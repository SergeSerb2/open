"""Import report -> real per-Profile Chromium installs and consent sheets.

Runs inside firstrun's screen lock. All data and signed CRX3s are synthetic.
Set OPEN_E2E_IMPORT_EXT_ONLY=1 for this block without unrelated first-run rows.
"""
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import time

# The engine harness uses Python's isolated mode, which omits sibling modules.
pack_probe = runpy.run_path(str(Path(__file__).with_name('extensions_p3.py')))['pack_probe']


def run(launch, state, until, row, source, tmp, h, results):
    negative = os.environ.get("OPEN_E2E_IMPORT_EXT_NEGATIVE", "")
    fixture = Path(tmp) / 'arc-extension-import'
    shutil.copytree(source, fixture, dirs_exist_ok=True)
    sidebar = json.loads((fixture/'StorableSidebar.json').read_text())
    spaces = sidebar['sidebar']['containers'][1]['spaces']
    spaces[3]['profile'] = {'custom': {'_0': {'directoryBasename': 'Profile 2',
        'machineID': '0F085EC9-2E74-48A5-9D88-4BAFC4686164'}}}
    (fixture/'StorableSidebar.json').write_text(json.dumps(sidebar))
    (fixture/'User Data/Local State').write_text(json.dumps({'profile': {'info_cache': {
        'Default': {'name': 'Example Personal'}, 'Profile 2': {'name': 'Example Work'}}}}))
    files, identifiers = {}, {}
    for label in ('existing', 'failed', 'install'):
        crx = Path(pack_probe(h.ROOT, tmp, 'import-' + label))
        digest = hashlib.sha256(crx.with_suffix('.der').read_bytes()).digest()[:16].hex()
        identifiers[label] = ''.join(chr(ord('a') + int(c, 16)) for c in digest)
        files[identifiers[label]] = str(crx)
    # Chromium must reject this signed CRX through the completion API.
    failed_file = Path(files[identifiers['failed']])
    if negative != 'queue':
        damaged = bytearray(failed_file.read_bytes()); damaged[-1] ^= 1
        failed_file.write_bytes(damaged)
    if negative != 'queue':
        # Refuse before calling the engine; no event or timeout is fabricated.
        files[identifiers['failed']] = str(Path(tmp)/'missing-import-fixture.crx')
    names = {'existing': 'Example Already Installed', 'failed': 'Example Failed Extension',
             'install': 'Example Installed Extension'}
    internals = ['a'*32, 'b'*32]
    for directory, labels, internal in [('Default', ('existing', 'failed'), internals[0]),
                                        ('Profile 2', ('install',), internals[1])]:
        target = fixture/'User Data'/directory
        target.mkdir(parents=True, exist_ok=True)
        settings = {identifiers[label]: {'path': 'Extensions/' + identifiers[label], 'from_webstore': True,
                    'manifest': {'manifest_version': 3, 'name': names[label], 'version': '1.0'}} for label in labels}
        settings[internal] = {'path': '/Applications/Arc.app/Contents/ExampleInternal',
                              'manifest': {'name': 'Example Internal', 'manifest_version': 3, 'version': '1'}}
        (target/'Secure Preferences').write_text(json.dumps({'extensions': {'settings': settings}}))
    if negative == 'detection':
        # Real input faults: one built-in now claims to be a store extension,
        # and the second Space points at the first Profile. Restore on relaunch.
        prefs = fixture/'User Data/Default/Secure Preferences'
        payload = json.loads(prefs.read_text())
        payload['extensions']['settings'][internals[0]]['path'] = 'Extensions/example'
        prefs.write_text(json.dumps(payload))
        spaces[3]['profile'] = {'default': True}
        (fixture/'StorableSidebar.json').write_text(json.dumps(sidebar))
    if negative == 'queue':
        # An actual source ownership fault must fail the target-manager gate.
        personal_prefs = fixture/'User Data/Default/Secure Preferences'
        work_prefs = fixture/'User Data/Profile 2/Secure Preferences'
        a, b = json.loads(personal_prefs.read_text()), json.loads(work_prefs.read_text())
        a['extensions']['settings'][identifiers['install']] = b['extensions']['settings'].pop(identifiers['install'])
        personal_prefs.write_text(json.dumps(a)); work_prefs.write_text(json.dumps(b))
    app = None
    saved = {}
    def ext(**args): return app.call('import-extensions', **args)
    def pending():
        value = app.call('ext-prompt')
        return value if value.get('pending') else None
    def registries():
        value = h.wait_until(lambda: (lambda r: r if all(p['ready'] for p in r['profiles']) else None)(
            ext(action='registries')), timeout=20)
        return {p['profile']: set(p['installed']) for p in value['profiles']}
    def install_rows(): return {r['extension']: r for r in ext()['rows']}
    def selected(only):
        for r in ext()['rows']: ext(action='toggle', row=r['row'], on=r['extension'] in only)
    def settings_import(directory):
        app.call('first-run', action='settings-import', directory=str(directory))
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        assert h.wait_until(lambda: state().get('settingsStep') == 'Report', timeout=20), state()
    def settings_done():
        # SwiftUI dismisses its native report sheet asynchronously. Wait for
        # that exact window to go before replacing the wizard on re-import.
        sheets = {w['attachedSheet'] for w in app.call('windows') if w['visible'] and w['attachedSheet']}
        assert len(sheets) == 1, 'expected one native Settings import sheet'
        app.call('first-run', action='settings-done')
        assert h.wait_until(lambda: not sheets.intersection(
            w['number'] for w in app.call('windows') if w['visible']), timeout=10), 'Settings import sheet did not dismiss'
    def queue(answer, hold_consent=False):
        ext(action='install')
        prompts = []
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            p = pending()
            if p:
                if negative == 'abort-sheet':
                    raise RuntimeError('deliberate early failure with ExtensionPromptSheet open')
                if hold_consent:
                    started = time.monotonic()
                    # Cross the removed 45 s timeout while the real sheet stays
                    # unanswered. This harness bound never completes the App.
                    while time.monotonic() - started < 46:
                        time.sleep(.25)
                    p['heldSeconds'] = time.monotonic() - started
                    waiting = ext()
                    p['stillWaiting'] = (waiting['installing'] and not waiting['summary']
                        and all(not r['status'] for r in waiting['rows']) and bool(pending()))
                prompts.append(p)
                app.call('ext-prompt', answer=answer)
            if not ext()['installing']: return ext(), prompts
            time.sleep(.05)
        raise RuntimeError('import extension queue did not finish')
    try:
        app = launch(fresh=True, directory=fixture)
        for key in ('open.firstRun.completed', 'open.import.lastArcDir', 'open.settings.lastPane'):
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=None)
        app.call('first-run', action='import'); app.call('first-run', action='continue'); until('report')
        ext(action='fixtures', files=files)
        current = ext(); rows = install_rows()
        rendered = ' '.join(r['text'] for r in ext(action='inspect')['text']).casefold()
        profile_by_space = {s['title']: s['profile'] for s in app.call('spaces')}
        personal, work = profile_by_space['Alpha'], profile_by_space['Beta']
        row('EI_candidates', current['visible'] and len(rows) == 3 and set(rows) == set(identifiers.values())
            and all(r['selected'] for r in rows.values())
            and all(name.casefold() in rendered for name in names.values()), candidates=len(rows), selected=sum(r['selected'] for r in rows.values()))
        counts = state()['outcome']
        row('EI_internal_hidden', not set(internals).intersection(rows) and 'example internal' not in rendered
            and counts.get('Extensions total') == 5 and counts.get('Extensions internal') == 2
            and counts.get('Extensions candidates') == 3 and counts.get('Extensions missing manifest') == 0,
            counts={k:v for k,v in counts.items() if k.startswith('Extensions')})
        row('EI_profile_labels', current['showsProfiles'] and personal != work
            and all(name in rendered for name in ('example personal', 'example work'))
            and rows[identifiers['install']]['profile'] == work
            and all(rows[identifiers[label]]['profile'] == personal for label in ('existing', 'failed')),
            profiles=len({r['profile'] for r in rows.values()}))
        if negative == 'detection':
            return  # The same EI detection rows above must be FAIL.
        if negative == 'queue':
            selected({identifiers['install']})
            queue('accept')  # Break the untouched-before-click condition.
            settings = install_rows()
            rows = settings
        before = registries()
        row('EI_click_required', not pending() and not any(set(identifiers.values()) & values for values in before.values())
            and all(not r['status'] for r in rows.values()), installed=sum(len(v) for v in before.values()))
        selected(set())
        if negative == 'queue': selected({identifiers['existing']})
        refused = False
        try:
            if negative != 'queue': ext(action='install')
        except RuntimeError as error: refused = 'disabled' in str(error)
        row('EI_empty_selection', not ext()['canInstall'] and refused and not pending())
        selected({identifiers['install']})
        if negative == 'queue':
            cancelled, prompts = ext(), []
        else:
            cancelled, prompts = queue('cancel', hold_consent=True)
        row('EI_cancel_skips', install_rows()[identifiers['install']]['status'] == 'Skipped (cancelled)'
            and identifiers['install'] not in registries()[work] and len(prompts) == 1
            and prompts[0]['sheetVisible'] and prompts[0]['sheetClass'] == 'ExtensionPromptSheet'
            and prompts[0]['parentWindow'] == state()['window'] and prompts[0].get('stillWaiting', False),
            prompts=len(prompts), summary=cancelled['summary'],
            heldSeconds=prompts[0].get('heldSeconds', 0) if prompts else 0,
            stillWaiting=prompts[0].get('stillWaiting', False) if prompts else False)
        # Completing first run does not require installing any candidate.
        app.call('first-run', action='continue'); app.call('first-run', action='finish')
        row('EI_finish_without_install', not state()['active'] and state()['completed']
            and not any(set(identifiers.values()) & values for values in registries().values()))
        # Reimport into a fresh live Default with a different ID. The source
        # role must resolve to that context rather than its stable imported ID.
        imported_personal = personal
        if negative != 'queue':
            app.quit()
            app = launch(fresh=True, directory=fixture)
            app.call('defaults', key='open.firstRun.completed', value=None)
            app.call('first-run', action='fresh')
        live_default = app.call('profiles-shell')['profiles'][0]['id']
        settings_import(fixture)
        ext(action='fixtures', files=files)
        rows = install_rows()
        profile_by_space = {s['title']: s['profile'] for s in app.call('spaces')}
        personal, work = profile_by_space['Alpha'], profile_by_space['Beta']
        row('EI_default_role_mapping', personal == live_default and personal != imported_personal
            and all(rows[identifiers[label]]['profile'] == live_default for label in ('existing', 'failed'))
            and rows[identifiers['install']]['profile'] == work and work != live_default,
            liveDefaultMapped=personal == live_default, sourceIDDiffers=personal != imported_personal)
        # Install the Default candidate through the report itself, then check
        # both actual managers. Its next import must skip it as already present.
        if negative != 'queue':
            selected({identifiers['existing']})
            queue('accept')
        registry = registries()
        row('EI_default_role_target', identifiers['existing'] in registry[personal]
            and identifiers['existing'] not in registry[work],
            installedInLiveDefault=identifiers['existing'] in registry[personal],
            absentInOther=identifiers['existing'] not in registry[work])
        settings_done()
        # Add one tab so Settings import owns a real, independently undoable action.
        modified = json.loads((fixture/'StorableSidebar.json').read_text())
        graph = modified['sidebar']['containers'][1]
        new_id = 'B9E4BC40-149C-48D4-8311-9C732EB92B4A'
        container = graph['spaces'][1]['containerIDs'][-1]
        graph['items'][graph['items'].index(container)+1]['childrenIds'].append(new_id)
        graph['items'] += [new_id, {'id': new_id, 'childrenIds': [], 'title': 'Example extension import tab',
            'data': {'tab': {'savedURL': 'https://example.com/extension-import', 'savedTitle': 'Example extension import tab'}}}]
        (fixture/'StorableSidebar.json').write_text(json.dumps(modified))
        settings_import(fixture)
        if negative == 'queue': settings_done()
        current = ext()
        row('EI_settings_section', current['visible'] and len(current['rows']) == 3 and current['showsProfiles'])
        if negative == 'queue': settings_import(fixture)
        # Keep App preflight rejection separate from Chromium rejection.
        selected({identifiers['failed']})
        app_result, _ = queue('accept')
        rows = install_rows()
        row('EI_failure_reported_app', rows[identifiers['failed']]['status'] == 'Failed: The local fixture file is missing or unreadable.'
            and identifiers['failed'] not in set().union(*registries().values())
            and app_result['summary'] == 'Installed 0 · Skipped 0 · Failed 1'
            and not app_result['installing'], status=rows[identifiers['failed']]['status'], summary=app_result['summary'])
        settings_done()
        settings_import(fixture)
        files[identifiers['failed']] = str(failed_file)
        ext(action='fixtures', files=files)
        result, prompts = queue('accept')
        rows = install_rows(); registry = registries()
        row('EI_already_installed', rows[identifiers['existing']]['status'] == 'Skipped (already installed)'
            and all(p['extension'] != identifiers['existing'] for p in prompts), status=rows[identifiers['existing']]['status'])
        inspection = ext(action='inspect')
        rendered = ' '.join(r['text'] for r in inspection['text'])
        signature_error = 'CRX_SIGNATURE_VERIFICATION_FAILED'
        # OCR can render underscores as spaces; the model must retain the exact error.
        rendered_error = ''.join(c for c in rendered if c.isalnum()).casefold()
        signature_visible = signature_error.replace('_', '').casefold() in rendered_error
        row('EI_failure_reported_engine', rows[identifiers['failed']]['status'].startswith('Failed: ')
            and signature_error in rows[identifiers['failed']]['status']
            and signature_visible
            and identifiers['failed'] not in set().union(*registry.values())
            and result['summary'] == 'Installed 1 · Skipped 1 · Failed 1'
            and rows[identifiers['install']]['status'] == 'Installed' and not result['installing'],
            status=rows[identifiers['failed']]['status'], summary=result['summary'],
            nextInstalled=rows[identifiers['install']]['status'] == 'Installed', renderedSignature=signature_visible)
        row('EI_target_profile', rows[identifiers['install']]['status'] == 'Installed'
            and identifiers['install'] in registry[work] and identifiers['install'] not in registry[personal]
            and identifiers['existing'] in registry[personal] and identifiers['existing'] not in registry[work],
            installedInTarget=identifiers['install'] in registry[work], absentInOther=identifiers['install'] not in registry[personal])
        row('EI_result_counts', result['summary'] == 'Installed 1 · Skipped 1 · Failed 1'
            and len(prompts) == 1 and not result['canInstall'] and not pending(), summary=result['summary'], prompts=len(prompts))
        settings_done()
        browser_id = app.call('shell-windows')[0]['id']
        app.call('window-focus', id=browser_id, activate=True)
        app.call('sidebar-key', key='z', modifiers=['command'])
        if negative == 'queue':
            # A real uninstall after Undo must invalidate the persistence gate.
            app.call('ext-manage', action='uninstall', extension=identifiers['install'])
            if h.wait_until(pending, timeout=10): app.call('ext-prompt', answer='accept')
            h.wait_until(lambda: identifiers['install'] not in registries()[personal], timeout=10)
        row('EI_undo_keeps_installs', new_id not in {t['id'] for t in app.call('tabs')}
            and identifiers['install'] in registries()[work], newTabUndone=new_id not in {t['id'] for t in app.call('tabs')})
        # Real source receipt: copy ONLY preference JSON. Never touch a source
        # database or print a manifest name, ID, path, URL, or Profile name.
        empty = Path(tmp)/'arc-internal-only'
        shutil.copytree(fixture, empty)
        real_counts = dict(profiles=0, total=0, internal=0, candidates=0)
        arc = Path.home()/'Library/Application Support/Arc/User Data'
        for directory in ('Default', 'Profile 1'):
            prefs = arc/directory/'Secure Preferences'
            if prefs.is_file():
                raw = prefs.read_bytes()
                entries = json.loads(raw).get('extensions', {}).get('settings', {})
                real_counts['profiles'] += 1; real_counts['total'] += len(entries)
                for entry in entries.values():
                    internal = entry.get('path', '').startswith('/Applications/') or not entry.get('path')
                    real_counts['internal' if internal else 'candidates'] += 1
                # This machine has zero candidates. The source preference file
                # goes into this run's private, disposable synthetic Arc root.
                (empty/'User Data'/('Profile 2' if directory == 'Profile 1' else directory)/'Secure Preferences').write_bytes(raw)
            else:
                (empty/'User Data'/('Profile 2' if directory == 'Profile 1' else directory)/'Secure Preferences').write_text('{"extensions":{"settings":{}}}')
        if negative == 'queue':
            prefs = empty/'User Data/Default/Secure Preferences'
            payload = json.loads(prefs.read_text())
            payload['extensions']['settings'][identifiers['existing']] = {
                'path': 'Extensions/example', 'manifest': {'name': 'Example Negative Candidate'}}
            prefs.write_text(json.dumps(payload))
        settings_import(empty)
        result = ext()
        row('EI_no_candidates', real_counts['candidates'] == 0 and not result['visible'] and not result['rows']
            and state()['settingsOutcome'].get('Extensions candidates') == 0, sourceCounts=real_counts, sectionShown=result['visible'])
        settings_done()
        metadata_limits(app, settings_import, state, row, empty, tmp, identifiers['existing'], negative == 'queue')
        if os.environ.get('OPEN_E2E_IMPORT_EXT_NETWORK') == '1' and not negative:
            network_receipt(app, settings_import, ext, empty, tmp, results)
    finally:
        if app:
            try:
                app.call('ext-prompt', clear=True)
                h._restore_defaults(app, saved)
            finally: app.quit()


def metadata_limits(app, settings_import, state, row, base, tmp, identifier, negative=False):
    """At/over each reader limit through the actual Settings import action."""
    source = Path(tmp)/'arc-extension-limits'
    shutil.copytree(base, source, dirs_exist_ok=True)
    profile = source/'User Data/Default'
    prefs = profile/'Secure Preferences'
    payload = profile/'Extensions'
    def preference(name='Example Boundary', key=identifier):
        return json.dumps({'extensions': {'settings': {key: {
            'path': '/Applications/Arc.app/Example', 'manifest': {'name': name}}}}}).encode()
    cases = []
    for kind, maximum in [('preferences', 16*1024*1024), ('records', 4096), ('name', 1024),
                           ('id', 256), ('manifest', 1024*1024), ('versions', 256), ('folders', 4096)]:
        for over in (False, True):
            size = maximum + int(over)
            if negative and kind == 'name' and over: size = maximum  # real boundary fault
            shutil.rmtree(payload, ignore_errors=True)
            prefs.write_bytes(preference())
            if kind == 'preferences':
                data = preference(); prefs.write_bytes(data + b' '*(size-len(data)))
            elif kind == 'records':
                ids = [''.join(chr(97+int(c, 16)) for c in format(n, '032x')) for n in range(size)]
                prefs.write_text(json.dumps({'extensions': {'settings': {key: {
                    'path': '/Applications/Arc.app/Example', 'manifest': {'name': 'Example Boundary'}} for key in ids}}}))
            elif kind == 'name': prefs.write_bytes(preference(name='x'*size))
            elif kind == 'id': prefs.write_bytes(preference(key='a'*size))
            else:
                prefs.write_text('{"extensions":{"settings":{}}}')
                if kind == 'manifest':
                    version = payload/identifier/'1.0'; version.mkdir(parents=True)
                    data = b'{"manifest_version":3,"name":"Example Boundary","version":"1.0"}'
                    (version/'manifest.json').write_bytes(data + b' '*(size-len(data)))
                elif kind == 'versions':
                    for n in range(size): (payload/identifier/str(n)).mkdir(parents=True)
                else:
                    for n in range(size): (payload/str(n)).mkdir(parents=True)
            settings_import(source)
            counts = state()['settingsOutcome']
            cases.append({'case': kind + ('-over' if over else '-at'),
                          'unreadableProfiles': counts.get('Extensions unreadable profiles'),
                          'ok': counts.get('Extensions unreadable profiles') == int(over)})
            app.call('first-run', action='settings-done')
    row('EI_metadata_limits', all(case['ok'] for case in cases), cases=cases)


def network_receipt(app, settings_import, ext, base, tmp, results):
    """INFO only: real production Web Store call, private root, <= 2 minutes."""
    source = Path(tmp)/'arc-extension-network'
    shutil.copytree(base, source)
    identifier = 'p'*32  # Well-formed synthetic ID with no known store listing.
    for directory in ('Default', 'Profile 2'):
        entries = {identifier: {'path': 'Extensions/example', 'manifest': {'name': 'Example Missing Store Item'}}} if directory == 'Default' else {}
        (source/'User Data'/directory/'Secure Preferences').write_text(json.dumps({'extensions': {'settings': entries}}))
    settings_import(source)
    ext(action='fixtures', files={})  # No local mapping: use production installer.
    started = time.monotonic()
    ext(action='install')
    while time.monotonic() - started < 120 and ext()['installing']:
        time.sleep(.25)
    value = ext()
    status = value['rows'][0]['status']
    results['EI_webstore_network'] = dict(status='INFO', load=os.getloadavg(),
        seconds=time.monotonic()-started, completionReceived=not value['installing'],
        rowShowsFailed=status.startswith('Failed: '), completionResult=value['webStoreCompletion'], rowStatus=status, summary=value['summary'],
        reason='Web Store completion observed' if not value['installing'] else 'No store/network answer within 2 minutes; queue remains pending')
