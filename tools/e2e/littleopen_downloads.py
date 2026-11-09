"""Little Open tray: real engine transfers and the visible native tray controls."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import urllib.parse


def checks(factory, results, tmp, E, server):
    root = Path(tempfile.mkdtemp(prefix='littleopen-downloads-', dir=tmp))
    evidence = Path(E.ROOT) / '.re/littleopen-downloads'
    evidence.mkdir(parents=True, exist_ok=True)
    # Use the normal built bundle. This flow needs no preference writes, copied
    # bundle, re-signing, injected library or teardown of a cloned CEF bundle.
    opener = root / 'DownloadOpenProbe.app'
    executable = opener / 'Contents/MacOS/DownloadOpenProbe'
    executable.parent.mkdir(parents=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-O', '-parse-as-library',
                    str(Path(E.ROOT) / 'tools/e2e/download-opener.swift'), '-framework', 'AppKit', '-o', str(executable)], check=True)
    (opener / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'io.github.sergeserb2.open.tray-opener.' + str(os.getpid()),
        'CFBundleName': 'Download Open Probe', 'CFBundleExecutable': 'DownloadOpenProbe',
        'CFBundlePackageType': 'APPL', 'NSPrincipalClass': 'NSApplication',
        'LSBackgroundOnly': True, 'LSMinimumSystemVersion': '26.0'}))
    subprocess.run(['codesign', '--force', '--sign', '-', str(opener)], check=True, capture_output=True)
    private_home = root / 'home'; private_home.mkdir()
    app = factory(urls=(), extra_env={'OPEN_DOWNLOADS_DEFAULT_DIRECTORY': str(root / 'files'),
                                    'CFFIXED_USER_HOME': str(private_home)},
                  extra_args=['-open.links.littleOpenNUXSeen', 'YES'])
    sessions = []
    def wait(fn, seconds=15): return E.wait_until(fn, timeout=seconds, step=.05)
    def state(): return app.call('downloads-state')
    def item(key): return next((v for v in state()['items'] if v['id'] == key), {})
    def tray(session, **args): return app.call('little-open-downloads', id=session['id'], **args)
    def row(session, key): return next((v for v in tray(session)['rows'] if v['id'] == key), {})
    def check(name, ok, **data):
        results['little_tray_' + name] = dict(ok=bool(ok), **data)
        print('little tray %-25s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
    def page():
        before = {s['id'] for s in app.call('little-open-state')['sessions']}
        app.call('little-open-action', action='blank')
        session = next(s for s in app.call('little-open-state')['sessions'] if s['id'] not in before)
        sessions.append(session)
        app.call('key', window=session['window'], text=base + '/?tray-window=' + str(len(sessions)) + '\r')
        ready = wait(lambda: next((s for s in app.call('little-open-state')['sessions']
                                  if s['id'] == session['id'] and s['state'] == 'page' and s['content'] and not s['loading']), None))
        if not ready:
            observed = app.call('little-open-state')
            (evidence / 'page-not-ready.json').write_text(json.dumps(observed, indent=2))
            raise RuntimeError('Little Open page did not load: ' + json.dumps(observed['sessions']))
        app.call('little-open-action', id=session['id'], action='dismiss-intro')
        return session
    def start(session, route):
        before = {v['id'] for v in state()['items']}
        app.call('little-open-action', id=session['id'], action='focus')
        app.call('little-open-eval', id=session['id'], js='''(() => {
          let a=document.createElement('a');a.href=%s;a.id='download';a.textContent='Download';
          document.body.replaceChildren(a);return true})()''' % json.dumps(base + route))
        # DevTools input targets the actual standalone page. No desktop input.
        app.call('click', window=session['window'], selector='#download')
        created = wait(lambda: next((v for v in state()['items'] if v['id'] not in before), None))
        if not created: raise RuntimeError('Little Open download did not start')
        return created['id']
    def press(session, key, title):
        tray(session, action='row', download=key, button=title)
    def show(session):
        app.call('little-open-action', id=session['id'], action='focus')
        if not tray(session)['shown']: tray(session, action='toggle')
        return wait(lambda: tray(session) if tray(session)['shown'] else None)
    try:
        app.call('download-policy', quit='close', recordFiles=True, openApp=str(opener))
        with server() as base:
            main = E.new_tab(app, base + '/')
            profile = next(s['profile'] for s in app.call('spaces') if s['focused'])
            app.call('download-settings', profile=profile, directory=str(root / 'files'), ask=False)
            one, two = page(), page()
            check('empty', all(not tray(s)['buttonVisible'] and not tray(s)['items'] and not tray(s)['shown'] for s in sessions))
            active = start(one, '/slow?tray=one')
            arrived = wait(lambda: tray(one)['buttonVisible'] and any(v['id'] == active and v['received'] > 0 for v in tray(one)['items']))
            check('attribution', arrived and not tray(two)['buttonVisible'], one=tray(one), two=tray(two))
            shown = show(one)
            check('progress', shown and shown['running'] and 0 < shown['progress'] < 1
                  and row(one, active).get('status') and tray(one)['items'][0]['host'] == '127.0.0.1', tray=tray(one))
            controls = row(one, active).get('buttons', [])
            check('accessibility', tray(one)['label'] == 'Downloads' and all(v['label'] for v in controls)
                  and {v['name'] for v in controls} == {'Pause', 'Cancel'} and row(one, active).get('label'), row=row(one, active))
            press(one, active, 'Pause')
            paused = wait(lambda: item(active).get('state') == 'paused' and row(one, active).get('status') == 'Paused')
            time.sleep(.5); paused_bytes = item(active)['received']; time.sleep(.6)
            check('pause', paused and item(active)['received'] == paused_bytes, item=item(active), pausedBytes=paused_bytes)
            press(one, active, 'Resume')
            check('resume', wait(lambda: item(active).get('state') == 'inProgress' and item(active)['received'] > paused_bytes
                                 and any(v['name'] == 'Pause' for v in row(one, active).get('buttons', []))), item=item(active))
            press(one, active, 'Cancel')
            check('cancel', wait(lambda: item(active).get('state') == 'cancelled' and row(one, active).get('status') == 'Cancelled'), item=item(active))
            # Two windows in the same Profile still own different trays.
            second = start(two, '/fast?tray=two')
            wait(lambda: item(second).get('fileExists'))
            check('two_windows', {v['id'] for v in tray(one)['items']} == {active}
                  and {v['id'] for v in tray(two)['items']} == {second}, one=tray(one), two=tray(two))
            before = {v['id'] for v in state()['items']}
            app.call('select', tab=main)
            app.eval(main, 'document.body.innerHTML=%s;true' % json.dumps('<a id="mainDownload" href="' + base + '/fast?tray=main">Main download</a>'))
            app.call('click', tab=main, selector='#mainDownload')
            main_item = wait(lambda: next((v for v in state()['items'] if v['id'] not in before and v['state'] == 'completed'), None))
            check('main_excluded', main_item and all(main_item['id'] not in {v['id'] for v in tray(s)['items']} for s in sessions), main=main_item)
            finished = start(one, '/finish?tray=finished')
            show(one)
            check('finish', wait(lambda: item(finished).get('fileExists') and row(one, finished).get('status') == 'Completed'), tray=tray(one))
            check('retained', {v['id'] for v in tray(one)['items']} == {active, finished}
                  and all(not v['historical'] for v in tray(one)['items']), tray=tray(one))
            press(one, finished, 'Open')
            receipt_path = root / 'opened-file.json'
            def receipt():
                try: return json.loads(receipt_path.read_text())
                except (OSError, ValueError): return None
            opened = wait(receipt)
            if opened and opened.get('pid'): app.owned_processes[opened['pid']] = str(executable.resolve())
            payload = (b'Open download.\n' + b'x' * (16384 - 15)) * 64
            check('open_file', opened and opened.get('bytes') == len(payload)
                  and opened.get('sha256') == hashlib.sha256(payload).hexdigest()
                  and urllib.parse.unquote(urllib.parse.urlparse(opened['url']).path) == item(finished)['path'], receipt=opened)
            press(one, finished, 'Show in Finder')
            check('reveal', wait(lambda: any(v['action'] == 'reveal' and urllib.parse.unquote(urllib.parse.urlparse(v['url']).path) == item(finished)['path'] for v in state()['fileActions'])), actions=state()['fileActions'])
            tray(one, action='close')
            app.call('command', id='view-downloads')
            shared = wait(lambda: {active, finished, second, main_item['id']} <= {v['id'] for v in state()['rows']})
            check('library_shared', shared and all(v['id'] in {i['id'] for i in state()['items']} for v in tray(one)['items']), rows=state()['rows'])
            app.call('download-library-close')
            for appearance in ('light', 'dark'):
                app.call('appearance', name=appearance)
                show(one)
                snapshot = evidence / ('tray-' + appearance + '.png')
                app.call('snapshot', window=tray(one)['window'], path=str(snapshot))
                if not snapshot.exists(): raise RuntimeError('tray screenshot was not saved')
                if appearance == 'dark':
                    tray(one, action='escape')
                    check('escape', wait(lambda: not tray(one)['shown']) and bool(item(finished)))
                else:
                    tray(one, action='close')
            # Closing the source window must not remove the shared download.
            app.call('little-open-action', id=one['id'], action='close')
            check('source_close', item(finished).get('state') == 'completed' and Path(item(finished)['path']).exists())
    finally:
        E._try(lambda: app.call('appearance', name='system'))
        for session in sessions:
            E._try(lambda s=session: tray(s, action='close'))
            E._try(lambda s=session: app.call('little-open-action', id=s['id'], action='close'))
        E._try(lambda: app.call('download-policy', quit='close'))
        app.quit()
        (evidence / ('cleanup-' + str(os.getpid()) + '.json')).write_text(json.dumps(app.quit_report, indent=2))
