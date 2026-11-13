"""The one HTTP server class for test and tool fixtures: 127.0.0.1 only, no name lookup.

`http.server.HTTPServer.server_bind` calls `socket.getfqdn(host)`. That is a PTR query
through mDNSResponder. On macOS the query goes through Local Network privacy, and the
system shows "Allow 'Python' to find devices on local networks?" (rented Mac 1 log,
2026-11-12 20:57:09: PTR from the suite's Python, then nehelper, then
UserNotificationCenter). This class binds the loopback address and sets `server_name`
without any lookup. Map fixture host names with the engine's `--host-resolver-rules`.

The gate's build row (`tools/verification/check.py`, `loopback_servers`) fails when a
file under tools/ creates or subclasses an HTTP or TCP server class directly, or calls
`getfqdn`/`gethostbyaddr`. Import this module instead:

    from loopback_http import LoopbackHTTPServer
    server = LoopbackHTTPServer(Handler)          # ephemeral port
    server = LoopbackHTTPServer(Handler, port)    # fixed port

Files outside tools/e2e append tools/e2e to sys.path (append, so the standard library
always wins) before the import.
"""
import http.server
import socketserver


class LoopbackHTTPServer(http.server.ThreadingHTTPServer):
    """ThreadingHTTPServer on 127.0.0.1 whose bind does no name lookup."""

    def __init__(self, handler, port=0, bind_and_activate=True):
        super().__init__(("127.0.0.1", port), handler, bind_and_activate)

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]
