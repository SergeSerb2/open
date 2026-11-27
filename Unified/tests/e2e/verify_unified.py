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

def is_windows_binary(binary: str) -> bool:
  return (sys.platform == "win32" or os.name == "nt" or
          binary.lower().endswith(".exe"))


def is_wsl_windows_target(binary: str) -> bool:
  return os.name != "nt" and is_windows_binary(binary)


def to_browser_path(path: str, binary: str) -> str:
  if not is_wsl_windows_target(binary):
    return path
  wslpath = shutil.which("wslpath")
  if not wslpath:
    return path
  try:
    return subprocess.check_output(
        [wslpath, "-w", path], text=True, stderr=subprocess.DEVNULL).strip()
  except (OSError, subprocess.CalledProcessError):
    return path


def from_browser_path(path: str, binary: str) -> str:
  if not is_wsl_windows_target(binary):
    return path
  wslpath = shutil.which("wslpath")
  if not wslpath:
    return path
  try:
    return subprocess.check_output(
        [wslpath, "-u", path], text=True, stderr=subprocess.DEVNULL).strip()
  except (OSError, subprocess.CalledProcessError):
    return path


def same_local_path(a: str, b: str) -> bool:
  try:
    return os.path.samefile(a, b)
  except OSError:
    return (os.path.normcase(os.path.abspath(a)) ==
            os.path.normcase(os.path.abspath(b)))


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
    self._log = None

  def start(self, timeout=60):
    server_dir = os.path.join(REPO_ROOT, "SyncServer")
    entry = os.path.join(server_dir, "dist", "index.js")
    if not os.path.exists(entry):
      npx_cmd = shutil.which("npx")
      npm_cmd = shutil.which("npm")
      if not npx_cmd or not npm_cmd:
        raise RuntimeError("SyncServer/dist is missing and npm/npx is not found")
      subprocess.run([npm_cmd, "ci", "--no-audit", "--no-fund"],
                     cwd=server_dir, check=True)
      subprocess.run([npx_cmd, "--yes", "tsrs", "-p", "tsconfig.json"],
                     cwd=server_dir, check=True)
    node_cmd = shutil.which("node") or "node"
    env = dict(os.environ, OPEN_SYNC_DATA_DIR=self.data_dir,
               OPEN_SYNC_PORT="0", OPEN_SYNC_HOST="127.0.0.1")
    self._log = open(self.log_path, "w", encoding="utf-8")
    popen_kwargs = {}
    if os.name == "nt":
      popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    self.proc = subprocess.Popen(
        [node_cmd, "--no-warnings", entry], cwd=server_dir, env=env,
        stdout=subprocess.PIPE, stderr=self._log, text=True, **popen_kwargs)
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
    try:
      for line in self.proc.stdout:
        if self._log and not self._log.closed:
          self._log.write(line)
    except (OSError, ValueError):
      pass

  def health(self) -> Dict:
    with urllib.request.urlopen(self.url + "/health", timeout=5) as r:
      return json.loads(r.read())

  def stop(self):
    try:
      if self.proc and self.proc.poll() is None:
        self.proc.terminate()
        try:
          self.proc.wait(10)
        except subprocess.TimeoutExpired:
          self.proc.kill()
          self.proc.wait(5)
    finally:
      if self._log and not self._log.closed:
        self._log.close()


class Browser:
  def __init__(self, binary: str, user_data: str, log_path: str,
               use_port: bool, env: Dict[str, str], extra: List[str]):
    self.binary = binary
    self.user_data = user_data
    self.log_path = log_path
    self.use_port = use_port
    self.env = env
    self.extra = extra
    self._windows_target = is_windows_binary(binary)
    self.proc = None
    self._log = None
    self.client: Optional[OpenClient] = None
    self.clean_exit = False

  def command_line(self) -> List[str]:
    browser_ud = to_browser_path(self.user_data, self.binary)
    args = [
        self.binary,
        f"--user-data-dir={browser_ud}",
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
      sock_path = to_browser_path(
          os.path.join(self.user_data, "automation.sock"), self.binary)
      args.append("--automation-socket=" + sock_path)
    if sys.platform == "darwin":
      args.append("--use-mock-keychain")
    if (sys.platform.startswith("linux") and not self._windows_target and
        "DISPLAY" in self.env):
      args.append("--ozone-platform=x11")
    return args + self.extra

  def start(self, timeout=90):
    os.makedirs(self.user_data, exist_ok=True)
    self._log = open(self.log_path, "w", encoding="utf-8")
    popen_kwargs = {}
    if os.name == "nt":
      popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    self.proc = subprocess.Popen(self.command_line(), env=self.env,
                                 stdout=self._log, stderr=subprocess.STDOUT,
                                 **popen_kwargs)
    end = time.monotonic() + timeout
    while time.monotonic() < end:
      if self.proc.poll() is not None:
        raise RuntimeError(f"browser exited ({self.proc.returncode}); "
                           f"see {self.log_path}")
      if self.use_port:
        port_path = os.path.join(self.user_data, "automation.port")
        token_path = os.path.join(self.user_data, "automation.token")
        ready = (os.path.exists(port_path) and os.path.exists(token_path) and
                 os.path.getsize(port_path) > 0 and
                 os.path.getsize(token_path) > 0)
      else:
        ready = os.path.exists(os.path.join(self.user_data, "automation.sock"))
      if ready:
        break
      time.sleep(0.2)
    # The port file is read on every connection attempt (inside wait_for):
    # it may not exist yet, or be half written, when the socket is ready.
    self.client = OpenClient.wait_for(
        deadline_s=max(5.0, end - time.monotonic()),
        user_data_dir=self.user_data,
        port=self._port if self.use_port else None)
    return self

  def _port(self) -> int:
    with open(os.path.join(self.user_data, "automation.port"),
              encoding="utf-8") as f:
      return int(f.read().strip())

  def stop(self):
    try:
      if self.client:
        try:
          self.client.call("quit", _timeout=5)
        except (OSError, OpenError, ConnectionError, TimeoutError):
          pass
        self.client.close()
        self.client = None
      if self.proc:
        try:
          rc = self.proc.wait(20)
          self.clean_exit = (rc == 0)
        except subprocess.TimeoutExpired:
          self.clean_exit = False
          if os.name == "nt":
            try:
              self.proc.send_signal(signal.CTRL_BREAK_EVENT)
            except OSError:
              self.proc.terminate()
          else:
            self.proc.send_signal(signal.SIGTERM)
          try:
            self.proc.wait(10)
          except subprocess.TimeoutExpired:
            if os.name == "nt":
              subprocess.run(
                  ["taskkill", "/F", "/T", "/PID", str(self.proc.pid)],
                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                  check=False)
            self.proc.kill()
            try:
              self.proc.wait(5)
            except subprocess.TimeoutExpired:
              pass
        self.proc = None
    finally:
      if self._log and not self._log.closed:
        self._log.close()


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
    result = self.call("snapshot", path=to_browser_path(path, self.browser.binary))
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
  data_root = from_browser_path(ping["dataRoot"], ctx.browser.binary)
  check(same_local_path(data_root, ctx.browser.user_data),
        f"data root {ping['dataRoot']!r} differs from --user-data-dir "
        f"{ctx.browser.user_data!r}")
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


def wait_peek_loaded(ctx: Context, fragment: str) -> Dict:
  def _loaded():
    state = ctx.call("peek-state")
    return state if (state.get("shown") and not state.get("loading") and
                     fragment in state.get("url", "")) else None
  return ctx.client.wait_until(_loaded, timeout=30, what=f"Peek {fragment}")


def suite_peek(ctx: Context):
  state = ctx.call("peek-open", url=ctx.fixtures.url("/page/31.html"))
  check(state["shown"], "Peek not shown")
  wait_peek_loaded(ctx, "/page/31.html")
  ctx.snapshot("peek")
  state = ctx.call("peek-expand")
  check(not state["shown"], "Peek still shown after expand")
  tab = ctx.client.wait_until(lambda: ctx.tab_by_url("/page/31.html"),
                              what="Peek promoted to a tab")
  ctx.call("wait", tab=tab["id"])
  state = ctx.call("peek-open", url=ctx.fixtures.url("/page/32.html"))
  check(state["shown"], "second Peek not shown")
  check(not ctx.call("peek-close")["shown"], "Peek not closed")

  # Esc takes the topmost overlay first: Command Bar over Peek, then Peek.
  ctx.call("peek-open", url=ctx.fixtures.url("/page/33.html"))
  wait_peek_loaded(ctx, "/page/33.html")
  ctx.call("command-bar", action="open")
  check(ctx.call("command-bar")["shown"], "bar over Peek not shown")
  ctx.call("key", key="escape")
  ctx.client.wait_until(lambda: not ctx.call("command-bar")["shown"],
                        what="Esc closes the Command Bar first")
  check(ctx.call("peek-state")["shown"], "Esc closed Peek under the bar")
  handled = ctx.call("key", key="escape")
  check(handled.get("handled") == "accelerator",
        f"Esc over Peek not an Open accelerator: {handled}")
  ctx.client.wait_until(lambda: not ctx.call("peek-state")["shown"],
                        what="Esc closes Peek")


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
  def _blocked_stats():
    s = ctx.call("adblock-stats", tab=tab)
    return s if s["blocked"] >= 1 else None

  stats = ctx.client.wait_until(_blocked_stats, timeout=5,
                                what="adblock blocked count")
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


WEBUI_HOSTS = ("settings", "library", "boosts", "easel", "note",
               "onboarding", "welcome")

# Mounted Preact root and failed subresources of an open:// page:
# resource timing entries with an error status (or no response at all for a
# same-document asset), stylesheets without a sheet, and broken images.
WEBUI_HEALTH_JS = """
(() => {
  const app = document.getElementById('app');
  const failed = [];
  for (const e of performance.getEntriesByType('resource')) {
    const status = e.responseStatus;
    if (typeof status === 'number' && status >= 400) {
      failed.push(e.name + ' ' + status);
    }
  }
  for (const link of document.querySelectorAll('link[rel=stylesheet]')) {
    if (!link.sheet) failed.push(link.href + ' (stylesheet)');
  }
  for (const img of document.querySelectorAll('img')) {
    if (img.complete && img.src && img.naturalWidth === 0) {
      failed.push(img.src + ' (image)');
    }
  }
  return {mounted: !!app && app.childElementCount > 0,
          children: app ? app.childElementCount : -1,
          failed, url: location.href};
})()
"""


def suite_webui(ctx: Context):
  # Every open:// host serves its bundle: #app mounted, no failed loads.
  for host in WEBUI_HOSTS:
    tab = ctx.call("open", url=f"open://{host}/")["id"]
    ctx.call("wait", tab=tab, timeout=30)
    health = ctx.client.wait_until(
        lambda: (lambda h: h if isinstance(h, dict) and h.get("mounted")
                 else None)(ctx.client.eval(WEBUI_HEALTH_JS, tab=tab)),
        timeout=30, what=f"open://{host} #app mounted")
    check(health["url"].startswith(f"open://{host}") or
          health["url"].startswith(f"chrome://open-{host}"),
          f"open://{host} landed on {health['url']}")
    check(not health["failed"],
          f"open://{host} failed resource loads: {health['failed']}")
    ctx.notes[f"webui_{host}_children"] = health["children"]
    ctx.call("close", tab=tab)

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
  ctx.call("snapshot", tab=live["id"],
           path=to_browser_path(page_path, ctx.browser.binary))
  width, height = png_size(page_path)
  check(width > 100 and height > 100, "page PNG too small")
  ctx.notes["window_png"] = path


def suite_extensions(ctx: Context):
  result = ctx.call("extensions")
  check(isinstance(result["installed"], list) and
        isinstance(result["actions"], list), "extensions shape")


def find_state_with_matches(ctx: Context) -> Dict:
  def _counted():
    state = ctx.call("find-bar")
    return state if state.get("matches", -1) >= 0 else None
  return ctx.client.wait_until(_counted, timeout=15, what="find results")


def suite_find_bar(ctx: Context):
  tab = ctx.open_page("/page/51.html")
  ctx.call("select", tab=tab)
  state = ctx.call("find-bar", action="open", text="marker")
  check(state["shown"], "find bar not shown")
  check(state.get("query") == "marker", f"query {state.get('query')!r}")
  state = find_state_with_matches(ctx)
  check(state["matches"] >= 1, f"no match for 'marker': {state}")
  ctx.call("find-bar", action="next")
  check(ctx.call("find-bar")["shown"], "next closed the bar")
  ctx.snapshot("find-bar")

  # Esc closes the bar (an Open accelerator only while the bar shows).
  handled = ctx.call("key", key="escape")
  check(handled.get("handled") == "accelerator", f"Esc: {handled}")
  check(not ctx.call("find-bar")["shown"], "Esc did not close the find bar")

  # Mod+F opens it again with the previous query (Open's accelerator wins
  # over Chromium's IDC_FIND).
  handled = ctx.call("key", key="f", modifiers=["mod"])
  check(handled.get("handled") == "accelerator", f"Mod+F: {handled}")
  state = ctx.call("find-bar")
  check(state["shown"], "Mod+F did not open Open's find bar")
  check(state.get("query") == "marker", "previous query not restored")

  # A query with no match counts 0.
  ctx.call("find-bar", action="open", text="zz-no-such-text-zz")
  ctx.client.wait_until(
      lambda: ctx.call("find-bar").get("matches") == 0,
      timeout=15, what="zero matches")
  ctx.call("find-bar", action="close")
  check(not ctx.call("find-bar")["shown"], "find bar still shown")


def suite_toasts(ctx: Context):
  state = ctx.call("toasts", action="copied-url")
  check(state["shown"] and state["count"] >= 1, f"toast not shown: {state}")
  ctx.snapshot("toast")
  ctx.client.wait_until(lambda: not ctx.call("toasts")["shown"], timeout=20,
                        what="toast auto-dismiss")
  # Copy URL through its shortcut: clipboard write + the same toast.
  tab = ctx.open_page("/page/52.html")
  ctx.call("select", tab=tab)
  handled = ctx.call("key", key="c", modifiers=["mod", "shift"])
  check(handled.get("handled") == "accelerator", f"Copy URL key: {handled}")
  ctx.client.wait_until(lambda: ctx.call("toasts")["shown"], timeout=5,
                        what="Copied URL toast")
  ctx.client.wait_until(lambda: not ctx.call("toasts")["shown"], timeout=20,
                        what="toast auto-dismiss")
  # Closing a Today tab shows "Tab Archived" (with Undo).
  extra = ctx.open_page("/page/53.html")
  ctx.call("close", tab=extra)
  ctx.client.wait_until(lambda: ctx.call("toasts")["shown"], timeout=5,
                        what="Tab Archived toast")


def selected_tab(ctx: Context) -> Optional[str]:
  return next((t["id"] for t in ctx.tabs() if t["selected"]), None)


def suite_tab_switcher(ctx: Context):
  a = ctx.open_page("/page/61.html")
  b = ctx.open_page("/page/62.html")
  ctx.call("select", tab=b)
  check(selected_tab(ctx) == b, "setup: b not selected")
  state = ctx.call("tab-switcher", action="forward")
  check(state["active"], f"switcher not active: {state}")
  check(state["mru"][:2] == [b, a], f"MRU order {state['mru'][:2]}")
  ctx.call("tab-switcher", action="commit")
  ctx.client.wait_until(lambda: selected_tab(ctx) == a,
                        what="switcher commit selects the previous tab")
  check(not ctx.call("tab-switcher")["active"], "switcher still active")
  # Cancel keeps the selection.
  ctx.call("tab-switcher", action="forward")
  ctx.call("tab-switcher", action="cancel")
  check(not ctx.call("tab-switcher")["active"], "cancel left it active")
  check(selected_tab(ctx) == a, "cancel changed the selection")


def live_little_opens(ctx: Context) -> List[Dict]:
  return [w for w in ctx.call("little-open")["windows"]
          if not w.get("closing")]


def suite_little_open(ctx: Context):
  url = ctx.fixtures.url("/page/71.html")
  state = ctx.call("little-open", action="open", url=url)
  check(any("/page/71.html" in w.get("url", "") for w in state["windows"]),
        f"Little Open page not opened: {state}")
  window = ctx.client.wait_until(
      lambda: next((w for w in live_little_opens(ctx)
                    if "/page/71.html" in w.get("url", "") and
                    not w.get("loading")), None),
      timeout=30, what="Little Open page loaded")
  check(window["mode"] == "page", f"mode {window['mode']}")
  ctx.snapshot("little-open")
  ctx.call("little-open", action="open-in-space")
  tab = ctx.client.wait_until(lambda: ctx.tab_by_url("/page/71.html"),
                              what="Open in Space made a tab")
  check(tab["selected"], "the new tab is not selected")
  ctx.client.wait_until(lambda: not live_little_opens(ctx),
                        what="Little Open closed after Open in Space")

  # Bar mode (no URL), then close.
  state = ctx.call("little-open", action="open")
  check(any(w["mode"] == "bar" for w in state["windows"]), "no bar window")
  ctx.call("little-open", action="close")
  ctx.client.wait_until(lambda: not live_little_opens(ctx),
                        what="Little Open bar closed")

  # Air Traffic Control: an external link goes to Little Open (default
  # setting) or to a Space, never nowhere.
  routed = ctx.fixtures.url("/page/72.html")
  ctx.call("little-open", action="route", url=routed)
  ctx.client.wait_until(
      lambda: any("/page/72.html" in w.get("url", "")
                  for w in live_little_opens(ctx)) or
      ctx.tab_by_url("/page/72.html"),
      what="routed external link")
  for _ in live_little_opens(ctx):
    ctx.call("little-open", action="close")


def suite_site_controls(ctx: Context):
  tab = ctx.open_page("/page/81.html")
  ctx.call("select", tab=tab)
  state = ctx.call("site-controls", action="open")
  check(state["shown"], f"Site Control not shown: {state}")
  check(state["host"] == "127.0.0.1", f"host {state['host']}")
  check(state["secure"] is False, "http page reported secure")
  check(isinstance(state["extensions"], list), "extensions shape")
  ctx.snapshot("site-controls")
  ctx.call("site-controls", action="close")
  ctx.client.wait_until(lambda: not ctx.call("site-controls")["shown"],
                        what="Site Control closed")


BOOST_COLOR = "rgb(1, 2, 3)"


def suite_boosts(ctx: Context):
  boosts_tab = ctx.call("open", url="open://boosts/")["id"]
  ctx.call("wait", tab=boosts_tab, timeout=30)
  saved = ctx.client.webui_rpc(boosts_tab, "boosts.save", {"boost": {
      "name": "E2E Boost", "host_pattern": "127.0.0.1", "enabled": True,
      "custom_css": "body { background: %s !important; }" % BOOST_COLOR}})
  boost = saved["boost"]
  check(boost.get("id"), f"saved Boost has no id: {boost}")
  listed = ctx.client.webui_rpc(boosts_tab, "boosts.list", {})["boosts"]
  check(any(b["id"] == boost["id"] for b in listed), "Boost not listed")

  page = ctx.open_page("/page/91.html")
  ctx.client.wait_until(
      lambda: ctx.client.eval(
          "getComputedStyle(document.body).backgroundColor", tab=page) ==
      BOOST_COLOR, timeout=20, what="Boost CSS applied")
  ctx.snapshot("boost-applied")

  # Toggle goes through the store (read-modify-write) and the list reads
  # the store, so both reflect the change.
  toggled = ctx.client.webui_rpc(boosts_tab, "boosts.toggle",
                                 {"id": boost["id"], "enabled": False})
  check(toggled["boost"]["enabled"] is False, f"toggle reply {toggled}")
  listed = ctx.client.webui_rpc(boosts_tab, "boosts.list", {})["boosts"]
  check(any(b["id"] == boost["id"] and b["enabled"] is False for b in listed),
        "toggle not stored")
  ctx.call("navigate", tab=page, url=ctx.fixtures.url("/page/91.html"))
  ctx.call("wait", tab=page)
  ctx.client.wait_until(
      lambda: ctx.client.eval(
          "getComputedStyle(document.body).backgroundColor", tab=page) !=
      BOOST_COLOR, timeout=20, what="disabled Boost not applied")
  ctx.client.webui_rpc(boosts_tab, "boosts.delete", {"id": boost["id"]})
  listed = ctx.client.webui_rpc(boosts_tab, "boosts.list", {})["boosts"]
  check(not any(b["id"] == boost["id"] for b in listed), "Boost not deleted")


def _collect_sidebar_nodes(nodes: List[Dict], out: Dict[str, Dict]):
  """Recursively indexes SidebarNodeToValue trees by node/tab/pane id."""
  for node in nodes:
    kind = node.get("kind")
    nid = node.get("id")
    check(isinstance(nid, str) and len(nid) > 0,
          f"corrupted empty-id sidebar node: {node}")
    if kind == "tab":
      check(isinstance(node.get("url"), str) and len(node["url"]) > 0,
            f"empty url on tab {nid}: {node}")
      check(isinstance(node.get("title"), str) and len(node["title"]) > 0,
            f"empty title on tab {nid}: {node}")
      out[nid] = {"kind": "tab", "url": node["url"], "title": node["title"]}
    elif kind == "folder":
      check(isinstance(node.get("title"), str) and len(node["title"]) > 0,
            f"empty title on folder {nid}: {node}")
      children = node.get("children") or []
      out[nid] = {"kind": "folder", "title": node["title"],
                  "child_ids": [c.get("id") for c in children]}
      _collect_sidebar_nodes(children, out)
    elif kind == "split":
      panes = node.get("panes") or []
      check(len(panes) >= 2, f"split {nid} has fewer than 2 panes: {node}")
      out[nid] = {"kind": "split", "pane_ids": [p.get("id") for p in panes]}
      for pane in panes:
        pid = pane.get("id")
        check(isinstance(pid, str) and len(pid) > 0,
              f"corrupted empty-id split pane in {nid}: {pane}")
        check(isinstance(pane.get("url"), str) and len(pane["url"]) > 0,
              f"empty url on split pane {pid}: {pane}")
        check(isinstance(pane.get("title"), str) and len(pane["title"]) > 0,
              f"empty title on split pane {pid}: {pane}")
        out[pid] = {"kind": "pane", "url": pane["url"], "title": pane["title"]}


def _scan_browser_json_nodes(nodes: List[Dict], found_ids: set,
                             empty_shells: List[Dict]):
  """Recursively scans SnapshotStore-encoded SidebarNodes in browser.json."""
  for wrapped in nodes:
    if not isinstance(wrapped, dict):
      continue
    if "tab" in wrapped:
      tab = (wrapped.get("tab") or {}).get("_0") or {}
      tid = tab.get("id")
      if not isinstance(tid, str) or not tid:
        empty_shells.append(tab)
      else:
        found_ids.add(tid)
    elif "folder" in wrapped:
      folder = (wrapped.get("folder") or {}).get("_0") or {}
      fid = folder.get("id")
      if not isinstance(fid, str) or not fid:
        empty_shells.append(folder)
      else:
        found_ids.add(fid)
      _scan_browser_json_nodes(folder.get("children") or [],
                               found_ids, empty_shells)
    elif "split" in wrapped:
      split = (wrapped.get("split") or {}).get("_0") or {}
      sid = split.get("id")
      if not isinstance(sid, str) or not sid:
        empty_shells.append(split)
      else:
        found_ids.add(sid)
      for pane in split.get("panes") or []:
        pid = pane.get("id") if isinstance(pane, dict) else None
        if not isinstance(pid, str) or not pid:
          empty_shells.append(pane)
        else:
          found_ids.add(pid)


def _load_browser_json(user_data: str) -> Dict:
  path = os.path.join(user_data, "State", "browser.json")
  check(os.path.exists(path), f"{path} does not exist")
  with open(path, encoding="utf-8") as f:
    data = json.load(f)
  check(isinstance(data, dict), "browser.json root is not an object")
  return data


def _audit_browser_json_tabs(data: Dict):
  found_ids = set()
  empty_shells: List[Dict] = []
  for prof in data.get("profiles") or []:
    _scan_browser_json_nodes(prof.get("favorites") or [],
                             found_ids, empty_shells)
  for space in data.get("spaces") or []:
    _scan_browser_json_nodes(space.get("pinned") or [],
                             found_ids, empty_shells)
    _scan_browser_json_nodes(space.get("today") or [],
                             found_ids, empty_shells)
  return found_ids, empty_shells


def verify_clean_exit_browser_json(user_data: str):
  """Verifies persisted State/browser.json after a clean browser shutdown."""
  data = _load_browser_json(user_data)
  windows = data.get("windows")
  check(isinstance(windows, list) and len(windows) >= 1,
        f"browser.json windows array missing or empty after clean shutdown: "
        f"{windows!r}")
  space_ids = {s.get("id") for s in (data.get("spaces") or [])
               if isinstance(s, dict) and s.get("id")}
  valid_win = False
  for win in windows:
    if not isinstance(win, dict):
      continue
    wid = win.get("id")
    focused_space = win.get("focusedSpaceID")
    sidebar_width = win.get("sidebarWidth")
    check(isinstance(wid, str) and len(wid) > 0,
          f"saved window has empty id: {win}")
    check(isinstance(focused_space, str) and focused_space in space_ids,
          f"saved window focusedSpaceID {focused_space!r} not in spaces")
    check(isinstance(sidebar_width, (int, float)) and
          164.0 <= float(sidebar_width) <= 500.0,
          f"saved window sidebarWidth invalid: {sidebar_width!r}")
    valid_win = True
  check(valid_win, "no valid saved window entry in browser.json")
  _, empty_shells = _audit_browser_json_tabs(data)
  check(not empty_shells,
        f"browser.json contains empty-ID tab shells after shutdown: "
        f"{empty_shells}")


def suite_regression_core_and_chrome(ctx: Context):
  spaces_initial = ctx.call("spaces")
  focused_initial = next(s["id"] for s in spaces_initial if s["focused"])

  # --- 1. Auto-archive sweep data integrity (P0 SweepExpiredList) ------------
  reg_space = ctx.call("space-create", title="E2E Regression")["id"]
  ctx.call("space", space=reg_space)

  solo_a = ctx.open_page("/page/101.html")
  solo_b = ctx.open_page("/page/102.html")
  folder_t1 = ctx.open_page("/page/103.html")
  folder_t2 = ctx.open_page("/page/104.html")
  split_t1 = ctx.open_page("/page/105.html")
  split_t2 = ctx.open_page("/page/106.html")
  all_created_tabs = [solo_a, solo_b, folder_t1, folder_t2, split_t1, split_t2]

  # Ensure model URL and title propagated for every tab before grouping.
  for tid, num in zip(all_created_tabs, (101, 102, 103, 104, 105, 106)):
    ctx.client.wait_until(
        lambda t=tid, n=num: (
            lambda st: st if (f"/page/{n}.html" in st.get("url", "") and
                              st.get("title") == f"Page {n}") else None
        )(ctx.call("tab-state", tab=t)),
        timeout=15, what=f"tab-state for Page {num}")

  folder_res = ctx.call("folder", tabs=[folder_t1, folder_t2],
                        section="today", title="Regression Folder", at=0)
  folder_id = folder_res["folder"]
  check(isinstance(folder_id, str) and len(folder_id) > 0,
        f"folder id empty: {folder_res}")

  ctx.call("select", tab=split_t2)
  split_res = ctx.call("split", tab=split_t2)
  split_id = split_res.get("split")
  check(isinstance(split_id, str) and len(split_id) > 0,
        f"split not created: {split_res}")
  check(len(split_res["node"]["panes"]) == 2,
        f"expected 2 split panes: {split_res}")

  before_rows = ctx.call("tabs", sidebar=True)["rows"]["today"]
  before_index: Dict[str, Dict] = {}
  _collect_sidebar_nodes(before_rows, before_index)
  expected_ids = set(all_created_tabs) | {folder_id, split_id}
  check(expected_ids.issubset(before_index.keys()),
        f"missing pre-sweep ids: {expected_ids - set(before_index.keys())}")

  browser_json_path = os.path.join(ctx.browser.user_data, "State",
                                   "browser.json")
  before_mtime = (os.stat(browser_json_path).st_mtime_ns
                  if os.path.exists(browser_json_path) else 0)

  sweep = ctx.call("auto-archive-sweep")
  check(sweep.get("ok") is True, f"auto-archive-sweep failed: {sweep}")

  after_rows = ctx.call("tabs", sidebar=True)["rows"]["today"]
  after_index: Dict[str, Dict] = {}
  _collect_sidebar_nodes(after_rows, after_index)
  check(after_index == before_index,
        f"auto-archive-sweep mutated/corrupted retained Today nodes: "
        f"before={before_index} after={after_index}")

  # Wait for SnapshotStore debounced save after sweep and audit browser.json.
  def _post_sweep_saved():
    if not os.path.exists(browser_json_path):
      return None
    try:
      st = os.stat(browser_json_path)
      if st.st_mtime_ns <= before_mtime:
        return None
      data = _load_browser_json(ctx.browser.user_data)
    except (OSError, json.JSONDecodeError, CheckFailed):
      return None
    found_ids, empty_shells = _audit_browser_json_tabs(data)
    if expected_ids.issubset(found_ids):
      return (found_ids, empty_shells)
    return None

  _, empty_shells = ctx.client.wait_until(
      _post_sweep_saved, timeout=15, interval=0.25,
      what="post-sweep browser.json save")
  check(not empty_shells,
        f"browser.json has empty-ID tab shells after sweep: {empty_shells}")

  # --- 2. ClearToday retained-item integrity (P0 ClearToday) -----------------
  clear_space = ctx.call("space-create", title="E2E ClearToday")["id"]
  ctx.call("space", space=clear_space)
  only_tab = ctx.open_page("/page/107.html")
  ctx.call("select", tab=only_tab)
  only_state = ctx.client.wait_until(
      lambda: (lambda st: st if ("/page/107.html" in st.get("url", "") and
                                 st.get("title") == "Page 107") else None)(
          ctx.call("tab-state", tab=only_tab)),
      timeout=15, what="only tab state for ClearToday")
  expected_url = only_state["url"]
  expected_title = only_state["title"]

  # Default clear-today keeps the active tab -> 0 removed, no shell corruption.
  cleared_default = ctx.call("clear-today", space=clear_space)
  check(cleared_default.get("removed") == 0,
        f"clear-today removed active tab: {cleared_default}")
  cleared_explicit = ctx.call("clear-today", space=clear_space,
                              keep=[only_tab])
  check(cleared_explicit.get("removed") == 0,
        f"clear-today(keep=[active]) removed retained tab: {cleared_explicit}")

  today_after_clear = ctx.call("tabs", sidebar=True)["rows"]["today"]
  check(len(today_after_clear) == 1,
        f"expected 1 retained tab in Today, got {today_after_clear}")
  kept_node = today_after_clear[0]
  check(kept_node.get("id") == only_tab,
        f"retained tab id corrupted: {kept_node}")
  check(kept_node.get("url") == expected_url,
        f"retained tab url corrupted: {kept_node}")
  check(kept_node.get("title") == expected_title,
        f"retained tab title corrupted: {kept_node}")
  post_clear_state = ctx.call("tab-state", tab=only_tab)
  check(post_clear_state["id"] == only_tab and
        post_clear_state["url"] == expected_url and
        post_clear_state["title"] == expected_title,
        f"tab-state corrupted after ClearToday: {post_clear_state}")

  # --- 3. Space theme live propagation (UpdateSpace) -------------------------
  style_a = {
      "math_version": 1,
      "key_color": {"r": 0.15, "g": 0.65, "b": 0.90, "a": 1},
      "color_count": 2, "wheel": "analogous", "appearance": "light",
      "noise_factor": 0.2, "texture": "sand", "intensity_factor": 0.7,
  }
  theme_a = ctx.call("space-theme", space=clear_space, style=style_a)
  check(abs(theme_a["style"]["key_color"]["r"] - 0.15) < 1e-6 and
        theme_a["style"]["appearance"] == "light",
        f"first space-theme did not apply: {theme_a}")

  style_b = {
      "math_version": 1,
      "key_color": {"r": 0.88, "g": 0.22, "b": 0.55, "a": 1},
      "color_count": 2, "wheel": "complementary", "appearance": "dark",
      "noise_factor": 0.4, "texture": "grain", "intensity_factor": 0.85,
  }
  theme_b = ctx.call("space-theme", space=clear_space, style=style_b)
  check(abs(theme_b["style"]["key_color"]["r"] - 0.88) < 1e-6 and
        theme_b["style"]["wheel"] == "complementary" and
        theme_b["style"]["appearance"] == "dark",
        f"second space-theme did not update: {theme_b}")
  spaces_now = {s["id"]: s for s in ctx.call("spaces")}
  stored_style = spaces_now[clear_space]["theme"]["style"]
  check(abs(stored_style["key_color"]["r"] - 0.88) < 1e-6 and
        abs(stored_style["key_color"]["b"] - 0.55) < 1e-6 and
        stored_style["appearance"] == "dark",
        f"updated Space theme stale in spaces readback: {stored_style}")
  ctx.snapshot("regression-space-theme")

  # --- 4. Overlay non-blocking visibility (OverlayWidgetHost) ----------------
  # Exercise Command Bar, Find Bar, and Tab Switcher open/close cycles and
  # verify no overlay remains visible or blocks subsequent tab navigation.
  cb = ctx.call("command-bar", action="open", text="regression")
  check(cb["shown"], "command bar failed to open")
  cb = ctx.call("command-bar", action="close")
  check(not cb["shown"], "command bar stayed shown after close")

  fb = ctx.call("find-bar", action="open", text="marker")
  check(fb["shown"], "find bar failed to open")
  fb = ctx.call("find-bar", action="close")
  check(not fb["shown"], "find bar stayed shown after close")

  ctx.call("tab-switcher", action="forward")
  ctx.call("tab-switcher", action="cancel")
  sw_after = ctx.call("tab-switcher")
  check(not sw_after["active"] and not sw_after.get("shown"),
        f"tab switcher leaked visible: {sw_after}")

  check(not ctx.call("command-bar")["shown"], "command bar leaked visible")
  check(not ctx.call("find-bar")["shown"], "find bar leaked visible")

  # Normal tab creation & navigation remain unblocked after overlay cycles.
  nav_tab = ctx.open_page("/page/108.html")
  ctx.call("navigate", tab=nav_tab, url=ctx.fixtures.url("/page/109.html"))
  ctx.call("wait", tab=nav_tab, timeout=30)
  check("/page/109.html" in ctx.call("tab-state", tab=nav_tab)["url"],
        "navigation blocked after overlay open/close")
  marker = ctx.client.eval("document.getElementById('marker').textContent",
                           tab=nav_tab)
  check(marker == "marker-109", f"unexpected page marker: {marker!r}")

  # --- 5. Secondary window & Incognito independence (P0 MainWindowId) --------
  wins_before = ctx.call("windows")
  main_id = wins_before["mainWindowId"]
  check(isinstance(main_id, str) and len(main_id) > 0,
        f"missing mainWindowId: {wins_before}")
  main_before = next(
      (w for w in wins_before["windows"] if w["id"] == main_id), None)
  check(main_before is not None, f"main window missing: {wins_before}")
  main_space_before = main_before["focusedSpace"]
  main_sel_before = main_before["selectedNode"]

  win2 = ctx.call("windows", action="open", space=reg_space)
  win2_id = win2.get("windowId")
  check(isinstance(win2_id, str) and len(win2_id) > 0 and win2_id != main_id,
        f"secondary window did not get distinct id: {win2}")
  check(win2["mainWindowId"] == main_id,
        f"secondary window changed mainWindowId: {win2}")
  main_after_w2 = next(
      (w for w in win2["windows"] if w["id"] == main_id), None)
  check(main_after_w2 is not None and
        main_after_w2["focusedSpace"] == main_space_before and
        main_after_w2["selectedNode"] == main_sel_before,
        f"secondary window overwrote main window state: "
        f"before={main_before} after={main_after_w2}")
  sec_entry = next(
      (w for w in win2["windows"] if w["id"] == win2_id), None)
  check(sec_entry is not None and sec_entry["incognito"] is False and
        sec_entry["focusedSpace"] == reg_space,
        f"secondary window state wrong: {sec_entry}")
  ctx.call("windows", action="close", window=win2_id)
  ctx.client.wait_until(
      lambda: not any(w["id"] == win2_id
                      for w in ctx.call("windows")["windows"]),
      timeout=15, what="secondary window close")

  inc = ctx.call("windows", action="incognito")
  inc_id = inc.get("windowId")
  check(isinstance(inc_id, str) and len(inc_id) > 0 and inc_id != main_id,
        f"incognito window did not get distinct id: {inc}")
  check(inc["mainWindowId"] == main_id,
        f"incognito window changed mainWindowId: {inc}")
  inc_entry = next(
      (w for w in inc["windows"] if w["id"] == inc_id), None)
  check(inc_entry is not None and inc_entry["incognito"] is True and
        inc_entry["focusedSpace"] != main_space_before,
        f"incognito window did not get its own ephemeral Space: {inc_entry}")
  # Fresh Incognito window has <2 tabs: Tab Switcher must stay hidden/inactive
  # (OverlayWidgetHost regression with <2 tabs).
  sw_inc = ctx.call("tab-switcher", action="forward", window=inc_id)
  check(not sw_inc["active"] and not sw_inc.get("shown"),
        f"tab switcher active/shown with <2 tabs in fresh window: {sw_inc}")
  main_after_inc = next(
      (w for w in inc["windows"] if w["id"] == main_id), None)
  check(main_after_inc is not None and
        main_after_inc["focusedSpace"] == main_space_before and
        main_after_inc["selectedNode"] == main_sel_before,
        f"incognito window overwrote main window state: "
        f"before={main_before} after={main_after_inc}")
  ctx.call("windows", action="close", window=inc_id)
  ctx.client.wait_until(
      lambda: not any(w["id"] == inc_id
                      for w in ctx.call("windows")["windows"]),
      timeout=15, what="incognito window close")

  # Restore initial focused Space for any following suite.
  ctx.call("space", space=focused_initial)
  ctx.notes["regression_verified"] = True


SUITES: Dict[str, Callable[[Context], None]] = {
    "startup": suite_startup,
    "spaces": suite_spaces,
    "tabs": suite_tabs,
    "split": suite_split,
    "command-bar": suite_command_bar,
    "peek": suite_peek,
    "find-bar": suite_find_bar,
    "toasts": suite_toasts,
    "tab-switcher": suite_tab_switcher,
    "little-open": suite_little_open,
    "site-controls": suite_site_controls,
    "adblock": suite_adblock,
    "sleep": suite_sleep,
    "sync": suite_sync,
    "webui": suite_webui,
    "boosts": suite_boosts,
    "extensions": suite_extensions,
    "regression_core_and_chrome": suite_regression_core_and_chrome,
    "snapshot": suite_snapshot,
}


# =============================================================================
# Main
# =============================================================================

def main(argv) -> int:
  parser = argparse.ArgumentParser(
      description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument("--binary", help="the built browser (open, open.exe, "
                      "chrome.exe, or .app/Contents/MacOS/<name>)")
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
                      help="loopback TCP instead of AF_UNIX "
                           "(automatic for Windows .exe binaries)")
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

  win_binary = is_windows_binary(binary)
  use_port = options.port or win_binary

  out_dir = options.out or tempfile.mkdtemp(prefix="open-unified-e2e-")
  os.makedirs(out_dir, exist_ok=True)
  if options.user_data:
    user_data = options.user_data
  else:
    ud_parent = None
    # macOS sun_path is 104 bytes; keep AF_UNIX socket paths short when $TMPDIR is deep.
    if not use_port and os.name != "nt" and os.path.isdir("/tmp"):
      sample = os.path.join(tempfile.gettempdir(), "open-unified-ud-XXXXXXXX",
                            "automation.sock")
      if len(sample.encode("utf-8")) >= 100:
        ud_parent = "/tmp"
    user_data = tempfile.mkdtemp(prefix="open-unified-ud-", dir=ud_parent)
  env = dict(os.environ)
  cleanups: List[Callable[[], None]] = []
  report = {"binary": binary, "platform": platform.platform(),
            "started": time.time(), "suites": []}
  exit_code = 0
  browser: Optional[Browser] = None
  try:
    if sys.platform.startswith("linux") and not win_binary and \
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
                      use_port, env, options.browser_arg)
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
                       if isinstance(v, (str, int, float, list, bool))}
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
    # Session restore & clean exit check: after browser.stop() sends "quit" and
    # the process exits cleanly, State/browser.json must retain a non-empty
    # "windows" array (with focusedSpaceID & sidebarWidth) and zero empty tabs.
    if browser is not None and "regression_core_and_chrome" in selected:
      t0 = time.monotonic()
      entry = {"suite": "clean_exit_browser_json"}
      try:
        check(browser.clean_exit, "browser did not exit cleanly on quit")
        verify_clean_exit_browser_json(user_data)
        entry["status"] = "PASS"
      except (CheckFailed, OSError, json.JSONDecodeError) as e:
        entry["status"] = "FAIL"
        entry["error"] = f"{type(e).__name__}: {e}"
        entry["trace"] = traceback.format_exc(limit=4)
        if exit_code == 0:
          exit_code = 1
      entry["seconds"] = round(time.monotonic() - t0, 2)
      report["suites"].append(entry)
      print(f"{entry['status']:4}  {entry['suite']:12} {entry['seconds']:7.2f}s"
            + (f"  {entry.get('error')}" if entry["status"] != "PASS" else ""),
            flush=True)
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
