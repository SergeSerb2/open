"""Section 15: real App sinks, stores, consent wall and SIGKILL recovery.

All sources are generated fixtures. Results contain counts and booleans only.
No Keychain access, source override, DB mutation, or system input is used.
"""
import contextlib
import http.server
import json
import os
from pathlib import Path
import runpy
import signal
import ssl
import subprocess
import threading


@contextlib.contextmanager
def fixture_server(h, tmp):
    handler = runpy.run_path(os.path.join(h.ROOT, 'tools/e2e/fixtures/passwords/server.py'))['Handler']
    cert, key = (str(Path(tmp) / ('secrets-fixture.' + suffix)) for suffix in ('crt', 'key'))
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=Open secrets fixture', '-keyout', key, '-out', cert],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    os.chmod(key, 0o600)
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
               '--ignore-certificate-errors', '--no-proxy-server', '--open-e2e']
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5)


def run(factory, results, tmp, h):
    try:
        _run(factory, results, tmp, h)
    except h.FocusInterruption:
        raise
    except Exception as error:
        # The harness prints tracebacks. Do not let an eval failure expose a
        # fixture field literal from a source line or an engine description.
        raise RuntimeError('synthetic secrets suite stopped: ' + type(error).__name__) from None


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
            raise RuntimeError('new Open crash report; stopped before the next flow')
        results[name] = dict(ok=bool(ok), load=os.getloadavg(), **counts)

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
        return all(state[key] == 0 for key in ('consentAdapterCalls', 'keychainProbeCalls', 'keychainReadCalls'))

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
            for key in ('open.links.littleOpenNUXSeen', 'open.general.searchSuggestNoticeDismissed', 'open.import.lastArcDir'):
                saved[key] = app.call('defaults', key=key, persistent=True)
                app.call('defaults', key=key, value=None if key == 'open.import.lastArcDir' else True)
            spaces = setup()
            failed_closed = False
            try:
                app.call('import-secrets-fixture')
            except RuntimeError as error:
                failed_closed = 'OEErrorDomain:8' in str(error)
            counts = all_credentials()
            row('I-negative-mock-key', failed_closed and all(not any(v.values()) for v in counts.values()) and zero_consent(),
                profiles=counts, errorCode=8 if failed_closed else 0)
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
              if (!entry) return false;
              await chrome.passwordsPrivate.changeCredential({id:entry.id, username:entry.username, password:'fixture-open-newer'});
              return !chrome.runtime.lastError;
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

            for identifier, pause in [('I-5', 'after-logins'), ('I-6', 'during-cookies')]:
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
            for allow in (False, True):
                launch(fresh=True, allow=allow)
                app.call('first-run', action='settings-import', directory=str(source))
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
                    keychainCalls=app.call('import-secrets-state')['keychainReadCalls'])
                app.quit()
        finally:
            if app is not None:
                app.quit()
            h._restore_defaults(None, saved)
