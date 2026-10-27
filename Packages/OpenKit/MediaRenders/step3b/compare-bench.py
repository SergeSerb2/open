#!/usr/bin/env python3
"""MC9: 12 interleaved pairs, main/no card vs head/one paused 41 pt card.
Each measurement holds the shared on-screen lock. Builds use heavy.sh.
"""
from pathlib import Path
import argparse, hashlib, io, json, re, statistics, subprocess, sys, tarfile
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline-ref', required=True)
p.add_argument('--baseline-bin')
p.add_argument('--out', required=True)
p.add_argument('--series-lock', action='store_true', help='hold the on-screen lock for the full measurement series; pass a prebuilt baseline')
p.add_argument('--lock-held', action='store_true', help=argparse.SUPPRESS)
p.add_argument('--aa', action='store_true', help='same head binary, no card on either side')
a = p.parse_args()
if a.series_lock and not a.lock_held:
    if not a.aa and not a.baseline_bin:
        p.error('--series-lock requires --baseline-bin (build before acquiring the on-screen lock)')
    raise SystemExit(subprocess.call(['/usr/bin/lockf','/tmp/open-onscreen-e2e.lock',sys.executable,str(Path(__file__).resolve()),*sys.argv[1:],'--lock-held']))
repo = Path(__file__).resolve().parents[4]
out = Path(a.out).resolve(); out.mkdir(parents=True, exist_ok=False)
sha = subprocess.check_output(['git','rev-parse',a.baseline_ref],cwd=repo,text=True).strip()
head = repo/'Packages/OpenKit/.build/release/sidebar-render'
if a.aa:
    baseline = head
elif a.baseline_bin:
    baseline = Path(a.baseline_bin).resolve()
else:
    base = out/'baseline'; base.mkdir()
    blob = subprocess.check_output(['git','archive',sha,'Packages/OpenKit'],cwd=repo)
    with tarfile.open(fileobj=io.BytesIO(blob)) as archive: archive.extractall(base)
    with (out/'baseline-build.log').open('w') as log:
        subprocess.run([str(Path.home()/'Library/Caches/OpenRE/scripts/heavy.sh'),'nice','-n','10','swift','build','--package-path',str(base/'Packages/OpenKit'),'-c','release','--product','sidebar-render','-j','6'],stdout=log,stderr=subprocess.STDOUT,start_new_session=True,check=True)
    baseline = base/'Packages/OpenKit/.build/release/sidebar-render'
bins = {'baseline':baseline,'head':head}
hashes = {k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in bins.items()}
records = []
def run(label,name,stack=False):
    flags = ['--media-stack'] if stack else (['--media-card'] if label=='head' and not a.aa else [])
    cmd = [str(bins[label]),'bench','--rows','1000',*flags]
    if not a.lock_held: cmd = ['/usr/bin/lockf','/tmp/open-onscreen-e2e.lock',*cmd]
    result = subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,check=True)
    (out/(name+'.log')).write_text(result.stdout)
    assert 'rows match the model after edits: yes' in result.stdout
    if label=='head' and not a.aa and not stack: assert 'media fixture: one paused card, container 41.0 pt' in result.stdout
    if stack: assert 'media fixture: three paused cards, container 55.0 pt' in result.stdout
    m=re.search(r'scroll .*?p95 ([0-9.]+) ms',result.stdout); assert m
    return float(m.group(1))
for label in bins: run(label,label+'-warmup')
pair_count = 20 if a.aa else 12
for pair in range(1,pair_count+1):
    for label in (['baseline','head'] if pair%2 else ['head','baseline']):
        value=run(label,f'{label}-{pair}')
        records.append({'build':label,'pair':pair,'p95_ms':value})
        print(label,pair,'p95',value,flush=True)
deltas=[next(r['p95_ms'] for r in records if r['pair']==i and r['build']=='head')-next(r['p95_ms'] for r in records if r['pair']==i and r['build']=='baseline') for i in range(1,pair_count+1)]
sorted_deltas=sorted(deltas); trim=len(deltas)//5
summary={'paired_deltas_ms':deltas,'paired_median_delta_ms':statistics.median(deltas),'paired_trimmed20_mean_delta_ms':statistics.mean(sorted_deltas[trim:-trim])}
for label in bins:
    values=[r['p95_ms'] for r in records if r['build']==label]
    summary[label]={'median_p95_ms':statistics.median(values),'mean_p95_ms':statistics.mean(values)}
passed=summary['paired_median_delta_ms']<=0.3 and summary['paired_trimmed20_mean_delta_ms']<=0.3
stack=run('head','stack-report-only',stack=True) if not a.aa else None
assert hashes == {k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in bins.items()}, 'binary changed during measurements'
receipt={'baseline_ref':sha,'lock':'/tmp/open-onscreen-e2e.lock','lock_scope':'series' if a.lock_held else 'per-run','pairs':pair_count,'mode':'A/A' if a.aa else 'MC9','binary_sha256':hashes,'records':records,'summary':summary,'stack_report_only_p95_ms':stack,'MC9':'PASS' if passed else 'FAIL'}
(out/'results.json').write_text(json.dumps(receipt,indent=2)+'\n'); print(json.dumps(receipt,indent=2),flush=True)
raise SystemExit(0 if passed else 1)
