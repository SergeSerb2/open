#!/usr/bin/env python3
"""One bounded native-event route proof under LEAD 03:40, on the frozen app."""
import argparse
import json
import os
import shutil
import tempfile
import time
from pathlib import Path

from frame_client import Frames
from phase2_input import ax, center, largest, rect, walk, scroll_script, dispatch_scroll
from run import (ROOT, OPEN, ARC, Browser, atomic, existing_pids, guard, now,
                 probe, provenance, sha)
from server import Collector


def main():
    if os.environ.get('OPEN_HEAVY_HELD')!='1':
        raise RuntimeError('Exclusive queue slot required')
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    out=args.out;out.mkdir(exist_ok=False)
    expected=json.loads((ROOT/'.re/perf/phase2-build.json').read_text())
    result={'date':now(),'authorization':'LEAD 03:40; user additional-route proof',
            'load_before':list(os.getloadavg()),'provenance':provenance(),
            'attempts':[],'valid':False}
    for k in ('commit','app_main_sha256','engine_sha256','display'):
        if result['provenance'][k]!=expected[k]:raise RuntimeError('Frozen artifact changed: '+k)
    if existing_pids(ARC) or existing_pids(OPEN):raise RuntimeError('Foreign browser blocks route proof')
    if os.getloadavg()[0]>10:raise RuntimeError('Load gate refused')
    root=Path(tempfile.mkdtemp(prefix='op.'));c=Collector(out/'collector')
    b=Browser('open',root,out,c,'swipe-route');frames=None
    try:
        b.start(c.url+'/interaction.html?run=swipe-route')
        c.wait('swipe-route',visible=True)
        while len(b.call('spaces'))<3:
            b.call('space-create',title='Synthetic swipe route '+str(len(b.call('spaces'))))
        middle=b.call('spaces')[1]['id']
        b.call('space',space=middle);time.sleep(.4)
        bounds=max((w for w in probe('windows') if w['pid']==b.pid),key=lambda w:w['bounds'][2]*w['bounds'][3])['bounds']
        frames=Frames(b.pid,expected['display']['screens'][0]['id'],out/'frames',resolution_ms=expected['detector_resolution_ms'])
        result['input_contract']={
            'source':'Packages/OpenKit/Sources/OpenSidebar/SpacePagerView.swift:173-246; PageScrollView:277-285',
            'source_sha256':sha(ROOT/'Packages/OpenKit/Sources/OpenSidebar/SpacePagerView.swift'),
            'start':'began, abs(scrollingDeltaX) > abs(scrollingDeltaY), pointer over pager list',
            'commit':'ended; distance > 0.5 * pager width, or velocity > 6 and distance > 0.08 * width',
            'script':'30 pixel-wheel events at 240 Hz; dx +/-12, dy 0; began/changed/ended; momentum tail',
            'native_route':'real CGEvent, continuous/precise pixel deltas; own-window NSApp.sendEvent'}
        for direction in (-1,1):
            b.call('space',space=middle);time.sleep(.35)
            tree=ax(b,out,'target-'+str(direction))
            candidates=[]
            for node in walk(tree):
                if node.get('role')!='AXScrollArea' or not node.get('frame'):continue
                x,y,w,h=rect(node);bx,by,bw,bh=bounds
                left,top=max(x,bx),max(y,by)
                right,bottom=min(x+w,bx+bw),min(y+h,by+bh)
                if right-left>40 and bottom-top>100:
                    candidates.append([left,top,right-left,bottom-top])
            if not candidates:raise RuntimeError('No visible pager AX region')
            region=max(candidates,key=lambda r:r[2]*r[3])
            point=[region[0]+region[2]/2,region[1]+region[3]/2]
            script=scroll_script(point,12*direction,0,duration=125)
            before=b.call('spaces')
            trial=frames.measure('swipe-'+str(direction),region,
                lambda:dispatch_scroll(b,script,out,'swipe-'+str(direction),bounds),duration=1200)
            posted=trial['input_receipt']['events']
            phases={0:0,1:1,2:4,4:8,8:16}
            momentum={0:0,1:1,2:4,3:8}
            shape_ok=len(posted)==len(script) and all(
                event['phase']==phases[step['phase']] and event['momentum']==momentum[step['momentum']]
                and event['scrollingDelta']==[step['dx'],step['dy']]
                and event['location']==event['targetPoint']
                for event,step in zip(posted,script))
            distance=sum(abs(e['dx']) for e in script if e['phase']==2)
            if not shape_ok or distance<=region[2]*.5:
                raise RuntimeError('Bounded swipe did not prove the required event shape and distance')
            after=b.call('spaces')
            selected=lambda spaces:next(s['id'] for s in spaces if s['focused'])
            result['attempts'].append({'direction':direction,'area':region,'point':point,
                'space_count':len(before),'before':selected(before),'after':selected(after),
                'space_changed':selected(before)!=selected(after),
                'event_shape_verified':shape_ok,
                'changed_frames':len(trial['changes']),
                'changed_distance_px':distance,
                'distance_threshold_px':region[2]*.5,
                'input_receipt':trial['input_receipt']})
            guard(b.baseline)
        works=[a['direction'] for a in result['attempts'] if a['space_changed']]
        result['scored_route']='swipe' if works else 'keyboard'
        result['swipe_dx']=12*(works[0] if works else -1)
        if not works:
            result['unscored']='Space swipe: not measurable through the in-process route; unscored'
            result['lead_action']='verify by hand: two-finger swipe on the sidebar changes Space'
        result['valid']=True
    except BaseException as exc:result['error']=str(exc)
    finally:
        if frames:frames.close()
        b.stop();c.close();shutil.rmtree(root)
        try:guard(b.baseline);result['no_new_system_window']=True
        except RuntimeError as exc:result['valid']=False;result['error']=str(exc)
        result['load_after']=list(os.getloadavg())
        result['browsers_quit']=not existing_pids(ARC) and not existing_pids(OPEN)
        result['valid']=result['valid'] and result['browsers_quit'] and max(result['load_before'][0],result['load_after'][0])<=10
        for k in ('app_main_sha256','engine_sha256','display'):
            if provenance()[k]!=expected[k]:result['valid']=False;result['error']='Frozen artifact changed: '+k
        atomic(out/'result.json',result)
    print(json.dumps({k:result.get(k) for k in ('valid','scored_route','error','browsers_quit')}),flush=True)
    return 0 if result['valid'] else 1


if __name__=='__main__':raise SystemExit(main())
