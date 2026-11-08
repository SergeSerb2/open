"""Real sign-in acceptance for the engine PR with main's App delegate.

Run through engine_e2e's supervised feature runner. No App save-prompt adapter
may be installed in that build. Reports contain counts and booleans only.
"""
import json
import os
import time


def run(app, results, tmp, h):
    h['begin_row']('PW-ENGINE-no-delegate')
    baseline = h['_open_crash_reports']()
    wait = h['wait_until']

    def dismissal_counts(tab):
        reply = app.call('devtools', tab=tab, method='Browser.getHistograms',
                         params={'query': 'PasswordManager.SaveUIDismissalReason', 'delta': False})
        histogram = next((x for x in reply.get('histograms', [])
                          if x.get('name') == 'PasswordManager.SaveUIDismissalReason'), {})
        return {int(x['low']): int(x['count']) for x in histogram.get('buckets', [])}

    with h['passwords_fixture_server']() as urls:
        tab = h['new_tab'](app, urls['local_login'])
        assert wait(lambda: app.eval(tab, 'document.readyState === "complete" && !!document.querySelector("#submit")'), timeout=15, step=.1)
        before = dismissal_counts(tab)
        old_windows = {w['number'] for w in app.call('windows') if w.get('visible')}
        app.call('focus', tab=tab)
        fields = app.eval(tab, 'Array.from(document.querySelectorAll("input[data-fixture]")).map(e => e.id)')
        assert fields
        for field in fields:
            app.call('click', tab=tab, selector='#'+field)
            value = app.eval(tab, 'document.getElementById(%s).dataset.fixture' % json.dumps(field))
            app.call('key', text=value, route='app')
            del value
        app.call('click', tab=tab, selector='#submit')
        assert wait(lambda: app.eval(tab, 'location.pathname === "/welcome"'), timeout=10, step=.1)
        # Chromium logs NO_DIRECT_INTERACTION (0) when the ignored bridge offer
        # closes its SaveUpdateBubbleController. A missing form would not emit it.
        assert wait(lambda: dismissal_counts(tab).get(0, 0) == before.get(0, 0)+1, timeout=10, step=.1), 'save offer did not finish as ignored'
        deadline = time.monotonic()+2
        while time.monotonic() < deadline:
            assert not app.call('save-prompt', state=True).get('visible'), 'main App showed a save sheet'
            assert not any(w.get('visible') and w['number'] not in old_windows for w in app.call('windows')), 'Chromium showed a save bubble'
            assert app.call('ping')['pid'] == app.pid
            assert not h['_open_crash_reports']()-baseline
            time.sleep(.1)
        after = dismissal_counts(tab)
        assert all(after.get(k, 0) == before.get(k, 0) for k in set(before)|set(after) if k != 0)
        results['PW-ENGINE-no-delegate'] = {'ok': True, 'signInSubmitted': True,
            'ignoredOffers': 1, 'noDirectInteractionBucket': 0, 'sheetVisible': False,
            'chromiumBubbleVisible': False, 'appAlive': True, 'newCrashReports': 0,
            'load': os.getloadavg()}
