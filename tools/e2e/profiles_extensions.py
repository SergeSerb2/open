"""Section 10: lazy contexts and two-Profile UI through the real App.

Local CRX3 installs use Chromium's installer and native consent sheets.
No desktop input, mock engine, task-manager polling, or debugger attach.
"""
import json
import math
import os
from pathlib import Path
import runpy
import statistics
import subprocess
import time

pack_probe = runpy.run_path(str(Path(__file__).with_name("extensions_p3.py")))["pack_probe"]


def run(factory, results, tmp, root, wait, engine):
    _fixture_server = engine._fixture_server
    _restore_defaults = engine._restore_defaults
    process_cpu_window = engine.process_cpu_window
    app = None
    saved = {}
    server = None
    memory_only = os.environ.get('OPEN_E2E_EXTENSIONS_UI_SCOPE') == 'profiles-memory'
    crashes = Path.home() / 'Library/Logs/DiagnosticReports'
    reports_before = {p.name for p in crashes.glob('Open*.ips')}

    def row(name, ok, **evidence):
        results['P10_' + name] = dict(ok=bool(ok), **evidence)
        print('P10_' + name, 'PASS' if ok else 'FAIL', flush=True)

    def launch(**args):
        nonlocal app
        app = factory(urls=(), load_extensions=False, **args)
        for key, value in {'open.advanced.showToolbar': False,
                           'open.advanced.playSoundEffects': False,
                           'open.general.searchSuggestNoticeDismissed': True,
                           'open.settings.lastPane': 'general',
                           'open.links.littleOpenNUXSeen': True,
                           'open.links.littleOpenProfileSwitchConfirmed': False}.items():
            if key not in saved:
                saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=value)
        return app

    def profiles(): return app.call('profiles-shell')['profiles']
    def context_ids(): return app.call('engine-contexts')
    def focus(window): app.call('window-focus', id=window, activate=True)
    def opened(url='about:blank'):
        tab = app.call('open', url=url)['id']
        app.call('wait', tab=tab)
        return tab
    def installed(): return app.call('extensions')['installed']
    def action_ids(): return {r['id'] for r in app.call('extensions')['actions']}
    def strip_ids():
        app.call('ext-hover', inside=True)
        return app.call('ext-strip')
    def install(name):
        crx = pack_probe(root, tmp, prefix=name, name=name)
        app.call('ext-manage', extension='local', action='install-crx', path=crx)
        prompt = wait(lambda: (lambda p: p if p.get('pending') else None)(app.call('ext-prompt')), timeout=20)
        assert prompt, 'no Chromium install consent for ' + name
        identifier = prompt['extension']
        app.call('ext-prompt', answer='accept')
        assert wait(lambda: identifier in action_ids(), timeout=20), installed()
        app.call('ext-pin', extension=identifier, pinned=True)
        return identifier
    def registry(page):
        return app.eval(page, 'new Promise(done=>chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true}, rows=>done(rows.map(r=>r.id))))')
    def popup(identifier):
        strip_ids()
        app.call('ext-click', extension=identifier)
        return wait(lambda: (lambda p: p if p.get('visible') else None)(app.call('ext-popup-state')), timeout=15)
    def memory():
        app.discover_owned_processes()
        values = subprocess.check_output(['ps', '-p', ','.join(map(str, app.owned_processes)), '-o', 'pid=,rss='], text=True)
        rows = {int(pid): int(rss) * 1024 for pid, rss in (r.split() for r in values.splitlines())}
        assert app.pid in rows
        return dict(browser_rss_bytes=rows[app.pid], helper_count=len(rows) - 1,
                    helper_rss_bytes=sum(v for p, v in rows.items() if p != app.pid), load=list(os.getloadavg()))

    try:
        launch(fresh=True)
        window_a = app.call('window-state')['id']
        default_space = next(s['id'] for s in app.call('spaces') if s['focused'])
        work_space = app.call('space-create', title='Work', profile='Work')
        work = next(p for p in profiles() if p['name'] == 'Work')
        empty_browser = app.call('tab-strip')
        reads = {cmd: app.call(cmd) for cmd in ('extensions', 'actions', 'ext-popup', 'ext-commands', 'permission-decisions', 'downloads')}
        before_settings = context_ids()
        # The selected Settings Profile is independent of browser focus.
        app.call('profiles-shell', profile='Work')
        app.call('settings-pane', pane='shortcuts')
        shortcuts = app.call('ext-shortcuts')
        app.call('ext-shortcuts', action='close')
        row('empty_focus_reads', context_ids() == ['Default'] and before_settings == ['Default']
            and not reads['extensions']['loaded'] and reads['extensions']['actions'] == []
            and reads['actions']['actions'] == [] and reads['downloads'] == []
            and all(b['profile'] != work['id'] for b in empty_browser), contexts=context_ids(), strip=empty_browser, reads=reads,
            shortcutNotices=shortcuts['notices'])
        app.call('space', space=default_space)
        seed_path = Path(tmp) / 'p10-two-profiles.json'
        seed_path.write_bytes(Path(app.call('save')).read_bytes())
        app.quit()
        launch(snapshot=str(seed_path))
        time.sleep(10)
        row('launch_unvisited_profile', context_ids() == ['Default'], contexts=context_ids(), load=list(os.getloadavg()), idleSeconds=10)
        window_a = app.call('window-state')['id']
        # The first actual Work page, rather than focus or inspection, loads it.
        if memory_only:
            samples = []
            for index in range(5):
                if index:
                    app.quit(); launch(snapshot=str(seed_path)); time.sleep(10)
                before = memory()
                unloaded = context_ids()
                app.call('space', space=work_space)
                opened()
                time.sleep(10)
                after = memory()
                loaded = context_ids()
                samples.append(dict(before=before, after=after, unloaded=unloaded, loaded=loaded,
                    delta={k: after[k] - before[k] for k in ('browser_rss_bytes', 'helper_count', 'helper_rss_bytes')}))
                print('P10_memory_sample', index + 1, json.dumps(samples[-1]), flush=True)
            medians = {part: {k: statistics.median(s[part][k] for s in samples)
                             for k in ('browser_rss_bytes', 'helper_count', 'helper_rss_bytes')}
                       for part in ('before', 'after', 'delta')}
            row('context_memory', all(s['unloaded'] == ['Default'] and set(s['loaded']) == {'Default', work['directory']} for s in samples),
                launches=5, settleSeconds=10, samples=samples, medians=medians, units='RSS bytes; helper count')
            # The existing OS CPU sampler, without enabling Chromium metrics.
            app.call('command', id='new-window')
            time.sleep(30)
            work_before = app.call('frame-save-counters')
            sleep_before = app.call('sleep-state')
            idle = process_cpu_window(app)
            work_after = app.call('frame-save-counters')
            sleep_after = app.call('sleep-state')
            row('two_window_idle_cpu', idle['complete'] and len(app.call('shell-windows')) == 2, measurement=idle,
                contexts=context_ids(), windows=len(app.call('shell-windows')),
                workBefore=work_before, workAfter=work_after, sleepPasses=[sleep_before['passes'], sleep_after['passes']],
                scope='receipt; docs/idle-cpu.md defines no absolute CPU budget')
            return

        default_tab = opened()
        default_id = install('P10 Default Only')
        app.call('command', id='new-window')
        window_b = app.call('window-state')['id']
        assert window_a != window_b
        app.call('space', space=work_space)
        work_tab = opened()
        work_id = install('P10 Work Only')
        contexts = context_ids()
        strip_b = strip_ids()
        installed_b = {r['id'] for r in installed()}
        focus(window_a)
        strip_a = strip_ids()
        installed_a = {r['id'] for r in installed()}
        row('two_window_strips', strip_a['ids'] == [default_id] and strip_b['ids'] == [work_id]
            and installed_a == {default_id} and installed_b == {work_id}
            and len(contexts) == 2, a=strip_a, b=strip_b, installedA=sorted(installed_a), installedB=sorted(installed_b))
        menus = []
        for window, name in ((window_a, 'P10 Default Only'), (window_b, 'P10 Work Only')):
            focus(window)
            titles = [r['title'] for r in app.call('ext-ui-menu', kind='bar') if not r['separator']]
            menus.append(dict(titles=titles, expected=name, window=window))
        row('menu_follows_key_window', all(m['titles'] == [m['expected'], 'Manage Extensions…', 'Add Extension…'] for m in menus), menus=menus)
        pop = popup(work_id)
        assert pop, 'Work popup did not open'
        popup_page = app.call('ext-popup')['page']
        popup_runtime = app.eval(pop['page'], '({id:chrome.runtime.id, ids:[]})')
        row('popup_work_context', popup_page['context'] == work['directory'] and popup_runtime['id'] == work_id,
            page=popup_page, runtime=popup_runtime)
        app.call('popup-close')
        app.call('ext-ui-menu', kind='bar', select='Manage Extensions…')
        manage = wait(lambda: next((t for t in app.call('tabs') if t['url'] in ('chrome://extensions', 'chrome://extensions/') and t['selected']), None), timeout=15)
        assert manage, 'Manage Extensions did not open a Work tab'
        app.call('wait', tab=manage['id'])
        assert wait(lambda: app.eval(manage['id'], 'typeof chrome.developerPrivate?.getExtensionsInfo') == 'function', timeout=10)
        work_registry = registry(manage['id'])
        row('manage_work_tab', manage['space'] == work_space and manage['profile'] == work['id']
            and work_registry == [work_id], tab=manage, registry=work_registry)
        # Bind the same unused key in each real Chromium Profile. Dispatch keys
        # through OEApplication.sendEvent; each storage ledger proves the target.
        controls = {}
        for window, identifier in ((window_a, default_id), (window_b, work_id)):
            focus(window)
            settings_tab = opened('chrome://extensions/shortcuts')
            assert wait(lambda: app.eval(settings_tab, 'typeof chrome.developerPrivate?.updateExtensionCommand') == 'function', timeout=10)
            changed = app.eval(settings_tab, 'new Promise(done=>chrome.developerPrivate.updateExtensionCommand(' + json.dumps(
                dict(extensionId=identifier, commandName='probe-named', keybinding='Command+Shift+U')) + ',()=>done(chrome.runtime.lastError?.message||true)))')
            assert changed is True, changed
            controls[window] = app.page(opened('chrome-extension://' + identifier + '/popup.html'))['identifier']
            app.eval(controls[window], 'chrome.storage.session.set({commands:[]}).then(()=>true)')
        ledgers = []
        for window in (window_a, window_b):
            focus(window)
            app.call('focus', target='page')
            app.call('key', key='u', modifiers=['command', 'shift'], route='app')
            assert wait(lambda: app.eval(controls[window], "chrome.storage.session.get('commands').then(v=>(v.commands||[]).length)") == 1, timeout=5)
            # Read both pages without changing the key window or Profile.
            ledgers.append({w: app.eval(tab, "chrome.storage.session.get('commands').then(v=>(v.commands||[]).length)") for w, tab in controls.items()})
        row('shortcuts_key_profile', ledgers == [{window_a: 1, window_b: 0}, {window_a: 1, window_b: 1}], ledgers=ledgers)
        # Reuse the existing Space-switch gate: native switcher, the installed
        # 0.20 s critically damped spring, and <=0.5 pt remainder at 0.30 s.
        scheduled_spring = engine.scheduled_spring
        focus(window_a)
        app.call('space', space=work_space)
        attached = strip_ids()
        # A window without a selected page keeps its strip hidden. Its action
        # context still follows Work; selecting the page below reveals it.
        row('loaded_empty_space_binding', attached['contextIDs'] == [work_id]
            and attached['pinnedIDs'] == [work_id] and not attached['hasPage']
            and not attached['visible'] and context_ids() == contexts, strip=attached, contexts=context_ids())
        app.call('select', tab=work_tab)
        same_space = app.call('space-create', title='Default Second', profile='Default')
        same_tab = opened()
        app.call('space', space=default_space)
        app.call('select', tab=default_tab)
        app.call('window-motion', reduced=False)
        time.sleep(.35)
        for label, target, selected in (('same_profile_space_switch', same_space, same_tab),
                                        ('cross_profile_space_switch', work_space, work_tab)):
            position = app.call('window-state')['spaceSwitcherFrames'][target]
            start = time.monotonic()
            app.call('mouse', action='click', x=position[0] + position[2] / 2, y=position[1] + position[3] / 2)
            selected_state = wait(lambda: (lambda w: w if w['space'] == target and w['selected'] == selected else None)(app.call('window-state')), timeout=3, step=.01)
            observed_ms = (time.monotonic() - start) * 1000
            motion = app.call('window-motion')['space']
            omega = math.sqrt(motion.get('stiffness', 0) / motion.get('mass', 1))
            travel = abs(motion.get('to', 0) - motion.get('from', 0))
            remainder = travel * (1 + omega * .30) * math.exp(-omega * .30)
            row(label, bool(selected_state) and scheduled_spring(motion, .20, 1, 'position.x')
                and remainder <= .5 and travel > .5, scheduled=motion, remainingAt300msPt=remainder,
                observationMs=observed_ms, load=list(os.getloadavg()),
                scope='existing Space motion gate; RPC observation is diagnostic, not physical presentation')
            time.sleep(.35)
        switched = strip_ids()
        row('space_swap_reuses_context', switched['ids'] == [work_id] and context_ids() == contexts,
            strip=switched, before=contexts, after=context_ids())
        app.call('menu-perform', id='new-little-open-window')
        little = wait(lambda: next((s for s in app.call('little-open-state')['sessions'] if s['profile'] == work['id'] and s['content'] and not s['loading']), None), timeout=20)
        assert little, 'Work Little Open did not load'
        server, origin = _fixture_server('P10 Little Open')
        app.call('key', window=little['window'], text=origin + '/little\r', route='app')
        assert wait(lambda: next((s for s in app.call('little-open-state')['sessions'] if s['id'] == little['id'] and s['state'] == 'page' and not s['loading']), None), timeout=20)
        little_strip = app.call('ext-strip', surface='little', window=little['window'])
        row('little_work_actions', little_strip['ids'] == [work_id] and little_strip['context'] == work['directory'], strip=little_strip)
        app.call('little-open-action', id=little['id'], action='close')
        app.call('profiles-shell', action='create', name='No Space')
        no_space = next(p for p in profiles() if p['name'] == 'No Space')
        app.call('profiles-shell', profile='No Space', action='open-url', url='chrome://extensions')
        no_space_little = wait(lambda: next((s for s in app.call('little-open-state')['sessions']
            if s['profile'] == no_space['id'] and s['content'] and not s['loading']), None), timeout=20)
        assert no_space_little, 'No-Space Profile did not open its management page'
        app.call('little-open-action', id=no_space_little['id'], action='focus')
        app.call('ext-ui-menu', kind='bar', select='Manage Extensions…')
        managed_little = wait(lambda: next((s for s in app.call('little-open-state')['sessions']
            if s['id'] != no_space_little['id'] and s['profile'] == no_space['id'] and s['content'] and not s['loading']), None), timeout=20)
        no_space_url = app.call('little-open-eval', id=managed_little['id'], js='location.href') if managed_little else ''
        row('manage_without_space', bool(managed_little) and no_space['spaces'] == 0
            and managed_little['browser']['context'] == no_space['directory']
            and no_space_url.rstrip('/') == 'chrome://extensions', session=managed_little, url=no_space_url)
        for session in (no_space_little, managed_little):
            if session: app.call('little-open-action', id=session['id'], action='close')
        # Automation is read-only unless a test explicitly requests an action.
        app.call('space-create', title='Explicit Interaction', profile='Explicit Interaction')
        interaction = next(p for p in profiles() if p['name'] == 'Explicit Interaction')
        unloaded_ids = context_ids()
        explicit = app.call('extensions', create=True)
        row('explicit_interaction_load', interaction['directory'] not in unloaded_ids and explicit['loaded']
            and set(context_ids()) == set(unloaded_ids) | {interaction['directory']}, before=unloaded_ids, after=context_ids())
        app.call('space', space=work_space)
        # Delete an unused Profile through the existing typed native sheet.
        app.call('profiles-shell', action='create', name='Never Loaded')
        unused = next(p for p in profiles() if p['name'] == 'Never Loaded')
        before_delete = context_ids()
        app.call('profiles-shell', action='show', profile='Never Loaded')
        app.call('profiles-shell', action='press', label='Delete Profile')
        app.call('profiles-shell', action='type-delete', text='Never Loaded')
        app.call('profiles-shell', action='press', label='Delete')
        gone = wait(lambda: not any(p['id'] == unused['id'] for p in profiles()), timeout=15)
        row('delete_unloaded_no_context', gone and unused['directory'] not in before_delete and context_ids() == before_delete,
            before=before_delete, after=context_ids())
        # Close both windows while they are on Work, then quit the process.
        app.activation_trace = app.call('activation-events')
        app.call('ext-shortcuts', action='close')
        for window in (window_a, window_b):
            focus(window); app.call('window-close')
        app.discover_owned_processes()
        try: app.call('quit')
        except (OSError, RuntimeError, json.JSONDecodeError): pass  # Last-window close can already terminate.
        time.sleep(5)
        survivors = [pid for pid, path in app.owned_processes.items() if app.process_path(pid) == path]
        reports = sorted({p.name for p in crashes.glob('Open*.ips')} - reports_before)
        app.quit()  # Finalize harness ownership after the unforced five-second census.
        row('quit_no_orphans', not survivors and not reports, remainingProcesses=survivors, newCrashReports=reports, seconds=5)
    finally:
        if app:
            if not app.closed:
                try: app.call('ext-prompt', clear=True)
                except (RuntimeError, OSError, json.JSONDecodeError): pass
            _restore_defaults(app, saved)
            app.quit()
        if server:
            server.shutdown(); server.server_close()
