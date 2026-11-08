"""Setup gates through the real App, shared importer, native window and saved root."""
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import time
import uuid


def run(factory, results, tmp, h):
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
    keys = ('open.onboarding.name', 'open.firstRun.completed', 'open.import.lastArcDir', 'open.settings.lastPane')
    saved = {key: domain.get(key) for key in keys}
    app = None
    negatives = {}
    ax_steps = {}
    def state(): return app.call('onboarding', action='state')
    def until(predicate, timeout=20):
        assert h.wait_until(predicate, timeout=timeout, step=.025), state()
    def screen(name): until(lambda: state()['screen']==name); return state()
    def launch(directory=source, fresh=True, flags=(), **env):
        nonlocal app
        if app and not app.closed: app.quit()
        if fresh: h._restore_defaults(None, {keys[0]: None, keys[1]: None})
        app = factory(urls=(), fresh=fresh, extra_args=['--arc-dir='+str(directory), '--intro-sound=off', *flags], extra_env=env)
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
        raise AssertionError(state())
    def snapshot(): return Path(app.user_data)/'State/browser.json'
    try:
        h._restore_defaults(None, {key: None for key in keys})
        initial = launch()
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
        gate('keyboard_tab_order', lambda s: s.get('focus')=='Google Calendar', tabbed, backwards)
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
        gate('confetti', lambda s: s.get('confettiPlayed') is True, ready, initial)
        action('shuffle-card'); shuffled = state(); shot('ready-shuffled-light')
        gate('shuffle', lambda s: s.get('cardPattern')==1, shuffled, ready)
        # Real NSSavePanel service response reaches its production completion.
        action('save-card'); until(lambda: state()['savePanel'])
        action('card-cancel'); until(lambda: not state()['savePanel'])
        card_path = evidence/'open-card.png'
        action('save-card'); until(lambda: state()['savePanel'])
        action('card-save', path=str(card_path)); until(lambda: card_path.is_file())
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
        # A real write failure keeps Ready open and D3 unset; retry reuses choices.
        for _ in range(4): action('back')
        screen('favorites'); action('toggle-favorite', index=0); action('toggle-favorite', index=6)
        for _ in range(3): action('next')
        screen('defaultBrowser'); action('choose-default', yes=False); action('next'); screen('ready')
        snapshot().mkdir(); action('get-started'); failure = state()
        gate('save_error', lambda s: s['active'] and s['screen']=='ready' and 'could not save' in s['error'], failure, blank)
        assert app.call('first-run')['completed'] is False
        snapshot().rmdir(); action('get-started'); until(lambda: not state()['active']); assert app.call('first-run')['completed']
        retried_tabs = app.call('tabs')
        results['steps_save_retry_no_duplicates'] = dict(ok=len([t for t in retried_tabs if t['section']=='favorites'])==2
            and len([t for t in retried_tabs if t['url']=='open://welcome'])==1, load=os.getloadavg())
        # Already default is a read-only automation outcome. No system prompt runs.
        launch(directory=empty, OPEN_AUTOMATION_DEFAULT_BROWSER='already'); skip_to_ready()
        already = state(); action('back'); offered = screen('defaultBrowser'); shot('already-default-light')
        gate('already_default', lambda s: s.get('alreadyDefault') is True and not s['defaultAttempted'], offered, default)
        # Decline and failure both show their outcome before continuing.
        for outcome in ('declined','failed','success'):
            launch(directory=empty, **{'OPEN_AUTOMATION_DEFAULT_BROWSER': outcome}); action('skip'); action('skip'); action('skip'); action('skip'); screen('defaultBrowser')
            action('next'); during = state()
            until(lambda: state()['screen']=='ready')
            gate('default_'+outcome, lambda s: s['defaultPending'] and s['defaultAttempted'] and bool(s['defaultOutcome']), during, default)
        # Reduced motion has no offset or emitter, including after back/forward.
        launch(directory=empty, flags=['--reduce-motion']); reduced = skip_to_ready(); shot('ready-reduce-motion')
        gate('reduced', lambda s: s['reduceMotion'] and s['offset']==0 and not s['confettiPlayed'] and not s['confettiActive'], reduced, ready)
        action('set-appearance', appearance='dark'); shot('ready-dark')
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
        h._restore_defaults(None, saved)
