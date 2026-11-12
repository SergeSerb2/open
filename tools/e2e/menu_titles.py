"""Menu bar titles and order against Arc 1.172.2's runtime menu bar (capture AX trees,
docs/re/menus-and-hotkeys.md "Arc 1.172.2 runtime menu bar").

Reads the real App's menu with `menu-tree` (visible items only; separators collapse) in
two states: a web page selected, and the same window with two Today tabs selected.
No route, validation or selector is replaced. Synthetic pages only.
"""
import json
import os

# Arc 1.172.2's visible titles in order, with Open's deliberate differences applied
# (each one listed in OPEN_DIFFERENCES). '---' is a separator. macOS's own Window items
# (Fill, Center, Move & Resize, Full Screen Tile, Minimize All / Zoom All, Arrange in
# Front, Remove Window from Set) and the window list are left out of the comparison.
EXPECTED = {
    'Open': ['About Open', '---', 'Settings…', 'Set as Default Browser', '---', 'Import from Another Browser…',
             'Check for Updates…', '---', 'Services', '---', 'Hide Open', 'Hide Other Windows', 'Show All', '---', 'Quit Open'],
    'File': ['New Tab…', 'New Window', 'Blank Window', 'New Incognito Window', 'New Little Open Window',
             'Restore Last Closed Tab', '---', 'Open Command Bar', '---', 'New Profile', 'New Note', 'New Note (in Split)',
             'New Easel', '---', 'Close Window', 'Archive Tab', '---', 'Share…', 'Capture…', 'Capture Full Page',
             'Capture in Portrait Mode', 'Save Page As', 'Print'],
    'Edit': ['Undo', 'Redo', '---', 'Cut', 'Copy', 'Copy URL', 'Copy URL as Markdown', 'Copy URL as Quote', 'Paste',
             'Paste and Match Style', 'Delete', 'Select All', '---', 'Find'],
    'Find': ['Find…', 'Find and Replace', 'Find Next', 'Find Previous', 'Use Selection to Find', 'Jump to Selection'],
    'View': ['Appearance', '---', 'Hide Sidebar', 'Show Toolbar', 'Collapse Pinned Tabs', '---', 'Stop Loading',
             'Refresh the Page', 'Force Refresh the Page', 'Clear Cookies and Refresh', 'Clear Cache and Refresh', '---',
             'Add Split View', 'Close this Split Pane', 'Separate Page from Split View', 'Expand Current Split', '---',
             'Zoom to Actual Size', 'Zoom In', 'Zoom Out', '---', 'Developer', '---', 'Enter Full Screen'],
    'Developer': ['View Source', 'Developer Tools', 'Inspect Elements', 'JavaScript Console', 'Network Inspector',
                  'Allow JavaScript from Apple Events', 'Turn on Developer Mode for this site'],
    'Appearance': ['Websites, Easels, and Notes will use:', 'Automatic', 'Light', 'Dark'],
    'Spaces': ['New Space…', 'Edit Theme…', 'Rename Space', 'Change Profile', '---', 'Next Space', 'Previous Space'],
    'Tabs': ['New Tab…', 'Pin Tab', 'New Folder…', '---', 'Next Tab', 'Previous Tab', 'Reveal Tab in Sidebar', '---',
             'Clear Today', 'Reset all tabs in this Space'],
    'Archive': ['Go Back', 'Go Forward', '---', 'View History', 'View Archive…', 'Clear Archive'],
    'Extensions': ['Add Extension…', 'Manage Extensions…'],
    'Window': ['Stay On Top', 'Minimize Window', 'Zoom', '---', 'Open Library…', 'View Downloads…', 'View Media…',
               'View Boosts…', '---', 'Bring All to Front'],
    'Help': ['Getting Started', 'Essential Keyboard Shortcuts', 'Contact the Team', 'Visit Help Center', 'Export Notes',
             '---', 'Troubleshooting'],
    'Troubleshooting': ['Record Trace', 'Open Task Manager', '---', 'Reveal Open Data', 'Copy Open Info'],
}
SYSTEM_WINDOW_ITEMS = {'Minimize All', 'Zoom All', 'Fill', 'Center', 'Move & Resize', 'Full Screen Tile',
                       'Arrange in Front', 'Remove Window from Set'}


def visible(items, name, window_titles=()):
    out = []
    for item in items:
        if item.get('hidden'):
            continue
        title = '---' if item.get('separator') else item.get('title', '')
        if name == 'Window' and (title in SYSTEM_WINDOW_ITEMS or title in window_titles):
            continue
        if not title:  # macOS's Help search field and other view items
            continue
        if title == '---' and (not out or out[-1] == '---'):
            continue
        out.append(title)
    while out and out[-1] == '---':
        out.pop()
    return out


def flatten(tree, window_titles):
    menus = {}
    def walk(items, name):
        menus[name] = visible(items, name, window_titles)
        for item in items:
            if item.get('children') and not item.get('hidden'):
                walk(item['children'], item.get('title', ''))
    for top in tree:
        if top.get('children'):
            walk(top['children'], top.get('title', ''))
    return menus


def run(factory, results, tmp, h):
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('menu-titles %-34s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    server, origin = h._fixture_server('MenuTitles')
    app = factory(urls=(origin + '/one', origin + '/two'), fresh=True)
    try:
        tabs = app.call('tabs')
        app.call('wait', tab=tabs[0]['id'])
        app.call('select', tab=tabs[0]['id'])
        windows = {w.get('title', '') for w in app.call('shell-windows')}
        menus = flatten(app.call('menu-tree'), windows)
        out = os.path.join(h.ROOT, '.re', 'menu-titles'); os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, 'open-menu-page.json'), 'w') as f:
            json.dump(menus, f, indent=1, ensure_ascii=False)
        for name, expected in EXPECTED.items():
            got = menus.get(name, [])
            # Spaces and Tabs end with dynamic lists; macOS appends Writing Tools, AutoFill, Dictation… to Edit.
            if name in ('Spaces', 'Tabs', 'Edit'):
                got = got[:len(expected)]
            row('menu_' + name.lower(), got == expected, got=got, expected=expected)
        spaces = menus.get('Spaces', [])
        row('menu_spaces_ends_with_manage', spaces[-2:] == ['---', 'Manage Spaces…'], tail=spaces[-3:])

        # Two Today tabs selected: Arc's plural titles for the selection (capture union: Pin Tabs and
        # New Folder from Selection…; both commands act on the selection in Open).
        app.call('sidebar-click', node=tabs[0]['id']); app.call('sidebar-click', node=tabs[1]['id'], modifiers=['cmd'])
        many = flatten(app.call('menu-tree'), windows)
        with open(os.path.join(out, 'open-menu-selection.json'), 'w') as f:
            json.dump(many, f, indent=1, ensure_ascii=False)
        app.call('sidebar-key', key='escape')
        after = flatten(app.call('menu-tree'), windows)
        row('menu_selection_titles', 'Pin Tabs' in many.get('Tabs', []) and 'New Folder from Selection…' in many.get('Tabs', [])
            and after.get('Tabs', [])[1:3] == ['Pin Tab', 'New Folder…'], tabs=many.get('Tabs'), after=after.get('Tabs'))

        # Window ▸ Stay On Top floats this window and shows a checkmark; choosing it again restores it.
        def level():
            return app.call('shell-windows')[0]['level']
        def checked():
            return next((r.get('checked') for r in app.call('menu-tree') if r.get('title') == 'Window'
                         for r in r['children'] if r.get('id') == 'stay-on-top'), None)
        before = (level(), checked())
        app.call('menu-perform', id='stay-on-top')
        on = (level(), checked())
        app.call('menu-perform', id='stay-on-top')
        off = (level(), checked())
        row('stay_on_top_toggles', before == (0, 0) and on == (3, 1) and off == (0, 0), before=before, on=on, off=off)
    finally:
        app.quit()
        server.shutdown()
