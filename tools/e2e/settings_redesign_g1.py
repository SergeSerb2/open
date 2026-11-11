#!/usr/bin/env python3
"""G1 look evidence from the real Open App and its own-window socket.

Run under the machine's on-screen lock. No desktop input or system dialogs.
The App bundle and all browser data belong to this run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import tempfile
import time
from engine_e2e import Open


def run(bundle, out):
    out.mkdir(parents=True, exist_ok=True)
    data = tempfile.mkdtemp(prefix='g1-data-', dir=out)
    app = Open('Debug', 'alloy', data, [], str(out/'app.log'),
               extra_env={'OPEN_E2E_APP_BUNDLE': str(bundle)})
    results = {}
    frames = []
    saved = {}
    state = None

    def check(name, condition, **evidence):
        results[name] = dict(ok=bool(condition), **evidence)
        print(name + (' PASS' if condition else ' FAIL'), flush=True)
        if not condition:
            try:
                debug=ui();(out/'failure-state.json').write_text(json.dumps(debug,indent=2))
                app.call('snapshot',window=debug['window'],path=str(out/'failure.png'))
            except Exception: pass
        assert condition, name

    def ui(**args):
        return app.call('settings-ui', **args)

    def settle():
        time.sleep(.16)
        return ui()

    def node(label=None, identifier=None, role=None, window=None):
        s = settle()
        found = [c for c in s['controls']
                 if (label is None or c['label'] == label)
                 and (identifier is None or c['id'] == identifier)
                 and (role is None or c['role'] == role)
                 and (window is None or c['window'] == window)
                 and c['frame'][2] > 0 and c['frame'][3] > 0]
        if not found:
            (out/'missing-control.json').write_text(json.dumps(s,indent=2))
            app.call('snapshot',window=s['window'],path=str(out/'missing-control.png'))
        assert found, 'visible control missing: ' + str(label or identifier)
        return found[0]

    def point(c):
        x,y,w,h = c['frame']
        return dict(window=c['window'], x=x+w/2, y=y+h/2)

    def click(label=None, identifier=None, role=None):
        receipt=app.call('mouse', action='click', queued=True, **point(node(label, identifier, role)))
        time.sleep(.16)
        return receipt

    def key(key=None, modifiers=None, text=None, window=None):
        a = dict(window=window or ui()['window'], route='app')
        if key is not None: a['key'] = key
        if modifiers is not None: a['modifiers'] = modifiers
        if text is not None: a['text'] = text
        return app.call('key', **a)

    def search(query):
        key('f', ['cmd']); key('a', ['cmd']); key('delete')
        for char in query: key(text=char)
        return settle()

    def capture(name, sheet=False):
        s = settle()
        path = out/(name+'.png')
        receipt = app.call('snapshot', window=s['sheet'] if sheet else s['window'], path=str(path))
        frames.append(dict(name=name, file=path.name, size=s['size'], scale=s['scale'], screen=s['screen'], snapshot=receipt))
        (out/(name+'.json')).write_text(json.dumps(s, indent=2))

    def record(command, keyname, modifiers):
        ui(action='select-command', id=command); settle()
        c = next((c for c in ui()['controls'] if c['label'].startswith('Record shortcut for ') and c['label'] == 'Record shortcut for '+titles[command]), None)
        assert c, 'recording control not realized: '+command
        app.call('mouse', action='click', queued=True, **point(c)); settle()
        assert ui()['recording'] == command
        key(keyname, modifiers)
        return settle()

    try:
        keys = ('open.advanced.restoreWindowsOnLaunch', 'open.general.warnBeforeQuitting',
                'open.general.automaticallyUpdate', 'open.web.colorScheme',
                'open.advanced.showFullURLWithToolbar', 'open.appIcon.selectedID',
                'open.settings.lastPane', 'open.settings.lastSection',
                'open.general.searchSuggestNoticeDismissed')
        saved = {k: app.call('defaults', key=k, persistent=True) for k in keys}
        app.call('defaults', key='open.general.searchSuggestNoticeDismissed', value=True)
        app.call('appearance', name='light')
        app.call('menu-perform', id='settings')
        state = settle()
        results['first_open'] = dict(layoutDisplayMs=state['openLayoutDisplayMs'], size=state['size'], load=list(os.getloadavg()))
        ui(action='resize', width=960, height=660)
        key('1', ['cmd'])
        state = settle()
        check('window_geometry', state['size'] == [960,660] and state['scale'] == 2 and 'Built-in' in state['screen'], size=state['size'], scale=state['scale'], screen=state['screen'])
        # The switch is hit from its actual AX row bounds and the design's
        # trailing control inset, rather than a fixed window coordinate.
        before = app.call('defaults', key='open.advanced.restoreWindowsOnLaunch')
        # Start this fixture at its registered default, regardless of the
        # machine's saved preference. Finally restores the original value.
        if before is not True:
            click(label='Restore windows from the previous session',role='AXCheckBox')
        before = app.call('defaults', key='open.advanced.restoreWindowsOnLaunch')
        assert before is True
        click(label='Restore windows from the previous session',role='AXCheckBox')
        after = app.call('defaults',key='open.advanced.restoreWindowsOnLaunch')
        check('general_switch_store', after is (not before), before=before, after=after)
        changed = search('is:changed')
        check('changed_scope', any(r['id']=='general/restore-windows' for r in changed['results']))
        key('escape')
        row = node(identifier='general/restore-windows')
        app.call('mouse',action='hover',**point(row))
        click(label='Reset Restore windows from the previous session',role='AXButton')
        check('changed_reset_store', app.call('defaults',key='open.advanced.restoreWindowsOnLaunch') is True)
        # Native global search, keyboard selection, stable link and empty case.
        samples=[]
        for query in ('archive','default','toolbar','shortcut','restore','window'):
            key('f',['cmd']);key('a',['cmd']);key('delete')
            for ch in query:
                key(text=ch); samples.append(ui()['searchCPUms'])
        s=search('archive')
        target=next(i for i,r in enumerate(s['results']) if r['id']=='tabs-archive/archive-after')
        for _ in range(target):key('down')
        key('return');s=settle()
        check('search_return_deep_link',s['section']=='tabs-archive' and s['arrival']=='tabs-archive/archive-after',arrival=s['arrival'])
        ui(action='link',url='open://settings/appearance/toolbar');s=settle()
        check('stable_settings_link',s['section']=='appearance' and s['arrival']=='appearance/toolbar')
        try:
            ui(action='link',url='open://settings/appearance/missing')
            invalid=False
        except RuntimeError: invalid=True
        check('invalid_link_keeps_section',invalid and ui()['section']=='appearance')
        s=search('zzzz-no-such-setting')
        check('search_empty',s['results']==[])
        capture('search-empty-light')
        key('escape');check('search_escape',ui()['query']=='')
        results['search_cpu'] = dict(samplesMs=samples, p95Ms=sorted(samples)[max(0,int(len(samples)*.95)-1)], indexCount=s['indexCount'], scope='main-thread index filtering only', load=list(os.getloadavg()))
        # Profile pill dispatches the actual native pop-up action.
        app.call('space-create',title='G1 Work',profile='G1 Work')
        ui(action='open',section='tabs-archive');s=settle();first=s['profile']
        ui(action='choice',label='Profile',title='G1 Work');s=settle()
        check('profile_pill',first!=s['profile'])
        # Appearance controls keep their production action paths.
        key('2',['cmd']);settle()
        click(label='Website appearance: Dark',role='AXButton')
        check('website_appearance_store',app.call('defaults',key='open.web.colorScheme')=='dark')
        click(label='Website appearance: Match System',role='AXButton')
        row=node(identifier='appearance/toolbar');x,y,w,h=row['frame']
        app.call('mouse',action='click',window=row['window'],x=x+w-32,y=y+h/2)
        state=app.call('window-state')
        # Read back through the same browser model persisted by the control.
        snapshot=json.loads(Path(app.call('save')).read_text())
        check('toolbar_snapshot',any(w.get('showsToolbar') for w in snapshot['windows']))
        # Restore toolbar for the designed disabled full-URL state.
        row=node(identifier='appearance/toolbar');x,y,w,h=row['frame']
        app.call('mouse',action='click',window=row['window'],x=x+w-32,y=y+h/2)
        # Inline native recording: invalid key, Escape, guarded conflict, Revert.
        app.call('appearance',name='dark');ui(action='open',section='shortcuts');settle()
        global titles
        titles={'search-actions':'Search Actions','new-tab':'New Tab…','search-tabs':'Search Tabs'}
        ui(action='select-command',id='search-actions');settle()
        click(label='Record shortcut for Search Actions')
        check('record_started',ui()['recording']=='search-actions')
        key(text='q');s=settle()
        check('record_typing_guard',s['recording']=='search-actions' and not Path(s['keybindingsFile']).exists())
        key('escape');check('record_escape',ui()['recording']=='')
        mods=['cmd','shift','control','option']
        s=record('search-actions','j',mods)
        binding=Path(s['keybindingsFile']);saved_hash=hashlib.sha256(binding.read_bytes()).hexdigest()
        check('shortcut_record_store','search-actions' in s['bindings'] and s['conflicts']==0)
        s=record('new-tab','j',mods)
        check('shortcut_conflict_no_write',s['conflicts']>0 and hashlib.sha256(binding.read_bytes()).hexdigest()==saved_hash,conflicts=s['conflicts'])
        ui(action='filter',filter='conflicts');settle()
        capture('shortcuts-conflict-dark')
        ui(action='revert');s=settle()
        check('shortcut_revert',s['conflicts']==0 and hashlib.sha256(binding.read_bytes()).hexdigest()==saved_hash)
        # Repeat the conflict, then exercise the actual native Keep button.
        ui(action='filter',filter='all');s=record('new-tab','j',mods)
        ui(action='filter',filter='conflicts');settle()
        click(label='Keep this')
        s=settle();check('shortcut_keep_resolution',s['conflicts']==0 and hashlib.sha256(binding.read_bytes()).hexdigest()!=saved_hash)
        ui(action='filter',filter='all')
        # Four requested artboards in both appearances, using live store values.
        for mode in ('light','dark'):
            app.call('appearance',name=mode)
            ui(action='open',section='general');capture('general-'+mode)
            ui(action='open',section='appearance');capture('appearance-'+mode)
            ui(action='open',section='shortcuts');ui(action='filter',filter='all');s=record('search-tabs','j',mods)
            check('frame_conflict_'+mode,s['conflicts']>0 and 'search-tabs' in s['bindings'])
            ui(action='select-command',id='search-actions');settle()
            click(label='Record shortcut for Search Actions');capture('shortcuts-'+mode)
            key('escape');ui(action='revert')
            search('archive');capture('search-'+mode);key('escape')
            ui(action='kit',visible=True);s=settle()
            # Move outside every control to capture the normal sheet state.
            app.call('mouse',action='hover',window=s['sheet'],x=24,y=24)
            capture('controls-'+mode,sheet=True)
            normal=ui()
            # Hover the changed row in the real sheet, then Tab into controls.
            c=node(identifier='kit/switch',window=s['sheet'])
            app.call('mouse',action='hover',**point(c));capture('controls-hover-'+mode,sheet=True)
            hovered=ui()
            check('kit_hover_'+mode,normal['focusedSetting']!='kit/switch'
                  and not any(c['label']=='Reset Switch' for c in normal['controls'])
                  and any(c['label']=='Reset Switch' for c in hovered['controls']))
            app.call('mouse',action='hover',window=s['sheet'],x=24,y=24)
            for _ in range(16):
                key('tab',window=s['sheet']);s=settle()
                if s['focusedSetting']=='kit/switch':break
            check('kit_keyboard_focus_'+mode,s['focusedSetting']=='kit/switch')
            capture('controls-focus-'+mode,sheet=True)
            key('escape',window=s['sheet']);settle()
        # Min-size state: nav and detail scroll independently, labels stay valid.
        app.call('appearance',name='light');ui(action='open',section='general');ui(action='resize',width=800,height=540)
        capture('general-minimum-light')
        ui(action='resize',width=960,height=660)
        warm=[]
        for _ in range(8):
            app.call('menu-perform',id='settings');warm.append(ui()['openLayoutDisplayMs'])
        results['warm_open'] = dict(samplesMs=warm,p95Ms=sorted(warm)[-1],load=list(os.getloadavg()))
        results['complete']=True
    finally:
        for k,v in saved.items():
            try: app.call('defaults',key=k,value=v)
            except Exception: pass
        app.quit()
        (out/'results.json').write_text(json.dumps(dict(results=results,frames=frames),indent=2))
    return results


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--bundle',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();run(a.bundle,a.out)
