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
    {'signed_in': bool, 'prs': {kind_marker: [(owner/repo, number, title, status)]},
     'sso': None (no banner) or a list of hrefs in its banner}."""
    import http.server, threading, html, urllib.parse
    state = {'signed_in': True, 'prs': {}, 'requests': [], 'sso': None, 'fetch_gate': None}
    markers = {'author:@me': 'created', 'review-requested:@me': 'review', 'review:approved': 'approved', 'review:changes_requested': 'changes'}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            state['requests'].append(parsed.path)
            if parsed.path == '/pulls' and state.get('redirect'):
                self.send_response(302); self.send_header('Location', state['redirect']); self.send_header('Content-Length', '0'); self.end_headers(); return
            if parsed.path == '/pulls' and not state['signed_in']:
                self.send_response(302); self.send_header('Location', '/login?return_to=%2Fpulls'); self.send_header('Content-Length', '0'); self.end_headers(); return
            if parsed.path == '/login':
                body = '<!doctype html><title>Sign in</title><form action="/session" method="post"><input name="login"></form>'
            elif parsed.path in ('/pulls', '/elsewhere-pulls'):
                gate = state['fetch_gate']
                if gate is not None: gate.wait(timeout=10)
                query = urllib.parse.parse_qs(parsed.query).get('q', [''])[0]
                kind = next((v for k, v in markers.items() if k in query), '')
                rows = state['prs'].get(kind, [])
                items = ''.join('<li data-pr-row data-pr-state="%s" data-pr-author="octo"><a class="Link--primary" href="/%s/pull/%d">%s</a>'
                                '<relative-time datetime="2026-11-1%dT10:00:00Z"></relative-time></li>' % (st, repo, n, html.escape(t), n % 10)
                                for repo, n, t, st in rows)
                body = '<!doctype html><title>Pull requests</title><ul>%s%s</ul>%s' % (items, state.get('extra') or '', '' if rows else '<div class="blankslate">No results</div>')
                if state['sso'] is not None:
                    body += '<div data-testid="global-sso-banner">%s</div>' % ''.join(
                        '<a href="%s">Authorize organization</a>' % html.escape(href, quote=True) for href in state['sso'])
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
        # C-LF-1 (Open's design, live-data §8): each row stores its PR facts and draws Open's PR-state
        # glyph instead of the favicon; hovering a row shows the PR card (no fetch).
        def by_number(st): return {r['number']: r for r in st.get('rows', [])}
        glyphs = wait_until(lambda: (lambda st: st if {r['number']: r['glyph'] for r in st.get('rows', [])}
            == {12: 'pullRequest.open', 7: 'pullRequest.draft', 15: 'pullRequest.open'} else None)(app.call('live-folder-state')), timeout=5, step=.1)
        facts = by_number(glyphs or app.call('live-folder-state'))
        plain = [t for t in app.call('tabs') if not any(t['id'] == r['id'] for r in facts.values())]
        results['live_folder_row_glyphs'] = {'ok': bool(glyphs)
            and (facts[12]['status'], facts[12]['repository'], facts[12]['author'], facts[12]['awaitingMyReview']) == ('open', 'acme/app', 'octo', True)
            and (facts[7]['status'], facts[7]['repository'], facts[7]['awaitingMyReview']) == ('draft', 'acme/web', False)
            and (facts[15]['status'], facts[15]['awaitingMyReview']) == ('open', True)
            and bool(plain) and not any(t.get('rowFaviconSource', '').startswith('pullRequest') for t in plain),
            'rows': facts, 'negative': {t['id']: t.get('rowFaviconSource') for t in plain}}
        def pr_card(row):
            app.call('hover', leave=True, ms=300)
            app.call('hover', node=row['id'], ms=800)
            return wait_until(lambda: (lambda g: g if g.get('kind') == 'pullRequest' and g.get('tab') == row['id'] else None)(app.call('glance-state')), timeout=3, step=.05) or app.call('glance-state')
        review_card = pr_card(facts[15])
        if os.environ.get('OPEN_LIVE_DATA_FRAMES') and review_card.get('kind') == 'pullRequest':
            for name in ('light', 'dark'):
                app.call('appearance', name=name); time.sleep(.6)
                review_card = pr_card(facts[15])
                app.call('snapshot', window=app.call('window-state').get('number'),
                         path=os.path.join(os.environ['OPEN_LIVE_DATA_FRAMES'], 'live-folder-pr-card-%s.png' % name))
            app.call('appearance', name='system')
            review_card = pr_card(facts[15])
        draft_card = pr_card(facts[7])
        app.call('hover', leave=True, ms=300)
        results['live_folder_pr_card'] = {'ok': review_card.get('title') == 'Add Live Folders' and review_card.get('subtitle') == '#15 · acme/app'
            and review_card.get('reviewLine') == 'octo needs your review' and review_card.get('status') == 'open'
            and review_card.get('card', [0, 0, 0])[2] == 240
            and draft_card.get('title') == 'Draft: new header' and draft_card.get('subtitle') == '#7 · acme/web'
            and draft_card.get('reviewLine') is None and draft_card.get('status') == 'draft',
            'review': review_card, 'draft': draft_card, 'negative': 'no review line on a PR that does not await my review'}
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
        facts_before = {r['url']: (r['status'], r['number'], r['repository'], r['awaitingMyReview']) for r in state.get('rows', [])}
        app.quit()
        app = holder['app'] = factory(urls=(), fresh=False, extra_env={'OPEN_AUTOMATION_GITHUB_ORIGIN': 'http://github.localhost:%d' % port})
        app.call('live-folder-origin', url='http://github.localhost:%d' % port)
        again = app.call('live-folder-state')
        # C-LF-1: the PR facts are stored with the row, so the glyph is right before any refresh.
        facts_again = {r['url']: (r['status'], r['number'], r['repository'], r['awaitingMyReview']) for r in again.get('rows', [])}
        results['live_folder_pr_facts_survive_relaunch'] = {'ok': bool(facts_before) and all(f[0] for f in facts_before.values())
            and facts_again == facts_before, 'before': facts_before, 'after': facts_again}
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
        # C-LF-2: Open's design is ten PR rows, then the actual sidebar Show More control.
        gh['prs'] = {'created': [('acme/app', n, 'Pull request %d' % n, 'open') for n in range(100, 113)]}
        app.call('sidebar-menu', item='Live Folders/GitHub')
        long_folder = app.call('live-folder-state', wait=True)
        def exposed(st): return [r['id'] for r in st.get('rows', []) if r.get('exposed')]
        limited = wait_until(lambda: (lambda s: s if len(exposed(s)) == 10 and s.get('showMore') else None)(app.call('live-folder-state')), timeout=3, step=.05) or long_folder
        results['live_folder_show_more_limit'] = {'ok': len(limited.get('rows', [])) == 13 and len(exposed(limited)) == 10
            and (limited.get('showMore') or {}).get('title') == 'Show More', 'state': limited}
        if os.environ.get('OPEN_LIVE_DATA_FRAMES'):
            for name in ('light', 'dark'):
                app.call('appearance', name=name)
                app.call('live-folder-state', revealMore=True); time.sleep(.3)
                app.call('snapshot', window=app.call('window-state').get('number'),
                         path=os.path.join(os.environ['OPEN_LIVE_DATA_FRAMES'], 'live-folder-show-more-%s.png' % name))
            app.call('appearance', name='system')
        fetches = limited.get('fetchPagesCreated')
        pressed = app.call('live-folder-show-more')
        revealed = wait_until(lambda: (lambda s: s if len(exposed(s)) == 13 and s.get('showMore') is None else None)(app.call('live-folder-state')), timeout=3, step=.05) or app.call('live-folder-state')
        results['live_folder_show_more_reveals_without_fetch'] = {'ok': pressed.get('pressed') is True and len(exposed(revealed)) == 13
            and revealed.get('showMore') is None and revealed.get('fetchPagesCreated') == fetches, 'pressed': pressed, 'state': revealed}
        app.call('folder-toggle', folder=long_folder['id'])
        app.call('folder-toggle', folder=long_folder['id'])
        reset = wait_until(lambda: (lambda s: s if len(exposed(s)) == 10 and s.get('showMore') else None)(app.call('live-folder-state')), timeout=3, step=.05) or app.call('live-folder-state')
        results['live_folder_show_more_resets_on_collapse'] = {'ok': len(exposed(reset)) == 10 and bool(reset.get('showMore')), 'state': reset}
        gh['prs']['created'] = gh['prs']['created'][:10]
        app.call('live-folder-refresh')
        boundary = app.call('live-folder-state')
        gh['prs']['created'] = []
        app.call('live-folder-refresh')
        empty = app.call('live-folder-state')
        results['live_folder_show_more_boundary_and_empty'] = {'ok': len(exposed(boundary)) == 10 and boundary.get('showMore') is None
            and empty.get('rows') == [] and empty.get('showMore') is None and app.call('live-folder-show-more').get('pressed') is False,
            'boundary': boundary, 'empty': empty}
        # C-LF-3: fetch the real banner, build the real menu, and deliver its NSMenu action.
        # The checked state reports the fetch. Pressing it must not toggle a preference.
        folder = long_folder['id']
        origin = 'http://github.localhost:%d' % port
        def sso_menu(): return app.call('sidebar-menu-state', node=folder, items=['Single Sign-On', 'Required'])
        def press_sso():
            try:
                app.call('sidebar-menu', node=folder, items=['Single Sign-On', 'Required'])
                return True
            except Exception:
                return False
        gh['sso'] = ['/orgs/acme/sso/?return_to=private#ignored']
        sso_refresh = app.call('live-folder-refresh')
        sso_state, checked = app.call('live-folder-state'), sso_menu()
        owner = next(s for s in app.call('spaces') if s['focused'])
        prefs = {k: app.call('defaults', key=k) for k in ('open.liveFolders.githubAutoCreate', 'open.liveFolders.introSeen')}
        tabs_before = {t['id'] for t in app.call('tabs')}
        pressed = press_sso()
        opened = wait_until(lambda: [t for t in app.call('tabs') if t['id'] not in tabs_before], timeout=3, step=.05) or []
        results['live_folder_sso_menu_opens_org'] = {'ok': sso_refresh.get('outcome') == 'needsSSO'
            and sso_state.get('ssoURL') == origin + '/orgs/acme/sso' and checked.get('checked') and checked.get('enabled') and pressed
            and len(opened) == 1 and opened[0]['url'] == origin + '/orgs/acme/sso'
            and opened[0]['space'] == owner['id'] and opened[0]['profile'] == owner['profile']
            and sso_menu().get('checked') and prefs == {k: app.call('defaults', key=k) for k in prefs},
            'state': sso_state, 'menu': checked, 'opened': opened}
        for t in opened: app.call('close', tab=t['id'])
        # Boundary inputs travel through page extraction and the native service, not a parser helper.
        base_link = origin + '/orgs/a/sso?x='
        cases = [
            ('slug_39', ['/orgs/' + 'a' * 39 + '/sso'], origin + '/orgs/' + 'a' * 39 + '/sso'),
            ('slug_40', ['/orgs/' + 'a' * 40 + '/sso'], None),
            ('url_2048', [base_link + 'a' * (2048 - len(base_link))], origin + '/orgs/a/sso'),
            ('url_2049', [base_link + 'a' * (2049 - len(base_link))], None),
            ('link_20', ['/settings'] * 19 + ['/orgs/twenty/sso'], origin + '/orgs/twenty/sso'),
            ('link_21', ['/settings'] * 20 + ['/orgs/twentyone/sso'], None),
            ('cross_origin', ['https://example.invalid/orgs/acme/sso'], None),
            ('credentials', [origin.replace('://', '://user:pass@') + '/orgs/acme/sso'], None),
            ('bad_slug', ['/orgs/-bad/sso'], None),
            ('wrong_path', ['/orgs/acme/settings'], None),
            ('missing_link', [], None),
        ]
        boundaries = []
        for name, links, expected in cases:
            gh['sso'] = links
            fetched = app.call('live-folder-refresh')
            st, mi = app.call('live-folder-state'), sso_menu()
            tab_ids = {t['id'] for t in app.call('tabs')}
            refused = not press_sso() if expected is None else True
            boundaries.append({'case': name, 'ok': fetched.get('outcome') == 'needsSSO' and st.get('ssoURL') == expected
                and mi.get('checked') is True and mi.get('enabled') == (expected is not None)
                and refused and tab_ids == {t['id'] for t in app.call('tabs')}, 'menu': mi, 'ssoURL': st.get('ssoURL')})
        results['live_folder_sso_url_boundaries'] = {'ok': all(c['ok'] for c in boundaries), 'cases': boundaries}
        gh['sso'] = ['/orgs/acme/sso']
        app.call('live-folder-refresh')
        # The saved last-fetch state can say SSO, but a URL is never restored from disk.
        app.quit()
        import threading
        gate = gh['fetch_gate'] = threading.Event()
        try:
            app = holder['app'] = factory(urls=(), fresh=False, extra_env={'OPEN_AUTOMATION_GITHUB_ORIGIN': origin})
            app.call('live-folder-origin', url=origin)
            # Hold any automatic fetch at the fixture while inspecting the restored model.
            restored, restored_menu = app.call('live-folder-state'), sso_menu()
        finally:
            gh['fetch_gate'] = None
            gate.set()
        results['live_folder_sso_link_is_transient'] = {'ok': restored.get('outcome') == 'needsSSO'
            and restored.get('ssoURL') is None and restored_menu.get('checked') and not restored_menu.get('enabled'),
            'state': restored, 'menu': restored_menu}
        gh['sso'] = None
        # A refresh may already be running after activation. Wait for its 20 s native
        # deadline, then a completed fixture refresh; a busy reply is not a result.
        cleared = wait_until(lambda: (lambda r: r if r.get('outcome') == 'success' else None)(app.call('live-folder-refresh')),
                             timeout=30, step=.1) or {}
        clean, clean_menu = app.call('live-folder-state'), sso_menu()
        results['live_folder_sso_clears_after_success'] = {'ok': cleared.get('outcome') == 'success' and clean.get('ssoURL') is None
            and not clean_menu.get('checked') and not clean_menu.get('enabled') and not press_sso(), 'state': clean, 'menu': clean_menu}
        def refreshed(expect):
            # A busy reply (another refresh in flight) is not a result.
            return wait_until(lambda: (lambda r: r if r.get('outcome') == expect else None)(app.call('live-folder-refresh')),
                              timeout=30, step=.1) or {}
        def live_urls(): return {r['live'] for r in app.call('live-folder-state').get('rows', []) if r.get('live')}
        # Bug sweep R2 (seed-livedata #3): an SSO banner means GitHub hid some organization's PRs. A row
        # missing from that partial result stays; only a complete result removes it.
        trio = [('acme/app', n, 'SSO row %d' % n, 'open') for n in (201, 202, 203)]
        gh['prs'] = {'created': trio}
        full = refreshed('success'); before_sso = live_urls()
        gh['prs'] = {'created': trio[:1]}; gh['sso'] = ['/orgs/acme/sso']
        partial = refreshed('needsSSO'); during_sso = live_urls()
        gh['sso'] = None
        complete = refreshed('success'); after_sso = live_urls()
        results['live_folder_sso_keeps_missing_rows'] = {'ok': full.get('outcome') == 'success' and len(before_sso) == 3
            and partial.get('outcome') == 'needsSSO' and during_sso == before_sso
            and complete.get('outcome') == 'success' and len(after_sso) == 1 and after_sso < before_sso,
            'before': sorted(before_sso), 'duringSSO': sorted(during_sso), 'after': sorted(after_sso)}
        # Bug sweep r3 E15: one malformed /pull/ link used to throw and fail the whole refresh; a
        # link to another origin used to become a row on the GitHub origin.
        gh['extra'] = ('<li><a href="http://[/acme/app/pull/301">Malformed link</a></li>'
                       '<li><a href="https://elsewhere.invalid/evil/repo/pull/302">Cross-origin link</a></li>')
        try:
            odd = refreshed('success'); odd_urls = live_urls()
        finally:
            gh['extra'] = None
        results['live_folder_odd_links_skipped'] = {'ok': odd.get('outcome') == 'success'
            and odd_urls == {'http://github.localhost:%d/acme/app/pull/201' % port}, 'refresh': odd, 'rows': sorted(odd_urls)}
        # Review r1 item 6: the pulls page redirects to another origin (an interstitial). Its PR-shaped
        # links used to replace the rows; the refresh must fail and keep the rows.
        gh['prs'] = {'created': [('evil/repo', 401, 'Redirected row', 'open')]}
        gh['redirect'] = 'http://elsewhere.localhost:%d/elsewhere-pulls?q=author:@me' % port
        try:
            redirected = refreshed('failed'); redirected_urls = live_urls()
        finally:
            gh['redirect'] = None
        results['live_folder_offorigin_redirect_fails'] = {'ok': redirected.get('outcome') == 'failed' and redirected_urls == odd_urls,
            'refresh': redirected, 'rows': sorted(redirected_urls)}
        gh['prs'] = {'created': []}
        refreshed('success')
        # Bug sweep R2 (seed-livedata #12): the user drags the Live Folder into another Pinned folder. The Space
        # still finds it: a refresh runs, the Space menu shows it on, and the toggle removes it (no second folder).
        space = next(s for s in app.call('spaces') if s['focused'])['id']
        holder_tab = new_tab(app, 'about:blank')
        wrapper = app.call('folder', tabs=[holder_tab], title='LF wrapper', section='pinned')
        lf = app.call('live-folder-state', space=space)
        dropped = app.call('sidebar-drop', nodes=[lf['id']], parent={'kind': 'folder', 'id': wrapper}, index=0)
        nested = app.call('live-folder-state', space=space)
        gh['prs'] = {'created': trio[:2]}
        try:
            nested_refresh = refreshed('success') if nested.get('exists') else {}
        finally:
            gh['prs'] = {'created': []}
        nested_rows = len(app.call('live-folder-state', space=space).get('rows', []))
        menu_on = app.call('sidebar-menu-state', item='Live Folders/GitHub').get('checked')
        app.call('sidebar-menu', item='Live Folders/GitHub')
        after_toggle = app.call('live-folder-state', space=space)
        menu_off = app.call('sidebar-menu-state', item='Live Folders/GitHub').get('checked')
        results['live_folder_nested_refresh_and_toggle'] = {'ok': bool(dropped) and nested.get('exists') is True
            and nested.get('id') == lf['id'] and nested.get('pinnedIndex') == -1 and nested_refresh.get('outcome') == 'success'
            and nested_rows == 2 and menu_on is True and after_toggle.get('exists') is False and menu_off is False,
            'dropped': dropped, 'nested': {k: nested.get(k) for k in ('exists', 'id', 'pinnedIndex')}, 'refresh': nested_refresh,
            'rows': nested_rows, 'menuOn': menu_on, 'afterToggle': after_toggle.get('exists'), 'menuOff': menu_off}
        app.call('close', tab=holder_tab)
        # Bug sweep round 4. A fresh top-level folder with two PR rows.
        app.call('sidebar-menu', item='Live Folders/GitHub')
        gh['prs'] = {'created': trio[:2]}
        r4 = app.call('live-folder-state', wait=True)
        r4_rows = refreshed('success') and app.call('live-folder-state').get('rows', [])
        gh_prs_r4 = gh['prs']
        # SB-05: a PR row dragged out of the Live Folder (the outline's drop: moveNodes) leaves it for
        # good, as Remove Pin does: its PR URL is hidden and a refresh does not add it back.
        dragged = r4_rows[0] if r4_rows else {}
        today = next(s for s in app.call('spaces') if s['focused'])['id']
        dragged_ok = bool(dragged) and app.call('sidebar-drop', nodes=[dragged['id']], parent={'kind': 'today', 'id': today}, index=0)
        refreshed('success')
        after_drag = app.call('live-folder-state')
        copies = [r for r in after_drag.get('rows', []) if r.get('live') == dragged.get('live')]
        results['live_folder_drag_out_stays_out'] = {'ok': bool(dragged_ok) and len(r4_rows) == 2 and not copies
            and dragged.get('live') in after_drag.get('hiddenItems', []) and app.tab(dragged['id'])['section'] == 'today',
            'dragged': dragged.get('live'), 'copies': len(copies), 'hidden': after_drag.get('hiddenItems'), 'rows': len(after_drag.get('rows', []))}
        # Bug sweep round 5 (item 2): New Folder with a PR row and a split with a PR row also take it
        # out for good (they moved it without the Live Folder note, so a refresh added it back).
        gh['prs'] = {'created': trio}
        r5_rows = refreshed('success') and app.call('live-folder-state').get('rows', [])
        r5_out = {}
        if len(r5_rows) >= 2:
            app.call('folder', tabs=[r5_rows[0]['id']], title='R5 out')
            holder5 = new_tab(app, 'about:blank'); app.call('select', tab=holder5)
            x, y, w, height = app.call('split', op='state')['container']
            r5_split = app.call('split', op='drop', node=r5_rows[1]['id'], point=[x+w-12, y+height/2]).get('accepted')
            refreshed('success')
            after5 = app.call('live-folder-state')
            for label, row in (('newFolder', r5_rows[0]), ('split', r5_rows[1])):
                r5_out[label] = dict(live=row['live'], copies=len([r for r in after5.get('rows', []) if r.get('live') == row['live']]),
                                     hidden=row['live'] in after5.get('hiddenItems', []))
            r5_out['splitAccepted'] = r5_split
            app.call('split', op='menu', item='Separate All Tabs') if app.call('split', op='state')['id'] else None
            app.call('close', tab=holder5)
        results['live_folder_new_folder_and_split_take_row_out'] = {'ok': len(r5_rows) >= 2 and r5_out.get('splitAccepted') is True
            and all(r5_out[k]['copies'] == 0 and r5_out[k]['hidden'] for k in ('newFolder', 'split')), 'rows': len(r5_rows), 'out': r5_out}
        # Bug sweep round 5 (item 1): deleting a regular folder that holds the Live Folder removes the
        # Live Folder (not archived with the folder) and turns automatic creation off.
        app.call('defaults', key='open.liveFolders.githubAutoCreate', value=True)
        r5_lf = app.call('live-folder-state')['id']
        r5_wrap_tab = new_tab(app, 'about:blank')
        r5_wrap = app.call('folder', tabs=[r5_wrap_tab], title='R5 wrapper')
        r5_nested = app.call('sidebar-drop', nodes=[r5_lf], parent={'kind': 'folder', 'id': r5_wrap}, index=0)
        app.call('sidebar-menu', node=r5_wrap, item='Delete')
        time.sleep(.5)
        try: app.call('alert', button='Delete Folder')
        except RuntimeError: pass
        time.sleep(.3)
        r5_gone = app.call('live-folder-state').get('exists') is False
        r5_auto = app.call('defaults', key='open.liveFolders.githubAutoCreate')
        results['live_folder_nested_delete_removes_live_folder'] = {'ok': bool(r5_nested) and r5_gone and r5_auto is False,
            'nested': r5_nested, 'gone': r5_gone, 'autoCreate': r5_auto}
        app.call('defaults', key='open.liveFolders.githubAutoCreate', value=None)
        gh['prs'] = {'created': trio[:2]}
        if r5_gone: app.call('sidebar-menu', item='Live Folders/GitHub'); app.call('live-folder-state', wait=True)
        refreshed('success')
        # SB-04: keyboard Delete on the focused Live Folder row is Delete Live Folder: its alert, no
        # Archive rows, and automatic creation turns off. It was the plain folder delete (archived).
        app.call('defaults', key='open.liveFolders.githubAutoCreate', value=True)
        r4_folder = app.call('live-folder-state')['id']
        # The outline's Delete key on a selection of the Live Folder row alone (a plain click keeps a
        # multi-selection it is part of, so add or drop rows until it is the only one).
        app.call('sidebar-click', node=r4_folder)
        for node in [n for n in app.call('selection') if n != r4_folder]:
            app.call('sidebar-click', node=node, modifiers=['cmd'])
        if r4_folder not in app.call('selection'):
            app.call('sidebar-click', node=r4_folder, modifiers=['cmd'])
        r4_selection = app.call('selection')
        app.call('sidebar-key', key='delete')
        def read_alert():
            try: return app.call('alert') or None
            except RuntimeError: return None
        r4_alert = wait_until(lambda: (lambda a: a if a and a.get('texts') else None)(read_alert()), timeout=3, step=.05) or {}
        try: app.call('alert', button='Delete Folder')
        except RuntimeError: pass
        r4_gone = app.call('live-folder-state').get('exists') is False
        r4_archived = [r for r in app.call('archive-list', limit=50)['rows'] if r['id'] == r4_folder]
        # A lone Live Folder gets Delete Live Folder's alert; with other rows it is the folders' alert.
        # Either way it is removed, never archived, and automatic creation turns off.
        lone = r4_selection == [r4_folder]
        expected_title = 'Delete your GitHub Live Folder?' if lone else 'Delete your Pull Requests folder?'
        results['live_folder_keyboard_delete_is_live_delete'] = {'ok': expected_title in r4_alert.get('texts', [])
            and r4_gone and not r4_archived and app.call('defaults', key='open.liveFolders.githubAutoCreate') is False,
            'alert': r4_alert.get('texts'), 'gone': r4_gone, 'archived': len(r4_archived), 'selection': r4_selection}
        app.call('defaults', key='open.liveFolders.githubAutoCreate', value=None)
        gh['prs'] = {'created': []}
        if not r4_gone:
            app.call('sidebar-menu', item='Live Folders/GitHub')
        # The checks below toggle the folder off: give them one at the top level again.
        app.call('sidebar-menu', item='Live Folders/GitHub')
        app.call('live-folder-state', wait=True)
        # Bug sweep round 4 (SB-12): Export a Space into a Folder of a Space that has its own Live
        # Folder. One Live Folder stays live in the destination; the incoming one is a plain folder
        # that keeps its rows. It became a second Live Folder the Space menu cannot reach.
        import json
        from pathlib import Path
        home = next(s for s in app.call('spaces') if s['focused'])
        home_lf = app.call('live-folder-state', space=home['id'])
        export_space = app.call('space-create', title='LF Export'); app.call('space', space=export_space)
        app.call('sidebar-menu', item='Live Folders/GitHub')
        export_lf = app.call('live-folder-state', wait=True, space=export_space)
        # The menu uses the model's display title: the Space's own, else "Space N" by position.
        order = [sp['id'] for sp in app.call('spaces')]
        home_title = home.get('title') or 'Space %d' % (order.index(home['id']) + 1)
        def live_folders_in(space_id):
            snapshot = json.loads(Path(app.call('save')).read_text())
            def count(value):
                if isinstance(value, dict):
                    own = 1 if isinstance(value.get('live'), dict) and 'children' in value else 0
                    return own + sum(count(v) for v in value.values())
                if isinstance(value, list): return sum(count(v) for v in value)
                return 0
            return sum(count(sp) for sp in snapshot.get('spaces', []) if sp.get('id') == space_id)
        try:
            app.call('sidebar-menu', items=['Export “LF Export” into Folder', home_title]); exported = True
        except RuntimeError as error:
            exported = str(error)
        app.call('space', space=home['id'])
        after_export = app.call('live-folder-state', space=home['id'])
        results['live_folder_export_space_keeps_one'] = {'ok': exported is True and home_lf.get('exists') and export_lf.get('exists')
            and live_folders_in(home['id']) == 1 and after_export.get('id') == home_lf.get('id'),
            'exported': exported, 'liveFolders': live_folders_in(home['id']), 'homeTitle': home_title,
            'homeFolder': home_lf.get('id'), 'after': after_export.get('id')}
        # Bug sweep round 6 (seed 1): a drag of another Space's Live Folder into this Space, or Move to ▸
        # this Space for a folder that holds one, made a second Live Folder. The incoming one is now a
        # plain folder (lead ruling, the Export rule above); this Space's own stays the live one.
        def plain_folder_in(space_id, folder_id):
            snapshot = json.loads(Path(app.call('save')).read_text())
            def find(value):
                if isinstance(value, dict):
                    if value.get('id') == folder_id and 'children' in value: return value
                    return next((f for f in map(find, value.values()) if f is not None), None)
                if isinstance(value, list): return next((f for f in map(find, value) if f is not None), None)
                return None
            found = find([sp for sp in snapshot.get('spaces', []) if sp.get('id') == space_id])
            return found is not None and not isinstance(found.get('live'), dict)
        r6 = {}
        for how in ('drag', 'moveTo'):
            src = app.call('space-create', title='LF R6 %s' % how); app.call('space', space=src)
            app.call('sidebar-menu', item='Live Folders/GitHub')
            src_lf = app.call('live-folder-state', wait=True, space=src)
            moved = src_lf.get('id')
            try:
                if how == 'drag':
                    done = app.call('sidebar-drop', nodes=[moved], parent={'kind': 'pinned', 'id': home['id']}, index=0)
                else:
                    wrap = app.call('folder', tabs=[new_tab(app, 'about:blank')], title='R6 wrap', section='pinned')
                    app.call('sidebar-drop', nodes=[moved], parent={'kind': 'folder', 'id': wrap}, index=0)
                    done = app.call('sidebar-menu', node=wrap, items=['Move to', home_title])
            except RuntimeError as error:
                done = str(error)
            r6[how] = {'moved': done, 'liveFolders': live_folders_in(home['id']), 'plain': plain_folder_in(home['id'], moved),
                       'homeLive': app.call('live-folder-state', space=home['id']).get('id') == home_lf.get('id')}
        app.call('space', space=home['id'])
        results['live_folder_move_into_space_keeps_one'] = {'ok': all(r['moved'] is True and r['liveFolders'] == 1
            and r['plain'] and r['homeLive'] for r in r6.values()), 'moves': r6}
        app.call('sidebar-menu', item='Live Folders/GitHub')
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
                entries = ''.join('<entry><title>%s</title><link rel="alternate" href="%s" type="text/html"/>'
                                  '<issued>%s</issued><author><name>%s</name><email>x@example.com</email></author></entry>'
                                  % (html.escape(m[0]), html.escape(m[3] if len(m) > 3 else 'http://mail.localhost:%d/mail/u/0/?msg=%d' % (port, i), quote=True),
                                     m[2], html.escape(m[1])) for i, m in enumerate(state['mail']))
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
        # Bug sweep round 4 (SB-15): opening a row of a Favorite's card ends the hover preview, so
        # the same tile shows its card again on the next hover. A Favorite's Peek does not select
        # the Favorite (a pinned source is selected, which reset the tracker); the tracker kept the
        # old request and ignored the tile.
        fav_mail = new_tab(app, 'http://mail.localhost:%d/mail/u/0/#inbox' % port)
        app.call('favorite', tab=fav_mail)
        app.call('select', tab=other)
        def hover_favorite():
            app.call('hover', leave=True, ms=300)
            return app.call('hover', favorite=fav_mail, ms=800)
        first_card = hover_favorite()
        app.call('glance-open', row=0)
        fav_peek = wait_until(lambda: (lambda s: s if s.get('shown') else None)(app.call('peek-state')), timeout=5, step=.05)
        app.call('peek-close'); wait_until(lambda: not app.call('peek-state').get('shown'), timeout=5, step=.05)
        current = app.call('window-state')['selected']
        again_hover = hover_favorite()
        again = app.call('glance-state')
        results['live_glance_rehover_after_open'] = {'ok': first_card.get('kind') == 'glance' and bool(fav_peek) and current != fav_mail
            and again.get('kind') == 'gmail' and again.get('phase') == 'mail',
            'first': first_card.get('kind'), 'peek': bool(fav_peek), 'currentIsFavorite': current == fav_mail,
            'hover': again_hover.get('kind'), 'state': {k: again.get(k) for k in ('shown', 'kind', 'phase')}}
        app.call('close', tab=fav_mail)
        app.call('select', tab=other)
        # Review r1 item 6: a row whose link scheme only starts with "http" is dropped.
        mail['mail'] = [('Odd scheme', 'Eve', '2026-11-12T10:00:00Z', 'httpfoo://mail.localhost/odd'), ('Plain row', 'Bob', '2026-11-12T07:00:00Z')]
        app.call('select', tab=other)
        hover(inbox); odd = app.call('glance-state')
        results['live_gmail_odd_scheme_dropped'] = {'ok': odd.get('phase') == 'mail' and [r['title'] for r in odd.get('rows', [])] == ['Plain row'],
            'state': odd}
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
    before_prefs = {k: app.call('defaults', key=k) for k in keys}
    state = lambda: app.call('first-run')
    app.call('first-run', action='settings-import', directory=str(arc))
    app.call('first-run', action='settings-next')
    app.call('first-run', action='settings-run')
    report = wait_until(lambda: (lambda s: s if s.get('settingsStep') == 'Report' else None)(state()), timeout=60, step=.05) or state()
    try: app.call('first-run', action='settings-done')
    except RuntimeError: pass
    beta = next((s for s in app.call('spaces') if s['title'] == 'Beta'), None)
    folder = app.call('live-folder-state', space=beta['id']) if beta else {}
    rows = {r['url']: r['live'] for r in folder.get('rows', [])}
    prefs = {k: app.call('defaults', key=k) for k in keys}
    results['live_folder_arc_import'] = {'ok': bool(beta) and folder.get('exists') and folder.get('title') == 'Pull Requests'
        and rows == {'https://github.com/acme/app/pull/12': 'https://github.com/acme/app/pull/12', 'https://github.com/acme/web/pull/7': 'https://github.com/acme/web/pull/7'}
        and folder.get('hiddenItems') == ['https://github.com/acme/app/pull/3'] and folder.get('hiddenRepositories') == ['acme/old']
        # Lead ruling (round 2): a Settings re-import keeps Open's own settings; first run maps them (below).
        and prefs == before_prefs and 'Arc settings' not in (report.get('lastOutcome') or {}),
        'folder': folder, 'prefs': prefs, 'prefsBefore': before_prefs,
        'report': {k: report.get(k) for k in ('lastOutcome', 'lastFailures', 'arcPreferences')}}
    # Undo the import: the folder and the two settings go back.
    app.call('sidebar-key', key='z', modifiers=['command'])
    wait_until(lambda: not state().get('importUndoInProgress', False), timeout=30, step=.05)
    undone = wait_until(lambda: (lambda v: v if v == {k: None for k in keys} else None)({k: app.call('defaults', key=k, persistent=True) for k in keys}), timeout=10, step=.1)
    results['live_folder_arc_import_undo'] = {'ok': undone is not None and not any(s['title'] == 'Beta' and app.call('live-folder-state', space=s['id']).get('exists') for s in app.call('spaces')),
        'prefs': {k: app.call('defaults', key=k, persistent=True) for k in keys}}


def live_folder_first_run_checks(factory, results, wait_until, tmp, harness):
    """L7 first run: Arc's two Live Folder preferences land with the Live Folder (own launch)."""
    import runpy
    from pathlib import Path
    arc = Path(tmp) / 'arc-live-home' / 'Library' / 'Application Support' / 'Arc'
    helper = runpy.run_path(str(Path(harness['ROOT']) / 'tools' / 'e2e' / 'firstrun.py'))
    keys = ('open.liveFolders.githubAutoCreate', 'open.liveFolders.introSeen')
    app, saved = None, {}
    try:
        app, report, saved = helper['first_run_arc_import'](factory, arc, wait_until, reset_keys=keys, history=False)
        prefs = {k: app.call('defaults', key=k) for k in keys}
        beta = next((s for s in app.call('spaces') if s['title'] == 'Beta'), None)
        folder = app.call('live-folder-state', space=beta['id']) if beta else {}
        results['live_folder_arc_prefs_first_run'] = {'ok': report.get('step') == 'report' and bool(beta)
            and folder.get('exists') and folder.get('title') == 'Pull Requests'
            and prefs == {'open.liveFolders.githubAutoCreate': False, 'open.liveFolders.introSeen': True},
            'prefs': prefs, 'folder': {k: folder.get(k) for k in ('exists', 'title')},
            'outcome': report.get('outcome'), 'failures': report.get('failures')}
    finally:
        if app is not None:
            harness['_restore_defaults'](app, saved)
            for key in keys: app.call('defaults', key=key, value=None)
            app.quit()


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
        case = os.environ.get('OPEN_LIVE_DATA_CASE', '')
        if case == 'r3-folder':  # diagnostic: the Live Folder rows alone (row glyphs need one plain tab)
            new_tab(app, url('plain', 'r3-folder'))
            app = live_folder_checks(holder, results, wait_until, factory, new_tab)
            return
        # Bug sweep r3 E7 (claim rejected): a script that never settles must not hold the one fetch
        # slot. OpenEngine ends an Open-world request after 10 s (OEWebContent.mm, "Open-world request
        # timed out"); the slot frees and the next fetch works. Regression row for that guarantee.
        try:
            stalled = app.call('live-fetch', url=url('fetch', 'live-fetch-stall'), script='new Promise(() => {})', timeout=45)
        except Exception as error:
            stalled = {'error': 'client: ' + str(error)[-200:]}
        try:
            after = app.call('live-fetch', url=url('fetch', 'live-fetch'), script='document.title', timeout=45)
        except Exception as error:
            after = {'error': 'client: ' + str(error)[-200:]}
        results['live_fetch_stalled_script_frees_slot'] = {'ok': 'timed out' in str(stalled.get('error', ''))
            and stalled.get('created') == stalled.get('closed') == 2
            and after.get('value') == 'Sleep /live-fetch' and after.get('created') == after.get('closed') == 3,
            'stalled': stalled, 'after': after}
        if case == 'r3-fetch':
            return
        if case == 'r3-gmail':
            gmail_checks(app, results, wait_until, new_tab, {'recents.localhost': 'linear', 'empty.localhost': 'notion', 'today.localhost': 'figma'})
            return
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
    # The Arc fixture of live_folder_import_checks, now through first run (Arc settings apply there only).
    live_folder_first_run_checks(factory, results, wait_until, tmp, harness)
