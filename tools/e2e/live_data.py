"""LF L1: the Recents live-data hover card, through the real App automation socket.

Fixture hosts on the loopback server stand in for linear.app / notion.so (`glance-alias`);
history rows are seeded in the Profile's real history store. No account, no network.
"""
import os
import struct
import time
import zlib
from loopback_http import LoopbackHTTPServer


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
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1], state


def live_folder_checks(holder, results, wait_until, factory, new_tab):
    app = holder['app']
    server, port, gh = github_fixture()
    try:
        app.call('live-folder-origin', url='http://github.localhost:%d' % port)
        # The test App's preferences domain outlives one run: start from first-use state.
        for key in ('open.liveFolders.introSeen', 'open.liveFolders.githubAutoCreate'):
            app.call('defaults', key=key, value=None)
        gh['prs'] = {'created': [('acme/app', 12, 'Fix sidebar drag', 'open'), ('acme/web', 7, 'Draft: new header', 'draft')],
                     'review': [('acme/app', 15, 'Add Live Folders', 'open'), ('acme/app', 12, 'Fix sidebar drag', 'open')],
                     'approved': [], 'changes': [('acme/api', 3, 'Merged already', 'merged')]}
        menu = app.call('sidebar-menu-state', item='Live Folders/GitHub')
        app.call('sidebar-menu', item='Live Folders/GitHub')
        state = app.call('live-folder-state', wait=True)
        intro, row = state.get('intro'), state.get('rowFrame')
        # Intro card beside the new row (capture s5 b3): right of the sidebar, centred on the row, Arc's strings.
        results['live_folder_intro_card'] = {'ok': bool(intro) and bool(row) and intro['body'] == 'Pull requests from you and your team will show up here automatically'
            and intro['title'] == 'Pull Requests' and intro['frame'][0] >= row[0] + row[2] and abs((intro['frame'][1] + intro['frame'][3] / 2) - (row[1] + row[3] / 2)) <= 1
            and intro['frame'][2] == 228, 'intro': intro, 'row': row}
        if os.environ.get('OPEN_LIVE_DATA_FRAMES'):
            window = app.call('window-state')
            app.call('snapshot', window=window.get('number'), path=os.path.join(os.environ['OPEN_LIVE_DATA_FRAMES'], 'live-folder-intro-window.png'))
        app.call('key', key='escape', route='app')
        results['live_folder_intro_dismiss'] = {'ok': app.call('live-folder-state').get('intro') is None}
        titles = [r['title'] for r in state.get('rows', [])]
        results['live_folder_created_from_space_menu'] = {'ok': menu.get('checked') is False and state.get('exists') and state.get('title') == 'Pull Requests'
            and state.get('pinnedIndex') == state.get('pinnedCount', 0) - 1 and state.get('outcome') == 'success'
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
        # A new PR peeks out of the collapsed folder, with the unread dot (Arc W2).
        app.call('folder-toggle', folder=state['id'])
        gh['prs']['approved'] = [('acme/app', 30, 'Approved and new', 'open')]
        app.call('live-folder-refresh')
        peek = app.call('live-folder-state')
        new_row = next((r for r in peek.get('rows', []) if r['title'] == 'Approved and new'), None)
        results['live_folder_new_row_peeks_out'] = {'ok': peek.get('expanded') is False and bool(new_row) and new_row['unread']
            and peek.get('peeked') == new_row['id'] and app.call('sidebar-row', node=peek['id']).get('unreadBadge') is True, 'state': peek}
        gh['prs']['approved'] = []
        app.call('folder-toggle', folder=state['id'])
        app.call('live-folder-refresh')
        state = app.call('live-folder-state')
        throttled = app.call('live-folder-refresh', manual=False)
        results['live_folder_throttle_10s'] = {'ok': throttled.get('outcome') is None and throttled.get('throttled', 0) >= 1, 'refresh': throttled}
        # L3: the Live Folder's own menu (live-data §2.2).
        gh['prs']['created'] = [('acme/app', 12, 'Fix sidebar drag (v2)', 'open'), ('acme/web', 7, 'Draft: new header', 'draft')]
        app.call('live-folder-refresh')
        state = app.call('live-folder-state')
        folder = state['id']
        def menu_state(path):
            try: return app.call('sidebar-menu-state', node=folder, items=path.split('|') if '|' in path else path.split('/'))
            except Exception as e: return {'error': str(e)}
        repos = {r: menu_state('Repositories|' + r).get('checked') for r in ('acme/app', 'acme/web')}
        items = {t: menu_state(t) for t in ('Refresh', 'Copy All Links', 'Delete Live Folder', 'Single Sign-On/Required',
                                           'Repositories/This list is generated based on your currently active pull requests.')}
        results['live_folder_menu'] = {'ok': repos == {'acme/app': True, 'acme/web': True} and items['Refresh'].get('enabled')
            and items['Delete Live Folder'].get('enabled') and items['Copy All Links'].get('enabled')
            and items['Single Sign-On/Required'].get('title') == 'Required'
            and items['Repositories/This list is generated based on your currently active pull requests.'].get('enabled') is False,
            'repos': repos, 'items': items}
        app.call('sidebar-menu', node=folder, items=['Repositories', 'acme/web'])
        hidden = app.call('live-folder-state')
        app.call('live-folder-refresh')
        after = app.call('live-folder-state')
        results['live_folder_hide_repository'] = {'ok': not any('/acme/web/' in r['url'] for r in hidden['rows'] + after['rows'])
            and after.get('hiddenRepositories') == ['acme/web'] and menu_state('Repositories|acme/web').get('checked') is False, 'after': after}
        app.call('sidebar-menu', node=folder, items=['Repositories', 'acme/web'])
        victim = next(r for r in after['rows'] if r['title'].startswith('Fix sidebar drag'))
        app.call('sidebar-menu', node=victim['id'], item='Remove Pin')  # the user takes the row out of the folder
        app.call('live-folder-refresh')
        after = app.call('live-folder-state')
        results['live_folder_manual_delete_stays_hidden'] = {'ok': victim['live'] in after.get('hiddenItems', [])
            and not any(r['live'] == victim['live'] for r in after['rows']) and any('/acme/web/' in r['url'] for r in after['rows'])
            and app.tab(victim['id'])['section'] == 'today', 'after': after}
        gh['signed_in'] = False
        out = app.call('live-folder-refresh')
        state = app.call('live-folder-state')
        results['live_folder_signed_out_state'] = {'ok': out.get('outcome') == 'signedOut' and state.get('outcome') == 'signedOut' and len(state.get('rows', [])) >= 1,
            'refresh': out, 'state': state}
        tabs_before = {t['id'] for t in app.call('tabs')}
        pressed = app.call('live-folder-state-press')
        opened = wait_until(lambda: [t for t in app.call('tabs') if t['id'] not in tabs_before], timeout=5, step=.1) or []
        results['live_folder_state_glyph'] = {'ok': state.get('stateMessage') == 'Sign back in to GitHub.'
            and (state.get('stateGlyph') or {}).get('tooltip') == 'Sign back in to GitHub.' and pressed.get('pressed')
            and any(t['url'].startswith('http://github.localhost:%d/login' % port) for t in opened), 'state': state, 'opened': opened}
        for t in opened: app.call('close', tab=t['id'])
        gh['signed_in'] = True
        # The folder's settings and rows survive a relaunch (snapshot DTO fields).
        before = {(r['url'], r['live']) for r in state.get('rows', [])}
        app.quit()
        app = holder['app'] = factory(urls=(), fresh=False)
        app.call('live-folder-origin', url='http://github.localhost:%d' % port)
        again = app.call('live-folder-state')
        results['live_folder_survives_relaunch'] = {'ok': again.get('exists') and again.get('outcome') == 'signedOut'
            and {(r['url'], r['live']) for r in again.get('rows', [])} == before
            and bool(wait_until(lambda: app.call('live-folder-refresh').get('outcome') == 'success', timeout=15, step=.5)),
            'state': again}
        # Signing in on GitHub (a tab leaves the sign-in page) refetches the folder without a manual
        # Refresh (live-data §2.4 item 4, Arc `githubUserSignedIn`).
        gh['signed_in'] = False
        app.call('live-folder-refresh')
        signed_out = app.call('live-folder-state')
        login = new_tab(app, 'http://github.localhost:%d/login' % port)
        gh['signed_in'] = True
        base_refreshes = signed_out.get('signInRefreshes', 0)
        app.call('navigate', tab=login, url='http://github.localhost:%d/' % port); app.call('wait', tab=login)
        signed_in = wait_until(lambda: (lambda s: s if s.get('outcome') == 'success' else None)(app.call('live-folder-state')), timeout=15, step=.2) or app.call('live-folder-state')
        results['live_folder_refetch_on_sign_in'] = {'ok': signed_out.get('outcome') == 'signedOut' and signed_in.get('outcome') == 'success'
            and signed_in.get('signInRefreshes', 0) == base_refreshes + 1, 'before': signed_out.get('outcome'), 'after': signed_in.get('outcome'),
            'signInRefreshes': signed_in.get('signInRefreshes')}
        app.call('close', tab=login)
        app.call('sidebar-menu', item='Live Folders/GitHub')
        gone = app.call('live-folder-state')
        app.call('sidebar-menu', item='Live Folders/GitHub')
        second = app.call('live-folder-state', wait=True)
        app.call('sidebar-menu', item='Live Folders/GitHub')
        results['live_folder_intro_once'] = {'ok': second.get('exists') and second.get('intro') is None, 'state': {'intro': second.get('intro')}}
        gone = app.call('live-folder-state')
        results['live_folder_toggle_off_removes'] = {'ok': gone.get('exists') is False and app.call('sidebar-menu-state', item='Live Folders/GitHub').get('checked') is False, 'state': gone}
        # Auto-create: compare page → new PR page in a tab of this Space (Arc pullRequestCreated).
        gh['prs'] = {'created': [('acme/app', 77, 'Brand new PR', 'open')]}
        pr_tab = new_tab(app, 'http://github.localhost:%d/acme/app/compare/main...feature' % port)
        app.call('navigate', tab=pr_tab, url='http://github.localhost:%d/acme/app/pull/77' % port); app.call('wait', tab=pr_tab)
        made = app.call('live-folder-state', wait=True)
        moved = next((r for r in made.get('rows', []) if r['id'] == pr_tab), None)
        results['live_folder_auto_create_on_pr'] = {'ok': made.get('exists') and made.get('autoCreated') == 1 and bool(moved)
            and moved['live'] == 'http://github.localhost:%d/acme/app/pull/77' % port and len(made['rows']) == 1, 'state': made}
        # Delete Live Folder: Arc's alert, then automatic creation stays off.
        app.call('sidebar-menu', node=made['id'], item='Delete Live Folder')
        alert = app.call('alert'); app.call('alert', button='Delete Folder')
        gone = app.call('live-folder-state')
        other = new_tab(app, 'http://github.localhost:%d/acme/app/compare/main...other' % port)
        app.call('navigate', tab=other, url='http://github.localhost:%d/acme/app/pull/78' % port); app.call('wait', tab=other)
        results['live_folder_delete_alert_turns_off_auto'] = {'ok': 'Delete your GitHub Live Folder?' in alert.get('texts', [])
            and 'You can restore this folder at any time by right-clicking the sidebar.' in alert.get('texts', [])
            and set(alert.get('buttons', [])) >= {'Delete Folder', 'Cancel'} and gone.get('exists') is False
            and app.call('live-folder-state').get('exists') is False
            and app.call('defaults', key='open.liveFolders.githubAutoCreate') is False, 'alert': alert}
        return app
    finally:
        try:
            for key in ('open.liveFolders.introSeen', 'open.liveFolders.githubAutoCreate'):
                holder['app'].call('defaults', key=key, value=None)
        except Exception:
            pass
        server.shutdown()


def gmail_fixture():
    """Loopback stand-in for mail.google.com's Atom feed (synthetic mail only).
    state: {'signed_in': bool, 'mail': [(subject, author, iso time)]}."""
    import http.server, threading, html
    state = {'signed_in': True, 'mail': [], 'requests': []}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split('?')[0]; host = (self.headers.get('Host') or '').split(':')[0]
            state['requests'].append((host, path))
            port = self.server.server_address[1]
            if host == 'mail.localhost' and path.endswith('/feed/atom'):
                if not state['signed_in']:
                    self.send_response(302); self.send_header('Location', 'http://accounts.localhost:%d/signin' % port)
                    self.send_header('Content-Length', '0'); self.end_headers(); return
                entries = ''.join('<entry><title>%s</title><link rel="alternate" href="http://mail.localhost:%d/mail/u/0/?msg=%d" type="text/html"/>'
                                  '<issued>%s</issued><author><name>%s</name><email>x@example.com</email></author></entry>'
                                  % (html.escape(t), port, i, d, html.escape(a)) for i, (t, a, d) in enumerate(state['mail']))
                body = ('<?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#">'
                        '<title>Inbox</title><fullcount>%d</fullcount>%s</feed>' % (len(state['mail']), entries)).encode()
                kind = 'application/atom+xml; charset=utf-8'
            else:
                body = b'<!doctype html><title>Mail fixture</title><p>Mail fixture'
                kind = 'text/html; charset=utf-8'
            self.send_response(200); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1], state


def gmail_checks(app, results, wait_until, new_tab, recents_aliases):
    server, port, mail = gmail_fixture()
    def hover(node, ms=800):
        app.call('hover', leave=True, ms=300)
        return app.call('hover', node=node, ms=ms)
    try:
        cases = {'https://mail.google.com/mail/u/1/#inbox': 1, 'https://mail.google.com/mail/#inbox': 0, 'https://accounts.google.com/': None,
                 'https://mail.google.com/chat/': None}
        got = {u: app.call('glance-match', url=u).get('account') for u in cases}
        results['live_gmail_host_match'] = {'ok': got == cases, 'got': got}
        app.call('glance-alias', aliases=recents_aliases, mail=['mail.localhost'])
        mail['mail'] = [('Quarterly numbers', 'Ada', '2026-11-12T09:00:00Z'), ('Lunch?', 'Grace', '2026-11-12T08:00:00Z')]
        inbox = new_tab(app, 'http://mail.localhost:%d/mail/u/0/#inbox' % port)
        app.call('pin', tab=inbox)
        other = new_tab(app, 'http://plain.localhost:%d/elsewhere' % port)
        app.call('select', tab=other)
        shown = hover(inbox)
        state = app.call('glance-state')
        results['live_gmail_card_rows'] = {'ok': shown['kind'] == 'glance' and state.get('kind') == 'gmail' and state.get('phase') == 'mail'
            and [r['title'] for r in state.get('rows', [])] == ['Quarterly numbers', 'Lunch?'] and state['rows'][0]['author'] == 'Ada'
            and state.get('header') == 'Unread' and state.get('newLabel') == 'New Email'
            and state.get('newURL') == 'http://mail.localhost:%d/mail/u/0/#compose' % port, 'state': state, 'hover': shown}
        app.call('glance-open', row=1)
        peek = wait_until(lambda: (lambda s: s if s.get('shown') and s['stack'] and s['stack'][-1]['content'] > 0 else None)(app.call('peek-state')), timeout=5, step=.05)
        href = ''
        if peek:
            app.call('wait', tab=peek['stack'][-1]['content']); href = app.eval(peek['stack'][-1]['content'], 'location.href')
        results['live_gmail_row_opens_peek'] = {'ok': href == 'http://mail.localhost:%d/mail/u/0/?msg=1' % port, 'href': href}
        app.call('peek-close'); wait_until(lambda: not app.call('peek-state').get('shown'), timeout=5, step=.05)
        app.call('select', tab=other)
        mail['mail'] = []
        hover(inbox); empty = app.call('glance-state')
        results['live_gmail_empty'] = {'ok': empty.get('phase') == 'empty' and empty.get('message') == 'No unread emails, you can exhale! 🍃'
            and empty.get('rows') == [], 'state': empty}
        mail['signed_in'] = False
        hover(inbox); out = app.call('glance-state')
        results['live_gmail_signed_out'] = {'ok': out.get('phase') == 'signedOut'
            and out.get('message') == 'Sign in to your Email to see messages at a glance.', 'state': out}
        mail['signed_in'] = True
        app.call('defaults', key='open.general.previewsGmail', value=False)
        off = hover(inbox)
        app.call('defaults', key='open.general.previewsGmail', value=None)
        results['live_gmail_switch_off_gives_page_card'] = {'ok': off['kind'] == 'page', 'hover': off}
        app.call('hover', leave=True, ms=300)
    finally:
        server.shutdown()


def live_folder_import_checks(app, results, wait_until, tmp, harness):
    """L7: Import from Arc brings an Arc Live Folder (settings + PR rows) and Arc's two Live Folder
    preferences. Synthetic Arc home: <home>/Library/Application Support/Arc + Preferences plist."""
    import json, plistlib, runpy, uuid
    from pathlib import Path
    home = Path(tmp) / 'arc-live-home'
    arc = home / 'Library' / 'Application Support' / 'Arc'
    arc.mkdir(parents=True, exist_ok=True)
    ids = runpy.run_path(str(Path(harness['ROOT']) / 'tools' / 'e2e' / 'firstrun.py'))['fixture'](arc)
    sidebar = json.loads((arc / 'StorableSidebar.json').read_text())
    items = sidebar['sidebar']['containers'][1]['items']
    def new_id(name): return str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/lf-l7/' + name)).upper()
    live_id, pr1, pr2 = new_id('live'), new_id('pr1'), new_id('pr2')
    for key, url, title in ((pr1, 'https://github.com/acme/app/pull/12', 'Fix sidebar drag'), (pr2, 'https://github.com/acme/web/pull/7', 'New header')):
        items.extend([key, dict(id=key, data={'tab': dict(savedURL=url, savedTitle=title)}, childrenIds=[], title=title)])
    items.extend([live_id, dict(id=live_id, title='Pull Requests', childrenIds=[pr1, pr2], data={'list': {'automaticLiveFolderData': {
        'dataSource': {'github': {}}, 'hiddenItems': [{'url': {'_0': 'https://github.com/acme/app/pull/3'}}],
        'filter': {'github': {'attributes': 15, 'hiddenRepositories': [{'owner': 'acme', 'name': 'old'}]}},
        'lastFetch': {'timestamp': 0, 'status': {'success': {}}}}}})])
    for i in range(0, len(items), 2):
        if items[i] == ids['beta'] or (isinstance(items[i + 1], dict) and items[i + 1].get('id') == ids['pb']):
            items[i + 1]['childrenIds'].append(live_id)
    (arc / 'StorableSidebar.json').write_text(json.dumps(sidebar))
    prefs_dir = home / 'Library' / 'Preferences'; prefs_dir.mkdir(parents=True, exist_ok=True)
    with open(prefs_dir / 'company.thebrowser.Browser.plist', 'wb') as f:
        plistlib.dump({'hasTurnedOffGithubLiveFolder': True, 'hasSeenGithubLiveFolderEducation': True}, f, fmt=plistlib.FMT_BINARY)
    keys = ('open.liveFolders.githubAutoCreate', 'open.liveFolders.introSeen')
    for key in keys: app.call('defaults', key=key, value=None)
    state = lambda: app.call('first-run')
    app.call('first-run', action='settings-import', directory=str(arc))
    app.call('first-run', action='settings-next')
    app.call('first-run', action='settings-run')
    report = wait_until(lambda: (lambda s: s if s.get('settingsStep') == 'report' else None)(state()), timeout=60, step=.05) or state()
    try: app.call('first-run', action='settings-done')
    except RuntimeError: pass
    beta = next((s for s in app.call('spaces') if s['title'] == 'Beta'), None)
    folder = app.call('live-folder-state', space=beta['id']) if beta else {}
    rows = {r['url']: r['live'] for r in folder.get('rows', [])}
    prefs = {k: app.call('defaults', key=k) for k in keys}
    results['live_folder_arc_import'] = {'ok': bool(beta) and folder.get('exists') and folder.get('title') == 'Pull Requests'
        and rows == {'https://github.com/acme/app/pull/12': 'https://github.com/acme/app/pull/12', 'https://github.com/acme/web/pull/7': 'https://github.com/acme/web/pull/7'}
        and folder.get('hiddenItems') == ['https://github.com/acme/app/pull/3'] and folder.get('hiddenRepositories') == ['acme/old']
        and prefs == {'open.liveFolders.githubAutoCreate': False, 'open.liveFolders.introSeen': True},
        'folder': folder, 'prefs': prefs, 'report': {k: report.get(k) for k in ('lastOutcome', 'lastFailures', 'arcPreferences')}}
    # Undo the import: the folder and the two settings go back.
    app.call('sidebar-key', key='z', modifiers=['command'])
    wait_until(lambda: not state().get('importUndoInProgress', False), timeout=30, step=.05)
    undone = wait_until(lambda: (lambda v: v if v == {k: None for k in keys} else None)({k: app.call('defaults', key=k, persistent=True) for k in keys}), timeout=10, step=.1)
    results['live_folder_arc_import_undo'] = {'ok': undone is not None and not any(s['title'] == 'Beta' and app.call('live-folder-state', space=s['id']).get('exists') for s in app.call('spaces')),
        'prefs': {k: app.call('defaults', key=k, persistent=True) for k in keys}}


def run(factory, results, tmp, harness):
    new_tab, wait_until = harness['new_tab'], harness['wait_until']
    server, port = harness['_sleep_server']()
    app = factory(urls=(), fresh=True)
    holder = {'app': app}
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
        # The snapshot above re-lays out the window; on a real screen AppKit then recomputes the
        # row's tracking areas from the REAL pointer (not over the row on the M1), which ends the
        # hover and hides the card. That is correct for a user; the Peek check hovers again.
        survived = app.call('glance-state', wait=False).get('shown') is True
        if not survived:
            hover(linear)
            # Under load the card can show after the hover's 800 ms read (one suite error on a
            # loaded rented Mac: "glance-open: no Recents card"). Wait for it before opening a row.
            wait_until(lambda: app.call('glance-state').get('shown') is True, timeout=3, step=.05)
        results['live_recents_card_after_snapshot'] = {'ok': True, 'info': 'card survived the window snapshot: %s' % survived}
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
        # The page card shows after the hover delay; under load it can land after the 800 ms read
        # (one FAIL on a loaded rented Mac). Wait for the shown card; a glance card still fails.
        if off['kind'] == 'none':
            off = wait_until(lambda: (lambda st: st if st['kind'] != 'none' else None)(app.call('preview-state')), timeout=3, step=.05) or off
        results['live_recents_switch_off_gives_page_card'] = {'ok': off['kind'] == 'page' and app.call('glance-state').get('shown') is False, 'hover': off}
        app.call('defaults', key='open.general.previewsPages', value=False)
        none = hover(linear)
        app.call('defaults', key=key, value=None)
        on = hover(linear)
        results['live_recents_own_switch'] = {'ok': none['kind'] == 'none' and on['kind'] == 'glance', 'off': none, 'on': on}
        app.call('defaults', key='open.general.previewsPages', value=None)
        app.call('hover', leave=True, ms=400)
        results['live_recents_hides_on_leave'] = {'ok': app.call('glance-state').get('shown') is False}
        gmail_checks(app, results, wait_until, new_tab, {'recents.localhost': 'linear', 'empty.localhost': 'notion', 'today.localhost': 'figma'})
        live_folder_import_checks(app, results, wait_until, tmp, harness)
        holder['app'] = app
        app = live_folder_checks(holder, results, wait_until, factory, new_tab)
    finally:
        app = holder['app']
        try:
            app.call('glance-alias', aliases={})
        finally:
            app.quit()
            server.shutdown()
