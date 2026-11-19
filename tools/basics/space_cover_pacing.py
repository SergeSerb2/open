#!/usr/bin/env python3
"""Space-switch timing set, cover off against cover on, in one session.

Launches alternate off/on (-OpenSeamSpaceCover NO/YES), three of each. Each
launch has two Spaces with a warm local page and two phases:

1. Pacing: six Space switches with the stock ScreenCaptureKit detector
   (tools/perf/frames.m via frame_client) on the page area. Score p99 and late
   frames with:

     python3 tools/perf/pacing_gate.py --before OUT/off-* --after OUT/on-* --no-latency

   (the gate's own latency row compares on against off; off's first change is
   the blank swap, the defect, so it is no baseline: lead ruling 2026-11-18 21:25).

2. Latency (the rule for the cover, same ruling): four more switches, each
   recorded by one stream (tools/e2e/space-frames.swift) that reports the
   sidebar pager and the page in every frame. Per switch, each region's first
   visible change is its first frame that differs from the last frame before
   the input. Rule: with the cover, the median of (page first change - sidebar
   first change) <= one display frame (the display's refresh). The off value is
   recorded only as evidence of the defect.

  space_cover_pacing.py --app Open.app --out DIR     (under the on-screen lock)
  space_cover_pacing.py --score DIR                  (latency rule only)
"""
import argparse, ctypes, json, runpy, statistics, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/perf')); sys.path.insert(0, str(ROOT / 'tools/e2e'))
from frame_client import Frames  # noqa: E402

core = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
core.CGMainDisplayID.restype = ctypes.c_uint32
core.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p; core.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
core.CGDisplayModeGetRefreshRate.restype = ctypes.c_double; core.CGDisplayModeGetRefreshRate.argtypes = [ctypes.c_void_p]
core.CGDisplayModeRelease.argtypes = [ctypes.c_void_p]
# A region changed when its luma mean or spread moved by more than this (0-255);
# a still capture of the same content repeats its numbers exactly.
CHANGE = 0.5


def refresh_hz():
    mode = core.CGDisplayCopyDisplayMode(core.CGMainDisplayID())
    try: return core.CGDisplayModeGetRefreshRate(mode)
    finally: core.CGDisplayModeRelease(mode)


def first_change(frames, dispatched):
    """Seconds from the input to the region's first frame that differs from
    the last frame before the input (None when nothing changed)."""
    before = [f for f in frames if f['host'] < dispatched]
    if not before: return None
    base = before[-1]
    for f in frames:
        if f['host'] >= dispatched and (abs(f['mean'] - base['mean']) > CHANGE or abs(f['std'] - base['std']) > CHANGE
                                        or f['inkX'] != base['inkX']):
            return f['host'] - dispatched
    return None


def score(out):
    """The latency rule over every launch in OUT; returns True when it passes."""
    report = {}
    for side in ('off', 'on'):
        rows = [r for d in sorted(Path(out).glob(side + '-*')) if (d / 'latency.json').exists()
                for r in json.loads((d / 'latency.json').read_text())['switches']]
        hz = {json.loads((d / 'latency.json').read_text())['refresh_hz'] for d in Path(out).glob(side + '-*') if (d / 'latency.json').exists()}
        deltas = [r['page_ms'] - r['sidebar_ms'] for r in rows if r['page_ms'] is not None and r['sidebar_ms'] is not None]
        report[side] = dict(switches=len(rows), measured=len(deltas), refresh_hz=sorted(hz),
                            sidebar_first_median_ms=statistics.median([r['sidebar_ms'] for r in rows if r['sidebar_ms'] is not None] or [float('nan')]),
                            page_first_median_ms=statistics.median([r['page_ms'] for r in rows if r['page_ms'] is not None] or [float('nan')]),
                            page_minus_sidebar_ms=dict(median=statistics.median(deltas) if deltas else None,
                                                       max=max(deltas) if deltas else None, values=[round(v, 2) for v in deltas]))
    on = report['on']
    frame_ms = 1000 / max(on['refresh_hz']) if on['refresh_hz'] else None
    ok = (frame_ms is not None and on['measured'] == on['switches'] > 0
          and on['page_minus_sidebar_ms']['median'] <= frame_ms + 0.05)
    report['rule'] = dict(text='cover on: median(page first change - sidebar first change) <= one display frame, same session',
                          display_frame_ms=frame_ms, verdict='PASS' if ok else 'FAIL',
                          off_note='off is the blank swap (the defect); recorded as evidence only')
    (Path(out) / 'latency-rule.json').write_text(json.dumps(report, indent=1))
    print(json.dumps(report, indent=1))
    return ok


def page(path, title, background):
    path.write_text('<!doctype html><title>%s</title><style>body{margin:0;background:%s;font:bold 44px -apple-system;'
                    'color:#111}h1{margin:60px}</style><h1>%s</h1><p style="margin:0 60px;font:20px -apple-system">'
                    'A warm page for the Space switch timing set.</p>' % (title, background, title))
    return path.as_uri()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--app'); p.add_argument('--out'); p.add_argument('--score')
    p.add_argument('--launches', type=int, default=3); p.add_argument('--trials', type=int, default=3)
    p.add_argument('--latency-trials', type=int, default=4)
    o = p.parse_args()
    if o.score: sys.exit(0 if score(o.score) else 1)
    if not (o.app and o.out): p.error('--app and --out are required')
    h = runpy.run_path(str(ROOT / 'tools/e2e/engine_e2e.py'))
    cover = runpy.run_path(str(ROOT / 'tools/e2e/space_cover_frames.py'))
    api = type('Api', (), {'ROOT': str(ROOT)})
    binary = cover['helper'](api)
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
                    frames.close(); frames = None
                    # Latency phase: one stream reports the sidebar pager and the page.
                    targets = app.call('basics-demo', op='targets')
                    sx, sy, sw, sh = targets['sidebar']
                    regions = [[sx + 10, sy + 100, sw - 20, max(40, sh - 180)], [box[0] + 24, box[1] + 24, box[2] - 48, min(box[3] - 48, 260)]]
                    switches = []
                    for trial in range(1, o.latency_trials + 1):
                        target = space_b if trial % 2 else space_a
                        (sidebar, page_frames), dispatched = cover['record'](
                            api, app, binary, out / ('latency-%d.jsonl' % trial), regions, lambda t=target: app.call('space', space=t), seconds=1.0)
                        s_first, p_first = first_change(sidebar, dispatched), first_change(page_frames, dispatched)
                        switches.append(dict(trial=trial, sidebar_ms=s_first and s_first * 1000, page_ms=p_first and p_first * 1000))
                        time.sleep(.6)
                    (out / 'latency.json').write_text(json.dumps(dict(side=side, refresh_hz=refresh_hz(), regions=regions, switches=switches), indent=1))
                    print(json.dumps({'side': side, 'launch': launch, 'changes': [len(r['changes']) for r in rows],
                                      'latency': [(round(v['sidebar_ms'] or -1, 1), round(v['page_ms'] or -1, 1)) for v in switches]}), flush=True)
                finally:
                    if frames: frames.close()
                    app.quit()
    sys.exit(0 if score(o.out) else 1)


if __name__ == '__main__':
    main()
