#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, re, statistics, subprocess, tempfile
import argparse, io, tarfile
parser=argparse.ArgumentParser(description="Compare actual sidebar scroll timing against a pinned main snapshot.")
parser.add_argument('--baseline-ref', required=True)
parser.add_argument('--out', required=True)
args=parser.parse_args()
repo=Path(__file__).resolve().parents[4]
out=Path(args.out).resolve(); out.mkdir(parents=True, exist_ok=False)
base=out/'baseline'; base.mkdir()
blob=subprocess.check_output(['git','archive',args.baseline_ref,'Packages/OpenKit'],cwd=repo)
with tarfile.open(fileobj=io.BytesIO(blob)) as tar: tar.extractall(base)
relative=Path('Packages/OpenKit/Sources/sidebar-render/Bench.swift')
(base/relative).write_bytes((repo/relative).read_bytes())
sha=subprocess.check_output(['git','rev-parse',args.baseline_ref],cwd=repo,text=True).strip()
(base/'baseline-receipt.txt').write_text(f'{args.baseline_ref} {sha}\nOnly Bench.swift receives head fixture instrumentation.\n')
with (out/'baseline-build.log').open('w') as log:
    subprocess.run(['swift','build','--package-path',str(base/'Packages/OpenKit'),'-c','release','--product','sidebar-render','-j','6'],stdout=log,stderr=subprocess.STDOUT,start_new_session=True,check=True)
relative=Path('Packages/OpenKit/Sources/sidebar-render/Bench.swift')
assert (base/relative).read_bytes()==(repo/relative).read_bytes()
bins={'baseline':base/'Packages/OpenKit/.build/release/sidebar-render','head':repo/'Packages/OpenKit/.build/release/sidebar-render'}
records=[]
for variant in ['plain','mixed']:
    extra=[] if variant=='plain' else ['--row-media','mixed']
    for label in ['baseline','head']:
        r=subprocess.run([str(bins[label]),'bench','--rows','1000']+extra,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,check=True)
        (out/f'{variant}-{label}-warmup.log').write_text(r.stdout)
    for i in range(1,7):
        for label in (['baseline','head'] if i % 2 else ['head','baseline']):
            r=subprocess.run([str(bins[label]),'bench','--rows','1000']+extra,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,check=True)
            (out/f'{variant}-{label}-{i}.log').write_text(r.stdout)
            match=re.search(r'scroll .*?p95 ([0-9.]+) ms',r.stdout)
            assert match and 'rows match the model after edits: yes' in r.stdout
            p95=float(match.group(1)); records.append({'variant':variant,'build':label,'run':i,'p95_ms':p95})
            print(variant,label,i,'p95',p95,flush=True)
summary={}
for variant in ['plain','mixed']:
    summary[variant]={}
    for label in ['baseline','head']:
        values=[r['p95_ms'] for r in records if r['variant']==variant and r['build']==label]
        summary[variant][label]={'runs':values,'median_p95_ms':statistics.median(values),'mean_p95_ms':statistics.mean(values)}
    summary[variant]['mean_delta_ms']=summary[variant]['head']['mean_p95_ms']-summary[variant]['baseline']['mean_p95_ms']
receipt={'baseline':(base/'baseline-receipt.txt').read_text(),'bench_source_sha256':hashlib.sha256((repo/relative).read_bytes()).hexdigest(),'binary_sha256':{k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in bins.items()},'records':records,'summary':summary}
(out/'results.json').write_text(json.dumps(receipt,indent=2))
print(json.dumps(summary,indent=2),flush=True)
print('artifacts',out,flush=True)
