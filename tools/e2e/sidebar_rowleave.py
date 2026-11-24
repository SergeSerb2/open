"""UX round 1, lane UXB, UXB-11 (UXD-W2-S1): a row the outline removes leaves as one piece.

The removal animation keeps a departing row view on screen for about 0.2 s. Its plate (the selected
fill) and a selected Split's pane plates must be gone from its first frame; before the fix a closed
selected row showed an empty selected plate for about 4 frames at 120 fps.

Cases, each read through `sidebar-departing-rows` (row views no longer mapped to an outline row)
right after the real action:
  tab     Cmd+W on the selected Today tab.
  folder  Collapse (production folder toggle) of folder A while the pointer hovers a child of its
          expanded subfolder B: B and B's visible children leave in the same animation, and the
          hovered grandchild must drop its plate too. (Delete Folder removes rows without animation.)
  split   Cmd+W on the selected pane of a two-pane Split: the Split row collapses and is removed.
"""
import copy
import json
import time
import uuid
from pathlib import Path

PAGE = 'data:text/html,%3Ctitle%3ERow%3C%2Ftitle%3E%3Cbody%20style%3D%22background%3A%23f4f4f2%22%3E'


def _tab(title, pinned=False):
    now = time.time()
    t = {'createdAt': now, 'id': str(uuid.uuid4()).upper(), 'isMuted': False, 'isUnread': False,
         'lastActiveAt': now, 'title': title, 'url': PAGE}
    if pinned: t['pinnedURL'] = PAGE
    return t


def run(factory, results, wait_until, scratch, root):
    data = json.loads(Path(root, 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json').read_text())
    space = copy.deepcopy(data['spaces'][0]); space['id'] = str(uuid.uuid4()).upper(); space['title'] = 'Rows'
    child, sibling = _tab('Grandchild', True), _tab('Grandchild 2', True)
    folder_id, inner_id = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    inner = {'folder': {'_0': {'id': inner_id, 'isExpanded': True, 'title': 'Inner folder',
                               'children': [{'tab': {'_0': child}}, {'tab': {'_0': sibling}}]}}}
    space['pinned'] = [{'folder': {'_0': {'id': folder_id, 'isExpanded': True, 'title': 'Outer folder',
                                          'children': [inner, {'tab': {'_0': _tab('Outer child', True)}}]}}},
                       {'tab': {'_0': _tab('Pinned page', True)}}]
    closed, left, right = _tab('Close me'), _tab('Left pane'), _tab('Right pane')
    split = {'split': {'_0': {'fractions': [], 'id': str(uuid.uuid4()).upper(), 'orientation': 'horizontal',
                              'panes': [left, right]}}}
    space['today'] = [{'tab': {'_0': closed}}, {'tab': {'_0': _tab('Stays')}}, split, {'tab': {'_0': _tab('Last')}}]
    data['spaces'] = [space]
    window = data['windows'][0]
    window.update(focusedSpaceID=space['id'], sidebarWidth=228, sidebarMode='anchored', frameX=80, frameY=80,
                  frameWidth=1280, frameHeight=800, selectedNodeBySpace={space['id']: closed['id']})
    data['windows'] = [window]
    fixture = Path(scratch, 'sidebar-rowleave.json'); fixture.write_text(json.dumps(data))
    app = factory(urls=(), snapshot=str(fixture))
    cases = {}
    try:
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)

        def departing(timeout=1.0):
            seen = wait_until(lambda: app.call('sidebar-departing-rows') or None, timeout=timeout, step=.003)
            return seen or []

        def check(name, rows, need):
            # Model opacity and running fill animations; the presentation can lag the commit by a turn.
            problems = [r for r in rows if r['fillOpacity'] > 0 or r['fillAnimations'] or r['splitPlates'] or r['ringVisible']]
            cases[name] = {'ok': need(rows) and not problems, 'departing': rows, 'problems': problems}

        def select(tab_id):
            app.call('select', tab=tab_id); time.sleep(.6)

        select(closed['id'])
        app.call('key', key='w', modifiers=['cmd'], route='app')
        check('tab', departing(), lambda rows: any(r['current'] or r['kind'] == 'Tab' for r in rows))
        time.sleep(.6)

        point = app.call('sidebar-row', node=child['id'])['point']
        app.call('mouse', action='hover', x=point[0], y=point[1]); time.sleep(.4)
        app.call('folder-toggle', folder=folder_id)
        rows = departing()
        check('folder', rows, lambda rows: len(rows) >= 3)  # inner folder, its two children, the outer child
        app.call('mouse', action='hover', x=700, y=400)
        time.sleep(.6)

        select(left['id'])
        app.call('key', key='w', modifiers=['cmd'], route='app')
        check('split', departing(), lambda rows: any(r['kind'] == 'Split' for r in rows))
    finally:
        app.quit()
    results['UXB11_removed_row_leaves_as_one_piece'] = {'ok': len(cases) == 3 and all(c['ok'] for c in cases.values()),
                                                        'cases': cases}
