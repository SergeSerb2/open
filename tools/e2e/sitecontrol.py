"""SCC acceptance through Open's real anchors, controls, menus and engine.

The fixture and its server belong to this invocation. No desktop input.
"""
from pathlib import Path
import hashlib
import json
import os
import statistics
import time
import uuid


from sitecontrol_fixtures import fixture_server

def run(factory, results, tmp, env, functional_only=False):
    wait, new_tab = env['wait_until'], env['new_tab']
    load = lambda: list(os.getloadavg())
    with fixture_server(tmp) as origin:
        # SCC's scroll load stays local to this suite. Both Section 12 suites
        # use the same ads/Boost pages from sitecontrol_fixtures.
        # S11_light / S14: the Arc 14c page background and a black block behind the panel's empty material.
        (Path(tmp) / 'sitecontrol-fixtures' / 'light.html').write_text(
            '<!doctype html><title>Light fixture</title><body style="margin:0;background:#F3F5EE">'
            '<h1 id="ghost" style="visibility:hidden;position:absolute;left:12px;top:142px;margin:0;font:800 40px -apple-system;color:#24382c">Lisbon weather</h1>',
            encoding='utf-8')
        (Path(tmp) / 'sitecontrol-fixtures' / 'heavy.html').write_text(
            '<!doctype html><style>body{margin:0;background:white}.card{height:70px;background:linear-gradient(90deg,#fff,#def);border-bottom:1px solid #aaa}</style>'
            + ''.join('<div class="card">%d</div>' % i for i in range(2000)),
            encoding='utf-8')
        # Use the real bundled filter, as settings_adblock.real_engine does.
        # This host resolves only to our ephemeral fixture, never the network.
        repo = Path(env['ROOT'])
        rule = '||demand.supply^$script'
        pin = next(line.split()[2] for line in
                   (repo/'Packages/OpenKit/Sources/OpenAdBlock/Resources/list-pins.txt').read_text().splitlines()
                   if line.startswith('easylist.txt '))
        easylist = (repo/'Vendor/adblock/easylist.txt').read_bytes()
        assert hashlib.sha256(easylist).hexdigest() == pin and rule in easylist.decode().splitlines()
        fixture_args = [
            '--host-resolver-rules=MAP demand.supply 127.0.0.1:'+origin.rsplit(':',1)[1],
            '--no-proxy-server']
        original_factory = factory
        def factory(*args, **kwargs):
            kwargs['extra_args'] = [*kwargs.get('extra_args', []), *fixture_args]
            return original_factory(*args, **kwargs)
        if env.get('E2E_LANE') == 'observers':
            from sitecontrol_performance import run as performance
            performance(factory, results, origin, tmp, env)
            return
        app = factory(urls=('about:blank',))
        saved = {}
        private = Path(env['ROOT']) / '.re/handoff/sections/s12/A-sitecontrol'
        private.mkdir(parents=True, exist_ok=True)
        def state(): return app.call('site-controls', action='state')
        def close(): return app.call('site-controls', action='close')
        def opened(via='urlField'):
            if state()['presented']: close()
            return app.call('site-controls', action='open', via=via)
        def row(s, identifier): return next((r for r in s['rows'] if r['id'] == identifier), {})
        def control(s, identifier): return next((r for r in s['controls'] if r['id'] == identifier), {})
        def permission_index():
            return {str(p.relative_to(app.user_data)): dict(mtimeNS=p.stat().st_mtime_ns,
                    sha256=hashlib.sha256(p.read_bytes()).hexdigest(), origins=json.loads(p.read_text()))
                    for p in Path(app.user_data).rglob('OpenPermissionOrigins.json')}
        def record(key, ok, **detail):
            results[key] = dict(ok=bool(ok), load=load(), **detail)
            print(key, 'PASS' if ok else 'FAIL', flush=True)
        def recorded_visual(key, value):
            # LEAD 02:35 approves exactly these two S12-V rows for Step 4.
            # CheckedResults still audits App life, focus and crashes first;
            # retain the failed pixel predicate and every raw measurement.
            assert key in ('S11_material', 'S12_elements')
            measured = (len(value.get('probes', [])) == 4 if key == 'S11_material'
                        else bool(value.get('elements')) and {k: value.get('limits', {}).get(k) for k in ('positionPoints', 'deltaE00')} == {'positionPoints': 1, 'deltaE00': 2})
            deferred = value.get('ok') is False and measured and value.get('negativeRejected') is True
            if deferred:
                value['reason'] = 'S12-V: recorded Site Control material and element colour fault (LEAD 02:35, 2026-11-11)'
            try:
                results[key] = value
            except env['SuiteStopped'] as stop:
                if not deferred or stop.failed_row != key or results.get(key) is not value:
                    raise
                env['begin_row']('after ' + key)
                print(key + ' raw FAIL; exact S12-V deferral, continuing', flush=True)
        def blocked(key, reason, **detail):
            results[key] = dict(status='BLOCKED', reason=reason, load=load(), **detail)
        def refused(**args):
            try: app.call('site-controls', **args); return False
            except RuntimeError: return True
        try:
            for key, value in {'open.advanced.playSoundEffects': False, 'open.advanced.showToolbar': False,
                               'open.settings.lastPane': 'general',
                               'open.advanced.enableBoosts': True,
                               'open.boosts.hasDismissedInterstitial': False}.items():
                saved[key] = app.call('defaults', key=key, persistent=True)
                app.call('defaults', key=key, value=value)
            app.call('appearance', name='dark')
            app.call('window-frame', frame=[80,60,1200,800])
            app.call('window-focus', id=app.call('window-state')['id'], activate=True)
            tab = new_tab(app, origin + '/ads.html')
            # S2 must exercise the bound AdBlockStore adapter. A synthetic
            # request filter here would replace the Profile's real filter.
            app.call('navigate', tab=tab, url=origin+'/ads.html'); app.call('wait', tab=tab)
            adblock_open_before = Path(app.user_data, '.adblock-lock').exists()
            before = state()
            permission_before = permission_index()
            s = opened()
            permission_ready = app.call('site-controls', action='permission-index')['ready']
            permission_after = permission_index()
            record('S1_permission_read_only', permission_ready and permission_before == permission_after
                   and all(origin not in p['origins'] for p in permission_before.values()),
                   before=permission_before, after=permission_after, origin=origin,
                   negative='old panel reads remember this never-decided origin and write the index')
            s = state()
            adblock = app.call('site-controls', action='adblock-state')
            adblock_available = adblock['bindingInstalled'] and adblock['profileOpen'] and adblock['enabled']
            expected_adblock = ('on' if adblock['shouldBlock'] else 'off') if adblock_available else 'unavailable'
            startup = app.call('startup')
            # Command services legitimately open Settings after first paint.
            # Capture the owner at the existing pre-engine startup checkpoint,
            # after the real window and SCC source have been constructed.
            record('S1_lazy_adblock_owner', startup.get('adBlockOwnerOpenBeforeEngine') is False,
                   startup=startup,
                   openedBefore=adblock_open_before,
                   openedAfter=Path(app.user_data, '.adblock-lock').exists())
            actions = [r for r in s['controls'] if r['id'].startswith('action.')]
            expected = {'action.share','action.newBoost','action.capture','action.captureFull'}
            anchor, tip, body = s['anchor'], s['tip'], s['body']
            geometry = abs(tip[0] - anchor[0] - anchor[2]/2) <= 1 and abs(tip[1] - anchor[1] - anchor[3] - 2) <= 1 and abs(body[1] - tip[1] - 10) <= 1
            # Closed state is the negative control for all visible SCC elements.
            record('S1_open', not before['presented'] and s['presented'] and {r['id'] for r in actions} == expected
                   and s['extensionsVisible'] and any(i['id'] == 'extension.add' and i['visible'] for i in s['extensionItems'])
                   and row(s,'row.contentBlocking').get('title') == 'Block Ads & Trackers'
                   and row(s,'row.contentBlocking').get('state') == expected_adblock
                   and s['security'].get('title') == 'Connection: Insecure' and geometry,
                   state=s, negative=before, adBlockStore=adblock, expectedAdBlockState=expected_adblock,
                   oldUnavailableAssertionRejected=row(s,'row.contentBlocking').get('state') != 'unavailable')
            app.call('snapshot', path=str(private/'S1-open.png'))
            toggled_closed=app.call('site-controls', action='open')
            reopened=app.call('site-controls', action='open')
            record('S1_toggle', not toggled_closed['presented'] and reopened['presented'],
                   closed=toggled_closed['presented'], reopened=reopened['presented'])
            close()
            point=dict(x=anchor[0]+anchor[2]/2,y=anchor[1]+anchor[3]/2,queued=True)
            app.call('mouse',action='click',modifiers=['option'],**point)
            option_closed=not state()['presented']
            app.call('mouse',action='click',**point)
            record('S1_option_click',option_closed and state()['presented'],negativeOptionIgnored=option_closed)
            # An unopened/disabled adapter remains a supported unavailable
            # case. Only the real available store can qualify S2.
            if row(s,'row.contentBlocking').get('state') == 'unavailable':
                # Settings may open the Profile. Its current real store,
                # rather than the prior drawn state, decides availability.
                settings_file=Path(app.user_data,'adblock-settings.json')
                settings_before=settings_file.read_bytes() if settings_file.exists() else None
                browser=app.call('window-state')['id']
                actions_before=state()['sourceActions']
                tapped=app.call('site-controls',action='tap',id='row.contentBlocking')
                action_calls={key:tapped['sourceActions'][key]-actions_before[key] for key in actions_before}
                settings=app.call('settings-state')
                app.call('menu-perform',id='close-window')
                app.call('window-focus',id=browser,activate=True)
                unavailable=opened()
                after_settings=app.call('site-controls',action='adblock-state')
                now_available=after_settings['bindingInstalled'] and after_settings['profileOpen'] and after_settings['enabled']
                expected_after=('on' if after_settings['shouldBlock'] else 'off') if now_available else 'unavailable'
                settings_after=settings_file.read_bytes() if settings_file.exists() else None
                record('S1_unavailable_settings',settings['settings']>0 and settings['pane']=='advanced'
                       and row(unavailable,'row.contentBlocking').get('state')==expected_after
                       and action_calls=={'toggle':0,'openAdBlockSettings':1}
                       and settings_before==settings_after,settings=settings,unchanged=settings_before==settings_after,
                       sourceActionCalls=action_calls,adBlockStore=after_settings,
                       negative='the unavailable tile must open Settings without toggling or changing persisted settings')
                s=unavailable
            if row(s,'row.contentBlocking').get('state') == 'unavailable':
                blocked('S2_adblock', 'section 13 ad-block adapter', row=row(unavailable,'row.contentBlocking'))
            else:
                def native_adblock():
                    page = app.call('tab-state', tab=tab)['page']['identifier']
                    return next((context for profile in app.call('settings-adblock-engine')['profiles']
                                 for context in profile['contexts']
                                 if any(p['identifier'] == page for p in context['pages'])), {})
                # Settings disables exclusion edits until its Profile is ready.
                # Keep that ordering explicit, including the unchanged-main control.
                settings_ready = wait(lambda: app.call('settings-adblock')['ready'], timeout=30)
                if not settings_ready:
                    record('S2_settings_ready', False, timeoutSeconds=30)
                    raise AssertionError('S2 Settings Profile did not become ready')
                def exclusion_barrier(excluded):
                    expected = 1 if excluded else 0
                    status = wait(lambda: (lambda c: c if c.get('adBlockStatus',{}).get('excluded_count') == expected else None)(native_adblock()), timeout=10)
                    if not status:
                        record('S2_exclusion_barrier', False, expectedCount=expected,
                               timeoutSeconds=10, native=native_adblock())
                        raise AssertionError('S2 native exclusion state did not settle')
                    return status
                ready = wait(lambda: native_adblock().get('adBlockStatus',{}).get('engine_loaded'), timeout=40)
                app.call('navigate', tab=tab, url=origin+'/ads.html'); app.call('wait', tab=tab)
                initial_on = opened()
                initial_native = native_adblock()
                initial_loaded = app.eval(tab,'window.fixtureAdLoaded === true')
                record('S2_initial_on', ready and row(initial_on,'row.contentBlocking').get('state') == 'on'
                       and initial_loaded is False
                       and any(p['blockedCount'] > 0 for p in initial_native.get('pages',[])
                               if p['identifier'] == app.call('tab-state',tab=tab)['page']['identifier']),
                       scriptLoaded=initial_loaded, native=initial_native, list='easylist.txt', rule=rule,
                       listSHA256=pin, locallyResolved=True)
                off = app.call('site-controls', action='tap', id='row.contentBlocking')
                files = list(Path(app.user_data).glob('Profiles/*/adblock/exclusions.json'))
                persisted = any('127.0.0.1' in json.loads(p.read_text()) for p in files)
                off_native = exclusion_barrier(True)
                app.call('site-controls', action='tap', id='reload'); app.call('wait', tab=tab)
                allowed = app.eval(tab,'window.fixtureAdLoaded === true')
                on = app.call('site-controls', action='tap', id='row.contentBlocking') if state()['presented'] else None
                if on is None: opened(); on = app.call('site-controls',action='tap',id='row.contentBlocking')
                on_native = exclusion_barrier(False)
                app.call('site-controls', action='tap', id='reload'); app.call('wait', tab=tab)
                denied = app.eval(tab,'window.fixtureAdLoaded === true')
                record('S2_adblock', row(off,'row.contentBlocking').get('subtitle') == 'Off' and off['reloadVisible'] and persisted
                       and row(on,'row.contentBlocking').get('subtitle') == 'On' and allowed is True and denied is False,
                       off=off,on=on,allowed=allowed,blocked=denied)
                # Keep the exact drawn tile, change the real owner through
                # automation, then deliver the retained value via onToggle.
                # The old tile.state decision fails in both directions.
                stale_proofs = []
                for initial_excluded in (False, True):
                    opened()
                    app.call('site-controls', action='set-adblock-excluded', excluded=initial_excluded)
                    captured_state = 'off' if initial_excluded else 'on'
                    captured = wait(lambda: (lambda x: x if row(x,'row.contentBlocking').get('state') == captured_state else None)(state()), timeout=5)
                    app.call('site-controls', action='capture-content-blocking')
                    app.call('site-controls', action='set-adblock-excluded', excluded=not initial_excluded)
                    changed_state = 'on' if initial_excluded else 'off'
                    changed = wait(lambda: (lambda x: x if row(x,'row.contentBlocking').get('state') == changed_state else None)(state()), timeout=5)
                    app.call('site-controls', action='toggle-captured-content-blocking')
                    restored = wait(lambda: (lambda x: x if row(x,'row.contentBlocking').get('state') == captured_state else None)(state()), timeout=5)
                    actual = app.call('site-controls', action='adblock-state')
                    stale_proofs.append(dict(captured=captured, changed=changed, restored=restored,
                        store=actual, initialExcluded=initial_excluded,
                        ok=bool(captured and changed and restored and restored['reloadVisible'])
                           and actual['shouldBlock'] is (not initial_excluded)))
                record('S2_stale_tile', all(p['ok'] for p in stale_proofs), directions=stale_proofs,
                       negative='using tile.state leaves the changed exclusion in place instead of toggling current state')
                # Leave the shared fixture blocking, as before these proofs.
                opened(); app.call('site-controls', action='tap', id='row.contentBlocking')
            standard = state()
            standard_picker = standard['mode'] == 'extensionPicker' and standard['focusedControl'] == 'extension.add'
            close(); app.call('key', key='e', modifiers=['cmd'], route='app')
            empty_picker = state()
            app.call('key', key='return', route='app')
            added = wait(lambda: next((t for t in app.call('tabs') if t['selected']
                         and t['url'] == 'https://chromewebstore.google.com/category/extensions'), None), timeout=5)
            record('S1_empty_picker', not standard_picker and empty_picker['presented']
                   and empty_picker['mode'] == 'extensionPicker' and empty_picker['focusedControl'] == 'extension.add'
                   and bool(added) and not state()['presented'], state=empty_picker,
                   negativeStandardRejected=not standard_picker, openedStore=bool(added))
            app.call('key', key='w', modifiers=['cmd'], route='app'); app.call('select', tab=tab)
            close()
            app.call('permission', origin=origin, kind=1, state=0)
            app.call('permission', origin=origin, kind=1, state=1)
            opened()
            for _ in range(32):
                app.call('key',key='tab',route='app')
                if state()['focusedControl']=='permission.camera': break
            focus=state()['focusedControl']
            app.call('key',key='return',route='app')
            returned=app.call('permission',origin=origin,kind=1)
            app.call('key',key='space',route='app')
            spaced=app.call('permission',origin=origin,kind=1)
            record('S3_keyboard',focus=='permission.camera' and returned==2 and spaced==1,
                   focused=focus, afterReturn=returned, afterSpace=spaced)
            app.call('permission', origin=origin, kind=1, state=0)
            absent = opened()
            app.call('permission', origin=origin, kind=1, state=1)
            allowed = wait(lambda: (lambda x:x if row(x,'row.permission.camera').get('subtitle') == 'Allowed' else None)(state()), timeout=5)
            toggled = app.call('site-controls', action='tap', id='row.permission.camera')
            value = app.call('permission', origin=origin, kind=1)
            record('S3_permission', not row(absent,'row.permission.camera') and bool(allowed) and row(toggled,'row.permission.camera').get('subtitle') == 'Blocked' and value == 2 and toggled['reloadVisible'], allowed=allowed,blocked=toggled,negative=absent)
            app.call('permission', origin=origin, kind=1, state=0)
            # S3_content (A10 E1, SC-11/SC-12): a changed content setting shows as a tile with Arc's
            # subtitle; a tap flips the engine value; a setting back at its default does not appear.
            def site_settings(): return {x['kind']: x['state'] for x in app.call('site-settings', origin=origin)}
            close(); app.call('site-setting', origin=origin, kind='javascript', state='allow')
            content_absent = opened()
            close(); app.call('site-setting', origin=origin, kind='javascript', state='block')
            app.call('site-setting', origin=origin, kind='popups', state='allow')
            content_shown = opened()
            content_ids = [r['id'] for r in content_shown['rows'] if r['id'].startswith('row.content.')]
            content_unblocked = app.call('site-controls', action='tap', id='row.content.javascript')
            content_engine_allowed = 'javascript' not in site_settings()
            content_reblocked = app.call('site-controls', action='tap', id='row.content.javascript')
            content_engine_blocked = site_settings().get('javascript') == 'block'
            close(); app.call('site-setting', origin=origin, kind='javascript', state='allow')
            app.call('site-setting', origin=origin, kind='popups', state='block')
            record('S3_content',
                   not any(r['id'].startswith('row.content.') for r in content_absent['rows'])
                   and content_ids == ['row.content.javascript', 'row.content.popups']
                   and row(content_shown, 'row.content.javascript').get('subtitle') == 'Blocked'
                   and row(content_shown, 'row.content.popups').get('subtitle') == 'Allowed'
                   and row(content_unblocked, 'row.content.javascript').get('subtitle') == 'Allowed'
                   and content_engine_allowed and content_unblocked['reloadVisible']
                   and row(content_reblocked, 'row.content.javascript').get('subtitle') == 'Blocked'
                   and content_engine_blocked and 'javascript' not in site_settings() and 'popups' not in site_settings(),
                   shown=[(r['id'], r.get('title'), r.get('subtitle')) for r in content_shown['rows']],
                   unblocked=row(content_unblocked, 'row.content.javascript'), reblocked=row(content_reblocked, 'row.content.javascript'),
                   negative='defaults only: no content rows')
            app.call('site-controls', action='permission-index')
            close()
            undecided_origin = origin.replace('127.0.0.1','localhost')
            undecided = new_tab(app, undecided_origin+'/boost.html')
            indexed_before = permission_index()
            read_only = opened()
            indexed_ready = app.call('site-controls', action='permission-index')['ready']
            indexed_after = permission_index()
            record('S3_permission_index_unchanged', indexed_ready and read_only['presented']
                   and bool(indexed_before) and indexed_before == indexed_after
                   and any(origin in p['origins'] for p in indexed_before.values())
                   and all(undecided_origin not in p['origins'] for p in indexed_before.values()),
                   before=indexed_before, after=indexed_after, origin=undecided_origin,
                   negative='old state() adds the never-decided origin and changes file content and mtime')
            close(); app.call('key',key='w',modifiers=['cmd'],route='app'); app.call('select',tab=tab)
            # Create and persist through the real editor, then exercise the
            # SCC's visible controls against the sole AppBoosts owner.
            def editor(action='state', **args): return app.call('boost-editor', action=action, **args)
            empty_boosts=opened()
            empty_negative=not empty_boosts['boostsVisible'] and not any(
                c['id'].startswith('boost.') for c in empty_boosts['controls'])
            app.call('site-controls',action='tap',id='action.newBoost')
            if editor().get('interstitial'): editor('tap',id='firstRun.makeABoost')
            assert wait(lambda:editor().get('colorsReady'),timeout=10,step=.05)
            before_outline=app.eval(tab,'getComputedStyle(document.body).outlineStyle')
            editor('tap',id='code')
            assert wait(lambda:editor().get('mode')=='code',timeout=5,step=.02)
            editor('type',text='body{outline:3px solid red !important}')
            assert wait(lambda:app.eval(tab,'getComputedStyle(document.body).outlineStyle')=='solid',timeout=5,step=.02)
            boost_id=editor()['boost']['id']; boost_profile=editor()['profile']
            editor('close')
            def stored_boost(): return app.call('boosts',action='get',boost=boost_id,profile=boost_profile)
            circle='boost.'+boost_id+'.circle'; edit_row='boost.'+boost_id+'.row'
            matching=opened()
            record('S4_boost',empty_negative and matching['boostsVisible']
                   and all(control(matching,c).get('visible') and control(matching,c).get('enabled') for c in (circle,edit_row))
                   and stored_boost()['isEnabled'] and control(matching,edit_row).get('title')=='Edit '+stored_boost()['name']
                   and matching['urlButtonState'] in ('boosted','openBoosted'),
                   state=matching,stored=stored_boost(),negativeEmpty=empty_negative,negativeOutline=before_outline)
            app.call('site-controls',action='tap',id=circle)
            assert wait(lambda:not stored_boost()['isEnabled'],timeout=5,step=.02)
            off=wait(lambda:(lambda x:x if x['urlButtonState'] not in ('boosted','openBoosted') else None)(state()),timeout=5,step=.02)
            outline_off=bool(wait(lambda:app.eval(tab,'getComputedStyle(document.body).outlineStyle')=='none',timeout=5,step=.02))
            off_store=stored_boost()
            app.call('site-controls',action='tap',id=circle)
            assert wait(lambda:stored_boost()['isEnabled'],timeout=5,step=.02)
            on=wait(lambda:(lambda x:x if x['urlButtonState'] in ('boosted','openBoosted') else None)(state()),timeout=5,step=.02)
            outline_on=bool(wait(lambda:app.eval(tab,'getComputedStyle(document.body).outlineStyle')=='solid',timeout=5,step=.02))
            record('S4_toggle_glyph',outline_off and outline_on and before_outline=='none' and bool(off and on) and not off_store['isEnabled'] and stored_boost()['isEnabled']
                   and all(control(x,edit_row).get('visible') for x in (off,on) if x),
                   disabled=off,reenabled=on,negativeDisabled=off_store,liveCSSDisabled=outline_off,liveCSSReenabled=outline_on)
            editor_closed=not editor().get('open')
            app.call('site-controls',action='tap',id=edit_row)
            edited=editor()
            record('S4_edit',editor_closed and edited.get('open') and edited['boost']['id']==boost_id,
                   editor=edited,negativeClosed=editor_closed)
            editor('close')
            unmatched=new_tab(app,origin.replace('127.0.0.1','localhost')+'/boost.html')
            unmatched_state=opened()
            unmatched_negative=not unmatched_state['boostsVisible'] and unmatched_state['urlButtonState'] not in ('boosted','openBoosted')
            close();app.call('key',key='w',modifiers=['cmd'],route='app');app.call('select',tab=tab)
            rematched=opened()
            record('S4_match_boundary',unmatched_negative and rematched['boostsVisible']
                   and control(rematched,edit_row).get('visible'),
                   negativeUnmatched=unmatched_state,matching=rematched)
            # boost.html shares the cookie's origin and does not set it again
            # on reload, so S5 can prove that Clear Cookies removed it.
            close(); app.call('navigate', tab=tab, url=origin+'/boost.html'); app.call('wait', tab=tab)
            cookie_before = app.eval(tab, 'document.cookie')
            s=opened(); cache_available = any(i['title']=='Clear Cache' and i['enabled'] for i in s['items'])
            cleared = app.call('site-controls', action='menu', item='Clear Cookies')
            cookie_gone = wait(lambda: app.eval(tab,'document.cookie') == '', timeout=10)
            app.call('wait', tab=tab)
            record('S5_cookies', cookie_before == 'f=1' and cookie_gone and app.eval(tab,'document.cookie') == '' and cache_available,
                   before=cookie_before,after=app.eval(tab,'document.cookie'),cacheAvailable=cache_available)
            s=opened(); app.call('pasteboard',text='scc-negative-sentinel')
            # F8: the product's own copy toast must be new, not just any toast state.
            copy_titles=('Copied Current URL','Copied a clean link without trackers')
            toasts_before=[t['title'] for t in app.call('toasts')['toasts'] if t['title'] in copy_titles and not t['exiting']]
            app.call('key',key='c',modifiers=['cmd','shift'],route='app')
            copied=app.call('pasteboard')
            toasts=wait(lambda:(lambda t:t if len([x for x in t['toasts'] if x['title']=='Copied Current URL' and not x['exiting']])>toasts_before.count('Copied Current URL') else None)(app.call('toasts')),timeout=3)
            record('S6_copy', len([c for c in s['controls'] if c['id'].startswith('action.')]) == 4 and not any('copy' in c['id'].lower() for c in s['controls']) and copied == origin+'/boost.html' and bool(toasts), pasteboard=copied,toasts=toasts or app.call('toasts'),toastsBefore=toasts_before,negative='sentinel replaced; no SCC Copy control; no copy toast before the key')
            close(); app.call('navigate',tab=tab,url=origin+'/ads.html'); app.call('wait',tab=tab)
            opened(); app.call('key',key='escape',route='app'); escaped = not state()['presented']
            opened(); count=app.eval(tab,'window.clicks'); app.call('mouse',action='click',x=700,y=500,queued=True)
            got=wait(lambda: app.eval(tab,'window.clicks') == count+1, timeout=5)
            record('S7_dismiss',escaped and not state()['presented'] and got,escaped=escaped,before=count,after=app.eval(tab,'window.clicks'),negative='counter unchanged before outside click')
            for key in ['l','t']:
                opened(); app.call('key',key=key,modifiers=['cmd'],route='app')
                bar=app.call('commandbar-state')
                record('S7_cmd_'+key,not state()['presented'] and bar.get('presented'),bar=bar)
                app.call('key',key='escape',route='app')
            disposable=new_tab(app,origin+'/boost.html'); opened()
            app.call('key',key='w',modifiers=['cmd'],route='app')
            gone=wait(lambda: not any(t['id']==disposable for t in app.call('tabs')),timeout=5)
            record('S7_cmd_w',gone and not state()['presented'],archived=disposable)
            app.call('select',tab=tab)
            second=new_tab(app,origin+'/boost.html'); app.call('split'); time.sleep(.2)
            s=opened('pane'); selected=app.call('window-state')['selected']
            # F8: the product refuses an anchor for a tab with no page (unknown tab ID): no panel, focus kept.
            bad=app.call('site-controls',action='deliver',what='anchor',anchor='paneBar',tab=str(uuid.uuid4()))
            bad_anchor=not bad['presented'] and app.call('window-state')['selected']==selected
            s=opened('pane')
            record('S8_split',s['presented'] and s['tab']==selected and s['host']=='127.0.0.1' and s['anchor'][0]>228 and bad_anchor,state=s,negativeRefused=bad_anchor)
            close(); app.call('split')
            app.call('menu-perform',id='toggle-toolbar')
            toolbar=opened('pane')
            # F8: with the toolbar shown the URL field is hidden; the product refuses that anchor itself.
            url_anchor=app.call('site-controls',action='deliver',what='anchor',anchor='urlField',tab=app.call('window-state')['selected'])
            record('S8_toolbar',toolbar['presented'] and toolbar['tab']==app.call('window-state')['selected']
                   and not url_anchor['presented'],state=toolbar,urlAnchorRefused=not url_anchor['presented'])
            close(); app.call('menu-perform',id='toggle-toolbar')
            app.call('menu-perform',id='toggle-sidebar')
            app.call('mouse',action='move',x=600,y=300)
            hidden=wait(lambda:not app.call('window-state')['revealed'],timeout=5)
            closed_before_reveal=not state()['presented']
            app.call('mouse',action='move',x=3,y=300)
            revealed=wait(lambda:app.call('window-state')['revealed'],timeout=5)
            floating=opened()
            record('S8_floating',hidden and closed_before_reveal and revealed and floating['presented']
                   and abs(floating['tip'][0]-floating['anchor'][0]-floating['anchor'][2]/2)<=1,state=floating,negativeClosed=closed_before_reveal,hiddenBeforeReveal=hidden)
            close();app.call('menu-perform',id='toggle-sidebar')
            opened();app.call('select',tab=tab)
            record('S7_tab_change',not state()['presented'],negative='the panel was open on the other tab before selection')
            blank=new_tab(app,'about:blank'); no_site=refused(action='open')
            internal=new_tab(app,'chrome://version'); s=opened()
            acts=[c for c in s['controls'] if c['id'].startswith('action.')]
            record('S9_empty_internal',no_site and s['presented'] and s['extensionsVisible'] and [c['id'] for c in acts if c['enabled']]==['action.share'] and not s['security'].get('visible'),state=s,negativeNoSite=no_site)
            normal_window=app.call('window-state')['id']
            normal_context=s
            normal_boost=stored_boost()
            private_windows=app.call('incognito-state')['windows']
            existing_private={w['id'] for w in private_windows if w['private']}
            app.call('menu-perform',id='new-incognito-window')
            private_window=wait(lambda:next((w for w in app.call('incognito-state')['windows']
                if w['private'] and w['id'] not in existing_private),None),timeout=5,step=.05)
            if not private_window:
                raise RuntimeError('main has private windows, but New Incognito Window did not create one')
            try:
                app.call('window-focus',id=private_window['id'],activate=True)
                private_tab=app.call('open',url=origin+'/boost.html')['id']
                app.call('wait',tab=private_tab)
                private_state=opened()
                manage_boosts=next((i for i in private_state['items'] if i['title']=='Manage Boosts…'), {})
                private_context=app.call('incognito-state',private=True)
                boost_controls=[c for c in private_state['controls'] if c['id'].startswith('boost.')]
                boost_commands=('new-boost','edit-boost','new-legacy-boost','view-boosts')
                menu_rows={r['id']:r for r in app.call('menu-state') if r['id'] in boost_commands}
                refused_commands={}
                for command in boost_commands:
                    try:
                        app.call('menu-perform',id=command)
                        refused_commands[command]=False
                    except RuntimeError:
                        refused_commands[command]=True
                private_menu_refused=refused(action='menu',item='New Boost…')
                private_customize_refused=editor('customize') is False and not editor().get('open')
                try:
                    editor('open',boost=boost_id)
                    private_editor_refused=False
                except RuntimeError:
                    private_editor_refused=True
                record('S10_incognito',private_context.get('private') is True and private_context.get('ephemeral') is True
                    and private_state['isIncognito'] is True and not normal_context['isIncognito']
                    and not private_state['canCreateBoost'] and not control(private_state,'action.newBoost')['enabled']
                    and not any(c['enabled'] for c in boost_controls)
                    and manage_boosts.get('enabled') is False
                    and private_state['urlButtonState'] not in ('boosted','openBoosted')
                    and len(menu_rows)==len(boost_commands) and all(not r['enabled'] for r in menu_rows.values())
                    and all(refused_commands.values()) and private_menu_refused
                    and private_customize_refused and private_editor_refused
                    and app.eval(private_tab,'getComputedStyle(document.body).outlineStyle')=='none'
                    and refused(action='tap',id='action.newBoost'),
                    state=private_state,privateContext=private_context,manageBoostsMenu=manage_boosts,
                    boostMenus=menu_rows,refusedCommands=refused_commands,negativeDisabledMenu=private_menu_refused,
                    negativeNormalContext=normal_context['isIncognito'],negativeDisabledTap=True,
                    customizeRefused=private_customize_refused,editorRefused=private_editor_refused)
                row_refusals={c['id']:refused(action='tap',id=c['id']) for c in boost_controls}
                # F8: deliver the same actions to the product past the disabled buttons. Its guards
                # must refuse them: no editor, no new Boost, the stored Boost unchanged.
                def boost_count(): return len(app.call('boosts',action='list',profile=boost_profile))
                count_before=boost_count()
                opened(); app.call('site-controls',action='deliver',what='action',id='newBoost')
                delivered_new=not editor().get('open') and boost_count()==count_before
                opened(); app.call('site-controls',action='deliver',what='boostEnabled',boost=boost_id,enabled=not normal_boost['isEnabled'])
                delivered_toggle=stored_boost()==normal_boost
                opened(); app.call('site-controls',action='deliver',what='boostEdit',boost=boost_id)
                delivered_edit=not editor().get('open')
                row_refusals.update(productNewBoost=delivered_new,productToggle=delivered_toggle,productEdit=delivered_edit)
                close()
                unchanged_boost=stored_boost()
                record('S10_boost_rows',private_context.get('parent')==boost_profile
                       and {c['id'] for c in boost_controls}=={circle,edit_row}
                       and all(c['visible'] and not c['enabled'] for c in boost_controls)
                       and all(row_refusals.values()) and unchanged_boost==normal_boost,
                       controls=boost_controls,refusals=row_refusals,storedUnchanged=unchanged_boost==normal_boost,
                       negativeNormalEnabled=normal_boost['isEnabled'],parent=private_context.get('parent'))
            finally:
                app.call('window-focus',id=private_window['id'],activate=True)
                app.call('menu-perform',id='close-window')
                app.call('window-focus',id=normal_window,activate=True)
            # Remove the saved fixture through its editor before pixel rows.
            app.call('select',tab=tab)
            editor('open',boost=boost_id)
            editor('tap',id='menu.Delete this Boost');editor('tap',id='alert.Delete')
            assert wait(lambda:not any(b['id']==boost_id for b in app.call('boosts',action='list',profile=boost_profile)),timeout=5,step=.02)
            if functional_only:
                for key in ['S11_material', 'S12_elements', 'S13_scroll', 'P1_first_draw', 'P2_idle']:
                    results[key]=dict(status='DEFERRED', reason='M5 display/performance receipt required (TANDEM §4M)')
                return
            # Use the same dark, white-page fixture and actual window pixels.
            app.call('permission',origin=origin,kind=1,state=1)
            app.call('select',tab=tab); app.call('navigate',tab=tab,url=origin+'/ads.html');app.call('wait',tab=tab)
            close(); closed_path=str(private/'S11-closed.png');app.call('snapshot',path=closed_path)
            s=opened();time.sleep(.4);path=str(private/'S11-open.png');app.call('snapshot',path=path)
            width,height,pixel=env['read_image'](path,srgb=True)
            win=app.call('window-state'); scale=width/win['frame'][2]
            # P4 moved from (260,250) to (300,250), same Arc target (LEAD 12:05): (260,250) sampled the first settings
            # row's title in Open ("Block Ads & Trackers" is longer than Arc's "Developer Mode"); a probe samples material.
            targets=[(88,215,(64,62,84)),(300,140,(123,123,123)),(150,330,(69,68,89)),(300,250,(122,122,123))]
            probes=[dict(point=[x,y],actual=list(pixel(x*scale,y*scale)),target=list(rgb)) for x,y,rgb in targets]
            # Exact fit probes keep ±3 sRGB levels; validation uses DE00.
            delta_e = env["chrome_delta_e"]
            for probe in probes: probe['deltaE00']=delta_e(probe['actual'],probe['target'])
            fits=all(max(abs(a-b) for a,b in zip(p['actual'],p['target']))<=3 for p in probes[:2])
            validation=all(p['deltaE00']<=3 for p in probes[2:])
            _,_,closed_pixels=env['read_image'](closed_path,srgb=True)
            closed_fit=all(max(abs(a-b) for a,b in zip(closed_pixels(x*scale,y*scale),rgb))<=3 for x,y,rgb in targets[:2])
            recorded_visual('S11_material',dict(ok=fits and validation and not closed_fit,load=load(),probes=probes,snapshot=path,negative=closed_path,negativeRejected=not closed_fit,scale=scale,state=s))
            from sitecontrol_pixels import compare_live, background_response
            recorded_visual('S12_elements',compare_live(path, s, scale, private, env,negative_path=closed_path))
            response=background_response(app,tab,private,env,scale)
            # INFO has no acceptance predicate. Keep focus loss as an interruption.
            interruptions=results.tracker.loss()
            if interruptions:
                raise env['FocusInterruption']('foreground lost during S11 R-7 diagnostic', interruptions)
            results['S11_material']['backgroundResponse']=response
            print('S11 R-7 INFO: '+json.dumps(response), flush=True)
            app.call('navigate',tab=tab,url=origin+'/heavy.html');app.call('wait',tab=tab);close()
            js='''new Promise(done=>{scrollTo(0,0);let last=0,frames=[];function tick(t){if(last)frames.push(t-last);last=t;scrollBy(0,12);if(frames.length<240)requestAnimationFrame(tick);else done(frames)}requestAnimationFrame(tick)})'''
            baseline=app.eval(tab,js);opened();shown=app.eval(tab,js)
            p95=lambda xs: sorted(xs)[int(.95*(len(xs)-1))]
            # Discover the actual refresh interval, without assuming this display is 120 Hz.
            interval=statistics.median(baseline); drops=lambda xs: sum(max(0,round(x/interval)-1) for x in xs)/len(xs)
            p0,p1=p95(baseline),p95(shown);d0,d1=drops(baseline),drops(shown)
            # Break the real page frame path, then let the bounded promise end.
            # The same acceptance predicate must reject the slow frames.
            # The broken path must exceed a frame on the actual display. A
            # fixed 12 ms workload fits inside one frame at 60 Hz.
            slow=app.eval(tab,js.replace('scrollBy(0,12);',f'scrollBy(0,12);let until=performance.now()+{interval+12};while(performance.now()<until){{}}')
                          .replace('frames.length<240','frames.length<60'))
            negative_rejected=not (p95(slow)<=p0+1 and drops(slow)<=d0+.01)
            record('S13_scroll',p1<=p0+1 and d1<=d0+.01 and negative_rejected,closedP95=p0,openP95=p1,closedDropped=d0,openDropped=d1,refreshMilliseconds=interval,
                   timing=True,functionalOK=negative_rejected,negativeRejected=negative_rejected,negativeP95=p95(slow),negativeDropped=drops(slow))
            from sitecontrol_pixels import light_and_ghost
            light_and_ghost(app, origin, private, env, record)
        finally:
            env['_restore_defaults'](app,saved)
            app.quit()
        from sitecontrol_performance import run as performance
        performance(factory, results, origin, tmp, env)
