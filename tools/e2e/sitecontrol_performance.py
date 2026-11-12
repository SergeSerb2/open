"""SCC first-draw and native idle observation in separate real App runs."""
from pathlib import Path
import os
import statistics
import subprocess
import time


def run(factory, results, origin, tmp, env):
    lane = env.get("E2E_LANE", "all")
    if lane != "observers":
        app = factory(urls=(origin + '/ads.html',))
        saved = {}
        try:
            key = 'open.advanced.playSoundEffects'
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=False)
            tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab)
            app.call('window-focus', id=app.call('window-state')['id'], activate=True)
            for _ in range(35):
                app.call('site-controls', action='open')
                time.sleep(.3)
                app.call('site-controls', action='close')
            state = app.call('site-controls', action='state')
            all_samples = state['firstDrawMilliseconds']
            # Per-sample phase split (ms from the request): snapshot, apply, layout, focusAndAnimation, subtreeLayout, display, flush.
            phases = state.get('firstDrawPhases', [])
            samples = all_samples[-30:]
            p95 = sorted(samples)[int(.95 * (len(samples) - 1))]
            p95_all = sorted(all_samples)[int(.95 * (len(all_samples) - 1))]
            data = dict(timing=True, functionalOK=len(all_samples) == 35 and len(samples) == 30, milliseconds=samples, allMilliseconds=all_samples,p95=p95,p95IncludingCold=p95_all,limit=8,warmups=5,coldMilliseconds=all_samples[0],
                        load=list(os.getloadavg()), phases=phases)
            if app.config == 'Release':
                data['ok'] = len(all_samples) == 35 and len(samples) == 30 and p95 < 8 and p95_all < 8
                # Exact text of the DEFERRED gate exception (LEAD 17:55, PR #324).
                if data['functionalOK'] and not data['ok']: data['reason'] = 'first-draw p95 must be below 8 ms (warm 30 and including cold)'
            else: data.update(status='BLOCKED', reason='Release required for first-draw budget')
            results['P1_first_draw'] = data
            # Review receipt through real page loads. State reads do not ask the
            # source for panel data, so these deltas isolate native refresh work.
            def reads(): return app.call('site-controls', action='state')['sourceReads']
            def delta(before, after): return {key: after[key] - before[key] for key in before}
            before = reads()
            app.call('navigate', tab=tab, url=origin + '/heavy.html'); app.call('wait', tab=tab)
            time.sleep(.2)
            closed = delta(before, reads())
            app.call('site-controls', action='open')
            before = reads()
            app.call('navigate', tab=tab, url=origin + '/heavy.html?panel=open'); app.call('wait', tab=tab)
            time.sleep(.2)
            opened = delta(before, reads())
            before = reads()
            app.eval(tab, "for(let i=0;i<250;i++)document.title='SCC title '+i;true")
            time.sleep(.2)
            titles = delta(before, reads())
            data['sourceRefresh'] = dict(fixture='heavy.html (2000 cards)', closedPageLoad=closed, openPageLoad=opened,
                titleChanges=titles, load=list(os.getloadavg()))
            app.call('site-controls', action='close')
        finally:
            env['_restore_defaults'](app, saved)
            app.quit()

    if lane == "merge":
        return

    # Delay each native phase in a separate real-App run. Counters sampled by
    # the receipt callback exclude any AppKit work that happens after timing.
    delay_source = Path(env['ROOT'], 'tools/e2e/sitecontrol_draw_probe.m')
    delay_probe = str(Path(tmp, 'sitecontrol-delay.dylib'))
    subprocess.run(['xcrun','clang','-dynamiclib','-fobjc-arc',str(delay_source),
                    '-framework','AppKit','-framework','QuartzCore','-o',delay_probe],check=True,timeout=30)
    phase_proofs = []
    for index, phase in enumerate(['layout', 'display', 'flush']):
        app = factory(urls=(origin + '/ads.html',), extra_env={
            'DYLD_INSERT_LIBRARIES': delay_probe, 'OPEN_SCC_DELAY_PHASE': phase})
        try:
            tab=app.call('tabs')[0]['id']; app.call('wait',tab=tab)
            app.call('window-focus', id=app.call('window-state')['id'], activate=True)
            app.begin_timing('SCC '+phase+' negative control')
            before=app.call('site-controls',action='state')['drawNativeProbe']
            app.call('site-controls',action='open')
            shown=app.call('site-controls',action='state')
            delayed=shown['firstDrawMilliseconds'][-1]
            measured=shown['firstDrawNativeProbe'][-1]
            delta=[a-b for a,b in zip(measured,before)]
            rejected=len(delta)==6 and all(n>0 for n in delta[:3]) and delta[index+3]>0 and delayed>=12
            interruptions=results.tracker.loss()
            if interruptions:
                raise env['FocusInterruption']('foreground lost during P1 '+phase+' negative control', interruptions)
            phase_proofs.append(dict(phase=phase, negativeRejected=rejected,
                milliseconds=delayed, nativeCalls=delta[:3], nativeDelays=delta[3:], load=list(os.getloadavg())))
        finally:
            app.quit()
    results['P1_native_phase_proofs'] = dict(ok=all(p['negativeRejected'] for p in phase_proofs),
        nativePhaseProofs=phase_proofs, negativeMilliseconds=max(p['milliseconds'] for p in phase_proofs))

    # Observe real view invalidation and native schedulers. The observer is
    # injected before SCC initialization; it never ships in the App.
    source = Path(env['ROOT'], 'tools/verification/feature-idle-probe.m').read_text()
    source = source.replace('if (!strstr(path, "/features-render")) return NO;',
                            'if (!strstr(path, "/Open.app/Contents/MacOS/Open")) return NO;')
    source = source.replace('return strstr(info.dli_sname, "OpenFeatures") || strstr(info.dli_sname, "observerProof");',
                            'return strstr(info.dli_sname, "OpenSiteControl") || strstr(info.dli_sname, "siteControlIdle");')
    file = Path(tmp, 'sitecontrol-idle.m'); file.write_text(source)
    probe = str(Path(tmp, 'idle-probe.dylib'))
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fblocks', '-fobjc-arc',
                    '-Wno-deprecated-declarations', str(file), '-framework', 'AppKit',
                    '-framework', 'QuartzCore', '-framework', 'CoreVideo', '-o', probe],
                   check=True, timeout=30)
    app = factory(urls=(origin + '/ads.html',), extra_env={'DYLD_INSERT_LIBRARIES': probe})
    try:
        tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab)
        app.call('site-controls-idle', action='begin')
        app.call('site-controls', action='open'); time.sleep(.5)
        app.call('site-controls-idle', action='watch')
        app.call('site-controls-idle', action='reset')
        before = app.call('site-controls-idle'); start = time.monotonic()
        time.sleep(2)
        after = app.call('site-controls-idle'); elapsed = time.monotonic() - start
        canary = app.call('site-controls-idle', action='canary')
        results['P2_idle'] = dict(ok=after['counts'] == [0] * 10 and canary['live'] > 0
            and canary['after'] == 0, observer=after['counts'], canary=canary,
            cpuPercent=100 * (after['cpuSeconds'] - before['cpuSeconds']) / elapsed,
            elapsed=elapsed, load=list(os.getloadavg()))
        app.call('site-controls-idle', action='end')
    finally:
        app.quit()
