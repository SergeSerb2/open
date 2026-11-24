"""Real App Welcome tab: the basics page, its clip playlist and lifecycle.

The page follows the reference layout and timing (docs/re/onboarding.md §6):
a staged reveal, a four-step accordion, one clip panel playing clips recorded
from the real app (tools/basics), Replay All, click-to-play and Reduce Motion.
Only the automation socket and the App's own event/menu paths are used. No
global input or real user data. Shared preferences are restored in finally.
"""
import json
import ctypes
import os
import plistlib
import shutil
import subprocess
import time
from collections import Counter
from statistics import median
from pathlib import Path


def browser_thread_names(pid):
    """Read the browser's OS thread metadata; never attach a sampler/debugger."""
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    class ThreadInfo(ctypes.Structure):
        _fields_ = [('user', ctypes.c_uint64), ('system', ctypes.c_uint64)] + [
            (key, ctypes.c_int32) for key in ('cpu', 'policy', 'state', 'flags', 'sleep', 'curpri', 'priority', 'maxpri')
        ] + [('name', ctypes.c_char * 64)]
    tids = (ctypes.c_uint64 * 1024)()
    size = lib.proc_pidinfo(pid, 6, 0, tids, ctypes.sizeof(tids)) # PROC_PIDLISTTHREADS
    if size <= 0 or size >= ctypes.sizeof(tids) or size % 8:
        raise RuntimeError('could not enumerate browser threads within the 1024-thread limit')
    names = []
    for tid in list(tids)[:size // 8]:
        info = ThreadInfo()
        if lib.proc_pidinfo(pid, 5, tid, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info):
            names.append(info.name.decode(errors='replace')) # PROC_PIDTHREADINFO
    if not names:
        raise RuntimeError('could not read browser thread metadata')
    return names



COPY = [
    ('Pin what matters', "Drag a tab above the line to pin it. Pinned tabs stay put; today's tabs tidy themselves away."),
    ('A Space for every part of life', 'Spaces give you separate sidebars for work, projects, and home. Click a Space or swipe to switch.'),
    ('Two tabs side by side', 'Drag a tab from the sidebar to the side of the page to make a Split View.'),
    ('Open your first tab', 'Click New Tab in the sidebar, or press'),
]
CLIP = 8.5
PERIOD = 9.0          # clip plus the hold before the next step (reference)
REVEAL_CLIP = 2.9     # the clip panel and first clip start (reference)
PLAYLIST_END = REVEAL_CLIP + 3 * PERIOD + CLIP  # 38.8 s


def at_rest(state):
    return state['animationCount'] == 0 and not state['pendingCompletion'] \
        and state.get('pendingDisplayUpdates', 0) == 0 and not state['animating'] and state.get('decoders', 0) == 0


def process_cpu_seconds(pid):
    # Match import-robust's process-wide counter. Keep the large native
    # layout/AX state reply outside the idle measurement itself.
    value = subprocess.check_output(['ps', '-p', str(pid), '-o', 'time='], text=True).strip()
    return sum(float(v) * 60**i for i, v in enumerate(reversed(value.split(':'))))


def run_idle_contract(factory, results, tmp, api):
    """Real launch, complete playlist, five-second rest, then hide during play."""
    app = factory(urls=('about:blank',), fresh=True)
    try:
        app.call('wait', tab=app.call('tabs')[0]['id'])
        api.place_away_from_cursor(app, 1280, 800)
        names = browser_thread_names(app.pid)
        results['no_stack_sampling_after_launch'] = dict(ok='StackSamplingProfiler' not in names, threadNames=names)
        inserted = app.call('welcome', action='insert')
        started = time.monotonic()
        settled = api.wait_until(lambda: (lambda s: s if s['ended'] and at_rest(s) else None)(app.call('welcome')),
                                 timeout=PLAYLIST_END + 6, step=.1)
        elapsed = time.monotonic() - started
        final = settled or app.call('welcome')
        results['playlist_settles'] = dict(ok=bool(settled and final['playedCards'] == [1, 2, 3, 4]
            and final['completionCount'] == 4 and final.get('playlistElapsed', elapsed) <= PLAYLIST_END + 1.5),
            elapsedSeconds=elapsed, limitSeconds=PLAYLIST_END + 1.5, state=final)
        # The reveal prepares clip 0 under the fade; the playlist must start that player, not decode
        # clip 0 a second time: one player per clip.
        players = ((final.get('clip') or {}).get('playersCreated'))
        results['playlist_reuses_prepared_clip'] = dict(ok=bool(settled and players == 4), playersCreated=players)
        before = process_cpu_seconds(app.pid); start = time.monotonic(); time.sleep(5)
        cpu_delta = process_cpu_seconds(app.pid)-before; seconds = time.monotonic()-start
        cpu = cpu_delta/seconds*100; after = app.call('welcome')
        results['idle_after_playlist'] = dict(ok=bool(settled and at_rest(after)
            and (app.config != 'Release' or cpu < 1)), appCPUPercent=cpu, seconds=seconds,
            limitPercent=1, loadAverage=list(os.getloadavg()), state=after)
        app.call('close', tab=inserted['tab'])
        app.call('welcome', action='insert')
        results['miniaturized_idle'] = pause_resume_playlist(app, api)
    finally:
        app.quit()


def run(factory, results, tmp, api):
    # Normal and reduced paths are explicit, independent of the host's setting.
    os.environ.setdefault('OPEN_E2E_REDUCE_MOTION', '0')
    if os.environ.get('OPEN_E2E_WELCOME_RESTORE_ONLY') == '1':
        return run_restore_contract(factory, results, tmp, api)
    if os.environ.get('OPEN_E2E_WELCOME_IDLE_ONLY') == '1':
        return run_idle_contract(factory, results, tmp, api)
    if os.environ.get('OPEN_E2E_WELCOME_COVER_ONLY') == '1':
        return space_cover_rows(factory, results, tmp, api)
    if os.environ.get('OPEN_E2E_WELCOME_EDGE_ONLY') == '1':
        return edge_fade_rows(factory, results, tmp, api)
    run_restore_contract(factory, results, tmp, api)
    # The Spaces clip shows a Space switch: no empty page frame, no jump (W40).
    space_cover_rows(factory, results, tmp, api)
    edge_fade_rows(factory, results, tmp, api)
    root = Path(api.ROOT)
    evidence = root / '.re/welcome-e2e'
    evidence.mkdir(parents=True, exist_ok=True)
    app = None
    domain = __import__('prefs_domain').domain()
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
        return api.wait_until(lambda: (lambda s: s if predicate(s) else None)(state()), timeout=timeout, step=.05)

    def screenshot(name):
        path = str(evidence / (name + '.png'))
        app.call('snapshot', path=path)
        return path

    def cpu(label):
        before = process_cpu_seconds(app.pid)
        start = time.monotonic()
        time.sleep(5)
        after = process_cpu_seconds(app.pid)
        elapsed = time.monotonic() - start
        return dict(label=label, appPercent=(after-before)/elapsed*100,
                    seconds=elapsed, loadAverage=list(os.getloadavg()))

    def refused(**arguments):
        try:
            app.call('welcome', **arguments)
            return False
        except RuntimeError:
            return True

    try:
        app = factory(urls=('about:blank',), fresh=True)
        blank = app.call('tabs')[0]['id']
        app.call('wait', tab=blank)
        names = browser_thread_names(app.pid)
        record('W00_no_stack_sampling_after_launch', 'StackSamplingProfiler' not in names, threadNames=names)
        api.place_away_from_cursor(app, 1280, 800)
        app.call('window-frame', frame=[60, 60, 1280, 800])
        baseline = state()
        blank_cpu = cpu('blank tab')
        record('W01_no_welcome_no_work', baseline['hostCount'] == 0 and baseline['animationCount'] == 0
               and not baseline['pendingCompletion'] and baseline['decoders'] == 0, state=baseline)
        creation_count = baseline['engineContentCreationCount']
        inserted = app.call('welcome', action='insert')
        welcome = inserted['tab']
        shown = await_state(lambda s: s['visible'])
        appeared = time.monotonic()
        tab = app.call('tab-state', tab=welcome)
        record('W02_insert_native_today', shown and tab['url'] == 'open://welcome'
               and tab['title'] == 'Welcome to Open' and tab['selected'] and tab['section'] == 'today'
               and app.call('tabs')[0]['id'] == welcome and tab['favicon'], tab=tab, state=shown)
        record('W03_never_engine', shown and shown['engineInternalPages'] == 0
               and shown['engineContentCreationCount'] == creation_count and not tab['loaded'] and 'page' not in tab,
               tab=tab, state=shown)
        labels = state()['cards']
        record('W04_AX_steps', len(labels) == 4 and all(c['label'] == title + '. ' + detail
               and c['role'] == 'AXButton' and 'Replay' in c['actions']
               for c, (title, detail) in zip(labels, COPY)), cards=labels)
        record('W05_address_label', state()['urlField'] == 'Welcome to Open', state=state())
        # Reveal: the clip waits for the staged fades, then the playlist starts at step 1.
        early = state()
        playing = await_state(lambda s: s['animating'] and s['clip']['playing'], timeout=REVEAL_CLIP + 3)
        started_at = time.monotonic() - appeared
        record('W06_reveal_then_play', not early['revealed'] and not early['clip']['playing']
               and playing and playing['activeCard'] == 1 and playing['playlist'] == 'playing'
               and playing['decoders'] == 1 and REVEAL_CLIP - .4 <= started_at <= REVEAL_CLIP + 1.2
               and all(playing['clip']['movies']),
               early=early, playing=playing, startedSeconds=started_at, expectedSeconds=REVEAL_CLIP)
        screenshot('welcome-playing')
        second = await_state(lambda s: s['activeCard'] == 2 and s['animating'], timeout=PERIOD + 2)
        record('W07_steps_advance', second and second['playlist'] == 'playing' and second['playedCards'] == [1, 2]
               and second['decoders'] == 1, state=second)
        stopped = await_state(lambda s: s['ended'] and s['playlist'] == 'stopped' and not s['animating'],
                              timeout=PLAYLIST_END + 4)
        record('W08_playlist_ends_with_replay_all', stopped and stopped['playedCards'] == [1, 2, 3, 4]
               and stopped['activeCard'] == 4 and stopped['completionCount'] == 4
               and abs(stopped['playlistElapsed'] - PLAYLIST_END) <= 1.5
               and stopped['clip']['end'] and at_rest(api.wait_until(lambda: (lambda s: s if at_rest(s) else None)(state()), timeout=2, step=.05) or state()),
               state=stopped, expectedSeconds=PLAYLIST_END)
        if not stopped:
            raise AssertionError('Welcome playlist did not finish in order')
        replay_all = await_state(lambda s: s['clip']['replayAllVisible'], timeout=2)
        record('W09_replay_all_visible', replay_all, state=replay_all)
        welcome_cpu = cpu('Welcome ended')
        stable = state()
        record('W10_idle_no_pending_work', at_rest(stable) and (app.config != 'Release' or welcome_cpu['appPercent'] < 1),
               timing=True, functionalOK=at_rest(stable), blank=blank_cpu, welcome=welcome_cpu, state=stable)
        # Hover changes only the step surface; it never plays (reference: no change on hover).
        hover = app.call('welcome', action='hover', card=2)
        time.sleep(1.0)
        after_hover = state()
        app.call('welcome', action='hover', card=2, phase='exit')
        record('W11_hover_does_not_play', after_hover['cards'][1]['hovered'] and not after_hover['animating']
               and after_hover['activeCard'] == 4 and after_hover['playedCards'] == stopped['playedCards']
               and after_hover['cards'][1]['trackingAreas'] == 1, state=after_hover)
        replay = app.call('welcome', action='replay', card=3)
        playing3 = await_state(lambda s: s['animating'] and s['clip']['playing'] and s['activeCard'] == 3, timeout=3)
        record('W12_click_plays_one_clip', replay['activeCard'] == 3 and replay['playlist'] == 'stopped' and playing3
               and not playing3['clip']['end'] and playing3['decoders'] == 1, state=playing3)
        single_end = await_state(lambda s: s['ended'] and not s['animating'], timeout=CLIP + 3)
        record('W13_single_clip_ends', single_end and single_end['activeCard'] == 3 and single_end['playlist'] == 'stopped'
               and single_end['clip']['end'], state=single_end)
        for value in (0, 5):
            record('W14_invalid_card_%d' % value, refused(action='replay', card=value))
        record('W15_refuse_unknown_action', refused(action='unknown'))
        record('W16_refuse_unknown_argument', refused(action='state', unexpected=True))
        app.call('welcome', action='replay-all')
        again = await_state(lambda s: s['playlist'] == 'playing' and s['activeCard'] == 1 and s['animating'], timeout=3)
        record('W17_replay_all_restarts_playlist', again and not again['clip']['end'], state=again)
        # Hidden: pause, release the decoder, keep the place; shown: resume there.
        time.sleep(1.5)
        app.call('select', tab=blank)
        hidden = await_state(lambda s: not s['visible'] and s['animationCount'] == 0 and s['decoders'] == 0
                             and not s['pendingCompletion'], timeout=3)
        record('W18_hidden_tab_pauses_and_releases', hidden and all(not h['animating'] and not h['decoder'] for h in hidden['hosts']),
               state=hidden)
        record('W19_hidden_replay_refused', refused(action='replay', card=1))
        app.call('select', tab=welcome)
        resumed = await_state(lambda s: s['visible'] and s['animating'] and s['clip']['playing'], timeout=3)
        record('W20_shown_resumes_same_step', resumed and resumed['activeCard'] == 1 and resumed['playlist'] == 'playing'
               and resumed['playedCards'][-1] == 1 and resumed['decoders'] == 1, state=resumed)
        app.call('command', id='minimize-window')
        mini = api.wait_until(lambda: app.call('window-state')['miniaturized'], timeout=4, step=.1)
        minimized = await_state(lambda s: not s['visible'] and s['animationCount'] == 0 and s['decoders'] == 0, timeout=3)
        record('W21_minimize_pauses', mini and minimized and not minimized['pendingCompletion'], state=minimized)
        app.call('window-deminiaturize')
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        back = await_state(lambda s: s['visible'] and s['animating'], timeout=4)
        record('W22_deminiaturize_resumes', back and back['activeCard'] == 1, state=back)
        occlusion = occlude_resume_playlist(app, api)
        record('W23_covered_pauses_and_resumes', **occlusion)
        # Real app keyboard route from the native step focus context.
        app.call('key', key='return')
        keyboard_one = state()
        app.call('key', key='tab')
        app.call('key', key='space')
        keyboard_two = state()
        record('W24_step_keyboard', keyboard_one['activeCard'] == 1 and keyboard_two['activeCard'] == 2
               and keyboard_two['focusedCard'] == 2 and keyboard_two['animating'], first=keyboard_one, second=keyboard_two)
        app.call('key', key='l', modifiers=['cmd'])
        bar = app.call('commandbar-state')
        record('W25_commandbar_label', bar.get('presented') and bar.get('text') == 'Welcome to Open', state=bar)
        app.call('key', key='escape')
        app.call('key', key='t', modifiers=['cmd'])
        bar = app.call('commandbar-state')
        record('W26_cmd_t_native_context', bar.get('presented') and bar.get('mode') == 'newTab', state=bar)
        app.call('key', key='escape')
        # Links: Learn Essential Shortcuts opens its window; Help & Resources opens a help tab.
        browser_window = app.call('window-state')['id']
        app.call('welcome', action='link', link='shortcuts')
        shortcut_window = api.wait_until(lambda: next((w for w in app.call('windows')
            if w['visible'] and 'Essential' in w['title']), None), timeout=5, step=.1)
        record('W27_link_shortcuts', shortcut_window, window=shortcut_window)
        if shortcut_window:
            app.call('key', key='w', modifiers=['cmd'], window=shortcut_window['number'])
        app.call('window-focus', id=browser_window, activate=True)
        assert await_state(lambda s: s['visible']), 'Welcome did not return after Shortcuts'
        tabs_before = {t['id'] for t in app.call('tabs')}
        app.call('welcome', action='link', link='help')
        help_tab = api.wait_until(lambda: next((t for t in app.call('tabs') if t['id'] not in tabs_before), None), timeout=5, step=.1)
        record('W28_link_help_opens_tab', help_tab and 'github.com' in (help_tab.get('url') or ''), tab=help_tab)
        if help_tab:
            app.call('close', tab=help_tab['id'])
        app.call('select', tab=welcome)
        await_state(lambda s: s['visible'])
        app.call('key', key='l', modifiers=['cmd'])
        app.call('key', text=destination)
        app.call('key', key='return')
        navigated = api.wait_until(lambda: app.call('tab-state', tab=welcome) if
            app.call('tab-state', tab=welcome)['url'] == destination else None, timeout=10, step=.1)
        app.call('wait', tab=welcome)
        record('W29_same_tab_web_navigation', navigated and navigated['id'] == welcome
               and app.eval(welcome, 'document.title') == 'Welcome navigation'
               and not state()['visible'] and state()['hostCount'] == 0 and state()['decoders'] == 0,
               tab=app.call('tab-state', tab=welcome), state=state())
        app.call('menu-perform', id='open-basics')
        help_state = await_state(lambda s: s['visible'])
        welcome = help_state['tab']
        count = len(app.call('tabs'))
        app.call('menu-perform', id='open-basics')
        record('W30_menu_reuses_current_space', state()['tab'] == welcome and len(app.call('tabs')) == count, state=state())
        app.call('save')
        app.quit(); app = factory(urls=())
        restored = await_state(lambda s: s['visible'])
        record('W31_session_restore', restored and restored['tab'] == welcome and restored['engineInternalPages'] == 0
               and not app.call('tab-state', tab=welcome)['loaded'], state=restored)
        app.call('key', key='w', modifiers=['cmd'])
        archived = api.wait_until(lambda: next((r for r in app.call('archive-list')['rows'] if r['id'] == welcome), None), timeout=8, step=.1)
        record('W32_archive_ordinary_tab', archived and archived['url'] == 'open://welcome', row=archived)
        app.call('command', id='restore-last-closed-tab')
        reopened = await_state(lambda s: s['visible'])
        record('W33_reopen_closed', reopened and reopened['tab'] == welcome and reopened['engineInternalPages'] == 0, state=reopened)
        before = len(app.call('tabs'))
        delivery = subprocess.run(['/usr/bin/open', '-a', app.bundle, 'open://welcome'], capture_output=True, text=True, timeout=15)
        rejection = api.wait_until(lambda: next((r for r in app.call('routing-log')['entries']
            if r['decision']['request']['url'] == 'open://welcome'), None), timeout=5, step=.1)
        record('W34_external_internal_refused', delivery.returncode == 0 and rejection
               and 'rejected (not http/https)' in rejection['summary'] and len(app.call('tabs')) == before,
               decision=rejection, deliveryCode=delivery.returncode)
        # Layout at the reference size, a smaller window, the 640 pt content floor, and a tall window.
        # A reopened page plays its staged reveal again; measure after the last fade.
        await_state(lambda s: s['visible'] and s['revealed'] and s['appearanceElapsed'] > 4.3, timeout=10)
        appearance_before = app.call('space-manager-lifecycle')['appAppearance']
        try:
            for appearance in ('dark', 'light'):
                app.call('appearance', name=appearance)
                for width, height in ((1280, 800), (1000, 700)):
                    app.call('window-frame', frame=[80, 60, width, height])
                    time.sleep(.4)
                    design = state()
                    gates = design_gates(design)
                    capture = screenshot('welcome-%dx%d-%s' % (width, height, appearance))
                    gates['text_contrast'] = text_contrast(capture, design, app.call('window-state'), api)
                    record('W35_design_%dx%d_%s' % (width, height, appearance), all(v is True or (isinstance(v, dict) and v['ok']) for v in gates.values()),
                           gates=gates, layout=design['layout'], screenshot=capture)
            app.call('window-frame', frame=[80, 60, 1280, 1100])
            time.sleep(.4)
            tall = state()
            gates = design_gates(tall)
            record('W36_tall_content', all(gates.values()) and tall['layout']['viewport'][1] > 820, gates=gates, layout=tall['layout'])
        finally:
            original = 'dark' if 'Dark' in appearance_before else 'light' if 'Aqua' in appearance_before else 'system'
            app.call('appearance', name=original)
        # Reduce Motion: no reveal, no autoplay, a poster per step; a click plays that clip.
        app.quit(); app = factory(urls=(), extra_env={'OPEN_E2E_REDUCE_MOTION': '1'})
        reduced = await_state(lambda s: s['visible'] and s['reduceMotion'])
        time.sleep(REVEAL_CLIP + 1)
        reduced = state()
        record('W37_reduce_motion_static', reduced and reduced['playlist'] == 'stopped' and reduced['revealed']
               and not reduced['animating'] and reduced['decoders'] == 0 and reduced['clip']['loaded'] == 1
               and reduced['animationCount'] == 0 and not reduced['pendingCompletion'], state=reduced)
        screenshot('welcome-reduce-motion')
        app.call('welcome', action='replay', card=4)
        reduced_play = await_state(lambda s: s['animating'] and s['clip']['playing'], timeout=3)
        record('W38_reduce_motion_click_plays', reduced_play and reduced_play['activeCard'] == 4
               and reduced_play['playlist'] == 'stopped', state=reduced_play)
    finally:
        try:
            api._restore_defaults(app, saved)
        finally:
            if app: app.quit()
        for source in Path(tmp).glob('open.log*'):
            shutil.copyfile(source, evidence / source.name)
        (evidence / 'welcome-checks.json').write_text(json.dumps(dict(results), indent=2))


def space_cover_rows(factory, results, tmp, api):
    from space_cover_frames import run as cover_run
    cover_run(factory, results, tmp, api, prefix='W40')


def design_gates(state):
    """Acceptance from the real native view frames (reference metrics, docs/re/onboarding.md §6)."""
    layout = state['layout']
    width, height = layout['viewport']
    cards = layout['cards']
    column = layout['column']
    clip = layout['clip']
    heading = layout['heading']
    collapsed = [c for c in cards if not c['active']]
    active = [c for c in cards if c['active']]
    links = [l['frame'] for l in layout['linkPixels']]
    side_by_side = clip[0] >= column[0] + column[2]
    return {
        'column_margin': abs(column[0] - 31) <= .5 and column[2] <= 336.5,
        'heading_above_steps': heading[1] + 2 * heading[3] <= cards[0]['frame'][1] + .5,
        'one_active_step': len(active) == 1,
        'collapsed_steps_72': all(abs(c['frame'][3] - 72) <= .5 for c in collapsed),
        'step_pitch_8': all(abs(b['frame'][1] - (a['frame'][1] + a['frame'][3]) - 8) <= .5 for a, b in zip(cards, cards[1:])),
        'clip_16_10': abs(clip[2] / clip[3] - 1.6) <= .01,
        'clip_beside_or_below': side_by_side or clip[1] >= cards[-1]['frame'][1] + cards[-1]['frame'][3],
        'clip_top_ratio': not side_by_side or abs(clip[1] - round(height * .196)) <= .5,
        'links_top_right': len(links) == 2 and all(l[1] < 80 for l in links)
            and layout['footer'][0] + layout['footer'][2] <= width - 23,
        'document_holds_column': layout['document'][3] >= column[1] + column[3] + 31.5,
        'scroll_at_top': abs(layout['scrollOrigin'][1]) <= .5,
        'static_or_playing_without_relayout': state['animationCount'] < 64,
    }


def text_contrast(path, state, window, api):
    """Heading glyph cores against the page background, on the real window pixels."""
    width, height, pixel = api.read_image(path, srgb=True)
    sx, sy = width / window['frame'][2], height / window['frame'][3]

    def luminance(rgb):
        def linear(c):
            c = c / 255
            return c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4
        return sum(linear(c) * w for c, w in zip(rgb, (.2126, .7152, .0722)))

    out = {}
    for name in ('heading', 'subheading'):
        x, y, w, h = state['layout']['textPixels'][name]['frame']
        colors = [pixel(px, py) for py in range(round(y * sy), round((y + h) * sy))
                  for px in range(round(x * sx), round((x + w) * sx))]
        # Solid heavy glyphs can outnumber any one shade of the gradient wash,
        # so take the background from the light half and the ink from the 12 darkest.
        ordered = sorted(colors, key=luminance)
        background = Counter(ordered[len(ordered) // 2:]).most_common(1)[0][0]
        ink = ordered[:12][6]
        a, b = luminance(ink), luminance(background)
        out[name] = round((max(a, b) + .05) / (min(a, b) + .05), 2)
    return dict(ok=all(v >= 7 for v in out.values()), ratios=out, minimum=7)


def pause_resume_playlist(app, api):
    """Minimize a playing page: pause and release within one second, idle, then resume there."""
    def state(): return app.call('welcome')
    def await_state(predicate, timeout=5):
        return api.wait_until(lambda: (lambda s: s if predicate(s) else None)(state()), timeout=timeout, step=.05)
    initial = await_state(lambda s: s['visible'] and s['playlist'] == 'playing' and s['animating'], timeout=REVEAL_CLIP + 3)
    window = app.call('window-state')['id']
    mini_started = time.monotonic()
    app.call('window-miniaturize')
    mini = api.wait_until(lambda: app.call('window-state')['miniaturized'], timeout=2, step=.05)
    paused = await_state(lambda s: not s['visible'] and at_rest(s), timeout=2)
    pause_seconds = time.monotonic()-mini_started
    before = process_cpu_seconds(app.pid); start = time.monotonic(); time.sleep(5)
    cpu_delta = process_cpu_seconds(app.pid)-before; seconds = time.monotonic()-start
    cpu = cpu_delta/seconds*100; after = state()
    app.call('window-deminiaturize'); app.call('window-focus', id=window, activate=True)
    resumed = await_state(lambda s: s['visible'] and s['animating'] and s['decoders'] == 1)
    functional = bool(initial and mini and paused and pause_seconds <= 2 and at_rest(after) and resumed
                      and resumed['activeCard'] == initial['activeCard'] and resumed['playlist'] == 'playing')
    return dict(ok=functional and (app.config != 'Release' or cpu < 1), initial=initial, paused=paused, resumed=resumed,
                pauseSeconds=pause_seconds, timing=True, functionalOK=functional,
                appCPUPercent=cpu, seconds=seconds, limitPercent=1, cpuLoadAverage=list(os.getloadavg()))


def occlude_resume_playlist(app, api):
    """Cover the native page with another owned Open window, without moving input."""
    base = app.call('window-state')
    window = base['id']
    def state(): return app.call('welcome', window=window)
    def await_state(predicate, timeout=5):
        return api.wait_until(lambda: (lambda s: s if predicate(s) else None)(state()), timeout=timeout, step=.1)
    initial = await_state(lambda s: s['visible'] and s['animating'])
    cover = covered = observed = paused = None
    covered_state = None
    try:
        app.call('command', id='new-window')
        cover = api.wait_until(lambda: (lambda s: s if s['id'] != window else None)(
            app.call('window-state')), timeout=5, step=.1)
        if not cover:
            raise AssertionError('covering Open window did not open')
        app.call('space-create', title='Welcome occlusion cover')
        app.call('open', url='about:blank')
        x, y, width, height = base['frame']
        app.call('window-frame', frame=[x-32, y-32, width+64, height+64], unconstrained=True)
        covered = app.call('window-state')
        observed = await_state(lambda s: s['windowState']['occluded'])
        if observed:
            paused = await_state(lambda s: s['windowState']['occluded'] and not s['visible'] and not s['animating']
                and not s['pendingCompletion'] and s['animationCount'] == 0 and s['decoders'] == 0)
        covered_state = state()
    finally:
        if cover:
            app.call('window-focus', id=cover['id'], activate=True)
            app.call('window-close')
        app.call('window-focus', id=window, activate=True)
    resumed = await_state(lambda s: s['visible'] and (s['animating'] or s['ended']))
    cx, cy, cw, ch = covered['frame']
    bx, by, bw, bh = base['frame']
    full_cover = cx <= bx and cy <= by and cx+cw >= bx+bw and cy+ch >= by+bh
    ok = bool(initial and full_cover and resumed and (not observed or paused))
    return dict(ok=ok, status='observed' if observed else 'INFO',
                reason=None if observed else 'Open cover did not change NSWindow.occlusionState on this setup',
                initial=initial, baseWindow=base, coverWindow=covered, fullyCovered=full_cover,
                coveredState=covered_state, occlusionObserved=bool(observed), paused=paused, resumed=resumed)


def run_restore_contract(factory, results, tmp, api):
    """Quit preflight may visit a background page; it must keep Welcome selected."""
    app = None
    try:
        for handler in (False, True):
            app = factory(urls=('about:blank',), fresh=True)
            background = app.call('tabs')[0]['id']
            app.call('wait', tab=background)
            if handler:
                # A real renderer reports this handler to the engine. It does
                # not ask for a dialog or need sticky user activation.
                app.eval(background, 'onbeforeunload=()=>{};true')
                assert api.wait_until(lambda: app.call('engine-sleep', tab=background)['unloadHandlers'],
                                      timeout=3, step=.025)
            welcome = app.call('welcome', action='insert')['tab']
            assert api.wait_until(lambda: app.call('welcome')['visible'], timeout=5, step=.025)
            path = Path(app.call('save'))
            def selection():
                return [w['selectedNodeBySpace'] for w in json.loads(path.read_text())['windows']]
            before = selection()
            app.quit()
            after = selection()
            app = factory(urls=())
            restored = api.wait_until(lambda: (lambda s: s if s['visible'] and s['tab'] == welcome else None)(
                app.call('welcome')), timeout=5, step=.025)
            results['W38_quit_restore_' + ('background_handler' if handler else 'no_handler')] = dict(
                ok=before == after and bool(restored), beforeQuit=before, afterQuit=after,
                expectedTab=welcome, state=restored or app.call('welcome'))
            app.quit()
    finally:
        if app and not app.closed:
            app.quit()


def edge_fade_rows(factory, results, tmp, api):
    """W-EDGE: where the clip deliberately runs past the page (wide window), the last strip of the visible
    clip fades into the page backdrop: at the strip's right end the real-window pixels match the backdrop
    just above and below the clip (same column). A narrow window stacks the clip and hides the strip."""
    app = factory(urls=('about:blank',), fresh=True)
    try:
        app.call('wait', tab=app.call('tabs')[0]['id'])
        app.call('appearance', name='light')
        app.call('window-frame', frame=[80, 80, 1680, 1050]); app.call('updater-banner-width', width=180)
        inserted = app.call('welcome', action='insert'); time.sleep(2.5)
        layout = app.call('welcome')['layout']; fade, clip = layout.get('edgeFade') or {}, layout.get('clipWindowFrame') or []
        path = str(Path(tmp) / 'welcome-edge-fade.png'); app.call('snapshot', path=path)
        width, height, pixel = api.read_image(path, srgb=True); scale = width / 1680
        def diff(a, b): return sum(abs(i - j) for i, j in zip(a, b))
        samples = []
        if not fade.get('hidden', True) and len(clip) == 4:
            fx, fy, fw, fh = fade['window']; cx, cy, cw, ch = clip
            x = (fx + fw - 2) * scale
            for inside, outside in ((cy + 30, cy - 20), (cy + ch - 30, cy + ch + 20)):
                a, b = pixel(x, inside * scale), pixel(x, outside * scale)
                samples.append(dict(clip=list(a), backdrop=list(b), diff=diff(a, b)))
        # 900 pt with a 360 pt sidebar leaves the page under clipX + 260 pt: the clip stacks below the steps.
        app.call('window-frame', frame=[80, 80, 900, 620]); app.call('updater-banner-width', width=360); time.sleep(1.0)
        narrow_layout = app.call('welcome')['layout'] or {}
        narrow = dict(narrow_layout.get('edgeFade') or {}, clip=narrow_layout.get('clip'), clipShown=narrow_layout.get('clipShown'))
        results['W_edge_fade'] = dict(ok=not fade.get('hidden', True) and len(samples) == 2
            and all(s['diff'] <= 36 for s in samples) and narrow.get('hidden') is True,
            wide=fade, samples=samples, narrow=narrow, png=path, load=list(os.getloadavg()))
        app.call('close', tab=inserted['tab'])
    finally:
        app.quit()
