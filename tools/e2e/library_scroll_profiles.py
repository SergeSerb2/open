#!/usr/bin/env python3
"""LEAD 11:20: real Library wheel, scroller-drag and no-scroll control.

Release qualification requires the M1 heavy slots and on-screen lock. Input
goes through the App socket into NSScrollView; nothing posts desktop events.
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
              'created': 0, 'appAttributedMissedIntervals': 1},
    'scroller': {'maximumMilliseconds': 8.3, 'created': 0,
                 'p95AndMisses': 'INFO: replaces the viewport each callback'},
}


def analyze(native, physical):
    rows = native['frames']
    costs = sorted(row['milliseconds'] for row in rows)
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
    raw = sum(gap['missedIntervals'] for gap in gaps)
    # No exclusion by assumption. Only a control reproduced at the same launch
    # offset could justify one. The early control cannot explain a >=150s gap.
    return {'callbacks': len(rows), 'p95Milliseconds': costs[min(len(costs)-1, int(len(costs)*.95))],
            'maximumMilliseconds': max(costs),
            'created': sum(row['counterDelta'].get('created', 0) for row in rows),
            'configured': sum(row['counterDelta'].get('configured', 0) for row in rows),
            'startLaunchMilliseconds': rows[0]['launchMilliseconds'],
            'endLaunchMilliseconds': rows[-1]['launchMilliseconds'],
            'activePhysicalChanges': len(active), 'activePhysicalMissedIntervals': raw,
            'fullCaptureMissedIntervals': physical['missed120HzIntervals'],
            'excludedIntervals': 0, 'appAttributedMissedIntervals': raw,
            'physicalGaps': gaps, 'busyGapsAtLeast8ms': busy,
            'phaseMaximumMilliseconds': phases,
            'physicalWindow': {'startTicks': first, 'endTicks': last,
                               'firstChangeTicks': active[0] if active else None,
                               'lastChangeTicks': active[-1] if active else None},
            'heartbeatContexts': native['heartbeatContexts']}


def main(args):
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    bundle = args.bundle.resolve()
    result = {'configuration': 'Release', 'rule': 'LEAD 11:20 (11 Nov)',
              'limits': LIMITS, 'complete': False, 'productRenderingChanged': False,
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
                   urls=('about:blank',), extra_env={'OPEN_E2E_APP_BUNDLE': str(bundle)})
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        result['open'] = app.call('library-performance', operation='open', section='downloads')
        assert result['open']['providerRows'] == 10000
        control = app.call('library-performance', operation='scroll-series', profile='control',
                           beginAtLaunchMilliseconds=2000)
        result['control'] = control
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
        for profile, duration in [('wheel', 6500), ('scroller', 1800)]:
            app.call('library-performance', operation='scroll', row=0)
            time.sleep(.5)
            assert wait_until(lambda: app.call('library-performance', operation='cpu')['counters'].get('tasks', 0) == 0, timeout=15)
            quiet_before = quiet()
            frames = Frames(app, args.frame_helper, out/('physical-'+profile))
            native, physical = frames.measure(profile, lambda: app.call('library-performance',
                operation='scroll-series', profile=profile, beginAtLaunchMilliseconds=150000), duration=duration)
            frames.close(); frames = None
            row = analyze(native, physical)
            row.update(native=native, physical=physical, quietBefore=quiet_before,
                       loadAfter=os.getloadavg()[0], otherProcessesAfter=other_processes(app.bundle))
            result[profile] = row; save()
            assert not native['inputError'] and len(native['frames']) == (600 if profile == 'wheel' else 120)
            assert row['startLaunchMilliseconds'] >= 150000
            row['valid'] = max(quiet_before[0]) <= 3.5
            assert row['activePhysicalChanges'] >= (400 if profile == 'wheel' else 100), row['activePhysicalChanges']
            if profile == 'wheel':
                inputs = [f['input'] for f in native['frames']]
                assert all(i['precise'] == 1 and 0 < i['requestedPoints'] <= 168 for i in inputs)
                assert [inputs[i]['phase'] for i in [0, 1, 179]] == [1, 4, 8]
                assert [inputs[i]['momentumPhase'] for i in [180, 181, 599]] == [1, 4, 8]
                assert max(i['offsetAfter'] for i in inputs) > inputs[0]['offsetBefore']+56
            row['ok'] = row['valid'] and row['maximumMilliseconds'] <= 8.3 and row['created'] == 0
            if profile == 'wheel':
                row['ok'] = row['ok'] and row['p95Milliseconds'] <= 4 and row['appAttributedMissedIntervals'] <= 1
            print(json.dumps({key: value for key, value in row.items() if key in [
                'callbacks', 'p95Milliseconds', 'maximumMilliseconds', 'created', 'activePhysicalMissedIntervals',
                'appAttributedMissedIntervals', 'startLaunchMilliseconds', 'valid', 'ok']}, sort_keys=True), flush=True)
            save()
        result['settled'] = app.call('library-performance', operation='cpu')
        result['complete'] = True
        result['ok'] = result['wheel']['ok'] and result['scroller']['ok']
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
