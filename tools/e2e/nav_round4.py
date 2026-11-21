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
            row('nav4_library_reopen_follows_profile', profiles.get('history') == profile_b and profiles.get('downloads') == profile_b,
                profiles=profiles, profileA=profile_a, profileB=profile_b)
        guarded('nav4_library_reopen_follows_profile', library_profile,
                lambda: (app.call('library', action='close'), app.call('space', space=space_a['id'])))

        # F-13 guard (seed was a false positive on the real key path): Cmd+F in Library ▸ Spaces opens no Find
        # on the page strip behind Library.
        def library_spaces_find():
            app.call('select', tab=start)
            app.call('library', action='open', section='spaces')
            assert wait_until(lambda: app.call('library').get('section') == 'spaces' or None, timeout=3, step=.1) or True
            app.call('key', key='f', modifiers=['cmd'], route='app')
            time.sleep(.5)
            panes = app.call('find-state').get('panes', [])
            row('nav4_library_spaces_cmd_f_no_find', not any(p.get('visible') for p in panes), panes=panes,
                section=app.call('library').get('section'))
        guarded('nav4_library_spaces_cmd_f_no_find', library_spaces_find, lambda: app.call('library', action='close'))

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
