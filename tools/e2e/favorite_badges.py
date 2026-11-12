"""Audit A2: Favorite ("Top App") unread badges through the real App, real pages and the real menu.

A private HTTPS server (a one-day self-signed certificate; the app hosts are HSTS-preloaded, so
plain HTTP cannot load) answers for the app hosts (x.com, web.whatsapp.com, mail.google.com) and a
plain host (example.com) through host-resolver rules; no request reaches a public host. Each page sets
its own title, as a signed-in app does. Rows (FB_*):
  gmail_count        "Inbox (12) - … - Gmail" shows 12
  leading_count      "(3) Home / X" shows 3
  cap                "(120) …" shows 99+
  no_count           a title without "(N)" shows no badge
  title_update       the badge follows a live title change
  plain_site         a non-app Favorite shows no badge and no "Show Unread Badge" item
  host_switch        "Show Unread Badge" on Gmail turns the badge off/on and stores the host
  twitter_switch     the item on X writes the Twitter switch, not the host list
  whatsapp_switch    the item on WhatsApp writes the WhatsApp switch
  other_window       a second window's tile follows a switch changed in the first
  pinned_no_badge    a Pinned (not Favorite) tab with a count title has no tile badge
"""
import http.server
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import threading

HOSTS = ('x.com', 'web.whatsapp.com', 'mail.google.com', 'example.com')
KEYS = ('open.favorites.badgingDisabledHosts', 'open.favorites.subtitleDisabledHosts',
        'open.favorites.twitterBadgeEnabled', 'open.favorites.whatsAppBadgeEnabled')


def run(factory, results, harness):
    wait_until, new_tab = harness['wait_until'], harness['new_tab']

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'<!doctype html><title>Start</title><link rel="icon" href="data:,"><p>Open badge fixture</p>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
        def log_message(self, *_): pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    folder = tempfile.mkdtemp(prefix='open-favorite-badges-')
    cert, key = os.path.join(folder, 'cert.pem'), os.path.join(folder, 'key.pem')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=Open favorite badge fixture', '-keyout', key, '-out', cert],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    rules = ', '.join('MAP %s 127.0.0.1:%d' % (h, server.server_port) for h in HOSTS)
    app = None

    def row(name, ok, **evidence):
        results['FB_' + name] = dict(ok=bool(ok), **evidence)
        print('FB_' + name, 'PASS' if ok else 'FAIL', json.dumps(evidence, sort_keys=True, default=str), flush=True)

    try:
        app = factory(urls=('about:blank',), fresh=True,
                      extra_args=['--host-resolver-rules=' + rules + ', MAP * ~NOTFOUND, EXCLUDE localhost',
                                  '--ignore-certificate-errors', '--no-proxy-server'])
        for key in KEYS: app.call('defaults', key=key, value=None)

        def favorite(host, path='/'):
            tab = new_tab(app, 'https://%s%s' % (host, path))
            app.call('wait', tab=tab)
            app.call('favorite', tab=tab)
            return tab

        def title(tab, text):
            app.call('eval', tab=tab, js='document.title = %s; true' % json.dumps(text))

        def badge(tab): return app.call('favorite-badge', favorite=tab)

        def shows(tab, text):
            return wait_until(lambda: (lambda b: b if (b['shown'] and b['text'] == text) or (text is None and not b['shown']) else None)(badge(tab)),
                              timeout=4, step=.05)

        def menu(tab, item='Show Unread Badge'):
            try: return app.call('sidebar-menu-state', node=tab, item=item)
            except Exception as error: return {'missing': str(error)}

        def stored(key): return app.call('defaults', key=key, persistent=True)

        gmail = favorite('mail.google.com', '/mail/u/0/#inbox')
        title(gmail, 'Inbox (12) - a@example.test - Gmail')
        b = shows(gmail, '12')
        row('gmail_count', b and b['frame'][3] > 0 and b['frame'][0] + b['frame'][2] <= b['tile'][0], badge=b or badge(gmail))

        x = favorite('x.com', '/home')
        title(x, '(3) Home / X')
        row('leading_count', shows(x, '3'), badge=badge(x))
        title(x, '(120) Home / X')
        row('cap', shows(x, '99+'), badge=badge(x))
        title(x, 'Home / X')
        row('no_count', shows(x, None), badge=badge(x))
        title(x, '(7) Home / X')
        row('title_update', shows(x, '7'), badge=badge(x))

        plain = favorite('example.com')
        title(plain, '(5) Example')
        hidden = shows(plain, None)
        row('plain_site', hidden and 'missing' in menu(plain), badge=badge(plain), menu=menu(plain))

        before = menu(gmail)
        app.call('sidebar-menu', node=gmail, item='Show Unread Badge')
        off, off_menu, off_store = shows(gmail, None), menu(gmail), stored(KEYS[0])
        app.call('sidebar-menu', node=gmail, item='Show Unread Badge')
        on = shows(gmail, '12')
        row('host_switch', before.get('checked') is True and off and off_menu.get('checked') is False
            and off_store == ['mail.google.com'] and on and stored(KEYS[0]) == [],
            before=before, offMenu=off_menu, stored=off_store)

        app.call('sidebar-menu', node=x, item='Show Unread Badge')
        x_off, x_store, x_hosts = shows(x, None), stored(KEYS[2]), stored(KEYS[0])
        app.call('sidebar-menu', node=x, item='Show Unread Badge')
        row('twitter_switch', x_off and x_store is False and x_hosts == [] and shows(x, '7') and stored(KEYS[2]) is True,
            stored=x_store, hosts=x_hosts)

        wa = favorite('web.whatsapp.com')
        title(wa, '(2) WhatsApp')
        wa_on = shows(wa, '2')
        app.call('sidebar-menu', node=wa, item='Show Unread Badge')
        wa_off, wa_store = shows(wa, None), stored(KEYS[3])
        app.call('sidebar-menu', node=wa, item='Show Unread Badge')
        row('whatsapp_switch', wa_on and wa_off and wa_store is False and shows(wa, '2') and stored(KEYS[3]) is True,
            stored=wa_store)

        first_window = app.call('window-state')['id']
        app.call('command', id='new-window')
        second = wait_until(lambda: (lambda w: w if w['id'] != first_window else None)(app.call('window-state')), timeout=5, step=.05)
        mirrored = shows(gmail, '12')
        app.call('window-focus', id=first_window, activate=True)
        app.call('sidebar-menu', node=gmail, item='Show Unread Badge')
        app.call('window-focus', id=second['id'], activate=True) if second else None
        followed = shows(gmail, None)
        app.call('sidebar-menu', node=gmail, item='Show Unread Badge')
        row('other_window', bool(second) and mirrored and followed and shows(gmail, '12'), second=bool(second))
        if second: app.call('window-close', id=second['id'])
        app.call('window-focus', id=first_window, activate=True)

        app.call('sidebar-menu', node=x, item='Remove Favorite')
        pinned = new_tab(app, 'https://x.com/notifications')
        app.call('wait', tab=pinned)
        app.call('pin', tab=pinned)
        title(pinned, '(4) Notifications / X')
        try:
            app.call('favorite-badge', favorite=pinned); tile = True
        except Exception:
            tile = False
        row('pinned_no_badge', not tile, pinned=pinned)
    finally:
        try:
            if app:
                for key in KEYS: app.call('defaults', key=key, value=None)
                app.quit()
        finally:
            server.shutdown()
            server.server_close()
            shutil.rmtree(folder, ignore_errors=True)
