"""Bug sweep r7 (lane LIBSPACE7): Library overlay and Spaces UI rows.

Run by the history suite; OPEN_LIBRARY_R7_ONLY=1 runs only these rows, and
OPEN_LIBRARY_R7_ROWS=X01,W03 runs only the named rows. Every row drives the real App
through the automation socket on a fresh synthetic Profile. An exception in one row
records FAIL for that row; the next row still runs.
"""
import http.server
import json
import os
import threading
import time
from pathlib import Path

from loopback_http import LoopbackHTTPServer


def _title_server():
    """Pages titled by their path: /r7-alpha -> "R7 alpha"."""
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            title = 'R7 ' + self.path.strip('/').split('?')[0].replace('r7-', '').replace('-', ' ')
            body = ('<!doctype html><title>%s</title><body>%s</body>' % (title, title)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, 'http://127.0.0.1:%d' % server.server_address[1]


def _try(fn):
    try: return fn()
    except Exception: return None


def run(factory, results, tmp, wait_until):
    only = set(filter(None, os.environ.get('OPEN_LIBRARY_R7_ROWS', '').split(',')))
    server, base = _title_server()
    app = factory(urls=('about:blank',), fresh=True)

    def check(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('library_r7 %-48s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
    def lib(**kw): return app.call('library', **kw)
    def rows(kind=None): return [r for r in lib().get('rows', []) if kind is None or r['kind'] == kind]
    def close_library():
        if _try(lambda: lib().get('open')): _try(lambda: lib(action='close')); wait_until(lambda: not lib().get('open'), timeout=5, step=.05)
    def open_library(section):
        lib(action='open', section=section)
        return wait_until(lambda: lib().get('open'), timeout=5, step=.05)
    def loaded(tab, title):
        return wait_until(lambda: any(t['id'] == tab and t.get('title') == title for t in app.call('tabs')), timeout=10, step=.05)
    def focused_space(): return next((s for s in app.call('spaces') if s['focused']), {}).get('id')

    def x06():
        # First: a fresh Profile has an empty Archive.
        open_library('archive')
        empty = wait_until(lambda: lib().get('emptyVisible'), timeout=8, step=.05)
        state = lib().get('emptyState', {})
        # Archive's "Learn more" had no action: a dimmed button that ignored clicks and AXPress.
        check('R7_X06_archive_empty_has_no_dead_button', empty and state.get('title') == 'Nothing archived yet'
              and not state.get('buttonVisible'), emptyState=state)

    def x01():
        # 150 synthetic visits, newest first in the list. One History page is 100 rows.
        for i in range(150):
            app.call('history-record', url='%s/r7-page-%03d' % (base, i), title='R7 page %03d' % i, ago=600 + i * 30)
        open_library('history')
        assert wait_until(lambda: len(rows('history')) >= 100, timeout=10, step=.05), len(rows('history'))
        time.sleep(.3)  # The idle append slices are done.
        target = rows('history')[80]
        lib(action='row-select', id=target['id'])
        before = next(r for r in rows('history') if r['id'] == target['id'])
        # A new visit: the History store changes, and the open list rebuilds at the same depth.
        app.call('history-record', url=base + '/r7-new-visit', title='R7 new visit', ago=0)
        grew = wait_until(lambda: any(r['title'] == 'R7 new visit' for r in rows('history')), timeout=10, step=.05)
        time.sleep(.4)
        after = next((r for r in rows('history') if r['id'] == target['id']), {})
        # One row more above it, no new heading: the row moves down one row height at most.
        moved = after['frame'][1] - before['frame'][1] if after else None
        # A row pushed below the visible rows has no cell to draw; a visible one draws as selected.
        check('R7_X01_refresh_keeps_selection_and_position', grew and after.get('selected')
              and (after.get('drawnSelected') or not after.get('realized')) and moved is not None and 0 <= moved <= 60,
              before={k: before.get(k) for k in ('id', 'selected', 'frame')},
              after={k: after.get(k) for k in ('id', 'selected', 'drawnSelected', 'realized', 'frame')}, moved=moved,
              selected=[r['title'] for r in rows('history') if r['selected']])

    def x02():
        app.call('history-record', url=base + '/r7-guide', title='React Hooks Guide', ago=5)
        open_library('history')
        wait_until(lambda: len(rows('history')) > 0, timeout=8, step=.05)
        lib(action='search', text='hooks react')
        found = wait_until(lambda: any(r['title'] == 'React Hooks Guide' for r in rows('history')), timeout=8, step=.05)
        state = lib()
        # The History store matched both words; the panel's own filter wanted one phrase.
        check('R7_X02_history_search_words_any_order', found and not state.get('emptyVisible'),
              titles=[r['title'] for r in rows('history')][:5], empty=state.get('emptyState', {}).get('title'))
        lib(action='search', text='')

    def x03():
        tab = app.call('open', url=base + '/r7-restored')['id']; loaded(tab, 'R7 restored')
        app.call('close', tab=tab)
        open_library('archive')
        row = wait_until(lambda: next((r for r in rows('archive') if r['title'] == 'R7 restored'), None), timeout=8, step=.05)
        lib(action='row-action', id=row['id'], name='Restore')
        closed = wait_until(lambda: not lib().get('open'), timeout=8, step=.05)
        back = any(t.get('title') == 'R7 restored' for t in app.call('tabs'))
        open_library('archive')
        time.sleep(.5)
        state = lib()
        # "Restored to …" was set as the Library closed; the next open showed it as a stale status line.
        check('R7_X03_restore_status_not_stale_on_reopen', closed and back and state.get('statusLabel') == '',
              statusLabel=state.get('statusLabel'), status=state.get('status'), restored=back)

    def w02():
        open_library('history')
        app.call('menu-perform', id='new-space')
        def form():
            c = app.call('creation-state')
            return c if c.get('open') and c.get('visible') and c.get('nameFocused') and not lib().get('open') \
                and app.call('window-state').get('sidebarVisible') else None
        shown = wait_until(form, timeout=5, step=.05)
        creation = app.call('creation-state')
        # The form was built in the sidebar the Library hides, and took the typing out of sight.
        check('R7_W02_new_space_closes_library', shown, libraryOpen=lib().get('open'),
              sidebarVisible=app.call('window-state').get('sidebarVisible'),
              creation={k: creation.get(k) for k in ('open', 'visible', 'nameFocused')})
        app.call('editor-close')
        open_library('history')
        app.call('menu-perform', id='rename-space')
        alert = wait_until(lambda: _try(lambda: app.call('alert')), timeout=5, step=.05) or {}
        # Rename asks with the dialog, as for a hidden sidebar, not with the hidden header field.
        check('R7_W02_rename_space_with_library_asks', 'Rename' in alert.get('buttons', []), alert=alert)
        if alert: app.call('alert', button='Cancel')

    def w04():
        bindings = Path(app.user_data, 'State/keybindings.json')
        try:
            first = app.call('spaces')[0]['id']
            def space_item(): return next((n for n in app.call('menu-state') if n['id'] == 'dynamic-space-' + first), {})
            default = space_item()
            bindings.parent.mkdir(parents=True, exist_ok=True)
            bindings.write_text(json.dumps({'version': 1, 'bindings': {
                'go-to-space-1': {'shortcuts': [{'key': '1', 'modifiers': ['option', 'control']}]}}}))
            app.call('reload-keybindings'); time.sleep(.2)
            custom = space_item()
            # NSEvent.ModifierFlags: control 1<<18, option 1<<19. The item kept a fixed ⌃1.
            check('R7_W04_space_menu_key_follows_binding', default.get('key') == '1' and default.get('modifierMask') == 1 << 18
                  and custom.get('key') == '1' and custom.get('modifierMask') == (1 << 18) | (1 << 19),
                  default={k: default.get(k) for k in ('key', 'modifierMask')}, custom={k: custom.get(k) for k in ('key', 'modifierMask')})
        finally:
            bindings.unlink(missing_ok=True); _try(lambda: app.call('reload-keybindings'))

    def w01():
        first = focused_space()
        alpha = app.call('open', url=base + '/r7-alpha')['id']; loaded(alpha, 'R7 alpha')
        second = app.call('space-create', title='R7 Second')
        beta = app.call('open', url=base + '/r7-beta')['id']; loaded(beta, 'R7 beta')
        app.call('space', space=first)
        def title(): return next((w['title'] for w in app.call('shell-windows')), '')
        def tab_items(): return {n['payload'] for n in app.call('menu-state') if n['id'].startswith('dynamic-tab-')}
        assert wait_until(lambda: title() == 'R7 alpha' and alpha in tab_items(), timeout=5, step=.05), \
            (title(), tab_items(), app.call('spaces'), first, second)
        open_library('spaces'); time.sleep(.3)
        items = app.call('space-manager-menu', space=second, item='?')
        app.call('space-manager-menu', space=second, item=next(i for i in items if i.startswith('Edit Theme')))
        switched = wait_until(lambda: focused_space() == second, timeout=5, step=.05)
        editor = app.call('editor-state')
        time.sleep(.4)
        menus = tab_items()
        # The editor's own Space switch skipped the window's focus path (menus, extensions' active tab).
        check('R7_W01_edit_theme_switch_updates_window_menus', switched and editor.get('open') and title() == 'R7 beta'
              and beta in menus and alpha not in menus,
              title=title(), editorOpen=editor.get('open'), tabMenu=sorted(menus), alpha=alpha, beta=beta)
        app.call('editor-close')

    def w03():
        import live_data
        gh_server, port, gh = live_data.github_fixture()
        try:
            app.call('live-folder-origin', url='http://github.localhost:%d' % port)
            for key in ('open.liveFolders.introSeen', 'open.liveFolders.githubAutoCreate'):
                app.call('defaults', key=key, value=None)
            gh['prs'] = {'created': [('acme/app', 12, 'R7 fetched one', 'open'), ('acme/web', 7, 'R7 fetched two', 'open')],
                         'review': [], 'approved': [], 'changes': []}
            doomed = app.call('space-create', title='R7 Doomed')
            own = app.call('open', url=base + '/r7-own-tab')['id']; loaded(own, 'R7 own tab')
            app.call('sidebar-menu', item='Live Folders/GitHub')
            live = app.call('live-folder-state', wait=True)
            app.call('key', key='escape', route='app')
            fetched = [r['title'] for r in live.get('rows', [])]
            open_library('spaces'); time.sleep(.3)
            items = app.call('space-manager-menu', space=doomed, item='?')
            app.call('space-manager-menu', space=doomed, item=next(i for i in items if i.startswith('Delete')))
            alert = wait_until(lambda: _try(lambda: app.call('alert', window='library')), timeout=5, step=.05) or {}
            app.call('alert', window='library', button=next(b for b in alert.get('buttons', []) if b.startswith('Delete')))
            gone = wait_until(lambda: all(s['id'] != doomed for s in app.call('spaces')), timeout=5, step=.05)
            archived = wait_until(lambda: (lambda a: a if any(r['title'] == 'R7 own tab' for r in a['rows']) else None)(app.call('archive-list')),
                                  timeout=8, step=.1) or app.call('archive-list')
            titles = [r['title'] for r in archived['rows']]
            # Fetched rows are data, not the user's tabs (as Delete of the Live Folder itself); the own tab is archived.
            check('R7_W03_delete_space_skips_live_rows', len(fetched) == 2 and gone and 'R7 own tab' in titles
                  and not any(t.startswith('R7 fetched') for t in titles), fetched=fetched, archived=titles[:10])
        finally:
            gh_server.shutdown()

    def x04():
        for _ in range(3): app.call('menu-perform', id='new-easel')
        def shown():
            state = lib()
            easels = [r for r in state.get('rows', []) if r['kind'] == 'easel']
            return state if len(easels) >= 3 and all(r['iconLoaded'] for r in easels if r['realized']) else None
        open_library('easels')
        first = wait_until(shown, timeout=10, step=.1) or lib()
        time.sleep(.5)  # Prefetch slices are done.
        opened = lib().get('easelThumbnailRenders', 0)
        close_library(); open_library('easels')
        wait_until(shown, timeout=10, step=.1); time.sleep(.5)
        again = lib().get('easelThumbnailRenders', 0)
        # Each configure, prefetch and open read the document and drew the whole canvas again.
        check('R7_X04_easel_thumbnails_drawn_once', 3 <= opened <= 3 and again == opened,
              rendersFirstOpen=opened, rendersAfterReopen=again,
              rows=[{k: r.get(k) for k in ('title', 'realized', 'iconLoaded')} for r in first.get('rows', []) if r['kind'] == 'easel'])

    def x07():
        import downloads
        # Quit cancels a transfer the old build hid (no row left to cancel it from).
        app.call('download-policy', quit='close')
        with downloads.server() as dbase:
            profile = app.call('spaces')[0]['profile']
            folder = Path(tmp, 'r7-downloads'); folder.mkdir(parents=True, exist_ok=True)
            app.call('download-settings', profile=profile, directory=str(folder), ask=False)
            source = app.call('open', url=dbase + '/')['id']
            assert loaded(source, 'Downloads fixture'), 'download source page did not load'
            assert wait_until(lambda: app.eval(source, 'Boolean(document.body) && document.readyState === "complete"'), timeout=10, step=.05)
            app.eval(source, '(() => {let a=document.createElement("a"); a.href=%s; a.id="d"; a.textContent="d"; document.body.replaceChildren(a)})()'
                     % json.dumps(dbase + '/slow?name=r7-running.bin'))
            app.call('click', tab=source, selector='#d')
            open_library('downloads')
            row = wait_until(lambda: next((r for r in rows('download') if r['title'] == 'r7-running.bin'), None), timeout=10, step=.05)
            try:
                lib(action='row-select', id=row['id']); lib(action='focus-list')
                app.call('key', key='delete', modifiers=['cmd'], route='app')
                time.sleep(.5)
                still = next((r for r in rows('download') if r['id'] == row['id']), None)
                running = any(i['id'] == row['id'] and i.get('state') in ('inProgress', 'paused') for i in app.call('downloads-state')['items'])
                # Cmd+Delete ran "Hide from Open" on a running transfer: it kept writing, with no row left.
                check('R7_X07_cmd_delete_keeps_running_download', still is not None and running,
                      row=still and {k: still.get(k) for k in ('id', 'title', 'actions')}, running=running)
            finally:
                _try(lambda: lib(action='row-action', id=row['id'], name='Cancel'))

    rows_by_key = [
        ('X06', x06, ['R7_X06_archive_empty_has_no_dead_button']),
        ('X01', x01, ['R7_X01_refresh_keeps_selection_and_position']),
        ('X02', x02, ['R7_X02_history_search_words_any_order']),
        ('X03', x03, ['R7_X03_restore_status_not_stale_on_reopen']),
        ('W02', w02, ['R7_W02_new_space_closes_library', 'R7_W02_rename_space_with_library_asks']),
        ('W04', w04, ['R7_W04_space_menu_key_follows_binding']),
        ('W01', w01, ['R7_W01_edit_theme_switch_updates_window_menus']),
        ('W03', w03, ['R7_W03_delete_space_skips_live_rows']),
        ('X04', x04, ['R7_X04_easel_thumbnails_drawn_once']),
        ('X07', x07, ['R7_X07_cmd_delete_keeps_running_download']),
    ]
    try:
        for key, body, names in rows_by_key:
            if only and key not in only: continue
            try: body()
            except Exception as error:
                for name in names:
                    if name not in results: check(name, False, error='%s: %s' % (type(error).__name__, error))
            finally:
                # A sheet a failed row left open (rename, delete confirmation) is answered here.
                for window in (None, 'library'):
                    _try(lambda: app.call('alert', button='Cancel', **({'window': window} if window else {})))
                _try(lambda: app.call('editor-close')); close_library()
    finally:
        server.shutdown()
        app.quit()
