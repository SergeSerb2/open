"""Real-App Section 10 profile engine acceptance, invoked by --only profiles."""
import http.server
import json
import os
from pathlib import Path
import re
import threading
import time
from loopback_http import LoopbackHTTPServer


def run(factory, results, tmp, config, new_tab, wait_until):
    counts = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            counts[self.path] = counts.get(self.path, 0) + 1
            body = b'<!doctype html><title>Section 10 profile fixture</title><p>Profile data</p>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'public, max-age=86400')
            self.end_headers()
            self.wfile.write(body)

    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    base = 'http://127.0.0.1:%d/' % port
    private_host = 'private-section10.localhost'
    private_url = 'http://%s:%d/private' % (private_host, port)
    app = None
    private_keys = set()

    def private(name, key, url=base):
        def create():
            try:
                return app.call('profile-engine', action='private-open', profile=name, key=key, url=url)
            except RuntimeError as error:
                # The old primary OTR may still await renderer destruction.
                if 'unavailable' not in str(error):
                    raise
                return None
        info = wait_until(create, timeout=20, step=.2)
        if not info:
            raise RuntimeError('private session did not become available')
        private_keys.add(key)
        page = wait_until(lambda: app.call('profile-engine', action='state').get(key, {}).get('page') or None,
                          timeout=20)
        app.call('wait', tab=page)
        info['page'] = page
        return info

    def close(key):
        app.call('profile-engine', action='close', key=key)
        private_keys.discard(key)

    def data(page):
        # Switching a Space can retire its hidden page. The tab UUID reopens
        # it through the product host factory; wait for that real navigation.
        app.call('wait', tab=page)
        return app.eval(page, '({cookie:document.cookie,storage:localStorage.getItem("s10")})')

    def shutdown_receipt(instance, deadline):
        instance.quit()
        text = Path(instance.launch_log_path).read_text(errors='replace')
        matches = re.findall(r'shutdown contexts=(\d+) inert=(\d+) deadline=(\d+) deadlineSeconds=3', text)
        row = matches[-1] if matches else None
        return {'ok': bool(row) and int(row[0]) >= 3 and row[0] == row[1]
                      and int(row[2]) == deadline and instance.quit_report.get('ok')
                      and not instance.quit_report.get('forced'),
                'context_counts': row, 'quit': instance.quit_report}

    try:
        app = factory(urls=(), fresh=True)
        root = Path(app.user_data)
        crash_root = Path.home() / 'Library/Logs/DiagnosticReports'
        crashes_before = set(crash_root.glob('Open-*.ips'))
        default = new_tab(app, base)
        app.eval(default, 'document.cookie="s10_disk_default=1;max-age=86400";1')
        home = next(s['id'] for s in app.call('spaces') if s['focused'])
        work = app.call('space-create', title='Engine Work', profile='Engine Work')
        disk = new_tab(app, base)
        work_dir = app.page(disk)['context']
        app.eval(disk, 'document.cookie="s10_disk_work=1;max-age=86400";localStorage.setItem("s10","disk");1')
        if os.environ.get('OPEN_PROFILES_ENGINE_NEGATIVE') == 'retained-page':
            error = ''
            try:
                app.call('profile-engine', action='delete', profile='Engine Work')
            except RuntimeError as failure:
                error = str(failure)
            results['s10_delete_retained_native_page'] = {
                'ok': 'profile-keep-alive-held:' in error
                      and (root / 'Engine' / work_dir).is_dir()
                      and (root / 'Profiles' / work_dir).is_dir(),
                'error': error, 'engine_files_intact': (root / 'Engine' / work_dir).is_dir(),
                'open_files_intact': (root / 'Profiles' / work_dir).is_dir()}
            return
        first = private('Engine Work', 'work1')
        no_seed = data(first['page'])
        app.eval(first['page'], 'document.cookie="s10_private_work=1";localStorage.setItem("s10","private");1')
        second = private('Engine Work', 'work2')
        other = private('Default', 'default')
        shared = data(second['page'])
        isolated = [data(p) for p in (disk, default, other['page'])]
        results['s10_private_ancestry'] = {
            'ok': first['parent'] == work_dir and other['parent'] == 'Default'
                  and first['context'] == second['context'] != other['context']
                  and 's10_private_work=1' in shared['cookie']
                  and all('s10_private_work' not in d['cookie'] for d in isolated),
            'contexts': [first, second, other], 'shared': shared, 'other_contexts': isolated}
        results['s10_private_no_seeding'] = {
            'ok': not no_seed['cookie'] and no_seed['storage'] is None, 'initial': no_seed}
        if os.environ.get('OPEN_PROFILES_ENGINE_NEGATIVE') == 'parent':
            return
        try:
            app.call('profile-engine', action='delete', profile='Default')
            default_refused = False
        except RuntimeError:
            default_refused = True
        try:
            app.call('profile-engine', action='clear', profile='Engine Work', kinds=0)
            invalid_clear_refused = False
        except RuntimeError:
            invalid_clear_refused = True
        results['s10_invalid_operations_refused'] = {
            'ok': default_refused and invalid_clear_refused
                  and 's10_disk_work=1' in data(disk)['cookie'],
            'default_delete': default_refused, 'empty_clear': invalid_clear_refused}
        close('work1')
        still_shared = data(second['page'])
        close('work2')
        wait_until(lambda: not any(p.get('live') and p.get('context') == first['context']
                                   for p in app.call('pages')), timeout=15)
        # The native destroyer can still be waiting for its renderer host.
        def fresh_private():
            try:
                return private('Engine Work', 'work3')
            except RuntimeError as error:
                if 'unavailable' not in str(error):
                    raise
                return None
        fresh = wait_until(fresh_private, timeout=20, step=.2)
        fresh_data = data(fresh['page'])
        results['s10_private_session_end'] = {
            'ok': 's10_private_work=1' in still_shared['cookie']
                  and fresh['context'] != first['context'] and not fresh_data['cookie']
                  and fresh_data['storage'] is None,
            'remaining_window': still_shared, 'fresh': fresh_data}

        # Chrome's incognito opt-in, with a real spanning content script and MV3 worker.
        wait_until(lambda: any(e['name'] == 'Section 10 profile probe'
                               for e in app.call('extensions')['installed']), timeout=30)
        extension = next(e['id'] for e in app.call('extensions')['installed']
                         if e['name'] == 'Section 10 profile probe')
        before_allow = app.eval(fresh['page'], 'document.documentElement.dataset.s10Extension || ""')
        management = new_tab(app, 'chrome://extensions')
        wait_until(lambda: app.eval(management, 'typeof chrome.developerPrivate') == 'object', timeout=20)
        # Chrome reloads a command-line fixture as an unpacked extension when
        # access changes. That developer fixture requires developer mode.
        developer_mode = app.eval(management, 'new Promise(done=>chrome.developerPrivate.updateProfileConfiguration('
                                  '{inDeveloperMode:true},()=>done(!chrome.runtime.lastError)))')
        grant = app.eval(management, 'new Promise(done=>chrome.developerPrivate.updateExtensionConfiguration('
                         '{extensionId:%s,incognitoAccess:true},()=>done(chrome.runtime.lastError?'
                         'chrome.runtime.lastError.message:"ok")))' % json.dumps(extension))
        app.call('close', tab=management)
        # The opt-in reloads the extension. Its content-script file loader is
        # asynchronous; observe a fresh regular document before private load.
        app.call('navigate', tab=disk, url=base + '?extension-ready=1')
        app.call('wait', tab=disk)
        regular_ready = wait_until(lambda: app.eval(disk, 'document.documentElement.dataset.s10Extension || ""')
                                   == 'regular', timeout=20)
        close('work3')
        fresh = private('Engine Work', 'work3', base + '?allowed=1')
        ran = wait_until(lambda: app.eval(fresh['page'], 'document.documentElement.dataset.s10Extension || ""')
                         == 'private', timeout=20)
        after_allow = app.eval(fresh['page'], 'document.documentElement.dataset.s10Extension || ""')
        worker = wait_until(lambda: app.eval(disk, 'document.documentElement.dataset.s10Worker || ""') == 'live', timeout=20)
        results['s10_private_extension_opt_in'] = {
            'ok': developer_mode is True and before_allow == '' and grant == 'ok' and bool(ran) and bool(worker),
            'before': before_allow, 'after': after_allow, 'grant': grant,
            'regular_after_grant': bool(regular_ready),
            'spanning_script': bool(ran), 'mv3_worker': bool(worker)}

        # Page JS creates real timestamps on each side of begin. No clock,
        # CDP cookie mutation, or Open-side timestamp filtering participates.
        for label in ('bounded_range', 'all_time'):
            app.call('profile-engine', action='clear', profile='Engine Work', kinds=2)
            old_storage = new_tab(app, 'http://old-%s-storage.localhost:%d/' % (label, port))
            app.eval(old_storage, 'localStorage.setItem("s10","old");1')
            app.eval(disk, 'document.cookie="s10_old=1;max-age=86400";1')
            # Chromium normally commits localStorage metadata after five seconds.
            time.sleep(6)
            boundary = time.time()
            time.sleep(.5)
            new_storage = new_tab(app, 'http://new-%s-storage.localhost:%d/' % (label, port))
            app.eval(new_storage, 'localStorage.setItem("s10","new");1')
            app.eval(disk, 'document.cookie="s10_new=1;max-age=86400";1')
            time.sleep(6)
            end = time.time()
            begin = boundary if label == 'bounded_range' else -62135596800
            app.call('profile-engine', action='clear', profile='Engine Work', kinds=2, begin=begin, end=end)
            got = data(disk)
            other_cookie = data(default)['cookie']
            # Reopen the documents to observe the backend result independently
            # of renderer-local StorageArea caches and queued storage events.
            values = []
            for page in (old_storage, new_storage):
                app.call('navigate', tab=page, url=app.page(page)['url'])
                app.call('wait', tab=page)
                values.append(app.eval(page, 'localStorage.getItem("s10")'))
            old_value, new_value = values
            preserved = label == 'bounded_range'
            results['s10_clear_' + label] = {
                'ok': ('s10_old=1' in got['cookie']) == preserved and 's10_new' not in got['cookie']
                      and 's10_disk_default=1' in other_cookie
                      and old_value == ('old' if preserved else None) and new_value is None,
                'contract': 'Chromium inclusive end; no Open filtering',
                'work': got, 'default': other_cookie,
                'before_begin_storage': old_value, 'after_begin_storage': new_value}
            for page in (old_storage, new_storage):
                app.call('close', tab=page)
        app.call('profile-engine', action='clear', profile='Engine Work', kinds=2)
        results['s10_clear_site_data'] = {'ok': data(disk) == {'cookie': '', 'storage': None}, 'after': data(disk)}
        app.eval(disk, 'fetch("/cached").then(r=>r.text())')
        before_cache = counts.get('/cached', 0)
        app.eval(disk, 'fetch("/cached").then(r=>r.text())')
        cached_count = counts.get('/cached', 0)
        app.call('space', space=home); app.call('select', tab=default); app.call('wait', tab=default)
        app.eval(default, 'fetch("/cached").then(r=>r.text())')
        primed_count = counts.get('/cached', 0)
        app.call('profile-engine', action='clear', profile='Engine Work', kinds=4)
        app.call('space', space=work); app.call('select', tab=disk); app.call('wait', tab=disk)
        app.eval(disk, 'fetch("/cached").then(r=>r.text())')
        cleared_count = counts.get('/cached', 0)
        app.call('space', space=home); app.call('select', tab=default); app.call('wait', tab=default)
        app.eval(default, 'fetch("/cached").then(r=>r.text())')
        results['s10_clear_http_cache'] = {
            'ok': before_cache == cached_count and primed_count == cached_count + 1
                  and cleared_count == primed_count + 1 and counts.get('/cached', 0) == cleared_count,
            'requests': [before_cache, cached_count, primed_count, cleared_count, counts.get('/cached', 0)]}

        # The App's Settings adapter supplies real Last hour / All time ranges.
        app.call('space', space=work); app.call('select', tab=disk); app.call('wait', tab=disk)
        for label, interval in [('last_hour', 'Last hour'), ('all_time', 'All time')]:
            settings_url = 'http://settings-%s.localhost:%d/' % (label.replace('_', '-'), port)
            app.call('navigate', tab=disk, url=settings_url); app.call('wait', tab=disk)
            app.eval(disk, 'document.cookie="s10_settings=1;max-age=86400";localStorage.setItem("s10","settings");1')
            # Chromium batches localStorage metadata commits for five seconds.
            # Capture Settings' end=now only after the real write commits.
            time.sleep(6)
            app.call('profile-engine', action='settings-clear', profile='Engine Work', kinds=2, range=interval)
            app.call('navigate', tab=disk, url=settings_url + '?cleared=1'); app.call('wait', tab=disk)
            after = data(disk)
            results['s10_settings_' + label] = {
                'ok': after == {'cookie': '', 'storage': None}
                      and 's10_disk_default=1' in data(default)['cookie'], 'after': after}
        created = app.call('profiles-shell', action='create', name='History Only')
        unused = next(p for p in created['profiles'] if p['name'] == 'History Only')
        cleared = app.call('profile-engine', action='settings-clear', profile='History Only', kinds=1, range='Last hour')
        results['s10_history_only_stays_lazy'] = {
            'ok': cleared['contextsBefore'] == cleared['contextsAfter']
                  and not (root / 'Engine' / unused['directory']).exists(), 'contexts': cleared}

        # Delete with a live regular page, worker and primary OTR child.
        app.call('space', space=work); app.call('select', tab=disk); app.call('wait', tab=disk)
        app.call('navigate', tab=disk, url=base + '?delete-worker=1')
        app.call('wait', tab=disk)
        worker_before_delete = bool(wait_until(
            lambda: app.eval(disk, 'document.documentElement.dataset.s10Worker || ""') == 'live', timeout=20))
        private_before_delete = app.call('profile-engine', action='state').get('work3', {}).get('live', False)
        deletion = app.call('profile-engine', action='delete', profile='Engine Work', coalesce=True)
        private_after_delete = app.call('profile-engine', action='state').get('work3', {})
        for key in ('work3',):
            close(key)
        deleted = root / 'Engine' / work_dir
        cache_root = Path.home() / 'Library/Caches' / root.name / 'Engine' / work_dir
        stable = True
        until = time.monotonic() + 30
        while time.monotonic() < until:
            stable = stable and not deleted.exists() and not cache_root.exists()
            time.sleep(.5)
        local_state = json.loads((root / 'Engine/Local State').read_text())
        attrs = local_state.get('profile', {})
        results['s10_delete_loaded_profile'] = {
            'ok': worker_before_delete and private_before_delete
                  and private_after_delete.get('closed') and not private_after_delete.get('live')
                  and deletion['closed'] and deletion['extensionsClosed'] and deletion['completions'] == 2
                  and stable and work_dir not in attrs.get('info_cache', {})
                  and work_dir not in attrs.get('last_active_profiles', [])
                  and attrs.get('last_used') != work_dir,
            'completion': deletion, 'stable_30_seconds': stable,
            'worker_live_before_delete': worker_before_delete, 'private_live_before_delete': private_before_delete,
            'private_after_delete': private_after_delete,
            'attributes_removed': work_dir not in attrs.get('info_cache', {})}
        try:
            app.call('profile-engine', action='private-open', profile='Engine Work', key='rejected', url=base)
            refused = False
        except RuntimeError:
            refused = True
        try:
            app.call('profile-engine', action='clear', profile='Engine Work', kinds=2)
            closed_clear_refused = False
        except RuntimeError:
            closed_clear_refused = True
        results['s10_deleted_parent_refused'] = {'ok': refused and closed_clear_refused,
                                                'private_factory': refused, 'clear': closed_clear_refused}
        app.call('space', space=home)
        app.call('select', tab=default)
        app.call('navigate', tab=default, url=base + '?survived=1')
        app.call('wait', tab=default)
        results['s10_other_profile_survives'] = {'ok': app.eval(default, 'document.title') == 'Section 10 profile fixture'}
        close('default')

        # Private synthetic host never enters the shell's durable stores.
        def installation_files():
            profiles = set(json.loads((root / 'Engine/Local State').read_text())
                           .get('profile', {}).get('info_cache', {})) | {'Default'}
            snapshot = {}
            for path in (root / 'Engine').rglob('*'):
                relative = path.relative_to(root / 'Engine')
                if relative.parts[0] in profiles or path.is_symlink():
                    continue
                try:
                    if path.is_file():
                        stat = path.stat()
                        snapshot[str(relative)] = (stat.st_size, stat.st_mtime_ns)
                except FileNotFoundError:
                    # Chromium can replace an installation-wide temp file
                    # while this live snapshot is being collected.
                    continue
            return snapshot
        installation_before = installation_files()
        disk_proof = private('Default', 'disk-proof', private_url)
        private_navigated = app.eval(disk_proof['page'], 'location.hostname') == private_host
        private_navigated = private_navigated and counts.get('/private', 0) > 0
        close('disk-proof')
        app.call('space-create', title='Quit Work', profile='Quit Work')
        new_tab(app, base + '?quit=1')
        private('Default', 'quit-private', base)
        results['s10_quit_normal'] = shutdown_receipt(app, 0)
        app = None
        forbidden = private_host.encode()
        matches = []
        for folder in [root / 'Engine', root / 'Profiles', root / 'State',
                       Path.home() / 'Library/Caches' / root.name]:
            if folder.exists():
                for path in folder.rglob('*'):
                    if path.is_file() and not path.is_symlink():
                        with path.open('rb') as stream:
                            tail = b''
                            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                                joined = tail + chunk
                                if forbidden in joined:
                                    matches.append(str(path.relative_to(folder)))
                                    break
                                tail = joined[-len(forbidden):]
        installation_after = installation_files()
        changed = sorted(p for p in installation_before.keys() | installation_after.keys()
                         if installation_before.get(p) != installation_after.get(p))
        results['s10_private_disk_records'] = {'ok': private_navigated and not matches,
                                              'private_navigation': private_navigated, 'matching_files': matches,
                                              'installation_wide_changed': changed}
        crashes_after = set(crash_root.glob('Open-*.ips'))
        results['s10_quit_contexts'] = {'ok': not (crashes_after - crashes_before),
                                      'new_crash_reports': len(crashes_after - crashes_before)}
        # Relaunch the saved model after the loaded-Profile delete.
        app = factory(urls=())
        restored = new_tab(app, base + '?relaunch=1')
        results['s10_delete_relaunch'] = {
            'ok': not deleted.exists() and not cache_root.exists()
                  and app.eval(restored, 'document.title') == 'Section 10 profile fixture'}
        app.quit()
        app = factory(urls=(), fresh=True, extra_env={'OPEN_AUTOMATION_QUIT_AT_DEADLINE': '1'})
        new_tab(app, base)
        app.call('space-create', title='Deadline Work', profile='Deadline Work')
        new_tab(app, base + '?deadline=1')
        private('Deadline Work', 'deadline-private')
        results['s10_quit_deadline'] = shutdown_receipt(app, 1)
        app = None
        app = factory(urls=(), fresh=True, extra_args=[
            '--disable-features=DisableLoadExtensionCommandLineSwitch,DestroyProfileOnBrowserClose'])
        new_tab(app, base)
        app.call('space-create', title='Unload Disabled', profile='Unload Disabled')
        blocked_page = new_tab(app, base + '?disabled=1')
        blocked_dir = app.page(blocked_page)['context']
        error = ''
        try:
            app.call('profile-engine', action='delete', profile='Unload Disabled')
        except RuntimeError as failure:
            error = str(failure)
        results['s10_delete_feature_disabled'] = {
            'ok': 'profile-unload-feature-disabled' in error
                  and (root / 'Engine' / blocked_dir).is_dir()
                  and (root / 'Profiles' / blocked_dir).is_dir(),
            'error': error, 'engine_files_intact': (root / 'Engine' / blocked_dir).is_dir()}
        app.quit()
        app = None
        final_crashes = set(crash_root.glob('Open-*.ips'))
        results['s10_all_launches_no_crash'] = {'ok': not (final_crashes - crashes_before),
                                              'new_crash_reports': len(final_crashes - crashes_before)}
    finally:
        if app:
            for key in list(private_keys):
                try:
                    close(key)
                except (RuntimeError, OSError):
                    pass
            app.quit()
        server.shutdown()
        server.server_close()
