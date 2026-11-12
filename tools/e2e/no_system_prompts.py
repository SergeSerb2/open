"""No suite may raise a macOS permission prompt (LEAD 12:24, 2026-11-12).

A prompt such as "Allow 'Open' to access your microphone?" (UserNotificationCenter) blocks every
on-screen suite on that Mac until a person answers it. Automation launches pass
--use-fake-device-for-media-stream, so a page that asks for the camera and microphone gets fake
devices and Chromium never asks macOS. Rows: the page gets live fake tracks; macOS camera and
microphone status is unchanged (never requested); no system dialog is on screen afterwards.
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
