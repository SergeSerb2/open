"""File ▸ Blank Window as its own window kind (capture C10), through the real App:
⌃⌘N from a normal window, the "This Window" sidebar (no Favorites, no Space dots, Library and
"+" in the bottom bar), the command bar open, tabs newest first, the row menu with Move to ▸,
⌘W on the last tab closing the window, and nothing of it in the session snapshot. Capture
C-report-s11: tabs drag both ways between it and a normal window, the header's "Move to…",
⌘W puts a tab in the Archive but not the last one, and it comes back at relaunch with
"restore windows" on (not with it off). Socket only; loopback pages.
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
        main_drop_top = app.call('sidebar-row', node=main_tab)['point'][1]
        main_tabs = [t['id'] for t in app.call('tabs')]
        main_space = next(s['id'] for s in app.call('spaces') if s['focused'])

        def archived(): return [r['url'] for r in app.call('archive-list')['rows']]
        def snapshot_text(): return json.dumps(json.loads(Path(app.call('save')).read_text()))

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

        # C-report-s11 1(a): the header has a "Move to…" button; its menu lists the browser's Spaces.
        mt = blank()['moveTo']
        row('header_move_to_button', mt.get('shown') and mt.get('title') == 'Move to…' and spaces and set(spaces) <= set(mt.get('menu', [])),
            moveTo=mt, spaces=spaces)

        # C-report-s11 1(a): a tab drags from the Blank Window into the normal window's sidebar and back.
        five = h.new_tab(app, origin + '/five')
        bspace = blank()['space']
        blank_drop_top = app.call('sidebar-row', node=first)['point'][1]
        rails = app.call('sidebar-drag', op='begin', nodes=[five])['rails']
        target_rails = [r for r in rails if r['parent'] == main_window]
        hover = app.call('sidebar-drag', op='rail', window=main_window, rail=0, node=five, top=main_drop_top)
        row('destination_rails_and_blue_line', len(target_rails) == 2
            and sorted(r['frame'][2] for r in target_rails) == [30, 80]
            and all(r['visible'] and not r['opaque'] for r in target_rails)
            and hover['entered'] and hover['updated'] and len(hover['indicator']) == 4,
            rails=target_rails, hover=hover)
        # Cancel leaves the tab in its original window and removes all rail windows and feedback.
        ended = app.call('sidebar-drag', op='end')
        row('cancel_drag_cleans_rails', ended['rails'] == [] and any('/five' in t['url'] for t in blank()['tabs']), ended=ended)
        app.call('sidebar-drag', op='begin', nodes=[five])
        try:
            out = app.call('sidebar-drag', op='rail', window=main_window, rail=0, node=five, top=main_drop_top, perform=True)['accepted']
        finally:
            app.call('sidebar-drag', op='end')
        left = h.wait_until(lambda: all('/five' not in t['url'] for t in blank()['tabs']) or None, timeout=5, step=.1)
        in_main = '/five' in snapshot_text()
        row('drag_blank_to_normal_window', out is True and bool(left) and in_main and blank()['isBlankWindow'], dropped=out, inMain=in_main)
        app.call('window-focus', id=main_window, activate=True)
        moved_five = h.wait_until(lambda: [t['id'] for t in app.call('tabs') if '/five' in t['url']] or None, timeout=5, step=.1) or []
        back = False
        if moved_five:
            app.call('sidebar-drag', op='begin', nodes=moved_five[:1])
            try:
                incoming = app.call('sidebar-drag', op='rail', window=b['window'], rail=1, node=moved_five[0], top=blank_drop_top, perform=True)
                back = incoming['accepted'] and len(incoming['indicator']) == 4
            finally:
                app.call('sidebar-drag', op='end')
        app.call('window-focus', id=b['window'], activate=True)
        returned = h.wait_until(lambda: any('/five' in t['url'] for t in blank()['tabs']) or None, timeout=5, step=.1)
        row('drag_normal_window_to_blank', back is True and bool(returned) and '/five' not in snapshot_text(),
            dropped=back, blankTabs=[t['url'] for t in blank()['tabs']])
        five_back = next((t['id'] for t in app.call('tabs') if '/five' in t['url']), None)
        if five_back:
            app.call('close', tab=five_back)
            h.wait_until(lambda: all('/five' not in t['url'] for t in app.call('tabs')) or None, timeout=5, step=.1)

        # C-report-s11 1(b): a tab closed with ⌘W (not the last) is in the Archive.
        four = h.new_tab(app, origin + '/four')
        app.call('select', tab=four)
        key('w', 'command')
        in_archive = h.wait_until(lambda: any('/four' in u for u in archived()) or None, timeout=8, step=.2)
        row('closed_tab_goes_to_archive', bool(in_archive) and blank()['isBlankWindow'], archive=archived()[:5])

        frames = os.path.join(h.ROOT, '.re', 'nt-frames'); os.makedirs(frames, exist_ok=True)
        app.call('snapshot', path=os.path.join(frames, 'blank-window.png'))
        for appearance in ['light', 'dark']:
            app.call('appearance', name=appearance)
            app.call('snapshot', path=os.path.join(frames, 'blank-window-' + appearance + '.png'))
        app.call('appearance', name='system')

        # ⇧⌘T (capture C10 addition): a tab closed here reopens in this window.
        third = h.new_tab(app, origin + '/three')
        key('w', 'command')
        h.wait_until(lambda: all(t['id'] != third for t in app.call('tabs')) or None, timeout=5, step=.1)
        key('t', 'command', 'shift')
        back = h.wait_until(lambda: [t for t in app.call('tabs') if '/three' in t['url']] or None, timeout=8, step=.1) or []
        reopened = blank()
        row('reopen_closed_tab_in_this_window', len(back) == 1 and reopened['isBlankWindow'] and reopened['browserWindows'] == 2
            and len(app.call('tabs')) == 3, tabs=[t['url'] for t in app.call('tabs')])
        if back:
            app.call('close', tab=back[0]['id'])
            h.wait_until(lambda: len(app.call('tabs')) == 2 or None, timeout=5, step=.1)

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
        # ⇧⌘T in the browser window does not bring a closed Blank Window back.
        key('t', 'command', 'shift'); time.sleep(1)
        row('reopen_does_not_restore_blank_window', blank()['browserWindows'] == 1 and not blank()['isBlankWindow'], state=blank())
        row('last_tab_closes_window', still_blank and closed['browserWindows'] == 1 and closed['window'] == main_window
            and len(after) == len(main_tabs) + 1 and any('/two' in t['url'] for t in after) and set(main_tabs) <= {t['id'] for t in after}, after=closed)
        # C-report-s11 1(b): the last tab, which closed the window, is not in the Archive.
        time.sleep(1)
        row('last_tab_not_archived', not any('/one' in u for u in archived()), archive=archived()[:5])

        # A Blank Window open at quit, with "restore windows" on (Open's default).
        app.call('window-focus', id=main_window, activate=True)
        key('n', 'control', 'command')
        h.wait_until(lambda: blank()['isBlankWindow'] or None, timeout=8, step=.1)
        key('escape')
        h.new_tab(app, origin + '/six')
        quit_frame = blank()['frame']
    finally:
        app.quit()

    # 7. Relaunch with "restore windows" on: the Blank Window comes back with its tab (C-report-s11 1(c)),
    # at the default frame (GUESS, Arc restored a cascade frame, not the saved one); a closed one does not.
    app = factory(urls=())
    try:
        s = h.wait_until(lambda: (lambda x: x if x['browserWindows'] == 2 else None)(app.call('blank-window')), timeout=10, step=.2) or app.call('blank-window')
        blank_window = next((w['id'] for w in app.call('shell-windows') if w['id'] != s['window'] or s['isBlankWindow']), None)
        if not s['isBlankWindow'] and blank_window:
            app.call('window-focus', id=blank_window, activate=True); s = app.call('blank-window')
        row('restored_at_relaunch_when_restore_on', s['browserWindows'] == 2 and s['isBlankWindow'] and s['headerTitle'] == 'This Window'
            and [t['url'].rsplit('/', 1)[-1] for t in s['tabs']] == ['six'], state=s, quitFrame=quit_frame)
        app.call('defaults', key='open.advanced.restoreWindowsOnLaunch', value=False)
    finally:
        app.quit()

    # 8. With "restore windows" off, an open Blank Window does not come back.
    app = factory(urls=())
    try:
        s = app.call('blank-window')
        row('not_restored_when_restore_off', not s['isBlankWindow'] and not any(w for w in app.call('shell-windows') if w['id'] != s['window']),
            state=s, windows=len(app.call('shell-windows')))
        app.call('defaults', key='open.advanced.restoreWindowsOnLaunch', value=None)
    finally:
        app.quit()
    try:
        live_transfer_checks(factory, results, h, origin)
    finally:
        server.shutdown()
        server.server_close()


def live_transfer_checks(factory, results, h, origin):
    """Typed document, engine/native identities, and last-source close via real rails."""
    app = factory(urls=(origin + '/transfer-control',), fresh=True)
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('blank-window %-34s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
    def key(name, *mods): return app.call('key', key=name, modifiers=list(mods), route='app')
    def front(window): app.call('window-focus', id=window, activate=True)
    def page(tab): return app.call('tab-state', tab=tab).get('page', {})
    def document(tab):
        return app.call('eval', tab=tab, js='({text:document.querySelector("#transfer-text")?.value||"", nonce:window.__transferNonce||"", scroll:scrollY})')
    def drop(tab, target, top):
        app.call('sidebar-drag', op='begin', nodes=[tab])
        try:
            return app.call('sidebar-drag', op='rail', window=target, rail=0, node=tab, top=top, perform=True)['accepted']
        finally:
            app.call('sidebar-drag', op='end')
    def open_blank():
        key('n', 'control', 'command')
        opened = h.wait_until(lambda: (lambda s: s if s['isBlankWindow'] else None)(app.call('blank-window')), timeout=8)
        if not opened: raise AssertionError('live transfer Blank Window did not open')
        key('escape')
        placeholder = h.new_tab(app, origin + '/transfer-placeholder')
        return opened['window'], placeholder, app.call('sidebar-row', node=placeholder)['point'][1]
    try:
        supported = app.call('blank-window').get('liveTabTransferSupported', False)
        if not supported and os.environ.get('OPEN_REQUIRE_LIVE_TAB_TRANSFER') != '1':
            results['live_transfer_engine_capability'] = dict(status='DEFERRED', reason='Adopted engine lacks live tab transfer; URL reload fallback remains enabled.')
            return
        main = app.call('window-state')['id']
        control = app.call('tabs')[0]['id']; app.call('wait', tab=control)
        app.call('window-frame', frame=[100, 220, 900, 480])
        tab = h.new_tab(app, origin + '/transfer-before')
        app.call('navigate', tab=tab, url=origin + '/transfer-form'); app.call('wait', tab=tab)
        app.call('focus', tab=tab)
        app.call('eval', tab=tab, js='document.body.innerHTML="<input id=transfer-text><div style=height:3000px>Transfer fixture</div>"; window.__transferNonce=crypto.randomUUID(); document.querySelector("input").focus()')
        app.call('type', tab=tab, text='Typed before moving this page')
        app.call('eval', tab=tab, js='scrollTo(0,380)')
        initial = document(tab); original = page(tab)
        row('live_transfer_typed_fixture', initial['text'] == 'Typed before moving this page' and initial['nonce'] and initial['scroll'] == 380,
            document=initial, page=original)
        main_top = app.call('sidebar-row', node=control)['point'][1]
        blank, placeholder, blank_top = open_blank()
        front(main); accepted = drop(tab, blank, blank_top)
        front(blank)
        incoming = h.wait_until(lambda: next((t['id'] for t in app.call('tabs') if t['url'] == origin + '/transfer-form'), None), timeout=5)
        if not incoming: raise AssertionError('live transfer did not reach Blank Window')
        app.call('wait', tab=incoming)
        moved, moved_page = document(incoming), page(incoming)
        identity = lambda p: [p.get(k) for k in ('identifier', 'chromeTabId', 'nativeViewIdentity')]
        row('live_transfer_normal_to_blank_keeps_document', accepted and incoming == tab and moved == initial
            and identity(moved_page) == identity(original) and moved_page['browser'] != original['browser']
            and original['canGoBack'] and moved_page['canGoBack'],
            before=initial, after=moved, originalPage=original, movedPage=moved_page)
        # Leave only the moved tab. Moving it back must close its old Blank
        # Window without closing the transferred engine page or native view.
        app.call('close', tab=placeholder)
        accepted_back = drop(incoming, main, main_top)
        front(main)
        returned = h.wait_until(lambda: next((t['id'] for t in app.call('tabs') if t['url'] == origin + '/transfer-form'), None), timeout=5)
        if not returned: raise AssertionError('live transfer did not return to normal window')
        app.call('wait', tab=returned)
        closed = h.wait_until(lambda: all(w['id'] != blank for w in app.call('shell-windows')), timeout=8)
        after, after_page = document(returned), page(returned)
        row('live_transfer_blank_to_normal_survives_source_close', accepted_back and closed and returned == tab
            and after == initial and identity(after_page) == identity(original) and after_page['browser'] == original['browser']
            and after_page['canGoBack'],
            before=initial, after=after, originalPage=original, returnedPage=after_page, windows=app.call('shell-windows'))
        # The Move to menu must use the same ownership handoff as drag.
        blank, placeholder, blank_top = open_blank()
        front(main); drop(returned, blank, blank_top); front(blank)
        incoming = next(t['id'] for t in app.call('tabs') if t['url'] == origin + '/transfer-form')
        app.call('close', tab=placeholder)
        target = app.call('spaces')[0]['title'] or 'Space 1'
        app.call('sidebar-menu', node=incoming, items=['Move to', target])
        closed = h.wait_until(lambda: all(w['id'] != blank for w in app.call('shell-windows')), timeout=8)
        front(main)
        returned = next(t['id'] for t in app.call('tabs') if t['url'] == origin + '/transfer-form')
        app.call('select', tab=returned)
        after, after_page = document(returned), page(returned)
        row('live_transfer_move_to_space_keeps_document', closed and returned == tab and after == initial
            and identity(after_page) == identity(original), before=initial, after=after, returnedPage=after_page)
    finally:
        app.quit()
