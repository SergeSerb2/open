"""UX round 1 (lane UXB): sidebar bottom bar and Space header geometry in the real App.

UXB-1  Every Space switcher item draws only between Home and +, inside the sidebar, and a click at
       the center of + hits +. 6 and 20 Spaces, at 228 pt and after a native resize drag to 164 pt.
UXB-2  The current Space's switcher item is fully visible, also after switching to the last Space.
UXB-3  A long Space name is drawn again for the new width after a native resize drag (no stale,
       hard-clipped title).

Geometry comes from `window-state.switcherGeometry`: frames in window-root coordinates and each
item's part left after every clipping ancestor. Widths change through real resize-handle drags.
Fixtures are synthetic (generated from Packages/OpenKit/Fixtures/space-schema1).
"""
import copy
import json
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


def _bar_problems(g):
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
    current = g['items'].get(g['current'])
    if current is None:
        problems.append('no switcher item for the current Space')
    elif any(abs(a - b) > 0.5 for a, b in zip(current['visible'], current['frame'])):
        problems.append('current Space item %d is not fully visible: frame %s visible %s'
                        % (current['index'], current['frame'], current['visible']))
    return problems


def run(factory, results, wait_until, scratch, root):
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
        finally:
            app.quit()
