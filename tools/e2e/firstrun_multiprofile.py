"""Two-Profile import through first run and Settings, with real Profile stores.

OPEN_E2E_IMPORT_NEGATIVE=1 deliberately misroutes each fixture area and adds
an intervening real command before Undo. The unchanged checks must fail.
"""
import importlib.util
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
               {'littleArc': {'_0': {'profile': {'_0': ref}}}}]
    for index, target in enumerate(targets):
        rules.append({'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/multi-route/'+str(index))),
            'sourceComponents': [{'componentType': {'urlMatch': {'_0': {'contains': {}}, '_1': 'route'+str(index)+'.example.com'}}}],
            'destination': {'space': {'_0': {'mostRecent': {}}}} if negative else target})
    (root/'StorableLinkRouting.json').write_text(json.dumps({'rules': rules,
        'defaultDestination': {'littleArc': {'_0': {'mostRecent': {}}}}}))
    return ids


def run(factory, results, tmp, h):
    source = Path(tmp)/'arc-multiprofile'; negative = os.environ.get('OPEN_E2E_IMPORT_NEGATIVE') == '1'
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
        return dict(archive=count('archive.sqlite3','archived_tabs'), history=count('history.sqlite3','history_import_keys'))
    try:
        for mode in ('firstRun', 'settings'):
            app = factory(urls=(), fresh=True, extra_args=['--arc-dir='+str(source)])
            if not saved:
                for key in ('open.firstRun.completed','open.import.lastArcDir','open.settings.lastPane','open.advanced.tabSleepMode'):
                    saved[key] = app.call('defaults', key=key, persistent=True)
            for key in saved: app.call('defaults', key=key, value=None)
            # An unrelated on-disk Arc-shaped directory is never an import target.
            occupied = Path(app.user_data)/'Profiles/Profile 1'; occupied.mkdir(parents=True, exist_ok=True)
            marker = occupied/'unrelated-data'; marker.write_text('synthetic unrelated Profile data')
            existing = None
            if mode == 'firstRun':
                app.call('first-run', action='import'); app.call('first-run', action='select', history=True)
                app.call('first-run', action='continue'); wait_for('step','report')
                first = state()['outcome']
                app.call('first-run', action='continue'); app.call('first-run', action='finish')
            else:
                app.call('first-run', action='fresh')
                app.call('profiles-shell', action='create', name='Example Work')
                before = snapshot(); existing = next(p for p in before['profiles'] if p['name'] == 'Example Work')
                first = settings_import()
            data = snapshot()
            profiles = data['profiles']; by_id = {p['id']:p for p in profiles}; spaces = {s['id']:s for s in data['spaces']}
            alpha, beta = spaces[ids['alpha']], spaces[ids['beta']]
            personal, work = by_id[alpha['profileID']], by_id[beta['profileID']]
            expected_names = ('Example Personal','Example Work') if mode == 'firstRun' else ('Default','Example Work (2)')
            stores = [counts(personal), counts(work)]
            destinations = [rule['destination'] for rule in data['routingRules']]
            checks = dict(
                profiles=len(profiles) == (2 if mode == 'firstRun' else 3)
                    and (personal['name'],work['name']) == expected_names
                    and (existing is None or existing['id'] != work['id']),
                spaceProfiles=alpha['profileID'] != beta['profileID'],
                favorites={f['tab']['_0']['id'] for f in personal['favorites']} == {ids['favorite']}
                    and {f['tab']['_0']['id'] for f in work['favorites']} == {ids['work-favorite']},
                archive=stores[0]['archive'] == stores[1]['archive'] == 1,
                history=stores[0]['history'] == 3 and stores[1]['history'] == 2,
                routing={'space': {'_0': beta['id']}} in destinations
                    and {'mostRecentSpace': {'profile': work['id']}} in destinations
                    and {'littleOpen': {'profile': work['id']}} in destinations,
                collision=work['dataDirectoryName'].startswith('Profile-') and marker.read_text() == 'synthetic unrelated Profile data',
            )
            if negative:
                app.quit()
                path = Path(app.user_data)/'State/browser.json'
                broken = json.loads(path.read_text()); broken['spaces'][0]['profileID'] = str(uuid.uuid4()).upper(); path.write_text(json.dumps(broken))
                app = factory(urls=(), extra_args=['--arc-dir='+str(source)])
                app.call('profiles-shell', action='notice-ok')
            repairs = app.call('profiles-shell')['noticeShown']
            checks['noRepairs'] = repairs == 0 and all(s['profileID'] in by_id for s in data['spaces'])
            if negative:
                expanded = json.loads((source/'StorableSidebar.json').read_text()); graph = expanded['sidebar']['containers'][1]
                new = str(uuid.uuid4()).upper()
                graph['items'] += [new, {'id': new, 'data': {'tab': {'savedURL': 'https://example.com/negative-new','savedTitle':'Example Negative'}}, 'childrenIds': []}]
                graph['items'][graph['items'].index(ids['ta'])+1]['childrenIds'].append(new)
                (source/'StorableSidebar.json').write_text(json.dumps(expanded))
            repeat = settings_import(); repeated = snapshot()
            checks['reimport'] = all(repeat.get(k,0) == 0 for k in ('Imported Spaces','Imported tabs','Imported Archive','History')) and all(repeated[k] == data[k] for k in ('profiles','spaces','routingRules'))
            # A fresh Settings import is one model Undo. Disk/context destruction
            # is Section 10's separate restart/confirmation boundary on main.
            if mode == 'settings':
                if negative: app.call('profiles-shell', action='create', name='Example Intervening Command')
                app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
                app.call('sidebar-key', key='z', modifiers=['command'])
                undone = snapshot()
                checks['undoModel'] = undone['profiles'] == before['profiles'] and undone['spaces'] == before['spaces'] and undone['routingRules'] == before['routingRules']
            details[mode] = dict(checks=checks, profileCount=len(profiles), stores=stores, repairs=repairs, first=first, repeat=repeat, load=os.getloadavg())
            app.quit(); app = None
        for name in ('profiles','spaceProfiles','favorites','archive','history','routing','collision','noRepairs','reimport','undoModel'):
            results['MP_'+name] = dict(ok=all(d['checks'].get(name,True) for d in details.values()), modes=details, negative=negative, load=os.getloadavg())
    finally:
        h._restore_defaults(app, saved)
        if app is not None: app.quit()
