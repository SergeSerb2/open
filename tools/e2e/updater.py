#!/usr/bin/env python3 -I
"""Real-App updater checks. Hold the on-screen lock; never install an update.

Only disposable app copies are re-signed. Keys stay in TMPDIR, never Keychain.
--force-failure proves cleanup with Sparkle's actual update window still open.
--main-bundle runs an interleaved Release launch comparison instead (quiet lock).
"""
import argparse
import base64
import datetime
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from loopback_http import LoopbackHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine_e2e as harness
from restore_defaults import write_collection

DOMAIN = 'io.github.sergeserb2.open'
OPEN_KEYS = {'open.general.automaticallyUpdate', 'open.general.updateChannel',
             'open.debug.updateFeedURL', 'open.settings.lastPane', 'OPEN_UPDATER_ALLOW_ADHOC',
             'open.links.openPeekShiftClick', 'open.links.openPeekOtherSites',
             'open.links.littleOpenNUXSeen', 'open.general.searchSuggestNoticeDismissed',
             'NSWindow Frame SUUpdateAlert2', 'open.updates.lastInstalledBuild',
             'open.updates.summaryShownBuild', 'open.updates.bannerDismissalCount',
             'open.general.warnBeforeQuitting',
             'open.sidebar.autoArchiveBannerEligible', 'open.sidebar.autoArchiveBannerDismissed'}
FIXTURE = 'data:text/html,<title>Updater fixture</title><h1>Updater fixture</h1>'


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def domain():
    result = subprocess.run(['defaults', 'export', __import__('prefs_domain').domain(), '-'], capture_output=True)
    return plistlib.loads(result.stdout) if result.returncode == 0 else {}


def write(key, value):
    if value is None:
        subprocess.run(['defaults', 'delete', __import__('prefs_domain').domain(), key], capture_output=True, check=False)
    else:
        # The existing CFPreferences helper preserves plist types, including dates.
        write_collection(key, value)


def restore(saved):
    for key in set(saved) | set(domain()):
        if key in OPEN_KEYS or key.startswith('SU'):
            write(key, saved.get(key))


def wait(read, accept, message):
    end = time.monotonic() + 15
    while True:
        value = read()
        if accept(value):
            return value
        if time.monotonic() >= end:
            raise AssertionError(message + ': ' + repr(value))
        time.sleep(.05)


def make_feed(folder, tools, openssl, origin):
    private = folder / 'throwaway.pem'
    subprocess.run([openssl, 'genpkey', '-algorithm', 'ed25519', '-out', str(private)], check=True, capture_output=True)
    os.chmod(private, 0o600)
    seed_der = subprocess.check_output([openssl, 'pkey', '-in', str(private), '-outform', 'DER'])
    public_der = subprocess.check_output([openssl, 'pkey', '-in', str(private), '-pubout', '-outform', 'DER'])
    assert seed_der[:16].hex() == '302e020100300506032b657004220420' and len(seed_der) == 48
    assert public_der[:12].hex() == '302a300506032b6570032100' and len(public_der) == 44
    key = folder / 'throwaway.key'
    key.write_bytes(base64.b64encode(seed_der[-32:]))
    os.chmod(key, 0o600)
    # A valid disposable update bundle lets the real installer prepare. It is
    # never launched or installed: either Skip cancels it, or R2 pauses its
    # owned installer before the host can exit and kills it without resuming.
    fixture = folder / 'payload' / 'Open.app'
    executable = fixture / 'Contents/MacOS/Open'
    executable.parent.mkdir(parents=True)
    shutil.copyfile('/usr/bin/true', executable)
    executable.chmod(0o755)
    (fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': DOMAIN, 'CFBundleName': 'Open', 'CFBundleExecutable': 'Open',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '900001', 'CFBundleShortVersionString': '99.0',
        'SUPublicEDKey': base64.b64encode(public_der[-32:]).decode()}))
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(fixture)],
                   check=True, capture_output=True)
    archive = folder / 'Open-fixture.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as zipped:
        for path in fixture.rglob('*'):
            if path.is_file():
                zipped.write(path, path.relative_to(fixture.parent))
        zipped.writestr('padding.bin', os.urandom(256 * 1024))
    signing = [str(tools / 'sign_update'), '--ed-key-file', str(key)]
    attributes = subprocess.check_output(signing + [str(archive)], text=True).strip()
    items = []
    for version, channel in [('900001', ''), ('900002', '<sparkle:channel>beta</sparkle:channel>')]:
        items.append(f'''<item><title>Open updater fixture {version}</title>
          <sparkle:version>{version}</sparkle:version><sparkle:shortVersionString>99.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>{channel}
          <description sparkle:format="markdown"><![CDATA[# Local release notes
**Faster tabs** and [Open updates](https://github.com/SergeSerb2/open#updates).]]></description>
          <enclosure url="{origin}/Open-fixture.zip" {attributes} type="application/octet-stream"/>
          </item>''')
    feed = folder / 'appcast.xml'
    feed.write_text('''<?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><title>Open updater fixture</title>''' + ''.join(items) + '</channel></rss>')
    subprocess.run(signing + [str(feed)], check=True, capture_output=True)
    return base64.b64encode(public_der[-32:]).decode(), feed


def run(opts, folder, results, apps):
    saved = domain()
    for key in set(saved) | OPEN_KEYS:
        if key in OPEN_KEYS or key.startswith('SU'):
            write(key, None)
    app_root = Path.home() / 'Library/Application Support' / ('Open-E2E-updater-' + str(os.getpid()))
    caches = Path.home() / 'Library/Caches' / app_root.name
    tracker = results.tracker
    try:
        def launch(bundle, allow='0', fresh=True):
            if fresh:
                shutil.rmtree(app_root, ignore_errors=True)
                shutil.rmtree(caches, ignore_errors=True)
            app = harness.Open(opts.config, 'chrome', str(app_root), ['--use-mock-keychain'],
                str(folder / 'open.log'), urls=(FIXTURE,), extra_env={
                    'OPEN_E2E_APP_BUNDLE': str(bundle), 'OPEN_UPDATER_ALLOW_ADHOC': allow})
            apps.append(app)
            app.focus_tracker = tracker; tracker.apps.append(app)
            app.call('wait', tab=app.call('tabs')[0]['id'])
            return app

        if opts.main_bundle:
            assert opts.config == 'Release', 'Launch comparison requires Release builds with automation'
            engine = Path('Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework')
            fingerprints = {label: {'binarySHA256': file_sha256(bundle / 'Contents/MacOS/Open'),
                'engineSHA256': file_sha256(bundle / engine)}
                for label, bundle in [('main', opts.main_bundle), ('branch', opts.bundle)]}
            results['A10_same_engine'] = {'ok': fingerprints['main']['engineSHA256'] == fingerprints['branch']['engineSHA256'],
                'fingerprints': fingerprints}
            assert results['A10_same_engine']['ok'], 'A10 requires the same engine distribution in both bundles'
            samples = {'main': [], 'branch': []}
            for _ in range(3):
                for label, bundle in [('main', opts.main_bundle), ('branch', opts.bundle)]:
                    assert os.getloadavg()[0] <= 12, 'TANDEM launch timing requires load1 <= 12'
                    app = launch(bundle)
                    try:
                        timing = wait(lambda: app.call('timing'), lambda t: 'firstContentfulPaint' in t, 'no paint')
                        assert timing.get('kernelProcessStart') and timing.get('firstFrameConfirmed'), timing
                        # Let engine startup and the post-paint updater hook settle.
                        # This delay belongs only to the harness, never the App.
                        time.sleep(15)
                        samples[label].append({'timing': timing, 'idle': harness.process_cpu_window(app, seconds=30), 'load': os.getloadavg(),
                            'uptime': subprocess.check_output(['uptime'], text=True).strip()})
                    finally:
                        app.quit()
                    tracker.checkpoint()
            medians = {label: statistics.median(s['timing']['sidebarDrawn'] for s in values)
                       for label, values in samples.items()}
            results['interleaved_launch'] = {'ok': medians['branch'] <= medians['main'],
                'sidebarDrawnMedianMs': medians, 'samples': samples}
            idle = {label: statistics.median(s['idle']['total_cpu_percent'] for s in values) for label, values in samples.items()}
            results['A10_interleaved_idle'] = {'ok': idle['branch'] <= idle['main']
                and all(s['idle']['complete'] for values in samples.values() for s in values), 'medianCPUPercent': idle}
            return

        copied = folder / 'Open.app'
        subprocess.run(['cp', '-cRp', str(opts.bundle), str(copied)], check=True)
        info_path = copied / 'Contents/Info.plist'
        original = plistlib.loads(info_path.read_bytes())
        requests = []
        serve_fixture = False
        class Canary(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                if serve_fixture and self.path == '/download-failure.zip':
                    time.sleep(1)
                    self.send_response(503); self.end_headers(); return
                name = {'/appcast.xml': 'appcast.xml', '/Open-fixture.zip': 'Open-fixture.zip', '/NoApp.zip': 'NoApp.zip'}.get(self.path.split('?', 1)[0])
                if not serve_fixture or name is None:
                    self.send_response(404); self.end_headers(); return
                body = (folder / name).read_bytes()
                assert len(body) <= 2 * 1024 * 1024
                if name.endswith(".xml"):
                    time.sleep(.6)
                self.send_response(200)
                self.send_header('Content-Type', 'application/xml' if name.endswith('.xml') else 'application/zip')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                try:
                    for offset in range(0, len(body), 4096):
                        self.wfile.write(body[offset:offset + 4096]); self.wfile.flush()
                        if name.endswith('.zip'):
                            # Keep Cancel observable through both real-window captures.
                            time.sleep(.05)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def log_message(self, *_):
                pass
        server = LoopbackHTTPServer(Canary)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            origin = 'http://127.0.0.1:%d' % server.server_port
            public, feed = make_feed(folder, opts.tools, opts.openssl, origin)
            def configure(key, url):
                info = dict(original, SUPublicEDKey=key, SUFeedURL=url)
                info_path.write_bytes(plistlib.dumps(info))
                subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none',
                    '--preserve-metadata=entitlements', str(copied)], check=True, capture_output=True)
            if opts.windowless_only:
                serve_fixture = True
                exercise_windowless_alerts(opts, folder, results, launch, configure, public, origin)
                return
            canary = origin + '/appcast.xml'
            for label, key in [('placeholder', 'PASTE_PUBLIC_KEY_FROM_GENERATE_KEYS'),
                               ('invalid_base64', '!' * 44), ('short_key', base64.b64encode(b'x' * 31).decode()),
                               ('long_key', base64.b64encode(b'x' * 33).decode())]:
                configure(key, canary)
                write('open.debug.updateFeedURL', canary)
                app = launch(copied, allow='1')
                try:
                    state = wait(lambda: app.call('updater-state'), lambda s: s['created'], 'updater not created')
                    menu = [r for r in app.call('menu-state') if r['id'] == 'check-for-updates']
                    app.call('menu-perform', id='check-for-updates')
                    settings = app.call('settings-state')
                    # Give the post-start scheduler a full turn; no SPUUpdater exists.
                    time.sleep(.25)
                    results[label + '_fails_closed'] = {'ok': state['offReason'] == 'invalid-public-key'
                        and not state['started'] and not state['automaticallyChecks'] and not state['automaticallyDownloads']
                        and state['lastCheck'] is None and state['canCheck'] and not requests
                        and len(menu) == 1 and menu[0]['title'] == 'Check for Updates…' and menu[0]['enabled']
                        and settings['settingsVisible'] and settings['pane'] == 'general'
                        and settings['generalError'] == 'Updates are not set up in this build.',
                        'state': state, 'canaryRequests': len(requests)}
                    if label == 'placeholder':
                        settings_window = settings['settings']
                        app.call('key', key='w', modifiers=['cmd'], route='app', window=settings_window)
                        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
                        app.call('command', id='check-for-updates')
                        settings = app.call('settings-state')
                        results['command_dispatch_same_off_status'] = {'ok': settings['settingsVisible']
                            and settings['pane'] == 'general'
                            and settings['generalError'] == 'Updates are not set up in this build.'}
                finally:
                    app.quit()
                tracker.checkpoint()

            configure(public, canary)
            app = launch(copied)
            try:
                state = wait(lambda: app.call('updater-state'), lambda s: s['created'], 'updater not created')
                results['adhoc_fails_closed'] = {'ok': state['offReason'] == 'missing-team-identifier'
                    and not state['started'] and not requests, 'state': state, 'canaryRequests': len(requests)}
            finally:
                app.quit()
            tracker.checkpoint()

            configure(public, origin + '/must-not-request')
            serve_fixture = True
            if opts.review_only:
                configure(public, canary)
                exercise_review_regressions(opts, folder, results, launch, public, origin, original)
                return
            for channel, expected in [('stable', '900001'), ('beta', '900002')]:
                write('open.general.updateChannel', channel)
                write('open.general.automaticallyUpdate', None if channel == 'stable' else True)
                write('open.debug.updateFeedURL', canary)
                # Avoid a scheduled check competing with the manual check on startup.
                write('SULastCheckTime', datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None))
                # Cover both supported opt-in sources, without touching signing keys.
                if channel == 'beta':
                    write('OPEN_UPDATER_ALLOW_ADHOC', '1')
                app = launch(copied, allow='1' if channel == 'stable' else '0')
                try:
                    state = wait(lambda: app.call('updater-state'), lambda s: s['created'], 'updater not created')
                    assert state['started'], state
                    state = wait(lambda: app.call('updater-state'), lambda s: s['canCheck'], 'updater not ready for a manual check')
                    timing = app.call('timing')
                    results[channel + '_after_paint'] = {'ok': timing['updaterCreated'] >= timing['sidebarDrawn']
                        and timing['updaterCreated'] >= timing['firstContentfulPaint'], 'timing': timing}
                    results[channel + '_automatic_default'] = {'ok': state['automaticallyChecks']
                        and state['automaticallyDownloads'] and state['channel'] == channel, 'state': state}
                    app.call('menu-perform', id='check-for-updates')
                    if channel == 'stable':
                        checking = ui(app)
                        results['A2_checking'] = {'ok': checking.get('statusText') == 'Checking for updates...'
                            and checking.get('indeterminate') and 'Cancel' in ax(app, checking.get('statusWindow')).get('text', []), 'ui': checking}
                    found = wait(lambda: app.call('updater-state'), lambda s: s['foundVersion'] is not None, 'update not found')
                    windows = wait(lambda: app.call('windows', accessibility=True),
                        lambda rows: any(r['visible'] and r['title'] == 'Open Update' for r in rows),
                        'custom Open Update window missing')
                    results[channel + '_local_signed_feed'] = {'ok': found['foundVersion'] == expected
                        and found['lastCheck'] is not None and all(p in ('/appcast.xml', '/Open-fixture.zip') for p in requests),
                        'state': found, 'sparkleWindowTitles': [r['title'] for r in windows if r['visible']],
                        'loopbackRequests': len(requests)}
                    busy = app.call('updater-state')
                    menu = [r for r in app.call('menu-state') if r['id'] == 'check-for-updates']
                    # Sparkle allows this action to refocus its checking/update UI.
                    # canCheck is not a session-in-progress flag (SPUUpdater.h).
                    results[channel + '_menu_tracks_canCheck'] = {'ok': len(menu) == 1
                        and menu[0]['enabled'] and menu[0]['title'] == 'Update Available…' and menu[0].get('badgeCount') == 1, 'state': busy, 'menu': menu}
                    if opts.force_failure:
                        raise AssertionError('forced failure while custom update window is open')
                    if channel == 'stable':
                        exercise_ui(app, opts, results, original)
                    # Invoke General's toggle model and its real preference writer.
                    app.call('settings-pane', pane='general')
                    app.call('settings-toggle', name='updates')
                    off = wait(lambda: app.call('updater-state'),
                        lambda s: not s['automaticallyChecks'] and not s['automaticallyDownloads'], 'automatic flags stayed on')
                    results[channel + '_automatic_off_live'] = {'ok': off['started'] and not off['automaticPreference'], 'state': off}
                    app.call('settings-toggle', name='updates')
                    on = wait(lambda: app.call('updater-state'),
                        lambda s: s['automaticallyChecks'] and s['automaticallyDownloads'], 'automatic flags stayed off')
                    results[channel + '_automatic_on_live'] = {'ok': on['automaticPreference'], 'state': on}
                    if channel == 'stable':
                        settings = app.call('settings-state')
                        settings_ax = ax(app, settings['settings'])
                        # Settings' own navigation (2026-11-10): row title, its help link, and the
                        # sidebar footer button's accessibility label (SettingsNavigation.swift).
                        labels = ('Update Open automatically', 'Keep Open up to date.', 'Learn more', 'Check for Updates')
                        paths = capture_pair(app, opts, 'general', settings['settings'])
                        results['S8_general_rows'] = ({'ok': True, 'ax': settings_ax, 'paths': paths}
                            if all(t in settings_ax.get('text', []) for t in labels) else
                            {'ok': False, 'reason': 'General lacks an update row label: ' + ', '.join(t for t in labels if t not in settings_ax.get('text', [])),
                             'ax': settings_ax, 'paths': paths})
                        count = len(app.call('tabs'))
                        app.call('updater-act', action='settings-help')
                        tabs = app.call('tabs')
                        results['S8_help_tab'] = {'ok': len(tabs) == count + 1 and any(t.get('selected')
                            and t.get('section') == 'today' and t['url'] == 'https://github.com/SergeSerb2/open#updates' for t in tabs)}
                        close_updates(app)
                        app.call('updater-act', action='settings-check')
                        wait(lambda: ui(app), lambda s: s.get('updateWindow', 0) > 0, 'General check did not show updater')
                        results['S8_check_row'] = {'ok': ui(app).get('phase') == 'found'}
                finally:
                    close_updates(app)
                    app.quit()
                tracker.checkpoint()
            exercise_variants(opts, folder, results, launch, configure, public, origin, original)
            exercise_review_regressions(opts, folder, results, launch, public, origin, original)
            exercise_windowless_alerts(opts, folder, results, launch, configure, public, origin)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=5)
            results['loopback_server_stopped'] = {'ok': not thread.is_alive(), 'requests': requests}
    finally:
        for app in apps:
            app.quit()
        restore(saved)
        shutil.rmtree(app_root, ignore_errors=True); shutil.rmtree(caches, ignore_errors=True)
        current = domain()
        keys = {k for k in set(saved) | set(current) if k in OPEN_KEYS or k.startswith('SU')}
        results['defaults_restored'] = {'ok': all(saved.get(k) == current.get(k) for k in keys)}


def close_updates(app):
    try:
        if getattr(app, 'updater_needs_skip', False):
            wait(lambda: app.call('updater-state'), lambda s: s.get('canCheck') and not s.get('sessionInProgress'), 'resume did not settle')
            app.call('menu-perform', id='check-for-updates')
            wait(lambda: ui(app), lambda s: s.get('phase') == 'found', 'prepared update did not resume')
        app.call('updater-act', action='cleanup', timeout=3)
        wait(lambda: app.call('updater-state'), lambda s: s.get('canCheck') and not s.get('sessionInProgress')
            and all(s.get('ui', {}).get(k, 0) == 0 for k in ('statusWindow', 'updateWindow', 'alertWindow')),
            'Sparkle did not finish cancellation')
        app.updater_needs_skip = False
    except Exception as error:
        # Process/window cleanup still runs. Keep a separate failure receipt;
        # quitting alone must not hide an unacknowledged Sparkle operation.
        app.updater_cleanup_error = str(error)


def ui(app):
    return app.call('updater-state').get('ui', {})


def ax(app, number):
    return next((r for r in app.call('windows', accessibility=True) if r['number'] == number), {})


def exercise_windowless_alerts(opts, folder, results, launch, configure, public, origin):
    """Real menu checks and pending Sparkle replies after all browsers close."""
    for variant in ('error-ok', 'error-manual', 'restart-cancel'):
        url = origin + ('/appcast.xml' if variant == 'restart-cancel' else '/missing-feed.xml')
        configure(public, url)
        write('open.general.automaticallyUpdate', False)
        write('open.general.updateChannel', 'stable')
        write('open.debug.updateFeedURL', url)
        write('SULastCheckTime', datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None))
        for key in ('SUSkippedVersion', 'SUSkippedMajorVersion', 'SUSkippedMajorSubreleaseVersion'):
            write(key, None)
        app = launch(folder / 'Open.app', allow='1')
        armed = False
        try:
            before = wait(lambda: app.call('updater-state'), lambda s: s.get('started') and s.get('canCheck'), 'updater not ready')
            if variant == 'restart-cancel':
                app.call('updater-background-check')
                wait(lambda: ui(app), lambda s: s.get('phase') == 'found', 'background update not found')
                app.call('updater-act', action='primary')
                wait(lambda: ui(app), lambda s: s.get('phase') == 'ready', 'background update not ready')
                app.call('updater-act', action='dismiss-banner')
            button = 0 if variant == 'error-ok' else 1
            try:
                app.call('updater-modal-alert', action='arm', button=button)
                armed = True
            except RuntimeError as error:
                # The preserved pre-fix App has no modal observer. Its missing
                # alert must be the failed row, not an early harness exception.
                if 'unknown command' not in str(error):
                    raise
            for window in app.call('shell-windows'):
                app.call('window-close', window=window['id'])
            wait(lambda: app.call('shell-windows'), lambda rows: not rows, 'browser windows stayed open')
            app.call('menu-perform', id='check-for-updates', timeout=30)
            if variant != 'restart-cancel':
                settled = wait(lambda: app.call('updater-state'),
                    lambda s: not s.get('sessionInProgress') and s.get('canCheck'), 'error acknowledgement did not finish')
            else:
                settled = app.call('updater-state')
            events = app.call('updater-modal-alert') if armed else []
            event = events[0] if len(events) == 1 else {}
            after_ax = [row for row in app.call('windows', accessibility=True) if row.get('visible')]
            during = event.get('updaterBeforeAnswer', {})
            expected = ('Open is ready to update!', 'Restart required.', 'Restart', 'Cancel') if variant == 'restart-cancel' else (
                'Update error!', 'OK', 'Download manually')
            visible = all(text in event.get('text', []) for text in expected)
            if variant != 'restart-cancel':
                visible = visible and bool(event.get('informativeText')) and event['informativeText'] in event.get('text', [])
            native = (event.get('appModal') is True and event.get('active') is True
                and event.get('key') is True and event.get('visible') is True
                and event.get('sheet') is False and event.get('browserWindows') == 0
                and event.get('pressedButton') == button
                and len(event.get('buttons', [])) == 2 and all(b['enabled'] for b in event['buttons']))
            common = visible and native and during.get('sessionInProgress') is True and not settled['ui']['alertWindow']
            if variant == 'restart-cancel':
                pending = (settled['sessionInProgress'] and settled['ui']['phase'] == 'ready'
                    and settled['ui']['banner'] == '' and not app.call('shell-windows'))
                results['R5_windowless_restart_cancel'] = {'ok': common and pending, 'alertAX': event,
                    'pendingAfterCancel': settled, 'windowsAXAfter': after_ax, 'modalObserverAvailable': armed}
            else:
                acknowledged = (during.get('completedChecks') == before['completedChecks']
                    and settled['completedChecks'] == before['completedChecks'] + 1)
                if variant == 'error-manual' and event:
                    # The alert action opens the model tab before acknowledging.
                    # Record a wrong/missing destination as FAIL so the deliberate
                    # broken-UI run can finish every acceptance family.
                    tabs = app.call('tabs')
                    destination = len(app.call('shell-windows')) == 1 and any(t.get('selected') and t['url'] ==
                        'https://github.com/SergeSerb2/open/releases/latest' for t in tabs)
                else:
                    destination = not app.call('shell-windows')
                results['R4_windowless_' + variant] = {'ok': common and acknowledged and destination,
                    'alertAX': event, 'before': before, 'afterAnswer': settled, 'windowsAXAfter': after_ax,
                    'modalObserverAvailable': armed, 'browserWindowsAfter': app.call('shell-windows')}
        finally:
            try:
                if armed:
                    app.call('updater-modal-alert', action='disarm', timeout=3)
            finally:
                close_updates(app); app.quit()
        results.tracker.checkpoint()


TOAST_COPY = {
    'newUpdatePending': ('A new update is pending! It will be ready soon', None),
    'updateAlreadyInProgress': ('Update in progress. Hang tight!', None),
    'failedToDownloadUpdate': ('Something went wrong downloading the update to Open.', 'We’ll try again later…'),
    'failedToInstall': ('Something went wrong installing a new update.', 'We’ll try again later…'),
    'cancelledInstall': ('Restart at a later time to finish installing the new update!', None),
}


def toast_matches(app, kind):
    title, subtitle = TOAST_COPY[kind]
    return any(t.get('title') == title and t.get('subtitle') == subtitle
        for t in app.call('toasts')['toasts'])


def capture_pair(app, opts, name, number, results=None):
    folder = opts.output.parent.resolve() / 'snapshots'
    folder.mkdir(parents=True, exist_ok=True)
    captures = []
    for appearance in ('light', 'dark'):
        if 'banner' in name:
            browser = next(w for w in app.call('shell-windows') if w['number'] == number)
            app.call('window-focus', id=browser['id'], activate=True)
            wait(lambda: app.call('windows'),
                 lambda rows: any(w['number'] == number and w['key'] for w in rows),
                 'banner capture window is not key')
        app.call('appearance', name=appearance)
        if 'banner' in name:
            # Real-window review captures show the settled sidebar appearance.
            time.sleep(.3)
        path = folder / (name + '-' + appearance + '.png')
        capture = app.call('snapshot', window=number, path=str(path))
        assert capture['method'].startswith('windowserver'), capture
        captures.append(str(path))
        if results is not None and 'banner' in name:
            styles = app.call('updater-view-tree').get('bannerStyles', [])
            expected = [0, 0, 0, 140] if appearance == 'light' else [255, 255, 255, 179]
            results['S6_' + name + '_' + appearance + '_secondary_color'] = {
                'ok': bool(styles) and all(s.get('subtitleColor') == expected for s in styles),
                'styles': styles, 'expected': expected}
            title_height = 34 if name == 'available-banner-narrow' else 18
            card_height = 86 if name == 'available-banner-narrow' else 68
            results['S6_' + name + '_' + appearance + '_content_height'] = {
                'ok': bool(styles) and all(
                    s.get('titleFrame', [0, 0, 0, 0])[3] == title_height
                    and s.get('subtitleFrame', [0, 0])[1] == 12 + title_height + 4
                    and s.get('frame', [0, 0, 0, 0])[3] == card_height for s in styles),
                'styles': styles, 'expectedTitleHeight': title_height,
                'expectedCardHeight': card_height, 'expectedTitleSubtitleGap': 4}
    return captures


def exercise_ui(app, opts, results, original):
    state = ui(app)
    row = ax(app, state.get('updateWindow'))
    installed = original['CFBundleShortVersionString'] + ' (' + original['CFBundleVersion'] + ')'
    prompt = 'You have v' + installed + '.\nWould you like to download\n v99.0 (900001) now?'
    results['A3_has_update_notes'] = {'ok': prompt in row.get('text', [])
        and all(t in row.get('text', []) for t in ('Download', 'Remind me Later'))
        and '{692, 418}' in row.get('frame', '')
        and 'Faster tabs' in state.get('notes', '') and '**' not in state.get('notes', ''), 'ax': row, 'ui': state}
    results['A3_update_notes_snapshots'] = {'ok': True, 'paths': capture_pair(app, opts, 'has-update-notes', state['updateWindow'])}
    views = app.call('updater-view-tree')
    results['A9_no_web_views'] = {'ok': views['webViewCount'] == 0 and views['notesIsTextView']
        and views['notesViewClass'] == 'NSTextView', 'viewTree': views}
    app.call('updater-act', action='notes-link')
    results['D3_foreground_link'] = {'ok': any(t['url'] == 'https://github.com/SergeSerb2/open#updates'
        and t.get('selected') and t.get('section') == 'today' for t in app.call('tabs'))}
    app.call('updater-act', action='primary')
    checking = wait(lambda: ui(app), lambda s: s.get('phase') == 'downloading', 'download status missing')
    number = checking['statusWindow']
    steps = []
    for _ in range(4):
        time.sleep(.12)
        steps.append(ui(app))
    results['A2_download_progress'] = {'ok': len({s.get('received') for s in steps}) > 1
        and all(' of ' in s.get('statusText', '') for s in steps)
        and all(0 <= s.get('progress', -1) <= 1 and not s.get('indeterminate') for s in steps)
        and 'Cancel' in ax(app, number).get('text', []), 'steps': steps}
    results['A2_status_snapshots'] = {'ok': True, 'paths': capture_pair(app, opts, 'status-download', number)}
    assert app.call('updater-act', action='cancel-download'), 'download finished before Cancel could be tested'
    cancelled = wait(lambda: ui(app), lambda s: s.get('statusWindow') == 0, 'download Cancel left status open')
    results['A2_cancel_download'] = {'ok': cancelled.get('statusWindow') == 0, 'ui': cancelled}


def exercise_variants(opts, folder, results, launch, configure, public, origin, original):
    import xml.etree.ElementTree as ET
    ET.register_namespace('sparkle', 'http://www.andymatuschak.org/xml-namespaces/sparkle')
    sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    feed = folder / 'appcast.xml'
    base = feed.read_text()
    no_app = folder / 'NoApp.zip'
    with zipfile.ZipFile(no_app, 'w', compression=zipfile.ZIP_DEFLATED) as zipped:
        for i in range(512):
            zipped.writestr('files/%04d.txt' % i, 'Preparation fixture. ' * 100)
        zipped.writestr('padding.bin', os.urandom(256 * 1024))
    no_app_attributes = subprocess.check_output([str(opts.tools / 'sign_update'), '--ed-key-file',
        str(folder / 'throwaway.key'), str(no_app)], text=True).strip()
    no_app_enclosure = ET.fromstring('<enclosure xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" ' + no_app_attributes + '/>')
    for variant in ('without-notes', 'critical', 'minimum', 'information-only', 'html', 'empty-html', 'notes-at-limit', 'notes-over-limit', 'up-to-date', 'background-up-to-date', 'bad-signature', 'background-error', 'background-install-error', 'ready', 'background-ready', 'summary', 'summary-dismiss'):
        tree = ET.fromstring(base)
        items = list(tree.find('channel').findall('item'))
        for item in items:
            if variant == 'without-notes':
                item.remove(item.find('description'))
            elif variant == 'critical':
                ET.SubElement(item, sparkle + 'criticalUpdate')
            elif variant == 'minimum':
                ET.SubElement(item, sparkle + 'minimumAutoupdateVersion').text = '900000'
            elif variant == 'information-only':
                item.remove(item.find('enclosure'))
                ET.SubElement(item, 'link').text = 'https://github.com/SergeSerb2/open#updates'
            elif variant == 'html':
                notes = item.find('description')
                notes.set(sparkle + 'format', 'html')
                notes.text = '<b>Plain &amp; safe</b> &lt;literal&gt; &quot;quote&quot; &#39;apostrophe&#39;'
            elif variant == 'empty-html':
                item.find('description').set(sparkle + 'format', 'html')
                item.find('description').text = '<p></p>'
                item.find('title').text = ''
            elif variant in ('notes-at-limit', 'notes-over-limit'):
                item.find('description').text = ('x' * 65536 if variant == 'notes-at-limit'
                    else 'x' * 65535 + 'éLIMIT_SENTINEL')
            elif variant == 'background-install-error':
                item.find('enclosure').attrib.update(no_app_enclosure.attrib)
                item.find('enclosure').set('url', origin + '/NoApp.zip')
            elif variant in ('up-to-date', 'background-up-to-date'):
                item.find(sparkle + 'version').text = original['CFBundleVersion']
            elif variant == 'background-error':
                item.find('enclosure').set('url', origin + '/download-failure.zip')
            elif variant == 'bad-signature':
                item.find('enclosure').set(sparkle + 'edSignature', base64.b64encode(b'x' * 64).decode())
        feed.write_text(ET.tostring(tree, encoding='unicode'))
        subprocess.run([str(opts.tools / 'sign_update'), '--ed-key-file', str(folder / 'throwaway.key'), str(feed)],
                       check=True, capture_output=True)
        write('open.general.updateChannel', 'stable')
        # The ready-stage cleanup really skips the fixture. Do not let that
        # choice suppress the next independent background-feed case.
        for key in ('SUSkippedVersion', 'SUSkippedMajorVersion', 'SUSkippedMajorSubreleaseVersion'):
            write(key, None)
        write('open.general.automaticallyUpdate', variant != 'background-ready')
        write('SULastCheckTime', datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None))
        if variant.startswith('summary'):
            write('open.updates.lastInstalledBuild', '0')
            write('open.updates.summaryShownBuild', None)
        app = launch(folder / 'Open.app', allow='1')
        try:
            wait(lambda: app.call('updater-state'), lambda s: s.get('started') and s.get('canCheck'), 'updater not ready')
            if variant.startswith('summary'):
                state = ui(app)
                if variant == 'summary-dismiss':
                    snapshot = json.loads(Path(app.call('save')).read_text())
                    app.call('profile-archive-setting', profile=snapshot['profiles'][0]['id'], interval='twelveHours', scope='all')
                    app.call('defaults', key='open.sidebar.autoArchiveBannerEligible', value=True)
                    app.call('defaults', key='open.sidebar.autoArchiveBannerDismissed', value=False)
                    old = app.call('open', url=FIXTURE, background=True)['id']
                    stamp = app.tab(old)['lastActiveAt'] + 13 * 3600
                    app.call('archive-sweep', now=datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).isoformat().replace('+00:00', 'Z'))
                    waiting = app.call('archive-banner-state')
                    app.call('updater-act', action='dismiss-banner')
                    wait(lambda: ui(app), lambda s: s.get('banner') == '', 'summary dismiss failed')
                    results['A7_dismiss'] = {'ok': domain().get('open.updates.summaryShownBuild') == original['CFBundleVersion']}
                    education = app.call('archive-banner-state')
                    results['S6_slot_priority'] = {'ok': waiting['requested'] and not waiting['visible']
                        and education['visible'], 'waiting': waiting, 'afterUpdateDismiss': education}
                    continue
                summary_ax = ax(app, app.call('shell-windows')[0]['number'])
                results['A7_summary'] = {'ok': state.get('banner') == 'summary'
                    and all(t in summary_ax.get('text', []) for t in ('Open Updated!', 'What’s New')), 'ui': state, 'ax': summary_ax}
                first_window = app.call('shell-windows')[0]
                app.call('menu-perform', id='new-window')
                windows = app.call('shell-windows')
                results['S6_every_browser_window'] = {'ok': len(windows) == 2
                    and all('Open Updated!' in ax(app, w['number']).get('text', []) for w in windows)}
                added = next(w for w in windows if w['id'] != first_window['id'])
                app.call('window-close', window=added['id'])
                app.call('window-focus', id=first_window['id'], activate=True)
                paths = capture_pair(app, opts, 'summary-banner', app.call('shell-windows')[0]['number'], results)
                app.call('updater-banner-width', width=164)
                row = ax(app, app.call('shell-windows')[0]['number'])
                results['A7_narrow'] = {'ok': 'Updated!' in row.get('text', []) and 'What’s new' in row.get('text', []),
                    'ax': row, 'paths': capture_pair(app, opts, 'summary-banner-narrow', app.call('shell-windows')[0]['number'], results)}
                app.call('updater-act', action='banner')
                tabs = app.call('tabs')
                url = 'https://github.com/SergeSerb2/open/releases/tag/v' + original['CFBundleShortVersionString']
                results['A7_notes_tab'] = {'ok': any(t['url'] == url and t.get('selected') and t.get('section') == 'today' for t in tabs)
                    and ui(app).get('banner') == '', 'paths': paths, 'tabs': tabs}
                continue
            before = wait(lambda: app.call('updater-menu'), lambda m: m['canCheck'] and m['title'] == 'Check for Updates…', 'menu did not settle after startup')
            app.call('updater-background-check') if variant.startswith('background-') else app.call('menu-perform', id='check-for-updates')
            checking = ui(app)
            during = app.call('updater-menu')
            can_check = during['canCheck']
            results['A1_checking_' + variant] = {'ok': before['title'] == 'Check for Updates…'
                and during['title'] == ('Check for Updates…' if can_check else 'Updating…') and during['enabled']
                and (variant.startswith('background-') or (checking.get('statusText') == 'Checking for updates...' and checking.get('indeterminate'))),
                'before': before, 'during': during, 'ui': checking}
            if variant == 'background-up-to-date':
                finished = wait(lambda: app.call('updater-state'), lambda s: s.get('completedChecks', 0) > 0
                    and not s.get('sessionInProgress'), 'background no-update check did not finish')
                results['A5_background_no_update_silent'] = {'ok': finished['ui'].get('lastToast') == ''
                    and all(finished['ui'].get(k, 0) == 0 for k in ('statusWindow', 'updateWindow', 'alertWindow')), 'state': finished}
                continue
            if variant in ('background-error', 'background-install-error'):
                wait(lambda: ui(app), lambda s: s.get('phase') == 'downloading', 'background download missing')
                app.call('menu-perform', id='check-for-updates')
                pending = ui(app)
                results['A8_new_update_pending_' + variant] = {'ok': pending.get('lastToast') == 'newUpdatePending'
                    and toast_matches(app, 'newUpdatePending'), 'ui': pending}
                if variant == 'background-install-error':
                    states = []
                    in_progress_copy = False
                    end = time.monotonic() + 30
                    while time.monotonic() < end:
                        sample = ui(app); states.append(sample)
                        if sample.get('phase') == 'extracting':
                            app.call('menu-perform', id='check-for-updates')
                            in_progress_copy |= toast_matches(app, 'updateAlreadyInProgress')
                        if sample.get('lastToast') == 'failedToInstall':
                            break
                        time.sleep(.025)
                    state = states[-1]
                    observed = any(s.get('lastToast') == 'updateAlreadyInProgress' for s in states)
                    results['A8_already_in_progress'] = {'ok': observed and in_progress_copy, 'states': states}
                    results['A8_failed_to_install'] = {'ok': state.get('lastToast') == 'failedToInstall' and toast_matches(app, 'failedToInstall')
                        and state.get('alertWindow') == 0, 'ui': state}
                else:
                    state = wait(lambda: ui(app), lambda s: s.get('lastToast') == 'failedToDownloadUpdate', 'background error toast missing')
                    results['A5_background_error_toast'] = {'ok': state.get('alertWindow') == 0 and state.get('lastToast') == 'failedToDownloadUpdate'
                        and toast_matches(app, 'failedToDownloadUpdate'), 'ui': state}
                continue
            state = wait(lambda: ui(app), lambda s: s.get('phase') in ('found', 'upToDate'), 'no result window')
            row = ax(app, state['updateWindow'])
            if variant == 'up-to-date':
                version = 'Version ' + original['CFBundleShortVersionString'] + ' (' + original['CFBundleVersion'] + ')'
                results['A4_up_to_date'] = {'ok': version in row.get('text', []) and 'Your browser is up to date' in row.get('text', [])
                    and 'Close' in row.get('text', []), 'ax': row,
                    'paths': capture_pair(app, opts, 'up-to-date', state['updateWindow'])}
                app.call('key', key='return', window=state['updateWindow'], route='app')
                wait(lambda: app.call('updater-state'), lambda s: not s.get('sessionInProgress'), 'Close did not acknowledge up-to-date')
            elif variant == 'without-notes':
                results['A3_without_notes'] = {'ok': state.get('notes') == '' and 'Download' in row.get('text', []),
                    'ax': row, 'paths': capture_pair(app, opts, 'has-update-no-notes', state['updateWindow'])}
            elif variant == 'critical':
                blocked = app.call('updater-act', action='later') is False
                app.call('updater-act', action='close')
                results['A3_critical'] = {'ok': blocked and 'Remind me Later' not in row.get('text', [])
                    and ui(app).get('updateWindow') == state['updateWindow'], 'ax': row}
            elif variant == 'minimum':
                blocked = app.call('updater-act', action='later') is False
                app.call('updater-act', action='close')
                results['A3_minimum'] = {'ok': blocked and 'Remind me Later' not in row.get('text', [])
                    and ui(app).get('updateWindow') == state['updateWindow'], 'ax': row}
            elif variant == 'information-only':
                app.call('updater-act', action='primary')
                results['A3_information_only'] = {'ok': 'Download' in row.get('text', [])
                    and any(t['url'] == 'https://github.com/SergeSerb2/open#updates' and t.get('selected') and t.get('section') == 'today' for t in app.call('tabs'))}
            elif variant == 'html':
                results['A3_html_plain'] = {'ok': state.get('notes') == 'Plain & safe <literal> "quote" \'apostrophe\'', 'ui': state}
            elif variant == 'empty-html':
                results['A3_empty_notes'] = {'ok': state.get('notes') == 'Thanks for using Open!'
                    and 'A new version is available' in row.get('text', []), 'ax': row}
            elif variant in ('notes-at-limit', 'notes-over-limit'):
                count = len(state.get('notes', '').encode('utf-8'))
                results['D3_' + variant] = {'ok': count == (65536 if variant == 'notes-at-limit' else 65535)
                    and 'LIMIT_SENTINEL' not in state.get('notes', ''), 'renderedBytes': count}
            elif variant in ('ready', 'background-ready'):
                app.call('updater-act', action='primary')
                states = []
                end = time.monotonic() + 30
                while time.monotonic() < end:
                    sample = ui(app); states.append(sample)
                    if sample.get('phase') == 'ready' or sample.get('alertWindow'):
                        break
                    time.sleep(.03)
                state = states[-1]
                if variant == 'ready':
                    row = ax(app, state.get('statusWindow'))
                    results['A2_preparing_ready'] = {'ok': state.get('phase') == 'ready'
                        and any(s.get('statusText') == 'Preparing…' for s in states)
                        and state.get('statusText') == 'Ready to Install' and state.get('progress') == 1 and state.get('banner') == ''
                        and 'Install and Relaunch' in row.get('text', []), 'states': states, 'ax': row}
                    app.updater_needs_skip = True
                    app.call('updater-act', action='close')
                    wait(lambda: app.call('updater-state'), lambda s: s.get('canCheck') and not s.get('sessionInProgress'), 'ready dismissal did not finish')
                    app.call('menu-perform', id='check-for-updates')
                    resumed = wait(lambda: ui(app), lambda s: s.get('updateWindow', 0) > 0, 'prepared update did not resume')
                    app.updater_needs_skip = False
                    resumed_ax = ax(app, resumed['updateWindow'])
                    results['A3_install_stage'] = {'ok': resumed.get('primary') == 'Install and Relaunch'
                        and 'Install and Relaunch' in resumed_ax.get('text', []), 'ax': resumed_ax}
                else:
                    row = ax(app, app.call('shell-windows')[0]['number'])
                    paths = capture_pair(app, opts, 'available-banner', app.call('shell-windows')[0]['number'], results)
                    results['A6_available_banner'] = {'ok': state.get('banner') == 'available'
                        and 'Open is ready to update!' in row.get('text', []), 'ui': state, 'ax': row, 'paths': paths}
                    app.call('updater-act', action='banner')
                    state = wait(lambda: ui(app), lambda s: s.get('alertWindow'), 'restart sheet missing')
                    row = ax(app, state['alertWindow'])
                    app.call('updater-act', action='alert-second')
                    results['A6_restart_cancel'] = {'ok': all(t in row.get('text', []) for t in
                        ('Open is ready to update!', 'Restart required.', 'Restart', 'Cancel'))
                        and ui(app).get('banner') == 'available', 'ax': row}
                    results['A8_cancelled_install'] = {'ok': ui(app).get('lastToast') == 'cancelledInstall' and toast_matches(app, 'cancelledInstall')}
                    app.call('updater-banner-width', width=164)
                    row = ax(app, app.call('shell-windows')[0]['number'])
                    results['A6_narrow'] = {'ok': 'An update is ready!' in row.get('text', []), 'ax': row,
                        'paths': capture_pair(app, opts, 'available-banner-narrow', app.call('shell-windows')[0]['number'], results)}
                    app.call('updater-act', action='dismiss-banner')
                    wait(lambda: ui(app), lambda s: s.get('banner') == '', 'banner stayed visible')
                    results['A6_dismiss'] = {'ok': domain().get('open.updates.bannerDismissalCount') == 1}
            elif variant == 'bad-signature':
                app.call('updater-act', action='primary')
                state = wait(lambda: ui(app), lambda s: s.get('alertWindow', 0) > 0, 'signature error alert missing')
                row = ax(app, state['alertWindow'])
                results['A5_error_alert'] = {'ok': all(t in row.get('text', []) for t in ('Update error!', 'OK', 'Download manually')), 'ax': row}
                app.call('updater-act', action='alert-second')
                results['A5_manual_tab'] = {'ok': any(t['url'] == 'https://github.com/SergeSerb2/open/releases/latest' for t in app.call('tabs'))}
        finally:
            close_updates(app)
            app.quit()
        results.tracker.checkpoint()
    app = launch(folder / 'Open.app', allow='1')
    try:
        wait(lambda: app.call('updater-state'), lambda s: s.get('created'), 'updater not created')
        results['A7_never_returns'] = {'ok': ui(app).get('banner') == ''
            and domain().get('open.updates.summaryShownBuild') == original['CFBundleVersion'], 'ui': ui(app)}
    finally:
        close_updates(app); app.quit()
    results.tracker.checkpoint()
    feed.write_text(base)


def installer_processes():
    """Only Sparkle installers, identified by executable and host argument."""
    rows = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or DOMAIN not in parts[1]:
            continue
        pid = int(parts[0]); path = harness.Open.process_path(pid)
        if path.endswith('/Autoupdate'):
            rows[pid] = path
    return rows


def pause_review_installer(app, before, copied):
    # #283 deliberately lets installer quits bypass every user prompt. Freeze
    # the real, already prepared installer BEFORE answering Install, so even
    # an unexpected host exit cannot install the fixture. Never resume it.
    app.review_binary_sha = file_sha256(copied / 'Contents/MacOS/Open')
    app.review_installers = {pid: path for pid, path in installer_processes().items() if pid not in before}
    assert app.review_installers, 'Refuse installation without identified suite-owned installer cleanup'
    for pid, path in app.review_installers.items():
        assert harness.Open.process_path(pid) == path, 'Installer ownership changed before pause'
        os.kill(pid, signal.SIGSTOP)
    def stopped():
        return {pid: subprocess.check_output(['ps', '-p', str(pid), '-o', 'stat='], text=True).strip()
                for pid, path in app.review_installers.items() if harness.Open.process_path(pid) == path}
    app.review_paused = wait(stopped, lambda rows: len(rows) == len(app.review_installers)
                             and all('T' in state for state in rows.values()), 'installer did not pause')


def stop_review_installer(app, results, copied):
    # Only the new installers observed during this exclusive screen run belong
    # to us. SIGKILL also ends a paused installer; SIGTERM would stay pending.
    owned = getattr(app, 'review_installers', {})
    assert owned, 'No suite-owned Sparkle installer found'
    for pid, path in owned.items():
        if harness.Open.process_path(pid) == path:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
    wait(lambda: [pid for pid, path in owned.items() if harness.Open.process_path(pid) == path],
         lambda pids: not pids, 'suite-owned Sparkle installer did not stop')
    after = file_sha256(copied / 'Contents/MacOS/Open')
    results['R2_no_install_cleanup'] = {'ok': bool(getattr(app, 'review_paused', {})) and after == app.review_binary_sha
        and all(harness.Open.process_path(pid) != path for pid, path in owned.items()),
        'installerPIDs': sorted(owned), 'pausedBeforeInstallReply': getattr(app, 'review_paused', {}),
        'binarySHA256Before': app.review_binary_sha, 'binarySHA256After': after}


def exercise_review_regressions(opts, folder, results, launch, public, origin, original):
    """The three review regressions use real Sparkle cycles and native alerts."""
    import xml.etree.ElementTree as ET
    import downloads
    feed = folder / 'appcast.xml'; base = feed.read_text()
    sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    for variant in ('ready-menu', 'termination-relaunch', 'scheduled-errors'):
        tree = ET.fromstring(base)
        if variant == 'scheduled-errors':
            for item in tree.find('channel').findall('item'):
                item.find('enclosure').set('url', origin + '/download-failure.zip')
        feed.write_text(ET.tostring(tree, encoding='unicode'))
        subprocess.run([str(opts.tools / 'sign_update'), '--ed-key-file', str(folder / 'throwaway.key'), str(feed)],
                       check=True, capture_output=True)
        for key in ('SUSkippedVersion', 'SUSkippedMajorVersion', 'SUSkippedMajorSubreleaseVersion'):
            write(key, None)
        write('open.general.updateChannel', 'stable')
        write('open.general.automaticallyUpdate', variant == 'scheduled-errors')
        write('open.debug.updateFeedURL', origin + '/appcast.xml')
        write('SULastCheckTime', datetime.datetime(2000, 1, 1) if variant == 'scheduled-errors'
              else datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None))
        before_installers = installer_processes()
        app = launch(folder / 'Open.app', allow='1')
        installing = False
        try:
            if variant == 'scheduled-errors':
                first = wait(lambda: app.call('updater-state'), lambda s: s.get('completedChecks', 0) >= 1
                             and not s.get('sessionInProgress'), 'first scheduled failure did not finish')
                first_toasts = app.call('toasts')
                # A changed feed plus the real General toggle resets Sparkle's
                # scheduler. Do not call our manual-background automation path:
                # it resets the old driver's error suppression and hides the bug.
                app.call('defaults', key='open.debug.updateFeedURL', value=origin + '/appcast.xml?cycle=2')
                app.call('settings-toggle', name='updates')
                app.call('settings-toggle', name='updates')
                second = wait(lambda: app.call('updater-state'), lambda s: s.get('completedChecks', 0) > first['completedChecks']
                              and not s.get('sessionInProgress'), 'second scheduled failure did not finish')
                second_toasts = app.call('toasts')
                results['R3_scheduled_background_errors'] = {'ok': first_toasts['shown'] == 1
                    and second_toasts['shown'] == 2 and toast_matches(app, 'failedToDownloadUpdate')
                    and not first['ui']['userInitiated'] and not second['ui']['userInitiated'],
                    'first': first, 'second': second, 'toastCounts': [first_toasts['shown'], second_toasts['shown']]}
                continue
            wait(lambda: app.call('updater-state'), lambda s: s.get('started') and s.get('canCheck'), 'updater not ready')
            app.call('updater-background-check') if variant == 'ready-menu' else app.call('menu-perform', id='check-for-updates')
            wait(lambda: ui(app), lambda s: s.get('phase') == 'found', 'review update not found')
            app.call('updater-act', action='primary')
            ready = wait(lambda: ui(app), lambda s: s.get('phase') == 'ready', 'review update not ready')
            if variant == 'ready-menu':
                app.call('updater-act', action='dismiss-banner')
                app.call('menu-perform', id='check-for-updates')
                state = ui(app); row = ax(app, state.get('alertWindow'))
                if state.get('alertWindow'):
                    app.call('updater-act', action='alert-second')
                pending = app.call('updater-state')
                results['R1_ready_menu_after_dismiss'] = {'ok': all(t in row.get('text', []) for t in
                    ('Open is ready to update!', 'Restart required.', 'Restart', 'Cancel'))
                    and pending['sessionInProgress'] and pending['ui']['phase'] == 'ready'
                    and pending['ui']['banner'] == '' and pending['ui']['alertWindow'] == 0,
                    'ready': ready, 'alertAX': row, 'pendingAfterCancel': pending}
                continue
            # A real normal-quit control proves each prompt is armed. #283
            # bypasses all three for installer relaunch, including beforeunload;
            # there is no longer a user-cancel path for the former R2 retry row.
            with downloads.server() as base_url:
                tab = app.call('tabs')[0]['id']
                installing = True
                pause_review_installer(app, before_installers, folder / 'Open.app')
                if opts.force_failure:
                    raise AssertionError('forced failure with the prepared installer paused')
                snapshot = json.loads(Path(app.call('save')).read_text())
                destination = folder / 'retry-downloads'; destination.mkdir(exist_ok=True)
                app.call('download-settings', profile=snapshot['profiles'][0]['id'], directory=str(destination), ask=False)
                app.call('download-policy', quit='keep')
                app.call('defaults', key='open.general.warnBeforeQuitting', value=True)
                app.call('quit-warning', button='cancel', request=True)
                generic = wait(lambda: app.call('quit-warning'), lambda rows: len(rows) == 1,
                               'normal quit did not show the generic warning')
                app.call('defaults', key='open.general.warnBeforeQuitting', value=False)
                app.call('navigate', tab=tab, url=base_url + '/arm')
                app.call('wait', tab=tab)
                app.call('click', tab=tab, selector='#arm')
                wait(lambda: app.call('engine-sleep', tab=tab), lambda s: s['unloadHandlers'], 'beforeunload not armed')
                app.call('quit-warning', request=True)
                page = wait(lambda: app.call('dialog-state'), lambda s: s.get('visible'), 'normal quit did not show beforeunload')
                app.call('dialog-button', accept=False)
                wait(lambda: app.call('dialog-state'), lambda s: not s.get('pending'), 'beforeunload stayed open')
                app.call('defaults', key='open.general.warnBeforeQuitting', value=True)
                # A download navigation on the armed page would itself ask
                # beforeunload before the quit proof. Keep both real fixtures.
                download_tab = harness.new_tab(app, base_url + '/')

                def start_download():
                    app.eval(download_tab, '(() => {let a=document.createElement("a");a.href=%s;a.id="review-download";a.textContent="download";document.body.append(a)})()' % json.dumps(base_url + '/slow'))
                    app.call('click', tab=download_tab, selector='#review-download')
                    return wait(lambda: app.call('downloads-state'),
                                lambda s: s['running'] and any(i['received'] > 0 for i in s['items']), 'real download did not start')
                start_download()
                app.call('quit-warning', request=True)
                downloads_control = wait(lambda: app.call('downloads-state'), lambda s: len(s['quitAlerts']) == 1,
                                         'normal quit did not show Downloads warning')
                results['R2_normal_quit_controls'] = {'ok': generic[0]['title'] == 'Quit Open?'
                    and page.get('title') == 'Leave site?' and page.get('buttons') == ['OK', 'Cancel']
                    and page.get('kind') == 3
                    and downloads_control['quitAlerts'][0]['title'] == 'Downloads in progress'
                    and bool(app.call('ping')), 'generic': generic, 'beforeunload': page,
                    'downloads': downloads_control['quitAlerts']}
                assert results['R2_normal_quit_controls'].get('ok'), 'Quit controls did not prove the prompts are armed'
                running = app.call('downloads-state')
                assert running['running'], 'Download finished before relaunch proof'
                assert app.call('engine-sleep', tab=tab)['unloadHandlers'], 'beforeunload was disarmed'
                before_log = app.log_text()
                app.discover_owned_processes()
                app.activation_trace = app.call('activation-events')
                app.call('updater-act', action='primary')
                # The paused installer cannot send its quit event. Use the real
                # App menu command after the native Install button has requested
                # relaunch. This is NOT harness `quit`, which bypasses warnings.
                app.call('quit-warning', request=True)
                exited = harness.wait_until(lambda: not app.process_path(app.pid), timeout=15, step=.05)
                after_log = app.log_text()
                markers = ('generic-quit-alert-presented', 'downloads-quit-alert-presented')
                results['R2_install_relaunch_skips_prompts'] = {'ok': bool(exited)
                    and all(after_log.count(m) == before_log.count(m) for m in markers),
                    'normalQuitCommand': 'quit-open', 'installerPaused': app.review_paused,
                    'downloadsRunning': running['running'], 'beforeunloadArmed': True,
                    'warningCountsBefore': [before_log.count(m) for m in markers],
                    'warningCountsAfter': [after_log.count(m) for m in markers], 'hostExited': bool(exited)}
        finally:
            if installing and getattr(app, 'review_installers', {}):
                stop_review_installer(app, results, folder / 'Open.app')
            if app.process_path(app.pid):
                if variant == 'termination-relaunch':
                    if app.call('dialog-state').get('visible'): app.call('dialog-button', accept=False)
                    app.eval(tab, 'onbeforeunload=null;true')
                    app.call('download-policy', quit='close')
                close_updates(app)
            app.quit()
        results.tracker.checkpoint()
    feed.write_text(base)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default='Debug')
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--main-bundle', type=Path)
    parser.add_argument('--tools', type=Path, default=Path.home() / 'Developer/open-release-tools/sparkle-2.10.1/bin')
    parser.add_argument('--openssl', default='/opt/homebrew/opt/openssl@3/bin/openssl'
                        if Path('/opt/homebrew/opt/openssl@3/bin/openssl').exists() else 'openssl')
    parser.add_argument('--force-failure', action='store_true')
    parser.add_argument('--review-only', action='store_true', help='Only the three real-App review regressions')
    parser.add_argument('--windowless-only', action='store_true', help='Only real-App error and restart alerts with no browser window')
    parser.add_argument('--output', type=Path)
    opts = parser.parse_args()
    opts.bundle = (opts.bundle or Path(harness.ROOT) / 'build' / opts.config / 'Open.app').resolve()
    opts.output = opts.output or Path(harness.ROOT) / '.re/updater/results.json'
    opts.output.parent.mkdir(parents=True, exist_ok=True)
    apps, results = [], harness.CheckedResults(harness.FocusTracker())
    results.update(load=os.getloadavg(), uptime=subprocess.check_output(['uptime'], text=True).strip())
    scan = subprocess.run(['rg', '-n', r'import WebKit|\b(WKWebView|WebView)\b|NSAttributedString\s*\(\s*html:|\.documentType.*\.html|\.html.*\.documentType',
        'App/Updater', 'Packages/OpenKit/Sources/OpenSidebar'], cwd=harness.ROOT, text=True, capture_output=True)
    results['A9_source_scan'] = {'ok': scan.returncode == 1, 'command': scan.args,
        'matches': scan.stdout, 'stderr': scan.stderr}
    diff = subprocess.check_output(['git', 'diff', 'HEAD', '--', 'App', 'tools/e2e/updater.py'], cwd=harness.ROOT)
    source_paths = sorted(set(subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard',
        'App/Updater', 'App/AppDelegate.swift', 'App/MainMenu.swift', 'App/Automation/AutomationController.swift',
        'Packages/OpenKit/Sources/OpenSidebar', 'Packages/OpenKit/Sources/OpenSettings/GeneralPane.swift',
        'tools/e2e/updater.py'], cwd=harness.ROOT, text=True).splitlines()))
    results['source'] = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=harness.ROOT, text=True).strip(),
        'clean': not subprocess.check_output(['git', 'status', '--porcelain', '--', *source_paths], cwd=harness.ROOT),
        'diffSHA256': hashlib.sha256(diff).hexdigest(),
        'filesSHA256': {name: hashlib.sha256((Path(harness.ROOT) / name).read_bytes()).hexdigest() for name in source_paths},
        'binarySHA256': hashlib.sha256((opts.bundle / 'Contents/MacOS/Open').read_bytes()).hexdigest()}
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(128 + 15))
    failed = False
    with tempfile.TemporaryDirectory(prefix='open-updater-') as scratch:
        try:
            run(opts, Path(scratch), results, apps)
        except (Exception, KeyboardInterrupt) as error:
            failed = True; results['failure'] = str(error)
        finally:
            for app in apps:
                app.quit()
            results['cleanup'] = {'ok': all(a.quit_report.get('ok') for a in apps),
                'instances': len(apps), 'remainingProcesses': sum(len(a.quit_report.get('remaining_processes', [])) for a in apps),
                'remainingWindows': sum(a.quit_report.get('windows_after_quit', {}).get('count', 0) for a in apps)}
            cleanup_errors = [a.updater_cleanup_error for a in apps if hasattr(a, 'updater_cleanup_error')]
            results['updater_sessions_closed'] = {'ok': not cleanup_errors, 'errors': cleanup_errors}
            if (Path(scratch) / 'open.log').exists():
                shutil.copyfile(Path(scratch) / 'open.log', opts.output.with_suffix('.app.log'))
            results['endLoad'] = os.getloadavg()
            opts.output.write_text(json.dumps(results, indent=2))
    for key, value in results.items():
        if isinstance(value, dict) and 'ok' in value:
            print(key, 'PASS' if value['ok'] else 'FAIL')
            failed |= not value['ok']
        elif isinstance(value, dict) and value.get('status'):
            print(key, value['status'], value.get('reason', ''))
    if results.get('failure'):
        print(results['failure'])
    print('receipt:', opts.output)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
