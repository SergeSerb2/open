#!/usr/bin/env python3
"""Section 5 real-App measurements. Caller owns quiet, heavy, then screen locks.

Requires matched Release + OPEN_AUTOMATION builds with WindowMaterialMeasurement.
Uses only the App socket, never desktop input. Receipts include every sample/load.
"""
import argparse
import http.server
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import threading
import tempfile
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('engine_e2e', ROOT/'tools/e2e/engine_e2e.py')
E = importlib.util.module_from_spec(spec)
spec.loader.exec_module(E)


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        background = '#151515' if self.path == '/band' else '#ffffff'
        body = ('<!doctype html><html><meta charset=utf-8><title>S5 static fixture</title>'
                '<style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:'+background+
                '}#band{position:absolute;top:240px;left:0;width:100%;height:160px;background:#ededed}'
                'p{color:#777;padding:40px;font:24px sans-serif}</style><p>Open static material fixture</p>'
                + ('<div id=band></div>' if self.path == '/band' else '')).encode()
        self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args):
        pass


def stamp():
    return dict(time=time.monotonic(), load=list(os.getloadavg()))


class Monitor:
    def __init__(self, pid):
        self.pid = pid; self.samples = []; self.done = threading.Event()
    def __enter__(self):
        self.thread = threading.Thread(target=self.run, daemon=True); self.thread.start(); return self
    def run(self):
        ws = subprocess.check_output(['pgrep','-x','WindowServer'],text=True).strip()
        while not self.done.is_set():
            row = stamp()
            try:
                raw = subprocess.check_output(['ioreg','-a','-r','-d','1','-c','IOAccelerator'])
                row['gpu'] = [v.get('PerformanceStatistics',{}) for v in plistlib.loads(raw)]
                row['cpu'] = subprocess.check_output(['ps','-o','pid=,%cpu=,time=','-p',str(self.pid)+','+ws],text=True)
            except Exception as error:
                row['error'] = str(error)
            self.samples.append(row); self.done.wait(.2)
    def __exit__(self, *args):
        self.done.set(); self.thread.join()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--bundle',required=True); p.add_argument('--label',required=True)
    p.add_argument('--out',required=True); p.add_argument('--probe',required=True)
    p.add_argument('--bench',required=True); p.add_argument('--cycles',type=int,default=20)
    p.add_argument('--only',choices=('full','activation','scroll'),default='full')
    a = p.parse_args(); out = Path(a.out).resolve(); out.mkdir(parents=True,exist_ok=True)
    receipt = dict(label=a.label, bundle=a.bundle, start=stamp(), cycles=a.cycles, motion={}, idle={}, activation={},status='RUNNING')
    def bench():
        receipt['benchStart'] = stamp()
        result = subprocess.run([a.bench,'bench','--rows','1000','--scale','2'],capture_output=True,text=True)
        receipt['benchEnd'] = stamp(); receipt['bench'] = dict(code=result.returncode,stdout=result.stdout,stderr=result.stderr)
        (out/'bench.txt').write_text(result.stdout+result.stderr)
        return result.returncode
    receipt['kind'] = a.only
    if a.only == 'scroll':
        code = bench(); receipt['status'] = 'COMPLETE' if code == 0 else 'ERROR'
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2))
        print(json.dumps(receipt,indent=2),flush=True)
        return code
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Page)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    origin = 'http://127.0.0.1:'+str(server.server_port)
    app = None; exitcode = 1
    def save():
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2))
    save()
    def state():
        return app.call('window-state')
    def move(x):
        return app.call('mouse',action='move',x=x,y=400)
    def wait(shown):
        value = E.wait_card(app,shown)
        if value is None: raise RuntimeError('Card did not settle: '+str(state()['reveal']))
        return value
    try:
        profile = out/'profile'
        if len(os.fsencode(profile/'automation.sock')) > 100:
            profiles = ROOT/'.re/s5-perf/profile'; profiles.mkdir(parents=True,exist_ok=True)
            profile = Path(tempfile.mkdtemp(prefix='p-',dir=profiles))
        if len(os.fsencode(profile/'automation.sock')) > 100:
            raise RuntimeError('Automation profile path exceeds the Unix socket limit')
        receipt['profile'] = str(profile)
        app = E.Open('Release','chrome',str(profile),['--use-mock-keychain'],str(out/'app.log'),
                     urls=(origin+'/band',),extra_env={'OPEN_E2E_APP_BUNDLE':a.bundle,
                     'DYLD_INSERT_LIBRARIES':a.probe})
        receipt['pid'] = app.pid
        E.place_away_from_cursor(app,1280,900)
        initial = state(); wid = initial['id']
        app.call('window-focus',id=wid,activate=True)
        app.call('suggest-remote',enabled=False)
        app.call('window-motion',reduced=False,sampleCard=False)
        app.call('window-material-probe',op='observe')
        tid = app.call('tabs')[0]['id']; app.call('wait',tab=tid)
        if state()['sidebarMode'] != 'hidden': app.call('menu-perform',id='toggle-sidebar')
        time.sleep(.4); move(700)
        for page in (('band','white') if a.only == 'full' else ()):
            print(a.label,'motion',page,stamp(),flush=True)
            app.call('navigate',tab=tid,url=origin+'/'+page); app.call('wait',tab=tid)
            time.sleep(.5)
            app.call('window-material-probe',op='start')
            cycles = []; start = stamp()
            with Monitor(app.pid) as monitor:
                for index in range(a.cycles):
                    row = dict(index=index,start=stamp())
                    move(3); row['shown'] = wait(True); time.sleep(.12)
                    row['showMotion'] = app.call('window-motion')['card']
                    move(700); row['hidden'] = wait(False); time.sleep(.08)
                    cycles.append(row)
            motion = app.call('window-material-probe',op='stop')
            receipt['motion'][page] = dict(start=start,end=stamp(),cycles=cycles,
                                           samples=monitor.samples,probe=motion)
            save()
        for shown in ((True,False) if a.only == 'full' else ()):
            print(a.label,'idle','shown' if shown else 'hidden',stamp(),flush=True)
            move(3 if shown else 700); wait(shown); time.sleep(1)
            key = 'shown' if shown else 'hidden'; before = state()
            app.call('snapshot',path=str(out/('idle-'+key+'.png')))
            time.sleep(.3)
            with Monitor(app.pid) as monitor:
                observation = app.call('window-material-probe',op='idle')
            receipt['idle'][key] = dict(startState=before,endState=state(),probe=observation,
                                        samples=monitor.samples,end=stamp())
            save()
        # Key changes remain inside our two windows. Snapshot follows a settled
        # observation, so snapshot preparation cannot force the measured rebuild.
        app.call('menu-perform',id='new-window'); second = state()['id']
        print(a.label,'activation',stamp(),flush=True)
        app.call('window-frame',frame=[1420,80,1000,900]); time.sleep(.4)
        app.call('window-focus',id=wid,activate=True); time.sleep(.2)
        app.call('window-material-probe',op='start')
        switches = []
        for index in range(20):
            target = second if index % 2 == 0 else wid
            app.call('window-material-probe',op='arm')
            row = dict(target=target,start=stamp()); t = time.perf_counter()
            app.call('window-focus',id=target,activate=True)
            row['roundTripMs'] = (time.perf_counter()-t)*1000
            time.sleep(.08)
            if index < 2:
                t = time.perf_counter(); app.call('snapshot',path=str(out/('activation-'+str(index)+'.png')))
                row['settledSnapshotMs'] = (time.perf_counter()-t)*1000
            switches.append(row)
        receipt['activation'] = dict(switches=switches,probe=app.call('window-material-probe',op='stop'),end=stamp())
        events = app.call('activation-events'); receipt['activationEvents'] = events
        start_uptime = initial.get('uptime', 0)
        # Initial launch can precede foreground grant. Only events after the
        # first motion sampler start are part of measured foreground intervals.
        start_uptime = min((v['probe']['started'] for v in receipt['motion'].values()),
                           default=receipt['activation']['probe']['started'])
        outside = [e for e in events if e['uptime'] >= start_uptime and
                   ((e['event']=='frontmostChanged' and e.get('frontmostPID') not in (None,0,app.pid)) or
                    e['event']=='NSApplicationDidResignActiveNotification')]
        receipt['interruptions'] = outside
        receipt['status'] = 'INTERRUPTED' if outside else 'COMPLETE'
        exitcode = 75 if outside else 0
    except Exception:
        receipt['status'] = 'ERROR'; receipt['error'] = traceback.format_exc()
        # The constructor already cleans up after a readiness timeout. Retain
        # that owned instance's cleanup report even though assignment failed.
        if app is None and E._OWNED_APPS: app = E._OWNED_APPS[-1]
    finally:
        if app:
            app.quit(); receipt['quit'] = app.quit_report
        server.shutdown(); receipt['end'] = stamp(); save()
    # This bench uses an offscreen native window and a prohibited activation
    # policy. It runs after our App quits and cannot take the user's foreground.
    if exitcode == 0:
        exitcode = bench(); save()
    print(json.dumps({k:receipt.get(k) for k in ('label','status','error','start','end','quit')},indent=2),flush=True)
    return exitcode


if __name__ == '__main__':
    raise SystemExit(main())
