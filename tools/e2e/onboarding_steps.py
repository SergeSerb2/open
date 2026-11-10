"""Setup gates through the real App, shared importer, native window and saved root."""
import json
import hashlib
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import time
import uuid


def run(factory, results, tmp, h):
    if os.environ.get('OPEN_E2E_ONBOARDING_ICONS_ONLY') == '1':
        return run_favorite_icons(factory, results, tmp, h)
    run_favorite_icons(factory, results, tmp, h)
    source = Path(tmp)/'setup-arc-synthetic'
    shutil.rmtree(source, ignore_errors=True)
    ids = runpy.run_path(str(Path(h.ROOT)/'tools/e2e/firstrun.py'))['fixture'](source)
    windows_path = source/'StorableWindows.json'
    windows = json.loads(windows_path.read_text())
    windows['windows'].append(dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL,'https://example.com/setup/window-two')).upper(),
        focusedSpaceID=ids['beta'], expandedItems=[]))
    windows_path.write_text(json.dumps(windows))
    empty = Path(tmp)/'setup-no-arc'; empty.mkdir(exist_ok=True)
    evidence = Path(h.ROOT)/'.re/handoff/sections/s17/c3'; evidence.mkdir(parents=True, exist_ok=True)
    exported = h.subprocess.run(['defaults','export','io.github.sergeserb2.open','-'], capture_output=True)
    domain = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    keys = ('open.onboarding.name', 'open.firstRun.completed', 'open.import.lastArcDir', 'open.settings.lastPane',
            'open.links.externalInLittleOpen')
    saved = {key: domain.get(key) for key in keys}
    app = None
    external_server = None
    last_intro = None
    negatives = {}
    ax_steps = {}
    def state(): return app.call('onboarding', action='state')
    def until(predicate, timeout=20):
        assert h.wait_until(predicate, timeout=timeout, step=.025), state()
    def screen(name): until(lambda: state()['screen']==name); return state()
    def launch(directory=source, fresh=True, flags=(), **env):
        nonlocal app, last_intro
        if app and not app.closed: app.quit()
        if fresh: h._restore_defaults(None, {keys[0]: None, keys[1]: None})
        app = factory(urls=(), fresh=fresh, extra_args=['--arc-dir='+str(directory), '--intro-sound=off', *flags], extra_env=env)
        # Answer the native quit confirmation on this suite's unsaved close path.
        app.call('quit-warning', button='quit')
        last_intro = state()
        if state().get('active') and state()['screen']=='intro':
            app.call('onboarding', action='skip-intro'); app.call('onboarding', action='get-started'); screen('name')
        return state()
    def action(verb, **args): app.call('onboarding', action=verb, **args)
    def shot(name):
        if name.endswith('-light'): action('set-appearance', appearance='light')
        time.sleep(.4)
        ax_steps[state()['screen']] = state()['controls']
        app.call('snapshot', path=str(evidence/(name+'.png')))
        if name.endswith('-light'):
            action('set-appearance', appearance='dark'); time.sleep(.2)
            app.call('snapshot', path=str(evidence/(name[:-6]+'-dark.png')))
            action('set-appearance', appearance='light')
    def gate(name, predicate, good, bad):
        results['steps_'+name] = dict(ok=bool(predicate(good)), load=os.getloadavg(), observed=good)
        rejected = not bool(predicate(bad))
        results['steps_'+name+'_negative'] = dict(ok=rejected, expected='FAIL', load=os.getloadavg())
        negatives[name] = dict(ok=rejected, observed=bad)
    def skip_to_ready():
        for _ in range(9):
            s = state()['screen']
            if s == 'ready': return state()
            action('skip' if s in ('name','import','favorites','theme','blocker') else 'next')
            if s == 'defaultBrowser':
                until(lambda: state()['screen']=='ready' or not state()['defaultPending'])
        raise AssertionError(state())
    def snapshot(): return Path(app.user_data)/'State/browser.json'
    def export_card(path):
        path.unlink(missing_ok=True)
        action('save-card'); until(lambda: state()['savePanel'])
        action('card-save', path=str(path))
        until(lambda: path.is_file() and not state()['savePanel'])
    def card_ink(path, s):
        _, _, pixel = h.read_image(str(path), srgb=True)
        observed = dict(luminance=s['card']['luminance'], darkText=s['card']['darkText'])
        # These are the name/date areas of the real 1200 x 750 export. Compare
        # each row with clear background left of the text, beyond grain/pattern
        # variation. Opposite-color exports provide the negative proofs below.
        for label, top, bottom in [('name',525,625), ('date',625,658)]:
            deltas = [h.luma(pixel(x,y))-h.luma(pixel(48,y))
                for y in range(top,bottom) for x in range(76,490)]
            observed[label+'DarkPixels'] = sum(delta < -45 for delta in deltas)
            observed[label+'LightPixels'] = sum(delta > 45 for delta in deltas)
        return observed
    try:
        h._restore_defaults(None, {key: None for key in keys})
        initial = launch()
        normal_intro = last_intro
        shot('name-light')
        action('set-name', name='N'*40)
        at_limit = state()
        refused = False
        try: action('set-name', name='N'*41)
        except RuntimeError: refused = True
        results['steps_name_limit'] = dict(ok=at_limit['name']=='N'*40 and refused, load=os.getloadavg())
        pending_blocker = Path(app.user_data,'adblock-settings.json')
        blocker_before = pending_blocker.read_bytes() if pending_blocker.exists() else None
        action('set-name', name='  Example  ')
        app.call('key', key='return'); imported = screen('import'); shot('import-light')
        gate('same_window', lambda s: s['screen']=='import' and s['window']==initial['window'] and s['dim']['exists'], imported, initial)
        action('skip'); favorites = screen('favorites'); shot('favorites-empty-light')
        action('toggle-favorite', index=11); last_site = state(); action('toggle-favorite', index=11)
        refused = False
        try: action('toggle-favorite', index=12)
        except RuntimeError: refused = True
        results['steps_favorite_limits'] = dict(ok=last_site['favorites']==[11] and refused and state()['favorites']==[], load=os.getloadavg())
        app.call('key', key='space'); spaced = state()
        gate('keyboard_space', lambda s: s.get('favorites')==[0], spaced, favorites)
        app.call('key', key='tab'); tabbed = state()
        app.call('key', key='tab', modifiers=['shift']); backwards = state()
        gate('keyboard_tab_order', lambda s: s.get('focus')=='Google Maps', tabbed, backwards)
        action('toggle-favorite', index=6)
        selected = state(); shot('favorites-selected-light')
        gate('favorite_selection', lambda s: s.get('favorites')==[0,6], selected, favorites)
        app.call('key', key='return'); theme = screen('theme')
        action('set-theme', preset=44); last_preset = state()
        refused = []
        for index in (-1,45):
            try: action('set-theme', preset=index); refused.append(False)
            except RuntimeError: refused.append(True)
        results['steps_theme_limits'] = dict(ok=last_preset['theme']!=theme['theme'] and all(refused), load=os.getloadavg())
        action('set-theme', preset=5); themed = state(); shot('theme-light')
        gate('theme_choice', lambda s: s['theme']!=theme['theme'], themed, theme)
        app.call('key', key='return'); screen('blocker'); action('set-blocker', on=False); off = state(); shot('blocker-off-light')
        gate('blocker_choice', lambda s: s.get('blocker') is False, off, initial)
        app.call('key', key='return'); default = screen('defaultBrowser'); shot('default-browser-light')
        gate('no_default_prompt_before_click', lambda s: s['screen']=='defaultBrowser' and not s['defaultAttempted'], default, off)
        action('choose-default', yes=False); app.call('key', key='return'); ready = screen('ready'); shot('ready-light')
        gate('name_greeting', lambda s: s.get('title')=='Welcome to Open, Example.', ready, initial)
        gate('confetti', lambda s: s.get('confettiPlayed') is True and s.get('confettiBehindCard') is True
            and abs(s.get('confettiLifetime',0)-0.6)<0.000001, ready, initial)
        def card_buttons(s):
            card = s.get('card',{}); buttons = card.get('buttons',[])
            if len(buttons)!=2: return False
            left,right = (b['frame'] for b in buttons); frame = card['frame']
            return all(b['circle'] and b['label'] for b in buttons) and left[2:]==right[2:]==[32,32] \
                and abs(right[0]-left[0]-44)<0.01 and abs(left[1]-frame[1]-frame[3]-16)<0.01 \
                and abs((left[0]+right[0]+32)/2-frame[0]-frame[2]/2)<0.01
        gate('card_buttons', card_buttons, ready, initial)
        action('shuffle-card'); shuffled = state(); shot('ready-shuffled-light')
        gate('shuffle', lambda s: s.get('cardPattern')==1, shuffled, ready)
        # Real NSSavePanel service response reaches its production completion.
        action('save-card'); until(lambda: state()['savePanel'])
        action('card-cancel'); until(lambda: not state()['savePanel'])
        card_path = evidence/'open-card.png'
        export_card(card_path)
        yellow_ink = card_ink(card_path, state())
        width, height, pixel = h.read_image(str(card_path))
        screenshot_width, screenshot_height, _ = h.read_image(str(evidence/'ready-light.png'))
        gate('card_png', lambda s: s['size']==[1200,750] and s['nonflat'],
            dict(size=[width,height],nonflat=pixel(600,375)!=pixel(1,1)),
            dict(size=[screenshot_width,screenshot_height],nonflat=True))
        # No model, name or global blocker write before Get Started.
        pending = dict(snapshot=snapshot().exists(), name=app.call('defaults', key=keys[0], persistent=True))
        blocker_after = pending_blocker.read_bytes() if pending_blocker.exists() else None
        results['steps_pending_no_writes'] = dict(ok=not pending['snapshot'] and pending['name'] is None
            and blocker_before==blocker_after, state=pending, load=os.getloadavg())
        app.call('key', key='return')
        handoff = state(); until(lambda: not state()['active'] and not state()['dim']['exists'])
        final = state(); stored = json.loads(snapshot().read_text())
        tabs = app.call('tabs'); selected_tabs = [t for t in tabs if t.get('selected')]
        welcome = app.call('welcome')
        normal_surfaces = dict(intro=normal_intro, setup=ready, welcome=welcome)
        native_welcome = lambda s: s.get('visible') and s.get('engineInternalPages')==0 and s.get('urlField')=='Welcome to Open'
        gate('welcome_native_selected', native_welcome, welcome, {})
        welcome_id = welcome['tab']
        results['steps_welcome_first_today'] = dict(ok=bool(selected_tabs) and selected_tabs[0]['id']==welcome_id
            and app.call('tab-state', tab=welcome_id)['section']=='today'
            and [t for t in tabs if t['section']=='today'][0]['id']==welcome_id, load=os.getloadavg())
        adblock = json.loads(Path(app.user_data,'adblock-settings.json').read_text())
        saved_name = app.call('defaults', key=keys[0], persistent=True)
        focused = next(s for s in stored['spaces'] if s['id']==stored['windows'][0]['focusedSpaceID'])
        data = dict(name=saved_name, blocker=adblock.get('nativeAdBlockEnabled'),
            favorites=[t['url'] for t in tabs if t['section']=='favorites'], style=focused['theme'].get('style'))
        gate('final_data', lambda s: s.get('name')=='Example' and s.get('blocker') is False
            and s.get('favorites')==['https://mail.google.com/','https://github.com/']
            and s.get('style',{}).get('colorCount')==1 and bool(s.get('style',{}).get('keyColor')), data, pending)
        gate('handoff_done', lambda s: not s['active'] and not s['dim']['exists'] and s['screen']=='done', final, handoff)
        results['steps_browser_key'] = dict(ok=any(w.get('key') for w in app.call('windows') if w.get('class')=='BrowserWindow'), load=os.getloadavg())
        # Cover this whole wait with the existing foreground guard. Welcome
        # resumes its current card after occlusion; an interrupted playlist
        # cannot prove the uninterrupted [1,2,3,4] sequence below.
        app.begin_timing('Welcome playlist after first-run handoff')
        until(lambda: app.call('welcome')['playlist']=='stopped' and not app.call('welcome')['animating'], timeout=38)
        stopped = app.call('welcome')
        gate('welcome_playlist_ends', lambda s: s.get('playedCards')==[1,2,3,4] and not s.get('animating')
            and s.get('animationCount')==0 and not s.get('pendingCompletion'), stopped, welcome)
        app.call('welcome', action='replay', card=2)
        active = app.call('welcome')
        app.call('key', key='t', modifiers=['command']); app.call('key', key='escape')
        # A new ordinary tab hides Welcome and must cancel its pending work.
        app.call('open', url='about:blank')
        hidden = app.call('welcome')
        gate('welcome_hidden_stops', lambda s: not s.get('visible') and s.get('animationCount')==0
            and not any(x['animating'] for x in s.get('hosts',[])), hidden, active)
        app.call('select', tab=welcome_id); app.call('save')
        returning = launch(fresh=False)
        gate('returning', lambda s: not s['active'] and not s['moduleActive'], returning, initial)
        restored = app.call('welcome')
        gate('welcome_restores', lambda s: native_welcome(s) and s['tab']==welcome_id, restored, hidden)
        app.call('command', id='archive-tab')
        app.call('menu-perform', id='open-basics')
        reopened = app.call('welcome')
        gate('open_basics_menu', native_welcome, reopened, hidden)
        # Import branch uses Section 7's real plan, runner, report and model swap.
        launch(); action('next'); screen('import')
        app.call('first-run', action='continue')
        until(lambda: app.call('first-run')['step']=='report')
        report = app.call('first-run'); shot('import-report-light')
        app.call('window-reopen')
        prepared = [w for w in app.call('windows') if w['class']=='BrowserWindow']
        hidden_browser = lambda windows: bool(windows) and all((not w['visible'] or w['alpha']==0)
            and not w['key'] and not w['main'] for w in windows)
        action('next'); after_import = screen('theme')
        gate('import_skips_favorites', lambda s: s.get('screen')=='theme', after_import, favorites)
        results['steps_import_report'] = dict(ok=report['outcome'].get('Favorites')==1 and report['outcome'].get('Imported tabs')==7 and not report['completed'], load=os.getloadavg(), outcome=report['outcome'])
        skip_to_ready(); action('get-started')
        until(lambda: not state()['active'] and not state()['dim']['exists'])
        revealed = [w for w in app.call('windows') if w['class']=='BrowserWindow']
        gate('import_browser_hidden', hidden_browser, prepared, revealed)
        gate('import_browser_revealed', lambda ws: bool(ws) and any(w['visible'] and w['alpha']==1 and w['key'] for w in ws), revealed, prepared)
        imported_welcome = app.call('welcome')
        selected_welcome = app.call('tab-state', tab=imported_welcome['tab'])
        results['steps_import_focused_space'] = dict(ok=len(prepared)==2 and native_welcome(imported_welcome)
            and selected_welcome['space']==next(s['id'] for s in app.call('spaces') if s['focused']), load=os.getloadavg())
        # Empty source skips Import. Escape returns to the actual preceding step.
        launch(directory=empty); action('next'); no_data = screen('favorites')
        gate('no_arc_skips_import', lambda s: s['screen']=='favorites', no_data, imported)
        app.call('key', key='escape'); escaped = screen('name')
        gate('escape_back', lambda s: s['screen']=='name', escaped, no_data)
        action('skip'); screen('favorites'); action('skip'); screen('theme'); action('skip'); screen('blocker'); action('skip'); screen('defaultBrowser')
        action('choose-default', yes=False); action('next'); blank = screen('ready')
        results['steps_every_skip'] = dict(ok=blank['name']=='' and blank['favorites']==[] and blank['blocker'] is False and blank['title']=='Welcome to Open.', state=blank, load=os.getloadavg())
        blue_path = evidence/'open-card-blue.png'
        export_card(blue_path)
        blue_ink = card_ink(blue_path, state())
        gate('card_yellow_ink', lambda s: s['darkText'] and s['luminance']>0.55
            and s['nameDarkPixels']>200 and s['dateDarkPixels']>30
            and s['nameLightPixels']<20 and s['dateLightPixels']<20, yellow_ink, blue_ink)
        gate('card_blue_ink', lambda s: not s['darkText'] and s['luminance']<=0.55
            and s['nameLightPixels']>200 and s['dateLightPixels']>30
            and s['nameDarkPixels']<20 and s['dateDarkPixels']<20, blue_ink, yellow_ink)
        # A real write failure keeps Ready open and D3 unset; retry reuses choices.
        for _ in range(4): action('back')
        screen('favorites'); action('toggle-favorite', index=1); action('toggle-favorite', index=6)
        for _ in range(3): action('next')
        screen('defaultBrowser'); action('choose-default', yes=False); action('next'); screen('ready')
        snapshot().mkdir(); action('get-started'); failure = state()
        gate('save_error', lambda s: s['active'] and s['screen']=='ready' and 'could not save' in s['error'], failure, blank)
        assert app.call('first-run')['completed'] is False
        snapshot().rmdir(); action('get-started'); until(lambda: not state()['active']); assert app.call('first-run')['completed']
        retried_tabs = app.call('tabs')
        results['steps_save_retry_no_duplicates'] = dict(ok=len([t for t in retried_tabs if t['section']=='favorites'])==2
            and len([t for t in retried_tabs if t['url']=='open://welcome'])==1, load=os.getloadavg())
        gate('maps_favorite', lambda ts: any(t['section']=='favorites' and t['title']=='Google Maps'
            and t['url']=='https://maps.google.com/' for t in ts), retried_tabs, tabs)
        # Already default is a read-only automation outcome. No system prompt runs.
        launch(directory=empty, OPEN_AUTOMATION_DEFAULT_BROWSER='already'); skip_to_ready()
        already = state(); action('back'); offered = screen('defaultBrowser'); shot('already-default-light')
        gate('already_default', lambda s: s.get('alreadyDefault') is True and not s['defaultAttempted'], offered, default)
        # Decline and failure both show their outcome before continuing.
        for outcome in ('declined','failed','success'):
            launch(directory=empty, **{'OPEN_AUTOMATION_DEFAULT_BROWSER': outcome, 'OPEN_AUTOMATION_DEFAULT_BROWSER_DELAY_MS': '500'}); action('skip'); action('skip'); action('skip'); action('skip'); screen('defaultBrowser')
            action('next'); waiting = state()
            until(lambda: bool(state()['defaultOutcome']))
            during = state()
            gate('default_waits_'+outcome, lambda s: s['screen']=='defaultBrowser' and s['defaultPending']
                and s['defaultAttempted'] and not s['defaultOutcome'], waiting, during)
            until(lambda: state()['screen']=='ready')
            gate('default_'+outcome, lambda s: s['defaultPending'] and s['defaultAttempted'] and bool(s['defaultOutcome']), during, default)
        # Reduced motion has no offset or emitter, including after back/forward.
        launch(directory=empty, flags=['--reduce-motion']); reduced = skip_to_ready(); shot('ready-reduce-motion-light')
        gate('reduced', lambda s: s['reduceMotion'] and s['offset']==0 and not s['confettiPlayed'] and not s['confettiActive'], reduced, ready)
        # Replay exercises all setup choices over the saved browser. None may
        # reach the importer, model, preferences, blocker or default service.
        action('get-started'); until(lambda: not state()['active'] and not state()['dim']['exists'])
        reduced_welcome = app.call('welcome')
        gate('reduce_motion_all_surfaces', lambda s: s['intro'].get('reduceMotion') is True
            and all('crossfade' in key for key in s['intro'].get('animations',[]))
            and s['setup']['reduceMotion'] and s['setup']['offset']==0
            and not s['setup']['confettiPlayed'] and not s['setup']['confettiActive']
            and s['welcome']['visible'] and s['welcome']['reduceMotion']
            and not s['welcome']['animating'] and s['welcome']['animationCount']==0
            and not s['welcome']['pendingCompletion'],
            dict(intro=last_intro, setup=reduced, welcome=reduced_welcome), normal_surfaces)
        def persisted():
            return dict(snapshot=hashlib.sha256(snapshot().read_bytes()).hexdigest(),
                blocker=hashlib.sha256(Path(app.user_data,'adblock-settings.json').read_bytes()).hexdigest(),
                name=app.call('defaults', key=keys[0], persistent=True),
                completed=app.call('defaults', key=keys[1], persistent=True))
        # Flush the ordinary hand-off window-state save before the replay starts.
        # Replay still has to preserve the complete saved bytes, not a subset.
        app.call('save')
        baseline = persisted()
        replay_before = snapshot().read_bytes()
        action('replay-intro')
        until(lambda: state().get('active'))
        action('skip-intro'); action('get-started'); screen('name')
        action('set-name', name='Replay only'); action('next'); screen('favorites')
        action('toggle-favorite', index=1); action('next'); screen('theme')
        action('set-theme', preset=9); action('next'); screen('blocker')
        action('set-blocker', on=True); action('next'); screen('defaultBrowser')
        action('choose-default', yes=True); action('next'); screen('ready')
        replay_ready = state(); action('shuffle-card'); action('get-started')
        until(lambda: not state()['active'] and not state()['dim']['exists'])
        replay_saved = persisted()
        if replay_saved['snapshot'] != baseline['snapshot']:
            (evidence/'replay-before.json').write_bytes(replay_before)
            (evidence/'replay-after.json').write_bytes(snapshot().read_bytes())
        replay_saved['defaultAttempted'] = replay_ready['defaultAttempted']
        gate('replay_read_only', lambda s: all(s.get(key)==value for key,value in baseline.items())
            and s.get('defaultAttempted') is False, replay_saved, pending)
        # Real macOS URL delivery queues until the final save; it must not
        # create a browser (or bypass setup through Little Open) beforehand.
        external_server, external_origin = h._fixture_server('Onboarding external link')
        launch(directory=empty)
        app.call('defaults', key='open.links.externalInLittleOpen', value=False)
        external_url = external_origin+'/queued-during-setup'
        delivered = h.subprocess.run(['/usr/bin/open', '-a', app.bundle, external_url],
            capture_output=True, text=True, timeout=15)
        until(lambda: app.call('routing-log')['pendingCount']==1)
        queued_external = dict(delivery=delivered.returncode, setup=state(),
            routing=app.call('routing-log'), windows=app.call('windows'))
        skip_to_ready()
        before_finish = app.call('shell-windows')
        handoff_start = app.call('onboarding', action='get-started')
        handoff_windows = app.call('shell-windows')
        # The onboarding controller still exists during its 2.5-second dim
        # fade. Only pre-save windows may inherit setup's hidden/key guard.
        app.call('command', id='new-window')
        new_windows = [w for w in app.call('shell-windows')
            if w['id'] not in {old['id'] for old in handoff_windows}]
        created = app.call('window-state')
        native_created = next((w for w in app.call('windows') if w['number']==created['number']), {})
        during_fade = state()
        new_window_observed = dict(start=handoff_start, setup=during_fade,
            created=created, native=native_created, windows=new_windows)
        gate('new_window_during_handoff', lambda s: s.get('start',{}).get('screen')=='handoff'
            and s['start']['dim']['exists'] and s['start']['dim']['alpha']>0
            and s.get('setup',{}).get('screen')=='handoff' and s['setup']['dim']['exists']
            and len(s.get('windows',[]))==1
            and s.get('created',{}).get('id')==s['windows'][0]['id']
            and s['created']['canBecomeKey'] is True
            and s['created']['isKeyWindow'] and s.get('native',{}).get('visible') is True
            and s['native']['alpha']==1,
            new_window_observed, dict(setup=queued_external['setup'], windows=before_finish))
        until(lambda: not state()['active'] and not state()['dim']['exists'])
        until(lambda: app.call('routing-log')['pendingCount']==0
            and any(t['url']==external_url for t in app.call('tabs')))
        drained_external = dict(delivery=delivered.returncode, setup=state(),
            routing=app.call('routing-log'), windows=app.call('windows'))
        gate('external_url_queued_during_setup', lambda s: s.get('delivery')==0
            and s.get('setup',{}).get('screen')=='name' and s['setup']['active']
            and not s.get('routing',{}).get('ready') and s['routing']['pendingCount']==1
            and s['routing']['queuedCount']==1 and s['routing']['drainedCount']==0
            and not any(w['class'] in ('BrowserWindow','LittleOpenNativeWindow') for w in s.get('windows',[])),
            queued_external, drained_external)
        # Native Cmd+W reaches the window delegate and quits without completion.
        launch(directory=empty, OPEN_AUTOMATION_PROBE_DELAY_MS='5000')
        root = snapshot(); pid = app.pid
        app.call('key', key='w', modifiers=['command'])
        quit_ok = h.wait_until(lambda: not app.process_path(pid), timeout=20, step=.05)
        app.quit()
        results['steps_close_quits_unsaved'] = dict(ok=quit_ok and not root.exists() and app.quit_report.get('ok'), load=os.getloadavg())
        launch(directory=empty, flags=['--reduce-motion']); skip_to_ready()
        # Wrong-stage and boundary requests must be rejected by the real server.
        rejected = []
        for args in [dict(action='set-name',name='x'), dict(action='toggle-favorite',index=12), dict(action='set-theme',preset=-1), dict(action='next'), dict(action='skip'), dict(action='state', extra=True)]:
            try: app.call('onboarding', **args); rejected.append(False)
            except RuntimeError: rejected.append(True)
        results['steps_invalid_actions'] = dict(ok=all(rejected), rejected=rejected, load=os.getloadavg())
        # Every native step's controls have a role and a label. The shared SwiftUI
        # host retains its existing AX labels; native controls are dumped here.
        controls = [c for step_controls in ax_steps.values() for c in step_controls]
        results['steps_accessibility_labels'] = dict(ok=len(ax_steps)==7 and all(c['label'] and c['role']!='AXUnknown' for c in controls) and any(c['label']=='Get Started' for c in controls), controls=ax_steps, load=os.getloadavg())
        (evidence/'negative-proofs.json').write_text(json.dumps(negatives, indent=2))
    finally:
        if app and not app.closed: app.quit()
        if external_server:
            external_server.shutdown(); external_server.server_close()
        h._restore_defaults(None, saved)


def run_favorite_icons(factory, results, tmp, h):
    """Live direct-site downloads -> onboarding -> persisted sidebar Favorites.

    Both network states use the real App and window. No icon bytes are bundled
    or supplied by the harness. Capture only the App's owned window.
    """
    import sqlite3
    evidence = Path(os.environ.get('OPEN_E2E_C7_EVIDENCE', str(Path(h.ROOT)/'.re/handoff/sections/s17/c7')))
    evidence.mkdir(parents=True, exist_ok=True)
    source = Path(tmp)/'favorite-icons-no-arc'; source.mkdir(exist_ok=True)
    keys = ('open.firstRun.completed', 'open.onboarding.name', 'open.import.lastArcDir',
            'open.onboarding.introSoundEnabled')
    exported = h.subprocess.run(['defaults', 'export', 'io.github.sergeserb2.open', '-'], capture_output=True)
    domain = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    saved = {key: domain.get(key) for key in keys}
    app = None
    receipts = {}
    def state(): return app.call('onboarding', action='state')
    def until(predicate, timeout=20):
        assert h.wait_until(predicate, timeout=timeout, step=.025), state()
    def action(verb, **args): return app.call('onboarding', action=verb, **args)
    def launch(blocked=False, reduced=False, curated_failure=False):
        nonlocal app
        if app and not app.closed: app.quit()
        h._restore_defaults(None, {key: None for key in keys})
        flags = ['--arc-dir='+str(source), '--intro-sound=off']
        if blocked: flags.append('--favicon-network=blocked')
        if reduced: flags.append('--reduce-motion')
        if curated_failure: flags.append('--favicon-curated=fail')
        app = factory(urls=(), fresh=True, extra_args=flags, extra_env={'OPEN_FAVICON_DIAGNOSTICS':'1'})
        first = state()
        database = Path(app.user_data)/'State/favicons.sqlite3'
        existing_rows = 0
        if database.exists():
            with sqlite3.connect('file:'+str(database)+'?mode=ro', uri=True) as db:
                if db.execute("SELECT 1 FROM sqlite_master WHERE name='favicons'").fetchone():
                    existing_rows = db.execute('SELECT count(*) FROM favicons').fetchone()[0]
        proof = dict(factoryFresh=True, pid=app.pid, initialScreen=first['screen'],
            firstRunCompleted=app.call('first-run')['completed'], faviconRowsBeforePrefetch=existing_rows,
            introElapsed=first['elapsed'], prefetchNotScheduledBefore=3.3,
            prefetchStarted=first.get('faviconFetch',{}).get('started'),
            snapshotExists=(Path(app.user_data)/'State/browser.json').exists())
        action('skip-intro'); action('get-started')
        until(lambda: state()['screen']=='name')
        name = state(); name['firstLaunchProof'] = proof
        action('skip'); until(lambda: state()['screen']=='favorites')
        initial = state(); initial['firstLaunchProof'] = proof
        return name, initial
    def capture(label):
        captures = {}
        for appearance in ('light', 'dark'):
            action('set-appearance', appearance=appearance)
            time.sleep(.3)
            s = state(); path = evidence/('favorites-'+label+'-'+appearance+'.png')
            # Window ID belongs to this owned App. -x suppresses capture sound.
            captured = h.subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-a', '-l', str(s['window']), str(path)], capture_output=True)
            assert captured.returncode == 0, captured.stderr.decode(errors='replace')
            width, height, pixel = h.read_image(str(path), srgb=True)
            scale = s['backingScale']; frames = s['frameSize']
            assert [width,height] == [round(frames[0]*scale), round(frames[1]*scale)], (width,height,frames,scale)
            tiles = []
            for tile in s['favoriteTiles']:
                x,y,w,hgt = tile['iconWindowFrame']
                # Window coordinates are bottom-up; PNG rows are top-down.
                points = [pixel(round((x+dx)*scale), round(height-(y+dy)*scale))
                    for dx in range(4,29,3) for dy in range(4,29,3)]
                spread = max(max(p[c] for p in points)-min(p[c] for p in points) for c in range(3))
                tiles.append(dict(index=tile['index'], spread=spread))
            captures[appearance] = dict(path=str(path), size=[width,height], scale=scale, pixels=tiles)
        return captures
    def quality(s):
        tiles = s.get('favoriteTiles',[])
        icons = [t for t in tiles if t.get('iconState')=='icon']
        return len(tiles)==len(icons)==12 and all(min(t['pixelSize'])>=32
            and t['elapsedMS']<=12000 and t['sourceKind'] in ('apple-touch','manifest','link','favicon.ico','curated') for t in icons) \
            and all(t['renderedKind']=='monogram' for t in tiles if t['iconState']!='icon')
    def monograms(s):
        tiles = s.get('favoriteTiles',[])
        return len(tiles)==12 and all(t.get('renderedKind')=='monogram' for t in tiles) and not s.get('error')
    def stable(before, after):
        lhs, rhs = before.get('favoriteTiles',[]), after.get('favoriteTiles',[])
        return len(lhs)==len(rhs)==12 and all(a['frame']==b['frame'] and a['iconWindowFrame']==b['iconWindowFrame']
            and a['iconFrame']==b['iconFrame']==[28,12,32,32]
            and a['frame'][2:]==b['frame'][2:]==[88,84] for a,b in zip(lhs,rhs))
    def row(name, ok, **data):
        results['favorite_icons_'+name] = dict(ok=bool(ok), load=os.getloadavg(), **data)
    def fresh(proof):
        return proof['factoryFresh'] and proof['initialScreen']=='intro' and not proof['firstRunCompleted'] \
            and proof['faviconRowsBeforePrefetch']==0 and proof['introElapsed']<proof['prefetchNotScheduledBefore'] \
            and proof['prefetchStarted'] is not True and not proof['snapshotExists']
    def pixel_icons(s, captures, fallback, fallback_captures):
        # The negative reference is this tile's actual monogram in a fresh,
        # blocked-network window, in the same appearance and selection state.
        # Sample the inner 24x24 pt square, avoiding rounded corners/shadows.
        # Require mean CIEDE2000 >=6 and >=25% of pixels with delta >=8.
        observed = []
        for appearance, shot in captures.items():
            _,height,pixel = h.read_image(shot['path'], srgb=True)
            _,mono_height,mono_pixel = h.read_image(fallback_captures[appearance]['path'], srgb=True)
            scale, mono_scale = shot['scale'], fallback_captures[appearance]['scale']
            for tile, monogram in zip(s['favoriteTiles'], fallback['favoriteTiles']):
                x,y,_,_ = tile['iconWindowFrame']; mx,my,_,_ = monogram['iconWindowFrame']
                deltas = [h.chrome_delta_e(pixel(round((x+dx)*scale),round(height-(y+dy)*scale)),
                    mono_pixel(round((mx+dx)*mono_scale),round(mono_height-(my+dy)*mono_scale)))
                    for dx in range(4,28) for dy in range(4,28)]
                mean = sum(deltas)/len(deltas); changed = sum(d>=8 for d in deltas)/len(deltas)
                observed.append(dict(name=tile['name'],appearance=appearance,meanDeltaE00=mean,
                    changedFraction=changed,ok=mean>=6 and changed>=.25))
        return dict(ok=len(observed)==24 and all(t['ok'] for t in observed),
            meanDeltaE00Minimum=6, changedPixelDeltaE00=8, changedFractionMinimum=.25, tiles=observed)
    def gmail_curated(s):
        tile = s['favoriteTiles'][0]
        return tile['name']=='Gmail' and tile['iconState']=='icon' and tile['sourceKind']=='curated' \
            and min(tile['pixelSize'])>=64 and not tile['storeHit'] \
            and tile['iconSourceURL']=='https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico' \
            and all(t['iconSourceURL'] is None for t in s['favoriteTiles'][1:])
    try:
        name, initial = launch()
        row('fresh_launch', fresh(initial['firstLaunchProof']), observed=initial['firstLaunchProof'])
        # Capture the actual initial fallback before the delayed intro prefetch.
        until(lambda: state().get('faviconFetch',{}).get('finished'), timeout=17)
        network = state()
        receipts['network'] = dict(initial=initial, final=network)
        (evidence/'network-state.json').write_text(json.dumps(network, indent=2))
        action('toggle-favorite', index=0); action('toggle-favorite', index=6)
        shots = capture('network')
        trace = Path(app.user_data)/'favicon-trace.jsonl'
        if trace.is_file(): shutil.copyfile(trace, evidence/'network-trace.jsonl')
        receipts['network'] = dict(initial=initial, final=network, captures=shots)
        (evidence/'icons-first-screenshots.json').write_text(json.dumps(receipts, indent=2))
        print('C7_FIRST_SCREENSHOTS '+json.dumps(shots), flush=True)
        row('network', quality(network), state=network,
            missing=[t['name'] for t in network['favoriteTiles'] if t['iconState']!='icon'])
        row('minimum_source', all(min(t['pixelSize'])>=32 and (min(t['pixelSize'])>=64 or t['iconStyle']=='plate')
            for t in network['favoriteTiles'] if t['iconState']=='icon'), state=network)
        focus = state()
        row('selected_focused', focus['favoriteTiles'][0]['focused'] and 0 in focus['favorites'], state=focus)
        preview = focus['favoritePreview']
        empty_preview = initial['favoritePreview']
        preview_shape = lambda p: p['size']==[200,440] and p['radius']==16 and p['headerHeight']==28 \
            and p['columns']==4 and p['tileSize']==[40,40] and p['gap']==8 and p['ghostRows']==6 \
            and p['favoritesArea']==[8,52,184,88] and p['dividerFrame']==[12,152,176,1] \
            and p['ghostStartY']==165 and p['ghostGap']==8
        row('preview', preview_shape(preview) and preview['selectedCount']==2 and preview['emptySlots']==0
            and all(item['frame'][2:]==[40,40] for item in preview['items']), state=preview)
        row('preview_empty', preview_shape(empty_preview) and empty_preview['emptySlots']==8 and empty_preview['selectedCount']==0,
            state=empty_preview)
        row('preview_empty_negative', not (preview['emptySlots']==8 and preview['selectedCount']==0), expected='FAIL')
        row('tile_style', all(t['style']['tileSize']==[88,84] and t['style']['radius']==14
            and t['style']['focusOutset']==3 and t['style']['focusWidth']==3 and t['style']['focusRadius']==19
            and t['style']['badgeDiameter']==18 and t['style']['badgeOffset']==4
            and t['style']['pressedScale']==.97 and t['style']['hoverDuration']==.12 for t in focus['favoriteTiles']), state=focus)
        row('selection_counter', initial['favoriteCountLabel']=='None selected' and focus['favoriteCountLabel']=='2 selected')
        for index in sorted(set(range(12)) - set(focus['favorites'])): action('toggle-favorite',index=index)
        full_preview = state()['favoritePreview']
        row('preview_bounded', full_preview['selectedCount']==12 and full_preview['visibleCount']==8
            and len(full_preview['items'])==8 and all(item['frame'][1]+item['frame'][3]<=140 for item in full_preview['items']),
            state=full_preview)
        for index in sorted(set(range(12)) - set(focus['favorites'])): action('toggle-favorite',index=index)
        x,y,w,hgt = focus['favoriteTiles'][0]['windowFrame']
        scale = focus['backingScale']
        for appearance, shot in shots.items():
            path = evidence/('favorites-selected-focused-'+appearance+'.png')
            padding = 24 # Include the outer focus ring, badge and their shadows.
            h.subprocess.run(['sips', '-c', str(round((hgt+padding*2)*scale)), str(round((w+padding*2)*scale)), '--cropOffset',
                str(round(shot['size'][1]-(y+hgt+padding)*scale)), str(round((x-padding)*scale)), shot['path'], '--out', str(path)],
                check=True, capture_output=True)
        # Move focus through the native key path. The tile interior must not
        # change: the focus indicator belongs only around its outside edge.
        app.call('key', key='tab')
        unfocused = capture('network-unfocused')
        focus_checks = []
        focus_deltas = []
        for appearance in shots:
            _,height,a = h.read_image(shots[appearance]['path'],srgb=True)
            _,_,b = h.read_image(unfocused[appearance]['path'],srgb=True)
            points = [(round((x+dx)*scale),round(height-(y+dy)*scale))
                for dx in range(10,int(w)-10) for dy in range(10,int(hgt)-10)]
            # Core Animation can round antialiased label edges by one sRGB
            # code value when appearance changes. A focus band differs by far
            # more; retain the measured maximum instead of exact byte identity.
            delta = max(max(abs(aa-bb) for aa,bb in zip(a(px,py),b(px,py))) for px,py in points)
            focus_deltas.append(delta); focus_checks.append(delta<=1)
        outside_deltas = []
        badge_pixels = []
        absent_badge_pixels = []
        for appearance in shots:
            _,height,a = h.read_image(shots[appearance]['path'],srgb=True)
            _,_,b = h.read_image(unfocused[appearance]['path'],srgb=True)
            px,py = round((x-4.5)*scale),round(height-(y+hgt/2)*scale)
            outside_deltas.append(max(abs(aa-bb) for aa,bb in zip(a(px,py),b(px,py))))
            def blue_badge(tile):
                bx,by,bw,bh = tile['windowFrame']
                points = [a(round((bx+bw+4+dx)*scale),round(height-(by+bh+4+dy)*scale))
                    for dx in range(-7,8) for dy in range(-7,8) if dx*dx+dy*dy<=49]
                return sum(p[2]>p[0]+40 and p[2]>p[1]+20 for p in points)
            badge_pixels.append(blue_badge(focus['favoriteTiles'][0]))
            absent_badge_pixels.append(blue_badge(focus['favoriteTiles'][1]))
        row('focus_outside', all(delta>=15 for delta in outside_deltas), observed=outside_deltas)
        row('focus_outside_negative', not all(delta<=1 for delta in outside_deltas), expected='FAIL')
        row('selection_badge', all(count>=60 for count in badge_pixels), observed=badge_pixels)
        row('selection_badge_negative', not all(count>=60 for count in absent_badge_pixels), expected='FAIL', observed=absent_badge_pixels)
        row('focus_border', all(focus_checks) and not state()['favoriteTiles'][0]['focused'],
            observed=focus_deltas, maximumChannelDifference=1)
        _,height,light = h.read_image(shots['light']['path'],srgb=True)
        _,_,dark = h.read_image(shots['dark']['path'],srgb=True)
        contrast_delta = max(max(abs(aa-bb) for aa,bb in zip(light(px,py),dark(px,py))) for px,py in points)
        row('focus_border_negative', contrast_delta>1, expected='FAIL', observed=contrast_delta)
        handoff_selection = {t['index'] for t in network['favoriteTiles'] if t['iconState']=='icon'}
        handoff_selection = set(sorted(handoff_selection)[:2])
        assert len(handoff_selection)==2, network
        for index in sorted(set(state()['favorites']) ^ handoff_selection): action('toggle-favorite', index=index)
        row('fixed_frames', stable(initial,network), initial=initial, final=network)
        row('fixed_frames_negative', not stable(name,network), expected='FAIL')
        fetch = network['faviconFetch']
        row('prefetch_bounds', fetch['introElapsedWhenStarted']>=3.3 and fetch['siteTimeoutSeconds']==6
            and fetch['overallTimeoutSeconds']==12 and fetch['concurrency']==6, observed=fetch)
        fade = [t['fadeDuration'] for t in network['favoriteTiles'] if t['iconState']=='icon']
        row('fade', bool(fade) and all(v in (0,.2) for v in fade) and .2 in fade
            and all(abs(t['arrivalDelay']-min(.18,t['index']*.018))<1e-9 for t in network['favoriteTiles']), observed=fade)
        database = Path(app.user_data)/'State/favicons.sqlite3'
        with sqlite3.connect('file:'+str(database)+'?mode=ro', uri=True) as db:
            before_store = list(db.execute('SELECT origin,png64,fetched_at FROM favicons WHERE status=0 ORDER BY origin'))
            gmail_url = db.execute("SELECT icon_url FROM favicons WHERE origin='https://mail.google.com' AND status=0").fetchone()
        # Product pages can redirect to a sign-in page with no icon declaration.
        # Distinct product artwork must be >=64 px; otherwise record the real
        # discovery reason instead of calling a generic login icon a product icon.
        trace_rows = [json.loads(line) for line in trace.read_text().splitlines()] if trace.is_file() else []
        google = []
        for tile, origin in zip(network['favoriteTiles'][:2], ('https://mail.google.com','https://maps.google.com')):
            events = [entry for entry in trace_rows if entry['origin']==origin]
            discovery = [entry for entry in events if entry['event'].startswith('discovered:')]
            declarations = [entry for entry in events if entry['event'].startswith('declared:')]
            google.append(dict(name=tile['name'], pixelSize=tile['pixelSize'], sourceKind=tile['sourceKind'],
                declarations=declarations, discovery=discovery,
                reason='curated source before page discovery' if tile['sourceKind']=='curated' else
                    'no icon declared in bounded final page head' if discovery and not declarations else 'declared icon available'))
        stored_images = [data for origin,data,_ in before_store if origin in ('https://mail.google.com','https://maps.google.com')]
        distinct_products = len(stored_images)==2 and stored_images[0]!=stored_images[1]
        gmail, maps = google
        curated_trace = [entry for entry in trace_rows if entry['event'].startswith('accepted:curated:')]
        row('gmail_curated', gmail_curated(network) and gmail_url==(network['favoriteTiles'][0]['iconSourceURL'],)
            and any(entry['url']==gmail_url[0] for entry in curated_trace), state=network['favoriteTiles'][0],
            storedURL=gmail_url, trace=curated_trace)
        maps_declared = maps['declarations'] and maps['sourceKind'] in ('apple-touch','manifest','link') and min(maps['pixelSize'])>=64
        row('google_product_discovery', distinct_products and gmail_curated(network) and maps_declared, sites=google,
            distinctImages=distinct_products, reason='Gmail curated artwork; Maps distinct declared artwork')
        row('google_product_discovery_negative', not (gmail['declarations'] and gmail['sourceKind'] in ('apple-touch','manifest','link')),
            expected='FAIL', observed='Curated Gmail cannot satisfy the Maps page-declared-artwork predicate')
        while state()['screen']!='ready':
            s=state()['screen']
            if s=='defaultBrowser': action('choose-default', yes=False); action('next')
            else: action('next')
        action('get-started'); until(lambda: not state()['active'] and not state()['dim']['exists'])
        def sidebar(): return [t for t in app.call('tabs') if t['section']=='favorites']
        until(lambda: len(sidebar())==2 and all(t['rowFaviconSource']=='stored' and t['rowFaviconHash'] for t in sidebar()))
        sidebar_tiles = sidebar()
        with sqlite3.connect('file:'+str(database)+'?mode=ro', uri=True) as db:
            after_store = list(db.execute('SELECT origin,png64,fetched_at FROM favicons WHERE status=0 ORDER BY origin'))
        row('sidebar_store_handoff', before_store==after_store and all(not t['hasWebContent'] and not t['loaded']
            and t['rowFaviconSource']=='stored' for t in sidebar_tiles), favorites=sidebar_tiles)
        receipts['sidebar'] = sidebar_tiles
        _, blocked_initial = launch(blocked=True)
        until(lambda: state()['faviconFetch']['finished'])
        blocked = state(); action('toggle-favorite',index=0); action('toggle-favorite',index=6)
        blocked_shots = capture('blocked')
        receipts['blocked'] = dict(initial=blocked_initial, final=blocked, captures=blocked_shots)
        row('blocked', monograms(blocked) and blocked['faviconFetch']['requests']==0
            and all(p['spread']>25 for shot in blocked_shots.values() for p in shot['pixels']), state=blocked, captures=blocked_shots)
        row('monogram_contrast', all(t['monogramContrast']>=4.5 for t in blocked['favoriteTiles']),
            observed=[dict(name=t['name'],color=t['monogramColor'],contrast=t['monogramContrast']) for t in blocked['favoriteTiles']])
        row('network_negative', not quality(blocked), expected='FAIL', state=blocked)
        row('blocked_negative', not monograms(network), expected='FAIL', state=network)
        row('blocked_fixed_frames', stable(blocked_initial,blocked), initial=blocked_initial, final=blocked)
        detected = pixel_icons(network, shots, blocked, blocked_shots)
        row('network_pixels', detected['ok'], observed=detected)
        rejected = pixel_icons(blocked, blocked_shots, blocked, blocked_shots)
        row('network_pixels_negative', not rejected['ok'] and all(not t['ok'] for t in rejected['tiles']),
            expected='FAIL', observed=rejected)
        print('C7_SIX_DESIGN_CAPTURES_READY '+str(evidence), flush=True)
        # Repeat with the same normal launch options and another fresh root.
        # A cache hit or monogram fails, even if the other eleven sites succeed.
        _, repeat_initial = launch()
        until(lambda: state()['faviconFetch']['finished'], timeout=17)
        repeated = state(); action('toggle-favorite', index=0); action('toggle-favorite', index=6)
        repeat_shots = capture('network-repeat')
        repeat_pixels = pixel_icons(repeated, repeat_shots, blocked, blocked_shots)
        repeat_trace = Path(app.user_data)/'favicon-trace.jsonl'
        if repeat_trace.is_file(): shutil.copyfile(repeat_trace, evidence/'network-repeat-trace.jsonl')
        row('fresh_launch_repeat', fresh(repeat_initial['firstLaunchProof']), observed=repeat_initial['firstLaunchProof'])
        row('network_repeat', quality(repeated) and all(not t['storeHit'] for t in repeated['favoriteTiles']),
            state=repeated, missing=[t['name'] for t in repeated['favoriteTiles'] if t['iconState']!='icon'])
        row('network_repeat_pixels', repeat_pixels['ok'], observed=repeat_pixels)
        row('gmail_curated_repeat', gmail_curated(repeated), state=repeated['favoriteTiles'][0])
        receipts['networkRepeat'] = dict(initial=repeat_initial, final=repeated, captures=repeat_shots, pixels=repeat_pixels)
        receipts['network']['pixels'] = detected
        # Force a real HTTP 404 on the curated URL, leaving system networking
        # and ordinary discovery unchanged. This fresh run fetches Google's
        # generic G through the original chain for the perceptual negative.
        _, fallback_initial = launch(curated_failure=True)
        until(lambda: state()['faviconFetch']['finished'], timeout=17)
        fallback = state(); action('toggle-favorite', index=0); action('toggle-favorite', index=6)
        fallback_shots = capture('curated-fallback')
        fallback_trace = Path(app.user_data)/'favicon-trace.jsonl'
        fallback_events = [json.loads(line) for line in fallback_trace.read_text().splitlines()]
        shutil.copyfile(fallback_trace, evidence/'curated-fallback-trace.jsonl')
        gmail_events = [entry for entry in fallback_events if entry['origin']=='https://mail.google.com']
        generic = fallback['favoriteTiles'][0]
        refused = [entry for entry in gmail_events if entry['event'].startswith('rejected:curated:')]
        row('gmail_curated_fallback', fresh(fallback_initial['firstLaunchProof']) and quality(fallback)
            and generic['sourceKind']=='favicon.ico' and not generic['storeHit'] and bool(refused)
            and any(entry['event']=='http:404' and 'open-onboarding-forced-missing' in entry['url'] for entry in gmail_events),
            state=generic, rejected=refused)
        discovery = [entry for entry in gmail_events if entry['event'].startswith('discovered:')]
        declarations = [entry for entry in gmail_events if entry['event'].startswith('declared:')]
        row('gmail_public_page_no_declaration', bool(discovery) and not declarations
            and all(entry['event'].startswith('discovered:0:') for entry in discovery), discovery=discovery, declarations=declarations)
        distinct = []
        for run_name, s, captures in [('first',network,shots),('second',repeated,repeat_shots)]:
            measured = pixel_icons(s, captures, fallback, fallback_shots)
            distinct.extend(dict(run=run_name, **tile) for tile in measured['tiles'] if tile['name']=='Gmail')
        row('gmail_distinct_from_generic', len(distinct)==4 and all(tile['ok'] for tile in distinct),
            meanDeltaE00Minimum=6, changedPixelDeltaE00=8, changedFractionMinimum=.25, observed=distinct)
        same = pixel_icons(fallback, fallback_shots, fallback, fallback_shots)
        row('gmail_distinct_from_generic_negative', all(not tile['ok'] for tile in same['tiles'] if tile['name']=='Gmail'),
            expected='FAIL', observed=[tile for tile in same['tiles'] if tile['name']=='Gmail'])
        receipts['curatedFallback'] = dict(initial=fallback_initial, final=fallback, captures=fallback_shots, gmailDifference=distinct)
        # Same window and real downloaded images with Reduce Motion: no fade.
        _, reduced_initial = launch(reduced=True)
        until(lambda: state()['faviconFetch']['finished'], timeout=17)
        reduced = state()
        reduced_icons = [t for t in reduced['favoriteTiles'] if t['iconState']=='icon']
        row('reduce_motion', bool(reduced_icons) and all(t['fadeDuration']==0 for t in reduced_icons)
            and stable(reduced_initial,reduced) and all(not t['style']['badgeScales'] for t in reduced['favoriteTiles'])
            and not reduced['favoritePreview']['arrivalScales'], state=reduced)
        row('reduce_motion_negative', not all(t['fadeDuration']==0 for t in network['favoriteTiles'] if t['iconState']=='icon'), expected='FAIL')
        receipts['reduced'] = reduced
    finally:
        if app:
            trace = Path(app.user_data)/'favicon-trace.jsonl'
            if trace.is_file(): shutil.copyfile(trace, evidence/'last-network-trace.jsonl')
        (evidence/'icon-receipts.json').write_text(json.dumps(receipts, indent=2))
        if app and not app.closed: app.quit()
        h._restore_defaults(None, saved)
