"""Native Shift+letter menu inventory and one-event/one-command regression.

The App records real dispatch only while observeCommands is requested. No route,
validation, selector, or command target is replaced by this suite.
"""
import os
import time
from pathlib import Path

SHIFT = 1 << 17
COMMAND = 1 << 20
OPTION = 1 << 19
CONTROL = 1 << 18
EXPECTED = {
    'new-incognito-window': ('N', COMMAND | SHIFT),
    'close-window': ('W', COMMAND | SHIFT),
    'closeAll:': ('W', COMMAND | OPTION | SHIFT),
    'restore-last-closed-tab': ('T', COMMAND | SHIFT),
    'save-page-as': ('S', COMMAND | SHIFT),
    'redo': ('Z', COMMAND | SHIFT),
    'paste-and-match-style': ('V', COMMAND | SHIFT),
    'copy-url': ('C', COMMAND | SHIFT),
    'copy-url-markdown': ('C', COMMAND | OPTION | SHIFT),
    'copy-url-quote': ('C', COMMAND | CONTROL | SHIFT),
    'find-previous': ('G', COMMAND | SHIFT),
    'toggle-toolbar': ('D', COMMAND | SHIFT),
    'force-reload': ('R', COMMAND | SHIFT),
    'clear-unpinned-tabs': ('K', COMMAND | SHIFT),
    'new-folder': ('N', COMMAND | SHIFT),
    'peek-email': ('E', COMMAND | SHIFT),
    'view-downloads': ('J', COMMAND | SHIFT),
    'view-library': ('L', COMMAND | SHIFT),
}


def run(h, factory, results, tmp):
    server, origin = h._fixture_server('Shift menu')
    app = factory(urls=(origin + '/alpha',), fresh=True)
    saved = {}
    tested = set()
    private = Path(h.ROOT, '.re/s4-d')
    private.mkdir(parents=True, exist_ok=True)

    def check(name, ok, **details):
        results['shift_menu_' + name] = dict(details, ok=bool(ok))
        if not ok:
            raise AssertionError('shift_menu_' + name)

    def key(letter, mods=('cmd', 'shift')):
        return app.call('key', key=letter, modifiers=list(mods), route='app', observeCommands=True)

    def once(command, receipt, effect=True, native=False, **details):
        commands, menus = receipt['commands'], receipt['menuActions']
        count = commands.count(command) + menus.count(command) if native else commands.count(command)
        check(command, count == 1 and commands.count(command) <= 1 and menus.count(command) <= 1
              and (native or not menus)
              and receipt['charactersIgnoringModifiers'] == EXPECTED[command][0] and effect,
              receipt=receipt, **details)
        tested.add(command)

    def browser_focus(sidebar=False):
        app.call('window-focus', id=browser, activate=True)
        app.call('select', tab=tab)
        if sidebar:
            app.call('menu-perform', id='reveal-tab-in-sidebar')
        else:
            app.call('focus', tab=tab)

    def pane():
        return next((p for p in app.call('find-state').get('panes', []) if p['tab'] == tab), {})

    try:
        pref = 'open.sidebar.hideHintShown'
        saved[pref] = app.call('defaults', key=pref)
        app.call('defaults', key=pref, value=True)
        browser = app.call('window-state')['id']
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        browser_focus(True)
        rows = [r for r in app.call('menu-state') if r['modifierMask'] & SHIFT
                and len(r['key']) == 1 and r['key'].isalpha()]
        actual = {r['id']: (r['key'], r['modifierMask']) for r in rows}
        check('inventory', actual == EXPECTED and len(rows) == len(EXPECTED), rows=rows)
        app.call('menu-key-render', path=str(private / 'native-shift-menu-glyphs.png'))
        (private / 'native-shift-menu-inventory.json').write_text(h.json.dumps(rows, indent=2) + '\n')

        # The unimplemented Incognito item stays disabled. Cmd+Shift+N has no
        # browser-window effect with page focus; sidebar focus owns New Folder.
        browser_focus()
        windows, tree = app.call('shell-windows'), app.call('sidebar-tree')
        disabled = next(r for r in app.call('menu-state') if r['id'] == 'new-incognito-window')
        receipt = key('n')
        check('new-incognito-window_disabled', not disabled['enabled']
              and 'new-incognito-window' not in receipt['commands'] + receipt['menuActions']
              and app.call('shell-windows') == windows and app.call('sidebar-tree') == tree,
              receipt=receipt, menu=disabled)
        tested.add('new-incognito-window')
        browser_focus(True)
        count = len(app.call('sidebar-tree')['pinned'])
        receipt = key('n')
        after = app.call('sidebar-tree')
        once('new-folder', receipt, len(after['pinned']) == count + 1 and len(app.call('shell-windows')) == len(windows), tree=after)
        key('escape', ())

        # Two closed tabs make a duplicate restore observable.
        a = app.call('open', url=origin + '/closed-a')['id']
        b = app.call('open', url=origin + '/closed-b')['id']
        app.call('close', tab=a); app.call('close', tab=b)
        browser_focus(True)
        before = {t['id'] for t in app.call('tabs')}
        receipt = key('t')
        after = h.wait_until(lambda: (lambda ts: ts if len(ts) > len(before) else None)(app.call('tabs')), timeout=5)
        once('restore-last-closed-tab', receipt, bool(after) and {t['id'] for t in after} - before == {b}, tabs=after)

        browser_focus(True)
        before = app.call('window-state')['toolbar']['shown']
        receipt = key('d')
        once('toggle-toolbar', receipt, app.call('window-state')['toolbar']['shown'] is not before)
        app.call('menu-perform', id='toggle-toolbar')

        for command, mods in [('copy-url', ('cmd', 'shift')),
                              ('copy-url-markdown', ('cmd', 'opt', 'shift')),
                              ('copy-url-quote', ('cmd', 'ctrl', 'shift'))]:
            browser_focus(True)
            app.call('pasteboard', text='untouched')
            receipt = key('c', mods)
            copied = h.wait_until(lambda: (lambda text: text if origin + '/alpha' in text else None)(app.call('pasteboard')), timeout=5)
            once(command, receipt, bool(copied), clipboard=copied)

        browser_focus()
        before = app.call('save-page-state')['requests']
        receipt = key('s')
        panel = h.wait_until(lambda: (lambda s: s if s['visible'] else None)(app.call('save-page-state')), timeout=5)
        once('save-page-as', receipt, bool(panel) and panel['requests'] == before + 1, panel=panel)
        app.call('dismiss')
        assert h.wait_until(lambda: not app.call('save-page-state')['pending'], timeout=5)

        browser_focus(True)
        app.call('events')
        receipt = key('r')
        assert h.wait_until(lambda: not app.tab(tab).get('loading', False), timeout=5)
        app.call('wait', tab=tab)
        events = app.call('events')
        once('force-reload', receipt, app.eval(tab, 'document.title') == 'Shift menu /alpha', events=events)

        # Native text actions: two redo groups prove only one is redone, and a
        # single paste must insert the clipboard once. A5 separately proves
        # typing Undo falls back to the persistent draft history.
        app.call('editor-open', kind='create')
        app.call('editor-act', action='click', control='theme')
        app.call('editor-act', action='preset', index=2)
        app.call('editor-close'); app.call('editor-open', kind='create')
        app.call('type', text='first')
        key('z', ('cmd',))
        receipt = key('z')
        state = app.call('creation-state')
        once('redo', receipt, state['style'] is not None and state['name'] == 'first', native=True, state=state)
        app.call('pasteboard', text='paste')
        key('a', ('cmd',))
        receipt = key('v')
        state = app.call('creation-state')
        once('paste-and-match-style', receipt, state['name'] == 'paste', native=True, state=state)
        key('escape', ())

        # Find moves from match 3 to match 2, so running twice cannot pass.
        browser_focus()
        app.eval(tab, "document.body.innerHTML='<p>needle one</p><p>needle two</p><p>needle three</p>'; true")
        key('f', ('cmd',)); app.call('key', text='needle', route='app')
        assert h.wait_until(lambda: pane().get('total') == 3, timeout=5)
        key('g', ('cmd',)); key('g', ('cmd',))
        assert h.wait_until(lambda: pane().get('active') == 3, timeout=5), pane()
        receipt = key('g')
        after = h.wait_until(lambda: pane() if pane().get('active') == 2 else None, timeout=5)
        once('find-previous', receipt, bool(after), native=True, pane=pane())
        key('escape', ())

        for command, letter, section in [('view-downloads', 'j', 'downloads'), ('view-library', 'l', None)]:
            browser_focus(True)
            receipt = key(letter)
            state = h.wait_until(lambda: (lambda s: s if s['library'] else None)(app.call('settings-state')), timeout=5)
            once(command, receipt, bool(state) and (section is None or state['librarySection'] == section), state=state)

        # No network discovery: a saved mail tab is sufficient for Peek Email.
        browser_focus(True)
        app.call('filter', block=['mail.google.com'])
        mail = app.call('open', url='https://mail.google.com/mail/', background=True)['id']
        app.call('pin', tab=mail)
        browser_focus(True)
        receipt = key('e')
        peek = app.call('peek-state')
        once('peek-email', receipt, peek['shown'] and len(peek['stack']) == 1, peek=peek)
        app.call('peek-close')

        browser_focus(True)
        count = len(app.call('sidebar-tree')['today'])
        receipt = key('k')
        tree = app.call('sidebar-tree')
        once('clear-unpinned-tabs', receipt, count > 0 and tree['today'] == [], tree=tree)
        key('z', ('cmd',))
        check('clear_one_undo', len(app.call('sidebar-tree')['today']) == count)

        # Native close must leave both other browser windows alive.
        browser_focus(True)
        app.call('menu-perform', id='blank-window')
        second = app.call('window-state')['id']
        app.call('menu-perform', id='blank-window')
        third = app.call('window-state')['id']
        before = {w['id'] for w in app.call('shell-windows')}
        receipt = key('w')
        after = h.wait_until(lambda: (lambda ws: ws if len(ws) == len(before) - 1 else None)(app.call('shell-windows')), timeout=5)
        once('close-window', receipt, bool(after) and {w['id'] for w in after} == before - {third}, native=True, windows=after)
        app.call('window-focus', id=browser, activate=True)
        receipt = key('w', ('cmd', 'opt', 'shift'))
        closed = h.wait_until(lambda: not app.call('shell-windows'), timeout=5)
        once('closeAll:', receipt, bool(closed), native=True)
        check('all_inventory_commands_exercised', tested == set(EXPECTED), tested=sorted(tested))
    finally:
        h._try(lambda: app.call('dismiss'))
        h._try(lambda: app.call('filter', block=[]))
        h._restore_defaults(app, saved)
        app.quit()
        server.shutdown()
