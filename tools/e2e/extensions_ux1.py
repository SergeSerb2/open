"""UX round 1 wave 3 (UXC): extensions UI rows in the real App.

Rows (each fails on the parent code and passes with the fix):
- ext_ux1_prompt_body_ends_on_whole_line (X1): an install prompt with 12 permission lines scrolls; its visible
  part ends on a whole line under a fade, and the fade goes away at the end of the list.
- ext_ux1_prompt_no_signed_in_devices (X4): the history permission line does not promise "all your signed-in
  devices" (Open has no accounts or sync), while the engine's own line still does.
- ext_ux1_menus_add_then_manage (X5): the overflow menu ends "Add Extension…, Manage Extensions…", as the menu bar.
- ext_ux1_extension_page_names_extension (X3): an extension's own page shows the extension's name in the URL
  field and its icon in the sidebar row, not its 32-letter ID and a letter.
- ext_ux1_incognito_extensions_note (X6): in an Incognito window with no extension allowed, Site Controls says
  so instead of showing a lone Add tile.

Loopback only: one HTTP server on 127.0.0.1; every other host fails to resolve.
"""
import os
import runpy
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

from loopback_http import LoopbackHTTPServer

PROBE_NAME = 'Action Probe'
MANY = ['tabs', 'history', 'bookmarks', 'downloads', 'clipboardRead', 'management', 'nativeMessaging',
        'debugger', 'geolocation', 'notifications', 'privacy', 'contentSettings']


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        body = b'<!doctype html><title>Fixture page</title><h1>Fixture page</h1>'
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)


def body_ink(app, prompt, body, tmp, h):
    """Text contrast (max − min luma) in the top and bottom 12 pt bands of the prompt's visible body."""
    frame, sheet = body.get('frameInWindow'), prompt.get('sheet')
    if not frame or not sheet: return {}
    path = str(Path(tmp, 'ux1-prompt-%d.png' % int(time.time() * 1000)))
    if os.environ.get('OPEN_EXTENSIONS_UX1_KEEP'): path = os.path.join(os.environ['OPEN_EXTENSIONS_UX1_KEEP'], os.path.basename(path))
    app.call('snapshot', path=path, window=sheet)
    width, height, pixel = h.read_image(path)
    scale = width / body['sheetWidth']
    x, y, w, hh = frame
    def contrast(y0, y1):
        values = [h.luma(pixel(px, py)) for px in range(int((x + 16) * scale), int((x + w - 24) * scale))
                  for py in range(int(y0 * scale), int(y1 * scale))]
        return max(values) - min(values)
    return {'top': round(contrast(y + 2, y + 14), 1), 'bottom': round(contrast(y + hh - 12, y + hh - 1), 1), 'snapshot': path}


def run(factory, results, tmp, root, wait_until, h):
    server = LoopbackHTTPServer(_Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]

    def row(name, ok, **detail):
        print(name, 'PASS' if ok else 'FAIL', flush=True)
        results[name] = dict(detail, ok=bool(ok))

    pack_probe = runpy.run_path(str(Path(root) / 'tools/e2e/extensions_p3.py'))['pack_probe']
    app = factory(urls=(base + '/start',), fresh=True)
    try:
        app.call('window-frame', frame=[80, 60, 1200, 800])
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        def actions():
            seen = set()
            return [a for a in app.call('extensions')['actions'] if not (a['id'] in seen or seen.add(a['id']))]
        wait_until(lambda: len(actions()) >= 4, timeout=30)
        probe = next(a['id'] for a in actions() if a['name'] == PROBE_NAME)
        start = next(t['id'] for t in app.call('tabs') if t['url'].startswith(base))
        app.call('select', tab=start)

        def pending():
            return wait_until(lambda: (lambda p: p if p.get('pending') and p.get('sheetVisible') else None)(app.call('ext-prompt')), timeout=20)

        # X1 and X4: one install prompt with a long permission list, including history.
        crx = pack_probe(root, tmp, prefix='ux1-many', name='Everything Helper', edit=lambda m: m.update(permissions=MANY, host_permissions=['<all_urls>']))
        app.call('ext-manage', extension='local', action='install-crx', path=crx)
        prompt = pending() or {}
        time.sleep(.3)
        body = (app.call('ext-prompt') or {}).get('body') or {}
        ink = body_ink(app, prompt, body, tmp, h)
        end = app.call('ext-prompt', scrollBody='end') if prompt else {}
        time.sleep(.3)
        end_ink = body_ink(app, prompt, end, tmp, h)
        # Text near the bottom edge is faded at rest (more follows) and as strong as the top line once the
        # list is scrolled to its end. Contrast works in light and dark.
        row('ext_ux1_prompt_body_ends_on_whole_line', body.get('overflows') is True and body.get('lineCutAtBottom') is False
            and body.get('fadeMask') is True and end.get('lineCutAtBottom') is False and end.get('fadeMask') is False
            and ink.get('bottom', 255) <= 0.75 * ink.get('top', 0) and end_ink.get('bottom', 0) >= 0.8 * end_ink.get('top', 255),
            atRest=body, atEnd=end, ink=ink, endInk=end_ink)
        shown = prompt.get('shownPermissionLines') or []
        engine = prompt.get('permissionLines') or []
        row('ext_ux1_prompt_no_signed_in_devices', any('signed-in devices' in line for line in engine)
            and 'Read and change your browsing history' in shown and not any('signed-in devices' in line for line in shown),
            shown=shown, engine=engine)
        if prompt: app.call('ext-prompt', answer='cancel')
        wait_until(lambda: not app.call('ext-prompt').get('pending'), timeout=5)

        # X5: every action pinned at 228 pt overflows the URL field strip.
        for a in actions(): app.call('ext-pin', extension=a['id'], pinned=True)
        app.call('updater-banner-width', width=228.0)
        app.call('select', tab=start)
        app.call('ext-hover', inside=False); app.call('ext-hover', inside=True); time.sleep(.2)
        strip = app.call('ext-strip')
        overflow = app.call('ext-click', extension='more').get('menu', []) if strip.get('more') else []
        bar = app.call('ext-ui-menu', kind='bar')
        tail = [i['title'] for i in overflow if not i['separator']][-2:]
        bar_tail = [i['title'] for i in bar if not i['separator']][-2:]
        row('ext_ux1_menus_add_then_manage', strip.get('more') is True and tail == ['Add Extension…', 'Manage Extensions…'] == bar_tail,
            overflowTail=tail, barTail=bar_tail, strip=strip)

        # X3: the probe's own page in a tab.
        page = app.call('open', url='chrome-extension://%s/popup.html' % probe)['id']
        app.call('select', tab=page)
        wait_until(lambda: next((t for t in app.call('tabs') if t['id'] == page and not t['loading']), None), timeout=10)
        time.sleep(.5)
        text = app.call('window-state').get('urlFieldText')
        source = wait_until(lambda: (lambda t: t if t.get('rowFaviconSource') == 'provider' else None)(
            next(t for t in app.call('tabs') if t['id'] == page)), timeout=3) or next(t for t in app.call('tabs') if t['id'] == page)
        row('ext_ux1_extension_page_names_extension', text == PROBE_NAME and source.get('rowFaviconSource') == 'provider',
            urlFieldText=text, rowFaviconSource=source.get('rowFaviconSource'), extension=probe)
        app.call('close', tab=page)

        # X6: Incognito window, no extension allowed there.
        app.call('menu-perform', id='new-incognito-window')
        wait_until(lambda: any(w['private'] for w in app.call('incognito-state')['windows']), timeout=10)
        time.sleep(.5)
        if app.call('commandbar-state').get('presented'): app.call('key', key='escape', route='app')
        app.call('key', key='l', modifiers=['command'], route='app')
        app.call('key', text=base + '/private\r', route='app')
        wait_until(lambda: app.call('window-state').get('urlFieldText') == '127.0.0.1', timeout=10)
        time.sleep(.5)
        app.call('site-controls', action='open')
        scc = wait_until(lambda: (lambda s: s if s.get('presented') else None)(app.call('site-controls', action='state')), timeout=5) or {}
        row('ext_ux1_incognito_extensions_note', scc.get('isIncognito') is True
            and scc.get('extensionsNote') == 'Extensions are off in Incognito.'
            and not any(i.get('id') == 'extension.add' for i in scc.get('extensionItems', [])),
            note=scc.get('extensionsNote'), items=scc.get('extensionItems'), incognito=scc.get('isIncognito'))
        app.call('site-controls', action='close')
        app.call('key', key='w', modifiers=['command', 'shift'], route='app')
    finally:
        app.quit()
        server.shutdown(); server.server_close()
