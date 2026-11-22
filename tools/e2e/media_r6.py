"""Bug sweep r6 (SIDEPAGE6) media rows, in the real App through the automation socket.

V-06: Mute All / Unmute All reach an Incognito window's tab and a Little Open page.
V-04: Picture in Picture from a Little Open page does not leave the video in a PiP that has
      no window: the page gets its video back.
"""
import time


def run(factory, results, wait_until, base):
    app = factory(urls=(base + 'plain.html',), fresh=True)
    try:
        _rows(app, results, wait_until, base)
    finally:
        app.quit()


def _rows(app, results, wait_until, base):
    def m(tab): return app.call('media', tab=tab)
    def sessions(): return app.call('little-open-state')['sessions']
    def dismiss_bar():
        if app.call('commandbar-state').get('presented'): app.call('key', key='escape'); time.sleep(.2)
    def little(url):
        previous = {s['id'] for s in sessions()}
        app.call('little-open-action', action='blank')
        row = wait_until(lambda: next((s for s in sessions() if s['id'] not in previous), None), timeout=5, step=.05)
        app.call('key', window=row['window'], text=url + '\r')
        def loaded():
            s = next((s for s in sessions() if s['id'] == row['id']), None)
            return s if s and s['state'] == 'page' and s['content'] and not s['loading'] else None
        return wait_until(loaded, timeout=12, step=.05) or row
    def little_state(row): return next((s for s in sessions() if s['id'] == row['id']), {})
    def close_little(row):
        try: app.call('little-open-action', id=row['id'], action='close')
        except Exception: pass

    # V-06: Mute All from an Incognito window mutes its own tab, the normal tab and Little Open.
    normal = app.call('open', url=base + 'audio.html?r6=normal')['id']; app.call('wait', tab=normal)
    app.eval(normal, 'start()')
    row = little(base + 'audio.html?r6=little')
    app.call('little-open-eval', id=row['id'], js='start()', timeout=5)
    windows_before = {w['id'] for w in app.call('shell-windows')}
    app.call('menu-perform', id='new-incognito-window'); time.sleep(.5); dismiss_bar()
    private = app.call('open', url=base + 'audio.html?r6=private')['id']; app.call('wait', tab=private)
    app.eval(private, 'start()')
    wait_until(lambda: m(private)['playback'] == 'playing', timeout=10, step=.05)
    try:
        app.call('media-action', action='mute-all'); time.sleep(.3)
        muted = dict(private=m(private)['muted'], normal=m(normal)['muted'], little=little_state(row).get('muted'))
        app.call('media-action', action='unmute-all'); time.sleep(.3)
        unmuted = dict(private=m(private)['muted'], normal=m(normal)['muted'], little=little_state(row).get('muted'))
        results['r6_mute_all_reaches_private_and_little_open'] = dict(
            ok=all(v is True for v in muted.values()) and all(v is False for v in unmuted.values()),
            muted=muted, unmuted=unmuted)
    finally:
        for w in app.call('shell-windows'):
            if w['id'] not in windows_before:
                app.call('window-focus', id=w['id']); app.call('window-close')
        close_little(row)

    # V-04: a Little Open page's PiP has no sidebar tab; the page must not lose its video.
    row = little(base + 'video-muted.html?r6=pip')
    try:
        entered = app.call('little-open-eval', id=row['id'], timeout=8,
            js='(async () => { await start(); await document.getElementById("main").requestPictureInPicture();'
               ' return !!document.pictureInPictureElement; })().catch(e => "error: " + e.message)')
        def returned():
            v = app.call('little-open-eval', id=row['id'], js='!!document.pictureInPictureElement', timeout=3)
            return True if v is False else None
        back = wait_until(returned, timeout=3, step=.1)
        pip = app.call('pip')
        results['r6_little_open_pip_returns_video'] = dict(
            ok=entered is True and (bool(back) or pip.get('openWindow', {}).get('visible') is True),
            entered=entered, videoBack=bool(back), pip=pip)
    finally:
        close_little(row)
