"""UX round 1 wave 2 (UXC): error and empty states in the real App.

Rows (each fails on the parent code and passes with the fix):
- states_sad_tab_buttons_readable_dark: a light Space theme in a dark window; the crashed page's
  "Close Tab" label must be readable (pixels inside the button), and both buttons draw light.
- states_import_no_arc_data: Settings ▸ Import from Arc on a folder with no Arc data; the error is
  plain and has no path, and every Arc data type that was not found is unticked.
- states_download_time_left: a running download with a known size shows its time left in plain
  units ("25 min left"), not raw seconds ("1519s").

Loopback only: one HTTP server on 127.0.0.1; no host names, no real network.
"""
import json
import re
import socket
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path.startswith('/slow'):
            self.send_response(200); self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="slow-file.dmg"')
            self.send_header('Content-Length', str(50_000_000)); self.end_headers()
            try:
                for _ in range(300):
                    self.wfile.write(b'y' * 4096); self.wfile.flush(); time.sleep(.1)
            except OSError: pass
            return
        body = b'<!doctype html><title>State page</title><body style="margin:40px;font:16px -apple-system">A page</body>'
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)


def run(factory, results, tmp, h):
    server = ThreadingHTTPServer(('127.0.0.1', 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]

    def row(name, ok, **detail):
        print(name, 'PASS' if ok else 'FAIL', flush=True)
        results[name] = dict(detail, ok=bool(ok))

    try:
        _sad_tab(factory, row, tmp, h, base)
        _import(factory, row, tmp, h)
        _download(factory, row, tmp, h, base)
    finally:
        server.shutdown(); server.server_close()


def _sad_tab(factory, row, tmp, h, base):
    # The schema fixture's first Space has a light theme (light content over a light sidebar).
    data = json.loads(Path(h.ROOT, 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json').read_text())
    fixture = Path(tmp, 'states-sad-tab.json'); fixture.write_text(json.dumps(data))
    app = factory(urls=(), snapshot=str(fixture))
    try:
        app.call('appearance', name='dark')
        tab = app.call('open', url=base + '/page')['id']; app.call('wait', tab=tab)
        app.call('navigate', tab=tab, url='chrome://kill')
        state = h.wait_until(lambda: (lambda s: s if s.get('shown') else None)(app.call('sad-tab-state', tab=tab)), timeout=10, step=.1) or {}
        time.sleep(.5)
        shot = str(Path(tmp, 'states-sad-tab.png')); app.call('snapshot', path=shot)
        width, height, pixel = h.read_image(shot)
        scale = width / app.call('window-state')['frame'][2]
        close = next((b for b in state.get('buttons', []) if b.get('id') == 'sad-tab-close'), {})
        spread = 0
        if close.get('frame'):
            x, y, w, hgt = close['frame']
            lumas = [h.luma(pixel(px * scale, py * scale)) for px in range(int(x + 6), int(x + w - 6))
                     for py in range(int(y + 6), int(y + hgt - 6))]
            spread = max(lumas) - min(lumas) if lumas else 0
        appearances = [b.get('appearance', '') for b in state.get('buttons', [])]
        row('states_sad_tab_buttons_readable_dark', state.get('shown') and spread >= 80
            and all(a.endswith('Aqua') and 'Dark' not in a for a in appearances),
            closeLabelLumaSpread=round(spread, 1), buttonAppearances=appearances, snapshot=shot)
        app.call('appearance', name='light')
    finally:
        app.quit()


def _import(factory, row, tmp, h):
    empty = tempfile.mkdtemp(prefix='states-no-arc-data-', dir=tmp)
    app = factory(urls=(), fresh=True)
    try:
        # The Settings wizard fields come back only from a settings-… action; this one waits for the counts.
        state = app.call('first-run', action='settings-import', directory=empty)
        error = state.get('settingsWizardError', '')
        plan = state.get('settingsArcPlan', {})
        not_found = state.get('settingsArcNotFound', [])
        row('states_import_no_arc_data', bool(error) and empty not in error and '/' not in error and len(error) <= 120
            and set(not_found) == set(plan) and plan and not any(plan.values()),
            error=error, arcPlan=plan, arcNotFound=not_found)
        try: app.call('first-run', action='settings-done')
        except RuntimeError: pass
    finally:
        app.quit()


def _download(factory, row, tmp, h, base):
    app = factory(urls=(), fresh=True)
    try:
        tab = app.call('open', url=base + '/page')['id']; app.call('wait', tab=tab)
        before = {v['id'] for v in app.call('downloads-state')['items']}
        app.eval(tab, '(() => {let a=document.createElement("a"); a.href=%s; a.id="dl"; a.textContent="dl"; document.body.replaceChildren(a)})()' % json.dumps(base + '/slow'))
        app.call('click', tab=tab, selector='#dl')
        key = h.wait_until(lambda: next((v['id'] for v in app.call('downloads-state')['items'] if v['id'] not in before), None), timeout=10, step=.1)
        app.call('command', id='view-downloads')
        def subtitle():
            r = next((r for r in app.call('downloads-state')['rows'] if r.get('id') == key), {})
            text = r.get('subtitle', '')
            return text if ' · ' in text else None
        text = h.wait_until(subtitle, timeout=15, step=.2) or ''
        plain = bool(re.search(r' · (\d+ (sec|min|hr)|\d+ hr \d+ min) left$', text)) and not re.search(r'\d+s$', text)
        row('states_download_time_left', plain, subtitle=text)
        try: app.call('download-row', id=key, action='Cancel')
        except RuntimeError: pass
        try: app.call('download-library-close')
        except RuntimeError: pass
    finally:
        app.quit()
