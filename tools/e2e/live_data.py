"""LF L1: the Recents live-data hover card, through the real App automation socket.

Fixture hosts on the loopback server stand in for linear.app / notion.so (`glance-alias`);
history rows are seeded in the Profile's real history store. No account, no network.
"""
import os
import struct
import time
import zlib


def png_pixels(path):
    """Minimal PNG reader (8-bit RGB/RGBA, not interlaced): width, height, rows of bytes."""
    data = open(path, 'rb').read()
    pos, idat, info = 8, b'', None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR': info = struct.unpack('>IIBBBBB', chunk)
        elif kind == b'IDAT': idat += chunk
        pos += 12 + length
    width, height, depth, color, _, _, interlace = info
    assert depth == 8 and color in (2, 6) and interlace == 0, info
    bpp = 3 if color == 2 else 4
    raw, stride, rows, prev = zlib.decompress(idat), width * bpp, [], bytearray(width * bpp)
    for y in range(height):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p_ = a + b - c; pa, pb, pc = abs(p_ - a), abs(p_ - b), abs(p_ - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return width, height, bpp, rows


def github_fixture():
    """A loopback stand-in for github.com/pulls (synthetic rows only). `state` drives it:
    {'signed_in': bool, 'prs': {kind_marker: [(owner/repo, number, title, status)]}}."""
    import http.server, threading, html, urllib.parse
    state = {'signed_in': True, 'prs': {}, 'requests': []}
    markers = {'author:@me': 'created', 'review-requested:@me': 'review', 'review:approved': 'approved', 'review:changes_requested': 'changes'}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            state['requests'].append(parsed.path)
            if parsed.path == '/pulls' and not state['signed_in']:
                self.send_response(302); self.send_header('Location', '/login?return_to=%2Fpulls'); self.send_header('Content-Length', '0'); self.end_headers(); return
            if parsed.path == '/login':
                body = '<!doctype html><title>Sign in</title><form action="/session" method="post"><input name="login"></form>'
            elif parsed.path == '/pulls':
                query = urllib.parse.parse_qs(parsed.query).get('q', [''])[0]
                kind = next((v for k, v in markers.items() if k in query), '')
                rows = state['prs'].get(kind, [])
                items = ''.join('<li data-pr-row data-pr-state="%s" data-pr-author="octo"><a class="Link--primary" href="/%s/pull/%d">%s</a>'
                                '<relative-time datetime="2026-11-1%dT10:00:00Z"></relative-time></li>' % (st, repo, n, html.escape(t), n % 10)
                                for repo, n, t, st in rows)
                body = '<!doctype html><title>Pull requests</title><ul>%s</ul>%s' % (items, '' if rows else '<div class="blankslate">No results</div>')
            else:
                body = '<!doctype html><title>Fixture</title>'
            data = body.encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1], state


def live_folder_checks(app, results, wait_until):
    server, port, gh = github_fixture()
    try:
        app.call('live-folder-origin', url='http://github.localhost:%d' % port)
        gh['prs'] = {'created': [('acme/app', 12, 'Fix sidebar drag', 'open'), ('acme/web', 7, 'Draft: new header', 'draft')],
                     'review': [('acme/app', 15, 'Add Live Folders', 'open'), ('acme/app', 12, 'Fix sidebar drag', 'open')],
                     'approved': [], 'changes': [('acme/api', 3, 'Merged already', 'merged')]}
        menu = app.call('sidebar-menu-state', item='Live Folders/GitHub')
        app.call('sidebar-menu', item='Live Folders/GitHub')
        state = app.call('live-folder-state', wait=True)
        titles = [r['title'] for r in state.get('rows', [])]
        results['live_folder_created_from_space_menu'] = {'ok': menu.get('checked') is False and state.get('exists') and state.get('title') == 'Pull Requests'
            and state.get('pinnedIndex') == 0 and state.get('outcome') == 'success'
            and sorted(titles) == sorted(['Fix sidebar drag', 'Draft: new header', 'Add Live Folders'])
            and all(r['live'] for r in state['rows']) and not any(r['unread'] for r in state['rows'])
            and app.call('sidebar-menu-state', item='Live Folders/GitHub').get('checked') is True, 'menu': menu, 'state': state}
        results['live_folder_fetch_pages_closed'] = {'ok': state.get('fetchPagesCreated') == state.get('fetchPagesClosed') and state.get('fetchPagesCreated', 0) >= 4,
            'state': {k: state.get(k) for k in ('fetchPagesCreated', 'fetchPagesClosed')}}
        # A PR ends, a new one comes: refetch removes and adds, new rows are unread.
        gh['prs']['created'] = [('acme/app', 12, 'Fix sidebar drag (v2)', 'open')]
        gh['prs']['review'] = [('acme/app', 21, 'New review request', 'open')]
        refreshed = app.call('live-folder-refresh')
        state = app.call('live-folder-state')
        rows = {r['title']: r for r in state.get('rows', [])}
        results['live_folder_refresh_diff'] = {'ok': refreshed.get('outcome') == 'success' and set(rows) == {'Fix sidebar drag (v2)', 'New review request'}
            and rows['New review request']['unread'] and not rows['Fix sidebar drag (v2)']['unread'], 'state': state}
        throttled = app.call('live-folder-refresh', manual=False)
        results['live_folder_throttle_10s'] = {'ok': throttled.get('outcome') is None and throttled.get('throttled', 0) >= 1, 'refresh': throttled}
        gh['signed_in'] = False
        out = app.call('live-folder-refresh')
        state = app.call('live-folder-state')
        results['live_folder_signed_out_state'] = {'ok': out.get('outcome') == 'signedOut' and state.get('outcome') == 'signedOut' and len(state.get('rows', [])) == 2,
            'refresh': out, 'state': state}
        gh['signed_in'] = True
        app.call('sidebar-menu', item='Live Folders/GitHub')
        gone = app.call('live-folder-state')
        results['live_folder_toggle_off_removes'] = {'ok': gone.get('exists') is False and app.call('sidebar-menu-state', item='Live Folders/GitHub').get('checked') is False, 'state': gone}
    finally:
        server.shutdown()


def run(factory, results, tmp, harness):
    new_tab, wait_until = harness['new_tab'], harness['wait_until']
    server, port = harness['_sleep_server']()
    app = factory(urls=(), fresh=True)
    key = 'open.general.previewsRecents'
    def url(host, path):
        return 'http://%s.localhost:%d/%s' % (host, port, path)
    def hover(node, ms=800):
        app.call('hover', leave=True, ms=300)
        return app.call('hover', node=node, ms=ms)
    try:
        app.call('window-frame', frame=[80, 60, 1280, 820])
        # Real host matching (pure decision, same code the tracker uses).
        cases = {'https://linear.app/acme/issue/ENG-1': 'linear', 'https://www.notion.so/acme/Plan-1a2b': 'notion',
                 'https://www.figma.com/design/abc/Icons': 'figma', 'https://acme.atlassian.net/wiki/spaces/ENG': 'confluence',
                 'https://calendar.notion.so/': None, 'https://acme.atlassian.net/jira/software': None, 'https://example.com/linear.app': None}
        got = {u: app.call('glance-match', url=u).get('site') for u in cases}
        results['live_glance_host_match'] = {'ok': got == cases, 'got': got}

        # L2 groundwork: a hidden, never-shown page in the Profile loads and runs an Open-world script.
        before = len(app.call('tabs'))
        fetched = app.call('live-fetch', url=url('fetch', 'live-fetch'), script='document.title + "|" + typeof window.__pageOnly')
        results['live_fetch_host_hidden_page'] = {'ok': fetched.get('value') == 'Sleep /live-fetch|undefined'
            and fetched.get('created') == fetched.get('closed') == 1 and len(app.call('tabs')) == before, 'fetched': fetched}
        app.call('glance-alias', aliases={'recents.localhost': 'linear', 'empty.localhost': 'notion', 'today.localhost': 'figma'})
        now_rows = [  # (path, title, seconds ago) — newest first after sorting.
            ('issue/ENG-3', 'ENG-3 Newest issue', 60),
            ('issue/ENG-2', 'ENG-2 Middle issue', 600),
            ('issue/ENG-2?tab=activity', 'ENG-2 Middle issue (activity)', 900),  # same page, query ignored
            ('', 'Linear home', 30),                                            # site home is not a recent page
            ('login', 'Log in', 20),                                            # login is not a recent page
            ('project/roadmap', 'Q4 Roadmap', 3600)]
        for path, title, ago in now_rows:
            app.call('history-record', url=url('recents', path), title=title, ago=ago)
        app.call('history-record', url=url('other', 'issue/ENG-9'), title='Other host', ago=5)
        linear = new_tab(app, url('recents', ''))
        app.call('pin', tab=linear)
        empty = new_tab(app, url('empty', ''))
        app.call('pin', tab=empty)
        today = new_tab(app, url('plain', 'today'))
        today_url = url('today', 'design/today-row')  # own host: its visit must not reach the Linear card
        today_site = new_tab(app, today_url)
        app.call('select', tab=today)

        shown = hover(linear)
        state = app.call('glance-state')
        titles = [r['title'] for r in state.get('rows', [])]
        expected = ['ENG-3 Newest issue', 'ENG-2 Middle issue', 'Q4 Roadmap']
        results['live_recents_card_rows'] = {'ok': shown['kind'] == 'glance' and shown['target'] == linear and state.get('shown')
            and state.get('site') == 'linear' and state.get('header') == 'Recents' and state.get('newLabel') == 'New Issue'
            and titles[:3] == expected and len(titles) == 3 and state.get('empty') == ''
            and len(state.get('card', [])) == 4 and state['card'][2] == 240,
            'hover': shown, 'state': state}

        # Real-window snapshot: the card casts the folder card's shadow on the window under it.
        shot = os.path.join(tmp, 'live-recents-card.png')
        window = app.call('window-state')
        app.call('snapshot', window=window.get('number'), path=shot)
        width, height, bpp, rows = png_pixels(shot)
        scale = width / 1280  # window-frame set above: 1280 pt wide
        x0, y0, cw, ch = state['card']
        def lum(px, py):
            px, py = int(px * scale), int(py * scale)
            r = rows[min(py, height - 1)][px * bpp:px * bpp + 3]
            return sum(r) / 3
        cx = x0 + cw / 2
        near, far = lum(cx, y0 + ch + 3), lum(cx, y0 + ch + 40)
        if os.environ.get('OPEN_LIVE_DATA_FRAMES'):  # optional copy for look reviews
            import shutil; shutil.copy(shot, os.path.join(os.environ['OPEN_LIVE_DATA_FRAMES'], 'live-recents-card-window.png'))
        results['live_recents_card_shadow'] = {'ok': far - near >= 6, 'near': near, 'far': far, 'scale': scale, 'card': state['card'], 'png': shot}
        opened = app.call('glance-open', row=0)
        first_state = app.call('peek-state')
        peek = wait_until(lambda: (lambda s: s if s.get('shown') and s['stack'] and s['stack'][-1]['content'] > 0 else None)(app.call('peek-state')), timeout=5, step=.05)
        top = peek['stack'][-1] if peek else {}
        href = ''
        if peek:
            app.call('wait', tab=top['content'])
            href = app.eval(top['content'], 'location.href')
        results['live_recents_row_opens_peek'] = {'ok': bool(peek) and href == url('recents', 'issue/ENG-3') and top.get('source') == linear and app.call('window-state').get('selected') == linear
            and app.call('glance-state').get('shown') is False, 'peek': peek, 'href': href, 'opened': opened, 'first': first_state, 'window': app.call('window-state')}
        app.call('peek-close')
        wait_until(lambda: not app.call('peek-state').get('shown'), timeout=5, step=.05)
        app.call('select', tab=today)  # the Peek selected its Pinned source; hover skips the current tab

        shown = hover(empty)
        state = app.call('glance-state')
        results['live_recents_empty'] = {'ok': shown['kind'] == 'glance' and state.get('site') == 'notion' and state.get('rows') == []
            and state.get('empty') == 'Recent Notion docs appear here.' and state.get('newLabel') == 'New Page', 'state': state}

        plain = hover(today_site)
        results['live_recents_only_pinned_or_favorite'] = {'ok': plain['kind'] == 'none', 'hover': plain}

        app.call('defaults', key=key, value=False)
        off = hover(linear)
        results['live_recents_switch_off_gives_page_card'] = {'ok': off['kind'] == 'page' and app.call('glance-state').get('shown') is False, 'hover': off}
        app.call('defaults', key='open.general.previewsPages', value=False)
        none = hover(linear)
        app.call('defaults', key=key, value=None)
        on = hover(linear)
        results['live_recents_own_switch'] = {'ok': none['kind'] == 'none' and on['kind'] == 'glance', 'off': none, 'on': on}
        app.call('defaults', key='open.general.previewsPages', value=None)
        app.call('hover', leave=True, ms=400)
        results['live_recents_hides_on_leave'] = {'ok': app.call('glance-state').get('shown') is False}
        live_folder_checks(app, results, wait_until)
    finally:
        try:
            app.call('glance-alias', aliases={})
        finally:
            app.quit()
            server.shutdown()
