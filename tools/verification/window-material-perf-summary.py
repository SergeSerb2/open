#!/usr/bin/env python3
"""Summarize raw Section 5 receipts; retain interrupted/error attempts separately."""
import argparse
import json
import math
from pathlib import Path
import re
import statistics


def stats(values):
    values = sorted(values)
    if not values: return {'n':0}
    return dict(n=len(values),median=statistics.median(values),
                p95=values[min(len(values)-1,math.floor(len(values)*.95))],
                min=values[0],max=values[-1])


def loads(rows):
    values = [r['load'] for r in rows if 'load' in r]
    return [stats([v[i] for v in values]) for i in range(3)]


def cpu_rows(samples,pid):
    result=[]
    for sample in samples:
        for line in sample.get('cpu','').splitlines():
            parts=line.split()
            if len(parts)!=3 or int(parts[0])!=pid: continue
            fields=parts[2].split(':'); seconds=0
            for value in fields: seconds=seconds*60+float(value)
            result.append(dict(time=sample['time'],pct=float(parts[1]),seconds=seconds))
    return result


def sensors(groups):
    samples=[s for _,ss in groups for s in ss]
    gpu={key:stats([g[key] for s in samples for g in s.get('gpu',[]) if key in g])
         for key in ('Device Utilization %','Renderer Utilization %')}
    app=[]; server=[]; delta=[]
    for pid,ss in groups:
        rows=cpu_rows(ss,pid); app.extend(r['pct'] for r in rows)
        if len(rows)>1 and rows[-1]['time']>rows[0]['time']:
            delta.append(100*(rows[-1]['seconds']-rows[0]['seconds'])/(rows[-1]['time']-rows[0]['time']))
        for s in ss:
            for line in s.get('cpu','').splitlines():
                fields=line.split()
                if len(fields)==3 and int(fields[0])!=pid: server.append(float(fields[1]))
    return dict(gpu=gpu,appPsPct=stats(app),appIntervalCpuPct=stats(delta),
                windowServerPsPct=stats(server),load=loads(samples))


def summarize(runs):
    answer={'runs':[r['label'] for r in runs],'motion':{},'idle':{},'activation':{}}
    for page in ('band','white'):
        segments=[(r,r['motion'][page]) for r in runs if page in r.get('motion',{})]
        if not segments: continue
        motion={'sensors':sensors([(r['pid'],s['samples']) for r,s in segments])}
        for direction in ('in','out'):
            gaps=[]; timestamp_gaps=[]; intervals=[]; bad=0; count_by_cycle=[]
            for r,segment in segments:
                counts={}
                frames=segment['probe']['frames']
                for previous,f in zip(frames,frames[1:]):
                    if not f['animated'] or f['offset'] is None: continue
                    kind='in' if f['shows']>f['hides'] else 'out'
                    if kind!=direction: continue
                    dt=f['time']-previous['time']
                    interval=f['duration'] or f['targetTimestamp']-f['timestamp']
                    gaps.append(dt*1000); intervals.append(interval*1000)
                    timestamp_gaps.append((f['timestamp']-previous['timestamp'])*1000)
                    bad+=dt>1.5*interval
                    key=(f['shows'],f['hides']); counts[key]=counts.get(key,0)+1
                count_by_cycle.extend(counts.values())
            motion[direction]=dict(callbackGapMs=stats(gaps),displayGapMs=stats(timestamp_gaps),
                requestedIntervalMs=stats(intervals),gapsOver1_5=bad,framesPerAnimation=stats(count_by_cycle))
        answer['motion'][page]=motion
    for key in ('shown','hidden'):
        segments=[(r,r['idle'][key]) for r in runs if key in r.get('idle',{})]
        if not segments: continue
        answer['idle'][key]=dict(sensors=sensors([(r['pid'],s['samples']) for r,s in segments]),
            observerBefore=[s['probe']['before'] for _,s in segments],
            observerAfter=[s['probe']['after'] for _,s in segments],
            fieldsUnchanged=[s['probe']['fieldsBefore']==s['probe']['fieldsAfter'] for _,s in segments],
            pageBlur=[s['endState']['reveal'].get('pageBlur','not exposed') for _,s in segments])
    changes=[c for r in runs for c in r.get('activation',{}).get('probe',{}).get('changes',[])]
    switches=[c for r in runs for c in r.get('activation',{}).get('switches',[])]
    callback_gaps=[]; lower_bounds=[]; widths=[]; signed_lower_bounds=[]; full_widths=[]; unbounded=0
    for run in runs:
        if not run.get('activation'): continue
        frames=run['activation']['probe']['frames']
        callback_gaps.extend((b['time']-a['time'])*1000 for a,b in zip(frames,frames[1:]))
        by_time={f['time']:i for i,f in enumerate(frames)}
        for change in run['activation']['probe']['changes']:
            if 'observed' not in change: continue
            index=by_time[change['observed']]
            previous=frames[index-1] if index else None
            lower=max(0,previous['time']-change['time'])*1000 if previous and previous['fields']==change['before'] else 0
            upper=(change['observed']-change['time'])*1000
            lower_bounds.append(lower); widths.append(upper-lower)
            if previous and previous['fields']==change['before']:
                signed=(previous['time']-change['time'])*1000
                signed_lower_bounds.append(signed); full_widths.append(upper-signed)
            else: unbounded+=1
    answer['activation']=dict(keyToObservedRebuildMs=stats([(c['observed']-c['time'])*1000 for c in changes if 'observed' in c]),
        callbackGapMs=stats(callback_gaps),fieldCommitLowerBoundMs=stats(lower_bounds),fieldCommitObservationWidthMs=stats(widths),
        fieldRebuildSignedLowerBoundMs=stats(signed_lower_bounds),fieldRebuildFullObservationWidthMs=stats(full_widths),unboundedRebuildIntervals=unbounded,
        missingObservations=sum('observed' not in c for c in changes),
        focusRoundTripMs=stats([c['roundTripMs'] for c in switches]),
        settledSnapshotMs=stats([c['settledSnapshotMs'] for c in switches if 'settledSnapshotMs' in c]),load=loads([c['start'] for c in switches]))
    bench=[]
    for r in runs:
        m=re.search(r'scroll (\d+) steps.*median ([\d.]+) ms, p95 ([\d.]+) ms, max ([\d.]+) ms',r.get('bench',{}).get('stdout',''))
        if m: bench.append(dict(label=r['label'],steps=int(m[1]),medianMs=float(m[2]),p95Ms=float(m[3]),maxMs=float(m[4]),load=r['benchStart']['load']))
    answer['scroll']=dict(runs=bench,medianOfMediansMs=stats([v['medianMs'] for v in bench]),
                         p95AcrossRunsMs=stats([v['p95Ms'] for v in bench]),load=loads(bench))
    return answer


def main():
    p=argparse.ArgumentParser(); p.add_argument('root'); a=p.parse_args(); root=Path(a.root)
    # macOS Python 3.9 monotonic epochs can differ across processes. These runs
    # are sequential; receipt completion mtimes preserve their actual order.
    paths=sorted(root.glob('runs/*/receipt.json'),key=lambda p:p.stat().st_mtime)
    runs=[json.loads(p.read_text()) for p in paths]
    good=[r for r in runs if r.get('status')=='COMPLETE' and
          (r.get('kind')=='scroll' or r.get('quit',{}).get('ok')) and r.get('bench',{}).get('code')==0]
    result={'order':[r['label'] for r in good],
            'excluded':[{k:r.get(k) for k in ('label','status','error','interruptions')} for r in runs if r not in good]}
    for build in ('main','branch'):
        result[build]=summarize([r for r in good if r['label'].startswith(build+'-')])
    (root/'summary.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))


if __name__=='__main__': main()
