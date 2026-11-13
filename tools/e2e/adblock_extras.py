"""PB2 row 1: scriptlets, :style() and :has() through the real App, real lists and real pages.

A private server serves the pinned official lists plus synthetic extra rules for the mapped
host open-adblock.test. No request reaches a public host. Rows (AX_*):
  build           the adapter built one main-world script and one stylesheet for the host
  style           `:style()` applies its declarations with !important over the page
  style_refused   a `:style(url(...))` rule is refused (no background, counted as skipped)
  set_constant    `+js(set-constant, …)` holds before the first page script runs
  nostif          `+js(nostif, adTimer)` stops only the matching timer
  has_hides       plain `:has()` hiding comes from the engine (no extras script needed)
  other_domain    a rule for another domain does not run here (other_domain_own_page: it runs there)
  exception       `#@#+js(set-constant, openExceptedProbe, true)` stops that one call
  excluded_off    a site exclusion removes every extra (and the engine's :has hide)
  reincluded_on   removing the exclusion brings them back
  global_off/on   the global switch removes them and brings them back
"""
import hashlib
import http.server
import json
import threading
import urllib.parse
from pathlib import Path
from loopback_http import LoopbackHTTPServer

EXTRA_RULES = b'''
! Open PB2 row 1 synthetic extras (e2e only)
open-adblock.test##.style-target:style(outline: 3px solid rgb(255, 0, 0); color: rgb(0, 128, 0))
open-adblock.test##.evil-target:style(background: url(http://open-adblock.test/evil.png))
open-adblock.test##+js(set-constant, openScriptletProbe, true)
open-adblock.test##+js(set-constant, openExceptedProbe, true)
open-adblock.test#@#+js(set-constant, openExceptedProbe, true)
open-adblock.test##+js(nostif, adTimer)
open-adblock.test##div.has-parent:has(> .has-child)
other-domain.test##+js(set-constant, openOtherProbe, true)
'''

PAGE = b'''<!doctype html><title>Open ad-block extras</title><link rel="icon" href="data:,">
<script>
window.__probeAtParse = window.openScriptletProbe;
window.openScriptletProbe = false;
window.__probeAfterWrite = window.openScriptletProbe;
window.__timerFired = false; window.__keptTimer = false;
setTimeout(function adTimer() { window.__timerFired = true; }, 20);
setTimeout(function keepTimer() { window.__keptTimer = true; }, 20);
</script>
<div class="style-target">styled</div>
<div class="evil-target">refused</div>
<div class="has-parent" id="has-hit"><span class="has-child">x</span></div>
<div class="has-parent" id="has-control"><span>y</span></div>
'''

STATE = '''new Promise(r => setTimeout(() => { const cs = s => getComputedStyle(document.querySelector(s)); r({
  outline: cs('.style-target').outlineStyle + ' ' + cs('.style-target').outlineWidth,
  color: cs('.style-target').color,
  evilBackground: cs('.evil-target').backgroundImage,
  probeAtParse: window.__probeAtParse === undefined ? 'undefined' : window.__probeAtParse,
  probeAfterWrite: window.__probeAfterWrite === undefined ? 'undefined' : window.__probeAfterWrite,
  excepted: typeof window.openExceptedProbe,
  other: typeof window.openOtherProbe,
  timerFired: window.__timerFired, keptTimer: window.__keptTimer,
  hasHit: cs('#has-hit').display, hasControl: cs('#has-control').display,
}); }, 400))'''


def run(factory, results, wait):
    from engine_e2e import _restore_defaults
    repo = Path(__file__).resolve().parents[2]
    pinned = {}
    for line in (repo / 'Packages/OpenKit/Sources/OpenAdBlock/Resources/list-pins.txt').read_text().splitlines():
        if not line.strip() or line.startswith('#'): continue
        name, _, digest = line.split()
        body = (repo / 'Vendor/adblock' / name).read_bytes()
        assert hashlib.sha256(body).hexdigest() == digest, 'fixture must match the official bundled pin'
        pinned[name] = body
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            if self.path.endswith('.txt'):
                name = Path(urllib.parse.urlsplit(self.path).path).name
                body, mime = pinned[name] + (EXTRA_RULES if name == 'easylist.txt' else b'\n! Open refresh\n'), 'text/plain'
            else:
                body, mime = PAGE, 'text/html'
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
        def log_message(self, *_): pass

    server = LoopbackHTTPServer(Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    origin = 'http://open-adblock.test'
    args = ['--host-resolver-rules=MAP open-adblock.test 127.0.0.1:%d, MAP other-domain.test 127.0.0.1:%d' % (port, port),
            '--no-proxy-server']
    keys = {'open.settings.lastPane': 'general', 'open.general.searchSuggestNoticeDismissed': True,
            'open.links.littleOpenNUXSeen': True}
    app, saved = None, {}

    def row(name, ok, **evidence):
        print('AX_' + name, 'PASS' if ok else 'FAIL', json.dumps(evidence, sort_keys=True, default=str), flush=True)
        results['AX_' + name] = dict(ok=bool(ok), **evidence)

    def extras(profile):
        state = app.call('settings-adblock-engine')
        return next(p for p in state['profiles'] if p['profile'] == profile)['extras']

    def scripts_ready(profile, present):
        wanted = {'open.adblock.extras.open-adblock.test.js', 'open.adblock.extras.open-adblock.test.css'}
        def check():
            e = extras(profile)
            if e['pending']: return None
            have = wanted.issubset(set(e['scripts']))
            return e if have == present else None
        return wait(check, timeout=60)

    def load(tab, path='/extras'):
        app.call('navigate', tab=tab, url=origin + path)
        app.call('wait', tab=tab)
        return app.call('eval', tab=tab, js=STATE)

    def on(s):
        return (s['outline'] == 'solid 3px' and s['color'] == 'rgb(0, 128, 0)' and s['probeAtParse'] is True
                and s['probeAfterWrite'] is True and not s['timerFired'] and s['keptTimer'])

    def off(s):
        return (s['outline'].startswith('none') and s['color'] != 'rgb(0, 128, 0)' and s['probeAtParse'] == 'undefined'
                and s['probeAfterWrite'] is False and s['timerFired'] and s['keptTimer'] and s['excepted'] == 'undefined')

    try:
        app = factory(urls=('about:blank',), fresh=True, load_extensions=False, extra_args=args,
                      extra_env={'OPEN_ADBLOCK_DEBUG_SCHEDULE_SCALE': '0.1',
                                 'OPEN_ADBLOCK_DEBUG_SOURCE_ROOT': 'http://127.0.0.1:%d' % port})
        for key, value in keys.items():
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=None)
            app.call('defaults', key=key, value=value)
        if not app.call('settings-adblock-engine')['nativeSupported']:
            row('native_support', False)
            return
        profile = next(p for p in app.call('profiles-shell')['profiles'] if p['name'] == 'Default')
        app.call('profiles-shell', profile=profile['id'], action='adblock-open')
        app.call('settings-adblock', enabled=True)
        built = scripts_ready(profile['id'], True)
        row('build', bool(built) and built['skipped'] >= 1 and built['installedContexts'] >= 1, extras=built or extras(profile['id']))
        tab = app.call('open', url='about:blank')['id']
        app.call('wait', tab=tab)
        s = load(tab)
        row('style', s['outline'] == 'solid 3px' and s['color'] == 'rgb(0, 128, 0)', state=s)
        row('style_refused', s['evilBackground'] == 'none' and not any(p.startswith('/evil.png') for p in requests), state=s)
        row('set_constant', s['probeAtParse'] is True and s['probeAfterWrite'] is True, state=s)
        row('nostif', s['timerFired'] is False and s['keptTimer'] is True, state=s)
        row('has_hides', s['hasHit'] == 'none' and s['hasControl'] != 'none', state=s)
        row('other_domain', s['other'] == 'undefined', state=s)
        row('exception', s['excepted'] == 'undefined', state=s)
        # The other domain's own page does get its rule.
        app.call('navigate', tab=tab, url='http://other-domain.test/extras')
        app.call('wait', tab=tab)
        own = app.call('eval', tab=tab, js='typeof window.openOtherProbe === "boolean" && window.openOtherProbe')
        row('other_domain_own_page', own is True, own=own)

        app.call('settings-adblock', host='open-adblock.test', excluded=True)
        gone = scripts_ready(profile['id'], False)
        s = load(tab)
        row('excluded_off', bool(gone) and off(s) and s['hasHit'] != 'none', state=s, extras=gone)
        app.call('settings-adblock', host='open-adblock.test', excluded=False)
        back = scripts_ready(profile['id'], True)
        s = load(tab)
        row('reincluded_on', bool(back) and on(s) and s['hasHit'] == 'none', state=s)
        app.call('settings-adblock', enabled=False)
        gone = scripts_ready(profile['id'], False)
        s = load(tab)
        row('global_off', bool(gone) and off(s), state=s)
        app.call('settings-adblock', enabled=True)
        back = scripts_ready(profile['id'], True)
        s = load(tab)
        row('global_on', bool(back) and on(s), state=s)
    finally:
        try:
            if app:
                for key, value in saved.items(): app.call('defaults', key=key, value=value)
                app.quit()
        finally:
            _restore_defaults(app, saved)
            server.shutdown()
            server.server_close()
