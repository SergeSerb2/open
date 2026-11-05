"""Real App Step H history flow, loaded by engine_e2e.py's history suite."""
import http.server
import json
import os
import sqlite3
import statistics
import threading
import time


def history_checks(factory, results, tmp, wait_until, restore_defaults):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/redirect':
                self.send_response(302); self.send_header('Location', '/final'); self.end_headers(); return
            title = 'HistoryNeedle' if self.path == '/link' else 'History ' + self.path
            body = (f'<!doctype html><title>{title}</title><body><h1>{title}</h1>'
                    '<a id="link" href="/link">Link</a><a id="redirect" href="/redirect">Redirect</a>'
                    '<button id="popup" onclick="window.open(\'/popup\',\'historyPopup\',\'width=600,height=400\')">Popup</button>'
                    '<iframe src="/subframe"></iframe></body>').encode() if self.path != '/subframe' else b'<title>Subframe</title>'
            self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]
    app = None; saved = {}
    keys = ['open.library.lastSection', 'open.settings.lastPane', 'open.settings.selectedProfileID',
            'open.search.hasSeenSuggestionsNotice', 'open.links.littleOpenHotkeyEnabled']
    def check(name, ok, **evidence): results[name] = dict(ok=bool(ok), **evidence)
    def history(profile=None): return app.call('history-state', **({'profile': profile} if profile else {}))
    def dbrows(profile=None):
        state = history(profile)
        with sqlite3.connect(state['file']) as db:
            return [dict(url=u, title=t, visits=n, typed=k, transition=x) for u, t, n, k, x in db.execute(
                'SELECT u.url,u.title,u.visit_count,u.typed_count,v.transition FROM urls u JOIN visits v ON v.url_id=u.id ORDER BY v.id')]
    def page(path):
        rows = dbrows()
        return [r for r in rows if r['url'] == base + path]
    def loaded(tab, path):
        app.call('wait', tab=tab)
        committed = wait_until(lambda: app.eval(tab, 'location.pathname') == path, timeout=5, step=.05)
        app.call('wait', tab=tab)
        return committed
    def settle():
        # One explicit socket barrier drains the accepted writer and deferred title tasks.
        return history()
    def bar(query):
        app.call('key', key='t', modifiers=['cmd'], route='app')
        opened = wait_until(lambda: app.call('commandbar-state').get('presented'), timeout=3, step=.05)
        if not opened: return {}
        if query: app.call('key', text=query)
        return wait_until(lambda: (lambda s: s if s.get('final') and s.get('text') == query else None)(app.call('commandbar-state')),
                          timeout=5, step=.05) or {}
    def dismiss_bar(): app.call('key', key='escape', route='app')
    def typed_open(path):
        state = bar(base + path)
        app.call('key', key='return', route='app')
        tab = wait_until(lambda: next((t['id'] for t in app.call('tabs') if t['url'] == base + path), None), timeout=5, step=.05)
        if tab: loaded(tab, path)
        return tab
    def history_hits(state):
        return [r for r in state.get('rows', []) if r.get('url') == base + '/link' and r.get('kind') == 'history']
    try:
        app = factory(urls=(base + '/start',), fresh=True)
        saved = {key: app.call('defaults', key=key) for key in keys}
        for key in keys: app.call('defaults', key=key, value=None)
        app.call('defaults', key='open.search.hasSeenSuggestionsNotice', value=True)
        app.call('suggest-remote', enabled=False)
        tab = app.call('tabs')[0]['id']; loaded(tab, '/start'); settle()
        profile1 = history()['profile']
        app.call('click', tab=tab, selector='#link'); loaded(tab, '/link'); settle()
        link = page('/link')
        check('history_link_commit', len(link) == 1 and link[0]['transition'] == 'link' and link[0]['typed'] == 0, rows=link)
        baseline = len(dbrows()); app.call('command', id='reload'); loaded(tab, '/link'); settle()
        reloaded = page('/link')
        check('history_reload_no_visit', len(link) == len(reloaded) == 1 and len(dbrows()) == baseline, rows=reloaded)
        app.call('events')
        app.call('back', tab=tab); back_loaded = loaded(tab, '/start'); settle()
        back = page('/start')
        app.call('command', id='go-forward'); forward_loaded = loaded(tab, '/link'); settle()
        check('history_back_forward_guess', len(back) == 2 and len(page('/link')) == 2, back=back, forward=page('/link'), backLoaded=bool(back_loaded), forwardLoaded=bool(forward_loaded),
              page=app.page(tab), events=app.call('events'), guess=True)
        app.call('click', tab=tab, selector='#redirect'); loaded(tab, '/final'); settle()
        final = page('/final')
        check('history_redirect_final_once', len(final) == 1 and final[0]['transition'] == 'link' and not page('/redirect'), rows=final)
        before_title = len(dbrows()); writes_before = history()['writes']
        app.eval(tab, "document.title='old';document.title='middle';document.title='History updated title';true")
        wait_until(lambda: app.eval(tab, 'document.title') == 'History updated title', timeout=3, step=.05)
        settle(); updated = page('/final'); writes = history()['writes'] - writes_before
        check('history_title_updates_one_row', len(updated) == 1 and updated[0]['title'] == 'History updated title'
              and len(dbrows()) == before_title and writes == 1, rows=updated, titleWrites=writes)
        app.call('click', tab=tab, selector='#popup')
        popup = wait_until(lambda: next((p for p in app.call('pages') if p.get('kind') == 'popup' and p.get('url') == base + '/popup'), None), timeout=5, step=.05)
        popup_rows = wait_until(lambda: page('/popup'), timeout=3, step=.05)
        check('history_popup_profile', bool(popup) and bool(popup_rows) and popup_rows[0]['transition'] == 'link', rows=popup_rows)
        if popup:
            try: app.eval(popup['identifier'], 'window.close();true')
            except RuntimeError: pass  # The close may destroy its execution context before replying.
            wait_until(lambda: not any(p.get('kind') == 'popup' for p in app.call('pages')), timeout=3, step=.05)
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        before_same = len(dbrows())
        app.eval(tab, "history.pushState({}, '', '/same-document');true")
        settle(); same = page('/same-document')
        check('history_same_document', len(same) == 1 and same[0]['transition'] == 'link' and len(dbrows()) == before_same + 1, rows=same)
        typed = typed_open('/typed'); settle(); typed_rows = page('/typed')
        check('history_typed_commit', bool(typed) and len(typed_rows) == 1 and typed_rows[0]['transition'] == 'typed'
              and typed_rows[0]['typed'] == 1, rows=typed_rows)
        check('history_main_frame_only', bool(link) and not page('/subframe'), rows=page('/subframe'))
        # Library stays open while a new visit arrives. This state command does not reload it.
        app.call('key', key='y', modifiers=['cmd'], route='app')
        wait_until(lambda: app.call('settings-state').get('librarySection') == 'history', timeout=3, step=.05)
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        app.call('navigate', tab=typed or tab, url=base + '/live'); loaded(typed or tab, '/live'); settle()
        live = wait_until(lambda: (lambda s: s if any(r['url'] == base + '/live' for r in s['rows']) else None)(app.call('library-history-state')),
                          timeout=3, step=.05)
        check('history_library_live_cmd_y', bool(live) and bool(page('/live')), state=live)
        # Close the only tab that visited /link: query must find History, not an open tab.
        app.call('close', tab=tab)
        found = bar('HistoryNeedle'); hit = history_hits(found)
        check('history_commandbar_link_source', bool(link) and bool(hit), state=found); dismiss_bar()
        empty = bar(''); check('history_empty_cmd_t_no_history', bool(hit) and not any(r.get('kind') == 'history' for r in empty.get('rows', [])), state=empty); dismiss_bar()
        # A second Profile/Space must own a different on-disk HistoryStore.
        space2 = app.call('space-create', profile='History Second', title='History Second')
        profile2 = history()['profile']
        app.call('library-history-state', profile=profile2, selectProfile=True)
        second = app.call('open', url=base + '/second'); second = second['id'] if isinstance(second, dict) else second
        loaded(second, '/second'); state2 = settle(); profile2 = state2['profile']
        wait_until(lambda: any(r['url'] == base + '/second' for r in app.call('library-history-state')['rows']), timeout=3, step=.05)
        app.call('navigate', tab=second, url=base + '/second-live'); loaded(second, '/second-live'); settle()
        late_profile_live = wait_until(lambda: any(r['url'] == base + '/second-live' for r in app.call('library-history-state')['rows']), timeout=3, step=.05)
        check('history_library_new_profile_live', bool(late_profile_live) and bool(page('/second-live')))
        rows1, rows2 = dbrows(profile1), dbrows(profile2)
        check('history_profile_isolation', profile1 != profile2 and any(r['url'] == base + '/second' for r in rows2)
              and not any(r['url'] == base + '/second' for r in rows1) and not any(r['url'] == base + '/link' for r in rows2),
              profile1Count=len(rows1), profile2Count=len(rows2), file1=history(profile1)['file'], file2=state2['file'])
        app.quit(); app = factory(urls=()); app.call('suggest-remote', enabled=False)
        for key in keys: app.call('defaults', key=key, value=None)
        app.call('defaults', key='open.search.hasSeenSuggestionsNotice', value=True)
        persisted = dbrows(profile1)
        check('history_relaunch_persists', bool(link) and any(r['url'] == base + '/link' for r in persisted)
              and any(r['url'] == base + '/second' for r in dbrows(profile2)), rows= len(persisted))
        # Use Profile Settings' adapter. The second Profile must survive.
        cleared = app.call('history-clear', profile=profile1)
        remaining = dbrows(profile1)
        check('history_settings_clear_profile', bool(hit) and cleared['error'] == '' and not remaining
              and bool(dbrows(profile2)), error=cleared['error'], rows=remaining)
        app.call('space', space=next(s['id'] for s in app.call('spaces') if s['profile'] == profile1))
        after_clear = bar('HistoryNeedle')
        check('history_clear_removes_suggestions', bool(hit) and not history_hits(after_clear), state=after_clear); dismiss_bar()
        app.call('key', key='y', modifiers=['cmd'], route='app')
        app.call('library-history-state', profile=profile2, selectProfile=True)
        untouched_first = dbrows(profile1)
        deleted = app.call('library-history-delete', urls=[base + '/second', base + '/second-live'])
        check('history_library_delete_profile', bool(rows2) and not dbrows(profile2) and dbrows(profile1) == untouched_first, status=deleted)
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        # Fifty real document commits. Time only the synchronous callback -> enqueue path.
        sample_tab = app.call('tabs')[0]['id']
        for n in range(55):
            app.call('navigate', tab=sample_tab, url=base + '/sample-%d' % n); loaded(sample_tab, '/sample-%d' % n)
        state = settle(); samples = state['enqueueMilliseconds'][-50:]
        p95 = sorted(samples)[int(.95 * (len(samples) - 1))] if samples else None
        check('history_enqueue_cost', len(samples) >= 50 and p95 < 1.0, n=len(samples), p95Ms=p95,
              loadAverage=list(os.getloadavg()), scope='main-frame commit handler entry through enqueue; no disk IO')
        # Same-URL commits and time ranges use real visits; only their wall-clock
        # timestamps are backdated in this run's private SQLite fixture.
        for index, (label, seconds) in enumerate([('Last hour', 3600), ('Last 24 hours', 86400), ('Last 7 days', 604800)]):
            ranged = typed_open('/range-%d' % index)
            if ranged:
                app.call('navigate', tab=ranged, url=base + '/range-%d' % index); loaded(ranged, '/range-%d' % index)
            state = settle(); url = base + '/range-%d' % index
            before_range = [r for r in dbrows() if r['url'] == url]
            with sqlite3.connect(state['file']) as db:
                db.execute('UPDATE visits SET time=? WHERE id=(SELECT MIN(v.id) FROM visits v JOIN urls u ON u.id=v.url_id WHERE u.url=?)', (time.time() - 2 * seconds, url))
            response = app.call('history-clear', range=label)
            after_range = [r for r in dbrows() if r['url'] == url]
            check('history_range_%d' % index, len(before_range) == 2 and len(after_range) == 1
                  and after_range[0]['visits'] == 1 and after_range[0]['typed'] == 1 and response['error'] == '',
                  range=label, before=before_range, after=after_range, error=response['error'])
            sample_tab = ranged or sample_tab
        # Peek has a normal Profile HistoryStore even though it is not a sidebar tab (guess).
        app.call('peek-open', tab=sample_tab, url=base + '/peek')
        peek = wait_until(lambda: page('/peek'), timeout=5, step=.05)
        check('history_peek_profile_guess', bool(link) and bool(peek) and peek[0]['transition'] == 'link', rows=peek, guess=True)
        app.call('peek-close')
        internal_before = len(dbrows())
        app.call('navigate', tab=sample_tab, url='data:text/html,<title>Internal history exclusion</title>')
        app.call('wait', tab=sample_tab); settle()
        check('history_internal_excluded', bool(link) and len(dbrows()) == internal_before
              and all(not r['url'].startswith(('data:', 'about:', 'chrome:', 'devtools:', 'file:')) for r in dbrows()), count=len(dbrows()))
        before_idle = history(); time.sleep(2); after_idle = history()
        check('history_idle_no_work', before_idle['writes'] > 0 and before_idle['writes'] == after_idle['writes']
              and len(before_idle['enqueueMilliseconds']) == len(after_idle['enqueueMilliseconds']),
              before=before_idle['writes'], after=after_idle['writes'], seconds=2, loadAverage=list(os.getloadavg()),
              scope='history writer and callback counters; features-idle separately checks native idle resources')
        app.call('library-history-state', profile=profile1, selectProfile=True)
        before_all = dbrows(profile1); app.call('library-history-delete', all=True)
        check('history_library_clear_all', bool(before_all) and not dbrows(profile1), beforeCount=len(before_all))
    finally:
        if app:
            restore_defaults(app, saved)
            app.quit()
        server.shutdown(); server.server_close(); worker.join(timeout=3)
