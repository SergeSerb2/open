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
