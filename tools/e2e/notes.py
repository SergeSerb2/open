"""Notes N1 through the real App: File ▸ New Note / New Note (in Split) by their
keys and menu actions, typing into the native editor with real key events, the
debounced store on disk, and quit + relaunch.

Only the automation socket and the App's own event and menu paths are used.
Synthetic text only; no user data.
"""
import os
import subprocess
import time


def run(factory, results, tmp, h):
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('notes %-36s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    server, origin = h._fixture_server('Notes')
    app = factory(urls=(origin + '/page-a',), fresh=True)
    try:
        web = app.call('tabs')[0]['id']
        app.call('wait', tab=web)
        before = app.call('note')
        created_engine = before['engineContentCreationCount']

        # 1. ⌃⇧N through the App's key routing and the File menu carrier.
        app.call('key', key='n', modifiers=['control', 'shift'], route='app', observeCommands=True)
        s = h.wait_until(lambda: (lambda v: v if v['isNote'] and v['shown'] else None)(app.call('note')), timeout=5, step=.05)
        s = s or app.call('note')
        tabs = app.call('tabs')
        row('new_note_shortcut_opens_note', s['isNote'] and s['shown'] and s['hasHost']
            and s['url'].startswith('open://note/') and s['focused'] == 'title' and s['tabTitle'] == 'Untitled'
            and s['favicon'] and tabs[0]['id'] == s['tab'] and tabs[0]['section'] == 'today',
            state=s, tabs=[{k: t[k] for k in ('id', 'url', 'section', 'title')} for t in tabs])
        row('note_never_reaches_engine', not s['engineHostForTab']
            and s['engineContentCreationCount'] == created_engine,
            before=created_engine, after=s['engineContentCreationCount'])
        row('untouched_note_writes_no_file', s['stored'] is None and not s['pendingWrites'], state=s)
        first = s['tab']; first_note = s['noteID']

        # 2. Real key events: title, Return moves to the body, two body lines.
        app.call('key', text='Groceries')
        app.call('key', key='return')
        after_return = app.call('note')
        app.call('key', text='Milk')
        app.call('key', key='return')
        app.call('key', text='Eggs')
        s = app.call('note')
        row('typing_edits_title_and_body', s['title'] == 'Groceries' and s['body'] == 'Milk\nEggs'
            and after_return['focused'] == 'body' and s['tabTitle'] == 'Groceries'
            and any(t['id'] == first and t['title'] == 'Groceries' for t in app.call('tabs')), state=s,
            focusAfterReturn=after_return['focused'])
        saved = h.wait_until(lambda: (lambda v: v if v['stored'] and v['stored']['text'] == 'Milk\nEggs'
                                      and not v['pendingWrites'] else None)(app.call('note')), timeout=3, step=.05)
        row('store_saves_after_debounce', bool(saved) and saved['stored']['title'] == 'Groceries'
            and saved['stored']['formatVersion'] == 1 and not saved['storeError'], state=saved or app.call('note'))

        # 3. The title is one paragraph: a pasted line break becomes a space.
        app.call('note', action='focus', field='title')
        app.call('note', action='paste', text=' list\nfor Friday')
        s = app.call('note')
        row('title_stays_one_line', s['title'] == 'Groceries list for Friday' and s['tabTitle'] == s['title'], state=s)

        # 4. A second Note from the File menu action (registry command), then the first again.
        app.call('note', action='create')
        second = app.call('note')
        app.call('select', tab=first)
        back = h.wait_until(lambda: (lambda v: v if v['tab'] == first and v['shown'] else None)(app.call('note')), timeout=5, step=.05)
        back = back or app.call('note')
        row('second_note_and_switch_back', second['isNote'] and second['noteID'] != first_note and second['title'] == ''
            and back['title'] == 'Groceries list for Friday' and back['body'] == 'Milk\nEggs', second=second, back=back)

        # 5. ⌃⌥N beside a web page: a Split with the page and a new Note.
        app.call('select', tab=web)
        h.wait_until(lambda: app.call('note')['tab'] == web, timeout=5, step=.05)
        app.call('key', key='n', modifiers=['control', 'option'], route='app', observeCommands=True)
        split = h.wait_until(lambda: (lambda v: v if v['id'] and len(v['panes']) == 2 else None)(app.call('split', op='state')), timeout=5, step=.05)
        split = split or app.call('split', op='state')
        note = app.call('note')
        panes = [p for p in split['panes'] if not p['hidden']]
        ids = [p['id'] for p in panes]
        frames = sorted((p['frame'] for p in panes), key=lambda f: f[0])
        row('new_note_in_split_beside_page', len(panes) == 2 and web in ids and note['tab'] in ids and note['isNote']
            and note['shown'] and split['focused'] == note['tab'] and all(p['host'] for p in panes)
            and frames[1][0] > frames[0][0] and note['focused'] == 'title',
            split=split, note=note)
        app.call('key', text='Side note')
        split_note = app.call('note')['tab']
        app.call('note', action='flush')
        stored = app.call('note')
        row('split_note_saves', stored['stored'] and stored['stored']['title'] == 'Side note'
            and stored['tabTitle'] == 'Side note'
            and any(t['id'] == split_note and t['title'] == 'Side note' for t in app.call('tabs')), state=stored,
            tabs=[(t['id'], t['title']) for t in app.call('tabs')])
        broken_file = stored['file']
    finally:
        app.quit()
    # Failure case: a damaged Note file is shown read-only and never overwritten.
    with open(broken_file, 'w') as f:
        f.write('not a note')

    # 6. Quit and relaunch the same data root: text and titles come back.
    app = factory(urls=())
    try:
        tabs = app.call('tabs')
        by_id = {t['id']: t for t in tabs}
        row('relaunch_restores_rows', first in by_id and by_id[first]['title'] == 'Groceries list for Friday'
            and split_note in by_id and by_id[split_note]['title'] == 'Side note',
            tabs=[{k: t[k] for k in ('id', 'url', 'section', 'title')} for t in tabs])
        def note_icons():
            rows = [t for t in app.call('tabs') if t['url'].startswith('open://note/')]
            return rows if rows and all(t.get('rowFaviconSource') in ('provider', 'live') for t in rows) else None
        icons = h.wait_until(note_icons, timeout=5, step=.1)
        row('relaunch_rows_draw_note_icon', bool(icons),
            rows=[(t['title'], t.get('rowFaviconSource')) for t in app.call('tabs') if t['url'].startswith('open://note/')])
        unshown = app.call('note', tab=first)
        row('relaunch_reads_no_note_before_shown', not unshown['hasHost'] or unshown['tab'] == app.call('note')['tab'],
            state={k: unshown[k] for k in ('hasHost', 'noteHostCount', 'tab')})
        app.call('select', tab=first)
        s = h.wait_until(lambda: (lambda v: v if v['tab'] == first and v['shown'] else None)(app.call('note')), timeout=5, step=.05)
        s = s or app.call('note')
        row('relaunch_restores_text', s['title'] == 'Groceries list for Friday' and s['body'] == 'Milk\nEggs'
            and s['favicon'] and not s['engineHostForTab'], state=s)
        # Look frames (light + dark) for the lead's review; View ▸ Appearance drives the Note.
        frames = os.path.join(h.ROOT, '.re', 'nt-frames')
        os.makedirs(frames, exist_ok=True)
        domain = 'io.github.sergeserb2.open'
        stored_scheme = subprocess.run(['defaults', 'read', domain, 'open.web.colorScheme'], capture_output=True, text=True)
        try:
            looks = {}
            for scheme in ('light', 'dark'):
                app.call('command', id='appearance-' + scheme)
                looks[scheme] = h.wait_until(lambda: (lambda v: v if v['dark'] == (scheme == 'dark') else None)(app.call('note')), timeout=3, step=.05)
                app.call('note', action='focus', field='body')
                time.sleep(.3)
                app.call('snapshot', path=os.path.join(frames, 'n1-note-%s.png' % scheme))
            row('appearance_follows_view_menu', bool(looks['light']) and bool(looks['dark']),
                light=bool(looks['light']), dark=bool(looks['dark']), frames=frames)
        finally:
            if stored_scheme.returncode == 0:
                subprocess.run(['defaults', 'write', domain, 'open.web.colorScheme', stored_scheme.stdout.strip()])
            else:
                subprocess.run(['defaults', 'delete', domain, 'open.web.colorScheme'], capture_output=True)
        app.call('select', tab=split_note)
        broken = h.wait_until(lambda: (lambda v: v if v['tab'] == split_note and v['shown'] else None)(app.call('note')), timeout=5, step=.05)
        broken = broken or app.call('note')
        app.call('note', action='focus', field='body')
        app.call('key', text='x')
        app.call('note', action='flush')
        with open(broken_file) as f:
            kept = f.read()
        row('damaged_file_read_only_and_kept', broken['unreadable'] and not broken['editable']
            and app.call('note')['body'] == '' and kept == 'not a note'
            and app.call('note')['tabTitle'] == 'Side note', state=broken, kept=kept)
        app.call('select', tab=second['tab'])
        empty = h.wait_until(lambda: (lambda v: v if v['tab'] == second['tab'] and v['shown'] else None)(app.call('note')), timeout=5, step=.05)
        empty = empty or app.call('note')
        row('empty_note_restores_empty', empty['isNote'] and empty['title'] == '' and empty['body'] == ''
            and empty['stored'] is None and empty['tabTitle'] == 'Untitled', state=empty)
        time.sleep(.3)
        app.call('snapshot', path=os.path.join(frames, 'n1-note-empty.png'))
    finally:
        app.quit()
        server.shutdown()
