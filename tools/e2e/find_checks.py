"""Section 11 Find: real App, native application keys, loopback page and own-window pixels."""
import os
import time
import subprocess
from pathlib import Path


def jump_selection(h, app, tab):
    app.eval(tab, "window.selectFindText('far')"); time.sleep(.1)
    app.eval(tab, 'window.scrollTo(0,0)'); time.sleep(.1)
    selection_position = "(() => {let r=document.getElementById('far').getBoundingClientRect();return [scrollY,innerHeight,r.top,r.bottom]})()"
    before_jump = app.eval(tab, selection_position)
    app.call('key', route='app', key='j', modifiers=['cmd'])
    def centered_selection():
        position=app.eval(tab, selection_position)
        return position if position[0]>1000 and abs((position[2]+position[3]-position[1])/2)<2 else None
    jumped=h.wait_until(centered_selection, timeout=3, step=.05)
    return dict(ok=before_jump[0]==0 and before_jump[2]>before_jump[1] and bool(jumped),
        before=before_jump, after=app.eval(tab, selection_position))

def run(h, factory, results, tmp):
    server, origin = h._static_server(os.path.join(h.ROOT, 'tools/e2e/fixtures/find'))
    # Reuse the real S8 scheduler/view observer, scoped to Find's executable
    # frames. This does not attach to a process or request macOS authorization.
    probe_source = Path(h.ROOT, 'tools/verification/feature-idle-probe.m').read_text()
    probe_source = probe_source.replace('if (!strstr(path, "/features-render")) return NO;',
        'if (!strstr(path, "/Open.app/Contents/MacOS/Open")) return NO;')
    probe_source = probe_source.replace('return strstr(info.dli_sname, "OpenFeatures") || strstr(info.dli_sname, "observerProof");',
        'return strstr(info.dli_sname, "FindController") || strstr(info.dli_sname, "FindBarView") || strstr(info.dli_sname, "FindPaneOverlay") || strstr(info.dli_sname, "FindResultsView");')
    source = os.path.join(tmp, 'find-idle-probe.m'); Path(source).write_text(probe_source)
    probe = os.path.join(tmp, 'idle-probe.dylib')
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fblocks', '-fobjc-arc', '-Wno-deprecated-declarations', source,
                    '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'CoreVideo', '-o', probe], check=True, timeout=30)
    app = factory(urls=(origin + '/index.html',), fresh=True)
    saved = {}
    private = os.path.join(h.ROOT, '.re', 'find')
    os.makedirs(private, exist_ok=True)
    def row(name, ok, **data):
        data['display'] = state().get('display', {})
        results[name] = dict(ok=bool(ok), **data)
    def key(key=None, modifiers=(), text=None):
        return app.call('key', route='app', **({'text': text} if text is not None else {'key': key, 'modifiers': list(modifiers)}))
    def state(): return app.call('find-state')
    def pane(tab=None):
        s = state()
        return next((p for p in s.get('panes', []) if p['tab'] == (tab or s.get('focusedTab'))),
                    dict(tab='', visible=False, focused=False, query='', countText='', active=0, total=0, notFound=False,
                         navigationVisible=False, separatorVisible=False, frame=[], paneFrame=[], topInset=0,
                         placeholder='', radius=0, querySelection=[], layouts=0))
    def settled(tab=None, count=None):
        def ready():
            p=pane(tab)
            return p if count is None or p['countText']==count else None
        return h.wait_until(ready, timeout=3, step=.05) or pane(tab)
    def query(value):
        key('f', ['cmd']); key('a', ['cmd']); key(text=value)
        return settled()
    def select(tab, element):
        app.call('focus', tab=tab)
        app.eval(tab, 'window.selectFindText(%r)' % element)
    def rect_ok(p, top=10, width=300):
        f, area = p['frame'], p['paneFrame']
        return len(f) == 4 and len(area) == 4 and p['visible'] and abs(f[2]-width)<.1 and f[3] == 32 and abs(area[0]+area[2]-f[0]-f[2]-10)<.1 and abs(area[1]+area[3]-f[1]-f[3]-top)<.1
    try:
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        window_ready = app.call('window-state')
        app.call('window-focus', id=window_ready['id'], activate=True)
        viewport = window_ready['toolbar']['page'][2:]
        ready = h.wait_until(lambda: app.eval(tab, '[window.innerWidth,window.innerHeight,document.readyState]') == viewport+['complete'], timeout=5, step=.05)
        if not ready: raise RuntimeError('Find fixture viewport did not settle before the timing input')
        cold = state()
        row('F01_lazy', not cold.get('created', bool(cold.get('panes'))), state=cold)
        app.call('focus', tab=tab)
        opening_key = key('f', ['cmd'])
        p = pane(tab)
        row('F02_open_focus_placeholder', p['visible'] and p['focused'] and p['placeholder'] == 'Find in page...', pane=p)
        row('F03_frame', rect_ok(p) and p['radius'] == 5 and p.get('controls',{}).get('closeHitMatches') is True, pane=p)
        load = subprocess.check_output(['uptime'], text=True).strip()
        fps=state().get('display',{}).get('window',{}).get('maximumFPS',0)
        deadline=min(1000/120,1000/fps) if fps>0 else 0
        row('F04_one_frame', p['visible'] and fps>0 and state().get('presentationPhases', {}).get('commit', 999) <= deadline,
            commitMilliseconds=state().get('presentationPhases', {}).get('commit'), dispatchMilliseconds=opening_key.get('dispatchMilliseconds'), scope='native key event timestamp to flushed visible Find layer in the initial settled window, with no Find warm-up; native field-editor focus completes in the same action', viewMilliseconds=state().get('presentationMilliseconds'), phases=state().get('presentationPhases'), deadline=deadline, baseline120HzDeadline=1000/120, load=load)
        if os.environ.get('OPEN_FIND_TIMING_ONLY') == '1': return
        requests_before = state()
        key(text='quasar'); p = settled(tab, '1/5')
        after_typing = state()
        typed = after_typing.get('typedRequests', 0)-requests_before.get('typedRequests', 0)
        activated = after_typing.get('activationRequests', 0)-requests_before.get('activationRequests', 0)
        requests = after_typing.get('requests', 0)-requests_before.get('requests', 0)
        row('F05_coalescing', p['query'] == 'quasar' and typed == 1 and requests == typed+activated and activated <= 1, typedRequests=typed, activationRequests=activated, engineRequests=requests)
        row('F05_incremental_count', p['visible'] and p['query'] == 'quasar' and p['countText'] == '1/5' and p['navigationVisible'] and p['separatorVisible'], pane=p)
        for name, k, mods, expected in [('return', 'return', [], '2/5'), ('shift_return', 'return', ['shift'], '1/5'),
                                        ('down', 'down', [], '2/5'), ('up', 'up', [], '1/5'), ('wrap_previous', 'up', [], '5/5'), ('wrap_next', 'down', [], '1/5')]:
            key(k, mods); p = settled(tab, expected)
            row('F06_'+name, p['visible'] and p['countText'] == expected, pane=p)
        seen = app.eval(tab, 'window.findKeys')
        row('F07_field_keys_stay_native', pane(tab)['visible'] and seen == [], pageKeys=seen)
        key('f', ['cmd']); p = pane(tab)
        find_menu = next(m for m in app.call('menu-state') if m['id'] == 'find')
        row('F08_select_all', p['querySelection'] == [0, 6] and find_menu['enabled'], pane=p, menu=find_menu)
        app.call('focus', tab=tab)
        key('g', ['cmd']); p = settled(tab, '3/5')  # repeated Cmd+F runs the retained query once
        row('F09_page_cmd_g', p['countText'] == '3/5', pane=p)
        key('g', ['cmd', 'shift']); p = settled(tab, '2/5')
        row('F10_page_cmd_shift_g', p['countText'] == '2/5', pane=p)
        key('f', ['cmd']); settled(tab, '3/5'); key('escape')
        kept = app.eval(tab, 'window.getSelection().toString()')
        key('g', ['cmd']); p = settled(tab, '4/5')
        row('F10_closed_cmd_g', kept == 'quasar' and p['visible'] and p['countText'] == '4/5', pane=p, keptSelection=kept)
        key('escape'); key('g', ['cmd','shift']); p = settled(tab, '3/5')
        row('F10_closed_previous', p['visible'] and p['countText'] == '3/5', pane=p)
        key('f', ['cmd']); key('a', ['cmd']); key(text='no-such-match'); p = settled(tab, 'Not Found')
        row('F11_not_found', p['visible'] and p['notFound'] and p['total'] == 0 and not p['navigationVisible'], pane=p)
        key('a', ['cmd']); key('delete'); p = settled(tab, '')
        row('F12_empty', p['visible'] and p['query'] == '' and p['countText'] == '' and not p['navigationVisible'] and not p['separatorVisible'], pane=p)
        # The page's input remains the DOM focus target while AppKit owns Find.
        key('escape'); app.call('focus', tab=tab)
        app.eval(tab, "document.getElementById('input').focus(); window.findKeys=[]")
        key('f', ['cmd']); editing_before_escape = pane(tab)['focused']
        key('escape'); key(text='page-typing')
        text = h.wait_until(lambda: app.eval(tab, "document.getElementById('input').value"), timeout=3, step=.05)
        escaped = not pane(tab)['visible'] and app.call('focus-state')['owner'] == 'page' and text == 'page-typing'
        key('f', ['cmd']); p=pane(tab); f=p['frame']
        app.call('mouse', action='click', x=f[0]+f[2]-16, y=app.call('window-state')['frame'][3]-f[1]-16)
        click_closed=h.wait_until(lambda: not pane(tab)['visible'] and app.call('focus-state')['owner'] == 'page' and app.eval(tab, 'document.hasFocus()'), timeout=3, step=.05)
        key(text='-close'); closed_text=app.eval(tab, "document.getElementById('input').value")
        row('F13_escape_focus', editing_before_escape and escaped and bool(click_closed) and not pane(tab)['visible'] and not state().get('chromeHidden') and app.call('focus-state')['owner'] == 'page' and closed_text == 'page-typing-close', text=text, closeText=closed_text, closePane=pane(tab), closeFocus=app.call('focus-state'), chromeHidden=state().get('chromeHidden'))
        if os.environ.get('OPEN_FIND_FOCUS_ONLY') == '1': return
        for name, element, expected in [('trim_newline', 'lines', 'alpha beta'), ('short', 'seed', 'A short selection'), ('40', 'forty', '1234567890123456789012345678901234567890'), ('41_keeps', 'fortyone', '1234567890123456789012345678901234567890')]:
            select(tab, element); key('f', ['cmd'])
            h.wait_until(lambda: not state().get('pending'), timeout=3, step=.05)
            p = pane(tab); row('F14_seed_'+name, p['visible'] and p['query'] == expected, pane=p)
            key('escape')
        # Cmd+G with a closed bar uses its retained query.
        key('g', ['cmd']); p = settled(tab, '1/2')
        row('F15_closed_cmd_g', p['visible'] and p['query'].startswith('123456') and p['total'] >= 1, pane=p)
        app.eval(tab, 'getSelection().removeAllRanges()')
        query('quasar'); settled(tab, '1/5')
        other = app.call('open', url=origin + '/index.html?tab=b')['id']; app.call('wait', tab=other)
        row('F16_new_tab_closed', not pane(other)['visible'], pane=pane(other))
        query('orbit'); b = settled(other, '1/2')
        app.call('select', tab=tab); a = settled(tab, '1/5')
        app.call('select', tab=other); b2 = settled(other, '1/2')
        row('F17_per_tab', a['visible'] and a['query'] == 'quasar' and a['total'] == 5 and b['query'] == b2['query'] == 'orbit' and b2['total'] == 2, a=a, b=b2)
        new_document=origin + '/index.html?new=document'
        app.call('navigate', tab=other, url=new_document); app.call('wait', tab=other)
        navigated=h.wait_until(lambda: app.eval(other, 'location.href===%r && document.readyState==="complete"' % new_document), timeout=5, step=.05)
        p = pane(other)
        row('F18_navigation_clears', bool(navigated) and p['visible'] and p['query'] == 'orbit' and p['countText'] == '' and not p['navigationVisible'], pane=p)
        f = p['frame']; app.call('mouse', action='click', x=f[0]+45, y=app.call('window-state')['frame'][3]-f[1]-16)
        before_return=state(); return_focus=app.call('focus-state')
        key('return'); p = settled(other, '1/2')
        row('F19_return_after_navigation', p['visible'] and p['countText'] == '1/2', pane=p, focus=return_focus,
            requests=state().get('requests',0)-before_return.get('requests',0), results=state().get('results',0)-before_return.get('results',0))
        old_origin=app.eval(other, 'performance.timeOrigin')
        app.call('menu-perform', id='reload'); app.call('wait', tab=other)
        reloaded=h.wait_until(lambda: app.eval(other, 'performance.timeOrigin!==%r && document.readyState==="complete"' % old_origin), timeout=5, step=.05)
        p = pane(other)
        row('F19_reload_clears', bool(reloaded) and p['visible'] and p['query'] == 'orbit' and p['countText'] == '', pane=p)
        # Use the real native menu action as well as its key binding.
        key('escape'); app.call('menu-perform', id='find-and-replace'); p = pane(other)
        row('F20_find_replace_opens', p['visible'] and p['focused'], pane=p)
        key('escape'); key('f', ['cmd','option']); p=pane(other)
        row('F20_find_replace_key', p['visible'] and p['focused'], pane=p)
        key('escape'); app.call('focus', tab=other)
        row('F21_jump_selection', **jump_selection(h, app, other))
        app.eval(other, 'getSelection().removeAllRanges();window.scrollTo(0,0)')
        # Use Selection to Find has no 40-character ceiling; preserve Cmd+E registry.
        select(other, 'long'); selection_requests=state().get('requests',0)
        app.call('menu-perform', id='use-selection-to-find')
        h.wait_until(lambda: not state().get('pending'), timeout=3, step=.05)
        p = pane(other)
        row('F22_use_selection', not p['visible'] and p['query'] == app.eval(other, "document.getElementById('long').textContent") and len(p['query']) > 40 and state().get('requests',0)>selection_requests, pane=p,
            menu=next(m for m in app.call('menu-state') if m['id'] == 'use-selection-to-find'))
        app.eval(other, 'getSelection().removeAllRanges()')
        query('x'*1000); p = pane(other)
        row('F23_at_cap', p['visible'] and len(p['query'].encode()) == 1000, bytes=len(p['query'].encode()))
        key('a', ['cmd']); key(text='é'*501); p = pane(other)
        row('F24_over_cap_utf8', p['visible'] and p['query'] == 'é'*500, bytes=len(p['query'].encode()))
        # A split's pane bars each own Find. Focus through the app's real pane command.
        key('escape'); app.call('select', tab=tab); app.call('split')
        h.wait_until(lambda: len(app.call('window-state')['shownPages']) == 2, timeout=5, step=.05)
        app.call('focus', tab=tab); key('1', ['ctrl','shift']); key('f', ['cmd']); key('a', ['cmd']); key(text='quasar')
        left_id = state().get('focusedTab'); left = settled(left_id, '1/5')
        app.call('focus', tab=left_id); key('2', ['ctrl','shift']); key('f', ['cmd']); key('a', ['cmd']); key(text='orbit')
        right_id = state().get('focusedTab'); right = settled(right_id, '1/2'); left2 = pane(left_id)
        row('F25_split_focused_only', left_id != right_id and left['query'] == left2['query'] == 'quasar' and left2['total'] == 5 and right['query'] == 'orbit' and right['total'] == 2 and left2['visible'] and right['visible'], left=left2, right=right)
        # The toolbar is tested on a single pane, at a 50 pt top inset.
        app.call('split'); app.call('select', tab=tab)
        key('f', ['cmd']); key('a', ['cmd']); key(text='quasar'); settled(tab, '1/5')
        app.call('menu-perform', id='toggle-toolbar'); p = pane(tab)
        row('F26_toolbar_top_50', rect_ok(p, top=50) and not state().get('chromeHidden'), pane=p, chromeHidden=state().get('chromeHidden'))
        app.call('menu-perform', id='toggle-toolbar')
        # A narrow split pane shrinks the preferred 300 pt width.
        app.call('window-frame', frame=[100,70,600,760]); app.call('split')
        key('f', ['cmd']); p = pane()
        expected_width = max(0, min(300, p['paneFrame'][2]-20)) if p['paneFrame'] else 0
        row('F27_narrow', p['visible'] and expected_width < 300 and rect_ok(p, top=50, width=expected_width), pane=p)
        app.call('split'); app.call('window-frame', frame=[100,70,1100,760]); app.call('select', tab=tab)
        # Peek keeps its own bar; Esc closes Find before closing Peek.
        app.call('peek-open', tab=tab, url=origin + '/index.html?peek=1')
        app.call('wait'); peek = app.call('peek-state')['stack'][-1]['content']
        key('f', ['cmd']); key(text='quasar'); p = settled(count='1/5')
        row('F28_peek', p['visible'] and p['total'] == 5 and p['tab'] not in (tab, other) and rect_ok(p), pane=p)
        if os.environ.get('OPEN_FIND_FAIL_AT_PEEK') == '1': raise RuntimeError('intentional Find cleanup proof with Peek open')
        key('escape')
        field_escape = not pane()['visible'] and app.call('peek-state')['shown']
        key('f', ['cmd']); app.call('focus'); key('escape')
        page_escape = not pane()['visible'] and app.call('peek-state')['shown']
        row('F29_peek_escape', field_escape and page_escape, fieldEscape=field_escape, pageEscape=page_escape, pane=pane())
        app.call('peek-close'); h.wait_until(lambda: not app.call('peek-state')['shown'], timeout=3, step=.05)
        app.call('select', tab=tab); app.call('focus', tab=tab)
        app.eval(tab, 'getSelection().removeAllRanges()'); key('f', ['cmd']); key('a', ['cmd']); key(text='quasar'); settled(tab, '1/5')
        # Own-window colors in sRGB. Expected 8-bit values independently use
        # NSColor(displayP3Red: ...) -> usingColorSpace(.sRGB), then round.
        # Spec light (.980,.984,1), dark (.082,.110,.188).
        for appearance, expected in [('light', (250,251,255)), ('dark', (19,28,50))]:
            app.call('appearance', name=appearance)
            path = os.path.join(private, 'find-'+appearance+'.png'); capture = app.call('snapshot', path=path)
            p = pane(tab); f=p['frame']; width,height,pixel=h.read_image(path, srgb=True)
            ws=app.call('window-state'); scale=width/ws['frame'][2]
            rgb=pixel(round((f[0]+75)*scale), round(height-(f[1]+f[3]-3)*scale)) if f else (0,0,0)
            middle=pixel(round((f[0]+125)*scale), round(height-(f[1]+16)*scale)) if f else (0,0,0)
            delta=max(h.chrome_delta_e(rgb,expected),h.chrome_delta_e(middle,expected))
            if appearance == 'dark':
                corner = pixel(round((f[0]+.5)*scale), round(height-(f[1]+f[3]-.5)*scale)) if f else (0,0,0)
                edge = pixel(round((f[0]+5)*scale), round(height-(f[1]+f[3]-1)*scale)) if f else (0,0,0)
                row('F30_radius_pixels', capture.get('method') == 'windowserver+devtools' and p['visible'] and p['radius'] == 5 and h.chrome_delta_e(edge, expected) <= 2 and h.chrome_delta_e(corner, expected) > 5, corner=corner, edge=edge, file=path, capture=capture)
            row('F30_color_'+appearance, capture.get('method') == 'windowserver+devtools' and p['visible'] and delta <= 2, rgb=rgb, middle=middle, expected=expected, deltaE00=delta, file=path, capture=capture)
        app.call('appearance', name='system')
        # A separate real App keeps observer overhead out of the timing gate.
        # The observer is armed before the lazy Find view exists, so a leaked
        # initialization timer remains visible to the zero-resource gate.
        app.quit()
        app = factory(urls=(origin + '/index.html',), fresh=True, extra_env={'DYLD_INSERT_LIBRARIES': probe})
        tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab); app.call('focus', tab=tab)
        app.call('find-idle', action='begin')
        key('f', ['cmd']); key(text='quasar'); settled(tab, '1/5')
        app.call('focus', tab=tab); time.sleep(.5)
        app.call('find-idle', action='watch'); app.call('find-idle', action='reset')
        before=state(); p0=pane(tab); time.sleep(2); after=state(); p1=pane(tab)
        observed=app.call('find-idle', action='read')
        row('F31_idle', p1['visible'] and not before.get('pending') and not after.get('pending') and before.get('requests') == after.get('requests')
            and before.get('results') == after.get('results') and p0['layouts'] == p1['layouts'] and all(v == 0 for v in observed.values()), before=before, after=after, observer=observed, load=subprocess.check_output(['uptime'], text=True).strip())
        canary=app.call('find-idle', action='invalidate')
        row('F31_observer_canary', any(canary[k] > 0 for k in ('invalidations','layout')), observer=canary)
        app.call('find-idle', action='end')
        # Browser keys must keep their real owners from this new field editor.
        for name, k in [('address', 'l'), ('new_tab', 't')]:
            app.call('select', tab=tab); key('f', ['cmd']); key(k, ['cmd'])
            commandbar = app.call('commandbar-state')
            row('F32_'+name, bool(commandbar.get('presented')), bar=commandbar)
            key('escape')
        app.call('open', url=origin + '/index.html?survivor=1', background=True)
        app.call('select', tab=tab); key('f', ['cmd']); key('w', ['cmd'])
        remaining=app.call('tabs')
        row('F32_close_tab', tab not in [t['id'] for t in remaining] and not any(p['tab'] == tab for p in state().get('panes', [])), tabs=len(remaining))
    finally:
        try:
            app.call('appearance', name='system')
            try: app.call('find-idle', action='end')
            except Exception: pass
            for key_name, value in saved.items(): app.call('defaults', key=key_name, value=value)
        finally:
            app.quit(); server.shutdown(); server.server_close()
