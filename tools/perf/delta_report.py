#!/usr/bin/env python3
"""Add the ruled current-main delta without relabeling the pinned cohort."""
import argparse
import copy
import json
from pathlib import Path
from campaign import MAIN_DELTA
from run import ROOT, PLANS, atomic, now, sha
from score import metric_rows, compare

def update(path):
    delta=json.loads(Path(path).read_text())
    invalidations=ROOT/'.re/perf/main-delta-invalidations.json'
    if invalidations.exists():
        rulings=json.loads(invalidations.read_text())
        for sample in delta['samples']:
            ruling=next((r for r in rulings['invalidations'] if all(sample.get(k)==r[k]
                        for k in ('browser','task','round_index','date'))),None)
            if ruling:sample['valid']=False;sample['lead_invalidation']=ruling
        delta['lead_invalidations']=rulings
    rows=metric_rows(delta,'open')
    qualified={key:r for key,r in rows.items() if r['id'] in MAIN_DELTA and r['summary']['n']>=5}
    pinned=json.loads((ROOT/'.re/perf/aw2726dm-accepted-window-v3.json').read_text())
    old=metric_rows(pinned,'open')
    score=json.loads((PLANS/'P-scorecard-1.json').read_text())
    delta_score=compare(json.loads((ROOT/'docs/perf/arc-reference-m5.json').read_text()),delta)
    info={'date':now(),'status':'COMPLETE' if len(qualified)==8 else 'IN_PROGRESS',
          'receipt':str(Path(path).resolve().relative_to(ROOT)), 'receipt_sha256':sha(path),
          'pinned_commit':pinned['provenance']['commit'],'main_commit':delta['provenance']['commit'],
          'main_app_sha256':delta['provenance']['app_main_sha256'],
          'lead_invalidations':delta.get('lead_invalidations'),
          'build':json.loads((ROOT/'.re/perf/main-build.json').read_text()),'rows':[]}
    lines=['<!-- main-delta -->','## Current-main delta','',
           f"Open `{info['pinned_commit'][:8]}` → `{info['main_commit'][:8]}`. Open-only N≥5; fixed Arc reference and private starting-state replay. Status: **{info['status']}**.",'',
           '| Metric | Pinned median | Main median | N | Main / pinned | Main score vs Arc |',
           '|---|---:|---:|---:|---:|---:|']
    scored={r['id']:r for r in delta_score['rows']}
    for key in sorted(MAIN_DELTA):
        row=qualified.get(('S-real',key));before=old[('S-real',key)]['summary']
        if not row:
            lines.append(f'| `{key}` | {before["median"]:.3f} | pending | {rows.get(("S-real",key),{}).get("summary",{}).get("n",0)} / 5 | — | — |');continue
        after=row['summary'];s=scored[key]
        info['rows'].append({'id':key,'pinned':before,'main':after,'ratio_main_to_pinned':after['median']/before['median'],'main_score_vs_arc':s['computed_score'],'overlap':s['overlap'],'load_range':row['load_range']})
        lines.append(f'| `{key}` | {before["median"]:.3f} | {after["median"]:.3f} | {after["n"]} | {after["median"]/before["median"]:.3f} | {s["computed_score"]:.1f}{" ≈" if s["overlap"] else ""} |')
    lines.extend(['',f"Release artifact SHA-256 `{info['main_app_sha256']}`. Automation-only scroll patch SHA-256 `{info['build']['automation_patch_sha256']}`. The hook is inert in these delta sessions.",
                  '', 'These eight rows update the current-build comparison in report 2. The Phase 1 headline and the other pinned measurements above keep their original build provenance.',''])
    if info['lead_invalidations']:
        lines.extend(['LEAD 04:10 excludes the original 04:06 core replay index 4 because A’s crash-report window overlapped 04:06–04:09. Its raw receipt is retained and contributes no value; the same replay is repeated under a fresh exclusive ticket.',''])
    report=PLANS/'P-report-1.md';text=report.read_text().split('<!-- main-delta -->')[0].rstrip()+'\n\n'+'\n'.join(lines)
    report.write_text(text);score['main_delta']=info;atomic(PLANS/'P-scorecard-1.json',score)
    atomic(ROOT/'.re/perf/main-delta-summary.json',info)
    print(json.dumps({'status':info['status'],'qualified_rows':len(qualified),'commit':info['main_commit']}))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('receipt',type=Path);update(p.parse_args().receipt)
