"""Setup gates through the real App, shared importer, native window and saved root."""
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import time


def run(factory, results, tmp, h):
    source = Path(tmp)/'setup-arc-synthetic'
    shutil.rmtree(source, ignore_errors=True)
    runpy.run_path(str(Path(h.ROOT)/'tools/e2e/firstrun.py'))['fixture'](source)
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
        action('set-name', name='  Example  ')
        action('next'); imported = screen('import'); shot('import-light')
        gate('same_window', lambda s: s['screen']=='import' and s['window']==initial['window'] and s['dim']['exists'], imported, initial)
        action('skip'); favorites = screen('favorites'); shot('favorites-empty-light')
        action('toggle-favorite', index=0); action('toggle-favorite', index=6)
        selected = state(); shot('favorites-selected-light')
        gate('favorite_selection', lambda s: s.get('favorites')==[0,6], selected, favorites)
        action('next'); theme = screen('theme'); action('set-theme', preset=5); themed = state(); shot('theme-light')
        gate('theme_choice', lambda s: s['theme']!=theme['theme'], themed, theme)
        action('next'); screen('blocker'); action('set-blocker', on=False); off = state(); shot('blocker-off-light')
        gate('blocker_choice', lambda s: s.get('blocker') is False, off, initial)
        action('next'); default = screen('defaultBrowser'); shot('default-browser-light')
        gate('no_default_prompt_before_click', lambda s: s['screen']=='defaultBrowser' and not s['defaultAttempted'], default, off)
        action('choose-default', yes=False); action('next'); ready = screen('ready'); shot('ready-light')
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
        results['steps_card_png'] = dict(ok=(width,height)==(1200,750) and pixel(600,375)!=pixel(1,1), size=[width,height], load=os.getloadavg())
        # No model, name or global blocker write before Get Started.
        pending = dict(snapshot=snapshot().exists(), name=app.call('defaults', key=keys[0], persistent=True))
        results['steps_pending_no_writes'] = dict(ok=not pending['snapshot'] and pending['name'] is None, state=pending, load=os.getloadavg())
        action('get-started')
        handoff = state(); until(lambda: not state()['active'] and not state()['dim']['exists'])
        final = state(); stored = json.loads(snapshot().read_text())
        tabs = app.call('tabs'); selected_tabs = [t for t in tabs if t.get('selected')]
        welcome = app.call('welcome')
        native_welcome = lambda s: s.get('visible') and s.get('engineInternalPages')==0 and s.get('urlField')=='Welcome to Open'
        gate('welcome_native_selected', native_welcome, welcome, {})
        welcome_id = welcome['tab']
        results['steps_welcome_first_today'] = dict(ok=bool(selected_tabs) and selected_tabs[0]['id']==welcome_id
            and app.call('tab-state', tab=welcome_id)['section']=='today' and tabs[0]['id']==welcome_id, load=os.getloadavg())
        adblock = json.loads(Path(app.user_data,'adblock-settings.json').read_text())
        saved_name = app.call('defaults', key=keys[0], persistent=True)
        results['steps_final_data'] = dict(ok=saved_name=='Example' and adblock.get('nativeAdBlockEnabled') is False
            and len([t for t in tabs if t['url'] in ('https://mail.google.com/','https://github.com/')])==2
            and 'keyColor' in json.dumps(stored), load=os.getloadavg(), blocker=adblock, savedName=saved_name)
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
        prepared = [w for w in app.call('windows') if w['class']=='BrowserWindow']
        hidden_browser = lambda windows: bool(windows) and all((not w['visible'] or w['alpha']==0)
            and not w['key'] and not w['main'] for w in windows)
        gate('import_browser_hidden', hidden_browser, prepared, [dict(visible=True,alpha=1,key=True,main=True)])
        action('next'); after_import = screen('theme')
        gate('import_skips_favorites', lambda s: s.get('screen')=='theme', after_import, favorites)
        results['steps_import_report'] = dict(ok=report['outcome'].get('Favorites')==1 and report['outcome'].get('Imported tabs')==7 and not report['completed'], load=os.getloadavg(), outcome=report['outcome'])
        skip_to_ready(); action('get-started')
        until(lambda: not state()['active'] and not state()['dim']['exists'])
        revealed = [w for w in app.call('windows') if w['class']=='BrowserWindow']
        gate('import_browser_revealed', lambda ws: bool(ws) and any(w['visible'] and w['alpha']==1 and w['key'] for w in ws), revealed, prepared)
        # Empty source skips Import. Escape returns to the actual preceding step.
        launch(directory=empty); action('next'); no_data = screen('favorites')
        gate('no_arc_skips_import', lambda s: s['screen']=='favorites', no_data, imported)
        app.call('key', key='escape'); escaped = screen('name')
        gate('escape_back', lambda s: s['screen']=='name', escaped, no_data)
        action('skip'); screen('favorites'); action('skip'); screen('theme'); action('skip'); screen('blocker'); action('skip'); screen('defaultBrowser')
        action('choose-default', yes=False); action('next'); blank = screen('ready')
        results['steps_every_skip'] = dict(ok=blank['name']=='' and blank['favorites']==[] and blank['blocker'] is False and blank['title']=='Welcome to Open.', state=blank, load=os.getloadavg())
        # A real write failure keeps Ready open and D3 unset; retry reuses choices.
        snapshot().mkdir(); action('get-started'); failure = state()
        gate('save_error', lambda s: s['active'] and s['screen']=='ready' and 'could not save' in s['error'], failure, blank)
        assert app.call('first-run')['completed'] is False
        snapshot().rmdir(); action('get-started'); until(lambda: not state()['active']); assert app.call('first-run')['completed']
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
        results['steps_accessibility_labels'] = dict(ok=len(ax_steps)==7 and all(c['label'] for c in controls) and any(c['label']=='Get Started' for c in controls), controls=ax_steps, load=os.getloadavg())
        (evidence/'negative-proofs.json').write_text(json.dumps(negatives, indent=2))
    finally:
        if app and not app.closed: app.quit()
        h._restore_defaults(None, saved)
