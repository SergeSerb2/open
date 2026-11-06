"""Section 7 acceptance through the built App, its native commands and real stores."""
import json
import os
from pathlib import Path


def run(factory, results, tmp, wait_until, restore_defaults):
    fixture = Path(tmp) / 'settings-live.html'
    fixture.write_text('<!doctype html><title>Settings fixture</title><body>Settings fixture</body>')
    url = fixture.resolve().as_uri()
    app = factory(urls=(url,), fresh=True)
    keys = ('open.appIcon.selectedID', 'open.advanced.tabSleepMode', 'open.settings.lastPane',
            'open.general.searchSuggestNoticeDismissed', 'open.links.openPeekShiftClick',
            'open.links.openPeekOtherSites', 'open.peek.shiftClick', 'open.peek.otherSites')
    saved = {key: app.call('defaults', key=key, persistent=True) for key in keys}

    def profile_sheet():
        return wait_until(lambda: (lambda s: s if s['creating'] and s['sheet'] else None)(
            app.call('settings-profile')), timeout=5, step=.05)

    def cancel_sheet():
        app.call('settings-profile', cancel=True)
        assert wait_until(lambda: not app.call('settings-profile')['sheet'], timeout=5, step=.05)

    def close_settings():
        s = app.call('settings-state')
        if s['settingsVisible']:
            app.call('key', key='w', modifiers=['cmd'], window=s['settings'], route='app')
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)

    try:
        for key in keys: app.call('defaults', key=key, value=None)
        app.call('defaults', key='open.general.searchSuggestNoticeDismissed', value=True)
        app.call('wait', tab=app.call('tabs')[0]['id'])
        # Native File command, the exact Profiles sheet, and inert cancellation.
        app.call('menu-perform', id='new-profile')
        sheet = profile_sheet()
        results['settings_new_profile_command'] = {'ok': bool(sheet) and sheet['pane'] == 'profiles'
            and sheet['spaces'] == [], 'sheet': sheet}
        if os.environ.get('OPEN_SETTINGS_FAIL_IN_SHEET') == '1':
            raise AssertionError('forced failure with the real Create Profile sheet open')
        cancel_sheet(); close_settings()
        source = app.call('window-state')['space']
        app.call('sidebar-menu', item='Set Profile/New Profile…')
        sheet = profile_sheet()
        results['settings_new_profile_sidebar_source'] = {'ok': bool(sheet) and sheet['pane'] == 'profiles'
            and sheet['spaces'] == [source], 'sheet': sheet}
        cancel_sheet(); close_settings()

        # AppKit's menu fallback must not turn a typing Cmd+, into Settings.
        app.call('key', key='l', modifiers=['cmd'], route='app')
        assert wait_until(lambda: app.call('commandbar-state').get('presented'), timeout=5, step=.05)
        app.call('key', text='settings typing')
        app.call('key', key=',', modifiers=['cmd'], route='app')
        s = app.call('settings-state'); bar = app.call('commandbar-state')
        app.call('key', key='escape', route='app')
        escaped = wait_until(lambda: not app.call('commandbar-state')['presented'], timeout=5, step=.05)
        results['settings_cmd_comma_typing_guard'] = {'ok': not s['settingsVisible'] and bar['presented']
            and bar['text'] == 'settings typing' and bool(escaped), 'escapeDismissed': bool(escaped)}
        app.call('menu-perform', id='check-for-updates')
        s = app.call('settings-state')
        results['settings_general_action_error'] = {'ok': s['pane'] == 'general'
            and s['generalError'] == 'An update feed is not available yet.', 'error': s['generalError']}

        # The picker action writes the actual preference and replaces NSApp's actual image.
        app.call('settings-pane', pane='appIcon')
        icon_rows = {}
        for icon in ('openDark', 'openLight', 'openMono', 'openColor', 'openRetro'):
            s = app.call('settings-icon', select=icon)
            icon_rows[icon] = {'ok': s['selected'] == icon and s['applied'] == icon
                and s['matchesApplication'] and s['pixels'] == [[1024, 1024]] and not s['error'],
                'pixels': s['pixels']}
        first = app.call('settings-icon', select='openDark')
        again = app.call('settings-icon', select='openDark')
        reset = app.call('settings-icon', select='openDefault')
        results['settings_app_icon_live'] = {'ok': all(row['ok'] for row in icon_rows.values())
            and first['imageObject'] == again['imageObject'] and reset['imageObject'] == 'bundle',
            'icons': icon_rows, 'cacheReused': first['imageObject'] == again['imageObject'],
            'bundleReset': reset['imageObject'] == 'bundle'}
        app.call('settings-icon', select='openDark')

        # Global Never also seeds a new Profile and reconciles stored divergence on launch.
        app.call('defaults', key='open.advanced.tabSleepMode', value='never')
        app.call('space-create', title='Never Space', profile='Never Profile')
        snapshot = Path(app.call('save'))
        data = json.loads(snapshot.read_text())
        profiles = data['profiles']
        results['settings_sleep_new_profile'] = {'ok': all(p['settings']['sleepMode'] == 'off' for p in profiles),
            'modes': [p['settings']['sleepMode'] for p in profiles]}
        app.quit()
        data['profiles'][0]['settings']['sleepMode'] = 'aggressive'
        snapshot.write_text(json.dumps(data))
        app = factory(urls=(url,))
        app.call('wait', tab=app.call('tabs')[0]['id'])
        restored = wait_until(lambda: (lambda s: s if s['restoreStartedMs'] is not None else None)(
            app.call('settings-icon')), timeout=10, step=.05)
        timing = app.call('timing')
        results['settings_app_icon_after_content'] = {'ok': bool(restored) and restored['applied'] == 'openDark'
            and restored['matchesApplication'] and restored['pixels'] == [[1024, 1024]]
            and restored['restoreStartedMs'] >= timing['windowShown']
            and restored['restoreStartedMs'] >= timing['firstContentfulPaint'],
            'restore': restored, 'timing': timing, 'load': os.getloadavg()}
        modes = app.call('sleep-mode')
        results['settings_sleep_launch_reconcile'] = {'ok': all(mode == 'off' for mode in modes.values()),
            'modes': list(modes.values())}

        pairs = (('open.links.openPeekShiftClick', 'open.peek.shiftClick'),
                 ('open.links.openPeekOtherSites', 'open.peek.otherSites'))
        for canonical, legacy in pairs:
            app.call('defaults', key=canonical, value=None)
            app.call('defaults', key=legacy, value=False)
        app.quit(); app = factory(urls=(url,))
        migrated = [app.call('defaults', key=canonical, persistent=True) for canonical, _ in pairs]
        for canonical, _ in pairs: app.call('defaults', key=canonical, value=True)
        app.quit(); app = factory(urls=(url,))
        winning = [app.call('defaults', key=canonical, persistent=True) for canonical, _ in pairs]
        results['settings_peek_migration'] = {'ok': migrated == [False, False] and winning == [True, True],
            'legacyCopiedWhenMissing': migrated, 'canonicalWins': winning}
    finally:
        if not app.closed:
            app.call('settings-profile', cancel=True)
            app.call('settings-icon', select='openDefault')
        restore_defaults(app, saved)
        app.quit()
