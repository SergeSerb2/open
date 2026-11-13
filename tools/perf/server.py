#!/usr/bin/env python3
"""Loopback-only static workloads and bounded numerical telemetry collector."""
import functools
from http.server import BaseHTTPRequestHandler
import json
import math
from pathlib import Path
import shutil
import subprocess
import threading
import time
import urllib.request
from urllib.parse import urlsplit, parse_qs
import sys as _sys
_sys.path.append(str(Path(__file__).resolve().parents[1] / 'e2e'))  # loopback_http; appended, so the stdlib wins
from loopback_http import LoopbackHTTPServer

PAGES=Path(__file__).parent/'pages'

class Collector:
    def __init__(self, out, port=0):
        self.out=Path(out);self.out.mkdir(parents=True,exist_ok=True)
        # Generate our own small, silent video outside Git. No media from Arc
        # or the user's profiles is read. Creation happens before timing locks.
        media=Path.home()/'Library/Caches/OpenRE/perf/synthetic-loop.mp4'
        if not media.is_file():
            encoder=shutil.which('ffmpeg')
            if not encoder:raise RuntimeError('ffmpeg is needed for the synthetic media fixture')
            media.parent.mkdir(parents=True,exist_ok=True)
            temporary=media.with_name('synthetic-loop-tmp.mp4')
            subprocess.run([encoder,'-hide_banner','-loglevel','error','-y',
                '-f','lavfi','-i','testsrc2=size=160x90:rate=15','-t','2','-an',
                '-c:v','libx264','-pix_fmt','yuv420p','-movflags','+faststart',str(temporary)],
                check=True,timeout=30)
            temporary.replace(media)
        destination=self.out/'video.mp4'
        if not destination.exists():destination.symlink_to(media)
        self.events=[];self.condition=threading.Condition()
        # 20,000 bounded records. /events returns at most 2,000 × 4 KiB;
        # its worst JSON byte allocation stays below 9 MiB.
        self.max_events=20_000
        self.asset_epoch='seed'
        owner=self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_POST(self):
                if self.path!='/collect':self.send_error(404);return
                try:length=int(self.headers.get('Content-Length','0'))
                except ValueError:self.send_error(400);return
                if not 0<length<=16384:self.send_error(413);return
                try:
                    record=json.loads(self.rfile.read(length))
                    if not isinstance(record,dict):raise ValueError('Expected a record')
                    # Explicit allowlist: no browser URLs, titles or headers.
                    allowed={'run','event','time_origin_ms','fcp_ms','lcp_ms','load_ms','score','benchmark','delay_ms','tab','visibility','resource_network_count','resource_cache_count','error','viewport_width','viewport_height'}
                    record={k:v for k,v in record.items() if k in allowed and isinstance(v,(str,int,float,bool,type(None)))}
                    if any(isinstance(v,float) and not math.isfinite(v) for v in record.values()):raise ValueError('Non-finite record')
                    if len(json.dumps(record))>4096:raise ValueError('large record')
                    record['collector_wall_ms']=time.time()*1000
                    with owner.condition:
                        if len(owner.events)>=owner.max_events:
                            self.send_error(507,'Telemetry record limit reached');return
                        owner.events.append(record)
                        with (owner.out/'collector.jsonl').open('a') as f:f.write(json.dumps(record)+'\n')
                        owner.condition.notify_all()
                except (ValueError,TypeError,RecursionError):self.send_error(400);return
                self.send_response(204);self.end_headers()
            def do_GET(self):
                if len(self.path)>8192:self.send_error(414);return
                u=urlsplit(self.path);q=parse_qs(u.query)
                if u.path=='/events':
                    after=float(q.get('after',['0'])[0]);run=q.get('run',[None])[0];event=q.get('event',[None])[0]
                    with owner.condition:
                        records=[r for r in owner.events if r['collector_wall_ms']>=after and (run is None or r.get('run')==run) and (event is None or r.get('event')==event)]
                    data=json.dumps(records[-2000:]).encode()
                    self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)))
                    self.end_headers();self.wfile.write(data);return
                if u.path=='/command.html':
                    payload=json.dumps({'command':'close','keep':q.get('keep',[''])[0]})
                    data=("<!doctype html><meta charset=utf-8><script>const c=new BroadcastChannel('open-perf');"
                          f"c.postMessage({payload});setTimeout(()=>window.close(),200);</script>").encode()
                else:
                    name=u.path.lstrip('/') or 'report.html'
                    aliases={'static-cold.html':'static.html','static-warm.html':'static.html','heavy-dom-cold.html':'heavy-dom.html','heavy-dom-warm.html':'heavy-dom.html'}
                    name=aliases.get(name,name)
                    if '/' in name or name.startswith('.') or name not in {'interaction.html','static.html','animated.html','heavy-dom.html','media.html','report.html','reporter.js','image.svg','video.mp4'}:
                        self.send_error(404);return
                    source=(owner.out/'video.mp4') if name=='video.mp4' else PAGES/name
                    if not source.is_file():self.send_error(404);return
                    delay=min(2.,max(0.,float(q.get('delay_ms',['0'])[0])/1000))
                    if delay:time.sleep(delay)
                    data=source.read_bytes()
                    if name.endswith('.html'):
                        key=q.get('assetkey',[owner.asset_epoch+'-'+name])[0]
                        # The cold and warm documents use one paired asset key.
                        from urllib.parse import quote
                        for asset in ('reporter.js','image.svg','video.mp4'):
                            data=data.replace(('"'+asset+'"').encode(),('"'+asset+'?cache=warm&key='+quote(key,safe='')+'"').encode())
                self.send_response(200)
                self.send_header('Content-Type','text/javascript' if u.path.endswith('.js') else 'image/svg+xml' if u.path.endswith('.svg') else 'video/mp4' if u.path.endswith('.mp4') else 'text/html; charset=utf-8')
                self.send_header('Content-Length',str(len(data)))
                self.send_header('Cache-Control','no-store' if u.path.endswith('.html') or q.get('cache',['cold'])[0]=='cold' else 'public,max-age=3600')
                self.end_headers()
                try:self.wfile.write(data)
                except (BrokenPipeError,ConnectionResetError):pass
        self.http=LoopbackHTTPServer(Handler, port)
        self.url=f'http://127.0.0.1:{self.http.server_port}'
        self.thread=threading.Thread(target=self.http.serve_forever,daemon=True);self.thread.start()
    def wait(self,run,event='loaded',timeout=45,after_wall_ms=0,visible=False):
        deadline=time.monotonic()+timeout
        with self.condition:
            while time.monotonic()<deadline:
                for row in reversed(self.events):
                    if row.get('run')==run and row.get('event')==event and row['collector_wall_ms']>=after_wall_ms and (not visible or row.get('visibility')=='visible'):return row
                self.condition.wait(min(1,max(0,deadline-time.monotonic())))
        raise RuntimeError(f'no {event} telemetry for synthetic run {run}')
    def close(self):
        self.http.shutdown();self.http.server_close();self.thread.join()

class CollectorClient:
    """A worker view of the campaign's persistent loopback collector."""
    def __init__(self,url):self.url=url;self.api_url=url;self.after_wall_ms=0
    @property
    def events(self):
        with urllib.request.urlopen(self.api_url+'/events',timeout=5) as response:return json.load(response)
    def wait(self,run,event='loaded',timeout=45,after_wall_ms=0,visible=False):
        from urllib.parse import urlencode
        query=urlencode({'run':run,'event':event,'after':max(after_wall_ms,self.after_wall_ms)})
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            with urllib.request.urlopen(self.api_url+'/events?'+query,timeout=5) as response:rows=json.load(response)
            rows=[r for r in rows if not visible or r.get('visibility')=='visible']
            if rows:return rows[-1]
            time.sleep(.05)
        raise RuntimeError(f'no {event} telemetry for synthetic run {run}')
    def close(self):pass
