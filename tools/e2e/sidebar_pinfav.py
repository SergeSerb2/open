"""Pinned tabs and Favorites: every close path through the real App (lane PINFAV, 2026-11-17).

Real input only through the automation socket: `hover` and `mouse` deliver own-window NSEvents
through AppKit hit testing (no system events), `key` sends a real Cmd-W key event. Synthetic
profile, data: and loopback pages only.
"""
import http.server
import threading
import time

from loopback_http import LoopbackHTTPServer


def run(factory, results, tmp, harness):
    wait_until, new_tab, fixture = harness['wait_until'], harness['new_tab'], harness['fixture']

    class Slow(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith('/slow'):
                time.sleep(3)
            body = ('<title>Slow %s</title><h1>%s</h1>' % (self.path, self.path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass

        def log_message(self, *a): pass

    server = LoopbackHTTPServer(Slow)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]
    app = factory(urls=(), fresh=True)
    try:
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)

        def tab(t): return app.tab(t)
        def ids(): return [t['id'] for t in app.call('tabs')]
        def selected(): return app.call('window-state')['selected']

        def accessory(t, favorite=False):
            return app.call('sidebar-accessory', **({'favorite': t} if favorite else {'node': t}))

        def hover(t, favorite=False):
            app.call('hover', **({'favorite': t} if favorite else {'node': t}))
            return wait_until(lambda: (lambda a: a if a.get('shown') or a.get('tileHovered') else None)(accessory(t, favorite)), timeout=2, step=.02) or accessory(t, favorite)

        def click_at(point):
            app.call('mouse', action='click', x=point[0], y=point[1], queued=True)

        def click_accessory(t, favorite=False):
            """Hover the row like a pointer would, then click its real button. Returns the glyph clicked."""
            shown = hover(t, favorite)
            if not shown.get('shown'):
                return {'clicked': False, 'accessory': shown}
            click_at(shown['point'])
            return {'clicked': True, 'glyph': shown['glyph'], 'point': shown['point']}

        def settle(t, timeout=2):
            # The App finishes a close asynchronously at most one run-loop turn later.
            end = time.monotonic() + timeout
            last = None
            while time.monotonic() < end:
                last = tab(t) if t in ids() else None
                time.sleep(.05)
            return last

        def record(name, ok, **evidence):
            results[name] = dict(ok=bool(ok), **evidence)

        def archived(t): return any(r['id'] == t for r in app.call('archive'))

        # --- fixtures: three pinned tabs, two Today tabs, one Favorite -----------------------
        p1 = new_tab(app, fixture('PF Pinned One')); app.call('pin', tab=p1)
        p2 = new_tab(app, fixture('PF Pinned Two')); app.call('pin', tab=p2)
        p3 = app.call('open', url=fixture('PF Pinned Never Loaded'), background=True)['id']; app.call('pin', tab=p3)
        t1 = new_tab(app, fixture('PF Today One'))
        t2 = new_tab(app, fixture('PF Today Two'))
        f1 = new_tab(app, fixture('PF Favorite One')); app.call('favorite', tab=f1)
        app.call('select', tab=t2)

        # PF1 (Arc P1): an unselected pinned row shows "×" even while its page is loaded, and "×"
        # archives the pinned tab. The selection does not move.
        before = tab(p1)
        clicked = click_accessory(p1)
        after = settle(p1)
        record('PF1_unselected_loaded_pinned_x_archives', before['hasWebContent'] and clicked.get('glyph') == 'rowClose'
               and after is None and archived(p1) and selected() == t2 and p1 not in app.call('window-state')['shownPages'],
               before={k: before[k] for k in ('hasWebContent', 'loaded')}, clicked=clicked, after=after, selected=selected())

        # PF2 (Arc P1): the same for a pinned row that never loaded (every pinned row after a relaunch).
        clicked2 = click_accessory(p3)
        after2 = settle(p3)
        record('PF2_unloaded_pinned_x_archives', clicked2.get('glyph') == 'rowClose' and after2 is None and archived(p3)
               and selected() == t2, clicked=clicked2, after=after2)

        # PF2b (Arc P2, P5): the selected pinned row shows "−"; it unloads in place and the
        # previously selected tab comes back.
        app.call('select', tab=t1); app.call('select', tab=p2); wait_until(lambda: tab(p2)['hasWebContent'], timeout=5, step=.05)
        clicked2b = click_accessory(p2)
        after2b = settle(p2)
        record('PF2b_selected_pinned_minus_unloads_back_to_previous', clicked2b.get('glyph') == 'rowUnload' and after2b
               and after2b['section'] == 'pinned' and not after2b['hasWebContent'] and selected() == t1,
               clicked=clicked2b, after=after2b, selected=selected(), expected=t1)

        # PF3 (Arc F2): a hovered Favorite tile shows no close or unload button, loaded or not,
        # selected or not; it shows its hover fill.
        app.call('select', tab=f1); wait_until(lambda: tab(f1)['hasWebContent'], timeout=5, step=.05)
        on_selected = hover(f1, favorite=True)
        app.call('select', tab=t2)
        on_loaded = hover(f1, favorite=True)
        app.call('sidebar-unload', tab=f1); wait_until(lambda: not tab(f1)['hasWebContent'], timeout=5, step=.05)
        on_unloaded = hover(f1, favorite=True)
        states = [on_selected, on_loaded, on_unloaded]
        record('PF3_favorite_hover_has_no_button', all(not x.get('shown') and x.get('tileHovered') is True for x in states), states=states)

        # PF5 (Arc P3, P5): Cmd-W on the selected pinned tab keeps the row, unloads it, and selects
        # the tab selected before it (here t2), not a strip neighbour.
        app.call('select', tab=t2); app.call('select', tab=p2); wait_until(lambda: tab(p2)['hasWebContent'], timeout=5, step=.05)
        order = ids()
        app.call('key', key='w', modifiers=['command'])
        after5 = settle(p2)
        record('PF5_cmdw_pinned_unloads_back_to_previous', after5 and after5['section'] == 'pinned' and not after5['hasWebContent']
               and selected() == t2, after=after5, selected_after=selected(), expected=t2, order=order)

        # PF6 (Arc F3): Cmd-W on the selected Favorite keeps the tile, unloads it, and selects the tab
        # selected before it.
        app.call('select', tab=t1); app.call('select', tab=f1); wait_until(lambda: tab(f1)['hasWebContent'], timeout=5, step=.05)
        app.call('key', key='w', modifiers=['command'])
        after6 = settle(f1)
        record('PF6_cmdw_favorite_unloads_back_to_previous', after6 and after6['section'] == 'favorites' and not after6['hasWebContent']
               and selected() == t1, after=after6, selected_after=selected(), expected=t1)

        # PF6b (Arc F4): Cmd-W on a Favorite that left its saved URL puts it back on that URL and title.
        app.call('select', tab=f1); wait_until(lambda: tab(f1)['hasWebContent'], timeout=5, step=.05)
        app.call('navigate', tab=f1, url=fixture('PF Favorite Away'))
        wait_until(lambda: (lambda t: t if 'PF%20Favorite%20Away' in t['url'] and t['title'] == 'PF Favorite Away' else None)(tab(f1)), timeout=5, step=.05)
        app.call('key', key='w', modifiers=['command'])
        after6b = settle(f1)
        record('PF6b_cmdw_navigated_favorite_returns_to_saved_url', after6b and after6b['section'] == 'favorites'
               and not after6b['hasWebContent'] and after6b['url'] == after6b['pinnedURL'] and after6b['title'] == 'PF Favorite One',
               after=after6b)
        app.call('select', tab=t2)

        # PF7: quick repeated "×" on two unselected pinned rows at one point: the lower row slides up
        # under the still pointer, shows its "×" at once, and the second click archives it too.
        q2 = new_tab(app, fixture('PF Pinned Quick Lower')); app.call('pin', tab=q2)
        q1 = new_tab(app, fixture('PF Pinned Quick Upper')); app.call('pin', tab=q1)
        app.call('sidebar-move', tab=q1, section='pinned', index=0); app.call('sidebar-move', tab=q2, section='pinned', index=1)
        app.call('select', tab=t2)
        first7 = click_accessory(q1)
        gone7 = wait_until(lambda: q1 not in ids() or None, timeout=2, step=.02)
        under7 = accessory(q2)
        if under7.get('shown') and under7['point'] == first7.get('point'):
            click_at(under7['point'])
        closed7 = wait_until(lambda: q2 not in ids() or None, timeout=2, step=.02)
        record('PF7_quick_repeated_pinned_x', first7.get('glyph') == 'rowClose' and gone7 and closed7
               and archived(q1) and archived(q2) and selected() == t2, first=first7, under=under7, selected=selected())

        # PF8: close a pinned tab while it loads (3 s server delay): it unloads at once and stays unloaded.
        slow = app.call('open', url=base + '/slow-pin')['id']
        app.call('pin', tab=slow)
        time.sleep(.3)
        loading = tab(slow)
        app.call('select', tab=slow)
        app.call('key', key='w', modifiers=['command'])
        early = settle(slow, 1)
        late = settle(slow, 4)
        record('PF8_close_loading_pinned_stays_unloaded', early and late and late['section'] == 'pinned' and not late['hasWebContent']
               and not late['loading'] and not late['loaded'], loading=loading, early=early, late=late)

        # PF9: close right after a drop: t1 moves into Pinned through the real drop handler, and its
        # "×" (an unselected pinned row) archives it at once.
        space = next(x for x in app.call('spaces') if x['focused'])['id']
        app.call('select', tab=t2)
        dropped = app.call('sidebar-drop', nodes=[t1], parent={'kind': 'pinned', 'id': space}, index=0)
        clicked9 = click_accessory(t1)
        after9 = settle(t1)
        record('PF9_close_right_after_drop', dropped and clicked9.get('glyph') == 'rowClose' and after9 is None and archived(t1),
               dropped=dropped, clicked=clicked9, after=after9)

        # PF10 (Arc P4): Cmd-W on a pinned tab that left its pinned URL puts the row back on the pinned
        # URL and title, unloaded; selecting it again loads the pinned page.
        app.call('select', tab=p2); wait_until(lambda: tab(p2)['hasWebContent'], timeout=5, step=.05)
        app.call('navigate', tab=p2, url=fixture('PF Away'))
        away = wait_until(lambda: (lambda t: t if 'PF Away' in t['url'] and t['title'] == 'PF Away' else None)(tab(p2)), timeout=5, step=.05) or tab(p2)
        app.call('key', key='w', modifiers=['command'])
        after10 = settle(p2)
        app.call('select', tab=p2)
        reloaded = wait_until(lambda: (lambda t: t if t['hasWebContent'] and not t['loading'] and t['title'] == 'PF Pinned Two' else None)(tab(p2)), timeout=5, step=.05)
        record('PF10_cmdw_navigated_pinned_returns_to_pinned_url', after10 and after10['section'] == 'pinned' and not after10['hasWebContent']
               and after10['url'] == after10['pinnedURL'] and after10['title'] == 'PF Pinned Two' and bool(reloaded)
               and reloaded['url'] == after10['pinnedURL'],
               away={k: away[k] for k in ('url', 'title')}, after=after10, reloaded=reloaded)
        app.call('select', tab=t2)

        # PF11: quick repeated "×" at one point: the row that slides up under the still pointer
        # shows its button at once, so the second click closes it instead of selecting it.
        lower = new_tab(app, fixture('PF Quick Lower')); upper = new_tab(app, fixture('PF Quick Upper'))
        app.call('select', tab=t2)
        first = click_accessory(upper)
        gone = wait_until(lambda: upper not in ids() or None, timeout=2, step=.02)
        under = accessory(lower)
        if under.get('shown') and under['point'] == first.get('point'):
            click_at(under['point'])
        closed = wait_until(lambda: lower not in ids() or None, timeout=2, step=.02)
        record('PF11_quick_repeated_x_closes_next_row', first.get('glyph') == 'rowClose' and gone and closed and selected() == t2,
               first=first, under=under, closed_second=bool(closed), selected=selected())
        # PF12: a Favorite leaves the grid under a still pointer; the tile that moves into its place
        # is the hovered one (its button shows), and no other tile keeps a stale hover.
        fa = new_tab(app, fixture('PF Grid A')); app.call('favorite', tab=fa)
        fb = new_tab(app, fixture('PF Grid B')); app.call('favorite', tab=fb)
        # Six tiles before and five after both lay out in three columns (balanced rows), so B takes
        # A's cell and the pointer stays inside a tile.
        while sum(t['section'] == 'favorites' for t in app.call('tabs')) < 6:
            app.call('favorite', tab=new_tab(app, fixture('PF Grid Extra')))
        app.call('select', tab=t2)
        grid = [t['id'] for t in app.call('tabs') if t['section'] == 'favorites']
        held = hover(fa, favorite=True)
        app.call('sidebar-move', tab=fa, section='today', index=0)
        moved = wait_until(lambda: tab(fa)['section'] == 'today' or None, timeout=2, step=.02)
        time.sleep(.4)
        next_tile = accessory(fb, favorite=True)
        others = {t: accessory(t, favorite=True).get('tileHovered') for t in grid if t not in (fa, fb) and t in ids()}
        record('PF12_favorite_grid_hover_follows_pointer', held.get('tileHovered') is True and moved and next_tile.get('tileHovered') is True
               and not any(others.values()), grid=grid, held=held, next_tile=next_tile, others=others)
        # PF13 (Arc P5): with no earlier selection in this Space, Cmd-W on a pinned tab shows no tab;
        # it does not select a tab that was opened in the background and never shown.
        home = next(x for x in app.call('spaces') if x['focused'])['id']
        other = app.call('space-create', title='PF Empty History')
        app.call('space', space=other)
        background = app.call('open', url=fixture('PF Never Shown'), background=True)['id']
        pz = new_tab(app, fixture('PF Pinned Alone')); app.call('pin', tab=pz)
        app.call('key', key='w', modifiers=['command'])
        after13 = settle(pz)
        record('PF13_cmdw_pinned_without_history_selects_none', after13 and after13['section'] == 'pinned' and not after13['hasWebContent']
               and not selected() and not tab(background)['hasWebContent'], after=after13, selected=selected(),
               shown=app.call('window-state')['shownPages'])
        app.call('space', space=home)

        # PF14 (Arc c5): two quick Cmd-W: the first unloads the pinned tab and returns to the previous
        # Today tab, the second archives that Today tab.
        tx = new_tab(app, fixture('PF Double Today'))
        pd = new_tab(app, fixture('PF Double Pinned')); app.call('pin', tab=pd)
        # A newer Today tab sits first in Today, so the strip neighbour of pd is ty, not tx.
        ty = new_tab(app, fixture('PF Double Neighbour'))
        app.call('select', tab=tx); app.call('select', tab=pd); wait_until(lambda: tab(pd)['hasWebContent'], timeout=5, step=.05)
        app.call('key', key='w', modifiers=['command']); app.call('key', key='w', modifiers=['command'])
        after14 = settle(pd)
        record('PF14_double_cmdw_pinned_then_previous', after14 and after14['section'] == 'pinned' and not after14['hasWebContent']
               and tx not in ids() and archived(tx) and ty in ids(), after=after14, selected=selected())

        # PF15 (Arc P4, P5 after a relaunch): the selection restored at launch is the tab Cmd-W returns
        # to, and a pinned tab restored away from its pinned URL gets a title on reset (never blank).
        pr = app.call('open', url=base + '/pin-restore')['id']; app.call('wait', tab=pr); app.call('pin', tab=pr)
        app.call('navigate', tab=pr, url=base + '/away-restore')
        wait_until(lambda: tab(pr)['url'].endswith('/away-restore') or None, timeout=5, step=.05)
        tr = new_tab(app, fixture('PF Restored Today'))
        app.call('select', tab=tr); app.call('save')
        app.quit()
        app = factory(urls=(), fresh=False)
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        restored = selected()
        app.call('select', tab=pr); wait_until(lambda: tab(pr)['hasWebContent'] and not tab(pr)['loading'], timeout=8, step=.05)
        away15 = tab(pr)
        app.call('key', key='w', modifiers=['command'])
        after15 = settle(pr)
        record('PF15_relaunch_restored_selection_and_title', restored == tr and selected() == tr and after15
               and after15['url'] == after15['pinnedURL'] and after15['title'] == '127.0.0.1' and not after15['hasWebContent'],
               restored=restored, away={k: away15[k] for k in ('url', 'title')}, after=after15, selected=selected())
    finally:
        server.shutdown()
        app.quit()
