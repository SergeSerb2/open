"""Plan NS §2 CAL: Join Meeting (Tabs menu, Ctrl+Cmd+J, command bar) through the real App automation socket.

Calendar data comes from the `calendar` fixture source (no macOS Calendar prompt on test machines). Every join
link resolves to nothing (host-resolver rules), so no run touches a real meeting service.
"""
import json
import os
import runpy
import subprocess
import time

# Join links never reach the network: every host except localhost resolves to NOTFOUND.
ENGINE_SWITCHES = ['--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1', '--no-proxy-server']

ARC_PREF_KEYS = ('open.general.previewsFolders', 'open.general.previewsRecents', 'open.general.previewsCalendar',
                 'open.general.previewsGmail', 'open.general.previewsPages')
ZOOM = 'https://acme.zoom.us/j/81234567890?pwd=e2e'
MEET = 'https://meet.google.com/abc-defg-hij'
TEAMS = 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_e2e%40thread.v2/0'


def run(factory, results, tmp, harness):
    wait_until, new_tab = harness['wait_until'], harness['new_tab']
    badges = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'favorite_badges.py'))['run']
    if os.environ.get('OPEN_E2E_FAVORITE_BADGES_ONLY') == '1':
        badges(factory, results, harness)
        return
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
        # Arc enables Join Meeting only while its Live Calendar has an active event with a join link (menu
        # validation FUN_100314424, branch joinLiveMeeting:). Open: only while a joinable meeting is in memory.
        def enabled(): return menu_row('join-meeting').get('enabled')
        def refused(via):
            """The disabled item cannot run: the menu refuses, the hotkey is not taken; nothing is recorded."""
            seq, n = cal(action='join-result').get('seq', 0), len(tabs())
            app.call('window-focus', id=app.call('window-state')['id'], activate=True)
            if via == 'menu':
                try: app.call('menu-perform', id='join-meeting'); return False
                except RuntimeError: pass
            else:
                app.call('key', key='j', modifiers=['control', 'cmd'], route='app')
            time.sleep(0.5)
            return cal(action='join-result').get('seq', 0) == seq and len(tabs()) == n
        row = menu_row('join-meeting')
        results['cal_menu_join_meeting'] = {
            'ok': row.get('enabled') is False and row.get('title') == 'Join Meeting' and row.get('key') == 'j'
                and row.get('modifierMask') == (1 << 18 | 1 << 20),  # Control | Command
            'row': {k: row.get(k) for k in ('title', 'enabled', 'key', 'modifierMask')}}
        # A calendar Favorite: Live Calendar keeps today's events in memory (the real source of the enabled state).
        fav0 = new_tab(app, 'https://calendar.google.com/calendar/u/0/r/day')
        app.call('favorite', tab=fav0)
        new_tab(app, 'about:blank')
        # 1. No permission yet: nothing is in memory, the item stays disabled, and nothing asks macOS for access.
        cal(action='fixture', access='notDetermined', answer='denied', events=[{'title': 'Standup', 'start': 3, 'url': MEET}])
        time.sleep(0.5)
        state = cal()
        results['cal_join_disabled_without_access'] = {
            'ok': enabled() is False and refused('menu') and refused('hotkey') and state.get('requests') == 0
                and state.get('queries') == 0 and not toasts(),
            'enabled': enabled(), 'requests': state.get('requests'), 'queries': state.get('queries')}

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
        became = wait_until(enabled, timeout=5, step=.05)
        state = cal()
        n_tabs = len(tabs())
        joined = join('hotkey')
        after = tabs()
        opened = next((t for t in after if t['id'] == joined.get('tab')), {})
        results['cal_join_next_eligible'] = {
            'ok': became is True and state.get('joinableInMemory') == 'zoom'
                and state.get('next', {}).get('id') == 'zoom' and joined.get('outcome') == 'join' and joined.get('event') == 'zoom'
                and joined.get('service') == 'zoom' and joined.get('url') == ZOOM and len(after) == n_tabs + 1
                and opened.get('url', '').startswith('https://acme.zoom.us/j/81234567890')
                and app.call('window-state').get('selected') == joined.get('tab') and state.get('requests') == 0,
            'next': state.get('next'), 'joined': joined, 'opened': opened.get('url'), 'tabs': [len(after), n_tabs]}

        # 3. A meeting that started 4 minutes ago wins over one in 15 minutes; run from the command bar.
        cal(action='fixture', access='granted', events=[
            {'id': 'running', 'title': 'Running call', 'start': -4, 'end': 26, 'url': MEET},
            {'id': 'teams', 'title': 'Teams sync', 'start': 15, 'location': TEAMS},
        ])
        wait_until(lambda: cal().get('joinableInMemory') == 'running', timeout=5, step=.05)
        joined = join(('join next meeting', 'join-next-meeting'))
        results['cal_commandbar_join_next_meeting'] = {
            'ok': joined.get('outcome') == 'join' and joined.get('event') == 'running' and joined.get('url') == MEET,
            'joined': joined}
        cal(action='fixture', access='granted', events=[{'id': 'teams', 'title': 'Teams sync', 'start': 15, 'location': TEAMS}])
        wait_until(lambda: cal().get('joinableInMemory') == 'teams', timeout=5, step=.05)
        joined = join(('video call', 'join-next-video-conference'))
        results['cal_commandbar_join_video_conference'] = {
            'ok': joined.get('outcome') == 'join' and joined.get('event') == 'teams' and joined.get('service') == 'teams',
            'joined': joined}

        # 4. No meeting with a call link: the item is disabled, as Arc; ⌃⌘J gives no feedback (C3 capture): no
        #    toast, no new tab; the command bar hides both actions.
        cal(action='fixture', access='granted', events=[
            {'id': 'nolink', 'title': 'Lunch', 'start': 10, 'location': 'Cafe'},
            {'id': 'old', 'title': 'Old call', 'start': -30, 'end': 30, 'url': MEET},  # started > 10 min ago
        ])
        off = wait_until(lambda: enabled() is False, timeout=5, step=.05)
        shown_before = app.call('toasts')['shown']
        quiet = refused('menu') and refused('hotkey')
        shown_after = app.call('toasts')['shown']
        hidden = join(('join next meeting', 'join-next-meeting'))
        app.call('key', key='escape', route='app')
        results['cal_join_no_meeting'] = {
            'ok': off is True and quiet and shown_after == shown_before and hidden.get('outcome') == 'row-missing',
            'disabled': off, 'quiet': quiet, 'toasts': [shown_before, shown_after], 'commandBar': hidden}

        # 5. Calendar card (L4): a Pinned Google Calendar tab shows the native card on hover.
        card_checks(app, results, wait_until, new_tab, cal, tabs, join_seq=lambda: cal(action='join-result').get('seq', 0))
        # 6. Live Calendar (L5): a calendar Favorite counts down and reminds.
        live_checks(app, results, wait_until, new_tab, cal, fav0)

        # 7. Meet route: the first external Meet link adds Arc's default rule and announces it once.
        meet_route_checks(app, results, wait_until, cal)

        # 8. Import from Arc maps Arc's preview switches, Live Calendar reminder and Meet route (synthetic plist).
        arc_preferences_checks(app, results, wait_until, tmp, harness)
    finally:
        try:
            app.call('defaults', key='open.general.previewsCalendar', value=None)
            app.call('defaults', key='open.links.didSetDefaultMeetRoute', value=None)
            for key in ARC_PREF_KEYS: app.call('defaults', key=key, value=None)
            app.call('defaults', key='open.favorites.subtitleDisabledHosts', value=None)
            app.call('defaults', key='open.favorites.liveCalendarDisabled', value=None)
        finally:
            app.quit()
    live_persistence_checks(factory, results, wait_until, new_tab)
    # Audit A2: Favorite unread badges (own launch: app hosts map to a local server).
    badges(factory, results, harness)


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
    # CG1 (Open's design, LEAD 19:30): a Pinned calendar tab has no Live Calendar, so its gear menu is Refresh only.
    gear = state.get('gear') or {}
    results['cal_card_gear_pinned'] = {'ok': gear.get('shown') is True and gear.get('items') == ['Refresh']
        and gear.get('enabled') == [True] and len(gear.get('frame', [])) == 4 and gear['frame'][0] < state['card'][0] + state['card'][2],
        'gear': gear}

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


def live_checks(app, results, wait_until, new_tab, cal, fav):
    def live(): return cal(action='live')
    def tile(): return (live().get('tiles') or [{}])[0] if live().get('tiles') else {}
    def at(minutes): cal(action='clock', minutes=minutes); return live()
    def toasts(): return [t for t in app.call('toasts')['toasts'] if t['coalescingKey'] == 'live-calendar' and not t['exiting']]
    app.call('defaults', key='open.general.previewsCalendar', value=None)
    cal(action='fixture', access='granted', events=[{'id': 'm', 'title': 'Weekly sync', 'start': 10, 'end': 40, 'url': MEET}])
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
        # Count only this event's reminders: the calendar Favorite from the Join Meeting rows keeps Live Calendar on
        # during their fixtures, so the log can hold reminders for those events too.
        seen[minutes] = ((s.get('tiles') or [{}])[0].get('subtitle'), sum(r.get('event') == 'm' for r in s.get('reminders', [])))
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

    # Audit A2: "Show Time to Next Meeting" (Arc's Top App subtitle switch) hides and shows the plate per host.
    cal(action='fixture', access='granted', events=[{'id': 's', 'title': 'Subtitle sync', 'start': 10, 'end': 40, 'url': MEET}])
    cal(action='clock', minutes=0)
    wait_until(lambda: live().get('tiles'), timeout=5, step=.05)
    def plate(): return app.call('favorite-badge', favorite=fav).get('subtitleShown')
    item = lambda: app.call('sidebar-menu-state', node=fav, item='Show Time to Next Meeting')
    shown_before, checked_before = wait_until(plate, timeout=3, step=.05), item().get('checked')
    app.call('sidebar-menu', node=fav, item='Show Time to Next Meeting')
    hidden = wait_until(lambda: plate() is False, timeout=3, step=.05)
    stored = app.call('defaults', key='open.favorites.subtitleDisabledHosts', persistent=True)
    checked_off, still_live = item().get('checked'), bool(live().get('tiles'))
    app.call('sidebar-menu', node=fav, item='Show Time to Next Meeting')
    back = wait_until(plate, timeout=3, step=.05)
    results['cal_live_subtitle_switch'] = {'ok': bool(shown_before) and checked_before is True and bool(hidden)
        and stored == ['calendar.google.com'] and checked_off is False and still_live and bool(back)
        and item().get('checked') is True and app.call('defaults', key='open.favorites.subtitleDisabledHosts', persistent=True) == [],
        'stored': stored, 'checked': [checked_before, checked_off]}

    gear_checks(app, results, wait_until, cal, fav, live)

    # Without a calendar Favorite the coordinator stops: no tiles, no timer.
    app.call('sidebar-menu', node=fav, item='Remove Favorite')
    stopped = at(0)
    results['cal_live_stops_without_favorite'] = {'ok': stopped.get('active') is False and stopped.get('nextFireIn') is None
        and not stopped.get('tiles'), 'state': stopped}


def gear_checks(app, results, wait_until, cal, fav, live):
    """CG1, Open's design (LEAD 19:30; Arc's effect was never captured): the calendar card's gear menu, Refresh
    with a spinner in the gear's place, and Disable / Enable Live Calendar stored per Favorite."""
    key = 'open.favorites.liveCalendarDisabled'
    def hover(favorite, ms=800):
        # A Favorite tile is addressed with `favorite`, not `node`.
        app.call('hover', leave=True, ms=300)
        return app.call('hover', favorite=favorite, ms=ms)
    def glance(wait=True): return app.call('glance-state', wait=wait)
    def has_item(title):
        try:
            app.call('sidebar-menu-state', node=fav, item=title)
            return True
        except RuntimeError:
            return False
    def stored(): return [s.lower() for s in (app.call('defaults', key=key, persistent=True) or [])]
    def choose(command, **arguments):
        # Keep recording each missing behavior on the pre-CG1 App, instead of aborting at its missing menu.
        try:
            return app.call(command, **arguments)
        except RuntimeError as error:
            return {'error': str(error)}
    sync = {'id': 'g1', 'title': 'Gear sync', 'start': 10, 'end': 40, 'url': MEET}
    cal(action='fixture', access='granted', events=[sync])
    cal(action='clock', minutes=0)
    wait_until(lambda: live().get('tiles'), timeout=5, step=.05)
    hover(fav)
    card = glance()
    gear = card.get('gear') or {}
    results['cal_card_gear_menu'] = {'ok': card.get('kind') == 'calendar' and gear.get('shown') is True
        and gear.get('items') == ['Refresh', '-', 'Disable Live Calendar'] and gear.get('enabled') == [True, True]
        and gear.get('refreshing') is False, 'gear': gear}

    # Keep the same native-menu acceptance at two window origins. AppKit's
    # hardware cursor can be elsewhere than the socket pointer; menu teardown
    # must not replace the socket's Favorite hover with that unrelated position.
    original_frame = app.call('window-state')['frame']
    refresh_cases = []
    try:
        for window_frame in [None, [0, 0, *original_frame[2:]]]:
            if window_frame is not None:
                app.call('hover', leave=True, ms=300)
                app.call('window-frame', frame=window_frame)
                cal(action='fixture', access='granted', events=[sync])
                wait_until(lambda: live().get('tiles'), timeout=5, step=.05)
                hover(fav)
                glance()
            # Refresh: new events arrive slowly (fixture delay); the spinner stands where the gear was until they land.
            cal(action='fixture', access='granted', delayMs=900,
                events=[sync, {'id': 'g2', 'title': 'Added before refresh', 'start': 20, 'end': 50}])
            tracking = choose('glance-open', control='gear', item='Refresh')
            during = glance(wait=False).get('gear') or {}
            done = wait_until(lambda: (lambda s: s if (s.get('gear') or {}).get('refreshing') is False else None)(glance(wait=False)),
                              timeout=6, step=.05) or glance(wait=False)
            frame, spin = during.get('frame') or [0, 0, 0, 0], during.get('spinnerFrame') or [0, 0, 0, 0]
            centred = abs((frame[0] + frame[2] / 2) - (spin[0] + spin[2] / 2)) <= 1 and abs((frame[1] + frame[3] / 2) - (spin[1] + spin[3] / 2)) <= 1
            after_gear = done.get('gear') or {}
            refreshes = cal().get('refreshes', 0)
            # Keeping the card through native tracking must not pin it open.
            app.call('hover', leave=True, ms=300)
            left_closes = glance(wait=False).get('shown') is False
            refresh_cases.append({'ok': tracking.get('tracked') is True and tracking.get('cardStayedVisible') is True
                and tracking.get('opened') is True and during.get('refreshing') is True and during.get('spinner') is True
                and during.get('shown') is False and centred and after_gear.get('shown') is True and after_gear.get('spinner') is False
                and 'g2' in [e['id'] for e in done.get('events', [])] and refreshes == 1 and left_closes,
                'tracking': tracking, 'during': during, 'after': after_gear, 'events': [e['id'] for e in done.get('events', [])], 'refreshes': refreshes,
                'leftCloses': left_closes,
                'windowOrigin': (window_frame or original_frame)[:2]})
    finally:
        app.call('window-frame', frame=original_frame)
    representative = next((case for case in refresh_cases if not case['ok']), refresh_cases[0])
    results['cal_card_gear_refresh'] = {**representative, 'ok': all(case['ok'] for case in refresh_cases), 'windowOrigins': refresh_cases}

    # Disable Live Calendar: the card closes; the Favorite becomes plain (no card, no countdown, no Live Calendar
    # items) and the choice is stored for this Favorite.
    cal(action='fixture', access='granted', events=[sync])
    wait_until(lambda: live().get('tiles'), timeout=5, step=.05)
    hover(fav)
    glance()
    choose('glance-open', control='gear', item='Disable Live Calendar')
    closed = wait_until(lambda: glance(wait=False).get('shown') is False, timeout=3, step=.05)
    plain = wait_until(lambda: (lambda s: s if not s.get('tiles') and s.get('active') is False else None)(live()), timeout=3, step=.05)
    saved = stored()
    hover(fav)
    again = glance(wait=False)
    menu = {t: has_item(t) for t in ('Enable Live Calendar', 'Disable Live Calendar', 'Show Time to Next Meeting', 'Meeting Reminder')}
    plate = app.call('favorite-badge', favorite=fav).get('subtitleShown')
    app.call('hover', leave=True, ms=300)
    results['cal_live_disable_per_favorite'] = {'ok': bool(closed) and bool(plain) and saved == [fav.lower()]
        and again.get('kind') != 'calendar' and not plate
        and menu == {'Enable Live Calendar': True, 'Disable Live Calendar': False, 'Show Time to Next Meeting': False, 'Meeting Reminder': False},
        'stored': saved, 'hoverAgain': again.get('kind'), 'menu': menu, 'plate': plate, 'live': plain}

    # Enable Live Calendar (the tile menu): countdown, card and Live Calendar items come back; the stored list empties.
    choose('sidebar-menu', node=fav, item='Enable Live Calendar')
    back = wait_until(lambda: (lambda s: s if s.get('tiles') and s.get('active') else None)(live()), timeout=5, step=.05)
    hover(fav)
    card_back = glance()
    menu_back = {t: has_item(t) for t in ('Enable Live Calendar', 'Disable Live Calendar', 'Meeting Reminder')}
    app.call('hover', leave=True, ms=300)
    results['cal_live_enable_per_favorite'] = {'ok': bool(back) and card_back.get('kind') == 'calendar' and stored() == []
        and menu_back == {'Enable Live Calendar': False, 'Disable Live Calendar': True, 'Meeting Reminder': True},
        'card': card_back.get('kind'), 'menu': menu_back, 'stored': stored()}


def live_persistence_checks(factory, results, wait_until, new_tab):
    """Disable one of two Google Calendar Favorites, then restart the real App on the same data."""
    key = 'open.favorites.liveCalendarDisabled'
    app = None
    try:
        app = factory(urls=('about:blank',), fresh=True, extra_args=ENGINE_SWITCHES)
        app.call('defaults', key=key, value=None)
        first = new_tab(app, 'https://calendar.google.com/calendar/u/0/r/day')
        app.call('favorite', tab=first)
        second = new_tab(app, 'https://calendar.google.com/calendar/u/1/r/week')
        app.call('favorite', tab=second)
        new_tab(app, 'about:blank')
        app.call('calendar', action='fixture', access='granted', events=[{'id': 'persist', 'title': 'Restart sync', 'start': 5, 'end': 35, 'url': MEET}])
        wait_until(lambda: len(app.call('calendar', action='live').get('tiles', [])) == 2, timeout=5, step=.05)
        app.call('sidebar-menu', node=first, item='Disable Live Calendar')
        saved = app.call('defaults', key=key, persistent=True)
        app.quit()
        app = None
        app = factory(urls=(), fresh=False, extra_args=ENGINE_SWITCHES)
        app.call('calendar', action='fixture', access='granted', events=[{'id': 'persist', 'title': 'Restart sync', 'start': 5, 'end': 35, 'url': MEET}])
        live = wait_until(lambda: (lambda state: state if state.get('active') and len(state.get('tiles', [])) == 1 else None)(app.call('calendar', action='live')),
                          timeout=5, step=.05) or {}
        app.call('hover', favorite=first, ms=800)
        first_card = app.call('glance-state', wait=False).get('kind')
        app.call('hover', leave=True, ms=300)
        app.call('hover', favorite=second, ms=800)
        second_card = app.call('glance-state').get('kind')
        app.call('hover', leave=True, ms=300)
        first_menu = app.call('sidebar-menu-state', node=first, item='Enable Live Calendar')
        second_menu = app.call('sidebar-menu-state', node=second, item='Disable Live Calendar')
        stored = app.call('defaults', key=key, persistent=True) or []
        tiles = {tile['tab'].lower() for tile in live.get('tiles', [])}
        results['cal_live_disable_restart_isolation'] = {'ok': [s.lower() for s in saved or []] == [first.lower()]
            and stored == saved and first_card != 'calendar' and second_card == 'calendar'
            and second.lower() in tiles and first.lower() not in tiles and bool(first_menu) and bool(second_menu),
            'saved': saved, 'restored': stored, 'cards': [first_card, second_card], 'tiles': list(tiles)}
    except RuntimeError as error:
        results['cal_live_disable_restart_isolation'] = {'ok': False, 'error': str(error)}
    finally:
        if app is not None:
            try:
                app.call('defaults', key=key, value=None)
            finally:
                app.quit()


def meet_route_checks(app, results, wait_until, cal):
    app.call('defaults', key='open.links.didSetDefaultMeetRoute', value=None)
    def rules():
        with open(app.call('save')) as stream: return json.load(stream).get('routingRules', [])
    def meet_rules(): return [r for r in rules() if r.get('match') == {'hostEquals': {'_0': 'meet.google.com'}}]
    def deliver(url): return subprocess.run(['/usr/bin/open', '-a', app.bundle, url], capture_output=True, text=True, timeout=15)
    def landed(url): return wait_until(lambda: [t for t in app.call('tabs') if t['url'].startswith(url)], timeout=8, step=.05)
    def meet_toasts(): return [t for t in app.call('toasts')['toasts'] if t['coalescingKey'] == 'meet-route' and not t['exiting']]
    before = meet_rules()
    first = 'https://meet.google.com/abc-defg-hij'
    deliver(first)
    tab = landed(first)
    toast = wait_until(meet_toasts, timeout=3, step=.05) or []
    added = meet_rules()
    state = cal()
    second = 'https://meet.google.com/xyz-abcd-efg'
    deliver(second)
    landed(second)
    time.sleep(0.5)
    again = cal()
    results['cal_meet_route_first_link'] = {
        'ok': not before and len(added) == 1 and added[0].get('destination') == {'mostRecentSpace': {}}
            and bool(tab) and bool(toast) and toast[0]['title'] == 'Meet links now open in your current Space!'
            and toast[0]['subtitle'] == 'Choose where they open' and state.get('meetRouteDone') is True
            and state.get('meetRouteAnnounced') == 1,
        'rules': added, 'toast': toast[:1], 'tab': tab[:1] if tab else tab, 'state': {k: state.get(k) for k in ('meetRouteDone', 'meetRouteAnnounced')}}
    results['cal_meet_route_once'] = {'ok': again.get('meetRouteAnnounced') == 1 and len(meet_rules()) == 1,
        'announced': again.get('meetRouteAnnounced'), 'rules': len(meet_rules())}


def arc_preferences_checks(app, results, wait_until, tmp, harness):
    """Synthetic Arc home: <home>/Library/Application Support/Arc (sidebar) + <home>/Library/Preferences/<domain>.plist."""
    import plistlib
    import runpy
    from pathlib import Path
    home = Path(tmp) / 'arc-prefs-home'
    arc = home / 'Library' / 'Application Support' / 'Arc'
    arc.mkdir(parents=True, exist_ok=True)
    runpy.run_path(str(Path(harness['ROOT']) / 'tools' / 'e2e' / 'firstrun.py'))['fixture'](arc)
    prefs_dir = home / 'Library' / 'Preferences'
    prefs_dir.mkdir(parents=True, exist_ok=True)
    prefs = {
        'folderPreviewEnabled': False, 'recentPagesPreviewEnabled': False,
        'calendarPreviewEnabled': False, 'cronPreviewEnabled': True,      # any calendar switch on -> on
        'gmailPreviewEnabled': False, 'outlookEmailPreviewEnabled': False,  # Outlook Mail: no Open switch
        'didSetDefaultGoogleMeetRoute': True,
        'liveCalendarNotificationPreferences': json.dumps({'default': 'fiveMinutesBefore', 'unknown-profile': 'tenMinutesBefore'}).encode(),
        'unrelatedArcKey': 'ignored',
        # Audit A2: Favorite tile switches and host lists.
        'twitterBadgeEnabled': False, 'whatsAppBadgeEnabled': True,
        'topAppsBadgingDisabledHosts': ['Mail.Google.com'], 'topAppsSubtitleDisabledHosts': ['calendar.google.com'],
        # PB2 row 4: Capture in Portrait Mode.
        'portraitCaptureBackground': 'desktopWallpaper', 'portraitCaptureColorPercentage': 0.3, 'portraitCaptureHidesWatermark': True,
    }
    FAVORITE_KEYS = ('open.favorites.twitterBadgeEnabled', 'open.favorites.whatsAppBadgeEnabled',
                     'open.favorites.badgingDisabledHosts', 'open.favorites.subtitleDisabledHosts',
                     'open.capture.portraitBackground', 'open.capture.portraitColorPercentage', 'open.capture.portraitHidesWatermark')
    for key in FAVORITE_KEYS: app.call('defaults', key=key, value=None)
    with open(prefs_dir / 'company.thebrowser.Browser.plist', 'wb') as f: plistlib.dump(prefs, f, fmt=plistlib.FMT_BINARY)
    def d(key): return app.call('defaults', key=key)
    for key in ARC_PREF_KEYS + ('open.links.didSetDefaultMeetRoute',): app.call('defaults', key=key, value=None)
    with open(app.call('save')) as stream: snapshot = json.load(stream)
    default_profile = snapshot['profiles'][0]['id'] if snapshot.get('profiles') else ''
    reminder_key = 'open.calendar.reminder.' + default_profile
    app.call('defaults', key=reminder_key, value=None)
    def state(): return app.call('first-run')
    keys = ARC_PREF_KEYS + ('open.links.didSetDefaultMeetRoute', reminder_key) + FAVORITE_KEYS
    before = {k: d(k) for k in keys}  # registered defaults read as their default value
    app.call('first-run', action='settings-import', directory=str(arc))
    app.call('first-run', action='settings-next')
    app.call('first-run', action='settings-run')
    report = wait_until(lambda: (lambda s: s if s.get('settingsStep') == 'report' else None)(state()), timeout=60, step=.05) or state()
    mapped = report.get('arcPreferences', {})
    written = {k: d(k) for k in keys}
    # previewsPages has no Arc key: it keeps its value.
    expected = {'open.general.previewsFolders': False, 'open.general.previewsRecents': False, 'open.general.previewsCalendar': True,
                'open.general.previewsGmail': False, 'open.general.previewsPages': before['open.general.previewsPages'],
                'open.links.didSetDefaultMeetRoute': True, reminder_key: 'fiveMinutes',
                'open.favorites.twitterBadgeEnabled': False, 'open.favorites.whatsAppBadgeEnabled': True,
                'open.favorites.badgingDisabledHosts': ['mail.google.com'],
                'open.favorites.subtitleDisabledHosts': ['calendar.google.com'],
                'open.capture.portraitBackground': 'wallpaper', 'open.capture.portraitColorPercentage': 0.3,
                'open.capture.portraitHidesWatermark': True}
    results['cal_arc_prefs_import'] = {
        'ok': bool(default_profile) and written == expected and report.get('lastOutcome', {}).get('Live Calendar reminders') == 1
            and report.get('lastOutcome', {}).get('Arc settings') == 13 and not report.get('lastFailures', {}).get('Arc settings'),
        'written': written, 'mapped': mapped, 'outcome': report.get('lastOutcome'), 'failures': report.get('lastFailures')}
    try:
        app.call('first-run', action='settings-done')
    except RuntimeError:
        pass
    # Undo the import: Arc's settings go back to Open's previous (absent) values.
    app.call('sidebar-key', key='z', modifiers=['command'])
    wait_until(lambda: not state().get('importUndoInProgress', False), timeout=30, step=.05)
    undone = wait_until(lambda: (lambda w: w if w == before else None)({k: d(k) for k in keys}), timeout=10, step=.1) \
        or {k: d(k) for k in keys}
    results['cal_arc_prefs_undo'] = {'ok': undone == before and written != before, 'before': before, 'after': undone}
