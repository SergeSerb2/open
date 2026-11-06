"""Local ads and Boost pages from the Site Control plan, plus the scroll page."""
from contextlib import contextmanager
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial
from pathlib import Path
import threading


@contextmanager
def fixture_server(tmp):
    root = Path(tmp) / 'sitecontrol-web'
    root.mkdir(exist_ok=True)
    (root / 'ad.js').write_text('window.adLoaded=(window.adLoaded||0)+1')
    common = '<div id="promo-banner">Promotion</div><script>window.clicks=0;document.addEventListener("click",()=>window.clicks++);if(!location.search)document.cookie="f=1;path=/";</script>'
    (root / 'ads.html').write_text('<!doctype html><style>body{background:white;margin:0;min-height:3000px}</style><h1>Site control fixture</h1>' + common + '<script src="/ad.js"></script>')
    (root / 'boost.html').write_text('<!doctype html><style>body{background:#fff;margin:0}header{width:600px;height:300px;background:#2E7DF6}</style><header></header><h1>Boost fixture</h1>' + '<article>Article</article>' * 3 + common)
    (root / 'heavy.html').write_text('<!doctype html><style>body{margin:0;background:white}.card{height:70px;background:linear-gradient(90deg,#fff,#def);border-bottom:1px solid #aaa}</style>' + ''.join('<div class="card">%d</div>' % i for i in range(2000)))
    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *_): pass
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(root)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield 'http://127.0.0.1:%d' % server.server_port
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5)

