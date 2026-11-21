"""Real App Step H history flow, loaded by engine_e2e.py's history suite."""
import http.server
import json
import os
import sqlite3
import statistics
import threading
import time
from loopback_http import LoopbackHTTPServer


def label_checks(app, check, tmp, base, loaded, wait_until):
    """HISTFIX (0.1.6): every History row draws its whole title and subtitle in every state.

    CATextLayer's own end truncation drew only the top 3 points of a line wider than
    the row, so long titles showed as a thin slice and long subtitles vanished. Pixels
    come from the real window capture; label geometry comes from `library row-labels`.
    """
    from pathlib import Path
    from library_overlay import capture_window
    from engine_e2e import read_image
    lib = lambda **kw: app.call('library', **kw)
    frames = Path(os.environ.get('OPEN_E2E_HISTORY_FRAMES') or tmp); frames.mkdir(parents=True, exist_ok=True)
    tab = app.call('open', url=base + '/label-seed')['id']; loaded(tab, '/label-seed')
    paths = ['/label-%02d-a-long-history-title-that-is-much-wider-than-the-library-row' % i for i in range(30)]
    for path in paths:
        app.call('navigate', tab=tab, url=base + path); loaded(tab, path)
    app.call('menu-perform', id='view-history')
    seeded = wait_until(lambda: sum(r['kind'] == 'history' for r in lib().get('rows', [])) >= len(paths) + 1, timeout=8, step=.05)
    assert seeded, lib().get('rows', [])[:3]

    def measure(name, hovered=None):
        time.sleep(.3)  # Past the 0.10 s section fade and the next display commit.
        state = lib(); window = app.call('window-state')['frame']
        path = frames / ('history-labels-' + name + '.png'); capture_window(state['window'], path)
        width, height, pixel = read_image(str(path)); scale = width / window[2]
        try: probe = {r['id']: r for r in lib(action='row-labels')['rows']}
        except RuntimeError as error: probe = {'error': str(error)}
        rows, failures = [], []
        for row in state['rows']:
            x, y, w, h = row['frame']
            if row['kind'] != 'history' or y < 56 or y + h > window[3]: continue  # Fully visible rows only.
            right = x + w - len(row['buttons']) * 34 - 8 if row['id'] == hovered else x + w - 20
            def ink(top, bottom):
                xs = range(int((x + 52) * scale), int(right * scale)); ys = range(int((y + top) * scale), int((y + bottom) * scale))
                colors = {}
                for py in ys:
                    for px in xs[::3]: c = pixel(px, py); colors[c] = colors.get(c, 0) + 1
                bg = max(colors, key=colors.get)
                lines, left, end = 0, None, None
                for py in ys:
                    hits = [px for px in xs if max(abs(a - b) for a, b in zip(pixel(px, py), bg)) > 40]
                    if hits:
                        lines += 1; left = hits[0] if left is None else min(left, hits[0]); end = hits[-1] if end is None else max(end, hits[-1])
                span = (end - left) / scale if left is not None else 0
                return round(lines / scale, 1), round(span, 1)
            title, subtitle = ink(11, 30), ink(31, 48)
            labels = probe.get(row['id'])
            geometry = 'probe ' + probe['error'] if 'error' in probe else 'not realized' if not labels else ''
            if labels:
                for key in ('title', 'subtitle'):
                    layer = labels[key]; frame = layer['frame']
                    if not (frame[0] >= x and frame[1] >= y and frame[0] + frame[2] <= x + w and frame[1] + frame[3] <= y + h
                            and layer['rasterSize'] == frame[2:] and layer['rasterScale'] == layer['contentsScale'] == labels['windowScale']
                            and not layer['needsDisplay'] and not layer['animations'] and not any(layer['presentationOffset'])
                            and not layer['hidden'] and layer['opacity'] == 1):
                        geometry += key + ' layer ' + repr(layer) + '; '
                if labels['title']['frame'][1] + labels['title']['frame'][3] > labels['subtitle']['frame'][1]: geometry += 'title overlaps subtitle; '
            # Glyph ink: a 15 pt title spans >= 9 pt of rows, a 13 pt subtitle >= 7 pt; both
            # long lines truncate near the band's right edge.
            if row['id'] == hovered and not (labels or {}).get('hovered', True): geometry += 'probe row not hovered; '
            ok = title[0] >= 9 and subtitle[0] >= 7 and title[1] >= (right - x - 52) * .7 and subtitle[1] >= (right - x - 52) * .7 and not geometry
            rows.append(dict(id=row['id'][len(base):], titleInkPoints=title, subtitleInkPoints=subtitle, hovered=row['id'] == hovered))
            if not ok: failures.append(dict(rows[-1], geometry=geometry))
        least = lambda key, i: min((r[key][i] for r in rows), default=0)
        check('history_row_labels_' + name, len(rows) >= 8 and not failures, rows=len(rows), failures=failures[:4], capture=str(path), scale=scale,
              minimumInkPoints=dict(titleHeight=least('titleInkPoints', 0), titleSpan=least('titleInkPoints', 1),
                                    subtitleHeight=least('subtitleInkPoints', 0), subtitleSpan=least('subtitleInkPoints', 1)),
              hoveredMeasured=any(r['hovered'] for r in rows) if hovered else None)

    lib(action='close'); wait_until(lambda: not lib()['open'], timeout=3, step=.05)
    app.call('menu-perform', id='view-history'); wait_until(lambda: lib()['open'], timeout=3, step=.05)
    measure('open')
    for row in (24, 0): app.call('library-performance', operation='scroll', row=row)
    measure('scroll_reuse')
    target = next(r for r in lib()['rows'] if r['kind'] == 'history' and r['frame'][1] >= 120)
    lib(action='hover-row', id=target['id'], hovered=True)
    measure('hover', hovered=target['id'])
    lib(action='hover-row', id=target['id'], hovered=False)
    app.call('navigate', tab=tab, url=base + '/label-live-row-that-arrives-while-the-library-history-list-is-visible')
    wait_until(lambda: any(r['id'].endswith('/label-live-row-that-arrives-while-the-library-history-list-is-visible') for r in lib()['rows']), timeout=5, step=.05)
    lib(action='refresh')
    measure('reload')
    # Section fade (0.10 s opacity animation) with a reload issued inside it.
    lib(action='select', section='downloads'); lib(action='select', section='history'); lib(action='refresh')
    measure('reload_during_animation')

    def luma(c): return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    def grab(name):
        time.sleep(.4)
        state = lib(); window = app.call('window-state')['frame']
        path = frames / ('history-' + name + '.png'); capture_window(state['window'], path)
        width, _, pixel = read_image(str(path)); return state, window, width / window[2], pixel, path
    def background(pixel, scale, left, top, right, bottom):
        """Per-channel median of an empty strip. The panel is a dithered gradient: a solid glyph
        stroke can be the most common single color in a small box, so a mode is not the background."""
        samples = [pixel(px, py) for py in range(int(top * scale), int(bottom * scale)) for px in range(int(left * scale), int(right * scale))]
        return tuple(sorted(c[i] for c in samples)[len(samples) // 2] for i in range(3))
    def peak(pixel, scale, left, top, right, bottom, bg):
        """The pixel with the largest luma contrast to the background."""
        xs, ys = range(int(left * scale), int(right * scale)), range(int(top * scale), int(bottom * scale))
        return max((pixel(px, py) for py in ys for px in xs), key=lambda c: abs(luma(c) - luma(bg)))
    def globes(name):
        """Placeholder globe vs the row's subtitle text: both are the Library's secondary tint (foreground at 0.68)."""
        state, window, scale, pixel, path = grab(name)
        rows, failures = [], []
        for row in state['rows']:
            x, y, w, h = row['frame']
            if row['kind'] != 'history' or y < 56 or y + h > window[3]: continue
            bg = background(pixel, scale, x + 42, y + 6, x + 50, y + 50)  # Between the icon and the text.
            globe = peak(pixel, scale, x + 20, y + 18, x + 40, y + 38, bg)
            text = peak(pixel, scale, x + 52, y + 31, x + w - 20, y + 48, bg)
            delta = luma(globe) - luma(text)
            same_side = (luma(globe) - luma(bg)) * (luma(text) - luma(bg)) > 0
            rows.append(dict(id=row['id'][len(base):], background=bg, globePeak=globe, subtitlePeak=text, lumaDelta=round(delta, 1)))
            if abs(delta) > 30 or not same_side or abs(luma(globe) - luma(bg)) < 40: failures.append(rows[-1])
        return rows, failures, str(path)
    def appearance_row(mode):
        # Switch while the list stays open, after its idle overscan pass has prepared the rows below.
        app.call('library-performance', operation='scroll', row=0); time.sleep(1.5)
        app.call('appearance', name=mode)
        rows, failures, top = globes('globe-' + mode)
        # Rows prepared in overscan before the switch must take the new tint when they scroll in.
        app.call('library-performance', operation='scroll', row=16)
        more, more_failures, scrolled = globes('globe-' + mode + '-scrolled')
        app.call('library-performance', operation='scroll', row=0)
        check('history_placeholder_globe_' + mode, len(rows) >= 8 and len(more) >= 8 and not failures and not more_failures,
              rows=len(rows) + len(more), failures=(failures + more_failures)[:4], sample=rows[:1], captures=[top, scrolled])
    try:
        appearance_row('dark'); appearance_row('light')
    finally:
        app.call('appearance', name='system')

    # Filter chips show user text (Profile and Space names): a long name stays inside its chip and truncates.
    long_name = 'History Profile With A Very Long Name That Cannot Fit One Chip'  # 62 characters; Profile names allow 64.
    app.call('space-create', profile=long_name, title='History Long Name')
    app.call('menu-perform', id='view-history'); wait_until(lambda: lib()['open'], timeout=3, step=.05)
    lib(action='filter', open=True)
    chip = wait_until(lambda: next((c for c in lib()['header']['chips'] if c['title'] == long_name), None), timeout=3, step=.05)
    state, window, scale, pixel, path = grab('filter-chip-long-profile')
    x, y, w, h = chip['frame'] if chip else (0, 0, 0, 0)
    panel = state['panelFrame']
    def ink_columns(left, right):
        bg = background(pixel, scale, left, y + 4, right, y + h - 4)
        return [px for px in range(int(left * scale), int(right * scale))
                if any(max(abs(a - b) for a, b in zip(pixel(px, py), bg)) > 40 for py in range(int((y + 6) * scale), int((y + h - 6) * scale)))]
    inside = ink_columns(x + 3, x + w - 3) if chip else []  # Inside the 1.5 pt selected border.
    outside = (ink_columns(panel[0] + 112, x - 1) if x - 1 > panel[0] + 112 else []) + (ink_columns(x + w + 1, panel[0] + panel[2] - 2) if chip else [])
    span = (inside[-1] - inside[0]) / scale if inside else 0
    # The label keeps the chip's padding: a clipped label (cut at both chip edges, no ellipsis) has none.
    pads = [round(inside[0] / scale - x, 1), round(x + w - inside[-1] / scale, 1)] if inside else [0, 0]
    check('history_filter_chip_long_profile', bool(chip) and w <= 289 and span >= (w - 24) * .7 and not outside and min(pads) >= 8,
          chip=chip, inkSpanPoints=round(span, 1), paddingPoints=pads, inkColumnsOutsideChip=len(outside), capture=str(path))
    lib(action='filter', open=False)


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
    server = LoopbackHTTPServer(Handler)
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
    def select_history_profile(profile):
        if not app.call('library-state').get('open'):
            app.call('menu-perform', id='view-history')
            assert wait_until(lambda: app.call('library-state').get('open'), timeout=3, step=.05)
        app.call('library-ui', action='chip', id='profile:' + profile)
        assert wait_until(lambda: app.call('library-history-state')['profile'] == profile,
                          timeout=3, step=.05), app.call('library-history-state')
    try:
        app = factory(urls=(base + '/start',), fresh=True)
        saved = {key: app.call('defaults', key=key, persistent=True) for key in keys}
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
        select_history_profile(profile2)
        second = app.call('open', url=base + '/second'); second = second['id'] if isinstance(second, dict) else second
        loaded(second, '/second'); state2 = settle(); profile2 = state2['profile']
        wait_until(lambda: any(r['url'] == base + '/second' for r in app.call('library-history-state')['rows']), timeout=3, step=.05)
        app.call('navigate', tab=second, url=base + '/second-live'); loaded(second, '/second-live'); settle()
        late_profile_live = wait_until(lambda: any(r['url'] == base + '/second-live' for r in app.call('library-history-state')['rows']), timeout=3, step=.05)
        stored_second_live = page('/second-live')
        live_second_state = app.call('library-history-state')
        native_second_live = wait_until(lambda: (lambda s: s if any(r['id'] == base + '/second-live' for r in s['rows']) else None)(app.call('library-state')),
                                       timeout=3, step=.05)
        check('history_library_new_profile_live', bool(late_profile_live) and bool(stored_second_live) and bool(native_second_live),
              state=live_second_state, stored=stored_second_live, native=native_second_live)
        rows1, rows2 = dbrows(profile1), dbrows(profile2)
        check('history_profile_isolation', profile1 != profile2 and any(r['url'] == base + '/second' for r in rows2)
              and not any(r['url'] == base + '/second' for r in rows1) and not any(r['url'] == base + '/link' for r in rows2),
              profile1Count=len(rows1), profile2Count=len(rows2), file1=history(profile1)['file'], file2=state2['file'])
        # Two actual standard windows. The first model window has Profile 1,
        # while the front window has Profile 2: model order cannot pass this gate.
        first_window = app.call('shell-windows')[0]['id']
        space1 = next(s['id'] for s in app.call('spaces') if s['profile'] == profile1)
        select_history_profile(profile1)
        app.call('download-library-close')
        app.call('space', space=space1)
        app.call('command', id='new-window'); dismiss_bar()
        second_window = app.call('window-state')['id']
        app.call('space', space=space2)
        app.call('key', key='y', modifiers=['cmd'], route='app')
        picked = app.call('library-history-state')['profile']
        check('history_front_profile_cmd_y', first_window != second_window and picked == profile2 and picked != profile1,
              profile=picked, expected=profile2)
        select_history_profile(profile1)
        app.call('library-ui', action='select', section='downloads')
        app.call('library-ui', action='select', section='history')
        internal_profile = app.call('library-history-state')['profile']
        check('history_internal_navigation_keeps_filter', internal_profile == profile1 and internal_profile != profile2, profile=internal_profile)
        app.call('window-focus', id=second_window, activate=True)
        app.call('menu-perform', id='view-history')
        kept = app.call('library-history-state')['profile']
        check('history_manual_profile_while_open', kept == profile2 and kept != profile1, profile=kept, expectedOwner=profile2, rule='outside entry resets the filter')
        settled_provider = wait_until(lambda: (lambda s: s if s.get('loaded') and not s.get('running') else None)(app.call('library-state')['providers'].get('history', {})), timeout=3, step=.05)
        assert settled_provider, app.call('library-state')
        app.call('menu-perform', id='view-history')
        same_provider = app.call('library-state')['providers']['history']
        check('history_owner_entry_no_reload', same_provider['generation'] == settled_provider['generation'] and same_provider['loaded'], before=settled_provider, after=same_provider)
        select_history_profile(profile1)
        app.call('download-library-close')
        app.call('window-focus', id=second_window, activate=True)
        app.call('menu-perform', id='view-history')
        picked = app.call('library-history-state')['profile']
        check('history_front_profile_menu_reopen', picked == profile2 and picked != profile1, profile=picked, previousOwner=kept)
        select_history_profile(profile1)
        app.call('download-library-close')
        app.call('window-focus', id=second_window, activate=True)
        command = bar('View History')
        action = next((i for i, r in enumerate(command.get('rows', [])) if r.get('action') == 'view-history'), None)
        if action is None: raise RuntimeError('History command missing from real command bar')
        # Move through the real command field and submit its selected result.
        selected = command.get('selected', 0)
        for _ in range(abs(action - selected)):
            app.call('key', key='down' if action > selected else 'up', route='app')
        app.call('key', key='return', route='app')
        picked = app.call('library-history-state')['profile']
        check('history_front_profile_commandbar', picked == profile2 and picked != profile1
              and app.call('settings-state')['librarySection'] == 'history', profile=picked, command=command)
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
        select_history_profile(profile2)
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
        # The substring fallback runs when FTS finds nothing (a mid-word query). `%` and `_`
        # typed there are literal text, not LIKE wildcards ('qz_qv' must not match 'qzaqv').
        app.call('navigate', tab=sample_tab, url=base + '/like-qzaqv'); loaded(sample_tab, '/like-qzaqv'); settle()
        def history_search(query):
            return [r['url'] for owner in (profile1, profile2) for r in app.call('history-state', profile=owner, query=query)['rows']]
        like_target = base + '/like-qzaqv'
        like_control, like_underscore, like_percent = history_search('zaqv'), history_search('qz_qv'), history_search('qz%v')
        check('history_substring_wildcards_literal', like_target in like_control and like_target not in like_underscore
              and like_target not in like_percent, control=like_control, underscore=like_underscore, percent=like_percent)
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
        select_history_profile(profile1)
        before_all = dbrows(profile1); app.call('library-history-delete', all=True)
        check('history_library_clear_all', bool(before_all) and not dbrows(profile1), beforeCount=len(before_all))
        select_history_profile(profile2)
        app.call('download-library-close')
        for window in app.call('shell-windows'):
            app.call('window-focus', id=window['id'], activate=True)
            app.call('window-close')
        without_windows = app.call('shell-windows')
        assert not without_windows, without_windows
        app.call('menu-perform', id='view-history')
        fallback = app.call('library-history-state')['profile']
        owners = app.call('shell-windows')
        owner_profile = next((s['profile'] for s in app.call('spaces') if s['focused']), None)
        check('history_default_profile_without_window', len(owners) == 1 and fallback == profile1
              and fallback != profile2 and owner_profile == profile1, profile=fallback,
              windowsBefore=without_windows, windowsAfter=owners, ownerProfile=owner_profile)
        label_checks(app, check, tmp, base, loaded, wait_until)
    finally:
        if app:
            restore_defaults(app, saved)
            app.quit()
        server.shutdown(); server.server_close(); worker.join(timeout=3)
