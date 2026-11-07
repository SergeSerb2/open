"""Private-window product flows through the real App, native menus, and engine."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import threading
import time


def checks(factory, results, tmp, harness):
    wait = harness.wait_until
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/download':
                body = b'private download fixture\n'
                self.send_response(200)
                self.send_header('Content-Disposition', 'attachment; filename="private.txt"')
                self.send_header('Content-Type', 'application/octet-stream')
            elif self.path == '/favicon.svg':
                body = b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="#72a"/></svg>'
                self.send_response(200); self.send_header('Content-Type', 'image/svg+xml')
            else:
                body = ('<!doctype html><title>Private fixture ' + self.path + '</title>'
                    '<link rel="icon" href="/favicon.svg"><h1>Private window fixture</h1>'
                    '<a id="link" href="/linked">Open fixture link</a><br>'
                    '<a id="download" href="/download">Download</a>').encode()
                self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]
    app = None; saved = {}
    keys = ['open.links.optionCommandClickLittleOpen', 'open.general.searchSuggestNoticeDismissed',
            'open.links.littleOpenHotkeyEnabled', 'open.general.previewsEnabled', 'open.advanced.playSoundEffects',
            'open.links.externalInLittleOpen']
    def check(name, ok, **evidence): results[name] = dict(ok=bool(ok), **evidence)
    def state(): return app.call('incognito-state', private=True)
    def windows(private=None):
        rows = app.call('incognito-state')['windows']
        return rows if private is None else [w for w in rows if w['private'] == private]
    def focus(window): app.call('window-focus', id=window['id'], activate=True)
    def key(k, mods=()): return app.call('key', key=k, modifiers=list(mods), route='app')
    def dismiss():
        if app.call('commandbar-state').get('presented'): key('escape')
    def open_page(path):
        dismiss(); tab = app.call('open', url=base + path)['id']
        app.call('wait', tab=tab)
        wait(lambda: app.eval(tab, 'location.pathname') == path, timeout=5, step=.05)
        return tab
    def private_window(entry):
        before = {w['id'] for w in windows(True)}
        if entry == 'menu': app.call('menu-perform', id='new-incognito-window')
        elif entry == 'key': key('n', ['cmd', 'shift'])
        else:
            key('t', ['cmd']); app.call('key', text='New Incognito Window')
            found = wait(lambda: next(([i] for i, r in enumerate(app.call('commandbar-state').get('rows', []))
                                     if r.get('action') == 'new-incognito-window'), None), timeout=5, step=.05)
            found = found[0] if found else None
            # Native Down/Return executes the actual action row.
            assert found is not None, 'incognito action absent from command bar'
            current = app.call('commandbar-state')['selected']
            for _ in range(max(0, found - current)): key('down')
            for _ in range(max(0, current - found)): key('up')
            key('return')
        window = wait(lambda: next((w for w in windows(True) if w['id'] not in before), None), timeout=5, step=.05)
        assert window, 'private window did not open via ' + entry
        focus(window); dismiss()
        return window
    def fingerprint():
        root = Path(app.user_data)
        tables = {}
        for file in sorted(root.rglob('*.sqlite3')):
            if 'Engine' in file.relative_to(root).parts: continue
            with sqlite3.connect('file:' + str(file) + '?mode=ro', uri=True) as db:
                tables[str(file.relative_to(root))] = {name: db.execute('SELECT count(*) FROM "' + name.replace('"', '""') + '"').fetchone()[0]
                    for name, in db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")}
        snapshot = root / 'State/browser.json'
        thumbnails = sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and ('Captures' in p.parts or 'Thumbnails' in p.parts))
        return dict(snapshot=hashlib.sha256(snapshot.read_bytes()).hexdigest(), tables=tables, thumbnails=thumbnails)
    try:
        app = factory(urls=(base + '/normal',), fresh=True)
        saved = {k: app.call('defaults', key=k, persistent=True) for k in keys}
        for k in keys: app.call('defaults', key=k, value=None)
        for k, v in zip(keys, [True, True, False, False, False, False]): app.call('defaults', key=k, value=v)
        normal = windows(False)[0]; normal_tab = app.call('tabs')[0]['id']; app.call('wait', tab=normal_tab)
        profile = app.call('history-state')['profile']
        app.eval(normal_tab, "document.cookie='normalOnly=1; path=/'; true")
        # Drain normal launch metadata and durable writes before the private session.
        app.call('history-state', profile=profile); app.call('save'); time.sleep(1.2)
        recent_before = app.call('archive')
        before = fingerprint(); counts = app.call('incognito-state')
        one = private_window('menu')
        # Focused break-and-revert runs still create real windows/pages. The fault
        # is a temporary source edit, never an automation substitute for storage.
        negative = os.environ.get('OPEN_INCOGNITO_NEGATIVE')
        if negative == 'model':
            app.call('open', url=base + '/private-model-fault')
            app.call('save'); time.sleep(.4)
            after = fingerprint()
            check('no_snapshot_history_change', before == after and counts['normalTabs'] == app.call('incognito-state')['normalTabs'], before=before, after=after)
            return
        if negative == 'disk':
            tab = open_page('/private-disk-fault')
            check('cookie_normal_absent_private', 'normalOnly' not in app.eval(tab, 'document.cookie'))
            return
        view = state()
        ax = next(w for w in app.call('windows', accessibility=True) if w['number'] == one['number'])
        check('private_ax_header', 'Incognito' in ax['text'] and 'eyeglasses' in ax['text'], text=ax['text'])
        check('menu_private_chrome', view['private'] and not view['modelIsNormal'] and not view['modelArchiveSink']
              and view['header'] == 'Incognito' and view['appearance'] == 'NSAppearanceNameDarkAqua'
              and all(view['chrome'].values()) and one['title'] == 'Incognito', state=view)
        tab = open_page('/one'); first = state()
        check('off_the_record_context', first['ephemeral'], context=first['context'])
        check('cookie_normal_absent_private', 'normalOnly' not in app.eval(tab, 'document.cookie'))
        app.eval(tab, "document.cookie='privateOnly=1; path=/'; true")
        two = private_window('key'); second_tab = open_page('/two'); second = state()
        check('shortcut_shared_private_session', second['ephemeral'] and second['context'] == first['context']
              and 'privateOnly=1' in app.eval(second_tab, 'document.cookie'), state=second)
        for path in ['/navigation-2', '/navigation-3']:
            app.call('navigate', tab=second_tab, url=base + path); app.call('wait', tab=second_tab)
        third = open_page('/close-me'); app.call('close', tab=third)
        app.call('download-dir', path=tmp)
        app.call('click', tab=second_tab, selector='#download')
        check('private_download_allowed', wait(lambda: (Path(tmp) / 'private.txt').exists() and (Path(tmp) / 'private.txt').read_bytes() == b'private download fixture\n', timeout=12, step=.1))
        private_ids = {t['id'] for t in state()['tabs']} | {tab}
        focus(normal)
        check('normal_dump_excludes_live_private', not any(p['ephemeral'] for p in app.call('pages'))
              and not private_ids.intersection(t['id'] for t in app.call('tabs')))
        key('tab', ['ctrl'])
        switcher = app.call('tab-switcher-state')
        check('normal_tab_switcher_private_free', not private_ids.intersection(switcher['items']), items=switcher['items'])
        key('escape')
        focus(one); app.call('window-close'); focus(two)
        check('session_survives_one_close', 'privateOnly=1' in app.eval(second_tab, 'document.cookie'))
        app.call('window-close'); focus(normal)
        check('cookie_private_absent_normal', 'privateOnly' not in app.eval(normal_tab, 'document.cookie'))
        app.call('history-state', profile=profile); time.sleep(1.2)
        after = fingerprint(); after_counts = app.call('incognito-state')
        check('no_snapshot_history_change', before == after and counts['normalTabs'] == after_counts['normalTabs']
              and counts['historyWrites'] == after_counts['historyWrites'], before=before, after=after)
        check('no_download_history', counts['downloads'] == after_counts['downloads'])
        check('no_recently_closed', app.call('archive') == recent_before)
        check('normal_model_dump_private_free', all('private.txt' not in json.dumps(v) and base + '/one' not in json.dumps(v)
              for v in [app.call('tabs'), app.call('spaces')]))
        three = private_window('commandbar'); tab = open_page('/fresh')
        check('last_window_ends_session', 'privateOnly' not in app.eval(tab, 'document.cookie') and state()['context'] != first['context'])
        # All navigation paths below still use the private factory.
        old_tabs = len(app.call('tabs')); old_windows = len(windows())
        point = app.eval(tab, "(()=>{const r=document.querySelector('#link').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
        app.call('little-open-link-click', tab=tab, x=point[0], y=point[1])
        stayed = wait(lambda: len(app.call('tabs')) == old_tabs + 1, timeout=5, step=.05)
        check('option_command_link_stays_private', stayed and len(windows()) == old_windows and state()['ephemeral']
              and not app.call('little-open-state').get('sessions', []))
        current = next(t['id'] for t in app.call('tabs') if t['selected'])
        key('l', ['cmd']); check('command_l_private', app.call('commandbar-state')['presented']); key('escape')
        key('t', ['cmd']); check('command_t_private', app.call('commandbar-state')['presented']); key('escape')
        app.call('peek-open', tab=current, url=base + '/peek')
        peek = wait(lambda: app.call('peek-state').get('shown'), timeout=5, step=.05)
        peek_pages = wait(lambda: [p for p in app.call('pages', private=True) if p.get('url') == base + '/peek'], timeout=5, step=.05)
        check('peek_private', peek and bool(peek_pages) and all(p['ephemeral'] and p['context'] == state()['context'] for p in peek_pages))
        app.call('peek-close')
        panes = app.call('split')
        dismiss()
        split_pages = [p for p in app.call('pages', private=True) if p['identifier'] in [t.get('page', {}).get('identifier') for t in panes]]
        check('split_private', len(panes) == 2 and len(split_pages) == 2 and all(p['ephemeral'] and p['context'] == state()['context'] for p in split_pages))
        app.call('split')
        key('n', ['cmd'])
        check('command_n_normal', wait(lambda: len(windows(False)) == 2, timeout=5, step=.05) and not state()['private'])
        app.call('window-close'); focus(normal)
        app.call('policy', contextMenu='run-open:Open Link in Incognito Window'); app.call('events')
        point = app.eval(normal_tab, "(()=>{const r=document.querySelector('#link').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
        previous = {w['id'] for w in windows(True)}
        app.call('rightclick', tab=normal_tab, x=point[0], y=point[1])
        linked = wait(lambda: next((w for w in windows(True) if w['id'] not in previous), None), timeout=5, step=.05)
        check('context_menu_private_link', bool(linked))
        if linked: focus(linked); wait(lambda: state()['ephemeral'], timeout=5, step=.05)
        # Real window-server snapshots on each physical display, never rescaled renders.
        evidence = Path(harness.ROOT) / 'docs/engine-spike/incognito'; evidence.mkdir(parents=True, exist_ok=True)
        for appearance in ['light', 'dark']:
            app.call('appearance', name=appearance)
            for scale in [int(os.environ.get('OPEN_INCOGNITO_CAPTURE_SCALE', '1'))]:
                display = app.call('incognito-screen', scale=scale)
                time.sleep(.15)
                path = evidence / ('private-%s-%dx.png' % (appearance, scale))
                subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(display['number']), str(path)], check=True)
                width, height, pixel = harness.read_image(str(path), srgb=True)
                # Flat empty sidebar below the rows: actual pixels, no PNG-size proxy.
                colors = [pixel(x * scale, y * scale) for x, y in [(70, 580), (100, 590), (130, 600)]]
                target = (38, 35, 43)
                check('snapshot_%s_%dx' % (appearance, scale), path.is_file() and state()['appearance'] == 'NSAppearanceNameDarkAqua'
                      and all(max(abs(a-b) for a, b in zip(c, target)) <= 2 for c in colors), scale=display['scale'], pixels=colors, size=[width, height], path=str(path.relative_to(harness.ROOT)))
        # Last-session quit has a beforeunload handler; private pages must not prompt.
        private_tab = next(t['id'] for t in app.call('tabs') if t['selected'])
        app.eval(private_tab, "window.addEventListener('beforeunload',e=>{e.preventDefault();e.returnValue='stay';});true")
        focus(normal); app.call('window-close')
        focus(linked or three)
        # Only private windows remain: an external link must open a normal window
        # (most recent Space), never a tab of the private window's model.
        private_before = sorted(t['id'] for t in state()['tabs'])
        external = base + '/external-only-private'
        sent = subprocess.run(['/usr/bin/open', '-a', app.bundle, external], capture_output=True, text=True, timeout=15)
        normal_again = wait(lambda: next((w for w in windows(False)), None), timeout=8, step=.05)
        landed = wait(lambda: any(t['url'] == external for t in app.call('tabs')), timeout=8, step=.05) if normal_again else False
        if normal_again: focus(normal_again)
        landed_normal = landed and not state()['private'] and any(t['url'] == external and t['selected'] for t in app.call('tabs'))
        focus(linked or three)
        check('external_link_only_private_opens_normal', sent.returncode == 0 and bool(normal_again) and landed_normal
              and sorted(t['id'] for t in state()['tabs']) == private_before, window=normal_again, stderr=sent.stderr[-300:])
        if normal_again: focus(normal_again); app.call('window-close'); focus(linked or three)
        app.call('history-state', profile=profile)
        app.call('save'); quit_before = fingerprint()
        app.activation_trace = app.call('activation-events')
        app.call('quit'); clean_exit = wait(lambda: not app.process_path(app.pid), timeout=8, step=.1)
        app.quit()
        check('quit_private_no_prompt_no_records', clean_exit and fingerprint() == quit_before)
        results['native_2x_captures'] = dict(status='DEFERRED', reason='Lead ruling 16:28: M5 exposes 1x only; M1 held. Run OPEN_INCOGNITO_CAPTURE_SCALE=2 under the same lock on a native 2x display. No upscaling.')
        results['parent_profiles_after_0701'] = dict(status='SKIP', reason='0701 has not merged: per-parent OTR ancestry, per-parent extensions and cross-parent cookie isolation need the engine API. Current provider requests Default OTR and records the requested parent.')
        results['boosts_disabled'] = dict(status='DEFERRED', reason='Lead ruling 16:12: Section 12 consumes factory.isIncognito when its App presenter lands.')
    finally:
        if saved: harness._restore_defaults(app, saved)
        if app: app.quit()
        server.shutdown(); server.server_close()
