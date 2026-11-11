"""Section 10 acceptance through the real App, Settings, native fields and AX actions."""
import json
import http.server
import shutil
import threading
import base64
import os
import re
import subprocess
import time
import uuid
from pathlib import Path
from profiles_first_navigation import run as first_navigation
from profiles_pending_navigation import run as pending_navigation, DELAY_KEY, DELAY_MS


def run(factory, results, tmp, api, defaults_before):
    wait = api['wait_until']
    restore = api['_restore_defaults']
    server, origin = api['_fixture_server']('Profiles shell')
    confirm_key = 'open.profiles.confirmInterProfileMove'
    keys = ('open.general.searchSuggestNoticeDismissed', 'open.links.littleOpenNUXSeen', confirm_key, 'open.settings.lastPane')
    saved = {key: defaults_before.get(key) for key in keys}
    app = None

    def launch(**args):
        nonlocal app
        app = factory(urls=(), **args)
        for key in keys:
            app.call('defaults', key=key, value=None)
        for key in keys[:2]:
            app.call('defaults', key=key, value=True)
        app.call('defaults', key='open.settings.lastPane', value='general')
        return app

    def state(**args):
        return app.call('profiles-shell', **args)

    def profile(name):
        return next(row for row in state()['profiles'] if row['name'] == name)

    def little(url=None):
        sessions = app.call('little-open-state')['sessions']
        return next((s for s in sessions if url is None or s['url'] == url
                    ), None)

    def page_ready(url):
        def ready():
            session = little(url)
            return session if session and session['content'] and not session['loading'] else None
        answer = wait(ready, timeout=30)
        assert answer, 'Little Open page did not load: ' + url + ' ' + repr([{k: row[k] for k in ('url', 'profile', 'content', 'loading', 'browser')}
                                             for row in app.call('little-open-state')['sessions']])
        return answer

    page_urls = {'privacy': 'chrome://settings/privacy',
                 'passwords': 'chrome://password-manager/passwords',
                 'paymentMethods': 'chrome://settings/payments',
                 'notifications': 'chrome://settings/content/notifications'}

    def check_pages(name, has_space):
        chosen = profile(name)
        state(profile=name)
        for page, requested in page_urls.items():
            before = {row['id'] for row in app.call('little-open-state')['sessions']}
            state(action='page', page=page)
            if has_space:
                selected = wait(lambda: next((row for row in app.call('tabs')
                                             if row['selected'] and row.get('page')), None), timeout=10)
                assert selected, app.call('tabs')
                app.call('wait', tab=selected['id'])
                # The WebUI router can replace the URL after the document load.
                final = wait(lambda: app.call('eval', tab=selected['id'], js='location.href') == requested, timeout=5)
                committed = app.call('eval', tab=selected['id'], js='location.href')
                current = app.call('tab-state', tab=selected['id'])
                context = current['page']['context']
                native_url = current['page']['url']
                actual_profile = current['profile']
                app.call('close', tab=selected['id'])
            else:
                def ready():
                    return next((row for row in app.call('little-open-state')['sessions']
                                 if row['id'] not in before and row['content'] and not row['loading']), None)
                session = wait(ready, timeout=30)
                assert session, app.call('little-open-state')
                final = wait(lambda: app.call('little-open-eval', id=session['id'], js='location.href') == requested, timeout=5)
                committed = app.call('little-open-eval', id=session['id'], js='location.href')
                current = next(row for row in app.call('little-open-state')['sessions'] if row['id'] == session['id'])
                context = current['browser']['context']
                native_url = current['url']
                actual_profile = current['profile']
                app.call('little-open-action', id=session['id'], action='close')
            results['shell_page_' + ('tab_' if has_space else 'little_') + page] = {
                'ok': bool(final) and committed == requested and native_url == requested and context == chosen['directory'] and actual_profile == chosen['id'],
                'requestedURL': requested, 'committedURL': committed, 'nativeURL': native_url, 'context': context,
                'profileMatches': actual_profile == chosen['id']}

    def capture_native(label, window=None):
        if window is None:
            window = app.call('window-state')['number']
        meta = next(row for row in app.call('windows') if row['number'] == window)
        width_pt = float(re.findall(r'-?\d+(?:\.\d+)?', meta['frame'])[-2])
        raw = Path(tmp) / (label + '.png')
        shot = app.call('snapshot', window=window, path=str(raw))
        width_px, _, _ = api['read_image'](str(raw))
        scale = width_px / width_pt
        assert scale in (1, 2), (width_px, width_pt)
        destination = evidence / (label + '-%dx.png' % scale)
        raw.replace(destination)
        return dict(shot, path=str(destination), nativeScale=scale)

    def press(label, **args):
        if label == 'Delete Profile' and not args:
            return app.press_profile_delete()
        if label == 'Delete Unused Profiles…' and not args:
            app.call('settings-ui', action='link', url='open://settings/profiles/manage')
            label = 'Delete unused Profiles…'
        return state(action='press', label=label, **args)

    def manager_profile_checks():
        state(action='create', name='Manager Work')
        source = app.call('spaces')[0]
        target = profile('Manager Work')
        # The inline Library reuses one existing browser and its factory.
        # Keep that owner; close every other browser, including private ones.
        owner = next(w for w in app.call('incognito-state')['windows'] if not w['private'])
        for window in list(app.call('incognito-state')['windows']):
            if window['id'] != owner['id']:
                app.call('window-focus', id=window['id'], activate=True)
                app.call('window-close')
        app.call('window-focus', id=owner['id'], activate=True)

        def same_owner():
            windows = app.call('incognito-state')['windows']
            return len(windows) == 1 and windows[0]['id'] == owner['id'] and windows[0]['number'] == owner['number'] and not windows[0]['private']

        assert wait(same_owner, timeout=5)
        manager = app.call('library-open', section='spaces')
        assert manager['window'] == owner['number'] and manager['contextWindow'] == owner['id'] and same_owner(), manager

        def request():
            state(action='indicator-menu', library=True, space=source['id'], item='Manager Work')
            return wait(lambda: state() if state()['managerSheet'] else None, timeout=3)

        def assigned():
            return next(s['profile'] for s in app.call('spaces') if s['id'] == source['id'])

        shown = request()
        text = shown['managerSheetText'] if shown else []
        warning = ('Each Profile has different browser data, so you might get logged out or lose your progress in '
                   + (source['title'] or 'Space 1') + '. Its tabs will reopen with Manager Work data.')
        results['shell_manager_profile_alert'] = {
            'ok': bool(shown) and shown['managerSheetParent'] == manager['window']
                  and all(t in text for t in ('Change Profile?', warning, 'Change Profile', 'Cancel', "Don't show again"))
                  and same_owner() and assigned() == source['profile'],
            'text': text, 'parent': shown['managerSheetParent'] if shown else 0, 'library': manager['window'],
            'profileUnchanged': assigned() == source['profile'], 'owner': owner['id'], 'sameOwner': same_owner()}
        assert results['shell_manager_profile_alert']['ok'], 'Change Profile sheet missing from Library'
        if os.environ.get('OPEN_PROFILES_SHELL_FORCE_MANAGER_DIALOG_FAILURE') == '1':
            raise AssertionError('intentional early Manager sheet failure for cleanup proof')
        app.call('key', window=shown['managerSheet'], key='escape', route='app')
        assert wait(lambda: state()['managerSheet'] == 0, timeout=5)
        results['shell_manager_profile_cancel'] = {'ok': assigned() == source['profile']}
        shown = request()
        assert shown, 'Change Profile sheet missing after Cancel'
        app.call('key', window=shown['managerSheet'], key='return', route='app')
        changed = wait(lambda: assigned() == target['id'] and state()['managerSheet'] == 0, timeout=5)
        undo_name = state()['undoName']
        app.call('key', window=manager['window'], key='z', modifiers=['cmd'], route='app')
        undone = wait(lambda: assigned() == source['profile'], timeout=5)
        results['shell_manager_profile_confirm_undo'] = {'ok': bool(changed and undone) and undo_name == 'Change Profile',
                                                        'changed': bool(changed), 'undone': bool(undone), 'undoName': undo_name}
        assert request(), 'Change Profile sheet missing before suppression'
        press("Don't show again", library=True)
        press('Cancel', library=True)
        assert wait(lambda: state()['managerSheet'] == 0, timeout=5)
        results['shell_manager_profile_cancel_suppression'] = {
            'ok': app.call('defaults', key=confirm_key, persistent=True) is None and assigned() == source['profile']}
        assert request(), 'Cancel must not save suppression'
        press("Don't show again", library=True)
        press('Change Profile', library=True)
        assert wait(lambda: assigned() == target['id'] and state()['managerSheet'] == 0, timeout=5)
        suppressed = app.call('defaults', key=confirm_key, persistent=True) is False
        app.call('key', window=manager['window'], key='z', modifiers=['cmd'], route='app')
        assert wait(lambda: assigned() == source['profile'], timeout=5)
        state(action='indicator-menu', library=True, space=source['id'], item='Manager Work')
        results['shell_manager_profile_suppressed'] = {
            'ok': suppressed and assigned() == target['id'] and state()['managerSheet'] == 0
                  and same_owner(), 'sameOwner': same_owner()}
        app.call('defaults', key=confirm_key, value=None)
        app.call('library-close')

    def show(name=None):
        state(action='show', **({'profile': name} if name else {}))
        time.sleep(.15)

    def confirm(name, token=None, bulk=False):
        show(name)
        press('Delete Unused Profiles…' if bulk else 'Delete Profile')
        assert wait(lambda: state()['sheet'] > 0, timeout=5), state()
        before = state()
        assert ('Delete Unused Profiles' if bulk else 'Delete this Profile') in before['sheetText'], before
        if os.environ.get('OPEN_PROFILES_SHELL_FORCE_DIALOG_FAILURE') == '1':
            raise AssertionError('intentional early dialog failure for cleanup proof')
        state(action='type-delete', text=token if token is not None else name)
        typed = state()
        assert typed['deleteEnabled'] and typed['deleteAXEnabled'] is True, typed
        press('Delete')
        assert wait(lambda: not state()['deleting'] and state()['sheet'] == 0, timeout=15), state()
        return before, typed, state()

    def check_adblock():
        # Exercise Settings and the scheduled real list repository through the actual App.
        # The loopback HTTP server replaces upstream transport only; it serves valid filter lists.
        hold_downloads = threading.Event()
        download_started = threading.Event()
        release_downloads = threading.Event()

        class Lists(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if hold_downloads.is_set():
                    download_started.set()
                    release_downloads.wait(timeout=35)
                body = b'[Adblock Plus 2.0]\n! Profile teardown fixture\n||ads.example.invalid^\n'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # Retirement cancelled this real HTTP transfer.

            def log_message(self, *_):
                pass

        lists = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Lists)
        thread = threading.Thread(target=lists.serve_forever, daemon=True)
        thread.start()
        env = {'OPEN_ADBLOCK_DEBUG_SOURCE_ROOT': 'http://127.0.0.1:%d' % lists.server_port,
               'OPEN_ADBLOCK_DEBUG_UPDATE_DELAY_SECONDS': '12',
               'OPEN_ADBLOCK_DEBUG_SCHEDULE_SCALE': '0.005'}

        def ready(name):
            state(profile=name, action='adblock-open')
            answer = wait(lambda: state() if state()['adblockReady'] else None, timeout=30)
            assert answer, state()
            return answer

        try:
            launch(fresh=True, extra_env=env)
            root = Path(app.user_data)
            default = profile('Default')
            ready('Default')
            state(action='adblock-exclude', host='kept.example.com')
            kept = root / 'Profiles' / default['directory'] / 'AdBlock/exclusions.json'
            before = kept.read_bytes()
            state(action='create', name='Ad Block Deleted')
            victim = profile('Ad Block Deleted')
            assert victim['directory'] != victim['id'], 'fixture must use a non-UUID data directory'
            ready('Ad Block Deleted')
            state(action='adblock-exclude', host='deleted.example.org')
            folder = root / 'Profiles' / victim['directory']
            legacy = root / 'Profiles' / victim['id'] / 'adblock'
            dirty = json.loads((folder / 'AdBlock/exclusions.json').read_text())
            updating = wait(lambda: state()['adblockUpdating'], timeout=5)
            assert updating and dirty == ['example.org'], (updating, dirty, state())
            confirm('Ad Block Deleted')
            # Wait past the held operation via its actual state. Without App forwarding its
            # failure receipt re-creates the deleted folder, which must make this row fail.
            drained = wait(lambda: not state(adblockProfile=victim['id'])['adblockProfileUpdating'], timeout=20)
            retired = state(adblockProfile=victim['id'])['adblockProfileRetired']
            app.quit()
            launch(extra_env=env)
            ready('Default')
            results['shell_adblock_dirty_inflight_delete_relaunch'] = {
                'ok': bool(drained) and retired and not folder.exists() and not legacy.exists()
                      and kept.read_bytes() == before and state()['adblockDomains'] == ['example.com'],
                'dirty': dirty == ['example.org'], 'inFlightBeforeDelete': bool(updating),
                'retired': retired, 'drained': bool(drained), 'folderAbsent': not folder.exists(),
                'legacyAbsent': not legacy.exists(), 'otherProfileUnchanged': kept.read_bytes() == before}

            state(action='create', name='Ad Block Migrated')
            migrated = profile('Ad Block Migrated')
            ready('Ad Block Migrated')
            state(action='adblock-exclude', host='migrated.example.net')
            canonical = root / 'Profiles' / migrated['directory'] / 'AdBlock'
            legacy = root / 'Profiles' / migrated['id'] / 'adblock'
            app.quit()
            legacy.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(canonical / 'lists'), str(legacy))
            for name in ('catalog-state.json', 'exclusions.json'):
                shutil.move(str(canonical / name), str(legacy / name))
            canonical.rmdir()
            old_pointer = (legacy / 'current.json').read_bytes()
            launch(extra_env=env)
            migrated_state = ready('Ad Block Migrated')
            results['shell_adblock_legacy_layout_migration'] = {
                'ok': migrated_state['adblockDomains'] == ['example.net'] and not legacy.exists()
                      and (canonical / 'lists/current.json').read_bytes() == old_pointer
                      and (canonical / 'catalog-state.json').is_file()
                      and kept.read_bytes() == before,
                'settingsDomains': migrated_state['adblockDomains'], 'legacyAbsent': not legacy.exists(),
                'canonicalListsPresent': (canonical / 'lists/current.json').is_file(),
                'otherProfileUnchanged': kept.read_bytes() == before}

            if retired:
                app.quit()
                launch(extra_env=dict(env, OPEN_ADBLOCK_DEBUG_UPDATE_DELAY_SECONDS='0'))
                ready('Default')
                # Hold the initial list download before the Profile opens. This also proves
                # retirement during open, without racing the first scheduled update.
                hold_downloads.set()
                download_started.clear()
                state(action='create', name='Ad Block Network')
                network = profile('Ad Block Network')
                active = wait(lambda: download_started.is_set() and state()['adblockUpdating'], timeout=10)
                assert active, 'Profile open did not enter the held HTTP request'
                network_folder = root / 'Profiles' / network['directory']
                confirm('Ad Block Network')
                ended = state(adblockProfile=network['id'])
                results['shell_adblock_network_retirement'] = {
                    'ok': ended['adblockProfileRetired'] and not ended['adblockProfileUpdating']
                          and not network_folder.exists() and kept.read_bytes() == before,
                    'realHTTPInFlight': bool(active), 'retired': ended['adblockProfileRetired'],
                    'drained': not ended['adblockProfileUpdating'], 'folderAbsent': not network_folder.exists()}
        finally:
            release_downloads.set()
            if app is not None and not app.closed:
                try:
                    state(action='cancel')
                finally:
                    restore(app, saved)
                    app.quit()
            lists.shutdown()
            lists.server_close()
            thread.join(timeout=5)

    try:
        if os.environ.get('OPEN_PROFILES_PENDING_NAV_ONLY') == '1':
            launch(fresh=True, extra_env={DELAY_KEY: str(DELAY_MS)})
            pending_navigation(app, results, origin, api)
            return
        launch(fresh=True)
        first_navigation(app, results, origin, api)
        if os.environ.get('OPEN_PROFILES_FIRST_NAV_ONLY') == '1':
            return
        app.quit()
        launch(fresh=True, extra_env={DELAY_KEY: str(DELAY_MS)})
        pending_navigation(app, results, origin, api)
        app.quit()
        if not any(os.environ.get(key) == '1' for key in
                   ('OPEN_PROFILES_SHELL_PAGES_ONLY', 'OPEN_PROFILES_SHELL_REPAIR_ONLY')):
            check_adblock()
        if os.environ.get('OPEN_PROFILES_SHELL_ADBLOCK_ONLY') == '1':
            return
        launch(fresh=True)
        one = state()
        results['shell_indicator_one_profile'] = {'ok': len(one['profiles']) == 1 and one['indicators'] == [], 'indicators': one['indicators']}
        manager_profile_checks()
        if os.environ.get('OPEN_PROFILES_SHELL_MANAGER_ONLY') == '1':
            return
        app.quit()
        launch(fresh=True)
        if os.environ.get('OPEN_PROFILES_SHELL_PAGES_ONLY') == '1':
            check_pages('Default', has_space=True)
            state(action='create', name='Page Without Space')
            check_pages('Page Without Space', has_space=False)
            return
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
        if os.environ.get('OPEN_PROFILES_SHELL_REPAIR_ONLY') == '1':
            return
        state(action='notice-ok')
        app.quit()
        launch()
        repaired_again = state()
        results['shell_repair_notice_once'] = {'ok': repaired_again['noticeShown'] == 0 and not repaired_again['noticeVisible'],
                                               'noticeShown': repaired_again['noticeShown']}

        check_pages('Default', has_space=True)

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
        normal = next(row for row in app.call('incognito-state')['windows'] if not row['private'])
        app.call('menu-perform', id='new-incognito-window')
        private = wait(lambda: next((row for row in app.call('incognito-state')['windows'] if row['private']), None), timeout=5)
        assert private, 'private window did not open'
        try:
            app.call('window-focus', id=private['id'], activate=True)
            app.call('key', key='escape', route='app')
            private_state = app.call('incognito-state', private=True)
            private_shell = state()
            results['shell_indicator_private_hidden'] = {
                'ok': private_state['private'] and not private_state['modelIsNormal']
                      and private_shell['indicators'] == []
                      and [row['id'] for row in private_shell['profiles']] == [row['id'] for row in two['profiles']],
                'indicators': private_shell['indicators'], 'normalProfiles': len(private_shell['profiles']),
                'privateModelIsNormal': private_state['modelIsNormal']}
        finally:
            app.call('window-close')
            app.call('window-focus', id=normal['id'], activate=True)
        # Native window evidence uses the display's real backing scale.
        # Native 2x hardware captures are recorded separately on the M1.
        evidence = Path(api['ROOT']) / 'docs/profiles-shell'
        evidence.mkdir(parents=True, exist_ok=True)
        app.call('window-frame', frame=[100, 100, 1000, 700])
        capture_rows = []
        for appearance in ('light', 'dark'):
            app.call('appearance', name=appearance)
            for hovered in (False, True):
                header = app.call('window-state')['chrome']['header']
                app.call('mouse', action='hover', x=120 if hovered else 900,
                         y=header[1] + 18 if hovered else 500)
                time.sleep(.15)
                label = 'header-' + appearance + ('-hover' if hovered else '-rest')
                shot = capture_native(label)
                capture_rows.append(dict(shot, appearance=appearance, hovered=hovered))
        results['shell_header_captures'] = {'ok': len(capture_rows) == 4, 'captures': capture_rows}
        show('Shell Loaded')
        state(action='page', page='passwords')
        default_chip = page_ready('chrome://password-manager/passwords')
        app.call('little-open-action', id=default_chip['id'], action='close')
        # The shared icon picker runs from the actual Settings row button.
        show('Shell Loaded')
        press('Change icon for Shell Loaded')
        assert wait(lambda: state()['iconPicker'], timeout=5), state()
        state(action='icon-symbol', index=0)
        assert wait(lambda: not state()['iconPicker'] and 'nil' != profile('Shell Loaded')['icon'], timeout=5), state()
        custom_icon = profile('Shell Loaded')['icon']
        check_pages('Shell Loaded', has_space=False)
        state(action='page', page='passwords')
        passwords = page_ready('chrome://password-manager/passwords')
        native_pixels = []
        for label, session in (('default', default_chip), ('custom', passwords)):
            path = Path(tmp) / ('profile-chip-' + label + '.tiff')
            path.write_bytes(base64.b64decode(session['profileIconImage']))
            w, h, pixel = api['read_image'](str(path))
            native_pixels.append((w, h, [pixel(x, y) for y in range(h) for x in range(w)]))
        results['shell_profile_icon_pixels'] = {'ok': native_pixels[0] != native_pixels[1],
                                               'nativeImagesDiffer': native_pixels[0] != native_pixels[1]}
        results['shell_page_without_space'] = {
            'ok': passwords['profile'] == loaded['id'] and passwords['browser']['context'] == loaded['directory']
                  and loaded['spaces'] == 0 and passwords['profileIconImage'] != '',
            'profileMatches': passwords['profile'] == loaded['id'], 'context': passwords['browser']['context'],
            'requestedURL': 'chrome://password-manager/passwords', 'actualURL': passwords['url'],
            'icon': custom_icon, 'nativeIconBytes': len(passwords['profileIconImage'])}
        for appearance in ('light', 'dark'):
            app.call('appearance', name=appearance)
            capture_native('little-open-profile-' + appearance, window=passwords['window'])
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
        # A named Profile was Chromium's last-used Profile at quit. Default
        # must still use its own native storage after CEF initializes again.
        default_space = next(s['id'] for s in app.call('spaces') if s['profile'] == profile('Default')['id'])
        app.call('space', space=default_space)
        default_page = api['new_tab'](app, origin + '/default-after-relaunch')
        default_cookie = app.eval(default_page, 'document.cookie')
        results['shell_default_after_named_profile_relaunch'] = {
            'ok': app.page(default_page)['context'] == 'Default' and 'shell_delete' not in default_cookie,
            'context': app.page(default_page)['context'], 'isolated': 'shell_delete' not in default_cookie}
        app.call('close', tab=default_page)
        state(profile='Shell Loaded', action='open-url', url=url)
        session = page_ready(url)
        old_cookie = app.call('little-open-eval', id=session['id'], js='document.cookie')
        show('Shell Loaded')
        press('Delete Profile')
        assert wait(lambda: state()['sheet'] > 0, timeout=5), state()
        if os.environ.get('OPEN_PROFILES_SHELL_FORCE_DIALOG_FAILURE') == '1':
            raise AssertionError('intentional early dialog failure for cleanup proof')
        app.call('key', window=state()['sheet'], key='escape', route='app')
        assert wait(lambda: state()['sheet'] == 0, timeout=5), state()
        press('Delete Profile')
        assert wait(lambda: state()['sheet'] > 0, timeout=5), state()
        state(action='type-delete', text='shell loaded')
        app.call('key', window=state()['sheet'], key='return', route='app')
        wrong = state()
        results['shell_delete_exact_name'] = {'ok': not wrong['deleteEnabled'] and wrong['deleteAXEnabled'] is False,
                                              'draft': wrong['deleteText'], 'nativeEnabled': wrong['deleteAXEnabled']}
        state(action='type-delete', text='Shell Loaded')
        right = state()
        assert right['deleteAXEnabled'] is True and right['deleteEnabled'], right
        app.call('key', window=state()['sheet'], key='return', route='app')
        submitted = wait(lambda: not any(p['id'] == loaded['id'] for p in state()['profiles']) and not state()['deleting'], timeout=15)
        results['shell_delete_return'] = {'ok': bool(submitted)}
        if not submitted:
            # Keep gathering disk evidence, while the Return row still fails.
            press('Delete')
            assert wait(lambda: not any(p['id'] == loaded['id'] for p in state()['profiles']) and not state()['deleting'], timeout=15), state()
        gone = state()
        app.call('key', window=gone['settings'], key='z', modifiers=['cmd'], route='app')
        pending = root / 'Profiles/.pending-wipe.json'
        durable = json.loads(snapshot.read_text())
        results['shell_delete_loaded_immediate'] = {
            'ok': 'shell_delete=old' in old_cookie and 'Shell Loaded' not in gone['rows']
                  and not any(p['id'] == loaded['id'] for p in state()['profiles']) and not gone['canUndo']
                  and not (root / 'Profiles' / old_directory).exists() and not old_engine.exists()
                  and not (Path.home() / 'Library/Caches' / root.name / 'Engine' / old_directory).exists()
                  and (not pending.exists() or old_directory not in json.loads(pending.read_text()))
                  and old_directory not in json.loads((root / 'Engine/Local State').read_text()).get('profile', {}).get('info_cache', {})
                  and not any(p['id'] == loaded['id'] for p in durable['profiles']),
            'modelGone': 'Shell Loaded' not in gone['rows'], 'canUndo': gone['canUndo'],
            'openFilesGone': not (root / 'Profiles' / old_directory).exists(), 'engineGone': not old_engine.exists(),
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
                  and 'Shell Never Loaded' not in gone['rows'], 'engineGone': not engine.exists(), 'cacheGone': not cache.exists(),
            'profileGone': not (root / 'Profiles' / never['directory']).exists(),
            'modelGone': 'Shell Never Loaded' not in gone['rows'], 'error': gone.get('error')}

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
        app.call('library-open')
        manager = app.call('space-manager-state')
        # LEAD16:35: cards omit Profile indicators by design. Read each
        # realised Space's model association and exercise its native card menu.
        cards = state()['managerProfiles']
        spaces = {s['id']: s['profile'] for s in app.call('spaces')}
        menus = {card['space']: state(action='indicator-menu', library=True, space=card['space'])['indicatorMenu'] for card in cards}
        names = [card['name'] for card in cards]
        results['shell_manager_indicators'] = {
            'ok': len(cards) == len(spaces) and {c['space']: c['profile'] for c in cards} == spaces
                  and all(c['owner'] == manager['contextWindow'] for c in cards)
                  and 'Default' in names and 'Shell Assigned' in names
                  and all(all(name in choices for name in ('Default', 'Shell Assigned', 'New Profile…')) for choices in menus.values()),
            'profiles': cards, 'menus': menus, 'source': 'Space model and card More options → Set Profile'}
        for appearance in ('light', 'dark'):
            app.call('appearance', name=appearance)
            capture_native('manager-' + appearance, window=manager['window'])
        app.call('key', window=manager['window'], key='w', modifiers=['cmd'], route='app')
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
            interrupted = 'Interrupted-Wipe'
            interrupted_paths = [root / 'Profiles' / interrupted, root / 'Engine' / interrupted,
                                 Path.home() / 'Library/Caches' / root.name / 'Engine' / interrupted]
            for folder in interrupted_paths:
                folder.mkdir(parents=True, exist_ok=True)
                (folder / 'synthetic-marker').write_text('interrupted cleanup fixture')
            interrupted_state = json.loads(original_local_state)
            interrupted_profile = interrupted_state.setdefault('profile', {})
            interrupted_profile.setdefault('info_cache', {})[interrupted] = {'name': 'Synthetic'}
            interrupted_profile['last_used'] = interrupted
            interrupted_profile['last_active_profiles'] = [interrupted, 'Default']
            early('interrupted-wipe', json.dumps([interrupted]).encode(), json.dumps(interrupted_state).encode())
            cleaned = json.loads(local_state.read_bytes())['profile']
            boundary[-1]['cleanupComplete'] = (all(not folder.exists() for folder in interrupted_paths)
                and interrupted not in cleaned.get('info_cache', {}) and cleaned.get('last_used') == 'Default'
                and cleaned.get('last_active_profiles') == ['Default'] and not pending.exists())
            early('journal-at-64KiB', b'[]' + b' ' * (65536 - 2))
            early('journal-over-64KiB', b'[]' + b' ' * (65537 - 2), expected=1)
            early('names-at-1024', json.dumps(['P%04d' % n for n in range(1024)]).encode())
            early('names-over-1024', json.dumps(['P%04d' % n for n in range(1025)]).encode(), expected=1)
            early('name-at-255', json.dumps(['P' * 255]).encode())
            early('name-over-255', json.dumps(['P' * 256]).encode(), expected=1)
            for label, value in [('default', ['Default']), ('path', ['../Default']), ('duplicate', ['A', 'A'])]:
                early(label, json.dumps(value).encode(), expected=1)
            early('trailing-JSON', b'["P"] {}', expected=1)
            early('local-state-trailing-JSON', b'["P"]', original_local_state + b' {}', expected=1)
            # Real launch parser, not an isolated JSON helper. Each allocation is bounded.
            small = json.dumps({'profile': {}, 'padding': ''}, separators=(',', ':')).encode()
            at_limit = small.replace(b'"padding":""', b'"padding":"' + b'x' * (16777216 - len(small)) + b'"')
            early('local-state-at-16MiB', b'["P"]', at_limit)
            early('local-state-over-16MiB', b'["P"]', at_limit + b' ', expected=1)
        finally:
            local_state.write_bytes(original_local_state)
            if pending.exists():
                pending.unlink()
        results['shell_cleanup_input_bounds'] = {'ok': all(row['exit'] == row['expected'] and row.get('cleanupComplete', True) for row in boundary), 'rows': boundary}
    finally:
        if app is not None:
            if not app.closed:
                try:
                    app.call('library-close', timeout=3)
                    app.call('profiles-shell', action='cancel', timeout=3)
                    app.call('profiles-shell', action='notice-ok', timeout=3)
                except Exception:
                    pass
            restore(app, saved)
            app.quit()
            results['shell_owned_window_cleanup'] = {'ok': app.quit_report.get('ok', False), 'quit': app.quit_report}
        server.shutdown()
        server.server_close()
