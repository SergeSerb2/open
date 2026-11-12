#!/usr/bin/env python3
"""LEAD 13:50: one bounded ticket, three real Release ready-open pairs.

Warm/search carry from the accepted receipts only when OpenLibrary matches
55b507c3. Capture every preparation slice and its full main-loop interval.
"""
import argparse
import hashlib
import json
from pathlib import Path
import signal
import statistics
import tempfile
import time

from library_performance import seed, launch, quiet, other_processes


def preparation_intervals(trace, opened):
    cutoff = opened['preparationBefore']['launchMilliseconds']
    slices = [s for s in trace['idleWorkIntervals'] if s['endLaunchMilliseconds'] <= cutoff]
    intervals = trace['busyIntervals']
    rows = []
    for index, slice in enumerate(slices):
        low, high = slice['startLaunchMilliseconds'], slice['endLaunchMilliseconds']
        matching = [b for b in intervals if b['startLaunchMilliseconds'] < high
                    and b['endLaunchMilliseconds'] > low]
        covered = sum(max(0, min(high, b['endLaunchMilliseconds'])-
                          max(low, b['startLaunchMilliseconds'])) for b in matching)
        rows.append(dict(index=index+1, **slice, busyIntervals=matching,
                         coveredMilliseconds=covered,
                         coverageOK=covered >= high-low-.001))
    busy = [b for b in intervals if any(b['startLaunchMilliseconds'] < s['endLaunchMilliseconds']
                                      and b['endLaunchMilliseconds'] > s['startLaunchMilliseconds']
                                      for s in slices)]
    attributed = []
    for b in busy:
        own = sum(max(0, min(b['endLaunchMilliseconds'], s['endLaunchMilliseconds'])-
                         max(b['startLaunchMilliseconds'], s['startLaunchMilliseconds'])) for s in slices)
        attributed.append(dict(**b, librarySliceMilliseconds=own,
                               otherMainThreadMilliseconds=max(0, b['milliseconds']-own)))
    maximum = max((s['milliseconds'] for s in slices), default=0)
    busy_maximum = max((b['milliseconds'] for b in busy), default=0)
    return {'slices':rows, 'overlappingBusyIntervals':attributed,
            'maximumSliceMilliseconds':maximum,
            'maximumOverlappingBusyMilliseconds':busy_maximum,
            'coverageOK':bool(slices) and not trace['overflow'] and all(s['coverageOK'] for s in rows)
                         and trace['startedLaunchMilliseconds'] <= slices[0]['startLaunchMilliseconds'],
            'sliceLimitOK':maximum <= 8,
            # Keep all mixed intervals. Do not invent an exclusion for a new
            # long interval; its Library/other work split goes to the lead.
            'allOverlappingBusyWithinLimit':busy_maximum <= 8.3}


def run(args):
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    digest = hashlib.sha256()
    module = Path('Packages/OpenKit/Sources/OpenLibrary')
    for path in sorted(module.rglob('*.swift')):
        digest.update(str(path.relative_to(module)).encode()+b'\0'+path.read_bytes())
    result = {'rule':'LEAD 13:50 (11 Nov)', 'configuration':'Release', 'samples':[],
              'complete':False, 'warmSearchRepeated':False, 'libraryModuleSHA256':digest.hexdigest(),
              'executableSHA256':hashlib.sha256((args.bundle/'Contents/MacOS/Open').read_bytes()).hexdigest()}
    temporary = tempfile.TemporaryDirectory(prefix='olro-', dir='/tmp')
    root = Path(temporary.name); app = None
    deadline = time.monotonic()+13*60
    def expire(signum, frame): raise TimeoutError('13-minute ticket deadline; preserve completed pairs')
    old_handler = signal.signal(signal.SIGALRM, expire)
    signal.setitimer(signal.ITIMER_REAL, 13*60)
    def save(): (out/'result.json').write_text(json.dumps(result, indent=2))
    save()
    try:
        seed(root, args.bundle, out)
        for index in range(3):
            baseline_quiet = quiet(deadline=min(deadline, time.monotonic()+360))
            app = launch(root, args.baseline_bundle, out, 'baseline-'+str(index))
            baseline = {'quiet':baseline_quiet, 'timing':app.call('timing')}
            app.quit(); baseline['cleanup'] = app.quit_report
            assert app.quit_report['ok'] and not app.quit_report['forced']; app = None
            candidate_quiet = quiet(deadline=min(deadline, time.monotonic()+360))
            app = launch(root, args.bundle, out, str(index),
                         {'OPEN_AUTOMATION_LIBRARY_PREPARATION_TRACE':'1'})
            states = []; until = time.monotonic()+35
            while time.monotonic() < until:
                state = app.call('library-performance', operation='preparation-state')
                states.append(state)
                if state['completed']: break
                time.sleep(.05)
            assert states[-1]['completed'], states[-1]
            opened = app.call('library-performance', operation='open', section='downloads')
            assert opened['providerRows'] == 1000, opened
            trace = app.call('library-performance', operation='preparation-trace', stop=True)
            idle = preparation_intervals(trace, opened)
            row = {'index':index, 'baseline':baseline, 'quiet':candidate_quiet,
                   'preparationStates':states, 'open':opened, 'trace':trace, 'idle':idle,
                   'otherProcessesAfter':other_processes(app.bundle)}
            app.quit(); row['cleanup'] = app.quit_report
            assert app.quit_report['ok'] and not app.quit_report['forced']; app = None
            row['valid'] = max(baseline_quiet[0]+candidate_quiet[0]) <= 3.5
            row['classification'] = 'required after preparation' if opened['preparationBefore']['completed'] else 'INFO open during preparation'
            result['samples'].append(row); save()
            print(json.dumps({'pair':index+1, 'valid':row['valid'],
                  'readyOpen':opened['firstSubmittedMilliseconds'],
                  'preparation':opened['preparationBefore'],
                  'maximumSlice':idle['maximumSliceMilliseconds'],
                  'maximumOverlappingBusy':idle['maximumOverlappingBusyMilliseconds'],
                  'coverageOK':idle['coverageOK']}), flush=True)
        required = [s for s in result['samples'] if s['open']['preparationBefore']['completed']]
        values = [s['open']['firstSubmittedMilliseconds'] for s in required]
        result['summary'] = {'requiredPairs':len(required), 'values':values,
                             'median':statistics.median(values) if values else None,
                             'maximum':max(values) if values else None,
                             'medianLimit':8, 'sampleLimit':12}
        result['complete'] = True
        result['ok'] = len(required) >= 3 and statistics.median(values) <= 8 and max(values) <= 12 and all(
            s['valid'] and s['idle']['coverageOK'] and s['idle']['sliceLimitOK']
            and s['idle']['allOverlappingBusyWithinLimit'] for s in result['samples'])
    except BaseException as error:
        result['error'] = repr(error); raise
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        if app:
            app.quit(); result['errorCleanup'] = app.quit_report
        temporary.cleanup()
        signal.signal(signal.SIGALRM, old_handler)
        save()
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--baseline-bundle', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    raise SystemExit(run(p.parse_args()))
