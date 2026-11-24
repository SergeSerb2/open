"""UX round 1 wave 2 (lane UXG): sidebar contrast under Space themes, real App, real pixels.

With macOS Increase Contrast (automation stand-in `increase-contrast`, the same context flag the
system notification sets), light-text Space themes must reach WCAG AA in the sidebar: row titles,
the selected row and the URL host at 4.5:1, enabled toolbar and bottom-bar glyphs at 3:1.
Without it the sidebar keeps Arc 1.172.2's values (docs/re/sidebar-themes.md §1: mid-tone keys
2.2–2.7:1), checked by one control row.

Contrast: the window snapshot converted to sRGB; in each box the ink is the pixel farthest in
luminance from the box's dominant colour. Frames come from `sidebar-row` and `window-state`.
Socket only; Open is never activated; loopback pages.
`engine_e2e.py --only space-editor` runs it; OPEN_E2E_THEMES_UXG_ONLY=1 runs only these rows.
"""
import http.server
import os
import sys
import threading
import time
from collections import Counter

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from loopback_http import LoopbackHTTPServer  # noqa: E402

PAGES = {'/one': '<title>First page</title><body style="background:#fff">One</body>',
         '/two': '<title>Second page</title><body style="background:#fff">Two</body>'}
# SpaceStylePresets (Display P3 keys): Drab 1, Drab 8, Greyscale 6, Greyscale 9.
THEMES = {'Drab 1': 0x4B3B58, 'Drab 8': 0x2D4468, 'Greyscale 6': 0x666666, 'Greyscale 9': 0x000000}


def _server():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ('<!doctype html><meta charset=utf-8>' + PAGES.get(self.path, '<title>404</title>')).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)

        def log_message(self, *a):
            pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, 'http://127.0.0.1:%d' % server.server_address[1]


def _style(hex_):
    def lin(c): return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    def enc(c): return 12.92 * c if abs(c) <= 0.0031308 else (1 if c > 0 else -1) * (1.055 * abs(c) ** (1 / 2.4) - 0.055)
    r, g, b = (lin(((hex_ >> s) & 255) / 255) for s in (16, 8, 0))
    sr, sg, sb = 1.2249 * r - 0.2247 * g, -0.0420 * r + 1.0419 * g, -0.0197 * r - 0.0786 * g + 1.0979 * b
    return {'keyColor': {'red': enc(sr), 'green': enc(sg), 'blue': enc(sb), 'alpha': 1}, 'appearance': 'automatic'}


def _lum(p):
    def ch(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(p[0]) + 0.7152 * ch(p[1]) + 0.0722 * ch(p[2])


def _ratio(pixel, box, scale):
    x0, y0, x1, y1 = (int(v * scale) for v in box)
    px = [pixel(x, y) for x in range(x0, x1) for y in range(y0, y1)]
    bg = Counter(px).most_common(1)[0][0]
    ink = max(px, key=lambda p: abs(_lum(p) - _lum(bg)))
    a, b = sorted((_lum(ink), _lum(bg)), reverse=True)
    return round((a + 0.05) / (b + 0.05), 2)


def run(factory, results, tmp, h):
    server, origin = _server()
    app = factory(urls=(origin + '/one', origin + '/two'), fresh=True)
    try:
        tabs = app.call('tabs')
        today = [t for t in tabs if t.get('url', '').startswith(origin)]
        selected = next(t['id'] for t in today if t.get('selected'))
        other = next(t['id'] for t in today if t['id'] != selected)
        # A background tab that never loaded has no title to measure: load both, then come back.
        for tab in (other, selected):
            app.call('select', tab=tab); app.call('wait', tab=tab)
        time.sleep(.5)

        def measure(name):
            path = os.path.join(tmp, 'uxg-theme-%s.png' % name)
            app.call('snapshot', path=path)
            width, _, pixel = h.read_image(path, srgb=True)
            win = app.call('window-state'); W, H = win['frame'][2], win['frame'][3]; scale = width / W
            sw = win['sidebarWidth']
            sel = app.call('sidebar-row', node=selected)['frame']; row = app.call('sidebar-row', node=other)['frame']
            url = win['chrome']['urlField']; reload = win['toolbarFrames']['reload']
            def text(f): return (f[0] + 40, f[1] + 11, f[0] + f[2] - 14, f[1] + f[3] - 11)
            values = {
                'selectedRow': _ratio(pixel, text(sel), scale), 'row': _ratio(pixel, text(row), scale),
                'urlHost': _ratio(pixel, (url[0] + 12, url[1] + 10, url[0] + url[2] * 0.55, url[1] + url[3] - 10), scale),
                'reloadGlyph': _ratio(pixel, (reload[0] + 8, reload[1] + 8, reload[0] + 24, reload[1] + 24), scale),
                'plusGlyph': _ratio(pixel, (sw - 32, H - 33, sw - 16, H - 17), scale)}
            values['frames'] = {'selected': sel, 'row': row, 'url': url}
            if os.environ.get('OPEN_E2E_THEMES_KEEP'): os.replace(path, os.path.join(os.environ['OPEN_E2E_THEMES_KEEP'], os.path.basename(path)))
            else: os.remove(path)
            return values

        def row(name, check):
            try:
                ok, evidence = check()
            except Exception as error:
                ok, evidence = False, {'error': repr(error)}
            results[name] = dict(ok=bool(ok), **evidence)
            print('uxg %-46s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

        app.call('increase-contrast', on=True)
        for appearance in ('light', 'dark'):
            app.call('appearance', name=appearance); time.sleep(.4)
            for theme, key in THEMES.items():
                def check(theme=theme, key=key, appearance=appearance):
                    app.call('theme-set', style=_style(key)); time.sleep(.6)
                    v = measure('%s-%s' % (theme.replace(' ', ''), appearance))
                    low = {k: x for k, x in v.items() if k != 'frames' and x < (3.0 if k.endswith('Glyph') else 4.5)}
                    return not low, dict(v, below=low)
                row('uxg_ic_contrast_%s_%s' % (theme.lower().replace(' ', ''), appearance), check)

        def bar_selection(theme, key):
            # The command bar's selected row (white text on the Space accent) in Light, per theme.
            app.call('increase-contrast', on=False); app.call('appearance', name='light'); time.sleep(.4)
            for _ in range(3):
                if not app.call('commandbar-state').get('presented'): break
                app.call('command', id='new-tab'); time.sleep(.8)
            app.call('theme-set', style=_style(key) if key is not None else None); time.sleep(.5)
            app.call('command', id='new-tab'); time.sleep(1.0)
            state = app.call('commandbar-state')
            if not state.get('presented'): return False, {'error': 'command bar did not open'}
            panel = state['panelFrame']
            path = os.path.join(tmp, 'uxg-bar.png'); app.call('snapshot', path=path)
            width, _, pixel = h.read_image(path, srgb=True)
            scale = width / app.call('window-state')['frame'][2]
            # Row 1 title: panel-relative box (fitted on 1x captures: title ink at x +53…+131, y +76…+94).
            label = (panel[0] + 53, panel[1] + 76, panel[0] + 131, panel[1] + 94)
            value = _ratio(pixel, label, scale)
            app.call('command', id='new-tab'); time.sleep(.6)
            os.remove(path)
            return value >= 4.5, {'selectedRowText': value, 'panel': panel}
        BAR_THEMES = {'Default': None, 'Drab 5': 0xD1B46A, 'Brand 8': 0x7EB8D6, 'Greyscale 5': 0x808080, 'Pastel 9': 0xC5C6E2}
        for theme, key in BAR_THEMES.items():
            row('uxg_commandbar_selection_aa_%s_light' % theme.lower().replace(' ', ''), lambda t=theme, k=key: bar_selection(t, k))

        def normal_keeps_parity():
            # Without Increase Contrast a light-text Space keeps Arc's values: the white selected plate.
            app.call('increase-contrast', on=False); app.call('appearance', name='dark'); time.sleep(.4)
            app.call('theme-set', style=_style(THEMES['Drab 8'])); time.sleep(.6)
            v = measure('drab8-normal')
            return v['selectedRow'] < 4.5 and v['urlHost'] < 4.5, dict(v, note='Arc 1.172.2: mid-tone keys 2.2–2.7:1')
        row('uxg_normal_contrast_keeps_arc_values', normal_keeps_parity)
    finally:
        try: app.call('increase-contrast', on=False)
        except Exception: pass
        try: app.quit()
        except Exception: pass
        server.shutdown(); server.server_close()
