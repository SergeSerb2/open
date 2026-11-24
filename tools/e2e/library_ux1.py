"""UX round 1 (lane UXE): Library and Live Calendar layout rows through the real App.

Run by the history suite after the r7 rows; OPEN_LIBRARY_UX1_ONLY=1 runs only these rows:

  /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock env OPEN_LIBRARY_UX1_ONLY=1 \
      python3 tools/e2e/engine_e2e.py --only history --config Debug

Every row drives the real App through the automation socket on a fresh synthetic Profile.

UX1_E01 (E1): the Library rail draws every tile whole inside its viewport, from the standard
  window down to the window's minimum height (480 pt). Before the fix, tiles kept 80 pt at a
  72 pt minimum pitch, so any window under about 620 pt cut the last tile ("History") in half.
UX1_E02 (E2): the Live Calendar countdown plate on a calendar Favorite draws dark ink after the
  appearance changes from dark to light. Before the fix, the tile refreshed the plate's dark
  flag only when its text changed, so it kept near-white ink on a light tile. The row starts in
  Light and creates the countdown in Dark, so it fails without the fix on any host appearance.
"""
import os
import struct
import time
import zlib


def png_luma(path):
    """Minimal PNG reader (RGB/RGBA, 8 or 16 bits, not interlaced): width, height and a
    function (x, y) -> luminance 0...1. Snapshots in Dark can be 16-bit (wide colour)."""
    data = open(path, 'rb').read()
    pos, idat, info = 8, b'', None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR': info = struct.unpack('>IIBBBBB', chunk)
        elif kind == b'IDAT': idat += chunk
        pos += 12 + length
    width, height, depth, color, _, _, interlace = info
    assert depth in (8, 16) and color in (2, 6) and interlace == 0, info
    channels, size = (3 if color == 2 else 4), depth // 8
    bpp = channels * size
    raw, stride, rows, prev = zlib.decompress(idat), width * bpp, [], bytearray(width * bpp)
    for y in range(height):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p_ = a + b - c; pa, pb, pc = abs(p_ - a), abs(p_ - b), abs(p_ - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    def luma(x, y):
        o = x * bpp  # the high byte of each 16-bit sample is enough here
        r, g, b = rows[y][o], rows[y][o + size], rows[y][o + 2 * size]
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    return width, height, luma

# Calendar Favorites and meeting links never reach the network: their hosts resolve to nothing.
# Live Calendar counts down only to a meeting with a join link (calendar_app.py live rows).
SWITCHES = ['--host-resolver-rules=MAP calendar.google.com ~NOTFOUND, MAP meet.google.com ~NOTFOUND', '--no-proxy-server']


def run(factory, results, tmp, wait_until):
    app = factory(urls=('about:blank',), fresh=True, extra_args=SWITCHES, extra_env={'OPEN_E2E_NO_SYSTEM_SETTINGS': '1'})

    def check(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('library_ux1 %-48s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def lib(**kw): return app.call('library', **kw)

    def e01():
        sx, sy, sw, sh = app.call('window-state')['screenFrame']
        lib(action='open', section='downloads')
        assert wait_until(lambda: lib().get('open'), timeout=5, step=.05)
        for height in (800, 600, 480):
            app.call('window-frame', frame=[sx + 40, sy + 40, 1100, height], unconstrained=True)
            time.sleep(.5)
            state = lib()
            panel_height = state['panelFrame'][3]
            top, bottom = 52, panel_height - 56  # the rail viewport (LibraryPanelView.layout)
            rail = state.get('rail', [])
            frames = {t['id']: t['frame'] for t in rail}
            outside = {k: f for k, f in frames.items() if f[1] < top - .5 or f[1] + f[3] > bottom + .5}
            short = {k: f for k, f in frames.items() if f[3] < 44}
            # The standard window keeps Arc's 97 x 80 tiles (library-overlay.md).
            arc_size = height < 800 or all(f[2] == 97 and f[3] == 80 for f in frames.values())
            check('UX1_E01_rail_tiles_whole_h%d' % height, len(rail) >= 6 and not outside and not short and arc_size,
                  panelHeight=panel_height, viewport=[top, bottom], outside=outside, short=short, frames=frames)
        lib(action='close')
        app.call('window-frame', frame=[sx + 40, sy + 40, 1280, 800], unconstrained=True)

    def plate_ink(fav, name):
        """Darkest and brightest luminance inside the countdown plate in a real window snapshot."""
        plate = app.call('favorite-badge', favorite=fav).get('subtitleWindowFrame') or []
        path = os.path.join(tmp, 'ux1-calendar-plate-%s.png' % name)
        app.call('snapshot', path=path)
        width, height, luma = png_luma(path)
        scale = width / app.call('window-state')['frame'][2]
        darkest, brightest = 1.0, 0.0
        if len(plate) == 4:
            x0, y0 = int(plate[0] * scale), int(plate[1] * scale)
            x1, y1 = int((plate[0] + plate[2]) * scale), int((plate[1] + plate[3]) * scale)
            for y in range(max(0, y0), min(height, y1)):
                for x in range(max(0, x0), min(width, x1)):
                    value = luma(x, y)
                    darkest, brightest = min(darkest, value), max(brightest, value)
        return plate, round(darkest, 3), round(brightest, 3)

    def e02():
        # Review r1 #1: start from Light (what a Light-mode host gives a fresh App) and switch to
        # Dark BEFORE the countdown exists, so the plate is created with dark ink whatever the
        # host's appearance. Installing the fixture first on a Light host created the plate with
        # light-mode ink, and the old code then passed without the fix.
        app.call('appearance', name='light'); time.sleep(.5)
        # As calendar_app.py: the tab commits its (unresolvable) calendar URL before it becomes a Favorite.
        fav = app.call('open', url='https://calendar.google.com/calendar/u/0/r/day')['id']
        try: app.call('wait', tab=fav, timeout=30)
        except RuntimeError: pass
        app.call('favorite', tab=fav)
        blank = app.call('open', url='about:blank')['id']
        try: app.call('wait', tab=blank, timeout=30)
        except RuntimeError: pass
        app.call('appearance', name='dark'); time.sleep(1.0)
        app.call('calendar', action='fixture', access='granted', events=[{'id': 'ux1', 'title': 'UX1 sync', 'start': 4, 'end': 34,
                                                                         'url': 'https://meet.google.com/ux1-test-row'}])
        wait_until(lambda: (app.call('calendar', action='live').get('tiles') or None), timeout=8, step=.1)
        shown = wait_until(lambda: (lambda b: b if b.get('subtitleShown') and len(b.get('subtitleWindowFrame') or []) == 4
                                    and b['subtitleWindowFrame'][2] > 20 else None)(app.call('favorite-badge', favorite=fav)), timeout=8, step=.1)
        time.sleep(.5)
        plate, dark_darkest, dark_brightest = plate_ink(fav, 'dark')
        app.call('appearance', name='light'); time.sleep(1.0)
        plate, darkest, brightest = plate_ink(fav, 'light')
        # Dark mode draws light ink (0.87-0.92 at 70 %): its brightest pixel is well above 0.5.
        # After the switch to Light the ink is RGB 0.13 (luminance about 0.13; antialiasing lifts
        # it). The stale dark-mode ink on a light tile kept every plate pixel above 0.6.
        check('UX1_E02_calendar_plate_dark_ink_after_dark_to_light', shown and len(plate) == 4
              and dark_brightest > 0.5 and darkest < 0.4,
              plate=plate, darkModeBrightest=dark_brightest, darkModeDarkest=dark_darkest,
              darkestLuminance=darkest, brightestLuminance=brightest)
        app.call('appearance', name='system')

    rows_by_key = [
        ('E01', e01, ['UX1_E01_rail_tiles_whole_h800', 'UX1_E01_rail_tiles_whole_h600', 'UX1_E01_rail_tiles_whole_h480']),
        ('E02', e02, ['UX1_E02_calendar_plate_dark_ink_after_dark_to_light']),
    ]
    try:
        for key, body, names in rows_by_key:
            try: body()
            except Exception as error:
                for name in names:
                    if name not in results: check(name, False, error='%s: %s' % (type(error).__name__, error))
            finally:
                try:
                    if lib().get('open'): lib(action='close')
                except Exception: pass
    finally:
        app.quit()
