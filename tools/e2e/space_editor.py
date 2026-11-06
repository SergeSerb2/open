"""Section 4 real-App icon flows. No shared defaults keys are changed."""
from pathlib import Path


def checks(factory, results, tmp, harness):
    app = factory(urls=(), fresh=True)

    def require(name, ok, *, fatal=True, **detail):
        print(name, 'PASS' if ok else 'FAIL', flush=True)
        results[name] = dict(detail, ok=bool(ok))
        if not ok and fatal:
            raise AssertionError(name)

    def state():
        return app.call('editor-state')

    def opened(**target):
        require('icon_open_' + ('node' if 'node' in target else 'space'),
                app.call('editor-open', kind='icon', **target))
        assert harness.wait_until(lambda: state().get('count', 0) > 0, timeout=5)

    def click(control, **args):
        app.call('editor-act', action='click', control=control, **args)

    def key(value):
        app.call('editor-act', action='key', key=value)

    def closed():
        return harness.wait_until(lambda: not state()['open'], timeout=3)

    def tree_folder(node):
        def find(nodes):
            for item in nodes:
                if item['id'] == node:
                    return item
                nested = find(item.get('children', []))
                if nested:
                    return nested
        tree = app.call('sidebar-tree')
        return find(tree['pinned'] + tree['today'])

    try:
        space = next(s['id'] for s in app.call('spaces') if s['focused'])
        tab = app.call('open', url='about:blank')['id']
        app.call('pin', tab=tab)
        app.call('sidebar-menu', node=tab, item='Change Icon…')
        require('tab_menu_opens', state()['open'])
        app.call('editor-close')
        opened(node=tab)
        require('A6_tab_default_emoji', state()['page'] == 'emoji')
        # Real key events through NSApplication -> panel -> search field.
        key('grinning face')
        require('A6_search', harness.wait_until(lambda: state()['search'] == 'grinning face' and state()['count'] < 20, timeout=3))
        key('down'); key('return')
        require('A6_tab_emoji_pick', closed() and app.tab(tab)['iconOverride'] == {'type': 'emoji', 'value': '😀'})
        app.call('sidebar-key', key='z', modifiers=['cmd'])
        require('tab_pick_undo', app.tab(tab)['iconOverride'] is None)
        app.call('sidebar-key', key='z', modifiers=['cmd', 'shift'])
        require('tab_pick_redo', app.tab(tab)['iconOverride'] == {'type': 'emoji', 'value': '😀'})
        app.quit(); app = factory(urls=())
        require('A6_tab_relaunch', app.tab(tab)['iconOverride'] == {'type': 'emoji', 'value': '😀'})

        require('space_command_open', app.call('command', id='change-space-icon'))
        assert harness.wait_until(lambda: state().get('count', 0) > 0, timeout=5)
        click('icons')
        require('space_icons_page', state()['page'] == 'icons')
        click('item', index=0)
        require('space_named_pick', closed() and next(s for s in app.call('spaces') if s['id'] == space)['icon'] == {'type': 'named', 'value': 'star'})
        folder = app.call('folder', title='Picker folder', tabs=[tab], section='pinned')
        app.call('sidebar-menu', node=folder, item='Change Icon…')
        require('folder_menu_opens', state()['open'])
        require('folder_default_icons', state()['page'] == 'icons')
        click('item', index=2)
        require('folder_named_pick', closed() and tree_folder(folder)['iconOverride'] == {'type': 'named', 'value': 'heart'})
        app.quit(); app = factory(urls=())
        require('space_folder_relaunch', next(s for s in app.call('spaces') if s['id'] == space)['icon'] == {'type': 'named', 'value': 'star'}
                and tree_folder(folder)['iconOverride'] == {'type': 'named', 'value': 'heart'})

        opened(node=tab)
        key('thumbs up')
        assert harness.wait_until(lambda: state()['search'] == 'thumbs up' and state()['count'] == 1, timeout=3)
        click('item', index=0, modifiers=['ctrl'])
        require('skin_tones_open', state()['tones'] == 6)
        click('tone', index=3)
        require('skin_tone_exact_pick', closed() and app.tab(tab)['iconOverride'] == {'type': 'emoji', 'value': '👍🏽'})
        opened(node=tab); click('remove')
        require('tab_remove', closed() and app.tab(tab)['iconOverride'] is None)
        opened(space=space); key('zzemptyemojiresult')
        require('emoji_empty_search', harness.wait_until(lambda: state()['count'] == 0, timeout=3))
        key('escape'); require('escape_search_closes', closed())
        opened(space=space)
        click('category-5')
        require('category_scroll_highlight', state()['category'] == 5)
        app.call('snapshot', window='editor', path=str(Path(tmp) / 'icon-picker-emoji.png'))
        click('icons')
        app.call('snapshot', window='editor', path=str(Path(tmp) / 'icon-picker-icons.png'))
        other = app.call('space-create', title='Other picker Space')
        require('space_switch_closes', closed())
        app.call('space', space=space)
        opened(space=space)
        # An in-App outside click uses the normal AppKit event route.
        app.call('mouse', action='click', x=400, y=300, queued=True)
        require('outside_click_closes', closed())
        require('close_idempotent', app.call('editor-close') and closed())
        # Global keys start at NSApplication with the picker as the key window.
        shortcut_rows = []
        for letter, mode in [('t', 'newTab'), ('l', 'editCurrentURL')]:
            opened(space=space)
            panel = app.call('native-focus-state')['keyWindow']
            app.call('key', key=letter, modifiers=['cmd'], route='app', window=panel)
            bar = app.call('commandbar-state')
            row = 'picker_cmd_' + letter
            require(row, closed() and bar['presented'] and bar['mode'] == mode, fatal=False)
            shortcut_rows.append(row)
            app.call('editor-close')
            app.call('key', key='escape', route='app')
        app.call('open', url='about:blank')
        opened(space=space)
        before_tabs = [t['id'] for t in app.call('tabs')]
        panel = app.call('native-focus-state')['keyWindow']
        app.call('key', key='w', modifiers=['cmd'], route='app', window=panel)
        require('picker_cmd_w', closed() and [t['id'] for t in app.call('tabs')] == before_tabs, fatal=False)
        shortcut_rows.append('picker_cmd_w')
        assert all(results[row]['ok'] for row in shortcut_rows), 'picker shortcut routing'
    finally:
        try:
            app.call('editor-close')
        except (RuntimeError, OSError):
            pass
        app.quit()
