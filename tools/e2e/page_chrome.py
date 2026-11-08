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

        for anchor in ['content-top-left','toolbar-url']:
            def fallback(anchor=anchor):
                permission_page('hidden-' + anchor); app.call('command', id='toggle-sidebar')
                if anchor == 'toolbar-url': app.call('command', id='toggle-toolbar')
                perm(); state=visible(ps)
                return check(state['anchor']['name']==anchor and state['anchor']['frame'][2]>0, state=state)
            gate('permission_anchor_' + anchor, fallback)
            h['_try'](lambda: app.call('command',id='toggle-sidebar'))
            if anchor == 'toolbar-url': h['_try'](lambda: app.call('command', id='toggle-toolbar'))

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
