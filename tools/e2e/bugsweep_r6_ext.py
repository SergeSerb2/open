"""Bug sweep round 6, lane EXT6: real-App rows for extensions, Site Control, Ad Blocking,
Boosts, the command bar and Notes. Socket only; loopback pages; one fresh profile per launch.

Run: OPEN_EXT_R6_ONLY=1 engine_e2e.py --only blank-window --config Debug
(under the on-screen lock). OPEN_EXT_R6_ROWS=name[,name] runs only those row groups.

Each row records PASS or FAIL and the suite continues; every row names the old behaviour
it would show without its fix. Automation reads and acts on the front standard window (its
`window` argument selects only Little Open windows), so rows focus the window they address.
"""
import http.server
import json
import os
import shutil
import threading
import time
from pathlib import Path

PROBE = "jihnllejimhgcmfmcnchbekapeajboik"  # tools/e2e/fixtures/action-probe (manifest key)


def run(factory, results, tmp, h):
    # OPEN_EXT_R6_APP=<path to Open.app>: run these rows against that bundle (a parent-commit
    # copy for the break-and-revert proof) instead of build/<config>/Open.app.
    bundle = os.environ.get("OPEN_EXT_R6_APP")
    if bundle:
        launch = factory
        def factory(*args, extra_env=None, **kw):
            return launch(*args, extra_env=dict(extra_env or {}, OPEN_E2E_APP_BUNDLE=bundle), **kw)
    only = set(filter(None, os.environ.get("OPEN_EXT_R6_ROWS", "").split(",")))
    def wanted(name): return not only or name in only

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('ext-r6 %-44s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def guarded(name, fn):
        if not wanted(name): return
        try: fn()
        except Exception as error:  # A broken step is this row's FAIL; later rows still run.
            row(name + '_error', False, error=repr(error)[:600])

    server, origin = h._fixture_server('R6')
    probe = Path(tmp) / 'action-probe-r6'
    shutil.rmtree(probe, ignore_errors=True)
    shutil.copytree(Path(h.ROOT) / 'tools/e2e/fixtures/action-probe', probe)
    ext_args = ['--load-extension=' + str(probe), '--disable-features=DisableLoadExtensionCommandLineSwitch',
                '--host-resolver-rules=MAP *.r6.test 127.0.0.1']
    try:
        app = factory(urls=(origin + '/main',), fresh=True, extra_args=ext_args)
        try:
            app.call('defaults', key='open.advanced.playSoundEffects', value=False)
            app.call('window-focus', id=app.call('window-state')['id'], activate=True)
            h.wait_until(lambda: any(a['id'] == PROBE for a in app.call('extensions')['actions']), timeout=30)
            guarded('EXT01', lambda: ext01_blank_window_pin(app, row, h, origin))
            guarded('R10', lambda: r10_open_bar_keycaps(app, row, h, origin))
            guarded('R5', lambda: r5_delete_selected_note(app, row, h, origin))
            guarded('BST01', lambda: bst01_editor_uses_invoking_window(app, row, h, origin))
            guarded('BST02', lambda: bst02_library_edit_closes_library(app, row, h, origin))
            guarded('ADB01', lambda: adb01_ipv6_allowed_site(app, row, h))
            guarded('EXT04', lambda: ext04_little_open_menu(app, row, h, origin))
            guarded('EXT05', lambda: ext05_incognito_table_follows_rebind(app, row, h, origin))
            guarded('R4', lambda: r4_renewed_session_forgets_developer_mode(app, row, h, origin))
        finally:
            app.quit()
        guarded('ADB03', lambda: adb03_no_list_fetch_while_off(factory, row, h))
    finally:
        server.shutdown(); server.server_close()


def control_tab(app, h):
    """The probe's own page as a tab: chrome.* APIs with the tabs permission."""
    existing = next((t['id'] for t in app.call('tabs') if t['url'].startswith('chrome-extension://' + PROBE)), None)
    return existing or h.new_tab(app, 'chrome-extension://' + PROBE + '/popup.html')


def ext01_blank_window_pin(app, row, h, origin):
    """EXT-01: chrome.tabs.update({pinned:true}) on a Blank Window tab is refused. Old: the tab moves to
    the hidden pinned list and leaves the "This Window" sidebar."""
    main = app.call('window-state')['id']
    control = control_tab(app, h)
    app.call('key', key='n', modifiers=['control', 'command'], route='app')
    blank = h.wait_until(lambda: (lambda s: s if s['isBlankWindow'] else None)(app.call('blank-window')), timeout=8, step=.1)
    assert blank, 'no Blank Window'
    window = blank['window']
    try:
        app.call('key', key='escape', route='app')
        url = origin + '/blank-pin'
        tab = h.new_tab(app, url)  # the Blank Window is in front
        # The probe page is a tab of the main window: address it there.
        app.call('window-focus', id=main, activate=True)
        found = h.wait_until(lambda: app.eval(control, "chrome.tabs.query({}).then(ts=>(ts.find(t=>t.url===%s)||{}).id||0)" % json.dumps(url)), timeout=10)
        result = app.eval(control, "chrome.tabs.update(%d,{pinned:true}).then(t=>({pinned:t.pinned}),e=>({error:String(e)}))" % found)
        time.sleep(1)
        app.call('window-focus', id=window, activate=True)
        tabs = app.call('tabs')
        mine = next((t for t in tabs if t['id'] == tab), {})
        row('EXT01_blank_window_api_pin_refused', bool(found) and mine.get('section') == 'today',
            api=result, tab=mine, negative='old: the tab moves to the pinned list, which a Blank Window never shows')
    finally:
        app.call('window-focus', id=window, activate=True); app.call('window-close')
        app.call('window-focus', id=main, activate=True)


def command_count(app, control, name='probe-named'):
    return app.eval(control, "chrome.storage.session.get('commands').then(v=>(v.commands||[]).filter(c=>c===%s).length)" % json.dumps(name))


def open_bar(app, h, window):
    app.call('window-focus', id=window, activate=True)
    app.call('menu-perform', id='open-command-bar')
    return h.wait_until(lambda: (lambda s: s if s.get('presented') else None)(app.call('commandbar-state', window=window)), timeout=5, step=.05)


def type_in_bar(app, h, window, text, ready):
    app.call('key', window=window, text=text)
    return h.wait_until(lambda: (lambda s: s if s.get('text') == text and s.get('final') and ready(s) else None)(
        app.call('commandbar-state', window=window)), timeout=6, step=.05) or app.call('commandbar-state', window=window)


def r10_open_bar_keycaps(app, row, h, origin):
    """R10: an open standard-window bar shows a rebound key at once. Old: stale ⌘T until reopened."""
    w1 = app.call('window-state')['id']
    assert open_bar(app, h, w1)
    def new_tab_row(s): return next((r for r in s['rows'] if r['kind'] == 'action' and r['action'] == 'new-tab'), None)
    before = type_in_bar(app, h, w1, 'New Tab', new_tab_row)
    try:
        app.call('settings-pane', pane='shortcuts')
        app.call('ext-shortcuts', action='record', id='new-tab', key='o', modifiers=['command', 'option', 'control'])
        # An action row shows its key as the subtitle (ActionsProvider).
        old = (new_tab_row(before) or {}).get('subtitle')
        after = h.wait_until(lambda: (lambda s: s if s.get('presented') and (new_tab_row(s) or {}).get('subtitle') != old else None)(
            app.call('commandbar-state', window=w1)), timeout=5, step=.05) or app.call('commandbar-state', window=w1)
        keys = (new_tab_row(after) or {}).get('subtitle') or ''
        row('R10_open_bar_shows_rebound_key', bool(new_tab_row(before)) and after.get('presented') and 'T' in (old or '')
            and 'O' in keys and '⌥' in keys and '⌃' in keys, before=old, after=keys,
            presented=after.get('presented'), negative='old: the open bar keeps ⌘T')
    finally:
        app.call('settings-pane', pane='shortcuts')
        app.call('ext-shortcuts', action='reset', id='new-tab')
        app.call('ext-shortcuts', action='close')
        app.call('window-focus', id=w1, activate=True)
        if app.call('commandbar-state', window=w1).get('presented'): app.call('key', key='escape', window=w1, route='app')


def r5_delete_selected_note(app, row, h, origin):
    """R5: deleting the selected Note selects its neighbour. Old: no tab stays selected (blank page)."""
    page = h.new_tab(app, origin + '/r5-page')
    app.call('select', tab=page)
    app.call('menu-perform', id='new-note')
    note = h.wait_until(lambda: next((t['id'] for t in app.call('tabs') if t['url'].startswith('open://note/') and t.get('selected')), None), timeout=5, step=.05)
    assert note, 'no selected Note'
    app.call('sidebar-menu', node=note, item='Delete Note')
    h.wait_until(lambda: (lambda s: s if s.get('shown') else None)(app.call('note', action='sheet')), timeout=5, step=.05)
    app.call('note', action='sheet', press='Delete')
    gone = h.wait_until(lambda: all(t['id'] != note for t in app.call('tabs')) or None, timeout=5, step=.05)
    selected = h.wait_until(lambda: [t['id'] for t in app.call('tabs') if t.get('selected')] or None, timeout=3, step=.05) or []
    row('R5_delete_selected_note_selects_neighbour', bool(gone) and bool(selected) and selected[0] != note,
        selected=selected, page=page, negative='old: the deleted Note stays the window selection; nothing shows')


def bst01_editor_uses_invoking_window(app, row, h, origin):
    """BST-01: one pinned tab shows in two windows, each with its own page (a.r6.test, b.r6.test).
    New Boost in each window edits that window's page. Old: both resolved to the same window (the
    first in an unordered dictionary), so one window's editor opened in, and for, the other."""
    port = origin.rsplit(':', 1)[1]
    a_url, b_url = 'http://a.r6.test:%s/one' % port, 'http://b.r6.test:%s/two' % port
    w1 = app.call('window-state')['id']
    tab = h.new_tab(app, a_url)
    app.call('pin', tab=tab)
    app.call('menu-perform', id='new-window')
    w2 = h.wait_until(lambda: (lambda s: s['id'] if s['id'] != w1 else None)(app.call('window-state')), timeout=5)
    assert w2, 'no second window'
    def editor(window): return app.call('boost-editor', window=window)
    def domain(state): return ((state.get('boost') or {}).get('siteMatch') or {}).get('domain')
    try:
        if app.call('commandbar-state', window=w2).get('presented'): app.call('key', key='escape', window=w2, route='app')
        app.call('select', tab=tab, window=w2)
        h.wait_until(lambda: any(t['id'] == tab and t.get('selected') for t in app.call('tabs', window=w2)), timeout=5)
        app.call('navigate', tab=tab, url=b_url, window=w2); app.call('wait', tab=tab, window=w2)
        shown = {}
        for w in (w1, w2):
            app.call('window-focus', id=w, activate=True); shown[w] = app.eval(tab, 'location.host')
        seen = {}
        for window in (w1, w2):
            app.call('window-focus', id=window, activate=True)
            app.call('menu-perform', id='new-boost')
            state = h.wait_until(lambda: (lambda s: s if s.get('open') else None)(editor(window)), timeout=8, step=.05) or editor(window)
            seen[window] = {'open': state.get('open'), 'domain': domain(state)}
            for other in (w1, w2):
                if editor(other).get('open'): app.call('boost-editor', action='close', window=other)
        row('BST01_new_boost_edits_invoking_windows_page', shown == {w1: 'a.r6.test:' + port, w2: 'b.r6.test:' + port}
            and seen[w1] == {'open': True, 'domain': 'a.r6.test'} and seen[w2] == {'open': True, 'domain': 'b.r6.test'},
            pages=shown, editors=seen, negative='old: one window\'s New Boost opened in the other window, for its site')
    finally:
        app.call('window-focus', id=w2, activate=True); app.call('window-close')
        app.call('window-focus', id=w1, activate=True)
        try: app.call('pin', tab=tab)  # unpin
        except RuntimeError: pass


def bst02_library_edit_closes_library(app, row, h, origin):
    """BST-02: Library ▸ Boosts ▸ Edit Boost closes the Library before the editor opens on the page.
    Old: the Library overlay stayed over the page and the floating editor."""
    tab = h.new_tab(app, origin + '/boost-page')
    app.call('menu-perform', id='new-boost')
    assert h.wait_until(lambda: app.call('boost-editor').get('colorsReady'), timeout=10)
    app.call('boost-editor', action='tap', id='font.Avenir')
    boost = app.call('boost-editor')['boost']['id']
    app.call('boost-editor', action='close')
    app.call('library', action='open', section='boosts')
    assert h.wait_until(lambda: any(r['id'] == boost for r in app.call('library').get('rows', [])), timeout=8, step=.05)
    tabs_before = {t['id'] for t in app.call('tabs')}
    app.call('library', action='row-menu', id=boost, select='Edit Boost')
    opened = h.wait_until(lambda: next((t for t in app.call('tabs') if t['id'] not in tabs_before and t.get('selected')), None), timeout=10)
    library = h.wait_until(lambda: (lambda s: s if not s.get('open') else None)(app.call('library')), timeout=3, step=.05) or app.call('library')
    row('BST02_library_edit_closes_library', bool(opened) and not library.get('open'),
        opened=opened and opened['url'], libraryOpen=library.get('open'), editorOpen=app.call('boost-editor').get('open'),
        negative='old: the Library stays open over the Boost page and its editor')
    if app.call('boost-editor').get('open'): app.call('boost-editor', action='close')
    if app.call('library').get('open'): app.call('library', action='close')


def adb01_ipv6_allowed_site(app, row, h):
    """ADB-01: an IPv6 literal can be added to and removed from Allowed Sites in Settings; a host with
    a port is still refused. Old: "::1" (also one Site Control saved) could not be removed."""
    app.call('settings-pane', pane='advanced')
    if not h.wait_until(lambda: app.call('settings-adblock')['ready'], timeout=30):
        app.call('settings-adblock', enabled=True)
        h.wait_until(lambda: app.call('settings-adblock')['ready'], timeout=30)
    def domains(): return None  # Settings exposes no list here; the save result is the evidence.
    added = app.call('settings-adblock', host='::1', excluded=True)
    after_add = domains()
    removed = app.call('settings-adblock', host='::1', excluded=False)
    after_remove = domains()
    port = app.call('settings-adblock', host='example.com:8080', excluded=True)
    row('ADB01_ipv6_allowed_site_add_remove', added['error'] == '' and removed['error'] == ''
        and port['error'] != '' and (after_add is None or '::1' in after_add) and (after_remove is None or '::1' not in after_remove),
        addError=added['error'], removeError=removed['error'], portError=port['error'], afterAdd=after_add, afterRemove=after_remove,
        negative='old: "Enter a host only, such as example.com." for ::1')
    app.call('settings-adblock', host='::1', excluded=False)


def ext04_little_open_menu(app, row, h, origin):
    """EXT-04: with Little Open key, Extensions ▸ Manage/Add/Shortcuts are enabled and run.
    Old: all three stayed disabled (menu-perform refused them)."""
    before = {s['id'] for s in app.call('little-open-state')['sessions']}
    app.call('menu-perform', id='new-little-open-window')
    little = h.wait_until(lambda: next((s for s in app.call('little-open-state')['sessions'] if s['id'] not in before), None), timeout=8)
    assert little, 'no Little Open window'
    app.call('key', window=little['window'], text=origin + '/little\r', route='app')
    h.wait_until(lambda: next((s for s in app.call('little-open-state')['sessions'] if s['id'] == little['id'] and s['state'] == 'page'), None), timeout=15)
    app.call('little-open-action', id=little['id'], action='focus')
    time.sleep(.3)
    items = {r['id']: r['enabled'] for r in app.call('menu-state') if r['id'] in ('manage-extensions', 'add-extension', 'extension-shortcuts')}
    tabs_before = {t['id'] for t in app.call('tabs')}
    try:
        app.call('menu-perform', id='manage-extensions'); performed = True
    except RuntimeError as error: performed = str(error)
    opened = h.wait_until(lambda: next((t for t in app.call('tabs') if t['id'] not in tabs_before and t['url'].startswith('chrome://extensions')), None), timeout=8)
    row('EXT04_little_open_extensions_menu_enabled', items.get('manage-extensions') is True and items.get('add-extension') is True
        and performed is True and bool(opened), items=items, performed=performed, opened=opened,
        negative='old: the three items are disabled while Little Open is key')
    try: app.call('little-open-action', id=little['id'], action='close')
    except RuntimeError: pass


def ext05_incognito_table_follows_rebind(app, row, h, origin):
    """EXT-05: binding an Open command to an extension's key in Settings turns that command off in an
    open Incognito window too. Old: the Incognito manager's table was never rebuilt (stale, still on)."""
    main = app.call('window-state')['id']
    page = h.new_tab(app, 'chrome://extensions')
    h.wait_until(lambda: app.eval(page, "typeof chrome.developerPrivate.updateExtensionConfiguration") == 'function', timeout=10)
    allowed = app.eval(page, "new Promise(done=>chrome.developerPrivate.updateExtensionConfiguration(" +
        json.dumps({'extensionId': PROBE, 'incognitoAccess': True}) + ",()=>done(chrome.runtime.lastError?.message||true)))")
    app.call('close', tab=page)
    def private(): return [w for w in app.call('incognito-state')['windows'] if w['private']]
    before = {w['id'] for w in private()}
    app.call('menu-perform', id='new-incognito-window')
    window = h.wait_until(lambda: next((w['id'] for w in private() if w['id'] not in before), None), timeout=8, step=.05)
    assert window, 'no Incognito window'
    def probe_row():
        rows = app.call('ext-commands')['commands']  # the Incognito window is in front
        return next((c for c in rows if c['extension'] == PROBE and c['name'] == 'probe-named'), None)
    try:
        app.call('window-focus', id=window, activate=True)
        if app.call('commandbar-state', window=window).get('presented'): app.call('key', key='escape', window=window, route='app')
        h.new_tab(app, origin + '/ext05', window=window)
        free = h.wait_until(probe_row, timeout=10)
        app.call('settings-pane', pane='shortcuts')
        app.call('ext-shortcuts', action='record', id='new-tab', key='u', modifiers=['command', 'shift'])
        app.call('ext-shortcuts', action='close')
        after = h.wait_until(lambda: (lambda c: c if c and c.get('dropped') else None)(probe_row()), timeout=5) or probe_row()
        row('EXT05_incognito_shortcut_table_rebuilt', allowed is True and bool(free) and not free.get('dropped')
            and bool(after) and after.get('dropped') and after.get('openCommandID') == 'new-tab',
            allowed=allowed, before=free, after=after, commands=app.call('ext-commands').get('commands'),
            privateExtensions=app.call('incognito-state', private=True).get('extensions'),
            negative='old: the Incognito table keeps the probe command on after the rebind')
    finally:
        app.call('settings-pane', pane='shortcuts')
        app.call('ext-shortcuts', action='reset', id='new-tab')
        app.call('ext-shortcuts', action='close')
        app.call('window-focus', id=window, activate=True); app.call('window-close')
        app.call('window-focus', id=main, activate=True)


def r4_renewed_session_forgets_developer_mode(app, row, h, origin):
    """R4: an Incognito window whose session ended (its last tab closed) and renewed (a new page)
    shows no Developer Mode bar for a site turned on in the old session. Old: the window kept the
    old session's Developer Mode sites until some other change posted didChange."""
    main = app.call('window-state')['id']
    def private(): return [w for w in app.call('incognito-state')['windows'] if w['private']]
    before = {w['id'] for w in private()}
    app.call('menu-perform', id='new-incognito-window')
    window = h.wait_until(lambda: next((w['id'] for w in private() if w['id'] not in before), None), timeout=8, step=.05)
    assert window, 'no Incognito window'
    try:
        # developer-panel and incognito-state read the front window: keep this one in front.
        app.call('window-focus', id=window, activate=True)
        if app.call('commandbar-state', window=window).get('presented'): app.call('key', key='escape', window=window, route='app')
        tab = h.new_tab(app, origin + '/r4', window=window)
        app.call('command', id='toggle-developer-mode', window=window)
        on = h.wait_until(lambda: (lambda s: s if s.get('shown') else None)(app.call('developer-panel')), timeout=8, step=.05) or app.call('developer-panel')
        def session(): return app.call('incognito-state', private=True)['session']
        app.call('close', tab=tab, window=window)
        closed = h.wait_until(lambda: (lambda s: s if s['closed'] else None)(session()), timeout=8, step=.05) or session()
        renewed_tab = h.new_tab(app, origin + '/r4', window=window)
        renewed = h.wait_until(lambda: (lambda s: s if not s['closed'] and s['context'] != closed['context'] else None)(session()), timeout=8, step=.05) or session()
        app.call('select', tab=renewed_tab, window=window)
        time.sleep(.5)
        off = app.call('developer-panel')
        row('R4_renewed_private_session_drops_developer_mode', bool(on.get('shown')) and closed['closed']
            and not renewed['closed'] and renewed['context'] != closed['context'] and off.get('shown') is False,
            onShown=on.get('shown'), sessions=[closed, renewed], offShown=off.get('shown'), url=off.get('url'),
            negative='old: the renewed session still shows the old session\'s Developer Mode bar')
    finally:
        app.call('window-focus', id=window, activate=True); app.call('window-close')
        app.call('window-focus', id=main, activate=True)


def adb03_no_list_fetch_while_off(factory, row, h):
    """ADB-03: with Ad Blocking off, the scheduled list update makes no network request.
    Old: the schedule fetched every enabled list (first check 60 s after launch, here scaled to 6 s)."""
    hits = []
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            hits.append(self.path); self.send_response(404); self.end_headers()
        def log_message(self, *args): pass
    lists = h.LoopbackHTTPServer(Handler)
    threading.Thread(target=lists.serve_forever, daemon=True).start()
    app = None
    try:
        env = {'OPEN_ADBLOCK_DEBUG_SOURCE_ROOT': 'http://127.0.0.1:%d' % lists.server_port,
               'OPEN_ADBLOCK_DEBUG_SCHEDULE_SCALE': '0.1'}
        app = factory(urls=('about:blank',), fresh=True, load_extensions=False, extra_env=env)
        app.call('settings-pane', pane='advanced')
        state = app.call('settings-adblock', enabled=False)
        off_at = time.monotonic()
        del hits[:]
        time.sleep(15)  # scaled first check: max(60 s, due) × 0.1, plus a 60 s × 0.1 retry
        off_hits = list(hits)
        app.call('settings-adblock', enabled=True)
        on_hits = h.wait_until(lambda: list(hits) or None, timeout=15) or []
        row('ADB03_no_scheduled_fetch_while_off', not state['enabled'] and off_hits == [] and bool(on_hits),
            offRequests=off_hits[:6], onRequests=on_hits[:3], offSeconds=round(time.monotonic() - off_at, 1),
            negative='old: list requests arrive while Ad Blocking is off')
        app.call('settings-adblock', enabled=True)
    finally:
        if app: app.quit()
        lists.shutdown(); lists.server_close()
