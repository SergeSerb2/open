#!/usr/bin/env python3
"""Plain launches and paired real-app sessions with replayable imported states.

Arc creates new main tabs for external URLs and saves its sidebar on quit.
Each Arc/Open pair therefore starts from the same real import. Private Open
snapshots preserve every starting state for later Open-only hill-climb runs.
No desktop input or scripting Apple events are used.
"""
import argparse
import contextlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

from benchmarks import BenchmarkCollector
from run import (ARC, ARC_DATA, BASE, OPEN, PLANS, ROOT, Browser, arc_counts,
                 atomic, command, cpu_window, guard, mem_snapshot, metric,
                 now, prepare_real, probe, provenance, sha, version, disk_mib)
from run import existing_pids, arc_core
from score import benchmark_target, metric_rows, required_n
from server import CollectorClient

MAIN_DELTA = {'cpu.idle_static_pct', 'cpu.idle_10tabs_pct', 'cpu.idle_hidden_pct',
              'energy.idle_impact', 'wakeups.idle_per_s', 'launch.first_paint_ms',
              'launch.window_ms', 'mem.idle_1tab_mib'}

BLOCKED={
 'S-empty.arc':'M5 native-state isolation is not authorized; later M1 run',
 'mem.after_close_mib':'Phase 2: normal Arc tabs refuse script self-close',
 'mem.pressure_30tabs_swap':'Global swap is recorded; other agents prevent causal attribution',
 'ui.*':'Phase 2 requires separate permission and display acceptance',
 'fps.*':'Phase 2 requires separate permission and display acceptance',
 'resume.*':'Phase 2 requires separate permission and display acceptance',
}

def checkpoint(b):
    guard(b.baseline)
    return {'date':now(),'load':list(os.getloadavg())}

def activate(b,url):
    if getattr(b.collector,'route_suffix','') and b.collector.route_suffix not in url:
        url+=('&' if '?' in url else '?')+b.collector.route_suffix
    if b.name=='arc':command(['/usr/bin/open','-a',b.bundle,url])
    else:
        tabs=b.call('tabs')
        found=next((t for t in tabs if t.get('url')==url),None)
        if found:b.call('select',tab=found['id'])
        else:b.call('open',url=url)
    guard(b.baseline)

def visit(b,url,token):
    activate(b,url)
    row=b.collector.wait(token,after_wall_ms=b.launch['birth_wall_seconds']*1000,visible=True)
    if row.get('visibility')!='visible':raise RuntimeError('Workload did not report visible')
    return row

def startup_url(c):return c.url+'/report.html?run=startup'+('&'+c.route_suffix if getattr(c,'route_suffix','') else '')
def static_url(c,n):return startup_url(c) if n==0 else c.url+f'/static.html?run={c.round_token}-static-{n:02}'

def tree_cpu(b,out,label):
    # top uses the exact same initial process tree as the rusage window.
    ids=[p['pid'] for p in b.snapshot()['processes']]
    path=out/('power-'+label+'.txt')
    args=['/usr/bin/top','-l','121','-s','1','-stats','pid,power']
    for pid in ids:args.extend(['-pid',str(pid)])
    with path.open('w') as f:
        job=subprocess.Popen(args,stdout=f,stderr=subprocess.STDOUT)
        try:row=cpu_window(b,120)
        finally:
            # Only this owned top process is stopped. Browser children use
            # normal application quit and process-identity receipts.
            if job.poll() is None:job.terminate()
            job.wait(timeout=10)
    groups=[];current={}
    for line in path.read_text().splitlines():
        if line.startswith('Processes:'):
            if current:groups.append(current)
            current={}
        match=re.fullmatch(r'\s*(\d+)\s+([\d.]+)\s*',line)
        if match:current[int(match[1])]=float(match[2])
    if current:groups.append(current)
    valid=[sum(g.values()) for g in groups[1:] if set(g)==set(ids)]
    row['top_power']={'unit':'top POWER, summed tree','n':len(valid),
                      'mean':statistics.mean(valid) if valid else None,
                      'complete_tree':len(valid)>=100}
    atomic(out/('cpu-'+label+'.json'),row)
    return row

def import_view(out):
    """Own read-only source view; only order the global container first.

    Arc serializes a map as alternating key/value elements. Open's current
    importer chooses element 1. Reordering this map changes no source data.
    Every other input is a symlink to the read-only original.
    """
    view=(out/'arc-import-view').resolve();view.mkdir()
    for p in ARC_DATA.iterdir():
        if p.name!='StorableSidebar.json':(view/p.name).symlink_to(p)
    raw=json.loads((ARC_DATA/'StorableSidebar.json').read_text())
    values=raw['sidebar']['containers'];pairs=[values[i:i+2] for i in range(0,len(values),2)]
    pairs.sort(key=lambda pair:0 if isinstance(pair[0],dict) and 'global' in pair[0] else 1)
    raw['sidebar']['containers']=[v for pair in pairs for v in pair]
    atomic(view/'StorableSidebar.json',raw)
    return view

def worker(config_path):
    if os.environ.get('OPEN_PERF_LOCKED')!='1':raise RuntimeError('Missing quiet/screen locks')
    cfg=json.loads(Path(config_path).read_text());out=Path(cfg['out']);out.mkdir(parents=True,exist_ok=True)
    row={'date':now(),'browser':cfg['browser'],'state':cfg['state'],'task':cfg['task'],
         'round_index':cfg.get('round_index',0),
         'load_before':list(os.getloadavg()),'metrics':{},'blocked':dict(BLOCKED),'valid':False,
         'arc_version_before':version(False),'arc_core_before':arc_core(),'display_before':probe('metadata')}
    row['harness_sha256']={p.name:sha(p) for p in [Path(__file__),Path(__file__).with_name('run.py'),Path(__file__).with_name('server.py'),ROOT/'.re/perf/bin/probe']}
    atomic(out/'sample.json',row)
    if os.getloadavg()[0]>cfg['max_load']:row['gate_refused']=True;atomic(out/'sample.json',row);return 75
    if Path('/tmp/open-onscreen-priority').exists() or (ROOT/'.re/hold-on-screen').exists():
        row['gate_refused']=True;atomic(out/'sample.json',row);return 75
    if existing_pids(ARC) or existing_pids(OPEN):
        row['gate_refused']=True;row['gate_reason']='Another browser process is running; no process adopted or stopped'
        atomic(out/'sample.json',row);return 75
    if row['arc_version_before']!=cfg['arc_version']:raise RuntimeError('Arc build changed before session')
    if row['arc_core_before']!=cfg['arc_core']:raise RuntimeError('ArcCore changed before session')
    if cfg.get('app_main_sha256'):
        row['open_app_sha256_before']=sha(OPEN/'Contents/MacOS/Open')
        row['open_engine_sha256_before']=sha(OPEN/'Contents/Frameworks/OpenEngine.framework/Versions/A/OpenEngine')
        if (row['open_app_sha256_before']!=cfg['app_main_sha256'] or
                row['open_engine_sha256_before']!=cfg['engine_sha256']):
            raise RuntimeError('Frozen Open artifact changed before session')
    c=CollectorClient(cfg['collector']);c.route_suffix=cfg.get('route_suffix','')
    c.url=cfg.get('navigation_origin',c.url)
    c.round_token=cfg.get('round_token','prepare')
    b=Browser(cfg['browser'],Path(cfg['root']),out,c,'fixed')
    metrics=row['metrics'];row['checkpoints']=[]
    try:
        if cfg.get('refresh_import') and cfg['browser']=='arc':
            # Capture agent C can change Arc between lock holds. Refresh the
            # real import inside this Arc hold, immediately before its launch.
            # Preserve Open's exact starting state before Arc adds any tabs.
            imported_root=Path(cfg['root'])
            shutil.rmtree(imported_root);imported_root.mkdir()
            nested={**cfg,'browser':'open','task':'import','refresh_import':False,
                    'out':str(out/'paired-import')}
            nested_path=out/'paired-import-config.json';atomic(nested_path,nested)
            if worker(nested_path):raise RuntimeError('Paired import failed before Arc launch')
            imported=json.loads((out/'paired-import/sample.json').read_text())
            if not imported.get('valid'):raise RuntimeError('Paired import did not pass its load/display gates')
            snapshot=Path(cfg['pair_snapshot'])
            shutil.copytree(imported_root,snapshot,ignore=shutil.ignore_patterns('automation.sock'))
            row['pair_setup']={'arc_counts':arc_counts(),'import_counts':imported['import_counts'],
                               'snapshot_browser_sha256':sha(snapshot/'State/browser.json')}
        if cfg['task'].startswith('bench-'):
            starting_state=Path(cfg['root'])/'State/browser.json'
            row['benchmark_token_prefix']=sha(starting_state)[:16] if starting_state.is_file() else 'empty'
        if cfg['task']=='import':
            containers=json.loads((ARC_DATA/'StorableSidebar.json').read_text())['sidebar']['containers']
            directory=ARC_DATA if isinstance(containers[0],dict) and 'global' in containers[0] else import_view(out)
            counts=prepare_real(b,directory,normalize=True);row['import_counts']=counts
            # Focus the imported synthetic startup tab wherever it resides.
            found=False
            for space in b.call('spaces'):
                b.call('space',space=space['id'])
                for tab in b.call('tabs'):
                    if tab.get('url')==startup_url(c):b.call('select',tab=tab['id']);found=True;break
                if found:break
            if not found:raise RuntimeError('Real import did not preserve synthetic startup tab')
            if cfg.get('frame'):b.call('window-frame',frame=cfg['frame'],unconstrained=True)
        else:
            b.external_startup=cfg['task']=='paint'
            paint_token=c.round_token+'-startup'
            paint_url=startup_url(c).replace('run=startup','run='+paint_token)
            launch=b.start(paint_url if b.external_startup else None)
            row['launch_route']='LaunchServices plain application launch; restored selected local tab'
            row['window_bounds']=launch['windows']
            if cfg['browser']=='open' and cfg.get('frame'):
                b.call('window-frame',frame=cfg['frame'],unconstrained=True)
            if cfg['task'] in ('prime','prime-empty'):
                row['counts_before']=arc_counts()
                visit(b,startup_url(c),'startup');time.sleep(2)
                row['counts_after']=arc_counts()
                row['window_bounds']=[w for w in probe('windows') if w['pid']==b.pid]
            elif cfg['task']=='window':
                metric(metrics,'launch.window_ms',launch['window_ms'],'ms')
                row['launch_detector_version']=launch.get('detector_version',1)
                row['window_timeline']=launch.get('window_timeline',[])
                row['window_before_completion']=launch.get('window_before_completion',False)
                row['completion_after_birth_ms']=launch.get('completion_after_birth_ms')
                # Latency is already captured. Let the restored window settle
                # before normal quit so setup state is not cut off at creation.
                time.sleep(2)
                b.snapshot()
                try:row['restored_startup_page']=c.wait('startup',timeout=1,after_wall_ms=launch['birth_wall_seconds']*1000)
                except RuntimeError:row['restored_startup_page']=None
                row['counts_end']=arc_counts()
            else:
                metric(metrics,'launch.window_ms',launch['window_ms'],'ms')
                if cfg['task']=='paint':
                    page=c.wait(paint_token,after_wall_ms=launch['birth_wall_seconds']*1000,visible=True)
                    row['startup_page']=page
                    row['startup_windows']=[w for w in probe('windows') if w['pid']==b.pid]
                    if page.get('visibility')!='visible':raise RuntimeError('Startup page not visible')
                    if page.get('fcp_ms') is not None:metric(metrics,'launch.first_paint_ms',page['time_origin_ms']+page['fcp_ms']-launch['birth_wall_seconds']*1000,'ms')
                    metrics.pop('launch.window_ms')
                    row['launch_route']='LaunchServices URL startup intent in both browsers, matching existing main-Space route'
                else:
                    try:
                        row['restored_startup_page']=c.wait('startup',timeout=1,after_wall_ms=launch['birth_wall_seconds']*1000)
                    except RuntimeError:row['restored_startup_page']=None
                    initial=c.round_token+'-initial'
                    page=visit(b,c.url+'/static.html?run='+initial,initial)
                    row['initial_workload_page']=page
                    row['owned_workload_windows']=[w for w in probe('windows') if w['pid']==b.pid]
                    target=cfg.get('target_viewport')
                    if b.name=='open' and target:
                        bounds=max(row['owned_workload_windows'],key=lambda w:w['bounds'][2]*w['bounds'][3])['bounds']
                        screen=row['display_before']['screens'][0]
                        frame=[bounds[0],screen['height']-bounds[1]-bounds[3],
                               bounds[2]+target[0]-page['viewport_width'],bounds[3]+target[1]-page['viewport_height']]
                        b.call('window-frame',frame=frame,unconstrained=True)
                        selected=next(t['id'] for t in b.call('tabs') if t.get('selected'))
                        actual=json.loads(b.call('eval',tab=selected,js='JSON.stringify([innerWidth,innerHeight])'))
                        row['matched_viewport']={'target':target,'actual':actual,'frame':frame}
                        if actual!=target:raise RuntimeError('Open viewport did not match Arc workload')
                row['quit_gap_seconds']=time.time()-cfg.get('last_quit_wall',time.time())
                if cfg['task']=='core':
                    time.sleep(60);row['checkpoints'].append(checkpoint(b))
                    mem1,detail=mem_snapshot(b,metrics,'mem.idle_1tab_mib');row['mem_1tab_details']=detail
                    metric(metrics,'procs.idle_count',detail['process_count'],'count')
                    cpu=tree_cpu(b,out,'static');row['checkpoints'].append(checkpoint(b))
                    if cpu['complete']:
                        metric(metrics,'cpu.idle_static_pct',cpu['cpu_pct'],'% of one core')
                        metric(metrics,'wakeups.idle_per_s',cpu['wakeups_per_s'],'wakeups/s')
                    if cpu['top_power']['complete_tree']:metric(metrics,'energy.idle_impact',cpu['top_power']['mean'],'top POWER summed tree')
                    hide=probe('hide',b.pid);atomic(out/'hide.json',hide)
                    if not hide['hidden']:raise RuntimeError('Hide did not produce hidden state')
                    time.sleep(60)
                    if any(w['pid']==b.pid for w in probe('windows')):raise RuntimeError('Owned window still visible after hide')
                    cpu=cpu_window(b,120);atomic(out/'cpu-hidden.json',cpu)
                    if cpu['complete']:metric(metrics,'cpu.idle_hidden_pct',cpu['cpu_pct'],'% of one core')
                    show=probe('unhide',b.pid);atomic(out/'unhide.json',show)
                    if show['hidden']:raise RuntimeError('Unhide did not restore visible state')
                    memory=[(1,mem1)]
                    for count in ((10,) if cfg.get('main_delta') else (10,30)):
                        for n in range(1 if count==10 else 10,count):visit(b,static_url(c,n),f'{c.round_token}-static-{n:02}')
                        swap_before=command(['/usr/sbin/sysctl','-n','vm.swapusage']).strip()
                        time.sleep(60);row['checkpoints'].append(checkpoint(b))
                        value,detail=mem_snapshot(b,metrics,f'mem.{count}tabs_mib')
                        row[f'mem_{count}tab_details']=detail;memory.append((count,value))
                        if count==10:
                            cpu=cpu_window(b,120);atomic(out/'cpu-10tabs.json',cpu)
                            if cpu['complete']:metric(metrics,'cpu.idle_10tabs_pct',cpu['cpu_pct'],'% of one core')
                        else:row['swap_30tabs']={'before':swap_before,'after':command(['/usr/sbin/sysctl','-n','vm.swapusage']).strip(),'scope':'whole machine, information only'}
                    xm=statistics.mean(x for x,y in memory);ym=statistics.mean(y for x,y in memory)
                    slope=sum((x-xm)*(y-ym) for x,y in memory)/sum((x-xm)**2 for x,y in memory)
                    metric(metrics,'mem.per_tab_mib',slope,'MiB/visited tab')
                    animated=c.round_token+'-animated'
                    if not cfg.get('main_delta'):
                        visit(b,c.url+'/animated.html?run='+animated,animated);time.sleep(60)
                        cpu=cpu_window(b,120);atomic(out/'cpu-animated.json',cpu)
                        if cpu['complete']:metric(metrics,'cpu.animated_pct',cpu['cpu_pct'],'% of one core')
                        row['animated_workload']='One visible CSS animation plus thirty previously visited static tabs; normal sleep policy retained'
                if cfg['task'] in ('fast','core') and not cfg.get('main_delta'):
                    for name,key in [('static','load.static_ms'),('heavy-dom','load.heavy_dom_ms')]:
                        for cache in ('cold','warm'):
                            token=f'{c.round_token}-{name}-{cache}'
                            page=visit(b,c.url+f'/{name}-{cache}.html?run={token}&cache={cache}&assetkey=load-{c.round_token}-{name}',token)
                            if cache=='cold' and not page.get('resource_network_count'):raise RuntimeError('Cold subresource network load not observed')
                            if cache=='warm' and not page.get('resource_cache_count'):raise RuntimeError('Warm subresource cache not observed')
                            metric(metrics,key+'.'+cache,page['load_ms'],'ms')
                            for field,suffix in [('fcp_ms','fcp'),('lcp_ms','lcp')]:
                                if page.get(field) is not None:metric(metrics,key.replace('_ms','_'+suffix+'_ms')+'.'+cache,page[field],'ms')
                    metric(metrics,'disk.app_mib',disk_mib(b.bundle),'MiB allocated')
                    metric(metrics,'disk.main_binary_mib',(b.bundle/'Contents/MacOS'/('Arc' if b.name=='arc' else 'Open')).stat().st_size/2**20,'MiB logical')
                    if cfg['state']=='S-empty':metric(metrics,'disk.fresh_profile_mib',disk_mib(b.root),'MiB allocated')
                if cfg['task'].startswith('bench-'):
                    name=cfg['task'][6:];token=row['benchmark_token_prefix']+'-'+c.round_token+'-benchmark-'+name
                    before=time.time()*1000
                    activate(b,c.url+f'/bench/{name}/{token}/index.html')
                    deadline=time.monotonic()+1800
                    while time.monotonic()<deadline:
                        guard(b.baseline);os.kill(b.pid,0)
                        try:result=c.wait(token,event='benchmark',timeout=1,after_wall_ms=before);break
                        except RuntimeError:continue
                    else:raise RuntimeError(name+' did not finish within 1800 seconds')
                    score=result.get('score')
                    if name=='motionmark':
                        stage=c.wait(token,event='benchmark-stage',timeout=1,after_wall_ms=before)
                        row['benchmark_start_stage']=stage.get('error')
                    row['benchmark_attempt']=name
                    if not isinstance(score,(float,int)) or not math.isfinite(score) or score<=0:
                        row['benchmark_failure']={'suite':name,'score':score,'reason':'Official suite reported an invalid result'}
                        row['blocked']['bench.'+name]='Real suite failed; no numerical score'
                    else:metric(metrics,'bench.'+name,score,'score','higher')
                # Add the same next-launch startup tab in both browsers. Arc
                # creates a new main tab even for an identical external URL.
                if b.name=='open':b.call('open',url=startup_url(c))
                else:activate(b,startup_url(c))
                time.sleep(2)
                row['counts_end']=arc_counts()
                if cfg['task']=='core':
                    row['optional_relaunch_probe_enabled']=bool(cfg.get('optional_relaunch_probe', False))
                if cfg['task']=='core' and cfg.get('optional_relaunch_probe', False):
                    atomic(out/'launch-cold.json',launch)
                    b.stop();time.sleep(1)
                    warm=b.start();atomic(out/'launch-warm.json',warm)
                    row['launch_gap_comparison']={'quit_gap_seconds':row['quit_gap_seconds'],
                        'cold_window_ms':launch['window_ms'],'immediate_window_ms':warm['window_ms'],
                        'first_after_10min':row['quit_gap_seconds']>=600,
                        'label':'first after >=10 min quit vs immediate relaunch; file caches not purged'}
                    if row['quit_gap_seconds']>=600:
                        metric(metrics,'launch.warm_vs_cold',launch['window_ms']/warm['window_ms'],'cold/warm window ratio')
        if cfg.get('main_delta'):
            row['main_delta'] = True
            row['metrics'] = {k:v for k,v in row['metrics'].items() if k in MAIN_DELTA}
            if cfg['task']=='core':row['metrics'].pop('launch.window_ms',None)
        guard(b.baseline)
    except BaseException as exc:
        row['error']=str(exc) or type(exc).__name__
    finally:
        try:b.stop();row['cleanup']=True
        except Exception as exc:row['cleanup']=False;row['cleanup_error']=str(exc)
        row['quit_wall_seconds']=time.time()
        row['arc_counts_after_quit']=arc_counts()
        if cfg['task']=='prime' and cfg['browser']=='arc':
            saved=json.loads((ARC_DATA/'StorableSidebar.json').read_text())['sidebar']['containers']
            holder=next(saved[i+1] for i in range(0,len(saved)-1,2) if 'global' in saved[i])
            if c.url not in json.dumps(holder):row['error']='Synthetic startup URL did not reach the global sidebar'
        row['arc_version_after']=version(False);row['arc_core_after']=arc_core();row['display_after']=probe('metadata')
        row['load_after']=list(os.getloadavg())
        for path in sorted(out.glob('cpu-*.json')):
            interval=json.loads(path.read_text())
            for endpoint in ('before','after'):
                if 'load_'+endpoint in interval:
                    row['checkpoints'].append({'measurement':path.stem+'-'+endpoint,
                                               'load':interval['load_'+endpoint]})
        row['valid']=not row.get('error') and row.get('cleanup') and max(row['load_before'][0],row['load_after'][0],*[v['load'][0] for v in row['checkpoints']])<=cfg['max_load']
        if row.get('metrics',{}).get('launch.window_ms') and b.launch.get('average_poll_hz',0)<250:
            row['valid']=False;row['detector_invalid']='Actual average window polling was below 250 Hz'
        if row['arc_version_after']!=row['arc_version_before']:row['valid']=False;row['error']='Arc changed build during session'
        if row['arc_core_after']!=row['arc_core_before']:row['valid']=False;row['error']='ArcCore changed during session'
        if row['display_after']!=row['display_before']:row['valid']=False;row['error']='Display changed during session'
        if cfg.get('app_main_sha256'):
            row['open_app_sha256_after']=sha(OPEN/'Contents/MacOS/Open')
            row['open_engine_sha256_after']=sha(OPEN/'Contents/Frameworks/OpenEngine.framework/Versions/A/OpenEngine')
            if (row['open_app_sha256_after']!=cfg['app_main_sha256'] or
                    row['open_engine_sha256_after']!=cfg['engine_sha256']):
                row['valid']=False;row['error']='Frozen Open artifact changed during session'
        atomic(out/'sample.json',row)
    print(json.dumps({k:row.get(k) for k in ('date','browser','task','valid','error','load_before','load_after','cleanup')}),flush=True)
    return 1 if row.get('error') or not row.get('cleanup') else 0

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('browser',choices=['paired','arc','open'],nargs='?',default='paired')
    p.add_argument('--out',type=Path);p.add_argument('--worker',type=Path)
    p.add_argument('--state',choices=['S-real','S-empty'],default='S-real')
    p.add_argument('--samples',type=int,default=7);p.add_argument('--max-load',type=float,default=8)
    p.add_argument('--tasks',help='Comma-separated tasks; Open-only defaults to frozen replay tasks')
    p.add_argument('--main-delta',action='store_true',help='LEAD 01:35: only the eight Open-only rows, N5; use frozen private starts')
    p.add_argument('--prepare',action='store_true');p.add_argument('--port',type=int,default=18793)
    p.add_argument('--resume-from',type=Path,help='Preserve an earlier raw receipt and append missing rounds into a new output')
    p.add_argument('--reference',type=Path,default=ROOT/'docs/perf/arc-reference-m5.json')
    a=p.parse_args()
    if a.worker:return worker(a.worker)
    if not a.out:p.error('--out is required')
    if a.out.exists():p.error('Output exists; preserve every attempt with a new path')
    if not 0<a.max_load<=10:p.error('Load ceiling must be in (0,10]')
    if a.main_delta and (a.browser!='open' or a.samples!=5):p.error('Main delta requires Open-only N5')
    if a.samples<7 and not a.prepare and not a.main_delta:p.error('At least seven samples required')
    if a.state=='S-empty' and a.browser!='open':p.error('Arc S-empty is blocked on M5')
    if a.browser=='open' and a.state=='S-real' and not a.prepare and not a.reference.is_file():
        p.error('Open-only S-real needs the frozen Arc reference and its private replay manifest')
    if a.browser=='open' and a.state=='S-real' and not a.prepare:
        reference=json.loads(a.reference.read_text())
        actual={'hardware':command(['/usr/sbin/sysctl','-n','hw.model','hw.ncpu','hw.memsize']).strip(),
                'os':command(['/usr/bin/sw_vers']).strip(),'display':probe('metadata')}
        for key,value in actual.items():
            if reference['provenance'][key]!=value:
                p.error('Frozen Arc reference has different '+key+'; no browser launched')
    if a.main_delta and a.tasks is None:a.tasks='paint,window,core'
    if a.tasks is None:
        if a.browser=='open' and a.state=='S-real' and a.reference.exists():
            a.tasks=','.join(json.loads(a.reference.read_text())['provenance']['replay_tasks'])
        else:a.tasks='paint,core,bench-speedometer,bench-jetstream,bench-motionmark'
    a.out.parent.mkdir(parents=True,exist_ok=True);work=a.out.parent/(a.out.stem+'-samples');work.mkdir()
    c=BenchmarkCollector(work/'collector',port=a.port)
    # A stored Air Traffic Control destination takes precedence over the legacy
    # Boolean. Use the existing main-Space contains rule, without changing it.
    # Its private match string is kept only in ignored worker configuration.
    routing=json.loads((ARC_DATA/'StorableLinkRouting.json').read_text())
    route_suffix='';navigation_origin=c.url
    for rule in routing.get('rules',[]):
        if 'space' not in rule.get('destination',{}):continue
        for component in rule.get('sourceComponents',[]):
            match=component.get('componentType',{}).get('urlMatch',{})
            value=match.get('_1')
            if 'contains' in match.get('_0',{}) and isinstance(value,str) and value:
                route_suffix='routing='+quote(value,safe=':/.');break
        if route_suffix:break
    if route_suffix and re.fullmatch(r'[a-zA-Z0-9.-]+',value):
        # Chromium resolves every *.localhost name to loopback. Matching the
        # existing host rule needs no DNS/hosts-file or stored-route change.
        navigation_origin=f'http://{value}.localhost:{a.port}'
    root=Path(tempfile.mkdtemp(prefix='op.',dir='/tmp'))
    root_empty=Path(tempfile.mkdtemp(prefix='op.',dir='/tmp'))
    current_provenance=provenance()
    run={'schema':1,'date':now(),'provenance':current_provenance,'samples':[],'blocked':dict(BLOCKED),'last_quit':{}}
    if a.resume_from:
        run=json.loads(a.resume_from.read_text())
        for key in ('hardware','os','display','arc_version','commit','app_main_sha256','engine_sha256'):
            if run['provenance'][key]!=current_provenance[key]:raise RuntimeError('Resume refused: different '+key)
        run.setdefault('resumes',[]).append({'date':now(),'source':str(a.resume_from),'source_sha256':sha(a.resume_from)})
        run.pop('stop_reason',None);run.pop('end_date',None)
    run['provenance']['max_load1']=a.max_load
    policy={'authorization':'LEAD 23:45', 'core_required_n':a.samples, 'disk_required_n':1,
            'web_initial_n':3, 'web_max_n':5, 'web_spread_threshold':.05,
            'web_spread_statistic':'(max-min)/median of the first three accepted results, separately per browser; either browser above 5% requires five matched pairs',
            'metric_required_n':{}}
    if a.browser=='open' and a.state=='S-real' and a.reference.is_file():
        policy.update(json.loads(a.reference.read_text())['provenance'].get('sampling_policy',{}))
    policy.update(run['provenance'].get('sampling_policy',{}))
    if a.main_delta:
        policy['metric_required_n'] = dict(policy.get('metric_required_n',{}), **{k:5 for k in MAIN_DELTA})
        policy['main_delta_authorization']='LEAD 01:35 item 3'
    run['provenance']['sampling_policy']=policy
    run['provenance']['collector_port']=a.port
    run['provenance']['benchmark_revisions']=c.revisions
    run['provenance']['route']='Plain LaunchServices; restored selected local page; fixed workload URLs'
    cohort=run['provenance']['replay_cohort'] if a.resume_from else 'cohort-'+str(int(time.time()))
    replay=BASE.parent/'cohorts'/cohort;replay.mkdir(parents=True,exist_ok=bool(a.resume_from))
    manifest={'schema':1,'cohort':cohort,'port':a.port,'navigation_origin':navigation_origin,
              'route_suffix':route_suffix,'pairs':[]}
    if a.resume_from:
        manifest=json.loads((replay/'manifest.json').read_text())
        if manifest['port']!=a.port or manifest['navigation_origin']!=navigation_origin or manifest['route_suffix']!=route_suffix:
            raise RuntimeError('Resume refused: private workload routing changed')
    run['provenance']['replay_cohort']=cohort
    frozen_manifest=None
    if a.browser=='open' and a.state=='S-real' and not a.prepare and a.reference.exists():
        reference=json.loads(a.reference.read_text())
        frozen_manifest=json.loads((BASE.parent/'cohorts'/reference['provenance']['replay_cohort']/'manifest.json').read_text())
        if frozen_manifest['port']!=a.port:raise RuntimeError('Replay collector port differs from frozen reference')
        navigation_origin=frozen_manifest['navigation_origin'];route_suffix=frozen_manifest['route_suffix']
        run['provenance']['replay_cohort']=frozen_manifest['cohort']
    atomic(a.out,run)
    def session(name,task,index):
        directory=work/f'{index:02}-{name}-{task}'
        cfg={'browser':name,'task':task,'out':str(directory),'collector':c.url,
             'root':str(root_empty if a.state=='S-empty' else root),'state':a.state,
             'arc_core':run['provenance']['arc_core'],
             'app_main_sha256':run['provenance']['app_main_sha256'],
             'engine_sha256':run['provenance']['engine_sha256'],
             'max_load':a.max_load,'arc_version':run['provenance']['arc_version'],
             'route_suffix':route_suffix,
             'navigation_origin':navigation_origin,
             'round_token':f'{task}-{index:02}','round_index':index,
             'target_viewport':run.get('last_arc_viewport'),
             'main_delta':a.main_delta,
             'refresh_import':name=='arc' and a.state=='S-real' and not a.prepare,
             'pair_snapshot':run.get('pair_snapshot'),
             'frame':run.get('frame'),'last_quit_wall':run['last_quit'].get(name,time.time())}
        path=work/'worker-config.json';atomic(path,cfg);started=time.monotonic()
        while True:
            if time.monotonic()-started>3600:raise RuntimeError('Lock/load wait exceeded one hour')
            if os.getloadavg()[0]>a.max_load or Path('/tmp/open-onscreen-priority').exists() or (ROOT/'.re/hold-on-screen').exists():
                print('WAIT outside locks',list(os.getloadavg()),flush=True);time.sleep(5);continue
            # One session per FIFO ticket. heavy.sh owns the shared quiet
            # lock; taking it again inside that slot would deadlock.
            cmd=['/usr/bin/lockf','-k','-t','30','/tmp/open-onscreen-e2e.lock',sys.executable,str(Path(__file__)),'--worker',str(path)]
            if os.environ.get('OPEN_HEAVY_HELD')!='1':
                cmd.insert(0,str(Path.home()/'Library/Caches/OpenRE/scripts/heavy.sh'))
            result=subprocess.run(cmd,env=dict(os.environ,OPEN_PERF_LOCKED='1',OPEN_HEAVY_EXCLUSIVE='1',OPEN_PERF_ARC_VERSION=json.dumps(run['provenance']['arc_version'])))
            sample_path=directory/'sample.json'
            sample=json.loads(sample_path.read_text()) if sample_path.exists() else None
            if sample and sample.get('gate_reason'):
                run['foreign_browser_block']=sample['gate_reason'];atomic(a.out,run)
                print('FOREIGN_BROWSER_BLOCK: lead pending question required',flush=True)
                raise RuntimeError(sample['gate_reason'])
            if sample and not sample.get('gate_refused'):break
            time.sleep(5)
        run['samples'].append(sample);run['last_quit'][name]=sample.get('quit_wall_seconds',time.time());atomic(a.out,run)
        if probe('metadata')!=run['provenance']['display']:raise RuntimeError('Display changed; restart cohort')
        if sample['arc_version_after']!=run['provenance']['arc_version']:raise RuntimeError('Arc build changed; restart cohort')
        if result.returncode:
            launch_path=directory/'launch.json'
            launch=json.loads(launch_path.read_text()) if launch_path.exists() else {}
            recoverable=(sample.get('error')=='LaunchServices did not produce an owned window' and
                         sample.get('cleanup') and not launch.get('application_terminated',True))
            if recoverable:
                sample['intent_failure']=True
                run.setdefault('intent_failures',[]).append({'browser':name,'task':task,'index':index,'reason':sample['error']})
                atomic(directory/'sample.json',sample);atomic(a.out,run)
            else:raise RuntimeError(sample.get('error','Worker failed'))
        return sample
    try:
        if a.prepare:
            seed=session('arc','prime',0)
            largest=max(seed['window_bounds'],key=lambda w:w['bounds'][2]*w['bounds'][3])['bounds']
            screen=run['provenance']['display']['screens'][0]
            run['frame']=[largest[0],screen['height']-largest[1]-largest[3],largest[2],largest[3]]
            imported=session('open','import',0)
            if BASE.exists():BASE.rename(BASE.with_name('S-real-archive-'+str(int(time.time()))))
            shutil.copytree(root,BASE,ignore=shutil.ignore_patterns('automation.sock'))
            atomic(BASE.parent/'campaign-setup.json',{'port':a.port,'frame':run['frame'],'arc_counts':arc_counts(),'import_counts':imported['import_counts'],'date':now()})
        else:
            setup=json.loads((BASE.parent/'campaign-setup.json').read_text())
            if setup['port']!=a.port:raise RuntimeError('Use the prepared fixed port to preserve restored URLs')
            run['frame']=setup['frame'];run['provenance']['setup_counts']=setup
            shutil.copytree(BASE,root,dirs_exist_ok=True)
            (root/'automation.sock').unlink(missing_ok=True)
            if a.state=='S-empty':
                # A small socket-only setup gives Open its real restored page.
                # It never supplies a URL to the measured plain launch.
                session('open','prime-empty',0)
            order=['arc','open'] if a.browser=='paired' else [a.browser]
            if a.resume_from and a.browser=='paired' and run['samples']:
                pending=run['samples'][-1]
                if (pending['browser']=='arc' and pending.get('pair_setup') and
                        not any(s['browser']=='open' and s['task']==pending['task'] and s['round_index']==pending['round_index'] for s in run['samples'])):
                    pair=next((r for r in manifest['pairs'] if r['task']==pending['task'] and r['index']==pending['round_index']),None)
                    if pair is None:
                        pair={'task':pending['task'],'index':pending['round_index'],
                              'snapshot':Path(run['pair_snapshot']).name,**pending['pair_setup']}
                        manifest['pairs'].append(pair);atomic(replay/'manifest.json',manifest)
                    if pending.get('error')=='LaunchServices did not produce an owned window' and not pending.get('intent_failure'):
                        pending['intent_failure']=True
                        run.setdefault('intent_failures',[]).append({'browser':'arc','task':pending['task'],
                            'index':pending['round_index'],'reason':pending['error']})
                    snapshot=replay/pair['snapshot']
                    if sha(snapshot/'State/browser.json')!=pair['snapshot_browser_sha256']:
                        raise RuntimeError('Private replay state changed before pending counterpart')
                    run['last_arc_viewport']=pair.get('target_viewport',run.get('last_arc_viewport'))
                    shutil.rmtree(root);shutil.copytree(snapshot,root)
                    session('open',pending['task'],pending['round_index'])
            for task in a.tasks.split(','):
                if a.resume_from:
                    good={s['round_index'] for s in run['samples'] if s['task']==task and all(
                        any(t['task']==task and t['round_index']==s['round_index'] and
                            t['browser']==name and t.get('valid') for t in run['samples']) for name in order)}
                    counted={**run,'samples':[s for s in run['samples'] if s['task']==task and s['round_index'] in good]}
                    required=({'launch.first_paint_ms'} if task=='paint' else
                              {'launch.window_ms'} if task=='window' else
                              {'bench.'+task[6:]} if task.startswith('bench-') else
                              {'launch.window_ms','mem.idle_1tab_mib','mem.10tabs_mib','mem.30tabs_mib',
                               'mem.per_tab_mib','cpu.idle_static_pct','cpu.idle_10tabs_pct','cpu.idle_hidden_pct',
                               'cpu.animated_pct','wakeups.idle_per_s','load.static_ms.cold','load.static_ms.warm',
                               'load.heavy_dom_ms.cold','load.heavy_dom_ms.warm','disk.app_mib',
                               'disk.main_binary_mib','procs.idle_count'})
                    if a.main_delta and task=='core':required=MAIN_DELTA-{'launch.window_ms','launch.first_paint_ms'}
                    target=benchmark_target(run,counted,task,order) if task.startswith('bench-') else a.samples
                    if all(metric_rows(counted,name).get((a.state,key),{}).get('summary',{}).get('n',0)>=target
                           for name in order for key in required):
                        print('RESUME retains completed task',task,flush=True);continue
                previous=[s['round_index'] for s in run['samples'] if s['task']==task]
                start_index=max(previous)+1 if previous else 0
                indices=(sorted(r['index'] for r in frozen_manifest['pairs'] if r['task']==task)
                         if frozen_manifest else range(start_index,max(a.samples*2,start_index+1)))
                if frozen_manifest and a.resume_from:
                    # Keep qualified replay sessions and repeat a rejected
                    # starting state, without duplicating completed indices.
                    indices=[i for i in indices if not all(any(
                        s['task']==task and s['round_index']==i and s['browser']==name
                        and s.get('valid') and required<=set(s.get('metrics',{}))
                        for s in run['samples']) for name in order)]
                for index in indices:
                    if a.state=='S-real' and a.browser in ('paired','arc'):
                        # Import occurs within the following Arc screen hold,
                        # so another capture agent cannot change its starting
                        # state between import and the measured Arc launch.
                        shutil.rmtree(root);root.mkdir()
                        snapshot=replay/f'{task}-{index:02}'
                        run['pair_snapshot']=str(snapshot)
                    elif frozen_manifest:
                        pair=next((r for r in frozen_manifest['pairs'] if r['task']==task and r['index']==index),None)
                        if not pair:raise RuntimeError('Frozen reference has no matching private starting state')
                        snapshot=BASE.parent/'cohorts'/frozen_manifest['cohort']/pair['snapshot']
                        if sha(snapshot/'State/browser.json')!=pair['snapshot_browser_sha256']:raise RuntimeError('Private replay state changed')
                        shutil.rmtree(root);shutil.copytree(snapshot,root)
                        run['last_arc_viewport']=pair.get('target_viewport')
                    c.asset_epoch=f'{task}-{index}'
                    for name in order:
                        sample=session(name,task,index)
                        if name=='arc' and sample.get('pair_setup'):
                            pair={'task':task,'index':index,'snapshot':Path(run['pair_snapshot']).name,
                                  **sample['pair_setup']}
                            manifest['pairs'].append(pair);atomic(replay/'manifest.json',manifest)
                        if name=='arc' and sample.get('initial_workload_page'):
                            page=sample['initial_workload_page']
                            run['last_arc_viewport']=[page['viewport_width'],page['viewport_height']]
                            manifest['pairs'][-1]['target_viewport']=run['last_arc_viewport'];atomic(replay/'manifest.json',manifest)
                    counted=run
                    if a.browser=='paired':
                        # A bad load endpoint in either browser rejects that
                        # entire pair, preserving identical starting workloads.
                        good={i for i in range(index+1) if all(any(s['browser']==name and s['task']==task and s.get('round_index')==i and s.get('valid') for s in run['samples']) for name in order)}
                        counted={**run,'samples':[s for s in run['samples'] if s['task']!=task or s.get('round_index') in good]}
                    counts={name:{key[1]:v['summary']['n'] for key,v in metric_rows(counted,name).items() if any(s['task']==task and key[1] in s['metrics'] for s in counted['samples'])} for name in order}
                    if task.startswith('bench-'):
                        for name in order:
                            counts[name]['suite_attempts']=sum(bool(s.get('valid') and s['browser']==name and s['task']==task and s.get('benchmark_attempt')) for s in run['samples'])
                    run['valid_metric_counts']=counts;atomic(a.out,run)
                    if a.main_delta:
                        update=subprocess.run([sys.executable,str(Path(__file__).with_name('delta_report.py')),str(a.out.resolve())],capture_output=True,text=True)
                        print('MAIN DELTA REPORT',update.stdout.strip() or update.stderr.strip(),flush=True)
                        if update.returncode:raise RuntimeError('Main delta publication failed')
                    required_counts=[{k:n for k,n in v.items() if k != 'launch.warm_vs_cold' and (a.main_delta or k != 'energy.idle_impact')} for v in counts.values()]
                    if task.startswith('bench-'):
                        target=benchmark_target(run,counted,task,order)
                        atomic(a.out,run)
                        if all(counts[name].get('bench.'+task[6:],0)>=target for name in order):break
                    elif a.main_delta:
                        expected=({'launch.first_paint_ms'} if task=='paint' else
                                  {'launch.window_ms'} if task=='window' else
                                  MAIN_DELTA-{'launch.first_paint_ms','launch.window_ms'})
                        if all(counts[name].get(k,0)>=a.samples for name in order for k in expected):break
                    elif all(v and min(v.values())>=a.samples for v in required_counts):break
                else:raise RuntimeError('Insufficient valid N after maximum rounds')
                if task=='core' and a.browser=='paired' and 'paint' in a.tasks.split(','):
                    interim=subprocess.run([sys.executable,str(Path(__file__).with_name('assemble.py')),
                        '--input',str(a.out.resolve())+':paint,core','--interim',
                        '--out',str(a.out.with_name(a.out.stem+'-interim.json').resolve())],
                        capture_output=True,text=True)
                    run['interim_report']={'exit':interim.returncode,'output':interim.stdout,'error':interim.stderr}
                    atomic(a.out,run)
                    print('INTERIM REPORT',json.dumps(run['interim_report']),flush=True)
    except BaseException as exc:
        run['stop_reason']=str(exc) or type(exc).__name__
    finally:
        run['end_date']=now();atomic(a.out,run);c.close()
        shutil.rmtree(root);shutil.rmtree(root_empty)
    return 1 if run.get('stop_reason') else 0

if __name__=='__main__':raise SystemExit(main())
