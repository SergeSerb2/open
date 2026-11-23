"""UX round 1, page chrome (lane UXG): frame rows through the real App socket and DevTools.

- `split_rows`: Split View pane bars in narrow panes. No two visible bar buttons overlap, Close and
  Back stay as long as there is room, and the visible buttons sit inside the bar, vertically centred.
- `zap_rows`: the Zap popup and Done next to the Boost editor (which Arc centers on the window's
  right edge, so it covers the page's right side). The popup and Done stay inside the visible page
  and clear of the editor: after a click on the right of the page, after a window resize with the
  popup open, and in a short window.

Socket only (no desktop input, the app is never activated); loopback pages only.
`engine_e2e.py --only split` runs `split_rows`; `--only boosteditor` runs `zap_rows`.
OPEN_SPLIT_UXG_ONLY=1 / OPEN_E2E_BOOST_UXG_ONLY=1 run only these rows.
"""
import http.server
import os
import sys
import threading
import time

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from loopback_http import LoopbackHTTPServer  # noqa: E402

PAGES = {
    '/plain': '<title>Plain</title><body style="margin:0;background:#fff;font:15px -apple-system">Plain page</body>',
    '/dark': '<title>Dark</title><body style="margin:0;background:#15161a;color:#ddd;font:15px -apple-system">Dark page</body>',
    '/zapwide': ('<title>Zap wide</title><style>body{margin:24px;font:15px -apple-system}div{height:60px;margin:10px 0;'
                 'background:#eee}.r{margin-left:auto;width:300px;background:#fdd}</style><div>Left block</div>'
                 '<div class=r id=right>Right block</div><div>Another block</div>'),
}


def _server():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ('<!doctype html><meta charset=utf-8>' + PAGES.get(self.path.split('?')[0], '<title>404</title>')).encode()
            self.send_response(200 if self.path.split('?')[0] in PAGES else 404)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, 'http://127.0.0.1:%d' % server.server_address[1]


def _row(results, name, check):
    try:
        ok, evidence = check()
    except Exception as error:  # a broken step is a failed row, never a skipped one
        ok, evidence = False, {'error': repr(error)}
    results[name] = dict(ok=bool(ok), **evidence)
    print('uxg %-44s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)


def _overlap(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


# ---------------------------------------------------------------- Split View pane bars
def split_rows(factory, results, tmp, h):
    server, origin = _server()
    app = factory(urls=(origin + '/plain', origin + '/dark'), fresh=True)
    wait = h.wait_until
    try:
        tabs = [t['id'] for t in app.call('tabs')]
        app.call('select', tab=tabs[0])
        app.call('split'); wait(lambda: len(app.call('split', op='state')['panes']) >= 2, timeout=10)
        for _ in range(2):
            app.call('split', op='menu', item='Add Pane'); time.sleep(1.0)

        def bars(size):
            app.call('window-frame', frame=[80, 80, size[0], size[1]], unconstrained=True); time.sleep(.8)
            state = app.call('split', op='state')
            return state, [(p['frame'], p.get('ring'), p.get('barControls')) for p in state['panes']]

        for size in ((1280, 800), (760, 520), (520, 380)):
            def check(size=size):
                state, panes = bars(size)
                problems, seen = [], []
                for frame, focused, controls in panes:
                    if controls is None:
                        return False, {'error': 'split state has no barControls (automation predates the row)', 'panes': len(panes)}
                    names = [c[0] for c in controls]
                    seen.append({'width': frame[2], 'focused': focused, 'controls': names})
                    for i, a in enumerate(controls):
                        x, y, w, hh = a[1:]
                        if x < 0 or x + w > frame[2] + 0.5:
                            problems.append('%s outside its %.0f pt bar' % (a[0], frame[2]))
                        if abs((y + hh / 2) - 16) > 0.5:
                            problems.append('%s not centred (y %s h %s)' % (a[0], y, hh))
                        for b in controls[i + 1:]:
                            if _overlap(a[1:], b[1:]):
                                problems.append('%s overlaps %s in a %.0f pt pane' % (a[0], b[0], frame[2]))
                    if 'Close This Pane' not in names:
                        problems.append('Close hidden in a %.0f pt pane' % frame[2])
                    if frame[2] >= 120 and 'Go back' not in names:
                        problems.append('Back hidden in a %.0f pt pane' % frame[2])
                return not problems, {'size': list(size), 'panes': seen, 'problems': problems[:12]}
            _row(results, 'uxg_split_bar_no_overlap_%dx%d' % size, check)
    finally:
        app.call('window-frame', frame=[80, 80, 1280, 800], unconstrained=True)
        server.shutdown(); server.server_close()


# ---------------------------------------------------------------- Zap next to the Boost editor
class _Picker:
    def __init__(self, app, tab):
        self.app, self.tab = app, tab

    def box(self, selector):
        """Border box of an overlay element in viewport CSS px: [x, y, w, h], or None when hidden."""
        root = self.app.call('devtools', tab=self.tab, method='DOM.getDocument', params={'depth': -1, 'pierce': True})['root']

        def find(node):
            attrs = node.get('attributes', [])
            if any(attrs[i:i + 2] == ['id', 'open-zap-overlay-host'] for i in range(0, len(attrs), 2)):
                return node
            for child in node.get('children', []) + node.get('shadowRoots', []):
                found = find(child)
                if found:
                    return found
        host = find(root)
        node = self.app.call('devtools', tab=self.tab, method='DOM.querySelector',
                             params={'nodeId': host['shadowRoots'][0]['nodeId'], 'selector': selector})['nodeId']
        try:
            quad = self.app.call('devtools', tab=self.tab, method='DOM.getBoxModel', params={'nodeId': node})['model']['border']
        except Exception:
            return None
        xs, ys = quad[0::2], quad[1::2]
        return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]

    def mouse(self, kind, x, y):
        params = {'type': kind, 'x': x, 'y': y}
        if kind != 'mouseMoved':
            params.update(button='left', clickCount=1)
        self.app.call('devtools', tab=self.tab, method='Input.dispatchMouseEvent', params=params)


def zap_rows(factory, results, tmp, h):
    wait = h.wait_until
    server, origin = _server()
    app = factory(urls=(origin + '/zapwide',), fresh=True)
    keys = {'open.advanced.enableBoosts': True, 'open.boosts.hasDismissedInterstitial': True}
    saved = {k: app.call('defaults', key=k, persistent=True) for k in keys}
    try:
        for k, v in keys.items():
            app.call('defaults', key=k, value=v)
        tab = next(t['id'] for t in app.call('tabs') if t['selected'])
        app.call('wait', tab=tab)
        picker = _Picker(app, tab)

        def editor_on(size):
            app.call('boost-editor', action='close'); time.sleep(.3)
            app.call('window-frame', frame=[80, 80, size[0], size[1]], unconstrained=True); time.sleep(.8)
            app.call('boost-editor', action='open')
            ready = lambda: (lambda s: any(c['id'] == 'editor.tool.zap' and c['enabled'] for c in s.get('controls', [])))(app.call('boost-editor'))
            assert wait(ready, timeout=10, step=.1), 'Zap did not enable'
            app.call('boost-editor', action='tap', id='editor.tool.zap')
            assert wait(lambda: app.eval(tab, 'window.__openZap?.isActive() === true', world='open'), timeout=5, step=.05), 'picker did not enter'
            time.sleep(.6)  # the editor's cover reaches the picker after it is ready

        def geometry():
            """The page and the editor in screen points, and a viewport-px to screen mapper."""
            win = app.call('window-state')
            panel, frame = win['panel'], win['frame']
            inner = app.eval(tab, '[innerWidth, innerHeight]')
            scale = panel[2] / inner[0]
            page = [frame[0] + panel[0], frame[1] + frame[3] - panel[1] - panel[3], panel[2], panel[3]]

            def to_screen(b):
                return [page[0] + b[0] * scale, page[1] + page[3] - (b[1] + b[3]) * scale, b[2] * scale, b[3] * scale]
            editor = app.call('boost-editor')['frame']
            return page, editor, to_screen

        def placed(selector, label):
            page, editor, to_screen = geometry()
            box = picker.box(selector)
            if box is None:
                return False, {'error': label + ' not shown'}
            r = to_screen(box)
            inside = r[0] >= page[0] - .5 and r[1] >= page[1] - .5 and r[0] + r[2] <= page[0] + page[2] + .5 and r[1] + r[3] <= page[1] + page[3] + .5
            covered = _overlap(r, editor)
            return inside and not covered, {label: [round(v, 1) for v in r], 'page': page, 'editor': editor,
                                            'insidePage': inside, 'underEditor': covered}

        def click_right_block():
            rect = app.eval(tab, '(r => [r.left, r.top, r.width, r.height])(document.getElementById("right").getBoundingClientRect())')
            x, y = rect[0] + rect[2] - 20, rect[1] + rect[3] / 2
            picker.mouse('mouseMoved', x, y); time.sleep(.3)
            picker.mouse('mousePressed', x, y); picker.mouse('mouseReleased', x, y)
            assert wait(lambda: picker.box('.popup') is not None, timeout=5, step=.05), 'no popup'
            time.sleep(.2)

        def default_window():
            editor_on((1280, 800)); click_right_block()
            return placed('.popup', 'popup')
        _row(results, 'uxg_zap_popup_clear_of_editor_1280x800', default_window)

        def after_resize():
            app.call('window-frame', frame=[80, 80, 900, 700], unconstrained=True); time.sleep(1.0)
            ok, evidence = placed('.popup', 'popup')
            # The editor stays where it was, so it no longer covers the page: Done is back at its
            # own place, 10 px from the page's right edge (no stale inset from the old size).
            page, editor, to_screen = geometry()
            done = to_screen(picker.box('.done'))
            scale = page[2] / app.eval(tab, 'innerWidth')
            flush = abs((page[0] + page[2] - 10 * scale) - (done[0] + done[2])) <= 1
            return ok and flush and not _overlap(page, editor), dict(evidence, done=[round(v, 1) for v in done], doneFlushRight=flush)
        _row(results, 'uxg_zap_popup_inside_page_after_resize', after_resize)

        def short_window():
            editor_on((760, 520))
            ok, evidence = placed('.done', 'done')
            click_right_block()
            popup_ok, popup = placed('.popup', 'popup')
            return ok and popup_ok, dict(evidence, popupCheck=popup)
        _row(results, 'uxg_zap_done_and_popup_clear_of_editor_760x520', short_window)
    finally:
        try:
            app.call('boost-editor', action='close')
            app.call('window-frame', frame=[80, 80, 1280, 800], unconstrained=True)
            for k, v in saved.items():
                app.call('defaults', key=k, value=v)
        except Exception:
            pass
        server.shutdown(); server.server_close()
