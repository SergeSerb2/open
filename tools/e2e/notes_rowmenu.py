"""Note sidebar row menu through the real App: the menu built as a right-click builds
it (order as the Easel row, Copy Link disabled), inline rename, Export Note… (panel
and file), Remove Note from Sidebar + restore, Add Split View, Delete Note (Cancel,
then Delete). Socket only; synthetic text.
"""
import os
import time


def run(factory, results, tmp, h):
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('notes-rowmenu %-32s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def key(name, *mods):
        return app.call('key', key=name, modifiers=list(mods), route='app')

    def sheet(**kw):
        return h.wait_until(lambda: (lambda s: s if s.get('shown') else None)(app.call('note', action='sheet', **kw)), timeout=5, step=.05)

    server, origin = h._fixture_server('NotesRow')
    app = factory(urls=(origin + '/page',), fresh=True)
    try:
        web = app.call('tabs')[0]['id']
        app.call('wait', tab=web)
        app.call('note', action='create'); app.call('key', text='Alpha'); key('return'); app.call('key', text='first body')
        a = app.call('note')['tab']
        app.call('note', action='create'); app.call('key', text='Beta')
        b = app.call('note')['tab']
        app.call('note', action='flush')

        menu = app.call('note', action='row-menu', tab=a)
        expected = ['Copy Link', 'Export Note…', '—', 'Change Icon…', 'Rename…', '—', 'Add Split View', 'Move to ▸', '—',
                    'Remove Note from Sidebar', 'Delete Note']
        enabled = {t: e for t, e in menu['enabled']}
        copy = app.call('sidebar-menu-state', node=a, item='Copy Link')
        row('row_menu_order_copy_link_disabled', menu['items'] == expected and not enabled['Copy Link']
            and all(enabled[t] for t in expected if t not in ('—', 'Copy Link', 'Move to ▸')) and not copy['enabled'],
            menu=menu, copy=copy)

        # Rename: a shown Note (B) and a Note not shown (A).
        shown = app.call('note', action='rename', tab=b, text='Beta two')
        hidden = app.call('note', action='rename', tab=a, text='Alpha renamed')
        app.call('select', tab=a)
        a_state = h.wait_until(lambda: (lambda v: v if v['tab'] == a and v['shown'] else None)(app.call('note')), timeout=5, step=.05) or {}
        row('rename_syncs_row_and_note', shown['title'] == 'Beta two' and shown['tabTitle'] == 'Beta two'
            and hidden['tabTitle'] == 'Alpha renamed' and hidden['stored']['title'] == 'Alpha renamed'
            and a_state.get('title') == 'Alpha renamed' and a_state.get('body') == 'first body',
            shown={k: shown[k] for k in ('title', 'tabTitle')}, hidden={k: hidden[k] for k in ('tabTitle', 'stored')}, a=a_state.get('title'))

        # Export Note…: the real panel (cancelled), then the same export to a file.
        app.call('sidebar-menu', node=a, item='Export Note…')
        panel = sheet() or {}
        app.call('note', action='sheet', cancel=True)
        out = os.path.join(tmp, 'alpha.html')
        app.call('note', action='export-one', tab=a, path=out)
        html = open(out).read() if os.path.exists(out) else ''
        row('export_note', panel.get('isSavePanel') and panel.get('name') == 'Alpha renamed.html'
            and '<h1 class="title">Alpha renamed</h1>' in html and '<p>first body</p>' in html, panel=panel, html=html[-200:])

        # Add Split View from the row menu.
        app.call('sidebar-menu', node=a, item='Add Split View')
        split = h.wait_until(lambda: (lambda s: s if s['id'] and len(s['panes']) == 2 else None)(app.call('split', op='state')), timeout=5, step=.05)
        row('add_split_view', bool(split) and a in [p['id'] for p in split['panes']], split=split)
        if split: app.call('split', op='menu', item='Separate All Tabs')

        # Remove Note from Sidebar archives the row; the Note file stays; Restore brings it back with its text.
        file_before = app.call('note', tab=a)['file']
        app.call('sidebar-menu', node=a, item='Remove Note from Sidebar')
        gone = h.wait_until(lambda: all(t['id'] != a for t in app.call('tabs')) or None, timeout=5, step=.05)
        kept = os.path.exists(file_before)
        key('t', 'command', 'shift')
        back = h.wait_until(lambda: [t for t in app.call('tabs') if t['url'].startswith('open://note/') and t['title'] == 'Alpha renamed'] or None, timeout=5, step=.1) or []
        restored = {}
        if back:
            app.call('select', tab=back[0]['id'])
            restored = h.wait_until(lambda: (lambda v: v if v['tab'] == back[0]['id'] and v['shown'] else None)(app.call('note')), timeout=5, step=.05) or {}
        row('remove_from_sidebar_then_restore', gone and kept and restored.get('body') == 'first body', kept=kept, restored=restored.get('body'))
        a = back[0]['id'] if back else a

        # Delete Note: Cancel keeps it; Delete removes the row and the file (not to the Archive).
        app.call('sidebar-menu', node=a, item='Delete Note')
        alert = sheet() or {}
        app.call('note', action='sheet', press='Cancel')
        time.sleep(.3)
        still = any(t['id'] == a for t in app.call('tabs')) and os.path.exists(file_before)
        app.call('sidebar-menu', node=a, item='Delete Note')
        sheet(); app.call('note', action='sheet', press='Delete')
        deleted = h.wait_until(lambda: all(t['id'] != a for t in app.call('tabs')) or None, timeout=5, step=.05)
        row('delete_note_cancel_then_delete', 'Are you sure you want to delete this Note?' in alert.get('texts', [])
            and 'Doing so will delete the Note permanently.' in alert.get('texts', []) and sorted(alert.get('buttons', [])) == ['Cancel', 'Delete']
            and still and deleted and not os.path.exists(file_before), alert=alert, still=still, fileExists=os.path.exists(file_before))

        # A selection of only Notes: the last item is Arc's plural "Remove Notes from Sidebar" and Copy Links /
        # Share are disabled (a Note has no address). With a web tab in the selection it stays "Archive Tabs".
        app.call('note', action='create'); app.call('key', text='Gamma')
        c = app.call('note')['tab']
        app.call('note', action='flush')
        files = [app.call('note', tab=t)['file'] for t in (b, c)]
        app.call('sidebar-click', node=b); app.call('sidebar-click', node=c, modifiers=['cmd'])
        notes_only = app.call('sidebar-menu-items', node=b)
        app.call('sidebar-key', key='escape')
        app.call('sidebar-click', node=b); app.call('sidebar-click', node=web, modifiers=['cmd'])
        mixed = app.call('sidebar-menu-items', node=b)
        app.call('sidebar-key', key='escape')
        app.call('sidebar-click', node=b); app.call('sidebar-click', node=c, modifiers=['cmd'])
        # Without the item (old code) the call is refused: the row then FAILs instead of stopping the suite.
        h._try(lambda: app.call('sidebar-menu', node=b, item='Remove Notes from Sidebar'))
        removed = h.wait_until(lambda: all(t['id'] not in (b, c) for t in app.call('tabs')) or None, timeout=5, step=.05)
        row('selection_of_notes_menu', 'Remove Notes from Sidebar' in notes_only['items'] and 'Archive Tabs' not in notes_only['items']
            and {'Copy Links', 'Share 2 Items…'} <= set(notes_only['disabled'])
            and 'Archive Tabs' in mixed['items'] and 'Remove Notes from Sidebar' not in mixed['items'] and 'Copy Links' not in mixed['disabled']
            and bool(removed) and all(os.path.exists(f) for f in files),
            notesOnly=notes_only, mixed=mixed['items'], removed=bool(removed))

        # Two rows of one Note (Duplicate keeps the address): an edit in one row's editor shows in the
        # other's, and typing there keeps both edits (an older editor copy must not overwrite the file).
        def shown(tab):
            return h.wait_until(lambda: (lambda v: v if v['tab'] == tab and v['shown'] else None)(app.call('note')), timeout=5, step=.05) or {}
        app.call('note', action='create'); app.call('key', text='Delta'); key('return'); app.call('key', text='one')
        d = app.call('note')['tab']
        d_url = app.call('note', tab=d)['url']
        app.call('note', action='flush')
        app.call('menu-perform', id='duplicate-tab')
        twins = h.wait_until(lambda: (lambda r: r if len(r) == 2 else None)([t['id'] for t in app.call('tabs') if t['url'] == d_url]), timeout=5, step=.1) or []
        e = next((t for t in twins if t != d), None)
        seen, stored, hosts, seen_before = {}, {}, 0, None
        if e:
            app.call('select', tab=e); shown(e)
            app.call('select', tab=d); shown(d)
            app.call('note', action='select', start=3, length=0)
            app.call('note', action='type', text=' two')
            # Read row B's editor by tab before showing it: an editor made again from the file
            # would pass without the sync.
            pre = app.call('note', tab=e)
            seen_before = pre.get('body') if pre.get('hasHost') else None
            app.call('select', tab=e); seen = shown(e)
            hosts = seen.get('noteHostCount', 0)
            app.call('note', action='select', start=len(seen.get('body', '')), length=0)
            app.call('note', action='type', text=' three')
            # A title typed in one row's editor becomes the title of both rows.
            app.call('note', action='focus', field='title')
            app.call('note', action='type', text=' Two')
            app.call('note', action='flush')
            stored = app.call('note', tab=d).get('stored') or {}
        titles = sorted(t['title'] for t in app.call('tabs') if t['url'] == d_url)
        row('duplicate_rows_share_edits', seen_before == 'one two' and seen.get('body') == 'one two' and stored.get('text') == 'one two three'
            and bool(stored.get('title')) and titles == [stored.get('title')] * 2,
            twins=twins, seenBefore=seen_before, seen=seen.get('body'), stored=stored.get('text'), storedTitle=stored.get('title'), titles=titles, noteHosts=hosts)

        # Bug sweep r2: Delete Note also removes Archive entries of the Note's rows that left the
        # sidebar earlier (Remove Note from Sidebar on a twin row: another row ID). Before, restoring
        # such an entry gave a row of a Note whose file is in the Trash (an empty Note).
        app.call('note', action='create'); app.call('key', text='Zeta'); key('return'); app.call('key', text='zeta body')
        z = app.call('note')['tab']
        z_url = app.call('note', tab=z)['url']
        app.call('note', action='flush')
        app.call('menu-perform', id='duplicate-tab')
        z_rows = h.wait_until(lambda: (lambda r: r if len(r) == 2 else None)([t['id'] for t in app.call('tabs') if t['url'] == z_url]), timeout=5, step=.1) or []
        z2 = next((t for t in z_rows if t != z), None)
        archived_before, left = [], None
        if z2:
            app.call('sidebar-menu', node=z2, item='Remove Note from Sidebar')
            h.wait_until(lambda: all(t['id'] != z2 for t in app.call('tabs')) or None, timeout=5, step=.05)
            archived_before = h.wait_until(lambda: [r['id'] for r in app.call('archive-list')['rows'] if r['url'] == z_url] or None, timeout=5, step=.1) or []
            app.call('sidebar-menu', node=z, item='Delete Note')
            sheet(); app.call('note', action='sheet', press='Delete')
            h.wait_until(lambda: all(t['id'] != z for t in app.call('tabs')) or None, timeout=5, step=.05)
            h.wait_until(lambda: not [r for r in app.call('archive-list')['rows'] if r['url'] == z_url] or None, timeout=5, step=.1)
            left = [r['id'] for r in app.call('archive-list')['rows'] if r['url'] == z_url]
        row('delete_note_drops_archived_twin', len(z_rows) == 2 and archived_before == [z2] and left == [],
            rows=z_rows, archivedBefore=archived_before, archivedAfter=left)

        # Bug sweep r2 seed #4: one Note row shown in two windows (each window has its own editor). An
        # edit in window 2 shows in window 1's editor before it is shown again, and typing there keeps both.
        app.call('note', action='create'); app.call('key', text='Eta'); key('return'); app.call('key', text='one')
        w_tab = app.call('note')['tab']
        app.call('note', action='flush')
        first_window = app.call('window-state')['id']
        app.call('command', id='new-window')
        second_window = h.wait_until(lambda: next((v['id'] for v in app.call('shell-windows') if v['id'] != first_window), None), timeout=5, step=.1)
        w_seen, w_stored = None, {}
        if second_window:
            app.call('window-focus', id=second_window, activate=True)
            app.call('select', tab=w_tab); shown(w_tab)
            app.call('note', action='select', start=3, length=0)
            app.call('note', action='type', text=' two')
            app.call('window-focus', id=first_window, activate=True)
            pre = app.call('note', tab=w_tab)
            w_seen = pre.get('body') if pre.get('hasHost') else None
            app.call('select', tab=w_tab); after = shown(w_tab)
            app.call('note', action='select', start=len(after.get('body', '')), length=0)
            app.call('note', action='type', text=' three')
            app.call('note', action='flush')
            w_stored = app.call('note', tab=w_tab).get('stored') or {}
            app.call('window-focus', id=second_window, activate=True)
            app.call('window-close')
            app.call('window-focus', id=first_window, activate=True)
        row('two_windows_share_edits', w_seen == 'one two' and w_stored.get('text') == 'one two three',
            windows=[first_window, second_window], seenInFirstWindow=w_seen, stored=w_stored.get('text'))

        # Bug sweep r3 L20: Delete Note also removes the Note's row from inside an archived folder.
        # Before, the folder's stored children kept it, and restoring the folder brought back a row of
        # a Note whose file is in the Trash (an empty Note). The folder's other row stays.
        app.call('note', action='create'); app.call('key', text='Theta'); key('return'); app.call('key', text='theta body')
        th = app.call('note')['tab']
        th_url = app.call('note', tab=th)['url']
        app.call('note', action='create'); app.call('key', text='Iota')
        io = app.call('note')['tab']
        io_url = app.call('note', tab=io)['url']
        app.call('note', action='flush')
        app.call('select', tab=th); shown(th)
        app.call('menu-perform', id='duplicate-tab')
        th_rows = h.wait_until(lambda: (lambda r: r if len(r) == 2 else None)([t['id'] for t in app.call('tabs') if t['url'] == th_url]), timeout=5, step=.1) or []
        th2 = next((t for t in th_rows if t != th), None)
        archived_kind, restored_urls, status = None, None, None
        if th2:
            profile = app.tab(th)['profile']
            folder = app.call('folder', tabs=[th2, io], title='R3 Notes', section='pinned')
            app.call('sidebar-menu', node=folder, item='Delete')
            h.wait_until(lambda: app.call('window-state')['confirmation'], timeout=5, step=.05)
            app.call('alert', button='Delete Folder')
            folder_row = h.wait_until(lambda: next((r for r in app.call('archive-list', profile=profile)['rows'] if r['id'] == folder), None), timeout=5, step=.1) or {}
            archived_kind = folder_row.get('kind')
            app.call('sidebar-menu', node=th, item='Delete Note')
            sheet(); app.call('note', action='sheet', press='Delete')
            h.wait_until(lambda: all(t['url'] != th_url for t in app.call('tabs')) or None, timeout=5, step=.05)
            app.call('library-open', section='archive')
            h.wait_until(lambda: any(r['id'] == folder for r in app.call('settings-state')['archive']), timeout=5, step=.1)
            status = app.call('library-restore', id=folder)
            restored_urls = h.wait_until(lambda: (lambda u: u if io_url in u else None)([t['url'] for t in app.call('tabs')]), timeout=5, step=.1) or []
            app.call('library-close')
        row('delete_note_drops_row_in_archived_folder', len(th_rows) == 2 and archived_kind == 'folder'
            and restored_urls is not None and io_url in restored_urls and th_url not in restored_urls,
            rows=th_rows, archivedKind=archived_kind, restoreStatus=status, restoredHasDeleted=th_url in (restored_urls or []),
            restoredHasKept=io_url in (restored_urls or []))
    finally:
        app.quit()
        server.shutdown()
