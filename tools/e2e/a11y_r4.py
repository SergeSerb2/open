"""Bug sweep r4 keyboard rows, through the App's real key path (OEApplication.sendEvent route).

A11Y-03: closing Library with Esc gives keyboard focus back to the page, not the hidden search field.
A11Y-04: Space and Return on a focused Settings navigation button open that section.
"""
import http.server
import threading
import time
from loopback_http import LoopbackHTTPServer


def run(factory, results, wait_until):
    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/dark':
                body = b'<!doctype html><title>Dark fixture</title><body style="background:#121212;color:#eee">Dark page</body>'
            else:
                body = (b'<!doctype html><title>Focus fixture</title><input id="field" autofocus>'
                        b'<script>addEventListener("load",()=>document.getElementById("field").focus())</script>')
            self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *_): pass
    server = LoopbackHTTPServer(Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    page = 'http://127.0.0.1:%d/focus' % server.server_address[1]
    app = factory(urls=(page,), fresh=True)
    try:
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)

        def key(name=None, text=None, mods=(), window=None):
            args = dict(route='app', modifiers=list(mods))
            if name: args['key'] = name
            if text: args['text'] = text
            if window: args['window'] = window
            return app.call('key', **args)

        def browser():
            return next(w for w in app.call('windows') if w['class'] == 'BrowserWindow' and w['visible'])

        # A11Y-03: Library search typed, cleared with Esc, then Library closed with Esc.
        app.call('library-open', section='history')
        wait_until(lambda: app.call('library-state').get('open') or None, timeout=5, step=.1)
        key('f', mods=['cmd'])
        searching = wait_until(lambda: 'TextView' in browser()['firstResponder'] or None, timeout=5, step=.1)
        responder_in_library = browser()['firstResponder']
        key(text='zz')
        key('escape')
        key('escape')
        closed = wait_until(lambda: not app.call('library-state').get('open') or None, timeout=5, step=.1)
        time.sleep(.3)
        responder = browser()['firstResponder']
        focused = app.eval(tab, 'document.hasFocus()')
        key(text='ok')
        typed = wait_until(lambda: app.eval(tab, 'document.getElementById("field").value') == 'ok' or None, timeout=3, step=.1)
        results['a11y_library_close_returns_focus_to_page'] = {
            # The search field may or may not hold focus on Cmd+F; either way the page must get it back.
            'ok': bool(closed) and focused is True and bool(typed),
            'searchFocused': bool(searching), 'firstResponderInLibrary': responder_in_library, 'firstResponderAfterClose': responder,
            'pageHasFocus': focused, 'typedIntoPage': bool(typed)}

        # A11Y-04: keyboard activation of the Settings navigation rail.
        app.call('settings-ui', action='open', section='general')
        settings = app.call('settings-ui')['window']
        rows = {}
        for section, name in (('shortcuts', 'space'), ('profiles', 'return')):
            app.call('settings-ui', action='focus-nav', section=section)
            key(name, window=settings)
            state = wait_until(lambda: (lambda s: s if s['section'] == section else None)(app.call('settings-ui')),
                               timeout=3, step=.1) or app.call('settings-ui')
            rows[name] = {'section': state['section'], 'query': state.get('query', '')}
        key('w', mods=['cmd'], window=settings)
        results['a11y_settings_nav_keyboard_activation'] = {
            'ok': rows['space'] == {'section': 'shortcuts', 'query': ''} and rows['return'] == {'section': 'profiles', 'query': ''},
            'rows': rows}
        # A11Y-05: Library list headings and row actions in the accessibility tree (read in-process).
        app.call('library-open', section='history')
        wait_until(lambda: app.call('library-state').get('open') or None, timeout=5, step=.1)
        number = browser()['number']
        def tree():
            elements = app.call('ax-elements', window=number)
            return elements if any(e['label'].startswith('Focus fixture') for e in elements) else None
        elements = wait_until(tree, timeout=10, step=.3) or app.call('ax-elements', window=number)
        headings = [e['label'] for e in elements if e['role'] == 'AXStaticText' and e['class'] == 'LibraryHeadingView']
        rows = [e for e in elements if e['role'] == 'AXRow']
        visit = next((e for e in rows if e['label'].startswith('Focus fixture')), None)
        results['a11y_library_headings_and_row_actions'] = {
            'ok': 'Today' in headings and visit is not None and bool(visit['actions'])
                  and not any('-' == name for e in rows for name in e['actions']),
            'headings': headings, 'visitActions': visit and visit['actions'],
            'rowActionNames': sorted({n for e in rows for n in e['actions']})}
        app.call('library-close')

        # A11Y-02: the content toolbar takes a dark page's color; its host text must turn light.
        def luminance(c): return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255 if c else None
        app.call('navigate', tab=tab, url=page.replace('/focus', '/dark')); app.call('wait', tab=tab)
        key('d', mods=['cmd', 'shift'])
        def dark_bar():
            st = app.call('window-state')
            bg = next((p['color'] for p in st.get('paneBackgrounds', []) if p['color']), None)
            return st if st['toolbar']['drawn'] and bg and luminance(bg) < .3 else None
        state = wait_until(dark_bar, timeout=8, step=.2) or app.call('window-state')
        bar_color = next((p['color'] for p in state.get('paneBackgrounds', []) if p['color']), None)
        text, glyph = state['toolbar'].get('textColor'), state['toolbar'].get('glyphColor')
        # Back to a light page: the old dark ink returns.
        app.call('navigate', tab=tab, url=page); app.call('wait', tab=tab)
        def light_bar():
            st = app.call('window-state')
            bg = next((p['color'] for p in st.get('paneBackgrounds', []) if p['color']), None)
            return st if st['toolbar']['drawn'] and bg and luminance(bg) > .7 else None
        light = wait_until(light_bar, timeout=8, step=.2) or app.call('window-state')
        light_text, light_glyph = light['toolbar'].get('textColor'), light['toolbar'].get('glyphColor')
        results['a11y_toolbar_text_legible_on_dark_page'] = {
            'ok': bool(state['toolbar']['drawn']) and luminance(bar_color) is not None and luminance(bar_color) < .3
                  and luminance(text) is not None and luminance(text) > .7 and luminance(glyph) is not None and luminance(glyph) > .7
                  and luminance(light_text) is not None and luminance(light_text) < .3 and luminance(light_glyph) is not None and luminance(light_glyph) < .3,
            'barColor': bar_color, 'textColor': text, 'glyphColor': glyph, 'text': state['toolbar'].get('text'),
            'lightTextColor': light_text, 'lightGlyphColor': light_glyph}
        key('d', mods=['cmd', 'shift'])
    finally:
        app.quit()
        server.shutdown(); server.server_close()
