#!/usr/bin/env python3
"""Frozen M5 launch batch. No builds, no heavy token, no low-load waits."""
import argparse,datetime,hashlib,json,os,re,shutil,signal,statistics,subprocess,sys,tempfile,time,traceback
from pathlib import Path
BATCH_STARTED=float(os.environ.setdefault('S16_BATCH_START',str(time.time())))
REPO=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
p.add_argument('--artifacts',type=Path,required=True,help='Frozen batch directory with window-manifest.json')
p.add_argument('--window-end',type=float,help='Optional absolute Unix deadline; default is 44 minutes from start')
p.add_argument('--dry-run',action='store_true')
p.add_argument('--max-load',type=float,default=4.0,help='Maximum load1 before/after each sample (default: 4)')
p.add_argument('--quiet-held',action='store_true')
p.add_argument('--screen-held',action='store_true')
p.add_argument('--sample',type=int)
p.add_argument('--output',type=Path)
p.add_argument('--deadline',type=float)
a=p.parse_args()
BASE=a.artifacts.resolve()
MANIFEST=BASE/'window-manifest.json'
if not 0 < a.max_load <= 12: p.error("--max-load must be greater than 0 and at most 12")
os.environ['OPEN_ENGINE_ROOT']=str(Path.home()/'Developer/open-engine-s8-main')
cfg=json.loads(Path(os.environ.get('S16_BATCH_RUNTIME_MANIFEST',str(MANIFEST))).read_text())
def digest(path):
 h=hashlib.sha256()
 with Path(path).open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
 return h.hexdigest()
def load():return list(os.getloadavg())
def foreign_processes():
 rows=[]
 # Darwin's `comm` defaults to a truncated path; `command` is untruncated.
 for line in subprocess.check_output(['ps','-axo','pid=,comm=','-ww'],text=True).splitlines():
  fields=line.strip().split(None,1)
  if len(fields)!=2:continue
  pid,executable=int(fields[0]),fields[1]
  if pid==os.getpid():continue
  name=Path(executable).name
  if name in ('Open','xcodebuild','siso') or name.startswith('Open Helper'):
   rows.append({'pid':pid,'executable':executable})
 return rows
def check():
 baseline=set(json.loads(Path(os.environ['S16_CRASH_BASELINE_PATH']).read_text()))
 for path in (Path.home()/'Library/Logs/DiagnosticReports').glob('Open*.ips'):
  if path.name in baseline or not path.name.startswith(('Open-','Open Helper')):continue
  if re.search(r'"isSimulated"\s*:\s*1',path.read_text(errors='replace')):continue
  raise RuntimeError('STOP on-screen work; new real crash report: '+path.name)

def priority():
 f=Path('/tmp/open-onscreen-priority')
 return f.exists() and time.time()-f.stat().st_mtime<1800

def optional_update_ui():
 receipt=BASE.parent/'update-ui/A10-APP.txt'
 result={'receipt':str(receipt),'policy':'Optional final main/update-UI pair set x7; admitted only with at least 10 minutes left. Missing receipt skips without error.'}
 if not receipt.exists():return dict(result,status='SKIP: receipt missing at start')
 try:
  raw=receipt.read_text()
  try:info=json.loads(raw)
  except json.JSONDecodeError:info={}
  bundle=info.get('bundle') or info.get('app') or info.get('path') if isinstance(info,dict) else None
  if not bundle:
   match=re.search(r'(/[^\r\n`"\']+?\.app)(?:/Contents/MacOS/Open)?(?:[\r\n`"\']|$)',raw)
   if not match:raise ValueError('No .app path in receipt')
   bundle=match.group(1).strip()
  if str(bundle).endswith('/Contents/MacOS/Open'):bundle=str(bundle)[:-len('/Contents/MacOS/Open')]
  expected=info.get('sha256') or info.get('executable_sha256') if isinstance(info,dict) else None
  if not expected:
   matches=re.findall(r'(?im)^.*(?:executable|app|binary|sha.?256).*?\b([0-9a-f]{64})\b',raw)
   if not matches:matches=re.findall(r'(?i)\b([0-9a-f]{64})\b',raw)
   expected=next((v for v in matches if v==digest(Path(bundle)/'Contents/MacOS/Open')),None)
  assert expected and digest(Path(bundle)/'Contents/MacOS/Open')==expected,'Executable SHA-256 does not match receipt'
  engine=digest(Path(bundle)/'Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework')
  assert engine==cfg['variants']['main']['engine_sha256'],'Optional app has a different engine'
  sig=subprocess.run(['codesign','-dvv',str(bundle)],capture_output=True,text=True,check=True).stderr
  assert 'Signature=adhoc' in sig and not re.search(r'flags=.*runtime',sig),'Optional app is not safe ad-hoc Release'
  subprocess.run(['codesign','--verify','--deep','--strict',str(bundle)],capture_output=True,check=True)
  uuid=re.search(r'UUID: (\S+)',subprocess.check_output(['xcrun','dwarfdump','--uuid',str(Path(bundle)/'Contents/MacOS/Open')],text=True)).group(1).lower()
  for report in (Path.home()/'Library/Logs/DiagnosticReports').glob('Open-*.ips'):
   try:header=json.loads(report.open().readline())
   except (OSError,ValueError):continue
   assert header.get('slice_uuid','').lower()!=uuid or re.search(r'"isSimulated"\s*:\s*1',report.read_text(errors='replace')),'Optional build has a real crash report'
  cfg['variants']['update-ui']={'bundle':str(bundle),'executable':'Open','sha256':expected,'engine_sha256':engine,'optional':True,'macho_uuid':uuid} 
  cfg['optional_order']=['main','update-ui']
  return dict(result,status='AVAILABLE: final set x7 if 10 minutes remain',bundle=str(bundle),sha256=expected)
 except Exception as error:return dict(result,status='SKIP: invalid optional receipt/artifact',reason=str(error))

def plan_optional(remaining):
 cfg['primary_order']=[v for v in cfg['primary_order'] if v!='update-ui']
 if 'update-ui' not in cfg['variants']:return {'status':'SKIP: optional artifact unavailable'}
 estimate=(7*(len(cfg['primary_order'])+1+len(cfg['key_order'])))*10+120
 if remaining>=estimate:
  cfg['primary_order'].insert(cfg['primary_order'].index('main')+1,'update-ui')
  cfg['optional_order']=[]
  return {'status':'INLINE: main/update-UI adjacent x7 in primary set','estimated_seconds':estimate,'remaining_seconds':remaining}
 cfg['optional_order']=['main','update-ui']
 return {'status':'LAST: main/update-UI x7 only if ten minutes remain','estimated_seconds':estimate,'remaining_seconds':remaining}

def validate():
 assert not (BASE/'build-active').exists(),'Candidate builds still active'
 assert not (REPO/'.re/hold-on-screen').exists(),'Lead screen hold present'
 assert cfg['samples']==7
 engines=set()
 for name,v in cfg['variants'].items():
  app=Path(v['bundle']);exe=app/'Contents/MacOS'/v['executable']
  assert exe.is_file(),str(exe)
  assert digest(exe)==v['sha256'],'Executable hash mismatch: '+name
  sig=subprocess.run(['codesign','-dvv',str(app)],capture_output=True,text=True,check=True).stderr
  assert 'Signature=adhoc' in sig and not re.search(r'flags=.*runtime',sig),'Unsafe signature: '+name
  subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True,check=True)
  if not v.get('floor'):
   engine=app/'Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework'
   assert digest(engine)==v['engine_sha256'],'Engine hash mismatch: '+name
   engines.add(v['engine_sha256'])
 assert len(engines)==1,'Mixed engine cohort'
 known={v.get('macho_uuid') for v in cfg['variants'].values() if v.get('macho_uuid')}
 for report in (Path.home()/'Library/Logs/DiagnosticReports').glob('Open-*.ips'):
  try:header=json.loads(report.open().readline())
  except (OSError,ValueError):continue
  if header.get('slice_uuid','').lower() in known:
   assert re.search(r'"isSimulated"\s*:\s*1',report.read_text(errors='replace')),'Frozen candidate has a real crash report; never retry: '+report.name
 for helper in cfg['helpers']:
  assert digest(helper['path'])==helper['sha256'],'Helper hash mismatch'
  assert Path(helper['path']).stat().st_mtime>=Path(helper['source']).stat().st_mtime,'Helper would compile during timing'
 for src in cfg['driver_sources']:
  assert digest(src['path'])==src['sha256'],'Harness changed after freeze: '+src['path']
 assert digest(cfg['profile_recipe'])==cfg['profile_recipe_sha256'],'Profile recipe changed'
 assert cfg['floor_links']==cfg['main_links'],'Floor matched links differ from exact main'
 return {'paths_hashes_signatures':'PASS','same_engine':'PASS','load':load(),'foreign_processes':foreign_processes()}

def command(*flags):
 return [sys.executable,str(Path(__file__).resolve()),'--artifacts',str(BASE),'--output',str(a.output),'--deadline',str(a.deadline),'--max-load',str(a.max_load),*flags]

def summary(out):
 rows=json.loads((out/'samples.json').read_text()) if (out/'samples.json').exists() else []
 groups={}
 for row in rows:
  if not row.get('valid_load'):continue
  k=row['set']+'/'+row['variant'];groups.setdefault(k,[]).append(row)
 results={}
 lines=['| Set / variant | n | Sidebar median ms (samples) | Paint median ms (samples) | Key accepted median ms (samples) | load1 before → after (all samples) |',
 '|---|---:|---|---|---|---|']
 def values(rs,key):return [r['timing'][key] for r in rs if isinstance(r['timing'].get(key),(int,float))]
 def cell(v):return '—' if not v else f'{statistics.median(v):.2f} ('+', '.join(f'{x:.2f}' for x in v)+')'
 for k,rs in groups.items():
  side=values(rs,'sidebarDrawn');paint=values(rs,'firstContentfulPaint')
  key=values(rs,'keyAccepted');gap=[r['timing']['keyAccepted']-r['timing']['sidebarDrawn'] for r in rs if 'keyAccepted' in r['timing']]
  results[k]={'count':len(rs),'median_sidebar':statistics.median(side) if side else None,'median_paint':statistics.median(paint) if paint else None,
   'median_key':statistics.median(key) if key else None,'median_frame_to_key':statistics.median(gap) if gap else None}
  loads=', '.join(f"{r['load_before'][0]:.2f}→{r['load_after'][0]:.2f}" for r in rs)
  lines.append(f'| {k} | {len(rs)} | {cell(side)} | {cell(paint)} | {cell(key)} | {loads} |')
 gains={}
 branch=results.get('primary/branch',{})
 for name in cfg['primary_order']:
  control=results.get('primary/'+name,{})
  if name not in ('floor','floor-links','branch') and control.get('median_sidebar') is not None and branch.get('median_sidebar') is not None:
   gains[name]={'sidebar_gain_ms':control['median_sidebar']-branch['median_sidebar'],
    'branch_paint_minus_control_ms':branch['median_paint']-control['median_paint'] if branch.get('median_paint') is not None and control.get('median_paint') is not None else None}
 data={'gains_vs_branch':gains,'origin':'kernel ri_proc_start_abstime, translated to mach_continuous_time','frame':'CADisplayLink.timestamp >= post-flush CACurrentMediaTime',
  'manifest':cfg,'medians':results,'rows':rows,'elapsed_seconds':time.time()-BATCH_STARTED,'max_load':a.max_load}
 (out/'results.json').write_text(json.dumps(data,indent=2))
 (out/'TABLE.md').write_text('\n'.join(lines)+'\n')

if a.sample is None and not a.quiet_held:
 optional=optional_update_ui()
 result=validate();result['optional_update_ui']=optional
 result['optional_plan']=plan_optional(44*60-(time.time()-BATCH_STARTED))
 if a.dry_run:
  lock_results={}
  for lock in ('/tmp/open-m5-quiet.lock','/tmp/open-onscreen-e2e.lock'):
   r=subprocess.run(['/usr/bin/lockf','-k','-t','0',lock,'/usr/bin/true'],capture_output=True,text=True)
   lock_results[lock]={'exit':r.returncode,'state':'acquired and released' if r.returncode==0 else 'busy; command will refuse to wait under another lock','stderr':r.stderr.strip()}
  result.update(mode='DRY RUN: NO APP LAUNCHES',locks=lock_results,variants=list(cfg['variants']),planned_launches=7*(len(cfg['primary_order'])+len(cfg['key_order'])))
  (BASE/'window-dry-run.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));raise SystemExit(0)
 (BASE/'window-last-start-check.json').write_text(json.dumps(result,indent=2))
 assert not result['foreign_processes'],'Other Open/xcodebuild/siso process at start: '+repr(result['foreign_processes'])
 assert result['load'][0]<=a.max_load,f'Start load1 > {a.max_load}; nothing launched'
 assert not priority(),'Foreign screen priority present; nothing launched'
 now=datetime.datetime.now()
 a.deadline=min(BATCH_STARTED+44*60,a.window_end-60 if a.window_end else float('inf'))
 assert a.deadline>time.time()+120,'Insufficient time remains before window end'
 a.output=a.output or BASE/('quiet-'+now.strftime('%Y%m%d-%H%M%S'))
 a.output.mkdir(parents=True,exist_ok=False)
 result['optional_plan']=plan_optional(a.deadline-time.time())
 (a.output/'preflight.json').write_text(json.dumps(result,indent=2))
 # AF_UNIX includes the entire user-data path and has a 104-byte ceiling.
 # Keep setup and sample profiles short even when raw logs use a long path.
 cfg['profile_workdir']=tempfile.mkdtemp(prefix='s16p-',dir='/tmp')
 cfg['profile_seed']=str(Path(cfg['profile_workdir'])/'seed')
 assert len(os.fsencode(str(Path(cfg['profile_seed'])/'automation.sock')))<104
 runtime=a.output/'frozen-runtime-manifest.json';runtime.write_text(json.dumps(cfg,indent=2))
 os.environ['S16_BATCH_RUNTIME_MANIFEST']=str(runtime)
 # The lead invokes this command after clearing the screen in the granted
 # window. Preserve all existing reports as history; abort on any new real
 # Open/Helper crash from this point. Never relaunch a failed candidate.
 crash_baseline=a.output/'crash-baseline.json'
 crash_baseline.write_text(json.dumps(sorted(p.name for p in (Path.home()/'Library/Logs/DiagnosticReports').glob('Open*.ips')),indent=2))
 os.environ['S16_CRASH_BASELINE_PATH']=str(crash_baseline)
 # Queue blocking for quiet, but bound queue time by the 45 minute total.
 job=subprocess.Popen(['/usr/bin/lockf','-k','-t','30','/tmp/open-m5-quiet.lock',*command('--quiet-held')],start_new_session=True)
 try:
  rc=job.wait(timeout=max(1,a.deadline-time.time()))
 except subprocess.TimeoutExpired:
  # Keep the whole command inside 45 minutes, including cleanup. Only this
  # owned group is signalled; App owner-watch and harness finally paths quit
  # LaunchServices children when their owning sample exits.
  os.killpg(job.pid,signal.SIGTERM)
  try:job.wait(timeout=20)
  except subprocess.TimeoutExpired:
   os.killpg(job.pid,signal.SIGKILL);job.wait(timeout=5)
  rc=76
  (a.output/'deadline.json').write_text(json.dumps({'status':'45 minute deadline; owned driver stopped','load':load()}))
 shutil.rmtree(cfg['profile_workdir'],ignore_errors=True)
 summary(a.output)
 print('Batch exit',rc,'results',a.output,flush=True);raise SystemExit(rc)

assert a.output and a.deadline
if a.sample is None and a.quiet_held and not a.screen_held:
 assert time.time()<a.deadline
 assert load()[0]<=a.max_load,f'Load1 > {a.max_load} after quiet acquisition: released without waiting'
 assert not foreign_processes(),'Other Open/xcodebuild/siso after quiet acquisition'
 assert not priority(),'Screen priority present'
 # One screen set for the primary launches, then a separate key set. Each
 # acquisition is nonblocking; no quiet lock can be held through a screen wait.
 for which in ('primary','key','optional'):
  if which=='optional':
   status={'status':'SKIP: receipt missing or less than 10 minutes left','remaining_seconds':a.deadline-time.time()}
   if not cfg.get('optional_order') or a.deadline-time.time()<10*60:
    (a.output/'optional-update-ui.json').write_text(json.dumps(status,indent=2));continue
   (a.output/'optional-update-ui.json').write_text(json.dumps({'status':'RUN: main/update-UI x7, paint and sidebar only','remaining_seconds':a.deadline-time.time()},indent=2))
  os.environ['S16_BATCH_SET']=which
  rc=subprocess.call(['/usr/bin/lockf','-k','-t','0','/tmp/open-onscreen-e2e.lock',*command('--quiet-held','--screen-held')])
  summary(a.output)
  if rc:raise SystemExit(rc)
 print((a.output/'TABLE.md').read_text(),flush=True)
 raise SystemExit(0)

which=os.environ['S16_BATCH_SET']
order=cfg['primary_order'] if which=='primary' else cfg['key_order'] if which=='key' else cfg['optional_order']
if a.sample is None:
 assert load()[0]<=a.max_load,f'Load1 > {a.max_load}: release screen and quiet immediately'
 if which=='primary':
  # One declared fixture setup, outside all measured samples. This restores
  # the existing-profile path for every measured launch without a launch
  # during the preparation/dry run while the M5 screen is held.
  check()
  sys.path.insert(0,str(REPO/'tools/e2e'));import engine_e2e as e
  recipe=json.loads(Path(cfg['profile_recipe']).read_text())
  seed=Path(cfg['profile_seed']);before=load()
  app=e.Open('Release','chrome',str(seed),[],str(a.output/'profile-setup.log'),urls=(recipe['selected_url'],),extra_env={'OPEN_E2E_APP_BUNDLE':cfg['variants']['main']['bundle'],'OPEN_SPEED_TRACE':'0','OPEN_SPEED_KEY_PROBE':'0','OPEN_SPEED_IMAGES':'0'})
  try:
   actual=subprocess.check_output(['/bin/ps','-ww','-p',str(app.pid),'-o','comm='],text=True).strip()
   assert os.path.realpath(actual)==os.path.realpath(str(Path(cfg['variants']['main']['bundle'])/'Contents/MacOS/Open')),actual
   tab=app.call('tabs',timeout=15)[0];app.call('wait',tab=tab['id'],timeout=15)
   app.call('open',url=recipe['unselected_url'],timeout=15)
   app.call('select',tab=tab['id'],timeout=15);app.call('save',timeout=15)
  finally:
   app.quit();assert app.quit_report['ok'],app.quit_report
  (a.output/'profile-setup.json').write_text(json.dumps({'status':'unmeasured synthetic existing-profile setup','recipe_sha256':cfg['profile_recipe_sha256'],'actual_executable':actual,'cleanup':app.quit_report,'load_before':before,'load_after':load()},indent=2))
  check()
 for index,name in enumerate([v for _ in range(7) for v in order]):
  assert time.time()<a.deadline-120,'45 minute batch deadline'
  assert load()[0]<=a.max_load,f'Load1 > {a.max_load}: release all locks immediately'
  assert not foreign_processes(),'Unexpected Open/build process between launches'
  os.environ['S16_BATCH_VARIANT']=name
  rc=subprocess.call(command('--quiet-held','--screen-held','--sample',str(index)))
  summary(a.output)
  if rc:raise SystemExit(rc)
 raise SystemExit(0)

check()
sys.path.insert(0,str(REPO/'tools/e2e'))
import engine_e2e as e
# Bound every call, including launch wait and cleanup, within the batch deadline.
def expired(*_):raise TimeoutError('Per-sample / whole-batch deadline')
signal.signal(signal.SIGALRM,expired)
signal.alarm(max(1,min(90,int(a.deadline-time.time()))))
name=os.environ['S16_BATCH_VARIANT'];v=cfg['variants'][name]
log=a.output/f'{which}-{a.sample:03}-{name}.log'
row={'set':which,'index':a.sample,'variant':name,'load_before':load()}
assert row['load_before'][0]<=a.max_load,f'Load1 rose above {a.max_load} before launch: release locks immediately'
if v.get('floor'):
 r=subprocess.run(['/usr/bin/open','-n','-W','-a',v['bundle'],'--env','OPEN_SPEED_IMAGES=0','--stdout',str(log),'--stderr',str(log)],capture_output=True,text=True,timeout=20)
 reports=[]
 for line in log.read_text().splitlines() if log.exists() else []:
  try:x=json.loads(line)
  except json.JSONDecodeError:continue
  if isinstance(x,dict) and 'firstFrameConfirmed' in x:reports.append(x)
 assert len(reports)==1,'Missing floor receipt'
 report=reports[0];assert report['kernelProcessStart'] and report['firstFrameConfirmed']
 assert os.path.realpath(report['executable'])==os.path.realpath(str(Path(v['bundle'])/'Contents/MacOS/Floor'))
 for _ in range(50):
  try:os.kill(report['pid'],0)
  except ProcessLookupError:break
  time.sleep(.1)
 else:raise RuntimeError('Floor PID still alive after 5 s')
 windows=json.loads(subprocess.check_output([str(REPO/'.re/e2e-tools/owned-window-count'),str(report['pid'])],text=True))
 assert windows['count']==0
 row.update(timing=report['timing'],receipt=report,launcher_exit=r.returncode,cleanup={'ok':True,'windows':windows})
else:
 profile=Path(cfg['profile_workdir'])/f'{which}-{a.sample:03}'
 assert len(os.fsencode(str(profile/'automation.sock')))<104
 subprocess.run(['cp','-cR',cfg['profile_seed'],str(profile)],check=True)
 env={'OPEN_E2E_APP_BUNDLE':v['bundle'],'OPEN_SPEED_TRACE':'0','OPEN_SPEED_IMAGES':'0','OPEN_SPEED_MENU_PROBE':'0',
 'OPEN_SPEED_EARLY_MENU_PROBE':'0','OPEN_SPEED_KEY_PROBE':'1' if which=='key' else '0'}
 app=None
 try:
  app=e.Open('Release','chrome',str(profile),[],str(log),urls=(),extra_env=env)
  actual=subprocess.check_output(['/bin/ps','-ww','-p',str(app.pid),'-o','comm='],text=True).strip()
  assert os.path.realpath(actual)==os.path.realpath(str(Path(v['bundle'])/'Contents/MacOS/Open')),actual
  row['actual_executable']=actual
  tab=next(t for t in app.call('tabs',timeout=15) if t['selected'])
  app.call('wait',tab=tab['id'],timeout=15)
  e.wait_until(lambda:'firstContentfulPaint' in app.call('timing',timeout=15),timeout=10,step=.05)
  if which=='key':e.wait_until(lambda:'keyAccepted' in app.call('timing',timeout=15) or 'keyRejected' in app.call('timing',timeout=15),timeout=10,step=.05)
  timing=app.call('timing',timeout=15)
  assert timing['kernelProcessStart'] and timing['firstFrameConfirmed']
  assert timing['sidebarDrawn']<=timing['engineStart']
  assert len([t for t in app.call('tabs',timeout=15) if t['loaded']])==1
  startup=app.call('startup',timeout=15)
  assert startup['pagesBeforeEngine']==0 and startup['contextsBeforeEngine']==0
  if which=='key':
   assert 'keyAccepted' in timing and 'keyRejected' not in timing
   assert app.call('commandbar-state',timeout=15).get('presented')
  row.update(timing=timing,startup=startup,pid=app.pid,activation=app.call('activation-events',timeout=15),raw_launch_log=app.launch_log_path)
 finally:
  if app:
   app.quit();assert app.quit_report['ok'],app.quit_report
   row['cleanup']=app.quit_report
 shutil.rmtree(profile)
signal.alarm(0)
check()
row['load_after']=load();row['valid_load']=max(row['load_before'][0],row['load_after'][0])<=a.max_load
rowsfile=a.output/'samples.json';rows=json.loads(rowsfile.read_text()) if rowsfile.exists() else []
rows.append(row);rowsfile.write_text(json.dumps(rows,indent=2))
summary(a.output)
print(json.dumps({'set':which,'variant':name,'timing':row['timing'],'load_before':row['load_before'],'load_after':row['load_after']}),flush=True)
if not row['valid_load']:raise SystemExit(f'Load1 rose above {a.max_load}: locks released; sample retained and flagged invalid')
