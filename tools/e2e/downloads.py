"""S11 Downloads: real App, engine transfers, native Library controls and sheets."""
import contextlib
import http.server
import json
import hashlib
import os
from pathlib import Path
import re
import plistlib
import socket
import sqlite3
import subprocess
import threading
import time
import tempfile
import urllib.parse
from loopback_http import LoopbackHTTPServer


# Running Library rows. Known total: "1.2/33.6 MB" or "512 KB/33.6 MB", then " · 12s" with a speed.
# Unknown total: the received byte count alone.
LIVE_SUBTITLE = re.compile(r'^[\d.,]+( [A-Za-z]+)?/[\d.,]+ [A-Za-z]+( · \d+s)?$')
UNKNOWN_SUBTITLE = re.compile(r'^[\d.,]+ [A-Za-z]+$')

QUIT_EVENT_SOURCE = r"""
#import <Carbon/Carbon.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  pid_t pid = (pid_t)strtol(argv[1], 0, 10);
  if (pid <= 1) return 2;
  AEAddressDesc target = {typeNull, NULL}; AppleEvent event = {typeNull, NULL};
  OSStatus status = AECreateDesc(typeKernelProcessID, &pid, sizeof(pid), &target);
  if (!status) status = AECreateAppleEvent(kCoreEventClass, kAEQuitApplication, &target, kAutoGenerateReturnID, kAnyTransactionID, &event);
  if (!status) status = AESendMessage(&event, NULL, kAENoReply | kAENeverInteract, kAEDefaultTimeout);
  AEDisposeDesc(&event); AEDisposeDesc(&target);
  return status ? 1 : 0;
}
"""


def quit_event_sender():
    """A pid-targeted kAEQuitApplication sender, as tools/release.sh's smoke uses (no osascript,
    no desktop input; the core quit event needs no Automation consent)."""
    folder = Path(tempfile.gettempdir()) / 'open-e2e-quit-event'
    folder.mkdir(exist_ok=True)
    binary = folder / 'quit-pid'
    if not binary.exists():
        (folder / 'quit-pid.m').write_text(QUIT_EVENT_SOURCE)
        subprocess.run(['clang', '-framework', 'Carbon', str(folder / 'quit-pid.m'), '-o', str(binary)], check=True)
    return str(binary)


@contextlib.contextmanager
def server():
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_): pass
        def do_GET(self):
            route = self.path.split('?', 1)[0]
            if route in ('/', '/arm'):
                body = b'<!doctype html><title>Downloads fixture</title><body>Downloads fixture</body>'
                if route == '/arm':
                    body = (b'<!doctype html><title>Unload fixture</title><button id=arm '
                            b'onclick="onbeforeunload=e=>{e.preventDefault();e.returnValue=1}">Arm</button>')
                self.send_response(200); self.send_header('Connection', 'close'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
            unknown = route == '/unknown'
            slow = route in ('/slow', '/unknown', '/finish')
            count = 64 if route == '/finish' else 2048 if slow else 8
            length = count * 16384
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            name = ('open-e2e-fallback-%d.txt' % os.getpid() if route == '/fallback'
                    else 'private-history.txt' if route == '/private' else 'sample.txt')
            self.send_header('Content-Disposition', 'attachment; filename="%s"' % name)
            if not unknown: self.send_header('Content-Length', str(length if route != '/fail' else length * 100))
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                for _ in range(count):
                    self.wfile.write(b'Open download.\n' + b'x' * (16384 - 15)); self.wfile.flush()
                    if slow: time.sleep(.04)
                if route == '/fail': self.connection.shutdown(socket.SHUT_RDWR)
            except (OSError, BrokenPipeError): pass
            if unknown or route == '/fail': self.close_connection = True
    httpd = LoopbackHTTPServer(Handler)
    httpd.daemon_threads = True
    thread = threading.Thread(target=httpd.serve_forever, daemon=True); thread.start()
    try: yield 'http://127.0.0.1:%d' % httpd.server_port
    finally: httpd.shutdown(); httpd.server_close(); thread.join(5)


def checks(factory, results, tmp, config, harness):
    E = harness
    lane = getattr(harness, 'E2E_LANE', 'all')
    if lane != 'observers' and os.environ.get('OPEN_DOWNLOADS_CASE', '') in ('', 'littleopen'):
        import littleopen_downloads
        littleopen_downloads.checks(factory, results, tmp, E, server)
        if os.environ.get('OPEN_DOWNLOADS_CASE') == 'littleopen':
            return
    root = Path(tempfile.mkdtemp(prefix="downloads-attempt-", dir=tmp))
    probe = root / 'idle-probe.dylib'
    if lane != "merge":
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fblocks', '-fobjc-arc', '-Wno-deprecated-declarations',
                        str(Path(E.ROOT) / 'tools/verification/feature-idle-probe.m'), '-framework', 'AppKit',
                        '-framework', 'QuartzCore', '-framework', 'CoreVideo', '-o', str(probe)], check=True)
    bundle = root / 'Open.app'
    source_app = os.environ.get('OPEN_DOWNLOADS_SOURCE_APP') or str(Path(E.ROOT) / 'build' / config / 'Open.app')
    subprocess.run(['cp', '-cR', source_app, str(bundle)], check=True)
    info_file = bundle / 'Contents/Info.plist'
    info = plistlib.loads(info_file.read_bytes())
    domain = 'io.github.sergeserb2.open.downloads-e2e.' + str(os.getpid()) + '.' + os.urandom(4).hex()
    info['CFBundleIdentifier'] = domain; info_file.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    opener = root / 'DownloadOpenProbe.app'
    executable = opener / 'Contents/MacOS/DownloadOpenProbe'
    executable.parent.mkdir(parents=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-O', '-parse-as-library',
                    str(Path(E.ROOT) / 'tools/e2e/download-opener.swift'), '-framework', 'AppKit', '-o', str(executable)], check=True)
    (opener / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': domain + '.opener', 'CFBundleName': 'Download Open Probe',
        'CFBundleExecutable': 'DownloadOpenProbe', 'CFBundlePackageType': 'APPL',
        'NSPrincipalClass': 'NSApplication', 'LSBackgroundOnly': True, 'LSMinimumSystemVersion': '26.0'}))
    subprocess.run(['codesign', '--force', '--sign', '-', str(opener)], check=True, capture_output=True)
    opened_file = root / 'opened-file.json'
    launch_env = {'DYLD_INSERT_LIBRARIES': str(probe), 'OPEN_IDLE_DOWNLOADS': '1', 'OPEN_E2E_APP_BUNDLE': str(bundle), 'OPEN_DOWNLOADS_DEFAULT_DIRECTORY': str(root / 'DefaultDownloads')}
    if lane == 'merge':
        launch_env.pop('DYLD_INSERT_LIBRARIES')
        launch_env.pop('OPEN_IDLE_DOWNLOADS')
    app = factory(urls=(), extra_env=launch_env, extra_args=['-open.general.warnBeforeQuitting', 'YES'])
    app.exclusive_bundle = True  # This suite alone owns the disposable clone.
    app.preferences_domain = domain
    def state(): return app.call('downloads-state')
    def item(key): return next((v for v in state()['items'] if v['id'] == key), {})
    def row(key): return next((v for v in state()['rows'] if v['id'] == key), {})
    def wait(predicate, seconds=15): return E.wait_until(predicate, timeout=seconds, step=.05)
    def check(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('downloads %-26s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
    retry_result = None
    def menu(key, select=None):
        return app.call('download-menu', id=key, **({'select': select} if select else {}))
    def start(route, source_tab=None):
        before = {v['id'] for v in state()['items']}
        source_tab = source_tab or tab
        app.call('select', tab=source_tab)
        if not wait(lambda: app.eval(source_tab, 'Boolean(document.body) && document.readyState !== "loading"')):
            raise RuntimeError('download source document is not ready')
        app.eval(source_tab, '(() => {let a=document.createElement("a"); a.href=%s; a.id="download"; a.textContent="download";document.body.replaceChildren(a)})()' % json.dumps(base + route))
        app.call('click', tab=source_tab, selector='#download')
        value = wait(lambda: next((v for v in state()['items'] if v['id'] not in before), None))
        if not value: raise RuntimeError('download callback missing for ' + route)
        return value['id']
    def library():
        app.call('command', id='view-downloads')
        wait(lambda: bool(state()['rows']))
    def dismiss_library(): E._try(lambda: app.call('download-library-close'))
    def cancel_sheet_flow():
        app.call('download-settings', profile=profile, directory=str(first), ask=True)
        pending = start('/slow')
        sheet = wait(lambda: next((v for v in state()['sheets'] if v['visible']), None))
        library()
        wait(lambda: bool(row(pending)))
        app.call('download-row', id=pending, action='Cancel')
        stopped = wait(lambda: item(pending).get('state') == 'cancelled' and not state()['sheets'] and not state()['running'])
        check('cancel_save_from_library', sheet and stopped, item=item(pending), sheets=state()['sheets'])
        dismiss_library()
        app.call('download-settings', profile=profile, ask=False)

    def save_flow():
        app.call('download-settings', profile=profile, directory=str(first), ask=True)
        ask = start('/fast')
        sheet = wait(lambda: next((v for v in state()['sheets'] if v['visible']), None))
        check('save_sheet', sheet and sheet['sheet'] and sheet['name'] == 'sample.txt' and sheet['directory'] == str(first), sheet=sheet)
        if os.environ.get('OPEN_DOWNLOADS_FAIL_IN_SHEET'):
            raise RuntimeError('deliberate save-sheet cleanup proof')
        saved_file = root / 'chosen.txt'
        app.call('download-save', id=sheet['id'], path=str(saved_file))
        accepted = wait(lambda: item(ask).get('state') == 'completed')
        check('save_accept', accepted and saved_file.exists() and saved_file.stat().st_size == 131072 and Path(item(ask)['path']).resolve() == saved_file.resolve(), item=item(ask))
        cancelled = start('/fast'); sheet = wait(lambda: next((v for v in state()['sheets'] if v['visible']), None))
        app.call('download-save', id=sheet['id'], action='cancel')
        check('save_cancel', wait(lambda: item(cancelled).get('state') == 'cancelled') and item(cancelled).get('name') == 'sample.txt' and not state()['sheets'], item=item(cancelled))
        app.call('download-settings', profile=profile, ask=False)
        cancel_sheet_flow()


    def controls_flow():
        known = start('/slow')
        live = wait(lambda: (lambda v: v if v.get('received', 0) > 0 and v.get('total', 0) else None)(item(known)))
        library()
        # The in-window Library's running row (OpenLibrary `downloadSubtitle`, #350): "<received>/<total> <unit>",
        # then " · <seconds>s" once the engine reports a speed. The old Settings Library text
        # ("<speed>/s · from <host>") no longer exists, so this row failed on every Mac that ran it.
        running = wait(lambda: (lambda v: v if LIVE_SUBTITLE.match(v.get('subtitle', '')) else None)(row(known)))
        check('live_subtitle', live and running, item=live, row=running or row(known))
        badge = state()['badge']
        check('home_progress', badge.get('running', 0) > 0 and 0 < badge.get('progress', 0) < 1 and badge.get('trackOpacity') == 1 and badge.get('ringOpacity') == 1 and badge.get('ringBounds') == [3, 3, 26, 26] and badge.get('lineWidth') == 2, badge=badge)
        titles = [v['title'] for v in menu(known)]
        check('running_menu_order', len(titles) == 7 and titles[0].startswith('Open ') and titles[1].startswith('Copy ') and titles[2:] == ['Show in Finder', 'separator', 'Cancel Download', 'separator', 'Hide from Open'], titles=titles)
        app.call('download-row', id=known, action='Pause')
        paused = wait(lambda: row(known).get('subtitle') == 'Paused')
        time.sleep(.5); before_pause = item(known)['received']; time.sleep(.6); after_pause = item(known)['received']
        check('pause', paused and before_pause == after_pause and item(known)['state'] == 'paused', received=[before_pause, after_pause], row=row(known))
        app.call('download-row', id=known, action='Resume')
        resumed = wait(lambda: item(known).get('received', 0) > after_pause)
        check('resume', resumed and item(known)['state'] == 'inProgress', item=item(known))
        # With a running download the Library button opens the in-window Library at Downloads, also
        # when it last showed Archive (Arc: library-overlay.md, "Clicking the sidebar Downloads badge").
        # The button toggles the in-window Library (#350), so it starts closed here. The old row
        # pressed it with the Settings Library open and read that window's section.
        app.call('library-open', section='archive'); dismiss_library()
        app.call('download-home')
        check('home_running_entry', wait(lambda: bool(row(known)), 5), rows=len(state()['rows']))
        library()
        app.call('download-row', id=known, action='Cancel')
        check('cancel', wait(lambda: row(known).get('subtitle') == 'Cancelled'), row=row(known))
        dismiss_library()

        # The indeterminate ring spins only without Reduce Motion (HomeDownloadButton); the rented Macs
        # have it on, so pin it off (the state of the M5 and the M1; the App is this suite's own).
        app.call('window-motion', reduced=False)
        unknown = start('/unknown'); library()
        unknown_state = wait(lambda: (lambda v: v if v['badge'].get('indeterminate') and v['badge'].get('animations', 0) > 0 and item(unknown).get('received', 0) > 0 else None)(state()))
        check('unknown_total', unknown_state and item(unknown)['total'] is None and UNKNOWN_SUBTITLE.match(row(unknown).get('subtitle', '')), badge=unknown_state and unknown_state['badge'], row=row(unknown))
        menu(unknown, 'Cancel Download')
        check('menu_cancel', wait(lambda: row(unknown).get('subtitle') == 'Cancelled'))
        dismiss_library()
        failed = start('/fail'); library()
        check('failed_subtitle', wait(lambda: row(failed).get('subtitle') == 'Failed', 30), item=item(failed), row=row(failed))
        dismiss_library()
        # PB1-b wiring: the download started above got a flight record when it was created: played to the
        # Library button, or skipped for a known reason (the Library covers the sidebar at that point of the
        # suite; Reduce Motion on the rented Macs). Read only now: an early downloads-state call changes the
        # rows the checks above read. The motion itself is features-render DF1–DF8.
        flight = next((f for f in state().get('flights', []) if f['id'] == known), None)
        played = bool(flight) and 'duration' in flight and 0.2 < flight['duration'] < 2.5 \
            and flight['target'][0] < flight['start'][0] and flight['target'][1] > flight['start'][1]
        check('download_flight', played or (bool(flight) and flight.get('skipped') in ('Library open', 'Reduce Motion')), flight=flight)


    def files_flow():
        fast = start('/fast')
        wait(lambda: item(fast).get('fileExists'))
        fast2 = start('/fast'); wait(lambda: item(fast2).get('fileExists'))
        paths = [item(v).get('path') for v in (fast, fast2)]
        check('folder_unique', len(set(paths)) == 2 and all(Path(v).parent == first and Path(v).stat().st_size == 131072 for v in paths) and sentinel.read_text() == 'do not overwrite', paths=paths)
        library()
        # The open Library may still show its previous rows; wait for this download's row.
        completed = wait(lambda: row(fast2) or None) or {}
        check('completed_subtitle', completed.get('subtitle') == 'Download', row=completed)  # Arc: the kind word, else "Download" (C3 s8 item 9); .txt has none
        titles = [v['title'] for v in menu(fast2)]
        check('finished_menu_order', len(titles) == 6 and titles[0].startswith('Open ') and titles[1].startswith('Copy ') and titles[2:] == ['Show in Finder', 'separator', 'Hide from Open', 'Move to Trash'], titles=titles)
        app.call('download-policy', openApp=str(opener))
        menu(fast2, titles[0]); menu(fast2, titles[1]); menu(fast2, 'Show in Finder')
        actions = wait(lambda: state()['fileActions'] if len(state()['fileActions']) >= 3 else None)
        check('open_copy_reveal', actions and [a['action'] for a in actions[-3:]] == ['open', 'copy', 'reveal'] and all(urllib.parse.unquote(urllib.parse.urlparse(a['url']).path) == paths[1] for a in actions[-3:]), actions=actions)
        def opened():
            try: return json.loads(opened_file.read_text())
            except (OSError, ValueError): return None
        document = wait(opened)
        expected_hash = hashlib.sha256((b'Open download.\n' + b'x' * (16384 - 15)) * 8).hexdigest()
        check('open_file', document and document.get('bytes') == 131072 and document.get('sha256') == expected_hash
              and Path(urllib.parse.unquote(urllib.parse.urlparse(document.get('url', '')).path)).resolve() == Path(paths[1]).resolve(), receipt=document, error=state()['error'])
        if document and document.get('pid'):
            app.owned_processes[document['pid']] = str(executable.resolve())
        copied = state().get('copiedFileURL', '')
        check('copy_file_url', urllib.parse.unquote(urllib.parse.urlparse(copied).path) == paths[1], copied=copied)
        menu(fast2, 'Hide from Open')
        check('hide', wait(lambda: not item(fast2)) and Path(paths[1]).exists())
        menu(fast, 'Move to Trash')
        check('trash', wait(lambda: not item(fast)) and not Path(paths[0]).exists())
        dismiss_library()


    def fallback_flow():
        before = state()['fallbacks']
        path = None
        try:
            app.call('download-settings', profile=profile, directory=str(root / 'missing-folder'), ask=False)
            download = start('/fallback')
            wait(lambda: item(download).get('fileExists'))
            value = item(download)
            path = Path(value['path'])
            check('missing_folder_fallback', path.parent == root / 'DefaultDownloads' and state()['fallbacks'] == before + 1, item=value, fallbacks=state()['fallbacks'])
        finally:
            app.call('download-settings', profile=profile, directory=str(first), ask=False)
            if path and path.parent == root / 'DefaultDownloads' and path.name.startswith('open-e2e-fallback-%d' % os.getpid()):
                path.unlink(missing_ok=True)


    def profiles_flow():
        nonlocal tab
        # Distinct Profile settings, same suggested filename, separate destination.
        space1 = next(v['id'] for v in app.call('spaces') if v['focused'])
        app.call('space-create', title='Second', profile='Downloads Second')
        profile2 = next(v['profile'] for v in app.call('spaces') if v['focused'])
        second = root / 'second'; second.mkdir()
        app.call('download-settings', profile=profile2, directory=str(second), ask=False)
        tab = E.new_tab(app, base + '/')
        other = start('/fast'); wait(lambda: item(other).get('fileExists'))
        check('profile_folder', item(other).get('profile') == profile2 and Path(item(other)['path']).parent == second, item=item(other))
        app.call('space', space=space1); tab = E.new_tab(app, base + '/')


    def badge_flow():
        for reduced in (False, True):
            app.call('window-motion', reduced=reduced)
            finishing = start('/finish')
            before = state()['badge'].get('completions', 0)
            animation = wait(lambda: (lambda v: v if v['badge'].get('completing') else None)(state()))
            ended = wait(lambda: (lambda v: v if v['badge'].get('completions', 0) > before and not v['badge'].get('completing') and v['badge'].get('animations') == 0 else None)(state()))
            check('completion_reduced' if reduced else 'completion_motion', animation and ended and animation['badge']['ringFadeDuration'] == .8 and animation['badge']['homeDuration'] == 1.45 and bool(animation['badge']['spring']) != reduced and item(finishing).get('state') == 'completed', during=animation and animation['badge'], after=ended and ended['badge'])
        app.call('library-open', section='archive')
        app.call('download-home')
        closed = wait(lambda: not app.call('library-state').get('open'))
        app.call('download-home')
        opened = wait(lambda: (lambda s: s if s.get('open') and s.get('section') == 'downloads' and s.get('rows') else None)(app.call('library-state')))
        check('home_recent_entry', bool(closed and opened) and app.call('settings-state')['librarySection'] == 'downloads', native=opened, toggledClosed=bool(closed))
        dismiss_library()
        original_window = app.call('shell-windows')[0]['id']
        app.call('command', id='new-window')
        new_window = next(v['id'] for v in app.call('shell-windows') if v['id'] != original_window)
        app.call('window-focus', id=new_window, activate=True)
        app.call('library-open', section='archive')
        app.call('download-home')
        closed = wait(lambda: not app.call('library-state').get('open'))
        app.call('download-home')
        opened = wait(lambda: (lambda s: s if s.get('open') and s.get('section') == 'downloads' and s.get('rows') else None)(app.call('library-state')))
        check('home_recent_new_window', bool(closed and opened) and opened['windowID'] == new_window and app.call('settings-state')['librarySection'] == 'downloads', native=opened, toggledClosed=bool(closed))
        dismiss_library()
        app.call('window-focus', id=new_window, activate=True)
        app.call('window-close')
        app.call('window-focus', id=original_window, activate=True)
        app.call('library-open', section='archive')
        app.call('key', key='j', modifiers=['cmd', 'shift'])
        check('shortcut', wait(lambda: app.call('settings-state')['librarySection'] == 'downloads'))
        dismiss_library()

        # S8's native observer: real timer canary, then a settled interval
        # with zero Home draw/layout/display/invalidations/queue work and no
        # owned timers/display links or CA animation keys.
        if lane != "merge":
            app.call('download-idle', action='begin')
            canary = app.call('download-idle', action='canary')
            check('idle_observer_canary', canary['live'] > 0 and canary['after'] == 0, canary=canary)
            time.sleep(.4); app.call('download-idle', action='reset')
            before = state(); t0 = time.monotonic(); time.sleep(2)
            counts = app.call('download-idle'); after = state()
            check('idle_zero', counts == [0] * 10 and before['publishes'] == after['publishes'] and after['badge']['animations'] == 0 and after['badge']['trackOpacity'] == 0 and after['badge']['ringOpacity'] == 0 and after['badge']['checkOpacity'] == 0 and after['badge']['homeOpacity'] == 1 and not after['queued'], counts=counts, elapsed=time.monotonic()-t0, load=os.getloadavg(), publishes=[before['publishes'], after['publishes']])
            app.call('download-idle', action='end')



    def history_flow():
        nonlocal app, tab, retry_result
        home_space = next(v['id'] for v in app.call('spaces') if v['focused'])
        normal_window = next(v for v in app.call('incognito-state')['windows'] if not v['private'])
        library()
        if len(app.call('profiles-shell')['profiles']) == 1:
            check('history_single_profile_filter_hidden', not state()['profileFilter'])
        dismiss_library()

        # Real completed, cancelled and failed transfers in the first Profile.
        completed = start('/fast?history=completed')
        wait(lambda: item(completed).get('fileExists'))
        old = start('/fast?history=old'); wait(lambda: item(old).get('fileExists'))
        app.call('download-start-age', id=old, seconds=7200)
        failed = start('/fail?history=failed'); wait(lambda: item(failed).get('state') == 'failed', 30)
        cancelled = start('/slow?history=cancelled'); library()
        wait(lambda: 'Cancel' in row(cancelled).get('buttons', []))
        app.call('download-row', id=cancelled, action='Cancel')
        wait(lambda: item(cancelled).get('state') == 'cancelled')
        dismiss_library()
        before_first = {key: item(key) for key in (completed, old, failed, cancelled)}

        app.call('space-create', title='History Second', profile='History Second')
        profile2 = next(v['profile'] for v in app.call('spaces') if v['focused'])
        second = root / 'history-second'; second.mkdir()
        app.call('download-settings', profile=profile2, directory=str(second), ask=False)
        tab = E.new_tab(app, base + '/')
        other = start('/fast?history=second'); wait(lambda: item(other).get('fileExists'))
        before_second = item(other)
        check('history_two_profile_downloads', before_second.get('profile') == profile2
              and all(v.get('profile') == profile for v in before_first.values()), first=before_first, second=before_second)

        # Private download uses the real Incognito menu and engine. It must finish
        # on disk without publishing a regular row or writing either Profile store.
        app.call('menu-perform', id='new-incognito-window')
        private = wait(lambda: next((v for v in app.call('incognito-state')['windows'] if v['private']), None))
        if not private: raise RuntimeError('history private window missing')
        try:
            app.call('window-focus', id=private['id'], activate=True)
            private_tab = E.new_tab(app, base + '/')
            private_dir = root / 'history-private'; private_dir.mkdir()
            app.call('download-dir', path=str(private_dir))
            app.eval(private_tab, 'document.body.innerHTML = \'<a id="private-download" href="/private?history=private">Download</a>\'')
            app.call('click', tab=private_tab, selector='#private-download')
            private_file = private_dir / 'private-history.txt'
            private_complete = wait(lambda: private_file.exists() and private_file.stat().st_size == 131072)
            check('history_private_transfer', private_complete)
        finally:
            app.call('window-focus', id=private['id'], activate=True); app.call('window-close')
            app.call('window-focus', id=normal_window['id'], activate=True)

        def stored_rows():
            app.call('download-history-flush')
            records = []
            for path in Path(app.user_data).glob('Profiles/*/State/downloads.sqlite3'):
                with contextlib.closing(sqlite3.connect('file:' + str(path) + '?mode=ro', uri=True)) as db:
                    records += [json.loads(v[0]) for v in db.execute('SELECT payload FROM downloads')]
            return records
        disk = stored_rows()
        required = set(before_first) | {other}
        check('history_terminal_store', required <= {r['id'] for r in disk}
              and all(r['endedAt'] >= r['startedAt'] and r['sourceURL'] and r['profileID'] for r in disk), rows=disk)
        check('history_private_absent_store', not any('private-history' in json.dumps(v) or 'history=private' in json.dumps(v) for v in disk))

        def restart(expected_ids):
            nonlocal app, tab
            dismiss_library()
            app.call('download-policy', quit='close')
            app.activation_trace = app.call('activation-events')
            app.call('quit')
            if not wait(lambda: not app.process_path(app.pid), 15): raise RuntimeError('history clean quit did not finish')
            app.quit()
            app = factory(urls=(), fresh=False, extra_env=launch_env)
            app.preferences_domain = domain
            app.call('download-policy', quit='keep', recordFiles=True)
            # No launch history read: the first Library opening hydrates it.
            check('history_lazy_before_library_' + str(len([k for k in results if k.startswith('history_lazy_before_library_')])),
                  not state()['items'], items=state()['items'])
            app.call('command', id='view-downloads')
            def restored_expected():
                snapshot = state()
                rows = {v['id']: v for v in snapshot['items']}
                # Even an expected empty list must wait for the real lazy load
                # and its publication, never accept all([]) as restoration.
                return (snapshot['historyLoaded'] and not snapshot['queued']
                        and expected_ids <= rows.keys()
                        and all(rows[key]['historical'] for key in expected_ids))
            if not wait(restored_expected):
                raise RuntimeError('history relaunch did not restore expected IDs: ' + ', '.join(sorted(expected_ids)))

        restart(required)
        restored = {v['id']: v for v in state()['items']}
        check('history_relaunch_two_profiles', required <= set(restored)
              and len(restored) == len(state()['items']) and all(restored[k]['historical'] for k in required)
              and all(restored[k]['state'] == before_first[k]['state'] for k in before_first)
              and restored[other]['profile'] == profile2, items=list(restored.values()))
        # The in-window Library's Profile filter is a chip group in the filter editor (no "All Profiles" item:
        # pressing the selected chip clears the filter), not the retired Library window's pop-up.
        app.call('library', action='filter', open=True)
        chips = app.call('library')['header']['chips']
        app.call('library', action='filter', open=False)
        chip_ids = {c.get('id') for c in chips}
        check('history_profile_filter_menu', {'profile:' + profile, 'profile:' + profile2} <= chip_ids
              and any(c.get('title') == 'History Second' for c in chips), chips=chips)
        for selected, wanted in [(profile, set(before_first)), (profile2, {other})]:
            app.call('download-profile-filter', profile=selected)
            filtered = wait(lambda: wanted <= set(state()['visibleItems'])
                            and all(v['profile'] == selected for v in state()['items'] if v['id'] in state()['visibleItems']))
            check('history_profile_filter_' + ('first' if selected == profile else 'second'), filtered,
                  visible=state()['visibleItems'], filter=state()['profileFilter'])
        app.call('download-profile-filter', profile='all')
        check('history_profile_filter_all', required <= set(state()['visibleItems']))
        check('history_private_absent_relaunch', not any('history=private' in v['source'] for v in state()['items']))

        # Historical rows use the same native menu and real file opener as live rows.
        app.call('download-profile-filter', profile=profile2)
        wait(lambda: bool(row(other)) and item(other).get('fileExists'))
        app.call('download-policy', openApp=str(opener))
        titles = [v['title'] for v in menu(other)]
        action_count = len(state()['fileActions'])
        opened_file.unlink(missing_ok=True)
        for title in (titles[0], titles[1], 'Show in Finder'): menu(other, title)
        actions = wait(lambda: state()['fileActions'][action_count:] if len(state()['fileActions']) >= action_count + 3 else None)
        def receipt():
            try: return json.loads(opened_file.read_text())
            except (OSError, ValueError): return None
        opened = wait(receipt)
        if opened and opened.get('pid'): app.owned_processes[opened['pid']] = str(executable.resolve())
        check('history_open_copy_reveal', actions and [a['action'] for a in actions[:3]] == ['open', 'copy', 'reveal']
              and opened and opened.get('bytes') == 131072
              and urllib.parse.unquote(urllib.parse.urlparse(state()['copiedFileURL']).path) == before_second['path'], actions=actions, receipt=opened)

        Path(before_first[completed]['path']).unlink()
        # Every outside entry scopes Downloads to the window owner's Profile: filter after the Library reopens.
        dismiss_library(); library()
        app.call('download-profile-filter', profile=profile)
        missing = wait(lambda: row(completed).get('subtitle') == 'File moved or deleted.')
        missing_menu = menu(completed)
        check('history_missing_file_safe', missing and all(not v['enabled'] for v in missing_menu[:3])
              and any(v['title'] == 'Hide from Open' and v['enabled'] for v in missing_menu), row=row(completed), menu=missing_menu)
        menu(completed, 'Hide from Open'); wait(lambda: not item(completed))

        # Retry must re-download its recorded URL under its original Profile. Since the native Library only a
        # failed row offers Retry (a hover control; Arc has none), so the historical failed row of the first
        # Profile is retried. "/fail" fails again by design: the receipt is a new transfer of the same URL.
        before_retry = set(v['id'] for v in state()['items'])
        before_retry_tabs = {v['id'] for v in app.call('tabs')}
        source = before_first[failed]['source']
        offered = wait(lambda: 'Retry' in row(failed).get('buttons', []))
        if offered: app.call('download-row', id=failed, action='Retry')
        dismiss_library()
        retried = wait(lambda: next((v for v in state()['items'] if v['id'] not in before_retry and v['source'] == source), None), 30)
        # Publish it last so a Retry failure cannot prevent independent history/quit checks.
        retry_result = dict(ok=bool(offered and retried and retried['profile'] == profile), item=retried, offered=bool(offered),
              items=state()['items'], tabs=app.call('tabs'), sheets=state()['sheets'],
              detachedPages=state()['detachedPages'], engineEvents=app.call('events'),
              reason='' if retried else 'no new transfer of the recorded URL after Retry')
        # Preserve the raw assertion even if a later independent check fails.
        # The normal checked assignment at the end still fails the suite.
        dict.__setitem__(results, 'history_retry', retry_result)
        for new_tab in app.call('tabs'):
            if new_tab['id'] not in before_retry_tabs: app.call('close', tab=new_tab['id'])
        survivor = None
        if survivor is None:
            # A real completed transfer is the independent second-Profile
            # survivor for clear/retirement checks. It is never counted as Retry.
            app.call('space', space=next(s['id'] for s in app.call('spaces') if s['profile'] == profile2))
            tab = E.new_tab(app, base + '/')
            control = start('/fast?history=retention-control')
            survivor = wait(lambda: item(control) if item(control).get('state') == 'completed' else None)
            check('history_retention_control', survivor and survivor['profile'] == profile2
                  and Path(survivor['path']).exists(), item=survivor)
            if not survivor: raise RuntimeError('independent history retention transfer did not complete')
        library(); wait(lambda: bool(row(other))); menu(other, 'Move to Trash')
        check('history_trash', wait(lambda: not item(other)) and not Path(before_second['path']).exists())

        # Last hour removes recent terminals only; the old first-Profile row and
        # all second-Profile rows survive. Then All time removes the old row too.
        response = app.call('settings-clear-data', profile=profile, kinds=8, range='Last hour')
        wait(lambda: all(not item(k) for k in (failed, cancelled)))
        check('history_clear_range', response['status'] == 'Done' and bool(item(old))
              and bool(survivor and item(survivor['id'])), response=response)
        restart({old, survivor['id']})
        check('history_remove_clear_persist', not any(item(k) for k in (completed, failed, cancelled, other))
              and bool(item(old)) and bool(survivor and item(survivor['id'])), items=state()['items'])
        response = app.call('settings-clear-data', profile=profile, kinds=8, range='All time')
        restart({survivor['id']})
        check('history_clear_all_persist', response['status'] == 'Done'
              and not any(v['profile'] == profile for v in state()['items'])
              and bool(survivor and item(survivor['id'])), items=state()['items'])

        # The real typed Settings deletion closes the owner before removing its
        # directory. Opening Library and quitting again must not recreate it.
        dismiss_library(); app.call('space', space=home_space)
        profile_row = next(p for p in app.call('profiles-shell')['profiles'] if p['id'] == profile2)
        profile_dir = Path(app.user_data) / 'Profiles' / profile_row['directory']
        # Settings offers Delete Profile only for a Profile with no Spaces: move the second
        # Space to Default first (the same path as boost_profile_retirement.py).
        for space in [v for v in app.call('spaces') if v['profile'] == profile2]:
            assert app.call('space-profile', space=space['id'], profile='Default')
            E._try(lambda: app.call('alert', button='Change Profile'))
        wait(lambda: next(p for p in app.call('profiles-shell')['profiles'] if p['id'] == profile2)['spaces'] == 0)
        # Settings shows a Profile by name; its SwiftUI controls install a moment later.
        app.call('profiles-shell', action='show', profile=profile_row['name'])
        # A first Settings visit can attach the search-suggestions notice; answer it.
        if wait(lambda: 'Got it' in (app.call('profiles-shell').get('sheetText') or []) or None, 2):
            app.call('profiles-shell', action='press', label='Got it')
            wait(lambda: app.call('profiles-shell')['sheet'] == 0 or None, 5)
        try:
            def press_delete():
                try:
                    app.press_profile_delete(); return True
                except RuntimeError:
                    return None
            if not wait(press_delete, 5):
                shell = app.call('profiles-shell')
                print('history_profile_deletion diagnostic:', json.dumps({k: shell.get(k) for k in ('settings', 'sheet', 'sheetText', 'selected', 'profiles')})[:1500], flush=True)
                raise RuntimeError('Delete Profile control did not appear')
            wait(lambda: app.call('profiles-shell')['sheet'] > 0)
            app.call('profiles-shell', action='type-delete', text='History Second')
            app.call('profiles-shell', action='press', label='Delete')
            deleted = wait(lambda: not app.call('profiles-shell')['deleting']
                           and all(p['id'] != profile2 for p in app.call('profiles-shell')['profiles']))
            check('history_profile_deletion', deleted and not profile_dir.exists()
                  and not any(v['profile'] == profile2 for v in state()['items']))
        finally:
            app.call('profiles-shell', action='cancel')
            settings_window = app.call('profiles-shell')['settings']
            if settings_window:
                E._try(lambda: app.call('key', window=settings_window, key='w', modifiers=['cmd'], route='app'))
        restart(set())
        check('history_profile_deletion_persists', not profile_dir.exists()
              and not any(v['profile'] == profile2 for v in state()['items']))
        dismiss_library(); app.call('space', space=home_space)
        tab = E.new_tab(app, base + '/')

    def history_errors_flow():
        nonlocal app, tab
        dismiss_library()
        tab = E.new_tab(app, base + '/')
        seed_download = start('/fast?history=limits'); wait(lambda: item(seed_download).get('fileExists'))
        profile_row = next(p for p in app.call('profiles-shell')['profiles'] if p['id'] == profile)
        path = Path(app.user_data) / 'Profiles' / profile_row['directory'] / 'State/downloads.sqlite3'

        def stop():
            dismiss_library(); app.call('download-history-flush'); app.call('download-policy', quit='close')
            app.activation_trace = app.call('activation-events'); app.call('quit')
            if not wait(lambda: not app.process_path(app.pid), 15): raise RuntimeError('history boundary fixture quit did not finish')
            app.quit()

        def launch_and_check(name, count=None):
            nonlocal app
            app = factory(urls=(), fresh=False, extra_env=launch_env); app.preferences_domain = domain
            app.call('download-policy', quit='keep', recordFiles=True)
            app.call('command', id='view-downloads')
            observed = wait(lambda: state() if (state()['historyError'] if count is None else
                                               len([v for v in state()['items'] if v['profile'] == profile]) == count) else None)
            owned = [v for v in state()['items'] if v['profile'] == profile]
            check(name, observed and (bool(state()['historyError']) and not owned if count is None else not state()['historyError'] and len(owned) == count),
                  count=len(owned), error=state()['historyError'])

        stop()
        check('history_store_private_permissions', path.stat().st_mode & 0o777 == 0o600)
        with contextlib.closing(sqlite3.connect(path)) as db, db:
            template = json.loads(db.execute('SELECT payload FROM downloads WHERE id=?', (seed_download,)).fetchone()[0])

        def seed(count):
            # Synthetic on-disk fixture from a real engine download. Only change
            # the disposable root while Open is stopped; the real Library reads it.
            with contextlib.closing(sqlite3.connect(path)) as db, db:
                db.execute('DELETE FROM downloads')
                for i in range(count):
                    record = dict(template, id='history-boundary-%04d' % i,
                                  startedAt=template['startedAt'] - i, endedAt=template['endedAt'] - i)
                    db.execute('INSERT INTO downloads VALUES(?,?,?,?)',
                               (record['id'], record['startedAt'], record['endedAt'], json.dumps(record)))

        try:
            seed(1000); launch_and_check('history_count_at_limit', count=1000)
            dismiss_library(); tab = E.new_tab(app, base + '/')
            newest = start('/fast?history=prune'); wait(lambda: item(newest).get('fileExists'))
            app.call('download-history-flush')
            with contextlib.closing(sqlite3.connect('file:' + str(path) + '?mode=ro', uri=True)) as db:
                ids = {r[0] for r in db.execute('SELECT id FROM downloads')}
            check('history_newest_1000_pruned', len(ids) == 1000 and newest in ids and 'history-boundary-0999' not in ids, count=len(ids))
            stop()
            seed(1001); launch_and_check('history_count_over_limit_loads_newest', count=1000)
            check('history_over_count_oldest_omitted', not item('history-boundary-1000')
                  and bool(item('history-boundary-0000')) and bool(item('history-boundary-0999')))
            dismiss_library(); tab = E.new_tab(app, base + '/')
            recovered = start('/fast?history=over-count-recovery'); wait(lambda: item(recovered).get('fileExists'))
            app.call('download-history-flush')
            with contextlib.closing(sqlite3.connect('file:' + str(path) + '?mode=ro', uri=True)) as db:
                ids = {r[0] for r in db.execute('SELECT id FROM downloads')}
            check('history_over_count_write_recovers', len(ids) == 1000 and recovered in ids
                  and 'history-boundary-0999' not in ids and 'history-boundary-1000' not in ids, count=len(ids))
            stop()
            seed(1)
            with contextlib.closing(sqlite3.connect(path)) as db, db: db.execute('UPDATE downloads SET payload=?', ('{"invalid":true}',))
            launch_and_check('history_corrupt_record_refused'); stop()
            seed(1)
            healthy = path.read_bytes()
            path.write_bytes(b'not a SQLite database\n')
            launch_and_check('history_corrupt_file_refused'); stop()
            with path.open('wb') as file: file.truncate(32 * 1024 * 1024 + 1)
            launch_and_check('history_oversized_file_refused'); stop()
            path.write_bytes(healthy)
            launch_and_check('history_valid_file_restored', count=1)
        finally:
            # A failed assertion or interrupted App must still leave no fixture
            # process or oversized sparse file. The outer finally owns App cleanup.
            if app.closed and path.exists() and path.stat().st_size > 32 * 1024 * 1024:
                path.unlink()
        dismiss_library(); tab = E.new_tab(app, base + '/')

    def quit_flow():
        nonlocal app, tab
        # Earlier history cases relaunch without preference arguments. Start
        # this case explicitly with YES, then restore with NO for the second pass.
        dismiss_library(); app.call('download-policy', quit='close')
        app.activation_trace = app.call('activation-events'); app.call('quit')
        if not wait(lambda: not app.process_path(app.pid), 15): raise RuntimeError('quit fixture setup did not finish')
        app.quit()
        app = factory(urls=(), fresh=False, extra_env=launch_env,
                      extra_args=['-open.general.warnBeforeQuitting', 'YES'])
        app.preferences_domain = domain
        tab = E.new_tab(app, base + '/')
        for warn in (True, False):
            running = start('/slow'); wait(lambda: item(running).get('received', 0) > 0)
            app.call('download-policy', quit='keep')
            before_quit = item(running)['received']; count = len(state()['quitAlerts'])
            app.call('quit')
            alerts = wait(lambda: state()['quitAlerts'] if item(running).get('received', 0) > before_quit and len(state()['quitAlerts']) > count else None)
            check('quit_keep_warn_%s' % str(warn).lower(), alerts and alerts[-1] == {'title': 'Downloads in progress', 'body': 'There are downloads in progress. Closing the application will cancel them.', 'buttons': ['Close Open', 'Keep browsing']} and item(running)['state'] == 'inProgress', alerts=alerts)
            before_close = item(running)
            app.call('download-policy', quit='close')
            app.activation_trace = app.call('activation-events')
            # No download-history-flush: only AppDelegate's approved-quit path
            # can save this in-progress transfer as a persisted cancellation.
            app.call('quit')
            exited = wait(lambda: not app.process_path(app.pid), 15)
            app.quit()
            check('quit_close_warn_%s' % str(warn).lower(), exited)
            app = factory(urls=(), fresh=False, extra_env=launch_env,
                          extra_args=['-open.general.warnBeforeQuitting', 'NO'])
            app.preferences_domain = domain
            app.call('download-policy', quit='keep')
            app.call('command', id='view-downloads')
            restored = wait(lambda: item(running) if item(running).get('historical') else None)
            check('quit_cancel_persisted_warn_%s' % str(warn).lower(), restored
                  and restored['state'] == 'cancelled' and restored['profile'] == before_close['profile']
                  and restored['source'] == before_close['source'], item=restored)
            dismiss_library()
            if warn: tab = E.new_tab(app, base + '/')
        # The restoration check leaves a live App with no active transfer.
        app.activation_trace = app.call('activation-events'); app.call('quit')
        if not wait(lambda: not app.process_path(app.pid), 15): raise RuntimeError('quit restoration cleanup did not finish')
        app.quit()
        app = factory(urls=(), fresh=True, extra_env=launch_env)
        app.preferences_domain = domain
        app.call('download-policy', quit='record')
        empty = state()
        app.activation_trace = app.call('activation-events')
        app.call('quit')
        no_alert_exit = wait(lambda: not app.process_path(app.pid), 15)
        app.quit()
        check('quit_empty', not empty['running'] and not empty['quitAlerts'] and no_alert_exit)

    def generic_quit_flow():
        nonlocal app, tab
        key = 'open.general.warnBeforeQuitting'

        def relaunch():
            nonlocal app
            app = factory(urls=(), fresh=True, extra_env=launch_env)
            app.preferences_domain = domain
            app.call('download-policy', quit='keep')

        def request(button):
            app.call('quit-warning', button=button, request=True)

        def exited():
            return wait(lambda: not app.process_path(app.pid), 15)

        def generic_alerts():
            return Path(app.launch_log_path).read_text(errors='replace').count('generic-quit-alert-presented')

        def download_alerts():
            return Path(app.launch_log_path).read_text(errors='replace').count('downloads-quit-alert-presented')

        def stable_snapshot(value):
            # Native modal focus can update usage timestamps without changing a tab/window.
            if isinstance(value, dict):
                return {k: stable_snapshot(v) for k, v in value.items() if k not in ('lastActiveAt', 'lastFocusedAt')}
            if isinstance(value, list):
                return [stable_snapshot(v) for v in value]
            return value

        def tab_ids(value):
            if isinstance(value, dict):
                own = {value['id']} if {'id', 'url', 'createdAt'} <= value.keys() else set()
                return own.union(*(tab_ids(v) for v in value.values()))
            if isinstance(value, list):
                return set().union(*(tab_ids(v) for v in value))
            return set()

        # Real menu-command quit, native NSAlert buttons, two browser windows.
        if app.closed:
            relaunch()
            tab = E.new_tab(app, base + '/')
        app.call('defaults', key=key, value=True)
        app.call('command', id='new-window')
        windows_before = app.call('shell-windows')
        snapshot_before = stable_snapshot(json.loads(Path(app.call('save')).read_text()))
        before = generic_alerts()
        request('cancel')
        cancelled = wait(lambda: not app.process_path(app.pid) or E._try(lambda: app.call('quit-warning')))
        if not app.process_path(app.pid):
            app.quit()
            check('generic_quit_cancel', False, reason='App exited instead of presenting a cancellable warning', quit=app.quit_report)
            return
        snapshot_after = stable_snapshot(json.loads(Path(app.call('save')).read_text()))
        check('generic_quit_cancel', cancelled and generic_alerts() == before + 1
              and app.call('shell-windows') == windows_before and snapshot_before == snapshot_after
              and cancelled[-1]['windows'] == len(windows_before)
              and cancelled[-1]['tabs'] == len(tab_ids(snapshot_before)) >= 1
              and cancelled[-1]['title'] == 'Quit Open?' and cancelled[-1]['buttons'] == ['Quit', 'Cancel']
              and cancelled[-1]['keys'] == ['\r', '\x1b'], alerts=cancelled,
              windowsBefore=windows_before, windowsAfter=app.call('shell-windows'), snapshotIntact=snapshot_before == snapshot_after)

        # Accepted approval survives async history/sleep/engine shutdown retries.
        request('quit')
        clean_exit = exited()
        alerts = generic_alerts()
        app.quit()
        check('generic_quit_accept', clean_exit and alerts == before + 2 and not app.quit_report['forced'],
              alerts=alerts - before, quit=app.quit_report)

        relaunch()
        app.call('defaults', key=key, value=False)
        request('cancel')  # A broken always-on prompt would cancel this quit.
        immediate = exited()
        alerts = generic_alerts()
        app.quit()
        check('generic_quit_off', immediate and alerts == 0 and not app.quit_report['forced'], alerts=alerts, quit=app.quit_report)

        # A quit Apple event from another process (a script, the Dock, the release smoke) does
        # not get the generic alert, even with the setting on: the process is gone within 5 s.
        relaunch()
        app.call('defaults', key=key, value=True)
        sender = quit_event_sender()
        sent = time.monotonic()
        delivered = subprocess.run([sender, str(app.pid)]).returncode == 0
        gone = wait(lambda: not app.process_path(app.pid), 5)
        seconds = round(time.monotonic() - sent, 2)
        alerts = generic_alerts()
        app.quit()
        check('generic_quit_apple_event', delivered and bool(gone) and seconds <= 5 and alerts == 0
              and not app.quit_report['forced'], seconds=seconds, alerts=alerts, quit=app.quit_report)

        relaunch()
        app.call('defaults', key=key, value=True)
        tab = E.new_tab(app, base + '/')
        profile_id = next(v['profile'] for v in app.call('spaces') if v['focused'])
        app.call('download-settings', profile=profile_id, directory=str(first), ask=False)
        running = start('/slow')
        wait(lambda: item(running).get('received', 0) > 0)
        app.call('download-policy', quit='keep')
        request('cancel')
        kept = wait(lambda: state()['quitAlerts'])
        check('generic_quit_downloads_keep_one', kept and len(kept) == 1 and generic_alerts() == 0
              and download_alerts() == 1 and item(running)['state'] == 'inProgress', alerts=kept, genericAlerts=generic_alerts())
        app.call('download-policy', quit='close')
        request('cancel')  # A stacked generic alert would keep the App alive.
        download_exit = exited()
        alerts = [download_alerts(), generic_alerts()]
        app.quit()
        check('generic_quit_downloads_close_one', download_exit and alerts == [2, 0] and not app.quit_report['forced'],
              alerts=alerts, quit=app.quit_report)

        # Review R1 finding 1: an approved attempt that a page's beforeunload "Stay" ends
        # must not leave the next quit prompt-free. Close Open, Stay, new download, quit:
        # the downloads alert must appear again.
        relaunch()
        app.call('defaults', key=key, value=True)
        tab = E.new_tab(app, base + '/')
        profile_id = next(v['profile'] for v in app.call('spaces') if v['focused'])
        app.call('download-settings', profile=profile_id, directory=str(first), ask=False)
        armed = E.new_tab(app, base + '/arm')
        app.call('wait', tab=armed)
        try:
            app.call('click', tab=armed, selector='#arm')  # beforeunload needs a user activation
            running = start('/slow')
            wait(lambda: item(running).get('received', 0) > 0)
            app.call('download-policy', quit='close')
            downloads_before = download_alerts()
            request('quit')
            def dialog_visible():
                return bool((E._try(lambda: app.call('dialog-state')) or {}).get('visible'))
            stay = wait(lambda: dialog_visible() or None, 10)
            if stay: app.call('dialog-button', accept=False)
            survived = wait(lambda: (not dialog_visible() and bool(app.process_path(app.pid))) or None, 5)
            again = start('/slow')
            wait(lambda: item(again).get('received', 0) > 0)
            app.call('download-policy', quit='keep')
            request('cancel')
            asked_again = wait(lambda: download_alerts() >= downloads_before + 2 or None, 10)
            check('generic_quit_stay_then_requit', bool(stay) and bool(survived) and bool(asked_again)
                  and item(again).get('state') == 'inProgress' and app.process_path(app.pid),
                  stay=bool(stay), survived=bool(survived), downloadAlerts=download_alerts() - downloads_before,
                  again=item(again))
        finally:
            # Leave no page or quit prompt behind (review checklist §4).
            E._try(lambda: app.call('dialog-button', accept=False) if (app.call('dialog-state') or {}).get('visible') else None)
            E._try(lambda: app.eval(armed, 'onbeforeunload=null;true'))
            E._try(lambda: app.call('download-policy', quit='close'))
            app.quit()

        # The harness must still exit with the setting on and no alert policy.
        relaunch()
        app.call('defaults', key=key, value=True)
        app.quit()
        check('generic_quit_harness_bypass', not app.quit_report['forced'] and generic_alerts() == 0,
              quit=app.quit_report, alerts=generic_alerts())

    def clear_flow():
        nonlocal tab
        original_space = next(s['id'] for s in app.call('spaces') if s['focused'])
        app.call('space-create', profile='Clear downloads other', title='Clear downloads other')
        other_profile = next(s['profile'] for s in app.call('spaces') if s['focused'])
        other_tab = E.new_tab(app, base + '/')
        app.call('download-settings', profile=other_profile, directory=str(first), ask=False)
        other = start('/fast', other_tab); wait(lambda: item(other).get('state') == 'completed')
        app.call('space', space=original_space)
        tab = E.new_tab(app, base + '/')
        running = start('/slow'); paused = start('/slow')
        library(); wait(lambda: bool(row(paused)))
        app.call('download-row', id=paused, action='Pause')
        wait(lambda: item(paused).get('state') == 'paused')
        for label, seconds in [('Last hour', 3600), ('Last 24 hours', 86400), ('Last 7 days', 604800), ('Last 4 weeks', 2419200), ('All time', None)]:
            dismiss_library()
            inside = start('/fast'); outside = start('/fast')
            failed = start('/fail'); cancelled = start('/slow')
            library()
            # Under load the row can appear before its live Cancel control: wait for
            # the actual button the user would press (the row's own identifiers).
            ready = wait(lambda: 'Cancel' in row(cancelled).get('buttons', []))
            if not ready:
                check('clear_cancel_button_' + label, False, item=item(cancelled), row=row(cancelled),
                      running=state()['running'], sheets=state()['sheets'],
                      downloadState=state(), sourcePage=app.page(tab))
                raise RuntimeError('clear fixture has no live Cancel button: ' + json.dumps(item(cancelled)))
            app.call('download-row', id=cancelled, action='Cancel')
            if not wait(lambda: all(item(k).get('state') == s for k, s in [(inside, 'completed'), (outside, 'completed'), (failed, 'failed'), (cancelled, 'cancelled')])):
                raise RuntimeError('terminal download fixture did not finish')
            for k in (inside, failed, cancelled): app.call('download-start-age', id=k, seconds=(seconds / 2 if seconds else 600))
            app.call('download-start-age', id=outside, seconds=(seconds * 2 if seconds else 20 * 86400))
            paths = [Path(item(k)['path']) for k in (inside, outside, other)]
            hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
            before_items = state()['items']
            before = {v['id'] for v in before_items}
            history_before = app.call('history-state', profile=profile)['rows']
            invalid = app.call('settings-clear-data', profile=profile, kinds=0, range=label)
            check('clear_validate_before_mutation_' + label, invalid['status'] != 'Done'
                  and {v['id'] for v in state()['items']} == before
                  and app.call('history-state', profile=profile)['rows'] == history_before, response=invalid)
            response = app.call('settings-clear-data', profile=profile, kinds=(15 if seconds is None else 8), range=label)
            removed = {v['id'] for v in before_items if v['profile'] == profile
                       and v['state'] in ('completed', 'failed', 'cancelled')
                       and (seconds is None or time.time() - v['startedAt'] <= seconds)}
            cleared = wait(lambda: not (removed & {v['id'] for v in state()['items']})
                           and not (removed & {v['id'] for v in state()['rows']}))
            retained = {v['id']: v for v in state()['items']}
            check('clear_downloads_' + label, response['status'] == 'Done' and cleared
                  and set(retained) == before - removed
                  and retained.get(running, {}).get('state') == 'inProgress'
                  and retained.get(paused, {}).get('state') == 'paused' and other in retained
                  and (seconds is None or outside in retained)
                  and all(p.exists() and hashlib.sha256(p.read_bytes()).hexdigest() == hashes[str(p)] for p in paths),
                  response=response, removed=sorted(removed), retained=sorted(retained), files=hashes)
            if seconds is None:
                check('clear_combined_history_downloads', bool(history_before) and not app.call('history-state', profile=profile)['rows'] and other in retained,
                      historyBefore=len(history_before))
        app.call('download-row', id=running, action='Cancel')
        app.call('download-row', id=paused, action='Cancel')
        wait(lambda: not state()['running'])
        dismiss_library()


    try:
        # The cloned bundle starts with a unique empty preferences domain.
        # Quit preference variants use transient launch arguments, no defaults writes.
        app.call('download-policy', quit='keep', recordFiles=True)
        with server() as base:
            tab = E.new_tab(app, base + '/')
            profile = next(v['profile'] for v in app.call('spaces') if v['focused'])
            first = root / 'first'; first.mkdir()
            sentinel = first / 'sample.txt'; sentinel.write_text('do not overwrite')
            app.call('download-settings', profile=profile, directory=str(first), ask=False)
            flows = {"controls": controls_flow, "files": files_flow, "save": save_flow,
                     "profiles": profiles_flow, "fallback": fallback_flow, "badge": badge_flow, "clear": clear_flow,
                     "history": history_flow, "history-errors": history_errors_flow, "quit": quit_flow,
                     "generic-quit": generic_quit_flow}
            selection = os.environ.get('OPEN_DOWNLOADS_CASE', '')
            selected = {'badge'} if lane == 'observers' else set(selection.split(',')) if selection else set(flows)
            flows['cancel-sheet'] = cancel_sheet_flow
            if selected - set(flows):
                raise RuntimeError('unknown Downloads diagnostic case: ' + selection)
            for name, flow in flows.items():
                if name in selected:
                    flow()
            if retry_result is not None:
                check('history_retry', **retry_result)
                if not retry_result['ok']:
                    raise RuntimeError('historical Retry did not complete a new transfer')
    finally:
        if not app.closed:
            E._try(lambda: app.call('profiles-shell', action='cancel'))
            E._try(lambda: app.call('download-policy', quit='close'))
            for sheet in E._try(lambda: state()['sheets']) or []:
                E._try(lambda: app.call('download-save', id=sheet['id'], action='cancel'))
        if not app.closed:
            pid = E._try(lambda: state()['openerPID']) or 0
            if pid > 0: app.owned_processes[pid] = str(executable.resolve())
        app.quit()
