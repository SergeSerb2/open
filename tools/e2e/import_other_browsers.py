"""IMF: import from Firefox and Safari through the real Settings import sheet.

All source files are synthetic. `openkit firefox-fixture` and `openkit safari-fixture` write them
(Firefox logins need NSS encryption, which the Python standard library lacks). The App reads a
private `Library` root through `--browser-import-library`; no real browser data is read, and the
wizard never opens System Settings for a synthetic library (it counts the request instead).
Rows: detection, Firefox counts/import/re-import/Undo, Primary Password, running Firefox (lock),
Safari Full Disk Access (denied on Next, then granted), Safari live import, Safari export + CSV.
"""
import fcntl
import json
import os
import sqlite3
import struct
import tempfile
import uuid
from pathlib import Path
import runpy
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def openkit():
    # The newest build wins, so a stale release binary never writes an old fixture.
    found = [p for p in (ROOT/'Packages/OpenKit/.build/release/openkit', ROOT/'Packages/OpenKit/.build/debug/openkit') if p.exists()]
    for path in sorted(found, key=lambda p: p.stat().st_mtime, reverse=True):
        if subprocess.run([str(path), 'firefox-fixture'], capture_output=True).returncode == 2:
            return str(path)
    # The caller already holds the machine's build slot (heavy.sh); nested builds reuse it.
    subprocess.run(['swift', 'build', '--product', 'openkit'], cwd=ROOT/'Packages/OpenKit', check=True,
                   stdout=subprocess.DEVNULL)
    return str(ROOT/'Packages/OpenKit/.build/debug/openkit')


def mozlz4(document):
    """A Firefox session file: `mozLz40\0`, u32 size, then one LZ4 block of literals only (valid LZ4)."""
    raw = json.dumps(document).encode()
    n, token = len(raw), min(len(raw), 15) << 4
    length = b''
    if n >= 15:
        rest = n - 15
        length = b'\xff' * (rest // 255) + bytes([rest % 255])
    return b'mozLz40\0' + struct.pack('<I', n) + bytes([token]) + length + raw


def session_tabs(windows):
    """Session JSON: each tab is (url, pinned) or a raw dict."""
    def tab(t):
        if isinstance(t, dict): return t
        url, pinned = t
        return {'entries': [{'url': url, 'title': 'Example'}], 'index': 1, 'pinned': pinned}
    return {'version': ['sessionrestore', 1], 'windows': [{'tabs': [tab(t) for t in w]} for w in windows]}


def run(factory, results, tmp, h):
    helpers = runpy.run_path(str(ROOT/'tools/e2e/import_browsers.py'))
    sidebar, visit_count = helpers['sidebar'], helpers['visit_count']
    base = Path(tmp)/'import-other'
    if base.exists():
        shutil.rmtree(base)
    library, files = base/'Library', base/'files'
    cli = openkit()
    subprocess.run([cli, 'firefox-fixture', '--out', str(library/'Application Support/Firefox')], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([cli, 'safari-fixture', '--out', str(files)], check=True, stdout=subprocess.DEVNULL)
    shutil.copytree(files/'Library/Safari', library/'Safari')
    safari_dir = library/'Safari'
    default_profile = library/'Application Support/Firefox/Profiles/syn0001.default-release'

    def row(name, ok, **detail):
        results[name] = dict(ok=bool(ok), **detail)
    # A crash can leave private source copies (history, secret stores) in the temporary folder. The App
    # removes ones older than an hour after launch and keeps younger ones (another live import).
    temp_root = Path(tempfile.gettempdir())
    stale, young = temp_root/('open-history-import-e2e-' + str(uuid.uuid4())), temp_root/('open-history-import-e2e-' + str(uuid.uuid4()))
    for folder in (stale, young):
        folder.mkdir(mode=0o700); (folder/'Login Data').write_bytes(b'synthetic')
    old = time.time() - 2 * 3600
    os.utime(stale/'Login Data', (old, old)); os.utime(stale, (old, old))
    # The mock-key engine writes logins only with this switch (OEAutofill.mm Import); the secrets suites use it too.
    app = factory(urls=(), fresh=True, extra_args=['--browser-import-library=' + str(library), '--open-allow-mock-keychain-secrets',
                                                   '--host-resolver-rules=MAP * ~NOTFOUND'])
    def call(action, **args): return app.call('first-run', action=action, **args)
    def state(): return call('settings-inspect')
    def settle():
        assert h.wait_until(lambda: not state().get('settingsBusy'), timeout=30, step=.05), state()
        return state()
    def open_sources():
        call('settings-open-sources'); return settle()
    def cancel():
        settle()  # counting after an access grant can still be running (slower rented Macs)
        if state().get('settingsStep') not in ('Report', ''):
            call('settings-cancel-passwords')
    def finish_import():
        call('settings-next'); call('settings-run')
        assert h.wait_until(lambda: state().get('settingsStep') == 'Report' and not state().get('settingsBusy'), timeout=180, step=.05), state()
        report = state(); call('settings-done')
        return report
    def logins():
        return app.call('credentials', profile='Default')['logins']
    def today_urls(data):
        urls = []
        for space in data['spaces']:
            for node in space.get('today', []):
                if 'tab' in node: urls.append(node['tab']['_0'].get('url'))
        return urls
    def folders_of(nodes, root):
        return sorted('/'.join(n[1][1:]) for n in nodes if n[0] == 'folder' and n[1][1:2] == [root])
    swept = h.wait_until(lambda: not stale.exists(), timeout=15, step=.2)
    row('stale_import_copies_swept', swept and young.exists(), staleGone=not stale.exists(), youngKept=young.exists())
    shutil.rmtree(young, ignore_errors=True); shutil.rmtree(stale, ignore_errors=True)
    # Seed: a second key4.db row carries the SDR key ID with a NULL key blob, ahead of the real key row.
    # The reader must skip it and use the row that decrypts (every Firefox password failed before).
    with sqlite3.connect(default_profile/'key4.db') as db:
        db.execute("UPDATE nssPrivate SET a11 = NULL, a102 = X'F8000000000000000000000000000001' WHERE id = 1")

    # Detection: Firefox profiles from profiles.ini (default first); Safari is one profile.
    s = open_sources()
    sources = {item['id']: item for item in s.get('settingsSources', [])}
    ff, sf = sources.get('firefox', {}), sources.get('safari', {})
    row('sources_detected', ff.get('selectable') and [p['name'] for p in ff.get('profiles', [])] == ['Synthetic Default', 'Synthetic Work']
        and sf.get('selectable') and [p['id'] for p in sf.get('profiles', [])] == ['Safari'],
        firefox=(ff.get('selectable'), ff.get('status'), [p['name'] for p in ff.get('profiles', [])]),
        safari=(sf.get('selectable'), sf.get('status')))
    cancel()

    # Files that exist but cannot be read are "Could not be read", never "Not found".
    session_file = default_profile/'sessionstore-backups/recovery.jsonlz4'
    for path in (default_profile/'logins.json', session_file): os.chmod(path, 0)
    try:
        open_sources(); call('settings-source', id='firefox')
        unreadable = {k: v for k, v in settle().get('settingsBrowserLabels', {}).items() if k in ('Passwords', 'Open tabs')}
    finally:
        for path in (default_profile/'logins.json', session_file): os.chmod(path, 0o644)
        cancel()
    row('firefox_unreadable_labels', unreadable == {'Passwords': 'Could not be read', 'Open tabs': 'Could not be read'},
        labels=unreadable)
    # A FIFO in place of logins.json must not block the reader (open without O_NONBLOCK waits for a writer).
    logins_file = default_profile/'logins.json'
    shutil.move(str(logins_file), str(files/'logins.json.aside'))
    os.mkfifo(logins_file)
    fifo_label, fifo_settled = None, False
    try:
        open_sources(); call('settings-source', id='firefox')
        fifo_settled = bool(h.wait_until(lambda: not state().get('settingsBusy'), timeout=20, step=.1))
        fifo_label = state().get('settingsBrowserLabels', {}).get('Passwords') if fifo_settled else None
    except Exception as error:
        fifo_label = 'error: %s' % str(error)[:80]
    finally:
        try:  # release a reader blocked in open() (old code): a writer end that closes gives it EOF
            os.close(os.open(logins_file, os.O_WRONLY | os.O_NONBLOCK))
        except OSError:
            pass
        logins_file.unlink()
        shutil.move(str(files/'logins.json.aside'), str(logins_file))
    if fifo_settled: cancel()
    row('firefox_fifo_not_blocking', fifo_settled and fifo_label == 'Could not be read', settled=fifo_settled, label=fifo_label)

    # Firefox: counts on Choose, then the import.
    before_data, before_nodes = sidebar(app)
    before_visits, before_logins = visit_count(app), logins()
    open_sources(); call('settings-source', id='firefox')
    chosen = settle()
    labels = {k: v for k, v in chosen.get('settingsBrowserLabels', {}).items() if k in ('Bookmarks', 'History', 'Passwords', 'Open tabs')}
    row('firefox_choose', chosen.get('settingsStep') == 'Choose' and chosen.get('settingsTitle') == 'Import from Firefox'
        and labels == {'Bookmarks': 'Found: 6', 'History': 'Found: 7,003', 'Passwords': 'Found: 3', 'Open tabs': 'Found: 4'}
        and chosen.get('settingsPasswords') is True and not chosen.get('settingsNeedsPrimaryPassword'),
        step=chosen.get('settingsStep'), labels=labels, passwords=chosen.get('settingsPasswords'))
    report = finish_import()
    outcome = report.get('settingsOutcome', {})
    data, nodes = sidebar(app)
    imported = [n for n in nodes if n not in before_nodes]
    folders = folders_of(imported, 'Imported from Firefox')
    tabs = sorted(n[2] for n in imported if n[0] == 'tab' and n[1][1:2] == ['Imported from Firefox'])
    row('firefox_bookmarks', outcome.get('Bookmarks') == 6 and folders == [
            'Imported from Firefox', 'Imported from Firefox/Bookmarks Menu', 'Imported from Firefox/Bookmarks Toolbar',
            'Imported from Firefox/Bookmarks Toolbar/Synthetic Nested 1', 'Imported from Firefox/Bookmarks Toolbar/Synthetic Nested 1/Deeper']
        and len(tabs) == 6 and 'https://menu.example.test/1' in tabs and report.get('settingsReportSummary') == 'Imported 6 bookmarks.',
        outcome={k: outcome.get(k) for k in ('Bookmarks', 'Skipped bookmarks')}, folders=folders, tabs=len(tabs))
    # I-6: the last session. The pinned tab stays pinned at the top level; the others become Today tabs.
    pinned_open = sorted(n[2] for n in imported if n[0] == 'tab' and len(n[1]) == 1)
    new_today = [u for u in today_urls(data) if u not in today_urls(before_data)]
    row('firefox_open_tabs', outcome.get('Open tabs') == 4 and pinned_open == ['https://pinned.session.example.test/s1']
        and sorted(new_today) == ['https://current.session.example.test/2', 'https://second.session.example.test/w2', 'https://third.session.example.test/w2'],
        outcome=outcome.get('Open tabs'), pinned=pinned_open, today=new_today)
    # Bug sweep r4 F-10: the session file (up to 64 MiB LZ4, 256 MiB JSON) is read and parsed off the
    # main thread, as bookmarks, history and passwords are. Before, the whole UI froze for its read.
    row('firefox_open_tabs_read_off_main', report.get('openTabsReadOnMainThread') is False,
        readOnMainThread=report.get('openTabsReadOnMainThread'))
    after_visits = visit_count(app)
    row('firefox_history', outcome.get('History') == 5600 and after_visits - before_visits == 5600,
        history=outcome.get('History'), visits=after_visits - before_visits)
    after_logins = logins()
    row('firefox_passwords', outcome.get('Passwords') == 3 and outcome.get('Skipped passwords') == 1 and after_logins - before_logins == 3
        and report.get('settingsReportCategories') == ['Bookmarks', 'History', 'Passwords', 'Open tabs'] and not report.get('settingsError'),
        passwords=outcome.get('Passwords'), skipped=outcome.get('Skipped passwords'), logins=after_logins - before_logins,
        failures=report.get('settingsFailures'),
        appLog=[l for l in app.log_text().splitlines() if 'browser passwords import failed' in l][:3],
        error=report.get('settingsError'))

    # Re-import: nothing new, also after Firefox reordered its windows and tabs (IDs must not hold
    # positions); then Undo both imports (the sidebar and history; passwords stay, as for Arc).
    original_session = session_file.read_bytes()
    session_file.write_bytes(mozlz4(session_tabs([
        [('https://third.session.example.test/w2', False), ('https://second.session.example.test/w2', False)],
        [{'entries': [{'url': 'https://back.session.example.test/1'}, {'url': 'https://current.session.example.test/2'}], 'index': 2},
         ('https://pinned.session.example.test/s1', True)]])))
    open_sources(); call('settings-source', id='firefox'); settle()
    again = finish_import().get('settingsOutcome', {})
    _, nodes2 = sidebar(app)
    row('firefox_reimport', again.get('Bookmarks') == 0 and again.get('History') == 0 and again.get('Passwords') == 0 and again.get('Open tabs') == 0
        and again.get('Password duplicates') == 3 and sorted(map(str, nodes2)) == sorted(map(str, nodes)) and visit_count(app) == after_visits
        and logins() == after_logins, repeat={k: again.get(k) for k in ('Bookmarks', 'History', 'Passwords', 'Password duplicates', 'Open tabs')})
    session_file.write_bytes(original_session)
    undo_title = state().get('undoTitle')
    app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
    for _ in range(2):
        app.call('sidebar-key', key='z', modifiers=['command'])
        assert h.wait_until(lambda: not state().get('importUndoInProgress', False), timeout=60, step=.05)
    _, undone = sidebar(app)
    row('firefox_undo', undo_title == 'Import from Firefox' and sorted(map(str, undone)) == sorted(map(str, before_nodes))
        and visit_count(app) == before_visits and today_urls(sidebar(app)[0]) == today_urls(before_data),
        undoTitle=undo_title, visits=visit_count(app) - before_visits)

    # Bug sweep r3 L16: open tabs imported by a build before round 2 (IDs with the window and list
    # position) are not added again by a re-import of the same session. Before, every one was.
    def open_tabs_import():
        open_sources(); call('settings-source', id='firefox'); settle()
        call('settings-browser-select', bookmarks=False, history=False, passwords=False, openTabs=True)
        return finish_import().get('settingsOutcome', {})
    legacy_key = 'open.automation.firefoxLegacyOpenTabIDs'
    app.call('defaults', key=legacy_key, value=True)
    try:
        legacy = open_tabs_import()
    finally:
        app.call('defaults', key=legacy_key, value=None)
    current = open_tabs_import()
    # The same session in another order (other windows and positions than the old IDs hold).
    legacy_session = session_file.read_bytes()
    session_file.write_bytes(mozlz4(session_tabs([
        [('https://third.session.example.test/w2', False), ('https://second.session.example.test/w2', False)],
        [{'entries': [{'url': 'https://back.session.example.test/1'}, {'url': 'https://current.session.example.test/2'}], 'index': 2},
         ('https://pinned.session.example.test/s1', True)]])))
    try:
        reordered = open_tabs_import()
    finally:
        session_file.write_bytes(legacy_session)
    row('firefox_reimport_legacy_ids', legacy.get('Open tabs') == 4 and current.get('Open tabs') == 0
        and current.get('Open tab duplicates') == 4 and reordered.get('Open tabs') == 0 and reordered.get('Open tab duplicates') == 4,
        legacy={k: legacy.get(k) for k in ('Open tabs', 'Open tab duplicates')},
        current={k: current.get(k) for k in ('Open tabs', 'Open tab duplicates')},
        reordered={k: reordered.get(k) for k in ('Open tabs', 'Open tab duplicates')})
    app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
    for _ in range(4):
        if state().get('undoTitle') != 'Import from Firefox':
            break
        app.call('sidebar-key', key='z', modifiers=['command'])
        assert h.wait_until(lambda: not state().get('importUndoInProgress', False), timeout=60, step=.05)

    # Primary Password (profile "Synthetic Work"): Next stays off without it; a wrong one is reported; the right one imports.
    def work_passwords(password):
        open_sources(); call('settings-source', id='firefox'); settle()
        call('settings-profile', id='syn0002.work'); s = settle()
        call('settings-browser-select', bookmarks=False, history=False, passwords=True, openTabs=False)
        blocked = state().get('settingsCanContinue')
        call('settings-browser-select', primaryPassword=password)
        return s, blocked, finish_import()
    s, blocked, wrong = work_passwords('wrong')
    row('primary_password_wrong', s.get('settingsNeedsPrimaryPassword') and blocked is False
        and wrong.get('settingsFailures', {}).get('Passwords') == 'The Primary Password is not correct',
        needs=s.get('settingsNeedsPrimaryPassword'), blockedWithout=blocked, failures=wrong.get('settingsFailures'))
    count = logins()
    _, _, right = work_passwords('synthetic-primary')
    row('primary_password_right', right.get('settingsOutcome', {}).get('Passwords') == 3 and logins() - count == 3,
        outcome=right.get('settingsOutcome', {}).get('Passwords'), logins=logins() - count)

    # A session whose tab index is Int.min (a corrupt or hand-made file) is skipped, not a crash.
    original_session = session_file.read_bytes()
    session_file.write_bytes(mozlz4(session_tabs([[{'entries': [{'url': 'https://min.session.example.test/'}], 'index': -2**63},
                                                    ('https://ok.session.example.test/', False)]])))
    try:
        open_sources(); call('settings-source', id='firefox')
        tabs_label = settle().get('settingsBrowserLabels', {}).get('Open tabs')
    finally:
        session_file.write_bytes(original_session)
        cancel()
    row('firefox_session_index_min', tabs_label == 'Found: 1', label=tabs_label)

    # A running Firefox holds the profile lock: Arc's "Quit Firefox to continue importing".
    lock = os.open(default_profile/'.parentlock', os.O_RDWR | os.O_CREAT)
    holder = subprocess.Popen(['/usr/bin/python3', '-c', 'import fcntl,sys,os;f=os.open(sys.argv[1],os.O_RDWR);fcntl.lockf(f,fcntl.LOCK_EX);print("locked",flush=True);sys.stdin.read()',
                               str(default_profile/'.parentlock')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        assert holder.stdout.readline().strip() == 'locked'
        open_sources(); call('settings-source', id='firefox')
        blocked = settle()
        holder.stdin.close(); holder.wait(timeout=10)
        released = h.wait_until(lambda: state().get('settingsStep') == 'Choose', timeout=10, step=.1)
        row('firefox_running', blocked.get('settingsStep') == 'Access' and blocked.get('settingsAccess') == 'quitBrowser'
            and blocked.get('settingsAccessTitle') == 'Quit Firefox to continue importing.' and released,
            step=blocked.get('settingsStep'), access=blocked.get('settingsAccess'), released=released)
    finally:
        if holder.poll() is None: holder.kill()
        os.close(lock)
        cancel()

    # Safari without Full Disk Access: selectable; Next asks for access at once, then continues when granted.
    os.chmod(safari_dir, 0)
    try:
        s = open_sources()
        sf = {i['id']: i for i in s.get('settingsSources', [])}.get('safari', {})
        requests = s.get('fullDiskAccessRequests', 0)
        call('settings-source', id='safari')
        blocked = settle()
    finally:
        os.chmod(safari_dir, 0o755)
    granted = h.wait_until(lambda: state().get('settingsStep') == 'Choose', timeout=10, step=.1)
    row('safari_full_disk_access', sf.get('selectable') and blocked.get('settingsStep') == 'Access'
        and blocked.get('settingsAccess') == 'fullDiskAccess' and blocked.get('fullDiskAccessRequests') == requests + 1 and granted,
        selectable=sf.get('selectable'), step=blocked.get('settingsStep'), requests=blocked.get('fullDiskAccessRequests', 0) - requests,
        granted=granted)
    cancel()

    # Safari live files.
    _, before_nodes = sidebar(app)
    before_visits = visit_count(app)
    open_sources(); call('settings-source', id='safari')
    chosen = settle()
    labels = {k: v for k, v in chosen.get('settingsBrowserLabels', {}).items() if k in ('Bookmarks', 'History', 'Passwords', 'Open tabs')}
    report = finish_import()
    outcome = report.get('settingsOutcome', {})
    _, nodes = sidebar(app)
    folders = folders_of([n for n in nodes if n not in before_nodes], 'Imported from Safari')
    row('safari_live', labels == {'Bookmarks': 'Found: 3', 'History': 'Found: 5', 'Passwords': 'Choose a passwords file'}
        and outcome.get('Bookmarks') == 3 and folders == ['Imported from Safari', 'Imported from Safari/Favorites',
            'Imported from Safari/Favorites/Synthetic Live Folder', 'Imported from Safari/Reading List']
        and outcome.get('History') == 4 and visit_count(app) - before_visits == 4,
        labels=labels, outcome={k: outcome.get(k) for k in ('Bookmarks', 'History')}, folders=folders)

    # Safari export ZIP plus a Passwords.csv (a non-passwords file is refused first).
    _, before_nodes = sidebar(app)
    before_visits, before_logins = visit_count(app), logins()
    open_sources(); call('settings-source', id='safari'); settle()
    call('settings-passwords-file', path=str(files/'Notes.csv'))
    refused = settle().get('settingsWizardError', '')
    call('settings-safari-export', path=str(files/'Safari Export.zip')); settle()
    call('settings-passwords-file', path=str(files/'Passwords.csv'))
    chosen = settle()
    labels = {k: v for k, v in chosen.get('settingsBrowserLabels', {}).items() if k in ('Bookmarks', 'History', 'Passwords', 'Open tabs')}
    report = finish_import()
    outcome = report.get('settingsOutcome', {})
    _, nodes = sidebar(app)
    def safari_roots(found): return sum(1 for n in found if n[0] == 'folder' and n[1][1:] == ['Imported from Safari'])
    roots_before, roots_after = safari_roots(before_nodes), safari_roots(nodes)
    # #580 (reviewed design, LEAD Q4 2026-11-17): a separate Passwords.csv adds to the export ZIP's
    # password count, so the wizard shows 3 + 3 = 6. The import itself saves 3 new logins and reports
    # the 3 that repeat as duplicates.
    row('safari_export_csv', "doesn't look like a passwords file" in refused and chosen.get('settingsSafariExport') == 'Safari Export.zip'
        and labels == {'Bookmarks': 'Found: 5', 'History': 'Found: 6,002', 'Passwords': 'Found: 6'} and chosen.get('settingsPasswords') is True
        and outcome.get('Bookmarks') == 5 and (roots_before, roots_after) == (1, 2)
        and outcome.get('History') == 6000 and visit_count(app) - before_visits == 6000
        and outcome.get('Passwords') == 3 and outcome.get('Password duplicates') == 3 and logins() - before_logins == 3,
        refused=refused[:60], labels=labels, safariFolders=(roots_before, roots_after), failures=report.get('settingsFailures'),
        outcome={k: outcome.get(k) for k in ('Bookmarks', 'History', 'Passwords', 'Password duplicates')}, logins=logins() - before_logins)

    # A '"' inside an unquoted CSV field is a literal character (Chromium's CSV rule). Before, it opened
    # a quoted field and swallowed every later row.
    quoted_csv = files/'Passwords-quote.csv'
    quoted_csv.write_text('Title,URL,Username,Password\nQuote,https://quote.example.com/,example-quote,pa"ss\n'
                          'After,https://after.example.com/,example-after,fixture-after\n')
    before_logins = logins()
    open_sources(); call('settings-source', id='safari'); settle()
    call('settings-passwords-file', path=str(quoted_csv)); settle()
    call('settings-browser-select', bookmarks=False, history=False, passwords=True)
    quoted_chosen = settle()
    quoted_report = finish_import()
    quoted = quoted_report.get('settingsOutcome', {})
    row('safari_csv_inner_quote', quoted.get('Passwords') == 2 and logins() - before_logins == 2,
        outcome={k: quoted.get(k) for k in ('Passwords', 'Skipped passwords', 'Password duplicates')}, logins=logins() - before_logins,
        label=quoted_chosen.get('settingsBrowserLabels', {}).get('Passwords'), plan=quoted_chosen.get('settingsPlan'),
        failures=quoted_report.get('settingsFailures'), error=quoted_report.get('settingsError'),
        appLog=[l for l in app.log_text().splitlines() if 'browser passwords import failed' in l][-3:])

    # A fresh Safari profile has no Bookmarks.plist: Bookmarks shows "Not found", is unticked and disabled, and the
    # Report has no "could not be imported" line (hand check, IMF 20:15). The file returns for later rows.
    aside = files/'Bookmarks.plist.aside'
    shutil.move(str(safari_dir/'Bookmarks.plist'), aside)
    try:
        open_sources(); call('settings-source', id='safari')
        chosen = settle()
        label = chosen.get('settingsBrowserLabels', {}).get('Bookmarks')
        report = finish_import()
    finally:
        shutil.move(str(aside), safari_dir/'Bookmarks.plist')
    row('safari_not_found_unticked', label == 'Not found' and chosen.get('settingsPlan', {}).get('bookmarks') is False
        and 'Bookmarks' in chosen.get('settingsNotFound', []) and chosen.get('settingsPlan', {}).get('history') is True
        and report.get('settingsError') == '' and 'Bookmarks' not in report.get('settingsFailures', {}),
        label=label, plan=chosen.get('settingsPlan'), notFound=chosen.get('settingsNotFound'),
        error=report.get('settingsError'), failures=report.get('settingsFailures'))

    # I-5 data sources in IMC's onboarding (first run, no Arc data): Safari without Full Disk Access is not
    # offered; a running Firefox stops the import; Favorites come from Firefox frecency + visit counts.
    app.quit()
    first = base/'first-run'
    first_library, no_arc = first/'Library', first/'NoArc'
    shutil.copytree(library/'Application Support/Firefox', first_library/'Application Support/Firefox')
    (first_library/'Safari').mkdir(parents=True); no_arc.mkdir()
    shutil.copy(files/'Library/Safari/Bookmarks.plist', first_library/'Safari/Bookmarks.plist')
    os.chmod(first_library/'Safari', 0)
    try:
        app = factory(urls=(), fresh=True, first_run=True, extra_args=['--browser-import-library=' + str(first_library),
                      '--arc-dir=' + str(no_arc), '--host-resolver-rules=MAP * ~NOTFOUND', '--intro-sound=silent'])
        if app.call('onboarding').get('active'):
            app.call('onboarding', action='skip-intro'); app.call('onboarding', action='get-started')
        assert h.wait_until(lambda: app.call('onboarding').get('screen') == 'name', timeout=20, step=.1), app.call('onboarding')
        app.call('onboarding', action='next')
        assert h.wait_until(lambda: app.call('first-run').get('browserSource') == 'firefox'
                            and app.call('first-run').get('step') == 'importChoices', timeout=30, step=.1), app.call('first-run')
        offered = app.call('first-run')
        row('onboarding_sources', offered.get('browserSources') == ['firefox'], sources=offered.get('browserSources'))
        lock_file = first_library/'Application Support/Firefox/Profiles/syn0001.default-release/.parentlock'
        holder = subprocess.Popen(['/usr/bin/python3', '-c', 'import fcntl,sys,os;f=os.open(sys.argv[1],os.O_RDWR);fcntl.lockf(f,fcntl.LOCK_EX);print("locked",flush=True);sys.stdin.read()',
                                   str(lock_file)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            assert holder.stdout.readline().strip() == 'locked'
            app.call('first-run', action='select', history=True)
            app.call('onboarding', action='next')
            time.sleep(1)
            blocked = app.call('first-run')
        finally:
            holder.stdin.close(); holder.wait(timeout=10)
        row('onboarding_firefox_running', blocked.get('step') == 'importChoices' and blocked.get('error') == 'Quit Firefox to continue importing.',
            step=blocked.get('step'), error=blocked.get('error'))
        app.call('onboarding', action='next')
        assert h.wait_until(lambda: app.call('first-run').get('step') in ('report', 'failed'), timeout=180, step=.1), app.call('first-run')
        done = app.call('first-run')
        outcome = done.get('outcome', {})
        row('onboarding_firefox_import', done.get('step') == 'report' and outcome.get('Bookmarks') == 6 and outcome.get('Open tabs') == 4
            and outcome.get('History') == 5600, step=done.get('step'), outcome={k: outcome.get(k) for k in ('Bookmarks', 'Open tabs', 'History')})
        app.call('onboarding', action='next')
        assert h.wait_until(lambda: app.call('onboarding').get('screen') == 'favorites', timeout=20, step=.1), app.call('onboarding')
        hosts = done.get('suggestedHosts', [])
        favorites = app.call('onboarding').get('favorites')
        # Sites: 6 = GitHub, 11 = Wikipedia (OnboardingStepsController.sites). YouTube has 3 visits but ranks below 8 hosts.
        row('onboarding_firefox_suggestions', hosts[:2] == ['github.com', 'en.wikipedia.org'] and len(hosts) == 8 and favorites == [6, 11],
            hosts=hosts, favorites=favorites)
    finally:
        os.chmod(first_library/'Safari', 0o755)
