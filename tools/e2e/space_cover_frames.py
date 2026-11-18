"""Frame-level Space switch rows: no empty page frame and no position jump.

Two real Spaces with local fixture pages. Page A (the outgoing page) is cream
with light text only; page B (the destination) has one dark title at a fixed
place. tools/e2e/space-frames.swift reports per-frame numbers for the page area
(luma mean and spread, and the first dark column), never pixels. Rows:

  <prefix>_space_switch_warm      switch to a Space whose tab rendered before
  <prefix>_space_switch_resized   the window was resized while that tab was hidden

A frame is empty when the page area is flat (luma spread < 3) and light: white,
or the outgoing page's background with no content. A flat dark frame is the
cover's destination theme field (Space B has a dark theme): allowed after a
resize, when no current-size snapshot exists, but not for a warm tab. A jump is B's title resting for two
frames at a place more than 2 pt from where it settles; the cover's slide moves
every frame and is not a jump. OPEN_E2E_SPACE_COVER_OFF=1 launches with the
kill switch (-OpenSeamSpaceCover NO) for a break-and-revert run.
"""
import json
import os
from pathlib import Path
import subprocess
import time

FLAT = 3.0
NEAR = 2.0
RECORD = 1.4
SWITCH_AT = 0.35
INSET = 24
LIGHT = 200
# Space B's theme: dark teal, so its field frames are flat and dark.
THEME_B = {'mathVersion': 1, 'keyColor': {'red': .10, 'green': .32, 'blue': .30, 'alpha': 1}, 'colorCount': 1,
           'wheel': 'analogous', 'appearance': 'dark', 'noiseFactor': 0, 'texture': 'grain', 'intensityFactor': .8}


def helper(api):
    source = Path(api.ROOT) / 'tools/e2e/space-frames.swift'
    binary = Path(api.ROOT) / '.re/e2e-tools/space-frames'
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        binary.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['nice', '-n', '10', 'xcrun', 'swiftc', '-O', '-swift-version', '6', '-parse-as-library',
                        str(source), '-o', str(binary)], check=True)
    return binary


def record(api, app, binary, out, roi, action):
    """Start the frame reader, run `action` at SWITCH_AT, return (frames, action host time)."""
    window = app.call('basics-demo', op='window')
    log = Path(str(out) + '.log')
    command = [str(binary), str(window['pid']), str(window['number']), str(out), str(RECORD), *map(str, roi)]
    launcher = Path.home() / 'Applications/OpenCapture.app'
    if launcher.exists():  # the M1: pixel readers run only through the approved launcher
        job = subprocess.Popen(['/usr/bin/open', '-g', '-n', '-W', str(launcher), '--args',
                                str(Path(api.ROOT) / 'tools/capture/pixels.sh'), str(log), *command])
    else:
        job = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=open(log, 'w'))
    deadline = time.monotonic() + 15
    ready = None
    while ready is None:
        if time.monotonic() > deadline or job.poll() not in (None, 0):
            raise RuntimeError('space-frames did not start: ' + (log.read_text() if log.exists() else ''))
        if out.exists():
            for line in out.read_text().splitlines():
                row = json.loads(line)
                if row.get('event') == 'ready': ready = row
        time.sleep(.02)
    app.call('window-focus', id=app.call('window-state')['id'], activate=True)
    target = ready['host'] + SWITCH_AT
    while time.clock_gettime(time.CLOCK_UPTIME_RAW) < target: time.sleep(.002)
    dispatched = time.clock_gettime(time.CLOCK_UPTIME_RAW)
    action()
    job.wait(timeout=30)
    rows = [json.loads(line) for line in out.read_text().splitlines()]
    return [r for r in rows if 'mean' in r], dispatched


def judge(frames, dispatched):
    after = [f for f in frames if f['host'] >= dispatched]
    # Flat and light: white or the outgoing page's cream background, no content.
    empty = [round(f['host'] - dispatched, 4) for f in after if f['std'] < FLAT and f['mean'] > LIGHT]
    # Flat and dark: the cover's destination theme field (Space B's dark theme).
    field = [round(f['host'] - dispatched, 4) for f in after if f['std'] < FLAT and f['mean'] <= LIGHT]
    white = [round(f['host'] - dispatched, 4) for f in after if f['std'] < FLAT and f['white'] > .95]
    xs = [(f['host'] - dispatched, f['inkX']) for f in after if f['inkX'] is not None]
    final = xs[-1][1] if xs else None
    rests = []
    for (t0, a), (t1, b) in zip(xs, xs[1:]):
        if abs(a - b) <= 1 and final is not None and abs(b - final) > NEAR:
            rests.append(dict(time=round(t1, 4), x=b))
    return dict(frames=len(after), emptyFrames=empty, whiteFrames=white, themeFieldFrames=field, restsAwayFromFinal=rests,
                finalInkX=final,
                settledAtDestination=final is not None and all(abs(x - final) <= 1 for _, x in xs[-10:]),
                firstContentFrames=[dict(t=round(t, 4), x=x) for t, x in xs[:6]])


def run(factory, results, tmp, api, prefix='W'):
    off = os.environ.get('OPEN_E2E_SPACE_COVER_OFF') == '1'
    page_a = Path(tmp) / 'space-cover-a.html'
    page_b = Path(tmp) / 'space-cover-b.html'
    page_a.write_text('<!doctype html><title>Cover A</title><style>body{margin:0;background:#f4ecdc;'
                      'font:28px -apple-system;color:#d8cfbf}p{margin:40px 0 0 360px}</style>'
                      '<p>Outgoing page</p><p>light text only</p>')
    page_b.write_text('<!doctype html><title>Cover B</title><style>body{margin:0;background:#fff;'
                      'font:bold 44px -apple-system;color:#111}h1{margin:60px 0 0;text-align:center}'
                      '</style><h1>Destination</h1>')  # centered: its place depends on the page width
    binary = helper(api)
    evidence = Path(api.ROOT) / '.re/space-cover-frames'
    evidence.mkdir(parents=True, exist_ok=True)
    stamp = str(time.time_ns())
    app = factory(urls=(page_a.as_uri(),), fresh=True,
                  extra_args=['-OpenSeamSpaceCover', 'NO'] if off else None)
    try:
        tab_a = app.call('tabs')[0]['id']
        app.call('wait', tab=tab_a)
        app.call('appearance', name='light')
        app.call('window-frame', frame=[60, 60, 1100, 720])
        space_a = app.call('spaces')[0]['id']
        space_b = app.call('space-create', title='Cover B')
        app.call('theme-set', space=space_b, style=THEME_B)
        tab_b = app.call('open', url=page_b.as_uri(), background=False)['id']
        app.call('wait', tab=tab_b)
        time.sleep(.8)  # B presents at this size: a warm tab
        app.call('space', space=space_a)
        time.sleep(1.0)

        def roi():
            page = app.call('basics-demo', op='targets')['page']
            # Inside the web view: the panel's inset shows window background.
            return [page[0] + INSET, page[1] + INSET, page[2] - 2 * INSET, min(page[3] - 2 * INSET, 260)]

        for name, prepare in (('space_switch_warm', None),
                              ('space_switch_resized', lambda: app.call('window-frame', frame=[60, 60, 980, 680]))):
            if prepare:
                prepare(); time.sleep(1.0)
            frames, dispatched = record(api, app, binary, evidence / ('%s-%s.jsonl' % (stamp, name)), roi(),
                                        lambda: app.call('space', space=space_b))
            motion = app.call('window-motion')['spacePage']
            verdict = judge(frames, dispatched)
            # A warm tab has a current snapshot: no field either. After a resize
            # the snapshot is stale, so the cover may show the theme field.
            ok = (verdict['frames'] >= 3 and not verdict['emptyFrames'] and not verdict['restsAwayFromFinal']
                  and verdict['settledAtDestination'] and not motion['presentationUnavailable']
                  and (name != 'space_switch_warm' or not verdict['themeFieldFrames']))
            results['%s_%s' % (prefix, name)] = dict(ok=ok, coverKillSwitch=off, motion=motion, **verdict,
                                                     evidence=str(evidence), loadAverage=list(os.getloadavg()))
            app.call('space', space=space_a); time.sleep(1.0)
    finally:
        app.quit()
