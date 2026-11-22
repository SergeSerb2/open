"""Boost runtime and editor fixes through the real App (bug sweep round 7, lane BOOST7).

The Boosts are seeded through persistence (the Profile's Boosts/boosts.json, read at launch). Each row
drives the real App: engine navigations, the automation socket's editor actions, DevTools input.

BST7-F1: on a path with "[" "]" (Chromium keeps them raw in location.href, Foundation encodes them),
  turning Boosts off in Settings clears the page live, and Zap enters.
BST7-F2: a pushState that lands while the page is still loading re-plans Boosts at load end.
BST7-F3: a Boost whose JavaScript does not parse does not stop another Boost's JavaScript on the page.
BST7-F8: on a page whose CSP has style-src 'self', the Boost CSS, the Zap overlay and the Zap preview apply.
BST7-F4: Undo Import from Arc closes an editor that is open on an imported Boost; no later edit brings it back.
BST7-F6: Zap cancels pointerdown, mousedown, mouseup and dblclick as well as click.
BST7-F9: opening the editor again on the Boost it already shows keeps a usable Boost and the last code edit.
Synthetic pages on a loopback server only.
"""
import json
import os
import threading
import time
import uuid
from pathlib import Path
import http.server
from loopback_http import LoopbackHTTPServer


class _Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        headers = {}
        if path == '/slow.png':
            time.sleep(2.5)
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
        if path.startswith('/f2/'):
            # The page leaves its load running (a slow image) and moves its address during that load.
            body = ('<!doctype html><title>F2</title><h1>F2</h1><script>history.pushState({}, "", "/f2/watch")</script>'
                    '<img src="/slow.png">')
        elif path.startswith('/f6/'):
            body = ('<!doctype html><title>F6</title><style>#f6-target{width:300px;height:80px;background:#ddd}</style>'
                    '<h1>F6</h1><div id="f6-target">Target</div><script>window.f6={};'
                    'for (const t of ["pointerdown","pointerup","mousedown","mouseup","click","dblclick"]) '
                    'document.addEventListener(t, () => { window.f6[t] = (window.f6[t] || 0) + 1; }, true);</script>')
        else:
            body = '<!doctype html><title>Boost sweep</title><h1>Boost sweep</h1>'
        if path.startswith('/f8/'):
            headers['Content-Security-Policy'] = "style-src 'self'"
        data = body.encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers(); self.wfile.write(data)

    def log_message(self, *_):
        pass


def _boost(name, path, css='', js=''):
    now = time.time()
    return {'id': str(uuid.uuid4()).upper(), 'name': name, 'siteMatch': {'domain': '127.0.0.1', 'pathPrefix': path},
            'isEnabled': True, 'css': css, 'js': js, 'zaps': [], 'createdAt': now, 'updatedAt': now}


def run(factory, results, tmp, env):
    if os.environ.get('OPEN_E2E_BST7_F4_ONLY') == '1':
        run_f4(factory, results, tmp, env)
        return
    wait = env['wait_until']
    from boost_zap import PickerFlow
    server = LoopbackHTTPServer(_Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    app, saved = None, {}

    def record(key, ok, **detail):
        results[key] = dict(ok=bool(ok), load=list(os.getloadavg()), **detail)
        print(key, 'PASS' if ok else 'FAIL', json.dumps(detail)[:600], flush=True)

    def attempt(key, fn):
        try:
            fn()
        except Exception as error:  # A failed row must not hide the next one.
            record(key, False, error=repr(error))
    try:
        app = factory(urls=('about:blank',), fresh=True)
        keys = {'open.advanced.enableBoosts': True, 'open.boosts.hasDismissedInterstitial': True,
                'open.boosts.hasDismissedJSNotice': True, 'open.boosts.codeEditorSize': '480x588'}
        for key, value in keys.items():
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=value)
        snapshot = json.loads(Path(app.call('save')).read_text())
        profile = next(p for p in snapshot['profiles'] if p['id'] == next(s for s in app.call('spaces') if s['focused'])['profile'])
        boosts_file = Path(app.user_data) / 'Profiles' / profile.get('dataDirectoryName', 'Default') / 'Boosts' / 'boosts.json'
        app.quit()
        boosts = [
            _boost('F1 bracket', '/f1[x]', css='h1 { color: rgb(11, 22, 33) !important; }'),
            _boost('F2 watch', '/f2/watch', css='h1 { color: rgb(44, 55, 66) !important; }'),
            _boost('F3 good', '/f3', js='window.f3Good = (window.f3Good || 0) + 1;'),
            _boost('F3 broken', '/f3', js='document.querySelector('),
            _boost('F6 zap', '/f6', css='h2 { color: rgb(1, 1, 1); }'),
            _boost('F8 csp', '/f8', css='h1 { color: rgb(77, 88, 99) !important; }'),
            _boost('F9 code', '/f9', css='h1 { color: rgb(5, 6, 7); }'),
        ]
        ids = {b['name']: b['id'] for b in boosts}
        boosts_file.parent.mkdir(parents=True, exist_ok=True)
        boosts_file.write_text(json.dumps({'schemaVersion': 1, 'profileID': profile['id'], 'boosts': boosts}))
        app = factory(urls=('about:blank',))
        tab = env['new_tab'](app, origin + '/plain.html')
        app.call('select', tab=tab); app.call('wait', tab=tab)
        flow = PickerFlow(app, tab, wait)

        def color():
            return app.eval(tab, "getComputedStyle(document.querySelector('h1')).color")

        def go(url):
            app.call('navigate', tab=tab, url=url); app.call('wait', tab=tab)

        def editor(action='state', **kw):
            return app.call('boost-editor', action=action, **kw)

        def f1():
            # A page link keeps "[" "]" (and "{" "}" "|" in the query) raw; the automation navigate
            # command would encode them.
            go(origin + '/plain.html')
            app.eval(tab, "location.href='/f1[x]/page.html?q[a]={b}|c#d[e]';true")
            wait(lambda: app.eval(tab, "location.pathname==='/f1[x]/page.html'&&document.readyState==='complete'"), timeout=10, step=.1)
            app.call('wait', tab=tab)
            boosted = wait(lambda: color() == 'rgb(11, 22, 33)', timeout=5, step=.05)
            try:
                app.call('defaults', key='open.advanced.enableBoosts', value=False)
                cleared = wait(lambda: color() != 'rgb(11, 22, 33)', timeout=5, step=.05)
                off = color()
            finally:
                app.call('defaults', key='open.advanced.enableBoosts', value=True)
            restored = wait(lambda: color() == 'rgb(11, 22, 33)', timeout=5, step=.05)
            editor('open', boost=ids['F1 bracket'])
            wait(lambda: editor()['colorsReady'], timeout=10, step=.05)
            zap = False
            try:
                flow.enter()
                time.sleep(.5)
                zap = flow.active() and editor()['zap']
            except AssertionError:
                zap = False
            finally:
                editor('close')
            record('BST7_F1_bracket_path_live_refresh_and_zap', boosted and cleared and restored and zap,
                   url=app.eval(tab, 'location.href'), boostedAtLoad=bool(boosted), clearedLive=bool(cleared), colorWhenOff=off,
                   restoredLive=bool(restored), zapEntered=bool(zap),
                   negative='location.href kept "[" "]" "{" "}" "|" raw but the guard compared it with Foundation\'s encoded form: '
                            'the clear, the re-apply and the picker bootstrap all returned false')
        attempt('BST7_F1_bracket_path_live_refresh_and_zap', f1)

        def f2():
            go(origin + '/plain.html')
            app.call('navigate', tab=tab, url=origin + '/f2/home'); app.call('wait', tab=tab)
            moved = wait(lambda: app.eval(tab, "location.pathname==='/f2/watch'&&document.readyState==='complete'"), timeout=10, step=.1)
            applied = wait(lambda: color() == 'rgb(44, 55, 66)', timeout=5, step=.05)
            watched = color()
            # An ordinary load of a Boosted page still delivers once (at commit), not again at load end.
            go(origin + '/plain.html')
            before = editor()['deliveryCount']
            go(origin + '/f9/page.html')
            time.sleep(.5)
            deliveries = editor()['deliveryCount'] - before
            record('BST7_F2_pushstate_during_load', moved and applied and deliveries == 1, url=app.eval(tab, 'location.href'),
                   color=watched, ordinaryLoadDeliveries=deliveries,
                   negative='the URL notification arrived while the page was loading and nothing re-planned Boosts at load end')
        attempt('BST7_F2_pushstate_during_load', f2)

        def f3():
            go(origin + '/f3/page.html')
            good = app.eval(tab, 'window.f3Good ?? 0')
            record('BST7_F3_syntax_error_isolated', good == 1, goodRuns=good,
                   negative='both Boosts shared one main-world script: its SyntaxError stopped the other Boost')
        attempt('BST7_F3_syntax_error_isolated', f3)

        def f6():
            go(origin + '/f6/page.html')
            editor('open', boost=ids['F6 zap'])
            wait(lambda: editor()['colorsReady'], timeout=10, step=.05)
            point = app.eval(tab, "(() => {const r=document.querySelector('#f6-target').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
            def press(counts):
                for count in counts:
                    for kind in ('mousePressed', 'mouseReleased'):
                        app.call('devtools', tab=tab, method='Input.dispatchMouseEvent',
                                 params={'type': kind, 'x': point[0], 'y': point[1], 'button': 'left', 'clickCount': count})
                time.sleep(.3)
            try:
                flow.enter()
                app.eval(tab, 'window.f6={};true')
                press((1, 2))
                seen = app.eval(tab, 'window.f6')
                active = flow.active()
            finally:
                editor('close')
            stopped = wait(flow.stopped, timeout=5, step=.05)
            app.eval(tab, 'window.f6={};true')
            press((1,))
            after = app.eval(tab, 'window.f6')
            record('BST7_F6_zap_cancels_press_events', active and stopped and seen == {} and after.get('mousedown') == 1 and after.get('click') == 1,
                   duringZap=seen, afterExit=after, pickerActive=active,
                   negative='only click was cancelled, after page capture listeners: the page saw pointerdown, mousedown, mouseup, click and dblclick')
        attempt('BST7_F6_zap_cancels_press_events', f6)

        def f8():
            go(origin + '/f8/page.html')
            applied = wait(lambda: color() == 'rgb(77, 88, 99)', timeout=5, step=.05)
            element = app.eval(tab, "document.getElementById('open-boosts-style') ? (document.getElementById('open-boosts-style').sheet ? 'sheet' : 'no sheet') : 'none'")
            # The Zap overlay and its live preview use the same page under the same CSP.
            editor('open', boost=ids['F8 csp'])
            wait(lambda: editor()['colorsReady'], timeout=10, step=.05)
            bar, preview = None, 0
            try:
                flow.enter()
                box = app.call('devtools', tab=tab, method='DOM.getBoxModel', params={'nodeId': flow.dom('.bar')})['model']['border']
                bar = max(box[1::2]) - min(box[1::2])
                flow.pick('h1', '.this')
                wait(lambda: editor()['zapCount'] == 1, timeout=5, step=.05)
                # The applier's sheet and the picker's preview sheet both hide the pick.
                hiding = "[...document.adoptedStyleSheets].filter(s => [...s.cssRules].some(r => r.style?.display === 'none')).length"
                # The applier's sheet arrives with the asynchronous store refresh: poll for it.
                wait(lambda: app.eval(tab, hiding, world='open') >= 2, timeout=5, step=.05)
                preview = app.eval(tab, hiding, world='open')
            finally:
                editor('close')
            record('BST7_F8_strict_style_src', applied and bar == 56 and preview >= 2, color=color(), styleElement=element,
                   zapBarHeight=bar, hidingSheets=preview,
                   negative="the page's style-src 'self' blocked the Boost's and the Zap overlay's inline <style> elements")
        attempt('BST7_F8_strict_style_src', f8)

        def f9_draft():
            go(origin + '/plain.html')
            first = editor('open')
            draft = first['boost']['id']
            second = editor('open', boost=draft)
            stored = [b['id'] for b in app.call('boosts', action='list')]
            ok = second['open'] and second['boost']['id'] in stored
            editor('close')
            record('BST7_F9_reopen_empty_draft', ok, draft=draft, session=second['boost']['id'], storedIDs=len(stored),
                   inStore=second['boost']['id'] in stored,
                   negative='the old session deleted its empty draft after the new session had read it')
        attempt('BST7_F9_reopen_empty_draft', f9_draft)

        def f9_code():
            go(origin + '/f9/page.html')
            editor('open', boost=ids['F9 code'], mode='code')
            editor('tap', id='editor.code.js')
            typed = 'window.f9Typed = 1;'
            editor('type', text=typed)
            # Before the 0.5 s JavaScript debounce: the draft is still only in the old session.
            again = editor('open', boost=ids['F9 code'])
            stored = app.call('boosts', action='get', boost=ids['F9 code'])
            editor('close')
            record('BST7_F9_reopen_keeps_code_edit', again['boost']['js'] == typed and stored['js'] == typed,
                   sessionJS=again['boost']['js'], storedJS=stored['js'],
                   negative='the new session read the Boost before the old session flushed its code draft')
        attempt('BST7_F9_reopen_keeps_code_edit', f9_code)
    finally:
        try:
            env['_restore_defaults'](app if app and not app.closed else None, saved)
        finally:
            if app and not app.closed:
                app.quit()
            server.shutdown(); server.server_close()
    run_f4(factory, results, tmp, env)


def run_f4(factory, results, tmp, env):
    """Settings Import from Arc of the synthetic source, an editor on an imported Boost, then Undo."""
    import runpy
    import shutil
    root = Path(env['ROOT'])
    generator = runpy.run_path(str(root / 'tools/e2e/fixtures/import-boosts/generate.py'))
    fixture_server = runpy.run_path(str(root / 'tools/e2e/firstrun_boosts.py'))['fixture_server']
    source = Path(tmp) / 'bst7-arc-boosts'
    shutil.rmtree(source, ignore_errors=True)
    generator['write'](source)
    wait = env['wait_until']
    app, saved = None, {}
    key = 'BST7_F4_undo_import_closes_editor'
    try:
        with fixture_server() as origin:
            app = factory(urls=(), fresh=True, extra_args=['--arc-dir=' + str(source),
                '--host-resolver-rules=MAP example.com 127.0.0.1, MAP * ~NOTFOUND', '--no-proxy-server'])
            for name, value in {'open.firstRun.completed': None, 'open.import.lastArcDir': None,
                                'open.settings.lastPane': None, 'open.advanced.enableBoosts': True,
                                'open.boosts.hasDismissedInterstitial': True,
                                'open.advanced.tabSleepMode': 'never', 'open.library.lastSection': 'spaces'}.items():
                saved[name] = app.call('defaults', key=name, persistent=True)
                app.call('defaults', key=name, value=value)
            tab = env['new_tab'](app, origin)
            app.call('first-run', action='settings-import', directory=str(source))
            app.call('first-run', action='settings-select', history=False)
            app.call('first-run', action='settings-next')
            app.call('first-run', action='settings-run')
            assert wait(lambda: app.call('first-run')['settingsStep'] == 'Report', timeout=30, step=.05)
            app.call('first-run', action='settings-done')
            imported = app.call('boosts')
            enabled = next(b for b in imported if b['isEnabled'])
            app.call('select', tab=tab)
            opened = app.call('boost-editor', action='open', boost=enabled['id'])['open']
            window = app.call('shell-windows')[0]['id']
            app.call('window-focus', id=window, activate=True)
            app.call('sidebar-key', key='z', modifiers=['command'])
            assert wait(lambda: not app.call('first-run')['importUndoInProgress'], timeout=30, step=.02)
            undone = len(app.call('boosts')) == 0
            still_open = app.call('boost-editor')['open']
            edited = False
            if still_open:
                # What a user does next in that editor: one edit.
                try:
                    app.call('boost-editor', action='tap', id='case'); edited = True
                except RuntimeError:
                    pass
                time.sleep(.3)
            after = [b['id'] for b in app.call('boosts')]
            results[key] = dict(ok=bool(opened and undone and not still_open and not after), load=list(os.getloadavg()),
                                editorOpenBeforeUndo=opened, storeEmptyAfterUndo=undone, editorOpenAfterUndo=still_open,
                                editAfterUndo=edited, storedAfterEdit=after,
                                negative='Undo deleted the imported Boosts but left the editor open; its next edit wrote the Boost back')
            print(key, 'PASS' if results[key]['ok'] else 'FAIL', json.dumps(results[key])[:600], flush=True)
    except Exception as error:
        results[key] = dict(ok=False, error=repr(error), load=list(os.getloadavg()))
        print(key, 'FAIL', repr(error), flush=True)
    finally:
        try:
            env['_restore_defaults'](app if app and not app.closed else None, saved)
        finally:
            if app and not app.closed:
                app.quit()
