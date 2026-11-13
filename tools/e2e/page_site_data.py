"""View menu site clears through the real App and local HTTP origin boundaries."""
from collections import Counter
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler
import os
import threading
from loopback_http import LoopbackHTTPServer


def run(factory, results, tmp, style, harness, site_control=False):
    hits = Counter()
    mutex = threading.Lock()

    class Page(BaseHTTPRequestHandler):
        def log_message(self, *args): pass

        def do_GET(self):
            host = self.headers.get('Host', '').split(':')[0]
            with mutex:
                key = (host, self.server.server_port, self.path)
                hits[key] += 1
                count = hits[key]
            cached = self.path == '/cached'
            if cached:
                body = ('cache-' + str(count)).encode()
            elif self.path == '/cookies':
                body = self.headers.get('Cookie', '').encode()
            else:
                body = b'''<!doctype html><title>View site clear fixture</title>
                  <body>Site clear fixture<script>
                    window.loadID = Math.random().toString(36);
                  </script></body>'''
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain' if cached or self.path == '/cookies' else 'text/html')
            self.send_header('Cache-Control', 'public, max-age=31536000, immutable' if cached else 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass

    resources = ExitStack()
    app = None
    saved = {}
    wait = harness.wait_until
    commands = ['clear-cache-and-refresh', 'clear-cookies-and-refresh']
    origins, cache_keys = [], []

    def check(name, ok, **evidence):
        results[name + '_' + style] = dict(ok=bool(ok), load=list(os.getloadavg()), **evidence)

    def open_page(url):
        tab = app.call('open', url=url)['id']
        # open://welcome is a native internal page, with no engine page to wait on.
        if not url.startswith('open:'):
            app.call('wait', tab=tab)
        return tab

    def select(tab):
        app.call('select', tab=tab)
        assert wait(lambda: app.call('window-state')['selected'] == tab, timeout=5)

    def cookies(tab):
        return app.eval(tab, "fetch('/cookies').then(r=>r.text())")

    def cookie_values(tab):
        return dict(value.split('=', 1) for value in cookies(tab).split('; ') if value)

    def cached(tab):
        return app.eval(tab, "fetch('/cached',{cache:'force-cache'}).then(r=>r.text())")

    def counts():
        with mutex:
            return [hits[(host, port, '/cached')] for host, port in cache_keys]

    def document_hits():
        with mutex:
            return hits[(*cache_keys[0], '/start')]

    def seed(tab, domain, value):
        return app.eval(tab, "document.cookie='hostCookie=%s;path=/';"
                        "document.cookie='domainCookie=%s;domain=%s;path=/';document.cookie" % (value, value, domain))

    def clear(tab, command):
        select(tab)
        before = app.eval(tab, 'window.loadID')
        if site_control:
            if app.call('site-controls')['presented']:
                app.call('site-controls', action='close')
            panel = app.call('site-controls', action='open')
            title = 'Clear Cache' if command == commands[0] else 'Clear Cookies'
            enabled = next((i['enabled'] for i in panel['items'] if i['title'] == title), False)
            app.call('site-controls', action='menu', item=title)
        else:
            enabled = (harness._menu_row(app, command) or {}).get('enabled')
            app.call('menu-perform', id=command)
        reloaded = wait(lambda: harness._try(lambda: (lambda v: v and v != before)(
            app.eval(tab, 'window.loadID'))), timeout=10)
        return enabled is True and bool(reloaded)

    def bar_actions():
        found = []
        for title, command in zip(['Clear Cache and Refresh', 'Clear Cookies and Refresh'], commands):
            app.call('key', key='t', modifiers=['cmd'], route='app')
            app.call('key', text=title)
            state = wait(lambda: (lambda s: s if s.get('final') and s.get('text') == title else None)(
                app.call('commandbar-state')), timeout=5)
            assert state, 'command bar query did not finish'
            found.append(any(row.get('action') == command for row in state.get('rows', [])))
            app.call('key', key='escape', route='app')
        return found

    try:
        servers = []
        for _ in range(2):
            server = resources.enter_context(LoopbackHTTPServer(Page))
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            resources.callback(worker.join, timeout=5)
            resources.callback(server.shutdown)
            servers.append(server)
        port, other_port = [server.server_port for server in servers]
        origins = ['http://a.clear-a.test:%d' % port, 'http://b.clear-b.test:%d' % port,
                   'http://sibling.clear-a.test:%d' % port, 'http://a.clear-a.test:%d' % other_port]
        cache_keys = [('a.clear-a.test', port), ('b.clear-b.test', port),
                      ('sibling.clear-a.test', port), ('a.clear-a.test', other_port)]
        app = factory(urls=(origins[0] + '/start',), fresh=True, load_extensions=False,
                      extra_args=['--host-resolver-rules=MAP *.test 127.0.0.1', '--no-proxy-server'])
        ta = app.call('tabs')[0]['id']
        app.call('wait', tab=ta)
        normal_window = app.call('window-state')['id']
        app.call('window-focus', id=normal_window, activate=True)
        key = 'open.general.searchSuggestNoticeDismissed'
        saved[key] = app.call('defaults', key=key, persistent=True)
        app.call('defaults', key=key, value=None)
        app.call('defaults', key=key, value=True)
        app.call('suggest-remote', enabled=False)
        tb = open_page(origins[1] + '/start')
        seeded = [seed(ta, 'clear-a.test', 'A'), seed(tb, 'clear-b.test', 'B')]
        # Inherited Domain cookies clear, but host-only cookies of the sibling
        # and parent must survive the clear of a.clear-a.test.
        sibling = open_page(origins[2] + '/start')
        sibling_before = cookies(sibling)
        app.eval(sibling, "document.cookie='siblingHost=kept;path=/';1")
        parent_tab = open_page('http://clear-a.test:%d/start' % port)
        app.eval(parent_tab, "document.cookie='parentHost=kept;path=/';1")
        other_port_tab = open_page(origins[3] + '/start')
        cache_tabs = [ta, tb, sibling, other_port_tab]
        cookie_tabs = [ta, tb, sibling, parent_tab]
        cookie_seed = [cookie_values(tab) for tab in cookie_tabs]
        check('K_seed_host_and_parent_domain', all('hostCookie=' in s and 'domainCookie=' in s for s in seeded)
              and sibling_before == 'domainCookie=A'
              and cookie_seed[2] == {'domainCookie': 'A', 'siblingHost': 'kept'}
              and cookie_seed[3] == {'domainCookie': 'A', 'parentHost': 'kept'},
              seeded=seeded, sibling=sibling_before, cookies=cookie_seed)
        first = [cached(tab) for tab in cache_tabs]
        repeated = [cached(tab) for tab in cache_tabs]
        before = counts()
        refreshed = clear(ta, commands[0])
        after_cache = [cached(tab) for tab in cache_tabs]
        after = counts()
        after_cookies = [cookie_values(tab) for tab in cookie_tabs]
        check('K1_clear_cache_and_refresh', refreshed and first == repeated == ['cache-1'] * 4
              and before == [1, 1, 1, 1] and after == [2, 1, 1, 1]
              and after_cache == ['cache-2', 'cache-1', 'cache-1', 'cache-1'] and after_cookies == cookie_seed,
              reloaded=refreshed, origins=origins, serverBefore=before, serverAfter=after,
              cache=after_cache, cookies=after_cookies)
        refreshed = clear(ta, commands[1])
        after_cookies = [cookie_values(tab) for tab in cookie_tabs]
        check('K2_clear_cookies_and_refresh', refreshed and after_cookies[0] == {}
              and after_cookies[1] == cookie_seed[1]
              and all('domainCookie' not in values for values in after_cookies[2:])
              and [cached(tab) for tab in cache_tabs] == after_cache and counts() == after,
              reloaded=refreshed, cookies=after_cookies, cacheCounts=counts())
        check('K_cookie_sibling_host_only_survives', after_cookies[2] == {'siblingHost': 'kept'},
              before=cookie_seed[2], after=after_cookies[2])
        check('K_cookie_parent_host_only_survives', after_cookies[3] == {'parentHost': 'kept'},
              before=cookie_seed[3], after=after_cookies[3])

        if site_control:
            app.call('site-controls', action='close')
        # Hold only delivery of the real engine completion. Change the hash and
        # invoke again while the first operation is still awaiting its refresh.
        # The bounded automation barrier releases itself after ten seconds.
        select(ta)
        old_load = app.eval(ta, 'window.loadID')
        old_requests = document_hits()
        app.call('page-site-data-probe', action='hold', tab=ta)
        try:
            app.call('menu-perform', id=commands[1])
            held = wait(lambda: (lambda s: s if s['waiting'] else None)(
                app.call('page-site-data-probe')), timeout=5)
            assert held, 'real clear did not reach its completion barrier'
            app.call('menu-perform', id=commands[1])
            duplicate = app.call('page-site-data-probe')
            changed_url = app.eval(ta, "location.hash='during-site-clear';location.href")
            assert wait(lambda: app.tab(ta).get('page', {}).get('url') == changed_url, timeout=5), 'hash URL not observed'
        finally:
            app.call('page-site-data-probe', action='release')
        reloaded = wait(lambda: harness._try(lambda: (lambda value: value and value != old_load)(
            app.eval(ta, 'window.loadID'))), timeout=10)
        if reloaded:
            app.call('wait', tab=ta)
        finished = app.call('page-site-data-probe')
        check('K_same_origin_hash_refresh', reloaded and document_hits() == old_requests + 1,
              reloaded=bool(reloaded), changedURL=changed_url, requests=[old_requests, document_hits()])
        check('K_inflight_clear_deduplicated', duplicate['starts'] == duplicate['completions'] == 1
              and duplicate['waiting'] and finished['starts'] == finished['completions'] == finished['refreshes'] == 1
              and document_hits() == old_requests + 1, held=held, duplicate=duplicate, finished=finished)
        select(ta)
        actions = bar_actions()
        check('K_site_commandbar_available', actions == [True, True], actions=actions)

        # Private context clearing must leave the parent's host and Domain
        # cookies, and its cached resource, intact.
        select(ta)
        seed(ta, 'clear-a.test', 'parent')
        app.call('menu-perform', id='new-incognito-window')
        private_window = wait(lambda: next((w for w in app.call('incognito-state')['windows'] if w['private']), None), timeout=5)
        assert private_window, 'private window did not open'
        app.call('window-focus', id=private_window['id'], activate=True)
        app.call('key', key='escape', route='app')
        private_tab = open_page(origins[0] + '/private')
        private_before = cookies(private_tab)
        seed(private_tab, 'clear-a.test', 'private')
        private_cache = cached(private_tab)
        private_refreshed = clear(private_tab, commands[0])
        private_cache_after = cached(private_tab)
        private_refreshed = clear(private_tab, commands[1]) and private_refreshed
        private_after = cookies(private_tab)
        app.call('window-close')
        app.call('window-focus', id=normal_window, activate=True)
        parent = cookies(ta)
        check('K_private_context_only', private_before == private_after == '' and private_refreshed
              and private_cache != private_cache_after and 'hostCookie=parent' in parent
              and 'domainCookie=parent' in parent and cached(ta) == after_cache[0],
              privateInitiallyEmpty=private_before == '', privateCookies=private_after, parentCookies=parent,
              privateCache=[private_cache, private_cache_after], parentCache=cached(ta), reloaded=private_refreshed)

        for index, url in enumerate(['about:blank', 'open://welcome', 'file://' + str(harness.Path(tmp) / 'site-clear.html')]):
            if url.startswith('file:'):
                (harness.Path(tmp) / 'site-clear.html').write_text('<!doctype html><title>Local clear guard</title>')
            tab = open_page(url)
            select(tab)
            rows = [harness._menu_row(app, command) for command in commands]
            refused = []
            for command in commands:
                try:
                    app.call('menu-perform', id=command)
                    refused.append(False)
                except RuntimeError as error:
                    refused.append('disabled menu item' in str(error))
            check('K_internal_commands_disabled_' + str(index), all(row and row['enabled'] is False for row in rows)
                  and all(refused), url=url, rows=rows, refused=refused)
            actions = bar_actions()
            check('K_internal_commandbar_unavailable_' + str(index), actions == [False, False], url=url, actions=actions)
            app.call('close', tab=tab)
    finally:
        try:
            if app:
                try:
                    harness._restore_defaults(app, saved)
                finally:
                    app.quit()
        finally:
            resources.close()
