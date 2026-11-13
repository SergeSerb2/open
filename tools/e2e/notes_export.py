"""Notes N2b through the real App: export of every Note (HTML + Markdown + images,
one zip) with the empty case, and Settings ▸ Profiles ▸ New documents driving
New Note (⌃⇧N) through the real Settings popup.

Only the automation socket and the App's own event and menu paths are used.
Synthetic text and a generated PNG only; no user data.
"""
import os
import runpy
import time
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
