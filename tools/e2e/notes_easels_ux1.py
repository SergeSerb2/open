"""UX round 1 wave 3, Notes and Easels editing (lane UXE): real App rows through the automation socket.

Notes (`engine_e2e.py --only notes`; OPEN_NOTES_UXE_ONLY=1 runs only these):
- `uxe3_note_image_own_line`: a pasted image is its own plain paragraph and its line is as tall as
  the image (no blank band from the body's line-height multiple, no list indent) (N3).
- `uxe3_note_empty_item_marker_baseline`: the marker of an empty last list item sits on the caret's
  baseline, as a written item's marker does (N1).
- `uxe3_note_link_input`: the link input keeps the bar 36 pt tall with padded text; clicking away
  applies the typed link, Escape cancels (N2).

Easels (`engine_e2e.py --only easel`; OPEN_EASEL_UXE_ONLY=1 runs only these):
- `uxe3_easel_escape_keeps_canvas_focus`: after Escape ends a text box the canvas has keyboard focus,
  so Delete removes the selected box (E1).
- `uxe3_easel_text_box_clear_of_toolbar`: a text box growing near the bottom stays above the floating
  toolbar (E2).
- `uxe3_easel_title_clear_of_shapes`: in a small window the title shrinks with the canvas (13 pt at
  least) and does not overlap the shapes at the top (E3).
- `uxe3_easel_resize_redraws_shape`: resizing a rectangle or ellipse by its handle redraws the
  shape's pixels at the new size immediately without changing colour or any other property, and
  Undo restores the original pixels.

Keys go through the App's real key path (`key`, NSApp.sendEvent); Easel pointer input is NSEvents sent
by the window; paste uses AppKit's paste path from a private pasteboard. Socket only.
"""
import os
import struct
import time
import zlib


def _row(results, name, check):
    try:
        ok, evidence = check()
    except Exception as error:  # a broken step is a failed row, never a skipped one
        ok, evidence = False, {'error': repr(error)}
    results[name] = dict(ok=bool(ok), **evidence)
    print('uxe3 %-44s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)


def _png(path, w, h, rgb):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def chunk(kind, d):
        return struct.pack('>I', len(d)) + kind + d + struct.pack('>I', zlib.crc32(kind + d) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def _overlap(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


# ---------------------------------------------------------------- Notes
def note_rows(factory, results, tmp, h):
    wait = h.wait_until
    app = factory(urls=('about:blank',), fresh=True)
    try:
        app.call('window-frame', frame=[80, 80, 1280, 820], unconstrained=True)

        def new_note(title):
            app.call('note', action='create')
            assert wait(lambda: app.call('note').get('shown'), timeout=5, step=.05), 'note not shown'
            app.call('note', action='focus', field='title')
            app.call('key', text=title); app.call('key', key='return')

        def key(k=None, text=None, mods=()):
            return app.call('key', text=text) if text is not None else app.call('key', key=k, modifiers=list(mods))

        def image_line():
            new_note('Image line')
            key(text='- first item'); key('return'); key(text='second item')
            image = os.path.join(tmp, 'uxe3-image.png'); _png(image, 640, 360, (70, 140, 220))
            app.call('note', action='paste-file', path=image); time.sleep(.3)
            # Typing right after the image starts a paragraph of its own (review r1 #4).
            key(text='Caption'); time.sleep(.2)
            s = app.call('note')
            lines = s.get('imageLines')
            if lines is None:
                return False, {'error': 'note state has no imageLines (automation predates the row)'}
            if len(lines) != 1:
                return False, {'error': 'expected one image', 'imageLines': lines, 'imageError': s.get('imageError')}
            line = lines[0]
            problems = []
            if line['bandAbove'] > 2: problems.append('%.0f pt blank above the image' % line['bandAbove'])
            if not line['ownParagraph']: problems.append('image shares a paragraph with text')
            if line['headIndent'] > 0: problems.append('image keeps the list indent (%.0f pt)' % line['headIndent'])
            if not s['body'].endswith('\ufffc\nCaption'): problems.append('typing after the image joined its line')
            return not problems, {'imageLine': line, 'body': s['body'][-30:], 'problems': problems}
        _row(results, 'uxe3_note_image_own_line', image_line)

        def marker_baseline():
            new_note('Markers')
            key(text='- one'); key('return'); key(text='two'); key('return'); time.sleep(.2)
            s = app.call('note')
            marker = s.get('trailingMarker')
            if marker is None:
                return False, {'error': 'note state has no trailingMarker (automation predates the row)'}
            if not marker:
                return False, {'error': 'no empty trailing list item', 'typingBlock': s.get('typingBlock')}
            delta = abs(marker['marker'] - marker['writtenItem'])
            # A list on the first line of an empty body: no line exists yet (review r1 #5).
            new_note('Empty list')
            app.call('note', action='gutter', item='Bulleted list'); time.sleep(.2)
            first = app.call('note').get('trailingMarker') or {}
            first_delta = abs(first.get('marker', -100) - marker['writtenItem'])
            return delta <= 1 and first_delta <= 1, {'trailingMarker': marker, 'delta': round(delta, 2),
                                                    'emptyNoteMarker': first, 'emptyNoteDelta': round(first_delta, 2)}
        _row(results, 'uxe3_note_empty_item_marker_baseline', marker_baseline)

        def link_input():
            new_note('Links')
            key(text='Visit the example site today and another site later.')
            body = app.call('note')['body']
            first, second = body.find('example'), body.find('another')
            app.call('note', action='select', start=first, length=7); time.sleep(.2)
            app.call('note', action='press', item='link'); time.sleep(.3)
            bar = app.call('note')['formatBar']
            if 'linkField' not in bar:
                return False, {'error': 'format bar state has no linkField (automation predates the row)'}
            field = bar['linkField']
            problems = []
            if not bar.get('editingLink'): problems.append('link input not shown')
            if abs(bar['frame'][3] - 36) > .5: problems.append('bar is %.0f pt tall while editing a link' % bar['frame'][3])
            if not field or field[0] < 8: problems.append('link text starts %s pt into the bar' % (field[0] if field else None))
            # A real click in the box's left padding keeps the input open and the body selection
            # (review r1 #1).
            box = bar.get('linkBoxWindow') or []
            if len(box) == 4:
                at = dict(x=box[0] + 3, y=box[1] + box[3] / 2)
                app.call('mouse', action='down', **at); app.call('mouse', action='up', **at); time.sleep(.2)
                clicked = app.call('note')
                if not clicked['formatBar'].get('editingLink'): problems.append('a click in the input box closed it')
                if clicked['selection'] != [first, 7]: problems.append('a click in the input box moved the caret to %r' % clicked['selection'])
            else:
                problems.append('no link box frame')
            key(text='https://example.com/')
            # A click in the body: the input loses focus without Return or Escape.
            app.call('note', action='focus', field='body'); time.sleep(.3)
            after_click = [f for f in app.call('note')['formats'] if f.get('type') in ('link', 'hyperlink')]
            if not any(f['location'] == first for f in after_click): problems.append('click away dropped the typed link')
            app.call('note', action='select', start=second, length=7); time.sleep(.2)
            app.call('note', action='press', item='link'); time.sleep(.3)
            key(text='https://cancelled.example/'); key('escape'); time.sleep(.3)
            after_escape = [f for f in app.call('note')['formats'] if f.get('type') in ('link', 'hyperlink')]
            if any(f['location'] == second for f in after_escape): problems.append('Escape applied the link')
            return not problems, {'bar': bar, 'linksAfterClick': after_click, 'linksAfterEscape': after_escape, 'problems': problems}
        _row(results, 'uxe3_note_link_input', link_input)
    finally:
        try: app.quit()
        except Exception: pass


# ---------------------------------------------------------------- Easels
def easel_rows(factory, results, tmp, h):
    wait = h.wait_until
    app = factory(urls=('about:blank',), fresh=True)
    try:
        app.call('window-frame', frame=[80, 80, 1280, 820], unconstrained=True)

        def easel(**kw):
            return app.call('easel', **kw)

        def new_easel():
            app.call('menu-perform', id='new-easel')
            assert wait(lambda: easel().get('shown'), timeout=5, step=.05), 'easel not shown'
            time.sleep(.3)

        def escape_focus():
            new_easel()
            easel(action='tool', tool='text'); easel(action='click', at=[300, 300]); easel(action='type', text='Delete me')
            easel(action='key', key='escape'); time.sleep(.2)
            s = easel()
            before = {'firstResponder': s.get('firstResponder'), 'objects': len(s['canvas']['objects']), 'selection': s['canvas']['selection']}
            app.call('key', key='delete'); time.sleep(.2)
            after = len(easel()['canvas']['objects'])
            ok = before['firstResponder'] == 'EaselDocumentView' and before['objects'] == 1 and after == 0
            return ok, {'afterEscape': before, 'objectsAfterDelete': after}
        _row(results, 'uxe3_easel_escape_keeps_canvas_focus', escape_focus)

        def clear_of_toolbar():
            new_easel()
            c = easel()['canvas']
            bar = c['toolbarFrame']
            scale = c['scale']
            # A box whose first line sits just above the toolbar, over its left half.
            doc_y = (bar[1] - 40 + easel()['canvas']['scrollOffset']) / scale
            easel(action='tool', tool='text'); easel(action='click', at=[60, doc_y])
            # Long enough that, at Heading size, the box outgrows the page's spare height below its
            # stored frame (review r1 #3).
            easel(action='type', text='Weekend moodboard ideas for the long trip to the coast and the hills next month, '
                                      'with stops for lunch and a swim')
            for _ in range(2): easel(action='size', button='larger')
            time.sleep(.3)
            c = easel()['canvas']
            if 'editorFrame' not in c:
                return False, {'error': 'canvas state has no editorFrame (automation predates the row)'}
            box, bar = c['editorFrame'], c['toolbarFrame']
            covered = box is not None and _overlap(box, bar)
            ok = box is not None and not covered and box[1] >= 0
            easel(action='key', key='escape')
            return ok, {'editorFrame': box, 'toolbarFrame': bar, 'covered': covered, 'scrollOffset': c['scrollOffset']}
        _row(results, 'uxe3_easel_text_box_clear_of_toolbar', clear_of_toolbar)

        def title_clear():
            new_easel()
            easel(action='tool', tool='rectangle'); easel(action='drag', **{'from': [80, 140], 'to': [320, 300]})
            easel(action='tool', tool='ellipse'); easel(action='drag', **{'from': [420, 140], 'to': [600, 300]})
            # A strip just under the title: at small widths it reaches the title's line (review r1 #6).
            easel(action='tool', tool='rectangle'); easel(action='drag', **{'from': [430, 86], 'to': [570, 120]})
            seen = {}
            for size in ((1280, 820), (760, 520)):
                app.call('window-frame', frame=[80, 80, size[0], size[1]], unconstrained=True); time.sleep(.6)
                c = easel()['canvas']
                if 'titleFontSize' not in c:
                    return False, {'error': 'canvas state has no titleFontSize (automation predates the row)'}
                hits = [o['kind'] for o in c['objects'] if _overlap(c['titleFrame'], o['viewFrame'])]
                seen['%dx%d' % size] = {'title': c['titleFrame'], 'fontSize': c['titleFontSize'], 'scale': c['scale'], 'overlaps': hits}
            small, large = seen['760x520'], seen['1280x820']
            ok = (not small['overlaps'] and not large['overlaps'] and 13 <= small['fontSize'] < large['fontSize']
                  and small['title'][1] >= 2 and large['title'][1] >= 2
                  and abs(large['fontSize'] - 26) < .5)
            app.call('window-frame', frame=[80, 80, 1280, 820], unconstrained=True)
            return ok, seen
        _row(results, 'uxe3_easel_title_clear_of_shapes', title_clear)

        def resize_redraws_shape():
            new_easel()
            prev_appearance = 'dark' if 'Dark' in str(app.call('window-state').get('windowAppearance', '')) else 'light'
            app.call('appearance', name='light'); time.sleep(.2)
            try:
                # Draw a 100x100 rectangle at [120, 220] and pick black so the 75% fill (~63) is
                # sharply distinct from both the canvas background (~253) and the 100% stroke (0).
                easel(action='tool', tool='rectangle')
                easel(action='drag', **{'from': [120, 220], 'to': [220, 320]})
                s0 = easel(action='swatch', color='black')
                rect = s0['canvas']['objects'][-1]
                rect_id = rect['id']
                win_w, win_h = app.call('window-state')['frame'][2:4]
                cx, cy_bottom, _, ch = s0['canvasFrame']
                canvas_top = win_h - (cy_bottom + ch)
                scale = s0['canvas']['scale']
                origin_x = rect['viewFrame'][0] - rect['frame'][0] * scale
                origin_y = rect['viewFrame'][1] - rect['frame'][1] * scale
                methods = []

                def snap_pixels(name):
                    path = os.path.join(tmp, name)
                    shot = app.call('snapshot', path=path)
                    methods.append(shot.get('method'))
                    w_img, h_img, px = h.read_image(path, srgb=True)
                    def at(doc_pt):
                        wx = cx + origin_x + doc_pt[0] * scale
                        wy = canvas_top + origin_y + doc_pt[1] * scale
                        return px(wx * (w_img / win_w), wy * (h_img / win_h))
                    return at

                def max_diff(a, b):
                    return max(abs(x - y) for x, y in zip(a, b))

                time.sleep(.25)
                before = snap_pixels('easel-resize-before.png')
                bg_px = before([920, 300])
                rect_fill_px = before([170, 270])
                expanded_before = before([360, 370])

                # Resize the rectangle 4x wider to [120, 220, 400, 220] without changing any property.
                # Probe both the expanded interior ([360, 370], catches a pinned stale bitmap) and
                # 6 doc pt inside the new right edge ([514, 330], catches a 4x-stretched 2.5 pt stroke
                # which would widen to 10 doc pt and paint opaque stroke instead of 75% fill).
                s1 = easel(action='drag', **{'from': [220, 320], 'to': [520, 440]})
                resized = next(o for o in s1['canvas']['objects'] if o['id'] == rect_id)
                time.sleep(.25)
                grow = snap_pixels('easel-resize-grow.png')
                expanded_after_grow = grow([360, 370])
                near_edge_after_grow = grow([514, 330])

                # Undo must immediately redraw back to the original size.
                s2 = easel(action='undo')
                undone = next(o for o in s2['canvas']['objects'] if o['id'] == rect_id)
                time.sleep(.25)
                expanded_after_undo = snap_pixels('easel-resize-undo.png')([360, 370])

                # Also verify resizing an ellipse (explicit red) redraws without any property change.
                easel(action='tool', tool='ellipse')
                easel(action='drag', **{'from': [580, 220], 'to': [680, 320]})
                se0 = easel(action='swatch', color='red')
                ellipse_id = se0['canvas']['objects'][-1]['id']
                time.sleep(.25)
                ellipse_before = snap_pixels('easel-ellipse-before.png')
                ellipse_fill_px = ellipse_before([630, 270])
                ellipse_exp_before = ellipse_before([730, 370])

                se1 = easel(action='drag', **{'from': [680, 320], 'to': [820, 440]})
                ellipse_resized = next(o for o in se1['canvas']['objects'] if o['id'] == ellipse_id)
                time.sleep(.25)
                ellipse_exp_after = snap_pixels('easel-ellipse-grow.png')([730, 370])

                windowserver_ok = bool(methods) and all(m == 'windowserver+devtools' for m in methods)
                frame_grew = all(abs(a - b) < 1 for a, b in zip(resized['frame'], [120, 220, 400, 220]))
                frame_undone = all(abs(a - b) < 1 for a, b in zip(undone['frame'], [120, 220, 100, 100]))
                ellipse_grew = all(abs(a - b) < 1 for a, b in zip(ellipse_resized['frame'], [580, 220, 240, 220]))
                rect_ok = (frame_grew and frame_undone
                           and max_diff(rect_fill_px, bg_px) >= 30
                           and max_diff(expanded_before, bg_px) <= 10
                           and max_diff(expanded_after_grow, rect_fill_px) <= 10
                           and max_diff(expanded_after_grow, bg_px) >= 30
                           and max_diff(near_edge_after_grow, rect_fill_px) <= 10
                           and max_diff(expanded_after_undo, bg_px) <= 10)
                ellipse_ok = (ellipse_grew
                              and max_diff(ellipse_fill_px, bg_px) >= 30
                              and max_diff(ellipse_exp_before, bg_px) <= 10
                              and max_diff(ellipse_exp_after, ellipse_fill_px) <= 10
                              and max_diff(ellipse_exp_after, bg_px) >= 30)
                return windowserver_ok and rect_ok and ellipse_ok, {
                    'methods': methods, 'bg': list(bg_px), 'rectFill': list(rect_fill_px),
                    'expandedBefore': list(expanded_before), 'expandedAfterGrow': list(expanded_after_grow),
                    'nearEdgeAfterGrow': list(near_edge_after_grow),
                    'expandedAfterUndo': list(expanded_after_undo),
                    'resizedFrame': resized['frame'], 'undoneFrame': undone['frame'],
                    'ellipseFrame': ellipse_resized['frame'],
                    'ellipseFill': list(ellipse_fill_px), 'ellipseExpandedBefore': list(ellipse_exp_before),
                    'ellipseExpandedAfter': list(ellipse_exp_after),
                }
            finally:
                app.call('appearance', name=prev_appearance)
        _row(results, 'uxe3_easel_resize_redraws_shape', resize_redraws_shape)
    finally:
        try: app.quit()
        except Exception: pass
