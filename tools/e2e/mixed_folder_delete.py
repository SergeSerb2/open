"""C13-D2-6: normal folder + Today selection, through the real sidebar menu and stores."""
from pathlib import Path
import os


def checks(h, factory, results, tmp):
    app = factory(urls=(), fresh=True)

    def record(name, condition, **detail):
        results['C13_mixed_delete_' + name] = dict(detail, ok=bool(condition))

    def ids(nodes):
        return {node['id'] for node in nodes} | {child for node in nodes for child in ids(node.get('children', []))}

    def sidebar_ids():
        tree = app.call('sidebar-tree')
        return ids(tree['pinned'] + tree['today'])

    def select():
        app.call('sidebar-click', node=folder)
        app.call('sidebar-click', node=today, modifiers=['cmd'])

    def delete():
        select()
        app.call('sidebar-menu', node=folder, item='Delete')
        return h.wait_until(lambda: app.call('window-state')['confirmation'], timeout=3, step=.05)

    try:
        space = app.call('space-create', title='C13 Delete', profile='C13 Delete Profile')
        app.call('space', space=space)
        made = []
        for name in ('F1', 'F2', 'T1', 'Archive Control'):
            path = Path(tmp) / ('c13-delete-' + name.replace(' ', '-') + '.html')
            path.write_text('<title>C13 %s</title><h1>%s</h1>' % (name, name))
            node = app.call('open', url=path.as_uri())['id']
            app.call('wait', tab=node)
            made.append(node)
        first, second, today, control = made
        profile = app.tab(today)['profile']
        app.call('close', tab=control)
        folder = app.call('folder', tabs=[first, second], title='C13 Folder', section='pinned')
        before = sidebar_ids()
        archive_before = app.call('archive-list', profile=profile)['rows']
        select()
        menu = app.call('sidebar-menu-items', node=folder)
        record('menu', menu['items'] == ['Copy Links', 'Share 2 Items…', '—', 'Open in Split View',
               'Move to ▸', 'New Folder with 2 Items', '—', 'Delete', '—']
               and menu['disabled'] == ['Open in Split View'], menu=menu)
        sheet = delete()
        record('confirmation', sheet and sheet['title'] == 'Delete your “C13 Folder” folder?'
               and sheet['text'] == 'Deleting this folder will archive the tabs inside it.'
               and set(sheet['buttons']) == {'Cancel', 'Delete Folder'}, sheet=sheet)
        if os.environ.get('OPEN_MIXED_DELETE_EARLY_FAILURE') == '1':
            raise RuntimeError('deliberate early failure with the mixed Delete sheet open')
        app.call('alert', button='Cancel')
        record('cancel', sidebar_ids() == before and app.call('archive-list', profile=profile)['rows'] == archive_before)
        delete()
        app.call('alert', button='Delete Folder')
        h.wait_until(lambda: folder not in sidebar_ids(), timeout=3, step=.05)

        def archived_result():
            rows = app.call('archive-list', profile=profile)['rows']
            added = [r for r in rows if r['id'] not in {r['id'] for r in archive_before}]
            return (not ({folder, first, second, today} & sidebar_ids())
                    and {r['id'] for r in added} == {first, second, today}
                    and all(r['kind'] == 'tab' for r in added)
                    and [r for r in rows if r['id'] == control] == [r for r in archive_before if r['id'] == control]), rows

        valid, rows = archived_result()
        record('separate_archive_rows', valid, archive=rows, sidebar=app.call('sidebar-tree'))
        app.call('toast-undo')
        record('one_undo', sidebar_ids() == before and app.call('archive-list', profile=profile)['rows'] == archive_before)
        def visible_archive(name):
            expected = {first: 'C13 F1', second: 'C13 F2', today: 'C13 T1'}
            app.call('library', action='open', section='archive')
            try:
                h.wait_until(lambda: set(expected) <= {r['id'] for r in app.call('library').get('rows', [])}, timeout=5, step=.05)
                rows = app.call('library').get('rows', [])
                actual = {r['id']: r for r in rows}
                record(name, folder not in actual and set(expected) <= actual.keys()
                       and all(actual[node]['kind'] == 'archive' and actual[node]['title'] == title
                               for node, title in expected.items()), rows=rows)
            finally:
                app.call('library', action='close')

        # Repeat the same captured action after Undo, then prove normal quit/relaunch persistence.
        delete()
        app.call('alert', button='Delete Folder')
        visible_archive('visible_archive_rows')
        app.call('save')
        app.quit()
        app = factory(urls=(), fresh=False)
        app.call('space', space=space)
        valid, rows = archived_result()
        record('relaunch', valid, archive=rows, sidebar=app.call('sidebar-tree'))
        visible_archive('relaunch_archive_rows')
    finally:
        if not app.closed:
            if h._try(lambda: app.call('window-state')['confirmation']):
                h._try(lambda: app.call('alert', button='Cancel'))
            app.quit()
