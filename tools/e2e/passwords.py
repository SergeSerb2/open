"""Section 15 M-* rows: synthetic metadata through the real App save sheet.

No passwords, cards, addresses, Keychain access, or engine save callbacks. P-*
rows will exercise the engine when its bridge is available.
"""
import os


def run(factory, results, tmp, harness):
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
