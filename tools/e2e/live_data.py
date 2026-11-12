"""LF L1: the Recents live-data hover card, through the real App automation socket.

Fixture hosts on the loopback server stand in for linear.app / notion.so (`glance-alias`);
history rows are seeded in the Profile's real history store. No account, no network.
"""
import time


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
    finally:
        try:
            app.call('glance-alias', aliases={})
        finally:
            app.quit()
            server.shutdown()
