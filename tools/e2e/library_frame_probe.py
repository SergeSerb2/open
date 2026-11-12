"""Numeric, app-scoped ScreenCaptureKit receipts through OpenCapture.

The optional helper is Open's existing tools/perf/frames.m executable. It reads
only the exact Open PID. It never writes pixels or sends desktop input.
"""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import time

lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
lib.mach_absolute_time.restype=ctypes.c_uint64
class Timebase(ctypes.Structure):
    _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
tb=Timebase();lib.mach_timebase_info(ctypes.byref(tb))
TICK_MS=tb.numer/tb.denom/1e6


class Frames:
    def __init__(self,app,helper,out):
        self.out=Path(out);self.out.mkdir(parents=True,exist_ok=False)
        cg=ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cg.CGMainDisplayID.restype=ctypes.c_uint32
        self.cfg={'pid':app.pid,'display_id':int(cg.CGMainDisplayID()),'hz':120,'stride':2}
        cfg=self.out/'config.json';cfg.write_text(json.dumps(self.cfg))
        self.fifo=self.out/'commands';os.mkfifo(self.fifo,0o600)
        self.fd=os.open(self.fifo,os.O_RDWR)
        wrapper=self.out/'reader.sh';wrapper.write_text('#!/bin/sh\nexec "$1" "$2" < "$3"\n');wrapper.chmod(0o700)
        self.log=self.out/'reader.log';self.read=None;self.ident=0
        launcher=Path.home()/'Applications/OpenCapture.app'
        if not launcher.exists():raise RuntimeError('Approved OpenCapture launcher is unavailable')
        self.job=subprocess.Popen(['/usr/bin/open','-n','-W',str(launcher),'--args',str(wrapper),str(self.log),str(helper),str(cfg),str(self.fifo)])
        try:self.ready=self.wait('ready',timeout=20)
        except Exception:
            self.close();raise
        self.window=app.call('window-state')

    def send(self,**value):os.write(self.fd,(json.dumps(value)+'\n').encode())

    def wait(self,event,timeout=10):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            if self.read is None and self.log.exists():self.read=self.log.open()
            line=self.read.readline() if self.read else ''
            if not line:
                if Path(str(self.log)+'.rc').exists():raise RuntimeError('Frame reader exited: '+self.log.read_text())
                time.sleep(.005);continue
            try:row=json.loads(line)
            except ValueError:continue
            if row.get('event')=='error':raise RuntimeError(row['error'])
            if row.get('event')==event:return row
        raise RuntimeError('Frame reader timed out at '+event)

    def measure(self,label,action,duration=600):
        self.ident+=1
        # SCK's configured dimensions define the mapping from window points.
        w=self.window;screen=w['screenFrame'];frame=w['frame']
        sx=self.ready['width']/screen[2];sy=self.ready['height']/screen[3]
        roi=[(frame[0]-screen[0]+120)*sx,(screen[1]+screen[3]-frame[1]-frame[3]+56)*sy,289*sx,(frame[3]-66)*sy]
        self.send(cmd='arm',id=self.ident,roi=roi,duration_ms=duration)
        armed=self.wait('armed')
        start=int(lib.mach_absolute_time());self.send(cmd='mark',id=self.ident,ticks=start);self.wait('marked')
        value=action();returned=int(lib.mach_absolute_time())
        result=self.wait('result',timeout=duration/1000+10)
        result.update(label=label,dispatchTicks=start,returnTicks=returned,clock='mach_absolute_time; socket dispatch boundary',baselineAgeMilliseconds=(start-armed['baseline_ticks'])*TICK_MS)
        changes=result['changes'];gaps=[(b-a)*TICK_MS for a,b in zip(changes,changes[1:])]
        result['changedIntervalsMilliseconds']=gaps
        result['missed120HzIntervals']=sum(max(0,round(gap/(1000/120))-1) for gap in gaps)
        (self.out/(label+'.json')).write_text(json.dumps(result,indent=2))
        return value,result

    def close(self):
        if getattr(self,'job',None) and self.job.poll() is None:
            self.send(cmd='quit')
            try:self.job.wait(timeout=10)
            except subprocess.TimeoutExpired:self.job.terminate();self.job.wait(timeout=10)
        if self.read:self.read.close()
        os.close(self.fd)
