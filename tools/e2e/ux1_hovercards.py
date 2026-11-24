"""UX round 1 wave 2 (lane UXD): hover-card layout rows through the real App's automation socket. Loopback pages
only (every other host NOTFOUND); synthetic profile.

Runs at the end of the live-data suite; `OPEN_UX1_HOVER_ONLY=1` runs these rows alone:
  /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only live-data --config Debug
"""
import copy
import http.server
import json
import os
import uuid
import threading
import time
import traceback
from loopback_http import LoopbackHTTPServer


def serve():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ("<!doctype html><title>Card %s</title><body style='margin:0;font:18px -apple-system'><h1>Card page</h1>"
                    % self.path).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def session(h, tmp, origin):
    """A saved session whose pinned tab has never loaded (what every pinned tab is right after launch)."""
    data = json.load(open(os.path.join(h['ROOT'], 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json')))
    now = time.time()
    def tab(title, url):
        return {'tab': {'_0': {'createdAt': now, 'id': str(uuid.uuid4()).upper(), 'isMuted': False, 'isUnread': False,
                               'lastActiveAt': now, 'title': title, 'url': url}}}
    data['profiles'][0]['favorites'] = []
    space = copy.deepcopy(data['spaces'][0]); space['id'] = str(uuid.uuid4()).upper()
    space['today'] = [tab('Start', origin + '/start')]; space['pinned'] = [tab('Pinned card', origin + '/pinned')]
    data['spaces'] = [space]
    w = data['windows'][0]
    w.update(focusedSpaceID=space['id'], sidebarWidth=228, sidebarMode='anchored', frameX=40, frameY=40, frameWidth=1280,
             frameHeight=800, selectedNodeBySpace={space['id']: space['today'][0]['tab']['_0']['id']})
    data['windows'] = [w]
    path = os.path.join(tmp, 'ux1-hovercards-browser.json')
    with open(path, 'w') as f: json.dump(data, f)
    return path, space['pinned'][0]['tab']['_0']['id']


def run(factory, results, tmp, h):
    wait = h['wait_until']
    server = serve()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    snapshot, pinned = session(h, tmp, origin)
    app = factory(urls=(), snapshot=snapshot,
                  extra_args=['--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE *.localhost, EXCLUDE 127.0.0.1'])

    def gate(name, fn):
        try:
            results[name] = fn()
        except h['FocusInterruption']:
            raise
        except Exception as error:
            results[name] = {'ok': False, 'error': str(error), 'trace': traceback.format_exc()[-900:]}
        print(name + (' PASS' if results[name].get('ok') else ' FAIL'), flush=True)
        if not results[name].get('ok'): print(json.dumps(results[name], default=str)[:3000], flush=True)

    try:
        app.call('window-frame', frame=[40, 40, 1280, 800])
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        for k in ('open.general.previewsEnabled', 'open.general.previewsPages', 'open.general.previewsFolders'):
            app.call('defaults', key=k, value=True)
        start = next(t['id'] for t in app.call('tabs') if t['url'].endswith('/start')); app.call('wait', tab=start)

        # H1: the first hover of a pinned tab with no live page shows the page laid out at the card's size. Before,
        # CefTabStrip::CreateTab resized the new background tab like the active tab (the content area, 1042 × 780)
        # after OpenEngine had fitted it to the card, so it was squeezed into the 420 × 560 card for the whole hover.
        def first_hover_page_size():
            app.call('select', tab=start); app.call('focus', tab=start); time.sleep(.5)
            unloaded = not any(n.get('loaded') for n in app.call('sidebar-tree').get('pinned', []) if n.get('id') == pinned)
            app.call('hover', leave=True, ms=300)
            shown = app.call('hover', node=pinned, ms=900)
            inner = app.eval(pinned, '[innerWidth, innerHeight]')
            card = shown.get('card', [])
            app.call('hover', leave=True, ms=300)
            ok = (bool(unloaded) and shown.get('kind') == 'page' and shown.get('makeHostCount', 0) >= 1 and len(card) == 4
                  and abs(inner[0] - card[2]) <= 1 and abs(inner[1] - card[3]) <= 1)
            return {'ok': ok, 'unloaded': bool(unloaded), 'card': card, 'inner': inner, 'hover': shown}
        gate('UX1W2_page_card_first_hover_layout', first_hover_page_size)

        # H2: an empty folder card is only its "No tabs" text: no search band, no separator, text centred.
        def empty_folder_card():
            folder = app.call('folder-create', title='Empty folder')
            node = next((n for n in app.call('sidebar-tree').get('pinned', []) if n.get('id') == folder), {})
            if node.get('expanded'): app.call('folder-toggle', folder=folder)
            app.call('hover', leave=True, ms=300)
            shown = app.call('hover', node=folder, ms=900)
            fs = shown.get('folderSearch', {})
            label, height = fs.get('emptyLabel', []), fs.get('cardHeight', 0)
            app.call('hover', leave=True, ms=300)
            centred = len(label) == 4 and label[3] > 0 and abs((label[1] + label[3] / 2) - height / 2) <= 2
            return {'ok': shown.get('kind') == 'folder' and fs.get('searchHidden') is True and fs.get('separatorShown') is False
                    and 0 < height <= 72 and centred, 'folderSearch': fs, 'card': shown.get('card')}
        gate('UX1W2_empty_folder_card_layout', empty_folder_card)
    finally:
        app.quit(); server.shutdown(); server.server_close()
