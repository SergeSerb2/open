"""Real Settings delete, debounce/quit, and relaunch coverage for Boost ownership."""
import os
import pathlib
import time
import traceback
from sitecontrol_fixtures import fixture_server


def run(factory, results, tmp, env):
    app = None
    saved = {}
    evidence = {}
    wait = env['wait_until']
    with fixture_server(tmp) as origin:
        try:
            app = factory(urls=(origin + '/boost.html',), fresh=True)
            for key, value in {'open.advanced.enableBoosts': True,
                               'open.boosts.hasDismissedInterstitial': False}.items():
                saved[key] = app.call('defaults', key=key, persistent=True)
                app.call('defaults', key=key, value=value)
            name = 'Boost Retire Work'
            space = app.call('space-create', title='Retire Space', profile=name)
            tab = app.call('open', url=origin + '/boost.html')['id']
            app.call('wait', tab=tab)
            def editor(action='state', **kw):
                return app.call('boost-editor', action=action, **kw)
            editor('open')
            if editor()['interstitial']:
                editor('tap', id='firstRun.makeABoost')
            assert wait(lambda: editor()['colorsReady'], timeout=10, step=.05)
            editor('tap', id='editor.color.invert')
            profile = next(p for p in app.call('profiles-shell')['profiles'] if p['name'] == name)
            directory = pathlib.Path(app.user_data) / 'Profiles' / profile['directory']
            file = directory / 'Boosts/boosts.json'
            assert wait(lambda: file.exists(), timeout=5, step=.05), 'Boost file not persisted'
            evidence['fileBeforeDelete'] = file.exists()
            # Make another native edit after persistence. This dirties the owner
            # and schedules BoostStore's actual one-second debounced write.
            before = editor()['boost'].get('textTransform')
            editor('tap', id='case')
            assert editor()['boost'].get('textTransform') != before
            evidence['dirtyNativeEdit'] = True
            assert app.call('space-profile', space=space, profile='Default')
            if next(p for p in app.call('profiles-shell')['profiles'] if p['id'] == profile['id'])['spaces']:
                app.call('alert', button='Change Profile')
            assert wait(lambda: next(p for p in app.call('profiles-shell')['profiles'] if p['id'] == profile['id'])['spaces'] == 0,
                        timeout=5, step=.05)
            app.call('profiles-shell', action='show', profile=name)
            time.sleep(.15) # Let Settings install its real SwiftUI accessibility controls.
            app.call('profiles-shell', action='press', label='Delete Profile')
            assert wait(lambda: app.call('profiles-shell')['sheet'] > 0, timeout=5, step=.05)
            app.call('profiles-shell', action='type-delete', text=name)
            assert app.call('profiles-shell')['deleteEnabled']
            app.call('profiles-shell', action='press', label='Delete')
            assert wait(lambda: not app.call('profiles-shell')['deleting'] and app.call('profiles-shell')['sheet'] == 0,
                        timeout=30, step=.05)
            evidence['modelGone'] = not any(p['id'] == profile['id'] for p in app.call('profiles-shell')['profiles'])
            evidence['directoryGoneImmediately'] = not directory.exists()
            evidence['editorClosed'] = not editor().get('open', False)
            # Observe beyond the configured debounce, then the real quit save.
            time.sleep(1.2)
            evidence['directoryGoneAfterDebounce'] = not directory.exists()
            app.quit()
            evidence['directoryGoneAfterQuit'] = not directory.exists()
            evidence['boostFileAfterQuit'] = file.exists()
            app = factory(urls=())
            evidence['modelGoneAfterRelaunch'] = not any(p['id'] == profile['id'] for p in app.call('profiles-shell')['profiles'])
            evidence['directoryGoneAfterRelaunch'] = not directory.exists()
            evidence['boostFileAfterRelaunch'] = file.exists()
            positive = all(evidence[k] for k in ('modelGone', 'directoryGoneImmediately', 'editorClosed',
                           'directoryGoneAfterDebounce', 'directoryGoneAfterQuit', 'modelGoneAfterRelaunch',
                           'directoryGoneAfterRelaunch')) and not evidence['boostFileAfterQuit'] and not evidence['boostFileAfterRelaunch']
            results['B27_deleted_profile_not_recreated'] = dict(evidence, ok=positive,
                negative=evidence['fileBeforeDelete'] and evidence['dirtyNativeEdit'], load=os.getloadavg())
        except env['FocusInterruption']:
            raise
        except Exception as error:
            results['B27_deleted_profile_not_recreated'] = dict(evidence, ok=False, error=str(error),
                trace=traceback.format_exc()[-1500:], load=os.getloadavg())
        finally:
            if app and not app.closed:
                try:
                    try:
                        app.call('profiles-shell', action='cancel')
                    finally:
                        env['_restore_defaults'](app, saved)
                finally:
                    app.quit()
            elif saved:
                env['_restore_defaults'](None, saved)
