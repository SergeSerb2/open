"""Import from Arc, Notes half, through the real App: a synthetic Arc folder with
two `arcDocument` sidebar rows (one with text in StorableARCDocuments, one without)
imported by the real Settings import sheet; then an Arc Notes export zip that fills
the placeholder and adds a new Note; re-import is idempotent; a bad zip is refused.

Synthetic data only (no Arc data of the user). The store and export spellings are
GUESSes (docs/re/easels-notes.md §4.4–4.6); the readers accept the likely variants.
"""
import base64
import json
import os
import runpy
import shutil
import uuid
import zipfile
from pathlib import Path


def run(factory, results, tmp, h):
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('notes-import %-34s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def has(formats, kind, start, length, **extra):
        return any(f['type'] == kind and f['location'] == start and f['length'] == length
                   and all(f.get(k) == v for k, v in extra.items()) for f in formats)

    source = Path(tmp) / 'arc-notes'
    shutil.rmtree(source, ignore_errors=True)
    ids = runpy.run_path(os.path.join(h.ROOT, 'tools/e2e/firstrun.py'))['fixture'](source)
    data = json.loads((source / 'StorableSidebar.json').read_text())
    graph = data['sidebar']['containers'][1]
    def ident(name): return str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/notes-import/' + name)).upper()
    with_text, without = ident('row-a'), ident('row-b')
    graph['items'] += [with_text, {'id': with_text, 'childrenIds': [], 'title': 'Groceries',
                                   'data': {'arcDocument': {'arcDocumentID': 'DOC-A', 'isEditable': True,
                                                            'customInfo': {'iconType': {'emoji_v2': '\U0001F34E'}}}}},
                       without, {'id': without, 'childrenIds': [], 'title': 'Trip ideas',
                                 'data': {'arcDocument': {'arcDocumentID': 'DOC-B', 'isEditable': True}}}]
    today = graph['items'][graph['items'].index(ids['ta']) + 1]
    today['childrenIds'] += [with_text, without]
    (source / 'StorableSidebar.json').write_text(json.dumps(data))
    store = source / 'StorableARCDocuments'; store.mkdir()
    (store / 'DOC-A.json').write_text(json.dumps({'version': 1, 'arcDocument': {
        'id': 'DOC-A', 'title': {'value': 'Groceries', 'lastUpdatedAt': 0},
        'data': {'scratchpad': {'blocks': ['B1', {'id': 'B1', 'type': 'fullBlob', 'version': 1,
            'text': 'Fruit\nmilk and eggs', 'content': [], 'lastUpdatedAt': 0, 'properties': [
                {'richText': {'range': [0, 5], 'value': {'h1': {}}}},
                {'richText': {'range': [6, 4], 'value': 'bold'}},
                {'richText': {'range': [15, 4], 'value': {'formattedHyperlink': {'url': 'https://example.com/eggs'}}}}]}],
            'rootBlocks': ['B1']}},
        'shareStatus': 'privateDocument', 'creatorID': 'synthetic', 'createdAt': 0}}))
    (store / 'broken.json').write_text('{"not":')

    png = runpy.run_path(os.path.join(h.ROOT, 'tools/e2e/notes_format.py'))['png']
    pic = os.path.join(tmp, 'zip-image.png'); png(pic, 30, 20)
    picture = base64.b64encode(Path(pic).read_bytes()).decode()
    export = os.path.join(tmp, 'Arc-Notes-Export.zip')
    with zipfile.ZipFile(export, 'w') as z:
        z.writestr('Arc-Notes-Export/Trip ideas.html',
                   '<!doctype html><html><head><title>Trip ideas</title><style>p{}</style></head><body>'
                   '<h1>Trip ideas</h1><h2>Places</h2><ul><li>Lisbon &amp; <strong>Porto</strong></li><li>Kyoto</li></ul>'
                   '<p>See <a href="https://example.com/map">the map</a></p><p><img src="data:image/png;base64,%s"></p>'
                   '</body></html>' % picture)
        z.writestr('Arc-Notes-Export/extra.json', json.dumps({'id': 'DOC-C', 'title': 'Extra',
                   'html': '<p>hello <em>there</em></p>', 'lastUpdatedAt': 0}))
        z.writestr('Arc-Notes-Export/readme.txt', 'ignored')
    bad = os.path.join(tmp, 'not-a-zip.zip')
    Path(bad).write_text('plain text')

    app = factory(urls=(), fresh=True, extra_args=['--arc-dir=' + str(source), '--host-resolver-rules=MAP * ~NOTFOUND'])
    try:
        def state(): return app.call('first-run')
        app.call('first-run', action='settings-import', directory=str(source))
        app.call('first-run', action='settings-select', history=False)
        app.call('first-run', action='settings-next'); app.call('first-run', action='settings-run')
        assert h.wait_until(lambda: state().get('settingsStep') == 'Report', timeout=60, step=.05), state()
        outcome = state().get('settingsOutcome')
        app.call('first-run', action='settings-done')
        def all_notes():
            # Imported rows land in the imported Spaces; walk every Space.
            found = {}
            for space in app.call('spaces'):
                app.call('space', space=space['id'])
                for t in app.call('tabs'):
                    if t['url'].startswith('open://note/'): found[t['title']] = dict(t, space=space['id'])
            return found
        notes = all_notes()
        row('import_creates_note_rows', 'Groceries' in notes and 'Trip ideas' in notes and outcome.get('Notes') == 2
            and outcome.get('Note placeholders') == 1 and outcome.get('Sidebar accounted') == outcome.get('Sidebar total'),
            notes=list(notes), outcome=outcome)
        # `customInfo.iconType` (easels-notes.md §4.3) becomes the Note row's custom icon; no icon stays none.
        row('custom_icon_imported', notes.get('Groceries', {}).get('iconOverride') == {'type': 'emoji', 'value': '\U0001F34E'}
            and notes.get('Trip ideas', {}).get('iconOverride') is None,
            icons={k: v.get('iconOverride') for k, v in notes.items()})

        def show(title):
            app.call('space', space=notes[title]['space'])
            app.call('select', tab=notes[title]['id'])
            return h.wait_until(lambda: (lambda v: v if v['tab'] == notes[title]['id'] and v['shown'] else None)(app.call('note')), timeout=5, step=.05) or app.call('note')
        g = show('Groceries')
        row('stored_arc_text_and_formats', g['title'] == 'Groceries' and g['body'] == 'Fruit\nmilk and eggs'
            and has(g['formats'], 'h1', 0, 5) and has(g['formats'], 'bold', 6, 4)
            and has(g['formats'], 'link', 15, 4, url='https://example.com/eggs') and not g['importPlaceholder'], state=g)
        t = show('Trip ideas')
        row('missing_text_is_a_placeholder', t['importPlaceholder'] and t['body'].startswith('Arc kept this Note') and t['title'] == 'Trip ideas', state=t)

        # The export zip: fills the placeholder (by title), adds the Note with a new Arc id.
        bad_result = app.call('note', action='import-zip', path=bad)
        first = app.call('note', action='import-zip', path=export)
        t2 = h.wait_until(lambda: (lambda v: v if v['shown'] and v['body'] != t['body'] else None)(app.call('note')), timeout=5, step=.05) or app.call('note')
        body = 'Places\nLisbon & Porto\nKyoto\nSee the map\n￼'
        row('bad_zip_refused', bad_result['error'] != '' and bad_result['filled'] == 0 and bad_result['added'] == 0, result=bad_result)
        row('export_zip_fills_placeholder', first['filled'] == 1 and t2['tab'] == notes['Trip ideas']['id'] and t2['body'] == body
            and has(t2['formats'], 'h2', 0, 6) and has(t2['formats'], 'bulletList', 7, 14, level=0) and has(t2['formats'], 'bold', 16, 5)
            and has(t2['formats'], 'link', 32, 7, url='https://example.com/map') and t2['images'] == 1 and t2['assets'] == 1
            and not t2['importPlaceholder'], result=first, state=t2)
        app.call('space', space=notes['Trip ideas']['space'])
        extra = [x for x in app.call('tabs') if x['title'] == 'Extra' and x['url'].startswith('open://note/')]
        if extra:
            app.call('select', tab=extra[0]['id'])
            e = h.wait_until(lambda: (lambda v: v if v['tab'] == extra[0]['id'] and v['shown'] else None)(app.call('note')), timeout=5, step=.05) or app.call('note')
        else: e = {}
        row('export_zip_adds_new_note', first['added'] == 1 and e.get('body') == 'hello there' and has(e.get('formats', []), 'italic', 6, 5),
            result=first, state=e)
        again = app.call('note', action='import-zip', path=export)
        row('reimport_is_idempotent', again['filled'] == 0 and again['added'] == 0 and again['alreadyPresent'] == 2
            and len([x for x in app.call('tabs') if x['title'] == 'Extra']) == 1, result=again)
    finally:
        app.quit()
