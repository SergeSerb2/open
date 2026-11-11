#!/usr/bin/env python3
"""Real-window frames of the command card, the inline address editor, the long-host URL field
and the Site Control panel (plan D3 §2): views × Space themes × Light/Dark at 1280×800.

Run under the on-screen lock with a built automation App:
  /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/commandbar_frames.py --out DIR [--config Debug]
Pages are synthetic loopback fixtures; nothing leaves the machine. Frames are private (.re/ or the
handoff folder), never committed.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import runpy
import struct
import tempfile
import threading
import time
import zlib

ROOT = Path(__file__).resolve().parents[2]
PAGES = {'lisbon': ('Lisbon weather', (63, 122, 92)), 'lemon': ('Lemon pasta', (168, 80, 44)),
         'trip': ('Trip planning', (79, 125, 240))}
LONG_HOST = 'long-synthetic-host-name-for-url-truncation.localhost'
THEMES = {
    'night': None,  # Open's default theme
    'gold': {'mathVersion': 1, 'keyColor': {'red': 0xB9 / 255, 'green': 0xA3 / 255, 'blue': 0x5F / 255, 'alpha': 1}, 'colorCount': 1,
             'wheel': 'analogous', 'appearance': 'automatic', 'noiseFactor': 0, 'texture': 'grain', 'intensityFactor': .8},
    'pastel': {'mathVersion': 1, 'keyColor': {'red': 0xFA / 255, 'green': 0xE1 / 255, 'blue': 0xD5 / 255, 'alpha': 1}, 'colorCount': 1,
               'wheel': 'analogous', 'appearance': 'automatic', 'noiseFactor': 0, 'texture': 'grain', 'intensityFactor': .8},
}


def png(rgb, size=32):
    """A rounded-square favicon with a white dot, like the mock-up's synthetic sites."""
    rows = []
    r = size * 0.28
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            cx, cy = min(x, size - 1 - x), min(y, size - 1 - y)
            inside = not (cx < r and cy < r and (r - cx) ** 2 + (r - cy) ** 2 > r * r)
            dot = (x - size / 2 + .5) ** 2 + (y - size / 2 + .5) ** 2 < (size * .22) ** 2
            row += bytes((255, 255, 255, 255) if inside and dot else (*rgb, 255) if inside else (0, 0, 0, 0))
        rows.append(bytes(row))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


def serve(name):
    title, rgb = PAGES.get(name, ('Long article', (63, 122, 92)))
    icon = png(rgb)
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith('/favicon'):
                body, kind = icon, 'image/png'
            else:
                body = ("<!doctype html><title>%s</title><link rel=icon href=/favicon.png>"
                        "<body style='margin:0;background:#f3f5ee;color:#24382c;font:20px -apple-system'>"
                        "<h1 style='font-size:40px;margin:70px 60px 0'>%s</h1><p style='margin:22px 60px'>"
                        "<a href=#>Long article</a><p style='margin:22px 60px'><a href=#>Form</a>" % (title, title)).encode()
                kind = 'text/html'
            self.send_response(200); self.send_header('Content-Type', kind); self.send_header('Cache-Control', 'max-age=3600')
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--config', default='Debug')
    parser.add_argument('--themes', default='night,gold,pastel')
    parser.add_argument('--appearances', default='light,dark')
    parser.add_argument('--views', default='newtab,edit,long,site')
    options = parser.parse_args()
    out = Path(options.out).resolve(); out.mkdir(parents=True, exist_ok=True)
    h = runpy.run_path(str(ROOT / 'tools/e2e/engine_e2e.py'))
    wait = h['wait_until']
    servers = {name: serve(name) for name in list(PAGES) + ['long']}
    url = lambda name: 'http://127.0.0.1:%d/%s' % (servers[name].server_address[1], name)
    long_url = 'http://%s:%d/article' % (LONG_HOST, servers['long'].server_address[1])
    manifest = []
    with tempfile.TemporaryDirectory(prefix='open-d3-frames-', dir='/tmp') as scratch:
        app = h['Open'](options.config, 'chrome', str(Path(scratch) / 'data'), ['--use-mock-keychain'],
                        str(Path(scratch) / 'app.log'), urls=tuple(url(n) for n in PAGES))
        tracker = h['FocusTracker'](); tracker.apps.append(app); app.focus_tracker = tracker
        try:
            app.call('window-frame', frame=[40, 40, 1280, 800])
            state = app.call('window-state')
            width = state['sidebarWidth']
            if width != 366:
                app.call('mouse', **{'from': [width, 400], 'to': [366, 400]})
            app.call('suggest-remote', enabled=False)
            tabs = app.call('tabs')
            for t in tabs: app.call('wait', tab=t['id'])
            lisbon = next(t['id'] for t in app.call('tabs') if t['url'].endswith('/lisbon'))
            # Let favicons reach the store before the bar reads them.
            time.sleep(1.5)
            def press(key, **kw): return app.call('key', key=key, **kw)
            def bar(): return app.call('commandbar-state')
            def snap(name, extra):
                path = out / (name + '.png')
                time.sleep(.35)
                app.call('snapshot', path=str(path), window=app.call('window-state')['number'])
                row = dict(name=name, path=str(path), window=app.call('window-state'), **extra)
                manifest.append(row); print(json.dumps({k: row[k] for k in ('name', 'path')}), flush=True)
            for theme in options.themes.split(','):
                app.call('theme-set', style=THEMES[theme]); time.sleep(.5)
                for appearance in options.appearances.split(','):
                    app.call('appearance', name=appearance); time.sleep(.4)
                    app.call('select', tab=lisbon); app.call('focus', tab=lisbon)
                    key = '%s-%s' % (theme, appearance)
                    for view in options.views.split(','):
                        if view == 'newtab':
                            press('t', modifiers=['cmd'], route='window')
                            assert wait(lambda: bar().get('presented'), timeout=3, step=.05), bar()
                            app.call('key', text='Lisbon')
                            assert wait(lambda: bar().get('text') == 'Lisbon' and bar().get('final'), timeout=5, step=.05), bar()
                            snap('newtab-' + key, dict(bar=bar()))
                            press('escape'); wait(lambda: not bar().get('presented'), timeout=3, step=.05)
                        elif view == 'edit':
                            press('l', modifiers=['cmd'], route='window')
                            assert wait(lambda: bar().get('presented') and bar().get('final'), timeout=5, step=.05), bar()
                            snap('edit-' + key, dict(bar=bar()))
                            press('escape'); wait(lambda: not bar().get('presented'), timeout=3, step=.05)
                        elif view == 'long':
                            app.call('navigate', tab=lisbon, url=long_url); app.call('wait', tab=lisbon)
                            app.call('mouse', action='hover', x=150, y=64)
                            snap('long-' + key, dict(field=app.call('window-state').get('sidebarFrame')))
                            app.call('mouse', action='hover', x=800, y=500)
                            app.call('navigate', tab=lisbon, url=url('lisbon')); app.call('wait', tab=lisbon)
                        elif view == 'site':
                            opened = app.call('site-controls', action='open', via='urlField')
                            snap('site-' + key, dict(scc=opened))
                            app.call('site-controls', action='close')
            app.call('theme-set', style=None); app.call('appearance', name='system')
        finally:
            app.quit()
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=1, default=str))
    for server in servers.values(): server.shutdown()


if __name__ == '__main__':
    main()
