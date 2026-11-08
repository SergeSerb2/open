"""Real editor save, unchanged live document, and next document-start proof."""
import os
import traceback
from sitecontrol_fixtures import fixture_server


def run(factory, results, tmp, env):
    app = None
    saved = {}
    evidence = {}
    with fixture_server(tmp) as origin:
        try:
            app = factory(urls=(origin + '/boost-first.html',), fresh=True)
            tab = app.call('tabs')[0]['id']
            app.call('wait', tab=tab)
            for key, value in {'open.advanced.enableBoosts': True,
                               'open.advanced.restoreWindowsOnLaunch': True,
                               'open.boosts.hasDismissedInterstitial': False,
                               'open.boosts.hasDismissedJSNotice': False,
                               'open.boosts.codeEditorSize': '480x588'}.items():
                saved[key] = app.call('defaults', key=key, persistent=True)
                app.call('defaults', key=key, value=value)

            def call(action='state', **kwargs):
                return app.call('boost-editor', action=action, **kwargs)

            def tap(control):
                return call('tap', id=control)

            def code():
                assert env['wait_until'](lambda: call()['colorsReady'], timeout=10, step=.05)
                tap('code')
                assert env['wait_until'](lambda: call()['mode'] == 'code', timeout=5, step=.02)
                tap('editor.code.js')

            old = "window.boostScriptUpdateRuns=(window.boostScriptUpdateRuns||0)+1;window.boostScriptUpdateVersion='old';"
            new = old.replace("'old'", "'new'")
            call('open')
            tap('firstRun.makeABoost')
            code()
            boost_id = call()['boost']['id']
            call('type', text=old)
            assert env['wait_until'](lambda: call()['boost']['js'] == old, timeout=5, step=.02)
            call('close')
            app.quit()
            # Seed through persistence so both the positive and hook-disabled
            # negative begin with the same browser-creation script list.
            app = factory(urls=(origin + '/boost-first.html',))
            tab = app.call('tabs')[0]['id']
            app.call('wait', tab=tab)
            initial = app.eval(tab, 'window.scriptUpdateAtFirstScript')
            evidence['initialDocumentStart'] = initial
            assert initial == {'version': 'old', 'runs': 1}, 'initial document did not run the saved JS'
            call('open', boost=boost_id)
            code()
            before = call()
            before_ids = sorted(app.call('incognito-state', private=True)['boostScriptIDs'])
            css = app.eval(tab, "(() => {const s=document.getElementById('open-boosts-style');if(s)s.__scriptUpdateMarker='same-node';return s?.textContent??null})()")
            call('type', text=new)
            assert env['wait_until'](lambda: call()['boost']['js'] == new and call()['refreshToRun'], timeout=5, step=.02)
            edited = call()
            live = app.eval(tab, "({version:window.boostScriptUpdateVersion,runs:window.boostScriptUpdateRuns,css:document.getElementById('open-boosts-style')?.textContent??null,marker:document.getElementById('open-boosts-style')?.__scriptUpdateMarker??null})")
            after_ids = sorted(app.call('incognito-state', private=True)['boostScriptIDs'])
            evidence.update(liveAfterSave=live, scriptIDsBefore=before_ids, scriptIDsAfter=after_ids,
                            refreshToRun=edited['refreshToRun'], liveDeliveriesBefore=before['deliveryCount'],
                            liveDeliveriesAfter=edited['deliveryCount'])
            assert live['version'] == 'old' and live['runs'] == 1, 'JS save changed the live JS result'
            assert live['css'] == css and (css is None or live['marker'] == 'same-node'), 'JS save reapplied CSS'
            assert edited['deliveryCount'] == before['deliveryCount'] and edited['refreshCount'] == before['refreshCount'], 'JS save refreshed live pages'
            assert edited['loadedJS'] == old and before_ids != after_ids, 'script list did not change after JS save'
            evidence['hookUpdatedScriptsWithoutLiveRefresh'] = True
            tap('editor.code.run')
            app.call('wait', tab=tab)
            assert env['wait_until'](lambda: call()['loadedJS'] == new and not call()['refreshToRun'], timeout=5, step=.02)
            first = app.eval(tab, 'window.scriptUpdateAtFirstScript')
            evidence['reloadedDocumentStart'] = first
            assert first == {'version': 'new', 'runs': 1}, 'replacement renderer document-start JS mismatch: ' + str(first)
            results['B28_js_save_scripts_only'] = dict(evidence, ok=True, negative=True, load=os.getloadavg())
            print('B28_js_save_scripts_only PASS', flush=True)
        except env['FocusInterruption']:
            raise
        except Exception as error:
            results['B28_js_save_scripts_only'] = dict(evidence, ok=False, error=str(error),
                trace=traceback.format_exc()[-1400:], load=os.getloadavg())
            print('B28_js_save_scripts_only FAIL', str(error), flush=True)
        finally:
            try:
                env['_restore_defaults'](app if app and not app.closed else None, saved)
            finally:
                if app:
                    app.quit()
