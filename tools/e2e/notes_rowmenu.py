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
    finally:
        app.quit()
        server.shutdown()
