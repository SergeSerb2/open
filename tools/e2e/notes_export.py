"""Notes N2b through the real App: export of every Note (HTML + Markdown + images,
one zip) with the empty case, and Settings ▸ Profiles ▸ New documents driving
New Note (⌃⇧N) through the real Settings popup.

Only the automation socket and the App's own event and menu paths are used.
Synthetic text and a generated PNG only; no user data.
"""
import os
import json
import runpy
import time
import uuid
import zipfile


def run(factory, results, tmp, h):
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('notes-export %-34s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def key(name, *mods):
        return app.call('key', key=name, modifiers=list(mods), route='app')

    png = runpy.run_path(os.path.join(h.ROOT, 'tools/e2e/notes_format.py'))['png']
    image = os.path.join(tmp, 'export-image.png'); png(image, 60, 40)
    server, origin = h._fixture_server('NotesExport')
    # No real network: word.new must not resolve; the loopback fixture stays reachable.
    app = factory(urls=(origin + '/page',), fresh=True, extra_args=['--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1'])
    try:
        app.call('wait', tab=app.call('tabs')[0]['id'])

        # 1. Empty case: no Note yet, nothing is written.
        empty_zip = os.path.join(tmp, 'empty.zip')
        state = app.call('note', action='export', path=empty_zip)
        row('export_without_notes_writes_nothing', state['last'] == 'none' and not os.path.exists(empty_zip), state=state)
        # C-NT3 (C-report-s11): Help ▸ Export Notes with no Notes: no phase-out alert (Open keeps Notes),
        # a toast at the window's top right with the text only (no "Click to report a bug.").
        app.call('menu-perform', id='export-notes')
        toast = h.wait_until(lambda: next((t for t in app.call('toasts')['toasts'] if t['title'].startswith('No Notes')), None), timeout=5, step=.1) or {}
        win = app.call('window-state')['frame']
        tf = toast.get('frame') or [0, 0, 0, 0]
        row('export_no_notes_toast_top_right', toast.get('title') == 'No Notes found to export.' and not toast.get('subtitle')
            and tf[0] + tf[2] > win[2] * 0.6 and tf[1] < 120 and not any(w.get('sheet') for w in [app.call('window-state')]),
            toast=toast, window=win)

        # 2. A Note with every kind of format, and a second one with the same title.
        app.call('note', action='create')
        app.call('key', text='Trip <plan>')
        key('return')
        app.call('key', text='# Day 1\r* pack *bags*\r* tickets\r')
        key('return')
        app.call('key', text='1. fly\r')
        key('return')
        app.call('key', text='see docs')
        body = app.call('note')['body']
        app.call('note', action='select', start=body.rfind('docs'), length=4)
        app.call('note', action='press', item='link')
        app.call('key', text=origin + '/docs'); key('return')
        app.call('note', action='select', start=len(body), length=0)
        key('return')
        app.call('note', action='paste-file', path=image)
        first = app.call('note')
        app.call('note', action='create')
        app.call('key', text='Trip <plan>'); key('return'); app.call('key', text='second copy')
        app.call('note', action='flush')

        out = os.path.join(tmp, 'notes.zip')
        app.call('note', action='export', path=out)
        done = h.wait_until(lambda: (lambda s: s if s['last'] == 'exported' and not s['running'] else None)(app.call('note', action='export-state')), timeout=20, step=.1)
        names, html, md, md2 = [], '', '', ''
        if done and os.path.exists(out):
            with zipfile.ZipFile(out) as z:
                names = z.namelist()
                def read(suffix):
                    match = [n for n in names if n.endswith(suffix)]
                    return z.read(match[0]).decode() if match else ''
                html = read('/Trip <plan>.html'); md = read('/Trip <plan>.md'); md2 = read('/Trip <plan> 2.md')
        image_files = [n for n in names if n.endswith('.png')]
        row('export_writes_html_markdown_and_images', bool(done) and done['count'] == 2 and len(image_files) == 1
            and '<h1 class="title">Trip &lt;plan&gt;</h1>' in html and '<h1>Day 1</h1>' in html
            and '<ul><li>pack <strong>bags</strong></li>\n<li>tickets</li></ul>' in html and '<ol><li>fly</li></ol>' in html
            and ('<a href="%s/docs">docs</a>' % origin) in html and 'src="data:image/png;base64,' in html
            and md.startswith('# Trip \\<plan\\>\n') and '\n## Day 1\n' in md and '\n- pack **bags**\n' in md
            and '\n1. fly\n' in md and ('[docs](%s/docs)' % origin) in md and '![](Trip%20%3Cplan%3E%20images/' in md
            and 'second copy' in md2 and not any(n.startswith('__MACOSX') for n in names),
            state=done, names=names, html=html[-900:], md=md)

        # 2b. A numbered list around a nested list: the HTML list at level 0 continues after
        # the nested one (one <ol>, so "two" is item 2), as the Markdown numbering does.
        app.call('note', action='create')
        app.call('key', text='Nested list'); key('return')
        app.call('key', text='1. one\r'); key('tab')
        app.call('key', text='sub\r')
        # Shift-Tab carries the back-tab character on real hardware; AppKit maps it to insertBacktab.
        app.call('key', key='tab', modifiers=['shift'], characters='\x19', route='app')
        app.call('key', text='two')
        nested_formats = app.call('note')['formats']
        app.call('note', action='flush')
        out2 = os.path.join(tmp, 'notes-nested.zip')
        app.call('note', action='export', path=out2)
        done2 = h.wait_until(lambda: (lambda s: s if s['last'] == 'exported' and not s['running'] and os.path.exists(out2) else None)(app.call('note', action='export-state')), timeout=20, step=.1)
        nested_html, nested_md = '', ''
        if done2:
            with zipfile.ZipFile(out2) as z:
                for n in z.namelist():
                    if n.endswith('/Nested list.html'): nested_html = z.read(n).decode()
                    if n.endswith('/Nested list.md'): nested_md = z.read(n).decode()
        body_html = nested_html.split('<h1 class="title">Nested list</h1>\n', 1)[-1]
        row('export_html_list_continues_after_nested_list', bool(done2)
            and body_html.startswith('<ol><li>one\n<') and '</li>\n<li>two</li></ol>' in body_html
            and body_html.count('<ol>') + body_html.count('<ul>') == 2 and '\n2. two' in nested_md,
            html=body_html, md=nested_md, formats=nested_formats)

        # 2c. A saved Note whose list levels are outside the editor's 0...5 (a damaged or hand-edited
        # file; the store decodes it as is) still exports, with the levels clamped. Two list paragraphs
        # of different types at Int.max used to trap in the HTML writer.
        notes_dir = next(os.path.join(d, 'Notes') for d, subs, _ in os.walk(app.user_data) if 'Notes' in subs
                         and any(n.endswith('.json') for n in os.listdir(os.path.join(d, 'Notes'))))
        bad_id = str(uuid.uuid4())
        with open(os.path.join(notes_dir, bad_id + '.json'), 'w') as f:
            json.dump({'formatVersion': 1, 'id': bad_id.upper(), 'title': 'Bad levels', 'text': 'deep\nshallow\nnegative',
                       'formats': [{'type': 'bulletList', 'location': 0, 'length': 4, 'level': 2 ** 63 - 1},
                                   {'type': 'numberedList', 'location': 5, 'length': 7, 'level': 2 ** 63 - 1},
                                   {'type': 'bulletList', 'location': 13, 'length': 8, 'level': -3}],
                       'createdAt': '2026-01-01T00:00:00Z', 'modifiedAt': '2026-01-01T00:00:00Z'}, f)
        out3 = os.path.join(tmp, 'notes-bad-levels.zip')
        app.call('note', action='export', path=out3)
        done3 = h.wait_until(lambda: (lambda s: s if s['last'] == 'exported' and not s['running'] and os.path.exists(out3) else None)(app.call('note', action='export-state')), timeout=20, step=.1)
        bad_html, bad_md = '', ''
        if done3:
            with zipfile.ZipFile(out3) as z:
                for n in z.namelist():
                    if n.endswith('/Bad levels.html'): bad_html = z.read(n).decode()
                    if n.endswith('/Bad levels.md'): bad_md = z.read(n).decode()
        row('export_out_of_range_list_levels_clamped', bool(done3)
            and '<ul><li>deep</li></ul>\n<ol><li>shallow</li></ol>\n<ul><li>negative' in bad_html
            and '\n' + ' ' * 10 + '- deep\n' + ' ' * 15 + '1. shallow\n- negative' in bad_md,
            html=bad_html[-400:], md=bad_md)

        # 3. Settings ▸ Profiles ▸ New documents (the real popup) changes what ⌃⇧N creates.
        app.call('settings-ui', action='open', section='profiles')
        app.call('settings-ui', action='link', url='open://settings/profiles/new-documents')
        shown = app.call('settings-ui', action='choice', label='New documents', title='Word Doc')
        frames = os.path.join(h.ROOT, '.re', 'nt-frames'); os.makedirs(frames, exist_ok=True)
        time.sleep(.4)
        app.call('snapshot', window=shown['window'], path=os.path.join(frames, 'n2b-settings-new-documents.png'))
        before = {t['id'] for t in app.call('tabs')}
        key('n', 'control', 'shift')
        added = h.wait_until(lambda: [t for t in app.call('tabs') if t['id'] not in before] or None, timeout=5, step=.05) or []
        word = [t['url'] for t in added]
        for t in added: app.call('close', tab=t['id'])
        app.call('settings-ui', action='choice', label='New documents', title='Note')
        before = {t['id'] for t in app.call('tabs')}
        key('n', 'control', 'shift')
        back = h.wait_until(lambda: [t for t in app.call('tabs') if t['id'] not in before] or None, timeout=5, step=.05) or []
        row('new_documents_setting_drives_new_note', word and word[0].startswith('https://word.new')
            and len(back) == 1 and back[0]['url'].startswith('open://note/'), word=word, back=[t['url'] for t in back])
    finally:
        app.quit()
        server.shutdown()
