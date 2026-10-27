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
import base64
import ctypes
import json
import math
import glob
import re
import os
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import sys
import time
import traceback
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "docs", "engine-spike")
_ACTIVE_FOCUS_TRACKER = None

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
                observations = app.observation_steps[self.observation_checkpoints.get(app.pid, 0):]
                steps = observations[:1]
                if not steps: continue
            events = app.activation_trace if app.closed else app.call("activation-events")
            # Untimed pointer/model work may run in the background. Native
            # input and timed intervals both retain their own trace bounds.
            for event in events:
                resigned = event["event"] == "NSApplicationDidResignActiveNotification"
                outside = event["event"] == "frontmostChanged" and event.get("frontmostPID") not in (None, 0, app.pid)
                if event["uptime"] >= min(steps) and (resigned or outside or event["event"] == "hardwareInteraction"):
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
        self.pid = None
        self.launch_waiter_ended_before_automation = False
        self.closed = False
        self.native_steps = []
        self.timing_steps = []
        self.observation_steps = []
        self.activation_trace = []
        self.focus_tracker = None
        env = dict(os.environ, OPEN_USER_DATA=user_data, OPEN_AUTOMATION_VIRTUAL_INPUT="1")
        env.update(extra_env or {})
        args = [app, "--style=%s" % style] + list(urls) + extra_args
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
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                self.pid = self.call("ping")["pid"]
                return
            except (OSError, json.JSONDecodeError):
                time.sleep(0.1)
            if self.proc.poll() is not None:
                # LaunchServices may fail its -W GetProcessPID wait independently
                # of launching the app. Only the real socket establishes readiness.
                self.launch_waiter_ended_before_automation = True
        self.proc.kill()
        self.proc.wait()
        self.log.close()
        raise RuntimeError("Open automation was not ready within 60 s (launcher exit %s); see %s" % (self.proc.returncode, log_path))

    def call(self, cmd, timeout=120, **args):
        foreground_input = cmd in ("key", "focus") or (cmd == "window-focus" and args.get("activate"))
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

    def accept_file_reveal_handoff(self, receipt, path):
        """Only the explicitly tested own-download NSWorkspace reveal may hand off to Finder."""
        assert receipt.get("performed") and receipt.get("reveal", {}).get("path") == path and os.path.isfile(path), receipt
        assert os.path.commonpath([os.path.realpath(path), os.path.realpath(self.user_data)]) == os.path.realpath(self.user_data), path
        deadline = time.monotonic() + 5
        while True:
            state = self.call("native-focus-state"); events = self.call("activation-events")
            observed = any(e["event"] == "frontmostChanged" and e.get("frontmostBundle") == "com.apple.finder" for e in events)
            if state.get("frontmostBundle") == "com.apple.finder" and observed:
                break
            if time.monotonic() >= deadline:
                raise FocusInterruption("own download reveal did not hand off to Finder", [state])
            time.sleep(.02)
        if self.focus_tracker: self.focus_tracker.checkpoint()

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

    def quit(self):
        if self.closed:
            return
        try:
            self.activation_trace = self.call("activation-events")
        except Exception:
            pass
        self.quit_report = {}
        try:
            self.quit_report["reply"] = self.call("quit")
        except Exception as error:
            self.quit_report["error"] = str(error)
        # The launch waiter may have been interrupted independently of its app.
        # Wait for the actual app PID too, and never kill another executable.
        def still_ours():
            if not self.pid:
                return False
            path = ctypes.create_string_buffer(4096)
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
            size = libproc.proc_pidpath(self.pid, path, len(path))
            actual = os.path.realpath(os.fsdecode(path.value)) if size > 0 else ""
            if "observedExecutable" not in self.quit_report:
                self.quit_report["observedExecutable"] = actual
                self.quit_report["expectedExecutable"] = os.path.realpath(self.executable)
            return size > 0 and actual == os.path.realpath(self.executable)
        deadline = time.monotonic() + 15
        while still_ours() and time.monotonic() < deadline:
            time.sleep(.05)
        self.quit_report["forced"] = still_ours()
        if self.quit_report["forced"]:
            os.kill(self.pid, signal.SIGKILL)
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
    popups = {}
    for name, ext_id in EXT.items():
        info = {}
        try:
            app.call("events")
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
    out["windows_after"] = [(w["class"], w["frame"]) for w in app.call("windows") if w["visible"]]
    out["console"] = [e["message"] for e in app.call("events") if e.get("type") == "console"][-5:]
    out["ok"] = bool(installed)
    app.call("close", tab=t)
    return out


# ----------------------------------------------------------------------------
# Engine feature checks (no extensions needed)


def page_chrome_checks(factory, results, tmp):
    """Real page chrome flows. Policies expose caller choices, never fake engine replies."""
    import http.server
    import threading
    payload = b'OPEN PAGE CHROME DOWNLOAD\n' * 327680
    fixture_path = Path(ROOT) / 'tools/e2e/fixtures/page-chrome/page.html'
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split('?', 1)[0]
            if path.startswith('/download'):
                self.send_response(200); self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Disposition', 'attachment; filename="%s"' % ('cancel.bin' if 'cancel' in path else 'page-chrome.bin'))
                self.send_header('Content-Length', str(len(payload))); self.end_headers()
                try:
                    for i in range(0, len(payload), 65536):
                        self.wfile.write(payload[i:i+65536]); self.wfile.flush(); time.sleep(.06)
                except (BrokenPipeError, ConnectionResetError): pass
                return
            if path == '/image.svg':
                body = b'<svg xmlns="http://www.w3.org/2000/svg" width="80" height="60"><rect width="80" height="60" fill="#936550"/></svg>'; mime = 'image/svg+xml'
            elif path == '/link': body = b'<title>Linked fixture</title><h1>Linked fixture needle</h1>'; mime = 'text/html'
            else: body = fixture_path.read_bytes(); mime = 'text/html'
            self.send_response(200); self.send_header('Content-Type', mime); self.send_header('Content-Length', str(len(body))); self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
        def log_message(self, *args): pass
    servers = [http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) for _ in range(3)]
    for server in servers: threading.Thread(target=server.serve_forever, daemon=True).start()
    origins = ['http://127.0.0.1:%d' % server.server_address[1] for server in servers]
    origin = origins[0]; app = factory(urls=(origin + '/page',), fresh=True)
    try:
        tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab); app.call('focus', tab=tab)
        app.call('policy', dialogs='', permissions='', contextMenu='hold')
        def key(name=None, **args): return app.call('key', **dict(args, **({'key': name} if name else {})))
        def find_state(): return app.call('find-state')
        def open_find(text):
            app.call('focus', tab=tab); key('f', modifiers=['cmd'], route='window')
            assert wait_until(lambda: find_state()['visible'], timeout=3, step=.02), find_state()
            key(text=text)
        open_find('needle')
        found = wait_until(lambda: (lambda s: s if s['count'] == 3 and s['index'] > 0 else None)(find_state()), timeout=5, step=.02)
        results['find_bar_open_type'] = {'ok': bool(found) and found['text'] == 'needle' and found['frame'][2:] == [260,24], 'state': find_state()}
        shot(app, 'page-chrome-find.png')
        assert found, find_state()
        initial = found['index']; key('return')
        next_match = wait_until(lambda: find_state()['index'] == initial % 3 + 1, timeout=3, step=.02)
        key('return', modifiers=['shift'])
        previous = wait_until(lambda: find_state()['index'] == initial, timeout=3, step=.02)
        results['find_bar_next_previous'] = {'ok': bool(next_match) and bool(previous), 'initial': initial, 'state': find_state()}
        key('escape'); closed = wait_until(lambda: not find_state()['visible'], timeout=3, step=.02)
        results['find_bar_escape'] = {'ok': bool(closed) and app.eval(tab, 'document.hasFocus()')}
        open_find('absent-match-12345')
        empty = wait_until(lambda: find_state()['text'] == 'absent-match-12345' and find_state()['count'] == 0, timeout=3, step=.02)
        key('a', modifiers=['cmd']); key('backspace')
        cleared = wait_until(lambda: not find_state()['visible'] and find_state()['text'] == '', timeout=3, step=.02)
        results['find_bar_empty'] = {'ok': bool(empty) and bool(cleared)}
        app.call('peek-open', tab=tab, url=origin + '/link')
        peek = wait_until(lambda: (lambda s: s if s['shown'] and s['stack'] and s['stack'][-1]['content'] else None)(app.call('peek-state')), timeout=8, step=.05)
        assert peek, app.call('peek-state')
        peek_page = peek['stack'][-1]['content']; app.call('wait', tab=peek_page)
        key('f', modifiers=['cmd']); key(text='needle')
        peek_find = wait_until(lambda: find_state()['count'] == 1 and find_state()['page'] == peek_page, timeout=5, step=.02)
        results['find_bar_peek_scope'] = {'ok': bool(peek_find), 'state': find_state()}
        key('escape'); app.call('peek-close'); app.call('focus', tab=tab)

        # A split changes the actual focused engine pane, not merely the sidebar row.
        peer_tab=app.call('open',url=origin+'/link')['id'];app.call('wait',tab=peer_tab)
        app.call('split');key('2',modifiers=['ctrl','shift'])
        focused=app.call('window-state');key('f',modifiers=['cmd']);key(text='needle')
        expected_count=1 if focused['engineURL']==origin+'/link' else 3
        split_find=wait_until(lambda:find_state()['count']==expected_count and find_state()['page']==focused['engineSelected'],timeout=5,step=.02)
        results['find_bar_split_scope']={'ok':bool(split_find),'state':find_state(),'focusedEngine':focused['engineSelected']}
        key('escape');app.call('split');app.call('select',tab=tab);app.call('focus',tab=tab)

        # This fixture uses the same current OpenEngine action/popup contract as real extensions.
        action=wait_until(lambda:next((a for a in app.call('extensions')['actions'] if a['title']=='Page chrome popup'),None),timeout=10,step=.1)
        if action:
            opened=app.call('extension-toolbar-press',extension=action['id'])
            popup=wait_until(lambda:(lambda s:s if s['visible'] and s['content'] else None)(app.call('extension-popup-state')),timeout=5,step=.02)
            assert popup,app.call('extension-popup-state');app.call('wait',tab=popup['content'])
            results['extension_popup_panel']={'ok':opened and app.eval(popup['content'],'document.title')=='Page chrome popup' and all(25<=v<=limit for v,limit in zip(popup['size'],[800,600])),'state':popup}
            app.call('click',tab=popup['content'],selector='#edit');key(text='popup input',window=popup['window'])
            results['extension_popup_input']={'ok':app.eval(popup['content'],'document.querySelector("#edit").value')=='popup input'}
            app.eval(popup['content'],'window.resizeFixture();true')
            resized=wait_until(lambda:(lambda s:s if s['visible'] and s['size']!=popup['size'] else None)(app.call('extension-popup-state')),timeout=5,step=.05)
            results['extension_popup_resize']={'ok':bool(resized) and all(25<=v<=limit for v,limit in zip(resized['size'],[800,600])),'before':popup,'after':resized}
            app.call('extension-toolbar-press',extension=action['id'])
            toggled=wait_until(lambda:not app.call('extension-popup-state')['visible'],timeout=3,step=.02)
            results['extension_popup_second_click']={'ok':bool(toggled)}
            app.call('focus',tab=tab);app.call('extension-toolbar-press',extension=action['id'])
            popup=wait_until(lambda:(lambda s:s if s['visible'] and s['content'] else None)(app.call('extension-popup-state')),timeout=5,step=.02)
            assert popup,app.call('extension-popup-state');app.call('wait',tab=popup['content']);app.call('click',tab=popup['content'],selector='#close')
            closed=wait_until(lambda:not app.call('extension-popup-state')['visible'],timeout=3,step=.02)
            results['extension_popup_window_close']={'ok':bool(closed)}
            app.call('focus',tab=tab);app.call('extension-toolbar-press',extension=action['id'])
            assert wait_until(lambda:app.call('extension-popup-state')['visible'],timeout=5,step=.02)
            rect=app.call('downloads-state')['button'];assert len(rect)==4 and rect[2]>0,rect
            app.call('mouse',action='queued-click',x=rect[0]+rect[2]/2,y=rect[1]+rect[3]/2)
            outside=wait_until(lambda:not app.call('extension-popup-state')['visible'],timeout=3,step=.02)
            results['extension_popup_outside_click']={'ok':bool(outside)}
            if app.call('downloads-state')['visible']:app.call('downloads-show')
            app.call('focus',tab=tab)
        else:
            installed=app.call('extensions')
            assert any(e['name']=='Open page chrome fixture' for e in installed['installed']), installed
            results['extension_popup_pending']={'status':'BLOCKED','reason':'pending #93: installed fixture action not published by current engine','engineActions':installed['actions']}
        results['extension_chrome_model_pending']={'status':'BLOCKED','reason':'pending #93: native Chrome toolbar action/popup implementation is not on main'}

        def start_dialog(script):
            app.eval(tab, 'window.outcome="pending";setTimeout(()=>{window.outcome=(' + script + ');},0);true')
            return wait_until(lambda: (lambda s: s if s['visible'] else None)(app.call('page-dialog-state')), timeout=5, step=.02)
        for name, script, accepted, text, expected, kind in [
            ('alert', '(alert("page chrome alert"),"alert done")', True, None, 'alert done', 0),
            ('confirm_cancel', 'confirm("page chrome confirm")', False, None, False, 1),
            ('confirm_accept', 'confirm("page chrome confirm")', True, None, True, 1),
            ('prompt_accept', 'prompt("page chrome prompt","seed")', True, 'typed response', 'typed response', 2),
            ('prompt_cancel', 'prompt("page chrome prompt","seed")', False, 'ignored', None, 2)]:
            visible = start_dialog(script); assert visible, app.call('page-dialog-state')
            if name == 'prompt_accept': shot(app, 'page-chrome-dialog.png', window=visible['window'])
            response = app.call('page-dialog-press', accept=accepted, text=text)
            done = wait_until(lambda: app.eval(tab, 'window.outcome') == expected, timeout=5, step=.02)
            results['dialog_' + name] = {'ok': visible['kind'] == kind and response and bool(done)
                and (kind != 2 or visible['text'] == 'seed'), 'sheet': visible, 'result': app.eval(tab, 'window.outcome')}
        app.call('policy', dialogs='dismiss')
        dismissed = app.eval(tab, '[confirm("dismiss policy"),prompt("dismiss prompt","seed")]')
        results['dialog_dismiss_policy'] = {'ok': dismissed == [False, None] and app.call('page-dialog-state')['pending'] == 0, 'result': dismissed}
        app.call('policy', dialogs='hold')
        app.eval(tab, 'setTimeout(()=>{window.outcome=confirm("held confirm")},0);true')
        held = wait_until(lambda: (lambda s: s if s['pending'] == 1 and s['held'] else None)(app.call('page-dialog-state')), timeout=5, step=.02)
        answered = app.call('dialog', accept=True)
        results['dialog_hold_policy'] = {'ok': bool(held) and not held['visible'] and answered and bool(wait_until(lambda: app.eval(tab,'window.outcome') is True, timeout=3, step=.02))}
        app.call('policy', dialogs='')
        closing = app.call('open', url=origin + '/page?unsaved')['id']; app.call('wait', tab=closing); app.call('focus', tab=closing)
        app.call('click', tab=closing, selector='#unload'); before_hosts = app.call('host-counts')['created']
        app.call('close', tab=closing)
        unload = wait_until(lambda: (lambda s: s if s.get('visible') and s.get('kind') == 3 else None)(app.call('page-dialog-state')), timeout=5, step=.02)
        assert unload, app.call('page-dialog-state')
        app.call('page-dialog-press', accept=False)
        stayed = wait_until(lambda: not app.call('page-dialog-state')['visible'], timeout=3, step=.02)
        results['dialog_beforeunload_stay'] = {'ok': bool(stayed) and any(t['id'] == closing for t in app.call('tabs'))
            and app.eval(closing,'document.title') == 'Page chrome fixture' and app.call('host-counts')['created'] == before_hosts, 'sheet': unload}
        app.call('close', tab=closing)
        assert wait_until(lambda: app.call('page-dialog-state').get('kind') == 3 and app.call('page-dialog-state')['visible'], timeout=5, step=.02)
        app.call('page-dialog-press', accept=True)
        removed = wait_until(lambda: all(t['id'] != closing for t in app.call('tabs')), timeout=5, step=.02)
        results['dialog_beforeunload_leave'] = {'ok': bool(removed) and app.call('page-dialog-state')['pending'] == 0}
        app.call('select', tab=tab); app.call('focus', tab=tab)

        # Separate secure localhost origins keep remembered decisions independent.
        remembered = []
        for index, allow, remember in [(0,False,False),(1,True,True),(2,False,True)]:
            target = app.call('open', url=origins[index]+'/page?permission')['id']; app.call('wait',tab=target); app.call('focus',tab=target)
            app.call('permission-setting',tab=target,origin=origins[index],kind=8,state=0)
            app.eval(target,'window.permissionResult="pending";Notification.requestPermission().then(v=>window.permissionResult=v);true')
            prompt = wait_until(lambda: (lambda s: s if s['visible'] else None)(app.call('permission-state')), timeout=5, step=.02)
            assert prompt, app.call('permission-state')
            if allow: shot(app, 'page-chrome-permission.png', window=prompt['window'])
            pressed = app.call('permission-press', allow=allow, remember=remember)
            outcome = 'granted' if allow else 'denied'
            settled = wait_until(lambda: app.eval(target,'window.permissionResult') == outcome, timeout=5, step=.02)
            stored = app.call('permission-setting',tab=target,origin=origins[index],kind=8)
            wanted = (1 if allow else 2) if remember else 0
            results['permission_' + ('allow_remember' if allow else 'deny_remember' if remember else 'deny_once')] = {
                'ok': bool(pressed) and bool(settled) and stored == wanted and app.call('permission-state')['pending'] == 0,
                'prompt': prompt, 'stored': stored, 'expectedStored': wanted}
            if remember: remembered.append((origins[index],wanted,outcome))
        old_decisions = app.call('permission-state')['decisions']
        known = app.call('open',url=origins[1]+'/page?remembered')['id'];app.call('wait',tab=known)
        actual = app.eval(known,'Notification.requestPermission()')
        results['permission_stored_no_prompt'] = {'ok': actual == 'granted' and not app.call('permission-state')['visible'] and app.call('permission-state')['decisions'] == old_decisions}
        app.call('select',tab=tab);app.call('focus',tab=tab)
        # Actual engine context menu events; selections use the same NSMenu items.
        def context(selector, selection=False):
            if selection:app.eval(tab,'(()=>{const r=document.createRange();r.selectNodeContents(document.querySelector('+json.dumps(selector)+'));const s=getSelection();s.removeAllRanges();s.addRange(r);return true})()')
            pos=app.eval(tab,'(()=>{const r=document.querySelector('+json.dumps(selector)+').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()')
            app.call('context-menu-cancel');app.call('rightclick',tab=tab,x=pos[0],y=pos[1])
            menu=wait_until(lambda:(lambda s:s if s['items'] and not s['completed'] else None)(app.call('context-menu-state')),timeout=5,step=.02)
            assert menu,app.call('context-menu-state');return menu
        menu=context('#page-target');results['page_context_page']={'ok': any(r['engine'] for r in menu['items']) and not any(r['key']=='link-copy' for r in menu['items']), 'items':menu['items']};app.call('context-menu-cancel')
        menu=context('#link-target');app.call('pasteboard-write',text='LINK NOT COPIED');picked=app.call('context-menu-select',key='link-copy')
        results['page_context_link']={'ok':picked and app.call('pasteboard')==origin+'/link' and all(any(r['key']==key for r in menu['items']) for key in ('link-open','link-new-tab','link-peek','link-copy')), 'items':menu['items']}
        menu=context('#image-target');app.call('pasteboard-write',text='IMAGE NOT COPIED');picked=app.call('context-menu-select',key='image-copy-url')
        results['page_context_image']={'ok':picked and app.call('pasteboard')==origin+'/image.svg' and any(r['key']=='image-new-tab' for r in menu['items']), 'items':menu['items']}
        menu=context('#selection-target',True);app.call('pasteboard-write',text='HIGHLIGHT NOT COPIED');picked=app.call('context-menu-select',key='selection-copy-link')
        results['page_context_selection']={'ok':picked and ':~:text=Distinct%20selection%20text' in app.call('pasteboard'), 'items':menu['items']}
        context('#link-target');before={t['id'] for t in app.call('tabs')};app.call('context-menu-select',key='link-new-tab')
        opened=wait_until(lambda:next((t for t in app.call('tabs') if t['id'] not in before and t['url']==origin+'/link'),None),timeout=5,step=.02)
        assert opened,app.call('tabs');app.call('select',tab=opened['id']);app.call('wait',tab=opened['id'])
        results['page_context_new_tab_engine']={'ok':app.eval(opened['id'],'document.title')=='Linked fixture' and opened['profile']==app.tab(tab)['profile']}
        app.call('select',tab=tab);app.call('focus',tab=tab)
        app.call('site-controls');site=app.call('site-controls-state')
        results['site_control_host_pending']={'status':'BLOCKED','reason':'pending #69','hostRequest':site}
        assert not site['available'] and site['requests']>0 and site['request']['profile']==app.tab(tab)['profile'] and site['request']['anchor'][2:]==[30,30],site
        # Relauch proves the remembered default-context values are durable.
        app.call('save');app.quit();app=factory(urls=());app.call('wait');app.call('select',tab=tab);app.call('wait',tab=tab)
        values=[app.call('permission-setting',tab=tab,origin=o,kind=8) for o,_,_ in remembered]
        results['permission_remember_relaunch']={'ok':values==[v for _,v,_ in remembered],'values':values}
        app.call('policy',dialogs='',permissions='',contextMenu='hold');app.call('focus',tab=tab)
        directory=Path(app.user_data)/'downloads';directory.mkdir(exist_ok=True)
        app.call('download-profile-options',directory=str(directory),ask=False)
        initial=app.call('downloads-show');results['downloads_empty']={'ok':initial['visible'] and initial['rows']==[],'state':initial}
        app.call('downloads-show')
        app.call('click',tab=tab,selector='#download-target')
        def download(name):return next((r for r in app.call('downloads-state')['rows'] if r['name']==name),None)
        started=wait_until(lambda:(lambda r:r if r and r['state']=='inProgress' and r['received']>0 and r['received']<len(payload) else None)(download('page-chrome.bin')),timeout=10,step=.05)
        assert started,app.call('downloads-state');app.call('downloads-show')
        shot(app, 'page-chrome-downloads.png')
        results['downloads_start_progress']={'ok':started['total']==len(payload) and started['path'].startswith(str(directory)) and app.call('downloads-state')['visible'],'row':started}
        assert app.call('downloads-action',id=started['id'],action='pause')['performed']
        last=[None,time.monotonic()]
        def bytes_stable():
            row=download('page-chrome.bin')
            if not row or row['state']!='paused':return None
            if row['received']!=last[0]:last[:]=[row['received'],time.monotonic()]
            return row if time.monotonic()-last[1]>=1 else None
        paused=wait_until(bytes_stable,timeout=4,step=.05)
        results['downloads_pause']={'ok':bool(paused) and paused['received']<len(payload),'row':paused}
        assert app.call('downloads-action',id=started['id'],action='resume')['performed']
        continued=wait_until(lambda:(lambda r:r if r and r['received']>(paused or started)['received'] else None)(download('page-chrome.bin')),timeout=5,step=.05)
        results['downloads_resume']={'ok':bool(continued),'row':continued}
        complete=wait_until(lambda:(lambda r:r if r and r['state']=='completed' else None)(download('page-chrome.bin')),timeout=20,step=.1)
        file=Path(complete['path']) if complete else directory/'missing'
        results['downloads_finish']={'ok':bool(complete) and file.exists() and file.read_bytes()==payload,'row':complete}
        # Cancel is a real failed/empty-path case, not a fake finished row.
        app.eval(tab,'document.querySelector("#download-target").href="'+origin+'/download-cancel.bin";true');app.call('click',tab=tab,selector='#download-target')
        cancel=wait_until(lambda:(lambda r:r if r and r['state']=='inProgress' else None)(download('cancel.bin')),timeout=5,step=.05)
        assert cancel,app.call('downloads-state');app.call('downloads-action',id=cancel['id'],action='cancel')
        cancelled=wait_until(lambda:(lambda r:r if r and r['state']=='cancelled' else None)(download('cancel.bin')),timeout=5,step=.05)
        results['downloads_cancel']={'ok':bool(cancelled) and not Path(cancelled['path']).exists(),'row':cancelled}
        reveal=app.call('downloads-action',id=started['id'],action='reveal')
        app.accept_file_reveal_handoff(reveal, str(file))
        results['downloads_show_in_finder']={'ok':reveal['performed'] and reveal['reveal']['id']==started['id'] and reveal['reveal']['path']==str(file) and file.exists(),
            'request':reveal,'boundary':'Real NSWorkspace reveal request and Finder foreground; Finder selection UI is not inspected.'}
    finally:
        app.quit()
        for server in servers:server.shutdown();server.server_close()


def feature_checks(app, style, results, tmp):
    t = new_tab(app, "https://en.wikipedia.org/wiki/Web_browser")
    app.call("policy", dialogs="accept", prompt="hello", permissions="grant", contextMenu="record",
             fullscreen="record")

    def run(name, fn):
        try:
            results[name] = fn()
        except FocusInterruption:
            raise
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
        # The Work profile's engine data lives in Profiles/<dir>/Engine
        # (docs/plans/profiles.md §5-6), separate from the default profile.
        engine_dir = os.path.join(app.user_data, "Profiles", ctx or "?", "Engine")
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
        cdm = os.path.join(app.user_data, "Profiles", "WidevineCdm")
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

    def ext_eval(page, js, timeout=20):
        return app.eval(page, js, timeout=timeout)

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
    pop = app.call("popup", extension=PROBE)["identifier"]
    wait_until(lambda: ext_eval(pop, "window.currentTab !== undefined"), timeout=20)
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
    made = ext_eval(pop, "chrome.tabs.create({url: 'https://example.net/?from=extension', active: true})"
                         ".then(t => ({id: t.id, windowId: t.windowId}))")
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
    ext_eval(pop, "chrome.tabs.update(%d, {active: true}).then(t => t.id)" % b_id)
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
    ext_eval(pop, "chrome.tabs.update(%d, {active: true}).then(t => t.id)" % s2_cid)
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
CONTEXT_MENU_SKIP_SUBMENUS = ("Speech", "Services")


def menu_key(title):
    """Titles compared by letters only: AppKit drops "&" ("Emoji  Symbols")."""
    return "".join(ch for ch in title.lower() if ch.isalnum())


def context_menu_commands(app, results):
    """Runs every Chrome context-menu command in a hosted tab, for each kind
    of target (page, link, image, video, selection, editable). None may
    crash the app (PR #53 review: toast and QR code paths). Dialogs and
    windows a command opens are dismissed through automation."""
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
            ran = []
            for command in commands:
                label = (command["submenu"] + " > " if command["submenu"] else "") + command["title"]
                if (not command["enabled"] or menu_key(command["title"]) in {menu_key(x) for x in CONTEXT_MENU_SKIP_TITLES}
                        or menu_key(command["submenu"]) in {menu_key(x) for x in CONTEXT_MENU_SKIP_SUBMENUS}):
                    report["skipped"].append("%s: %s%s" % (target, label, "" if command["enabled"] else " (disabled)"))
                    continue
                current = "%s: %s" % (target, label)
                point = prepare(target)
                app.call("policy", contextMenu="run:%d" % command["id"])
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
            report["targets"][target] = ran
            if crashed:
                break
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
        server.shutdown()
        subprocess.run(["pbcopy"], input=clipboard)
        shutil.rmtree(root, ignore_errors=True)
        if app.proc.poll() is None:
            app.call("policy", contextMenu="record")
    report["crashed"] = crashed
    report["video"] = video
    report["ok"] = not crashed and not report["failures"] and report["ran"] >= 20 and len(report["targets"]) == len(setups)
    results["context_menu_commands"] = report


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


def window_checks(app_factory, results, tmp, config):
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
        app.call("mouse", **{"from": [500, 300], "to": [190, 300]})
        narrow = app.call("window-state")
        results["resize_limits"] = {"ok": wide["sidebarWidth"] == 500 and narrow["sidebarWidth"] == 228 and narrow["sidebarMode"] == "anchored"}
        app.call("mouse", **{"from": [228, 300], "to": [170, 300]})
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
        app.call("mouse", **{"from": [228, 300], "to": [300, 300]})
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
        request = app.eval(c, 'document.documentElement.requestFullscreen().then(() => "ok", e => e.message)')
        page_full = wait_until(lambda: app.call("window-state")["pageFullscreen"], timeout=5, step=0.1)
        page_state = app.call("window-state")
        app.call("fullscreen-exit", tab=c)
        page_exit = wait_until(lambda: not app.call("window-state")["pageFullscreen"], timeout=5, step=0.1)
        after_page = app.call("window-state")
        results["html_fullscreen_in_native"] = {"ok": request == "ok" and bool(page_full) and bool(page_exit)
            and not page_state["sidebarVisible"] and page_state["panel"] == [0, 0] + page_state["frame"][2:]
            and after_page["fullscreen"] and after_page["sidebarVisible"] and after_page["panel"][0] == 228,
            "page_state": page_state, "after_exit": after_page}
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
RING_COLORS = {"light": [(219, 59, 60), (212, 162, 1), (47, 181, 19)], "dark": [(254, 129, 121), (254, 206, 63), (112, 210, 73)]}


def dimmed_look(png, scale, centers, mode, ring=True):
    """Rest look at each button against the expected composite over the background sampled
    between buttons: the fill at the center (±5 levels) and, on dark content, the ring at
    r 6.5. `ring` is the expectation: in an active window the colored ring (±12 levels: an
    anti-aliased pixel), in an inactive one none (the pixel nearer the plain background than
    the colored ring). On light content the ring is only 0.06, so it is not checked."""
    _, _, px = read_image(png)
    tok, fill_a, ring_a = DIMMED_LOOK[mode]
    rows, ok = [], True
    for index, (cx, cy) in enumerate(centers):
        core = [sum(px((cx + dx) * scale, (cy + dy) * scale)[k] for dx in (-1.5, -0.5, 0.5) for dy in (-1.5, -0.5, 0.5)) / 9 for k in range(3)]
        bg = [sum(px((cx + 11.5) * scale, (cy + dy) * scale)[k] for dy in (-2, 0, 2)) / 3 for k in range(3)]
        expected = [bg[k] * (1 - fill_a) + tok[k] * fill_a for k in range(3)]
        fill_err = max(abs(core[k] - expected[k]) for k in range(3))
        ring_px = px((cx - 6.5) * scale, cy * scale)
        ring_expected = [bg[k] * (1 - ring_a) + RING_COLORS[mode][index][k] * ring_a for k in range(3)]
        ring_err = max(abs(ring_px[k] - ring_expected[k]) for k in range(3))
        plain_err = max(abs(ring_px[k] - bg[k]) for k in range(3))
        ring_ok = mode == "light" or (ring_err <= 12 if ring else plain_err < ring_err)
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
        results["durable_profile_storage"] = {"status": "BLOCKED", "reason": "CEF root_cache_path non-default profile storage; docs/followups.md. Wrapper/page switching is not durable-storage proof."}
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


def main():
    global _ACTIVE_FOCUS_TRACKER
    ap = argparse.ArgumentParser()
    ap.add_argument("--style", default="alloy", choices=["alloy", "chrome"])
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--extensions", default=os.path.join(ROOT, ".re", "ext", "unpacked"))
    ap.add_argument("--only", choices=["shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek", "commandbar", "actions", "page-chrome"],
                    required=True)
    opts = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    tmp = os.path.join(ROOT, ".re", "e2e-%s-%s" % (opts.only, opts.style))
    user_data = os.path.join(tmp, "user-data")
    shutil.rmtree(user_data, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    extra = ["--use-mock-keychain"]
    if opts.only in ("features", "page-chrome"):
        extra += ["--load-extension=" + os.path.join(ROOT, "tools/e2e/fixtures/page-chrome-extension"), "--disable-features=DisableLoadExtensionCommandLineSwitch"]
    if opts.only == "extensions":
        dirs = [os.path.join(opts.extensions, d) for d in ("ublock-lite", "darkreader", "1password", "bitwarden")]
        if not all(os.path.isdir(d) for d in dirs):
            sys.exit("missing unpacked extensions in %s" % opts.extensions)
        extra += ["--load-extension=" + ",".join(dirs), "--disable-features=DisableLoadExtensionCommandLineSwitch"]
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
    framework = 'Chromium Embedded Framework.framework/Chromium Embedded Framework'
    embedded = framework_uuid(os.path.join(ROOT, 'build', opts.config, 'Open.app/Contents/Frameworks', framework))
    vendor = framework_uuid(os.path.join(ROOT, 'Vendor/cef/Release', framework))
    stamp_path = os.path.join(ROOT, 'Vendor/cef/.open-source')
    stamp = Path(stamp_path).read_text().strip() if os.path.exists(stamp_path) else ''
    results['engine'] = {'source': 'fork' if stamp.startswith('fork ') and embedded and embedded == vendor else 'unconfirmed', 'embeddedUUID': embedded, 'distributionUUID': vendor, 'stamp': stamp}
    def execute():
        if opts.only == "shell":
            results["shell"] = CheckedResults(tracker)
            shell_checks(factory, results["shell"], tmp)
        elif opts.only in ("commandbar", "actions"):
            results[opts.only] = CheckedResults(tracker)
            commandbar_checks(factory, results[opts.only], tmp, opts.config)
        elif opts.only == "page-chrome":
            results[opts.only] = CheckedResults(tracker)
            page_chrome_checks(factory, results[opts.only], tmp)
        elif opts.only == "window":
            results["window"] = CheckedResults(tracker)
            window_checks(factory, results["window"], tmp, opts.config)
        elif opts.only == "sidebar":
            results["sidebar"] = CheckedResults(tracker)
            sidebar_checks(factory, results["sidebar"], tmp)
        elif opts.only == "peek":
            results["peek"] = CheckedResults(tracker)
            peek_checks(factory, results["peek"], tmp)
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
                    tabstrip_checks(app, results["tabstrip"])
                else:
                    feature_checks(app, opts.style, results["features"], tmp)
            finally:
                app.quit()
            if opts.only == "features":
                page_chrome_checks(factory, results["features"], tmp)

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
            loss = tracker.loss()
            if loss:
                interruption = {"reason": str(error), "focus": loss}
            else:
                dict.__setitem__(results.setdefault(opts.only, {}), "suite", {"ok": False, "error": str(error)})
                traceback.print_exc()
        finally:
            for instance in tracker.apps:
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
    name = "results-%s-%s.json" % (opts.only, opts.style if opts.only in ("extensions", "features", "tabstrip")
                                   else opts.config.lower())
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(results, f, indent=2, sort_keys=True)
    for group in ("shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek", "commandbar", "actions", "page-chrome"):
        for k, v in results.get(group, {}).items():
            if isinstance(v, dict) and "ok" in v:
                print("%-24s %s" % (k, "PASS" if v.get("ok") else "FAIL"))
            elif isinstance(v, dict) and v.get("status") in ("SKIP", "BLOCKED", "INTERRUPTED"):
                print("%-24s %s: %s" % (k, v["status"], v.get("reason", "")))
    print("wrote", os.path.join(OUT, name))
    failures = [k for group in ("shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek", "commandbar", "actions", "page-chrome")
                for k, v in results.get(group, {}).items() if isinstance(v, dict) and v.get("ok") is False]
    if failures:
        sys.exit(1)
    if any(isinstance(v, dict) and v.get("status") == "INTERRUPTED" for v in results.get(opts.only, {}).values()):
        sys.exit(2)


if __name__ == "__main__":
    main()
