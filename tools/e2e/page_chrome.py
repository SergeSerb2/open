"""S11 real-App dialogs and permissions. Imported by engine_e2e.py.

Every assertion uses a loopback page, native AppKit state/buttons, and the
production automation socket. No fake engine requests or desktop input.
"""
import json
import os
import shutil
import time
import traceback
from pathlib import Path


def run(factory, results, tmp, h):
    wait, server_fn = h['wait_until'], h['_fixture_server']
    server, origin = server_fn('Page chrome')
    app = factory(urls=(origin + '/start',), fresh=True,
                  extra_env={'OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION': 'record'},
                  extra_args=['--host-resolver-rules=MAP *.localhost 127.0.0.1'])
    saved = {}
    tab = None

    def ds(): return app.call('dialog-state')
    def ps(): return app.call('permission-prompt')
    def check(value, **evidence): return dict(ok=bool(value), **evidence)
    def visible(state):
        value = wait(lambda: (lambda s: s if s.get('visible') else None)(state()), timeout=5, step=.02)
        assert value, state()
        return value
    def page(url=None):
        nonlocal tab
        tab = app.call('open', url=url or origin + '/case?' + str(time.time_ns()))['id']
        app.call('wait', tab=tab); app.call('focus', tab=tab)
        return tab
    def schedule(js, target=None):
        return app.eval(target or tab, 'window.outcome="pending";setTimeout(()=>{window.outcome=(' + js + ');},50);true')
    def answer(accepted=True, text=None, suppress=False):
        assert app.call('dialog-button', accept=accepted, text=text, suppress=suppress), ds()
        assert wait(lambda: ds()['pending'] == 0, timeout=3, step=.02), ds()
    def value(): return app.eval(tab, 'window.outcome', timeout=3)
    def perm(kind='notifications', target=None):
        js = {'notifications': 'Notification.requestPermission()',
              'midi': 'navigator.requestMIDIAccess({sysex:true}).then(()=>"granted",()=>"denied")',
              'clipboard': 'navigator.clipboard.readText().then(()=>"granted",()=>"denied")'}[kind]
        app.eval(target or tab, 'window.permissionResult="pending";' + js + '.then(v=>window.permissionResult=v);true')
    def cleanup():
        h['_try'](lambda: app.call('dismiss'))
        # No evaluation of a renderer blocked in a held dialog.
        for _ in range(32):
            if not ds()['pending']: break
            app.call('dialog', accept=False)
        if ps()['visible']: app.call('permission-prompt', answer='notnow')
        app.call('policy', dialogs='dismiss', permissions='deny')
        for t in app.call('tabs'):
            try:
                app.eval(t['id'], 'onbeforeunload=null;true', timeout=1)
            except Exception: pass
        app.call('policy', dialogs='', permissions='')
        if app.call('commandbar-state').get('presented'): app.call('key', key='escape')
    only = set(filter(None, os.environ.get('OPEN_E2E_PAGE_CHROME_ONLY', '').split(',')))
    def gate(name, fn):
        if only and name not in only: return
        try:
            cleanup()
            results[name] = fn()
        except h['FocusInterruption']:
            raise
        except Exception as error:
            results[name] = {'ok': False, 'error': str(error), 'trace': traceback.format_exc()[-900:]}
        finally:
            cleanup()
        print(name + (' PASS' if results[name].get('ok') else ' FAIL'), flush=True)
        if not results[name].get('ok'): print(json.dumps(results[name],ensure_ascii=False),flush=True)

    try:
        keys = ['open.advanced.showFullURLWithToolbar']
        for key in keys:
            saved[key] = app.call('defaults', key=key)
            app.call('defaults', key=key, value=None)
        app.call('window-frame', frame=[80, 60, 1100, 760])

        def script_batch():
            # Bug sweep r4 PERF-02: one replace of K user scripts rescanned the whole script list for
            # every script, in the browser process and again in each renderer (O(K^2) on both main
            # threads; Ad Block installs up to ~15,000). The later of two scripts with one ID still
            # wins and moves last. Runs first, with only the launch tab open, so the broadcast is
            # bounded and no later row shares a busy renderer (review r1 item 2).
            live = app.call('tabs')[0]['id']
            app.call('wait', tab=live)
            batch = app.call('script-batch', count=20000, timeout=300)
            started = time.monotonic()
            try:
                answered = app.eval(live, '1 + 1', timeout=30) == 2
            except Exception as error:
                answered = False
            renderer = (time.monotonic() - started) * 1000
            return check(batch['count'] == 20000 and batch['last'] == '0' and batch['lastSource'] == 'void 1'
                         and batch['remaining'] == 0 and batch['milliseconds'] < 1000 and answered and renderer < 1000,
                         batch=batch, rendererMilliseconds=renderer, answered=answered)
        gate('user_script_batch_linear', script_batch)
        for name, script, accepted, text, expected, kind in [
            ('alert', '(alert("page message"),"done")', True, None, 'done', 0),
            ('confirm_ok', 'confirm("page message")', True, None, True, 1),
            ('confirm_cancel', 'confirm("page message")', False, None, False, 1),
            ('prompt_ok', 'prompt("page message","seed")', True, 'typed response', 'typed response', 2),
            ('prompt_cancel', 'prompt("page message","seed")', False, None, None, 2)]:
            def replies(script=script, accepted=accepted, text=text, expected=expected, kind=kind):
                page(); schedule(script); state = visible(ds)
                if os.environ.get('OPEN_E2E_PAGE_CHROME_EARLY_FAILURE') == '1':
                    raise RuntimeError('intentional failure with a visible sheet')
                if kind in [0,2] and accepted:
                    app.call('snapshot',path=str(Path(tmp)/('dialog-'+str(kind)+'.png')),window=state['window'])
                answer(accepted, text)
                actual = value()
                return check(actual == expected and state['title'] == '127.0.0.1 says'
                             and state['buttons'] == (['OK'] if kind == 0 else ['OK', 'Cancel'])
                             and state['kind'] == kind and state['message'] == 'page message'
                             and not state['suppressible'], state=state, result=actual)
            gate('dialog_' + name, replies)
            if os.environ.get('OPEN_E2E_PAGE_CHROME_EARLY_FAILURE') == '1': return

        for scheme in ['data', 'file']:
            def opaque(scheme=scheme):
                path = Path(tmp) / 'dialog.html'; path.write_text('<title>Opaque fixture</title>')
                page('data:text/html,<title>Opaque fixture</title>' if scheme == 'data' else path.as_uri())
                schedule('(alert("opaque"),true)'); state = visible(ds); answer()
                return check(state['title'] == 'This page says' and value() is True, title=state['title'])
            gate('dialog_title_' + scheme, opaque)

        def unicode_title():
            page(origin.replace('127.0.0.1', 'www.xn--bcher-kva.localhost') + '/unicode')
            schedule('(alert("unicode"),true)'); state = visible(ds); answer()
            return check(state['title'] == 'www.bücher.localhost says', title=state['title'])
        gate('dialog_title_unicode_www', unicode_title)

        def suppression():
            page(); schedule('(alert("first"),true)'); first = visible(ds); answer()
            schedule('confirm("second")'); second = visible(ds); answer(suppress=True)
            app.call('events'); schedule('[confirm("third"),prompt("fourth","seed"),(alert("fifth"),true)]')
            done = wait(lambda: ds()['pending'] == 0, timeout=2, step=.02)
            # A broken suppression path holds the renderer: check UI before eval.
            time.sleep(.15)
            events = [e for e in app.call('events') if e.get('suppressed')]
            actual = value() if not ds()['pending'] else 'blocked'
            return check(not first['suppressible'] and second['suppressible'] and done
                         and second['suppressionTitle'] == "Don't show this again"
                         and actual == [False, None, True] and len(events) == 3,
                         first=first, second=second, result=actual, suppressed=len(events))
        gate('dialog_suppression', suppression)

        def suppression_reset():
            page(); schedule('(alert("first"),true)'); visible(ds); answer()
            schedule('(alert("second"),true)'); visible(ds); answer(suppress=True)
            app.call('devtools', tab=tab, method='Page.reload'); app.call('wait', tab=tab)
            schedule('(alert("after reload"),true)'); state = visible(ds); answer()
            return check(not state['suppressible'] and value() is True, state=state)
        gate('dialog_suppression_reload_reset', suppression_reset)

        def navigation_reset():
            page(); schedule('(alert("first"),true)'); visible(ds); answer()
            schedule('(alert("second"),true)'); visible(ds); answer(suppress=True)
            app.call('events')
            app.eval(tab,'history.pushState({},"","#same-document");setTimeout(()=>{alert("same document");window.sameDone=true},50);true')
            time.sleep(.15)
            same=[e for e in app.call('events') if e.get('suppressed')]
            if ds()['pending']: return check(False,reason='same-document navigation reset suppression')
            assert app.eval(tab,'sameDone') is True
            app.call('navigate',tab=tab,url=origin+'/new-document'); app.call('wait',tab=tab)
            schedule('(alert("new document"),true)'); state=visible(ds); answer()
            return check(len(same)==1 and not state['suppressible'],sameSuppressed=len(same),state=state)
        gate('dialog_suppression_navigation_scope', navigation_reset)

        def background():
            target = page(); other = page(); app.call('events')
            schedule('confirm("background")', target)
            wait(lambda:ds()['pending']==1,timeout=5,step=.02)
            state = ds(); queued = app.call('events')
            app.call('select', tab=target); shown = visible(ds); answer(False)
            actual = app.eval(target, 'outcome')
            return check(not state['visible'] and (state['pending'] == 0 or state['queued'])
                         and actual is False,
                         waiting=state, shown=shown, other=other)
        gate('dialog_background_select', background)

        def close_pending():
            target = page(); app.call('policy', dialogs='hold'); schedule('confirm("close held")')
            assert wait(lambda: ds()['pending'] == 1, timeout=3, step=.02)
            app.call('events'); app.call('close', tab=target)
            gone = wait(lambda: ds()['pending'] == 0, timeout=3, step=.02)
            answers = [e for e in app.call('events') if e['type'] == 'dialogAnswer']
            return check(gone and sum(e['tab'] == target for e in answers) == 1
                         and all(e['accepted'] is False for e in answers) and all(t['id'] != target for t in app.call('tabs')), answers=answers)
        gate('dialog_close_once', close_pending)

        for policy in ['accept', 'dismiss', 'hold']:
            def policies(policy=policy):
                page(); app.call('policy', dialogs=policy, prompt='policy text')
                if policy == 'hold':
                    schedule('confirm("held")')
                    assert wait(lambda: ds()['pending'] == 1, timeout=3, step=.02)
                    hidden = not ds()['visible']; app.call('dialog', accept=False)
                    return check(hidden and value() is False)
                actual = app.eval(tab, '[confirm("policy"),prompt("policy","seed")]')
                return check(actual == ([True, 'policy text'] if policy == 'accept' else [False, None]) and not ds()['pending'], result=actual)
            gate('dialog_policy_' + policy, policies)

        for name in ['message', 'prompt']:
            def truncation(name=name):
                checks = []
                for kind in (['alert', 'confirm', 'prompt'] if name == 'message' else ['prompt']):
                    # Chromium caps message characters before the callback, without a mark.
                    # Multibyte text stays below that character cap but exceeds our byte cap.
                    samples = [
                        ('at', 'x' * 10240, 'x' * 10240),
                        ('over', 'x' + 'é' * 5120, 'x' + 'é' * 5118 + '…'),
                        ('multibyte', 'x' * 10235 + '😀' * 8, 'x' * 10235 + '…')]
                    if name == 'message': samples.append(('upstream', 'x' * 10241, 'x' * 10240))
                    for boundary, source, expected in samples:
                        page()
                        message = source if name == 'message' else 'bounded prompt'
                        default = source if name == 'prompt' else 'seed'
                        js = kind + '(' + json.dumps(message)
                        if kind == 'prompt': js += ',' + json.dumps(default)
                        js += ')'
                        if kind == 'alert': js = '(' + js + ',"done")'
                        app.call('events'); schedule(js)
                        state = wait(lambda: (lambda s: s if s.get('visible') else None)(ds()), timeout=5, step=.02)
                        if not state:
                            refusals = [e for e in app.call('events') if e['type'] == 'pageChromeRefused']
                            checks.append(dict(kind=kind, boundary=boundary, sourceBytes=len(source.encode()),
                                               ok=False, visible=False, refusals=refusals))
                            continue
                        shown = state['informativeText'] if name == 'message' else state['text']
                        # Press the real OK button without replacing the default field.
                        answer()
                        actual = value()
                        reply = 'done' if kind == 'alert' else True if kind == 'confirm' else expected if name == 'prompt' else 'seed'
                        checks.append(dict(kind=kind, boundary=boundary, sourceBytes=len(source.encode()),
                            receivedBytes=state['sourceMessageBytes' if name == 'message' else 'sourcePromptBytes'],
                            shownBytes=len(shown.encode()), shownTail=shown[-8:], visible=state['visible'],
                            ok=shown == expected and len(shown.encode()) <= 10240 and actual == reply))
                return check(all(c['ok'] for c in checks), cases=checks)
            gate('dialog_' + name + '_limit', truncation)

        def prompt_keys():
            page(); schedule('prompt("native prompt","seed")'); state = visible(ds)
            app.call('key', text='replacement', window=state['window']); app.call('key', key='return', window=state['window'])
            closed = wait(lambda: ds()['pending'] == 0, timeout=2, step=.02)
            return check(closed and value() == 'replacement', state=state)
        gate('dialog_prompt_native_return', prompt_keys)

        for pressed in ['return','escape']:
            def alert_key(pressed=pressed):
                page(); schedule('(alert("native alert"),"done")'); state=visible(ds)
                app.call('key',key=pressed,window=state['window'])
                closed=wait(lambda:ds()['pending']==0,timeout=2,step=.02)
                return check(closed and value()=='done',state=state)
            gate('dialog_alert_native_'+pressed,alert_key)

        def sheet_keys():
            page(); schedule('confirm("native sheet")'); state = visible(ds)
            before = {t['id'] for t in app.call('tabs')}
            blocked = []
            for letter in ['w', 't', 'l']:
                app.call('key', key=letter, modifiers=['cmd'], window=state['window'])
                blocked.append(ds()['pending'] == 1 and not app.call('commandbar-state').get('presented',False)
                               and {t['id'] for t in app.call('tabs')} == before)
            app.call('key', key='escape', window=state['window'])
            closed = wait(lambda: ds()['pending'] == 0, timeout=2, step=.02)
            return check(all(blocked) and closed and value() is False, blocked=blocked)
        gate('dialog_sheet_native_keys', sheet_keys)

        def unload(reload=False):
            target = page(); app.eval(target, 'onbeforeunload=e=>{e.preventDefault();e.returnValue="unsaved"};true')
            # Runtime.evaluate is sent with userGesture; a real click also gives
            # Chromium its sticky activation for the beforeunload contract.
            app.eval(target, 'document.body.innerHTML="<button id=activate>Activate</button>";true')
            app.call('click', tab=target, selector='#activate')
            assert wait(lambda: app.call('engine-sleep', tab=target)['unloadHandlers'], timeout=3, step=.02)
            before = app.call('host-counts')['created']
            if reload: app.call('devtools', tab=target, method='Page.reload')
            else: app.call('key', key='w', modifiers=['cmd'])
            state = visible(ds); answer(False)
            stays = any(t['id'] == target for t in app.call('tabs')) and app.call('host-counts')['created'] == before
            app.eval(target, 'document.title="Stayed";true')
            if reload: app.call('devtools', tab=target, method='Page.reload')
            else: app.call('key', key='w', modifiers=['cmd'])
            visible(ds); answer()
            completes = wait(lambda: app.eval(target, 'document.title') != 'Stayed', timeout=3, step=.02) if reload else wait(lambda: all(t['id'] != target for t in app.call('tabs')), timeout=3, step=.02)
            return check(state['title'] == ('Reload site?' if reload else 'Leave site?') and state['buttons'] == ['OK','Cancel']
                         and state['informativeText'] == 'Changes you made may not be saved.' and not state['suppressible'] and stays and completes, state=state, keptHost=stays)
        gate('dialog_beforeunload_close', unload)
        gate('dialog_beforeunload_reload', lambda: unload(True))

        def quit_cancel_identity():
            page(); app.eval(tab,'document.title="Quit survivor";document.body.innerHTML="<button id=arm>Arm</button>";document.querySelector("#arm").onclick=()=>{onbeforeunload=e=>{e.preventDefault();e.returnValue="unsaved"}};true')
            app.call('click',tab=tab,selector='#arm')
            assert wait(lambda:app.call('engine-sleep',tab=tab)['unloadHandlers'],timeout=3,step=.02)
            app.call('quit'); state=visible(ds); answer(False)
            return check(state['title']=='Leave site?' and app.call('ping')['pid']==app.pid
                         and app.eval(tab,'document.title')=='Quit survivor',state=state)
        gate('dialog_quit_cancel',quit_cancel_identity)

        def arm(target):
            # A real click gives Chromium the sticky activation its beforeunload contract needs.
            app.eval(target,'document.body.innerHTML="<button id=arm>Arm</button>";document.querySelector("#arm").onclick=()=>{onbeforeunload=e=>{e.preventDefault();e.returnValue="unsaved"}};true')
            app.call('click',tab=target,selector='#arm')
            assert wait(lambda:app.call('engine-sleep',tab=target)['unloadHandlers'],timeout=3,step=.02)
        def alive():
            try: return app.call('ping')['pid']==app.pid
            except Exception: return False

        def background_close():
            # WC-03: closing a background tab whose beforeunload asks must show that tab and its
            # sheet; it used to queue an invisible sheet and leave the renderer blocked.
            target = page(); arm(target); other = page()
            app.call('close', tab=target)
            state = visible(ds); shown = app.call('window-state')['selected']
            answer(False)
            stays = any(t['id'] == target for t in app.call('tabs'))
            app.call('select', tab=other); app.call('close', tab=target)
            visible(ds); answer()
            gone = wait(lambda: all(t['id'] != target for t in app.call('tabs')), timeout=3, step=.02)
            return check(state['title'] == 'Leave site?' and shown == target and stays and gone,
                         state=state, shown=shown, target=target, stays=stays, gone=bool(gone))
        gate('dialog_beforeunload_background_close', background_close)

        def quit_with_pending_dialog():
            # WC-02: a page that asks beforeunload and also has an open dialog must not let Quit
            # skip its beforeunload (the App used to terminate at once).
            page(); arm(tab)
            app.call('policy', dialogs='hold'); schedule('confirm("held during quit")')
            assert wait(lambda: ds()['pending'] == 1, timeout=3, step=.02), ds()
            app.call('quit'); time.sleep(1.5)
            survived = alive()
            if not survived: return check(False, survived=False)
            app.call('dialog', accept=False); app.call('policy', dialogs='')
            assert wait(lambda: ds()['pending'] == 0, timeout=3, step=.02), ds()
            # The refused quit must not leave the preflight stuck: the next Quit asks again.
            app.call('quit'); state = visible(ds); answer(False)
            return check(state['title'] == 'Leave site?' and alive(), survived=survived, state=state)
        gate('dialog_quit_pending_dialog', quit_with_pending_dialog)

        def close_with_pending_dialog():
            # #645 review: closing a tab that asks beforeunload while it shows a dialog keeps the
            # tab (the close used to skip beforeunload); after the answer, the close asks.
            target = page(); arm(target)
            app.call('policy', dialogs='hold'); schedule('confirm("held during close")')
            assert wait(lambda: ds()['pending'] == 1, timeout=3, step=.02), ds()
            app.call('close', tab=target); time.sleep(.5)
            kept = any(t['id'] == target for t in app.call('tabs'))
            app.call('dialog', accept=False); app.call('policy', dialogs='')
            assert wait(lambda: ds()['pending'] == 0, timeout=3, step=.02), ds()
            app.call('close', tab=target); state = visible(ds); answer()
            gone = wait(lambda: all(t['id'] != target for t in app.call('tabs')), timeout=3, step=.02)
            return check(kept and state['title'] == 'Leave site?' and gone, kept=kept, state=state)
        gate('dialog_close_pending_dialog', close_with_pending_dialog)

        def tab_row(target): return next((t for t in app.call('tabs') if t['id'] == target), {})
        def bulk_archive():
            # Bug sweep r6 P-01: a bulk archive (here Archive Tabs Above) force-closed a page with a
            # beforeunload handler, with no prompt. Each such page asks now; "Stay" keeps every tab
            # of the action; "Leave" archives them all and keeps the user's own selection.
            low = page(); target = page(); arm(target); top = page()
            app.call('select', tab=low)
            app.call('sidebar-menu', node=low, item='Archive Tabs Above', alternate=True)
            state = visible(ds); shown = app.call('window-state')['selected']
            answer(False)
            ids = {t['id'] for t in app.call('tabs')}
            kept = target in ids and top in ids and tab_row(target).get('loaded')
            app.call('select', tab=low)
            app.call('sidebar-menu', node=low, item='Archive Tabs Above', alternate=True)
            visible(ds); answer()
            gone = wait(lambda: (lambda ids: target not in ids and top not in ids)({t['id'] for t in app.call('tabs')}), timeout=3, step=.02)
            selected = app.call('window-state')['selected']
            return check(state['title'] == 'Leave site?' and shown == target and kept and gone and selected == low,
                         state=state, shown=shown, target=target, kept=kept, gone=bool(gone), selected=selected, low=low)
        gate('dialog_beforeunload_bulk_archive', bulk_archive)

        def bulk_archive_leave_then_stay():
            # Bug sweep r6 P-01, lead ruling (b): pages ask in turn. "Leave" on the first and "Stay"
            # on the second cancels the action: both tabs stay. The first page has closed; its tab
            # wakes from the back list stored before it asked.
            assert wait(lambda: app.call('sleep-state').get('started'), timeout=10, step=.1)
            low = page(); second = page(); arm(second)
            first = page(); app.call('navigate', tab=first, url=origin + '/leave-b?' + str(time.time_ns())); app.call('wait', tab=first); arm(first)
            app.call('select', tab=low)
            app.call('sidebar-menu', node=low, item='Archive Tabs Above', alternate=True)
            asked_first = visible(ds); shown_first = app.call('window-state')['selected']; answer()
            asked_second = visible(ds); shown_second = app.call('window-state')['selected']; answer(False)
            ids = {t['id'] for t in app.call('tabs')}
            kept = first in ids and second in ids
            first_closed = not tab_row(first).get('loaded')
            app.call('select', tab=first)
            woke = wait(lambda: (lambda t: t if t.get('loaded') and not t.get('loading') else None)(tab_row(first)), timeout=8, step=.05) or {}
            length = app.eval(first, 'history.length') if woke.get('loaded') else 0
            return check(asked_first['title'] == 'Leave site?' and asked_second['title'] == 'Leave site?'
                         and shown_first == first and shown_second == second and kept and first_closed and length >= 2,
                         titles=[asked_first['title'], asked_second['title']],
                         shownFirst=shown_first, shownSecond=shown_second, first=first, second=second,
                         kept=kept, firstClosed=first_closed, historyLength=length)
        gate('dialog_beforeunload_bulk_leave_then_stay', bulk_archive_leave_then_stay)

        def folder_delete():
            # Bug sweep r6 P-01: Delete Folder confirms first; the page in it then asks on the next
            # turn, after the confirmation sheet ended. "Stay" keeps the folder and the tab.
            inner = page(); arm(inner); other = page()
            folder = app.call('folder', tabs=[inner], title='Unload folder')
            app.call('select', tab=other)
            app.call('sidebar-menu', node=folder, item='Delete')
            assert wait(lambda: h['_try'](lambda: app.call('alert', button='Delete Folder')) is not None, timeout=3, step=.05)
            state = visible(ds); answer(False)
            kept = any(t['id'] == inner for t in app.call('tabs'))
            app.call('select', tab=other)
            app.call('sidebar-menu', node=folder, item='Delete')
            assert wait(lambda: h['_try'](lambda: app.call('alert', button='Delete Folder')) is not None, timeout=3, step=.05)
            visible(ds); answer()
            gone = wait(lambda: all(t['id'] != inner for t in app.call('tabs')), timeout=3, step=.02)
            return check(state['title'] == 'Leave site?' and kept and bool(gone), state=state, kept=kept, gone=bool(gone))
        gate('dialog_beforeunload_folder_delete', folder_delete)

        def pinned_folder_unload():
            # Review r1 #2: Unload ("−") of a pinned folder whose only loaded page asks, while that
            # page is selected. After "Leave" the page stays unloaded and the selection leaves the
            # folder; it used to load the page again at once.
            other = page(); inner = page(); arm(inner)
            folder = app.call('folder', tabs=[inner], section='pinned', title='Pinned unload')
            app.call('select', tab=inner)
            assert wait(lambda: app.call('window-state')['selected'] == inner, timeout=3, step=.02)
            app.call('sidebar-unload', folder=folder)
            state = visible(ds); answer()
            left = wait(lambda: app.call('window-state')['selected'] != inner and not tab_row(inner).get('loaded'), timeout=3, step=.02)
            time.sleep(1.0)
            stays_unloaded = not tab_row(inner).get('loaded') and app.call('window-state')['selected'] != inner
            return check(state['title'] == 'Leave site?' and bool(left) and stays_unloaded,
                         state=state, left=bool(left), staysUnloaded=stays_unloaded, tab=tab_row(inner), selected=app.call('window-state')['selected'])
        gate('dialog_beforeunload_pinned_folder_unload', pinned_folder_unload)


        def window_close():
            # Bug sweep r6 WL-04: closing a window (its close button, Close Window) destroyed its
            # pages without beforeunload; a Blank Window loses its tabs with it. "Stay" keeps the
            # window; "Leave" closes it.
            def windows(): return len(app.call('shell-windows'))
            before = windows()
            app.call('key', key='n', modifiers=['control', 'command'], route='app')
            assert wait(lambda: windows() == before + 1, timeout=8, step=.1), app.call('shell-windows')
            try:
                if app.call('commandbar-state').get('presented'): app.call('key', key='escape', route='app')
                target = page(); arm(target)
                app.call('window-close'); state = visible(ds); answer(False)
                stays = windows() == before + 1 and any(t['id'] == target for t in app.call('tabs'))
                app.call('window-close'); visible(ds); answer()
                closed = wait(lambda: windows() == before, timeout=5, step=.05)
                return check(state['title'] == 'Leave site?' and stays and bool(closed), state=state, stays=stays, closed=bool(closed))
            finally:
                if windows() > before:
                    app.call('policy', dialogs='accept'); app.call('window-close')
                    wait(lambda: windows() == before, timeout=5, step=.05); app.call('policy', dialogs='')
        gate('dialog_beforeunload_window_close', window_close)

        def cache_keeps_unload_page():
            # Bug sweep r6 V-01: the 8-page hidden-page cache force-closed a background page with a
            # beforeunload handler (no prompt; its input was lost). Such a page stays past the cap.
            # Liveness is read from the tab list: an eval of an evicted tab would make a new page.
            target = page(); arm(target); app.eval(target, 'window.keptMarker=42;true')
            for _ in range(10): page()
            loaded = tab_row(target).get('loaded')
            marker = app.eval(target, 'window.keptMarker') if loaded else None
            return check(loaded and marker == 42, loaded=loaded, marker=marker)
        gate('cache_keeps_beforeunload_page', cache_keeps_unload_page)

        def incognito(fn):
            # Runs `fn` in a new Incognito window, then closes that window (its pages agree).
            def windows(): return len(app.call('shell-windows'))
            before = windows()
            app.call('menu-perform', id='new-incognito-window')
            assert wait(lambda: windows() == before + 1, timeout=8, step=.1), app.call('shell-windows')
            try:
                if app.call('commandbar-state').get('presented'): app.call('key', key='escape', route='app')
                return fn()
            finally:
                if windows() > before:
                    app.call('policy', dialogs='accept'); app.call('window-close')
                    wait(lambda: windows() == before, timeout=5, step=.05); app.call('policy', dialogs='')
        # Review r1 #3: an Incognito window's hidden-page cache keeps a page that asks beforeunload.
        gate('incognito_cache_keeps_beforeunload_page', lambda: incognito(cache_keeps_unload_page))

        def incognito_bulk_archive():
            # Review r1 #4: an Incognito window's bulk close (a selection's Close Tabs) asks first too.
            low = page(); target = page(); arm(target); top = page()
            def close_both():
                app.call('select', tab=low)
                app.call('sidebar-click', node=target); app.call('sidebar-click', node=top, modifiers=['cmd'])
                assert set(app.call('selection')) == {target, top}, app.call('selection')
                app.call('sidebar-menu', node=top, item='Close Tabs')
            close_both()
            state = visible(ds); answer(False)
            ids = {t['id'] for t in app.call('tabs')}
            kept = target in ids and top in ids
            close_both()
            visible(ds); answer()
            gone = wait(lambda: (lambda ids: target not in ids and top not in ids)({t['id'] for t in app.call('tabs')}), timeout=3, step=.02)
            return check(state['title'] == 'Leave site?' and kept and bool(gone), state=state, kept=kept, gone=bool(gone))
        gate('incognito_bulk_archive_asks', lambda: incognito(incognito_bulk_archive))

        def wake_after_cache_close():
            # Bug sweep r6 V-03: a page closed outside sleep (here by the hidden-page cache) woke from
            # an older stored back list, so its newer navigation was lost. The stored row follows the
            # page's own list now. The tab is selected again at once, without a wait.
            assert wait(lambda: app.call('sleep-state').get('started'), timeout=10, step=.1)
            stamp = str(time.time_ns())
            first, second, third = (origin + '/v3-' + n + '?' + stamp for n in 'abc')
            def sleep_tab(t): return app.call('sleep-state', tab=t)['tabs'][0]
            try:
                target = page(first)
                app.call('navigate', tab=target, url=second); app.call('wait', tab=target)
                page()
                app.call('sleep-clock', advance=15.0); app.call('sleep-now', tab=target)
                app.call('sleep-clock', advance=86400.0); app.call('sleep-tick')
                assert wait(lambda: (lambda t: not t['content'] and t['hosts'] == 0)(sleep_tab(target)), timeout=8, step=.1), sleep_tab(target)
                app.call('sleep-clock', reset=True)
                app.call('select', tab=target)
                assert wait(lambda: (lambda t: t.get('loaded') and t.get('url') == second and not t.get('loading'))(tab_row(target)), timeout=8, step=.05), tab_row(target)
                app.call('navigate', tab=target, url=third); app.call('wait', tab=target)
                for _ in range(10): page()
                evicted = not tab_row(target).get('loaded')
                app.call('select', tab=target)
                woke = wait(lambda: (lambda t: t if t.get('loaded') and not t.get('loading') else None)(tab_row(target)), timeout=8, step=.05) or tab_row(target)
                href = app.eval(target, 'location.href') if woke.get('loaded') else ''
                length = app.eval(target, 'history.length') if woke.get('loaded') else 0
                return check(evicted and href == third and length >= 3, evicted=evicted, href=href, historyLength=length, tab=woke)
            finally:
                app.call('sleep-clock', reset=True)
        gate('wake_after_cache_close_keeps_navigation', wake_after_cache_close)

        def quit_buried_peek():
            # WC-02: a beforeunload page under another Peek used to hang Quit for good.
            source = page()
            app.call('peek-open', tab=source, url=origin + '/peek-one?' + str(time.time_ns()))
            first = wait(lambda: (lambda s: s['stack'][0]['content'] if s['stack'] and s['stack'][0]['content'] else None)(app.call('peek-state')), timeout=5, step=.05)
            assert first, app.call('peek-state')
            assert wait(lambda: app.eval(first, 'document.readyState') == 'complete', timeout=5, step=.05)
            arm(first)
            app.call('peek-open', tab=source, url=origin + '/peek-two?' + str(time.time_ns()))
            assert wait(lambda: len(app.call('peek-state')['stack']) == 2, timeout=5, step=.05), app.call('peek-state')
            app.call('quit')
            state = wait(lambda: (lambda s: s if s.get('visible') else None)(ds()), timeout=5, step=.05)
            if state: answer(False)
            survived = alive()
            if survived:
                app.eval(first, 'onbeforeunload=null;true', timeout=1); app.call('peek-close')
            return check(bool(state) and state['title'] == 'Leave site?' and survived, state=state, survived=survived)
        gate('dialog_quit_buried_peek', quit_buried_peek)

        def ws(): return app.call('window-state')
        def settled(full, page_full):
            return wait(lambda: (lambda s: s if s['fullscreen'] == full and s['pageFullscreen'] == page_full
                                 and not s['fullscreenTransition'] else None)(ws()), timeout=15, step=.1)
        def enter_page_fullscreen(target):
            result = app.eval(target, 'document.documentElement.requestFullscreen().then(() => "ok", e => e.message)')
            entered = settled(True, True)
            assert result == 'ok' and entered, {'request': result, 'state': ws()}
        def fullscreen_rows(how):
            # WC-01: page fullscreen ends with its page. A closed, hidden or window-exited page
            # used to leave the window in full screen with the sidebar hidden for good.
            assert not ws()['fullscreen'], ws()
            target = page(); other = None
            if how == 'switch': other = page(); app.call('select', tab=target)
            enter_page_fullscreen(target)
            if how == 'close': app.call('close', tab=target)
            elif how == 'switch': app.call('select', tab=other)
            elif how == 'window': app.call('window-fullscreen')
            elif how == 'peek': app.call('peek-open', tab=target, url=origin + '/peek-fs?' + str(time.time_ns()))
            after = settled(False, False) or ws()
            doc = None if how == 'close' else app.eval(target, '!!document.fullscreenElement')
            if ws()['fullscreen']: app.call('window-fullscreen'); settled(False, ws()['pageFullscreen'])
            if how == 'peek': app.call('peek-close')
            return check(not after['fullscreen'] and not after['pageFullscreen'] and after['sidebarVisible'] and not doc,
                         after={k: after.get(k) for k in ('fullscreen', 'pageFullscreen', 'sidebarVisible', 'fullscreenTransition')},
                         documentFullscreen=doc)
        for how in ('close', 'switch', 'window', 'peek'):
            gate('fullscreen_ends_on_' + how, lambda how=how: fullscreen_rows(how))

        def fullscreen_background():
            # WC-01: a page not shown in this window cannot take the window into full screen.
            target = page(); page()
            result = app.eval(target, 'document.documentElement.requestFullscreen().then(() => "ok", e => e.message)')
            time.sleep(1.5); state = ws(); doc = app.eval(target, '!!document.fullscreenElement')
            if state['fullscreen']: app.call('window-fullscreen'); settled(False, False)
            return check(not state['fullscreen'] and not state['pageFullscreen'] and not doc,
                         request=result, documentFullscreen=doc,
                         state={k: state.get(k) for k in ('fullscreen', 'pageFullscreen', 'sidebarVisible')})
        gate('fullscreen_background_refused', fullscreen_background)

        def popup_menu_profile():
            # WC-11 (#645 review): a popup panel of Profile "Menu Work" stays open after the window
            # switches to the Default Profile. Its "Open Link in New Tab" opens in a Work Space, and
            # opens nothing once Work has no Space; it used to open in the focused Default Space.
            home = ws()['space']
            work = app.call('space-create', title='Menu Work', profile='Menu Work')
            page(); app.eval(tab, 'void window.open(%s, "pm", "popup,width=520,height=420")' % json.dumps(origin + '/menu-popup'))
            popup = wait(lambda: next((x['identifier'] for x in app.call('pages') if x['kind'] == 'popup'), None), timeout=5, step=.05)
            assert popup, app.call('pages')
            def link_tabs(space):
                app.call('space', space=space)
                return [t['id'] for t in app.call('tabs') if '/menu-link' in t.get('url', '')]
            def open_link(name):
                url = origin + '/menu-link-' + name
                app.eval(popup, 'document.body.innerHTML=%s;true' % json.dumps('<a id=l href="%s" style="position:fixed;left:20px;top:20px">link</a>' % url))
                x, y = app.eval(popup, '(r=>[r.left+5,r.top+5])(document.querySelector("#l").getBoundingClientRect())')
                app.call('space', space=home)
                app.call('policy', contextMenu='run-open:Open Link in New Tab'); app.call('events')
                app.call('rightclick', tab=popup, x=x, y=y)
                return wait(lambda: any(e['type'] == 'contextMenu' for e in app.call('events')), timeout=5, step=.05)
            try:
                assert wait(lambda: app.eval(popup, 'document.readyState') == 'complete', timeout=5, step=.05)
                shown = open_link('a'); time.sleep(.5)
                in_home, in_work = link_tabs(home), link_tabs(work)
                for t in in_home + in_work: app.call('close', tab=t)
                # Work loses its last Space: the popup's Profile has none now.
                app.call('space', space=home); assert app.call('space-profile', space=work, profile='Default')
                if any(p['name'] == 'Menu Work' and p['spaces'] for p in app.call('profiles-shell')['profiles']):
                    app.call('alert', button='Change Profile')
                spaceless = open_link('b'); time.sleep(.5)
                stray = [t for t in link_tabs(home) + link_tabs(work) if t not in in_home + in_work]
                for t in stray: app.call('close', tab=t)
            finally:
                app.call('policy', contextMenu=''); app.call('close', tab=popup); app.call('space', space=home)
            return check(shown and in_work and not in_home and spaceless and not stray,
                         inWork=in_work, inHome=in_home, stray=stray)
        gate('menu_link_uses_page_profile', popup_menu_profile)

        def find_behind_library_spaces():
            # Round 5 (#646 leftover): Edit > Find, Cmd+G and Cmd+Shift+G open no Find on the page
            # strip behind Library > Spaces (Cmd+F alone was guarded). Wide window, as #646's row.
            page(); app.call('window-frame', frame=[40, 40, 2000, 820])
            try:
                app.call('library', action='open', section='spaces')
                assert wait(lambda: app.call('library').get('section') == 'spaces', timeout=3, step=.1), app.call('library')
                for key, mods in (('g', ['cmd']), ('g', ['cmd', 'shift'])): app.call('key', key=key, modifiers=mods, route='app')
                try: menu = app.call('menu-perform', id='find')
                except RuntimeError as error: menu = str(error)
                time.sleep(.5)
                panes = app.call('find-state').get('panes', [])
                app.call('library', action='close'); time.sleep(.5)
                app.call('focus', tab=tab); app.call('key', key='g', modifiers=['cmd'], route='app')
                control = wait(lambda: any(p.get('visible') for p in app.call('find-state').get('panes', [])), timeout=3, step=.1)
                app.call('key', key='escape', route='app')
            finally:
                h['_try'](lambda: app.call('library', action='close')); app.call('window-frame', frame=[80, 60, 1100, 760])
            return check(not any(p.get('visible') for p in panes) and bool(control), panes=panes, menu=menu, control=bool(control))
        gate('find_hidden_by_library_spaces', find_behind_library_spaces)

        # Fresh localhost origins avoid Chromium's repeated-denial embargo.
        port = server.server_address[1]
        def permission_page(host):
            url = 'http://%s.localhost:%d' % (host, port)
            page(url + '/permission'); app.call('permission', origin=url, kind=8, state=0)
            return url
        def notnow():
            url = permission_page('notnow'); perm(); state = visible(ps)
            pressed = app.call('permission-prompt', answer='notnow')
            denied = wait(lambda: app.eval(tab, 'permissionResult') == 'denied', timeout=3, step=.02)
            stored = app.call('permission', origin=url, kind=8)
            app.call('devtools', tab=tab, method='Page.reload'); app.call('wait', tab=tab)
            perm(); again = visible(ps)
            return check(pressed and denied and stored == 0 and again['visible']
                         and state['question'] == 'Allow notnow.localhost to send you notifications?'
                         and state['buttons'] == ['Not Now','Allow']
                         and state['help'] == 'Click the lock to change this any time'
                         and state['anchor']['name'] == 'sidebar-url', state=state, stored=stored)
        gate('permission_notnow_once_copy_anchor', notnow)

        remembered = 'http://remember.localhost:%d' % port
        def allow():
            permission_page('remember'); perm(); state = visible(ps)
            app.call('snapshot',path=str(Path(tmp)/'permission.png'),window=state['window'])
            pressed = app.call('permission-prompt', answer='allow')
            granted = wait(lambda: app.eval(tab, 'permissionResult') == 'granted', timeout=3, step=.02)
            stored = app.call('permission', origin=remembered, kind=8)
            before = ps()['decisions']; page(remembered + '/second'); actual = app.eval(tab,'Notification.requestPermission()')
            decisions = app.call('permission-decisions')
            return check(pressed and granted and stored == 1 and actual == 'granted' and not ps()['visible']
                         and ps()['decisions'] == before and any(d['origin'] == remembered and d['state'] == 1 for d in decisions['decisions']),
                         state=state, stored=stored, decisions=decisions)
        gate('permission_allow_remember_data', allow)

        def ipv6_origin():
            # Bug sweep r3 E13: the decision index stored IPv6 origins without brackets
            # ("http://::1:8080"). That string does not parse, so the decision was never listed.
            origin6 = 'http://[::1]:%d' % port
            try:
                stored = app.call('permission', origin=origin6, kind=8, state=1)
                listed = [d for d in app.call('permission-decisions')['decisions'] if d['origin'] == origin6]
            finally:
                app.call('permission', origin=origin6, kind=8, state=0)
            return check(stored == 1 and len(listed) == 1 and listed[0]['state'] == 1, stored=stored, listed=listed)
        gate('permission_ipv6_origin_listed', ipv6_origin)

        def origin_normalized():
            # Review r1 item 5: the index keeps one canonical origin. An uppercase scheme was dropped
            # (never listed); an explicit default port listed a second row for the same origin.
            # A port no other row indexes, so the uppercase case stands alone.
            upper, default = 'HTTP://[::1]:8443', 'http://[::1]:80'
            try:
                app.call('permission', origin=upper, kind=8, state=1)
                app.call('permission', origin=default, kind=8, state=1)
                listed = sorted(d['origin'] for d in app.call('permission-decisions')['decisions'] if '[::1]' in d['origin'])
            finally:
                for origin6 in (upper, default):
                    app.call('permission', origin=origin6, kind=8, state=0)
            return check(listed == sorted(['http://[::1]', 'http://[::1]:8443']), listed=listed)
        gate('permission_origin_index_normalized', origin_normalized)

        def switched():
            permission_page('switch'); target=tab; other=page(); app.call('select',tab=target); perm(target=target); visible(ps)
            app.call('events'); before=ps()['decisions']; app.call('select', tab=other)
            closed=wait(lambda: not ps()['visible'] and ps()['pending']==0, timeout=3,step=.02)
            events=[e for e in app.call('events') if e['type']=='permissionAnswer']
            return check(closed and ps()['decisions']==before+1 and len(events)==1 and events[0]['decision']=='dismiss', events=events)
        gate('permission_tab_switch_once', switched)

        for action in ['navigate','close']:
            def cancel_permission(action=action):
                permission_page('cancel-'+action); target=tab; perm(); visible(ps)
                before=ps()['decisions']; app.call('events')
                if action=='navigate':
                    app.call('navigate',tab=target,url=origin+'/after-permission'); app.call('wait',tab=target)
                else: app.call('close',tab=target)
                gone=wait(lambda:ps()['pending']==0 and not ps()['visible'],timeout=3,step=.02)
                events=[e for e in app.call('events') if e['type']=='permissionAnswer']
                return check(gone and ps()['decisions']==before+1 and len(events)==1 and events[0]['decision']=='dismiss',events=events)
            gate('permission_'+action+'_once',cancel_permission)

        def permission_background():
            permission_page('background'); target=tab; other=page()
            app.eval(target,'window.permissionResult="pending";Notification.requestPermission().then(v=>window.permissionResult=v);true')
            queued=wait(lambda:ps()['pending']==1,timeout=3,step=.02); hidden=not ps()['visible']
            app.call('select',tab=target); state=visible(ps); app.call('permission-prompt',answer='notnow')
            return check(hidden and state['visible'],state=state,other=other,appQueued=queued,hidden=hidden)
        gate('permission_background_select',permission_background)

        for anchor in ['content-top-left','toolbar-site-control']:
            def fallback(anchor=anchor):
                permission_page('hidden-' + anchor); app.call('command', id='toggle-sidebar')
                if anchor == 'toolbar-site-control': app.call('command', id='toggle-toolbar')
                perm(); state=visible(ps)
                button = app.call('site-controls')['visibleAnchor']
                if anchor == 'toolbar-site-control':
                    # The installed SCC provider anchors to the actual toolbar
                    # button, rather than the old whole-URL-field fallback.
                    frame = button.get('frame', [])
                    correct = (state['anchor']['name'] == 'site-control' and button.get('surface') == 'toolbar'
                        and len(frame) == 4 and frame[2] > 0 and frame[3] > 0
                        and all(abs(a-b) <= 1 for a,b in zip(state['anchor']['frame'],frame)))
                else:
                    correct = state['anchor']['name'] == anchor and state['anchor']['frame'][2] > 0 and not button
                return check(correct, state=state, visibleSiteControl=button)
            gate('permission_anchor_' + anchor, fallback)
            h['_try'](lambda: app.call('command',id='toggle-sidebar'))
            if anchor == 'toolbar-site-control': h['_try'](lambda: app.call('command', id='toggle-toolbar'))

        def midi():
            page('http://midi.localhost:%d/midi' % port); perm('midi'); state=visible(ps)
            app.call('permission-prompt',answer='notnow')
            return check(state['question']=='Allow midi.localhost to access your MIDI devices?' and state['kinds'] & 32, state=state)
        gate('permission_midi_real_request', midi)

        for key in ['escape','return','w','t','l']:
            def permission_keys(key=key):
                permission_page('keys-' + key); target=tab
                app.eval(target,'window.promptKeys=[];document.addEventListener("keydown",e=>promptKeys.push(e.key));true')
                perm(); state=visible(ps)
                app.call('key', key=key, **({'modifiers':['cmd']} if key in ['w','t','l'] else {}))
                closed=wait(lambda:not ps()['visible'],timeout=3,step=.02)
                if key in ['escape','return']:
                    actual=app.eval(target,'permissionResult')
                    good=actual==('granted' if key=='return' else 'denied') and app.eval(target,'promptKeys')==[]
                elif key=='w': good=all(t['id']!=target for t in app.call('tabs'))
                else:
                    bar=app.call('commandbar-state'); good=bar.get('presented') and bar['mode']==('newTab' if key=='t' else 'editCurrentURL')
                    app.call('key',key='escape')
                return check((closed if key in ['escape','return','w'] else True) and good,state=state)
            gate('permission_native_' + key, permission_keys)

        if only and 'permission_remember_relaunch' not in only: return
        cleanup()
        assert wait(lambda: app.call('permission-decisions')['ready'],timeout=3,step=.02)
        app.quit()
        app=factory(urls=(remembered+'/relaunch',), extra_env={'OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION':'record'})
        tab=next(t['id'] for t in app.call('tabs') if t['url'].startswith(remembered)); app.call('select',tab=tab); app.call('wait',tab=tab)
        perm()
        wait(lambda: ps()['visible'] or app.eval(tab,'permissionResult')!='pending',timeout=3,step=.02)
        actual=app.eval(tab,'permissionResult')
        ready=wait(lambda:app.call('permission-decisions')['ready'],timeout=3,step=.02)
        decisions=app.call('permission-decisions')
        results['permission_remember_relaunch']=check(actual=='granted' and not ps()['visible'] and ready
            and any(d['origin']==remembered and d['kind']==8 and d['state']==1 for d in decisions['decisions']),result=actual,decisions=decisions)
        if not only:
            try:
                cleanup(); page(); app.eval(tab,'document.body.innerHTML="<button id=arm>Arm</button>";document.querySelector("#arm").onclick=()=>{onbeforeunload=e=>{e.preventDefault();e.returnValue="unsaved"}};true')
                app.call('click',tab=tab,selector='#arm')
                assert wait(lambda:app.call('engine-sleep',tab=tab)['unloadHandlers'],timeout=3,step=.02)
                app.call('quit'); state=visible(ds); answer()
                exited=wait(lambda:app.process_path(app.pid)!=app.executable,timeout=8,step=.05)
                app.quit()
                results['dialog_quit_ok']=check(exited and state['title']=='Leave site?',state=state)
            except h['FocusInterruption']:
                raise
            except Exception as error:
                app.quit()
                results['dialog_quit_ok']=check(False,error=str(error))
    finally:
        evidence=Path(h['ROOT'])/'.re/s11-dialogs'; evidence.mkdir(parents=True,exist_ok=True)
        for name in ['dialog-0.png','dialog-2.png','permission.png']:
            if (Path(tmp)/name).exists(): shutil.copyfile(Path(tmp)/name,evidence/name)
        h['_try'](cleanup)
        h['_restore_defaults'](app,saved)
        app.quit(); server.shutdown(); server.server_close()
