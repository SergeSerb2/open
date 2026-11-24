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

        def hover_until(node, kind):
            # The card shows after the 0.5 s hover delay; under load it can land after the hover's own read.
            shown = app.call('hover', node=node, ms=600)
            if shown.get('kind') != kind:
                shown = wait(lambda: (lambda st: st if st.get('kind') == kind else None)(app.call('preview-state')), timeout=3, step=.05) or shown
            return shown

        def preview_until(test):
            return wait(lambda: (lambda st: st if test(st) else None)(app.call('preview-state')), timeout=3, step=.05)

        # H1: the first hover of a pinned tab with no live page shows the page laid out at the card's size. Before,
        # CefTabStrip::CreateTab resized the new background tab like the active tab (the content area, 1042 × 780)
        # after OpenEngine had fitted it to the card, so it was squeezed into the 420 × 560 card for the whole hover.
        def first_hover_page_size():
            app.call('select', tab=start); app.call('focus', tab=start); time.sleep(.5)
            unloaded = not any(n.get('loaded') for n in app.call('sidebar-tree').get('pinned', []) if n.get('id') == pinned)
            app.call('hover', leave=True, ms=300)
            shown = hover_until(pinned, 'page')
            inner, still = None, {}
            if shown.get('kind') == 'page':
                # Read the page's viewport as soon as it is live (the engine refuses an eval before), while the
                # card is still open: the size the user sees first.
                def viewport():
                    try: return app.call('eval', tab=pinned, js='[innerWidth, innerHeight]')
                    except RuntimeError: return None
                inner = wait(viewport, timeout=10, step=.05)
                still = app.call('preview-state')
            card = shown.get('card', [])
            app.call('hover', leave=True, ms=300)
            ok = (bool(unloaded) and shown.get('kind') == 'page' and shown.get('makeHostCount', 0) >= 1 and len(card) == 4
                  and still.get('kind') == 'page' and still.get('card') == card and isinstance(inner, list)
                  and abs(inner[0] - card[2]) <= 1 and abs(inner[1] - card[3]) <= 1)
            return {'ok': ok, 'unloaded': bool(unloaded), 'card': card, 'inner': inner, 'hover': shown, 'after': still}
        gate('UX1W2_page_card_first_hover_layout', first_hover_page_size)

        # H2: an empty folder card is only its "No tabs" text: no search band, no separator, text centred.
        def empty_folder_card():
            folder = app.call('folder-create', title='Empty folder')
            node = next((n for n in app.call('sidebar-tree').get('pinned', []) if n.get('id') == folder), {})
            if node.get('expanded'): app.call('folder-toggle', folder=folder)
            app.call('hover', leave=True, ms=300)
            shown = hover_until(folder, 'folder')
            fs = shown.get('folderSearch', {})
            label, height = fs.get('emptyLabel', []), fs.get('cardHeight', 0)
            app.call('hover', leave=True, ms=300)
            centred = len(label) == 4 and label[3] > 0 and abs((label[1] + label[3] / 2) - height / 2) <= 2
            return {'ok': shown.get('kind') == 'folder' and fs.get('searchHidden') is True and fs.get('separatorShown') is False
                    and 0 < height <= 72 and centred and fs.get('emptyText') == 'No tabs', 'folderSearch': fs, 'card': shown.get('card'),
                    'folder': folder}
        gate('UX1W2_empty_folder_card_layout', empty_folder_card)

        # Review r1 nit: a tab joins or leaves the folder while its card is open. The change comes from a second
        # window on the same model (this window's own sidebar actions close the card by design). The card grows to
        # one row with its search band, then goes back to the 64 pt "No tabs" card, without closing.
        def live_folder_change():
            folder = results['UX1W2_empty_folder_card_layout'].get('folder')
            if not folder: return {'ok': False, 'error': 'no empty folder from the row above'}
            space = next(s['id'] for s in app.call('spaces') if s['focused'])
            tab = h['new_tab'](app, origin + '/live')
            w1 = app.call('window-state')['id']
            app.call('menu-perform', id='new-window')
            w2 = wait(lambda: next((w['id'] for w in app.call('shell-windows') if w['id'] != w1), None), timeout=5, step=.1)
            if not w2: return {'ok': False, 'error': 'no second window'}
            try:
                app.call('window-focus', id=w1, activate=True)
                app.call('select', tab=start); app.call('focus', tab=start); time.sleep(.3)
                app.call('hover', leave=True, ms=300)
                opened = hover_until(folder, 'folder')
                app.call('sidebar-drop', window=w2, nodes=[tab], parent={'kind': 'folder', 'id': folder}, index=0)
                # The card frame and its folder view (laid out on the next pass) must both reach the new height.
                grown = preview_until(lambda st: st.get('kind') == 'folder' and st['folderSearch'].get('rows') == 1
                                      and st['card'][3] == st['folderSearch'].get('cardHeight') == 48 + 45 + 8) or app.call('preview-state')
                app.call('sidebar-drop', window=w2, nodes=[tab], parent={'kind': 'today', 'id': space}, index=0)
                shrunk = preview_until(lambda st: st.get('kind') == 'folder' and st['folderSearch'].get('rows') == 0
                                       and st['card'][3] == st['folderSearch'].get('cardHeight', 0) <= 72) or app.call('preview-state')
                app.call('hover', leave=True, ms=300)
            finally:
                app.call('window-focus', id=w2, activate=True); app.call('window-close')
                app.call('window-focus', id=w1, activate=True)
            g, k = grown.get('folderSearch', {}), shrunk.get('folderSearch', {})
            ok = (opened.get('kind') == 'folder' and g.get('rows') == 1 and g.get('searchHidden') is False and g.get('cardHeight') == 101
                  and grown.get('card', [0, 0, 0, 0])[3] == 101 and k.get('rows') == 0 and k.get('searchHidden') is True
                  and k.get('emptyText') == 'No tabs' and 0 < k.get('cardHeight', 0) <= 72 and shrunk.get('card', [0, 0, 0, 99])[3] <= 72
                  and grown.get('shows') == shrunk.get('shows') == opened.get('shows'))
            return {'ok': ok, 'opened': opened.get('card'), 'grown': {'card': grown.get('card'), 'fs': g},
                    'shrunk': {'card': shrunk.get('card'), 'fs': k}, 'shows': [opened.get('shows'), grown.get('shows'), shrunk.get('shows')]}
        gate('UX1W2_folder_card_live_change', live_folder_change)
    finally:
        app.quit(); server.shutdown(); server.server_close()
