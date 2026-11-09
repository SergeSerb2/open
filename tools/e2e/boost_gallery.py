"""Local Gallery through native menus, hosted controls, the editor and real pages."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import threading
import traceback
from contextlib import contextmanager


@contextmanager
def fixture(tmp):
    root = Path(tmp) / 'gallery-tls'
    root.mkdir(mode=0o700)
    config, key, cert = (root / n for n in ('openssl.cnf', 'key.pem', 'cert.pem'))
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=gallery.example.test\n[ext]\nsubjectAltName=DNS:*.example.test\n')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(config), '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True, timeout=15)
    key.chmod(0o600)
    public = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-pubkey', '-noout'], timeout=10)
    der = subprocess.check_output(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=public, timeout=10)
    pin = base64.b64encode(hashlib.sha256(der).digest()).decode('ascii')
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'<!doctype html><title>Gallery fixture</title><style>body{background:white;color:#222}header{width:600px;height:300px;background:#2e7df6}</style><header></header><h1>Gallery fixture heading</h1><p>Local synthetic content.</p>'
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *_):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        yield ['--host-resolver-rules=MAP *.example.test 127.0.0.1:%d' % server.server_port, '--no-proxy-server', '--ignore-certificate-errors-spki-list=' + pin]
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5)


def run(factory, results, tmp, env):
    wait, new_tab = env['wait_until'], env['new_tab']
    app = None
    saved = {}
    keys = {'open.advanced.enableBoosts': True, 'open.boosts.hasDismissedInterstitial': True,
            'open.boosts.hasDismissedJSNotice': True, 'open.general.searchSuggestNoticeDismissed': True,
            'open.library.lastSection': 'spaces', 'open.settings.lastPane': None}
    selected = set(filter(None, os.environ.get('OPEN_BG_ONLY', '').split(',')))
    known = {'BG1_menu', 'BG1_commandbar', 'F1_key_library', 'F1_browser_profile',
             'F1_editor_profile', 'F2_layout', 'BG2_cards_toggle', 'F4_toggle_profile',
             'F4_edit_profile', 'BG3_edit', 'F6_settings_preference', 'BG_private',
             'BG3_delete_empty', 'BG_focus'}
    if selected - known:
        raise ValueError('unknown Gallery rows: ' + ', '.join(sorted(selected - known)))
    def row(name, fn):
        if selected and name not in selected:
            return
        env['begin_row'](name)
        try:
            detail = fn() or {}
            results[name] = dict(detail, ok=True)
            print(name, 'PASS', flush=True)
        except env['FocusInterruption']:
            raise
        except Exception as error:
            results[name] = dict(ok=False, error=str(error), trace=traceback.format_exc()[-1800:])
            print(name, 'FAIL', str(error), flush=True)
    def ui(action='state', **kw):
        return app.call('boost-gallery-ui', action=action, **kw)
    def state():
        return app.call('settings-state')
    def editor(action='state', **kw):
        return app.call('boost-editor', action=action, **kw)
    def tap(id):
        return editor('tap', id=id)
    def items(profile=None):
        return app.call('boosts', profile=profile or profile_a)
    def browser():
        app.call('window-focus', id=normal, activate=True)
        app.call('space', space=space_a)
    def gallery():
        browser(); app.call('menu-perform', id='boost-gallery')
        assert wait(lambda: state()['boostsPresentation'] == 'gallery', timeout=5)
        assert wait(lambda: 'boosts.gallery' in ids(), timeout=5), ui()
    def ids():
        return {c['id'] for c in ui()['controls'] if c['id']}
    def font(tab):
        return app.eval(tab, "getComputedStyle(document.querySelector('h1')).fontFamily")
    def profile(name):
        ui('profile', name=name)
        assert wait(lambda: state()['boostsProfile'] == (profile_a if name == name_a else profile_b), timeout=5)
    def enabled():
        return next(m['enabled'] for m in app.call('menu-state') if m['id'] == 'boost-gallery')
    def bar():
        return app.call('commandbar-state')
    def type_gallery():
        app.call('key', key='t', modifiers=['cmd'], route='app')
        assert wait(lambda: bar()['presented'], timeout=5)
        app.call('key', text='Boost Gallery', route='app')
        assert wait(lambda: bar().get('final'), timeout=5)
    with fixture(tmp) as switches:
        try:
            app = factory(urls=('https://alpha.example.test/boost.html',), fresh=True, extra_args=switches)
            for key, value in keys.items():
                saved[key] = app.call('defaults', key=key, persistent=True)
                app.call('defaults', key=key, value=value)
            tab_a = app.call('tabs')[0]['id']; app.call('wait', tab=tab_a)
            normal = app.call('shell-windows')[0]['id']
            spaces = app.call('spaces'); space_a = next(s['id'] for s in spaces if s['focused'])
            profile_a = next(s['profile'] for s in spaces if s['id'] == space_a)
            snapshot = json.loads(Path(app.call('save')).read_text())
            name_a = next(p['name'] for p in snapshot['profiles'] if p['id'] == profile_a)
            name_b = 'Gallery B'
            space_b = app.call('space-create', title=name_b, profile=name_b)
            profile_b = next(s['profile'] for s in app.call('spaces') if s['id'] == space_b)
            browser()
            tab_b = new_tab(app, 'https://beta.example.test/boost.html')
            def create(tab, name):
                app.call('select', tab=tab); app.call('menu-perform', id='new-boost')
                assert wait(lambda: editor().get('colorsReady'), timeout=15), editor()
                tap('font.Avenir'); tap('menu.Rename this Boost…'); editor('type', text=name); tap('alert.Done')
                result = editor()['boost']; editor('close')
                assert wait(lambda: font(tab).startswith('Avenir'), timeout=5)
                return result['id']
            first, second = create(tab_a, 'Alpha Boost'), create(tab_b, 'Beta Boost')
            browser(); app.call('select', tab=tab_a)
            def bg1_menu():
                app.call('menu-perform', id='view-boosts'); before = state()
                assert before['boostsPresentation'] == 'list'
                app.call('menu-perform', id='boost-gallery')
                assert wait(lambda: 'boosts.gallery' in ids(), timeout=5), ui()
                assert state()['library'] == before['library'] and state()['boostsProfile'] == profile_a
                return {'sameWindow': True, 'cards': sorted(id for id in ids() if id.endswith('.card'))}
            row('BG1_menu', bg1_menu)
            def bg1_bar():
                browser(); app.call('menu-perform', id='view-boosts'); before = state()['library']; browser()
                type_gallery()
                assert any(r.get('action') == 'boost-gallery' for r in bar()['rows']), bar()
                app.call('key', key='return', route='app')
                assert wait(lambda: not bar()['presented'] and state()['boostsPresentation'] == 'gallery', timeout=5)
                assert 'boosts.gallery' in ids() and state()['library'] == before
                return {'sameWindow': True, 'realAppReturn': True}
            row('BG1_commandbar', bg1_bar)
            def f1_key():
                gallery(); profile(name_b)
                assert ui()['key']
                app.call('menu-perform', id='boost-gallery')
                assert state()['boostsProfile'] == profile_b, state()
                assert not any(id.endswith('.card') for id in ids())
                return {'keptLibraryB': True}
            row('F1_key_library', f1_key)
            def f1_browser():
                gallery(); profile(name_b); browser(); app.call('menu-perform', id='boost-gallery')
                assert state()['boostsProfile'] == profile_a, state()
                assert 'boosts.' + first + '.card' in ids()
                return {'visibleLibraryBOverriddenByBrowserA': True}
            row('F1_browser_profile', f1_browser)
            def f1_editor():
                gallery(); profile(name_b); browser(); app.call('select', tab=tab_a)
                editor('open', boost=first); tap('menu.All Boosts…')
                assert wait(lambda: state()['boostsProfile'] == profile_a, timeout=5), state()
                editor('close')
                return {'editorAOverridesVisibleLibraryB': True}
            row('F1_editor_profile', f1_editor)
            def f2():
                gallery(); ui('section', section='downloads'); ui('section', section='boosts')
                assert state()['boostsPresentation'] == 'gallery'
                ui('layout', name='List'); assert wait(lambda: state()['boostsPresentation'] == 'list' and 'boosts.list' in ids(), timeout=5)
                ui('layout', name='Gallery'); profile(name_b)
                app.call('menu-perform', id='view-library')
                assert state()['boostsPresentation'] == 'gallery' and state()['boostsProfile'] == profile_b, state()
                ui('section', section='history'); app.call('menu-perform', id='view-library')
                assert state()['boostsProfile'] == profile_b and state()['librarySection'] == 'history', state()
                ui('section', section='boosts'); app.call('menu-perform', id='view-boosts')
                assert state()['boostsPresentation'] == 'list'
                return {'inWindowList': True, 'plainLibraryPreserved': True, 'historyPreserved': True}
            row('F2_layout', f2)
            def bg2():
                gallery(); controls=ui()['controls']; labels=' '.join(c['label'] + ' ' + c['value'] for c in controls)
                assert all(s in labels for s in ['Alpha Boost', 'Beta Boost', 'alpha.example.test', 'beta.example.test']), controls
                ui('press', id='boosts.' + first + '.enabled')
                assert wait(lambda: not font(tab_a).startswith('Avenir'), timeout=5)
                assert font(tab_b).startswith('Avenir')
                ui('press', id='boosts.' + first + '.enabled')
                assert wait(lambda: font(tab_a).startswith('Avenir'), timeout=5)
                ui('search', text='Beta'); assert wait(lambda: 'boosts.' + first + '.card' not in ids(), timeout=5)
                assert 'boosts.' + second + '.card' in ids()
                ui('search', text=''); profile(name_b); assert not any(id.endswith('.card') for id in ids())
                profile(name_a); assert all('boosts.' + id + '.card' in ids() for id in [first, second])
                app.call('snapshot', window=state()['library'], path=str(Path(tmp) / 'gallery-rest.png'))
                env['shot'](app, 'boost-gallery-rest.png', window=state()['library'])
                return {'liveToggleOffOn': True, 'otherSiteUnchanged': True, 'searchAndProfiles': True}
            row('BG2_cards_toggle', bg2)
            def f4_toggle():
                gallery(); ui('press', id='boosts.' + first + '.enabled', profileBeforePress=profile_b)
                assert wait(lambda: not next(b['isEnabled'] for b in items() if b['id'] == first), timeout=5)
                assert state()['boostsProfile'] == profile_b and not items(profile_b)
                profile(name_a); ui('press', id='boosts.' + first + '.enabled')
                assert wait(lambda: font(tab_a).startswith('Avenir'), timeout=5)
                return {'renderedProfileRetained': True}
            row('F4_toggle_profile', f4_toggle)
            def edit_card(queued=False):
                gallery(); ui('press', id='boosts.' + first + '.edit', **({'profileBeforePress': profile_b} if queued else {}))
                assert wait(lambda: editor().get('open') and editor().get('boost', {}).get('id') == first, timeout=15), editor()
                assert editor()['profile'] == profile_a
                if queued: assert state()['boostsProfile'] == profile_b
                target = editor()['tab']; app.call('wait', tab=target)
                assert app.eval(target, 'document.querySelector("h1").textContent') == 'Gallery fixture heading'
                editor('close')
                return {'realCardEdit': True, 'profileA': True, 'realHTTPSFixture': True}
            row('F4_edit_profile', lambda: edit_card(True))
            row('BG3_edit', edit_card)
            def f6():
                browser(); app.call('settings-pane', pane='advanced')
                ui('press', window='settings', label='Enable Boosts on websites you visit')
                assert wait(lambda: app.call('defaults', key='open.advanced.enableBoosts') is False, timeout=5)
                browser(); assert not enabled()
                type_gallery(); assert not any(r.get('action') == 'boost-gallery' for r in bar()['rows']); app.call('key', key='escape', route='app')
                assert wait(lambda: not font(tab_a).startswith('Avenir'), timeout=5)
                app.call('menu-perform', id='view-boosts'); ui('press', label='Turn On')
                assert wait(lambda: app.call('defaults', key='open.advanced.enableBoosts') is True and font(tab_a).startswith('Avenir'), timeout=5)
                browser(); assert enabled(); app.call('select', tab=tab_a); editor('open', boost=first)
                assert editor()['globallyEnabled']; editor('close')
                return {'settingsOffRefusedMenuAndBar': True, 'turnOnRestoredLivePage': True, 'editorAgreed': True}
            row('F6_settings_preference', f6)
            def private():
                browser(); app.call('menu-perform', id='new-incognito-window')
                private = wait(lambda: next((w for w in app.call('incognito-state')['windows'] if w['private']), None), timeout=5)
                assert private
                app.call('window-focus', id=private['id'], activate=True)
                assert not enabled()
                refused=False
                try: app.call('menu-perform', id='boost-gallery')
                except RuntimeError: refused=True
                assert refused
                type_gallery(); assert not any(r.get('action') == 'boost-gallery' for r in bar()['rows']); app.call('key', key='escape', route='app')
                app.call('window-close'); browser()
                return {'privateMenuAndBarRefused': True}
            row('BG_private', private)
            def delete():
                gallery(); ui('press', id='boosts.' + second + '.delete')
                alert=wait(lambda: app.call('alert', window='library'), timeout=5)
                assert 'Delete this Boost?' in alert['texts'], alert
                if os.environ.get('OPEN_BG_FAIL_IN_SHEET') == '1': raise AssertionError('forced Gallery failure with Delete sheet open')
                app.call('key', key='escape', route='app', window=next(w['number'] for w in app.call('windows') if w['sheet']))
                assert len(items()) == 2
                ui('press', id='boosts.' + second + '.delete'); app.call('alert', window='library', button='Delete')
                assert wait(lambda: all(b['id'] != second for b in items()), timeout=5)
                assert wait(lambda: not font(tab_b).startswith('Avenir'), timeout=5)
                ui('press', id='boosts.' + first + '.delete'); app.call('alert', window='library', button='Delete')
                assert wait(lambda: not items(), timeout=5)
                assert 'Nothing Boosted Yet!' in ' '.join(c['label'] + c['value'] for c in ui()['controls'])
                ui('layout', name='List'); assert state()['boostsPresentation'] == 'list'
                return {'cancelInert': True, 'confirmedDeleteLive': True, 'empty': True, 'existingUndo': 'none'}
            row('BG3_delete_empty', delete)
            def focus():
                browser(); app.call('menu-perform', id='boost-gallery'); number=state()['library']
                app.call('key', key='w', modifiers=['cmd'], route='app', window=number)
                assert not any(w['number'] == number and w['visible'] for w in app.call('windows'))
                browser(); app.call('menu-perform', id='boost-gallery')
                for key in ['t', 'l']:
                    app.call('key', key=key, modifiers=['cmd'], route='app', window=state()['library'])
                    assert wait(lambda: bar()['presented'], timeout=5), bar()
                    app.call('key', key='escape', route='app')
                    assert wait(lambda: not bar()['presented'], timeout=5)
                return {'cmdW': True, 'cmdT': True, 'cmdL': True, 'escape': True, 'return': 'BG1_commandbar'}
            row('BG_focus', focus)
        finally:
            try:
                if app and not app.closed:
                    app.call('alert', window='library', button='Cancel', timeout=3)
            except RuntimeError:
                pass
            finally:
                try:
                    # Stop querying a failed/dead App while unwinding. Restore
                    # the same shared domain even when strict checks abort.
                    env['_restore_defaults'](None, saved)
                finally:
                    if app:
                        app.quit()
