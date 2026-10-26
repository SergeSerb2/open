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
import json
import math
import glob
import re
import os
import shutil
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

EXT = {
    "ublock": "ddkjiahejlhfcafbddmgiahcphecmpfh",
    "darkreader": "eimadpbcbfnmbkopoojfekhnkhdbieeh",
    "1password": "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
    "bitwarden": "nngceckbapebfimnlniiiahkandclblb",
}
CWS_TEST_ID = "aapbdbdomjkkjkaonfhkkikfgjllcleb"  # Google Translate (MV3)


class Open:
    def __init__(self, config, style, user_data, extra_args, log_path, urls=("about:blank",), extra_env=None):
        self.user_data = user_data
        self.sock = os.path.join(user_data, "automation.sock")
        app = os.path.join(ROOT, "build", config, "Open.app", "Contents", "MacOS", "Open")
        env = dict(os.environ, OPEN_USER_DATA=user_data)
        env.update(extra_env or {})
        args = [app, "--style=%s" % style] + list(urls) + extra_args
        self.log = open(log_path, "a")
        self.started = time.time()
        self.proc = subprocess.Popen(args, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                self.call("ping")
                return
            except (OSError, json.JSONDecodeError):
                time.sleep(0.1)
            if self.proc.poll() is not None:
                self.log.close()
                raise RuntimeError("Open exited before automation; see %s" % log_path)
        self.proc.kill()
        self.proc.wait()
        self.log.close()
        raise RuntimeError("Open did not start; see %s" % log_path)

    def call(self, cmd, timeout=120, **args):
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
        if not resp.get("ok"):
            raise RuntimeError("%s: %s" % (cmd, resp.get("error")))
        return resp["result"]

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
        try:
            self.call("quit")
        except Exception:
            pass
        try:
            self.proc.wait(15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.log.close()

    def tab(self, tab_id):
        return [t for t in self.call("tabs") if t["id"] == tab_id][0]

    def page(self, tab_id):
        return self.tab(tab_id).get("page", {})


def shot(app, name, window=None, max_px=1100):
    """PNG of one of OUR windows. The main window uses the in-app snapshot
    (includes Chrome-style child windows and real page pixels); other
    windows (panels, Chromium dialogs) use `screencapture -l <our window>`,
    falling back to the in-app snapshot."""
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
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
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
        route["cmd_l_window"] = app.call("key", key="l", modifiers=["cmd"], route="window")["firstResponder"]
        app.call("focus", tab=c)
        time.sleep(0.2)
        route["cmd_t_app"] = app.call("key", key="t", modifiers=["cmd"])["firstResponder"]
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
            "ok": route["cmd_l_window"] == "NSTextView" and route["cmd_t_app"] == "NSTextView"
                  and len(new) == 1 and n1 == n0 + 1 and n2 == n0 and len(restored) == 1,
            "routes": route, "tabs": [n0, n1, n2], "restored_same_id": bool(restored)}

        # Split View: two live pages side by side in one window.
        app.call("select", tab=b)
        panes = app.call("split")
        time.sleep(2)
        pages = [x["page"] for x in app.call("tabs") if x["visible"] and x.get("page")]
        wins = app.call("windows")
        results["split_view"] = {"ok": len(panes) == 2 and len(pages) == 2 and all(p["live"] for p in pages),
                                 "panes": [p["url"] for p in pages]}
        results["split_view"]["screenshot"] = shot(app, "shell-split-view.png")
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
    t0 = time.time()
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
    menus = {}
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
        if not crashed:
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
        server.shutdown()
        subprocess.run(["pbcopy"], input=clipboard)
        shutil.rmtree(root, ignore_errors=True)
        if app.proc.poll() is None:
            app.call("policy", contextMenu="record")
    report["crashed"] = crashed
    report["video"] = video
    report["ok"] = not crashed and not report["failures"] and report["ran"] >= 20 and len(report["targets"]) == len(setups)
    results["context_menu_commands"] = report

    # The allowlist: no dropped Chrome item, the kept ones, extension items,
    # and no empty, leading, trailing or doubled separators.
    allow = {"menus": menus, "dropped_seen": {}, "kept_missing": {}, "separators": {}}
    for target, items in menus.items():
        titles = [x for x in items if x]
        seen = [x for x in titles if any(d in menu_key(x) for d in CONTEXT_MENU_DROPPED)]
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
    with open(app.log.name, errors="replace") as f:
        log_text = f.read()
    results["context_menu_hidden_command_refused"] = {
        "ok": bool(hidden) and not hidden["new_windows"] and not hidden["window_requests"]
              and not hidden["foreign_windows"] and ("refused command %d" % hidden.get("id")) in log_text,
        **hidden}


# ----------------------------------------------------------------------------
# Window startup checks (Step A; Step B extends this suite).


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
    start = time.time()
    samples, still = [], 0
    while time.time() - start < timeout:
        st = app.call("window-state")
        r = st["reveal"]
        samples.append([round(time.time() - start, 3), r["phase"], r["offset"]])
        if shown:
            still = still + 1 if st["revealed"] and r["offset"] is not None and abs(r["offset"]) <= 0.5 else 0
            if still >= 3:
                return {"elapsed": round(time.time() - start, 3), "samples": len(samples), "state": st}
        elif not st["revealed"] and r["offset"] is None:
            return {"elapsed": round(time.time() - start, 3), "samples": len(samples), "state": st}
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
    """Center of the system-drawn circle near (cx, cy) points: contrast-weighted centroid of
    the pixels that differ from the background between two buttons."""
    _, _, px = read_image(png)
    bg = px((cx + 11.5) * scale, cy * scale)
    sx = sy = sw = 0.0
    for y in range(int((cy - 9) * scale), int((cy + 9) * scale)):
        for x in range(int((cx - 9) * scale), int((cx + 9) * scale)):
            c = px(x, y)
            d = max(abs(c[i] - bg[i]) for i in range(3))
            if d > 24:
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
    underlay, so the window is made key again right before each one."""
    wid = app.call("window-state")["id"]
    settled = reveal_card_and_wait(app)
    if not settled:
        return None
    card = settled["state"]["reveal"]["card"]
    png = os.path.join(private, name + ".png")
    app.call("mouse", action="move", x=120, y=400)
    app.call("window-focus", id=wid, activate=True)
    app.call("snapshot", path=png)
    app.call("mouse", action="move", x=700, y=400)
    wait_card(app, False)
    base = os.path.join(private, name + "-base.png")
    app.call("window-focus", id=wid, activate=True)
    app.call("snapshot", path=base)
    return png, base, card


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
        app.call("snapshot", path=card_png)
        t1 = time.time()
        app.call("mouse", action="move", x=700, y=400)
        leaving = state_when(app, lambda st: st["reveal"]["phase"] == "idle", timeout=2, step=0.01)
        exit_s = round(time.time() - t1, 3)
        gone = wait_card(app, False)
        base_png = os.path.join(private, "card-base.png")
        app.call("window-focus", id=wid, activate=True)
        app.call("snapshot", path=base_png)
        results["reveal_timing"] = {"ok": lights_hidden and no_quick_reveal and bool(settled) and 0.13 <= dwell <= 0.35
                                    and lights_card_ok and no_flicker and bool(leaving) and 0.13 <= exit_s <= 0.6 and bool(gone),
                                    "lights_hidden_while_hidden": lights_hidden, "pass_by_without_reveal": no_quick_reveal,
                                    "dwell_s": round(dwell, 3), "settled_s": settled and settled["elapsed"],
                                    "card": card, "lights_on_card": lights_card, "edge_walk": samples, "held": held,
                                    "exit_to_idle_s": exit_s, "slide_out_s": gone and gone["elapsed"]}
        results["card_edges_1x"] = card_edges(card_png, base_png, card, scale)
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
    app_path = app.proc.args[0]
    app.quit()
    unconfirmed = factory(urls=("data:text/html,<title>Unconfirmed frame</title><h1>Unconfirmed frame</h1>",), fresh=True,
                          extra_env={"OPEN_AUTOMATION_SKIP_DISPLAY_LINK": "1"})
    try:
        tab = unconfirmed.call("tabs")[0]
        unconfirmed.call("wait", tab=tab["id"])
        timing = unconfirmed.call("timing")
        results["first_frame_timeout_continues"] = {"ok": timing["firstFrameConfirmed"] is False
            and "sidebarDrawn" not in timing and timing["firstFrameWaitTimedOut"] >= 3000
            and timing["engineStart"] >= timing["firstFrameWaitTimedOut"] and "engineStarted" in timing
            and unconfirmed.eval(tab["id"], "document.title") == "Unconfirmed frame",
            "timing": timing, "hosts": unconfirmed.call("host-counts")}
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
    def actions():
        return app.call("actions")

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
              and on_a["toolbarImage"]["hash"] != on_b["toolbarImage"]["hash"]
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
        api["key"] = app.call("activate")["key"]
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
        refusal["key"] = app.call("activate")["key"]
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

    # A tab switch closes the popup (Chrome's ExtensionPopup does).
    app.call("select", tab=a)
    state = open_popup(ACTION_PROBE)
    if state:
        app.call("select", tab=b)
    switched = wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10)
    app.call("select", tab=a)
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
    ran = {}
    for prefix in ("Pin", "Manage Extension", "View Web Permissions", "Remove from"):
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
            r["dialog"] = wait_until(lambda: [w["class"] for w in app.call("windows") if w["visible"]
                                              and w["number"] not in before_windows], timeout=10)
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
    results["action_menu_commands"] = {"ok": all(v["ok"] for v in ran.values()), "commands": ran}
    popup_teardown_checks(app, results, actions, action, popup_eval, open_popup, close_popup, a)


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
    # action comes back (same pin), and the new version runs.
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
        r["pinned"] = bool(back and back["pinned"])
        installed = [e for e in app.call("extensions")["installed"] if e["id"] == ACTION_PROBE]
        r["version"] = installed[0]["version"] if installed else None
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
    told = [e for e in app.call("events")]
    idle = {"not_ready": bool(gone)}
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
    results["no_live_tab_actions"] = {
        "ok": idle["not_ready"] and bool(idle.get("listed")) and idle["listed"]["pinned"] and not idle["listed"]["live"]
              and idle.get("ran") is False and not idle.get("popup") and idle["live_again"],
        **idle}

    # Closing the Open window with a popup open closes the popup with it;
    # the app keeps running, and a reopened window works.
    app.call("select", tab=fresh)
    time.sleep(0.5)
    state = open_popup(bitwarden)
    closing = {"opened": bool(state)}
    popup_page = state["page"]["identifier"] if state else None
    app.call("window-close")
    closing["windows_after_close"] = wait_until(lambda: len(app.call("shell-windows")) == 0, timeout=10)
    closing["alive"] = app.call("ping") is not None
    app.call("window-reopen")
    wait_until(lambda: app.call("shell-windows"), timeout=10)
    closing["popup_page_gone"] = bool(wait_until(lambda: popup_page not in [p["identifier"] for p in app.call("pages")],
                                                 timeout=10))
    closing["new_window_popup"] = app.call("ext-popup").get("open")
    results["window_close_with_popup"] = {
        "ok": closing["opened"] and bool(closing["windows_after_close"]) and closing["alive"] and closing["popup_page_gone"]
              and not closing["new_window_popup"],
        **closing}


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


def engine_provenance(config):
    def uuid(path):
        result = subprocess.run(['dwarfdump', '--uuid', path], capture_output=True, text=True)
        match = re.search(r'UUID: ([0-9A-F-]+)', result.stdout)
        return match.group(1) if match else ''
    framework = 'Chromium Embedded Framework.framework/Chromium Embedded Framework'
    embedded = uuid(os.path.join(ROOT, 'build', config, 'Open.app/Contents/Frameworks', framework))
    vendor = uuid(os.path.join(ROOT, 'Vendor/cef/Release', framework))
    stamp_file = Path(ROOT, 'Vendor/cef/.open-source')
    stamp = stamp_file.read_text().strip() if stamp_file.exists() else ''
    return {'source': 'fork' if stamp.startswith('fork ') and embedded and embedded == vendor else 'unconfirmed',
            'embeddedUUID': embedded, 'distributionUUID': vendor, 'stamp': stamp}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--style", default="alloy", choices=["alloy", "chrome"])
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--extensions", default=os.path.join(ROOT, ".re", "ext", "unpacked"))
    ap.add_argument("--only", choices=["shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek",
                                       "actions"],
                    required=True)
    opts = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    tmp = os.path.join(ROOT, ".re", "e2e-%s-%s" % (opts.only, opts.style))
    user_data = os.path.expanduser("~/Library/Application Support/Open-E2E-%s-%s" % (opts.only, opts.style))
    shutil.rmtree(user_data, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
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
    if opts.only == "tabstrip":
        dirs = [os.path.join(ROOT, "tools", "e2e", "fixtures", "tabs-probe"), os.path.join(opts.extensions, "bitwarden")]
        if not all(os.path.isdir(d) for d in dirs):
            sys.exit("missing extensions: %s" % dirs)
        extra += ["--load-extension=" + ",".join(dirs), "--disable-features=DisableLoadExtensionCommandLineSwitch"]
    log = os.path.join(tmp, "open.log")

    def factory(urls=("about:blank",), fresh=False, snapshot=None, extra_env=None):
        if fresh or snapshot:
            shutil.rmtree(user_data, ignore_errors=True)
        if snapshot:
            os.makedirs(os.path.join(user_data, "State"), exist_ok=True)
            shutil.copyfile(snapshot, os.path.join(user_data, "State", "browser.json"))
        return Open(opts.config, opts.style, user_data, extra, log, urls=urls, extra_env=extra_env)

    results = {"style": opts.style, "config": opts.config, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    results["engine"] = engine_provenance(opts.config)
    try:
        if opts.only == "shell":
            results["shell"] = {}
            shell_checks(factory, results["shell"], tmp)
        elif opts.only == "window":
            results["window"] = {}
            window_checks(factory, results["window"], tmp, opts.config)
        elif opts.only == "sidebar":
            results["sidebar"] = {}
            sidebar_checks(factory, results["sidebar"], tmp)
        elif opts.only == "peek":
            results["peek"] = {}
            peek_checks(factory, results["peek"], tmp)
        elif opts.only == "measure":
            results["measure"] = {}
            measure(factory, results["measure"], tmp)
        else:
            app = factory(urls=("https://example.com/",))
            try:
                results["ping"] = app.call("ping")
                app.call("window-frame", frame=[80, 60, 1360, 860])
                results[opts.only] = {}
                if opts.only == "extensions":
                    extension_checks(app, opts.style, results["extensions"])
                elif opts.only == "tabstrip":
                    tabstrip_checks(app, results["tabstrip"])
                elif opts.only == "actions":
                    actions_checks(app, results["actions"])
                else:
                    feature_checks(app, opts.style, results["features"], tmp)
            finally:
                app.quit()
    except Exception as error:
        results.setdefault(opts.only, {})["suite"] = {"ok": False, "error": str(error)}
        traceback.print_exc()
    name = "results-%s-%s.json" % (opts.only, opts.style if opts.only in ("extensions", "features", "tabstrip", "actions")
                                   else opts.config.lower())
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(results, f, indent=2, sort_keys=True)
    for group in ("shell", "extensions", "features", "measure", "tabstrip", "window", "sidebar", "peek", "actions"):
        for k, v in results.get(group, {}).items():
            if isinstance(v, dict) and "ok" in v:
                print("%-24s %s" % (k, "PASS" if v.get("ok") else "FAIL"))
            elif isinstance(v, dict) and v.get("status") in ("SKIP", "BLOCKED"):
                print("%-24s %s: %s" % (k, v["status"], v.get("reason", "")))
    print("wrote", os.path.join(OUT, name))
    failures = [k for group in ("shell", "extensions", "features", "measure", "window", "sidebar", "peek", "actions")
                for k, v in results.get(group, {}).items() if isinstance(v, dict) and v.get("ok") is False]
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
