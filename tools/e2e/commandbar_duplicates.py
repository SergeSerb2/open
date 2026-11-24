"""Command bar rows for tabs that share a title (UX round 1 wave 2, W2).

A real profile has the same page open in several Spaces. Those tabs were title-only "Switch to Tab"
rows, so the user could not tell them apart. Rows that share a title now carry "<Space> · <host>",
or "<Space> · <short URL>" when the Space and host match too. Real App, real Cmd+T / Cmd+L and typed
queries; local pages. `commandbar-state` gives the model rows (`drawn`) and the text each row view
really drew (`drawnText`, with any "…").
"""
import http.server
import threading
import time
from loopback_http import LoopbackHTTPServer

# Two same-Space, same-host pages whose URLs differ only after a long shared path.
LONG = '/long/' + 'shared-path-segment-' * 8


class Pages(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        title = ('Unique fixture page' if self.path.startswith('/unique') else
                 'Long fixture page' if self.path.startswith('/long') else 'Duplicate fixture page')
        body = ('<!doctype html><title>%s</title><h1>%s %s</h1>' % (title, title, self.path)).encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)


def run(factory, results, h):
    server = LoopbackHTTPServer(Pages); threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_port
    app = factory(urls=('about:blank',), fresh=True)
    try:
        def open_tab(path):
            tab = app.call('open', url=origin + path)['id']; app.call('wait', tab=tab)
        # Same title, different pages (the command bar folds tabs with the same URL into one row).
        for n, space in enumerate(('Alpha Space', 'Beta Space')):
            app.call('space-create', title=space); open_tab('/duplicate/%d' % n)
        # A second copy in Beta: same Space and host, so only the path can tell it apart.
        open_tab('/duplicate/2'); open_tab('/unique')
        app.call('space-create', title='Gamma Space')
        open_tab(LONG + 'oauth'); open_tab(LONG + 'refresh')
        app.call('open', url='about:blank')

        def query(text, key='t'):
            app.call('key', key=key, modifiers=['cmd'], route='app')
            h.wait_until(lambda: app.call('commandbar-state').get('presented'), timeout=3, step=.05)
            app.call('key', text=text)
            state = h.wait_until(lambda: (lambda s: s if s.get('final') and s.get('text') == text else None)(app.call('commandbar-state')),
                                 timeout=5, step=.05) or {}
            time.sleep(.3)  # one draw pass after the final rows
            state = app.call('commandbar-state') or state
            app.call('key', key='escape', route='app'); time.sleep(.3)
            drawn = {d['id']: d for d in state.get('drawnText') or []}
            return [dict(r, shown=drawn.get(r.get('id'), {})) for r in state.get('drawn') or []], state.get('panelFrame')

        def tabs(rows, title): return [r for r in rows if r.get('title') == title and r.get('id', '').startswith('tab:')]

        rows, _ = query('Duplicate fixture page')
        duplicates = tabs(rows, 'Duplicate fixture page')
        subtitles = [r.get('subtitle', '') for r in duplicates]
        results['commandbar_duplicate_titles_disambiguated'] = dict(
            ok=len(duplicates) == 3 and all(subtitles) and len(set(subtitles)) == 3
               and all(s.startswith(('Alpha Space', 'Beta Space')) for s in subtitles),
            duplicates=subtitles, drawn=[(r.get('id', '')[:12], r.get('title'), r.get('subtitle')) for r in rows])

        # A unique tab whose title equals the typed query: the typed (search) row has the same title,
        # but it is not another tab, so the tab row stays title-only.
        rows, _ = query('Unique fixture page')
        unique = tabs(rows, 'Unique fixture page')
        results['commandbar_unique_title_no_subtitle'] = dict(
            ok=len(unique) == 1 and unique[0].get('subtitle', '') == '' and any(not r['id'].startswith('tab:') and r.get('title') == 'Unique fixture page' for r in rows),
            unique=[r.get('subtitle') for r in unique], drawn=[(r.get('id', '')[:12], r.get('title'), r.get('subtitle')) for r in rows])

        # Same Space, same host, long shared path: the drawn subtitles still differ (cut in the middle,
        # so the Space in front and the path's end both show).
        rows, card = query('Long fixture page')
        long_rows = tabs(rows, 'Long fixture page')
        shown = [r['shown'].get('subtitle', '') for r in long_rows]
        results['commandbar_duplicate_long_path_distinct'] = dict(
            ok=len(long_rows) == 2 and all(shown) and len(set(shown)) == 2 and any('…' in s for s in shown)
               and all(s.startswith('— Gamma Space') for s in shown)
               and sorted(s.endswith('oauth') or s.endswith('refresh') for s in shown) == [True, True],
            shown=shown, model=[r.get('subtitle') for r in long_rows], card=card)

        # A narrow card (Cmd+L, the inline editor over the sidebar): a title gives up room only when
        # its subtitle then really draws.
        rows, card = query('Duplicate fixture page', key='l')
        narrow = tabs(rows, 'Duplicate fixture page')
        broken = [r['shown'] for r in narrow if r['shown'].get('titleGaveRoom') and not r['shown'].get('subtitle')]
        results['commandbar_duplicate_narrow_card'] = dict(
            ok=len(narrow) >= 2 and all(r['shown'].get('title') for r in narrow) and not broken,
            card=card, shown=[r['shown'] for r in narrow], broken=broken)
    finally:
        app.quit(); server.shutdown()
