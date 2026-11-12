#!/usr/bin/env python3
"""Guarded, interleaved Arc/Open Phase 1 runs. Builds are always separate."""
import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

from server import Collector
from score import metric_rows

ROOT=Path(__file__).resolve().parents[2]
PROBE=ROOT/'.re/perf/bin/probe'
PLANS=Path.home()/'.t3/projects/open/.re/handoff/plans'
ARC=Path('/Applications/Arc.app')
OPEN=ROOT/'build/Release/Open.app'
ARC_DATA=Path.home()/'Library/Application Support/Arc'
BASE=ROOT/'.re/perf/profiles/S-real'
EXPECTED_ARC=json.loads(os.environ.get('OPEN_PERF_ARC_VERSION','["1.172.2","90755"]'))

def now():return dt.datetime.now().astimezone().isoformat()
def atomic(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix(path.suffix+'.tmp');tmp.write_text(json.dumps(value,indent=2)+'\n');tmp.replace(path)
def command(args,**kwargs):
    return subprocess.run([str(v) for v in args],capture_output=True,text=True,check=True,timeout=kwargs.pop('timeout',30),**kwargs).stdout
def probe(*args):return json.loads(command([PROBE,*args],timeout=70))
def arc_core():
    framework=ARC/'Contents/Frameworks/ArcCore.framework'
    info=plistlib.loads((framework/'Resources/Info.plist').read_bytes())
    return {'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],
            'binary_sha256':sha(framework/'ArcCore')}

def version(strict=True):
    info=plistlib.loads((ARC/'Contents/Info.plist').read_bytes())
    v=[info['CFBundleShortVersionString'],info['CFBundleVersion']]
    if strict and v!=EXPECTED_ARC:raise RuntimeError('Arc version changed; discard and restart the unfinished cohort')
    return v
def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(4*1024*1024),b''):h.update(chunk)
    return h.hexdigest()
def disk_mib(path):return int(command(['/usr/bin/du','-sk',path]).split()[0])/1024
def existing_pids(bundle):
    executable=bundle/'Contents/MacOS'/('Arc' if bundle==ARC else 'Open')
    rows=command(['/bin/ps','-axo','pid=,comm='])
    found=[]
    for line in rows.splitlines():
        parts=line.split(None,1)
        if len(parts)!=2:continue
        path=parts[1]
        # LaunchServices may return another checkout's existing Open with
        # the same bundle ID. Never adopt it, even when our path is absent.
        if path==str(executable) or (bundle==OPEN and path.endswith('.app/Contents/MacOS/Open')):
            found.append(int(parts[0]))
    return found
def background_jobs():
    """Live slotless heavy jobs invalidate quiet-machine score measurements."""
    holders=Path(os.environ.get('OPEN_HEAVY_PREFIX','/tmp/open-heavy')+'-holders')
    if not holders.is_dir():return []
    result=[]
    for path in holders.iterdir():
        if not path.name.isdigit():continue
        try:
            if path.stat().st_size>4096:raise RuntimeError('Oversize heavy holder record')
            fields=path.read_text().strip().split('\t')
        except FileNotFoundError:continue  # The queued job finished during this read.
        if fields[-1]!='background':continue
        pid=int(path.name)
        try:os.kill(pid,0)
        except ProcessLookupError:continue
        result.append({'pid':pid,'kind':'background'})
        if len(result)>64:raise RuntimeError('Heavy holder count limit')
    return result
def arc_counts():
    """Counts only; schema mirrors OpenImport/ArcProbe, never emits names."""
    raw=json.loads((ARC_DATA/'StorableSidebar.json').read_text())
    containers=raw['sidebar']['containers']
    holders=[containers[i+1] for i in range(0,len(containers)-1,2) if isinstance(containers[i],dict) and 'global' in containers[i]]
    if len(holders)!=1:raise RuntimeError('Arc global sidebar container is ambiguous')
    holder=holders[0]
    def entries(value):
        if isinstance(value,dict):return value
        return {value[i]:value[i+1] for i in range(0,len(value)-1,2) if isinstance(value[i],str) and isinstance(value[i+1],dict)}
    items=entries(holder.get('items',[]));spaces=entries(holder.get('spaces',[]))
    favorites=set()
    top=holder.get('topAppsContainerIDs',[])
    for i in range(1,len(top),2):favorites.update(items.get(top[i],{}).get('childrenIds',[]))
    def descendants(cid):
        seen=set();pending=[cid]
        while pending:
            key=pending.pop()
            if key in seen or key not in items:continue
            seen.add(key);pending.extend(items[key].get('childrenIds',[]))
        return seen
    sections={'pinned':set(),'today':set()}
    for space in spaces.values():
        pending=None
        for v in space.get('newContainerIDs',space.get('containerIDs',[])):
            if isinstance(v,dict):pending='pinned' if 'pinned' in v else 'today' if 'unpinned' in v else None
            elif v in ('pinned','unpinned'):pending='pinned' if v=='pinned' else 'today'
            elif isinstance(v,str) and pending:sections[pending].update(descendants(v));pending=None
    favorites=set().union(*(descendants(v) for v in favorites)) if favorites else set()
    counts={'spaces':len(spaces),'favorites':0,'pinned':0,'today':0,'pinned_and_today':0,'folders':0,'extensions_enabled':0,'extensions_installed':0}
    for key,item in items.items():
        kind=next(iter(item.get('data',{})),None)
        if kind in ('tab','welcomeToArc'):
            counts['favorites' if key in favorites else 'pinned_and_today']+=1
            for section,ids in sections.items():
                if key in ids:counts[section]+=1
        elif kind=='list':counts['folders']+=1
    for path in (ARC_DATA/'User Data').glob('*/Preferences'):
        pref=json.loads(path.read_text())
        settings=pref.get('extensions',{}).get('settings',{})
        counts['extensions_installed']+=len(settings)
        counts['extensions_enabled']+=sum(v.get('state')==1 for v in settings.values())
    return counts
def system_windows():
    """Identify only system-owned windows, without reading their contents."""
    rows=probe('windows');out=set()
    for row in rows:
        result=subprocess.run(['/bin/ps','-p',str(row['pid']),'-o','comm='],capture_output=True,text=True,timeout=5)
        path=result.stdout.strip()
        if path.startswith('/System/') or '/SecurityAgent' in path or '/CoreServices/' in path:
            out.add((row['pid'],row['id']))
    return out
def guard(baseline):
    if system_windows()-baseline:raise RuntimeError('new system-owned window appeared; measurement stopped without interacting')

class Browser:
    def __init__(self,name,root,out,collector,token):
        self.name=name;self.root=root;self.out=out;self.collector=collector;self.token=token
        self.bundle=ARC if name=='arc' else OPEN
        self.pid=None;self.owned={};self.tabs={};self.baseline=system_windows()
        self.startup_fault=False
    def call(self,cmd,**args):
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
            s.settimeout(60);s.connect(str(self.root/'automation.sock'))
            s.sendall((json.dumps({'id':1,'cmd':cmd,'args':args})+'\n').encode())
            buf=b''
            while not buf.endswith(b'\n'):
                chunk=s.recv(1<<20)
                if not chunk:break
                buf+=chunk
        result=json.loads(buf)
        if not result.get('ok'):raise RuntimeError(f'Open {cmd} refused: {result.get("error")}')
        return result.get('result')
    def ready(self):
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            guard(self.baseline)
            try:
                if self.call('ping')['pid']==self.pid:return
            except (OSError,ValueError):pass
            time.sleep(.1)
        raise RuntimeError('Open socket not ready')
    def snapshot(self):
        result=probe('snapshot',self.pid)
        for p in result['processes']:self.owned[p['pid']]=p['birth_ticks']
        if not any(p['pid']==self.pid for p in result['processes']):raise RuntimeError('browser process disappeared')
        return result
    def start(self,url=None,first_run=False):
        if existing_pids(self.bundle):raise RuntimeError(f'{self.name} already running; refusing to adopt or stop it')
        cfg={'bundle':str(self.bundle),'urls':[url] if url else []}
        if self.name=='open':
            cfg['args']=['--user-data-dir='+str(self.root),'--style=chrome','--open-e2e','--intro-sound=silent']
            if not first_run:cfg['args'].append('--skip-first-run')
            # LaunchOptions' real startup URL creates the standard browser.
            # A cold external-URL Apple event can instead choose Little Open.
            if url and not getattr(self,'external_startup',False):cfg['args'].append(url)
            if not getattr(self,'external_startup',False):cfg['urls']=[]
            cfg['environment']={'OPEN_USER_DATA':str(self.root),'OPEN_E2E_OWNER_PID':str(os.getpid()),
                                'OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS':'1'}
            if self.startup_fault:
                cfg['environment']['DYLD_INSERT_LIBRARIES']=str(ROOT/'.re/perf/bin/startup-fault.dylib')
        config=self.out/'launch-config.json';atomic(config,cfg)
        p=subprocess.run([str(PROBE),'launch',str(config)],capture_output=True,text=True,timeout=70)
        self.launch=json.loads(p.stdout);atomic(self.out/'launch.json',self.launch)
        if self.launch.get('birth_ticks',0)<self.launch.get('request_ticks',0):
            raise RuntimeError('LaunchServices returned an existing process; refusing to adopt or quit it')
        self.pid=self.launch.get('pid')
        if self.pid:self.snapshot()
        guard(self.baseline)
        if p.returncode or not self.launch.get('window_detected'):raise RuntimeError('LaunchServices did not produce an owned window')
        if self.name=='open':self.ready()
        return self.launch
    def new_page(self,url,token):
        if self.name=='arc':command(['/usr/bin/open','-a',self.bundle,url])
        else:
            self.call('open',url=url)
            for tab in self.call('tabs'):
                if tab.get('url')==url:self.tabs[token]=tab['id'];break
        record=self.collector.wait(token)
        guard(self.baseline)
        if record.get('visibility')!='visible':raise RuntimeError('synthetic workload page was not visible')
        return record
    def close_pages(self,keep):
        if self.name=='open':
            for tab in self.call('tabs'):
                if str(tab.get('url','')).startswith(self.collector.url) and f'run={keep}' not in tab.get('url',''):
                    self.call('close',tab=tab['id'])
            return True
        old={r['run'] for r in self.collector.events if r.get('event')=='loaded' and r['run']!=keep and r['run'].startswith(self.token)}
        if not old:return True
        command(['/usr/bin/open','-a',self.bundle,self.collector.url+'/command.html?keep='+keep])
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            hidden={r['run'] for r in self.collector.events if r.get('event')=='pagehide'}
            if old<=hidden:return True
            time.sleep(.1)
        return False
    def stop(self):
        if not self.pid:return
        with contextlib.suppress(Exception):self.snapshot()
        # Both use a normal quit request. Arc's NSRunningApplication operation
        # requires no scripting permission. Open always uses its socket.
        if self.name=='open':
            with contextlib.suppress(OSError,ValueError,RuntimeError):self.call('quit')
        else:probe('terminate',self.pid)
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            live=[]
            for pid,birth in self.owned.items():
                snap=probe('snapshot',pid)
                if any(p['pid']==pid and p['birth_ticks']==birth for p in snap['processes']):live.append(pid)
            if not live:
                atomic(self.out/'cleanup.json',{'ok':True,'owned_process_count':len(self.owned),'remaining':0})
                if self.name=='arc':version()
                return
            time.sleep(.25)
        atomic(self.out/'cleanup.json',{'ok':False,'remaining':live})
        raise RuntimeError('normal quit left owned processes; stop before more launches')

def metric(out,key,value,unit,direction='lower'):
    out[key]={'value':value,'unit':unit,'direction':direction}
def mem_snapshot(browser,out,key):
    snap=browser.snapshot();atomic(browser.out/(key.replace('.','-')+'.json'),snap)
    rows=snap['processes'];total=sum(p['footprint_bytes'] for p in rows)/2**20
    metric(out,key,total,'MiB')
    detail={'process_count':len(rows),'browser_share':sum(p['footprint_bytes'] for p in rows if p['pid']==browser.pid)/sum(p['footprint_bytes'] for p in rows),
            'renderer_count':sum(p['kind']=='renderer' for p in rows)}
    if browser.name=='open':
        tabs=browser.call('tabs')
        detail['focused_space_saved_tabs']=len(tabs)
        detail['focused_space_loaded_tabs']=sum(bool(t.get('loaded')) for t in tabs)
        detail['focused_space_loading_tabs']=sum(bool(t.get('loading')) for t in tabs)
    return total,detail
def cpu_window(browser,seconds):
    load_before=list(os.getloadavg())
    before=browser.snapshot();start=time.monotonic();time.sleep(seconds);after=browser.snapshot()
    a={p['pid']:p for p in before['processes']};b={p['pid']:p for p in after['processes']}
    common={pid for pid in a.keys()&b.keys() if a[pid]['birth_ticks']==b[pid]['birth_ticks']}
    tb=probe('metadata')['mach_timebase'];scale=tb[0]/tb[1]/1e9
    values=[]
    for pid in common:
        elapsed=(b[pid]['stamp_ticks']-a[pid]['stamp_ticks'])*scale
        values.append({'pid':pid,'kind':b[pid]['kind'],'elapsed_s':elapsed,
            'cpu_pct':100*(b[pid]['cpu_seconds']-a[pid]['cpu_seconds'])/elapsed,
            'wakeups_per_s':(b[pid]['wakeups']-a[pid]['wakeups'])/elapsed})
    result={'before':before,'after':after,'processes':values,'elapsed_s':time.monotonic()-start,
            'load_before':load_before,'load_after':list(os.getloadavg()),
            'complete':a.keys()==b.keys()==common,'cpu_pct':sum(v['cpu_pct'] for v in values),
            'wakeups_per_s':sum(v['wakeups_per_s'] for v in values)}
    if all('reaped_cpu_seconds' in p for snap in (before,after) for p in snap['processes']):
        elapsed=(after['monotonic_seconds']-before['monotonic_seconds'])
        def total(snap,field,reaped):return sum(p[field]+p[reaped] for p in snap['processes'])
        cpu=100*(total(after,'cpu_seconds','reaped_cpu_seconds')-total(before,'cpu_seconds','reaped_cpu_seconds'))/elapsed
        wake=(total(after,'wakeups','reaped_wakeups')-total(before,'wakeups','reaped_wakeups'))/elapsed
        result['live_process_only_cpu_pct']=result['cpu_pct']
        result['accounting']='sum live self and reaped-child lifetime counters, then take interval delta'
        result['process_churn']=a.keys()!=b.keys()
        # Kernel child counters carry terminated helpers across the interval.
        # Keep the process-common split as detail, never silently lose exits.
        result['cpu_pct']=cpu;result['wakeups_per_s']=wake
        result['complete']=cpu>=0 and wake>=0 and browser.pid in common
    return result

def negative_proofs(browser,collector,token,out):
    """Real end-to-end faults in synthetic pages, never production source."""
    results={}
    def page(suffix,extra=''):
        ident=token+'-'+suffix
        return browser.new_page(collector.url+'/static.html?run='+ident+extra,ident)
    normal=page('delay-normal');slow=page('delay-200','&delay_ms=200')
    delta=slow['load_ms']-normal['load_ms']
    results['load.static_ms']={'injection':'200 ms HTTP response delay','normal_ms':normal['load_ms'],
                               'fault_ms':slow['load_ms'],'delta_ms':delta,'detected':delta>120}
    for fixture,metric_base in (('static','load.static'),('heavy-dom','load.heavy_dom')):
        for cache in ('cold','warm'):
            records=[]
            shared=f'{token}-{fixture}-{cache}'
            if cache=='warm':
                ident=shared+'-prime'
                browser.new_page(collector.url+f'/{fixture}.html?run={ident}&assetkey={shared}',ident)
            for fault in (False,True):
                ident=shared+('-fault' if fault else '-normal')
                asset=shared if cache=='warm' else ident
                url=collector.url+f'/{fixture}.html?run={ident}&assetkey={asset}'
                if fault:url+='&delay_ms=200'
                records.append(browser.new_page(url,ident))
            observed=all(r.get('resource_cache_count' if cache=='warm' else 'resource_network_count',0)>0 for r in records)
            for field,suffix in (('load_ms','_ms'),('fcp_ms','_fcp_ms'),('lcp_ms','_lcp_ms')):
                a,b=(r.get(field) for r in records)
                key=metric_base+suffix+'.'+cache
                difference=b-a if a is not None and b is not None else None
                results[key]={'injection':'200 ms HTTP response delay in the real '+fixture+' '+cache+'-asset flow',
                              'normal_ms':a,'fault_ms':b,'delta_ms':difference,'cache_verified':observed,
                              'detected':observed and difference is not None and difference>120}
    # Allocate in the same settled renderer. Opening another tab here would
    # confound the fault with Chromium retiring/reusing its spare renderer.
    time.sleep(15)
    selected=next(t['id'] for t in browser.call('tabs') if t.get('selected'))
    before=browser.snapshot()
    browser.call('eval',tab=selected,js='window.perfAllocation=new Uint8Array(100*1024*1024);for(let i=0;i<perfAllocation.length;i+=4096)perfAllocation[i]=(i/4096)%251;perfAllocation.length')
    time.sleep(.25);after=browser.snapshot()
    delta=(sum(p['footprint_bytes'] for p in after['processes'])-sum(p['footprint_bytes'] for p in before['processes']))/2**20
    results['mem.footprint']={'injection':'100 MiB touched Uint8Array in a real renderer','delta_mib':delta,'detected':delta>=80}
    baseline=cpu_window(browser,12)
    page('cpu-spinner','&cpu_pct=5');time.sleep(3);fault=cpu_window(browser,12)
    results['cpu.tree']={'injection':'5 ms busy loop every 100 ms','before':baseline,'after':fault,
                         'delta_pct':fault['cpu_pct']-baseline['cpu_pct'],
                         'detected':baseline['complete'] and fault['complete'] and fault['cpu_pct']-baseline['cpu_pct']>2}
    selected=next(t['id'] for t in browser.call('tabs') if t.get('selected'))
    browser.call('eval',tab=selected,js='window.perfWakeupTimer=setInterval(()=>{window.perfWakeupCount=(window.perfWakeupCount||0)+1},1);true')
    wake_fault=cpu_window(browser,12)
    results['wakeups.tree']={'injection':'1 ms foreground timer; browser timer clamping is retained',
                             'normal_per_s':fault['wakeups_per_s'],'fault_per_s':wake_fault['wakeups_per_s'],
                             'detected':wake_fault['wakeups_per_s']>fault['wakeups_per_s']+20,
                             'before':fault,'after':wake_fault}
    atomic(out/'negative-proofs.json',results)
    return results

def prepare_real(browser,directory=ARC_DATA,normalize=False):
    browser.start()
    initial_profiles=browser.call('profiles-shell')['profiles'] if normalize else []
    initial_spaces={s['id'] for s in browser.call('spaces')} if normalize else set()
    browser.call('first-run',action='settings-import',directory=str(directory))
    browser.call('first-run',action='settings-select',history=False)
    browser.call('first-run',action='settings-next')
    state=browser.call('first-run',action='settings-inspect')
    atomic(browser.out/'import-review-state.json',state)
    if state.get('settingsStep')!='Review':
        raise RuntimeError('Import did not reach Review; private wizard state retained')
    browser.call('first-run',action='settings-run')
    deadline=time.monotonic()+120
    while time.monotonic()<deadline:
        guard(browser.baseline)
        state=browser.call('first-run',action='settings-inspect')
        if state.get('settingsStep')=='Report':break
        if state.get('settingsError'):raise RuntimeError('real Import from Arc returned an error; details remain private')
        time.sleep(.2)
    else:raise RuntimeError('real Import from Arc did not finish')
    counts=state.get('settingsOutcome',{})
    atomic(browser.out/'import-counts.json',{'arc_counts':arc_counts(),'open_import_counts':counts,
                                         'extensions_policy':'No extension installation or consent; inventory counts only'})
    browser.call('first-run',action='settings-done')
    if normalize:
        current=browser.call('profiles-shell')['profiles']
        spaces=browser.call('spaces')
        source=arc_counts()
        if len(spaces)>source['spaces']:
            for placeholder_space in initial_spaces:
                if not any(s['id']==placeholder_space for s in spaces):continue
                browser.call('space',space=placeholder_space)
                browser.call('sidebar-menu',item='Delete Space')
                browser.call('alert',button='Delete')
            spaces=browser.call('spaces')
        for placeholder in initial_profiles:
            retained=next((p for p in current if p['id']==placeholder['id']),None)
            if not retained:continue
            owners={s['id'] for s in spaces if s['profile']==placeholder['id']}
            # Import can reuse the Default profile for real Arc Spaces. Keep
            # it, and remove only an unused extra fresh-root placeholder.
            if owners or len(current)<=counts.get('Profiles',len(current)):continue
            if sum(p['name']==placeholder['name'] for p in current)!=1:
                raise RuntimeError('Ambiguous placeholder profile name; no deletion')
            browser.call('profile-engine',action='delete',profile=placeholder['name'])
        spaces=browser.call('spaces');sections={k:set() for k in ('favorites','pinned','today')}
        for space in spaces:
            browser.call('space',space=space['id'])
            for tab in browser.call('tabs'):
                if tab.get('section') in sections:sections[tab['section']].add(tab['id'])
        actual={'spaces':len(spaces),'profiles':len(browser.call('profiles-shell')['profiles']),
                **{key:len(ids) for key,ids in sections.items()}}
        atomic(browser.out/'normalized-counts.json',{'arc':arc_counts(),'open':actual,'removed_fresh_placeholder_profiles':len(initial_profiles)})
        if any(actual[key]!=source[key] for key in ('spaces','favorites','pinned','today')):
            raise RuntimeError('Imported live sidebar counts differ; private count receipt retained')
    return counts

def worker(args):
    if os.environ.get('OPEN_PERF_LOCKED')!='1':raise RuntimeError('worker must be started by the lock supervisor')
    output=Path(args.worker);output.mkdir(parents=True,exist_ok=True)
    receipt={'date':now(),'browser':args.browser,'state':args.state,'mode':args.mode,'valid':False,
             'load_before':list(os.getloadavg()),'metrics':{},'blocked':{}}
    receipt['display_before']=probe('metadata')
    receipt['harness_sha256']={p.name:sha(p) for p in [Path(__file__),PROBE,Path(__file__).with_name('server.py')]}
    atomic(output/'sample.json',receipt)
    if os.getloadavg()[0]>args.max_load:
        receipt['gate_refused']=True;atomic(output/'sample.json',receipt);return 75
    if (Path('/tmp/open-onscreen-priority').exists() or (ROOT/'.re/hold-on-screen').exists()):
        receipt['gate_refused']=True;receipt['reason']='screen hold';atomic(output/'sample.json',receipt);return 75
    version(strict=args.browser=='arc');backup=Path.home()/'Library/Caches/OpenRE/arc-reference/Arc-1.170.0-89123.app'
    if not backup.is_dir():raise RuntimeError('Arc backup is missing')
    # Short roots preserve the macOS Unix socket path limit.
    root=Path(tempfile.mkdtemp(prefix='op.',dir='/tmp'))
    if args.browser=='open' and args.state=='S-real' and args.mode!='prepare':
        if not BASE.exists():raise RuntimeError('Run --mode prepare first: missing real imported Open state')
        shutil.copytree(BASE,root,dirs_exist_ok=True)
        with contextlib.suppress(FileNotFoundError):(root/'automation.sock').unlink()
    collector=Collector(output);token=uuid.uuid4().hex[:12]
    browser=Browser(args.browser,root,output,collector,token);metrics=receipt['metrics']
    browser.startup_fault=args.mode=='negative-launch'
    try:
        if args.mode=='prepare':
            receipt['import_counts']=prepare_real(browser)
        else:
            url=collector.url+'/report.html?run='+token+'-launch'
            launch=browser.start(url)
            page=collector.wait(token+'-launch');guard(browser.baseline)
            if page.get('visibility')!='visible':raise RuntimeError('launch reporter was not visible')
            if 'launch' in args.groups:
                metric(metrics,'launch.window_ms',launch['window_ms'],'ms')
                if page.get('fcp_ms') is not None:
                    metric(metrics,'launch.first_paint_ms',page['time_origin_ms']+page['fcp_ms']-launch['birth_wall_seconds']*1000,'ms')
                else:receipt['blocked']['launch.first_paint_ms']='no renderer FCP'
            if args.mode=='negative-launch':
                receipt['injection']='200 ms pre-main constructor, each process; separate from primary samples'
            elif args.mode=='negative':
                receipt['negative_proofs']=negative_proofs(browser,collector,token,output)
            elif args.mode=='smoke':
                second=token+'-close-proof';browser.new_page(collector.url+'/static.html?run='+second,second)
                receipt['self_close_supported']=browser.close_pages(second)
            else:
                if any(v in args.groups for v in ('memory','idle')):
                    time.sleep(60)
                    mem1,details=mem_snapshot(browser,metrics,'mem.idle_1tab_mib');receipt['mem_1tab_details']=details
                    metric(metrics,'procs.idle_count',details['process_count'],'count')
                    if 'idle' in args.groups:
                        cpu=cpu_window(browser,120);atomic(output/'cpu-static.json',cpu)
                        if cpu['complete']:
                            metric(metrics,'cpu.idle_static_pct',cpu['cpu_pct'],'% of one core')
                            metric(metrics,'wakeups.idle_per_s',cpu['wakeups_per_s'],'wakeups/s')
                        else:receipt['blocked']['cpu.idle_static_pct']='process churn; partial counters not scored'
                    memory=[]
                    for count in (10,30):
                        for index in range(1 if count==10 else 10,count):
                            ident=f'{token}-t{index}';browser.new_page(collector.url+'/static.html?run='+ident,ident)
                        time.sleep(60)
                        value,detail=mem_snapshot(browser,metrics,f'mem.{count}tabs_mib')
                        memory.append((count,value));receipt[f'mem_{count}tab_details']=detail
                        if count==10 and 'idle' in args.groups:
                            cpu=cpu_window(browser,120);atomic(output/'cpu-10tabs.json',cpu)
                            if cpu['complete']:metric(metrics,'cpu.idle_10tabs_pct',cpu['cpu_pct'],'% of one core')
                            else:receipt['blocked']['cpu.idle_10tabs_pct']='process churn'
                    xs=[1,*[v[0] for v in memory]];ys=[mem1,*[v[1] for v in memory]]
                    xm=statistics.mean(xs);ym=statistics.mean(ys)
                    slope=sum((x-xm)*(y-ym) for x,y in zip(xs,ys))/sum((x-xm)**2 for x in xs)
                    metric(metrics,'mem.per_tab_mib',slope,'MiB/tab')
                    receipt['swap_after_30tabs']=command(['/usr/sbin/sysctl','-n','vm.swapusage']).strip()
                    if browser.close_pages(token+'-t29'):
                        time.sleep(60);mem_snapshot(browser,metrics,'mem.after_close_mib')
                    else:
                        receipt['blocked']['mem.after_close_mib']='Arc refused script self-close; exact tab count not established'
                        raise RuntimeError('Arc cannot close synthetic tabs without permission; stop to avoid accumulating unmatched state')
                    if 'idle' in args.groups:
                        hidden_state=probe('hide',browser.pid)
                        atomic(output/'hide.json',hidden_state)
                        if not hidden_state['hidden']:raise RuntimeError('hide did not produce hidden state')
                        time.sleep(60)
                        hidden=browser.snapshot()
                        if any(w['pid']==browser.pid for w in hidden['windows']):raise RuntimeError('owned browser window still on screen after hide')
                        cpu=cpu_window(browser,120);atomic(output/'cpu-hidden.json',cpu)
                        if cpu['complete']:metric(metrics,'cpu.idle_hidden_pct',cpu['cpu_pct'],'% of one core')
                        else:receipt['blocked']['cpu.idle_hidden_pct']='process churn'
                        probe('unhide',browser.pid)
                        animated=token+'-animated'
                        browser.new_page(collector.url+'/animated.html?run='+animated,animated)
                        if not browser.close_pages(animated):raise RuntimeError('cannot isolate animated workload')
                        time.sleep(60)
                        cpu=cpu_window(browser,120);atomic(output/'cpu-animated.json',cpu)
                        if cpu['complete']:metric(metrics,'cpu.animated_pct',cpu['cpu_pct'],'% of one core')
                        else:receipt['blocked']['cpu.animated_pct']='process churn'
                if 'page' in args.groups:
                    for name,metric_id in [('static','load.static_ms'),('heavy-dom','load.heavy_dom_ms')]:
                        for cache in ('cold','warm'):
                            ident=f'{token}-{name}-{cache}'
                            page=browser.new_page(f'{collector.url}/{name}.html?run={ident}&cache={cache}&assetkey={token}-{name}',ident)
                            if cache=='warm' and not page.get('resource_cache_count'):
                                raise RuntimeError('warm subresource cache was not observed; refuse the cache label')
                            suffix='.'+cache
                            metric(metrics,metric_id+suffix,page['load_ms'],'ms')
                            if page.get('fcp_ms') is not None:metric(metrics,metric_id.replace('_ms','_fcp_ms')+suffix,page['fcp_ms'],'ms')
                            if page.get('lcp_ms') is not None:metric(metrics,metric_id.replace('_ms','_lcp_ms')+suffix,page['lcp_ms'],'ms')
                if 'disk' in args.groups:
                    metric(metrics,'disk.app_mib',disk_mib(browser.bundle),'MiB allocated')
                    exe=browser.bundle/'Contents/MacOS'/('Arc' if args.browser=='arc' else 'Open')
                    metric(metrics,'disk.main_binary_mib',exe.stat().st_size/2**20,'MiB logical')
                    if args.state=='S-empty' and args.browser=='open':metric(metrics,'disk.fresh_profile_mib',disk_mib(root),'MiB allocated')
                receipt['synthetic_cleanup']=browser.close_pages('none')
                if args.browser=='arc' and not receipt['synthetic_cleanup']:raise RuntimeError('Arc synthetic-tab cleanup failed; no further Arc launches')
        guard(browser.baseline)
    except Exception as exc:
        receipt['error']=str(exc)
    finally:
        try:browser.stop();receipt['cleanup']=True
        except Exception as exc:receipt['cleanup']=False;receipt['cleanup_error']=str(exc)
        collector.close()
        if args.mode=='prepare' and receipt.get('cleanup') and not receipt.get('error'):
            if BASE.exists():raise RuntimeError('refusing to overwrite existing imported baseline')
            shutil.copytree(root,BASE,ignore=shutil.ignore_patterns('automation.sock'))
        shutil.rmtree(root)
        receipt['load_after']=list(os.getloadavg())
        receipt['display_after']=probe('metadata')
        receipt['valid']=not receipt.get('error') and receipt.get('cleanup',False) and receipt['load_after'][0]<=args.max_load and args.mode=='measure'
        if receipt['display_before']!=receipt['display_after']:
            receipt['valid']=False;receipt['error']='display changed during sample; stop this cohort'
        if receipt['load_after'][0]>args.max_load:receipt['load_invalid']=True
        atomic(output/'sample.json',receipt)
    print(json.dumps({k:v for k,v in receipt.items() if k not in ('metrics','import_counts','negative_proofs','display_before','display_after','harness_sha256')}),flush=True)
    return 1 if receipt.get('error') or not receipt.get('cleanup') else 0

def provenance(include_arc=True):
    engine=OPEN/'Contents/Frameworks/OpenEngine.framework/Versions/A/OpenEngine'
    return {'commit':command(['git','rev-parse','HEAD']).strip(),'origin_main':command(['git','rev-parse','origin/main']).strip(),
            'app_main_sha256':sha(OPEN/'Contents/MacOS/Open'),'engine_sha256':sha(engine),
            'arc_version':version(strict=False) if include_arc else None,'arc_core':arc_core() if include_arc else None,'open_chromium_version':'156.0.8078.48','os':command(['/usr/bin/sw_vers']).strip(),'hardware':command(['/usr/sbin/sysctl','-n','hw.model','hw.ncpu','hw.memsize']).strip(),
            'display':probe('metadata'),'power_battery':command(['/usr/bin/pmset','-g','batt']).strip(),
            'power_configuration':command(['/usr/bin/pmset','-g','custom']).strip(),
            'max_load1':8.,'workload':'local synthetic pages plus preserved S-real saved sidebar; active rendered-tab equivalence must be qualified',
            'arc_counts':arc_counts() if include_arc else None,'source_dirty':bool(command(['git','status','--porcelain','--','App','Packages','Engine']).strip())}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('browser',choices=['paired','arc','open']);p.add_argument('--state',choices=['S-real','S-empty'],default='S-real')
    p.add_argument('--out',type=Path,required=True);p.add_argument('--samples',type=int,default=7)
    p.add_argument('--groups',default='launch,memory,idle,page,disk');p.add_argument('--max-load',type=float,default=8)
    p.add_argument('--mode',choices=['measure','smoke','prepare','negative','negative-launch'],default='measure');p.add_argument('--worker')
    p.add_argument('--max-wait-seconds',type=int,default=3600)
    a=p.parse_args();a.groups=a.groups.split(',')
    if a.worker:return worker(a)
    if not PROBE.is_file():p.error('Compile tools/perf/probe.m into .re/perf/bin/probe first; runner never builds')
    if a.state=='S-empty' and a.browser in ('arc','paired'):p.error('Arc S-empty needs lead-approved isolation; never deletes M5 data')
    if a.mode=='prepare' and a.browser!='open':p.error('prepare imports Arc through Open only')
    if a.mode=='measure' and a.samples<7:p.error('Primary measurements require at least seven samples; use --mode smoke for preparation')
    if not 0<a.max_load<=10:p.error('load gate must be greater than zero and no greater than 10')
    if a.out.exists():p.error('output already exists; use a fresh path to preserve all attempts')
    run={'schema':1,'date':now(),'provenance':provenance(),'samples':[],'blocked':{
        'S-empty.arc':'Native Arc state isolation not established; M5 source preserved',
        'launch.warm_vs_cold':'Requires seven first-after-10-minute-quit pairs; process-cold immediate runs are labelled separately',
        'energy.idle_impact':'top power counter support not yet qualified',
        'bench.speedometer':'Benchmark auto-reporter not yet qualified',
        'bench.jetstream':'Benchmark auto-reporter not yet qualified',
        'bench.motionmark':'Benchmark auto-reporter not yet qualified'}}
    run['provenance']['max_load1']=a.max_load
    atomic(a.out,run);order=['arc','open'] if a.browser=='paired' else [a.browser]
    stopped=False
    max_rounds=2*a.samples if a.mode=='measure' else a.samples if a.mode=='negative-launch' else 1
    complete=False
    for index in range(max_rounds):
        for name in order:
            if probe('metadata')!=run['provenance']['display']:
                run['stop_reason']='display changed between samples; new Arc reference required';stopped=True;break
            directory=a.out.parent/(a.out.stem+'-samples')/f'{index:02}-{name}'
            wait_started=time.monotonic()
            while True:
                # Never hold any lock while waiting for machine load/priority.
                while os.getloadavg()[0]>a.max_load or Path('/tmp/open-onscreen-priority').exists():
                    if time.monotonic()-wait_started>a.max_wait_seconds:
                        run['stop_reason']='load/priority wait exceeded declared limit';stopped=True;break
                    print(f'WAIT no locks: load={os.getloadavg()} ceiling={a.max_load}',flush=True);time.sleep(5)
                if stopped:break
                args=[sys.executable,str(Path(__file__)),name,'--state',a.state,'--out',str(a.out),'--worker',str(directory),
                      '--mode',a.mode,'--groups',','.join(a.groups),'--max-load',str(a.max_load)]
                cmd=['/usr/bin/lockf','-k','-t','30','/tmp/open-onscreen-e2e.lock',*args]
                if os.environ.get('OPEN_HEAVY_HELD')!='1':
                    cmd=[str(Path.home()/'Library/Caches/OpenRE/scripts/heavy.sh'),*cmd]
                env=dict(os.environ,OPEN_PERF_LOCKED='1',OPEN_HEAVY_EXCLUSIVE='1')
                job=subprocess.run(cmd,env=env,check=False)
                path=directory/'sample.json'
                sample=json.loads(path.read_text()) if path.exists() else None
                if sample and not sample.get('gate_refused'):
                    run['samples'].append(sample);atomic(a.out,run)
                    if job.returncode:stopped=True;run['stop_reason']=sample.get('error','worker failed')
                    break
                if time.monotonic()-wait_started>a.max_wait_seconds:
                    run['stop_reason']='lock/load wait exceeded declared limit';stopped=True;break
                time.sleep(5)
            if stopped:break
        if stopped:break
        if a.mode=='measure':
            counts={name:{key[1]:v['summary']['n'] for key,v in metric_rows(run,name).items()} for name in order}
            run['valid_metric_counts']=counts;atomic(a.out,run)
            if all(counts[name] and min(counts[name].values())>=a.samples for name in order):
                complete=True;break
        else:complete=True
    if a.mode=='measure' and not complete and not stopped:
        stopped=True;run['stop_reason']='maximum rounds reached without seven valid samples per measured metric'
    run['end_date']=now();atomic(a.out,run)
    return 1 if stopped else 0

if __name__=='__main__':raise SystemExit(main())
