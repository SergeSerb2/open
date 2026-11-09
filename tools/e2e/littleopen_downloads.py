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
    evidence = Path(E.ROOT) / '.re/littleopen-downloads/review-r1'
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
            # Hold real progress at the App callback boundary until destination
            # selection has continued and the source host has moved away.
            early = page()
            tray(early, action='arm-early-move')
            early_key = start(early, '/finish?tray=early-move')
            check('early_move', wait(lambda: not tray(early)['exists'])
                  and item(early_key).get('littleOpenSession') == early['id']
                  and not tray(early)['trayExists'], item=item(early_key), tray=tray(early))
            check('early_move_finish', wait(lambda: item(early_key).get('fileExists') and state()['detachedPages'] == 0), item=item(early_key))
            active = start(one, '/slow?tray=one')
            arrived = wait(lambda: tray(one)['buttonVisible'] and any(v['id'] == active and v['received'] > 0 for v in tray(one)['items']))
            check('attribution', arrived and not tray(two)['buttonVisible'], one=tray(one), two=tray(two))
            shown = show(one)
            check('progress', shown and shown['running'] and 0 < shown['progress'] < 1
                  and row(one, active).get('status') and tray(one)['items'][0]['host'] == '127.0.0.1', tray=tray(one))
            controls = row(one, active).get('buttons', [])
            check('accessibility', tray(one)['label'] == 'Downloads' and all(v['label'] for v in controls)
                  and {v['name'] for v in controls} == {'Pause', 'Cancel'} and row(one, active).get('label'), row=row(one, active))
            ax = tray(one)
            check('ax_order', ax['axRowOrder'] == [r['id'] for r in ax['rows']]
                  and [v['name'] for v in ax['rows'][0]['axChildren']] == ['Pause', 'Cancel']
                  and all(v['role'] == 'AXButton' and v['label'] for v in ax['rows'][0]['axChildren'])
                  and ax['firstAction'] == 'Pause' and ax['rows'][0]['icon'], tree=ax)
            check('return', ax['popoverKey'] and tray(one, action='key', key='Return', target='popover')['shown']
                  and wait(lambda: item(active).get('state') == 'paused')
                  and {'code': 36, 'path': 'popover'} in tray(one)['handledKeys']
                  and tray(one)['exists'] and tray(two)['exists'], tray=tray(one))
            press(one, active, 'Resume')
            wait(lambda: item(active).get('state') == 'inProgress')
            press(one, active, 'Pause')
            paused = wait(lambda: item(active).get('state') == 'paused' and row(one, active).get('status') == 'Paused')
            time.sleep(.5); paused_bytes = item(active)['received']; time.sleep(.6)
            check('pause', paused and item(active)['received'] == paused_bytes
                  and not tray(one)['running'] and tray(one)['progress'] is None
                  and tray(one)['value'] == '1 paused download', item=item(active), tray=tray(one), pausedBytes=paused_bytes)
            mixed = start(one, '/slow?tray=mixed')
            show(one)
            wait(lambda: any(v['id'] == mixed and v['received'] > 0 for v in tray(one)['items']))
            mix = tray(one)
            expected = next(v['received'] for v in mix['items'] if v['id'] == mixed) / item(mixed)['total']
            check('mixed_progress', mix['value'] == '1 active download' and mix['running']
                  and abs(mix['progress'] - expected) < 1e-9, tray=mix)
            press(one, mixed, 'Cancel')
            wait(lambda: item(mixed).get('state') == 'cancelled')
            press(one, active, 'Resume')
            check('resume', wait(lambda: item(active).get('state') == 'inProgress' and item(active)['received'] > paused_bytes
                                 and any(v['name'] == 'Pause' for v in row(one, active).get('buttons', []))), item=item(active))
            press(one, active, 'Cancel')
            check('cancel', wait(lambda: item(active).get('state') == 'cancelled' and row(one, active).get('status') == 'Cancelled'), item=item(active))
            # Two windows in the same Profile still own different trays.
            second = start(two, '/fast?tray=two')
            wait(lambda: item(second).get('fileExists'))
            check('two_windows', {v['id'] for v in tray(one)['items']} == {active, mixed}
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
            check('retained', {v['id'] for v in tray(one)['items']} == {active, mixed, finished}
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
            failed = start(one, '/fail?tray=retry')
            wait(lambda: item(failed).get('state') == 'failed', seconds=40)
            show(one)
            before_retry = {v['id'] for v in state()['items']}
            failed_row = row(one, failed)
            press(one, failed, 'Retry')
            retried = wait(lambda: next((v for v in state()['items'] if v['id'] not in before_retry
                                        and v['source'] == base + '/fail?tray=retry'), None))
            check('retry', retried and failed_row['icon'] and [v['name'] for v in failed_row['buttons']] == ['Retry'], row=failed_row, retry=retried)
            tray(one, action='close')

            # Native destination choice belongs to the standalone source window.
            app.call('download-settings', profile=profile, ask=True)
            asking = page()
            asked = start(asking, '/finish?tray=ask')
            sheet = wait(lambda: next((s for s in state()['sheets'] if s['id'] == asked and s['visible']), None))
            check('ask_owner', sheet and sheet['sheet'] and sheet['parent'] == asking['window'], sheet=sheet)
            app.call('download-save', id=asked, path=str(root / 'files/little-ask.txt'))
            check('ask_finish', wait(lambda: item(asked).get('fileExists') and not any(s['id'] == asked for s in state()['sheets'])), item=item(asked))
            app.call('download-settings', profile=profile, ask=False)

            lifecycle = []
            for mode in ('move', 'close'):
                source = page()
                key = start(source, '/finish?tray=active-' + mode)
                wait(lambda: item(key).get('received', 0) > 0)
                show(source)
                before_action = tray(source)
                if mode == 'move': tray(source, action='move')
                else: app.call('little-open-action', id=source['id'], action='close-button')
                removed = wait(lambda: not tray(source)['exists'] and not tray(source)['trayExists'] and not tray(source)['shown'])
                check('active_' + mode, before_action['running'] and removed
                      and wait(lambda: item(key).get('fileExists') and state()['detachedPages'] == 0), item=item(key), after=tray(source), detachedPages=state()['detachedPages'])
                lifecycle.append(key)

            closing = page()
            close_key = start(closing, '/fast?tray=cmd-w')
            wait(lambda: item(close_key).get('fileExists'))
            keyed = show(closing)
            tray(closing, action='key', key='Cmd+W', target='popover')
            check('cmd_w', keyed['popoverKey'] and wait(lambda: not tray(closing)['exists'] and not tray(closing)['trayExists'])
                  and tray(two)['exists'] and bool(app.eval(main, 'Boolean(document.body)')), after=tray(closing))

            tray(one, action='close')
            app.call('command', id='view-downloads')
            shared_ids = {active, mixed, finished, second, main_item['id'], early_key, asked, close_key, *lifecycle}
            shared = wait(lambda: shared_ids <= {v['id'] for v in state()['rows']})
            check('library_shared', shared and all(v['id'] in {i['id'] for i in state()['items']} for v in tray(one)['items']), rows=state()['rows'])
            app.call('download-library-close')
            for appearance in ('light', 'dark'):
                app.call('appearance', name=appearance)
                dark = appearance == 'dark'
                html = '<style>body{font:20px system-ui;padding:70px;background:%s;color:%s}h1{font-size:38px}</style><h1>Downloads</h1><p>A real page behind the Little Open tray.</p>' % ('#182b40' if dark else '#edf4fc', '#edf4fc' if dark else '#182b40')
                app.call('little-open-eval', id=one['id'], js='document.body.innerHTML=%s;true' % json.dumps(html))
                show(one)
                snapshot = evidence / ('tray-' + appearance + '.png')
                app.call('snapshot', window=tray(one)['window'], path=str(snapshot))
                app.call('snapshot', window=one['window'], overlayWindows=[tray(one)['window']],
                         path=str(evidence / ('tray-' + appearance + '-page.png')))
                if not snapshot.exists(): raise RuntimeError('tray screenshot was not saved')
                if appearance == 'dark':
                    tray(one, action='escape')
                    check('escape', wait(lambda: not tray(one)['shown']) and bool(item(finished)))
                else:
                    tray(one, action='close')
            show(one)
            parent_escape = tray(one, action='key', key='Escape', target='parent')
            check('escape_parent', not parent_escape['shown']
                  and {'code': 53, 'path': 'parent'} in parent_escape['handledKeys'], tray=parent_escape)
            check('focus_restore', parent_escape['parentKey'] and parent_escape['parentFocusRestored'], tray=parent_escape)

            # Real transfers, each with page input, rather than injected rows.
            for index in range(101): start(one, '/fast?tray=bound-' + str(index))
            wait(lambda: all(v['state'] not in ('inProgress', 'paused') for v in tray(one)['items']))
            bounded = show(one)
            check('row_bound', len(bounded['items']) > 100 and len(bounded['rows']) == 100
                  and [v['id'] for v in bounded['rows']] == [v['id'] for v in bounded['items'][:100]], rows=len(bounded['rows']), items=len(bounded['items']))
            tray(one, action='close')
            unchanged = tray(one)['updates']
            app.call('little-open-action', id=one['id'], action='focus')
            check('unchanged', tray(one)['updates'] == unchanged, before=unchanged, after=tray(one)['updates'])
            # Closing the source window must not remove the shared download.
            app.call('little-open-action', id=one['id'], action='close')
            check('source_close', item(finished).get('state') == 'completed' and Path(item(finished)['path']).exists())
    finally:
        E._try(lambda: app.call('download-settings', profile=profile, ask=False))
        E._try(lambda: app.call('appearance', name='system'))
        for session in sessions:
            E._try(lambda s=session: tray(s, action='close'))
            E._try(lambda s=session: app.call('little-open-action', id=s['id'], action='close'))
        E._try(lambda: app.call('download-policy', quit='close'))
        app.quit()
        (evidence / ('cleanup-' + str(os.getpid()) + '.json')).write_text(json.dumps(app.quit_report, indent=2))
