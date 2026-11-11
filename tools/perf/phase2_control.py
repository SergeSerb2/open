#!/usr/bin/env python3
"""Real Open scroll-route and app-scoped frame-detector controls."""
import json
import os
from pathlib import Path
import shutil
import statistics
import tempfile
import time

from frame_client import Frames
from phase2_input import ax, web_rect, scroll_script, dispatch_scroll, center, largest
from run import Browser, ROOT, atomic, existing_pids, ARC, OPEN, probe, provenance, now, guard
from server import Collector

def main():
    if os.environ.get('OPEN_HEAVY_HELD')!='1':raise RuntimeError('Missing exclusive queue slot')
    out=ROOT/'.re/perf'/os.environ.get('OPEN_PERF_CONTROL_OUT','phase2-control-5');out.mkdir(exist_ok=False)
    result={'date':now(),'provenance':provenance(include_arc=False),'load_before':list(os.getloadavg()),'passed':False}
    if existing_pids(ARC) or existing_pids(OPEN):raise RuntimeError('Foreign browser running; no adoption')
    if os.getloadavg()[0]>10:raise RuntimeError('Load gate refused')
    root=Path(tempfile.mkdtemp(prefix='op.'));c=Collector(out/'collector');b=Browser('open',root,out,c,'control');frames=None
    try:
        b.start(c.url+'/interaction.html?run=control&delay=0')
        c.wait('control',visible=True)
        b.call('window-frame',frame=[350,150,1300,1000],unconstrained=True)
        time.sleep(1)
        tree=ax(b,out,'initial');web=web_rect(b,tree)
        bounds=max((w for w in probe('windows') if w['pid']==b.pid),key=lambda w:w['bounds'][2]*w['bounds'][3])['bounds']
        point=[web[0]+web[2]/2,web[1]+web[3]/2]
        result['geometry']={'web':web,'bounds':bounds,'state':b.call('window-state')}
        b.call('eval',js='window.perfWheels=[];addEventListener("wheel",e=>perfWheels.push([e.clientX,e.clientY,e.deltaX,e.deltaY]),{passive:true});true')
        before=float(b.call('eval',js='String(scrollY)'))
        result['scroll']=dispatch_scroll(b,scroll_script(point,0,-8,duration=250),out,'scroll',bounds)
        time.sleep(.5);after=float(b.call('eval',js='String(scrollY)'))
        result['scroll_position']={'before':before,'after':after,'passed':after>before+100}
        result['page_wheel_events']=json.loads(b.call('eval',js='JSON.stringify(perfWheels)'))
        atomic(out/'scroll-check.json',result)
        result['refusals']={}
        for label,args in [('foreign-window',{'window':2147483647}),('bad-phase',{'phase':'invalid'}),('bad-momentum',{'momentum':9}),
                           ('outside-window',{'x':-1}),('oversize-delta',{'dy':4097})]:
            request={'x':point[0]-bounds[0],'y':point[1]-bounds[1],**args}
            try:b.call('mouse',action='scroll',**request)
            except RuntimeError as exc:result['refusals'][label]=str(exc)
            else:raise RuntimeError('Invalid scroll was accepted: '+label)
        # Both signs at the allowed delta boundary, plus corrected phase values.
        result['boundary']=[]
        for delta in (-4096,4096):
            value=b.call('mouse',action='scroll',x=point[0]-bounds[0],y=point[1]-bounds[1],dy=delta,phase='began')
            if value['routedPhase']!=1:raise RuntimeError('Wrong began phase')
            result['boundary'].append(value)
        for phase,wanted in [('changed',4),('ended',8),('cancelled',16)]:
            value=b.call('mouse',action='scroll',x=point[0]-bounds[0],y=point[1]-bounds[1],phase=phase)
            if value['routedPhase']!=wanted:raise RuntimeError('Wrong finger phase: '+phase)
        for momentum,wanted in [(1,1),(2,4),(3,8)]:
            value=b.call('mouse',action='scroll',x=point[0]-bounds[0],y=point[1]-bounds[1],phase='none',momentum=momentum)
            if value['routedMomentum']!=wanted:raise RuntimeError('Wrong momentum phase')
        frames=Frames(b.pid,result['provenance']['display']['screens'][0]['id'],out/'frames')
        result['calibrations']=[]
        for index in range(3):
            for delay in (0,200):
                token=f'cal-{index}-{delay}'
                b.new_page(c.url+f'/interaction.html?run={token}&delay={delay}',token)
                web=web_rect(b,ax(b,out,token))
                b.call('mouse',action='click',x=web[0]+100-bounds[0],y=web[1]+200-bounds[1]);time.sleep(.15)
                roi=[web[0]+50,web[1]+150,250,250]
                row=frames.measure(token,roi,lambda:b.call('key',key='x'),duration=650)
                row['telemetry']=c.wait(token,event='calibration')
                if 'first_changed_ms' not in row:raise RuntimeError('Colour change not detected')
                result['calibrations'].append({'delay':delay,'detected_ms':row['first_changed_ms'],'page_ms':row['telemetry']['score']})
        base=statistics.median(r['detected_ms'] for r in result['calibrations'] if r['delay']==0)
        fault=statistics.median(r['detected_ms'] for r in result['calibrations'] if r['delay']==200)
        result['delay_control']={'normal_ms':base,'fault_ms':fault,'delta_ms':fault-base,'passed':150<fault-base<300}
        cadence=frames.measure('cadence',[web[0]+50,web[1]+150,250,250],lambda:b.call('eval',js='perfAnimate(1000); true'),duration=1200)
        result['page_raf_ms']=json.loads(b.call('eval',js='JSON.stringify(perfFrames.slice(1).map((v,i)=>v-perfFrames[i]))'))
        result['cadence']={k:cadence.get(k) for k in ('changed_frame_intervals_ms','capture_intervals_ms','p95_frame_ms','p99_frame_ms','dropped_pct','late_pct')}
        stalled=frames.measure('cadence-stalled',[web[0]+50,web[1]+150,250,250],lambda:b.call('eval',js='perfFrames=[];perfAnimate(1000,25);true'),duration=1200)
        result['cadence_fault']={k:stalled.get(k) for k in ('changed_frame_intervals_ms','capture_intervals_ms','p95_frame_ms','p99_frame_ms','dropped_pct','late_pct')}
        result['cadence_control_passed']=stalled.get('p95_frame_ms',0)>cadence.get('p95_frame_ms',10000)+8
        result['swipe_proof']='Separate bounded proof; LEAD 03:40 keyboard fallback if needed'
        result['passed']=result['scroll_position']['passed'] and result['delay_control']['passed'] and result['cadence_control_passed']
    except BaseException as exc:result['error']=str(exc)
    finally:
        if frames:frames.close()
        b.stop();c.close();shutil.rmtree(root)
        try:guard(b.baseline);result['no_new_system_window']=True
        except RuntimeError as exc:result['no_new_system_window']=False;result['passed']=False;result['error']=str(exc)
        result['load_after']=list(os.getloadavg());result['browsers_quit']=not existing_pids(ARC) and not existing_pids(OPEN)
        atomic(out/'result.json',result)
    print(json.dumps({k:result.get(k) for k in ('passed','error','scroll_position','delay_control','cadence','browsers_quit')}),flush=True)
    return 0 if result['passed'] else 1

if __name__=='__main__':raise SystemExit(main())
