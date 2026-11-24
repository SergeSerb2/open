"""Command bar rows for tabs that share a title (UX round 1 wave 2, W2).

A real profile has the same page open in several Spaces. Those tabs were title-only "Switch to Tab"
rows, so the user could not tell them apart. Rows that share a title now carry "<Space> · <host>".
Real App, real Cmd+T and typed query; local pages; reads the drawn rows from `commandbar-state`.
"""
import http.server
import threading
import time
from loopback_http import LoopbackHTTPServer


class Pages(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        title = 'Unique fixture page' if self.path.startswith('/unique') else 'Duplicate fixture page'
        body = ('<!doctype html><title>%s</title><h1>%s %s</h1>' % (title, title, self.path)).encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)


def run(factory, results, h):
    server = LoopbackHTTPServer(Pages); threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_port
    app = factory(urls=('about:blank',), fresh=True)
    try:
        # Same title, different pages (the command bar folds tabs with the same URL into one row).
        for n, space in enumerate(('Alpha Space', 'Beta Space')):
            app.call('space-create', title=space)
            tab = app.call('open', url='%s/duplicate/%d' % (origin, n))['id']; app.call('wait', tab=tab)
        # A second copy in Beta: same Space and host, so only the path can tell it apart.
        tab = app.call('open', url='%s/duplicate/2' % origin)['id']; app.call('wait', tab=tab)
        tab = app.call('open', url=origin + '/unique')['id']; app.call('wait', tab=tab)
        app.call('open', url='about:blank')
        def query(text):
            app.call('key', key='t', modifiers=['cmd'], route='app')
            h.wait_until(lambda: app.call('commandbar-state').get('presented'), timeout=3, step=.05)
            app.call('key', text=text)
            state = h.wait_until(lambda: (lambda s: s if s.get('final') and s.get('text') == text else None)(app.call('commandbar-state')),
                                 timeout=5, step=.05) or {}
            app.call('key', key='escape', route='app'); time.sleep(.3)
            return state.get('drawn') or []
        drawn = query('fixture page')
        duplicates = [r for r in drawn if r.get('title') == 'Duplicate fixture page' and r.get('id', '').startswith('tab:')]
        unique = [r for r in drawn if r.get('title') == 'Unique fixture page' and r.get('id', '').startswith('tab:')]
        subtitles = [r.get('subtitle', '') for r in duplicates]
        results['commandbar_duplicate_titles_disambiguated'] = dict(
            ok=len(duplicates) == 3 and all(subtitles) and len(set(subtitles)) == 3
               and all(s.startswith(('Alpha Space', 'Beta Space')) for s in subtitles)
               and len(unique) == 1 and unique[0].get('subtitle', '') == '',
            duplicates=subtitles, unique=[r.get('subtitle') for r in unique],
            drawn=[(r.get('id', '')[:12], r.get('title'), r.get('subtitle')) for r in drawn])
    finally:
        app.quit(); server.shutdown()
