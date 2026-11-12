#!/usr/bin/env python3
"""LEAD 05:00 facts from saved receipts; no new measurements or attribution."""
import json
from pathlib import Path
import statistics

from run import ROOT, PLANS, atomic, now, sha


def source_dir(sample, prefix):
    candidates=list((ROOT/'.re/perf').glob(f'{prefix}*-samples/{sample["round_index"]:02}-open-core'))
    matches=[p for p in candidates if json.loads((p/'sample.json').read_text())['date']==sample['date']]
    if len(matches)!=1:raise RuntimeError('Raw receipt missing or ambiguous')
    return matches[0]


def main():
    facts={'date':now(),'authorization':'LEAD 05:00','cpu':{},'memory':{},
           'limits':['Historical helpers were stored as generic helper: GPU and utility are not distinguishable.',
                     'No key-window or tab-identity snapshot was stored at the CPU-window boundary.']}
    main=json.loads((ROOT/'.re/perf/main-delta-2.json').read_text())
    pinned=json.loads((ROOT/'.re/perf/aw2726dm-accepted-window-v3.json').read_text())
    def samples(run):return [s for s in run['samples'] if s.get('valid') and s['browser']=='open' and s['task']=='core']
    for scenario in ('static','10tabs'):
        key=f'cpu.idle_{scenario}_pct'
        rows=[]
        for s in samples(main):
            p=source_dir(s,'main-delta-')/f'cpu-{scenario}.json';raw=json.loads(p.read_text())
            grouped={kind:sum(v['cpu_pct'] for v in raw['processes'] if v['kind']==kind) for kind in ('browser','renderer','helper')}
            grouped['unassigned_reaped_or_churn']=raw['cpu_pct']-sum(grouped.values())
            elapsed=raw['after']['monotonic_seconds']-raw['before']['monotonic_seconds']
            reaped=[]
            for proc in raw['after']['processes']:
                before=next((v for v in raw['before']['processes'] if (v['pid'],v['birth_ticks'])==(proc['pid'],proc['birth_ticks'])),None)
                if before:
                    reaped.append({'pid':proc['pid'],'kind':proc['kind'],
                        'reaped_cpu_pct':100*(proc['reaped_cpu_seconds']-before['reaped_cpu_seconds'])/elapsed})
            grouped['browser_reaped_child_counters']=sum(v['reaped_cpu_pct'] for v in reaped if v['kind']=='browser')
            launch=json.loads((p.parent/'launch.json').read_text())
            rows.append({'index':s['round_index'],'date':s['date'],'receipt':str(p.relative_to(ROOT)),
                         'sha256':sha(p),'total_pct':raw['cpu_pct'],'by_kind_pct':grouped,
                         'processes':raw['processes'],'reaped_child_counter_changes':reaped,'process_churn':raw['process_churn'],
                         'cpu_start_after_birth_s':raw['before']['wall_seconds']-launch['birth_wall_seconds'],
                         'elapsed_s':raw['elapsed_s'],'launch_application_active':launch['application_active'],
                         'loaded_tabs':s['mem_1tab_details' if scenario=='static' else 'mem_10tab_details']})
        facts['cpu'][scenario]={'samples':rows,'median_total_pct':statistics.median(r['total_pct'] for r in rows),
                                'median_by_kind_pct':{k:statistics.median(r['by_kind_pct'][k] for r in rows) for k in rows[0]['by_kind_pct']},
                                'start_after_birth_s_range':[min(r['cpu_start_after_birth_s'] for r in rows),max(r['cpu_start_after_birth_s'] for r in rows)]}
    for label,run,prefix in [('pinned',pinned,'aw2726dm-'),('main',main,'main-delta-')]:
        rows=[]
        for s in samples(run):
            p=source_dir(s,prefix)/'mem-idle_1tab_mib.json';raw=json.loads(p.read_text())
            processes=[{'kind':v['kind'],'pid':v['pid'],'footprint_mib':v['footprint_bytes']/2**20} for v in raw['processes']]
            rows.append({'index':s['round_index'],'date':s['date'],'receipt':str(p.relative_to(ROOT)),
                         'sha256':sha(p),'total_mib':sum(v['footprint_mib'] for v in processes),'processes':processes})
        ordered=sorted(rows,key=lambda r:r['total_mib']);n=len(ordered);middle=ordered[(n-1)//2:n//2+1]
        def components(row):
            values={}
            for kind in ('browser','renderer','helper'):
                for i,v in enumerate(sorted((p['footprint_mib'] for p in row['processes'] if p['kind']==kind),reverse=True)):
                    values[kind if kind=='browser' else f'{kind} {i+1}']=v
            return values
        keys=set().union(*(components(r) for r in middle))
        facts['memory'][label]={'commit':run['provenance']['commit'],'app_main_sha256':run['provenance']['app_main_sha256'],
            'samples':rows,'median_total_mib':statistics.median(r['total_mib'] for r in rows),
            'median_total_representative_indices':[r['index'] for r in middle],
            'additive_representative_split_mib':{k:statistics.mean(components(r).get(k,0) for r in middle) for k in sorted(keys)}}
    facts['static_scene']={'page':'local static.html, Repeatable local page; fixed text and generated image; no animation or recurring script',
        'visible_page_receipt':'initial_workload_page.visibility=visible; viewport 1682x1030; one owned window 1920x1050',
        'welcome':'Static fixture is the selected visible page, not Welcome or a new-tab surface. Identities of other loaded/restored tabs were not saved.',
        'key_window':'Launch receipt says application_active=true. Key-window status was not sampled at the 120-second boundary.',
        'sequence':'Plain launch; restored startup reporter; navigate static fixture; match viewport; wait 60 s; memory snapshot; start 120 s CPU window.',
        'loaded':'1 tab means one newly visited workload page, not a single loaded host: all six main samples record 2 loaded tabs, 0 loading, 3 renderer processes.'}
    atomic(ROOT/'.re/perf/main-delta-facts.json',facts)
    lines=['<!-- main-delta-facts -->','### Idle scenario and process facts','',facts['static_scene']['page']+'. '+facts['static_scene']['welcome'],
           '',facts['static_scene']['visible_page_receipt']+'. '+facts['static_scene']['key_window'],
           '',facts['static_scene']['sequence']+' '+facts['static_scene']['loaded'],
           '',f"The static CPU window begins {facts['cpu']['static']['start_after_birth_s_range'][0]:.2f}–{facts['cpu']['static']['start_after_birth_s_range'][1]:.2f} s after process birth. The 10-tab scenario follows hide/unhide, nine further local static pages and a separate 60 s settle; native sleep policy remains enabled.",
           '', '| Main CPU, % of one core | Static | 10 tabs |','|---|---:|---:|']
    for kind in ('browser','renderer','helper','browser_reaped_child_counters'):
        lines.append('| '+kind+' | '+' | '.join(f"{facts['cpu'][s]['median_by_kind_pct'][kind]:.4f}" for s in ('static','10tabs'))+' |')
    lines.extend(['| Scored tree median | '+' | '.join(f"{facts['cpu'][s]['median_total_pct']:.4f}" for s in ('static','10tabs'))+' |',
        '', 'Browser, renderer and helper cells use live self counters. The extra row is the change in child-lifetime CPU counters under the browser process; the recorded scorer includes it in the tree total. All six static intervals have the same live PID set at both boundaries. These facts do not identify the departed processes. CPU cells are separate medians across six sessions and need not add to the tree median. The JSON includes every per-process interval and residual. Historical generic helper counters combine GPU/utility roles; a separate GPU or utility number cannot be recovered from these receipts.',
        '', '| Physical footprint at the median total, MiB | Pinned | Main |','|---|---:|---:|'])
    keys=sorted(set().union(*(facts['memory'][b]['additive_representative_split_mib'] for b in ('pinned','main'))))
    for key in keys:
        lines.append('| '+key+' | '+' | '.join(f"{facts['memory'][b]['additive_representative_split_mib'].get(key,0):.3f}" for b in ('pinned','main'))+' |')
    lines.extend(['| Total | '+' | '.join(f"{facts['memory'][b]['median_total_mib']:.3f}" for b in ('pinned','main'))+' |',
        '', 'Pinned uses its middle-total session (index 3). Main averages its two middle-total sessions (indices 8 and 4). Renderer/helper entries are ranked by footprint within each session; they are not claimed to be the same process across sessions. The split adds to the corresponding scored total. GPU/utility identities were not stored; helpers 1–3 remain explicitly unidentified.',
        '', 'Source: `.re/perf/main-delta-facts.json`, with exact raw receipt paths/hashes and full per-process numbers. These are observations, not an explanation of the changes.',''])
    report=PLANS/'P-report-1.md';text=report.read_text().split('<!-- main-delta-facts -->')[0].rstrip()+'\n\n'+'\n'.join(lines);report.write_text(text)
    score=json.loads((PLANS/'P-scorecard-1.json').read_text());score['main_delta']['scenario_process_facts']=facts;atomic(PLANS/'P-scorecard-1.json',score)
    print(json.dumps({'static':facts['cpu']['static']['median_by_kind_pct'],'10tabs':facts['cpu']['10tabs']['median_by_kind_pct'],'static_start_after_birth_s':facts['cpu']['static']['start_after_birth_s_range']}))


if __name__=='__main__':main()
