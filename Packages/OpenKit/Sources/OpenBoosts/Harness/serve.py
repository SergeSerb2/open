#!/usr/bin/env python3
"""Serve the real Boosts resources and standalone browser harness (no dependencies)."""
import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        path = urlsplit(self.path).path
        if not (ROOT / path.lstrip("/")).is_file() and (
            path.endswith("/post") or path.startswith("/Harness/blog") or
            (path.startswith("/Harness/") and "spa.html" in self.headers.get("Referer", ""))
        ):
            self.path = "/Harness/spa.html"
        super().do_GET()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8931)
    args = parser.parse_args()
    for page in ["loader", "static", "spa", "shadow-dom", "obfuscated"]:
        print(f"http://127.0.0.1:{args.port}/Harness/{page}.html", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
