#!/usr/bin/env python3
"""Multi-arm interleaved bench with work metrics; paired deltas against the first arm."""
import argparse, json, os, re, statistics, subprocess
from pathlib import Path
p = argparse.ArgumentParser(); p.add_argument('--rounds', type=int, default=12); p.add_argument('--out', required=True)
p.add_argument('--arm', action='append', required=True, help='name=binary|args|ENV=VAL,...')
a = p.parse_args(); out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
arms = []
for spec in a.arm:
    name, rest = spec.split('=', 1); b, args, env = (rest.split('|') + ['', ''])[:3]
    arms.append((name, b, args.split(), dict(kv.split('=', 1) for kv in env.split(',') if kv)))
pats = {'wall_med': r'^scroll \d+ steps .*?median ([0-9.]+)', 'wall_p95': r'^scroll \d+ steps .*?p95 ([0-9.]+)',
        'cpu_med': r'main-thread cpu: median ([0-9.]+)', 'cpu_p95': r'main-thread cpu: median [0-9.]+ ms, p95 ([0-9.]+)',
        'instr': r'scroll work: ([0-9]+) instructions', 'cycles': r'instructions/step, ([0-9]+) cycles'}
def run(arm, tag):
    name, b, args, env = arm
    r = subprocess.run([b, 'bench', '--rows', '1000'] + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True, env={**os.environ, **env})
    (out / f'{name}-{tag}.log').write_text(r.stdout)
    return {k: float(re.search(v, r.stdout, re.M).group(1)) for k, v in pats.items()}
for arm in arms: run(arm, 'warm')
rounds = []
for i in range(a.rounds):
    order = arms[i % len(arms):] + arms[:i % len(arms)]
    if i % 2: order = order[::-1]
    rec = {arm[0]: run(arm, str(i + 1)) for arm in order}; rounds.append(rec)
    print(i + 1, ' | '.join(f"{n}: {rec[n]['wall_p95']:.2f}ms {rec[n]['instr'] / 1e6:.3f}M" for n, *_ in arms), flush=True)
base = arms[0][0]; summary = {}
for name, *_ in arms:
    summary[name] = {}
    for k in pats:
        d = sorted(r[name][k] - r[base][k] for r in rounds); n = len(d) // 5
        summary[name][k] = {'median': statistics.median(r[name][k] for r in rounds), 'paired_median_delta': statistics.median(d),
                            'trim20_delta': statistics.mean(d[n:len(d) - n]), 'higher': sum(x > 0 for x in d)}
(out / 'summary.json').write_text(json.dumps({'rounds': rounds, 'summary': summary}, indent=1))
for k in pats:
    print(k, ' | '.join(f"{n}: {s[k]['median']:.4g} (Δ {s[k]['paired_median_delta']:+.4g}, trim {s[k]['trim20_delta']:+.4g}, higher {s[k]['higher']}/{len(rounds)})" for n, s in summary.items()))
