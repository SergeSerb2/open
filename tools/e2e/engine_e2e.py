#!/usr/bin/env python3 -I
"""End-to-end checks for OpenEngine and the M1 shell (docs/engine-spike.md).

Launches the real Open.app with a fresh profile, drives it only through the
automation socket (docs/automation.md), and writes results plus screenshots
of OUR windows to docs/engine-spike/. Nothing here touches other apps or the
system mouse and keyboard.

  tools/e2e/engine_e2e.py --only shell
  tools/e2e/engine_e2e.py --style alloy  --only features
  tools/e2e/engine_e2e.py --style alloy  --only extensions
  tools/e2e/engine_e2e.py --style chrome --only extensions
  tools/e2e/engine_e2e.py --config Release --only measure

Extensions are unpacked CRX folders (tools/crx-unpack.py) in
.re/ext/unpacked/{ublock-lite,darkreader,1password,bitwarden}.
"""
import argparse
import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
import traceback

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
    def __init__(self, config, style, user_data, extra_args, log_path, urls=("about:blank",)):
        self.user_data = user_data
        self.sock = os.path.join(user_data, "automation.sock")
        app = os.path.join(ROOT, "build", config, "Open.app", "Contents", "MacOS", "Open")
        env = dict(os.environ, OPEN_USER_DATA=user_data)
        args = [app, "--style=%s" % style] + list(urls) + extra_args
        self.log = open(log_path, "a")
        self.started = time.time()
        self.proc = subprocess.Popen(args, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                self.call("ping")
                return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("Open did not start")

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
        return {"ok": "oe_profile" not in r["cookie"] and r["storage"] is None and ctx == "Work",
                "work_profile_sees": r, "work_tab_context": ctx, "work_space": work_space}

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
        cdm = os.path.join(app.user_data, "WidevineCdm")
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--style", default="alloy", choices=["alloy", "chrome"])
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--extensions", default=os.path.join(ROOT, ".re", "ext", "unpacked"))
    ap.add_argument("--only", choices=["shell", "extensions", "features", "measure"], required=True)
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
    log = os.path.join(tmp, "open.log")

    def factory(urls=("about:blank",)):
        return Open(opts.config, opts.style, user_data, extra, log, urls=urls)

    results = {"style": opts.style, "config": opts.config, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    if opts.only == "shell":
        results["shell"] = {}
        shell_checks(factory, results["shell"], tmp)
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
            else:
                feature_checks(app, opts.style, results["features"], tmp)
        finally:
            app.quit()
    name = "results-%s-%s.json" % (opts.only, opts.style if opts.only in ("extensions", "features") else opts.config.lower())
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(results, f, indent=2, sort_keys=True)
    for group in ("shell", "extensions", "features", "measure"):
        for k, v in results.get(group, {}).items():
            if isinstance(v, dict) and "ok" in v:
                print("%-24s %s" % (k, "PASS" if v.get("ok") else "FAIL"))
    print("wrote", os.path.join(OUT, name))


if __name__ == "__main__":
    main()
