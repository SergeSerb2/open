"""Bug sweep r6 (SIDEPAGE6) sidebar rows, in the real App through the automation socket.

P-04: moving the current tab to another Space (Move to, a Space-icon drop, a drop into a
      second window) selects a neighbour; the source Space is not left blank.
P-03: a link dropped on another Space's icon opens there in the background; this Space keeps
      its selected tab.
P-05: Remove Pin (Cmd+D) on one pinned tab puts it at the top of Today, as a selection does.
P-02: Restore Last Closed Tab brings back the tab the user closed, not a later auto-archived one.
"""
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
    check('r6_cross_window_drop_keeps_source_selection', drop2 and second and first['space'] == a and first['selected'] == keep,
          drop=drop2, first={k: first[k] for k in ('space', 'selected', 'shownPages')}, keep=keep, crossed=crossed)
    if second:
        app.call('window-focus', id=second); app.call('window-close'); settle()
    app.call('window-focus', id=window); settle()

    # P-03: a link dropped on another Space's icon opens there; this Space keeps its tab.
    app.call('select', tab=keep); settle()
    link = (Path(tmp) / 'r6-link.html'); link.write_text('<title>R6 Link</title><h1>Link</h1>')
    url_drop = app.call('space-dot-drop', space=b, url=link.as_uri()); settle()
    after = state()
    new_in_b = [t for t in app.call('tabs') if t['url'] == link.as_uri()]
    check('r6_space_icon_link_drop_keeps_current_tab', url_drop.get('accepted') and after['space'] == a and after['selected'] == keep
          and keep in after['shownPages'] and len(new_in_b) == 1,
          drop=url_drop, state={k: after[k] for k in ('space', 'selected', 'shownPages')}, keep=keep, newTabs=new_in_b)

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
