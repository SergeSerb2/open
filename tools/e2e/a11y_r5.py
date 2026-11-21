"""Bug sweep r5 VoiceOver rows, read in-process (never System Events).

A11Y-07: the "+" popover's drawn rows are menu item elements (title, enabled, highlighted).
A11Y-06: the sidebar URL field's value is the current host.
A11Y-14: each Ctrl+Tab step is announced with the selected tab's title.
"""
import http.server
import threading
from loopback_http import LoopbackHTTPServer


def run(factory, results, wait_until):
    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ('<!doctype html><title>R5 %s</title><h1>%s</h1>' % (self.path, self.path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *_): pass
    server = LoopbackHTTPServer(Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]
    app = factory(urls=(base + '/one',), fresh=True)
    try:
        first = app.call('tabs')[0]['id']
        app.call('wait', tab=first)

        # A11Y-07
        app.call('plus-popover', op='toggle')
        state = wait_until(lambda: (lambda s: s if s.get('shown') else None)(app.call('plus-popover')), timeout=5, step=.1) or {}
        rows, ax = state.get('rows', []), state.get('axRows')
        results['a11y_plus_popover_rows_are_menu_items'] = {
            'ok': bool(rows) and ax is not None and [r['label'] for r in ax] == [r['title'] for r in rows]
                  and all(r['role'] == 'AXMenuItem' for r in ax) and [r['enabled'] for r in ax] == [r['enabled'] for r in rows]
                  and [r['label'] for r in ax if r['selected']] == [state.get('highlighted')],
            'rows': [r['title'] for r in rows], 'axRows': ax, 'highlighted': state.get('highlighted')}
        app.call('plus-popover', op='key', code=53)

        # A11Y-06
        window = next(w for w in app.call('windows') if w['class'] == 'BrowserWindow' and w['visible'])['number']
        def field():
            return next((e for e in app.call('ax-elements', window=window) if e['label'] == 'Search or Enter URL'), None)
        url = wait_until(lambda: (lambda e: e if e and e.get('value') else None)(field()), timeout=5, step=.2) or field() or {}
        results['a11y_url_field_value_is_host'] = {'ok': url.get('value') == '127.0.0.1', 'element': url}

        # A11Y-14
        second = app.call('open', url=base + '/two')['id']
        app.call('wait', tab=second)
        app.call('key', key='tab', modifiers=['ctrl'], route='app')
        switcher = wait_until(lambda: (lambda s: s if s.get('active') else None)(app.call('tab-switcher-state')), timeout=5, step=.05) \
            or app.call('tab-switcher-state')
        results['a11y_tab_switcher_announces_selection'] = {
            'ok': bool(switcher.get('active')) and switcher.get('announcement') == 'R5 /one',
            'announcement': switcher.get('announcement'), 'selected': switcher.get('selected')}
        app.call('key', key='escape', route='app')
    finally:
        app.quit()
        server.shutdown(); server.server_close()
