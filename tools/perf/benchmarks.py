#!/usr/bin/env python3
"""Serve pinned external benchmarks with a numerical callback, no desktop input.

No third-party source is vendored. A preflight checks inputs only; accepted
scores require real, guarded browser completions from campaign.py.
"""
import argparse
import json
import mimetypes
from pathlib import Path
import re
from urllib.parse import urlsplit
from server import Collector
from run import command

CACHE=Path.home()/'Library/Caches/OpenRE/perf'
CHECKOUTS={
 'speedometer':('Speedometer-3.1','1386415be8fef2f6b6bbdbe1828872471c5d802a',''),
 'jetstream':('JetStream-2.2','332d8ee1e4d5c40d9492c56f6865e64a9525ee9f',''),
 'motionmark':('MotionMark-1.3','5d9c88136d59c11daf78d539c73e4e3e88c091ab','MotionMark'),
}

class BenchmarkCollector(Collector):
    def __init__(self,out,port=0):
        self.roots={};self.revisions={}
        for key,(directory,revision,suffix) in CHECKOUTS.items():
            root=CACHE/directory
            actual=command(['git','-C',root,'rev-parse','HEAD']).strip()
            if actual!=revision:raise RuntimeError(f'{key} checkout differs from pinned revision')
            if command(['git','-C',root,'status','--porcelain']).strip():raise RuntimeError(f'{key} checkout is modified')
            self.roots[key]=root/suffix;self.revisions[key]=revision
        super().__init__(out,port=port)
        old=self.http.RequestHandlerClass;owner=self
        class Handler(old):
            def do_GET(self):
                path=urlsplit(self.path).path
                if path=='/benchmark-reporter.js':
                    data=(Path(__file__).with_name('benchmark-reporter.js')).read_bytes();kind='text/javascript'
                elif path.startswith('/bench/'):
                    parts=path.split('/',4)
                    if len(parts)!=5 or parts[2] not in owner.roots or not re.fullmatch('[a-zA-Z0-9-]+',parts[3]):
                        self.send_error(400);return
                    name,token,relative=parts[2:]
                    root=owner.roots[name].resolve();source=(root/relative).resolve()
                    if source.is_dir():source=source/'index.html'
                    if not source.is_relative_to(root) or not source.is_file():self.send_error(404);return
                    data=source.read_bytes();kind=mimetypes.guess_type(source)[0] or 'application/octet-stream'
                    if kind=='text/html':
                        cfg=json.dumps({'name':name,'run':token})
                        hook=('<script>(()=>{let n=0;const c='+cfg+';addEventListener("error",e=>{if(n++<8)navigator.sendBeacon("/collect",new Blob([JSON.stringify({run:c.run,benchmark:c.name,event:"benchmark-error",error:String(e.message).slice(0,256)})],{type:"application/json"}))})})()</script>').encode()
                        data=data.replace(b'</head>',hook+b'</head>',1)
                    if relative=='index.html':
                        cfg=json.dumps({'name':name,'run':token})
                        data=data.replace(b'</body>',f'<script>window.openPerfBenchmark={cfg}</script><script src="/benchmark-reporter.js?run={token}"></script></body>'.encode())
                else:return super().do_GET()
                self.send_response(200);self.send_header('Content-Type',kind)
                self.send_header('Content-Length',str(len(data)))
                if path=='/benchmark-reporter.js' or relative=='index.html':
                    self.send_header('Cache-Control','no-store')
                self.send_header('Cross-Origin-Opener-Policy','same-origin')
                self.send_header('Cross-Origin-Embedder-Policy','require-corp')
                self.end_headers()
                try:self.wfile.write(data)
                except (BrokenPipeError,ConnectionResetError):pass
        self.http.RequestHandlerClass=Handler
    def benchmark_url(self,name,token):return self.url+f'/bench/{name}/{token}/index.html'

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--preflight',action='store_true');a=p.parse_args()
    collector=BenchmarkCollector(a.out)
    try:
        print(json.dumps({'url':collector.url,'revisions':collector.revisions,'status':'PREPARATION ONLY'}),flush=True)
        if not a.preflight:raise RuntimeError('Use through a guarded real-browser worker; standalone server mode is intentionally unavailable')
    finally:collector.close()

if __name__=='__main__':main()
