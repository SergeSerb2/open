"""Incognito and cross-Profile privacy rows (bug sweep round 2, lane PRIVACY), through the real App.

Each row drives a product path that used to fail: a new tab after every tab of an Incognito window
closed (the engine had ended the private session), a site choice made in an Incognito window
(PiP "Turn off", "Never Translate This Site", Developer Mode), the published Handoff page after
focus moves to an Incognito window, a Live Calendar reminder while an Incognito window is in front,
an external mailto: link while an Incognito window is in front, and a Live Folder refresh that is
still running when its Space moves to another Profile.

Site choices made in an Incognito window must stay in memory: the regular preferences domain keeps
the value it had before the action. All fixtures are loopback servers or fixture sources.
"""
import json
import os
import subprocess
import threading
import time
from loopback_http import LoopbackHTTPServer

PREF_KEYS = ('open.pip.autoDisabledHosts', 'open.pip.keepOnTop', 'open.advanced.enablePictureInPictureOnLeave',
             'open.translate.neverTranslateHosts', 'open.translate.enabled', 'open.developer.modeHosts',
             'open.general.previewsCalendar',
             'open.liveFolders.introSeen', 'open.liveFolders.githubAutoCreate', 'open.links.externalInLittleOpen')
# Join links and the calendar Favorite never reach the network: every host but loopback resolves to NOTFOUND.
ENGINE_SWITCHES = ['--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE *.localhost, EXCLUDE 127.0.0.1',
                   '--no-proxy-server']
MEET = 'https://meet.google.com/abc-defg-hij'
CALENDAR = 'https://calendar.google.com/calendar/u/0/r/day'


def checks(factory, results, tmp, harness):
    wait = harness.wait_until
    media_server, media_port = harness._media_server()
    page_server, page_origin = harness._static_server(harness.PAGE_FIXTURES)
    from live_data import github_fixture
    gh_server, gh_port, gh = github_fixture()
    media = 'http://127.0.0.1:%d/' % media_port
    app = None; saved = {}

    def check(name, ok, **evidence): results[name] = dict(ok=bool(ok), **evidence)
    def windows(private=None):
        rows = app.call('incognito-state')['windows']
        return rows if private is None else [w for w in rows if w['private'] == private]
    def focus(window): app.call('window-focus', id=window['id'], activate=True)
    def dismiss():
        if app.call('commandbar-state').get('presented'): app.call('key', key='escape', route='app')
    def open_page(url):
        dismiss(); tab = app.call('open', url=url)['id']
        try: app.call('wait', tab=tab, timeout=30)
        except RuntimeError: pass
        def ready():
            try: return app.eval(tab, 'document.readyState') == 'complete'
            except RuntimeError: return False
        assert wait(ready, timeout=15, step=.1), 'page did not load: ' + url
        return tab
    def private_window():
        before = {w['id'] for w in windows(True)}
        app.call('menu-perform', id='new-incognito-window')
        window = wait(lambda: next((w for w in windows(True) if w['id'] not in before), None), timeout=5, step=.05)
        assert window, 'private window did not open'
        focus(window); dismiss()
        return window
    def pref(key): return app.call('defaults', key=key, persistent=True)
    only = [r for r in os.environ.get('OPEN_PRIVACY_ROWS', '').split(',') if r]
    def guarded(name, fn):
        # One row's failure (an exception) is that row's FAIL; the next rows still run.
        if only and name not in only: return
        try: fn()
        except Exception as error:
            if name not in results or results[name].get('ok'):
                evidence = {}
                try: evidence = dict(windows=app.call('incognito-state')['windows'], tabs=app.call('tabs'),
                                     front=app.call('window-state'))
                except Exception as more: evidence = dict(evidenceError=repr(more)[:200])
                results[name] = dict(ok=False, error=repr(error)[:600], **evidence)
            try: dismiss()
            except Exception: pass


    try:
        app = factory(urls=(page_origin + '/en.html',), fresh=True, extra_args=ENGINE_SWITCHES,
                      extra_env={'OPEN_AUTOMATION_TRANSLATE_BACKEND': 'fixture', 'OPEN_E2E_NO_SYSTEM_SETTINGS': '1'})
        saved = {k: pref(k) for k in PREF_KEYS}
        for k in PREF_KEYS: app.call('defaults', key=k, value=None)
        app.call('defaults', key='open.links.externalInLittleOpen', value=False)  # external links open in a window
        app.call('window-frame', frame=[80, 60, 1280, 820])
        normal = windows(False)[0]
        focus(normal)
        normal_tab = app.call('tabs')[0]['id']; app.call('wait', tab=normal_tab)
        incognito = private_window()

        # 0. Closing every tab of an Incognito window ends the engine's private session; a new tab still loads.
        def row0():
            focus(incognito)
            first = open_page(page_origin + '/en.html?last-tab')
            app.eval(first, "document.cookie='lastTab=1; path=/'; true")
            app.call('close', tab=first)
            empty = app.call('tabs')
            again = open_page(page_origin + '/en.html?after-last-tab')
            cookie = app.eval(again, 'document.cookie')
            page = app.call('tabs')[0].get('page', {})
            check('privacy_private_new_tab_after_last_closed', empty == [] and page.get('ephemeral') is True
                  and 'lastTab' not in cookie, cookie=cookie, page={k: page.get(k) for k in ('ephemeral', 'context', 'live', 'url')})
            app.call('close', tab=again)
        guarded('privacy_private_new_tab_after_last_closed', row0)

        # 1. PiP "Turn off" (Open's own PiP window, phase 2) in an Incognito window.
        def row1():
            focus(incognito)
            video = open_page(media + 'video-muted.html')
            entered = app.eval(video, '(async () => { await start(); await document.getElementById("main").requestPictureInPicture();'
                                      ' return !!document.pictureInPictureElement; })().catch(e => "error: " + e.message)')
            pip = wait(lambda: (lambda p: p if p.get('state') == 'active' and (p.get('openWindow') or {}).get('visible') else None)(app.call('pip')),
                       timeout=5, step=.05) or app.call('pip')
            if pip.get('phase') != 2:
                results['privacy_pip_turn_off_memory'] = {'status': 'BLOCKED', 'reason': 'EM-4: phase 1 shows Chromium\'s PiP window, which has no site menu', 'pip': pip}
            else:
                before = pref('open.pip.autoDisabledHosts')
                items = app.call('pip-action', action='menu')
                app.call('pip-action', action='menu', item='Turn off')
                after = pref('open.pip.autoDisabledHosts')
                items_after = app.call('pip-action', action='menu')
                check('privacy_pip_turn_off_memory', entered is True and 'Turn off' in items and after == before
                      and 'Turn off ✓' in items_after and 'Open automatically' in items_after,
                      entered=entered, before=before, after=after, items=items, itemsAfter=items_after)
                app.call('pip-action', action='close')
                wait(lambda: app.call('pip').get('state') != 'active', timeout=3, step=.05)
            app.call('close', tab=video)
            focus(incognito)
        guarded('privacy_pip_turn_off_memory', row1)

        # 2. "Never Translate This Site" in an Incognito window: this session remembers it; the regular list does not change.
        def row2():
            focus(incognito)
            def translate(): return app.call('translate', action='state')
            def offered(): return wait(lambda: (lambda s: s if s['state'] == 'offered' else None)(translate()), timeout=15, step=.1)
            fr = open_page(page_origin + '/fr.html')
            first_offer = offered()
            before = pref('open.translate.neverTranslateHosts')
            never = app.call('translate', action='never') if first_offer else {}
            after = pref('open.translate.neverTranslateHosts')
            app.call('close', tab=fr)
            again = open_page(page_origin + '/fr.html?again')
            time.sleep(1.5)
            private_again = translate()
            app.call('close', tab=again)
            focus(normal)
            regular_fr = open_page(page_origin + '/fr.html?regular')
            regular_offer = offered()
            app.call('close', tab=regular_fr)
            check('privacy_translate_never_memory', bool(first_offer) and after == before and private_again['state'] != 'offered'
                  and bool(regular_offer),
                  before=before, after=after, never=never.get('state'), privateAgain=private_again.get('state'),
                  regular=(regular_offer or {}).get('state'))
        guarded('privacy_translate_never_memory', row2)

        # 3. Developer Mode toggled in an Incognito window stays in that session.
        def row3():
            focus(incognito)
            focus(incognito)
            dev = open_page(page_origin + '/en.html?developer')
            before = pref('open.developer.modeHosts')
            app.call('command', id='toggle-developer-mode')
            private_on = wait(lambda: app.call('developer-panel').get('shown'), timeout=5, step=.05)
            after = pref('open.developer.modeHosts')
            focus(normal)
            app.call('navigate', tab=normal_tab, url=page_origin + '/en.html?developer'); app.call('wait', tab=normal_tab)
            time.sleep(.5)
            regular_panel = app.call('developer-panel').get('shown')
            focus(incognito)
            app.call('command', id='toggle-developer-mode')
            private_off = wait(lambda: app.call('developer-panel').get('shown') is False, timeout=5, step=.05)
            app.call('close', tab=dev)
            check('privacy_developer_mode_memory', bool(private_on) and after == before and regular_panel is False and bool(private_off)
                  and pref('open.developer.modeHosts') == before,
                  before=before, after=after, privateOn=private_on, regularPanel=regular_panel, privateOff=private_off)
        guarded('privacy_developer_mode_memory', row3)

        # 4. Handoff: focus moving to an Incognito window ends the regular page's activity.
        def row4():
            focus(incognito)
            private_page = open_page(page_origin + '/en.html?private-handoff')
            focus(normal)
            app.call('navigate', tab=normal_tab, url=page_origin + '/en.html?handoff'); app.call('wait', tab=normal_tab)
            published = wait(lambda: (lambda h: h if h['url'] == page_origin + '/en.html?handoff' else None)(app.call('handoff-state')),
                             timeout=5, step=.1)
            focus(incognito)
            time.sleep(1)
            after_focus = app.call('handoff-state')
            focus(normal)
            back = wait(lambda: (lambda h: h if h['url'] == page_origin + '/en.html?handoff' else None)(app.call('handoff-state')),
                        timeout=5, step=.1)
            check('privacy_handoff_private_focus', bool(published) and after_focus['published'] is False and bool(back),
                  published=published, afterFocus=after_focus, back=back)
            focus(incognito); app.call('close', tab=private_page); focus(normal)
        guarded('privacy_handoff_private_focus', row4)

        # 5. Live Calendar: the reminder never shows the meeting title in an Incognito window, and stays for a regular one.
        def row5():
            focus(normal)
            def cal(**kw): return app.call('calendar', **kw)
            fav = harness.new_tab(app, CALENDAR)
            app.call('favorite', tab=fav)
            cal(action='fixture', access='granted', events=[{'id': 'p', 'title': 'Private-check sync', 'start': 10, 'end': 40, 'url': MEET}])
            live = wait(lambda: (lambda s: s if s.get('active') and s.get('tiles') else None)(cal(action='live')), timeout=5, step=.05)
            focus(incognito)
            cal(action='clock', minutes=9)
            time.sleep(.5)
            def calendar_toasts(): return [t for t in app.call('toasts')['toasts'] if t['coalescingKey'] == 'live-calendar' and not t['exiting']]
            private_toasts = calendar_toasts()
            focus(normal)
            cal(action='clock', minutes=9.2)
            regular_toasts = wait(calendar_toasts, timeout=3, step=.05) or []
            state = cal(action='live')
            check('privacy_calendar_reminder_not_private', bool(live) and not private_toasts
                  and [t['title'] for t in regular_toasts] == ['Private-check sync']
                  and sum(r.get('event') == 'p' for r in state.get('reminders', [])) == 1,
                  privateToasts=private_toasts, regularToasts=regular_toasts, reminders=state.get('reminders'))
            cal(action='clock', minutes=0)
            app.call('close', tab=fav)
        guarded('privacy_calendar_reminder_not_private', row5)

        # 6. External mailto: while an Incognito window is in front uses the regular Profile's handler.
        def row6():
            focus(normal)
            app.call('policy', permissions='grant')
            mail_home = open_page(page_origin + '/en.html?mail-home')
            template = page_origin + '/en.html?compose=%s'
            app.eval(mail_home, 'navigator.registerProtocolHandler("mailto", %s)' % json.dumps(template))
            registered = wait(lambda: any(h['scheme'] == 'mailto' and h['default'] for h in app.call('protocol-handlers')['handlers']),
                              timeout=8, step=.1)
            focus(incognito)
            def private_tab_ids(): return sorted(t['id'] for t in app.call('incognito-state', private=True)['tabs'])
            private_tabs = private_tab_ids()
            handled = app.call('mailto-state')['handled']
            sent = subprocess.run(['/usr/bin/open', '-a', app.bundle, 'mailto:someone@example.org'], capture_output=True, text=True, timeout=15)
            mail = wait(lambda: (lambda s: s if s['handled'] > handled else None)(app.call('mailto-state')), timeout=8, step=.1) or {}
            expected = page_origin + '/en.html?compose=mailto%3Asomeone%40example.org'
            focus(normal)
            landed = wait(lambda: any(t['url'] == expected for t in app.call('tabs')), timeout=8, step=.05)
            focus(incognito)
            private_after = private_tab_ids()
            focus(normal)
            app.call('protocol-handlers', removeScheme='mailto', removeURLTemplate=template)
            check('privacy_mailto_private_front', bool(registered) and sent.returncode == 0 and mail.get('translated') == expected and bool(landed)
                  and private_after == private_tabs,
                  mail=mail, landed=bool(landed), privateTabs=[private_tabs, private_after], stderr=sent.stderr[-300:])
            for t in app.call('tabs'):
                if t['url'] in (expected, page_origin + '/en.html?mail-home'): app.call('close', tab=t['id'])
        guarded('privacy_mailto_private_front', row6)

        # 7. A Live Folder refresh still running when its Space moves to another Profile never lands in the new Profile.
        def row7():
            focus(normal)
            app.call('live-folder-origin', url='http://github.localhost:%d' % gh_port)
            gh['prs'] = {'created': [('acme/app', 12, 'Old profile PR', 'open')], 'review': [], 'approved': [], 'changes': []}
            app.call('sidebar-menu', item='Live Folders/GitHub')
            first = app.call('live-folder-state', wait=True)
            app.call('key', key='escape', route='app')  # the first-use intro card
            space_row = next(s for s in app.call('spaces') if s['focused'])
            space, old_profile = space_row['id'], space_row['profile']
            gh['prs'] = {'created': [('acme/app', 99, 'Fetched for the old Profile', 'open')], 'review': [], 'approved': [], 'changes': []}
            gate = threading.Event(); gh['fetch_gate'] = gate
            requests = len(gh['requests'])
            outcome = {}
            def refresh():
                try: outcome['value'] = app.call('live-folder-refresh', space=space)
                except Exception as error: outcome['error'] = str(error)
            worker = threading.Thread(target=refresh, daemon=True); worker.start()
            started = wait(lambda: len(gh['requests']) > requests, timeout=10, step=.05)
            moved = app.call('space-profile', space=space, profile='Privacy Work')
            app.call('alert', button='Change Profile')
            moved = moved and wait(lambda: next((s for s in app.call('spaces') if s['id'] == space), {}).get('profile') not in (None, old_profile),
                                   timeout=5, step=.05)
            gate.set(); gh['fetch_gate'] = None
            worker.join(timeout=30)
            stale = app.call('live-folder-state', space=space)
            titles = sorted(r['title'] for r in stale.get('rows', []))
            check('privacy_live_folder_profile_move', [r['title'] for r in first.get('rows', [])] == ['Old profile PR'] and bool(started)
                  and moved is True and 'value' in outcome and outcome['value'].get('outcome') is None
                  and titles == ['Old profile PR'],
                  first=[r['title'] for r in first.get('rows', [])], refresh=outcome, titles=titles, moved=moved)
            # Control: a refresh that starts after the move fetches for the new Profile and applies.
            fresh = app.call('live-folder-refresh', space=space)
            after_move = sorted(r['title'] for r in app.call('live-folder-state', space=space).get('rows', []))
            check('privacy_live_folder_after_move_applies', fresh.get('outcome') == 'success' and 'Fetched for the old Profile' in after_move,
                  refresh=fresh, titles=after_move)
        guarded('privacy_live_folder_profile_move', row7)

    finally:
        if saved: harness._restore_defaults(app, saved)
        if app: app.quit()
        for server in (media_server, page_server, gh_server):
            server.shutdown(); server.server_close()
