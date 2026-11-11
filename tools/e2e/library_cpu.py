"""Read-only libproc CPU attribution for the real Open bundle tree.

Darwin task times are Mach ticks; thread times are already nanoseconds.
No process attach, sampler or privilege change is used.
"""
import ctypes
import re
import subprocess
from pathlib import Path

lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
lib.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
lib.proc_pidinfo.restype=ctypes.c_int
class Timebase(ctypes.Structure):_fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
system=ctypes.CDLL('/usr/lib/libSystem.B.dylib');tb=Timebase();system.mach_timebase_info(ctypes.byref(tb));NANOSECONDS_PER_TICK=tb.numer/tb.denom
class TaskInfo(ctypes.Structure):
 _fields_=[(x,ctypes.c_uint64) for x in ['virtual','resident','user','system','threadsUser','threadsSystem']]+[(x,ctypes.c_int32) for x in ['policy','faults','pageins','cow','messagesSent','messagesReceived','machCalls','unixCalls','switches','threads','running','priority']]
class ThreadInfo(ctypes.Structure):
 _fields_=[('user',ctypes.c_uint64),('system',ctypes.c_uint64)]+[(x,ctypes.c_int32) for x in ['usage','policy','state','flags','sleep','currentPriority','priority','maxPriority']]+[('name',ctypes.c_char*64)]
def read(pid,flavor,arg,kind):
 value=kind();got=lib.proc_pidinfo(pid,flavor,arg,ctypes.byref(value),ctypes.sizeof(value))
 if got!=ctypes.sizeof(value):raise OSError(ctypes.get_errno(),f'proc_pidinfo pid={pid} flavor={flavor} got={got}')
 return value
def snapshot(app):
 processes={};unavailable=[]
 for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
  parts=line.strip().split(None,1)
  if len(parts)!=2 or not parts[1].startswith(str(app.bundle)+'/'):continue
  pid=int(parts[0])
  try:
   task=read(pid,4,0,TaskInfo)
   command=subprocess.check_output(['ps','-p',str(pid),'-o','args='],text=True,stderr=subprocess.DEVNULL)
  except (ProcessLookupError,FileNotFoundError,subprocess.CalledProcessError) as error:
   if pid==app.pid:raise
   unavailable.append({'pid':pid,'reason':'exited between enumeration and counter read','error':type(error).__name__})
   continue
  match=re.search(r'--type=([^\s]+)',command)
  processes[str(pid)]={'role':'App' if pid==app.pid else match.group(1) if match else Path(parts[1]).name,'cpuNanoseconds':(task.user+task.system)*NANOSECONDS_PER_TICK,'machCalls':task.machCalls,'unixCalls':task.unixCalls,'contextSwitches':task.switches}
 ids=(ctypes.c_uint64*4096)();size=lib.proc_pidinfo(app.pid,6,0,ids,ctypes.sizeof(ids))
 if size<=0:raise OSError(ctypes.get_errno(),'PROC_PIDLISTTHREADS failed')
 threads={}
 for tid in list(ids)[:size//8]:
  try:t=read(app.pid,5,tid,ThreadInfo)
  except OSError:continue
  threads[str(tid)]={'name':bytes(t.name).decode(errors='replace'),'cpuNanoseconds':(t.user+t.system)}
 if not threads:raise RuntimeError('No App thread counters were readable')
 return {'processes':processes,'threads':threads,'unavailableProcesses':unavailable}
def delta(before,after,seconds):
 def rows(key):
  output=[]
  for identity,end in after[key].items():
   if identity not in before[key]:continue
   start=before[key][identity]
   output.append(dict(id=identity,**end,cpuPercent=100*(end['cpuNanoseconds']-start['cpuNanoseconds'])/1e9/seconds))
  return sorted(output,key=lambda x:x['cpuPercent'],reverse=True)
 return {'processes':rows('processes'),'threads':rows('threads'),
         'exitedProcessIDs':sorted(set(before['processes'])-set(after['processes'])),
         'appearedProcessIDs':sorted(set(after['processes'])-set(before['processes'])),
         'unavailableBefore':before.get('unavailableProcesses',[]),'unavailableAfter':after.get('unavailableProcesses',[])}
