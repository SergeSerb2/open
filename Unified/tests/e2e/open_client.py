#!/usr/bin/env python3
# Copyright 2026 The Open Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Client for Open Unified's automation channel (docs/automation.md).

One JSON object per line in each direction:

  -> {"id": 1, "cmd": "open", "args": {"url": "https://example.com"}}
  <- {"id": 1, "ok": true, "result": {...}}

Transports, as OpenAutomationServer offers them:
  * AF_UNIX stream socket (Linux, macOS, Windows 10+ with Python 3.12+)
  * 127.0.0.1:<port> TCP with the token from <user data>/automation.token

Library use:

  client = OpenClient.connect(user_data_dir="/tmp/open-e2e")
  client.call("ping")
  tab = client.call("open", url="http://127.0.0.1:8000/")

Command line (key=value args; values that parse as JSON are sent as JSON):

  open_client.py --user-data /tmp/open-e2e ping
  open_client.py --socket /tmp/open-e2e/automation.sock tabs sidebar=true
  open_client.py --port 9222 --user-data /tmp/open-e2e eval js='document.title'
  open_client.py --user-data /tmp/open-e2e raw '{"cmd":"spaces"}'
"""

import argparse
import json
import os
import socket
import sys
import time
from typing import Any, Callable, Dict, Optional, Union


class OpenError(RuntimeError):
  """A command answered with ok: false."""

  def __init__(self, cmd: str, message: str):
    super().__init__(f"{cmd}: {message}")
    self.cmd = cmd
    self.message = message


def default_socket_path(user_data_dir: str) -> str:
  return os.path.join(user_data_dir, "automation.sock")


class OpenClient:
  """A persistent connection; commands run one at a time, in order."""

  def __init__(self, sock: socket.socket, token: Optional[str] = None,
               timeout: float = 120.0):
    self._sock = sock
    self._sock.settimeout(timeout)
    self._token = token
    self._buffer = b""
    self._next_id = 1

  # --- Connecting -----------------------------------------------------------

  @classmethod
  def connect(cls, socket_path: Optional[str] = None,
              port: Optional[int] = None,
              user_data_dir: Optional[str] = None,
              token: Optional[str] = None,
              timeout: float = 120.0) -> "OpenClient":
    if port is None and socket_path is None and user_data_dir:
      port_file = os.path.join(user_data_dir, "automation.port")
      sock_file = default_socket_path(user_data_dir)
      if os.path.exists(port_file) and (
          sys.platform == "win32" or not hasattr(socket, "AF_UNIX") or
          not os.path.exists(sock_file)):
        with open(port_file, encoding="utf-8") as f:
          port = int(f.read().strip())
      else:
        socket_path = sock_file
    if port is not None:
      if token is None and user_data_dir:
        token_file = os.path.join(user_data_dir, "automation.token")
        with open(token_file, encoding="utf-8") as f:
          token = f.read().strip()
        if not token:
          raise ValueError("automation.token is empty")
      sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
      return cls(sock, token=token, timeout=timeout)
    if not socket_path:
      raise ValueError("need socket_path, port or user_data_dir")
    if not hasattr(socket, "AF_UNIX"):
      raise OSError("this Python has no AF_UNIX; use --port")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(socket_path)
    return cls(sock, timeout=timeout)

  @classmethod
  def wait_for(cls, deadline_s: float = 60.0, poll_s: float = 0.25,
               port: Union[int, Callable[[], int], None] = None,
               **connect_args) -> "OpenClient":
    """Connects once the browser listens and answers ping.

    |port| may be a callable (read <user data>/automation.port): it is
    called on every attempt, so a port file that does not exist yet, or is
    being written, is retried instead of failing the run."""
    end = time.monotonic() + deadline_s
    last_error: Optional[BaseException] = None
    timeout = connect_args.pop("timeout", 120.0)
    while time.monotonic() < end:
      client = None
      try:
        resolved = port() if callable(port) else port
        client = cls.connect(timeout=10.0, port=resolved, **connect_args)
        client.call("ping")
        client._sock.settimeout(timeout)
        return client
      except (OSError, OpenError, ValueError, json.JSONDecodeError) as e:
        if client is not None:
          client.close()
        last_error = e
        time.sleep(poll_s)
    raise TimeoutError(f"automation channel not ready: {last_error}")

  def close(self):
    try:
      self._sock.close()
    except OSError:
      pass

  def __enter__(self):
    return self

  def __exit__(self, *exc):
    self.close()

  # --- Protocol -------------------------------------------------------------

  def request(self, cmd: str, args: Optional[Dict[str, Any]] = None,
              timeout: Optional[float] = None) -> Dict[str, Any]:
    """Sends one command; returns the whole response object."""
    message: Dict[str, Any] = {"id": self._next_id, "cmd": cmd,
                               "args": args or {}}
    self._next_id += 1
    if self._token:
      message["token"] = self._token
    previous = self._sock.gettimeout()
    if timeout is not None:
      self._sock.settimeout(timeout)
    try:
      self._sock.sendall((json.dumps(message) + "\n").encode("utf-8"))
      while b"\n" not in self._buffer:
        chunk = self._sock.recv(1 << 20)
        if not chunk:
          raise ConnectionError("automation channel closed")
        self._buffer += chunk
    finally:
      self._sock.settimeout(previous)
    line, self._buffer = self._buffer.split(b"\n", 1)
    response = json.loads(line)
    if response.get("id") != message["id"]:
      raise ConnectionError(f"response id {response.get('id')} for "
                            f"request {message['id']}")
    return response

  def call(self, cmd: str, _timeout: Optional[float] = None, **args) -> Any:
    """Runs a command and returns its result; raises OpenError on failure."""
    response = self.request(cmd, args, timeout=_timeout)
    if not response.get("ok"):
      raise OpenError(cmd, str(response.get("error")))
    return response.get("result")

  # --- Conveniences used by the suites ------------------------------------------

  def wait_until(self, predicate, timeout: float = 30.0,
                 interval: float = 0.2, what: str = "condition"):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
      last = predicate()
      if last:
        return last
      time.sleep(interval)
    raise TimeoutError(f"timed out waiting for {what} (last: {last!r})")

  def eval(self, js: str, tab: Optional[str] = None, world: str = "page"):
    args: Dict[str, Any] = {"js": js, "world": world}
    if tab:
      args["tab"] = tab
    return self.call("eval", **args)

  def webui_rpc(self, tab: str, method: str, payload: Dict[str, Any],
                timeout: float = 30.0) -> Any:
    """Calls an open:// page's open.rpc channel from inside the page
    (chrome.send -> C++ handler -> window.__openRpcResolve), the same path
    the Preact frontend uses."""
    req_id = 900000 + (abs(hash((method, time.monotonic()))) % 90000)
    # bridge.ts installs window.__openRpcResolve lazily (its first RPC, and
    # only while the global is unset). Wait briefly for that, so the hook
    # below wraps the page's handler instead of shadowing it.
    try:
      self.wait_until(
          lambda: self.call(
              "eval", _timeout=10, tab=tab,
              js="typeof window.__openRpcResolve === 'function' || "
                 "window.__openE2EHooked === true"),
          timeout=10, interval=0.1, what="bridge.ts resolver")
    except TimeoutError:
      pass  # A page that has made no RPC yet; the accessor still chains.
    fire_script = """
(() => {
  const id = %d, method = %s, payload = %s;
  window.__openE2ERpc = window.__openE2ERpc || {};
  window.__openE2EIds = window.__openE2EIds || new Set();
  delete window.__openE2ERpc[id];
  if (!window.__openE2EHooked) {
    window.__openE2EHooked = true;
    // Chain, never replace: |inner| is the page's own handler (bridge.ts),
    // whenever it is assigned; E2E ids are answered here, every other id
    // goes to |inner|. While the page has no handler and no E2E call is in
    // flight, the getter stays undefined so bridge.ts still installs its own.
    let inner = window.__openRpcResolve;
    const ids = window.__openE2EIds;
    const route = (requestId, ok, value) => {
      if (ids.has(requestId)) {
        ids.delete(requestId);
        window.__openE2ERpc[requestId] = {ok: !!ok, value};
        return;
      }
      if (typeof inner === 'function') inner(requestId, ok, value);
    };
    Object.defineProperty(window, '__openRpcResolve', {
      configurable: true,
      get() { return (inner || ids.size) ? route : undefined; },
      set(fn) { if (fn !== route) inner = fn; },
    });
  }
  window.__openE2EIds.add(id);
  chrome.send('open.rpc', [id, method, payload]);
  return id;
})()
""" % (req_id, json.dumps(method), json.dumps(payload))
    self.call("eval", _timeout=timeout + 5, tab=tab, js=fire_script)

    def _poll():
      res = self.call(
          "eval", _timeout=10, tab=tab,
          js=f"window.__openE2ERpc && window.__openE2ERpc[{req_id}] || null")
      return res if isinstance(res, dict) else None

    result = self.wait_until(_poll, timeout=timeout, what=f"webui rpc {method}")
    if not isinstance(result, dict) or not result.get("ok"):
      raise OpenError(method, json.dumps(result))
    return result.get("value")


# --- Command line -------------------------------------------------------------

def _parse_value(text: str) -> Any:
  try:
    return json.loads(text)
  except ValueError:
    return text


def main(argv) -> int:
  parser = argparse.ArgumentParser(
      description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument("--socket", help="AF_UNIX socket path")
  parser.add_argument("--port", type=int, help="loopback TCP port")
  parser.add_argument("--user-data",
                      default=os.environ.get("OPEN_USER_DATA"),
                      help="user data dir (socket, port and token files)")
  parser.add_argument("--timeout", type=float, default=120.0)
  parser.add_argument("cmd")
  parser.add_argument("args", nargs="*")
  options = parser.parse_args(argv)

  socket_path = options.socket or os.environ.get("OPEN_AUTOMATION_SOCKET")
  client = OpenClient.connect(socket_path=socket_path, port=options.port,
                              user_data_dir=options.user_data,
                              timeout=options.timeout)
  with client:
    if options.cmd == "raw":
      message = json.loads(options.args[0])
      response = client.request(message.get("cmd", ""),
                                message.get("args", {}))
    else:
      args = {}
      for item in options.args:
        key, sep, value = item.partition("=")
        if not sep:
          parser.error(f"argument {item!r} is not key=value")
        args[key] = _parse_value(value)
      response = client.request(options.cmd, args)
  print(json.dumps(response, indent=2, ensure_ascii=False))
  return 0 if response.get("ok") else 1


if __name__ == "__main__":
  sys.exit(main(sys.argv[1:]))
