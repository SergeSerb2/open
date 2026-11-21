"""Two-Profile import through first run and Settings, with real Profile stores.

OPEN_E2E_IMPORT_NEGATIVE=1 deliberately misroutes each fixture area and adds
an intervening real command before Undo. The unchanged checks must fail.
"""
import json
import os
from pathlib import Path
import runpy
import shutil
import sqlite3
import time
import uuid


def fixture(root, h, negative=False):
    ids = runpy.run_path(str(Path(h.ROOT)/'tools/e2e/firstrun.py'))['fixture'](root)
    ref = {'custom': {'_0': {'directoryBasename': 'Profile 1', 'machineID': str(uuid.uuid4())}}}
    data = json.loads((root/'StorableSidebar.json').read_text())
    graph = data['sidebar']['containers'][1]
    graph['spaces'][3]['profile'] = {'default': True} if negative else ref
    for name in ('work-favorite', 'work-top'):
        ids[name] = str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/multi-profile/'+name)).upper()
    graph['items'] += [ids['work-favorite'], {'id': ids['work-favorite'], 'childrenIds': [],
        'data': {'tab': {'savedURL': 'https://example.com/work-favorite', 'savedTitle': 'Example Work Favorite'}}},
        ids['work-top'], {'id': ids['work-top'], 'childrenIds': [ids['work-favorite']], 'data': {'itemContainer': {}}}]
    graph['topAppsContainerIDs'] += [{'default': True} if negative else ref, ids['work-top']]
    (root/'StorableSidebar.json').write_text(json.dumps(data))
    archive = json.loads((root/'StorableArchiveItems.json').read_text())
    archive['items'][3]['source'] = {'space': {'_0': ids['alpha'] if negative else ids['beta']}}
    (root/'StorableArchiveItems.json').write_text(json.dumps(archive))
    (root/'User Data/Local State').write_text(json.dumps({'profile': {'info_cache': {
        'Default': {'name': 'Example Personal'}, 'Profile 1': {'name': 'Wrong Profile' if negative else 'Example Work'}}}}))
    work = root/'User Data/Profile 1'; work.mkdir()
    shutil.copyfile(root/'User Data/Default/History', work/'History')
    with sqlite3.connect(work/'History') as db:
        db.execute('DELETE FROM visits')
        if not negative:
            db.executemany('INSERT INTO visits VALUES(?,?,?,1,1)', [(1,1,13437000000000000),(2,2,13437000010000000)])
    rules = []
    targets = [{'space': {'_0': {'space': {'_0': ids['beta']}}}},
               {'space': {'_0': {'profile': {'_0': ref}}}},
               {'littleArc': {'_0': {'profile': {'_0': ref}}}},
               {'space': {'_0': {'profile': {'_0': {'default': True}}}}},
               {'littleArc': {'_0': {'profile': {'_0': {'default': True}}}}}]
    for index, target in enumerate(targets):
        rules.append({'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/multi-route/'+str(index))),
            'sourceComponents': [{'componentType': {'urlMatch': {'_0': {'contains': {}}, '_1': 'route'+str(index)+'.example.com'}}}],
            'destination': {'space': {'_0': {'mostRecent': {}}}} if negative else target})
    (root/'StorableLinkRouting.json').write_text(json.dumps({'rules': rules,
        'defaultDestination': {'littleArc': {'_0': {'mostRecent': {}}}}}))
    (root/'StorableSessionRestorationData.json').write_text(json.dumps({'mapping': {'keysToValues': [] if negative else [
        {'browser': {'windowID': ids['window'], 'contextID': {'profile': {'default': True}}}, 'itemId': ids['t0']}, 1,
        {'browser': {'windowID': ids['window'], 'contextID': {'profile': ref}}, 'itemId': ids['work-favorite']}, 2]}}))
    return ids


def shapes_fixture(root, h):
    """Arc shapes found in corrupt or hand-made files (bug sweep round 2), on top of the two-Profile fixture:
    a Profile whose UUID a Space names in another letter case; routing rules naming a Profile by its
    directory or by the "Default" string; splits with one, zero and five panes, a skipped first child
    and negative width factors."""
    ids = fixture(root, h)
    data = json.loads((root/'StorableSidebar.json').read_text())
    graph = data['sidebar']['containers'][1]
    def key(name): return str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/shapes/' + name)).upper()
    case_id = key('case-profile')
    (root/'StorableProfiles.json').write_text(json.dumps({'profiles': [case_id, {
        'id': case_id, 'name': 'Example Case', 'directoryBasename': 'Profile 2'}]}))
    def tab(name):
        ids[name] = key(name)
        graph['items'] += [ids[name], {'id': ids[name], 'childrenIds': [], 'title': 'Example ' + name,
            'data': {'tab': {'savedURL': 'https://example.com/shapes/' + name, 'savedTitle': 'Example ' + name}}}]
        return ids[name]
    def split(name, children, **extra):
        ids[name] = key(name)
        graph['items'] += [ids[name], {'id': ids[name], 'childrenIds': children, 'data': {'splitView': dict(layoutOrientation='horizontal', **extra)}}]
        return ids[name]
    one = split('split-one', [tab('one-a')])
    empty = split('split-empty', [key('missing-0')])
    five = split('split-five', [tab('five-%d' % i) for i in range(5)])
    focus = split('split-focus', [key('missing-1'), tab('focus-a'), tab('focus-b')], focusItemID=key('focus-a'),
                  itemWidthFactors=[0.2, 0.3, 0.5])
    negative = split('split-negative', [tab('negative-a'), tab('negative-b')], itemWidthFactors=[-1, 2])
    # Bug sweep r3 L15: a split whose second child is a folder (its tab stays in the Space), and a
    # tab whose ID is another tab's ID in lowercase (two items, two Open IDs).
    ids['split-folder-dir'] = key('split-folder-dir')
    graph['items'] += [ids['split-folder-dir'], {'id': ids['split-folder-dir'], 'childrenIds': [tab('folder-inner')],
                                                'title': 'Example split folder', 'data': {'list': {}}}]
    with_folder = split('split-with-folder', [tab('with-folder-a'), ids['split-folder-dir']])
    twin_of = tab('case-twin-a')
    ids['case-twin-b'] = twin_of.lower()
    graph['items'] += [ids['case-twin-b'], {'id': ids['case-twin-b'], 'childrenIds': [], 'title': 'Example case-twin-b',
        'data': {'tab': {'savedURL': 'https://example.com/shapes/case-twin-b', 'savedTitle': 'Example case-twin-b'}}}]
    # Review round 1 (#643): five-pane splits outside a Space container (an orphan, and one in
    # Favorites), and a split whose fifth child is a five-pane split. Each pane is placed once.
    split('split-orphan', [tab('loose-%d' % i) for i in range(5)])
    favorite_split = split('split-favorite', [tab('fav-split-%d' % i) for i in range(5)])
    # Review round 2: a Favorites split whose only child is a folder (the split dissolves; the folder stays).
    ids['fav-folder'] = key('fav-folder')
    graph['items'] += [ids['fav-folder'], {'id': ids['fav-folder'], 'childrenIds': [tab('fav-folder-inner')],
                                          'title': 'Example favorites folder', 'data': {'list': {}}}]
    folder_split = split('split-fav-folder', [ids['fav-folder']])
    for index in range(0, len(graph['items']), 2):
        if graph['items'][index] == ids['top']: graph['items'][index + 1]['childrenIds'] += [favorite_split, folder_split]
    inner = split('split-inner', [tab('inner-%d' % i) for i in range(5)])
    outer = split('split-outer', [tab('outer-%d' % i) for i in range(4)] + [inner])
    pinned, today = key('gamma-pinned'), key('gamma-today')
    graph['items'] += [pinned, {'id': pinned, 'childrenIds': [tab('gamma-tab')], 'data': {'itemContainer': {}}},
                       today, {'id': today, 'childrenIds': [one, empty, five, focus, negative, with_folder, twin_of, ids['case-twin-b'], outer],
                               'data': {'itemContainer': {}}}]
    ids['gamma'] = key('gamma')
    graph['spaces'] += [ids['gamma'], {'id': ids['gamma'], 'title': 'Gamma', 'profile': case_id.lower(),
                                       'containerIDs': ['pinned', pinned, 'unpinned', today]}]
    (root/'StorableSidebar.json').write_text(json.dumps(data))
    routing = json.loads((root/'StorableLinkRouting.json').read_text())
    for host, target in (('route-directory.example.com', {'custom': {'_0': {'directoryBasename': 'Profile 2', 'machineID': 'synthetic'}}}),
                         ('route-default-string.example.com', 'Default')):
        routing['rules'].append({'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/shapes-route/' + host)),
            'sourceComponents': [{'componentType': {'urlMatch': {'_0': {'contains': {}}, '_1': host}}}],
            'destination': {'space': {'_0': {'profile': {'_0': target}}}}})
    (root/'StorableLinkRouting.json').write_text(json.dumps(routing))
    ids['case'] = case_id
    return ids


def no_space_fixture(root, h):
    """A sidebar with no Space and one unreached tab: the orphan needs the fallback Space."""
    runpy.run_path(str(Path(h.ROOT)/'tools/e2e/firstrun.py'))['fixture'](root)
    orphan = str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/shapes/orphan')).upper()
    (root/'StorableSidebar.json').write_text(json.dumps({'sidebar': {'containers': [{'global': {}}, {'spaces': [], 'items': [
        orphan, {'id': orphan, 'childrenIds': [], 'data': {'tab': {'savedURL': 'https://example.com/shapes/orphan', 'savedTitle': 'Example orphan'}}}]}]}}))
    for name in ('StorableArchiveItems.json', 'StorableLinkRouting.json', 'StorableSessionRestorationData.json'):
        if (root/name).exists(): (root/name).unlink()


def shapes_rows(factory, results, tmp, h):
    source, lonely = Path(tmp)/'arc-shapes', Path(tmp)/'arc-no-space'
    for folder in (source, lonely): shutil.rmtree(folder, ignore_errors=True)
    ids = shapes_fixture(source, h); no_space_fixture(lonely, h)
    helper = runpy.run_path(str(Path(h.ROOT)/'tools/e2e/firstrun.py'))
    app, saved = None, {}
    try:
        app, report, saved = helper['first_run_arc_import'](factory, source, h.wait_until, history=False)
        data = json.loads(Path(app.call('save')).read_text())
        by_id = {p['id']: p for p in data['profiles']}
        gamma = next((sp for sp in data['spaces'] if sp['id'] == ids['gamma']), None)
        owner = by_id.get(gamma['profileID']) if gamma else None
        results['MP_shapes_profile_case'] = dict(ok=report.get('step') == 'report' and bool(owner) and owner['name'] == 'Example Case'
            and len(data['profiles']) == 3 and sum(1 for p in data['profiles'] if p['name'] == 'Example Case') == 1,
            step=report.get('step'), error=report.get('error'), profiles=[p['name'] for p in data['profiles']])
        def rule(host): return next((r['destination'] for r in data.get('routingRules', []) if host in json.dumps(r)), None)
        personal = next((p for p in data['profiles'] if p['dataDirectoryName'] == 'Default'), {})
        results['MP_shapes_routing_refs'] = dict(ok=bool(owner) and rule('route-directory.example.com') == {'mostRecentSpace': {'profile': owner['id']}}
            and rule('route-default-string.example.com') == {'mostRecentSpace': {'profile': personal.get('id')}},
            directory=rule('route-directory.example.com'), defaultString=rule('route-default-string.example.com'),
            case=owner and owner['id'], personal=personal.get('id'))
        today = (gamma or {}).get('today', [])
        splits = {sp['split']['_0']['id']: sp['split']['_0'] for sp in today if 'split' in sp}
        tabs = [n['tab']['_0']['id'] for n in today if 'tab' in n]
        five = splits.get(ids['split-five'], {})
        five_url = 'https://example.com/shapes/five-4'  # the fifth pane: a Today tab of the split's own Space (Gamma)
        everywhere = json.dumps(data)
        focus = splits.get(ids['split-focus'], {})
        negative = splits.get(ids['split-negative'], {})
        def pane_ids(split): return [p['id'] for p in split.get('panes', [])]
        results['MP_shapes_split_normalized'] = dict(ok=ids['split-one'] not in splits and ids['one-a'] in tabs and ids['split-empty'] not in splits
            and ids['split-empty'] not in everywhere and pane_ids(five) == [ids['five-%d' % i] for i in range(4)]
            and json.dumps(gamma).count(five_url) == 1 and everywhere.count(five_url) == 1 and ids['five-4'] in tabs
            and pane_ids(focus) == [ids['focus-a'], ids['focus-b']] and focus.get('focusedPaneID') == ids['focus-a']
            and [round(f, 3) for f in focus.get('fractions', [])] == [0.375, 0.625]
            and pane_ids(negative) == [ids['negative-a'], ids['negative-b']] and negative.get('fractions', []) == [],
            today=[list(n)[0] for n in today], five=pane_ids(five), fifthInGamma=json.dumps(gamma).count(five_url), fifthAnywhere=everywhere.count(five_url),
            focus={k: focus.get(k) for k in ('focusedPaneID', 'fractions')}, negative=negative.get('fractions'))
        # Bug sweep r3 L15. Before: the folder (and its tab) was dropped, and both case twins had one ID.
        node_ids = []
        def walk(value):
            if isinstance(value, dict):
                if 'id' in value and ('url' in value or 'children' in value or 'panes' in value): node_ids.append(value['id'])
                for child in value.values(): walk(child)
            elif isinstance(value, list):
                for child in value: walk(child)
        walk(data['spaces']); walk([p.get('favorites') for p in data['profiles']])
        duplicates = sorted({i for i in node_ids if node_ids.count(i) > 1})
        gamma_text = json.dumps(gamma)
        # Review round 1: every pane of the orphan, Favorites and nested five-pane splits appears exactly
        # once; the nested split's overflow stays in Gamma (its outer split's Space).
        whole = json.dumps(data)
        loose = ['loose-%d' % i for i in range(5)] + ['fav-split-%d' % i for i in range(5)] + ['inner-%d' % i for i in range(5)] + ['outer-%d' % i for i in range(4)] + ['fav-folder-inner']
        counts = {name: whole.count('"https://example.com/shapes/%s"' % name) for name in loose}
        inner_in_gamma = all('"https://example.com/shapes/inner-%d"' % i in gamma_text for i in range(5))
        results['MP_shapes_overflow_placed_once'] = dict(ok=not duplicates and all(c == 1 for c in counts.values()) and inner_in_gamma,
            duplicateIDs=duplicates, counts={k: v for k, v in counts.items() if v != 1}, innerInGamma=inner_in_gamma)
        results['MP_shapes_split_folder_child_and_case_twins'] = dict(ok=not duplicates
            and 'https://example.com/shapes/folder-inner' in gamma_text and 'Example split folder' in gamma_text
            and 'https://example.com/shapes/case-twin-a' in gamma_text and 'https://example.com/shapes/case-twin-b' in gamma_text,
            duplicateIDs=duplicates, folderChild='https://example.com/shapes/folder-inner' in gamma_text,
            twins=[u for u in ('case-twin-a', 'case-twin-b') if 'https://example.com/shapes/' + u in gamma_text])
        # A Settings import of a sidebar without Spaces keeps its unreached tab in a new Space.
        app.call('first-run', action='settings-import', directory=str(lonely))
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        h.wait_until(lambda: app.call('first-run').get('settingsStep') == 'Report', timeout=45, step=.05)
        lonely_report = app.call('first-run')
        app.call('first-run', action='settings-done')
        after = json.loads(Path(app.call('save')).read_text())
        holder = [sp.get('title') for sp in after['spaces'] if 'https://example.com/shapes/orphan' in json.dumps(sp)]
        results['MP_shapes_orphan_without_space'] = dict(ok=len(holder) == 1, spaces=holder,
            outcome=lonely_report.get('settingsOutcome'), failures=lonely_report.get('settingsFailures'))
    finally:
        if app is not None:
            h._restore_defaults(app, saved)
            app.quit()


def run(factory, results, tmp, h):
    source = Path(tmp)/'arc-multiprofile'
    shutil.rmtree(source, ignore_errors=True)
    negative = os.environ.get('OPEN_E2E_IMPORT_NEGATIVE') == '1'
    ids = fixture(source, h, negative)
    saved, details = {}, {}
    app = None
    def state(): return app.call('first-run')
    def snapshot(): return json.loads(Path(app.call('save')).read_text())
    def wait_for(key, value):
        assert h.wait_until(lambda: state().get(key) == value, timeout=45, step=.05), 'import did not reach '+value
    def settings_import(directory=source):
        app.call('first-run', action='settings-import', directory=str(directory))
        app.call('first-run', action='settings-select', history=True)
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        wait_for('settingsStep', 'Report')
        outcome = state()['settingsOutcome']
        app.call('first-run', action='settings-done')
        return outcome
    def counts(profile):
        store = Path(app.user_data)/'Profiles'/profile['dataDirectoryName']/'State'
        def count(name, table):
            file = store/name
            if not file.exists(): return 0
            with sqlite3.connect('file:'+str(file)+'?mode=ro', uri=True) as db:
                return db.execute('SELECT count(*) FROM '+table).fetchone()[0]
        archive_rows = []
        if (store/'archive.sqlite3').exists():
            with sqlite3.connect('file:'+str(store/'archive.sqlite3')+'?mode=ro', uri=True) as db:
                archive_rows = db.execute('SELECT id, space_id, profile_id FROM archived_tabs').fetchall()
        return dict(archive=count('archive.sqlite3','archived_tabs'), archiveRows=archive_rows,
                    history=count('history.sqlite3','history_import_keys'))
    try:
        local_state = (source/'User Data/Local State').read_bytes()
        for mode in ('firstRun', 'sourceDirectories', 'settings'):
            if mode == 'sourceDirectories': (source/'User Data/Local State').unlink()
            else: (source/'User Data/Local State').write_bytes(local_state)
            app = factory(urls=(), fresh=True, extra_args=['--arc-dir='+str(source)])
            if not saved:
                for key in ('open.firstRun.completed','open.import.lastArcDir','open.settings.lastPane','open.advanced.tabSleepMode'):
                    saved[key] = app.call('defaults', key=key, persistent=True)
            for key in saved: app.call('defaults', key=key, value=None)
            # An unrelated on-disk Arc-shaped directory is never an import target.
            occupied = Path(app.user_data)/'Profiles/Profile 1'; occupied.mkdir(parents=True, exist_ok=True)
            marker = occupied/'unrelated-data'; marker.write_text('synthetic unrelated Profile data')
            existing = live_default = None
            imported_selections = None
            undo_completion = None
            if mode != 'settings':
                app.call('first-run', action='import')
                if os.environ.get('OPEN_E2E_IMPORT_EARLY_FAILURE') == '1':
                    raise RuntimeError('deliberate import-dialog cleanup proof')
                app.call('first-run', action='select', history=True)
                app.call('first-run', action='continue'); wait_for('step','report')
                first = state()['outcome']
                # The importer checkpoint precedes Welcome's intentional
                # selection at the final setup hand-off.
                checkpoint = json.loads((Path(app.user_data)/'State/browser.json').read_text())
                imported_selections = checkpoint['windows'][0]['selectedNodeBySpace']
                app.call('first-run', action='continue'); app.call('first-run', action='finish')
            else:
                app.call('first-run', action='fresh')
            assert h.wait_until(lambda: app.call('welcome')['visible'], timeout=10, step=.02), 'Welcome did not appear after setup'
            if mode == 'settings':
                app.call('profiles-shell', action='create', name='Example Work')
                before = snapshot(); existing = next(p for p in before['profiles'] if p['name'] == 'Example Work')
                live_default = next(p for p in before['profiles'] if p['dataDirectoryName'] == 'Default')
                first = settings_import()
            data = snapshot()
            profiles = data['profiles']; by_id = {p['id']:p for p in profiles}; spaces = {s['id']:s for s in data['spaces']}
            alpha, beta = spaces[ids['alpha']], spaces[ids['beta']]
            personal, work = by_id[alpha['profileID']], by_id[beta['profileID']]
            expected_names = ('Default','Profile') if mode == 'sourceDirectories' else ('Example Personal','Example Work') if mode == 'firstRun' else (live_default['name'],'Example Work (2)')
            stores = [counts(personal), counts(work)]
            destinations = [rule['destination'] for rule in data['routingRules']]
            checks = dict(
                profiles=len(profiles) == (3 if mode == 'settings' else 2)
                    and (personal['name'],work['name']) == expected_names
                    and (existing is None or existing['id'] != work['id']),
                spaceProfiles=alpha['profileID'] != beta['profileID'],
                favorites={f['tab']['_0']['id'] for f in personal['favorites']} == {ids['favorite']}
                    and {f['tab']['_0']['id'] for f in work['favorites']} == {ids['work-favorite']},
                archive=stores[0]['archiveRows'] == [(ids['archive0'], ids['alpha'], personal['id'])]
                    and stores[1]['archiveRows'] == [(ids['archive1'], ids['beta'], work['id'])],
                history=stores[0]['history'] == 3 and stores[1]['history'] == 2,
                routing={'space': {'_0': beta['id']}} in destinations
                    and {'mostRecentSpace': {'profile': work['id']}} in destinations
                    and {'littleOpen': {'profile': work['id']}} in destinations
                    and {'mostRecentSpace': {'profile': personal['id']}} in destinations
                    and {'littleOpen': {'profile': personal['id']}} in destinations,
                collision=work['dataDirectoryName'].startswith('Profile-') and marker.read_text() == 'synthetic unrelated Profile data',
            )
            if mode == 'settings':
                # The live Default has its own random ID and keeps its context.
                # Source Local State calls it Example Personal: names do not match.
                checks['defaultRole'] = personal['id'] == live_default['id'] and personal['dataDirectoryName'] == live_default['dataDirectoryName'] \
                    and len(profiles) == len(before['profiles']) + 1 \
                    and {p['id'] for p in profiles if p['name'].startswith('Default')} == {live_default['id']}
            if negative:
                app.quit()
                path = Path(app.user_data)/'State/browser.json'
                broken = json.loads(path.read_text()); broken['spaces'][0]['profileID'] = str(uuid.uuid4()).upper(); path.write_text(json.dumps(broken))
                app = factory(urls=(), extra_args=['--arc-dir='+str(source)])
                assert h.wait_until(lambda: app.call('profiles-shell')['noticeShown'] > 0, timeout=10, step=.05)
                app.call('profiles-shell', action='notice-ok')
            selections = data['windows'][0]['selectedNodeBySpace']
            welcome_selection = app.call('welcome') if mode != 'settings' else None
            app.call('space', space=ids['beta'])
            selected = {tab['id'] for tab in app.call('tabs') if tab['selected']}
            import_session = imported_selections if imported_selections is not None else selections
            checks['session'] = import_session.get(ids['alpha']) == ids['t0'] and import_session.get(ids['beta']) == ids['work-favorite'] and selected == {ids['work-favorite']}
            if welcome_selection is not None:
                checks['session'] &= welcome_selection['visible'] and selections.get(ids['alpha']) == welcome_selection['tab']
            session_detail = dict(checkpoint=import_session, final=selections, selected=sorted(selected),
                welcome=None if welcome_selection is None else {k: welcome_selection[k] for k in ('visible','tab')})
            repairs = app.call('profiles-shell')['noticeShown']
            checks['noRepairs'] = repairs == 0 and all(s['profileID'] in by_id for s in data['spaces'])
            if negative:
                expanded = json.loads((source/'StorableSidebar.json').read_text()); graph = expanded['sidebar']['containers'][1]
                new = str(uuid.uuid4()).upper()
                graph['items'] += [new, {'id': new, 'data': {'tab': {'savedURL': 'https://example.com/negative-new','savedTitle':'Example Negative'}}, 'childrenIds': []}]
                graph['items'][graph['items'].index(ids['ta'])+1]['childrenIds'].append(new)
                (source/'StorableSidebar.json').write_text(json.dumps(expanded))
            repeat = settings_import(); repeated = snapshot()
            checks['reimport'] = all(repeat.get(k,0) == 0 for k in ('Imported Spaces','Imported tabs','Imported Archive','History')) and {(p['id'],p['dataDirectoryName']) for p in repeated['profiles']} == {(p['id'],p['dataDirectoryName']) for p in data['profiles']} and {s['id'] for s in repeated['spaces']} == set(spaces) and len(repeated['routingRules']) == len(data['routingRules'])
            # A fresh Settings import is one model Undo. Disk/context destruction
            # is Section 10's separate restart/confirmation boundary on main.
            if mode == 'settings':
                if negative: app.call('profiles-shell', action='create', name='Example Intervening Command')
                app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
                app.call('sidebar-key', key='z', modifiers=['command'])
                pending = state()['importUndoInProgress']
                assert h.wait_until(lambda: not state()['importUndoInProgress'], timeout=30, step=.02), 'import Undo did not finish'
                undo_completion = dict(wasPending=pending, error=state()['importUndoError'])
                undone = snapshot()
                # Undo restores Welcome's selection, which updates that live
                # tab's activity time. Check that update separately; compare
                # every other persisted field exactly as before.
                expected = json.loads(json.dumps(before))
                def welcome_tabs(value):
                    if isinstance(value, dict):
                        if value.get('url') == 'open://welcome': yield value
                        for child in value.values(): yield from welcome_tabs(child)
                    elif isinstance(value, list):
                        for child in value: yield from welcome_tabs(child)
                actual_welcome = {tab['id']: tab for tab in welcome_tabs(undone['spaces'])}
                activity_ok = True
                for tab in welcome_tabs(expected['spaces']):
                    actual = actual_welcome.get(tab['id'])
                    activity_ok &= actual is not None and actual['lastActiveAt'] >= tab['lastActiveAt']
                    if actual is not None: tab['lastActiveAt'] = actual['lastActiveAt']
                undo_completion['welcomeActivityValid'] = activity_ok
                checks['undoModel'] = not undo_completion['error'] and activity_ok and undone['profiles'] == expected['profiles'] and undone['spaces'] == expected['spaces'] and undone['routingRules'] == expected['routingRules']
                if not checks['undoModel']:
                    evidence = Path(h.ROOT)/'.re/handoff/sections/s17/c3'
                    (evidence/'multiprofile-before-undo.json').write_text(json.dumps(before, indent=2))
                    (evidence/'multiprofile-after-undo.json').write_text(json.dumps(undone, indent=2))
            details[mode] = dict(checks=checks, profileCount=len(profiles), stores=stores, repairs=repairs, first=first, repeat=repeat, session=session_detail, undoCompletion=undo_completion, load=os.getloadavg())
            app.quit(); app = None
        for name in ('profiles','defaultRole','spaceProfiles','favorites','archive','history','routing','collision','session','noRepairs','reimport','undoModel'):
            results['MP_'+name] = dict(ok=all(d['checks'].get(name,True) for d in details.values()), modes=details, negative=negative, load=os.getloadavg())
        if not negative:
            shapes_rows(factory, results, tmp, h)
    finally:
        h._restore_defaults(app, saved)
        if app is not None: app.quit()
