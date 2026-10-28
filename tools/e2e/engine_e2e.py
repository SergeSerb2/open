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
    def __init__(self, config, style, user_data, extra_args, log_path, urls=("about:blank",), extra_env=None):
        if os.path.exists(os.path.join(ROOT, ".re", "hold-on-screen")):
            raise RuntimeError("On-screen Open runs are held by the lead (.re/hold-on-screen)")
        self.user_data = user_data
        self.config, self.style = config, style
        self.sock = os.path.join(user_data, "automation.sock")
        app = os.path.join(ROOT, "build", config, "Open.app", "Contents", "MacOS", "Open")
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
        env = dict(os.environ, OPEN_USER_DATA=user_data)
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
        launch = ["/usr/bin/open", "-n"] + wait_args + [self.bundle,
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
        if cmd == "space-manager-drag": foreground_input = True
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
    first = app.call("tabs")[0]["id"]
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

    # chrome.tabs.discard asks Open: a background tab unloads in place; the
    # visible tab is refused. Chromium never discards on its own.
    bg = f2
    bg_cid = chrome_id(bg)
    discard_bg = ext_call(pop, "chrome.tabs.discard(%d).then(t => ({id: t.id, discarded: t.discarded}))" % bg_cid)
    unloaded = wait_until(lambda: (lambda r: r if r and not r["loaded"] else None)(row(bg)), timeout=10)
    visible = [t for t in app.call("tabs") if t["visible"]][0]
    discard_visible = ext_call(pop, "chrome.tabs.discard(%d)" % visible["page"]["chromeTabId"])
    time.sleep(0.5)
    results["tabs_discard"] = {
        "ok": "ok" in discard_bg and bool(unloaded) and "error" in discard_visible
              and bool(row(visible["id"])) and row(visible["id"])["loaded"],
        "background": discard_bg, "background_unloaded_in_place": bool(unloaded),
        "visible": discard_visible}

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
    results["window_screenshot"] = shot(app, "p1-window.png")
    context_menu_commands(app, results)
    new_window_outlives_opener(app, results)


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


def ensure_key(app, wid, timeout=15):
    """Makes the window key; macOS refuses to activate an app while someone uses another one,
    so this asks again until it holds. Returns the state, key or not."""
    app.begin_timing("key-window readiness")
    deadline = time.monotonic() + timeout
    while True:
        app.call("window-focus", id=wid, activate=True)
        time.sleep(0.25)
        st = app.call("window-state", id=wid)
        if (st["key"] and st["appActive"]) or time.monotonic() > deadline:
            return st


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
    def spring(a, response, damping, path=None):
        return (a.get("type") == "CASpringAnimation" and abs(a.get("response", 0) - response) < 1e-6
                and abs(a.get("damping", 0) - damping) < 1e-6 and 0 <= a.get("scheduledDelay", a.get("beginTime", -1)) <= 1/60
                and (path is None or a.get("keyPath") == path))
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
            and all(spring(a, .1, .95) for a in m["sidebar"].get("panel", {}).get("children", []))
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
        app.call("window-fullscreen")
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
        app.call("space", space=s2)
        second_page = check_page(app, e, "Sidebar E")
        results["space_switch_wrapper"] = {"ok": first_page and second_page and context != "Default"
                                                and app.page(e)["context"] == context}
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
        proc = subprocess.run([app_path, "--user-data-dir=" + early_data],
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
        failed = subprocess.run([os.path.join(failed_bundle, "Contents", "MacOS", "Open"), "--user-data-dir=" + failure_data],
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
    try:
        _actions_checks(app, results)
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
            app.call("key", key="d", modifiers=["ctrl"], window="popup", route="window")
            stages = wait_until(lambda: (lambda e: e if {"beforePage", "unconsumed"} <= {x.get("phase") for x in e} else None)(
                [x for x in app.call("events") if x["type"] == "popupKey"]), timeout=5)
            keys["ctrl_d_stages"] = sorted({x.get("phase") for x in stages or []})
            keys["still_open"] = bool(app.call("ext-popup").get("open"))
            app.call("key", key="w", modifiers=["cmd"], window="popup", route="app")
            keys["closed"] = bool(wait_until(lambda: not app.call("ext-popup").get("open"), timeout=5))
            keys["tabs_kept"] = len(app.call("tabs")) == tabs_before
            if not keys["closed"]:
                close_popup()
        results["popup_keys"] = {
            "ok": keys["opened"] and keys.get("ctrl_d_stages") == ["beforePage", "unconsumed"] and keys.get("still_open")
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
        env = dict(os.environ, OPEN_USER_DATA=root, **env_extra)
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


def measure(app_factory, results, tmp):
    def mb(x):
        return round(x / 1048576, 1)

    # Load matters: the numbers are only comparable at similar load.
    results["load_average_at_start"] = [round(x, 1) for x in os.getloadavg()]
    results["cpu_count"] = os.cpu_count()

    # Cold-ish launch: profile already exists (second launch), one restored
    # tab. Process start to first contentful paint of that tab.
    runs = []
    for i in range(4):
        app = app_factory(urls=("https://example.com/",) if i == 0 else ())
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
        time.sleep(8)
        m10 = app.call("metrics", interval=2)
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
    results["idle_cpu_10_tabs_percent"] = round(sum(max(p["cpu"], 0) for p in idle["tasks"]), 2)
    results["ok"] = True


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
        app.call('focus', tab=tab)
        opened = bar('t', 'window')
        first_open = wait_until(lambda: state() if state().get('openFirstResultsMs',-1) >= 0 else None, step=.02)
        results['first_open_results_budget'] = {'ok': bool(first_open) and first_open['openFirstResultsMs'] <= 50, 'milliseconds': first_open.get('openFirstResultsMs') if first_open else None, 'scope': 'showCommandBar entry to first snapshot applied; excludes preceding key routing, socket transport and frame presentation'}
        results['cmd_t_mode'] = {'ok': opened['mode'] == 'newTab' and opened['newTabHighlighted'], 'state': opened}
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
        results['first_results_budget'] = {'ok': bool(timings) and timings['openFirstResultsMs'] <= 50, 'milliseconds': timings.get('openFirstResultsMs') if timings else None, 'scope': 'showCommandBar entry to first snapshot applied; excludes preceding key routing, socket transport and frame presentation'}
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

        time.sleep(.25)
        app.call('menu-perform', id='settings'); original_external = app.call('settings-state')['external']
        app.call('settings-toggle', name='external'); app.call('save'); app.quit()
        app = factory(urls=())
        press(',', modifiers=['cmd']); time.sleep(.2)
        results['settings_persist_relaunch'] = {'ok': app.call('settings-state')['external'] != original_external}
        app.call('settings-toggle', name='external')
    finally:
        app.quit(); server.shutdown(); server.server_close()


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
    spaces_before = [sp['id'] for sp in app.call('spaces')]
    app.call('sidebar-menu', item='Delete Space')
    sheet = wait_until(lambda: state()['confirmation'], timeout=3)
    texts = app.call('alert')
    app.call('alert', button='Cancel')
    cancelled = [sp['id'] for sp in app.call('spaces')] == spaces_before and state()['confirmation'] is None
    require('E7_delete_space_cancel', sheet and sheet['title'] == 'Delete your Delete Me Space?' and sheet['buttons'] == ['Delete', 'Cancel']
            and 'This will archive all the tabs and folders inside it.' in texts['texts'] and cancelled, sheet=sheet, texts=texts)
    app.call('sidebar-menu', item='Delete Space'); wait_until(lambda: state()['confirmation'], timeout=3)
    app.call('alert', button='Delete')
    deleted = wait_until(lambda: doomed not in [sp['id'] for sp in app.call('spaces')], timeout=3)
    require('E7_delete_space_confirmed', deleted and state()['confirmation'] is None, spaces=app.call('spaces'))
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
    app.call('mouse', action='hover', x=point[0], y=point[1])
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
        return wait_until(lambda: (lambda s: s if s['visible'] and s['hostedManagers'] == 1 else None)(state(app)), timeout=5)

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
        uncached = app.call('space-manager-lifecycle')
        section = next(r for r in uncached['sectionRows'] if r['section'] == 'spaces')
        app.call('mouse', action='click', window=state(app)['window'], x=section['point'][0], y=section['point'][1])
        reopened = manager_ready(app)
        require('library_section_click_fills_cache', uncached['identity'] == '' and reopened and reopened['hostedManagers'] == 1,
                before=uncached, after=app.call('space-manager-lifecycle'))
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
        export_title = next(sp['title'] for sp in app.call('spaces') if sp['id'] == s1) or 'Space'
        export_dest = next(sp for sp in app.call('spaces') if sp['id'] == s3)
        app.call('space-manager-menu', space=s1, item='Turn into Folder/' + (export_dest['title'] or 'Space'))
        exported = wait_until(lambda: s1 not in order(app), timeout=5)
        with open(app.call('save')) as stream: exported_snapshot = json.load(stream)
        dest_pinned = next(sp for sp in exported_snapshot['spaces'] if sp['id'] == s3)['pinned']
        first = dest_pinned[0] if dest_pinned else {}
        require('manager_turn_into_folder', exported and 'folder' in first, order=order(app), firstPinned=first, title=export_title)
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


def main():
    global _ACTIVE_FOCUS_TRACKER
    ap = argparse.ArgumentParser()
    ap.add_argument("--style", default="alloy", choices=["alloy", "chrome"])
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--engine-sha256", help="require this Vendor framework SHA-256 and matching embedded code before app launch")
    ap.add_argument("--engine-fingerprint-only", action="store_true", help="verify built engine artifacts and exit without launching Open")
    ap.add_argument("--extensions", default=os.path.join(ROOT, ".re", "ext", "unpacked"))
    ap.add_argument("--only", choices=["shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek",
                                       "commandbar", "app-actions", "actions", "profiles", "sidebar-completion"])
    ap.add_argument("--window-chrome-only", action="store_true", help="run only the window-chrome follow-up flows in the window suite")
    ap.add_argument("--keep", action="store_true",
                    help="keep this run's data root, cache root and scratch folder (paths printed at the end)")
    opts = ap.parse_args()
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
    run_name = "Open-E2E-%s-%s-%d-%s" % (opts.only, opts.style, os.getpid(), os.urandom(4).hex())
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

    def factory(urls=("about:blank",), fresh=False, snapshot=None, extra_env=None):
        if fresh or snapshot:
            shutil.rmtree(user_data, ignore_errors=True)
            shutil.rmtree(user_caches, ignore_errors=True)
        if snapshot:
            os.makedirs(os.path.join(user_data, "State"), exist_ok=True)
            shutil.copyfile(snapshot, os.path.join(user_data, "State", "browser.json"))
        app = Open(opts.config, opts.style, user_data, extra, log, urls=urls, extra_env=extra_env)
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
        elif opts.only in ("commandbar", "app-actions"):
            results[opts.only] = CheckedResults(tracker)
            commandbar_checks(factory, results[opts.only], tmp, opts.config)
        elif opts.only == "sidebar-completion":
            results[opts.only] = CheckedResults(tracker)
            space_manager_checks(results[opts.only], tmp, opts.config, opts.style)
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
            app = factory(urls=("https://example.com/",))
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
    results["interrupted_attempts"] = interrupted_attempts
    results["cleanup"] = {"ok": all(instance.quit_report.get("ok") for instance in _OWNED_APPS),
                          "processes": [instance.quit_report for instance in _OWNED_APPS]}
    print("owned_process_cleanup    " + ("PASS" if results["cleanup"]["ok"] else "FAIL"), flush=True)
    name = ("results-actions-p2.json" if opts.only == "actions" else
            "results-%s-%s.json" % (opts.only, opts.style if opts.only in ("extensions", "features", "tabstrip")
                                    else opts.config.lower()))
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(results, f, indent=2, sort_keys=True)
    for group in ("shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek", "commandbar", "app-actions", "actions", "profiles", "sidebar-completion"):
        for k, v in results.get(group, {}).items():
            if isinstance(v, dict) and "ok" in v:
                print("%-24s %s" % (k, "PASS" if v.get("ok") else "FAIL"))
            elif isinstance(v, dict) and v.get("status") in ("SKIP", "BLOCKED", "INTERRUPTED", "DEFERRED"):
                print("%-24s %s: %s" % (k, v["status"], v.get("reason", "")))
    print("wrote", os.path.join(OUT, name))
    failures = [k for group in ("shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek", "commandbar", "app-actions", "actions", "sidebar-completion")
                for k, v in results.get(group, {}).items() if isinstance(v, dict) and v.get("ok") is False]
    if failures or not results["cleanup"]["ok"]:
        sys.exit(1)
    if any(isinstance(v, dict) and v.get("status") == "INTERRUPTED" for v in results.get(opts.only, {}).values()):
        sys.exit(2)


if __name__ == "__main__":
    main()
