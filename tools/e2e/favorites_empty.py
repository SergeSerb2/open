"""A3: the Favorites empty-state card, through the real App automation socket.

The harness hides the card by default (older suites keep their sidebar geometry); this suite
launches with --favorites-empty-state=shown. Loopback pages only.
"""
import os
import runpy

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
        # Colours in the light default theme, read from a real-window snapshot, against Arc's capture
        # (C-report-s10 (a) 1; sRGB): fill #E1E0F5 lighter than the sidebar, dashed outline #A2A6FB,
        # star disc #202BFF, title #090D4E, body #4A4C81.
        app.call('appearance', name='light')
        shot = os.path.join(tmp, 'a3-favorites-empty-window.png')
        wait_until(lambda: state(app).get('colors', {}).get('content') == 'light', timeout=5, step=.1)
        app.call('snapshot', window=app.call('window-state').get('number'), path=shot)
        png_pixels = runpy.run_path(os.path.join(harness['ROOT'], 'tools', 'e2e', 'live_data.py'))['png_pixels']
        w, h, bpp, rows = png_pixels(shot)
        scale = w / 1280
        def px(x, y):
            r = rows[min(int(y * scale), h - 1)]; i = min(int(x * scale), w - 1) * bpp
            return tuple(r[i:i + 3])
        def region(x0, y0, x1, y1): return [px(x / scale, y / scale) for y in range(int(y0 * scale), int(y1 * scale)) for x in range(int(x0 * scale), int(x1 * scale))]
        def near(a, b, tol): return all(abs(p - q) <= tol for p, q in zip(a, b))
        cx, cy, cw = card[0], card[1], card[2]
        sidebar_px, fill_px = px(3, cy + 60), px(cx + 12, cy + 60)
        outline_px = min(region(cx + 30, cy, cx + cw - 30, cy + 1.5), key=sum)
        disc_px = px(cx + cw / 2 - 6, cy + 12.5 + 8.25)
        title_px = min(region(cx + 30, cy + 34, cx + cw - 30, cy + 51), key=sum)
        body_px = min(region(cx + 34, cy + 54, cx + cw - 34, cy + 85), key=sum)
        got = dict(sidebar=sidebar_px, fill=fill_px, outline=outline_px, disc=disc_px, title=title_px, body=body_px)
        results['fav_empty_colors_light_default'] = {'ok': near(fill_px, (0xE1, 0xE0, 0xF5), 6) and sum(fill_px) > sum(sidebar_px)
            and near(outline_px, (0xA2, 0xA6, 0xFB), 12) and near(disc_px, (0x20, 0x2B, 0xFF), 8) and near(title_px, (0x09, 0x0D, 0x4E), 8)
            and near(body_px, (0x4A, 0x4C, 0x81), 20), 'pixels': {k: '#%02X%02X%02X' % v for k, v in got.items()},
            'resolved': first.get('colors'), 'scale': scale}
        if os.environ.get('OPEN_LIVE_DATA_FRAMES'):
            import shutil; shutil.copy(shot, os.path.join(os.environ['OPEN_LIVE_DATA_FRAMES'], 'a3-favorites-empty-window.png'))

        # A drop into Favorites (the same intent a real tab drop sends) replaces the card with a tile.
        tab = new_tab(app, url('one'))
        dropped = app.call('sidebar-drop', nodes=[tab], parent=dict(kind='favorites', id=first['profile']), index=0)
        after = wait_until(lambda: (lambda s: s if not s.get('shown') else None)(state(app)), timeout=5, step=.05) or state(app)
        results['fav_empty_drop_adds_favorite_and_hides_card'] = {'ok': bool(dropped) and after.get('favorites') == 1 and not after.get('shown')
            and after.get('dismissed') is False and after.get('sectionHeight', 0) > 8 and app.tab(tab)['section'] == 'favorites', 'state': after}

        # Removing the last Favorite brings the card back: it was not dismissed (C-report-s10 (a) 5c).
        app.call('sidebar-drop', nodes=[tab], parent=dict(kind='today', id=app.call('window-state')['space']), index=0)
        back = wait_until(lambda: (lambda s: s if s.get('shown') else None)(state(app)), timeout=5, step=.05) or state(app)
        results['fav_empty_card_returns_when_empty_again'] = {'ok': back.get('shown') and back.get('favorites') == 0 and back.get('sectionHeight') == 113, 'state': back}

        # Dismiss through the real button: the card goes at once (no animation) and the section has no content
        # (Arc: Space title 17 pt under the section top = Open's 8 pt empty section); it stays so.
        pressed = app.call('favorites-empty-state', action='dismiss')
        immediately = state(app)   # no animation: gone on the next read
        gone = wait_until(lambda: (lambda s: s if not s.get('shown') else None)(state(app)), timeout=5, step=.05) or state(app)
        results['fav_empty_dismiss'] = {'ok': pressed.get('pressed') and not immediately.get('shown') and not gone.get('shown') and gone.get('dismissed') is True
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
