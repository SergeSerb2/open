"""Bug sweep r6 seed 8 (#643 L11): a relaunch with no input writes the snapshot at most once.

Called by the relaunch suite (OPEN_RELAUNCH_SAVES_ONLY=1 runs only this row). The App is quit
for real and relaunched with no input. Its snapshot captures are read until tab sleep (which
stamps the visible tab) is prepared and the 1 s save debounce has passed.
"""
import time


def run(factory, results, harness):
    E = harness
    app = factory(urls=(), fresh=True)
    try:
        E.new_tab(app, 'data:text/html,<title>Relaunch saves A</title>')
        E.new_tab(app, 'data:text/html,<title>Relaunch saves B</title>')
        app.call('save')
        app.call('quit')
        E.wait_until(lambda: not app.process_path(app.pid), timeout=20, step=.05)
    finally:
        app.quit()
    app = factory(urls=())
    try:
        started = time.monotonic()
        samples = []
        def sample():
            c = app.call('frame-save-counters')
            samples.append([round(time.monotonic() - started, 2), c['captures'], c['scheduled'], c['dirty']])
            return c
        # Tab sleep starts after the first paint and stamps the visible tab (the second save on
        # main). Wait until it is prepared, then past the 1 s save debounce, before counting.
        prepared = None
        while time.monotonic() - started < 20:
            sample()
            if prepared is None and app.call('sleep-state').get('prepared'): prepared = time.monotonic()
            if prepared is not None and time.monotonic() - prepared > 2.5 and time.monotonic() - started > 5: break
            time.sleep(.1)
        final = sample()
        changes = [s for i, s in enumerate(samples) if i == 0 or s[1:] != samples[i - 1][1:]]
        ok = prepared is not None and final['captures'] <= 1 and not final['dirty']
        results['R6_relaunch_no_input_saves_once'] = {'ok': ok, 'sleepPrepared': prepared is not None,
            'sleepPreparedAt': prepared and round(prepared - started, 2),
            'captures': final['captures'], 'scheduled': final['scheduled'], 'dirty': final['dirty'], 'changes': changes}
        print('R6_relaunch_no_input_saves_once', 'PASS' if ok else 'FAIL', changes, flush=True)
    finally:
        app.quit()
