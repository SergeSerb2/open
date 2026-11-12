"""PB3 row 5: Developer Mode's content panel (developer bar) and its network list, through the real App.

A synthetic loopback server serves every page. Rows: the bar shows only for a Developer Mode site and replaces the
page area's top 40 pt; its nine buttons; the network list records the page's requests (200 and 404) from DevTools
protocol events; a navigation starts a new list; Close and Developer Mode off remove it.
"""
import http.server
import os
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_GET(self):
        pages = {
            '/a': b'<!doctype html><title>Example A</title><h1>A</h1><img src="/pixel.png"><script src="/app.js"></script>'
                  b'<script>fetch("/missing.json")</script>',
            '/b': b'<!doctype html><title>Example B</title><h1>B</h1><script src="/app.js?b"></script>',
        }
        path = self.path.split('?')[0]
        if path in pages: body, kind, code = pages[path], 'text/html', 200
        elif path == '/app.js': body, kind, code = b'window.example = 1;', 'text/javascript', 200
        elif path == '/pixel.png':
            body = bytes.fromhex('89504e470d0a1a0a0000000d4948445200000001000000010806000000'
                                 '1f15c4890000000d49444154789c6360000002000154a24f5f0000000049454e44ae426082')
            kind, code = 'image/png', 200
        else: body, kind, code = b'{"error":"not found"}', 'application/json', 404
        self.send_response(code); self.send_header('Content-Type', kind); self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)


def run(factory, results, tmp, h):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_port
    def row(name, ok, **detail): results[name] = dict(ok=bool(ok), **detail)
    try:
        app = factory(urls=(base + '/a',), fresh=True)
        tabs = app.call('tabs')
        tab = next(t['id'] for t in tabs if '/a' in t.get('url', ''))
        app.call('wait', tab=tab, timeout=30)
        def state(): return app.call('developer-panel')
        off = state()
        row('bar_hidden_without_developer_mode', off.get('shown') is False, state={k: off.get(k) for k in ('shown', 'toolbar')})

        app.call('command', id='toggle-developer-mode')
        assert h.wait_until(lambda: state().get('shown'), timeout=10, step=.05), state()
        on = state()
        frame, page = on.get('frame', [0, 0, 0, 0]), on.get('pageFrame', [0, 0, 0, 0])
        buttons = {b['id']: b for b in on.get('buttons', [])}
        row('bar_shown_for_site', on.get('url') == base + '/a' and frame[3] == 40 and abs(page[1] + page[3] - frame[1]) < .5
            and len(buttons) == 9 and all(b['frame'][2] == 28 and b['frame'][3] == 28 for b in buttons.values())
            and buttons['siteSettings']['frame'][0] < buttons['copyURL']['frame'][0] < buttons['capture']['frame'][0]
            < buttons['console']['frame'][0] < buttons['network']['frame'][0] < buttons['inspect']['frame'][0]
            < buttons['extensions']['frame'][0] < buttons['splitMenu']['frame'][0]
            and buttons['network']['label'] == 'Toggle Network Panel',
            url=on.get('url'), frame=frame, page=page, buttons=sorted(buttons))

        # Pane 2: the sidebar marks a Developer Mode site. A second tab on "localhost" (another site) stays plain.
        other = h.new_tab(app, base.replace('127.0.0.1', 'localhost') + '/b')
        app.call('select', tab=tab)
        def rows(): return {r['url']: r for r in state().get('rows', [])}
        assert h.wait_until(lambda: rows().get(base + '/a', {}).get('outline') is True, timeout=10, step=.05), state().get('rows')
        marked = rows(); dev, plain = marked[base + '/a'], marked[base.replace('127.0.0.1', 'localhost') + '/b']
        port = base.rsplit(':', 1)[1]
        row('sidebar_marks_developer_site', dev['subtitle'] == '127.0.0.1:' + port and dev['titleBaseline'] == 18 and dev['outline'] is True
            and plain['subtitle'] == '' and plain['titleBaseline'] == 25 and plain['outline'] is False, dev=dev, plain=plain)
        app.call('select', tab=other)
        assert h.wait_until(lambda: rows().get(base + '/a', {}).get('outline') is False, timeout=10, step=.05), state().get('rows')
        moved = rows()
        row('outline_only_on_current_row', moved[base + '/a']['subtitle'] == '127.0.0.1:' + port
            and moved[base.replace('127.0.0.1', 'localhost') + '/b']['outline'] is False, rows=moved)
        app.call('select', tab=tab)

        app.call('developer-panel', action='press', button='network')
        assert h.wait_until(lambda: state().get('networkPressed'), timeout=10, step=.05), state()
        app.call('navigate', tab=tab, url=base + '/a')
        def entries():
            # The browser's own favicon fetch is not page traffic; it is ignored by name.
            return [e for e in next(iter(state().get('logs', {}).get('logs', {}).values()), []) if not e['url'].endswith('/favicon.ico')]
        assert h.wait_until(lambda: any(e['url'].endswith('/missing.json') and e['status'] == 404 for e in entries()), timeout=20, step=.1), entries()
        listed = entries(); shown = state()
        frames = os.environ.get('OPEN_E2E_DEVMODE_FRAMES')
        if frames:  # look frames for the lead, not asserted: the real browser window with the bar and the list
            for mode in ('light', 'dark'):
                app.call('appearance', name=mode); time.sleep(.8)
                app.call('snapshot', path=os.path.join(frames, 'devmode-network-%s.png' % mode))
            app.call('appearance', name='system')
        urls = sorted(e['url'].replace(base, '') for e in listed)
        row('network_list_records_requests', urls == ['/a', '/app.js', '/missing.json', '/pixel.png']
            and {e['url'].replace(base, ''): e['status'] for e in listed} == {'/a': 200, '/app.js': 200, '/missing.json': 404, '/pixel.png': 200}
            and all(e['method'] == 'GET' for e in listed) and shown.get('networkRows') == 4
            and abs(shown['pageFrame'][1] - shown['networkFrame'][3]) < .5,
            urls=urls, rows=shown.get('networkRows'), networkFrame=shown.get('networkFrame'), pageFrame=shown.get('pageFrame'))

        app.call('navigate', tab=tab, url=base + '/b')
        assert h.wait_until(lambda: any('/app.js?b' in e['url'] for e in entries()), timeout=20, step=.1), entries()
        time.sleep(.5)
        after = sorted(e['url'].replace(base, '') for e in entries())
        row('navigation_starts_new_list', after == ['/app.js?b', '/b'] and state().get('url') == base + '/b', urls=after)

        app.call('developer-panel', action='press', button='network')
        assert h.wait_until(lambda: not state().get('networkPressed'), timeout=10, step=.05), state()
        closed = state()
        row('network_list_closes', 'networkRows' not in closed and closed.get('logs', {}).get('shown') == []
            and abs(closed['pageFrame'][1]) < .5, state={k: closed.get(k) for k in ('networkPressed', 'pageFrame')})

        app.call('developer-panel', action='press', button='network')
        assert h.wait_until(lambda: state().get('networkPressed'), timeout=10, step=.05)
        app.call('command', id='toggle-developer-mode')
        assert h.wait_until(lambda: not state().get('shown'), timeout=10, step=.05), state()
        # The sidebar row redraws on its next layout pass, after the bar is gone: wait for it, then assert.
        h.wait_until(lambda: {r['url']: r for r in state().get('rows', [])}.get(base + '/b', {}).get('outline') is False, timeout=10, step=.05)
        gone = state()
        unmarked = {r['url']: r for r in gone.get('rows', [])}.get(base + '/b', {})
        row('sidebar_unmarks_after_off', unmarked.get('subtitle') == '' and unmarked.get('titleBaseline') == 25 and unmarked.get('outline') is False,
            row=unmarked)
        row('developer_mode_off_removes_bar_and_list', gone.get('shown') is False and 'networkRows' not in gone
            and gone.get('logs', {}).get('shown') == [], state={k: gone.get(k) for k in ('shown', 'logs')})
    finally:
        server.shutdown(); server.server_close()
