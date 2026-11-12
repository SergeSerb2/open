"""IMC: import from Chrome-family browsers through the real Settings import sheet.

Every source file is a synthetic fixture under a private `Library` root that the
App reads through `--browser-import-library`. No real browser data is read.
Rows: source detection, counts, bookmarks folder tree, history, search engine,
re-import idempotency, Undo, second profile with a custom search engine, and
unselectable sources (no data / not yet supported).
"""
import json
import os
from pathlib import Path
import sqlite3
import time

CHROME_EPOCH = 11644473600 * 1000000


def chromium_time(unix):
    return str(int(unix * 1000000) + CHROME_EPOCH)


def write_history(path, rows):
    with sqlite3.connect(path) as db:
        db.executescript('''
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version','70');
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL,
                typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, from_visit INTEGER,
                transition INTEGER DEFAULT 0 NOT NULL, incremented_omnibox_typed_score BOOLEAN DEFAULT FALSE NOT NULL);
            CREATE TABLE keyword_search_terms(keyword_id INTEGER NOT NULL, url_id INTEGER NOT NULL, term LONGVARCHAR NOT NULL);
        ''')
        now = time.time() - 3600
        for i, (url, title, visits) in enumerate(rows):
            db.execute('INSERT INTO urls(id,url,title) VALUES(?,?,?)', (i + 1, url, title))
            for v in range(visits):
                db.execute('INSERT INTO visits(url,visit_time,transition) VALUES(?,?,?)',
                           (i + 1, int(chromium_time(now - 60 * (i * 10 + v))), 1 if v == 0 else 0))


def snss(commands, version=3):
    """A synthetic Chromium session file: 'SNSS', int32 version, then uint16 size + uint8 id + payload."""
    import struct
    out = b'SNSS' + struct.pack('<i', version)
    for cid, payload in commands:
        out += struct.pack('<H', len(payload) + 1) + bytes([cid]) + payload
    return out


def navigation(tab, index, url, title):
    import struct
    def align(b): return b + b'\0' * (-len(b) % 4)
    body = struct.pack('<ii', tab, index)
    body += align(struct.pack('<i', len(url)) + url.encode())
    t = title.encode('utf-16-le')
    body += align(struct.pack('<i', len(title)) + t)
    body += align(struct.pack('<i', 0)) + struct.pack('<ii', 0, 0)  # page state, transition, type mask
    return (6, struct.pack('<I', len(body)) + body)


def session_fixture(sessions):
    """Window 1 (normal): tab 10 (two navigations, the second selected), pinned tab 11, chrome:// tab 12,
    closed tab 13. Window 2 is closed (tab 20). Window 3 is a popup (tab 30). An older file and an encrypted
    (version 5) file must be ignored."""
    import struct
    ii = lambda a, b: struct.pack('<ii', a, b)
    cmds = [(9, ii(1, 0)), (9, ii(2, 0)), (9, ii(3, 1))]
    for tab, window, index in ((10, 1, 0), (11, 1, 1), (12, 1, 2), (13, 1, 3), (20, 2, 0), (30, 3, 0)):
        cmds += [(0, ii(window, tab)), (2, ii(tab, index))]
    cmds += [navigation(10, 0, 'https://old.example.com/', 'Example Old'), navigation(10, 1, 'https://tab.example.com/', 'Example Tab'),
             (7, ii(10, 1)), navigation(11, 0, 'https://pinned.example.com/', 'Example Pinned'), (12, struct.pack('<i?xxx', 11, True)),
             navigation(12, 0, 'chrome://settings/', 'Settings'), navigation(13, 0, 'https://closed.example.com/', 'Example Closed'),
             (16, struct.pack('<iiq', 13, 0, 0)), navigation(20, 0, 'https://window.example.com/', 'Example Window'),
             (17, struct.pack('<iiq', 2, 0, 0)), navigation(30, 0, 'https://popup.example.com/', 'Example Popup'), (255, b'')]
    sessions.mkdir(parents=True)
    (sessions/'Session_13400000000000000').write_bytes(snss(cmds))
    (sessions/'Session_13300000000000000').write_bytes(snss([(9, ii(1, 0)), (0, ii(1, 50)), navigation(50, 0, 'https://older.example.com/', 'Example Older')]))
    (sessions/'Tabs_13400000000000000').write_bytes(snss([]))
    encrypted = sessions.parent/'Sessions_Encrypted'; encrypted.mkdir()
    (encrypted/'Session_13500000000000000').write_bytes(snss([], version=5))


def fixture(library):
    """Synthetic Chrome (two profiles), an empty Brave folder, and a Firefox folder."""
    chrome = library/'Application Support/Google/Chrome'
    (chrome/'Default').mkdir(parents=True)
    (chrome/'Profile 1').mkdir()
    (chrome/'Local State').write_text(json.dumps({'profile': {
        'info_cache': {'Default': {'name': 'Example Person'}, 'Profile 1': {'name': 'Example Work'}},
        'profiles_order': ['Default', 'Profile 1']}}))
    added = chromium_time(time.time() - 86400)
    def url(guid, name, href):
        return {'type': 'url', 'guid': guid, 'id': guid[-2:], 'name': name, 'url': href, 'date_added': added}
    bookmarks = {'version': 1, 'checksum': '0', 'roots': {
        'bookmark_bar': {'type': 'folder', 'guid': '00000000-0000-4000-a000-000000000001', 'name': 'Bookmarks bar', 'children': [
            url('10000000-0000-4000-a000-000000000001', 'Example One', 'https://one.example.com/'),
            url('10000000-0000-4000-a000-000000000002', 'Example Two', 'https://two.example.com/'),
            {'type': 'folder', 'guid': '10000000-0000-4000-a000-000000000003', 'name': 'Example Folder', 'children': [
                url('10000000-0000-4000-a000-000000000004', 'Example Nested', 'https://nested.example.com/a'),
                url('10000000-0000-4000-a000-000000000005', 'Example Script', 'javascript:void(0)')]}]},
        'other': {'type': 'folder', 'guid': '00000000-0000-4000-a000-000000000002', 'name': 'Other bookmarks', 'children': [
            url('10000000-0000-4000-a000-000000000006', 'Example Other', 'https://other.example.com/')]},
        'synced': {'type': 'folder', 'guid': '00000000-0000-4000-a000-000000000003', 'name': 'Mobile bookmarks', 'children': []}}}
    (chrome/'Default/Bookmarks').write_text(json.dumps(bookmarks))
    write_history(chrome/'Default/History', [('https://one.example.com/', 'Example One', 3),
                                             ('https://two.example.com/', 'Example Two', 2),
                                             ('chrome://settings/', 'Settings', 1)])
    (chrome/'Default/Preferences').write_text(json.dumps({'default_search_provider_data': {'template_url_data': {
        'short_name': 'DuckDuckGo', 'keyword': 'duckduckgo.com', 'url': 'https://duckduckgo.com/?q={searchTerms}'}}}))
    session_fixture(chrome/'Default/Sessions')
    # I-2: secret stores with rows only (no real ciphertext; counts are read without a key).
    with sqlite3.connect(chrome/'Default/Login Data') as db:
        db.executescript("""CREATE TABLE logins(origin_url VARCHAR NOT NULL, username_value VARCHAR, password_value BLOB,
            signon_realm VARCHAR NOT NULL, blacklisted_by_user INTEGER NOT NULL DEFAULT 0);""")
        db.executemany('INSERT INTO logins VALUES(?,?,?,?,0)', [('https://%s.example.com/' % n, 'example', b'v10', 'https://%s.example.com/' % n) for n in ('a', 'b', 'c')])
    with sqlite3.connect(chrome/'Default/Cookies') as db:
        db.executescript("CREATE TABLE cookies(host_key TEXT NOT NULL, name TEXT NOT NULL, encrypted_value BLOB);")
        db.executemany('INSERT INTO cookies VALUES(?,?,?)', [('.example.com', 'a', b'v10'), ('.example.com', 'b', b'v10')])
    # Extensions: one Web Store extension (a reinstall candidate) and one component (internal, excluded).
    (chrome/'Default/Secure Preferences').write_text(json.dumps({'extensions': {'settings': {
        'aaaabbbbccccddddeeeeffffgggghhhh': {'path': 'aaaabbbbccccddddeeeeffffgggghhhh/1.0', 'from_webstore': True,
                                             'manifest': {'name': 'Example Extension', 'version': '1.0'}},
        'iiiijjjjkkkkllllmmmmnnnnoooopppp': {'path': '/Applications/Example.app/Contents/Resources/component',
                                             'manifest': {'name': 'Example Component', 'version': '1.0'}}}}}))
    work = {'version': 1, 'checksum': '0', 'roots': {
        'bookmark_bar': {'type': 'folder', 'guid': '00000000-0000-4000-b000-000000000001', 'name': 'Bookmarks bar', 'children': [
            url('20000000-0000-4000-a000-000000000001', 'Example Work', 'https://work.example.com/')]},
        'other': {'type': 'folder', 'guid': '00000000-0000-4000-b000-000000000002', 'name': 'Other bookmarks', 'children': []}}}
    (chrome/'Profile 1/Bookmarks').write_text(json.dumps(work))
    (chrome/'Profile 1/Preferences').write_text(json.dumps({'default_search_provider': {'guid': 'example-guid'}}))
    with sqlite3.connect(chrome/'Profile 1/Web Data') as db:
        db.executescript('''CREATE TABLE keywords(id INTEGER PRIMARY KEY, short_name VARCHAR NOT NULL, keyword VARCHAR NOT NULL,
            favicon_url VARCHAR NOT NULL DEFAULT '', url VARCHAR NOT NULL, suggest_url VARCHAR DEFAULT '', sync_guid VARCHAR);''')
        db.execute("INSERT INTO keywords(short_name,keyword,url,sync_guid) VALUES('Example Search','ex','https://search.example.com/find?q={searchTerms}&ie={inputEncoding}','example-guid')")
    # Input limits: a Bookmarks file of exactly 64 MiB is read; one byte more is refused.
    limit = 64 << 20
    edge = library/'Application Support/Microsoft Edge/Default'; edge.mkdir(parents=True)
    body = json.dumps({'roots': {'bookmark_bar': {'type': 'folder', 'children': [url('30000000-0000-4000-a000-000000000001', 'Example Edge', 'https://edge.example.com/')]}}})
    (edge/'Bookmarks').write_text(body + ' ' * (limit - len(body)))
    import struct
    one_tab = snss([(9, struct.pack('<ii', 1, 0)), (0, struct.pack('<ii', 1, 5)), navigation(5, 0, 'https://edge-tab.example.com/', 'Example')])
    (edge/'Sessions').mkdir()
    (edge/'Sessions/Session_1').write_bytes(one_tab + b'\0' * ((32 << 20) - len(one_tab)))
    vivaldi = library/'Application Support/Vivaldi/Default'; vivaldi.mkdir(parents=True)
    (vivaldi/'Sessions').mkdir()
    (vivaldi/'Sessions/Session_1').write_bytes(one_tab + b'\0' * ((32 << 20) + 1 - len(one_tab)))
    (vivaldi/'Bookmarks').write_text(body + ' ' * (limit + 1 - len(body)))
    (library/'Application Support/BraveSoftware/Brave-Browser').mkdir(parents=True)
    (library/'Application Support/Arc').mkdir(parents=True)
    (library/'Application Support/Firefox/Profiles').mkdir(parents=True)


def sidebar(app):
    data = json.loads(Path(app.call('save')).read_text())
    found = []
    def walk(nodes, path):
        for node in nodes:
            if 'folder' in node:
                folder = node['folder']['_0']
                found.append(('folder', path + [folder['title']], None))
                walk(folder.get('children', []), path + [folder['title']])
            elif 'tab' in node:
                tab = node['tab']['_0']
                found.append(('tab', path, tab.get('pinnedURL')))
    for space in data['spaces']:
        walk(space.get('pinned', []), [space['id']])
    return data, found


def visit_count(app):
    total = 0
    for file in (Path(app.user_data)/'Profiles').glob('*/State/history.sqlite3'):
        with sqlite3.connect('file:' + str(file) + '?mode=ro', uri=True) as db:
            if db.execute("SELECT count(*) FROM sqlite_master WHERE name='visits'").fetchone()[0]:
                total += db.execute('SELECT count(*) FROM visits').fetchone()[0]
    return total


def run(factory, results, tmp, h):
    library = Path(tmp)/'import-browsers'/'Library'
    if library.exists():
        import shutil; shutil.rmtree(library)
    fixture(library)
    def row(name, ok, **detail):
        results[name] = dict(ok=bool(ok), **detail)
    app = factory(urls=(), fresh=True, extra_args=['--browser-import-library=' + str(library),
                                                   '--host-resolver-rules=MAP * ~NOTFOUND'])
    def state(): return app.call('first-run', action='settings-inspect')
    def settle():
        assert h.wait_until(lambda: not state().get('settingsBusy'), timeout=30, step=.05), state()
        return state()
    def open_sources():
        app.call('first-run', action='settings-open-sources')
        return settle()
    def run_import(profile=None, **select):
        open_sources()
        app.call('first-run', action='settings-source', id='chrome')
        if profile: app.call('first-run', action='settings-profile', id=profile)
        if select: app.call('first-run', action='settings-browser-select', **select)
        chosen = settle()
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        assert h.wait_until(lambda: state().get('settingsStep') == 'Report' and not state().get('settingsBusy'), timeout=120, step=.05), state()
        report = state()
        app.call('first-run', action='settings-done')
        return chosen, report

    s = open_sources()
    sources = {item['id']: item for item in s.get('settingsSources', [])}
    visible = [item['id'] for item in s.get('settingsSources', []) if item.get('visible')]
    # Capture s5: Arc lists detected browsers only, preselects nothing, and keeps Next disabled until a pick.
    row('sources_detected', s.get('settingsStep') == 'Source' and visible == ['arc', 'chrome', 'firefox', 'edge', 'vivaldi']
        and sources['chrome']['selectable'] and sources['arc']['selectable']
        and [p['name'] for p in sources['chrome']['profiles']] == ['Example Person', 'Example Work']
        and s.get('settingsSelectedSource') == '' and s.get('settingsCanContinueFromSource') is False,
        step=s.get('settingsStep'), visible=visible, selected=s.get('settingsSelectedSource'),
        canContinue=s.get('settingsCanContinueFromSource'))
    # Capture s5 hides a detected browser without an importable profile; lead 01:55 keeps Firefox as "Coming soon".
    row('sources_hidden_without_profile', 'brave' in sources and 'brave' not in visible and 'opera' not in sources
        and sources.get('firefox', {}).get('selectable') is False and sources['firefox']['status'] == 'Coming soon',
        sources=sorted(sources), visible=visible, firefox=sources.get('firefox', {}).get('status'))
    app.call('first-run', action='settings-cancel-passwords')

    before_data, before_nodes = sidebar(app)
    before_visits = visit_count(app)
    chosen, report = run_import()
    labels = chosen.get('settingsBrowserLabels', {})
    row('choose_counts', chosen.get('settingsTitle') == 'Import from Chrome' and labels.get('Bookmarks') == 'Found: 4'
        and labels.get('History') == 'Found: 6' and labels.get('Search settings') == 'DuckDuckGo',
        title=chosen.get('settingsTitle'), labels=labels)
    outcome = report.get('settingsOutcome', {})
    secrets_state = app.call('import-secrets-state')
    row('secrets_counts_only', labels.get('Passwords and cookies') == 'Found: 5' and labels.get('Passwords') == 'Found: 3'
        and labels.get('Cookies') == 'Found: 2' and chosen.get('settingsBrowserSecretsEnabled') is False
        and chosen.get('settingsSecretsTitle') == "Passwords and cookies can't be imported yet."
        and all(secrets_state[k] == 0 for k in ('consentAdapterCalls', 'keychainProbeCalls', 'keychainReadCalls')),
        labels=labels, enabled=chosen.get('settingsBrowserSecretsEnabled'),
        keychain={k: secrets_state[k] for k in ('consentAdapterCalls', 'keychainProbeCalls', 'keychainReadCalls')})
    row('extensions_list', report.get('settingsExtensions') == ['aaaabbbbccccddddeeeeffffgggghhhh'],
        extensions=report.get('settingsExtensions'))
    data, nodes = sidebar(app)
    imported = [n for n in nodes if n not in before_nodes]
    folders = sorted('/'.join(n[1][1:]) for n in imported if n[0] == 'folder')
    tabs = sorted(n[2] for n in imported if n[0] == 'tab' and len(n[1]) > 1 and n[1][1] == 'Imported from Chrome')
    row('bookmarks_folder_tree', outcome.get('Bookmarks') == 4 and folders == [
            'Imported from Chrome', 'Imported from Chrome/Bookmarks bar', 'Imported from Chrome/Bookmarks bar/Example Folder',
            'Imported from Chrome/Other bookmarks'] and tabs == ['https://nested.example.com/a', 'https://one.example.com/',
            'https://other.example.com/', 'https://two.example.com/'] and outcome.get('Skipped bookmarks') == 1
        and report.get('settingsReportSummary') == 'Imported 4 bookmarks.' and not report.get('settingsError'),
        outcome=outcome, folders=folders, tabs=len(tabs), summary=report.get('settingsReportSummary'), error=report.get('settingsError'))
    data_tabs = [dict(t) for space in data['spaces'] for t in
                 [x['tab']['_0'] for x in space.get('today', []) if 'tab' in x]]
    pinned_top = [n[2] for n in imported if n[0] == 'tab' and len(n[1]) == 1]
    row('open_tabs', labels.get('Open tabs') == 'Found: 2' and outcome.get('Open tabs') == 2
        and sorted(t['url'] for t in data_tabs if 'example.com' in t['url']) == ['https://tab.example.com/']
        and pinned_top == ['https://pinned.example.com/'],
        label=labels.get('Open tabs'), imported=outcome.get('Open tabs'), today=[t['url'] for t in data_tabs], pinned=pinned_top)
    after_visits = visit_count(app)
    row('history_imported', outcome.get('History') == 5 and after_visits - before_visits == 5,
        history=outcome.get('History'), visits=after_visits - before_visits)
    engines = {p['settings']['searchEngineID'] for p in data['profiles']}
    row('search_engine', outcome.get('Search settings') == 1 and 'duckduckgo' in engines, engines=sorted(engines))

    def labels_for(source_id):
        open_sources()
        app.call('first-run', action='settings-source', id=source_id)
        result = settle().get('settingsBrowserLabels', {})
        app.call('first-run', action='settings-cancel-passwords')
        return result
    at_limit, over_limit = labels_for('edge'), labels_for('vivaldi')
    row('bookmarks_size_limit', at_limit.get('Bookmarks') == 'Found: 1' and over_limit.get('Bookmarks') == 'Could not be read',
        atLimit=at_limit.get('Bookmarks'), overLimit=over_limit.get('Bookmarks'))
    row('session_size_limit', at_limit.get('Open tabs') == 'Found: 1' and over_limit.get('Open tabs') == 'Could not be read',
        atLimit=at_limit.get('Open tabs'), overLimit=over_limit.get('Open tabs'))

    _, again = run_import()
    repeat = again.get('settingsOutcome', {})
    data2, nodes2 = sidebar(app)
    row('reimport_idempotent', repeat.get('Bookmarks') == 0 and repeat.get('Open tabs') == 0 and repeat.get('History') == 0 and repeat.get('Duplicates', 0) >= 9
        and sorted(map(str, nodes2)) == sorted(map(str, nodes)) and visit_count(app) == after_visits,
        repeat=repeat, nodes=len(nodes2))

    # Undo the no-op repeat, then the real import (the Edit menu path via the sidebar key).
    undo_title = state().get('undoTitle')
    app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
    for _ in range(2):
        app.call('sidebar-key', key='z', modifiers=['command'])
        assert h.wait_until(lambda: not state().get('importUndoInProgress', False), timeout=30, step=.05)
    _, undone = sidebar(app)
    row('undo', undo_title == 'Import from Chrome' and sorted(map(str, undone)) == sorted(map(str, before_nodes))
        and visit_count(app) == before_visits, undoTitle=undo_title, nodes=len(undone), visits=visit_count(app) - before_visits)

    chosen, report = run_import(profile='Profile 1', history=False)
    outcome = report.get('settingsOutcome', {})
    data, nodes = sidebar(app)
    custom = [e for p in data['profiles'] for e in p['settings'].get('customSearchEngines', [])]
    engines = {p['settings']['searchEngineID'] for p in data['profiles']}
    row('second_profile_custom_search', outcome.get('Bookmarks') == 1 and 'History' not in outcome
        and chosen.get('settingsBrowserLabels', {}).get('Search settings') == 'Example Search'
        and 'imported-ex' in engines and any(e['id'] == 'imported-ex' and e['searchURLTemplate'] == 'https://search.example.com/find?q=%s&ie=UTF-8' for e in custom),
        outcome=outcome, engines=sorted(engines), custom=[e['id'] for e in custom])

    # I-2: one chosen profile only. The synthetic secrets fixture (generated key, no Keychain) runs through the
    # real engine sinks with the same restriction the Chromium import uses.
    app.quit()
    app = factory(urls=(), fresh=True, extra_args=['--open-allow-mock-keychain-secrets', '--open-e2e',
                                                   '--host-resolver-rules=MAP * ~NOTFOUND'])
    def fixture_import(**args):
        deadline = time.time() + 30
        while True:
            try: return app.call('import-secrets-fixture', **args)
            except RuntimeError as error:
                if 'ready mock-key engine' not in str(error) or time.time() > deadline: raise
                time.sleep(.2)
    restricted = fixture_import(map={'Default': 'Default'}, only=['Default'])
    control = fixture_import(map={'Default': 'Default'})
    rr, cr = restricted.get('report', {}), control.get('report', {})
    row('secrets_one_profile', restricted.get('stage') == 'finished' and sorted(rr.get('profiles', {})) == ['Default']
        and rr.get('unmappedProfiles') == 0 and rr['total']['logins']['added'] > 0
        and cr.get('unmappedProfiles') == 1 and cr['total']['logins']['added'] == 0,
        restricted=dict(profiles=sorted(rr.get('profiles', {})), unmapped=rr.get('unmappedProfiles'), logins=rr.get('total', {}).get('logins')),
        control=dict(profiles=sorted(cr.get('profiles', {})), unmapped=cr.get('unmappedProfiles')))

    # I-5: first run with no Arc data and a detected Chrome. Onboarding offers Chrome; the import lands in the
    # first-run browser; the Favorites step preselects the most visited sites from the imported history.
    app.quit()
    import shutil
    first_library = Path(tmp)/'import-browsers'/'FirstRunLibrary'
    shutil.rmtree(first_library, ignore_errors=True)
    shutil.copytree(library, first_library, ignore=shutil.ignore_patterns('Vivaldi', 'Microsoft Edge', 'Arc'))
    history = first_library/'Application Support/Google/Chrome/Default/History'
    history.unlink()
    write_history(history, [('https://github.com/example', 'Example Repo', 5), ('https://www.youtube.com/watch', 'Example Video', 4),
                            ('https://rare.example.com/', 'Example Rare', 1)])
    empty_arc = Path(tmp)/'import-browsers'/'NoArc'; empty_arc.mkdir(exist_ok=True)
    app = factory(urls=(), fresh=True, first_run=True, extra_args=['--browser-import-library=' + str(first_library),
                  '--arc-dir=' + str(empty_arc), '--host-resolver-rules=MAP * ~NOTFOUND', '--intro-sound=silent'])
    if app.call('onboarding').get('active'):
        app.call('onboarding', action='skip-intro'); app.call('onboarding', action='get-started')
    assert h.wait_until(lambda: app.call('onboarding').get('screen') == 'name', timeout=20, step=.1), app.call('onboarding')
    app.call('onboarding', action='next')
    assert h.wait_until(lambda: app.call('onboarding').get('screen') == 'import' and app.call('first-run').get('step') == 'importChoices'
                        and app.call('first-run').get('browserSource') == 'chrome', timeout=30, step=.1), app.call('onboarding')
    offered = app.call('first-run')
    frames = Path(h.OUT)/'import-browsers-frames'; frames.mkdir(exist_ok=True)
    def capture(name):
        # Look frames for the lead (not asserted): the real onboarding window, light and dark.
        for mode in ('light', 'dark'):
            app.call('onboarding', action='set-appearance', appearance=mode); time.sleep(.6)
            app.call('snapshot', path=str(frames/('onboarding-%s-%s.png' % (name, mode))))
    capture('import-browser')
    app.call('first-run', action='select', history=True)
    app.call('onboarding', action='next')
    assert h.wait_until(lambda: app.call('first-run').get('step') in ('report', 'failed'), timeout=120, step=.1), app.call('first-run')
    done = app.call('first-run')
    app.call('onboarding', action='next')
    assert h.wait_until(lambda: app.call('onboarding').get('screen') == 'favorites', timeout=20, step=.1), app.call('onboarding')
    favorites = app.call('onboarding').get('favorites')
    capture('favorites-suggested')
    data, nodes = sidebar(app)
    folder = [n for n in nodes if n[0] == 'folder' and n[1][1:] == ['Imported from Chrome']]
    row('onboarding_browser_import', offered.get('browserSource') == 'chrome' and offered.get('browserSources') == ['chrome']
        and done.get('step') == 'report' and done.get('outcome', {}).get('Bookmarks') == 4 and done.get('outcome', {}).get('Open tabs') == 2
        and done.get('outcome', {}).get('History') == 10 and len(folder) == 1,
        source=offered.get('browserSource'), sources=offered.get('browserSources'), step=done.get('step'),
        outcome={k: done.get('outcome', {}).get(k) for k in ('Bookmarks', 'Open tabs', 'History')}, folder=len(folder))
    # Sites: index 2 = YouTube, 6 = GitHub (OnboardingStepsController.sites).
    row('onboarding_favorite_suggestions', done.get('suggestedHosts') == ['github.com', 'youtube.com'] and favorites == [2, 6],
        suggested=done.get('suggestedHosts'), favorites=favorites)
