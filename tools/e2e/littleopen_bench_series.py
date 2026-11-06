#!/usr/bin/env python3
"""Interleaved Little Open receipts with the screen lock released between pairs.

Run under /usr/bin/lockf -k /tmp/open-m5-quiet.lock. The per-App sample method
is littleopen_bench.py's unchanged native-frame/submit/load/memory method.
Only the complete aggregate (at least ten pairs) is an acceptance receipt.
"""
import argparse
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--main-bundle', required=True)
    parser.add_argument('--branch-bundle', required=True)
    parser.add_argument('--config', default='Release')
    parser.add_argument('--samples', type=int, default=10)
    parser.add_argument('--output', required=True)
    parser.add_argument('--scenario', choices=('immediate', 'typed', 'external'), default='immediate')
    parser.add_argument('--report-only', action='store_true', help='record measurements without a performance verdict')
    args = parser.parse_args()
    # New user-realistic paths are measurements for the lead, never new gates.
    args.report_only = args.report_only or args.scenario != 'immediate'
    if not 10 <= args.samples <= 100:
        parser.error('10 to 100 samples per build are required')
    output = Path(args.output).resolve()
    attempts = output.with_suffix('.attempts')
    attempts.mkdir(parents=True, exist_ok=False)
    priority = Path('/tmp/open-onscreen-priority')
    receipt = {'scenario': args.scenario, 'reportOnly': args.report_only, 'samples': [], 'attempts': [], 'complete': False,
               'screenLock': 'one interleaved pair per lock; low-load waits hold only the outer quiet lock'}
    output.write_text(json.dumps(receipt, indent=2) + '\n')
    for index in range(args.samples):
        attempt = 0
        while True:
            # Never wait for low load while holding the screen lock.
            while priority.exists() or os.getloadavg()[0] > 12:
                print('waiting with quiet lock only; load=%s priority=%s' %
                      (os.getloadavg(), priority.exists()), flush=True)
                time.sleep(5)
            path = attempts / ('pair-%02d-attempt-%02d.json' % (index, attempt))
            log = path.with_suffix('.log')
            command = ['/usr/bin/lockf', '-k', '-t', '0', '/tmp/open-onscreen-e2e.lock',
                       sys.executable, str(Path(__file__).with_name('littleopen_bench.py')),
                       '--main-bundle', args.main_bundle, '--branch-bundle', args.branch_bundle,
                       '--config', args.config, '--samples', str(args.samples),
                       '--pair-index', str(index), '--output', str(path), '--scenario', args.scenario]
            if args.report_only:
                command.append('--report-only')
            with log.open('w') as stream:
                result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT)
            if result.returncode == 75:
                # lockf did not acquire the screen. The sampler never ran.
                time.sleep(5)
                continue
            attempt += 1
            text = log.read_text()
            entry = {'pair': index, 'attempt': attempt, 'exit': result.returncode,
                     'receipt': path.name, 'log': log.name}
            receipt['attempts'].append(entry)
            if result.returncode:
                output.write_text(json.dumps(receipt, indent=2) + '\n')
                if 'load1 exceeded 12' in text:
                    # Discard the entire incomplete pair solely on the declared
                    # load rule, never on its timing outcome; retry after release.
                    print('pair %d invalid at load limit; screen released' % index, flush=True)
                    continue
                raise RuntimeError('pair failed; see ' + str(log))
            partial = json.loads(path.read_text())
            rows = partial['samples']
            if (len(rows) != 2 or {r['build'] for r in rows} != {'main', 'branch'}
                    or any(r['pair'] != index or max(r['load'][0], r['endLoad'][0]) > 12 for r in rows)):
                raise RuntimeError('invalid paired receipt: ' + str(path))
            receipt['samples'].extend(rows)
            for key in ('configuration', 'method', 'externalMethod', 'typedDelayMs', 'memory', 'mainBundle', 'branchBundle'):
                receipt[key] = partial[key]
            output.write_text(json.dumps(receipt, indent=2) + '\n')
            print('pair %d/%d complete; load1=%s' %
                  (index + 1, args.samples, [r['load'][0] for r in rows]), flush=True)
            break
    receipt['summary'] = {}
    for label in ('main', 'branch'):
        rows = [r for r in receipt['samples'] if r['build'] == label]
        if len(rows) != args.samples:
            raise RuntimeError('incomplete sample count')
        summary = receipt['summary'][label] = {}
        for metric in ('firstFrameMs', 'pageLoadMs', 'openToFCPMs', 'windowRSS', 'loadedRSS', 'browserCreationToReadyMs'):
            values = sorted(r[metric] for r in rows if metric in r)
            if values:
                summary[metric] = {'median': statistics.median(values),
                                   'p95': values[math.ceil(len(values) * .95) - 1]}
    if not args.report_only:
        receipt['noSlower'] = all(receipt['summary']['branch'][metric][pct] <= receipt['summary']['main'][metric][pct]
                             for metric in ('firstFrameMs', 'pageLoadMs') for pct in ('median', 'p95'))
    receipt['extraHiddenBrowserRSS'] = receipt['summary']['branch']['windowRSS']['median'] - receipt['summary']['main']['windowRSS']['median']
    receipt['complete'] = True
    output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({k: receipt[k] for k in ('summary', 'noSlower', 'extraHiddenBrowserRSS') if k in receipt}, indent=2), flush=True)
    if not args.report_only and not receipt['noSlower']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
