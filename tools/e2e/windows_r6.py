"""Bug sweep round 6, lane WIN6: windows, Split View, Peek and Little Open rows through the real
App automation socket (no desktop input).

Runs inside `engine_e2e.py --only split`; OPEN_SPLIT_WIN6_ONLY=1 runs only these rows.
Loopback pages only; every other host resolves to nothing, so no row reaches a real service.
"""
import http.server
import json
import os
import subprocess
import threading
import time
import traceback
from loopback_http import LoopbackHTTPServer

ENGINE_SWITCHES = ['--host-resolver-rules=MAP *.localhost 127.0.0.1, MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1',
                   '--no-proxy-server']
ARM = '<button id=arm onclick="onbeforeunload=e=>{e.preventDefault();e.returnValue=1}">Arm</button>'


def _server(LoopbackHTTPServer):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split('?')[0]
            if path.startswith('/slow'):
                time.sleep(6)
            body = ('<!doctype html><title>Win6 %s</title><body style="background:#fff">%s Win6 %s'
                    % (path, ARM, path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers()
            try: self.wfile.write(body)
            except OSError: pass
        def log_message(self, *args): pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def run(factory, results, tmp, h):
    wait_until = h.wait_until
    server, port = _server(LoopbackHTTPServer)

    def url(host='a', path='/page'): return 'http://%s.localhost:%d%s' % (host, port, path)

    app = factory(urls=(url('start', '/start'),), fresh=True, extra_args=ENGINE_SWITCHES)

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('win6 %-44s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
        if not ok: print('  ' + json.dumps(evidence, default=str)[:1500], flush=True)

    only = set(filter(None, os.environ.get('OPEN_WIN6_ROWS', '').split(',')))
    def guarded(name, body, cleanup=None):
        if only and name not in only: return
        try:
            body()
        except Exception as error:  # A failed setup is a FAIL row, never a skipped one.
            if isinstance(error, getattr(h, 'FocusInterruption', ())): raise
            row(name, False, error=repr(error), trace=traceback.format_exc()[-1200:])
        finally:
            try:
                if cleanup: cleanup()
            except Exception as error:
                print('win6 cleanup after %s: %r' % (name, error), flush=True)

    def tabs(): return app.call('tabs')
    def selected(): return next((t['id'] for t in tabs() if t.get('selected')), None)
    def peek(): return app.call('peek-state')
    def motion(): return app.call('peek-motion')
    def split(): return app.call('split', op='state')
    def windows(): return app.call('shell-windows')

    def opened():
        assert wait_until(lambda: (lambda s: s['shown'] and s['stack'] and s['stack'][-1]['content'] > 0)(peek()), timeout=6, step=.05), peek()

    def new_tab(target):
        tid = app.call('open', url=target)['id']
        app.call('wait', tab=tid)
        return tid

    def answer_dialogs():
        # A failed row must not leave a beforeunload sheet on screen (review checklist 4).
        for w in [None] + [s['window'] for s in app.call('little-open-state')['sessions']]:
            args = {'window': w} if w else {}
            for _ in range(3):
                try:
                    if not app.call('dialog-state', **args).get('pending'): break
                    app.call('dialog-button', accept=True, **args)
                except Exception: break

    def reset_peek():
        app.call('peek-close')
        wait_until(lambda: not peek()['stack'], timeout=3, step=.05)

    def unsplit():
        s = split()
        if s['id']:
            app.call('split', op='menu', item='Separate All Tabs')
            wait_until(lambda: not split()['id'], timeout=3, step=.05)

    try:
        start = app.call('tabs')[0]['id']
        app.call('wait', tab=start)
        app.call('window-frame', frame=[60, 60, 1280, 820], unconstrained=True)
        for key in ('open.links.littleOpenNUXSeen',):
            app.call('defaults', key=key, value=True)
        reduced = app.call('window-motion')['reduced']
        main_window = app.call('window-state')['id']

        # WL-03: sidebar multi-select "Open in Split View" shows the split it made (the selection
        # moves from the absorbed tab to the split), not the first tab alone.
        def multi_select_split():
            a = new_tab(url('a')); b = new_tab(url('b'))
            app.call('sidebar-click', node=a); app.call('sidebar-click', node=b, modifiers=['cmd'])
            app.call('sidebar-menu', node=b, item='Open in Split View')
            s = wait_until(lambda: (lambda v: v if v['id'] else None)(split()), timeout=3, step=.05) or split()
            row('win6_multiselect_split_is_shown', bool(s['id']) and len(s['panes']) == 2 and s['selected'] == s['id'],
                state={k: s[k] for k in ('id', 'selected', 'focused')}, panes=[p['id'] for p in s['panes']])
        guarded('win6_multiselect_split_is_shown', multi_select_split, unsplit)

        # WL-10: Add Split View is one Undo step: one Cmd+Z leaves no split and no blank pane tab.
        def add_split_one_undo():
            a = new_tab(url('undo'))
            app.call('select', tab=a)
            before = [t['id'] for t in tabs()]
            app.call('key', key='=', modifiers=['ctrl', 'shift'], route='app')
            made = wait_until(lambda: (lambda v: v if v['id'] and len(v['panes']) == 2 else None)(split()), timeout=3, step=.05)
            assert made, split()
            time.sleep(.4)
            app.call('sidebar-key', key='z', modifiers=['cmd'])
            time.sleep(.6)
            after = split(); ids = [t['id'] for t in tabs()]
            row('win6_add_split_single_undo', not after['id'] and sorted(ids) == sorted(before) and selected() == a,
                made=made['id'], after=after['id'], tabsBefore=len(before), tabsAfter=len(ids), selected=selected())
        guarded('win6_add_split_single_undo', add_split_one_undo, unsplit)

        # WL-02: "Open in Split View" on a closing nested Peek must not wedge the Peek under it.
        def split_during_dismiss():
            source = new_tab(url('psrc'))
            app.call('select', tab=source)
            app.call('peek-open', tab=source, url=url('pa')); opened()
            lower = peek()['stack'][-1]['content']; app.call('wait', tab=lower)
            app.call('peek-open', tab=source, url=url('pb'))
            assert wait_until(lambda: len(peek()['stack']) == 2 and peek()['stack'][-1]['content'] > 0, timeout=6, step=.05), peek()
            app.call('wait', tab=peek()['stack'][-1]['content'])
            app.call('peek-button', id='confirmCloseModal')
            try: app.call('peek-button', id='openInSplit')
            except Exception as error: print('win6 split during dismiss refused: %r' % (error,), flush=True)
            time.sleep(1)
            unsplit(); app.call('select', tab=source)
            left = peek()['stack']
            if left:
                app.call('peek-button', id='confirmCloseModal')
            closed = wait_until(lambda: not peek()['stack'], timeout=5, step=.05)
            row('win6_peek_split_while_closing_keeps_close', bool(closed) and not reduced, reduced=reduced, left=len(left), stack=peek()['stack'])
        guarded('win6_peek_split_while_closing_keeps_close', split_during_dismiss, lambda: (reset_peek(), unsplit()))

        # WL-01: a promoted Peek whose new tab closes while it loads ends the expansion overlay.
        def promotion_tab_closed():
            source = new_tab(url('hsrc'))
            app.call('select', tab=source)
            app.call('peek-open', tab=source, url=url('ha')); opened()
            page = peek()['stack'][-1]['content']; app.call('wait', tab=page)
            app.call('eval', tab=page, js='setTimeout(()=>location.href="/slow",10);true')
            time.sleep(.3)
            app.call('peek-expand')
            handoff = wait_until(lambda: motion().get('promotionHandoff'), timeout=4, step=.02)
            promoted = selected()
            assert promoted and promoted != source, tabs()
            app.call('close', tab=promoted)
            ended = wait_until(lambda: (lambda m: m if not m.get('promotionHandoff') and not m.get('expandedImage') else None)(motion()), timeout=4, step=.05)
            row('win6_peek_promotion_ends_when_tab_closes', bool(handoff) and bool(ended),
                sawHandoff=bool(handoff), motion={k: motion().get(k) for k in ('promotionHandoff', 'expandedImage', 'overlayHidden', 'kind')})
        guarded('win6_peek_promotion_ends_when_tab_closes', promotion_tab_closed, reset_peek)

        # WL-05: closing a Peek's source tab closes the Peek and its page.
        def source_closed():
            other = new_tab(url('other'))
            source = new_tab(url('srcgone'))
            app.call('select', tab=source)
            app.call('peek-open', tab=source, url=url('orphan')); opened()
            page = peek()['stack'][-1]['content']; app.call('wait', tab=page)
            app.call('select', tab=other)
            app.call('close', tab=source)
            pruned = wait_until(lambda: not peek()['stack'], timeout=3, step=.05)
            alive = page in [p['identifier'] for p in app.call('pages')]
            row('win6_peek_closes_with_its_source_tab', bool(pruned) and not alive, stack=peek()['stack'], pageAlive=alive)
        guarded('win6_peek_closes_with_its_source_tab', source_closed, reset_peek)

        # WL-09: focusing a minimized window (Window menu, Little Open promote) and reopening from the Dock show it.
        def deminiaturize():
            for how in ('focus', 'reopen'):
                app.call('window-miniaturize')
                assert wait_until(lambda: app.call('window-state')['miniaturized'], timeout=5, step=.1)
                if how == 'focus': app.call('window-focus', id=main_window, activate=True)
                else: app.call('window-reopen')
                shown = wait_until(lambda: not app.call('window-state')['miniaturized'], timeout=4, step=.1)
                if not shown:
                    app.call('window-deminiaturize'); wait_until(lambda: not app.call('window-state')['miniaturized'], timeout=5, step=.1)
                row('win6_minimized_window_%s_shows_it' % how, bool(shown), windows=len(windows()))
        guarded('win6_minimized_window_focus_shows_it', deminiaturize)

        # REG-01: a blank Little Open bar given an internal open:// address keeps its bar.
        def little_internal():
            before = {s['id'] for s in app.call('little-open-state')['sessions']}
            app.call('little-open-action', action='blank')
            session = next(s for s in app.call('little-open-state')['sessions'] if s['id'] not in before)
            app.call('key', window=session['window'], text='open://welcome\r')
            time.sleep(1.5)
            current = next(s for s in app.call('little-open-state')['sessions'] if s['id'] == session['id'])
            row('win6_little_open_internal_url_keeps_bar', current['state'] == 'bar' and current['barPresented'],
                state=current['state'], bar=current['barPresented'], input=current['barInput'])
            app.call('little-open-action', id=session['id'], action='close')
        guarded('win6_little_open_internal_url_keeps_bar', little_internal)

        # WL-08: Little Open "Open in Space" runs the page's beforeunload before it moves the page;
        # Stay keeps the window and adds no tab.
        def little_move_stay():
            before = {s['id'] for s in app.call('little-open-state')['sessions']}
            app.call('little-open-action', action='blank')
            session = next(s for s in app.call('little-open-state')['sessions'] if s['id'] not in before)
            target = url('lomove', '/lomove')
            app.call('key', window=session['window'], text=target + '\r')
            def current(): return next((s for s in app.call('little-open-state')['sessions'] if s['id'] == session['id']), None)
            assert wait_until(lambda: (lambda s: s and s['state'] == 'page' and s['content'] and not s['loading'])(current()), timeout=12), current()
            win = session['window']
            app.call('click', window=win, tab=current()['content'], selector='#arm')
            assert wait_until(lambda: app.call('engine-sleep', window=win, tab=current()['content'])['unloadHandlers'], timeout=3)
            tabs_before = len(tabs())
            app.call('key', window=win, key='o', modifiers=['cmd'])
            prompted = wait_until(lambda: app.call('dialog-state', window=win).get('visible'), timeout=4, step=.05)
            if prompted:
                app.call('dialog-button', window=win, accept=False)
                wait_until(lambda: not app.call('dialog-state', window=win).get('pending'), timeout=3, step=.05)
            time.sleep(.5)
            kept = current() is not None
            row('win6_little_open_move_stay_keeps_page', bool(prompted) and kept and len(tabs()) == tabs_before,
                prompted=bool(prompted), kept=kept, tabsBefore=tabs_before, tabsAfter=len(tabs()))
            if kept:
                # Leave: the page moves to the main window at its current URL, and the window closes.
                app.call('little-open-eval', id=session['id'], js='history.pushState({}, "", "/lomoved");true')
                app.call('key', window=win, key='o', modifiers=['cmd'])
                again = wait_until(lambda: app.call('dialog-state', window=win).get('visible'), timeout=4, step=.05)
                if again: app.call('dialog-button', window=win, accept=True)
                gone = wait_until(lambda: current() is None, timeout=5, step=.05)
                moved = wait_until(lambda: any(t['url'].endswith('/lomoved') and t.get('selected') for t in tabs()), timeout=5, step=.05)
                row('win6_little_open_move_leave_opens_in_space', bool(again) and bool(gone) and bool(moved),
                    prompted=bool(again), gone=bool(gone), urls=[t['url'] for t in tabs()][-3:])
            if current() is not None:
                try: app.call('little-open-eval', id=session['id'], js='onbeforeunload=null;true')
                except Exception: pass
                app.call('little-open-action', id=session['id'], action='close')
        guarded('win6_little_open_move_stay_keeps_page', little_move_stay, answer_dialogs)

        # REG-04: a Blank Window has no Pinned section: New Folder and New Space are not offered.
        def blank_folder():
            app.call('menu-perform', id='blank-window')
            assert wait_until(lambda: len(windows()) == 2, timeout=5, step=.05), windows()
            blank = next(w for w in windows() if w['id'] != main_window)
            app.call('window-focus', id=blank['id'])
            plus = {r['title']: r['enabled'] for r in app.call('split', op='plus') if r['title']}
            state_before = json.dumps(app.call('blank-window'), sort_keys=True)
            pinned_before = len(app.call('sidebar-tree').get('pinned', []))
            try: app.call('menu-perform', id='new-folder')
            except Exception as error: print('win6 blank new-folder refused: %r' % (error,), flush=True)
            state_after = json.dumps(app.call('blank-window'), sort_keys=True)
            pinned_after = len(app.call('sidebar-tree').get('pinned', []))
            row('win6_blank_window_no_hidden_folder', not plus.get('New Folder') and not plus.get('New Space')
                and state_before == state_after and pinned_before == pinned_after, plus=plus,
                changed=state_before != state_after, pinned=[pinned_before, pinned_after])
            app.call('window-close')
            wait_until(lambda: len(windows()) == 1, timeout=5, step=.05)
            app.call('window-focus', id=main_window)
        guarded('win6_blank_window_no_hidden_folder', blank_folder)

        # WL-04: closing a browser window runs beforeunload; Stay keeps the window.
        def window_close_unload():
            app.call('command', id='new-window')
            assert wait_until(lambda: len(windows()) == 2, timeout=5, step=.05), windows()
            second = next(w for w in windows() if w['id'] != main_window)
            app.call('window-focus', id=second['id'])
            app.call('key', key='escape', route='app')
            tid = new_tab(url('wclose', '/wclose'))
            app.call('click', tab=tid, selector='#arm')
            assert wait_until(lambda: app.call('engine-sleep', tab=tid)['unloadHandlers'], timeout=3)
            app.call('window-close')
            prompted = wait_until(lambda: app.call('dialog-state').get('visible'), timeout=4, step=.05)
            if prompted:
                app.call('dialog-button', accept=False)
                wait_until(lambda: not app.call('dialog-state').get('pending'), timeout=3, step=.05)
            time.sleep(.5)
            stayed = len(windows()) == 2
            row('win6_window_close_runs_beforeunload_stay', bool(prompted) and stayed, prompted=bool(prompted), windows=len(windows()))
            if stayed:
                app.call('window-focus', id=second['id'])
                app.call('window-close')
                again = wait_until(lambda: app.call('dialog-state').get('visible'), timeout=4, step=.05)
                if again: app.call('dialog-button', accept=True)
                gone = wait_until(lambda: len(windows()) == 1, timeout=5, step=.05)
                row('win6_window_close_runs_beforeunload_leave', bool(again) and bool(gone), prompted=bool(again), windows=len(windows()))
            app.call('window-focus', id=main_window)
        guarded('win6_window_close_runs_beforeunload_stay', window_close_unload, answer_dialogs)

        # WL-06: in native full screen, hiding the sidebar must not slide AppKit's title-bar buttons
        # off the screen edge.
        def fullscreen_lights():
            app.call('window-fullscreen')
            assert wait_until(lambda: (lambda s: s['fullscreen'] and not s['fullscreenTransition'])(app.call('window-state')), timeout=6, step=.1), app.call('window-state')
            app.call('key', key='s', modifiers=['cmd'], route='app')
            time.sleep(1.0)
            hidden = app.call('window-state')
            app.call('key', key='s', modifiers=['cmd'], route='app')
            time.sleep(1.0)
            row('win6_fullscreen_sidebar_keeps_title_bar_buttons', all(abs(x) < 0.5 for x in hidden['trafficLightOffsets']),
                offsets=hidden['trafficLightOffsets'], sidebar=hidden.get('sidebarMode'))
        def leave_fullscreen():
            if app.call('window-state')['fullscreen']:
                app.call('window-fullscreen')
                wait_until(lambda: (lambda s: not s['fullscreen'] and not s['fullscreenTransition'])(app.call('window-state')), timeout=6, step=.1)
        guarded('win6_fullscreen_sidebar_keeps_title_bar_buttons', fullscreen_lights, leave_fullscreen)

        # WL-07: a Little Open page in HTML fullscreen fills the window (no title bar or corners).
        def little_fullscreen():
            before = {s['id'] for s in app.call('little-open-state')['sessions']}
            app.call('little-open-action', action='blank')
            session = next(s for s in app.call('little-open-state')['sessions'] if s['id'] not in before)
            win = session['window']
            app.call('key', window=win, text=url('lofull', '/lofull') + '\r')
            def current(): return next((s for s in app.call('little-open-state')['sessions'] if s['id'] == session['id']), None)
            try:
                assert wait_until(lambda: (lambda s: s and s['state'] == 'page' and s['content'] and not s['loading'])(current()), timeout=12), current()
                request = app.call('eval', window=win, tab=current()['content'], js='document.documentElement.requestFullscreen().then(() => "ok", e => e.message)')
                full = wait_until(lambda: (lambda s: s if s['fullscreen'] and s['pageFullscreen'] else None)(current()), timeout=8, step=.1)
                time.sleep(.5); s = current()
                filled = abs(s['contentFrame'][3] - s['frame'][3]) <= 1 and s['titleBarHidden'] and s['cornerRadius'] == 0
                row('win6_little_open_page_fullscreen_fills_window', bool(full) and filled, request=request,
                    contentFrame=s['contentFrame'], frame=s['frame'], titleBarHidden=s['titleBarHidden'], corner=s['cornerRadius'])
                app.call('eval', window=win, tab=s['content'], js='document.exitFullscreen().then(() => "ok", e => e.message)')
                wait_until(lambda: (lambda s: s and not s['fullscreen'] and not s['pageFullscreen'])(current()), timeout=8, step=.1)
                time.sleep(.5); s = current()
                row('win6_little_open_page_fullscreen_restores_chrome', not s['titleBarHidden'] and s['cornerRadius'] > 0
                    and s['contentFrame'][3] < s['frame'][3] - 40, contentFrame=s['contentFrame'], frame=s['frame'], corner=s['cornerRadius'])
            finally:
                if current(): app.call('little-open-action', id=session['id'], action='close')
                wait_until(lambda: current() is None, timeout=8, step=.1)
        guarded('win6_little_open_page_fullscreen_fills_window', little_fullscreen)

        # WL-09 (parts 3 and 4): a minimized Little Open window comes back when resurfaced; an external
        # link with only a minimized browser window reuses it (no second window).
        def minimized_more():
            before = {s['id'] for s in app.call('little-open-state')['sessions']}
            app.call('little-open-action', action='blank')
            session = next(s for s in app.call('little-open-state')['sessions'] if s['id'] not in before)
            app.call('key', window=session['window'], text=url('lomin', '/lomin') + '\r')
            def current(): return next((s for s in app.call('little-open-state')['sessions'] if s['id'] == session['id']), None)
            assert wait_until(lambda: (lambda s: s and s['state'] == 'page')(current()), timeout=12), current()
            app.call('little-open-action', id=session['id'], action='miniaturize')
            assert wait_until(lambda: current()['miniaturized'], timeout=5, step=.1)
            app.call('little-open-action', id=session['id'], action='focus')
            shown = wait_until(lambda: not current()['miniaturized'], timeout=4, step=.1)
            row('win6_minimized_little_open_resurface_shows_it', bool(shown))
            app.call('little-open-action', id=session['id'], action='close')
            wait_until(lambda: current() is None, timeout=8, step=.1)
            app.call('routing-rules', hostEquals='extmin.localhost')
            app.call('window-focus', id=main_window)
            app.call('window-miniaturize')
            assert wait_until(lambda: app.call('window-state')['miniaturized'], timeout=5, step=.1)
            count = len(windows()); link = url('extmin', '/extmin')
            sent = subprocess.run(['/usr/bin/open', '-a', app.bundle, link], capture_output=True, text=True, timeout=15)
            landed = wait_until(lambda: any(t['url'] == link for t in tabs()), timeout=8, step=.1)
            time.sleep(.5)
            row('win6_external_link_reuses_minimized_window', sent.returncode == 0 and bool(landed) and len(windows()) == count,
                windowsBefore=count, windowsAfter=len(windows()), landed=bool(landed), stderr=sent.stderr[-300:])
            for extra in [w for w in windows() if w['id'] != main_window]:
                app.call('window-focus', id=extra['id']); app.call('window-close')
            app.call('window-focus', id=main_window, activate=True)
            if app.call('window-state')['miniaturized']: app.call('window-deminiaturize')
        guarded('win6_minimized_little_open_resurface_shows_it', minimized_more)

        # WL-11: New Little Open Window takes the Profile of the most recently focused window.
        def little_profile():
            app.call('command', id='new-window')
            assert wait_until(lambda: len(windows()) == 2, timeout=5, step=.05), windows()
            second = next(w for w in windows() if w['id'] != main_window)
            app.call('window-focus', id=second['id'])
            app.call('key', key='escape', route='app')
            space_b = app.call('space-create', title='Win6 Work', profile='Win6 Work')
            profile_b = next(s['profile'] for s in app.call('spaces') if s['id'] == space_b)
            app.call('window-focus', id=main_window); app.call('window-focus', id=second['id'])
            before = {s['id'] for s in app.call('little-open-state')['sessions']}
            app.call('little-open-action', action='blank')
            session = next(s for s in app.call('little-open-state')['sessions'] if s['id'] not in before)
            row('win6_little_open_new_window_front_profile', session['profile'] == profile_b, got=session['profile'], expected=profile_b)
            app.call('little-open-action', id=session['id'], action='close')
            app.call('window-focus', id=second['id']); app.call('window-close')
            wait_until(lambda: len(windows()) == 1, timeout=5, step=.05)
            app.call('window-focus', id=main_window)
        guarded('win6_little_open_new_window_front_profile', little_profile)
    finally:
        server.shutdown()
