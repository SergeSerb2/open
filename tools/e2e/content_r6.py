"""Bug sweep r6 CONTENT6 rows through the real App (routing and downloads).

DHR-02: a Little Open rule whose Profile is gone is skipped like a missing Space rule.
DHR-03: a link routed to a Space reuses a minimized browser window (no second window).
DHR-07: a `data:` download whose address is over 8 KiB keeps its history row (no store error).
DHR-08: an Incognito download in progress counts as a running download (the quit warning).

Synthetic pages on a loopback server only. Links arrive through LaunchServices
(`open -a <this bundle>`), never a system default handler.
"""
import base64
import http.server
import json
import os
import subprocess
import threading
import time
import uuid

from loopback_http import LoopbackHTTPServer


def run(factory, results, h, tmp):
    wait_until = h.wait_until

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split('?')[0]
            if path == '/slow':
                total = 4 << 20
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Disposition', 'attachment; filename="r6-slow.bin"')
                self.send_header('Content-Length', str(total)); self.end_headers()
                try:
                    for _ in range(total // 16384):
                        self.wfile.write(b'\0' * 16384); self.wfile.flush(); time.sleep(.05)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            body = ('<!doctype html><title>R6 %s</title><h1>%s</h1>' % (path, path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = LoopbackHTTPServer(Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]
    downloads_dir = os.path.join(tmp, 'content-r6-downloads')
    os.makedirs(downloads_dir, exist_ok=True)
    env = {'OPEN_DOWNLOADS_DEFAULT_DIRECTORY': downloads_dir}
    if os.environ.get('OPEN_CONTENT_R6_APP'):
        # A saved copy of another build (break-and-revert proof against the parent commit).
        env['OPEN_E2E_APP_BUNDLE'] = os.environ['OPEN_CONTENT_R6_APP']

    def record(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('content-r6 %-44s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    app = factory(urls=(), fresh=True, extra_env=env)
    try:
        # ---- Routing fixture: one Profile that does not exist in any rule's target ----
        with open(app.call('save')) as stream:
            seed = json.load(stream)
        space = seed['spaces'][0]['id']
        gone = str(uuid.uuid4()).upper()
        seed['routingRules'] = [
            {'id': str(uuid.uuid4()).upper(), 'match': {'urlPrefix': {'_0': base + '/gone-little'}},
             'destination': {'littleOpen': {'profile': gone}}},
            {'id': str(uuid.uuid4()).upper(), 'match': {'urlPrefix': {'_0': base + '/gone-little'}},
             'destination': {'space': {'_0': space}}},
            {'id': str(uuid.uuid4()).upper(), 'match': {'urlPrefix': {'_0': base + '/minimized'}},
             'destination': {'space': {'_0': space}}}]
        fixture = os.path.join(tmp, 'content-r6-routing.json')
        with open(fixture, 'w') as stream:
            json.dump(seed, stream)
        app.quit()
        app = factory(urls=(base + '/start',), snapshot=fixture, extra_env=env)
        app.call('wait', tab=app.call('tabs')[0]['id'])

        def deliver(url):
            return subprocess.run(['/usr/bin/open', '-a', app.bundle, url], capture_output=True, text=True, timeout=15)

        def decision(url):
            return wait_until(lambda: next((e['decision'] for e in app.call('routing-log')['entries']
                                            if e['decision']['request']['url'] == url), None), timeout=10, step=.1) or {}

        # DHR-02
        url = base + '/gone-little/page'
        sent = deliver(url)
        made = decision(url)
        traces = [list(t['outcome'].keys())[0] for t in made.get('traces', [])]
        record('r6_routing_little_open_missing_profile_skipped',
               sent.returncode == 0 and traces[:2] == ['targetProfileMissing', 'matched']
               and 'space' in (made.get('resolved') or {}) and 'rule' in (made.get('via') or {}),
               traces=traces, resolved=made.get('resolved'), via=made.get('via'))

        # DHR-03
        windows_before = len(app.call('shell-windows'))
        # Minimize acts on the key window: make the browser window key first.
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        app.call('menu-perform', id='minimize-window')
        minimized = wait_until(lambda: app.call('window-state').get('miniaturized') or None, timeout=5, step=.1)
        url = base + '/minimized/page'
        sent = deliver(url)
        made = decision(url)
        landed = wait_until(lambda: any(t['url'] == url for t in app.call('tabs')), timeout=10, step=.1)
        windows_after = len(app.call('shell-windows'))
        shown = wait_until(lambda: not app.call('window-state').get('miniaturized') or None, timeout=5, step=.1)
        record('r6_routing_minimized_window_reused',
               sent.returncode == 0 and minimized and landed and windows_after == windows_before and shown
               and made.get('standardWindowCount') == 1,
               windowsBefore=windows_before, windowsAfter=windows_after, minimized=bool(minimized), shown=bool(shown),
               standardWindowCount=made.get('standardWindowCount'))
        h._try(lambda: app.call('window-deminiaturize'))

        # DHR-07: a data: address over the 8 KiB source limit.
        page = h.new_tab(app, base + '/data-download')
        payload = base64.b64encode(b'r6 ' * 3000).decode()
        app.eval(page, '(() => {let a=document.createElement("a"); a.href=%s; a.download="r6-data.txt"; a.id="r6data";'
                       ' a.textContent="download"; document.body.replaceChildren(a); return true})()'
                 % json.dumps('data:text/plain;base64,' + payload))
        app.call('click', tab=page, selector='#r6data')
        done = wait_until(lambda: next((i for i in app.call('downloads-state')['items']
                                        if i['name'] == 'r6-data.txt' and i['state'] == 'completed'), None), timeout=15, step=.1)
        time.sleep(1.5)  # the store's write callback
        data_error = app.call('downloads-state').get('historyError')

        # DHR-08: an Incognito transfer in progress is a running download.
        idle = app.call('downloads-state')['running']
        app.call('menu-perform', id='new-incognito-window')
        private = wait_until(lambda: next((v for v in app.call('incognito-state')['windows'] if v['private']), None), timeout=10, step=.1)
        running = None
        if private:
            app.call('window-focus', id=private['id'], activate=True)
            app.call('download-dir', path=downloads_dir)
            app.call('open', url=base + '/slow')
            running = wait_until(lambda: app.call('downloads-state')['running'] or None, timeout=10, step=.1)
            h._try(lambda: app.call('window-close'))
        after_close = wait_until(lambda: not app.call('downloads-state')['running'] or None, timeout=10, step=.1)
        record('r6_downloads_incognito_transfer_is_running', idle is False and bool(private) and bool(running) and bool(after_close),
               idle=idle, private=bool(private), running=bool(running), afterClose=bool(after_close))

        # DHR-07 after a relaunch: the completed data: download is still a history row.
        app.quit()
        app = factory(urls=(), fresh=False, extra_env=env)
        app.call('command', id='view-downloads')
        kept = wait_until(lambda: next((i for i in app.call('downloads-state')['items']
                                        if i['name'] == 'r6-data.txt' and i['historical']), None), timeout=10, step=.1)
        record('r6_downloads_long_data_url_keeps_history', bool(done) and data_error == '' and bool(kept)
               and app.call('downloads-state').get('historyError') == '',
               historyError=data_error, kept=bool(kept), sourceLength=len((done or {}).get('source', '')),
               afterRelaunchError=app.call('downloads-state').get('historyError'))
    finally:
        h._try(lambda: app.quit())
        server.shutdown()
