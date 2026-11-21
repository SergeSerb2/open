"""SCC action guards through the real App, panel callbacks, native menu and engine.

G1: a click drawn for one origin must not act on the origin the tab shows later
(a redirect can land between drawing the panel and receiving the click).
G2: the ad-block tile on a one-word host cannot be changed (its exclusion has no
registrable domain to store), so it is disabled instead of failing to save.
G3: content tiles toggled in a tab that closed are forgotten.
G4: a mouse press that began on a panel button for one origin does nothing when
the release lands after the panel refreshed for another origin.
G5: in Incognito, the ad-block tile for a site that the parent Profile excludes is disabled
with help text (a private session cannot turn blocking back on for it).
"""
import hashlib
import os
from pathlib import Path


def run(factory, results, origin, tmp, env):
    wait, new_tab = env['wait_until'], env['new_tab']
    port = origin.rsplit(':', 1)[1]
    # One-word host and a second registrable site, both on the fixture server.
    a_origin, b_origin, word_origin = origin, 'http://b.guard.test:' + port, 'http://intranet:' + port
    other_origin = 'http://c.other.test:' + port
    args = ['--host-resolver-rules=MAP demand.supply 127.0.0.1:%s, MAP *.guard.test 127.0.0.1, MAP *.other.test 127.0.0.1, MAP intranet 127.0.0.1' % port,
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
        toggled_state = app.call('site-controls', action='toggle-captured')
        a_after, b_after = settings(a_origin), settings(b_origin)
        record('G1_redirect_toggle_refused', bool(refreshed) and row(drawn, 'row.content.popups').get('subtitle') == 'Allowed'
               and a_before.get('popups') == 'allow' and 'popups' not in b_before
               and a_after == a_before and b_after == b_before and not toggled_state['reloadVisible'],
               drawnHost=drawn.get('host'), panel=refreshed, a=[a_before, a_after], b=[b_before, b_after],
               reloadVisible=toggled_state['reloadVisible'],
               negative='without the guard, the A tile sets popups=allow on B')
        app.call('site-controls', action='perform-captured-menu', item='Clear Cookies')
        # A clear runs asynchronously and reloads the page; give it time to act.
        kept = not wait(lambda: 'g=1' not in app.eval(tab, 'document.cookie'), timeout=3, step=.1)
        cleared_state = state()
        record('G1_redirect_clear_refused', bool(refreshed) and kept and not cleared_state['reloadVisible'],
               cookie=app.eval(tab, 'document.cookie'), reloadVisible=cleared_state['reloadVisible'],
               negative='without the guard, Clear Cookies built for A clears B and reloads it')
        close()

        # G4: press New Boost while the panel shows A, let the tab land on B, then release.
        # Tile rows are rebuilt (AppKit then drops their mouse-up); the top buttons stay and
        # would run the command for B. The command dismisses the panel first.
        visit(a_origin + '/ads.html')
        pressed_on = opened()
        button = next(c for c in pressed_on['controls'] if c['id'] == 'action.newBoost')
        x, y, w, h = button['frame']
        point = dict(x=x + w / 2, y=y + h / 2)
        app.call('mouse', action='down', **point)
        visit(b_origin + '/ads.html')
        moved = wait(lambda: (lambda s: s if s['presented'] and s['host'] == 'b.guard.test' else None)(state()), timeout=8)
        app.call('mouse', action='up', **point)
        released, editor = state(), app.call('boost-editor')
        if editor.get('open'): app.call('boost-editor', action='close')
        record('G4_press_across_redirect_refused', bool(moved) and button['enabled'] and released['presented']
               and released['host'] == 'b.guard.test' and not editor.get('open'),
               button=button, point=point, presentedAfterRelease=released['presented'], editorOpened=bool(editor.get('open')),
               negative='old buttons kept the press across the refresh: mouse-up dismissed the panel and opened New Boost for B')
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
               and row(after, 'row.contentBlocking').get('state') == 'on' and not after['reloadVisible'] and exclusions() == files_before
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

        # G5: the parent Profile turns ad blocking off for b.guard.test; an Incognito window then
        # shows that site's tile disabled with help text. Another site stays enabled (control).
        visit(b_origin + '/ads.html')
        assert row(tile_on(), 'row.contentBlocking').get('enabled') is True
        app.call('site-controls', action='tap', id='row.contentBlocking')
        assert wait(lambda: row(opened(), 'row.contentBlocking').get('state') == 'off', timeout=10), 'parent exclusion'
        close()
        normal_window = app.call('window-state')['id']
        existing = {w['id'] for w in app.call('incognito-state')['windows'] if w['private']}
        app.call('menu-perform', id='new-incognito-window')
        private = wait(lambda: next((w for w in app.call('incognito-state')['windows'] if w['private'] and w['id'] not in existing), None), timeout=10)
        assert private, 'New Incognito Window did not create one'
        try:
            app.call('window-focus', id=private['id'], activate=True)
            private_tab = app.call('open', url=other_origin + '/ads.html')['id']; app.call('wait', tab=private_tab)
            control = wait(lambda: (lambda s: s if row(s, 'row.contentBlocking').get('state') == 'on' else None)(opened()), timeout=20) or state()
            app.call('navigate', tab=private_tab, url=b_origin + '/ads.html'); app.call('wait', tab=private_tab)
            excluded = wait(lambda: (lambda s: s if s['host'] == 'b.guard.test' and row(s, 'row.contentBlocking').get('state') == 'off' else None)(opened()), timeout=20) or state()
            tile = row(excluded, 'row.contentBlocking')
            tap_refused = refused(action='tap', id='row.contentBlocking')
            app.call('site-controls', action='capture-tile', id='row.contentBlocking')
            app.call('site-controls', action='toggle-captured')
            after = row(opened(), 'row.contentBlocking')
            record('G5_incognito_parent_exclusion_disabled', excluded.get('isIncognito') is True and row(control, 'row.contentBlocking').get('enabled') is True
                   and tile.get('enabled') is False and tile.get('help') == 'Ad blocking is off for this site in a regular window. Turn it on there.'
                   and tap_refused and after.get('state') == 'off' and after.get('enabled') is False,
                   tile=tile, control=row(control, 'row.contentBlocking'), tapRefused=tap_refused, after=after,
                   negative='old tile was enabled; a tap removed nothing from the session, so the tile stayed Off')
            close()

            # G5b (review round 1): a tile drawn enabled before the parent Profile excluded the site
            # (another window changed it) reaches toggle(); its own guard refuses the stale click.
            app.call('navigate', tab=private_tab, url=other_origin + '/ads.html'); app.call('wait', tab=private_tab)
            stale = wait(lambda: (lambda s: s if s['host'] == 'c.other.test' and row(s, 'row.contentBlocking').get('state') == 'on' else None)(opened()), timeout=20) or state()
            app.call('site-controls', action='capture-tile', id='row.contentBlocking')
            app.call('navigate', tab=tab, url=other_origin + '/ads.html'); app.call('wait', tab=tab)
            parent = app.call('settings-adblock-site', tab=tab, excluded=True)
            private_site = app.call('settings-adblock-site', tab=private_tab)
            toggled_stale = app.call('site-controls', action='toggle-captured')
            record('G5b_stale_tile_parent_exclusion_refused', row(stale, 'row.contentBlocking').get('enabled') is True
                   and 'other.test' in parent['excludedDomains'] and private_site['shouldBlock'] is False
                   and not toggled_stale['reloadVisible'] and app.call('settings-adblock-site', tab=private_tab)['shouldBlock'] is False,
                   staleTile=row(stale, 'row.contentBlocking'), parent=parent['excludedDomains'], reloadVisible=toggled_stale['reloadVisible'],
                   negative='without the toggle guard the stale click "applied" (reload prompt shown) and changed nothing')
            app.call('settings-adblock-site', tab=tab, excluded=False)
            close()
        finally:
            for w in app.call('incognito-state')['windows']:
                if w['private']:
                    app.call('window-focus', id=w['id'], activate=True); app.call('window-close')
            app.call('window-focus', id=normal_window, activate=True)
    finally:
        if app:
            try: env['_restore_defaults'](app, saved)
            finally: app.quit()
