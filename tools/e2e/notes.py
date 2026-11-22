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

    if os.environ.get('OPEN_E2E_NOTES_SIZE_ONLY') == '1':
        size_limit_rows(factory, row, h)
        return
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

        # Print… and Save Page As… act on a web page only: on a Note they are disabled, not enabled no-ops.
        page_items = ('print', 'save-page-as')
        on_note = {r['id']: r['enabled'] for r in app.call('menu-state') if r['id'] in page_items}
        # ⌘P through the App's real key path on the Note: no Print command runs, the Note is unchanged.
        windows_before = len(app.call('shell-windows'))
        pressed = app.call('key', key='p', modifiers=['cmd'], route='app', observeCommands=True)
        note_after = app.call('note')
        key_ok = ('print' not in pressed['commands'] and not any('print' in m for m in pressed['menuActions'])
                  and note_after['tab'] == first and note_after['body'] == 'Milk\nEggs'
                  and len(app.call('shell-windows')) == windows_before)
        app.call('select', tab=web)
        h.wait_until(lambda: app.call('note')['tab'] == web, timeout=5, step=.05)
        on_page = h.wait_until(lambda: (lambda m: m if all(m.get(i) for i in page_items) else None)(
            {r['id']: r['enabled'] for r in app.call('menu-state') if r['id'] in page_items}), timeout=5, step=.05)
        row('page_commands_disabled_on_note', len(on_note) == 2 and not any(on_note.values()) and bool(on_page) and key_ok,
            onNote=on_note, onPage=on_page, commandP={k: pressed[k] for k in ('commands', 'menuActions', 'firstResponder')})

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
        domain = __import__('prefs_domain').domain()
        stored_scheme = subprocess.run(['defaults', 'read', domain, 'open.web.colorScheme'], capture_output=True, text=True)
        try:
            looks = {}
            for scheme in ('light', 'dark'):
                app.call('command', id='appearance-' + scheme)
                looks[scheme] = h.wait_until(lambda: (lambda v: v if v['dark'] == (scheme == 'dark') else None)(app.call('note')), timeout=3, step=.05)
                app.call('note', action='focus', field='body')
                time.sleep(.3)
                app.call('snapshot', path=os.path.join(frames, 'n1-note-%s.png' % scheme))
            row('appearance_follows_view_menu', bool(looks['light']) and bool(looks['dark'])
                and looks['light']['background'] == '#FFFFFF' and looks['dark']['background'] == '#121212',
                light=looks['light'] and looks['light']['background'], dark=looks['dark'] and looks['dark']['background'], frames=frames)
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
    size_limit_rows(factory, row, h)


def size_limit_rows(factory, row, h):
    """Bug sweep r2 #5: a Note whose file would be over the store's 32 MiB read limit is not written.
    The file keeps the last saved text, the window says so, and the Note opens again after a relaunch.
    Before, the save wrote the large file and every later open refused it ("Can't load this note").

    The body is '/' lines: JSON stores '/' as two bytes, so about 17 M characters make a file over
    the limit, in two pastes under the socket's 16 MiB request limit.
    """
    limit = 32 << 20
    app = factory(urls=(), fresh=True)
    try:
        app.call('note', action='create')
        h.wait_until(lambda: (lambda v: v if v['isNote'] and v['shown'] else None)(app.call('note')), timeout=5, step=.05)
        app.call('note', action='focus', field='title')
        app.call('note', action='type', text='Big note')
        app.call('note', action='focus', field='body')
        app.call('note', action='type', text='Short body')
        app.call('note', action='flush')
        small = app.call('note')
        file = small['file']
        line = '/' * 99 + '\n'
        chunk = line * 84000
        started = time.time()
        # The first paste fits (about 16.8 MB on disk): it is saved. The second one would make the file
        # over the limit: that save is refused, and the file keeps the first paste.
        app.call('note', action='paste', text=chunk, timeout=300)
        app.call('note', action='flush', timeout=300)
        fits = os.path.getsize(file) if os.path.exists(file) else 0
        shown_before = app.call('toasts')['shown']
        app.call('note', action='paste', text=chunk, timeout=300)
        paste_seconds = round(time.time() - started, 1)
        # The debounced save runs right after the paste. Its toast lives 10 s, which a 34 MB reply can
        # outlast on a loaded machine: read the window's toast count and last title instead.
        after = h.wait_until(lambda: (lambda t: t if t['shown'] > shown_before else None)(app.call('toasts')), timeout=8, step=.1) \
            or app.call('toasts')
        shown_after, toasts = after['shown'], [after.get('lastTitle', '')]
        encodes_before = app.call('note', timeout=300).get('encodeCount')
        # A later edit is refused too, and says so again (each refused save is an edit not on disk).
        app.call('note', action='type', text='x', timeout=300)
        app.call('note', action='flush', timeout=300)
        again = app.call('toasts')
        big = app.call('note', timeout=300)
        # Bug sweep r3 L21: a refused save of a Note whose text alone encodes over the limit does not
        # encode the whole Note again (before, every debounced save copied it to JSON).
        row('oversized_note_not_encoded_again', encodes_before is not None and big.get('encodeCount') == encodes_before,
            encodesBefore=encodes_before, encodesAfter=big.get('encodeCount'))
        size = os.path.getsize(file) if os.path.exists(file) else 0
        row('oversized_note_not_written', small['stored'] and small['stored']['text'] == 'Short body'
            and 0 < fits < limit and size == fits and len(big['body']) == 2 * len(chunk) + len('Short body') + 1
            and 'limit' in big['storeError'] and shown_after == shown_before + 1 and 'too large' in toasts[0]
            and again['shown'] == shown_after + 1 and 'too large' in again.get('lastTitle', ''),
            fileBytes=size, savedFirstPaste=fits, limit=limit, storeError=big['storeError'][:200], toasts=toasts, toastsShown=[shown_before, shown_after, again['shown']],
            bodyCharacters=len(big['body']), pasteSeconds=paste_seconds)
        expected_body = len(chunk) + len('Short body')
        note_tab = big['tab']
    finally:
        app.quit()
    app = factory(urls=())
    try:
        app.call('select', tab=note_tab)
        back = h.wait_until(lambda: (lambda v: v if v['tab'] == note_tab and v['shown'] else None)(app.call('note')), timeout=10, step=.1)
        back = back or app.call('note')
        row('oversized_note_reopens_last_save', not back['unreadable'] and back['editable'] and back['title'] == 'Big note'
            and len(back['body']) == expected_body and back['body'].startswith('Short body'),
            unreadable=back['unreadable'], title=back['title'][:40], bodyCharacters=len(back['body']), expected=expected_body)
    finally:
        app.quit()
