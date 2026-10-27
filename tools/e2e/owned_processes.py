"""Own-process cleanup and window receipts. Never activate or input to another app."""
import ctypes
import os
import signal
import subprocess
import time

_libproc = ctypes.CDLL('/usr/lib/libproc.dylib')

def executable(pid):
    path = ctypes.create_string_buffer(4096)
    size = _libproc.proc_pidpath(int(pid), path, len(path))
    return os.path.realpath(os.fsdecode(path.value)) if size > 0 else ''

def process_tree(pid):
    pairs = [tuple(map(int, line.split())) for line in subprocess.check_output(['ps','-axo','pid=,ppid='],text=True).splitlines() if line.strip()]
    found = {int(pid)}
    while True:
        children = {p for p,parent in pairs if parent in found}
        if children <= found: break
        found |= children
    return {p: executable(p) for p in found if executable(p)}

def kill_known(processes):
    killed=[]
    for pid,path in sorted(processes.items(),reverse=True):
        if path and executable(pid)==path:
            try: os.kill(pid,signal.SIGKILL);killed.append(pid)
            except ProcessLookupError: pass
    return killed

def on_screen_windows(pids):
    """CGWindowList filtered by PID before reading any title or other metadata."""
    pids=set(pids)
    cg=ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cf=ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    ptr=ctypes.c_void_p
    cg.CGWindowListCopyWindowInfo.argtypes=[ctypes.c_uint32,ctypes.c_uint32];cg.CGWindowListCopyWindowInfo.restype=ptr
    cf.CFArrayGetCount.argtypes=[ptr];cf.CFArrayGetCount.restype=ctypes.c_long
    cf.CFArrayGetValueAtIndex.argtypes=[ptr,ctypes.c_long];cf.CFArrayGetValueAtIndex.restype=ptr
    cf.CFDictionaryGetValue.argtypes=[ptr,ptr];cf.CFDictionaryGetValue.restype=ptr
    cf.CFNumberGetValue.argtypes=[ptr,ctypes.c_int,ptr]
    cf.CFStringGetCString.argtypes=[ptr,ptr,ctypes.c_long,ctypes.c_uint32]
    cf.CFRelease.argtypes=[ptr]
    keys={name:ptr.in_dll(cg,name).value for name in ['kCGWindowOwnerPID','kCGWindowNumber','kCGWindowName','kCGWindowLayer']}
    def number(entry,key):
        value=cf.CFDictionaryGetValue(entry,keys[key]);out=ctypes.c_longlong()
        return out.value if value and cf.CFNumberGetValue(value,4,ctypes.byref(out)) else 0
    info=cg.CGWindowListCopyWindowInfo(1|16,0)
    if not info: raise RuntimeError('CGWindowList could not enumerate owned windows')
    result=[]
    try:
        count=cf.CFArrayGetCount(info)
        if count>65536:raise RuntimeError('CGWindowList exceeds safety bound')
        for i in range(count):
            entry=cf.CFArrayGetValueAtIndex(info,i);pid=number(entry,'kCGWindowOwnerPID')
            if pid not in pids:continue
            title=cf.CFDictionaryGetValue(entry,keys['kCGWindowName']);buf=ctypes.create_string_buffer(4096)
            text=buf.value.decode('utf-8','replace') if title and cf.CFStringGetCString(title,buf,len(buf),0x08000100) else ''
            result.append({'pid':pid,'number':number(entry,'kCGWindowNumber'),'title':text or '(untitled owned window)','layer':number(entry,'kCGWindowLayer')})
    finally:cf.CFRelease(info)
    return result

def wait_no_windows(pids,timeout=3):
    deadline=time.monotonic()+timeout
    while True:
        windows=on_screen_windows(pids)
        if not windows or time.monotonic()>=deadline:return windows
        time.sleep(.05)

def run_owned_process(command,**kwargs):
    """Subprocesses that may show an alert always own a killable session."""
    timeout=kwargs.pop('timeout',15)
    proc=subprocess.Popen(command,start_new_session=True,**kwargs)
    timed_out=False;before=[]
    try:
        try:proc.wait(timeout)
        except subprocess.TimeoutExpired:
            timed_out=True
            try:before=on_screen_windows([proc.pid])
            except Exception as error:before=[{'error':str(error)}]
            os.killpg(proc.pid,signal.SIGKILL);proc.wait(3)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid,signal.SIGKILL);proc.wait(3)
    remaining=wait_no_windows([proc.pid])
    if remaining:
        try:os.killpg(proc.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        remaining=wait_no_windows([proc.pid])
    result=subprocess.CompletedProcess(command,proc.returncode)
    result.cleanup={'pid':proc.pid,'timeout':timed_out,'windowsAtTimeout':before,'remainingWindows':remaining,'ok':not timed_out and not remaining}
    return result
