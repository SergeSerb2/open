"""PB3 row 5: Developer Mode's toolbar and sidebar marks, through the real App (capture PB3-a).

A synthetic loopback server serves every page. Rows: the bar shows only for a Developer Mode site and replaces the
page area's top 40 pt; Arc's nine controls in order with Arc's names; its light and dark colours; the sidebar
outline and host subtitle; Console / Network / Inspect toggle the standard DevTools on that panel.
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
            and [b['label'] for b in sorted(buttons.values(), key=lambda b: b['frame'][0])] == [
                'Site Settings', 'Copy Link', 'Capture Window', 'Capture', 'Toggle Console', 'Toggle Network Panel',
                'Inspect Element', 'Extensions Menu', 'Split View Menu'],
            url=on.get('url'), frame=frame, page=page,
            labels=[b['label'] for b in sorted(buttons.values(), key=lambda b: b['frame'][0])])

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

        # Capture PB3-a: Console, Network and Inspect toggle the standard Chromium DevTools on that panel.
        def selected():
            try: return app.call('devtools-frontend', tab=tab, js=h._DEVTOOLS_SELECTED_TABS) or []
            except RuntimeError: return None  # no DevTools for this page
        def press(button):
            app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
            app.call('developer-panel', action='press', button=button)
        def wait_panel(tab_id):
            return h.wait_until(lambda: (lambda ids: ids if ids and tab_id in ids else None)(selected()), timeout=20, step=.25)
        press('console')
        console = wait_panel('tab-console'); pressed_console = state().get('activePanel')
        frames = os.environ.get('OPEN_E2E_DEVMODE_FRAMES')  # look frames for the lead, not asserted
        press('network')
        network = wait_panel('tab-network'); pressed_network = state().get('activePanel')
        row('console_and_network_open_devtools_panel', bool(console) and pressed_console == 'console'
            and bool(network) and pressed_network == 'network' and state()['devtools']['hasDevTools'] is True,
            console=console, network=network, pressed=[pressed_console, pressed_network])
        press('network')
        closed = h.wait_until(lambda: selected() is None, timeout=10, step=.25)
        after_close = state()
        row('same_button_closes_devtools', bool(closed) and after_close.get('activePanel') == ''
            and after_close['devtools']['hasDevTools'] is False, state=after_close.get('devtools'))
        press('inspect')
        inspect = wait_panel('tab-elements'); pressed_inspect = state().get('activePanel')
        row('inspect_opens_elements', bool(inspect) and pressed_inspect == 'inspect', tabs=inspect, pressed=pressed_inspect)
        press('inspect'); h.wait_until(lambda: selected() is None, timeout=10, step=.25)

        # The bar's colours follow the appearance (Arc's measured default-theme values).
        palettes = {}
        for mode in ('light', 'dark'):
            app.call('appearance', name=mode); time.sleep(.5)
            palettes[mode] = state().get('palette')
            if frames: app.call('snapshot', path=os.path.join(frames, 'devbar-%s.png' % mode))
        app.call('appearance', name='system')
        row('bar_palette_light_dark', palettes['light'] == {'stripeA': '#EFF1F5', 'stripeB': '#F4F5F8', 'glyph': '#212AFB', 'text': '#242526', 'line': '#D8D9DD'}
            and palettes['dark'] == {'stripeA': '#3E43CA', 'stripeB': '#4247CB', 'glyph': '#ECEDFE', 'text': '#D8D9F4', 'line': '#5155CF'}, palettes=palettes)

        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        app.call('command', id='toggle-developer-mode')
        assert h.wait_until(lambda: not state().get('shown'), timeout=10, step=.05), state()
        # The sidebar row redraws on its next layout pass, after the bar is gone: wait for it, then assert.
        h.wait_until(lambda: {r['url']: r for r in state().get('rows', [])}.get(base + '/a', {}).get('outline') is False, timeout=10, step=.05)
        gone = state()
        unmarked = {r['url']: r for r in gone.get('rows', [])}.get(base + '/a', {})
        row('sidebar_unmarks_after_off', unmarked.get('subtitle') == '' and unmarked.get('titleBaseline') == 25 and unmarked.get('outline') is False,
            row=unmarked)
        row('developer_mode_off_removes_bar', gone.get('shown') is False, state={k: gone.get(k) for k in ('shown', 'toolbar')})
    finally:
        server.shutdown(); server.server_close()
