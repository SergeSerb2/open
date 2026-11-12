"""Plan NS §2 CAL: Join Meeting (Tabs menu, Ctrl+Cmd+J, command bar) through the real App automation socket.

Calendar data comes from the `calendar` fixture source (no macOS Calendar prompt on test machines). Every join
link resolves to nothing (host-resolver rules), so no run touches a real meeting service.
"""
import time

# Join links never reach the network: every host except localhost resolves to NOTFOUND.
ENGINE_SWITCHES = ['--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1', '--no-proxy-server']

ZOOM = 'https://acme.zoom.us/j/81234567890?pwd=e2e'
MEET = 'https://meet.google.com/abc-defg-hij'
TEAMS = 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_e2e%40thread.v2/0'


def run(factory, results, tmp, harness):
    wait_until = harness['wait_until']
    app = factory(urls=('about:blank',), fresh=True, extra_args=ENGINE_SWITCHES)

    def cal(**kw): return app.call('calendar', **kw)
    def tabs(): return app.call('tabs')
    def toasts(): return [t for t in app.call('toasts')['toasts'] if t['coalescingKey'] == 'join-meeting' and not t['exiting']]
    def menu_row(id): return next((r for r in app.call('menu-state') if r['id'] == id), {})
    def bar_state(): return app.call('commandbar-state')

    def join(via):
        """Runs Join Meeting through one real entry point; returns the outcome the App recorded."""
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        seq = app.call('calendar', action='join-result').get('seq', 0)
        if via == 'menu':
            app.call('menu-perform', id='join-meeting')
        elif via == 'hotkey':
            app.call('key', key='j', modifiers=['control', 'cmd'], route='app')
        else:
            query, action = via
            app.call('key', key='t', modifiers=['cmd'], route='app')
            assert wait_until(lambda: bar_state().get('presented'), timeout=3, step=.05), bar_state()
            app.call('key', text=query)
            ready = wait_until(lambda: (lambda s: s if s.get('text') == query and s.get('final') else None)(bar_state()), timeout=5, step=.05)
            rows = (ready or {}).get('rows', [])
            if not rows or rows[0].get('action') != action:
                return {'outcome': 'row-missing', 'rows': [(r['title'], r['action']) for r in rows[:5]]}
            app.call('key', key='return')
        # Every join records a new outcome with the next sequence number.
        result = wait_until(lambda: (lambda r: r if r.get('seq', 0) > seq else None)(app.call('calendar', action='join-result')),
                            timeout=8, step=.05)
        return result or {}

    try:
        app.call('window-frame', frame=[80, 60, 1280, 820])
        row = menu_row('join-meeting')
        results['cal_menu_join_meeting'] = {
            'ok': row.get('enabled') is True and row.get('title') == 'Join Meeting' and row.get('key') == 'j'
                and row.get('modifierMask') == (1 << 18 | 1 << 20),  # Control | Command
            'row': {k: row.get(k) for k in ('title', 'enabled', 'key', 'modifierMask')}}
        # 1. No permission yet: the first join asks once; a "no" shows the access toast, a second join does not ask again.
        cal(action='fixture', access='notDetermined', answer='denied', events=[{'title': 'Standup', 'start': 3, 'url': MEET}])
        n_tabs = len(tabs())
        first = join('menu')
        second = join('hotkey')
        state = cal()
        toast = toasts()
        results['cal_join_denied'] = {
            'ok': first.get('outcome') == 'noAccess' and first.get('access') == 'denied' and second.get('outcome') == 'noAccess'
                and state.get('requests') == 1 and state.get('queries') == 0 and len(tabs()) == n_tabs
                and bool(toast) and toast[0]['title'] == 'Allow Calendar access to join meetings' and toast[0]['accessory'] == 'gearshape',
            'first': first, 'second': second, 'requests': state.get('requests'), 'toast': toast[:1]}

        # 2. Eligibility: declined, canceled, all-day, ended and link-less events are skipped; the link in notes counts.
        events = [
            {'id': 'declined', 'title': 'Declined sync', 'start': 1, 'url': MEET, 'declined': True},
            {'id': 'nolink', 'title': 'Room meeting', 'start': 2, 'location': 'Room 4'},
            {'id': 'canceled', 'title': 'Canceled', 'start': 3, 'location': ZOOM, 'canceled': True},
            {'id': 'allday', 'title': 'Offsite', 'start': -300, 'end': 600, 'allDay': True, 'url': TEAMS},
            {'id': 'ended', 'title': 'Earlier call', 'start': -40, 'end': -5, 'url': MEET},
            {'id': 'zoom', 'title': 'Design review', 'start': 6, 'notes': 'Agenda\nJoin Zoom Meeting\n' + ZOOM + '\nMeeting ID: 812 3456 7890'},
            {'id': 'meet', 'title': 'Later call', 'start': 25, 'url': MEET},
        ]
        cal(action='fixture', access='granted', events=events)
        state = cal()
        n_tabs = len(tabs())
        joined = join('hotkey')
        after = tabs()
        opened = next((t for t in after if t['id'] == joined.get('tab')), {})
        results['cal_join_next_eligible'] = {
            'ok': state.get('next', {}).get('id') == 'zoom' and joined.get('outcome') == 'join' and joined.get('event') == 'zoom'
                and joined.get('service') == 'zoom' and joined.get('url') == ZOOM and len(after) == n_tabs + 1
                and opened.get('url', '').startswith('https://acme.zoom.us/j/81234567890')
                and app.call('window-state').get('selected') == joined.get('tab') and state.get('requests') == 0,
            'next': state.get('next'), 'joined': joined, 'opened': opened.get('url'), 'tabs': [len(after), n_tabs]}

        # 3. A meeting that started 4 minutes ago wins over one in 15 minutes; run from the command bar.
        cal(action='fixture', access='granted', events=[
            {'id': 'running', 'title': 'Running call', 'start': -4, 'end': 26, 'url': MEET},
            {'id': 'teams', 'title': 'Teams sync', 'start': 15, 'location': TEAMS},
        ])
        joined = join(('join next meeting', 'join-next-meeting'))
        results['cal_commandbar_join_next_meeting'] = {
            'ok': joined.get('outcome') == 'join' and joined.get('event') == 'running' and joined.get('url') == MEET,
            'joined': joined}
        cal(action='fixture', access='granted', events=[{'id': 'teams', 'title': 'Teams sync', 'start': 15, 'location': TEAMS}])
        joined = join(('video call', 'join-next-video-conference'))
        results['cal_commandbar_join_video_conference'] = {
            'ok': joined.get('outcome') == 'join' and joined.get('event') == 'teams' and joined.get('service') == 'teams',
            'joined': joined}

        # 4. No meeting with a call link: a toast, no new tab.
        cal(action='fixture', access='granted', events=[
            {'id': 'nolink', 'title': 'Lunch', 'start': 10, 'location': 'Cafe'},
            {'id': 'old', 'title': 'Old call', 'start': -30, 'end': 30, 'url': MEET},  # started > 10 min ago
        ])
        n_tabs = len(tabs())
        joined = join('menu')
        toast = toasts()
        results['cal_join_no_meeting'] = {
            'ok': joined.get('outcome') == 'noMeeting' and len(tabs()) == n_tabs and bool(toast)
                and toast[0]['title'] == 'No upcoming meetings',
            'joined': joined, 'toast': toast[:1]}
    finally:
        app.quit()
