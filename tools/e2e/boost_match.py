"""Boost document-start matching through the real App (bug sweep round 3, lane BOOSTLIB3).

The Boosts are seeded through persistence (the Profile's Boosts/boosts.json, read at launch),
then real engine navigations run their main-world JavaScript at document start.

BM1 (E5): a Boost whose code declares `const path` (a name the match gate also used) runs,
  and two Boosts on one page can declare the same name.
BM2 (E5): the gate keeps the exact matching set: on a page that a host-wide Boost and two
  path Boosts match, the host-wide Boost's code runs once (one script, not two).
BM3 (E11): a Boost for the IPv6 literal ::1 runs on http://[::1]:<port>/ (a URL with a port).
BM4 (E14): a stored path prefix with a space (a hand-edited file) matches the browser's
  percent-encoded path.
BM5 (review round 1): a path prefix with "[" "]" matches at document start. Chromium keeps
  them raw in location.pathname; Foundation encodes them as %5B %5D.
Synthetic pages on loopback servers only.
"""
import json
import os
import threading
import time
import uuid
from pathlib import Path
import http.server
from loopback_http import LoopbackHTTPServer, LoopbackHTTPServer6


class _Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Boost match fixture</title><h1>Boost match</h1>'
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def log_message(self, *_):
        pass


def _serve(cls):
    server = cls(_Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def _boost(name, domain, js, path=None):
    now = time.time()
    match = {'domain': domain}
    if path is not None:
        match['pathPrefix'] = path
    return {'id': str(uuid.uuid4()).upper(), 'name': name, 'siteMatch': match, 'isEnabled': True, 'css': '', 'js': js,
            'zaps': [], 'createdAt': now, 'updatedAt': now}


def run(factory, results, tmp, env):
    wait = env['wait_until']
    v4, v6 = _serve(LoopbackHTTPServer), _serve(LoopbackHTTPServer6)
    origin, origin6 = 'http://127.0.0.1:%d' % v4.server_address[1], 'http://[::1]:%d' % v6.server_address[1]
    app, saved = None, {}

    def record(key, ok, **detail):
        results[key] = dict(ok=bool(ok), load=list(os.getloadavg()), **detail)
        print(key, 'PASS' if ok else 'FAIL', flush=True)

    def count(name):
        return "window.%s=(window.%s||0)+1;" % (name, name)
    try:
        app = factory(urls=('about:blank',), fresh=True)
        for key, value in {'open.advanced.enableBoosts': True, 'open.boosts.hasDismissedInterstitial': True,
                           'open.boosts.hasDismissedJSNotice': True}.items():
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=value)
        snapshot = json.loads(Path(app.call('save')).read_text())
        profile = next(p for p in snapshot['profiles'] if p['id'] == next(s for s in app.call('spaces') if s['focused'])['profile'])
        boosts_file = Path(app.user_data) / 'Profiles' / profile.get('dataDirectoryName', 'Default') / 'Boosts' / 'boosts.json'
        app.quit()
        boosts = [
            _boost('Gate names', '127.0.0.1', "const path = 'boost', u = 1, h = 2, ids = 3;" + count('gateNamesRuns') + "window.gatePath = path;", '/e5'),
            _boost('Same names', '127.0.0.1', "const path = 'second';" + count('sameNamesRuns'), '/e5'),
            _boost('Host wide', '127.0.0.1', count('hostWideRuns')),
            _boost('Space path', '127.0.0.1', count('spacePathRuns'), '/my docs'),
            _boost('IPv6', '::1', count('ipv6Runs')),
            _boost('Bracket path', '127.0.0.1', count('bracketRuns'), '/v1[test]'),
        ]
        boosts_file.parent.mkdir(parents=True, exist_ok=True)
        boosts_file.write_text(json.dumps({'schemaVersion': 1, 'profileID': profile['id'], 'boosts': boosts}))
        app = factory(urls=('about:blank',))
        tab = env['new_tab'](app, origin + '/e5/page.html')
        app.call('select', tab=tab); app.call('wait', tab=tab)

        def probe(url):
            app.call('navigate', tab=tab, url=url); app.call('wait', tab=tab)
            return app.eval(tab, "({url:location.href,gateNames:window.gateNamesRuns??0,gatePath:window.gatePath??null,"
                                 "sameNames:window.sameNamesRuns??0,hostWide:window.hostWideRuns??0,"
                                 "spacePath:window.spacePathRuns??0,ipv6:window.ipv6Runs??0,bracket:window.bracketRuns??0})")
        e5 = probe(origin + '/e5/page.html')
        record('BM1_boost_js_names_isolated', e5['gateNames'] == 1 and e5['gatePath'] == 'boost' and e5['sameNames'] == 1, page=e5,
               negative="old script declared the gate's const path in the Boost's scope: SyntaxError, no Boost code ran")
        other = probe(origin + '/other.html')
        record('BM2_exact_set_runs_once', e5['hostWide'] == 1 and other['hostWide'] == 1 and other['gateNames'] == 0 and other['sameNames'] == 0,
               e5=e5, other=other, negative='two scripts passing their gates on one page run the host-wide code twice')
        v6_page = probe(origin6 + '/v6.html')
        record('BM3_ipv6_literal_with_port', v6_page['ipv6'] == 1 and v6_page['url'].startswith('http://[::1]:'), page=v6_page,
               negative='old SplitUrl kept ":<port>" in the IPv6 host, so the *://[::1]/* pattern never matched')
        spaced = probe(origin + '/my%20docs/page.html')
        stored = next(b for b in app.call('boosts', action='list') if b['name'] == 'Space path')
        record('BM4_space_path_prefix_matches', spaced['spacePath'] == 1 and spaced['hostWide'] == 1 and stored['siteMatch'].get('pathPrefix') == '/my%20docs',
               page=spaced, stored=stored['siteMatch'], negative='raw "/my docs" never equals the percent-encoded "/my%20docs"')
        bracket = probe(origin + '/v1[test]/page.html')
        stored = next(b for b in app.call('boosts', action='list') if b['name'] == 'Bracket path')
        record('BM5_bracket_path_prefix_matches', bracket['bracket'] == 1 and '[test]' in bracket['url'] and stored['siteMatch'].get('pathPrefix') == '/v1%5Btest%5D',
               page=bracket, stored=stored['siteMatch'], negative='the matcher saw /v1%5Btest%5D (Foundation) but the stored prefix or the page gate kept /v1[test]')
    finally:
        try:
            env['_restore_defaults'](app if app and not app.closed else None, saved)
        finally:
            if app and not app.closed:
                app.quit()
            for server in (v4, v6):
                server.shutdown(); server.server_close()
