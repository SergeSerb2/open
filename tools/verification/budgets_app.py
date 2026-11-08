"""Real-App workloads extracted from S16 run_launch.py/run_idle.py.

The source research is .re/s16/speed/REPORT.md (2026-11-07). The socket,
process sampler, frame marks, activation and cleanup remain engine_e2e's.
No traces or diagnostic observers run in the primary CPU windows.
"""
import math
import json
import os
from pathlib import Path
import statistics
import signal
import time


PAGES = ['https://example.com/', 'https://example.org/',
         'https://en.wikipedia.org/wiki/Web_browser', 'https://www.iana.org/',
         'https://developer.mozilla.org/en-US/', 'https://news.ycombinator.com/',
         'https://www.w3.org/', 'https://github.com/', 'https://www.rust-lang.org/',
         'https://www.python.org/']
FIXTURE = 'data:text/html,<title>Open launch fixture</title><h1>Open launch fixture</h1>'


def summary(values):
    return {'median': statistics.median(values),
            'p95': sorted(values)[math.ceil(len(values) * .95) - 1]}


def profile_roots(kind, data_root):
    """Share exact App roots with the launch-free socket-path preflight."""
    profile = Path(data_root) / 'profile'
    if kind in ('first-run', 'find'):
        return [profile / str(index) for index in range(5 if kind == 'first-run' else 20)]
    return [profile]


def run(kind, h, app_bundle, scratch, data_root):
    scratch = Path(scratch)
    data_root = Path(data_root)
    profiles = profile_roots(kind, data_root)
    profile = profiles[0]
    (data_root / 'profile').mkdir()
    cleanups = []

    def owned_open(*args, **kwargs):
        # engine_e2e.Open joins user_data with automation.sock. Check again at
        # the call site so a future workload cannot bypass parent preflight.
        socket_path = Path(args[2]) / 'automation.sock'
        for path in (socket_path, socket_path.resolve()):
            if len(os.fsencode(path)) > 100:
                raise RuntimeError('automation socket path exceeds 100 bytes: ' + str(path))
        # Let the existing constructor record ownership before cancellation can
        # unwind it. LaunchServices starts the App independently of this mask.
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGINT, signal.SIGHUP))
        try:
            app = h.Open(*args, **kwargs)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        tracker = h._ACTIVE_FOCUS_TRACKER
        if tracker:
            tracker.apps.append(app)
            app.focus_tracker = tracker
        return app

    def launch(urls):
        return owned_open('Release', 'chrome', str(profile), ['--use-mock-keychain'],
                      str(scratch / 'app.log'), urls=urls,
                      extra_env={'OPEN_E2E_APP_BUNDLE': str(app_bundle)})

    def close(app):
        app.quit()
        cleanups.append(app.quit_report)
        if not app.quit_report.get('ok'):
            raise RuntimeError('owned App/window cleanup failed')

    if kind == 'first-run':
        # firstrun.py F12 and docs/first-run/steps-ef-verification.md:
        # five fresh Welcome roots, then selected imported-tab paint relative
        # to firstRunLandingStarted. Reuse its synthetic import schema.
        import firstrun
        source = data_root / 'fixtures'
        firstrun.fixture(source)
        sidebar_file = source / 'StorableSidebar.json'
        sidebar = json.loads(sidebar_file.read_text())
        def local_pages(value):
            if isinstance(value, dict):
                for key in value:
                    if key == 'savedURL':
                        value[key] = FIXTURE
                    else:
                        local_pages(value[key])
            elif isinstance(value, list):
                for item in value:
                    local_pages(item)
        local_pages(sidebar)
        sidebar_file.write_text(json.dumps(sidebar))
        samples = []
        for root in profiles:
            root.mkdir()
            app = owned_open('Release', 'chrome', str(root),
                         ['--use-mock-keychain', '--arc-dir=' + str(source)],
                         str(scratch / 'app.log'), urls=(), first_run=True,
                         extra_env={'OPEN_E2E_APP_BUNDLE': str(app_bundle)})
            try:
                state = app.call('first-run')
                if not state['active'] or state['step'] != 'welcome':
                    raise RuntimeError('first-run Welcome fixture missing')
                timing = app.call('timing')
                if not timing.get('kernelProcessStart') or 'sidebarDrawn' not in timing:
                    raise RuntimeError('first-run kernel/frame timing missing')
                if not h.wait_until(lambda: app.call('first-run').get('probeReady'), timeout=10, step=.05):
                    raise RuntimeError('synthetic import probe not ready')
                app.call('first-run', action='import')
                app.call('first-run', action='continue')
                if not h.wait_until(lambda: app.call('first-run')['step'] == 'report', timeout=30, step=.05):
                    raise RuntimeError('synthetic first-run import did not finish')
                app.call('first-run', action='continue')
                app.call('first-run', action='finish')
                if not h.wait_until(lambda: 'firstContentfulPaint' in app.call('timing'), timeout=15, step=.1):
                    raise RuntimeError('imported first paint missing')
                landed = app.call('timing')
                samples.append(dict(welcome=timing, landing=landed,
                                    imported_paint_ms=landed['firstContentfulPaint'] - landed['firstRunLandingStarted']))
            finally:
                close(app)
        return dict(samples=samples, cleanup=cleanups)

    if kind == 'launch':
        app = launch((FIXTURE,))
        try:
            tab = app.call('tabs')[0]
            app.call('wait', tab=tab['id'])
            app.call('open', url='data:text/html,<title>Unselected</title><h1>Unselected</h1>')
            app.call('select', tab=tab['id'])
            app.call('save')
        finally:
            close(app)
        samples = []
        for index in range(7):
            before = list(os.getloadavg())
            app = launch(())
            try:
                selected = next(t for t in app.call('tabs') if t['selected'])
                app.call('wait', tab=selected['id'])
                if not h.wait_until(lambda: 'firstContentfulPaint' in app.call('timing'), timeout=10, step=.1):
                    raise RuntimeError('no restored first contentful paint')
                timing = app.call('timing')
                tabs = app.call('tabs')
                if not (timing.get('kernelProcessStart') is True
                        and timing.get('firstFrameConfirmed') is True
                        and len(tabs) == 2 and sum(t['loaded'] for t in tabs) == 1):
                    raise RuntimeError('warm_existing_profile frame/selected-only proof failed')
                samples.append(dict(index=index, timing=timing, load_start=before,
                                    load_end=list(os.getloadavg()), startup=app.call('startup')))
            finally:
                close(app)
        return dict(samples=samples, cleanup=cleanups)

    if kind.startswith('idle-'):
        app = launch((PAGES[0],))
        try:
            try:
                app.call('wait', tab=app.call('tabs')[0]['id'], timeout=30)
            except RuntimeError:
                pass  # Same bounded public-page wait as S16 research.
            for url in PAGES[1:]:
                h.new_tab(app, url)
            if kind == 'idle-static':
                selected = next(t for t in app.call('tabs') if t['selected'])
                app.call('navigate', tab=selected['id'], url=FIXTURE)
                app.call('wait', tab=selected['id'], timeout=30)
            time.sleep(90)
            state = app.call('window-state')
            sleep_before = app.call('sleep-state')
            cpu = h.process_cpu_window(app, 60)
            sleep_after = app.call('sleep-state')
            tabs = app.call('tabs')
            if len(tabs) != 10:
                raise RuntimeError('idle fixture must retain ten model tabs')
            return dict(cpu=cpu, window=state, sleep_before=sleep_before,
                        sleep_after=sleep_after, tab_count=len(tabs), cleanup=cleanups,
                        selected_static=kind == 'idle-static')
        finally:
            close(app)

    if kind == 'command-open':
        app = launch((FIXTURE,))
        try:
            tab = app.call('tabs')[0]['id']
            app.call('wait', tab=tab)
            app.call('suggest-remote', enabled=False)
            if not h.wait_until(lambda: app.call('hotkey-state')['prepared'], timeout=5, step=.02):
                raise RuntimeError('command preparation missing')
            app.call('focus', tab=tab)
            # app-actions first_open_results_budget: native window key route.
            app.call('key', key='t', modifiers=['cmd'], route='window')
            state = h.wait_until(lambda: (s if (s := app.call('commandbar-state')).get('openFirstResultsMs', -1) >= 0 else None), step=.02)
            if not state:
                raise RuntimeError('no first-results mark')
            return dict(milliseconds=state['openFirstResultsMs'], cleanup=cleanups)
        finally:
            close(app)

    if kind == 'find':
        # find_checks.py F04_one_frame, its twenty fresh windows and native
        # application key timestamps. No observer build/idle diagnostic here.
        server, origin = h._static_server(str(Path(h.ROOT) / 'tools/e2e/fixtures/find'))
        samples = []
        try:
            for profile in profiles:
                profile.mkdir()
                app = launch((origin + '/index.html',))
                try:
                    tab = app.call('tabs')[0]['id']
                    app.call('wait', tab=tab)
                    window = app.call('window-state')
                    app.call('window-focus', id=window['id'], activate=True)
                    viewport = window['toolbar']['page'][2:]
                    if not h.wait_until(lambda: app.eval(tab, '[window.innerWidth,window.innerHeight,document.readyState]') == viewport + ['complete'], timeout=5, step=.05):
                        raise RuntimeError('Find fixture viewport not settled')
                    cold = app.call('find-state')
                    app.call('focus', tab=tab)
                    app.call('key', route='app', key='f', modifiers=['cmd'])
                    first = app.call('find-state')
                    app.call('key', route='app', key='escape')
                    app.call('focus', tab=tab)
                    app.call('key', route='app', key='f', modifiers=['cmd'])
                    repeat = app.call('find-state')
                    visible = all(any(p['tab'] == tab and p['visible'] for p in s['panes']) for s in (first, repeat))
                    if not visible or cold.get('created', bool(cold.get('panes'))):
                        raise RuntimeError('Find lazy/visible fixture proof failed')
                    samples.append(dict(first=first['presentationPhases']['commit'],
                                        repeat=repeat['presentationPhases']['commit'],
                                        load=list(os.getloadavg())))
                finally:
                    close(app)
            return dict(samples=samples, cleanup=cleanups)
        finally:
            server.shutdown()
            server.server_close()

    if kind == 'tab-switch':
        # tools/verification/split-app-speed.py: same root singles/split fixture,
        # same op=bench endpoint (40 samples/path; max native flush + every-pane rAF).
        server, origin = h._fixture_server('Split speed')
        app = None
        try:
            app = launch(())
            app.call('suggest-remote', enabled=False)
            app.call('window-frame', frame=[60, 60, 1360, 860])
            ids = []
            for name in ('first', 'second', 'third', 'fourth'):
                tid = app.call('open', url=origin + '/' + name)['id']
                app.call('wait', tab=tid)
                ids.append(tid)
            app.call('select', tab=ids[2])
            app.call('sidebar-menu', node=ids[3], item='Open in Split View')
            split = next(n for n in app.call('sidebar-tree')['today'] if n['kind'] == 'split')
            if {n['id'] for n in split['children']} != set(ids[2:]):
                raise RuntimeError('split fixture panes differ')
            for index, pane in enumerate(split['children']):
                app.call('navigate', tab=pane['id'], url=origin + '/pane-' + str(index))
                app.call('wait', tab=pane['id'])
            app.call('focus', tab=split['children'][-1]['id'])
            measured = app.call('split', op='bench', nodes=[ids[0], ids[1], split['id']])
            return dict(samples=measured, cleanup=cleanups)
        finally:
            if app:
                close(app)
            server.shutdown()
            server.server_close()
    raise RuntimeError('unknown App workload ' + kind)
