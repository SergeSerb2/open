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
    wait_until, new_tab = harness['wait_until'], harness['new_tab']
    # The denied card's button must not open System Settings on the test machine.
    app = factory(urls=('about:blank',), fresh=True, extra_args=ENGINE_SWITCHES, extra_env={'OPEN_E2E_NO_SYSTEM_SETTINGS': '1'})

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
                and bool(toast) and toast[0]['title'] == 'Allow Calendar access to join meetings' and toast[0]['accessory'] == 'open privacy settings',
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

        # 5. Calendar card (L4): a Pinned Google Calendar tab shows the native card on hover.
        card_checks(app, results, wait_until, new_tab, cal, tabs, join_seq=lambda: cal(action='join-result').get('seq', 0))
        # 6. Live Calendar (L5): a calendar Favorite counts down and reminds.
        live_checks(app, results, wait_until, new_tab, cal)
    finally:
        try:
            app.call('defaults', key='open.general.previewsCalendar', value=None)
        finally:
            app.quit()


def card_checks(app, results, wait_until, new_tab, cal, tabs, join_seq):
    def hover(node, ms=800):
        app.call('hover', leave=True, ms=300)
        return app.call('hover', node=node, ms=ms)
    def glance(): return app.call('glance-state')
    calendar = new_tab(app, 'https://calendar.google.com/calendar/u/0/r')
    app.call('pin', tab=calendar)
    today = new_tab(app, 'about:blank')
    app.call('select', tab=today)
    results['cal_card_match'] = {'ok': app.call('glance-match', url='https://calendar.google.com/calendar/u/0/r').get('kind') == 'calendar'
        and app.call('glance-match', url='https://outlook.office.com/calendar/view/day').get('provider') == 'outlook'
        and app.call('glance-match', url='https://outlook.office.com/mail/').get('kind') == 'none'
        and app.call('glance-match', url='https://calendar.notion.so/').get('provider') == 'notion'}

    cal(action='fixture', access='granted', events=[
        {'id': 'standup', 'title': 'Standup', 'start': -60, 'end': -45, 'url': MEET},
        {'id': 'soon', 'title': 'Design review', 'start': 4, 'end': 34, 'notes': 'Zoom: ' + ZOOM},
        {'id': 'later', 'title': '', 'start': 90, 'end': 120},
    ])
    shown = hover(calendar)
    state = glance()
    join = state.get('join') or {}
    results['cal_card_timeline'] = {
        'ok': shown.get('kind') == 'glance' and state.get('kind') == 'calendar' and state.get('phase') == 'timeline'
            and state.get('header') == 'Upcoming' and state.get('newLabel') == 'New Event'
            and state.get('newURL') == 'https://calendar.google.com/calendar/u/0/r/eventedit'
            and join.get('event') == 'soon' and join.get('url') == ZOOM and join.get('tooltip') == 'Join Zoom'
            and join.get('subtitle') in ('Event in 4m', 'Event in 3m')
            and [e['title'] for e in state.get('events', [])] == ['Standup', 'Design review', 'Event']
            and len(state.get('card', [])) == 4 and state['card'][2] == 240,
        'hover': shown, 'state': state}

    seq, n_tabs = join_seq(), len(tabs())
    app.call('glance-open', control='join')
    joined = wait_until(lambda: (lambda r: r if r.get('seq', 0) > seq else None)(cal(action='join-result')), timeout=5, step=.05) or {}
    results['cal_card_join'] = {'ok': joined.get('origin') == 'card' and joined.get('url') == ZOOM and len(tabs()) == n_tabs + 1
        and app.call('window-state').get('selected') == joined.get('tab') and glance().get('shown') is False, 'joined': joined}

    app.call('select', tab=today)
    shown = hover(calendar)
    card = glance()
    app.call('glance-open', control='new')
    peek = wait_until(lambda: (lambda s: s if s.get('shown') and s['stack'] else None)(app.call('peek-state')), timeout=5, step=.05)
    results['cal_card_new_event_peek'] = {'ok': bool(peek) and peek['stack'][-1].get('source') == calendar, 'peek': peek,
        'hover': shown, 'card': {k: card.get(k) for k in ('shown', 'phase', 'newURL')}, 'final': app.call('peek-state'),
        'window': {k: app.call('window-state').get(k) for k in ('selected', 'space', 'peekCreated')}}
    app.call('peek-close')
    wait_until(lambda: not app.call('peek-state').get('shown'), timeout=5, step=.05)

    # Hover never asks macOS; the button does, and a yes fills the card.
    app.call('select', tab=today)
    cal(action='fixture', access='notDetermined', answer='granted', events=[{'id': 'soon', 'title': 'Sync', 'start': 2, 'url': MEET}])
    hover(calendar)
    before = glance()
    asked_on_hover = cal().get('requests')
    app.call('glance-open', control='access')
    after = wait_until(lambda: (lambda s: s if s.get('phase') == 'timeline' else None)(glance()), timeout=5, step=.05) or glance()
    results['cal_card_access_prompt_on_click_only'] = {
        'ok': before.get('phase') == 'needsAccess' and before.get('access') == 'Allow Calendar Access' and asked_on_hover == 0
            and cal().get('requests') == 1 and after.get('phase') == 'timeline' and (after.get('join') or {}).get('event') == 'soon',
        'before': before, 'after': after}

    cal(action='fixture', access='denied', events=[])
    hover(calendar)
    denied = glance()
    opened = denied.get('privacyOpened', 0)
    app.call('glance-open', control='access')
    again = wait_until(lambda: (lambda s: s if s.get('privacyOpened', 0) > opened else None)(glance()), timeout=5, step=.05) or glance()
    results['cal_card_denied'] = {'ok': denied.get('phase') == 'denied' and denied.get('access') == 'Open Privacy Settings'
        and again.get('privacyOpened') == opened + 1 and again.get('phase') == 'denied' and cal().get('queries') == 0,
        'denied': denied, 'again': again}

    app.call('defaults', key='open.general.previewsCalendar', value=False)
    off = hover(calendar)
    results['cal_card_switch_off'] = {'ok': off.get('kind') != 'glance' and glance().get('shown') is False, 'hover': off}
    app.call('hover', leave=True, ms=300)


def live_checks(app, results, wait_until, new_tab, cal):
    def live(): return cal(action='live')
    def tile(): return (live().get('tiles') or [{}])[0] if live().get('tiles') else {}
    def at(minutes): cal(action='clock', minutes=minutes); return live()
    def toasts(): return [t for t in app.call('toasts')['toasts'] if t['coalescingKey'] == 'live-calendar' and not t['exiting']]
    app.call('defaults', key='open.general.previewsCalendar', value=None)
    cal(action='fixture', access='granted', events=[{'id': 'm', 'title': 'Weekly sync', 'start': 10, 'end': 40, 'url': MEET}])
    fav = new_tab(app, 'https://calendar.google.com/calendar/u/0/r/day')
    app.call('favorite', tab=fav)
    state = wait_until(lambda: (lambda s: s if s.get('active') and s.get('tiles') else None)(live()), timeout=5, step=.05) or live()
    first = (state.get('tiles') or [{}])[0]
    results['cal_live_tile_countdown'] = {
        'ok': first.get('tab') == fav and first.get('subtitle') == 'in 10m' and first.get('phase') == 'before'
            and first.get('remind') is False and state.get('interval') == 'twoMinutes'
            and isinstance(state.get('nextFireIn'), (int, float)) and 0 < state['nextFireIn'] <= 61,
        'state': state}

    seen = {}
    for minutes in (9, 10, 13):
        s = at(minutes)
        seen[minutes] = ((s.get('tiles') or [{}])[0].get('subtitle'), len(s.get('reminders', [])))
    toast = toasts()
    gone = at(21)
    results['cal_live_tile_times'] = {
        'ok': seen[9] == ('in 1m', 1) and seen[10] == ('Now', 1) and seen[13] == ('3m ago', 1) and not gone.get('tiles')
            and bool(toast) and toast[0]['title'] == 'Weekly sync' and toast[0]['accessory'] == 'join',
        'seen': seen, 'toast': toast[:1], 'after': gone.get('tiles')}

    # Tile menu: Show Meeting Link ▸ Copy Link / Dismiss; Meeting Reminder ▸ interval.
    at(0)
    app.call('pasteboard-write', text='before')
    app.call('sidebar-menu', node=fav, item='Show Meeting Link/Copy Link')
    copied = app.call('pasteboard')
    app.call('sidebar-menu', node=fav, item='Show Meeting Link/Dismiss')
    dismissed = live()
    results['cal_live_menu_copy_dismiss'] = {'ok': copied == MEET and 'm' in dismissed.get('dismissed', []) and not dismissed.get('tiles'),
        'copied': copied, 'state': dismissed}

    app.call('sidebar-menu', node=fav, item='Meeting Reminder/Never')
    cal(action='fixture', access='granted', events=[{'id': 'n', 'title': 'Never reminded', 'start': 5, 'end': 35, 'url': ZOOM}])
    never = at(4.5)
    app.call('sidebar-menu', node=fav, item='Meeting Reminder/Five Minutes Before')
    cal(action='fixture', access='granted', events=[{'id': 'f', 'title': 'Five before', 'start': 8, 'end': 38, 'url': ZOOM}])
    early = at(2)
    five = at(3.5)
    reminded = [r['event'] for r in five.get('reminders', [])]
    results['cal_live_reminder_interval'] = {
        'ok': never.get('interval') == 'never' and 'n' not in [r['event'] for r in never.get('reminders', [])]
            and five.get('interval') == 'fiveMinutes' and 'f' not in [r['event'] for r in early.get('reminders', [])] and 'f' in reminded,
        'never': never.get('reminders'), 'five': five.get('reminders')}
    app.call('sidebar-menu', node=fav, item='Meeting Reminder/Two Minutes Before')

    # Without a calendar Favorite the coordinator stops: no tiles, no timer.
    app.call('sidebar-menu', node=fav, item='Remove from Favorites')
    stopped = at(0)
    results['cal_live_stops_without_favorite'] = {'ok': stopped.get('active') is False and stopped.get('nextFireIn') is None
        and not stopped.get('tiles'), 'state': stopped}
