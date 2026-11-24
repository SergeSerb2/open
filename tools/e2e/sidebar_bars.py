"""UX round 1 (lane UXB): sidebar bottom bar and Space header geometry in the real App.

UXB-1  Every Space switcher item draws only between Home and +, inside the sidebar, and a click at
       the center of + hits +. 6 and 20 Spaces, at 228 pt and after a native resize drag to 164 pt.
UXB-2  The current Space's switcher item is fully visible, also after switching to the last Space.
UXB-3  A long Space name is drawn again for the new width after a native resize drag (no stale,
       hard-clipped title).
UXB-4  Real scroll events (a trackpad gesture and a vertical mouse wheel, sent through NSApp.sendEvent)
       scroll an overflowing strip, keep UXB-1 true, and turn the edge fades on and off with what
       is hidden. The same events move nothing when the Spaces fit.
UXB-5  Fit and near-fit widths (6 Spaces at 300, 288 and 280 pt): no fade where no icon is hidden.
UXB-6  Resize sweep 164 -> 176 pt in 1 pt drags with the middle Space current: the strip offset only
       moves one way (no jitter) and the current icon's ink stays out of both fades.
UXB-8  A Space switch always shows the new Space's list: 4 launches (emoji or letter icons, Reduce
       Motion on and off) visit 11 new Spaces each; after every switch the list area must have
       drawn pixels (contrast) and the focused page must sit at index x width in the strip.
UXB-9  Hovering a long-title pinned tab, pinned folder and Today tab (at 228 pt and after a native
       drag to 164 pt): the title is drawn for its current width and ends before the row's x or -.
UXB-10 A letter Space icon in the header draws like the title: its darkest ink within 25 levels of
       the title's, and its ink between the title's cap top and baseline (1 pt slack).
UXB-7  At 164 pt, moving the current Space from index 0 to 2 (real Space Manager drag; the Library
       shows about three columns, so both must be on screen) and undoing it (Cmd+Z) keeps the
       current Space visible and out of the fades.

Geometry comes from `window-state.switcherGeometry`: frames in window-root coordinates and each
item's part left after every clipping ancestor. Widths change through real resize-handle drags.
Fixtures are synthetic (generated from Packages/OpenKit/Fixtures/space-schema1).
"""
import copy
import json
import os
import time
import uuid
from pathlib import Path

EMOJI = ['🌿', '📘', '🪐', '🚲', '🙂', '🎒', '🧪', '🎧', '🍜', '🏔️', '⚽️', '🧭', '🎨', '📷', '🛠️', '🌙', '🍀', '🐙', '🎯', '🧩']
PAGE = 'data:text/html,%3Ctitle%3EBars%3C%2Ftitle%3E%3Cbody%20style%3D%22background%3A%23f4f4f2%22%3E'
LONG = 'Space %d with a rather long name that will not fit'


def _fixture(root, scratch, count):
    data = json.loads(Path(root, 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json').read_text())
    template = data['spaces'][0]
    spaces = []
    for i in range(count):
        space = copy.deepcopy(template)
        space['id'] = str(uuid.uuid4()).upper()
        space['icon'] = {'emoji': {'_0': EMOJI[i % len(EMOJI)]}}
        space['title'] = LONG % (i + 1)
        now = time.time()
        space['pinned'] = []
        space['today'] = [{'tab': {'_0': {'createdAt': now, 'id': str(uuid.uuid4()).upper(), 'isMuted': False,
                                          'isUnread': False, 'lastActiveAt': now, 'title': 'Bars', 'url': PAGE}}}]
        spaces.append(space)
    data['spaces'] = spaces
    window = data['windows'][0]
    window.update(focusedSpaceID=spaces[0]['id'], sidebarWidth=228, sidebarMode='anchored', frameX=80, frameY=80,
                  frameWidth=1280, frameHeight=800, selectedNodeBySpace={})
    data['windows'] = [window]
    path = Path(scratch, 'sidebar-bars-%d.json' % count)
    path.write_text(json.dumps(data))
    return str(path), [s['id'] for s in spaces]


def _inside(inner, outer, slack=0.5):
    return (inner[0] >= outer[0] - slack and inner[1] >= outer[1] - slack
            and inner[0] + inner[2] <= outer[0] + outer[2] + slack and inner[1] + inner[3] <= outer[1] + outer[3] + slack)


def _bar_problems(g, current=True):
    """Layout faults in one switcherGeometry reading (empty when the bar is clean)."""
    home, plus, sidebar = g['home'], g['plus'], g['sidebar']
    # The strip runs from Home's right edge to +'s left edge, at the bar's height.
    strip = [home[0] + home[2], g['bottomBar'][1], plus[0] - home[0] - home[2], g['bottomBar'][3]]
    problems = []
    for sid, item in g['items'].items():
        v = item['visible']
        if v[2] <= 0 or v[3] <= 0:
            continue
        if not _inside(v, strip):
            problems.append('item %d draws outside the strip %s: %s' % (item['index'], strip, v))
        if not _inside(v, sidebar):
            problems.append('item %d draws outside the sidebar %s: %s' % (item['index'], sidebar, v))
    if not g['plusHit']:
        problems.append('a click at the center of + does not hit +')
    current = g['items'].get(g['current']) if current else True
    if current is True:
        pass
    elif current is None:
        problems.append('no switcher item for the current Space')
    else:
        # The plate (the frame inset 1 pt on each side) must show whole; the 1 pt slop may clip.
        f, v = current['frame'], current['visible']
        if not (v[0] <= f[0] + 1.5 and v[0] + v[2] >= f[0] + f[2] - 1.5 and v[2] > 0):
            problems.append('current Space item %d is not fully visible: frame %s visible %s'
                            % (current['index'], f, v))
    fade = g['fade']
    if fade['masked'] != (fade['left'] or fade['right']):
        problems.append('fade mask %s does not match hidden edges %s' % (fade['masked'], fade))
    return problems


def run(factory, results, wait_until, scratch, root, read_image=None):
    only = set(filter(None, os.environ.get('OPEN_UXB_ONLY', '').split(',')))  # e.g. "8,9,10" for iteration
    if only:
        if '8' in only: _switch_draw_rows(factory, results, scratch, root, read_image)
        if '9' in only: _hover_title_rows(factory, results, wait_until, scratch, root)
        if '10' in only: _letter_icon_rows(factory, results, scratch, root, read_image)
        return
    for count in (6, 20):
        fixture, ids = _fixture(root, scratch, count)
        app = factory(urls=(), snapshot=fixture)
        try:
            app.call('window-focus', id=app.call('window-state')['id'], activate=True)

            def geometry(): return app.call('window-state')['switcherGeometry']

            def resize(width):
                state = app.call('window-state')
                y = state['frame'][3] / 2
                app.call('mouse', **{'from': [state['sidebarWidth'] - 1, y], 'to': [width, y]})
                wait_until(lambda: abs(app.call('window-state')['sidebarWidth'] - width) < 1, timeout=5, step=.05)
                time.sleep(.4)
                return app.call('window-state')['sidebarWidth']

            for width in (228, 164):
                actual = resize(width) if width != 228 else app.call('window-state')['sidebarWidth']
                if count == 6 and width == 164:
                    # UXB-3: the current Space's header (drawn at 228) after the 228 -> 164 drag.
                    def drawn():
                        d = app.call('space-header')['titleDraw']
                        return d if d and abs(d['drawnForWidth'] - d['width']) < 0.5 else None
                    settled = wait_until(drawn, timeout=3, step=.05)
                    draw = settled or app.call('space-header')['titleDraw']
                    results['UXB3_space_title_redrawn_after_resize'] = {
                        'ok': bool(settled) and draw['lineWidth'] <= draw['width'] + 0.5 and draw['maxX'] <= actual + 0.5,
                        'width': actual, 'titleDraw': draw}
                app.call('space', space=ids[0])
                time.sleep(.6)
                first = geometry()
                p1 = _bar_problems(first)
                results['UXB1_switcher_%dspaces_w%d' % (count, width)] = {
                    'ok': not p1 and abs(actual - width) < 1, 'width': actual, 'problems': p1, 'geometry': first}
                app.call('space', space=ids[-1])
                time.sleep(.8)
                last = geometry()
                p2 = _bar_problems(last)
                results['UXB2_current_last_%dspaces_w%d' % (count, width)] = {
                    'ok': not p2 and last['current'] == ids[-1], 'problems': p2, 'geometry': last}
            if count == 6:
                _scroll_rows(app, results, wait_until, ids, resize, geometry)
                _reveal_rows(app, results, wait_until, ids, resize, geometry)
        finally:
            app.quit()
    _hover_title_rows(factory, results, wait_until, scratch, root)
    if read_image is not None:
        _switch_draw_rows(factory, results, scratch, root, read_image)
        _letter_icon_rows(factory, results, scratch, root, read_image)


def _switch_draw_rows(factory, results, scratch, root, read_image):
    """UXB-8. A page built on first use must draw at its strip position (B7: AppKit reset its
    layer transform during the next layer-tree build, so the page sat off screen)."""
    letters = ['W', 'P', 'R', 'S', 'H', 'M', 'T', 'Q', 'A', 'B', 'K', 'L']
    summary, failures, restores = [], [], []
    for icons in ('emoji', 'letters'):
        for reduced in (False, True):
            data = json.loads(Path(root, 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json').read_text())
            template = data['spaces'][0]
            spaces = []
            for i in range(12):
                space = copy.deepcopy(template)
                space['id'] = str(uuid.uuid4()).upper(); space['title'] = 'Space %d' % (i + 1)
                space['icon'] = {'emoji': {'_0': (EMOJI if icons == 'emoji' else letters)[i % 12]}}
                now = time.time()
                space['today'] = [{'tab': {'_0': {'createdAt': now, 'id': str(uuid.uuid4()).upper(), 'isMuted': False, 'isUnread': False,
                                                  'lastActiveAt': now, 'title': 'Row %d' % j, 'url': PAGE}}} for j in range(2)]
                spaces.append(space)
            data['spaces'] = spaces
            window = data['windows'][0]
            window.update(focusedSpaceID=spaces[0]['id'], sidebarWidth=228, sidebarMode='anchored', frameX=80, frameY=80,
                          frameWidth=1280, frameHeight=800, selectedNodeBySpace={})
            data['windows'] = [window]
            fixture = Path(scratch, 'sidebar-bars-switch-%s.json' % icons); fixture.write_text(json.dumps(data))
            app = factory(urls=(), snapshot=str(fixture))
            try:
                app.call('window-focus', id=app.call('window-state')['id'], activate=True)
                app.call('window-motion', reduced=reduced)
                for index in range(1, 12):
                    app.call('space', space=spaces[index]['id']); time.sleep(.5 if reduced else .8)
                    png = str(Path(scratch, 'uxb8-%s-%s-%02d.png' % (icons, reduced, index)))
                    app.call('snapshot', path=png)
                    state = app.call('window-state')
                    width, height, pixel = read_image(png)
                    k = width / state['frame'][2]
                    lum = [sum(pixel(int(x * k), int(y * k))) / 3 for x in range(12, 200, 3) for y in range(204, 330, 3)]
                    mean = sum(lum) / len(lum); spread = (sum((v - mean) ** 2 for v in lum) / len(lum)) ** .5
                    pager = state['pagerState']
                    page = next((p for p in pager['pages'] if p['index'] == index), None)
                    placed = page is not None and abs(page['translation'] - index * pager['width']) < .5 and not page['layerHidden']
                    row = {'icons': icons, 'reduced': reduced, 'index': index, 'contrast': round(spread, 1), 'placed': placed,
                           'translation': page and page['translation']}
                    summary.append(row)
                    if spread < 12 or not placed: failures.append(row)
                    try: os.remove(png)
                    except OSError: pass
                restores.append(app.call('window-state')['pagerState'].get('translationRestores'))
            finally:
                try: app.call('window-motion', reduced=False)
                except Exception: pass
                app.quit()
    results['UXB8_space_switch_draws_list'] = {'ok': not failures and len(summary) == 44, 'switches': len(summary),
                                               'failures': failures, 'restoresPerLaunch': restores}


def _scroll_rows(app, results, wait_until, ids, resize, geometry):
    def scroll(g, **event):
        s = g['strip']
        app.call('mouse', action='scroll', x=s[0] + s[2] / 2, y=s[1] + s[3] / 2, **event)

    def gesture(g, dx):
        # The first event carries the horizontal delta, as a real trackpad's does (AppKit can lock a
        # gesture's axis on it).
        scroll(g, dx=dx / 5, dy=0, phase='began')
        for _ in range(4): scroll(g, dx=dx / 5, dy=0, phase='changed')
        scroll(g, dx=0, dy=0, phase='ended')
        time.sleep(1.2)  # let an elastic bounce at an end settle

    resize(228)
    app.call('space', space=ids[0]); time.sleep(.6)
    start = geometry()
    # The strip hands gestures to NSScrollView unchanged. Synthetic gesture events move it by an
    # AppKit-chosen distance, and in some runs not at all (28, 60, 0, 24, 0, 0 pt over six runs on
    # the M5), so the gesture gets up to three attempts, each recorded. The wheel steps below are
    # Open's own code and are exact.
    attempts = []
    for _ in range(3):
        gesture(start, -30)
        swiped = geometry()
        attempts.append(swiped['offset'])
        if swiped['offset'] > 0: break
    scroll(swiped, dx=0, dy=-400, phase='none'); time.sleep(1.0)  # a vertical wheel to the end
    wheeled = geometry()
    scroll(wheeled, dx=0, dy=400, phase='none'); time.sleep(1.0)  # and back to the start
    back = geometry()
    problems = [p for g in (swiped, wheeled, back) for p in _bar_problems(dict(g, current='none'), current=False)]
    results['UXB4_scroll_overflow_6spaces_w228'] = {
        'ok': start['scrollable'] and start['offset'] == 0 and start['fade'] == {'left': False, 'right': True, 'masked': True}
              and swiped['offset'] > 0 and wheeled['offset'] == 60  # 6 × 34 − 144 = 60 pt; AppKit sets the gesture's distance
              and wheeled['fade']['left'] and not wheeled['fade']['right'] and back['offset'] == 0
              and not back['fade']['left'] and back['fade']['right'] and not problems,
        'offsets': [start['offset'], swiped['offset'], wheeled['offset'], back['offset']], 'gestureAttempts': attempts,
        'fades': [start['fade'], swiped['fade'], wheeled['fade'], back['fade']], 'problems': problems}
    rows = {}
    for width in (300, 288, 280):
        actual = resize(width)
        g = geometry()
        gesture(g, -60)
        scroll(g, dx=0, dy=-200, phase='none'); time.sleep(1.0)
        after = geometry()
        fits = width >= 288
        rows[width] = {'width': actual, 'scrollable': g['scrollable'], 'offsetAfterScroll': after['offset'],
                       'fade': after['fade'], 'problems': _bar_problems(after, current=False)}
        rows[width]['ok'] = (abs(actual - width) < 1 and g['scrollable'] == (not fits)
                             and (after['offset'] == 0 if fits else 0 <= after['offset'] <= 204 - (actual - 84))
                             and after['fade'] == {'left': False, 'right': False, 'masked': False}
                             and not rows[width]['problems'])
    results['UXB5_fit_and_near_fit_no_fade'] = {'ok': all(r['ok'] for r in rows.values()), 'widths': rows}


def _ink_clear(g):
    """The current item's ink (emoji 14 pt centered in the 36 pt frame) lies outside each active fade."""
    current = g['items'][g['current']]
    strip, f = g['strip'], current['frame']
    ink = (f[0] + 11 - strip[0], f[0] + 25 - strip[0])  # in strip coordinates
    fade = 28
    return ((not g['fade']['left'] or ink[0] >= fade - 0.5)
            and (not g['fade']['right'] or ink[1] <= strip[2] - fade + 0.5))


def _reveal_rows(app, results, wait_until, ids, resize, geometry):
    middle = ids[len(ids) // 2]
    resize(164)
    app.call('space', space=middle); time.sleep(.8)
    steps = []
    for width in range(164, 177):
        if width != 164: resize(width)
        g = geometry()
        steps.append({'width': app.call('window-state')['sidebarWidth'], 'offset': g['offset'], 'inkClear': _ink_clear(g),
                      'fade': g['fade'], 'problems': _bar_problems(g)})
    offsets = [x['offset'] for x in steps]
    monotonic = all(b <= a + 0.5 for a, b in zip(offsets, offsets[1:]))
    results['UXB6_resize_sweep_middle_space'] = {
        'ok': monotonic and all(x['inkClear'] and not x['problems'] for x in steps), 'monotonic': monotonic, 'steps': steps}

    # UXB-7: reorder the current (first) Space and back through the real Manager.
    resize(164)
    app.call('space', space=ids[0]); time.sleep(.8)
    window = app.call('window-state')['id']
    before = geometry()
    app.call('library-open', entry='space-menu'); time.sleep(.8)
    app.call('space-manager-drag', space=ids[0], to=2); time.sleep(.5)
    app.call('library-close')
    app.call('window-focus', id=window, activate=True); time.sleep(.6)
    moved = geometry()
    app.call('key', key='z', modifiers=['cmd'], route='app'); time.sleep(.8)
    undone = geometry()
    rows = {name: {'index': g['items'][ids[0]]['index'], 'offset': g['offset'], 'problems': _bar_problems(g),
                   'inkClear': _ink_clear(g)}
            for name, g in (('before', before), ('moved', moved), ('undone', undone))}
    results['UXB7_reorder_keeps_current_visible'] = {
        'ok': rows['before']['index'] == 0 and rows['moved']['index'] == 2 and rows['undone']['index'] == 0
              and all(not r['problems'] and r['inkClear'] for r in rows.values()), 'rows': rows}


def _tab(title, pinned=False):
    now = time.time()
    t = {'createdAt': now, 'id': str(uuid.uuid4()).upper(), 'isMuted': False, 'isUnread': False,
         'lastActiveAt': now, 'title': title, 'url': PAGE}
    if pinned: t['pinnedURL'] = PAGE
    return {'tab': {'_0': t}}


def _hover_title_rows(factory, results, wait_until, scratch, root):
    """UXB-9 (UXD): a row's x / - must not sit on a title drawn for an older, wider frame."""
    data = json.loads(Path(root, 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json').read_text())
    space = copy.deepcopy(data['spaces'][0]); space['id'] = str(uuid.uuid4()).upper(); space['title'] = 'Rows'
    long_pinned = _tab('A really long pinned article title that keeps going', pinned=True)
    folder = {'folder': {'_0': {'id': str(uuid.uuid4()).upper(), 'isExpanded': True, 'title': 'Reading list with a long folder name',
                                'children': [_tab('Morning news', pinned=True)]}}}
    long_today = _tab('A very long today tab title that runs past the edge')
    space['pinned'] = [_tab('Lemon pasta recipe', pinned=True), long_pinned, folder]
    space['today'] = [_tab('Trip planning'), long_today]
    data['spaces'] = [space]
    window = data['windows'][0]
    window.update(focusedSpaceID=space['id'], sidebarWidth=228, sidebarMode='anchored', frameX=80, frameY=80,
                  frameWidth=1280, frameHeight=800, selectedNodeBySpace={space['id']: space['today'][0]['tab']['_0']['id']})
    data['windows'] = [window]
    fixture = Path(scratch, 'sidebar-bars-rows.json'); fixture.write_text(json.dumps(data))
    ids = {'pinned': long_pinned['tab']['_0']['id'], 'folder': folder['folder']['_0']['id'], 'today': long_today['tab']['_0']['id']}
    app = factory(urls=(), snapshot=str(fixture))
    rows, problems = {}, []
    try:
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        for phase in ('w228', 'drag164'):
            if phase == 'drag164':
                state = app.call('window-state'); y = state['frame'][3] / 2
                app.call('mouse', **{'from': [state['sidebarWidth'] - 1, y], 'to': [164, y]})
                wait_until(lambda: abs(app.call('window-state')['sidebarWidth'] - 164) < 1, timeout=5, step=.05)
            for name, node in ids.items():
                point = app.call('sidebar-row', node=node)['point']
                app.call('mouse', action='hover', x=point[0], y=point[1])
                def settled():
                    d = app.call('sidebar-row', node=node)['titleDraw']
                    return d if d and d.get('buttonMinX') is not None and abs(d['drawnForWidth'] - d['width']) < .5 else None
                draw = wait_until(settled, timeout=3, step=.05) or app.call('sidebar-row', node=node)['titleDraw']
                key = '%s-%s' % (phase, name); rows[key] = draw
                if not draw or draw.get('buttonMinX') is None:
                    problems.append('%s: no row button shown on hover' % key)
                elif abs(draw['drawnForWidth'] - draw['width']) >= .5 or draw['lineWidth'] > draw['width'] + .5 \
                        or draw['titleMaxX'] > draw['buttonMinX'] + .5:
                    problems.append('%s: title drawn for %s, width %s, line %.1f, ends %.1f, button at %.1f' % (
                        key, draw['drawnForWidth'], draw['width'], draw['lineWidth'], draw['titleMaxX'], draw['buttonMinX']))
            app.call('mouse', action='hover', x=700, y=400)
    finally:
        app.quit()
    results['UXB9_hover_title_clears_row_button'] = {'ok': not problems and len(rows) == 6, 'problems': problems, 'rows': rows}


def _letter_icon_rows(factory, results, scratch, root, read_image):
    """UXB-10 (E10): a letter icon in the Space header draws in the title's ink, cap-aligned."""
    data = json.loads(Path(root, 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json').read_text())
    space = copy.deepcopy(data['spaces'][0]); space['id'] = str(uuid.uuid4()).upper()
    space['title'] = 'Studio'; space['icon'] = {'emoji': {'_0': 'P'}}
    data['spaces'] = [space]
    window = data['windows'][0]
    window.update(focusedSpaceID=space['id'], sidebarWidth=228, sidebarMode='anchored', frameX=80, frameY=80,
                  frameWidth=1280, frameHeight=800, selectedNodeBySpace={})
    data['windows'] = [window]
    fixture = Path(scratch, 'sidebar-bars-letter.json'); fixture.write_text(json.dumps(data))
    app = factory(urls=(), snapshot=str(fixture))
    try:
        app.call('window-focus', id=app.call('window-state')['id'], activate=True); time.sleep(.6)
        png = str(Path(scratch, 'uxb10-letter.png')); app.call('snapshot', path=png)
        state = app.call('window-state')
    finally:
        app.quit()
    width, height, pixel = read_image(png)
    k = width / state['frame'][2]
    baseline = state['chrome']['headerTitleBaseline']; band = state['chrome']['header']

    def ink(x0, x1):
        y0, y1 = band[1] + 2, band[1] + band[3] - 2
        bg = pixel(int(x0 * k), int(y0 * k))
        pts = [(x, y) for x in range(x0, x1) for y in range(y0, y1)
               if sum(abs(a - b) for a, b in zip(pixel(int(x * k), int(y * k)), bg)) > 60]
        if not pts: return None
        ys = [p[1] for p in pts]
        return {'top': min(ys), 'bottom': max(ys), 'darkest': min(sum(pixel(int(x * k), int(y * k))) / 3 for x, y in pts)}
    icon, title = ink(10, 40), ink(41, 60)  # the title's first letter, "S" (a capital, no descender)
    ok = bool(icon and title) and abs(icon['darkest'] - title['darkest']) <= 25 \
        and abs(icon['top'] - title['top']) <= 1 and abs(icon['bottom'] - (baseline - 1)) <= 1
    results['UXB10_letter_icon_matches_title'] = {'ok': ok, 'icon': icon, 'title': title, 'baseline': baseline}
    try: os.remove(png)
    except OSError: pass
