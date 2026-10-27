#!/usr/bin/env python3
"""Interleaved pairs on one scratch binary; paired deltas for wall, CPU, instruction and cycle metrics."""
import argparse, json, os, re, statistics, subprocess
from pathlib import Path
p = argparse.ArgumentParser(); p.add_argument('--bin', required=True); p.add_argument('--pairs', type=int, default=16); p.add_argument('--out', required=True)
p.add_argument('--b-args', default='--media-card'); p.add_argument('--b-env', default='')
a = p.parse_args(); out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
benv = dict(kv.split('=', 1) for kv in a.b_env.split(',') if kv)
pats = {'wall_med': r'^scroll \d+ steps .*?median ([0-9.]+)', 'wall_p95': r'^scroll \d+ steps .*?p95 ([0-9.]+)',
        'cpu_med': r'main-thread cpu: median ([0-9.]+)', 'cpu_p95': r'main-thread cpu: median [0-9.]+ ms, p95 ([0-9.]+)',
        'wait_med': r'off-cpu wait: median ([0-9.]+)', 'instr': r'scroll work: ([0-9]+) instructions', 'cycles': r'instructions/step, ([0-9]+) cycles'}
def run(label, tag):
    args = a.b_args.split() if label == 'B' else []
    env = {**os.environ, **(benv if label == 'B' else {})}
    r = subprocess.run([a.bin, 'bench', '--rows', '1000'] + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True, env=env)
    (out / f'{label}-{tag}.log').write_text(r.stdout)
    return {k: float(re.search(v, r.stdout, re.M).group(1)) for k, v in pats.items()}
run('A', 'warm'); run('B', 'warm'); rec = []
for i in range(1, a.pairs + 1):
    row = {}
    for label in (['A', 'B'] if i % 2 else ['B', 'A']): row[label] = run(label, i)
    rec.append(row); print(i, ' '.join(f"{k}:{row['B'][k] - row['A'][k]:+.3g}" for k in pats), flush=True)
summary = {}
for k in pats:
    d = sorted(r['B'][k] - r['A'][k] for r in rec); n = len(d) // 5
    summary[k] = {'A_median': statistics.median(r['A'][k] for r in rec), 'B_median': statistics.median(r['B'][k] for r in rec),
                  'paired_median_delta': statistics.median(d), 'trim20_delta': statistics.mean(d[n:len(d) - n]), 'B_higher': sum(x > 0 for x in d), 'pairs': len(d)}
(out / 'summary.json').write_text(json.dumps({'records': rec, 'summary': summary}, indent=1))
print(f"{'metric':9} {'A med':>12} {'B med':>12} {'Δ med':>11} {'Δ trim20':>11} B higher")
for k, s in summary.items(): print(f"{k:9} {s['A_median']:12.4g} {s['B_median']:12.4g} {s['paired_median_delta']:+11.4g} {s['trim20_delta']:+11.4g} {s['B_higher']}/{s['pairs']}")
