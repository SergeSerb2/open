"""UX round 1 wave 3 (lane UXG): new windows and window titles, real App, socket only.

- New Window (⌘N) takes the source window's size and sidebar width, one cascade step (24 pt right and
  down) from it; a step past the screen starts again at the screen's top-left (Arc: same size, same Space,
  the source's sidebar width; docs/re/interaction-states.md §17, §13).
- New Incognito Window cascades from the front window instead of a fixed default over it.
- A standard window's title (Window menu, Mission Control, AppleScript `name of window`) is its focused
  Space's title, and follows a Space switch and a rename (Arc: docs/re/runtime-observations.md §6).

Frames are AppKit screen points (origin bottom-left). Open is never activated; loopback pages only.
`engine_e2e.py --only split` runs it; OPEN_SPLIT_UXG_WIN_ONLY=1 runs only these rows.
"""
import http.server
import os
import sys
import threading
import time

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from loopback_http import LoopbackHTTPServer  # noqa: E402

STEP = 24


def _server():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'<!doctype html><title>Window page</title><body>Window page</body>'
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)

        def log_message(self, *a):
            pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, 'http://127.0.0.1:%d' % server.server_address[1]


def run(factory, results, tmp, h):
    wait = h.wait_until
    server, origin = _server()
    app = factory(urls=(origin + '/one',), fresh=True)

    def row(name, check):
        try:
            ok, evidence = check()
        except Exception as error:
            ok, evidence = False, {'error': repr(error)}
        results[name] = dict(ok=bool(ok), **evidence)
        print('uxg %-46s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def windows():
        return {w['id']: w for w in app.call('shell-windows')}

    def state(wid):
        return app.call('window-state', id=wid)

    def close_others(keep):
        for wid in list(windows()):
            if wid != keep:
                app.call('window-focus', id=wid); app.call('window-close'); time.sleep(.5)
        app.call('window-focus', id=keep); time.sleep(.3)

    def new_window(command, source):
        before = set(windows())
        app.call('window-focus', id=source); time.sleep(.3)
        app.call('command', id=command)
        made = wait(lambda: next(iter(set(windows()) - before), None), timeout=10, step=.1)
        assert made, 'no new window'
        time.sleep(.6)
        return made

    try:
        first = next(iter(windows()))
        app.call('wait', tab=next(t['id'] for t in app.call('tabs') if t.get('selected')))

        def cmd_n_matches_source():
            app.call('window-frame', frame=[700, 300, 1100, 760], unconstrained=True); time.sleep(.5)
            app.call('updater-banner-width', width=300.0); time.sleep(.4)
            src = state(first)
            made = new_window('new-window', first)
            new = state(made)
            sx, sy, sw, sh = src['frame']; nx, ny, nw, nh = new['frame']
            ok = (nw, nh) == (sw, sh) and (nx, ny) == (sx + STEP, sy - STEP) and new['sidebarWidth'] == src['sidebarWidth'] \
                and new['space'] == src['space']
            close_others(first)
            return ok, {'source': src['frame'], 'new': new['frame'], 'sourceSidebar': src['sidebarWidth'],
                        'newSidebar': new['sidebarWidth'], 'sameSpace': new['space'] == src['space']}
        row('uxg_new_window_same_size_sidebar_cascade', cmd_n_matches_source)

        def cmd_n_wraps_at_screen_edge():
            screen = app.call('screens')[0]  # visible frame of the main screen
            vx, vy, vw, vh = screen
            # The source touches the bottom of the visible frame: a cascade step would leave the screen.
            app.call('window-frame', frame=[vx + vw - 1000, vy, 900, 600], unconstrained=True); time.sleep(.5)
            made = new_window('new-window', first)
            nx, ny, nw, nh = state(made)['frame']
            inside = nx >= vx - .5 and ny >= vy - .5 and nx + nw <= vx + vw + .5 and ny + nh <= vy + vh + .5
            close_others(first)
            return inside and (nw, nh) == (900, 600), {'visible': screen, 'new': [nx, ny, nw, nh]}
        row('uxg_new_window_stays_on_screen', cmd_n_wraps_at_screen_edge)

        def incognito_cascades():
            app.call('window-frame', frame=[700, 300, 1100, 760], unconstrained=True); time.sleep(.5)
            src = state(first)
            made = new_window('new-incognito-window', first)
            nx, ny, nw, nh = state(made)['frame']
            sx, sy, sw, sh = src['frame']
            ok = (nx, ny) == (sx + STEP, sy - STEP) and (nw, nh) == (sw, sh)
            close_others(first)
            return ok, {'source': src['frame'], 'incognito': [nx, ny, nw, nh]}
        row('uxg_incognito_window_cascades_from_source', incognito_cascades)

        def titles_follow_space():
            spaces = app.call('spaces')
            app.call('window-focus', id=first)
            first_space = state(first)['space']
            second = app.call('space-create', title='UXG Second'); time.sleep(.5)
            # space-create shows the new Space in the front window: go back, so the windows differ.
            app.call('window-focus', id=first); app.call('space', space=first_space); time.sleep(.6)
            made = new_window('new-window', first)
            app.call('window-focus', id=made); app.call('space', space=second); time.sleep(.8)
            def titles(): return {w: windows()[w]['title'] for w in (first, made)}
            def space_title(sid):
                rows = app.call('spaces')
                return next(((x['title'] or 'Space %d' % (i + 1)) for i, x in enumerate(rows) if x['id'] == sid), None)
            switched = titles()
            app.call('space-rename', space=second, title='UXG Renamed'); time.sleep(.6)
            renamed = titles()
            ok = switched[first] == space_title(first_space) and switched[made] == 'UXG Second' and renamed[made] == 'UXG Renamed'
            close_others(first)
            return ok, {'afterSwitch': switched, 'afterRename': renamed, 'firstSpaceTitle': space_title(first_space),
                        'spacesBefore': len(spaces)}
        row('uxg_window_title_is_space_title', titles_follow_space)
    finally:
        try: app.quit()
        except Exception: pass
        server.shutdown(); server.server_close()
