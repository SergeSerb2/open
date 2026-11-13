"""Little Open page chrome through real loopback pages and AppKit controls."""
import http.server
import json
import os
from pathlib import Path
import threading
import time
import traceback
from loopback_http import LoopbackHTTPServer


def run(factory, results, tmp, h):
    only = set(filter(None, os.environ.get('OPEN_E2E_PAGE_CHROME_ONLY', '').split(',')))
    if only == {'little'}: only = set()
    if only and not any(name.startswith('little_') for name in only):
        return
    wait = h['wait_until']
    hits = []
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            hits.append(self.path)
            script = 'alert("early");window.completed=(window.completed||0)+1;fetch("/resumed")' if self.path == '/early' else ''
            body = ('<!doctype html><title>Little fixture</title><button id=arm onclick="onbeforeunload=e=>{e.preventDefault();e.returnValue=1}">Arm</button><script>' + script + '</script>').encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    # MIDI is hardware-free and never requests macOS notification authorization.
    app = factory(urls=(origin + '/main',), fresh=True,
                  extra_args=['--host-resolver-rules=MAP *.localhost 127.0.0.1'])
    saved = {}
    row = None
    def sessions(): return app.call('little-open-state')['sessions']
    def current(): return next((s for s in sessions() if s['id'] == row['id']), None)
    def call(command, **args): return app.call(command, window=row['window'], **args)
    def ev(js): return app.call('little-open-eval', id=row['id'], js=js, timeout=3)
    def ds(): return call('dialog-state')
    def ps(): return call('permission-prompt')
    def visible(state):
        value = wait(lambda: (lambda s: s if s.get('visible') else None)(state()), timeout=5, step=.02)
        assert value, state()
        return value
    def page(path='/page', host=None, load=True):
        nonlocal row
        previous = {s['id'] for s in sessions()}
        app.call('little-open-action', action='blank')
        row = next(s for s in sessions() if s['id'] not in previous)
        url = (origin if host is None else origin.replace('127.0.0.1', host + '.localhost')) + path
        app.call('key', window=row['window'], text=url + '\r')
        if load:
            assert wait(lambda: (lambda s: s and s['state'] == 'page' and s['content'] and not s['loading'])(current()), timeout=12), current()
        return url
    def schedule(js): ev('window.outcome="pending";setTimeout(()=>{window.outcome=(' + js + ')},50);true')
    def answer(accepted=True, text=None):
        assert call('dialog-button', accept=accepted, text=text)
        assert wait(lambda: not ds()['pending'], timeout=3, step=.02), ds()
    def cleanup():
        nonlocal row
        for session in sessions():
            row = session
            for _ in range(10):
                if not ds().get('pending'): break
                call('dialog', accept=False)
            if ps()['visible']: call('permission-prompt', answer='notnow')
            call('policy', dialogs='dismiss', permissions='deny')
            try: ev('onbeforeunload=null;true')
            except Exception: pass
            app.call('little-open-action', id=row['id'], action='close')
        row = None
    def gate(name, fn):
        if only and name not in only: return
        try:
            cleanup(); results[name] = fn()
        except h['FocusInterruption']: raise
        except Exception as error: results[name] = dict(ok=False, error=str(error), trace=traceback.format_exc()[-1200:])
        finally: cleanup()
        print(name + (' PASS' if results[name].get('ok') else ' FAIL'), flush=True)
        if not results[name].get('ok'): print(json.dumps(results[name]), flush=True)
    try:
        for key in ['open.links.littleOpenNUXSeen', 'open.links.littleOpenHotkeyEnabled']:
            saved[key] = app.call('defaults', key=key)
            app.call('defaults', key=key, value=key.endswith('NUXSeen'))
        for name, js, accepted, text, expected in [
            ('alert', '(alert("little message"),"resumed")', True, None, 'resumed'),
            ('confirm_ok', 'confirm("little message")', True, None, True),
            ('confirm_cancel', 'confirm("little message")', False, None, False),
            ('prompt', 'prompt("little message","seed")', True, 'little reply', 'little reply')]:
            def dialog(js=js, accepted=accepted, text=text, expected=expected, name=name):
                page(); schedule(js); state = visible(ds)
                if os.environ.get('OPEN_E2E_LITTLE_CHROME_EARLY_FAILURE') == '1': raise RuntimeError('intentional visible-sheet failure')
                blocked = []
                for key in ['w', 't', 'l']:
                    app.call('key', key=key, modifiers=['cmd'], window=state['window'])
                    blocked.append(ds()['visible'] and not current()['barPresented'])
                answer(accepted, text)
                return dict(ok=ev('outcome') == expected and state['parent'] == row['window']
                            and state['title'] == '127.0.0.1 says' and state['buttons'] == (['OK'] if name == 'alert' else ['OK', 'Cancel'])
                            and all(blocked), state=state, blocked=blocked)
            gate('little_dialog_' + name, dialog)
        def early():
            page('/early', load=False); state = visible(ds); before = hits.count('/resumed'); answer()
            resumed = wait(lambda: hits.count('/resumed') == before + 1, timeout=4)
            events = call('events')
            answers = [e for e in events if e['type'] == 'dialogAnswer']
            return dict(ok=bool(resumed) and state['parent'] == row['window'] and ev('completed') == 1 and len(answers) == 1 and current()['firstFrameRead']['content'] == 0
                        and current()['firstFrameRead']['browserID'] is None,
                        state=state, answers=answers, firstFrame=current()['firstFrameRead'],
                        resumed=bool(resumed), completed=ev('completed'))
        gate('little_dialog_early_once', early)
        for close in ['key', 'button']:
            def unload(close=close):
                page(); call('click', tab=current()['content'], selector='#arm')
                # The engine reports the actual unload handler, not just a JS variable.
                assert wait(lambda: call('engine-sleep', tab=current()['content'])['unloadHandlers'], timeout=3)
                before = current()['content']
                def close_window():
                    if close == 'button': app.call('little-open-action', id=row['id'], action='close-button')
                    else: app.call('key', window=row['window'], key='w' if close == 'key' else 'escape', **({'modifiers':['cmd']} if close == 'key' else {}))
                close_window(); state = visible(ds)
                # Repeated close while the sheet owns the request must not bypass it.
                app.call('little-open-action', id=row['id'], action='close')
                answer(False); kept = current()['content'] == before and ev('document.title') == 'Little fixture'
                close_window(); visible(ds); answer()
                gone = wait(lambda: current() is None, timeout=4)
                return dict(ok=kept and bool(gone) and state['title'] == 'Leave site?' and state['parent'] == row['window'], kept=kept, state=state)
            gate('little_beforeunload_' + close, unload)
        def request(): ev('window.permissionResult="pending";navigator.requestMIDIAccess({sysex:true}).then(()=>permissionResult="granted",()=>permissionResult="denied");true')
        for decision in ['allow', 'notnow']:
            def permission(decision=decision):
                url = page(host='little-' + decision)
                call('permission', origin=url, kind=32, state=0); request(); state=visible(ps)
                if state['presentation'] != 'card':
                    return dict(ok=False, reason='Expected an in-window permission card', state=state)
                x,y,w,height = state['frame']; content=current()['contentFrame']; window=current()['frame']
                inside = x >= 0 and y >= 0 and x+w <= window[2] and y+height <= window[3]
                content_top = window[3] - content[1]
                positioned = abs(x - 10) < 1 and abs(y + height - (content_top - 10)) < 1 and w == 320
                assert call('permission-prompt', answer=decision)
                assert wait(lambda: ev('permissionResult') != 'pending', timeout=3)
                actual=ev('permissionResult'); stored=call('permission', origin=url, kind=32)
                ev('location.reload();true')
                assert wait(lambda: current() and not current()['loading'], timeout=8)
                request()
                again=wait(lambda: ps()['visible'] or ev('permissionResult') != 'pending', timeout=4)
                second=ps(); expected='granted' if decision=='allow' else 'denied'
                app.call('snapshot', window=row['window'], path=str(Path(h['ROOT'])/'.re/s11-littleopen-card.png'))
                return dict(ok=state['presentation']=='card' and state['window']==row['window'] and inside and positioned
                            and actual==expected and stored==(1 if decision=='allow' else 0)
                            and bool(again) and second['visible']==(decision=='notnow')
                            and (decision!='allow' or ev('permissionResult')=='granted')
                            and state['buttons']==['Not Now','Allow']
                            and state['help']=='Click the lock to change this any time'
                            and state['question']=='Allow little-'+decision+'.localhost to access your MIDI devices?', state=state, second=second, stored=stored, inside=inside, positioned=positioned)
            gate('little_permission_' + decision, permission)
        for key in ['escape','return','w','t','l']:
            def keys(key=key):
                page(host='little-key-'+key); request(); state=visible(ps)
                ev('window.pageKeys=[];document.onkeydown=e=>pageKeys.push(e.key);true')
                app.call('key',window=row['window'],key=key,**({'modifiers':['cmd']} if key in ['w','t','l'] else {}))
                if key=='w': good=wait(lambda:current() is None,timeout=3)
                elif key in ['escape','return']:
                    good=wait(lambda:not ps()['visible'],timeout=3) and ev('pageKeys')==[] and ev('permissionResult')==('granted' if key=='return' else 'denied')
                    app.call('key',window=row['window'],key='x')
                    good = good and ev('pageKeys') == ['x']
                elif key=='t':
                    good=wait(lambda:app.call('commandbar-state').get('presented'),timeout=3)
                    app.call('key',key='escape')
                else:
                    good=current()['barPresented']; app.call('key',window=row['window'],key='escape')
                return dict(ok=bool(good), state=state)
            gate('little_permission_key_' + key,keys)
        for action in ['navigate', 'miniaturize']:
            def dismissed(action=action):
                page(host='little-dismiss-' + action); request(); state=visible(ps)
                before=ps()['decisions']; call('events')
                if action == 'navigate':
                    ev('location.href="/after-permission";true')
                else:
                    app.call('little-open-action',id=row['id'],action='miniaturize')
                gone=wait(lambda:not ps()['visible'] and ps()['pending']==0,timeout=3)
                events=[e for e in call('events') if e['type']=='permissionAnswer']
                if action == 'miniaturize': app.call('little-open-action',id=row['id'],action='deminiaturize')
                return dict(ok=bool(gone) and ps()['decisions']==before+1 and len(events)==1 and events[0]['decision']=='dismiss',
                            state=state,events=events,dismissed=bool(gone),after=ps())
            gate('little_permission_dismiss_' + action,dismissed)
        def hidden_dialog():
            page(); app.call('little-open-action',id=row['id'],action='miniaturize')
            schedule('confirm("hidden")')
            queued=wait(lambda:ds()['pending']==1,timeout=3); hidden=ds()
            app.call('little-open-action',id=row['id'],action='deminiaturize')
            state=visible(ds); answer(False)
            return dict(ok=bool(queued) and not hidden['visible'] and hidden['queued'] and state['parent']==row['window'] and ev('outcome') is False,hidden=hidden,state=state)
        gate('little_dialog_hidden_queue',hidden_dialog)
        for reduced in [False, True]:
            def motion(reduced=reduced):
                app.call('window-motion',reduced=reduced)
                try:
                    page(host='little-motion-'+str(reduced).lower()); request(); state=visible(ps)
                    call('permission-prompt',answer='notnow')
                    return dict(ok=state['animationDuration']==(0 if reduced else .1) and state['shadowPath'] and (not reduced or state['opacity']==1),state=state)
                finally: app.call('window-motion',reduced=False)
            gate('little_permission_motion_' + str(reduced).lower(),motion)
        def quit_cancel():
            page(); call('click', tab=current()['content'], selector='#arm')
            assert wait(lambda:call('engine-sleep',tab=current()['content'])['unloadHandlers'],timeout=3)
            app.call('quit'); state=visible(ds); answer(False)
            return dict(ok=state['parent']==row['window'] and ev('document.title')=='Little fixture',state=state)
        gate('little_quit_cancel',quit_cancel)
        def quit_partial_cancel():
            nonlocal row
            armed = {}
            for path in ['/quit-first', '/quit-second']:
                page(path); call('click', tab=current()['content'], selector='#arm')
                assert wait(lambda:call('engine-sleep',tab=current()['content'])['unloadHandlers'],timeout=3)
                armed[row['id']] = dict(current())
            def active_dialog():
                for session in sessions():
                    state = app.call('dialog-state', window=session['window'])
                    if state.get('visible'): return session, state
                return None
            app.call('quit')
            first = wait(active_dialog, timeout=5, step=.02)
            assert first, sessions()
            accepted, first_state = first
            assert app.call('dialog-button', window=accepted['window'], accept=True)
            second = wait(lambda: (lambda value: value if value and value[0]['id'] != accepted['id'] else None)(active_dialog()), timeout=5, step=.02)
            assert second, sessions()
            row, second_state = second
            answer(False)
            closed = wait(lambda: all(s['id'] != accepted['id'] for s in sessions()), timeout=3, step=.02)
            survivor = current()
            alive = survivor and survivor['content'] == armed[row['id']]['content'] and ev('document.title') == 'Little fixture'
            ev('onbeforeunload=null;location.href="/after-quit-cancel";true')
            navigated = wait(lambda: (lambda s: s and s['url'] == origin + '/after-quit-cancel' and not s['loading'])(current()), timeout=8, step=.02)
            return dict(ok=bool(closed and alive and navigated) and len(sessions()) == 1
                        and first_state['parent'] == accepted['window'] and second_state['parent'] == row['window'],
                        acceptedClosed=bool(closed), survivorAlive=bool(alive), survivorNavigated=bool(navigated),
                        first=first_state, second=second_state, sessions=sessions())
        gate('little_quit_partial_cancel',quit_partial_cancel)
        if not only or 'little_quit_ok' in only:
            try:
                cleanup(); page(); call('click',tab=current()['content'],selector='#arm')
                assert wait(lambda:call('engine-sleep',tab=current()['content'])['unloadHandlers'],timeout=3)
                app.call('quit'); state=visible(ds); answer()
                exited=wait(lambda:app.process_path(app.pid)!=app.executable,timeout=8)
                app.quit()
                results['little_quit_ok']=dict(ok=bool(exited) and state['parent']==row['window'],state=state)
            except h['FocusInterruption']: raise
            except Exception as error:
                h['_try'](cleanup)
                app.quit()
                results['little_quit_ok']=dict(ok=False,error=str(error))
            print('little_quit_ok ' + ('PASS' if results['little_quit_ok']['ok'] else 'FAIL'),flush=True)
    finally:
        h['_try'](cleanup)
        h['_restore_defaults'](app,saved)
        app.quit(); server.shutdown(); server.server_close()
