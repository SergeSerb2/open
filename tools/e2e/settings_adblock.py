"""Settings warning through the real App, live registry and native AX text."""
import json
import os
from pathlib import Path
import shutil
import time

KNOWN = 'ddkjiahejlhfcafbddmgiahcphecmpfh'
WARNING = 'More than one ad blocker is on. Blocking may break sites.'


def fixtures(root, tmp):
    known = Path(tmp) / 'known-blocker'
    shutil.copytree(Path(root) / 'tools/e2e/fixtures/adblock-known-id', known)
    other = Path(tmp) / 'ordinary-extension'
    other.mkdir()
    (other / 'manifest.json').write_text(json.dumps({
        'manifest_version': 3, 'name': 'Open ordinary extension', 'version': '1.0'}))
    return [str(known), str(other)]


def run(factory, results, tmp, root, wait):
    if os.environ.get('OPEN_E2E_ADBLOCK_REAL_ONLY') == '1':
        real_engine(factory, results, wait)
        return
    binding(factory, results, wait)
    if os.environ.get('OPEN_E2E_ADBLOCK_BINDING_ONLY') == '1':
        return
    real_engine(factory, results, wait)
    from engine_e2e import _restore_defaults
    app = factory(fresh=True)
    saved = {}
    def row(name, expected, **evidence):
        state = wait(lambda: (lambda s: s if s['hasOtherBlocker'] == expected
                     and (WARNING in s['text']) == expected else None)(
                     app.call('settings-adblock')), timeout=10)
        results['AD1_' + name] = dict(ok=bool(state), state=state or app.call('settings-adblock'), **evidence)
        print('AD1_' + name, 'PASS' if state else 'FAIL', flush=True)
    def installed(): return app.call('extensions')['installed']
    try:
        for key, value in {'open.settings.lastPane': 'general',
                           'open.general.searchSuggestNoticeDismissed': True}.items():
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=value)
        assert wait(lambda: any(e['id'] == KNOWN and e['enabled'] for e in installed()), timeout=30)
        other = next(e['id'] for e in installed() if e['name'] == 'Open ordinary extension')
        app.call('settings-pane', pane='advanced')
        native = app.call('settings-adblock')['enabled']
        app.call('settings-adblock', enabled=True)
        row('installed_open', True, knownID=KNOWN)
        ready = wait(lambda: app.call('settings-adblock')['ready'], timeout=30)
        state = app.call('settings-adblock')
        results['AD1_bundled_offline_seed'] = {'ok': bool(ready) and state['listStatus'] == ['Bundled', 'Bundled'], 'state': state}
        app.call('ext-manage', extension=KNOWN, action='disable')
        assert wait(lambda: any(e['id'] == KNOWN and not e['enabled'] for e in installed()), timeout=10)
        row('disabled_negative_ordinary', False, ordinaryID=other)
        app.call('ext-manage', extension=KNOWN, action='enable')
        row('enabled_live', True)
        app.call('settings-adblock', enabled=False)
        row('native_off', False)
        app.call('settings-adblock', enabled=True)
        row('native_on', True)
        # Settings' selected Profile must win over the focused browser Profile.
        original = app.call('settings-state')['selectedProfile']
        app.call('profiles-shell', action='create', name='No blocker')
        profiles = app.call('profiles-shell')['profiles']
        second = next(p['id'] for p in profiles if p['name'] == 'No blocker')
        app.call('profiles-shell', profile=second)
        row('selected_profile_empty', False)
        app.call('profiles-shell', profile=original)
        row('selected_profile_restored', True)
        app.call('ext-manage', extension=KNOWN, action='uninstall')
        prompt = wait(lambda: (lambda p: p if p.get('pending') and p.get('sheetVisible') else None)(app.call('ext-prompt')), timeout=10)
        assert prompt and prompt['type'] == 'uninstall'
        results['AD1_uninstall_prompt'] = {'ok': True, 'type': prompt['type'], 'sheetVisible': prompt['sheetVisible']}
        if os.environ.get('OPEN_E2E_ADBLOCK_FAIL_IN_UNINSTALL') == '1':
            raise AssertionError('forced failure with the real uninstall prompt open')
        app.call('ext-prompt', answer='accept')
        assert wait(lambda: not any(e['id'] == KNOWN for e in installed()), timeout=10)
        row('uninstalled_live', False)
        # Reopening Settings must retain the negative case with an ordinary extension.
        app.call('ext-shortcuts', action='close')
        app.call('settings-pane', pane='advanced')
        row('reopened_ordinary_only', False)
        app.call('settings-adblock', enabled=native)
    finally:
        try:
            if app.call('ext-prompt').get('pending'): app.call('ext-prompt', answer='cancel')
            app.call('profiles-shell', action='cancel')
            app.call('ext-shortcuts', action='close')
            for key, value in saved.items(): app.call('defaults', key=key, value=value)
        finally:
            app.quit()
            _restore_defaults(app, saved)


def binding(factory, results, wait):
    """Real store → adapter → regular/OTR contexts. Each launch uses factory's own root.

    Reset/finally for every row: preferences are reset on launch and restored below;
    all Profiles, exclusions and enabled state live only in the disposable data root.
    Private/Little Open/Settings windows and any delete sheet close before verified quit.
    The debug copy command restores every clipboard format before it returns.
    """
    from engine_e2e import _fixture_server, _restore_defaults
    server, origin = _fixture_server('Ad-block adapter')
    app = None
    saved = {}
    keys = {'open.settings.lastPane': 'general',
            'open.general.searchSuggestNoticeDismissed': True,
            'open.links.littleOpenNUXSeen': True}

    def query(): return app.call('settings-adblock-engine')
    def profiles(): return app.call('profiles-shell')['profiles']
    def state_for(state, profile): return next(p for p in state['profiles'] if p['profile'] == profile)
    def follows(state):
        return (state['started'] and bool(state['profiles'])
                and all(p['storeReady'] for p in state['profiles'])
                and sum(len(p['contexts']) for p in state['profiles']) > 0
                and all(c['adBlockEnabled'] == p['storeEnabled'] and c['listDirectorySet']
                        and c['listDirectoryMatchesProfile']
                        and c['excludedDomains'] == p['storeExcludedDomains']
                        and bool(c['adBlockStatus']['enabled']) == p['storeEnabled']
                        and c['adBlockStatus']['excluded_count'] == len(p['storeExcludedDomains'])
                        for p in state['profiles'] for c in p['contexts']))
    def row(name, ok, **evidence):
        results['AD2_' + name] = dict(ok=bool(ok), **evidence)
        print('AD2_' + name, 'PASS' if ok else 'FAIL', flush=True)
    def settled():
        wait(lambda: follows(query()), timeout=3)
        return query()
    def launch(fresh=False, force_supported=False):
        nonlocal app
        app = factory(urls=(origin + '/adapter',), fresh=fresh, load_extensions=False,
                      extra_env={'OPEN_ADBLOCK_AUTOMATION_FORCE_SUPPORTED': '1'} if force_supported else {})
        for key, value in keys.items():
            if key not in saved: saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=None)
            app.call('defaults', key=key, value=value)
        # Read-only query does not create Settings or open a Profile on our behalf.
        assert wait(lambda: query()['started'], timeout=30), query()
        if force_supported or query()['nativeSupported']:
            assert wait(lambda: all(p['storeReady'] for p in query()['profiles']), timeout=30), query()
    def loaded_profile(name):
        app.call('profiles-shell', action='create', name=name)
        profile = next(p for p in profiles() if p['name'] == name)
        app.call('profiles-shell', action='open-url', url=origin + '/' + name.replace(' ', '-'))
        assert wait(lambda: state_for(query(), profile['id'])['contexts'], timeout=20), query()
        return profile

    try:
        launch(fresh=True, force_supported=False)
        assert wait(lambda: 'firstContentfulPaint' in app.call('timing'), timeout=30), app.call('timing')
        # Observe the real post-paint launch without touching Settings. This query
        # is read-only; opening Settings below is the first permitted store open.
        launch_state = query()
        launch_closed = bool(launch_state['profiles']) and all(not p['storeReady'] for p in launch_state['profiles'])
        observation_start = time.monotonic()
        while time.monotonic() - observation_start < 5:
            time.sleep(.1)
            unsupported = query()
            launch_closed = launch_closed and all(not p['storeReady'] for p in unsupported['profiles'])
        observation_seconds = time.monotonic() - observation_start
        app.call('settings-pane', pane='advanced')
        selected = app.call('settings-state')['selectedProfile']
        settings_ready = bool(wait(lambda: app.call('settings-adblock')['ready'], timeout=30))
        settings_state = query()
        selected_open = state_for(settings_state, selected)['storeReady']
        app.call('settings-adblock', enabled=True)
        honest = app.call('settings-state')['advancedStatus']
        row('placeholder_unbound', unsupported['bindingInstalled'] == unsupported['nativeSupported']
            and unsupported['adapterSupported'] == unsupported['nativeSupported']
            and settings_ready and selected_open
            and (unsupported['nativeSupported'] or (launch_closed
                and 'Ad blocking is not active in this build' in honest
                and all(not c['adBlockEnabled'] and not c['listDirectorySet']
                        for p in unsupported['profiles'] for c in p['contexts']))),
            nativeSupported=unsupported['nativeSupported'], bindingInstalled=unsupported['bindingInstalled'],
            honestStatus='Ad blocking is not active in this build' in honest,
            launchProfiles=launch_state['profiles'], postPaintProfiles=unsupported['profiles'],
            postPaintObservationSeconds=observation_seconds, launchProfilesClosed=launch_closed,
            settingsSelectedProfile=selected, settingsReady=settings_ready, settingsSelectedProfileOpen=selected_open)
        app.quit()
        launch(fresh=True, force_supported=not unsupported['nativeSupported'])
        initial = settled()
        row('a_launch_loaded_profiles', follows(initial), state=initial)
        original = next(p for p in profiles() if p['name'] == 'Default')
        normal = next(w for w in app.call('incognito-state')['windows'] if not w['private'])
        other = loaded_profile('Adapter Other')
        app.call('profiles-shell', profile=original['id'], action='adblock-open')
        app.call('window-focus', id=normal['id'], activate=True)
        app.call('menu-perform', id='new-incognito-window')
        private = wait(lambda: next((w for w in app.call('incognito-state')['windows'] if w['private']), None), timeout=10)
        assert private, 'OTR window not created'
        app.call('window-focus', id=private['id'], activate=True)
        app.call('dismiss')
        tab = app.call('open', url=origin + '/private')['id']
        app.call('wait', tab=tab)
        assert wait(lambda: any(c['offTheRecord'] for c in state_for(query(), original['id'])['contexts']), timeout=20), query()
        private_state = settled()
        row('d_new_otr_inherits', follows(private_state)
            and any(c['offTheRecord'] for c in state_for(private_state, original['id'])['contexts']), state=private_state)

        app.call('settings-pane', pane='advanced')
        app.call('settings-adblock', enabled=False)
        off = settled()
        app.call('settings-adblock', enabled=True)
        on = settled()
        row('b_global_off_on_all_contexts', follows(off) and follows(on)
            and all(not c['adBlockEnabled'] for p in off['profiles'] for c in p['contexts'])
            and all(c['adBlockEnabled'] for p in on['profiles'] for c in p['contexts']), off=off, on=on)

        app.call('profiles-shell', profile=original['id'], action='adblock-open')
        other_before = state_for(query(), other['id'])
        app.call('settings-adblock', host='sub.adapter.example.com', excluded=True)
        added = settled()
        app.call('settings-adblock', host='sub.adapter.example.com', excluded=False)
        removed = settled()
        row('c_exclusion_profile_only', follows(added) and follows(removed)
            and all(c['excludedDomains'] == ['example.com'] for c in state_for(added, original['id'])['contexts'])
            and all(c['excludedDomains'] == [] for c in state_for(removed, original['id'])['contexts'])
            and state_for(added, other['id']) == other_before
            and state_for(removed, other['id']) == other_before, added=added, removed=removed)

        copied = app.call('settings-adblock', copyDebug=True)['copiedDebugInfo']
        status = state_for(query(), original['id'])['contexts'][0]['adBlockStatus']
        engine_lines = app.call('settings-adblock', copyDebug=True)['copiedDebugInfo'].splitlines()[-len(status):]
        row('f_copy_debug_no_path_url', bool(copied) and '/' not in copied and '://' not in copied
            and str(Path(app.user_data)) not in copied and 'example.com' not in copied
            and [line.split(':', 1)[0] for line in engine_lines] == sorted(status)
            and (query()['nativeSupported'] or 'list_directory_set:' in copied), keys=sorted(status), noPathsOrURLs='/' not in copied and '://' not in copied)

        app.call('settings-adblock', enabled=False)
        created = loaded_profile('Adapter New')
        new_state = settled()
        row('e_new_profile_configured', follows(new_state)
            and bool(state_for(new_state, created['id'])['contexts'])
            and all(not c['adBlockEnabled'] for c in state_for(new_state, created['id'])['contexts']), state=new_state)
        app.call('profiles-shell', profile=created['id'], action='show')
        app.call('profiles-shell', action='press', label='Delete Profile')
        assert wait(lambda: app.call('profiles-shell')['sheet'] > 0, timeout=5)
        if os.environ.get('OPEN_E2E_ADBLOCK_FAIL_IN_DELETE') == '1':
            raise AssertionError('forced failure with real Profile delete sheet open')
        app.call('profiles-shell', action='type-delete', text='Adapter New')
        app.call('profiles-shell', action='press', label='Delete')
        assert wait(lambda: not app.call('profiles-shell')['deleting'] and app.call('profiles-shell')['sheet'] == 0, timeout=20)
        folder = Path(app.user_data) / 'Profiles' / created['directory']
        row('e_deleted_context_retired', not folder.exists()
            and created['directory'] not in app.call('engine-contexts'), folderAbsent=not folder.exists())
        # Relaunch keeps global off and independently saved exclusions. #241's
        # profiles-shell adblock suite covers delete during real in-flight IO too.
        app.call('profiles-shell', profile=original['id'], action='adblock-open')
        app.call('settings-adblock', host='sub.adapter.example.org', excluded=True)
        app.call('save')
        app.quit()
        launch()
        relaunched = settled()
        row('a_relaunch_persisted_config', follows(relaunched)
            and all(not p['storeEnabled'] for p in relaunched['profiles'])
            and state_for(relaunched, original['id'])['storeExcludedDomains'] == ['example.org']
            and not folder.exists(), state=relaunched)
    finally:
        try:
            if app is not None and not app.closed:
                try:
                    app.call('profiles-shell', action='cancel')
                    app.call('ext-shortcuts', action='close')
                    for key, value in saved.items(): app.call('defaults', key=key, value=value)
                finally:
                    app.quit()
            if app is not None: _restore_defaults(app, saved)
        finally:
            server.shutdown()
            server.server_close()


def real_engine(factory, results, wait):
    """Settings → production CEF API → real requests, with no support override.

    The pinned EasyList contains ||demand.supply^$script; EasyPrivacy does not.
    Host mapping sends both origins to this private server. No request reaches
    that public host. Every case has an allowed control script. Preferences are
    reset at launch and restored in finally; all Profile data is disposable.
    """
    import hashlib
    import http.server
    import statistics
    import threading
    import urllib.parse
    from engine_e2e import _restore_defaults

    requests = []
    repo = Path(__file__).resolve().parents[2]
    pinned = {}
    for line in (repo / 'Packages/OpenKit/Sources/OpenAdBlock/Resources/list-pins.txt').read_text().splitlines():
        if not line.strip() or line.startswith('#'): continue
        name, _, digest = line.split()
        body = (repo / 'Vendor/adblock' / name).read_bytes()
        assert hashlib.sha256(body).hexdigest() == digest, 'fixture must match the official bundled pin'
        pinned[name] = body
    synthetic_lists = threading.Event()
    hold_lists, list_started, release_lists = (threading.Event() for _ in range(3))
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            if self.path.endswith('.txt'):
                if hold_lists.is_set():
                    list_started.set()
                    release_lists.wait(timeout=40)
                name = Path(urllib.parse.urlsplit(self.path).path).name
                body = (b'[Adblock Plus 2.0]\n||demand.supply^$script\n' if synthetic_lists.is_set() else pinned[name])
                mime = 'text/plain'
            elif self.path.startswith('/ad.js'):
                body, mime = b'window.__adLoaded=true;', 'application/javascript'
            elif self.path.startswith('/control.js'):
                body, mime = b'window.__controlLoaded=true;', 'application/javascript'
            else:
                body = b'''<!doctype html><title>Open ad-block acceptance</title>
<link rel="icon" href="data:,"><script>window.__done=0;</script>
<script src="http://demand.supply/ad.js" onload="__done++" onerror="__done++"></script>
<script src="/control.js" onload="__done++" onerror="__done++"></script>'''
                mime = 'text/html'
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
        def log_message(self, *_): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    app, saved = None, {}
    origin = 'http://open-adblock.test'
    keys = {'open.settings.lastPane': 'general',
            'open.general.searchSuggestNoticeDismissed': True,
            'open.links.littleOpenNUXSeen': True}
    args = ['--host-resolver-rules=MAP open-adblock.test 127.0.0.1:%d, MAP demand.supply 127.0.0.1:%d' %
            (server.server_port, server.server_port), '--no-proxy-server']
    def query(): return app.call('settings-adblock-engine')
    def profile_state(profile): return next(p for p in query()['profiles'] if p['profile'] == profile)
    def status(profile, private=False):
        return next(c['adBlockStatus'] for c in profile_state(profile)['contexts'] if c['offTheRecord'] == private)
    def loaded(profile, private=False):
        return wait(lambda: (lambda s: s if s['engine_loaded'] else None)(status(profile, private)), timeout=40)
    def count(tab):
        page = app.call('tab-state', tab=tab)['page']['identifier']
        return next(p['blockedCount'] for profile in query()['profiles']
                    for context in profile['contexts'] for p in context['pages'] if p['identifier'] == page)
    def browser_footprint():
        return next(p['footprint'] for p in app.call('metrics', interval=0)['processes']
                    if p['pid'] == app.pid)
    def row(name, ok, **evidence):
        results['AD3_' + name] = dict(ok=bool(ok), **evidence)
        print('AD3_' + name, 'PASS' if ok else 'FAIL', flush=True)
    observations = {}
    def request_verdict(evidence, blocked):
        state = evidence['scriptState']
        return (state['control'] and state['ad'] == (not blocked)
                and (evidence['blockedCount'] > 0 if blocked else evidence['blockedCount'] == 0)
                and ('net::ERR_BLOCKED_BY_CLIENT' in evidence['networkErrors']) == blocked
                and evidence['adReachedServer'] == (not blocked))
    def visit(tab, name, blocked):
        app.call('devtools', tab=tab, method='Network.enable')
        app.call('events')
        requests.clear()
        app.call('navigate', tab=tab, url=origin + '/' + name)
        app.call('wait', tab=tab)
        assert wait(lambda: app.call('eval', tab=tab, js='window.__done===2'), timeout=20)
        wait(lambda: count(tab) > 0 if blocked else count(tab) == 0, timeout=3)
        state = app.call('eval', tab=tab, js='({ad:window.__adLoaded===true,control:window.__controlLoaded===true})')
        events = app.call('events')
        errors = [e['params'].get('errorText') for e in events
                  if e['type'] == 'devtools' and e['method'] == 'Network.loadingFailed']
        native_count = count(tab)
        evidence = dict(blockedCount=native_count, scriptState=state, networkErrors=errors,
                        adReachedServer=any(p.startswith('/ad.js') for p in requests))
        observations[name] = evidence
        ok = request_verdict(evidence, blocked)
        row(name, ok, **evidence)
        return ok
    def next_request(tab, name, blocked):
        before = count(tab)
        app.call('events')
        requests.clear()
        completed = app.call('eval', tab=tab, js='new Promise(resolve=>{const s=document.createElement("script");s.onload=()=>resolve("load");s.onerror=()=>resolve("error");s.src="http://demand.supply/ad.js?probe=' + name + '";document.body.append(s)})')
        if blocked: wait(lambda: count(tab) > before, timeout=3)
        events = app.call('events')
        errors = [e['params'].get('errorText') for e in events
                  if e['type'] == 'devtools' and e['method'] == 'Network.loadingFailed']
        after = count(tab)
        reached = any(p.startswith('/ad.js?probe=') for p in requests)
        row(name, completed == ('error' if blocked else 'load')
            and (after > before if blocked else after == before)
            and ('net::ERR_BLOCKED_BY_CLIENT' in errors) == blocked
            and reached == (not blocked), before=before, after=after,
            completion=completed, networkErrors=errors, adReachedServer=reached)
    try:
        app = factory(urls=('about:blank',), fresh=True, load_extensions=False, extra_args=args,
                      extra_env={'OPEN_ADBLOCK_DEBUG_SCHEDULE_SCALE': '0.1',
                                 'OPEN_ADBLOCK_DEBUG_SOURCE_ROOT': 'http://127.0.0.1:%d' % server.server_port})
        for key, value in keys.items():
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=None)
            app.call('defaults', key=key, value=value)
        native = query()['nativeSupported']
        bound = wait(lambda: query()['bindingInstalled'], timeout=30) if native else False
        row('native_support_without_override', native and bound)
        if not native:
            return  # Placeholder coverage is the separate AD2 flow.
        original = next(p for p in app.call('profiles-shell')['profiles'] if p['name'] == 'Default')
        app.call('profiles-shell', profile=original['id'], action='adblock-open')
        app.call('settings-adblock', enabled=True)
        assert loaded(original['id'])
        tab = app.call('open', url='about:blank')['id']
        visit(tab, 'enabled_blocks', True)
        app.call('settings-adblock', host='open-adblock.test', excluded=True)
        visit(tab, 'excluded_allows', False)
        app.call('settings-adblock', host='open-adblock.test', excluded=False)
        next_request(tab, 'reincluded_next_request_same_document', True)
        visit(tab, 'reincluded_blocks', True)
        app.call('settings-adblock', enabled=False)
        visit(tab, 'global_off_allows', False)
        app.call('settings-adblock', enabled=True)
        next_request(tab, 'global_on_next_request_same_document', True)
        visit(tab, 'global_on_blocks_same_process', True)
        app.call('settings-adblock', enabled=False)
        next_request(tab, 'global_off_next_request_same_document', False)
        app.call('settings-adblock', enabled=True)

        assert wait(lambda: status(original['id'])['load_generation'] > 1, timeout=40)
        before = status(original['id'])['load_generation']
        app.call('settings-adblock', list='EasyList', listEnabled=False)
        assert wait(lambda: status(original['id'])['load_generation'] > before, timeout=40)
        disabled = status(original['id'])
        visit(tab, 'list_disabled_allows', False)
        app.call('settings-adblock', list='EasyList', listEnabled=True)
        assert wait(lambda: status(original['id'])['load_generation'] > disabled['load_generation'], timeout=40)
        restored = status(original['id'])
        visit(tab, 'list_enabled_blocks', True)
        row('settings_generation_reload', disabled['load_generation'] > before
            and restored['load_generation'] > disabled['load_generation'],
            before=before, disabled=disabled['load_generation'], restored=restored['load_generation'])

        app.call('profiles-shell', action='create', name='Engine Independent')
        other = next(p for p in app.call('profiles-shell')['profiles'] if p['name'] == 'Engine Independent')
        app.call('profiles-shell', profile=other['id'], action='open-url', url='about:blank')
        other_tab = next(t['id'] for t in app.call('tabs') if t['profile'] == other['id'])
        assert loaded(other['id'])
        assert wait(lambda: status(other['id'])['load_generation'] > 1, timeout=40)
        shared = status(other['id'])
        row('second_profile_shares_engine', shared['engine_shared'], status=shared)
        app.call('profiles-shell', profile=other['id'], action='adblock-open')
        app.call('settings-adblock', host='open-adblock.test', excluded=True)
        visit(other_tab, 'other_profile_excluded', False)
        row('profile_exclusions_independent', not profile_state(original['id'])['storeExcludedDomains']
            and profile_state(other['id'])['storeExcludedDomains'] == ['open-adblock.test'])
        app.call('settings-adblock', host='open-adblock.test', excluded=False)
        time.sleep(6)
        independent_before = [browser_footprint() for _ in range(5)]
        app.call('settings-adblock', list='EasyList', listEnabled=False)
        assert wait(lambda: status(other['id'])['list_count'] == 1, timeout=40)
        time.sleep(6)
        independent_after = [browser_footprint() for _ in range(5)]
        visit(other_tab, 'other_profile_list_independent', False)
        independent = status(other['id'])
        row('profile_lists_independent', status(original['id'])['list_count'] == 2
            and independent['list_count'] == 1)
        independent_delta = statistics.median(independent_after) - statistics.median(independent_before)
        row('sharing_rejects_different_lists_control', not independent['engine_shared']
            and independent_delta > 2 * 1024 * 1024,
            listCount=independent['list_count'], engineShared=independent['engine_shared'],
            before=independent_before, after=independent_after, deltaBytes=independent_delta,
            load=os.getloadavg())
        previous_generation = status(other['id'])['load_generation']
        app.call('settings-adblock', list='EasyPrivacy', listEnabled=False)
        assert wait(lambda: status(other['id'])['load_generation'] > previous_generation
                    and status(other['id'])['list_count'] == 0, timeout=40)
        visit(other_tab, 'all_lists_disabled_allows', False)
        # Both contexts already exist. Price only the empty → shared engine
        # transition, after idle reclaim, rather than Profile/window creation.
        time.sleep(6)
        memory_before = [browser_footprint() for _ in range(5)]
        app.call('settings-adblock', resetLists=True)
        assert wait(lambda: status(other['id'])['list_count'] == 2, timeout=40)
        time.sleep(6)
        memory_after = [browser_footprint() for _ in range(5)]
        delta = statistics.median(memory_after) - statistics.median(memory_before)
        row('shared_engine_footprint', status(other['id'])['engine_shared'] and delta <= 2 * 1024 * 1024,
            before=memory_before, after=memory_after, deltaBytes=delta, load=os.getloadavg())
        app.call('ext-shortcuts', action='close')
        app.call('select', tab=other_tab)
        app.call('menu-perform', id='new-incognito-window')
        private = wait(lambda: next((w for w in app.call('incognito-state')['windows'] if w['private']), None), timeout=15)
        assert private
        app.call('window-focus', id=private['id'], activate=True)
        private_tab = app.call('open', url='about:blank')['id']
        assert loaded(other['id'], True)
        row('otr_shares_parent_engine', status(other['id'], True)['engine_shared'])
        visit(private_tab, 'otr_parent_enabled_blocks', True)
        app.call('profiles-shell', profile=other['id'], action='adblock-open')
        app.call('settings-adblock', host='open-adblock.test', excluded=True)
        visit(private_tab, 'otr_parent_excluded_allows', False)
        app.call('settings-adblock', host='open-adblock.test', excluded=False)
        visit(private_tab, 'otr_parent_reincluded_blocks', True)
        copied = app.call('settings-adblock', copyDebug=True)['copiedDebugInfo']
        debug_keys = sorted(status(other['id']))
        expected_keys = sorted(['enabled', 'engine_loaded', 'engine_from_dat', 'engine_shared',
                               'dat_policy', 'list_count', 'resources_loaded', 'last_build_ms',
                               'last_error', 'excluded_count', 'load_generation'])
        row('debug_copy_privacy', bool(copied) and '/' not in copied and '://' not in copied
            and 'open-adblock.test' not in copied and app.user_data not in copied
            and debug_keys == expected_keys, keys=debug_keys)
        # The inverse controls use actual completed requests from this App.
        # The same gate must reject the opposite real result, including its
        # native count, CDP completion and server observation.
        pairs = [('enabled_blocks', 'global_off_allows'),
                 ('reincluded_blocks', 'excluded_allows'),
                 ('global_on_blocks_same_process', 'global_off_allows'),
                 ('list_enabled_blocks', 'list_disabled_allows'),
                 ('enabled_blocks', 'other_profile_excluded'),
                 ('list_enabled_blocks', 'other_profile_list_independent'),
                 ('list_enabled_blocks', 'all_lists_disabled_allows'),
                 ('otr_parent_enabled_blocks', 'otr_parent_excluded_allows'),
                 ('otr_parent_reincluded_blocks', 'otr_parent_excluded_allows')]
        row('request_gates_reject_inverse_controls', all(
            request_verdict(observations[positive], True)
            and request_verdict(observations[negative], False)
            and not request_verdict(observations[negative], True)
            and not request_verdict(observations[positive], False)
            for positive, negative in pairs), pairs=pairs)

        # Real scheduled HTTP load with an already-loaded native context. The
        # same Settings delete sheet retires the store and the engine together.
        app.quit()
        synthetic_lists.set()
        app = factory(urls=('about:blank',), fresh=True, load_extensions=False, extra_args=args,
                      extra_env={'OPEN_ADBLOCK_DEBUG_SOURCE_ROOT': 'http://127.0.0.1:%d' % server.server_port,
                                 'OPEN_ADBLOCK_DEBUG_SCHEDULE_SCALE': '0.1'})
        for key, value in keys.items():
            app.call('defaults', key=key, value=None)
            app.call('defaults', key=key, value=value)
        app.call('settings-pane', pane='advanced')
        app.call('settings-adblock', enabled=True)
        default_profile = next(p for p in app.call('profiles-shell')['profiles'] if p['name'] == 'Default')
        # Let Default's one initial scheduled update finish first. The next
        # update is hours away; the held HTTP request below is the victim's.
        assert wait(lambda: status(default_profile['id'])['load_generation'] > 1, timeout=40)
        list_started.clear()
        hold_lists.set()
        app.call('profiles-shell', action='create', name='Engine Delete')
        victim = next(p for p in app.call('profiles-shell')['profiles'] if p['name'] == 'Engine Delete')
        app.call('profiles-shell', profile=victim['id'], action='open-url', url=origin + '/delete')
        assert loaded(victim['id'])
        native_before = status(victim['id'])
        active = wait(lambda: list_started.is_set() and app.call('profiles-shell',
                      adblockProfile=victim['id'])['adblockProfileUpdating'], timeout=15)
        assert active, 'victim did not enter the held real list load'
        app.call('profiles-shell', profile=victim['id'], action='show')
        app.call('profiles-shell', action='press', label='Delete Profile')
        assert wait(lambda: app.call('profiles-shell')['sheet'] > 0, timeout=5)
        if os.environ.get('OPEN_E2E_ADBLOCK_REAL_FAIL_IN_DELETE_SHEET') == '1':
            raise AssertionError('forced failure with the real engine deletion sheet open')
        app.call('profiles-shell', action='press', label='Cancel')
        assert wait(lambda: app.call('profiles-shell')['sheet'] == 0, timeout=5)
        folder = Path(app.user_data) / 'Profiles' / victim['directory']
        cancelled = app.call('profiles-shell', adblockProfile=victim['id'])
        row('delete_gate_rejects_cancel_control', folder.exists()
            and victim['directory'] in app.call('engine-contexts')
            and not cancelled['adblockProfileRetired'] and status(victim['id'])['engine_loaded'],
            folderPresent=folder.exists(), retired=cancelled['adblockProfileRetired'])
        app.call('profiles-shell', action='press', label='Delete Profile')
        assert wait(lambda: app.call('profiles-shell')['sheet'] > 0, timeout=5)
        app.call('profiles-shell', action='type-delete', text='Engine Delete')
        app.call('profiles-shell', action='press', label='Delete')
        assert wait(lambda: not app.call('profiles-shell')['deleting'] and app.call('profiles-shell')['sheet'] == 0, timeout=30)
        folder = Path(app.user_data) / 'Profiles' / victim['directory']
        retired = app.call('profiles-shell', adblockProfile=victim['id'])
        release_lists.set()
        app.call('save')
        app.quit()
        app = factory(urls=('about:blank',), load_extensions=False)
        row('delete_during_load_relaunch', bool(active) and native_before['engine_loaded']
            and retired['adblockProfileRetired'] and not retired['adblockProfileUpdating']
            and not folder.exists() and victim['directory'] not in app.call('engine-contexts'),
            nativeEngineLoaded=native_before['engine_loaded'], realHTTPInFlight=bool(active),
            retired=retired['adblockProfileRetired'], folderAbsentAfterRelaunch=not folder.exists())
    finally:
        release_lists.set()
        try:
            if app is not None and not app.closed:
                try:
                    app.call('profiles-shell', action='cancel')
                    app.call('ext-shortcuts', action='close')
                    for key, value in saved.items(): app.call('defaults', key=key, value=value)
                finally: app.quit()
            if app is not None: _restore_defaults(app, saved)
        finally:
            server.shutdown()
            server.server_close()
