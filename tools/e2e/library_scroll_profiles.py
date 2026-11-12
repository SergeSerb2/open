#!/usr/bin/env python3
"""LEAD 11:20: real Library wheel, scroller-drag and no-scroll control.

Release qualification requires the M1 heavy slots and on-screen lock. Input
goes through the App socket into the owning window; nothing posts desktop events.
The five-pair interaction/idle receipt is retained when rendering is unchanged.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time

from engine_e2e import Open, wait_until
from library_frame_probe import Frames, TICK_MS
from library_performance import seed, scroll_fixture, quiet, other_processes


PERIOD = 1000 / 120
LIMITS = {
    'wheel': {'p95Milliseconds': 4, 'maximumMilliseconds': 8.3,
              'created': 0, 'libraryAttributedMissedIntervals': 1},
    'scroller': {'maximumMilliseconds': 8.3, 'created': 0,
                 'p95AndMisses': 'INFO: replaces the viewport each callback'},
}


def classify_gaps(native, gaps):
    """LEAD 12:25: retain raw capture gaps; attribute only App clock evidence.

    startTicks and capture ticks share mach_absolute_time. Heartbeat launch
    ages use the per-callback launch anchor. The old receipt records a positive
    layout/display/flush duration after every wheel submitNativeFrame call;
    these are durations, not monotonically increasing commit counters.
    """
    rows = native['frames']
    classified = []
    all_rows = rows+native.get('settlingFrames', [])
    for gap in gaps:
        left, right = gap['startTicks'], gap['endTicks']
        busy, late, missing_commit, ticks = [], [], [], []
        for i, row in enumerate(rows):
            heartbeat = row['heartbeat']
            anchor = row['startTicks']-row['launchMilliseconds']/TICK_MS
            if heartbeat['maxBusyAgeMilliseconds'] >= 8:
                begin = anchor+heartbeat['busyStartLaunchMilliseconds']/TICK_MS
                end = anchor+heartbeat['busyEndLaunchMilliseconds']/TICK_MS
                if begin < right and end > left: busy.append(i+1)
            if i and row['intervalMilliseconds'] > 12.5:
                if rows[i-1]['startTicks'] < right and row['startTicks'] > left: late.append(i+1)
            if left <= row['startTicks'] <= right:
                ticks.append(i+1)
                changed = i and row['input'].get('offsetBefore') != rows[i-1]['input'].get('offsetBefore')
                committed = any(row['counters'].get('last.'+phase, 0)>0 for phase in ['layout','display','flush'])
                if changed and not committed: missing_commit.append(i+1)
        attributed = bool(busy or late or missing_commit)
        # Attribute to Library only when its non-nested phases account for
        # >=4ms of a busy interval that actually overlaps this capture gap.
        # Callback wall time includes its own layout/display/flush; clip and
        # reconcile counters are nested, as are reconcile and idle slices.
        busy_windows = []
        for number in busy:
            row = rows[number-1]; h = row['heartbeat']
            anchor = row['startTicks']-row['launchMilliseconds']/TICK_MS
            busy_windows.append((anchor+h['busyStartLaunchMilliseconds']/TICK_MS,
                                 anchor+h['busyEndLaunchMilliseconds']/TICK_MS))
        library_ms = 0
        for i, row in enumerate(all_rows):
            def overlaps(begin, end):
                return any(begin < high and end > low for low, high in busy_windows)
            if overlaps(row['startTicks'], row['endTicks']): library_ms += row['milliseconds']
            if i and overlaps(all_rows[i-1]['endTicks'],row['startTicks']):
                delta = row['betweenCallbackDelta']
                library_ms += max(delta.get('scroll.clipBounds',0),delta.get('scroll.reconcile',0))
        # Idle slices include reconcile work, so retain the larger accounting.
        for low, high in busy_windows:
            anchor = rows[0]['startTicks']-rows[0]['launchMilliseconds']/TICK_MS
            idle_ms = sum(slice['milliseconds'] for slice in native.get('idleWorkIntervals', [])
                          if anchor+slice['startLaunchMilliseconds']/TICK_MS < high
                          and anchor+slice['endLaunchMilliseconds']/TICK_MS > low)
            library_ms = max(library_ms,idle_ms)
        classified.append(dict(gap, callbacks=ticks, busyCallbacks=busy,
            lateDisplayLinkCallbacks=late, changedOffsetWithoutCommitCallbacks=missing_commit,
            appAttributed=attributed, libraryPhaseMilliseconds=library_ms,
            libraryAttributed=attributed and library_ms>=4, classification='App-attributed' if attributed else
            'outside the App (compositor or capture cadence)'))
    count = sum(gap['missedIntervals'] for gap in classified if gap['appAttributed'])
    return {'rule':'LEAD 12:50 (11 Nov)', 'rawMissedIntervals':sum(g['missedIntervals'] for g in gaps),
            'appAttributedMissedIntervals':count,
            'libraryAttributedMissedIntervals':sum(g['missedIntervals'] for g in classified if g['libraryAttributed']),
            'outsideAppIntervals':sum(g['missedIntervals'] for g in classified if not g['appAttributed']),
            'gaps':classified}


def idle_work(native):
    slices = native.get('idleWorkIntervals', [])
    frames = native['frames']+native.get('settlingFrames', [])
    attributed = []
    for i, row in enumerate(frames):
        h = row['heartbeat']
        low, high = h['busyStartLaunchMilliseconds'], h['busyEndLaunchMilliseconds']
        matching = [s for s in slices if s['startLaunchMilliseconds'] < high and s['endLaunchMilliseconds'] > low]
        if matching:
            attributed.append({'callback':i+1,'settling':i>=len(native['frames']),
                'milliseconds':h['maxBusyAgeMilliseconds'],'startLaunchMilliseconds':low,
                'endLaunchMilliseconds':high,'slices':matching})
    maximum = max((r['milliseconds'] for r in attributed), default=0)
    unit_max = max((s['milliseconds'] for s in slices), default=0)
    return {'slices':slices,'libraryBusyIntervals':attributed,
            'largestLibraryBusyMilliseconds':maximum,'maximumSliceMilliseconds':unit_max,
            'ok':maximum<=8.3 and unit_max<=8}


def analyze(native, physical):
    rows = native['frames']
    all_rows = rows+native.get('settlingFrames', [])
    dispatch_costs = sorted(row['milliseconds'] for row in rows)
    # Precise NSScrollView events can apply their clip changes after dispatch.
    # For wheel qualification include all run-loop busy wall time in each
    # display interval, including that deferred work; never qualify only the
    # cheap event-enqueue call. Keep direct callback costs separately.
    costs = sorted(max(row['milliseconds'], row['heartbeat']['mainBusyIntervalMilliseconds'])
                   if native['profile'] == 'wheel' else row['milliseconds'] for row in rows)
    moving = [i for i in range(1, len(rows)) if native['profile'] == 'wheel'
              and rows[i]['input']['offsetBefore'] != rows[i-1]['input']['offsetBefore']]
    moving_costs = sorted(max(rows[i]['milliseconds'], rows[i]['heartbeat']['mainBusyIntervalMilliseconds']) for i in moving)
    p95 = costs[min(len(costs)-1, int(len(costs)*.95))]
    moving_p95 = moving_costs[min(len(moving_costs)-1, int(len(moving_costs)*.95))] if moving_costs else None
    if moving_p95 is not None: p95 = max(p95, moving_p95)
    first, last = rows[0]['startTicks'], rows[-1]['endTicks']
    changes = physical['changes']
    # Keep the full capture, including scrollbar fade, in physical. Budget
    # only complete observed intervals during the active callback sequence.
    active = [tick for tick in changes if first <= tick <= last]
    gaps = []
    for left, right in zip(active, active[1:]):
        ms = (right-left)*TICK_MS
        missed = max(0, round(ms/PERIOD)-1)
        if missed:
            gaps.append({'startTicks': left, 'endTicks': right,
                         'milliseconds': ms, 'missedIntervals': missed})
    busy = [dict(callback=i+1, launchMilliseconds=row['launchMilliseconds'],
                 intervalMilliseconds=row['intervalMilliseconds'],
                 callbackMilliseconds=row['milliseconds'],
                 heartbeat=row['heartbeat'], betweenCallbackDelta=row['betweenCallbackDelta'])
            for i, row in enumerate(rows)
            if row['heartbeat']['maxBusyAgeMilliseconds'] >= 8]
    phases = {key: max(row['counters'].get('last.'+key, 0) for row in rows)
              for key in ['layout', 'display', 'flush']}
    phases.update({key: max(row['counterDelta'].get(key, 0) for row in rows)
                   for key in rows[-1]['counterDelta']
                   if key.startswith('scroll.') or key in ['formatting', 'listLayout', 'wake.trackingMilliseconds']})
    deferred_phases = {key: max(row['betweenCallbackDelta'].get(key, 0) for row in rows)
                       for key in rows[-1]['counterDelta']
                       if key.startswith('scroll.') or key in ['formatting', 'listLayout', 'wake.trackingMilliseconds']}
    raw = sum(gap['missedIntervals'] for gap in gaps)
    classification = classify_gaps(native, gaps)
    return {'callbacks': len(rows), 'p95Milliseconds': dispatch_costs[min(len(dispatch_costs)-1, int(len(dispatch_costs)*.95))],
            'mainBusyP95Milliseconds': p95,
            'maximumMilliseconds': max(dispatch_costs),
            'mainBusyMaximumMilliseconds': max(costs),
            'movingCallbacks': len(moving), 'movingP95Milliseconds': moving_p95,
            'allCallbacksP95Milliseconds': costs[min(len(costs)-1, int(len(costs)*.95))],
            'directCallbackP95Milliseconds': dispatch_costs[min(len(costs)-1, int(len(costs)*.95))],
            'directCallbackMaximumMilliseconds': max(dispatch_costs),
            'workClock': 'native callback through explicit App commit; full main-busy intervals retained separately',
            'created': all_rows[-1]['counters']['created']-rows[0]['counters']['created']+rows[0]['counterDelta'].get('created', 0),
            'configured': all_rows[-1]['counters']['configured']-rows[0]['counters']['configured']+rows[0]['counterDelta'].get('configured', 0),
            'configuredDuringCallbacks': sum(row['counterDelta'].get('configured', 0) for row in rows),
            'configuredBetweenCallbacks': sum(row['betweenCallbackDelta'].get('configured', 0) for row in rows),
            'startLaunchMilliseconds': rows[0]['launchMilliseconds'],
            'endLaunchMilliseconds': rows[-1]['launchMilliseconds'],
            'activePhysicalChanges': len(active), 'activePhysicalMissedIntervals': raw,
            'fullCaptureMissedIntervals': physical['missed120HzIntervals'],
            'excludedIntervals': raw-classification['appAttributedMissedIntervals'],
            'appAttributedMissedIntervals': classification['appAttributedMissedIntervals'],
            'libraryAttributedMissedIntervals':classification['libraryAttributedMissedIntervals'],
            'physicalGapClassification': classification,
            'physicalGaps': gaps, 'busyGapsAtLeast8ms': busy,
            'phaseMaximumMilliseconds': phases,
            'deferredPhaseMaximumMilliseconds': deferred_phases,
            'physicalWindow': {'startTicks': first, 'endTicks': last,
                               'firstChangeTicks': active[0] if active else None,
                               'lastChangeTicks': active[-1] if active else None},
            'heartbeatContexts': native['heartbeatContexts'], 'idlePreparation':idle_work(native)}


def main(args):
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    bundle = args.bundle.resolve()
    result = {'configuration': 'Release', 'rule': 'LEAD 12:50 (11 Nov)',
              'limits': LIMITS, 'complete': False, 'productRenderingChanged': True,
              'executableSHA256': hashlib.sha256((bundle/'Contents/MacOS/Open').read_bytes()).hexdigest(),
              'oldGapLaunchOffsetEstimateMilliseconds': [[2940, 3170], [3160, 3390]],
              'oldOffsetCaveat': 'Reconstructed from external file/tick anchors; not exact process-start timestamps.'}
    app = frames = None
    temporary = tempfile.TemporaryDirectory(prefix='olsp-', dir='/tmp')
    def save(): (out/'result.json').write_text(json.dumps(result, indent=2))
    save()
    try:
        root = Path(temporary.name)
        model = seed(root, bundle, out); root = scroll_fixture(root, model)
        result['prelaunchQuiet'] = quiet()
        app = Open('Release', 'chrome', str(root), [], str(out/'app.log'),
                   urls=('about:blank',), extra_env={'OPEN_E2E_APP_BUNDLE': str(bundle),
                                                     # Record-only split of long run-loop turns (H2 follow-up row 1).
                                                     'OPEN_AUTOMATION_RUNLOOP_TURNS': '1'})
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        result['open'] = app.call('library-performance', operation='open', section='downloads')
        assert result['open']['providerRows'] == 10000
        control = app.call('library-performance', operation='scroll-series', profile='control',
                           beginAtLaunchMilliseconds=2000)
        result['control'] = control
        result['controlIdlePreparation'] = idle_work(control)
        assert not control['inputError'] and len(control['frames']) == 216
        coverage = [control['frames'][0]['launchMilliseconds'], control['frames'][-1]['launchMilliseconds']]
        result['controlCoverageMilliseconds'] = coverage
        result['controlCoversOldGapEstimates'] = coverage[0] <= 2940 and coverage[1] >= 3390
        assert result['controlCoversOldGapEstimates'], coverage
        result['controlBusyGapsAtLeast8ms'] = [dict(callback=i+1, **row['heartbeat'])
            for i, row in enumerate(control['frames']) if row['heartbeat']['maxBusyAgeMilliseconds'] >= 8]
        assert all(row['counterDelta'].get('created', 0) == 0 for row in control['frames'])
        save()
        age = app.call('library-performance', operation='cpu')['launchElapsedMilliseconds']
        print('WAIT launch age '+json.dumps({'currentMilliseconds': age, 'minimumMilliseconds': 150000}), flush=True)
        # No socket polling during the control or launch-age wait.
        while age < 150000:
            seconds = min(30, (150000-age)/1000)
            time.sleep(seconds); age += seconds*1000
        for profile, duration in [('wheel', 8500), ('scroller', 4000)]:
            app.call('library-performance', operation='scroll', row=0)
            time.sleep(.5)
            assert wait_until(lambda: app.call('library-performance', operation='cpu')['counters'].get('tasks', 0) == 0, timeout=15)
            quiet_before = quiet()
            frames = Frames(app, args.frame_helper, out/('physical-'+profile))
            native, physical = frames.measure(profile, lambda: app.call('library-performance',
                operation='scroll-series', profile=profile, beginAtLaunchMilliseconds=150000), duration=duration)
            frames.close(); frames = None
            row = analyze(native, physical)
            # INFO only: every main run-loop turn >= 8 ms from this profile's start, split into
            # wake/timers/sources/CA commit. It classifies busy time that phase marks do not cover.
            row['runloopTurns'] = app.call('runloop-turns', minimumMs=8, fromLaunchMs=row['startLaunchMilliseconds'])
            row.update(native=native, physical=physical, quietBefore=quiet_before,
                       loadAfter=os.getloadavg()[0], otherProcessesAfter=other_processes(app.bundle))
            result[profile] = row; save()
            assert not native['inputError'] and len(native['frames']) == (600 if profile == 'wheel' else 120)
            assert row['startLaunchMilliseconds'] >= 150000
            row['valid'] = max(quiet_before[0]) <= 3.5
            assert row['activePhysicalChanges'] >= (400 if profile == 'wheel' else 100), row['activePhysicalChanges']
            if profile == 'wheel':
                inputs = [f['input'] for f in native['frames']]
                assert all(i['precise'] == 1 and 0 <= i['requestedPoints'] <= 168 for i in inputs)
                assert [inputs[i]['phase'] for i in [0, 1, 539]] == [1, 4, 8]
                assert [inputs[i]['momentumPhase'] for i in [540, 541, 599]] == [1, 4, 8]
                assert inputs[-1]['offsetAfter'] > inputs[539]['offsetAfter'], 'momentum did not move the list'
                assert len({i['offsetBefore'] for i in inputs}) > 500, 'wheel velocity curve did not move the list'
                assert all(i['timestamp'] > 0 for i in inputs)
            row['ok'] = row['valid'] and row['maximumMilliseconds'] <= 8.3 and row['created'] == 0 and row['idlePreparation']['ok']
            if profile == 'wheel':
                row['ok'] = row['ok'] and row['p95Milliseconds'] <= 4 and row['libraryAttributedMissedIntervals'] <= 1
            print(json.dumps({key: value for key, value in row.items() if key in [
                'callbacks', 'p95Milliseconds', 'maximumMilliseconds', 'created', 'activePhysicalMissedIntervals',
                'appAttributedMissedIntervals', 'startLaunchMilliseconds', 'valid', 'ok']}, sort_keys=True), flush=True)
            save()
        result['settled'] = app.call('library-performance', operation='cpu')
        result['complete'] = True
        result['ok'] = result['wheel']['ok'] and result['scroller']['ok'] and result['controlIdlePreparation']['ok']
    except Exception as error:
        result['error'] = repr(error)
        raise
    finally:
        if frames: frames.close()
        if app:
            app.quit(); result['cleanup'] = app.quit_report
            result['ok'] = result.get('ok', False) and app.quit_report['ok']
        temporary.cleanup(); save()
    print(json.dumps({'complete': result['complete'], 'ok': result['ok'], 'cleanup': result['cleanup']}), flush=True)
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--frame-helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    raise SystemExit(main(parser.parse_args()))
