"""S11 real App menu flows. Called by engine_e2e.py; no isolated or mocked tests."""
import http.server
import json
import os
import ssl
import subprocess
import threading
import time
import traceback
import urllib.parse


LINK_ITEMS = ['Open Link in Incognito Window', 'Open Link in New Tab', 'Open Link in Split View', 'Open Link in Peek',
              'Open Link in Little Open', 'Open Link in New Window']


def context_menu_checks(factory, results, tmp, h):
    folder = os.path.join(h.ROOT, 'tools', 'e2e', 'fixtures', 'context-menus')
    server, origin = h._static_server(folder)
    # Keep provider-shaped URLs local. The private App process resolves these names to
    # a loopback TLS server; no system DNS, trust store, credentials, or mail data change.
    cert, key = os.path.join(tmp, 'webmail-cert.pem'), os.path.join(tmp, 'webmail-key.pem')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=Open context menu fixture', '-keyout', key, '-out', cert],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    class MailHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            payload = b'<!doctype html><title>Local webmail fixture</title><p>Webmail fixture</p>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        def log_message(self, *args):
            pass
    mail_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), MailHandler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    mail_server.socket = tls.wrap_socket(mail_server.socket, server_side=True)
    threading.Thread(target=mail_server.serve_forever, daemon=True).start()
    def webmail(host, path='/'):
        return 'https://' + host + ':' + str(mail_server.server_port) + path
    mail_hosts = ['mail.google.com', 'outlook.live.com', 'outlook.office.com', 'outlook.office365.com',
                  'app.fastmail.com', 'mail.proton.me', 'mail.yahoo.com', 'www.icloud.com', 'app.hey.com']
    resolver = ', '.join('MAP ' + host + ' 127.0.0.1' for host in mail_hosts)
    app = factory(urls=(origin + '/index.html',), fresh=True,
                  extra_env={'OPEN_AUTOMATION_TRANSLATE_BACKEND': 'fixture'},
                  extra_args=['--host-resolver-rules=' + resolver, '--ignore-certificate-errors', '--no-proxy-server', '--load-extension=' + os.path.join(h.ROOT, 'tools/e2e/fixtures/context-menu-probe'),
                              '--disable-features=DisableLoadExtensionCommandLineSwitch'])
    saved = {}
    only_case = os.environ.get('OPEN_CONTEXT_MENU_CASE')
    ran_cases = set()
    tab = app.call('tabs')[0]['id']
    home = app.call('window-state')['id']
    space = next(x['id'] for x in app.call('spaces') if x['focused'])
    wait = h.wait_until

    def run(name, fn):
        if only_case and name != only_case:
            return
        ran_cases.add(name)
        try:
            value = fn()
            results[name] = value
        except h.FocusInterruption:
            raise
        except Exception as error:
            results[name] = {'ok': False, 'error': str(error), 'trace': traceback.format_exc()[-900:]}

    def focus():
        app.call('window-focus', id=home, activate=True)
        app.call('peek-close')
        app.call('space', space=space)
        visible = [t for t in app.call('tabs') if t['visible']]
        if len(visible) > 1 and any(t['id'] == tab for t in visible):
            # Pane tabs have no sidebar row. Focus through the real split-pane shortcut.
            app.call('focus')
            app.call('key', key='1', modifiers=['control', 'shift'], route='app')
        else:
            app.call('select', tab=tab)
        app.call('wait', tab=tab)
        app.call('focus', tab=tab)

    def point(selector, target=tab):
        return app.eval(target, '''(() => { const e=document.querySelector(%s); e.scrollIntoView({block:'center'});
          const r=e.getBoundingClientRect(); return [r.left + Math.min(r.width/2, 25), r.top+r.height/2] })()''' % json.dumps(selector))

    def select(selector, text=None):
        app.eval(tab, '''(() => { const e=document.querySelector(%s); %s
          const r=document.createRange(); r.selectNodeContents(e); const s=getSelection();s.removeAllRanges();s.addRange(r) })()'''
                 % (json.dumps(selector), ('e.textContent=' + json.dumps(text) + ';') if text is not None else ''))

    def menu(selector='#page', policy='record', target=tab, clear=True):
        if clear:
            app.eval(target, 'getSelection().removeAllRanges(); document.activeElement?.blur()')
        app.call('policy', contextMenu=policy)
        app.call('events')
        x, y = point(selector, target)
        app.call('rightclick', tab=target, x=x, y=y)
        collected = []

        def received():
            collected.extend(app.call('events'))
            return next((e for e in collected if e['type'] == 'contextMenu'), None)
        event = wait(received, timeout=8, step=.05)
        # Drain the queued action/decision after the engine callback returns.
        collected.extend(app.call('events'))
        return event or {}, collected

    def selected():
        return next((t for t in app.call('tabs') if t['selected']), {})

    def opener_of(identifier):
        with open(app.call('save')) as stream:
            snapshot = json.load(stream)
        def find(value):
            if isinstance(value, dict):
                if value.get('id') == identifier:
                    return value.get('openerID')
                for child in value.values():
                    result = find(child)
                    if result:
                        return result
            if isinstance(value, list):
                for child in value:
                    result = find(child)
                    if result:
                        return result
        return find(snapshot)

    def row_enabled(identifier):
        return next(r['enabled'] for r in app.call('menu-state') if r['id'] == identifier)

    def new_background(selector, title, url):
        focus()
        before = {x['id'] for x in app.call('tabs')}
        if title == 'Open Image in New Tab':
            recorded, _ = menu(selector)
            command = next(c for c in recorded['commands'] if c['title'] == title)
            policy = 'run:' + str(command['id'])
        else:
            policy = 'run-open:' + title
        event, decisions = menu(selector, policy)
        new = wait(lambda: [x for x in app.call('tabs') if x['id'] not in before], timeout=5)
        result = {'ok': len(new) == 1 and new[0]['url'] == url and not new[0]['selected']
                  and selected()['id'] == tab and new[0]['section'] == 'today'
                  and opener_of(new[0]['id']) == tab,
                  'new': new, 'shown': event.get('shown'), 'decisions': decisions}
        for item in new:
            app.call('close', tab=item['id'])
        return result

    try:
        for key in ('open.translate.neverTranslateHosts', 'open.translate.enabled', 'open.previews.pinned',
                    'open.links.littleOpenHotkeyEnabled', 'open.profiles.confirmInterProfileMove'):
            saved[key] = app.call('defaults', key=key)
            app.call('defaults', key=key, value=None)
        app.call('defaults', key='open.profiles.confirmInterProfileMove', value=True)
        app.call('window-frame', frame=[80, 60, 1360, 1000])
        focus()
        app.call('settings-custom-engine', template=origin + '/target.html?q=%s')
        wait(lambda: app.call('translate', action='state').get('state') == 'offered', timeout=10)

        def order(name, selector, selection=False):
            focus()
            if selection:
                select(selector)
            event, events = menu(selector, clear=not selection)
            shown = event.get('shown', [])
            raw = event.get('items', [])
            selection_text = app.eval(tab, 'getSelection().toString()').strip()
            # macOS can supply the clicked link's text as the engine selection.
            if event.get('selectionBytes', 0) and name in ('link', 'mailto'):
                selection_text = {'link': 'Fixture link', 'mailto': 'Fixture email'}[name]
            ok = bool(shown) and shown[0] != '-' and shown[-1] != '-' and not any(a == b == '-' for a, b in zip(shown, shown[1:]))
            if name in ('link', 'mailto', 'linked_image'):
                ok = ok and all(shown.count(t) == 1 for t in LINK_ITEMS)
                anchor = shown.index(LINK_ITEMS[0]) if LINK_ITEMS[0] in shown else -1
                ok = ok and shown[anchor:anchor + len(LINK_ITEMS) + 1] == LINK_ITEMS + ['-']
                ok = ok and next((r['enabled'] for r in event.get('rows', []) if r['key'] == 'link-little-open'), None) is True
                if name == 'mailto':
                    ok = ok and any('Copy Email Address' in t or 'Copy Link' in t for t in shown)
            else:
                ok = ok and not any(t in shown for t in LINK_ITEMS)
            if name == 'page':
                expected = ['Back', 'Forward', 'Reload']
                ok = ok and all(x in shown for x in expected) and 'Capture' in shown and 'Capture Full Page' in shown
                if 'Translate to English' in shown:
                    ok = ok and shown.index('Translate to English') < shown.index('Capture')
                for title in ('View Page Source', 'Inspect'):
                    if title in shown:
                        ok = ok and shown.index('Capture Full Page') < shown.index(title)
                ok = ok and shown.index('Capture') + 1 == shown.index('Capture Full Page')
            if name in ('image', 'linked_image'):
                ok = ok and all(any(x.startswith(t) for x in shown) for t in ('Open Image in New Tab', 'Save Image As', 'Copy Image', 'Copy Image Address'))
            if name == 'selection':
                title = 'Search Local Search for “bonjour menu contextuel”'
                ok = ok and title in shown and shown.index(title) == shown.index('Copy') + 1
            if name == 'url':
                title = 'Go to https://example.invalid/context-target'
                ok = ok and shown.count(title) == 1 and shown.index(title) == shown.index('Copy') + 1
            if name == 'editable':
                ok = ok and shown == [t or '-' for t in raw] and not any(t.startswith('Search ') for t in shown)
                source = [{key: c[key] for key in ('title', 'enabled', 'checked', 'submenu')} for c in event.get('commands', [])]
                native = [{key: r[key] for key in ('title', 'enabled', 'checked', 'submenu')} for r in event.get('rows', [])]
                ok = ok and source == native
            # Compare the complete native order with Chromium's delivered base plus the
            # lead's fixed insertions. These are real engine/native menu rows, not mocks.
            expected = [title or '-' for title in raw]
            link_open = {'Open Link in New Tab', 'Open Link in New Window', 'Open Link in Incognito Window',
                         'Open Link in Split View', 'Open Link in Left View', 'Open Link in Right View',
                         'Open Link in Top View', 'Open Link in Bottom View', 'Open Link With…', 'Open Link With'}
            if name in ('link', 'mailto', 'linked_image'):
                anchor = next((i for i, title in enumerate(expected) if title in link_open), 0)
                expected = [title for title in expected if title not in link_open]
                expected[anchor:anchor] = LINK_ITEMS + ['-']
            if name in ('link', 'mailto', 'linked_image') and selection_text and 'Copy' in expected:
                display = selection_text[:32] + ('…' if len(selection_text) > 32 else '')
                expected.insert(expected.index('Copy') + 1, 'Search Local Search for “' + display + '”')
            if name in ('selection', 'url'):
                expected = [title for title in expected if not title.startswith('Go to ')]
                addition = ('Search Local Search for “bonjour menu contextuel”' if name == 'selection'
                            else 'Go to https://example.invalid/context-target')
                anchor = expected.index('Copy') + 1
                expected.insert(anchor, addition)
            if name == 'page':
                anchor = next((i for i, title in enumerate(expected) if title.startswith(('View Page Source', 'Inspect'))), len(expected))
                addition = ['Translate to English', 'Capture', 'Capture Full Page']
                if anchor > 0 and expected[anchor - 1] != '-':
                    addition.insert(0, '-')
                if anchor < len(expected) and expected[anchor] != '-':
                    addition.append('-')
                expected[anchor:anchor] = addition
            if name != 'editable':
                anchor = next((i for i, title in enumerate(expected) if title.startswith('Inspect')), len(expected))
                if anchor > 0 and expected[anchor - 1] == '-': anchor -= 1
                addition = ['Manage Extensions']
                if anchor > 0 and expected[anchor - 1] != '-': addition.insert(0, '-')
                if anchor < len(expected) and expected[anchor] != '-': addition.append('-')
                expected[anchor:anchor] = addition
            trimmed = []
            for title in expected:
                if title != '-' or (trimmed and trimmed[-1] != '-'):
                    trimmed.append(title)
            if trimmed and trimmed[-1] == '-':
                trimmed.pop()
            ok = ok and shown == trimmed
            return {'ok': bool(ok), 'shown': shown, 'expected': trimmed, 'selection': selection_text, 'engine': raw, 'rows': event.get('rows'),
                    'decisions': [e for e in events if e['type'] == 'contextMenuDecision']}

        for name, selector, selection in [('page', '#page', False), ('link', '#link', False), ('mailto', '#mailto', False),
                                         ('image', '#image', False), ('linked_image', '#linked-image', False),
                                         ('selection', '#selection', True), ('url', '#url', True), ('editable', '#editable', False)]:
            run('cm_order_' + name, lambda n=name, s=selector, v=selection: order(n, s, v))
        def manage_extensions():
            focus()
            extension = wait(lambda: next((e for e in app.call('extensions')['installed']
                if e['name'] == 'Open context menu limits probe'), None), timeout=15)
            assert extension, 'real extension fixture missing'
            probe = h.new_tab(app, 'chrome-extension://' + extension['id'] + '/probe.html')
            cases = []
            try:
                for contributed in [False, True]:
                    configured = app.eval(probe, 'chrome.runtime.sendMessage(' + json.dumps(
                        dict(op='configure', count=1 if contributed else 0, title='Manage placement probe')) + ')')
                    assert configured.get('ok'), configured
                    for target, selector in [('page', '#page'), ('link', '#link'), ('image', '#image'),
                                              ('selection', '#selection'), ('editable', '#editable')]:
                        focus()
                        if target == 'selection': select(selector, 'bonjour menu contextuel')
                        event, _ = menu(selector, clear=target != 'selection')
                        shown = event.get('shown', [])
                        if target == 'editable':
                            ok = 'Manage Extensions' not in shown and bool(shown)
                        else:
                            index = shown.index('Manage Extensions') if 'Manage Extensions' in shown else -1
                            inspect = next((i for i, title in enumerate(shown) if title.startswith('Inspect')), len(shown))
                            if contributed:
                                # One contribution is top-level; preserve its group and Inspect separator.
                                ok = index > 0 and shown[index - 1] == 'Manage placement probe' and shown[index + 1] == '-'
                            else:
                                ok = index > 0 and shown[index - 1] == '-' and shown[index + 1:inspect] == ['-']
                            ok = ok and shown.count('Manage Extensions') == 1
                        cases.append(dict(target=target, extension=contributed, ok=ok, shown=shown))
                focus()
                before = {t['id'] for t in app.call('tabs')}
                event, decisions = menu('#page', 'run-open:Manage Extensions')
                opened = wait(lambda: next((t for t in app.call('tabs') if t['id'] not in before
                    and t['url'].rstrip('/') == 'chrome://extensions' and t['selected']), None), timeout=5)
                action = bool(opened) and opened.get('section') == 'today'
                if opened: app.call('close', tab=opened['id'])
                return dict(ok=all(c['ok'] for c in cases) and action, cases=cases, action=action,
                            opened=opened, decisions=[e for e in decisions if e['type'] == 'contextMenuDecision'])
            finally:
                app.eval(probe, 'chrome.runtime.sendMessage({op:"configure",count:0})')
                app.call('close', tab=probe)
        run('cm_manage_extensions', manage_extensions)

        run('cm_link_background', lambda: new_background('#link', 'Open Link in New Tab', origin + '/target.html'))
        run('cm_image_background', lambda: new_background('#image', 'Open Image in New Tab', origin + '/image.svg'))

        def split():
            focus()
            event, _ = menu('#link', 'run-open:Open Link in Split View')
            panes = wait(lambda: [t for t in app.call('tabs') if t['visible']], timeout=5)
            # Wait for both panes rather than accepting the source's pre-action single pane.
            panes = wait(lambda: (lambda p: p if len(p) == 2 else None)([t for t in app.call('tabs') if t['visible']]), timeout=5) or panes
            with open(app.call('save')) as stream:
                snap = json.load(stream)
            def find_split(value):
                if isinstance(value, dict):
                    if 'panes' in value and any(t['id'] == tab for t in value['panes']):
                        return value
                    for child in value.values():
                        found = find_split(child)
                        if found:
                            return found
                if isinstance(value, list):
                    for child in value:
                        found = find_split(child)
                        if found:
                            return found
            made = find_split(snap) or {}
            ids = [p['id'] for p in made.get('panes', [])]
            target = next((p for p in panes if p['id'] != tab), {})
            ok = len(panes) == 2 and target.get('url') == origin + '/target.html' and ids == [tab, target.get('id')]
            stages = {'initial': made}
            if made:
                app.call('sidebar-menu', node=made['id'], item='Convert to Vertical Split View')
                with open(app.call('save')) as stream:
                    stages['vertical'] = find_split(json.load(stream)) or {}
                focus()
                menu('#link', 'run-open:Open Link in Split View')
                wait(lambda: len([t for t in app.call('tabs') if t['visible']]) == 3, timeout=5)
                with open(app.call('save')) as stream:
                    stages['third'] = find_split(json.load(stream)) or {}
                third = stages['third']
                third_ids = [p['id'] for p in third.get('panes', [])]
                ok = ok and stages['vertical'].get('orientation') == 'vertical' and len(third_ids) == 3 \
                    and third.get('orientation') == 'horizontal' and third_ids[0] == tab and third_ids[2] == target.get('id')
                focus()
                menu('#link', 'run-open:Open Link in Split View')
                wait(lambda: len([t for t in app.call('tabs') if t['visible']]) == 4, timeout=5)
                before = {t['id'] for t in app.call('tabs')}
                focus()
                full, _ = menu('#link', 'run-open:Open Link in Split View')
                capacity = next((r['enabled'] is False for r in full.get('rows', []) if r['key'] == 'link-split'), False)
                ok = ok and capacity and len([t for t in app.call('tabs') if t['visible']]) == 4 and {t['id'] for t in app.call('tabs')} == before
                stages['fullCapacityDisabled'] = capacity
                with open(app.call('save')) as stream:
                    current_split = find_split(json.load(stream)) or {}
                extra = [p['id'] for p in current_split.get('panes', []) if p['id'] != tab]
                app.call('sidebar-menu', node=made['id'], item='Separate All Tabs')
                for identifier in extra:
                    app.call('close', tab=identifier)
            return {'ok': bool(ok), 'panes': panes, 'split': made, 'stages': stages, 'shown': event.get('shown')}
        run('cm_split', split)

        def new_window():
            focus()
            before = app.call('shell-windows')
            event, _ = menu('#link', 'run-open:Open Link in New Window')
            windows = wait(lambda: (lambda w: w if len(w) == len(before) + 1 else None)(app.call('shell-windows')), timeout=5) or []
            new = next((w for w in windows if w['id'] not in {b['id'] for b in before}), None)
            target = selected() if new else {}
            ok = new is not None and target.get('url') == origin + '/target.html' and target.get('section') == 'today'
            if new:
                app.call('window-focus', id=new['id'], activate=True)
                app.call('window-close')
            focus()
            return {'ok': ok, 'new': new, 'tab': target, 'shown': event.get('shown')}
        run('cm_new_window', new_window)

        def peek():
            focus()
            event, _ = menu('#link', 'run-open:Open Link in Peek')
            state = wait(lambda: (lambda s: s if s['shown'] else None)(app.call('peek-state')), timeout=5) or {}
            stack = state.get('stack', [])
            if stack:
                app.call('wait', tab=stack[-1]['content'])
            url = app.eval(stack[-1]['content'], 'location.href') if stack else ''
            # Right-click inside Peek uses its real host, and Split stays disabled.
            if stack:
                nested, _ = menu('p', target=stack[-1]['content'])
                # The target has no link; add a real link only to this fixture document.
                app.eval(stack[-1]['content'], 'document.body.innerHTML += \'<a id="nested" href="/target.html">Nested link</a>\'')
                nested, _ = menu('#nested', target=stack[-1]['content'])
            else:
                nested = {}
            disabled = next((r['enabled'] is False for r in nested.get('rows', []) if r['key'] == 'link-split'), False)
            app.call('peek-close')
            return {'ok': bool(stack) and url == origin + '/target.html' and disabled, 'state': state, 'url': url, 'nested': nested.get('shown')}
        run('cm_peek_and_split_disabled', peek)

        def peek_extension_items():
            # A12: Peek pages are Alloy style. The engine adds the extension's
            # chrome.contextMenus items to CEF's Alloy model (CEF patch 0306), with
            # Chrome's grouping, and a click reaches contextMenus.onClicked.
            focus()
            name = 'Open context menu limits probe'
            extension = wait(lambda: next((e for e in app.call('extensions')['installed'] if e['name'] == name), None), timeout=15)
            assert extension, 'real extension fixture missing'
            probe = h.new_tab(app, 'chrome-extension://' + extension['id'] + '/probe.html')
            def send(**message):
                return app.eval(probe, 'chrome.runtime.sendMessage(' + json.dumps(message) + ')')
            state = {}
            try:
                assert send(op='configure', count=2).get('ok')
                send(op='clicks')
                app.call('select', tab=tab); focus()
                menu('#link', 'run-open:Open Link in Peek')
                state = wait(lambda: (lambda s: s if s['shown'] else None)(app.call('peek-state')), timeout=5) or {}
                page = state['stack'][-1]['content']
                app.call('wait', tab=page)
                app.eval(page, 'document.body.innerHTML += \'<a id="nested" href="/target.html?x=1">Nested link</a>\'')
                shown, _ = menu('p', target=page)
                leaves = [c for c in shown.get('commands', []) if c['submenu'] == name]
                ran, _ = menu('p', 'run:%d' % leaves[0]['id'], target=page) if leaves else ({}, [])
                page_click = wait(lambda: send(op='clicks').get('clicks') or None, timeout=5) or []
                link_shown, _ = menu('#nested', target=page)
                link_leaves = [c for c in link_shown.get('commands', []) if c['submenu'] == name]
                if len(link_leaves) > 1:
                    menu('#nested', 'run:%d' % link_leaves[1]['id'], target=page)
                link_click = wait(lambda: send(op='clicks').get('clicks') or None, timeout=5) or []
                assert send(op='configure', count=0).get('ok')
                none, _ = menu('p', target=page)
            finally:
                h._try(lambda: send(op='configure', count=0))
                h._try(lambda: app.call('peek-close'))
                h._try(lambda: app.call('close', tab=probe))
                h._try(lambda: app.call('select', tab=tab))
            target_url = origin + '/target.html'
            return {'ok': [c['title'] for c in leaves] == ['Probe leaf 0', 'Probe leaf 1'] and all(c['enabled'] for c in leaves)
                          and page_click == [dict(menuItemId='leaf-0', pageUrl=target_url, linkUrl=None, frameId=0, hasTab=False)]
                          and len(link_click) == 1 and link_click[0]['menuItemId'] == 'leaf-1'
                          and link_click[0]['linkUrl'] == target_url + '?x=1' and link_click[0]['pageUrl'] == target_url
                          and not [c for c in none.get('commands', []) if c['submenu'] == name],
                    'peek': state, 'leaves': leaves, 'pageClick': page_click, 'linkLeaves': link_leaves,
                    'linkClick': link_click, 'afterRemoval': none.get('shown')}
        run('cm_peek_extension_items', peek_extension_items)

        def search(selector, text, title, expected):
            focus()
            select(selector, text)
            before = {t['id'] for t in app.call('tabs')}
            event, _ = menu(selector, 'run-open:' + title, clear=False)
            opened = wait(lambda: next((t for t in app.call('tabs') if t['id'] not in before and t['selected']), None), timeout=5) or {}
            ok = opened.get('url') == expected and opened.get('section') == 'today'
            if opened:
                app.call('close', tab=opened['id'])
            return {'ok': ok, 'opened': opened, 'shown': event.get('shown')}
        run('cm_search', lambda: search('#selection', 'bonjour menu contextuel', 'Search Local Search for “bonjour menu contextuel”',
                                       origin + '/target.html?q=bonjour%20menu%20contextuel'))
        run('cm_go_url', lambda: search('#url', origin + '/target.html', 'Go to ' + origin + '/target.html', origin + '/target.html'))
        long_text = 'x' * 40
        run('cm_search_truncation', lambda: search('#selection', long_text, 'Search Local Search for “' + 'x' * 32 + '…”', origin + '/target.html?q=' + long_text))

        def cancellation():
            focus()
            event, events = menu()
            # Repeat after the first cancel to prove a fresh engine request still works.
            again, next_events = menu()
            decisions = [e for e in events + next_events if e['type'] == 'contextMenuDecision']
            return {'ok': bool(event) and bool(again) and len(decisions) == 2 and all(e['key'] == 'cancel' for e in decisions), 'decisions': decisions}
        run('cm_cancel_once', cancellation)

        def little_entry():
            focus()
            windows = app.call('shell-windows')
            profile = app.call('tab-state', tab=tab)['profile']
            event, events = menu('#link', 'run-open:Open Link in Little Open')
            request = wait(lambda: app.call('routing-log').get('lastLittleOpenRequest'), timeout=5) or {}
            number = app.call('native-focus-state')['keyWindow']
            shown = number != 0 and number not in {w['number'] for w in windows}
            if shown:
                # Native Close Window on Little Open itself, never the source page/tab.
                app.call('key', key='w', modifiers=['command', 'shift'], route='app', window=number)
            focus()
            return {'ok': shown and request.get('url') == origin + '/target.html' and request.get('profileHint') == profile
                    and any(r['key'] == 'link-little-open' and r['enabled'] for r in event.get('rows', [])),
                    'request': request, 'stubWindow': number if shown else None, 'shown': event.get('shown')}
        run('cm_little_open_entry', little_entry)

        def translate():
            focus()
            # Reload restores the real French fixture and triggers language detection again.
            app.call('navigate', tab=tab, url=origin + '/index.html'); app.call('wait', tab=tab)
            offered = wait(lambda: app.call('translate', action='state')['state'] == 'offered', timeout=10)
            event, _ = menu('#page', 'run-open:Translate to English')
            translated = wait(lambda: (lambda s: s if s['state'] == 'translated' else None)(app.call('translate', action='state')), timeout=10)
            return {'ok': bool(offered) and bool(translated), 'state': translated, 'shown': event.get('shown')}
        run('cm_translate', translate)

        def capture(title, full):
            focus()
            event, _ = menu('#page', 'run-open:' + title)
            if full:
                captured = wait(lambda: (lambda s: s if s.get('result') else None)(app.call('capture-state')), timeout=30) or {}
                ok = captured.get('result', {}).get('saved') is not None
                if captured.get('card'):
                    app.call('capture-action', action='delete')
            else:
                captured = wait(lambda: (lambda s: s if s['overlayActive'] else None)(app.call('capture-state')), timeout=5) or {}
                ok = captured.get('overlayActive') is True
                app.call('key', key='escape', route='app')
            return {'ok': ok, 'state': captured, 'shown': event.get('shown')}
        run('cm_capture', lambda: capture('Capture', False))
        run('cm_capture_full', lambda: capture('Capture Full Page', True))

        def selection_limit():
            focus()
            values = []
            for size in (16384, 16385):
                select('#long', 'x' * size)
                app.call('policy', contextMenu='record'); app.call('events')
                x, y = point('#long')
                app.call('rightclick', tab=tab, x=x, y=y)
                events = []
                def received():
                    events.extend(app.call('events'))
                    return next((e for e in events if e['type'] in ('contextMenu', 'contextMenuRefused')), None)
                event = wait(received, timeout=5) or {}
                values.append(event)
            app.eval(tab, "document.querySelector('#long').textContent=''")
            return {'ok': values[0].get('selectionBytes') == 16384 and values[1].get('type') == 'contextMenuRefused', 'events': values}
        run('cm_selection_limit', selection_limit)

        def url_limit():
            focus()
            events = []
            prefix = origin + '/target.html?'
            for size in (65536, 65537):
                app.eval(tab, "document.querySelector('#link').href=" + json.dumps(prefix + 'x' * (size - len(prefix))))
                app.call('policy', contextMenu='record'); app.call('events')
                x, y = point('#link'); app.call('rightclick', tab=tab, x=x, y=y)
                seen = []
                def received():
                    seen.extend(app.call('events'))
                    return next((e for e in seen if e['type'] in ('contextMenu', 'contextMenuRefused')), None)
                event = wait(received, timeout=5) or {}
                events.append({'type': event.get('type'), 'reason': event.get('reason'), 'linkBytes': len(event.get('link', '').encode())})
            app.eval(tab, "document.querySelector('#link').href='target.html'")
            return {'ok': events[0]['linkBytes'] == 65536 and events[1]['type'] == 'contextMenuRefused', 'events': events}
        run('cm_url_limit', url_limit)

        def extension_limits():
            focus()
            extension = wait(lambda: next((e for e in app.call('extensions')['installed'] if e['name'] == 'Open context menu limits probe'), None), timeout=15)
            if not extension:
                raise RuntimeError('real extension probe was not loaded')
            probe = h.new_tab(app, 'chrome-extension://' + extension['id'] + '/probe.html')
            def configure(**options):
                result = app.eval(probe, 'chrome.runtime.sendMessage(' + json.dumps(dict(op='configure', **options)) + ')')
                if not result.get('ok'):
                    raise RuntimeError(str(result))
                focus()
            def observed(selector='#page'):
                app.call('policy', contextMenu='record'); app.call('events')
                x, y = point(selector); app.call('rightclick', tab=tab, x=x, y=y)
                seen = []
                def received():
                    seen.extend(app.call('events'))
                    return next((e for e in seen if e['type'] in ('contextMenu', 'contextMenuRefused')), None)
                return wait(received, timeout=5) or {}
            checks = {}
            try:
                configure(count=1, title='x' * 1024)
                accepted = observed()
                configure(count=1, title='x' * 1025)
                refused = observed()
                titles = [c['title'] for e in (accepted, refused) for c in e.get('commands', []) if c['id'] >= 49000 and c['title'].startswith('x')]
                if len(titles) == 2 and all(len(t.encode()) < 1024 for t in titles):
                    # These labels are bounded upstream; exercise the App's own title limit
                    # below through a real selection whose combining marks stay in 32 characters.
                    checks['title'] = {'upstreamElision': True, 'deliveredBytes': [len(t.encode()) for t in titles]}
                else:
                    checks['title'] = {'ok': accepted.get('type') == 'contextMenu' and refused.get('type') == 'contextMenuRefused',
                                       'acceptedNodes': accepted.get('incomingNodes'), 'refused': refused}
                configure(count=2)
                base = observed().get('incomingNodes', 0) - 3  # extension wrapper + two leaves
                count = 128 - base - 1
                configure(count=count)
                accepted = observed()
                configure(count=count + 1)
                refused = observed()
                checks['nodes'] = {'ok': accepted.get('incomingNodes') == 128 and refused.get('type') == 'contextMenuRefused',
                                   'acceptedNodes': accepted.get('incomingNodes'), 'refused': refused}
                configure(count=1, depth=7)
                accepted = observed()
                configure(count=1, depth=8)
                refused = observed()
                checks['depth'] = {'ok': accepted.get('type') == 'contextMenu' and refused.get('type') == 'contextMenuRefused',
                                   'acceptedNodes': accepted.get('incomingNodes'), 'refused': refused}
                configure(count=0)
                title_events = []
                overhead = len('Search Local Search for “”'.encode())
                for size in (1024, 1025):
                    payload = size - overhead
                    base = 31 if payload % 2 else 32
                    text = 'x' * base + '\u035c' * ((payload - base) // 2)
                    assert len(text.encode()) + overhead == size
                    select('#selection', text)
                    event = observed('#selection')
                    own = next((r for r in event.get('rows', []) if r['key'] == 'selection-search'), None)
                    title_events.append({'type': event.get('type'), 'reason': event.get('reason'),
                                         'requestedBytes': size, 'shownBytes': len(own['title'].encode()) if own else None})
                results['cm_title_boundary'] = {'ok': title_events[0]['type'] == 'contextMenu'
                    and title_events[0]['shownBytes'] == 1024 and title_events[1]['type'] == 'contextMenuRefused',
                    'events': title_events, 'engineExtensionTitleBytes': [len(t.encode()) for t in titles]}
                configure(count=1, title='Go to fixture')
                select('#selection', 'Extension collision selection')
                go = observed('#selection')
                custom_go = next((c for c in go.get('commands', []) if c['title'] == 'Go to fixture'), None)
                go_kept = custom_go is not None and any(r['key'] == 'engine:' + str(custom_go['id']) for r in go.get('rows', []))
                configure(count=1, title='Open Link in New Tab')
                link = observed('#link')
                native = h._command_id('IDC_CONTENT_CONTEXT_OPENLINKNEWTAB')
                custom_link = next((c for c in link.get('commands', []) if c['title'] == 'Open Link in New Tab' and c['id'] != native), None)
                link_kept = custom_link is not None and any(r['key'] == 'engine:' + str(custom_link['id']) for r in link.get('rows', []))
                checks['extension_title_collisions'] = {'ok': go_kept and link_kept,
                                                        'goKept': go_kept, 'linkKept': link_kept,
                                                        'goShown': go.get('shown'), 'linkShown': link.get('shown')}
                return {'ok': all(c.get('ok', c.get('upstreamElision', False)) for c in checks.values()), 'limits': checks}
            finally:
                configure(count=0)
                app.call('close', tab=probe)
        run('cm_extension_limits', extension_limits)

        def email():
            focus()
            empty = not row_enabled('peek-email')
            today = app.call('open', url=webmail('mail.google.com', '/mail/u/0/'), background=True)['id']
            ignored_today = not row_enabled('peek-email')
            app.call('pin', tab=today)
            enabled = row_enabled('peek-email')
            # The real menu key route, not a direct call to the handler.
            app.call('key', key='e', modifiers=['command', 'shift'], route='app')
            state = wait(lambda: (lambda s: s if s['shown'] else None)(app.call('peek-state')), timeout=5) or {}
            content = state.get('stack', [{}])[-1].get('content')
            urls = wait(lambda: [p['url'] for p in app.call('pages') if p['identifier'] == content and p['url'].startswith('https://')], timeout=5) or []
            app.call('peek-close')
            app.call('pin', tab=today); app.call('close', tab=today)
            disabled = not row_enabled('peek-email')
            return {'ok': empty and ignored_today and enabled and disabled and urls == [webmail('mail.google.com', '/mail/u/0/')],
                    'empty': empty, 'ignoredToday': ignored_today, 'enabled': enabled, 'disabledAgain': disabled, 'peek': state, 'urls': urls}
        run('cm_peek_email', email)

        def email_scope():
            focus()
            second = app.call('space-create', title='Other mail Space', profile='Default')
            app.call('space', space=second)
            other = app.call('open', url=webmail('app.fastmail.com', '/mail/'), background=True)['id']
            app.call('pin', tab=other)
            app.call('space', space=space); app.call('select', tab=tab)
            from_other = row_enabled('peek-email')
            near = app.call('open', url=webmail('mail.proton.me', '/u/0/inbox'), background=True)['id']
            app.call('pin', tab=near)
            app.call('key', key='e', modifiers=['command', 'shift'], route='app')
            state = wait(lambda: (lambda s: s if s['shown'] else None)(app.call('peek-state')), timeout=5) or {}
            content = state.get('stack', [{}])[-1].get('content')
            urls = wait(lambda: [p['url'] for p in app.call('pages') if p['identifier'] == content and p['url'].startswith('https://')], timeout=5) or []
            app.call('peek-close')
            app.call('space-profile', space=second, profile='Unrelated')
            app.call('alert', button='Change Profile')
            app.call('pin', tab=near); app.call('close', tab=near)
            unrelated = not row_enabled('peek-email')
            return {'ok': from_other and urls == [webmail('mail.proton.me', '/u/0/inbox')] and unrelated,
                    'otherSpaceEnabled': from_other, 'focusedSpaceURL': urls, 'otherProfileIgnored': unrelated}
        run('cm_peek_email_scope', email_scope)

        def email_split():
            focus()
            mail_space = app.call('space-create', title='Pinned split mail', profile='Default')
            companion = app.call('open', url=origin + '/target.html', background=False)['id']
            mail_url = webmail('mail.google.com', '/mail/u/0/')
            mail = app.call('open', url=mail_url, background=True)['id']
            split_id = None
            try:
                app.call('select', tab=companion)
                app.call('sidebar-menu', node=mail, item='Open in Split View')
                split_id = next(n['id'] for n in app.call('sidebar-tree')['today'] if n['kind'] == 'split')
                app.call('sidebar-drop', nodes=[split_id], parent=dict(kind='pinned', id=mail_space), index=0)
                empty_space = app.call('space-create', title='Empty mail source', profile='Default')
                before = app.call('tabs')
                enabled = row_enabled('peek-email')
                app.call('key', key='e', modifiers=['command', 'shift'], route='app')
                state = wait(lambda: (lambda s: s if s['shown'] else None)(app.call('peek-state')), timeout=5) or {}
                content = state.get('stack', [{}])[-1].get('content')
                urls = (wait(lambda: [p['url'] for p in app.call('pages') if p['identifier'] == content and p['url'] == mail_url], timeout=5) or []) if content is not None else []
                after = app.call('tabs')
                focused = next(s['id'] for s in app.call('spaces') if s['focused'])
                return {'ok': enabled and not any(t['selected'] for t in before) and focused == mail_space
                        and any(t['id'] == mail and t['selected'] for t in after) and urls == [mail_url]
                        and app.call('peek-state')['shown'],
                        'emptySpace': empty_space, 'enabled': enabled, 'before': before,
                        'mailSpace': mail_space, 'split': split_id, 'after': after, 'peek': state, 'urls': urls}
            finally:
                h._try(lambda: app.call('peek-close'))
                h._try(lambda: app.call('space', space=mail_space))
                if split_id:
                    h._try(lambda: app.call('sidebar-menu', node=split_id, item='Separate All Tabs'))
                for identifier in (mail, companion):
                    h._try(lambda i=identifier: app.call('pin', tab=i) if app.call('tab-state', tab=i)['section'] == 'pinned' else None)
                    h._try(lambda i=identifier: app.call('close', tab=i))
                focus()
        run('cm_peek_email_split', email_split)

        def email_hosts():
            focus()
            accepted = ['mail.google.com', 'outlook.live.com', 'outlook.office.com', 'outlook.office365.com',
                        'app.fastmail.com', 'mail.proton.me', 'mail.yahoo.com', 'www.icloud.com/mail', 'app.hey.com']
            rejected = ['www.icloud.com', 'www.icloud.com/mailish', 'evil.mail.google.com', 'mail.google.com.evil.invalid']
            actual = {}
            for value in accepted + rejected:
                host, slash, path = value.partition('/')
                candidate = app.call('open', url=webmail(host, '/' + path if slash else '/'), background=True)['id']
                app.call('pin', tab=candidate)
                actual[value] = row_enabled('peek-email')
                app.call('pin', tab=candidate); app.call('close', tab=candidate)
            # A Favorite is eligible without a pinned row.
            candidate = app.call('open', url=webmail('app.hey.com'), background=False)['id']
            app.call('favorite', tab=candidate)
            favorite = row_enabled('peek-email')
            favorite_url = app.call('tab-state', tab=candidate)['url']
            app.call('key', key='e', modifiers=['command', 'shift'], route='app')
            state = wait(lambda: (lambda s: s if s['shown'] else None)(app.call('peek-state')), timeout=5) or {}
            content = state.get('stack', [{}])[-1].get('content')
            favorite_urls = wait(lambda: [p['url'] for p in app.call('pages') if p['identifier'] == content and p['url'].startswith('https://')], timeout=5) or []
            app.call('peek-close')
            favorite = favorite and favorite_urls == [favorite_url]
            return {'ok': all(actual[h] for h in accepted) and not any(actual[h] for h in rejected) and favorite,
                    'hosts': actual, 'favorite': favorite}
        run('cm_peek_email_hosts', email_hosts)

        def help_item(identifier, url):
            focus()
            before = {t['id'] for t in app.call('tabs')}
            app.call('menu-perform', id=identifier)
            opened = wait(lambda: next((t for t in app.call('tabs') if t['id'] not in before and t['selected']), None), timeout=5) or {}
            ok = opened.get('url') == url and opened.get('section') == 'today'
            if opened:
                app.call('close', tab=opened['id'])
            return {'ok': ok, 'opened': opened}
        for identifier, path in [('help-center', '/blob/main/docs/commands.md'), ('getting-started', '#readme'),
                                 ('release-notes', '/releases'), ('contact-team', '/issues/new')]:
            run('cm_help_' + identifier, lambda i=identifier, p=path: help_item(i, 'https://github.com/SergeSerb2/open' + p))
        run('cm_join_meeting_disabled', lambda: {'ok': row_enabled('join-meeting') is False})

        # D2c menu order (docs/re/sidebar-menus-parity.md §1): Arc 1.172.2, capture session 3 Part D.
        # Open differences, each recorded: Share stays "Share…" (a picker) until C3 item 1 records Arc's submenu.
        def sidebar_menu_order():
            focus()
            # Its own Space, so Archive Tabs Above touches only this case's rows.
            app.call('space', space=app.call('space-create', title='Menu order', profile='Default'))
            made = [app.call('open', url=origin + '/target.html?menu=%d' % i, background=True)['id'] for i in range(5)]
            try:
                today_top, today_mid, today_last, pinned, favorite = made
                app.call('pin', tab=pinned)
                app.call('favorite', tab=favorite)
                empty = app.call('folder', tabs=[], title='Menu Empty', section='pinned')
                today_ids = [n['id'] for n in app.call('sidebar-tree')['today'] if n['kind'] == 'tab']
                items = lambda node, **kw: app.call('sidebar-menu-items', **({'node': node} if node else {}), **kw)
                today_expected = ['Copy Link', 'Share…', '—', 'Change Icon…', 'Rename…', 'Mute', '—', 'Open in Split View',
                                  'Duplicate', 'Move to ▸', '—', 'Archive Tab', 'Archive Other Tabs', 'Archive Tabs Below',
                                  'Archive Tabs Above']
                pinned_head = ['Copy Link', 'Share…', '—', 'Change Icon…', 'Rename…', 'Mute', 'Edit Pinned Page ▸', '—',
                               'Open in Split View', 'Duplicate', 'Move to ▸', '—']
                first, last = items(today_ids[0]), items(today_ids[-1])
                rows = {
                    'today': first['items'] == today_expected,
                    'today_first_above_disabled': 'Archive Tabs Above' in first['disabled'] and 'Archive Tabs Below' not in first['disabled'],
                    'today_last_below_disabled': 'Archive Tabs Below' in last['disabled'] and 'Archive Tabs Above' not in last['disabled'],
                    'today_silent_mute_disabled': 'Mute' in first['disabled'],
                    'pinned': items(pinned)['items'] == pinned_head + ['Remove Pin'],
                    'favorite': items(favorite)['items'] == pinned_head + ['Remove Favorite'],
                    'folder_empty': items(empty)['items'] == ['Share Folder…', '—', 'New Nested Folder…', 'Turn “Menu Empty” into Space',
                                                              '—', 'Change Icon…', 'Rename…', '—', 'Duplicate', 'Move to ▸', '—', 'Delete'],
                    'space': items(None)['items'][:9] == ['Change Space Icon…', 'Rename Space…', 'Edit Theme Color…', 'Set Profile ▸',
                                                         '—', 'New Folder', 'Live Folders ▸', '—', 'Share Space…'],
                }
                # Behaviour: Archive Tabs Above on the row whose menu enables it archives every row above, then undo.
                before = [n['id'] for n in app.call('sidebar-tree')['today'] if n['kind'] == 'tab']
                target = next((t for t in before if 'Archive Tabs Above' not in items(t)['disabled']), None)
                rows['archive_above_enabled_somewhere'] = target is not None and target != before[0]
                if target is not None:
                    app.call('sidebar-menu', node=target, item='Archive Tabs Above')
                    after = [n['id'] for n in app.call('sidebar-tree')['today'] if n['kind'] == 'tab']
                    rows['archive_above_acts'] = target in after and len(after) < len(before)
                    app.call('key', key='z', modifiers=['command'], route='app')
                    rows['archive_above_undo'] = wait(lambda: [n['id'] for n in app.call('sidebar-tree')['today'] if n['kind'] == 'tab'] == before, timeout=3) is True
                return {'ok': all(rows.values()), 'rows': rows, 'todayOrder': before, 'target': target,
                        'menus': {'todayFirst': first, 'todayLast': last, 'pinned': items(pinned), 'favorite': items(favorite)}}
            finally:
                for tab_id in made:
                    h._try(lambda t=tab_id: app.call('close', tab=t))
                h._try(focus)
        run('cm_sidebar_menu_order', sidebar_menu_order)

        # D2c URL field menu (S3D order). Share stays "Share…" until C3 item 1; the toggle flips Shared Quotes.
        def url_field_menu():
            focus()
            expected = ['Copy URL', 'Share…', 'Capture…', 'Capture Full Page', 'Capture in Portrait Mode', '—',
                        'Show as Toolbar', 'Disable Shared Quotes']
            listed = app.call('sidebar-menu-items', surface='url-field')
            app.call('sidebar-menu', surface='url-field', item='Disable Shared Quotes')
            flipped = app.call('sidebar-menu-items', surface='url-field')
            app.call('sidebar-menu', surface='url-field', item='Enable Shared Quotes')
            restored = app.call('sidebar-menu-items', surface='url-field')
            app.call('sidebar-menu', surface='url-field', item='Copy URL')
            copied = app.call('pasteboard')
            rows = {'order': listed['items'] == expected, 'none_disabled_with_page': listed['disabled'] == [],
                    'quotes_toggle': flipped['items'][-1] == 'Enable Shared Quotes' and restored['items'][-1] == 'Disable Shared Quotes',
                    'copy_url': isinstance(copied, str) and copied.startswith(origin)}
            return {'ok': all(rows.values()), 'rows': rows, 'listed': listed, 'copied': copied}
        run('cm_url_field_menu', url_field_menu)

        # D2c bottom-bar "+" (S3D items and order; the popover form is capture pending, C3 item 7).
        def plus_menu():
            focus()
            rows = app.call('split', op='plus')
            titles = ['—' if r.get('separator') else r['title'] for r in rows]
            expected = ['New Space', 'New Folder', '—', 'New Easel', 'New Boost', '—', 'New Split', 'New Tab']
            enabled = {r['title']: r['enabled'] for r in rows if not r.get('separator')}
            keys = {r['title']: r.get('key') for r in rows if not r.get('separator')}
            ok = titles == expected and enabled.get('New Boost') is True and enabled.get('New Split') is True
            return {'ok': ok, 'titles': titles, 'enabled': enabled, 'keys': keys}
        run('cm_plus_menu', plus_menu)
        if only_case and not ran_cases:
            raise RuntimeError('Unknown context-menu case: ' + only_case)
    finally:
        try:
            if not app.closed:
                h._try(lambda: app.call('policy', contextMenu='record'))
                h._try(lambda: app.call('peek-close'))
                h._try(lambda: app.call('capture-action', action='cancel'))
        finally:
            h._restore_defaults(app, saved)
            try:
                app.quit()
            finally:
                server.shutdown()
                server.server_close()
                mail_server.shutdown()
                mail_server.server_close()
