"""Bug sweep r6 appearance and keyboard rows, read in-process (never System Events).

A11Y-09: a live Light/Dark switch (Open's own NSApp.appearance, the same KVO path a system
switch takes) recolors an open Note (View ▸ Appearance Automatic) and an open New Space form.
A11Y-11: Tab from the Library rail reaches the Filter drawer's controls and the Boosts controls.
"""
import http.server
import threading
import time
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
        first = app.call('tabs')[0]['id']
        app.call('wait', tab=first)

        # A11Y-09: open Note, then the New Space form, across a light → dark switch.
        app.call('appearance', name='light')
        app.call('note', action='create')
        before = wait_until(lambda: (lambda s: s if s.get('hasHost') and s.get('shown') else None)(app.call('note', action='state')),
                            timeout=5, step=.1) or app.call('note', action='state')
        app.call('appearance', name='dark')
        after = wait_until(lambda: (lambda s: s if s.get('dark') else None)(app.call('note', action='state')), timeout=3, step=.1) \
            or app.call('note', action='state')
        results['a11y_note_follows_system_appearance'] = {
            'ok': before.get('isNote') is True and before.get('dark') is False and after.get('dark') is True,
            'before': {'dark': before.get('dark'), 'background': before.get('background')},
            'after': {'dark': after.get('dark'), 'background': after.get('background')}}

        app.call('appearance', name='light')
        app.call('select', tab=first)
        app.call('editor-open', kind='create')
        light = wait_until(lambda: (lambda s: s if s.get('open') else None)(app.call('creation-state')), timeout=5, step=.1) or {}
        app.call('appearance', name='dark')
        time.sleep(.3)
        dark = app.call('creation-state')
        results['a11y_space_creation_follows_system_appearance'] = {
            'ok': light.get('systemAppearance') == 'light' and 'Dark' not in light.get('formAppearance', '')
                  and dark.get('systemAppearance') == 'dark' and 'Dark' in dark.get('formAppearance', ''),
            'light': {k: light.get(k) for k in ('systemAppearance', 'formAppearance')},
            'dark': {k: dark.get(k) for k in ('systemAppearance', 'formAppearance')}}
        app.call('editor-close')
        wait_until(lambda: not app.call('creation-state').get('open') or None, timeout=5, step=.1)
        app.call('appearance', name='system')

        # A11Y-11: Tab order from the rail, with the History Filter drawer open, then on Boosts.
        def tab_walk(count=24):
            app.call('library', action='focus-rail')
            seen = []
            for _ in range(count):
                app.call('key', key='tab', route='app')
                label = app.call('library').get('firstResponderLabel', '')
                seen.append(label)
            return seen
        app.call('library', action='open', section='history')
        wait_until(lambda: app.call('library').get('open') or None, timeout=5, step=.1)
        app.call('library', action='filter', open=True)
        chips = [c.get('title') or c.get('label') for c in wait_until(lambda: app.call('library')['header'].get('chips') or None, timeout=5, step=.1) or []]
        history = tab_walk()
        results['a11y_library_tab_reaches_filter_drawer'] = {
            'ok': 'Done' in history and any(c in history for c in chips if c),
            'chips': chips, 'tabOrder': history}
        app.call('library', action='filter', open=False)
        app.call('library', action='select', section='boosts')
        wait_until(lambda: app.call('library').get('section') == 'boosts' or None, timeout=5, step=.1)
        boosts = tab_walk()
        reached = sorted(set(boosts) & {'boosts.layout.list', 'boosts.layout.gallery', 'boosts.profile', 'Turn On'})
        results['a11y_library_tab_reaches_boosts_controls'] = {'ok': bool(reached), 'reached': reached, 'tabOrder': boosts}
        app.call('library', action='close')
    finally:
        try: app.call('appearance', name='system')
        except Exception: pass
        app.quit()
        server.shutdown(); server.server_close()
