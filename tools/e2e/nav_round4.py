"""Bug sweep round 4, lane NAV4: command bar, Peek, Library, Blank Window, Little Open, Handoff and
Meet-route rows through the real App automation socket (keys go through the App route).

Runs inside `engine_e2e.py --only commandbar`; OPEN_COMMANDBAR_NAV4_ONLY=1 runs only these rows.
Loopback pages only; every other host resolves to nothing, so no row reaches a real service.
"""
import json
import subprocess
import time

ENGINE_SWITCHES = ['--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1', '--no-proxy-server']
MEET = 'https://meet.google.com/abc-defg-hij'
MEET_DONE = 'open.links.didSetDefaultMeetRoute'


def run(factory, results, tmp, h):
    wait_until = h.wait_until
    server, origin = h._fixture_server('Nav4')
    app = factory(urls=(origin + '/start',), fresh=True, extra_args=ENGINE_SWITCHES)

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('nav4 %-40s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def state(): return app.call('commandbar-state')

    def bar(key):
        app.call('key', key=key, modifiers=['cmd'], route='app')
        assert wait_until(lambda: state().get('presented'), timeout=3, step=.05), state()
        return state()

    def type_query(text):
        app.call('key', text=text)
        return wait_until(lambda: (lambda s: s if s.get('text') == text and s.get('final') else None)(state()), timeout=5, step=.05) or state()

    def close_bar():
        if not app.call('shell-windows'): return
        if state().get('presented'):
            app.call('key', key='escape', route='app')
            wait_until(lambda: not state().get('presented'), timeout=3, step=.05)

    def spaces(): return app.call('spaces')

    def history_urls(): return [r['url'] for r in app.call('history-state')['rows']]

    def guarded(name, body, cleanup=None):
        try:
            body()
        except Exception as error:  # A failed setup is a FAIL row, never a skipped one.
            row(name, False, error=repr(error))
        finally:
            try:
                close_bar()
                if cleanup: cleanup()
            except Exception as error:
                print('nav4 cleanup after %s: %r' % (name, error), flush=True)

    meet_saved = None
    try:
        start = app.call('tabs')[0]['id']
        app.call('wait', tab=start)
        app.call('suggest-remote', enabled=False)
        wait_until(lambda: app.call('hotkey-state')['prepared'], timeout=5, step=.02)
        space_a = next(s for s in spaces() if s['focused'])
        profile_a = space_a['profile']

        # F-07: a Top Domains row draws "<name> — <domain>" (capture PB1-i), not "<domain> — <domain>".
        def top_domain():
            bar('t')
            typed = type_query('netfl')
            drawn = next((r for r in typed.get('drawn', []) if r['id'] == 'topDomain:netflix.com'), None)
            row('nav4_top_domain_drawn_title', drawn is not None and drawn['title'] == 'Netflix' and drawn['subtitle'] == 'netflix.com',
                drawn=typed.get('drawn'))
        guarded('nav4_top_domain_drawn_title', top_domain)

        # F-12: a punctuation-only query matches its own text, never the top history pages.
        def punctuation():
            for path in ('/alpha', '/beta'):
                h.new_tab(app, origin + path)
            assert wait_until(lambda: all(origin + p in history_urls() for p in ('/alpha', '/beta')), timeout=8, step=.1), history_urls()
            store_rows = app.call('history-state', query='---')['rows']
            bar('t')
            typed = type_query('---')
            history_rows = [r for r in typed.get('rows', []) if r['kind'] == 'history']
            row('nav4_punctuation_query_no_history', not history_rows and not store_rows,
                barHistory=[r['url'] for r in history_rows], storeRows=[r['url'] for r in store_rows])
        guarded('nav4_punctuation_query_no_history', punctuation)

        # F-10: cleared history never comes back through the bar's carry-over (the first, local snapshot).
        def carry_over():
            secret = origin + '/secret-carry'
            tab = h.new_tab(app, secret)
            assert wait_until(lambda: secret in history_urls(), timeout=8, step=.1), history_urls()
            app.call('navigate', tab=tab, url=origin + '/after-secret'); app.call('wait', tab=tab)
            bar('t')
            before = type_query('secret-carr')
            listed = any(r['url'] == secret and r['kind'] == 'history' for r in before.get('rows', []))
            cleared = app.call('history-clear')
            gone = wait_until(lambda: secret not in history_urls(), timeout=8, step=.1)
            # One more letter: the new query extends the last answered one, so carry-over applies.
            app.call('key', text='y')
            after = wait_until(lambda: (lambda s: s if s.get('text') == 'secret-carry' and s.get('final') else None)(state()), timeout=5, step=.05) or state()
            first = after.get('firstSnapshotURLs', [])
            row('nav4_cleared_history_not_carried', after.get('text') == 'secret-carry' and listed and not cleared.get('error') and bool(gone) and secret not in first
                and not any(r['url'] == secret for r in after.get('rows', [])),
                listedBefore=listed, firstSnapshot=first, rows=[r['url'] for r in after.get('rows', [])])
        guarded('nav4_cleared_history_not_carried', carry_over)

        # F-09: Cmd+L over a Peek on a Welcome tab navigates the Peek, not the Welcome tab behind it.
        def peek_over_welcome():
            welcome = app.call('open', url='open://welcome')['id']
            app.call('select', tab=welcome)
            app.call('peek-open', tab=welcome, url=origin + '/peek9')
            assert wait_until(lambda: (lambda s: s['shown'] and s['stack'] and s['stack'][-1]['content'] > 0)(app.call('peek-state')), timeout=6, step=.05)
            edited = bar('l')
            type_query(origin + '/peek9-next')
            app.call('key', key='return', route='app')
            target = origin + '/peek9-next'
            moved = wait_until(lambda: (lambda s: s['stack'] and s['stack'][-1]['url'] == target)(app.call('peek-state')), timeout=6, step=.05)
            tabs = app.call('tabs')
            still_welcome = any(t['id'] == welcome and t['url'] == 'open://welcome' for t in tabs)
            row('nav4_cmd_l_peek_over_welcome', edited.get('mode') == 'editCurrentURL' and bool(moved) and still_welcome
                and not any(t['url'] == target for t in tabs), seed=edited.get('text'), peek=app.call('peek-state'),
                tabs=[(t['id'], t['url']) for t in tabs])
        guarded('nav4_cmd_l_peek_over_welcome', peek_over_welcome, lambda: app.call('peek-close'))

        # F-01: Undo of a closed Peek after a switch to another Profile's Space keeps the Peek's Profile.
        space_b = app.call('space-create', title='Nav4 B', profile='Nav4 Profile B')
        profile_b = next(s['profile'] for s in spaces() if s['id'] == space_b)

        def peek_undo_profile():
            app.call('space', space=space_a['id'])
            app.call('select', tab=start)
            app.call('peek-open', tab=start, url=origin + '/peek-undo')
            assert wait_until(lambda: app.call('peek-state')['shown'], timeout=6, step=.05)
            opened_profile = app.call('peek-state')['stack'][-1]['profile']
            app.call('key', key='escape', route='app')
            assert wait_until(lambda: not app.call('peek-state')['stack'], timeout=5, step=.05)
            assert wait_until(lambda: any(t['title'] == 'Peek closed' and not t['exiting'] for t in app.call('toasts')['toasts']), timeout=3, step=.05)
            app.call('space', space=space_b)
            undone = app.call('toast-action', index=0)
            back = wait_until(lambda: app.call('peek-state')['stack'], timeout=5, step=.05) or []
            row('nav4_peek_undo_keeps_profile', opened_profile == profile_a and profile_b != profile_a and undone
                and len(back) == 1 and back[-1]['profile'] == profile_a, opened=opened_profile, undone=back,
                profileA=profile_a, profileB=profile_b)
        guarded('nav4_peek_undo_keeps_profile', peek_undo_profile,
                lambda: (app.call('space', space=space_a['id']), app.call('peek-close')))

        # F-03: reopening Library in another Profile's Space shows that Profile's History, even when the
        # panel reopens on another section first.
        def library_profile():
            app.call('space', space=space_a['id'])
            page_a = origin + '/library-profile-a'
            h.new_tab(app, page_a)
            assert wait_until(lambda: page_a in history_urls(), timeout=8, step=.1)
            app.call('space', space=space_b)
            page_b = origin + '/library-profile-b'
            h.new_tab(app, page_b)
            assert wait_until(lambda: page_b in [r['url'] for r in app.call('history-state', profile=profile_b)['rows']], timeout=8, step=.1)
            app.call('space', space=space_a['id'])
            app.call('library', action='open', section='downloads')
            app.call('library', action='close')
            time.sleep(.6)
            app.call('space', space=space_b)
            app.call('library', action='open')
            app.call('library', action='select', section='history')
            state_b = app.call('library')

            def find(value, key):
                if isinstance(value, dict):
                    if key in value: return value[key]
                    for item in value.values():
                        found = find(item, key)
                        if found is not None: return found
                return None
            profiles = find(state_b, 'profiles') or {}
            # The History rows the panel shows are Profile B's: its page is listed, Profile A's is not.
            shown = wait_until(lambda: (lambda r: r if page_b in [x['url'] for x in r['rows']] else None)(
                app.call('library-history-state')), timeout=5, step=.1) or app.call('library-history-state')
            urls = [x['url'] for x in shown['rows']]
            row('nav4_library_reopen_follows_profile', profiles.get('history') == profile_b and profiles.get('downloads') == profile_b
                and shown['profile'] == profile_b and page_b in urls and page_a not in urls,
                profiles=profiles, historyRows=urls, profileA=profile_a, profileB=profile_b)
        guarded('nav4_library_reopen_follows_profile', library_profile,
                lambda: (app.call('library', action='close'), app.call('space', space=space_a['id'])))

        # Bug sweep r6 (review of #646, #7): the panel above holds Profile B's History rows. Reopened
        # from Profile A's Space, the open call's own turn must not draw them (the `open` reply is read
        # on the same main-actor turn as the show).
        def library_profile_same_turn():
            page_a, page_b = origin + '/library-profile-a', origin + '/library-profile-b'
            app.call('library', action='close')
            time.sleep(.6)
            app.call('space', space=space_a['id'])
            opened = app.call('library', action='open', section='history')
            drawn = [r.get('subtitle', '') for r in opened.get('rows', [])] if opened.get('listVisible') else []
            later = wait_until(lambda: (lambda r: r if page_a in [x['url'] for x in r['rows']] else None)(
                app.call('library-history-state')), timeout=5, step=.1) or app.call('library-history-state')
            row('nav6_library_profile_switch_no_stale_rows', opened.get('section') == 'history'
                and not any(page_b in text for text in drawn) and page_a in [x['url'] for x in later['rows']],
                listVisible=opened.get('listVisible'), drawn=drawn, profiles=opened.get('profiles'))
        guarded('nav6_library_profile_switch_no_stale_rows', library_profile_same_turn,
                lambda: (app.call('library', action='close'), app.call('space', space=space_a['id'])))

        # F-13: Cmd+F in Library ▸ Spaces opens no Find on the page strip behind Library (and keeps focus).
        def library_spaces_find():
            app.call('select', tab=start)
            # A wide window: the run that reproduced the bug had a 2077 pt window (Find opened on the page
            # strip right of Space Manager); 1280 pt runs did not open Find on old code.
            app.call('window-frame', frame=[40, 40, 2000, 820])
            frame = app.call('window-state').get('frame')
            app.call('library', action='open', section='spaces')
            assert wait_until(lambda: app.call('library').get('section') == 'spaces' or None, timeout=3, step=.1) or True
            app.call('key', key='f', modifiers=['cmd'], route='app')
            time.sleep(.5)
            panes = app.call('find-state').get('panes', [])
            section = app.call('library').get('section')
            # Control: the same key with Library closed opens Find, so the key reaches the window.
            app.call('library', action='close')
            time.sleep(1)
            app.call('select', tab=start)
            routed = app.call('key', key='f', modifiers=['cmd'], route='app')
            control = wait_until(lambda: any(p.get('visible') for p in app.call('find-state').get('panes', [])), timeout=3, step=.1)
            control_state = app.call('find-state')
            app.call('key', key='escape', route='app')
            row('nav4_library_spaces_cmd_f_no_find', not any(p.get('visible') for p in panes) and bool(control), panes=panes,
                section=section, control=bool(control), routed=routed, controlState=control_state,
                window=app.call('window-state').get('selected'), start=start, frame=frame)
        guarded('nav4_library_spaces_cmd_f_no_find', library_spaces_find,
                lambda: (app.call('library', action='close'), app.call('window-frame', frame=[80, 60, 1280, 820])))

        # F-02: a Blank Window's bar lists its own tabs (Switch to Tab) and the current-tab actions.
        def blank_window():
            main_tabs = {t['id'] for t in app.call('tabs')}
            app.call('key', key='n', modifiers=['control', 'command'], route='app')
            assert wait_until(lambda: app.call('blank-window')['isBlankWindow'] or None, timeout=8, step=.1)
            close_bar()
            first = h.new_tab(app, origin + '/blank-one')
            second = h.new_tab(app, origin + '/blank-two')
            app.call('select', tab=first)
            opened = bar('t')
            empty = wait_until(lambda: (lambda s: s if s.get('final') and s.get('text') == '' else None)(state()), timeout=5, step=.05) or state()
            switch_ids = [r['tab'] for r in empty.get('rows', []) if r['kind'] == 'switchToTab']
            typed = type_query('copy url')
            actions = [r['action'] for r in typed.get('rows', []) if r['kind'] == 'action']
            row('nav4_blank_window_bar_uses_window_tabs', opened.get('presented') and second in switch_ids
                and not (set(switch_ids) & main_tabs) and 'copy-url' in actions,
                switchTabs=switch_ids, mainTabs=sorted(main_tabs), actions=actions)
        def close_blank():
            close_bar()
            if app.call('blank-window').get('isBlankWindow'):
                app.call('window-close')
                wait_until(lambda: not app.call('blank-window').get('isBlankWindow') or None, timeout=5, step=.1)
        guarded('nav4_blank_window_bar_uses_window_tabs', blank_window, close_blank)

        # F-14: an exact-host rule for google.com does not cover Meet: the first Meet link adds the Meet rule.
        def meet_route():
            nonlocal meet_saved
            meet_saved = app.call('defaults', key=MEET_DONE, persistent=True)
            app.call('defaults', key=MEET_DONE, value=None)
            app.call('routing-rules', hostEquals='google.com')
            delivered = subprocess.run(['/usr/bin/open', '-a', app.bundle, MEET], capture_output=True, text=True, timeout=15)
            logged = wait_until(lambda: any(e['decision']['request']['url'] == MEET for e in app.call('routing-log')['entries']), timeout=8, step=.1)
            rules = app.call('routing-rules')
            row('nav4_meet_route_exact_host_not_covering', delivered.returncode == 0 and bool(logged) and {'hostEquals': 'meet.google.com'} in rules,
                rules=rules)
        def close_meet():
            for session in app.call('little-open-state')['sessions']:
                app.call('little-open-action', id=session['id'], action='close')
            for tab in app.call('tabs'):
                if tab['url'].startswith('https://meet.google.com'): app.call('close', tab=tab['id'])
        guarded('nav4_meet_route_exact_host_not_covering', meet_route, close_meet)

        # F-11: Little Open's Open in Space (Cmd+O) uses the most recently focused window, not the oldest.
        # Both windows show Space A (the pill's Space for a Profile A session); only the target window changes.
        def little_open_window():
            app.call('space', space=space_a['id'])
            app.call('select', tab=start)
            first_window = app.call('window-state')['id']
            app.call('key', key='n', modifiers=['cmd'], route='app')
            assert wait_until(lambda: app.call('window-state')['id'] != first_window or None, timeout=8, step=.1)
            close_bar()
            second_window = app.call('window-state')['id']
            if app.call('window-state')['space'] != space_a['id']: app.call('space', space=space_a['id'])
            before = {s['id'] for s in app.call('little-open-state')['sessions']}
            app.call('menu-perform', id='new-little-open-window')
            session = wait_until(lambda: next((s for s in app.call('little-open-state')['sessions'] if s['id'] not in before), None), timeout=5, step=.1)
            app.call('key', window=session['window'], text=origin + '/little-move\r')
            assert wait_until(lambda: next((s for s in app.call('little-open-state')['sessions'] if s['id'] == session['id'] and s['state'] == 'page' and not s['loading']), None), timeout=12, step=.1)
            app.call('key', window=session['window'], key='o', modifiers=['cmd'])
            moved = wait_until(lambda: not any(s['id'] == session['id'] for s in app.call('little-open-state')['sessions']), timeout=8, step=.1)
            target = wait_until(lambda: next((t for t in app.call('tabs') if t['url'] == origin + '/little-move'), None), timeout=5, step=.1)
            first_state = app.call('window-state', id=first_window)
            second_state = app.call('window-state', id=second_window)
            row('nav4_little_open_moves_to_recent_window', bool(moved) and target is not None
                and second_state['selected'] == target['id'] and first_state['selected'] != target['id'],
                first=(first_state['space'], first_state['selected']), second=(second_state['space'], second_state['selected']),
                target=target and target['id'])
        def close_second_window():
            while len(app.call('shell-windows')) > 1:
                app.call('window-close'); time.sleep(.5)
            app.call('space', space=space_a['id'])
        guarded('nav4_little_open_moves_to_recent_window', little_open_window, close_second_window)

        # F-08: Cmd+L while a sleeping tab wakes from its stored history (the wake held after the history
        # read) loads the typed address once the wake ends, over the restored back list: Back returns to
        # the page the tab slept on, and the old address never replaces the typed one.
        def sleep_tab(t): return app.call('sleep-state', tab=t)['tabs'][0]
        def wake_navigation():
            app.call('space', space=space_a['id'])
            assert wait_until(lambda: app.call('sleep-state').get('started'), timeout=10, step=.1)
            app.call('sleep-mode', mode='balanced')
            first, second, typed = origin + '/wake-a', origin + '/wake-b', origin + '/wake-typed'
            tab = h.new_tab(app, first)
            app.call('navigate', tab=tab, url=second); app.call('wait', tab=tab)
            app.call('select', tab=start)
            assert wait_until(lambda: app.call('window-state')['selected'] == start, timeout=5, step=.05)
            app.call('sleep-clock', advance=15.0); app.call('sleep-now', tab=tab)
            app.call('sleep-clock', advance=86400.0); app.call('sleep-tick')
            assert wait_until(lambda: (lambda t: not t['content'] and t['hosts'] == 0)(sleep_tab(tab)), timeout=8, step=.1), sleep_tab(tab)
            stored = any(r['tab'] == tab and r['entries'] >= 2 for r in app.call('sleep-store'))
            app.call('sleep-wake-hold', hold=True)
            app.call('select', tab=tab)
            held = wait_until(lambda: tab in app.call('sleep-wake-hold')['held'], timeout=8, step=.05)
            bar('l')
            type_query(typed)
            app.call('key', key='return', route='app')
            time.sleep(.3)
            app.call('sleep-wake-hold', hold=False)
            def current():
                return next((t for t in app.call('tabs') if t['id'] == tab), {})
            loaded = wait_until(lambda: (lambda t: t if t.get('url') == typed and t.get('hasWebContent') and t.get('loaded') else None)(current()), timeout=12, step=.1)
            href = app.eval(tab, 'location.href') if loaded else ''
            length = app.eval(tab, 'history.length') if loaded else 0
            reported_back = current().get('canGoBack')
            app.call('key', key='[', modifiers=['cmd'], route='app')
            went_back = wait_until(lambda: app.eval(tab, 'location.href') == second, timeout=8, step=.1) if loaded else False
            row('nav4_cmd_l_during_wake_keeps_typed_and_back', stored and bool(held) and bool(loaded) and href == typed
                and length >= 3 and reported_back is True and bool(went_back),
                stored=stored, held=bool(held), tab=current(), href=href, historyLength=length, reportedBack=reported_back)
        def end_wake():
            app.call('sleep-wake-hold', hold=False)
            app.call('sleep-clock', reset=True)
            app.call('select', tab=start)
        guarded('nav4_cmd_l_during_wake_keeps_typed_and_back', wake_navigation, end_wake)

        # F-05: a blank Little Open whose address never commits (a download) gets its bar back: input,
        # Esc and close stay. The download goes to this run's own folder.
        def little_open_download():
            import http.server, tempfile, threading
            class Download(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    body = b'nav4 download fixture\n'
                    self.send_response(200); self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Disposition', 'attachment; filename="nav4-fixture.bin"')
                    self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
                def log_message(self, *args): pass
            files = h.LoopbackHTTPServer(Download)
            threading.Thread(target=files.serve_forever, daemon=True).start()
            folder = tempfile.mkdtemp(prefix='nav4-downloads-', dir=tmp)
            try:
                app.call('download-settings', profile=profile_a, directory=folder, ask=False)
                app.call('space', space=space_a['id'])
                before = {x['id'] for x in app.call('little-open-state')['sessions']}
                app.call('menu-perform', id='new-little-open-window')
                session = wait_until(lambda: next((x for x in app.call('little-open-state')['sessions'] if x['id'] not in before), None), timeout=5, step=.1)
                target = 'http://127.0.0.1:%d/nav4-download' % files.server_address[1]
                app.call('key', window=session['window'], text=target + '\r')
                import os
                saved = wait_until(lambda: [f for f in os.listdir(folder) if f.startswith('nav4-fixture')] or None, timeout=10, step=.1)
                back = wait_until(lambda: next((x for x in app.call('little-open-state')['sessions']
                                                if x['id'] == session['id'] and x['state'] == 'bar' and x['barPresented']), None), timeout=5, step=.1)
                after = next((x for x in app.call('little-open-state')['sessions'] if x['id'] == session['id']), {})
                closed = False
                if back:
                    app.call('key', window=session['window'], key='escape')
                    closed = wait_until(lambda: not any(x['id'] == session['id'] for x in app.call('little-open-state')['sessions']), timeout=5, step=.1)
                row('nav4_little_open_bar_back_after_download', bool(saved) and bool(back) and bool(closed),
                    saved=saved, state=after.get('state'), barPresented=after.get('barPresented'), closedByEsc=bool(closed))
            finally:
                for x in app.call('little-open-state')['sessions']:
                    app.call('little-open-action', id=x['id'], action='close')
                files.shutdown(); files.server_close()
        guarded('nav4_little_open_bar_back_after_download', little_open_download)

        # F-04: closing the last browser window stops Handoff advertising its page.
        def handoff_last_window():
            app.call('select', tab=start)
            published = wait_until(lambda: (lambda s: s if s['url'] == origin + '/start' else None)(app.call('handoff-state')), timeout=5, step=.1)
            for _ in app.call('shell-windows'):
                app.call('window-close')
            closed = wait_until(lambda: not app.call('shell-windows') or None, timeout=5, step=.1)
            after = app.call('handoff-state')
            row('nav4_handoff_cleared_after_last_window', bool(published) and bool(closed) and not after['published'] and after['url'] == '',
                before=published, after=after)
        guarded('nav4_handoff_cleared_after_last_window', handoff_last_window)
    finally:
        try:
            app.call('defaults', key=MEET_DONE, value=meet_saved)
        except Exception:
            pass
        server.shutdown()
        server.server_close()
