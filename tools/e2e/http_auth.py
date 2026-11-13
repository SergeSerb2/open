"""PW-11: real network challenges and Open sheets; synthetic credentials only.

No request values, field values or server headers enter the result receipt.
"""
from pathlib import Path
import re

ROWS = {
    'PW-AUTH-submit', 'PW-AUTH-return', 'PW-AUTH-cancel', 'PW-AUTH-retry',
    'PW-AUTH-tab-close', 'PW-AUTH-navigate', 'PW-AUTH-window-close',
    'PW-AUTH-quit', 'PW-AUTH-save-refill', 'PW-AUTH-cleanup',
}


class IntentionalAuthExit(Exception):
    pass


def run(factory, results, tmp, h, guard, row_ids=None):
    wait = h['wait_until']
    app = None
    source = Path(h['ROOT']) / 'tools/e2e/fixtures/passwords/server.py'
    # Test-only public fixtures, read without printing or retaining in receipts.
    fixture = source.read_text()
    username = re.search(r"^USERNAME = '([^']+)'", fixture, re.M).group(1)
    password = re.search(r"^PASSWORD = '([^']+)'", fixture, re.M).group(1)

    def state():
        return app.call('http-auth', state=True)

    def gone():
        assert wait(lambda: not state().get('visible'), timeout=5, step=.05), 'auth sheet did not close'

    def key(name, **kw):
        app.call('key', window=state()['window'], key=name, route='app', **kw)

    def type_field(field, value):
        app.call('http-auth', focus=field)
        key('a', modifiers=['command'])
        app.call('key', window=state()['window'], text=value, route='app')

    def enter_credentials(correct=True):
        type_field('username', username)
        type_field('password', password if correct else 'rejected-fixture-password')

    def authenticated(tab):
        assert wait(lambda: app.eval(tab, '!!document.getElementById("authenticated")'),
                    timeout=10, step=.1), 'server did not accept authentication'

    def show(origin):
        tab = app.call('open', url=origin + '/basic-login')['id']
        sheet = wait(lambda: (s if (s := state()).get('visible') else None), timeout=10, step=.05)
        assert sheet, 'Open HTTP authentication sheet did not appear'
        windows = app.call('windows')
        matches = [w for w in windows if w.get('visible') and w['number'] == sheet['window']
                   and w.get('class', '').endswith('HTTPAuthSheet')]
        assert len(matches) == 1 and sheet['parent'] > 0, 'specific Open sheet is not attached'
        assert not [w for w in windows if w.get('visible') and w.get('parent') == sheet['parent']
                    and w.get('class') == 'NativeWidgetMacNSWindow'], 'Chromium auth dialog also appeared'
        return tab, sheet

    with h['passwords_fixture_server']() as urls:
        origin = 'http://127.0.0.1:%d' % urls['port']
        switches = ['--no-proxy-server', '--use-mock-keychain', '--open-allow-mock-keychain-secrets']

        def launch(fresh=True):
            nonlocal app
            app = factory(urls=('about:blank',), fresh=fresh, extra_args=switches)
            assert wait(lambda: app.call('tabs'), timeout=10, step=.1), 'fresh window not ready'
            app.call('policy', savePrompt='hold')

        def flow(name):
            launch()
            tab, sheet = show(origin)
            if name in ('PW-AUTH-submit', 'PW-AUTH-return'):
                enter_credentials()
                before = len(app.call('tabs'))
                for command in ('t', 'l', 'w'):
                    key(command, modifiers=['command'])
                    assert state().get('visible'), 'browser shortcut displaced the auth sheet'
                    assert len(app.call('tabs')) == before, 'browser shortcut changed tabs behind auth sheet'
                if name == 'PW-AUTH-return':
                    key('return')
                else:
                    app.call('http-auth', answer='accept')
                gone(); authenticated(tab)
                return {'networkAccepted': True, 'browserShortcutsBlocked': True,
                        'keyPath': 'NSApplication.sendEvent' if name.endswith('return') else 'NSButton.performClick'}
            if name == 'PW-AUTH-cancel':
                key('escape'); gone()
                assert wait(lambda: app.eval(tab, 'document.readyState === "complete"'), timeout=10, step=.1)
                assert not app.eval(tab, '!!document.getElementById("authenticated")'), 'cancel authenticated the request'
                assert not app.call('save-prompt', state=True).get('visible'), 'cancel offered to save credentials'
                return {'cancelKeyPath': 'NSApplication.sendEvent', 'noSaveOffer': True}
            if name == 'PW-AUTH-retry':
                enter_credentials(correct=False)
                app.call('http-auth', answer='accept')
                retry = wait(lambda: (s if (s := state()).get('visible') and s['window'] != sheet['window'] else None),
                             timeout=10, step=.05)
                assert retry, 'rejected credentials did not produce a fresh challenge'
                assert not retry['passwordPresent'], 'retry retained the rejected password'
                app.call('http-auth', answer='cancel'); gone()
                return {'freshChallengeAfterRejection': True, 'rejectedPasswordCleared': True}
            if name == 'PW-AUTH-tab-close':
                app.call('close', tab=tab); gone()
                assert not any(t['id'] == tab for t in app.call('tabs')), 'challenged tab stayed open'
                return {'tabClosed': True, 'sheetClosed': True}
            if name == 'PW-AUTH-navigate':
                app.call('navigate', tab=tab, url=origin + '/welcome'); gone()
                assert wait(lambda: app.eval(tab, '!!document.getElementById("welcome")'), timeout=10, step=.1)
                return {'staleChallengeClosed': True, 'navigationFinished': True}
            if name == 'PW-AUTH-window-close':
                app.call('window-close')
                assert wait(lambda: not [w for w in app.call('windows') if w.get('visible')
                                        and w['number'] in (sheet['window'], sheet['parent'])], timeout=5, step=.1)
                return {'parentAndSheetClosed': True}
            if name in ('PW-AUTH-quit', 'PW-AUTH-cleanup'):
                if name.endswith('cleanup'):
                    try:
                        raise IntentionalAuthExit('intentional early exit with the real auth sheet open')
                    finally:
                        app.quit()
                app.quit()
                return {'quitWithChallengeOpen': True}
            if name == 'PW-AUTH-save-refill':
                enter_credentials(); key('return'); gone(); authenticated(tab)
                save = wait(lambda: (s if (s := app.call('save-prompt', state=True)).get('visible') else None),
                            timeout=10, step=.1)
                assert save and save.get('kind') == 'password', 'HTTP auth did not offer password save'
                app.call('save-prompt', answer='save')
                assert wait(lambda: app.call('credentials')['logins'] == 1, timeout=10, step=.1), 'password was not stored'
                app.quit(); launch(fresh=False)
                tab, _ = show(origin)
                assert wait(lambda: (lambda s: s.get('autofilled') and s.get('usernamePresent') and s.get('passwordPresent'))(state()),
                            timeout=10, step=.1), 'saved HTTP credentials did not fill the real auth sheet'
                key('return'); gone(); authenticated(tab)
                return {'savedLoginCount': 1, 'restarted': True, 'passwordManagerFilled': True, 'networkAcceptedAfterRefill': True}
            raise AssertionError('unknown HTTP-auth flow')

        for name in sorted(ROWS if row_ids is None else ROWS.intersection(row_ids)):
            h['begin_row'](name)
            guard.check()
            try:
                detail = flow(name)
                guard.check(); results[name] = {'ok': True, **detail}
            except h['FocusInterruption']:
                raise
            except IntentionalAuthExit:
                guard.check(); results[name] = {'ok': True, 'intentionalEarlyExit': True, 'ownedAppCleaned': True}
            except Exception as error:
                guard.check()
                reason = str(error) if isinstance(error, AssertionError) and error.args else 'HTTP auth flow failed'
                results[name] = {'ok': False, 'reason': reason, 'errorType': type(error).__name__}
            finally:
                if app and not app.closed:
                    app.quit()
