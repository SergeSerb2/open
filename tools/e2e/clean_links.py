"""Clean links through real row, selection, folder, page and toast menu actions."""


def checks(app, results, origin, h):
    singular = 'Copied a clean link without trackers'
    plural = 'Copied clean links without trackers'

    def record(name, ok, **evidence):
        results['CL_' + name] = dict(ok=bool(ok), **evidence)

    def copy(name, node, menu, expected, title):
        shown = app.call('toasts')['shown']
        app.call('pasteboard', text='clean-links-copy-sentinel')
        # Open's "Copy links as Markdown" on a selection is an ⌥ alternate (drawn menu = Arc's, session 8 item 6).
        app.call('sidebar-menu', node=node, item=menu, **({'alternate': True} if menu == 'Copy links as Markdown' else {}))
        actual = app.call('pasteboard')
        toast_state = app.call('toasts')
        toast = h.page_newest_toast(app, title) if title else None
        record(name, actual == expected and (bool(toast) and toast_state['shown'] == shown + 1 if title
                                            else toast_state['shown'] == shown),
               actual=actual, expected=expected, toast=toast, shownBefore=shown, shownAfter=toast_state['shown'])

    def share(name, action, node):
        app.call('sidebar-share', dismiss=True)
        try:
            action()
            request = app.call('sidebar-share', waitClosed=True)
            record(name, request.get('url') == clean[0] and request.get('payloadURLs') == [clean[0]]
                   and request.get('node') == node and request.get('servicesRequested')
                   and request.get('closed') and not request.get('pending'), request=request)
        finally:
            app.call('sidebar-share', close=True, dismiss=False)

    raw = [origin + '/en.html?utm_source=copy&keep=1&fbclid=tracker#top',
           origin + '/en.html?keep=2&utm_campaign=copy#second']
    clean = [origin + '/en.html?keep=1#top', origin + '/en.html?keep=2#second']
    ids = [h.new_tab(app, url) for url in raw]
    for tab in ids:
        app.call('wait', tab=tab)
    try:
        app.call('select', tab=ids[0])
        copy('row_plain', ids[0], 'Copy Link', clean[0], singular)
        app.call('sidebar-click', node=ids[0])
        app.call('sidebar-click', node=ids[1], modifiers=['cmd'])
        by_id = dict(zip(ids, clean))
        selection = app.call('selection')
        record('selection_contains_both_tabs', set(selection) == set(ids))
        copy('selection_plain', ids[0], 'Copy Links', '\n'.join(by_id[tab] for tab in selection), plural)
        markdown = '\n'.join('[%s](%s)' % (app.tab(tab)['title'], url) for tab, url in zip(ids, clean))
        selection_markdown = '\n'.join('[%s](%s)' % (app.tab(tab)['title'], by_id[tab]) for tab in selection)
        copy('selection_markdown', ids[0], 'Copy links as Markdown', selection_markdown, plural)
        app.call('sidebar-key', key='escape')
        folder = app.call('folder', tabs=ids, title='Clean Link Fixtures', section='pinned')
        copy('folder_plain', folder, 'Copy All Links', '\n'.join(clean), plural)
        copy('folder_markdown', folder, 'Copy All Links as Markdown', markdown, plural)
        # The live model must retain the original navigation URLs.
        record('navigation_unchanged', [app.tab(tab)['url'] for tab in ids] == raw)
        app.call('select', tab=ids[0])
        # Share ▸ lists the system services (capture session 8 item 1); the first one, recorded, not opened.
        service = app.call('sidebar-menu-items', node=ids[0], path='Share')['items'][0]
        share('row_share', lambda: app.call('sidebar-menu', items=['Share', service], node=ids[0]), ids[0])
        share('page_share', lambda: app.call('menu-perform', id='share-page'), 'page')
        app.call('menu-perform', id='copy-url')
        share('toast_share', lambda: app.call('toast-action', index=0), 'toast')
        app.call('navigate', tab=ids[0], url=clean[0])
        app.call('wait', tab=ids[0])
        # Sidebar plain copies currently have no toast. Do not invent one.
        copy('row_without_trackers', ids[0], 'Copy Link', clean[0], None)
        app.call('menu-perform', id='copy-url')
        record('copy_url_plain_toast_unchanged', app.call('pasteboard') == clean[0]
               and bool(h.page_newest_toast(app, 'Copied Current URL')))
        app.call('navigate', tab=ids[1], url=clean[1])
        app.call('wait', tab=ids[1])
        copy('folder_without_trackers', folder, 'Copy All Links', '\n'.join(clean), None)
        app.call('navigate', tab=ids[1], url=raw[1])
        app.call('wait', tab=ids[1])
        copy('folder_mixed_trackers', folder, 'Copy All Links', '\n'.join(clean), plural)
        # The no-browser Manager has a separate fallback writer.
        space = next(space['id'] for space in app.call('spaces') if space['focused'])
        app.call('window-close')
        try:
            app.call('library-open')
            h.wait_until(lambda: app.call('space-manager-state').get('contextValid'), timeout=5)
            app.call('pasteboard', text='manager-copy-sentinel')
            app.call('space-manager-menu', space=space, node=ids[1], item='Copy Link')
            record('manager_without_browser', app.call('shell-windows') == []
                   and app.call('pasteboard') == clean[1], actual=app.call('pasteboard'))
            # Folder Copy All Links has the same no-browser fallback (review R1 finding 1).
            app.call('pasteboard', text='manager-copy-sentinel')
            app.call('space-manager-menu', space=space, node=folder, item='Copy All Links')
            record('manager_folder_without_browser', app.call('shell-windows') == []
                   and app.call('pasteboard') == '\n'.join(clean), actual=app.call('pasteboard'))
        finally:
            app.call('library-close')
            app.call('window-reopen')
        app.call('sidebar-drop', nodes=ids, parent=dict(kind='today', id=space), index=0)
        app.call('select', tab=ids[1])
        app.call('wait', tab=ids[1])
        app.call('eval', tab=ids[1], js="document.title = 'Clean Split Tracker'")
        h.wait_until(lambda: app.tab(ids[1])['title'] == 'Clean Split Tracker', timeout=5)
        app.call('select', tab=ids[0])
        app.call('sidebar-menu', node=ids[1], item='Open in Split View')
        panes = [pane['id'] for pane in app.call('split', op='state')['panes']]
        record('split_contains_both_tabs', set(panes) == set(ids))
        split = app.call('split', op='state')['id']
        copy('split_pane_markdown', split, 'Clean Split Tracker/Copy link as Markdown',
             '[%s](%s)' % (app.tab(ids[1])['title'], clean[1]), singular)
        shown = app.call('toasts')['shown']
        app.call('split', op='menu', item='Copy Link')
        record('split_menu_plain', app.call('pasteboard') == '\n'.join(by_id[tab] for tab in panes)
               and bool(h.page_newest_toast(app, plural)) and app.call('toasts')['shown'] == shown + 1,
               actual=app.call('pasteboard'))
        app.call('split', op='menu', item='Separate All Tabs')
    finally:
        app.call('sidebar-share', close=True, dismiss=False)
        for tab in ids:
            app.call('close', tab=tab)
