"""Real-App callers of live transfer and HTTP/proxy authentication APIs."""
import base64
import http.server
import io
import threading
import wave
from loopback_http import LoopbackHTTPServer


def run(factory, results, wait):
    credential = 'Basic ' + base64.b64encode(b'open-fixture:synthetic-only').decode()
    attempts = {}
    audio = io.BytesIO()
    with wave.open(audio, 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(8000)
        wav.writeframes(b'\0' * 160000)  # Ten seconds of synthetic silence.

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == '/tone.wav':
                body = audio.getvalue()
                self.send_response(200)
                self.send_header('Content-Type', 'audio/wav')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)
                return
            proxy = self.path.startswith('http://')
            protected = proxy or self.path.startswith('/auth')
            accepted = self.headers.get('Proxy-Authorization' if proxy else 'Authorization') == credential
            attempts[self.path] = attempts.get(self.path, 0) + 1
            # A fresh realm must challenge even if Chromium preemptively sent
            # credentials cached for a previous path on this loopback origin.
            if protected and attempts[self.path] == 1:
                accepted = False
            if self.path == '/auth/reject':
                accepted = False
            if self.path == '/auth/credential-boundary':
                boundary = 'Basic ' + base64.b64encode(('u' * 4096 + ':' + 'p' * 4096).encode()).decode()
                accepted = self.headers.get('Authorization') == boundary
            if protected and not accepted:
                body = b'<!doctype html><p>Authentication cancelled or required</p>'
                self.send_response(407 if proxy else 401)
                realm = ('r' * 4096 if self.path == '/auth/realm-boundary' else
                         'r' * 4097 if self.path == '/auth/realm-over' else
                         'Open API fixture%s' % (' proxy' if proxy else self.path))
                self.send_header('Proxy-Authenticate' if proxy else 'WWW-Authenticate', 'Basic realm="%s"' % realm)
            else:
                body = (b'<!doctype html><title>Engine API fixture</title>'
                        b'<input id="form"><div style="height:3000px">fixture</div>'
                        b'<script>window.nonce=globalThis.crypto?.randomUUID?.()||String(Math.random());'
                        b'window.accepted=true;</script>')
                self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    base = 'http://127.0.0.1:%d' % port
    app = None
    last_urls = {}

    def call(action='state', **args):
        reply = app.call('engine-api', action=action, **args)
        if action in ('add', 'navigate'):
            last_urls[args['page']] = args['url']
        return reply

    def loaded(key, match_url=True):
        return wait(lambda: (lambda p: p if p['live'] and not p['loading']
            and (not match_url or p['url'] == last_urls[key]) else None)(
            call()['pages'][key]), timeout=20)

    def evaluate(js, key='p'):
        return call('eval', page=key, js=js)

    def pending():
        return wait(lambda: next(iter(call()['requests']), None), timeout=15)

    def row(name, ok, **receipt):
        results[name] = dict(ok=bool(ok), **receipt)

    try:
        app = factory(fresh=True, urls=('about:blank',), extra_args=['--style=chrome'])
        call('start')
        call('add', page='p', browser='a', url=base + '/form')
        assert loaded('p'), 'live fixture did not load'
        evaluate('document.querySelector("#form").value="retained form";'
                 'history.pushState({},"","/history");scrollTo(0,420);true')
        evaluate('window.media=new Audio(%r);media.loop=true;media.play().then(()=>true)' % (base + '/tone.wav'))
        assert wait(lambda: evaluate('media.currentTime') > .05, timeout=10)
        script = ('({nonce,form:document.querySelector("#form").value,scroll:scrollY,history:history.length,'
                  'mediaPaused:media.paused,mediaLoop:media.loop})')
        before = evaluate(script)
        identity = call()['pages']['p']
        for source, target in [('a', 'b'), ('b', 'a')]:
            media_before = evaluate('media.currentTime')
            moved = call('transfer', page='p', **{'from': source, 'to': target, 'index': 0})
            after = evaluate(script)
            state = call()
            page = state['pages']['p']
            row('transfer_%s_to_%s' % (source, target),
                moved['moved'] and before == after and all(page[k] == identity[k] for k in ('id', 'tabID', 'view'))
                and state['browsers'][source]['tabs'] == []
                and state['browsers'][target]['tabs'] == [page['id']]
                and evaluate('media.currentTime') >= media_before
                and state['synchronousCallbacks'] == 0, preserved=before == after, identity=page,
                before=before, after=after, moved=moved['moved'], originalIdentity=identity,
                synchronousCallbacks=state['synchronousCallbacks'],
                sourceTabs=state['browsers'][source]['tabs'], targetTabs=state['browsers'][target]['tabs'])

        for name, source, target, index in [('context', 'a', 'c', 0), ('owner', 'b', 'a', 0),
                                            ('index', 'a', 'b', 1), ('same', 'a', 'a', 0)]:
            old = call()
            refused = call('transfer', page='p', **{'from': source, 'to': target, 'index': index})
            current = call()
            row('refuse_' + name, not refused['moved'] and old['pages'] == current['pages']
                and old['browsers'] == current['browsers'] and evaluate(script) == before)
        call('add', page='q', browser='d', url=base + '/neighbor')
        assert loaded('q')
        call('pin', page='p', pinned=True)
        moved = call('transfer', page='p', **{'from': 'a', 'to': 'd', 'index': 1})
        row('transfer_pinned_into_nonempty', moved['moved'] and call()['pages']['p']['pinned']
            and evaluate(script) == before)
        moved = call('transfer', page='p', **{'from': 'd', 'to': 'a', 'index': 0})
        row('transfer_nonlast_source', moved['moved'] and len(call()['browsers']['d']['tabs']) == 1
            and call()['pages']['p']['pinned'] and evaluate(script) == before)
        call('close-browser', browser='b')
        row('close_emptied_source', call()['pages']['p']['live'] and evaluate(script) == before)
        refused = call('transfer', page='p', **{'from': 'a', 'to': 'b', 'index': 0})
        row('refuse_closed_destination', not refused['moved'] and evaluate(script) == before)

        windows = call()['visibleWindows']
        call('add', page='auth', browser='a', url=base + '/auth/submit')
        challenge = pending()
        row('http_challenge', challenge and challenge['scheme'] == 'basic' and not challenge['proxy']
            and challenge['host'] == '127.0.0.1' and challenge['port'] == port
            and challenge['realm'] == 'Open API fixture/auth/submit'
            and challenge['origin'].startswith(base) and call()['visibleWindows'] == windows,
            challenge=challenge)
        assert challenge
        call('auth', id=challenge['id'], username='open-fixture', password='synthetic-only')
        assert loaded('auth')
        row('http_answer_once', evaluate('window.accepted===true', 'auth') is True and not call()['requests'])

        call('navigate', page='auth', url=base + '/auth/reject')
        challenge = pending(); assert challenge
        call('auth', id=challenge['id'], username='open-fixture', password='wrong')
        retry = pending()
        row('http_rejected_retry', retry and retry['id'] != challenge['id'])
        assert retry
        call('auth', id=retry['id'], cancel=True)
        row('http_cancel', bool(loaded('auth')) and not call()['requests'])

        call('navigate', page='auth', url=base + '/auth/navigation')
        assert pending()
        count = call()['cancelled']
        call('navigate', page='auth', url=base + '/form')
        row('http_navigation_withdrawal', bool(loaded('auth')) and call()['cancelled'] > count
            and not call()['requests'])

        call('navigate', page='auth', url=base + '/auth/stop')
        assert pending()
        count = call()['cancelled']
        call('stop', page='auth')
        row('http_stop_withdrawal', bool(loaded('auth', match_url=False)) and call()['cancelled'] > count
            and not call()['requests'])

        call('navigate', page='auth', url=base + '/auth/realm-boundary')
        boundary = pending()
        row('http_realm_boundary', boundary and len(boundary['realm']) == 4096)
        assert boundary
        call('auth', id=boundary['id'], cancel=True)
        assert loaded('auth')
        count = call()['received']
        call('navigate', page='auth', url=base + '/auth/realm-over')
        row('http_realm_over_limit', bool(loaded('auth')) and call()['received'] == count
            and not call()['requests'])
        call('navigate', page='auth', url=base + '/auth/credential-boundary')
        boundary = pending(); assert boundary
        call('auth', id=boundary['id'], username='u' * 4096, password='p' * 4096)
        row('http_credential_boundary', bool(loaded('auth')) and evaluate('window.accepted===true', 'auth') is True)
        call('navigate', page='auth', url=base + '/auth/credential-over')
        boundary = pending(); assert boundary
        call('auth', id=boundary['id'], username='u' * 4097, password='p')
        row('http_credential_over_limit', bool(loaded('auth')) and not call()['requests']
            and evaluate('window.accepted===true', 'auth') is False)
        call('auth', handles=False)
        call('navigate', page='auth', url=base + '/auth/unhandled')
        row('http_unhandled_no_chrome_dialog', bool(loaded('auth')) and not call()['requests']
            and call()['visibleWindows'] == windows)
        call('auth', handles=True)
        call('navigate', page='auth', url=base + '/auth/close')
        assert pending()
        count = call()['cancelled']
        call('close-browser', browser='a')
        row('http_close_withdrawal', wait(lambda: call()['cancelled'] > count, timeout=10)
            and not call()['requests'])
        call('cleanup'); app.quit(); app = None

        app = factory(fresh=True, urls=('about:blank',), extra_args=[
            '--style=chrome', '--proxy-server=http://127.0.0.1:%d' % port,
            '--proxy-bypass-list=<-loopback>'])
        call('start')
        call('add', page='proxy', browser='a', url='http://open-auth-fixture.test/page')
        challenge = pending()
        row('proxy_challenge', challenge and challenge['proxy'] and challenge['scheme'] == 'basic'
            and challenge['realm'] == 'Open API fixture proxy' and challenge['port'] == port,
            challenge=challenge)
        assert challenge
        call('auth', id=challenge['id'], username='open-fixture', password='synthetic-only')
        row('proxy_answer', bool(loaded('proxy')) and evaluate('window.accepted===true', 'proxy') is True)
        try:
            # Force the same finally path used by an assertion failure. A proxy
            # credential may be cached, so the earlier 401 cancel/close rows
            # separately prove cleanup of an actually pending challenge.
            call('navigate', page='proxy', url='http://other-auth-fixture.test/page')
            raise RuntimeError('intentional fixture early exit')
        except RuntimeError as error:
            assert str(error) == 'intentional fixture early exit'
        finally:
            cleaned = call('cleanup')
        row('cleanup_no_fixture_windows', cleaned['remainingWindows'] == 0 and cleaned['pending'] == 0,
            state=cleaned)
    finally:
        if app:
            try:
                call('cleanup')
            except Exception:
                pass
            app.quit()
        server.shutdown(); server.server_close()
