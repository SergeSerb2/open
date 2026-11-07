"""Section 15 M-* rows: synthetic metadata through the real App save sheet.

No passwords, cards, addresses, Keychain access, or engine save callbacks. P-*
rows will exercise the engine when its bridge is available.
"""
import os


def run_save_prompts(factory, results, tmp, harness):
    wait = harness['wait_until']
    crashes_before = harness['_open_crash_reports']()
    app = factory(urls=('about:blank',), extra_args=['--use-mock-keychain'])

    def state():
        return app.call('save-prompt', state=True)

    def show(kind='password', host='login.example.com'):
        app.call('save-prompt', mock={'kind': kind, 'host': host})
        value = wait(lambda: (s if (s := state()).get('visible') else None), timeout=5, step=.05)
        assert value, 'specific save sheet did not become visible'
        return value

    def gone():
        return bool(wait(lambda: not state().get('visible'), timeout=5, step=.05))

    def events():
        return [e for e in app.call('events') if e.get('type') == 'savePrompt']

    def answer(value):
        app.call('save-prompt', answer=value)
        assert gone(), 'save sheet did not close after answer'

    def row(name, fn):
        try:
            detail = fn() or {}
            results[name] = {'ok': True, **detail}
        finally:
            app.call('save-prompt', withdraw=True)
            assert gone(), 'case cleanup left a save sheet open'

    try:
        wait(lambda: app.call('tabs') and app.call('tabs')[0].get('page'), timeout=15, step=.1)
        rows = [
            ('password', 'Save password for login.example.com?', ['Never on this site', 'No', 'Save']),
            ('passwordUpdate', 'Save password for login.example.com?', ['No', 'Save']),
            ('card', 'Save this card?', ['Not Now', 'Save']),
            ('address', 'Save Address?', ['No Thanks', 'Save']),
            ('addressUpdate', 'Save Address?', ['No Thanks', 'Save']),
        ]
        for kind, title, buttons in rows:
            def check_sheet(kind=kind, title=title, buttons=buttons):
                s = show(kind)
                assert s['kind'] == kind and s['title'] == title and s['buttons'] == buttons, s
                assert s['defaultButton'] == 'Save' and s['cancelButton'] == buttons[-2], s
                assert s['queueLength'] == 0, s
                app.call('snapshot', window=s['window'], path=os.path.join(tmp, 'save-sheet-' + kind + '.png'))
                answer('dismiss')
                return {'title': title, 'buttons': buttons}
            row('M-1-' + kind, check_sheet)

        def empty_long():
            assert show(host='')['title'] == 'Save this password?'
            answer('dismiss')
            s = show(host='long-subdomain-' * 40 + 'example.com')
            assert '…' in s['title'] and s['title'].endswith('example.com?'), s
            answer('dismiss')
        row('M-1-empty-long-host', empty_long)

        for choice in ['save', 'never', 'dismiss']:
            def check_answer(choice=choice):
                events(); show(); answer(choice)
                ev = events()
                assert len(ev) == 1 and ev[0]['answer'] == choice and ev[0]['kind'] == 'password' and ev[0]['displayHost'] == 'login.example.com', ev
                try:
                    app.call('save-prompt', answer=choice)
                    raise AssertionError('second answer was accepted')
                except RuntimeError as error:
                    assert 'no visible save sheet' in str(error), str(error)
                assert not events(), 'request answered twice'
                return {'answer': choice, 'events': len(ev)}
            row('M-2-' + choice, check_answer)

        def same_page_queue():
            events()
            for i in range(4):
                show(host='queue-%d.example.com' % i)
            s = state(); ev = events()
            assert s['title'] == 'Save password for queue-3.example.com?' and s['queueLength'] == 0, s
            assert [e['answer'] for e in ev] == ['ignored'] * 3, ev
            assert [e['displayHost'] for e in ev] == ['queue-%d.example.com' % i for i in range(3)], ev
            answer('save')
            assert [e['answer'] for e in events()] == ['save']
            return {'replaced': 3, 'visible': 1, 'queued': 0}
        row('M-3-same-page-replacement', same_page_queue)

        def withdraw():
            events(); show()
            app.call('save-prompt', withdraw=True)
            assert gone() and [e['answer'] for e in events()] == ['ignored']
        row('M-3-withdraw', withdraw)

        def capacity_and_focus():
            events()
            tabs = []
            app.call('window-interrupt', kind='sheet')
            try:
                for i in range(4):
                    tabs.append(harness['new_tab'](app, 'about:blank'))
                    app.call('save-prompt', mock={'kind': 'password', 'host': 'waiting-%d.example.com' % i})
                    assert not state().get('visible'), 'save sheet covered another sheet'
                    assert state()['queueLength'] == min(i + 1, 3)
                ev = events()
                assert [(e['displayHost'], e['answer']) for e in ev] == [('waiting-0.example.com', 'ignored')], ev
                # The dropped page cannot bring its sheet back.
                app.call('select', tab=tabs[0])
            finally:
                app.call('window-interrupt', kind='end-sheet')
            assert not state().get('visible') and state()['queueLength'] == 3
            for i in range(1, 4):
                app.call('select', tab=tabs[i])
                s = wait(lambda: (s if (s := state()).get('visible') else None), timeout=5, step=.05)
                assert s and s['title'] == 'Save password for waiting-%d.example.com?' % i, s
                answer('save')
            assert [e['answer'] for e in events()] == ['save'] * 3
            for tab in tabs:
                app.call('close', tab=tab)
            return {'waitingLimit': 3, 'oldestIgnored': 1, 'focusedPagesShown': 3}
        row('M-3-capacity-and-focus', capacity_and_focus)

        def page_close():
            events()
            tab = harness['new_tab'](app, 'about:blank')
            show()
            app.call('close', tab=tab)
            assert gone() and [e['answer'] for e in events()] == ['ignored']
        row('M-3-page-close-ignored', page_close)

        for key, modifiers, expected in [('escape', [], 'dismiss'), ('return', [], 'save'), ('enter', [], 'save'), ('.', ['command'], 'dismiss')]:
            def check_key(key=key, modifiers=modifiers, expected=expected):
                events(); s = show()
                app.call('key', window=s['window'], key=key, modifiers=modifiers)
                assert gone(), key + ' did not close the sheet'
                ev = events()
                assert [e['answer'] for e in ev] == [expected], ev
                return {'route': 'app', 'answer': expected}
            row('M-4-' + ('cmd-period' if key == '.' else key), check_key)

        def modal_keys():
            events(); s = show()
            before = [t['id'] for t in app.call('tabs')]
            for key in ['w', 't', 'l']:
                app.call('key', window=s['window'], key=key, modifiers=['command'])
                assert state().get('visible'), key + ' escaped save sheet'
            assert before == [t['id'] for t in app.call('tabs')]
            assert not events()
            answer('dismiss')
        row('M-4-browser-shortcuts-blocked', modal_keys)

        def input_limits():
            events(); show(host='h' * 4096); answer('dismiss'); events()
            for mock in [{'kind': 'password', 'host': 'h' * 4097}, {'kind': 'unknown', 'host': ''},
                         {'kind': 'card', 'host': '', 'extra': True}]:
                try:
                    app.call('save-prompt', mock=mock)
                    raise AssertionError('invalid mock was accepted')
                except RuntimeError as error:
                    assert 'invalid mock' in str(error), str(error)
            assert not state().get('visible') and not events()
        row('M-1-input-limits', input_limits)

        def early_failure_cleanup():
            events()
            try:
                show()
                raise ValueError('intentional early-exit fixture')
            except ValueError:
                pass
            finally:
                app.call('save-prompt', withdraw=True)
            assert gone() and [e['answer'] for e in events()] == ['ignored']
        row('M-6-early-exit-cleanup', early_failure_cleanup)

        events(); show()
        app.call('window-close')
        assert gone(), 'window close kept the save sheet'
        ev = events()
        results['M-5-window-close-ignored'] = {'ok': [e['answer'] for e in ev] == ['ignored'], 'answers': [e['answer'] for e in ev]}
        new_crashes = sorted(harness['_open_crash_reports']() - crashes_before)
        results['M-6-no-crash'] = {'ok': app.call('ping')['pid'] == app.pid and not new_crashes, 'newCrashReports': len(new_crashes)}
    finally:
        try:
            app.call('save-prompt', withdraw=True)
        except RuntimeError:
            pass  # No window remains after M-5.
        app.quit()  # Harness verifies every owned PID and on-screen window is gone.


def run_manage_pages(factory, results, tmp, harness):
    """MP-* rows use the real command bar and the Profiles row's action."""
    from urllib.parse import urlsplit
    wait = harness['wait_until']
    crashes_before = harness['_open_crash_reports']()
    app = factory(urls=('about:blank',), fresh=True, extra_args=['--use-mock-keychain'])
    password_url = 'chrome://password-manager/passwords'
    payment_url = 'chrome://settings/payments'

    def key(value, modifiers=()):
        return app.call('key', key=value, modifiers=list(modifiers), route='app')

    def bar_query():
        key('t', ['command'])
        assert wait(lambda: app.call('commandbar-state').get('presented'), timeout=5, step=.05)
        app.call('key', text='Manage Passwords')
        return wait(lambda: (s if (s := app.call('commandbar-state')).get('text') == 'Manage Passwords'
                             and s.get('final') else None), timeout=10, step=.05)

    def manage():
        state = bar_query()
        assert state, 'Manage Passwords query did not finish'
        index = next((i for i, r in enumerate(state['rows']) if r.get('action') == 'manage-passwords'), None)
        assert index is not None, 'Manage Passwords action absent from command bar'
        current = state['selected']
        for _ in range(abs(index - current)):
            key('down' if index > current else 'up')
        key('return')
        assert wait(lambda: not app.call('commandbar-state').get('presented'), timeout=5, step=.05)

    def focused_space():
        return next(s for s in app.call('spaces') if s['focused'])

    def same_page(actual, expected):
        a, b = urlsplit(actual), urlsplit(expected)
        return (a.scheme, a.netloc, a.path.strip('/')) == (b.scheme, b.netloc, b.path.strip('/'))

    def page(expected, space):
        tab = wait(lambda: next((t for t in app.call('tabs') if t.get('selected') and t['space'] == space
                                and same_page(t['url'], expected)
                                and same_page(t.get('page', {}).get('url', ''), expected)), None), timeout=15, step=.1)
        assert tab, 'manage page not selected in target Space'
        app.call('wait', tab=tab['id'])
        tab = app.call('tab-state', tab=tab['id'])
        assert not tab['crashed'] and tab['page']['live'] and tab['page']['browser'] != 0, 'manage page has no live hosted browser'
        assert tab['page']['style'] == 'chrome', 'manage page is not Chrome WebUI'
        assert same_page(tab['page']['url'], expected), 'hosted page did not commit the manage URL'
        return tab

    def row(name, fn):
        try:
            results[name] = {'ok': True, **(fn() or {})}
        except Exception:
            results[name] = {'ok': False}
            raise

    try:
        assert wait(lambda: app.call('tabs') and app.call('tabs')[0].get('page'), timeout=15, step=.1)
        default = focused_space()
        initial = len(app.call('tabs'))
        identity = {}

        def first():
            manage()
            tab = page(password_url, default['id'])
            assert tab['profile'] == default['profile'] and tab['section'] == 'today'
            tabs = app.call('tabs')
            assert len(tabs) == initial + 1
            assert next(t for t in tabs if t['space'] == default['id'] and t['section'] == 'today')['id'] == tab['id']
            identity['passwords'] = tab['id']
            identity['context'] = tab['page']['context']
            return {'url': password_url, 'newTodayTabs': 1, 'placement': 'top', 'entry': 'commandbar-native-return'}
        row('MP-1-commandbar', first)

        def again():
            count = len(app.call('tabs'))
            # Select another tab first, so a successful result must reselect it.
            other = next(t['id'] for t in app.call('tabs') if t['id'] != identity['passwords'])
            app.call('select', tab=other)
            manage()
            assert page(password_url, default['id'])['id'] == identity['passwords']
            assert len(app.call('tabs')) == count
            return {'sameTab': True, 'tabCountUnchanged': True}
        row('MP-2-commandbar-singleton', again)

        def settings_passwords():
            count = len(app.call('tabs'))
            for args in [dict(profile='missing', page='passwords'),
                         dict(profile=default['profile'], page='unknown'),
                         dict(profile=default['profile'], page='passwords', extra=True)]:
                try:
                    app.call('settings-profile-page', **args)
                    raise AssertionError('invalid Settings page action was accepted')
                except RuntimeError as error:
                    assert 'expected an existing profile ID and ProfilePage' in str(error), str(error)
            assert len(app.call('tabs')) == count
            app.call('select', tab=next(t['id'] for t in app.call('tabs') if t['id'] != identity['passwords']))
            app.call('settings-profile-page', profile=default['profile'], page='passwords')
            assert page(password_url, default['id'])['id'] == identity['passwords']
            assert len(app.call('tabs')) == count
            return {'sameTab': True, 'entry': 'ProfilesViewModel.open'}
        row('MP-3-settings-passwords-singleton', settings_passwords)

        def settings_cards():
            count = len(app.call('tabs'))
            app.call('settings-profile-page', profile=default['profile'], page='paymentMethods')
            tab = page(payment_url, default['id'])
            assert tab['profile'] == default['profile'] and tab['section'] == 'today'
            assert len(app.call('tabs')) == count + 1
            app.call('select', tab=identity['passwords'])
            app.call('settings-profile-page', profile=default['profile'], page='paymentMethods')
            assert page(payment_url, default['id'])['id'] == tab['id']
            assert len(app.call('tabs')) == count + 1
            return {'url': payment_url, 'sameTabOnRepeat': True}
        row('MP-4-settings-credit-cards', settings_cards)

        def second_profile():
            work_id = app.call('space-create', title='Work', profile='Work')
            work = focused_space()
            assert work['id'] == work_id and work['profile'] != default['profile']
            manage()
            tab = page(password_url, work_id)
            assert tab['profile'] == work['profile'] and tab['id'] != identity['passwords']
            assert tab['page']['context'] != identity['context'], 'manage page reused the default engine context'
            count = len(app.call('tabs'))
            app.call('space', space=default['id'])
            app.call('settings-profile-page', profile=work['profile'], page='passwords')
            assert focused_space()['id'] == work_id
            assert page(password_url, work_id)['id'] == tab['id'] and len(app.call('tabs')) == count
            return {'isolatedProfile': True, 'settingsTargetsSelectedProfile': True}
        row('MP-5-second-profile', second_profile)

        def incognito():
            app.call('menu-perform', id='new-incognito-window')
            assert wait(lambda: app.call('incognito-state', private=True).get('private'), timeout=10, step=.05)
            before = app.call('incognito-state', private=True)['tabs']
            state = bar_query()
            assert state and not any(r.get('action') == 'manage-passwords' for r in state.get('rows', []))
            key('escape')
            try:
                app.call('command', id='manage-passwords')
                raise AssertionError('private Manage Passwords command ran')
            except RuntimeError as error:
                assert 'disabled command' in str(error), str(error)
            assert app.call('incognito-state', private=True)['tabs'] == before
            app.call('window-close')
            return {'actionAbsent': True, 'directCommandDisabled': True, 'tabCountUnchanged': True}
        row('MP-6-incognito-unavailable', incognito)
        new_crashes = harness['_open_crash_reports']() - crashes_before
        results['MP-7-no-crash'] = {'ok': app.call('ping')['pid'] == app.pid and not new_crashes,
                                    'newCrashReports': len(new_crashes)}
    finally:
        app.quit()


def run(factory, results, tmp, harness):
    run_save_prompts(factory, results, tmp, harness)
    run_manage_pages(factory, results, tmp, harness)
