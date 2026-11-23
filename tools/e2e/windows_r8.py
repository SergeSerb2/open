"""Bug sweep round 8, lane REGR8A: windows, Little Open and Profile rows through the real App
automation socket (no desktop input).

Runs inside `engine_e2e.py --only split`; OPEN_SPLIT_WIN8_ONLY=1 runs only these rows, and
OPEN_WIN8_ROWS=name[,name] a subset. Loopback pages only; every other host resolves to nothing,
so no row reaches a real service.
"""
import http.server
import json
import os
import threading
import time
import traceback
from loopback_http import LoopbackHTTPServer

ENGINE_SWITCHES = ['--host-resolver-rules=MAP *.localhost 127.0.0.1, MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1',
                   '--no-proxy-server']
ARM = '<button id=arm onclick="onbeforeunload=e=>{e.preventDefault();e.returnValue=1}">Arm</button>'
POP = '<button id=pop onclick="window.open(\'/w8popup\', \'w8\', \'width=420,height=360\')">Pop</button>'


def _server():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split('?')[0]
            body = ('<!doctype html><title>Win8 %s</title><body style="background:#fff">%s %s Win8 %s'
                    % (path, ARM, POP, path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers()
            try: self.wfile.write(body)
            except OSError: pass
        def log_message(self, *args): pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def run(factory, results, tmp, h):
    wait_until = h.wait_until
    server, port = _server()

    def url(host='a', path='/page'): return 'http://%s.localhost:%d%s' % (host, port, path)

    app = factory(urls=(url('start', '/start'),), fresh=True, extra_args=ENGINE_SWITCHES)

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('win8 %-50s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
        if not ok: print('  ' + json.dumps(evidence, default=str)[:1500], flush=True)

    only = set(filter(None, os.environ.get('OPEN_WIN8_ROWS', '').split(',')))
    main_window = []

    def focus_main():
        if main_window: app.call('window-focus', id=main_window[0], activate=True)
        wait_until(lambda: app.call('window-state').get('isKeyWindow') or None, timeout=3, step=.05)

    def guarded(name, body, cleanup=None):
        if only and name not in only: return
        try:
            focus_main()
            body()
        except Exception as error:  # A failed setup is a FAIL row, never a skipped one.
            if isinstance(error, getattr(h, 'FocusInterruption', ())): raise
            row(name, False, error=repr(error), trace=traceback.format_exc()[-1200:])
        finally:
            try:
                answer_dialogs()
                if cleanup: cleanup()
            except Exception as error:
                print('win8 cleanup after %s: %r' % (name, error), flush=True)

    def sessions(): return app.call('little-open-state')['sessions']
    def session_by_id(sid): return next((s for s in sessions() if s['id'] == sid), None)
    def windows(): return app.call('shell-windows')
    def shell(**kw): return app.call('profiles-shell', **kw)
    def profile_named(name): return next((p for p in shell()['profiles'] if p['name'] == name), None)

    def answer_dialogs():
        # A failed row must not leave a beforeunload sheet on screen (review checklist 4).
        for s in sessions():
            for _ in range(3):
                try:
                    if not app.call('dialog-state', window=s['window']).get('pending'): break
                    app.call('dialog-button', window=s['window'], accept=True)
                except Exception: break

    def close_little_opens():
        for s in sessions():
            try: app.call('little-open-eval', id=s['id'], js='onbeforeunload=null;true')
            except Exception: pass
            app.call('little-open-action', id=s['id'], action='close')
        wait_until(lambda: not sessions() or None, timeout=8, step=.1)

    def little_open_page(host, path):
        """A new Little Open window (the front window's Profile) on a loaded loopback page."""
        before = {s['id'] for s in sessions()}
        app.call('little-open-action', action='blank')
        session = next(s for s in sessions() if s['id'] not in before)
        app.call('key', window=session['window'], text=url(host, path) + '\r')
        assert wait_until(lambda: (lambda s: s and s['state'] == 'page' and s['content'] and not s['loading'])(session_by_id(session['id'])),
                          timeout=12), session_by_id(session['id'])
        return session_by_id(session['id'])

    def arm(session):
        app.call('click', window=session['window'], tab=session['content'], selector='#arm')
        assert wait_until(lambda: app.call('engine-sleep', window=session['window'], tab=session['content'])['unloadHandlers'],
                          timeout=3), 'beforeunload not armed'

    def popups():
        return [p for p in app.call('pages') if p.get('kind') == 'popup']

    try:
        start = app.call('tabs')[0]['id']
        app.call('wait', tab=start)
        app.call('window-frame', frame=[60, 60, 1280, 820], unconstrained=True)
        for key in ('open.links.littleOpenNUXSeen',):
            app.call('defaults', key=key, value=True)
        main_window.append(app.call('window-state')['id'])
        home = next(s for s in app.call('spaces') if s['focused'])

        # A-R6-06 / B-R6-02 (LEAD ruling): Undo of New Profile closes that Profile's windows as Profile
        # delete does, with no "Leave site?" Stay: its Little Open window (beforeunload armed) and the
        # popup panel a page of the Profile opened both close.
        def undo_profile_windows():
            app.call('space', space=home['id']); app.call('select', tab=start)
            app.call('undo-state', clear=True)
            shell(action='create', name='W8 Undo', spaces=[home['id']])
            created = profile_named('W8 Undo')
            assert created, shell()['profiles']
            shell(action='cancel')
            focus_main()
            app.call('navigate', tab=start, url=url('w8undo', '/w8undo')); app.call('wait', tab=start)
            app.call('click', tab=start, selector='#pop')
            popup = wait_until(lambda: popups() or None, timeout=8, step=.1) or []
            focus_main()
            session = little_open_page('w8lo', '/w8lo')
            arm(session)
            focus_main()
            for _ in range(4):
                if profile_named('W8 Undo') is None: break
                try: app.call('menu-perform', id='reveal-tab-in-sidebar')
                except RuntimeError: pass
                app.call('menu-perform', id='undo'); time.sleep(.3)
            removed = profile_named('W8 Undo') is None
            gone = wait_until(lambda: session_by_id(session['id']) is None or None, timeout=5, step=.1)
            dialog = app.call('dialog-state', window=session['window']) if session_by_id(session['id']) else {}
            popup_gone = wait_until(lambda: not popups() or None, timeout=5, step=.1)
            row('win8_undo_profile_closes_little_open_and_popups', created['id'] == session['profile'] and bool(popup)
                and removed and bool(gone) and bool(popup_gone),
                profile=created['id'], littleOpenProfile=session['profile'], popupOpened=bool(popup), removed=removed,
                littleOpenClosed=bool(gone), dialog={k: dialog.get(k) for k in ('visible', 'pending', 'title')},
                popupsLeft=[p.get('url') for p in popups()])
        def undo_cleanup():
            answer_dialogs(); close_little_opens()
            for p in popups():
                try: app.call('eval', tab=p['identifier'], js='window.close();true')
                except Exception: pass
        guarded('win8_undo_profile_closes_little_open_and_popups', undo_profile_windows, undo_cleanup)

        # B-R6-06: switching Little Open's Profile reloads its page in another Profile: the page's
        # beforeunload runs first. Stay keeps the page and the Profile; Leave switches.
        def switch_profile_asks():
            focus_main()
            other_space = app.call('space-create', title='W8 Other', profile='W8 Other')
            other = next(s['profile'] for s in app.call('spaces') if s['id'] == other_space)
            app.call('space', space=home['id'])
            app.call('defaults', key='open.links.littleOpenProfileSwitchConfirmed', value=True)
            session = little_open_page('w8sw', '/w8sw')
            before_profile = session['profile']
            arm(session)
            app.call('little-open-action', id=session['id'], action='switch-profile', profile=other)
            prompted = wait_until(lambda: app.call('dialog-state', window=session['window']).get('visible') or None, timeout=4, step=.05)
            if prompted:
                app.call('dialog-button', window=session['window'], accept=False)
                wait_until(lambda: not app.call('dialog-state', window=session['window']).get('pending') or None, timeout=3, step=.05)
            time.sleep(.5)
            stayed = session_by_id(session['id']) or {}
            kept = stayed.get('profile') == before_profile and stayed.get('content') == session['content']
            app.call('little-open-action', id=session['id'], action='switch-profile', profile=other)
            again = wait_until(lambda: app.call('dialog-state', window=session['window']).get('visible') or None, timeout=4, step=.05)
            if again: app.call('dialog-button', window=session['window'], accept=True)
            switched = wait_until(lambda: (session_by_id(session['id']) or {}).get('profile') == other or None, timeout=5, step=.05)
            row('win8_little_open_switch_profile_asks_beforeunload', bool(prompted) and kept and bool(again) and bool(switched),
                prompted=bool(prompted), kept=kept, profileAfterStay=stayed.get('profile'), before=before_profile,
                promptedAgain=bool(again), switched=bool(switched), other=other)
        def switch_cleanup():
            app.call('defaults', key='open.links.littleOpenProfileSwitchConfirmed', value=None)
            answer_dialogs(); close_little_opens()
            focus_main(); app.call('space', space=home['id'])
        guarded('win8_little_open_switch_profile_asks_beforeunload', switch_profile_asks, switch_cleanup)

        # A-R6-07: Extensions ▸ Manage Extensions from Little Open opens in the frontmost standard
        # window of its Profile (it took the oldest one by creation order, or a Blank Window).
        def manage_extensions_target():
            focus_main(); app.call('space', space=home['id'])
            app.call('command', id='new-window')
            assert wait_until(lambda: len(windows()) == 2 or None, timeout=5, step=.05), windows()
            second = next(w for w in windows() if w['id'] != main_window[0])
            app.call('window-focus', id=second['id'], activate=True)
            app.call('key', key='escape', route='app')
            # A Blank Window of the same Profile in front (its stand-in Profile shares the id): never the target.
            app.call('menu-perform', id='blank-window')
            assert wait_until(lambda: len(windows()) == 3 or None, timeout=5, step=.05), windows()
            blank = next(w for w in windows() if w['id'] not in (main_window[0], second['id']))
            app.call('key', key='escape', route='app')
            session = little_open_page('w8ext', '/w8ext')
            app.call('little-open-action', id=session['id'], action='focus')
            app.call('menu-perform', id='manage-extensions')
            # Both windows show the same Space (its tabs are the model's): the window the command
            # brought forward, with the new page selected, is the one it used.
            def ext_window():
                state = app.call('window-state')
                page = next((t for t in app.call('tabs') if t['id'] == state.get('selected')), {})
                return state['id'] if page.get('url', '').startswith('chrome://extensions') else None
            target = wait_until(ext_window, timeout=6, step=.1)
            row('win8_little_open_manage_extensions_front_window', target == second['id'],
                target=target, front=second['id'], oldest=main_window[0], blank=blank['id'], keyWindow=app.call('window-state')['id'])
        def ext_cleanup():
            close_little_opens()
            for w in windows():
                if w['id'] != main_window[0]:
                    app.call('window-focus', id=w['id']); app.call('window-close')
            wait_until(lambda: len(windows()) == 1 or None, timeout=5, step=.05)
            focus_main()
            for t in app.call('tabs'):
                if t['url'].startswith('chrome://extensions'): app.call('close', tab=t['id'])
        guarded('win8_little_open_manage_extensions_front_window', manage_extensions_target, ext_cleanup)

        # A-R6-05: the auto-archive banner's "Profile Settings" link opens Settings ▸ Tabs & Archive
        # without the search-suggestion notice sheet (only the Search section shows it).
        def profile_settings_no_notice():
            focus_main(); app.call('space', space=home['id'])
            app.call('defaults', key='open.general.searchSuggestNoticeDismissed', value=None)
            app.call('archive-clock', reset=True)
            old = app.call('open', url=url('w8old', '/w8old'), background=True)['id']
            app.call('select', tab=start)
            activity = max(t['lastActiveAt'] for t in app.call('tabs') if t['id'] in (old, start))
            import datetime
            iso = datetime.datetime.fromtimestamp(activity + 13 * 3600, datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
            app.call('archive-sweep', now=iso)
            banner = wait_until(lambda: (lambda b: b if b['visible'] else None)(app.call('archive-banner-state')), timeout=3, step=.1) \
                or app.call('archive-banner-state')
            assert banner['visible'], banner
            app.call('archive-banner-action', action='settings')
            opened = wait_until(lambda: (lambda s: s if s.get('settings') else None)(shell()), timeout=5, step=.1) or shell()
            time.sleep(.6); opened = shell()
            row('win8_profile_settings_link_no_suggest_notice', bool(opened.get('settings')) and not opened.get('sheet'),
                settings=opened.get('settings'), sheet=opened.get('sheet'), sheetText=opened.get('sheetText', [])[:6],
                selected=opened.get('selectedProfile'))
        def notice_cleanup():
            try:
                if shell().get('sheet'): shell(action='press', label='OK')
            except Exception: pass
            try: shell(action='cancel')
            except Exception: pass
            app.call('archive-clock', reset=True)
            focus_main()
        guarded('win8_profile_settings_link_no_suggest_notice', profile_settings_no_notice, notice_cleanup)
    finally:
        try: app.quit()
        except Exception: pass
        server.shutdown()
