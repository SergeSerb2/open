"""SCC acceptance through Open's real anchors, controls, menus and engine.

The fixture and its server belong to this invocation. No desktop input.
"""
from pathlib import Path
import json
import os
import statistics
import time


from sitecontrol_fixtures import fixture_server

def run(factory, results, tmp, env, functional_only=False):
    wait, new_tab = env['wait_until'], env['new_tab']
    load = lambda: list(os.getloadavg())
    with fixture_server(tmp) as origin:
        # SCC's scroll load stays local to this suite. Both Section 12 suites
        # use the same ads/Boost pages from sitecontrol_fixtures.
        (Path(tmp) / 'sitecontrol-fixtures' / 'heavy.html').write_text(
            '<!doctype html><style>body{margin:0;background:white}.card{height:70px;background:linear-gradient(90deg,#fff,#def);border-bottom:1px solid #aaa}</style>'
            + ''.join('<div class="card">%d</div>' % i for i in range(2000)),
            encoding='utf-8')
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
        def record(key, ok, **detail):
            results[key] = dict(ok=bool(ok), load=load(), **detail)
            print(key, 'PASS' if ok else 'FAIL', flush=True)
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
            s = opened()
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
                   and row(s,'row.contentBlocking').get('state') == 'unavailable'
                   and s['security'].get('title') == 'Connection: Insecure' and geometry,
                   state=s, negative=before)
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
            # Main's App ad-block adapter has not opened this profile. Never
            # count the unavailable row or a synthetic filter as a passing S2.
            if row(s,'row.contentBlocking').get('state') == 'unavailable':
                # Lead ruling: the missing Section 13 adapter is an interim
                # unavailable state. Opening Settings must not change it.
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
                settings_after=settings_file.read_bytes() if settings_file.exists() else None
                record('S1_unavailable_settings',settings['settings']>0 and settings['pane']=='advanced'
                       and row(unavailable,'row.contentBlocking').get('state')=='unavailable'
                       and action_calls=={'toggle':0,'openAdBlockSettings':1}
                       and settings_before==settings_after,settings=settings,unchanged=settings_before==settings_after,
                       sourceActionCalls=action_calls,
                       negative='opening the store in Settings does not make the missing engine adapter available')
                blocked('S2_adblock', 'section 13 ad-block adapter', row=row(unavailable,'row.contentBlocking'))
            else:
                off = app.call('site-controls', action='tap', id='row.contentBlocking')
                files = list(Path(app.user_data).glob('Profiles/*/adblock/exclusions.json'))
                persisted = any('127.0.0.1' in json.loads(p.read_text()) for p in files)
                app.call('site-controls', action='tap', id='reload'); app.call('wait', tab=tab)
                allowed = app.eval(tab,'window.fixtureAdLoaded === true')
                on = app.call('site-controls', action='tap', id='row.contentBlocking') if state()['presented'] else None
                if on is None: opened(); on = app.call('site-controls',action='tap',id='row.contentBlocking')
                app.call('site-controls', action='tap', id='reload'); app.call('wait', tab=tab)
                denied = app.eval(tab,'window.fixtureAdLoaded === true')
                record('S2_adblock', row(off,'row.contentBlocking').get('subtitle') == 'Off' and off['reloadVisible'] and persisted
                       and row(on,'row.contentBlocking').get('subtitle') == 'On' and allowed is True and denied is False,
                       off=off,on=on,allowed=allowed,blocked=denied)
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
            # Create and persist through the real editor, then exercise the
            # SCC's visible controls against the sole AppBoosts owner.
            def editor(action='state', **args): return app.call('boost-editor', action=action, **args)
            empty_boosts=opened()
            empty_negative=not empty_boosts['boostsVisible'] and not any(
                c['id'].startswith('boost.') for c in empty_boosts['controls'])
            app.call('site-controls',action='tap',id='action.newBoost')
            if editor().get('interstitial'): editor('tap',id='firstRun.makeABoost')
            assert wait(lambda:editor().get('colorsReady'),timeout=10,step=.05)
            editor('tap',id='font.Avenir')
            boost_id=editor()['boost']['id']; boost_profile=editor()['profile']
            editor('close')
            def stored_boost(): return app.call('boosts',action='get',boost=boost_id,profile=boost_profile)
            circle='boost.'+boost_id+'.circle'; edit_row='boost.'+boost_id+'.row'
            matching=opened()
            record('S4_boost',empty_negative and matching['boostsVisible']
                   and all(control(matching,c).get('visible') and control(matching,c).get('enabled') for c in (circle,edit_row))
                   and stored_boost()['isEnabled']
                   and matching['urlButtonState'] in ('boosted','openBoosted'),
                   state=matching,stored=stored_boost(),negativeEmpty=empty_negative)
            app.call('site-controls',action='tap',id=circle)
            assert wait(lambda:not stored_boost()['isEnabled'],timeout=5,step=.02)
            off=wait(lambda:(lambda x:x if x['urlButtonState'] not in ('boosted','openBoosted') else None)(state()),timeout=5,step=.02)
            off_store=stored_boost()
            app.call('site-controls',action='tap',id=circle)
            assert wait(lambda:stored_boost()['isEnabled'],timeout=5,step=.02)
            on=wait(lambda:(lambda x:x if x['urlButtonState'] in ('boosted','openBoosted') else None)(state()),timeout=5,step=.02)
            record('S4_toggle_glyph',bool(off and on) and not off_store['isEnabled'] and stored_boost()['isEnabled']
                   and all(control(x,edit_row).get('visible') for x in (off,on) if x),
                   disabled=off,reenabled=on,negativeDisabled=off_store)
            editor_closed=not editor().get('open')
            app.call('site-controls',action='tap',id=edit_row)
            edited=editor()
            record('S4_edit',editor_closed and edited.get('open') and edited['boost']['id']==boost_id,
                   editor=edited,negativeClosed=editor_closed)
            editor('close');opened()
            # boost.html shares the cookie's origin and does not set it again
            # on reload, so S5 can prove that Clear Cookies removed it.
            close(); app.call('navigate', tab=tab, url=origin+'/boost.html'); app.call('wait', tab=tab)
            cookie_before = app.eval(tab, 'document.cookie')
            s=opened(); absent_cache = not any(i['title']=='Clear Cache' for i in s['items'])
            cache_refused = refused(action='menu', item='Clear Cache')
            cleared = app.call('site-controls', action='menu', item='Clear Cookies')
            cookie_gone = wait(lambda: app.eval(tab,'document.cookie') == '', timeout=10)
            app.call('site-controls', action='tap', id='reload'); app.call('wait', tab=tab)
            record('S5_cookies', cookie_before == 'f=1' and cookie_gone and app.eval(tab,'document.cookie') == '' and absent_cache and cache_refused and cleared['reloadVisible'],before=cookie_before,after=app.eval(tab,'document.cookie'),negativeCacheRefused=cache_refused)
            s=opened(); app.call('pasteboard',text='scc-negative-sentinel')
            app.call('key',key='c',modifiers=['cmd','shift'],route='app')
            copied=app.call('pasteboard'); toasts=app.call('toasts')
            record('S6_copy', len([c for c in s['controls'] if c['id'].startswith('action.')]) == 4 and not any('copy' in c['id'].lower() for c in s['controls']) and copied == origin+'/boost.html' and bool(toasts), pasteboard=copied,toasts=toasts,negative='sentinel replaced; no SCC Copy control')
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
            bad_anchor=refused(action='open',via='invalid')
            record('S8_split',s['presented'] and s['tab']==selected and s['host']=='127.0.0.1' and s['anchor'][0]>228 and bad_anchor,state=s,negativeRefused=bad_anchor)
            close(); app.call('split')
            app.call('menu-perform',id='toggle-toolbar')
            toolbar=opened('pane')
            record('S8_toolbar',toolbar['presented'] and toolbar['tab']==app.call('window-state')['selected']
                   and refused(action='open',via='urlField'),state=toolbar)
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
                    and private_state['urlButtonState'] not in ('boosted','openBoosted')
                    and len(menu_rows)==len(boost_commands) and all(not r['enabled'] for r in menu_rows.values())
                    and all(refused_commands.values()) and private_menu_refused
                    and private_customize_refused and private_editor_refused
                    and refused(action='tap',id='action.newBoost'),
                    state=private_state,privateContext=private_context,
                    boostMenus=menu_rows,refusedCommands=refused_commands,negativeDisabledMenu=private_menu_refused,
                    negativeNormalContext=normal_context['isIncognito'],negativeDisabledTap=True,
                    customizeRefused=private_customize_refused,editorRefused=private_editor_refused)
                row_refusals={c['id']:refused(action='tap',id=c['id']) for c in boost_controls}
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
            targets=[(88,215,(64,62,84)),(300,140,(123,123,123)),(150,330,(69,68,89)),(260,250,(122,122,123))]
            probes=[dict(point=[x,y],actual=list(pixel(x*scale,y*scale)),target=list(rgb)) for x,y,rgb in targets]
            # Exact fit probes keep ±3 sRGB levels; validation uses DE00.
            delta_e = env["chrome_delta_e"]
            for probe in probes: probe['deltaE00']=delta_e(probe['actual'],probe['target'])
            fits=all(max(abs(a-b) for a,b in zip(p['actual'],p['target']))<=3 for p in probes[:2])
            validation=all(p['deltaE00']<=3 for p in probes[2:])
            _,_,closed_pixels=env['read_image'](closed_path,srgb=True)
            closed_fit=all(max(abs(a-b) for a,b in zip(closed_pixels(x*scale,y*scale),rgb))<=3 for x,y,rgb in targets[:2])
            record('S11_material',fits and validation and not closed_fit,probes=probes,snapshot=path,negative=closed_path,negativeRejected=not closed_fit,scale=scale,state=s)
            from sitecontrol_pixels import compare_live, background_response
            results['S12_elements']=compare_live(path, s, scale, private, env,negative_path=closed_path)
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
            slow=app.eval(tab,js.replace('scrollBy(0,12);','scrollBy(0,12);let until=performance.now()+12;while(performance.now()<until){}')
                          .replace('frames.length<240','frames.length<60'))
            negative_rejected=not (p95(slow)<=p0+1 and drops(slow)<=d0+.01)
            record('S13_scroll',p1<=p0+1 and d1<=d0+.01 and negative_rejected,closedP95=p0,openP95=p1,closedDropped=d0,openDropped=d1,refreshMilliseconds=interval,
                   negativeRejected=negative_rejected,negativeP95=p95(slow),negativeDropped=drops(slow))
        finally:
            env['_restore_defaults'](app,saved)
            app.quit()
        from sitecontrol_performance import run as performance
        performance(factory, results, origin, tmp, env)
