"""Real first-window ordering checks, including a blocked engine-start fixture."""
import json
import os
import threading
import time
from pathlib import Path


def before_engine(timing, startup, evidence):
    keys = ('windowShown', 'firstWindowDrawn', 'engineStart', 'engineStarted')
    marks = [timing.get(key) for key in keys]
    return (all(isinstance(t, (int, float)) for t in marks)
            and marks == sorted(marks)
            and timing.get('firstFrameConfirmed') is True
            and evidence.get('visibleOnboardingWindows') == 1
            and evidence.get('pagesBeforeEngine') == 0
            and evidence.get('contextsBeforeEngine') == 0
            and isinstance(startup.get('firstWindowFrameHostTime'), (int, float))
            and startup['firstWindowFrameHostTime'] < startup.get('engineStartBeginHostTime', 0))


def run(factory, results, tmp, h):
    # Observe only the owned PID while the main thread is in the forced delay.
    # The existing native helper reads the window server, without UI input.
    observed = {}
    done = threading.Event()
    previous = set(id(a) for a in h._OWNED_APPS)
    offsets = {a.log.name: Path(a.log.name).stat().st_size for a in h._OWNED_APPS}

    def observe():
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not done.wait(.02):
                app = next((a for a in h._OWNED_APPS if id(a) not in previous and a.pid), None)
                if app is None:
                    continue
                with Path(app.log.name).open(errors='replace') as log:
                    log.seek(offsets.get(app.log.name, 0))
                    text = log.read()
                if 'Open: pre-engine timing ' not in text:
                    continue
                sample = h.subprocess.run([app.window_counter, str(app.pid)], capture_output=True, text=True, timeout=5)
                if sample.returncode:
                    raise RuntimeError(sample.stderr)
                observed.update(json.loads(sample.stdout))
                observed['beforeAutomationReady'] = not done.is_set()
                return
        except Exception as error:
            observed['error'] = str(error)

    observer = threading.Thread(target=observe, daemon=True)
    observer.start()
    app = None
    try:
        app = factory(urls=(), fresh=True, extra_args=['--intro-sound=off'],
                      extra_env={'OPEN_AUTOMATION_ENGINE_START_DELAY_MS': '2000'})
        done.set(); observer.join(timeout=6)
        timing, state, evidence = app.call('timing'), app.call('onboarding'), app.call('startup')
        startup = state.get('startup', {})
        results['first_window_before_slow_engine'] = dict(ok=before_engine(timing, startup, evidence)
            and timing['engineStarted'] - timing['engineStart'] >= 2000,
            timing=timing, startup=startup, evidence=evidence, load=os.getloadavg())
        results['first_window_server_before_engine_ready'] = dict(ok=observed.get('count', 0) == 1
            and observed.get('beforeAutomationReady') is True
            and any(w['number'] == evidence.get('onboardingWindowNumber') for w in observed.get('windows', [])),
            observed=observed, load=os.getloadavg())
        # The very same window survives the engine/animation transition.
        results['first_window_reused'] = dict(ok=state.get('window') == evidence.get('onboardingWindowNumber')
            and startup.get('windowCreationHostTime', 1) < startup.get('firstWindowFrameHostTime', 0),
            window=state.get('window'), evidence=evidence, load=os.getloadavg())
    finally:
        done.set(); observer.join(timeout=6)
        if app is not None:
            app.quit()

    # Termination in the temporary native loop must skip Chromium entirely.
    root = Path(tmp)/'first-window-early-quit'
    log = Path(tmp)/'first-window-early-quit.log'
    with log.open('w') as stream:
        quit = h.subprocess.run([app.executable, '--user-data-dir='+str(root), '--intro-sound=off'],
            env=dict(os.environ, OPEN_AUTOMATION_QUIT_BEFORE_ENGINE='1', OPEN_E2E_OWNER_PID=str(os.getpid()),
                     OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS='1'), stdout=stream, stderr=h.subprocess.STDOUT, timeout=15)
    text = log.read_text(errors='replace')
    results['first_window_quit_before_engine'] = dict(ok=quit.returncode == 0
        and 'termination before engine' in text and 'terminationSkippedEngine' in text
        and 'engineStart' not in text and not (root/'State/browser.json').exists(),
        exit=quit.returncode, load=os.getloadavg())
    unconfirmed = None
    try:
        unconfirmed = factory(urls=(), fresh=True, extra_args=['--intro-sound=off'],
                              extra_env={'OPEN_AUTOMATION_SKIP_DISPLAY_LINK': '1'})
        timing = unconfirmed.call('timing')
        results['first_window_timeout_continues'] = dict(ok=timing.get('firstFrameConfirmed') is False
            and 'firstWindowDrawn' not in timing and 'sidebarDrawn' not in timing
            and timing.get('firstFrameWaitTimedOut', 0) >= 3000
            and timing.get('engineStart', 0) >= timing['firstFrameWaitTimedOut']
            and 'engineStarted' in timing and unconfirmed.call('onboarding').get('active') is True,
            timing=timing, load=os.getloadavg())
    finally:
        if unconfirmed is not None:
            unconfirmed.quit()
