"""No suite may raise a macOS permission prompt (LEAD 12:24, 2026-11-12).

A prompt such as "Allow 'Open' to access your microphone?" (UserNotificationCenter) blocks every
on-screen suite on that Mac until a person answers it. Automation launches pass
--use-fake-device-for-media-stream, so a page that asks for the camera and microphone gets fake
devices and Chromium never asks macOS. Rows: the page gets live fake tracks; macOS camera and
microphone status is unchanged (never requested); no system dialog is on screen afterwards.

Local Network (2026-11-23): Chromium's built-in DNS client sends UDP DNS to the configured server
(usually the LAN router), and macOS then asks "Allow "Open" to find devices on local networks?" for
every new test binary. Automation builds pass --disable-features=AsyncDns (App/main.swift). Rows: the
network service helper runs with AsyncDns in --disable-features, merged with a launcher's own list;
an offline lookup (.invalid, RFC 6761) in a net log uses the system resolver only: the insecure
client is off, no built-in DNS transaction, no UDP to port 53.
"""
import json
from pathlib import Path
import subprocess
import time


def system_dialogs(h):
    root = Path(h.ROOT)
    import hashlib
    source = root / 'tools/verification/system-windows.swift'
    helper = root / 'build/verification' / ('system-windows-' + hashlib.sha256(source.read_bytes()).hexdigest()[:16])
    if not helper.is_file():
        helper.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['xcrun', 'swiftc', '-O', str(source), '-o', str(helper)], check=True, stdout=subprocess.DEVNULL)
    return json.loads(subprocess.check_output([str(helper)], text=True, timeout=10))


def run(factory, results, tmp, h):
    def row(name, ok, **detail):
        results[name] = dict(ok=bool(ok), **detail)
    before_dialogs = system_dialogs(h)
    server, origin = h._fixture_server('Media')
    app = factory(urls=(), fresh=True)
    try:
        app.call('policy', permissions='grant')
        before = app.call('capture-permission')
        tab = app.call('open', url=origin + '/capture')['id']
        app.call('wait', tab=tab)
        js = """navigator.mediaDevices.getUserMedia({audio: true, video: true}).then(s => {
                  window.__capture = s.getTracks().map(t => [t.kind, t.readyState, t.label]); return 'ok' },
                  e => { window.__capture = String(e); return 'error' })"""
        app.eval(tab, 'window.__started = (' + js + '), true')
        outcome = h.wait_until(lambda: app.eval(tab, 'window.__capture || null'), timeout=10, step=.1)
        tracks = outcome if isinstance(outcome, list) else []
        row('fake_devices_for_page', sorted(t[0] for t in tracks) == ['audio', 'video'] and all(t[1] == 'live' for t in tracks),
            capture=outcome)
        time.sleep(2)
        after = app.call('capture-permission')
        row('macos_permission_not_requested', after == before, before=before, after=after)
        dialogs = system_dialogs(h)
        row('no_system_dialog', not dialogs and not before_dialogs, before=before_dialogs, after=dialogs)
    finally:
        try: app.call('policy', permissions='')
        except Exception: pass
        server.shutdown()
        # The next launch is fresh=True and deletes the data root: this App must be gone first.
        app.quit()
    local_network_rows(factory, results, tmp, h, row)


def local_network_rows(factory, results, tmp, h, row):
    import re
    netlog = Path(tmp) / 'local-network-netlog.json'
    # A launcher's own feature list must survive next to the shell's AsyncDns (they merge).
    app = factory(urls=(), fresh=True, extra_args=['--log-net-log=' + str(netlog), '--net-log-capture-mode=Everything',
                                                   '--disable-features=OpenLocalNetworkProbe'])
    try:
        tab = app.call('open', url='http://ux-local-network-probe.invalid/')['id']
        try: app.call('wait', tab=tab, timeout=15)
        except Exception: pass
        ps = subprocess.run(['ps', '-axo', 'pid,ppid,command'], capture_output=True, text=True).stdout.splitlines()
        helpers = [l for l in ps if l.split(None, 2)[1:2] == [str(app.pid)] and 'Open Helper' in l]
        network = [l for l in helpers if '--utility-sub-type=network.mojom.NetworkService' in l]
        def disabled(line):
            found = re.findall(r'--disable-features=(\S+)', line)
            return set(found[-1].split(',')) if found else set()
        lists = [disabled(l) for l in network]
        row('local_network_async_dns_off_in_helpers', bool(network) and all({'AsyncDns', 'OpenLocalNetworkProbe', 'MediaRouter'} <= d for d in lists),
            networkHelpers=len(network), disableFeatures=[sorted(d) for d in lists])
    finally:
        app.quit()
    raw = netlog.read_text() if netlog.exists() else ''
    if raw and not raw.rstrip().endswith('}'):
        raw = raw.rstrip().rstrip(',') + ']}'   # a net log cut at quit has no closing brackets
    events, names = [], {}
    try:
        log = json.loads(raw)
        names = {v: k for k, v in log['constants']['logEventTypes'].items()}
        events = log['events']
    except (ValueError, KeyError):
        pass
    def of(kind): return [e.get('params', {}) for e in events if names.get(e['type']) == kind]
    configs = of('DNS_CONFIG_CHANGED')
    udp53 = [p['address'] for p in of('UDP_CONNECT') if str(p.get('address', '')).endswith(':53')]
    system = len(of('HOST_RESOLVER_SYSTEM_TASK'))
    builtin = len(of('DNS_TRANSACTION_ATTEMPT'))
    row('local_network_lookup_uses_system_resolver', bool(events) and bool(configs)
        and all(c.get('can_use_insecure_dns_transactions') is False for c in configs)
        and builtin == 0 and not udp53 and system >= 1,
        insecureClient=[c.get('can_use_insecure_dns_transactions') for c in configs], builtInAttempts=builtin,
        udpPort53=udp53, systemTasks=system, events=len(events))
