"""Transient Little Open tabs through real Cocoa Apple events and real pages."""
import http.server
import threading
import time
from loopback_http import LoopbackHTTPServer

NUX = 'open.links.littleOpenNUXSeen'


def run(app, script, results, wait_until, quote, key, off_message, prefix=''):
    requests = []
    release = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Security-Policy', "script-src 'self'")
            self.end_headers()
            try:
                self.wfile.write(('<!doctype html><title>Little script %s</title><body>fixture' % self.path).encode())
                self.wfile.flush()
                if self.path == '/slow':
                    release.wait(12)
                    self.wfile.write(b'done')
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *args): pass

    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    saved = {name: app.call('defaults', key=name, persistent=True) for name in (key, NUX)}
    original = {row['id'] for row in app.call('little-open-state')['sessions']}
    model_ids = {row['id'] for row in app.call('tabs')}

    def record(name, ok, **details): results[prefix+'A15_'+name] = dict(details, ok=bool(ok))
    def sessions(): return app.call('little-open-state')['sessions']
    def state(tab): return next((row for row in sessions() if row['tabID'].lower() == tab.lower()), None)
    def target(tab): return 'tab id '+quote(tab)
    def ready(tab, path):
        return wait_until(lambda: (row if (row := state(tab)) and row['url'] == origin+path
            and not row['loading'] and row['title'] == 'Little script '+path else None), timeout=15, step=.1)

    try:
        app.call('defaults', key=key, value=None)
        app.call('defaults', key=NUX, value=True)
        invalid = script.error('make new tab with properties {URL:"invalid text"}', 1001,
            '"invalid text" is not a valid URL.')
        record('invalid_URL', invalid['ok'] and {row['id'] for row in sessions()} == original,
            **error_without_ok(invalid))
        try:
            tab = script('set t to make new tab with properties {URL:'+quote(origin+'/a')+'}\nreturn id of t')
        except RuntimeError as error:
            record('make', False, error=str(error), sender=script.mode)
            return  # The unchanged-code negative proof must retain the 1011 failure.
        row = ready(tab, '/a')
        props = script('return (id of '+target(tab)+') & "|" & (URL of '+target(tab)+') & "|" & (title of '+target(tab)+') & "|" & loading of '+target(tab))
        record('make', bool(row and row['visible'] and row['state'] == 'page' and not row['sidebarTab'])
            and props == tab+'|'+origin+'/a|Little script /a|false', state=row, properties=props, sender=script.mode)
        record('lowercase_ID', script('return id of '+target(tab.lower())) == tab)
        # make means fresh creation even for the same URL; external-link reuse is separate.
        duplicate = script('set t to make new tab with properties {URL:'+quote(origin+'/a')+'}\nreturn id of t')
        record('fresh_window', duplicate != tab and state(duplicate) is not None)
        script('close '+target(duplicate))

        off = script.error('execute '+target(tab)+' javascript "document.title"', 1013, off_message)
        app.call('defaults', key=key, value=True)
        value = script('return execute '+target(tab)+' javascript "document.title"')
        nested = script.error('execute '+target(tab)+' javascript '+quote("eval('1+1')"), 1013)
        record('javascript_gate_CSP', off['ok'] and value == 'Little script /a'
            and nested['ok'] and 'EvalError' in nested['reply'], off=off, value=value, explicitEval=nested)
        if not prefix:
            import os
            started = time.monotonic()
            timeout = script.error('execute '+target(tab)+' javascript "new Promise(() => {})"', 1014,
                'JavaScript did not finish in 10 seconds.')
            record('javascript_deadline', timeout['ok'], elapsedSeconds=time.monotonic()-started,
                loadAverage=list(os.getloadavg()), **error_without_ok(timeout))
            record('javascript_after_deadline', script('return execute '+target(tab)+' javascript "6*7"') == '42')

        script('set URL of '+target(tab)+' to '+quote(origin+'/b'))
        navigated = ready(tab, '/b')
        script('go back '+target(tab))
        back = ready(tab, '/a')
        script('go forward '+target(tab))
        forward = ready(tab, '/b')
        record('navigate_back_forward', bool(navigated and back and forward), url=script('return URL of '+target(tab)))
        count = requests.count('/b')
        script('execute '+target(tab)+' javascript "window.reloadMarker = 7"\nreload '+target(tab))
        reloaded = wait_until(lambda: requests.count('/b') > count or None, timeout=10, step=.1)
        ready(tab, '/b')
        marker = script('return execute '+target(tab)+' javascript "typeof window.reloadMarker"')
        record('reload', bool(reloaded) and marker == 'undefined', beforeRequests=count,
            afterRequests=requests.count('/b'), marker=marker)

        script('set URL of '+target(tab)+' to '+quote(origin+'/slow'))
        loading = wait_until(lambda: state(tab) and state(tab)['loading'] or None, timeout=10, step=.1)
        loading_property = script('return loading of '+target(tab)+' as text')
        script('stop '+target(tab))
        stopped = wait_until(lambda: state(tab) and not state(tab)['loading'] or None, timeout=10, step=.1)
        record('stop_loading', bool(loading and stopped) and loading_property == 'true', loading=loading_property)
        release.set()

        for name, body in [('select', 'select '+target(tab)), ('location_get', 'get location of '+target(tab)),
                           ('location_set', 'set location of '+target(tab)+' to "pinned"'),
                           ('window_containment', 'get '+target(tab)+' of window 1'),
                           ('space_containment', 'get '+target(tab)+' of space 1 of window 1')]:
            error = script.error(body, 1009)
            record('unsupported_'+name, error['ok'] and 'not supported for Little Open tabs' in error['reply'], **error_without_ok(error))
        record('no_model_tab', {row['id'] for row in app.call('tabs')} == model_ids
            and script('return count windows') == '1', beforeCount=len(model_ids), afterCount=len(app.call('tabs')))

        script('close '+target(tab))
        closed = wait_until(lambda: state(tab) is None or None, timeout=5, step=.1)
        record('close', bool(closed))
        uses = [('reference', 'get '+target(tab))]
        uses += [(key, 'get '+key+' of '+target(tab)) for key in ('id', 'URL', 'title', 'loading', 'location')]
        uses += [(verb, verb+' '+target(tab)) for verb in ('select', 'reload', 'go back', 'go forward', 'stop', 'close')]
        uses += [('set_URL', 'set URL of '+target(tab)+' to '+quote(origin+'/a')),
                 ('set_location', 'set location of '+target(tab)+' to "unpinned"'),
                 ('execute', 'execute '+target(tab)+' javascript "42"')]
        for name, body in uses:
            results[prefix+'A15_closed_'+name] = script.error(body, 1000)

        blank = script('set t to make new tab\nreturn (id of t) & "|" & URL of t')
        blank_id, blank_url = blank.split('|', 1)
        blank_state = state(blank_id)
        record('blank', blank_url == 'about:blank' and blank_state is not None and blank_state['state'] == 'bar', state=blank_state)
        # Navigate immediately, including before the deferred Browser exists.
        script('set URL of '+target(blank_id)+' to '+quote(origin+'/blank-nav'))
        immediate = script('return execute '+target(blank_id)+' javascript "document.title"')
        navigated_blank = ready(blank_id, '/blank-nav')
        record('blank_navigate_execute', immediate == 'Little script /blank-nav'
            and bool(navigated_blank and navigated_blank['state'] == 'page'), value=immediate, state=navigated_blank)
        # Hold the exact make result through closure in the same AppleScript evaluation.
        retained = script.error('set t to '+target(blank_id)+'\nclose t\nget id of t', 1000)
        record('retained_closed', retained['ok'], **error_without_ok(retained))
        record('blank_no_model_tab', {row['id'] for row in app.call('tabs')} == model_ids)
    finally:
        release.set()
        try:
            for row in sessions():
                if row['id'] not in original:
                    app.call('little-open-action', id=row['id'], action='close')
        finally:
            try:
                for name, value in saved.items(): app.call('defaults', key=name, value=value)
                restored = {name: app.call('defaults', key=name, persistent=True) for name in saved}
                record('defaults_restored', restored == saved)
            finally:
                server.shutdown(); server.server_close()


def error_without_ok(error):
    return {key: value for key, value in error.items() if key != 'ok'}
