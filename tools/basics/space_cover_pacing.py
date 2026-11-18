#!/usr/bin/env python3
"""Space-switch pacing ledgers, cover off against cover on, in one session.

Launches alternate off/on (-OpenSeamSpaceCover NO/YES), three of each. Each
launch has two Spaces with a warm local page and records three Space switches
with the stock ScreenCaptureKit detector (tools/perf/frames.m via frame_client)
on the page area. Score with:

  python3 tools/perf/pacing_gate.py --before OUT/off-* --after OUT/on-*

  space_cover_pacing.py --app Open.app --out DIR     (under the on-screen lock)
"""
import argparse, ctypes, json, runpy, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/perf')); sys.path.insert(0, str(ROOT / 'tools/e2e'))
from frame_client import Frames  # noqa: E402

core = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
core.CGMainDisplayID.restype = ctypes.c_uint32


def page(path, title, background):
    path.write_text('<!doctype html><title>%s</title><style>body{margin:0;background:%s;font:bold 44px -apple-system;'
                    'color:#111}h1{margin:60px}</style><h1>%s</h1><p style="margin:0 60px;font:20px -apple-system">'
                    'A warm page for the Space switch timing set.</p>' % (title, background, title))
    return path.as_uri()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--app', required=True); p.add_argument('--out', required=True)
    p.add_argument('--launches', type=int, default=3); p.add_argument('--trials', type=int, default=3)
    o = p.parse_args()
    h = runpy.run_path(str(ROOT / 'tools/e2e/engine_e2e.py'))
    for launch in range(1, o.launches + 1):
        for side in ('off', 'on'):
            out = Path(o.out) / ('%s-%d' % (side, launch))
            with tempfile.TemporaryDirectory(prefix='open-cover-pacing-', dir='/tmp') as scratch:
                first = page(Path(scratch) / 'a.html', 'Space A', '#f6efe3')
                app = h['Open']('Release', 'chrome', scratch + '/root',
                                ['--use-mock-keychain', '--skip-first-run', '-OpenSeamSpaceCover', 'NO' if side == 'off' else 'YES'],
                                scratch + '/app.log', urls=(first,), extra_env={'OPEN_E2E_APP_BUNDLE': o.app})
                frames = None
                try:
                    app.call('wait', tab=app.call('tabs')[0]['id'])
                    app.call('appearance', name='light')
                    app.call('window-frame', frame=[60, 60, 1280, 800])
                    space_a = app.call('spaces')[0]['id']
                    space_b = app.call('space-create', title='Space B')
                    tab = app.call('open', url=page(Path(scratch) / 'b.html', 'Space B', '#e3eef6'), background=False)['id']
                    app.call('wait', tab=tab); time.sleep(.8)
                    app.call('space', space=space_a); time.sleep(.8)
                    app.call('window-focus', id=app.call('window-state')['id'], activate=True)
                    frames = Frames(app.pid, core.CGMainDisplayID(), out / 'frames')
                    x, y, w, hgt = app.call('window-state')['frame']
                    box = app.call('basics-demo', op='targets')['page']
                    top = frames.ready['height'] - y - hgt  # Cocoa frame -> top-left display points
                    roi = [x + box[0] + 8, top + box[1] + 8, box[2] - 16, box[3] - 16]
                    rows = []
                    for trial in range(1, o.trials + 1):
                        for target in (space_b, space_a):
                            label = 'space-switch-%d' % (len(rows) + 1)
                            rows.append(frames.measure(label, roi, lambda t=target: app.call('space', space=t), duration=700))
                            time.sleep(.6)
                    (out / 'result.json').write_text(json.dumps(rows, indent=1))
                    print(json.dumps({'side': side, 'launch': launch, 'changes': [len(r['changes']) for r in rows]}), flush=True)
                finally:
                    if frames: frames.close()
                    app.quit()


if __name__ == '__main__':
    main()
