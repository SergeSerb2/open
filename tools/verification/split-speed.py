#!/usr/bin/env python3
"""Compare the unchanged 1,000-row real sidebar scroll workload, paired three times.

Build both binaries first under heavy.sh. Run this receipt under open-m5-quiet.lock.
The benchmark uses the real AppKit sidebar in an offscreen window; no desktop input.
"""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess


def run(binary):
    before = list(os.getloadavg())
    result = subprocess.run([str(binary), 'bench', '--rows', '1000'], text=True, capture_output=True, timeout=120)
    after = list(os.getloadavg())
    match = re.search(r'scroll \d+ steps.*?p95 ([0-9.]+) ms', result.stdout)
    if result.returncode or not match:
        raise RuntimeError('sidebar bench failed: ' + result.stdout[-2000:] + result.stderr[-1000:])
    return dict(p95_ms=float(match[1]), load_before=before, load_after=after, output=result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--main', required=True, type=Path)
    parser.add_argument('--branch', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    receipts = []
    for pair in range(3):
        row = {'pair': pair+1}
        # AB, BA, AB: alternate adjacent runs without discarding any sample.
        for name in (('main', 'branch') if pair % 2 == 0 else ('branch', 'main')):
            row[name] = run(getattr(args, name).resolve())
            print('%s pair %d p95 %.3f ms load %s → %s' %
                  (name, pair+1, row[name]['p95_ms'], row[name]['load_before'], row[name]['load_after']), flush=True)
        receipts.append(row)
    baseline = statistics.median(r['main']['p95_ms'] for r in receipts)
    changed = statistics.median(r['branch']['p95_ms'] for r in receipts)
    ratio = changed / baseline
    ok = .9 <= ratio <= 1.1
    report = dict(ok=ok, baseline_p95_ms=baseline, branch_p95_ms=changed, ratio=ratio,
                  limit='median paired p95 within ±10%; three pairs; no samples discarded', pairs=receipts)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print('split sidebar scroll parity %s: %.3f → %.3f ms, %+.2f%%' %
          ('PASS' if ok else 'FAIL', baseline, changed, (ratio-1)*100), flush=True)
    raise SystemExit(0 if ok else 1)


if __name__ == '__main__':
    main()
