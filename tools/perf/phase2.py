#!/usr/bin/env python3
"""Exclusive interleaved app-scoped Phase 2 measurements; raw data stays private."""
import argparse
import contextlib
import copy
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import traceback
from urllib.parse import urlencode

from campaign import import_view
from frame_client import Frames, arc_input, ticks, socket_boundary, TICK_SECONDS
from phase2_input import (ax, walk, rect, center, find, largest, synthetic_tab,
                          click_arc, web_rect, scroll_script, dispatch_scroll)
from run import (ROOT, ARC, ARC_DATA, OPEN, BASE, PLANS, Browser, atomic, now, probe,
                 provenance, sha, version, arc_core, existing_pids, guard,
                 prepare_real, metric)
from server import Collector, CollectorClient
from score import summarize, metric_rows
from campaign import MAIN_DELTA
from display import displays_match

DEFAULT_KEYS=['SUEnableAutomaticChecks','SUAutomaticallyUpdate','openExternalLinksInLittleBrowserEnabled']

def defaults_apply(out):
    receipt={'date':now(),'authorization':'LEAD 15:00; user route override 15:20','originals':{}}
    for key in DEFAULT_KEYS:
        p=subprocess.run(['/usr/bin/defaults','read','company.thebrowser.Browser',key],capture_output=True,text=True)
        receipt['originals'][key]={'present':p.returncode==0,'value':p.stdout.strip() if not p.returncode else None}
        if not p.returncode:raise RuntimeError('Arc default is no longer absent; no preference changed')
    atomic(Path(out)/'defaults-originals.json',receipt)
    for key in DEFAULT_KEYS:subprocess.run(['/usr/bin/defaults','write','company.thebrowser.Browser',key,'-bool','false'],check=True)
    return receipt

def defaults_restore(out,receipt):
    if not receipt:return
    result={'date':now(),'keys':{}}
    for key in receipt['originals']:
        subprocess.run(['/usr/bin/defaults','delete','company.thebrowser.Browser',key],capture_output=True,text=True)
        p=subprocess.run(['/usr/bin/defaults','read','company.thebrowser.Browser',key],capture_output=True,text=True)
        result['keys'][key]=p.returncode!=0
    result['ok']=all(result['keys'].values());atomic(Path(out)/'defaults-restored.json',result)
    if not result['ok']:raise RuntimeError('Arc preference restoration failed')

def owned_bounds(b):
    return max((w for w in probe('windows') if w['pid']==b.pid),key=lambda w:w['bounds'][2]*w['bounds'][3])['bounds']

def key(b,name,mods=()):
    guard(b.baseline)
    if b.name=='arc':return arc_input(b.pid,'key',name,','.join(mods))
    windows=b.call('windows');focused=next((w['number'] for w in windows if w.get('key')),None)
    dispatched=socket_boundary()
    result=b.call('key',key=name,modifiers=list(mods),**({'window':focused} if focused else {}))
    result['socket_dispatch_ticks']=dispatched
    if 'ctrl' in mods and name!='control':
        b.call('key',key='control',modifiers=[],**({'window':focused} if focused else {}))
    return result

def text(b,value):
    if b.name=='arc':return arc_input(b.pid,'type',value)
    focused=next((w['number'] for w in b.call('windows') if w.get('key')),None)
    dispatched=socket_boundary();result=b.call('key',text=value,**({'window':focused} if focused else {}))
    result['socket_dispatch_ticks']=dispatched
    return result

def native_click(b,point,mods=()):
    guard(b.baseline)
    if b.name=='arc':
        bounds=owned_bounds(b)
        if not (bounds[0]<=point[0]<bounds[0]+bounds[2] and bounds[1]<=point[1]<bounds[1]+bounds[3]):
            raise RuntimeError('Arc AX point is outside the owned visible window')
        return arc_input(b.pid,'click',*point,'left',1,','.join(mods))
    bounds=owned_bounds(b)
    return b.call('mouse',action='click',x=point[0]-bounds[0],y=point[1]-bounds[1],modifiers=list(mods))

def selected_tab(b):return next(t for t in b.call('tabs') if t.get('selected'))

def verify_selected(b,target,variant,out):
    if b.name=='open':
        if selected_tab(b)['id']!=target:raise RuntimeError('Wrong synthetic tab selected: '+variant)
    else:
        title=f'Perf local {variant} {target}'
        tree=ax(b,out,'selected-'+variant,depth=0)
        if not any(title in str(n.get('title','')) for n in walk(tree) if n.get('role')=='AXWindow'):
            raise RuntimeError('Arc did not select the expected synthetic tab: '+variant)

def navigate(b,url,token):
    if b.name=='arc':subprocess.run(['/usr/bin/open','-a',str(ARC),url],check=True)
    else:b.call('open',url=url)
    row=b.collector.wait(token,visible=True,after_wall_ms=b.launch['birth_wall_seconds']*1000)
    guard(b.baseline)
    return row

def scene(b,out,variant='A',suffix=''):
    token=f'p2-{b.run_id}-{b.task}-{b.round_index}-{variant}{suffix}'
    b.scene_tokens[variant+suffix]=token
    url=b.origin+'/interaction.html?'+urlencode({'run':token,'variant':variant})
    if b.route:url+='&'+b.route
    b.last_page=navigate(b,url,token);time.sleep(.15)
    if b.name=='open':return selected_tab(b)['id']
    return token

def content_region(b,out,label='content'):
    tree=ax(b,out,label,web='frame') if b.name=='arc' else None
    r=web_rect(b,tree)
    return [r[0]+50,r[1]+150,250,200],r,tree

def sidebar_region(b,out,label):
    tree=ax(b,out,label,web='frame' if b.name=='arc' else False);web=web_rect(b,tree)
    bounds=owned_bounds(b)
    areas=[n for n in walk(tree) if n.get('role')=='AXScrollArea' and n.get('frame') and
           n['frame'][2]>50 and n['frame'][3]>100 and n['frame'][0]+n['frame'][2]<=web[0]+8]
    if not areas:raise RuntimeError('Native sidebar scroll area missing')
    visible=[]
    for area in areas:
        x,y,w,h=rect(area);bx,by,bw,bh=bounds
        left,top=max(x,bx),max(y,by)
        right,bottom=min(x+w,bx+bw),min(y+h,by+bh)
        if right-left>40 and bottom-top>100:visible.append([left,top,right-left,bottom-top])
    if not visible:raise RuntimeError('Native sidebar has no visible AX region')
    r=max(visible,key=lambda r:r[2]*r[3])
    return r,[r[0]+r[2]/2,r[1]+r[3]/2],tree

def arc_command_url(b,url):
    key(b,'t',['cmd']);time.sleep(.3)
    tree=ax(b,b.out,'navigation-bar',depth=12)
    fields=[n for n in walk(tree) if n.get('role') in ('AXTextField','AXComboBox') and n.get('frame') and
            n['frame'][1]>owned_bounds(b)[1]+100 and n['frame'][3]>5]
    if not fields:
        raise RuntimeError('Arc navigation command field did not become ready')
    native_click(b,center(max(fields,key=lambda n:n['frame'][2])))
    key(b,'a',['cmd']);arc_input(b.pid,'type',url);time.sleep(.25)
    end=time.monotonic()+3;matched=False;attempt=0
    while time.monotonic()<end:
        typed=ax(b,b.out,f'navigation-typed-{attempt}',depth=12);attempt+=1
        if any(n.get('role') in ('AXTextField','AXComboBox') and n.get('value')==url for n in walk(typed)):
            matched=True;break
        time.sleep(.1)
    if not matched:
        raise RuntimeError('Arc command field did not contain the complete navigation URL')
    key(b,'return')

def open_in_current_space(b,url,token):
    if b.name=='open':b.call('open',url=url)
    else:arc_command_url(b,url)
    return b.collector.wait(token,visible=True,after_wall_ms=b.launch['birth_wall_seconds']*1000)

def debug_page_control(b,out,label,navigate=True):
    if navigate:arc_command_url(b,'chrome://chrome-urls/');time.sleep(.5)
    for attempt in range(5):
        tree=ax(b,out,f'{label}-{attempt}',depth=30,web=True)
        buttons=[n for n in walk(tree) if n.get('role')=='AXButton' and
                 n.get('title') in ('Enable internal debugging pages','Disable internal debugging pages') and n.get('frame')]
        if len(buttons)!=1:raise RuntimeError('Internal debugging toggle is missing or ambiguous')
        button=buttons[0];bounds=owned_bounds(b);x,y,w,h=rect(button);point=center(button)
        if h>=10 and bounds[0]<=point[0]<bounds[0]+bounds[2] and bounds[1]<=point[1]<bounds[1]+bounds[3]:
            return button
        web=web_rect(b,tree);point=[web[0]+web[2]/2,web[1]+web[3]/2]
        dispatch_scroll(b,scroll_script(point,0,-12,duration=350),out,f'{label}-reveal-{attempt}',bounds)
        time.sleep(.15)
    raise RuntimeError('Internal debugging toggle could not be revealed inside the owned window')

def enable_debug_pages(b,out,row):
    button=debug_page_control(b,out,'debug-original')
    receipt={'authorization':'User 2026-11-11 06:14; temporary enable and restoration',
             'original_enabled':button['title']=='Disable internal debugging pages','date':now(),
             'next_launch_verification':'Disabled state checked at this launch before enable, per LEAD 06:20'}
    row['debug_pages_override']=receipt;atomic(Path(out)/'debug-pages-original.json',receipt)
    if receipt['original_enabled']:raise RuntimeError('Internal debugging original state is no longer disabled; no setting changed')
    # Set the restoration obligation before dispatch, including partial failures.
    b.debug_pages_restore_required=True
    native_click(b,center(button));time.sleep(.2)
    confirmed=debug_page_control(b,out,'debug-enabled',navigate=False)
    if confirmed['title']!='Disable internal debugging pages':raise RuntimeError('Internal debugging enable was not confirmed')
    receipt['enabled_confirmed']=True;atomic(Path(out)/'debug-pages-original.json',receipt)
    key(b,'w',['cmd']);time.sleep(.2)

def restore_debug_pages(b,out):
    button=debug_page_control(b,out,'debug-restore-before')
    if button['title']=='Disable internal debugging pages':native_click(b,center(button));time.sleep(.2)
    confirmed=debug_page_control(b,out,'debug-restored',navigate=False)
    ok=confirmed['title']=='Enable internal debugging pages'
    atomic(Path(out)/'debug-pages-restored.json',{'date':now(),'original_enabled':False,'enabled_after':not ok,'ok':ok})
    if not ok:raise RuntimeError('Internal debugging pages did not restore to disabled')
    key(b,'w',['cmd']);time.sleep(.2)

def prepare_neighbor(b,out):
    key(b,'right',['cmd','opt']);time.sleep(.4)
    token=f'p2n-{b.run_id[-8:]}-{b.round_index}'
    url=b.origin+'/interaction.html?'+urlencode({'run':token,'variant':'A'})
    open_in_current_space(b,url,token)
    key(b,'left',['cmd','opt']);time.sleep(.4)

def changed(row):
    if 'first_changed_ms' not in row:raise RuntimeError('Target did not visibly respond: '+row['label'])
    if not 0<=row['first_changed_ms']<=5000:raise RuntimeError('Invalid visual response time')
    return row['first_changed_ms']

def measure_metric(b,f,out,metrics,name,roi,action,duration=1100,field='first_changed_ms',target=None,hidden_before_input=False):
    guard(b.baseline)
    live_socket=b.name=='open' and name.startswith('ui.') and name!='ui.peek_open_ms'
    row=f.measure(name,roi,action,duration=duration,target_signature=target,live_socket=live_socket)
    if hidden_before_input:
        row['hidden_precondition_verified']=True
        row['cached_baseline_matches_target_while_hidden']=row.get('armed_baseline_signature')==target
        atomic(f.out/(name+'.json'),row)
    if target and row.get('armed_baseline_signature')==target and not hidden_before_input:
        raise RuntimeError('Target content was already visible before the measured action: '+name)
    if field=='first_changed_ms':value=changed(row)
    else:
        if field not in row:raise RuntimeError('Expected final content did not appear: '+name)
        value=row[field]
    metric(metrics,name,value,'ms')
    if getattr(b,'fail_after_metric',None)==name:raise RuntimeError('Injected failure after '+name)
    return row

def worker(cfg):
    from run import background_jobs
    out=Path(cfg['out']);out.mkdir(parents=True,exist_ok=False)
    open_only=cfg.get('open_only',False)
    calibration=cfg.get('calibration_only',False)
    if open_only and cfg['browser']!='open':raise RuntimeError('Open-only replay cannot launch Arc')
    row={'date':now(),'browser':cfg['browser'],'state':'S-real','task':cfg['task'],
         'input_boundary_version':2,
         'round_index':cfg['index'],'metrics':{},'valid':False,'load_before':list(os.getloadavg()),
         'commit':cfg['provenance']['commit'],'app_main_sha256':cfg['provenance']['app_main_sha256'],
         'arc_version_before':None if open_only else version(False),
         'arc_core_before':None if open_only else arc_core(),'display_before':probe('metadata')}
    row['background_jobs_before']=background_jobs()
    row['qualification']=('under load, not for scoring' if row['background_jobs_before'] or
        row['load_before'][0]>cfg['provenance'].get('max_load1',10) else 'unscored functional calibration') if calibration else 'scored'
    atomic(out/'sample.json',row)
    if os.environ.get('OPEN_HEAVY_HELD')!='1':raise RuntimeError('Exclusive queue slot missing')
    if existing_pids(ARC) or existing_pids(OPEN):
        row['foreign_browser']=True;atomic(out/'sample.json',row);return 76
    if row['background_jobs_before'] and not calibration:
        row['error']='Background build invalidates score measurements';atomic(out/'sample.json',row);return 1
    max_load=cfg['provenance'].get('max_load1',10)
    if cfg.get('quiet_pair'):
        from profile_state import quiet_pair
        row['quiet_readings'],quiet=quiet_pair(max_load)
        if not quiet:
            row['gate_refused']=True;atomic(out/'sample.json',row);return 75
        if existing_pids(ARC) or existing_pids(OPEN):
            row['foreign_browser']=True;atomic(out/'sample.json',row);return 76
    if not calibration and os.getloadavg()[0]>max_load:row['gate_refused']=True;atomic(out/'sample.json',row);return 75
    expected=cfg['provenance']
    for name,digest in expected['measurement_helpers'].items():
        if sha(ROOT/'.re/perf/bin'/name)!=digest:raise RuntimeError('Measurement helper changed: '+name)
    for path,digest_key in [(OPEN/'Contents/MacOS/Open','app_main_sha256'),(OPEN/'Contents/Frameworks/OpenEngine.framework/Versions/A/OpenEngine','engine_sha256')]:
        if sha(path)!=expected[digest_key]:raise RuntimeError('Frozen Open artifact changed')
    if not displays_match(expected['display'],row['display_before']) or (not open_only and
        (row['arc_core_before']!=expected['arc_core'] or row['arc_version_before']!=expected['arc_version'])):
        raise RuntimeError('Session provenance changed')
    root=Path(cfg['root']);c=CollectorClient(cfg['collector']);b=Browser(cfg['browser'],root,out,c,'phase2')
    b.round_index=cfg['index'];b.task=cfg['task'];b.origin=cfg['origin'];b.route=cfg.get('route','')
    b.space_transition_route=cfg['provenance']['space_transition_route']
    b.run_id=cfg['provenance']['phase2_run_id'];b.scene_tokens={}
    b.metric_filter=cfg.get('metric_filter',[])
    b.fail_after_metric=cfg.get('fail_after_metric')
    b.app_cadence=cfg.get('app_cadence',False)
    f=None;prefs=None
    try:
        if cfg['browser']=='arc':
            # Import inside this same hold, then preserve the paired Open start.
            imported=Browser('open',root,out/'import',c,'import');imported.out.mkdir()
            try:
                directory=import_view(imported.out)
                row['import_counts']=prepare_real(imported,directory,normalize=True)
                # The existing local routing rule chooses this main Space in
                # Arc. Keep the imported Open start on that same saved Space.
                matched=False
                for space in imported.call('spaces'):
                    imported.call('space',space=space['id'])
                    target=next((t for t in imported.call('tabs') if str(t.get('url','')).startswith(b.origin+'/report.html?run=startup')),None)
                    if target:imported.call('select',tab=target['id']);matched=True;break
                if not matched:raise RuntimeError('Imported local main-Space route is missing')
            finally:imported.stop()
            shutil.copytree(root,Path(cfg['snapshot']),ignore=shutil.ignore_patterns('automation.sock'))
            prefs=defaults_apply(out)
        b.start();probe('unhide',b.pid)
        if b.name=='arc':
            local=json.loads((ARC_DATA/'User Data/Local State').read_text())
            row['debug_pages_at_launch']={'preference':'internal_only_uis_enabled',
                'enabled':local.get('internal_only_uis_enabled',False),'date':now(),
                'verification':'Read stored state after launch, before any override; LEAD 06:20'}
            if row['debug_pages_at_launch']['enabled'] is not False:
                raise RuntimeError('Internal debugging setting was not disabled at the next launch; stop Arc sessions')
        if b.name=='open' and cfg.get('frame'):b.call('window-frame',frame=cfg['frame'],unconstrained=True)
        b.input_started=time.monotonic()
        # All measured content is synthetic. The saved sidebar is the matched
        # real import; no private title is exported from AX receipts.
        task=cfg['task']
        a=scene(b,out,'A');bb=scene(b,out,'B')
        row['workload_page']=b.last_page;row['window_bounds']=owned_bounds(b)
        if b.name=='open' and cfg.get('viewport'):
            width,height=cfg['viewport'];actual=[b.last_page['viewport_width'],b.last_page['viewport_height']]
            state=b.call('window-state');frame=state['frame']
            frame[2]+=width-actual[0];frame[3]+=height-actual[1]
            b.call('window-frame',frame=frame,unconstrained=True)
            end=time.monotonic()+3
            while time.monotonic()<end:
                actual=json.loads(b.call('eval',js='JSON.stringify([innerWidth,innerHeight])'))
                if actual==[width,height]:break
                time.sleep(.05)
            row['matched_viewport']={'target':[width,height],'actual':actual}
            if actual!=[width,height]:raise RuntimeError('Phase 2 viewport did not match Arc')
        row['window_bounds']=owned_bounds(b)
        f=Frames(b.pid,expected['display']['screens'][0]['id'],out/'frames',resolution_ms=cfg['provenance']['detector']['resolution_ms'])
        row['route']='Arc system CGEvent / Open own-window socket dispatch'
        if task=='explore':
            ax(b,out,'scene',depth=30)
            display=expected['display']['screens'][0];screen=[0,0,display['width'],display['height']]
            row['surface_probe']={}
            for label,name,mods in [('settings',',',['cmd']),('close-settings','w',['cmd']),
                                    ('library','l',['cmd','shift']),('close-library','w',['cmd']),('new-window','n',['cmd'])]:
                result=f.measure(label,screen,lambda name=name,mods=mods:key(b,name,mods),duration=4500 if label=='settings' else 1600)
                row['surface_probe'][label]={'first_changed_ms':result.get('first_changed_ms'),
                    'windows':[w for w in probe('windows') if w['pid']==b.pid]}
                ax(b,out,label,depth=3)
        elif task=='discard-controls':
            if b.name!='arc':raise RuntimeError('Read-only discard control exploration is Arc-only')
            arc_command_url(b,'chrome://chrome-urls/');time.sleep(.6)
            tree=ax(b,out,'internal-debug-controls',depth=30,web=True)
            row['internal_debug_controls']=[{k:n[k] for k in ('role','title','value','desc','frame') if k in n}
                for n in walk(tree) if n.get('role') in ('AXButton','AXCheckBox','AXStaticText') and
                any('debug' in str(n.get(k,'')).lower() for k in ('title','value','desc'))]
        elif task=='interaction':interaction(b,f,out,row,a,bb)
        elif task=='smoothness':smoothness(b,f,out,row,a,bb)
        elif task=='resume':resume(b,f,out,row,a,bb)
        else:raise RuntimeError('Unknown Phase 2 task')
        row['input_block_seconds']=time.monotonic()-b.input_started
        if b.name=='arc' and row['input_block_seconds']>180:raise RuntimeError('Arc input block exceeded three minutes')
        guard(b.baseline)
    except BaseException as exc:
        row['error']=str(exc) or type(exc).__name__
        row['traceback']=traceback.format_exc()
    finally:
        if f:f.close()
        if getattr(b,'debug_pages_restore_required',False):
            try:restore_debug_pages(b,out);row['debug_pages_restored']=True
            except Exception as exc:row['debug_pages_restored']=False;row['restore_error']='Internal debug setting: '+str(exc)
        if b.name=='arc' and hasattr(b,'input_started'):
            row['scored_flow_seconds']=row.get('input_block_seconds')
            row['input_block_seconds']=time.monotonic()-b.input_started
            if row['input_block_seconds']>180:row['error']='Arc input block including restoration exceeded three minutes'
        try:b.stop();row['cleanup']=True
        except Exception as exc:row['cleanup']=False;row['cleanup_error']=str(exc)
        if prefs is None and (out/'defaults-originals.json').is_file():prefs=json.loads((out/'defaults-originals.json').read_text())
        if prefs:
            try:defaults_restore(out,prefs);row['defaults_restored']=True
            except Exception as exc:row['defaults_restored']=False;row['restore_error']=str(exc)
        row['arc_version_after']=None if open_only else version(False)
        row['arc_core_after']=None if open_only else arc_core();row['display_after']=probe('metadata')
        row['load_after']=list(os.getloadavg())
        row['background_jobs_after']=background_jobs()
        if calibration and (row['background_jobs_after'] or row['load_after'][0]>max_load):
            row['qualification']='under load, not for scoring'
        if row['background_jobs_after'] and not calibration:row['error']='Background build invalidates score measurements'
        row['valid']=not row.get('error') and not row.get('restore_error') and row.get('cleanup') and (calibration or max(row['load_before'][0],row['load_after'][0])<=max_load)
        for what in ('arc_version','arc_core','display'):
            matches=displays_match(row[what+'_before'],row[what+'_after']) if what=='display' else row[what+'_before']==row[what+'_after']
            if not matches:row['valid']=False;row['error']=what+' changed'
        for path,k in [(OPEN/'Contents/MacOS/Open','app_main_sha256'),(OPEN/'Contents/Frameworks/OpenEngine.framework/Versions/A/OpenEngine','engine_sha256')]:
            if sha(path)!=expected[k]:row['valid']=False;row['error']='Frozen Open artifact changed'
        for name,digest in expected['measurement_helpers'].items():
            if sha(ROOT/'.re/perf/bin'/name)!=digest:row['valid']=False;row['error']='Measurement helper changed: '+name
        atomic(out/'sample.json',row)
    print(json.dumps({k:row.get(k) for k in ('browser','task','round_index','valid','error','cleanup','input_block_seconds')}),flush=True)
    return 1 if row.get('error') or row.get('restore_error') or not row.get('cleanup') else 0

# Task implementations are kept below the guarded worker so all failures still
# use its cleanup and default-restoration path.
def interaction(b,f,out,row,a,bb):
    metrics=row['metrics'];bounds=owned_bounds(b)
    key(b,'tab',['ctrl'])
    time.sleep(.25)
    verify_selected(b,a,'A',out)
    roi,web,tree=content_region(b,out,'tab-target')
    action=lambda:key(b,'tab',['ctrl'])
    measure_metric(b,f,out,metrics,'ui.tab_switch_ms',roi,action)
    verify_selected(b,bb,'B',out)
    row['tab_switch_route']='Recent-tab switch, Ctrl+Tab and modifier release in both browsers'
    # Native surfaces use one shared app-scoped visual detector. The region
    # includes only the owned window; no pixels are written to disk.
    full=[bounds[0]+8,bounds[1]+8,bounds[2]-16,bounds[3]-16]
    measure_metric(b,f,out,metrics,'ui.new_tab_ms',full,lambda:key(b,'t',['cmd']))
    tree=ax(b,out,'commandbar')
    fields=[n for n in walk(tree) if n.get('role') in ('AXTextField','AXComboBox') and n.get('frame')]
    if not fields:raise RuntimeError('Command bar text field missing')
    fields=[n for n in fields if n['frame'][1]>bounds[1]+100 and n['frame'][3]>5]
    if not fields:raise RuntimeError('Command bar field is not inside the command surface')
    field=max(fields,key=lambda n:n['frame'][2]);x,y,w,h=rect(field)
    result_roi=[x,max(bounds[1],y+h),w,min(400,bounds[1]+bounds[3]-y-h)]
    script='abcdefghijklmnopqrst'*2
    if len(script)!=40:raise RuntimeError('Command bar script length changed')
    values=[];misses=[]
    for i,ch in enumerate(script):
        # Reset outside the timed interval. Long appended strings eventually
        # truncate every result label, so later keys have no visible result
        # change to time. Forty declared one-character queries keep each
        # measured result repaint observable, with the same setup in both.
        key(b,'a',['cmd']);key(b,'delete');time.sleep(.2)
        # Existing native socket text input works for every character. Arc's
        # instrumented Unicode input reports the exact posted key timestamp.
        action=lambda ch=ch:text(b,ch)
        result=f.measure(f'cmdbar-{i:02}',result_roi,action,duration=350,live_socket=b.name=='open')
        if 'first_changed_ms' in result:values.append(result['first_changed_ms'])
        else:misses.append(i)
    row['commandbar_script']={'characters':40,'script':script,'mode':'one-character queries; clear outside each timed interval',
        'result_region':result_roi,'responded':len(values),'no_result_repaint_indices':misses,'summary':summarize(values)}
    if len(values)!=40:raise RuntimeError('Not every command bar key repainted results')
    metric(metrics,'ui.cmdbar_keystroke_ms',statistics.median(values),'ms')
    metric(metrics,'ui.cmdbar_keystroke_p95_ms',sorted(values)[math.ceil(.95*len(values))-1],'ms')
    key(b,'escape');time.sleep(.2)
    measure_metric(b,f,out,metrics,'ui.sidebar_toggle_ms',full,lambda:key(b,'s',['cmd']))
    key(b,'s',['cmd']);time.sleep(.25)
    prepare_neighbor(b,out)
    measure_metric(b,f,out,metrics,'ui.space_switch_ms',full,lambda:key(b,'right',['cmd','opt']))
    key(b,'left',['cmd','opt']);time.sleep(.3)
    # Use the same key intent for the main split command. Its visible command
    # bar/new pane is the first response; settle is retained as a diagnostic.
    measure_metric(b,f,out,metrics,'ui.split_open_ms',full,lambda:key(b,'=',['ctrl','shift']))
    # Split and library can change content selection. Open a new synthetic page
    # before each following surface, preserving the same per-browser intent.
    scene(b,out,'A','-peek')
    if b.name=='arc':
        tree=ax(b,out,'peek-link',web=True);link=find(tree,lambda n:n.get('role')=='AXLink' and 'Open local target' in str(n.get('title',n.get('value',''))))
        action=lambda:native_click(b,center(link),['shift'])
    else:
        tab=selected_tab(b)['id']
        action=lambda:b.call('peek-open',tab=tab,url=b.origin+'/interaction.html?variant=peek')
    measure_metric(b,f,out,metrics,'ui.peek_open_ms',full,action,duration=1500)
    key(b,'escape');time.sleep(.2)
    measure_metric(b,f,out,metrics,'ui.library_open_ms',full,lambda:key(b,'l',['cmd','shift']))
    key(b,'w',['cmd']);time.sleep(.3)
    # Settings may be a separate window outside the old window's bounds.
    display=probe('metadata')['screens'][0];screen=[0,0,display['width'],display['height']]
    measure_metric(b,f,out,metrics,'ui.settings_open_ms',screen,lambda:key(b,',',['cmd']),duration=4500)
    key(b,'w',['cmd']);time.sleep(.2)
    measure_metric(b,f,out,metrics,'ui.window_new_ms',screen,lambda:key(b,'n',['cmd']))
def smoothness(b,f,out,row,a,bb):
    metrics=row['metrics'];resolution=f.resolution_ms
    detector={'resolution_ms':resolution,'observed_hz':1000/resolution,
              'limit':'detector resolves 8.3 ms; drops shorter than that are not seen',
              'authorization':'LEAD 03:00'}
    row['smoothness']={}
    def save(name,trials):
        gaps=[]
        for trial in trials:
            changes=trial['changes'];gaps.extend((v-u)*TICK_SECONDS*1000 for u,v in zip(changes,changes[1:]))
        observed_intervals=len(gaps)
        # A single instantaneous repaint cannot expose a smaller interval.
        # Retain that resolution floor rather than invent a zero frame time.
        if not gaps:
            if not any(t['changes'] for t in trials):raise RuntimeError('No visible motion for '+name)
            gaps=[resolution]
        ordered=sorted(gaps)
        values={'late_pct':100*sum(v>1.5*resolution for v in gaps)/len(gaps),
                'p95_ms':ordered[math.ceil(.95*len(ordered))-1],
                'p99_ms':ordered[math.ceil(.99*len(ordered))-1],
                'longest_stall_ms':max(gaps)}
        for suffix,value in values.items():
            keyname=f'fps.{name}.{suffix}'
            metric(metrics,keyname,value,'%' if suffix=='late_pct' else 'ms');metrics[keyname]['detector']=detector
        row['smoothness'][name]={'detector':detector,'values':values,'changed_interval_count':len(gaps),
              'observed_changed_interval_count':observed_intervals,'detector_floor_used':observed_intervals==0,
              'first_response_ms_informative':[t.get('first_changed_ms') for t in trials],
              'settle_ms_informative':[t.get('last_changed_ms') for t in trials],
              'source_trials':[t['label'] for t in trials]}
    area,point,_=sidebar_region(b,out,'sidebar-scroll-target')
    # Opening the synthetic active tab may reveal the bottom of Today. The
    # same real wheel preposition gives both lists room for the scored scroll.
    row['sidebar_scroll_preposition']=dispatch_scroll(b,
        scroll_script(point,0,12,duration=750),out,'sidebar-scroll-preposition',owned_bounds(b))
    time.sleep(.25)
    script=scroll_script(point,0,-12,duration=750)
    cadence=b.name=='open' and getattr(b,'app_cadence',False)
    if cadence:
        bounds=owned_bounds(b)
        b.call('mouse',action='scroll-cadence-start',x=point[0]-bounds[0],y=point[1]-bounds[1])
    try:
        result=f.measure('sidebar-scroll',area,lambda:dispatch_scroll(b,script,out,'sidebar-scroll',owned_bounds(b)),duration=1500)
    finally:
        if cadence:row['sidebar_app_cadence']=b.call('mouse',action='scroll-cadence-stop')
    save('sidebar_scroll',[result])
    if getattr(b,'metric_filter',None) and all(k.startswith('fps.sidebar_scroll.') for k in b.metric_filter):return
    # Long-article page scroll. The page records its own rAF cadence for the
    # first 700 ms of the same scroll; those rows are informative only.
    token=f'p2-{b.run_id}-scroll-{b.round_index}'
    url=b.origin+'/heavy-dom.html?'+urlencode({'run':token,'phase2':'1'})
    if b.route:url+='&'+b.route
    navigate(b,url,token);time.sleep(.2)
    _,web,_=content_region(b,out,'article-scroll-target');point=[web[0]+web[2]/2,web[1]+web[3]/2]
    roi=[web[0]+25,web[1]+25,min(900,web[2]-50),min(700,web[3]-50)]
    result=f.measure('page-scroll',roi,lambda:dispatch_scroll(b,scroll_script(point,0,-12,duration=750),out,'page-scroll',owned_bounds(b)),duration=1500)
    save('page_scroll_article',[result])
    row['page_scroll_y']=b.collector.wait(token,event='scrolled')['score']
    if row['page_scroll_y']<=100:raise RuntimeError('Long-article page did not scroll')
    row['raf_cadence_informative']={'median_ms':b.collector.wait(token,event='raf-median')['score'],
                                    'p95_ms':b.collector.wait(token,event='raf-p95')['score']}
    # Repeated open/close or collapse/expand are separate capture trials; the
    # deliberate quiet gap between them never becomes a supposed stall.
    bounds=owned_bounds(b);roi=[bounds[0]+8,bounds[1]+8,bounds[2]-16,bounds[3]-16]
    first=f.measure('commandbar-open',roi,lambda:key(b,'t',['cmd']),duration=650,live_socket=b.name=='open')
    second=f.measure('commandbar-close',roi,lambda:key(b,'escape'),duration=650,live_socket=b.name=='open')
    save('commandbar_open_close',[first,second])
    first=f.measure('sidebar-collapse',roi,lambda:key(b,'s',['cmd']),duration=650,live_socket=b.name=='open')
    second=f.measure('sidebar-expand',roi,lambda:key(b,'s',['cmd']),duration=650,live_socket=b.name=='open')
    save('sidebar_collapse_expand',[first,second])
    # LEAD 03:40: the other four scenarios run before the bounded swipe route
    # or its explicitly authorized keyboard Space-transition fallback.
    prepare_neighbor(b,out)
    area,point,tree=sidebar_region(b,out,'space-transition-target')
    route=b.space_transition_route
    before=b.call('spaces') if b.name=='open' else None
    if route['scored_route']=='keyboard':
        row['space_swipe_unscored']=route['unscored']
        result=f.measure('space-change-keyboard',area,lambda:key(b,'right',['cmd','opt']),duration=1400,live_socket=b.name=='open')
        name='space_change_keyboard'
    else:
        result=f.measure('space-swipe',area,lambda:dispatch_scroll(b,
            scroll_script(point,route['swipe_dx'],0,duration=125),out,'space-swipe',owned_bounds(b)),duration=1400)
        name='space_swipe'
    row['space_transition_route']=route['scored_route']
    row['space_transition_before']=before
    row['space_transition_after']=b.call('spaces') if b.name=='open' else None
    if before and next(s['id'] for s in before if s['focused'])==next(s['id'] for s in row['space_transition_after'] if s['focused']):
        raise RuntimeError('Scored Space transition did not change the selected Space')
    save(name,[result])
def resume(b,f,out,row,a,bb):
    metrics=row['metrics']
    def select_target(target,variant):
        if b.name=='open':return b.call('select',tab=target)
        return key(b,'tab',['ctrl'])
    select_target(a,'A');time.sleep(.25)
    roi,_,_=content_region(b,out,'resume-A-region')
    stable=f.measure('resume-A-known-content',roi,lambda:None,duration=150)
    expected=stable['armed_baseline_signature']
    if not expected:raise RuntimeError('Known target-content signature missing')
    select_target(bb,'B');time.sleep(.15)
    if b.name=='open':
        b.call('sleep-clock',advance=600)
        sleeping=b.call('sleep-now',tab=a);row['sleep_preparation']=sleeping
        if sleeping['tab']['phase']!='sleeping' or not sleeping['tab']['discarded']:
            raise RuntimeError('Synthetic tab did not enter the real sleeping/discarded state')
        b.call('sleep-clock',reset=True)
    else:
        enable_debug_pages(b,out,row)
        arc_command_url(b,'chrome://discards/');time.sleep(.6)
        tree=ax(b,out,'discards-before',depth=30,web=True)
        title=f'Perf local A {a}'
        def target_row(tree):
            found=[n for n in walk(tree) if n.get('role')=='AXRow' and n.get('frame') and
                   any(title==str(v.get('value','')) for v in walk(n))]
            if len(found)!=1:raise RuntimeError('Synthetic discard row is missing or ambiguous')
            return found[0]
        def discard_state(tree,target):
            header=next(n for n in walk(tree) if n.get('role')=='AXRow' and
                        any(v.get('value')=='Loading State' for v in walk(n)))
            labels=[' '.join(str(v.get('value','')) for v in walk(c) if v.get('role')=='AXStaticText').replace('▲','').strip()
                    for c in header.get('children',[])]
            cells=[' '.join(str(v.get('value','')) for v in walk(c) if v.get('role')=='AXStaticText').strip()
                   for c in target.get('children',[])]
            values=dict(zip(labels,cells))
            return {k:values[k] for k in ('Loading State','Lifecycle State','Discard Count')}
        node=target_row(tree);before_state=discard_state(tree,node)
        buttons=[n for n in walk(node) if n.get('role') in ('AXButton','AXLink','AXStaticText') and
                 'urgent discard' in ' '.join(str(n.get(k,'')) for k in ('title','value','desc')).lower() and n.get('frame')]
        if len(buttons)!=1:raise RuntimeError('Synthetic target has no unambiguous urgent-discard AX control')
        button=buttons[0]
        native_click(b,center(button));time.sleep(.25)
        after=ax(b,out,'discards-after',depth=30,web=True)
        # Require the synthetic row itself to show discarded state. The rest
        # of the user's old test tabs are never chosen by table position.
        after_state=discard_state(after,target_row(after))
        discarded=(int(after_state['Discard Count'])==int(before_state['Discard Count'])+1 and
                   (after_state['Loading State'].lower()=='unloaded' or after_state['Lifecycle State'].lower()=='discarded'))
        row['discard_state']={'before':before_state,'after':after_state}
        if not discarded:raise RuntimeError('Urgent-discard UI did not confirm the synthetic target state')
        row['sleep_preparation']={'method':'Chromium discards UI, urgent-discard synthetic row','confirmed_discarded':True}
        key(b,'w',['cmd']);time.sleep(.2)
    verify_selected(b,bb,'B',out)
    wall_before=time.time()*1000
    result=measure_metric(b,f,out,metrics,'resume.sleeping_tab_ms',roi,lambda:select_target(a,'A'),duration=4000,field='first_final_content_ms',target=expected)
    token=a if b.name=='arc' else b.scene_tokens['A']
    row['resumed_page']=b.collector.wait(token,after_wall_ms=wall_before,visible=True)
    row['resume_content_signature']={'expected':expected,'final':result.get('final_signature'),'matched':result.get('final_signature')==expected}
    if result.get('final_signature')!=expected:raise RuntimeError('Resumed content did not match the known synthetic page')
    # Reuse the same numerical detector and known, nonblank content signature.
    time.sleep(.2)
    baseline=f.measure('unhide-known-content',roi,lambda:None,duration=150)['armed_baseline_signature']
    hidden=probe('hide',b.pid);row['hide']=hidden
    if not hidden['hidden']:raise RuntimeError('App did not become hidden')
    time.sleep(.3)
    if any(w['pid']==b.pid for w in probe('windows')):raise RuntimeError('Owned window stayed visible after hide')
    measure_metric(b,f,out,metrics,'resume.app_unhide_ms',roi,lambda:probe('unhide',b.pid),duration=1800,field='first_final_content_ms',target=baseline,hidden_before_input=True)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--worker',type=Path)
    p.add_argument('--out',type=Path)
    p.add_argument('--tasks',default='interaction,smoothness,resume')
    p.add_argument('--samples',type=int,default=7)
    p.add_argument('--calibrate',action='store_true',help='Unscored real-flow calibration; never publish these samples')
    p.add_argument('--browser',choices=['paired','arc','open'],default='paired')
    p.add_argument('--resume-from',type=Path)
    p.add_argument('--delta',type=Path,default=ROOT/'.re/perf/main-delta-1.json')
    p.add_argument('--swipe-proof',type=Path,default=ROOT/'.re/perf/phase2-swipe-route-corrected-2/result.json')
    args=p.parse_args()
    if args.worker:return worker(json.loads(args.worker.read_text()))
    if not args.out:p.error('--out required')
    args.out=args.out.resolve()
    args.delta=args.delta.resolve()
    if args.out.exists():p.error('Preserve receipts: use a fresh output path')
    if args.browser=='open':p.error('Phase 2 Open-only replay requires a frozen Phase 2 manifest')
    tasks=args.tasks.split(',')
    if tasks!=['explore'] and args.samples<7 and not args.calibrate:p.error('Timing rows require N7')
    current=provenance();build=json.loads((ROOT/'.re/perf/phase2-build.json').read_text())
    for k in ('commit','app_main_sha256','engine_sha256'):
        if current[k]!=build[k]:raise RuntimeError('Phase 2 build differs from frozen corrected artifact')
    delta=json.loads(args.delta.read_text())
    current['main_delta_receipt']={'path':str(args.delta),'sha256':sha(args.delta)}
    delta_rows=metric_rows(delta,'open')
    if any(delta_rows.get(('S-real',k),{}).get('summary',{}).get('n',0)<5 for k in MAIN_DELTA):
        raise RuntimeError('Finish the eight N5 main delta rows before Phase 2')
    for k in ('commit','engine_sha256'):
        if delta['provenance'][k]!=current[k]:raise RuntimeError('Phase 2 artifact differs from measured main delta')
    exception=build['delta_artifact_exception']
    if delta['provenance']['app_main_sha256']!=exception['delta_app_sha256']:
        raise RuntimeError('Delta artifact is outside the LEAD 05:00 exception')
    current['delta_artifact_exception']=exception
    current['automation_patch_sha256']=build['automation_patch_sha256']
    current['max_load1']=10
    current['measurement_helpers']={name:sha(ROOT/'.re/perf/bin'/name) for name in ('frames','arc-input','probe','ax-perf')}
    current['phase2_run_id']=f'{time.time_ns():x}'
    route_path=args.swipe_proof.resolve()
    route=json.loads(route_path.read_text())
    if not route.get('valid'):
        if tasks!=['explore']:raise RuntimeError('Bounded swipe route proof is not valid')
        route={**route,'scored_route':'unscored exploration only'}
    for k in ('commit','app_main_sha256','engine_sha256','display'):
        if route['provenance'][k]!=current[k]:raise RuntimeError('Swipe route proof used a different artifact: '+k)
    current['space_transition_route']={k:route[k] for k in ('scored_route','swipe_dx','unscored','lead_action') if k in route}
    current['space_transition_route'].update(receipt=str(route_path.relative_to(ROOT)),sha256=sha(route_path),authorization='LEAD 03:40')
    current['sampling_policy']={'core_required_n':7,'disk_required_n':1,'metric_required_n':{}}
    current['detector']={'source':'ScreenCaptureKit, owned app windows only','requested':'native display refresh','pixels_saved':False,
                         'resolution_ms':build['detector_resolution_ms'],'observed_hz':build['detector_hz'],
                         'qualification':'LEAD 03:00: detector resolves 8.3 ms; drops shorter than that are not seen; no 240 Hz frame-delivery claim'}
    run={'schema':1,'date':now(),'provenance':current,'samples':[],'blocked':{},'gate_attempts':[],
         'calibration_only':args.calibrate or tasks==['explore']}
    if args.resume_from:
        run=json.loads(args.resume_from.read_text())
        for k in ('commit','app_main_sha256','engine_sha256','arc_version','arc_core','display','hardware','os','measurement_helpers','space_transition_route'):
            if run['provenance'][k]!=current[k]:raise RuntimeError('Resume provenance changed: '+k)
        run.setdefault('resumes',[]).append({'date':now(),'source':str(args.resume_from),'sha256':sha(args.resume_from)})
        current['phase2_run_id']=run['provenance']['phase2_run_id']
        run.pop('stop_reason',None)
        for sample in run['samples']:
            if sample['browser']=='open' and sample['task']=='interaction' and sample.get('input_boundary_version',1)<2:
                sample['valid']=False
                sample['boundary_invalidation']='Open key timestamp included preflight before socket dispatch; repeat the pair'
        run.pop('qualified_pairs',None)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    work=args.out.parent/(args.out.stem+'-samples');work.mkdir()
    reference=json.loads((ROOT/'docs/perf/arc-reference-m5.json').read_text())
    manifest=json.loads((BASE.parent/'cohorts'/reference['provenance']['replay_cohort']/'manifest.json').read_text())
    c=Collector(work/'collector',port=manifest['port'])
    root=Path(tempfile.mkdtemp(prefix='op.'));order=['arc','open'] if args.browser=='paired' else ['arc']
    atomic(args.out,run)
    def session(name,task,index,snapshot):
        attempt=0;wait_started=time.monotonic();noted=False
        while True:
            if time.monotonic()-wait_started>600 and not noted:
                with (PLANS/'P-questions.md').open('a') as note:
                    note.write(f'\n## P FIFO wait — {now()}\n\n{task} index {index}, {name}, has waited over ten minutes outside slots. Saved cohort is preserved; no holder is touched.\n')
                noted=True
            if os.getloadavg()[0]>10 or Path('/tmp/open-onscreen-priority').exists() or (ROOT/'.re/hold-on-screen').exists():time.sleep(5);continue
            directory=work/f'{task}-{index:02}-{name}-attempt-{attempt:02}'
            cfg={'browser':name,'task':task,'index':index,'out':str(directory),'root':str(root),
                 'collector':c.url,'origin':manifest['navigation_origin'],'route':manifest.get('route_suffix',''),
                 'snapshot':str(snapshot),'provenance':current}
            if name=='open':cfg.update(frame=run.get('last_arc_frame'),viewport=run.get('last_arc_viewport'))
            cfg_path=work/'worker-config.json';atomic(cfg_path,cfg)
            cmd=[str(Path.home()/'Library/Caches/OpenRE/scripts/heavy.sh'),'/usr/bin/lockf','-k','-t','30','/tmp/open-onscreen-e2e.lock',sys.executable,str(Path(__file__)),'--worker',str(cfg_path)]
            status=subprocess.run(cmd,env=dict(os.environ,OPEN_HEAVY_EXCLUSIVE='1')).returncode
            path=directory/'sample.json'
            sample=json.loads(path.read_text()) if path.exists() else None
            if sample and sample.get('foreign_browser'):
                run['foreign_browser_block']=True;atomic(args.out,run)
                raise RuntimeError('Foreign browser blocks preflight; ask one pending question now')
            if not sample or sample.get('gate_refused'):
                run['gate_attempts'].append({'directory':str(directory),'status':status,'date':now()});atomic(args.out,run)
                attempt+=1;time.sleep(5);continue
            sample['source_directory']=str(directory.relative_to(ROOT));run['samples'].append(sample);atomic(args.out,run)
            if status:raise RuntimeError(sample.get('error','Worker failed'))
            return sample
    try:
        for task in tasks:
            prior=[s for s in run['samples'] if s['task']==task]
            next_index=max((s['round_index'] for s in prior),default=-1)+1
            def qualified():
                return [i for i in {s['round_index'] for s in run['samples'] if s['task']==task} if all(any(s['task']==task and s['round_index']==i and s['browser']==name and s.get('valid') for s in run['samples']) for name in order)]
            for index in range(next_index,next_index+args.samples*2):
                if len(qualified())>=args.samples:break
                shutil.rmtree(root);root.mkdir()
                snapshot=work/f'{task}-{index:02}-paired-start'
                for name in order:
                    if name=='open':
                        shutil.rmtree(root);shutil.copytree(snapshot,root)
                    sample=session(name,task,index,snapshot)
                    if name=='arc' and sample.get('workload_page'):
                        bounds=sample['window_bounds'];height=current['display']['screens'][0]['height']
                        run['last_arc_frame']=[bounds[0],height-bounds[1]-bounds[3],bounds[2],bounds[3]]
                        run['last_arc_viewport']=[sample['workload_page']['viewport_width'],sample['workload_page']['viewport_height']]
                        atomic(args.out,run)
                run.setdefault('qualified_pairs',{})[task]=qualified();atomic(args.out,run)
            if len(qualified())<args.samples:raise RuntimeError('Insufficient matched pairs: '+task)
    except BaseException as exc:run['stop_reason']=str(exc) or type(exc).__name__
    finally:
        run['end_date']=now();atomic(args.out,run);c.close();shutil.rmtree(root)
    return 1 if run.get('stop_reason') else 0
if __name__=='__main__':raise SystemExit(main())
