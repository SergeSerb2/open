"""Bug sweep r6: a dialog reset names its engine browser, and the page's own reset still matches.

A page alert is held pending and then answered. CEF resets dialog state after every closed dialog;
that reset must name the same engine browser the dialog carries (a mismatch would leave a page's
own pending dialogs behind on navigation and close).
"""
import http.server
import threading
from loopback_http import LoopbackHTTPServer


def run(factory, results, wait_until):
    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ('<!doctype html><title>R6 %s</title><h1>%s</h1>' % (self.path, self.path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *_): pass
    server = LoopbackHTTPServer(Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]
    app = factory(urls=(base + '/one',), fresh=True)
    try:
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        app.call('policy', dialogs='hold')
        app.call('events')
        app.eval(tab, "setTimeout(() => alert('R6 reset'), 0); true")
        pending = wait_until(lambda: (lambda s: s if s.get('pending') else None)(app.call('dialog-state')), timeout=5, step=.05) or {}
        # CEF resets dialog state after every closed dialog, naming the browser: answering the page's
        # own alert must produce a reset for the same browser the dialog carries.
        app.call('dialog', accept=True)
        cleared = wait_until(lambda: (lambda s: s if not s.get('pending') else None)(app.call('dialog-state')), timeout=5, step=.05)
        seen = wait_until(lambda: [e for e in app.call('events') if e.get('type') == 'dialogResetSeen'] or None, timeout=5, step=.1) or []
        results['dialog_page_reset_names_its_browser'] = {
            'ok': pending.get('message') == 'R6 reset' and isinstance(pending.get('browser'), int) and pending['browser'] > 0
                  and cleared is not None and any(e.get('browser') == pending['browser'] for e in seen),
            'dialogBrowser': pending.get('browser'), 'cleared': cleared is not None, 'resets': [e.get('browser') for e in seen]}
    finally:
        try: app.call('policy', dialogs='')
        except Exception: pass
        app.quit()
        server.shutdown(); server.server_close()
