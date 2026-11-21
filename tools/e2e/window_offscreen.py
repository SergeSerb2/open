"""Bug sweep r4 A11Y-01: a saved window frame that is on no connected display (the display was
removed, or the frame is larger than the screen left) is moved onto a screen at the next launch.
The App reads the real NSScreen list; the row edits only the saved snapshot between launches."""
import json
import re
from pathlib import Path


def run(factory, results):
    def rect(text):
        x, y, w, h = (float(v) for v in re.findall(r'-?[\d.]+', text)[:4])
        return x, y, w, h

    def reachable(frame, screens):
        x, y, w, h = frame
        for sx, sy, sw, sh in screens:
            # The whole title bar strip (top 28 pt) is inside one visible frame.
            if x >= sx - 1 and x + w <= sx + sw + 1 and y + h <= sy + sh + 1 and y + h - 28 >= sy - 1:
                return True
        return False

    fixture = 'data:text/html,<title>Off-screen fixture</title><h1>Off-screen fixture</h1>'
    app = factory(urls=(fixture,), fresh=True)
    try:
        screens = app.call('screens')
        snapshot = Path(app.call('save'))
    finally:
        app.quit()
    right = max(sx + sw for sx, _, sw, _ in screens)
    top = max(sy + sh for _, sy, _, sh in screens)
    cases = {
        # A display to the right that is no longer connected.
        'gone_display': dict(frameX=right + 1500, frameY=200, frameWidth=1200, frameHeight=800),
        # Larger than every screen, with its title bar above all of them.
        'too_large_above': dict(frameX=-200, frameY=top + 400, frameWidth=9000, frameHeight=6000),
    }
    rows = {}
    for name, frame in cases.items():
        data = json.loads(snapshot.read_text())
        for window in data['windows']:
            window.update(frame)
        snapshot.write_text(json.dumps(data))
        app = factory(urls=())
        try:
            frames = [rect(w['frame']) for w in app.call('windows')
                      if w['visible'] and w['class'] in ('BrowserWindow', 'SpaceThemeWindow')]
            rows[name] = {'saved': frame, 'frames': frames, 'reachable': bool(frames) and all(reachable(f, screens) for f in frames)}
        finally:
            app.quit()
    results['window_offscreen_frame_moved_on_screen'] = {
        'ok': all(row['reachable'] for row in rows.values()), 'screens': screens, 'cases': rows}
