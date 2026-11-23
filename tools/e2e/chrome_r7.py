"""Bug sweep round 7, lane CHROME7: window chrome and drop targets, through the real App
automation socket (no desktop input).

Runs inside `engine_e2e.py --only page-chrome`; OPEN_CHROME7_ONLY=1 runs only these rows, and
OPEN_CHROME7_ROWS=a,b picks rows by name. Loopback pages only.
"""
import http.server
import json
import os
import threading
import time
import traceback
from pathlib import Path
from loopback_http import LoopbackHTTPServer


def run(factory, results, tmp, h):
    wait = h['wait_until']

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith('/slow'):
                time.sleep(4)
            body = ('<!doctype html><title>Chrome7 %s</title><body style="background:#fff;color:#222">'
                    '<p id=quote>A sentence on page %s for the quote link.</p>' % (self.path, self.path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    app = factory(urls=(origin + '/start',), fresh=True)
    rows = set(filter(None, os.environ.get('OPEN_CHROME7_ROWS', '').split(',')))

    def check(value, **evidence): return dict(ok=bool(value), **evidence)
    def page(path=None):
        tab = app.call('open', url=origin + (path or '/case?' + str(time.time_ns())))['id']
        app.call('wait', tab=tab); app.call('focus', tab=tab)
        return tab
    def ws(): return app.call('window-state')
    def ss(): return app.call('split', op='state')
    def settled(full, page_full):
        return wait(lambda: (lambda s: s if s['fullscreen'] == full and s['pageFullscreen'] == page_full
                             and not s['fullscreenTransition'] else None)(ws()), timeout=15, step=.1)
    def enter_page_fullscreen(target):
        result = app.eval(target, 'document.documentElement.requestFullscreen().then(() => "ok", e => e.message)')
        entered = settled(True, True)
        assert result == 'ok' and entered, {'request': result, 'state': ws()}
    def exit_page_fullscreen(target):
        app.eval(target, 'document.fullscreenElement ? document.exitFullscreen().then(() => "ok", e => e.message) : "none"')
        if not settled(False, False) and ws()['fullscreen']:
            app.call('window-fullscreen'); settled(False, False)
    def close_others(keep=()):
        for t in app.call('tabs'):
            if t['id'] not in keep and t.get('section') not in ('favorites', 'pinned'):
                h['_try'](lambda t=t: app.call('close', tab=t['id']))
    def gate(name, fn):
        if rows and name not in rows: return
        try:
            results[name] = fn()
        except h['FocusInterruption']:
            raise
        except Exception as error:
            results[name] = {'ok': False, 'error': str(error), 'trace': traceback.format_exc()[-900:]}
        finally:
            h['_try'](lambda: app.call('dismiss'))
        print(name + (' PASS' if results[name].get('ok') else ' FAIL'), flush=True)
        if not results[name].get('ok'): print(json.dumps(results[name], ensure_ascii=False), flush=True)

    # The rows write the system clipboard: keep its contents and put them back at the end.
    clipboard_saved = app.call('pasteboard-preserve')
    try:
        app.call('window-frame', frame=[80, 60, 1100, 760])

        def fullscreen_toolbar():
            # AB-01: HTML fullscreen used to keep the 32 pt content toolbar over the page's top edge
            # and the panel's rounded corners at the screen corners.
            app.call('command', id='toggle-toolbar')
            target = page()
            try:
                before = ws()['toolbar']
                enter_page_fullscreen(target)
                full_state, pane = ws(), ss()['panes'][0]
                container = ss()['container']
                exit_page_fullscreen(target)
                after = wait(lambda: (lambda s: s if s['toolbar']['drawn'] else None)(ws()), timeout=5, step=.1) or ws()
                pane_after = ss()['panes'][0]
            finally:
                app.call('command', id='toggle-toolbar')
            return check(before['drawn'] and not full_state['toolbar']['drawn'] and not pane['bar'] and pane['fullBleed']
                         and pane['pageFrame'][3] == container[3] and after['toolbar']['drawn'] and pane_after['bar']
                         and not pane_after['fullBleed'],
                         toolbarBefore=before['drawn'], toolbarInFullscreen=full_state['toolbar']['drawn'], pane=pane,
                         container=container, toolbarAfter=after['toolbar']['drawn'], paneAfter=pane_after)
        gate('chrome7_fullscreen_hides_toolbar', fullscreen_toolbar)

        def fullscreen_split():
            # AB-01: a fullscreen page in a Split pane used to fill only its pane, with the other
            # panes, their bars and the dividers laid out across the screen.
            first = page(); second = page()
            app.call('select', tab=first)
            app.call('sidebar-menu', node=second, item='Open in Split View')
            panes = wait(lambda: (lambda s: s if len(s['panes']) == 2 else None)(ss()), timeout=5, step=.1)
            assert panes, ss()
            try:
                enter_page_fullscreen(second)
                state = wait(lambda: (lambda s: s if s['pageFullscreenTab'] == second else None)(ss()), timeout=3, step=.05) or ss()
                shown = [p for p in state['panes'] if not p['hidden']]
                exit_page_fullscreen(second)
                after = wait(lambda: (lambda s: s if all(p['bar'] and not p['hidden'] for p in s['panes']) else None)(ss()), timeout=5, step=.1) or ss()
            finally:
                h['_try'](lambda: app.call('split', op='menu', item='Separate All Tabs'))
                close_others()
            full = shown[0] if len(shown) == 1 else {}
            return check(len(shown) == 1 and full.get('id') == second and not full.get('bar') and full.get('fullBleed')
                         and full.get('frame') == state['container'] and all(state['dividersHidden'])
                         and len(after['panes']) == 2 and all(p['bar'] and not p['hidden'] and not p['fullBleed'] for p in after['panes'])
                         and not any(after['dividersHidden']),
                         shown=shown, container=state['container'], dividersHidden=state['dividersHidden'],
                         after=[{k: p[k] for k in ('id', 'hidden', 'bar', 'fullBleed')} for p in after['panes']])
        gate('chrome7_fullscreen_split_pane_fills', fullscreen_split)

        def fullscreen_split_focus():
            # Review r2 #1 (lead ruling): focus moving to another pane while a Split pane is in HTML
            # fullscreen used to leave the focused pane hidden behind it. It now ends the fullscreen.
            first = page(); second = page()
            app.call('select', tab=first)
            app.call('sidebar-menu', node=second, item='Open in Split View')
            assert wait(lambda: len(ss()['panes']) == 2 or None, timeout=5, step=.1), ss()
            outcomes = {}
            try:
                # Next Split Pane (the command ⌃⇧N-style focus keys run).
                enter_page_fullscreen(second)
                app.call('command', id='next-split-pane')
                done = settled(False, False)
                state = ss()
                outcomes['nextPane'] = dict(exited=bool(done), focused=state['focused'],
                    hidden=[p['id'] for p in state['panes'] if p['hidden']], fullscreenTab=state['pageFullscreenTab'])
                # The other pane's page asks to be shown (the same activation path as its focus()).
                app.call('command', id='next-split-pane')
                assert wait(lambda: ss()['focused'] == second or None, timeout=3, step=.05), ss()
                enter_page_fullscreen(second)
                page_id = next(t['page']['identifier'] for t in app.call('tabs') if t['id'] == first)
                app.call('devtools', tab=page_id, method='Page.bringToFront')
                done = settled(False, False)
                state = ss()
                outcomes['activation'] = dict(exited=bool(done), focused=state['focused'],
                    hidden=[p['id'] for p in state['panes'] if p['hidden']], fullscreenTab=state['pageFullscreenTab'])
            finally:
                if ws()['fullscreen']: h['_try'](lambda: exit_page_fullscreen(second))
                h['_try'](lambda: app.call('split', op='menu', item='Separate All Tabs'))
                close_others()
            return check(all(o['exited'] and o['focused'] == first and not o['hidden'] and not o['fullscreenTab']
                             for o in outcomes.values()) and len(outcomes) == 2, outcomes=outcomes)
        gate('chrome7_fullscreen_split_focus_exits', fullscreen_split_focus)

        def quote_after_switch():
            # AB-04: the copy toast's "Copy Quote Link" button copied from the tab selected when it
            # was clicked (here B, with no selection: B's plain URL).
            first = page('/quote-a'); first_url = origin + '/quote-a'
            selected = h['page_select'](app, first, '#quote')
            app.call('menu-perform', id='copy-url')
            offered = wait(lambda: (lambda t: t if t and t.get('subtitle') else None)(h['page_newest_toast'](app, timeout=0.2)), timeout=2, step=.05)
            second = page('/quote-b')
            still = h['page_newest_toast'](app, timeout=0.5)
            acted = app.call('toast-action', index=0) if still and still.get('subtitle') else False
            board = wait(lambda: (lambda p: p if '#:~:text=' in p or '/quote-b' in p else None)(app.call('pasteboard')), timeout=3, step=.05)
            close_others()
            return check(bool(selected.strip()) and bool(offered) and bool(acted) and bool(board)
                         and board.startswith(first_url + '#:~:text='),
                         selected=selected, offered=offered, toastAfterSwitch=still, acted=acted, pasteboard=board, second=second)
        gate('chrome7_quote_toast_keeps_page', quote_after_switch)

        def share_follows_peek():
            # AB-03: with a Peek open, the URL field's Share ▸ shared the tab behind the Peek.
            source = page('/peek-source')
            peek_url = origin + '/peek-shown'
            app.call('peek-open', tab=source, url=peek_url)
            shown = wait(lambda: (lambda s: s if s['stack'] and s['stack'][-1].get('content') else None)(app.call('peek-state')), timeout=5, step=.05)
            assert shown, app.call('peek-state')
            text = wait(lambda: (lambda t: t if t and 'peek-source' not in t else None)(ws()['urlFieldText']), timeout=5, step=.05)
            listed = app.call('sidebar-menu-items', surface='url-field', path='Share')['items']
            services = [s.rstrip(' ▸') for s in listed if s != '—']
            assert services, listed
            app.call('sidebar-share', dismiss=True)
            try:
                app.call('sidebar-menu', surface='url-field', items=['Share', services[0]])
                shared = app.call('sidebar-share')
            finally:
                app.call('sidebar-share', dismiss=False)
                h['_try'](lambda: app.call('peek-close'))
                close_others()
            return check(shared.get('url') == peek_url and shared.get('node') == 'page',
                         shared=shared, service=services[0], urlFieldText=text)
        gate('chrome7_url_field_share_follows_peek', share_follows_peek)

        def note_copy():
            # AB-06: a Note's Copy URL copied its internal open://note/ route as "Copied Current URL";
            # the content toolbar named it "note" and copied the route too.
            before = {t['id'] for t in app.call('tabs')}
            app.call('menu-perform', id='new-note')
            note = wait(lambda: next((t for t in app.call('tabs') if t['id'] not in before and t['url'].startswith('open://note/')), None), timeout=5, step=.05)
            assert note, app.call('tabs')
            app.call('select', tab=note['id']); time.sleep(.3)
            app.call('pasteboard', text='sentinel')
            menu = app.call('menu-state')
            enabled = next((m['enabled'] for m in menu if m['id'] == 'copy-url'), None)
            share_enabled = next((m['enabled'] for m in menu if m['id'] == 'share-page'), None)
            try:
                app.call('menu-perform', id='copy-url'); refused = False
            except Exception as error:
                refused = 'disabled' in str(error)
            board = app.call('pasteboard')
            field = app.call('sidebar-menu-items', surface='url-field')
            app.call('command', id='toggle-toolbar')
            try:
                bar = wait(lambda: (lambda t: t if t['drawn'] else None)(ws()['toolbar']), timeout=3, step=.05) or ws()['toolbar']
            finally:
                app.call('command', id='toggle-toolbar')
            h['_try'](lambda: app.call('close', tab=note['id']))
            return check(enabled is False and share_enabled is False and refused and board == 'sentinel' and 'Copy URL' in field['disabled']
                         and 'Share' in field['disabled'] and bar['text'] == 'Note' and 'Copy Current URL' not in bar['controls'],
                         menuEnabled=enabled, shareEnabled=share_enabled, refused=refused, pasteboard=board, urlFieldMenu=field,
                         toolbarText=bar['text'], toolbarControls=bar['controls'])
        gate('chrome7_note_copy_refused', note_copy)

        def multi_drop():
            # AB-05: dropping several links on the list or Favorites opened only the first.
            close_others()
            tree = app.call('sidebar-tree')
            today_start = 1 + len(tree['pinned']) + (1 if tree['today'] else 0) + 1
            urls = [origin + '/drop-%d' % i for i in (1, 2, 3)]
            hosts_before = app.call('host-counts')
            accepted = app.call('sidebar-url-drop', urls=urls, index=today_start)
            today = [n.get('url') for n in app.call('sidebar-tree')['today']]
            time.sleep(1); hosts_after = app.call('host-counts')
            last = next((t['id'] for t in app.call('tabs') if t['url'] == urls[-1]), None)
            last_selected = bool(last) and app.call('tab-state', tab=last)['selected']
            app.call('menu-perform', id='undo')
            undone = [n.get('url') for n in app.call('sidebar-tree')['today']]
            favs = [origin + '/fav-%d' % i for i in (1, 2)]
            fav_accepted = app.call('sidebar-url-drop', urls=favs, index=0, favoritesIndex=0)
            fav_urls = [t['url'] for t in app.call('tabs') if t.get('section') == 'favorites']
            for t in app.call('tabs'):
                if t.get('section') == 'favorites' and '/fav-' in t['url']:
                    h['_try'](lambda t=t: app.call('sidebar-menu', node=t['id'], item='Remove from Favorites'))
            close_others()
            return check(accepted and today[:3] == urls and not any(u in undone for u in urls)
                         and hosts_after['created'] - hosts_before['created'] == 1 and last_selected
                         and fav_accepted and all(u in fav_urls for u in favs),
                         accepted=accepted, today=today, afterUndo=undone, favoritesAccepted=fav_accepted, favorites=fav_urls,
                         hostsBefore=hosts_before, hostsAfter=hosts_after, lastSelected=last_selected)
        gate('chrome7_multi_url_drop_opens_all', multi_drop)

        def manager_drop():
            # AB-05 review r1 #1: a multi-item drop on a Library Space Manager column selected, and so
            # loaded, every new tab.
            close_others(); page('/mgr-anchor')
            space = ws()['space']
            tree = app.call('sidebar-tree')
            # The Manager's outline has no New Tab row: with Today non-empty, Today starts right
            # after the Today divider (an empty Today maps this index to Pinned).
            start = 1 + len(tree['pinned']) + 1
            urls = [origin + '/mgr-%d' % i for i in (1, 2, 3)]
            app.call('library-open', section='spaces')
            try:
                hosts_before = app.call('host-counts')
                accepted = None
                deadline = time.time() + 10
                while accepted is None and time.time() < deadline:
                    try: accepted = app.call('sidebar-url-drop', manager=space, urls=urls, index=start)
                    except Exception as error:
                        if 'unavailable' not in str(error): raise
                        time.sleep(.2)
                time.sleep(1); hosts_after = app.call('host-counts')
            finally:
                h['_try'](lambda: app.call('library-close'))
            today = [n.get('url') for n in app.call('sidebar-tree')['today']]
            close_others()
            return check(accepted and today[:3] == urls and hosts_after['created'] - hosts_before['created'] <= 1,
                         accepted=accepted, today=today, hostsBefore=hosts_before, hostsAfter=hosts_after)
        gate('chrome7_manager_multi_drop_loads_one', manager_drop)

        def rebound_tooltips():
            # AB-07: the sidebar toolbar tooltips and the compact More options rows showed the
            # default keys after a rebind, and "Stop loading" showed Reload's ⌘R.
            bindings = Path(app.user_data, 'State/keybindings.json')
            bindings.parent.mkdir(parents=True, exist_ok=True)
            bindings.write_text(json.dumps({'version': 1, 'bindings': {
                'toggle-sidebar': {'shortcuts': [{'key': 's', 'modifiers': ['command', 'option']}]},
                'go-back': {'shortcuts': [{'key': 'b', 'modifiers': ['command', 'control']}]}}}))
            try:
                app.call('reload-keybindings'); time.sleep(.2)
                # The file loaded (a rejected file silently keeps the defaults).
                bound = next((m for m in app.call('menu-state') if m['id'] == 'toggle-sidebar'), {})
                assert bound.get('key') == 's' and bound.get('modifierMask', 0) & (1 << 19), bound
                state = ws()
                tips, more = state['toolbarTooltips'], state['toolbarMoreRows']
                slow = app.call('open', url=origin + '/slow?' + str(time.time_ns()))['id']
                loading = wait(lambda: (lambda t: t if t.get('reload', [''])[0] == 'Stop loading' else None)(ws()['toolbarTooltips']), timeout=3, step=.05) or ws()['toolbarTooltips']
            finally:
                bindings.unlink(missing_ok=True); app.call('reload-keybindings')
                close_others()
            return check(tips.get('toggle') == ['Hide sidebar', '⌥', '⌘', 'S'] and tips.get('back') == ['Go back', '⌃', '⌘', 'B']
                         and ['Toggle Sidebar', '⌥⌘S'] in more and loading.get('reload') == ['Stop loading', '⌘', '.'],
                         tooltips=tips, moreRows=more, whileLoading=loading.get('reload'))
        gate('chrome7_tooltips_follow_rebind', rebound_tooltips)
    finally:
        if clipboard_saved: h['_try'](lambda: app.call('pasteboard-restore'))
        h['_try'](lambda: app.quit())
        server.shutdown()
