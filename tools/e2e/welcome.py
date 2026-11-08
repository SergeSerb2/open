"""Real App Welcome tab lifecycle, native page, and finite CA playlist.

Only the existing automation socket and the App's own event/menu paths are used.
No global input or real user data. Shared preferences are restored in finally.
"""
import json
import os
import plistlib
import shutil
import subprocess
import time
from pathlib import Path


def run(factory, results, tmp, api):
    if os.environ.get('OPEN_E2E_WELCOME_NEGATIVE') == '1':
        return negative_gates(factory, results, tmp, api)
    root = Path(api.ROOT)
    evidence = root / '.re/handoff/sections/s17/c4'
    evidence.mkdir(parents=True, exist_ok=True)
    app = None
    domain = 'io.github.sergeserb2.open'
    keys = ('open.settings.lastPane', 'open.library.lastSection', 'open.import.lastArcDir')
    exported = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
    before = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    saved = {key: before.get(key) for key in keys}
    for key in keys: subprocess.run(['defaults', 'delete', domain, key], capture_output=True)
    fixture_page = Path(tmp) / 'welcome-navigation.html'
    fixture_page.write_text('<!doctype html><title>Welcome navigation</title><h1>Welcome navigation</h1>')
    destination = fixture_page.as_uri()

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
               and stopped['animationCount'] == 0 and not stopped['pendingCompletion'], state=stopped,
               lastState=state(), lastWindow=app.call('window-state'), lastFocus=app.call('native-focus-state'))
        if not stopped:
            raise AssertionError('Welcome playlist did not finish in order')
        completion_count = stopped['completionCount']
        welcome_cpu = cpu('Welcome stopped')
        stable = state()
        app.call('select', tab=blank)
        await_state(lambda s: not s['visible'])
        time.sleep(1)
        warm_blank_cpu = cpu('warm blank tab after Welcome')
        app.call('select', tab=welcome)
        assert await_state(lambda s: s['visible']), 'Welcome did not return after idle comparison'
        record('W07_idle_no_pending_work', not stable['animating'] and stable['animationCount'] == 0
               and not stable['pendingCompletion'] and stable['completionCount'] == completion_count,
               blank=blank_cpu, warmBlank=warm_blank_cpu, welcome=welcome_cpu, state=stable)
        screenshot('welcome-stopped')
        app.call('welcome', action='hover', card=2, phase='exit')
        before_hover = len(state()['playedCards'])
        hover = app.call('welcome', action='hover', card=2)
        record('W08_hover', hover['animating'] and hover['activeCard'] == 2 and hover['playlist'] == 'stopped', state=hover)
        for _ in range(20): app.call('welcome', action='hover', card=2)
        hover_ended = await_state(lambda s: not s['animating'], timeout=10)
        stationary = []
        for _ in range(10):
            stationary.append(app.call('welcome', action='hover', card=2))
            time.sleep(1)
        stable_hover = state()
        record('W30_stationary_hover_one_replay', hover_ended
               and all(not s['animating'] and len(s['playedCards']) == before_hover + 1 for s in stationary)
               and len(stable_hover['playedCards']) == before_hover + 1
               and stable_hover['animationCount'] == 0 and not stable_hover['pendingCompletion']
               and stable_hover['cards'][1]['hovered'] and stable_hover['cards'][1]['trackingAreas'] == 1,
               beforeCount=before_hover, state=stable_hover, stableSeconds=10)
        app.call('welcome', action='hover', card=2, phase='exit')
        replay = app.call('welcome', action='replay', card=3)
        record('W09_AX_replay', replay['animating'] and replay['activeCard'] == 3 and replay['playlist'] == 'stopped', state=replay)
        for value in (0, 5):
            try:
                app.call('welcome', action='replay', card=value)
                refused = False
            except RuntimeError:
                refused = True
            record('W10_invalid_card_%d' % value, refused)
        for arguments in ({'action': 'unknown'}, {'action': 'state', 'unexpected': True}):
            try:
                app.call('welcome', **arguments)
                refused = False
            except RuntimeError:
                refused = True
            record('W29_refuse_' + ('unknown_action' if arguments['action'] == 'unknown' else 'unknown_argument'), refused)
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
        app.call('key', text=destination)
        app.call('key', key='return')
        navigated = api.wait_until(lambda: app.call('tab-state', tab=welcome) if
            app.call('tab-state', tab=welcome)['url'] == destination else None, timeout=10, step=.1)
        app.call('wait', tab=welcome)
        record('W15_same_tab_web_navigation', navigated and navigated['id'] == welcome
               and app.eval(welcome, 'location.href') == destination
               and app.eval(welcome, 'document.title') == 'Welcome navigation'
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
        app.call('key', key='w', modifiers=['cmd'])
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
        app.call('key', key='w', modifiers=['cmd'], window=shortcut_window['number'])
        app.call('window-focus', id=browser_window, activate=True)
        assert await_state(lambda s: s['visible']), 'Welcome did not return after Shortcuts'
        app.call('welcome', action='link', link='settings')
        settings_state = api.wait_until(lambda: (lambda s: s if s['settingsVisible'] and s['pane'] == 'general' else None)(
            app.call('settings-state')), timeout=5, step=.1)
        settings_window = next((w for w in app.call('windows') if settings_state and w['number'] == settings_state['settings']), None)
        record('W27_footer_settings', settings_state and settings_window and settings_window['visible'],
               window=settings_window, state=settings_state)
        if os.environ.get('OPEN_E2E_WELCOME_FAIL_FOOTER') == '1':
            raise RuntimeError('intentional early failure with owned Settings window open')
        app.call('key', key='w', modifiers=['cmd'], window=settings_window['number'])
        app.call('window-focus', id=browser_window, activate=True)
        assert await_state(lambda s: s['visible']), 'Welcome did not return after Settings'
        # The shared importer treats the internal URL as an ordinary model tab.
        from firstrun import fixture
        source = Path(tmp) / 'arc-welcome-synthetic'
        ids = fixture(source)
        sidebar_path = source / 'StorableSidebar.json'
        sidebar = json.loads(sidebar_path.read_text())
        items = sidebar['sidebar']['containers'][1]['items']
        for item in items:
            if isinstance(item, dict) and item.get('id') == ids['t0']:
                item['data']['tab']['savedURL'] = 'open://welcome'
                item['data']['tab']['savedTitle'] = 'Welcome to Open'
        sidebar_path.write_text(json.dumps(sidebar))
        app.call('first-run', action='settings-import', directory=str(source))
        app.call('first-run', action='settings-select', history=False)
        app.call('first-run', action='settings-next')
        app.call('first-run', action='settings-run')
        imported = api.wait_until(lambda: app.call('first-run') if
            app.call('first-run').get('settingsStep') == 'Report' else None, timeout=25, step=.1)
        app.call('first-run', action='settings-done')
        settings_state = app.call('settings-state')
        if settings_state['settingsVisible']:
            app.call('key', key='w', modifiers=['cmd'], window=settings_state['settings'])
        app.call('window-focus', id=browser_window, activate=True)
        app.call('space', space=ids['alpha'])
        app.call('select', tab=ids['t0'])
        imported_page = await_state(lambda s: s['visible'])
        imported_tab = app.call('tab-state', tab=ids['t0'])
        record('W28_import_ordinary_internal_tab', imported and imported_page
               and imported_tab['url'] == 'open://welcome' and not imported_tab['loaded']
               and imported_page['engineInternalPages'] == 0, state=imported_page, tab=imported_tab, report=imported)
        app.call('welcome', action='reveal', card=4)
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
        appearance_before = app.call('space-manager-lifecycle')['appAppearance']
        try:
            for appearance in ('dark', 'light'):
                app.call('appearance', name=appearance)
                for width, height in ((1280, 800), (1000, 700)):
                    app.call('window-frame', frame=[80, 60, width, height])
                    # Let AppKit finish layout and the appearance transaction.
                    time.sleep(.3)
                    design = state()
                    gates = design_gates(design, appearance)
                    capture = screenshot('welcome-%dx%d-%s' % (width, height, appearance))
                    record('W31_design_%dx%d_%s' % (width, height, appearance), all(gates.values()),
                           gates=gates, layout=design['layout'], screenshot=capture)
                # The guarantee refers to the content viewport, below chrome.
                # Adjust the outer window to exercise the exact lower boundary.
                viewport_height = state()['layout']['viewport'][1]
                app.call('window-frame', frame=[80, 60, 1000, 700 + 640 - viewport_height])
                time.sleep(.3)
                boundary = state()
                gates = design_gates(boundary, appearance)
                record('W32_content_640_' + appearance, all(gates.values())
                       and abs(boundary['layout']['viewport'][1] - 640) <= .5,
                       gates=gates, layout=boundary['layout'])
            # Exercise the other header inset and the illustration size cap.
            app.call('window-frame', frame=[80, 60, 1280, 1100])
            time.sleep(.3)
            tall = state()
            gates = design_gates(tall, 'light')
            record('W33_tall_content', all(gates.values()) and tall['layout']['viewport'][1] > 820,
                   gates=gates, layout=tall['layout'])
        finally:
            original = 'dark' if 'Dark' in appearance_before else 'light' if 'Aqua' in appearance_before else 'system'
            app.call('appearance', name=original)
        app.call('key', key='t', modifiers=['cmd'])
        bar = app.call('commandbar-state')
        record('W24_cmd_t_native_context', bar.get('presented') and bar.get('mode') == 'newTab', state=bar)
        app.call('key', key='escape')
    finally:
        try:
            api._restore_defaults(app, saved)
        finally:
            if app: app.quit()
        for source in Path(tmp).glob('open.log*'):
            shutil.copyfile(source, evidence / source.name)
        (evidence / 'welcome-checks.json').write_text(json.dumps(dict(results), indent=2))


COPY = [
    ("Open your first tab", "Click New Tab in the sidebar or press ⌘T, then type a site or a search."),
    ("Pin what matters", "Drag a tab above the line to pin it. Today's tabs tidy themselves away."),
    ("A Space for every part of life", "Spaces give you separate sidebars for work, projects, and home. Swipe with two fingers to switch."),
    ("Two tabs side by side", "Drag a tab from the sidebar onto the page to make a Split View.")
]


def design_gates(state, appearance):
    """Acceptance from the real native view frames and rendered layer colors."""
    layout = state['layout']
    width, height = layout['viewport']
    document = layout['document']
    footer = layout['footer']
    cards = layout['cards']
    dark = appearance == 'dark'
    ink = 1 if dark else 0
    contrast = .04 if dark else .06
    surface = [(1 - contrast) * c + contrast * ink for c in layout['background'][:3]] + [1]

    def near(actual, expected, tolerance=.005):
        return len(actual) == len(expected) and all(abs(a - b) <= tolerance for a, b in zip(actual, expected))

    color_ok = len(cards) == 4
    for card in cards:
        paint = card['paints']
        color_ok = color_ok and near(paint.get('surface', []), surface) \
            and near(paint.get('row', []), [ink, ink, ink, .14 if dark else .10]) \
            and near(paint.get('active', []), [61/255, 107/255, 1, .9]) \
            and abs(paint.get('sidebar', [0, 0, 0, 0])[3] - .55) <= .005
        if 'otherSidebar' in paint:
            color_ok = color_ok and abs(paint['otherSidebar'][3] - .55) <= .005
        if 'text' in paint:
            color_ok = color_ok and near(paint['text'], [ink, ink, ink, .75])
        if 'activeText' in paint:
            color_ok = color_ok and near(paint['activeText'], [1, 1, 1, 1])
    return {
        'fits_without_scroll': height >= 639.5 and document[3] <= height + .5
            and document[2] <= width + .5 and near(layout['scrollOrigin'], [0, 0], .5),
        'header_inset': abs(layout['headerTop'] - (56 if height <= 820 else 80)) <= .5,
        'footer_spacing': abs(layout['footerGap'] - 24) <= .5
            and footer[1] + footer[3] <= height - 31.5,
        'illustration_limits': len(cards) == 4 and all(119.5 <= c['illustration'][3]
            <= layout['columnWidth']/2 * 10/16 + .5 for c in cards),
        'undistorted_scenes': len(cards) == 4 and all(c['scale'][0] > 0
            and abs(c['scale'][0] - c['scale'][1]) < .001 for c in cards),
        'copy_fits': len(cards) == 4 and all(c['requiredTextHeight'] <= c['detail'][3]
            and c['requiredTitleWidth'] <= c['title'][2] for c in cards),
        'contrast': bool(color_ok),
        'only_permitted_labels': [c['labels'] for c in cards] == [['+ New Tab'], [], ['Home'], []],
        'static_without_pending_work': not state['animating'] and state['animationCount'] == 0
            and not state['pendingCompletion'],
    }


def negative_gates(factory, results, tmp, api):
    """Break-and-revert receipt driver. Requires an intentionally mutated build.

    The temporary build switches live only in the ignored receipt patch. They
    are removed before the final build. Without that patch each row must fail.
    All paths still launch and exercise the real App with temporary model roots.
    """
    evidence = Path(api.ROOT) / '.re/handoff/sections/s17/c4/negative'
    evidence.mkdir(parents=True, exist_ok=True)
    app = None
    domain = 'io.github.sergeserb2.open'
    exported = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
    before = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    saved = {'open.settings.lastPane': before.get('open.settings.lastPane')}
    subprocess.run(['defaults', 'delete', domain, 'open.settings.lastPane'], capture_output=True)

    def state(): return app.call('welcome')
    def visible(): return api.wait_until(lambda: state() if state()['visible'] else None, timeout=5, step=.1)
    def record(name, rejected, **details):
        if name != 'N_owned_window_cleanup_after_failure':
            print('EXPECTED FAIL: %s production gate; detected=%s' % (name, bool(rejected)), flush=True)
        results[name] = dict(ok=bool(rejected), expected='production assertion rejects deliberately broken gate',
                             loadAverage=list(os.getloadavg()), **details)
    try:
        for mutation in ('native', 'playlist', 'visibility', 'reduce', 'external', 'hover', 'layout', 'contrast', 'labels'):
            app = factory(urls=('about:blank',), fresh=True,
                          extra_env={'OPEN_E2E_WELCOME_MUTATION': mutation,
                                     'OPEN_E2E_REDUCE_MOTION': '1' if mutation in ('reduce', 'layout', 'contrast', 'labels') else '0'})
            blank = app.call('tabs')[0]['id']
            app.call('wait', tab=blank)
            initial = state()
            if mutation == 'external':
                before = len(app.call('tabs'))
                delivered = subprocess.run(['/usr/bin/open', '-a', app.bundle, 'open://welcome'],
                                            capture_output=True, timeout=15)
                landed = api.wait_until(lambda: len(app.call('tabs')) > before, timeout=5, step=.1)
                record('N_external_refusal', delivered.returncode == 0 and landed, tabs=app.call('tabs'))
            else:
                inserted = app.call('welcome', action='insert')
                if mutation == 'native':
                    native_gate = inserted['visible'] and inserted['engineContentCreationCount'] == initial['engineContentCreationCount']
                    record('N_native_host_engine_absence', not native_gate
                           and inserted['engineContentCreationCount'] > initial['engineContentCreationCount'], state=inserted)
                elif mutation == 'playlist':
                    visible()
                    ended = api.wait_until(lambda: state() if state()['completionCount'] >= 4 else None, timeout=38, step=.1)
                    finite_gate = ended and ended['playlist'] == 'stopped' and not ended['animating'] and ended['animationCount'] == 0
                    record('N_playlist_stops', ended and not finite_gate and ended['playedCards'][:4] == [1, 2, 3, 4], state=ended)
                elif mutation == 'visibility':
                    visible(); app.call('welcome', action='replay', card=1)
                    app.call('select', tab=blank)
                    hidden = state()
                    hidden_gate = not hidden['visible'] and hidden['animationCount'] == 0 \
                        and all(not h['animating'] for h in hidden['hosts'])
                    record('N_hidden_tab_stops', not hidden_gate
                           and any(h['animating'] for h in hidden['hosts']), state=hidden)
                    app.call('select', tab=inserted['tab']); visible()
                    app.call('welcome', action='replay', card=1)
                    app.call('command', id='minimize-window')
                    mini = api.wait_until(lambda: app.call('window-state')['miniaturized'], timeout=4, step=.1)
                    hidden = state()
                    record('N_minimize_stops', mini and hidden['animating'] and hidden['animationCount'] > 0, state=hidden)
                elif mutation == 'reduce':
                    shown = visible()
                    static_gate = shown and shown['reduceMotion'] and not shown['animating'] and shown['animationCount'] == 0
                    record('N_reduce_motion_static', shown and not static_gate and shown['animating'], state=shown)
                elif mutation == 'hover':
                    visible()
                    app.call('welcome', action='hover', card=2, phase='exit')
                    before_hover = len(state()['playedCards'])
                    for _ in range(20): app.call('welcome', action='hover', card=2)
                    repeated = state()
                    record('N_stationary_hover_one_replay', len(repeated['playedCards']) > before_hover + 1,
                           beforeCount=before_hover, state=repeated)
                elif mutation in ('layout', 'contrast', 'labels'):
                    visible()
                    app.call('appearance', name='dark')
                    app.call('window-frame', frame=[80, 60, 1000, 700])
                    time.sleep(.3)
                    broken = state()
                    gates = design_gates(broken, 'dark')
                    gate = {'layout': 'fits_without_scroll', 'contrast': 'contrast', 'labels': 'only_permitted_labels'}[mutation]
                    record('N_design_' + mutation, not gates[gate], gates=gates, layout=broken['layout'])
            app.quit(); app = None
        # Force an early exception after a specific owned window appears.
        app = factory(urls=('about:blank',), fresh=True)
        app.call('welcome', action='insert'); visible()
        app.call('welcome', action='link', link='settings')
        settings = app.call('settings-state')
        forced = False
        try:
            if settings['settingsVisible'] and settings['pane'] == 'general':
                raise RuntimeError('intentional failure with Settings open')
        except RuntimeError as error:
            forced = str(error) == 'intentional failure with Settings open'
        finally:
            app.quit()
        report = app.quit_report
        record('N_owned_window_cleanup_after_failure', forced and report['ok']
               and not report['remaining_processes'] and report['windows_after_quit']['count'] == 0,
               cleanup=report)
        app = None
    finally:
        try:
            api._restore_defaults(app, saved)
        finally:
            if app: app.quit()
        (evidence / 'results.json').write_text(json.dumps(dict(results), indent=2))
