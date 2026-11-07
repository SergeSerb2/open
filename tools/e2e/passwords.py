"""Section 15 real-sheet, management, engine and cookie acceptance.

Field values stay in fixture documents or temporary comparisons. Reports contain
booleans, counts, fixture hosts and public UI text only.
"""
import os
import json
import signal
import sqlite3
import time
from pathlib import Path

def autofill_child_windows(app):
    """Window metadata only; no accessibility or field values."""
    return [w for w in app.call('windows') if w.get('visible') and w.get('parent', 0) and not w.get('sheet')]


def show_autofill_dropdown(app, tab, wait_until, selector='#username', timeout=5):
    """Click the actual field; return newly visible native child metadata."""
    before = {w['number'] for w in autofill_child_windows(app)}
    app.call('focus', tab=tab)
    app.call('click', tab=tab, selector=selector)
    return wait_until(lambda: [w for w in autofill_child_windows(app) if w['number'] not in before], timeout=timeout, step=.05)


def fill_from_dropdown(app, tab, wait_until, selector='#username', down=1):
    """Choose a native suggestion through real App keys. Caller checks equality."""
    assert show_autofill_dropdown(app, tab, wait_until, selector), 'autofill dropdown did not appear after a field click'
    for _ in range(down):
        app.call('key', key='down', route='app')
    app.call('key', key='return', route='app')
    return True


class PasswordAppDied(RuntimeError):
    fatal_app_death = True


class PasswordGuard:
    """Check every row, including inherited M/MP rows, before publishing it."""
    def __init__(self, factory, results, harness):
        self.factory, self.results, self.h = factory, results, harness
        self.baseline = harness['_open_crash_reports']()
        self.app = None

    def launch(self, *args, **kwargs):
        self.check()
        self.app = self.factory(*args, **kwargs)
        return self.app

    def check(self):
        crashes = self.h['_open_crash_reports']() - self.baseline
        if crashes:
            raise PasswordAppDied('new Open crash report; stopped before the next flow')
        if self.app and not self.app.closed:
            try:
                os.kill(self.app.pid, 0)
                assert self.app.call('ping', timeout=3)['pid'] == self.app.pid
            except Exception as error:
                raise PasswordAppDied('Open stopped answering; suite stopped at first App death') from error

    def __setitem__(self, name, result):
        try:
            self.check()
        except PasswordAppDied:
            self.results[name] = {'ok': False, 'reason': 'App death or new crash report', 'load': os.getloadavg()}
            raise
        self.results[name] = dict(result, newCrashReports=0, load=os.getloadavg())


class PasswordBlocked(RuntimeError):
    pass


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


def run_engine(factory, results, tmp, h, guard, engine_distribution_sha256):
    wait = h['wait_until']
    app = None
    passed = set()
    fixture_root = Path(h['ROOT']) / 'tools/e2e/fixtures/passwords'

    def row(name, flow, requires=()):
        guard.check()
        if any(r not in passed for r in requires):
            results[name] = {'status': 'BLOCKED', 'reason': 'requires passing ' + ', '.join(requires)}
            return
        try:
            detail = flow() or {}
            guard.check()
            results[name] = {'ok': True, **detail}
            passed.add(name)
        except PasswordAppDied:
            raise
        except h['FocusInterruption']:
            raise
        except PasswordBlocked as error:
            results[name] = {'status': 'BLOCKED', 'reason': str(error)}
        except Exception as error:
            guard.check()
            # No arbitrary exception payloads (a browser error can echo input).
            results[name] = {'ok': False, 'reason': 'flow assertion failed', 'errorType': type(error).__name__}
        finally:
            if app and not app.closed:
                try:
                    app.call('save-prompt', withdraw=True)
                    app.call('key', key='escape', route='app')
                except Exception:
                    guard.check()

    def key(value, **kwargs):
        return app.call('key', key=value, route='app', **kwargs)

    def dev(tab, method, **params):
        return app.call('devtools', tab=tab, method=method, params=params)

    def sheet():
        return app.call('save-prompt', state=True)

    def events():
        return app.call('events')

    def load(url):
        tab = h['new_tab'](app, url)
        assert wait(lambda: app.eval(tab, 'document.readyState === "complete"'), timeout=15, step=.1)
        return tab

    def fill(tab):
        app.call('focus', tab=tab)
        fields = app.eval(tab, 'Array.from(document.querySelectorAll("input[data-fixture]")).map(e => e.id)')
        for field in fields:
            app.call('click', tab=tab, selector='#' + field)
            text = app.eval(tab, 'document.getElementById(%s).dataset.fixture' % json.dumps(field))
            app.call('key', text=text, route='app')
            del text
        assert app.eval(tab, 'Array.from(document.querySelectorAll("input[data-fixture]")).every(e => e.value === e.dataset.fixture)')

    def submit(tab):
        app.call('click', tab=tab, selector='#submit')
        assert wait(lambda: app.eval(tab, 'location.pathname === "/welcome"'), timeout=10, step=.1)

    def prompt(kind, url, answer=None):
        events()
        tab = load(url); fill(tab); submit(tab)
        value = wait(lambda: (s if (s := sheet()).get('visible') else None), timeout=5, step=.05)
        assert value and value['kind'] == kind
        assert any(e.get('type') == 'savePrompt' and e.get('kind') == kind and e.get('answer') == 'pending' for e in events())
        if answer:
            app.call('save-prompt', answer=answer)
            assert wait(lambda: not sheet().get('visible'), timeout=5, step=.05)
            assert any(e.get('type') == 'savePrompt' and e.get('answer') == answer for e in events())
        return tab, value

    def counts(**expected):
        def matching():
            current = app.call('credentials')
            return current if all(current.get(k) == v for k, v in expected.items()) else None
        value = wait(matching, timeout=10, step=.1)
        assert value
        return {k: value[k] for k in expected}

    def children():
        return autofill_child_windows(app)

    def popup(tab, selector='#username'):
        return show_autofill_dropdown(app, tab, wait, selector)

    def choose():
        key('down'); key('return')

    def empty(tab):
        return app.eval(tab, 'Array.from(document.querySelectorAll("input[data-fixture]")).every(e => e.value === "")')

    def fields_match(tab, ids, changed=False):
        script = '''(() => {const ids=%s; return ids.every(id => {
          const e=document.getElementById(id); let expected=e.dataset.fixture;
          if (%s && id==='password') expected=%s;
          if (id==='expiry') {const a=e.value.replace(/\\D/g,''),b=expected.replace(/\\D/g,'');return a===b||a===b.slice(0,2)+b.slice(-2);}
          return e.value.replace(/\\s/g,'')===expected.replace(/\\s/g,''); });})()'''
        # The updated fixture value is read from our source, never printed.
        import re
        updated = re.search(r'id="password"[^>]*data-fixture="([^"]+)"', (fixture_root / 'change.html').read_text()).group(1)
        return app.eval(tab, script % (json.dumps(ids), 'true' if changed else 'false', json.dumps(updated)))

    def no_prompt(url, profile=None):
        app.call('policy', savePrompt='hold'); events()
        tab = load(url); fill(tab); submit(tab)
        deadline = time.monotonic() + 1.5
        while time.monotonic() < deadline:
            assert not sheet().get('visible')
            assert not any(e.get('type') == 'savePrompt' for e in events())
            time.sleep(.1)
        return {'sheetVisible': False}

    with h['passwords_fixture_server']() as urls:
        switches = urls['engine_switches'] + ['--use-mock-keychain', '--open-allow-mock-keychain-secrets']

        def launch(fresh=False, allow=True):
            nonlocal app
            app = factory(urls=('about:blank',), fresh=fresh, extra_args=switches if allow else [s for s in switches if s != '--open-allow-mock-keychain-secrets'])
            assert wait(lambda: app.call('tabs'), timeout=15, step=.1)
            app.call('policy', savePrompt='hold')
            return app

        def relaunch(allow=True):
            app.quit(); launch(allow=allow)

        launch(fresh=True)
        identity = {}
        try:
            def first():
                tab, value = prompt('password', urls['login'])
                assert value['title'] == 'Save password for login.example.com?'
                assert value['buttons'] == ['Never on this site', 'No', 'Save']
                app.call('snapshot', window=value['window'], path=os.path.join(tmp, 'P-1-save-sheet.png'))
                identity['login'] = tab
                # P-2 owns the button press. Hold across this one row boundary.
                identity['held'] = value
                return {'kind': 'password', 'displayHost': 'login.example.com', 'sheetVisible': True}
            # Do not use row's per-flow withdrawal between P-1 and P-2.
            def first_and_save():
                detail = first()
                results['P-1'] = {'ok': True, **detail}; passed.add('P-1')
                app.call('save-prompt', answer='save')
                assert wait(lambda: not sheet().get('visible'), timeout=5, step=.05)
                return counts(logins=1)
            row('P-2', first_and_save)
            if 'P-1' not in passed:
                results['P-1'] = {'ok': False, 'reason': 'real password prompt did not appear'}

            def dropdown():
                tab = load(urls['login']); identity['refill'] = tab
                assert empty(tab)
                windows = popup(tab); assert windows
                # Empty form + masked dropdown; never snapshot filled data.
                app.call('snapshot', window=windows[0]['number'], path=os.path.join(tmp, 'P-3-dropdown.png'))
                return {'childWindowVisible': True}
            row('P-3', dropdown, ['P-2'])

            def refill():
                tab = identity['refill']; assert popup(tab)
                choose(); assert fields_match(tab, ['username', 'password'])
                return {'bothFieldsMatch': True, 'inputRoute': 'app'}
            row('P-4', refill, ['P-3'])

            def update():
                _, value = prompt('passwordUpdate', urls['change'], 'save')
                assert value['buttons'] == ['No', 'Save']
                tab = load(urls['login']); assert popup(tab); choose()
                assert fields_match(tab, ['username', 'password'], changed=True)
                return {'updatedValueMatches': True, 'offersNever': False}
            row('P-5', update, ['P-4'])

            def never():
                other = urls['login'].replace('login.example.com', 'never.example.com')
                prompt('password', other, 'never'); counts(blockedSites=1)
                return no_prompt(other)
            row('P-6', never)
            def no_automatic_fill():
                assert empty(load(urls['login'])), 'fields filled before a dropdown choice'
                return {'emptyOnLoad': True}
            row('P-7', no_automatic_fill, ['P-2'])

            def iframe():
                tab = load(urls['iframe'])
                frame = dev(tab, 'Page.getFrameTree')['frameTree']['childFrames'][0]['frame']['id']
                context = dev(tab, 'Page.createIsolatedWorld', frameId=frame, worldName='OpenPasswordFixture')['executionContextId']
                result = dev(tab, 'Runtime.evaluate', contextId=context, expression='Array.from(document.querySelectorAll("input")).every(e=>!e.value)', returnByValue=True)
                assert result['result']['value'] is True
                geometry = dev(tab, 'Runtime.evaluate', contextId=context, expression='(()=>{let r=document.querySelector("#username").getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()', returnByValue=True)['result']['value']
                offset = app.eval(tab, '(()=>{const r=document.querySelector("iframe").getBoundingClientRect();return [r.x+2,r.y+2]})()')
                for event in ['mousePressed', 'mouseReleased']:
                    dev(tab, 'Input.dispatchMouseEvent', type=event, x=geometry[0]+offset[0], y=geometry[1]+offset[1], button='left', clickCount=1)
                assert wait(children, timeout=5, step=.05)
                return {'emptyOnLoad': True, 'dropdownAfterClick': True}
            row('P-8', iframe, ['P-2'])

            row('P-9', lambda: (prompt('address', urls['address'], 'save'), counts(addresses=1))[1])
            def address_fill():
                tab = load(urls['address']); assert popup(tab, '#name'); choose()
                assert fields_match(tab, ['name', 'street', 'city', 'postal'])
                return {'addressFieldsMatch': True}
            row('P-10', address_fill, ['P-9'])
            row('P-11', lambda: (prompt('card', urls['card'], 'save'), counts(cards=1))[1])
            def card_fill():
                tab = load(urls['card']); assert popup(tab, '#number'); choose()
                assert fields_match(tab, ['name', 'number', 'expiry'])
                return {'cardFieldsMatch': True}
            row('P-12', card_fill, ['P-11'])

            def manage():
                key('t', modifiers=['command']); app.call('key', text='Manage Passwords', route='app')
                state = wait(lambda: (s if (s := app.call('commandbar-state')).get('final') else None), timeout=10, step=.1)
                index = next(i for i, r in enumerate(state['rows']) if r.get('action') == 'manage-passwords')
                for _ in range(abs(index-state['selected'])): key('down' if index > state['selected'] else 'up')
                key('return')
                tab = wait(lambda: next((t for t in app.call('tabs') if t.get('selected') and t['url'].startswith('chrome://password-manager/passwords')), None), timeout=10, step=.1)
                assert tab; identity['manage'] = tab['id']
                # Traverse open shadow roots and report a row COUNT only.
                script = '''(()=>{let n=0;const walk=r=>{for(const e of r.querySelectorAll('*')){if(e.localName==='password-list-item')n++;if(e.shadowRoot)walk(e.shadowRoot)}};walk(document);return n})()'''
                assert wait(lambda: app.eval(tab['id'], script) == 1, timeout=10, step=.1)
                return {'passwordRows': 1, 'entry': 'commandbar-native-return'}
            row('P-13', manage, ['P-2'])

            def footer():
                tab = load(urls['login']); assert popup(tab); events()
                # Password dropdown has one fixture entry followed by its footer.
                key('down'); key('down'); key('return')
                assert wait(lambda: any(e.get('type') == 'autofillPage' and e.get('page') == 'passwords' for e in events()), timeout=5, step=.1)
                selected = next(t for t in app.call('tabs') if t.get('selected'))
                assert selected['id'] == identity['manage']
                return {'autofillPage': 'passwords', 'sameTab': True}
            row('P-14', footer, ['P-13'])

            def popup_dismissal():
                tab = load(urls['login']); assert popup(tab)
                key('t', modifiers=['command'])
                assert wait(lambda: not children(), timeout=5, step=.05); key('escape')
                assert popup(tab); default = next(s for s in app.call('spaces') if s['focused'])
                work = app.call('space-create', title='Work', profile='Work'); identity['default'] = default['id']; identity['work'] = work
                assert wait(lambda: not children(), timeout=5, step=.05)
                app.call('space', space=default['id']); app.call('select', tab=tab); assert popup(tab)
                key('s', modifiers=['command'])
                assert wait(lambda: not children(), timeout=5, step=.05)
                key('s', modifiers=['command'])
                return {'commandbar': True, 'SpaceChange': True, 'sidebarHide': True}
            row('P-16', popup_dismissal, ['P-2'])

            def profile_isolation():
                work = identity.get('work') or app.call('space-create', title='Work', profile='Work')
                identity['work'] = work; app.call('space', space=work)
                assert app.call('credentials', profile='Work')['logins'] == 0
                tab = load(urls['login']); assert empty(tab)
                app.call('click', tab=tab, selector='#username')
                time.sleep(.5); assert not children()
                return {'logins': 0, 'dropdownVisible': False}
            row('P-17', profile_isolation, ['P-2'])

            def at_rest():
                # Read copies of this suite's synthetic data only.
                paths = list((Path(app.user_data)/'Engine').rglob('Login Data'))
                assert paths
                import re
                fixture = re.search(r'id="password"[^>]*data-fixture="([^"]+)"', (fixture_root/'login.html').read_text()).group(1).encode()
                checked = 0
                for index, path in enumerate(paths):
                    assert path.parent.stat().st_mode & 0o777 == 0o700
                    copy = Path(tmp)/('login-data-%d.sqlite' % index)
                    source = sqlite3.connect('file:'+str(path)+'?mode=ro', uri=True)
                    with sqlite3.connect(copy) as database:
                        source.backup(database)
                        blobs = database.execute('select password_value from logins where blacklisted_by_user=0').fetchall()
                        assert all(bytes(b[0]).startswith(b'v10') for b in blobs)
                        checked += len(blobs)
                    source.close(); assert fixture not in copy.read_bytes()
                assert checked >= 1
                return {'encryptedLogins': checked, 'profileMode': '0700', 'fixtureBytesAbsent': True}
            row('P-18', at_rest, ['P-2'])

            def private():
                app.call('menu-perform', id='new-incognito-window')
                assert wait(lambda: app.call('incognito-state', private=True).get('private'), timeout=10, step=.1)
                try: return no_prompt(urls['login'].replace('login.example.com', 'private.example.com'))
                finally: app.call('window-close')
            row('P-19', private)

            def virtual_authenticator():
                tab = load(urls['webauthn'])
                dev(tab, 'WebAuthn.enable')
                auth = dev(tab, 'WebAuthn.addVirtualAuthenticator', options={'protocol': 'ctap2', 'transport': 'usb', 'hasResidentKey': True, 'hasUserVerification': True, 'isUserVerified': True})['authenticatorId']
                try:
                    for operation in ['create', 'get']:
                        app.call('click', tab=tab, selector='#'+operation)
                        assert wait(lambda: app.eval(tab, 'document.querySelector("#result").textContent') == 'resolved', timeout=5, step=.05)
                finally:
                    dev(tab, 'WebAuthn.removeVirtualAuthenticator', authenticatorId=auth)
                    dev(tab, 'WebAuthn.disable')
                return {'create': 'resolved', 'get': 'resolved'}
            row('P-20', virtual_authenticator)

            def native_webauthn():
                tab = load(urls['webauthn']); before = {w['number'] for w in children()}
                app.call('click', tab=tab, selector='#create')
                child = wait(lambda: next((w for w in children() if w['number'] not in before), None), timeout=3, step=.05)
                if not child:
                    raise PasswordBlocked('H-7 WebAuthn native dialog is unavailable in this engine distribution')
                try:
                    app.call('snapshot', window=child['number'], path=os.path.join(tmp, 'P-21-webauthn.png'))
                    key('escape', window=child['number'])
                    assert wait(lambda: app.eval(tab, 'document.querySelector("#result").textContent') == 'NotAllowedError', timeout=5, step=.05)
                finally: app.call('dismiss')
                return {'childWindowVisible': True, 'rejection': 'NotAllowedError'}
            row('P-21', native_webauthn)

            def credential_manager():
                app.call('space', space=identity.get('default') or app.call('spaces')[0]['id'])
                tab = load(urls['login']); before = len(children())
                value = app.eval(tab, '''Promise.race([navigator.credentials.get({password:true}).then(x=>x===null?'null':'unexpected'),new Promise(r=>setTimeout(()=>r('timeout'),2000))])''')
                assert value == 'null' and len(children()) == before
                return {'result': 'null', 'dialogVisible': False}
            row('P-23', credential_manager, ['P-2'])

            def switches_off():
                app.call('space', space=identity.get('default') or app.call('spaces')[0]['id'])
                prefs = app.call('credentials-prefs', passwordSaving=False)
                assert prefs['passwordSaving'] is False
                return no_prompt(urls['login'].replace('login.example.com', 'saving-off.example.com'))
            row('PW-SW1', switches_off)
            def persists():
                relaunch()
                assert app.call('credentials-prefs', profile='Default')['passwordSaving'] is False
                return no_prompt(urls['login'].replace('login.example.com', 'saving-persist.example.com'))
            row('PW-SW2', persists, ['PW-SW1'])
            def switch_profiles():
                app.call('credentials-prefs', profile='Default', passwordSaving=True)
                if not identity.get('work'): identity['work'] = app.call('space-create', title='Work', profile='Work')
                app.call('credentials-prefs', profile='Work', passwordSaving=False)
                assert app.call('credentials-prefs', profile='Default')['passwordSaving'] is True
                app.call('space', space=identity['work'])
                no_prompt(urls['login'].replace('login.example.com', 'work-saving-off.example.com'))
                app.call('space', space=identity.get('default') or app.call('spaces')[0]['id'])
                prompt('password', urls['login'].replace('login.example.com', 'default-saving-on.example.com'), 'dismiss')
                return {'Work': False, 'Default': True, 'enginePromptsFollowPrefs': True}
            row('PW-SW3', switch_profiles, ['PW-SW1'])

            def auto_policy(policy):
                app.call('space', space=identity.get('default') or app.call('spaces')[0]['id'])
                app.call('credentials-prefs', profile='Default', passwordSaving=True)
                before = app.call('credentials')['logins']; events()
                app.call('policy', savePrompt=policy)
                try:
                    url = urls['login'].replace('login.example.com', 'policy-'+policy+'.example.com')
                    tab = load(url); fill(tab); submit(tab)
                    expected = 'dismiss' if policy == 'record' else policy
                    seen = []
                    def answered():
                        seen.extend(e for e in events() if e.get('type') == 'savePrompt')
                        return any(e.get('answer') == expected for e in seen)
                    assert wait(answered, timeout=5, step=.05), 'automatic real-sheet answer was not recorded'
                    assert any(e.get('answer') == 'pending' for e in seen), 'real engine prompt was not recorded'
                    assert wait(lambda: not sheet().get('visible'), timeout=5, step=.05)
                    counts(logins=before+(1 if policy == 'save' else 0))
                    return {'policy': policy, 'answer': expected, 'realSheetButton': True}
                finally: app.call('policy', savePrompt='hold')
            for policy in ['record', 'save', 'never', 'dismiss']:
                row('PW-POLICY-'+policy, lambda policy=policy: auto_policy(policy))

            def mock_guard():
                before = app.call('credentials', profile='Default')['logins']
                relaunch(allow=False)
                assert app.call('credentials-prefs', profile='Default')['canEnablePasswordSaving'] is False
                no_prompt(urls['login'].replace('login.example.com', 'mock-blocked.example.com'))
                assert app.call('credentials', profile='Default')['logins'] == before
                return {'canEnablePasswordSaving': False, 'loginsUnchanged': True}
            row('P-22', mock_guard)

            def cookie_names():
                tab = load(urls['echo_cookies'])
                names = app.eval(tab, 'JSON.parse(document.body.innerText)')
                assert set(['oe_persist', 'oe_session', 'oe_lax']).issubset(names)
                return {'cookieNamesPresent': 3}
            def cookies_graceful():
                load(urls['set_cookies']); relaunch(allow=False)
                return cookie_names()
            row('C-1', cookies_graceful)
            def cookies_killed():
                load(urls['set_cookies'])
                deadline = time.monotonic()+35
                while time.monotonic() < deadline:
                    guard.check(); time.sleep(.5)
                app.discover_owned_processes(); os.kill(app.pid, signal.SIGKILL)
                app.quit(); launch(allow=False)
                return cookie_names()
            row('C-2', cookies_killed)
            def encrypted_cookies():
                paths = list((Path(app.user_data)/'Engine').rglob('Cookies')); assert paths
                checked = 0
                for index, path in enumerate(paths):
                    source = sqlite3.connect('file:'+str(path)+'?mode=ro', uri=True)
                    with sqlite3.connect(Path(tmp)/('cookies-%d.sqlite' % index)) as database:
                        source.backup(database)
                        records = database.execute("select value,encrypted_value from cookies where name in ('oe_persist','oe_session','oe_lax')").fetchall()
                        assert all(value == '' and bytes(blob).startswith(b'v10') for value, blob in records)
                        checked += len(records)
                    source.close()
                assert checked >= 3
                return {'encryptedCookies': checked, 'plaintextValuesEmpty': True}
            row('C-3', encrypted_cookies, ['C-1'])
            results['PW-KC1'] = {'status': 'BLOCKED', 'reason': 'No synthetic Keychain-error injection API; real Keychain access is prohibited by CHILD-RULES rule 6'}
            def https_first():
                if not app.call('credentials')['supportsSecretsImport']:
                    raise PasswordBlocked('running engine has no 08xx capability (supportsSecretsImport is false)')
                settings = load('chrome://settings/security')
                enabled = app.eval(settings, '''new Promise(resolve => chrome.settingsPrivate.setPref('https_only_mode_enabled', true, '', success => resolve(success === true)))''')
                assert enabled, 'could not enable HTTPS-First in the disposable profile'
                before = {w['number'] for w in children()}
                url = urls['login'].replace('login.example.com', 'https-first.example.com')
                tab = app.call('open', url=url)['id']

                def warning():
                    child = next((w for w in children() if w['number'] not in before), None)
                    if child:
                        return ('dialog', child)
                    try:
                        if app.eval(tab, '!!document.querySelector("#proceed-button, #proceed-link")'):
                            return ('interstitial', None)
                    except RuntimeError:
                        guard.check()
                    return None

                shown = wait(warning, timeout=20, step=.1)
                assert shown, 'HTTPS-First did not show a warning'
                if shown[0] == 'dialog':
                    window = shown[1]['number']
                    texts = next(w.get('text', []) for w in app.call('windows', accessibility=True) if w['number'] == window)
                    import re
                    assert any(re.search(r'HTTPS|secure connection|[Cc]ontinue', text) for text in texts), 'new child was not the HTTPS warning'
                    app.call('snapshot', window=window, path=os.path.join(tmp, 'PW-HF1-warning.png'))
                    key('return', window=window)
                else:
                    app.call('snapshot', path=os.path.join(tmp, 'PW-HF1-warning.png'))
                    app.call('click', tab=tab, selector='#proceed-button, #proceed-link')
                assert wait(lambda: app.eval(tab, 'location.hostname === "https-first.example.com" && !!document.querySelector("#username")'), timeout=15, step=.1), 'Continue did not load the fixture'
                return {'warning': shown[0], 'continuedToFixture': True, 'distributionSHA256': engine_distribution_sha256}
            row('PW-HF1', https_first)
            guard.check(); results['P-15'] = {'ok': True, 'allExecutedRowsAlive': True}
        finally:
            if app: app.quit()


def run(factory, results, tmp, harness, engine_distribution_sha256=None):
    guard = PasswordGuard(factory, results, harness)
    run_save_prompts(guard.launch, guard, tmp, harness)
    run_manage_pages(guard.launch, guard, tmp, harness)
    run_engine(guard.launch, guard, tmp, harness, guard, engine_distribution_sha256)
