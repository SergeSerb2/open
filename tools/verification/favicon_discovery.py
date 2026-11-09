"""Direct-site discovery through the real release CLI, HTTP server and SQLite."""
import json
from pathlib import Path
import sqlite3
import struct
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def run(cli, snapshot, site, origin, env, invoke, require):
    def image(size):
        def chunk(kind, body):
            return struct.pack('>I',len(body))+kind+body+struct.pack('>I',zlib.crc32(kind+body))
        return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',size,size,8,6,0,0,0)) \
            +chunk(b'IDAT',zlib.compress((b'\x00'+b'\x40\x80\xc0\xff'*size)*size))+chunk(b'IEND',b'')
    for name,size in [('touch',128),('small',64),('large',1024),('manifest',512),('link',256),('fallback',64)]:
        (site/(name+'.png')).write_bytes(image(size))
    (site/'favicon.ico').write_bytes(image(64))
    manifest = dict(icons=[dict(src='/large.png',sizes='1024x1024'),
        dict(src='/manifest.png',sizes='512x512'),dict(src='/small.png',sizes='64x64')])
    (site/'icons.webmanifest').write_text(json.dumps(manifest))
    apple = '<link rel="apple-touch-icon" href="/touch.png" sizes="128x128">'
    small = '<link rel="apple-touch-icon" href="/small.png" sizes="64x64">'
    declared = '<link rel="icon" href="/small.png" sizes="64x64"><link rel="icon" href="/link.png" sizes="256x256">'
    linked_manifest = '<link rel="manifest" href="/icons.webmanifest">'
    cases = [('touch',apple+linked_manifest+declared,'apple-touch',128),
        ('manifest',linked_manifest+declared,'manifest',512),
        ('small-touch',small+linked_manifest+declared,'manifest',512),
        ('link',declared,'link',256),('fallback','','favicon.ico',64)]
    observed=[]
    for label,head,kind,size in cases:
        (site/'index.html').write_text('<html><head>'+head+'</head><body>Open icon discovery</body></html>')
        database='discovery-'+label+'.sqlite3'
        invoke(cli,'favicons','fetch','--snapshot',snapshot,'--db',database,'--treat-as-public','127.0.0.1',env=env)
        with sqlite3.connect(database) as db:
            row=db.execute('SELECT image_info FROM favicons WHERE status=0').fetchone()
        require(row is not None,'discovery did not store an icon')
        info=json.loads(row[0]); observed.append(info)
        require(info['sourceKind']==kind and info['width']==info['height']==size and info['opaque'],
            'wrong direct-site icon preference or source dimensions: '+label)
        cached=invoke(cli,'favicons','fetch','--snapshot',snapshot,'--db',database,env=env)
        require('alreadyCached=1 fetched=0' in cached,'discovery did not reuse persisted icon')
    require(observed[0]['sourceKind'] != observed[1]['sourceKind'], 'apple preference negative proof did not change')
    # Exercise the entry boundary through the same CLI and HTTP route.
    for count,kind in [(64,'manifest'),(65,'link')]:
        manifest['icons'] = [dict(src='/manifest.png',sizes='512x512')] + [dict(src='/small.png',sizes='64x64')]*(count-1)
        (site/'icons.webmanifest').write_text(json.dumps(manifest))
        (site/'index.html').write_text('<head>'+linked_manifest+declared+'</head>')
        database='manifest-boundary-'+str(count)+'.sqlite3'
        invoke(cli,'favicons','fetch','--snapshot',snapshot,'--db',database,'--treat-as-public','127.0.0.1',env=env)
        with sqlite3.connect(database) as db:
            info=json.loads(db.execute('SELECT image_info FROM favicons WHERE status=0').fetchone()[0])
        require(info['sourceKind']==kind,'manifest entry boundary failed')
    manifest['icons'] = [dict(src='/manifest.png',sizes='512x512')]
    encoded = json.dumps(manifest).encode()
    for count,kind in [(64*1024,'manifest'),(64*1024+1,'link')]:
        (site/'icons.webmanifest').write_bytes(encoded+b' '*(count-len(encoded)))
        database='manifest-bytes-'+str(count)+'.sqlite3'
        invoke(cli,'favicons','fetch','--snapshot',snapshot,'--db',database,'--treat-as-public','127.0.0.1',env=env)
        with sqlite3.connect(database) as db:
            info=json.loads(db.execute('SELECT image_info FROM favicons WHERE status=0').fetchone()[0])
        require(info['sourceKind']==kind,'manifest byte boundary failed')
    for size,expected in [(1024,0),(1025,1)]:
        Path('dimension.png').write_bytes(image(size))
        invoke(cli,'favicons','ingest','https://dimensions.invalid/','--db','dimensions.sqlite3',
            '--file','dimension.png',expected=expected,env=env)
    for elements,expected in [(2048,0),(2049,1)]:
        Path('static.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">'
            + '<rect width="128" height="128" fill="#3e8ec1"/>'*(elements-1) + '</svg>')
        invoke(cli,'favicons','ingest','https://vector.invalid/','--db','vectors.sqlite3',
            '--file','static.svg',expected=expected,env=env)
    for depth,expected in [(32,0),(33,1)]:
        Path('depth.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128">'
            + '<g>'*(depth-2) + '<rect width="128" height="128" fill="#3e8ec1"/>' + '</g>'*(depth-2) + '</svg>')
        invoke(cli,'favicons','ingest','https://vector.invalid/depth','--db','vectors.sqlite3',
            '--file','depth.svg',expected=expected,env=env)
    Path('external.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128">'
        '<use href="https://example.invalid/external.svg#icon"/></svg>')
    invoke(cli,'favicons','ingest','https://vector.invalid/external','--db','vectors.sqlite3',
        '--file','external.svg',expected=1,env=env)
    print('FV13 direct HTTP discovery: apple >=120, manifest largest <=512, link largest, fallback, persisted metadata/cache; negatives PASS')
    print('FV14 manifest entry cap refused; source dimensions accept 1024 and refuse 1025: PASS')
    print('FV20 real CLI SVG: 128 px raster; accept 2048 static elements, refuse 2049 and external resources PASS')
    # A real HTTP redirect and Set-Cookie traverse the release CLI's PSL guard
    # and ephemeral session. The cross-site target must receive no connection.
    requests = []
    cross_site = False
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            requests.append((self.path, self.headers.get('Cookie'), self.headers.get('Authorization')))
            if self.path == '/page':
                self.send_response(302)
                self.send_header('Location', 'http://localhost:%d/landing' % http.server_port if cross_site else '/landing')
                self.send_header('Set-Cookie', 'open_fixture=synthetic; Path=/')
                self.end_headers()
            elif self.path == '/landing':
                self.send_response(200); self.end_headers()
                self.wfile.write(b'<head><link rel="apple-touch-icon" href="/touch.png" sizes="128x128"></head>')
            elif self.path == '/touch.png':
                self.send_response(200); self.end_headers(); self.wfile.write(image(128))
            else:
                self.send_response(404); self.end_headers()
    original = (Path(snapshot)/'State/browser.json').read_bytes()
    http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=http.serve_forever, daemon=True); worker.start()
    try:
        data = json.loads(original)
        data['profiles'][0]['favorites'][0]['tab']['_0']['url'] = 'http://127.0.0.1:%d/page' % http.server_port
        (Path(snapshot)/'State/browser.json').write_text(json.dumps(data))
        for blocked in (False, True):
            cross_site = blocked; requests.clear()
            text = invoke(cli, 'favicons', 'fetch', '--snapshot', snapshot, '--db', 'redirect-%s.sqlite3' % blocked,
                '--treat-as-public', '127.0.0.1', env=env)
            require(('fetched=0 missing=0 failed=1' if blocked else 'fetched=1 missing=0 failed=0') in text,
                'redirect site boundary result differs')
            require(all(cookie is None and auth is None for _,cookie,auth in requests), 'credentials sent by icon fetch')
            require(('/landing' in [path for path,_,_ in requests]) != blocked,
                'cross-site redirect connected or same-site redirect failed')
        print('FV19 real HTTP redirects: same site accepted, cross-site refused before connection, no cookies/credentials PASS')
    finally:
        http.shutdown(); http.server_close(); worker.join()
        (Path(snapshot)/'State/browser.json').write_bytes(original)
    (site/'favicon.ico').unlink()
