"""UX round 1 (lane UXD): layout rows for the command bar, Little Open, find, toasts, hover cards and the link
status bubble, through the real App's automation socket. Loopback pages only; nothing leaves the machine.

Runs at the end of the page-chrome suite; `OPEN_UX1_ONLY=1` runs these rows alone:
  /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only page-chrome --config Debug
Frames: automation window-base frames (bottom-left origin) unless a row says otherwise.
"""
import http.server
import json
import threading
import time
import traceback
from loopback_http import LoopbackHTTPServer

LONG_LINK = '/target/a/long/path/for/the/status/bubble?with=query&and=more'
TEXT = ('<p>' + ' '.join(['The quasar beyond the nebula glows.'] * 6) + '</p>') * 4


def serve():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split('?')[0]
            if path == '/link':
                # The whole page is one link, so any pointer position in the page hovers it.
                body = ("<!doctype html><title>Link page</title><body style='margin:0'>"
                        "<a id=l href='%s' style='display:block;width:100vw;height:100vh;background:#eef'>link</a>" % LONG_LINK)
            else:
                body = "<!doctype html><title>Find page</title><body style='font:16px -apple-system;margin:40px'>%s" % TEXT
            data = body.encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data)
        def log_message(self, *args): pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def inside(inner, outer, slack=0.5):
    return (len(inner) == 4 and len(outer) == 4 and inner[0] >= outer[0] - slack and inner[1] >= outer[1] - slack
            and inner[0] + inner[2] <= outer[0] + outer[2] + slack and inner[1] + inner[3] <= outer[1] + outer[3] + slack)


def run(factory, results, tmp, h):
    wait = h['wait_until']
    server = serve()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    app = factory(urls=(origin + '/find',), fresh=True)

    def gate(name, fn):
        try:
            results[name] = fn()
        except h['FocusInterruption']:
            raise
        except Exception as error:
            results[name] = {'ok': False, 'error': str(error), 'trace': traceback.format_exc()[-900:]}
        print(name + (' PASS' if results[name].get('ok') else ' FAIL'), flush=True)
        if not results[name].get('ok'): print(json.dumps(results[name], default=str)[:4000], flush=True)

    def key(k=None, modifiers=(), text=None, **kw):
        return app.call('key', route='app', **({'text': text} if text is not None else {'key': k, 'modifiers': list(modifiers)}), **kw)

    try:
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        state = app.call('window-state')
        app.call('window-focus', id=state['id'], activate=True)
        app.call('window-frame', frame=[40, 40, 1280, 800])

        def pane(st):
            return next((p for p in st.get('panes', []) if p.get('visible')), {})

        # D3 / D4: the count is never clipped and keeps a gap before the chevrons; NOT FOUND ends before the separator.
        def find_count():
            app.call('focus', tab=tab)
            key('f', ['cmd']); key('a', ['cmd']); key(text='quasar')
            match = wait(lambda: (lambda p: p if p.get('countText', '').endswith('/24') else None)(pane(app.call('find-state'))), timeout=5, step=.05) or {}
            m = match.get('controls', {}).get('results', {})
            key('a', ['cmd']); key(text='zzqqxx')
            miss = wait(lambda: (lambda p: p if p.get('notFound') else None)(pane(app.call('find-state'))), timeout=5, step=.05) or {}
            n = miss.get('controls', {}).get('results', {})
            sep = miss.get('controls', {}).get('separator', [])
            key('escape')
            count_fits = bool(m) and m['count'][2] >= m['countNeeds'] and m['previous'][0] - (m['count'][0] + m['count'][2]) >= 3
            miss_fits = bool(n) and n['count'][2] >= n['countNeeds'] and len(sep) == 4 and n['count'][0] + n['count'][2] <= sep[0]
            return {'ok': count_fits and miss_fits and inside(m.get('count', []), match.get('frame', [])),
                    'match': m, 'miss': n, 'separator': sep, 'bar': match.get('frame')}
        gate('UX1_D3_D4_find_count_fits', find_count)

        # D5: a sentence that does not fit one line wraps (two-line toast) and keeps every word; short copy stays one line.
        def toast_wrap():
            sentence = 'Restart at a later time to finish installing the new update!'
            app.call('toast-show', title=sentence)
            long_toast = wait(lambda: next((t for t in app.call('toasts')['toasts'] if t['title'] == sentence and not t['exiting']), None), timeout=3, step=.05) or {}
            app.call('toast-show', title='Copied')
            short = wait(lambda: next((t for t in app.call('toasts')['toasts'] if t['title'] == 'Copied' and not t['exiting']), None), timeout=3, step=.05) or {}
            two = 'Something went wrong downloading the update to Open.'
            app.call('toast-show', title=two, subtitle='We’ll try again later…')
            with_sub = wait(lambda: next((t for t in app.call('toasts')['toasts'] if t['title'] == two and not t['exiting']), None), timeout=3, step=.05) or {}
            panel = app.call('toasts')['panel']
            return {'ok': bool(with_sub) and with_sub['titleTruncated'] is False and with_sub['frame'][3] > 60
                    and inside(with_sub['titleFrame'], with_sub['frame']) and inside(with_sub['frame'], panel)
                    and bool(long_toast) and long_toast['titleTruncated'] is False and long_toast['frame'][3] == 60
                    and inside(long_toast['titleFrame'], long_toast['frame']) and inside(long_toast['frame'], panel)
                    and bool(short) and short['titleTruncated'] is False and short['frame'][3] == 42,
                    'long': long_toast, 'short': short, 'subtitle': with_sub, 'panel': panel}
        gate('UX1_D5_toast_long_copy_wraps', toast_wrap)

        # D2: hovering a link shows its URL without the scheme at the page's bottom-left (10 / 12 pt, 23 tall);
        # leaving the link hides it. In Split View it sits inside the hovered pane.
        def link_bubble(split=False, focus=None):
            if not split: app.call('navigate', tab=tab, url=origin + '/link'); app.call('wait', tab=tab)
            # The synthetic pointer reaches the focused pane's page only, so a split row focuses its pane first.
            if focus: app.call('focus', tab=focus); time.sleep(.3)
            window = app.call('window-state'); frame = window['frame']
            x = frame[2] * (0.85 if split else 0.6)
            app.call('mouse', action='hover', x=x, y=frame[3] * 0.5)
            st = wait(lambda: (lambda s: s if s.get('visible') else None)(app.call('link-status')), timeout=5, step=.05) or app.call('link-status')
            f, area = st.get('frame', []), st.get('pageArea', [])
            expected = '127.0.0.1:%d%s' % (server.server_address[1], LONG_LINK)
            placed = (len(f) == 4 and len(area) == 4 and abs(f[0] - (area[0] + 10)) <= 1 and abs(f[1] - (area[1] + 12)) <= 1
                      and f[3] == 23 and inside(f, area))
            app.call('mouse', action='hover', x=x, y=6)  # into the window's top chrome: off the link
            gone = wait(lambda: not app.call('link-status').get('visible'), timeout=3, step=.05)
            # A long URL is cut in the middle at two thirds of its page; in a full-width page it fits whole.
            fits = f[2] <= area[2] * 2 / 3 + 1 if split else not st.get('truncated')
            return {'ok': st.get('visible') is True and st.get('text') == expected and placed and fits and bool(gone)
                    and (not split or area[0] > frame[2] * 0.3), 'state': st, 'expected': expected}
        gate('UX1_D2_link_status_bubble', link_bubble)
        def split_bubble():
            other = h['new_tab'](app, origin + '/link')
            app.call('select', tab=tab)
            app.call('split')
            wait(lambda: len(app.call('split', op='state').get('panes', [])) == 2, timeout=5, step=.05)
            time.sleep(.5)
            panes = app.call('split', op='state').get('panes', [])
            right = max(panes, key=lambda p: p['frame'][0])['id'] if panes else other
            row = link_bubble(split=True, focus=right); row['split'] = app.call('split', op='state'); row['other'] = other
            row['ok'] = row['ok'] and row['state'].get('tab', '').upper() == right.upper()
            return row
        gate('UX1_D2_link_status_bubble_split', split_bubble)

        # D6: a folder card's long search placeholder ends in an ellipsis inside its field.
        def folder_placeholder():
            folder = app.call('folder-create', title='Reading list with a really long folder name')
            pinned = h['new_tab'](app, origin + '/find?folder=1')
            app.call('sidebar-drop', nodes=[pinned], parent={'kind': 'folder', 'id': folder}, index=0)
            tree = app.call('sidebar-tree')
            node = next((n for n in tree.get('pinned', []) if n.get('id') == folder), {})
            if node.get('expanded'): app.call('folder-toggle', folder=folder)
            for k in ('open.general.previewsEnabled', 'open.general.previewsFolders'):
                app.call('defaults', key=k, value=True)
            app.call('hover', leave=True, ms=300)
            shown = app.call('hover', node=folder, ms=900)
            fs = shown.get('folderSearch', {})
            app.call('hover', leave=True, ms=300)
            return {'ok': shown.get('kind') == 'folder' and fs.get('needs', 0) > fs.get('textBoxWidth', 1e9) and fs.get('tailEllipsis') is True,
                    'hover': shown}
        gate('UX1_D6_folder_placeholder_ellipsis', folder_placeholder)

        # D1: Little Open's blank bar in Light uses the Dark text palette on its dark fill. D7: Cmd+F on a Little Open page.
        def little_open():
            app.call('appearance', name='light')
            sessions = lambda: app.call('little-open-state')['sessions']
            before = {s['id'] for s in sessions()}
            app.call('little-open-action', action='blank')
            row = wait(lambda: next((s for s in sessions() if s['id'] not in before and s.get('barPresented')), None), timeout=5, step=.05) or {}
            blank = dict(row)
            # A unique address: an address already open in the main window would offer Switch to Tab instead.
            app.call('key', window=row['window'], text=origin + '/find?little=open\r')
            page = wait(lambda: next((s for s in sessions() if s['id'] == row['id'] and s['state'] == 'page' and s.get('url', '').endswith('/find?little=open')), None), timeout=12, step=.1) or {}
            time.sleep(.5)
            app.call('key', window=row['window'], key='f', modifiers=['cmd']); app.call('key', window=row['window'], text='quasar')
            found = wait(lambda: (lambda s: s if s and pane(s.get('findBar', {})).get('countText', '').endswith('/24') else None)(
                next((s for s in sessions() if s['id'] == row['id']), None)), timeout=5, step=.05) or {}
            fp = pane(found.get('findBar', {}))
            after = [{k: x.get(k) for k in ('id', 'state', 'url', 'key')} for x in sessions()]
            if any(x['id'] == row['id'] for x in after): app.call('little-open-action', id=row['id'], action='close')
            app.call('appearance', name='system')
            results['UX1_D1_little_open_bar_dark_text'] = {'ok': blank.get('barDark') is True and 'Dark' in blank.get('barAppearance', ''),
                                                          'blank': {k: blank.get(k) for k in ('barDark', 'barAppearance', 'windowAppearance', 'state')}}
            print('UX1_D1_little_open_bar_dark_text' + (' PASS' if results['UX1_D1_little_open_bar_dark_text']['ok'] else ' FAIL'), flush=True)
            return {'ok': bool(page) and fp.get('visible') is True and fp.get('countText', '').endswith('/24')
                    and inside(fp.get('frame', []), fp.get('viewportFrame', [])), 'find': fp, 'page': page.get('url'), 'sessions': after}
        gate('UX1_D7_little_open_find', little_open)
    finally:
        try: app.call('appearance', name='system')
        except Exception: pass
        app.quit(); server.shutdown(); server.server_close()
