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
        # ⌘⇧ letters only: ⌃⇧N (New Note) and ⌃⇧E (New Easel) are Control shortcuts, not this inventory.
        rows = [r for r in app.call('menu-state') if r['modifierMask'] & SHIFT and r['modifierMask'] & COMMAND
                and len(r['key']) == 1 and r['key'].isalpha()]
        actual = {r['id']: (r['key'], r['modifierMask']) for r in rows}
        check('inventory', actual == EXPECTED and len(rows) == len(EXPECTED), rows=rows)
        app.call('menu-key-render', path=str(private / 'native-shift-menu-glyphs.png'))
        (private / 'native-shift-menu-inventory.json').write_text(h.json.dumps(rows, indent=2) + '\n')

        # Page focus owns Incognito; one native event creates one private
        # window. Sidebar focus still owns New Folder for the same chord.
        browser_focus()
        windows, tree = app.call('shell-windows'), app.call('sidebar-tree')
        counts = app.call('incognito-state')
        incognito = next(r for r in app.call('menu-state') if r['id'] == 'new-incognito-window')
        receipt = key('n')
        private_windows = h.wait_until(lambda: (lambda rows: rows if rows else None)(
            [w for w in app.call('incognito-state')['windows'] if w['private']]), timeout=5)
        once('new-incognito-window', receipt, incognito['enabled'] and bool(private_windows)
             and len(private_windows) == 1 and len(app.call('shell-windows')) == len(windows) + 1,
             windows=private_windows, menu=incognito)
        app.call('window-focus', id=private_windows[0]['id'], activate=True)
        new_space = next(r for r in app.call('menu-state') if r['id'] == 'new-space')
        refusal = ''
        try:
            app.call('menu-perform', id='new-space')
        except RuntimeError as error:
            refusal = str(error)
        check('incognito_new_space_refused', not new_space['enabled'] and 'disabled menu item' in refusal
              and not app.call('creation-state')['open']
              and app.call('incognito-state')['normalSpaces'] == counts['normalSpaces'],
              menu=new_space, refusal=refusal, creation=app.call('creation-state'))
        app.call('window-close')
        check('incognito_close_preserves_normal', bool(h.wait_until(
            lambda: len(app.call('shell-windows')) == len(windows), timeout=5)))
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
        # Normal windows (a Blank Window is its own window kind since #462).
        app.call('menu-perform', id='new-window')
        second = app.call('window-state')['id']
        app.call('menu-perform', id='new-window')
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
