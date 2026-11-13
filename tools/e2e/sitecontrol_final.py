"""Final SCC flows through the real App, native panel and loopback fixtures."""
import base64
from collections import Counter
from contextlib import contextmanager, ExitStack
import hashlib
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import ssl
import subprocess
import threading

from loopback_http import LoopbackHTTPServer


@contextmanager
def fixture(tmp):
    root = Path(tmp) / 'scc-final-tls'
    root.mkdir(mode=0o700)
    hits = Counter()
    mutex = threading.Lock()
    class Page(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            with mutex:
                hits[(self.headers.get('Host', ''), self.path)] += 1
            if self.path.endswith('.js'):
                body = b'window.fixtureAdLoaded=true;window.mixedLoaded=true;'
                kind = 'text/javascript'
            else:
                body = b'<!doctype html><title>SCC local fixture</title><h1>Site Control</h1>'
                if self.path.startswith('/ads'):
                    body += b'<script src="http://demand.supply/ad.js"></script>'
                kind = 'text/html'
            self.send_response(200)
            self.send_header('Content-Type', kind)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
    with ExitStack() as resources:
        servers, pins = [], []
        for index in range(3):
            server = resources.enter_context(LoopbackHTTPServer(Page))
            if index:
                key, cert, config = [root / (str(index) + suffix) for suffix in ('.key', '.pem', '.cnf')]
                config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n'
                                  '[dn]\nCN=secure.scc.test\n[ext]\nsubjectAltName=DNS:*.scc.test\n')
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                                '-config', str(config), '-keyout', str(key), '-out', str(cert)],
                               check=True, capture_output=True, timeout=15)
                key.chmod(0o600)
                public = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-pubkey', '-noout'], timeout=10)
                der = subprocess.check_output(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=public, timeout=10)
                pins.append(base64.b64encode(hashlib.sha256(der).digest()).decode('ascii'))
                tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                tls.load_cert_chain(cert, key)
                server.socket = tls.wrap_socket(server.socket, server_side=True)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            resources.callback(worker.join, timeout=5)
            resources.callback(server.shutdown)
            servers.append(server)
        http, good, bad = [s.server_port for s in servers]
        yield dict(http='http://plain.scc.test:%d' % http,
                   secure='https://secure.scc.test:%d' % good,
                   bad='https://untrusted.scc.test:%d' % bad,
                   args=['--host-resolver-rules=MAP *.scc.test 127.0.0.1, MAP demand.supply 127.0.0.1:%d' % http,
                         '--no-proxy-server', '--ignore-certificate-errors-spki-list=' + pins[0],
                         '--allow-running-insecure-content'], hits=hits, mutex=mutex)


def run(factory, results, tmp, h):
    group = os.environ.get('OPEN_SCC_FINAL_GROUP', 'all')
    if group not in ('all', 'adblock', 'security', 'clear'):
        raise ValueError('unknown final SCC group')
    wait = h.wait_until
    app, saved = None, {}
    def record(name, ok, **detail):
        results[name] = dict(ok=bool(ok), load=list(os.getloadavg()), **detail)
        print(name, 'PASS' if ok else 'FAIL', flush=True)
        if ok and isinstance(detail.get('panel'), dict) and detail['panel'].get('presented'):
            capture = Path(h.ROOT) / '.re/s12-t-final' / (name + '.png')
            capture.parent.mkdir(parents=True, exist_ok=True)
            app.call('snapshot', path=str(capture))
            results[name]['snapshot'] = str(capture)
    if group == 'clear':
        from page_site_data import run as clear_flows
        return clear_flows(factory, results, tmp, 'panel', h, site_control=True)
    with fixture(tmp) as f:
        try:
            app = factory(urls=(f['http'] + '/ads',), fresh=True, load_extensions=False, extra_args=f['args'])
            tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab)
            normal = app.call('window-state')['id']
            app.call('window-focus', id=normal, activate=True)
            for key, value in {'open.advanced.playSoundEffects': False, 'open.advanced.showToolbar': False}.items():
                saved[key] = app.call('defaults', key=key, persistent=True)
                app.call('defaults', key=key, value=value)
            def state(): return app.call('site-controls')
            def open_panel():
                if state()['presented']: app.call('site-controls', action='close')
                return app.call('site-controls', action='open')
            def tile(s=None):
                return next((r for r in (s or state())['rows'] if r['id'] == 'row.contentBlocking'), {})
            def tile_is(value):
                return wait(lambda: (lambda s: s if tile(s).get('state') == value else None)(state()), timeout=8)
            def visit(t, url):
                app.call('select', tab=t); app.call('navigate', tab=t, url=url); app.call('wait', tab=t)
            def tap(): return app.call('site-controls', action='tap', id='row.contentBlocking')
            def native(t):
                page = app.call('tab-state', tab=t)['page']['identifier']
                return next((c for p in app.call('settings-adblock-engine')['profiles'] for c in p['contexts']
                             if any(v['identifier'] == page for v in c['pages'])), {})
            def barrier(t, count):
                return wait(lambda: (lambda c: c if c.get('adBlockStatus', {}).get('engine_loaded')
                                    and c.get('adBlockStatus', {}).get('excluded_count') == count else None)(native(t)), timeout=40)
            def files():
                paths = [Path(app.user_data) / 'adblock-settings.json']
                paths += list(Path(app.user_data).glob('Profiles/*/[Aa]d[Bb]lock/exclusions.json'))
                return {str(p.relative_to(app.user_data)): (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
                        for p in paths if p.exists()}
            def ad_hits():
                with f['mutex']:
                    return sum(n for (host, path), n in f['hits'].items() if path == '/ad.js')
            if group in ('all', 'adblock'):
                app.call('settings-adblock', enabled=True)
                assert wait(lambda: app.call('settings-adblock')['ready'], timeout=40), 'Settings readiness'
                assert barrier(tab, 0), 'native lists not loaded'
                visit(tab, f['http'] + '/ads')
                s = open_panel()
                record('T_normal_initial_block', tile(s).get('state') == 'on'
                       and app.eval(tab, 'window.fixtureAdLoaded===true') is False, panel=s, native=native(tab))
                # Normal clicks still persist to the parent owner.
                tap(); assert tile_is('off'); assert barrier(tab, 1)
                def saved_domain():
                    return any('scc.test' in json.loads(p.read_text()) for p in Path(app.user_data).glob('Profiles/*/[Aa]d[Bb]lock/exclusions.json'))
                saved_exclusion = wait(saved_domain, timeout=8)
                persisted = files()
                record('T_normal_saved_exclusion', saved_exclusion, files=persisted)
                tap(); assert tile_is('on'); assert barrier(tab, 0)
                parent_profile = app.call('settings-adblock-site', tab=tab)['profile']
                def private_window():
                    app.call('menu-perform', id='new-incognito-window')
                    w = wait(lambda: next((w for w in app.call('incognito-state')['windows'] if w['private']), None), timeout=10)
                    assert w, 'private window did not open'
                    app.call('window-focus', id=w['id'], activate=True)
                    app.call('key', key='escape', route='app')
                    t = h.new_tab(app, f['http'] + '/ads')
                    assert barrier(t, 0)
                    return w, t
                private, pt = private_window()
                session = app.call('settings-adblock-site', tab=pt)['privateSession']
                initial = open_panel(); before = files(); hits_before = ad_hits()
                record('T_private_initial_on', bool(session) and tile(initial).get('state') == 'on', panel=initial)
                assert tile(initial).get('state') == 'on', 'private tile unavailable before the click'
                tap(); off = tile_is('off'); private_native = barrier(pt, 1)
                visit(pt, f['http'] + '/ads?private-off')
                loaded = app.eval(pt, 'window.fixtureAdLoaded===true')
                private_state = app.call('settings-adblock-site', tab=pt)
                record('T_private_session_only', off and private_native and loaded and ad_hits() > hits_before
                       and files() == before and not private_state['shouldBlock'],
                       before=before, after=files(), panel=off, store=private_state, native=private_native,
                       scriptLoaded=loaded, adRequests=[hits_before, ad_hits()])
                app.call('window-focus', id=normal, activate=True)
                visit(tab, f['http'] + '/ads?normal-still-blocked'); s = open_panel()
                record('T_private_parent_still_blocks', tile(s).get('state') == 'on'
                       and app.eval(tab, 'window.fixtureAdLoaded===true') is False, panel=s, native=native(tab))
                tap(); assert tile_is('off'); assert barrier(tab, 1)
                app.call('window-focus', id=private['id'], activate=True); open_panel()
                assert tile_is('off')
                app.call('window-focus', id=normal, activate=True); open_panel(); tap(); assert tile_is('on'); assert barrier(tab, 0)
                app.call('window-focus', id=private['id'], activate=True); open_panel()
                preserved = tile_is('off')
                record('T_parent_change_preserves_private', preserved and not app.call('settings-adblock-site', tab=pt)['shouldBlock'], panel=preserved)
                app.call('window-focus', id=normal, activate=True); open_panel(); tap(); assert tile_is('off'); assert barrier(tab, 1)
                app.call('window-focus', id=private['id'], activate=True); open_panel()
                inherited_before = files()
                tap(); inherited = tile_is('off')
                record('T_inherited_parent_stays_off', inherited and not app.call('settings-adblock-site', tab=pt)['shouldBlock'] and files() == inherited_before, panel=inherited, savedFilesUnchanged=files() == inherited_before)
                app.call('window-focus', id=normal, activate=True); open_panel(); tap(); assert tile_is('on'); assert barrier(tab, 0)
                app.call('window-focus', id=private['id'], activate=True); open_panel()
                assert tile_is('on'); tap(); assert tile_is('off'); assert barrier(pt, 1)
                before_close = files()
                app.call('window-close')
                closed = wait(lambda: not app.call('settings-adblock-profile', profile=parent_profile, privateSession=session)['privateSessionOpen'], timeout=10)
                app.call('window-focus', id=normal, activate=True)
                private, pt = private_window()
                current = app.call('settings-adblock-site', tab=pt); reopened = open_panel()
                record('T_private_last_close_drops_choice', closed and current['privateSession'] != session
                       and current['shouldBlock'] and tile(reopened).get('state') == 'on' and files() == before_close,
                       oldSessionClosed=closed, new=current, panel=reopened, filesUnchanged=files() == before_close)
                app.call('window-close'); app.call('window-focus', id=normal, activate=True); open_panel()
                # Keep this exact panel visible across the real Profile lifecycle.
                close_state = app.call('settings-adblock-lifecycle', profile=parent_profile, action='close')
                unavailable = tile_is('unavailable')
                record('T_profile_close_refresh', unavailable and state()['presented'] and bool(tile(unavailable).get('help')) and not close_state['open'], panel=unavailable, store=close_state)
                app.call('settings-adblock-lifecycle', profile=parent_profile, action='open')
                record('T_profile_reopen_refresh', bool(tile_is('on')), panel=state())
            # Exercise the built-in certificate error page. Use its existing
            # proceed link when offered; never add a shell bypass or trust rule.
            if group in ('all', 'security'):
                visit(tab, f['secure'] + '/secure')
                secure = wait(lambda: app.call('security-state', tab=tab)['level'] == 'secure', timeout=10)
                s = open_panel()
                record('T_security_trusted_https', secure and s['security']['title'] == 'Connection: Secure'
                       and s['security']['enabled'], panel=s, engine=app.call('security-state', tab=tab))
                # A10 certificate viewer (SC-16 onSecurityButtonClick -> showCertificateDialog): the pill
                # closes the panel and shows the page's chain in the system certificate sheet.
                chain = len(app.call('security-state', tab=tab)['certificates'])
                app.call('site-controls', action='tap', id='security')
                sheet = wait(lambda: (lambda x: x if 'SFCertificatePanel' in x.get('sheet', '') else None)(state()), timeout=5)
                ended = app.call('site-controls', action='end-sheet') if sheet else None
                record('T_security_certificate_sheet', bool(sheet) and not sheet['presented'] and chain >= 1
                       and state().get('sheet') == '', sheet=sheet and sheet.get('sheet'), chain=chain,
                       negative='T_security_plain_http: the pill is status only on http')
                s = open_panel()
                deliveries = s['sourceReads']['changeDeliveries']
                app.eval(tab, "(()=>{let s=document.createElement('script');s.src=%s;document.body.append(s);return true})()" % json.dumps(f['http'] + '/mixed.js'))
                mixed = wait(lambda: app.call('security-state', tab=tab)['level'] == 'mixedContent', timeout=10)
                panel = wait(lambda: (lambda s: s if s['security']['title'] == 'Connection: Insecure' else None)(state()), timeout=8)
                record('T_security_mixed_live_refresh', mixed and panel and panel['presented']
                       and panel['sourceReads']['changeDeliveries'] > deliveries and app.eval(tab, 'window.mixedLoaded===true'),
                       panel=panel, engine=app.call('security-state', tab=tab), variant='mixed-content warning on an already-open panel')
                visit(tab, f['http'] + '/plain'); s = open_panel()
                record('T_security_plain_http', s['security']['title'] == 'Connection: Insecure' and not s['security']['enabled'], panel=s)
                # Begin on secure HTTPS so a canceled provisional navigation
                # cannot pass just because the previous page was plain HTTP.
                visit(tab, f['secure'] + '/before-certificate-error'); open_panel()
                app.call('navigate', tab=tab, url=f['bad'] + '/untrusted')
                bad = wait(lambda: (lambda s: s if s['level'] == 'dangerous' else None)(app.call('security-state', tab=tab)), timeout=15)
                s = open_panel()
                error_document = app.eval(tab, "({title:document.title,url:location.href,proceed:!!document.querySelector('#proceed-link')})")
                interstitial_panel = s
                error_ok = bad and s['security']['title'] == 'Connection: Insecure'
                proceed = app.eval(tab, """(()=>{
                  document.querySelector('#details-button')?.click();
                  const link=document.querySelector('#proceed-link');
                  if(!link || !link.getClientRects().length || getComputedStyle(link).visibility==='hidden')return false;
                  link.click();return true})()""")
                proceed_ok, engine = True, bad
                if proceed:
                    app.call('wait', tab=tab)
                    loaded = wait(lambda: app.eval(tab, 'document.title') == 'SCC local fixture', timeout=10)
                    engine = app.call('security-state', tab=tab); s = open_panel()
                    proceed_ok = loaded and engine['level'] == 'dangerous' and s['host'] == 'untrusted.scc.test' and s['security']['title'] == 'Connection: Insecure'
                record('T_security_untrusted_https', error_ok and proceed_ok,
                       panel=s, engine=engine, interstitialPanel=interstitial_panel, interstitialEngine=bad,
                       requestedOrigin=f['bad'], errorDocument=error_document, proceeded=proceed,
                       variant='existing Privacy error details/proceed link' if proceed else 'approved untrusted-error plus mixed-content variant')
        finally:
            if app:
                try: h._restore_defaults(app, saved)
                finally: app.quit()
    if group == 'all':
        from page_site_data import run as clear_flows
        clear_flows(factory, results, tmp, 'panel', h, site_control=True)
