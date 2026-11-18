#!/usr/bin/env python3
"""Record the four basics clips from the real Open app.

Each clip starts from a fresh, scripted profile with our own fixture pages
(tools/basics/site, served on fictional .example hosts through the loopback
server). The timeline drives the real app only through the automation socket:
the virtual pointer for hover and clicks, keys for typing, and `basics-demo`
for sidebar drags (the same drag-source state and NSDraggingDestination
callbacks AppKit runs during a real drag). Every pointer move and drag step is
logged with host-clock times; tools/basics/post.py draws the pointer and the
drag image from that log. Nothing in post changes the app's own motion.

  demo.py --app Open.app --out DIR [--clips pin,spaces,split,newtab] [--dry]
          [--recorder BIN --launcher OpenCapture.app --pixels tools/capture/pixels.sh]

--dry runs the timelines without the recorder (in-app snapshots instead), for
checking a script on any Mac. Recording runs on the M1 under the screen lock.
"""
import argparse, json, math, os, runpy, subprocess, sys, tempfile, threading, time
from functools import partial
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = Path(__file__).resolve().parent / 'site'
sys.path.insert(0, str(ROOT / 'tools/e2e'))
from loopback_http import LoopbackHTTPServer  # noqa: E402
import http.server  # noqa: E402

CLIP_SECONDS = 8.5
LEAD_IN = 0.5
TAIL = 0.6
CROP = (0, 0, 960, 600)  # window points, top-left origin
WINDOW = (40, 40, 960, 600)  # recorded whole, as on the reference clips

PAGES = {
    ('travel.example', '/lisbon'): 'travel-lisbon.html', ('travel.example', '/porto'): 'travel-porto.html',
    ('kitchen.example', '/plum-cake'): 'kitchen-plum-cake.html', ('convert.example', '/scale'): 'convert-scale.html',
    ('plans.example', '/week'): 'plans-week.html', ('notes.example', '/reading'): 'notes-reading.html',
}
URL = {name: 'http://%s%s' % key for key, name in
       [(k, v.split('.')[0]) for k, v in PAGES.items()]}
# URL['travel-lisbon'] = 'http://travel.example/lisbon', and so on.

PERSONAL_THEME = {'mathVersion': 1, 'keyColor': {'red': 0.66, 'green': 0.62, 'blue': 0.93, 'alpha': 1}, 'colorCount': 1,
                  'wheel': 'analogous', 'appearance': 'light', 'noiseFactor': 0, 'texture': 'grain', 'intensityFactor': .8}
WORK_THEME = {'mathVersion': 1, 'keyColor': {'red': 0.55, 'green': 0.80, 'blue': 0.74, 'alpha': 1}, 'colorCount': 1,
              'wheel': 'analogous', 'appearance': 'light', 'noiseFactor': 0, 'texture': 'grain', 'intensityFactor': .8}


def host_now():
    """Host clock (mach absolute time), the clock of ScreenCaptureKit frame times."""
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_GET(self):
        host = (self.headers.get('Host') or '').split(':')[0]
        name = 'base.css' if self.path == '/base.css' else PAGES.get((host, self.path))
        if not name:
            self.send_error(404); return
        body = (SITE / name).read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'text/css' if name.endswith('.css') else 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)


def ease(u):
    """Minimum-jerk position profile: the speed curve of a natural hand move."""
    u = min(1.0, max(0.0, u))
    return u * u * u * (10 - 15 * u + 6 * u * u)


class Timeline:
    """Runs one clip: timed socket actions plus a logged virtual pointer."""

    def __init__(self, app, t0, dry):
        self.app, self.t0, self.dry = app, t0, dry
        self.pointer = None
        self.snap_dir, self.snaps = None, 0
        self.log = {'t0': t0, 'moves': [], 'drags': [], 'clicks': [], 'keys': [], 'events': []}

    def at(self, t):
        while True:
            self.snapshot_if_due()
            delay = self.t0 + t - host_now()
            if delay <= 0: return
            time.sleep(min(delay, 0.02))

    def snapshot_if_due(self):
        """--dry only: in-app snapshots every 0.5 s, on this thread (one socket client)."""
        if not self.dry or self.snap_dir is None: return
        due = self.t0 + self.snaps * 0.5
        if host_now() >= due and self.snaps < 19:
            self.app.call('snapshot', path=str(self.snap_dir / ('dry-%02d.png' % self.snaps))); self.snaps += 1

    def place(self, point):
        self.pointer = list(point)
        self.log['moves'].append({'start': host_now(), 'duration': 0, 'from': self.pointer, 'to': self.pointer})
        self.app.call('mouse', action='move', x=point[0], y=point[1])

    def move(self, t, to, duration, hover=True, drag=False, rate=30.0):
        """Move the pointer from where it is to `to` over `duration` seconds."""
        self.at(t)
        start, origin = host_now(), list(self.pointer)
        self.log['moves'].append({'start': start, 'duration': duration, 'from': origin, 'to': list(to)})
        step = 1.0 / rate
        while True:
            u = min(1.0, (host_now() - start) / duration)
            k = ease(u)
            p = [origin[0] + (to[0] - origin[0]) * k, origin[1] + (to[1] - origin[1]) * k]
            if drag:
                self.app.call('basics-demo', op='drag-over', point=p)
            elif hover:
                self.app.call('mouse', action='hover', x=p[0], y=p[1])
            if u >= 1: break
            self.snapshot_if_due()
            time.sleep(max(0, step - ((host_now() - start) % step)))
        self.pointer = list(to)

    def click(self, t):
        self.at(t)
        state = self.app.call('basics-demo', op='window')
        active = self.app.call('native-focus-state').get('active')
        self.log['clicks'].append({'time': host_now(), 'point': self.pointer, 'tooltip': state.get('tooltip'), 'active': active})
        self.app.call('mouse', action='click', x=self.pointer[0], y=self.pointer[1])

    def drag_begin(self, t, node, image):
        self.at(t)
        result = self.app.call('basics-demo', op='drag-begin', node=node, point=self.pointer, image=str(image))
        self.log['drags'].append({'start': host_now(), 'grab': list(self.pointer), 'image': str(image),
                                  'imageSize': result['imageSize'], 'pixels': result['pixels'], 'row': result['row']})

    def drag_end(self, t, perform=True):
        self.at(t)
        result = self.app.call('basics-demo', op='drag-end', point=self.pointer, perform=perform)
        self.log['drags'][-1].update(end=host_now(), accepted=result['accepted'])
        return result

    def key(self, t, **kwargs):
        self.at(t)
        self.log['keys'].append({'time': host_now(), **kwargs})
        self.app.call('key', **kwargs)

    def event(self, t, name, fn):
        self.at(t)
        self.log['events'].append({'time': host_now(), 'name': name})
        return fn()


def targets(app):
    return app.call('basics-demo', op='targets')


def row(app, title):
    for r in targets(app)['rows']:
        if r['title'] == title:
            return r
    raise RuntimeError('no sidebar row titled %r' % title)


def center(frame, dx=None):
    x = frame[0] + (dx if dx is not None else frame[2] / 2)
    return [x, frame[1] + frame[3] / 2]


# ---------------------------------------------------------------- profile

def build_profile(app, clip):
    """A fresh Personal + Work setup. Returns ids by role."""
    first = app.call('tabs')[0]['id']
    spaces = app.call('spaces')
    personal = spaces[0]['id']
    app.call('basics-demo', op='space-icon', space=personal, emoji='🏡', title='Personal')
    app.call('theme-set', space=personal, style=PERSONAL_THEME)

    def open_tab(url, background=True):
        tab = app.call('open', url=url, background=background)
        app.call('wait', tab=tab['id'], timeout=20)
        return tab['id']

    ids = {}
    # Favorites: three of our own sites.
    app.call('appearance', name='light')
    # Size the window first: every tab renders at the size the clip shows, as
    # for a user who visited both Spaces (the resize case is welcome W40).
    app.call('window-frame', frame=list(WINDOW))
    for name in ('plans-week', 'notes-reading', 'convert-scale'):
        tab = open_tab(URL[name]); app.call('favorite', tab=tab)
    # Pinned folders with a few saved pages.
    trips = [open_tab(URL['travel-porto'])] if clip != 'pin' else []
    reading = [open_tab(URL['notes-reading'])]
    for title, tabs in (('Trips', trips), ('Reading', reading)):
        if tabs: app.call('folder', title=title, section='pinned', tabs=tabs)
    app.call('folder-create', title='Recipes')
    # Today.
    if clip == 'pin':
        ids['porto'] = open_tab(URL['travel-porto'])
        ids['lisbon'] = open_tab(URL['travel-lisbon'], background=False)
    elif clip == 'split':
        ids['scaler'] = open_tab(URL['convert-scale'])
        ids['lisbon'] = open_tab(URL['travel-lisbon'])
        ids['cake'] = open_tab(URL['kitchen-plum-cake'], background=False)
    elif clip == 'newtab':
        visited = open_tab(URL['kitchen-plum-cake'])  # history for the command bar suggestion
        app.call('close', tab=visited)
        ids['lisbon'] = open_tab(URL['travel-lisbon'], background=False)
    else:
        ids['lisbon'] = open_tab(URL['travel-lisbon'], background=False)
    app.call('close', tab=first)
    if clip == 'spaces':
        work = app.call('space-create', title='Work')
        app.call('basics-demo', op='space-icon', space=work, emoji='🚀', title='Work')
        app.call('theme-set', space=work, style=WORK_THEME)
        app.call('folder-create', title='Projects'); app.call('folder-create', title='Team')
        week = open_tab(URL['plans-week'], background=False)
        app.call('space', space=personal)
        ids.update(work=work, personal=personal, week=week)
    else:
        # A second Space so the switcher shows Spaces (as on the reference).
        work = app.call('space-create', title='Work')
        app.call('basics-demo', op='space-icon', space=work, emoji='🚀', title='Work')
        app.call('theme-set', space=work, style=WORK_THEME)
        app.call('space', space=personal)
    time.sleep(1.0)
    return ids


# ---------------------------------------------------------------- clips

def clip_pin(tl, app, ids, scratch):
    t = targets(app)
    page = t['page']
    tl.place([page[0] + 300, page[1] + 330])
    porto = row(app, 'Where to Stay in Porto')['frame']
    tl.move(0.4, center(porto, 70), 1.2)
    tl.drag_begin(2.0, ids['porto'], scratch / 'drag-porto.png')
    recipes = row(app, 'Recipes')['frame']  # the last pinned row: drop at the end of Pinned
    tl.move(2.05, [recipes[0] + 70, recipes[1] + recipes[3] + 6], 1.1, drag=True)
    tl.drag_end(3.3)
    lisbon = tl.event(3.45, 'targets', lambda: row(app, 'Three Days in Lisbon')['frame'])
    tl.move(3.5, center(lisbon, 70), 1.1)
    tl.drag_begin(4.85, ids['lisbon'], scratch / 'drag-lisbon.png')
    porto = row(app, 'Where to Stay in Porto')['frame']
    tl.move(4.9, [porto[0] + 70, porto[1] + porto[3] + 4], 1.1, drag=True)
    tl.drag_end(6.15)
    tl.move(6.5, [page[0] + 220, page[1] + 300], 1.1)


def clip_spaces(tl, app, ids, scratch):
    t = targets(app)
    page = t['page']
    switch = {s['title']: s['frame'] for s in t['spaces']}
    tl.place([page[0] + 260, page[1] + 380])
    # Each click waits for the switcher's tooltip (0.6 s hover delay), as on the reference.
    tl.move(0.2, center(switch['Work']), 1.0)
    tl.click(2.3)
    tl.move(3.4, center(switch['Personal']), 0.6)
    tl.click(4.8)
    tl.move(5.3, center(switch['Work']), 0.5)
    tl.click(6.6)
    tl.move(7.2, [tl.pointer[0] + 40, tl.pointer[1] - 90], 0.8)


def clip_split(tl, app, ids, scratch):
    t = targets(app)
    page = t['page']
    tl.place([page[0] + 360, page[1] + 300])
    scaler = row(app, 'Recipe Scaler')['frame']
    tl.move(0.3, center(scaler, 70), 1.2)
    tl.drag_begin(1.9, ids['scaler'], scratch / 'drag-scaler.png')
    tl.move(1.95, [page[0] + page[2] * 0.86, page[1] + page[3] * 0.42], 1.3, drag=True)  # Open's right split zone
    tl.drag_end(3.5)
    tl.move(4.2, [page[0] + page[2] * 0.30, page[1] + page[3] * 0.55], 1.0)
    tl.click(5.6)


def clip_newtab(tl, app, ids, scratch):
    t = targets(app)
    page = t['page']
    tl.place([page[0] + 260, page[1] + 340])
    tl.move(0.3, center(t['newTab'], 80), 1.2)
    tl.click(1.9)
    for i, ch in enumerate('plum'):
        tl.key(2.5 + i * 0.32, text=ch)
    tl.key(4.25, key='down')  # from the search row to the history row "Plum Cake"
    tl.key(4.9, key='return')
    tl.move(5.2, [tl.pointer[0] + 30, tl.pointer[1] + 110], 0.9)


CLIPS = {'pin': clip_pin, 'spaces': clip_spaces, 'split': clip_split, 'newtab': clip_newtab}


# ---------------------------------------------------------------- run

def record(options, name, h, port):
    out = Path(options.out) / name
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='open-basics-%s-' % name, dir='/tmp') as scratch:
        scratch = Path(scratch)
        # The Space cover (engine presentation seam): no empty page frame on a switch.
        args = ['--use-mock-keychain', '--skip-first-run', '--no-proxy-server', '-OpenSeamSpaceCover', 'YES',
                '--host-resolver-rules=MAP *.example 127.0.0.1:%d, MAP * ~NOTFOUND' % port]  # no network
        env = {'OPEN_E2E_APP_BUNDLE': options.app, 'OPEN_E2E_REDUCE_MOTION': '0'}
        app = h['Open']('Release', 'chrome', str(scratch / 'root'), args, str(scratch / 'app.log'),
                        urls=('about:blank',), extra_env=env)
        try:
            ids = build_profile(app, name)
            window = app.call('basics-demo', op='window')
            recorder = None
            if not options.dry:
                log = out / 'recorder.log'
                recorder = subprocess.Popen(['/usr/bin/open', '-g', '-n', '-W', options.launcher, '--args', options.pixels, str(log),
                    options.recorder, str(window['pid']), str(window['number']), str(out),
                    str(LEAD_IN + CLIP_SECONDS + TAIL), str(window['scale']), *map(str, CROP)])
                deadline = time.monotonic() + 15
                while not (out / 'ready').exists():
                    if recorder.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('recorder did not start; see %s' % log)
                    time.sleep(0.02)
                t0 = float((out / 'ready').read_text()) + LEAD_IN
                # Launching the recorder through its app can take activation.
                # Take it back within the lead-in: an inactive window draws gray
                # traffic lights and hides tooltip panels.
                for _ in range(3):
                    app.call('window-focus', id=app.call('window-state')['id'], activate=True)
                    time.sleep(0.12)
                if not app.call('native-focus-state').get('active'):
                    raise RuntimeError('Open is not active for the recording')
            else:
                t0 = host_now() + LEAD_IN
            tl = Timeline(app, t0, options.dry)
            if options.dry: tl.snap_dir = out
            CLIPS[name](tl, app, ids, scratch)
            tl.at(CLIP_SECONDS + TAIL)
            for drag in tl.log['drags']:
                image = Path(drag['image'])
                if image.exists():
                    target = out / image.name; target.write_bytes(image.read_bytes()); drag['image'] = target.name
            if recorder:
                recorder.wait(timeout=30)
                if recorder.returncode != 0 or not (out / 'capture.mov').exists():
                    raise RuntimeError('recorder failed; see %s' % (out / 'recorder.log'))
            tl.log.update(clip=name, window=window, crop=CROP, seconds=CLIP_SECONDS, leadIn=LEAD_IN,
                          source=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
                          if (ROOT / '.git').exists() else os.environ.get('OPEN_BASICS_SOURCE', 'unknown'))
            (out / 'timeline.json').write_text(json.dumps(tl.log, indent=1))
            print(json.dumps({'clip': name, 'out': str(out), 'drags': [d.get('accepted') for d in tl.log['drags']]}), flush=True)
        finally:
            app.quit()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--app', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--clips', default='pin,spaces,split,newtab')
    p.add_argument('--dry', action='store_true')
    p.add_argument('--recorder', default='/tmp/open-basics-recorder')
    p.add_argument('--launcher', default=str(Path.home() / 'Applications/OpenCapture.app'))
    p.add_argument('--pixels', default=str(ROOT / 'tools/capture/pixels.sh'))
    options = p.parse_args()
    h = runpy.run_path(str(ROOT / 'tools/e2e/engine_e2e.py'))
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for name in options.clips.split(','):
            record(options, name, h, server.server_address[1])
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
