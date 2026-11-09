"""Shared Section 12 fixtures. The caller owns the temp directory and server lifetime."""
import http.server
import pathlib
import threading
from contextlib import contextmanager


@contextmanager
def fixture_server(tmp):
    folder = pathlib.Path(tmp) / "sitecontrol-fixtures"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "boost.html").write_text("""<!doctype html><title>Boost fixture</title>
<style>body{background:#fff;color:#222;margin:16px}header{width:600px;height:300px;background:#2E7DF6}article{height:32px}</style>
<header></header><h1>Boost fixture heading</h1><article>First</article><article>Second</article><article>Third</article><div id="promo-banner">Promo</div>
<script>document.addEventListener('DOMContentLoaded',()=>{window.boostAtDOMContentLoaded=getComputedStyle(document.documentElement).filter;window.styleAtDOMContentLoaded=!!document.getElementById('open-boosts-style')})</script>""", encoding="utf-8")
    (folder / "boost-first.html").write_text("""<!doctype html><html><head><script>
window.boostAtFirstScript={filter:getComputedStyle(document.documentElement).filter,style:!!document.getElementById('open-boosts-style'),js:window.boostRestoredFirstDocument??null};
window.scriptUpdateAtFirstScript={version:window.boostScriptUpdateVersion??null,runs:window.boostScriptUpdateRuns??0};
</script><title>Restored Boost fixture</title></head><body><h1>Restored Boost</h1></body></html>""", encoding="utf-8")
    # EasyList's shipped ||demand.supply^$script rule blocks this request.
    # The Site Control caller maps that host to this server before launch.
    (folder / "ads.html").write_text("""<!doctype html><title>Site fixture</title><h1>Site controls</h1><div id="promo-banner">Promo</div><script>document.cookie='f=1';window.clicks=0;document.addEventListener('click',()=>window.clicks++)</script><script src="http://demand.supply/ad.js"></script>""", encoding="utf-8")
    (folder / "ad.js").write_text("window.fixtureAdLoaded=true", encoding="utf-8")
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(folder), **kw)
        def log_message(self, *a):
            pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:%d" % server.server_address[1]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
