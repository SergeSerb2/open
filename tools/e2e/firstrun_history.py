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
        paths = ['App/Import/AppImportRunner.swift', 'App/FirstRun/AppFirstRunActions.swift']
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
    finally:
        if writer is not None:
            writer.terminate(); writer.wait(timeout=5)
        if app is not None:
            app.quit()
