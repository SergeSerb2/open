"""Real App/window onboarding gates. Owned roots, seeded source, no audible audio.

Each negative proof applies the SAME predicate to a contrasting, real App run
or to the real flow before its trigger (for example before Esc, with measuring
disabled, or with sound off). No synthetic telemetry or mocked player is used.
"""
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import tempfile
import time


def run(factory, results, tmp, h):
    if os.environ.get('OPEN_E2E_ONBOARDING_STEPS_ONLY') == '1':
        return runpy.run_path(str(Path(h.ROOT)/'tools/e2e/onboarding_steps.py'))['run'](factory, results, tmp, h)
    source = Path(tmp)/'intro-arc-synthetic'
    shutil.rmtree(source, ignore_errors=True)
    runpy.run_path(str(Path(h.ROOT)/'tools/e2e/firstrun.py'))['fixture'](source)
    evidence = Path(h.ROOT)/'.re/handoff/sections/s17/c2'
    evidence.mkdir(parents=True, exist_ok=True)
    exported = h.subprocess.run(['defaults', 'export', 'io.github.sergeserb2.open', '-'], capture_output=True)
    domain = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    keys = ('open.onboarding.introSoundEnabled', 'open.firstRun.completed')
    saved = {key: domain.get(key) for key in keys}
    app = None
    negatives = {}

    def launch(*args, fresh=True):
        nonlocal app
        if app and not app.closed: app.quit()
        app = factory(urls=(), fresh=fresh, extra_args=['--arc-dir='+str(source), '--intro-sound=silent', *args])
        return app

    def state(): return app.call('onboarding', action='state')
    def until(predicate, timeout=15): return h.wait_until(predicate, timeout=timeout, step=.025)
    def elapsed(t):
        until(lambda: state().get('elapsed', 0) >= t)
        return state()
    def gate(name, predicate, observed, broken, **details):
        passed, rejected = bool(predicate(observed)), not bool(predicate(broken))
        results[name] = dict(ok=passed, state=observed, load=os.getloadavg(), **details)
        negatives[name] = dict(ok=rejected, expected='FAIL', observed=broken)
        results[name+'_negative'] = dict(ok=rejected, expected='FAIL', load=os.getloadavg())

    try:
        h._restore_defaults(None, {key: None for key in keys})
        launch('--measure-intro-frames')
        before = state()
        intro = elapsed(.3)
        # Native Return/Space reach OEApplication, and cannot advance early.
        app.call('key', key='return'); app.call('key', key='space')
        early_keys = state()
        for key in ('t', 'l'): app.call('key', key=key, modifiers=['command'])
        guarded = dict(intro=state(), browsers=app.call('shell-windows'))
        dim = elapsed(1.7)
        app.call('snapshot', path=str(evidence/'intro-native-initial.png'))
        phase0 = state()
        phase1 = elapsed(3.5)
        phase2 = elapsed(10.3)
        gate('early_keys_do_not_advance', lambda s: s.get('active') and s.get('screen')=='intro' and not s.get('ready'), early_keys, phase2)
        app.call('snapshot', path=str(evidence/'intro-native-completed.png'))
        phase_pred = lambda rows: [s['phase'] for s in rows] == ['introAnimation', 'sellIntro', 'sellCompleted'] and rows[-1]['buttonEnabled'] and rows[-1]['buttonDefault'] and rows[-1]['buttonLabel']=='Get Started'
        gate('phases_reached_in_order', phase_pred, [phase0, phase1, phase2], [phase0, phase1, phase1])
        frame_pred = lambda s: s.get('frameStats', {}).get('count', 0) >= 30 and not s['frameStats']['running']
        played_pred = lambda s: s.get('sound', {}).get('decision') == 'played' and s['sound']['playerCreated'] and abs(s['sound']['audioStartHostTime']-s['animationStartHostTime']) <= .020
        played = phase1
        invalid = []
        for arguments in (dict(action='x'*33), dict(action='state', unexpected=True)):
            try: app.call('onboarding', **arguments)
            except RuntimeError: invalid.append(True)
            else: invalid.append(False)
        gate('unknown_automation_input_refused', lambda s: all(s), invalid, [bool(phase1.get('error'))])
        measured = phase2
        # At 3 s, task_info must report an actual resident delta.
        gate('resident_3_seconds', lambda s: isinstance(s.get('residentDelta3Seconds'), int), phase1, intro)
        stats = measured['frameStats']; load = os.getloadavg()
        print('intro frames p50=%.3f p95=%.3f max=%.3f drops=%d count=%d load1=%.2f nominal=%.3f' %
              (stats['p50MS'], stats['p95MS'], stats['maxMS'], stats['drops'], stats['count'], load[0], stats['nominalMS']), flush=True)
        if 'Apple M5' in h.subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True) and load[0] <= 12 and stats['nominalMS'] <= 8.34:
            results['strict_120hz'] = dict(ok=stats['p95MS'] <= 1.5*stats['nominalMS'] and stats['drops'] <= max(1, stats['count']*.01), stats=stats, load=load)
        else:
            results['strict_120hz'] = dict(status='INFO', reason='requires M5 120 Hz and load1 <= 12', stats=stats, load=load)
        paused = elapsed(23.7)
        gate('idle_pauses', lambda s: s.get('ambientPaused') is True, paused, phase1)
        app.call('onboarding', action='get-started')
        until(lambda: app.call('first-run')['active'])
        until(lambda: app.call('first-run').get('probeReady', False))
        first_run = app.call('first-run')
        app.call('snapshot', path=str(evidence/'intro-handoff-first-run.png'))
        gate('get_started_handoff', lambda s: s.get('screen')=='name' and s['active'], state(), phase2)
        gate('handoff_import_fresh_choices', lambda s: s.get('active') and s.get('step')=='welcome' and s.get('probeReady'), first_run, phase2)
        app.call('first-run', action='fresh')
        until(lambda: not app.call('first-run')['active'])
        until(lambda: isinstance(state().get('residentDeltaAfterHandoff'), int))
        landed = dict(windows=app.call('windows'), snapshot=Path(app.user_data, 'State/browser.json').exists(), memory=state().get('residentDeltaAfterHandoff'))
        gate('start_fresh_browser', lambda s: s.get('snapshot') and any(w['class']=='BrowserWindow' for w in s.get('windows', [])), landed, phase2)
        # Natural returning launch: a real saved browser root, no skip switch.
        launch(fresh=False)
        returning = state()
        gate('intro_browser_shortcuts_guarded', lambda s: s.get('intro', {}).get('active') and not s.get('browsers'), guarded, dict(intro=returning, browsers=app.call('shell-windows')))
        gate('first_launch_shows_intro', lambda s: s.get('active') and s.get('screen')=='intro' and s.get('moduleActive'), intro, returning)
        inactive = lambda s: not s.get('active') and not s.get('moduleActive') and s.get('phase')=='inactive'
        gate('returning_inactive', inactive, returning, intro)
        dim_pred = lambda s: s.get('dim', {}).get('exists') and abs(s['dim']['alpha']-.85)<.001 and s['dim']['ignoresMouseEvents'] and s['dim']['child']
        gate('dim_overlay', dim_pred, dim, returning)
        launch('--skip-first-run')
        skipped_launch = state()
        gate('skip_first_run_inactive', inactive, skipped_launch, intro)
        launch()
        unmeasured = elapsed(.3)
        gate('frame_stats_recorded', frame_pred, measured, unmeasured)
        app.call('key', key='escape')
        escaped = state()
        final = lambda s: s.get('phase')=='sellCompleted' and s.get('ready') and s.get('buttonEnabled') and s.get('skipped') and abs(s.get('doorStrokeEnd', 0)-.88)<.001
        gate('escape_skips_to_final', final, escaped, unmeasured)
        gate('silent_playback_sync', played_pred, played, skipped_launch)
        # Native default button hands off through the real key/menu responder path.
        app.call('key', key='return')
        until(lambda: app.call('first-run')['active'])
        gate('native_return_handoff', lambda s: s.get('active') and s.get('step')=='welcome', app.call('first-run'), escaped)
        music_after_continue = state()
        gate('music_continues_after_continue', lambda s: s.get('sound', {}).get('playerCreated') and s['sound']['decision']=='played' and s.get('screen')=='name', music_after_continue, skipped_launch)
        app.call('first-run', action='fresh')
        until(lambda: state().get('sound', {}).get('playerCreated') is False)
        gate('finish_releases_player', lambda s: not s.get('sound', {}).get('playerCreated') and s.get('sound', {}).get('decision')=='played', state(), music_after_continue)
        launch()
        elapsed(.3)
        app.call('onboarding', action='skip-intro'); app.call('onboarding', action='get-started')
        until(lambda: app.call('first-run')['active'])
        before_close = state()
        app.call('key', key='w', modifiers=['command'])
        closed_pred = lambda s: not s.get('sound', {}).get('playerCreated') and not s.get('dim', {}).get('exists')
        until(lambda: closed_pred(state()))
        gate('closing_setup_releases_music_and_dim', closed_pred, state(), before_close)
        launch('--reduce-motion')
        reduced_initial = state()
        reduced = elapsed(1.2)
        reduce_pred = lambda s: s.get('reduceMotion') and s.get('phase')=='sellCompleted' and s['buttonEnabled'] and all('crossfade' in key for key in s.get('animations', []))
        gate('reduce_motion_crossfade_only', reduce_pred, reduced, phase2)
        app.call('snapshot', path=str(evidence/'intro-native-reduce-motion.png'))
        launch('--intro-sound=off')
        off = elapsed(.3)
        muted = lambda s: s.get('sound', {}).get('decision')=='muted' and not s['sound']['playerCreated'] and not s['sound']['playerWasCreated']
        gate('sound_off_mutes_without_player', muted, off, played)
        app.call('mouse', action='click', window=off['window'], x=100, y=200)
        until(lambda: final(state()))
        gate('scene_click_skips', final, state(), off)
        app.call('defaults', key=keys[0], value=False)
        launch()
        setting = elapsed(.3)
        gate('setting_mutes_without_player', lambda s: muted(s) and s['sound']['reason']=='setting', setting, played)
        app.call('defaults', key=keys[0], value=None)
        launch('--intro-sound=fail-device')
        failed = elapsed(.3)
        app.call('key', key='escape')
        failed_final = state()
        fail_pred = lambda s: s.get('sound', {}).get('decision')=='failed' and s['sound']['reason']=='no-output-device' and not s['sound']['playerCreated'] and not s['sound']['playerWasCreated'] and s['phase']=='sellCompleted'
        gate('device_failure_completes', fail_pred, failed_final, escaped)
        # Restore/replay touches no persistent snapshot. Close/quit during an
        # active animation also proves cleanup closes the dim child window.
        launch('--skip-first-run')
        app.call('save')
        snapshot = Path(app.user_data)/'State/browser.json'
        prior = snapshot.read_bytes()
        app.call('onboarding', action='replay-intro')
        replay = state()
        gate('replay_over_browser', lambda s: s.get('active') and s.get('replay'), replay, returning)
        app.call('onboarding', action='skip-intro'); app.call('onboarding', action='get-started')
        for _ in range(7):
            screen = state()['screen']
            if screen == 'ready': break
            app.call('onboarding', action='skip' if screen in ('name','import','favorites','theme','blocker') else 'next')
        app.call('onboarding', action='get-started')
        until(lambda: not state()['active'])
        unchanged = dict(same=snapshot.read_bytes()==prior, firstRun=app.call('first-run')['active'])
        app.call('open', url='about:blank'); app.call('save')
        changed = dict(same=snapshot.read_bytes()==prior, firstRun=app.call('first-run')['active'])
        gate('replay_does_not_write', lambda s: s['same'] and not s['firstRun'], unchanged, changed)
        # A denied replay exits before root preparation. It opens no window,
        # writes no default-root snapshot and reports a concrete refusal.
        denied = h.subprocess.run([app.executable, '--replay-onboarding', '--intro-sound=off'], capture_output=True, text=True, timeout=15)
        denied_state = dict(exit=denied.returncode, refused='requires --user-data-dir' in denied.stderr)
        app.call('onboarding', action='replay-intro')
        interrupted_intro = state()
        gate('quit_during_animation_fixture', lambda s: s.get('active') and s.get('dim', {}).get('exists'), interrupted_intro, returning)
        before_quit = app.call('windows')
        app.quit()
        gate('owned_window_cleanup', lambda s: s.get('ok') and s.get('windows_after_quit', {}).get('count')==0, app.quit_report, dict(windows=before_quit))
        with tempfile.TemporaryDirectory(prefix='open-intro-replay-', dir='/tmp') as root:
            Path(root, 'State').mkdir()
            Path(root, 'State/browser.json').write_bytes(prior)
            app = h.Open('Debug', 'chrome', root, ['--use-mock-keychain', '--intro-sound=silent',
                '--replay-onboarding', '--arc-dir='+str(source)], str(evidence/'replay-temp.log'), urls=(), first_run=True)
            app.focus_tracker = h._ACTIVE_FOCUS_TRACKER
            h._ACTIVE_FOCUS_TRACKER.apps.append(app)
            replay_launch = state()
            gate('replay_temp_root_allowed', lambda s: s.get('active') and s.get('screen')=='intro', replay_launch, returning)
            gate('replay_default_root_refused', lambda s: s.get('exit')==64 and s.get('refused'), denied_state, replay_launch)
            app.quit()
    finally:
        if app and not app.closed: app.quit()
        h._restore_defaults(None, saved)
        (evidence/'negative-proofs.json').write_text(json.dumps(negatives, indent=2))
    runpy.run_path(str(Path(h.ROOT)/'tools/e2e/onboarding_steps.py'))['run'](factory, results, tmp, h)
