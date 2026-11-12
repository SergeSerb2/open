"""Real App Easels (milestone E1): New Easel entry points, canvas tools, colours, text,
move/resize, undo/redo, context menus, zoom, title, persistence across a relaunch.

Only the automation socket is used. The `easel` command dispatches real NSEvents through the
window and presses the real toolbar buttons. No global input, no real user data.
"""
import json
import os
import plistlib
import subprocess
import time
from pathlib import Path


def run(factory, results, tmp, api):
    root = Path(api.ROOT)
    frames_dir = Path(os.environ.get('OPEN_E2E_EASEL_FRAMES', str(root / '.re/ez/frames')))
    frames_dir.mkdir(parents=True, exist_ok=True)
    app = None

    def record(name, ok, **details):
        results[name] = dict(ok=bool(ok), **details)

    def easel(**kw):
        return app.call('easel', **kw)

    def canvas(state=None):
        return (state or easel())['canvas']

    def objects(state=None):
        return canvas(state)['objects']

    def close(a, b, eps=0.01):
        return all(abs(x - y) <= eps for x, y in zip(a, b))

    def snapshot(name):
        path = str(frames_dir / (name + '.png'))
        app.call('snapshot', path=path)
        return path

    # Per-tool colours are a user preference (Arc's rectangleColor & co.): start from the defaults.
    domain = 'io.github.sergeserb2.open'
    color_keys = ['open.easel.color.' + k for k in ('rectangle', 'circle', 'arrow', 'freehand')]
    exported = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
    saved_prefs = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    for key in color_keys:
        subprocess.run(['defaults', 'delete', domain, key], capture_output=True)
    try:
        app = factory(urls=('about:blank',), fresh=True)
        blank = app.call('tabs')[0]['id']
        app.call('wait', tab=blank)
        app.call('window-frame', frame=[60, 60, 1280, 800])

        # E01: File ▸ New Easel (menu item) adds a selected Easel row at the top of Today.
        before = app.call('tabs')
        app.call('menu-perform', id='new-easel')
        s = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(easel()), timeout=5, step=.1)
        tabs = app.call('tabs')
        tab = app.call('tab-state', tab=s['tab']) if s else {}
        c = canvas(s) if s else {}
        labels = [b['label'] for b in c.get('toolbarButtons', [])]
        record('E01_new_easel_menu', s and len(tabs) == len(before) + 1 and tabs[0]['id'] == s['tab']
               and s['url'].startswith('open://easel/') and s['tabTitle'] == 'Untitled Easel' and s['favicon']
               and tab.get('selected') and tab.get('section') == 'today' and s['fileExists']
               and c['titleFieldText'] == '' and c['titlePlaceholder'] == 'Untitled Easel'
               and labels == ['Pointer', 'Image', 'Text', 'Ellipse', 'Rectangle', 'Arrow', 'Freehand']
               and c['tool'] == 'pointer' and c['toolbarButtons'][0]['selected'] and c['objects'] == [],
               state=s, tab=tab)
        record('E02_never_engine', s and s['engineContentCreationCount'] == easel()['engineContentCreationCount']
               and 'page' not in tab and not tab.get('loaded'), tab=tab)
        first = s['tab']
        # Toolbar geometry (C-measurements-s4): 36-pt buttons at a 38-pt pitch, 10 pt from the page's left.
        frames = [b['frame'] for b in c['toolbarButtons']]
        record('E03_toolbar_geometry', all(f[2] == 36 and f[3] == 36 for f in frames)
               and all(abs((frames[i + 1][0] - frames[i][0]) - 38) < 0.01 for i in range(6))
               and abs(frames[0][0] - 10) < 0.01, frames=frames, toolbar=c['toolbarFrame'])

        # E04: ⌃⇧E (the real key path) and the "+" menu row both make another Easel.
        count = len(app.call('tabs'))
        app.call('key', key='e', modifiers=['ctrl', 'shift'], route='app')
        by_key = api.wait_until(lambda: len(app.call('tabs')) == count + 1 or None, timeout=5, step=.1)
        plus_items = [i['title'] for i in app.call('split', op='plus')]
        app.call('split', op='plus', item='New Easel')
        by_plus = api.wait_until(lambda: len(app.call('tabs')) == count + 2 or None, timeout=5, step=.1)
        tabs = app.call('tabs')
        record('E04_shortcut_and_plus_menu', by_key and by_plus and 'New Easel' in plus_items
               and all(t['url'].startswith('open://easel/') for t in tabs[:2]), plusItems=plus_items, tabs=tabs[:3])
        for t in tabs[:2]:
            app.call('close', tab=t['id'])
        app.call('select', tab=first)
        api.wait_until(lambda: easel(tab=first).get('shown') or None, timeout=5, step=.1)

        # E05: Rectangle tool: drag draws, the shape stays selected with the colour popover,
        # default colour lightGreen, tool returns to Pointer.
        easel(action='tool', tool='rectangle')
        s = easel(action='drag', **{'from': [100, 200], 'to': [360, 400]})
        o = objects(s)
        rect = o[-1] if o else {}
        record('E05_rectangle', len(o) == 1 and rect['kind'] == 'rectangle' and rect['color'] == 'lightGreen'
               and close(rect['frame'], [100, 200, 260, 200]) and canvas(s)['selection'] == [rect['id']]
               and canvas(s)['popoverShown'] and canvas(s)['popoverColor'] == 'lightGreen' and canvas(s)['tool'] == 'pointer',
               state=canvas(s))
        snapshot('e05-rect-selected-light')

        # E06: a swatch recolours the selected shape.
        s = easel(action='swatch', color='purple')
        record('E06_swatch', objects(s)[-1]['color'] == 'purple' and canvas(s)['popoverColor'] == 'purple', state=canvas(s))

        # E07: Ellipse, Arrow, Freehand with their default colours.
        easel(action='tool', tool='ellipse'); easel(action='drag', **{'from': [450, 200], 'to': [650, 400]})
        easel(action='tool', tool='arrow'); easel(action='drag', **{'from': [700, 420], 'to': [900, 220]})
        easel(action='tool', tool='freehand'); s = easel(action='drag', wave=True, steps=24, **{'from': [100, 500], 'to': [400, 500]})
        kinds = [(x['kind'], x.get('color')) for x in objects(s)]
        record('E07_shapes', kinds == [('rectangle', 'purple'), ('circle', 'red'), ('arrow', 'lightBlue'), ('freehand', 'black')]
               and objects(s)[3].get('pointCount', 0) >= 10, kinds=kinds, objects=objects(s))

        # E08: Text tool: a click places a box in edit mode with the placeholder; typing and a
        # click on the empty canvas commit it.
        easel(action='tool', tool='text')
        s = easel(action='click', at=[520, 560])
        editing = canvas(s)['editingText']
        s = easel(action='type', text='Trip ideas')
        typed = canvas(s)['editorText']
        s = easel(action='click', at=[960, 150])
        texts = [x for x in objects(s) if x['kind'] == 'text']
        record('E08_text', editing and typed == 'Trip ideas' and len(texts) == 1 and texts[0]['text'] == 'Trip ideas'
               and texts[0]['paragraphStyle'] == 'body' and canvas(s)['editingText'] is None
               and canvas(s)['undoName'] == 'Add Text', state=canvas(s))
        # An empty text box leaves nothing behind and no undo step.
        undo_before = canvas(s)['undoName']
        easel(action='tool', tool='text'); easel(action='click', at=[700, 600])
        s = easel(action='click', at=[960, 150])
        record('E09_empty_text_discarded', len([x for x in objects(s) if x['kind'] == 'text']) == 1
               and canvas(s)['undoName'] == undo_before, state=canvas(s))

        # E10: move by drag, then resize from the bottom-right handle.
        rect_id = objects(s)[0]['id']
        easel(action='click', at=[200, 300])
        s = easel(action='drag', **{'from': [200, 300], 'to': [250, 340]})
        moved = next(x for x in objects(s) if x['id'] == rect_id)
        record('E10_move', close(moved['frame'], [150, 240, 260, 200]) and canvas(s)['undoName'] == 'Move', frame=moved['frame'])
        s = easel(action='drag', **{'from': [410, 440], 'to': [450, 480]})
        resized = next(x for x in objects(s) if x['id'] == rect_id)
        record('E11_resize', close(resized['frame'], [150, 240, 300, 240]) and canvas(s)['undoName'] == 'Resize', frame=resized['frame'])

        # E12: undo/redo through the Edit menu action on the canvas undo stack.
        s = easel(action='undo')
        after_undo = next(x for x in objects(s) if x['id'] == rect_id)['frame']
        s = easel(action='redo')
        after_redo = next(x for x in objects(s) if x['id'] == rect_id)['frame']
        record('E12_undo_redo', close(after_undo, [150, 240, 260, 200]) and close(after_redo, [150, 240, 300, 240]),
               undo=after_undo, redo=after_redo)

        # E13: context menus (C-measurements-s4) and their actions.
        object_menu = easel(action='menu', at=[200, 300])
        canvas_menu = easel(action='menu', at=[960, 150])
        record('E13_menus', object_menu == ['Bring to Front', 'Send to Back', 'Delete', '—', 'Cut', 'Copy', 'Paste', '—', 'Duplicate']
               and canvas_menu[:3] == ['Paste', '—', 'Color Palette ▸'], objectMenu=object_menu, canvasMenu=canvas_menu)
        z_before = {x['id']: x['zIndex'] for x in objects()}
        s = easel(action='menu', at=[200, 300], item='Bring to Front')
        top = max(objects(s), key=lambda x: x['zIndex'])
        s = easel(action='menu', at=[200, 300], item='Duplicate')
        dup_count = len(objects(s))
        s = easel(action='key', key='delete')
        record('E14_menu_actions', top['id'] == rect_id and top['zIndex'] > max(z_before.values())
               and dup_count == 6 and len(objects(s)) == 5, top=top, count=len(objects(s)))
        s = easel(action='menu', at=[960, 150], item='Color Palette', submenu='Chill')
        record('E15_palette', canvas(s)['palette'] == 'chill', state=canvas(s)['palette'])

        # E16: the title edits the sidebar row too.
        s = easel(action='title', text='Trip board')
        record('E16_title', canvas(s)['title'] == 'Trip board' and s['tabTitle'] == 'Trip board'
               and app.call('tab-state', tab=first)['title'] == 'Trip board', state=s)

        # E17: View ▸ Zoom Out/In/Actual Size zoom the canvas in steps (min ≈ 33 %).
        zooms = []
        for _ in range(4):
            app.call('menu-perform', id='zoom-out'); zooms.append(canvas()['zoom'])
        app.call('menu-perform', id='zoom-actual-size'); reset = canvas()['zoom']
        app.call('menu-perform', id='zoom-in'); zin = canvas()['zoom']
        app.call('menu-perform', id='zoom-actual-size')
        record('E17_zoom', [round(z, 2) for z in zooms] == [0.75, 0.5, 0.33, 0.33] and reset == 1 and zin == 1.25,
               zooms=zooms, reset=reset, zoomIn=zin)

        # Frames for the look review: light and dark, with a selected shape.
        easel(action='click', at=[500, 300])
        snapshot('e18-canvas-light')
        app.call('appearance', name='dark')
        time.sleep(.5)
        snapshot('e18-canvas-dark')
        app.call('appearance', name='light')
        easel(action='tool', tool='text'); easel(action='click', at=[520, 760])
        snapshot('e18-text-editing-light')
        easel(action='key', key='escape')

        # E19: persistence. Quit, relaunch on the same data: every frame, colour, z, title and
        # the palette come back exactly; nothing loads until the Easel is selected.
        final = easel(action='flush')
        # Leave a web tab selected, so the relaunch shows that nothing Easel loads until selected.
        app.call('select', tab=blank)
        stored = app.call('easel', action='store', document=final['document'])
        saved = sorted((x['id'], x['kind'], x.get('color'), tuple(x['frame']), x['zIndex'], x.get('text')) for x in objects(final))
        record('E19_file', stored['exists'] and len(stored['json']['objects']) == len(saved)
               and stored['json']['title'] == 'Trip board' and stored['json']['palette'] == 'chill', path=stored.get('path'))
        app.quit(); app = None
        app = factory(urls=(), fresh=False)
        restored_tab = next((t for t in app.call('tabs') if t['id'] == first), None)
        unshown = easel(tab=first) if restored_tab else {}
        app.call('select', tab=first)
        s = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(easel(tab=first)), timeout=8, step=.1)
        again = sorted((x['id'], x['kind'], x.get('color'), tuple(x['frame']), x['zIndex'], x.get('text')) for x in objects(s)) if s else []
        record('E19_relaunch_restores', restored_tab and not unshown.get('shown') and unshown.get('hostCount') == 0
               and s and again == saved and s['tabTitle'] == 'Trip board' and canvas(s)['palette'] == 'chill'
               and not s['recreated'] and s['favicon'], saved=saved, restored=again, unshown=unshown,
               state={k: v for k, v in (s or {}).items() if k != 'canvas'})

        # E20: a corrupt document file is refused, kept aside, and the row opens a fresh Easel.
        created = easel(action='create')
        bad = easel(tab=created['tab'])
        path = Path(app.call('easel', action='store', document=bad['document'])['path'])
        app.call('select', tab=blank)
        app.quit(); app = None
        path.write_text('{"formatVersion": 1, "objects": [')
        app = factory(urls=(), fresh=False)
        app.call('select', tab=created['tab'])
        s = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(easel(tab=created['tab'])), timeout=8, step=.1)
        aside = sorted(p.name for p in path.parent.glob('document.refused-*.json'))
        record('E20_corrupt_file_set_aside', s and s['recreated'] and objects(s) == [] and len(aside) == 1
               and (path.parent / aside[0]).read_text().startswith('{"formatVersion": 1'), aside=aside,
               state={k: v for k, v in (s or {}).items() if k != 'canvas'})
    finally:
        if app:
            app.quit()
        for key in color_keys:
            if saved_prefs.get(key) is None:
                subprocess.run(['defaults', 'delete', domain, key], capture_output=True)
            else:
                subprocess.run(['defaults', 'write', domain, key, '-string', saved_prefs[key]], capture_output=True)
