"""Section 4 real-App theme flows. Socket input stays inside Open's windows.

No defaults keys are written by this suite. Fixtures and captures contain only
synthetic data. Siblings can extend this suite with the icon/create rows.
"""
import copy
import json
import time
import uuid
from pathlib import Path


def run(factory, results, scratch, root, wait_until, read_image, delta_e):
    output = Path(root, '.re', 'space-editor', str(uuid.uuid4()))
    output.mkdir(parents=True)
    data = json.loads(Path(root, 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json').read_text())
    tabs = {}
    for space in data['spaces'][:2]:
        tab = next(node['tab']['_0'] for node in space['pinned'] if 'tab' in node)
        tab['url'] = 'data:text/html,%3Chtml%20style%3D%22background%3Awhite%3Bcolor-scheme%3Alight%22%3E%3C%2Fhtml%3E'
        tab['pinnedURL'] = tab['url']; tab['title'] = 'Theme backdrop'
        tabs[space['id']] = tab['id']
    template = data['windows'][0]
    data['windows'] = []
    for index in range(3):
        window = copy.deepcopy(template)
        space = data['spaces'][index // 2]['id']
        window.update(id=str(uuid.uuid4()).upper(), focusedSpaceID=space,
                      frameWidth=1280, frameHeight=800, frameX=40 + index * 24,
                      frameY=80 + index * 24, sidebarWidth=500,
                      selectedNodeBySpace={space: tabs[space]})
        data['windows'].append(window)
    fixture = Path(scratch, 'space-editor.json'); fixture.write_text(json.dumps(data))
    app = factory(urls=(), snapshot=str(fixture))
    try:
        app.call('appearance', name='dark')
        windows = app.call('shell-windows'); owner, other, third = windows
        app.call('window-focus', id=owner['id'], activate=True)
        space = data['spaces'][0]['id']
        assert wait_until(lambda: app.eval(tabs[space], "document.readyState === 'complete'"), timeout=10, step=.02)
        # Seed through the new session API; the first pad pick gets the F0137 state.
        app.call('theme-set', space=space, style=None)

        def state(): return app.call('editor-state')
        def theme(): return app.call('theme-get', space=space)['style']
        def closed(): return not state()['open']
        def open_editor():
            app.call('window-focus', id=owner['id'], activate=True)
            app.call('command', id='edit-theme')
            assert wait_until(lambda: state()['open'], timeout=3, step=.02)
            time.sleep(.6)
            return state()
        def capture(name, window):
            path = output / (name + '.png')
            app.call('snapshot', path=str(path), window=window)
            return str(path)
        def sample(path):
            width, height, pixel = read_image(path)
            return [pixel(x * width / 1280, y * height / 800) for x, y in [(30, 550), (80, 570), (160, 590)]]
        def key(name, modifiers=(), window=None):
            return app.call('key', key=name, modifiers=list(modifiers), route='app', **({'window': window} if window else {}))

        editor = open_editor()
        app.call('editor-act', action='key', key='return')
        results['return_keeps_editor'] = dict(ok=state()['open'])
        number = editor['window']
        app.call('editor-act', action='click', x=223.5, y=222.5)
        first = wait_until(theme, timeout=3, step=.02)
        assert first, 'first pad pick did not reach model'
        app.call('editor-close')
        app.call('theme-set', space=space, style=first)
        editor = open_editor(); number = editor['window']
        png = capture('A1-editor', 'editor')
        width, height, pixel = read_image(png)
        frame = state()['frame']
        owner_frame = app.call('window-state')['frame']
        # Owner frame is [x,y,width,height] in screen coordinates.
        results['A1_panel_structure'] = dict(ok=frame[2:] == [382, 534] and abs(frame[0] - owner_frame[0] - 500) <= .5
            and abs(owner_frame[1] + owner_frame[3] - frame[1] - 534 - 35) <= .5
            and width >= 382 and height >= 534 and len({pixel(x * width / 382, y * height / 534) for x in range(30, 350, 20) for y in range(30, 500, 20)}) > 20,
            frame=frame, owner=owner_frame, pixels=[width, height], artifact=str(output.relative_to(root)))
        base_frame = app.call('window-state')['frame']
        panel_before = state()['frame']
        app.call('window-frame', frame=[base_frame[0] + 20, base_frame[1] + 20, base_frame[2], base_frame[3]])
        moved = state()['frame']
        results['owner_move_anchor'] = dict(ok=abs(moved[0] - panel_before[0] - 20) <= .5 and abs(moved[1] - panel_before[1] - 20) <= .5)
        app.call('window-frame', frame=base_frame)
        screens = state()['screens']; scale_before = state()['scale']
        other_screen = next((s for s in screens if s['scale'] != scale_before), None)
        if other_screen:
            f = other_screen['frame']
            app.call('window-frame', frame=[f[0] + 20, f[1] + 20, 1280, 800])
            follows = wait_until(lambda: state()['scale'] == other_screen['scale'] == state()['ownerScale'], timeout=3, step=.02)
            scale_png = capture('editor-backing-scale', 'editor')
            scale_width, scale_height, _ = read_image(scale_png)
            results['backing_scale_follows'] = dict(ok=bool(follows) and scale_width == 382 * other_screen['scale'] and scale_height == 534 * other_screen['scale'],
                scales=[scale_before, other_screen['scale']], pixels=[scale_width, scale_height])
            app.call('window-frame', frame=base_frame)
            assert wait_until(lambda: state()['scale'] == scale_before, timeout=3, step=.02)
        else:
            results['backing_scale_follows'] = dict(ok=state()['scale'] == state()['ownerScale'], scales=[scale_before], note='one backing scale available; live scale transition unverified')
        app.call('editor-open', kind='theme', space=space)
        results['same_space_refocus'] = dict(ok=state()['window'] == number)
        results['unknown_kind_refused'] = dict(ok=app.call('editor-open', kind='unknown') is False and state()['window'] == number)
        refused = False
        try: app.call('editor-act', action='drag', **{'from': [40, 500], 'to': [40, 500], 'steps': 241})
        except RuntimeError as error: refused = 'steps must be 1...240' in str(error)
        results['drag_limit_refused'] = dict(ok=refused)
        accepted = app.call('editor-act', action='drag', **{'from': [40, 500], 'to': [40, 500], 'steps': 240})
        results['drag_limit_accepted'] = dict(ok=accepted is True)
        idle_before = state(); time.sleep(.12); idle_after = state()
        results['idle_open_at_rest'] = dict(ok=idle_after['displayLinks'] == 0 and not idle_after['pendingFrame']
            and idle_before['frames'] == idle_after['frames'] and idle_before['previews'] == idle_after['previews'], before=idle_before, after=idle_after)
        before = [capture('A2-before-' + str(i), w['number']) for i, w in enumerate(windows)]
        counters = app.call('frame-save-counters')
        knob_before = state()['knob']
        knob_rect = state()['controls']['knob']
        start = [knob_rect[0] + knob_rect[2] / 2 + 13, knob_rect[1] + knob_rect[3] / 2 + 13]
        app.call('editor-act', action='drag', **{'from': start, 'to': [105, 235], 'steps': 16})
        edited = wait_until(lambda: (lambda s: s if s != first else None)(theme()), timeout=3, step=.02)
        assert edited, 'drag did not reach model'
        wait_until(lambda: state()['displayLinks'] == 0, timeout=3, step=.02)
        after = [capture('A2-after-' + str(i), w['number']) for i, w in enumerate(windows)]
        old_pixels, new_pixels = list(map(sample, before)), list(map(sample, after))
        results['A2_three_windows'] = dict(ok=all(old_pixels[i] != new_pixels[i] for i in range(2)) and old_pixels[2] == new_pixels[2],
            sameSpaceChanged=[old_pixels[i] != new_pixels[i] for i in range(2)], otherSpaceUnchanged=old_pixels[2] == new_pixels[2])
        scheduled = app.call('frame-save-counters')['scheduled'] - counters['scheduled']
        results['gesture_one_save'] = dict(ok=scheduled == 1, scheduled=scheduled)
        knob_edited = state()['knob']
        app.call('editor-act', action='key', key='z', modifiers=['cmd'])
        wait_until(lambda: theme() == first and state()['knob'] == knob_before, timeout=3, step=.02)
        undo, knob_undo = theme(), state()['knob']
        app.call('editor-act', action='key', key='z', modifiers=['cmd', 'shift'])
        wait_until(lambda: theme() == edited and state()['knob'] == knob_edited, timeout=3, step=.02)
        redo, knob_redo = theme(), state()['knob']
        results['A3_open_undo_redo'] = dict(ok=undo == first and redo == edited and knob_undo == knob_before and knob_redo == knob_edited, styleUndo=undo == first, styleRedo=redo == edited, before=knob_before, edited=knob_edited, undo=knob_undo, redo=knob_redo)
        app.call('editor-act', action='click', x=243.032, y=465)
        immediate_end = theme()
        wait_until(lambda: state()['displayLinks'] == 0, timeout=3, step=.02)
        near_end = theme()
        app.call('editor-act', action='hover', x=243.032, y=465)
        app.call('editor-act', action='click', x=256, y=465)
        at_end = wait_until(lambda: (lambda s: s if s['intensityFactor'] == 1 else None)(theme()), timeout=2, step=.02)
        results['thumb_overhang_hit_path'] = dict(ok=abs(near_end['intensityFactor'] - .98) < .01 and at_end is not None,
            before=near_end['intensityFactor'], after=theme()['intensityFactor'], immediate=immediate_end['intensityFactor'])
        app.call('editor-act', action='key', key='escape')
        assert wait_until(closed, timeout=3, step=.02)
        key('z', ['cmd'], owner['number']); closed_undo = theme()
        key('z', ['cmd', 'shift'], owner['number']); closed_redo = theme()
        results['A3_closed_undo_redo'] = dict(ok=abs(closed_undo['intensityFactor'] - .98) < .01
            and closed_redo['intensityFactor'] == 1 and closed(), undo=closed_undo['intensityFactor'], redo=closed_redo['intensityFactor'])
        results['idle_closed'] = dict(ok=state()['displayLinks'] == 0)
        # Save/relaunch uses the normal persisted snapshot, not a theme fixture.
        persisted = theme(); saved = Path(scratch, 'theme-persisted.json')
        time.sleep(.35)
        expected_pixels = sample(capture('A4-before', owner['number']))
        app.quit()
        saved.write_bytes(Path(app.user_data, 'State', 'browser.json').read_bytes())
        app = factory(urls=(), snapshot=str(saved))
        app.call('appearance', name='dark'); app.call('window-focus', id=owner['id'], activate=True)
        assert wait_until(lambda: app.eval(tabs[space], "document.readyState === 'complete'"), timeout=10, step=.02)
        time.sleep(.35)
        actual_pixels = sample(capture('A4-after', app.call('shell-windows')[0]['number']))
        errors = [delta_e(a, b) for a, b in zip(expected_pixels, actual_pixels)]
        results['A4_persistence'] = dict(ok=theme() == persisted and max(errors) <= 1,
            deltaE00=errors, styleEqual=theme() == persisted)
        owner = next(w for w in app.call('shell-windows') if w['id'] == owner['id'])
        p = open_editor(); original = theme()
        app.call('editor-act', action='down', x=130, y=220)
        app.call('editor-act', action='drag', x=120, y=250)
        app.call('editor-act', action='key', key='escape')
        results['E8_escape_mid_drag'] = dict(ok=wait_until(closed, timeout=3, step=.02) and theme() != original)
        p = open_editor()
        app.call('mouse', window=owner['number'], action='click', x=700, y=650, queued=True)
        results['E8_outside_click'] = dict(ok=bool(wait_until(closed, timeout=3, step=.02)))
        for name in ['t', 'l', 'w']:
            if name == 'w': app.call('open', url='data:text/html,Theme-close-fixture')
            p = open_editor()
            before_tabs = len(app.call('tabs'))
            app.call('editor-act', action='key', key=name, modifiers=['cmd'])
            shut = bool(wait_until(closed, timeout=3, step=.02))
            normal = (len(app.call('tabs')) < before_tabs) if name == 'w' else app.call('commandbar-state')['presented']
            results['E8_cmd_' + name] = dict(ok=shut and normal)
            if name != 'w': key('escape', window=owner['number'])
        p = open_editor()
        peer = app.foreground_peer()
        try:
            app.accept_owned_handoff(peer)
            results['E8_deactivation'] = dict(ok=bool(wait_until(closed, timeout=3, step=.02)))
        finally: peer.quit()
        app.call('window-focus', id=owner['id'], activate=True)
        p = open_editor(); app.call('space', space=data['spaces'][1]['id'])
        results['E8_space_switch'] = dict(ok=bool(wait_until(closed, timeout=3, step=.02)))
        # Context-menu path, plus retarget from a different Space without an undo step.
        app.call('editor-open', kind='theme', space=space)
        results['context_target_focus'] = dict(ok=state()['space'] == space and app.call('window-state')['space'] == space)
        target_panel = state()['window']
        app.call('editor-open', kind='theme', space=data['spaces'][1]['id'])
        results['retarget_same_panel'] = dict(ok=state()['window'] == target_panel and state()['space'] == data['spaces'][1]['id'])
        app.call('editor-open', kind='theme', space=space)
        app.call('editor-close')
        app.call('command', id='search-actions')
        app.call('key', text='Edit Theme', route='app')
        bar = wait_until(lambda: (lambda b: b if b.get('final') and any(r.get('action') == 'edit-theme' for r in b.get('rows', [])) else None)(app.call('commandbar-state')), timeout=5, step=.02)
        app.call('key', key='return', route='app')
        results['commandbar_edit_theme'] = dict(ok=bool(bar) and bool(wait_until(lambda: state()['open'], timeout=3, step=.02)))
        app.call('editor-close')
        app.call('sidebar-menu', item='Edit Theme Color…')
        results['context_menu_entry'] = dict(ok=state()['open'])
        app.call('editor-close')
        app.call('command', id='toggle-sidebar'); p = open_editor()
        wf = app.call('window-state')['frame']
        results['hidden_sidebar_anchor'] = dict(ok=abs(p['frame'][0] - wf[0] - 8) <= .5)
        app.call('editor-close'); app.call('command', id='toggle-sidebar')
        doomed = app.call('space-create', title='Editor deletion fixture')
        app.call('space', space=doomed); p = open_editor()
        app.call('sidebar-menu', item='Delete Space'); app.call('alert', button='Delete')
        results['E8_space_delete'] = dict(ok=bool(wait_until(closed, timeout=3, step=.02)) and doomed not in [s['id'] for s in app.call('spaces')])
        p = open_editor(); app.call('window-close')
        # editor-state now targets another surviving browser window.
        results['E8_owner_close'] = dict(ok=bool(wait_until(lambda: all(not (w['class'] == 'ThemeEditorPanel' and w['visible']) for w in app.call('windows')), timeout=3, step=.02)))
        owner = app.call('shell-windows')[0]
        app.call('window-focus', id=owner['id'], activate=True)
        p = open_editor(); target_space = state()['space']
        app.call('editor-act', action='down', x=120, y=225)
        app.call('editor-act', action='drag', x=155, y=205)
        expected_final_style = state()['style']
        app.quit()
        final = json.loads(Path(app.user_data, 'State', 'browser.json').read_text())
        final_style = next(s['theme'].get('style') for s in final['spaces'] if s['id'] == target_space)
        results['E8_termination_commits'] = dict(ok=final_style == expected_final_style and not app.quit_report.get('forced', False))
    finally:
        app.quit()
