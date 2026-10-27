#!/usr/bin/env python3
"""MC9: compare real sidebar commands, main with no card against head with one paused card."""
from pathlib import Path
import argparse, hashlib, io, json, re, statistics, subprocess, tarfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline-ref', required=True)
parser.add_argument('--out', required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[4]
out = Path(args.out).resolve(); out.mkdir(parents=True, exist_ok=False)
base = out / 'baseline'; base.mkdir()
sha = subprocess.check_output(['git', 'rev-parse', args.baseline_ref], cwd=repo, text=True).strip()
blob = subprocess.check_output(['git', 'archive', sha, 'Packages/OpenKit'], cwd=repo)
with tarfile.open(fileobj=io.BytesIO(blob)) as archive: archive.extractall(base)
with (out / 'baseline-build.log').open('w') as log:
    subprocess.run(['swift', 'build', '--package-path', str(base / 'Packages/OpenKit'), '-c', 'release', '--product', 'sidebar-render', '-j', '6'], stdout=log, stderr=subprocess.STDOUT, start_new_session=True, check=True)
binaries = {'baseline': base / 'Packages/OpenKit/.build/release/sidebar-render', 'head': repo / 'Packages/OpenKit/.build/release/sidebar-render'}
records = []
def run(label, name):
    command = [str(binaries[label]), 'bench', '--rows', '1000'] + (['--media-card'] if label == 'head' else [])
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True)
    (out / (name + '.log')).write_text(result.stdout)
    assert 'rows match the model after edits: yes' in result.stdout
    if label == 'head': assert 'media fixture: one paused card, container 76.0 pt' in result.stdout
    match = re.search(r'scroll .*?p95 ([0-9.]+) ms', result.stdout); assert match
    return float(match.group(1))
for label in binaries: run(label, label + '-warmup')
for pair in range(1, 7):
    for label in (['baseline', 'head'] if pair % 2 else ['head', 'baseline']):
        p95 = run(label, f'{label}-{pair}')
        records.append({'build': label, 'pair': pair, 'p95_ms': p95})
        print(label, pair, 'p95', p95, flush=True)
summary = {}
for label in binaries:
    values = [r['p95_ms'] for r in records if r['build'] == label]
    summary[label] = {'runs': values, 'median_p95_ms': statistics.median(values), 'mean_p95_ms': statistics.mean(values)}
for metric in ['median_p95_ms', 'mean_p95_ms']:
    summary[metric + '_delta'] = summary['head'][metric] - summary['baseline'][metric]
passed = summary['median_p95_ms_delta'] <= 0.3 and summary['mean_p95_ms_delta'] <= 0.3
receipt = {'baseline_ref': sha, 'binary_sha256': {label: hashlib.sha256(path.read_bytes()).hexdigest() for label, path in binaries.items()}, 'records': records, 'summary': summary, 'MC9': 'PASS' if passed else 'FAIL'}
(out / 'results.json').write_text(json.dumps(receipt, indent=2))
print(json.dumps(receipt, indent=2), flush=True)
raise SystemExit(0 if passed else 1)
