"""Real App Easels (milestone E1): New Easel entry points, canvas tools, colours, text,
move/resize, undo/redo, context menus, zoom, title, persistence across a relaunch.

Only the automation socket is used. The `easel` command dispatches real NSEvents through the
window and presses the real toolbar buttons. No global input, no real user data.
"""
import json
import os
import plistlib
import runpy
import subprocess
import time
from pathlib import Path
from loopback_http import LoopbackHTTPServer


def make_png(path, width, height, rgb):
    """A synthetic solid-colour PNG (no image library needed)."""
    import struct, zlib
    raw = b''.join(b'\x00' + bytes(rgb) * width for _ in range(height))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
    Path(path).write_bytes(png)
    return path


def fixture_server(root):
    """Serves a synthetic page with Open Graph tags and its picture."""
    import http.server, threading
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(root), **kw)
        def log_message(self, *a):
            pass
    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


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
    domain = __import__('prefs_domain').domain()
    color_keys = ['open.easel.color.' + k for k in ('rectangle', 'circle', 'arrow', 'freehand')] \
        + ['open.easel.liveWebCardEduSeen', 'open.easel.useAlignmentGuides', 'libraryShowsEasels']
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
        # "Aa" moves the box to the next face and keeps editing (C-report-s6 §1).
        s = easel(action='size', button='family')
        still_editing = canvas(s)['editingText'] == editing
        s = easel(action='click', at=[960, 150])
        texts = [x for x in objects(s) if x['kind'] == 'text']
        record('E08_text', editing and typed == 'Trip ideas' and len(texts) == 1 and texts[0]['text'] == 'Trip ideas'
               and texts[0]['paragraphStyle'] == 'body' and texts[0]['fontFamily'] == 'fancy' and still_editing
               and canvas(s)['editingText'] is None
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
        zins = []
        for _ in range(4):
            app.call('menu-perform', id='zoom-in'); zins.append(canvas()['zoom'])
        app.call('menu-perform', id='zoom-actual-size')
        record('E17_zoom', [round(z, 2) for z in zooms] == [0.75, 0.5, 0.33, 0.33] and reset == 1 and zin == 1.75
               and zins == [1.75, 2.5, 4, 4], zooms=zooms, reset=reset, zoomIn=zin, zoomIns=zins)

        # E17b: a click without a drag makes a 200 × 200 shape centred on the click (C-report-s6 §1).
        easel(action='tool', tool='ellipse')
        s = easel(action='click', at=[880, 560])
        clicked = objects(s)[-1]
        record('E17b_click_without_drag', clicked['kind'] == 'circle' and close(clicked['frame'], [780, 460, 200, 200])
               and canvas(s)['tool'] == 'pointer' and canvas(s)['selection'] == [clicked['id']], frame=clicked['frame'])

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
        # E28: an Easel row whose canvas is not loaded (restored, not selected) shows the Easel mark.
        unloaded = app.call('tab-state', tab=first)
        record('E28_unloaded_row_icon', unloaded.get('rowFaviconSource') == 'provider' and not unloaded.get('selected'),
               tab={k: unloaded.get(k) for k in ('rowFaviconSource', 'selected', 'title')})
        record('E20_corrupt_file_set_aside', s and s['recreated'] and objects(s) == [] and len(aside) == 1
               and (path.parent / aside[0]).read_text().startswith('{"formatVersion": 1'), aside=aside,
               state={k: v for k, v in (s or {}).items() if k != 'canvas'})

        # ---- E2: pictures, link cards, alignment guides, Capture → Easel ----
        site = Path(tmp) / 'easel-site'
        site.mkdir(exist_ok=True)
        make_png(site / 'og.png', 600, 315, (40, 120, 200))
        (site / 'page.html').write_text(
            '<!doctype html><html><head><title>Fallback title</title>'
            '<meta property="og:title" content="Easel Fixture &amp; Friends">'
            '<meta content="A synthetic page for link cards." property="og:description">'
            '<meta property="og:image" content="/og.png"></head>'
            '<body style="margin:0;background:#3a7"><h1>Easel fixture</h1></body></html>')
        server = fixture_server(site)
        origin = 'http://127.0.0.1:%d' % server.server_address[1]
        try:
            e2 = created['tab']

            # E21: the Image tool opens a picture panel; Cancel adds nothing.
            easel(action='tool', tool='image')
            panel = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(easel(action='image-panel', cancel=False, tab=e2)), timeout=5, step=.1)
            easel(action='image-panel', tab=e2)
            s = easel(tab=e2)
            record('E21_image_panel', panel and panel['message'] == 'Choose pictures to add to this Easel.'
                   and objects(s) == [] and canvas(s)['tool'] == 'pointer', panel=panel)

            # E22: a pasted picture file lands at most 400 pt wide, stored once by its hash.
            picture = make_png(Path(tmp) / 'picture.png', 800, 400, (220, 90, 60))
            app.call('easel', action='pasteboard', file=str(picture))
            s = easel(action='edit', op='paste', tab=e2)
            imgs = [x for x in objects(s) if x['kind'] == 'image']
            record('E22_paste_image_file', len(imgs) == 1 and imgs[0]['pixelSize'] == [800, 400]
                   and abs(imgs[0]['frame'][2] - 400) < .01 and abs(imgs[0]['frame'][3] - 200) < .01
                   and s['imageFiles'] == [imgs[0]['file']] and canvas(s)['selection'] == [imgs[0]['id']], state=canvas(s), files=s['imageFiles'])
            # E23: the same bytes as picture data reuse the stored file.
            app.call('easel', action='pasteboard', imageData=str(picture))
            s = easel(action='edit', op='paste', tab=e2)
            record('E23_image_dedup', len([x for x in objects(s) if x['kind'] == 'image']) == 2 and len(s['imageFiles']) == 1,
                   files=s['imageFiles'])

            # E24: a pasted address makes a link card at once; its metadata and picture follow.
            app.call('easel', action='pasteboard', url=origin + '/page.html')
            s = easel(action='edit', op='paste', tab=e2)
            first_link = [x for x in objects(s) if x['kind'] == 'link']
            done = api.wait_until(lambda: (lambda x: x if x['pendingLinks'] == 0 else None)(easel(tab=e2)), timeout=15, step=.2)
            link = [x for x in objects(done) if x['kind'] == 'link'] if done else []
            record('E24_link_card', len(first_link) == 1 and first_link[0]['url'] == origin + '/page.html'
                   and link and link[0]['title'] == 'Easel Fixture & Friends' and link[0]['summary'] == 'A synthetic page for link cards.'
                   and link[0]['file'] and link[0]['file'] in done['imageFiles'] and abs(link[0]['frame'][3] - 250) < .01,
                   link=link, first=first_link)

            snapshot('e24-link-image-light')
            app.call('appearance', name='dark'); time.sleep(.5)
            snapshot('e24-link-image-dark')
            app.call('appearance', name='light')
            # E25: alignment guides snap a moved shape to another's edge; the canvas menu turns them off.
            menu = easel(action='menu', at=[960, 150], tab=e2)
            easel(action='edit', op='selectAll', tab=e2); easel(action='key', key='delete', tab=e2)
            easel(action='tool', tool='rectangle'); a = easel(action='drag', **{'from': [100, 250], 'to': [300, 350]})
            easel(action='tool', tool='rectangle'); b = easel(action='drag', **{'from': [500, 420], 'to': [650, 500]})
            b_id = objects(b)[-1]['id']
            # Move B up by 167: its top lands 3 pt below A's top (250) and snaps to 250.
            s = easel(action='drag', **{'from': [575, 460], 'to': [575, 293]}, tab=e2)
            snapped = next(x for x in objects(s) if x['id'] == b_id)['frame']
            easel(action='menu', at=[960, 150], item='Use Alignment Guides', tab=e2)
            off_menu = easel(action='menu', at=[960, 150], tab=e2)
            s = easel(action='drag', **{'from': [575, 300], 'to': [575, 305]}, tab=e2)
            unsnapped = next(x for x in objects(s) if x['id'] == b_id)['frame']
            easel(action='menu', at=[960, 150], item='Use Alignment Guides', tab=e2)
            record('E25_alignment_guides', 'Use Alignment Guides' in menu and abs(snapped[1] - 250) < .01
                   and abs(unsnapped[1] - 255) < .01, menu=menu, snapped=snapped, unsnapped=unsnapped, offMenu=off_menu)

            # E26: Capture → Easel. The card offers Add to Easel; its menu lists New Easel and
            # each Easel; a row adds the capture as a web card and selects that Easel.
            page = api.new_tab(app, origin + '/page.html')
            r = app.call('capture', mode='area', rect=[0, 0, 400, 240])
            actions = r['state'].get('card', {}).get('actions', [])
            rows = app.call('easel', action='capture-menu')
            target_title = easel(tab=e2)['tabTitle']
            app.call('easel', action='capture-menu', item=target_title)
            s = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(easel(tab=e2)), timeout=8, step=.1)
            cards = [x for x in objects(s) if x['kind'] == 'webCard'] if s else []
            card_state = app.call('capture-state')
            record('E26_capture_to_easel', 'easel' in actions and rows[0] == 'New Easel' and rows[1] == '—'
                   and target_title in rows and s and s['selected'] and len(cards) == 1
                   and cards[0]['url'] == origin + '/page.html' and cards[0]['title'] == 'Fallback title'
                   and cards[0]['file'] in s['imageFiles'] and 'card' not in card_state,
                   actions=actions, rows=rows, cards=cards)
            snapshot('e26-cards-light')
            app.call('appearance', name='dark'); time.sleep(.5)
            snapshot('e26-cards-dark')
            app.call('appearance', name='light')
            # E27: New Easel from the capture menu.
            app.call('select', tab=page)
            app.call('capture', mode='area', rect=[40, 40, 120, 80])
            count = len(app.call('tabs'))
            app.call('easel', action='capture-menu', item='New Easel')
            fresh = easel()
            record('E27_capture_new_easel', len(app.call('tabs')) == count + 1 and fresh['tabTitle'] == 'Untitled Easel'
                   and [x['kind'] for x in objects(fresh)] == ['webCard'], state={k: v for k, v in fresh.items() if k != 'canvas'})

            # ---- E3: live web cards ----
            app.call('select', tab=e2)
            api.wait_until(lambda: easel(tab=e2).get('shown') or None, timeout=5, step=.1)
            card = next(x for x in objects(easel(tab=e2)) if x['kind'] == 'webCard')
            f = card['frame']; mid = [f[0] + f[2] / 2, f[1] + f[3] / 2]
            menu = easel(action='menu', at=mid, tab=e2)
            easel(action='menu', at=mid, item='Show Live Website', tab=e2)
            sheet = easel(action='sheet', tab=e2)
            easel(action='sheet', press='Show Live Website', tab=e2)
            s = api.wait_until(lambda: (lambda x: x if x['livePages'] == 1 else None)(easel(tab=e2)), timeout=8, step=.1)
            live = next(x for x in objects(s) if x['id'] == card['id']) if s else {}
            record('E29_live_card', 'Show Live Website' in menu and 'Open Page in New Tab' in menu and sheet.get('shown')
                   and sheet['buttons'][:2] == ['Show Live Website', 'Cancel'] and live.get('live') and live.get('liveAttached'),
                   menu=menu, sheet=sheet, card=live)
            time.sleep(1.5)
            snapshot('e29-live-card-light')
            app.call('appearance', name='dark'); time.sleep(.5)
            snapshot('e29-live-card-dark')
            app.call('appearance', name='light')
            # E30: at most three live pages per canvas.
            for _ in range(3):
                easel(action='menu', at=mid, item='Duplicate', tab=e2)
            s = easel(tab=e2)
            lives = [x for x in objects(s) if x['kind'] == 'webCard' and x.get('live')]
            record('E30_live_pool_cap', len(lives) == 4 and s['livePages'] == 3 and canvas(s)['liveCount'] == 3
                   and sum(1 for x in lives if x['liveAttached']) == 3, livePages=s['livePages'], made=s['livePagesMade'])
            # E31: a hidden Easel releases every live page; showing it again brings them back.
            app.call('select', tab=page)
            hidden = easel(tab=e2)
            app.call('select', tab=e2)
            shown = api.wait_until(lambda: (lambda x: x if x['livePages'] == 3 else None)(easel(tab=e2)), timeout=8, step=.1)
            record('E31_live_release_when_hidden', hidden['livePages'] == 0 and shown, hidden=hidden['livePages'])
            # E32: back to the screenshot (no question the second time).
            # Duplicates sit 20 pt down-right of each other: each card's top-left corner is its own.
            for x in [x for x in objects(easel(tab=e2)) if x['kind'] == 'webCard' and x.get('live')]:
                g = x['frame']; easel(action='menu', at=[g[0] + 6, g[1] + 6], item='Show Screenshot', tab=e2)
            s = easel(tab=e2)
            record('E32_show_screenshot', s['livePages'] == 0 and not any(x.get('live') for x in objects(s) if x['kind'] == 'webCard'),
                   livePages=s['livePages'])
            # E33: Open Page in New Tab opens the captured page in a web tab.
            count = len(app.call('tabs'))
            easel(action='menu', at=mid, item='Open Page in New Tab', tab=e2)
            tabs = app.call('tabs')
            record('E33_open_page', len(tabs) == count + 1 and tabs[0]['url'] == origin + '/page.html', first=tabs[0])

            # ---- E4: row menu, rename, export, delete ----
            rows = easel(action='row-menu', tab=e2)
            record('E34_row_menu', rows == ['Copy Link', 'Save as Web Page…', '—', 'Change Icon…', 'Rename…', '—', 'Add Split View',
                                            'Move to ▸', '—', 'Remove Easel from Sidebar', 'Delete Easel'], rows=rows)
            app.call('sidebar-menu', node=e2, item='Copy Link')
            copied = subprocess.run(['/usr/bin/pbpaste'], capture_output=True, text=True).stdout
            record('E34b_copy_link', copied == easel(tab=e2)['url'], copied=copied)
            s = easel(action='rename', text='Board two', tab=e2)
            record('E35_rename_syncs_title', s['tabTitle'] == 'Board two' and canvas(s)['title'] == 'Board two'
                   and canvas(s)['titleFieldText'] == 'Board two', state={k: v for k, v in s.items() if k != 'canvas'})
            app.call('sidebar-menu', node=e2, item='Save as Web Page…')
            panel = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(app.call('easel', action='window-sheet')), timeout=5, step=.1)
            app.call('easel', action='window-sheet', cancel=True)
            out = Path(tmp) / 'export-one'
            easel(action='export', path=str(out), tab=e2)
            exported = json.loads((out / 'easel.json').read_text()) if (out / 'easel.json').exists() else {}
            current = objects(easel(tab=e2))
            used = sorted({x['file'] for x in current if x.get('file')})
            files_ok = all((out / 'images' / f).exists() for f in used)
            viewer = api.new_tab(app, (out / 'index.html').as_uri())
            drawn = app.eval(viewer, "document.querySelectorAll('#page .o').length")
            heading = app.eval(viewer, "document.getElementById('title').textContent")
            record('E36_save_as_web_page', panel and panel['isSavePanel'] and panel['message'] == 'Save this Easel as a web page you can open anywhere.'
                   and exported.get('title') == 'Board two' and len(exported.get('objects', [])) == len(current)
                   and all(0 <= o['frame']['x'] <= 1 for o in exported.get('objects', [])) and files_ok
                   and drawn == len(current) and heading == 'Board two', drawn=drawn, objects=len(current), used=used)
            app.call('close', tab=viewer)
            all_out = Path(tmp) / 'export-all'
            result = app.call('easel', action='export-all', path=str(all_out))
            easel_tabs = [t for t in app.call('tabs') if t['url'].startswith('open://easel/')]
            index = (all_out / 'index.html').read_text() if (all_out / 'index.html').exists() else ''
            # Export All covers every Easel document, also those whose row was archived (E04).
            record('E37_export_all', result['count'] >= len(easel_tabs) and not result['failures']
                   and 'Board%20two/index.html' in index and (all_out / 'Board two' / 'easel.json').exists(), result=result,
                   tabs=len(easel_tabs))
            folder = Path(app.call('easel', action='store', document=easel(tab=e2)['document'])['path']).parent
            app.call('sidebar-menu', node=e2, item='Delete Easel')
            alert = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(app.call('easel', action='window-sheet')), timeout=5, step=.1)
            app.call('easel', action='window-sheet', press='Delete')
            gone = api.wait_until(lambda: all(t['id'] != e2 for t in app.call('tabs')) or None, timeout=5, step=.1)
            record('E38_delete_easel', alert and 'Are you sure you want to delete this Easel?' in alert['texts']
                   and 'Doing so will delete the Easel permanently.' in alert['texts'] and sorted(alert['buttons']) == ['Cancel', 'Delete']
                   and gone and not folder.exists(), alert=alert, folderExists=folder.exists())

            # ---- I1: Arc "Export All Easels" folder → Open Easels ----
            export = Path(tmp) / 'Arc Easels - synthetic'
            def easel_json(folder, doc):
                (export / folder).mkdir(parents=True, exist_ok=True)
                (export / folder / 'easel.json').write_text(json.dumps(doc))
            (export / 'Board A' / 'images').mkdir(parents=True, exist_ok=True)
            make_png(export / 'Board A' / 'images' / 'pic.png', 300, 200, (10, 160, 90))
            easel_json('Board A', {'formatVersion': 1, 'id': 'arc-easel-a', 'title': 'Board A', 'palette': 'chill',
                'exportedAt': '2026-11-01T10:00:00Z', 'objects': [
                {'id': '11111111-0000-4000-8000-000000000001', 'frame': {'x': .1, 'y': .2, 'width': .3, 'height': .05}, 'zIndex': 1,
                 'content': {'type': 'text', 'string': 'Hello from Arc', 'fontFamily': 'mono', 'paragraphStyle': 'h2'}},
                {'id': '11111111-0000-4000-8000-000000000002', 'frame': {'x': .5, 'y': .2, 'width': .2, 'height': .1}, 'zIndex': 2,
                 'content': {'type': 'shape', 'kind': 'rectangle', 'color': 'purple'}},
                {'id': '11111111-0000-4000-8000-000000000003', 'frame': {'x': .1, 'y': .4, 'width': .3, 'height': .2}, 'zIndex': 3,
                 'content': {'type': 'image', 'src': 'images/pic.png', 'size': {'width': 300, 'height': 200}}},
                {'id': '11111111-0000-4000-8000-000000000004', 'frame': {'x': .5, 'y': .4, 'width': .3, 'height': .2}, 'zIndex': 4,
                 'content': {'type': 'webCard', 'url': 'https://example.com/a', 'title': 'Example', 'image': 'images/pic.png'}},
                {'id': '11111111-0000-4000-8000-000000000005', 'frame': {'x': .1, 'y': .7, 'width': .3, 'height': .07}, 'zIndex': 5,
                 'content': {'type': 'link', 'source': 'https://example.org/', 'title': 'Org', 'description': 'An example'}},
                {'id': '11111111-0000-4000-8000-000000000006', 'frame': {'x': .5, 'y': .7, 'width': .3, 'height': .2}, 'zIndex': 6,
                 'content': {'type': 'browser', 'url': 'https://example.net/'}},
                {'id': '11111111-0000-4000-8000-000000000007', 'frame': {'x': .1, 'y': .9, 'width': .3, 'height': .05}, 'zIndex': 7,
                 'content': {'type': 'richText', 'text': 'Rich words', 'formats': []}},
                {'id': '11111111-0000-4000-8000-000000000008', 'frame': {'x': .1, 'y': 1.0, 'width': .3, 'height': .05}, 'zIndex': 8,
                 'content': {'type': 'hologram'}}]})
            easel_json('Board B', {'formatVersion': 1, 'id': 'arc-easel-b', 'title': 'Board B', 'palette': 'vibrant', 'objects': []})
            easel_json('From the future', {'formatVersion': 9, 'id': 'arc-easel-c', 'title': 'Future', 'objects': []})
            easel_json('Escape', {'formatVersion': 1, 'id': 'arc-easel-d', 'title': 'Escape', 'objects': [
                {'id': '11111111-0000-4000-8000-000000000009', 'frame': {'x': .1, 'y': .1, 'width': .1, 'height': .1}, 'zIndex': 1,
                 'content': {'type': 'image', 'src': '../Board A/images/pic.png'}}]})
            count = len(app.call('tabs'))
            first_import = app.call('easel', action='import-arc-export', path=str(export))
            tabs = app.call('tabs')
            titles = [t['title'] for t in tabs[:4]]
            record('I01_import_counts', first_import['imported'] == 3 and first_import['newRows'] == 3
                   and len(first_import['skipped']) == 1 and 'From the future' in first_import['skipped'][0]
                   and first_import['droppedObjects'] == 2 and len(tabs) == count + 3
                   and {'Board A', 'Board B', 'Escape'} <= set(titles), result=first_import, titles=titles)
            a_id = app.call('easel', action='document-id', arcID='arc-easel-a')
            board_a = next(t for t in tabs if t['url'] == 'open://easel/' + a_id)
            app.call('select', tab=board_a['id'])
            s = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(easel(tab=board_a['id'])), timeout=8, step=.1)
            got = [(x['kind'], x.get('text') or x.get('url') or x.get('color') or x.get('file')) for x in objects(s)] if s else []
            text = next((x for x in objects(s) if x['kind'] == 'text'), {}) if s else {}
            record('I02_import_content', s and [k for k, _ in got] == ['text', 'rectangle', 'image', 'webCard', 'link', 'link', 'text']
                   and close(text.get('frame', [0] * 4), [100, 200, 300, 50]) and text.get('fontFamily') == 'mono'
                   and text.get('paragraphStyle') == 'h2' and canvas(s)['palette'] == 'chill' and canvas(s)['title'] == 'Board A'
                   and len(s['imageFiles']) == 1, got=got)
            again = app.call('easel', action='import-arc-export', path=str(export))
            archive = Path(tmp) / 'arc-easels.zip'
            subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(export), str(archive)], check=True)
            zipped = app.call('easel', action='import-arc-export', path=str(archive))
            record('I03_reimport_and_zip', again['imported'] == 3 and again['newRows'] == 0 and zipped['imported'] == 3
                   and zipped['newRows'] == 0 and len(app.call('tabs')) == count + 3, again=again, zipped=zipped)

            # ---- Library › Easels ----
            def library(**kw):
                return app.call('library', **kw)
            board_b = next(t for t in app.call('tabs') if t['url'] == 'open://easel/' + app.call('easel', action='document-id', arcID='arc-easel-b'))
            app.call('close', tab=board_b['id'])   # archived row: the Easel stays in the Library
            library(action='open', section='easels')
            lib = api.wait_until(lambda: (lambda x: x if x.get('section') == 'easels' and x['easels']['items'] and x.get('rows') else None)(library()), timeout=8, step=.2)
            rows = {r.get('title'): r for r in (lib or {}).get('rows', [])}
            record('L01_library_easels_page', lib and 'easels' in [t['id'] for t in lib['rail']] and lib['easels']['cardVisible']
                   and lib['easels']['cardTitle'] == 'Your Easels are yours to keep' and lib['easels']['exportTitle'] == 'Export All Easels →'
                   and {'Board A', 'Board B'} <= set(rows) and lib['easels']['items'] == len(lib['rows']),
                   easels=(lib or {}).get('easels'), titles=sorted(rows))
            time.sleep(.6)   # thumbnails draw on the next turn
            snapshot('l01-library-easels-light')
            app.call('appearance', name='dark'); time.sleep(.6)
            snapshot('l01-library-easels-dark')
            app.call('appearance', name='light')
            b_row = rows.get('Board B', {}).get('id', '')
            menu = library(action='row-menu', id=b_row)['items'] if b_row else []
            library(action='row-action', id=b_row, name='open')
            opened = api.wait_until(lambda: (lambda x: x if x.get('shown') and x['tabTitle'] == 'Board B' else None)(easel()), timeout=8, step=.2)
            record('L02_open_easel_without_row', [m['title'] for m in menu] == ['Delete'] and opened and not library()['open'],
                   menu=menu, opened={k: v for k, v in (opened or {}).items() if k != 'canvas'})
            library(action='open', section='easels')
            api.wait_until(lambda: library().get('easels', {}).get('items') or None, timeout=8, step=.2)
            library(action='easels-export')
            sheet = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(app.call('easel', action='window-sheet')), timeout=5, step=.1)
            archive_out = Path(tmp) / 'library-export.zip'
            library(action='save-panel', path=str(archive_out))
            exported = api.wait_until(lambda: archive_out.exists() and archive_out.stat().st_size > 0 or None, timeout=20, step=.2)
            listing = subprocess.run(['/usr/bin/zipinfo', '-1', str(archive_out)], capture_output=True, text=True).stdout if exported else ''
            record('L03_export_all_archive', sheet and sheet['isSavePanel']
                   and sheet['message'] == 'Save an archive of all your Easels as web pages you can open anywhere.'
                   and exported and '/Board A/index.html' in listing and '/index.html' in listing, sheet=sheet, entries=listing.count('\n'))
            lib = library()
            before = lib['easels']['items']
            a_row = next(r['id'] for r in lib['rows'] if r.get('title') == 'Board A')
            a_folder = Path(app.call('easel', action='store', document=a_row)['path']).parent
            library(action='row-menu', id=a_row, select='Delete')
            alert = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(app.call('easel', action='window-sheet')), timeout=5, step=.1)
            app.call('easel', action='window-sheet', press='Delete')
            after = api.wait_until(lambda: (lambda x: x if x['easels']['items'] == before - 1 else None)(library()), timeout=8, step=.2)
            record('L04_library_delete', alert and 'Are you sure you want to delete this Easel?' in alert['texts'] and after
                   and not a_folder.exists() and all(t['url'] != 'open://easel/' + a_row for t in app.call('tabs')),
                   before=before, after=(after or {}).get('easels'))
            library(action='close')
        finally:
            server.shutdown()
        # L05: a profile with no Easels shows the empty state (docs/re/easels.md copy).
        app.quit(); app = None
        app = factory(urls=('about:blank',), fresh=True)
        app.call('library', action='open', section='easels')
        empty = api.wait_until(lambda: (lambda x: x if x.get('section') == 'easels' and x.get('emptyVisible') else None)(app.call('library')), timeout=8, step=.2)
        record('L05_library_empty', empty and empty['emptyState']['title'] == 'No Easels yet'
               and empty['emptyState']['body'] == 'Click the + sign in the Sidebar to create a new Easel.' and empty['easels']['cardVisible'],
               state=(empty or {}).get('emptyState'))
        # ---- Import from Arc ▸ Easels (IMC's provider API): wizard → runner → Undo/Redo ----
        app.quit(); app = None
        arc = Path(tmp) / 'ArcSourceEasels'
        ids = runpy.run_path(str(root / 'tools/e2e/firstrun.py'))['fixture'](arc)
        sidebar_file = arc / 'StorableSidebar.json'
        sidebar = json.loads(sidebar_file.read_text())
        for item in sidebar['sidebar']['containers'][1]['items']:
            if isinstance(item, dict) and item.get('id') == ids['easel']:
                item['data'] = {'easel': {'easelID': 'arc-easel-a', 'title': 'Board A', 'shareStatus': 'creatorOnly'}}
        sidebar_file.write_text(json.dumps(sidebar))
        app = factory(urls=(), fresh=True, extra_args=['--host-resolver-rules=MAP * ~NOTFOUND'])
        def fr():
            return app.call('first-run', action='settings-inspect')
        app.call('first-run', action='settings-import', directory=str(arc))
        def provider_row():
            return next((p for p in app.call('first-run', action='settings-inspect').get('settingsProviders', []) if p['id'] == 'easels'), {})
        # The count is asked again once the wizard has the chosen Arc folder.
        before_pick = api.wait_until(lambda: (lambda x: x if x.get('count') is not None else None)(provider_row()), timeout=10, step=.2) or provider_row()
        app.call('first-run', action='settings-provider', id='easels', file=str(export))
        chosen = next((p for p in app.call('first-run', action='settings-inspect').get('settingsProviders', []) if p['id'] == 'easels'), {})
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        finished = api.wait_until(lambda: (lambda x: x if x.get('settingsStep') == 'Report' and not x.get('settingsBusy') else None)(fr()), timeout=120, step=.1)
        report = finished or fr()
        app.call('first-run', action='settings-done')
        a_url = 'open://easel/' + app.call('easel', action='document-id', arcID='arc-easel-a')
        def easel_tabs():
            return app.call('easel', action='rows')
        imported_tabs = easel_tabs()
        a_tab = next((t for t in imported_tabs if t['url'] == a_url), None)
        a_objects = []
        if a_tab:
            app.call('select', tab=a_tab['tab'])
            shown = api.wait_until(lambda: (lambda x: x if x.get('shown') else None)(easel(tab=a_tab['tab'])), timeout=8, step=.1)
            a_objects = objects(shown) if shown else []
        record('W01_wizard_easels', before_pick.get('count') == 1 and chosen.get('count') == 3 and chosen.get('selected') is True
               and report.get('settingsOutcome', {}).get('Easels') == 3 and a_tab and a_tab['title'] == 'Board A'
               and len(a_objects) == 7 and len(imported_tabs) == 3, beforePick=before_pick, chosen=chosen,
               outcome=report.get('settingsOutcome'), tabs=[t['title'] for t in imported_tabs])
        a_doc = Path(app.call('easel', action='store', document=a_url.rsplit('/', 1)[1])['path'])
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        app.call('sidebar-key', key='z', modifiers=['command'])
        api.wait_until(lambda: not fr().get('importUndoInProgress', False), timeout=30, step=.05)
        undone_tabs, undone_file = easel_tabs(), a_doc.exists()
        app.call('sidebar-key', key='z', modifiers=['command', 'shift'])
        api.wait_until(lambda: not fr().get('importUndoInProgress', False), timeout=30, step=.05)
        redone_tabs, redone_file = easel_tabs(), a_doc.exists()
        record('W02_wizard_undo_redo', undone_tabs == [] and not undone_file and len(redone_tabs) == 3 and redone_file,
               undone=[t['title'] for t in undone_tabs], undoneFile=undone_file, redone=[t['title'] for t in redone_tabs])
    finally:
        if app:
            app.quit()
        for key in color_keys:
            if saved_prefs.get(key) is None:
                subprocess.run(['defaults', 'delete', domain, key], capture_output=True)
            else:
                value = saved_prefs[key]
                kind = '-bool' if isinstance(value, bool) else '-string'
                subprocess.run(['defaults', 'write', domain, key, kind, str(value).lower() if isinstance(value, bool) else value],
                               capture_output=True)
