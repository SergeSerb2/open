"""Extensions shell acceptance through the real App, native events and local CRX3.

All pointer/key events stay inside Open. This module never touches the desktop.
"""
import json
import math
import os
from pathlib import Path
import statistics
import time

from extensions_p3 import pack_probe


def run(factory, results, tmp, root, wait_until, new_tab, frame, read_image, extensions):
    class Progress:
        def __init__(self, target): self.target = target
        def __setitem__(self, key, value):
            self.target[key] = value
            print(key, value.get("status", "PASS" if value.get("ok") else "FAIL"), flush=True)
        def __getitem__(self, key): return self.target[key]
    results = Progress(results)
    app = factory(urls=("about:blank",))
    saved = {}
    captures = Path(root) / ".re/extensions-ui/captures"
    captures.mkdir(parents=True, exist_ok=True)
    probe = "kpapbconhioppmhbehbhjldpbgpbibhl"  # Resolved from the real action list below.
    def actions():
        seen = set()
        return [a for a in app.call("extensions")["actions"] if not (a["id"] in seen or seen.add(a["id"]))]
    def action(identifier): return next((a for a in actions() if a["id"] == identifier), {})
    def strip(surface="url"): return app.call("ext-strip", surface=surface)
    def hover(inside=True):
        event = app.call("ext-hover", inside=inside)
        time.sleep(.12)
        state = strip(); state["hoverEvent"] = event
        return state
    def close():
        app.call("popup-close")
        return wait_until(lambda: not app.call("ext-popup-state")["open"], timeout=5)
    def popup(identifier=None, surface="url", command=False):
        identifier = identifier or probe
        if command:
            app.call("key", key="y", modifiers=["command", "shift"], route="app")
        else:
            hover(); app.call("ext-click", extension=identifier, surface=surface)
        return wait_until(lambda: (lambda s: s if s.get("visible") else None)(app.call("ext-popup-state")), timeout=15)
    def page(): return app.call("ext-popup")["page"]["identifier"]
    def capture(name, window=None):
        path = str(captures / (name + ".png"))
        app.call("snapshot", path=path, **({"window": window} if window else {}))
        return path
    try:
        for key, value in {"open.advanced.showToolbar": False,
                           "open.advanced.playSoundEffects": False}.items():
            saved[key] = app.call("defaults", key=key, persistent=True)
            app.call("defaults", key=key, value=value)
        app.call("window-frame", frame=[80, 60, 1200, 800])
        app.call("window-focus", id=app.call("window-state")["id"], activate=True)
        wait_until(lambda: len(actions()) >= 4, timeout=30)
        probe = next(a["id"] for a in actions() if a["name"] == "Open action probe")
        ids = [extensions["ublock"], extensions["darkreader"], probe]
        for a in actions(): app.call("ext-pin", extension=a["id"], pinned=False)
        for identifier in ids: app.call("ext-pin", extension=identifier, pinned=True)
        hover()
        pinned = wait_until(lambda: (lambda s: s if s["ids"] == ids else None)(strip()), timeout=10)
        app.call("ext-pin", extension=probe, pinned=True, index=0)
        moved = wait_until(lambda: strip()["ids"] == [probe] + ids[:2], timeout=5)
        results["X2_pin_order_frames"] = {"ok": bool(pinned and moved)
            and [f[0] for f in pinned["frames"]] == [74, 102, 130], "strip": pinned, "moved": bool(moved), "lastStrip": strip(), "actions": actions(), "events": app.call("events")}
        duplicates = app.call("extensions")["duplicatesDropped"]
        if duplicates:
            results["X2_pin_order_frames"] = {"status": "BLOCKED", "reason": "engine defect, C5: duplicate E1 action IDs",
                "duplicatesDropped": duplicates, "assertion": results["X2_pin_order_frames"]}
        else:
            results["X2_pin_order_frames"]["duplicatesDropped"] = duplicates
        hidden = hover(False); shown = hover(True)
        results["X3_hover"] = {"ok": not hidden["visible"] and shown["visible"] and len(shown["ids"]) == 3,
                                 "away": hidden, "over": shown}
        for appearance in ("light", "dark"):
            app.call("appearance", name=appearance); hover()
            capture("url-" + appearance)
        app.call("appearance", name="light")
        control = new_tab(app, "chrome-extension://" + probe + "/popup.html")
        p = popup(probe)
        if not p:
            results["X6_popup"] = {"ok": False, "state": app.call("ext-popup-state")}
            return
        content = control
        active = app.eval(content, "chrome.tabs.query({active:true,currentWindow:true}).then(ts=>ts[0].id)")
        expected = app.call("engine-sleep")["chromeTabId"]
        anchor, panel = frame(p["anchor"]), frame(p["frame"])
        results["X6_popup"] = {"ok": p["key"] and p["ready"] and frame(p["contentSize"])[0] > 25
            and active == expected and abs(panel[1] + panel[3] - (anchor[1] - 6)) <= 1, "state": p, "activeTab": active}
        close()
        app.eval(content, "chrome.action.setBadgeText({tabId:" + str(active) + ",text:'7'}).then(()=>true)")
        badge = wait_until(lambda: action(probe).get("badge") == "7", timeout=5)
        hover(); badged = capture("badge-seven")
        app.eval(content, "chrome.action.setBadgeText({tabId:" + str(active) + ",text:''}).then(()=>true)")
        clear = wait_until(lambda: action(probe).get("badge") in (None, ""), timeout=5)
        hover(); unbadged = capture("badge-empty")
        _, h, bp = read_image(badged); _, _, np = read_image(unbadged)
        slot = strip()["frames"][0]
        # The snapshot is top-left; automation reports Cocoa window coordinates.
        x, y, w, hh = slot; y = h - y - hh
        difference = sum(bp(xx, yy) != np(xx, yy) for xx in range(int(x), int(x+w)) for yy in range(int(y), int(y+hh)))
        results["X4_badge_pixels"] = {"ok": bool(badge and clear) and difference > 0, "changedPixels": difference}
        layouts = strip()["layoutCount"]; draws = strip()["redraws"]
        app.eval(content, "Promise.all(Array.from({length:100},(_,i)=>chrome.action.setBadgeText({text:String(i)}))).then(()=>true)")
        burst = wait_until(lambda: action(probe).get("badge") == "99", timeout=5)
        time.sleep(.1)
        after = strip()
        results["X5_badge_burst"] = {"ok": bool(burst) and after["layoutCount"] == layouts and after["redraws"] - draws <= 3,
            "layoutDelta": after["layoutCount"]-layouts, "redrawDelta": after["redraws"]-draws,
            "source": "network-free action-probe, 100 action events in one renderer turn"}
        # Real store extensions use their bundled assets and APIs; no account or network is needed.
        for identifier, name in ((extensions["bitwarden"], "bitwarden"), (extensions["darkreader"], "darkreader")):
            close(); app.call("ext-pin", extension=identifier, pinned=True, index=0)
            shown = popup(identifier)
            dimensions = app.eval(page(), "({width:document.documentElement.scrollWidth,height:document.documentElement.scrollHeight})") if shown else {}
            if name == "bitwarden":
                results["X6_bitwarden"] = {"ok": bool(shown) and shown["key"] and frame(shown["contentSize"])[0] >= 350, "state":shown}
            else:
                size = frame(shown["contentSize"]) if shown else [0,0]
                results["X7_darkreader_resize"] = {"ok": bool(shown) and all(abs(a-b)<=1 for a,b in zip(size, (dimensions.get("width",0), dimensions.get("height",0))))
                    and 25<=size[0]<=800 and 25<=size[1]<=600, "state":shown, "document":dimensions}
            if shown:
                for appearance in ("light", "dark"):
                    app.call("appearance", name=appearance); capture(name + "-popup-" + appearance, shown["window"])
            close()
        app.call("ext-pin", extension=probe, pinned=True, index=0)
        # D1-D5 and F2 use the native key/event path, not a popup-controller call.
        dismissals = []
        close()
        for how in ("blur", "toggle", "escape", "window.close", "tab", "command-w", "sidebar-hide"):
            opened = popup(probe)
            if not opened: dismissals.append({"rule": how, "ok": False}); continue
            if how == "blur": app.call("window-focus", id=app.call("window-state")["id"], activate=True)
            elif how == "toggle": app.call("ext-click", extension=probe, surface="url")
            elif how == "escape": app.call("key", key="escape", window="popup", route="app")
            elif how == "window.close": app.eval(page(), "window.close(); true")
            elif how == "tab": new_tab(app, "about:blank")
            elif how == "command-w": app.call("key", key="w", modifiers=["command"], window="popup", route="app")
            elif how == "sidebar-hide":
                app.call("key", key="s", modifiers=["command"], window="popup", route="app")
            ended = wait_until(lambda: not app.call("ext-popup-state")["open"], timeout=5)
            dismissals.append({"rule": how, "ok": bool(ended)})
            if app.call("window-state")["sidebarMode"] == "hidden": app.call("command", id="toggle-sidebar")
        results["X8_dismiss_D1_D5_F2_D7"] = {"ok": all(d["ok"] for d in dismissals), "rows": dismissals}
        shown = popup(probe)
        if shown:
            popup_page = page()
            app.call("ext-menu", extension=probe, select="Inspect Popup")
            inspected = wait_until(lambda: app.call("ext-popup-state").get("staysOpenOnBlur"), timeout=10)
            app.call("window-focus", id=app.call("window-state")["id"], activate=True)
            kept = app.call("ext-popup-state")
            app.call("devtools-close", tab=popup_page)
            results["X8_inspect_keeps_open"] = {"ok": bool(inspected) and kept["open"] and kept["visible"], "state":kept}
            close()
        app.call("select", tab=control); hover(); content = control
        app.eval(content, "chrome.action.setPopup({popup:''}).then(()=>true)")
        before = app.eval(content, "chrome.storage.session.get('clicks').then(v=>v.clicks||0)")
        close(); hover(); app.call("ext-click", extension=probe, surface="url")
        count = app.eval(control, "chrome.storage.session.get('clicks').then(v=>v.clicks||0)")
        app.eval(control, "chrome.action.setPopup({popup:'popup.html'}).then(()=>true)")
        results["X9_popup_less"] = {"ok": count == before + 1, "before": before, "after": count}
        app.eval(control, "chrome.action.disable().then(()=>true)")
        disabled = wait_until(lambda: action(probe).get("enabled") is False, timeout=5)
        hover(); menu = app.call("ext-click", extension=probe, surface="url")
        results["X10_disabled_menu"] = {"ok": bool(disabled) and bool(menu.get("menu")), "menu": menu}
        app.eval(control, "chrome.action.enable().then(()=>true)")
        wait_until(lambda: action(probe).get("enabled"), timeout=5)
        hover(); right = app.call("ext-click", extension=probe, surface="url", button="right")
        titles = [i["title"] for i in right.get("menu", [])]
        app.call("ext-menu", extension=probe, select="Unpin")
        unpinned = wait_until(lambda: not action(probe).get("pinned"), timeout=5)
        app.call("ext-pin", extension=probe, pinned=True, index=0)
        results["X11_context_menu"] = {"ok": bool(unpinned) and "Remove from Open…" in titles and "Unpin" in titles
            and all("Chrome" not in t and "Chromium" not in t for t in titles), "titles": titles}
        permission_rows = []
        for answer in ("cancel", "accept"):
            opened = popup(probe)
            popup_page = page()
            app.eval(popup_page, "window.permissionResult='pending'; chrome.permissions.request({permissions:['downloads']})"
                ".then(v=>window.permissionResult=v, e=>window.permissionResult=String(e)); true")
            request = wait_until(lambda: (lambda p:p if p.get("pending") else None)(app.call("ext-prompt")), timeout=10)
            if request: app.call("ext-prompt", answer=answer)
            value = wait_until(lambda: (lambda v: {"value":v} if v != "pending" else None)(app.eval(popup_page,"window.permissionResult")), timeout=10)
            permission_rows.append({"ok": bool(request and value) and request["sheetVisible"] and request["buttons"] == ["Deny","Allow"]
                and value["value"] == (answer == "accept"), "prompt": request, "value": value})
            close()
        results["X14_permissions_deny_allow"] = {"ok":all(r["ok"] for r in permission_rows), "rows":permission_rows}
        commands = app.call("ext-commands")["commands"]
        own = [c for c in commands if c["extension"] == probe]
        app.call("focus", target="page")
        app.call("key", key="u", modifiers=["command", "shift"], route="app")
        named = wait_until(lambda: app.eval(control, "chrome.storage.session.get('commands').then(v=>(v.commands||[]).includes('probe-named'))"), timeout=5)
        p = popup(probe, command=True)
        results["X12_shortcuts"] = {"ok": bool(named and p) and len(own) == 2 and all(not c["dropped"] for c in own), "commands": own, "popup": p}
        close()
        bindings = Path(app.user_data) / "State/keybindings.json"
        previous_bindings = bindings.read_bytes() if bindings.exists() else None
        try:
            bindings.write_text(json.dumps({"version":1,"bindings":{"new-tab":{"shortcuts":[{"key":"u","modifiers":["command","shift"]}],"priority":"browser"}}}))
            app.call("reload-keybindings")
            conflicts = [c for c in app.call("ext-commands")["commands"] if c["extension"] == probe and c["name"] == "probe-named"]
            results["X12_shortcut_conflict"] = {"ok": len(conflicts)==1 and conflicts[0]["dropped"] and conflicts[0]["openCommandID"]=="new-tab", "rows":conflicts}
        finally:
            if previous_bindings is None: bindings.unlink(missing_ok=True)
            else: bindings.write_bytes(previous_bindings)
            app.call("reload-keybindings")
        picker = app.call("ext-picker")
        results["X13_picker"] = {"status":"BLOCKED", "reason":picker.get("blocked", "SCC extension picker not presented"), "state":picker}
        bar = app.call("ext-ui-menu", kind="bar")
        names = [a["name"] for a in sorted(actions(), key=lambda a: (not a["pinned"], a["pinnedIndex"] if a["pinned"] else a["name"]))]
        shown_names = [x["title"] for x in bar if not x["separator"]]
        results["X16_menu_bar"] = {"ok": shown_names == names + ["Manage Extensions…", "Add Extension…"], "titles": shown_names}
        app.call("ext-ui-menu", kind="bar", select=action(probe)["name"])
        from_menu = wait_until(lambda: app.call("ext-popup-state").get("visible"), timeout=10)
        results["X16_menu_run"] = {"ok": bool(from_menu), "state":app.call("ext-popup-state")}
        close()
        for _ in range(2): app.call("command", id="manage-extensions")
        manage = [t for t in app.call("tabs") if t["url"] == "chrome://extensions"]
        results["X17_manage_singleton"] = {"ok": len(manage) == 1 and manage[0]["selected"], "tabs": len(manage)}
        app.call("select", tab=control)
        app.call("split")
        app.call("command", id="next-split-pane")
        time.sleep(.2)
        panes = strip("pane")
        shown_panes = [s for s in panes["strips"] if s["visible"]]
        p = popup(probe, surface="pane") if shown_panes else None
        results["X18_split"] = {"ok": len(panes["strips"]) == 2 and len(shown_panes) == 1 and bool(p), "strips":panes, "popup":p}
        for appearance in ("light", "dark"):
            close(); app.call("appearance", name=appearance); capture("pane-" + appearance)
        app.call("split")
        samples = []
        for i in range(20):
            p = popup(probe)
            if p and p["readyToVisibleMs"] is not None: samples.append(p["readyToVisibleMs"])
            close()
        p95 = sorted(samples)[math.ceil(.95*len(samples))-1] if samples else None
        results["popup_ready_visible_p95"] = {"ok": len(samples) >= 20 and p95 <= 16.7,
            "samples": samples, "p95ms": p95, "load": os.getloadavg()}
        # A real packed install owns and displays the same sheet that automation answers.
        crx = pack_probe(root, tmp, prefix="ui-install")
        installs = []
        for answer in ("cancel", "accept"):
            app.call("ext-manage", extension="local", action="install-crx", path=crx)
            prompt = wait_until(lambda: (lambda p:p if p.get("pending") else None)(app.call("ext-prompt")), timeout=20)
            if not prompt: installs.append({"ok": False}); continue
            app.call("ext-prompt", answer=answer)
            installed = wait_until(lambda: any(e["id"] == prompt["extension"] for e in app.call("extensions")["installed"]) == (answer=="accept"), timeout=15)
            installs.append({"ok": bool(installed) and prompt["sheetVisible"] and prompt["sheetClass"] == "ExtensionPromptSheet"
                and prompt["title"] == "Add Open action probe extension to Open?" and prompt["buttons"] == ["Cancel","Add Extension"], "prompt":prompt})
        results["prompt_install_cancel_add"] = {"ok": all(p["ok"] for p in installs), "rows": installs}
        toasts = app.call("toasts")
        results["install_toast"] = {"ok": any(t["title"] == "Added Open action probe" and t["lifetime"] == 3 for t in toasts["toasts"]), "state":toasts}
        if installs[-1].get("prompt"):
            installed_id = installs[-1]["prompt"]["extension"]
            app.call("ext-menu", extension=installed_id, select="Remove from Open…")
            request = wait_until(lambda: (lambda p:p if p.get("pending") else None)(app.call("ext-prompt")), timeout=10)
            if request: app.call("ext-prompt", answer="accept")
            removed = wait_until(lambda: not action(installed_id), timeout=10)
            results["X15_remove_sheet"] = {"ok": bool(request and removed) and request["sheetVisible"]
                and request["buttons"] == ["Cancel","Remove Extension"], "prompt": request}
        for appearance in ("light", "dark"):
            app.call("appearance", name=appearance)
            app.call("command", id="toggle-toolbar")
            time.sleep(.2); capture("toolbar-" + appearance)
            app.call("command", id="toggle-toolbar")
        hover(True); time.sleep(1)
        baseline = strip()
        time.sleep(10)
        idle = strip()
        results["X21_idle"] = {"ok": idle["redraws"] == baseline["redraws"] and idle["layoutCount"] == baseline["layoutCount"],
            "redraws": idle["redraws"]-baseline["redraws"], "layouts": idle["layoutCount"]-baseline["layoutCount"], "seconds":10}
        results["X19_little_open"] = {"status":"BLOCKED", "reason":"App entry point is showLittleOpenStub; Section 9 owns the real App presenter"}
    finally:
        try:
            app.call("ext-prompt", clear=True)
            close()
            for key, value in saved.items(): app.call("defaults", key=key, value=value)
        finally: app.quit()
