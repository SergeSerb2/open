"""Step 5: real browser/editor windows through existing automation commands.

This uses the generic menu, mouse, key, snapshot and save paths. The Step 8
editor-specific automation API and creation/icon flows remain deferred.
"""
import copy
import json
import os
import time
import uuid
from pathlib import Path


def run(factory, results, scratch, root, wait_until):
    output = Path(root, '.re', 'theme-live', str(uuid.uuid4()))
    output.mkdir(parents=True)
    data = json.loads(Path(root, 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json').read_text())
    data['spaces'][0]['theme'] = {'gradientStopsLight': [], 'gradientStopsDark': []}
    template = data['windows'][0]
    data['windows'] = []
    for index in range(3):
        window = copy.deepcopy(template)
        window.update(id=str(uuid.uuid4()).upper(), focusedSpaceID=data['spaces'][index // 2]['id'],
                      frameWidth=1280, frameHeight=800, frameX=40 + index * 24,
                      frameY=80 + index * 24, sidebarWidth=500, selectedNodeBySpace={})
        data['windows'].append(window)
    fixture = Path(scratch, 'theme-live.json')
    fixture.write_text(json.dumps(data))
    app = factory(urls=(), snapshot=str(fixture))
    try:
        app.call('appearance', name='dark')
        windows = app.call('shell-windows')
        owner, other, third = windows
        app.call('window-focus', id=owner['id'], activate=True)
        owner_state = app.call('window-state')
        results['three_real_windows'] = {'ok': len(windows) == 3 and owner_state['space'] == data['spaces'][0]['id']}

        def panel():
            return next((w for w in app.call('windows') if w['class'] == 'ThemeEditorPanel' and w['visible']), None)

        def opened():
            app.call('menu-perform', id='edit-theme')
            p = wait_until(panel, timeout=4, step=.02)
            assert p and p['parent'] == owner['number'], app.call('windows')
            time.sleep(0.6)  # Let the documented open spring settle before rest captures.
            return p

        def capture(name, number):
            path = output / (name + '.png')
            app.call('snapshot', path=str(path), window=number)
            return str(path)

        def saved_style():
            path = app.call('save')
            snapshot = json.loads(Path(path).read_text())
            return snapshot['spaces'][0]['theme'].get('style')

        before = [capture('window-before-' + str(i), w['number']) for i, w in enumerate(windows)]
        p = opened()
        results['menu_opens_editor'] = {'ok': bool(p) and p['key'], 'class': p['class'], 'parentMatches': p['parent'] == owner['number']}
        empty = capture('editor-empty-rest', p['number'])
        # First empty-pad pick reproduces F0137's full-range knob location.
        app.call('mouse', window=p['number'], action='click', x=223.5, y=222.5)
        first = wait_until(saved_style, timeout=4, step=.03)
        assert first, 'first pad pick did not reach model'
        rest = capture('editor-rest', p['number'])
        app.call('mouse', window=p['number'], action='hover', x=151, y=61)
        hovered = capture('editor-hover', p['number'])
        results['real_window_renders'] = {'ok': all(Path(f).stat().st_size > 0 for f in (empty, rest, hovered)),
                                          'artifacts': str(output.relative_to(root))}
        # Queued drag events use the real panel responder path.
        counters = app.call('frame-save-counters')
        app.call('mouse', window=p['number'], action='drag', **{'from': [223.5, 222.5], 'to': [105, 235]})
        edited = wait_until(lambda: (lambda s: s if s and s != first else None)(saved_style()), timeout=4, step=.02)
        assert edited, 'panel drag did not change the model'
        after = [capture('window-after-' + str(i), w['number']) for i, w in enumerate(windows)]
        # Image comparisons use decoded pixels, not PNG lengths or metadata.
        # Decode real window pixels with the existing e2e bitmap reader.
        from_pixels = globals()['read_image']
        def sample(path):
            width, height, pixel = from_pixels(path)
            return [pixel((x / 1280) * width, (y / 800) * height) for x, y in [(30, 500), (80, 600), (160, 650)]]
        old_pixels, new_pixels = list(map(sample, before)), list(map(sample, after))
        results['live_three_windows'] = {'ok': old_pixels[0] != new_pixels[0] and old_pixels[1] != new_pixels[1] and old_pixels[2] == new_pixels[2],
                                          'sameSpaceChanged': [old_pixels[i] != new_pixels[i] for i in range(2)], 'otherSpaceUnchanged': old_pixels[2] == new_pixels[2]}
        scheduled = app.call('frame-save-counters')['scheduled'] - counters['scheduled']
        results['one_drag_one_save_schedule'] = {'ok': scheduled == 1, 'scheduled': scheduled}
        app.call('key', window=p['number'], key='z', modifiers=['cmd'], route='app')
        undo = saved_style()
        app.call('key', window=p['number'], key='z', modifiers=['cmd', 'shift'], route='app')
        redo = saved_style()
        results['app_key_undo_redo'] = {'ok': undo == first and redo == edited}
        app.call('key', window=p['number'], key='escape', route='app')
        results['escape_closes_editor'] = {'ok': wait_until(lambda: not panel(), timeout=3, step=.02)}
        p = opened()
        app.call('key', window=p['number'], key='return', route='app')
        results['return_keeps_editor'] = {'ok': panel() is not None}
        app.call('key', window=p['number'], key='t', modifiers=['cmd'], route='app')
        results['cmd_t_editor_context'] = {'ok': wait_until(lambda: app.call('commandbar-state')['presented'], timeout=3, step=.02) and not panel()}
        app.call('key', key='escape', route='app')
        p = opened()
        app.call('key', window=p['number'], key='l', modifiers=['cmd'], route='app')
        results['cmd_l_editor_context'] = {'ok': wait_until(lambda: app.call('commandbar-state')['presented'], timeout=3, step=.02) and not panel()}
        app.call('key', key='escape', route='app')
        p = opened()
        app.call('space', space=data['spaces'][1]['id'])
        results['space_switch_closes_editor'] = {'ok': wait_until(lambda: not panel(), timeout=3, step=.02)}
        app.call('space', space=data['spaces'][0]['id'])
        p = opened()
        app.call('window-close')
        results['owner_close_closes_editor'] = {'ok': wait_until(lambda: not panel(), timeout=3, step=.02)}
        results['scope'] = {'status': 'PASS', 'note': 'Step 5 generic automation only; Step 8 theme/icon/create APIs are not added'}
    finally:
        app.quit()
