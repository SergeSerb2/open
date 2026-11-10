"""Import robustness through the real first-run and Settings interfaces.

All source stores are synthetic, including the WAL held by our writer.
OPEN_E2E_IMPORT_ROBUST_NEGATIVE=1 breaks each condition with real input or
App actions; the original assertions must FAIL. ONLY=timing runs the large
fixture alone, for a baseline or a quiet timing rerun.
"""
import json
import os
from pathlib import Path
import runpy
import shutil
import sqlite3
import subprocess
import time
import uuid


def fixture(root, h, large=False):
    root = Path(root)
    ids = runpy.run_path(str(Path(h.ROOT)/'tools/e2e/firstrun_multiprofile.py'))['fixture'](root, h)
    graph_file = root/'StorableSidebar.json'
    data = json.loads(graph_file.read_text())
    graph = data['sidebar']['containers'][1]
    def identity(name):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/robust/'+name)).upper()
    def item(name, kind, children=()):
        key = identity(name)
        graph['items'] += [key, dict(id=key, data=kind, childrenIds=list(children))]
        return key
    panes = [item('pane'+str(i), {'tab': {'savedURL': 'https://example.com/pane'+str(i),
                                       'savedTitle': 'Example pane'}}) for i in range(2)]
    split = item('split', {'splitView': {'layoutOrientation': 'horizontal'}}, panes)
    graph['items'][graph['items'].index(ids['pa'])+1]['childrenIds'].append(split)
    if large:
        graph['spaces'] = []
        ref = {'custom': {'_0': {'directoryBasename': 'Profile 1', 'machineID': 'synthetic'}}}
        # Keep the original items reachable in the first Space as well.
        for space_index in range(6):
            tabs = [item('large-tab-%d-%d' % (space_index, i), {'tab': {
                'savedURL': 'https://example.com/large/%d/%d' % (space_index, i),
                'savedTitle': 'Example large tab'}}) for i in range(200)]
            if space_index == 0: tabs += [ids['pa'], ids['ta'], ids['pb'], ids['tb']]
            pinned = item('large-pinned-'+str(space_index), {'itemContainer': {}}, tabs)
            today = item('large-today-'+str(space_index), {'itemContainer': {}})
            sid = ids['alpha'] if space_index == 0 else ids['beta'] if space_index == 1 else identity('space-'+str(space_index))
            graph['spaces'] += [sid, dict(id=sid, title='Example Space '+str(space_index),
                profile={'default': True} if space_index % 2 == 0 else ref,
                containerIDs=['pinned', pinned, 'unpinned', today])]
        # Make the old source tab containers reachable without nesting containers.
        first_container = graph['items'][graph['items'].index(identity('large-pinned-0'))+1]
        first_container['childrenIds'] = first_container['childrenIds'][:200] + [ids['p0'], ids['folder'], ids['p2'], ids['t0'], ids['t1'], ids['welcome'], ids['easel'], split]
        archive = []
        for i in range(2000):
            key = identity('archive-'+str(i))
            archive += [key, dict(sidebarItem=dict(id=key, data={'tab': {
                'savedURL': 'https://example.com/archive/'+str(i), 'savedTitle': 'Example archive'}}),
                reason='manual', archivedAt=time.time()-978307200,
                source={'space': {'_0': ids['alpha'] if i % 2 == 0 else ids['beta']}})]
        (root/'StorableArchiveItems.json').write_text(json.dumps({'items': archive}))
        for directory in ('Default', 'Profile 1'):
            history = root/'User Data'/directory/'History'
            with sqlite3.connect(history) as db:
                db.executescript('DELETE FROM visits; DELETE FROM urls;')
                db.executemany('INSERT INTO urls VALUES(?,?,?,0)', [(i+1,
                    'https://example.com/history/'+directory.replace(' ', '-')+'/'+str(i),
                    'Example history '+str(i)) for i in range(2500)])
                db.executemany('INSERT INTO visits VALUES(?,?,?,?,?)', [(i+1, i % 2500+1,
                    13437000000000000+i*1000000, 1 if i % 5 == 0 else 0, 1 if i % 5 == 0 else 0) for i in range(50000)])
    graph_file.write_text(json.dumps(data))
    return ids


def inventory(app):
    """Counts only, including stores orphaned by a model-level Profile Undo."""
    data = json.loads(Path(app.call('save')).read_text())
    counts = dict(spaces=len(data['spaces']), profiles=len(data['profiles']), routing=len(data['routingRules']),
                  tabs=0, favorites=0, folders=0, splits=0, archive=0, history=0, historyKeys=0)
    def walk(value, favorite=False):
        if isinstance(value, dict):
            for kind, obj in value.items():
                if kind == 'tab' and isinstance(obj, dict) and '_0' in obj:
                    counts['favorites' if favorite else 'tabs'] += 1
                if kind == 'folder' and isinstance(obj, dict) and '_0' in obj: counts['folders'] += 1
                if kind == 'split' and isinstance(obj, dict) and '_0' in obj:
                    counts['splits'] += 1
                    # Split panes are Tab DTOs, not SidebarNode enum cases.
                    counts['tabs'] += len(obj['_0'].get('panes', []))
                walk(obj, favorite)
        elif isinstance(value, list):
            for child in value: walk(child, favorite)
    for profile in data['profiles']: walk(profile.get('favorites', []), True)
    for space in data['spaces']:
        walk(space.get('pinned', [])); walk(space.get('today', []))
    for file in (Path(app.user_data)/'Profiles').glob('*/State/*.sqlite3'):
        if file.name not in ('archive.sqlite3', 'history.sqlite3'): continue
        with sqlite3.connect('file:'+str(file)+'?mode=ro', uri=True) as db:
            tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            for table, key in [('archived_tabs', 'archive'), ('visits', 'history'), ('history_import_keys', 'historyKeys')]:
                if table in tables: counts[key] += db.execute('SELECT count(*) FROM '+table).fetchone()[0]
    return counts


def run(factory, results, tmp, h):
    root = Path(tmp)/'import-robust'
    root.mkdir(exist_ok=True)
    evidence = Path(h.OUT)/'import-robust'
    evidence.mkdir(exist_ok=True)
    negative = os.environ.get('OPEN_E2E_IMPORT_ROBUST_NEGATIVE') == '1'
    only = os.environ.get('OPEN_E2E_IMPORT_ROBUST_ONLY', '')
    saved, app = {}, None
    owned_writer = None
    def row(name, ok, **detail):
        results[name] = dict(ok=bool(ok), negative=negative, load=os.getloadavg(), **detail)
    def launch(source, **env):
        nonlocal app
        if os.environ.get('OPEN_E2E_APP_BUNDLE'):
            env['OPEN_E2E_APP_BUNDLE'] = os.environ['OPEN_E2E_APP_BUNDLE']
        app = factory(urls=(), fresh=True, extra_args=['--arc-dir='+str(source),
            '--host-resolver-rules=MAP * ~NOTFOUND'], extra_env=env)
        if not saved:
            for key in ('open.firstRun.completed', 'open.import.lastArcDir', 'open.settings.lastPane', 'open.advanced.tabSleepMode'):
                saved[key] = app.call('defaults', key=key, persistent=True)
        for key in saved: app.call('defaults', key=key, value=None)
        app.call('first-run', action='focus')
        return app
    def state(): return app.call('first-run')
    def wait(key, value):
        assert h.wait_until(lambda: state().get(key) == value, timeout=120, step=.02), state()
        return state()
    def settings_import(source, finish=True):
        app.call('first-run', action='settings-import', directory=str(source))
        if os.environ.get('OPEN_E2E_IMPORT_ROBUST_EARLY_FAILURE') == '1':
            raise RuntimeError('deliberate failure with the real import sheet open')
        app.call('first-run', action='settings-select', history=True)
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        result = wait('settingsStep', 'Report')
        if finish: app.call('first-run', action='settings-done')
        return result
    def first_import(history=True):
        app.call('first-run', action='import')
        app.call('first-run', action='select', history=history)
        app.call('first-run', action='continue')
        assert h.wait_until(lambda: state().get('step') in ('report', 'failed'), timeout=120, step=.02)
        return state()
    def finish_first():
        app.call('first-run', action='continue'); app.call('first-run', action='finish')
    def undo():
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        if negative:
            app.call('profiles-shell', action='create', name='Example intervening command')
        app.call('sidebar-key', key='z', modifiers=['command'])
        assert h.wait_until(lambda: not state().get('importUndoInProgress', False), timeout=30, step=.02)
        return inventory(app)
    def expand(source):
        data = json.loads((source/'StorableSidebar.json').read_text()); graph = data['sidebar']['containers'][1]
        key = str(uuid.uuid4()).upper()
        graph['items'] += [key, dict(id=key, childrenIds=[], data={'tab': {
            'savedURL': 'https://example.com/new', 'savedTitle': 'Example new'}})]
        graph['items'][graph['items'].index(graph['spaces'][1]['containerIDs'][1])+1]['childrenIds'].append(key)
        (source/'StorableSidebar.json').write_text(json.dumps(data))
        archive = json.loads((source/'StorableArchiveItems.json').read_text())
        new = dict(archive['items'][1]); new['sidebarItem'] = dict(new['sidebarItem'], id=str(uuid.uuid4()).upper())
        archive['items'] += [new['sidebarItem']['id'], new]
        (source/'StorableArchiveItems.json').write_text(json.dumps(archive))
        with sqlite3.connect(source/'User Data/Default/History') as db:
            db.execute('INSERT INTO visits SELECT coalesce(max(id),0)+1,1,13437000040000000,0,0 FROM visits')
    def file_state():
        return {str(f.relative_to(app.user_data)): (f.stat().st_size, f.stat().st_mtime_ns)
                for f in Path(app.user_data).rglob('*') if f.is_file() and
                (f.name == 'browser.json' or f.name.startswith(('history.sqlite3', 'archive.sqlite3')))}
    def cpu_seconds():
        value = subprocess.check_output(['ps', '-p', str(app.pid), '-o', 'time='], text=True).strip()
        parts = value.split(':')
        return sum(float(v) * 60**i for i, v in enumerate(reversed(parts)))
    try:
        source = root/'healthy'; fixture(source, h)
        if only != 'timing':
            # Fully synthetic Storable identities. A Little Browser can precede
            # the global pair in real Arc files; its own tab must stay out of
            # both the review counts and the imported sidebar.
            little_space = str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/little-space')).upper()
            little_tab = str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/little-tab')).upper()
            little_container = str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/little-container')).upper()
            little = dict(items=[little_container, dict(id=little_container,
                data={'itemContainer': {}}, childrenIds=[little_tab]), little_tab,
                dict(id=little_tab, data={'tab': {'savedURL': 'https://example.com/little-only',
                    'savedTitle': 'Synthetic Little-only tab'}}, childrenIds=[])],
                spaces=[little_space, dict(id=little_space, title='Synthetic Little-only Space',
                    profile={'default': True}, containerIDs=['pinned', little_container])])
            for little_first in (True, False):
                directory = root/('little-first' if little_first else 'global-first')
                shutil.copytree(source, directory)
                path = directory/'StorableSidebar.json'
                document = json.loads(path.read_text())
                global_pair = document['sidebar']['containers']
                little_pair = [{'littleBrowser': {'_0': little_space}}, little]
                document['sidebar']['containers'] = (little_pair + global_pair if little_first
                                                     else global_pair + little_pair)
                path.write_text(json.dumps(document))
                for entry in ('first-run', 'settings'):
                    launch(directory)
                    if entry == 'settings':
                        app.call('first-run', action='fresh')
                        outcome = settings_import(directory)
                        counts, review = outcome.get('settingsOutcome', {}), outcome.get('settingsCounts', {})
                    else:
                        outcome = first_import()
                        counts, review = outcome.get('outcome', {}), outcome.get('counts', {})
                        finish_first()
                    stored = json.loads(Path(app.call('save')).read_text())
                    stored_spaces = {space['id'].upper() for space in stored['spaces']}
                    row('container_identity_%s_%s' % ('little_first' if little_first else 'global_first', entry),
                        review.get('Spaces') == 2 and counts.get('Imported Spaces') == 2
                        and little_space not in stored_spaces
                        and 'little-only' not in json.dumps(stored)
                        and {'Alpha', 'Beta'} <= {space['title'] for space in stored['spaces']},
                        reviewSpaces=review.get('Spaces'), importedSpaces=counts.get('Imported Spaces'),
                        littleSpaceImported=little_space in stored_spaces)
                    app.quit(); app = None
            for case in ('global_missing', 'global_duplicate'):
                directory = root/case
                shutil.copytree(source, directory)
                path = directory/'StorableSidebar.json'
                document = json.loads(path.read_text())
                pairs = document['sidebar']['containers']
                document['sidebar']['containers'] = ([{'littleBrowser': {'_0': little_space}}, little]
                    if case == 'global_missing' else pairs + pairs)
                path.write_text(json.dumps(document))
                launch(directory)
                before = app.call('spaces')
                outcome = first_import()
                row('container_identity_' + case,
                    outcome.get('failures', {}).get('Spaces') == 'Could not be read'
                    and app.call('spaces') == before
                    and not (Path(app.user_data)/'State/browser.json').exists(),
                    failures=outcome.get('failures'), saved=(Path(app.user_data)/'State/browser.json').exists())
                app.quit(); app = None
            if only == 'containers':
                return
        if only != 'timing':
            for mode in ('settings_twice', 'first_then_settings'):
                launch(source)
                if mode == 'settings_twice':
                    app.call('first-run', action='fresh'); empty = inventory(app)
                    first = settings_import(source)
                else:
                    first = first_import(); finish_first()
                before = inventory(app)
                if negative: expand(source)
                second = settings_import(source)
                after = inventory(app)
                counts = second['settingsOutcome']
                row('repeat_'+mode, before == after and all(counts.get(k, 0) == 0 for k in (
                    'Imported Spaces', 'Imported tabs', 'Favorites', 'Folders', 'Profiles', 'Routing rules', 'Imported Archive', 'History')),
                    before=before, after=after, imported=counts)
                if mode == 'settings_twice':
                    # A no-op repeat must not release the first import's
                    # native Undo target when the runner replaces its receipt.
                    restored = undo()
                    twice = undo()
                    app.call('sidebar-key', key='z', modifiers=['command', 'shift'])
                    assert h.wait_until(lambda: not state().get('importUndoInProgress', False), timeout=30, step=.02)
                    redone = inventory(app)
                    row('repeat_then_undo', restored == empty and twice == empty and redone == before,
                        before=empty, imported=before, afterFirstUndo=restored, afterSecondUndo=twice, redone=redone)
                app.quit(); app = None
                if negative:
                    shutil.rmtree(source); fixture(source, h)

            launch(source); app.call('first-run', action='fresh'); empty = inventory(app)
            settings_import(source); first = inventory(app)
            expanded_ordered = root/'expanded-ordered'; shutil.copytree(source, expanded_ordered); expand(expanded_ordered)
            settings_import(expanded_ordered); second = inventory(app)
            restored_first = undo(); restored_empty = undo()
            row('two_imports_undo_order', second['tabs'] == first['tabs']+1
                and second['archive'] == first['archive']+1 and second['historyKeys'] == first['historyKeys']+1
                and restored_first == first and restored_empty == empty,
                empty=empty, first=first, second=second, afterFirstUndo=restored_first, afterSecondUndo=restored_empty)
            app.quit(); app = None

            launch(source)
            before = dict(spaces=len(app.call('spaces')), profiles=1, routing=0, tabs=0,
                          favorites=0, folders=0, splits=0, archive=0, history=0, historyKeys=0)
            first_import(); finish_first(); imported = inventory(app)
            after = undo()
            row('undo_first_run', before == after and imported['archive'] == 2 and imported['historyKeys'] == 5,
                before=before, imported=imported, after=after)
            app.quit(); app = None

            launch(source); app.call('first-run', action='fresh')
            before = inventory(app)
            settings_import(source); imported = inventory(app)
            after = undo()
            row('undo_all_parts', before == after and imported['splits'] == 1 and imported['archive'] == 2
                and imported['historyKeys'] == 5 and not state().get('importUndoError'),
                before=before, imported=imported, after=after, error=state().get('importUndoError'))
            app.call('sidebar-key', key='z', modifiers=['command', 'shift'])
            assert h.wait_until(lambda: not state().get('importUndoInProgress', False), timeout=30, step=.02)
            redone = inventory(app)
            row('redo_all_parts', redone == imported, before=imported, after=redone)
            app.call('sidebar-key', key='z', modifiers=['command'])
            assert h.wait_until(lambda: not state().get('importUndoInProgress', False), timeout=30, step=.02)
            # Re-import after Undo must be able to add the exact same History keys.
            again = settings_import(source)
            row('undo_then_reimport', again['settingsOutcome'].get('History') == 5
                and inventory(app)['historyKeys'] == 5, outcome=again['settingsOutcome'])
            app.quit(); app = None

            launch(source, OPEN_AUTOMATION_IMPORT_UNDO_DELAY_MS='1000')
            app.call('first-run', action='fresh'); before = inventory(app)
            settings_import(source)
            app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
            if negative: app.call('profiles-shell', action='create', name='Example intervening quit command')
            app.call('sidebar-key', key='z', modifiers=['command'])
            pending = state().get('importUndoInProgress', False)
            app.quit(); cleanup = app.quit_report
            app = factory(urls=(), extra_args=['--arc-dir='+str(source), '--host-resolver-rules=MAP * ~NOTFOUND'],
                          extra_env={k: os.environ[k] for k in ('OPEN_E2E_APP_BUNDLE',) if k in os.environ})
            after = inventory(app)
            row('undo_quit_persists', pending and before == after and not cleanup.get('forced'),
                before=before, after=after, pending=pending, cleanup=cleanup)
            app.quit(); app = None

            launch(source, OPEN_AUTOMATION_HISTORY_DELAY_MS='1000')
            app.call('first-run', action='fresh'); before = inventory(app)
            app.call('first-run', action='settings-import', directory=str(source))
            app.call('first-run', action='settings-select', history=True)
            app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
            assert h.wait_until(lambda: state().get('historyInProgress'), timeout=30, step=.02)
            app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
            if negative: app.call('profiles-shell', action='create', name='Example intervening pending command')
            for modifiers in (['command'], ['command', 'shift'], ['command']):
                app.call('sidebar-key', key='z', modifiers=modifiers)
            wait('settingsStep', 'Report')
            assert h.wait_until(lambda: not state().get('importUndoInProgress', False), timeout=30, step=.02)
            after = inventory(app)
            row('undo_redo_pending_batch', before == after and not state().get('importUndoError'),
                before=before, after=after, error=state().get('importUndoError'))
            app.call('first-run', action='settings-done'); app.quit(); app = None

            launch(source); app.call('first-run', action='fresh'); settings_import(source)
            # Synthetic pre-existing ordinary visit, exactly equal to the next
            # imported visit's URL/time/transition. Full App import and native
            # Undo must retain it; deleting by URL/time would remove both.
            data = json.loads(Path(app.call('save')).read_text())
            default = next(p for p in data['profiles'] if p['dataDirectoryName'] == 'Default')
            destination = Path(app.user_data)/'Profiles'/default['dataDirectoryName']/'State/history.sqlite3'
            with sqlite3.connect(destination) as db:
                uid = db.execute("SELECT id FROM urls WHERE url='https://example.com/a'").fetchone()[0]
                seconds = (13437000040000000-11644473600000000)/1000000
                db.execute("INSERT INTO visits(url_id,time,transition) VALUES(?,?,'link')", (uid, seconds))
                db.execute('UPDATE urls SET visit_count=(SELECT count(*) FROM visits WHERE url_id=?), last_visit=? WHERE id=?', (uid, seconds, uid))
                db.execute("UPDATE urls SET title='Example original live title' WHERE id=?", (uid,))
            baseline = inventory(app)
            expanded = root/'expanded'; shutil.copytree(source, expanded); expand(expanded)
            settings_import(expanded); added = inventory(app)
            with sqlite3.connect(destination) as db:
                db.execute("UPDATE urls SET title='Example newer live title' WHERE url='https://example.org/b'")
            restored = undo()
            with sqlite3.connect('file:'+str(destination)+'?mode=ro', uri=True) as db:
                title_restored = db.execute("SELECT title FROM urls WHERE url='https://example.com/a'").fetchone()[0] == 'Example original live title'
                newer_retained = db.execute("SELECT title FROM urls WHERE url='https://example.org/b'").fetchone()[0] == 'Example newer live title'
            row('undo_keeps_existing', restored == baseline and added['historyKeys'] == baseline['historyKeys']+1
                and added['archive'] == baseline['archive']+1 and title_restored and newer_retained,
                before=baseline, added=added, after=restored, titleRestored=title_restored, newerTitleRetained=newer_retained)
            app.quit(); app = None

            cases = ('folder_missing', 'sidebar_missing', 'sidebar_truncated', 'sidebar_shape', 'folder_unreadable',
                     'history_missing', 'history_schema', 'archive_corrupt', 'profile_missing', 'history_wal_unreadable', 'wal_locked_snapshot')
            for case in cases:
                directory = root/case; shutil.copytree(source, directory)
                sidebar_bad = case in cases[:5]
                failure, value = ('Spaces' if sidebar_bad else 'Archive' if case == 'archive_corrupt' else 'History'), 'Could not be read'
                if not negative:
                    if case == 'folder_missing': shutil.rmtree(directory); value = 'Not found'
                    elif case == 'sidebar_missing': (directory/'StorableSidebar.json').unlink(); value = 'Not found'
                    elif case == 'sidebar_truncated': (directory/'StorableSidebar.json').write_text('{"sidebar":')
                    elif case == 'sidebar_shape': (directory/'StorableSidebar.json').write_text('{}')
                    elif case == 'folder_unreadable': directory.chmod(0)
                    elif case == 'history_missing': (directory/'User Data/Default/History').unlink(); value = 'Not found'
                    elif case == 'history_schema':
                        with sqlite3.connect(directory/'User Data/Default/History') as db: db.execute("UPDATE meta SET value='99'")
                    elif case == 'archive_corrupt': (directory/'StorableArchiveItems.json').write_text('{')
                    elif case == 'profile_missing': shutil.rmtree(directory/'User Data/Profile 1'); value = 'Not found'
                if case in ('history_wal_unreadable', 'wal_locked_snapshot'):
                    owned_writer = sqlite3.connect(directory/'User Data/Default/History')
                    owned_writer.execute('PRAGMA journal_mode=WAL'); owned_writer.execute('PRAGMA wal_autocheckpoint=0')
                    owned_writer.execute("UPDATE urls SET title='Example committed WAL'"); owned_writer.commit()
                    if negative and case == 'wal_locked_snapshot':
                        owned_writer.execute('INSERT INTO visits VALUES(100,1,13437000040000000,0,0)'); owned_writer.commit()
                    owned_writer.execute('BEGIN IMMEDIATE'); owned_writer.execute("UPDATE urls SET title='Example uncommitted'")
                    if case == 'history_wal_unreadable' and not negative: Path(str(directory/'User Data/Default/History')+'-wal').chmod(0)
                try:
                    launch(directory); before = app.call('spaces')
                    if case in ('folder_missing', 'sidebar_missing', 'folder_unreadable'):
                        # Setup skips Import when discovery finds no source
                        # (#267). Do not force the retired Import screen. The
                        # negative fixture keeps the source readable, so this
                        # route assertion must then fail.
                        app.call('first-run', action='import')
                        routed = state()
                        row(case, routed.get('screen') == 'favorites'
                            and routed.get('probeReady') and not routed.get('sidebarFound')
                            and app.call('spaces') == before
                            and not (Path(app.user_data)/'State/browser.json').exists(),
                            screen=routed.get('screen'), probeReady=routed.get('probeReady'),
                            sidebarFound=routed.get('sidebarFound'))
                        app.quit(); app = None
                        continue
                    outcome = first_import()
                    if case == 'wal_locked_snapshot':
                        row(case, outcome.get('step') == 'report' and not outcome.get('failures')
                            and outcome['outcome'].get('History') == 5,
                            failures=outcome.get('failures'), counts=outcome.get('outcome'))
                    else:
                        failed = outcome.get('failures', {}).get(failure) == value and outcome.get('reportValues', {}).get(failure) == value
                        clean = app.call('spaces') == before and not (Path(app.user_data)/'State/browser.json').exists() if sidebar_bad else outcome['outcome'].get('Imported Spaces') == 2
                        row(case, failed and clean, failures=outcome.get('failures'), counts=outcome.get('outcome'),
                            error=outcome.get('error'), reportValues=outcome.get('reportValues'))
                    app.quit(); app = None
                finally:
                    if directory.exists(): directory.chmod(0o700)
                    wal = Path(str(directory/'User Data/Default/History')+'-wal')
                    if wal.exists(): wal.chmod(0o600)
                    if owned_writer is not None: owned_writer.rollback(); owned_writer.close(); owned_writer = None

            partial = root/'partial'; shutil.copytree(source, partial)
            if not negative: (partial/'StorableArchiveItems.json').write_text('{')
            owned_writer = sqlite3.connect(partial/'User Data/Default/History')
            owned_writer.execute('PRAGMA journal_mode=WAL'); owned_writer.execute("UPDATE urls SET title='Example WAL'"); owned_writer.commit()
            owned_writer.execute('BEGIN IMMEDIATE'); owned_writer.execute("UPDATE urls SET title='Example pending'")
            wal = Path(str(partial/'User Data/Default/History')+'-wal')
            if not negative: wal.chmod(0)
            try:
                launch(partial); app.call('first-run', action='fresh'); before = inventory(app)
                outcome = settings_import(partial, finish=False)
                shot = str(evidence/'partial-report.png'); app.call('snapshot', path=shot)
                partial_counts = inventory(app)
                failures = outcome.get('settingsFailures', {})
                app.call('first-run', action='settings-done'); after = undo()
                row('partial_failure_and_undo', failures.get('Archive') == 'Could not be read'
                    and failures.get('History') == 'Could not be read' and partial_counts['tabs'] > 0
                    and partial_counts['historyKeys'] == 2 and before == after,
                    before=before, landed=partial_counts, after=after, failures=failures, png=shot)
                app.quit(); app = None
            finally:
                wal.chmod(0o600); owned_writer.rollback(); owned_writer.close(); owned_writer = None

        large = root/'large'; fixture(large, h, large=True)
        if negative: expand(large)
        env = dict(OPEN_AUTOMATION_IMPORT_STALL_MS='80', OPEN_AUTOMATION_HISTORY_DELAY_MS='90') if negative else {}
        launch(large, **env); app.call('first-run', action='fresh')
        started_load = os.getloadavg()
        outcome = settings_import(large)
        metrics = outcome.get('importMetrics', {})
        stored = inventory(app)
        row('large_fixture', stored['spaces'] == 7 and stored['archive'] == 2000 and stored['historyKeys'] == 100000,
            counts=stored, metrics=metrics)
        row('timing_history_100k', metrics.get('historyMilliseconds', float('inf')) <= 1400,
            timing=True, targetMilliseconds=1400, planLimitMilliseconds=3000, metrics=metrics, startLoad=started_load)
        row('timing_main_responsive', metrics.get('maxMainLagMilliseconds', float('inf')) < 50
            and metrics.get('watchdogSamples', 0) > 0, timing=True, limitMilliseconds=50, metrics=metrics, startLoad=started_load)
        # Ten seconds after completion: no timer, polling or repeated import writes.
        time.sleep(10)
        files_before, counters_before = file_state(), app.call('frame-save-counters')
        cpu_before, wall_before = cpu_seconds(), time.monotonic()
        if negative:
            for _ in range(3): app.call('save')
        time.sleep(5)
        cpu = (cpu_seconds()-cpu_before)/(time.monotonic()-wall_before)*100
        files_after, counters_after = file_state(), app.call('frame-save-counters')
        metrics_after = state().get('importMetrics', {})
        row('idle_after_import', files_before == files_after and counters_before == counters_after
            and metrics_after.get('watchdogActive') == 0 and cpu < 1,
            timing=True, appCPUPercent=cpu, countersBefore=counters_before, countersAfter=counters_after,
            changedStoreFiles=sum(files_before.get(k) != files_after.get(k) for k in files_before.keys() | files_after.keys()),
            metrics=metrics_after)
    finally:
        if owned_writer is not None: owned_writer.close()
        # Restore permissions even if a failure occurs during App launch.
        for directory in root.iterdir():
            if directory.is_dir(): directory.chmod(0o700)
        for wal in root.glob('*/User Data/*/History-wal'): wal.chmod(0o600)
        h._restore_defaults(app, saved)
        if app is not None: app.quit()
