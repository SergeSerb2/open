"""E1/E2/E3 through the real App's OpenWeb API; no desktop input or mocks."""
import base64
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
import subprocess
import threading


def run(factory, results, tmp, new_tab, wait_until):
    hits = Counter()
    mutex = threading.Lock()
    pixel = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=')

    class Page(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            host = self.headers.get('Host', '').split(':')[0]
            with mutex:
                hits[(host, self.path)] += 1
                count = hits[(host, self.path)]
            content_type = 'text/html'
            cache = 'no-store'
            if self.path == '/deep/cookies':
                body = self.headers.get('Cookie', '').encode(); content_type = 'text/plain'
            elif self.path == '/cached':
                body = ('cache-' + str(count)).encode()
                cache = 'public, max-age=31536000, immutable'
                content_type = 'text/plain'
            elif self.path.startswith('/pixel'):
                body = pixel; content_type = 'image/png'
            else:
                body = b'''<!doctype html><title>Open site data fixture</title>
                  <script>document.documentElement.dataset.pageScript='ran'</script>
                  <body>Site data fixture<img id="pixel" src="/pixel"></body>'''
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Cache-Control', cache)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    secure_server = None; secure_worker = None; app = None
    a = 'http://127.0.0.1:%d' % server.server_port
    b = 'http://localhost:%d' % server.server_port
    tabs = []
    def check(name, ok, **evidence): results[name] = dict(ok=bool(ok), **evidence)
    def listed(origin): return {x['kind']: x['state'] for x in app.call('site-settings', origin=origin)}
    def setting(origin, kind, state): return app.call('site-setting', origin=origin, kind=kind, state=state)
    def load(tab, url):
        app.call('navigate', tab=tab, url=url)
        app.call('wait', tab=tab, timeout=20)
    def cache(tab): return app.eval(tab, "fetch('/cached',{cache:'force-cache'}).then(r=>r.text())")
    def count(host):
        with mutex: return hits[(host, '/cached')]
    def storage(tab):
        return app.eval(tab, """(async()=>({local:localStorage.getItem('s12'),
          cache:await caches.has('s12'),db:await new Promise((resolve,reject)=>{
            const r=indexedDB.open('s12');r.onerror=()=>reject(r.error);r.onsuccess=()=>{
              const d=r.result;if(!d.objectStoreNames.contains('values')){d.close();resolve(null);return}
              const q=d.transaction('values').objectStore('values').get('s12');
              q.onsuccess=()=>{d.close();resolve(q.result??null)};q.onerror=()=>{d.close();reject(q.error)}
            }})}))()""")
    seed = """(async()=>{document.cookie='s12=kept;path=/';document.cookie='deep=kept;path=/deep';localStorage.setItem('s12','kept');
      await (await caches.open('s12')).put('/storage-entry',new Response('kept'));
      await new Promise((resolve,reject)=>{const r=indexedDB.open('s12');
        r.onupgradeneeded=()=>r.result.createObjectStore('values');r.onerror=()=>reject(r.error);
        r.onsuccess=()=>{const d=r.result;const t=d.transaction('values','readwrite');
          t.objectStore('values').put('kept','s12');t.oncomplete=()=>{d.close();resolve()};
          t.onerror=()=>{d.close();reject(t.error)}}});return true})()"""
    try:
        app = factory(urls=(a + '/start',), fresh=True)
        ta = app.call('tabs')[0]['id']; tabs.append(ta)
        app.call('wait', tab=ta, timeout=20)
        tb = new_tab(app, b + '/start'); tabs.append(tb)
        initial = listed(a)
        js_set = setting(a, 'javascript', 'block')
        js_list = listed(a)
        load(ta, a + '/javascript-blocked')
        js_blocked = app.eval(ta, "document.documentElement.dataset.pageScript||null")
        js_reset = setting(a, 'javascript', 'allow')
        load(ta, a + '/javascript-allowed')
        js_allowed = app.eval(ta, "document.documentElement.dataset.pageScript||null")
        check('sitedata_javascript', initial == {} and js_set and js_list.get('javascript') == 'block'
              and js_blocked is None and js_reset and js_allowed == 'ran' and 'javascript' not in listed(a)
              and listed(b) == {}, initial=initial, listed=js_list, blocked=js_blocked, allowed=js_allowed)

        images_set = setting(a, 'images', 'block')
        load(ta, a + '/images-blocked')
        image_blocked = app.eval(ta, "document.querySelector('#pixel').naturalWidth")
        image_list = listed(a)
        images_reset = setting(a, 'images', 'allow')
        load(ta, a + '/images-allowed')
        image_allowed = wait_until(lambda: app.eval(ta, "document.querySelector('#pixel').naturalWidth"), timeout=5)
        check('sitedata_images', images_set and images_reset and image_list.get('images') == 'block'
              and image_blocked == 0 and image_allowed == 1 and listed(a) == {},
              listed=image_list, blocked=image_blocked, allowed=image_allowed)

        session = setting(a, 'cookies', 'session')
        session_list = listed(a)
        ask = setting(a, 'geolocation', 'ask')
        invalid = [setting(a, 'images', 'session'), setting(a, 'not-a-type', 'allow'),
                   setting('file:///tmp/invalid-origin', 'images', 'block'),
                   setting(a, 'images\0trailing', 'block')]
        empty = app.call('site-data-clear', origin=a, kinds=[])
        refused_clear = False
        try: app.call('site-data-clear', origin='file:///tmp/invalid-origin', kinds=['cache'])
        except RuntimeError: refused_clear = True
        reset = setting(a, 'cookies', 'allow')
        # Normalize a maximum-size URL to the same origin; reject one UTF-16
        # unit over the native/CEF bound before URL conversion or mutation.
        maximum_origin = a + '/' + 'x' * (16384 - len(a) - 1)
        limit_ok = setting(maximum_origin, 'images', 'block')
        over_limit = setting(maximum_origin + 'x', 'images', 'allow')
        limit_setting = listed(a).get('images')
        limit_reset = setting(a, 'images', 'allow')
        check('sitedata_states_invalid_empty', session and session_list.get('cookies') == 'session' and ask
              and invalid == [False, False, False, False] and empty and refused_clear and reset and listed(a) == {}
              and limit_ok and not over_limit and limit_setting == 'block' and limit_reset,
              session=session_list, invalid=invalid, empty=empty, invalidClearRefused=refused_clear,
              maximumOriginAccepted=limit_ok, overLimitRefused=not over_limit)

        for tab in [ta, tb]: app.eval(tab, seed)
        pre_a, pre_b = storage(ta), storage(tb)
        cache_a1, cache_b1 = cache(ta), cache(tb)
        cache_a2, cache_b2 = cache(ta), cache(tb)
        counts_before = [count('127.0.0.1'), count('localhost')]
        app.call('site-data-clear', origin=a, kinds=['cookies'])
        cookies = [app.eval(t, 'document.cookie') for t in [ta, tb]]
        deep_cookies = [app.eval(t, "fetch('/deep/cookies').then(r=>r.text())") for t in [ta, tb]]
        check('sitedata_cookies', pre_a == pre_b == {'local':'kept','cache':True,'db':'kept'}
              and 's12=' not in cookies[0] and 's12=kept' in cookies[1]
              and deep_cookies[0] == '' and 'deep=kept' in deep_cookies[1]
              and storage(ta) == pre_a and cache(ta) == cache_a1 and count('127.0.0.1') == 1,
              cookies=cookies, deepCookies=deep_cookies, beforeA=pre_a, beforeB=pre_b)

        app.call('site-data-clear', origin=a, kinds=['cache'])
        cache_after_a, cache_after_b = cache(ta), cache(tb)
        counts_after = [count('127.0.0.1'), count('localhost')]
        check('sitedata_cache', counts_before == [1,1] and counts_after == [2,1]
              and cache_a1 == cache_a2 == 'cache-1' and cache_b1 == cache_b2 == cache_after_b == 'cache-1'
              and cache_after_a == 'cache-2' and storage(ta) == pre_a
              and 's12=kept' in app.eval(tb,'document.cookie'),
              serverBefore=counts_before, serverAfter=counts_after, a=cache_after_a, b=cache_after_b)

        app.call('site-data-clear', origin=a, kinds=['storage'])
        # LocalStorage can cache its state in a live renderer. A new document
        # reads the cleared backend, also proving the data does not reappear.
        load(ta, a + '/storage-after-clear')
        after_a, after_b = storage(ta), storage(tb)
        check('sitedata_storage', after_a == {'local':None,'cache':False,'db':None} and after_b == pre_b
              and cache(tb) == 'cache-1' and count('localhost') == 1
              and 's12=kept' in app.eval(tb, 'document.cookie'), a=after_a, b=after_b)

        app.call('events')
        blank = new_tab(app, 'about:blank'); tabs.append(blank)
        neutral = app.call('security-state', tab=blank)
        http = app.call('security-state', tab=ta)
        check('sitedata_security_http_neutral', neutral == {'level':'neutral','certificates':[]}
              and http == {'level':'insecure','certificates':[]}, http=http, neutral=neutral)

        # No local trust or keychain changes. A public HTTPS control is used
        # because a newly generated local root is not trusted on this machine.
        valid = new_tab(app, 'https://example.com/'); tabs.append(valid)
        valid_state = wait_until(lambda: (lambda s: s if s['level']=='secure' and s['certificates'] else None)(
            app.call('security-state', tab=valid)), timeout=30)
        check('sitedata_security_https', bool(valid_state), state=valid_state)

        cert_dir = Path(tmp) / 'sitedata-tls'; cert_dir.mkdir()
        key, cert = cert_dir/'key.pem', cert_dir/'cert.pem'
        subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
                        '-subj','/CN=localhost','-keyout',str(key),'-out',str(cert)],
                       check=True, capture_output=True)
        secure_server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert,key)
        secure_server.socket = context.wrap_socket(secure_server.socket, server_side=True)
        secure_worker = threading.Thread(target=secure_server.serve_forever,daemon=True); secure_worker.start()
        app.call('events')
        # Navigate an existing page after draining its initial notifications;
        # creation/close flags must not satisfy the security-change gate.
        bad = blank
        app.call('navigate', tab=bad, url='https://localhost:%d/self-signed' % secure_server.server_port)
        bad_state = wait_until(lambda: (lambda s: s if s['level']=='dangerous' and s['certificates'] else None)(
            app.call('security-state', tab=bad)), timeout=20)
        events = app.call('events')
        security_events = [e for e in events if e.get('tab') == bad and int(e.get('changes',0)) & (1 << 16)]
        check('sitedata_security_self_signed', bool(bad_state), state=bad_state)
        check('sitedata_security_change', bool(security_events), events=security_events)
    finally:
        if app:
            # Settings live only in this fresh profile. Restore them even on
            # failure; no `defaults` key or system trust setting is touched.
            for kind in ['javascript','images','cookies']:
                try: setting(a,kind,'allow')
                except Exception: pass
            app.quit()
        if secure_server:
            secure_server.shutdown(); secure_server.server_close(); secure_worker.join(timeout=5)
        server.shutdown(); server.server_close(); worker.join(timeout=5)
