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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine_e2e as harness
from restore_defaults import write_collection

DOMAIN = 'io.github.sergeserb2.open'
OPEN_KEYS = {'open.general.automaticallyUpdate', 'open.general.updateChannel',
             'open.debug.updateFeedURL', 'open.settings.lastPane', 'OPEN_UPDATER_ALLOW_ADHOC',
             'open.links.openPeekShiftClick', 'open.links.openPeekOtherSites',
             'open.links.littleOpenNUXSeen', 'open.general.searchSuggestNoticeDismissed',
             'NSWindow Frame SUUpdateAlert2'}
FIXTURE = 'data:text/html,<title>Updater fixture</title><h1>Updater fixture</h1>'


def domain():
    result = subprocess.run(['defaults', 'export', DOMAIN, '-'], capture_output=True)
    return plistlib.loads(result.stdout) if result.returncode == 0 else {}


def write(key, value):
    if value is None:
        subprocess.run(['defaults', 'delete', DOMAIN, key], capture_output=True, check=False)
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
    archive = folder / 'Open-fixture.zip'
    with zipfile.ZipFile(archive, 'w') as zipped:
        zipped.writestr('fixture.txt', 'Detection fixture only. Never install.')
    signing = [str(tools / 'sign_update'), '--ed-key-file', str(key)]
    attributes = subprocess.check_output(signing + [str(archive)], text=True).strip()
    items = []
    for version, channel in [('900001', ''), ('900002', '<sparkle:channel>beta</sparkle:channel>')]:
        items.append(f'''<item><title>Open updater fixture {version}</title>
          <sparkle:version>{version}</sparkle:version><sparkle:shortVersionString>99.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>{channel}
          <description>Local detection fixture. Do not install.</description>
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
            samples = {'main': [], 'branch': []}
            for _ in range(5):
                for label, bundle in [('main', opts.main_bundle), ('branch', opts.bundle)]:
                    assert os.getloadavg()[0] <= 12, 'TANDEM launch timing requires load1 <= 12'
                    app = launch(bundle)
                    try:
                        timing = wait(lambda: app.call('timing'), lambda t: 'firstContentfulPaint' in t, 'no paint')
                        assert timing.get('kernelProcessStart') and timing.get('firstFrameConfirmed'), timing
                        samples[label].append({'timing': timing, 'load': os.getloadavg(),
                            'uptime': subprocess.check_output(['uptime'], text=True).strip()})
                    finally:
                        app.quit()
                    tracker.checkpoint()
            medians = {label: statistics.median(s['timing']['sidebarDrawn'] for s in values)
                       for label, values in samples.items()}
            results['interleaved_launch'] = {'ok': medians['branch'] <= medians['main'],
                'sidebarDrawnMedianMs': medians, 'samples': samples}
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
                name = {'/appcast.xml': 'appcast.xml', '/Open-fixture.zip': 'Open-fixture.zip'}.get(self.path)
                if not serve_fixture or name is None:
                    self.send_response(404); self.end_headers(); return
                body = (folder / name).read_bytes()
                assert len(body) <= 65536
                self.send_response(200)
                self.send_header('Content-Type', 'application/xml' if name.endswith('.xml') else 'application/zip')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)
            def log_message(self, *_):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Canary)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            origin = 'http://127.0.0.1:%d' % server.server_port
            public, feed = make_feed(folder, opts.tools, opts.openssl, origin)
            def configure(key, url):
                info = dict(original, SUPublicEDKey=key, SUFeedURL=url)
                info_path.write_bytes(plistlib.dumps(info))
                subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none',
                    '--preserve-metadata=entitlements', str(copied)], check=True, capture_output=True)
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
            for channel, expected in [('stable', '900001'), ('beta', '900002')]:
                write('open.general.updateChannel', channel)
                write('open.general.automaticallyUpdate', True)
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
                    found = wait(lambda: app.call('updater-state'), lambda s: s['foundVersion'] is not None, 'update not found')
                    windows = wait(lambda: app.call('windows', accessibility=True),
                        lambda rows: any(r['visible'] and 'Software Update' in (r['title'] + ' '.join(r.get('text', []))) for r in rows),
                        'Sparkle Software Update window missing')
                    results[channel + '_local_signed_feed'] = {'ok': found['foundVersion'] == expected
                        and found['lastCheck'] is not None and all(p == '/appcast.xml' for p in requests),
                        'state': found, 'sparkleWindowTitles': [r['title'] for r in windows if r['visible']],
                        'loopbackRequests': len(requests)}
                    if opts.force_failure:
                        raise AssertionError('forced failure while Sparkle update window is open')
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
                finally:
                    app.quit()
                tracker.checkpoint()
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default='Debug')
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--main-bundle', type=Path)
    parser.add_argument('--tools', type=Path, default=Path.home() / 'Developer/open-release-tools/sparkle-2.10.1/bin')
    parser.add_argument('--openssl', default='/opt/homebrew/opt/openssl@3/bin/openssl'
                        if Path('/opt/homebrew/opt/openssl@3/bin/openssl').exists() else 'openssl')
    parser.add_argument('--force-failure', action='store_true')
    parser.add_argument('--output', type=Path)
    opts = parser.parse_args()
    opts.bundle = (opts.bundle or Path(harness.ROOT) / 'build' / opts.config / 'Open.app').resolve()
    opts.output = opts.output or Path(harness.ROOT) / '.re/updater/results.json'
    opts.output.parent.mkdir(parents=True, exist_ok=True)
    apps, results = [], harness.CheckedResults(harness.FocusTracker())
    results.update(load=os.getloadavg(), uptime=subprocess.check_output(['uptime'], text=True).strip())
    diff = subprocess.check_output(['git', 'diff', 'HEAD', '--', 'App', 'tools/e2e/updater.py'], cwd=harness.ROOT)
    results['source'] = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=harness.ROOT, text=True).strip(),
                         'clean': not diff, 'diffSHA256': hashlib.sha256(diff).hexdigest()}
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
            if (Path(scratch) / 'open.log').exists():
                shutil.copyfile(Path(scratch) / 'open.log', opts.output.with_suffix('.app.log'))
            results['endLoad'] = os.getloadavg()
            opts.output.write_text(json.dumps(results, indent=2))
    for key, value in results.items():
        if isinstance(value, dict) and 'ok' in value:
            print(key, 'PASS' if value['ok'] else 'FAIL')
            failed |= not value['ok']
    if results.get('failure'):
        print(results['failure'])
    print('receipt:', opts.output)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
