#!/usr/bin/env python3
"""Settings ▸ Advanced "Allow websites to get your theme data" (PB1, LEAD 10:00 (2)).

Real App, loopback page. Default ON (as in Arc). Off: the page sees none of the variables. On: the page's
computed `--arc-*` and `--open-*` values equal what the App reports for the tab's Space. A new
navigation keeps them. Off again: they are gone. Run:
python3 tools/e2e/theme_data.py --output DIR [--config Release]
"""
import argparse
import http.server
import json
from pathlib import Path
import tempfile
import threading
import time

from engine_e2e import Open, wait_until, new_tab

KEY = 'open.advanced.allowSitesThemeData'
READ = "(() => { const cs = getComputedStyle(document.documentElement); const out = {};" \
       " for (const n of %s) { const v = cs.getPropertyValue(n).trim(); if (v) out[n] = v; } return out; })()"


def run(output, config='Release'):
    output.mkdir(parents=True, exist_ok=True)
    result = {'checks': {}}

    def check(name, ok, **evidence):
        result['checks'][name] = dict(ok=bool(ok), **evidence)
        print(('PASS ' if ok else 'FAIL ') + name, flush=True)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ('<!doctype html><title>Theme %s</title><p>theme data</p>' % self.path).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *a): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    app = None
    with tempfile.TemporaryDirectory(prefix='open-theme-data-') as data:
        try:
            app = Open(config, 'chrome', data, [], str(output / 'app.log'), urls=(origin + '/one',))
            saved = app.call('defaults', key=KEY, persistent=True)
            tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab)
            def names(): return [n for n in (app.call('theme-data-state', tab=tab)['variables'] or {})]
            all_names = ['--%s-%s' % (p, s) for p in ('arc', 'open') for s in (
                'palette-foregroundPrimary', 'palette-foregroundSecondary', 'palette-foregroundTertiary', 'palette-maxContrastColor',
                'palette-minContrastColor', 'palette-backgroundExtra', 'palette-background', 'palette-focus', 'palette-hover',
                'palette-cutoutColor', 'palette-title', 'palette-subtitle', 'background-gradient-color',
                'background-gradient-overlay-color', 'background-simple-color')]
            def page(): return app.eval(tab, READ % json.dumps(all_names))
            try:
                # Registered default is ON (as in Arc): with no stored value, the page already has the variables.
                app.call('defaults', key=KEY, value=None)
                default_on = wait_until(lambda: (lambda p: p if p.get('--arc-palette-title') else None)(page()), timeout=5, step=.1)
                check('on_by_default', bool(default_on) and app.call('theme-data-state', tab=tab)['enabled'], page=page())
                app.call('defaults', key=KEY, value=False)
                off = wait_until(lambda: page() == {}, timeout=5, step=.1)
                check('off_page_sees_nothing', bool(off), page=page())
                app.call('defaults', key=KEY, value=True)
                expected = wait_until(lambda: (lambda s: s['variables'] if s['enabled'] and s['variables'] else None)(app.call('theme-data-state', tab=tab)), timeout=5, step=.1) or {}
                got = wait_until(lambda: (lambda p: p if p and p == expected else None)(page()), timeout=5, step=.1)
                pairs = all(expected.get('--arc-' + n[len('--open-'):]) == v for n, v in expected.items() if n.startswith('--open-'))
                # Capture PB1-d: uppercase #RRGGBBAA; Arc's default theme has the full palette, no background values.
                fmt = all(__import__('re').fullmatch(r'#[0-9A-F]{8}', v) for v in expected.values())
                check('on_page_reads_both_prefixes', bool(got) and pairs and fmt and len(expected) == 24
                      and expected.get('--arc-palette-title') == '#0A0D4BFF' and '--arc-background-simple-color' not in expected,
                      expected=expected, page=page())
                app.call('navigate', tab=tab, url=origin + '/two'); app.call('wait', tab=tab)
                kept = wait_until(lambda: page() == expected, timeout=5, step=.1)
                check('navigation_keeps_variables', bool(kept), page=page())
                # A themed Space (palette present): every role appears and the open page updates live.
                gold = {'mathVersion': 1, 'keyColor': {'red': 0xBD / 255, 'green': 0x9C / 255, 'blue': 0x26 / 255, 'alpha': 1},
                        'colorCount': 1, 'wheel': 'analogous', 'appearance': 'automatic', 'noiseFactor': 0, 'texture': 'grain', 'intensityFactor': .8}
                app.call('theme-set', style=gold)
                themed = wait_until(lambda: (lambda v: v if v and v != expected and '--arc-palette-title' in v else None)(
                    app.call('theme-data-state', tab=tab)['variables']), timeout=5, step=.1) or {}
                live = wait_until(lambda: (lambda p: p if p and p == themed else None)(page()), timeout=5, step=.1)
                check('themed_space_palette_live', bool(themed) and len(themed) == 26 and bool(live)
                      and themed.get('--arc-background-simple-color') == themed.get('--arc-palette-foregroundPrimary'), expected=themed, page=page())
                app.call('defaults', key=KEY, value=False)
                gone = wait_until(lambda: page() == {}, timeout=5, step=.1)
                check('off_removes_variables', bool(gone), page=page())
            finally:
                app.call('defaults', key=KEY, value=saved)
                app.call('theme-set', style=None)
        except Exception as error:
            check('flow_completed', False, error=repr(error))
        finally:
            if app:
                app.quit(); result['cleanup'] = getattr(app, 'quit_report', {})
            server.shutdown(); server.server_close()
    result['ok'] = all(c['ok'] for c in result['checks'].values()) and bool(result.get('cleanup', {}).get('ok'))
    (output / 'results-theme-data.json').write_text(json.dumps(result, indent=2, default=str))
    print('suite ' + ('PASS' if result['ok'] else 'FAIL'), flush=True)
    return result['ok']


if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--output', required=True, type=Path)
    p.add_argument('--config', choices=['Debug', 'Release'], default='Release'); a = p.parse_args()
    raise SystemExit(0 if run(a.output, a.config) else 1)
