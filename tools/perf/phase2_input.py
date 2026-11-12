"""Private AX geometry and a common scroll script; never inputs into Open globally."""
import json
import subprocess
import time
from pathlib import Path
from frame_client import arc_input, ticks, TICK_SECONDS
from run import ROOT, atomic, command

TOOLS=Path.home()/'Library/Caches/OpenRE/scripts'

def walk(node):
    if isinstance(node,list):
        for item in node:yield from walk(item)
    elif isinstance(node,dict):
        yield node
        for item in node.get('children',[]):yield from walk(item)

def ax(browser,out,label,depth=22,web=False):
    helper=ROOT/'.re/perf/bin/ax-perf';original=None
    if browser.name=='arc' and web:
        original=json.loads(command([helper,browser.pid,'manual','true']))
        atomic(Path(out)/(label+'-manual-on.json'),original)
        if not original['set_success']:raise RuntimeError('Manual page accessibility refused')
        time.sleep(.15)
    try:
        raw=command([helper,browser.pid,str(depth),*(['web-frame' if web=='frame' else 'web'] if web else [])],timeout=25)
    finally:
        if original is not None:
            value=original['original'] if isinstance(original['original'],bool) else False
            restored=json.loads(command([helper,browser.pid,'manual','true' if value else 'false']))
            atomic(Path(out)/(label+'-manual-restored.json'),restored)
            if not restored['set_success']:raise RuntimeError('Manual page accessibility restore failed')
            time.sleep(.15)
    path=Path(out)/(label+'-ax.json');path.write_text(raw)
    result=json.loads(raw)
    if not result['complete']:raise RuntimeError('Bounded AX read did not complete')
    return result['windows']

def rect(node):
    r=node.get('frame')
    if not r or len(r)!=4 or min(r[2:])<=0:raise RuntimeError('AX target has no positive frame')
    return r

def center(node):
    x,y,w,h=rect(node);return [x+w/2,y+h/2]

def find(tree,predicate):
    found=[n for n in walk(tree) if predicate(n) and n.get('frame') and min(n['frame'][2:])>0]
    if len(found)!=1:raise RuntimeError('AX target missing or ambiguous: '+str(len(found)))
    return found[0]

def largest(tree,role):
    rows=[n for n in walk(tree) if n.get('role')==role and n.get('frame') and min(n['frame'][2:])>0]
    if not rows:raise RuntimeError('AX role missing: '+role)
    return max(rows,key=lambda n:n['frame'][2]*n['frame'][3])

def web_rect(browser,tree=None):
    if browser.name=='arc':return rect(largest(tree,'AXWebArea'))
    state=browser.call('window-state');x,y,w,h=state['frame']
    screen_height=state['screenFrame'][3]
    p=state['toolbar']['page'];panel=state['panel']
    return [x+panel[0]+p[0],screen_height-y-h+panel[1]+p[1],p[2],p[3]]

def synthetic_tab(tree,title):
    rows=[n for n in walk(tree) if any(title in str(n.get(k,'')) for k in ('title','desc','value')) and n.get('frame') and n.get('role') not in ('AXWindow','AXWebArea')]
    # The smallest AX leaf with the exact synthetic title locates that row.
    if not rows:raise RuntimeError('Synthetic tab has no AX target')
    return min(rows,key=lambda n:n['frame'][2]*n['frame'][3])

def click_arc(browser,node,modifiers=None):
    p=center(node)
    if modifiers:arc_input(browser.pid,'flags',modifiers,'down')
    try:return arc_input(browser.pid,'click',*p)
    finally:
        if modifiers:arc_input(browser.pid,'flags',modifiers,'up')

def scroll_script(point,dx,dy,duration=750,hz=240,momentum=True):
    n=round(duration*hz/1000);events=[]
    for i in range(n):
        events.append({'at_ms':i*1000/hz,'point':point,'dx':dx,'dy':dy,
                       'phase':1 if i==0 else 2,'momentum':0})
    events.append({'at_ms':duration,'point':point,'dx':0,'dy':0,'phase':4,'momentum':0})
    if momentum:
        # Explicit matching inertial tail. Same pixel deltas/phases in both
        # browsers; no OS-dependent physical trackpad acceleration is assumed.
        for j in range(24):
            events.append({'at_ms':duration+(j+1)*1000/hz,'point':point,
                           'dx':round(dx*(1-j/24)),'dy':round(dy*(1-j/24)),
                           'phase':0,'momentum':1 if j==0 else 2})
        events.append({'at_ms':duration+25*1000/hz,'point':point,'dx':0,'dy':0,'phase':0,'momentum':3})
    return events

def dispatch_scroll(browser,events,out,label,window_bounds=None):
    path=Path(out)/(label+'-event-script.json');atomic(path,events)
    if browser.name=='arc':return arc_input(browser.pid,'wheel-script',path)
    if window_bounds is None:raise RuntimeError('Open scroll needs its owned window frame')
    x,y,w,h=window_bounds;start=time.monotonic();posted=[]
    phases={0:'none',1:'began',2:'changed',4:'ended',8:'cancelled'}
    for step in events:
        delay=start+step['at_ms']/1000-time.monotonic()
        if delay>0:time.sleep(delay)
        before=ticks()
        result=browser.call('mouse',action='scroll',x=step['point'][0]-x,y=step['point'][1]-y,
                            dx=step['dx'],dy=step['dy'],phase=phases[step['phase']],momentum=step['momentum'])
        posted.append({'ticks':round(result['eventTimestamp']/TICK_SECONDS),'dispatch_ticks':before,
                       'event_type':22,'window':result['window'],
                       'location':result.get('location'),'targetPoint':result.get('targetPoint'),
                       'phase':result.get('routedPhase'),'momentum':result.get('routedMomentum'),
                       'scrollingDelta':result.get('scrollingDelta')})
    return {'events':posted,'route':'Open own-window NSApp.sendEvent'}
