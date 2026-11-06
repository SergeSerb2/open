#!/usr/bin/env python3 -I
"""End-to-end checks for OpenEngine and the app shell (docs/engine-spike.md).

Launches the real Open.app with a fresh profile, drives it only through the
automation socket (docs/automation.md), and writes results plus screenshots
of OUR windows to docs/engine-spike/. Nothing here touches other apps or the
system mouse and keyboard.

  tools/e2e/engine_e2e.py --only shell
  tools/e2e/engine_e2e.py --style alloy  --only features
  tools/e2e/engine_e2e.py --style alloy  --only extensions
  tools/e2e/engine_e2e.py --style chrome --only extensions
  tools/e2e/engine_e2e.py --config Release --only measure
  tools/e2e/engine_e2e.py --style chrome --only tabstrip   # fork patch P1
  tools/e2e/engine_e2e.py --style chrome --only sleep      # tab sleep (app-shell Step G)

Extensions are unpacked CRX folders (tools/crx-unpack.py) in
.re/ext/unpacked/{ublock-lite,darkreader,1password,bitwarden}.
"""
import argparse
import atexit
import base64
import ctypes
import json
import math
import glob
import hashlib
import re
import runpy
import os
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "docs", "engine-spike")
_ACTIVE_FOCUS_TRACKER = None
_OWNED_APPS = []

EXT = {
    "ublock": "ddkjiahejlhfcafbddmgiahcphecmpfh",
    "darkreader": "eimadpbcbfnmbkopoojfekhnkhdbieeh",
    "1password": "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
    "bitwarden": "nngceckbapebfimnlniiiahkandclblb",
}
CWS_TEST_ID = "aapbdbdomjkkjkaonfhkkikfgjllcleb"  # Google Translate (MV3)


class FocusInterruption(RuntimeError):
    def __init__(self, message, evidence):
        super().__init__(message)
        self.evidence = evidence


class FocusTracker:
    """Native input and every timed polling/capture interval keep separate trace bounds."""
    def __init__(self):
        self.apps = []
        self.checkpoints = {}
        self.timing_checkpoints = {}
        self.observation_checkpoints = {}

    def loss(self):
        interruptions = []
        for app in self.apps:
            checkpoint = self.checkpoints.get(app.pid, 0)
            steps = app.native_steps[checkpoint:] + [t["start"] for t in app.timing_steps[self.timing_checkpoints.get(app.pid, 0):]]
            if not steps:
                continue
            events = app.activation_trace if app.closed else app.call("activation-events")
            # Untimed pointer/model work may run in the background. Native
            # input and timed intervals both retain their own trace bounds.
            for event in events:
                resigned = event["event"] == "NSApplicationDidResignActiveNotification"
                outside = event["event"] == "frontmostChanged" and event.get("frontmostPID") not in (None, 0, app.pid)
                if event["uptime"] >= min(steps) and (resigned or outside):
                    interruptions.append(dict(event, openPID=app.pid))
        return interruptions

    def checkpoint(self, native_only=False):
        self.checkpoints = {app.pid: len(app.native_steps) for app in self.apps}
        if not native_only:
            self.timing_checkpoints = {app.pid: len(app.timing_steps) for app in self.apps}
            self.observation_checkpoints = {app.pid: len(app.observation_steps) for app in self.apps}

    def begin_timed_poll(self):
        for app in self.apps:
            if not app.closed:
                app.begin_timing("poll interval")


class CheckedResults(dict):
    def __init__(self, tracker):
        super().__init__()
        self.tracker = tracker

    def __setitem__(self, key, value):
        if isinstance(value, dict) and "ok" in value:
            interruptions = self.tracker.loss()
            if interruptions:
                # Retain even a successful assertion as INTERRUPTED. It cannot
                # count as a pass in this attempt. Retry from a fresh fixture,
                # since a dispatched key may already have mutated its state.
                super().__setitem__(key, {"status": "INTERRUPTED", "assertion": value, "focus": interruptions})
                raise FocusInterruption("foreground lost during " + key, interruptions)
            self.tracker.checkpoint()
        super().__setitem__(key, value)


class Open:
    def __init__(self, config, style, user_data, extra_args, log_path, urls=("about:blank",), extra_env=None, delivery_urls=()):
        if os.path.exists(os.path.join(ROOT, ".re", "hold-on-screen")):
            raise RuntimeError("On-screen Open runs are held by the lead (.re/hold-on-screen)")
        self.user_data = user_data
        self.config, self.style = config, style
        self.sock = os.path.join(user_data, "automation.sock")
        bundle_override = (extra_env or {}).get("OPEN_E2E_APP_BUNDLE")
        app = os.path.join(bundle_override or os.path.join(ROOT, "build", config, "Open.app"), "Contents", "MacOS", "Open")
        self.executable = app
        self.bundle = os.path.dirname(os.path.dirname(os.path.dirname(app)))
        activator_source = os.path.join(ROOT, "tools", "e2e", "activate-own-app.swift")
        self.activator = os.path.join(ROOT, ".re", "e2e-tools", "activate-own-app")
        if not os.path.exists(self.activator) or os.path.getmtime(self.activator) < os.path.getmtime(activator_source):
            os.makedirs(os.path.dirname(self.activator), exist_ok=True)
            subprocess.run(["nice", "-n", "10", "xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library",
                            activator_source, "-o", self.activator], check=True)
        counter_source = os.path.join(ROOT, "tools", "e2e", "owned-window-count.swift")
        self.window_counter = os.path.join(ROOT, ".re", "e2e-tools", "owned-window-count")
        if not os.path.exists(self.window_counter) or os.path.getmtime(self.window_counter) < os.path.getmtime(counter_source):
            subprocess.run(["nice", "-n", "10", "xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library",
                            counter_source, "-o", self.window_counter], check=True)
        self.owned_processes = {}
        self.pid = None
        self.launch_waiter_ended_before_automation = False
        self.closed = False
        self.native_steps = []
        self.timing_steps = []
        self.observation_steps = []
        self.activation_trace = []
        self.focus_tracker = None
        env = dict(os.environ, OPEN_USER_DATA=user_data, OPEN_E2E_OWNER_PID=str(os.getpid()))
        env.update(extra_env or {})
        args = [app, "--user-data-dir=" + user_data, "--style=%s" % style] + list(urls) + extra_args
        self.log = open(log_path, "a")
        self.started = time.time()
        # A raw executable launch can have a visible window but no foreground
        # activation grant. Launch the actual bundle through LaunchServices,
        # just as a user does. -W tracks this new instance through app exit.
        self.launch_log_path = log_path + ".launch-%d.log" % time.time_ns()
        # The first-frame timeout fixture also uses open without -W. Its
        # successful early launcher exit must not be mistaken for app exit.
        wait_args = [] if (extra_env or {}).get("OPEN_E2E_NO_LAUNCH_WAIT") == "1" else ["-W"]
        launch = ["/usr/bin/open", "-n"] + wait_args + ["-a", self.bundle] + list(delivery_urls) + [
                  "--stdout", self.launch_log_path, "--stderr", self.launch_log_path]
        for key, value in env.items():
            if key.startswith("OPEN_") or key in (extra_env or {}):
                launch += ["--env", key + "=" + value]
        launch += ["--args"] + args[1:]
        self.proc = subprocess.Popen(launch, stdout=self.log, stderr=subprocess.STDOUT)
        _OWNED_APPS.append(self)
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                self.pid = self.call("ping")["pid"]
                self.discover_owned_processes()
                return
            except (OSError, json.JSONDecodeError):
                time.sleep(0.1)
            if self.proc.poll() is not None:
                # LaunchServices may fail its -W GetProcessPID wait independently
                # of launching the app. Only the real socket establishes readiness.
                self.launch_waiter_ended_before_automation = True
        self.quit()
        raise RuntimeError("Open automation was not ready within 60 s (launcher exit %s); see %s" % (self.proc.returncode, log_path))

    def call(self, cmd, timeout=120, **args):
        if cmd in ("window-close", "popup-close", "quit") or (cmd == "devtools" and args.get("method") == "Page.crash"):
            self.discover_owned_processes()
        foreground_input = cmd in ("key", "focus") or (cmd == "window-focus" and args.get("activate"))
        if cmd in ("space-manager-drag", "sidebar-click", "sidebar-key", "hover"): foreground_input = True
        if foreground_input and self.pid and not self.call("window-state").get("appActive", False):
            # `NSApp.activate()` is a request, not a grant. Renew the explicit
            # foreground request if another app took focus. Address the exact
            # verified PID; a bundle identifier can name another Open worktree.
            activation = subprocess.run([self.activator, str(self.pid), self.executable], capture_output=True, text=True, timeout=10)
            if activation.returncode:
                native = self.call("native-focus-state")
                raise FocusInterruption("Exact-PID activation refused: " + activation.stdout.strip() + " " + activation.stderr.strip(), [native])
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(self.sock)
        s.sendall((json.dumps({"id": 1, "cmd": cmd, "args": args}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        s.close()
        resp = json.loads(buf)
        if resp.get("observationStart", 0) > 0:
            self.observation_steps.append(resp["observationStart"])
            if cmd in ("snapshot", "metrics", "timing"):
                self.timing_steps.append({"start": 0 if cmd == "timing" else resp["observationStart"], "label": cmd})
        if foreground_input and resp.get("nativeInputStart", 0) > 0:
            self.native_steps.append(resp["nativeInputStart"])
        if not resp.get("ok"):
            if foreground_input:
                native = self.call("native-focus-state")
                if not native["active"] or native["frontmostPID"] != self.pid:
                    raise FocusInterruption("%s: %s" % (cmd, resp.get("error")), [native])
            raise RuntimeError("%s: %s" % (cmd, resp.get("error")))
        if cmd == "mouse" and self.focus_tracker:
            # Pointer checks use the tagged virtual pointer and socket state,
            # not application activation. A later native key/capture step
            # establishes its own readiness grant and trace interval.
            self.focus_tracker.checkpoint(native_only=True)
        return resp["result"]

    def begin_timing(self, label):
        if not self.focus_tracker:
            return
        checkpoint = self.focus_tracker.observation_checkpoints.get(self.pid, 0)
        observations = self.observation_steps[checkpoint:]
        start = observations[0] if observations else self.call("native-focus-state")["uptime"]
        self.timing_steps.append({"start": start, "label": label})

    def accept_owned_handoff(self, peer):
        """An intentional control transition establishes the next check's background precondition."""
        deadline = time.monotonic() + 5
        while True:
            state = self.call("native-focus-state")
            events = self.call("activation-events")
            observed = any(e["event"] == "frontmostChanged" and e.get("frontmostPID") == peer.pid for e in events)
            if not state["active"] and state["frontmostPID"] == peer.pid and observed:
                break
            if time.monotonic() >= deadline:
                raise FocusInterruption("owned peer is not the expected foreground process", [state])
            time.sleep(.01)
        if self.focus_tracker:
            self.focus_tracker.checkpoint()

    def eval(self, tab, js, **kw):
        # A page that navigates (or an extension that reloads it) destroys
        # the execution context mid-call; try again on the new document.
        for attempt in range(4):
            try:
                return self.call("eval", tab=tab, js=js, **kw)
            except RuntimeError as e:
                if "context was destroyed" not in str(e) and "Cannot find context" not in str(e) or attempt == 3:
                    raise
                time.sleep(1)

    @staticmethod
    def process_path(pid):
        path = ctypes.create_string_buffer(4096)
        size = ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(pid, path, len(path))
        return os.path.realpath(os.fsdecode(path.value)) if size > 0 else ""

    def discover_owned_processes(self):
        # The unique data-root argument also finds a launch that failed before
        # ping returned its PID. Do not kill by app name or bundle identifier.
        rows = []
        for line in subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True).splitlines():
            fields = line.split()
            if len(fields) == 2:
                rows.append((int(fields[0]), int(fields[1])))
        root_path = os.path.realpath(self.executable)
        owned = set(self.owned_processes)
        if self.pid and self.process_path(self.pid) == root_path:
            owned.add(self.pid)
        if not self.pid:
            for pid, _ in rows:
                if self.process_path(pid) != root_path:
                    continue
                args = subprocess.run(["ps", "-p", str(pid), "-o", "args="], capture_output=True, text=True).stdout
                if "--user-data-dir=" + self.user_data in args:
                    owned.add(pid)
                    self.pid = pid
        for _ in range(16):
            found = {pid for pid, parent in rows if parent in owned}
            if found <= owned:
                break
            owned.update(found)
        bundle = os.path.realpath(self.bundle) + os.sep
        for pid in owned:
            path = self.process_path(pid)
            if path == root_path or path.startswith(bundle):
                self.owned_processes[pid] = path

    def owned_windows(self):
        result = subprocess.run([self.window_counter] + [str(pid) for pid in self.owned_processes],
                                capture_output=True, text=True, timeout=10, check=True)
        return json.loads(result.stdout)

    def log_text(self):
        self.log.flush()
        # LaunchServices writes the live app's stderr to this separate file;
        # quit later appends it to the aggregate log. Read it before quit too.
        # The aggregate may contain an earlier attempt with the same menu
        # command id. A refusal must come from this app instance's stderr.
        paths = [self.launch_log_path]
        return "\n".join(Path(path).read_text(errors="replace") for path in paths if os.path.exists(path))

    def cleanup_surfaces(self):
        for cmd in ("dismiss", "popup-close"):
            try:
                self.call(cmd, timeout=3)
            except Exception:
                pass  # quit's verified-PID kill is the final fallback

    def quit(self):
        if self.closed:
            return
        self.quit_report = {}
        try:
            self.discover_owned_processes()
            self.cleanup_surfaces()
            try:
                self.activation_trace = self.call("activation-events", timeout=3)
            except Exception:
                pass
            try:
                self.quit_report["windows_before_quit"] = self.owned_windows()["count"]
                self.quit_report["reply"] = self.call("quit", timeout=3)
            except Exception as error:
                self.quit_report["error"] = str(error)
        finally:
            def living():
                return [pid for pid, path in self.owned_processes.items() if path and self.process_path(pid) == path]
            deadline = time.monotonic() + 10
            while living() and time.monotonic() < deadline:
                time.sleep(.05)
            remaining = living()
            self.quit_report["forced"] = bool(remaining)
            for pid in remaining:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 5
            while living() and time.monotonic() < deadline:
                time.sleep(.05)
            try:
                self.quit_report["windows_after_quit"] = self.owned_windows()
                self.quit_report["remaining_processes"] = living()
                self.quit_report["ok"] = not living() and self.quit_report["windows_after_quit"]["count"] == 0
            except Exception as error:
                self.quit_report.update(ok=False, cleanup_error=str(error))
            self.quit_report["owned_pids"] = sorted(self.owned_processes)
            try:
                self.proc.wait(2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
            if os.path.exists(self.launch_log_path):
                self.log.write(Path(self.launch_log_path).read_text(errors="replace"))
            self.log.close()
            self.closed = True

    def tab(self, tab_id):
        return [t for t in self.call("tabs") if t["id"] == tab_id][0]

    def foreground_peer(self):
        """Foreground a second, owned Open instance without touching other apps."""
        data = self.user_data + "-b"
        shutil.rmtree(data, ignore_errors=True)
        peer = Open(self.config, self.style, data, ["--use-mock-keychain"], data + ".log", urls=())
        try:
            self.call("yield-activation", pid=peer.pid)
            peer.call("window-focus", id=peer.call("window-state")["id"], activate=True)
            return peer
        except Exception:
            peer.quit()
            raise

    def page(self, tab_id):
        return self.tab(tab_id).get("page", {})


def shot(app, name, window=None, max_px=1100):
    """PNG of one of OUR windows. The main window uses the in-app snapshot
    (includes Chrome-style child windows and real page pixels); other
    windows (panels, Chromium dialogs) use `screencapture -l <our window>`,
    falling back to the in-app snapshot."""
    app.begin_timing("window capture")
    path = os.path.join(OUT, name)
    raw = path + ".raw.png"
    if window is None:
        app.call("snapshot", path=raw)
    else:
        rc = subprocess.call(["screencapture", "-l", str(window), "-o", "-x", raw])
        if rc != 0 or not os.path.exists(raw):
            app.call("snapshot", path=raw, window=window)
    subprocess.call(["sips", "-Z", str(max_px), raw, "--out", path], stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL)
    os.remove(raw)
    return name


def wait_until(fn, timeout=20, step=0.5):
    if _ACTIVE_FOCUS_TRACKER:
        _ACTIVE_FOCUS_TRACKER.begin_timed_poll()
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(step)
    return last


def new_tab(app, url, **kw):
    t = app.call("open", url=url, **kw)
    try:
        app.call("wait", tab=t["id"], timeout=30)
    except RuntimeError:
        pass
    return t["id"]


def frame(f):
    return [float(x) for x in f.replace("{", "").replace("}", "").split(",")]


def wav_data_uri(seconds=2, freq=440, rate=22050):
    n = int(seconds * rate)
    import math
    frames = b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * freq * i / rate))) for i in range(n))
    header = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(frames))
    return "data:audio/wav;base64," + base64.b64encode(header + frames).decode()


# ----------------------------------------------------------------------------
# Extension checks


def extension_checks(app, style, results):
    app.call("ext-prompt", handler=False)
    def ext_list():
        lst = app.call("extensions")
        return lst if len(lst["installed"]) >= 4 else None

    info = wait_until(ext_list, timeout=30) or app.call("extensions")
    exts, actions = info["installed"], info["actions"]
    results["enumerate"] = {
        "ok": len(exts) >= 4 and all(e["enabled"] for e in exts) and len(actions) >= 4
              and all(a["icon"] > 0 for a in actions),
        "extensions": [{k: e[k] for k in ("id", "name", "version", "enabled", "options", "icon")} for e in exts],
        "actions": actions,
    }

    # Extensions open welcome pages as new tabs (at the top of Today, like
    # Arc); use the tab the app started with.
    tabs = app.call("tabs")
    results["welcome_tabs"] = [x["url"] for x in tabs if not x["url"].startswith("https://example.com")]
    t1 = [x for x in tabs if x["url"].startswith("https://example.com")][0]["id"]
    app.call("select", tab=t1)
    app.call("navigate", tab=t1, url="https://en.wikipedia.org/wiki/Web_browser")
    try:
        app.call("wait", tab=t1, timeout=30)
    except RuntimeError:
        pass
    time.sleep(2)

    # MV3 service workers, from the browser-wide DevTools target list.
    targets = app.call("devtools", tab=t1, method="Target.getTargets")["targetInfos"]
    sws = [t for t in targets if t["type"] == "service_worker" and t["url"].startswith("chrome-extension://")]
    results["service_workers"] = {
        "ok": len({t["url"].split("/")[2] for t in sws}) >= 4,
        "workers": sorted(t["url"] for t in sws),
        "all_target_types": sorted({t["type"] for t in targets}),
    }

    # Content scripts: isolated worlds created per extension + Dark Reader DOM.
    app.call("events")
    app.call("devtools", tab=t1, method="Runtime.enable")
    time.sleep(1)
    worlds = sorted({e["params"]["context"].get("name", "") for e in app.call("events")
                     if e.get("method") == "Runtime.executionContextCreated"
                     and e["params"]["context"].get("auxData", {}).get("type") == "isolated"})
    if not worlds:
        # Content scripts injected before Runtime.enable: ask for every context.
        ctx = app.eval(t1, 'chrome && chrome.runtime ? "page sees chrome.runtime" : "ok"')
        worlds = ["(not reported: %s)" % ctx]
    app.call("devtools", tab=t1, method="Runtime.disable")
    dr = app.eval(t1, '({mode: document.documentElement.getAttribute("data-darkreader-mode"),'
                      ' styles: document.querySelectorAll("style.darkreader").length})')
    results["content_scripts"] = {"ok": bool(dr["mode"]) and len(worlds) >= 2, "isolated_worlds": worlds,
                                  "darkreader": dr}
    results["content_scripts"]["screenshot"] = shot(app, "%s-content-script-darkreader.png" % style)

    # declarativeNetRequest (uBlock Origin Lite). Control: a profile with no
    # extensions must load the same URLs.
    probe = ('(async () => { const out = {}; for (const u of ["https://securepubads.g.doubleclick.net/tag/js/gpt.js",'
             ' "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"]) { try { await fetch(u, {mode: "no-cors"});'
             ' out[u] = "loaded"; } catch (e) { out[u] = "blocked"; } } return out; })()')
    # example.com has no CSP (Wikipedia's CSP would block these fetches).
    probe_tab = new_tab(app, "https://example.com/", background=True)
    with_ext = app.eval(probe_tab, probe)
    app.call("close", tab=probe_tab)
    # The control (same URLs loading without extensions) lives in the
    # feature run: adblock_control.
    results["dnr_blocking"] = {"ok": all(v == "blocked" for v in with_ext.values()), "probe": with_ext}

    # Action popups opened from OUR toolbar button, plus chrome.tabs from them.
    has_popup = {a["id"]: a["popup"] for a in app.call("extensions")["actions"]}
    popups = {}
    for name, ext_id in EXT.items():
        info = {}
        try:
            app.call("events")
            if style == "chrome" and not has_popup.get(ext_id, True):
                # No popup for this tab (chrome.action.setPopup({popup: ""});
                # 1Password without an account): as in Chrome, the click
                # fires chrome.action.onClicked. 1Password then opens or
                # selects its welcome tab.
                app.call("ext-run", extension=ext_id)
                opened = wait_until(lambda: [t for t in app.call("tabs") if t["selected"]
                                             and t["url"].startswith("chrome-extension://%s/" % ext_id)], timeout=15)
                info["on_clicked_tab"] = opened and opened[0]["url"]
                info["ok"] = bool(opened)
                popups[name] = info
                continue
            p = app.call("popup", extension=ext_id)["identifier"]
            state_js = ('({elements: document.querySelectorAll("*").length,'
                        ' text: document.body ? document.body.innerText.slice(0, 120) : "",'
                        ' w: innerWidth, h: innerHeight})')
            wait_until(lambda: app.eval(p, state_js, timeout=20)["elements"] > 20, timeout=15)
            time.sleep(1)
            info["state"] = app.eval(p, state_js, timeout=20)
            info["tabs_api"] = app.eval(p, timeout=20, js='(async () => { const r = {}; try {'
                                                 ' r.all = (await chrome.tabs.query({})).map(t => t.url);'
                                                 ' r.active = (await chrome.tabs.query({active: true, currentWindow: true})).map(t => t.url);'
                                                 ' r.windows = (await chrome.windows.getAll()).length;'
                                                 ' r.current = await chrome.windows.getCurrent().then(w => w.id, e => "error: " + e.message);'
                                                 ' } catch (e) { r.error = e.message } return r; })()')
            wins = app.call("windows")
            panel = [w for w in wins if w["visible"] and w["class"] == "NSPanel"]
            if panel:
                info["screenshot"] = shot(app, "%s-popup-%s.png" % (style, name), window=panel[-1]["number"], max_px=800)
            info["ok"] = info["state"]["elements"] > 20
            info["console_errors"] = [e["message"][:200] for e in app.call("events")
                                      if e["type"] == "console" and e.get("content") == p and e.get("level", 0) >= 3][:5]
            app.call("popup-close")
        except Exception as e:
            info["ok"] = False
            info["error"] = str(e)
        popups[name] = info
    results["popups"] = {"ok": all(v.get("ok") for v in popups.values()), "by_extension": popups}

    # Options pages as tabs.
    options = {}
    for e in exts:
        if not e["options"]:
            continue
        t = new_tab(app, e["options"], background=True)
        time.sleep(2)
        try:
            st = app.eval(t, '({elements: document.querySelectorAll("*").length, title: document.title})')
            options[e["name"]] = {"url": e["options"], "elements": st["elements"], "title": st["title"],
                                  "ok": st["elements"] > 20}
            if e["id"] == EXT["darkreader"]:
                app.call("select", tab=t)
                time.sleep(1)
                options[e["name"]]["screenshot"] = shot(app, "%s-options-darkreader.png" % style)
            app.call("close", tab=t)
        except RuntimeError as err:
            # An extension page may close its own tab (window.close()), which
            # Chrome allows; record it instead of stopping the suite.
            still_there = any(x["id"] == t for x in app.call("tabs"))
            options[e["name"]] = {"url": e["options"], "ok": False, "error": str(err),
                                  "tab_still_in_sidebar": still_there}
    results["options_pages"] = {"ok": bool(options) and all(v["ok"] for v in options.values()), "pages": options}

    # chrome://extensions in our web view (style decides: the shell's
    # Extensions menu always uses a Chrome-style page).
    t = new_tab(app, "chrome://extensions")
    count_js = ('(() => { const m = document.querySelector("extensions-manager"); if (!m || !m.shadowRoot) return -1;'
                ' const list = m.shadowRoot.querySelector("extensions-item-list");'
                ' return list && list.shadowRoot ? list.shadowRoot.querySelectorAll("extensions-item").length : -2; })()')
    wait_until(lambda: app.eval(t, count_js) >= 4, timeout=15)
    count = app.eval(t, count_js)
    results["chrome_extensions_page_url"] = app.page(t).get("url")
    results["chrome_extensions_page"] = {"ok": count >= 4, "items": count,
                                         "screenshot": shot(app, "%s-chrome-extensions.png" % style)}
    app.call("close", tab=t)

    # Chrome Web Store install flow.
    results["webstore_install"] = webstore_install(app, style)


def webstore_install(app, style):
    out = {}
    t = new_tab(app, "https://chromewebstore.google.com/detail/%s" % CWS_TEST_ID)
    time.sleep(3)
    before = {w["number"] for w in app.call("windows")}
    try:
        out["button"] = app.eval(t, '(() => { const b = [...document.querySelectorAll("button")].find(b => /add to chrome|'
                                    'remove from chrome/i.test(b.innerText)); return b ? b.innerText : null; })()')
        out["click"] = app.call("click", tab=t, text="^Add to Chrome$")
    except Exception as e:
        out["click_error"] = str(e)
    # Chrome's install prompt is a Views dialog in our process: a sheet on a
    # Chrome-style tab, a free-standing window for an Alloy-style tab.
    new = wait_until(lambda: [w for w in app.call("windows") if w["number"] not in before and w["visible"]
                              and w["class"].startswith("NativeWidget")], timeout=20) or []
    out["new_windows"] = new
    time.sleep(0.5)
    out["screenshot_store"] = shot(app, "%s-webstore-page.png" % style)
    if new:
        d = new[0]
        time.sleep(2)  # let the dialog lay out and draw
        out["screenshot_dialog"] = shot(app, "%s-webstore-dialog.png" % style, window=d["number"], max_px=800)
        # "Add extension" sits 81 pt from the right and 38 pt from the bottom
        # (Chrome's dialog has no default button). In-process click only.
        w, h = [float(x) for x in d["frame"].replace("{", "").replace("}", "").split(",")[2:4]]
        out["dialog_click"] = app.call("mouse", window=d["number"], x=w - 81, y=h - 38)
    installed = wait_until(lambda: any(e["id"] == CWS_TEST_ID for e in app.call("extensions")["installed"]),
                           timeout=25)
    out["installed"] = bool(installed)
    if installed and style == "chrome":
        # A new install is pinned (extensions UI plan Q4; fork patch P2 turns
        # on Chromium's ExtensionsPinnedByDefault).
        out["pinned"] = bool(wait_until(lambda: [x for x in app.call("actions")["actions"]
                                                 if x["id"] == CWS_TEST_ID and x["pinned"]], timeout=10))
    out["windows_after"] = [(w["class"], w["frame"]) for w in app.call("windows") if w["visible"]]
    out["console"] = [e["message"] for e in app.call("events") if e.get("type") == "console"][-5:]
    out["ok"] = bool(installed) and (style != "chrome" or out["pinned"])
    app.call("close", tab=t)
    return out


# ----------------------------------------------------------------------------
# Engine feature checks (no extensions needed)


def feature_checks(app, style, results, tmp):
    t = new_tab(app, "https://en.wikipedia.org/wiki/Web_browser")
    app.call("policy", dialogs="accept", prompt="hello", permissions="grant", contextMenu="record",
             fullscreen="record")

    def run(name, fn):
        try:
            results[name] = fn()
        except Exception as e:
            results[name] = {"ok": False, "error": str(e), "trace": traceback.format_exc()[-600:]}

    def dialogs():
        app.call("events")
        r = app.eval(t, '(() => { alert("a"); return [confirm("c?"), prompt("p?", "d")]; })()')
        ev = [e for e in app.call("events") if e["type"] == "dialog"]
        return {"ok": r == [True, "hello"] and len(ev) == 3, "result": r, "events": [e["kind"] for e in ev]}

    def permissions():
        app.call("events")
        r = app.eval(t, 'Notification.requestPermission()')
        # Geolocation is not exercised: it would trigger the macOS location
        # prompt for the user.
        geo = "not tested"
        ev = [e for e in app.call("events") if e["type"] == "permission"]
        return {"ok": r == "granted" and len(ev) >= 1, "notification": r, "geolocation": geo,
                "events": [{"origin": e["origin"], "kinds": e["kinds"]} for e in ev]}

    def popups_and_new_tabs():
        before = {x["id"] for x in app.call("tabs")}
        app.eval(t, 'void window.open("https://example.org/", "pop", "width=520,height=420")')
        time.sleep(2)
        app.eval(t, '(() => { const a = document.createElement("a"); a.href = "https://example.com/";'
                    ' a.target = "_blank"; a.id = "oe-blank"; a.textContent = "blank"; a.style = "position:fixed;top:10px;left:10px;z-index:99999;background:yellow";'
                    ' document.body.appendChild(a); })()')
        app.call("click", tab=t, selector="#oe-blank")
        time.sleep(2)
        pages = app.call("pages")
        kinds = sorted(p["kind"] for p in pages)
        new_tabs = [x for x in app.call("tabs") if x["id"] not in before]
        for p in pages:
            if p["kind"] == "popup":
                app.call("close", tab=p["identifier"])  # panel closes via Cmd-W path
        for x in new_tabs:
            app.call("close", tab=x["id"])
        app.call("select", tab=t)
        return {"ok": "popup" in kinds and len(new_tabs) == 1 and new_tabs[0]["url"] == "https://example.com/",
                "page_kinds": kinds, "new_sidebar_tabs": [x["url"] for x in new_tabs]}

    def find():
        r = app.call("find", tab=t, text="browser")
        return {"ok": r["matches"] > 10, **r}

    def zoom():
        z = app.call("zoom", tab=t, level=1.0)
        w = app.eval(t, "innerWidth")
        app.call("zoom", tab=t, level=0.0)
        w0 = app.eval(t, "innerWidth")
        return {"ok": abs(z - 1.0) < 0.01 and w < w0, "level": z, "innerWidth_zoomed": w, "innerWidth_100": w0}

    def context_menu():
        app.call("events")
        app.call("rightclick", tab=t, x=300, y=300)
        time.sleep(1)
        ev = [e for e in app.call("events") if e["type"] == "contextMenu"]
        return {"ok": bool(ev), "items": ev[0]["items"] if ev else []}

    def audio():
        app.eval(t, 'window.__oeAudio = new Audio(%s); __oeAudio.loop = true; __oeAudio.play().then(() => "playing")'
                 % json.dumps(wav_data_uri()))
        time.sleep(1)
        st = app.tab(t)
        m = app.call("mute", tab=t, muted=True)
        app.call("mute", tab=t, muted=False)
        app.eval(t, '__oeAudio.pause()')
        time.sleep(0.5)
        after = app.tab(t)
        return {"ok": st["audible"] and m["muted"] and not after["audible"], "audible_while_playing": st["audible"],
                "muted": m, "audible_after_pause": after["audible"]}

    def fullscreen():
        app.call("events")
        app.eval(t, 'document.documentElement.requestFullscreen().then(() => "ok", e => e.message)')
        time.sleep(1)
        ev = [e for e in app.call("events") if e["type"] == "fullscreen"]
        state = app.eval(t, '!!document.fullscreenElement')
        app.call("fullscreen-exit", tab=t)
        time.sleep(1)
        return {"ok": bool(ev) and ev[0]["on"], "events": [e["on"] for e in ev], "document_fullscreen": state}

    def pip():
        v = new_tab(app, "https://example.com/")
        r = app.eval(v, '(async () => { const v = document.createElement("video"); v.muted = true; v.width = 320;'
                        ' v.src = "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.webm";'
                        ' document.body.appendChild(v); await v.play(); await v.requestPictureInPicture();'
                        ' return !!document.pictureInPictureElement; })().catch(e => "error: " + e.message)')
        time.sleep(1.5)
        wins = [w for w in app.call("windows") if w["visible"]]
        app.eval(v, 'document.exitPictureInPicture().then(() => "exited", e => e.message)')
        app.call("close", tab=v)
        app.call("select", tab=t)
        return {"ok": r is True, "result": r, "visible_windows": [(w["class"], w["frame"]) for w in wins]}

    def pdf():
        p = new_tab(app, "https://www.w3.org/WAI/WCAG21/working-examples/pdf-table/table.pdf")
        time.sleep(3)
        info = app.eval(p, '({type: document.contentType, embed: !!document.querySelector("embed"),'
                           ' iframe: !!document.querySelector("iframe"), body: document.body ? document.body.innerHTML.slice(0, 200) : ""})')
        targets = app.call("devtools", tab=p, method="Target.getTargets")["targetInfos"]
        viewer = [x["url"] for x in targets if "mhjfbmdgcfjbbpaeojofohoefgiehjai" in x["url"]]
        name = shot(app, "%s-pdf-viewer.png" % style)
        app.call("close", tab=p)
        app.call("select", tab=t)
        return {"ok": bool(viewer) or info["embed"], "document": info, "viewer_targets": viewer, "screenshot": name}

    def print_to_pdf():
        path = os.path.join(tmp, "print.pdf")
        r = app.call("print-pdf", tab=t, path=path)
        size = os.path.getsize(path) if os.path.exists(path) else 0
        return {"ok": r["ok"] and size > 1000, "bytes": size}

    def download():
        app.call("download-dir", path=tmp)
        app.call("events")
        app.eval(t, '(() => { const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob(["hello open"],'
                    ' {type: "text/plain"})); a.download = "open-download.txt"; a.id = "oe-dl"; a.textContent = "dl";'
                    ' a.style = "position:fixed;top:40px;left:10px;z-index:99999;background:yellow"; document.body.appendChild(a); })()')
        app.call("click", tab=t, selector="#oe-dl")
        ok = wait_until(lambda: os.path.exists(os.path.join(tmp, "open-download.txt")), timeout=10)
        ev = [e for e in app.call("events") if e["type"] == "download"]
        return {"ok": bool(ok), "events": [(e["state"], e["received"]) for e in ev]}

    def user_scripts():
        app.call("script-add", id="boost-css", css=True, source="body { outline: 6px solid rgb(255, 0, 0) !important; }",
                 matches=["*://example.com/*"])
        app.call("script-add", id="boost-js", source="window.__boost = performance.now(); document.documentElement.dataset.boost = 'on';",
                 matches=["*://example.com/*"])
        e = new_tab(app, "https://example.com/")
        r = app.eval(e, '({outline: getComputedStyle(document.body).outlineColor, boost: typeof window.__boost,'
                        ' early: window.__boost < performance.getEntriesByType("navigation")[0].domInteractive,'
                        ' attr: document.documentElement.dataset.boost})')
        o = new_tab(app, "https://example.org/", background=True)
        other = app.eval(o, 'typeof window.__boost')
        app.call("script-remove", id="boost-css")
        app.call("script-remove", id="boost-js")
        app.call("close", tab=e)
        app.call("close", tab=o)
        app.call("select", tab=t)
        return {"ok": r["outline"] == "rgb(255, 0, 0)" and r["early"] and other == "undefined", "matched": r,
                "unmatched_site": other}

    def request_filter():
        f = new_tab(app, "https://example.com/")  # no CSP, unlike Wikipedia
        app.call("filter", block=["example.org"])
        r = app.eval(f, 'fetch("https://example.org/?x=1", {mode: "no-cors"}).then(() => "loaded", () => "blocked")')
        stats = app.call("filter-stats")
        app.call("filter", block=[])
        r2 = app.eval(f, 'fetch("https://example.org/?x=2", {mode: "no-cors"}).then(() => "loaded", () => "blocked")')
        app.call("close", tab=f)
        app.call("select", tab=t)
        return {"ok": r == "blocked" and r2 == "loaded" and stats["blocked"] >= 1, "with_filter": r,
                "without_filter": r2, "stats": stats}

    def profiles():
        a = new_tab(app, "https://example.com/")
        app.eval(a, 'document.cookie = "oe_profile=default; max-age=3600"; localStorage.setItem("oe", "default")')
        home = [x for x in app.call("spaces") if x["focused"]][0]["id"]
        work_space = app.call("space-create", title="Work", profile="Work")
        b = new_tab(app, "https://example.com/")
        r = app.eval(b, '({cookie: document.cookie, storage: localStorage.getItem("oe")})')
        ctx = app.page(b).get("context")
        app.call("close", tab=b)
        app.call("space", space=home)
        app.call("close", tab=a)
        app.call("select", tab=t)
        # The Work profile's engine data lives in Engine/<dir>, a direct child
        # of root_cache_path (docs/plans/profiles.md §6.2).
        engine_dir = os.path.join(app.user_data, "Engine", ctx or "?")
        return {"ok": "oe_profile" not in r["cookie"] and r["storage"] is None and ctx not in (None, "Default")
                      and os.path.isdir(engine_dir),
                "work_profile_sees": r, "work_tab_context": ctx, "work_engine_dir_exists": os.path.isdir(engine_dir),
                "work_space": work_space}

    def adblock_control():
        c = new_tab(app, "https://example.com/")
        r = app.eval(c, '(async () => { const out = {}; for (const u of ["https://securepubads.g.doubleclick.net/tag/js/gpt.js",'
                        ' "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"]) { try { await fetch(u, {mode: "no-cors"});'
                        ' out[u] = "loaded"; } catch (e) { out[u] = "blocked"; } } return out; })()')
        app.call("close", tab=c)
        app.call("select", tab=t)
        return {"ok": all(v == "loaded" for v in r.values()), "without_extensions": r}

    def codecs():
        return {"ok": True, "support": app.eval(t, '({h264: MediaSource.isTypeSupported(\'video/mp4; codecs="avc1.42E01E"\'),'
            ' aac: MediaSource.isTypeSupported(\'audio/mp4; codecs="mp4a.40.2"\'),'
            ' hevc: MediaSource.isTypeSupported(\'video/mp4; codecs="hvc1.1.6.L93.B0"\'),'
            ' vp9: MediaSource.isTypeSupported(\'video/webm; codecs="vp9"\'),'
            ' av1: MediaSource.isTypeSupported(\'video/mp4; codecs="av01.0.05M.08"\'),'
            ' opus: MediaSource.isTypeSupported(\'audio/webm; codecs="opus"\'),'
            ' mp3: document.createElement("audio").canPlayType("audio/mpeg")})')}

    def widevine():
        # Chromium's component updater downloads the CDM (fast-update switch).
        cdm = os.path.join(app.user_data, "Engine", "WidevineCdm")
        got = wait_until(lambda: os.path.isdir(cdm) and os.listdir(cdm), timeout=120, step=2)
        w = new_tab(app, "https://example.com/")
        r = app.eval(w, '(async () => { try { const a = await navigator.requestMediaKeySystemAccess("com.widevine.alpha",'
                        ' [{initDataTypes: ["cenc"], videoCapabilities: [{contentType: \'video/webm; codecs="vp9"\','
                        ' robustness: "SW_SECURE_DECODE"}]}]); await a.createMediaKeys(); return "available: " + a.keySystem;'
                        ' } catch (e) { return "unavailable: " + e.name + " " + e.message; } })()')
        play = None
        if r.startswith("available"):
            play = app.eval(w, '(async () => { const s = document.createElement("script");'
                ' s.src = "https://cdnjs.cloudflare.com/ajax/libs/shaka-player/4.11.7/shaka-player.compiled.js";'
                ' document.head.appendChild(s); await new Promise((r, j) => { s.onload = r; s.onerror = j; });'
                ' shaka.polyfill.installAll(); const v = document.createElement("video"); v.muted = true;'
                ' document.body.appendChild(v); const p = new shaka.Player(); await p.attach(v);'
                ' p.configure({drm: {servers: {"com.widevine.alpha": "https://cwip-shaka-proxy.appspot.com/no_auth"}}});'
                ' try { await p.load("https://storage.googleapis.com/shaka-demo-assets/sintel-widevine/dash.mpd"); }'
                ' catch (e) { return {error: e.code}; } await v.play(); await new Promise(r => setTimeout(r, 5000));'
                ' return {currentTime: v.currentTime, frames: v.getVideoPlaybackQuality().totalVideoFrames,'
                ' keySystem: p.keySystem(), track: p.getVariantTracks().filter(t => t.active).map(t => t.videoCodec)[0]}; })()',
                timeout=90)
        app.call("close", tab=w)
        app.call("select", tab=t)
        return {"ok": r.startswith("available") and bool(play) and play.get("frames", 0) > 30, "eme": r,
                "playback": play, "cdm_versions": sorted(os.listdir(cdm)) if got else None}

    def crash_recovery():
        c = new_tab(app, "https://example.com/", background=True)
        try:
            app.call("navigate", tab=c, url="chrome://crash")
        except Exception:
            pass
        time.sleep(2)
        st = app.page(c).get("crash")
        model_crashed = app.tab(c)["crashed"]
        app.call("navigate", tab=c, url="https://example.com/")
        app.call("wait", tab=c, timeout=20)
        after = app.page(c)
        app.call("close", tab=c)
        return {"ok": st != 0 and model_crashed and after["crash"] == 0 and after["url"] == "https://example.com/",
                "crash_state": st, "model_crashed": model_crashed,
                "after_reload": {"crash": after["crash"], "url": after["url"]}}

    for name, fn in [("js_dialogs", dialogs), ("permissions", permissions), ("popups_new_tabs", popups_and_new_tabs),
                     ("find_in_page", find), ("zoom", zoom),
                     ("context_menu", context_menu), ("audio_state", audio), ("fullscreen", fullscreen),
                     ("picture_in_picture", pip), ("pdf_viewer", pdf), ("print_to_pdf", print_to_pdf),
                     ("downloads", download), ("user_scripts", user_scripts), ("request_filter", request_filter),
                     ("profiles", profiles), ("adblock_control", adblock_control), ("codecs", codecs), ("widevine", widevine), ("crash_recovery", crash_recovery)]:
        run(name, fn)


# ----------------------------------------------------------------------------
# Relaunch soak (section 8 item 14): the Release persistence relaunch once
# aborted in PartitionAlloc's launch-zone race ("No zone found",
# docs/engine-fork.md "PartitionAlloc and the launch race"). Build one
# profile, then relaunch it N times. Every launch must reach automation,
# restore the same tabs, load only the selected one, quit cleanly, write no
# allocator FATAL and leave no new crash report. Local file pages only.

RELAUNCH_COUNT = int(os.environ.get("OPEN_E2E_RELAUNCH_COUNT", "20"))
_CRASH_DIR = os.path.expanduser("~/Library/Logs/DiagnosticReports")


def _open_crash_reports():
    try:
        names = os.listdir(_CRASH_DIR)
    except OSError:
        return set()
    return {n for n in names if n.startswith(("Open", "cefsimple")) and n.endswith((".ips", ".crash"))}


def relaunch_checks(app_factory, results, tmp):
    pages = []
    for name, color in (("a", "#c33"), ("b", "#3c3"), ("c", "#33c")):
        path = os.path.join(tmp, "relaunch-%s.html" % name)
        with open(path, "w") as f:
            f.write("<!doctype html><title>Relaunch %s</title><body style='background:%s'>%s</body>" % (name.upper(), color, name))
        pages.append("file://" + path)
    reports_before = _open_crash_reports()
    app = app_factory(urls=(), fresh=True)
    try:
        ids = [new_tab(app, url) for url in pages]
        app.call("select", tab=ids[0])
        app.call("save")
        expected = [(x["id"], x["section"], x["url"]) for x in app.call("tabs")]
    finally:
        app.quit()
    results["relaunch_fixture"] = {"ok": len(expected) >= 3, "tabs": len(expected)}
    runs, failures = [], []
    for i in range(RELAUNCH_COUNT):
        run = {"index": i + 1, "load": os.getloadavg()[0]}
        started = time.monotonic()
        try:
            app = app_factory(urls=())
        except Exception as error:
            run.update(ok=False, error=str(error))
            runs.append(run); failures.append(run)
            continue
        try:
            run["automation_ms"] = round((time.monotonic() - started) * 1000)
            ready = wait_until(lambda: (lambda t: t if any(x["loaded"] for x in t) else None)(app.call("tabs")), timeout=15, step=.1)
            tabs = ready or app.call("tabs")
            got = [(x["id"], x["section"], x["url"]) for x in tabs]
            loaded = [x["url"] for x in tabs if x["loaded"]]
            run.update(same_tabs=got == expected, loaded=len(loaded), pid=app.pid)
        except Exception as error:
            run.update(error=str(error))
        finally:
            app.quit()
        log_text = ""
        for path in (app.launch_log_path,):
            try:
                log_text += open(path, errors="replace").read()
            except OSError:
                pass
        run["zone_fatal"] = "No zone found" in log_text
        run["quit_ok"] = bool(app.quit_report.get("ok"))
        run["ok"] = (not run.get("error") and run.get("same_tabs") and run.get("loaded") == 1
                     and run["quit_ok"] and not run["zone_fatal"])
        runs.append(run)
        if not run["ok"]:
            failures.append(run)
        print("relaunch %2d/%d %s automation %s ms load %.1f" % (i + 1, RELAUNCH_COUNT, "PASS" if run["ok"] else "FAIL",
                                                                 run.get("automation_ms"), run["load"]), flush=True)
    # Crash reports are written asynchronously by ReportCrash.
    time.sleep(3)
    new_reports = sorted(_open_crash_reports() - reports_before)
    results["relaunch_soak"] = {"ok": not failures and len(runs) == RELAUNCH_COUNT and not new_reports,
                                "count": RELAUNCH_COUNT, "passed": len(runs) - len(failures),
                                "aborts": sum(1 for r in runs if r.get("zone_fatal") or "error" in r),
                                "new_crash_reports": new_reports, "failures": failures, "runs": runs}


# ----------------------------------------------------------------------------
# Shell checks: the M1 window bound to OpenModel


def shell_checks(app_factory, results, tmp):
    """Runs two app sessions on one profile: build state, quit, relaunch."""
    app = app_factory(urls=())
    try:
        results["fresh_model"] = {"ok": True, "tabs": app.call("tabs"), "spaces": app.call("spaces")}
        a = new_tab(app, "https://example.com/")
        b = new_tab(app, "https://example.org/")
        c = new_tab(app, "https://www.iana.org/help/example-domains")
        app.call("pin", tab=a)
        tabs = app.call("tabs")
        order = [x["id"] for x in tabs]
        strip = sorted((x["page"]["browserIndex"], x["id"]) for x in tabs if x.get("page"))
        results["tab_strip_mirror"] = {
            "ok": [i for _, i in strip] == [i for i in order if any(i == s for _, s in strip)]
                  and all(x["page"]["browser"] == tabs[0]["page"]["browser"] for x in tabs if x.get("page")),
            "sidebar": [(x["section"], x["url"]) for x in tabs], "strip": strip}

        # Keyboard: reserved shortcuts win even when the page swallows keys.
        app.call("select", tab=c)
        app.eval(c, 'addEventListener("keydown", e => { e.preventDefault(); e.stopImmediatePropagation(); }, true); 1')
        app.call("focus", tab=c)
        time.sleep(0.3)
        n0 = len(app.call("tabs"))
        route = {}
        app.call("key", key="l", modifiers=["cmd"], route="window")
        ready = state_when(app, lambda st: st["firstResponder"] in ("NSTextView", "CommandBarFieldEditor"))
        route["cmd_l_window"] = ready["firstResponder"] if ready else app.call("window-state")["firstResponder"]
        app.call("key", key="escape")
        time.sleep(.3)
        app.call("focus", tab=c)
        time.sleep(0.2)
        app.call("key", key="t", modifiers=["cmd"])
        ready = state_when(app, lambda st: st["firstResponder"] in ("NSTextView", "CommandBarFieldEditor"))
        route["cmd_t_app"] = ready["firstResponder"] if ready else app.call("window-state")["firstResponder"]
        app.call("key", text="example.net\r")
        time.sleep(2)
        tabs = app.call("tabs")
        new = [x for x in tabs if x["url"].startswith("https://example.net")]
        n1 = len(tabs)
        app.call("focus")
        time.sleep(0.2)
        app.call("key", key="w", modifiers=["cmd"], route="window")
        time.sleep(1)
        n2 = len(app.call("tabs"))
        app.call("key", key="t", modifiers=["cmd", "shift"])
        time.sleep(1.5)
        restored = [x for x in app.call("tabs") if new and x["id"] == new[0]["id"]]
        results["keyboard"] = {
            "ok": route["cmd_l_window"] in ("NSTextView", "CommandBarFieldEditor") and route["cmd_t_app"] in ("NSTextView", "CommandBarFieldEditor")
                  and len(new) == 1 and n1 == n0 + 1 and n2 == n0 and len(restored) == 1,
            "routes": route, "tabs": [n0, n1, n2], "restored_same_id": bool(restored)}

        # Split View: two live pages side by side in one window.
        app.call("select", tab=b)
        panes = app.call("split")
        time.sleep(2)
        pages = [x["page"] for x in app.call("tabs") if x["visible"] and x.get("page")]
        wins = app.call("windows")
        split_png = shot(app, "shell-split-view.png")
        results["split_view"] = {"ok": len(panes) == 2 and len(pages) == 2 and all(p["live"] for p in pages),
                                 "panes": [p["url"] for p in pages], "screenshot": split_png}
        app.call("split")  # unsplit

        # Window PNG from inside the app (no screen-recording permission).
        path = os.path.join(OUT, "shell-window.png")
        snap = app.call("snapshot", path=path)
        results["window_png"] = {"ok": os.path.getsize(path) > 10000, "method": snap["method"],
                                 "file": "shell-window.png"}
        app.call("select", tab=a)
        saved = app.call("save")
        expected = [(x["id"], x["section"], x["url"]) for x in app.call("tabs")]
    finally:
        app.quit()

    # Relaunch: same tabs, same IDs, only the selected tab loads (lazy).
    app = app_factory(urls=())
    try:
        time.sleep(2)
        tabs = app.call("tabs")
        got = [(x["id"], x["section"], x["url"]) for x in tabs]
        loaded = [x["url"] for x in tabs if x["loaded"]]
        results["persistence"] = {"ok": got == expected and len(loaded) == 1 and loaded[0].startswith("https://example.com"),
                                  "snapshot": os.path.relpath(saved, app.user_data) if saved.startswith(app.user_data) else saved,
                                  "tabs": len(got), "loaded_after_launch": loaded}
    finally:
        app.quit()
    shutdown_order_checks(app_factory, results, tmp)


# ----------------------------------------------------------------------------
# Fork patch P1: chrome.tabs / chrome.windows see Open's tabs (run with
# --style chrome). Extensions: the tabs probe fixture and Bitwarden.

PROBE = "ajfcefhgbdgihmnmnjpbejdkclfopicb"  # tools/e2e/fixtures/tabs-probe


def tabstrip_checks(app, results):
    def live():
        """Live sidebar tabs in sidebar row order: (tab, page). With one Space
        this is also the tab-strip order, which the checks compare."""
        return [(t, t["page"]) for t in app.call("tabs") if t.get("page") and t["page"]["live"]]

    def row(tab_id):
        rows = [t for t in app.call("tabs") if t["id"] == tab_id]
        return rows[0] if rows else None

    def chrome_id(tab_id):
        return [p["chromeTabId"] for t, p in live() if t["id"] == tab_id][0]

    # The probe's action popup. A tab switch closes it (Chrome's rule, #93),
    # so `pop` names the popup, and each call reopens it when it is gone.
    pop = "tabs-probe-popup"
    popup_page = {"id": None}

    def probe_popup():
        state = app.call("ext-popup")
        if popup_page["id"] is not None and state.get("open") and state["page"]["identifier"] == popup_page["id"]:
            return popup_page["id"]
        # A popup that is still closing would be closed by running the action
        # again (Chrome's toggle): wait for it to go first.
        wait_until(lambda: not app.call("ext-popup").get("open"), timeout=5, step=0.2)
        page = app.call("popup", extension=PROBE)["identifier"]
        wait_until(lambda: app.eval(page, "window.currentTab !== undefined", timeout=20), timeout=20)
        popup_page["id"] = page
        return page

    def ext_eval(page, js, timeout=20):
        if page != pop:
            return app.eval(page, js, timeout=timeout)
        for attempt in range(3):
            try:
                return app.eval(probe_popup(), js, timeout=timeout)
            except RuntimeError as error:
                # The popup was closing (a tab switch just happened): the page
                # is closed (OEErrorWebContentClosed) or already gone. Reopen
                # it and try again.
                if not ("error 4." in str(error) or "no page for" in str(error)) or attempt == 2:
                    raise
                popup_page["id"] = None

    op_seq = [0]

    def background_op(op, **args):
        """A tab-switching call, run by the probe's background (see
        tabs-probe/background.js); its result from chrome.storage.session."""
        op_seq[0] += 1
        seq = op_seq[0]
        # Fire and forget: the switch closes the popup, so do not wait for the
        # reply. The background ignores a repeated seq (a retried send).
        ext_eval(pop, "chrome.runtime.sendMessage(%s); true" % json.dumps(dict(op=op, seq=seq, **args)))
        return wait_until(lambda: (lambda r: r if r and r.get("seq") == seq else None)(
            ext_eval(pop, "chrome.storage.session.get('lastOp').then(r => r.lastOp || null)")), timeout=15)

    def ext_call(page, js, timeout=20):
        """Runs a promise in the extension page: {ok: value} or {error: message}."""
        return ext_eval(page, "(%s).then(v => ({ok: v === undefined ? null : v}), e => ({error: String(e.message || e)}))"
                        % js, timeout=timeout)

    def events(page):
        return ext_eval(page, "chrome.storage.session.get({events: []}).then(r => r.events)")

    def strip_ids(page):
        return ext_eval(page, "chrome.tabs.query({currentWindow: true}).then(ts => ts.map(t => t.id))")

    def strip_matches_rows(page):
        return strip_ids(page) == [p["chromeTabId"] for _, p in live()]

    wait_until(lambda: any(e["id"] == PROBE for e in app.call("extensions")["installed"]), timeout=30)
    # The live registry can be ready before Bitwarden opens its welcome tab.
    # Finish that install side effect before establishing selected-tab state.
    wait_until(lambda: [t for t in app.call("tabs") if "bitwarden.com" in t["url"]], timeout=15)
    first = next(t["id"] for t in app.call("tabs") if t["url"].startswith("https://example.com"))
    a = new_tab(app, "https://example.org/")
    b = new_tab(app, "https://www.iana.org/help/example-domains")
    app.call("select", tab=first)
    time.sleep(1)

    rows = live()
    results["hosted_tabs"] = {
        "ok": len(rows) >= 3 and all(p["style"] == "chrome" and p["chromeTabId"] > 0 for _, p in rows)
              and len({p["chromeWindowId"] for _, p in rows}) == 1 and rows[0][1]["chromeWindowId"] > 0,
        "tabs": [(t["section"], t["url"], p["chromeTabId"], p["chromeWindowId"]) for t, p in rows]}

    # The action popup (Alloy until P2) asks for the page under it, as
    # Bitwarden's popup does: chrome.tabs.query({active, currentWindow}).
    probe_popup()
    selected = [t for t, _ in rows if t["id"] == first][0]
    expect_id = [p["chromeTabId"] for t, p in rows if t["id"] == first][0]
    q = ext_eval(pop, "chrome.tabs.query({active: true, currentWindow: true})"
                      ".then(ts => ts.map(t => ({id: t.id, url: t.url, windowId: t.windowId})))")
    results["query_active_current_window"] = {
        "ok": len(q) == 1 and q[0]["id"] == expect_id and q[0]["url"].startswith(selected["url"].rstrip("/")),
        "result": q, "expected_tab": expect_id}

    # The strip lists the sidebar rows in row order (not sorted by the
    # engine's own index), with the selected tab active.
    wins = ext_eval(pop, "chrome.windows.getAll({populate: true}).then(ws => ws.map(w => ({id: w.id,"
                         " type: w.type, focused: w.focused, tabs: w.tabs.map(t => ({id: t.id, index: t.index,"
                         " url: t.url, active: t.active, pinned: t.pinned}))})))")
    normal = [w for w in wins if w["type"] == "normal"]
    rows = live()
    results["windows_and_tabs"] = {
        "ok": len(normal) == 1 and normal[0]["id"] == rows[0][1]["chromeWindowId"]
              and [t["id"] for t in normal[0]["tabs"]] == [p["chromeTabId"] for _, p in rows]
              and [t["active"] for t in normal[0]["tabs"]] == [t["id"] == first for t, _ in rows],
        "windows": wins, "sidebar_rows": [(t["id"], p["chromeTabId"]) for t, p in rows],
        "note": "chrome.windows focus state is out of scope for P1 (focused is not asserted)."}

    # onActivated fires when the user switches tabs in Open: a new event
    # after the switch, not one recorded earlier.
    a_id = chrome_id(a)
    seen = len(events(pop))
    app.call("select", tab=a)
    got = wait_until(lambda: [e for e in events(pop)[seen:] if e["type"] == "activated" and e["tabId"] == a_id],
                     timeout=10)
    results["on_activated"] = {"ok": bool(got), "new_events": got, "expected_tab": a_id, "events_before": seen}

    # Per-tab action state follows the selected tab at once (badge set for
    # one tab only must show on that tab, not one switch later).
    b_id = chrome_id(b)
    ext_eval(pop, "Promise.all([chrome.action.setBadgeText({tabId: %d, text: 'A'}),"
                  " chrome.action.setBadgeText({tabId: %d, text: 'B'})]).then(() => true)" % (a_id, b_id))
    def badge():
        acts = [x for x in app.call("extensions")["actions"] if x["id"] == PROBE]
        return acts[0].get("badge") if acts else None
    seen_badges = []
    for tab_id, want in ((b, "B"), (a, "A"), (first, "P1"), (b, "B")):
        app.call("select", tab=tab_id)
        seen_badges.append(wait_until(lambda: badge() if badge() == want else None, timeout=5) or badge())
    results["per_tab_badge"] = {"ok": seen_badges == ["B", "A", "P1", "B"], "badges": seen_badges,
                                "expected": ["B", "A", "P1", "B"]}
    app.call("select", tab=first)

    # chrome.tabs.create makes a Today tab in Open (selected: active true).
    made = background_op("create", props={"url": "https://example.net/?from=extension", "active": True})
    def created():
        for t, p in live():
            if t["url"].startswith("https://example.net/?from=extension") and p["chromeTabId"] == made["id"]:
                return t
    tab = wait_until(created, timeout=15)
    results["tabs_create"] = {
        "ok": bool(tab) and tab["section"] == "today" and tab["visible"]
              and made["windowId"] == live()[0][1]["chromeWindowId"],
        "extension_result": made, "sidebar_tab": tab and {k: tab[k] for k in ("id", "section", "url", "visible")},
        "note": "tabs.create ignores pinned, index and openerTabId (documented P1 gap)."}

    # chrome.tabs.update({active}) selects the tab in Open.
    background_op("activate", tabId=b_id)
    on_b = wait_until(lambda: [t for t, _ in live() if t["id"] == b and t["visible"]], timeout=10)
    results["tabs_update_active"] = {"ok": bool(on_b)}

    # chrome.tabs.move within Today: the shell reorders its sidebar.
    today = [(t, p) for t, p in live() if t["section"] == "today"]
    order_before = [t["id"] for t, _ in today]
    mover, target = today[-1], today[0]
    ext_eval(pop, "chrome.tabs.move(%d, {index: %d}).then(t => t.index)" % (mover[1]["chromeTabId"],
                                                                             target[1]["browserIndex"]))
    def moved():
        ids = [t["id"] for t, _ in live() if t["section"] == "today"]
        return ids if ids and ids[0] == mover[0]["id"] else None
    order_after = wait_until(moved, timeout=10)
    time.sleep(0.5)
    results["tabs_move"] = {"ok": bool(order_after) and strip_matches_rows(pop),
                            "today_before": order_before, "today_after": order_after}

    # Moves must map exactly onto the sidebar: Today [x, Folder(f1, f2), y].
    # Into the folder (between f1 and f2) is refused; before the folder works.
    f1 = new_tab(app, "https://example.com/?f1")
    f2 = new_tab(app, "https://example.com/?f2")
    y = new_tab(app, "https://example.com/?y")
    x = new_tab(app, "https://example.com/?x")
    app.call("folder", tabs=[f1, f2], at=1)
    time.sleep(1)
    def today_ids():
        return [t["id"] for t, _ in live() if t["section"] == "today"]
    rows_before = today_ids()
    strip = strip_ids(pop)
    y_cid, f2_index = chrome_id(y), strip.index(chrome_id(f2))
    into_folder = ext_call(pop, "chrome.tabs.move(%d, {index: %d}).then(t => t.index)" % (y_cid, f2_index))
    time.sleep(1.5)
    refused = today_ids() == rows_before and strip_matches_rows(pop)
    f1_index = strip_ids(pop).index(chrome_id(f1))
    before_folder = ext_call(pop, "chrome.tabs.move(%d, {index: %d}).then(t => t.index)" % (y_cid, f1_index))
    applied = wait_until(lambda: (lambda ids: ids if ids.index(y) == ids.index(f1) - 1 else None)(today_ids()),
                         timeout=10)
    time.sleep(0.5)
    results["tabs_move_exact"] = {
        "ok": refused and bool(applied) and strip_matches_rows(pop),
        "into_folder_result": into_folder, "into_folder_refused": refused,
        "before_folder_result": before_folder, "today_after": applied}

    # chrome.tabs.update({pinned}) pins the tab in Open.
    ext_eval(pop, "chrome.tabs.update(%d, {pinned: true}).then(t => t.pinned)" % a_id)
    pinned = wait_until(lambda: [t for t, _ in live() if t["id"] == a and t["section"] == "pinned"], timeout=10)
    results["tabs_update_pinned"] = {"ok": bool(pinned)}

    # A Favorite is pinned to Chromium; pin and unpin leave it a Favorite.
    fav = new_tab(app, "https://example.com/?favorite")
    app.call("favorite", tab=fav)
    time.sleep(1)
    fav_cid = chrome_id(fav)
    pin_result = ext_call(pop, "chrome.tabs.update(%d, {pinned: true}).then(t => t.pinned)" % fav_cid)
    time.sleep(1)
    after_pin = row(fav)
    unpin_result = ext_call(pop, "chrome.tabs.update(%d, {pinned: false}).then(t => t.pinned)" % fav_cid)
    time.sleep(1.5)
    after_unpin = row(fav)
    fav_tab = ext_eval(pop, "chrome.tabs.get(%d).then(t => ({pinned: t.pinned}))" % fav_cid)
    results["favorite_pin_noop"] = {
        "ok": bool(after_pin) and after_pin["section"] == "favorites" and bool(after_unpin)
              and after_unpin["section"] == "favorites" and fav_tab["pinned"],
        "pin": pin_result, "unpin": unpin_result, "chromium_after": fav_tab,
        "section_after": after_unpin and after_unpin["section"]}

    # Pinned tabs and Favorites follow Cmd-W: chrome.tabs.remove unloads them
    # and they stay in the sidebar (never archived); Today tabs close. Neither
    # is selected here, so no row selection reloads them.
    app.call("select", tab=first)
    time.sleep(0.5)
    removed_pinned = ext_call(pop, "chrome.tabs.remove(%d)" % a_id)
    removed_fav = ext_call(pop, "chrome.tabs.remove(%d)" % fav_cid)
    stays = wait_until(lambda: (lambda ra, rf: (ra, rf) if ra and rf and not ra["loaded"] and not rf["loaded"]
                                else None)(row(a), row(fav)), timeout=10)
    ext_eval(pop, "chrome.tabs.remove(%d).then(() => true)" % made["id"])
    gone = wait_until(lambda: not [t for t in app.call("tabs")
                                   if t["url"].startswith("https://example.net/?from=extension")], timeout=10)
    results["tabs_remove"] = {
        "ok": bool(gone) and bool(stays) and stays[0]["section"] == "pinned" and stays[1]["section"] == "favorites",
        "today_tab_gone_from_sidebar": bool(gone), "pinned_and_favorite_unloaded_in_place": bool(stays),
        "results": [removed_pinned, removed_fav]}

    # chrome.tabs.discard asks Open's sleep controller: a background renderer
    # is discarded in place; the visible tab is refused. The sleeping page
    # object stays until the controller's later destroy deadline.
    bg = f2
    bg_cid = chrome_id(bg)
    discard_initial = []
    def ready_to_discard():
        state = next(iter(app.call("sleep-state", tab=bg).get("tabs", [])), {})
        if not discard_initial: discard_initial.append(state)
        # A recent network commit has the controller's existing 10 s loading
        # grace. Establish an eligible background tab before sending one
        # discard request; a correct refusal during that grace is not failure.
        return state if state.get("content") and state.get("phase") == "live" \
            and state.get("discardGate") is None else None
    discard_ready = wait_until(ready_to_discard, timeout=20)
    discard_bg = ext_call(pop, "chrome.tabs.discard(%d).then(t => ({id: t.id, discarded: t.discarded}))" % bg_cid)
    def discarded_in_place():
        state = app.call("sleep-state", tab=bg)
        tab = next(iter(state.get("tabs", [])), {})
        return tab if tab.get("phase") == "sleeping" and tab.get("discarded") else None
    asleep = wait_until(discarded_in_place, timeout=10)
    chromium_after = ext_call(pop, "chrome.tabs.get(%d).then(t => ({id: t.id, discarded: t.discarded}))" % bg_cid)
    visible = [t for t in app.call("tabs") if t["visible"]][0]
    discard_visible = ext_call(pop, "chrome.tabs.discard(%d)" % visible["page"]["chromeTabId"])
    time.sleep(0.5)
    results["tabs_discard"] = {
        "ok": bool(discard_ready) and "ok" in discard_bg and bool(asleep) and bool(row(bg))
              and chromium_after.get("ok", {}).get("id") == bg_cid and "error" in discard_visible
              and bool(row(visible["id"])) and row(visible["id"])["loaded"],
        "background": discard_bg, "background_sleeping_in_place": bool(asleep),
        "eligible_before_request": discard_ready,
        "initial_eligibility": discard_initial[0] if discard_initial else None,
        "sleep_state": asleep or app.call("sleep-state", tab=bg), "chromium_after": chromium_after,
        "visible": discard_visible,
        "note": "P1 returns discarded:false in desktop chrome.tabs metadata; the engine's renderer-discard flag and sleeping phase prove the discard."}

    # Tabs stay in their Open window: windows.create({tabId}) and moves to
    # or from another window are refused.
    open_window = live()[0][1]["chromeWindowId"]
    some = chrome_id(b)
    create_with_tab = ext_call(pop, "chrome.windows.create({tabId: %d}).then(w => w.id)" % some)
    other = ext_call(pop, "chrome.windows.create({url: 'about:blank', focused: false})"
                          ".then(w => ({id: w.id, tab: w.tabs[0].id}))")
    out_move = into_move = group_here = other_group = group_move_in = None
    strip_before = strip_ids(pop)
    if "ok" in other:
        out_move = ext_call(pop, "chrome.tabs.move(%d, {windowId: %d, index: -1}).then(t => t.windowId)"
                            % (some, other["ok"]["id"]))
        into_move = ext_call(pop, "chrome.tabs.move(%d, {windowId: %d, index: -1}).then(t => t.windowId)"
                             % (other["ok"]["tab"], open_window))
        # Tab groups: none in an Open window, and a group of another window
        # cannot move its tabs into one.
        group_here = ext_call(pop, "chrome.tabs.group({tabIds: [%d]})" % some)
        other_group = ext_call(pop, "chrome.tabs.group({tabIds: [%d]})" % other["ok"]["tab"])
        if "ok" in other_group:
            group_move_in = ext_call(pop, "chrome.tabGroups.move(%d, {windowId: %d, index: -1}).then(g => g.windowId)"
                                     % (other_group["ok"], open_window))
        ext_call(pop, "chrome.windows.remove(%d)" % other["ok"]["id"])
        app.call("dismiss")
    time.sleep(1)
    results["no_cross_window_moves"] = {
        "ok": "error" in create_with_tab and "ok" in other and "error" in out_move and "error" in into_move
              and "error" in group_here
              and ("error" in other_group or (bool(group_move_in) and "error" in group_move_in))
              and bool(row(b)) and row(b)["loaded"] and strip_matches_rows(pop) and strip_ids(pop) == strip_before,
        "windows_create_with_tab": create_with_tab, "chrome_window": other,
        "move_out": out_move, "move_in": into_move, "group_in_open_window": group_here,
        "group_in_chrome_window": other_group, "group_move_in": group_move_in,
        "note": "No window of this build can hold a tab group (Chrome windows from windows.create refuse grouping"
                " too), so tabGroups.move has no group to carry; if one can be made, the move must fail."}

    # The close button of a window.open popup panel closes the page: it
    # leaves chrome.tabs and the opener sees popup.closed.
    app.call("select", tab=first)
    app.eval(first, 'window.__oePopup = window.open("https://example.com/?panel", "oepanel", "width=420,height=320"); 1')
    panel_page = wait_until(lambda: [x for x in app.call("pages") if "?panel" in x["url"] and x["kind"] == "popup"
                                     and x["live"]], timeout=15)
    panel_cid = panel_page[0]["chromeTabId"] if panel_page else -1
    listed_before = panel_cid in strip_ids(pop)
    if panel_page:
        app.call("panel-close", page=panel_page[0]["identifier"])
    gone = wait_until(lambda: panel_cid not in strip_ids(pop)
                      and not [x for x in app.call("pages") if "?panel" in x["url"]], timeout=10)
    closed_in_opener = wait_until(lambda: app.eval(first, "window.__oePopup ? window.__oePopup.closed : null"), timeout=5)
    results["popup_panel_close"] = {"ok": bool(panel_page) and listed_before and bool(gone) and closed_in_opener is True,
                                    "listed_before": listed_before, "gone": bool(gone), "opener_sees_closed": closed_in_opener}

    # chrome.windows.remove on an Open window is a request; v1 refuses it.
    app.call("events")
    live_before = [t["id"] for t, _ in live()]
    remove_window = ext_call(pop, "chrome.windows.remove(%d)" % open_window)
    time.sleep(2)
    window_events = [e for e in app.call("events") if e["type"] == "window-request"]
    results["windows_remove_refused"] = {
        "ok": [t["id"] for t, _ in live()] == live_before and bool(window_events)
              and window_events[0].get("refused") is True,
        "result": remove_window, "events": window_events, "live_tabs": len(live_before)}

    # The mirror is the only owner of strip order: chrome.tabs lists exactly
    # the mirror's tabs, in its order (favorites, every Space's pinned tabs,
    # then every Space's Today tabs).
    def mirror_matches():
        strip = [x for x in app.call("tab-strip") if x["context"] == live()[0][1]["context"]]
        ids = []
        for tab_id in strip[0]["tabs"] if strip else []:
            page = app.call("tab-state", tab=tab_id).get("page") if tab_id else None
            ids.append(page["chromeTabId"] if page else None)
        return ids == strip_ids(pop), ids

    # A tab in a second Space of the same profile: chrome.tabs.update
    # ({active}) focuses that Space and selects it.
    home = [x for x in app.call("spaces") if x["focused"]][0]["id"]
    second = app.call("space-create", title="Second")
    s2 = new_tab(app, "https://example.com/?second-space")
    s2_cid = app.call("tab-state", tab=s2)["page"]["chromeTabId"]
    app.call("space", space=home)
    time.sleep(1)
    in_strip = s2_cid in strip_ids(pop)
    mirror_ok, mirror_ids = mirror_matches()
    background_op("activate", tabId=s2_cid)
    switched = wait_until(lambda: [x for x in app.call("spaces") if x["focused"] and x["id"] == second]
                          and app.call("tab-state", tab=s2)["visible"], timeout=10)
    app.call("space", space=home)
    time.sleep(0.5)
    results["second_space"] = {"ok": in_strip and mirror_ok and bool(switched), "second_space_tab_in_strip": in_strip,
                               "mirror_matches_chrome_tabs": mirror_ok, "mirror": mirror_ids,
                               "activation_switched_space": bool(switched)}

    # A Peek page is Alloy and never a chrome.tabs tab.
    before = strip_ids(pop)
    app.call("peek-open", tab=first, url="https://example.com/?peek")
    peek_page = wait_until(lambda: [x for x in app.call("pages") if "?peek" in x["url"]], timeout=15)
    all_tabs = ext_eval(pop, "chrome.tabs.query({}).then(ts => ts.map(t => t.url || t.pendingUrl))")
    after = strip_ids(pop)
    peek_id = peek_page[0]["identifier"] if peek_page else 0
    # A link with target=_blank in the Peek page opens an ordinary Chrome tab.
    from_peek = None
    if peek_id:
        app.eval(peek_id, '(() => { const a = document.createElement("a"); a.href = "https://example.com/?from-peek";'
                          ' a.target = "_blank"; a.id = "oe-peek-blank"; a.textContent = "blank";'
                          ' a.style = "position:fixed;top:10px;left:10px;z-index:99999;background:yellow";'
                          ' document.body.appendChild(a); return 1; })()')
        app.call("click", tab=peek_id, selector="#oe-peek-blank")
        from_peek = wait_until(lambda: [t for t in app.call("tabs") if "?from-peek" in t["url"]
                                        and t.get("page") and t["page"]["live"]], timeout=15)
    from_peek_page = from_peek[0]["page"] if from_peek else {}
    results["peek_link_opens_chrome_tab"] = {
        "ok": bool(from_peek) and from_peek_page.get("style") == "chrome" and from_peek_page.get("chromeTabId", -1) > 0
              and from_peek_page.get("chromeTabId") in strip_ids(pop),
        "tab": from_peek_page and {k: from_peek_page[k] for k in ("style", "chromeTabId", "url")}}
    app.call("select", tab=first)
    time.sleep(0.5)
    # Expanding a Peek makes it a sidebar tab: a Chrome tab, active in chrome.tabs.
    app.call("peek-open", tab=first, url="https://example.com/?peek-expand")
    wait_until(lambda: [x for x in app.call("pages") if "?peek-expand" in x["url"] and x["live"]], timeout=15)
    app.call("peek-expand")
    promoted = wait_until(lambda: [t for t in app.call("tabs") if "?peek-expand" in t["url"] and t.get("page")
                                   and t["page"]["live"] and t["page"]["style"] == "chrome"], timeout=15)
    active = ext_eval(pop, "chrome.tabs.query({active: true, currentWindow: true}).then(ts => ts.map(t => t.url))")
    results["peek_promoted_is_tab"] = {
        "ok": bool(promoted) and promoted[0]["selected"] and promoted[0]["page"]["chromeTabId"] in strip_ids(pop)
              and len(active) == 1 and "?peek-expand" in active[0],
        "promoted": promoted and {k: promoted[0]["page"][k] for k in ("style", "chromeTabId", "url")},
        "active_in_chrome_tabs": active}
    app.call("select", tab=first)
    app.call("peek-close")
    results["peek_not_a_tab"] = {
        "ok": bool(peek_page) and peek_page[0]["style"] == "alloy" and after == before
              and not any("?peek" in (u or "") for u in all_tabs),
        "peek_page": peek_page and {k: peek_page[0][k] for k in ("style", "url", "kind")},
        "strip_unchanged": after == before,
        "note": "Little Open is not in this shell yet; its pages will follow the same rule (non-model hosts are Alloy)."}

    # Folders are not tab groups (Open v1 decision: no evidence that Arc maps
    # them, docs/re/arccore-engine.md §4.3.1). Open windows have no tab group
    # model (patch 0304): a folder's tabs stay pinned with no group, and the
    # group calls fail with Chrome's own errors.
    folder = app.call("folder", tabs=[b], title="Probe folder", section="pinned")
    def in_folder():
        rows = {t["id"]: p for t, p in live()}
        return rows.get(b) if b in rows else None
    wait_until(in_folder, timeout=10)
    time.sleep(1)
    flags = ext_eval(pop, "chrome.tabs.query({currentWindow: true}).then(ts => ts.map(t => ({id: t.id,"
                          " pinned: t.pinned, groupId: t.groupId})))")
    grouped = ext_eval(pop, "chrome.tabs.group({tabIds: [%d]}).then(g => 'grouped ' + g, e => e.message)" % b_id)
    groups = ext_eval(pop, "chrome.tabGroups.query({}).then(gs => gs.length, e => e.message)")
    ungrouped = ext_eval(pop, "chrome.tabs.ungroup([%d]).then(() => 'ungrouped', e => e.message)" % b_id)
    group_get = ext_eval(pop, "chrome.tabGroups.get(1).then(g => 'group ' + g.id, e => e.message)")
    b_flags = [f for f in flags if f["id"] == b_id]
    results["no_tab_groups"] = {
        "ok": bool(b_flags) and b_flags[0]["pinned"] and all(f["groupId"] == -1 for f in flags)
              and "support" in str(grouped) and groups == 0
              and "support" in str(ungrouped) and "no group" in str(group_get).lower(),
        "folder": folder, "folder_tab": b_flags, "group_call": grouped, "tab_groups": groups,
        "ungroup_call": ungrouped, "tab_groups_get": group_get}

    ev = events(pop)
    results["events_seen"] = sorted({e["type"] for e in ev})
    app.call("popup-close")

    # Badge text set by the probe's service worker reaches the toolbar
    # action snapshot (Chrome's action model through the tab strip).
    app.call("select", tab=first)
    time.sleep(1)
    actions = app.call("extensions")["actions"]
    probe_action = [x for x in actions if x["id"] == PROBE]
    results["badge_text"] = {"ok": bool(probe_action) and probe_action[0].get("badge") == "P1",
                             "action": probe_action}

    # Bitwarden's popup leaves its loading state (its first step asks for
    # the current tab).
    app.call("select", tab=first)
    time.sleep(1)
    info = {}
    try:
        p = app.call("popup", extension=EXT["bitwarden"])["identifier"]
        state_js = ('({elements: document.querySelectorAll("*").length,'
                    ' spinner: !!document.querySelector(".bwi-spinner, app-loading, .loading-container"),'
                    ' inputs: document.querySelectorAll("input").length,'
                    ' text: document.body ? document.body.innerText.slice(0, 160) : ""})')
        state = wait_until(lambda: (lambda s: s if not s["spinner"] and s["elements"] > 50 and s["text"] else None)(
            app.eval(p, state_js, timeout=20)), timeout=30) or app.eval(p, state_js, timeout=20)
        info["state"] = state
        info["tabs_api"] = app.eval(p, "chrome.tabs.query({active: true, currentWindow: true})"
                                       ".then(ts => ts.map(t => t.url))", timeout=20)
        # Bitwarden opens its welcome page on install; the selected tab is
        # whatever Open shows now.
        info["selected_tab"] = [t["url"] for t in app.call("tabs") if t["selected"]]
        wins = app.call("windows")
        panel = [w for w in wins if w["visible"] and w["class"] == "NSPanel"]
        if panel:
            info["screenshot"] = shot(app, "p1-popup-bitwarden.png", window=panel[-1]["number"], max_px=800)
        info["ok"] = (not state["spinner"] and state["elements"] > 50 and bool(state["text"])
                      and info["tabs_api"] == info["selected_tab"])
        info["note"] = ("The popup is narrow: Bitwarden uses its fixed popup width only when"
                        " chrome.extension.getViews({type: 'popup'}) lists it (patch P2).")
        app.call("popup-close")
    except Exception as e:
        info["ok"] = False
        info["error"] = str(e)
    results["bitwarden_popup"] = info
    sleep_engine_checks(app, results, lambda: strip_ids(pop))
    app.call("select", tab=first)
    results["window_screenshot"] = shot(app, "p1-window.png")
    context_menu_commands(app, results)
    new_window_outlives_opener(app, results)


def sleep_engine_checks(app, results, strip_ids):
    """Tab-sleep engine primitives on a hosted tab (memory-fork S1/S4/S5 on
    the shell's real tab path; fork patches 0101/0104/0105 + overlay API).
    Uses the memory-fork fixtures over loopback; prints the load average."""
    import http.server
    import threading
    fixtures = os.path.join(ROOT, "Engine", "fork", "verification", "fixtures")
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=fixtures, **k)

        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d/" % server.server_address[1]
    load = os.getloadavg()

    def sleep_op(tab, op):
        return app.call("engine-sleep", tab=tab, op=op, timeout=30)

    def navigate(tab, name):
        app.eval(tab, "location.href = %s; true" % json.dumps(base + name))
        wait_until(lambda: app.eval(tab, "location.pathname + document.readyState") == "/" + name.split("?")[0] + "complete",
                   timeout=20, step=0.2)

    def renderers():
        rows = [l.split(None, 2) for l in subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True).splitlines()]
        kids = {app.pid}
        for _ in range(6):
            kids |= {int(r[0]) for r in rows if len(r) == 3 and int(r[1]) in kids}
        return sorted(int(r[0]) for r in rows if len(r) == 3 and int(r[0]) in kids and "--type=renderer" in r[2]
                      and "--extension-process" not in r[2])

    selected = [t["id"] for t in app.call("tabs") if t["selected"]][0]
    unload_tab = [None]
    tab = new_tab(app, base + "ticker.html")
    app.call("select", tab=selected)
    time.sleep(1.5)
    try:
        # S1: a background hosted tab is HIDDEN for Chromium (its view is
        # hidden by the shell); setPageHidden goes through patch 0302's hosted
        # path to UpdateWebContentsVisibility.
        state = app.eval(tab, "document.visibilityState")
        sleep_op(tab, "show")
        shown = app.eval(tab, "document.visibilityState")
        sleep_op(tab, "hide")
        hidden = app.eval(tab, "document.visibilityState")
        results["sleep_hosted_visibility"] = {"ok": state == "hidden" and shown == "visible" and hidden == "hidden",
                                              "background": state, "after_show": shown, "after_hide": hidden}
        # S4 freeze: refused while visible; the hidden ticker stops while
        # frozen and runs again after unfreeze.
        app.call("select", tab=tab)
        time.sleep(0.5)
        refused = sleep_op(tab, "freeze")
        app.call("select", tab=selected)
        time.sleep(1.5)
        t0 = app.eval(tab, "ticks")
        frozen = sleep_op(tab, "freeze")
        time.sleep(6)
        during = sleep_op(tab, "state")
        thawed = sleep_op(tab, "unfreeze")
        t1 = app.eval(tab, "ticks")
        time.sleep(3.2)
        t2 = app.eval(tab, "ticks")
        results["sleep_hosted_freeze"] = {
            "ok": refused["ok"] is False and frozen["ok"] and frozen["frozen"] and during["frozen"]
                  and thawed["ok"] and not thawed["frozen"] and t1 - t0 <= 1 and t2 - t1 >= 2,
            "refused_visible": refused, "frozen": frozen, "ticks": [t0, t1, t2], "frozen_seconds": 6,
            "load": load}
        # S5: beforeunload handler flag. Never navigate away from the page
        # with the handler: closing it (force close) shows no dialog.
        without = sleep_op(tab, "state")["unloadHandlers"]
        unload_tab[0] = new_tab(app, base + "c.html?unload=1")
        app.call("select", tab=selected)
        with_handler = wait_until(lambda: sleep_op(unload_tab[0], "state")["unloadHandlers"] or None,
                                  timeout=5, step=0.3)
        results["sleep_hosted_unload_flag"] = {"ok": with_handler is True and without is False,
                                               "with": with_handler, "without_on_ticker": without}
        # S4 discard in place: history a -> b -> c with scroll and form state.
        navigate(tab, "b.html")
        navigate(tab, "c.html")
        app.eval(tab, "scrollTo(0, innerHeight * 2); document.querySelector('#q').value = 'open-sleep-check'; true")
        scroll = app.eval(tab, "scrollY")
        before = sleep_op(tab, "state")
        strip_before = strip_ids()
        procs_before = renderers()
        app.call("select", tab=selected)
        # Blink syncs the hidden page's scroll and form state to the browser
        # within about 5 s (measured: 840 B at 1 s, 1232 B at 6 s); sleep
        # policy discards 30 s or more after a hide.
        time.sleep(6)
        discard = sleep_op(tab, "discard")
        time.sleep(2)
        procs_after = renderers()
        after = sleep_op(tab, "state")
        # Capture after the discard settled: the renderer flushed the page
        # state (scroll, form) while it unloaded; a capture taken right after
        # a hide can miss the last edits (Track A measurement).
        capture = sleep_op(tab, "capture")["history"] or {}
        strip_after = strip_ids()
        again = sleep_op(tab, "discard")
        app.call("select", tab=tab)
        wait_until(lambda: app.eval(tab, "document.readyState") == "complete", timeout=20, step=0.3)
        time.sleep(0.5)
        page = app.eval(tab, "({d: document.wasDiscarded, q: document.querySelector('#q').value, y: scrollY,"
                             " n: history.length, path: location.pathname})")
        reloaded = sleep_op(tab, "state")
        results["sleep_hosted_capture"] = {
            "ok": capture.get("entryCount", 0) >= 3 and capture.get("currentIndex") == capture.get("entryCount", 0) - 1
                  and capture.get("hasPageState") is True and capture.get("title") == "Open history C"
                  and capture.get("roundTrip") is True,
            "history": capture}
        results["sleep_hosted_discard"] = {
            "ok": discard["ok"] is True and after["discarded"] and again["ok"] is True
                  and len(procs_after) < len(procs_before)
                  and page["d"] is True and page["path"] == "/c.html" and page["q"] == "open-sleep-check"
                  and abs(page["y"] - scroll) < 50 and not reloaded["discarded"],
            "renderers": [procs_before, procs_after], "page": page, "scroll_before": scroll, "load": load}
        # The discarded tab keeps its chrome.tabs identity (no replacement
        # WebContents, unlike Chrome's TabLifecycleUnit discard; patch 0303).
        results["sleep_hosted_discard_keeps_tab_id"] = {
            "ok": before["chromeTabId"] > 0 and before["chromeTabId"] == after["chromeTabId"] == reloaded["chromeTabId"]
                  and strip_before == strip_after and before["chromeTabId"] in strip_after,
            "chromeTabId": [before["chromeTabId"], after["chromeTabId"], reloaded["chromeTabId"]],
            "strip": [strip_before, strip_after]}
    finally:
        server.shutdown()
        server.server_close()
        # No dialog may outlive the checks (review checklist 4).
        leftover = [d for d in (app.call("dismiss") or []) if str(d).startswith(("javascript", "modal", "sheet"))]
        if leftover:
            results["sleep_hosted_no_dialog_left"] = {"ok": False, "dismissed": leftover}
        try:
            app.call("select", tab=selected)
            # Closing the page with a beforeunload handler asks it (Chrome
            # style tab close); accept that prompt here, then restore the
            # shell's default dialog handling.
            app.call("policy", dialogs="accept")
            if unload_tab[0]:
                # Remove the fixture's beforeunload handler before the close:
                # a closing tab with a handler gets Chromium's app-modal
                # prompt, which no shell policy answers (docs/followups.md).
                app.eval(unload_tab[0], "removeEventListener('beforeunload', window.openUnloadHandler); true")
                wait_until(lambda: not sleep_op(unload_tab[0], "state")["unloadHandlers"] or None,
                           timeout=10, step=0.3)
            for t in (tab, unload_tab[0]):
                if t:
                    app.call("close", tab=t)
            wait_until(lambda: not any(t["id"] in (tab, unload_tab[0]) for t in app.call("tabs")),
                       timeout=10, step=0.3)
        except RuntimeError:
            pass
        finally:
            app.call("policy", dialogs=None)
            left = [d for d in (app.call("dismiss") or []) if str(d).startswith(("javascript", "modal", "sheet"))]
            results["sleep_hosted_cleanup"] = {
                "ok": not left and not any(t["id"] in (tab, unload_tab[0]) for t in app.call("tabs")),
                "dialogs": left}


def new_window_outlives_opener(app, results):
    """Open Link in New Window from a hosted tab, close the first window:
    the page in the new window stays live and is a tab of that window."""
    windows = [x["id"] for x in app.call("shell-windows")]
    t = new_tab(app, "https://example.com/?opener")
    app.eval(t, '(() => { const a = document.createElement("a"); a.href = "https://example.com/?new-window";'
                ' a.id = "oe-nw"; a.textContent = "new window"; a.style = "position:fixed;top:40px;left:40px;z-index:99999";'
                ' document.body.appendChild(a); return 1; })()')
    point = app.eval(t, '(() => { const r = document.getElementById("oe-nw").getBoundingClientRect();'
                        ' return {x: r.x + r.width / 2, y: r.y + r.height / 2}; })()')
    app.call("policy", contextMenu="record")
    app.call("events")
    app.call("rightclick", tab=t, x=point["x"], y=point["y"])
    menu = wait_until(lambda: [e for e in app.call("events") if e["type"] == "contextMenu"], timeout=5)
    command = [c for c in (menu[0].get("commands", []) if menu else []) if menu_key(c["title"]) == menu_key("Open Link in New Window")]
    info = {"command_found": bool(command)}
    if command:
        app.call("policy", contextMenu="run:%d" % command[0]["id"])
        app.call("rightclick", tab=t, x=point["x"], y=point["y"])
        new = wait_until(lambda: [x["id"] for x in app.call("shell-windows") if x["id"] not in windows], timeout=10)
        app.call("policy", contextMenu="record")
        if new:
            app.call("window-focus", id=new[0])
            page_tab = wait_until(lambda: [x for x in app.call("tabs") if "?new-window" in x["url"] and x.get("page")
                                           and x["page"]["live"]], timeout=15)
            app.call("window-focus", id=windows[0])
            app.call("window-close")
            time.sleep(2)
            app.call("window-focus", id=new[0])
            after = [x for x in app.call("tabs") if "?new-window" in x["url"]]
            page = after[0].get("page") if after else None
            seen = None
            if page:
                wait_until(lambda: any(e["id"] == PROBE for e in app.call("extensions")["installed"]), timeout=30)
                pop = app.call("popup", extension=PROBE)["identifier"]
                wait_until(lambda: app.eval(pop, "window.currentTab !== undefined"), timeout=20)
                seen = app.eval(pop, "chrome.tabs.query({currentWindow: true}).then(ts => ts.map(t => ({id: t.id,"
                                     " windowId: t.windowId, url: t.url})))")
                app.call("popup-close")
            info.update({"new_window": new[0], "page_before_close": bool(page_tab),
                         "page_after_close": page and {k: page[k] for k in ("live", "style", "chromeTabId", "chromeWindowId", "url")},
                         "new_window_tabs": seen})
            info["ok"] = (bool(page_tab) and bool(page) and page["live"] and page["style"] == "chrome"
                          and any(x["id"] == page["chromeTabId"] and x["windowId"] == page["chromeWindowId"]
                                  and "?new-window" in x["url"] for x in (seen or [])))
    info.setdefault("ok", False)
    results["new_window_outlives_opener"] = info


# Commands not run: they only open system UI outside Open's code paths
# (Character Viewer, speech, other apps through Services, the spelling
# panel). Everything else Chromium puts in the menu runs.
CONTEXT_MENU_SKIP_TITLES = ("Emoji & Symbols", "Show Spelling and Grammar")
CONTEXT_MENU_SKIP_SUBMENUS = ("Speech", "Services", "Disabled tabs probe submenu")
# Open's context-menu allowlist (docs/engine-api.md, "Context menu items"):
# Chrome items that must be gone, as letter-only fragments of their titles,
# and items each target must still show.
CONTEXT_MENU_DROPPED = ("cast", "readingmode", "qrcode", "withgoogle", "lens", "splitview", "incognito",
                        "importpasswords", "languagesettings", "sendto", "readinglist", "translate", "searchgoogle")
CONTEXT_MENU_KEPT = {
    "page": ("Reload", "Save As…", "Print…", "View Page Source", "Inspect", "Tabs probe item"),
    "link": ("Open Link in New Tab", "Open Link in New Window", "Save Link As…", "Copy Link Address", "Inspect",
             "Tabs probe item"),
    "image": ("Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address", "Tabs probe item"),
    "selection": ("Copy", "Copy Link to Highlight", "Look Up", "Tabs probe item"),
    "editable": ("Cut", "Copy", "Paste", "Paste and Match Style", "Select All", "Tabs probe item"),
    "video": ("Loop", "Show All Controls", "Picture in Picture", "Save Video As…", "Copy Video Address",
              "Tabs probe item"),
}


def _command_id(name):
    """A Chromium command id from CEF's generated header."""
    header = os.path.join(ROOT, "Vendor", "cef", "include", "cef_command_ids.h")
    for line in open(header):
        parts = line.split()
        if len(parts) == 3 and parts[:2] == ["#define", name]:
            return int(parts[2])
    raise RuntimeError("no %s in %s" % (name, header))


def menu_key(title):
    """Titles compared by letters only ("Emoji & Symbols": Chromium writes "&&")."""
    return "".join(ch for ch in title.lower() if ch.isalnum())


def context_menu_commands(app, results, *, run_all_commands=True):
    """Runs every Chrome context-menu command in a hosted tab, for each kind
    of target (page, link, image, video, selection, editable). None may
    crash the app (PR #53 review: toast and QR code paths). Dialogs and
    windows a command opens are dismissed through automation. A focused guard
    proof can capture the real menus/refusals without the general smoke loop."""
    import http.server
    import tempfile
    import threading
    import zlib

    root = tempfile.mkdtemp(prefix="oe-context-menu-")

    def png(w, h, rgb):
        raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

    with open(os.path.join(root, "image.png"), "wb") as f:
        f.write(png(160, 90, (40, 120, 220)))
    video = None
    if shutil.which("ffmpeg"):
        for name, codec in (("video.webm", ["-c:v", "libvpx-vp9"]), ("video.mp4", ["-c:v", "libx264", "-pix_fmt", "yuv420p"])):
            out = os.path.join(root, name)
            if subprocess.call(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=10",
                                "-t", "2"] + codec + [out], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
                video = name
                break
    with open(os.path.join(root, "target.html"), "w") as f:
        f.write("<!doctype html><title>Target</title><p>Link target</p>")
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write("<!doctype html><meta charset=utf-8><title>Context menu fixture</title>"
                "<style>body{margin:0;font:16px sans-serif}#blank{height:120px}"
                "img,video{display:block;width:160px;height:90px;margin:8px}p{margin:8px}</style>"
                "<div id=blank></div><p><a id=link href='target.html'>A link to another page</a></p>"
                "<p id=text>Selectable sentence for the context menu check.</p>"
                "<img id=img src='image.png'>" + ("<video id=video src='%s' muted loop></video>" % video if video else "")
                + "<p><input id=input value='Mispeled wordd'></p>")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=root, **kw)

        def log_message(self, *a):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    index = "http://127.0.0.1:%d/index.html" % server.server_port
    clipboard = subprocess.run(["pbpaste"], capture_output=True).stdout

    def center(selector, before=""):
        return ("(async () => { %s const e = document.querySelector('%s'); const r = e.getBoundingClientRect();"
                " return {x: r.left + r.width / 2, y: r.top + r.height / 2}; })()" % (before, selector))

    setups = {
        "page": "(() => { getSelection().removeAllRanges(); if (document.activeElement) document.activeElement.blur();"
                " return {x: 300, y: 40}; })()",
        "link": center("#link", "getSelection().removeAllRanges();"),
        "image": center("#img", "getSelection().removeAllRanges(); const i = document.getElementById('img');"
                                " if (!i.complete) await new Promise(r => i.onload = r);"),
        "selection": center("#text", "getSelection().selectAllChildren(document.getElementById('text'));"),
        "editable": center("#input", "const i = document.getElementById('input'); i.focus(); i.select();"),
    }
    if video:
        setups["video"] = center("#video", "getSelection().removeAllRanges(); const v = document.getElementById('video');"
                                           " if (v.readyState < 2) await new Promise(r => v.addEventListener('loadeddata', r,"
                                           " {once: true}));")

    tab = new_tab(app, index)
    report = {"targets": {}, "ran": 0, "skipped": [], "dismissed": [], "failures": []}
    menus = {}
    menu_commands = {}
    home_windows = [x["id"] for x in app.call("shell-windows")]

    def close_new_windows():
        """Open windows a command opened (Open Link in New Window)."""
        extra = [x["id"] for x in app.call("shell-windows") if x["id"] not in home_windows]
        for window in extra:
            app.call("window-focus", id=window)
            app.call("window-close")
        if extra:
            time.sleep(0.5)
            app.call("window-focus", id=home_windows[0])
        return ["open-window"] * len(extra)

    def row():
        rows = [t for t in app.call("tabs") if t["id"] == tab]
        return rows[0] if rows else None

    def prepare(target):
        app.call("select", tab=tab)
        r = row()
        if not r or not r["url"].startswith(index) or not r.get("page") or not r["page"]["live"]:
            app.call("navigate", tab=tab, url=index)
            try:
                app.call("wait", tab=tab, timeout=20)
            except RuntimeError:
                pass
        return app.eval(tab, setups[target], timeout=20)

    def right_click(point):
        app.call("rightclick", tab=tab, x=point["x"], y=point["y"])

    crashed = None
    current = None
    try:
        for target in setups:
            app.call("policy", contextMenu="record")
            app.call("events")
            right_click(prepare(target))
            menu = wait_until(lambda: [e for e in app.call("events") if e["type"] == "contextMenu"], timeout=5)
            commands = menu[0].get("commands", []) if menu else []
            menus[target] = menu[0].get("items", []) if menu else []
            menu_commands[target] = commands
            ran = []
            for command in commands:
                if not run_all_commands:
                    break  # Focused guard proof still checks all six real models.
                label = (command["submenu"] + " > " if command["submenu"] else "") + command["title"]
                if (not command["enabled"] or menu_key(command["title"]) in {menu_key(x) for x in CONTEXT_MENU_SKIP_TITLES}
                        or menu_key(command["submenu"]) in {menu_key(x) for x in CONTEXT_MENU_SKIP_SUBMENUS}):
                    report["skipped"].append("%s: %s%s" % (target, label, "" if command["enabled"] else " (disabled)"))
                    continue
                current = "%s: %s" % (target, label)
                point = prepare(target)
                app.call("policy", contextMenu="run:%d" % command["id"])
                try:
                    right_click(point)
                    time.sleep(1.5)
                    if app.proc.poll() is not None:
                        crashed = "%s: %s" % (target, label)
                        break
                    dismissed = app.call("dismiss") + close_new_windows()
                    if dismissed:
                        report["dismissed"].append({"command": "%s: %s" % (target, label), "closed": dismissed})
                    app.call("ping")
                    r = row()
                    if r and r["crashed"]:
                        report["failures"].append("%s: %s (renderer crashed)" % (target, label))
                    ran.append(label)
                    report["ran"] += 1
                finally:
                    app.cleanup_surfaces()
                    # Close Open windows even if the command or its check
                    # throws before the normal dismissal step.
                    if app.pid and app.process_path(app.pid) == app.executable:
                        try:
                            extra = close_new_windows()
                            if extra:
                                report["dismissed"].append({"command": current, "closed": extra})
                        except Exception as error:
                            report["failures"].append("cleanup: %s" % error)
            report["targets"][target] = ran
            if crashed:
                break
        if not crashed:
            # Run an enabled child of a disabled parent by its real delivered
            # command id. The execution allowlist must reject it too.
            children = [c for c in menu_commands.get("page", []) if c["title"] == "Disabled child probe item"]
            disabled = {"found": len(children) == 1}
            if children:
                child_id = children[0]["id"]
                app.call("events")
                point = prepare("page")
                app.call("policy", contextMenu="run:%d" % child_id)
                try:
                    right_click(point)
                    time.sleep(.3)
                    app.call("policy", contextMenu="record")
                    pop = app.call("popup", extension=PROBE)["identifier"]
                    # isLive precedes the extension document/API injection.
                    # Read storage only after the actual popup API is ready.
                    if not wait_until(lambda: app.eval(pop, "typeof chrome !== 'undefined' && !!(chrome.storage && chrome.storage.session)"), timeout=20):
                        raise RuntimeError("tabs-probe popup storage API not ready")
                    disabled["clicks"] = app.eval(pop, "chrome.storage.session.get('events').then(r => (r.events || []).filter(e => e.type === 'menu' && e.id === 'probe-disabled-child').length)")
                    disabled["id"] = child_id
                finally:
                    app.cleanup_surfaces()
                    app.call("policy", contextMenu="record")
            report["disabled_submenu"] = disabled
            hidden_id = _command_id("IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD")
            # A hidden item cannot run either: the engine runs only ids of
            # the delivered items, so selecting "Open Link in Incognito
            # Window" by id is refused and opens no window.
            home_ids = [x["id"] for x in app.call("shell-windows")]
            app.call("events")
            point = prepare("link")
            app.call("policy", contextMenu="run:%d" % hidden_id)
            right_click(point)
            time.sleep(2)
            report["hidden_command"] = {
                "id": hidden_id,
                "new_windows": [x for x in app.call("shell-windows") if x["id"] not in home_ids],
                "window_requests": [e for e in app.call("events") if e["type"] == "window-request"],
                "foreign_windows": app.call("dismiss")}
    except Exception as e:
        try:
            app.proc.wait(5)
        except subprocess.TimeoutExpired:
            pass
        if app.proc.poll() is not None and not crashed:
            crashed = "%s (app exited: %s)" % (current, e)
        else:
            report["failures"].append("harness: %s" % e)
    finally:
        app.cleanup_surfaces()
        server.shutdown()
        subprocess.run(["pbcopy"], input=clipboard)
        shutil.rmtree(root, ignore_errors=True)
        if app.proc.poll() is None:
            app.call("policy", contextMenu="record")
    report["crashed"] = crashed
    report["video"] = video
    report["scope"] = "all_commands" if run_all_commands else "models_and_refusals"
    report["ok"] = not crashed and not report["failures"] and (not run_all_commands or report["ran"] >= 20) and len(report["targets"]) == len(setups)
    results["context_menu_commands"] = report

    # The allowlist: no dropped Chrome item, the kept ones, extension items,
    # and no empty, leading, trailing or doubled separators.
    allow = {"menus": menus, "dropped_seen": {}, "kept_missing": {}, "separators": {}}
    for target, items in menus.items():
        # Several extension items may be grouped under its name. Check
        # delivered leaf titles too, while separators still use each root menu.
        titles = [x for x in items if x] + [c["title"] for c in menu_commands.get(target, [])]
        seen = [x for x in titles if any(d in menu_key(x) for d in CONTEXT_MENU_DROPPED)]
        seen += [x for x in titles if x == "Invisible tabs probe item"]
        missing = [k for k in CONTEXT_MENU_KEPT.get(target, ())
                   if not any(menu_key(x).startswith(menu_key(k)) for x in titles)]
        bad = (items[:1] == [""] or items[-1:] == [""]
               or any(a == b == "" for a, b in zip(items, items[1:])))
        if seen:
            allow["dropped_seen"][target] = seen
        if missing:
            allow["kept_missing"][target] = missing
        if bad:
            allow["separators"][target] = items
    allow["ok"] = (len(menus) == len(CONTEXT_MENU_KEPT) - (0 if "video" in menus else 1)
                   and not allow["dropped_seen"] and not allow["kept_missing"] and not allow["separators"])
    results["context_menu_allowlist"] = allow
    hidden = report.get("hidden_command") or {}
    log_text = app.log_text()
    disabled = report.get("disabled_submenu") or {}
    results["context_menu_disabled_submenu_refused"] = {
        "ok": disabled.get("found") is True and disabled.get("clicks") == 0
              and ("refused command %d" % disabled.get("id", -1)) in log_text,
        **disabled}
    results["context_menu_hidden_command_refused"] = {
        "ok": bool(hidden) and not hidden["new_windows"] and not hidden["window_requests"]
              and not hidden["foreign_windows"] and ("refused command %d" % hidden.get("id")) in log_text,
        **hidden}


# ----------------------------------------------------------------------------
# Window startup checks (Step A; Step B extends this suite).


def focus_restore_checks(factory, results, tmp):
    """A real slow response keeps the exact command-bar load pending while focus moves."""
    import http.server
    import threading
    started, release = threading.Event(), threading.Event()
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith('/slow'):
                started.set(); release.wait(30)
            body = ('<title>Focus ' + self.path + '</title><p>Focus regression</p>').encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    try:
        for case in ('sidebar', 'find', 'inactive_load', 'inactive_dismiss'):
            started.clear(); release.clear()
            app = factory(urls=(origin + '/base',), fresh=True); peer = None
            try:
                w1 = app.call('window-state')['id']
                if case == 'inactive_dismiss':
                    app.call('menu-perform', id='new-window')
                    w2 = next(w['id'] for w in app.call('shell-windows') if w['id'] != w1)
                    app.call('window-focus', id=w1, activate=True)
                tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab); app.call('focus', tab=tab)
                page_handle = app.page(tab)['identifier']
                baseline = app.call('focus-state')['navigationDecisions']
                app.call('key', key='l', modifiers=['cmd'])
                assert wait_until(lambda: app.call('commandbar-state').get('presented'), timeout=3, step=.02)
                path = '/slow-' + case; url = origin + path
                app.call('key', text=url)
                assert wait_until(lambda: app.call('commandbar-state').get('text') == url and app.call('commandbar-state').get('final'), timeout=5, step=.02)
                app.call('key', key='return'); assert started.wait(10), 'controlled response did not start'
                assert app.tab(tab)['loading'], 'response completed before the focus move'
                if case == 'find':
                    app.call('menu-perform', id='find'); app.call('key', text='keep-find-focus')
                elif case == 'inactive_dismiss':
                    app.call('key', key='l', modifiers=['cmd'])
                    assert wait_until(lambda: app.call('commandbar-state').get('presented'), timeout=3, step=.02)
                else:
                    app.call('menu-perform', id='reveal-current-tab')
                if case.startswith('inactive'):
                    peer = app.foreground_peer(); app.accept_owned_handoff(peer)
                before = app.call('focus-state', id=w1)
                expected = 'find' if case == 'find' else 'commandbar' if case == 'inactive_dismiss' else 'sidebar'
                assert before['owner'] == expected, before
                release.set(); app.call('wait', tab=tab)
                # A delivery counter is read only after the real load-end callback's
                # next-turn decision. No sleep stands in for focus delivery.
                delivered = wait_until(lambda: (lambda s: s if s['navigationDecisions'] > baseline else None)(app.call('focus-state', id=w1)), timeout=5, step=.02)
                assert delivered, app.call('focus-state', id=w1)
                if case == 'inactive_dismiss':
                    app.call('window-focus', id=w2, activate=False)
                    after = wait_until(lambda: (lambda s: s if s['owner'] != 'commandbar' else None)(app.call('focus-state', id=w1)), timeout=3, step=.02)
                    expected = 'window'
                else:
                    after = app.call('focus-state', id=w1)
                native = app.call('native-focus-state')
                loaded = app.eval(page_handle, 'document.title') == 'Focus ' + path
                preserved = bool(after) and after['owner'] == expected and not delivered['lastNavigationRestored']
                if case == 'find': preserved = preserved and after['findText'] == 'keep-find-focus'
                if peer: preserved = preserved and not native['active'] and native['frontmostPID'] == peer.pid
                results['focus_preserves_' + case] = {'ok': loaded and preserved, 'before': before, 'after': after,
                    'loadDelivery': delivered, 'native': native, 'peerPID': peer.pid if peer else None}
            finally:
                release.set(); app.quit()
                if peer: peer.quit()
    finally:
        release.set(); server.shutdown()


def shutdown_order_checks(factory, results, tmp):
    """Real queued Save/background work is cancelled before the actual engine shutdown call."""
    app = factory(urls=('data:text/html,<title>Quit ordering</title><h1>Quit ordering</h1>',), fresh=True,
                  extra_env={'OPEN_AUTOMATION_SHUTDOWN_TRACE': '1', 'OPEN_AUTOMATION_ASYNC_TASK_DELAY_MS': '30000'})
    path = os.path.join(app.user_data, 'State', 'shutdown-order.json')
    destination = os.path.join(tmp, 'cancelled-at-quit.mhtml')
    try:
        app.call('wait'); app.call('background-read')
        app.call('menu-perform', id='save-page-as')
        assert wait_until(lambda: app.call('save-page-state')['visible'], timeout=5, step=.02)
        app.call('save-page-choose', path=destination)
        pending = wait_until(lambda: (lambda s: s if s['captures'] > 0 and s['background'] > 0 else None)(app.call('async-engine-state')), timeout=5, step=.02)
        assert pending, app.call('async-engine-state')
    finally:
        app.quit()
    def completed_trace():
        if not os.path.exists(path): return None
        with open(path) as stream: value = json.load(stream)
        return value if value and value[-1]['phase'] == 'engineShutdownEnd' else None
    trace = wait_until(completed_trace, timeout=10, step=.02)
    assert trace, {'quit': app.quit_report, 'traceExists': os.path.exists(path)}
    phases = [r['phase'] for r in trace]
    expected = ['prepare', 'hostsClosed', 'engineShutdownBegin', 'engineShutdownEnd']
    closed = trace[1:]
    results['quit_order_owned_work'] = {'ok': phases == expected and not app.quit_report.get('forced', False)
        and trace[0]['captureTasks'] > 0 and trace[0]['backgroundTasks'] > 0
        and all(r['captureTasks'] == r['backgroundTasks'] == r['selectionTasks'] == r['hosts'] == 0
                and r['closedFactories'] == r['factories'] and r['lateAsyncEngineCalls'] == 0 for r in closed)
        and all(a['uptime'] <= b['uptime'] for a, b in zip(trace, trace[1:]))
        and not os.path.exists(destination), 'pendingBeforeQuit': pending, 'quit': app.quit_report, 'trace': trace}


def window_checks(app_factory, results, tmp, config, chrome_only=False):
    window_chrome_followup_checks(app_factory, results, tmp)
    if chrome_only: return
    # Local deterministic text paints without DNS, TLS, or external requests.
    fixture = "data:text/html,<title>Open launch fixture</title><h1>Open launch fixture</h1>"
    runs = {"cold_fresh_profile": [], "warm_existing_profile": []}
    results["load_average"] = list(os.getloadavg())
    results["cpu_count"] = os.cpu_count()
    for i in range(5):
        # Clear only this suite's own data root. Warm launches then restore a
        # selected tab plus an unselected tab from the real saved snapshot.
        app = app_factory(urls=(fixture,), fresh=True)
        try:
            tab = app.call("tabs")[0]
            app.call("wait", tab=tab["id"])
            wait_until(lambda: "firstContentfulPaint" in app.call("timing"), timeout=10, step=0.1)
            runs["cold_fresh_profile"].append(app.call("timing"))
            evidence = app.call("startup")
            results["window_before_engine_%d" % i] = {
                "ok": evidence["pagesBeforeEngine"] == 0 and evidence["contextsBeforeEngine"] == 0
                      and evidence["visibleWindows"] >= 1
                      and evidence["sidebarClass"] == "OpenSidebar.SidebarView"
                      and runs["cold_fresh_profile"][-1]["kernelProcessStart"] is True
                      and runs["cold_fresh_profile"][-1]["firstFrameConfirmed"] is True
                      and runs["cold_fresh_profile"][-1]["sidebarDrawn"] <= runs["cold_fresh_profile"][-1]["engineStart"],
                "evidence": evidence}
            # Create the second row, then return selection to the first row.
            other = app.call("open", url="data:text/html,<title>Unselected</title><h1>Unselected</h1>")
            app.call("select", tab=tab["id"])
            app.call("save")
            if i == 0:
                results["window_png"] = {"ok": True, "file": shot(app, "window-startup.png", max_px=2560)}
        finally:
            app.quit()
        app = app_factory(urls=())
        try:
            selected = next(t for t in app.call("tabs") if t["selected"])
            app.call("wait", tab=selected["id"])
            wait_until(lambda: "firstContentfulPaint" in app.call("timing"), timeout=10, step=0.1)
            runs["warm_existing_profile"].append(app.call("timing"))
            tabs = app.call("tabs")
            results["selected_only_%d" % i] = {
                "ok": len(tabs) == 2 and len([t for t in tabs if t["loaded"]]) == 1
                      and next(t for t in tabs if t["loaded"])["id"] == selected["id"],
                "tabs": [{k: t[k] for k in ("title", "loaded", "selected")} for t in tabs]}
        finally:
            app.quit()
    results["launch_runs"] = runs
    results["kernel_process_start"] = {"ok": all(r.get("kernelProcessStart") is True for values in runs.values() for r in values), "samples": sum(map(len, runs.values()))}
    for label, values in runs.items():
        medians = {key: statistics.median([r[key] for r in values if key in r])
                   if all(key in r for r in values) else None
                   for key in ("main", "modelLoaded", "sidebarDrawn", "engineStart", "engineStarted", "firstContentfulPaint")}
        results[label] = {"median_ms": medians, "samples": len(values)}
        if config == "Release":
            results[label]["ok"] = medians["sidebarDrawn"] is not None and medians["sidebarDrawn"] <= 250 and medians["firstContentfulPaint"] is not None and medians["firstContentfulPaint"] <= 700
        else:
            results[label].update(status="SKIP", reason="Release timing budgets are not evaluated in Debug")
        print(label, medians)
    # A never-loaded pinned row must never pass through selection while
    # closing or unloading. The counter is cumulative, so create-then-drop
    # cannot look like zero retained hosts.
    app = app_factory(urls=(), fresh=True)
    try:
        first = new_tab(app, "data:text/html,<title>Selected</title><h1>Selected</h1>")
        pinned = app.call("open", url="data:text/html,<title>Never loaded</title><h1>Never loaded</h1>", background=True)["id"]
        app.call("pin", tab=pinned)
        before = app.call("host-counts")
        app.call("close", tab=pinned)
        after_close = app.call("host-counts")
        app.call("sidebar-unload", tab=pinned)
        after_unload = app.call("host-counts")
        results["close_unloaded_pinned"] = {"ok": before == after_close == after_unload
            and not app.tab(pinned)["loaded"] and app.tab(first)["selected"]
            and app.eval(first, "document.title") == "Selected",
            "before": before, "after_close": after_close, "after_unload": after_unload}
    finally:
        app.quit()
    startup_failure_checks(app_factory, results, tmp)
    window_flow_checks(app_factory, results, tmp)
    focus_restore_checks(app_factory, results, tmp)
    window_chrome_checks(app_factory, results, tmp)
    static_window_comparison(app_factory, results, tmp, "window")


# ----------------------------------------------------------------------------
# Real window and production-sidebar flows (Step B).


def fixture(name):
    return "data:text/html,<title>%s</title><h1>%s</h1>" % (name, name)


def check_page(app, tab, title):
    app.call("wait", tab=tab)
    state = app.call("window-state")
    page = app.page(tab)
    return (app.eval(tab, "document.title") == title and state["selected"] == tab
            and state["shownPages"] == [tab] and state["engineSelected"] == page["identifier"]
            and state["engineURL"] == page["url"] and page["live"] and not page["hidden"])


def state_when(app, predicate, timeout=5, step=0.05):
    """Polls window-state until `predicate(state)` holds; returns that state or None."""
    return wait_until(lambda: (lambda st: st if predicate(st) else None)(app.call("window-state")), timeout=timeout, step=step)


def sidebar_hidden(app, timeout=3):
    return state_when(app, lambda st: st["sidebarMode"] == "hidden" and not st["sidebarVisible"], timeout=timeout)


def sidebar_anchored(app, timeout=3):
    return state_when(app, lambda st: st["sidebarMode"] == "anchored" and st["sidebarVisible"] and st["panel"][0] > 10, timeout=timeout)


def wait_card(app, shown, timeout=3.0, step=0.015):
    """Waits for the hover-reveal card to settle instead of sleeping a fixed time.

    shown: the card is revealed and its on-screen offset (the slide's presentation value)
    stays within 0.5 pt of its place for three samples in a row. hidden: no card at all
    (the slide-out finished). Returns {"elapsed", "samples"} or None on timeout."""
    app.begin_timing("hover card settles")
    start = time.monotonic()
    samples, still = [], 0
    while time.monotonic() - start < timeout:
        st = app.call("window-state")
        r = st["reveal"]
        samples.append([round(time.monotonic() - start, 3), r["phase"], r["offset"]])
        if shown:
            still = still + 1 if st["revealed"] and r["offset"] is not None and abs(r["offset"]) <= 0.5 else 0
            if still >= 3:
                return {"elapsed": round(time.monotonic() - start, 3), "samples": len(samples), "state": st}
        elif not st["revealed"] and r["offset"] is None:
            return {"elapsed": round(time.monotonic() - start, 3), "samples": len(samples), "state": st}
        time.sleep(step)
    return None


def window_flow_checks(factory, results, tmp):
    app = factory(urls=(), fresh=True)
    try:
        # OpenEngine registers a delegating malloc zone before main(), so the
        # engine's PartitionAlloc replaces it in place and the system zone
        # is never out of the zone list (the launch race of 2026-10-26). On
        # the racy path the system zone is registered again, after the
        # purgeable zone (docs/engine-fork.md).
        zones = app.call("ping").get("mallocZones", [])
        results["malloc_zones_early"] = {
            "ok": zones[:1] == ["PartitionAlloc"] and "DefaultMallocZone" in zones
                  and "DefaultPurgeableMallocZone" in zones
                  and zones.index("DefaultMallocZone") < zones.index("DefaultPurgeableMallocZone"),
            "zones": zones}
        first = app.call("window-state")
        w1 = first["id"]
        results["native_window"] = {
            "ok": first["titled"] and first["hiddenTitle"] and not first["peekCreated"]
                  and len(first["trafficLights"]) == 3
                  and all(abs(x - target) <= 0.5 and abs(y - 24) <= 0.5
                          for (x, y), target in zip(first["trafficLights"], [20, 43, 66]))
                  and first["sidebarClass"] == "OpenSidebar.SidebarView",
            "state": first}
        app.call("key", key="escape", route="app")
        results["keys_keep_peek_lazy"] = {"ok": not app.call("window-state")["peekCreated"]}
        app.call("save")
        counts = app.call("frame-save-counters")
        for index in range(12):
            app.call("window-frame", frame=[80 + index, 60 + index, 1000, 700])
        immediate = app.call("frame-save-counters")
        wait_until(lambda: app.call("frame-save-counters")["captures"] > counts["captures"], timeout=4, step=0.1)
        debounced = app.call("frame-save-counters")
        def saved_frame():
            with open(os.path.join(app.user_data, "State", "browser.json")) as stream:
                row = json.load(stream)["windows"][0]
            return [row[k] for k in ("frameX", "frameY", "frameWidth", "frameHeight")]
        saved = wait_until(lambda: saved_frame() == [91, 71, 1000, 700], timeout=4, step=0.1)
        results["frame_save_debounced"] = {"ok": immediate["captures"] == counts["captures"]
            and debounced["captures"] == counts["captures"] + 1
            and immediate["treeChanges"] == counts["treeChanges"] and immediate["mirrorSyncs"] == counts["mirrorSyncs"] and bool(saved),
            "before": counts, "immediate": immediate, "debounced": debounced}
        app.call("window-frame", frame=[80, 60, 1000, 700])
        a = new_tab(app, fixture("Window A"))
        b = app.call("open", url=fixture("Window B"), background=True)["id"]
        results["background_lazy"] = {"ok": not app.tab(b)["loaded"] and not app.tab(b)["hasWebContent"]}
        app.call("mouse", **{"from": [228, 300], "to": [300, 300]})
        state = app.call("window-state")
        results["resize_300"] = {"ok": state["sidebarWidth"] == 300 and state["panel"][0] == 300, "state": state}
        app.call("mouse", **{"from": [300, 300], "to": [700, 300]})
        wide = app.call("window-state")
        app.call("mouse", **{"from": [500, 300], "to": [150, 300]})
        narrow = app.call("window-state")
        results["resize_limits"] = {"ok": wide["sidebarWidth"] == 500 and narrow["sidebarWidth"] == 164 and narrow["sidebarMode"] == "anchored"}
        app.call("mouse", **{"from": [164, 300], "to": [60, 300]})
        hidden = sidebar_hidden(app) or app.call("window-state")
        # The first reveal right after the hide: every wait below is a condition (the
        # card settled or gone), never a fixed sleep.
        app.call("mouse", action="move", x=600, y=300)
        app.call("mouse", action="move", x=3, y=300)
        reveal = wait_card(app, True)
        app.call("select", tab=b)
        dismissed = wait_card(app, False)
        selected = check_page(app, b, "Window B")
        # After a dismissal the pointer has to leave the edge before the card returns.
        app.call("mouse", action="move", x=600, y=300)
        app.call("mouse", action="move", x=3, y=300)
        again = wait_card(app, True)
        app.call("mouse", action="move", x=600, y=300)
        left = wait_card(app, False)
        results["hide_reveal"] = {"ok": hidden["sidebarMode"] == "hidden" and hidden["panel"][0] == 10
                                      and bool(reveal) and bool(dismissed) and selected and bool(again) and bool(left),
                                  "hidden": hidden["sidebarMode"], "panel_x": hidden["panel"][0],
                                  "revealed_s": reveal and reveal["elapsed"], "dismissed_s": dismissed and dismissed["elapsed"],
                                  "selected": selected, "revealed_again_s": again and again["elapsed"], "left_s": left and left["elapsed"]}
        # Yield only our own app. Tagged pointer handling must still work while
        # another process is foreground; no input is sent to that process.
        peer = app.foreground_peer()
        try:
            app.accept_owned_handoff(peer)
            inactive = state_when(app, lambda st: not st["appActive"])
            app.call("mouse", action="move", x=600, y=300)
            app.call("mouse", action="move", x=3, y=300)
            background_reveal = wait_card(app, True)
            app.call("mouse", action="move", x=600, y=300)
            background_hide = wait_card(app, False)
            results["background_tagged_pointer"] = {"ok": bool(inactive) and bool(background_reveal) and bool(background_hide)
                and not background_reveal["state"]["appActive"], "inactive": bool(inactive),
                "revealed": bool(background_reveal), "hidden": bool(background_hide)}
        finally:
            peer.quit()
        app.call("key", key="s", modifiers=["cmd"], route="app")
        results["toggle_sidebar"] = {"ok": bool(sidebar_anchored(app))}
        # Drag-hide now preserves 190 from before that drag, rather than writing 228.
        drag_start = app.call("window-state")["sidebarWidth"]
        app.call("mouse", **{"from": [drag_start, 300], "to": [300, 300]})
        app.call("key", key="s", modifiers=["cmd"], route="app")
        sidebar_hidden(app)
        app.call("key", key="n", modifiers=["cmd"], route="app")
        windows = app.call("shell-windows")
        second = app.call("window-state"); w2 = second["id"]
        results["multiple_windows"] = {"ok": len(windows) == 2 and w1 != w2 and second["frame"] != hidden["frame"]
                                            and second["selected"] == "" and second["shownPages"] == [], "windows": windows}
        app.call("window-frame", frame=[300, 200, 900, 600])
        space2 = app.call("space-create", title="Second Space")
        c = new_tab(app, fixture("Window C"))
        app.call("window-focus", id=w1)
        strip_before = app.call("tab-strip")
        space1 = app.call("window-state")["space"]
        app.call("window-focus", id=w2)
        app.call("space", space=space1); app.call("select", tab=a)
        strip_second = app.call("tab-strip")
        app.call("space", space=space2); app.call("select", tab=c)
        strip_second_after = app.call("tab-strip")
        app.call("window-focus", id=w1)
        strip_after = app.call("tab-strip")
        results["all_spaces_strip_order"] = {"ok": strip_before == strip_after
            and strip_before[0]["tabs"] == [b, a] and strip_second[0]["tabs"] == [a, c]
            and strip_second_after[0]["tabs"] == [a, c] and strip_second_after[0]["active"] == c,
            "first_before": strip_before, "first_after": strip_after, "second_before": strip_second, "second_after": strip_second_after}
        app.call("window-focus", id=w2)
        before = app.call("window-state")
        app.call("window-fullscreen")
        def finished_fullscreen(on, changes):
            state = app.call("window-state")
            return state if state["fullscreen"] == on and not state["fullscreenTransition"] and state["fullscreenChanges"] >= changes else None
        entered = wait_until(lambda: finished_fullscreen(True, before["fullscreenChanges"] + 1), timeout=15, step=0.1)
        app.call("key", key="s", modifiers=["cmd"], route="app")
        full_hidden = sidebar_hidden(app) or app.call("window-state")
        app.call("mouse", action="move", x=600, y=300)
        app.call("mouse", action="move", x=3, y=300)
        full_reveal = wait_card(app, True)
        app.call("select", tab=c)
        full_dismiss = wait_card(app, False)
        app.call("key", key="s", modifiers=["cmd"], route="app")
        sidebar_anchored(app)
        # Wait for the real state before the page call: the second window in
        # front with its full-screen transition over, and tab C's own page
        # there live. Automation resolves a tab in the front window; a page
        # call that lands while it has no live browser fails with
        # OEErrorWebContentClosed (code 4). If it still fails, record why.
        def fullscreen_diag():
            return {"front": app.call("window-state")["id"], "w1": w1, "w2": w2, "tab": app.tab(c),
                    "pages": [[p.get("identifier"), p.get("live"), p.get("url", "")[-40:]] for p in app.call("pages")]}
        def page_ready():
            state = app.call("window-state")
            return (state["id"] == w2 and state["fullscreen"] and not state["fullscreenTransition"]
                    and app.page(c).get("live"))
        ready = wait_until(page_ready, timeout=10, step=0.1)
        before_request = fullscreen_diag()
        try:
            request = app.eval(c, 'document.documentElement.requestFullscreen().then(() => "ok", e => e.message)')
        except RuntimeError as e:
            results["html_fullscreen_in_native"] = {"ok": False, "error": str(e), "ready": bool(ready),
                                                    "before": before_request, "after": fullscreen_diag()}
            raise
        page_full = wait_until(lambda: app.call("window-state")["pageFullscreen"], timeout=5, step=0.1)
        page_state = app.call("window-state")
        app.call("fullscreen-exit", tab=c)
        page_exit = wait_until(lambda: not app.call("window-state")["pageFullscreen"], timeout=5, step=0.1)
        after_page = app.call("window-state")
        results["html_fullscreen_in_native"] = {"ok": bool(ready) and request == "ok" and bool(page_full) and bool(page_exit)
            and not page_state["sidebarVisible"] and page_state["panel"] == [0, 0] + page_state["frame"][2:]
            and after_page["fullscreen"] and after_page["sidebarVisible"] and after_page["panel"][0] == 228,
            "ready": bool(ready), "page_state": page_state, "after_exit": after_page}
        app.call("window-fullscreen")
        exited = wait_until(lambda: finished_fullscreen(False, before["fullscreenChanges"] + 2), timeout=15, step=0.1)
        results["fullscreen"] = {"ok": bool(entered) and bool(exited) and check_page(app, c, "Window C")}
        results["fullscreen_hover_reveal"] = {"ok": full_hidden["sidebarMode"] == "hidden" and bool(full_reveal) and bool(full_dismiss),
            "hidden": full_hidden["sidebarMode"], "revealed_s": full_reveal and full_reveal["elapsed"],
            "dismissed_on_selection_s": full_dismiss and full_dismiss["elapsed"]}
        request = app.eval(c, 'document.documentElement.requestFullscreen().then(() => "ok", e => e.message)')
        entered_page = wait_until(lambda: finished_fullscreen(True, before["fullscreenChanges"] + 3), timeout=15, step=0.1)
        page_state = app.call("window-state")
        app.call("fullscreen-exit", tab=c)
        exited_page = wait_until(lambda: finished_fullscreen(False, before["fullscreenChanges"] + 4), timeout=15, step=0.1)
        after_page = app.call("window-state")
        results["html_fullscreen_from_window"] = {"ok": request == "ok" and bool(entered_page) and bool(exited_page)
            and page_state["pageFullscreen"] and not page_state["sidebarVisible"]
            and page_state["panel"] == [0, 0] + page_state["frame"][2:]
            and not after_page["pageFullscreen"] and after_page["sidebarVisible"] and check_page(app, c, "Window C"),
            "page_state": page_state, "after_exit": after_page}
        results["multiple_window_png"] = {"ok": True, "file": shot(app, "window-multiple.png")}
        app.call("save")
        expected = {}
        for wid in (w1, w2):
            app.call("window-focus", id=wid)
            state = app.call("window-state")
            expected[wid] = {k: state[k] for k in ("frame", "sidebarWidth", "sidebarMode", "space", "selected")}
        app.call("save")
    finally:
        app.quit()
    app = factory(urls=())
    try:
        restored = {}
        restored_pages = []
        for row in app.call("shell-windows"):
            app.call("window-focus", id=row["id"])
            state = app.call("window-state")
            restored[row["id"]] = {k: state[k] for k in ("frame", "sidebarWidth", "sidebarMode", "space", "selected")}
            restored_pages.append(check_page(app, state["selected"], "Window B" if row["id"] == w1 else "Window C"))
        results["window_persistence"] = {"ok": restored == expected and len(app.call("pages")) == 2 and all(restored_pages)
                                            and restored[w1]["sidebarWidth"] == 300 and restored[w1]["sidebarMode"] == "hidden"
                                            and restored[w1]["selected"] == b and restored[w2]["selected"] == c,
                                         "expected": expected, "restored": restored}
        # Relaunch intentionally restored only B and C. Load A in both windows
        # before testing that closing one owner preserves the other's live row.
        app.call("window-focus", id=w1); app.call("select", tab=a); app.call("wait", tab=a); app.call("select", tab=b)
        app.call("window-focus", id=w2); app.call("space", space=expected[w1]["space"])
        app.call("select", tab=a); app.call("wait", tab=a)
        app.call("space", space=space2); app.call("select", tab=c)
        app.call("window-close")
        remaining = app.call("tab-state", tab=a)
        results["window_close_preserves_other_host"] = {"ok": remaining["loaded"] and remaining["hasWebContent"], "state": remaining}
        app.call("space", space=space2)
        results["close_window_keeps_tabs"] = {"ok": len(app.call("shell-windows")) == 1 and any(t["id"] == c for t in app.call("tabs"))}
        app.call("select", tab=c)
        last = app.call("window-state")
        last_expected = {k: last[k] for k in ("id", "frame", "sidebarWidth", "sidebarMode", "space", "selected")}
        app.call("window-close")
        no_windows = app.call("shell-windows") == []
        app.call("window-reopen")
        reopened = app.call("window-state")
        reopened_state = {k: reopened[k] for k in last_expected}
        reopened_page = check_page(app, c, "Window C")
        results["last_window_reopen"] = {"ok": no_windows and len(app.call("shell-windows")) == 1
            and reopened_state == last_expected and reopened_page,
            "expected": last_expected, "reopened": reopened_state, "no_windows_after_close": no_windows, "correct_page": reopened_page}
        app.call("window-close")
        app.call("save")
    finally:
        app.quit()
    app = factory(urls=())
    try:
        restored = app.call("window-state")
        restored_state = {k: restored[k] for k in last_expected}
        restored_page = check_page(app, c, "Window C")
        results["last_window_relaunch"] = {"ok": len(app.call("shell-windows")) == 1
            and restored_state == last_expected and restored_page,
            "expected": last_expected, "restored": restored_state, "correct_page": restored_page}
    finally:
        app.quit()


# ----------------------------------------------------------------------------
# Window chrome (traffic lights, URL field and Space header, hover-reveal card).
# Expected values: docs/design.md section 2.2, docs/re/interaction-states.md section 13.

SRGB_PROFILE = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
LIGHT_CENTERS = [[20, 24], [43, 24], [66, 24]]


def read_image(path, srgb=False):
    """(width, height, pixel(x, y) -> (r, g, b)) through sips; the stdlib has no PNG decoder."""
    src = path
    if srgb:
        src = path + ".srgb.png"
        subprocess.run(["sips", "-m", SRGB_PROFILE, path, "--out", src], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    bmp = path + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", src, "--out", bmp], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data = open(bmp, "rb").read()
    os.remove(bmp)
    if srgb:
        os.remove(src)
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    stride = (width * bpp + 3) & ~3
    top_down, height = height < 0, abs(height)

    def pixel(x, y):
        x = min(max(int(x), 0), width - 1)
        y = min(max(int(y), 0), height - 1)
        i = offset + (y if top_down else height - 1 - y) * stride + x * bpp
        return data[i + 2], data[i + 1], data[i]
    return width, height, pixel


def luma(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def light_centers(st, dx=0, dy=0):
    centers = [[f[0] + f[2] / 2, f[1] + f[3] / 2] for f in st["trafficLightFrames"]]
    ok = len(centers) == 3 and all(abs(c[0] - e[0] - dx) <= 0.5 and abs(c[1] - e[1] - dy) <= 0.5 for c, e in zip(centers, LIGHT_CENTERS))
    return ok, centers


def drawn_light_center(png, scale, cx, cy):
    """Center of the drawn circle near (cx, cy) points: contrast-weighted centroid of the
    pixels that differ from the background between two buttons. The dimmed rest look on
    light content differs from the background by only about 15–23 levels."""
    _, _, px = read_image(png)
    bg = px((cx + 11.5) * scale, cy * scale)
    sx = sy = sw = 0.0
    for y in range(int((cy - 9) * scale), int((cy + 9) * scale)):
        for x in range(int((cx - 9) * scale), int((cx + 9) * scale)):
            c = px(x, y)
            d = max(abs(c[i] - bg[i]) for i in range(3))
            if d > 8:
                sx += (x + 0.5) * d; sy += (y + 0.5) * d; sw += d
    return [round(sx / sw / scale, 2), round(sy / sw / scale, 2)] if sw else None


def circular_corner_edges(r, n):
    """x of a circular corner's edge at each pixel row center (corner at the origin, radius r)."""
    return [r - max(r * r - (r - (j + 0.5)) ** 2, 0) ** 0.5 if j + 0.5 < r else 0.0 for j in range(n)]


def continuous_corner_edges(r, n):
    """x of a continuous rounded corner's edge at each pixel row center (corner at the origin,
    radius r): the curve PaintCode published for iOS 7 rounded rects, sampled densely."""
    k = [1.52866483, 1.08849323, 0.86840689, 0.63149399, 0.07491100, 0.37282392, 0.16905899]
    segments = [((k[0], 0), (k[1], 0), (k[2], 0), (k[3], k[4])),
                ((k[3], k[4]), (k[5], k[6]), (k[6], k[5]), (k[4], k[3])),
                ((k[4], k[3]), (0, k[2]), (0, k[1]), (0, k[0]))]
    points = []
    for p0, p1, p2, p3 in segments:
        for t in [i / 400 for i in range(401)]:
            u = 1 - t
            points.append(tuple(r * (u ** 3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t ** 3 * d) for a, b, c, d in zip(p0, p1, p2, p3)))
    edges = []
    for j in range(n):
        yc = j + 0.5
        if yc >= k[0] * r:
            edges.append(0.0)
            continue
        best = min(points, key=lambda p: abs(p[1] - yc))
        edges.append(best[0])
    return edges


def card_edges(card_png, base_png, card, scale, page_right=True, tolerance=0.6, radius=12, curve="circle"):
    """Pixel checks of the hover-reveal card edge against the same view without the card.

    alpha = how much of a pixel is card (0 outside, 1 on the stroke). Corners: the extreme
    corner pixel must be outside (no square corner), the 45-degree profile must rise through
    an intermediate value (anti-aliased, not jagged), all four corners must match (mirrored),
    and the edge must follow the card's corner (circular, radius 12: Arc's F0129 fits that). Edges: the boundary pixel is the
    stroke (white 0.30 over the card fill) on all four sides, and the shadow darkens just
    outside (7.5 % at 1 pt over a white page in Arc's F0129) and is gone by 9 pt.
    `tolerance` (px along the edge's normal) is looser for themes with grain, whose noise
    moves the measured edge where the curve is nearly flat."""
    _, _, P = read_image(card_png)
    _, _, B = read_image(base_png)
    s = scale
    x0, y0 = round(card[0] * s), round(card[1] * s)
    x1, y1 = round((card[0] + card[2]) * s) - 1, round((card[1] + card[3]) * s) - 1
    mx, my = (x0 + x1) // 2, (y0 + y1) // 2
    sides = {}
    for name, (bx, by, ix, iy, ox, oy) in {
            "left": (x0, my, x0 + 3 * s, my, x0 - 1, my), "right": (x1, my, x1 - 3 * s, my, x1 + 1, my),
            "top": (mx, y0, mx, y0 + 3 * s, mx, y0 - 1), "bottom": (mx, y1, mx, y1 - 3 * s, mx, y1 + 1)}.items():
        fill = P(ix, iy)
        expected = [f + 0.30 * (255 - f) for f in fill]
        got = P(bx, by)
        base_out, out = luma(B(ox, oy)), luma(P(ox, oy))
        sides[name] = {"stroke": list(got), "expected": [round(e) for e in expected],
                       "stroke_ok": max(abs(g - e) for g, e in zip(got, expected)) <= 10,
                       "shadow_1px": round(out / max(base_out, 1), 3),
                       "contrast": round(sum((a - b) ** 2 for a, b in zip(got, B(ox, oy))) ** 0.5, 1)}
    # Shadow profile right of the card, one sample per point.
    profile = [round(luma(P(x1 + 1 + int(k * s), my)) / max(luma(B(x1 + 1 + int(k * s), my)), 1), 3) for k in range(12)]
    def alpha(x, y, stroke, outside=None):
        # Projection of (pixel - outside) on (stroke - outside) in RGB: 0 outside, 1 on the
        # stroke. RGB, not brightness: on light themes the stroke is close in brightness to
        # the background. `outside` is the distance from the card edge in px; the outside
        # reference then carries the card's shadow (black 0.17, Gaussian sigma 4 pt).
        out = list(B(x, y))
        if outside is not None and outside > 0:
            out = [v * (1 - 0.17 * 0.5 * math.erfc(outside / (4 * s) / math.sqrt(2))) for v in out]
        d = [a - b for a, b in zip(stroke, out)]
        norm = sum(v * v for v in d)
        if norm <= 64:
            return None
        return sum((a - b) * c for a, b, c in zip(P(x, y), out, d)) / norm

    # Corners. Only the 1 pt stroke ring separates the card from the outside reliably (the
    # fill can match the window background), so per row from the corner, find where alpha
    # first rises through 0.4 coming from outside: the card's outer edge. Compare it with the
    # corner's shape: a circle, or Apple's continuous corner (PaintCode's published curve).
    r = radius * s
    n = int(1.6 * r) + 1
    reference = (circular_corner_edges if curve == "circle" else continuous_corner_edges)(r, n)
    # Distance along the edge's normal per pixel of horizontal error: near the tangent the
    # curve is flat, and a small brightness change moves a horizontal crossing a lot.
    normal = [1 / (1 + ((reference[min(j + 1, n - 1)] - reference[max(j - 1, 0)]) / 2) ** 2) ** 0.5 for j in range(n)]
    corners, curves = {}, {}
    for name, (cx, cy, sx, sy) in {"top_left": (x0, y0, 1, 1), "top_right": (x1, y0, -1, 1),
                                   "bottom_left": (x0, y1, 1, -1), "bottom_right": (x1, y1, -1, -1)}.items():
        curve, soft, errors = [], 0, []
        stroke_l = P(cx, cy + sy * (n + 3))  # the straight stroke right after this corner
        for j in range(n):
            row = [alpha(cx + sx * i, cy + sy * j, stroke_l, (reference[j] - (i + 0.5)) * normal[j]) for i in range(n + 2)]
            k = next((i for i, a in enumerate(row) if a is not None and a >= 0.4), None)
            if k is None or any(a is None for a in row[:k + 1]):
                curve.append(None)
                continue
            before = row[k - 1] if k > 0 else 0.0
            edge = (k - 1 + 0.5 + (0.4 - before) / max(row[k] - before, 1e-6)) if k > 0 else 0.0
            curve.append(round(edge, 2))
            errors.append(abs(edge - reference[j]) * normal[j])
            soft += k > 0 and 0.1 < row[k - 1] < 0.9 or 0.1 < row[k] < 0.9
        rows = [c for c in curve if c is not None]
        corners[name] = {"corner_alpha": round(alpha(cx, cy, stroke_l) or 0, 3), "edge_by_row": curve,
                         "reference": [round(v, 2) for v in reference],
                         "monotonic": all(b <= a + max(0.35, tolerance - 0.25) for a, b in zip(rows, rows[1:])),
                         "antialiased_rows": soft, "rows": len(rows),
                         "max_error_px": round(max(errors, default=9), 2)}
        curves[name] = curve
    sym = max(((max(c[j] for c in curves.values()) - min(c[j] for c in curves.values())) * normal[j]
               for j in range(n) if all(c[j] is not None for c in curves.values())), default=9)
    # A stroke within ~20 levels of the background (light themes: white 0.30 over a light
    # fill) is fainter than the shadow's own darkening; its edge cannot be located, so such
    # cards check the stroke, the shadow, and the edges only.
    low_contrast = min(v["contrast"] for v in sides.values()) < 20
    ok = (all(v["stroke_ok"] for v in sides.values())
          and (low_contrast or all(c["corner_alpha"] < 0.15 and c["monotonic"] and c["rows"] >= n - 1 and c["antialiased_rows"] >= r // 3
                  and c["max_error_px"] <= tolerance for c in corners.values()) and sym <= tolerance)
          and all(v["shadow_1px"] < 0.995 for v in sides.values())
          and (not page_right or (0.88 <= profile[0] <= 0.96 and profile[9] >= 0.99)))
    return {"ok": ok, "scale": s, "low_contrast": low_contrast, "sides": sides, "right_shadow_profile": profile, "corners": corners,
            "corner_symmetry_max": round(sym, 3)}


def white_fixture(name):
    return "data:text/html,<title>%s</title><body style='margin:0;background:white'><h1 style='margin:40px'>%s</h1>" % (name, name)


def place_away_from_cursor(app, width, height):
    """Moves the window where the hardware pointer is not: tracking areas follow the real
    pointer, so a pointer resting over the window would hover its controls during a check."""
    for x, y in ((60, 60), (1240, 60), (60, 600), (1240, 600), (600, 300)):
        app.call("window-frame", frame=[x, y, width, height])
        st = state_when(app, lambda st: st["frame"][2:] == [width, height]) or app.call("window-state")
        cx, cy = st["cursor"]
        if not (-20 <= cx <= width + 20 and -20 <= cy <= height + 20):
            return st
    return app.call("window-state")


def reveal_card_and_wait(app, x=3, y=400):
    app.call("mouse", action="move", x=700, y=y)
    app.call("mouse", action="move", x=x, y=y)
    return wait_card(app, True)


def card_pair(app, private, name):
    """Snapshot with the card settled and the same view after it left: (card PNG, base PNG, card frame).

    Both snapshots need the same window state: an inactive window lightens the theme
    underlay, so the window is made key again right before each one, and the pair is taken
    again (up to three times) when macOS left the two in different states."""
    wid = app.call("window-state")["id"]
    for _ in range(3):
        settled = reveal_card_and_wait(app)
        if not settled:
            return None
        card = settled["state"]["reveal"]["card"]
        png = os.path.join(private, name + ".png")
        app.call("mouse", action="move", x=120, y=400)
        app.call("window-focus", id=wid, activate=True)
        first = window_activity(app)
        app.call("snapshot", path=png)
        app.call("mouse", action="move", x=700, y=400)
        wait_card(app, False)
        base = os.path.join(private, name + "-base.png")
        app.call("window-focus", id=wid, activate=True)
        second = window_activity(app)
        app.call("snapshot", path=base)
        if first == second == window_activity(app):
            break
    return png, base, card


def window_activity(app):
    st = app.call("window-state")
    return st["key"], st["appActive"]


# Arc's dimmed window buttons at rest (docs/design.md section 2.2, interaction-states section 0):
# DimmedWindowControls over the background, with a faint ring in each button's color.
DIMMED_LOOK = {"light": ((0.0, 0.0, 0.0), 0.10, 0.06), "dark": ((243.0, 243.0, 234.1), 0.33, 0.34)}
RING_COLORS = {"light": [(219, 59, 60), (212, 162, 1), (47, 181, 19)], "dark": [(254, 129, 121), (255, 218, 9), (77, 221, 49)]}


def dimmed_look(png, scale, centers, mode, ring=True):
    """Core fill stays within ±5 levels of its composite. Dark rings use the measured
    session-2 r 6.5–7.5 band at ΔE00 <= 1, including rasterization/color management.
    A single anti-aliased edge pixel is not a plain token/background alpha blend.
    Inactive rings must be nearer the plain background than the active capture.
    Light rings remain too faint for this check (alpha 0.06)."""
    _, _, px = read_image(png, srgb=True)
    tok, fill_a, ring_a = DIMMED_LOOK[mode]
    rows, ok = [], True
    for index, (cx, cy) in enumerate(centers):
        core = [sum(px((cx + dx) * scale, (cy + dy) * scale)[k] for dx in (-1.5, -0.5, 0.5) for dy in (-1.5, -0.5, 0.5)) / 9 for k in range(3)]
        bg = [sum(px((cx + 11.5) * scale, (cy + dy) * scale)[k] for dy in (-2, 0, 2)) / 3 for k in range(3)]
        expected = [bg[k] * (1 - fill_a) + tok[k] * fill_a for k in range(3)]
        fill_err = max(abs(core[k] - expected[k]) for k in range(3))
        ring_px = px((cx - 6.5) * scale, cy * scale)
        ring_expected = [bg[k] * (1 - ring_a) + RING_COLORS[mode][index][k] * ring_a for k in range(3)]
        if mode == "dark":
            # Facts from S2 03/0003 and 05/0009 (docs/design.md §23.3), not the
            # implementation's ring token or a one-pixel compositing estimate.
            anchored = [[83.6041667, 56.5208333, 69.7083333], [83.1041667, 73.5, 56.9791667], [51.7291667, 74.5833333, 59.125]]
            floating = [[84.0833333, 57, 70.4166667], [84.0833333, 74.3541667, 57.8125], [53.5208333, 75.5833333, 60.6875]]
            ring_expected = (floating if centers[0][0] == 25 else anchored)[index]
            samples = [px(x, y) for y in range(int((cy-8)*scale), int((cy+8)*scale))
                       for x in range(int((cx-8)*scale), int((cx+8)*scale))
                       if 6.5 <= math.hypot((x+.5)/scale-cx, (y+.5)/scale-cy) < 7.5]
            ring_px = [statistics.mean(c[k] for c in samples) for k in range(3)]
            ring_err = chrome_delta_e(ring_px, ring_expected)
            plain_err = chrome_delta_e(ring_px, bg)
            ring_ok = ring_err <= 1 if ring else plain_err < ring_err
        else:
            ring_err = max(abs(ring_px[k] - ring_expected[k]) for k in range(3))
            plain_err = max(abs(ring_px[k] - bg[k]) for k in range(3))
            ring_ok = True
        good = fill_err <= 5 and ring_ok
        ok = ok and good
        rows.append({"center": [cx, cy], "core": [round(v) for v in core], "expected": [round(v) for v in expected],
                     "fill_error": round(fill_err, 1), "ring": list(ring_px), "ring_expected": [round(v) for v in ring_expected],
                     "ring_error": round(ring_err, 1), "plain_error": round(plain_err, 1), "ring_expected_shown": ring, "ok": good})
    return ok, rows


def colored_look(png, scale, centers):
    """The system buttons in color at each center (key window, pointer over the group): red
    (R − G ≥ 60), yellow (R and G − B ≥ 60), green (G − R ≥ 60). macOS's own grey buttons
    (an inactive window) and the dimmed look both fail."""
    _, _, px = read_image(png)
    rows, ok = [], True
    for index, (cx, cy) in enumerate(centers):
        r, g, b = [sum(px((cx + dx) * scale, (cy + dy) * scale)[k] for dx in (-1.5, -0.5, 0.5) for dy in (-1.5, -0.5, 0.5)) / 9 for k in range(3)]
        margin = (r - g, min(r, g) - b, g - r)[index]
        good = margin >= 60
        ok = ok and good
        rows.append({"center": [cx, cy], "core": [round(r), round(g), round(b)], "hue_margin": round(margin, 1), "ok": good})
    return ok, rows


def ensure_key(app, wid, timeout=15, *, activation_timeout=5):
    """Wait for native key readiness until the deadline; return the last state even on expiry.

    This is a readiness wait, not another attempt at the caller's behavior check.
    Foreground interruptions and errors other than native not-ready still abort.
    """
    app.begin_timing("key-window readiness")
    started = time.monotonic()
    deadline = started + timeout
    attempt = 0
    while True:
        attempt += 1
        not_ready = None
        try:
            # Bound the native wait by the remaining outer budget, including
            # the last attempt. The native default remains five seconds.
            app.call("window-focus", id=wid, activate=True,
                     readinessTimeout=min(5, activation_timeout, max(0, deadline - time.monotonic())))
        except FocusInterruption:
            raise
        except RuntimeError as error:
            if not str(error).startswith("window-focus: key focus not ready:"):
                raise
            not_ready = str(error)
        st = app.call("window-state", id=wid)
        now = time.monotonic()
        print("key-window readiness " + json.dumps({
            "attempt": attempt, "elapsed_s": now - started, "remaining_s": max(0, deadline - now),
            "state": {key: st.get(key) for key in (
                "appActive", "key", "keyWindow", "number", "keySameObject", "fullscreenTransition",
                "onActiveSpace", "canBecomeKey", "attachedSheet", "childWindows", "windowClass")},
            "not_ready": not_ready, "load_average": list(os.getloadavg()),
        }, sort_keys=True), flush=True)
        if (st["key"] and st["appActive"] and st["keySameObject"] and not st["fullscreenTransition"]) or now >= deadline:
            return st
        time.sleep(min(0.25, deadline - now))


def traffic_light_look_checks(app, results, private, scale, wid):
    """The window buttons' rest look, hover, not-key look, card, AX, actions, and the hover
    state across full screen, minimize, and a sidebar hide."""
    def state():
        return app.call("window-state")
    def buttons_ok(st, dimmed):
        alpha = [b["alpha"] for b in st["trafficLightButtons"]]
        ax = [(x["role"], x["subrole"]) for x in st["axWindowButtons"]]
        # At rest 0.001, not 0: AppKit ignores a window button at alpha 0.
        return (st["trafficLightsDimmed"] == dimmed and all(abs(a - (0.001 if dimmed else 1)) < 0.0005 for a in alpha) and len(alpha) == 3
                and ax[:3] == [("AXButton", "AXCloseButton"), ("AXButton", "AXMinimizeButton"), ("AXButton", "AXFullScreenButton")]), alpha, ax
    def shot(name, window=None):
        path = os.path.join(private, "lights-%s.png" % name)
        if window is None:
            app.call("snapshot", path=path)
        else:
            app.call("snapshot", path=path, window=window)
        return path
    def drawn_settled():
        """Waits until the buttons are placed and one display cycle has drawn them (see
        `click_button`), before a snapshot of the hover look."""
        placed = state_when(app, lambda st: light_centers(st)[0], timeout=2)
        time.sleep(0.15)
        return bool(placed)
    def click_button(x, y, modifiers=None):
        """Hover, then click once the buttons are where the next frame draws them. A synthetic
        enter on the title bar starts AppKit's own button layout, which can hold the buttons at
        its default spots until a later layout pass; real input only arrives after display
        cycles, which place them (the drawn centers stay at x 20 / 43 / 66, y 24)."""
        app.call("mouse", action="hover", x=x, y=y)
        placed = state_when(app, lambda st: light_centers(st)[0], timeout=2)
        if modifiers:
            app.call("mouse", action="click", x=x, y=y, modifiers=modifiers)
        else:
            app.call("mouse", action="click", x=x, y=y)
        return bool(placed)
    rows = {}
    for mode in ("light", "dark"):
        app.call("appearance", name=mode)
        app.call("mouse", action="hover", x=700, y=400)
        rest = ensure_key(app, wid)
        time.sleep(0.3)
        rest = state()
        rest_ok, alpha, ax = buttons_ok(rest, True)
        png = shot("%s-rest" % mode)
        look_ok, look = dimmed_look(png, scale, LIGHT_CENTERS, mode, ring=rest["key"])
        # Hover: the system buttons in color. The synthetic pointer gets macOS's colors only in
        # a key window (an inactive window's buttons stay grey), so the row needs key.
        hover_key = ensure_key(app, wid)["key"]
        app.call("mouse", action="hover", x=43, y=24)
        hover = state_when(app, lambda st: not st["trafficLightsDimmed"], timeout=2) or state()
        hover_ok, hover_alpha, _ = buttons_ok(hover, False)
        drawn_settled()
        hpng = shot("%s-hover" % mode)
        hue_ok, hue = colored_look(hpng, scale, LIGHT_CENTERS)
        app.call("mouse", action="hover", x=700, y=400)
        left = state_when(app, lambda st: st["trafficLightsDimmed"], timeout=2)
        # Controls: the checks reject the wrong look. The rest image is not colored; on dark
        # content in a key window, its rings fail the not-key expectation.
        control_hue = not colored_look(png, scale, LIGHT_CENTERS)[0]
        control_ring = mode == "light" or not rest["key"] or not dimmed_look(png, scale, LIGHT_CENTERS, mode, ring=False)[0]
        # Not key: a second window in front; the first keeps the look, without rings.
        app.call("key", key="n", modifiers=["cmd"], route="app")
        second = state_when(app, lambda st: st["id"] != wid) or state()
        first = app.call("window-state", id=wid)
        npng = shot("%s-notkey" % mode, window=first["number"])
        notkey_ok, notkey = dimmed_look(npng, scale, LIGHT_CENTERS, mode, ring=first["key"])
        app.call("window-close")
        state_when(app, lambda st: st["id"] == wid)
        ensure_key(app, wid)
        # On the hover-reveal card.
        app.call("key", key="s", modifiers=["cmd"], route="app")
        sidebar_hidden(app)
        hidden = state()
        card = reveal_card_and_wait(app)
        app.call("mouse", action="move", x=150, y=400)
        cpng = shot("%s-card" % mode)
        card_state = state()
        card_ok, card_look = dimmed_look(cpng, scale, [[x + 5, y + 5] for x, y in LIGHT_CENTERS], mode, ring=card_state["key"])
        app.call("mouse", action="move", x=700, y=400)
        wait_card(app, False)
        app.call("key", key="s", modifiers=["cmd"], route="app")
        sidebar_anchored(app)
        rows[mode] = {"ok": rest_ok and look_ok and hover_key and hover_ok and hue_ok and bool(left) and control_hue and control_ring
                      and not first["trafficLightsHovered"] and first["trafficLightsDimmed"] and notkey_ok
                      and all(hidden["trafficLightsHidden"]) and bool(card) and card_ok and card_state["trafficLightsDimmed"],
                      "rest_alpha": alpha, "ax": ax, "rest_look": look, "key_during_rest": rest["key"],
                      "hover": {"key": hover_key, "alpha": hover_alpha, "hue": hue,
                                "reason": None if hover_key else "window not key: macOS refused to activate Open (someone is using another app)"},
                      "dimmed_after_leaving": bool(left), "controls_reject": {"rest_as_colored": control_hue, "rings_as_not_key": control_ring},
                      "not_key": {"key": first["key"], "dimmed": first["trafficLightsDimmed"], "look": notkey},
                      "hidden_with_sidebar": hidden["trafficLightsHidden"], "card_look": card_look}
    app.call("appearance", name="system")
    # The hover region: each button and both gaps hold the hover (no flicker walking across);
    # points just outside the group do not.
    ensure_key(app, wid)
    app.call("mouse", action="hover", x=700, y=400)
    state_when(app, lambda st: st["trafficLightsDimmed"], timeout=2)
    inside, outside = {}, {}
    for x, y in ((20, 24), (31.5, 24), (43, 24), (54.5, 24), (66, 24)):
        app.call("mouse", action="hover", x=x, y=y)
        st = state_when(app, lambda st: not st["trafficLightsDimmed"], timeout=1) or state()
        inside["%g,%g" % (x, y)] = st["trafficLightsHovered"] and not st["trafficLightsDimmed"]
    for x, y in ((12.5, 24), (73.5, 24), (43, 16.5), (43, 31.5)):
        app.call("mouse", action="hover", x=43, y=24)
        state_when(app, lambda st: not st["trafficLightsDimmed"], timeout=1)
        app.call("mouse", action="hover", x=x, y=y)
        st = state_when(app, lambda st: st["trafficLightsDimmed"], timeout=1) or state()
        outside["%g,%g" % (x, y)] = st["trafficLightsDimmed"] and not st["trafficLightsHovered"]
    app.call("mouse", action="hover", x=700, y=400)
    region_ok = all(inside.values()) and all(outside.values())
    results["traffic_light_look"] = {"ok": all(r["ok"] for r in rows.values()) and region_ok, "rows": rows,
                                     "hover_region": {"inside": inside, "outside": outside}}
    # Actions on the real buttons: Option-click zoom zooms and restores.
    ensure_key(app, wid)
    before = state()
    click_button(66, 24, ["option"])
    zoomed = state_when(app, lambda st: st["zoomed"] and not st["fullscreen"], timeout=4)
    click_button(66, 24, ["option"])
    restored = state_when(app, lambda st: not st["zoomed"] and st["frame"] == before["frame"], timeout=4)
    app.call("mouse", action="hover", x=700, y=400)
    results["traffic_light_actions"] = {"ok": bool(zoomed) and bool(restored),
                                        "option_click_zoomed": bool(zoomed) and zoomed["frame"], "option_click_restored": bool(restored),
                                        "tiling_menu": {"status": "SKIP", "reason": "macOS opens it for the hardware pointer resting on the green button; synthetic events do not reach it"}}
    # The hover state after the buttons went away with the pointer on them. Each case checks
    # the look before any further pointer event (an exit would hide a stale state).
    def at_rest(name):
        st = state_when(app, lambda st: st["trafficLightsDimmed"], timeout=2) or state()
        ok, look = dimmed_look(shot(name), scale, LIGHT_CENTERS, "dark", ring=st["key"])
        return {"ok": st["trafficLightsDimmed"] and not st["trafficLightsHovered"] and ok, "dimmed": st["trafficLightsDimmed"],
                "hovered": st["trafficLightsHovered"], "key": st["key"], "look": look}
    stale = {}
    def brief(st):
        return {k: st.get(k) for k in ("trafficLightsDimmed", "trafficLightsHovered", "key", "appActive", "fullscreen", "zoomed",
                                        "miniaturized", "frame", "automationPointer", "trafficLightFrames")} | {"alpha": [b["alpha"] for b in st["trafficLightButtons"]]}
    app.call("appearance", name="dark")  # dark content: the rings are checked too
    # (1) A click on the green button enters full screen; the pointer moves away there; the
    # command exits full screen.
    ensure_key(app, wid)
    app.call("mouse", action="hover", x=66, y=24)
    pre_click = brief(state())
    click_button(66, 24)
    post_click = brief(state())
    full = state_when(app, lambda st: st["fullscreen"] and not st["fullscreenTransition"], timeout=15, step=0.1)
    full_alpha = full and [b["alpha"] for b in full["trafficLightButtons"]]
    app.call("mouse", action="move", x=700, y=400)
    app.call("window-fullscreen")
    back = state_when(app, lambda st: not st["fullscreen"] and not st["fullscreenTransition"], timeout=15, step=0.1)
    stale["full_screen_exit"] = dict(at_rest("stale-fullscreen"), entered=bool(full), full_screen_alpha=full_alpha, before_click=pre_click, after_click=post_click,
                                     full_screen_dimmed=bool(full) and full["trafficLightsDimmed"], exited=bool(back))
    stale["full_screen_exit"]["ok"] = (stale["full_screen_exit"]["ok"] and bool(full) and full_alpha == [1, 1, 1]
                                       and not full["trafficLightsDimmed"] and bool(back))
    # (1b) The same, with the pointer left on the green button: the window comes back under
    # it (a resting pointer), so the buttons show in color without any pointer event.
    ensure_key(app, wid)
    click_button(66, 24)
    full_over = state_when(app, lambda st: st["fullscreen"] and not st["fullscreenTransition"], timeout=15, step=0.1)
    app.call("window-fullscreen")
    back_over = state_when(app, lambda st: not st["fullscreen"] and not st["fullscreenTransition"], timeout=15, step=0.1)
    over = state_when(app, lambda st: st["trafficLightsHovered"] and not st["trafficLightsDimmed"], timeout=2) or state()
    drawn_settled()
    over_hue_ok, over_hue = colored_look(shot("stale-fullscreen-over"), scale, LIGHT_CENTERS)
    app.call("mouse", action="hover", x=700, y=400)
    over_left = state_when(app, lambda st: st["trafficLightsDimmed"], timeout=2)
    stale["full_screen_exit_pointer_over"] = {"ok": bool(full_over) and bool(back_over) and over["trafficLightsHovered"]
                                              and not over["trafficLightsDimmed"] and over["key"] and over_hue_ok and bool(over_left),
                                              "entered": bool(full_over), "exited": bool(back_over), "hovered": over["trafficLightsHovered"],
                                              "dimmed": over["trafficLightsDimmed"], "key": over["key"], "hue": over_hue,
                                              "dimmed_after_leaving": bool(over_left)}
    # (2) A click on the yellow button minimizes; the pointer moves away; the Dock restores.
    ensure_key(app, wid)
    click_button(43, 24)
    mini = state_when(app, lambda st: st["miniaturized"], timeout=5, step=0.1)
    app.call("mouse", action="move", x=700, y=400)
    app.call("window-deminiaturize")
    up = state_when(app, lambda st: not st["miniaturized"], timeout=5, step=0.1)
    time.sleep(0.4)
    stale["minimize_restore"] = dict(at_rest("stale-minimize"), minimized=bool(mini), restored=bool(up))
    stale["minimize_restore"]["ok"] = stale["minimize_restore"]["ok"] and bool(mini) and bool(up)
    # (3) Cmd+S hides the sidebar with the pointer on the buttons; the pointer moves away;
    # Cmd+S shows it; the pointer comes back over the buttons.
    ensure_key(app, wid)
    app.call("mouse", action="hover", x=43, y=24)
    hovered = state_when(app, lambda st: st["trafficLightsHovered"], timeout=1)
    app.call("key", key="s", modifiers=["cmd"], route="app")
    sidebar_hidden(app)
    app.call("mouse", action="hover", x=700, y=400)
    app.call("key", key="s", modifiers=["cmd"], route="app")
    sidebar_anchored(app)
    shown = at_rest("stale-hide-shown")
    ensure_key(app, wid)
    app.call("mouse", action="hover", x=43, y=24)
    again = state_when(app, lambda st: st["trafficLightsHovered"] and not st["trafficLightsDimmed"], timeout=2) or state()
    drawn_settled()
    hue_ok, hue = colored_look(shot("stale-hide-rehover"), scale, LIGHT_CENTERS)
    app.call("mouse", action="hover", x=700, y=400)
    left = state_when(app, lambda st: st["trafficLightsDimmed"], timeout=2)
    stale["hide_rehover"] = {"ok": bool(hovered) and shown["ok"] and again["trafficLightsHovered"] and not again["trafficLightsDimmed"]
                             and hue_ok and bool(left), "hovered_before": bool(hovered), "after_show": shown,
                             "rehover": {"hovered": again["trafficLightsHovered"], "dimmed": again["trafficLightsDimmed"], "key": again["key"], "hue": hue},
                             "dimmed_after_leaving": bool(left)}
    app.call("appearance", name="system")
    results["traffic_light_stale_hover"] = {"ok": all(v["ok"] for v in stale.values()), "cases": stale}


def chrome_delta_e(c1, c2):
    """CIEDE2000 on sRGB -> Lab D65; same math as sidebar-render ColorMath."""
    def lab(c):
        r, g, b = [v / 255 / 12.92 if v / 255 <= .04045 else ((v / 255 + .055) / 1.055) ** 2.4 for v in c]
        x = (.4124564*r + .3575761*g + .1804375*b) / .95047
        y = .2126729*r + .7151522*g + .072175*b
        z = (.0193339*r + .119192*g + .9503041*b) / 1.08883
        def f(t): return t ** (1/3) if t > (6/29)**3 else t / (3*(6/29)**2) + 4/29
        return 116*f(y)-16, 500*(f(x)-f(y)), 200*(f(y)-f(z))
    L1,a1,b1=lab(c1); L2,a2,b2=lab(c2)
    C=(math.hypot(a1,b1)+math.hypot(a2,b2))/2
    G=.5*(1-math.sqrt(C**7/(C**7+25**7)))
    a1*=1+G; a2*=1+G
    C1=math.hypot(a1,b1); C2=math.hypot(a2,b2)
    h1=math.degrees(math.atan2(b1,a1))%360; h2=math.degrees(math.atan2(b2,a2))%360
    dh=h2-h1
    if C1*C2==0: dh=0
    elif dh>180: dh-=360
    elif dh< -180: dh+=360
    dH=2*math.sqrt(C1*C2)*math.sin(math.radians(dh/2))
    L=(L1+L2)/2; C=(C1+C2)/2
    h=h1+h2
    if C1*C2!=0: h=(h+(360 if h<360 else -360))/2 if abs(h1-h2)>180 else h/2
    cos=lambda x:math.cos(math.radians(x))
    T=1-.17*cos(h-30)+.24*cos(2*h)+.32*cos(3*h+6)-.20*cos(4*h-63)
    Sl=1+.015*(L-50)**2/math.sqrt(20+(L-50)**2); Sc=1+.045*C; Sh=1+.015*C*T
    Rt=-math.sin(math.radians(60*math.exp(-((h-275)/25)**2)))*2*math.sqrt(C**7/(C**7+25**7))
    dl=(L2-L1)/Sl; dc=(C2-C1)/Sc; dh=dH/Sh
    return math.sqrt(dl*dl+dc*dc+dh*dh+Rt*dc*dh)


def chrome_ring(png, center, inner=6.5, outer=7.5):
    w, _, px = read_image(png, srgb=True)
    scale = w / 1728
    cx, cy = center
    colors = [px(x,y) for y in range(int((cy-8)*scale), int((cy+8)*scale))
              for x in range(int((cx-8)*scale), int((cx+8)*scale))
              if inner <= math.hypot((x+.5)/scale-cx, (y+.5)/scale-cy) < outer]
    return [statistics.mean(c[k] for c in colors) for k in range(3)]


def chrome_capture_comparison(snapshots):
    common = subprocess.check_output(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, text=True).strip()
    capture_root = os.environ.get("OPEN_ARC_CAPTURE_ROOT", os.path.join(os.path.dirname(os.path.realpath(os.path.join(ROOT, common))), ".re"))
    sessions = os.path.join(capture_root, "runtime", "sessions")
    rows=[]; rings=[]; profiles=[]
    for name, session, frame, edge, sample in [
            ("rest-364", "20261026-100848-03-active-window", 3, 364, (8,600)),
            ("mid-drag-164", "20261026-101147-06-sidebar-width", 29, 164, (8,600)),
            ("hidden-held", "20261026-101147-06-sidebar-width", 53, 10, (4,600)),
            ("cmd-s-restored", "20261026-101147-06-sidebar-width", 66, 228, (8,600)),
            ("card-revealed", "20261026-101324-05-reveal-card", 9, 233, (100,600))]:
        captures=glob.glob(os.path.join(sessions,session,"%04d-*"%frame,"win-70352.png"))
        if not captures: return {"status":"SKIP", "reason":"capture session 2 frames absent"}, {}
        arc=captures[0]; ours=os.path.join(snapshots,name+".png")
        aw,ah,A=read_image(arc,srgb=True); ow,oh,O=read_image(ours,srgb=True); scale=ow/aw
        def mean(P, x,y,s):
            return [statistics.mean(P((x+dx)*s,(y+dy)*s)[k] for dx in range(-1,2) for dy in range(-1,2)) for k in range(3)]
        ca=mean(A,*sample,1); co=mean(O,*sample,scale)
        def white_edge(P,s):
            return next(x for x in range(1,600) if min(P(x*s,600*s)) >= 230)
        ae=white_edge(A,1); oe=white_edge(O,scale)
        rows.append({"state":name,"capture":"S2 %s/%04d"%(session.split('-')[2],frame),
            "position_error_pt":abs(ae-oe),"implementation_error_pt":abs(edge-oe),"interim_floor":False,"arc_edge":ae,"open_edge":oe,
            "arc_rgb":ca,"open_rgb":co,"delta_e00":chrome_delta_e(ca,co)})
        if name in ("rest-364","card-revealed"):
            inset=5 if name=="card-revealed" else 0
            for label,x in (("close",20),("minimize",43),("zoom",66)):
                c=(x+inset,24+inset); ca=chrome_ring(arc,c); co=chrome_ring(ours,c)
                if label != "close":
                    rings.append({"state":name,"button":label,"arc_rgb":ca,"open_rgb":co,"delta_e00":chrome_delta_e(ca,co)})
                profiles.append({"state":name,"button":label,"non_gating":True,"half_bands":[
                    {"band":[lo,hi],"delta_e00":chrome_delta_e(chrome_ring(arc,c,lo,hi),chrome_ring(ours,c,lo,hi))}
                    for lo,hi in ((6.5,7),(7,7.5))]})
    return ({"ok":all((r["implementation_error_pt"] if r["interim_floor"] else r["position_error_pt"])<=1 and (r["state"] == "card-revealed" or r["delta_e00"]<=2) for r in rows),
             "color_scope":"Anchored/hidden background samples; card material is deferred to Part B, retained below without acceptance.", "rows":rows},
            {"ok":all(r["delta_e00"]<=1 for r in rings),"band":"6.5 <= r < 7.5 pt", "rows":rings, "non_gating_stroke_profile":profiles, "scale_scope":"1x proven; 2x M1 unproven (followups: Verification portability)"})


def scheduled_spring(a, response, damping, path=None, relative_to_group=False):
    """Check the spring read back from the real layer, including its scheduled lifetime.

    S2 §20.12 fits response R, not CA's settlingDuration: Space R=0.20 s,
    visually settled at about 0.27 s (21-motion.mov 35.05 / 43.63 s).
    """
    mass, stiffness, friction = (a.get(k, 0) for k in ("mass", "stiffness", "physicalDamping"))
    if mass <= 0 or stiffness <= 0:
        return False
    # CAAnimationGroup children use a relative beginTime; the group owns the
    # absolute requestedAt/scheduledDelay pair checked by the caller.
    delay = a.get("beginTime", -1) if relative_to_group else a.get("scheduledDelay", -1)
    return (a.get("type") == "CASpringAnimation"
            and abs(2 * math.pi / math.sqrt(stiffness / mass) - response) < 1e-6
            and abs(friction / (2 * math.sqrt(stiffness * mass)) - damping) < 1e-6
            and abs(a.get("response", 0) - response) < 1e-6
            and abs(a.get("damping", 0) - damping) < 1e-6 and a.get("initialVelocity") == 0
            and a.get("settlingDuration", 0) > 0
            and abs(a.get("duration", 0) - a["settlingDuration"]) < 1e-6
            and 0 <= delay <= 1/60
            and (path is None or a.get("keyPath") == path))


def window_chrome_followup_checks(factory, results, tmp):
    """App-shell §3.3. All input enters OEApplication.sendEvent, including held drags."""
    private = tempfile.mkdtemp(prefix="window-chrome-104-", dir=tmp)
    app = factory(urls=(white_fixture("Window chrome"),), fresh=True)
    down = False
    snapshot_methods = {}
    def state():
        return app.call("window-state")
    def pointer(action, x, count=1):
        nonlocal down
        if action == "down": down = True
        app.call("mouse", action=action, x=x, y=400, clickCount=count)
        if action == "up": down = False
        return state()
    def drag(start, end):
        pointer("down", start)
        pointer("drag", end)
        return pointer("up", end)
    def key():
        app.call("key", key="s", modifiers=["cmd"], route="app")
        return state()
    def settled():
        return wait_until(lambda: not app.call("window-motion")["active"]["sidebar"], timeout=3, step=.01)
    def spring(a, response, damping, path=None, relative_to_group=False):
        return scheduled_spring(a, response, damping, path, relative_to_group)
    def snap(name):
        path = os.path.join(private, name + ".png")
        receipt = app.call("snapshot", path=path)
        snapshot_methods[name] = receipt["method"]
        return path
    try:
        app.call("window-focus", id=state()["id"], activate=True)
        app.call("window-frame", frame=[40, 40, 1728, 1084], unconstrained=True)
        app.call("wait", tab=app.call("tabs")[0]["id"])
        app.call("appearance", name="dark")
        app.call("mouse", action="hover", x=700, y=400)
        app.call("window-motion", reduced=False, sampleCard=True)
        drag(228, 364)
        rest_png = snap("rest-364")
        before = state(); saves = app.call("frame-save-counters")["scheduled"]
        pointer("down", 364)
        high = pointer("drag", 700)
        low = pointer("drag", 150)
        mid_png = snap("mid-drag-164")
        toolbar = low["toolbarFrames"]
        lights_right = max(r[0]+r[2] for r in low["trafficLightFrames"])
        # Measured floor 164 with the compact toolbar (S2 06/0029): Back, Forward, More options
        # at [W − 90 / W − 62 / W − 34, 9, 28, 28]; Back starts where the zoom button ends.
        results["width_toolbar_floor"] = {"ok":low["sidebarLiveWidth"]==164 and low["toolbarButtons"]==["back","forward","more"]
            and toolbar["back"]==[74,9,28,28] and toolbar["forward"]==[102,9,28,28] and toolbar["more"]==[130,9,28,28]
            and toolbar["back"][0]>=lights_right,
            "floor":low["sidebarLiveWidth"],"toolbar":toolbar,"buttons":low["toolbarButtons"],"traffic_lights_right":lights_right}
        edge = pointer("drag", 82)
        results["width_live_limits"] = {"ok": high["sidebarLiveWidth"] == 500 and high["panel"][0] == 500
            and low["sidebarLiveWidth"] == edge["sidebarLiveWidth"] == 164 and edge["sidebarMode"] == "anchored"
            and all(s["sidebarWidth"] == 364 and s["sidebarWidthCommits"] == before["sidebarWidthCommits"] for s in (high, low, edge))
            and app.call("frame-save-counters")["scheduled"] == saves,
            "high": high["sidebarLiveWidth"], "low": low["sidebarLiveWidth"], "model": edge["sidebarWidth"]}
        gone = pointer("drag", 81)
        hide_motion = app.call("window-motion")
        results["width_hide_while_pressed"] = {"ok": gone["sidebarResizeActive"] and gone["sidebarMode"] == "hidden"
            and gone["panel"][0] == 10 and gone["sidebarWidth"] == 364
            and spring(hide_motion["sidebar"].get("sidebar", {}), .1, .95), "state": gone}
        back = pointer("drag", 82)
        results["width_show_before_release"] = {"ok": back["sidebarResizeActive"] and back["sidebarMode"] == "anchored"
            and back["sidebarLiveWidth"] == 164 and back["panel"][0] == 164 and back["sidebarWidth"] == 364}
        visible = pointer("up", 82)
        after_save = app.call("frame-save-counters")["scheduled"]
        results["width_visible_commit_once"] = {"ok": visible["sidebarWidth"] == 164
            and visible["sidebarWidthCommits"] == before["sidebarWidthCommits"] + 1 and after_save == saves + 1,
            "scheduled_delta": after_save - saves}
        settled()
        drag(164, 364)
        before = state(); saves = app.call("frame-save-counters")["scheduled"]
        pointer("down", 364); pointer("drag", 60)
        settled(); hidden_png = snap("hidden-held")
        hidden = pointer("up", 60)
        results["width_hidden_commit"] = {"ok": hidden["sidebarMode"] == "hidden" and hidden["sidebarWidth"] == 364
            and hidden["sidebarWidthCommits"] == before["sidebarWidthCommits"]
            and hidden["sidebarGestureHides"] == before["sidebarGestureHides"] + 1
            and app.call("frame-save-counters")["scheduled"] == saves + 1,
            "width": hidden["sidebarWidth"], "gestures": hidden["sidebarGestureHides"] - before["sidebarGestureHides"]}
        shown = key(); show_motion = app.call("window-motion")
        settled()
        results["width_cmd_s_restores_start"] = {"ok": shown["sidebarMode"] == "anchored" and shown["sidebarWidth"] == 364 and shown["panel"][0] == 364}
        drag(364, 228)
        key(); settled(); key(); settled(); show_png = snap("cmd-s-restored")
        key(); settled()
        app.begin_timing("Cmd+S show snapshot at 25ms")
        slide_png = os.path.join(private,"show-25ms.png")
        slide = app.call("snapshot",path=slide_png,toggleSidebar=True)
        sw,_,SP = read_image(slide_png); ss=sw/1728
        white = [x for x in range(sw) if min(SP(x,600*ss))>=230]
        left,right=min(white)/ss,(max(white)+1)/ss
        results["motion_show_panel_right_edge"] = {"ok":slide["method"]=="windowserver+devtools" and 10<left<227 and abs(right-1718)<=1,
            "left_pt":left,"right_pt":right,"snapshot":slide,"requested_after_key_s":.025,
            "capture_lateness_s":slide.get("capturedAfterKey",.025)-.025,"load_average":list(os.getloadavg())}
        print("show at25ms:",results["motion_show_panel_right_edge"],flush=True)
        settled()
        reset_rows = []
        for width in (364, 500):
            drag(state()["sidebarWidth"], width)
            before = state(); saves = app.call("frame-save-counters")["scheduled"]
            pointer("down", width); pointer("up", width)
            pointer("down", width, count=2); reset = pointer("up", width, count=2)
            reset_rows.append({"from": width, "width": reset["sidebarWidth"],
                "commits": reset["sidebarWidthCommits"] - before["sidebarWidthCommits"],
                "geometry": reset["sidebarGeometryChanges"] - before["sidebarGeometryChanges"],
                "saves": app.call("frame-save-counters")["scheduled"] - saves,
                "animations": app.call("window-motion")["active"]})
        results["width_double_click_reset"] = {"ok": all(r["width"] == 228 and r["commits"] == r["geometry"] == r["saves"] == 1
            and r["animations"] == {"panel": [], "sidebar": []} for r in reset_rows), "rows": reset_rows}
        key(); toggle_hide = app.call("window-motion")
        settled(); key(); toggle_show = app.call("window-motion")
        motions = [hide_motion, show_motion, toggle_hide, toggle_show]
        results["motion_sidebar_toggle"] = {"ok": all(spring(m["sidebar"].get("sidebar", {}), .1, .95, "transform.translation.x")
            and all(spring(a, .1, .95, relative_to_group=True) for a in m["sidebar"].get("panel", {}).get("children", []))
            and len(m["sidebar"].get("panel", {}).get("children", [])) == 2
            and 0<=m["sidebar"].get("panel",{}).get("scheduledDelay",-1)<=1/60
            and m["tokens"]["sidebarToggle"] == {"response": .1, "damping": .95} for m in motions),
            "scheduled": [m["sidebar"] for m in motions]}
        settled()
        app.call("window-motion", sidebarDelay=.29)
        key(); delayed=app.call("window-motion")["sidebar"].get("panel",{})
        results["motion_delay_negative_control"] = {"ok":.29<=delayed.get("scheduledDelay",-1)<.31,
            "scheduled":delayed,"injected_begin_time_delay":.29}
        settled();app.call("window-motion",sidebarDelay=0);key();settled()
        results["motion_end_frame_curves"] = {"ok":abs(toggle_show["toggleRemainderAt130ms"])<=.5 and abs(toggle_show["spaceRemainderAt300ms"])<=.5,
            "toggle_130ms_pt":toggle_show["toggleRemainderAt130ms"],"space_300ms_pt":toggle_show["spaceRemainderAt300ms"]}
        settled()
        drag(state()["sidebarWidth"],364)
        pointer("down",364);pointer("drag",60);pointer("up",60)
        flick=app.call("window-motion")
        results["motion_hide_release_continues"] = {"ok":"sidebarToggle" in flick["active"]["panel"],"active":flick["active"]}
        settled();key();settled();drag(state()["sidebarWidth"],228)
        settled(); key(); settled()
        reveal_card_and_wait(app)
        card_in = app.call("window-motion")
        curve = card_in["cardCurve"]
        results["motion_card_in_token"] = {"ok": spring(card_in["card"].get("card", {}), .164, .81, "transform.translation.x")
            and spring(card_in["card"].get("shadow", {}), .164, .81)
            and card_in["tokens"]["revealCardIn"] == {"response": .164, "damping": .81}
            and abs(curve[0]["pastRest"]) < .15 and 2.7 <= curve[1]["pastRest"] <= 3.1 and abs(curve[2]["pastRest"]) <= .5,
            "curve": curve, "scheduled": card_in["card"]}
        samples = wait_until(lambda: (lambda m: m["cardSamples"] if m["cardSamples"] and m["cardSamples"][-1]["time"] >= .3 else None)(app.call("window-motion")), timeout=3, step=.01) or []
        peak = max((s["offset"] for s in samples), default=0)
        peak_time = max(samples, key=lambda s: s["offset"])["time"] if samples else None
        lateness = peak_time - .140 if peak_time is not None else None
        load = list(os.getloadavg())
        print("card peak: %.3f pt; peak lateness: %s s; load average: %s" % (peak, lateness, load), flush=True)
        results["motion_card_real_peak"] = {"ok": peak >= 2, "past_rest_pt": peak, "peak_lateness_s": lateness, "samples": samples, "load_average": load}
        app.call("mouse", action="hover", x=120, y=400)
        card_png = snap("card-revealed")
        app.call("mouse", action="move", x=700, y=400); wait_card(app, False)
        card_out = app.call("window-motion")
        out = card_out["card"].get("card", {})
        app.call("mouse", action="move", x=3, y=400)
        interrupt = state_when(app, lambda st: st["revealed"] and st["reveal"]["offset"] is not None and -222 < st["reveal"]["offset"] < -5, timeout=3, step=.004)
        app.call("select", tab=app.call("tabs")[0]["id"])
        interrupted_out = app.call("window-motion")["card"].get("card", {})
        wait_card(app, False)
        results["motion_card_out_token"] = {"ok": bool(interrupt) and -223 < interrupted_out.get("from", 0) < -1 and out.get("type") == "CABasicAnimation" and out.get("duration") == .105
            and out.get("timing") == [[0, 0], [0.41999998688697815, 0], [0.5799999833106995, 1], [1, 1]]
            and card_out["tokens"]["revealCardOut"] == .105, "scheduled": out, "interrupted_from": interrupted_out.get("from")}
        key(); settled()
        app.call("space-create", title="Motion Space")
        switched = wait_until(lambda: app.call("window-motion")["space"], timeout=3, step=.01) or {}
        results["motion_space_switch"] = {"ok": spring(switched, .2, 1, "position.x"), "scheduled": switched}
        # Reduce Motion uses the same real input and frame paths, with no animated slide/fade.
        app.call("window-motion", reduced=True)
        key(); reduced_hide = app.call("window-motion")
        reveal_card_and_wait(app); reduced_card = app.call("window-motion")
        app.call("mouse", action="move", x=700, y=400); wait_card(app, False)
        key(); reduced_show = app.call("window-motion")
        app.call("space-create", title="Reduced Motion Space")
        reduced_space = app.call("window-motion")
        results["motion_reduce_motion"] = {"ok": reduced_hide["sidebar"] == reduced_show["sidebar"] == reduced_card["card"] == {}
            and reduced_space["space"] == {} and all(m["active"] == {"panel": [], "sidebar": []} for m in (reduced_hide, reduced_card, reduced_show)),
            "hide": reduced_hide["active"], "card": reduced_card["active"], "show": reduced_show["active"], "space": reduced_space["space"]}
        results["chrome_snapshot_files"] = {"files": [rest_png, mid_png, hidden_png, show_png, card_png], "methods": snapshot_methods}
        # Retain only our synthetic real-window snapshots outside the transient data root.
        saved = os.path.join(ROOT, ".re", "window-chrome-104", "snapshots")
        shutil.copytree(private, saved, dirs_exist_ok=True)
        results["chrome_capture_compare"], results["chrome_dark_rings"] = chrome_capture_comparison(saved)
        card_row = next((r for r in results["chrome_capture_compare"].get("rows", []) if r["state"] == "card-revealed"), None)
        results["chrome_card_material"] = {"status":"DEFERRED", "reason":"Part B: card material and inactive theme are explicitly excluded from Part A", "measurement":card_row}
    finally:
        if down:
            try: pointer("up", 600)
            except Exception: pass
        app.quit()
        if app.quit_report.get("forced"):
            raise RuntimeError("window-chrome flow required force quit; owned process was killed during cleanup")


def window_chrome_checks(factory, results, tmp):
    private = os.path.join(ROOT, ".re", "e2e-window-chrome")
    os.makedirs(private, exist_ok=True)
    app = factory(urls=(white_fixture("Chrome A"),), fresh=True)
    try:
        wid = app.call("window-state")["id"]
        app.call("window-focus", id=wid, activate=True)
        st = place_away_from_cursor(app, 1280, 800)
        app.call("wait", tab=app.call("tabs")[0]["id"])
        # Traffic lights: launch (frames and drawn pixels), resize, a second window (the first
        # is then not key), full-screen exit.
        launch_ok, launch = light_centers(st)
        shot_path = os.path.join(private, "lights.png")
        app.call("snapshot", path=shot_path)
        scale = read_image(shot_path)[0] / 1280.0
        drawn = [drawn_light_center(shot_path, scale, cx, cy) for cx, cy in LIGHT_CENTERS]
        drawn_ok = all(d and abs(d[0] - e[0]) <= 0.75 and abs(d[1] - e[1]) <= 0.75 for d, e in zip(drawn, LIGHT_CENTERS))
        app.call("window-frame", frame=[90, 80, 1000, 640])
        resized = state_when(app, lambda st: st["frame"][2:] == [1000, 640]) or app.call("window-state")
        resized_ok, resized_c = light_centers(resized)
        app.call("key", key="n", modifiers=["cmd"], route="app")
        second = state_when(app, lambda st: st["id"] != wid) or app.call("window-state")
        second_ok, second_c = light_centers(second)
        background_ok, background_c = light_centers(app.call("window-state", id=wid))
        app.call("window-close")
        state_when(app, lambda st: st["id"] == wid)
        app.call("window-focus", id=wid, activate=True)
        before = app.call("window-state")
        app.call("window-fullscreen")
        state_when(app, lambda st: st["fullscreen"] and not st["fullscreenTransition"]
                   and st["fullscreenChanges"] > before["fullscreenChanges"], timeout=15, step=0.1)
        # Toggle and observe the negative predicate in one native main-actor
        # turn. A delayed runner can consume the saved sample after exit.
        negative = app.call("window-fullscreen", observeReadiness=True)
        if negative["status"] == "SKIP":
            results["fullscreen_key_readiness_negative"] = {
                "status": "SKIP", "reason": negative["reason"], "sample": negative}
        else:
            results["fullscreen_key_readiness_negative"] = {
                "ok": negative["status"] == "observed" and negative["state"]["fullscreenTransition"]
                      and not negative["ready"], "sample": negative}
        # The positive wait may begin during or after exit. It must accept the
        # settled window without requiring any particular number of retries.
        ready = ensure_key(app, wid, activation_timeout=0)
        other_error = None
        try:
            ensure_key(app, "missing-readiness-window", timeout=0)
        except FocusInterruption:
            raise
        except RuntimeError as error:
            if str(error) != "window-focus: unknown window":
                raise
            other_error = str(error)
        results["fullscreen_key_readiness"] = {
            "ok": other_error is not None and ready["key"] and ready["appActive"] and ready["keySameObject"]
                  and not ready["fullscreenTransition"],
            "other_error": other_error,
            "ready": {k: ready[k] for k in ("key", "appActive", "keySameObject", "fullscreenTransition")},
            "load_average": list(os.getloadavg()),
        }
        exited = state_when(app, lambda st: not st["fullscreen"] and not st["fullscreenTransition"]
                            and st["fullscreenChanges"] > before["fullscreenChanges"] + 1, timeout=15, step=0.1)
        exited_ok, exited_c = light_centers(exited or app.call("window-state"))
        results["traffic_lights"] = {"ok": launch_ok and drawn_ok and resized_ok and second_ok and background_ok and exited_ok
                                     and not any(st["trafficLightsHidden"]),
                                     "expected_centers": LIGHT_CENTERS, "launch": launch, "drawn_launch": drawn, "resized": resized_c,
                                     "second_window_key": second_c, "first_window_not_key": background_c, "after_fullscreen_exit": exited_c}

        traffic_light_look_checks(app, results, private, scale, wid)

        # URL field and Space header, at rest and hovered (this profile has no favorites).
        place_away_from_cursor(app, 1280, 800)
        app.call("mouse", action="hover", x=900, y=500)
        rest = app.call("window-state")["chrome"]
        rest_png = os.path.join(private, "chrome-rest.png")
        app.call("snapshot", path=rest_png)
        app.call("mouse", action="hover", x=120, y=64)
        url_hover = state_when(app, lambda st: st["chrome"]["urlFieldHovered"], timeout=2)
        url_png = os.path.join(private, "chrome-url-hover.png")
        app.call("snapshot", path=url_png)
        app.call("mouse", action="hover", x=120, y=rest["header"][1] + 18)
        header_hover = state_when(app, lambda st: st["chrome"]["headerHovered"], timeout=2)
        header_png = os.path.join(private, "chrome-header-hover.png")
        app.call("snapshot", path=header_png)
        app.call("mouse", action="hover", x=900, y=500)
        _, _, R = read_image(rest_png)
        _, _, U = read_image(url_png)
        _, _, Hh = read_image(header_png)
        field_rest, field_hover = R(150 * scale, 50 * scale), U(150 * scale, 50 * scale)
        band = rest["header"]
        header_rest, header_fill = R(150 * scale, (band[1] + 3) * scale), Hh(150 * scale, (band[1] + 3) * scale)
        gap = band[1] - (rest["urlField"][1] + rest["urlField"][3])
        geometry_ok = (rest["urlField"] == [8, 46, 212, 36] and rest["favorites"][3] == 8 and band[1] == 90 and band[3] == 36
                       and abs(rest["headerTitleBaseline"] - (band[1] + 23)) <= 0.01 and gap == 8)
        hovered_ok = (bool(url_hover) and url_hover["chrome"]["urlField"] == rest["urlField"] and url_hover["chrome"]["header"] == band
                      and bool(header_hover) and header_hover["chrome"]["header"] == band and header_hover["chrome"]["urlField"] == rest["urlField"])
        pixels_ok = max(abs(a - b) for a, b in zip(field_rest, field_hover)) >= 3 and max(abs(a - b) for a, b in zip(header_rest, header_fill)) >= 3
        results["space_header_url_field"] = {"ok": geometry_ok and hovered_ok and pixels_ok,
                                             "rest": rest, "url_hovered": url_hover and url_hover["chrome"],
                                             "header_hovered": header_hover and header_hover["chrome"],
                                             "url_to_header_gap_pt": gap, "field_fill_rest": list(field_rest), "field_fill_hover": list(field_hover),
                                             "header_fill_rest": list(header_rest), "header_fill_hover": list(header_fill)}

        # Hover reveal: dwell, settle, no flicker along the edge, holds while hovered, hides after leaving.
        app.call("key", key="s", modifiers=["cmd"], route="app")
        hidden = sidebar_hidden(app) or app.call("window-state")
        lights_hidden = all(hidden["trafficLightsHidden"])
        app.call("mouse", action="move", x=700, y=400)
        start = app.call("window-state")["reveal"]
        app.call("mouse", action="move", x=3, y=50)
        app.call("mouse", action="move", x=700, y=400)
        time.sleep(0.4)
        no_quick_reveal = app.call("window-state")["reveal"]["shows"] == start["shows"]
        app.call("mouse", action="move", x=3, y=400)
        settled = wait_card(app, True)
        shown = app.call("window-state")
        card = shown["reveal"]["card"]
        dwell = shown["reveal"]["dwell"]
        lights_card_ok, lights_card = light_centers(shown, 5, 5)
        samples = []
        for x, y in [(2, 100), (4, 160), (1, 220), (3, 280), (0, 340), (2, 400), (5, 460), (1, 520),
                     (3, 580), (2, 640), (4, 700), (12, 700), (60, 650), (120, 400), (2, 300)]:
            app.call("mouse", action="move", x=x, y=y)
            time.sleep(0.03)
            r = app.call("window-state")["reveal"]
            samples.append([x, y, r["phase"], r["shows"], r["hides"]])
        app.call("mouse", action="move", x=120, y=400)
        time.sleep(0.8)
        held = app.call("window-state")["reveal"]
        no_flicker = all(p == "shown" for _, _, p, _, _ in samples) and held["phase"] == "shown" \
            and held["shows"] == shown["reveal"]["shows"] and held["hides"] == shown["reveal"]["hides"]
        card_png = os.path.join(private, "card.png")
        app.call("window-focus", id=wid, activate=True)
        card_activity = window_activity(app)
        app.call("snapshot", path=card_png)
        app.begin_timing("reveal dismiss latency")
        t1 = time.monotonic()
        app.call("mouse", action="move", x=700, y=400)
        leaving = state_when(app, lambda st: st["reveal"]["phase"] == "idle", timeout=2, step=0.01)
        exit_s = round(time.monotonic() - t1, 3)
        gone = wait_card(app, False)
        base_png = os.path.join(private, "card-base.png")
        app.call("window-focus", id=wid, activate=True)
        app.call("snapshot", path=base_png)
        base_activity = window_activity(app)
        results["reveal_timing"] = {"ok": lights_hidden and no_quick_reveal and bool(settled) and 0.13 <= dwell <= 0.35
                                    and lights_card_ok and no_flicker and bool(leaving) and 0.13 <= exit_s <= 0.6 and bool(gone),
                                    "lights_hidden_while_hidden": lights_hidden, "pass_by_without_reveal": no_quick_reveal,
                                    "dwell_s": round(dwell, 3), "settled_s": settled and settled["elapsed"],
                                    "card": card, "lights_on_card": lights_card, "edge_walk": samples, "held": held,
                                    "native_state_at_reveal": {k: shown[k] for k in ("appActive", "isKeyWindow", "firstResponder", "fullscreenTransition")},
                                    "exit_to_idle_s": exit_s, "slide_out_s": gone and gone["elapsed"]}
        edges = card_edges(card_png, base_png, card, scale)
        if not edges["ok"] and card_activity != base_activity:
            # macOS changed the window's active state between the two snapshots (someone is
            # using the Mac); take the pair again the paired way.
            pair = card_pair(app, private, "card-retake")
            edges = card_edges(*pair, scale) if pair else edges
            edges["retaken"] = {"card": card_activity, "base": base_activity}
        results["card_edges_1x"] = edges
        # Open's light and dark appearance (the default Space follows it).
        rows = {}
        for name in ("light", "dark"):
            app.call("appearance", name=name)
            time.sleep(0.3)
            pair = card_pair(app, private, "card-" + name)
            rows[name] = card_edges(*pair[:3], scale) if pair else {"ok": False, "error": "card did not settle"}
        app.call("appearance", name="system")
        results["card_edges_appearance"] = {"ok": all(v.get("ok") for v in rows.values()), "rows": rows}
    finally:
        results["chrome_activation_events"] = app.call("activation-events")
        app.quit()
    themed_card_checks(factory, results, private)


def themed_card_checks(factory, results, private):
    """Card edges on our synthetic themed Spaces: in the real window, and in 1x and 2x
    offscreen renders of the same SidebarView card and shadow (this display is 1x)."""
    binary = os.path.join(ROOT, "Packages", "OpenKit", ".build", "release", "sidebar-render")
    synth = os.path.join(private, "synth")
    shutil.rmtree(synth, ignore_errors=True)
    subprocess.run([binary, "synth", "--out", synth], check=True, stdout=subprocess.DEVNULL)
    with open(os.path.join(synth, "State", "browser.json")) as stream:
        data = json.load(stream)
    for window in data["windows"]:
        window.update(sidebarMode="hidden", sidebarWidth=228, frameX=60, frameY=60, frameWidth=1280, frameHeight=800)
    fixture_path = os.path.join(private, "synth-hidden.json")
    with open(fixture_path, "w") as stream:
        json.dump(data, stream)
    rows = {}
    app = factory(urls=(), snapshot=fixture_path)
    try:
        app.call("window-focus", id=app.call("window-state")["id"], activate=True)
        place_away_from_cursor(app, 1280, 800)
        state_when(app, lambda st: st["sidebarMode"] == "hidden")
        for index, space in enumerate(app.call("spaces")[:2]):
            app.call("space", space=space["id"])
            time.sleep(0.4)
            pair = card_pair(app, private, "themed-%d" % index)
            if not pair:
                rows["space %d (window)" % (index + 1)] = {"ok": False, "error": "card did not settle"}
                continue
            scale = read_image(pair[0])[0] / 1280.0
            rows["space %d (window, %gx)" % (index + 1, scale)] = card_edges(*pair, scale, page_right=False, tolerance=1.25)
    finally:
        app.quit()
    for scale in (1, 2):
        for space in (0, 1):
            png = os.path.join(private, "render-card-%dx-%d.png" % (scale, space))
            base = os.path.join(private, "render-base-%dx-%d.png" % (scale, space))
            common = ["render", "--snapshot", synth, "--size", "1280x800", "--scale", str(scale), "--space", str(space), "--hidden", "--page"]
            # Offscreen renders sometimes come back with garbage or missing (black) tiles
            # (docs/design.md section 15.1; about one in four at 2x here, more under memory
            # pressure, sometimes inside the card on a bottom-bar icon). A render is accepted
            # once two in a row agree on every pixel near the card's corners and edges and
            # none of those pixels is black (these scenes have no black).
            attempts = 0
            regions = [(x, y) for y in list(range(0, 46, 3)) + list(range(754, 800, 3)) for x in list(range(0, 46, 3)) + list(range(190, 250, 3))]
            regions += [(x, y) for y in range(46, 754, 24) for x in (0, 3, 6, 228, 231, 234, 237)]
            accepted = 0
            for out, extra in ((png, ["--reveal"]), (base, ["--no-lights"])):
                previous = None
                for _ in range(10):
                    attempts += 1
                    subprocess.run([binary] + common + extra + ["--out", out], check=True, stdout=subprocess.DEVNULL)
                    _, _, px = read_image(out)
                    data = [px(x * scale + dx, y * scale + dy) for x, y in regions for dx in range(int(scale)) for dy in range(int(scale))]
                    clean = all(max(c) >= 8 for c in data)
                    if clean and data == previous:
                        accepted += 1
                        break
                    previous = data if clean else None
            name = "space %d (offscreen render, %dx)" % (space + 1, scale)
            if accepted < 2:
                # The harness renderer, not the window, failed (this display is 1x, so 2x
                # is only checked offscreen): report it instead of measuring garbage.
                rows[name] = {"status": "SKIP", "renders": attempts,
                              "reason": "offscreen renderer gave no clean render in 10 tries (docs/design.md section 15.1)"}
                continue
            row = card_edges(png, base, [5, 5, 228, 790], scale, tolerance=1.0)
            row["renders"] = attempts
            rows[name] = row
    window_rows = [v for k, v in rows.items() if "(window" in k]
    results["card_edges_themed"] = {"ok": len(window_rows) == 2 and all(v.get("ok") for v in rows.values() if v.get("status") != "SKIP"),
                                    "skipped": [k for k, v in rows.items() if v.get("status") == "SKIP"], "rows": rows}



def peek_checks(factory, results, tmp):
    app = factory(urls=(), fresh=True)
    try:
        source = new_tab(app, fixture("Peek source"))
        app.call("pin", tab=source)
        baseline = app.call("host-counts")
        app.call("peek-open", tab=source, url=fixture("Peek page"))
        app.call("wait")
        state = app.call("peek-state")
        content = state["stack"][-1]["content"]
        app.call("wait", tab=content)
        app.eval(content, "window.openPromotionState=73")
        strip = app.call("tab-strip")
        results["peek_active_stays_model_tab"] = {"ok": state["shown"] and strip[0]["tabs"] == [source]
            and strip[0]["active"] == source and strip[0]["activeIsMember"], "strip": strip}
        before = app.call("host-counts")
        results["peek_png"] = {"ok": True, "file": shot(app, "peek-window.png")}
        app.call("peek-expand")
        wait_until(lambda: not app.call("peek-state")["stack"], timeout=5, step=0.05)
        promoted = next(t["id"] for t in app.call("tabs") if t["selected"])
        counts = app.call("host-counts")
        strip = app.call("tab-strip")
        if app.page(source)["style"] == "chrome":
            # Fork patch P1 (PR #53 round 2, lead decision): a sidebar tab is a
            # tab of the hidden Chrome window and a Peek page is Alloy, so
            # expanding reloads the page in a new Chrome host (docs/m4.md).
            page = app.page(promoted)
            results["expand_rebinds_host"] = {"ok": promoted != source and check_page(app, promoted, "Peek page")
                and page["style"] == "chrome" and page["identifier"] != content and page["hostTab"] == promoted
                and counts["created"] == before["created"] + 1 and counts["engineContents"] == before["engineContents"]
                and counts["retained"] == before["retained"]
                and strip[0]["tabs"] == [source, promoted] and strip[0]["active"] == promoted,
                "rule": "Chrome style: expand reloads in a Chrome host", "before": before, "after": counts, "strip": strip}
        else:
            results["expand_rebinds_host"] = {"ok": promoted != source and check_page(app, promoted, "Peek page")
                and app.page(promoted)["identifier"] == content and app.page(promoted)["hostTab"] == promoted
                and app.eval(promoted, "window.openPromotionState") == 73 and counts == before
                and strip[0]["tabs"] == [source, promoted] and strip[0]["active"] == promoted,
                "before": before, "after": counts, "strip": strip}
        app.call("close", tab=promoted)
        wait_until(lambda: app.call("host-counts")["engineContents"] == baseline["engineContents"], timeout=5, step=0.1)
        after = app.call("host-counts")
        strip = app.call("tab-strip")
        results["close_promoted_releases_host"] = {"ok": after["retained"] == baseline["retained"]
            and after["engineContents"] == baseline["engineContents"] and after["created"] == counts["created"]
            and strip[0]["tabs"] == [source] and check_page(app, source, "Peek source"), "after": after}
        results["window_png"] = {"ok": True, "file": shot(app, "peek-promoted-window.png")}
        # "Peek closed" with Undo in the window's toast (page-platform §4.1.4): Esc through the real key
        # path closes the Peek; the toast sits 8/10 pt inside the panel's top-right; its real Undo button
        # brings the Peek back and the toast leaves.
        app.call("peek-open", tab=source, url=fixture("Peek page"))
        wait_until(lambda: app.call("peek-state")["shown"], timeout=5, step=0.05)
        app.call("key", key="escape")
        closed = wait_until(lambda: not app.call("peek-state")["stack"], timeout=5, step=0.05)
        toasts = wait_until(lambda: (lambda t: t if t["toasts"] and t["toasts"][0]["title"] == "Peek closed" else None)(app.call("toasts")), timeout=3, step=0.05) or app.call("toasts")
        first = (toasts.get("toasts") or [{}])[0]
        panel, frame = toasts.get("panel", [0, 0, 0, 0]), first.get("frame", [0, 0, 0, 0])
        placed = abs(frame[1] - (panel[1] + 8)) < 0.5 and abs(frame[0] + frame[2] - (panel[0] + panel[2] - 10)) < 0.5
        undone = app.call("toast-action", index=0)
        reopened = wait_until(lambda: len(app.call("peek-state")["stack"]) == 1, timeout=5, step=0.05)
        left = wait_until(lambda: not any(not t["exiting"] for t in app.call("toasts")["toasts"]), timeout=3, step=0.05)
        results["peek_closed_toast_undo"] = {"ok": bool(closed) and first.get("accessory") == "undo" and placed and frame[3] == 46
            and undone and bool(reopened) and bool(left), "toast": first, "panel": panel}
        # Review #153: the pointer over "Peek closed" pauses it past the 5 s undo window; its Undo
        # still brings the Peek back.
        app.call("peek-close")
        wait_until(lambda: not app.call("peek-state")["stack"], timeout=5, step=0.05)
        app.call("peek-open", tab=source, url=fixture("Peek page"))
        wait_until(lambda: app.call("peek-state")["shown"], timeout=5, step=0.05)
        app.call("key", key="escape")
        wait_until(lambda: not app.call("peek-state")["stack"], timeout=5, step=0.05)
        wait_until(lambda: (lambda t: t if t["toasts"] and t["toasts"][0]["title"] == "Peek closed" else None)(app.call("toasts")), timeout=3, step=0.05)
        hovered = app.call("toast-hover", index=0, inside=True)
        time.sleep(6.5)
        still = [t for t in app.call("toasts")["toasts"] if t["title"] == "Peek closed" and not t["exiting"]]
        late_undo = app.call("toast-action", index=0) if still else False
        late_reopened = wait_until(lambda: len(app.call("peek-state")["stack"]) == 1, timeout=5, step=0.05)
        results["peek_closed_undo_while_hovered"] = {"ok": hovered and bool(still) and late_undo and bool(late_reopened),
            "hovered": hovered, "shownAfter6s": bool(still), "reopened": bool(late_reopened)}
        app.call("peek-close")
    finally:
        app.quit()
    app = factory(urls=(), fresh=True)
    try:
        color = new_tab(app, 'data:text/html,<title>Page color</title><body style="background:rgb(222,222,250)"><h1>Page color</h1>')
        new_tab(app, fixture("White pane"))
        app.call("split")
        def pane_color():
            return next((p["color"] for p in app.call("window-state")["paneBackgrounds"] if p["tab"] == color), [])
        initial = wait_until(lambda: pane_color() == [222,222,250,255], timeout=5, step=0.1)
        app.call("navigate", tab=color, url='data:text/html,<title>Page color 2</title><body style="background:rgb(30,80,120)"><h1>Page color 2</h1>')
        app.call("wait", tab=color)
        changed = wait_until(lambda: pane_color() == [30,80,120,255], timeout=5, step=0.1)
        results["page_background_after_load"] = {"ok": bool(initial) and bool(changed)
            and app.page(color)["pageBackground"] == [30,80,120,255], "host": app.page(color), "pane_color": pane_color()}
    finally:
        app.quit()

    import runpy
    runpy.run_path(os.path.join(ROOT, "tools", "e2e", "peek_app.py"))["run"](factory, results, tmp, globals())


def page_fixture_server():
    """Serves tools/e2e/fixtures/page-platform on an ephemeral 127.0.0.1 port (no external network)."""
    import http.server
    import threading
    root = os.path.join(ROOT, "tools", "e2e", "fixtures", "page-platform")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=root, **kw)

        def log_message(self, *a):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, "http://127.0.0.1:%d" % server.server_port


def page_newest_toast(app, title=None, timeout=3):
    """The newest toast that is not leaving (with the anchor `panel`), once its title matches."""
    def probe():
        state = app.call("toasts")
        live = [t for t in state["toasts"] if not t["exiting"]]
        if live and (title is None or live[0]["title"] == title):
            return dict(live[0], panel=state["panel"])
        return None
    return wait_until(probe, timeout=timeout, step=0.05)


def page_toast_inset(toast):
    """Top inset 8 and trailing inset 10 inside the web panel (PG-1.1)."""
    panel, frame = toast["panel"], toast["frame"]
    return abs(frame[1] - (panel[1] + 8)) < 0.5 and abs(frame[0] + frame[2] - (panel[0] + panel[2] - 10)) < 0.5


def page_select(app, tab, selector, index=0):
    """Selects one element's text the way a user does: scroll it into view, then triple-click it
    with DevTools Input mouse events (the page's real input path). The engine's selection state
    (EP-3) and text (EP-2) follow input selections, not script-only ones."""
    r = app.eval(tab, "(() => { const e = document.querySelectorAll(%s)[%d]; e.scrollIntoView({block: 'center'});"
                      " const b = e.getBoundingClientRect(); return [b.left + 12, b.top + b.height / 2]; })()" % (json.dumps(selector), index))
    for count in (1, 2, 3):
        for kind in ("mousePressed", "mouseReleased"):
            app.call("devtools", tab=tab, method="Input.dispatchMouseEvent",
                     params={"type": kind, "x": r[0], "y": r[1], "button": "left", "clickCount": count})
    wait_until(lambda: app.call("page-selection", tab=tab)["hasSelection"] or None, timeout=3, step=0.05)
    return app.eval(tab, "String(getSelection())")


def page_clear_selection(app, tab):
    """A click on the empty page corner, as a user clears a selection."""
    for kind in ("mousePressed", "mouseReleased"):
        app.call("devtools", tab=tab, method="Input.dispatchMouseEvent",
                 params={"type": kind, "x": 4, "y": 4, "button": "left", "clickCount": 1})
    wait_until(lambda: (not app.call("page-selection", tab=tab)["hasSelection"]) or None, timeout=3, step=0.05)


def page_copy_rows(app, results, origin):
    """T-E1, T-E2 (page-platform §8.3): Copy URL strips trackers, names what it copied, and shares."""
    tab = new_tab(app, origin + "/en.html?utm_source=x&id=1#top")
    app.call("wait", tab=tab)
    app.call("menu-perform", id="copy-url")
    copied = wait_until(lambda: app.call("pasteboard") == origin + "/en.html?id=1#top", timeout=3, step=0.05)
    toast = page_newest_toast(app, "Copied a clean link without trackers") or {}
    results["T-E1_copy_url_clean"] = {"ok": bool(copied) and toast.get("accessory") == "share"
        and toast.get("frame", [0, 0, 0, 0])[3] == 46 and page_toast_inset(toast) if toast else False,
        "pasteboard": app.call("pasteboard"), "toast": toast}
    app.call("navigate", tab=tab, url=origin + "/en.html?id=1")
    app.call("wait", tab=tab)
    app.call("menu-perform", id="copy-url")
    plain = wait_until(lambda: app.call("pasteboard") == origin + "/en.html?id=1", timeout=3, step=0.05)
    toast = page_newest_toast(app, "Copied Current URL") or {}
    # The real Share button opens the system picker anchored to it; the automation-only dismissal
    # policy closes it again (the picker is a native menu no check may leave open).
    app.call("sidebar-share", dismiss=True)
    try:
        acted = app.call("toast-action", index=0)
        share = app.call("sidebar-share", waitClosed=True)
    finally:
        app.call("sidebar-share", dismiss=False, close=True)
    results["T-E2_copy_url_share"] = {"ok": bool(plain) and bool(toast) and acted and share.get("node") == "toast"
        and share.get("url") == origin + "/en.html?id=1" and share.get("servicesRequested") is True
        and share.get("closed") is True and not share.get("pending"), "toast": toast, "share": share}
    app.call("close", tab=tab)


def page_quote_rows(app, results, origin):
    """Q1–Q5 (page-platform §8.3): Copy URL as Quote through the engine's selection and
    text-fragment generator (EP-2), the Copy URL offer (EP-3), and Share Quote (§4.2.5)."""
    tab = new_tab(app, origin + "/quote.html")
    app.call("wait", tab=tab)
    page_clear_selection(app, tab)
    # Q3: no selection behaves as Copy URL (lead Q11).
    app.call("menu-perform", id="copy-url-quote")
    plain = wait_until(lambda: app.call("pasteboard") == origin + "/quote.html", timeout=3, step=0.05)
    toast = page_newest_toast(app, "Copied Current URL") or {}
    results["Q3_quote_without_selection"] = {"ok": bool(plain) and toast.get("accessory") == "share",
        "pasteboard": app.call("pasteboard"), "toast": toast}
    # Q1: a unique sentence gives a #:~:text= link that scrolls to it in a new tab.
    selected = page_select(app, tab, "#unique")
    app.call("menu-perform", id="copy-url-quote")
    link = wait_until(lambda: (lambda p: p if "#:~:text=" in p else None)(app.call("pasteboard")), timeout=3, step=0.05) or ""
    toast = page_newest_toast(app, "Copied Quote Link") or {}
    opened = new_tab(app, link) if link else None
    landed = None
    if opened:
        app.call("wait", tab=opened)
        landed = wait_until(lambda: (lambda s: s if s["scrollY"] > 3000 and s["visible"] else None)(app.eval(opened,
            "(() => { const r = document.getElementById('unique').getBoundingClientRect();"
            " return {scrollY: scrollY, visible: r.top >= 0 && r.bottom <= innerHeight, hash: location.hash}; })()")),
            timeout=5, step=0.1)
        app.call("close", tab=opened)
    results["Q1_quote_link_scrolls"] = {"ok": selected.strip() == "A unique sentence far down the page for the quote link."
        and link.startswith(origin + "/quote.html#:~:text=") and toast.get("symbol") == "quote.bubble.fill"
        and toast.get("accessory") == "none" and bool(landed) and landed.get("hash") == "",
        "link": link, "toast": toast, "landed": landed}
    # Q2: the second of two identical sentences needs prefix/suffix context from Chromium's
    # generator (EP-2); the link lands on that second sentence, not the first.
    app.call("pasteboard", text="")
    second = page_select(app, tab, ".repeated", 1)
    app.call("menu-perform", id="copy-url-quote")
    ctx_link = wait_until(lambda: (lambda p: p if "#:~:text=" in p else None)(app.call("pasteboard")), timeout=3, step=0.05) or ""
    directive = ctx_link.split("#:~:text=", 1)[1] if ctx_link else ""
    ctx_landed = None
    if ctx_link:
        opened = new_tab(app, ctx_link)
        app.call("wait", tab=opened)
        ctx_landed = wait_until(lambda: (lambda s: s if s["second"] else None)(app.eval(opened,
            "(() => { const r = document.querySelectorAll('.repeated'); const a = r[0].getBoundingClientRect(), b = r[1].getBoundingClientRect();"
            " return {scrollY: scrollY, second: b.top >= 0 && b.bottom <= innerHeight, first: a.bottom > 0 && a.top < innerHeight}; })()")),
            timeout=5, step=0.1)
        app.call("close", tab=opened)
    results["Q2_quote_context"] = {"ok": second.strip() == "The same sentence appears twice on this page."
        and ("-," in directive or ",-" in directive) and bool(ctx_landed) and not ctx_landed.get("first"),
        "link": ctx_link, "landed": ctx_landed}
    # Q4: with Shared Quotes on (the default) and a selection, Copy URL offers the quote link in place.
    # The engine keeps the selection state (EP-3), so the offer needs no page round trip.
    page_select(app, tab, "#unique")
    app.call("menu-perform", id="copy-url")
    offered = wait_until(lambda: (lambda t: t if t and t.get("subtitle") else None)(page_newest_toast(app, timeout=0.2)), timeout=2, step=0.05)
    report = app.call("quote-offer")
    acted = app.call("toast-action", index=0) if offered else False
    quote = wait_until(lambda: (lambda p: p if "#:~:text=" in p else None)(app.call("pasteboard")), timeout=3, step=0.05)
    results["Q4_copy_url_offers_quote"] = {"ok": bool(offered) and offered.get("subtitle") == "Share a link directly to this text instead?"
        and offered.get("accessory") == "copy quote link" and acted and bool(quote) and report.get("shown") is True,
        "toast": offered, "offer": report, "pasteboard": app.call("pasteboard")}
    # Q5: Share Quote under the URL field while the page has a selection (§4.2.5); its press copies
    # the quote link. Without a selection the button goes away.
    state = lambda: app.call("translate", action="state")["button"]
    shown = wait_until(lambda: (lambda b: b if b["shown"] and b["title"] == "Share Quote" else None)(state()), timeout=3, step=0.05)
    app.call("pasteboard", text="")
    pressed = app.call("translate", action="press-status")
    via_button = wait_until(lambda: (lambda p: p if "#:~:text=" in p else None)(app.call("pasteboard")), timeout=3, step=0.05)
    page_clear_selection(app, tab)
    hidden = wait_until(lambda: (not state()["shown"]) or None, timeout=3, step=0.05)
    results["Q5_share_quote_button"] = {"ok": bool(shown) and pressed.get("pressed") is True and bool(via_button) and bool(hidden),
        "button": shown, "pasteboard": via_button, "hiddenAfterClear": bool(hidden)}
    app.call("close", tab=tab)


def page_zoom_rows(app, results, origin):
    """Z1–Z4 (page-platform §8.3): zoom toasts, pinch reset on Actual Size (EP-5), no Chromium zoom bubble."""
    tab = new_tab(app, origin + "/zoom.html")
    app.call("wait", tab=tab)
    windows_before = {w.get("number") for w in app.call("windows")}
    titles = []
    for command in ("zoom-in", "zoom-in", "zoom-actual-size"):
        app.call("menu-perform", id=command)
        expected = {"zoom-in": ["110%", "125%"][len(titles) % 2], "zoom-actual-size": "100%"}[command]
        toast = page_newest_toast(app, expected) or {}
        titles.append(toast.get("title"))
    results["Z1_zoom_toasts"] = {"ok": titles == ["110%", "125%", "100%"], "titles": titles}
    # Z4: Chrome's own zoom bubble never opens a window (hosted tabs have no location bar).
    new_windows = [w for w in app.call("windows") if w.get("number") not in windows_before and w.get("visible")]
    results["Z4_no_chromium_zoom_bubble"] = {"ok": not new_windows, "newWindows": new_windows}
    # Z2: a synthetic pinch scales the visual viewport; Actual Size resets it (EP-5).
    app.call("devtools", tab=tab, method="Input.synthesizePinchGesture",
             params={"x": 200, "y": 200, "scaleFactor": 2, "relativeSpeed": 800, "gestureSourceType": "touch"})
    pinched = wait_until(lambda: (lambda s: s if s > 1.5 else None)(app.eval(tab, "visualViewport.scale")), timeout=5, step=0.1)
    # Control: the pinch scale stays until a command resets it.
    time.sleep(1)
    held = app.eval(tab, "visualViewport.scale")
    app.call("menu-perform", id="zoom-actual-size")
    reset = wait_until(lambda: abs(app.eval(tab, "visualViewport.scale") - 1) < 0.01, timeout=5, step=0.1)
    results["Z2_pinch_then_actual_size"] = {"ok": bool(pinched) and held > 1.5 and bool(reset), "pinched": pinched, "heldAfter1s": held,
        "after": app.eval(tab, "visualViewport.scale")}
    results["Z3_smart_zoom"] = {"status": "DEFERRED", "reason": "no synthetic smart-zoom path; user check U-S1"}
    # Z2 on a Peek page (an Alloy page in a Chrome-style window): Actual Size targets the top Peek page.
    app.call("pin", tab=tab)
    app.call("peek-open", tab=tab, url=origin + "/zoom.html#peek")
    peek = wait_until(lambda: (lambda s: s["stack"][-1]["content"] if s["stack"] and s["stack"][-1]["content"] else None)(app.call("peek-state")), timeout=5, step=0.05)
    peek_pinched = peek_reset = None
    peek_held = 0
    if peek:
        app.call("wait", tab=peek)
        app.call("devtools", tab=peek, method="Input.synthesizePinchGesture",
                 params={"x": 200, "y": 200, "scaleFactor": 2, "relativeSpeed": 800, "gestureSourceType": "touch"})
        peek_pinched = wait_until(lambda: (lambda s: s if s > 1.5 else None)(app.eval(peek, "visualViewport.scale")), timeout=5, step=0.1)
        time.sleep(1)
        peek_held = app.eval(peek, "visualViewport.scale")
        app.call("menu-perform", id="zoom-actual-size")
        peek_reset = wait_until(lambda: abs(app.eval(peek, "visualViewport.scale") - 1) < 0.01, timeout=5, step=0.1)
    app.call("peek-close")
    results["Z2_peek_pinch_then_actual_size"] = {"ok": bool(peek) and bool(peek_pinched) and peek_held > 1.5 and bool(peek_reset),
        "pinched": peek_pinched, "heldAfter1s": peek_held, "reset": bool(peek_reset)}
    app.call("close", tab=tab)


def page_commands_checks(factory, results, tmp):
    """Copy URL family, quote and zoom rows (page-platform §8.3 T-E1, T-E2, Q1–Q4, Z1–Z4)."""
    server, origin = page_fixture_server()
    app = factory(urls=(), fresh=True)
    shared_quotes = None
    try:
        # Shared defaults domain: set the one key this suite reads, restore it in `finally`.
        shared_quotes = app.call("defaults", key="open.advanced.enableSharedQuotes")
        app.call("defaults", key="open.advanced.enableSharedQuotes", value=True)
        page_copy_rows(app, results, origin)
        page_quote_rows(app, results, origin)
        page_zoom_rows(app, results, origin)
    finally:
        try:
            app.call("defaults", key="open.advanced.enableSharedQuotes", value=shared_quotes)
        finally:
            app.quit()
            server.shutdown()


def sidebar_checks(factory, results, tmp):
    app = factory(urls=(), fresh=True)
    try:
        results["empty"] = {"ok": app.call("tabs") == [] and app.call("window-state")["shownPages"] == []}
        a = new_tab(app, fixture("Sidebar A"))
        b = app.call("open", url=fixture("Sidebar B"), background=True)["id"]
        results["new_tab_lazy"] = {"ok": check_page(app, a, "Sidebar A") and not app.tab(b)["loaded"]}
        app.call("select", tab=b)
        results["select"] = {"ok": check_page(app, b, "Sidebar B") and app.page(a)["hidden"]}
        app.call("pin", tab=b)
        pinned = app.tab(b)
        app.call("pin", tab=b)
        unpinned = app.tab(b)
        results["pin_unpin"] = {"ok": pinned["section"] == "pinned" and pinned["page"]["browserPinned"]
                                      and unpinned["section"] == "today" and not unpinned["page"]["browserPinned"]
                                      and check_page(app, b, "Sidebar B")}
        app.call("close", tab=b)
        archived = app.call("archive")
        results["close_today_archives"] = {"ok": not any(t["id"] == b for t in app.call("tabs"))
                                               and any(t["id"] == b for t in archived) and check_page(app, a, "Sidebar A")}
        app.call("pin", tab=a)
        old_page = app.page(a)["identifier"]
        app.call("close", tab=a)
        unloaded = app.tab(a)
        results["close_pinned_unloads"] = {"ok": unloaded["section"] == "pinned" and not unloaded["loaded"]
                                               and not unloaded["hasWebContent"] and unloaded["sleepPhase"] == "placeholder"}
        app.call("select", tab=a)
        results["wake_pinned"] = {"ok": check_page(app, a, "Sidebar A") and app.page(a)["identifier"] != old_page}
        c = new_tab(app, fixture("Sidebar C"))
        d = new_tab(app, fixture("Sidebar D"))
        moved = app.call("sidebar-move", tab=c, section="today", index=0)
        tabs = app.call("tabs")
        strip = sorted((t["page"]["browserIndex"], t["id"]) for t in tabs if t.get("page"))
        results["drag_reorder_intent"] = {"ok": moved and [t["id"] for t in tabs] == [a, c, d]
                                               and [tid for _, tid in strip] == [a, c, d] and check_page(app, d, "Sidebar D")}
        folder = app.call("folder-create", title="Fixture Folder")
        first = app.call("folder-toggle", folder=folder)
        second = app.call("folder-toggle", folder=folder)
        results["folder_toggle"] = {"ok": first["accepted"] and second["accepted"] and first["expanded"] != second["expanded"]}
        app.call("sidebar-clear")
        results["clear_today"] = {"ok": [t["id"] for t in app.call("tabs")] == [a]
                                       and len(app.call("archive")) >= 3}
        s1 = next(s for s in app.call("spaces") if s["focused"])["id"]
        s2 = app.call("space-create", title="Work", profile="Work")
        e = new_tab(app, fixture("Sidebar E"))
        context = app.page(e)["context"]
        app.call("space", space=s1)
        app.call("select", tab=a)
        first_page = check_page(app, a, "Sidebar A")
        # Click the real switcher through OEApplication.sendEvent; no direct intent dispatch.
        app.call("window-motion", reduced=False)
        frame = app.call("window-state")["spaceSwitcherFrames"][s2]
        app.call("mouse", action="click", x=frame[0]+frame[2]/2, y=frame[1]+frame[3]/2)
        # mouse-click queues mouse-up; wait for that real action before reading
        # its layer animation (otherwise the receipt can belong to the prior switch).
        after_click = state_when(app, lambda st: st["space"] == s2 and st["selected"] == e) or app.call("window-state")
        switched = app.call("window-motion")["space"]
        second_page = check_page(app, e, "Sidebar E")
        results["space_switch_wrapper"] = {"ok": first_page and second_page and context != "Default"
                                                and app.page(e)["context"] == context}
        # Closed-form critical response from the installed mass/stiffness, not elapsed time.
        omega = math.sqrt(switched.get("stiffness", 0) / switched.get("mass", 1))
        remainder = 228 * (1 + omega * .27) * math.exp(-omega * .27)
        travel = abs(switched.get("to", 0) - switched.get("from", 0))
        results["space_switch_click_spring"] = {"ok": after_click["space"] == s2
            and after_click["selected"] == e and after_click["shownPages"] == [e]
            and scheduled_spring(switched, .20, 1, "position.x") and remainder <= .5 and travel > .5,
            "scheduled": switched, "remaining_at_270ms_pt": remainder, "switcher_frame": frame,
            "travel_pt": travel,
            "selected_after_click": after_click["selected"], "shown_after_click": after_click["shownPages"]}
        results["durable_profile_storage"] = {"status": "SKIP", "reason": "covered by --only profiles (durable_second_profile: a cookie survives a relaunch)"}
        background = new_tab(app, fixture("Profile background"))
        app.call("select", tab=e)
        previous = app.page(e)["identifier"]
        changed = app.call("space-profile", space=s2, profile="Work New")
        selected_auto_created = app.tab(e)["loaded"]
        live_page = check_page(app, e, "Sidebar E")
        reset = app.call("tab-state", tab=background)
        new_context = app.page(e)["context"]
        results["profile_change_tears_down"] = {"ok": changed and selected_auto_created and live_page and app.page(e)["identifier"] != previous
            and new_context != context and not reset["loaded"] and not reset["hasWebContent"]
            and not any(reset[k] for k in ("favicon", "crashed", "loading", "audible", "canGoBack", "canGoForward")) and reset["progress"] == 0,
            "inactive_tab": reset}
        third_space = app.call("space-create", title="Background opener", profile="Work New")
        foreground = new_tab(app, fixture("Foreground Space"))
        known = {tid for strip in app.call("tab-strip") for tid in strip["tabs"]}
        app.eval(e, '(() => { const w=window.open("about:blank", "_blank"); if(w) { w.document.write("<title>Background child</title><h1>Background child</h1>"); w.document.close(); } return "opened"; })()')
        child_ids = wait_until(lambda: set(tid for strip in app.call("tab-strip") for tid in strip["tabs"]) - known, timeout=8, step=0.1)
        child = next(iter(child_ids)) if child_ids else ""
        child_state = app.call("tab-state", tab=child) if child else {}
        results["background_space_window_open"] = {"ok": bool(child) and child_state["space"] == s2
            and child_state["page"]["context"] == new_context and app.eval(child, "document.title") == "Background child", "child": child_state}
        app.call("space", space=s2); app.call("select", tab=e)
        before = [t["id"] for t in app.call("tabs")]
        refused = app.call("sidebar-move", tab=e, folder="00000000-0000-0000-0000-000000000099", index=0)
        results["refused_move"] = {"ok": not refused and [t["id"] for t in app.call("tabs")] == before
                                       and check_page(app, e, "Sidebar E")}
        cache_tabs = []
        for i in range(10):
            tid = new_tab(app, fixture("Cache %d" % i))
            cache_tabs.append(tid)
            if i == 0: first_page = app.page(tid)["identifier"]
        retained = app.call("host-counts")["retained"]
        evicted = not app.tab(cache_tabs[0])["loaded"]
        states = []
        for _ in range(6):
            time.sleep(0.15)
            states.append(app.tab(cache_tabs[0]))
        results["evicted_live_state_stays_unloaded"] = {"ok": evicted and all(not t["hasWebContent"] and not t["loaded"] for t in states),
            "samples": [{k:t[k] for k in ("hasWebContent", "loaded", "loading", "progress")} for t in states]}
        app.call("select", tab=cache_tabs[0])
        results["hidden_cache_lru"] = {"ok": retained <= 9 and evicted
            and check_page(app, cache_tabs[0], "Cache 0") and app.page(cache_tabs[0])["identifier"] != first_page
            and app.call("host-counts")["retained"] <= 9, "retained_before_wake": retained}
        results["window_png"] = {"ok": True, "file": shot(app, "sidebar-window.png")}
    finally:
        app.quit()
    static_window_comparison(factory, results, tmp, "sidebar")


def static_window_comparison(factory, results, tmp, suite):
    common = subprocess.check_output(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, text=True).strip()
    common = os.path.realpath(os.path.join(ROOT, common))
    capture_root = os.environ.get("OPEN_ARC_CAPTURE_ROOT", os.path.join(os.path.dirname(common), ".re"))
    snapshot = os.path.join(capture_root, "design-compare", "snap-real", "State", "browser.json")
    captures = glob.glob(os.path.join(capture_root, "runtime", "sessions", "20261024-213009-session-full", "0001-*", "win-5245.png"))
    if not captures or not os.path.isfile(snapshot):
        results["comparison"] = {"status": "SKIP", "reason": "F0001 capture and capture-time snapshot absent in OPEN_ARC_CAPTURE_ROOT"}
        print("comparison SKIP: F0001 capture and snapshot absent")
        return
    private = os.path.join(ROOT, ".re", "app-shell-comparison-" + suite)
    os.makedirs(private, exist_ok=True)
    with open(snapshot) as stream:
        data = json.load(stream)
    state = data["windows"][0]
    state.update(focusedSpaceID=data["spaces"][0]["id"], sidebarWidth=228, sidebarMode="anchored",
                 frameX=40, frameY=40, frameWidth=2216, frameHeight=1394, selectedNodeBySpace={})
    data["windows"] = [state]
    data["spaces"][0]["today"] = []
    fixture_path = os.path.join(private, "browser.json")
    with open(fixture_path, "w") as stream:
        json.dump(data, stream)
    app = factory(urls=(), snapshot=fixture_path)
    try:
        wid = app.call("window-state")["id"]
        app.call("window-focus", id=wid, activate=True)
        app.call("window-frame", frame=[40, 40, 2216, 1394], unconstrained=True)
        live_state = state_when(app, lambda st: st["frame"][2:] == [2216, 1394]) or app.call("window-state")
        if live_state["frame"][2:] != [2216, 1394]:
            raise RuntimeError("capture-size window refused: %s" % live_state["frame"])
        raw = os.path.join(private, "open-live-2x.png")
        ours = os.path.join(private, "open-live-1x.png")
        app.call("snapshot", path=raw)
        subprocess.run(["sips", "-z", "1394", "2216", raw, "--out", ours], check=True, stdout=subprocess.DEVNULL)
    finally:
        app.quit()
    compare = os.path.join(private, "comparison")
    binary = os.path.join(ROOT, "Packages", "OpenKit", ".build", "release", "sidebar-render")
    subprocess.run([binary, "compare", "--arc", captures[0], "--ours", ours, "--out", compare], check=True,
                   stdout=subprocess.DEVNULL)
    table = open(os.path.join(compare, "table.md")).read()
    print(table)
    elements = []
    for line in table.splitlines():
        if not line.startswith("| ") or line.startswith("| Element"): continue
        cells = [x.strip() for x in line.split("|")[1:-1]]
        def number(text):
            try: return float(text)
            except ValueError: return None
        elements.append({"element": cells[0], "position_pt": number(cells[1]), "delta_e00": number(cells[2])})
    worst_position = max((x["position_pt"] or 0 for x in elements), default=0)
    worst_color = max((x["delta_e00"] or 0 for x in elements), default=0)
    results["comparison"] = {"ok": bool(elements) and worst_position <= 1 and worst_color <= 2,
        "capture": "F0001", "elements": elements, "worst_position_pt": worst_position, "worst_delta_e00": worst_color,
        "private_artifacts": os.path.relpath(private, ROOT), "method": "docs/design.md section 7; live Open snapshot converted to 1x; same masks"}
    # Only element names, measurements, and colors leave .re. No captured
    # browser titles, URLs, icons, or Arc pixels are committed.
    with open(os.path.join(OUT, "comparison-" + suite + ".md"), "w") as stream:
        stream.write(table)


# ----------------------------------------------------------------------------
# Early lifecycle failures go through the real NSApplication terminate and
# NSAlert button paths, with own-process automation flags compiled out of
# ordinary Release builds.


def startup_failure_checks(factory, results, tmp):
    app = factory(urls=(), fresh=True)
    app_path = app.executable
    app.quit()
    unconfirmed = factory(urls=("data:text/html,<title>Unconfirmed frame</title><h1>Unconfirmed frame</h1>",), fresh=True,
                          extra_env={"OPEN_AUTOMATION_SKIP_DISPLAY_LINK": "1", "OPEN_E2E_NO_LAUNCH_WAIT": "1"})
    try:
        tab = unconfirmed.call("tabs")[0]
        unconfirmed.call("wait", tab=tab["id"])
        timing = unconfirmed.call("timing")
        results["first_frame_timeout_continues"] = {"ok": timing["firstFrameConfirmed"] is False
            and "sidebarDrawn" not in timing and timing["firstFrameWaitTimedOut"] >= 3000
            and timing["engineStart"] >= timing["firstFrameWaitTimedOut"] and "engineStarted" in timing
            and unconfirmed.eval(tab["id"], "document.title") == "Unconfirmed frame",
            "timing": timing, "hosts": unconfirmed.call("host-counts")}
        results["launch_waiter_early_exit"] = {"ok": unconfirmed.launch_waiter_ended_before_automation
            and unconfirmed.proc.poll() == 0 and check_page(unconfirmed, tab["id"], "Unconfirmed frame"),
            "launcherExit": unconfirmed.proc.returncode,
            "waiterEndedBeforeAutomation": unconfirmed.launch_waiter_ended_before_automation,
            "actualAppPID": unconfirmed.pid}
    finally:
        unconfirmed.quit()
    early_data = os.path.join(tmp, "early-quit")
    log = os.path.join(tmp, "early-quit.log")
    with open(log, "w") as stream:
        proc = subprocess.run([app_path, "--use-mock-keychain", "--user-data-dir=" + early_data],
            env=dict(os.environ, OPEN_AUTOMATION_QUIT_BEFORE_ENGINE="1"), stdout=stream, stderr=subprocess.STDOUT, timeout=15)
    text = open(log).read()
    results["quit_before_engine"] = {"ok": proc.returncode == 0 and "termination before engine" in text
        and "engineStart" not in text and os.path.isfile(os.path.join(early_data, "State", "browser.json"))
        and not os.path.exists(os.path.join(early_data, "State", "engine.log")), "exit": proc.returncode}
    queued_page = Path(tmp) / "queued-navigation.html"
    queued_page.write_text("<title>Queued</title><h1>Queued</h1>")
    queued = factory(urls=("data:text/html,<title>Initial</title><h1>Initial</h1>",), fresh=True,
                     extra_env={"OPEN_AUTOMATION_EARLY_NAVIGATION": queued_page.resolve().as_uri()})
    try:
        tab = queued.call("tabs")[0]
        queued.call("wait", tab=tab["id"])
        title = queued.eval(tab["id"], "document.title")
        counts = queued.call("host-counts")
        startup = queued.call("startup")
        results["navigation_before_engine"] = {"ok": title == "Queued"
            and startup["pagesBeforeEngine"] == 0 and startup.get("earlyHostRequestsRefused") is True and counts["created"] == 1,
            "title": title, "hosts": counts, "readiness_probe": startup.get("earlyHostRequestsRefused")}
    finally:
        queued.quit()
    # APFS clone of our own app, with its CEF library removed: exercise the
    # actual library-load failure, not an injected engine success/failure.
    bundle = os.path.dirname(os.path.dirname(os.path.dirname(app_path)))
    failed_bundle = os.path.join(tmp, "MissingEngine.app")
    subprocess.run(["cp", "-cR", bundle, failed_bundle], check=True)
    shutil.rmtree(os.path.join(failed_bundle, "Contents", "Frameworks", "Chromium Embedded Framework.framework"))
    failure_data = os.path.join(tmp, "engine-failure")
    failure_log = os.path.join(tmp, "engine-failure.log")
    with open(failure_log, "w") as stream:
        failed = subprocess.run([os.path.join(failed_bundle, "Contents", "MacOS", "Open"), "--use-mock-keychain", "--user-data-dir=" + failure_data],
            env=dict(os.environ, OPEN_AUTOMATION_DISMISS_ENGINE_FAILURE="1"), stdout=stream, stderr=subprocess.STDOUT, timeout=15)
    text = open(failure_log).read()
    results["engine_failure_alert"] = {"ok": failed.returncode == 1 and "engine failed to start" in text
        and "engine failure alert shown; button=Quit" in text, "exit": failed.returncode}
    shutil.rmtree(failed_bundle)


# ----------------------------------------------------------------------------
# Fork patch P2: toolbar actions and popups from Chrome's model (run with
# --style chrome). Extensions: tools/e2e/fixtures/action-probe and Bitwarden.

ACTION_PROBE = "jihnllejimhgcmfmcnchbekapeajboik"  # tools/e2e/fixtures/action-probe
# The suite loads a copy of the probe from here, so it can update it on disk.
ACTION_PROBE_COPY = None


def actions_checks(app, results):
    app.call("ext-prompt", handler=False)
    # Popup key routing must not depend on the user's per-site mode state.
    # This App key lives in the shared defaults domain, even with a test root.
    key = "open.developer.modeHosts"
    previous = app.call("defaults", key=key)
    try:
        app.call("defaults", key=key, value=None)
        _actions_checks(app, results)
    finally:
        try:
            app.call("defaults", key=key, value=previous)
        finally:
            app.cleanup_surfaces()


def _actions_checks(app, results):
    def actions():
        return app.call("actions")

    def make_key():
        """Use the shared exact-PID activation helper and target our shell window."""
        app.call("window-focus", id=app.call("window-state")["id"], activate=True)
        return app.call("activate")["key"]

    def action(ext):
        hits = [x for x in actions()["actions"] if x["id"] == ext]
        return hits[0] if hits else None

    def popup_eval(state, js):
        return app.eval(state["page"]["identifier"], js, timeout=20)

    def open_popup(ext):
        """Runs the action; the open popup once its extension page loaded."""
        app.call("events")
        app.call("ext-run", extension=ext)

        def loaded():
            s = app.call("ext-popup")
            if not (s.get("open") and s["page"]["live"] and s["page"]["url"].startswith("chrome-extension://")):
                return None
            return s if popup_eval(s, "document.readyState") == "complete" else None
        return wait_until(loaded, timeout=20)

    def close_popup():
        app.call("popup-close")
        wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10)

    ready = wait_until(lambda: actions()["ready"] and action(ACTION_PROBE), timeout=40)
    # Bitwarden opens its welcome page after install; let that happen first.
    wait_until(lambda: [t for t in app.call("tabs") if "bitwarden.com" in t["url"]], timeout=15)
    time.sleep(1)
    first = app.call("tabs")[0]["id"]
    a = new_tab(app, "https://example.com/?a")
    b = new_tab(app, "https://example.org/?b")
    app.call("select", tab=a)
    time.sleep(1)
    probe = action(ACTION_PROBE)
    # Images: 28 pt (toolbar) and 16 pt (icon), each with a 1x and a 2x
    # representation of the right pixel size.
    results["actions_list"] = {
        "ok": bool(ready) and bool(probe) and probe["name"] == "Open action probe" and probe["title"] == "Action probe"
              and probe["hasPopup"] and probe["live"] and probe["toolbarImage"]["bytes"] > 0 and probe["icon"]["bytes"] > 0
              and probe["toolbarImage"]["width"] == 28 and probe["icon"]["width"] == 16
              and probe["toolbarImage"]["pixels"] == [[28, 28], [56, 56]] and probe["icon"]["pixels"] == [[16, 16], [32, 32]],
        "probe": probe, "ids": [x["id"] for x in actions()["actions"]]}
    # The popup is a Chrome extension popup: getViews lists it, its tab query
    # sees the page under it, and it reports ready and its size.
    state = open_popup(ACTION_PROBE)
    info = {"opened": bool(state)}
    if state:
        info["source"] = state["source"]
        wait_until(lambda: popup_eval(state, "window.currentTab !== undefined"), timeout=20)
        info["popup_views"] = popup_eval(state, "window.popupViews")
        info["current_tab"] = popup_eval(state, "window.currentTab && window.currentTab.url")
        events = []

        def got():
            events.extend(app.call("events"))
            popup = [e for e in events if e["type"] == "extensionPopup"]
            return [e for e in popup if e.get("ready")] and [e for e in popup if "resize" in e]
        wait_until(got, timeout=15)
        info["ready"] = bool([e for e in events if e["type"] == "extensionPopup" and e.get("ready")])
        sizes = [e["resize"] for e in events if e["type"] == "extensionPopup" and "resize" in e]
        info["last_size"] = sizes[-1] if sizes else None
        info["document_size"] = popup_eval(state, "[document.documentElement.scrollWidth,"
                                                  " document.documentElement.scrollHeight]")
        info["showing_popup"] = action(ACTION_PROBE)["showingPopup"]
    results["popup_is_chrome_popup"] = {
        "ok": bool(state) and info.get("source") == "user" and info.get("popup_views") == 1
              and (info.get("current_tab") or "").startswith("https://example.com/?a") and info.get("ready")
              and info.get("last_size") is not None and info.get("last_size") == info.get("document_size")
              and info["last_size"][0] == 320 and info.get("showing_popup"),
        **info}

    # Focus the other real Split View pane and run the action in the SAME
    # socket turn, before the pending engine sync can run on its own.
    close_popup()
    left = new_tab(app, "https://example.com/?split-left")
    right = new_tab(app, "https://example.org/?split-right")
    pane_popup = open_popup(ACTION_PROBE)
    pane_ids = {"left": app.page(left)["chromeTabId"], "right": app.page(right)["chromeTabId"]}
    if pane_popup:
        popup_eval(pane_popup, "Promise.all([chrome.action.setTitle({tabId: %(left)d, title: 'Split left'}),"
                              "chrome.action.setTitle({tabId: %(right)d, title: 'Split right'})]).then(() => true)" % pane_ids)
    close_popup()
    wait_until(lambda: (lambda x: x and x["title"] == "Split right")(action(ACTION_PROBE)), timeout=10)
    panes = app.call("split")
    app.call("ext-run", extension=ACTION_PROBE, focusTab=left)

    def focused_popup():
        popup = app.call("ext-popup")
        try:
            return popup if popup.get("open") and popup["page"]["live"] and popup_eval(popup, "window.currentTab !== undefined") else None
        except RuntimeError as error:
            if "app.open.engine error 4" in str(error) or "no page" in str(error):
                return None  # The regression closes the popup during this poll.
            raise
    pane_state = wait_until(focused_popup, timeout=10)
    pane_tab = popup_eval(pane_state, "window.currentTab && window.currentTab.id") if pane_state else None
    still_open = app.call("ext-popup").get("open")
    close_popup()
    # Capture the action snapshot before the same socket command returns.
    # A getter after yielding would let the scheduled sync hide the bug.
    pane_menu = app.call("ext-menu", extension=ACTION_PROBE, focusTab=right, snapshot=True)
    results["split_pane_action_and_menu"] = {
        "ok": bool(pane_popup) and {left, right} <= {p["id"] for p in panes}
              and bool(pane_state) and pane_tab == pane_ids["left"] and still_open
              and pane_menu.get("action", {}).get("title") == "Split right" and bool(pane_menu.get("items")),
        "popup_tab": pane_tab, "expected_tab": pane_ids["left"], "popup_stayed_open": still_open,
        "menu_action_title": pane_menu.get("action", {}).get("title")}
    app.call("split")  # separate the temporary panes again
    for pane in (left, right):
        if any(t["id"] == pane for t in app.call("tabs")):
            app.call("close", tab=pane)
    app.call("select", tab=a)
    state = open_popup(ACTION_PROBE)

    # Per-tab state set by the extension shows for the active tab only.
    ids = {"a": app.page(a)["chromeTabId"], "b": app.page(b)["chromeTabId"]}
    if state:
        popup_eval(state, "Promise.all(["
                          "chrome.action.setBadgeText({tabId: %(a)d, text: '7'}),"
                          "chrome.action.setBadgeBackgroundColor({tabId: %(a)d, color: '#ff0000'}),"
                          "chrome.action.setTitle({tabId: %(a)d, title: 'Probe A'}),"
                          "chrome.action.setIcon({tabId: %(a)d, imageData: {32: solidIcon(220, 40, 40)}}),"
                          "chrome.action.disable(%(b)d)]).then(() => true)" % ids)
    close_popup()
    app.call("select", tab=a)
    on_a = wait_until(lambda: (lambda x: x if x and x["badge"] == "7" else None)(action(ACTION_PROBE)), timeout=10)
    app.call("select", tab=b)
    on_b = wait_until(lambda: (lambda x: x if x and not x["enabled"] else None)(action(ACTION_PROBE)), timeout=10)
    results["per_tab_state"] = {
        "ok": bool(on_a) and on_a["title"] == "Probe A" and on_a["badgeColor"] == "#ff0000ff" and on_a["enabled"]
              and bool(on_b) and on_b["badge"] == "" and on_b["title"] == "Action probe"
              and len(on_a["toolbarImage"].get("hash", "")) == 64 and len(on_b["toolbarImage"].get("hash", "")) == 64
              and on_a["toolbarImage"]["hash"] != on_b["toolbarImage"]["hash"]
              and len(on_a["icon"].get("hash", "")) == 64 and len(on_b["icon"].get("hash", "")) == 64
              and on_a["icon"]["hash"] != on_b["icon"]["hash"],
        "tab_a": on_a and {k: on_a[k] for k in ("badge", "badgeColor", "title", "enabled")},
        "tab_b": on_b and {k: on_b[k] for k in ("badge", "title", "enabled")}}

    # Running the action while it is disabled (tab b) asks the shell for its
    # context menu, as Chrome shows it, and opens no popup.
    app.call("events")
    ran_disabled = app.call("ext-run", extension=ACTION_PROBE)
    asked = wait_until(lambda: [e for e in app.call("events") if e["type"] == "extensionMenuRequest"], timeout=5)
    results["disabled_action_requests_menu"] = {
        "ok": bool(asked) and asked[0]["extension"] == ACTION_PROBE and not app.call("ext-popup").get("open"),
        "ran": ran_disabled, "requests": asked}

    # An unchanged image is the same object after an update (the engine
    # reads pixels and hashes them; no PNG round trip, no new image). The
    # plain icon of tab b and the first tab is the default icon.
    icon_b = action(ACTION_PROBE)["icon"]
    app.call("select", tab=first)
    on_first = wait_until(lambda: (lambda x: x if x and x["enabled"] else None)(action(ACTION_PROBE)), timeout=10)
    results["action_image_cache"] = {
        "ok": bool(on_first) and on_first["icon"]["hash"] == icon_b["hash"] and on_first["icon"]["object"] == icon_b["object"],
        "tab_b": icon_b, "first": on_first and on_first["icon"]}

    # Running a popup-less action fires chrome.action.onClicked.
    app.call("select", tab=a)
    time.sleep(0.5)
    state = open_popup(ACTION_PROBE)
    if state:
        popup_eval(state, "chrome.storage.session.set({clicks: 0})"
                          ".then(() => chrome.action.setPopup({tabId: %(a)d, popup: ''})).then(() => true)" % ids)
    close_popup()
    no_popup = wait_until(lambda: (lambda x: x if x and not x["hasPopup"] else None)(action(ACTION_PROBE)), timeout=10)
    app.call("ext-run", extension=ACTION_PROBE)
    time.sleep(1)
    popup_after_click = app.call("ext-popup").get("open")
    app.call("select", tab=first)
    time.sleep(0.5)
    state = open_popup(ACTION_PROBE)
    clicks = popup_eval(state, "chrome.storage.session.get(['clicks', 'lastClickTab'])") if state else None
    results["on_clicked"] = {
        "ok": bool(no_popup) and not popup_after_click and bool(clicks)
              and clicks.get("clicks") == 1 and clicks.get("lastClickTab") == ids["a"],
        "popup_less_on_tab": bool(no_popup), "popup_opened": popup_after_click, "storage": clicks}

    # chrome.action.openPopup() in the active window opens the popup with
    # source API. Open's window is made key first (this shell's popup panel
    # takes key; Chrome checks the window before anything else).
    api = {}
    if state:
        popup_eval(state, "chrome.storage.session.set({openPopup: ''}).then(() => true)")
        api["key"] = make_key()
        popup_eval(state, "chrome.runtime.sendMessage('open-popup')"
                          ".then(() => { setTimeout(() => window.close(), 50); return true; })")

        def api_popup():
            s = app.call("ext-popup")
            if s.get("open") and s["source"] == "api" and s["page"]["url"].startswith("chrome-extension://"):
                return s
        opened = wait_until(api_popup, timeout=6)
        if opened:
            api["source"] = opened["source"]
            api["result"] = wait_until(lambda: popup_eval(opened, "chrome.storage.session.get('openPopup')"
                                                                  ".then(r => r.openPopup)"), timeout=5)
            close_popup()
        else:
            state = open_popup(ACTION_PROBE)
            api["result"] = popup_eval(state, "chrome.storage.session.get('openPopup').then(r => r.openPopup)") if state else None
            close_popup()
    results["open_popup_api"] = {"ok": api.get("key") is True and api.get("source") == "api" and api.get("result") == "ok",
                                 **api}

    # While a popup is open, openPopup() is refused (as Chrome's desktop
    # toolbar): "Failed to open popup.", and the open popup stays.
    refusal = {}
    state = open_popup(ACTION_PROBE)
    if state:
        popup_eval(state, "chrome.storage.session.set({openPopup: ''}).then(() => true)")
        refusal["key"] = make_key()
        popup_eval(state, "chrome.runtime.sendMessage('open-popup-now').then(() => true)")
        refusal["result"] = wait_until(lambda: popup_eval(state, "chrome.storage.session.get('openPopup')"
                                                                 ".then(r => r.openPopup)"), timeout=6)
        after = app.call("ext-popup")
        refusal["same_popup"] = (after.get("open") and after["source"] == "user"
                                 and after["page"]["identifier"] == state["page"]["identifier"])
        close_popup()
    results["open_popup_refused_while_open"] = {
        "ok": refusal.get("key") is True and refusal.get("result") == "Failed to open popup." and bool(refusal.get("same_popup")),
        **refusal}
    # Running the action whose popup is open closes it (Chrome's toolbar).
    if not app.call("ext-popup").get("open"):
        open_popup(ACTION_PROBE)
    app.call("ext-run", extension=ACTION_PROBE)
    toggled = wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10)
    results["run_again_closes_popup"] = {"ok": bool(toggled)}

    # window.close() in the popup page closes it.
    state = open_popup(ACTION_PROBE)
    if state:
        popup_eval(state, "setTimeout(() => window.close(), 50); true")
    closed = wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10)
    results["page_close_closes_popup"] = {"ok": bool(state) and bool(closed)}

    # A popup's keys reach its delegate before the page (through the hidden
    # window's CEF delegate) and, when the page does not consume them, after
    # it (the engine forwards them). Ctrl+D: both stages. Cmd+W: this shell
    # closes the popup before the page (plan F2), and the tab stays.
    popup_key_checks(app, results, open_popup, close_popup)

    # A delegate closes (twice), or toggles the action, from each engine
    # callback. The popup must remain alive INSIDE that callback and close
    # on the next turn; the app and its tab must survive.
    callback_rows = {}
    for phase in ("open", "resize", "ready"):
        for toggle in (False, True):
            try:
                app.call("events")
                app.call("popup-callback-close", phase=phase, toggle=toggle)
                app.call("ext-run", extension=ACTION_PROBE)
                callbacks = []

                def callback_closed():
                    callbacks.extend(e for e in app.call("events") if e["type"] == "popupCallbackClose")
                    return callbacks and not app.call("ext-popup").get("open")
                closed = wait_until(callback_closed, timeout=10)
                alive = app.call("ping") is not None
                callback_rows[phase + (" toggle" if toggle else " close")] = {
                    "ok": bool(closed) and alive and callbacks[-1].get("stillOpenInsideCallback") is True,
                    "callbacks": callbacks, "closed": bool(closed), "alive": alive}
            except Exception as error:
                dict.__setitem__(results, "popup_callback_close", {"ok": False, "phase": phase,
                                 "toggle": toggle, "error": str(error), "rows": callback_rows})
                raise
            finally:
                try:
                    app.call("popup-callback-close", phase="clear", timeout=3)
                finally:
                    app.cleanup_surfaces()
    results["popup_callback_close"] = {"ok": all(row["ok"] for row in callback_rows.values()), "rows": callback_rows}

    # A tab switch closes the popup (Chrome's ExtensionPopup does). The first
    # tab: tab a has no popup since the onClicked check.
    app.call("select", tab=first)
    state = open_popup(ACTION_PROBE)
    if state:
        app.call("select", tab=b)
    switched = wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10)
    app.call("select", tab=first)
    results["tab_switch_closes_popup"] = {"ok": bool(state) and bool(switched)}

    # Pin and order: pinned actions first, in pinned order; moves and unpins.
    # Start from none pinned. (--load-extension installs come before Chrome's
    # toolbar model observes installs, so pin-by-default does not apply to
    # them; the extensions suite checks it with a Web Store install.)
    for ext in (ACTION_PROBE, EXT["bitwarden"]):
        app.call("ext-pin", extension=ext, pinned=False)
    wait_until(lambda: not [x for x in actions()["actions"] if x["pinned"]], timeout=10)
    app.call("ext-pin", extension=ACTION_PROBE, pinned=True)
    app.call("ext-pin", extension=EXT["bitwarden"], pinned=True)
    pinned = wait_until(lambda: (lambda ids: ids if ids[:2] == [ACTION_PROBE, EXT["bitwarden"]] else None)(
        [x["id"] for x in actions()["actions"]]), timeout=10)
    app.call("ext-move", extension=EXT["bitwarden"], index=0)
    moved = wait_until(lambda: (lambda xs: xs if [x["id"] for x in xs][:2] == [EXT["bitwarden"], ACTION_PROBE]
                                and xs[0]["pinnedIndex"] == 0 and xs[1]["pinnedIndex"] == 1 else None)(
        actions()["actions"]), timeout=10)
    results["pin_and_move"] = {"ok": bool(pinned) and bool(moved), "after_pin": pinned,
                               "after_move": moved and [(x["id"], x["pinnedIndex"]) for x in moved[:3]]}

    # The context menu is Chrome's (extension name, pin, options, ...); its
    # pin item unpins.
    menu = app.call("ext-menu", extension=ACTION_PROBE)
    titles = [x["title"] for x in menu if not x["separator"]]
    unpin = [t for t in titles if "unpin" in t.lower()]
    if unpin:
        app.call("ext-menu", extension=ACTION_PROBE, select=unpin[0])
    unpinned = wait_until(lambda: (lambda x: x if x and not x["pinned"] else None)(action(ACTION_PROBE)), timeout=10)
    results["context_menu"] = {"ok": "Open action probe" in titles and bool(unpin) and bool(unpinned), "items": titles}

    # Each menu keeps its own model: an item of an older menu still runs
    # after a newer menu of the same action was built.
    kept = app.call("ext-menu", extension=ACTION_PROBE, keep=True)
    pin = [x["title"] for x in kept if not x["separator"] and x["title"].lower().startswith("pin")]
    stale = app.call("ext-menu", extension=ACTION_PROBE, select=pin[0], stale=True) if pin else {}
    repinned = wait_until(lambda: (lambda x: x if x and x["pinned"] else None)(action(ACTION_PROBE)), timeout=10)
    results["menu_keeps_model"] = {"ok": bool(pin) and stale.get("ran") is True and bool(repinned),
                                   "item": pin[:1], "ran": stale.get("ran")}
    app.call("ext-pin", extension=ACTION_PROBE, pinned=False)
    wait_until(lambda: (lambda x: x if x and not x["pinned"] else None)(action(ACTION_PROBE)), timeout=10)

    # Bitwarden's popup is a real popup now: it takes its fixed width.
    app.call("select", tab=a)
    time.sleep(0.5)
    state = open_popup(EXT["bitwarden"])
    widths = []

    def wide():
        widths.extend(e["resize"][0] for e in app.call("events") if e["type"] == "extensionPopup" and "resize" in e)
        return widths and max(widths) >= 350
    wait_until(wide, timeout=20)
    views = popup_eval(state, "chrome.extension.getViews({type: 'popup'}).length") if state else None
    close_popup()
    results["bitwarden_popup_width"] = {"ok": bool(state) and views == 1 and bool(widths) and max(widths) >= 350,
                                        "widths": widths[-5:], "popup_views": views}

    # Every other command of the action menu runs without a crash in an Open
    # window (the PR #53 rule for context menus). Pin pins; Manage Extension
    # and View Web Permissions open Chrome's pages as Open tabs; Remove shows
    # Chrome's uninstall dialog (Open's own prompts are P3), which is
    # dismissed, so the extension stays.
    action_menu_command_checks(app, results, action)
    popup_teardown_checks(app, results, actions, action, popup_eval, open_popup, close_popup, first)


def popup_key_checks(app, results, open_popup, close_popup):
    """Real app-level Cmd+W; shared with the focused break/revert flow."""
    try:
        tabs_before = len(app.call("tabs"))
        state = open_popup(ACTION_PROBE)
        keys = {"opened": bool(state)}
        if state:
            app.call("focus", tab=state["page"]["identifier"])
            app.call("events")
            # Ctrl-D is Toggle Developer Mode in the current App and is
            # correctly consumed before the page. Use an unbound chord to
            # exercise the unconsumed callback (the original P2 contract).
            app.call("key", key="d", modifiers=["ctrl", "shift"], window="popup", route="window")
            # The socket drains events. CEF can deliver the before-page and
            # unconsumed callbacks in separate polls; retain both observations.
            observed = []
            def key_stages():
                observed.extend(x for x in app.call("events") if x["type"] == "popupKey")
                return observed if {"beforePage", "unconsumed"} <= {x.get("phase") for x in observed} else None
            stages = wait_until(key_stages, timeout=5)
            keys["unbound_key_stages"] = sorted({x.get("phase") for x in stages or []})
            keys["events"] = observed
            keys["still_open"] = bool(app.call("ext-popup").get("open"))
            app.call("key", key="w", modifiers=["cmd"], window="popup", route="app")
            keys["closed"] = bool(wait_until(lambda: not app.call("ext-popup").get("open"), timeout=5))
            keys["tabs_kept"] = len(app.call("tabs")) == tabs_before
            if not keys["closed"]:
                close_popup()
        results["popup_keys"] = {
            "ok": keys["opened"] and keys.get("unbound_key_stages") == ["beforePage", "unconsumed"] and keys.get("still_open")
                  and keys.get("closed") and keys.get("tabs_kept"), **keys}
    finally:
        app.cleanup_surfaces()


def action_menu_command_checks(app, results, action,
                              prefixes=("Pin", "Manage Extension", "View Web Permissions", "Remove from")):
    """Real Chrome menu commands; each opened surface closes on failure too."""
    ran = {}
    for prefix in prefixes:
        try:
            items = [x for x in app.call("ext-menu", extension=ACTION_PROBE)
                     if not x["separator"] and x["title"].startswith(prefix) and not x["title"].startswith("Pinned")]
            if not items or not items[0]["enabled"]:
                ran[prefix] = {"ok": False, "item": items[0] if items else None}
                continue
            title = items[0]["title"]
            before_tabs = {t["id"] for t in app.call("tabs")}
            before_windows = {w["number"] for w in app.call("windows")}
            app.call("ext-menu", extension=ACTION_PROBE, select=title)
            r = {"title": title}
            if prefix == "Pin":
                r["ok"] = bool(wait_until(lambda: (lambda x: x and x["pinned"])(action(ACTION_PROBE)), timeout=10))
            elif prefix == "Remove from":
                r["dialog"] = wait_until(lambda: [
                    {"class": w["class"], "title": w["title"], "text": w.get("text", [])}
                    for w in app.call("windows", accessibility=True) if w["visible"] and w["number"] not in before_windows
                    and w["class"] == "NativeWidgetMacNSWindow"
                    and "Open action probe" in " ".join([w["title"]] + w.get("text", []))
                    and {"Cancel", "Remove"} <= set(w.get("text", []))], timeout=10)
                if os.environ.get("OPEN_E2E_FAIL_UNINSTALL") == "1" and r["dialog"]:
                    results["forced_uninstall_failure"] = {"ok": False, "dialog_seen": True, "dialog": r["dialog"]}
                    raise RuntimeError("forced early failure in uninstall confirmation case")
                r["dismissed"] = app.call("dismiss")
                time.sleep(1)
                r["ok"] = bool(r["dialog"]) and bool(action(ACTION_PROBE))
            else:
                opened = wait_until(lambda: [t["url"] for t in app.call("tabs") if t["id"] not in before_tabs
                                             and t["url"].startswith("chrome://")], timeout=10)
                r["opened"] = opened
                r["ok"] = bool(opened)
                for t in app.call("tabs"):
                    if t["id"] not in before_tabs:
                        app.call("close", tab=t["id"])
            app.call("ping")
            ran[prefix] = r
        finally:
            app.cleanup_surfaces()
    results["action_menu_commands"] = {"ok": all(v["ok"] for v in ran.values()), "commands": ran}


def popup_teardown_checks(app, results, actions, action, popup_eval, open_popup, close_popup, tab):
    """What keeps a popup open on blur, and every way a popup goes away."""
    def holds(expected, timeout=10):
        return wait_until(lambda: (lambda s: s if s.get("open") and s.get("staysOpenOnBlur") is expected else None)(
            app.call("ext-popup")), timeout=timeout)

    app.call("select", tab=tab)
    time.sleep(0.5)
    # Chrome keeps the popup open on blur while a JavaScript dialog, a
    # web-modal dialog of the popup (WebAuthn), or DevTools on it shows.
    keep = {}
    state = open_popup(ACTION_PROBE)
    if state:
        keep["idle"] = app.call("ext-popup").get("staysOpenOnBlur")
        # DevTools' Page domain answers the dialog below.
        app.call("devtools", tab=state["page"]["identifier"], method="Page.enable")
        popup_eval(state, "setTimeout(() => alert('hold'), 10); true")
        keep["alert"] = bool(holds(True))
        # Answer Chrome's dialog the way DevTools does (it is Chrome's
        # app-modal dialog: the popup's WebContents delegate is Chrome's).
        try:
            app.call("devtools", tab=state["page"]["identifier"], method="Page.handleJavaScriptDialog",
                     params={"accept": True}, timeout=10)
        except Exception as e:
            keep["alert_answer"] = str(e)[:200]
            keep["alert_dismissed"] = app.call("dismiss")
        keep["after_alert"] = bool(holds(False))
        app.call("devtools-open", tab=state["page"]["identifier"])
        keep["devtools"] = bool(holds(True))
        keep["devtools_dismissed"] = app.call("dismiss")
        keep["after_devtools"] = bool(holds(False))
        # A passkey request: the request must stay alive while its dialog
        # shows (the popup is not closed under it).
        app.call("focus", tab=state["page"]["identifier"])
        popup_eval(state, "window.passkey = 'pending'; window.abortPasskey = new AbortController();"
                          "navigator.credentials.get({publicKey: {challenge: new Uint8Array(32), timeout: 60000,"
                          " userVerification: 'discouraged'}, signal: window.abortPasskey.signal})"
                          ".then(() => window.passkey = 'resolved', e => window.passkey = e.name + ': ' + e.message);"
                          "true")
        keep["webauthn"] = bool(holds(True))
        time.sleep(3)
        after = app.call("ext-popup")
        keep["webauthn_popup_still_open"] = bool(after.get("open")) and after["page"]["identifier"] == state["page"]["identifier"]
        keep["webauthn_request"] = popup_eval(state, "window.passkey")
        popup_eval(state, "window.abortPasskey.abort(); true")
        keep["webauthn_aborted"] = wait_until(lambda: (lambda r: r if r != "pending" else None)(popup_eval(state, "window.passkey")),
                                              timeout=10)
        keep["after_webauthn"] = bool(holds(False))
        app.call("dismiss")
        close_popup()
    results["popup_stays_open_on_blur"] = {
        "ok": keep.get("idle") is False and keep.get("alert") and keep.get("after_alert") and keep.get("devtools")
              and keep.get("after_devtools") and keep.get("webauthn") and keep.get("webauthn_popup_still_open")
              and keep.get("webauthn_request") == "pending" and (keep.get("webauthn_aborted") or "").startswith("AbortError")
              and keep.get("after_webauthn"),
        **keep}

    # Extension update and reload with the popup open: the popup closes, the
    # action comes back (same pin), and the new version runs. A reloaded
    # command-line extension comes back as an unpacked one, which Chrome keeps
    # disabled without developer mode (DISABLE_UNSUPPORTED_DEVELOPER_EXTENSION),
    # so turn developer mode on first, through Chrome's own extensions page,
    # as a developer who reloads an unpacked extension has it.
    page = new_tab(app, "chrome://extensions")
    wait_until(lambda: app.eval(page, "typeof chrome.developerPrivate") == "object", timeout=20)
    results["developer_mode_on"] = {"ok": app.eval(page, "new Promise(done => chrome.developerPrivate.updateProfileConfiguration("
                                                         "{inDeveloperMode: true}, () => done(!chrome.runtime.lastError)))") is True}
    app.call("close", tab=page)
    app.call("select", tab=tab)

    def reload_with_popup(bump):
        r = {}
        if bump:
            manifest = os.path.join(ACTION_PROBE_COPY, "manifest.json")
            data = json.load(open(manifest))
            data["version"] = bump
            with open(manifest, "w") as f:
                json.dump(data, f, indent=2)
        app.call("ext-pin", extension=ACTION_PROBE, pinned=True)
        wait_until(lambda: (lambda x: x if x and x["pinned"] else None)(action(ACTION_PROBE)), timeout=10)
        app.call("events")
        state = open_popup(ACTION_PROBE)
        r["opened"] = bool(state)
        if state:
            try:
                popup_eval(state, "setTimeout(() => chrome.runtime.reload(), 50); true")
            except RuntimeError:
                pass
        r["closed"] = bool(wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10))
        back = wait_until(lambda: (lambda x: x if x and x["live"] else None)(action(ACTION_PROBE)), timeout=20)
        r["back"] = bool(back)
        if not back:
            listed = actions()
            r["at_timeout"] = {"ready": listed["ready"], "actions": [(x["id"], x["live"]) for x in listed["actions"]],
                               "installed": [(e["id"], e["enabled"], e["version"]) for e in app.call("extensions")["installed"]]}
        r["pinned"] = bool(back and back["pinned"])
        def version():
            installed = [e for e in app.call("extensions")["installed"] if e["id"] == ACTION_PROBE]
            return installed[0]["version"] if installed else None
        r["version"] = wait_until(lambda: (lambda v: v if v == (bump or v) else None)(version()), timeout=10) or version()
        again = open_popup(ACTION_PROBE)
        r["popup_after"] = bool(again)
        close_popup()
        r["ok"] = (r["opened"] and r["closed"] and r["back"] and r["pinned"] and r["popup_after"]
                   and (not bump or r["version"] == bump))
        return r
    results["extension_update_with_popup"] = reload_with_popup("1.1")
    results["extension_reload_with_popup"] = reload_with_popup(None)

    # The popup's renderer crashes: the popup closes and Chrome terminates
    # the extension (its action goes away until it is reloaded); Open keeps
    # running.
    crash = {}
    state = open_popup(ACTION_PROBE)
    crash["opened"] = bool(state)
    if state:
        try:
            app.call("devtools", tab=state["page"]["identifier"], method="Page.crash", timeout=5)
        except Exception as e:  # the renderer dies before it answers
            crash["crash_call"] = str(e)[:200]
    crash["closed"] = bool(wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10))
    crash["action_gone"] = bool(wait_until(lambda: not action(ACTION_PROBE), timeout=10))
    crash["alive"] = app.call("ping") is not None
    results["popup_renderer_crash"] = {"ok": crash["opened"] and crash["closed"] and crash["action_gone"] and crash["alive"],
                                       **crash}

    # No live Chrome tab in the window: Chrome's model goes away (the shell
    # hears it), the list is the profile's (pins kept, not live), and an
    # action does not run (no manifest popup in a plain page). A new tab
    # brings the live model back.
    bitwarden = EXT["bitwarden"]
    app.call("ext-pin", extension=bitwarden, pinned=True)
    wait_until(lambda: (lambda x: x if x and x["pinned"] else None)(action(bitwarden)), timeout=10)
    app.call("events")
    for t in app.call("tabs"):
        app.call("close", tab=t["id"])
    gone = wait_until(lambda: (lambda r: r if not r["ready"] else None)(actions()), timeout=15)
    told = []
    def notified_gone():
        told.extend(e for e in app.call("events") if e["type"] == "extensionActions")
        return any(e.get("ready") is False for e in told)
    # The model transition is visible to getters before its posted delegate
    # notification arrives. Await that real event, not one immediate drain.
    idle = {"not_ready": bool(gone), "notified_gone": bool(wait_until(notified_gone, timeout=10))}
    if gone:
        listed = [x for x in gone["actions"] if x["id"] == bitwarden]
        idle["listed"] = listed[0] if listed else None
        idle["ran"] = app.call("ext-run", extension=bitwarden)
        time.sleep(2)
        idle["popup"] = app.call("ext-popup").get("open")
    fresh = new_tab(app, "https://example.com/?live")
    back = wait_until(lambda: (lambda r: r if r["ready"] and [x for x in r["actions"] if x["id"] == bitwarden and x["live"]]
                               else None)(actions()), timeout=20)
    idle["live_again"] = bool(back)
    back_told = []
    def notified_back():
        back_told.extend(e for e in app.call("events") if e["type"] == "extensionActions")
        return any(e.get("ready") is True for e in back_told)
    idle["notified_back"] = bool(wait_until(notified_back, timeout=10))
    results["no_live_tab_actions"] = {
        "ok": idle["not_ready"] and bool(idle.get("listed")) and idle["listed"]["pinned"] and not idle["listed"]["live"]
              and idle.get("ran") is False and not idle.get("popup") and idle["live_again"]
              and idle["notified_gone"] and idle["notified_back"],
        **idle}

    # Both teardown paths: explicit -close, and releasing the browser while
    # it still owns its popup/toolbar (the round 1 double-delete path).
    closing_rows = {}
    for release in (False, True):
        try:
            app.call("select", tab=fresh)
            wait_until(lambda: actions()["ready"], timeout=15)
            state = open_popup(bitwarden)
            closing = {"opened": bool(state)}
            popup_page = state["page"]["identifier"] if state else None
            released = app.call("window-close", releaseBrowsers=release)
            closing["released_without_close"] = released if release else None
            closing["windows_after_close"] = bool(wait_until(lambda: len(app.call("shell-windows")) == 0, timeout=10))
            closing["alive"] = app.call("ping") is not None
            app.call("window-reopen")
            wait_until(lambda: app.call("shell-windows"), timeout=10)
            closing["popup_page_gone"] = bool(wait_until(lambda: popup_page not in [p["identifier"] for p in app.call("pages")], timeout=10))
            closing["new_window_popup"] = app.call("ext-popup").get("open")
            closing["ok"] = (closing["opened"] and closing["windows_after_close"] and closing["alive"]
                             and closing["popup_page_gone"] and not closing["new_window_popup"]
                             and (not release or (released.get("released", 0) > 0 and released.get("remaining") == 0 and released.get("hadPopup"))))
            closing_rows["dealloc" if release else "close"] = closing
        except Exception as error:
            dict.__setitem__(results, "window_close_with_popup", {"ok": False, "release": release,
                             "error": str(error), "rows": closing_rows})
            raise
        finally:
            app.cleanup_surfaces()
    results["window_close_with_popup"] = {"ok": all(row["ok"] for row in closing_rows.values()), "rows": closing_rows}


# ----------------------------------------------------------------------------
# Profiles: engine data under <root>/Engine (docs/plans/profiles.md §6.2)


def profiles_checks(factory, results, tmp, config):
    """Two launches on one data root, then the legacy layout and its
    migration: a plain move, unreadable and locked files, a profile already
    in use, and a crash at each step."""
    root = None
    default_url, work_url = "https://example.com/?profile=default", "https://example.com/?profile=work"

    def cookie(app, tab):
        return app.eval(tab, "document.cookie")

    def probe_view(app):
        """URLs and window ids the tabs probe sees from the focused profile,
        and whether it may run in incognito. Chrome loads --load-extension
        into each profile when it starts."""
        wait_until(lambda: any(e["id"] == PROBE for e in app.call("extensions")["installed"]), timeout=30)

        def open_popup():
            try:
                return app.call("popup", extension=PROBE)["identifier"]
            except RuntimeError:
                return None  # the action is not ready for this tab yet
        pop = wait_until(open_popup, timeout=20)
        if pop is None:
            raise RuntimeError("tabs probe popup did not open")
        wait_until(lambda: app.eval(pop, "window.currentTab !== undefined"), timeout=20)
        seen = app.eval(pop, "Promise.all([chrome.tabs.query({}), chrome.windows.getAll(),"
                             " chrome.extension.isAllowedIncognitoAccess()]).then(([ts, ws, incognito]) =>"
                             " ({urls: ts.map(t => t.url || t.pendingUrl), windows: ws.map(w => w.id), incognito}))")
        app.call("popup-close")
        return seen

    def allow_probe_in_incognito(app):
        """The E5 threat: a default-profile extension allowed in incognito.
        Set through Chrome's own extensions page in the default profile."""
        page = new_tab(app, "chrome://extensions")
        wait_until(lambda: app.eval(page, "typeof chrome.developerPrivate") == "object", timeout=20)
        answer = app.eval(page, "new Promise(done => chrome.developerPrivate.updateExtensionConfiguration("
                                "{extensionId: '%s', incognitoAccess: true}, () =>"
                                " done(chrome.runtime.lastError ? chrome.runtime.lastError.message : 'ok')))" % PROBE)
        app.call("close", tab=page)
        return answer

    def mode(*parts):
        return oct(os.stat(os.path.join(root, *parts)).st_mode & 0o777)

    # First launch: the default profile's page and the incognito grant (the
    # grant reloads the extension; the next launch starts with it).
    app = factory(urls=(), fresh=True)
    try:
        root = app.user_data
        a = new_tab(app, default_url)
        app.eval(a, 'document.cookie = "oe_default=1; max-age=86400"; localStorage.setItem("oe", "default"); 1')
        incognito_set = allow_probe_in_incognito(app)
        app.call("save")
    finally:
        app.quit()
    app = factory(urls=())
    try:
        a = [t["id"] for t in app.call("tabs") if t["url"] == default_url][0]
        app.call("select", tab=a)
        app.call("wait", tab=a)
        home = [x for x in app.call("spaces") if x["focused"]][0]["id"]
        work = app.call("space-create", title="Work", profile="Work")
        b = new_tab(app, work_url)
        work_dir = app.page(b)["context"]
        app.eval(b, 'document.cookie = "oe_work=1; max-age=86400"; document.cookie = "oe_session=1";'
                    ' localStorage.setItem("oe", "work"); 1')
        work_hosted = app.page(b).get("chromeWindowId", -1)
        work_view = probe_view(app)
        app.call("space", space=home)
        app.call("select", tab=a)
        app.call("wait", tab=a)
        default_view = probe_view(app)
        # With incognito access, an off-the-record fallback of the Work
        # profile (the E5 leak) would show Work's tab here.
        results["extension_isolation"] = {
            "ok": incognito_set == "ok" and default_view["incognito"] is True
                  and default_url in default_view["urls"] and work_url not in default_view["urls"]
                  and work_url in work_view["urls"] and default_url not in work_view["urls"]
                  and not set(default_view["windows"]) & set(work_view["windows"]),
            "incognito_access": incognito_set, "default_profile_probe_sees": default_view,
            "work_profile_probe_sees": work_view}
        app.call("save")
    finally:
        app.quit()
    # Every disk context is a real disk profile, never Chromium's in-memory
    # (off-the-record) fallback: Chromium wrote its Preferences there,
    # registered it in Local State, and gave its tab a Chrome window.
    local_state = json.load(open(os.path.join(root, "Engine", "Local State")))
    registered = sorted(local_state.get("profile", {}).get("info_cache", {}))
    results["disk_profiles_on_disk"] = {
        "ok": all(os.path.isfile(os.path.join(root, "Engine", d, "Preferences")) for d in ("Default", work_dir))
              and work_dir in registered and work_hosted != -1,
        "info_cache": registered, "work_chrome_window": work_hosted}
    layout = {
        "engine_default_cookies": os.path.exists(os.path.join(root, "Engine", "Default", "Cookies")),
        "engine_work_cookies": os.path.exists(os.path.join(root, "Engine", work_dir, "Cookies")),
        "local_state": os.path.exists(os.path.join(root, "Engine", "Local State")),
        "profiles_default": sorted(x for x in os.listdir(os.path.join(root, "Profiles", "Default")) if not x.startswith(".")),
        "layout_marker": os.path.exists(os.path.join(root, "Engine", ".open-layout")),
        "modes": {p: mode(*p.split("/")) for p in ("Engine", "Engine/Default", "Engine/" + work_dir,
                                                  "Profiles/Default", "Profiles/" + work_dir)},
    }
    results["engine_layout"] = {"ok": layout["engine_default_cookies"] and layout["engine_work_cookies"]
                                      and layout["local_state"] and layout["profiles_default"] == ["AdBlock", "Boosts", "State"]
                                      and layout["layout_marker"] and set(layout["modes"].values()) == {"0o700"},
                                "layout": layout, "work_dir": work_dir}

    def check_cookies(app, label, work_loads=True):
        tabs = {t["url"]: t["id"] for t in app.call("tabs")}
        app.call("select", tab=tabs[default_url])
        app.call("wait", tab=tabs[default_url])
        default_cookie = cookie(app, tabs[default_url])
        app.call("space", space=work)
        work_tab = [t["id"] for t in app.call("tabs") if t["url"] == work_url][0]
        app.call("select", tab=work_tab)
        if not work_loads:
            time.sleep(2)
            page = app.page(work_tab)
            app.call("space", space=home)
            return {"default_cookie": default_cookie, "work_page_live": bool(page and page.get("live"))}
        app.call("wait", tab=work_tab)
        work_cookie, work_storage = cookie(app, work_tab), app.eval(work_tab, 'localStorage.getItem("oe")')
        app.call("space", space=home)
        return {"default_cookie": default_cookie, "work_cookie": work_cookie, "work_storage": work_storage}

    # Relaunch: each profile keeps its own cookies (persistent and session)
    # and storage.
    app = factory(urls=())
    try:
        got = check_cookies(app, "relaunch")
    finally:
        app.quit()
    results["durable_second_profile"] = {
        "ok": "oe_work=1" in got["work_cookie"] and "oe_session=1" in got["work_cookie"]
              and "oe_default" not in got["work_cookie"]
              and got["work_storage"] == "work" and "oe_default=1" in got["default_cookie"]
              and "oe_work" not in got["default_cookie"], **got}

    # The old layout: root_cache_path was Profiles/. The default profile's
    # Chromium files sat in Profiles/Default next to Open's folders,
    # installation files in Profiles/, the cache in ~/Library/Caches/<root>/
    # Profiles/Default, and other profiles kept nothing.
    caches = os.path.join(os.path.expanduser("~/Library/Caches"), os.path.basename(root))

    def make_legacy():
        engine, profiles = os.path.join(root, "Engine"), os.path.join(root, "Profiles")
        for name in os.listdir(os.path.join(engine, "Default")):
            shutil.move(os.path.join(engine, "Default", name), os.path.join(profiles, "Default", name))
        shutil.rmtree(os.path.join(engine, "Default"))
        shutil.rmtree(os.path.join(engine, work_dir), ignore_errors=True)
        os.makedirs(os.path.join(profiles, work_dir, "Engine"), exist_ok=True)
        os.makedirs(os.path.join(profiles, "Default", "Engine"), exist_ok=True)
        for name in os.listdir(engine):
            if not name.startswith(("Singleton", ".")):
                shutil.move(os.path.join(engine, name), os.path.join(profiles, name))
        shutil.rmtree(engine)
        os.symlink("%s-999999" % socket.gethostname(), os.path.join(profiles, "SingletonLock"))  # a dead owner
        old_cache, new_cache = os.path.join(caches, "Profiles", "Default"), os.path.join(caches, "Engine", "Default")
        shutil.rmtree(old_cache, ignore_errors=True)
        if os.path.isdir(new_cache):
            os.makedirs(os.path.dirname(old_cache), exist_ok=True)
            shutil.move(new_cache, old_cache)
        os.makedirs(old_cache, exist_ok=True)
        open(os.path.join(old_cache, "open-e2e-cache-marker"), "w").write("cache")

    def inventory(base, skip=("State", "Boosts", "AdBlock", "Engine")):
        out = {}
        for top in os.listdir(base):
            if top in skip or top.startswith("."):
                continue
            path = os.path.join(base, top)
            walk = [(path, top)] if not os.path.isdir(path) else [
                (os.path.join(d, f), os.path.relpath(os.path.join(d, f), base)) for d, _, fs in os.walk(path) for f in fs]
            for file, rel in walk:
                info = os.lstat(file)
                try:
                    digest = hashlib.sha256(open(file, "rb").read()).hexdigest()[:16]
                except (PermissionError, IsADirectoryError, OSError):
                    digest = "unreadable"
                out[rel] = (info.st_size, digest)
        return out

    binary = os.path.join(ROOT, "build", config, "Open.app", "Contents", "MacOS", "Open")
    browser_json = os.path.join(root, "State", "browser.json")

    def run_binary(label, **env_extra):
        """One launch of the real app; returns its exit code and output."""
        env = dict(os.environ, OPEN_USER_DATA=root, OPEN_E2E_OWNER_PID=str(os.getpid()), **env_extra)
        path = os.path.join(tmp, "migration-%s.log" % label)
        with open(path, "w") as log:
            code = subprocess.run([binary, "--use-mock-keychain"], env=env, stdout=log, stderr=subprocess.STDOUT,
                                  timeout=60).returncode
        return code, open(path).read()

    def migrate_only(label):
        """The launch's layout step alone: the app exits before the engine
        starts, so the moved files are exactly what was on disk."""
        before = open(browser_json, "rb").read()
        code, text = run_binary(label, OPEN_AUTOMATION_QUIT_BEFORE_ENGINE="1")
        return code, text, open(browser_json, "rb").read() == before

    def migrated_layout():
        return {"marker": os.path.exists(os.path.join(root, "Engine", ".open-layout")),
                "journal": os.path.exists(os.path.join(root, "Engine", ".open-layout-journal.json")),
                "profiles_default": sorted(x for x in os.listdir(os.path.join(root, "Profiles", "Default"))
                                           if not x.startswith(".")),
                "local_state_moved": os.path.exists(os.path.join(root, "Engine", "Local State"))
                                     and not os.path.exists(os.path.join(root, "Profiles", "Local State")),
                "old_engine_folder_gone": not os.path.exists(os.path.join(root, "Profiles", work_dir, "Engine")),
                "singletons_gone": not any(n.startswith("Singleton") for n in os.listdir(os.path.join(root, "Profiles"))),
                "cache_moved": os.path.exists(os.path.join(caches, "Engine", "Default", "open-e2e-cache-marker"))
                               and not os.path.exists(os.path.join(caches, "Profiles", "Default"))}

    def layout_ok(state):
        return (state["marker"] and not state["journal"] and state["profiles_default"] == ["AdBlock", "Boosts", "State"]
                and state["local_state_moved"] and state["old_engine_folder_gone"] and state["singletons_gone"]
                and state["cache_moved"])

    def launch_and_check(label):
        app = factory(urls=())
        try:
            return check_cookies(app, label, work_loads=False)
        finally:
            app.quit()

    def legacy_launch_with_deferred_profile(label):
        """A legacy launch (lead decision 2026-10-26): the default profile runs
        on its old data; the Work profile is deferred. Switching to its Space
        and opening a new tab there runs nothing: no crash, no context for
        Work (never a memory-only one), and one log line for the launch."""
        app = factory(urls=())
        start = os.path.getsize(app.log.name)
        try:
            got = check_cookies(app, label, work_loads=False)
            app.call("space", space=work)
            opened = app.call("open", url="https://example.com/?profile=work-new")
            time.sleep(2)
            got["new_work_tab_live"] = bool(app.page(opened["id"]).get("live"))
            app.call("space", space=home)
            got["alive"] = app.call("ping") is not None
            got["page_contexts"] = sorted({page["context"] for page in app.call("pages")})
        finally:
            app.quit()
        with open(app.log.name, errors="replace") as f:
            f.seek(start)
            got["deferred_log_lines"] = [line for line in f.read().splitlines() if "unavailable this launch" in line]
        return got

    # A plain move: every file arrives unchanged, the snapshot is untouched.
    make_legacy()
    before = inventory(os.path.join(root, "Profiles", "Default"))
    code, text, same_snapshot = migrate_only("legacy")
    after = inventory(os.path.join(root, "Engine", "Default"))
    state = migrated_layout()
    got = launch_and_check("legacy")
    results["migration_from_legacy"] = {
        "ok": code == 0 and before == after and same_snapshot and layout_ok(state) and "oe_default=1" in got["default_cookie"],
        "files": len(after), "inventory_equal": before == after, "snapshot_byte_identical": same_snapshot,
        "layout": state, "default_cookie": got["default_cookie"]}

    # Unreadable files (top level and nested) and a nested locked file do not
    # block renames: the migration finishes on the first launch.
    make_legacy()
    unreadable = os.path.join(root, "Profiles", "Default", "Open E2E unreadable.bin")
    nested = os.path.join(root, "Profiles", "Default", "Open E2E", "nested", "unreadable.bin")
    nested_locked = os.path.join(root, "Profiles", "Default", "Open E2E", "nested", "locked.bin")
    os.makedirs(os.path.dirname(nested))
    for path in (unreadable, nested, nested_locked):
        open(path, "w").write("open e2e")
    os.chmod(unreadable, 0)
    os.chmod(nested, 0)
    subprocess.run(["chflags", "uchg", nested_locked], check=True)
    before = inventory(os.path.join(root, "Profiles", "Default"))
    code, text, same_snapshot = migrate_only("unreadable")
    after = inventory(os.path.join(root, "Engine", "Default"))
    got = launch_and_check("unreadable")
    subprocess.run(["chflags", "nouchg", os.path.join(root, "Engine", "Default", "Open E2E", "nested", "locked.bin")])
    results["migration_unreadable_files"] = {
        "ok": code == 0 and before == after and same_snapshot and layout_ok(migrated_layout())
              and "oe_default=1" in got["default_cookie"],
        "inventory_equal": before == after, "snapshot_byte_identical": same_snapshot,
        "unreadable_entries": sorted(k for k, v in after.items() if v[1] == "unreadable")}
    for path in ("Open E2E unreadable.bin", "Open E2E"):
        target = os.path.join(root, "Engine", "Default", path)
        subprocess.run(["chmod", "-R", "u+rwX", target])
        shutil.rmtree(target) if os.path.isdir(target) else os.remove(target)

    # A Finder-locked top-level file blocks its rename: this launch uses the
    # old layout (the default profile works, other profiles wait), nothing
    # moves, and the next launch after unlocking finishes the migration.
    make_legacy()
    locked = os.path.join(root, "Profiles", "Default", "Open E2E locked.bin")
    open(locked, "w").write("open e2e")
    subprocess.run(["chflags", "uchg", locked], check=True)
    before = inventory(os.path.join(root, "Profiles", "Default"))
    code, text, same_snapshot = migrate_only("locked")
    untouched = inventory(os.path.join(root, "Profiles", "Default")) == before \
        and not os.path.exists(os.path.join(root, "Engine", "Default")) \
        and os.path.exists(os.path.join(root, "Profiles", "Local State"))
    got = legacy_launch_with_deferred_profile("locked-legacy-launch")
    subprocess.run(["chflags", "nouchg", locked], check=True)
    # The legacy launch ran Chromium on Profiles/Default: compare from here.
    before = inventory(os.path.join(root, "Profiles", "Default"))
    code2, text2, same_snapshot2 = migrate_only("unlocked")
    after = inventory(os.path.join(root, "Engine", "Default"))
    results["migration_locked_file"] = {
        "ok": code == 0 and same_snapshot and untouched and "legacy layout for this launch" in text
              and "oe_default=1" in got["default_cookie"] and not got["work_page_live"]
              and not got["new_work_tab_live"] and got["alive"] and got["page_contexts"] == ["Default"]
              and len(got["deferred_log_lines"]) == 1
              and code2 == 0 and same_snapshot2 and before == after and layout_ok(migrated_layout()),
        "first_launch": {"exit": code, "untouched": untouched, "snapshot_byte_identical": same_snapshot,
                         "log": [line for line in text.splitlines() if "engine layout" in line][:3],
                         "default_cookie": got["default_cookie"], "work_page_live": got["work_page_live"],
                         "new_work_tab_live": got["new_work_tab_live"], "alive": got["alive"],
                         "page_contexts": got["page_contexts"], "deferred_log_lines": got["deferred_log_lines"]},
        "after_unlock": {"exit": code2, "inventory_equal": before == after, "snapshot_byte_identical": same_snapshot2}}
    os.remove(os.path.join(root, "Engine", "Default", "Open E2E locked.bin"))

    # A crash at each step: at the crash every file is in exactly one place,
    # and the next launch finishes.
    for point in ("engine-journaled", "engine-moved", "engine-installation", "engine-staged",
                  "engine-published", "engine-cleanup"):
        make_legacy()
        before = inventory(os.path.join(root, "Profiles", "Default"))
        code, _ = run_binary("crash-" + point, OPENKIT_DEBUG_MIGRATION_CRASH=point)
        places = {}
        for base in ("Profiles/Default", "Engine/.migrating-Default", "Engine/Default"):
            if os.path.isdir(os.path.join(root, base)):
                for rel in inventory(os.path.join(root, base)):
                    places.setdefault(rel, []).append(base)
        one_place = set(places) == set(before) and all(len(v) == 1 for v in places.values())
        local_state = sum(os.path.exists(os.path.join(root, d, "Local State")) for d in ("Profiles", "Engine"))
        code2, _, _ = migrate_only("after-" + point)
        after = inventory(os.path.join(root, "Engine", "Default"))
        results["migration_crash_" + point.split("-")[1]] = {
            "ok": code == 86 and one_place and local_state == 1 and code2 == 0 and before == after
                  and layout_ok(migrated_layout()),
            "at_crash": {"exit": code, "each_file_in_one_place": one_place, "local_state_copies": local_state},
            "after_relaunch": {"exit": code2, "inventory_equal": before == after}}

    # The new folder already holds a profile: the old one is left in place
    # and reported, never mixed in.
    make_legacy()
    os.makedirs(os.path.join(root, "Engine", "Default"))
    open(os.path.join(root, "Engine", "Default", "Preferences"), "w").write("{}")
    code, text, same_snapshot = migrate_only("in-use")
    results["migration_engine_in_use"] = {
        "ok": code == 0 and same_snapshot and "Engine/Default is in use" in text
              and os.path.exists(os.path.join(root, "Profiles", "Default", "Cookies"))
              and os.path.exists(os.path.join(root, "Engine", ".open-layout")),
        "log": [line for line in text.splitlines() if "engine layout" in line][:3]}


# ----------------------------------------------------------------------------
# Measurements (run with --config Release)


def process_cpu_window(app, seconds=60):
    """OS CPU time deltas, without enabling Chromium's task-manager observer.

    rusage_info_v0 CPU times use Mach absolute ticks (not nanoseconds).
    Convert with this host's timebase. Each PID gets its own monotonic
    interval, so process discovery and ps do not skew the denominator. CPU
    is percent of one core, as in Activity Monitor, not divided by core count.
    Process churn is reported; a partial total is not idle-budget acceptance.
    """
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    class Timebase(ctypes.Structure):
        _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
    timebase = Timebase()
    if ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(timebase)) != 0 or not timebase.denom:
        raise RuntimeError('could not read Mach timebase for idle CPU sample')
    ns_per_tick = timebase.numer / timebase.denom

    def snapshot():
        app.discover_owned_processes()
        if len(app.owned_processes) > 512:
            raise RuntimeError('idle CPU sample exceeds 512 owned processes')
        rows = {}
        for pid, path in app.owned_processes.items():
            if app.process_path(pid) != path:
                continue
            # SDK sys/resource.h: ri_uuid[16], then ten uint64_t fields.
            usage = ctypes.create_string_buffer(96)
            if libproc.proc_pid_rusage(pid, 0, usage) != 0:
                continue
            values = struct.unpack('=16s10Q', usage.raw)
            stamp = time.monotonic_ns()
            process = subprocess.run(['ps', '-p', str(pid), '-o', 'time=,args='],
                                     capture_output=True, text=True, check=False).stdout.strip().split(maxsplit=1)
            if len(process) != 2:
                continue
            clock, args = process
            ps_seconds = sum(float(v) * 60 ** i for i, v in enumerate(reversed(clock.split(':'))))
            kind = ('browser' if pid == app.pid else
                    'gpu' if '--type=gpu-process' in args else
                    'renderer' if '--type=renderer' in args else
                    'network' if 'network.mojom.NetworkService' in args else
                    'utility' if '--type=utility' in args else 'other')
            rows[pid] = {'kind': kind, 'cpu_ticks': values[1] + values[2],
                         'idle_wakeups': values[3], 'interrupt_wakeups': values[4],
                         'start': values[9], 'stamp': stamp, 'ps_seconds': ps_seconds}
        if app.pid not in rows:
            raise RuntimeError('idle CPU sample could not read the Open process')
        return rows

    app.begin_timing('OS idle CPU window')
    load_start = subprocess.check_output(['sysctl', '-n', 'vm.loadavg'], text=True).strip()
    before = snapshot()
    time.sleep(seconds)
    after = snapshot()
    by_process, by_kind = [], {}
    common = {pid for pid in before.keys() & after.keys() if before[pid]['start'] == after[pid]['start']}
    for pid in sorted(common):
        a, b = before[pid], after[pid]
        elapsed = (b['stamp'] - a['stamp']) / 1e9
        cpu = (b['cpu_ticks'] - a['cpu_ticks']) * ns_per_tick / 1e9 / elapsed * 100
        by_kind[b['kind']] = by_kind.get(b['kind'], 0) + cpu
        by_process.append({'pid': pid, 'kind': b['kind'], 'seconds': round(elapsed, 3),
                           'cpu_time_ticks': b['cpu_ticks'] - a['cpu_ticks'],
                           'ps_cpu_seconds_delta': round(b['ps_seconds'] - a['ps_seconds'], 2),
                           'cpu_percent': round(cpu, 4),
                           'package_idle_wakeups_per_second': round((b['idle_wakeups'] - a['idle_wakeups']) / elapsed, 3),
                           'interrupt_wakeups_per_second': round((b['interrupt_wakeups'] - a['interrupt_wakeups']) / elapsed, 3)})
    return {'requested_seconds': seconds, 'mach_timebase': [timebase.numer, timebase.denom], 'load_start': load_start,
            'load_end': subprocess.check_output(['sysctl', '-n', 'vm.loadavg'], text=True).strip(),
            'by_process': by_process, 'by_kind': {k: round(v, 4) for k, v in by_kind.items()},
            'total_cpu_percent': round(sum(by_kind.values()), 4),
            'processes_started': sorted(after.keys() - common),
            'processes_exited': sorted(before.keys() - common),
            'complete': before.keys() == after.keys() == common}


def measure(app_factory, results, tmp):
    def mb(x):
        return round(x / 1048576, 1)

    # Load matters: the numbers are only comparable at similar load.
    results["load_average_at_start"] = [round(x, 1) for x in os.getloadavg()]
    results["cpu_count"] = os.cpu_count()

    # A fresh, one-blank-page window is a separate baseline. Never reuse a
    # restored real page and call it an empty window. Sample before metrics:
    # CefTaskManager adds a periodic CPU/memory/GPU observer while it is held.
    app = app_factory(urls=('about:blank',), fresh=True)
    try:
        time.sleep(30)
        results['idle_cpu_empty_startup_tail'] = process_cpu_window(app)
        results['idle_cpu_empty_window'] = process_cpu_window(app)
        results['idle_empty_tabs'] = app.call('tabs')
        results['idle_cpu_empty_task_manager'] = app.call('metrics', interval=10)
    finally:
        app.quit()

    # Cold-ish launch: profile already exists (second launch), one restored
    # tab. Process start to first contentful paint of that tab.
    runs = []
    for i in range(4):
        app = app_factory(urls=("https://example.com/",) if i == 0 else (), fresh=i == 0)
        try:
            tab = wait_until(lambda: (app.call("tabs") or [None])[0], timeout=20)
            app.call("wait", tab=tab["id"], timeout=30)
            time.sleep(1)
            runs.append(app.call("timing"))
        finally:
            app.quit()
    results["launch_runs"] = runs
    warm = runs[1:]
    def med(key):
        vals = sorted(r[key] for r in warm if key in r)
        return vals[len(vals) // 2] if vals else None
    results["launch_ms"] = {k: med(k) for k in ("main", "engineStarted", "engineInitialized", "windowShown",
                                                  "firstLoadEnd", "firstContentfulPaint")}

    # Memory: 1 tab, then 10 tabs (all loaded and visible once).
    app = app_factory(urls=())
    try:
        tab = app.call("tabs")[0]
        app.call("wait", tab=tab["id"], timeout=30)
        time.sleep(5)
        m1 = app.call("metrics", interval=2)
        urls = ["https://example.org/", "https://en.wikipedia.org/wiki/Web_browser", "https://www.iana.org/",
                "https://developer.mozilla.org/en-US/", "https://news.ycombinator.com/", "https://www.w3.org/",
                "https://github.com/", "https://www.rust-lang.org/", "https://www.python.org/"]
        for u in urls:
            new_tab(app, u)
        time.sleep(30)
        m10 = app.call("metrics", interval=2)
        results['idle_10_tabs_sleep_before'] = app.call('sleep-state')
        results['idle_cpu_10_tabs_startup_tail'] = process_cpu_window(app)
        results['idle_cpu_10_tabs_os'] = process_cpu_window(app)
        results['idle_10_tabs'] = app.call('tabs')
        results['idle_10_tabs_sleep'] = app.call('sleep-state')
        idle = app.call("metrics", interval=10)
    finally:
        app.quit()
    kind_names = {0: "unknown", 1: "browser", 2: "gpu", 3: "renderer", 4: "extension", 5: "utility",
                  6: "service_worker", 7: "other"}

    def summary(m):
        # Chromium's task manager (private footprint per task, by kind) and
        # the OS view (physical footprint per process, what Activity Monitor
        # shows). The totals use the OS view.
        kinds = {}
        for p in m["tasks"]:
            k = kind_names.get(p["kind"], str(p["kind"]))
            kinds[k] = round(kinds.get(k, 0) + mb(max(p["memory"], 0)), 1)
        return {"total_footprint_mb": mb(m["totalFootprint"]), "processes": len(m["processes"]),
                "live_pages": m["livePages"], "task_manager_mb_by_kind": kinds,
                "by_process": sorted(((x["name"], mb(x["footprint"])) for x in m["processes"]), key=lambda x: -x[1])}
    results["memory_1_tab"] = summary(m1)
    results["memory_10_tabs"] = summary(m10)
    # Keep the historical number explicitly labeled. CEF's CPU is per process
    # but returned per task (shared processes can repeat), and its macOS
    # refresh is 2 s: waiting 10 s does not produce a 10 s CPU average.
    results['idle_cpu_10_tabs_task_manager_percent'] = round(sum(max(p['cpu'], 0) for p in idle['tasks']), 2)
    results['idle_cpu_10_tabs_task_manager'] = idle
    results['idle_cpu_10_tabs_percent'] = results['idle_cpu_10_tabs_os']['total_cpu_percent']
    results["ok"] = True


def _fixture_server(prefix):
    import http.server
    import threading
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ("<!doctype html><title>%s %s</title><body style='background:#ffffff;color:#222'>%s %s" % (prefix, self.path, prefix, self.path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, 'http://127.0.0.1:%d' % server.server_address[1]



def _media_server():
    """Serves tools/e2e/fixtures/media on 127.0.0.1. Chromium maps *.localhost to loopback too,
    so one server gives three hosts for the site-rule checks (media-pip §8.4)."""
    import http.server
    import threading
    folder = os.path.join(ROOT, "tools", "e2e", "fixtures", "media")
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=folder, **kw)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


MEDIA_RULES = {"version": 1, "disallow": ["blocked.localhost"],
               "sites": [{"hosts": ["inaudible.localhost"], "activatesWhenInaudible": True}]}


def media_checks(factory, results, tmp):
    """media-pip §8.4 E-M1…E-M15 in the real App (phase 1: Chromium's own PiP window)."""
    server, port = _media_server()
    base = "http://127.0.0.1:%d/" % port
    # Chromium's fake capture devices (recording card): no system camera or microphone is opened, so
    # macOS shows no permission prompt. The permission itself goes through Open's real request path
    # (automation policy "grant"); Chromium's fake permission UI would skip the capture indicator.
    app = factory(urls=(base + "plain.html",), fresh=True, extra_args=["--use-fake-device-for-media-stream"])
    def m(tab): return app.call("media", tab=tab)
    def players(window=None):
        return app.call("mini-players", **({"window": window} if window else {}))
    def ids(window=None): return [c["tab"] for c in players(window)["cards"]]
    def pip(): return app.call("pip")
    def playing(tab): return m(tab)["playback"] == "playing"
    def start(tab):
        app.eval(tab, "start()")
        return wait_until(lambda: playing(tab), timeout=10, step=.05)
    def is_audible(tab): return next((t for t in app.call("tabs") if t["id"] == tab), {}).get("audible") is True
    def start_heard(tab):
        # Auto-PiP needs real audibility (A4). Chromium's signal (P6) follows the audio output a few
        # hundred ms after playback starts, so a leave right after play() would see "inaudible".
        ok = start(tab)
        t0 = time.monotonic()
        heard = wait_until(lambda: is_audible(tab), timeout=3, step=.02)
        return ok and bool(heard), round((time.monotonic() - t0) * 1000, 1)
    def select(tab):
        app.call("select", tab=tab)
        wait_until(lambda: app.call("window-state")["selected"] == tab, timeout=5, step=.02)
    def open_tab(url):
        t = new_tab(app, url)
        wait_until(lambda: app.eval(t, "document.readyState") == "complete", timeout=10, step=.05)
        return t
    def wait_pip(state, timeout=3):
        return wait_until(lambda: (lambda p: p if p["state"] == state else None)(pip()), timeout=timeout, step=.01) or pip()
    def close_tab(tab):
        app.call("close", tab=tab)
    # Start from the defaults the checks expect; a run killed mid-check (or another suite) can leave
    # these keys behind in the shared defaults domain.
    for key in ("open.advanced.enablePictureInPictureOnLeave", "open.pip.autoDisabledHosts", "open.pip.keepOnTop"):
        app.call("defaults", key=key, value=None)
    try:
        app.call("window-frame", frame=[80, 60, 1280, 820])
        home = app.call("tabs")[0]["id"]
        app.call("wait", tab=home)
        # E-M1: audible tab, row speaker, mute through the model, survives relaunch (checked at the end).
        audio = open_tab(base + "audio.html")
        ok_play = start(audio)
        audible = wait_until(lambda: next((t for t in app.call("tabs") if t["id"] == audio and t["audible"]), None), timeout=5, step=.05)
        state = m(audio)
        app.call("media-action", tab=audio, action="toggle-mute")
        muted = m(audio)
        element_muted = app.eval(audio, "document.getElementById('tone').muted")
        results["media_audio_state"] = {"ok": bool(ok_play) and bool(audible) and state["controllable"] and state["title"] == "Open Test Tone"
            and state["artist"] == "Open" and "nextTrack" in state["actions"] and "previousTrack" in state["actions"]
            and muted["muted"] and muted["modelMuted"] and element_muted is False,
            "state": state, "muted": muted, "elementMuted": element_muted}
        app.call("media-action", tab=audio, action="toggle-mute")

        # E-M3: the card appears when the source leaves the screen, and goes when it comes back.
        select(home)
        t0 = time.monotonic()
        listed = wait_until(lambda: audio in ids(), timeout=1, step=.005)
        appear_ms = (time.monotonic() - t0) * 1000
        card = players()["cards"][0] if listed else None
        select(audio)
        gone = wait_until(lambda: not ids(), timeout=1, step=.01)
        results["media_card_on_leave"] = {"ok": bool(listed) and bool(gone) and appear_ms < 1000
            and card is not None and set(["favicon", "previous", "play", "next", "volume"]) <= set(card["buttons"]),
            "appearMs": round(appear_ms, 1), "load": os.getloadavg(), "card": card}

        # E-M4: the card's controls reach the page (Chromium's media session; next/previous route to the page's handlers).
        select(home)
        wait_until(lambda: audio in ids(), timeout=2, step=.01)
        app.call("media-click", tab=audio, target="play")
        paused = wait_until(lambda: app.eval(audio, "document.getElementById('tone').paused"), timeout=3, step=.05)
        card_paused = wait_until(lambda: (lambda c: c if c and c[0]["playback"] == "paused" else None)(players()["cards"]), timeout=2, step=.02)
        app.call("media-click", tab=audio, target="play")
        resumed = wait_until(lambda: app.eval(audio, "document.getElementById('tone').paused") is False, timeout=3, step=.05)
        app.call("media-click", tab=audio, target="next")
        next_count = wait_until(lambda: (lambda c: c if c["nexttrack"] == 1 else None)(app.eval(audio, "__counts")), timeout=3, step=.05)
        app.call("media-click", tab=audio, target="previous")
        counts = wait_until(lambda: (lambda c: c if c["nexttrack"] == 1 and c["previoustrack"] == 1 else None)(app.eval(audio, "__counts")), timeout=3, step=.05)
        counts = counts or {"afterNext": next_count, "final": app.eval(audio, "__counts")} if not counts else counts
        results["media_card_controls"] = {"ok": bool(paused) and bool(card_paused) and bool(resumed) and counts.get("nexttrack") == 1
            and counts.get("previoustrack") == 1, "paused": bool(paused), "cardPaused": bool(card_paused), "resumed": bool(resumed), "counts": counts}

        # E-M3: a Space switch away lists it; another window does not.
        home_space = app.call("tab-state", tab=audio)["space"]
        app.call("space-create", title="Media Other")
        other_space = wait_until(lambda: audio in ids(), timeout=2, step=.02)
        app.call("command", id="new-window")
        second = wait_until(lambda: (lambda w: w if len(w) >= 2 else None)(app.call("shell-windows")), timeout=5, step=.05)
        second_cards = ids() if second else None
        if second:
            app.call("command", id="close-window")
            wait_until(lambda: len(app.call("shell-windows")) == 1, timeout=5, step=.05)
        app.call("space", space=home_space)
        results["media_card_scope"] = {"ok": bool(other_space) and second_cards == [], "secondWindowCards": second_cards}

        # E-M3: four sources, three cards, newest first.
        extra = []
        for i in range(3):
            t = open_tab(base + "audio.html?n=%d" % i); start(t); extra.append(t)
        select(home)
        four = wait_until(lambda: (lambda c: c if len(c) == 3 else None)(ids()), timeout=3, step=.02)
        results["media_cards_max_three"] = {"ok": four == list(reversed(extra)), "cards": four, "sources": [audio] + extra}
        for t in extra: close_tab(t)
        wait_until(lambda: ids() == [audio], timeout=3, step=.02)

        # E-M15 / D-11: idle CPU with a paused card on screen equals idle CPU without it.
        # Alternate the two states (paused card shown / hidden by a sidebar toggle-free Space switch is not
        # equivalent, so the card leaves by selecting its own tab and comes back by leaving it again).
        app.call("media-action", tab=audio, action="pause")
        wait_until(lambda: (lambda c: c if c and c[0]["playback"] == "paused" else None)(players()["cards"]), timeout=3, step=.02)
        def cpu(x): return round(sum(max(p["cpu"], 0) for p in x["tasks"]), 2)
        def browser_cpu(x): return round(sum(max(p["cpu"], 0) for p in x["tasks"] if p.get("kind") == 1), 2)
        samples = {"with": [], "without": [], "browserWith": [], "browserWithout": [], "load": []}
        card_view = players()
        rest_animations = []
        for _ in range(4):
            time.sleep(6); rest_animations.append(players()["animations"]); x = app.call("metrics", interval=8)
            samples["with"].append(cpu(x)); samples["browserWith"].append(browser_cpu(x)); samples["load"].append(os.getloadavg()[0])
            app.call("media-action", tab=audio, action="close"); wait_until(lambda: not ids(), timeout=3, step=.02)
            time.sleep(6); x = app.call("metrics", interval=8)
            samples["without"].append(cpu(x)); samples["browserWithout"].append(browser_cpu(x)); samples["load"].append(os.getloadavg()[0])
            # Back to a shown paused card: play (clears the dismissal), pause again.
            app.call("media-action", tab=audio, action="play"); wait_until(lambda: audio in ids(), timeout=3, step=.02)
            app.call("media-action", tab=audio, action="pause")
            wait_until(lambda: (lambda c: c if c and c[0]["playback"] == "paused" else None)(players()["cards"]), timeout=3, step=.02)
        # Other work on the Mac only adds CPU, so compare the floor of four interleaved pairs; the
        # structural part (no animation keys, no pending collapse) holds in every sample.
        results["media_idle_cpu"] = {"ok": abs(min(samples["with"]) - min(samples["without"])) <= 0.5
            and abs(min(samples["browserWith"]) - min(samples["browserWithout"])) <= 0.5
            and card_view["pendingCollapse"] == 0 and rest_animations == [0] * len(rest_animations),
            "minWith": min(samples["with"]), "minWithout": min(samples["without"]),
            "browserMinWith": min(samples["browserWith"]), "browserMinWithout": min(samples["browserWithout"]),
            "restAnimations": rest_animations, "samples": samples}
        app.call("media-action", tab=audio, action="close"); wait_until(lambda: not ids(), timeout=3, step=.02)
        close_tab(audio)

        # E-M5: auto-PiP on leave within 500 ms; back closes it, video keeps playing.
        video = open_tab(base + "video.html")
        _, video_audible_ms = start_heard(video)
        windows_before = len(app.call("windows"))
        select(home)
        opened = wait_pip("active", timeout=3)
        p = pip()
        latency = (p.get("enteredAt") or 0) - (p.get("requestedAt") or 0) if p.get("enteredAt") else None
        decision = m(video)["decision"]
        leave_to_request = (p.get("requestedAt") or 0) - (decision["at"] if decision else 0)
        pip_windows = p.get("windows", [])
        # Phase 1 shows Chromium's frameless window; phase 2 (EM-4) Open's own window and no Chromium one.
        phase = p.get("phase", 1)
        shown = len(pip_windows) >= 1 if phase == 1 else bool((p.get("openWindow") or {}).get("visible")) and not pip_windows
        results["media_auto_pip_on_leave"] = {"ok": opened["state"] == "active" and opened.get("automatic") is True and opened.get("tab") == video
            and latency is not None and latency <= 0.5 and shown and abs(leave_to_request) < 0.05, "phase": phase,
            "pip": p, "requestToEnterSeconds": latency, "leaveToRequestSeconds": leave_to_request,
            "load": os.getloadavg(), "windowsBefore": windows_before, "decision": decision, "audibleAfterPlayMs": video_audible_ms,
            "autoPiPSetting": app.call("defaults", key="open.advanced.enablePictureInPictureOnLeave")}
        # Sleep feed (§4.10): the PiP source is protected.
        feed = app.call("sleep-visibility")
        results["media_sleep_feed_pip"] = {"ok": video in feed["pictureInPicture"], "feed": feed}
        select(video)
        closed = wait_until(lambda: (lambda p: p if p["state"] == "closed" and not m(video)["pictureInPicture"] else None)(pip()), timeout=1, step=.01)
        still = app.eval(video, "document.getElementById('main').paused") is False
        results["media_auto_pip_return"] = {"ok": bool(closed) and still and closed.get("reason") == "sourceShown", "pip": pip(), "playing": still}

        # E-M7: Close pauses and snoozes until the tab shows again.
        select(home); wait_pip("active")
        app.call("pip-action", action="close")
        closed = wait_until(lambda: (lambda p: p if p["state"] == "closed" else None)(pip()), timeout=3, step=.02)
        paused = wait_until(lambda: app.eval(video, "document.getElementById('main').paused"), timeout=3, step=.05)
        snoozed = video in pip()["snoozed"]
        select(video); app.eval(video, "start()"); wait_until(lambda: is_audible(video), timeout=3, step=.02); select(home)
        again = wait_pip("active")
        results["media_close_snoozes"] = {"ok": bool(closed) and closed.get("reason") == "userClosed" and bool(paused) and snoozed
            and again["state"] == "active", "closed": closed, "paused": bool(paused), "snoozed": snoozed, "again": again}

        # E-M9: Back to Tab selects the tab, closes PiP, keeps playing.
        app.call("pip-action", action="back-to-tab")
        back = wait_until(lambda: (lambda p: p if p["state"] == "closed" else None)(pip()), timeout=3, step=.02)
        ws = app.call("window-state")
        # Phase 2 closes the engine's PiP when the window's return animation ends.
        page_left = wait_until(lambda: not m(video)["pictureInPicture"], timeout=3, step=.02)
        playing_after = app.eval(video, "document.getElementById('main').paused") is False
        results["media_back_to_tab"] = {"ok": bool(back) and ws["selected"] == video and playing_after and bool(page_left),
            "pip": back, "selected": ws["selected"], "pageLeftPiP": bool(page_left)}

        # E-M6: negatives, each from a fresh leave.
        def leave_decision(tab):
            select(tab); select(home)
            time.sleep(.3)
            return m(tab)["decision"]["value"], pip()["state"]
        # The App's defaults domain is shared by every Debug run on this Mac: always restore the key.
        app.call("defaults", key="open.advanced.enablePictureInPictureOnLeave", value=False)
        try:
            setting_off = leave_decision(video)
        finally:
            app.call("defaults", key="open.advanced.enablePictureInPictureOnLeave", value=None)
        close_tab(video)
        muted_video = open_tab(base + "video-muted.html"); start(muted_video)
        inaudible = leave_decision(muted_video)
        close_tab(muted_video)
        nopip = open_tab(base + "video-nopip.html"); start_heard(nopip)
        disabled = leave_decision(nopip)
        close_tab(nopip)
        blocked = open_tab("http://blocked.localhost:%d/video.html" % port); start_heard(blocked)
        disallowed = leave_decision(blocked)
        close_tab(blocked)
        relaxed = open_tab("http://inaudible.localhost:%d/video-muted.html" % port); start(relaxed)
        relaxed_result = leave_decision(relaxed)
        if pip()["state"] == "active": select(relaxed); wait_pip("closed")
        close_tab(relaxed)
        results["media_auto_pip_negatives"] = {"ok": setting_off[0] == "settingOff" and inaudible[0] == "inaudible"
            and disabled[0] == "videoDisabled" and disallowed[0] == "disallowed" and relaxed_result[0] == "open",
            "settingOff": setting_off, "inaudible": inaudible, "disablePictureInPicture": disabled,
            "disallowed": disallowed, "activatesWhenInaudible": relaxed_result}

        # E-M10: the largest playing video goes to PiP.
        two = open_tab(base + "two-videos.html"); start_heard(two)
        select(home); wait_pip("active")
        chosen = app.eval(two, "document.pictureInPictureElement && document.pictureInPictureElement.id")
        select(two); wait_pip("closed")
        close_tab(two)
        results["media_largest_video"] = {"ok": chosen == "large", "chosen": chosen}

        # E-M11: Chromium's system media controls (Now Playing, media keys) in Open.
        audio = open_tab(base + "audio.html"); start(audio)
        now = wait_until(lambda: (lambda n: n if n["title"] == "Open Test Tone" and n["playbackState"] == "playing" else None)(app.call("now-playing")), timeout=5, step=.1) or app.call("now-playing")
        app.call("media-action", tab=audio, action="pause")
        now_paused = wait_until(lambda: (lambda n: n if n["playbackState"] == "paused" else None)(app.call("now-playing")), timeout=3, step=.1) or app.call("now-playing")
        results["media_now_playing"] = {"ok": now["title"] == "Open Test Tone" and now["artist"] == "Open" and now["playbackState"] == "playing"
            and now_paused["playbackState"] == "paused" and all(now["commands"][k] for k in ("play", "pause", "next", "previous")),
            "playing": now, "paused": now_paused}

        # E-M12 (feed only; the App sleep adapter is section 8's): a shown paused card protects its tab.
        select(home)
        wait_until(lambda: audio in ids(), timeout=2, step=.02)
        feed = app.call("sleep-visibility")
        app.call("media-action", tab=audio, action="close")
        wait_until(lambda: not ids(), timeout=2, step=.02)
        feed_after = app.call("sleep-visibility")
        results["media_sleep_feed_card"] = {"ok": audio in feed["mediaControls"] and audio not in feed_after["mediaControls"],
            "withCard": feed["mediaControls"], "afterClose": feed_after["mediaControls"]}

        # Close removes the source: the card leaves with the tab.
        app.eval(audio, "start()"); wait_until(lambda: audio in ids(), timeout=2, step=.02)
        close_tab(audio)
        results["media_card_leaves_on_close"] = {"ok": bool(wait_until(lambda: not ids(), timeout=2, step=.02))}

        # Mute All / Unmute All: app-wide, one Undo.
        a1 = open_tab(base + "audio.html?all=1"); a2 = open_tab(base + "audio.html?all=2")
        app.call("media-action", action="mute-all")
        all_muted = all(m(t)["muted"] and m(t)["modelMuted"] for t in (a1, a2))
        app.call("menu-perform", id="undo")
        undone = wait_until(lambda: not any(m(t)["muted"] or m(t)["modelMuted"] for t in (a1, a2)), timeout=3, step=.05)
        app.call("media-action", action="mute-all"); app.call("media-action", action="unmute-all")
        unmuted = not any(m(t)["modelMuted"] or m(t)["muted"] for t in (a1, a2))
        results["media_mute_all"] = {"ok": all_muted and bool(undone) and unmuted, "allMuted": all_muted,
            "undoneInOneStep": bool(undone), "unmuted": unmuted, "states": [m(t) for t in (a1, a2)]}
        # View Media (Window menu): Arc's viewScreenshotsAndCaptures: opens the Library's Media section.
        app.call("menu-perform", id="view-media")
        library = wait_until(lambda: (lambda l: l if l["visible"] and l["section"] == "media" else None)(app.call("library-section")), timeout=5, step=.05)
        app.call("library-close")
        results["media_view_media_menu"] = {"ok": bool(library), "library": app.call("library-section") if not library else library}
        # E-M2 / P6 (EM-3): audible is Chromium's own signal, so Web Audio counts, in a background tab too
        # (OpenSleep's contract: an audio event for every change).
        def audible(tab): return next((t for t in app.call("tabs") if t["id"] == tab), {}).get("audible") is True
        def elapsed_ms(t0): return round((time.monotonic() - t0) * 1000, 1)
        wa = open_tab(base + "webaudio.html")
        t0 = time.monotonic(); app.eval(wa, "start()")
        heard = wait_until(lambda: audible(wa), timeout=1, step=.02); heard_ms = elapsed_ms(t0)
        t0 = time.monotonic(); app.eval(wa, "__ctx.suspend().then(() => true)")
        quiet_suspend = wait_until(lambda: not audible(wa), timeout=3, step=.05); suspend_ms = elapsed_ms(t0)
        select(home)
        t0 = time.monotonic(); app.eval(wa, "__ctx.resume().then(() => true)")
        heard_background = wait_until(lambda: audible(wa), timeout=1, step=.02); background_ms = elapsed_ms(t0)
        t0 = time.monotonic(); app.eval(wa, "__ctx.close().then(() => true)")
        quiet_close = wait_until(lambda: not audible(wa), timeout=3, step=.05); close_ms = elapsed_ms(t0)
        wa_media = m(wa)
        results["media_web_audio"] = {"ok": bool(heard) and heard_ms <= 1000 and bool(quiet_suspend) and bool(heard_background)
            and background_ms <= 1000 and bool(quiet_close) and not wa_media["session"],
            "audibleMs": heard_ms, "inaudibleAfterSuspendMs": suspend_ms, "audibleInBackgroundMs": background_ms,
            "inaudibleAfterCloseMs": close_ms, "session": wa_media["session"]}
        close_tab(wa)

        # EM-2: tab volume. The engine scales the page's players (MediaSessionImpl); the page's own
        # element volume stays 1 and the page keeps playing. Read back through the session snapshot.
        vt = open_tab(base + "audio.html?volume=1"); start(vt)
        before = m(vt)
        app.call("media-action", tab=vt, action="volume", value=0.3)
        after = wait_until(lambda: (lambda x: x if x["volume"] is not None and abs(x["volume"] - 0.3) < 1e-9 else None)(m(vt)), timeout=2, step=.02) or m(vt)
        time.sleep(.5)
        vt_playing = app.eval(vt, "!document.getElementById('tone').paused && document.getElementById('tone').currentTime > 0")
        vt_element = app.eval(vt, "document.getElementById('tone').volume")
        app.call("media-action", tab=vt, action="volume", value=1)
        reset = wait_until(lambda: (lambda x: x if x["volume"] == 1 else None)(m(vt)), timeout=2, step=.02) or m(vt)
        results["media_tab_volume"] = {"ok": before["volume"] == 1 and after["volume"] is not None and abs(after["volume"] - 0.3) < 1e-9
            and abs(after["pageVolume"] - 0.3) < 1e-9 and after["playback"] == "playing" and vt_playing is True and vt_element == 1
            and reset["volume"] == 1, "before": before["volume"], "after": after["volume"], "pageVolume": after["pageVolume"],
            "playback": after["playback"], "pagePlaying": vt_playing, "elementVolume": vt_element, "reset": reset["volume"]}
        close_tab(vt)

        # Step 8 volume drawer (§13.7 O2): Volume on an expanded card opens a 33 pt drawer row (card 66 -> 99);
        # a click on the slider sets the engine's tab volume, the high end sets 100 %, the low end toggles
        # mute; moving off the stack collapses it and closes the drawer. Real mouse events on the card.
        dv = open_tab(base + "audio.html"); start(dv); select(home)
        wait_until(lambda: dv in ids(), timeout=2, step=.01)
        def dcard(): return next((c for c in players()["cards"] if c["tab"] == dv), None)
        def settled(pred): return wait_until(lambda: (lambda c: c if c and pred(c) and not players()["animations"] else None)(dcard()), timeout=2, step=.02)
        closed_height = (dcard() or {}).get("height")
        app.call("media-click", tab=dv, target="volume")
        drawer = settled(lambda c: c["drawerOpen"] and abs(c["height"] - 99) < .5)
        slid = app.call("media-click", tab=dv, target="slider", fraction=0.25)
        quarter = wait_until(lambda: (lambda x: x if x["volume"] is not None and abs(x["volume"] - 0.25) < 1e-9 else None)(m(dv)), timeout=2, step=.02) or m(dv)
        dv_element = app.eval(dv, "document.getElementById('tone').volume")
        dv_playing = app.eval(dv, "!document.getElementById('tone').paused")
        app.call("media-click", tab=dv, target="volumeHigh")
        full = wait_until(lambda: m(dv)["volume"] == 1 and (dcard() or {}).get("slider") == "100%", timeout=2, step=.02)
        app.call("media-click", tab=dv, target="volumeLow")
        low_muted = wait_until(lambda: m(dv)["modelMuted"] is True and m(dv)["muted"] is True, timeout=2, step=.02)
        app.call("media-click", tab=dv, target="volumeLow")
        low_unmuted = wait_until(lambda: m(dv)["modelMuted"] is False, timeout=2, step=.02)
        off = drawer["frame"] if drawer else [0, 0, 0, 0]
        app.call("mouse", action="hover", x=off[0] + 40, y=160)
        collapsed = wait_until(lambda: (lambda c: c if c and not c["drawerOpen"] and not c["expanded"] and not players()["animations"] else None)(dcard()), timeout=3, step=.02)
        results["media_volume_drawer"] = {"ok": bool(drawer) and slid.get("value") == "25%" and quarter["volume"] is not None
            and abs(quarter["volume"] - 0.25) < 1e-9 and abs(quarter["pageVolume"] - 0.25) < 1e-9 and dv_element == 1 and dv_playing is True
            and bool(full) and bool(low_muted) and bool(low_unmuted) and bool(collapsed),
            "closedHeight": closed_height, "drawer": {k: drawer[k] for k in ("height", "drawerOpen", "slider", "buttons")} if drawer else None,
            "slider": slid, "volumeAfterSlider": quarter["volume"], "pageVolume": quarter["pageVolume"], "elementVolume": dv_element,
            "playing": dv_playing, "full": bool(full), "lowMutes": bool(low_muted), "lowUnmutes": bool(low_unmuted),
            "collapsed": {k: collapsed[k] for k in ("height", "drawerOpen", "expanded")} if collapsed else dcard()}
        close_tab(dv)

        # Step 8 recording card (Q13, PP-19): a meeting-like page (fake camera and microphone, MediaStream
        # players only, so never controllable) gets a card with its microphone and camera toggles; the
        # toggles reach the page's own handlers; the card goes when capture stops.
        # Auto-PiP is off for this row: the playing preview would otherwise open a PiP window on the leave,
        # and a source in PiP has no card (rule 3).
        def recording_card_row(results):
            app.call("policy", permissions="grant")
            app.call("defaults", key="open.advanced.enablePictureInPictureOnLeave", value=False)
            rec = open_tab(base + "recording.html")
            rec_started = app.eval(rec, "start()")
            rec_capturing = wait_until(lambda: m(rec)["capturing"] is True, timeout=5, step=.05)
            rec_state = m(rec)
            rec_audible = is_audible(rec)
            select(home)
            def rcard(): return next((c for c in players()["cards"] if c["tab"] == rec), None)
            rec_card = wait_until(lambda: (lambda c: c if c and c["kind"] == "recording" else None)(rcard()), timeout=3, step=.02)
            app.call("media-click", tab=rec, target="microphone")
            mic_off = wait_until(lambda: (lambda c: c if c and c["microphoneOn"] is False else None)(rcard()), timeout=2, step=.02)
            app.call("media-click", tab=rec, target="camera")
            cam_off = wait_until(lambda: (lambda c: c if c and c["cameraOn"] is False else None)(rcard()), timeout=2, step=.02)
            rec_page = app.eval(rec, "state()")
            still_capturing = m(rec)["capturing"]
            app.eval(rec, "stop()")
            rec_gone = wait_until(lambda: rec not in ids(), timeout=5, step=.05)
            app.call("defaults", key="open.advanced.enablePictureInPictureOnLeave", value=None)
            app.call("policy", permissions="")
            results["media_recording_card"] = {"ok": rec_started is True and bool(rec_capturing) and rec_state["controllable"] is False
                and bool(rec_card) and {"favicon", "microphone", "camera"} <= set(rec_card["buttons"])
                and not ({"play", "previous", "next", "volume"} & set(rec_card["buttons"])) and rec_card["microphoneOn"] is True
                and rec_card["cameraOn"] is True and bool(mic_off) and bool(cam_off) and rec_page["counts"]["togglemicrophone"] == 1
                and rec_page["counts"]["togglecamera"] == 1 and rec_page["mic"] is False and rec_page["cam"] is False
                and still_capturing is True and bool(rec_gone),
                "started": rec_started, "state": {k: rec_state.get(k) for k in ("capturing", "controllable", "playback", "actions", "source")},
                "card": rec_card, "page": rec_page, "stillCapturing": still_capturing, "gone": bool(rec_gone), "audibleAtLeave": rec_audible,
                "decision": m(rec)["decision"]}
            close_tab(rec)

        # Chromium asks macOS for camera and microphone access while their status is undetermined, even
        # with fake devices; that prompt lands on the user's screen. The row runs only when macOS has
        # already granted both and never asks.
        capture_permission = app.call("capture-permission")
        if capture_permission != {"camera": "authorized", "microphone": "authorized"}:
            results["media_recording_card"] = {"status": "BLOCKED", "permission": capture_permission,
                "reason": "macOS camera/microphone access is not granted to this build; the suite does not ask (a system prompt)"}
        else:
            recording_card_row(results)

        # EM-5: PiP from the browser needs no user gesture, and the browser enforces disablePictureInPicture
        # (Blink's browser-initiated path skips that check). Page reads go through Runtime.evaluate without
        # a gesture, so they do not grant one.
        def quiet_eval(tab, js):
            r = app.call("devtools", tab=tab, method="Runtime.evaluate",
                         params={"expression": js, "userGesture": False, "returnByValue": True, "awaitPromise": True})
            return (r or {}).get("result", {}).get("value")
        ng = open_tab(base + "video.html"); start(ng)
        expired = wait_until(lambda: quiet_eval(ng, "navigator.userActivation.isActive") is False, timeout=10, step=.25)
        page_attempt = quiet_eval(ng, "document.getElementById('main').requestPictureInPicture().then(() => 'entered', e => e.name)")
        if page_attempt == "entered":
            quiet_eval(ng, "document.exitPictureInPicture().then(() => true)")
        app.call("media-action", tab=ng, action="pip")
        entered = wait_pip("active", timeout=3)
        ng_p = pip()
        ng_latency = (ng_p.get("enteredAt") or 0) - (ng_p.get("requestedAt") or 0) if ng_p.get("enteredAt") else None
        ng_element = quiet_eval(ng, "document.pictureInPictureElement && document.pictureInPictureElement.id")
        ng_active = quiet_eval(ng, "navigator.userActivation.isActive")
        app.call("media-action", tab=ng, action="exit-pip")
        ng_closed = wait_until(lambda: not m(ng)["pictureInPicture"], timeout=2, step=.02)
        ng_still = quiet_eval(ng, "!document.getElementById('main').paused")
        results["media_pip_no_gesture"] = {"ok": bool(expired) and page_attempt == "NotAllowedError" and entered["state"] == "active"
            and ng_element == "main" and ng_active is False and ng_latency is not None and ng_latency <= 0.5 and bool(ng_closed) and ng_still is True,
            "activationExpired": bool(expired), "pageRequestWithoutGesture": page_attempt, "pip": ng_p, "requestToEnterSeconds": ng_latency,
            "pipElement": ng_element, "activationAfter": ng_active, "closed": bool(ng_closed), "playingAfterExit": ng_still}
        close_tab(ng)
        nd = open_tab(base + "video-nopip.html"); start(nd)
        nd_state = m(nd)
        nd_requests = pip()["requests"]
        app.call("media-action", tab=nd, action="pip")
        nd_result = wait_until(lambda: (lambda p: p if p["requests"] > nd_requests and p.get("tab") == nd
                                        and p["state"] in ("closed", "active") else None)(pip()), timeout=3, step=.02) or pip()
        nd_element = quiet_eval(nd, "document.pictureInPictureElement && document.pictureInPictureElement.id")
        results["media_pip_disabled_engine"] = {"ok": nd_state["pictureInPictureDisabled"] is True
            and "enterPictureInPicture" not in nd_state["actions"] and nd_result["state"] == "closed"
            and nd_result.get("reason") == "failed" and nd_element is None and not m(nd)["pictureInPicture"],
            "state": {k: nd_state[k] for k in ("pictureInPictureDisabled", "actions", "playback")}, "pip": nd_result, "pipElement": nd_element}
        close_tab(nd)
        # Steps 9-10 (EM-4): Open's own PiP window shows the engine's video, live. Two snapshots of
        # that window 0.5 s apart: the canvas video changes its hue every frame.
        # A file-backed video: MediaStream players are never controllable, so they never get a card
        # (Minimize leaves one). start() records the page's own 3 s WebM first.
        fv = open_tab(base + "video-file.html")
        start_heard(fv); select(home)
        fp = wait_pip("active")
        if fp.get("phase", 1) == 2:
            ow = wait_until(lambda: (lambda o: o if o and o.get("visible") else None)(pip().get("openWindow")), timeout=3, step=.02)
            time.sleep(.6)
            # The engine's composited picture of the video view (`pip-frame`): the window server
            # leaves out GPU-process layers on macOS 26, so a window snapshot shows no video.
            shots = []
            for i in range(2):
                path = os.path.join(tmp, "pip-frame-%d.png" % i)
                shot = app.call("pip-frame", path=path) if ow else {}
                shots.append((path, shot.get("bytes"))); time.sleep(.5)
            def grid(path):
                w, h, px = read_image(path)
                return (w, h), [px(w * (i + .5) / 8, h * (j + .5) / 6) for i in range(8) for j in range(6)]
            (size0, px0), (size1, px1) = grid(shots[0][0]), grid(shots[1][0])
            lit = sum(1 for c in px0 if max(c) > 40)
            moved = sum(1 for c, d in zip(px0, px1) if max(abs(c[k] - d[k]) for k in range(3)) > 12)
            results["media_pip_frames"] = {"ok": bool(ow) and lit >= 24 and moved >= 24 and not pip()["windows"],
                "lit": lit, "moved": moved, "of": len(px0), "size": [size0, size1], "bytes": [b for _, b in shots],
                "window": ow, "chromiumWindows": pip()["windows"], "load": os.getloadavg()}
            # E-M8: Minimize hides the window, keeps playing and leaves a card that reopens PiP.
            app.call("pip-action", action="minimize")
            minimized = wait_pip("minimized")
            hidden = wait_until(lambda: not (pip().get("openWindow") or {}).get("visible"), timeout=2, step=.02)
            min_playing = app.eval(fv, "!document.getElementById('main').paused")
            min_card = wait_until(lambda: next((c for c in players()["cards"] if c["tab"] == fv), None), timeout=3, step=.02)
            if min_card:
                app.call("media-click", tab=fv, target="pip")
            reopened = wait_pip("active")
            reshown = wait_until(lambda: (lambda o: o if o and o.get("visible") else None)(pip().get("openWindow")), timeout=3, step=.02)
            results["media_pip_minimize"] = {"ok": minimized["state"] == "minimized" and bool(hidden) and min_playing is True
                and bool(min_card) and reopened["state"] == "active" and bool(reshown),
                "minimized": minimized, "playing": min_playing, "card": bool(min_card), "reopened": reopened["state"]}
            # E-M14: Keep Window on Top (PP-8) changes the window level and the setting, both ways.
            items = app.call("pip-action", action="menu")
            level0 = (pip().get("openWindow") or {}).get("level")
            setting0 = app.call("defaults", key="open.pip.keepOnTop")
            app.call("pip-action", action="menu", item="Keep Window on Top")
            level1 = (wait_until(lambda: (lambda o: o if o and o.get("level") != level0 else None)(pip().get("openWindow")), timeout=2, step=.02) or {}).get("level")
            setting1 = app.call("defaults", key="open.pip.keepOnTop")
            app.call("pip-action", action="menu", item="Keep Window on Top")
            level2 = (wait_until(lambda: (lambda o: o if o and o.get("level") == level0 else None)(pip().get("openWindow")), timeout=2, step=.02) or {}).get("level")
            results["media_pip_keep_on_top"] = {"ok": any(i.startswith("Keep Window on Top") for i in items) and level1 is not None
                and level1 != level0 and level2 == level0 and setting1 != setting0,
                "items": items, "levels": [level0, level1, level2], "settings": [setting0, setting1]}
            app.call("defaults", key="open.pip.keepOnTop", value=None)
        else:
            results["media_pip_frames"] = {"status": "BLOCKED", "reason": "EM-4: phase 1 shows Chromium's window"}
            results["media_pip_minimize"] = {"status": "BLOCKED", "reason": "EM-4: phase 1 uses Chromium's PiP window, which has no Minimize"}
            results["media_pip_keep_on_top"] = {"status": "BLOCKED", "reason": "EM-4: the Keep Window on Top menu is in Open's own PiP window"}
        select(fv); wait_pip("closed")
        close_tab(fv)
        results["media_document_pip"] = {"status": "BLOCKED", "reason": "EM-7: Document PiP disposition"}
        # Item 16 (criterion 6) with section 8's sleep controller (#156): a paused tab whose mini player
        # shows survives a pass that sleeps an idle background tab; after Close (the card goes) the same
        # pass may sleep it. The controller's clock moves; no wall-clock wait.
        def sstate(tab): return next(iter(app.call("sleep-state", tab=tab)["tabs"]), {})
        held = open_tab(base + "audio.html"); start(held)
        idle = open_tab(base + "plain.html")
        select(home)
        wait_until(lambda: held in ids(), timeout=2, step=.02)
        app.call("media-click", tab=held, target="play")
        held_paused = wait_until(lambda: app.eval(held, "document.getElementById('tone').paused"), timeout=3, step=.05)
        wait_until(lambda: not is_audible(held), timeout=5, step=.05)
        app.call("sleep-start")
        app.call("sleep-clock", advance=86400.0)
        app.call("sleep-tick")
        held_after, idle_after = sstate(held), sstate(idle)
        feed_has = held in app.call("sleep-visibility")["mediaControls"]
        app.call("media-click", tab=held, target="close")
        wait_until(lambda: held not in ids(), timeout=3, step=.02)
        wait_until(lambda: held not in app.call("sleep-visibility")["mediaControls"], timeout=3, step=.02)
        app.call("sleep-clock", advance=86400.0)
        app.call("sleep-tick")
        held_closed = sstate(held)
        results["media_sleep_adapter"] = {"ok": bool(held_paused) and feed_has and held_after.get("phase") == "live"
            and held_after.get("freezeGate") is not None and idle_after.get("phase") in ("frozen", "sleeping")
            and held_closed.get("phase") in ("frozen", "sleeping"),
            "held": {k: held_after.get(k) for k in ("phase", "freezeGate", "discardGate", "audible")},
            "idle": {k: idle_after.get(k) for k in ("phase", "freezeGate")},
            "afterClose": {k: held_closed.get(k) for k in ("phase", "freezeGate")}, "feedHadTab": feed_has}
        app.call("sleep-clock", reset=True)
        close_tab(held); close_tab(idle)
        # E-M1 persistence: a muted tab stays muted after relaunch.
        app.call("media-action", tab=a1, action="toggle-mute")
        app.call("save"); app.quit()
        app = factory(urls=())
        kept = wait_until(lambda: next((t for t in app.call("tabs") if t["id"] == a1), None), timeout=10, step=.1)
        state = m(a1) if kept else {}
        results["media_mute_survives_relaunch"] = {"ok": bool(kept) and state.get("modelMuted") is True, "state": state}
    finally:
        app.quit(); server.shutdown(); server.server_close()


def _sleep_server():
    """Serves the memory-fork fixtures (Engine/fork/verification/fixtures) at / and the media
    fixtures at /media/ on 127.0.0.1. Any other path answers a small page titled with its path.
    Chromium maps *.localhost to loopback, so one server gives distinct sites (one renderer
    each) and a Gmail-like host the built-in keep-alive table matches (mail.google.*/mail)."""
    import html as _html
    import http.server
    import threading
    fixtures = os.path.join(ROOT, "Engine", "fork", "verification", "fixtures")
    media = os.path.join(ROOT, "tools", "e2e", "fixtures", "media")
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split("?")[0]
            folder, name = (media, path[len("/media/"):]) if path.startswith("/media/") else (fixtures, path.lstrip("/"))
            file = os.path.join(folder, name)
            if name and "/" not in name and os.path.isfile(file):
                with open(file, "rb") as f:
                    body = f.read()
                kind = "text/html; charset=utf-8" if name.endswith(".html") else "text/javascript"
            else:
                body = ("<!doctype html><meta charset=utf-8><title>Sleep %s</title><body>Sleep fixture %s"
                        % (_html.escape(path), _html.escape(path))).encode()
                kind = "text/html; charset=utf-8"
            self.send_response(200); self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


SLEEP_MEDIA_KEYS = ("open.advanced.enablePictureInPictureOnLeave", "open.pip.autoDisabledHosts", "open.pip.keepOnTop")


def sleep_checks(factory, results, tmp, style):
    """app-shell §6 `sleep` (Step G, memory-fork S6, §11 F0–F5) in the real App on the fork's
    sleep API (freeze, discard in place, history capture and restore; PR G2). Timed rows move the
    controller's automation clock (`sleep-clock`) and run one pass (`sleep-tick`); they assert
    the configured delays, never wall time."""
    server, port = _sleep_server()
    base = "http://127.0.0.1:%d/" % port
    def site(n, path="a.html"): return "http://t%d.localhost:%d/%s" % (n, port, path)
    app = factory(urls=(base + "a.html",), fresh=True)
    def state(tab=None): return app.call("sleep-state", **({"tab": tab} if tab else {}))
    def ts(tab): return state(tab)["tabs"][0]
    def tick(**kw): return app.call("sleep-tick", **kw)
    def advance(seconds): return app.call("sleep-clock", advance=float(seconds))
    def sleep_now(tab): return app.call("sleep-now", tab=tab)
    def selected(): return app.call("window-state")["selected"]
    def select(tab):
        app.call("select", tab=tab)
        wait_until(lambda: selected() == tab, timeout=5, step=.02)
        # The window's visibility hook reaches the controller in a task right after selection.
        return wait_until(lambda: tab in state()["visible"], timeout=5, step=.02)
    def open_live(url):
        tab = new_tab(app, url)
        wait_until(lambda: not app.tab(tab)["loading"], timeout=15, step=.05)
        return tab
    def phase(tab): return ts(tab)["phase"]
    def renderers():
        app.discover_owned_processes()
        pids = [pid for pid, path in app.owned_processes.items()
                if "(Renderer)" in path and app.process_path(pid) == path]
        rss = 0
        if pids:
            out = subprocess.run(["ps", "-o", "rss=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
            rss = sum(int(x) for x in out.split())
        return {"count": len(pids), "rssKB": rss}
    def blocked(name, reason):
        results[name] = {"status": "BLOCKED", "reason": reason}
    def _try(fn):
        try:
            return fn()
        except Exception:
            return None
    for key in SLEEP_MEDIA_KEYS:
        app.call("defaults", key=key, value=None)
    app.call("sleep-power", lowPower=False)
    try:
        app.call("window-frame", frame=[80, 60, 1280, 820])
        home = app.call("tabs")[0]["id"]
        app.call("wait", tab=home)

        # T5: the controller starts after the first paint, never before (app-shell §5.1).
        started = wait_until(lambda: (lambda s: s if s.get("started") else None)(state()), timeout=10, step=.1)
        timing = app.call("timing")
        results["sleep_started_after_paint"] = {
            "ok": bool(started) and timing.get("sleepStarted") is not None and timing.get("firstContentfulPaint") is not None
                  and timing["sleepStarted"] >= timing["firstContentfulPaint"] and timing["sleepStarted"] >= timing.get("sidebarDrawn", 0),
            "sleepStarted": timing.get("sleepStarted"), "firstContentfulPaint": timing.get("firstContentfulPaint"),
            "sidebarDrawn": timing.get("sidebarDrawn")}

        # No idle timer: with only the visible tab, the pass loop parks (no pass over 12 s).
        parked = wait_until(lambda: (lambda s: s if not s["scheduled"] and s["nextPassDelay"] is None else None)(state()), timeout=15, step=.25)
        before = state()["passes"]
        time.sleep(12)
        after = state()
        results["sleep_idle_parked"] = {"ok": bool(parked) and after["passes"] == before and not after["scheduled"],
                                        "passesBefore": before, "passesAfter": after["passes"], "scheduled": after["scheduled"],
                                        "load": os.getloadavg()}

        # F0 (memory-fork §10): the browser runs with Open's feature switches (chrome://version
        # shows the command line every process inherits).
        ver = app.call("open", url="chrome://version")["id"]
        app.call("wait", tab=ver)
        cmd = wait_until(lambda: app.eval(ver, "(document.getElementById('command_line') || {}).innerText || null"), timeout=10, step=.2) or ""
        app.call("close", tab=ver)
        select(home)
        def feature_list(flag):
            # A repeated switch takes its last value (base::CommandLine).
            found = re.findall(r"--%s=(\S+)" % flag, cmd)
            return set(found[-1].split(",")) if found else set()
        off = {"OptimizationHints", "OptimizationTargetPrediction", "OptimizationGuidePageContentExtraction",
               "OptimizationGuideModelExecution", "SegmentationPlatform", "SegmentationPlatformUkmEngine", "MediaRouter",
               "TranslateRankerQuery", "TranslateRankerEnforcement"}
        results["sleep_f0_switches"] = {"ok": "WebContentsDiscard" in feature_list("enable-features") and off <= feature_list("disable-features"),
                                        "enabled": sorted(feature_list("enable-features")), "disabledMissing": sorted(off - feature_list("disable-features"))}

        # Ladder: freeze at 30 s (the renderer stops), discard in place at the balanced 300 s.
        ladder = open_live(site(1, "ticker.html"))
        select(home)
        tick()
        ladder_steps = []
        advance(29); tick(); ladder_steps.append(phase(ladder))
        advance(1); tick(); ladder_steps.append(phase(ladder))
        scheduled = state()["scheduled"]
        # The phase deadline is still 270 s away. Frozen pages cannot change
        # without that deadline or an event; five-second polling is idle work.
        frozen_delay = state()['nextPassDelay']
        results['sleep_frozen_deadline'] = {
            'ok': frozen_delay is not None and 5 < frozen_delay <= 270,
            'nextPassDelay': frozen_delay, 'discardDelay': 300, 'hiddenElapsed': 30,
            'load': os.getloadavg()}
        advance(269); tick(); ladder_steps.append(phase(ladder))
        advance(1); tick(); s = ts(ladder); ladder_steps.append(s["phase"])
        results["sleep_timed_ladder"] = {"ok": ladder_steps == ["live", "frozen", "frozen", "sleeping"] and scheduled
                                         and s["hosts"] == 1 and s["discarded"] and app.tab(ladder)["loaded"],
                                         "phases": ladder_steps, "scheduledWhileFrozen": scheduled, "after": s}

        # Wake: selecting the discarded tab recreates its page with its URL and title.
        ladder_url = app.tab(ladder)["url"]
        select(ladder)
        woke = wait_until(lambda: (lambda t: t if t["phase"] == "live" and t["hosts"] == 1 else None)(ts(ladder)), timeout=10, step=.05)
        app.call("wait", tab=ladder)
        row = app.tab(ladder)
        log = state()["log"]
        results["sleep_wake_recreates"] = {"ok": bool(woke) and row["url"] == ladder_url and row["title"] == "Open freeze ticker"
                                           and any(l.startswith("sleep-wake discard") for l in log),
                                           "row": {k: row[k] for k in ("url", "title", "sleepPhase", "loaded")},
                                           "wakeLog": [l for l in log if l.startswith("sleep-wake")]}
        # F2 (memory-fork §11): A → B → C, scroll and a typed value on C; sleep; wake. In order: the
        # page is C, document.wasDiscarded, scroll, the field, Back to B then A, Forward to B.
        hist = open_live(site(31, "a.html"))
        for page in ("b.html", "c.html"):
            app.call("navigate", tab=hist, url=site(31, page))
            wait_until(lambda: app.eval(hist, "location.pathname") == "/" + page or None, timeout=10, step=.05)
            app.call("wait", tab=hist)
        app.eval(hist, "scrollTo(0, innerHeight * 2); document.querySelector('#q').value = 'open-sleep-check'; true")
        y0 = app.eval(hist, "scrollY")
        select(home)
        time.sleep(6)  # Blink syncs a hidden page's scroll and form state within about 5 s
        advance(15)
        f2_sleep = sleep_now(hist)
        f2_discarded = ts(hist)["discarded"]
        select(hist)
        wait_until(lambda: app.eval(hist, "document.readyState") == "complete" or None, timeout=15, step=.1)
        time.sleep(.5)
        woke2 = app.eval(hist, "({path: location.pathname, d: document.wasDiscarded, y: scrollY, q: document.querySelector('#q').value, n: history.length})")
        def nav(js, want):
            app.eval(hist, js + "; true")
            return wait_until(lambda: app.eval(hist, "location.pathname") == want or None, timeout=10, step=.05)
        back_b = nav("history.back()", "/b.html"); back_a = nav("history.back()", "/a.html"); fwd_b = nav("history.forward()", "/b.html")
        results["sleep_f2_history_scroll_form"] = {
            "ok": f2_sleep["refusedBy"] is None and f2_discarded and woke2["path"] == "/c.html" and woke2["d"] is True
                  and abs(woke2["y"] - y0) < 50 and woke2["q"] == "open-sleep-check" and woke2["n"] >= 3
                  and bool(back_b) and bool(back_a) and bool(fwd_b),
            "woke": woke2, "scrollBefore": y0, "back": [bool(back_b), bool(back_a)], "forward": bool(fwd_b)}
        select(home)
        app.call("close", tab=hist)

        # Modes (memory-fork §9.3): aggressive 120 s, conservative 900 s, off never discards.
        mode_rows = {}
        for mode, delay in (("aggressive", 120), ("conservative", 900), ("off", None)):
            app.call("sleep-mode", mode=mode)
            t = open_live(site(2, "b.html?mode=" + mode))
            select(home); tick()
            advance(30); tick()
            if delay:
                advance(delay - 31); tick(); early = phase(t)
                advance(1); tick(); late = phase(t)
                mode_rows[mode] = {"ok": early == "frozen" and late == "sleeping", "before": early, "at": late}
            else:
                advance(48 * 3600); tick(); late = phase(t)
                mode_rows[mode] = {"ok": late == "frozen", "after48h": late}
            app.call("close", tab=t)
        app.call("sleep-mode", mode="balanced")
        results["sleep_modes"] = {"ok": all(r["ok"] for r in mode_rows.values()), "modes": mode_rows}

        # F1: sleeping drops renderer processes. Eight distinct sites, then sleep them all.
        select(home)
        advance(15)
        for t in state()["tabs"]:
            if t["id"] != home and t["hosts"]:
                sleep_now(t["id"])
        time.sleep(2)
        one_tab = renderers()
        f1 = [open_live(site(10 + i, "a.html")) for i in range(8)]
        select(home)
        time.sleep(1)
        loaded = renderers()
        advance(15)  # past the 10 s loading grace after each page's commit
        f1_answers = [sleep_now(t) for t in f1]
        f1_slept = wait_until(lambda: all(phase(t) == "sleeping" for t in f1), timeout=10, step=.1)
        time.sleep(2)
        slept = renderers()
        rows = {t["id"]: t for t in app.call("tabs")}
        results["sleep_f1_renderers"] = {
            "ok": bool(f1_slept) and all(rows[t]["title"].startswith("Open history A") for t in f1)
                  and loaded["count"] >= one_tab["count"] + 4 and slept["count"] <= one_tab["count"]
                  and slept["rssKB"] < loaded["rssKB"],
            "oneTab": one_tab, "tenTabsLoaded": loaded, "nineSleeping": slept,
            "refused": [a["refusedBy"] for a in f1_answers if a["refusedBy"]],
            "note": "discard in place: the page objects stay, their renderers go"}

        # F3: an audible tab never sleeps; after audio stops it waits the 60 s grace, then sleeps.
        audio = open_live(base + "media/audio.html")
        app.eval(audio, "start()")
        audible = wait_until(lambda: app.tab(audio)["audible"], timeout=10, step=.05)
        select(home)
        refused = sleep_now(audio)["refusedBy"]
        advance(600); tick(); tick()
        held = phase(audio)
        # Close (not pause): a paused card would keep the tab protected as a mini player.
        app.call("media-action", tab=audio, action="close")
        quiet = wait_until(lambda: not app.tab(audio)["audible"] and audio not in state()["mediaControls"], timeout=10, step=.05)
        advance(59); tick(); grace = phase(audio)
        advance(2); tick()
        after_grace = phase(audio)
        # The hide clock starts when the tab left the media feed (at the close): discard at +300 s.
        advance(240); tick(); slept_after = phase(audio)
        # While it plays, the media feed (visible) or the audio gate refuses first; both protect.
        results["sleep_f3_audio"] = {"ok": bool(audible) and refused in ("audible", "visible") and held == "live" and bool(quiet)
                                     and grace == "live" and after_grace == "frozen" and slept_after == "sleeping",
                                     "debugSleepRefusedBy": refused, "after600s": held, "at59sAfterStop": grace,
                                     "at61sAfterStop": after_grace, "at301sAfterStop": slept_after}
        blocked("sleep_f3_capture", "unverified: no capture fixture without a camera or microphone grant "
                "(memory-fork §11 F3 records capture as unverified, not passed)")

        # Keep-alive (docs/sleep.md): a Gmail-like host the built-in table matches stays live.
        gmail = open_live("http://mail.google.localhost:%d/mail/u/0" % port)
        outside = open_live("http://mail.google.localhost:%d/settings" % port)
        select(home)
        keep_refused = sleep_now(gmail)["refusedBy"]
        for _ in range(4):
            advance(12 * 3600); tick(); tick()
        g, o = ts(gmail), ts(outside)
        results["sleep_keep_alive"] = {"ok": keep_refused == "keepAlive" and g["phase"] == "live" and g["freezeGate"] == "keepAlive"
                                       and g["hosts"] == 1 and o["phase"] == "sleeping",
                                       "debugSleepRefusedBy": keep_refused, "gmail48h": g["phase"], "gate": g["freezeGate"],
                                       "outsideMail48h": o["phase"]}
        app.call("close", tab=outside)

        # N5 (page-platform §8.3): notification permission Allow refuses debug sleep; Block sleeps.
        notify_origin = "http://t30.localhost:%d" % port
        notify = open_live(notify_origin + "/a.html")
        select(home)
        try:
            app.call("permission", origin=notify_origin, kind=8, state=1)
            allowed = ts(notify)
            n_refused = sleep_now(notify)["refusedBy"]
            advance(1000); tick(); tick()
            held_n = phase(notify)
            app.call("permission", origin=notify_origin, kind=8, state=2)
            blocked_state = ts(notify)
            n_after = sleep_now(notify)
        finally:
            app.call("permission", origin=notify_origin, kind=8, state=0)
        results["sleep_n5_notifications"] = {"ok": allowed["notificationsAllowed"] and n_refused == "notifications" and held_n == "live"
                                             and not blocked_state["notificationsAllowed"] and n_after["refusedBy"] is None
                                             and n_after["tab"]["phase"] == "sleeping",
                                             "allowedRefusedBy": n_refused, "after1000s": held_n, "blockedThen": n_after["tab"]["phase"]}

        # Media (Section 3's feed): a paused mini player and a PiP source never sleep.
        player = open_live(base + "media/audio.html?player")
        app.eval(player, "start()")
        wait_until(lambda: app.tab(player)["audible"], timeout=10, step=.05)
        select(home)
        card = wait_until(lambda: player in state()["mediaControls"], timeout=5, step=.05)
        app.call("media-action", tab=player, action="pause")
        wait_until(lambda: not app.tab(player)["audible"], timeout=10, step=.05)
        advance(400)
        card_refused = sleep_now(player)["refusedBy"]
        tick(); tick()
        card_phase = phase(player)
        app.call("media-action", tab=player, action="close")
        pip_row = {}
        video = open_live(base + "media/video.html")
        app.eval(video, "start()")
        wait_until(lambda: app.tab(video)["audible"], timeout=10, step=.05)
        # Auto-PiP on leave (media-pip §4.5.3, default on) makes the PiP source.
        select(home)
        pip_on = wait_until(lambda: (lambda p: p if p["state"] == "active" else None)(app.call("pip")), timeout=5, step=.05)
        if pip_on:
            in_feed = wait_until(lambda: video in state()["pictureInPicture"], timeout=5, step=.05)
            advance(400)
            pip_refused = sleep_now(video)["refusedBy"]
            tick(); tick()
            pip_row = {"inFeed": bool(in_feed), "refusedBy": pip_refused, "phase": phase(video)}
            try:
                app.call("pip-action", action="close")
            except RuntimeError:
                pass
            wait_until(lambda: app.call("pip")["state"] == "closed", timeout=5, step=.05)
        results["sleep_media_protection"] = {
            "ok": bool(card) and card_refused == "visible" and card_phase == "live" and bool(pip_on)
                  and pip_row.get("inFeed") and pip_row.get("refusedBy") == "visible" and pip_row.get("phase") == "live",
            "miniPlayer": {"listed": bool(card), "refusedBy": card_refused, "phase": card_phase}, "pip": pip_row or {"entered": False}}
        app.call("close", tab=video)
        app.call("close", tab=player)

        # Battery Saver (features-core §3.4 r17): Low Power Mode makes Automatic discard at 120 s,
        # with toasts when it turns on and off while Open runs.
        try:
            power_on = app.call("sleep-power", lowPower=True)
            on_toast = power_on["lastToast"]
            saver = open_live(site(3, "c.html"))
            select(home); tick()
            advance(30); tick(); advance(90); tick()
            saver_phase = phase(saver)
            power_off = app.call("sleep-power", lowPower=False)
        finally:
            app.call("sleep-power", lowPower=False)
            app.call("sleep-power", lowPower=None)
        results["sleep_battery_saver"] = {"ok": on_toast == "Battery Saver Mode Activated" and saver_phase == "sleeping"
                                          and power_off["lastToast"] == "Battery Saver Mode Deactivated"
                                          and power_off["toasts"][-2:] == ["Battery Saver Mode Activated", "Battery Saver Mode Deactivated"],
                                          "toastOn": on_toast, "toastOff": power_off["lastToast"], "phaseAt120s": saver_phase}

        # F5: wake latency per kind from the controller's log (selection to first commit).
        target = open_live(site(4, "b.html"))
        select(home)
        def wake(kind_setup):
            n = len([l for l in state()["log"] if l.startswith("sleep-wake")])
            kind_setup()
            select(target)
            line = wait_until(lambda: (lambda ls: ls[n] if len(ls) > n else None)(
                [l for l in state()["log"] if l.startswith("sleep-wake")]), timeout=10, step=.02)
            app.call("wait", tab=target)
            select(home)
            return line
        def discard_setup():
            advance(15); sleep_now(target)
        def destroyed_setup():
            advance(15); sleep_now(target); advance(86400); tick()
        discard_ms, destroyed_ms = [], []
        for _ in range(20):
            line = wake(discard_setup)
            if line and line.startswith("sleep-wake discard"):
                discard_ms.append(float(line.split("ms=")[1]))
        for _ in range(10):
            line = wake(destroyed_setup)
            if line and line.startswith("sleep-wake destroyed"):
                destroyed_ms.append(float(line.split("ms=")[1]))
        def pct(xs, p): return sorted(xs)[min(len(xs) - 1, int(round(p * (len(xs) - 1))))] if xs else None
        results["sleep_f5_discard_wake"] = {"ok": len(discard_ms) == 20 and pct(discard_ms, .95) <= 700,
                                            "p50ms": pct(discard_ms, .5), "p95ms": pct(discard_ms, .95), "n": len(discard_ms),
                                            "destroyed": {"p50ms": pct(destroyed_ms, .5), "p95ms": pct(destroyed_ms, .95), "n": len(destroyed_ms)},
                                            "cache": "warm (same fixture page each wake)", "load": os.getloadavg(),
                                            "note": "in-place discard reload; budget 700 ms first paint on a cached page"}
        # F5 unfreeze: a frozen tab shows again (budget 16 ms to content visible). An unfreeze has
        # no commit, so the page itself stamps the moment it becomes visible (visibilitychange,
        # which a frozen renderer cannot run); the clock starts right before the select call.
        app.eval(target, "window.__vis = []; document.addEventListener('visibilitychange', () => {"
                         " if (document.visibilityState === 'visible') __vis.push(Date.now()); }); true")
        unfreeze_ms, unfreeze_phases = [], []
        for _ in range(20):
            select(home)
            seen = len(app.eval(target, "__vis"))
            advance(31); tick()
            unfreeze_phases.append(phase(target))
            if unfreeze_phases[-1] != "frozen":
                continue
            t0 = time.time() * 1000
            app.call("select", tab=target)
            stamp = wait_until(lambda: (lambda v: v[-1] if len(v) > seen else None)(_try(lambda: app.eval(target, "__vis")) or []),
                               timeout=5, step=.005)
            if stamp:
                unfreeze_ms.append(stamp - t0)
        results["sleep_f5_unfreeze"] = {"ok": len(unfreeze_ms) == 20 and pct(unfreeze_ms, .95) <= 16,
                                        "p50ms": pct(unfreeze_ms, .5), "p95ms": pct(unfreeze_ms, .95), "n": len(unfreeze_ms),
                                        "frozenBeforeWake": unfreeze_phases.count("frozen"), "load": os.getloadavg(),
                                        "measure": "select call → the page's visibilitychange to visible (includes the automation round trip)"}
        select(home)

        # chrome.tabs.discard (engine-patches P1 "Discards") goes through the same gates.
        if style == "chrome":
            ext_row = sleep_tabs_discard_check(app, select, ts, home, open_live, site, advance)
            results["sleep_tabs_discard"] = ext_row
        else:
            results["sleep_tabs_discard"] = {"status": "SKIP", "reason": "chrome.tabs sees sidebar tabs only in Chrome style (--style chrome)"}

        # F4: quit captures live and frozen tabs; relaunch draws with one renderer for the selected tab.
        live_tab = open_live(site(5, "c.html"))
        frozen_tab = open_live(site(6, "a.html"))
        slept_tab = open_live(site(7, "a.html"))
        # Two entries, so the relaunched wake can prove the Back list (F4).
        app.call("navigate", tab=slept_tab, url=site(7, "b.html"))
        wait_until(lambda: app.eval(slept_tab, "location.pathname") == "/b.html" or None, timeout=10, step=.05)
        app.call("wait", tab=slept_tab)
        placeholder = app.call("open", url=site(8, "a.html"), background=True)["id"]
        select(home)
        advance(30); tick()
        sleep_now(slept_tab)
        pre = {t: phase(t) for t in (live_tab, frozen_tab, slept_tab, placeholder)}
        # live_tab stays live: touch it so its hide clock restarts.
        select(live_tab); select(home)
        pre[live_tab] = phase(live_tab)
        urls = {t: app.tab(t)["url"] for t in (live_tab, frozen_tab, slept_tab, home)}
        app.call("save")
        quit_started = time.monotonic()
        app.quit()
        quit_s = time.monotonic() - quit_started
        quit_log = Path(app.launch_log_path).read_text(errors="replace") if os.path.exists(app.launch_log_path) else ""
        capture_ms = [float(m) for m in re.findall(r"sleep-quit-capture ms=([0-9.]+)", quit_log)]
        app = factory(urls=())
        app.call("window-frame", frame=[80, 60, 1280, 820])
        wait_until(lambda: app.call("tabs"), timeout=10)
        app.call("wait", tab=home)
        time.sleep(2)
        store = {r["tab"]: r for r in app.call("sleep-store")}
        rows = {t["id"]: t for t in app.call("tabs")}
        hosted = [t for t, r in rows.items() if r["loaded"]]
        relaunch_renderers = renderers()
        results["sleep_f4_quit_capture"] = {
            "ok": pre[frozen_tab] == "frozen" and pre[slept_tab] == "sleeping" and pre[live_tab] == "live"
                  and all(t in store and store[t]["url"] == urls[t] for t in (live_tab, frozen_tab, slept_tab, home))
                  and placeholder not in store and hosted == [home] and len(capture_ms) == 1 and quit_s < 10
                  and capture_ms[0] < 3000,
            "phasesBeforeQuit": pre, "storedRows": len(store), "quitCaptureMs": capture_ms, "quitSeconds": round(quit_s, 2),
            "hostedAfterRelaunch": len(hosted), "renderersAfterRelaunch": relaunch_renderers, "load": os.getloadavg()}
        # F4: waking the relaunched sleeping tab restores its Back list (no-renderer create + history).
        n0 = len(state()["log"])
        select(slept_tab)
        app.call("wait", tab=slept_tab)
        restored = wait_until(lambda: (lambda v: v if v and v["path"] == "/b.html" else None)(
            app.eval(slept_tab, "({path: location.pathname, n: history.length})")), timeout=15, step=.1)
        back_a4 = None
        if restored:
            app.eval(slept_tab, "history.back(); true")
            back_a4 = wait_until(lambda: app.eval(slept_tab, "location.pathname") == "/a.html" or None, timeout=10, step=.05)
        log4 = state()["log"][n0:]
        results["sleep_f4_history_restore"] = {"ok": bool(restored) and restored["n"] >= 2 and bool(back_a4)
                                               and not any(l.startswith("sleep-restore-fallback") for l in log4),
                                               "restored": restored, "back": bool(back_a4), "log": log4}
        # F4 fallback: a stored container the engine cannot decode (one entry's pickle header
        # overwritten in this run's own store, never a user profile) loads the URL, Back
        # disabled, `sleep-restore-fallback` logged, no dialog, no crash.
        select(home)
        stored = {r["tab"]: r for r in app.call("sleep-store")}
        victim = frozen_tab if frozen_tab in stored else None
        corrupt = {}
        if victim:
            db = stored[victim]["file"]
            app.quit()
            import sqlite3
            con = sqlite3.connect(db)
            blob = bytearray(con.execute("SELECT container FROM sleep_history WHERE tab_id = ?", (victim,)).fetchone()[0])
            blob[24:28] = b"\xff\xff\xff\x7f"  # first entry's pickle payload size: undecodable
            con.execute("UPDATE sleep_history SET container = ? WHERE tab_id = ?", (bytes(blob), victim))
            con.commit(); con.close()
            app = factory(urls=())
            app.call("window-frame", frame=[80, 60, 1280, 820])
            wait_until(lambda: app.call("tabs"), timeout=10)
            app.call("wait", tab=home)
            n1 = len(state()["log"])
            select(victim)
            # No `wait` here: the first page (the refused restore) closes, and its replacement loads
            # the URL; poll the tab's current page instead.
            landed = wait_until(lambda: _try(lambda: app.eval(victim, "document.readyState === 'complete' ? location.href : null"))
                                == urls[frozen_tab] or None, timeout=20, step=.1)
            corrupt = {"landed": bool(landed), "historyLength": app.eval(victim, "history.length"),
                       "log": state()["log"][n1:], "dialogs": [d for d in (app.call("dismiss") or []) if str(d).startswith(("javascript", "modal", "sheet"))]}
        results["sleep_f4_corrupt_fallback"] = {
            "ok": bool(victim) and corrupt.get("landed") and corrupt.get("historyLength") == 1
                  and any(l.startswith("sleep-restore-fallback") for l in corrupt.get("log", [])) and not corrupt.get("dialogs"),
            "victimStored": bool(victim), **corrupt}
    finally:
        try:
            if not app.closed:
                app.call("sleep-power", lowPower=None)
                for key in SLEEP_MEDIA_KEYS:
                    app.call("defaults", key=key, value=None)
        except Exception:
            pass
        app.quit()
        server.shutdown()


def sleep_tabs_discard_check(app, select, ts, home, open_live, site, advance):
    """chrome.tabs.discard from the tabs probe: a quiet background tab sleeps through the
    controller; the visible tab and a keep-alive-protected tab are refused."""
    wait_until(lambda: any(e["id"] == PROBE for e in app.call("extensions")["installed"]), timeout=30)
    bg = open_live(site(40, "a.html"))
    select(home)
    advance(15)  # past the 10 s loading grace of the fresh page
    page = app.call("popup", extension=PROBE)["identifier"]
    wait_until(lambda: app.eval(page, "window.currentTab !== undefined", timeout=20), timeout=20)
    def call(js):
        return app.eval(page, "(%s).then(v => ({ok: v === undefined ? null : v}), e => ({error: String(e.message || e)}))" % js, timeout=20)
    def cid(tab): return app.tab(tab)["page"]["chromeTabId"]
    bg_cid, home_cid = cid(bg), cid(home)
    background = call("chrome.tabs.discard(%d).then(t => ({id: t.id}))" % bg_cid)
    slept = wait_until(lambda: ts(bg)["phase"] == "sleeping", timeout=10, step=.1)
    visible = call("chrome.tabs.discard(%d)" % home_cid)
    try:
        app.call("popup-close")
    except RuntimeError:
        pass
    return {"ok": "ok" in background and bool(slept) and "error" in visible and ts(home)["phase"] == "live",
            "background": background, "backgroundSlept": bool(slept), "visible": visible}


def _static_server(folder):
    import http.server
    import threading
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=folder, **kw)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, 'http://127.0.0.1:%d' % server.server_address[1]


# long.html band colors, top to bottom (one per 1,000 CSS px).
CAPTURE_BANDS = [(224, 64, 64), (64, 176, 80), (48, 96, 224), (224, 192, 48), (160, 64, 192), (48, 192, 192),
                 (240, 128, 32), (32, 32, 32), (128, 224, 128), (224, 128, 192), (64, 128, 160), (192, 160, 128)]


def page_checks(factory, results, tmp, style="alloy"):
    """page-platform §8.3 `--only page`: one suite, one row group per feature."""
    # D4 runs before foreground-sensitive groups, so consent-limited self-scripting
    # evidence remains available even when a later group is interrupted.
    page_tools_checks(factory, results, tmp, style)
    capture_checks(factory, results, tmp)
    page_commands_checks(factory, results, tmp)
    page_engine_checks(factory, results, tmp)
    page_notification_checks(factory, results, tmp)
    page_translate_checks(factory, results, tmp)


def page_engine_checks(factory, results, tmp):
    """Engine page API in the real App (page-platform §6, fork PR E2): EP-1 history swipe through the
    engine's automation replay hook (SW1, SW2, SW4), EP-2 selection and link to highlight (Q2), and
    EP-3 selection changes. Real trackpad recognition stays the manual check U-S1 (plan R-7)."""
    folder = os.path.join(ROOT, 'tools', 'e2e', 'fixtures', 'page-platform')
    server, origin = _static_server(folder)
    app = factory(urls=(origin + '/links.html',), fresh=True)
    selection_bit = 1 << 15
    try:
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        a_url = origin + '/links.html'
        b_url = origin + '/links-target.html'
        app.call('navigate', tab=tab, url=b_url)
        app.call('wait', tab=tab)
        wait_until(lambda: app.eval(tab, 'location.href') == b_url or None, timeout=10, step=.1)
        url = lambda: app.eval(tab, 'location.href')
        swipe_events = lambda: [e for e in app.call('events') if e['type'] == 'historySwipe']
        # SW1: back past the threshold navigates back; forward returns. Chrome's own overlay is off.
        app.call('events')
        # Tab pages draw Open's indicator and turn Chromium's arrow off (page-platform §4.4.3).
        options = app.call('swipe', tab=tab)
        back = app.call('swipe', tab=tab, direction='back', progress=1.2)
        ind_back = back['indicator']
        at_a = wait_until(lambda: url() == a_url or None, timeout=10, step=.1)
        ev_back = swipe_events()
        fwd = app.call('swipe', tab=tab, direction='forward', progress=1.2)
        at_b = wait_until(lambda: url() == b_url or None, timeout=10, step=.1)
        ev_fwd = swipe_events()
        phases = lambda ev: [e['phase'] for e in ev]
        results['SW1_swipe_back_forward'] = {
            'ok': options['engineOverlay'] is False and back['ran'] and fwd['ran'] and bool(at_a) and bool(at_b)
            and phases(ev_back)[:1] == ['began'] and phases(ev_back)[-1:] == ['completed']
            and all(e['direction'] == 'back' for e in ev_back) and phases(ev_fwd)[-1:] == ['completed']
            and all(e['direction'] == 'forward' for e in ev_fwd) and ev_back[-1]['progress'] >= 1
            and all(e.get('indicator') for e in ev_back + ev_fwd)
            and ind_back.get('made') and ind_back['last']['phase'] == 'completed' and ind_back['last']['direction'] == 'back',
            'back': phases(ev_back), 'forward': phases(ev_fwd), 'urls': [bool(at_a), bool(at_b)], 'indicator': ind_back}
        # The completed indicator fades out (0.18 s) and hides.
        gone = wait_until(lambda: app.call('swipe-indicator', tab=tab).get('hidden') or None, timeout=3, step=.05)
        results['SW1_indicator_hides_after_completion'] = {'ok': bool(gone), 'state': app.call('swipe-indicator', tab=tab)}
        # SW2: half a swipe does not navigate; the swipe ends cancelled.
        half = app.call('swipe', tab=tab, direction='back', progress=0.5)
        time.sleep(1)
        ev_half = swipe_events()
        ind_half = app.call('swipe-indicator', tab=tab)
        results['SW2_partial_swipe_cancels'] = {
            'ok': half['ran'] and url() == b_url and phases(ev_half)[-1:] == ['cancelled']
            and max(e['progress'] for e in ev_half) <= 0.5 and ind_half['last']['phase'] == 'cancelled' and ind_half['hidden'],
            'phases': phases(ev_half), 'url': url(), 'indicator': ind_half}
        # SW4: a page with swipes off (capture overlay, Zap) refuses; no event, no navigation.
        app.call('swipe', tab=tab, enabled=False)
        refused = app.call('swipe', tab=tab, direction='back', progress=1.2)
        time.sleep(1)
        ev_off = swipe_events()
        app.call('swipe', tab=tab, enabled=True)
        results['SW4_swipe_disabled'] = {'ok': refused['ran'] is False and not ev_off and url() == b_url,
                                         'ran': refused['ran'], 'events': len(ev_off)}
        # SW4: the Capture overlay pauses swipes on the window's pages; they come back after it.
        app.call('command', id='capture-page')
        up = wait_until(lambda: app.call('capture-state').get('overlay') or None, timeout=5, step=.1)
        during = app.call('swipe', tab=tab, direction='back', progress=1.2)
        app.call('capture-action', action='cancel')
        down = wait_until(lambda: (not app.call('capture-state').get('overlay')) or None, timeout=5, step=.1)
        after = app.call('swipe', tab=tab)
        results['SW4_capture_overlay_pauses_swipes'] = {'ok': bool(up) and during['ran'] is False and during['enabled'] is False
            and url() == b_url and bool(down) and after['enabled'] is True, 'during': during, 'after': after}

        # SW3: in Split View the swipe navigates the pane it was made in; the other pane stays.
        other = app.call('open', url=origin + '/quote.html')['id']
        app.call('wait', tab=other)
        app.call('navigate', tab=other, url=origin + '/links.html')
        app.call('wait', tab=other)
        wait_until(lambda: app.eval(other, "location.pathname === '/links.html' || null"), timeout=10, step=.1)
        panes = app.call('split')
        time.sleep(1)
        visible = [t['id'] for t in app.call('tabs') if t.get('visible')]
        tab_last_before = app.call('swipe-indicator', tab=tab).get('last')
        pane_swipe = app.call('swipe', tab=other, direction='back', progress=1.2)
        moved = wait_until(lambda: app.eval(other, "location.pathname === '/quote.html' || null"), timeout=10, step=.1)
        still = url()
        ind_other, ind_tab = app.call('swipe-indicator', tab=other), app.call('swipe-indicator', tab=tab)
        results['SW3_split_pane_swipe'] = {'ok': len(panes) == 2 and tab in visible and other in visible and pane_swipe['ran']
            and bool(moved) and still == b_url and ind_other.get('made') and ind_other['last']['phase'] == 'completed'
            and ind_tab.get('last') == tab_last_before,
            'visible': visible, 'otherIndicator': ind_other, 'tabIndicator': ind_tab, 'tabURL': still}
        app.call('split')
        app.call('close', tab=other)

        # Q2 (EP-2) and EP-3: select a sentence, read text + link, open the link.
        app.call('navigate', tab=tab, url=origin + '/quote.html')
        app.call('wait', tab=tab)
        wait_until(lambda: app.eval(tab, "document.readyState === 'complete' && location.pathname === '/quote.html' || null"), timeout=10, step=.1)
        app.call('focus', tab=tab)
        app.call('events')
        empty = app.call('page-selection', tab=tab)
        # A user's selection: triple-click the sentence (DevTools Input mouse events, the page's
        # real input path), so the page also has input focus as after a real click.
        r = app.eval(tab, "(() => { const b = document.getElementById('quote').getBoundingClientRect(); return [b.left + 20, b.top + b.height / 2] })()")
        for count in (1, 2, 3):
            for kind in ('mousePressed', 'mouseReleased'):
                app.call('devtools', tab=tab, method='Input.dispatchMouseEvent',
                         params={'type': kind, 'x': r[0], 'y': r[1], 'button': 'left', 'clickCount': count})
        has = wait_until(lambda: app.call('page-selection', tab=tab)['hasSelection'] or None, timeout=5, step=.1)
        picked = app.call('page-selection', tab=tab)
        changes = [e['changes'] for e in app.call('events') if e['type'] == 'change' and e['changes'] & selection_bit]
        # A single click elsewhere clears it.
        for kind in ('mousePressed', 'mouseReleased'):
            app.call('devtools', tab=tab, method='Input.dispatchMouseEvent',
                     params={'type': kind, 'x': 5, 'y': 5, 'button': 'left', 'clickCount': 1})
        cleared = wait_until(lambda: (not app.call('page-selection', tab=tab)['hasSelection']) or None, timeout=5, step=.1)
        link = picked.get('link') or ''
        opened = None
        if link:
            other = app.call('open', url=link)['id']
            app.call('wait', tab=other)
            # Chromium strips the directive from location and highlights the text it found.
            opened = wait_until(lambda: app.eval(other, "(() => { const s = CSS.highlights ? [...CSS.highlights.keys()] : []; "
                                                 "return location.pathname === '/quote.html' && !location.hash.includes(':~:') ? "
                                                 "{hash: location.hash, highlights: s, y: scrollY} : null })()"), timeout=10, step=.2)
            app.call('close', tab=other)
        results['Q2_selection_and_link'] = {
            'ok': empty['text'] == '' and empty['link'] is None and bool(has)
            and picked['text'].strip() == 'The quick brown fox studies the lazy dog before every jump.'
            and link.startswith(origin + '/quote.html#:~:text=') and bool(opened),
            'empty': empty, 'picked': picked, 'opened': opened}
        results['EP3_selection_change_bit'] = {'ok': bool(has) and bool(cleared) and len(changes) >= 1,
                                               'changeEvents': len(changes), 'cleared': bool(cleared)}
    finally:
        app.quit()
        server.shutdown(); server.server_close()


def capture_checks(factory, results, tmp):
    """page-platform §8.3 C1–C7: the Capture tool in the real App (Step 13)."""
    server, origin = _static_server(os.path.join(ROOT, 'tools', 'e2e', 'fixtures', 'page-platform'))
    app = factory(urls=(origin + '/long.html',), fresh=True)
    def state(): return app.call('capture-state')
    def rows(**kw): return app.call('captures', **kw)['rows']
    def nearest(rgb):
        return min(range(len(CAPTURE_BANDS)), key=lambda i: sum((a - b) ** 2 for a, b in zip(rgb[:3], CAPTURE_BANDS[i])))
    def close_card():
        if state().get('card'):
            app.call('key', key='escape')
            wait_until(lambda: not state().get('card'), timeout=3, step=.05)
    # The App writes these in the shared preferences domain: start from defaults, restore after.
    capture_keys = ('open.capture.shortcutHintLastShown', 'open.capture.dragToCaptureEnabled', 'open.capture.portraitBackground')
    saved_keys = {}
    emulated = [False]
    try:
        for key in capture_keys:
            saved_keys[key] = app.call('defaults', key=key)
            app.call('defaults', key=key, value=None)
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        ws = app.call('window-state')
        app.call('window-focus', id=ws['id'], activate=True)
        scale = app.eval(tab, 'devicePixelRatio')
        menu = {r['id']: r for r in app.call('menu-state') if r['id'].startswith('capture-')}
        results['capture_menu_enabled'] = {'ok': all(menu.get(i, {}).get('enabled') for i in ('capture-page', 'capture-full-page', 'capture-portrait')),
                                           'menu': menu}

        # C1: File > Capture..., a drag inside the overlay, one `area` row at device scale.
        before = rows()
        r = app.call('capture', mode='area', rect=[100, 100, 300, 200])
        after = rows()
        st, steps = r['state'], r['steps']
        overlay = steps[0]['state'].get('overlay', {})
        new = [x for x in after if x['id'] not in {y['id'] for y in before}]
        card = st.get('card', {})
        panel = card.get('panel', [0, 0, 0, 0])
        results['capture_c1_area'] = {'ok': len(new) == 1 and new[0]['kind'] == 'area' and new[0]['width'] == round(300 * scale)
            and new[0]['height'] == round(200 * scale) and new[0]['bytes'] > 0 and st['result']['saved'] == new[0]['id']
            and overlay.get('frame') == overlay.get('pageFrame') and overlay.get('firstResponder') is True
            and overlay.get('hint') == 'Drag to capture. Press Esc to cancel.' and not overlay.get('hintHidden')
            and steps[1]['hintHidden'] is True and steps[1]['selection'] == [100, 100, 150, 100]
            and card.get('actions') == ['copy', 'save', 'share', 'library', 'retake', 'delete'] and card.get('savedLine') is True,
            'scale': scale, 'row': new, 'steps': steps, 'state': st}
        # Real-window look of the card (no Arc capture exists yet, C-C1): kept for review in .re/.
        os.makedirs(os.path.join(ROOT, '.re', 'page-capture'), exist_ok=True)
        app.call('snapshot', path=os.path.join(ROOT, '.re', 'page-capture', 'card-window.png'))
        # The card's top-right corner is the toast anchor: panel maxX - 10, minY + 8 (section 4.1.1).
        results['capture_card_anchor'] = {'ok': bool(card) and abs(card['frame'][0] + card['frame'][2] - (panel[0] + panel[2] - 10)) < 0.5
            and abs(card['frame'][1] - (panel[1] + 8)) < 0.5 and card['frame'][2] == 248, 'card': card.get('frame'), 'panel': panel}
        lifetime = (card.get('lifetime'), card.get('remaining', 0))
        app.call('capture-action', hover=True)
        paused = state().get('card', {})
        app.call('capture-action', hover=False)
        resumed = state().get('card', {})
        results['capture_card_lifetime'] = {'ok': lifetime[0] == 8 and 7 < lifetime[1] <= 8 and paused.get('paused') is True
            and resumed.get('paused') is False and resumed.get('remaining', 9) <= paused.get('remaining', 0),
            'scheduled': lifetime, 'paused': paused.get('remaining'), 'resumed': resumed.get('remaining')}
        # Copy through the real button, then the Save... sheet (closed by `dismiss`), then Esc on the real key path.
        app.call('capture-action', action='copy')
        app.call('capture-action', action='save')
        sheet = wait_until(lambda: next((w for w in app.call('windows') if 'SavePanel' in w.get('class', '')), None), timeout=5, step=.1)
        app.call('dismiss')
        gone = wait_until(lambda: (not any('SavePanel' in w.get('class', '') for w in app.call('windows'))) or None, timeout=5, step=.1)
        app.call('key', key='escape')
        closed = wait_until(lambda: (lambda s: s if not s.get('card') and s['phase'] == 'idle' else None)(state()), timeout=3, step=.05)
        results['capture_card_copy_save_escape'] = {'ok': bool(sheet) and bool(gone) and bool(closed), 'sheet': sheet}
        # Section 4.6.7: after the first menu capture's flow ends, the keycap hint shows once and stores its time.
        hint_time = app.call('defaults', key='open.capture.shortcutHintLastShown')
        results['capture_shortcut_hint'] = {'ok': (closed or {}).get('hintShows') == 1 and isinstance(hint_time, (int, float)) and hint_time > 0,
                                            'hintShows': (closed or {}).get('hintShows'), 'stored': hint_time}

        # C4: Cmd+Shift+2 on the real key path shows the overlay; Esc during it: no row.
        count, cancelled = len(rows()), state()['cancelled']
        app.call('key', key='2', modifiers=['cmd', 'shift'])
        shown = wait_until(lambda: state().get('overlay'), timeout=3, step=.05)
        app.call('snapshot', path=os.path.join(ROOT, '.re', 'page-capture', 'overlay-window.png'))
        app.call('key', key='escape')
        after_esc = wait_until(lambda: (lambda s: s if not s['overlayActive'] else None)(state()), timeout=3, step=.05) or state()
        results['capture_c4_escape'] = {'ok': bool(shown) and shown.get('firstResponder') is True and not after_esc['overlayActive'] and after_esc['cancelled'] == cancelled + 1
            and len(rows()) == count, 'overlay': shown, 'state': after_esc}

        # C3: portrait -> a 4:5 PNG.
        r = app.call('capture', mode='portrait')
        row = rows()[-1]
        results['capture_c3_portrait'] = {'ok': row['kind'] == 'portrait' and abs(row['width'] / row['height'] - 0.8) < 0.002
            and r['state']['result']['saved'] == row['id'], 'row': row}
        close_card()

        # C2: full page of the 12,000 px page; bands at their offsets.
        app.eval(tab, 'scrollTo(0, 3000), scrollY')
        r = app.call('capture', mode='fullPage', timeout=90)
        row = rows()[-1]
        ys = [int((k * 1000 + 500) * scale) for k in range(12)]
        probe = app.call('captures', probe=[[20, y] for y in ys])['probe'] if row['kind'] == 'fullPage' else []
        bands = [nearest(p) if p else -1 for p in probe]
        scroll_after = app.eval(tab, 'scrollY')
        results['capture_c2_full_page'] = {'ok': row['kind'] == 'fullPage' and row['height'] == round(12000 * scale)
            and bands == list(range(12)) and r['state']['result']['truncated'] is False
            and r['state'].get('card', {}).get('actions') == ['copy', 'save', 'share', 'library', 'delete'],
            'row': row, 'bands': bands, 'probe': probe, 'scrollAfter': scroll_after, 'state': r['state']}
        # Delete on the card removes the file and the row in one step.
        app.call('capture-action', action='delete')
        rows_after_delete = rows()
        results['capture_delete'] = {'ok': row['id'] not in {x['id'] for x in rows_after_delete}
            and not os.path.exists(os.path.join(app.call('captures')['directory'], row['fileName'])) and not state().get('card'),
            'rows': len(rows_after_delete)}

        # C5: Cmd+Shift drag on the page: held under 4 pt, overlay at the press point after it.
        app.call('navigate', tab=tab, url=origin + '/links.html'); app.call('wait', tab=tab)
        count = len(rows())
        r = app.call('capture', mode='area', entry='drag', rect=[500, 300, 240, 160])
        steps, row = r['steps'], rows()[-1]
        results['capture_c5_drag'] = {'ok': steps[0]['held'] and not steps[0]['overlay'] and steps[1]['held'] and not steps[1]['overlay']
            and steps[2]['overlay'] and steps[2]['anchor'] == [500, 300] and len(rows()) == count + 1 and row['kind'] == 'area'
            and row['width'] == round(240 * scale) and row['height'] == round(160 * scale) and r['state']['entry'] == 'drag',
            'steps': steps, 'row': row}
        close_card()

        # C6: Cmd+Shift click on a link: the held press is replayed; a foreground tab opens.
        link = app.eval(tab, "(() => { const r = document.querySelector('#link').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()")
        page = app.call('window-state')['panel']
        tabs_before, replays = len(app.call('tabs')), state()['replays']
        app.call('mouse', action='click', x=page[0] + link[0], y=page[1] + link[1], modifiers=['command', 'shift'])
        opened = wait_until(lambda: next((t for t in app.call('tabs') if t['url'].endswith('/links-target.html') and t['selected']), None), timeout=8, step=.1)
        results['capture_c6_click_replay'] = {'ok': bool(opened) and len(app.call('tabs')) == tabs_before + 1 and state()['replays'] == replays + 1
            and not state()['overlayActive'], 'opened': opened, 'replays': state()['replays']}

        # Section 7.3: "Capture" and "Capture Full Page" in the page context menu, before Inspect.
        app.call('select', tab=tab); app.call('wait', tab=tab)
        app.call('policy', contextMenu='record'); app.call('events')
        app.call('rightclick', tab=tab, x=40, y=40)
        menu_event = wait_until(lambda: next((e for e in app.call('events') if e['type'] == 'contextMenu'), None), timeout=5, step=.1)
        app.call('policy', contextMenu='')
        shown = (menu_event or {}).get('shown', [])
        inspect = next((i for i, t in enumerate(shown) if t.startswith('Inspect')), len(shown))
        results['capture_context_menu'] = {'ok': (menu_event or {}).get('open') == ['Capture', 'Capture Full Page']
            and 'Capture' in shown and 'Capture Full Page' in shown and shown.index('Capture') + 1 == shown.index('Capture Full Page')
            and shown.index('Capture Full Page') < inspect, 'shown': shown}

        # 2x: no 2x display is attached to this Mac, so the scale path runs under DevTools device
        # emulation (deviceScaleFactor 2): the screenshot output and the layout metrics follow it.
        app.call('navigate', tab=tab, url=origin + '/long.html'); app.call('wait', tab=tab)
        app.call('devtools', tab=tab, method='Emulation.setDeviceMetricsOverride',
                 params={'width': 0, 'height': 0, 'deviceScaleFactor': 2, 'mobile': False})
        emulated[0] = True
        dpr = wait_until(lambda: (lambda d: d if d == 2 else None)(app.eval(tab, 'devicePixelRatio')), timeout=5, step=.1)
        css_width = app.eval(tab, 'document.documentElement.scrollWidth')
        app.call('capture', mode='area', rect=[100, 100, 300, 200])
        row = rows()[-1]
        close_card()
        results['capture_2x_c1_area'] = {'ok': dpr == 2 and row['kind'] == 'area' and row['width'] == 600 and row['height'] == 400,
                                         'devicePixelRatio': dpr, 'row': row}
        r = app.call('capture', mode='fullPage', timeout=120)
        row = rows()[-1]
        probe = app.call('captures', probe=[[20, (k * 1000 + 500) * 2] for k in range(12)])['probe'] if row['kind'] == 'fullPage' else []
        bands = [nearest(p) if p else -1 for p in probe]
        results['capture_2x_c2_full_page'] = {'ok': row['kind'] == 'fullPage' and row['height'] == 24000 and row['width'] == css_width * 2
            and bands == list(range(12)) and r['state']['result']['truncated'] is False,
            'row': row, 'cssWidth': css_width, 'bands': bands, 'probe': probe}
        close_card()
        # The 32,768 device-pixel cap counts device pixels: a 20,000 CSS px page at 2x is cut there.
        app.call('navigate', tab=tab, url=origin + '/tall.html'); app.call('wait', tab=tab)
        r = app.call('capture', mode='fullPage', timeout=120)
        row = rows()[-1] if r['state'].get('result', {}).get('kind') == 'fullPage' else {}
        probe = app.call('captures', probe=[[20, (k * 1000 + 500) * 2] for k in range(16)])['probe'] if row else []
        bands = [nearest(p) if p else -1 for p in probe]
        results['capture_2x_full_page_cap'] = {'ok': row.get('height') == 32768 and row.get('width') == css_width * 2
            and r['state']['result']['truncated'] is True and r['state'].get('card', {}).get('note') == 'Page cut at 32,768 px.'
            and bands == [k % 12 for k in range(16)], 'row': row, 'bands': bands, 'error': r['state'].get('error'), 'state': r['state']}
        close_card()
        app.call('navigate', tab=tab, url=origin + '/long.html'); app.call('wait', tab=tab)
        app.call('capture', mode='portrait')
        row = rows()[-1]
        view = app.eval(tab, '[innerWidth, innerHeight]')
        results['capture_2x_c3_portrait'] = {'ok': row['kind'] == 'portrait' and abs(row['width'] / row['height'] - 0.8) < 0.002
            and abs(row['width'] - round(view[0] * 2 / 0.86)) <= 2, 'row': row, 'view': view}
        close_card()
        app.call('devtools', tab=tab, method='Emulation.clearDeviceMetricsOverride', params={})
        emulated[0] = False

        # C7 needs incognito windows (app-shell 4.8, not built yet); features-render C3/C7 covers the ephemeral path.
        results['capture_c7_incognito'] = {'status': 'BLOCKED', 'reason': 'no incognito window in Open yet (app-shell 4.8); the ephemeral-context path is covered offscreen (features-render C3/C7)'}
        results['capture_shortcut_hint_once'] = {'ok': state()['hintShows'] == 1, 'hintShows': state()['hintShows']}
    finally:
        for cmd, kw in (('dismiss', {}), ('capture-action', {'action': 'cancel'})):
            try:
                app.call(cmd, timeout=3, **kw)
            except Exception:
                pass
        for key in capture_keys:
            try:
                app.call('defaults', key=key, value=saved_keys.get(key))
            except Exception:
                pass
        if emulated[0]:
            try:
                app.call('devtools', tab=tab, method='Emulation.clearDeviceMetricsOverride', params={}, timeout=3)
            except Exception:
                pass
        app.quit(); server.shutdown(); server.server_close()


def toolbar_checks(factory, results, tmp):
    """commandbar-completion §4.6 / §5.3 `toolbar`: the optional content toolbar in the real App."""
    server, origin = _fixture_server('TB')
    app = factory(urls=(origin + '/alpha',), fresh=True)
    def ws(): return app.call('window-state')
    def title(id='toggle-toolbar'): return next((r['title'] for r in app.call('menu-state') if r['id'] == id), None)
    def enabled(id='toggle-toolbar'): return next((r['enabled'] for r in app.call('menu-state') if r['id'] == id), None)
    try:
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        wait_until(lambda: app.eval(tab, 'document.title') == 'TB /alpha', step=.1)
        # The harness may move and resize the window after launch: compare the page with its own slot.
        before, h0 = ws(), app.eval(tab, 'window.innerHeight')
        results['toolbar_default_off'] = {'ok': not before['toolbar']['shown'] and not before['toolbar']['drawn'] and before['urlFieldVisible']
            and h0 == before['toolbar']['page'][3]
            and 'back' in before['toolbarButtons'] and title() == 'Show Toolbar' and enabled() is True,
            'toolbar': before['toolbar'], 'title': title(), 'enabled': enabled(), 'buttons': before['toolbarButtons'],
            'menuContext': app.call('menu-context'), 'frame': before['frame'], 'panel': before['panel']}
        app.call('key', key='d', modifiers=['cmd', 'shift'])
        shown = wait_until(lambda: (lambda s: s if s['toolbar']['drawn'] else None)(ws()), timeout=3, step=.05) or ws()
        bar = shown['toolbar']
        # The page fills the slot below the bar: innerHeight = slot height − 32.
        h1 = wait_until(lambda: (lambda h: h if h == bar['page'][3] else None)(app.eval(tab, 'window.innerHeight')), timeout=3, step=.05)
        results['toolbar_cmd_shift_d'] = {'ok': bar['shown'] and bar['drawn'] and h1 is not None and bar['frame'][1] == bar['page'][3] and bar['frame'][3] == 32
            and bar['controls'] == ['Go back', 'Go forward', 'Reload', 'Copy Current URL', 'Site Control Center'] and bar['text'] == '127.0.0.1'
            and title() == 'Hide Toolbar' and shown['menuTitles']['toggle-toolbar'] == 'Hide Toolbar',
            'innerHeight': [h0, h1], 'toolbar': bar, 'title': title(), 'menuContext': app.call('menu-context'),
            'frame': shown['frame'], 'panel': shown['panel']}
        fav0, fav1 = before['chrome']['favorites'], shown['chrome']['favorites']
        results['toolbar_sidebar_hides_url_and_navigation'] = {'ok': not shown['urlFieldVisible'] and shown['toolbarButtons'] == ['toggle']
            and bool(fav0) and bool(fav1) and round(fav0[1] - fav1[1], 1) == 36,
            'buttons': shown['toolbarButtons'], 'favoritesY': [fav0[1] if fav0 else None, fav1[1] if fav1 else None]}
        menu = app.call('toolbar-menu')
        app.call('toolbar-menu', item='Show Full URL')
        full = wait_until(lambda: (lambda s: s if s['toolbar']['text'].startswith('http') else None)(ws()), timeout=3, step=.05)
        stored = app.call('defaults', key='open.advanced.showFullURLWithToolbar')
        app.call('defaults', key='open.advanced.showFullURLWithToolbar', value=False)
        host = wait_until(lambda: (lambda s: s if s['toolbar']['text'] == '127.0.0.1' else None)(ws()), timeout=3, step=.05)
        results['toolbar_full_url_setting'] = {'ok': menu == ['Show Full URL', 'Hide Toolbar', '-', 'Manage Extensions'] and bool(full)
            and full['toolbar']['text'] == origin + '/alpha' and stored is True and bool(host),
            'menu': menu, 'text': full['toolbar']['text'] if full else None, 'stored': stored}
        tabs_before = len(app.call('tabs'))
        app.call('toolbar-menu', item='Manage Extensions')
        ext = wait_until(lambda: next((t for t in app.call('tabs') if 'extensions' in t['url']), None), timeout=5, step=.1)
        results['toolbar_manage_extensions'] = {'ok': bool(ext), 'url': ext['url'] if ext else None, 'tabs': [tabs_before, len(app.call('tabs'))]}
        if ext:
            app.call('select', tab=tab); wait_until(lambda: ws()['selected'] == tab, timeout=3, step=.05)
        app.call('toolbar-menu', item='Hide Toolbar')
        hidden = wait_until(lambda: (lambda s: s if not s['toolbar']['drawn'] else None)(ws()), timeout=3, step=.05)
        h2 = wait_until(lambda: (lambda h: h if hidden and h == hidden['toolbar']['page'][3] and h == hidden['panel'][3] else None)(app.eval(tab, 'window.innerHeight')), timeout=3, step=.05)
        results['toolbar_hide_from_menu'] = {'ok': bool(hidden) and hidden['urlFieldVisible'] and h2 is not None and title() == 'Show Toolbar',
            'innerHeight': h2, 'title': title()}
        field_menu = app.call('url-field-menu')
        app.call('url-field-menu', item='Show as Toolbar')
        again = wait_until(lambda: (lambda s: s if s['toolbar']['drawn'] else None)(ws()), timeout=3, step=.05)
        results['toolbar_url_field_show_as_toolbar'] = {'ok': field_menu == ['Show as Toolbar', '-', 'Manage Extensions'] and bool(again), 'menu': field_menu}
        windows_before = len(app.call('shell-windows'))
        app.call('key', key='n', modifiers=['cmd'])
        second = wait_until(lambda: (lambda s: s if len(app.call('shell-windows')) > windows_before and s['id'] != before['id'] else None)(ws()), timeout=5, step=.1)
        results['toolbar_new_window_copies'] = {'ok': bool(second) and second['toolbar']['shown'], 'toolbar': second['toolbar'] if second else None}
        if second:
            app.call('command', id='close-window')
            wait_until(lambda: len(app.call('shell-windows')) == windows_before, timeout=5, step=.1)
        app.call('window-focus', id=before['id'], activate=True)
        app.call('menu-perform', id='new-little-open-window')
        little = wait_until(lambda: next((w for w in app.call('windows') if w['title'] == 'Little Open' and w['key']), None), timeout=5, step=.1)
        refused = enabled() is False if little else None
        results['toolbar_little_open_refuses'] = {'ok': bool(little) and refused is True, 'enabled': enabled()}
        app.call('window-focus', id=before['id'], activate=True)
        app.call('save'); app.quit()
        app = factory(urls=())
        relaunched = wait_until(lambda: (lambda s: s if s['toolbar']['drawn'] else None)(ws()), timeout=10, step=.1)
        results['toolbar_relaunch_keeps'] = {'ok': bool(relaunched) and relaunched['toolbar']['shown'] and not relaunched['urlFieldVisible']}
    finally:
        app.quit(); server.shutdown(); server.server_close()


def numbering_checks(factory, results, tmp):
    """commandbar-completion §5.3 `numbering`: holding Command shows nothing (D13, CC-39); Cmd+2 selects
    item 2 of goToItemTargets; the Essential Keyboard Shortcuts window from its command."""
    server, origin = _fixture_server('NB')
    app = factory(urls=tuple(origin + '/%s' % n for n in ('one', 'two', 'three')), fresh=True)
    def ws(): return app.call('window-state')
    try:
        for t in app.call('tabs'): app.call('wait', tab=t['id'])
        time.sleep(.5)
        # Control pair first (no key): the sidebar must already be still, so a difference while
        # Command is held can only come from the press.
        shots = {n: os.path.join(tmp, 'numbering-%s.png' % n) for n in ('rest', 'rest2', 'held')}
        sidebar = ws()['sidebarFrame']
        def sidebar_diff(a, b):
            wa, ha, pa = read_image(a); wb, hb, pb = read_image(b)
            if (wa, ha) != (wb, hb): return 999, None
            scale = wa / ws()['frame'][2]; diff, where = 0, None
            for y in range(0, ha, 2):
                for x in range(int(sidebar[0] * scale), int((sidebar[0] + sidebar[2]) * scale), 2):
                    ca, cb = pa(x, y), pb(x, y); d = max(abs(ca[i] - cb[i]) for i in range(3))
                    if d > diff: diff, where = d, [round(x / scale), round(y / scale)]
            return diff, where
        still = None
        for _ in range(10):
            app.call('snapshot', path=shots['rest']); time.sleep(2); app.call('snapshot', path=shots['rest2'])
            still = sidebar_diff(shots['rest'], shots['rest2'])
            if still[0] <= 2: break
        app.call('key', key='command', modifiers=['command'])
        time.sleep(2)
        app.call('snapshot', path=shots['held'])
        app.call('key', key='command')
        held = sidebar_diff(shots['rest2'], shots['held'])
        results['numbering_hold_command_no_hints'] = {'ok': still[0] <= 2 and held[0] <= 2, 'controlDifference': still, 'heldDifference': held,
            'scope': 'sidebar pixels, rest vs rest 2 s later (control), then rest vs Command held 2 s'}
        today = [n['id'] for n in app.call('sidebar-tree')['today']]
        app.call('key', key='2', modifiers=['cmd'])
        picked = wait_until(lambda: ws()['selected'] == today[1], timeout=3, step=.05) if len(today) > 1 else None
        app.call('key', key='9', modifiers=['cmd'])
        last = wait_until(lambda: ws()['selected'] == today[-1], timeout=3, step=.05)
        results['numbering_cmd2_cmd9'] = {'ok': bool(picked) and bool(last), 'today': today, 'selected': ws()['selected']}
        app.call('command', id='keyboard-shortcuts-edu')
        edu = wait_until(lambda: next((w for w in app.call('windows') if w['title'] == 'Essential Keyboard Shortcuts' and w['visible']), None), timeout=5, step=.1)
        if edu:
            app.call('key', key='escape', window=edu['number'])
        gone = wait_until(lambda: not any(w['title'] == 'Essential Keyboard Shortcuts' and w['visible'] for w in app.call('windows')), timeout=5, step=.1)
        results['numbering_edu_window'] = {'ok': bool(edu) and edu['level'] == 3 and bool(gone), 'window': edu}
    finally:
        app.quit(); server.shutdown(); server.server_close()


def routing_checks(factory, results, tmp):
    """Step 5: LaunchServices -> real kAEGetURL -> intake -> model/window.
    Never sets a system default handler. Every delivery names this exact bundle.
    """
    import copy
    import plistlib
    import uuid
    domain = 'io.github.sergeserb2.open'
    keys = ('open.links.externalInLittleOpen', 'open.links.littleOpenHotkeyEnabled')
    exported = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
    domain_before = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    saved = {key: domain_before.get(key) for key in keys}
    server, origin = _fixture_server('Routing')
    app = None

    def record(name, ok, **details):
        results[name] = dict(details, ok=bool(ok))

    def log(): return app.call('routing-log')
    def snapshot():
        with open(app.call('save')) as stream: return json.load(stream)
    def tab_count():
        return sum(len(space['today']) for space in snapshot()['spaces'])
    def entries(url): return [row for row in log()['entries'] if row['decision']['request']['url'] == url]
    def deliver(url):
        return subprocess.run(['/usr/bin/open', '-a', app.bundle, url], capture_output=True, text=True, timeout=15)
    def landed(url, count=1):
        return wait_until(lambda: len([t for t in app.call('tabs') if t['url'] == url]) == count, timeout=8, step=.05)

    try:
        # Capture actual persisted values, including absence, before resetting.
        for key in keys: subprocess.run(['defaults', 'delete', domain, key], capture_output=True)
        subprocess.run(['defaults', 'write', domain, keys[0], '-bool', 'true'], check=True)
        subprocess.run(['defaults', 'write', domain, keys[1], '-bool', 'false'], check=True)
        app = factory(urls=(), fresh=True)
        state_before = app.call('default-browser-state')
        seed = snapshot()
        target = copy.deepcopy(seed['spaces'][0])
        target['id'] = str(uuid.uuid4()).upper()
        target['title'] = 'Routing target'
        target['today'] = []; target['pinned'] = []
        seed['spaces'].append(target)
        seed['routingRules'] = [{'id': str(uuid.uuid4()).upper(),
            'match': {'hostEquals': {'_0': '127.0.0.1'}}, 'destination': {'space': {'_0': target['id']}}}]
        seed['defaultDestination'] = {'littleOpen': {}}
        fixture_path = os.path.join(tmp, 'routing-snapshot.json')
        with open(fixture_path, 'w') as stream: json.dump(seed, stream)
        app.quit()
        app = factory(urls=(), snapshot=fixture_path)
        app.call('space', space=target['id'])
        existing_url = origin + '/existing-today'
        app.call('open', url=existing_url)
        app.call('space', space=seed['spaces'][0]['id'])

        warm = origin + '/warm-space'
        sent = deliver(warm)
        reached = landed(warm)
        tabs = app.call('tabs')
        record('routing_warm_space_rule', sent.returncode == 0 and reached
               and next(s for s in app.call('spaces') if s['focused'])['id'] == target['id']
               and tabs[0]['url'] == warm and tabs[0]['section'] == 'today' and tabs[0]['selected']
               and tabs[1]['url'] == existing_url
               and len(entries(warm)) == 1, tabs=tabs, log=log())

        default_url = origin.replace('127.0.0.1', 'localhost') + '/default-little'
        before = tab_count()
        sent = deliver(default_url)
        seen = wait_until(lambda: (log()['lastLittleOpenRequest'] or {}).get('url') == default_url, timeout=8, step=.05)
        record('routing_warm_default_little_open', sent.returncode == 0 and seen
               and tab_count() == before and len(entries(default_url)) == 1, log=log())

        # Stored first window is on target B. Make a second, front window on
        # A: using model order instead of AppKit z-order must now fail B8.
        app.call('menu-perform', id='new-window')
        app.call('dismiss')
        app.call('space', space=seed['spaces'][0]['id'])
        front_id = app.call('window-state')['id']
        app.call('defaults', key=keys[0], value=False)
        toggle_url = default_url + '?toggle=off'
        sent = deliver(toggle_url)
        reached = landed(toggle_url)
        rows = entries(toggle_url)
        off_ok = sent.returncode == 0 and reached \
               and next(s for s in app.call('spaces') if s['focused'])['id'] == seed['spaces'][0]['id']
        off_ok = off_ok and app.call('window-state')['id'] == front_id and len(app.call('shell-windows')) == 2 \
               and rows and 'defaultSuppressedByToggle' in rows[-1]['decision']['via'] \
               and 'Little Open off' in rows[-1]['summary']
        off_log = log(); before = tab_count()
        app.call('defaults', key=keys[0], value=True)
        toggle_on = default_url + '?toggle=on'
        sent = deliver(toggle_on)
        seen = wait_until(lambda: (log()['lastLittleOpenRequest'] or {}).get('url') == toggle_on, timeout=8, step=.05)
        record('routing_toggle_off_most_recent_space', off_ok and sent.returncode == 0 and seen and tab_count() == before,
               off=off_log, on=log())

        # Both deliveries are in one OS launch command: no socket round trip can
        # accidentally move the second arrival outside the two-second window.
        duplicate = origin + '/duplicate?preserve=Query%20Case'
        before = tab_count(); dropped = log()['duplicatesDropped']
        started = time.monotonic()
        sent = subprocess.run(['/usr/bin/open', '-a', app.bundle, duplicate, duplicate], capture_output=True, text=True, timeout=15)
        first = landed(duplicate)
        within = wait_until(lambda: log()['duplicatesDropped'] == dropped + 1, timeout=1, step=.02)
        first_log = log()
        # A genuine second click after the fixed window must create another tab.
        time.sleep(max(0, 2.15 - (time.monotonic() - started)))
        again = deliver(duplicate)
        second = landed(duplicate, 2)
        record('routing_dedupe_2s', sent.returncode == 0 and again.returncode == 0 and first and within and second
               and tab_count() == before + 2 and len(entries(duplicate)) == 2,
               firstLog=first_log, finalLog=log(), loadAverage=list(os.getloadavg()))

        rows = entries(warm)
        record('routing_source_detected', rows and (rows[0]['sourceBundleID'] or (rows[0]['sourcePID'] or 0) > 0),
               source=rows[0] if rows else None, delivery='/usr/bin/open -a <exact built bundle>')

        rejected = 'ftp://127.0.0.1/non-http'
        before = tab_count(); little_before = log()['lastLittleOpenRequest']
        sent = deliver(rejected)
        # LaunchServices may refuse a scheme absent from CFBundleURLTypes, or
        # deliver it to the explicit app. In the latter case intake must log rejection.
        if sent.returncode == 0:
            wait_until(lambda: entries(rejected), timeout=3, step=.05)
        rows = entries(rejected)
        rejected_log = rows and 'rejectedNonHTTP' in rows[-1]['decision']['via'] and rows[-1]['decision'].get('resolved') is None
        record('routing_non_http_rejected', tab_count() == before and log()['lastLittleOpenRequest'] == little_before
               and (sent.returncode != 0 or rejected_log), exit=sent.returncode, stderr=sent.stderr.strip(), entries=rows,
               launchServices='refused' if sent.returncode else 'delivered to explicit app')

        while app.call('shell-windows'):
            # The final retained model window must be on a different Space
            # from the rule, so recreating it alone cannot satisfy this check.
            app.call('space', space=seed['spaces'][0]['id'])
            app.call('window-close')
        none_before = app.call('shell-windows')
        no_window = origin + '/no-window'
        sent = deliver(no_window)
        created = wait_until(lambda: app.call('shell-windows'), timeout=8, step=.05)
        reached = landed(no_window) if created else False
        record('routing_no_window', not none_before and sent.returncode == 0 and created and reached
               and next(s for s in app.call('spaces') if s['focused'])['id'] == target['id']
               and app.call('tabs')[0]['selected'], windows=app.call('shell-windows'), log=log())

        # Cold URL is an open(1) URL operand, never an App argv URL. -n starts
        # this exact bundle with this run's data dir and automation arguments.
        app.quit()
        fast_cold = origin + '/cold-fast'
        app = factory(urls=(), snapshot=fixture_path, delivery_urls=(fast_cold,))
        fast_reached = landed(fast_cold)
        fast_log = log()
        app.quit()
        cold = origin + '/cold-launch'
        # Also hold only the readiness handoff, to prove an event received
        # before readiness stays pending. The real LaunchServices path is unchanged.
        app = factory(urls=(), snapshot=fixture_path, delivery_urls=(cold,),
                      extra_env={'OPEN_AUTOMATION_ROUTING_SLOW_READY': '1'})
        pending = wait_until(lambda: (lambda state: state if state['pendingCount'] > 0 and not state['ready'] else None)(log()),
                             timeout=1, step=.02)
        reached = landed(cold)
        cold_log = log()
        record('routing_cold_launch_queue', fast_reached and pending and reached and cold_log['ready'] and cold_log['pendingCount'] == 0
               and cold_log['queuedCount'] >= 1 and cold_log['drainedCount'] == cold_log['queuedCount']
               and len(entries(cold)) == 1 and app.call('tabs')[0]['selected'], log=cold_log,
               pending=pending, fastLaunch=fast_log,
               command='open -n -a <exact built bundle> <URL> --args --user-data-dir=<suite root> ...')
        state_after = app.call('default-browser-state')
        record('routing_default_browser_read_only', state_before == state_after
               and state_after['isDefaultBrowser'] == (state_after['http']['isDefault'] and state_after['https']['isDefault']),
               before=state_before, after=state_after)
    finally:
        if app:
            _restore_defaults(app, saved)
            app.quit()
        else:
            # A failed initial launch still restores exactly the keys reset above.
            for key, value in saved.items():
                if value is None: subprocess.run(['defaults', 'delete', domain, key], capture_output=True)
                else: subprocess.run(['defaults', 'write', domain, key, '-bool', 'true' if value else 'false'], check=True)
        server.shutdown(); server.server_close()


def commandbar_checks(factory, results, tmp, config):
    import http.server
    import threading
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = ("<!doctype html><title>Shell C %s</title><body style='background:#302d4a;color:white'>Shell C %s<p id=copy-source>PAGE COPY</p><input id=edit-input value=seed>"
                    "<script>window.keys=[];document.addEventListener('keydown',e=>{window.keys.push(e.key);e.preventDefault()})</script>" % (self.path, self.path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    app = factory(urls=(origin + '/start',), fresh=True)
    state = lambda: app.call('commandbar-state')
    def bar(key, route='app'):
        routing = app.call('key', key=key, modifiers=['cmd'], route=route)
        assert wait_until(lambda: state().get('presented'), timeout=3, step=.05), {'bar':state(),'routing':routing,'window':app.call('window-state'),'menu':[r for r in app.call('menu-state') if r['id'] in ('new-tab','show-fonts')]}
        return state()
    def type_query(text):
        app.call('key', text=text)
        return wait_until(lambda: state() if state().get('text') == text and state().get('final') else None, timeout=5, step=.05)
    def press(key, **kw): return app.call('key', key=key, **kw)
    try:
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        wait_until(lambda: app.eval(tab, 'document.title') == 'Shell C /start', step=.1)
        app.call('suggest-remote', enabled=False)
        assert wait_until(lambda: app.call('hotkey-state')['prepared'], timeout=5, step=.02), 'post-paint command preparation did not run'
        results['lazy_commandbar'] = {'ok': state().get('created') is False}
        switcher_before = app.call('tab-switcher-state')
        app.call('focus', tab=tab)
        opened = bar('t', 'window')
        first_open = wait_until(lambda: state() if state().get('openFirstResultsMs',-1) >= 0 else None, step=.02)
        results['first_open_results_budget'] = {'loadAverage': list(os.getloadavg()), 'ok': bool(first_open) and first_open['openFirstResultsMs'] <= 50, 'milliseconds': first_open.get('openFirstResultsMs') if first_open else None, 'scope': 'showCommandBar entry to first snapshot applied; excludes preceding key routing, socket transport and frame presentation'}
        switcher_after = app.call('tab-switcher-state')
        results['lazy_tab_switcher'] = {'ok': switcher_before['created'] is False and switcher_after['created'] is False and not switcher_after['monitoringModifiers'], 'before': switcher_before, 'after': switcher_after}
        results['cmd_t_mode'] = {'ok': opened['mode'] == 'newTab' and opened['newTabHighlighted'], 'state': opened}
        # Arc's empty Cmd+T (Section 2 item 9; S2 18/0008, 18/0044 AX): open tabs, then "Contact the Team"; no history.
        empty_final = wait_until(lambda: (lambda st: st if st.get('final') and st.get('text') == '' else None)(state()), timeout=3, step=.05) or state()
        kinds = [r['kind'] for r in empty_final.get('rows', [])]
        tab_rows = len(kinds) - len(list(__import__('itertools').dropwhile(lambda k: k == 'switchToTab', kinds)))
        results['empty_cmd_t_order'] = {'ok': 1 <= tab_rows <= 4 and kinds[tab_rows:] == ['action']
            and empty_final['rows'][tab_rows]['action'] == 'contact-team', 'kinds': kinds,
            'actions': [r['action'] for r in empty_final.get('rows', []) if r['kind'] == 'action']}
        typed = type_query(origin.removeprefix('http://') + '/new')
        press('return')
        new = wait_until(lambda: next((t for t in app.call('tabs') if t['url'] == origin + '/new'), None), step=.1)
        assert new, app.call('tabs')
        wait_until(lambda: app.eval(new['id'], 'document.title') == 'Shell C /new', step=.1)
        results['typed_top_today'] = {'ok': app.call('tabs')[0]['id'] == new['id'] and app.eval(new['id'], 'document.title') == 'Shell C /new', 'tab': new['id']}
        edited = bar('l', 'window')
        results['cmd_l_selection'] = {'ok': edited['mode'] == 'editCurrentURL' and edited['text'] == origin + '/new' and edited['range'] == [0, len(origin + '/new')], 'state': edited}
        type_query(origin + '/edited'); press('return')
        correct = wait_until(lambda: app.eval(new['id'], 'document.title') == 'Shell C /edited', step=.1)
        results['edit_current_tab'] = {'ok': bool(correct) and len(app.call('tabs')) == 2, 'title': app.eval(new['id'], 'document.title')}
        commandbar_footer_checks(app, results, tmp, bar, press, new['id'])
        app.call('focus', tab=new['id'])
        app.eval(new['id'], "(() => {let r=document.createRange();r.selectNodeContents(document.querySelector('#copy-source'));let s=getSelection();s.removeAllRanges();s.addRange(r)})()")
        app.call('pasteboard-write', text='COPY NOT RUN')
        press('c', modifiers=['cmd'], route='window')
        copied = wait_until(lambda: app.call('pasteboard') == 'PAGE COPY', step=.05)
        results['page_copy_native_responder'] = {'ok': bool(copied), 'clipboard': app.call('pasteboard')}
        app.call('click', tab=new['id'], selector='#edit-input')
        press('a', modifiers=['cmd'], route='window')
        selected = wait_until(lambda: app.eval(new['id'], "[document.querySelector('#edit-input').selectionStart,document.querySelector('#edit-input').selectionEnd]") == [0,4], step=.05)
        results['page_select_all_native_responder'] = {'ok': bool(selected)}
        press('v', modifiers=['cmd'], route='window')
        pasted = wait_until(lambda: app.eval(new['id'], "document.querySelector('#edit-input').value") == 'PAGE COPY', step=.05)
        results['page_paste_native_responder'] = {'ok': bool(pasted)}
        press('z', modifiers=['cmd'], route='window')
        undone = wait_until(lambda: app.eval(new['id'], "document.querySelector('#edit-input').value") == 'seed', step=.05)
        results['page_undo_native_responder'] = {'ok': bool(undone) and app.call('window-state')['selected'] == new['id']}
        press('a', modifiers=['cmd'], route='window'); press('x', modifiers=['cmd'], route='window')
        cut = wait_until(lambda: app.eval(new['id'], "document.querySelector('#edit-input').value") == '', step=.05)
        results['page_cut_native_responder'] = {'ok': bool(cut) and app.call('pasteboard') == 'seed'}
        press('z', modifiers=['cmd'], route='app')
        wait_until(lambda: app.eval(new['id'], "document.querySelector('#edit-input').value") == 'seed', step=.05)
        menu = app.call('menu-state')
        native_ids = {'cut','copy','paste','paste-and-match-style','select-all','undo','redo','find','find-next','find-previous','quit-open','hide-open','hide-others','show-all','minimize-window','zoom-window','bring-all-to-front','close-window','toggle-full-screen','emoji-and-symbols','start-speaking','stop-speaking','show-fonts','font-bold','font-italic','font-underline'}
        native_rows = [r for r in menu if r['id'] in native_ids]
        results['system_menu_nil_targets'] = {'ok': {r['id'] for r in native_rows} == native_ids and all(r['targetNil'] and r['action'] for r in native_rows), 'rows': native_rows}
        registered = app.call('menu-context')
        results['native_menu_registration'] = {'ok': all(registered.values()), 'menus': registered}
        results['native_font_traits'] = {'ok': any(r['id'] == 'font-bold' and r['action'] == 'addFontTrait:' and r['tag'] == 2 for r in menu) and any(r['id'] == 'font-italic' and r['action'] == 'addFontTrait:' and r['tag'] == 1 for r in menu)}
        results['tabs_reveal_registered'] = {'ok': any(r['id'] == 'reveal-tab-in-sidebar' and r['title'] == 'Reveal Tab in Sidebar' and r['key'] == '' for r in menu)}
        # Rename uses the existing live sidebar editor, not a nested modal loop.
        app.eval(new['id'], 'window.renameTicks=0;window.renameTicker=setInterval(()=>window.renameTicks++,10);1')
        app.call('menu-perform', id='rename-tab')
        editor = wait_until(lambda: (lambda f: f if f['responder'] in ('NSTextView','FieldEditor') and not f['sheet'] else None)(app.call('focus-state')), timeout=3, step=.02)
        assert editor, app.call('focus-state')
        ticks = app.eval(new['id'], 'window.renameTicks')
        engine_alive = wait_until(lambda: app.eval(new['id'], 'window.renameTicks') > ticks, timeout=3, step=.02)
        press('text', text='Renamed through menu'); press('return')
        renamed = wait_until(lambda: app.tab(new['id'])['title'] == 'Renamed through menu', timeout=3, step=.02)
        app.call('menu-perform', id='rename-tab'); press('text', text='Cancelled rename'); press('escape')
        cancelled = wait_until(lambda: app.call('focus-state')['responder'] not in ('NSTextView','FieldEditor'), timeout=3, step=.02)
        results['rename_tab_inline'] = {'ok': bool(editor) and bool(engine_alive) and bool(renamed) and bool(cancelled)
            and app.tab(new['id'])['title'] == 'Renamed through menu'
            and app.eval(new['id'], 'document.title') == 'Shell C /edited', 'editor': editor, 'engineHeartbeatAdvanced': bool(engine_alive)}
        app.eval(new['id'], 'clearInterval(window.renameTicker);1')
        before_text_undo = len(app.call('tabs'))
        bar('t'); type_query('word'); native_before = state(); native_route = press('z', modifiers=['cmd'])
        native_undone = wait_until(lambda: state()['text'] == '', timeout=3, step=.05)
        results['native_field_undo_preserves_model'] = {'ok': bool(native_undone) and state()['presented'] and len(app.call('tabs')) == before_text_undo, 'before':native_before, 'after':state(), 'route':native_route}
        press('escape'); time.sleep(.25)
        counts = app.call('host-counts')['created']; selected_before = app.call('window-state')['selected']
        bar('t'); type_query(origin + '/background'); press('return', modifiers=['cmd'])
        background = wait_until(lambda: next((t for t in app.call('tabs') if t['url'] == origin + '/background'), None), step=.1)
        assert background, app.call('tabs')
        app.call('wait', tab=background['id'])
        results['command_return_background'] = {'ok': app.call('window-state')['selected'] == selected_before and app.call('host-counts')['created'] == counts + 1 and app.eval(background['id'], 'document.title') == 'Shell C /background'}
        for action, query, expected in [('pin-tab','Pin Tab','pinned'),('unpin-tab','Unpin Tab','today')]:
            bar('t'); actions = type_query(query); assert actions, state()
            index = next(i for i,r in enumerate(actions['rows']) if r['action'] == action)
            selected = actions['selected']
            while selected != index:
                press('down' if selected < index else 'up'); selected = state()['selected']
            press('return')
            results['action_' + action] = {'ok': app.tab(new['id'])['section'] == expected and app.eval(new['id'], 'document.title') == 'Shell C /edited'}
        bar('t'); calc = type_query('12*7'); assert calc, state()
        rows = calc['rows']; index = next(i for i, r in enumerate(rows) if r['kind'] == 'calculator')
        selected = calc['selected']
        while selected != index:
            press('down' if selected < index else 'up'); selected = state()['selected']
        press('return')
        results['calculator_copy'] = {'ok': app.call('pasteboard') == '84', 'clipboard': app.call('pasteboard')}
        bar('t'); press('escape'); time.sleep(.3)
        app.eval(new['id'], 'window.keys=[]')
        press('escape', route='window'); time.sleep(.15)
        results['escape_then_page'] = {'ok': not state()['presented'] and 'Escape' in app.eval(new['id'], 'window.keys'), 'keys': app.eval(new['id'], 'window.keys')}
        mode = app.call('window-state')['sidebarMode']
        press('s', modifiers=['cmd'], route='window'); hidden = app.call('window-state')['sidebarMode']
        press('s', modifiers=['cmd'], route='window')
        results['cmd_s_page_swallowing_keys'] = {'ok': mode != hidden and app.call('window-state')['sidebarMode'] == mode}
        second_space = app.call('space-create', title='Cross Space', profile='Default')
        target = app.call('open', url=origin + '/cross')
        target = target['id'] if isinstance(target, dict) else target
        app.call('wait', tab=target)
        wait_until(lambda: app.eval(target, 'document.title') == 'Shell C /cross', step=.1)
        first_space = next(s['id'] for s in app.call('spaces') if s['id'] != second_space)
        app.call('space', space=first_space)
        bar('t'); cross = type_query('Shell C /cross'); assert cross, state()
        index = next(i for i, r in enumerate(cross['rows']) if r['tab'] == target)
        selected = cross['selected']
        while selected != index:
            press('down' if selected < index else 'up'); selected = state()['selected']
        return_routing = press('return')
        switched = wait_until(lambda: app.call('window-state') if app.call('window-state')['space'] == second_space and app.call('window-state')['selected'] == target else None, timeout=3, step=.1)
        results['switch_tab_across_spaces'] = {'ok': bool(switched) and app.eval(target, 'document.title') == 'Shell C /cross', 'state': app.call('window-state'), 'expectedSpace': second_space, 'expectedTab': target, 'rows': cross['rows'], 'barAfterReturn':state(), 'returnRouting':return_routing}
        bar('t'); timings = wait_until(lambda: state() if state().get('openFirstResultsMs', -1) >= 0 else None, step=.02)
        results['first_results_budget'] = {'loadAverage': list(os.getloadavg()), 'ok': bool(timings) and timings['openFirstResultsMs'] <= 50, 'milliseconds': timings.get('openFirstResultsMs') if timings else None, 'scope': 'showCommandBar entry to first snapshot applied; excludes preceding key routing, socket transport and frame presentation'}
        shot(app, 'commandbar-live-%s.png' % config.lower(), window=app.call('window-state')['number'])
        press('escape'); time.sleep(.3)
        other_profile_space = app.call('space-create', title='Isolated profile', profile='Commandbar Isolated')
        app.call('suggest-remote', enabled=False)
        isolated = bar('t'); isolated_rows = type_query('Shell C')
        results['suggest_profile_isolation'] = {'ok': isolated['profile'] != opened['profile'] and all(r['tab'] not in (tab,new['id'],target) for r in isolated_rows['rows'])}
        press('escape'); time.sleep(.2); app.call('space', space=second_space)
        time.sleep(.1)
        menu = app.call('menu-state')
        results['dynamic_menus'] = {'ok': any(x['id'] == 'dynamic-space-' + second_space for x in menu) and any(x['id'] == 'dynamic-tab-' + target for x in menu), 'entries': len(menu)}
        results['unsupported_disabled'] = {'ok': any(x['id'] == 'new-incognito-window' and not x['enabled'] for x in menu)}
        before = app.call('host-counts'); tree = app.call('sidebar-tree'); app.call('menu-perform', id='duplicate-tab')
        after = app.call('sidebar-tree'); copies = [x for x in after['today'] if x['id'] not in {n['id'] for n in tree['today']}]
        results['duplicate_tab_lazy'] = {'ok': len(copies) == 1 and copies[0]['url'] == origin + '/cross' and not copies[0]['loaded'] and before['created'] == app.call('host-counts')['created'], 'copies': copies}
        app.call('menu-perform', id='reveal-tab-in-sidebar'); app.call('menu-perform', id='undo'); results['duplicate_single_undo'] = {'ok': len(app.call('sidebar-tree')['today']) == len(tree['today'])}
        other = app.call('open', url=origin + '/split')['id']
        app.call('split')
        split = next(n for n in app.call('sidebar-tree')['today'] if n['kind'] == 'split')
        # One row per Split View (commandbar-completion §4.2): a pane's title finds one split row, no pane
        # rows; Return selects the split with that pane focused (the App's selectTabForCommand path).
        pane_ids = [n['id'] for n in split['children']]
        bar('t', 'window'); found = type_query('Shell C /split')
        split_rows = [r for r in found['rows'] if r['id'].startswith('split:')]
        pane_rows = [r for r in found['rows'] if not r['id'].startswith('split:') and r['tab'] in pane_ids]
        top_is_split = bool(found['rows']) and found['rows'][0]['id'].startswith('split:')
        press('return')
        chosen = wait_until(lambda: (lambda ts: ts if next((t for t in ts if t['id'] == other), {}).get('selected') else None)(app.call('tabs')), timeout=5, step=.05) or app.call('tabs')
        visible = {t['id'] for t in chosen if t['visible']}
        results['commandbar_split_one_row'] = {'ok': len(split_rows) == 1 and not pane_rows and top_is_split and split_rows[0]['tab'] == other
                                               and next((t for t in chosen if t['id'] == other), {}).get('selected', False) and set(pane_ids) <= visible
                                               and not state().get('presented'),
                                               'rows': [(r['id'][:6], r['title'], r['tab'] in pane_ids) for r in found['rows']], 'visible': sorted(visible), 'panes': pane_ids}
        # Actions scope (commandbar-completion §4.3): "actions", Tab, "side", Return runs Show/Hide Sidebar.
        bar('t', 'window'); hinted = type_query('actions')
        press('tab')
        scoped = wait_until(lambda: state() if state().get('scope') == 'Actions' and state().get('text') == '' else None, timeout=3, step=.05)
        sided = type_query('side')
        top_action = (sided or {}).get('rows', [{}])[0].get('action') if sided and sided.get('rows') else None
        only_actions = bool(sided) and all(r['kind'] == 'action' for r in sided['rows'])
        press('return')
        hid = sidebar_hidden(app)
        results['commandbar_actions_scope'] = {'ok': bool(scoped) and top_action == 'toggle-sidebar' and only_actions and bool(hid) and not state().get('presented'),
                                               'hint_rows': len((hinted or {}).get('rows', [])), 'scope': (scoped or {}).get('scope'), 'top': top_action}
        app.call('menu-perform', id='toggle-sidebar'); sidebar_anchored(app)
        # Help ▸ Essential Keyboard Shortcuts (commandbar-completion §4.5): one floating window; Esc closes it;
        # reopened, Cmd+W closes it and archives no tab.
        def edu():
            return next((w for w in app.call('windows') if w['title'] == 'Essential Keyboard Shortcuts'), None)
        tabs_before = len(app.call('tabs'))
        app.call('menu-perform', id='keyboard-shortcuts-edu')
        shown = wait_until(lambda: (lambda w: w if w and w['visible'] and w['key'] else None)(edu()), timeout=3, step=.05)
        press('escape', window=shown['number'] if shown else None)
        closed_esc = wait_until(lambda: (lambda w: True if not w or not w['visible'] else None)(edu()), timeout=3, step=.05)
        app.call('menu-perform', id='keyboard-shortcuts-edu')
        reshown = wait_until(lambda: (lambda w: w if w and w['visible'] and w['key'] else None)(edu()), timeout=3, step=.05)
        press('w', modifiers=['cmd'], window=reshown['number'] if reshown else None, route='app')
        closed_w = wait_until(lambda: (lambda w: True if not w or not w['visible'] else None)(edu()), timeout=3, step=.05)
        count = len([w for w in app.call('windows') if w['title'] == 'Essential Keyboard Shortcuts'])
        results['essential_shortcuts_window'] = {'ok': bool(shown) and shown['level'] == 3 and bool(closed_esc) and bool(reshown) and reshown['number'] == shown['number']
                                                 and bool(closed_w) and count == 1 and len(app.call('tabs')) == tabs_before,
                                                 'window': shown, 'tabs': [tabs_before, len(app.call('tabs'))]}
        before = app.call('host-counts')['created']; app.call('sidebar-duplicate', id=split['id'])
        splits = [n for n in app.call('sidebar-tree')['today'] if n['kind'] == 'split']
        copied = next(n for n in splits if n['id'] != split['id'])
        results['duplicate_split_lazy'] = {'ok': len(splits) == 2 and len(copied['children']) == 2 and all(not n['loaded'] for n in copied['children']) and {n['id'] for n in copied['children']}.isdisjoint(n['id'] for n in split['children']) and [n['url'] for n in copied['children']] == [n['url'] for n in split['children']] and before == app.call('host-counts')['created'], 'copy': copied}
        app.call('menu-perform', id='reveal-tab-in-sidebar'); app.call('menu-perform', id='undo')
        # Separate through the model-owned selection path before the folder flow.
        app.call('menu-perform', id='separate-from-split-view')
        app.call('select', tab=target)
        bindings = Path(app.user_data, 'State/keybindings.json')
        bindings.write_text(json.dumps({'version':1,'bindings':{'new-tab':{'shortcuts':[{'key':'o','modifiers':['command','option','control']}], 'priority':'browser'}}}))
        app.call('reload-keybindings'); time.sleep(.1)
        press('o', modifiers=['cmd','opt','ctrl'], route='window'); remapped = state()['presented']; press('escape'); time.sleep(.25)
        menu = app.call('menu-state')
        results['override_menu_and_router'] = {'ok': remapped and any(n['id'] == 'new-tab' and n['key'] == 'o' for n in menu)}
        bindings.write_text(json.dumps({'version':1,'bindings':{'new-tab':{'shortcuts':[{'key':'t','modifiers':['command']}], 'priority':'site-then-browser'}}}))
        app.call('reload-keybindings'); app.call('focus', tab=target); time.sleep(.1)
        press('t', modifiers=['cmd'], route='window'); first = state()['presented']
        press('t', modifiers=['cmd'], route='window'); second = state()['presented']
        results['double_press_shared_router'] = {'ok': not first and second, 'first': first, 'second': second}
        press('escape'); time.sleep(.25)
        bindings.write_text('{broken'); app.call('reload-keybindings'); time.sleep(.1)
        results['invalid_overrides_fallback'] = {'ok': any(n['id'] == 'new-tab' and n['key'] == 't' for n in app.call('menu-state'))}
        bindings.unlink(); app.call('reload-keybindings')
        folder = app.call('folder-create', title='Copy subtree')
        app.call('sidebar-move', tab=target, folder=folder, index=0)
        before = app.call('host-counts')['created']; app.call('sidebar-duplicate', id=folder)
        folders = [n for n in app.call('sidebar-tree')['pinned'] if n['kind'] == 'folder']
        results['duplicate_folder_lazy'] = {'ok': len(folders) == 2 and folders[0]['children'][0]['id'] != folders[1]['children'][0]['id'] and folders[1]['children'][0]['url'] == origin + '/cross' and not folders[1]['children'][0]['loaded'] and before == app.call('host-counts')['created'], 'folders': folders}
        press(',', modifiers=['cmd'], route='window'); time.sleep(.2)
        settings = app.call('settings-state'); app.call('menu-perform', id='settings'); time.sleep(.1)
        shot(app, 'settings-live-%s.png' % config.lower(), window=settings['settings'])
        results['settings_shared_window'] = {'ok': settings['settings'] > 0 and settings['settings'] == app.call('settings-state')['settings'] and settings['sameSnapshot']}
        original_hotkey = app.call('hotkey-state')['enabled']
        if not original_hotkey: app.call('settings-toggle', name='hotkey')
        app.call('settings-toggle', name='hotkey'); off = app.call('hotkey-state')
        app.call('settings-toggle', name='hotkey'); on = app.call('hotkey-state')
        results['global_hotkey_toggle'] = {'ok': not off['enabled'] and not off['registered'] and on['enabled'] and on['attempts'] > off['attempts'] and (on['registered'] or bool(on['error'])), 'off': off, 'on': on}
        if not original_hotkey: app.call('settings-toggle', name='hotkey')
        press('l', modifiers=['cmd','shift'], route='window'); time.sleep(.2)
        library = app.call('settings-state')['library']; app.call('menu-perform', id='view-library')
        shot(app, 'library-live-%s.png' % config.lower(), window=library)
        results['library_shared_window'] = {'ok': library > 0 and library == app.call('settings-state')['library']}
        for command, section in [('view-downloads','downloads'),('view-archive','archive'),('view-history','history')]:
            app.call('menu-perform', id=command); time.sleep(.2)
            library_state = app.call('settings-state')
            results[command + '_real_library'] = {'ok': library_state['library'] == library and library_state['librarySection'] == section and library_state['sharedArchives'], 'state': library_state}
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        archived = app.call('open', url=origin + '/archive')['id']; app.call('wait', tab=archived); app.call('close', tab=archived)
        app.call('menu-perform', id='view-archive')
        archive_state = wait_until(lambda: app.call('settings-state') if any(r['id'] == archived for r in app.call('settings-state')['archive']) else None, step=.1)
        assert archive_state, app.call('settings-state')
        app.call('library-restore', id=archived)
        results['library_archive_restore'] = {'ok': app.tab(archived)['url'] == origin + '/archive' and not app.tab(archived)['hasWebContent'] and all(r['id'] != archived for r in app.call('settings-state')['archive'])}
        app.call('menu-perform', id='view-history'); time.sleep(.2)
        app.call('library-history-open', url=origin + '/history-open')
        history_tab = wait_until(lambda: next((t for t in app.call('tabs') if t['url'] == origin + '/history-open'), None), step=.1)
        results['library_history_profile_open'] = {'ok': bool(history_tab) and history_tab['profile'] == opened['profile']}
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        app.call('settings-custom-engine', template=origin + '/search?q=%s')
        bar('t'); type_query('local custom query'); press('return')
        custom_url = origin + '/search?q=local%20custom%20query'
        custom = wait_until(lambda: next((t for t in app.call('tabs') if t['url'] == custom_url), None), step=.1)
        results['custom_search_engine_navigation'] = {'ok': bool(custom), 'expectedURL': custom_url}
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        app.call('select', tab=target); app.call('wait', tab=target); app.call('focus', tab=target)
        press('s', modifiers=['cmd','shift'])
        save = wait_until(lambda: app.call('save-page-state') if app.call('save-page-state')['visible'] else None, timeout=5, step=.1)
        results['save_page_sheet'] = {'ok': bool(save) and save['requests'] == 1, 'state': save, 'last': app.call('save-page-state')}
        if save: app.call('dismiss')  # AppKit sheet cancel; remote system key input is not covered
        assert wait_until(lambda: not app.call('save-page-state')['pending'], timeout=3, step=.1)
        app.call('dismiss')  # close any remaining owned native panel before the next flow
        capture = os.path.join(tmp, 'saved-command-page.mhtml')
        # This is a separate native Save action. Re-establish its exact browser
        # key window; the completion deliberately never re-keys a window.
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        assert wait_until(lambda: any(r['id'] == 'save-page-as' and r['enabled'] for r in app.call('menu-state')), timeout=3, step=.02), 'Save menu target did not return after sheet cancel'
        app.call('menu-perform', id='save-page-as')
        assert wait_until(lambda: app.call('save-page-state')['visible'], timeout=5, step=.02)
        app.call('save-page-choose', path=capture)
        written = wait_until(lambda: os.path.exists(capture) and 'Shell C' in Path(capture).read_text(errors='replace'), timeout=10, step=.05)
        results['save_page_capture'] = {'ok': bool(written) and not app.call('save-page-state')['pending'],
            'written': bool(written), 'bytes': os.path.getsize(capture) if os.path.exists(capture) else 0}

        # Inline completion in the real App (commandbar-completion §4.1, §5.3): a page visited twice on
        # localhost; Cmd+T, `localh` typed through the App's key path: the field completes the host with the
        # port and selects the completed tail; Return goes to that page; Backspace removes only the completion.
        host = 'localhost:%d' % server.server_address[1]
        local = new_tab(app, 'http://%s/alpha' % host)
        local_id = local['id'] if isinstance(local, dict) else local
        app.call('wait', tab=local_id)
        app.call('navigate', tab=local_id, url='http://%s/beta' % host); app.call('wait', tab=local_id)
        app.call('navigate', tab=local_id, url='http://%s/alpha' % host); app.call('wait', tab=local_id)
        other_tab = next(t['id'] for t in app.call('tabs') if t['id'] != local_id)
        app.call('select', tab=other_tab); app.call('focus', tab=other_tab)
        bar('t', 'window'); typed_l = type_query('localh')
        completed = wait_until(lambda: (lambda st: st if st.get('fieldText') == host and st.get('range') == [6, len(host) - 6] else None)(state()), timeout=3, step=.05)
        press('return')
        went = wait_until(lambda: (lambda w: w if w['selected'] == local_id else None)(app.call('window-state')), timeout=5, step=.05)
        bar('t', 'window'); type_query('localh')
        wait_until(lambda: state().get('fieldText') == host, timeout=3, step=.05)
        press('delete')
        removed = wait_until(lambda: (lambda st: st if st.get('fieldText') == 'localh' and st.get('text') == 'localh' and st.get('range') == [6, 0] else None)(state()), timeout=3, step=.05)
        press('escape')
        results['commandbar_inline_completion'] = {'ok': bool(completed) and bool(went) and bool(removed),
            'completed': {k: (completed or state()).get(k) for k in ('text', 'fieldText', 'range')},
            'afterBackspace': {k: (removed or state()).get(k) for k in ('text', 'fieldText', 'range')}, 'switched': bool(went)}
        app.call('close', tab=local_id)
        # A window the user creates opens with the command bar in New Tab mode (Section 2 item 10:
        # F0098, F0157, A0359); the launch window did not create a bar (`lazy_commandbar` above).
        windows_before = len(app.call('shell-windows')); first_window = app.call('window-state')['id']
        app.call('menu-perform', id='new-window')
        opened_new = wait_until(lambda: (lambda w, st: st if len(app.call('shell-windows')) > windows_before and w['id'] != first_window
            and st.get('presented') and st.get('mode') == 'newTab' else None)(app.call('window-state'), state()), timeout=5, step=.05)
        press('escape')
        app.call('menu-perform', id='close-window')
        closed_new = wait_until(lambda: len(app.call('shell-windows')) == windows_before, timeout=5, step=.1)
        app.call('window-focus', id=first_window, activate=True)
        results['new_window_opens_command_bar'] = {'ok': bool(opened_new) and bool(closed_new),
            'state': {k: (opened_new or {}).get(k) for k in ('presented', 'mode', 'newTabHighlighted')}}
        # Copy URL removes trackers by Arc's rule and names what it copied (Section 2 item 12, CC-31a).
        clean_tab = new_tab(app, origin + '/clean?utm_source=news&q=1&fbclid=x')
        app.call('select', tab=clean_tab); wait_until(lambda: app.call('window-state')['selected'] == clean_tab, timeout=3, step=.05)
        app.call('menu-perform', id='copy-url')
        copied_clean = wait_until(lambda: app.call('pasteboard') == origin + '/clean?q=1', timeout=3, step=.05)
        clean_toast = app.call('window-state')['toast']
        app.call('navigate', tab=clean_tab, url=origin + '/plain'); app.call('wait', tab=clean_tab)
        app.call('menu-perform', id='copy-url')
        copied_plain = wait_until(lambda: app.call('pasteboard') == origin + '/plain', timeout=3, step=.05)
        plain_toast = app.call('window-state')['toast']
        results['copy_url_without_trackers'] = {'ok': bool(copied_clean) and clean_toast == 'Copied a clean link without trackers'
            and bool(copied_plain) and plain_toast == 'Copied Current URL', 'toasts': [clean_toast, plain_toast], 'pasteboard': app.call('pasteboard')}
        app.call('close', tab=clean_tab)
        # Edit Pinned URL (app-shell §4.1, Section 2 item 11): the row menu's Edit Pinned Page ▸ Edit… opens
        # the command bar in edit mode with the pinned URL selected; Return stores the new pinned URL, and
        # the tab, still on its pinned page, goes there.
        pin_id = new_tab(app, origin + '/pinned')
        app.call('pin', tab=pin_id)
        app.call('sidebar-menu', node=pin_id, item='Edit Pinned Page/Edit…')
        editing = wait_until(lambda: (lambda st: st if st.get('presented') and st.get('pinnedEdit') == pin_id else None)(state()), timeout=3, step=.05)
        type_query(origin + '/pinned-new'); press('return')
        changed = wait_until(lambda: next((t for t in app.call('tabs') if t['id'] == pin_id and t['pinnedURL'] == origin + '/pinned-new'), None), timeout=5, step=.1)
        moved = wait_until(lambda: app.eval(pin_id, 'document.title') == 'Shell C /pinned-new', timeout=5, step=.1)
        results['edit_pinned_url'] = {'ok': bool(editing) and editing['mode'] == 'editCurrentURL' and editing['text'] == origin + '/pinned'
            and editing['range'] == [0, len(origin + '/pinned')] and bool(changed) and bool(moved) and not state().get('pinnedEdit'),
            'editing': {k: (editing or {}).get(k) for k in ('mode', 'text', 'range', 'pinnedEdit')}, 'pinnedURL': (changed or {}).get('pinnedURL')}
        time.sleep(.25)
        app.call('menu-perform', id='settings'); original_external = app.call('settings-state')['external']
        app.call('settings-toggle', name='external'); app.call('save'); app.quit()
        app = factory(urls=())
        press(',', modifiers=['cmd']); time.sleep(.2)
        results['settings_persist_relaunch'] = {'ok': app.call('settings-state')['external'] != original_external}
        app.call('settings-toggle', name='external')
    finally:
        app.quit(); server.shutdown(); server.server_close()


def commandbar_footer_checks(app, results, tmp, bar, press, tab):
    """commandbar-completion Step 0: no open or close animation (CC-44) and the (i) privacy
    footer (CC-42), through real keys, real AX presses and the real Settings writer."""
    state = lambda: app.call('commandbar-state')
    notice = 'open.general.searchSuggestNoticeDismissed'
    app.call('select', tab=tab); app.call('focus', tab=tab)
    app.call('defaults', key=notice, value=False)
    app.call('suggest-remote', enabled=True)
    try:
        visible = lambda: sorted(w['number'] for w in app.call('windows') if w['visible'])
        windows_before = visible()
        # Cmd+T: the window's first snapshot after the key already shows the whole panel.
        first_png, later_png = os.path.join(tmp, 'bar-first.png'), os.path.join(tmp, 'bar-later.png')
        app.call('key', key='t', modifiers=['cmd'], route='app')
        at_key = state()  # next command after the key: an animation of the old 0.13–0.22 s length is still running
        app.call('snapshot', path=first_png)
        opened = wait_until(lambda: state() if state().get('presented') and state().get('final') else None, timeout=5, step=.05)
        time.sleep(.4)  # longer than the deleted 0.22 s spring and 0.13 s fade
        app.call('snapshot', path=later_png)
        fx, fy, fw, fh = opened['panelFrame']
        w1, h1, p1 = read_image(first_png); w2, h2, p2 = read_image(later_png)
        sx = w1 / max(1, app.call('window-state')['frame'][2])
        # Panel fill and the empty row area: no caret, no rows changing between the two shots.
        probes = [(fx + 300, fy + 8), (fx + 600, fy + 56), (fx + fw / 2, fy + fh - 4), (fx + fw - 5, fy + fh / 2)]
        diff = max(max(abs(a - b) for a, b in zip(p1(x * sx, y * sx), p2(x * sx, y * sx))) for x, y in probes)
        results['commandbar_no_open_animation'] = {'ok': at_key['presented'] and at_key['animationKeys'] == [] and at_key['panelOpacity'] == 1
            and (w1, h1) == (w2, h2) and diff <= 2 and not opened['footer'],
            'atKey': {k: at_key[k] for k in ('presented', 'animationKeys', 'allAnimationKeys', 'panelOpacity')}, 'maxChannelDifference': diff, 'footer': opened['footer']}
        # (i) through its AX press: footer on, (i) gone (field +42 pt), no window.
        field_before = opened['fieldWidth']
        pressed = app.call('commandbar-press', control='info')
        shown = pressed['state']
        results['commandbar_info_shows_footer'] = {'ok': pressed['pressed'] and shown['footer'] and shown['presented'] and shown['fieldWidth'] - field_before == 42
            and visible() == windows_before and app.call('defaults', key=notice) is False, 'state': {k: shown[k] for k in ('footer', 'fieldWidth', 'presented')}}
        # "Dismiss": footer off, the Settings notice key set, remote suggestions allowed at once.
        dismissed = app.call('commandbar-press', control='dismiss')['state']
        results['commandbar_footer_dismiss'] = {'ok': not dismissed['footer'] and dismissed['presented'] and app.call('defaults', key=notice) is True
            and dismissed['allowsRemote'], 'state': {k: dismissed[k] for k in ('footer', 'allowsRemote', 'presented')}}
        # Esc: gone in the same turn, no animation key left behind.
        press('escape')
        closed = state()  # the next command after the key
        results['commandbar_no_close_animation'] = {'ok': not closed['presented'] and closed['hidden'] and closed['animationKeys'] == [], 'state': {k: closed[k] for k in ('presented', 'hidden', 'animationKeys')}}
        # A fresh Cmd+T never shows the footer by itself; Cmd+I (the real key path) does.
        reopened = bar('t')
        press('i', modifiers=['cmd'])
        by_key = wait_until(lambda: state() if state().get('footer') else None, timeout=3, step=.05)
        results['commandbar_cmd_i_footer'] = {'ok': not reopened['footer'] and bool(by_key) and visible() == windows_before, 'opened': reopened['footer']}
        # "Search Settings…": the bar closes; Settings ▸ Profiles for the bar's Profile.
        profile = state()['profile']
        app.call('commandbar-press', control='searchSettings')
        settings = wait_until(lambda: (lambda s: s if s['settings'] and s['pane'] == 'profiles' else None)(app.call('settings-state')), timeout=5, step=.05)
        results['commandbar_footer_search_settings'] = {'ok': bool(settings) and not state()['presented'] and settings['selectedProfile'] == profile,
            'settings': {k: settings[k] for k in ('pane', 'selectedProfile')} if settings else None, 'profile': profile}
        # The "Search Settings" action row sends a Space payload: still Profiles for the window's Profile
        # (main opened the General pane). Leave Profiles first so the row must switch back.
        app.call('settings-pane', pane='links')
        assert wait_until(lambda: app.call('settings-state')['pane'] == 'links', timeout=3, step=.05), app.call('settings-state')
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        bar('t')
        app.call('key', text='Search Settings')
        row = wait_until(lambda: (lambda s: s if s.get('final') and s['rows'] and s['rows'][0].get('action') == 'search-settings' else None)(state()), timeout=5, step=.05)
        press('return')
        via_row = wait_until(lambda: (lambda s: s if s['pane'] == 'profiles' and s['selectedProfile'] == profile and not state()['presented'] else None)(app.call('settings-state')), timeout=5, step=.05)
        results['commandbar_search_settings_action_row'] = {'ok': bool(row) and bool(via_row), 'row': row['rows'][0] if row else None,
            'settings': {k: via_row[k] for k in ('pane', 'selectedProfile')} if via_row else app.call('settings-state').get('pane')}
    finally:
        app.call('suggest-remote', enabled=False)
        app.call('defaults', key=notice, value=True)
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        app.call('select', tab=tab); app.call('focus', tab=tab)


RUN_NAME = re.compile(r"^Open-E2E-[a-z]+-(?:alloy|chrome)-(\d+)-[0-9a-f]{8}(?:-scratch-.*)?$")


def sweep_stale_runs():
    """Removes the folders of runs whose process is gone (a killed run never
    reaches its own cleanup). Only this harness's per-run names match; a live
    run of another agent is never touched."""
    bases = [os.path.expanduser("~/Library/Application Support"), os.path.expanduser("~/Library/Caches"),
             tempfile.gettempdir()]
    for base in bases:
        try:
            names = os.listdir(base)
        except OSError:
            continue
        for name in names:
            match = RUN_NAME.match(name)
            if not match:
                continue
            try:
                os.kill(int(match.group(1)), 0)
                continue  # still running
            except ProcessLookupError:
                pass
            except PermissionError:
                continue
            folder = os.path.join(base, name)
            subprocess.run(["chflags", "-R", "nouchg", folder], capture_output=True)
            subprocess.run(["chmod", "-R", "u+rwX", folder], capture_output=True)
            shutil.rmtree(folder, ignore_errors=True)


def space_manager_owned_processes(bundle):
    """Read executable identity, never match or terminate another Open build."""
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    rows = subprocess.check_output(['ps', '-axo', 'pid='], text=True).split()
    owned = []
    for raw in rows:
        path = ctypes.create_string_buffer(4096)
        pid = int(raw)
        if libproc.proc_pidpath(pid, path, len(path)) > 0:
            executable = os.path.realpath(os.fsdecode(path.value))
            if executable.startswith(os.path.realpath(bundle) + os.sep):
                owned.append(pid)
    return owned


def space_manager_owned_windows(pids):
    """Read on-screen metadata and retain only this suite's window records."""
    import plistlib
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
    cf.CFPropertyListCreateData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_ulong, ctypes.c_void_p]
    cf.CFPropertyListCreateData.restype = ctypes.c_void_p
    cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
    cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    info = cg.CGWindowListCopyWindowInfo(1 | 16, 0)
    if not info:
        raise RuntimeError('on-screen window metadata unavailable')
    data = None
    try:
        data = cf.CFPropertyListCreateData(None, info, 100, 0, None)
        if not data:
            raise RuntimeError('on-screen window metadata could not be decoded')
        rows = plistlib.loads(ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data)))
        return [{'pid': row['kCGWindowOwnerPID'], 'number': row['kCGWindowNumber']}
                for row in rows if row.get('kCGWindowOwnerPID') in pids]
    finally:
        if data: cf.CFRelease(data)
        cf.CFRelease(info)



def space_manager_engine_provenance(config):
    """Hash the actual embedded and recorded engine, without loading either."""
    framework = 'Chromium Embedded Framework.framework/Chromium Embedded Framework'
    embedded = Path(ROOT, 'build', config, 'Open.app/Contents/Frameworks', framework)
    recorded = Path(ROOT, 'Vendor/cef/Release', framework)
    def digest(path):
        value = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''): value.update(chunk)
        return value.hexdigest()
    stamp = Path(ROOT, 'Vendor/cef/.open-source').read_text().strip()
    embedded_hash, recorded_hash = digest(embedded), digest(recorded)
    signed_hash = recorded_hash
    if embedded_hash != recorded_hash:
        # embed-cef.sh re-signs the copied framework. Reproduce only that
        # existing signing step on an APFS clone; never change Vendor/cef.
        with tempfile.TemporaryDirectory(prefix='open-manager-engine-signature-') as directory:
            signed = Path(directory, 'Chromium Embedded Framework.framework')
            subprocess.run(['cp', '-cR', str(recorded.parent), str(signed)], check=True)
            for library in sorted((signed / 'Libraries').glob('*.dylib')):
                subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(library)], check=True, capture_output=True)
            subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(signed)], check=True, capture_output=True)
            signed_hash = digest(signed / 'Chromium Embedded Framework')
    return {'embeddedSHA256': embedded_hash, 'recordedSHA256': recorded_hash,
            'recordedAfterEmbedSigningSHA256': signed_hash,
            'expectedSHA256': os.environ.get('OPEN_SPACE_MANAGER_ENGINE_SHA256', ''),
            'suppliedProvenance': os.environ.get('OPEN_SPACE_MANAGER_ENGINE_PROVENANCE', ''),
            'signing': 'tools/embed-cef.sh ad-hoc signing reproduced on disposable clone when needed',
            'stamp': stamp}



def space_manager_route_checks(app, results, space, library_key, tmp):
    """Use real manager row keys, controls, menus, engine hosts and pasteboard."""
    def require(name, condition, **detail):
        results[name] = dict(detail, ok=bool(condition))
        if not condition: raise AssertionError(name)

    def row(tab):
        state = app.call('space-manager-state')
        return next(r for col in state['columns'] if col['id'] == space for r in col['rows'] if r['id'] == tab)

    def click_row(tab):
        point = row(tab)['point']
        app.call('mouse', action='click', window=app.call('space-manager-state')['window'], x=point[0], y=point[1])

    def click_control(tab, label, favicon=False):
        info = app.call('space-manager-row-controls', space=space, node=tab)
        x, y, width, height = info['frame']
        app.call('mouse', action='hover', window=app.call('space-manager-state')['window'],
                 x=x + 26 if favicon else x + width / 2, y=y + height / 2)
        control = wait_until(lambda: next((c for c in app.call('space-manager-row-controls', space=space, node=tab)['controls']
                                         if c['label'] == label), None), timeout=5)
        if not control: raise AssertionError('missing real row control ' + label + ': ' + json.dumps(app.call('space-manager-row-controls', space=space, node=tab)))
        app.call('mouse', action='click', window=app.call('space-manager-state')['window'], x=control['point'][0], y=control['point'][1])

    app.call('space', space=space)
    pinned_file = Path(tmp) / 'manager-pinned.html'
    pinned_file.write_text('<title>Manager Pinned Route</title><h1>Manager Pinned Route</h1>')
    pinned_url = pinned_file.as_uri()
    opened_pin = app.call('open', url=pinned_url)
    pin, pinned_url = opened_pin['id'], opened_pin['url']
    app.call('wait', tab=pin); app.call('pin', tab=pin)
    neighbor = app.call('open', url=fixture('Pinned Close Neighbor'))['id']
    app.call('wait', tab=neighbor); app.call('library-open'); click_row(pin)
    app.call('pasteboard-write', text='manager-copy-sentinel')
    app.call('space-manager-menu', space=space, node=pin, item='Copy Link')
    copied = app.call('pasteboard')
    # Record both regressions before stopping: old routing breaks both in one run.
    results['manager_copy_link_pasteboard'] = {'ok': copied == pinned_url, 'expected': pinned_url, 'actual': copied}
    library_key(app, 'down')  # Native keyboard focus starts at the first (pinned) row.
    library_key(app, 'delete')
    wait_until(lambda: any(t['id'] == pin and not t['hasWebContent'] for t in app.call('tabs')), timeout=2)
    retained = next((t for t in app.call('tabs') if t['id'] == pin), None)
    selected = app.call('window-state')['selected']
    app.call('menu-perform', id='view-archive')
    archive = app.call('settings-state')['archive']
    results['manager_pinned_delete_retains_pin'] = {'ok': bool(retained and retained['section'] == 'pinned'
        and not retained['hasWebContent'] and selected == neighbor and all(r['id'] != pin for r in archive)),
        'pin': retained, 'archive': archive, 'selected': selected, 'expectedNeighbor': neighbor}
    if not results['manager_copy_link_pasteboard']['ok'] or not results['manager_pinned_delete_retains_pin']['ok']:
        raise AssertionError('manager pinned close/Copy Link routing')
    app.call('library-open'); click_row(pin); app.call('wait', tab=pin)
    click_control(pin, 'Unload tab')
    unloaded = wait_until(lambda: not app.tab(pin)['hasWebContent'], timeout=5)
    require('manager_loaded_pin_unloads_host', unloaded and app.tab(pin)['section'] == 'pinned', tab=app.tab(pin))
    click_row(pin); app.call('wait', tab=pin)
    app.call('window-focus', id=app.call('window-state')['id'], activate=True)
    # Seed mute through the real browser command bar. Audibility is not needed to
    # use the enabled Unmute menu or prove that it reaches the actual host.
    app.call('key', key='t', modifiers=['cmd'], route='app')
    app.call('key', text='Mute All Tabs')
    mute_bar = wait_until(lambda: (lambda b: b if b.get('final') and any(r.get('action') == 'mute-all-tabs' for r in b.get('rows', [])) else None)(app.call('commandbar-state')), timeout=5)
    require('manager_mute_command_available', mute_bar, state=mute_bar)
    app.call('key', key='return', route='app')
    require('manager_mute_fixture_real_host', app.page(pin).get('muted') is True, page=app.page(pin))
    app.call('library-open'); app.call('space-manager-menu', space=space, node=pin, item='Unmute')
    require('manager_unmute_updates_real_host', app.page(pin).get('muted') is False, page=app.page(pin))
    changed_file = Path(tmp) / 'manager-navigated.html'
    changed_file.write_text('<title>Pinned Route Navigated</title><h1>Pinned Route Navigated</h1>')
    changed = changed_file.as_uri()
    app.call('navigate', tab=pin, url=changed); app.call('wait', tab=pin)
    require('manager_reset_fixture_navigated', app.eval(pin, 'document.title') == 'Pinned Route Navigated' and app.page(pin).get('url') == app.tab(pin)['url'], page=app.page(pin))
    app.call('library-open'); click_control(pin, 'Back to Pinned URL', favicon=True)
    reset = wait_until(lambda: app.page(pin).get('url') == pinned_url, timeout=5)
    require('manager_reset_updates_real_host', reset and app.tab(pin)['url'] == pinned_url, page=app.page(pin), tab=app.tab(pin))
    return pin


def sidebar_a1_checks(app, results, require, evidence):
    """Sidebar completion A1 in the real App (plan §5.4 E7, E8, E17, E19; §3.13 sound gate).
    Runs on a fresh preferences domain, so the first hide is the first ever."""
    def state(): return app.call('window-state')
    def key(name, mods=()): app.call('key', key=name, modifiers=list(mods), route='app')
    def settled(): wait_until(lambda: not app.call('window-motion')['active']['sidebar'], timeout=3, step=.01)
    def snap(name):
        path = os.path.join(evidence, name + '.png'); app.call('snapshot', path=path); return path
    browser = state()['id']
    app.call('window-focus', id=browser, activate=True)
    app.call('window-frame', frame=[40, 40, 1728, 1084], unconstrained=True)
    # E17: the first hide, by the toolbar button (a real click on its 32 pt frame).
    require('E17_hint_key_starts_false', app.call('defaults', key='open.sidebar.hideHintShown') in (None, False))
    toggle = state()['toolbarFrames']['toggle']
    app.call('mouse', action='click', x=toggle[0] + 16, y=toggle[1] + 16)
    hidden = wait_until(lambda: (lambda st: st if st['sidebarMode'] == 'hidden' and st['hint']['visible'] else None)(state()), timeout=3)
    width = state()['frame'][2]
    hint = (hidden or state())['hint']
    hint_png = snap('a1-hint')
    require('E17_first_hide_shows_hint', hidden and hint['shows'] == 1 and hint['keys'] == '⌘S'
            and abs(hint['frame'][0] + hint['frame'][2] - (width - 5)) < 0.5 and hint['frame'][1] == 4 and hint['frame'][3] == 47
            and app.call('defaults', key='open.sidebar.hideHintShown') is True, hint=hint, png=hint_png)
    settled(); key('s', ['cmd']); settled(); key('s', ['cmd']); settled()
    second = state()
    require('E17_second_hide_shows_nothing', second['sidebarMode'] == 'hidden' and second['hint']['shows'] == 1, hint=second['hint'])
    key('s', ['cmd']); settled()
    # E19: the resize gesture (real down/drag/up through OEApplication.sendEvent).
    def pointer(action, x): app.call('mouse', action=action, x=x, y=400); return state()
    before = state()
    pointer('down', before['sidebarWidth'])
    at150 = pointer('drag', 150)
    compact_png = snap('a1-compact-164')
    at60 = pointer('drag', 60)
    released = pointer('up', 60)
    require('E19_drag_stops_at_164_then_hides_while_pressed', at150['sidebarLiveWidth'] == 164 and at150['toolbarButtons'] == ['back', 'forward', 'more']
            and at60['sidebarMode'] == 'hidden' and at60['sidebarResizeActive'] and released['sidebarMode'] == 'hidden'
            and released['sidebarWidth'] == before['sidebarWidth'] and released['sidebarGestureHides'] == before['sidebarGestureHides'] + 1
            and released['hint']['shows'] == 1, at150=at150['toolbarButtons'], width=at150['sidebarLiveWidth'], png=compact_png)
    settled(); key('s', ['cmd']); settled()
    restored = state()
    require('E19_cmd_s_restores_pre_drag_width', restored['sidebarMode'] == 'anchored' and restored['sidebarLiveWidth'] == before['sidebarWidth'])
    pointer('down', restored['sidebarWidth']); pointer('drag', 200); at200 = pointer('up', 200)
    compact200 = snap('a1-compact-200')
    require('E19_compact_toolbar_at_200', at200['sidebarWidth'] == 200 and at200['toolbarButtons'] == ['back', 'forward', 'more']
            and at200['toolbarFrames']['more'] == [166, 9, 28, 28], toolbar=at200['toolbarFrames'], png=compact200)
    app.call('mouse', action='click', x=200, y=400, clickCount=1); app.call('mouse', action='click', x=200, y=400, clickCount=2)
    require('E19_double_click_resets_228', wait_until(lambda: state()['sidebarWidth'] == 228, timeout=3), width=state()['sidebarWidth'])
    # E7: Delete Space confirms first (Cancel changes nothing; Delete archives).
    doomed = app.call('space-create', title='Delete Me')
    app.call('space', space=doomed)
    doomed_tab = app.call('open', url=fixture('Doomed Space Tab'))['id']; app.call('wait', tab=doomed_tab)
    profile = app.tab(doomed_tab)['profile']
    archive_before = app.call('archive-list', profile=profile)['rows']
    spaces_before = [sp['id'] for sp in app.call('spaces')]
    app.call('sidebar-menu', item='Delete Space')
    sheet = wait_until(lambda: state()['confirmation'], timeout=3)
    texts = app.call('alert')
    app.call('alert', button='Cancel')
    cancelled = [sp['id'] for sp in app.call('spaces')] == spaces_before and state()['confirmation'] is None
    require('E7_delete_space_cancel', sheet and sheet['title'] == 'Delete your Delete Me Space?' and sheet['buttons'] == ['Delete', 'Cancel']
            and 'This will archive all the tabs and folders inside it.' in texts['texts'] and cancelled and app.call('archive-list', profile=profile)['rows'] == archive_before, sheet=sheet, texts=texts)
    app.call('sidebar-menu', item='Delete Space'); wait_until(lambda: state()['confirmation'], timeout=3)
    app.call('alert', button='Delete')
    deleted = wait_until(lambda: doomed not in [sp['id'] for sp in app.call('spaces')], timeout=3)
    require('E7_delete_space_confirmed', deleted and state()['confirmation'] is None, spaces=app.call('spaces'))
    archive_after = app.call('archive-list', profile=profile)['rows']
    require('E7_delete_space_archives_real_store', len(archive_after) == len(archive_before) + 1
            and any(r['id'] == doomed_tab and r['profile'] == profile for r in archive_after), archive=archive_after)
    # E8: Delete folder confirms first; the toast reads "Folder deleted"; Cmd+Z restores it.
    first_space = spaces_before[0]
    app.call('space', space=first_space)
    inner = app.call('open', url=fixture('Folder Child'))['id']; app.call('wait', tab=inner)
    folder = app.call('folder', tabs=[inner], title='Reading')
    app.call('sidebar-menu', node=folder, item='Delete')
    wait_until(lambda: state()['confirmation'], timeout=3)
    app.call('alert', button='Cancel')
    require('E8_delete_folder_cancel_keeps_it', state()['confirmation'] is None and any(t['id'] == inner for t in app.call('tabs')))
    app.call('sidebar-menu', node=folder, item='Delete')
    folder_sheet = wait_until(lambda: state()['confirmation'], timeout=3)
    app.call('alert', button='Delete Folder')
    gone = wait_until(lambda: all(t['id'] != inner for t in app.call('tabs')), timeout=3)
    toast = state()['toast']
    neighbor = state()['selected']
    pressed = app.call('toast-undo')
    back = wait_until(lambda: any(t['id'] == inner for t in app.call('tabs')), timeout=3)
    require('E8_delete_folder_alert_toast_undo', folder_sheet and folder_sheet['title'] == 'Delete your Reading folder?'
            and folder_sheet['buttons'] == ['Delete Folder', 'Cancel'] and gone and toast == 'Folder deleted' and back
            and neighbor not in (None, '', inner) and pressed, sheet=folder_sheet, toast=toast, selectedAfterDelete=neighbor)
    restored_sidebar = app.call('sidebar-tree')
    pressed_again = app.call('toast-undo')
    require('E8_delete_folder_toast_undo_single_use', back and not pressed_again
            and app.call('sidebar-tree') == restored_sidebar, pressedAgain=pressed_again)
    # Sound wiring (§3.13): the App resolves its own resources; the setting stays off by default.
    sound = app.call('sound-effect', effect='capture')
    require('A1_sound_effect_gated_off', sound['resource'] == 'open-capture.caf' and not sound['played'] and sound['plays'] == 0
            and app.call('defaults', key='open.advanced.playSoundEffects') in (None, False), sound=sound)


def sidebar_a2_checks(app, results, require, evidence, tmp):
    """Sidebar completion A2 in the real App (plan §5.4 E11–E14): page previews through the
    tab's own host, no reload on select, unread background tabs, Separate From Pinned Tab."""
    def state(): return app.call('window-state')
    def page(name):
        path = Path(tmp) / (name.replace(' ', '-').lower() + '.html')
        path.write_text('<title>%s</title><h1>%s</h1>' % (name, name)); return path.as_uri()
    def row(tab): return app.call('sidebar-row', node=tab)
    app.call('window-focus', id=state()['id'], activate=True)
    # A pinned tab that is not selected, and a current Today tab.
    pin = app.call('open', url=page('Preview Pinned'))['id']; app.call('wait', tab=pin); app.call('pin', tab=pin)
    current = app.call('open', url=page('Preview Current'))['id']; app.call('wait', tab=current)
    # E11: a real hover on the pinned row arms after 0.5 s and shows the page card.
    point = row(pin)['point']
    app.call('hover', node=pin, ms=600)
    shown = wait_until(lambda: (lambda st: st if st['kind'] == 'page' and st['target'] == pin else None)(app.call('preview-state')), timeout=3)
    require('E11_hover_pinned_shows_page_preview', shown and shown['host'] != '' and shown['card'][0] == state()['sidebarLiveWidth'] + 8,
            state=shown or app.call('preview-state'))
    app.call('snapshot', path=os.path.join(evidence, 'a2-page-preview.png'))
    app.call('mouse', action='hover', x=1200, y=600)
    gone = wait_until(lambda: app.call('preview-state')['kind'] == 'none', timeout=3)
    require('E11_leaving_hides_preview', gone, state=app.call('preview-state'))
    # E12: a page global set while the page shows in the card survives selecting the tab.
    point = row(pin)['point']
    app.call('mouse', action='hover', x=point[0], y=point[1])
    again = wait_until(lambda: (lambda st: st if st['kind'] == 'page' and st['target'] == pin else None)(app.call('preview-state')), timeout=3)
    app.call('eval', tab=pin, js='window.__peekProbe = 1')
    app.call('mouse', action='click', x=point[0], y=point[1])
    selected = wait_until(lambda: state()['selected'] == pin and app.call('preview-state')['kind'] == 'none', timeout=3)
    probe = app.call('eval', tab=pin, js='window.__peekProbe')
    require('E12_preview_host_survives_select', again and selected and probe == 1, probe=probe, state=again)
    # The non-sidebar Ctrl+Tab route must return the preview host before selection refresh.
    # MRU visits: pin was selected above, so current -> Ctrl+Tab targets pin.
    app.call('select', tab=current)
    point = row(pin)['point']
    app.call('mouse', action='hover', x=point[0], y=point[1])
    cycling = wait_until(lambda: (lambda st: st if st['kind'] == 'page' and st['target'] == pin else None)(app.call('preview-state')), timeout=3)
    app.call('eval', tab=pin, js='window.__cyclePreviewProbe = 12')
    hosts_before_cycle = app.call('host-counts')
    app.call('key', key='tab', modifiers=['ctrl'], route='app')
    pending_cycle = app.call('tab-switcher-state')
    pending_selection = state()['selected']
    app.call('key', key='control', modifiers=[], route='app')
    cycled = wait_until(lambda: state()['selected'] == pin and app.call('preview-state')['kind'] == 'none', timeout=3)
    cycle_probe = app.call('eval', tab=pin, js='window.__cyclePreviewProbe')
    hosts_after_cycle = app.call('host-counts')
    require('E12_preview_host_survives_ctrl_tab', cycling and cycled and cycle_probe == 12
            and pending_cycle['active'] and pending_cycle['selected'] == pin and pending_selection == current
            and hosts_after_cycle['created'] == hosts_before_cycle['created'],
            probe=cycle_probe, state=state(), preview=app.call('preview-state'), pending=pending_cycle,
            hostsBefore=hosts_before_cycle, hostsAfter=hosts_after_cycle)
    # E13: a background tab is unread until it is selected.
    background = app.call('open', url=page('Background Unread'), background=True)['id']
    unread = app.call('tab-state', tab=background)['unread']
    app.call('select', tab=background)
    read = wait_until(lambda: not app.call('tab-state', tab=background)['unread'], timeout=3)
    require('E13_background_tab_unread_until_selected', unread is True and read, tab=app.call('tab-state', tab=background))
    # E14: Separate From Pinned Tab (⌥-click on the reset plate) keeps the live page.
    sep = app.call('open', url=page('Separate Origin'))['id']; app.call('wait', tab=sep); app.call('pin', tab=sep)
    pinned_url = app.call('tab-state', tab=sep)['url']
    away_url = page('Separate Away')
    app.call('navigate', tab=sep, url=away_url)
    wait_until(lambda: (lambda t: t['url'].endswith('/separate-away.html') and not t['loading'])(app.call('tab-state', tab=sep)), timeout=5)
    app.call('wait', tab=sep)
    app.call('eval', tab=sep, js='window.__separateProbe = 7')
    require('E14_probe_set_on_navigated_page', app.call('eval', tab=sep, js='location.pathname.endsWith("separate-away.html") && window.__separateProbe') == 7)
    frame = row(sep)['frame']
    plate = [frame[0] + 26, frame[1] + 20]
    app.call('mouse', action='hover', x=plate[0], y=plate[1])
    page_before = app.call('tab-state', tab=sep)['page']
    hosts_before = app.call('host-counts')
    app.call('mouse', action='click', x=plate[0], y=plate[1], modifiers=['option'])
    separated = wait_until(lambda: (lambda st: st if st['selected'] not in ('', sep) else None)(state()), timeout=3)
    new_tab = separated['selected'] if separated else ''
    moved = app.call('eval', tab=new_tab, js='window.__separateProbe') if new_tab else None
    old = app.call('tab-state', tab=sep)
    new = app.call('tab-state', tab=new_tab) if new_tab else None
    require('E14_separate_keeps_live_page', separated and moved == 7 and old['section'] == 'pinned' and old['url'] == pinned_url
            and not old['hasWebContent'] and new['section'] == 'today' and new['selected'] and new['url'] == away_url
            and new['page']['url'] == away_url and new['page']['identifier'] == page_before['identifier'],
            probe=moved, pinned=old, newTab=new, pageBefore=page_before['identifier'],
            hostsBefore=hosts_before, hostsAfter=app.call('host-counts'), pages=[(p.get('url'), p.get('identifier')) for p in app.call('pages')])


def folder_peek_checks(factory, results, tmp):
    """E20: own-window real input, actual outline rows, save, same-root relaunch."""
    app = None
    def require(name, ok, **detail):
        results[name] = dict(detail, ok=bool(ok))
        if not ok:
            raise AssertionError(name)
    def motion_result(name, response, duration, curve):
        motion = response.get("motion", {})
        native = any(animation.get("path") == "position" and abs(animation.get("duration", 0) - duration) < .001
                     and len(animation.get("curve", [])) == 8
                     and all(abs(a-b) < .001 for a,b in zip(animation["curve"][2:6], curve))
                     for animation in motion.get("animations", []))
        samples = motion.get("samples", [])
        common = set.intersection(*(set(sample["rows"]) for sample in samples)) if samples else set()
        trajectories = [[sample["rows"][row] for sample in samples] for row in common]
        moving = any(max(values)-min(values) > 1 and abs(values[-1]-values[-2]) < .1 for values in trajectories)
        require(name, abs(motion.get("appliedDuration", 0)-duration) < .001 and native and moving, motion=motion)
    def state(folder):
        value = app.call("tabs", sidebar=True)
        row = next((f for f in value["folders"] if f["id"] == folder), {})
        return value, row
    def expected(folder, expanded, child, children):
        value, row = state(folder)
        visible = row.get("visibleChildren")
        ids = value["rows"]
        ok = (row.get("expanded") == expanded and row.get("peekedChildID") == child
              and visible == children and folder in ids)
        if children:
            i = ids.index(folder)
            ok = ok and ids[i+1:i+1+len(children)] == children
        return value if ok else None
    try:
        app = factory(urls=(), fresh=True)
        tabs = [app.call("open", url=fixture("Folder peek " + title), background=True)["id"] for title in ("A", "B", "C", "Today")]
        a, b, c, today = tabs
        folder = app.call("folder", tabs=[a, b, c], title="Folder peek E20", section="pinned")
        app.call("select", tab=b)
        require("E20_fixture_expanded", bool(wait_until(lambda: expected(folder, True, "", [a, b, c]), timeout=5, step=.02)))
        motion = app.call("sidebar-click", node=folder, motion=True)
        motion_result("E20_collapse_motion_receipt", motion, .25, [.25,.1,.25,1])
        value = wait_until(lambda: expected(folder, False, b, [b]), timeout=5, step=.02)
        require("E20_collapse_keeps_selected_child", bool(value) and any(t["id"] == b and t["selected"] for t in value["tabs"])
                and a not in value["rows"] and c not in value["rows"] and set(tabs) <= {t["id"] for t in value["tabs"]}
                and check_page(app, b, "Folder peek B"))
        app.call("select", tab=today)
        value = wait_until(lambda: expected(folder, False, b, [b]), timeout=5, step=.02)
        require("E20_other_selection_keeps_peek", bool(value) and any(t["id"] == today and t["selected"] for t in value["tabs"])
                and check_page(app, today, "Folder peek Today"))
        frame = app.call("sidebar-row", node=folder)["frame"]
        app.call("mouse", action="hover", x=frame[0] + frame[2] - 26, y=frame[1] + 20)
        before_unload = app.call("tabs", sidebar=True)  # settle the real hover accessory layout
        require("E20_Q18_loaded_fixture", any(tab["id"] == b and tab["loaded"] for tab in before_unload["tabs"]))
        app.call("mouse", action="click", x=frame[0] + frame[2] - 26, y=frame[1] + 20)
        unloaded = wait_until(lambda: (lambda v: v if all(not tab["loaded"] for tab in v["tabs"] if tab["id"] in [a,b,c]) else None)(app.call("tabs", sidebar=True)), timeout=5, step=.02)
        require("E20_Q18_pinned_folder_unloads", bool(unloaded) and bool(expected(folder, False, b, [b]))
                and set(tabs) <= {t["id"] for t in unloaded["tabs"]})
        results["E20_real_window_snapshot"] = {"ok": True, "file": shot(app, "E20-folder-peek.png", max_px=1728)}
        saved = json.load(open(app.call("save")))
        def find(value):
            if isinstance(value, dict):
                if value.get("id") == folder and "children" in value: return value
                for v in value.values():
                    found = find(v)
                    if found: return found
            if isinstance(value, list):
                for v in value:
                    found = find(v)
                    if found: return found
            return None
        record = find(saved)
        require("E20_snapshot_persists_peek", record is not None and record["isExpanded"] is False and record.get("peekedChildID") == b)
        app.quit()
        app = factory(urls=(), fresh=False)
        value = wait_until(lambda: expected(folder, False, b, [b]), timeout=8, step=.02)
        require("E20_relaunch_keeps_peek", bool(value) and set(tabs) <= {t["id"] for t in value["tabs"]}
                and any(t["id"] == today and t["selected"] for t in value["tabs"]))
        collapse = app.call("sidebar-click", node=folder, motion=True)
        motion_result("E20_full_collapse_motion_receipt", collapse, .25, [.25,.1,.25,1])
        value = wait_until(lambda: expected(folder, False, "", []), timeout=5, step=.02)
        require("E20_click_peek_fully_collapses", bool(value) and set(tabs) <= {t["id"] for t in value["tabs"]})
        expand = app.call("sidebar-click", node=folder, motion=True)
        motion_result("E20_expand_motion_receipt", expand, .20, [0,0,.58,1])
        require("E20_reexpand_all_children", bool(wait_until(lambda: expected(folder, True, "", [a, b, c]), timeout=5, step=.02)))
        app.call("sidebar-click", node=folder)
        require("E20_collapse_elsewhere_no_peek", bool(wait_until(lambda: expected(folder, False, "", []), timeout=5, step=.02)))
        empty = app.call("folder", tabs=[], title="Empty peek E20", section="pinned")
        app.call("sidebar-click", node=empty)
        require("E20_empty_folder_collapses", bool(wait_until(lambda: expected(empty, False, "", []), timeout=5, step=.02)))
        app.call("sidebar-click", node=empty)
        require("E20_empty_folder_reexpands", bool(wait_until(lambda: expected(empty, True, "", []), timeout=5, step=.02)))
        # Q18 must select the sidebar split node, rather than its first flattened
        # tab. Exercise the engine-backed hover button as well as the feature flow.
        first_outside = next(tab["id"] for tab in app.call("tabs") if tab["id"] not in [a,b,c])
        app.call("select", tab=first_outside)
        outside = app.call("split")
        pane_ids = {tab["id"] for tab in outside}
        tree = app.call("sidebar-tree")
        split = next(node for node in tree["pinned"] + tree["today"] if node["kind"] == "split"
                     and {child["id"] for child in node["children"]} == pane_ids)
        app.call("select", tab=b)
        app.call("wait", tab=b)
        for _ in range(3):
            if state(folder)[1]["expanded"]:
                break
            app.call("sidebar-click", node=folder)
        app.call("sidebar-click", node=folder)
        fixture_value = wait_until(lambda: expected(folder, False, b, [b]), timeout=5, step=.02)
        require("E20_Q18_split_fallback_fixture", len(pane_ids) == 2 and first_outside in pane_ids
                and bool(fixture_value) and fixture_value["selectedNode"] == b
                and any(tab["id"] == b and tab["loaded"] for tab in fixture_value["tabs"]))
        frame = app.call("sidebar-row", node=folder)["frame"]
        app.call("mouse", action="hover", x=frame[0] + frame[2] - 26, y=frame[1] + 20)
        app.call("tabs", sidebar=True)
        app.call("mouse", action="click", x=frame[0] + frame[2] - 26, y=frame[1] + 20)
        last_fallback = {}
        def split_fallback_ready():
            nonlocal last_fallback
            value = app.call("tabs", sidebar=True)
            row = app.call("sidebar-row", node=split["id"])
            enabled = next((item["enabled"] for item in app.call("menu-state") if item["id"] == "expand-current-split"), False)
            visible = {tab["id"] for tab in value["tabs"] if tab["visible"]}
            unloaded = all(not tab["loaded"] for tab in value["tabs"] if tab["id"] in [a,b,c])
            last_fallback = dict(selected=value["selectedNode"], visible=sorted(visible),
                                 current=row["current"], splitCommand=enabled, unloaded=unloaded)
            return last_fallback if (value["selectedNode"] == split["id"] and visible == pane_ids
                                    and row["current"] and enabled and unloaded) else None
        fallback = wait_until(split_fallback_ready, timeout=5, step=.02)
        require("E20_Q18_unload_fallback_to_split", bool(fallback), split=split["id"], state=last_fallback)
        # Persist fully collapsed state, then use only a real click after relaunch.
        # A structural edit or explicit folder-child query could mask a missing cache.
        app.call("sidebar-click", node=folder)
        require("E20_collapsed_load_saved_fixture", bool(wait_until(lambda: expected(folder, False, "", []), timeout=5, step=.02)))
        app.call("save")
        app.quit()
        app = factory(urls=(), fresh=False)
        require("E20_collapsed_load_relaunch_fixture", bool(wait_until(lambda: expected(folder, False, "", []), timeout=8, step=.02)))
        click_result = app.call("sidebar-click", node=folder)
        expanded = wait_until(lambda: expected(folder, True, "", [a,b,c]), timeout=5, step=.02)
        actual, row = state(folder)
        require("E20_collapsed_load_real_click_expands", bool(expanded), click=click_result,
                folder=row, rows=actual["rows"], expectedChildren=[a,b,c])


    finally:
        if app:
            app.quit()


def sidebar_completion_archive_checks(app, launch, results, require, evidence, tmp):
    """E16/AA_APP: real scheduler, advancing fake clock, Settings, and SQLite."""
    import datetime

    def iso(seconds):
        return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

    def state(): return app.call('archive-state')
    def rows(profile): return app.call('archive-list', profile=profile, limit=1000)
    def contains(tab): return any(t['id'] == tab for t in app.call('tabs'))
    def setting(profile, interval, scope='profile'):
        return app.call('profile-archive-setting', profile=profile, interval=interval, scope=scope)
    def create(name, background=True):
        return app.call('open', url=fixture(name), background=background)['id']
    def fixture_profile(space):
        with open(app.call('save')) as stream: snapshot = json.load(stream)
        return next(s['profileID'] for s in snapshot['spaces'] if s['id'] == space)
    def relaunch_aged(tab, age):
        path = app.call('save'); app.quit()
        with open(path) as stream: snapshot = json.load(stream)
        found = []
        def visit(value):
            if isinstance(value, dict):
                if value.get('id') == tab and 'lastActiveAt' in value:
                    value['lastActiveAt'] = time.time() - age; found.append(tab)
                for item in value.values(): visit(item)
            elif isinstance(value, list):
                for item in value: visit(item)
        visit(snapshot)
        if found != [tab]: raise AssertionError('expected one owned fixture TabDTO')
        with open(path, 'w') as stream: json.dump(snapshot, stream)
        return launch()

    app.call('library-close')
    # This suite tests the archive Settings link, not the separate suggestions notice.
    app.call('defaults', key='open.general.searchSuggestNoticeDismissed', value=True)
    app.call('archive-clock', reset=True)
    with open(app.call('save')) as stream: initial = json.load(stream)
    first_profile = initial['profiles'][0]['id']
    setting(first_profile, 'never', scope='all')
    space = app.call('space-create', title='Archive Today', profile='Archive Today')
    profile = fixture_profile(space)
    old = create('Auto Archive Old')
    pin = create('Auto Archive Pinned', background=False); app.call('pin', tab=pin)
    favorite = create('Auto Archive Favorite')
    app.call('favorite', tab=favorite)
    # The selected Today tab and an unselected Today tab are both past threshold.
    # Only the unselected tab may archive. Pinned/Favorite controls also survive.
    visible = create('Auto Archive Visible Today', background=False)
    before = rows(profile)['count']; activity = max(app.tab(old)['lastActiveAt'], app.tab(visible)['lastActiveAt'])
    sweep = app.call('archive-sweep', now=iso(activity + 13*3600))
    archived = rows(profile)
    exact = [r for r in archived['rows'] if r['id'] == old]
    again = app.call('archive-sweep')
    require('E16_fake_clock_sweep_archives_today', not contains(old) and contains(visible) and contains(pin) and contains(favorite)
            and app.call('window-state')['selected'] == visible and sweep['armedTimerCount'] == 0 and sweep['nextExpiry'] is None
            and archived['count'] == before + 1 and len(exact) == 1 and exact[0]['reason'] == 'autoArchived'
            and exact[0]['profile'] == profile and exact[0]['space'] == space and rows(profile)['count'] == archived['count']
            and sweep['lastReason'] == 'automation' and sweep['lastSweep']['affectedSpaces'] == [space]
            and again['lastSweep']['archivedCount'] == 0 and all(r['id'] != visible for r in archived['rows']),
            state=sweep, archive=archived, selectedToday=app.tab(visible))
    banner = app.call('archive-banner-state')
    png = os.path.join(evidence, 'e16-autoarchive-banner.png'); app.call('snapshot', path=png)
    require('E16_auto_archive_banner_visible', banner['visible'] and banner['title'] == 'We cleaned up!'
            and banner['threshold'] == '12 hours' and not banner['dismissed'], banner=banner, snapshot=png)
    first = app.call('window-state')['id']
    app.call('menu-perform', id='new-window')
    second = next(w['id'] for w in app.call('shell-windows') if w['id'] != first)
    second_banner = app.call('archive-banner-state', window=second)
    app.call('archive-banner-action', action='got-it', window=first)
    require('E16_got_it_hides_all_windows', second_banner['visible']
            and all(not app.call('archive-banner-state', window=w['id'])['visible'] for w in app.call('shell-windows'))
            and app.call('defaults', key='open.sidebar.autoArchiveBannerDismissed') is True)
    app.call('archive-clock', reset=True); app.call('save'); app.quit(); app = launch()
    app.call('space', space=space)
    fresh = create('Dismissed Relaunch Fixture'); activity = app.tab(fresh)['lastActiveAt']
    reset_state = state(); app.call('archive-sweep', now=iso(activity + 13*3600))
    require('E16_dismissal_survives_relaunch', reset_state['offsetSeconds'] == 0 and not contains(fresh)
            and not app.call('archive-banner-state')['visible']
            and app.call('defaults', key='open.sidebar.autoArchiveBannerDismissed') is True, state=state())

    # Separate fixture setup for the real Settings link; never reset dismissal inside the relaunch proof.
    app.call('archive-clock', reset=True)
    app.call('defaults', key='open.sidebar.autoArchiveBannerDismissed', value=False)
    setting(first_profile, 'never')  # selects Profile A in the shared Settings model.
    fresh = create('Settings Link Fixture'); activity = app.tab(fresh)['lastActiveAt']
    app.call('archive-sweep', now=iso(activity + 13*3600))
    app.call('archive-banner-action', action='settings')
    settings = app.call('settings-state')
    require('E16_settings_link_opens_correct_profile', settings['pane'] == 'profiles' and settings['selectedProfile'] == profile
            and settings['settings'] > 0 and app.call('defaults', key='open.sidebar.autoArchiveBannerDismissed') is True
            and all(not app.call('archive-banner-state', window=w['id'])['visible'] for w in app.call('shell-windows')), settings=settings)
    # Close only the Settings window using Open's own window event path.
    app.call('key', key='w', modifiers=['cmd'], route='app', window=settings['settings'])
    app.call('window-focus', id=app.call('window-state')['id'], activate=True)
    app.call('archive-clock', reset=True)
    timed = create('Natural Timer Fixture'); activity = app.tab(timed)['lastActiveAt']
    timer_before = state()['countsByReason'].get('timer', 0)
    armed = app.call('archive-clock', now=iso(activity + 12*3600 - .2))
    expired = wait_until(lambda: not contains(timed), timeout=4)
    timer_state = state(); timer_rows = rows(profile)
    require('AA_APP_timer_callback_not_manual_sweep', expired and armed['armedTimerCount'] == 1
            and timer_state['countsByReason'].get('timer', 0) == timer_before + 1 and timer_state['lastReason'] == 'timer'
            and timer_state['armedTimerCount'] == 0 and any(r['id'] == timed for r in timer_rows['rows']), state=timer_state)
    app.call('archive-clock', reset=True)
    wake = create('Wake Fixture'); activity = app.tab(wake)['lastActiveAt']
    wake_before = state()['countsByReason'].get('wake', 0)
    woke = app.call('archive-wake', now=iso(activity + 13*3600))
    require('AA_APP_wake_notification', not contains(wake) and woke['countsByReason'].get('wake', 0) == wake_before + 1
            and woke['lastReason'] == 'wake' and any(r['id'] == wake for r in rows(profile)['rows']), state=woke)
    app.call('archive-clock', reset=True)
    launch_tab = create('Launch Overdue Fixture'); app.call('select', tab=pin)
    app = relaunch_aged(launch_tab, 13*3600); app.call('space', space=space)
    launch_state = state(); launch_rows = [r for r in rows(profile)['rows'] if r['id'] == launch_tab]
    archived_at = datetime.datetime.fromisoformat(launch_rows[0]['archivedAt'].replace('Z', '+00:00')).timestamp() if launch_rows else 0
    require('AA_APP_launch_overdue_snapshot', not contains(launch_tab) and launch_state['offsetSeconds'] == 0
            and launch_state['countsByReason'].get('launch') == 1 and len(launch_rows) == 1
            and abs(archived_at - time.time()) < 30, state=launch_state, rows=launch_rows)
    change = create('Settings Two Hour Fixture'); app.call('select', tab=pin)
    app = relaunch_aged(change, 2*3600); app.call('space', space=space)
    change_before = state(); setting(profile, 'oneHour')
    changed = wait_until(lambda: not contains(change), timeout=4)
    never_space = app.call('space-create', title='Never Archive', profile='Never Archive')
    never_profile = fixture_profile(never_space); setting(never_profile, 'never')
    never = create('Never Fixture'); never_count = rows(never_profile)['count']
    setting(profile, 'never')
    app.call('archive-sweep', now=iso(app.tab(never)['lastActiveAt'] + 31*86400))
    never_state = state()
    require('AA_APP_threshold_change_and_never', changed and change_before['armedTimerCount'] == 1
            and any(r['id'] == change for r in rows(profile)['rows']) and contains(never)
            and rows(never_profile)['count'] == never_count and never_state['armedTimerCount'] == 0, state=never_state)
    invalid_before = state(); errors = []
    for command, args in [('archive-clock', {'now': 'not-a-date'}), ('archive-clock', {'now': iso(time.time()), 'reset': True}),
                          ('archive-clock', {'reset': False}), ('archive-clock', {'offsetSeconds': True}),
                          ('profile-archive-setting', {'profile': profile, 'interval': 'invalid', 'scope': 'all'})]:
        try: app.call(command, **args)
        except RuntimeError as error: errors.append(str(error))
    invalid_after = state()
    require('AA_APP_invalid_clock_refused', len(errors) == 5 and all(invalid_before[k] == invalid_after[k]
            for k in ['offsetSeconds', 'timerGeneration', 'sweepCount', 'nextExpiry']), errors=errors, state=invalid_after)
    app.call('archive-clock', reset=True)
    # Verify all-Profile scope, then restore Never before the idle interval.
    all_profiles = setting(never_profile, 'thirtyDays', scope='all')
    all_state = state()
    all_never = setting(never_profile, 'never', scope='all')
    require('AA_APP_all_profile_scope_rearms', all(p['interval'] == 'thirtyDays' for p in all_profiles['profiles'])
            and all_state['armedTimerCount'] == 1 and all_never['state']['armedTimerCount'] == 0,
            profiles=all_profiles['profiles'], farState=all_state)
    # No browser page needs to run JavaScript during the idle sample.
    for window in list(app.call('shell-windows')):
        app.call('window-focus', id=window['id']); app.call('window-close', releaseBrowsers=True)
    time.sleep(1)  # Let own-page teardown and the final debounced save finish.
    snapshot_path = app.call('save')
    saved_before = os.stat(snapshot_path).st_mtime_ns
    idle_before = state()
    metrics = app.call('metrics', interval=1)
    # archive-state must remain available without opening a browser.
    time.sleep(.35)
    idle_after = state()
    saved_after = os.stat(snapshot_path).st_mtime_ns
    require('AA_APP_idle_no_sweep_growth', idle_before['armedTimerCount'] == 0 and idle_after['armedTimerCount'] == 0
            and idle_before['sweepCount'] == idle_after['sweepCount'] and app.call('shell-windows') == []
            and saved_before == saved_after,
            before=idle_before, after=idle_after, metrics=metrics,
            snapshotMtimeBefore=saved_before, snapshotMtimeAfter=saved_after)
    with open(os.path.join(evidence, 'autoarchive-idle.json'), 'w') as stream:
        json.dump({'before': idle_before, 'after': idle_after, 'metrics': metrics,
                   'snapshotMtimeBefore': saved_before, 'snapshotMtimeAfter': saved_after}, stream, indent=2)
    return app


def sidebar_completion_a3_checks(app, results, require, evidence, tmp, launch):
    """Real sidebar/menu/event flows for Part B. E16 belongs to the sweeper lane.
    sidebar-drop covers the shared production intent, not an OS drag session."""
    def state(): return app.call('window-state')
    def tree(): return app.call('sidebar-tree')
    def roots(section): return [n['id'] for n in tree()[section]]
    def walk(nodes):
        return [value for node in nodes for value in [node] + walk(node.get('children', []))]
    def shape(nodes):
        return [(n['id'], n['kind'], shape(n.get('children', []))) for n in nodes]
    def selection(): return app.call('selection')
    def click(node, mods=()): return app.call('sidebar-click', node=node, modifiers=list(mods))
    def key(name, mods=()): return app.call('sidebar-key', key=name, modifiers=list(mods))
    def undo(): return key('z', ['cmd'])
    def select(ids):
        click(ids[0])
        for node in ids[1:]: click(node, ['cmd'])
    def page(name):
        path = Path(tmp) / ('a3-' + name.lower().replace(' ', '-') + '.html')
        path.write_text('<title>%s</title><h1>%s</h1>' % (name, name)); return path.as_uri()
    def opened(name, pinned=False):
        node = app.call('open', url=page(name))['id']; app.call('wait', tab=node)
        if pinned: app.call('pin', tab=node)
        return node
    def fresh(name):
        space = app.call('space-create', title='A3 ' + name); app.call('space', space=space)
        return space
    def menu_enabled(name):
        return next(row['enabled'] for row in app.call('menu-state') if row['id'] == name)
    def drop(ids, kind, target, index): return app.call('sidebar-drop', nodes=ids, parent=dict(kind=kind, id=target), index=index)
    def finish_rename():
        app.call('key', key='escape', route='app'); key('escape')
    def refused(cmd, **args):
        try: app.call(cmd, **args)
        except RuntimeError: return True
        return False

    app.call('library-close')
    app.call('window-focus', id=state()['id'], activate=True)
    space = fresh('Selection')
    pins = [opened('Pinned %d' % i, True) for i in range(2)]
    hidden = opened('Collapsed Child')
    collapsed = app.call('folder', tabs=[hidden], title='Collapsed', section='pinned')
    # A selected direct child now produces a persistent peek. This range fixture
    # needs a fully collapsed folder, so select an outside tab before collapsing.
    app.call('select', tab=pins[0])
    app.call('folder-toggle', folder=collapsed)
    control = opened('Unselected Control')
    for i in range(3): opened('Selection %d' % i)
    abc = [n for n in roots('today') if n != control]; a, b, c = abc
    first_click = click(a); second_click = click(b, ['cmd'])
    ordered = selection(); click(b, ['cmd']); toggled = selection()
    require('E1_cmd_click_order', ordered == [a, b] and toggled == [a], selection=ordered, toggled=toggled, expected=[a, b], clicks=[first_click, second_click])
    click(a); click(c, ['shift'])
    require('E1_shift_click_visible_range', selection() == abc and hidden not in selection(), selection=selection(), expected=abc)
    visible_order = roots('pinned') + roots('today'); click(pins[0]); click(c, ['shift'])
    require('E1_range_crosses_sections_skips_collapsed_children', selection() == visible_order[visible_order.index(pins[0]):visible_order.index(c) + 1] and hidden not in selection(), selection=selection())
    click(a); before = state()['selected']; key('down', ['shift']); down = selection(); key('up', ['shift']); key('escape')
    require('E1_keyboard_extend_and_escape', down == [a, b] and selection() == [] and state()['selected'] == before, down=down)
    select(abc); click(b)
    require('E1_plain_click_clears_selection', selection() == [] and state()['selected'] == b)
    before_invalid = tree()
    require('A3_input_rejects_missing_targets', refused('sidebar-click', node='invalid') and refused('hover', node=hidden, ms=0)
            and refused('sidebar-menu', node='invalid', item='Delete') and refused('hover', node=a, ms=5001)
            and refused('library-open', section='missing') and tree() == before_invalid)
    require('A3_selection_window_read', app.call('selection', window=state()['id']) == selection())
    # E2: native selected-row menu and both registry entries group the selection.
    before = shape(tree()['today']); select(abc)
    app.call('sidebar-menu', node=b, item='New Folder with 3 Items'); finish_rename()
    folder = next(n for n in tree()['today'] if n['kind'] == 'folder')
    require('E2_selection_folder_exact_ids', [n['id'] for n in folder['children']] == abc and selection() == [], folder=folder)
    app.call('sidebar-menu', node=folder['id'], item='Copy All Links')
    copied_folder = app.call('pasteboard')
    click(a); click(folder['id'], ['cmd'])
    app.call('sidebar-menu', node=a, item='Copy Links'); copied_overlap = app.call('pasteboard')
    before_refusal = tree(); overlap_selection = selection()
    expected_copy = '\n'.join(app.tab(n)['url'] for n in abc)
    ancestor_refused = refused('sidebar-menu', node=a, item='Move to/New Space…')
    require('A3_copy_folder_deduplicates_descendants', copied_folder == copied_overlap == expected_copy
            and ancestor_refused and tree() == before_refusal, folderCopy=copied_folder, selectionCopy=copied_overlap,
            expected=expected_copy, selection=overlap_selection, refused=ancestor_refused, before=before_refusal, after=tree())
    key('escape'); undo_before = app.call('space-manager-state')['modelUndoCount']; undo_route = undo()
    require('E2_folder_one_undo', shape(tree()['today']) == before, tree=tree(), expected=before, route=undo_route, focus=app.call('focus-state'), undoBefore=undo_before, undoAfter=app.call('space-manager-state')['modelUndoCount'])
    variants = []
    for mode in ('menu', 'key'):
        select(abc)
        if mode == 'menu': app.call('command', id='new-folder')
        else: key('n', ['cmd', 'shift'])
        finish_rename()
        grouped = next(n for n in tree()['today'] if n['kind'] == 'folder')
        variants.append([n['id'] for n in grouped['children']] == abc)
        undo(); variants.append(shape(tree()['today']) == before)
    require('E2_menu_and_key_use_selection', all(variants), variants=variants)
    select(abc); app.call('command', id='rename-tab')
    editor = wait_until(lambda: (lambda f: f if f['owner'] == 'sidebar' and 'Text' in f['responder'] else None)(app.call('focus-state')), timeout=3)
    editing_tree = tree(); app.call('key', key='delete', route='app')
    delete_safe = tree() == editing_tree and state()['confirmation'] is None
    pinned_before = set(roots('pinned')); app.call('command', id='new-folder')
    new_empty = [n for n in tree()['pinned'] if n['id'] not in pinned_before]
    stale_safe = len(new_empty) == 1 and new_empty[0]['kind'] == 'folder' and new_empty[0]['children'] == [] and roots('today') == abc + [control]
    finish_rename(); undo()
    require('A3_text_editor_keeps_delete_and_does_not_group_stale_selection', editor and delete_safe and stale_safe, editor=editor)
    # E3: selection commands traverse the App router, and the real engine strip.
    select(abc); key('d', ['cmd'])
    require('E3_cmd_d_pins_entire_selection', all(app.tab(n)['section'] == 'pinned' for n in abc) and app.tab(control)['section'] == 'today', tree=tree())
    flags = [r for strip in app.call('tab-strip') for r in strip['pinStates']]
    require('E3_engine_pin_flags_follow', all(any(r['id'] == n and r['pinned'] for r in flags) for n in abc), flags=flags)
    key('d', ['cmd'])
    unpinned = all(app.tab(n)['section'] == 'today' for n in abc)
    before_dup = shape(tree()['today']); ids_before = {n['id'] for n in walk(tree()['today'])}
    app.call('command', id='duplicate-tab'); ids_after = {n['id'] for n in walk(tree()['today'])}
    undo()
    require('E3_unpin_and_menu_duplicate_selection', unpinned and len(ids_after - ids_before) == 3 and shape(tree()['today']) == before_dup,
            newIDs=sorted(ids_after - ids_before), tree=tree())
    select(abc); app.call('sidebar-menu', node=a, item='Pin Tabs')
    menu_pinned = all(app.tab(n)['section'] == 'pinned' for n in abc)
    app.call('sidebar-menu', node=a, item='Unpin Tabs')
    before_context_dup = shape(tree()['today']); ids_before = {n['id'] for n in walk(tree()['today'])}
    app.call('sidebar-menu', node=a, item='Duplicate'); ids_after = {n['id'] for n in walk(tree()['today'])}; undo()
    require('A3_selection_context_pin_duplicate', menu_pinned and all(app.tab(n)['section'] == 'today' for n in abc)
            and len(ids_after - ids_before) == 3 and shape(tree()['today']) == before_context_dup)
    # A refused folder-only pin selection must not toggle the active page.
    click(a); click(collapsed, ['cmd']); click(a, ['cmd']); pin_before = app.tab(pins[0])['section']
    require('A3_folder_selection_pin_disabled', not menu_enabled('pin-unpin-tab') and refused('command', id='pin-unpin-tab')
            and app.tab(pins[0])['section'] == pin_before)
    # Copy plain/Markdown and both move variants use real selection menus.
    select(abc)
    app.call('sidebar-menu', node=a, item='Copy Links'); plain = app.call('pasteboard')
    app.call('sidebar-menu', node=a, item='Copy links as Markdown'); markdown = app.call('pasteboard')
    require('A3_selection_copy_links', plain.splitlines() == [app.tab(n)['url'] for n in abc]
            and markdown.splitlines() == ['[%s](%s)' % (app.tab(n)['title'], app.tab(n)['url']) for n in abc])
    dest = fresh('Move Destination'); app.call('space', space=space); select(abc)
    app.call('sidebar-menu', node=a, item='Move to/A3 Move Destination')
    app.call('space', space=dest)
    require('A3_move_existing_space_order_unread', roots('today') == abc and all(app.tab(n)['unread'] for n in abc), tree=tree())
    undo(); app.call('space', space=space); select(abc); spaces_before = len(app.call('spaces'))
    app.call('sidebar-menu', node=a, item='Move to/New Space…')
    require('A3_move_new_space_atomic', len(app.call('spaces')) == spaces_before + 1 and roots('pinned') == abc and roots('today') == [] and selection() == [], tree=tree(), selection=selection())
    undo(); app.call('space', space=space)
    require('A3_move_new_space_one_undo', len(app.call('spaces')) == spaces_before and roots('today') == abc + [control])
    # E4: noncontiguous move, same-parent pre-removal index, invalid descendant.
    move_space = fresh('Drop')
    for i in range(6): opened('Drop %d' % i)
    six = roots('today'); moved = six[1::2]
    target = app.call('folder-create', title='Drop Destination'); before = tree(); select(moved)
    accepted = drop(moved, 'folder', target, 0); after = tree()
    require('E4_drop_selection_keeps_order', accepted and roots('today') == six[::2]
            and [n['id'] for n in next(n for n in after['pinned'] if n['id'] == target)['children']] == moved, tree=after)
    undo(); restored = shape(tree()['today']) == shape(before['today']) and shape(tree()['pinned']) == shape(before['pinned'])
    select(moved); accepted = drop(moved, 'today', move_space, len(six))
    require('E4_same_parent_drop_index', restored and accepted and roots('today') == six[::2] + moved, tree=tree())
    undo()
    nested = app.call('folder-create', title='Nested Drop'); drop([nested], 'folder', target, 0)
    invalid_before = tree(); accepted = drop([target], 'folder', nested, 0)
    invalid_unchanged = tree() == invalid_before; undo()
    require('E4_invalid_drop_no_mutation', not accepted and invalid_unchanged and any(n['id'] == nested for n in tree()['pinned']), tree=tree())
    # E9: recursive folder state and host/path reset, including a split pane.
    reset_space = fresh('Reset')
    base = opened('Reset Base', True); partner = opened('Reset Partner', True)
    folder = app.call('folder', tabs=[base], title='Reset Folder', section='pinned')
    nested = app.call('folder-create', title='Reset Nested'); drop([nested], 'folder', folder, 0)
    today_folder = app.call('folder', title='Today Folder')
    app.call('folder-toggle', folder=nested)
    can_expand = menu_enabled('expand-all-folders'); app.call('command', id='expand-all-folders')
    expanded = all(n['expanded'] for n in walk(tree()['pinned'] + tree()['today']) if n['kind'] == 'folder')
    expand_disabled = not menu_enabled('expand-all-folders'); app.call('command', id='collapse-all-folders')
    collapsed_all = all(not n['expanded'] for n in walk(tree()['pinned'] + tree()['today']) if n['kind'] == 'folder')
    require('E9_expand_collapse_recursive_enablement', can_expand and expanded and expand_disabled and collapsed_all and not menu_enabled('collapse-all-folders'))
    app.call('command', id='expand-all-folders')
    split_other = opened('Reset Split Other')
    app.call('select', tab=partner); app.call('sidebar-menu', node=split_other, item='Open in Split View')
    split_node = next(n for n in tree()['today'] if n['kind'] == 'split')
    assert drop([split_node['id']], 'pinned', reset_space, 0), 'cannot pin Reset split fixture'
    favorite = opened('Reset Favorite'); app.call('favorite', tab=favorite)
    other_space = fresh('Reset Other Space'); other = opened('Reset Untouched', True)
    other_away = page('Reset Untouched Away'); app.call('navigate', tab=other, url=other_away); app.call('wait', tab=other)
    app.call('space', space=reset_space)
    originals = {n: app.tab(n)['url'] for n in (base, partner, split_other)}
    for n in (*originals, favorite):
        app.call('select', tab=n); app.call('navigate', tab=n, url=page('Reset Away ' + n)); app.call('wait', tab=n)
    favorite_away = app.tab(favorite)['url']; reset_enabled = menu_enabled('reset-all-tabs-in-space')
    app.call('command', id='reset-all-tabs-in-space')
    for n in originals: app.call('wait', tab=n)
    reset = all(app.tab(n)['url'] == url and app.tab(n).get('page', {}).get('url') == url for n, url in originals.items())
    pinned_split = any(n['kind'] == 'split' and {c['id'] for c in n['children']} == {partner, split_other} for n in walk(tree()['pinned']))
    require('E9_reset_live_pinned_pages', reset_enabled and reset and pinned_split and not menu_enabled('reset-all-tabs-in-space'), tabs=app.call('tabs'), tree=tree())
    favorite_ok = app.tab(favorite)['url'] == favorite_away
    app.call('space', space=other_space)
    require('E9_reset_excludes_favorites_other_spaces', favorite_ok and app.tab(other)['url'] == other_away)
    # E10: browser Space context export preserves IDs and order in one undo.
    export = fresh('Export Source'); exp_pin = opened('Export Pinned', True); exp_today = opened('Export Today')
    source = tree(); spaces_before = [s['id'] for s in app.call('spaces')]
    app.call('sidebar-menu', item='Export “A3 Export Source” into Folder/A3 Reset Other Space')
    focused = next(s['id'] for s in app.call('spaces') if s['focused'])
    app.call('space', space=other_space); exported = tree()['pinned'][0]
    require('E10_space_export_folder_exact_tree', len(app.call('spaces')) == len(spaces_before) - 1 and focused == other_space
            and exported['kind'] == 'folder' and shape(exported['children']) == shape(source['pinned'] + source['today']), folder=exported)
    undo()
    require('E10_export_one_undo', [s['id'] for s in app.call('spaces')] == spaces_before and next(s['id'] for s in app.call('spaces') if s['focused']) == export
            and shape(tree()['pinned']) == shape(source['pinned']) and shape(tree()['today']) == shape(source['today']))
    # E13: the actual command-bar Cmd+Return background open and visible dot.
    current = app.call('window-state')['selected']; app.call('suggest-remote', enabled=False)
    app.call('key', key='t', modifiers=['cmd'], route='app'); background_url = page('Command Background')
    app.call('key', text=background_url)
    wait_until(lambda: app.call('commandbar-state').get('final'), timeout=5)
    app.call('key', key='return', modifiers=['cmd'], route='app')
    background = wait_until(lambda: next((t for t in app.call('tabs') if t['url'] == background_url), None), timeout=5)
    require('E13_commandbar_cmd_return_unread', background and background['unread'] and state()['selected'] == current
            and app.call('sidebar-row', node=background['id'])['unreadBadge'], tab=background)
    click(background['id'])
    require('E13_sidebar_select_clears_unread', not app.tab(background['id'])['unread'] and not app.call('sidebar-row', node=background['id'])['unreadBadge'])
    hover_result = app.call('hover', favorite=favorite, ms=600); leave = app.call('hover', leave=True, ms=300)
    require('A3_favorite_hover_wrapper', hover_result['kind'] == 'page' and hover_result['target'] == favorite and leave['kind'] == 'none', preview=hover_result, leave=leave, expected=favorite)
    # E15: hit the divider's actual Clear control, with Option and without.
    clear_space = fresh('Clear'); protected = opened('Clear Pinned', True)
    for i in range(4): opened('Clear Today %d' % i)
    today = roots('today'); keep, current = today[:2]; select([keep, current])
    profile = app.tab(current)['profile']; prior_archive = {r['id'] for r in app.call('archive-list', profile=profile)['rows']}
    def clear(option):
        frame = app.call('sidebar-clear-state')['frame']; assert frame, 'missing divider frame'
        point = [frame[0] + frame[2] / 2, frame[1] + frame[3] / 2]
        app.call('mouse', action='hover', x=point[0], y=point[1]); visible = app.call('sidebar-clear-state')['visible']
        app.call('mouse', action='click', x=point[0], y=point[1], modifiers=['option'] if option else [])
        return visible
    # select() keeps the page on the first plain-clicked row; both IDs are protected.
    visible = clear(True); remaining = roots('today')
    require('E15_option_clear_keeps_current_selection', visible and remaining == today[:2] and app.tab(protected)['section'] == 'pinned' and app.tab(favorite)['section'] == 'favorites', remaining=remaining)
    archived = [r for r in app.call('archive-list', profile=profile)['rows'] if r['id'] not in prior_archive]
    toast = state()['toast']; pressed = app.call('toast-undo')
    require('E15_clear_real_archive_and_undo', {r['id'] for r in archived} == set(today[2:]) and all(r['reason'] == 'clearedToday' for r in archived)
            and toast == 'Cleared Tabs' and pressed and roots('today') == today, archive=archived, toast=toast)
    visible = clear(False); archived = app.call('archive-list', profile=profile)['rows']
    require('E15_plain_clear_archives_all_today', visible and roots('today') == [] and set(today) <= {r['id'] for r in archived})
    app.call('toast-undo')
    # E8 keyboard Delete and E18 nested folder archive/Library restore.
    restore_space = fresh('Folder Restore'); one = opened('Restore One'); two = opened('Restore Two')
    child = app.call('folder', tabs=[two], title='Nested Restore')
    folder = app.call('folder', tabs=[one], title='Restore Root')
    drop([child], 'folder', folder, 1)
    before = tree(); expected = shape(before['today']); click(one); click(folder, ['cmd']); click(one, ['cmd']); key('delete')
    sheet = wait_until(lambda: state()['confirmation'], timeout=3); app.call('alert', button='Cancel')
    require('E8_keyboard_delete_cancel_preserves_tree', sheet and shape(tree()['today']) == expected)
    key('forward-delete'); wait_until(lambda: state()['confirmation'], timeout=3); app.call('alert', button='Delete Folder')
    rows = app.call('archive-list', profile=profile)['rows']
    record = next((r for r in rows if r['id'] == folder), None)
    require('E18_delete_folder_archive_kind', record and record['kind'] == 'folder' and roots('today') == [], record=record)
    opened_library = app.call('library-open', section='archive')
    wait_until(lambda: any(r['id'] == folder for r in app.call('settings-state')['archive']), timeout=5)
    app.call('library-restore', id=folder)
    require('E18_library_restore_folder_ids', opened_library['section'] == 'archive' and shape(tree()['today']) == expected
            and not any(r['id'] == folder for r in app.call('archive-list', profile=profile)['rows']), tree=tree())
    app.call('library-close'); app.call('save'); app.quit(); app = launch(); app.call('space', space=restore_space)
    require('E18_folder_restore_survives_relaunch', shape(app.call('sidebar-tree')['today']) == expected, tree=app.call('sidebar-tree'))
    return app


def sidebar_favicon_checks(app, require, tmp, launch):
    """Engine favicon event -> App store -> unloaded real row -> cold relaunch."""
    import http.server
    import threading
    import zlib

    def icon(color):
        def chunk(kind, body):
            return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress((b'\0' + bytes(color) * 64) * 64)) + chunk(b'IEND', b''))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.endswith('.png'):
                body, mime = icon((20, 80, 220, 255) if 'blue' in self.path else (220, 80, 20, 255)), 'image/png'
            else:
                body, mime = b'<title>Stored favicon fixture</title><link rel="icon" href="/red.png"><h1>Stored favicon</h1>', 'text/html'
            self.send_response(200); self.send_header('Content-Type', mime)
            self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass

    class MissingHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path in ('/favicon.ico', '/missing.png'):
                self.send_error(404); return
            body = (b'<title>No favicon fixture</title><h1>No icon</h1>' +
                    (b'<link rel="icon" href="/missing.png">' if self.path == '/broken' else b''))
            self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass

    missing_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), MissingHandler)
    threading.Thread(target=missing_server.serve_forever, daemon=True).start()
    missing_origin = 'http://127.0.0.1:%d' % missing_server.server_address[1]
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    try:
        app.call('library-close')
        space = app.call('space-create', title='Stored favicons'); app.call('space', space=space)
        pin = app.call('open', url=origin + '/page')['id']; app.call('wait', tab=pin); app.call('pin', tab=pin)
        loaded = wait_until(lambda: (lambda t: t if t['favicon'] and t.get('rowFaviconHash') and t.get('faviconReportsCompleted', 0) else None)(app.tab(pin)), timeout=8)
        require('FV1_engine_report_stored_and_drawn', bool(loaded), tab=app.tab(pin))
        red = loaded['rowFaviconHash']; count = loaded['faviconReportsCompleted']
        app.eval(pin, "document.querySelector('link[rel=icon]').href='/blue.png'; true")
        changed = wait_until(lambda: (lambda t: t if t.get('rowFaviconHash') and t['rowFaviconHash'] != red and t.get('faviconReportsCompleted', 0) > count else None)(app.tab(pin)), timeout=8)
        require('FV2_engine_report_replaces_stored_icon', bool(changed), tab=app.tab(pin), previousHash=red)
        blue = changed['rowFaviconHash']
        # Pin Close follows production unload. It keeps the old live PNG; the row
        # must select storage when hasWebContent becomes false.
        neighbor = app.call('open', url=fixture('Stored favicon neighbor'))['id']; app.call('wait', tab=neighbor)
        app.call('close', tab=pin)
        unloaded = wait_until(lambda: (lambda t: t if not t['hasWebContent'] and t.get('rowFaviconSource') == 'stored' and t.get('rowFaviconHash') == blue else None)(app.tab(pin)), timeout=5)
        require('FV3_unloaded_row_draws_stored_pixels', bool(unloaded), tab=app.tab(pin), expectedHash=blue)
        app.call('save'); app.quit(); app = launch(); app.call('space', space=space)
        cold = wait_until(lambda: (lambda t: t if not t['hasWebContent'] and t.get('rowFaviconSource') == 'stored' and t.get('rowFaviconHash') == blue else None)(app.tab(pin)), timeout=8)
        require('FV4_relaunch_unloaded_row_same_pixels', bool(cold), tab=app.tab(pin), expectedHash=blue)
        # A new URL-only tab has the same shape as an imported pin. It has no host.
        imported = app.call('open', url=origin + '/page', background=True)['id']
        app.call('pin', tab=imported)
        imported_row = wait_until(lambda: (lambda t: t if not t['hasWebContent'] and t.get('rowFaviconSource') == 'stored' and t.get('rowFaviconHash') == blue else None)(app.tab(imported)), timeout=5)
        require('FV5_url_only_import_shape_uses_stored_icon', bool(imported_row), tab=app.tab(imported), expectedHash=blue)
        app.call('favorite', tab=imported)
        favorite = wait_until(lambda: (lambda t: t if t['section'] == 'favorites' and not t['hasWebContent'] and t.get('rowFaviconSource') == 'stored' and t.get('rowFaviconHash') == blue else None)(app.tab(imported)), timeout=5)
        require('FV6_unloaded_favorite_same_pixels', bool(favorite), tab=app.tab(imported), expectedHash=blue)
        # Same declared icon URL across two committed page paths: OpenEngine emits
        # no second favicon notification. Only the URL hook can persist /b.
        route = app.call('open', url=origin + '/a')['id']; app.call('wait', tab=route); app.call('pin', tab=route)
        same = wait_until(lambda: (lambda t: t if t.get('rowFaviconHash') and t['favicon'] else None)(app.tab(route)), timeout=8)
        same_hash = same['rowFaviconHash']
        app.call('navigate', tab=route, url=origin + '/b'); app.call('wait', tab=route)
        wait_until(lambda: app.tab(route)['url'] == origin + '/b', timeout=5)
        # Unload via the production pin Close route, then require storage pixels.
        app.call('open', url=fixture('Unchanged icon neighbor')); app.call('close', tab=route)
        same_stored = wait_until(lambda: (lambda t: t if not t['hasWebContent'] and t['url'] == origin + '/b' and t.get('rowFaviconSource') == 'stored' and t.get('rowFaviconHash') == same_hash else None)(app.tab(route)), timeout=5)
        require('FV14_same_icon_new_path_unloaded', bool(same_stored), tab=app.tab(route), expectedHash=same_hash)

        # A URL commit still exposes the previous document's NSImage. Both an
        # absent declaration and a failed download must leave no destination row.
        import sqlite3
        missing_results = []
        for path in ('/absent', '/broken'):
            candidate = app.call('open', url=origin + '/source' + path)['id']
            app.call('wait', tab=candidate); app.call('pin', tab=candidate)
            wait_until(lambda: app.tab(candidate)['favicon'], timeout=8)
            destination = missing_origin + path
            app.call('navigate', tab=candidate, url=destination); app.call('wait', tab=candidate)
            wait_until(lambda: app.tab(candidate)['url'] == destination, timeout=5)
            app.call('open', url=fixture('Missing icon neighbor')); app.call('close', tab=candidate)
            wait_until(lambda: not app.tab(candidate)['hasWebContent'], timeout=5)
            # Drain the real cache worker by orderly quit before read-only SQL.
            app.call('save'); app.quit(); app = launch(); app.call('space', space=space)
            row = wait_until(lambda: (lambda t: t if t.get('rowFaviconSource') else None)(app.tab(candidate)), timeout=5)
            with sqlite3.connect('file:' + os.path.join(app.user_data, 'State', 'favicons.sqlite3') + '?mode=ro', uri=True) as database:
                records = database.execute('SELECT count(*) FROM favicons WHERE origin=? AND page_key=?', (missing_origin, path)).fetchone()[0]
            missing_results.append(dict(path=path, row=row, records=records,
                ok=not row['hasWebContent'] and row['rowFaviconSource'] == 'placeholder' and not row['rowFaviconHash'] and records == 0))
        require('FV16_cross_origin_missing_and_404_leave_no_stored_icon', all(r['ok'] for r in missing_results), cases=missing_results)

        return app
    finally:
        server.shutdown(); server.server_close()
        missing_server.shutdown(); missing_server.server_close()



def sidebar_tab_switcher_checks(app, require, tmp):
    """TS keys enter OEApplication.sendEvent. No desktop input or direct dispatch."""
    def state(): return app.call('window-state')
    def switcher(): return app.call('tab-switcher-state')
    def key(name, mods=()): return app.call('key', key=name, modifiers=list(mods), route='app')
    def selected(): return state()['selected']
    def release(): return key('control')
    def opened(name):
        path = Path(tmp) / ('ts-' + name + '.html')
        path.write_text('<title>Switcher %s</title><h1>%s</h1>' % (name, name))
        node = app.call('open', url=path.as_uri())['id']; app.call('wait', tab=node); return node
    def tree_ids():
        def flatten(nodes):
            return [node['id'] for node in nodes if node['kind'] == 'tab'] + [item for node in nodes for item in flatten(node.get('children', []))]
        tree = app.call('sidebar-tree')
        return flatten(tree['pinned']) + flatten(tree['today'])
    include_key = 'open.shortcuts.includeFavoritesInTabNumbering'
    ninth_key = 'open.shortcuts.switchToNinthEnabled'
    old_include = app.call('defaults', key=include_key); old_ninth = app.call('defaults', key=ninth_key)
    app.call('library-close'); app.call('window-focus', id=state()['id'], activate=True)
    first_space = app.call('space-create', title='Tab Shortcuts A', profile='Tab Shortcuts')
    created_before_empty = switcher()['created']
    key('9', ['cmd']); key('tab', ['ctrl']); release()
    require('TS_empty_window_keys_are_safe', selected() == '' and not switcher()['active'] and switcher()['created'] == created_before_empty and not switcher()['monitoringModifiers'], switcher=switcher())
    favorite = opened('favorite'); app.call('favorite', tab=favorite)
    pin = opened('pin'); app.call('pin', tab=pin)
    today = [opened('today%d' % i) for i in range(3)]
    app.call('defaults', key=ninth_key, value=False)
    app.call('defaults', key=include_key, value=True)
    key('1', ['cmd'])
    require('TS_cmd1_include_favorites_on', selected() == favorite, selected=selected(), expected=favorite)
    app.call('defaults', key=include_key, value=False); key('1', ['cmd'])
    require('TS_cmd1_include_favorites_off', selected() == pin, selected=selected(), expected=pin)
    last = tree_ids()[-1]; key('9', ['cmd'])
    require('TS_cmd9_last_with_fewer_than_nine', selected() == last, selected=selected(), expected=last)
    more = [opened('more%d' % i) for i in range(7)]
    ids = tree_ids(); key('9', ['cmd'])
    require('TS_cmd9_last_after_ninth', len(ids) > 9 and selected() == ids[-1], selected=selected(), expected=ids[-1])
    app.call('defaults', key=ninth_key, value=True); key('9', ['cmd'])
    require('TS_cmd9_ninth_option', selected() == ids[8], selected=selected(), expected=ids[8])
    app.call('defaults', key=ninth_key, value=False)
    # Arc's committed Tabs table has no separate Go to Last Tab item. Dispatch
    # the real tab row carrying Cmd+9, after the preference-driven menu rebuild.
    last_menu = wait_until(lambda: next((r for r in app.call('menu-state')
        if r['id'] == 'dynamic-tab-' + ids[-1] and r['key'] == '9'), None), timeout=3)
    assert last_menu, 'last tab did not acquire the Cmd+9 menu equivalent'
    app.call('menu-perform', id=last_menu['id'])
    menu_rows = app.call('menu-state')
    require('TS_last_menu_dispatch', selected() == ids[-1]
            and all(r['id'] != 'go-to-last-tab' and r['title'] != 'Go to Last Tab' for r in menu_rows),
            selected=selected(), expected=ids[-1], item=last_menu)
    second_space = app.call('space-create', title='Tab Shortcuts B', profile='Tab Shortcuts')
    key('tab', ['ctrl']); empty_space = switcher(); release()
    require('TS_empty_space_starts_with_most_recent', empty_space['selected'] == ids[-1] and selected() == ids[-1], switcher=empty_space, state=state())
    app.call('space', space=second_space)
    other = opened('other-space')
    app.call('space', space=first_space)
    for node in (favorite, pin, today[0]): app.call('select', tab=node)
    current = selected(); hosts_before = app.call('host-counts'); key('tab', ['ctrl']); first = wait_until(lambda: (lambda s: s if s['presented'] else None)(switcher()), timeout=3)
    require('TS_ctrl_tab_mru_includes_pinned_favorites_other_space', first['presented'] and first['monitoringModifiers'] and first['items'][:4] == [current, pin, favorite, other]
            and len(first['items']) == 5 and first['selected'] == pin and selected() == current,
            switcher=first, selected=selected(), expected=[current, pin, favorite, other])
    hosts_after = app.call('host-counts')
    image_path = str(Path(ROOT) / '.re' / 'tab-switcher' / 'real-switcher.png')
    Path(image_path).parent.mkdir(parents=True, exist_ok=True)
    app.call('snapshot', path=image_path)
    require('TS_highlight_does_not_create_hosts', hosts_before == hosts_after, before=hosts_before, after=hosts_after, png=image_path)
    key('tab', ['ctrl']); second = switcher()
    require('TS_hold_ctrl_tab_twice_defers_commit', second['selected'] == favorite and selected() == current and second['items'] == first['items'], switcher=second)
    release()
    require('TS_release_control_commits', selected() == favorite and not switcher()['presented'] and not switcher()['monitoringModifiers'], selected=selected(), switcher=switcher())
    key('tab', ['ctrl']); key('escape'); release()
    require('TS_escape_cancels', selected() == favorite and not switcher()['presented'] and not switcher()['monitoringModifiers'], selected=selected(), switcher=switcher())
    key('tab', ['ctrl', 'shift']); reverse = switcher()
    require('TS_reverse_uses_frozen_mru', reverse['selected'] == reverse['items'][-1] and selected() == favorite, switcher=reverse)
    key('escape'); release()
    # Visit the other Space last, then return: committing the second recent tab
    # restores its Space as well as the real page's selected tab. Keep the
    # destination's remembered selection current: #130 stamps departures too.
    app.call('select', tab=today[0])
    app.call('space', space=second_space); app.call('select', tab=other)
    app.call('space', space=first_space); app.call('select', tab=today[0])
    key('tab', ['ctrl']); cross = switcher(); release()
    require('TS_commit_other_space', cross['selected'] == other and selected() == other and state()['space'] == second_space,
            switcher=cross, state=state(), expected=other)
    app.call('space', space=first_space)
    key('tab', ['ctrl']); bounded = switcher()
    require('TS_visible_view_count_bounded', bounded['viewCount'] == 1 and len(bounded['visible']) <= 5, switcher=bounded)
    key('escape'); release()
    app.call('defaults', key=include_key, value=old_include); app.call('defaults', key=ninth_key, value=old_ninth)

def sidebar_intents_menu_checks(app, results, require, tmp):
    """Section 1 items 9–10: use real NSMenu actions; always cancel native UI."""
    def state(): return app.call('window-state')
    def tree(): return app.call('sidebar-tree')
    def structure(value):
        if isinstance(value, dict): return {k: structure(v) for k, v in value.items() if k != 'loaded'}
        if isinstance(value, list): return [structure(v) for v in value]
        return value
    def spaces(): return app.call('spaces')
    def roots(section): return [n['id'] for n in tree()[section]]
    def key(name, mods=()): return app.call('sidebar-key', key=name, modifiers=list(mods))
    def undo(): return key('z', ['cmd'])
    def opened(name, pinned=False):
        path = Path(tmp) / ('intents-' + name.lower().replace(' ', '-') + '.html')
        path.write_text('<title>%s</title><h1>%s</h1>' % (name, name))
        node = app.call('open', url=path.as_uri())['id']; app.call('wait', tab=node)
        if pinned: app.call('pin', tab=node)
        return node
    def menu(node, item): return app.call('sidebar-menu', node=node, item=item)
    def inspect(item, node=None):
        return app.call('sidebar-menu-state', **dict(item=item, **({'node': node} if node else {})))
    def current_space(): return next(s for s in spaces() if s['focused'])
    def alert_state():
        try: return app.call('alert', window='library')
        except RuntimeError as error:
            if 'no attached alert sheet' in str(error): return None
            raise
    def cancelled_alert():
        try: app.call('alert', window='library', button='Cancel')
        except RuntimeError as error:
            if 'no attached alert sheet' not in str(error): raise
    browser = state()['id']
    try:
        # Same-profile conversion, with nested descendants, preserved order and live host.
        source = app.call('space-create', title='Intents Source', profile='Intents Profile')
        a, b, c = [opened('Convert %s' % name, True) for name in ('A', 'B', 'C')]
        nested = app.call('folder', tabs=[b, c], title='Nested', section='pinned')
        folder = app.call('folder', tabs=[a], title='Converted Folder', section='pinned')
        app.call('sidebar-drop', nodes=[nested], parent=dict(kind='folder', id=folder), index=1)
        d, e = opened('Convert Split A'), opened('Convert Split B')
        app.call('select', tab=d); menu(e, 'Open in Split View')
        split = next(n['id'] for n in tree()['today'] if n['kind'] == 'split')
        app.call('sidebar-drop', nodes=[split], parent=dict(kind='folder', id=nested), index=2)
        app.call('select', tab=a)
        app.call('eval', tab=a, js='window.__convertProbe = 91')
        before = tree(); count = len(spaces()); profile = current_space()['profile']
        # The real split menu inserts the clicked pane before the current pane (e, d).
        for markdown, label in [(False, 'Copy All Links'), (True, 'Copy All Links as Markdown')]:
            menu(folder, label)
            expected = ['[%s](%s)' % (app.tab(n)['title'], app.tab(n)['url']) if markdown else app.tab(n)['url'] for n in (a, b, c, e, d)]
            actual = app.call('pasteboard').splitlines()
            require('I9_copy_folder_' + ('markdown' if markdown else 'plain'), actual == expected, actual=actual, expected=expected, tree=tree())
        menu(folder, 'Turn “Converted Folder” into Space')
        created = current_space()
        require('I9_folder_into_space_today_same_profile', len(spaces()) == count + 1 and created['title'] == 'Converted Folder'
                and created['profile'] == profile and roots('pinned') == [] and roots('today') == [a, nested]
                and all(app.tab(n)['section'] == 'today' and not app.tab(n)['pinnedURL'] for n in (a, b, c, d, e)), space=created, tree=tree())
        require('I9_folder_conversion_preserves_live_host', app.call('eval', tab=a, js='window.__convertProbe') == 91)
        undo()
        require('I9_folder_conversion_one_undo', len(spaces()) == count and current_space()['id'] == source and tree() == before, tree=tree())
        key('z', ['cmd', 'shift'])
        require('I9_folder_conversion_redo', len(spaces()) == count + 1 and current_space()['id'] in (source, created['id'])
                and any(s['id'] == created['id'] for s in spaces()))
        undo(); app.call('space', space=source)
        # A folder with no children is also a valid conversion, with one undo.
        empty = app.call('folder-create', title='Empty Conversion'); before_empty = tree()
        menu(empty, 'Turn “Empty Conversion” into Space')
        require('I9_empty_folder_conversion', current_space()['title'] == 'Empty Conversion' and tree() == {'pinned': [], 'today': []})
        undo(); app.call('space', space=source)
        require('I9_empty_folder_conversion_undo', tree() == before_empty)
        # Single-item Move to uses A3's plain New Space helper (Pinned placement).
        single = opened('Move Single'); before_move = tree(); count = len(spaces())
        menu(single, 'Move to/New Space…'); moved = current_space()
        require('I9_move_single_to_new_space', len(spaces()) == count + 1 and moved['title'] == 'Space' and moved['profile'] == profile
                and roots('pinned') == [single] and roots('today') == [], space=moved)
        undo(); app.call('space', space=source)
        # A3's fallback-Space undo can unload background pages; compare the
        # complete saved structure, not that transient loaded flag.
        require('I9_move_single_one_undo', len(spaces()) == count and structure(tree()) == structure(before_move), before=before_move, after=tree(), expectedCount=count, actualCount=len(spaces()))
        # No Copy All Links intent comes from the captured Space menu. Verify its
        # existing export and Manage entries, rather than add a new uncaptured item.
        disabled = inspect('Share Space…')
        try: app.call('sidebar-menu', item='Share Space…'); refused = False
        except RuntimeError: refused = True
        require('I9_share_space_disabled', not disabled['enabled'] and disabled['key'] == '' and refused, item=disabled)
        # Spaces menu commands carry the documented empty key equivalents.
        rows = {r['id']: r for r in app.call('menu-state')}
        commands = ('rename-space', 'change-profile', 'clear-archive', 'manage-spaces')
        require('I10_menu_enablement_and_keys', all(rows[c]['enabled'] and rows[c]['key'] == '' for c in commands),
                rows={c: rows[c] for c in commands}, evidence='docs/re/menus-and-hotkeys.md Spaces and Archive; docs/commands.md')
        original = current_space()['title']
        app.call('menu-perform', id='rename-space')
        try:
            app.call('key', text='Renamed Inline')
            app.call('key', key='return', route='app')
            require('I10_rename_space_inline', current_space()['title'] == 'Renamed Inline', space=current_space())
        finally:
            app.call('key', key='escape', route='app')
        undo(); require('I10_rename_space_undo', current_space()['title'] == original)
        # Hidden-sidebar entry still starts the same inline editor, by revealing it.
        app.call('menu-perform', id='toggle-sidebar'); app.call('menu-perform', id='rename-space')
        try:
            require('I10_rename_hidden_sidebar_reveals', state()['sidebarMode'] == 'anchored')
            app.call('key', text='Cancelled Rename'); app.call('key', key='escape', route='app')
            require('I10_rename_cancel_unchanged', current_space()['title'] == original)
        finally:
            app.call('key', key='escape', route='app')
        app.call('window-focus', id=browser, activate=True)
        require('I10_profile_cancel_window_ready', state()['appActive'] and current_space()['title'] == original)
        app.call('profile-menu', response='cancel')
        try:
            app.call('menu-perform', id='change-profile')
            popup = app.call('profile-menu', waitClosed=True)
            require('I10_change_profile_opens_set_profile', popup and popup.get('shown') and popup.get('trackingBegan') and popup.get('closed') and not popup['pending'] and any(r['title'] == 'Intents Profile' and r['checked'] for r in popup['items'])
                    and current_space()['profile'] == profile, menu=popup)
        finally:
            app.call('profile-menu', close=True)
        app.call('window-focus', id=browser, activate=True)
        require('I10_profile_choice_window_ready', state()['appActive'])
        app.call('profile-menu', response='Default')
        try:
            app.call('menu-perform', id='change-profile')
            chosen = app.call('profile-menu', waitClosed=True)
            require('I10_change_profile_choice_dispatches', chosen and chosen.get('chosen') == 'Default' and chosen.get('shown') and chosen.get('trackingBegan') and chosen.get('closed') and not chosen['pending'] and current_space()['profile'] != profile, menu=chosen)
        finally:
            app.call('profile-menu', close=True)
        undo(); require('I10_change_profile_undo', current_space()['profile'] == profile)
        app.call('menu-perform', id='manage-spaces')
        require('I10_manage_spaces_menu', wait_until(lambda: app.call('space-manager-state')['visible'], timeout=5)
                and app.call('settings-state')['librarySection'] == 'spaces')
        app.call('library-close'); app.call('window-focus', id=browser, activate=True)
        # Clear Archive must use the Library dialog, including its real Cancel.
        archived = opened('Clear Archive Fixture'); app.call('menu-perform', id='archive-tab')
        archive_profiles = sorted({s['profile'] for s in spaces()})
        before_archives = {p: app.call('archive-list', profile=p)['rows'] for p in archive_profiles}
        before_archive = before_archives[profile]
        require('I10_clear_archive_fixture', any(r['id'] == archived for r in before_archive))
        app.call('menu-perform', id='clear-archive')
        try:
            confirmation = wait_until(alert_state, timeout=5)
            require('I10_clear_archive_library_confirmation', confirmation and "Are you sure you'd like to Clear Archive?" in confirmation['texts']
                    and 'This deletes every archived tab. This cannot be undone.' in confirmation['texts']
                    and 'Clear Archive' in confirmation['buttons'], alert=confirmation)
            app.call('alert', window='library', button='Cancel')
            require('I10_clear_archive_cancel', {p: app.call('archive-list', profile=p)['rows'] for p in archive_profiles} == before_archives)
        finally:
            cancelled_alert()
        app.call('library-close'); app.call('window-focus', id=browser, activate=True)
        app.call('menu-perform', id='clear-archive')
        try:
            wait_until(alert_state, timeout=5)
            app.call('alert', window='library', button='Clear Archive')
            require('I10_clear_archive_confirm', wait_until(lambda: all(app.call('archive-list', profile=p)['rows'] == [] for p in archive_profiles), timeout=5))
        finally:
            cancelled_alert()
        app.call('library-close'); app.call('window-focus', id=browser, activate=True)
        # The tab's real Share menu item must invoke NSSharingServicePicker with
        # that row's URL. The automation policy closes it without choosing a service.
        require('I9_share_window_ready', state()['appActive'])
        app.call('sidebar-share', dismiss=True)
        try:
            menu(a, 'Share…')
            shared = app.call('sidebar-share', waitClosed=True)
            require('I9_share_system_picker', shared and shared.get('closed') and not shared['pending'] and shared['requested'] and shared['url'] == app.tab(a)['url']
                    and shared['servicesRequested'] and shared['anchor'][2] > 0 and not shared.get('choseService'), request=shared)
        finally:
            app.call('sidebar-share', close=True, dismiss=False)
        app.call('window-close')
        rows = {r['id']: r for r in app.call('menu-state')}
        require('I10_no_browser_window_disables_commands', not app.call('shell-windows')
                and all(not rows[c]['enabled'] for c in ('rename-space', 'change-profile', 'clear-archive')), rows={c: rows[c] for c in commands})
        app.call('window-reopen')
    finally:
        # Run even after a failed assertion, so no tracked menu, share picker,
        # rename field, or confirmation can hold the next suite open.
        if app.call('shell-windows'):
            app.call('sidebar-share', close=True, dismiss=False)
            app.call('profile-menu', close=True)
            app.call('key', key='escape', route='app')
        cancelled_alert(); app.call('library-close')


def space_manager_checks(results, tmp, config, style):
    """E5/E6: real Library injection, native reorder/undo, stores and lifetimes."""
    import plistlib
    token = '%d-%s' % (os.getpid(), os.urandom(4).hex())
    suite_config = 'SpaceManager-' + token
    bundle_dir = os.path.join(ROOT, 'build', suite_config)
    bundle = os.path.join(bundle_dir, 'Open.app')
    bundle_id = 'io.github.sergeserb2.open.e2e.spacemanager.' + token
    run_name = 'Open-E2E-spacemanager-%s-%s' % (style, token)
    root = os.path.expanduser('~/Library/Application Support/' + run_name)
    cache = os.path.expanduser('~/Library/Caches/' + run_name)
    evidence = os.path.join(os.environ.get('OPEN_SPACE_MANAGER_EVIDENCE_ROOT', os.path.join(ROOT, '.re', 'space-manager')), 'run-' + token)
    os.makedirs(evidence, exist_ok=True)
    apps, owned_pids = [], set()
    tracker = results.tracker

    def launch(urls=()):
        app = Open(suite_config, style, root, ['--use-mock-keychain'], os.path.join(evidence, 'app.log'), urls=urls)
        app.focus_tracker = tracker
        tracker.apps.append(app); apps.append(app); owned_pids.add(app.pid)
        return app

    def require(name, condition, **detail):
        results[name] = dict(detail, ok=bool(condition))
        if not condition: raise AssertionError(name)

    def state(app):
        return app.call('space-manager-state')

    def order(app):
        return [row['id'] for row in app.call('spaces')]

    def manager_ready(app):
        return wait_until(lambda: (lambda s: s if s['visible'] and s['section'] == 'spaces'
                         and s['identity'] and s['hostedManagers'] == 1 else None)(state(app)), timeout=5)

    def library_key(app, key, modifiers=()):
        return app.call('key', key=key, modifiers=list(modifiers), route='app', window=state(app)['window'])

    def capture(app, name):
        path = os.path.join(evidence, name + '.png')
        app.call('snapshot', path=path, window=state(app)['window'])
        return path

    try:
        provenance = space_manager_engine_provenance(config)
        expected = provenance['expectedSHA256']
        require('engine_framework_provenance', provenance['stamp'].startswith('fork ')
                and provenance['embeddedSHA256'] == provenance['recordedAfterEmbedSigningSHA256']
                and (not expected or provenance['recordedSHA256'] == expected), **provenance)
        # A clone of our own built app gives CFPreferences a unique, disposable
        # domain. Frameworks and engine are the recorded distribution, unchanged.
        os.makedirs(bundle_dir)
        subprocess.run(['cp', '-cR', os.path.join(ROOT, 'build', config, 'Open.app'), bundle], check=True)
        info_path = os.path.join(bundle, 'Contents', 'Info.plist')
        with open(info_path, 'rb') as stream: info = plistlib.load(stream)
        info['CFBundleIdentifier'] = bundle_id
        with open(info_path, 'wb') as stream: plistlib.dump(info, stream)
        subprocess.run(['codesign', '--force', '--sign', '-', bundle], check=True, capture_output=True)
        app = launch((fixture('Manager One'),))
        first_window = app.call('shell-windows')[0]['id']
        if os.environ.get('OPEN_SIDEBAR_INTENTS_ONLY') == '1':
            sidebar_intents_menu_checks(app, results, require, tmp)
            return
        s1 = order(app)[0]
        s2 = app.call('space-create', title='Manager Two')
        s3 = app.call('space-create', title='Manager Three')
        sidebar_a1_checks(app, results, require, evidence)
        sidebar_a2_checks(app, results, require, evidence, tmp)
        app.call('space', space=s1)
        original = [s1, s2, s3]
        # The rest capture shows the loaded page title, not a title still in flight.
        for row in app.call('tabs'): app.call('wait', tab=row['id'])
        app.call('menu-perform', id='manage-spaces')
        ready = manager_ready(app)
        rest = capture(app, 'manager-rest')
        require('E5_menu_real_manager', ready and ready['section'] == 'spaces' and ready['managerClass'] == 'OpenSidebar.SpaceManagerView'
                and ready['sameModel'] and ready['sameUndoManager'] and not ready['previewsEnabled'] and ready['globalPreviewsEnabled'],
                state=state(app), png=rest, preferenceDomain=bundle_id)
        # No Arc frame of the Manager exists (capture C2 is pending), so the real
        # Library page is compared with the plan's spec: §3.2 columns (inset 16,
        # width 244, gap 12, header 44) and the S4 R1 header (icon 13/9, title
        # x 41, grabber W − 58, "…" W − 32; docs/design.md §20). Target ≤ 1 pt.
        def spec_rows(snapshot):
            rows = []
            for index, column in enumerate(snapshot['columns']):
                width = 244
                expected = {'column': [16 + index * 256, 16, 244, column['managerSize'][1] - 32],
                            'icon': [13, 9, 26, 26], 'grabber': [width - 58, 10, 24, 24], 'more': [width - 32, 10, 24, 24]}
                actual = dict(column['header'], column=column['column'])
                for part, frame in expected.items():
                    error = max(abs(a - e) for a, e in zip(actual.get(part, [1e9] * 4), frame))
                    rows.append({'space': column['id'], 'part': part, 'expected': frame, 'actual': actual.get(part), 'error': error})
                title = actual.get('title', [1e9] * 4)
                rows.append({'space': column['id'], 'part': 'title.x', 'expected': [41], 'actual': [title[0]], 'error': abs(title[0] - 41)})
            return rows
        geometry = spec_rows(ready)
        worst = max((row['error'] for row in geometry), default=1e9)
        require('E5_manager_spec_geometry', len(ready['columns']) == 3 and worst <= 1, worst=worst, rows=geometry,
                reference='plan §3.2 + docs/design.md §20 S4 R1; no Arc capture (C2 pending)')
        if os.environ.get('OPEN_SPACE_MANAGER_EARLY_FAILURE') == '1':
            raise AssertionError('deliberate early failure with Library open')
        library = ready['window']
        app.call('library-close')
        command = app.call('library-open', entry='command')
        app.call('library-close')
        app.call('window-focus', id=first_window, activate=True)
        header = app.call('library-open', entry='space-menu')
        require('E5_all_entries_one_library', command['window'] == library == header['window'] and header['hostedManagers'] == 1
                and header['section'] == 'spaces' and header['identity'] == command['identity'], command=command, header=header)
        app.call('library-close')
        app.call('window-focus', id=first_window, activate=True)
        app.call('suggest-remote', enabled=False)
        app.call('key', key='t', modifiers=['cmd'], route='app')
        bar_open = wait_until(lambda: app.call('commandbar-state').get('presented'), timeout=5)
        require('commandbar_opens_for_manager', bar_open, state=app.call('commandbar-state'))
        app.call('key', text='Manage Spaces')
        bar_results = wait_until(lambda: (lambda s: s if s.get('text') == 'Manage Spaces' and s.get('final') else None)(app.call('commandbar-state')), timeout=5)
        require('commandbar_finds_manager', bar_results and any(r.get('action') == 'manage-spaces' for r in bar_results.get('rows', [])), state=bar_results)
        app.call('key', key='return', route='app')
        from_bar = manager_ready(app)
        require('E5_commandbar_return_library', from_bar and from_bar['window'] == library and from_bar['section'] == 'spaces'
                and not app.call('commandbar-state').get('presented'), state=from_bar)
        point = header['columns'][0]['rows'][0]['point']
        app.call('mouse', action='hover', window=library, x=point[0], y=point[1])
        hovered = capture(app, 'manager-hovered')
        results['manager_captures'] = {'rest': rest, 'hovered': hovered,
            'comparison': 'no Arc Manager capture exists (C2 pending); geometry compared with the plan spec in E5_manager_spec_geometry'}
        refused = []
        for invalid in (-1, len(original)):
            try: app.call('space-manager-drag', space=s1, to=invalid)
            except RuntimeError as error:
                if 'invalid Space reorder' not in str(error): raise
                refused.append(invalid)
        require('automation_reorder_index_boundary_self_check', refused == [-1, len(original)] and order(app) == original, refused=refused)
        app.call('space-manager-drag', space=s1, to=2)
        reordered = [s2, s3, s1]
        drag = state(app)
        require('E6_native_drag_and_switcher', order(app) == reordered and [c['id'] for c in drag['columns']] == reordered
                and all(w['order'] == reordered for w in drag['switchers']), state=drag, expected=reordered,
                eventPath='OEApplication.sendEvent -> native SpaceGrabber.mouseDown -> tracking loop')
        # Count real UndoManager notifications as well as the resulting order.
        undo_before = state(app)['modelUndoCount']
        undo = library_key(app, 'z', ['cmd'])
        require('library_cmd_z_exactly_once', order(app) == original and state(app)['sameUndoManager'] and state(app)['modelUndoCount'] == undo_before + 1, order=order(app), key=undo, undoBefore=undo_before, undoAfter=state(app)['modelUndoCount'])
        app.call('space-manager-drag', space=s1, to=2)
        app.call('window-focus', id=first_window, activate=True)
        app.call('menu-perform', id='reveal-tab-in-sidebar')
        undo_before = state(app)['modelUndoCount']
        browser_undo = app.call('key', key='z', modifiers=['cmd'], route='app')
        require('browser_cmd_z_exactly_once', order(app) == original and state(app)['modelUndoCount'] == undo_before + 1, order=order(app), key=browser_undo, undoBefore=undo_before, undoAfter=state(app)['modelUndoCount'])
        app.call('library-open')
        app.call('space-manager-drag', space=s1, to=2)
        snapshot_path = app.call('save')
        with open(snapshot_path) as stream: saved = json.load(stream)
        app.call('library-close'); app.quit()
        app = launch()
        app.call('menu-perform', id='view-archive')
        # A menu action returning is not a Library composition/layout barrier.
        # Settle the actual window before reading coordinates, then poll the
        # cache-empty Archive state. Never accept an eagerly created cache.
        library_window = 0
        last_uncached = {}
        def archive_ready():
            nonlocal last_uncached, library_window
            # state() lays out the current Library window. Sample its row points
            # afterwards, in the same deadline poll, rather than before layout.
            library_window = state(app)['window']
            last_uncached = app.call('space-manager-lifecycle')
            has_row = any(r['section'] == 'spaces' for r in last_uncached['sectionRows'])
            return last_uncached if library_window and has_row and last_uncached['visible'] and last_uncached['section'] == 'archive' and last_uncached['identity'] == '' else None
        uncached = wait_until(archive_ready, timeout=5)
        if uncached:
            section = next(r for r in uncached['sectionRows'] if r['section'] == 'spaces')
            app.call('mouse', action='click', window=library_window, x=section['point'][0], y=section['point'][1])
        reopened = manager_ready(app) if uncached else None
        cache_ok = bool(uncached and reopened and reopened['hostedManagers'] == 1)
        if not cache_ok:
            # Keep the actual timeout state as well as the failed ready result.
            # A None from wait_until otherwise hides the reason it never settled.
            print('library_section_click_fills_cache FAIL ' + json.dumps(dict(
                uncached=last_uncached, reopened=state(app), ready=reopened), sort_keys=True), flush=True)
        require('library_section_click_fills_cache', cache_ok,
                uncached=last_uncached, reopened=reopened, after=app.call('space-manager-lifecycle'))
        require('E6_relaunch_preserves_ids', order(app) == reordered and [row['id'] for row in saved['spaces']] == reordered
                and reopened and [c['id'] for c in reopened['columns']] == reordered, expected=reordered, state=state(app))
        # The manager's real tab menu archives into the App's existing store.
        app.call('space', space=s2)
        archive_neighbor = app.call('open', url=fixture('Archive Neighbor'))['id']
        app.call('wait', tab=archive_neighbor)
        archived_tab = app.call('open', url=fixture('Manager Archive Original ID'))
        tab, archive_url = archived_tab['id'], archived_tab['url']
        app.call('wait', tab=tab)
        app.call('library-open')
        app.call('space-manager-menu', space=s2, node=tab, item='Archive Tab')
        archive_selection = app.call('window-state')
        results['manager_today_archive_selects_neighbor'] = dict(ok=archive_selection['selected'] == archive_neighbor, state=archive_selection, expected=archive_neighbor)
        app.call('menu-perform', id='view-archive')
        archived = wait_until(lambda: any(row['id'] == tab for row in app.call('settings-state')['archive']), timeout=5)
        require('manager_archive_real_store', archived and all(row['id'] != tab for row in app.call('tabs')), tab=tab)
        app.call('library-restore', id=tab)
        require('manager_archive_restore_original_id', app.tab(tab)['id'] == tab and app.tab(tab)['url'] == archive_url, tab=tab)
        app.call('library-open')
        # Delete/undo the Space through its real manager controls, preserving
        # both the Space and its archived tab's original identity.
        app.call('space-manager-menu', space=s2, item='Delete')
        # A1: the Manager's Delete confirms first, with a sheet on the Library window.
        manager_alert = app.call('alert', window='library')
        app.call('alert', window='library', button='Delete')
        require('manager_delete_space', s2 not in order(app) and 'Delete' in manager_alert['buttons']
                and any(t.endswith(' Space?') and t.startswith('Delete your ') for t in manager_alert['texts']),
                order=order(app), alert=manager_alert)
        library_key(app, 'z', ['cmd'])
        require('manager_delete_space_undo_ids', order(app) == reordered and app.tab(tab)['id'] == tab, order=order(app), tab=tab)
        # App-only appearance changes; always restore the original App override.
        appearance_before = app.call('space-manager-lifecycle')['appAppearance']
        try:
            for appearance in ('dark', 'light'):
                app.call('appearance', name=appearance)
                changed = wait_until(lambda: app.call('space-manager-lifecycle')['systemAppearance'] == appearance, timeout=5)
                require('manager_app_appearance_' + appearance, changed, state=app.call('space-manager-lifecycle'))
        finally:
            original_appearance = ('dark' if 'Dark' in appearance_before else 'light' if 'Aqua' in appearance_before else 'system')
            app.call('appearance', name=original_appearance)
        require('manager_app_appearance_restored', app.call('space-manager-lifecycle')['appAppearance'] == appearance_before, state=app.call('space-manager-lifecycle'))
        # One presenter follows B, then A, then B after A closes. The Space
        # edit precedes each lifetime mutation, with no intervening undoable edit.
        order_before_window = order(app)
        app.call('space-manager-drag', space=s1, to=0)
        undo_before_window = state(app)['modelUndoCount']
        hidden_before = app.call('space-manager-lifecycle')
        app.call('library-close')
        original_window = app.call('shell-windows')[0]['id']
        app.call('window-focus', id=original_window, activate=True)
        app.call('menu-perform', id='new-window')
        second = next(row['id'] for row in app.call('shell-windows') if row['id'] != original_window)
        app.call('window-focus', id=second, activate=True)
        app.call('window-focus', id=original_window, activate=True)
        app.call('window-focus', id=second, activate=True)
        hidden_after = app.call('space-manager-lifecycle')
        require('hidden_manager_focus_does_not_rebind', hidden_after['identity'] == hidden_before['identity']
                and hidden_after['contextWindow'] == hidden_before['contextWindow'] and hidden_after['builtColumns'] == hidden_before['builtColumns'],
                before=hidden_before, after=hidden_after)
        app.call('library-open'); second_manager = manager_ready(app)
        library_key(app, 'z', ['cmd'])
        with open(app.call('save')) as stream: after_create = json.load(stream)
        real_created = sorted(w['id'] for w in app.call('shell-windows'))
        require('library_undo_after_window_create', order(app) == order_before_window
                and state(app)['modelUndoCount'] == undo_before_window + 1
                and sorted(w['id'] for w in after_create['windows']) == real_created and len(real_created) == 2
                and state(app)['contextValid'] and app.call('space-manager-lifecycle')['undoRegistrationEnabled'],
                order=order(app), expectedOrder=order_before_window, snapshotWindows=after_create['windows'], shellWindows=app.call('shell-windows'),
                undoBefore=undo_before_window, undoAfter=state(app)['modelUndoCount'])
        scrolled = app.call('space-manager-scroll', x=32)
        app.call('window-focus', id=original_window, activate=True)
        app.call('library-open'); first_manager = manager_ready(app)
        require('manager_rebind_second_and_first', second_manager['contextWindow'] == second and first_manager['contextWindow'] == original_window
                and second_manager['identity'] != first_manager['identity'] and second_manager['window'] == first_manager['window'],
                first=first_manager, second=second_manager)
        copied_origin = app.call('space-manager-lifecycle')['origin']
        require('visible_manager_rebind_keeps_horizontal_origin', scrolled['origin'][0] > 0
                and abs(copied_origin[0] - scrolled['origin'][0]) < 0.5, before=scrolled['origin'], after=copied_origin)
        app.call('space-manager-scroll', x=0)
        order_before_close = order(app)
        app.call('space-manager-drag', space=s1, to=0)
        undo_before_close = state(app)['modelUndoCount']
        app.call('window-focus', id=original_window, activate=True)
        app.call('window-close')
        app.call('library-open'); surviving = manager_ready(app)
        require('closed_presenter_rebinds_live_window', surviving['contextWindow'] == second and surviving['contextValid']
                and len(app.call('shell-windows')) == 1, state=surviving)
        library_key(app, 'z', ['cmd'])
        with open(app.call('save')) as stream: after_close = json.load(stream)
        require('library_undo_after_window_close', order(app) == order_before_close
                and state(app)['modelUndoCount'] == undo_before_close + 1
                and [w['id'] for w in after_close['windows']] == [second]
                and [w['id'] for w in app.call('shell-windows')] == [second] and state(app)['contextValid'],
                order=order(app), expectedOrder=order_before_close, snapshotWindows=after_close['windows'], shellWindows=app.call('shell-windows'),
                undoBefore=undo_before_close, undoAfter=state(app)['modelUndoCount'])
        # A real manager row click must select in B, not A's removed state.
        app.call('window-focus', id=second, activate=True)
        app.call('space', space=s2)
        other = app.call('open', url=fixture('Surviving Browser Selection'))['id']
        app.call('wait', tab=other)
        app.call('library-open'); rebound = manager_ready(app)
        row = next(row for col in rebound['columns'] if col['id'] == s2 for row in col['rows'] if row['id'] == tab)
        app.call('mouse', action='click', window=rebound['window'], x=row['point'][0], y=row['point'][1])
        selected = state_when(app, lambda s: s['id'] == second and s['selected'] == tab and s['shownPages'] == [tab])
        require('rebound_manager_intents', selected and state(app)['contextWindow'] == second, browser=selected, actualBrowser=app.call('window-state', id=second), manager=state(app), point=row['point'], tab=tab, png=capture(app, 'manager-rebound-click'))
        pin = space_manager_route_checks(app, results, s2, library_key, tmp)
        if not results['manager_today_archive_selects_neighbor']['ok']: raise AssertionError('manager_today_archive_selects_neighbor')
        # #124 review: a URL dropped on another Space's column lands in that Space
        # (not the browser's focused one) and the browser shows it there.
        app.call('library-close'); app.call('window-focus', id=second, activate=True); app.call('space', space=s3)
        app.call('library-open'); manager_ready(app)
        drop_file = Path(tmp) / 'manager-drop-target.html'
        drop_file.write_text('<title>Manager Drop Target</title><h1>Manager Drop Target</h1>')
        drop_url = drop_file.as_uri()
        dropped = app.call('space-manager-intent', kind='openURL', space=s2, section='today', url=drop_url)
        landed = wait_until(lambda: (lambda tabs: tabs if any(t['url'].endswith('/manager-drop-target.html') and t['section'] == 'today' and t['selected'] for t in tabs) else None)(app.call('tabs')), timeout=5)
        focused = next((sp['id'] for sp in app.call('spaces') if sp['focused']), None)
        require('manager_url_drop_other_space', dropped and landed and focused == s2, focused=focused, expected=s2, tabs=app.call('tabs'))
        # #124 review: Open in Split View from a column whose Space the browser is
        # not showing goes through the browser controller in that Space.
        split_partner = next(t['id'] for t in app.call('tabs') if t['url'].endswith('/manager-drop-target.html'))
        split_source = app.call('open', url=fixture('Manager Split Source'))['id']
        app.call('wait', tab=split_source); app.call('select', tab=split_partner)
        app.call('space', space=s3); app.call('library-open'); manager_ready(app)
        app.call('space-manager-menu', space=s2, node=split_source, item='Open in Split View')
        split_state = wait_until(lambda: (lambda st: st if len(st.get('shownPages', [])) == 2 else None)(app.call('window-state')), timeout=5)
        focused = next((sp['id'] for sp in app.call('spaces') if sp['focused']), None)
        require('manager_split_through_browser', split_state and focused == s2 and set(split_state['shownPages']) == {split_source, split_partner},
                state=split_state or app.call('window-state'), focused=focused)
        # #124 review: Turn into Folder from a Manager column with a live browser
        # (E10 path): the Space becomes a Pinned folder of the destination; Cmd+Z restores it.
        app.call('library-open'); manager_ready(app)
        export_order = order(app)
        with open(app.call('save')) as stream: before_export = json.load(stream)
        export_source = next(sp for sp in before_export['spaces'] if sp['id'] == s1)
        def snapshot_ids(value):
            if isinstance(value, list): return [ident for child in value for ident in snapshot_ids(child)]
            if isinstance(value, dict): return ([value['id']] if 'id' in value else []) + [ident for key, child in value.items() if key != 'id' for ident in snapshot_ids(child)]
            return []
        source_ids = snapshot_ids(export_source['pinned'] + export_source['today'])
        export_title = next(sp['title'] for sp in app.call('spaces') if sp['id'] == s1) or 'Space'
        export_dest = next(sp for sp in app.call('spaces') if sp['id'] == s3)
        app.call('space-manager-menu', space=s1, item='Turn into Folder/' + (export_dest['title'] or 'Space'))
        exported = wait_until(lambda: s1 not in order(app), timeout=5)
        with open(app.call('save')) as stream: exported_snapshot = json.load(stream)
        dest_pinned = next(sp for sp in exported_snapshot['spaces'] if sp['id'] == s3)['pinned']
        first = dest_pinned[0] if dest_pinned else {}
        require('manager_turn_into_folder', exported and 'folder' in first, order=order(app), firstPinned=first, title=export_title)
        require('E10_manager_turn_into_folder', exported and 'folder' in first and snapshot_ids(first['folder']['_0']['children']) == source_ids, firstPinned=first, expectedIDs=source_ids)
        library_key(app, 'z', ['cmd'])
        require('manager_turn_into_folder_undo', wait_until(lambda: order(app) == export_order, timeout=5), order=order(app), expected=export_order)
        app.call('library-open'); manager_ready(app)
        pin_url_before_close = app.tab(pin)['url']
        app.call('library-close')
        app.call('window-focus', id=second, activate=True); app.call('window-close')
        require('no_browser_window', app.call('shell-windows') == [])
        no_browser = app.call('library-open')
        no_browser = manager_ready(app)
        require('no_browser_reuses_retained_model_window', no_browser and no_browser['contextValid'] and no_browser['sameModel']
                and no_browser['contextWindow'] == second and app.call('shell-windows') == [], state=state(app))
        app.call('pasteboard-write', text='no-browser-sentinel')
        app.call('space-manager-menu', space=s2, node=pin, item='Copy Link')
        copied_without_browser = app.call('pasteboard')
        with open(app.call('save')) as stream: retained_snapshot = json.load(stream)
        retained_space = next(s for s in retained_snapshot['spaces'] if s['id'] == s2)
        require('no_browser_copy_link_retains_model_ids', app.call('shell-windows') == []
                and len(retained_snapshot['windows']) == 1 and retained_snapshot['windows'][0]['id'] == second
                and any(n.get('tab', {}).get('_0', {}).get('id') == pin for n in retained_space['pinned'])
                and copied_without_browser == pin_url_before_close,
                snapshot=retained_snapshot, pasteboard=copied_without_browser)
        app.call('window-reopen'); app.call('library-open'); recovered = manager_ready(app)
        require('last_window_reopen_recovers', len(app.call('shell-windows')) == 1 and recovered['contextWindow'] == app.call('shell-windows')[0]['id']
                and recovered['contextValid'], state=recovered)
        # Native nil-target undo stays menu-owned. Other context keys exercise
        # the same OEApplication path and leave no panels or command bar open.
        # A selected Today tab makes accidental browser Cmd+W observable as an archive.
        app.call('window-focus', id=second, activate=True); app.call('select', tab=other)
        close_fixture = app.tab(other)
        app.call('library-open')
        key_states = []
        for key, modifiers in [('l', ['cmd']), ('escape', []), ('return', [])]:
            library_key(app, key, modifiers)
            key_states.append(dict(key=key, library=app.call('space-manager-lifecycle'), bar=app.call('commandbar-state')))
        library_key(app, 't', ['cmd'])
        app.call('key', key='escape', route='app')
        bar_after_escape = app.call('commandbar-state')
        app.call('library-open')
        tabs_before_close = sorted(t['id'] for t in app.call('tabs'))
        selected_before_close = app.call('window-state')['selected']
        library_key(app, 'w', ['cmd'])
        tabs_after_close = sorted(t['id'] for t in app.call('tabs'))
        require('library_focus_keys', close_fixture['section'] == 'today' and close_fixture['selected'] and selected_before_close == other
                and all(k['library']['visible'] and k['library']['key'] for k in key_states)
                and all(not k['bar'].get('presented') for k in key_states if k['key'] == 'escape')
                and not bar_after_escape.get('presented') and not state(app)['visible']
                and len(app.call('shell-windows')) == 1 and tabs_before_close == tabs_after_close,
                keys=key_states, closeFixture=close_fixture, selectedBeforeClose=selected_before_close, barAfterEscape=bar_after_escape, tabsBeforeClose=tabs_before_close, tabsAfterClose=tabs_after_close, state=state(app))
        app = sidebar_completion_a3_checks(app, results, require, evidence, tmp, launch)
        sidebar_tab_switcher_checks(app, require, tmp)

        app = sidebar_favicon_checks(app, require, tmp, launch)
        sidebar_intents_menu_checks(app, results, require, tmp)
        app = sidebar_completion_archive_checks(app, launch, results, require, evidence, tmp)
    finally:
        dialogs, cleanup_errors = [], []
        owned_pids.update(space_manager_owned_processes(bundle))
        for instance in apps:
            if instance.closed: continue
            try:
                before = instance.call('space-manager-state')
                dialogs += [w for w in before['windows'] if w['visible'] and (w['sheet'] or w['attachedSheet'] or 'Alert' in w['class'])]
                # Cancel existing dialogs before closing their owner, even when
                # a failure or timeout interrupted a menu/manager operation.
                if instance.call('shell-windows'): instance.call('dismiss')
                instance.call('library-close')
                for row in instance.call('shell-windows'):
                    instance.call('window-focus', id=row['id']); instance.call('window-close')
            except Exception as error: cleanup_errors.append(str(error))
            finally: instance.quit()
        remaining = space_manager_owned_processes(bundle)
        for pid in remaining:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        deadline = time.monotonic() + 3
        while space_manager_owned_processes(bundle) and time.monotonic() < deadline: time.sleep(.05)
        remaining = space_manager_owned_processes(bundle)
        for pid in remaining:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        windows = space_manager_owned_windows(owned_pids)
        receipt = {'ok': not dialogs and not cleanup_errors and not remaining and not windows
                   and all(not getattr(instance, 'quit_report', {}).get('forced') for instance in apps),
            'dialogsAtCleanup': dialogs, 'errors': cleanup_errors, 'remainingProcesses': remaining,
            'remainingWindows': windows, 'ownedPIDs': sorted(owned_pids), 'preferenceDomain': bundle_id,
            'quit': [getattr(instance, 'quit_report', {}) for instance in apps]}
        # Write even if another assertion is propagating.
        with open(os.path.join(evidence, 'cleanup.json'), 'w') as stream: json.dump(receipt, stream, indent=2)
        dict.__setitem__(results, 'cleanup_no_owned_windows', receipt)
        subprocess.run(['defaults', 'delete', bundle_id], capture_output=True)
        for folder in (root, cache, bundle_dir): shutil.rmtree(folder, ignore_errors=True)
        if not receipt['ok']: raise AssertionError('Space Manager cleanup failed: ' + json.dumps(receipt))


# ---------------------------------------------------------------------------
# Suite `page`, Section 8 helper B rows (page-platform §8.3: A1, A2, K1, K2,
# D1, D2, D4, H1-H4). One function per row group; `page_checks` calls them.

PAGE_FIXTURES = os.path.join(ROOT, "tools", "e2e", "fixtures", "page-platform")


def page_tools_fixture_server():
    """Serves tools/e2e/fixtures/page-platform on 127.0.0.1 with no-store caching (page tools rows; no external network)."""
    import http.server
    import threading
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=PAGE_FIXTURES, **kwargs)
        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def _menu_row(app, command):
    return next((r for r in app.call("menu-state") if r["id"] == command), None)


def _blocked(reason, **evidence):
    return dict(evidence, status="BLOCKED", reason=reason)


def _menu_checks_row(menu, expected):
    """Checkmarks (or hidden flags) as the validated menu shows them, one entry per step."""
    return {"ok": menu == expected, "menu": menu, "expected": expected}


def _toasts(app):
    return app.call("toasts")["toasts"]


def page_tools_appearance_checks(app, results, port, style):
    """A1, A2: View ▸ Appearance reaches prefers-color-scheme without a reload, and stays after a
    navigation (EP-9a SetChromeColorScheme + EP-9b fork patch 0505 CefSetWebsiteColorScheme)."""
    tab = app.call("open", url="http://127.0.0.1:%d/scheme.html" % port)["id"]
    app.call("wait", tab=tab)
    state = lambda: app.eval(tab, "window.schemeState()")
    def until_dark(value, event=False):
        # event: also wait for the page's change event for this switch (it fires at the next frame).
        want = "dark" if value else "light"
        return wait_until(lambda: (lambda s: s if s["dark"] is value and (not event or s["changes"][-1:] == [want])
                                   else None)(state()), timeout=8, step=.2) or state()
    ids = ("appearance-automatic", "appearance-light", "appearance-dark")
    def checks():
        return {i: (_menu_row(app, i) or {}).get("checked") for i in ids}
    try:
        # A1: the website value wins over the app's appearance, both ways.
        app.call("command", id="appearance-automatic")
        app.call("appearance", name="light")
        start = until_dark(False)
        app.call("command", id="appearance-dark")
        dark = until_dark(True)
        dark_checks, dark_stored = checks(), app.call("defaults", key="open.web.colorScheme")
        # 0505: Chrome recomputes the scheme after every navigation; the website value wins again.
        app.call("navigate", tab=tab, url="http://127.0.0.1:%d/scheme.html?nav=1" % port)
        app.call("wait", tab=tab)
        wait_until(lambda: app.eval(tab, "location.search") == "?nav=1" or None, timeout=8, step=.1)
        after_nav = until_dark(True)
        app.call("navigate", tab=tab, url="http://127.0.0.1:%d/scheme.html" % port)
        app.call("wait", tab=tab)
        wait_until(lambda: app.eval(tab, "location.search") == "" or None, timeout=8, step=.1)
        dark = until_dark(True)
        app.call("appearance", name="dark")
        app.call("command", id="appearance-light")
        light = until_dark(False)
        light_checks, light_stored = checks(), app.call("defaults", key="open.web.colorScheme")
        page_follows = (start["dark"] is False and dark["dark"] is True and light["dark"] is False
                        and dark["loadId"] == light["loadId"] and after_nav["dark"] is True)
        results["A1_appearance_light_dark_" + style] = {"ok": page_follows, "start": start, "websitesDark": dark,
                                                        "afterNavigation": after_nav, "websitesLight": light}
        want_dark = {"appearance-automatic": False, "appearance-light": False, "appearance-dark": True}
        want_light = {"appearance-automatic": False, "appearance-light": True, "appearance-dark": False}
        results["A1_appearance_stored_" + style] = {
            "ok": (dark_stored, light_stored) == ("dark", "light"), "stored": [dark_stored, light_stored]}
        # A2: Automatic follows the app's effective appearance, each time, without a reload.
        app.call("command", id="appearance-automatic")
        app.call("appearance", name="dark")
        follow_dark = until_dark(True, event=True)
        app.call("appearance", name="light")
        follow_light = until_dark(False, event=True)
        app.call("appearance", name="dark")
        follow_dark2 = until_dark(True, event=True)
        auto_checks = checks()
        want_auto = {"appearance-automatic": True, "appearance-light": False, "appearance-dark": False}
        results["A2_appearance_automatic_follows_app_" + style] = {
            "ok": follow_dark["dark"] is True and follow_light["dark"] is False and follow_dark2["dark"] is True
            and follow_dark2["loadId"] == dark["loadId"] and follow_dark2["changes"][-2:] == ["light", "dark"]
            and app.call("defaults", key="open.web.colorScheme") == "automatic",
            "states": [follow_dark, follow_light, follow_dark2]}
        results["A1_appearance_checkmarks_" + style] = _menu_checks_row(
            [dark_checks, light_checks, auto_checks], [want_dark, want_light, want_auto])
    finally:
        _try(lambda: app.call("appearance", name="system"))
    app.call("close", tab=tab)


def page_tools_clear_checks(app, results, port, style):
    """K1, K2: Clear Cookies and Refresh (interim before Site Control E2); Clear Cache disabled."""
    hosts = ["127.0.0.1", "localhost"]
    tabs = []
    for index, host in enumerate(hosts):
        tab = app.call("open", url="http://%s:%d/cookies.html" % (host, port))["id"]
        app.call("wait", tab=tab)
        app.eval(tab, "window.setFixtureCookie('k%d')" % (index + 1))
        tabs.append(tab)
    before = [app.eval(t, "document.cookie") for t in tabs]
    load_id = app.eval(tabs[0], "window.cookieLoadId")
    app.call("select", tab=tabs[0])
    wait_until(lambda: app.call("window-state")["selected"] == tabs[0], timeout=5, step=.1)
    enabled = (_menu_row(app, "clear-cookies-and-refresh") or {}).get("enabled")
    app.call("command", id="clear-cookies-and-refresh")
    reloaded = wait_until(lambda: (lambda v: v if v and v != load_id else None)(
        app.eval(tabs[0], "window.cookieLoadId")), timeout=10, step=.2)
    after = [app.eval(t, "document.cookie") for t in tabs]
    results["K1_clear_cookies_and_refresh_" + style] = {
        "ok": enabled is True and before == ["k1=127.0.0.1", "k2=localhost"] and bool(reloaded)
        and after == ["", "k2=localhost"],
        "enabled": enabled, "before": before, "after": after, "reloaded": bool(reloaded),
        "interim": "host cookies of the page's host via clearBrowsingData(origin:); Site Control E2 pending"}
    cache = _menu_row(app, "clear-cache-and-refresh") or {}
    results["K2_clear_cache_disabled_before_E2_" + style] = {"ok": cache.get("enabled") is False, "row": cache}
    for tab in tabs:
        app.call("close", tab=tab)


# Ids of the selected tabs of the DevTools front end (every tabbed pane, shadow roots included).
_DEVTOOLS_SELECTED_TABS = """(() => {
  const out = [];
  const walk = (root) => { for (const el of root.querySelectorAll('*')) {
    if (el.getAttribute('role') === 'tab' && el.getAttribute('aria-selected') === 'true') out.push(el.id || el.textContent.trim());
    if (el.shadowRoot) walk(el.shadowRoot); } };
  walk(document);
  return out;
})()"""


def page_tools_devtools_checks(app, results, port, style):
    """D1 (Console panel, EP-4a), D2 (Network, blocked on EP-4b)."""
    tab = app.call("open", url="http://127.0.0.1:%d/cookies.html" % port)["id"]
    app.call("wait", tab=tab)
    try:
        app.call("command", id="javascript-console")
        tabs = wait_until(lambda: (lambda ids: ids if "tab-console" in ids else None)(
            _try(lambda: app.call("devtools-frontend", tab=tab, js=_DEVTOOLS_SELECTED_TABS)) or []), timeout=20, step=.5)
        last = _try(lambda: app.call("devtools-frontend", tab=tab, js=_DEVTOOLS_SELECTED_TABS))
        windows = [w["title"] for w in app.call("windows") if w["visible"]]
        # Chrome style: IDC_DEV_TOOLS_CONSOLE; Alloy: the front end's DevToolsAPI.showPanel (EP-4b path).
        results["D1_javascript_console_panel_" + style] = {
            "ok": bool(tabs) and "tab-console" in tabs, "selectedTabs": last, "windows": windows}
    finally:
        _try(lambda: app.call("devtools-close", tab=tab))
        _try(lambda: app.call("dismiss"))
    if style != "alloy":
        # The real key path (OEApplication.sendEvent → page → unconsumed → menu): Cmd+Opt+J.
        closed = wait_until(lambda: _try(lambda: app.call("devtools-frontend", tab=tab, js="1")) is None, timeout=10, step=.25)
        try:
            app.call("focus", tab=tab)
            app.call("key", key="j", modifiers=["cmd", "opt"])
            keyed = wait_until(lambda: (lambda ids: ids if "tab-console" in ids else None)(
                _try(lambda: app.call("devtools-frontend", tab=tab, js=_DEVTOOLS_SELECTED_TABS)) or []), timeout=20, step=.5)
            results["D1_key_cmd_opt_j_" + style] = {"ok": bool(closed) and bool(keyed), "devtoolsClosedFirst": bool(closed),
                                                     "selectedTabs": keyed}
        finally:
            _try(lambda: app.call("devtools-close", tab=tab))
            _try(lambda: app.call("dismiss"))
    # D2 (EP-4b): Develop ▸ Network Inspector opens DevTools on the Network panel; a second
    # request with DevTools open switches an already open window to it.
    # Commands validate against the key window: the browser window, not a DevTools window.
    def focus_browser():
        app.call("window-focus", id=app.call("window-state")["id"], activate=True)
    try:
        focus_browser()
        app.call("command", id="network-inspector")
        net = wait_until(lambda: (lambda ids: ids if "tab-network" in ids else None)(
            _try(lambda: app.call("devtools-frontend", tab=tab, js=_DEVTOOLS_SELECTED_TABS)) or []), timeout=20, step=.5)
        focus_browser()
        app.call("command", id="javascript-console")
        back = wait_until(lambda: (lambda ids: ids if "tab-console" in ids else None)(
            _try(lambda: app.call("devtools-frontend", tab=tab, js=_DEVTOOLS_SELECTED_TABS)) or []), timeout=20, step=.5)
        focus_browser()
        app.call("command", id="network-inspector")
        again = wait_until(lambda: (lambda ids: ids if "tab-network" in ids else None)(
            _try(lambda: app.call("devtools-frontend", tab=tab, js=_DEVTOOLS_SELECTED_TABS)) or []), timeout=20, step=.5)
        results["D2_network_inspector_panel_" + style] = {"ok": bool(net) and bool(back) and bool(again),
            "first": net, "consoleAfter": back, "networkWhileOpen": again,
            "method": "DevToolsAPI.showPanel in the DevTools front end (no fork patch; Chrome's own Console command path)"}
    finally:
        _try(lambda: app.call("devtools-close", tab=tab))
        _try(lambda: app.call("dismiss"))
    app.call("close", tab=tab)


def page_tools_developer_mode_checks(app, results, port):
    """D3 (page-platform §4.10.3, Q6): Developer Mode per site. The menu title flips, a toast
    says the new state, and the URL field shows the full URL for that site only; Ctrl+D through
    the real key path turns it off. Pages that are not http(s) or file hide the item."""
    url = "http://127.0.0.1:%d/cookies.html?dev=1" % port
    tab = app.call("open", url=url)["id"]
    app.call("wait", tab=tab)
    field = lambda: app.call("window-state")["urlFieldText"]
    row = lambda: _menu_row(app, "toggle-developer-mode") or {}
    off_title, off_field = row().get("title"), field()
    app.call("menu-perform", id="toggle-developer-mode")
    on_toast = wait_until(lambda: (lambda t: t if t and t[0]["title"] == "Developer Mode On" else None)(app.call("toasts")["toasts"]), timeout=3, step=.05)
    on_field = wait_until(lambda: (lambda f: f if f.startswith("127.0.0.1:") else None)(field()), timeout=3, step=.05)
    on_title = row().get("title")
    # Another site keeps its plain host.
    other = app.call("open", url="http://localhost:%d/cookies.html?dev=2" % port)["id"]
    app.call("wait", tab=other)
    other_field = wait_until(lambda: (lambda f: f if f == "localhost" else None)(field()), timeout=3, step=.05)
    app.call("close", tab=other)
    app.call("select", tab=tab)
    wait_until(lambda: field().startswith("127.0.0.1:") or None, timeout=3, step=.05)
    # Ctrl+D (the registry shortcut) through OEApplication.sendEvent with the sidebar focused.
    app.call("menu-perform", id="reveal-tab-in-sidebar")
    app.call("key", key="d", modifiers=["ctrl"], route="app")
    off_toast = wait_until(lambda: (lambda t: t if t and t[0]["title"] == "Developer Mode Off" else None)(app.call("toasts")["toasts"]), timeout=3, step=.05)
    back_field = wait_until(lambda: (lambda f: f if f == "127.0.0.1" else None)(field()), timeout=3, step=.05)
    stored = app.call("defaults", key="open.developer.modeHosts")
    app.call("navigate", tab=tab, url="about:blank")
    wait_until(lambda: app.eval(tab, "location.href") == "about:blank" or None, timeout=5, step=.05)
    hidden = row().get("hidden")
    results["D3_developer_mode"] = {
        "ok": off_title == "Turn on Developer Mode for this site" and off_field == "127.0.0.1" and bool(on_toast)
              and on_field == "127.0.0.1:%d/cookies.html?dev=1" % port and on_title == "Turn off Developer Mode for this site"
              and bool(other_field) and bool(off_toast) and bool(back_field) and not stored and hidden is True,
        "titles": [off_title, on_title], "fields": [off_field, on_field, other_field, back_field], "stored": stored, "hiddenOnBlank": hidden}
    app.call("close", tab=tab)


def page_tools_apple_events_checks(app, results):
    """D4: Allow JavaScript from Apple Events (default off, checkmark)."""
    key, command = "open.developer.allowJavaScriptFromAppleEvents", "allow-js-apple-events"
    def step():
        return ((_menu_row(app, command) or {}).get("checked"), app.call("defaults", key=key))
    initial = step()
    app.call("command", id=command)
    on = step()
    app.call("command", id=command)
    off = step()
    results["D4_allow_js_apple_events_setting"] = {
        "ok": not initial[1] and on[1] is True and off[1] is False, "stored": [initial[1], on[1], off[1]]}
    results["D4_allow_js_apple_events_checkmark"] = _menu_checks_row(
        [initial[0], on[0], off[0]], [False, True, False])
    runpy.run_path(os.path.join(ROOT, "tools/e2e/applescript.py"))["javascript_gate_checks"](app, results)


def page_tools_troubleshooting_checks(app, results, tmp, port, style):
    """H1-H4: Task Manager, Record Trace + Stop, Copy Open Info, Cast hidden / media router off."""
    trace_dir = os.path.join(tmp, "traces")
    os.makedirs(trace_dir, exist_ok=True)
    app.call("troubleshooting-setup", traceDir=trace_dir, recordReveals=True)
    tab = app.call("open", url="http://127.0.0.1:%d/cookies.html" % port)["id"]
    app.call("wait", tab=tab)
    # H1
    try:
        app.call("command", id="task-manager")
        window = wait_until(lambda: next((w for w in app.call("windows")
                                          if w["visible"] and w["title"].startswith("Task Manager")), None), timeout=10, step=.25)
        state = app.call("troubleshooting-state")
        evidence = {"window": window, "shown": state["taskManagerShown"],
                    "titles": [w["title"] for w in app.call("windows") if w["visible"]]}
        if style == "alloy":
            # Chromium's window needs a Chrome style page; the App's pages are Chrome style
            # unless --style=alloy. H1 passes in Chrome style, so EP-10b's own window is not built.
            results["H1_task_manager_window_alloy"] = _blocked(
                "Alloy run: no Chrome style page for IDC_TASK_MANAGER_MAIN_MENU", **evidence)
        else:
            results["H1_task_manager_window"] = dict(evidence, ok=bool(window) and state["taskManagerShown"] == "yes")
    finally:
        _try(lambda: app.call("dismiss"))
    # H2
    rows0 = {i: (_menu_row(app, i) or {}).get("enabled") for i in ("record-trace", "cancel-trace")}
    app.call("command", id="record-trace")
    recording = wait_until(lambda: (lambda s: s if s["recording"] else None)(app.call("troubleshooting-state")), timeout=5, step=.1)
    rows1 = {i: (_menu_row(app, i) or {}).get("enabled") for i in ("record-trace", "cancel-trace")}
    time.sleep(2)
    # The sticky toast's real Stop button (Helper A's ToastCenter `toast-action`).
    recording_toast = next((t for t in _toasts(app) if t["title"] == "Recording Trace…" and not t["exiting"]), None)
    app.call("toast-action", index=0)
    saved = wait_until(lambda: (lambda s: s if s["lastTraceFile"] or s["lastTraceError"] else None)(
        app.call("troubleshooting-state")), timeout=60, step=.25) or app.call("troubleshooting-state")
    path = saved.get("lastTraceFile") or ""
    events = 0
    if path and os.path.isfile(path):
        with open(path) as stream:
            trace = json.load(stream)
        events = len(trace.get("traceEvents", [])) if isinstance(trace, dict) else 0
    saved_toast = wait_until(lambda: next((t for t in _toasts(app) if t["title"] == "Trace Saved" and not t["exiting"]), None), timeout=5, step=.1)
    if saved_toast:
        app.call("toast-action", index=0)  # Show in Finder (recorded, not shown)
    finder = app.call("troubleshooting-state")["reveals"][-1:] == [path]
    rows2 = {i: (_menu_row(app, i) or {}).get("enabled") for i in ("record-trace", "cancel-trace")}
    results["H2_record_trace_stop"] = {
        "ok": rows0 == {"record-trace": True, "cancel-trace": False} and bool(recording)
        and rows1 == {"record-trace": False, "cancel-trace": True}
        and os.path.dirname(path) == trace_dir and os.path.basename(path).startswith("Open Trace ") and path.endswith(".json")
        and events > 0 and bool(recording_toast) and recording_toast["sticky"] and recording_toast["accessory"] == "stop"
        and re.fullmatch(r"0:0[0-9]", recording_toast["subtitle"] or "") is not None
        and bool(saved_toast) and saved_toast["accessory"] == "show in finder" and finder
        and rows2 == {"record-trace": True, "cancel-trace": False},
        "menu": [rows0, rows1, rows2], "file": path, "traceEvents": events,
        "recordingToast": recording_toast, "savedToast": saved_toast, "showInFinder": finder,
        "error": saved.get("lastTraceError")}
    # Cancel: no file is kept.
    before_files = sorted(os.listdir(trace_dir))
    app.call("command", id="record-trace")
    wait_until(lambda: app.call("troubleshooting-state")["recording"], timeout=5, step=.1)
    app.call("command", id="cancel-trace")
    idle = wait_until(lambda: (lambda s: s if not s["tracing"] else None)(app.call("troubleshooting-state")), timeout=30, step=.25)
    results["H2_cancel_trace"] = {"ok": bool(idle) and sorted(os.listdir(trace_dir)) == before_files,
                                  "files": sorted(os.listdir(trace_dir))}
    # H3
    app.call("command", id="copy-open-info")
    text = app.call("pasteboard")
    lines = text.split("\n")
    shape = (len(lines) == 4 and re.fullmatch(r"Open \S+ \(\S+\)", lines[0])
             and re.fullmatch(r"Engine: Chromium 156\.0\.8078\.48, CEF \S+", lines[1])
             and lines[2].startswith("macOS ") and re.fullmatch(r"Mac: \S+ \((arm64|x86_64)\)", lines[3]))
    newest = (_toasts(app) or [{}])[0]
    results["H3_copy_open_info"] = {"ok": bool(shape) and "http" not in text and "/Users" not in text and "Arc" not in text
                                    and newest.get("title") == "Copied Open Info", "text": text, "toast": newest.get("title")}
    app.call("command", id="reveal-open-data")
    reveals = app.call("troubleshooting-state")["reveals"]
    root = app.call("ping")["root"]
    results["H_reveal_open_data"] = {"ok": reveals[-1:] == [root], "reveals": reveals, "root": root}
    # H4
    cast = _menu_row(app, "cast") or {}
    helpers = subprocess.run(["ps", "-axo", "pid,ppid,command"], capture_output=True, text=True).stdout.splitlines()
    pid = str(app.pid)
    children = [l for l in helpers if l.split(None, 2)[1:2] == [pid] and "Open Helper" in l]
    disabled = [l for l in children if re.search(r"--disable-features=\S*\bMediaRouter\b", l)]
    results["H4_media_router_off"] = {
        "ok": bool(children) and len(disabled) == len(children),
        "helpers": len(children), "helpersWithMediaRouterOff": len(disabled)}
    hidden = _menu_checks_row([cast.get("hidden"), cast.get("enabled")], [True, False])
    hidden["cast"] = cast
    results["H4_cast_menu_hidden"] = hidden
    app.call("close", tab=tab)


def _try(fn):
    try:
        return fn()
    except Exception:
        return None


def page_tools_checks(factory, results, tmp, style):
    """Section 8 helper B rows of the `page` suite."""
    server, port = page_tools_fixture_server()
    app = factory(urls=("http://127.0.0.1:%d/cookies.html" % port,), fresh=True)
    # Open's preferences domain is shared with other runs: restore what this group writes.
    keys = ("open.web.colorScheme", "open.developer.allowJavaScriptFromAppleEvents", "open.developer.modeHosts")
    saved = {key: app.call("defaults", key=key) for key in keys}
    try:
        for key in keys:
            app.call("defaults", key=key, value=None)
        app.call("window-frame", frame=[80, 60, 1360, 860])
        # The suite runs this group after others, each with its own app: make this window key and
        # Open active, so the menu validates against it (window commands need the key window).
        ws = app.call("window-state")
        app.call("window-focus", id=ws["id"], activate=True)
        app.call("wait", tab=app.call("tabs")[0]["id"])
        page_tools_apple_events_checks(app, results)
        page_tools_appearance_checks(app, results, port, style)
        page_tools_clear_checks(app, results, port, style)
        page_tools_devtools_checks(app, results, port, style)
        page_tools_developer_mode_checks(app, results, port)
        page_tools_troubleshooting_checks(app, results, tmp, port, style)
        page_tools_quit_with_devtools_check(app, results, saved)
    finally:
        if not app.closed:
            _try(lambda: app.call("dismiss"))
        _restore_defaults(app, saved)
        app.quit()
        server.shutdown()


def _restore_defaults(app, saved):
    """Restores keys of the shared io.github.sergeserb2.open domain through the App, or
    with `defaults` when the App can no longer answer (a crash must not leave keys behind)."""
    domain = getattr(app, "preferences_domain", "io.github.sergeserb2.open")
    for key, value in saved.items():
        restored = False
        if not app.closed:
            try:
                app.call("defaults", key=key, value=value)
                restored = True
            except Exception:
                pass
        if not restored:
            if value is None:
                subprocess.run(["defaults", "delete", domain, key], capture_output=True)
            elif isinstance(value, bool):
                subprocess.run(["defaults", "write", domain, key, "-bool", "true" if value else "false"], capture_output=True)
            elif isinstance(value, (list, dict)):
                runpy.run_path(os.path.join(ROOT, "tools/e2e/restore_defaults.py"))["write_collection"](key, value, domain)
            else:
                subprocess.run(["defaults", "write", domain, key, "-string", str(value)], capture_output=True)


def page_tools_quit_with_devtools_check(app, results, saved):
    """Quit while a DevTools window is open: OpenEngine holds the front end's browser
    (OEDevToolsClient) until OnBeforeClose, so quit must neither hang nor crash."""
    tab = app.call("tabs")[0]["id"]
    app.call("select", tab=tab)
    app.call("command", id="javascript-console")
    opened = wait_until(lambda: _try(lambda: app.call("devtools-frontend", tab=tab, js="1")) == 1, timeout=20, step=.5)
    _restore_defaults(app, saved)
    reports = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    started = time.time()
    app.quit()
    crashes = [f for f in (os.listdir(reports) if os.path.isdir(reports) else [])
               if f.startswith("Open") and os.path.getmtime(os.path.join(reports, f)) >= started - 1]
    report = app.quit_report
    results["D1_quit_with_devtools_open"] = {"ok": bool(opened) and report.get("ok") is True and not report.get("forced")
                                             and not crashes, "devtools": bool(opened), "quit": report, "crashReports": crashes}


def page_notification_checks(factory, results, tmp):
    """page-platform §8.3 N1–N4, N6: web notifications in the real App (Steps 7 and 16).

    macOS delivery needs the user's one-time Allow (U-N1). A normal run starts the App with
    OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION=record: the App logs its authorization request
    instead of showing the macOS prompt, so no human is needed, and the macOS-delivery rows
    report BLOCKED: U-N1 until macOS has authorized Open. For U-N1, run the suite once with
    OPEN_E2E_NOTIFICATION_PROMPT=1 and click Allow in the macOS prompt. The engine's own list and
    clicks come from EP-7 (fork patch 0504, `--open-automation` builds only). This suite writes no
    preferences keys.
    """
    import http.server
    import threading
    folder = os.path.join(ROOT, 'tools', 'e2e', 'fixtures', 'page-platform')

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=folder, **kw)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:%d' % server.server_address[1]
    prompt = os.environ.get('OPEN_E2E_NOTIFICATION_PROMPT') == '1'
    app = factory(urls=(origin + '/notify.html',), fresh=True,
                  extra_env={} if prompt else {'OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION': 'record'})
    pages = []

    def live_tab(url):
        def find():
            rows = [t for t in app.call('tabs') if t['url'] == url and t.get('page') and t['page']['live']]
            return rows[0] if rows else None
        tab = wait_until(find, timeout=20, step=.2)
        if not tab:
            raise AssertionError('no live tab for ' + url)
        wait_until(lambda: app.eval(tab['page']['identifier'], 'document.readyState') == 'complete', timeout=20, step=.2)
        pages.append(tab['page']['identifier'])
        return tab

    def sheet():
        try:
            return app.call('alert')
        except RuntimeError:
            return None

    def blocked(reason, **evidence):
        return dict(evidence, status='BLOCKED', reason=reason)

    try:
        app.call('window-frame', frame=[80, 60, 1360, 860])
        tab = live_tab(origin + '/notify.html')
        page = tab['page']['identifier']

        # N1: the user allows the site in Open's prompt (the real sheet button), Chromium shows
        # the banner, and the Allow asks macOS once (§4.5.3).
        before = app.call('notification-authorization')
        app.call('click', tab=page, selector='#ask')
        prompt_sheet = wait_until(sheet, timeout=10, step=.1)
        if prompt_sheet:
            app.call('alert', button='Allow')
        granted = wait_until(lambda: 'permission:granted' in app.eval(page, 'log'), timeout=10, step=.1)
        after = wait_until(lambda: (lambda s: s if len(s['requests']) > len(before['requests']) else None)(
            app.call('notification-authorization')), timeout=10, step=.1) or app.call('notification-authorization')
        entry = after['requests'][len(before['requests'])] if len(after['requests']) > len(before['requests']) else None
        expected = (('requested' if prompt else 'suppressed') if before['status'] == 'notDetermined'
                    else 'skipped:' + before['status'])
        results['N1_allow_asks_macos'] = {
            'ok': bool(prompt_sheet) and any(origin.split('//')[1].split(':')[0] in t for t in prompt_sheet['texts'])
                  and bool(granted) and entry == expected and len(after['requests']) == len(before['requests']) + 1,
            'sheet': prompt_sheet, 'granted': bool(granted), 'statusBefore': before['status'],
            'request': entry, 'expected': expected, 'requests': after['requests']}
        if prompt and before['status'] == 'notDetermined':
            print('U-N1: click Allow in the macOS notification prompt for Open (waiting up to 120 s)', flush=True)
            wait_until(lambda: app.call('notification-authorization')['status'] != 'notDetermined', timeout=120, step=1)
        app.call('click', tab=page, selector='#banner')
        shown = wait_until(lambda: app.eval(page, 'shown["Open N1 banner"] === true'), timeout=10, step=.1)
        results['N1_engine_display'] = {'ok': bool(shown), 'log': app.eval(page, 'log')}
        listed = app.call('notifications')
        if listed['authorization'] in ('authorized', 'provisional', 'ephemeral'):
            delivered = wait_until(lambda: [n for n in app.call('notifications')['delivered'] if n['title'] == 'Open N1 banner'],
                                   timeout=10, step=.2)
            if delivered:
                results['N1_macos_delivered'] = {'ok': True, 'delivered': delivered, 'authorization': listed['authorization']}
            else:
                # Seen on the M5 (2026-11-02): macOS reports Open authorized, Chromium shows the
                # banner (N1_engine_display), yet Notification Center's delivered list for Open.app
                # stays empty. Open cannot see why from inside the app (docs/followups.md); the
                # user confirms delivery by eye (U-N1). Never counted as a pass.
                results['N1_macos_delivered'] = blocked('U-N1: authorized, but macOS lists no delivered banner for Open.app; '
                                                        'the user confirms delivery (followups)', delivered=listed['delivered'],
                                                        authorization=listed['authorization'])
        else:
            results['N1_macos_delivered'] = blocked('U-N1: macOS has not authorized Open (status %s)' % listed['authorization'],
                                                    delivered=listed['delivered'])
        engine_titles = lambda: [n['title'] for n in app.call('notifications')['engine']]
        n1_listed = wait_until(lambda: 'Open N1 banner' in engine_titles() or None, timeout=5, step=.1)
        results['N1_engine_list'] = {'ok': bool(n1_listed), 'engine': app.call('notifications')['engine']}

        # N2: requireInteraction goes to the Alerts helper, whose bundle has the alert style and
        # shows as "Open" (§4.5.2).
        bundle = os.path.join(ROOT, 'build', app.config, 'Open.app', 'Contents')
        def plist(path):
            out = subprocess.run(['plutil', '-convert', 'json', '-o', '-', path], capture_output=True, text=True)
            return json.loads(out.stdout) if out.returncode == 0 else {}
        main_info = plist(os.path.join(bundle, 'Info.plist'))
        alerts_info = plist(os.path.join(bundle, 'Frameworks', 'Open Helper (Alerts).app', 'Contents', 'Info.plist'))
        helper_info = plist(os.path.join(bundle, 'Frameworks', 'Open Helper.app', 'Contents', 'Info.plist'))
        results['N2_bundles'] = {
            'ok': main_info.get('NSUserNotificationAlertStyle') == 'banner'
                  and alerts_info.get('NSUserNotificationAlertStyle') == 'alert'
                  and alerts_info.get('CFBundleDisplayName') == 'Open'
                  and alerts_info.get('CFBundleIdentifier') == 'io.github.sergeserb2.open.helper.alerts'
                  and 'NSUserNotificationAlertStyle' not in helper_info,
            'main': main_info.get('NSUserNotificationAlertStyle'),
            'alerts': {k: alerts_info.get(k) for k in ('NSUserNotificationAlertStyle', 'CFBundleDisplayName', 'CFBundleIdentifier')},
            'helper': helper_info.get('NSUserNotificationAlertStyle')}

        def alerts_helpers():
            app.discover_owned_processes()
            return sorted(pid for pid, path in app.owned_processes.items()
                          if path.endswith('Open Helper (Alerts).app/Contents/MacOS/Open Helper (Alerts)')
                          and app.process_path(pid) == path)
        before_helpers = alerts_helpers()
        app.call('click', tab=page, selector='#alert')
        alert_shown = wait_until(lambda: app.eval(page, 'shown["Open N2 alert"] === true'), timeout=10, step=.1)
        helpers = wait_until(alerts_helpers, timeout=15, step=.2)
        results['N2_alerts_helper'] = {'ok': bool(alert_shown) and bool(helpers) and not before_helpers,
                                       'shown': bool(alert_shown), 'helpersBefore': before_helpers, 'helpers': helpers or []}
        # EP-7: Chromium's own list has the alert too (macOS's list for Open.app does not: the
        # Alerts helper posts from its own bundle).
        n2_listed = wait_until(lambda: 'Open N2 alert' in engine_titles() or None, timeout=5, step=.1)
        results['N2_listed'] = {'ok': bool(n2_listed), 'engine': engine_titles()}

        # N3: a page in Space 2 asks to be shown while Space 1 is focused and the window is
        # minimized. DevTools Page.bringToFront calls the same WebContents::Activate →
        # ActivateContents as window.focus() in a notification click or a worker's
        # client.focus() (P1 path, §4.5.4).
        if app.style != 'chrome':
            results['N3_activation'] = {'status': 'SKIP', 'reason': 'P1 activation needs hosted tabs: run --style chrome (the App default)'}
        else:
            space1 = [s for s in app.call('spaces') if s['focused']][0]['id']
            space2 = app.call('space-create', title='Notify Space 2', profile='Default')
            url2 = origin + '/notify.html?space2'
            tab2 = app.call('open', url=url2)
            tab2_page = live_tab(url2)['page']
            app.call('space', space=space1)
            prepared = {'space1Focused': [s for s in app.call('spaces') if s['focused']][0]['id'] == space1,
                        'tabSelected': app.call('tab-state', tab=tab2['id'])['selected'], 'style': tab2_page['style']}
            app.call('window-miniaturize')
            prepared['miniaturized'] = bool(state_when(app, lambda st: st['miniaturized'], timeout=5, step=.1))
            app.call('events')
            app.call('devtools', tab=tab2_page['identifier'], method='Page.bringToFront')
            shown_state = state_when(app, lambda st: not st['miniaturized'] and st['isKeyWindow'], timeout=5, step=.05)
            # The Space switch lands on the next model turn after the activation request.
            focused = wait_until(lambda: (lambda f: f if f == space2 else None)([s for s in app.call('spaces') if s['focused']][0]['id']),
                                 timeout=5, step=.05) or [s for s in app.call('spaces') if s['focused']][0]['id']
            selected = app.call('tab-state', tab=tab2['id'])['selected']
            requests = [e for e in app.call('events') if e['type'] == 'tab-request' and e.get('request') == 'activate']
            results['N3_activation'] = {
                'ok': prepared['space1Focused'] and not prepared['tabSelected'] and prepared['miniaturized']
                      and prepared['style'] == 'chrome' and bool(shown_state) and focused == space2 and selected
                      and any(e['tab'] == tab2['id'] and e.get('space') == space2 for e in requests),
                'prepared': prepared, 'windowRestoredAndKey': bool(shown_state), 'focusedSpace': focused, 'space2': space2,
                'selected': selected, 'requests': requests}
            # N3 click: the banner's click (EP-7's real click path) runs the page's onclick, whose
            # focus() selects the tab through P1; Open's fallback sees the page answered.
            app.call('space', space=space1)
            other_n3 = app.call('open', url=origin + '/links.html')['id']
            wait_until(lambda: not app.call('tab-state', tab=tab['id'])['selected'] or None, timeout=5, step=.05)
            banner = next((n for n in app.call('notifications')['engine'] if n['title'] == 'Open N1 banner'), None)
            clicked = app.call('notification-click', id=banner['id']) if banner else {'clicked': False}
            via_page = wait_until(lambda: app.call('tab-state', tab=tab['id'])['selected'] or None, timeout=5, step=.05)
            time.sleep(0.8)
            clicks = app.call('notifications')['clicks']
            results['N3_notification_click'] = {
                'ok': bool(banner) and clicked['clicked'] and 'click:Open N1 banner' in app.eval(page, 'log') and bool(via_page)
                      and bool(clicks) and clicks[-1]['action'] == 'page',
                'clicked': clicked, 'selected': bool(via_page), 'router': clicks[-1:] if clicks else []}
            app.call('close', tab=other_n3)

        # N4: a page whose click handler does not call focus(): after 500 ms Open selects the
        # most recently active tab with the notification's origin (§4.5.4 fallback, EP-6).
        nf_url = origin + '/notify.html?nofocus'
        nf_tab = app.call('open', url=nf_url)
        nf_page = live_tab(nf_url)['page']['identifier']
        wait_until(lambda: app.eval(nf_page, "!!document.getElementById('banner') || null"), timeout=10, step=.1)
        app.call('click', tab=nf_page, selector='#banner')
        wait_until(lambda: app.eval(nf_page, 'shown["Open N1 banner"] === true'), timeout=10, step=.1)
        # Another origin (localhost, not 127.0.0.1), so the fallback has one candidate tab.
        away = app.call('open', url=origin.replace('127.0.0.1', 'localhost') + '/links.html')['id']
        wait_until(lambda: not app.call('tab-state', tab=nf_tab['id'])['selected'] or None, timeout=5, step=.05)
        nf_ids = [n['id'] for n in app.call('notifications')['engine'] if n['title'] == 'Open N1 banner']
        # The same tag replaces the first page's banner: the newest id belongs to this page.
        clicked4 = app.call('notification-click', id=nf_ids[-1]) if nf_ids else {'clicked': False}
        early = app.call('tab-state', tab=nf_tab['id'])['selected']
        time.sleep(0.2)
        before_deadline = app.call('tab-state', tab=nf_tab['id'])['selected']
        fallback = wait_until(lambda: app.call('tab-state', tab=nf_tab['id'])['selected'] or None, timeout=3, step=.05)
        clicks4 = app.call('notifications')['clicks']
        results['N4_click_fallback_selects_tab'] = {
            'ok': clicked4['clicked'] and 'click:Open N1 banner' in app.eval(nf_page, 'log') and not early and not before_deadline
                  and bool(fallback) and bool(clicks4) and clicks4[-1]['action'] == 'fallback' and clicks4[-1]['tab'] == nf_tab['id'],
            'selectedAtClick': early, 'selectedAt200ms': before_deadline, 'selectedAfter': bool(fallback), 'router': clicks4[-1:]}
        app.call('close', tab=away)

        # N6: a service worker notification outlives its tab (the engine still lists it with
        # no tab of its page open); its click opens the target in a new Today tab.
        sw_url = origin + '/notify-sw.html'
        sw_tab = app.call('open', url=sw_url)
        sw_page = live_tab(sw_url)['page']['identifier']
        # The fixture defines workerReady in its script: wait for the load before reading it.
        app.call('wait', tab=sw_tab['id'])
        wait_until(lambda: app.eval(sw_page, 'typeof workerReady') == 'object' or None, timeout=10, step=.1)
        ready = app.eval(sw_page, 'workerReady')
        titles = app.eval(sw_page, 'showWorkerNotification(%s)' % json.dumps(origin + '/notify.html?from=worker'))
        app.call('close', tab=sw_tab['id'])
        gone = wait_until(lambda: not [t for t in app.call('tabs') if t['url'] == sw_url], timeout=10, step=.2)
        script = ('navigator.serviceWorker.getRegistration("/").then(r => r ? r.getNotifications() : [])'
                  '.then(list => list.map(n => n.title))')
        later = app.eval(page, script)
        # The worker's notification outlives its tab in Chromium's own list (EP-7). The page-side
        # getNotifications() is macOS's list: it can only see it once macOS authorized Open (U-N1).
        authorized = app.call('notifications')['authorization'] in ('authorized', 'provisional', 'ephemeral')
        engine_after = [n['title'] for n in app.call('notifications')['engine']]
        results['N6_engine_display'] = {'ok': ready is True and bool(gone) and 'Open N6 worker' in engine_after,
                                        'ready': ready, 'titles': titles, 'tabClosed': bool(gone), 'engineAfterClose': engine_after,
                                        'pageListAfterClose': later,
                                        'note': "getNotifications() reads macOS's delivered list (see N1_macos_delivered); not asserted"}
        # Its click (EP-7) reaches the worker, whose clients.openWindow opens a new tab (P1 didOpen).
        worker_note = next((n for n in app.call('notifications')['engine'] if n['title'] == 'Open N6 worker'), None)
        target = origin + '/notify.html?from=worker'
        clicked6 = app.call('notification-click', id=worker_note['id']) if worker_note else {'clicked': False}
        opened6 = wait_until(lambda: [t for t in app.call('tabs') if 'from=worker' in t['url']], timeout=20, step=.2)
        n6 = {'ok': bool(worker_note) and clicked6['clicked'] and bool(opened6),
                                         'notification': worker_note, 'clicked': clicked6, 'opened': opened6,
                                         'tabs': [t['url'] for t in app.call('tabs')], 'pages': [p['url'] for p in app.call('pages')],
                                         'events': [e for e in app.call('events') if e['type'] in ('tab-request', 'open', 'didOpen')][-5:]}
        if not n6['ok'] and worker_note and clicked6['clicked']:
            # The click reaches Chromium (EP-7's real click path) and the worker's notificationclick,
            # but clients.openWindow() creates no page Open hosts (2026-11-02: no OEWebContent, no
            # tab-strip request). page-platform §2.2 assumed P1 handles it; it does not
            # (docs/followups.md, "Notifications (clients.openWindow)"). Never counted as a pass.
            n6 = dict(n6, status='BLOCKED', reason='P1: clients.openWindow from a service worker opens no page in Open (followups)')
            n6.pop('ok')
        results['N6_click_opens_tab'] = n6
        for t in opened6 or []:
            app.call('close', tab=t['id'])
    finally:
        # Close what the suite showed (Notification Center keeps delivered banners after U-N1).
        for identifier in pages:
            try:
                app.eval(identifier, 'typeof closeAll === "function" ? closeAll() : 0', timeout=5)
                app.eval(identifier, 'navigator.serviceWorker.getRegistration("/").then(r => r ? r.getNotifications() : [])'
                                     '.then(list => { list.forEach(n => n.close()); return list.length; })', timeout=5)
            except Exception:
                pass  # The page may be closed already; quit ends the rest.
        app.quit()
        server.shutdown()
        server.server_close()


PAGE_FIXTURES = os.path.join(ROOT, 'tools', 'e2e', 'fixtures', 'page-platform')


def page_translate_checks(factory, results, tmp):
    """page-platform §8.3 X1–X6: on-device page translation in the real App.

    Runs on the automation build's fixture backend (OPEN_AUTOMATION_TRANSLATE_BACKEND=fixture, a
    French → English word list) so the whole pipeline runs without Apple's language assets; the
    row X1_apple runs the same flow on Apple's backend when French → English is installed, else it
    reports BLOCKED (U-X1). The never-translate list lives in Open's preferences domain: the suite
    restores it in `finally`.
    """
    server, origin = _static_server(PAGE_FIXTURES)
    app = factory(urls=(origin + '/fr.html',), fresh=True, extra_env={'OPEN_AUTOMATION_TRANSLATE_BACKEND': 'fixture'})
    # Open's preferences domain is shared by every run: reset the translation keys at the start and
    # restore them in `finally`.
    translate_keys = ('open.translate.neverTranslateHosts', 'open.translate.enabled')
    hosts_key = translate_keys[0]
    saved = {}
    availability = None

    def st():
        return app.call('translate', action='state')

    def state_is(name, timeout=15):
        return wait_until(lambda: (lambda s: s if s['state'] == name else None)(st()), timeout=timeout, step=.1)

    def body(tab):
        return app.eval(tab, 'document.body.innerHTML')

    def texts(tab):
        return app.eval(tab, '''(() => ({ p1: document.getElementById('p1').textContent, p2: document.getElementById('p2').innerHTML,
          p3: document.getElementById('p3').innerHTML, brand: document.getElementById('brand').textContent,
          send: document.getElementById('send').textContent, placeholder: document.getElementById('address').getAttribute('placeholder'),
          value: document.getElementById('search').getAttribute('value'), title: document.getElementById('title').getAttribute('title'),
          boldSame: document.getElementById('bold') === window.__boldRef, text: document.body.innerText }))()''')

    try:
        for key in translate_keys:
            saved[key] = app.call('defaults', key=key)
            app.call('defaults', key=key, value=None)
        app.call('window-frame', frame=[80, 60, 1360, 860])
        ws = app.call('window-state')
        app.call('window-focus', id=ws['id'], activate=True)
        # X5: a request filter on every translation-shaped request, before any page work.
        app.call('filter', block=['translate', 'googleapis', 'gstatic'])
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        offered = state_is('offered')
        s0 = st()
        original = body(tab)
        app.eval(tab, "window.__boldRef = document.getElementById('bold'); true")
        results['X1_offer'] = {'ok': bool(offered) and s0['source'] == 'fr' and s0['target'] == 'en' and s0['button']['shown']
            and s0['button']['title'] == 'Translation Available' and s0['button']['frame'][:2] == [8, 88]
            and s0['button']['frame'][3] == 28 and s0['backend'] == 'fixture', 'state': s0}

        # Context menu: Open's own "Translate to English" while the page has an offer.
        app.call('events')
        app.call('policy', contextMenu='record')
        app.call('rightclick', tab=tab, x=600, y=500)
        menu = wait_until(lambda: [e for e in app.call('events') if e['type'] == 'contextMenu'], timeout=5) or []
        app.call('policy', contextMenu='')
        items = menu[-1].get('openItems', []) if menu else []
        results['X1_context_menu_item'] = {'ok': 'Translate to English' in items, 'openItems': items}

        # The popover through the real status button, then Esc through the real key path.
        app.call('translate', action='offer')
        # The window server lists the panel after the order-front commits: read it a moment later.
        pop = (wait_until(lambda: (lambda p: p if p.get('aboveWindow') else None)(st()['popover']), timeout=3, step=.05)
               or st()['popover'])
        # The in-app snapshot does not stack child panels; capture the panel window alone.
        shot(app, 'page-translate-popover.png', window=pop.get('window'))
        app.call('key', key='escape', route='app')
        closed = wait_until(lambda: not st()['popover']['presented'], timeout=3, step=.05)
        # Geometry (screen points, y up): the body stays 8 pt inside the window (the panel has a 14 pt
        # shadow margin), and the arrow tip sits 2 pt under the status button [8, 88, W − 16, 28].
        win = app.call('window-state')['frame']
        f = pop.get('frame') or [0, 0, 0, 0]
        tip_y = f[1] + f[3] - 14
        button_bottom = win[1] + win[3] - (88 + 28)
        results['X1_popover_offer_and_escape'] = {'ok': pop['presented'] and pop['title'] == 'Translate this page to English?'
            and pop['buttons'] == ['Translate', 'Options'] and bool(closed) and pop.get('aboveWindow') is True
            and f[0] + 14 >= win[0] + 8 - 0.5 and abs(tip_y - (button_bottom - 2)) <= 1,
            'popover': pop, 'window': win, 'tipY': tip_y, 'buttonBottom': button_bottom}

        app.call('translate', action='translate')
        done = state_is('translated')
        s1 = st()
        t = wait_until(lambda: (lambda v: v if v['send'] == 'Send' and 'sometimes' in v['p3'] else None)(texts(tab)), timeout=15, step=.2) or texts(tab)
        lang = app.call('translate', action='detect', text=t['text'])
        results['X1_translate'] = {'ok': bool(done) and lang['language'] != 'fr' and t['brand'] == 'Maison Dupont'
            and t['send'] == 'Send' and t['placeholder'] == 'Your address' and t['value'] == 'Search' and t['title'] == 'Title of the page'
            and '<b id="bold">very important</b>' in t['p2'] and t['boldSame'] is True
            and '<i>sometimes</i>' in t['p3'] and s1['fallbackUnits'] >= 1
            and s1['button']['title'] == 'Translated' and 'Translated to English' in s1['toasts'] and not s1['popover']['presented'],
            'detected': lang, 'texts': {k: v for k, v in t.items() if k != 'text'}, 'state': s1}
        # The <i> sentence: the fixture translator drops its markers, so its text nodes are translated
        # one by one and the <i> element stays (R-3 fallback).
        italic = app.eval(tab, "document.querySelector('#p3 i') ? document.querySelector('#p3 i').textContent : null")
        results['X1_marker_fallback'] = {'ok': italic == 'sometimes' and s1['fallbackUnits'] >= 1, 'italic': italic, 'fallbackUnits': s1['fallbackUnits']}
        stats = app.call('filter-stats')
        results['X5_no_network'] = {'ok': stats.get('blocked') == 0 and not stats.get('recent'), 'filterStats': stats,
            'method': 'profile request filter on translate/googleapis/gstatic installed before the page loaded'}

        # X2: Show Original restores the DOM byte for byte.
        app.call('translate', action='revert')
        back = state_is('offered')
        restored = wait_until(lambda: body(tab) == original, timeout=5, step=.1)
        s2 = st()
        results['X2_revert'] = {'ok': bool(back) and bool(restored) and 'Translated back to French' in s2['toasts']
            and app.eval(tab, "document.getElementById('bold') === window.__boldRef") is True and s2['button']['title'] == 'Translation Available',
            'equal': body(tab) == original, 'state': s2}

        # X6: Edit ▸ Undo Translate reverts. Cmd+Z through the real key path with the sidebar focused,
        # like every window undo in Open: a focused page sends undo: to Chromium's own editing undo.
        app.call('translate', action='translate')
        state_is('translated')
        undo_title = st()['undoTitle']
        app.call('menu-perform', id='reveal-tab-in-sidebar')
        menu_title = next((r['title'] for r in app.call('menu-state') if r['id'] == 'undo'), None)
        app.call('key', key='z', modifiers=['cmd'], route='app')
        undone = wait_until(lambda: body(tab) == original, timeout=5, step=.1)
        s6 = st()
        results['X6_undo'] = {'ok': undo_title == 'Translate' and menu_title == 'Undo Translate' and bool(undone) and s6['state'] == 'offered',
            'undoTitle': undo_title, 'menuTitle': menu_title, 'state': s6['state']}
        app.call('key', key='z', modifiers=['cmd', 'shift'], route='app')
        redone = wait_until(lambda: (lambda v: v if v['send'] == 'Send' else None)(texts(tab)), timeout=8, step=.2)
        results['X6_redo'] = {'ok': bool(undone) and bool(redone) and st()['state'] == 'translated', 'state': st()['state']}
        app.call('translate', action='revert')
        state_is('offered')
        wait_until(lambda: body(tab) == original, timeout=5, step=.1)

        # X3: a same-document navigation keeps translated mode; the new paragraph is translated.
        spa_tab = app.call('open', url=origin + '/fr-spa.html')['id']
        app.call('wait', tab=spa_tab)
        state_is('offered')
        app.call('translate', action='translate')
        state_is('translated')
        added = wait_until(lambda: app.eval(spa_tab, "(() => { const p = document.getElementById('added'); return p && !/paragraphe/.test(p.textContent) ? p.textContent : null })()"),
                           timeout=10, step=.2)
        s3 = st()
        results['X3_same_document'] = {'ok': bool(added) and 'paragraph' in (added or '') and s3['state'] == 'translated'
            and app.eval(spa_tab, 'location.search') == '?vue=2', 'added': added, 'state': s3['state']}

        # Q12: a new page of the same host in this tab translates by itself until Show Original.
        app.call('navigate', tab=spa_tab, url=origin + '/fr.html')
        app.call('wait', tab=spa_tab)
        auto = wait_until(lambda: (lambda v: v if v and v.startswith('This is') else None)(
            app.eval(spa_tab, "document.getElementById('p1') && document.getElementById('p1').textContent")), timeout=15, step=.2)
        sq = st()
        results['X3_same_host_auto_translate'] = {'ok': bool(auto) and sq['state'] == 'translated' and sq['sticky'] == '127.0.0.1', 'p1': auto, 'state': sq['state']}
        app.call('translate', action='revert')
        state_is('offered')

        # X4: Never Translate This Site hides the offer; a reload offers nothing; Settings reset brings it back.
        app.call('translate', action='never')
        hidden = wait_until(lambda: (lambda s: s if s['state'] == 'idle' and not s['button']['shown'] else None)(st()), timeout=5, step=.1)
        hosts = app.call('defaults', key=hosts_key)
        app.call('navigate', tab=spa_tab, url=origin + '/fr.html?again=1')
        app.call('wait', tab=spa_tab)
        probed = wait_until(lambda: (lambda s: s if s['probedDocument'] == s.get('document') else None)(st()), timeout=10, step=.1)
        time.sleep(1)
        after_reload = st()
        reset = app.call('translate', action='reset')
        app.call('navigate', tab=spa_tab, url=origin + '/fr.html?again=2')
        app.call('wait', tab=spa_tab)
        again = state_is('offered')
        results['X4_never_and_reset'] = {'ok': bool(hidden) and hosts == ['127.0.0.1'] and bool(probed) and after_reload['state'] == 'idle'
            and not after_reload['button']['shown'] and reset['neverTranslateHosts'] == [] and bool(again),
            'hosts': hosts, 'afterReload': after_reload['state'], 'reset': reset, 'again': bool(again)}

        # Review r2 rows. The runtime stays installed (inactive) in the page's main world after Show
        # Original (Blocked on P7), so the page can drive it directly like the shell does.
        app.call('navigate', tab=spa_tab, url=origin + '/fr.html?r2=1')
        app.call('wait', tab=spa_tab)
        state_is('offered')
        app.call('translate', action='translate')
        state_is('translated')
        wait_until(lambda: (lambda v: v if v['send'] == 'Send' else None)(texts(spa_tab)), timeout=15, step=.2)
        # Page-owned structure: the page replaces #p2's translated children; Show Original keeps
        # the page's new content and does not bring the old text and <b> back.
        app.eval(spa_tab, "document.getElementById('p2').replaceChildren(document.createTextNode('Nouveau contenu de la page.')); true")
        time.sleep(1)   # the mutation debounce (300 ms) queues and translates the new text
        app.call('translate', action='revert')
        state_is('offered')
        p2_after = wait_until(lambda: (lambda v: v if v == 'Nouveau contenu de la page.' else None)(
            app.eval(spa_tab, "document.getElementById('p2').innerHTML")), timeout=5, step=.1) or app.eval(spa_tab, "document.getElementById('p2').innerHTML")
        p1_after = app.eval(spa_tab, "document.getElementById('p1').textContent")
        results['X2_revert_keeps_page_structure'] = {'ok': p2_after == 'Nouveau contenu de la page.' and p1_after.startswith('Ceci est'),
            'p2': p2_after, 'p1': p1_after}
        # A result for text the page changed while its batch was out is dropped.
        stale = app.eval(spa_tab, '''(async () => {
          const t = window.__openTranslate; t.start();
          const b = await t.nextBatch();
          const unit = b.units.find((u) => u.text.startsWith('Ceci est'));
          document.getElementById('p1').firstChild.data = 'Texte changé par la page.';
          const r = t.apply(b.id, b.units.map((u) => 'TRANSLATED ' + u.text));
          const out = { p1: document.getElementById('p1').textContent, title: document.getElementById('title').textContent,
            hadUnit: !!unit, applied: r.applied, units: b.units.length };
          t.restore();
          return out; })()''')
        results['X_stale_result_dropped'] = {'ok': stale['hadUnit'] and stale['p1'] == 'Texte changé par la page.'
            and stale['title'].startswith('TRANSLATED') and stale['applied'] == stale['units'] - 1, 'result': stale}
        # <html translate="no"> opts the whole page out: translating changes no text. (The fixture's
        # name must not contain "translate": X5's request filter blocks those URLs.)
        app.call('navigate', tab=spa_tab, url=origin + '/fr-optout.html')
        app.call('wait', tab=spa_tab)
        on_nt = wait_until(lambda: app.eval(spa_tab, "location.pathname === '/fr-optout.html' && document.readyState === 'complete' || null"),
                           timeout=10, step=.1)
        before_nt = app.eval(spa_tab, 'document.body.innerHTML')
        nt_state = (state_is('offered', timeout=5) or st())['state']
        if nt_state == 'offered':
            app.call('translate', action='translate')
            state_is('translated')
            time.sleep(1)
        after_nt = app.eval(spa_tab, 'document.body.innerHTML')
        results['X_root_notranslate'] = {'ok': bool(on_nt) and before_nt == after_nt and 'Ceci est' in after_nt, 'state': nt_state,
            'equal': before_nt == after_nt, 'before': before_nt[:300], 'after': after_nt[:300], 'navigated': bool(on_nt)}
        if st()['state'] in ('translated', 'translating'):
            app.call('translate', action='revert')
            state_is('offered')
        # A page that finishes loading while its window is minimized offers once the window is back.
        app.call('menu-perform', id='minimize-window')
        mini = state_when(app, lambda w: w['miniaturized'], timeout=5, step=.1)
        app.call('navigate', tab=spa_tab, url=origin + '/fr.html?minimized=1')
        app.call('wait', tab=spa_tab)
        wait_until(lambda: app.eval(spa_tab, "location.search === '?minimized=1' && document.readyState === 'complete' || null"), timeout=10, step=.1)
        time.sleep(1)
        while_hidden = st()
        app.call('window-deminiaturize')
        state_when(app, lambda w: not w['miniaturized'], timeout=5, step=.1)
        shown = state_is('offered', timeout=10)
        results['X_offer_after_minimized_load'] = {'ok': bool(mini) and while_hidden['state'] == 'idle'
            and while_hidden['probedDocument'] != while_hidden.get('document') and bool(shown),
            'hidden': {k: while_hidden.get(k) for k in ('state', 'probedDocument', 'document')}, 'offered': bool(shown)}
        ws2 = app.call('window-state')
        app.call('window-focus', id=ws2['id'], activate=True)

        # Idle: with the page translated and nothing changing, the shell waits on one promise
        # (no timer, no polling): the batch count does not move for 2 s.
        app.call('translate', action='translate')
        state_is('translated')
        time.sleep(1)
        b0 = st()['pulls']; time.sleep(2); b1 = st()['pulls']
        results['X_idle_no_polling'] = {'ok': b0 == b1 and st()['loopRunning'], 'pulls': [b0, b1]}
        shot(app, 'page-translate-translated.png')
        app.call('translate', action='revert')

        # X1 on Apple's backend: only when French → English is installed (no download prompt in e2e).
        availability = app.call('translate', action='availability', source='fr', target='en')['status']
        if availability != 'installed':
            results['X1_apple_backend'] = {'status': 'BLOCKED', 'reason': 'U-X1: French → English is %s, not installed on this Mac' % availability}
    finally:
        try:
            app.call('filter', block=[])
            for key, value in saved.items():
                app.call('defaults', key=key, value=value)
        except Exception:
            pass
        app.quit()
        server.shutdown()

    if availability == 'installed':
        server, origin2 = _static_server(PAGE_FIXTURES)
        apple = factory(urls=(origin2 + '/fr.html',), fresh=True)
        try:
            tab = apple.call('tabs')[0]['id']
            apple.call('wait', tab=tab)
            wait_until(lambda: apple.call('translate', action='state')['state'] == 'offered', timeout=15, step=.1)
            apple.call('translate', action='translate')
            done = wait_until(lambda: apple.call('translate', action='state')['state'] == 'translated', timeout=60, step=.2)
            text = apple.eval(tab, 'document.body.innerText')
            lang = apple.call('translate', action='detect', text=text)
            results['X1_apple_backend'] = {'ok': bool(done) and lang['language'] != 'fr', 'detected': lang}
        finally:
            apple.quit()
            server.shutdown()




def main():
    global _ACTIVE_FOCUS_TRACKER
    ap = argparse.ArgumentParser()
    ap.add_argument("--style", default="alloy", choices=["alloy", "chrome"])
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--engine-sha256", help="require this Vendor framework SHA-256 and matching embedded code before app launch")
    ap.add_argument("--engine-fingerprint-only", action="store_true", help="verify built engine artifacts and exit without launching Open")
    ap.add_argument("--extensions", default=os.path.join(ROOT, ".re", "ext", "unpacked"))
    ap.add_argument("--only", choices=["shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek",
                                       "commandbar", "app-actions", "actions", "extensions-p3", "profiles", "sidebar-completion", "toolbar", "numbering", "media", "relaunch", "page",
                                       "sleep", "context-menus", "routing", "history", "applescript", "downloads"])
    ap.add_argument("--window-chrome-only", action="store_true", help="run only the window-chrome follow-up flows in the window suite")
    ap.add_argument("--keep", action="store_true",
                    help="keep this run's data root, cache root and scratch folder (paths printed at the end)")
    ap.add_argument("--focus-retry-delay-seconds", type=int, default=0,
                    help="wait between interrupted foreground attempts (0–600 seconds)")
    opts = ap.parse_args()
    if not 0 <= opts.focus_retry_delay_seconds <= 600:
        ap.error("--focus-retry-delay-seconds must be between 0 and 600")
    if opts.only is None and not opts.engine_fingerprint_only:
        ap.error("--only is required unless --engine-fingerprint-only is set")
    if opts.engine_sha256 and not re.fullmatch(r"[0-9a-f]{64}", opts.engine_sha256):
        ap.error("--engine-sha256 must be 64 lowercase hexadecimal characters")

    os.makedirs(OUT, exist_ok=True)
    # Every run is isolated: several agents run this harness at once, and two
    # runs of one suite must never share a profile, a cache or a socket. The
    # data root stays under Application Support so Chromium's cache rule
    # applies as for users (~/Library/Caches/<root name>, docs/plans/profiles.md);
    # its name is unique per run, so the cache root is too.
    # Keep AF_UNIX's 104-byte sun_path limit with this suite's longer name.
    root_kind = "sidebarc" if opts.only == "sidebar-completion" else opts.only
    run_name = "Open-E2E-%s-%s-%d-%s" % (root_kind, opts.style, os.getpid(), os.urandom(4).hex())
    sweep_stale_runs()
    user_data = os.path.expanduser("~/Library/Application Support/" + run_name)
    # Chromium keeps profile caches in ~/Library/Caches/<root name>.
    user_caches = os.path.join(os.path.expanduser("~/Library/Caches"), run_name)
    tmp = tempfile.mkdtemp(prefix=run_name + "-scratch-")
    run_folders = [user_data, user_caches, tmp]

    def remove_run_folders(*_):
        if opts.keep:
            print("kept: " + "  ".join(run_folders))
            return
        for folder in run_folders:
            if os.path.isdir(folder):
                subprocess.run(["chflags", "-R", "nouchg", folder], capture_output=True)
                subprocess.run(["chmod", "-R", "u+rwX", folder], capture_output=True)
            shutil.rmtree(folder, ignore_errors=True)
    atexit.register(remove_run_folders)
    atexit.register(lambda: [instance.quit() for instance in _OWNED_APPS])
    # `timeout` and Ctrl-C end the run with a signal: still clean up.
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(128 + 15))
    extra = ["--use-mock-keychain"]
    if opts.only == "media":
        rules_path = os.path.join(tmp, "pip-site-rules.json")
        with open(rules_path, "w") as f:
            json.dump(MEDIA_RULES, f)
        extra += ["--pip-site-rules=" + rules_path]
    if opts.only == "sleep" and opts.style == "chrome":
        # chrome.tabs.discard row: the committed tabs probe only.
        extra += ["--load-extension=" + os.path.join(ROOT, "tools", "e2e", "fixtures", "tabs-probe"),
                  "--disable-features=DisableLoadExtensionCommandLineSwitch"]
    if opts.only == "extensions":
        dirs = [os.path.join(opts.extensions, d) for d in ("ublock-lite", "darkreader", "1password", "bitwarden")]
        if not all(os.path.isdir(d) for d in dirs):
            sys.exit("missing unpacked extensions in %s" % opts.extensions)
        extra += ["--load-extension=" + ",".join(dirs), "--disable-features=DisableLoadExtensionCommandLineSwitch"]
    if opts.only == "actions":
        global ACTION_PROBE_COPY
        ACTION_PROBE_COPY = os.path.join(tmp, "action-probe")
        shutil.rmtree(ACTION_PROBE_COPY, ignore_errors=True)
        shutil.copytree(os.path.join(ROOT, "tools", "e2e", "fixtures", "action-probe"), ACTION_PROBE_COPY)
        dirs = [ACTION_PROBE_COPY, os.path.join(opts.extensions, "bitwarden")]
        if not all(os.path.isdir(d) for d in dirs):
            sys.exit("missing extensions: %s" % dirs)
        extra += ["--load-extension=" + ",".join(dirs), "--disable-features=DisableLoadExtensionCommandLineSwitch"]
    if opts.only == "profiles":
        extra += ["--load-extension=" + os.path.join(ROOT, "tools", "e2e", "fixtures", "tabs-probe"),
                  "--disable-features=DisableLoadExtensionCommandLineSwitch"]
    if opts.only == "tabstrip":
        dirs = [os.path.join(ROOT, "tools", "e2e", "fixtures", "tabs-probe"), os.path.join(opts.extensions, "bitwarden")]
        if not all(os.path.isdir(d) for d in dirs):
            sys.exit("missing extensions: %s" % dirs)
        extra += ["--load-extension=" + ",".join(dirs), "--disable-features=DisableLoadExtensionCommandLineSwitch"]
    log = os.path.join(tmp, "open.log")

    tracker = FocusTracker()
    _ACTIVE_FOCUS_TRACKER = tracker

    def factory(urls=("about:blank",), fresh=False, snapshot=None, extra_env=None, extra_args=None, delivery_urls=()):
        if fresh or snapshot:
            shutil.rmtree(user_data, ignore_errors=True)
            shutil.rmtree(user_caches, ignore_errors=True)
        if snapshot:
            os.makedirs(os.path.join(user_data, "State"), exist_ok=True)
            shutil.copyfile(snapshot, os.path.join(user_data, "State", "browser.json"))
        app = Open(opts.config, opts.style, user_data, extra + list(extra_args or []), log, urls=urls, extra_env=extra_env, delivery_urls=delivery_urls)
        app.focus_tracker = tracker
        tracker.apps.append(app)
        return app

    results = {"style": opts.style, "config": opts.config, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    def framework_uuid(path):
        proc = subprocess.run(['dwarfdump', '--uuid', path], capture_output=True, text=True)
        match = re.search(r'UUID: ([0-9A-F-]+)', proc.stdout)
        return match.group(1) if match else ''
    def framework_sha256(path):
        if not os.path.isfile(path):
            return ''
        digest = hashlib.sha256()
        # Largest Python read buffer: 8 MiB; never load the whole framework.
        with open(path, 'rb') as stream:
            for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
                digest.update(chunk)
        return digest.hexdigest()

    framework = 'Chromium Embedded Framework.framework/Chromium Embedded Framework'
    embedded = framework_uuid(os.path.join(ROOT, 'build', opts.config, 'Open.app/Contents/Frameworks', framework))
    vendor = framework_uuid(os.path.join(ROOT, 'Vendor/cef/Release', framework))
    stamp_path = os.path.join(ROOT, 'Vendor/cef/.open-source')
    stamp = Path(stamp_path).read_text().strip() if os.path.exists(stamp_path) else ''
    def framework_code_sha256(path):
        # Xcode re-signs the copied framework. Compare every byte after
        # removing signatures from private APFS clones and normalizing only
        # __LINKEDIT sizes (codesign can retain signature storage in vmsize).
        with tempfile.TemporaryDirectory(prefix='open-engine-fingerprint-') as folder:
            clone = os.path.join(folder, 'framework')
            subprocess.run(['cp', '-c', path, clone], check=True)
            subprocess.run(['codesign', '--remove-signature', clone], check=True, capture_output=True)
            with open(clone, 'r+b') as stream:
                header = stream.read(32)
                magic, _, _, _, count, size, _, _ = struct.unpack('<8I', header)
                if magic != 0xfeedfacf or count > 4096 or size > 1024 * 1024:
                    raise RuntimeError('unsupported engine Mach-O load commands')
                commands = bytearray(stream.read(size))
                offset, found = 0, False
                for _ in range(count):
                    if offset + 8 > len(commands):
                        raise RuntimeError('truncated engine load command')
                    command, length = struct.unpack_from('<II', commands, offset)
                    if length < 8 or offset + length > len(commands):
                        raise RuntimeError('invalid engine load command length')
                    if command == 0x19 and length >= 72 and bytes(commands[offset + 8:offset + 24]).rstrip(b'\0') == b'__LINKEDIT':
                        file_offset = struct.unpack_from('<Q', commands, offset + 40)[0]
                        payload = os.path.getsize(clone) - file_offset
                        if payload < 0 or found:
                            raise RuntimeError('invalid engine linkedit range')
                        struct.pack_into('<Q', commands, offset + 32, (payload + 16383) & ~16383)
                        struct.pack_into('<Q', commands, offset + 48, payload)
                        found = True
                    offset += length
                if not found or offset != len(commands):
                    raise RuntimeError('incomplete engine load commands')
                stream.seek(32)
                stream.write(commands)
            return framework_sha256(clone)

    embedded_sha = framework_sha256(os.path.join(ROOT, 'build', opts.config, 'Open.app/Contents/Frameworks', framework))
    vendor_sha = framework_sha256(os.path.join(ROOT, 'Vendor/cef/Release', framework))
    embedded_code_sha = framework_code_sha256(os.path.join(ROOT, 'build', opts.config, 'Open.app/Contents/Frameworks', framework))
    vendor_code_sha = framework_code_sha256(os.path.join(ROOT, 'Vendor/cef/Release', framework))
    results['engine'] = {'source': 'fork' if stamp.startswith('fork ') and embedded_code_sha == vendor_code_sha else 'unconfirmed',
                         'embeddedUUID': embedded, 'distributionUUID': vendor, 'stamp': stamp,
                         'embeddedSHA256': embedded_sha, 'distributionSHA256': vendor_sha,
                         'requiredSHA256': opts.engine_sha256 or '',
                         'embeddedCodeSHA256': embedded_code_sha, 'distributionCodeSHA256': vendor_code_sha}
    if embedded_code_sha != vendor_code_sha or (opts.engine_sha256 and vendor_sha != opts.engine_sha256):
        sys.exit('ENGINE_FINGERPRINT_MISMATCH before app launch: expectedVendor=%s vendor=%s embeddedCode=%s vendorCode=%s' %
                 (opts.engine_sha256, vendor_sha, embedded_code_sha, vendor_code_sha))
    print('engine_fingerprint      PASS vendor=%s code=%s' % (vendor_sha, embedded_code_sha), flush=True)
    if opts.engine_fingerprint_only:
        print(json.dumps(results['engine'], sort_keys=True), flush=True)
        return
    def execute():
        if opts.only == "shell":
            results["shell"] = CheckedResults(tracker)
            shell_checks(factory, results["shell"], tmp)
        elif opts.only == "relaunch":
            results["relaunch"] = CheckedResults(tracker)
            relaunch_checks(factory, results["relaunch"], tmp)
        elif opts.only in ("commandbar", "app-actions"):
            results[opts.only] = CheckedResults(tracker)
            commandbar_checks(factory, results[opts.only], tmp, opts.config)
        elif opts.only == "sidebar-completion":
            results[opts.only] = CheckedResults(tracker)
            space_manager_checks(results[opts.only], tmp, opts.config, opts.style)
            folder_peek_checks(factory, results[opts.only], tmp)
        elif opts.only == "context-menus":
            import importlib.util
            spec = importlib.util.spec_from_file_location("open_context_menus", os.path.join(ROOT, "tools/e2e/context_menus.py"))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            results[opts.only] = CheckedResults(tracker)
            module.context_menu_checks(factory, results[opts.only], tmp, sys.modules[__name__])
        elif opts.only == "applescript":
            results["applescript"] = CheckedResults(tracker)
            runpy.run_path(os.path.join(ROOT, "tools/e2e/applescript.py"))["run"](
                factory, results["applescript"], tmp, _fixture_server, _restore_defaults, wait_until)
        elif opts.only == "page":
            results["page"] = CheckedResults(tracker)
            page_checks(factory, results["page"], tmp, opts.style)
        elif opts.only in ("toolbar", "numbering"):
            results[opts.only] = CheckedResults(tracker)
            (toolbar_checks if opts.only == "toolbar" else numbering_checks)(factory, results[opts.only], tmp)
        elif opts.only == "media":
            results["media"] = CheckedResults(tracker)
            media_checks(factory, results["media"], tmp)
        elif opts.only == "downloads":
            import downloads
            results["downloads"] = CheckedResults(tracker)
            downloads.checks(factory, results["downloads"], tmp, opts.config, sys.modules[__name__])
        elif opts.only == "history":
            results["history"] = CheckedResults(tracker)
            runpy.run_path(os.path.join(ROOT, "tools/e2e/history_e2e.py"))["history_checks"](
                factory, results["history"], tmp, wait_until, _restore_defaults)
        elif opts.only == "sleep":
            results["sleep"] = CheckedResults(tracker)
            sleep_checks(factory, results["sleep"], tmp, opts.style)
        elif opts.only == "routing":
            results["routing"] = CheckedResults(tracker)
            routing_checks(factory, results["routing"], tmp)
        elif opts.only == "window":
            results["window"] = CheckedResults(tracker)
            window_checks(factory, results["window"], tmp, opts.config, chrome_only=opts.window_chrome_only)
        elif opts.only == "sidebar":
            results["sidebar"] = CheckedResults(tracker)
            sidebar_checks(factory, results["sidebar"], tmp)
        elif opts.only == "peek":
            results["peek"] = CheckedResults(tracker)
            peek_checks(factory, results["peek"], tmp)
        elif opts.only == "profiles":
            results["profiles"] = {}
            profiles_checks(factory, results["profiles"], tmp, opts.config)
        elif opts.only == "measure":
            results["measure"] = CheckedResults(tracker)
            measure(factory, results["measure"], tmp)
        else:
            app = factory(urls=("about:blank" if opts.only == "extensions-p3" else "https://example.com/",))
            try:
                results["ping"] = app.call("ping")
                app.call("window-frame", frame=[80, 60, 1360, 860])
                results[opts.only] = CheckedResults(tracker)
                if opts.only == "extensions":
                    extension_checks(app, opts.style, results["extensions"])
                elif opts.only == "tabstrip":
                    # LaunchServices can answer the socket before granting
                    # foreground focus. Establish the real window precondition
                    # through the same exact-PID activation path as native keys.
                    app.call("window-focus", id=app.call("window-state")["id"], activate=True)
                    tabstrip_checks(app, results["tabstrip"])
                elif opts.only == "actions":
                    actions_checks(app, results["actions"])
                elif opts.only == "extensions-p3":
                    import extensions_p3
                    extensions_p3.run(app, results["extensions-p3"], tmp, ROOT, wait_until, new_tab)
                else:
                    feature_checks(app, opts.style, results["features"], tmp)
            finally:
                app.quit()

    interrupted_attempts = []
    for attempt in range(1, 4):
        tracker = FocusTracker()
        _ACTIVE_FOCUS_TRACKER = tracker
        shutil.rmtree(user_data, ignore_errors=True)
        interruption = None
        try:
            execute()
        except FocusInterruption as error:
            interruption = {"reason": str(error), "focus": error.evidence}
        except Exception as error:
            try:
                loss = tracker.loss()
            except Exception:
                loss = []  # A crashed owned app cannot answer a focus query.
            if loss:
                interruption = {"reason": str(error), "focus": loss}
            else:
                dict.__setitem__(results.setdefault(opts.only, {}), "suite", {"ok": False, "error": str(error)})
                traceback.print_exc()
        finally:
            for instance in _OWNED_APPS:
                instance.quit()
        if interruption is None:
            break
        interrupted_attempts.append(dict(interruption, attempt=attempt, status="INTERRUPTED",
                                         checks=dict(results.get(opts.only, {}))))
        print("%s attempt %d INTERRUPTED: %s" % (opts.only, attempt, interruption["reason"]), flush=True)
        if attempt == 3:
            dict.__setitem__(results.setdefault(opts.only, {}), "suite", {
                "status": "INTERRUPTED", "reason": interruption["reason"], "focus": interruption["focus"], "attempts": 3})
        elif opts.focus_retry_delay_seconds:
            print("retrying interrupted foreground flow in %ds" % opts.focus_retry_delay_seconds, flush=True)
            remaining = opts.focus_retry_delay_seconds
            while remaining:
                delay = min(30, remaining)
                time.sleep(delay); remaining -= delay
    results["interrupted_attempts"] = interrupted_attempts
    results["cleanup"] = {"ok": all(instance.quit_report.get("ok") for instance in _OWNED_APPS),
                          "processes": [instance.quit_report for instance in _OWNED_APPS]}
    print("owned_process_cleanup    " + ("PASS" if results["cleanup"]["ok"] else "FAIL"), flush=True)
    name = ("results-actions-p2.json" if opts.only == "actions" else
            "results-%s-%s.json" % (opts.only, opts.style if opts.only in ("extensions", "features", "tabstrip", "page", "context-menus")
                                    else opts.config.lower()))
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(results, f, indent=2, sort_keys=True)
    for group in ("shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek", "commandbar", "app-actions", "actions", "extensions-p3", "profiles", "sidebar-completion", "toolbar", "numbering", "media", "relaunch", "page", "sleep", "context-menus", "routing", "history", "applescript", "downloads"):
        for k, v in results.get(group, {}).items():
            if isinstance(v, dict) and "ok" in v:
                print("%-24s %s" % (k, "PASS" if v.get("ok") else "FAIL"))
            elif isinstance(v, dict) and v.get("status") in ("SKIP", "BLOCKED", "INTERRUPTED", "DEFERRED"):
                print("%-24s %s: %s" % (k, v["status"], v.get("reason", "")))
    print("wrote", os.path.join(OUT, name))
    failures = [k for group in ("shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek", "commandbar", "app-actions", "actions", "extensions-p3", "sidebar-completion", "toolbar", "numbering", "media", "relaunch", "page", "sleep", "context-menus", "routing", "history", "applescript", "downloads")
                for k, v in results.get(group, {}).items() if isinstance(v, dict) and v.get("ok") is False]
    if failures or not results["cleanup"]["ok"]:
        sys.exit(1)
    if any(isinstance(v, dict) and v.get("status") == "INTERRUPTED" for v in results.get(opts.only, {}).values()):
        sys.exit(2)


if __name__ == "__main__":
    main()
