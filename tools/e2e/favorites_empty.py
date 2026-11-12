"""A3: the Favorites empty-state card, through the real App automation socket.

The harness hides the card by default (older suites keep their sidebar geometry); this suite
launches with --favorites-empty-state=shown. Loopback pages only.
"""
import os

SHOWN = ['--favorites-empty-state=shown']
TITLE = 'Drag to add Favorites'
BODY = 'Favorites keep your most used sites and apps close'


def run(factory, results, tmp, harness):
    new_tab, wait_until = harness['new_tab'], harness['wait_until']
    server, port = harness['_sleep_server']()
    def url(path): return 'http://fav.localhost:%d/%s' % (port, path)
    def state(app): return app.call('favorites-empty-state')
    app = factory(urls=(), fresh=True, extra_args=SHOWN)
    try:
        app.call('window-frame', frame=[80, 60, 1280, 820])
        first = state(app)
        width = first.get('sidebarWidth', 0)
        card, button = first.get('card', []), first.get('dismissButton', [])
        # Measured geometry (interaction-states §20.3): card 7 pt in, 95 pt tall; section 113; "x" 14 x 14.
        results['fav_empty_card_shown_on_fresh_profile'] = {'ok': first.get('enabled') and first.get('shown') and first.get('favorites') == 0
            and first.get('title') == TITLE and first.get('body') == BODY and len(card) == 4 and card[0] == 7 and card[2] == width - 14
            and card[3] == 95 and first.get('sectionHeight') == 113 and len(button) == 4 and button[2:] == [14, 14]
            and abs(button[0] - (width - 30)) <= 1, 'state': first}
        if os.environ.get('OPEN_LIVE_DATA_FRAMES'):
            app.call('snapshot', window=app.call('window-state').get('number'),
                     path=os.path.join(os.environ['OPEN_LIVE_DATA_FRAMES'], 'a3-favorites-empty-window.png'))

        # A drop into Favorites (the same intent a real tab drop sends) replaces the card with a tile.
        tab = new_tab(app, url('one'))
        dropped = app.call('sidebar-drop', nodes=[tab], parent=dict(kind='favorites', id=first['profile']), index=0)
        after = wait_until(lambda: (lambda s: s if not s.get('shown') else None)(state(app)), timeout=5, step=.05) or state(app)
        results['fav_empty_drop_adds_favorite_and_hides_card'] = {'ok': bool(dropped) and after.get('favorites') == 1 and not after.get('shown')
            and after.get('dismissed') is False and after.get('sectionHeight', 0) > 8 and app.tab(tab)['section'] == 'favorites', 'state': after}

        # Removing the last Favorite brings the card back: it was not dismissed (GUESS until capture PB5-c item 5).
        app.call('sidebar-drop', nodes=[tab], parent=dict(kind='today', id=app.call('window-state')['space']), index=0)
        back = wait_until(lambda: (lambda s: s if s.get('shown') else None)(state(app)), timeout=5, step=.05) or state(app)
        results['fav_empty_card_returns_when_empty_again'] = {'ok': back.get('shown') and back.get('favorites') == 0 and back.get('sectionHeight') == 113, 'state': back}

        # Dismiss through the real button: the card goes, the section falls back to 8 pt, and it stays so.
        pressed = app.call('favorites-empty-state', action='dismiss')
        gone = wait_until(lambda: (lambda s: s if not s.get('shown') else None)(state(app)), timeout=5, step=.05) or state(app)
        results['fav_empty_dismiss'] = {'ok': pressed.get('pressed') and not gone.get('shown') and gone.get('dismissed') is True
            and gone.get('sectionHeight') == 8, 'state': gone}
        again = new_tab(app, url('two'))
        app.call('sidebar-drop', nodes=[again], parent=dict(kind='favorites', id=first['profile']), index=0)
        app.call('sidebar-drop', nodes=[again], parent=dict(kind='today', id=app.call('window-state')['space']), index=0)
        still = state(app)
        results['fav_empty_dismissed_stays_after_add_remove'] = {'ok': not still.get('shown') and still.get('dismissed') is True and still.get('favorites') == 0, 'state': still}

        # The dismissal is stored with the Profile: it survives a relaunch.
        app.call('save')
        app.quit()
        app = factory(urls=(), fresh=False, extra_args=SHOWN)
        relaunched = state(app)
        results['fav_empty_dismissed_survives_relaunch'] = {'ok': relaunched.get('enabled') and not relaunched.get('shown')
            and relaunched.get('dismissed') is True and relaunched.get('profile') == first.get('profile'), 'state': relaunched}
        app.quit()

        # Older suites: the harness default hides the card on a fresh Profile (8 pt section).
        app = factory(urls=(), fresh=True)
        hidden = state(app)
        results['fav_empty_hidden_by_harness_default'] = {'ok': hidden.get('enabled') is False and not hidden.get('shown')
            and hidden.get('favorites') == 0 and hidden.get('sectionHeight') == 8, 'state': hidden}
    finally:
        try: app.quit()
        finally: server.shutdown()
