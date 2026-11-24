"""UX round 1 wave 2 (lane UXG): sidebar and command bar contrast under Space themes, real App, real pixels.

Every preset of `SpaceStylePresets` (45: Brand, Brand gradient, Pastel, Drab, Greyscale), with Open in Light
and in Dark:
- `uxg_ic_<preset>_<appearance>`: with macOS Increase Contrast (automation stand-in `increase-contrast`,
  the same context flag the system notification sets) the sidebar reaches WCAG AA: row, selected row and
  URL host text 4.5:1, at rest and with the URL field hovered (render-only `sidebar-force-hover`);
  enabled reload and bottom-bar plus glyphs 3:1.
- `uxg_bar_<preset>_<appearance>`: the command bar's selected row (white text on the Space accent) 4.5:1.
Plus: the New Space draft preview with Increase Contrast (`uxg_ic_creation_draft_chrome`), a Split row title
(`uxg_ic_split_row_title`), and a control row that normal contrast keeps Arc 1.172.2's values
(docs/re/sidebar-themes.md §1: mid-tone keys 2.2–2.7:1).

Contrast: the window snapshot converted to sRGB; in each box the ink is the pixel farthest in luminance
from the box's dominant colour. Frames come from `sidebar-row`, `window-state` and `commandbar-state`.
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

# SpaceStylePresets.swift: key colours; 's' = sRGB, 'p' = Display P3. "Brand gradient" = Brand with 3 colours.
_BRAND = [(0xF2EAE4, 's'), (0xF29BBB, 's'), (0xA6729D, 's'), (0xF25E6B, 's'), (0xFF8558, 's'),
          (0xF2D66D, 'p'), (0x73E59C, 'p'), (0x7EB8D6, 'p'), (0x666786, 'p')]
_PAGES = {
    'Brand': _BRAND, 'Brand gradient': _BRAND,
    'Pastel': [(h, 'p') for h in (0xFDFBFA, 0xFBEAF3, 0xECD2EA, 0xF7CDD2, 0xFAE1D5, 0xFEF9E7, 0xE4FCEC, 0xE0F2FB, 0xC5C6E2)],
    'Drab': [(h, 'p') for h in (0x4B3B58, 0x623856, 0x854444, 0xA77048, 0xD1B46A, 0xCDCCA8, 0x84A885, 0x34604B, 0x2D4468)],
    'Greyscale': [(h, 'p') for h in (0xFFFFFF, 0xE5E5E5, 0xCCCCCC, 0xB2B2B2, 0x808080, 0x666666, 0x333333, 0x1A1A1A, 0x000000)],
}
PRESETS = ['%s %d' % (page, i + 1) for page in _PAGES for i in range(9)]


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


def _style(name):
    """The preset's stored style (keyColor in extended sRGB, as `SpaceStylePresets` stores it)."""
    if name is None:
        return None
    page, index = name.rsplit(' ', 1)
    hex_, space = _PAGES[page][int(index) - 1]
    def lin(c): return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    def enc(c): return 12.92 * c if abs(c) <= 0.0031308 else (1 if c > 0 else -1) * (1.055 * abs(c) ** (1 / 2.4) - 0.055)
    rgb = [((hex_ >> s) & 255) / 255 for s in (16, 8, 0)]
    if space == 'p':
        r, g, b = (lin(c) for c in rgb)
        rgb = [enc(1.2249 * r - 0.2247 * g), enc(-0.0420 * r + 1.0419 * g), enc(-0.0197 * r - 0.0786 * g + 1.0979 * b)]
    return {'keyColor': {'red': rgb[0], 'green': rgb[1], 'blue': rgb[2], 'alpha': 1},
            'colorCount': 3 if page == 'Brand gradient' else 1, 'appearance': 'automatic'}


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


def _slug(name):
    return (name or 'default').lower().replace(' ', '')


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

        def snapshot(name):
            path = os.path.join(tmp, 'uxg-theme-%s.png' % name)
            app.call('snapshot', path=path)
            width, _, pixel = h.read_image(path, srgb=True)
            if os.environ.get('OPEN_E2E_THEMES_KEEP'):
                os.replace(path, os.path.join(os.environ['OPEN_E2E_THEMES_KEEP'], os.path.basename(path)))
            else:
                os.remove(path)
            win = app.call('window-state')
            return pixel, width / win['frame'][2], win

        def url_box(win):
            url = win['chrome']['urlField']
            return (url[0] + 12, url[1] + 10, url[0] + url[2] * 0.55, url[1] + url[3] - 10)

        def glyphs(pixel, scale, win):
            # The bottom bar sits at the sidebar's bottom (the window can be shorter while a panel is open).
            side = win.get('sidebarFrame') or [0, 0, win['sidebarWidth'], win['frame'][3]]
            H, sw, reload = side[1] + side[3], side[2], win['toolbarFrames']['reload']
            return {'reloadGlyph': _ratio(pixel, (reload[0] + 8, reload[1] + 8, reload[0] + 24, reload[1] + 24), scale),
                    'plusGlyph': _ratio(pixel, (sw - 32, H - 33, sw - 16, H - 17), scale)}

        def measure(name):
            pixel, scale, win = snapshot(name)
            sel = app.call('sidebar-row', node=selected)['frame']; row = app.call('sidebar-row', node=other)['frame']
            def text(f): return (f[0] + 40, f[1] + 11, f[0] + f[2] - 14, f[1] + f[3] - 11)
            values = {'selectedRow': _ratio(pixel, text(sel), scale), 'row': _ratio(pixel, text(row), scale),
                      'urlHost': _ratio(pixel, url_box(win), scale), **glyphs(pixel, scale, win)}
            app.call('sidebar-force-hover', target='urlField'); time.sleep(.3)
            pixel, scale, win = snapshot(name + '-hover')
            values['urlHostHovered'] = _ratio(pixel, url_box(win), scale)
            app.call('sidebar-force-hover', target='none')
            return values

        def low(values):
            return {k: x for k, x in values.items() if isinstance(x, float) and x < (3.0 if k.endswith('Glyph') else 4.5)}

        only = os.environ.get('OPEN_E2E_THEMES_ROWS')

        def row(name, check):
            if only and not any(part in name for part in only.split(',')):
                return
            try:
                ok, evidence = check()
            except Exception as error:
                ok, evidence = False, {'error': repr(error)}
            results[name] = dict(ok=bool(ok), **evidence)
            print('uxg %-46s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

        # Increase Contrast, every preset, both appearances.
        app.call('increase-contrast', on=True)
        for appearance in ('light', 'dark'):
            app.call('appearance', name=appearance); time.sleep(.4)
            for theme in [None] + PRESETS:
                def check(theme=theme, appearance=appearance):
                    app.call('theme-set', style=_style(theme)); time.sleep(.5)
                    v = measure('%s-%s' % (_slug(theme), appearance))
                    return not low(v), dict(v, below=low(v))
                row('uxg_ic_%s_%s' % (_slug(theme), appearance), check)

        def split_title(theme):
            # A Split row's titles take the raised title too (review r1 #4: palette titles 3.4–4.1:1).
            app.call('appearance', name='dark'); app.call('theme-set', style=_style(theme)); time.sleep(.5)
            app.call('split'); time.sleep(1.2)
            split = app.call('split', op='state')['id']
            f = app.call('sidebar-row', node=split)['frame']
            pixel, scale, _ = snapshot('split-%s-dark' % _slug(theme))
            value = _ratio(pixel, (f[0] + 36, f[1] + 11, f[0] + f[2] / 2 - 6, f[1] + f[3] - 11), scale)
            app.call('split', op='menu', item='Separate All Tabs'); time.sleep(.8)
            app.call('select', tab=selected); time.sleep(.3)
            return value >= 4.5, {'splitTitle': value, 'frame': f}
        for theme in ('Drab 1', 'Drab 8', 'Drab 9'):
            row('uxg_ic_split_row_title_%s_dark' % _slug(theme), lambda t=theme: split_title(t))

        def creation_draft():
            # Dark-text focused Space, then a light draft in the New Space form: the chrome must follow
            # the draft's polarity (no white glyphs on the light draft).
            app.call('appearance', name='light'); app.call('theme-set', style=_style('Greyscale 9')); time.sleep(.5)
            app.call('editor-open', kind='create'); time.sleep(.8)
            app.call('editor-act', action='click', control='theme'); time.sleep(.8)
            app.call('editor-act', action='preset', index=0); time.sleep(.8)
            # Close the theme panel first (the draft stays in the form): a snapshot with the child panel
            # open spans both windows and is scaled.
            app.call('editor-close'); time.sleep(.6)
            draft = app.call('creation-state').get('style')
            pixel, scale, win = snapshot('creation-draft')
            values = glyphs(pixel, scale, win)
            app.call('editor-close'); time.sleep(.6)
            if not draft: return False, {'error': 'no draft theme in the form'}
            return not low(values), dict(values, below=low(values))
        row('uxg_ic_creation_draft_chrome', creation_draft)

        def bar_selection(theme, appearance):
            app.call('increase-contrast', on=False); app.call('appearance', name=appearance); time.sleep(.3)
            for _ in range(3):
                if not app.call('commandbar-state').get('presented'): break
                app.call('command', id='new-tab'); time.sleep(.6)
            app.call('theme-set', style=_style(theme)); time.sleep(.4)
            app.call('command', id='new-tab'); time.sleep(.9)
            state = app.call('commandbar-state')
            if not state.get('presented'): return False, {'error': 'command bar did not open'}
            panel = state['panelFrame']
            pixel, scale, _ = snapshot('bar-%s-%s' % (_slug(theme), appearance))
            # Row 1 title: panel-relative box (fitted on 1x captures: title ink at x +53…+131, y +76…+94).
            value = _ratio(pixel, (panel[0] + 53, panel[1] + 76, panel[0] + 131, panel[1] + 94), scale)
            app.call('command', id='new-tab'); time.sleep(.5)
            return value >= 4.5, {'selectedRowText': value}
        for appearance in ('light', 'dark'):
            for theme in [None] + PRESETS:
                row('uxg_bar_%s_%s' % (_slug(theme), appearance), lambda t=theme, a=appearance: bar_selection(t, a))

        def live_toggle():
            # Increase Contrast turned on while a Space shows (no theme change, same polarity): the chrome
            # glyphs and the URL host must redraw in the stronger colours at once (review r2).
            app.call('increase-contrast', on=False); app.call('appearance', name='dark')
            app.call('theme-set', style=_style('Drab 8')); time.sleep(.6)
            pixel, scale, win = snapshot('live-off')
            off = dict(glyphs(pixel, scale, win), urlHost=_ratio(pixel, url_box(win), scale))
            app.call('increase-contrast', on=True); time.sleep(.6)
            pixel, scale, win = snapshot('live-on')
            on = dict(glyphs(pixel, scale, win), urlHost=_ratio(pixel, url_box(win), scale))
            app.call('increase-contrast', on=False); time.sleep(.3)
            raised = all(on[k] > off[k] + 0.3 for k in off)
            return raised and not low(on), {'off': off, 'on': on, 'below': low(on)}
        row('uxg_ic_live_toggle_redraws_chrome', live_toggle)

        def normal_keeps_parity():
            # Without Increase Contrast a light-text Space keeps Arc's values: the white selected plate.
            app.call('increase-contrast', on=False); app.call('appearance', name='dark'); time.sleep(.4)
            app.call('theme-set', style=_style('Drab 9')); time.sleep(.5)
            v = measure('drab9-normal')
            return v['selectedRow'] < 4.5 and v['urlHost'] < 4.5, dict(v, note='Arc 1.172.2: mid-tone keys 2.2–2.7:1')
        row('uxg_normal_contrast_keeps_arc_values', normal_keeps_parity)
    finally:
        try: app.call('increase-contrast', on=False)
        except Exception: pass
        try: app.quit()
        except Exception: pass
        server.shutdown(); server.server_close()
