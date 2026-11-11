#!/usr/bin/env python3
"""LEAD 14:20: three real Release launches, no scrolling or timed open.

Observe all idle preparation from launch through its completion. Only the
creation turn of each first row can use the stated first-use exception.
"""
import argparse
import hashlib
import json
from pathlib import Path
import signal
import tempfile
import time

from library_performance import seed, launch, quiet, other_processes
from library_ready_open import preparation_intervals


KINDS = {1: 'download', 2: 'archive', 3: 'history', 4: 'capture',
         5: 'boost', 6: 'boostGallery', 7: 'heading'}
PHASES = {0: 'later row', 1: 'creation', 2: 'configure + layout', 3: 'display + flush'}


def classify(trace, state):
    idle = preparation_intervals(trace, {'preparationBefore': state})
    slices = idle['slices']
    for row in slices:
        row['kindName'] = KINDS.get(int(row['rowKind']), 'later row')
        row['phaseName'] = PHASES[int(row['phase'])]
    labelled = [row for row in slices if row['rowKind']]
    labels_ok = len(labelled) == 21
    for kind in KINDS:
        group = [row for row in labelled if row['rowKind'] == kind]
        labels_ok &= [row['phase'] for row in group] == [1, 2, 3]
        labels_ok &= [row['firstUse'] for row in group] == [1, 0, 0]
        # Each phase must finish in a separate main-loop turn.
        labels_ok &= len({busy['startLaunchMilliseconds'] for row in group
                          for busy in row['busyIntervals']}) == 3
    for busy in idle['overlappingBusyIntervals']:
        group = [row for row in slices if row['startLaunchMilliseconds'] < busy['endLaunchMilliseconds']
                 and row['endLaunchMilliseconds'] > busy['startLaunchMilliseconds']]
        busy['sliceIndexes'] = [row['index'] for row in group]
        busy['firstUse'] = bool(group) and all(row['firstUse'] for row in group)
    first = [row for row in slices if row['firstUse']]
    later = [row for row in slices if not row['firstUse']]
    first_busy = [row for row in idle['overlappingBusyIntervals'] if row['firstUse']]
    later_busy = [row for row in idle['overlappingBusyIntervals'] if not row['firstUse']]
    maximum = lambda rows: max((row['milliseconds'] for row in rows), default=0)
    idle.update(firstUseMaximumMilliseconds=maximum(first),
                otherSliceMaximumMilliseconds=maximum(later),
                firstUseBusyMaximumMilliseconds=maximum(first_busy),
                otherBusyMaximumMilliseconds=maximum(later_busy),
                labelsOK=bool(labels_ok),
                sliceCountOK=len(slices) == state['idleSliceCount'])
    idle['allWithinFrame'] = idle['maximumSliceMilliseconds'] <= 8.3 and idle['maximumOverlappingBusyMilliseconds'] <= 8.3
    idle['closingBoundsOK'] = (maximum(first) <= 16.7 and maximum(first_busy) <= 16.7
                               and maximum(later) <= 8.3 and maximum(later_busy) <= 8.3)
    idle['ok'] = idle['coverageOK'] and labels_ok and idle['sliceCountOK'] and idle['closingBoundsOK']
    return idle


def run(args):
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    digest = hashlib.sha256()
    module = Path('Packages/OpenKit/Sources/OpenLibrary')
    for path in sorted(module.rglob('*.swift')):
        digest.update(str(path.relative_to(module)).encode()+b'\0'+path.read_bytes())
    result = {'rule': 'LEAD 14:20 (11 Nov)', 'configuration': 'Release',
              'libraryModuleSHA256': digest.hexdigest(),
              'executableSHA256': hashlib.sha256((args.bundle/'Contents/MacOS/Open').read_bytes()).hexdigest(),
              'launches': [], 'complete': False,
              'firstUseDefinition': 'Only creation (phase 1) for each of seven first row kinds; all other phases remain required.',
              'exclusions': []}
    temporary = tempfile.TemporaryDirectory(prefix='olfu-', dir='/tmp')
    root = Path(temporary.name); app = None
    deadline = time.monotonic()+13*60
    def expire(signum, frame): raise TimeoutError('13-minute ticket deadline; preserve completed launches')
    old_handler = signal.signal(signal.SIGALRM, expire)
    signal.setitimer(signal.ITIMER_REAL, 13*60)
    def save(): (out/'result.json').write_text(json.dumps(result, indent=2))
    save()
    try:
        seed(root, args.bundle, out)
        for index in range(3):
            preflight = quiet(deadline=min(deadline, time.monotonic()+360))
            app = launch(root, args.bundle, out, index,
                         {'OPEN_AUTOMATION_LIBRARY_PREPARATION_TRACE': '1'})
            states = []; until = time.monotonic()+35
            while time.monotonic() < until:
                state = app.call('library-performance', operation='preparation-state')
                states.append(state)
                if state['completed']: break
                time.sleep(.05)
            assert states[-1]['completed'], states[-1]
            trace = app.call('library-performance', operation='preparation-trace', stop=True)
            idle = classify(trace, states[-1])
            row = {'index': index+1, 'quiet': preflight, 'preparationStates': states,
                   'preparation': states[-1], 'trace': trace, 'idle': idle,
                   'otherProcessesAfter': other_processes(app.bundle),
                   'valid': max(preflight[0]) <= 3.5}
            app.quit(); row['cleanup'] = app.quit_report; app = None
            result['launches'].append(row); save()
            assert row['cleanup']['ok'] and not row['cleanup']['forced'], row['cleanup']
            print(json.dumps({'launch': index+1, 'valid': row['valid'],
                  'completedLaunchMilliseconds': states[-1]['launchMilliseconds'],
                  'firstSlice': idle['firstUseMaximumMilliseconds'],
                  'otherSlice': idle['otherSliceMaximumMilliseconds'],
                  'firstBusy': idle['firstUseBusyMaximumMilliseconds'],
                  'otherBusy': idle['otherBusyMaximumMilliseconds'],
                  'allWithinFrame': idle['allWithinFrame'], 'ok': idle['ok']}), flush=True)
            if not row['valid'] or not idle['ok']:
                result['stoppedAtRequiredFailure'] = index+1
                break
        result['complete'] = len(result['launches']) == 3
        result['usesFirstUseInfo'] = any(not row['idle']['allWithinFrame'] for row in result['launches'])
        result['ok'] = result['complete'] and all(row['valid'] and row['idle']['ok'] for row in result['launches'])
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    raise SystemExit(run(parser.parse_args()))
