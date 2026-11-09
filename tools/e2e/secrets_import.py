"""Section 15: real App sinks, stores, consent wall and SIGKILL recovery.

All sources are generated fixtures. Results contain counts and booleans only.
No Keychain access, source override, DB mutation, or system input is used.
"""
import contextlib
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import runpy
import signal
import ssl
import subprocess
import threading
import time


@contextlib.contextmanager
def fixture_server(h, tmp):
    handler = runpy.run_path(os.path.join(h.ROOT, 'tools/e2e/fixtures/passwords/server.py'))['Handler']
    cert, key = (str(Path(tmp) / ('secrets-fixture.' + suffix)) for suffix in ('crt', 'key'))
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=Open secrets fixture', '-keyout', key, '-out', cert],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    os.chmod(key, 0o600)
    # Match passwords_fixture_server: a broad certificate-error bypass can
    # leave a certificate error that Chromium's password manager refuses.
    # Trust only this run's generated public key for the HTTPS fixture.
    public_key = subprocess.check_output(['openssl', 'x509', '-in', cert, '-pubkey', '-noout'], timeout=10)
    spki = subprocess.check_output(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=public_key, timeout=10)
    pin = base64.b64encode(hashlib.sha256(spki).digest()).decode('ascii')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    server.daemon_threads = True
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        # Keep the source credential's exact HTTPS origin (port 443). Only
        # this App's resolver maps it to a private, unprivileged loopback port.
        yield ['--host-resolver-rules=MAP *.example.com 127.0.0.1:%d' % server.server_port,
               '--ignore-certificate-errors-spki-list=' + pin, '--no-proxy-server', '--open-e2e']
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5)


def run(factory, results, tmp, h):
    try:
        _run(factory, results, tmp, h)
    except (h.FocusInterruption, h.AppDied):
        raise
    except Exception as error:
        # The harness prints tracebacks. Do not let an eval failure expose a
        # fixture field literal from a source line or an engine description.
        safe_assertions = {
            'fixture Profile Space missing', 'fixture navigation timeout', 'fixture origin mismatch',
            'autofill dropdown missing', 'autofill dropdown did not close',
            'autofill dropdown did not appear after a field click',
            'password manager unavailable', 'fixture checkpoint not reached',
            'Change Profile warning missing', 'Profile reassignment did not finish',
            'Profile deletion sheet missing',
            'fixture import wizard not ready',
            'fixture import wizard counts differ',
            'fixture import wizard Next did not advance',
            'fixture import wizard sheet missing',
        }
        safe_runtime_errors = {
            'first-run: Passwords copy reference requires capability OFF': 'wizard copy reference not ready',
            'first-run: wizard is busy': 'wizard still busy',
        }
        detail = ': ' + str(error) if isinstance(error, AssertionError) and str(error) in safe_assertions else ''
        if isinstance(error, RuntimeError) and str(error) in safe_runtime_errors:
            detail = ': ' + safe_runtime_errors[str(error)]
        raise RuntimeError('synthetic secrets suite stopped: ' + type(error).__name__ + detail) from None


def _run(factory, results, tmp, h):
    # Use F's real popup helpers. run_path works with the harness's -I mode.
    dropdown = runpy.run_path(os.path.join(h.ROOT, 'tools/e2e/passwords.py'))
    show_autofill_dropdown = dropdown['show_autofill_dropdown']
    fill_from_dropdown = dropdown['fill_from_dropdown']
    app = None
    crashes_before = h._open_crash_reports()
    expected = dict(logins=3, blockedSites=1, addresses=1, cards=1, cookies=4)
    saved = {}
    source = Path(tmp) / 'wizard-arc-synthetic'
    runpy.run_path(os.path.join(h.ROOT, 'tools/e2e/firstrun.py'))['fixture'](source)

    def row(name, ok, **counts):
        if h._open_crash_reports() - crashes_before:
            raise h.AppDied('new Open crash report; stopped before the next flow')
        results[name] = dict(ok=bool(ok), load=os.getloadavg(), **counts)
        if not ok:
            raise RuntimeError('synthetic secrets acceptance row failed: ' + name)

    def credentials(profile):
        value = app.call('credentials', profile=profile)
        return {key: value[key] for key in expected}

    def all_credentials():
        return {profile: credentials(profile) for profile in ('Default', 'Work')}

    def counts_equal(values, cookie_count=4):
        return all(value == dict(expected, cookies=cookie_count) for value in values.values())

    def report_correct(state, added, existing):
        report = state['report']
        if set(report.get('profiles', {})) != {'Default', 'Profile 1'}:
            return False
        for value in report['profiles'].values():
            for kind, count in [('logins', 4), ('addresses', 1), ('cards', 1), ('cookies', 4)]:
                if any(value[kind][key] != factor * count for key, factor in [('added', added), ('existing', existing)]):
                    return False
                if value[kind]['failed'] != 0:
                    return False
            if value['logins']['skippedFederated'] != 1 or value['cookies']['skippedExpired'] != 1:
                return False
        return True

    def profile_space(profile):
        profiles = app.call('spaces')
        target = spaces[profile]
        assert any(value['id'] == target for value in profiles), 'fixture Profile Space missing'
        app.call('space', space=target)

    def load(profile, path):
        profile_space(profile)
        tab = h.new_tab(app, 'https://login.example.com/' + path)
        assert h.wait_until(lambda: not app.tab(tab)['loading'], timeout=20, step=.1), 'fixture navigation timeout'
        assert app.eval(tab, 'location.hostname === "login.example.com"'), 'fixture origin mismatch'
        return tab

    def fill(profile):
        tab = load(profile, 'login.html')
        empty = app.eval(tab, '!document.querySelector("#username").value && !document.querySelector("#password").value')
        index = 0 if profile == 'Default' else 1
        popup = show_autofill_dropdown(app, tab, h.wait_until)
        assert popup, 'autofill dropdown missing'
        popup_ids = {value['number'] for value in popup}
        labels = [label for window in app.call('windows', accessibility=True)
                  if window['number'] in popup_ids for label in window.get('text', [])]
        own = sum(any('fixture-%d-%d' % (index, n) in label for label in labels) for n in (1, 2))
        foreign = sum('fixture-%d-' % (1 - index) in label for label in labels)
        app.call('key', key='escape', route='app')
        assert h.wait_until(lambda: not popup_ids.intersection(
            w['number'] for w in dropdown['autofill_child_windows'](app)), timeout=5), 'autofill dropdown did not close'
        fill_from_dropdown(app, tab, h.wait_until)
        matched = h.wait_until(lambda: app.eval(tab, '''(() => {
          const u = document.querySelector('#username').value, p = document.querySelector('#password').value;
          return %s.includes(u) && p === 'fixture-password';
        })()''' % json.dumps(['fixture-%d-%d' % (index, n) for n in (1, 2)])), timeout=5, step=.1)
        return bool(empty and matched and own == 2 and foreign == 0), tab

    def ledger():
        return json.loads((Path(app.user_data) / 'State/secrets-import.json').read_text())

    def zero_consent():
        state = app.call('import-secrets-state')
        return not state['canImportPasswordsAndCookies'] and all(
            state[key] == 0 for key in ('consentAdapterCalls', 'keychainProbeCalls', 'keychainReadCalls'))

    with fixture_server(h, tmp) as switches:
        def launch(fresh=False, allow=True):
            nonlocal app
            args = switches + (['--open-allow-mock-keychain-secrets'] if allow else [])
            app = factory(urls=(), fresh=fresh, extra_args=args)
            return app

        def setup():
            # The Work context has no page before import: this checks lazy creation.
            default = app.call('spaces')[0]['id']
            work = app.call('space-create', profile='Work', title='Work')
            app.call('save')
            return dict(Default=default, Work=work)

        try:
            launch(fresh=True, allow=False)
            for key in ('open.links.littleOpenNUXSeen', 'open.general.searchSuggestNoticeDismissed',
                        'open.import.lastArcDir', 'open.settings.lastPane',
                        'open.profiles.confirmInterProfileMove'):
                saved[key] = app.call('defaults', key=key, persistent=True)
                app.call('defaults', key=key, value=None if key in ('open.import.lastArcDir', 'open.settings.lastPane') else True)
            spaces = setup()
            failed_closed = False
            try:
                app.call('import-secrets-fixture')
            except RuntimeError as error:
                failed_closed = 'OEErrorDomain:10' in str(error)
            counts = all_credentials()
            row('I-negative-mock-key', failed_closed and all(not any(v.values()) for v in counts.values()) and zero_consent(),
                profiles=counts, errorCode=10 if failed_closed else 0)
            app.quit()

            launch(fresh=True)
            spaces = setup()
            imported = app.call('import-secrets-fixture')
            counts = all_credentials()
            row('I-1', report_correct(imported, 1, 0) and counts_equal(counts) and zero_consent(), profiles=counts,
                report=imported['report'])
            matches = [fill(profile)[0] for profile in ('Default', 'Work')]
            row('I-2', all(matches) and counts_equal(all_credentials()), profilesChecked=len(matches), fillsMatched=sum(matches))
            repeated = app.call('import-secrets-fixture')
            row('I-3', report_correct(repeated, 0, 1) and all_credentials() == counts,
                report=repeated['report'])

            # Change a saved fixture password through Chromium's actual WebUI
            # service. It updates the same store used by a saved update prompt.
            profile_space('Default')
            manager = h.new_tab(app, 'chrome://password-manager/passwords')
            assert h.wait_until(lambda: app.eval(manager, '!!chrome.passwordsPrivate?.getSavedPasswordList'), timeout=10), 'password manager unavailable'
            updated = app.eval(manager, '''(async () => {
              const entries = await chrome.passwordsPrivate.getSavedPasswordList();
              const entry = entries.find(e => e.username === 'fixture-0-1');
              if (!entry || entry.isPasskey) return false;
              // Preserve the schema's required fields. Do not send optional
              // passkey displayName when updating a password credential.
              await chrome.passwordsPrivate.changeCredential({
                affiliatedDomains:entry.affiliatedDomains, id:entry.id,
                username:entry.username, storedIn:entry.storedIn,
                isPasskey:entry.isPasskey, hidden:entry.hidden,
                isAutomaticPasswordChangeSupported:entry.isAutomaticPasswordChangeSupported,
                password:'fixture-open-newer'});
              return true;
            })()''')
            existing = app.call('import-secrets-fixture')
            # Select that specific account by typing its fixture username first.
            tab = load('Default', 'login.html')
            app.call('click', tab=tab, selector='#username')
            app.call('key', text='fixture-0-1', route='app')
            app.call('key', key='escape', route='app')
            assert h.wait_until(lambda: not dropdown['autofill_child_windows'](app), timeout=5), 'autofill dropdown did not close'
            fill_from_dropdown(app, tab, h.wait_until)
            newer = h.wait_until(lambda: app.eval(tab, 'document.querySelector("#username").value === "fixture-0-1" && document.querySelector("#password").value === "fixture-open-newer"'), timeout=5, step=.1)
            row('I-4', updated and newer and report_correct(existing, 0, 1), updated=int(bool(updated)), newerFilled=int(bool(newer)))

            # Relaunch before checking the HTTP Cookie header. The session and
            # two persistent unpartitioned cookies must arrive. The partitioned
            # cookie is stored but does not match this top-level request.
            app.call('save'); app.quit(); launch()
            echo = []
            for index, profile in enumerate(('Default', 'Work')):
                tab = load(profile, 'echo-cookies')
                names = app.eval(tab, 'JSON.parse(document.body.textContent)')
                allowed = {'fixture-%d-%d' % (index, n) for n in range(1, 5)}
                required = {'fixture-%d-%d' % (index, n) for n in (1, 2, 3)}
                echo.append(dict(received=len(names), foreign=len(set(names) - allowed),
                                 requiredUnpartitioned=len(required & set(names))))
            row('I-7', all(value['foreign'] == 0 and value['received'] == 3
                          and value['requiredUnpartitioned'] == 3 for value in echo), profiles=echo)
            app.quit()

            # Delete through the real Settings confirmation and ProfileTeardown.
            # Reassign the fixture Space first: Profiles with Spaces cannot be deleted.
            for variant in ('completed', 'in-progress'):
                launch(fresh=True); spaces = setup()
                args = {} if variant == 'completed' else dict(pause='after-logins', pauseProfile='Profile 1')
                app.call('import-secrets-fixture', **args)
                if args:
                    assert h.wait_until(lambda: app.call('import-secrets-state')['stage'] == 'paused-after-logins',
                                        timeout=30, step=.1), 'fixture checkpoint not reached'
                default_before = credentials('Default')
                work_before = credentials('Work')
                before_ledger = (Path(app.user_data) / 'State/secrets-import.json').read_bytes()
                work = next(p for p in app.call('profiles-shell')['profiles'] if p['name'] == 'Work')
                folders = [Path(app.user_data) / kind / work['directory'] for kind in ('Profiles', 'Engine')]
                # Follow ProfileDirectories: Application Support roots put
                # Chromium caches under Library/Caches with the same suffix.
                support = Path.home() / 'Library/Application Support'
                try:
                    suffix = folders[1].relative_to(support)
                except ValueError:
                    pass  # Other disposable roots keep caches in Engine.
                else:
                    folders.append(Path.home() / 'Library/Caches' / suffix)
                had_folders = all(p.is_dir() for p in folders[:2])
                app.call('space-profile', space=spaces['Work'], profile='Default')
                warning = app.call('alert')
                assert 'Change Profile?' in warning['texts'] and 'Change Profile' in warning['buttons'], 'Change Profile warning missing'
                app.call('alert', button='Change Profile')
                assert h.wait_until(lambda: any(p['id'] == work['id'] and p['spaces'] == 0
                    for p in app.call('profiles-shell')['profiles']), timeout=5), 'Profile reassignment did not finish'
                profile_space('Default')
                app.call('profiles-shell', action='show', profile='Work')
                h.time.sleep(.15)  # Same Settings render settlement as profiles_shell.show.
                app.call('profiles-shell', action='press', label='Delete Profile')
                assert h.wait_until(lambda: app.call('profiles-shell')['sheet'] > 0, timeout=5), 'Profile deletion sheet missing'
                app.call('profiles-shell', action='type-delete', text='Work')
                app.call('profiles-shell', action='press', label='Delete')
                def deletion_done():
                    state = app.call('profiles-shell')
                    return not state['deleting'] and state['sheet'] == 0 and all(p['id'] != work['id'] for p in state['profiles'])
                deleted = h.wait_until(deletion_done, timeout=30, step=.1)
                stopped = h.wait_until(lambda: not app.call('import-secrets-state')['activeBatch'], timeout=5)
                state = app.call('import-secrets-state')
                inactive = work['directory'] not in app.call('engine-contexts')
                gone_before_quit = all(not p.exists() for p in folders)
                # A queued request for a retired destination must fail before
                # it can obtain a context or replace the counts ledger.
                refused = False
                try:
                    app.call('import-secrets-fixture', map={'Profile 1': work['id']})
                except RuntimeError:
                    refused = True
                unchanged = (Path(app.user_data) / 'State/secrets-import.json').read_bytes() == before_ledger
                app.call('save'); app.quit(); launch()
                gone_after_relaunch = all(not p.exists() for p in folders)
                unchanged = unchanged and (Path(app.user_data) / 'State/secrets-import.json').read_bytes() == before_ledger
                row('I-9-' + variant, deleted and stopped and had_folders and work_before['logins'] > 0
                    and default_before == expected and credentials('Default') == default_before
                    and gone_before_quit and gone_after_relaunch and inactive and refused and unchanged
                    and state['retiredProfiles'] == 1 and state['cachedSinks'] == 1 and zero_consent(),
                    defaultCounts=credentials('Default'), importedBeforeDelete=work_before['logins'],
                    foldersAbsent=gone_after_relaunch, ledgerUnchanged=unchanged, retiredRequestRefused=refused)
                app.quit()

            for identifier, pause in [('I-5', 'after-logins'), ('I-6', 'during-cookies')]:
                if os.environ.get('OPEN_E2E_NO_CRASH_PROBES') == '1':
                    results[identifier] = {'status': 'DEFERRED', 'reason': 'M1-only by rule; not run'}
                    continue
                launch(fresh=True); spaces = setup()
                app.call('import-secrets-fixture', pause=pause)
                assert h.wait_until(lambda: app.call('import-secrets-state')['stage'] == 'paused-' + pause, timeout=30, step=.1), 'fixture checkpoint not reached'
                before = ledger()
                pending = before.get('finished') is None and before['profiles']['Default']['logins']['state'] == 'done'
                if pause == 'during-cookies':
                    pending = pending and before['profiles']['Default']['cookies']['state'] == 'pending'
                    partial = app.call('credentials', profile='Default')['cookies']
                    pending = pending and 0 < partial < 4
                # Capture ownership before intentional SIGKILL; the normal
                # harness teardown still removes only our verified child PIDs.
                app.discover_owned_processes()
                os.kill(app.pid, signal.SIGKILL)
                app.quit(); launch()
                state = app.call('import-secrets-state')
                app.call('first-run', action='settings-import', directory=str(source))
                shown = app.call('first-run', action='settings-inspect')
                unfinished_copy = 'The last import stopped before it finished.' in shown.get('secretsUnfinishedMessage', '')
                recovered = app.call('import-secrets-fixture')
                counts = all_credentials()
                final = ledger()
                row(identifier, pending and state['unfinishedAtLaunch'] and unfinished_copy and counts_equal(counts)
                    and final['runID'] != before['runID'] and final.get('finished') is not None
                    and recovered['report']['previousRunUnfinished'] and zero_consent(), profiles=counts,
                    unfinishedAtLaunch=int(state['unfinishedAtLaunch']), unfinishedCopy=int(unfinished_copy))
                app.quit()

            # On mock-key builds the real consent button is absent. Even a
            # direct adapter action cannot mint a token or reach the Keychain.
            wizard_counts = {
                'Spaces': 2, 'Pinned and Today tabs': 6, 'Favorites': 1, 'Folders': 1,
                'Skipped easels': 1, 'Skipped notes': 0, 'Skipped unknown': 0,
                'Welcome items': 1, 'Profiles': 1, 'Search settings': 1,
                'Routing rules': 1, 'Boosts': 0, 'Archive': 2, 'History': 3,
                'Passwords and cookies': 3,
            }
            for allow in (False, True):
                launch(fresh=True, allow=allow)
                # One fixed bound includes choose() itself and every state
                # request; the receipt measures start-of-choose through idle.
                ready_started = time.monotonic()
                ready_deadline = ready_started + 10
                chosen = app.call('first-run', action='settings-import', directory=str(source), timeout=10)
                choose_returned = time.monotonic()
                # Presenting the sheet also starts its SwiftUI count task.
                # It can supersede choose()'s request, so that await can return
                # while the newer count is still active. Follow the real Next
                # button's readable/idle gate before entering the copy reference.
                def wizard_ready():
                    remaining = ready_deadline - time.monotonic()
                    if remaining <= 0:
                        return None
                    state = app.call('first-run', action='settings-inspect', timeout=remaining)
                    return state if state['settingsReadable'] and not state['settingsBusy'] else None
                remaining = ready_deadline - time.monotonic()
                assert remaining > 0, 'fixture import wizard not ready'
                ready = h.wait_until(wizard_ready, timeout=remaining, step=.05)
                idle_observed = time.monotonic()
                ready_elapsed = idle_observed - ready_started
                assert ready and ready_elapsed <= 10, 'fixture import wizard not ready'
                assert ready['settingsCounts'] == wizard_counts, 'fixture import wizard counts differ'
                # Prove a user can continue once counting settles, through the
                # real App key path and SwiftUI's default Next button.
                # sendKey defaults to the browser window. Identify the actual
                # Import sheet after its SwiftUI layout before sending Return.
                sheets = app.call('windows', accessibility=True)
                sheet = next((w for w in sheets if w.get('visible') and w.get('sheet')
                              and 'Import from Arc' in w.get('text', [])), None)
                assert sheet, 'fixture import wizard sheet missing'
                app.call('key', key='return', route='app', window=sheet['number'])
                advanced = bool(h.wait_until(lambda: app.call('first-run', action='settings-inspect')['settingsStep'] == 'Review',
                                            timeout=5, step=.05))
                assert advanced, 'fixture import wizard Next did not advance'
                row('I-8-readiness-' + ('allow-switch' if allow else 'no-switch'),
                    ready['settingsCanContinue'] and advanced,
                    busyAfterChoose=chosen['settingsBusy'], readableAfterChoose=chosen['settingsReadable'],
                    readinessUpperBoundSeconds=10, chooseToIdleSeconds=round(ready_elapsed, 3),
                    chooseCallSeconds=round(choose_returned - ready_started, 3),
                    waitAfterChooseSeconds=round(idle_observed - choose_returned, 3),
                    counts=ready['settingsCounts'], nextThroughAppKey=True)
                app.call('first-run', action='settings-passwords')
                app.call('first-run', action='settings-inspect')
                app.call('first-run', action='settings-allow-passwords')
                state = app.call('first-run', action='settings-inspect')
                text = state.get('secretsTitle', '')
                body = state.get('secretsBody', '')
                app.call('first-run', action='settings-skip-passwords')
                skipped_without_consent = zero_consent()
                app.call('first-run', action='settings-passwords')
                app.call('first-run', action='settings-cancel-passwords')
                row('I-8-' + ('allow-switch' if allow else 'no-switch'),
                    not state['secretsEnabled'] and "can't be imported yet" in text
                    and 'Passkeys saved only in Arc' not in body
                    and 'Import Passwords and Cookies' not in state['secretsButtons']
                    and not state['secretsAllowVisible'] and not state['secretsAllowEnabled']
                    and not state['secretsConsented'] and skipped_without_consent and zero_consent(),
                    consentCalls=app.call('import-secrets-state')['consentAdapterCalls'],
                    keychainProbeCalls=app.call('import-secrets-state')['keychainProbeCalls'],
                    keychainCalls=app.call('import-secrets-state')['keychainReadCalls'],
                    busyAfterChoose=chosen['settingsBusy'], readableAfterChoose=chosen['settingsReadable'],
                    readyBeforeReference=True)
                app.quit()
        finally:
            if app is not None:
                app.quit()
            h._restore_defaults(None, saved)
