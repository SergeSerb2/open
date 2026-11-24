"""UX round 1 wave 2, menus and drag and drop (lane UXE): real App rows through the automation socket.

- `uxe_drop_onto_folder_fills_row`: a tab dragged onto a folder's centre fills the folder row and opens
  its glyph, with no insertion line; moving on to a row boundary clears the fill and draws the line (D1).
- `uxe_favorites_gap_themed_mark`: over the gap between two Favorites the tray draws Open's own
  insertion mark (the sidebar drop line, standing up, 8 pt wide), not AppKit's system-blue bar (D2).
- `uxe_empty_split_pane_title`: an empty split pane is "New Tab" in the split row's menu, never
  the raw "about:blank" (M1).
- `uxe_library_filter_dot_only_off_default`: the Library Filter button shows its dot only when a
  filter differs from the section's default (UXC-W2-S8). Checked by the control's drawn state and by
  the window's pixels, after filter changes (with the Filter drawer opened and closed) and after
  section switches: none at the default, a dot for All Profiles or a When chip, none again after.
- `uxe_favorites_empty_tray_no_gap_mark`: over the empty Favorites tray the empty-state card is the
  drop feedback; no clipped or zero-size gap mark is shown (review r1 #2). Its own App launch.
- `uxe_drop_fill_survives_row_reuse`: the folder fill comes back on a new row view during a still
  drag (the outer folder of the target collapses and expands; review r1 #4).
- `uxe_drop_fill_cleared_on_space_switch`: a Space switch during a drag (⌃2, ⌃1) leaves no folder
  fill on the page that slid away (review r1 #4).

Drags use `basics-demo drag-begin/over/end`: the real destination views' NSDraggingDestination
callbacks with a real pasteboard, hit-tested at window points. Socket only (no desktop input).
`engine_e2e.py --only context-menus` runs these rows; OPEN_CONTEXT_MENUS_UXE_ONLY=1 runs only them.
"""
import http.server
import os
import sys
import threading
import time

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from loopback_http import LoopbackHTTPServer  # noqa: E402
from library_ux1 import png_luma  # noqa: E402


def _server():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            name = self.path.split('?')[0].strip('/') or 'page'
            body = ('<!doctype html><meta charset=utf-8><title>Page %s</title><body>%s</body>' % (name, name)).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, 'http://127.0.0.1:%d' % server.server_address[1]


def _row(results, name, check):
    try:
        ok, evidence = check()
    except Exception as error:  # a broken step is a failed row, never a skipped one
        ok, evidence = False, {'error': repr(error)}
    results[name] = dict(ok=bool(ok), **evidence)
    print('uxe %-44s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)


def _center(frame):
    return [frame[0] + frame[2] / 2, frame[1] + frame[3] / 2]


def _find(nodes, kind):
    for node in nodes if isinstance(nodes, list) else []:
        if isinstance(node, dict):
            if node.get('kind') == kind:
                return node
            found = _find(node.get('children', []), kind)
            if found:
                return found


def run(factory, results, tmp, h):
    empty_tray_rows(factory, results, tmp)
    main_rows(factory, results, tmp, h)


def empty_tray_rows(factory, results, tmp):
    # Its own App: the demo drag cannot end an NSCollectionView drag session the way AppKit does
    # (NSOutlineView's draggingEnded needs a real session), so in one App only the first demo drag
    # over the Favorites collection shows a gap mark. The empty-state card is off by default in
    # harness profiles.
    server, origin = _server()
    app = factory(urls=(origin + '/e0', origin + '/e1'), fresh=True, extra_args=['--favorites-empty-state=shown'])
    try:
        tabs = [t['id'] for t in app.call('tabs')]
        def empty_tray():
            empty = app.call('favorites-empty-state', action='state')
            card = app.call('basics-demo', op='targets').get('favoritesEmptyCard')
            if card is None:
                return False, {'error': 'targets has no favoritesEmptyCard (automation predates the row)'}
            if not card:
                return False, {'error': 'no Favorites empty-state card', 'state': empty}
            rows = {r['id']: r['frame'] for r in app.call('basics-demo', op='targets')['rows']}
            app.call('basics-demo', op='drag-begin', node=tabs[1], image=os.path.join(tmp, 'uxe-drag0.png'), point=_center(rows[tabs[1]]))
            try:
                replies = [app.call('basics-demo', op='drag-over', point=_center(card)) for _ in range(2)]
                during = app.call('favorites-empty-state', action='state')
            finally:
                app.call('basics-demo', op='drag-end', point=[600, 400], perform=False)
            gap = replies[-1].get('favoritesGap')
            ok = gap == [] and during.get('dropTarget') is True
            return ok, {'card': card, 'favoritesGap': gap, 'cardDropTarget': during.get('dropTarget'),
                        'destination': replies[-1].get('destination')}
        _row(results, 'uxe_favorites_empty_tray_no_gap_mark', empty_tray)
    finally:
        try: app.quit()
        except Exception: pass
        server.shutdown(); server.server_close()


def main_rows(factory, results, tmp, h):
    server, origin = _server()
    app = factory(urls=tuple(origin + '/t%d' % i for i in range(7)), fresh=True)
    wait = h.wait_until
    try:
        app.call('window-frame', frame=[80, 80, 1200, 820], unconstrained=True)
        tabs = [t['id'] for t in app.call('tabs')]
        for tab in tabs:
            try: app.call('wait', tab=tab, timeout=15)
            except Exception: pass
        fav, pinned, today = tabs[:3], tabs[3:5], tabs[5:]


        for tab in fav:
            app.call('favorite', tab=tab)
        for tab in pinned:
            app.call('pin', tab=tab)
        folder = app.call('folder', tabs=[pinned[1]], title='Drop Folder', section='pinned')
        # Collapsed, so an open glyph can only come from the drop target.
        if app.call('folder-toggle', folder=folder)['expanded']:
            app.call('folder-toggle', folder=folder)
        app.call('select', tab=today[0]); time.sleep(.6)

        def drag(over):
            """Lift today[1], visit each window point, cancel; the drag-over replies in order."""
            rows = {r['id']: r['frame'] for r in app.call('basics-demo', op='targets')['rows']}
            app.call('basics-demo', op='drag-begin', node=today[1], image=os.path.join(tmp, 'uxe-drag.png'),
                     point=_center(rows[today[1]]))
            try:
                return [app.call('basics-demo', op='drag-over', point=p) for p in over(rows)]
            finally:
                app.call('basics-demo', op='drag-end', point=[600, 400], perform=False)

        def onto_folder():
            on, between = drag(lambda rows: [_center(rows[folder]),
                                             [rows[pinned[0]][0] + 60, rows[pinned[0]][1] + rows[pinned[0]][3] - 1]])
            if 'dropFolder' not in on:
                return False, {'error': 'drag-over has no dropFolder (automation predates the row)'}
            target = on['dropFolder'] or {}
            problems = []
            if target.get('folder') != folder: problems.append('no folder drop target: %r' % target)
            if not target.get('rowFilled'): problems.append('folder row not filled')
            if not target.get('glyphOpen') or target.get('drawnGlyph') != 'folder.open':
                problems.append('folder glyph not open (%s)' % target.get('drawnGlyph'))
            if on.get('indicator'): problems.append('insertion line drawn over the folder: %r' % on['indicator'])
            if between.get('dropFolder'): problems.append('fill stays at a row boundary: %r' % between['dropFolder'])
            if not between.get('indicator'): problems.append('no insertion line at the row boundary')
            return not problems, {'onFolder': on, 'boundary': between, 'problems': problems}
        _row(results, 'uxe_drop_onto_folder_fills_row', onto_folder)

        def favorites_gap():
            tiles = app.call('basics-demo', op='targets').get('favorites')
            if tiles is None:
                return False, {'error': 'targets has no favorites (automation predates the row)'}
            if len(tiles) < 2:
                return False, {'error': 'expected 3 favorites, found %d' % len(tiles)}
            a, b = tiles[0]['frame'], tiles[1]['frame']
            point = [(a[0] + a[2] + b[0]) / 2, a[1] + a[3] / 2]
            # AppKit places its gap indicator a run-loop turn after the first update: visit twice.
            reply = drag(lambda rows: [point, point])[-1]
            gap = reply.get('favoritesGap')
            problems = []
            if gap is None: problems.append('drag-over has no favoritesGap (automation predates the row)')
            elif not gap: problems.append("no themed gap mark (AppKit's default bar or none)")
            else:
                if abs(gap[2] - 8) > .5: problems.append('mark is %.1f pt wide, not 8' % gap[2])
                if gap[3] < a[3] - 1: problems.append('mark is %.1f pt tall, shorter than a tile (%.1f)' % (gap[3], a[3]))
            if reply.get('indicator'): problems.append('sidebar line drawn over the tray')
            return not problems, {'point': point, 'tiles': [a, b], 'reply': reply, 'problems': problems}
        _row(results, 'uxe_favorites_gap_themed_mark', favorites_gap)

        def empty_pane():
            app.call('select', tab=today[0]); app.call('split')
            assert wait(lambda: len(app.call('split', op='state')['panes']) >= 2, timeout=10), 'no split'
            time.sleep(.5)
            tree = app.call('sidebar-tree')
            split = _find(tree.get('today', []) + tree.get('pinned', []) if isinstance(tree, dict) else tree, 'split')
            if not split:
                return False, {'error': 'no split row in the sidebar tree'}
            items = app.call('sidebar-menu-items', node=split['id'])['items']
            panes = [i for i in items if i.endswith(' ▸') and i not in ('Move to ▸',)]
            drawn = (app.call('split', op='state').get('rowPresentation') or {}).get('titles', [])
            labels = [e['label'] for e in app.call('ax-elements') if e.get('label', '').startswith('Split View:')]
            ok = ('New Tab ▸' in panes and not any('about:blank' in i for i in items)
                  and 'New Tab' in drawn and 'about:blank' not in drawn
                  and labels and all('New Tab' in l and 'about:blank' not in l for l in labels))
            return ok, {'items': items, 'paneSubmenus': panes, 'rowTitles': drawn, 'axLabels': labels}
        _row(results, 'uxe_empty_split_pane_title', empty_pane)

        def filter_dot():
            seen, problems = [], []

            def dot(label):
                """The dot as the control reports it and as the window's pixels show it."""
                state = app.call('library')
                if 'filterDot' not in state:
                    raise RuntimeError('library state has no filterDot (automation predates the row)')
                f = state['header']['filterFrame']
                path = os.path.join(tmp, 'uxe-filter-dot-%s.png' % label)
                app.call('snapshot', path=path)
                width, height, luma = png_luma(path)
                scale = width / app.call('window-state')['frame'][2]

                def box(x, y, w, h):
                    return [luma(int(px), int(py)) for py in range(int(y * scale), int((y + h) * scale))
                            for px in range(int(x * scale), int((x + w) * scale))]
                # The 4 pt dot sits 8 pt in from the control's right edge, 5 pt down; the 2 pt band
                # right of it is the control's own (clear) background.
                ink = box(f[0] + f[2] - 7.5, f[1] + 5.5, 3, 3)
                ground = box(f[0] + f[2] - 3, f[1] + 5, 2, 4)
                base = sorted(ground)[len(ground) // 2]
                contrast = round(max(abs(v - base) for v in ink), 3)
                return state['filterDot'], contrast > 0.25, contrast

            def check(label, want):
                drawn, pixels, contrast = dot(label)
                seen.append({'step': label, 'want': want, 'drawn': drawn, 'pixels': pixels, 'contrast': contrast})
                if drawn != want or pixels != want:
                    problems.append('%s: want %s, drawn %s, pixels %s (%.2f)' % (label, want, drawn, pixels, contrast))

            def chip(chip_id):
                app.call('library', action='filter', open=True); time.sleep(.3)
                app.call('library', action='chip', id=chip_id); time.sleep(.2)
                app.call('library', action='filter', open=False); time.sleep(.4)

            def section(name):
                app.call('library', action='select', section=name); time.sleep(.5)
            try:
                app.call('library', action='open', section='downloads'); time.sleep(.6)
                owner = app.call('library')['profiles']['downloads']
                check('downloads-default', False)
                chip('profile:' + owner); check('downloads-all-profiles', True)
                section('archive'); check('archive-default', False)
                section('downloads'); check('downloads-all-profiles-again', True)
                chip('profile:' + owner); check('downloads-back-to-default', False)
                section('history'); check('history-default', False)
                chip('when:today'); check('history-today', True)
                section('archive'); check('archive-after-history', False)
                section('history'); check('history-today-again', True)
                chip('when:today'); check('history-cleared', False)
            finally:
                app.call('library', action='close')
            return not problems, {'steps': seen, 'problems': problems}
        _row(results, 'uxe_library_filter_dot_only_off_default', filter_dot)

        def hold_over_folder():
            rows = {r['id']: r['frame'] for r in app.call('basics-demo', op='targets')['rows']}
            app.call('basics-demo', op='drag-begin', node=today[1], image=os.path.join(tmp, 'uxe-drag2.png'), point=_center(rows[today[1]]))
            on = app.call('basics-demo', op='drag-over', point=_center(rows[folder]))
            return (on.get('dropFolder') or {}).get('rowFilled') is True


        def fill_survives_row_reuse():
            # A folder inside an expanded folder; the pointer stays over the inner folder while the
            # outer one collapses (the inner row and its row view go away) and expands (a new row
            # view is added). No drag-over runs in between, so only `configure` can refill the row.
            space = next(x['id'] for x in app.call('spaces') if x['focused'])
            outer = app.call('folder', tabs=[], title='Outer Folder', section='pinned')
            inner = app.call('folder', tabs=[], title='Inner Folder', section='pinned')
            app.call('sidebar-drop', nodes=[inner], parent={'kind': 'folder', 'id': outer}, index=0)
            if not app.call('folder-toggle', folder=outer)['expanded']:
                app.call('folder-toggle', folder=outer)
            time.sleep(.5)
            rows = {r['id']: r['frame'] for r in app.call('basics-demo', op='targets')['rows']}
            if inner not in rows:
                return False, {'error': 'inner folder row not shown', 'space': space}
            app.call('basics-demo', op='drag-begin', node=today[1], image=os.path.join(tmp, 'uxe-drag3.png'), point=_center(rows[today[1]]))
            states = {}
            try:
                held = app.call('basics-demo', op='drag-over', point=_center(rows[inner])).get('dropFolder') or {}
                for step in ('collapsed', 'expanded'):
                    app.call('folder-toggle', folder=outer); time.sleep(.6)
                    states[step] = app.call('basics-demo', op='targets').get('dropFolder')
            finally:
                app.call('basics-demo', op='drag-end', point=[600, 400], perform=False)
            ok = held.get('folder') == inner and held.get('rowFilled') is True and (states['expanded'] or {}).get('rowFilled') is True
            return ok, {'held': held, 'states': states}
        _row(results, 'uxe_drop_fill_survives_row_reuse', fill_survives_row_reuse)

        def fill_cleared_on_space_switch():
            focused_space = lambda: next((x['id'] for x in app.call('spaces') if x['focused']), None)
            space_one = focused_space()
            app.call('space-create', title='Second', profile='Second')
            app.call('space', space=space_one); time.sleep(.8)
            held = hold_over_folder()
            try:
                app.call('key', key='2', modifiers=['ctrl'], route='app'); time.sleep(.8)
                app.call('key', key='1', modifiers=['ctrl'], route='app'); time.sleep(.8)
                back = app.call('basics-demo', op='targets').get('dropFolder')
                focused = focused_space()
            finally:
                app.call('basics-demo', op='drag-end', point=[600, 400], perform=False)
            ok = held and focused == space_one and not back
            return ok, {'heldFilled': held, 'afterSwitchBack': back, 'focused': focused, 'spaceOne': space_one}
        _row(results, 'uxe_drop_fill_cleared_on_space_switch', fill_cleared_on_space_switch)
    finally:
        try: app.quit()
        except Exception: pass
        server.shutdown(); server.server_close()
