"""UX round 1 wave 2, menus and drag and drop (lane UXE): real App rows through the automation socket.

- `uxe_drop_onto_folder_fills_row`: a tab dragged onto a folder's centre fills the folder row and opens
  its glyph, with no insertion line; moving on to a row boundary clears the fill and draws the line (D1).
- `uxe_favorites_gap_themed_mark`: over the gap between two Favorites the tray draws Open's own
  insertion mark (the sidebar drop line, standing up, 8 pt wide), not AppKit's system-blue bar (D2).
- `uxe_empty_split_pane_title`: an empty split pane is "New Tab" in the split row's menu, never
  the raw "about:blank" (M1).
- `uxe_library_filter_dot_only_off_default`: the Library Filter button shows its dot only when a
  filter differs from the section's default (UXC-W2-S8): none at the default in Downloads, Archive
  and History; a dot for All Profiles in Downloads and for a When chip in History; none again after.

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
            ok = 'New Tab ▸' in panes and not any('about:blank' in i for i in items)
            return ok, {'items': items, 'paneSubmenus': panes}
        _row(results, 'uxe_empty_split_pane_title', empty_pane)

        def filter_dot():
            seen, problems = {}, []
            try:
                for section in ('downloads', 'archive', 'history'):
                    app.call('library', action='open', section=section); time.sleep(.4)
                    state = app.call('library')
                    if 'filterDot' not in state:
                        return False, {'error': 'library state has no filterDot (automation predates the row)'}
                    seen[section + ':default'] = state['filterDot']
                    if state['filterDot']: problems.append('dot on %s with the default filter' % section)
                app.call('library', action='select', section='downloads'); time.sleep(.3)
                owner = app.call('library')['profiles']['downloads']
                for step, chip, want in (('all-profiles', 'profile:' + owner, True), ('back-to-default', 'profile:' + owner, False)):
                    app.call('library', action='chip', id=chip); time.sleep(.3)
                    seen['downloads:' + step] = app.call('library')['filterDot']
                    if seen['downloads:' + step] != want: problems.append('downloads %s: dot %s' % (step, seen['downloads:' + step]))
                app.call('library', action='select', section='history'); time.sleep(.3)
                for step, want in (('today', True), ('cleared', False)):
                    app.call('library', action='chip', id='when:today'); time.sleep(.3)
                    seen['history:' + step] = app.call('library')['filterDot']
                    if seen['history:' + step] != want: problems.append('history %s: dot %s' % (step, seen['history:' + step]))
            finally:
                app.call('library', action='close')
            return not problems, {'dot': seen, 'problems': problems}
        _row(results, 'uxe_library_filter_dot_only_off_default', filter_dot)
    finally:
        try: app.quit()
        except Exception: pass
        server.shutdown(); server.server_close()
