"""Shared numeric ScreenCaptureKit detector and authorized input receipts."""
import ctypes
import json
import math
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
from run import ROOT, atomic
from score import summarize

lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
lib.mach_absolute_time.restype=ctypes.c_uint64
class Timebase(ctypes.Structure):
    _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
tb=Timebase();lib.mach_timebase_info(ctypes.byref(tb))
TICK_SECONDS=tb.numer/tb.denom/1e9

def ticks():return int(lib.mach_absolute_time())

_socket_marker=None

def socket_boundary():
    stamp=ticks()
    if _socket_marker is not None:_socket_marker(stamp)
    return stamp

class Frames:
    def __init__(self,pid,display_id,out,resolution_ms=None):
        self.out=Path(out);self.out.mkdir(parents=True,exist_ok=True)
        self.cfg={'pid':pid,'display_id':display_id,'hz':240,'stride':2}
        self.resolution_ms=resolution_ms
        cfg=self.out/'frame-config.json';atomic(cfg,self.cfg)
        self.errors=(self.out/'frame-stderr.txt').open('w')
        self.job=subprocess.Popen([str(ROOT/'.re/perf/bin/frames'),str(cfg)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.errors,text=True,bufsize=1)
        self.mail=queue.Queue();self.pending=[];self.ident=0
        def read():
            for line in self.job.stdout:
                try:self.mail.put(json.loads(line))
                except ValueError:self.mail.put({'event':'error','error':'Frame helper emitted malformed JSON'})
            self.mail.put({'event':'error','error':'Frame helper closed its output'})
        self.reader=threading.Thread(target=read,daemon=True);self.reader.start()
        self.ready=self.wait('ready',timeout=20);atomic(self.out/'frame-ready.json',self.ready)
    def send(self,**value):
        self.job.stdin.write(json.dumps(value)+'\n');self.job.stdin.flush()
    def wait(self,event,ident=None,timeout=10):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            for i,row in enumerate(self.pending):
                if row['event']=='error':raise RuntimeError(row['error'])
                if row['event']==event and (ident is None or row.get('id')==ident):return self.pending.pop(i)
            try:row=self.mail.get(timeout=max(.01,end-time.monotonic()))
            except queue.Empty:break
            if row['event']=='error':raise RuntimeError(row['error'])
            if row['event']==event and (ident is None or row.get('id')==ident):return row
            self.pending.append(row)
        raise RuntimeError('Frame helper timeout waiting for '+event)
    def measure(self,label,roi,action,duration=1200,target_signature=None,live_socket=False):
        global _socket_marker
        self.ident+=1;i=self.ident
        self.send(cmd='arm',id=i,roi=roi,duration_ms=duration,**({'target_signature':target_signature} if target_signature else {}))
        armed=self.wait('armed',i)
        stamp=ticks()
        if not live_socket:
            self.send(cmd='mark',id=i,ticks=stamp);self.wait('marked',i)
        live_marks=[]
        previous_marker=_socket_marker
        def mark_socket(stamp):
            live_marks.append(stamp)
            self.send(cmd='mark',id=i,ticks=stamp)
        _socket_marker=mark_socket
        try:result=action()
        finally:_socket_marker=previous_marker
        finished=ticks()
        # An instrumented uidrive receipt provides the exact posted event.
        # Open returns a native eventTimestamp for scroll; other socket actions
        # use the dispatch boundary, with transport included and disclosed.
        actual=stamp;timestamp_kind='socket dispatch boundary'
        if isinstance(result,dict) and result.get('events'):
            candidates=[e for e in result['events'] if e['event_type'] in (1,3,10,22)]
            if candidates:
                actual=candidates[0]['ticks']
                timestamp_kind='native event timestamp' if result.get('route')=='Open own-window NSApp.sendEvent' else 'posted CGEvent'
        elif isinstance(result,dict) and result.get('eventTimestamp'):
            actual=round(result['eventTimestamp']/TICK_SECONDS);timestamp_kind='native event timestamp'
        elif isinstance(result,dict) and result.get('socket_dispatch_ticks'):
            actual=result['socket_dispatch_ticks']
        if live_marks:
            if len(live_marks)!=1 or actual!=live_marks[0]:raise RuntimeError('Ambiguous live socket timestamp')
            self.wait('marked',i)
        elif live_socket:raise RuntimeError('Live socket action did not provide an input timestamp')
        elif actual!=stamp:
            self.send(cmd='mark',id=i,ticks=actual);self.wait('marked',i)
        row=self.wait('result',i,timeout=duration/1000+10)
        row.update(label=label,action_return_ticks=finished,dispatch_ticks=actual,preflight_started_ticks=stamp,
                   timestamp_kind=timestamp_kind,
                   preflight_ms=(actual-stamp)*TICK_SECONDS*1000,
                   dispatch_to_action_return_ms=(finished-actual)*TICK_SECONDS*1000,
                   baseline_age_ms=(stamp-armed['baseline_ticks'])*TICK_SECONDS*1000)
        row['input_receipt']=result
        if isinstance(result,dict) and result.get('events'):
            posted=[e['ticks'] for e in result['events'] if e.get('event_type')==22]
            row['posted_scroll_intervals_ms']=summarize([(b-a)*TICK_SECONDS*1000 for a,b in zip(posted,posted[1:])])
        row['armed_baseline_signature']=armed.get('baseline_signature')
        times=row['changes'];gaps=[(b-a)*TICK_SECONDS*1000 for a,b in zip(times,times[1:])]
        row['changed_frame_intervals_ms']=summarize(gaps)
        captures=[v['ticks'] for v in row['frames']]
        row['capture_intervals_ms']=summarize([(b-a)*TICK_SECONDS*1000 for a,b in zip(captures,captures[1:])])
        row['capture_callback_lag_ms']=summarize([v['callback_lag_ms'] for v in row['frames']])
        row['detector_resolution_ms']=self.resolution_ms or (row['capture_intervals_ms']['median'] if row['capture_intervals_ms'] else None)
        if gaps:
            target=row['detector_resolution_ms'] or 1000/self.cfg['hz'];missed=sum(max(0,round(v/target)-1) for v in gaps)
            row['dropped_pct']=100*missed/(len(gaps)+missed)
            row['late_pct']=100*sum(v>target*1.5 for v in gaps)/len(gaps)
            ordered=sorted(gaps);row['p95_frame_ms']=ordered[math.ceil(.95*len(ordered))-1];row['p99_frame_ms']=ordered[math.ceil(.99*len(ordered))-1]
        atomic(self.out/(label+'.json'),row)
        return row
    def close(self):
        if self.job.poll() is None:
            self.send(cmd='quit')
            try:self.job.wait(timeout=10)
            except subprocess.TimeoutExpired:self.job.terminate();self.job.wait(timeout=10)
        self.errors.close()

def arc_input(pid,*args):
    result=subprocess.run([str(ROOT/'.re/perf/bin/arc-input'),*map(str,args)],env=dict(os.environ,OPEN_PERF_ARC_PID=str(pid)),capture_output=True,text=True,check=False,timeout=10)
    if result.returncode:raise RuntimeError('Arc input refused: '+(result.stderr.strip()[:500] or str(result.returncode)))
    return json.loads(result.stdout)
