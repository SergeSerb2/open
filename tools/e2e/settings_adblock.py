"""Settings warning through the real App, live registry and native AX text."""
import json
import os
from pathlib import Path
import shutil

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
    binding(factory, results, wait)
    if os.environ.get('OPEN_E2E_ADBLOCK_BINDING_ONLY') == '1':
        return
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
    def launch(fresh=False, force_supported=True):
        nonlocal app
        app = factory(urls=(origin + '/adapter',), fresh=fresh, load_extensions=False,
                      extra_env={'OPEN_ADBLOCK_AUTOMATION_FORCE_SUPPORTED': '1' if force_supported else '0'})
        for key, value in keys.items():
            if key not in saved: saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=None)
            app.call('defaults', key=key, value=value)
        # Read-only query does not create Settings or open a Profile on our behalf.
        assert wait(lambda: query()['started'] and all(p['storeReady'] for p in query()['profiles']), timeout=30), query()
    def loaded_profile(name):
        app.call('profiles-shell', action='create', name=name)
        profile = next(p for p in profiles() if p['name'] == name)
        app.call('profiles-shell', action='open-url', url=origin + '/' + name.replace(' ', '-'))
        assert wait(lambda: state_for(query(), profile['id'])['contexts'], timeout=20), query()
        return profile

    try:
        launch(fresh=True, force_supported=False)
        unsupported = query()
        app.call('settings-pane', pane='advanced')
        app.call('settings-adblock', enabled=True)
        honest = app.call('settings-state')['advancedStatus']
        row('placeholder_unbound', unsupported['bindingInstalled'] == unsupported['nativeSupported']
            and unsupported['adapterSupported'] == unsupported['nativeSupported']
            and (unsupported['nativeSupported'] or ('Ad blocking is not active in this build' in honest
                and all(not c['adBlockEnabled'] and not c['listDirectorySet']
                        for p in unsupported['profiles'] for c in p['contexts']))),
            nativeSupported=unsupported['nativeSupported'], bindingInstalled=unsupported['bindingInstalled'],
            honestStatus='Ad blocking is not active in this build' in honest)
        app.quit()
        launch(fresh=True)
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
            and 'list_directory_set:' in copied, keys=sorted(status), noPathsOrURLs='/' not in copied and '://' not in copied)

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
