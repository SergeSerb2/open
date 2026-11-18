#!/usr/bin/env python3
"""Pacing ledgers for the basics page motion, for tools/perf/pacing_gate.py.

Three launches (one ledger each) of an automation build. Per launch, three
trials of each action, measured by the stock ScreenCaptureKit detector
(tools/perf/frames.m via frame_client) on the steps column:
  basics-step         a step click: the accordion spring and the progress bar
  basics-replay-all   Replay All: back to step 1
  basics-reveal       the steps' fade-in during the staged reveal
The reveal's other fades are separate one-shot fades with intended pauses
between them, so only one fade is scored per trial.

  pacing.py --app Open.app --out DIR
Run under the on-screen lock. Then:
  python3 tools/perf/pacing_gate.py --after DIR/launch-1 DIR/launch-2 DIR/launch-3 --no-latency
"""
import argparse, ctypes, json, runpy, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/perf')); sys.path.insert(0, str(ROOT / 'tools/e2e'))
from frame_client import Frames  # noqa: E402

core = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
core.CGMainDisplayID.restype = ctypes.c_uint32


def column_roi(app, display_height):
    """The steps column in display points (top-left), from the real view frames.
    window-state reports the Cocoa frame (bottom-left origin)."""
    x, y, w, hgt = app.call('window-state')['frame']
    window = [x, display_height - y - hgt]
    cards = [c['windowFrame'] for c in app.call('welcome')['layout']['cards']]
    x0 = min(c[0] for c in cards); y0 = min(c[1] for c in cards)
    x1 = max(c[0] + c[2] for c in cards); y1 = max(c[1] + c[3] for c in cards)
    return [window[0] + x0 - 4, window[1] + y0 - 4, x1 - x0 + 8, y1 - y0 + 8]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--app', required=True); p.add_argument('--out', required=True)
    p.add_argument('--launches', type=int, default=3); p.add_argument('--trials', type=int, default=3)
    o = p.parse_args()
    h = runpy.run_path(str(ROOT / 'tools/e2e/engine_e2e.py'))
    for launch in range(1, o.launches + 1):
        out = Path(o.out) / ('launch-%d' % launch)
        with tempfile.TemporaryDirectory(prefix='open-basics-pacing-', dir='/tmp') as scratch:
            app = h['Open']('Release', 'chrome', scratch + '/root', ['--use-mock-keychain', '--skip-first-run'], scratch + '/app.log',
                            urls=('about:blank',), extra_env={'OPEN_E2E_APP_BUNDLE': o.app, 'OPEN_E2E_REDUCE_MOTION': '0'})
            frames = None
            try:
                app.call('wait', tab=app.call('tabs')[0]['id'])
                app.call('window-frame', frame=[60, 60, 1280, 800])
                app.call('window-focus', id=app.call('window-state')['id'], activate=True)
                frames = Frames(app.pid, core.CGMainDisplayID(), out / 'frames')
                rows = []
                for trial in range(1, o.trials + 1):
                    tab = app.call('welcome', action='insert')['tab']
                    h['wait_until'](lambda: app.call('welcome')['visible'], timeout=5, step=.02)
                    time.sleep(.05)
                    roi = column_roi(app, frames.ready['height'])
                    # The insert above already began the reveal; this trial waits for the steps' fade.
                    rows.append(frames.measure('basics-reveal-%d' % trial, roi, lambda: app.call('welcome'), duration=2700))
                    h['wait_until'](lambda: app.call('welcome')['animating'], timeout=5, step=.05)
                    time.sleep(1.0)
                    rows.append(frames.measure('basics-step-%d' % trial, roi,
                                               lambda t=trial: app.call('welcome', action='replay', card=2 + t % 3), duration=900))
                    time.sleep(1.0)
                    rows.append(frames.measure('basics-replay-all-%d' % trial, roi,
                                               lambda: app.call('welcome', action='replay-all'), duration=900))
                    time.sleep(.5)
                    app.call('close', tab=tab)
                    time.sleep(.5)
                (out / 'result.json').write_text(json.dumps(rows, indent=1))
                print(json.dumps({'launch': launch, 'trials': len(rows),
                                  'changes': [len(r['changes']) for r in rows]}), flush=True)
            finally:
                if frames: frames.close()
                app.quit()


if __name__ == '__main__':
    main()
