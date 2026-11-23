"""Bug sweep r6 (SIDEPAGE6) sidebar rows, in the real App through the automation socket.

P-04: moving the current tab to another Space (Move to, a Space-icon drop, a drop into a
      second window) selects a neighbour; the source Space is not left blank.
P-03: a link dropped on another Space's icon opens there in the background; this Space keeps
      its selected tab.
P-05: Remove Pin (Cmd+D) on one pinned tab puts it at the top of Today, as a selection does.
P-02: Restore Last Closed Tab brings back the tab the user closed, not a later auto-archived one.
"""
import json
import time
from pathlib import Path


def run(factory, results, wait_until, tmp):
    app = factory(urls=(), fresh=True)
    try:
        _rows(app, results, wait_until, tmp)
    finally:
        try: app.call('archive-clock', reset=True)
        except Exception: pass
        app.quit()


def _rows(app, results, wait_until, tmp):
    def settle(): time.sleep(.4)
    def opened(name):
        path = Path(tmp) / ('r6-' + name.lower().replace(' ', '-') + '.html')
        path.write_text('<title>R6 %s</title><h1>%s</h1>' % (name, name))
        node = app.call('open', url=path.as_uri())['id']; app.call('wait', tab=node); return node
    def state(window=None): return app.call('window-state', **({'id': window} if window else {}))
    def tree():
        t = app.call('sidebar-tree')
        return [n['id'] for n in t['pinned']], [n['id'] for n in t['today']]
    def check(name, ok, **detail):
        results[name] = dict(ok=bool(ok), **detail)

    a = app.call('space-create', title='R6 A'); app.call('space', space=a); settle()
    b = app.call('space-create', title='R6 B'); app.call('space', space=a); settle()
    window = state()['id']

    # P-04 Move to: the moved current tab leaves a neighbour selected, not a blank Space.
    keep = opened('Keep'); moved = opened('Moved')   # Today: Moved Keep
    app.call('select', tab=moved); settle()
    items = app.call('sidebar-menu-items', node=moved, path='Move to')['items']
    target = next((i for i in items if 'R6 B' in i), None)
    if target: app.call('sidebar-menu', node=moved, item='Move to/' + target); settle()
    after = state()
    check('r6_move_to_space_selects_neighbour', target and after['space'] == a and after['selected'] == keep
          and keep in after['shownPages'], items=items, state={k: after[k] for k in ('space', 'selected', 'shownPages')}, keep=keep, moved=moved)

    # P-04, review round 1: with three tabs the moving window picks the neighbour, not the
    # previously selected tab, and its title follows. Today: T3 T2 T1 Keep; T1 then T3 selected.
    t1 = opened('T1'); t2 = opened('T2'); t3 = opened('T3')
    app.call('select', tab=t1); settle(); app.call('select', tab=t3); settle()
    app.call('sidebar-menu', node=t3, item='Move to/' + (target or 'R6 B')); settle()
    after = state()
    title = next((w['title'] for w in app.call('shell-windows') if w['id'] == window), None)
    check('r6_move_to_space_neighbour_not_history', after['space'] == a and after['selected'] == t2 and t2 in after['shownPages']
          and title == 'R6 T2', state={k: after[k] for k in ('space', 'selected', 'shownPages')}, title=title, t1=t1, t2=t2, t3=t3)
    app.call('select', tab=keep); settle()
    for t in (t1, t2): app.call('close', tab=t)
    settle()

    # P-04 Space-icon drop of the current tab (released before the spring-load switch).
    dropped = opened('Dot Dropped'); app.call('select', tab=dropped); settle()
    drop = app.call('space-dot-drop', space=b, nodes=[dropped]); settle()
    after = state()
    check('r6_space_icon_drop_tab_selects_neighbour', drop.get('accepted') and after['space'] == a and after['selected'] == keep
          and keep in after['shownPages'], drop=drop, state={k: after[k] for k in ('space', 'selected', 'shownPages')}, keep=keep)

    # P-04 drop into a second window that shows another Space: the first window keeps a page.
    crossed = opened('Crossed'); app.call('select', tab=crossed); settle()
    app.call('command', id='new-window'); settle()
    second = wait_until(lambda: next((w['id'] for w in app.call('shell-windows') if w['id'] != window), None), timeout=5, step=.1)
    if app.call('commandbar-state').get('presented'): app.call('key', key='escape'); settle()
    app.call('space', space=b); settle()
    drop2 = app.call('sidebar-drop', window=second, nodes=[crossed], parent={'kind': 'today', 'id': b}, index=0); settle()
    first = state(window)
    check('r6_cross_window_drop_keeps_source_selection', drop2 and second and first['space'] == a and first['selected'] == keep
          and keep in first['shownPages'],
          drop=drop2, first={k: first[k] for k in ('space', 'selected', 'shownPages')}, keep=keep, crossed=crossed)
    if second:
        app.call('window-focus', id=second); app.call('window-close'); settle()
    app.call('window-focus', id=window); settle()

    # P-03: a link dropped on another Space's icon opens there; this Space keeps its tab.
    app.call('select', tab=keep); settle()
    link = (Path(tmp) / 'r6-link.html'); link.write_text('<title>R6 Link</title><h1>Link</h1>')
    url_drop = app.call('space-dot-drop', space=b, url=link.as_uri()); settle()
    after = state()
    # Read Space B from the saved snapshot: switching to B could select (and so read) the tab.
    def found(node):
        if isinstance(node, dict):
            if node.get('url') == link.as_uri() and 'id' in node: yield node
            for v in node.values(): yield from found(v)
        elif isinstance(node, list):
            for v in node: yield from found(v)
    with open(app.call('save')) as stream: snapshot = json.load(stream)
    space_b = next((s for s in snapshot['spaces'] if s['id'] == b), {})
    new_in_b = list(found(space_b.get('today', [])))
    unread = [n.get('isUnread', False) for n in new_in_b]
    check('r6_space_icon_link_drop_keeps_current_tab', url_drop.get('accepted') and after['space'] == a and after['selected'] == keep
          and keep in after['shownPages'] and len(new_in_b) == 1 and unread == [True],
          drop=url_drop, unread=unread, newTabs=[n.get('id') for n in new_in_b], state={k: after[k] for k in ('space', 'selected', 'shownPages')}, keep=keep)

    # P-05: Remove Pin on one tab puts it at the top of Today (as a selection's Unpin does).
    pin = opened('Pinned One'); app.call('pin', tab=pin); settle()
    opened('Today Top')
    app.call('select', tab=pin); settle()
    pinned_before, _ = tree()
    app.call('command', id='pin-unpin-tab'); settle()
    pinned_after, today_after = tree()
    check('r6_unpin_one_goes_to_top_of_today', pin in pinned_before and pin not in pinned_after and today_after[:1] == [pin],
          today=today_after[:4], pin=pin)

    # P-02: an auto-archive sweep after a close does not take Restore Last Closed Tab's place.
    closed = opened('Closed By User')
    app.call('close', tab=closed); settle()
    opened('Current')
    sweep = app.call('archive-sweep', offsetSeconds=13 * 3600); settle()
    rows = app.call('archive-list')['rows']
    auto_first = bool(rows) and rows[0]['reason'] == 'autoArchived'
    app.call('command', id='restore-last-closed-tab')
    restored = wait_until(lambda: any(t['id'] == closed for t in app.call('tabs')), timeout=5, step=.1)
    check('r6_restore_last_closed_skips_auto_archive', sweep.get('archivedCount', 0) > 0 and auto_first and restored,
          archivedCount=sweep.get('archivedCount'), archiveTop=[(r['title'], r['reason']) for r in rows[:4]], restored=bool(restored))

    _r8_rows(app, results, wait_until, tmp, window, b, target or 'R6 B', opened, state, check, settle)


ARM = '<button id=arm onclick="onbeforeunload=e=>{e.preventDefault();e.returnValue=1}">Arm</button>'


def _r8_rows(app, results, wait_until, tmp, window, b, target, opened, state, check, settle):
    """Bug sweep r8 (REGR8B) rows. Favorites stay empty until the last row adds one."""
    def guarded(name, body, cleanup=None):
        try: body()
        except Exception as error:  # A failed setup is a FAIL row, never a skipped one.
            check(name, False, error=repr(error))
        finally:
            try:
                if cleanup: cleanup()
            except Exception as error:
                print('sidebar r8 cleanup after %s: %r' % (name, error), flush=True)
    def title_of(w): return next((x['title'] for x in app.call('shell-windows') if x['id'] == w), None)
    def section(name): return [t['id'] for t in app.call('tabs') if t.get('section') == name]
    def answer_dialogs():
        for _ in range(3):
            if not app.call('dialog-state').get('pending'): break
            app.call('dialog-button', accept=True); settle()

    # B-R6-08: moving a Space's only tab to another Space leaves no tab here: the window title
    # follows (it kept the moved tab's title).
    solo_space = app.call('space-create', title='R8 Solo'); app.call('space', space=solo_space); settle()
    solo = opened('Solo')
    def move_last_tab():
        app.call('select', tab=solo); settle()
        favorites, others = section('favorites'), [t for t in section('today') + section('pinned') if t != solo]
        before = title_of(window)
        app.call('sidebar-menu', node=solo, item='Move to/' + target); settle()
        after = state(); title = title_of(window)
        check('r8_move_last_tab_out_updates_title', not favorites and not others and before == 'R6 Solo'
              and after['space'] == solo_space and after['selected'] == '' and title == 'Open',
              favorites=favorites, others=others, titleBefore=before, title=title,
              state={k: after[k] for k in ('space', 'selected', 'shownPages')}, solo=solo)
        # Control: Undo brings the tab back selected (the Space keeps its last selection), with its title.
        app.call('key', key='z', modifiers=['command'], route='app'); settle()
        undone = state(); title = title_of(window); back = section('today')
        check('r8_move_last_tab_undo_reselects', undone['space'] == solo_space and undone['selected'] == solo and title == 'R6 Solo',
              state={k: undone[k] for k in ('space', 'selected', 'shownPages')}, title=title, solo=solo, today=back,
              undo=app.call('undo-state'))
    guarded('r8_move_last_tab_out_updates_title', move_last_tab)

    # B-R6-10: Clear Unpinned Tabs waits for a page's beforeunload. When Today is already empty by
    # Leave (the tab was pinned meanwhile, as from a second window), nothing was cleared: no
    # "Cleared Tabs" toast, whose Undo would undo that pin.
    clear_space = app.call('space-create', title='R8 Clear'); app.call('space', space=clear_space); settle()
    page = Path(tmp) / 'r8-arm.html'; page.write_text('<title>R8 Arm</title>' + ARM)
    armed = app.call('open', url=page.as_uri())['id']; app.call('wait', tab=armed); settle()
    def clear_after_move():
        app.call('click', tab=armed, selector='#arm')
        assert wait_until(lambda: app.call('engine-sleep', tab=armed)['unloadHandlers'], timeout=4, step=.05)
        shown = app.call('toasts')['shown']
        app.call('menu-perform', id='clear-unpinned-tabs')
        asked = wait_until(lambda: app.call('dialog-state').get('visible'), timeout=5, step=.05)
        moved = app.call('pin', tab=armed) if asked else None
        settle()
        still = app.call('dialog-state').get('visible')
        if asked: app.call('dialog-button', accept=True)
        time.sleep(.8)
        toasts = app.call('toasts')
        titles = [t['title'] for t in toasts['toasts']]
        check('r8_clear_today_emptied_meanwhile_no_toast', bool(asked) and bool(moved) and armed not in section('today')
              and 'Cleared Tabs' not in titles and toasts.get('lastTitle') != 'Cleared Tabs', asked=bool(asked), moved=bool(moved), stillAsking=still, shownBefore=shown, shownAfter=toasts['shown'],
              titles=titles, lastTitle=toasts.get('lastTitle'))
    def disarm():
        answer_dialogs()
        try: app.call('eval', tab=armed, js='onbeforeunload=null;true')
        except Exception: pass
    guarded('r8_clear_today_emptied_meanwhile_no_toast', clear_after_move, disarm)

    # A-R6-09: another window moves this window's only Today tab away. The Space still shows a
    # Favorite (never selected here): it is selected, as Cmd+W and the moving window would, not a blank page.
    second = None
    def cross_window_favorite():
        nonlocal second
        app.call('space', space=b); settle()
        fav = opened('Fav'); app.call('favorite', tab=fav); settle()
        lone_space = app.call('space-create', title='R8 Lone'); app.call('space', space=lone_space); settle()
        lone = opened('Lone'); app.call('select', tab=lone); settle()
        others = [t for t in section('today') + section('pinned') if t != lone]
        app.call('command', id='new-window'); settle()
        second = wait_until(lambda: next((w['id'] for w in app.call('shell-windows') if w['id'] != window), None), timeout=5, step=.1)
        if app.call('commandbar-state').get('presented'): app.call('key', key='escape'); settle()
        app.call('space', space=b); settle()
        drop = app.call('sidebar-drop', window=second, nodes=[lone], parent={'kind': 'today', 'id': b}, index=0); settle()
        first = state(window)
        check('r8_cross_window_move_selects_favorite', drop and second and not others and first['space'] == lone_space
              and first['selected'] == fav and fav in first['shownPages'],
              drop=drop, others=others, first={k: first[k] for k in ('space', 'selected', 'shownPages')}, fav=fav, lone=lone)
    def close_second():
        if second:
            app.call('window-focus', id=second); app.call('window-close'); settle()
        app.call('window-focus', id=window); settle()
    guarded('r8_cross_window_move_selects_favorite', cross_window_favorite, close_second)
