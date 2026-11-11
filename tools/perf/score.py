#!/usr/bin/env python3
"""Score real browser receipts against a frozen, machine-specific Arc cohort."""
import argparse
import datetime as dt
import json
import math
from pathlib import Path
import statistics
from display import displays_match

WEIGHTS = {'Interaction latency':25, 'Smoothness':15, 'Launch':15, 'Memory':15,
           'Idle CPU/energy':15, 'Page load':5, 'Web benchmarks':5, 'Resume':3, 'Disk':2}

def category(metric):
    return {'launch':'Launch', 'mem':'Memory', 'cpu':'Idle CPU/energy', 'energy':'Idle CPU/energy',
            'wakeups':'Idle CPU/energy', 'load':'Page load', 'bench':'Web benchmarks',
            'disk':'Disk', 'procs':'Disk', 'ui':'Interaction latency', 'fps':'Smoothness',
            'resume':'Resume'}.get(metric.split('.')[0], 'Stability diagnostics')

def summarize(values):
    values = sorted(values)
    def q(p):
        index = (len(values)-1)*p
        low = int(index)
        return values[low] + (values[min(low+1,len(values)-1)]-values[low])*(index-low)
    return {'n':len(values), 'median':statistics.median(values), 'p25':q(.25), 'p75':q(.75),
            'min':min(values), 'max':max(values)} if values else None

def score(ratio):
    return round(max(0., min(10., 7.+3.*math.log2(ratio))), 1)

def required_n(metric, provenance):
    policy = provenance.get('sampling_policy', {})
    if metric in policy.get('metric_required_n',{}):
        return policy['metric_required_n'][metric]
    if metric.startswith('disk.'):
        return policy.get('disk_required_n', 7)
    if metric.startswith('bench.'):
        return policy.get('metric_required_n', {}).get(metric, policy.get('web_initial_n', 7))
    return policy.get('core_required_n', 7)

def benchmark_target(run, counted, task, order):
    key='bench.'+task[6:]
    policy=run['provenance']['sampling_policy']
    spreads={}
    for browser in order:
        values=[s['metrics'][key]['value'] for s in counted['samples']
                if s['browser']==browser and s.get('valid') and key in s.get('metrics',{})][:3]
        if len(values)==3:
            spreads[browser]=(max(values)-min(values))/statistics.median(values)
    if spreads:
        policy.setdefault('web_first_three_relative_ranges',{})[key]=spreads
    target=required_n(key,run['provenance'])
    if any(v>.05 for v in spreads.values()):target=max(target,5)
    policy['metric_required_n'][key]=target
    return target

def metric_rows(run,browser=None):
    rows = {}
    for sample in run.get('samples', []):
        if browser and sample.get('browser')!=browser:continue
        if not sample.get('valid', False): continue
        for metric, record in sample.get('metrics', {}).items():
            if not isinstance(record['value'],(int,float)) or not math.isfinite(record['value']):
                raise ValueError(f'{metric}: missing or non-finite numerical measurement')
            key = (sample['state'], metric)
            row = rows.setdefault(key, {'state':key[0], 'id':metric, 'unit':record['unit'],
                'direction':record.get('direction','lower'), 'values':[], 'loads':[], 'dates':[], 'commits':set(), 'app_hashes':set()})
            if record.get('detector'):row['detector']=record['detector']
            row['commits'].add(sample.get('commit',run['provenance']['commit']))
            row['app_hashes'].add(sample.get('app_main_sha256',run['provenance'].get('app_main_sha256')))
            row['values'].append(record['value'])
            row['loads'].extend([sample['load_before'], sample['load_after']])
            row['loads'].extend(v['load'] for v in sample.get('checkpoints',[]) if 'load' in v)
            row['dates'].append(sample['date'])
    for row in rows.values():
        row['commits']=sorted(row['commits'])
        row['app_hashes']=sorted(v for v in row['app_hashes'] if v)
        if len(row['commits'])!=1:raise ValueError('Cannot mix Open builds inside one metric row')
        row['summary'] = summarize(row.pop('values'))
        row['load_range'] = [[min(v[i] for v in row['loads']),max(v[i] for v in row['loads'])] for i in range(3)]
        del row['loads']
    return rows

def freeze(run):
    expected=run['provenance']['arc_version']
    if any(s.get('arc_version_before',expected)!=expected or s.get('arc_version_after',expected)!=expected for s in run['samples']):
        raise ValueError('Cannot freeze mixed Arc builds')
    rows=list(metric_rows(run,'arc').values())
    for row in rows:
        row.pop('commits',None);row.pop('app_hashes',None)
    if not rows or any(v['summary']['n']<required_n(v['id'],run['provenance']) for v in rows):
        raise ValueError('Frozen Arc reference does not meet its declared per-metric sample targets')
    return {'schema':1, 'kind':'frozen-arc-reference', 'date':run['date'], 'provenance':run['provenance'],
            'display':run['provenance']['display'],
            'arc_version':expected[0], 'arc_build':expected[1],
            'metrics':rows, 'blocked':run.get('blocked',{}),
            'negative_proofs':run.get('negative_proofs',{}),
            'intent_failures':run.get('intent_failures',[]),
            'latency_qualification':'Conditional on successful startup; failed intents are retained separately'}

def compare(reference, current):
    if current.get('calibration_only') or any(s.get('background_jobs_before') or s.get('background_jobs_after') for s in current.get('samples',[])):
        raise ValueError('Calibration or background-build receipts are not eligible for scoring')
    if reference.get('kind')!='frozen-arc-reference':
        raise ValueError('Expected a frozen Arc reference, not a scorecard or an unqualified run')
    for key in ('hardware','os'):
        if reference['provenance'][key]!=current['provenance'][key]:
            raise ValueError(f'Cannot score across different {key}; record a matching Arc reference')
    if not displays_match(reference['provenance']['display'], current['provenance']['display']):
        raise ValueError('Cannot score across different display; record a matching Arc reference')
    arc = {(v['state'],v['id']):v for v in reference['metrics']}
    rows=[]; categories={}
    for key, b in sorted(metric_rows(current,'open').items()):
        a=arc.get(key)
        if not a: continue
        aa,bb=a['summary'],b['summary']
        floor=(.1 if key[1].startswith(('cpu.','energy.')) else
               1. if key[1].startswith('wakeups.') else
               .1 if key[1].startswith('fps.') and key[1].endswith('_pct') else 0.)
        av,bv=aa['median']+floor,bb['median']+floor
        if min(av,bv)<=0: continue
        ratio=av/bv if b['direction']=='lower' else bv/av
        overlap=max(aa['p25'],bb['p25'])<=min(aa['p75'],bb['p75'])
        arc_required=required_n(key[1],reference['provenance'])
        open_required=required_n(key[1],current['provenance'])
        qualified=aa['n']>=arc_required and bb['n']>=open_required
        effective=1. if overlap else ratio
        bounded=max(.5,min(2.,ratio))
        category_ratio=1. if overlap else bounded
        cat=category(key[1])
        row={'id':key[1], 'state':key[0], 'category':cat, 'unit':b['unit'], 'direction':b['direction'],
             'arc':aa, 'open':bb, 'epsilon':floor, 'ratio':ratio, 'arc_score':7., 'computed_score':score(ratio),
             'clamped_ratio':bounded, 'ratio_clamped':bounded!=ratio,
             'category_ratio':category_ratio, 'category_metric_score':score(category_ratio),
             'overlap':overlap, 'effective_score':7. if overlap else score(ratio), 'qualified':qualified,
             'required_arc_n':arc_required, 'required_open_n':open_required,
             'open_commit':b['commits'][0], 'open_app_sha256':b['app_hashes'], 'date':current['date'], 'load_range':b['load_range'],
             'sample_date_range':[min(b['dates']),max(b['dates'])],
             'arc_load_range':a['load_range'], 'budget':{'status':'NO COMPARABLE BUDGET'}}
        if b.get('detector'):row['detector']=b['detector']
        # Window-list detection is NOT a confirmed sidebar frame. The plan's
        # local-page CPU fixture also differs from the architecture's ten sites.
        if key[1] in ('launch.window_ms','launch.first_paint_ms','cpu.idle_10tabs_pct'):
            limit={'launch.window_ms':250.,'launch.first_paint_ms':700.,'cpu.idle_10tabs_pct':.5}[key[1]]
            row['budget']={'limit':limit,'distance':bb['median']-limit,
                'numerical_status':'PASS' if bb['median']<=limit else 'FAIL',
                'status':'NOT EQUIVALENT TO ARCHITECTURE FIXTURE', 'source':'docs/architecture.md:75'}
        rows.append(row)
        if qualified and cat in WEIGHTS: categories.setdefault(cat,[]).append((effective,category_ratio))
    cats={cat:{'score':score(math.exp(statistics.mean(math.log(r[1]) for r in ratios))),
               'raw_score':score(math.exp(statistics.mean(math.log(r[0]) for r in ratios))),
               'metric_count':len(ratios), 'weight':WEIGHTS[cat]} for cat,ratios in categories.items()}
    overall=sum(v['score']*v['weight'] for v in cats.values())/sum(v['weight'] for v in cats.values()) if cats else None
    raw_overall=sum(v['raw_score']*v['weight'] for v in cats.values())/sum(v['weight'] for v in cats.values()) if cats else None
    return {'schema':1,'label':'Phase 1 partial','date':current['date'],'rows':rows,'categories':cats,
            'overall':round(overall,1) if overall is not None else None,
            'overall_clamped':round(overall,1) if overall is not None else None,
            'overall_raw':round(raw_overall,1) if raw_overall is not None else None,
            'scoring_policy':{'authorization':'LEAD 01:35','category_ratio_bounds':[.5,2.],
                              'headline':'clamped','row_scores':'raw ratios; overlapping intervals use ratio 1 for totals'},
            'coverage_weight':sum(v['weight'] for v in cats.values()),
            'blocked':current.get('blocked',{}),'provenance':current['provenance'],
            'negative_proofs':current.get('negative_proofs',{}),
            'reference_session_outcomes':reference.get('session_outcomes',{}),
            'reference_intent_failures':reference.get('intent_failures',[]),
            'current_intent_failures':current.get('intent_failures',[]),
            'latency_qualification':reference.get('latency_qualification'),
            'qualification':'Declared per-metric sample targets; overlapping interquartile intervals count as 7.0 in totals'}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('reference',type=Path);p.add_argument('open_run',type=Path,nargs='?')
    p.add_argument('--out',type=Path);p.add_argument('--freeze',action='store_true')
    a=p.parse_args();ref=json.loads(a.reference.read_text())
    if a.freeze: out=freeze(ref)
    else:
        if a.open_run is None:p.error('fresh Open run required')
        out=compare(ref,json.loads(a.open_run.read_text()))
    if a.out:
        a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(out,indent=2)+'\n')
    if not a.freeze:
        print('| Metric | State | Arc raw | Open raw | Raw ratio | Raw score | Category ratio | N A/O | Budget proxy |')
        print('|---|---|---:|---:|---:|---:|---:|---|---|')
        for row in out['rows']:
            mark=' ≈' if row['overlap'] else ''
            clamp_mark=' †' if row['ratio_clamped'] else ''
            budget=row['budget']
            proxy=(f"{budget['numerical_status']} ({budget['distance']:+.3f} {row['unit']})"
                   if 'numerical_status' in budget else '—')
            print(f"| {row['id']} | {row['state']} | {row['arc']['median']:.3f} | {row['open']['median']:.3f} | {row['ratio']:.3f}{clamp_mark} | {row['computed_score']:.1f}{mark} | {row['category_ratio']:.3f} | {row['arc']['n']}/{row['open']['n']} | {proxy} |")
        print('\nCategory scores:',json.dumps(out['categories'],sort_keys=True))
        print('Phase 1 partial overall — clamped:',out['overall_clamped'],'raw:',out['overall_raw'])
    elif not a.out:print(json.dumps(out,indent=2))

if __name__=='__main__':
    try:main()
    except (ValueError,KeyError) as exc:raise SystemExit('Cannot score: '+str(exc))
