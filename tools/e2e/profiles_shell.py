"""Section 10 acceptance through the real App, Settings, native fields and AX actions."""
import json
import os
import subprocess
import time
import uuid
from pathlib import Path


def run(factory, results, tmp, api, defaults_before):
    wait = api['wait_until']
    restore = api['_restore_defaults']
    server, origin = api['_fixture_server']('Profiles shell')
    keys = ('open.general.searchSuggestNoticeDismissed', 'open.links.littleOpenNUXSeen')
    saved = {key: defaults_before.get(key) for key in keys}
    app = None

    def launch(**args):
        nonlocal app
        app = factory(urls=(), **args)
        for key in keys:
            app.call('defaults', key=key, value=True)
        return app

    def state(**args):
        return app.call('profiles-shell', **args)

    def profile(name):
        return next(row for row in state()['profiles'] if row['name'] == name)

    def little(url=None):
        sessions = app.call('little-open-state')['sessions']
        return next((s for s in sessions if url is None or s['url'] == url), None)

    def page_ready(url):
        def ready():
            session = little(url)
            return session if session and session['content'] and not session['loading'] else None
        answer = wait(ready, timeout=30)
        assert answer, 'Little Open page did not load: ' + url
        return answer

    def press(label):
        return state(action='press', label=label)

    def show(name=None):
        state(action='show', **({'profile': name} if name else {}))
        time.sleep(.15)

    def confirm(name, token=None, bulk=False):
        show(name)
        press('Delete Unused Profiles…' if bulk else 'Delete Profile')
        assert wait(lambda: state()['sheet'] > 0, timeout=5), state()
        before = state()
        assert ('Delete Unused Profiles' if bulk else 'Delete this Profile') in before['sheetText'], before
        state(action='type-delete', text=token if token is not None else name)
        typed = state()
        assert typed['deleteEnabled'] and typed['deleteAXEnabled'] is True, typed
        press('Delete')
        assert wait(lambda: not state()['deleting'] and state()['sheet'] == 0, timeout=15), state()
        return before, typed, state()

    try:
        launch(fresh=True)
        one = state()
        results['shell_indicator_one_profile'] = {'ok': len(one['profiles']) == 1 and one['indicators'] == [], 'indicators': one['indicators']}
        snapshot = Path(app.call('save'))
        root = Path(app.user_data)
        app.quit()
        fixture = json.loads(snapshot.read_text())
        default_id = fixture['profiles'][0]['id']
        fixture['spaces'][0]['profileID'] = str(uuid.uuid4()).upper()
        fixture['spaces'][0]['title'] = 'Missing Profile Space'
        snapshot.write_text(json.dumps(fixture))

        launch()
        repaired = state()
        persisted = json.loads(snapshot.read_text())
        results['shell_missing_profile_repair'] = {
            'ok': persisted['spaces'][0]['profileID'] == default_id
                  and repaired['noticeShown'] == 1 and repaired['noticeVisible']
                  and repaired['noticeTitles'] == ['Missing Profile Space'],
            'noticeShown': repaired['noticeShown'], 'titles': repaired['noticeTitles'],
            'savedDefault': persisted['spaces'][0]['profileID'] == default_id}
        state(action='notice-ok')
        app.quit()
        launch()
        repaired_again = state()
        results['shell_repair_notice_once'] = {'ok': repaired_again['noticeShown'] == 0 and not repaired_again['noticeVisible'],
                                               'noticeShown': repaired_again['noticeShown']}

        # An unused Profile acquires a real engine context through its Settings page.
        state(action='create', name='Shell Loaded')
        loaded = profile('Shell Loaded')
        two = wait(lambda: state() if state()['indicators'] else None, timeout=5)
        assert two, state()
        menu = state(action='indicator-menu')
        results['shell_indicator_two_profiles'] = {
            'ok': two['indicators'][0]['label'] == 'Profile: Default'
                  and two['indicators'][0]['frame'][2:] == [20, 20]
                  and all(name in menu['indicatorMenu'] for name in ('Default', 'Shell Loaded', 'New Profile…')),
            'indicators': two['indicators'], 'menu': menu['indicatorMenu']}
        # The shared icon picker runs from the actual Settings row button.
        show('Shell Loaded')
        press('Change icon for Shell Loaded')
        assert wait(lambda: state()['iconPicker'], timeout=5), state()
        state(action='icon-symbol', index=0)
        assert wait(lambda: not state()['iconPicker'] and 'nil' != profile('Shell Loaded')['icon'], timeout=5), state()
        custom_icon = profile('Shell Loaded')['icon']
        state(action='page', page='passwords')
        passwords = page_ready('chrome://settings/passwords')
        results['shell_page_without_space'] = {
            'ok': passwords['profile'] == loaded['id'] and passwords['browser']['context'] == loaded['directory']
                  and loaded['spaces'] == 0 and passwords['profileIconImage'] != '',
            'profileMatches': passwords['profile'] == loaded['id'], 'context': passwords['browser']['context'],
            'icon': custom_icon, 'nativeIconBytes': len(passwords['profileIconImage'])}
        app.call('little-open-action', id=passwords['id'], action='close')

        url = origin + '/loaded'
        state(action='open-url', url=url)
        session = page_ready(url)
        app.call('little-open-eval', id=session['id'], js='document.cookie="shell_delete=old; max-age=86400"; document.cookie')
        app.call('save')
        app.quit()
        old_directory = loaded['directory']
        old_engine = root / 'Engine' / old_directory
        before_cache = json.loads((root / 'Engine/Local State').read_text()).get('profile', {}).get('info_cache', {})
        assert old_directory in before_cache, before_cache

        launch()
        state(profile='Shell Loaded', action='open-url', url=url)
        session = page_ready(url)
        old_cookie = app.call('little-open-eval', id=session['id'], js='document.cookie')
        show('Shell Loaded')
        press('Delete Profile')
        assert wait(lambda: state()['sheet'] > 0, timeout=5), state()
        state(action='type-delete', text='shell loaded')
        wrong = state()
        results['shell_delete_exact_name'] = {'ok': not wrong['deleteEnabled'] and wrong['deleteAXEnabled'] is False,
                                              'draft': wrong['deleteText'], 'nativeEnabled': wrong['deleteAXEnabled']}
        state(action='type-delete', text='Shell Loaded')
        right = state()
        assert right['deleteAXEnabled'] is True and right['deleteEnabled'], right
        press('Delete')
        assert wait(lambda: not any(p['id'] == loaded['id'] for p in state()['profiles']) and not state()['deleting'], timeout=15), state()
        gone = state()
        app.call('key', window=gone['settings'], key='z', modifiers=['cmd'], route='app')
        pending = root / 'Profiles/.pending-wipe.json'
        durable = json.loads(snapshot.read_text())
        results['shell_delete_loaded_immediate'] = {
            'ok': 'shell_delete=old' in old_cookie and 'Shell Loaded' not in gone['rows']
                  and not any(p['id'] == loaded['id'] for p in state()['profiles']) and not gone['canUndo']
                  and not (root / 'Profiles' / old_directory).exists() and old_engine.exists()
                  and old_directory in json.loads(pending.read_text())
                  and not any(p['id'] == loaded['id'] for p in durable['profiles']),
            'modelGone': 'Shell Loaded' not in gone['rows'], 'canUndo': gone['canUndo'],
            'openFilesGone': not (root / 'Profiles' / old_directory).exists(), 'engineDeferred': old_engine.exists(),
            'error': gone['error']}
        app.quit()
        launch()
        local = json.loads((root / 'Engine/Local State').read_text()).get('profile', {})
        results['shell_delete_loaded_relaunch'] = {
            'ok': not old_engine.exists() and old_directory not in local.get('info_cache', {})
                  and local.get('last_used') != old_directory and old_directory not in local.get('last_active_profiles', [])
                  and not pending.exists(), 'engineGone': not old_engine.exists(), 'pendingEmpty': not pending.exists()}

        state(action='create', name='Shell Loaded')
        replacement = profile('Shell Loaded')
        state(action='open-url', url=url)
        session = page_ready(url)
        new_cookie = app.call('little-open-eval', id=session['id'], js='document.cookie')
        results['shell_same_name_cookie_isolation'] = {'ok': 'shell_delete' not in new_cookie and replacement['directory'] != old_directory,
                                                       'cookieAbsent': 'shell_delete' not in new_cookie, 'newDirectory': replacement['directory'] != old_directory}
        app.call('little-open-action', id=session['id'], action='close')

        state(action='create', name='Shell Never Loaded')
        never = profile('Shell Never Loaded')
        engine = root / 'Engine' / never['directory']
        cache = Path.home() / 'Library/Caches' / root.name / 'Engine' / never['directory']
        for folder in (engine, cache):
            folder.mkdir(parents=True, exist_ok=True)
            (folder / 'synthetic-marker').write_text('synthetic profile cleanup')
        assert not never['loaded'], never
        _, _, gone = confirm('Shell Never Loaded')
        results['shell_delete_never_loaded'] = {
            'ok': not engine.exists() and not cache.exists() and not (root / 'Profiles' / never['directory']).exists()
                  and 'Shell Never Loaded' not in gone['rows'], 'engineGone': not engine.exists(), 'cacheGone': not cache.exists()}

        # Bulk lists the captured unused set. Default and a Profile with a Space stay out.
        assigned_space = app.call('space-create', title='Assigned Space', profile='Shell Assigned')
        state(action='create', name='Shell Unused A')
        state(action='create', name='Shell Unused B')
        show('Shell Unused A')
        press('Delete Unused Profiles…')
        assert wait(lambda: state()['sheet'] > 0, timeout=5), state()
        bulk = state()
        state(action='type-delete', text='delete')
        assert not state()['deleteEnabled'] and state()['deleteAXEnabled'] is False, state()
        state(action='type-delete', text='DELETE')
        assert state()['deleteAXEnabled'] is True, state()
        press('Delete')
        assert wait(lambda: not state()['deleting'] and state()['sheet'] == 0, timeout=20), state()
        after = state()
        results['shell_delete_unused'] = {
            'ok': all(name in bulk['deleteNames'] for name in ('Shell Unused A', 'Shell Unused B'))
                  and 'Shell Assigned' not in bulk['deleteNames'] and 'Default' not in bulk['deleteNames']
                  and all(name not in after['rows'] for name in ('Shell Unused A', 'Shell Unused B'))
                  and 'Shell Assigned' in after['rows'], 'listed': bulk['deleteNames'], 'remaining': after['rows']}
        # Every realised Space header resolves its own Profile, including the second Space.
        app.call('space', space=assigned_space)
        assigned = state()
        results['shell_indicator_assigned_profile'] = {'ok': any(i['label'] == 'Profile: Shell Assigned' for i in assigned['indicators']),
                                                      'indicators': assigned['indicators']}
        app.quit()
        launch()  # drain every real deletion before synthetic input-boundary fixtures
        app.quit()
        local_state = root / 'Engine/Local State'
        original_local_state = local_state.read_bytes()
        boundary = []

        def early(label, journal, local_bytes=None, expected=0):
            pending.write_bytes(journal)
            local_state.write_bytes(original_local_state if local_bytes is None else local_bytes)
            env = dict(os.environ, OPEN_USER_DATA=str(root), OPEN_E2E_OWNER_PID=str(os.getpid()),
                       OPEN_AUTOMATION_QUIT_BEFORE_ENGINE='1', OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS='1')
            run = subprocess.run([app.executable, '--skip-first-run', '--use-mock-keychain'], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
            Path(tmp, 'profiles-boundary-' + label + '.log').write_bytes(run.stdout)
            boundary.append({'name': label, 'exit': run.returncode, 'expected': expected})

        try:
            early('journal-at-64KiB', b'[]' + b' ' * (65536 - 2))
            early('journal-over-64KiB', b'[]' + b' ' * (65537 - 2), expected=1)
            early('names-at-1024', json.dumps(['P%04d' % n for n in range(1024)]).encode())
            early('names-over-1024', json.dumps(['P%04d' % n for n in range(1025)]).encode(), expected=1)
            early('name-at-255', json.dumps(['P' * 255]).encode())
            early('name-over-255', json.dumps(['P' * 256]).encode(), expected=1)
            for label, value in [('default', ['Default']), ('path', ['../Default']), ('duplicate', ['A', 'A'])]:
                early(label, json.dumps(value).encode(), expected=1)
            early('trailing-JSON', b'["P"] {}', expected=1)
            # Real launch parser, not an isolated JSON helper. Each allocation is bounded.
            small = json.dumps({'profile': {}, 'padding': ''}, separators=(',', ':')).encode()
            at_limit = small.replace(b'"padding":""', b'"padding":"' + b'x' * (16777216 - len(small)) + b'"')
            early('local-state-at-16MiB', b'["P"]', at_limit)
            early('local-state-over-16MiB', b'["P"]', at_limit + b' ', expected=1)
        finally:
            local_state.write_bytes(original_local_state)
            if pending.exists():
                pending.unlink()
        results['shell_cleanup_input_bounds'] = {'ok': all(row['exit'] == row['expected'] for row in boundary), 'rows': boundary}
    finally:
        if app is not None:
            if not app.closed:
                try:
                    state(action='cancel')
                    state(action='notice-ok')
                except Exception:
                    pass
            restore(app, saved)
            app.quit()
            results['shell_owned_window_cleanup'] = {'ok': app.quit_report.get('ok', False), 'quit': app.quit_report}
        server.shutdown()
        server.server_close()
