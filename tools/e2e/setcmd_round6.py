"""Bug sweep round 6, lane SETCMD6: Settings, Profiles and command bar rows through the real App
automation socket (keys go through the App route; Settings through its real view models and sheet).

Runs inside `engine_e2e.py --only commandbar`; OPEN_COMMANDBAR_SETCMD6_ONLY=1 runs only these rows.
OPEN_E2E_SETCMD6_ROWS=q01,s01 runs a subset (row keys: q04 q02 q01 q03 q05 s05 s02 s01 s01b).
Loopback pages only; every other host resolves to nothing, so no row reaches a real service.
"""
import os
import time

ENGINE_SWITCHES = ['--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1', '--no-proxy-server']


def run(factory, results, tmp, h):
    wait_until = h.wait_until
    server, origin = h._fixture_server('Setcmd6')
    app = factory(urls=(origin + '/start',), fresh=True, extra_args=ENGINE_SWITCHES)
    only = set(filter(None, os.environ.get('OPEN_E2E_SETCMD6_ROWS', '').split(',')))

    def wanted(key): return not only or key in only

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('setcmd6 %-44s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def state(): return app.call('commandbar-state')

    def bar(key='t'):
        app.call('key', key=key, modifiers=['cmd'], route='app')
        assert wait_until(lambda: state().get('presented'), timeout=3, step=.05), state()
        return state()

    def type_query(text):
        app.call('key', text=text)
        return wait_until(lambda: (lambda s: s if s.get('text') == text and s.get('final') else None)(state()), timeout=5, step=.05) or state()

    def press(key, modifiers=()):
        app.call('key', key=key, modifiers=list(modifiers), route='app')

    def close_bar():
        if not app.call('shell-windows'): return
        if state().get('presented'):
            press('escape')
            wait_until(lambda: not state().get('presented'), timeout=3, step=.05)

    def spaces(): return app.call('spaces')

    def focused_space(): return next(s for s in spaces() if s['focused'])

    def shell(**kw): return app.call('profiles-shell', **kw)

    def profile_named(name): return next((p for p in shell()['profiles'] if p['name'] == name), None)

    main_window = []

    def focus_main():
        # Each row starts in the launch window, key and active (an earlier row may close its own window).
        if main_window: app.call('window-focus', id=main_window[0], activate=True)
        wait_until(lambda: app.call('window-state').get('isKeyWindow') or None, timeout=3, step=.05)

    def reveal():
        # Edit ▸ Undo acts on the sidebar's (the model's) Undo stack, not a web page's.
        try: app.call('menu-perform', id='reveal-tab-in-sidebar')
        except RuntimeError: pass

    def guarded(name, body, cleanup=None):
        try:
            focus_main()
            body()
        except Exception as error:  # A failed setup is a FAIL row, never a skipped one.
            row(name, False, error=repr(error))
        finally:
            try:
                close_bar()
                if cleanup: cleanup()
            except Exception as error:
                print('setcmd6 cleanup after %s: %r' % (name, error), flush=True)

    try:
        start = app.call('tabs')[0]['id']
        app.call('wait', tab=start)
        home = focused_space()
        main_window.append(app.call('window-state')['id'])

        # Q-04: Settings rows in the command bar draw no keycap: an action row's subtitle is its shortcut.
        def settings_rows_no_keycap():
            app.call('select', tab=start)
            bar('t'); found = type_query('search engine')
            settings_ids = [r['id'] for r in found.get('rows', []) if r.get('action', '').startswith('settings-link:')]
            drawn = [d for d in found.get('drawn', []) if d['id'] in settings_ids]
            # Control: an ordinary action with a shortcut still draws its keycaps.
            close_bar(); bar('t'); control = type_query('new tab')
            shortcut = next((d for d in control.get('drawn', []) if d['id'].startswith('action:') and d.get('keys')), None)
            row('setcmd6_q04_settings_rows_no_keycap', bool(drawn) and all(not d.get('keys') for d in drawn) and bool(shortcut),
                drawn=drawn, control=shortcut)
        if wanted('q04'): guarded('setcmd6_q04_settings_rows_no_keycap', settings_rows_no_keycap)

        # Q-02: Ctrl+Cmd+F (Enter Full Screen) with Library open on Downloads reaches the View menu;
        # plain Cmd+F still focuses Library's search field.
        def library_full_screen():
            app.call('select', tab=start)
            app.call('library', action='open', section='downloads')
            assert wait_until(lambda: app.call('library').get('section') == 'downloads' or None, timeout=5, step=.1)
            time.sleep(.3)
            press('f', ['control', 'cmd'])
            full = wait_until(lambda: (lambda s: s if s['fullscreen'] and not s['fullscreenTransition'] else None)(app.call('window-state')),
                              timeout=8, step=.1)
            observed = app.call('window-state')
            if observed['fullscreen']:
                app.call('window-fullscreen')
                wait_until(lambda: (lambda s: s if not s['fullscreen'] and not s['fullscreenTransition'] else None)(app.call('window-state')),
                           timeout=10, step=.1)
            # Control: plain Cmd+F in the same Library focuses its search field (and opens no full screen).
            app.call('library', action='open', section='downloads'); time.sleep(.3)
            press('f', ['cmd']); time.sleep(.3)
            control = app.call('window-state')
            row('setcmd6_q02_library_ctrl_cmd_f_full_screen', bool(full) and not control['fullscreen']
                and control.get('firstResponder') == 'LibrarySearchEditor',
                fullscreen=bool(full), firstResponderAfterFullScreenKey=observed.get('firstResponder'),
                controlFirstResponder=control.get('firstResponder'), controlFullscreen=control['fullscreen'])
        if wanted('q02'): guarded('setcmd6_q02_library_ctrl_cmd_f_full_screen', library_full_screen,
                                  lambda: app.call('library', action='close'))

        # Q-01: Edit Pinned Page, Cmd+Return, then Return: both edit the pinned tab; the selected tab stays.
        def pinned_cmd_return():
            pin_id = h.new_tab(app, origin + '/pinned-a')
            app.call('wait', tab=pin_id)
            app.call('pin', tab=pin_id)
            other = h.new_tab(app, origin + '/today-t')
            app.call('wait', tab=other)
            app.call('select', tab=other)
            assert wait_until(lambda: app.call('window-state')['selected'] == other or None, timeout=3, step=.05)
            app.call('sidebar-menu', node=pin_id, item='Edit Pinned Page/Edit…')
            editing = wait_until(lambda: (lambda s: s if s.get('presented') and s.get('pinnedEdit') == pin_id else None)(state()), timeout=3, step=.05)
            assert editing, state()
            target = origin + '/pinned-b'
            type_query(target)
            press('return', ['cmd'])
            changed = wait_until(lambda: next((t for t in app.call('tabs') if t['id'] == pin_id and t['pinnedURL'] == target), None), timeout=5, step=.1)
            after_cmd = state()
            # The next entry (a different URL, typed over the selected text) still edits the pinned tab.
            second = origin + '/pinned-c'
            type_query(second)
            press('return')
            wait_until(lambda: not state().get('presented'), timeout=3, step=.05)
            time.sleep(1.0)
            other_url = app.eval(other, 'location.href')
            pinned = next((t for t in app.call('tabs') if t['id'] == pin_id), {})
            row('setcmd6_q01_pinned_edit_cmd_return_keeps_target', bool(changed) and other_url == origin + '/today-t'
                and pinned.get('pinnedURL') == second,
                otherURL=other_url, pinnedURL=pinned.get('pinnedURL'),
                afterCmdReturn={k: after_cmd.get(k) for k in ('presented', 'pinnedEdit', 'text')})
            app.call('close', tab=other)
        if wanted('q01'): guarded('setcmd6_q01_pinned_edit_cmd_return_keeps_target', pinned_cmd_return)

        # Q-05: Search Settings from an Incognito window opens Settings ▸ Search for the window's parent
        # Profile, not the Profile that Settings showed last.
        def incognito_search_settings():
            parent = home['profile']
            shell(action='create', name='SC6 Search B')
            other = profile_named('SC6 Search B')['id']
            shell(profile=other)  # Settings last showed Profile B
            assert shell()['selectedProfile'] == other
            before = {w['id'] for w in app.call('incognito-state')['windows'] if w['private']}
            app.call('menu-perform', id='new-incognito-window')
            window = wait_until(lambda: next((w for w in app.call('incognito-state')['windows'] if w['private'] and w['id'] not in before), None),
                                timeout=8, step=.1)
            assert window, 'no Incognito window'
            app.call('window-focus', id=window['id'], activate=True)
            close_bar()
            bar('t'); found = type_query('search settings')
            rows = found.get('rows', [])
            index = next((i for i, r in enumerate(rows) if r.get('action') == 'search-settings'), None)
            assert index is not None, [(r.get('title'), r.get('action')) for r in rows]
            current = found['selected']
            for _ in range(max(0, index - current)): press('down')
            for _ in range(max(0, current - index)): press('up')
            press('return')
            shown = wait_until(lambda: (lambda s: s if s['selectedProfile'] == parent else None)(shell()), timeout=5, step=.1) or shell()
            row('setcmd6_q05_incognito_search_settings_parent', shown['selectedProfile'] == parent,
                selected=shown['selectedProfile'], parent=parent, other=other)
            # Review r1 #4: a "Settings: …" row (a Settings link) from the same window also opens the parent.
            shell(profile=other); shell(action='cancel')
            app.call('window-focus', id=window['id'], activate=True)
            close_bar()
            bar('t'); found = type_query('search engine')
            rows = found.get('rows', [])
            index = next((i for i, r in enumerate(rows) if r.get('action') == 'settings-link:search/engine'), None)
            assert index is not None, [(r.get('title'), r.get('action')) for r in rows]
            current = found['selected']
            for _ in range(max(0, index - current)): press('down')
            for _ in range(max(0, current - index)): press('up')
            press('return')
            linked = wait_until(lambda: (lambda s: s if s['selectedProfile'] == parent else None)(shell()), timeout=5, step=.1) or shell()
            row('setcmd6_q05_incognito_settings_link_parent', linked['selectedProfile'] == parent,
                selected=linked['selectedProfile'], parent=parent, other=other)
            # Review r2 #1: a link to another section (Downloads) also takes the parent Profile, without the
            # search-suggestion notice sheet (only the Search section shows it).
            shell(profile=other); shell(action='cancel')
            app.call('window-focus', id=window['id'], activate=True)
            close_bar()
            bar('t'); found = type_query('download location')
            rows = found.get('rows', [])
            index = next((i for i, r in enumerate(rows) if r.get('action') == 'settings-link:downloads/location'), None)
            assert index is not None, [(r.get('title'), r.get('action')) for r in rows]
            current = found['selected']
            for _ in range(max(0, index - current)): press('down')
            for _ in range(max(0, current - index)): press('up')
            press('return')
            downloads = wait_until(lambda: (lambda s: s if s['selectedProfile'] == parent else None)(shell()), timeout=5, step=.1) or shell()
            time.sleep(.5); downloads = shell()
            row('setcmd6_q05_settings_link_no_suggest_notice', downloads['selectedProfile'] == parent and not downloads['sheet'],
                selected=downloads['selectedProfile'], parent=parent, sheet=downloads['sheet'], sheetText=downloads.get('sheetText', [])[:6])
            shell(action='cancel')
            app.call('window-focus', id=window['id'], activate=True)
            app.call('window-close')
            wait_until(lambda: not any(w['private'] for w in app.call('incognito-state')['windows']) or None, timeout=8, step=.1)
        if wanted('q05'): guarded('setcmd6_q05_incognito_search_settings_parent', incognito_search_settings)

        # Q-03: an Easel whose row is in another Profile's Space is still found from the command bar,
        # and choosing it selects that row (no second row).
        def easel_other_profile():
            app.call('space', space=home['id'])
            space_b = app.call('space-create', title='SC6 Easel B', profile='SC6 Easel Profile')
            app.call('space', space=space_b)
            assert wait_until(lambda: focused_space()['id'] == space_b or None, timeout=5, step=.1)
            app.call('menu-perform', id='new-easel')
            easel_tab = wait_until(lambda: next((t for t in app.call('tabs') if t['url'].startswith('open://easel/')), None), timeout=8, step=.1)
            assert easel_tab, 'no Easel tab'
            app.call('easel', action='title', text='Roadmap Board')
            app.call('easel', action='flush')
            app.call('space', space=home['id'])
            assert wait_until(lambda: focused_space()['id'] == home['id'] or None, timeout=5, step=.1)
            app.call('select', tab=start)
            def query():
                bar('t'); return type_query('roadmap board')
            found = query()
            if not any(r['url'] == easel_tab['url'] for r in found.get('rows', [])):
                # The catalog refreshes off the main thread when the bar opens: ask once more.
                close_bar(); time.sleep(.6); found = query()
            rows = found.get('rows', [])
            hit = next((r for r in rows if r['url'] == easel_tab['url']), None)
            chosen = None
            if hit:
                current = found['selected']; index = rows.index(hit)
                for _ in range(max(0, index - current)): press('down')
                for _ in range(max(0, current - index)): press('up')
                press('return')
                chosen = wait_until(lambda: (lambda w: w if w['selected'] == easel_tab['id'] else None)(app.call('window-state')), timeout=5, step=.1)
            copies = [t for t in app.call('tabs') if t['url'] == easel_tab['url']]
            row('setcmd6_q03_easel_in_other_profile_found', bool(hit) and hit.get('kind') == 'navigate' and bool(chosen) and len(copies) == 1,
                row=hit, rows=[(r['title'], r['kind']) for r in rows[:6]], chosen=bool(chosen), copies=len(copies))
            app.call('space', space=home['id'])
        if wanted('q03'): guarded('setcmd6_q03_easel_in_other_profile_found', easel_other_profile,
                                  lambda: app.call('space', space=home['id']))

        # S-05: with Settings open, the user moves to window B and back to Settings: "Show the toolbar"
        # acts on B, the window the user used last.
        def appearance_window():
            app.call('space', space=home['id'])
            first = app.call('window-state')['id']
            app.call('menu-perform', id='settings')
            shell(action='cancel')  # no sheet (an earlier row's notice) may take the key focus from Settings
            assert wait_until(lambda: app.call('settings-appearance')['window'] == first or None, timeout=5, step=.1), \
                ('settings shown for', app.call('settings-appearance'), first)
            app.call('window-focus', id=first, activate=True)
            close_bar()
            app.call('menu-perform', id='new-window')
            second = wait_until(lambda: (lambda w: w['id'] if w['id'] != first else None)(app.call('window-state')), timeout=5, step=.1)
            assert second, 'no second window'
            close_bar()
            # As a click on it does: retried, since a loaded machine can take a moment to order Settings in.
            assert wait_until(lambda: app.call('settings-appearance', action='key')['key'] or None, timeout=8, step=.25), \
                ('settings not key', app.call('settings-appearance'))
            before = {w: app.call('window-state', id=w)['toolbar'].get('shown') for w in (first, second)}
            st = app.call('settings-appearance', action='toolbar', on=True)
            time.sleep(.3)
            after = {w: app.call('window-state', id=w)['toolbar'].get('shown') for w in (first, second)}
            app.call('settings-appearance', action='toolbar', on=False)
            row('setcmd6_s05_appearance_follows_last_window', st['window'] == second and after[second] and not after[first],
                target=st['window'], first=first, second=second, before=before, after=after)
            app.call('window-focus', id=second, activate=True)
            app.call('menu-perform', id='close-window')
            wait_until(lambda: len(app.call('shell-windows')) == 1 or None, timeout=5, step=.1)
            app.call('window-focus', id=first, activate=True)
        if wanted('s05'): guarded('setcmd6_s05_appearance_follows_last_window', appearance_window)

        # S-02: Search Engines sheet: Add, type a new engine, click another engine's row, Save: the new
        # engine is added and the clicked one is unchanged.
        def engines_sheet():
            template_a = 'https://alpha.example/?q=%s'
            app.call('space', space=home['id'])
            shell(profile=home['profile'])
            shell(action='engines-open')
            assert wait_until(lambda: shell()['sheet'] or None, timeout=5, step=.1), 'no Search Engines sheet'
            # A custom engine "Alpha" through the sheet itself.
            shell(action='press', label='Add'); time.sleep(.3)
            for index, text in enumerate(('SC6 Alpha', 'sc6alpha', template_a)): shell(action='engine-type', field=index, text=text)
            shell(action='press', label='Save engine')
            alpha = wait_until(lambda: next((e for e in shell()['customEngines'] if e['name'] == 'SC6 Alpha'), None), timeout=3, step=.1)
            assert alpha, shell()['customEngines']
            time.sleep(.3)
            shell(action='press', label='Add'); time.sleep(.3)
            for index, text in enumerate(('SC6 Beta', 'sc6beta', 'https://beta.example/?q=%s')): shell(action='engine-type', field=index, text=text)
            shell(action='engine-click-row', engine=alpha['id']); time.sleep(.3)
            shell(action='press', label='Save engine'); time.sleep(.5)
            engines = shell()['customEngines']
            kept = next((e for e in engines if e['id'] == alpha['id']), {})
            row('setcmd6_s02_engine_save_targets_edited', kept.get('name') == 'SC6 Alpha' and kept.get('url') == template_a
                and any(e['name'] == 'SC6 Beta' and e['id'] != alpha['id'] for e in engines),
                engines=engines)
        def close_engines():
            sheet = shell()
            if sheet['sheet']:
                try: shell(action='press', label='Done')
                except Exception: pass
        if wanted('s02'): guarded('setcmd6_s02_engine_save_targets_edited', engines_sheet, close_engines)

        # S-01: Undo of New Profile (Settings ▸ Profiles ▸ New Profile with a Space moved in) journals the
        # Profile's folders. Redo takes them off the list; the next launch wipes them if the Profile
        # stayed undone. Settings no longer selects the removed Profile.
        def undo_new_profile():
            nonlocal app
            app.call('space', space=home['id'])
            app.call('select', tab=start)
            app.call('undo-state', clear=True)
            shell(action='create', name='SC6 Undo', spaces=[home['id']])
            created = profile_named('SC6 Undo')
            assert created, shell()['profiles']
            directory = created['directory']
            app.call('navigate', tab=start, url=origin + '/s01'); app.call('wait', tab=start)
            engine_dir = os.path.join(app.user_data, 'Engine', directory)
            profile_dir = os.path.join(app.user_data, 'Profiles', directory)
            on_disk = wait_until(lambda: os.path.isdir(engine_dir) and os.path.isdir(profile_dir) or None, timeout=10, step=.2)
            selected_before = shell()['selectedProfile']
            # Review r1 #2: a Blank Window and an Incognito window of the new Profile (neither registers Undo).
            windows_before = len(app.call('shell-windows'))
            press('n', ['control', 'command'])
            blank = wait_until(lambda: app.call('blank-window').get('isBlankWindow') or None, timeout=8, step=.1)
            close_bar(); focus_main()
            private_before = {w['id'] for w in app.call('incognito-state')['windows'] if w['private']}
            app.call('menu-perform', id='new-incognito-window')
            private = wait_until(lambda: next((w for w in app.call('incognito-state')['windows']
                                               if w['private'] and w['id'] not in private_before), None), timeout=8, step=.1)
            close_bar(); focus_main()
            opened = len(app.call('shell-windows'))
            def undo_until(gone):
                for _ in range(4):
                    if (profile_named('SC6 Undo') is None) == gone: return True
                    reveal()
                    app.call('menu-perform', id='undo' if gone else 'redo')
                    time.sleep(.3)
                return (profile_named('SC6 Undo') is None) == gone
            removed = undo_until(True)
            closed = wait_until(lambda: len(app.call('shell-windows')) == windows_before or None, timeout=5, step=.1)
            row('setcmd6_s01_undo_closes_profile_windows', bool(blank) and bool(private) and opened == windows_before + 2
                and bool(closed) and not any(w['private'] for w in app.call('incognito-state')['windows']),
                blankOpened=bool(blank), privateOpened=bool(private), windows=[windows_before, opened, len(app.call('shell-windows'))])
            focus_main()
            undone = shell()
            ids = [p['id'] for p in undone['profiles']]
            reveal(); app.call('menu-perform', id='redo'); time.sleep(.3)
            redone = shell()
            back = profile_named('SC6 Undo') is not None
            # The last Undo comes with no other edit: an earlier step's debounced save (1 s) lands first, and no
            # reveal (a selection change, which saves too) precedes it, so only the Undo itself can save.
            time.sleep(2.5)
            try: app.call('menu-perform', id='undo')
            except RuntimeError:
                reveal(); time.sleep(2.5); app.call('menu-perform', id='undo')
            time.sleep(.3)
            undone_again = shell()
            # Review r1 #1: no explicit save and no normal quit. The Undo's own scheduled save (1 s debounce)
            # must reach disk; then the App dies as in a crash (no quit-time save).
            time.sleep(3)
            import json, signal
            snapshot = json.loads(open(os.path.join(app.user_data, 'State', 'browser.json')).read())
            saved_profiles = [p.get('name') for p in snapshot.get('profiles', [])]
            killed_pid = app.pid
            os.kill(app.pid, signal.SIGKILL)
            app.quit()
            app = factory(urls=(), extra_args=ENGINE_SWITCHES)
            relaunched = shell()
            relaunched_profiles = [p['name'] for p in relaunched['profiles']]
            row('setcmd6_s01_undo_new_profile_wipes_folders', bool(on_disk) and removed and back
                and directory in undone['orphans'] and directory not in redone['orphans'] and directory in undone_again['orphans']
                and undone['selectedProfile'] in ids
                and 'SC6 Undo' not in relaunched_profiles
                and not os.path.isdir(engine_dir) and not os.path.isdir(profile_dir) and not relaunched['orphans'],
                directory=directory, onDisk=bool(on_disk), removed=removed, redoBack=back, selectedBefore=selected_before,
                orphans=[undone['orphans'], redone['orphans'], undone_again['orphans'], relaunched['orphans']],
                selectedAfterUndo=undone['selectedProfile'], profileIDs=ids,
                savedBeforeKill=saved_profiles, killedPid=killed_pid, quitReport=getattr(app, 'quit_report', None) and None,
                afterRelaunch=dict(engine=os.path.isdir(engine_dir), profile=os.path.isdir(profile_dir), profiles=relaunched_profiles))
        if wanted('s01'): guarded('setcmd6_s01_undo_new_profile_wipes_folders', undo_new_profile)

        # Review r1 #1: Undo of a new Profile saves the snapshot by itself. Here no Settings model exists (a
        # fresh process; Settings is not touched until after the crash). A regression guard, not proof of that
        # save: on every path tried, another save also follows the Undo, so this row passes without it too.
        def undo_saves_without_settings():
            nonlocal app
            import json, signal
            app.quit()
            app = factory(urls=(), extra_args=ENGINE_SWITCHES)
            focus_main()
            def saved():
                snapshot = json.loads(open(os.path.join(app.user_data, 'State', 'browser.json')).read())
                return [p.get('name') for p in snapshot.get('profiles', [])]
            space = app.call('space-create', title='SC6 Crash', profile='SC6 Crash Profile')
            time.sleep(2.5)
            created = 'SC6 Crash Profile' in saved()
            steps = [app.call('undo-state')]
            reveal(); time.sleep(2.5)
            app.call('menu-perform', id='undo')       # the Space
            time.sleep(2.5)
            steps.append(dict(app.call('undo-state'), spaces=len(app.call('spaces'))))
            # The Profile, through the command bar's "Undo" action: it calls the Undo manager directly, without the
            # save that Edit ▸ Undo's command path schedules.
            bar('t'); found = type_query('undo')
            rows = found.get('rows', [])
            index = next((i for i, r in enumerate(rows) if r.get('action') == 'undo-by-name'), None)
            assert index is not None, [(r.get('title'), r.get('action')) for r in rows]
            for _ in range(max(0, index - found['selected'])): press('down')
            time.sleep(2.5)                           # no earlier save is still pending
            before_last = saved()
            press('return')
            time.sleep(3)
            steps.append(dict(app.call('undo-state'), spaces=len(app.call('spaces'))))
            after_last = saved()
            os.kill(app.pid, signal.SIGKILL)
            app.quit()
            app = factory(urls=(), extra_args=ENGINE_SWITCHES)
            relaunched = [p['name'] for p in shell()['profiles']]
            row('setcmd6_s01_undo_saves_without_settings', created and 'SC6 Crash Profile' in before_last
                and 'SC6 Crash Profile' not in after_last and 'SC6 Crash Profile' not in relaunched
                and space not in [s['id'] for s in app.call('spaces')],
                created=created, steps=steps, savedBeforeLastUndo=before_last, savedAfterLastUndo=after_last, relaunched=relaunched)
        if wanted('s01b'): guarded('setcmd6_s01_undo_saves_without_settings', undo_saves_without_settings)
    finally:
        try:
            if not app.closed: app.quit()
        finally:
            server.shutdown(); server.server_close()
