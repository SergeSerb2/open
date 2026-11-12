"""File ▸ Blank Window as its own window kind (capture C10), through the real App:
⌃⌘N from a normal window, the "This Window" sidebar (no Favorites, no Space dots, Library and
"+" in the bottom bar), the command bar open, tabs newest first, the row menu with Move to ▸,
⌘W on the last tab closing the window, and nothing of it in the session snapshot or after a
relaunch. Socket only; loopback pages.
"""
import json
import os
import time
from pathlib import Path


def run(factory, results, tmp, h):
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('blank-window %-34s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def key(name, *mods): return app.call('key', key=name, modifiers=list(mods), route='app')

    def blank(): return app.call('blank-window')

    server, origin = h._fixture_server('BlankWindow')
    app = factory(urls=(origin + '/main',), fresh=True)
    try:
        main_tab = app.call('tabs')[0]['id']
        app.call('wait', tab=main_tab)
        # Small, with room below and to the right: the +29 / +29 offset must not hit a screen edge.
        app.call('window-frame', frame=[100, 220, 900, 480])
        main = blank()
        main_window = main['window']
        main_tabs = [t['id'] for t in app.call('tabs')]

        # 1. ⌃⌘N: a second window of its own kind, same size, offset +29 / +29 pt, command bar open.
        key('n', 'control', 'command')
        b = h.wait_until(lambda: (lambda s: s if s['isBlankWindow'] else None)(blank()), timeout=8, step=.1) or blank()
        bar = h.wait_until(lambda: (lambda s: s if s.get('presented') else None)(app.call('commandbar-state')), timeout=5, step=.1) or app.call('commandbar-state')
        mf, bf = main['frame'], b['frame']
        row('blank_window_opens', b['isBlankWindow'] and not main['isBlankWindow'] and b['window'] != main_window and b['browserWindows'] == 2
            and abs(bf[2] - mf[2]) < 1 and abs(bf[3] - mf[3]) < 1 and abs(bf[0] - mf[0] - 29) < 1 and abs(mf[1] - bf[1] - 29) < 1
            and bar.get('presented'), main=mf, blank=bf, commandBar=bar.get('presented'))
        row('this_window_sidebar', b['headerTitle'] == 'This Window' and not b['headerHidden'] and not b['favoritesShown']
            and b['spaceDots'] == 0 and b['libraryButtonShown'] and b['plusShown'] and b['windowTitle'] == 'Space 1'
            and app.call('tabs') == [] and main['spaceDots'] >= 1, state=b, mainDots=main['spaceDots'])
        key('escape')
        h.wait_until(lambda: not app.call('commandbar-state').get('presented') or None, timeout=5, step=.1)

        # 2. Pages opened in it are listed under "This Window", newest first; the title follows the tab.
        first = h.new_tab(app, origin + '/one')
        second = h.new_tab(app, origin + '/two')
        tabs = app.call('tabs')
        titled = h.wait_until(lambda: (lambda s: s if 'two' in s['windowTitle'] else None)(blank()), timeout=5, step=.1) or blank()
        row('tabs_newest_first', [t['id'] for t in tabs] == [second, first] and all(t['section'] == 'today' for t in tabs)
            and 'two' in titled['windowTitle'] and titled['profileDirectory'] == main['profileDirectory'],
            tabs=[(t['id'], t['url']) for t in tabs], title=titled['windowTitle'])

        # 3. The row menu is the ordinary Today-tab menu; Move to ▸ lists the browser's Spaces.
        menu = app.call('sidebar-menu-state', node=first, item='Move to')
        spaces = [s['title'] for s in app.call('spaces')]
        row('row_menu_has_move_to', menu['enabled'] and app.call('sidebar-menu-state', node=first, item='Duplicate')['enabled'],
            menu=menu, blankSpaces=spaces)

        # 4. The snapshot holds nothing of the Blank Window.
        snapshot = json.loads(Path(app.call('save')).read_text())
        text = json.dumps(snapshot)
        row('not_in_session_snapshot', not b['inSnapshotModel'] and '/one' not in text and '/two' not in text and b['window'].lower() not in text.lower(),
            windows=len(snapshot.get('windows', [])))

        frames = os.path.join(h.ROOT, '.re', 'nt-frames'); os.makedirs(frames, exist_ok=True)
        app.call('snapshot', path=os.path.join(frames, 'blank-window.png'))

        # 5. Move to ▸ ‹Space›: the tab leaves this window and lands at the top of that Space's Today list.
        target = app.call('spaces')[0]
        title = target['title'] or 'Space 1'
        app.call('sidebar-menu', node=second, items=['Move to', title])
        one_left = h.wait_until(lambda: (lambda t: t if len(t) == 1 else None)(app.call('tabs')), timeout=5, step=.1) or app.call('tabs')
        saved = json.loads(Path(app.call('save')).read_text())
        moved = '/two' in json.dumps(saved) and '/one' not in json.dumps(saved)
        still_blank = blank()['isBlankWindow']
        row('move_to_space', len(one_left) == 1 and one_left[0]['id'] == first and moved and still_blank, target=title, movedIntoSnapshot=moved)

        # 6. ⌘W on the last tab closes the whole window, with no prompt.
        key('w', 'command')
        closed = h.wait_until(lambda: (lambda s: s if s['browserWindows'] == 1 and not s['isBlankWindow'] else None)(blank()), timeout=8, step=.1) or blank()
        after = app.call('tabs')
        row('last_tab_closes_window', still_blank and closed['browserWindows'] == 1 and closed['window'] == main_window
            and len(after) == len(main_tabs) + 1 and any('/two' in t['url'] for t in after) and set(main_tabs) <= {t['id'] for t in after}, after=closed)
    finally:
        app.quit()

    # 7. Relaunch: one normal window; the Blank Window is not restored (its moved tab stays in the Space).
    app = factory(urls=())
    try:
        s = app.call('blank-window')
        row('not_restored_at_relaunch', s['browserWindows'] == 1 and not s['isBlankWindow']
            and all('/one' not in t['url'] for t in app.call('tabs')) and any('/two' in t['url'] for t in app.call('tabs')), state=s)
    finally:
        app.quit()
        server.shutdown()
