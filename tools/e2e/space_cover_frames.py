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
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import time
from loopback_http import LoopbackHTTPServer

FLAT = 3.0
NEAR = 2.0
RECORD = 1.4
SWITCH_AT = 0.35
INSET = 24
SLOW_SECONDS = 1.2
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


def record(api, app, binary, out, rois, action, seconds=RECORD):
    """One frame reader for all regions; run `action` at SWITCH_AT. Return
    (frames per region, action host time)."""
    window = app.call('basics-demo', op='window')
    log = Path(str(out) + '.log')
    command = [str(binary), str(window['pid']), str(window['number']), str(out), str(seconds),
               *[str(v) for roi in rois for v in roi]]
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
            if job.poll() is None: job.kill(); job.wait(timeout=5)  # never leave a reader behind
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
    rows = [json.loads(l) for l in out.read_text().splitlines()]
    rows = [r for r in rows if 'regions' in r]
    return [[dict(host=r['host'], **r['regions'][i]) for r in rows] for i in range(len(rois))], dispatched


def judge(frames, dispatched):
    after = [f for f in frames if f['host'] >= dispatched]
    # Flat and light: white or the outgoing page's cream background, no content.
    empty = [round(f['host'] - dispatched, 4) for f in after if f['std'] < FLAT and f['mean'] > LIGHT]
    # Flat and dark: the cover's destination theme field (Space B's dark theme).
    field = [round(f['host'] - dispatched, 4) for f in after if f['std'] < FLAT and f['mean'] <= LIGHT]
    white = [round(f['host'] - dispatched, 4) for f in after if f['std'] < FLAT and f['white'] > .95]
    xs = [(f['host'] - dispatched, f['inkX']) for f in after if f['inkX'] is not None]
    final = xs[-1][1] if xs else None
    # A jump: the destination reached its final place (two frames within 1 pt)
    # and then left it by more than NEAR. The slide spring only approaches it.
    rests = []
    settled = next((i for i in range(len(xs) - 1) if final is not None
                    and abs(xs[i][1] - final) <= 1 and abs(xs[i + 1][1] - final) <= 1), None)
    if settled is not None:
        rests = [dict(time=round(t, 4), x=x) for t, x in xs[settled:] if abs(x - final) > NEAR]
    shown = next((round(t, 4) for t, x in xs if final is not None and abs(x - final) <= 1), None)
    return dict(frames=len(after), destinationAt=shown, emptyFrames=empty, whiteFrames=white, themeFieldFrames=field, restsAwayFromFinal=rests,
                finalInkX=final,
                settledAtDestination=final is not None and all(abs(x - final) <= 1 for _, x in xs[-10:]),
                firstContentFrames=[dict(t=round(t, 4), x=x) for t, x in xs[:6]])


class Slow(http.server.BaseHTTPRequestHandler):
    """A destination page whose response waits SLOW_SECONDS."""
    def log_message(self, *_): pass

    def do_GET(self):
        time.sleep(SLOW_SECONDS)
        body = (b'<!doctype html><title>Slow</title><style>body{margin:0;background:#fff;font:bold 44px -apple-system;'
                b'color:#111}h1{margin:60px 0 0;text-align:center}</style><h1>Slow destination</h1>')
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)


def page(path, title, align='center', background='#fff'):
    path.write_text('<!doctype html><title>%s</title><style>body{margin:0;background:%s;font:bold 44px -apple-system;'
                    'color:#111}h1{margin:60px 0 0;text-align:%s}</style><h1>%s</h1>' % (title, background, align, title))
    return path.as_uri()


def run(factory, results, tmp, api, prefix='W'):
    """Rows: warm, resized, slow (destination still loading), split (two panes),
    native (a Welcome tab: no engine frame) and, on the M1 only, crashed (the
    destination renderer is gone, so no receipt can come)."""
    off = os.environ.get('OPEN_E2E_SPACE_COVER_OFF') == '1'
    tmp = Path(tmp)
    page_a = tmp / 'space-cover-a.html'
    # Mid-gray text: never flat (a flat frame means content is missing), never ink.
    page_a.write_text('<!doctype html><title>Cover A</title><style>body{margin:0;background:#f4ecdc;'
                      'font:bold 64px -apple-system;color:#9a917f}p{margin:30px 0 0 40px}</style>'
                      '<p>Outgoing page</p><p>mid-gray text</p><p>no dark ink</p>')
    binary = helper(api)
    evidence = Path(api.ROOT) / '.re/space-cover-frames'
    evidence.mkdir(parents=True, exist_ok=True)
    stamp = str(time.time_ns())
    server = LoopbackHTTPServer(Slow)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    on_m1 = subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).startswith('Apple M1')
    app = factory(urls=(page_a.as_uri(),), fresh=True,
                  extra_args=['-OpenSeamSpaceCover', 'NO' if off else 'YES'])
    try:
        tab_a = app.call('tabs')[0]['id']
        app.call('wait', tab=tab_a)
        app.call('appearance', name='light')
        app.call('window-frame', frame=[60, 60, 1100, 720])
        space_a = app.call('spaces')[0]['id']

        def new_space(title, urls):
            space = app.call('space-create', title=title)
            app.call('theme-set', space=space, style=THEME_B)
            tabs = []
            for url in urls:
                tabs.append(app.call('open', url=url, background=False)['id']); app.call('wait', tab=tabs[-1])
            time.sleep(.8)  # presents at this size: warm
            return space, tabs

        space_b, (tab_b,) = new_space('Cover B', [page(tmp / 'space-cover-b.html', 'Destination')])
        space_s, (left, right) = new_space('Cover Split', [page(tmp / 'space-cover-left.html', 'Left', 'left'),
                                                           page(tmp / 'space-cover-right.html', 'Right', 'left')])
        app.call('split')
        time.sleep(.8)
        space_n = app.call('space-create', title='Cover Native')
        app.call('theme-set', space=space_n, style=THEME_B)
        app.call('welcome', action='insert')
        time.sleep(4.5)  # the Welcome reveal settles; its page is native
        space_c = None
        if on_m1:
            space_c, (tab_c,) = new_space('Cover Crash', [page(tmp / 'space-cover-c.html', 'Crashed')])
        app.call('space', space=space_a)
        time.sleep(1.0)

        def page_roi():
            page_box = app.call('basics-demo', op='targets')['page']
            # Inside the web view: the panel's inset shows window background.
            return [page_box[0] + INSET, page_box[1] + INSET, page_box[2] - 2 * INSET, min(page_box[3] - 2 * INSET, 260)]

        def welcome_roi():
            # The Welcome heading and steps: text, never a flat gradient.
            x, y, w, h = app.call('basics-demo', op='targets')['page']
            return [x + 20, y + 220, 380, 260]

        def halves():
            x, y, w, h = page_roi()
            return [[x, y, w / 2 - 24, h], [x + w / 2 + 24, y, w / 2 - 24, h]]

        scenarios = [
            ('space_switch_warm', space_b, None, page_roi, RECORD),
            ('space_switch_resized', space_b, lambda: app.call('window-frame', frame=[60, 60, 980, 680]), page_roi, RECORD),
            ('space_switch_slow', space_b, None, page_roi, SLOW_SECONDS + 2.0),
            ('space_switch_split', space_s, None, halves, RECORD),
            ('space_switch_native', space_n, None, welcome_roi, RECORD),
        ]
        if on_m1:
            def crash():
                api.declare_popup_renderer_fault(app)
                identifier = app.call('tab-state', tab=tab_c)['page']['identifier']
                try: app.call('devtools', tab=identifier, method='Page.crash', timeout=5)
                except Exception: pass  # the renderer dies before it answers
                time.sleep(1.0)
            scenarios.append(('space_switch_crashed', space_c, crash, page_roi, RECORD))
        else:
            results['%s_space_switch_crashed' % prefix] = dict(ok=True, status='INFO',
                reason='renderer faults run on the M1 only (existing rule); this row runs there')
        for name, space, prepare, regions, seconds in scenarios:
            if prepare:
                prepare(); time.sleep(1.0)
            rois = regions()
            rois = rois if isinstance(rois[0], list) else [rois]
            switch = lambda: app.call('space', space=space)
            if name == 'space_switch_slow':  # the load starts with the switch: the cover holds through it
                switch = lambda: (app.call('navigate', tab=tab_b, url='http://127.0.0.1:%d/slow' % server.server_address[1]),
                                  app.call('space', space=space))
            frames, dispatched = record(api, app, binary, evidence / ('%s-%s.jsonl' % (stamp, name)), rois, switch, seconds)
            motion = app.call('window-motion')['spacePage']
            verdicts = [judge(f, dispatched) for f in frames]
            # When the destination first shows at its final place: how long the cover held.
            first = [v['destinationAt'] for v in verdicts]
            if name == 'space_switch_slow':
                # The load ends with the cover (theme field). A freshly loaded
                # document's first presented frame can be its blank first
                # paint: reported, allowed only after the load.
                for v in verdicts:
                    end = max(v['themeFieldFrames'] or [0])
                    v['blankFirstPaint'] = [t for t in v['emptyFrames'] if t > end]
                    v['emptyFrames'] = [t for t in v['emptyFrames'] if t <= end]
            ok = all(v['frames'] >= 3 and not v['emptyFrames'] and not v['restsAwayFromFinal'] for v in verdicts) \
                and motion['phase'] == 'idle'
            if name in ('space_switch_warm', 'space_switch_resized', 'space_switch_slow', 'space_switch_split'):
                ok = ok and all(v['settledAtDestination'] for v in verdicts) and not motion['presentationUnavailable']
            if name == 'space_switch_warm':
                ok = ok and not any(v['themeFieldFrames'] for v in verdicts)  # current snapshot: no field
            if name == 'space_switch_native':
                ok = ok and app.call('welcome')['visible'] and not motion['presentationUnavailable']
            results['%s_%s' % (prefix, name)] = dict(ok=ok, coverKillSwitch=off, motion=motion,
                destinationShownAfterSeconds=first,
                regions=verdicts, evidence=str(evidence), loadAverage=list(os.getloadavg()))
            app.call('space', space=space_a); time.sleep(1.0)
    finally:
        server.shutdown()
        app.quit()
