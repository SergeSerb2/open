"""Step 0 observations on the unpatched engine, through real App automation.

No feature assertions: `ok` means alive and no new crash report only. Values
stay in the fixture source/browser. No screenshots, arbitrary DOM text, or
credential/cookie/card/address values are retained in the report.
"""
import datetime
import json
import os
import re
import time
from pathlib import Path


class ProbeAbort(RuntimeError):
    """Deliberate early exit to verify real-dialog cleanup, never a crash."""


def timestamp():
    return datetime.datetime.now().astimezone().isoformat(timespec='seconds')


def crash_symbols(h, names):
    """Keep symbol names only, from the faulting thread; never copy a report."""
    symbols = []
    for name in names:
        path = Path(h._CRASH_DIR) / name
        try:
            if path.stat().st_size > 16 * 1024 * 1024:
                continue
            raw = path.read_text(errors='replace')
            if name.endswith('.ips'):
                decoder = json.JSONDecoder()
                _, offset = decoder.raw_decode(raw)
                body, _ = decoder.raw_decode(raw[offset:].lstrip())
                threads = body.get('threads', [])
                fault = body.get('faultingThread', -1)
                for index, thread in enumerate(threads):
                    if thread.get('triggered') or index == fault:
                        symbols.extend(f['symbol'] for f in thread.get('frames', [])[:12] if 'symbol' in f)
            else:
                match = re.search(r'Thread \d+ Crashed[^\n]*:\n(.*?)(?:\n\n|\Z)', raw, re.S)
                if match:
                    for line in match[1].splitlines()[:12]:
                        frame = re.match(r'\d+\s+\S+\s+0x[0-9a-f]+\s+(.+?)(?:\s+\+\s+\d+)?$', line)
                        if frame:
                            symbols.append(frame[1])
        except (OSError, ValueError, TypeError):
            continue
    return symbols[:24]


def run(h, factory, results, tmp):
    app = None
    last_tab = None
    baseline = h._open_crash_reports()
    out = Path(h.OUT) / 'results-passwords-probe.json'
    evidence = {'started': timestamp(), 'featureAssertions': False, 'load': os.getloadavg(), 'rows': results}
    root_readme = Path(os.environ['OPEN_ENGINE_ROOT']) / 'README.txt'
    hashes = re.findall(r'framework SHA-256 ([0-9a-f]{64})', root_readme.read_text())
    if not hashes:
        raise RuntimeError('main engine root README has no distribution hash')
    evidence['recordedDistributionSHA256'] = hashes[-1]
    evidence['distributionHashSource'] = 'OPEN_ENGINE_ROOT/README.txt (last framework SHA-256)'
    readme = Path(h.ROOT) / 'Vendor/cef/README.txt'
    if readme.exists():
        import hashlib
        data = readme.read_bytes()
        evidence['engineReadmeSHA256'] = hashlib.sha256(data).hexdigest()
        # Open's distribution receipt is at the end of README.txt. Retain
        # only hash facts, never absolute paths from the vendor stamp.
        evidence['engineReceiptLines'] = [s.strip() for s in data.decode(errors='replace').splitlines()
                                          if re.search(r'(?i)(sha256|overlay|patch).*\b[0-9a-f]{40,64}\b', s)][:12]
    def persist():
        evidence['updated'] = timestamp()
        out.write_text(json.dumps(evidence, indent=2, sort_keys=True) + '\n')

    def windows():
        return [{k: w[k] for k in ('number', 'class', 'visible', 'parent', 'sheet', 'key') if k in w}
                for w in app.call('windows', timeout=5)]

    def visible_delta(before):
        old = {w['number'] for w in before if w['visible']}
        return [w for w in windows() if w['visible'] and w['number'] not in old]

    def load(url):
        nonlocal last_tab
        last_tab = h.new_tab(app, url)
        ready = h.wait_until(lambda: app.eval(last_tab, 'document.readyState') == 'complete', timeout=15, step=.2)
        if not ready:
            raise RuntimeError('fixture document did not become ready')
        return last_tab

    def fill(tab):
        app.call('focus', tab=tab)
        fields = app.eval(tab, 'Array.from(document.querySelectorAll("input[data-fixture]")).map(e => e.id)')
        for field in fields:
            app.call('click', tab=tab, selector='#' + field)
            value = app.eval(tab, 'document.getElementById(%s).dataset.fixture' % json.dumps(field))
            app.call('key', text=value, route='app')
        return app.eval(tab, 'Array.from(document.querySelectorAll("input[data-fixture]")).every(e => e.value === e.dataset.fixture)')

    def submitted(tab):
        app.call('click', tab=tab, selector='#submit')
        return bool(h.wait_until(lambda: app.eval(tab, 'location.pathname === "/welcome"'), timeout=5, step=.2))

    def record(rowid, action):
        row = {'started': timestamp(), 'status': 'OBSERVED'}
        results[rowid] = row
        persist()  # An interrupted/dead row always has a durable start record.
        try:
            action(row)
        except ProbeAbort:
            row['status'] = 'FORCED_FAILURE'
            raise
        except h.FocusInterruption:
            row['status'] = 'INTERRUPTED'
            raise
        except Exception as error:
            row['status'] = 'UNVERIFIED'
            row['errorType'] = type(error).__name__
        finally:
            time.sleep(.3)  # Allow the OS crash reporter to publish its receipt.
            alive = bool(app and app.pid and app.process_path(app.pid) == os.path.realpath(app.executable))
            try:
                responsive = bool(alive and app.call('ping', timeout=3))
                row['windowsAfter'] = windows() if responsive else []
            except Exception:
                responsive = False
            new = sorted(h._open_crash_reports() - baseline)
            row.update(appAlive=alive, automationResponsive=responsive, newCrashReports=new,
                       crashTopSymbols=crash_symbols(h, new), finished=timestamp(), ok=alive and responsive and not new)
            persist()
        print('%s safety=%s status=%s' % (rowid, 'PASS' if row['ok'] else 'FAIL', row['status']), flush=True)
        if not row['ok']:
            # Never relaunch after a crash: a system crash dialog may own focus.
            evidence['stopped'] = 'Process death, unresponsive automation, or new crash report; no retry.'
            persist()
            return False
        app.call('key', key='escape', route='app')
        app.call('dismiss')
        return True

    with h.passwords_fixture_server() as urls:
        app = factory(urls=(), fresh=True, extra_args=urls['engine_switches'])
        evidence['fixturePort'] = urls['port']
        evidence['engineSwitches'] = urls['engine_switches']
        try:
            def login(row):
                tab = load(urls['login'])
                before = windows()
                row['typedFieldsMatch'] = fill(tab)
                row['submitted'] = submitted(tab)
                time.sleep(.5)
                row['newVisibleWindows'] = visible_delta(before)
            def saved_login(row):
                nonlocal last_tab
                # Use the same backend API as Chromium's Add Password WebUI,
                # if today's distribution exposes it. No DB/keychain writes.
                fixtures = h.runpy.run_path(os.path.join(h.ROOT, 'tools/e2e/fixtures/passwords/server.py'))
                tab = load('chrome://password-manager/passwords')
                row['webuiLoaded'] = app.eval(tab, 'location.protocol === "chrome:" && !!document.querySelector("password-manager-app")')
                script = '''(async () => {
                  if (!chrome.passwordsPrivate?.addPassword) return {status:'api-unavailable'};
                  return await Promise.race([
                    new Promise(resolve => chrome.passwordsPrivate.addPassword(%s, () => resolve({status:chrome.runtime.lastError ? 'backend-error' : 'added'}))),
                    new Promise(resolve => setTimeout(() => resolve({status:'timeout'}), 2000))]);
                })()''' % json.dumps({'url': urls['login'], 'username': fixtures['USERNAME'], 'password': fixtures['PASSWORD'], 'note': '', 'useAccountStore': False})
                try:
                    row['seed'] = app.eval(tab, script)
                except RuntimeError:
                    row['seed'] = {'status': 'api-refused'}
                row['seedMethod'] = 'chrome.passwordsPrivate.addPassword (WebUI API)'
                tab = load(urls['login'])
                row['emptyOnLoad'] = app.eval(tab, '!document.querySelector("#username").value && !document.querySelector("#password").value')
                before = windows()
                app.call('focus', tab=tab)
                app.call('click', tab=tab, selector='#username')
                time.sleep(.5)
                row['newVisibleWindows'] = visible_delta(before)
                app.call('key', key='down', route='app')
                app.call('key', key='return', route='app')
                row['filledFieldsMatch'] = app.eval(tab, 'Array.from(document.querySelectorAll("input[data-fixture]")).every(e => e.value === e.dataset.fixture)')
                if row['seed'].get('status') != 'added':
                    row['limitation'] = 'No saved-login prerequisite established; dropdown/refill outcome is inconclusive.'
            def address(row):
                tab = load(urls['address'])
                before = windows()
                row['typedFieldsMatch'] = fill(tab)
                row['submitted'] = submitted(tab)
                row['newVisibleWindows'] = visible_delta(before)
            def card(row):
                tab = load(urls['card'])
                before = windows()
                row['typedFieldsMatch'] = fill(tab)
                row['submitted'] = submitted(tab)
                row['newVisibleWindowsAfterSubmit'] = visible_delta(before)
                tab = load(urls['card'])
                before = windows()
                app.call('focus', tab=tab)
                app.call('click', tab=tab, selector='#number')
                time.sleep(.5)
                row['newVisibleWindowsForRefill'] = visible_delta(before)
                app.call('key', key='down', route='app')
                app.call('key', key='return', route='app')
                row['refilled'] = app.eval(tab, '!!document.querySelector("#number")?.value')
                row['limitation'] = 'Card re-auth path is exercised only if a saved card is offered and selected.'
            def webauthn(row):
                tab = load(urls['webauthn'])
                row['secureContext'] = app.eval(tab, 'isSecureContext')
                before = windows()
                app.call('click', tab=tab, selector='#create')
                time.sleep(.5)
                row['newVisibleWindows'] = visible_delta(before)
                row['promiseAt500ms'] = app.eval(tab, 'document.querySelector("#result").textContent')
                if os.environ.get('OPEN_E2E_PASSWORDS_PROBE_ABORT_DIALOG') == '1':
                    raise ProbeAbort('Deliberate exit with WebAuthn dialog open (cleanup verification)')
                target = row['newVisibleWindows'][0]['number'] if row['newVisibleWindows'] else None
                app.call('key', key='escape', route='app', **({'window': target} if target else {}))
                row['promiseAfterEscapeOrTimeout'] = app.eval(tab, 'new Promise(resolve => {const end=Date.now()+6000; const tick=()=>{const s=document.querySelector("#result").textContent; if(s!=="pending" || Date.now()>=end) resolve(s); else setTimeout(tick,50)};tick()})')
            def credential_get(row):
                tab = load(urls['local_login'])
                row['secureContext'] = app.eval(tab, 'isSecureContext')
                row['savedLoginForThisOrigin'] = False
                before = windows()
                row['promise'] = app.eval(tab, '''Promise.race([
                    navigator.credentials.get({password:true}).then(x=>x===null?'null':'credential',e=>e.name),
                    new Promise(resolve=>setTimeout(()=>resolve('timeout'),2000))])''')
                row['newVisibleWindows'] = visible_delta(before)
                row['limitation'] = 'Secure localhost origin has no seeded saved login; account chooser not established.'
            def basic(row):
                # Do not wait for navigation completion while auth is pending.
                before = windows()
                tab = app.call('open', url=urls['basic'])['id']
                time.sleep(1)
                row['newVisibleWindows'] = visible_delta(before)
                target = row['newVisibleWindows'][0]['number'] if row['newVisibleWindows'] else None
                app.call('key', key='escape', route='app', **({'window': target} if target else {}))
                row['requested'] = True
            def cookies(row):
                nonlocal app
                load(urls['set_cookies'])
                tab = load(urls['echo_cookies'])
                row['beforeQuit'] = app.eval(tab, 'JSON.parse(document.body.innerText)')
                app.quit()
                row['quitClean'] = app.quit_report.get('ok', False) and not app.quit_report.get('forced', True)
                new = sorted(h._open_crash_reports() - baseline)
                if new:
                    raise RuntimeError('new crash report during quit; relaunch refused')
                app = factory(urls=(), extra_args=urls['engine_switches'])
                tab = load(urls['echo_cookies'])
                row['afterRelaunch'] = app.eval(tab, 'JSON.parse(document.body.innerText)')
            def pages(row):
                def page_rows():
                    return [{k:p[k] for k in ('identifier','kind','style','browser','browserIndex','hidden') if k in p}
                            for p in app.call('pages')]
                tab = load(urls['login'])
                row['normal'] = page_rows()
                other = load(urls['signup'])
                app.call('select', tab=tab)
                app.call('split')
                row['split'] = page_rows()
                app.call('split')
                app.call('peek-open', tab=tab, url=urls['change'])
                time.sleep(.5)
                row['peek'] = page_rows()
                app.call('peek-close')
                try:
                    state = app.call('little-open-action', action='blank', timeout=10)
                    session = state['sessions'][-1]
                    app.call('little-open-action', id=session['id'], action='dismiss-intro')
                    h.wait_until(lambda: any(s.get('browserID') for s in app.call('little-open-state')['sessions']), timeout=8, step=.2)
                    app.call('key', window=session['window'], text=urls['local_login'] + '\r')
                    loaded = h.wait_until(lambda: any(s['state'] == 'page' and not s['loading']
                                                    for s in app.call('little-open-state')['sessions']), timeout=12, step=.2)
                    row['littleOpenLoaded'] = bool(loaded)
                    row['littleOpen'] = page_rows()
                    state = app.call('little-open-state')
                    row['littleOpenSessions'] = [{k:s.get(k) for k in ('state','content','browserID')} for s in state['sessions']]
                finally:
                    for session in app.call('little-open-state')['sessions']:
                        app.call('little-open-action', id=session['id'], action='close')
            actions = [('PR-1', login), ('PR-2', saved_login), ('PR-3', address), ('PR-4', card),
                       ('PR-5', webauthn), ('PR-6', credential_get), ('PR-7', basic), ('PR-8', cookies), ('PR-9', pages)]
            for rowid, action in actions:
                if not record(rowid, action):
                    break
        finally:
            app.quit()
            time.sleep(1)
            evidence['cleanup'] = app.quit_report.get('ok', False)
            evidence['newCrashReportsAfterQuit'] = sorted(h._open_crash_reports() - baseline)
            results['postQuitSafety'] = {'ok': not evidence['newCrashReportsAfterQuit'],
                                        'newCrashReports': evidence['newCrashReportsAfterQuit']}
            for index in range(1, 10):
                results.setdefault('PR-%d' % index, {'status': 'NOT_RUN', 'reason': evidence.get('stopped', 'Probe interrupted before row')})
            evidence['finished'] = timestamp()
            persist()
    return {k: v for k, v in evidence.items() if k != 'rows'}
