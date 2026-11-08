"""First run through the real App, using only owned roots and synthetic data."""
import json
import os
import runpy
from pathlib import Path
import sqlite3
import shutil
import statistics
import subprocess
import time
import uuid


def fixture(root):
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    ids = {name: str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/first-run/' + name)).upper()
           for name in ('alpha', 'beta', 'p0', 'p1', 'p2', 't0', 't1', 'favorite', 'folder', 'welcome', 'easel',
                        'pa', 'pb', 'ta', 'tb', 'top', 'window', 'archive0', 'archive1', 'archive-easel')}
    now = time.time() - 978307200
    items = []
    def item(name, data, children=()):
        items.extend([ids[name], dict(id=ids[name], data=data, childrenIds=[ids[n] for n in children],
                                     title='Example ' + name, createdAt=now)])
    for name in ('p0', 'p1', 'p2', 't0', 't1', 'favorite'):
        item(name, {'tab': dict(savedURL='https://example.com/' + name,
                               savedTitle='Example ' + name, timeLastActiveAt=now)})
    item('welcome', {'welcomeToArc': {'savedURL': 'https://example.com/welcome', 'timeLastActiveAt': now}})
    item('easel', {'easel': {}})
    item('folder', {'list': {}}, ('p1',))
    for container, children in [('pa', ('p0', 'folder')), ('pb', ('p2',)),
                                ('ta', ('t0', 'welcome', 'easel')), ('tb', ('t1',)), ('top', ('favorite',))]:
        item(container, {'itemContainer': {}}, children)
    spaces = []
    for name, title, pinned, today in [('alpha', 'Alpha', 'pa', 'ta'), ('beta', 'Beta', 'pb', 'tb')]:
        spaces.extend([ids[name], dict(id=ids[name], title=title, profile={'default': True},
                                      containerIDs=['pinned', ids[pinned], 'unpinned', ids[today]])])
    def write(name, obj): (root / name).write_text(json.dumps(obj))
    write('StorableSidebar.json', {'sidebar': {'containers': ['synthetic', dict(items=items, spaces=spaces,
                                                                topAppsContainerIDs=[{'default': True}, ids['top']])]}})
    write('StorableWindows.json', {'windows': [dict(id=ids['window'], focusedSpaceID=ids['alpha'],
                                                    expandedItems=[ids['folder'], {'expanded': {}}])]})
    write('StorableSessionRestorationData.json', {'mapping': {'keysToValues': [
        {'browser': {'windowID': ids['window'], 'contextID': {}}, 'itemId': ids['t0']}, 1]}})
    write('StorableLinkRouting.json', {'defaultDestination': {'littleArc': {}}, 'rules': [
        {'sourceComponents': [{'componentType': {'urlMatch': {'_0': {'contains': {}}, '_1': 'example.org'}}}],
         'destination': {'space': {'_0': {'mostRecent': {}}}}}]})
    archive = []
    for index, reason in enumerate(('manual', 'auto')):
        name = 'archive' + str(index)
        archive.extend([ids[name], dict(sidebarItem=dict(id=ids[name], data={'tab': {
            'savedURL': 'https://example.org/archive/' + str(index), 'savedTitle': 'Example archived tab'}}),
            reason=reason, archivedAt=now, source={'space': {'_0': ids['alpha']}})])
    archive.extend([ids['archive-easel'], dict(sidebarItem=dict(id=ids['archive-easel'], data={'easel': {}}), reason='manual')])
    write('StorableArchiveItems.json', {'items': archive})
    profile = root / 'User Data/Default'
    profile.mkdir(mode=0o700, parents=True)
    with sqlite3.connect(profile / 'History') as db:
        db.executescript("""
        CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','70');
        CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT,hidden INTEGER);
        CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER,transition INTEGER,incremented_omnibox_typed_score INTEGER);
        CREATE TABLE keyword_search_terms(keyword_id INTEGER,url_id INTEGER,term TEXT,normalized_term TEXT);
        INSERT INTO urls VALUES(1,'https://example.com/a','Example History A',0),(2,'https://example.org/b','Example History B',0),(3,'chrome://settings','Example Internal',0);
        INSERT INTO visits VALUES(1,1,13437000000000000,0,0),(2,1,13437000005000000,1,1),(3,2,13437000010000000,8,0),(4,3,13437000020000000,0,0),(5,1,13437000030000000,3,0),(6,1,0,0,0);
        """)
    with sqlite3.connect(profile / 'Login Data') as db:
        db.executescript('CREATE TABLE logins(blacklisted_by_user INTEGER); INSERT INTO logins VALUES(0);')
    with sqlite3.connect(profile / 'Cookies') as db:
        db.executescript("CREATE TABLE cookies(host_key TEXT); INSERT INTO cookies VALUES('example.com'),('example.org');")
    return ids


def run(factory, results, tmp, h):
    if os.environ.get('OPEN_E2E_FIRSTRUN_MULTIPROFILE_ONLY') == '1':
        return runpy.run_path(str(Path(h.ROOT)/'tools/e2e/firstrun_multiprofile.py'))['run'](factory, results, tmp, h)
    source = Path(tmp) / 'arc-synthetic'
    shutil.rmtree(source, ignore_errors=True)
    ids = fixture(source)
    evidence = Path(h.OUT) / 'firstrun'
    evidence.mkdir(exist_ok=True)
    saved = {}
    app = None
    all_copy = []
    ocr_retries = []
    def launch(fresh=False, directory=source, **env):
        nonlocal app
        app = factory(urls=(), fresh=fresh, extra_args=['--arc-dir=' + str(directory)], extra_env=env)
        app.call('first-run', action='focus') if app.call('first-run')['active'] else None
        return app
    def state(): return app.call('first-run')
    def until(step):
        assert h.wait_until(lambda: state()['step'] == step, timeout=15, step=.05), state()
        return state()
    def shot(name):
        path = str(evidence / (name + '.png'))
        time.sleep(.25)  # normal step fade, not import work
        app.call('snapshot', path=path)
        return path
    def copy():
        inspection = app.call('first-run', action='inspect', timeout=180)
        ocr_retries.append(inspection['ocrRetries'])
        rows = inspection['renderedText']
        text = '\n'.join(row['text'] for row in rows)
        all_copy.append(text)
        return text
    def row(name, ok, **detail): results[name] = dict(ok=bool(ok), load=os.getloadavg(), **detail)
    def user_tabs(): return [t for t in app.call('tabs') if t['url'] != 'open://welcome']
    def snapshot_path(): return Path(app.user_data) / 'State/browser.json'
    def saved_tab_ids():
        found = []
        def walk(value):
            if isinstance(value, dict):
                if {'id', 'url', 'lastActiveAt'} <= value.keys() and value['url'] != 'open://welcome': found.append(value['id'])
                for child in value.values(): walk(child)
            elif isinstance(value, list):
                for child in value: walk(child)
        walk(json.loads(snapshot_path().read_text()))
        return found
    def archives():
        # SQLite paths are the App's private destination; read the closed saved
        # output only, never a source database. The normal API also checks counts.
        return app.call('archive-list')
    try:
        if os.environ.get("OPEN_E2E_IMPORT_EXT_ONLY") == "1":
            runpy.run_path(str(Path(h.ROOT)/"tools/e2e/firstrun_extensions.py"))["run"](launch, state, until, row, source, tmp, h, results)
            return
        app = launch(fresh=True, OPEN_AUTOMATION_IMPORT_DELAY_MS='1500')
        for key in ('open.firstRun.completed', 'open.import.lastArcDir', 'open.settings.lastPane', 'open.advanced.tabSleepMode'):
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=None)
        s = state(); welcome = shot('welcome'); welcome_copy = copy()
        row('window_size', s['frameSize'] == [1280, 800] and s['key'], size=s['frameSize'])
        row('F1_welcome', s['active'] and s['step'] == 'welcome' and not s['completed']
            and not app.call('shell-windows') and not snapshot_path().exists()
            and any(w['number'] == s['window'] and w['class'] == 'OnboardingWindow' for w in app.call('windows')), state=s, png=welcome)
        assert h.wait_until(lambda: state().get('probeReady'), timeout=10, step=.05)
        s = state()
        row('F2_probe', s['counts'].get('Spaces') == 2 and s['counts'].get('Archive') == 2
            and s['counts'].get('History') == 3 and s['counts'].get('Passwords and cookies') == 3,
            counts=s['counts'], rawArchive=3, filteredArchive=2)
        app.call('key', key='escape')
        app.call('key', key='t', modifiers=['command'])
        app.call('key', key='l', modifiers=['command'])
        row('welcome_keyboard_guards', state()['step'] == 'welcome' and not app.call('shell-windows'))
        app.call('key', key='return'); until('importChoices')
        limits = []
        for action in ('x'*32, 'x'*33):
            try: app.call('first-run', action=action); limits.append('accepted')
            except RuntimeError as error: limits.append(str(error))
        app.call('first-run', action='choose-dir', directory='/'+'a'*4095)
        try: app.call('first-run', action='choose-dir', directory='/'+'a'*4096); limits.append('accepted')
        except RuntimeError as error: limits.append(str(error))
        app.call('first-run', action='choose-dir', directory=str(source))
        row('automation_limits', 'unknown first-run action' in limits[0]
            and all('exceeds limit' in error for error in limits[1:]), results=limits)
        imported_png = shot('import'); import_copy = copy()
        row('F2_import_choices', not state()['secretsEnabled'] and 'Bring your tabs with you.' in import_copy,
            png=imported_png, text=import_copy)
        geometry = app.call('first-run', action='inspect', timeout=180)
        ocr_retries.append(geometry['ocrRetries'])
        heading = [r for r in geometry['renderedText'] if 'Bring your tabs' in r['text']]
        light_bottom = max(r[1]+r[3] for r in geometry['trafficLights'])
        heading_top = min((r['frame'][1] for r in heading), default=0)
        row('titlebar_clearance', heading_top >= 36 and heading_top > light_bottom,
            headingTop=heading_top, trafficLightsBottom=light_bottom, png=imported_png)
        app.call('first-run', action='continue'); until('importing')
        progress_state = state()
        progress1 = shot('progress'); time.sleep(.15); progress2 = shot('progress-animation')
        progress_after = state()
        w1, h1, p1 = h.read_image(progress1); w2, h2, p2 = h.read_image(progress2)
        # Only the hosted progress area in the left pane. The room's moving
        # orbs and the right preview cannot satisfy the animation assertion.
        changed = sum(p1(x,y) != p2(x,y) for y in range(int(h1*300/800), int(h1*650/800))
                      for x in range(int(w1*80/1280), int(w1*440/1280))) if (w1,h1) == (w2,h2) else 0
        row('N9_indeterminate_animation', changed > 0 and progress_state['step']==progress_after['step']=='importing'
            and progress_state['phase']==progress_after['phase'] and progress_state['progress'] is None,
            changedPixels=changed, phase=progress_state['phase'], pngs=[progress1,progress2])
        s = until('report'); report_png = shot('report'); copy()
        counts = s['outcome']
        tabs = user_tabs()
        row('F3_import', counts.get('Imported Spaces') == 2 and counts.get('Imported tabs') == 7
            and counts.get('Imported Archive') == 2 and counts.get('Folders') == 1
            and counts.get('Sidebar accounted') == counts.get('Sidebar total')
            and counts.get('Archive accounted') == counts.get('Archive total')
            and counts.get('Imported welcome') == 1 and counts.get('Session selections') == 1
            and {s['title'] for s in app.call('spaces')} == {'Alpha','Beta'}
            and [t['id'] for t in tabs if t['selected']] == [ids['t0']]
            and archives()['count'] == 2, counts=counts, png=report_png)
        app.call('first-run', action='continue'); s = until('defaultBrowser')
        default_png = shot('default-browser'); default_copy = copy()
        # OCR preserves the title's visual line wrap in the new setup panel.
        # Keep the exact words and the no-default-request assertion.
        default_text = ' '.join(default_copy.split())
        row('F4_default_offer', not s['defaultAttempted'] and 'Make Open your default browser?' in default_text
            and ('Open is your default browser.' in default_text if s['defaultBrowser'] else
                 'Yes, make Open my default.' in default_text and 'Not yet.' in default_text), png=default_png, text=default_copy)
        app.call('first-run', action='finish')
        row('F4_finish', not state()['active'] and state()['completed'] and len(app.call('shell-windows')) == 1)
        # Never invoke the real system-default setter. Setup automation stubs it.
        # Exercise Profile insertion on the model swapped in by first run,
        # before a relaunch could reinstall a missing onProfileCreated hook.
        never_source = Path(tmp) / 'arc-never-profile'
        shutil.rmtree(never_source, ignore_errors=True)
        shutil.copytree(source, never_source)
        (never_source/'StorableProfiles.json').write_text(json.dumps({'profiles': [
            'synthetic-never', {'id': 'synthetic-never', 'name': 'Example Imported Profile',
                                'directory': 'Profile-Never'}]}))
        never_before = app.call('sleep-mode', mode='off')
        app.call('first-run', action='settings-import', directory=str(never_source))
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        assert h.wait_until(lambda: state().get('settingsStep') == 'Report', timeout=15, step=.05), state()
        never_after = app.call('sleep-mode')
        app.call('first-run', action='settings-done')
        app.quit(); app = launch()
        row('F4_relaunch', not state()['active'] and {s['title'] for s in app.call('spaces')} == {'Alpha','Beta'})
        never_reloaded = app.call('sleep-mode')
        row('settings_import_never_policy', len(never_after) == len(never_before) + 1
            and set(never_before.values()) == {'off'} and set(never_after.values()) == {'off'}
            and never_reloaded == never_after
            and app.call('defaults', key='open.advanced.tabSleepMode') == 'never',
            before=never_before, after=never_after, reloaded=never_reloaded)
        before_tabs = {t['id'] for t in user_tabs()}
        app.call('first-run', action='settings-import', directory=str(source))
        if os.environ.get('OPEN_E2E_FIRSTRUN_FORCE_FAILURE') == 'settings-sheet':
            raise RuntimeError('forced failure with the real Settings sheet open (cleanup proof)')
        app.call('first-run', action='settings-next')
        app.call('first-run', action='settings-run')
        assert h.wait_until(lambda: state().get('settingsStep') == 'Report', timeout=15, step=.05), state()
        again = state()['settingsOutcome']; now_tabs = user_tabs()
        row('F5_settings_reimport', again.get('Imported Archive', 0) == 0
            and again.get('Duplicates') == 12 and again.get('Imported Spaces') == 0
            and again.get('Imported tabs') == 0 and archives()['count'] == 2
            and len({t['id'] for t in now_tabs}) == len(now_tabs)
            and before_tabs == {t['id'] for t in now_tabs}
            and len(saved_tab_ids()) == len(set(saved_tab_ids())) == 7, outcome=again, error=state().get('settingsError'))
        app.call('first-run', action='settings-done')
        snapshot = json.loads(snapshot_path().read_text())
        row('routing_reimport', len(snapshot['routingRules']) == 1, rules=len(snapshot['routingRules']))
        # Add one real source item and change source metadata. The live Space
        # remains authoritative; one native Undo must remove the whole merge.
        expanded = Path(tmp) / 'arc-expanded'
        shutil.rmtree(expanded, ignore_errors=True)
        shutil.copytree(source, expanded)
        sidebar = json.loads((expanded/'StorableSidebar.json').read_text())
        graph = sidebar['sidebar']['containers'][1]
        new_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/first-run/new')).upper()
        graph['items'] += [new_id, dict(id=new_id, data={'tab': dict(savedURL='https://example.com/new',
            savedTitle='Example new', timeLastActiveAt=time.time()-978307200)}, childrenIds=[])]
        graph['items'][graph['items'].index(ids['ta'])+1]['childrenIds'].append(new_id)
        graph['spaces'][graph['spaces'].index(ids['alpha'])+1]['title'] = 'Changed upstream'
        (expanded/'StorableSidebar.json').write_text(json.dumps(sidebar))
        def settings_import(directory):
            app.call('first-run', action='settings-import', directory=str(directory))
            app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
            assert h.wait_until(lambda: state().get('settingsStep') == 'Report', timeout=15, step=.05), state()
        settings_import(expanded)
        row('settings_merge_live', state()['settingsOutcome'].get('Imported tabs') == 1
            and {s['title'] for s in app.call('spaces')} == {'Alpha', 'Beta'}
            and new_id in {t['id'] for t in user_tabs()}, outcome=state()['settingsOutcome'])
        app.call('first-run', action='settings-done')
        browser_id = app.call('shell-windows')[0]['id']
        app.call('window-focus', id=browser_id, activate=True)
        undo_before = app.call('space-manager-state')
        # Focus the sidebar before the native App key path. A page owns its
        # own Undo action while its RenderWidgetHostViewCocoa is first responder.
        undo_key = app.call('sidebar-key', key='z', modifiers=['command'])
        undone_tabs = {t['id'] for t in user_tabs()}
        row('settings_merge_one_undo', undone_tabs == before_tabs,
            before=undo_before, key=undo_key, after=app.call('space-manager-state'),
            expected=sorted(before_tabs), actual=sorted(undone_tabs))
        app.call('save')
        previous = snapshot_path().read_bytes()
        snapshot_path().unlink(); snapshot_path().mkdir()
        settings_import(expanded)
        row('settings_merge_save_rollback', 'previous browser state was kept' in state()['settingsError']
            and {t['id'] for t in user_tabs()} == undone_tabs, error=state()['settingsError'])
        snapshot_path().rmdir(); snapshot_path().write_bytes(previous)
        app.call('first-run', action='settings-done')
        app.quit()
        # Quit during the runner's real, cancellable progress delay. Browser
        # edits still use the normal debounced/quit save while Settings imports.
        app = launch(OPEN_AUTOMATION_IMPORT_DELAY_MS='5000')
        rename_space = app.call('spaces')[0]['id']
        app.call('space', space=rename_space)
        app.call('first-run', action='settings-import', directory=str(expanded))
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        assert h.wait_until(lambda: state().get('importInProgress'), timeout=3, step=.02), state()
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        app.call('menu-perform', id='rename-space')
        app.call('key', text='Renamed During Import')
        app.call('key', key='return', route='app')
        during_import = state()
        renamed = next(s for s in app.call('spaces') if s['id'] == rename_space)
        assert during_import.get('importInProgress') and during_import.get('settingsStep') == 'Importing', during_import
        assert renamed['title'] == 'Renamed During Import', renamed
        app.quit(); import_quit = app.quit_report
        app = launch()
        landed_rename = next(s for s in app.call('spaces') if s['id'] == rename_space)
        row('R1_settings_import_quit_save', landed_rename['title'] == 'Renamed During Import'
            and new_id not in {t['id'] for t in user_tabs()}
            and not import_quit.get('forced'), space=landed_rename,
            duringImport=during_import, cleanup=import_quit)
        app.quit()
        # A readable zero-item source still offers Spaces. Its importer-created
        # fallback model must not replace the unsaved first-run default model.
        zero = Path(tmp) / 'arc-zero-items'; zero.mkdir(exist_ok=True)
        (zero/'StorableSidebar.json').write_text(json.dumps(
            {'sidebar': {'containers': ['synthetic', {'items': [], 'spaces': []}]}}))
        app = launch(fresh=True, directory=zero)
        app.call('defaults', key='open.firstRun.completed', value=None)
        default_spaces = app.call('spaces')
        app.call('first-run', action='import')
        app.call('first-run', action='select', spaces=True, archive=False, history=False)
        app.call('first-run', action='continue'); zero_report = until('report')
        row('R2_empty_sidebar_report', zero_report['outcome'].get('Imported Spaces') == 0
            and zero_report['outcome'].get('Imported tabs') == 0
            and not zero_report['outcome'].get('Search settings', 0)
            and app.call('spaces') == default_spaces and not snapshot_path().exists()
            and not app.call('shell-windows'), outcome=zero_report['outcome'])
        # Stop before Finish if a regression swapped models: the old Debug
        # assertion would crash and put a system dialog on the shared display.
        assert app.call('spaces') == default_spaces, 'empty import replaced the default model; do not finish'
        app.call('first-run', action='continue'); until('defaultBrowser')
        app.call('first-run', action='finish')
        row('R2_empty_sidebar_continue', not state()['active'] and state()['completed']
            and [s['id'] for s in app.call('spaces')] == [s['id'] for s in default_spaces]
            and user_tabs() == []
            and snapshot_path().is_file())
        app.quit()
        # Closing setup now quits rather than leaving an old first-run panel.
        # Restart a new process on the same unsaved root while counting is pending.
        app = launch(fresh=True, OPEN_AUTOMATION_PROBE_DELAY_MS='5000')
        app.call('defaults', key='open.firstRun.completed', value=None)
        counting = state(); assert not counting['probeReady'], counting
        app.quit(); app = launch()
        assert h.wait_until(lambda: state().get('probeReady'), timeout=15, step=.05), state()
        reopened = state()
        row('R3_restart_restarts_probe', reopened['active'] and reopened['screen']=='name'
            and reopened['counts'].get('Spaces') == 2 and reopened['counts'].get('Archive') == 2
            and not snapshot_path().exists() and not app.call('shell-windows'), state=reopened)
        app.quit()
        app = launch(fresh=True)
        app.call('defaults', key='open.firstRun.completed', value=None)
        app.call('first-run', action='fresh')
        row('F6_start_fresh', not state()['active'] and len(app.call('spaces')) == 1 and user_tabs() == [])
        app.quit(); app = launch()
        row('F6_relaunch', not state()['active'] and len(app.call('spaces')) == 1)
        app.quit()
        empty = Path(tmp) / 'empty-arc'; empty.mkdir(exist_ok=True)
        app = launch(fresh=True, directory=empty)
        assert h.wait_until(lambda: state().get('probeReady'), timeout=10, step=.05)
        app.call('onboarding', action='next'); text = copy()
        row('F7_no_data', not state()['sidebarFound'] and state()['screen']=='favorites' and 'Choose the sites' in text, text=text)
        app.call('onboarding', action='back'); app.call('first-run', action='fresh')
        app.quit()
        app = launch(fresh=True)
        app.call('defaults', key='open.firstRun.completed', value=None)
        app.call('first-run', action='import'); app.call('save')
        app.quit()
        row('F11_save_guard', not (Path(app.user_data)/'State/browser.json').exists())
        app = launch()
        row('F11_relaunch', state()['step'] == 'welcome' and not state()['completed'])
        app.quit()
        corrupt = Path(tmp) / 'bad-sidebar'; corrupt.mkdir(exist_ok=True); (corrupt/'StorableSidebar.json').write_text('{}')
        app = launch(fresh=True, directory=corrupt)
        app.call('defaults', key='open.firstRun.completed', value=None)
        baseline = app.call('spaces')
        app.call('first-run', action='import'); app.call('first-run', action='continue'); s = until('failed')
        shot('failed')
        row('E1_corrupt_sidebar', app.call('spaces') == baseline and not snapshot_path().exists()
            and not s['completed'] and not app.call('shell-windows'), error=s['error'])
        app.quit(); app = launch(directory=corrupt)
        row('E1_relaunch', state()['step'] == 'welcome' and not snapshot_path().exists())
        app.quit()
        app = launch(fresh=True)
        app.call('defaults', key='open.firstRun.completed', value=None)
        snapshot_path().mkdir()
        app.call('first-run', action='fresh')
        s = state()
        row('fresh_save_failure', s['active'] and not s['completed'] and 'Try Start Fresh again' in s['error']
            and not app.call('shell-windows'), error=s['error'])
        snapshot_path().rmdir()
        app.call('first-run', action='fresh')
        row('fresh_save_retry', not state()['active'] and state()['completed'] and snapshot_path().is_file())
        app.quit()
        app = launch(fresh=True)
        app.call('defaults', key='open.firstRun.completed', value=None)
        snapshot_path().mkdir()
        app.call('first-run', action='import'); app.call('first-run', action='continue')
        s = until('report')
        pending = {t['id'] for t in user_tabs()}
        row('N4_import_save_failure', not s['completed'] and s['active']
            and 'browser window behind this panel' in s['error'] and pending == before_tabs
            and len(app.call('shell-windows')) == 1, error=s['error'], pendingTabs=len(pending),
            state=s, browserWindows=app.call('shell-windows'))
        shot('report-saveerror')
        snapshot_path().rmdir()
        app.call('first-run', action='retry')
        row('N4_import_save_retry', not state()['active'] and state()['completed'] and snapshot_path().is_file()
            and pending == {t['id'] for t in user_tabs()})
        app.quit()
        app = launch(fresh=True)
        app.call('defaults', key='open.firstRun.completed', value=None)
        app.call('first-run', action='import'); app.call('first-run', action='notnow')
        s = state()
        row('notnow_offer', s['step'] == 'defaultBrowser' and not s['completed'] and not s['defaultAttempted'])
        app.call('first-run', action='notnow')
        row('notnow_finish', not state()['active'] and state()['completed'] and user_tabs() == [])
        app.quit()
        partial = Path(tmp) / 'arc-partial'
        shutil.rmtree(partial, ignore_errors=True); shutil.copytree(source, partial)
        (partial/'StorableArchiveItems.json').write_text('{}')
        app = launch(fresh=True, directory=partial)
        app.call('defaults', key='open.firstRun.completed', value=None)
        app.call('first-run', action='import'); app.call('first-run', action='continue')
        s = until('report')
        row('partial_archive_failure', not s['completed'] and s['outcome'].get('Imported Spaces') == 2
            and s['failures'].get('Archive') == 'Could not be read' and archives()['count'] == 0,
            failures=s['failures'], outcome=s['outcome'])
        app.call('first-run', action='continue'); app.call('first-run', action='finish')
        app.quit()
        app = launch(fresh=True, directory=partial)
        app.call('defaults', key='open.firstRun.completed', value=None)
        app.call('first-run', action='import')
        app.call('first-run', action='select', spaces=False, archive=True, history=False)
        app.call('first-run', action='continue'); s = until('report')
        text = copy(); shot('report-all-failed')
        row('all_failed_unsaved', not s['completed'] and not snapshot_path().exists()
            and not app.call('shell-windows') and s['failures'].get('Archive') == 'Could not be read'
            and 'Try Again' in text and 'Next' in text, text=text)
        app.call('first-run', action='retry')
        row('all_failed_retry', state()['step'] == 'importChoices' and not snapshot_path().exists())
        app.call('first-run', action='continue'); until('report')
        app.call('first-run', action='continue'); app.call('first-run', action='finish')
        row('all_failed_continue', state()['completed'] and not state()['active']
            and len(app.call('spaces')) == 1 and user_tabs() == [])
        app.quit()
        runpy.run_path(str(Path(h.ROOT)/"tools/e2e/firstrun_history.py"))["run"](launch, state, until, row, source, tmp, h)
        runpy.run_path(str(Path(h.ROOT)/"tools/e2e/firstrun_extensions.py"))["run"](launch, state, until, row, source, tmp, h, results)
        runpy.run_path(str(Path(h.ROOT)/'tools/e2e/firstrun_multiprofile.py'))['run'](factory, results, tmp, h)
        timings = []
        for _ in range(5):
            app = launch(fresh=True)
            t = app.call('timing'); timings.append(dict(marks=t, load=os.getloadavg()))
            app.quit()
        med = statistics.median(t['marks'].get('sidebarDrawn', float('inf')) for t in timings)
        row('F12_first_content', all(t['marks'].get('kernelProcessStart') and 'sidebarDrawn' in t['marks'] for t in timings),
            medianMs=med, budgetMs=250, qualification='Debug/loaded measurements are upper bounds, not idle Release acceptance', samples=timings)
        binary_strings = subprocess.check_output(['strings', app.executable], text=True, errors='replace')
        import re
        forbidden = [text for text in all_copy if re.search(r'\b(?:sign in|account|Little Arc)\b', text, re.I)]
        row('F13_copy', not forbidden and 'Arc' not in welcome_copy.replace('Import from Arc', '')
            and 'What should we call you?' in binary_strings, checkedScreens=len(all_copy), ocrRetries=sum(ocr_retries))
    finally:
        if app is not None:
            h._restore_defaults(app, saved)
            app.quit()
