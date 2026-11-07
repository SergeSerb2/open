"""Real quit/relaunch preference flow; called by the relaunch suite."""
import json
import os
from pathlib import Path
import plistlib
import subprocess


def run(factory, results, tmp, harness, config):
    E = harness
    root = Path(tmp) / 'session-restore'
    root.mkdir(exist_ok=True)
    bundle = root / 'Open.app'
    subprocess.run(['cp', '-cR', str(Path(E.ROOT) / 'build' / config / 'Open.app'), str(bundle)], check=True)
    info_path = bundle / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    domain = 'io.github.sergeserb2.open.restore-e2e.' + str(os.getpid())
    info['CFBundleIdentifier'] = domain
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    env = {'OPEN_E2E_APP_BUNDLE': str(bundle)}
    key = 'open.advanced.restoreWindowsOnLaunch'
    app = None
    saved = {}
    def launch(fresh=False):
        value = factory(urls=(), fresh=fresh, extra_env=env)
        value.preferences_domain = domain
        return value
    def check(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('restore %-32s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
    def sidebar_ids():
        app.call('save')
        snapshot = json.loads((Path(app.user_data) / 'State/browser.json').read_text())
        def ids(value):
            if isinstance(value, dict):
                if isinstance(value.get('id'), str): yield value['id']
                for child in value.values(): yield from ids(child)
            elif isinstance(value, list):
                for child in value: yield from ids(child)
        return set(ids([snapshot['profiles'], snapshot['spaces']])), len(snapshot['spaces'])
    def quit_real():
        app.activation_trace = app.call('activation-events')
        app.call('quit')
        exited = E.wait_until(lambda: not app.process_path(app.pid), timeout=20, step=.05)
        app.quit()
        if not exited: raise RuntimeError('real quit did not exit')
    try:
        for restore in (True, False):
            app = launch(fresh=True)
            if not saved: saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=None)
            app.call('defaults', key=key, value=restore)
            first = app.call('window-state')['id']
            space1 = next(s['id'] for s in app.call('spaces') if s['focused'])
            tab1 = E.new_tab(app, 'data:text/html,<title>First restore selection</title>')
            app.call('window-frame', frame=[110, 140, 920, 660])
            app.call('mouse', **{'from': [228, 300], 'to': [280, 300]})
            space2 = app.call('space-create', profile='Restore second', title='Restore second')
            tab2 = E.new_tab(app, 'data:text/html,<title>Second restore selection</title>')
            app.call('space', space=space1)
            app.call('command', id='new-window')
            second = app.call('window-state')['id']
            app.call('key', key='escape', route='app')
            app.call('space', space=space2); app.call('select', tab=tab2)
            app.call('window-frame', frame=[260, 270, 1000, 700])
            app.call('mouse', **{'from': [228, 300], 'to': [310, 300]})
            # Focus the older window last: creation order is not focus recency.
            app.call('window-focus', id=first, activate=True)
            app.call('select', tab=tab1)
            before = {i: app.call('window-state', id=i) for i in (first, second)}
            app.call('command', id='new-little-open-window')
            app.call('window-focus', id=first, activate=True)
            tabs_before, space_count = sidebar_ids()
            quit_real()
            app = launch()
            windows = app.call('shell-windows')
            after = {w['id']: app.call('window-state', id=w['id']) for w in windows}
            state = app.call('window-state')
            if restore:
                check('restore_on_windows_frames_selection', len(after) == 2 and set(after) == set(before)
                      and before[first]['sidebarWidth'] != before[second]['sidebarWidth']
                      and all(after[i]['frame'] == before[i]['frame']
                              and after[i]['sidebarWidth'] == before[i]['sidebarWidth']
                              and after[i]['space'] == before[i]['space']
                              and after[i]['selected'] == before[i]['selected'] for i in before),
                      before=before, after=after)
            else:
                visible = state['mainScreenVisibleFrame']
                frame = state['frame']
                centered = abs(frame[0] + frame[2]/2 - visible[0] - visible[2]/2) <= 1 and abs(frame[1] + frame[3]/2 - visible[1] - visible[3]/2) <= 1
                check('restore_off_one_default_centered', len(after) == 1 and frame[2:] == [1280, 800]
                      and centered and state['id'] not in before and all(frame != s['frame'] for s in before.values()),
                      frame=frame, visibleFrame=visible, beforeFrames=[s['frame'] for s in before.values()])
                check('restore_off_recent_space_selection', len(after) == 1 and state['space'] == space1
                      and state['selected'] == tab1 and state['space'] != space2 and state['selected'] != tab2,
                      space=state['space'], selected=state['selected'], expected=[space1, tab1])
            tabs_after, after_count = sidebar_ids()
            little = app.call('little-open-state')
            check('restore_%s_preserves_sidebar_no_little' % ('on' if restore else 'off'),
                  tabs_before == tabs_after and space_count == after_count and after_count >= 2 and not little['sessions'],
                  tabsBefore=sorted(tabs_before), tabsAfter=sorted(tabs_after), little=little)
            quit_real()
    finally:
        E._restore_defaults(app, saved)
        if app: app.quit()
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
