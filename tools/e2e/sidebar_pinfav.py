"""Pinned tabs and Favorites: every close path through the real App (lane PINFAV, 2026-11-17).

Real input only through the automation socket: `hover` and `mouse` deliver own-window NSEvents
through AppKit hit testing (no system events), `key` sends a real Cmd-W key event. Synthetic
profile, data: and loopback pages only.
"""
import http.server
import threading
import time


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

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Slow)
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
            return wait_until(lambda: (lambda a: a if a.get('shown') else None)(accessory(t, favorite)), timeout=2, step=.02) or accessory(t, favorite)

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

        # --- fixtures: two pinned tabs, two Today tabs, one Favorite -------------------------
        p1 = new_tab(app, fixture('PF Pinned One')); app.call('pin', tab=p1)
        p2 = new_tab(app, fixture('PF Pinned Two')); app.call('pin', tab=p2)
        t1 = new_tab(app, fixture('PF Today One'))
        t2 = new_tab(app, fixture('PF Today Two'))
        f1 = new_tab(app, fixture('PF Favorite One')); app.call('favorite', tab=f1)
        app.call('select', tab=t2)

        # PF1: hover a loaded, unselected pinned row; its "−" unloads and keeps the row.
        before = tab(p1)
        clicked = click_accessory(p1)
        after = settle(p1)
        record('PF1_pinned_minus_unloads', clicked.get('glyph') == 'rowUnload' and after and after['section'] == 'pinned'
               and not after['hasWebContent'] and selected() == t2,
               before={k: before[k] for k in ('hasWebContent', 'loaded')}, clicked=clicked, after=after, selected=selected())

        # PF2: the pointer has not moved; the same button now shows "×" for an unloaded pinned row.
        again = accessory(p1)
        clicked2 = {'clicked': False}
        if again.get('shown'):
            click_at(again['point']); clicked2 = {'clicked': True, 'glyph': again['glyph']}
        after2 = settle(p1)
        record('PF2_pinned_x_on_unloaded_acts', clicked2.get('clicked') and (after2 is None or after2['section'] != 'pinned'),
               accessory=again, clicked=clicked2, after=after2, observe=True)

        # PF3: Favorite tile "−" unloads and keeps the tile.
        app.call('select', tab=f1); wait_until(lambda: tab(f1)['hasWebContent'], timeout=5, step=.05)
        app.call('select', tab=t2)
        clickedf = click_accessory(f1, favorite=True)
        afterf = settle(f1)
        record('PF3_favorite_minus_unloads', clickedf.get('glyph') == 'rowUnload' and afterf and afterf['section'] == 'favorites'
               and not afterf['hasWebContent'], clicked=clickedf, after=afterf)

        # PF4: the unloaded Favorite's "×" under the same pointer.
        againf = accessory(f1, favorite=True)
        clickedf2 = {'clicked': False}
        if againf.get('shown'):
            click_at(againf['point']); clickedf2 = {'clicked': True, 'glyph': againf['glyph']}
        afterf2 = settle(f1)
        record('PF4_favorite_x_on_unloaded_acts', clickedf2.get('clicked') and (afterf2 is None or afterf2['section'] != 'favorites'),
               accessory=againf, clicked=clickedf2, after=afterf2, observe=True)

        # PF5: Cmd-W on the selected pinned tab (real key event).
        app.call('select', tab=p2); wait_until(lambda: tab(p2)['hasWebContent'], timeout=5, step=.05)
        order = ids()
        app.call('key', key='w', modifiers=['command'])
        after5 = settle(p2)
        record('PF5_cmdw_pinned_unloads', after5 and after5['section'] == 'pinned' and not after5['hasWebContent'] and selected() != p2,
               after=after5, selected_after=selected(), order=order, observe_selection=True)

        # PF6: Cmd-W on the selected Favorite.
        if f1 in ids():
            app.call('select', tab=f1); wait_until(lambda: tab(f1)['hasWebContent'], timeout=5, step=.05)
            app.call('key', key='w', modifiers=['command'])
            after6 = settle(f1)
            record('PF6_cmdw_favorite_unloads', after6 and after6['section'] == 'favorites' and not after6['hasWebContent'] and selected() != f1,
                   after=after6, selected_after=selected())

        # PF7: two quick "−" clicks on two loaded pinned rows, no wait between them.
        for t in (p1, p2):
            app.call('select', tab=t); wait_until(lambda: tab(t)['hasWebContent'], timeout=5, step=.05)
        app.call('select', tab=t2)
        a1, a2 = hover(p1), None
        click_at(a1['point'])
        a2 = hover(p2)
        if a2.get('shown'): click_at(a2['point'])
        r1, r2 = settle(p1), settle(p2)
        record('PF7_quick_two_pinned_unloads', a1.get('glyph') == 'rowUnload' and a2.get('glyph') == 'rowUnload'
               and r1 and r2 and not r1['hasWebContent'] and not r2['hasWebContent'], first=a1, second=a2, after=[r1, r2])

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

        # PF9: close right after a drop: move t1 into Pinned through the real drop handler, then "−" at once.
        space = next(s for s in app.call('spaces') if s['focused'])['id']
        app.call('select', tab=t1); wait_until(lambda: tab(t1)['hasWebContent'], timeout=5, step=.05)
        app.call('select', tab=t2)
        dropped = app.call('sidebar-drop', nodes=[t1], parent={'kind': 'pinned', 'id': space}, index=0)
        clicked9 = click_accessory(t1)
        after9 = settle(t1)
        record('PF9_close_right_after_drop', dropped and clicked9.get('clicked') and after9 and after9['section'] == 'pinned'
               and not after9['hasWebContent'], dropped=dropped, clicked=clicked9, after=after9)

        # PF10: navigated away, then Cmd-W: the row keeps its pinned URL (reset semantics: observe).
        app.call('select', tab=p1); wait_until(lambda: tab(p1)['hasWebContent'], timeout=5, step=.05)
        app.call('navigate', tab=p1, url=fixture('PF Away'))
        wait_until(lambda: 'PF Away' in tab(p1)['url'] or None, timeout=5, step=.05)
        away = tab(p1)
        app.call('key', key='w', modifiers=['command'])
        after10 = settle(p1)
        record('PF10_cmdw_navigated_pinned', after10 and after10['section'] == 'pinned' and not after10['hasWebContent'],
               away={k: away[k] for k in ('url', 'pinnedURL', 'title')}, after=after10, observe=True)
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
    finally:
        server.shutdown()
        app.quit()
