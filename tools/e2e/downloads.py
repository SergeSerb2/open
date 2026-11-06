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
import subprocess
import threading
import time
import tempfile
import urllib.parse


@contextlib.contextmanager
def server():
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_): pass
        def do_GET(self):
            route = self.path.split('?', 1)[0]
            if route == '/':
                body = b'<!doctype html><title>Downloads fixture</title><body>Downloads fixture</body>'
                self.send_response(200); self.send_header('Connection', 'close'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
            unknown = route == '/unknown'
            slow = route in ('/slow', '/unknown', '/finish')
            count = 64 if route == '/finish' else 2048 if slow else 8
            length = count * 16384
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            name = 'open-e2e-fallback-%d.txt' % os.getpid() if route == '/fallback' else 'sample.txt'
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
    httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    httpd.daemon_threads = True
    thread = threading.Thread(target=httpd.serve_forever, daemon=True); thread.start()
    try: yield 'http://127.0.0.1:%d' % httpd.server_port
    finally: httpd.shutdown(); httpd.server_close(); thread.join(5)


def checks(factory, results, tmp, config, harness):
    E = harness
    root = Path(tempfile.mkdtemp(prefix="downloads-attempt-", dir=tmp))
    probe = root / 'idle-probe.dylib'
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
    app = factory(urls=(), extra_env=launch_env)
    app.preferences_domain = domain
    saved = {}
    def state(): return app.call('downloads-state')
    def item(key): return next((v for v in state()['items'] if v['id'] == key), {})
    def row(key): return next((v for v in state()['rows'] if v['id'] == key), {})
    def wait(predicate, seconds=15): return E.wait_until(predicate, timeout=seconds, step=.05)
    def check(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('downloads %-26s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
    def menu(key, select=None):
        return app.call('download-menu', id=key, **({'select': select} if select else {}))
    def start(route):
        before = {v['id'] for v in state()['items']}
        app.call('select', tab=tab)
        app.eval(tab, '(() => {let a=document.createElement("a"); a.href=%s; a.id="download"; a.textContent="download";document.body.replaceChildren(a)})()' % json.dumps(base + route))
        app.call('click', tab=tab, selector='#download')
        value = wait(lambda: next((v for v in state()['items'] if v['id'] not in before), None))
        if not value: raise RuntimeError('download callback missing for ' + route)
        return value['id']
    def library():
        app.call('command', id='view-downloads')
        wait(lambda: bool(state()['rows']))
    def dismiss_library(): E._try(lambda: app.call('download-library-close'))
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


    def controls_flow():
        known = start('/slow')
        live = wait(lambda: (lambda v: v if v.get('received', 0) > 0 and v.get('total', 0) else None)(item(known)))
        library()
        running = wait(lambda: (lambda v: v if '/s · from 127.0.0.1' in v.get('subtitle', '') else None)(row(known)))
        check('live_subtitle', live and running and '/' in running['subtitle'].split(' · ')[0], item=live, row=running)
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
        app.call('library-open', section='archive')
        app.call('download-home')
        check('home_running_entry', app.call('settings-state')['librarySection'] == 'downloads')
        library()
        app.call('download-row', id=known, action='Cancel')
        check('cancel', wait(lambda: row(known).get('subtitle') == 'Cancelled'), row=row(known))
        dismiss_library()

        unknown = start('/unknown'); library()
        unknown_state = wait(lambda: (lambda v: v if v['badge'].get('indeterminate') and v['badge'].get('animations', 0) > 0 and item(unknown).get('received', 0) > 0 else None)(state()))
        check('unknown_total', unknown_state and item(unknown)['total'] is None and '/s · from ' in row(unknown).get('subtitle', ''), badge=unknown_state and unknown_state['badge'], row=row(unknown))
        menu(unknown, 'Cancel Download')
        check('menu_cancel', wait(lambda: row(unknown).get('subtitle') == 'Cancelled'))
        dismiss_library()
        failed = start('/fail'); library()
        check('failed_subtitle', wait(lambda: row(failed).get('subtitle') == 'Failed to Download', 30), item=item(failed), row=row(failed))
        dismiss_library()


    def files_flow():
        fast = start('/fast')
        wait(lambda: item(fast).get('fileExists'))
        fast2 = start('/fast'); wait(lambda: item(fast2).get('fileExists'))
        paths = [item(v).get('path') for v in (fast, fast2)]
        check('folder_unique', len(set(paths)) == 2 and all(Path(v).parent == first and Path(v).stat().st_size == 131072 for v in paths) and sentinel.read_text() == 'do not overwrite', paths=paths)
        library()
        completed = row(fast2)
        check('completed_subtitle', completed.get('subtitle', '').startswith('Completed · '), row=completed)
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
        check('home_recent_entry', app.call('settings-state')['librarySection'] == 'downloads')
        dismiss_library()
        original_window = app.call('shell-windows')[0]['id']
        app.call('command', id='new-window')
        new_window = next(v['id'] for v in app.call('shell-windows') if v['id'] != original_window)
        app.call('window-focus', id=new_window, activate=True)
        app.call('library-open', section='archive')
        app.call('download-home')
        check('home_recent_new_window', app.call('settings-state')['librarySection'] == 'downloads')
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
        app.call('download-idle', action='begin')
        canary = app.call('download-idle', action='canary')
        check('idle_observer_canary', canary['live'] > 0 and canary['after'] == 0, canary=canary)
        time.sleep(.4); app.call('download-idle', action='reset')
        before = state(); t0 = time.monotonic(); time.sleep(2)
        counts = app.call('download-idle'); after = state()
        check('idle_zero', counts == [0] * 10 and before['publishes'] == after['publishes'] and after['badge']['animations'] == 0 and after['badge']['trackOpacity'] == 0 and after['badge']['ringOpacity'] == 0 and after['badge']['checkOpacity'] == 0 and after['badge']['homeOpacity'] == 1 and not after['queued'], counts=counts, elapsed=time.monotonic()-t0, load=os.getloadavg(), publishes=[before['publishes'], after['publishes']])
        app.call('download-idle', action='end')


    def quit_flow():
        nonlocal app
        running = start('/slow'); wait(lambda: item(running).get('received', 0) > 0)
        app.call('download-policy', quit='keep')
        before_quit = item(running)['received']
        app.call('quit')
        alerts = wait(lambda: state()['quitAlerts'] if item(running).get('received', 0) > before_quit else None)
        check('quit_keep', alerts and alerts[-1] == {'title': 'Downloads in progress', 'body': 'There are downloads in progress. Closing the application will cancel them.', 'buttons': ['Close Open', 'Keep browsing']} and item(running)['state'] == 'inProgress', alerts=alerts)
        E._restore_defaults(app, saved); saved.clear()
        app.call('download-policy', quit='close')
        app.activation_trace = app.call('activation-events')
        app.call('quit')
        exited = wait(lambda: not app.process_path(app.pid), 15)
        app.quit()
        check('quit_close', exited)
        app = factory(urls=(), fresh=True, extra_env=launch_env)
        app.preferences_domain = domain
        app.call('download-policy', quit='record')
        empty = state()
        app.activation_trace = app.call('activation-events')
        app.call('quit')
        no_alert_exit = wait(lambda: not app.process_path(app.pid), 15)
        app.quit()
        check('quit_empty', not empty['running'] and not empty['quitAlerts'] and no_alert_exit)


    try:
        # The cloned bundle has its own domain; reset/restore every key this suite owns.
        for key, value in {'open.general.warnBeforeQuitting': True}.items():
            saved[key] = app.call('defaults', key=key)
            app.call('defaults', key=key, value=value)
        app.call('download-policy', quit='keep', recordFiles=True)
        with server() as base:
            tab = E.new_tab(app, base + '/')
            profile = next(v['profile'] for v in app.call('spaces') if v['focused'])
            first = root / 'first'; first.mkdir()
            sentinel = first / 'sample.txt'; sentinel.write_text('do not overwrite')
            app.call('download-settings', profile=profile, directory=str(first), ask=False)
            flows = {"controls": controls_flow, "files": files_flow, "save": save_flow,
                     "profiles": profiles_flow, "fallback": fallback_flow, "badge": badge_flow, "quit": quit_flow}
            selection = os.environ.get('OPEN_DOWNLOADS_CASE', '')
            selected = set(selection.split(',')) if selection else set(flows)
            if selected - set(flows):
                raise RuntimeError('unknown Downloads diagnostic case: ' + selection)
            for name, flow in flows.items():
                if name in selected:
                    flow()
    finally:
        if not app.closed:
            E._try(lambda: app.call('download-policy', quit='close'))
            for sheet in E._try(lambda: state()['sheets']) or []:
                E._try(lambda: app.call('download-save', id=sheet['id'], action='cancel'))
        E._restore_defaults(app, saved)
        if not app.closed:
            pid = E._try(lambda: state()['openerPID']) or 0
            if pid > 0: app.owned_processes[pid] = str(executable.resolve())
        app.quit()
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
