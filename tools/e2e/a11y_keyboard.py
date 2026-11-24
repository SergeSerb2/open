"""Real-App keyboard and accessibility rows (UX round 1 wave 2, lane UXF).

Reads the App in-process over the automation socket (`ax-tree`, `ax-debug`, `responder`, `library`,
`settings-ui`); keys go through the real path (`key`, route app = NSApp.sendEvent). No system
accessibility client, no System Events, no VoiceOver.

  a11y_sidebar_rows_reach_voiceover   the outline's AXChildren/AXRows by value and by count list its
                                      tab rows, and each row names the outline as its parent (K6)
  a11y_sidebar_untitled_row_label     a tab that has not loaded has a non-empty row label (K7)
  a11y_no_leaked_decorative_images    no "selected"/"Down" images under the Library button, no
                                      "Search" image beside the Settings or Find fields (K8, K9)
  a11y_favorites_card_reachable       the Favorites list is named and holds the empty-state card with
                                      a labelled Close button (K11)
  a11y_commandbar_field_label         the command bar's text field has a label (K10)
  a11y_settings_keyboard              Tab from search lands on the selected section; ↓/↑ move between
                                      sections; Tab from a section reaches the page's text fields (K1, K2)
  a11y_library_focus_ring             Tab to a rail item that is not the selected section draws its ring (K4)
"""
import http.server
import json
import os
import threading
import time
import uuid
from loopback_http import LoopbackHTTPServer


def run(factory, results, tmp, h):
    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith('/slow'):
                time.sleep(12)  # keeps this tab without a title while the rows are read (K7)
            body = ('<!doctype html><title>A11y %s</title><h1>%s</h1>' % (self.path, self.path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *_): pass
    server = LoopbackHTTPServer(Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('a11y-keyboard %-36s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def attempt(name, fn):
        try: fn()
        except Exception as error: row(name, False, error=repr(error))

    # Two tabs from the launch list: the first answers slowly, so it has no title yet (K7).
    app = factory(urls=(base + '/slow', base + '/two'), fresh=True, extra_args=['--favorites-empty-state=shown'])
    try:
        tabs = app.call('tabs'); app.call('wait', tab=next(t['id'] for t in tabs if t['url'].endswith('/two')))
        state = app.call('window-state'); app.call('window-focus', id=state['id'], activate=True); time.sleep(.4)
        browser = next(w['number'] for w in app.call('windows') if w.get('class', '').endswith('BrowserWindow'))

        def key(name=None, mods=None, text=None, window=None):
            a = dict(route='app', window=window or browser)
            if name is not None: a['key'] = name
            if mods: a['modifiers'] = mods
            if text is not None: a['text'] = text
            return app.call('key', **a)

        def tree(window):
            return app.call('ax-tree', window=window)['nodes']

        def sidebar_rows():
            debug = app.call('ax-debug', window=browser)['tables']
            outline = next((t for t in debug if t['class'] == 'SidebarOutlineView'), {})
            ok = (outline.get('modern', 0) >= 3 and outline.get('attributeChildren') == outline.get('modern')
                  and outline.get('unignored') == outline.get('modern')
                  and all(not d.get('ignored') and d.get('element') for d in outline.get('detail', []))
                  and outline.get('attributeRows') == outline.get('modern')
                  and outline.get('arrayCountChildren') == outline.get('modern')
                  and outline.get('arrayCountRows') == outline.get('modern')
                  and all(d.get('parentIsTable') for d in outline.get('detail', [])))
            row('a11y_sidebar_rows_reach_voiceover', ok, outline=outline)
        attempt('a11y_sidebar_rows_reach_voiceover', sidebar_rows)

        def untitled():
            titles = [t.get('title') for t in app.call('tabs')]
            rows = [n for n in tree(browser) if n['class'] == 'SidebarRowView']
            row('a11y_sidebar_untitled_row_label', '' in titles and len(rows) >= 3 and all(n['label'] for n in rows),
                titles=titles, rows=[(n['label'], n['frame']) for n in rows])
        attempt('a11y_sidebar_untitled_row_label', untitled)

        def favorites_card():
            h.wait_until(lambda: app.call('favorites-empty-state').get('shown') or None, timeout=5, step=.1)
            nodes = tree(browser)
            listed = next((n for n in nodes if n['role'] == 'AXList' and n['class'] == 'FavoritesCollectionView'), None)
            card = next((n for n in nodes if n['role'] == 'AXGroup' and n['label'] == 'Drag to add Favorites'), None)
            close = next((n for n in nodes if n['role'] == 'AXButton' and n['label'] == 'Close'
                          and card and n['path'].startswith(card['path'] + '/')), None)
            row('a11y_favorites_card_reachable', listed is not None and listed['label'] == 'Favorites' and card and close
                and listed and card['path'].startswith(listed['path'] + '/'),
                list=listed and (listed['label'], listed['path']), card=card and card['path'], close=close and close['path'])
        attempt('a11y_favorites_card_reachable', favorites_card)

        leaked = []
        def images_main():
            leaked.extend((n['label'], n['class'], 'main') for n in tree(browser)
                          if n['role'] == 'AXImage' and n['label'] in ('selected', 'Down', 'Search'))
        attempt('a11y_no_leaked_decorative_images', images_main)

        def find_images():
            key('f', ['cmd']); time.sleep(.5)
            leaked.extend((n['label'], n['class'], 'find') for n in tree(browser) if n['role'] == 'AXImage' and n['label'] == 'Search')
            key('escape'); time.sleep(.3)
        attempt('a11y_no_leaked_decorative_images', find_images)

        def commandbar():
            key('t', ['cmd']); time.sleep(.6)
            window = app.call('native-focus-state')['keyWindow']
            fields = [n for n in tree(window) if n['role'] == 'AXTextField']
            row('a11y_commandbar_field_label', fields and all(n['label'] for n in fields),
                fields=[(n['class'], n['label']) for n in fields])
            key('escape', window=window); time.sleep(.4)
        attempt('a11y_commandbar_field_label', commandbar)

        def library():
            key('l', ['cmd', 'shift']); time.sleep(1)
            window = app.call('native-focus-state')['keyWindow']
            key('tab', window=window); time.sleep(.3)
            rail = app.call('library').get('rail', [])
            focused = next((t for t in rail if t.get('focused')), None)
            row('a11y_library_focus_ring', focused is not None and not focused.get('selected') and focused.get('focusRing') is True,
                focused=focused, rail=[(t['id'], t.get('selected'), t.get('focused'), t.get('focusRing')) for t in rail])
            key('escape', window=window); time.sleep(.6)
        attempt('a11y_library_focus_ring', library)

        SECTIONS = ['general', 'appearance', 'tabs-archive', 'search', 'links', 'downloads', 'previews', 'ad-blocking',
                    'site-permissions', 'passwords-cards', 'browsing-data', 'profiles', 'shortcuts', 'extensions', 'advanced']
        def settings():
            app.call('defaults', key='open.general.searchSuggestNoticeDismissed', value=True)
            app.call('menu-perform', id='settings'); time.sleep(1)
            window = app.call('settings-ui')['window']
            def who():
                r = app.call('responder', window=window)
                return r.get('class', ''), r.get('label') or r.get('title') or ''
            try:
                for section in ['general', 'ad-blocking', 'shortcuts']:
                    app.call('settings-ui', action='open', section=section); time.sleep(.5)
                    leaked.extend((n['label'], n['class'], 'settings-' + section) for n in tree(window)
                                  if n['role'] == 'AXImage' and n['label'] in ('Search', 'magnifyingglass'))
                app.call('settings-ui', action='open', section='ad-blocking'); time.sleep(.6)
                app.call('settings-ui', action='focus-nav', section='general'); time.sleep(.2)
                key('tab', ['shift'], window=window); time.sleep(.3)   # back to the search field
                ring = app.call('settings-ui').get('searchFocusRing')
                row('a11y_settings_search_ring', who()[0] == 'SettingsSearchField' and ring is True, responder=who(), ring=ring)
                key('tab', window=window); time.sleep(.2)
                from_search = app.call('responder', window=window)
                key('down', window=window); time.sleep(.4)
                down = (app.call('settings-ui')['section'], app.call('responder', window=window).get('label'))
                key('up', window=window); time.sleep(.4)
                up = (app.call('settings-ui')['section'], app.call('responder', window=window).get('label'))
                key('tab', window=window); time.sleep(.3)
                into_page = app.call('responder', window=window)
                row('a11y_settings_keyboard', from_search.get('label') == 'Ad Blocking' and down == ('site-permissions', 'Site Permissions')
                    and up == ('ad-blocking', 'Ad Blocking') and into_page.get('label') == 'Search block lists',
                    fromSearch=from_search.get('label'), down=down, up=up, intoPage=into_page.get('label'))
                # Every pane, both directions (review r1 #1): from the selected section, Tab goes through
                # the page's key views and back to search then the section; Shift-Tab is the same loop
                # reversed. No other section is ever a stop.
                walks, bad = {}, []
                for section in SECTIONS:
                    app.call('settings-ui', action='open', section=section); time.sleep(.5)
                    app.call('settings-ui', action='focus-nav', section=section); time.sleep(.2)
                    label = who()[1]
                    fwd = []
                    for _ in range(10):
                        key('tab', window=window); time.sleep(.1); fwd.append(who())
                        if fwd[-1] == ('SettingsNavigationButton', label): break
                    app.call('settings-ui', action='focus-nav', section=section); time.sleep(.2)
                    back = []
                    for _ in range(10):
                        key('tab', ['shift'], window=window); time.sleep(.1); back.append(who())
                        if back[-1] == ('SettingsNavigationButton', label): break
                    page_fwd = fwd[:-2]; page_back = back[1:-1]
                    ok = (len(fwd) >= 2 and fwd[-1] == ('SettingsNavigationButton', label) and fwd[-2][0] == 'SettingsSearchField'
                          and back and back[0][0] == 'SettingsSearchField' and back[-1] == ('SettingsNavigationButton', label)
                          and page_back == list(reversed(page_fwd))
                          and not any(c == 'SettingsNavigationButton' for c, _ in fwd[:-1] + back[:-1]))
                    walks[section] = dict(forward=fwd, backward=back)
                    if not ok: bad.append(section)
                row('a11y_settings_tab_loop_every_pane', not bad, bad=bad, walks=walks)
            finally:
                key('w', ['cmd'], window=window); time.sleep(.3)
        attempt('a11y_settings_keyboard', settings)

        if 'a11y_no_leaked_decorative_images' not in results:   # keep an earlier error's evidence
            row('a11y_no_leaked_decorative_images', not leaked, leaked=leaked)
    finally:
        app.quit()

    # Review r1 #2: a Space with 300 tabs answers VoiceOver's row count, a first page of rows and an
    # index without building a row view for every tab.
    fixture = json.loads(open(os.path.join(h.ROOT, 'Packages/OpenKit/Fixtures/space-schema1/State/browser.json')).read())
    space = fixture['spaces'][0]; space['pinned'] = []
    now = time.time()
    space['today'] = [{'tab': {'_0': {'id': str(uuid.uuid4()).upper(), 'url': base + '/t%d' % i, 'title': 'Tab %d' % i,
                                      'createdAt': now, 'lastActiveAt': now, 'isMuted': False, 'isUnread': False}}} for i in range(300)]
    fixture['spaces'] = [space]
    window = fixture['windows'][0]; window.update(focusedSpaceID=space['id'], selectedNodeBySpace={}); fixture['windows'] = [window]
    path = os.path.join(tmp, 'a11y-300-tabs.json'); open(path, 'w').write(json.dumps(fixture))
    app = factory(urls=(), fresh=True, snapshot=path)
    try:
        state = app.call('window-state'); app.call('window-focus', id=state['id'], activate=True); time.sleep(.6)
        number = next(w['number'] for w in app.call('windows') if w.get('class', '').endswith('BrowserWindow'))
        outline = next((t for t in app.call('ax-debug', window=number, mode='count')['tables'] if t['class'] == 'SidebarOutlineView'), {})
        built = outline.get('rowViewsAfter', 0) - outline.get('rowViewsBefore', 0)
        row('a11y_sidebar_300_tabs_count_without_build', outline.get('countRows', 0) >= 300 and outline.get('countChildren') == outline.get('countRows')
            and outline.get('firstPage') == 5 and outline.get('indexOfFirst') == 0 and outline.get('countVisible', 0) < 40 and built <= 5,
            outline=outline, rowViewsBuilt=built)
    except Exception as error:
        row('a11y_sidebar_300_tabs_count_without_build', False, error=repr(error))
    finally:
        app.quit()
        server.shutdown(); server.server_close()
