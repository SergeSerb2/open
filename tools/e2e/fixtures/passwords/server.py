#!/usr/bin/env python3 -I
"""Loopback-only synthetic passwords fixtures. No request or form-value logging."""
import argparse
import base64
import hmac
import http.server
import json
import ssl
import threading
from pathlib import Path
from http.cookies import SimpleCookie, CookieError
from urllib.parse import urlsplit
import sys as _sys
_sys.path.append(str(Path(__file__).resolve().parents[2]))  # loopback_http; appended, so the stdlib wins
from loopback_http import LoopbackHTTPServer

ROOT = Path(__file__).resolve().parent
USERNAME = 'fixture-user'
PASSWORD = 'fixture-password-1'
MAX_BODY = 8192
PAGES = {name + '.html' for name in ('login', 'change', 'signup', 'iframe', 'address', 'card', 'webauthn')}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'OpenFixture/1'

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *_):
        pass  # Never log request bodies, authorization, cookies or form values.

    def reply(self, status, body=b'', mime='text/html; charset=utf-8', headers=()):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = urlsplit(self.path).path
        if path.removeprefix('/') in PAGES:
            self.reply(200, (ROOT / path.removeprefix('/')).read_bytes())
        elif path == '/welcome':
            redirect = (b'<script>location.replace("/dashboard")</script>'
                        if self.headers.get('Host', '').split(':', 1)[0] == 'redirect.example.com' else b'')
            self.reply(200, b'<!doctype html><title>Fixture welcome</title><h1 id="welcome">Submitted</h1>' + redirect)
        elif path == '/dashboard':
            self.reply(200, b'<!doctype html><title>Fixture dashboard</title><h1 id="dashboard">Dashboard</h1>')
        elif path == '/set-cookies':
            self.reply(200, b'<!doctype html><title>Cookies set</title><p>Fixture cookies set.</p>', headers=[
                ('Set-Cookie', 'oe_persist=fixture; Path=/; Max-Age=86400; HttpOnly'),
                ('Set-Cookie', 'oe_session=fixture; Path=/'),
                ('Set-Cookie', 'oe_lax=fixture; Path=/; Max-Age=86400; SameSite=Lax')])
        elif path == '/echo-cookies':
            cookies = SimpleCookie()
            header = self.headers.get('Cookie', '')
            if len(header) > MAX_BODY:
                self.reply(431, b'Cookie header too large', 'text/plain')
                return
            try:
                cookies.load(header)
            except CookieError:
                pass
            # Only the synthetic cookie NAMES cross this endpoint.
            self.reply(200, json.dumps(sorted(cookies.keys())).encode(), 'application/json')
        elif path == '/basic':
            # Deliberately never inspect or reflect the Authorization header.
            self.reply(401, b'<!doctype html><title>Basic auth fixture</title><p>Authentication required.</p>',
                       headers=[('WWW-Authenticate', 'Basic realm="Open fixture"')])
        elif path in ('/basic-login', '/basic-other-realm'):
            # Only this synthetic route checks credentials. Never reflect or
            # log the Authorization header, even when it is wrong or too long.
            authorization = self.headers.get('Authorization', '')
            if len(authorization) > MAX_BODY:
                self.reply(431, b'Authorization header too large', 'text/plain')
                return
            expected = 'Basic ' + base64.b64encode((USERNAME + ':' + PASSWORD).encode()).decode()
            if hmac.compare_digest(authorization.encode('utf-8'), expected.encode('ascii')):
                self.reply(200, b'<!doctype html><title>Authenticated fixture</title><h1 id="authenticated">Signed in</h1>')
            else:
                realm = 'Open fixture' if path == '/basic-login' else 'Other Open fixture'
                self.reply(401, b'<!doctype html><title>Basic auth fixture</title><p>Authentication required.</p>',
                           headers=[('WWW-Authenticate', 'Basic realm="' + realm + '"')])
        else:
            self.reply(404, b'Not found', 'text/plain')

    def do_POST(self):
        if self.headers.get('Transfer-Encoding'):
            self.close_connection = True
            self.reply(400, b'Unsupported transfer encoding', 'text/plain')
            return
        try:
            length = int(self.headers.get('Content-Length', '-1'))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            self.close_connection = True
            self.reply(413, b'Form too large or missing length', 'text/plain')
            return
        self.rfile.read(length)  # Discard synthetic values. Never reflect them.
        if urlsplit(self.path).path in ('/login', '/change', '/signup', '/address', '/card'):
            self.reply(302, headers=[('Location', '/welcome')])
        else:
            self.reply(404, b'Not found', 'text/plain')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--cert')
    parser.add_argument('--key')
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error('port must be between 0 and 65535')
    if bool(args.cert) != bool(args.key):
        parser.error('cert and key must be supplied together')
    with LoopbackHTTPServer(Handler, args.port) as server:
        server.daemon_threads = True
        secure = None
        worker = None
        try:
            if args.cert:
                secure = LoopbackHTTPServer(Handler)
                secure.daemon_threads = True
                tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                tls.load_cert_chain(args.cert, args.key)
                secure.socket = tls.wrap_socket(secure.socket, server_side=True)
                worker = threading.Thread(target=secure.serve_forever, daemon=True)
                worker.start()
                print(json.dumps({'http': server.server_port, 'https': secure.server_port}), flush=True)
            else:
                print(server.server_port, flush=True)
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            if secure:
                secure.shutdown()
                secure.server_close()
            if worker:
                worker.join(timeout=5)


if __name__ == '__main__':
    main()
