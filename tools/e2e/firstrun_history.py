"""Background History through the real first-run and Settings actions and stores."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time


def run(launch, state, until, row, source, tmp, h):
    app = None
    writer = None
    def history_rows():
        return app.call('history-state', query='Example History')['rows']
    def imports():
        return sum(r['visits'] for r in history_rows())
    def choose_history():
        app.call('first-run', action='import')
        app.call('first-run', action='select', spaces=True, archive=True, history=True, secrets=True)
        app.call('first-run', action='continue')
    try:
        # A live, uncommitted WAL transaction must never lock Open's landing.
        locked = Path(tmp) / 'arc-history-wal'
        shutil.copytree(source, locked)
        ready = Path(tmp) / 'history-writer-ready'
        writer = subprocess.Popen([sys.executable, '-c', '''
import pathlib, sqlite3, sys, time
c = sqlite3.connect(sys.argv[1]); c.execute('PRAGMA journal_mode=WAL'); c.execute('PRAGMA wal_autocheckpoint=0')
c.execute('INSERT INTO visits VALUES(7,2,13437000040000000,0,0)'); c.commit()
c.execute('BEGIN IMMEDIATE'); c.execute('INSERT INTO visits VALUES(8,2,13437000050000000,0,0)')
pathlib.Path(sys.argv[2]).touch(); time.sleep(180)
''', str(locked/'User Data/Default/History'), str(ready)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert h.wait_until(ready.exists, timeout=5, step=.05)
        app = launch(fresh=True, directory=locked, OPEN_AUTOMATION_HISTORY_DELAY_MS='3000')
        app.call('defaults', key='open.firstRun.completed', value=None)
        app.call('defaults', key='open.advanced.tabSleepMode', value=None)
        choose_history()
        assert h.wait_until(lambda: state()['historyInProgress'], timeout=15, step=.02), state()
        pings = [app.call('ping') for _ in range(3)]
        landed = state()
        result = until('report')
        row('F8_wal_writer', writer.poll() is None and bool(pings)
            and landed['browserHasLanded'] and not landed['importInProgress']
            and len(app.call('shell-windows')) == 1
            and ((result['outcome'].get('History') == 4 and imports() == 4)
                 or ('History' in result['failures'] and 'history visits could not be read' in result['error'])),
            outcome=result['outcome'], failures=result['failures'], pings=pings, landed=landed)
        # The disabled selection is excluded even if an automation caller tries it.
        # Code-path proof: neither App adapter nor runner constructs a consent
        # token or calls a decrypt/Keychain API. countOnly remains in ArcProbe.
        root = Path(h.ROOT)
        paths = ['App/Import/AppImportRunner.swift', 'App/FirstRun/AppFirstRunActions.swift', 'App/Settings/AppSettingsActions.swift']
        text = '\n'.join((root/p).read_text() for p in paths)
        forbidden = ['SecItemCopyMatching', 'grantedByUser(', 'ChromiumCrypto.', 'ArcSecretsReader(']
        row('F10_passwords_off', not result['secretsEnabled'] and not result['outcome'].get('Passwords and cookies', 0)
            and result['step'] == 'report' and all(token not in text for token in forbidden),
            proof='Capability OFF excludes attempted selection. Shared Continue Without Passwords uses skipSecrets; no consent or decrypt call in App paths.',
            files=paths, keychainCalls='0 by unreachable code path; no runtime Keychain interception')
        app.call('first-run', action='continue'); app.call('first-run', action='finish'); app.quit()
        writer.terminate(); writer.wait(timeout=5); writer = None

        # 5,000 kept visits use the production reader and one real transaction.
        large = Path(tmp) / 'arc-history-5000'
        shutil.copytree(source, large)
        with sqlite3.connect(large/'User Data/Default/History') as db:
            db.execute('DELETE FROM visits')
            db.executemany('INSERT INTO visits VALUES(?,?,?,1,1)',
                [(i, 1 + (i % 2), 13437000000000000 + i * 1000000) for i in range(1, 5001)])
        app = launch(fresh=True, directory=large, OPEN_AUTOMATION_HISTORY_DELAY_MS='10000')
        app.call('defaults', key='open.firstRun.completed', value=None)
        choose_history()
        assert h.wait_until(lambda: state()['historyInProgress'], timeout=15, step=.02), state()
        before = state()
        opened = app.call('open', url='https://example.org')
        loaded = app.call('wait', tab=opened['id'], timeout=30)
        browsing = state()
        app.call('snapshot', path=str(Path(h.OUT)/'firstrun/progress-history-landed.png'))
        app.call('save')
        saved = json.loads((Path(app.user_data)/'State/browser.json').read_text())
        row('F9_browse_during_history', before['browserHasLanded'] and before['progress'] is not None
            and not before['importInProgress'] and browsing['historyInProgress'] and bool(loaded)
            and 'https://example.org' in json.dumps(saved), before=before, after=browsing)
        # Close the real progress window, then let its already-owned import finish.
        app.call('first-run', action='focus')
        app.call('key', key='w', modifiers=['command'])
        closed = state()
        result = until('report')
        row('F9_close_keeps_history', not closed['active'] and closed['historyInProgress']
            and result['outcome'].get('History') == 5000 and imports() == 5000,
            outcome=result['outcome'], visits=imports())
        app.call('first-run', action='continue'); app.call('first-run', action='finish')
        # Same destination through the actual Settings sheet: History only.
        app.call('first-run', action='settings-import', directory=str(large))
        app.call('first-run', action='settings-select', historyOnly=True, history=True)
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        assert h.wait_until(lambda: state().get('settingsStep') == 'Report', timeout=30, step=.05), state()
        repeat = state()['settingsOutcome']
        row('F9_settings_history_only_repeat', repeat.get('History') == 0
            and repeat.get('History duplicates') == 5000 and imports() == 5000
            and repeat.get('Imported Spaces', 0) == 0 and repeat.get('Imported tabs', 0) == 0,
            outcome=repeat, visits=imports())
        app.call('first-run', action='settings-done'); app.quit()

        # Reader failure after a good probe preserves sidebar and E-2's count.
        bad = Path(tmp) / 'arc-history-failed'
        shutil.copytree(source, bad)
        app = launch(fresh=True, directory=bad)
        assert h.wait_until(lambda: state().get('probeReady'), timeout=15, step=.05)
        (bad/'User Data/Default/History').write_bytes(b'synthetic unreadable history')
        choose_history(); failed = until('report')
        row('E2_history_failure', failed['outcome'].get('Imported Spaces') == 2
            and failed['failures'].get('History') == 'Could not be read'
            and failed['outcome'].get('History failed') == 3 and '3 history visits could not be read' in failed['error']
            and len(app.call('shell-windows')) == 1 and app.call('ping').get('pid') == app.pid,
            outcome=failed['outcome'], error=failed['error'])
        app.quit()

        # Import age starts in Open, including an unselected Today tab. The
        # source timestamps and pinned/Favorite timestamps remain unchanged.
        old = Path(tmp) / 'arc-old-today'
        shutil.copytree(source, old)
        sidebar = old / 'StorableSidebar.json'
        graph = json.loads(sidebar.read_text())
        items = graph['sidebar']['containers'][1]['items']
        named = {item.get('title'): item for item in items if isinstance(item, dict)}
        past = time.time() - 978307200 - 48 * 60 * 60
        for name in ('t0', 't1', 'p2', 'favorite'):
            named['Example ' + name]['data']['tab']['timeLastActiveAt'] = past
        sidebar.write_text(json.dumps(graph))
        original = sidebar.read_bytes()
        today_id = named['Example t1']['id']
        pinned_id = named['Example p2']['id']
        favorite_id = named['Example favorite']['id']

        def saved_tabs():
            data = json.loads(Path(app.call('save')).read_text())
            rows = {}
            def visit(value):
                if isinstance(value, dict):
                    if 'id' in value and 'url' in value: rows[value['id']] = value
                    for child in value.values(): visit(child)
                elif isinstance(value, list):
                    for child in value: visit(child)
            visit(data)
            return rows

        def settings_import():
            app.call('first-run', action='settings-import', directory=str(old))
            app.call('first-run', action='settings-select', history=False)
            app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
            assert h.wait_until(lambda: state().get('settingsStep') == 'Report', timeout=30, step=.05), state()
            outcome = state()['settingsOutcome']
            app.call('first-run', action='settings-done')
            return outcome

        app = launch(fresh=True, directory=old)
        app.call('first-run', action='import')
        app.call('first-run', action='select', history=False)
        started = time.time()
        app.call('first-run', action='continue'); until('report')
        landed = saved_tabs()
        intervals = [profile['settings']['autoArchiveAfter']
            for profile in json.loads(Path(app.call('save')).read_text())['profiles']]
        app.call('first-run', action='continue'); app.call('first-run', action='finish')
        finished = saved_tabs()
        app.quit(); app = launch(directory=old)
        reloaded = saved_tabs()
        row('import_today_age_after_relaunch', today_id in finished and today_id in reloaded
            and intervals == ['twelveHours']
            and landed[today_id]['lastActiveAt'] >= started
            and landed[pinned_id]['lastActiveAt'] == past + 978307200
            and landed[favorite_id]['lastActiveAt'] == past + 978307200
            and sidebar.read_bytes() == original,
            sourceAgeHours=48, archiveIntervals=intervals, todayPresent=today_id in reloaded,
            sourceUnchanged=sidebar.read_bytes() == original)
        repeat = settings_import()
        row('import_old_today_repeat', repeat.get('Imported tabs') == 0
            and saved_tabs()[today_id]['lastActiveAt'] == reloaded[today_id]['lastActiveAt'], outcome=repeat)

        # The same stable IDs can have moved into Archive through real commands.
        # A Favorite moved to Today and closed is also already in Open.
        beta = next(space['id'] for space in app.call('spaces') if space['title'] == 'Beta')
        app.call('space', space=beta)
        app.call('close', tab=today_id)
        app.call('sidebar-move', tab=favorite_id, section='today')
        app.call('close', tab=favorite_id)
        archived = {r['id'] for r in app.call('archive-list')['rows']}
        repeat = settings_import()
        remaining = saved_tabs()
        row('import_manual_archive_stays_archived', {today_id, favorite_id} <= archived
            and today_id not in remaining and favorite_id not in remaining
            and repeat.get('Imported tabs') == 0 and repeat.get('Favorites') == 0,
            outcome=repeat, manuallyArchived=2, sourceUnchanged=sidebar.read_bytes() == original)

        # A genuinely new old Today tab added through Settings gets a fresh
        # activity timestamp too, and survives the next startup sweep.
        import uuid
        new_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/first-run/new-old-today')).upper()
        tab = dict(id=new_id, title='Example new old Today', createdAt=past,
            data={'tab': dict(savedURL='https://example.com/new-old-today', savedTitle='Example new old Today', timeLastActiveAt=past)}, childrenIds=[])
        items.extend([new_id, tab])
        beta_today = next(item for item in items if isinstance(item, dict) and today_id in item.get('childrenIds', []))
        beta_today['childrenIds'].append(new_id)
        sidebar.write_text(json.dumps(graph))
        started = time.time(); added = settings_import(); fresh = saved_tabs()
        app.quit(); app = launch(directory=old)
        row('import_settings_today_age', added.get('Imported tabs') == 1 and new_id in saved_tabs()
            and fresh[new_id]['lastActiveAt'] >= started, outcome=added, sourceAgeHours=48)
        app.quit()
    finally:
        if writer is not None:
            writer.terminate(); writer.wait(timeout=5)
        if app is not None:
            app.quit()
