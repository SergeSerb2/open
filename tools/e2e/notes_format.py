"""Notes N2a through the real App: markdown shortcuts and Return/Tab rules typed
with real key events, Cmd-B / Cmd-I / Cmd-U and Undo through the menus, the
selection format bar's own buttons, the link input, link clicks, the "+" gutter
menu, image paste (and a refused non-image), and quit + relaunch.

Only the automation socket and the App's own event and menu paths are used.
Synthetic text and a generated PNG only; no user data.
"""
import os
import struct
import subprocess
import time
import zlib


def png(path, w=120, h=80):
    """A valid RGB PNG, streamed row by row (a 144 MP image stays small on disk and in memory)."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)
    z = zlib.compressobj(9)
    row = b'\x00' + bytes([200, 60, 90]) * w
    idat = b''.join(z.compress(row) for _ in range(h)) + z.flush()
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', idat) + chunk(b'IEND', b''))


def run(factory, results, tmp, h):
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('notes-format %-34s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def has(formats, kind, start, length, **extra):
        return any(f['type'] == kind and f['location'] == start and f['length'] == length
                   and all(f.get(k) == v for k, v in extra.items()) for f in formats)

    def key(name, *mods):
        return app.call('key', key=name, modifiers=list(mods), route='app')

    server, origin = h._fixture_server('NotesFormat')
    image = os.path.join(tmp, 'note-image.png'); png(image)
    huge = os.path.join(tmp, 'huge-header.png'); png(huge, 12000, 12000)  # valid 144 MP image, small file
    fake = os.path.join(tmp, 'not-an-image.png')
    with open(fake, 'w') as f:
        f.write('plain text, not a PNG')
    frames = os.path.join(h.ROOT, '.re', 'nt-frames'); os.makedirs(frames, exist_ok=True)
    app = factory(urls=(origin + '/page',), fresh=True)
    try:
        app.call('wait', tab=app.call('tabs')[0]['id'])
        app.call('note', action='create')
        app.call('key', text='Formats')
        key('return')

        # 1. Paragraph shortcuts and Return rules, typed.
        app.call('key', text='# Big\r## Mid\r### Small\r* one\r- two\r1. first\rsecond\r')
        key('return')  # Return on the empty numbered item ends the list.
        app.call('key', text='plain')
        s = app.call('note')
        text = 'Big\nMid\nSmall\none\ntwo\nfirst\nsecond\nplain'
        f = s['formats']
        # Paragraph formats cover the paragraph text without its line break.
        row('markdown_paragraph_shortcuts', s['body'] == text and has(f, 'h1', 0, 3) and has(f, 'h2', 4, 3)
            and has(f, 'h3', 8, 5) and has(f, 'bulletList', 14, 3, level=0) and has(f, 'bulletList', 18, 3, level=0)
            and has(f, 'numberedList', 22, 5, level=0) and has(f, 'numberedList', 28, 6, level=0)
            and not any(x['location'] >= 35 and x['type'] in ('h1', 'h2', 'h3', 'bulletList', 'numberedList') for x in f),
            body=s['body'], formats=f)

        # 2. Inline shortcuts, typed.
        app.call('key', text='\rmake *this* bold, _that_ italic, -gone- struck')
        s = app.call('note')
        line = 'make this bold, that italic, gone struck'
        at = s['body'].find(line)
        f = s['formats']
        row('markdown_inline_shortcuts', at > 0 and s['body'].endswith(line) and has(f, 'bold', at + 5, 4)
            and has(f, 'italic', at + 16, 4) and has(f, 'strikethrough', at + 29, 4), body=s['body'], formats=f)

        # 3. Cmd-B / Cmd-I / Cmd-U through the menus, then Undo (Cmd-Z) removes the last one.
        plain = s['body'].find('plain')
        app.call('note', action='select', start=plain, length=5)
        key('b', 'command'); key('i', 'command'); key('u', 'command')
        styled = app.call('note')['formats']
        key('z', 'command')
        undone = app.call('note')['formats']
        row('menu_keys_and_undo', has(styled, 'bold', plain, 5) and has(styled, 'italic', plain, 5)
            and has(styled, 'underline', plain, 5) and not has(undone, 'underline', plain, 5)
            and has(undone, 'bold', plain, 5), styled=styled, undone=undone)

        # 4. The format bar shows above a selection; its buttons apply formats.
        app.call('note', action='select', start=s['body'].find('one'), length=3)
        bar = app.call('note')['formatBar']
        app.call('note', action='press', item='strikethrough')
        app.call('note', action='select', start=plain, length=5)
        app.call('note', action='press', item='h2')
        s = app.call('note')
        row('format_bar_buttons', bar['visible'] and bar['frame'][1] >= bar['selectionTop'] - 1
            and bar['items'] == ['h1', 'h2', 'h3', 'bold', 'italic', 'underline', 'strikethrough', 'link']
            and has(s['formats'], 'strikethrough', s['body'].find('one'), 3) and has(s['formats'], 'h2', plain, 5)
            and 'h2' in s['formatBar']['on'], bar=bar, formats=s['formats'])
        app.call('note', action='select', start=plain, length=5)
        app.call('note', action='press', item='h2')  # toggles back to Text

        # 5. Link input (typed into the bar's field) and a link click opening a new tab.
        word = s['body'].find('first')
        app.call('note', action='select', start=word, length=5)
        app.call('note', action='press', item='link')
        editing = app.call('note')['formatBar']['editingLink']
        target = origin + '/linked'
        app.call('key', text=target)
        key('return')
        s = app.call('note')
        before = len(app.call('tabs'))
        app.call('note', action='click-link', at=word + 1)
        opened = h.wait_until(lambda: (lambda t: t if len(t) == before + 1 else None)(app.call('tabs')), timeout=5, step=.1)
        row('link_input_and_click', editing and has(s['formats'], 'link', word, 5, url=target)
            and bool(opened) and any(t['url'].startswith(target) for t in opened or []),
            formats=s['formats'], tabs=[t['url'] for t in opened or []])
        app.call('select', tab=s['tab'])
        h.wait_until(lambda: app.call('note')['shown'], timeout=5, step=.05)

        # 6. "+" gutter on an empty line; Bulleted list from its menu; Tab indents.
        end = len(app.call('note')['body'])
        app.call('note', action='select', start=end, length=0)
        key('return')
        g = app.call('note')
        app.call('note', action='gutter', item='Bulleted list')
        app.call('key', text='gutter item')
        key('tab')
        s = app.call('note')
        item = s['body'].rfind('gutter item')
        row('gutter_menu_and_indent', g['gutterVisible'] and item > 0
            and has(s['formats'], 'bulletList', item, len('gutter item'), level=1), gutter=g['gutterVisible'], formats=s['formats'])

        # 7. Images: paste a PNG file; a fake PNG is refused and leaves nothing.
        key('return'); key('return')  # end the list, new Text line
        app.call('note', action='paste-file', path=image)
        s = app.call('note')
        pic = [x for x in s['formats'] if x['type'] == 'image']
        app.call('note', action='paste-file', path=fake)
        refused = app.call('note')
        app.call('note', action='paste-file', path=huge)
        too_big = app.call('note')
        row('image_paste', len(pic) == 1 and s['images'] == 1 and s['assets'] == 1, formats=pic, images=s['images'], assets=s['assets'])
        row('fake_image_refused', refused['images'] == 1 and refused['assets'] == 1 and refused['imageError'] == 'not an image'
            and len([x for x in refused['formats'] if x['type'] == 'image']) == 1, state={k: refused[k] for k in ('images', 'assets', 'imageError')})
        row('oversize_image_refused_before_decode', too_big['images'] == 1 and too_big['assets'] == 1
            and too_big['imageError'] == 'not an image', state={k: too_big[k] for k in ('images', 'assets', 'imageError')})

        # Look frames: a selection with the format bar, light and dark.
        domain = __import__('prefs_domain').domain()
        stored_scheme = subprocess.run(['defaults', 'read', domain, 'open.web.colorScheme'], capture_output=True, text=True)
        try:
            for scheme in ('light', 'dark'):
                app.call('command', id='appearance-' + scheme)
                app.call('note', action='select', start=s['body'].find('this'), length=4)
                time.sleep(.3)
                app.call('snapshot', path=os.path.join(frames, 'n2-formats-%s.png' % scheme))
        finally:
            if stored_scheme.returncode == 0:
                subprocess.run(['defaults', 'write', domain, 'open.web.colorScheme', stored_scheme.stdout.strip()])
            else:
                subprocess.run(['defaults', 'delete', domain, 'open.web.colorScheme'], capture_output=True)
        app.call('note', action='flush')
        final = app.call('note')
        row('stored_formats_match_editor', final['storedFormats'] == final['formats'] and final['stored']['text'] == final['body'],
            stored=final['storedFormats'], live=final['formats'])
        note_tab = final['tab']
    finally:
        app.quit()

    # 8. Relaunch: text, formats and the image come back exactly.
    app = factory(urls=())
    try:
        app.call('select', tab=note_tab)
        s = h.wait_until(lambda: (lambda v: v if v['tab'] == note_tab and v['shown'] else None)(app.call('note')), timeout=5, step=.05)
        s = s or app.call('note')
        row('relaunch_restores_formats', s['body'] == final['body'] and s['formats'] == final['formats'] and s['images'] == 1,
            formats=s['formats'], images=s['images'])
    finally:
        app.quit()
        server.shutdown()
