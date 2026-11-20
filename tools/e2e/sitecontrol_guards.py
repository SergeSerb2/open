"""SCC action guards through the real App, panel callbacks, native menu and engine.

G1: a click drawn for one origin must not act on the origin the tab shows later
(a redirect can land between drawing the panel and receiving the click).
G2: the ad-block tile on a one-word host cannot be changed (its exclusion has no
registrable domain to store), so it is disabled instead of failing to save.
G3: content tiles toggled in a tab that closed are forgotten.
"""
import hashlib
import os
from pathlib import Path


def run(factory, results, origin, tmp, env):
    wait, new_tab = env['wait_until'], env['new_tab']
    port = origin.rsplit(':', 1)[1]
    # One-word host and a second registrable site, both on the fixture server.
    a_origin, b_origin, word_origin = origin, 'http://b.guard.test:' + port, 'http://intranet:' + port
    args = ['--host-resolver-rules=MAP demand.supply 127.0.0.1:%s, MAP *.guard.test 127.0.0.1, MAP intranet 127.0.0.1' % port,
            '--no-proxy-server']
    app, saved = None, {}

    def record(key, ok, **detail):
        results[key] = dict(ok=bool(ok), load=list(os.getloadavg()), **detail)
        print(key, 'PASS' if ok else 'FAIL', flush=True)
    try:
        app = factory(urls=('about:blank',), fresh=True, load_extensions=False, extra_args=args)
        for key, value in {'open.advanced.playSoundEffects': False, 'open.advanced.showToolbar': False}.items():
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=value)
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        tab = new_tab(app, a_origin + '/ads.html')

        def state(): return app.call('site-controls')
        def close():
            if state()['presented']: app.call('site-controls', action='close')
        def opened():
            close(); return app.call('site-controls', action='open')
        def row(s, identifier): return next((r for r in s['rows'] if r['id'] == identifier), {})
        def visit(url):
            app.call('select', tab=tab); app.call('navigate', tab=tab, url=url); app.call('wait', tab=tab)
        def settings(o): return {x['kind']: x['state'] for x in app.call('site-settings', tab=tab, origin=o)}
        def refused(**kw):
            try: app.call('site-controls', **kw); return False
            except RuntimeError: return True

        # G1: draw the panel on A, then let the same tab land on B before the click.
        app.call('site-setting', tab=tab, origin=a_origin, kind='popups', state='allow')
        visit(a_origin + '/ads.html')
        drawn = opened()
        app.call('site-controls', action='capture-tile', id='row.content.popups')
        app.call('site-controls', action='capture-menu')
        visit(b_origin + '/ads.html')
        app.eval(tab, "document.cookie='g=1';true")
        refreshed = wait(lambda: (lambda s: s if s['presented'] and s['host'] == 'b.guard.test' else None)(state()), timeout=8)
        a_before, b_before = settings(a_origin), settings(b_origin)
        app.call('site-controls', action='toggle-captured')
        a_after, b_after = settings(a_origin), settings(b_origin)
        record('G1_redirect_toggle_refused', bool(refreshed) and row(drawn, 'row.content.popups').get('subtitle') == 'Allowed'
               and a_before.get('popups') == 'allow' and 'popups' not in b_before
               and a_after == a_before and b_after == b_before,
               drawnHost=drawn.get('host'), panel=refreshed, a=[a_before, a_after], b=[b_before, b_after],
               negative='without the guard, the A tile sets popups=allow on B')
        app.call('site-controls', action='perform-captured-menu', item='Clear Cookies')
        # A clear runs asynchronously and reloads the page; give it time to act.
        kept = not wait(lambda: 'g=1' not in app.eval(tab, 'document.cookie'), timeout=3, step=.1)
        record('G1_redirect_clear_refused', bool(refreshed) and kept, cookie=app.eval(tab, 'document.cookie'),
               negative='without the guard, Clear Cookies built for A clears B and reloads it')
        close()
        app.call('site-setting', tab=tab, origin=a_origin, kind='popups', state='block')

        # G2: one-word host. Turn ad blocking on, as Settings does.
        app.call('settings-adblock', enabled=True)
        assert wait(lambda: app.call('settings-adblock')['ready'], timeout=40), 'Settings readiness'
        def exclusions():
            return {str(p.relative_to(app.user_data)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in Path(app.user_data).glob('Profiles/*/[Aa]d[Bb]lock/exclusions.json')}
        def tile_on(): return wait(lambda: (lambda s: s if row(s, 'row.contentBlocking').get('state') == 'on' else None)(opened()), timeout=20)
        visit(b_origin + '/ads.html')
        control = tile_on()
        visit(word_origin + '/ads.html')
        word = tile_on()
        blocked = app.eval(tab, 'window.fixtureAdLoaded===true') is False
        files_before, toasts_before = exclusions(), len(app.call('toasts')['toasts'])
        tap_refused = refused(action='tap', id='row.contentBlocking')
        app.call('site-controls', action='capture-tile', id='row.contentBlocking')
        app.call('site-controls', action='toggle-captured')
        after = state()
        toasts = [t['title'] for t in app.call('toasts')['toasts']]
        word_tile, control_tile = row(word, 'row.contentBlocking'), row(control, 'row.contentBlocking')
        record('G2_one_word_host_adblock', control_tile.get('enabled') is True and word_tile.get('enabled') is False
               and word_tile.get('help') == "Ad blocking can't be turned off for this site." and blocked and tap_refused
               and row(after, 'row.contentBlocking').get('state') == 'on' and exclusions() == files_before
               and len(toasts) == toasts_before and not any('could not be saved' in t for t in toasts),
               word=word_tile, control=control_tile, adBlocked=blocked, tapRefused=tap_refused, toasts=toasts,
               negative='old tile was enabled; turning it off showed "Ad blocking settings could not be saved."')
        close()

        # G3: a closed tab's toggled content entry is dropped.
        app.call('site-setting', tab=tab, origin=a_origin, kind='popups', state='allow')
        def toggled(): return state()['sourceActions']['toggledContentTabs']
        def toggle_in_new_tab():
            t = new_tab(app, a_origin + '/ads.html?g3')
            app.call('select', tab=t); app.call('wait', tab=t)
            s = opened()
            assert row(s, 'row.content.popups'), s['rows']
            app.call('site-controls', action='tap', id='row.content.popups')
            app.call('site-controls', action='tap', id='row.content.popups')
            close(); return t
        first = toggle_in_new_tab(); with_first = toggled()
        app.call('close', tab=first)
        second = toggle_in_new_tab(); with_second = toggled()
        app.call('close', tab=second)
        record('G3_closed_tab_toggles_dropped', with_first >= 1 and with_second == with_first,
               withFirst=with_first, withSecond=with_second,
               negative='old source kept one entry per closed tab (withSecond == withFirst + 1)')
    finally:
        if app:
            try: env['_restore_defaults'](app, saved)
            finally: app.quit()
