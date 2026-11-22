"""Bug sweep round 6, lane ENG6: OpenEngine bridge rows through the real App automation socket.

Runs inside `engine_e2e.py --only routing`; OPEN_ROUTING_ENG6_ONLY=1 runs only these rows.
OPEN_E2E_ENG6_BUNDLE=<path to an Open.app> runs them against another build (break-and-revert
proof on a parent clone). Loopback pages only; every other host resolves to nothing.
"""
import http.server
import os
import threading
import time

from loopback_http import LoopbackHTTPServer

ENGINE_SWITCHES = ['--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1', '--no-proxy-server']

PAGES = {
    '/a': '<title>ENG6 A</title><h1>A</h1>',
    '/b': '<title>ENG6 B</title><h1>B</h1>',
    '/target': '<title>ENG6 Target</title><h1>Target</h1>',
    '/opener': ('<title>ENG6 Opener</title>'
                '<button id="open" style="position:fixed;left:0;top:0;width:300px;height:120px" '
                'onclick="window.open(\'/popup\', \'eng6\', \'width=520,height=420\')">open popup</button>'),
    '/popup': ('<title>ENG6 Popup</title>'
               '<a id="blank" target="_blank" href="/from-popup" '
               'style="display:block;width:300px;height:120px">new tab</a>'),
    '/from-popup': '<title>ENG6 From Popup</title><h1>from popup</h1>',
    '/biglink': ('<title>ENG6 Big Link</title><style>html,body{margin:0;height:100%}</style>'
                 '<a id="big" href="/target" style="display:block;width:100%;height:100%">target</a>'
                 '<script>window.aux=[];addEventListener("auxclick",e=>aux.push(e.button))</script>'),
}


def fixture_server():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ('<!doctype html><meta charset=utf-8>' + PAGES.get(self.path.split('?')[0], '<title>404</title>')).encode()
            self.send_response(200 if self.path.split('?')[0] in PAGES else 404)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args): pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, 'http://127.0.0.1:%d' % server.server_address[1]


def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def run(factory, results, tmp, h):
    wait_until = h.wait_until
    server, origin = fixture_server()
    bundle = os.environ.get('OPEN_E2E_ENG6_BUNDLE')
    env = {'OPEN_E2E_APP_BUNDLE': bundle} if bundle else None
    state = {'app': None}

    def launch(urls=('about:blank',), fresh=True):
        state['app'] = factory(urls=urls, fresh=fresh, extra_args=ENGINE_SWITCHES, extra_env=env)
        return state['app']

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('eng6 %-52s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
        if not ok:
            print('eng6   evidence: %r' % (evidence,), flush=True)

    only = {r for r in os.environ.get('OPEN_E2E_ENG6_ROWS', '').split(',') if r}

    def guarded(name, body):
        if only and not any(key in name for key in only):
            return
        try:
            body()
        except Exception as error:  # A failed setup is a FAIL row, never a skipped one.
            row(name, False, error=repr(error))
        finally:
            app = state['app']
            if app is not None and not app.closed:
                try:
                    app.quit()
                except Exception as error:
                    print('eng6 cleanup after %s: %r' % (name, error), flush=True)
            state['app'] = None

    def pages(app):
        return app.call('pages')

    def button_click(app, tab, selector, modifiers=0):
        """A real in-page click (DevTools input events: a user gesture) with optional modifiers."""
        rect = app.eval(tab, "(() => { const r = document.querySelector(%s).getBoundingClientRect();"
                             " return [r.x + r.width / 2, r.y + r.height / 2]; })()" % quote(selector))
        for kind in ('mousePressed', 'mouseReleased'):
            app.call('devtools', tab=tab, method='Input.dispatchMouseEvent',
                     params={'type': kind, 'x': rect[0], 'y': rect[1], 'button': 'left', 'clickCount': 1,
                             'modifiers': modifiers})

    def open_popup(app, tab):
        before = {p['identifier'] for p in pages(app)}
        button_click(app, tab, '#open')
        popup = wait_until(lambda: next((p for p in pages(app) if p['kind'] == 'popup' and p['identifier'] not in before
                                         and p['url'].endswith('/popup') and not p['loading']), None), timeout=10, step=.1)
        assert popup, pages(app)
        return popup

    def visible_windows(app):
        return {w['number']: w for w in app.call('windows') if w.get('visible')}

    # OE-05: a closed page keeps its engine identifier. The `.live` change that reports the close
    # (after Chromium destroyed the browser) named page 0 before, so the shell could not match
    # it (pendingLittleOpenExtensionTabs kept such pages until Little Open closed). A popup panel
    # keeps the factory as its delegate up to that change, so the factory's own page event shows
    # the identifier it received. (The save-prompt half of the seed is a false positive: the
    # host closes before Chromium does; see M-3-page-close-ignored.)
    def oe05():
        app = launch(urls=(origin + '/opener',))
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        popup = open_popup(app, tab)
        app.call('events')
        app.call('close', tab=popup['identifier'])
        closed = wait_until(lambda: not any(p['identifier'] == popup['identifier'] for p in pages(app)), timeout=8, step=.1)
        time.sleep(.5)
        changes = [e for e in app.call('events') if e.get('type') == 'change' and int(e.get('changes', 0)) & (1 << 12)]
        row('eng6_oe05_closed_page_keeps_identifier',
            bool(closed) and bool(changes) and all(e.get('content') == popup['identifier'] for e in changes),
            popup=popup['identifier'], liveChanges=[e.get('content') for e in changes])
    guarded('eng6_oe05_closed_page_keeps_identifier', oe05)

    # OE-13: AppleScript "set URL" on a tab that wakes from stored history (no host yet after a
    # relaunch) loads the new URL. Before, the load arrived before browser creation and the
    # history restore replaced it.
    def oe13():
        app = launch(urls=(origin + '/a',))
        home = app.call('tabs')[0]['id']
        app.call('wait', tab=home)
        slept = h.new_tab(app, origin + '/a')
        app.call('navigate', tab=slept, url=origin + '/b')
        assert wait_until(lambda: app.eval(slept, 'location.pathname') == '/b' or None, timeout=10, step=.05)
        app.call('wait', tab=slept)
        app.call('select', tab=home)
        app.call('save')
        app.quit()
        app = launch(urls=(), fresh=False)
        assert wait_until(lambda: app.call('tabs'), timeout=10)
        app.call('wait', tab=home)
        stored = wait_until(lambda: {r['tab']: r for r in app.call('sleep-store')}.get(slept), timeout=10, step=.2)
        before = app.tab(slept)
        reply = app.call('applescript', body='set URL of tab id %s of window 1 to %s' % (quote(slept), quote(origin + '/target')))
        path = wait_until(lambda: (lambda p: p if p == '/target' else None)(
            _try(lambda: app.call('eval', tab=slept, js='location.pathname'))), timeout=10, step=.1)
        final = _try(lambda: app.call('eval', tab=slept, js='location.pathname'))
        after = _try(lambda: app.tab(slept))
        row('eng6_oe13_applescript_url_on_restored_tab',
            bool(stored) and not before.get('loaded') and reply.get('number') == 0 and path == '/target',
            storedRow=bool(stored), loadedBefore=before.get('loaded'), reply=reply, finalPath=final,
            tabAfter={k: (after or {}).get(k) for k in ('url', 'loaded', 'title')})
    guarded('eng6_oe13_applescript_url_on_restored_tab', oe13)

    # OE-09: a target=_blank link in a popup panel of Profile B opens a tab in a Space of
    # Profile B, also after the main window switched to a Space of another Profile. Before,
    # the request was dropped (no source tab, focused Space of the wrong Profile).
    def oe09():
        app = launch(urls=(origin + '/a',))
        home_space = next(s for s in app.call('spaces') if s['focused'])
        other = app.call('space-create', title='ENG6 Other', profile='ENG6 Other')
        other_id = other['id'] if isinstance(other, dict) else other
        app.call('space', space=other_id)
        opener = h.new_tab(app, origin + '/opener')
        opener_page = app.page(opener)
        popup = open_popup(app, opener)
        app.call('space', space=home_space['id'])
        assert wait_until(lambda: next(s for s in app.call('spaces') if s['id'] == home_space['id'])['focused'], timeout=5, step=.05)
        before = {t['id'] for t in app.call('tabs')}
        button_click(app, popup['identifier'], '#blank')
        opened = wait_until(lambda: [t for t in app.call('tabs') if t['id'] not in before and t['url'].endswith('/from-popup')],
                            timeout=8, step=.1)
        space_of = {}
        if opened:
            space_of = next((s for s in app.call('spaces') if s['focused']), {})
        row('eng6_oe09_popup_link_after_profile_switch',
            bool(opened) and popup['context'] == opener_page.get('context') and space_of.get('id') == other_id,
            popup=popup['context'], openerContext=opener_page.get('context'), opened=opened, focusedSpace=space_of.get('id'),
            otherSpace=other_id)
    guarded('eng6_oe09_popup_link_after_profile_switch', oe09)

    # OE-07: deleting a Profile closes its popup panels. Before, the engine closed the popup's
    # page and its panel stayed on screen, blank.
    def oe07():
        app = launch(urls=(origin + '/a',))
        confirm_key = 'open.profiles.confirmInterProfileMove'
        saved = app.call('defaults', key=confirm_key)
        try:
            app.call('defaults', key=confirm_key, value=False)
            home = next(s for s in app.call('spaces') if s['focused'])
            victim_space = app.call('space-create', title='ENG6 Victim', profile='ENG6 Victim')
            victim_id = victim_space['id'] if isinstance(victim_space, dict) else victim_space
            app.call('space', space=victim_id)
            opener = h.new_tab(app, origin + '/opener')
            popup = open_popup(app, opener)
            panel = wait_until(lambda: next((n for n, w in visible_windows(app).items() if w.get('title') == 'ENG6 Popup'), None),
                               timeout=5, step=.1)
            # The Space leaves the Profile (as in profiles_shell): only the popup still uses it.
            app.call('space-profile', space=victim_id, profile='Default')
            app.call('space', space=home['id'])
            assert popup['identifier'] in {p['identifier'] for p in pages(app)}
            victim = next(p for p in app.call('profiles-shell')['profiles'] if p['name'] == 'ENG6 Victim')
            app.call('profiles-shell', action='show', profile='ENG6 Victim')
            time.sleep(.15)
            app.press_profile_delete()
            assert wait_until(lambda: app.call('profiles-shell')['sheet'] > 0, timeout=5, step=.05)
            app.call('profiles-shell', action='type-delete', text='ENG6 Victim')
            app.call('profiles-shell', action='press', label='Delete')
            done = wait_until(lambda: (lambda s: s if not s['deleting'] and all(p['name'] != 'ENG6 Victim' for p in s['profiles'])
                                       else None)(app.call('profiles-shell')), timeout=20, step=.1)
            gone = all(p['name'] != 'ENG6 Victim' for p in app.call('profiles-shell')['profiles'])
            hidden = wait_until(lambda: panel not in visible_windows(app), timeout=5, step=.1)
            popups = [{k: p.get(k) for k in ('identifier', 'kind', 'live', 'url')} for p in pages(app) if p['kind'] == 'popup']
            row('eng6_oe07_profile_delete_closes_popup_panel', bool(done) and gone and panel is not None and bool(hidden) and not popups,
                deleteFinished=bool(done), shell={k: v for k, v in app.call('profiles-shell').items() if k in ('deleting', 'sheet', 'error')},
                deleted=gone, panel=panel, panelStillVisible=not hidden, popupsLeft=popups, victim=victim['id'],
                visible=[w.get('title') for w in visible_windows(app).values()])
        finally:
            _try(lambda: app.call('defaults', key=confirm_key, value=saved))
    guarded('eng6_oe07_profile_delete_closes_popup_panel', oe07)

    # OE-12: a middle click after a Command-Option click opens a background tab. The middle click
    # goes through OEApplication.sendEvent (automation `mouse` with button=middle) like real
    # input. Before, the earlier click's Command-Option stayed recorded and the middle-clicked
    # link went to Little Open.
    def oe12():
        app = launch(urls=(origin + '/biglink',))
        app.call('window-frame', frame=[80, 60, 1280, 820])
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        ws = app.call('window-state')
        app.call('window-focus', id=ws['id'], activate=True)
        frame = ws['frame']
        point = dict(x=frame[2] - 300, y=frame[3] / 2)

        def sessions(): return app.call('little-open-state')['sessions']
        app.call('mouse', action='click', modifiers=['command', 'option'], **point)
        little = wait_until(lambda: sessions(), timeout=8, step=.1)
        if little:
            app.call('window-focus', id=ws['id'], activate=True)
        before = {t['id'] for t in app.call('tabs')}
        little_before = len(sessions())
        app.call('mouse', action='click', button='middle', **point)
        opened = wait_until(lambda: [t for t in app.call('tabs') if t['id'] not in before and t['url'].endswith('/target')],
                            timeout=8, step=.1)
        aux = _try(lambda: app.eval(tab, 'window.aux'))
        row('eng6_oe12_middle_click_after_cmd_option_click',
            bool(little) and bool(opened) and len(sessions()) == little_before and aux == [1],
            littleOpenAfterCmdOption=bool(little), opened=opened, littleSessions=[little_before, len(sessions())], auxButtons=aux)
    guarded('eng6_oe12_middle_click_after_cmd_option_click', oe12)

    # Quit with DevTools, a popup panel and an Incognito window open, right after a metrics
    # sample (OE-01, OE-04, OE-06 shutdown paths): the quit finishes before the three-second
    # deadline, kills every owned process and leaves no crash report.
    def quit_open_tools():
        app = launch(urls=(origin + '/opener',))
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        popup = open_popup(app, tab)
        # The popup panel is key now; window commands validate against the key window.
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        app.call('select', tab=tab)
        app.call('command', id='javascript-console')
        devtools = wait_until(lambda: _try(lambda: app.call('devtools-frontend', tab=tab, js='1')) == 1, timeout=20, step=.5)
        app.call('menu-perform', id='new-incognito-window')
        private = wait_until(lambda: next((w for w in app.call('incognito-state')['windows'] if w.get('private')), None),
                             timeout=8, step=.1)
        sample = app.call('metrics', interval=0.5)
        reports = os.path.expanduser('~/Library/Logs/DiagnosticReports')
        started = time.time()
        app.quit()
        crashes = [f for f in (os.listdir(reports) if os.path.isdir(reports) else [])
                   if f.startswith('Open') and os.path.getmtime(os.path.join(reports, f)) >= started - 1]
        log = open(app.launch_log_path, errors='replace').read() if os.path.exists(app.launch_log_path) else ''
        shutdown = [line for line in log.splitlines() if 'OpenEngine: shutdown contexts=' in line]
        report = app.quit_report
        row('eng6_quit_with_devtools_popup_incognito_open',
            bool(devtools) and bool(popup) and bool(private) and len(sample.get('tasks', [])) > 0
            and report.get('ok') is True and not report.get('forced') and not crashes
            and len(shutdown) == 1 and 'deadline=0' in shutdown[0],
            devtools=bool(devtools), incognito=bool(private), metricsTasks=len(sample.get('tasks', [])),
            quit={k: report.get(k) for k in ('ok', 'forced', 'error')}, crashReports=crashes, shutdown=shutdown)
    guarded('eng6_quit_with_devtools_popup_incognito_open', quit_open_tools)

    server.shutdown()
    server.server_close()


def _try(fn):
    try:
        return fn()
    except Exception:
        return None
