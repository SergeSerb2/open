"""Split View acceptance through the real App's socket, native views and live pages."""
import math
import os
import statistics
import subprocess
import time
from pathlib import Path


def split_checks(factory, results, tmp, h, functional_only=False):
    lane = getattr(h, "E2E_LANE", "all")
    environment = None
    if not functional_only and lane != "merge":
        probe = Path(tmp) / 'split-idle-probe.dylib'
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fblocks', '-fobjc-arc', '-Wno-deprecated-declarations',
                        str(Path(h.ROOT) / 'tools/verification/feature-idle-probe.m'), '-framework', 'AppKit',
                        '-framework', 'QuartzCore', '-framework', 'CoreVideo', '-o', str(probe)], check=True)
        environment = {'DYLD_INSERT_LIBRARIES': str(probe), 'OPEN_IDLE_OWNER': 'split'}
    server, origin = h._fixture_server('Split')
    app = factory(urls=(), fresh=True, extra_env=environment)
    saved = {}
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('split %-34s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
        if name.startswith('speed_'):
            print('  speed receipt:', {k: v for k, v in evidence.items() if k not in ('samples', 'scope')}, flush=True)
    if environment:
        # The probe stays in the App process only. A child that inherits DYLD_INSERT_LIBRARIES can abort in
        # dyld (/usr/bin/profiles, arm64e, did: its crash dialog blocked the rented Macs on 2026-11-12).
        def descendants(pid):
            kids = [int(p) for p in subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True).stdout.split()]
            return kids + [d for k in kids for d in descendants(k)]
        h.wait_until(lambda: len(descendants(app.pid)) >= 2, timeout=10, step=.2)
        kids = descendants(app.pid)
        def env_of(pid): return subprocess.run(['ps', 'eww', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True).stdout
        leaked = [k for k in kids if 'DYLD_INSERT_LIBRARIES=' in env_of(k)]
        row('injected_library_not_inherited', len(kids) >= 2 and not leaked,
            children=len(kids), leaked=len(leaked))
    def state(): return app.call('split', op='state')
    def settled(count=None):
        value = h.wait_until(lambda: (lambda s: s if count is None or len(s['panes']) == count else None)(state()), timeout=5, step=.02)
        assert value, state()
        time.sleep(.3)  # Finish the shipped 0.22 s split transition before pointer input.
        return state()
    def opened(name, background=False):
        tid = app.call('open', url=origin + '/' + name, background=background)['id']
        if not background: app.call('wait', tab=tid)
        return tid
    def select(tid):
        app.call('select', tab=tid)
        return settled()
    def key(name, mods=('ctrl', 'shift')): return app.call('key', key=name, modifiers=list(mods), route='app')
    def menu(title): return app.call('split', op='menu', item=title)
    def unsplit():
        if state()['id']: menu('Separate All Tabs'); settled(1)
    def drop(node, point, **kw): return app.call('split', op='drop', node=node, point=point, **kw)
    def edge(s, zone):
        x, y, w, height = s['container']
        return {'left': [x+12, y+height/2], 'right': [x+w-12, y+height/2],
                'top': [x+w/2, y+12], 'bottom': [x+w/2, y+height-12]}[zone]
    def live(ids):
        for tid in ids: app.call('wait', tab=tid)
        pages = app.call('pages')
        identifiers = {app.page(tid)['identifier'] for tid in ids}
        shown = [p for p in pages if p['identifier'] in identifiers]
        return len(shown) == len(ids) and all(p['live'] and not p['hidden'] for p in shown), shown
    def geometry(s, orientation, count):
        panes = [p['frame'] for p in s['panes'] if not p['hidden']]
        x, y, w, height = s['container']
        if len(panes) != count or any(min(p[2:]) <= 0 for p in panes): return False
        axis = 2 if orientation == 'horizontal' else 3
        if abs(sum(p[axis] for p in panes) + 10*(count-1) - (w if axis == 2 else height)) > 1: return False
        for i, p in enumerate(panes):
            if axis == 2:
                if abs(p[1]-y) > 1 or abs(p[3]-height) > 1: return False
                if i and abs(p[0] - (panes[i-1][0]+panes[i-1][2]) - 10) > 1: return False
            else:
                if abs(p[0]-x) > 1 or abs(p[2]-w) > 1: return False
                if i and abs(p[1] - (panes[i-1][1]+panes[i-1][3]) - 10) > 1: return False
        return True
    try:
        # Preferences use the real shared domain. Reset exactly the keys we use,
        # and restore them even on an assertion, interrupted key, or relaunch.
        for name, value in {'open.advanced.showFullURLWithToolbar': False}.items():
            saved[name] = app.call('defaults', key=name)
            app.call('defaults', key=name, value=value)
        app.call('suggest-remote', enabled=False)
        if not functional_only and lane != 'merge':
            app.call('split', op='observe')
        app.call('window-frame', frame=[60, 60, 1360, 860], unconstrained=True)
        empty_menu = app.call('split', op='plus')
        row('empty_split_disabled', not next(r['enabled'] for r in empty_menu if r['title'] == 'New Split'), menu=empty_menu)
        a = opened('a'); original_page = app.page(a)['identifier']; app.call('focus', tab=a)
        app.eval(a, "window.__splitResize=[];addEventListener('resize',()=>__splitResize.push([innerWidth,innerHeight]));true")
        key('='); s = settled(2)
        add_resizes = app.eval(a, 'window.__splitResize')
        row('pane_layer_redraw_prepared_once', all(p['layerRedrawPolicy'] == 3 for p in s['panes']), panes=s['panes'])
        row('add_resizes_web_once', len(add_resizes) <= 1, sizes=add_resizes)
        b = next(p['id'] for p in s['panes'] if p['id'] != a)
        row('C1_shortcut', s['orientation'] == 'horizontal' and s['focused'] == b and len(app.call('tabs')) == 2 and app.page(a)['identifier'] == original_page, state=s)
        app.call('navigate', tab=b, url=origin+'/b'); app.call('wait', tab=b)
        ok, pages = live([a, b]); row('E1_two_live_pages', ok, pages=pages)
        # Real page focus and input, plus independent navigation histories.
        app.eval(b, "document.body.innerHTML += '<input id=edit>';document.querySelector('#edit').focus()")
        app.call('focus', tab=b); app.call('key', text='split input')
        typed = app.eval(b, "document.querySelector('#edit').value")
        app.call('navigate', tab=b, url=origin+'/b-next'); app.call('wait', tab=b)
        app.call('menu-perform', id='go-back'); app.call('wait', tab=b)
        back = app.page(b)['url']; app.call('menu-perform', id='go-forward'); app.call('wait', tab=b)
        row('E1_input_history', typed == 'split input' and back.endswith('/b') and app.page(b)['url'].endswith('/b-next')
            and app.page(a)['url'].endswith('/a'), typed=typed, back=back)
        if lane == 'observers':
            pass  # Pixels and strict timing belong to the uninstrumented merge lane.
        elif functional_only:
            results['snapshot_two_panes']=dict(status='DEFERRED', reason='M5 pixel receipt required (TANDEM §4M)')
        else:
            png = Path(h.ROOT) / '.re/s9-split/split-two-pane.png'; png.parent.mkdir(parents=True, exist_ok=True)
            snapshot = app.call('snapshot', path=str(png))
            captured = state(); width, height, pixel = h.read_image(str(png), srgb=True)
            scale = width / 1360
            ring_pixels = []
            for pane in captured['panes']:
                x, y, w, height_pt = pane['frame']
                color = pixel((x+.75)*scale, (y+60)*scale)
                error = h.chrome_delta_e(color, [49, 57, 255])  # F0081 measured 2 pt accent ring.
                ring_pixels.append(dict(focused=pane['id'] == captured['focused'], rgb=color, delta_e00=error))
            pixel_ok = all((p['delta_e00'] <= 2 if p['focused'] else p['delta_e00'] > 10) for p in ring_pixels)
            row('snapshot_two_panes', geometry(captured, 'horizontal', 2) and pixel_ok and abs(height/scale-860) <= 1,
                path=str(png), snapshot=snapshot, ringPixels=ring_pixels, scale=scale)

        # C12-D2-2, session 12: native split-row customization and its persisted presentation.
        custom_id = state()['id']
        def row_menu(item=None):
            return app.call('sidebar-menu', node=custom_id, item=item) if item else app.call('sidebar-menu-items', node=custom_id)
        def presentation(): return state().get('rowPresentation', {})
        def rename(value, cancel=False):
            row_menu('Rename…')
            before = state()['renameEditor']
            app.call('key', text=value, route='app')
            key('escape' if cancel else 'return', ())
            return before
        original_titles = presentation().get('titles', [])
        listed = row_menu()['items']
        row('custom_menu_initial', 'Change Icon…' in listed and 'Rename…' in listed and 'Reset Name and Icon' not in listed, menu=listed)
        initial = rename('D2 Split')
        h.wait_until(lambda: presentation()['titles'] == ['D2 Split'],timeout=3,step=.02)
        row('custom_rename_inline', initial.get('text') == '2 Tabs' and initial.get('placeholder') == 'Title'
            and initial.get('selection') == [0,6] and presentation()['titles'] == ['D2 Split']
            and presentation()['paneFaviconsVisible'] == 0 and presentation()['iconSource'] == 'count', editor=initial,presentation=presentation())
        rename('Cancelled split',cancel=True)
        row('custom_rename_escape', presentation()['titles'] == ['D2 Split'] and 'Reset Name and Icon' in row_menu()['items'],presentation=presentation())
        row_menu('Reset Name and Icon')
        h.wait_until(lambda: presentation()['titles'] == original_titles,timeout=3,step=.02)
        row('custom_name_reset', presentation()['titles'] == original_titles and presentation()['paneFaviconsVisible'] == 2
            and 'Reset Name and Icon' not in row_menu()['items'],presentation=presentation())
        row_menu('Change Icon…')
        h.wait_until(lambda: app.call('editor-state').get('count',0) > 0,timeout=5,step=.02)
        for value in ('grinning face','down','return'):
            app.call('editor-act',action='key',key=value)
        h.wait_until(lambda: not app.call('editor-state')['open'],timeout=3,step=.02)
        row('custom_icon_only', presentation()['titles'] == ['2 Tabs'] and presentation()['iconSource'] == 'custom'
            and 'Reset Name and Icon' in row_menu()['items'],presentation=presentation())
        row_menu('Reset Name and Icon')
        row('custom_icon_reset', presentation()['titles'] == original_titles and presentation()['paneFaviconsVisible'] == 2
            and 'Reset Name and Icon' not in row_menu()['items'],presentation=presentation())
        rename('D2 Persisted Split')
        row_menu('Change Icon…')
        h.wait_until(lambda: app.call('editor-state').get('count',0) > 0,timeout=5,step=.02)
        for value in ('grinning face','down','return'):
            app.call('editor-act',action='key',key=value)
        h.wait_until(lambda: not app.call('editor-state')['open'],timeout=3,step=.02)
        captures = []
        for appearance in ('light','dark'):
            app.call('appearance',name=appearance)
            path = Path(h.ROOT) / '.re/s9-split' / ('split-custom-' + appearance + '.png')
            path.parent.mkdir(parents=True, exist_ok=True)
            app.call('snapshot',path=str(path))
            captures.append(str(path))
        app.call('appearance',name='system')
        app.call('save'); app.quit(); app = factory(urls=()); settled(2)
        restored_node = next(n for n in app.call('sidebar-tree')['today'] if n['id'] == custom_id)
        row('custom_relaunch', restored_node['customTitle'] == 'D2 Persisted Split'
            and restored_node['iconOverride'] == {'type':'emoji','value':'😀'}
            and presentation()['titles'] == ['D2 Persisted Split'] and presentation()['iconSource'] == 'custom',node=restored_node,presentation=presentation(),captures=captures)
        row_menu('Reset Name and Icon')
        reset = presentation()
        row('custom_relaunch_reset', reset['titles'] == original_titles and reset['paneFaviconsVisible'] == 2
            and not reset['customIconVisible'] and 'Reset Name and Icon' not in row_menu()['items'],presentation=reset)

        # C2: all four edge zones use actual destination callbacks and pasteboard decoding.
        zones = []
        for zone in ('right', 'left', 'top', 'bottom'):
            unsplit(); select(a); before = state(); transport = drop(b, edge(before, zone)); after = settled(2)
            expected = [b, a] if zone in ('left', 'top') else [a, b]
            orientation = 'horizontal' if zone in ('left', 'right') else 'vertical'
            zones.append(dict(zone=zone, transport=transport, state=after,
                              ok=transport['accepted'] and transport['overlayShown'] and transport['overlayHidden']
                              and [p['id'] for p in after['panes']] == expected and after['orientation'] == orientation))
        row('C2_edge_drop', all(z['ok'] for z in zones), zones=zones)
        unsplit(); select(a)
        center = state()['container']; center = [center[0]+center[2]/2, center[1]+center[3]/2]
        switched = drop(b, center); after = settled(1)
        row('C2_center_select', switched['accepted'] and after['focused'] == b and not after['id'], state=after)
        select(a); cancelled = drop(b, edge(state(), 'right'), cancel=True)
        row('C2_cancel', cancelled['overlayShown'] and cancelled['overlayHidden'] and not state()['id'], transport=cancelled)

        select(a); drop(b, edge(state(), 'right')); s = settled(2)
        d = s['dividers'][0]; point = [d[0]+d[2]/2, d[1]+d[3]/2]
        app.call('mouse', **{'from': point, 'to': [point[0]+45, point[1]]}); changed = settled(2)
        d = changed['dividers'][0]; point = [d[0]+d[2]/2, d[1]+d[3]/2]
        app.call('mouse', action='down', x=point[0], y=point[1], clickCount=2)
        app.call('mouse', action='up', x=point[0], y=point[1], clickCount=2); equal = settled(2)
        row('divider_horizontal_double_click', changed['fractions'] != s['fractions']
            and abs(changed['panes'][0]['frame'][2]-s['panes'][0]['frame'][2]-45) <= 1
            and abs(equal['panes'][0]['frame'][2]-equal['panes'][1]['frame'][2]) <= 1, changed=changed, equal=equal)
        c = opened('c', background=True); s = state(); x, y, w, height = s['container']
        combined = drop(c, [x+w*.6, y+height/2]); s = settled(3)
        row('C3_combine', combined['accepted'] and [p['id'] for p in s['panes']] == [a, c, b], state=s, transport=combined)
        own = drop(c, edge(s, 'left'))
        row('C3_own_pane_refused', not own['accepted'] and len(state()['panes']) == 3, transport=own)

        unsplit(); select(a)
        app.call('sidebar-menu', node=b, item='Open in Split View'); s = settled(2)
        row('C4_context_menu', [p['id'] for p in s['panes']] == [b, a] and s['focused'] == b, state=s)
        app.call('sidebar-menu', node=c, item='Open in Split View'); s = settled(3)
        row('C4_context_add', len(s['panes']) == 3 and s['focused'] == c, state=s)

        unsplit(); select(a)
        app.call('split', op='plus', item='New Split'); s = settled(2)
        plus_ok = s['focused'] != a and s['panes'][0]['id'] == a
        unsplit(); select(a)
        key('t', ('cmd',)); app.call('key', text='Add Split View')
        bar = h.wait_until(lambda: (lambda v: v if v.get('final') and v.get('rows') else None)(app.call('commandbar-state')), timeout=5, step=.02)
        assert bar, app.call('commandbar-state')
        index = next(i for i, r in enumerate(bar['rows']) if r['action'] == 'add-split-view')
        for _ in range(abs(index-bar['selected'])): key('down' if bar['selected'] < index else 'up', ())
        key('return', ()); s = settled(2)
        row('C5_commandbar_plus', plus_ok and bool(bar) and s['panes'][0]['id'] == a, bar=bar, state=s)

        # Native split-row menu appends empty panes and stops at the hard cap.
        split_id = s['id']
        app.call('sidebar-menu', node=split_id, item='Add Tab…'); settled(3)
        app.call('sidebar-menu', node=split_id, item='Add Tab…'); s = settled(4)
        ids = [p['id'] for p in s['panes']]
        disabled = app.call('sidebar-menu-state', node=split_id, item='Add Tab…')
        commands = app.call('menu-state'); enabled = next(r['enabled'] for r in commands if r['id'] == 'add-split-view')
        app.call('focus', tab=s['focused']); key('='); after = settled(4)
        outsider = opened('fifth-refused', background=True); refused = drop(outsider, edge(after, 'right'))
        row('fifth_drop_refused', not refused['accepted'] and len(state()['panes']) == 4, transport=refused)
        plus_enabled = next(r['enabled'] for r in app.call('split', op='plus') if r['title'] == 'New Split')
        row('add_up_to_four', not disabled['enabled'] and not enabled and not plus_enabled and [p['id'] for p in after['panes']] == ids, state=after, plusEnabled=plus_enabled)
        for i, tid in enumerate(ids): app.call('navigate', tab=tid, url=origin.replace('127.0.0.1', 'pane%d.localhost' % (i+1))+'/four-'+str(i))
        ok, pages = live(ids); row('E1_four_live_pages', ok, pages=pages)
        focus_rows = []
        for i, tid in enumerate(ids):
            app.call('focus', tab=state()['focused']); key(str(i+1)); s = settled(4)
            focus_rows.append(dict(key=i+1, state=s, ok=s['focused'] == tid and [p['id'] for p in s['panes'] if p['ring']] == [tid]
                                  and s['sidebarCurrent'] and s['selected'] == split_id and s['sidebarURL'] == 'pane%d.localhost' % (i+1) and s['title'] == 'Split /four-'+str(i)))
        key('}'); next_focus = state()['focused']; key('{'); previous = state()['focused']
        row('focus_keys_ring_sidebar', all(r['ok'] for r in focus_rows) and next_focus == ids[0] and previous == ids[3], keys=focus_rows)
        # Queue a native click at a page, so the production NSEvent local monitor observes it.
        p = state()['panes'][1]['frame']
        app.call('mouse', action='click', x=p[0]+p[2]/2, y=p[1]+60)
        clicked = h.wait_until(lambda: state() if state()['focused'] == ids[1] else None, timeout=2, step=.02)
        row('focus_page_click', bool(clicked), state=state())

        horizontal = state(); row('four_horizontal_frames', geometry(horizontal, 'horizontal', 4), state=horizontal)
        menu('Convert to Vertical Split View'); vertical = settled(4)
        row('four_vertical_frames', geometry(vertical, 'vertical', 4) and vertical['focused'] == horizontal['focused'], state=vertical)
        app.call('window-frame', frame=[60, 60, 1360, 1180], unconstrained=True); settled(4)
        # Divider movement goes through the existing own-window NSEvent pointer.
        before = state(); d = before['dividers'][0]; point = [d[0]+d[2]/2, d[1]+d[3]/2]
        app.call('mouse', action='down', x=point[0], y=point[1])
        app.call('mouse', action='drag', x=point[0], y=point[1]+35)
        during = state()
        app.call('mouse', action='up', x=point[0], y=point[1]+35)
        after = settled(4)
        row('divider_drag_commit', before['fractions'] == during['fractions'] and before['fractions'] != after['fractions']
            and abs(during['panes'][0]['frame'][3]-before['panes'][0]['frame'][3]-35) <= 1
            and abs(after['panes'][0]['frame'][3]-before['panes'][0]['frame'][3]-35) <= 1
            and geometry(after, 'vertical', 4) and [p['frame'] for p in before['panes'][2:]] == [p['frame'] for p in after['panes'][2:]],
            before=before, during=during, after=after)
        if lane == 'merge':
            pass  # The native-resource predicate requires the separate observer lane.
        elif functional_only:
            results['speed_idle_after_drag']=dict(status='DEFERRED', reason='M5 performance receipt required (TANDEM §4M)')
        else:
            idle = app.call('split', op='idle')
            row('speed_idle_after_drag', all(v == 0 for v in idle['before'][5:]) and all(v == 0 for v in idle['after'])
                and idle['animationsBefore'] == idle['animationsAfter'] == 0,
                loadAverage=list(os.getloadavg()), uptime=subprocess.check_output(['uptime'], text=True).strip(), **idle)
        # Maximizing keeps hosts alive. Esc and a focus key both restore the stored layout.
        original = state(); app.call('menu-perform', id='expand-current-split'); expanded = settled(4)
        key('escape', ()); restored = settled(4)
        app.call('menu-perform', id='expand-current-split'); settled(4); key('1'); focused = settled(4)
        row('expand_escape_focus_restore', bool(expanded['maximized']) and sum(not p['hidden'] for p in expanded['panes']) == 1
            and not restored['maximized'] and restored['fractions'] == original['fractions'] and not focused['maximized']
            and geometry(restored, original['orientation'], 4) and geometry(focused, original['orientation'], 4)
            and focused['focused'] == ids[0] and all(p['host'] for p in expanded['panes']), expanded=expanded, restored=restored)
        # Relaunch >=3 panes with nonuniform fractions, vertical layout and non-first focus.
        key('3'); persisted = settled(4); app.call('menu-perform', id='expand-current-split'); settled(4); app.call('save'); app.quit()
        # The idle observer is only for the pre-quit work-count gate. A new
        # observer starts armed to catch eager work; do not inject it into the
        # relaunched process used for uninstrumented Release latency.
        app = factory(urls=()); relaunched = settled(4)
        ok, pages = live(ids)
        row('relaunch_orientation_fractions_focus', ok and relaunched['id'] == persisted['id']
            and relaunched['orientation'] == 'vertical' and relaunched['fractions'] == persisted['fractions']
            and relaunched['focused'] == persisted['focused'] and not relaunched['maximized'], before=persisted, after=relaunched, pages=pages)
        menu('Convert to Horizontal Split View'); settled(4)
        app.call('window-frame', frame=[60, 60, 900, 700]); narrow = settled(4)
        widths = [p['frame'][2] for p in narrow['panes']]
        row('narrow_equal_scaling', narrow['container'][2] < 800 and max(widths)-min(widths) <= 1
            and max(widths) < 200 and geometry(narrow, 'horizontal', 4), state=narrow)
        app.call('window-frame', frame=[60, 60, 1360, 860], unconstrained=True); settled(4)
        # Closing the focused third pane keeps a split with a valid focused survivor.
        closed = state()['focused']; key('-'); s = settled(3)
        row('close_focused_pane', closed not in [p['id'] for p in s['panes']] and s['focused'] == s['panes'][0]['id']
            and any(r['id'] == closed for r in app.call('archive')), state=s)
        separated = s['focused']; app.call('menu-perform', id='separate-from-split-view'); s = settled(1)
        tree = app.call('sidebar-tree'); remaining = next(n for n in tree['today'] if n['kind'] == 'split')
        row('separate_focused_pane', s['focused'] == separated and any(n['id'] == separated for n in tree['today'])
            and len(remaining['children']) == 2, tree=tree, state=s)
        # Select the remaining split through the real sidebar and close it down to one.
        app.call('sidebar-click', node=remaining['id']); s = settled(2)
        survivor = next(p['id'] for p in s['panes'] if p['id'] != s['focused'])
        app.call('focus', tab=s['focused']); key('-'); s = settled(1)
        row('collapse_two_to_one_selection', not s['id'] and s['focused'] == survivor and s['selected'] == survivor, state=s)
        # Separate All retains all tabs and selects its previously focused pane.
        a = opened('all-a'); b = opened('all-b'); select(a); app.call('sidebar-menu', node=b, item='Open in Split View'); s = settled(2)
        all_ids = {p['id'] for p in s['panes']}; focused = s['focused']
        app.eval(focused, "window.__splitRemoveResize=[];addEventListener('resize',()=>__splitRemoveResize.push([innerWidth,innerHeight]));true")
        app.call('sidebar-menu', node=s['id'], item='Separate All Tabs'); after = settled(1)
        remove_resizes = app.eval(focused, 'window.__splitRemoveResize')
        row('remove_resizes_web_once', len(remove_resizes) <= 1, sizes=remove_resizes)
        row('separate_all', after['focused'] == focused and not after['id'] and all_ids.issubset({n['id'] for n in app.call('sidebar-tree')['today']}), state=after)
        select(a); app.call('sidebar-menu', node=b, item='Open in Split View'); s = settled(2)
        removed = s['focused']; survivor = next(p['id'] for p in s['panes'] if p['id'] != removed)
        app.call('menu-perform', id='separate-from-split-view'); separate_two = settled(1)
        row('separate_two_to_one_selection', not separate_two['id'] and separate_two['focused'] == survivor
            and {removed, survivor}.issubset({n['id'] for n in app.call('sidebar-tree')['today']}), state=separate_two)
        # Option-click on a real pane close control unsplits without archiving.
        select(a); app.call('sidebar-menu', node=b, item='Open in Split View'); s = settled(2)
        p = s['panes'][0]['frame']; before_archive = len(app.call('archive'))
        app.call('mouse', action='click', x=p[0]+p[2]-21, y=p[1]+16, modifiers=['option'], queued=True)
        option = settled(1)
        row('option_close_unsplits', not option['id'] and len(app.call('archive')) == before_archive, state=option)
        # Release timing gate, interleaved single→single and single→split, warm live hosts.
        first = opened('bench-first'); second = opened('bench-second')
        third = opened('bench-third'); app.call('sidebar-menu', node=b, item='Open in Split View'); s = settled(2)
        live([p['id'] for p in s['panes']])
        if lane == 'observers':
            pass  # Pixels and strict timing belong to the uninstrumented merge lane.
        elif functional_only:
            results['speed_tab_switch']=dict(status='DEFERRED', reason='M5 timing receipt required (TANDEM §4M)')
        else:
            app.begin_timing('split switch benchmark')
            measured = app.call('split', op='bench', nodes=[first, second, s['id']])
            summaries = {}
            for name, values in measured.items():
                summaries[name] = dict(median=statistics.median(values), p95=sorted(values)[math.ceil(len(values)*.95)-1])
            row('speed_tab_switch', all(summaries[name]['p95'] <= 25 for name in ('single', 'split')), timing=True, functionalOK=bool(measured), loadAverage=list(os.getloadavg()), uptime=subprocess.check_output(['uptime'], text=True).strip(),
                milliseconds=summaries, samples=measured, target_ms=16, target_met=all(summaries[name]['p95'] <= 16 for name in ('single', 'split')), absolute_ceiling_ms=25, relative_gate='separate interleaved main/branch receipt: branch <= main + 1 ms on both paths', scope='production sidebar selection through native layout/CA submission and first rAF after fresh visibilitychange in every shown pane (last pane wins), native layout/CA flush return; query return retained separately; excludes physical presentation')
        app.begin_timing('split motion probe')
        motion = app.call('split', op='bench', nodes=[first, second, s['id']], motionOnly=True)
        unexpected = [animation for case in motion['motion'] for animation in case['animations']
                      if animation['layer'].endswith('.focusRing') and animation['keyPath'] in ('bounds', 'position')]
        row('pane_motion_no_extra_ring_animation', not unexpected, motion=motion, unexpected=unexpected)
        # E5: the production sleep controller protects shown panes, freezes and
        # discards a hidden split, then wakes both real pages with history intact.
        sleep_split = state(); sleep_ids = [p['id'] for p in sleep_split['panes']]; focus = sleep_split['focused']
        app.call('navigate', tab=focus, url=origin+'/sleep-back'); app.call('wait', tab=focus)
        app.call('navigate', tab=focus, url=origin+'/sleep-current'); app.call('wait', tab=focus)
        urls = {tid: app.tab(tid)['url'] for tid in sleep_ids}
        app.call('sleep-mode', mode='balanced'); app.call('sleep-start')
        protected = [app.call('sleep-now', tab=tid)['refusedBy'] for tid in sleep_ids]
        row('E5_visible_panes_protected', protected == ['visible']*2, gates=protected)
        select(first); app.call('sleep-tick'); app.call('sleep-clock', advance=30.0); app.call('sleep-tick')
        frozen = [app.call('sleep-state', tab=tid)['tabs'][0]['phase'] for tid in sleep_ids]
        row('E5_hidden_split_freezes', frozen == ['frozen']*2, phases=frozen)
        app.call('sleep-clock', advance=270.0); app.call('sleep-tick')
        for tid in sleep_ids: app.call('sleep-now', tab=tid)
        sleeping = [app.call('sleep-state', tab=tid)['tabs'][0]['phase'] for tid in sleep_ids]
        row('E5_hidden_split_discards', sleeping == ['sleeping']*2, phases=sleeping)
        app.call('sidebar-click', node=sleep_split['id']); settled(2)
        woke, pages = live(sleep_ids)
        restored_urls = {tid: app.tab(tid)['url'] for tid in sleep_ids}
        app.call('menu-perform', id='go-back'); app.call('wait', tab=focus)
        row('E5_wake_keeps_history', woke and restored_urls == urls and app.tab(focus)['url'].endswith('/sleep-back'), pages=pages, urls=restored_urls)
        app.call('sleep-clock', reset=True)
        unsplit(); favorite = opened('favorite'); app.call('favorite', tab=favorite); settled(1)
        favorite_menu = app.call('split', op='plus'); before = len(app.call('tabs'))
        app.call('focus', tab=favorite); key('='); s = settled(1)
        row('favorite_split_disabled_no_orphan', not next(r['enabled'] for r in favorite_menu if r['title'] == 'New Split')
            and len(app.call('tabs')) == before and not s['id'], menu=favorite_menu, state=s)
        retained = []
        for i in range(12):
            opened('slot-cache-'+str(i)); retained.append(state()['retainedSlots'])
        row('slot_cache_bounded', max(retained) <= 9, retainedSlots=retained, hiddenLimit=8)
    finally:
        try:
            h._restore_defaults(app, saved)
        finally:
            app.quit(); server.shutdown(); server.server_close()
