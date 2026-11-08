"""Real App Welcome tab lifecycle, native page, and finite CA playlist.

Only the existing automation socket and the App's own event/menu paths are used.
No global input or real user data. No preference keys are changed by this suite.
"""
import json
import os
import shutil
import subprocess
import time
from pathlib import Path


def run(factory, results, tmp, api):
    root = Path(api.ROOT)
    evidence = root / '.re/handoff/sections/s17/c4'
    evidence.mkdir(parents=True, exist_ok=True)
    app = None
    server, origin = api._fixture_server('Welcome')

    def record(name, ok, **details):
        results[name] = dict(ok=bool(ok), loadAverage=list(os.getloadavg()), **details)

    def state():
        return app.call('welcome')

    def await_state(predicate, timeout=8):
        return api.wait_until(lambda: (lambda s: s if predicate(s) else None)(state()), timeout=timeout, step=.1)

    def screenshot(name):
        path = str(evidence / (name + '.png'))
        app.call('snapshot', path=path)
        return path

    def cpu(label):
        before = state()['appCPUSeconds']
        start = time.monotonic()
        time.sleep(8)
        after = state()['appCPUSeconds']
        elapsed = time.monotonic() - start
        return dict(label=label, appPercent=(after-before)/elapsed*100,
                    seconds=elapsed, loadAverage=list(os.getloadavg()))

    try:
        app = factory(urls=('about:blank',), fresh=True)
        blank = app.call('tabs')[0]['id']
        app.call('wait', tab=blank)
        baseline = state()
        time.sleep(2)
        blank_cpu = cpu('blank tab')
        record('W01_no_welcome_no_work', baseline['hostCount'] == 0
               and baseline['animationCount'] == 0 and not baseline['pendingCompletion'], state=baseline)
        creation_count = baseline['engineContentCreationCount']
        inserted = app.call('welcome', action='insert')
        welcome = inserted['tab']
        shown = await_state(lambda s: s['visible'] and s['activeCard'] == 1 and s['animating'])
        tab = app.call('tab-state', tab=welcome)
        record('W02_insert_native_today', shown and tab['url'] == 'open://welcome'
               and tab['title'] == 'Welcome to Open' and tab['selected'] and tab['section'] == 'today'
               and app.call('tabs')[0]['id'] == welcome and tab['favicon'], tab=tab, state=shown)
        record('W03_never_engine', shown and shown['engineInternalPages'] == 0
               and shown['engineContentCreationCount'] == creation_count and not tab['loaded'] and 'page' not in tab,
               tab=tab, state=shown)
        labels = state()['cards']
        record('W04_AX_cards', len(labels) == 4 and all(c['label'] == title + '. ' + detail
               and c['role'] == 'AXButton' and 'Replay' in c['actions']
               for c, (title, detail) in zip(labels, COPY)), cards=labels)
        record('W05_address_label', state()['urlField'] == 'Welcome to Open', state=state())
        screenshot('welcome-playing')
        stopped = await_state(lambda s: s['playedCards'] == [1, 2, 3, 4]
                              and s['playlist'] == 'stopped' and not s['animating'], timeout=38)
        record('W06_finite_playlist_1_to_4', stopped and stopped['activeCard'] == 4
               and stopped['duration'] == 8.5 and stopped['completionCount'] == 4
               and stopped['animationCount'] == 0 and not stopped['pendingCompletion'], state=stopped)
        if not stopped:
            raise AssertionError('Welcome playlist did not finish in order')
        completion_count = stopped['completionCount']
        welcome_cpu = cpu('Welcome stopped')
        stable = state()
        record('W07_idle_no_pending_work', not stable['animating'] and stable['animationCount'] == 0
               and not stable['pendingCompletion'] and stable['completionCount'] == completion_count,
               blank=blank_cpu, welcome=welcome_cpu, state=stable)
        screenshot('welcome-stopped')
        hover = app.call('welcome', action='hover', card=2)
        record('W08_hover', hover['animating'] and hover['activeCard'] == 2 and hover['playlist'] == 'stopped', state=hover)
        replay = app.call('welcome', action='replay', card=3)
        record('W09_AX_replay', replay['animating'] and replay['activeCard'] == 3 and replay['playlist'] == 'stopped', state=replay)
        for value in (0, 5):
            try:
                app.call('welcome', action='replay', card=value)
                refused = False
            except RuntimeError:
                refused = True
            record('W10_invalid_card_%d' % value, refused)
        app.call('select', tab=blank)
        hidden = await_state(lambda s: not s['visible'] and s['animationCount'] == 0)
        record('W11_hidden_tab_stops', hidden and all(not h['animating'] for h in hidden['hosts']), state=hidden)
        try:
            app.call('welcome', action='replay', card=1)
            refused = False
        except RuntimeError:
            refused = True
        record('W12_hidden_replay_refused', refused)
        app.call('select', tab=welcome)
        await_state(lambda s: s['visible'])
        app.call('welcome', action='replay', card=1)
        app.call('command', id='minimize-window')
        mini = api.wait_until(lambda: app.call('window-state')['miniaturized'], timeout=4, step=.1)
        hidden = await_state(lambda s: not s['visible'] and s['animationCount'] == 0)
        record('W13_minimize_stops', mini and hidden and not hidden['animating'] and not hidden['pendingCompletion'], state=hidden)
        app.call('window-deminiaturize')
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        await_state(lambda s: s['visible'])
        # Real app keyboard route, from the new native card focus context.
        app.call('key', key='return')
        keyboard_one = state()
        app.call('key', key='tab')
        app.call('key', key='space')
        keyboard_two = state()
        record('W25_card_keyboard', keyboard_one['activeCard'] == 1
               and keyboard_two['activeCard'] == 2 and keyboard_two['focusedCard'] == 2,
               first=keyboard_one, second=keyboard_two)
        app.call('key', key='l', modifiers=['cmd'])
        bar = app.call('commandbar-state')
        record('W14_commandbar_label', bar.get('presented') and bar.get('text') == 'Welcome to Open', state=bar)
        app.call('key', key='escape')
        app.call('key', key='l', modifiers=['cmd'])
        app.call('key', text=origin + '/from-welcome')
        app.call('key', key='return')
        navigated = api.wait_until(lambda: app.call('tab-state', tab=welcome) if
            app.call('tab-state', tab=welcome)['url'] == origin + '/from-welcome' else None, timeout=10, step=.1)
        app.call('wait', tab=welcome)
        record('W15_same_tab_web_navigation', navigated and navigated['id'] == welcome
               and app.eval(welcome, 'location.href') == origin + '/from-welcome'
               and not state()['visible'] and state()['hostCount'] == 0,
               tab=app.call('tab-state', tab=welcome), state=state())
        app.call('menu-perform', id='open-basics')
        help_state = await_state(lambda s: s['visible'])
        welcome = help_state['tab']
        count = len(app.call('tabs'))
        app.call('menu-perform', id='open-basics')
        record('W16_help_reuses_current_space', state()['tab'] == welcome and len(app.call('tabs')) == count, state=state())
        # Persisted URL and selection are ordinary model state.
        app.call('save')
        app.quit(); app = factory(urls=())
        restored = await_state(lambda s: s['visible'])
        record('W17_session_restore', restored and restored['tab'] == welcome and restored['engineInternalPages'] == 0
               and not app.call('tab-state', tab=welcome)['loaded'], state=restored)
        app.call('command', id='archive-tab')
        archived = api.wait_until(lambda: next((r for r in app.call('archive-list')['rows'] if r['id'] == welcome), None), timeout=8, step=.1)
        record('W18_archive_ordinary_tab', archived and archived['url'] == 'open://welcome', row=archived)
        app.call('command', id='restore-last-closed-tab')
        reopened = await_state(lambda s: s['visible'])
        record('W19_reopen_closed', reopened and reopened['tab'] == welcome and reopened['engineInternalPages'] == 0, state=reopened)
        app.call('command', id='archive-tab')
        app.call('library-open', section='archive')
        app.call('library-restore', id=welcome)
        app.call('library-close')
        app.call('menu-perform', id='open-basics')
        library_restored = await_state(lambda s: s['visible'])
        record('W20_library_restore', library_restored and library_restored['engineInternalPages'] == 0
               and sum(t['url'] == 'open://welcome' for t in app.call('tabs')) == 1, state=library_restored)
        before = len(app.call('tabs'))
        delivery = subprocess.run(['/usr/bin/open', '-a', app.bundle, 'open://welcome'], capture_output=True, text=True, timeout=15)
        rejection = api.wait_until(lambda: next((r for r in app.call('routing-log')['entries']
            if r['decision']['request']['url'] == 'open://welcome'), None), timeout=5, step=.1)
        record('W21_external_internal_refused', delivery.returncode == 0 and rejection
               and 'rejected (not http/https)' in rejection['summary'] and len(app.call('tabs')) == before,
               decision=rejection, deliveryCode=delivery.returncode)
        # Footer uses the existing windows, never an engine page.
        browser_window = app.call('window-state')['id']
        app.call('welcome', action='reveal', card=4)
        screenshot('welcome-footer')
        app.call('welcome', action='link', link='shortcuts')
        shortcut_window = api.wait_until(lambda: next((w for w in app.call('windows')
            if w['visible'] and 'Essential' in w['title']), None), timeout=5, step=.1)
        record('W26_footer_shortcuts', shortcut_window, window=shortcut_window)
        app.call('key', key='w', modifiers=['cmd'])
        app.call('window-focus', id=browser_window, activate=True)
        await_state(lambda s: s['visible'])
        app.call('welcome', action='link', link='settings')
        settings_window = api.wait_until(lambda: next((w for w in app.call('windows')
            if w['visible'] and w['title'] == 'Settings'), None), timeout=5, step=.1)
        record('W27_footer_settings', settings_window, window=settings_window)
        app.call('key', key='w', modifiers=['cmd'])
        app.call('window-focus', id=browser_window, activate=True)
        await_state(lambda s: s['visible'])
        app.call('welcome', action='replay', card=4)
        screenshot('welcome-replay-four')
        app.quit(); app = factory(urls=(), extra_env={'OPEN_E2E_REDUCE_MOTION': '1'})
        reduced = await_state(lambda s: s['visible'] and s['reduceMotion'])
        record('W22_reduce_motion_static', reduced and reduced['playlist'] == 'stopped'
               and not reduced['animating'] and reduced['animationCount'] == 0 and not reduced['pendingCompletion'], state=reduced)
        reduced_replay = app.call('welcome', action='replay', card=4)
        record('W23_reduce_motion_replay_static', reduced_replay['activeCard'] == 4 and not reduced_replay['animating']
               and reduced_replay['animationCount'] == 0 and not reduced_replay['pendingCompletion'], state=reduced_replay)
        screenshot('welcome-reduce-motion')
        app.call('key', key='t', modifiers=['cmd'])
        bar = app.call('commandbar-state')
        record('W24_cmd_t_native_context', bar.get('presented') and bar.get('mode') == 'newTab', state=bar)
        app.call('key', key='escape')
    finally:
        if app:
            app.quit()
        server.shutdown(); server.server_close()
        for source in Path(tmp).glob('open.log*'):
            shutil.copyfile(source, evidence / source.name)
        (evidence / 'welcome-checks.json').write_text(json.dumps(dict(results), indent=2))


COPY = [
    ("Open your first tab", "Click New Tab in the sidebar or press ⌘T, then type a site or a search."),
    ("Pin what matters", "Drag a tab above the line to pin it. Today's tabs tidy themselves away."),
    ("A Space for every part of life", "Spaces give you separate sidebars for work, projects, and home. Swipe with two fingers to switch."),
    ("Two tabs side by side", "Drag a tab from the sidebar onto the page to make a Split View.")
]
