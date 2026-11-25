#!/usr/bin/env python3
# Copyright 2026 The Open Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""End-to-end verification of the Open Unified Browser (Unified/PLAN.md §4).

Launches the real compiled browser (built with open_enable_automation =
true) on a fresh user-data directory and drives it only through its
automation channel (docs/automation.md): no system mouse or keyboard, no
mocks. Pixels come from the browser's own window (`snapshot`, Chromium's
ui::GrabWindowSnapshotAsPNG).

  verify_unified.py --binary ~/open-unified-chromium/src/out/OpenLinux/open
  verify_unified.py --binary .../open --only startup,tabs,adblock
  verify_unified.py --binary .../open.exe --port            # loopback TCP
  verify_unified.py --list

Linux without $DISPLAY runs the browser under Xvfb (--xvfb forces it).
The sync suite starts a real local SyncServer/ (Node.js 22+; built with
`npx tsrs -p tsconfig.json` when SyncServer/dist is missing) unless
--sync-url points at a running one.

Writes <out>/report.json, <out>/browser.log and one window PNG per suite.
Exit status 0 only when every selected suite passed.
"""

import argparse
import http.server
import json
import os
import platform
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.request
import uuid
from typing import Callable, Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from open_client import OpenClient, OpenError  # noqa: E402

REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
CHROMIUM_TAG = "156.0.8078.48"
AD_RULE = "/ads/banner.js$script"


class CheckFailed(AssertionError):
  pass


def check(condition, message: str):
  if not condition:
    raise CheckFailed(message)


# =============================================================================
# Fixture web server (pages, a script the ad-block rule matches)
# =============================================================================

class FixtureServer:
  """Serves deterministic pages on 127.0.0.1 and records every request."""

  PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>{title}</title><style>body{{font:16px sans-serif;background:{bg};
margin:40px}}</style></head><body><h1>{title}</h1>
<p id="marker">{marker}</p>
<button id="go" onclick="document.getElementById('clicked').textContent='yes'">
Go</button> <span id="clicked">no</span>
<p><input id="field" placeholder="type here" autofocus></p>
<p><a id="next" href="/page/{next}.html">next</a></p>
</body></html>"""

  AD_PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>Ad fixture</title></head><body><h1>Ad fixture</h1>
<div id="slot">no ad</div>
<script src="/ads/banner.js"></script>
<script>window.__adPageDone = true;</script>
</body></html>"""

  def __init__(self):
    self.requests: List[str] = []
    self._lock = threading.Lock()
    outer = self

    class Handler(http.server.BaseHTTPRequestHandler):
      def log_message(self, *args):
        pass

      def do_GET(self):  # noqa: N802
        with outer._lock:
          outer.requests.append(self.path)
        if self.path.startswith("/page/"):
          name = self.path[len("/page/"):].split(".")[0]
          try:
            n = int(name)
          except ValueError:
            n = 0
          colors = ["#ffffff", "#ffe8e8", "#e8ffe8", "#e8e8ff", "#fff4d6"]
          body = outer.PAGE.format(title=f"Page {n}", marker=f"marker-{n}",
                                   bg=colors[n % len(colors)], next=n + 1)
          self._send(200, "text/html", body)
        elif self.path == "/adpage.html":
          self._send(200, "text/html", outer.AD_PAGE)
        elif self.path == "/ads/banner.js":
          self._send(200, "application/javascript",
                     "window.__adLoaded = true;"
                     "document.getElementById('slot').textContent='AD';")
        else:
          self._send(404, "text/plain", "not found")

      def _send(self, status, content_type, body):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
      daemon_threads = True
      allow_reuse_address = True

    self._server = Server(("127.0.0.1", 0), Handler)
    self.port = self._server.server_address[1]
    self._thread = threading.Thread(target=self._server.serve_forever,
                                    daemon=True)

  def start(self):
    self._thread.start()
    return self

  def stop(self):
    self._server.shutdown()

  def url(self, path: str) -> str:
    return f"http://127.0.0.1:{self.port}{path}"

  def count(self, path: str) -> int:
    with self._lock:
      return sum(1 for p in self.requests if p == path)


# =============================================================================
# Processes: Xvfb, SyncServer, the browser
# =============================================================================

def free_port() -> int:
  with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    return s.getsockname()[1]


class Xvfb:
  def __init__(self, width=1600, height=1000):
    self.display = None
    self.proc = None
    self.size = (width, height)

  def start(self):
    if not shutil.which("Xvfb"):
      raise RuntimeError("Xvfb is not installed (apt install xvfb)")
    for n in range(90, 120):
      if not os.path.exists(f"/tmp/.X11-unix/X{n}") and \
          not os.path.exists(f"/tmp/.X{n}-lock"):
        self.display = f":{n}"
        break
    self.proc = subprocess.Popen(
        ["Xvfb", self.display, "-screen", "0",
         f"{self.size[0]}x{self.size[1]}x24", "-nolisten", "tcp"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
      if os.path.exists(f"/tmp/.X11-unix/X{self.display[1:]}"):
        return self
      time.sleep(0.1)
    raise RuntimeError("Xvfb did not start")

  def stop(self):
    if self.proc:
      self.proc.terminate()
      try:
        self.proc.wait(5)
      except subprocess.TimeoutExpired:
        self.proc.kill()


class SyncServerProcess:
  """A real SyncServer/ instance on a free loopback port."""

  def __init__(self, data_dir: str, log_path: str):
    self.data_dir = data_dir
    self.log_path = log_path
    self.proc = None
    self.url = None

  def start(self, timeout=60):
    server_dir = os.path.join(REPO_ROOT, "SyncServer")
    entry = os.path.join(server_dir, "dist", "index.js")
    if not os.path.exists(entry):
      if not shutil.which("npx"):
        raise RuntimeError("SyncServer/dist is missing and npx is not found")
      subprocess.run(["npm", "ci", "--no-audit", "--no-fund"],
                     cwd=server_dir, check=True)
      subprocess.run(["npx", "--yes", "tsrs", "-p", "tsconfig.json"],
                     cwd=server_dir, check=True)
    env = dict(os.environ, OPEN_SYNC_DATA_DIR=self.data_dir,
               OPEN_SYNC_PORT="0", OPEN_SYNC_HOST="127.0.0.1")
    self._log = open(self.log_path, "w", encoding="utf-8")
    self.proc = subprocess.Popen(
        ["node", "--no-warnings", entry], cwd=server_dir, env=env,
        stdout=subprocess.PIPE, stderr=self._log, text=True)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
      line = self.proc.stdout.readline()
      if not line:
        if self.proc.poll() is not None:
          raise RuntimeError(f"SyncServer exited ({self.proc.returncode}); "
                             f"see {self.log_path}")
        continue
      self._log.write(line)
      if line.startswith("OPEN_SYNC_LISTENING"):
        info = json.loads(line.split(" ", 1)[1])
        self.url = f"http://127.0.0.1:{info['port']}"
        threading.Thread(target=self._drain, daemon=True).start()
        return self
    raise RuntimeError("SyncServer did not report OPEN_SYNC_LISTENING")

  def _drain(self):
    for line in self.proc.stdout:
      self._log.write(line)

  def health(self) -> Dict:
    with urllib.request.urlopen(self.url + "/health", timeout=5) as r:
      return json.loads(r.read())

  def stop(self):
    if self.proc and self.proc.poll() is None:
      self.proc.terminate()
      try:
        self.proc.wait(10)
      except subprocess.TimeoutExpired:
        self.proc.kill()


class Browser:
  def __init__(self, binary: str, user_data: str, log_path: str,
               use_port: bool, env: Dict[str, str], extra: List[str]):
    self.binary = binary
    self.user_data = user_data
    self.log_path = log_path
    self.use_port = use_port
    self.env = env
    self.extra = extra
    self.proc = None
    self.client: Optional[OpenClient] = None

  def command_line(self) -> List[str]:
    args = [
        self.binary,
        f"--user-data-dir={self.user_data}",
        "--no-first-run",
        "--no-default-browser-check",
        "--open-skip-onboarding",
        "--password-store=basic",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-features=Translate,MediaRouter,OptimizationHints",
        "--window-size=1440,900",
        "--enable-logging=stderr",
        "--v=0",
    ]
    if self.use_port:
      args.append("--automation-port=0")
    else:
      args.append("--automation-socket=" +
                  os.path.join(self.user_data, "automation.sock"))
    if sys.platform == "darwin":
      args.append("--use-mock-keychain")
    if sys.platform.startswith("linux") and "DISPLAY" in self.env:
      args.append("--ozone-platform=x11")
    return args + self.extra

  def start(self, timeout=90):
    os.makedirs(self.user_data, exist_ok=True)
    self._log = open(self.log_path, "w", encoding="utf-8")
    self.proc = subprocess.Popen(self.command_line(), env=self.env,
                                 stdout=self._log, stderr=subprocess.STDOUT)
    end = time.monotonic() + timeout
    while time.monotonic() < end:
      if self.proc.poll() is not None:
        raise RuntimeError(f"browser exited ({self.proc.returncode}); "
                           f"see {self.log_path}")
      ready = os.path.exists(os.path.join(
          self.user_data,
          "automation.port" if self.use_port else "automation.sock"))
      if ready:
        break
      time.sleep(0.2)
    self.client = OpenClient.wait_for(
        deadline_s=max(5.0, end - time.monotonic()),
        user_data_dir=self.user_data,
        port=self._port() if self.use_port else None)
    return self

  def _port(self) -> int:
    with open(os.path.join(self.user_data, "automation.port"),
              encoding="utf-8") as f:
      return int(f.read().strip())

  def stop(self):
    if self.client:
      try:
        self.client.call("quit", _timeout=5)
      except (OSError, OpenError, ConnectionError, TimeoutError):
        pass
      self.client.close()
    if self.proc:
      try:
        self.proc.wait(20)
      except subprocess.TimeoutExpired:
        self.proc.send_signal(signal.SIGTERM if os.name != "nt"
                              else signal.CTRL_BREAK_EVENT)
        try:
          self.proc.wait(10)
        except subprocess.TimeoutExpired:
          self.proc.kill()


# =============================================================================
# Helpers
# =============================================================================

def png_size(path: str):
  with open(path, "rb") as f:
    header = f.read(24)
  check(header[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG")
  width, height = struct.unpack(">II", header[16:24])
  return width, height


class Context:
  def __init__(self, browser: Browser, fixtures: FixtureServer, out_dir: str,
               sync: Optional[SyncServerProcess], sync_url: Optional[str]):
    self.browser = browser
    self.client = browser.client
    self.fixtures = fixtures
    self.out_dir = out_dir
    self.sync = sync
    self.sync_url = sync_url
    self.notes: Dict[str, object] = {}

  def call(self, cmd, **args):
    return self.client.call(cmd, **args)

  def open_page(self, path: str, background=False) -> str:
    tab = self.call("open", url=self.fixtures.url(path), background=background)
    self.call("wait", tab=tab["id"], timeout=30)
    return tab["id"]

  def tabs(self) -> List[Dict]:
    return self.call("tabs")

  def tab_by_url(self, fragment: str) -> Optional[Dict]:
    for tab in self.tabs():
      if fragment in (tab.get("url") or ""):
        return tab
    return None

  def snapshot(self, name: str) -> str:
    path = os.path.join(self.out_dir, f"{name}.png")
    result = self.call("snapshot", path=path)
    width, height = png_size(path)
    check(width > 200 and height > 200, f"window PNG too small: {width}x{height}")
    check(result.get("width") == width, "snapshot width mismatch")
    return path


# =============================================================================
# Suites
# =============================================================================

def suite_startup(ctx: Context):
  ping = ctx.call("ping")
  check(ping["chromium"] == CHROMIUM_TAG,
        f"Chromium {ping['chromium']}, expected {CHROMIUM_TAG}")
  check(ping["engine"] == "chromium-views", "not the unified engine")
  check(ping.get("cef") is None, "CEF must not be present")
  check(os.path.samefile(ping["dataRoot"], ctx.browser.user_data),
        "data root differs from --user-data-dir")
  spaces = ctx.call("spaces")
  check(len(spaces) >= 1, "no default Space")
  check(any(s["focused"] for s in spaces), "no focused Space")
  check(os.path.exists(os.path.join(ctx.browser.user_data, "State",
                                    "browser.json")),
        "State/browser.json was not written")
  ctx.notes["platform"] = ping["platform"]


def suite_spaces(ctx: Context):
  spaces_before = ctx.call("spaces")
  before = {s["id"] for s in spaces_before}
  focused_before = next(s["id"] for s in spaces_before if s["focused"])
  created = ctx.call("space-create", title="E2E Work")
  check(created["id"] not in before, "space-create returned an old id")
  ctx.call("space", space=created["id"])
  spaces = {s["id"]: s for s in ctx.call("spaces")}
  check(spaces[created["id"]]["focused"], "new Space not focused")
  style = {
      "math_version": 1,
      "key_color": {"r": 0.92, "g": 0.35, "b": 0.20, "a": 1},
      "color_count": 2, "wheel": "complementary", "appearance": "dark",
      "noise_factor": 0.3, "texture": "grain", "intensity_factor": 0.8,
  }
  theme = ctx.call("space-theme", space=created["id"], style=style)
  check(theme["style"]["wheel"] == "complementary", "theme not applied")
  spaces = {s["id"]: s for s in ctx.call("spaces")}
  key = spaces[created["id"]]["theme"]["style"]["key_color"]
  check(abs(key["r"] - 0.92) < 1e-6, "theme not stored in the model")
  ctx.snapshot("spaces-themed")
  # Back to the first Space for the following suites.
  ctx.call("space", space=focused_before)
  ctx.notes["e2e_space"] = created["id"]


def suite_tabs(ctx: Context):
  ids = [ctx.open_page(f"/page/{n}.html") for n in (1, 2, 3)]
  tabs = ctx.tabs()
  today = [t for t in tabs if t["section"] == "today"]
  order = [t["id"] for t in today]
  # New tabs open at the top of Today (Arc placement): newest first.
  check(order.index(ids[2]) < order.index(ids[1]) < order.index(ids[0]),
        f"Today order wrong: {order}")
  active = [t for t in tabs if t["selected"]]
  check(active and active[0]["id"] == ids[2], "newest tab not selected")
  check(active[0]["page"]["title"] == "Page 3", "page title not propagated")

  # Real input inside the page: a click and typed text.
  ctx.call("click", tab=ids[2], selector="#go")
  ctx.client.wait_until(
      lambda: ctx.client.eval("document.getElementById('clicked')"
                              ".textContent", tab=ids[2]) == "yes",
      what="click result")
  ctx.client.eval("document.getElementById('field').focus()", tab=ids[2])
  ctx.call("type", tab=ids[2], text="hello open")
  ctx.client.wait_until(
      lambda: ctx.client.eval("document.getElementById('field').value",
                              tab=ids[2]) == "hello open",
      what="typed text")

  # Pin (Cmd-D semantics).
  pinned = ctx.call("pin", tab=ids[0])
  check(pinned["section"] == "pinned", "pin did not move the tab")

  # Folder of two Today tabs.
  folder = ctx.call("folder", tabs=[ids[1], ids[2]], section="today",
                    title="E2E Folder", at=0)
  rows = ctx.call("tabs", sidebar=True)["rows"]
  folders = [r for r in rows["today"] if r.get("kind") == "folder"]
  check(any(f["id"] == folder["folder"] and len(f["children"]) == 2
            for f in folders), "folder not in Today with its two tabs")

  # Navigate + back.
  ctx.call("navigate", tab=ids[2], url=ctx.fixtures.url("/page/7.html"))
  ctx.call("wait", tab=ids[2])
  ctx.call("back", tab=ids[2])
  ctx.client.wait_until(
      lambda: "/page/3.html" in ctx.call("tab-state", tab=ids[2])["url"],
      what="back navigation")

  # Close a Today tab: it leaves the sidebar and lands in the Archive.
  extra = ctx.open_page("/page/9.html")
  ctx.call("close", tab=extra)
  check(not any(t["id"] == extra for t in ctx.tabs()), "closed tab remains")
  archive = ctx.client.wait_until(
      lambda: [a for a in ctx.call("archive")
               if "/page/9.html" in a["url"]],
      what="archive row")
  check(archive[0]["reason"] in ("closed", "archived"),
        f"archive reason {archive[0]['reason']}")
  ctx.snapshot("tabs")
  ctx.notes["tabs"] = ids


def suite_split(ctx: Context):
  a = ctx.open_page("/page/11.html")
  b = ctx.open_page("/page/12.html")
  ctx.call("select", tab=b)
  result = ctx.call("split", tab=b)
  split_id = result.get("split")
  check(split_id, "split did not create a Split View")
  check(len(result["node"]["panes"]) == 2, "Split View needs two panes")
  state = ctx.call("tabs", sidebar=True)
  check(state["selectedNode"] == split_id, "Split not selected")
  pane_ids = {p["id"] for p in result["node"]["panes"]}
  check(pane_ids == {a, b}, f"unexpected panes {pane_ids}")
  for pane in pane_ids:
    check(ctx.call("tab-state", tab=pane)["loaded"], "pane not live")
  ctx.snapshot("split-view")
  ctx.call("split", tab=b)  # Unsplit.
  check(ctx.call("tabs", sidebar=True)["selectedNode"] != split_id,
        "unsplit failed")


def suite_command_bar(ctx: Context):
  state = ctx.call("command-bar", action="open", text="page/21")
  check(state["shown"], "command bar not shown")
  ctx.snapshot("command-bar")
  # Typing goes to the bar's field while it is open.
  ctx.call("command-bar", action="close")
  ctx.call("command-bar", action="open")
  ctx.call("type", text=ctx.fixtures.url("/page/21.html"))
  rows = ctx.client.wait_until(
      lambda: ctx.call("command-bar")["rows"], what="command bar rows")
  check(len(rows) >= 1, "no command bar rows")
  ctx.call("command-bar", action="enter")
  tab = ctx.client.wait_until(lambda: ctx.tab_by_url("/page/21.html"),
                              what="tab opened from the command bar")
  ctx.call("wait", tab=tab["id"])
  check(not ctx.call("command-bar")["shown"], "bar still open after enter")


def suite_peek(ctx: Context):
  state = ctx.call("peek-open", url=ctx.fixtures.url("/page/31.html"))
  check(state["shown"], "Peek not shown")
  time.sleep(1.0)
  ctx.snapshot("peek")
  state = ctx.call("peek-expand")
  check(not state["shown"], "Peek still shown after expand")
  tab = ctx.client.wait_until(lambda: ctx.tab_by_url("/page/31.html"),
                              what="Peek promoted to a tab")
  ctx.call("wait", tab=tab["id"])
  state = ctx.call("peek-open", url=ctx.fixtures.url("/page/32.html"))
  check(state["shown"], "second Peek not shown")
  check(not ctx.call("peek-close")["shown"], "Peek not closed")


def suite_adblock(ctx: Context):
  state = ctx.call("adblock-publish",
                   lists=[{"id": "E2EFixture", "text": AD_RULE + "\n"}])
  check(state["available"], "ad blocking unavailable")
  ctx.call("settings-adblock", enabled=True)
  ctx.client.wait_until(
      lambda: ctx.call("settings-adblock")["engineLoaded"],
      timeout=60, what="ad-block engine")

  before = ctx.fixtures.count("/ads/banner.js")
  tab = ctx.open_page("/adpage.html")
  ctx.client.wait_until(
      lambda: ctx.client.eval("window.__adPageDone === true", tab=tab),
      what="ad page")
  loaded = ctx.client.eval("window.__adLoaded === true", tab=tab)
  check(loaded is False, "the ad script ran (not blocked)")
  check(ctx.fixtures.count("/ads/banner.js") == before,
        "the ad request reached the server")
  stats = ctx.call("adblock-stats", tab=tab)
  check(stats["blocked"] >= 1, f"no blocked request counted: {stats}")
  ctx.snapshot("adblock-blocked")

  # Excluding the site lets the same request through (Site Control path).
  ctx.call("settings-adblock", host="127.0.0.1", excluded=True)
  ctx.call("navigate", tab=tab, url=ctx.fixtures.url("/adpage.html"))
  ctx.call("wait", tab=tab)
  ctx.client.wait_until(
      lambda: ctx.client.eval("window.__adLoaded === true", tab=tab),
      what="ad loads on an excluded site")
  check(ctx.fixtures.count("/ads/banner.js") > before,
        "excluded site's request did not reach the server")
  ctx.call("settings-adblock", host="127.0.0.1", excluded=False)


def suite_sleep(ctx: Context):
  first = ctx.open_page("/page/41.html")
  ctx.call("navigate", tab=first, url=ctx.fixtures.url("/page/42.html"))
  ctx.call("wait", tab=first)
  ctx.open_page("/page/43.html")  # Selecting another tab hides `first`.
  ctx.client.wait_until(
      lambda: ctx.call("engine-sleep", tab=first)["visibility"] != "visible",
      what="first tab hidden")

  captured = ctx.call("engine-sleep", tab=first, op="capture")
  history = captured["history"]
  check(history["entries"] >= 2, f"history entries {history['entries']}")
  check(history["roundTrip"], "OPNH v1 round trip failed")
  check(history["opnhBytes"] > 20, "empty OPNH container")

  frozen = ctx.call("engine-sleep", tab=first, op="freeze")
  check(frozen["ok"] and frozen["frozen"], f"freeze failed: {frozen}")
  thawed = ctx.call("engine-sleep", tab=first, op="unfreeze")
  check(thawed["ok"] and not thawed["frozen"], "unfreeze failed")

  discarded = ctx.call("engine-sleep", tab=first, op="discard")
  check(discarded["ok"] and discarded["discarded"],
        f"discard failed: {discarded}")
  check(ctx.call("tab-state", tab=first)["phase"] == "sleeping",
        "model phase is not sleeping")

  # Selecting it restores in place with its back/forward history.
  ctx.call("select", tab=first)
  ctx.call("wait", tab=first, timeout=30)
  state = ctx.call("tab-state", tab=first)
  check("/page/42.html" in state["url"], "restored page has the wrong URL")
  check(ctx.client.eval("history.length", tab=first) >= 2,
        "history lost across the discard")


def suite_sync(ctx: Context):
  if not ctx.sync_url:
    raise CheckFailed("no SyncServer (use --sync-url or install Node 22+)")
  if ctx.sync:
    health = ctx.sync.health()
    check(health.get("ok") and health.get("service") == "open-sync",
          f"SyncServer health {health}")
  status = ctx.call("sync", op="configure", server=ctx.sync_url)
  check(status["serverUrl"].rstrip("/") == ctx.sync_url.rstrip("/"),
        "server URL not configured")
  email = f"e2e-{uuid.uuid4().hex[:10]}@open.invalid"
  status = ctx.call("sync", op="register", server=ctx.sync_url, email=email,
                    password="correct horse battery staple")
  check(status["signedIn"], f"register failed: {status}")
  status = ctx.call("sync", op="now")
  check(status["signedIn"] and "error" not in status,
        f"sync failed: {status}")
  check(status["revision"] >= 1, f"nothing pushed (revision "
        f"{status['revision']})")
  status = ctx.call("sync", op="logout")
  check(not status["signedIn"], "logout failed")


def suite_webui(ctx: Context):
  settings_tab = ctx.call("open", url="open://settings/")["id"]
  ctx.call("wait", tab=settings_tab, timeout=30)
  state = ctx.call("tab-state", tab=settings_tab)
  check(state["url"].startswith("open://settings"),
        f"address shows {state['url']}")
  snapshot = ctx.client.webui_rpc(settings_tab, "settings.getAll", {})
  check("preferences" in snapshot and snapshot["chromium_version"],
        "settings.getAll shape")
  result = ctx.client.webui_rpc(settings_tab, "settings.setPreference",
                                {"key": "tabs.sleepMode",
                                 "value": "aggressive"})
  check(result["ok"] and
        result["preferences"]["tabs.sleepMode"] == "aggressive",
        "settings.setPreference did not apply")
  with_bad = None
  try:
    ctx.client.webui_rpc(settings_tab, "settings.setPreference",
                         {"key": "no.such.key", "value": 1})
  except OpenError as e:
    with_bad = str(e)
  check(with_bad and "unknown preference" in with_bad,
        "invalid preference was accepted")
  adblock = ctx.client.webui_rpc(settings_tab, "settings.getAdBlockState", {})
  check(len(adblock["lists"]) >= 1, "ad-block catalog missing")
  ctx.snapshot("webui-settings")

  library_tab = ctx.call("open", url="open://library/")["id"]
  ctx.call("wait", tab=library_tab, timeout=30)
  spaces = ctx.client.webui_rpc(library_tab, "library.getSpaces", {})
  check(len(spaces["spaces"]) >= 1, "library.getSpaces empty")
  if "e2e_space" in ctx.notes:
    check(any(s["id"] == ctx.notes["e2e_space"] for s in spaces["spaces"]),
          "library does not list the E2E Space")
  history = ctx.client.wait_until(
      lambda: ctx.client.webui_rpc(library_tab, "library.getHistory",
                                   {"query": "", "limit": 100})["entries"],
      what="history rows")
  check(any("/page/" in e["url"] for e in history),
        "visited fixture pages missing from history")
  archive = ctx.client.webui_rpc(library_tab, "library.getArchive", {})
  check(isinstance(archive["items"], list), "library.getArchive shape")
  ctx.snapshot("webui-library")


def suite_snapshot(ctx: Context):
  path = ctx.snapshot("window-final")
  tabs = ctx.tabs()
  live = next((t for t in tabs if t["loaded"]), None)
  check(live, "no live tab for a page snapshot")
  page_path = os.path.join(ctx.out_dir, "page-final.png")
  ctx.call("select", tab=live["id"])
  ctx.call("snapshot", tab=live["id"], path=page_path)
  width, height = png_size(page_path)
  check(width > 100 and height > 100, "page PNG too small")
  ctx.notes["window_png"] = path


def suite_extensions(ctx: Context):
  result = ctx.call("extensions")
  check(isinstance(result["installed"], list) and
        isinstance(result["actions"], list), "extensions shape")


SUITES: Dict[str, Callable[[Context], None]] = {
    "startup": suite_startup,
    "spaces": suite_spaces,
    "tabs": suite_tabs,
    "split": suite_split,
    "command-bar": suite_command_bar,
    "peek": suite_peek,
    "adblock": suite_adblock,
    "sleep": suite_sleep,
    "sync": suite_sync,
    "webui": suite_webui,
    "extensions": suite_extensions,
    "snapshot": suite_snapshot,
}


# =============================================================================
# Main
# =============================================================================

def main(argv) -> int:
  parser = argparse.ArgumentParser(
      description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument("--binary", help="the built browser (open, open.exe, "
                      "or .app/Contents/MacOS/<name>)")
  parser.add_argument("--only", help="comma-separated suites")
  parser.add_argument("--list", action="store_true", help="list suites")
  parser.add_argument("--out", default=None,
                      help="report and PNG directory (default: a new temp dir)")
  parser.add_argument("--user-data", default=None,
                      help="user data dir (default: fresh temp dir)")
  parser.add_argument("--keep", action="store_true",
                      help="keep the user data dir")
  parser.add_argument("--xvfb", action="store_true",
                      help="force Xvfb (Linux; automatic without $DISPLAY)")
  parser.add_argument("--port", action="store_true",
                      help="loopback TCP instead of AF_UNIX")
  parser.add_argument("--sync-url", help="use a running SyncServer")
  parser.add_argument("--no-sync-server", action="store_true",
                      help="do not start a local SyncServer")
  parser.add_argument("--browser-arg", action="append", default=[],
                      help="extra browser switch (repeatable)")
  options = parser.parse_args(argv)

  if options.list:
    print("\n".join(SUITES))
    return 0
  if not options.binary:
    parser.error("--binary is required")
  binary = os.path.abspath(options.binary)
  if not os.path.exists(binary):
    parser.error(f"{binary} does not exist")
  selected = list(SUITES)
  if options.only:
    selected = [s.strip() for s in options.only.split(",") if s.strip()]
    unknown = [s for s in selected if s not in SUITES]
    if unknown:
      parser.error(f"unknown suites: {', '.join(unknown)}")

  out_dir = options.out or tempfile.mkdtemp(prefix="open-unified-e2e-")
  os.makedirs(out_dir, exist_ok=True)
  user_data = options.user_data or tempfile.mkdtemp(prefix="open-unified-ud-")
  env = dict(os.environ)
  cleanups: List[Callable[[], None]] = []
  report = {"binary": binary, "platform": platform.platform(),
            "started": time.time(), "suites": []}
  exit_code = 0
  try:
    if sys.platform.startswith("linux") and \
        (options.xvfb or not env.get("DISPLAY")):
      xvfb = Xvfb().start()
      cleanups.append(xvfb.stop)
      env["DISPLAY"] = xvfb.display
      report["display"] = f"Xvfb {xvfb.display}"

    fixtures = FixtureServer().start()
    cleanups.append(fixtures.stop)

    sync_proc = None
    sync_url = options.sync_url
    if "sync" in selected and not sync_url and not options.no_sync_server \
        and shutil.which("node"):
      sync_proc = SyncServerProcess(
          tempfile.mkdtemp(prefix="open-sync-e2e-"),
          os.path.join(out_dir, "syncserver.log")).start()
      cleanups.append(sync_proc.stop)
      sync_url = sync_proc.url

    browser = Browser(binary, user_data, os.path.join(out_dir, "browser.log"),
                      options.port, env, options.browser_arg)
    started = time.monotonic()
    browser.start()
    cleanups.append(browser.stop)
    report["startup_s"] = round(time.monotonic() - started, 2)
    ctx = Context(browser, fixtures, out_dir, sync_proc, sync_url)

    for name in selected:
      t0 = time.monotonic()
      entry = {"suite": name}
      try:
        SUITES[name](ctx)
        entry["status"] = "PASS"
      except (CheckFailed, OpenError, TimeoutError, KeyError,
              ConnectionError, OSError) as e:
        entry["status"] = "FAIL"
        entry["error"] = f"{type(e).__name__}: {e}"
        entry["trace"] = traceback.format_exc(limit=4)
        exit_code = 1
        try:
          ctx.snapshot(f"fail-{name}")
        except Exception:  # noqa: BLE001 - best-effort evidence
          pass
      entry["seconds"] = round(time.monotonic() - t0, 2)
      report["suites"].append(entry)
      print(f"{entry['status']:4}  {name:12} {entry['seconds']:7.2f}s"
            + (f"  {entry.get('error')}" if entry["status"] != "PASS" else ""),
            flush=True)
    report["notes"] = {k: v for k, v in ctx.notes.items()
                       if isinstance(v, (str, int, float, list))}
  except Exception as e:  # noqa: BLE001 - harness setup failure
    report["setup_error"] = f"{type(e).__name__}: {e}"
    print(f"SETUP FAILED: {report['setup_error']}", file=sys.stderr)
    exit_code = 2
  finally:
    for cleanup in reversed(cleanups):
      try:
        cleanup()
      except Exception:  # noqa: BLE001
        pass
    report["finished"] = time.time()
    with open(os.path.join(out_dir, "report.json"), "w",
              encoding="utf-8") as f:
      json.dump(report, f, indent=2)
    if not options.keep and not options.user_data:
      shutil.rmtree(user_data, ignore_errors=True)
  passed = sum(1 for s in report["suites"] if s["status"] == "PASS")
  print(f"\n{passed}/{len(report['suites'])} suites passed; report: "
        f"{os.path.join(out_dir, 'report.json')}")
  return exit_code


if __name__ == "__main__":
  sys.exit(main(sys.argv[1:]))
