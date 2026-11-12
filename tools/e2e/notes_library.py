"""Library › Easels, Notes half, through the real App: Note rows next to Easel rows
(also a Note whose row is archived), Arc's one-item card menu "Delete", open a Note
without a row, delete from the Library. Socket only; synthetic text.
"""
import os
import subprocess
import time


def run(factory, results, tmp, h):
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('notes-library %-32s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def library(**kw): return app.call('library', **kw)

    def key(name, *mods): return app.call('key', key=name, modifiers=list(mods), route='app')

    frames = os.path.join(h.ROOT, '.re', 'nt-frames'); os.makedirs(frames, exist_ok=True)
    server, origin = h._fixture_server('NotesLibrary')
    app = factory(urls=(origin + '/page',), fresh=True)
    try:
        app.call('wait', tab=app.call('tabs')[0]['id'])
        app.call('note', action='create'); app.call('key', text='Alpha'); key('return'); app.call('key', text='first line of alpha')
        alpha = app.call('note')
        app.call('note', action='create'); app.call('key', text='Beta'); key('return'); app.call('key', text='beta body')
        beta = app.call('note')
        app.call('note', action='flush')
        app.call('close', tab=beta['tab'])   # archived row: the Note stays in the Library

        library(action='open', section='easels')
        lib = h.wait_until(lambda: (lambda x: x if x.get('section') == 'easels' and x.get('notes') == 2 and x.get('rows') else None)(library()), timeout=8, step=.2) or library()
        rows = {r.get('title'): r for r in lib.get('rows', [])}
        row('library_lists_notes', {'Alpha', 'Beta'} <= set(rows) and lib.get('notes') == 2
            and 'first line of alpha' in rows.get('Alpha', {}).get('subtitle', ''), titles=sorted(rows), notes=lib.get('notes'),
            alpha=rows.get('Alpha'))
        domain = __import__('prefs_domain').domain()
        time.sleep(.5)
        app.call('snapshot', path=os.path.join(frames, 'nl-library-notes.png'))

        b_row = rows.get('Beta', {}).get('id', '')
        menu = library(action='row-menu', id=b_row)['items'] if b_row else []
        library(action='row-action', id=b_row, name='open')
        opened = h.wait_until(lambda: (lambda v: v if v['shown'] and v['tabTitle'] == 'Beta' else None)(app.call('note')), timeout=8, step=.1)
        row('open_note_without_row', [m['title'] for m in menu] == ['Delete'] and opened and opened['body'] == 'beta body'
            and not library().get('open'), menu=menu, opened=(opened or {}).get('tabTitle'))

        library(action='open', section='easels')
        lib = h.wait_until(lambda: (lambda x: x if x.get('notes') == 2 and x.get('rows') else None)(library()), timeout=8, step=.2) or library()
        a_row = next((r['id'] for r in lib.get('rows', []) if r.get('title') == 'Alpha'), '')
        library(action='row-menu', id=a_row, select='Delete')
        alert = h.wait_until(lambda: (lambda s: s if s.get('shown') else None)(app.call('note', action='sheet')), timeout=5, step=.05) or {}
        app.call('note', action='sheet', press='Delete')
        after = h.wait_until(lambda: (lambda x: x if x.get('notes') == 1 else None)(library()), timeout=8, step=.2)
        row('library_delete_note', 'Are you sure you want to delete this Note?' in alert.get('texts', []) and after
            and not os.path.exists(alpha['file']) and all(t['id'] != alpha['tab'] for t in app.call('tabs')),
            alert=alert, after=(after or {}).get('notes'), fileExists=os.path.exists(alpha['file']))
        library(action='close')
    finally:
        app.quit()
        server.shutdown()
