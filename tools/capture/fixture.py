"""Small loopback-only synthetic site for native browser capture blocks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import html
import threading
import time
from urllib.parse import urlsplit


class SyntheticSite:
    def __init__(self, port=39171, other_port=39172):
        if not (1024 <= port <= 65535 and 1024 <= other_port <= 65535 and port != other_port):
            raise ValueError('fixture needs two distinct unprivileged TCP ports')
        self.urls = [f'http://127.0.0.1:{port}', f'http://localhost:{other_port}']
        self.servers = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if len(self.path) > 8192:
                    self.send_error(414)
                    return
                path = urlsplit(self.path).path
                if path == '/favicon.svg':
                    color = '#237A57' if self.server.server_port == port else '#A84B20'
                    payload = f'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" rx="7" fill="{color}"/><circle cx="16" cy="16" r="7" fill="white"/></svg>'.encode()
                    kind = 'image/svg+xml'
                elif path == '/tone.wav':
                    # A quiet synthetic tone (about -54 dBFS), looped by /audio. It is
                    # not silent on purpose: Chromium only marks audible streams.
                    payload = owner.tone()
                    kind = 'audio/wav'
                elif path == '/download.txt':
                    payload = b'Open-capture synthetic attachment. No personal data.\n'
                    kind = 'application/octet-stream'
                elif path == '/download.pdf':
                    payload = owner.pdf()
                    kind = 'application/pdf'
                elif path in ('/large.bin', '/fail.bin'):
                    # Synthetic filler only. /large.bin: 8 MiB over about 60 s (stays in
                    # progress). /fail.bin: announces 4 MiB, then closes after 512 KiB.
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Length', str((8 if path == '/large.bin' else 4) << 20))
                    self.send_header('Content-Disposition', 'attachment; filename="Open-capture-%s"' % path[1:])
                    self.send_header('Cache-Control', 'no-store')
                    self.end_headers()
                    chunk = (b'Open-capture synthetic filler. No personal data.\n' * 1400)[:65536]
                    try:
                        for i in range(128 if path == '/large.bin' else 8):
                            self.wfile.write(chunk); self.wfile.flush(); time.sleep(.47 if path == '/large.bin' else .25)
                        if path == '/fail.bin':
                            self.close_connection = True
                            self.connection.shutdown(2)
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        pass
                    return
                else:
                    titles = {'/video': 'Open-capture video', '/audio': 'Open-capture audio', '/media': 'Open-capture media', '/': 'Open-capture index', '/article': 'Open-capture long article', '/form': 'Open-capture form', '/slow': 'Open-capture slow page', '/lisbon': 'Lisbon weather', '/lemon': 'Lemon pasta', '/long': 'Open-capture ' + 'very long title ' * 16}
                    title = titles.get('/long' if path.startswith('/long') else path, 'Open-capture page ' + path[:80])
                    links = [('/article', 'Long article'), ('/form', 'Form'), ('/download.txt', 'Download synthetic text'), ('/slow', 'Slow page'), ('/lisbon', 'Lisbon weather'), ('/lemon', 'Lemon pasta'), ('/long/' + 'synthetic-path-' * 18, 'Very long URL')] + [(f'/page-{i}', f'Open-capture page {i}') for i in range(5)]
                    body = '<nav>' + ''.join(f'<p><a href="{html.escape(p)}">{label}</a></p>' for p, label in links) + '</nav>'
                    body += f'<p><a href="{owner.urls[1]}/lemon">Cross-site Lemon pasta</a></p>'
                    if path == '/peek':
                        body = f'<p><a href="{owner.urls[1]}/lemon">Cross-site Lemon pasta</a></p>'
                    if path == '/article':
                        body += ''.join(f'<p>Open-capture paragraph {i}. Lemon pasta and Lisbon weather are synthetic search terms. This page has no personal content.</p>' for i in range(60))
                    if path == '/audio':
                        body = '<p>Open-capture quiet looping tone.</p><audio id="a" src="/tone.wav" loop autoplay controls></audio><p><button onclick="document.getElementById(\'a\').play()">Play synthetic tone</button></p>'
                    if path == '/video':
                        body = ('<p>Open-capture synthetic video (canvas stream).</p><video id="v" width="480" height="270" muted autoplay playsinline controls></video>'
                                '<canvas id="c" width="480" height="270" style="display:none"></canvas><script>'
                                'const c=document.getElementById("c"),x=c.getContext("2d"),v=document.getElementById("v");let t=0;'
                                'setInterval(()=>{t++;x.fillStyle="hsl("+(t*3%360)+",60%,45%)";x.fillRect(0,0,480,270);x.fillStyle="#fff";x.font="40px system-ui";x.fillText("Open-capture "+t,40,150)},40);'
                                'v.srcObject=c.captureStream(25);v.play();</script>')
                    if path == '/media':
                        body = '<p>Open-capture <a href="/lisbon">link to Lisbon weather</a> and an image:</p><p><img src="/favicon.svg" width="160" height="160" alt="Open-capture synthetic image"></p><p>Synthetic selectable paragraph about Lemon pasta.</p>'
                    if path == '/form':
                        body += '<form action="/form"><label>Open-capture name <input name="name" autocomplete="off"></label><button>Submit synthetic form</button></form>'
                    payload = ('<!doctype html><html><head><meta charset="utf-8"><title>' + html.escape(title) + '</title><link rel="icon" href="/favicon.svg" type="image/svg+xml"><style>body{font:18px system-ui;margin:48px;max-width:900px;background:#f3f5ef;color:#26372f}a{color:#175d42}p{line-height:1.6}</style></head><body><h1>' + html.escape(title) + '</h1>' + body + '</body></html>').encode()
                    kind = 'text/html; charset=utf-8'
                self.send_response(200)
                self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(payload)))
                self.send_header('Cache-Control', 'no-store')
                if path == '/download.txt':
                    self.send_header('Content-Disposition', 'attachment; filename="Open-capture-synthetic-s2.txt"')
                if path == '/download.pdf':
                    self.send_header('Content-Disposition', 'attachment; filename="Open-capture-synthetic.pdf"')
                self.end_headers()
                try:
                    if path == '/slow':
                        for offset in range(0, len(payload), 128):
                            self.wfile.write(payload[offset:offset+128]); self.wfile.flush(); time.sleep(.4)
                    else:
                        self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass

        try:
            for number in (port, other_port):
                server = ThreadingHTTPServer(('127.0.0.1', number), Handler)
                server.daemon_threads = True
                self.servers.append(server)
                threading.Thread(target=server.serve_forever, daemon=True).start()
        except Exception:
            self.close()
            raise

    @staticmethod
    def pdf():
        # A one-page synthetic PDF with the text "Open-capture synthetic PDF".
        text = b'BT /F1 24 Tf 72 720 Td (Open-capture synthetic PDF) Tj ET'
        objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
                b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
                b'<< /Length %d >>\nstream\n' % len(text) + text + b'\nendstream', b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
        out, offsets = b'%PDF-1.4\n', []
        for i, o in enumerate(objs, 1):
            offsets.append(len(out)); out += b'%d 0 obj\n' % i + o + b'\nendobj\n'
        xref = len(out)
        out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1) + b''.join(b'%010d 00000 n \n' % o for o in offsets)
        return out + b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, xref)

    @staticmethod
    def tone():
        import math, struct
        rate, seconds = 22050, 2
        frames = b''.join(struct.pack('<h', int(65 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(rate * seconds))
        header = b'RIFF' + struct.pack('<I', 36 + len(frames)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate * 2, 2, 16) + b'data' + struct.pack('<I', len(frames))
        return header + frames

    def close(self):
        for server in self.servers:
            server.shutdown(); server.server_close()
        self.servers.clear()
