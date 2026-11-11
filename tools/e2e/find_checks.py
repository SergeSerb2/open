"""Section 11 Find: real App, native application keys, loopback page and own-window pixels."""
import os
import time
import subprocess
import math
import statistics
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
        'return strstr(info.dli_sname, "FindController") || strstr(info.dli_sname, "FindBarView") || strstr(info.dli_sname, "FindPaneOverlay") || strstr(info.dli_sname, "FindResultsView") || strstr(info.dli_sname, "FindBarResources") || strstr(info.dli_sname, "FindBarPrewarm");')
    source = os.path.join(tmp, 'find-idle-probe.m'); Path(source).write_text(probe_source)
    probe = os.path.join(tmp, 'idle-probe.dylib')
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fblocks', '-fobjc-arc', '-Wno-deprecated-declarations', source,
                    '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'CoreVideo', '-o', probe], check=True, timeout=30)
    input_probe = None
    if os.environ.get('OPEN_FIND_INPUT_ORDER_NEGATIVE') == '1':
        input_probe = os.path.join(tmp, 'find-input-order-probe.dylib')
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc',
                        os.path.join(h.ROOT, 'tools/e2e/find-input-order-probe.m'),
                        '-framework', 'AppKit', '-o', input_probe], check=True, timeout=30)
    lane = getattr(h, "E2E_LANE", "all")
    app = None
    saved = {}
    private = os.path.join(h.ROOT, '.re', 'find')
    os.makedirs(private, exist_ok=True)
    def row(name, ok, **data):
        if lane == "observers" and not name.startswith("F31_"):
            return
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
    def rect_ok(p, width=None):
        f, area = p['frame'], p.get('viewportFrame', [])
        if len(f) != 4 or len(area) != 4: return False
        expected = max(0, min(300, area[2]-20)) if width is None else width
        return p['visible'] and abs(f[2]-expected)<.1 and f[3] == 32 and f[0]>=area[0]+10-.1 and f[1]>=area[1]-.1 and abs(area[0]+area[2]-f[0]-f[2]-10)<.1 and abs(area[1]+area[3]-f[1]-f[3]-10)<.1
    def intersects(a, b):
        return len(a)==4 and len(b)==4 and min(a[0]+a[2],b[0]+b[2])>max(a[0],b[0]) and min(a[1]+a[3],b[1]+b[3])>max(a[1],b[1])
    def clear_of_chrome(p):
        close = p.get('controls', {}).get('close', [])
        return len(close)==4 and all(not intersects(rect, item.get('frame', []))
            for item in p.get('chrome', []) if not item.get('hidden', False) for rect in [p['frame'],close])
    def viewport_close(name, target=None):
        if target is not None: app.call('focus', tab=target)
        app.call('ext-hover', inside=True)
        key('f', ['cmd']); p=pane(target)
        strips = [app.call('ext-strip', surface=s) for s in ('url', 'pane', 'toolbar')]
        pinned = [s for s in strips if s.get('visible') and s.get('ids')]
        duplicates = app.call('extensions')['duplicatesDropped']
        control=p.get('controls', {}).get('close', [])
        before=rect_ok(p) and clear_of_chrome(p) and p.get('controls',{}).get('closeHitMatches') is True and bool(pinned) and duplicates == 0
        if len(control)==4:
            app.call('mouse', action='click', x=control[0]+control[2]/2,
                     y=app.call('window-state')['frame'][3]-control[1]-control[3]/2)
        closed=h.wait_until(lambda: not pane(p['tab'])['visible'] and app.call('focus-state')['owner']=='page', timeout=3, step=.05)
        after = [app.call('ext-strip', surface=s) for s in ('url', 'pane', 'toolbar')]
        row(name, before and bool(closed) and any(s.get('visible') and s.get('ids') for s in after),
            pane=p, closed=bool(closed), focus=app.call('focus-state'), strips=strips,
            stripsAfterClose=after, duplicatesDropped=duplicates)
        key('f', ['cmd'])
    def idle_checks():
        nonlocal app
        app = factory(urls=(origin + '/index.html',), fresh=True, extra_env={'DYLD_INSERT_LIBRARIES': probe})
        tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab); app.call('focus', tab=tab)
        app.call('find-idle', action='begin')
        key('f', ['cmd']); key(text='quasar'); settled(tab, '1/5')
        app.call('focus', tab=tab); time.sleep(.5)
        app.call('find-idle', action='watch'); app.call('find-idle', action='reset')
        before=state(); p0=pane(tab); time.sleep(2); after=state(); p1=pane(tab)
        observed=app.call('find-idle', action='read')
        row('F31_idle', p1['visible'] and not before.get('pending') and not after.get('pending') and before.get('requests') == after.get('requests')
            and before.get('results') == after.get('results') and p0['layouts'] == p1['layouts'] and all(v == 0 for v in observed.values())
            and before.get('warmup', {}).get('runs') == after.get('warmup', {}).get('runs') == 1
            and after.get('warmup', {}).get('temporaryViewsReleased') is True,
            before=before, after=after, observer=observed, load=subprocess.check_output(['uptime'], text=True).strip())
        canary=app.call('find-idle', action='invalidate')
        row('F31_observer_canary', any(canary[k] > 0 for k in ('invalidations','layout')), observer=canary)
        app.call('find-idle', action='end')
        return tab
    try:
        if lane == "observers":
            idle_checks()
            return
        samples = []
        compare = os.environ.get('OPEN_FIND_COMPARE_PREWARM') == '1'
        for mode in (['cacheOnly', 'enabled'] * 20 if compare else ['enabled'] * 20):
            if app is not None: app.quit()
            mode_env = {'OPEN_FIND_DISABLE_PREWARM': '1' if mode == 'cacheOnly' else '0'} if compare else {}
            app = factory(urls=(origin + '/index.html',), fresh=True, extra_env=mode_env)
            tab = app.call('tabs')[0]['id']
            app.call('wait', tab=tab)
            window_ready = app.call('window-state')
            app.call('window-focus', id=window_ready['id'], activate=True)
            viewport = window_ready['toolbar']['page'][2:]
            ready = h.wait_until(lambda: app.eval(tab, '[window.innerWidth,window.innerHeight,document.readyState]') == viewport+['complete'], timeout=5, step=.05)
            if not ready: raise RuntimeError('Find fixture viewport did not settle before the timing input')
            cold = state()
            app.call('focus', tab=tab)
            opening_key = key('f', ['cmd'])
            first = state()
            first_pane = pane(tab)
            key('escape'); app.call('focus', tab=tab)
            repeat_key = key('f', ['cmd'])
            repeat = state()
            samples.append(dict(first=first.get('presentationPhases', {}).get('commit', 999),
                repeat=repeat.get('presentationPhases', {}).get('commit', 999),
                launch=app.call('timing', tab=tab), mode=mode, warmup=first.get('warmup', {}),
                lazy=not cold.get('created', bool(cold.get('panes'))),
                visible=first_pane['visible'] and pane(tab)['visible'],
                firstPhases=first.get('presentationPhases'), repeatPhases=repeat.get('presentationPhases'),
                firstDispatch=opening_key.get('dispatchMilliseconds'), repeatDispatch=repeat_key.get('dispatchMilliseconds'),
                load=subprocess.check_output(['uptime'], text=True).strip()))
        cache_samples = [s for s in samples if s['mode'] == 'cacheOnly']
        samples = [s for s in samples if s['mode'] == 'enabled']
        row('F01_lazy', all(s['lazy'] for s in samples + cache_samples), state=cold)
        p = pane(tab)
        row('F02_open_focus_placeholder', p['visible'] and p['focused'] and p['placeholder'] == 'Find in page...', pane=p)
        row('F03_frame', rect_ok(p, width=300) and clear_of_chrome(p) and p['radius'] == 5 and p.get('controls',{}).get('closeHitMatches') is True, pane=p)
        load = subprocess.check_output(['uptime'], text=True).strip()
        deadline=1000/120
        def distribution(name, source=samples):
            values=sorted(s[name] for s in source)
            return dict(median=statistics.median(values), p95=values[math.ceil(.95*len(values))-1], samples=len(values))
        first, repeat = distribution('first'), distribution('repeat')
        row('F04_one_frame', all(s['visible'] for s in samples) and first['p95'] <= deadline and repeat['p95'] <= deadline,
            firstMilliseconds=first, repeatMilliseconds=repeat, samples=samples,
            cacheOnly=dict(firstMilliseconds=distribution('first', cache_samples), repeatMilliseconds=distribution('repeat', cache_samples), samples=cache_samples) if cache_samples else {},
            scope='native key timestamp to flushed visible Find layer; first open includes lazy creation; repeat reuses the same window; twenty fresh App windows; focus completes in each action',
            deadline=deadline, informational240HzDeadline=1000/240, load=load)
        print('Find timing first median/p95 %.4f/%.4f ms; repeat %.4f/%.4f ms; 120 Hz gate %.4f ms; 240 Hz information %.4f ms' %
              (first['median'], first['p95'], repeat['median'], repeat['p95'], deadline, 1000/240), flush=True)
        if cache_samples:
            cache_first, cache_repeat = distribution('first', cache_samples), distribution('repeat', cache_samples)
            print('Find cache-only first median/p95 %.4f/%.4f ms; repeat %.4f/%.4f ms' %
                  (cache_first['median'], cache_first['p95'], cache_repeat['median'], cache_repeat['p95']), flush=True)
        if os.environ.get('OPEN_FIND_TIMING_ONLY') == '1': return
        # Keep extension setup outside the unchanged twenty-window timing gate.
        # The native close/viewport rows below must run with a real pinned action.
        app.quit()
        app = factory(urls=(origin + '/index.html',), fresh=True,
            extra_env={'DYLD_INSERT_LIBRARIES': input_probe} if input_probe else {}, extra_args=[
            '--load-extension=' + os.path.join(h.ROOT, 'tools/e2e/fixtures/action-probe'),
            '--disable-features=DisableLoadExtensionCommandLineSwitch'])
        tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab); app.call('focus', tab=tab)
        setting = 'open.advanced.showToolbar'
        saved[setting] = app.call('defaults', key=setting, persistent=True)
        app.call('defaults', key=setting, value=False)
        actions = h.wait_until(lambda: app.call('extensions')['actions'], timeout=15)
        if not actions: raise RuntimeError('Find extension overlap proof has no action')
        for action in actions: app.call('ext-pin', extension=action['id'], pinned=True)
        app.call('ext-hover', inside=True)
        key('f', ['cmd'])
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
        row('F13_escape_focus', editing_before_escape and escaped and bool(click_closed) and not pane(tab)['visible'] and app.call('focus-state')['owner'] == 'page' and closed_text == 'page-typing-close' and rect_ok(p) and clear_of_chrome(p) and p.get('controls',{}).get('closeHitMatches') is True, text=text, closeText=closed_text, closePane=pane(tab), beforeClick=p, closeFocus=app.call('focus-state'))
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
        # Queue both halves of the click. A direct down with an already queued
        # up can leave AppKit's control gesture tracking active and filter Return.
        f = p['frame']; app.call('mouse', action='click', queued=True, x=f[0]+45, y=app.call('window-state')['frame'][3]-f[1]-16)
        before_return=state(); return_focus=app.call('focus-state')
        return_delivery=key('return'); p = settled(other, '1/2')
        row('F19_return_after_navigation', p['visible'] and p['countText'] == '1/2', pane=p, focus=return_focus,
            delivery=return_delivery, focusAfter=app.call('focus-state'), before=before_return,
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
        viewport_close('F33_split_left_viewport_close', left_id)
        viewport_close('F33_split_right_viewport_close', right_id)
        # Both toolbar states use a 10 pt inset inside the real page viewport.
        app.call('split'); app.call('select', tab=tab)
        key('f', ['cmd']); key('a', ['cmd']); key(text='quasar'); settled(tab, '1/5')
        viewport_close('F33_toolbar_off_viewport_close', tab)
        app.call('menu-perform', id='toggle-toolbar'); p = pane(tab)
        row('F26_toolbar_viewport', rect_ok(p) and clear_of_chrome(p), pane=p)
        viewport_close('F33_toolbar_on_viewport_close', tab)
        app.call('menu-perform', id='toggle-toolbar')
        # A narrow split pane shrinks the preferred 300 pt width.
        app.call('window-frame', frame=[100,70,600,760]); app.call('split')
        key('f', ['cmd']); p = pane()
        expected_width = max(0, min(300, p['viewportFrame'][2]-20)) if p.get('viewportFrame') else 0
        row('F27_narrow', p['visible'] and expected_width < 300 and rect_ok(p, width=expected_width) and clear_of_chrome(p), pane=p)
        resizes=[]
        for width in [640,720,600]:
            app.call('window-frame', frame=[100,70,width,760])
            visible=[p for p in state().get('panes',[]) if p['visible']]
            resizes.append(dict(width=width,panes=visible))
        row('F34_split_live_resize', all(item['panes'] and all(rect_ok(p) and clear_of_chrome(p) for p in item['panes']) for item in resizes)
            and len({tuple(item['panes'][0]['frame']) for item in resizes if item['panes']})>1, resizes=resizes)
        viewport_close('F33_narrow_viewport_close')
        app.call('split'); app.call('window-frame', frame=[100,70,1100,760]); app.call('select', tab=tab)
        # Peek keeps its own bar; Esc closes Find before closing Peek.
        app.call('peek-open', tab=tab, url=origin + '/index.html?peek=1')
        app.call('wait'); peek = app.call('peek-state')['stack'][-1]['content']
        key('f', ['cmd']); key(text='quasar'); p = settled(count='1/5')
        row('F28_peek', p['visible'] and p['total'] == 5 and p['tab'] not in (tab, other) and rect_ok(p) and clear_of_chrome(p), pane=p)
        viewport_close('F33_peek_viewport_close')
        old_peek=pane()['frame']; old_viewport=pane()['viewportFrame']
        app.call('window-frame', frame=[100,70,1200,800])
        # Peek lays out its page viewport on the next AppKit layout pass. Wait
        # for that input to change, then apply the same Find placement checks.
        viewport_resized=h.wait_until(lambda: pane().get('viewportFrame') != old_viewport, timeout=3, step=.05)
        resized_peek=pane()
        row('F34_peek_live_resize', bool(viewport_resized) and rect_ok(resized_peek) and clear_of_chrome(resized_peek) and old_peek!=resized_peek['frame'], before=old_peek, viewportBefore=old_viewport, pane=resized_peek)
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
        if lane != "merge":
            tab = idle_checks()
        else:
            app = factory(urls=(origin + "/index.html",), fresh=True)
            tab = app.call("tabs")[0]["id"]; app.call("wait", tab=tab)
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
            if app is not None:
                app.call('appearance', name='system')
                try: app.call('find-idle', action='end')
                except Exception: pass
                for key_name, value in saved.items(): app.call('defaults', key=key_name, value=value)
        finally:
            if app is not None: app.quit()
            server.shutdown(); server.server_close()
