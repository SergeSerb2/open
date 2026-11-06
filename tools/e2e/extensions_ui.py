"""Extensions shell acceptance through the real App, native events and local CRX3.

All pointer/key events stay inside Open. This module never touches the desktop.
"""
import json
import math
import os
from pathlib import Path
import statistics
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from extensions_p3 import pack_probe


def run(factory, results, tmp, root, wait_until, new_tab, frame, read_image, extensions):
    class Progress:
        def __init__(self, target): self.target = target
        def __setitem__(self, key, value):
            self.target[key] = value
            recorded = self.target[key]
            print(key, recorded.get("status", "PASS" if recorded.get("ok") else "FAIL"), flush=True)
        def __getitem__(self, key): return self.target[key]
    results = Progress(results)
    app = factory(urls=("about:blank",))
    saved = {}
    server = None
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
            hover()
            current = strip(surface)
            if identifier in current["ids"]:
                app.call("ext-click", extension=identifier, surface=surface)
            elif current["more"]:
                app.call("ext-click", extension="more", surface=surface, select=action(identifier)["name"])
            else:
                raise RuntimeError("action has neither a visible slot nor an overflow menu: " + identifier)
        return wait_until(lambda: (lambda s: s if s.get("visible") else None)(app.call("ext-popup-state")), timeout=15)
    def page(): return app.call("ext-popup")["page"]["identifier"]
    def capture(name, window=None):
        path = str(captures / (name + ".png"))
        app.call("snapshot", path=path, **({"window": window} if window else {}))
        return path
    def anchored(state, slot):
        if not state: return False
        a = frame(state["anchor"])
        win = app.call("window-state")["frame"]
        return all(abs(actual-expected) <= 1 for actual, expected in zip(a, [slot[0]+win[0], slot[1]+win[1], *slot[2:]]))
    def pin_result(key, value):
        duplicates = app.call("extensions")["duplicatesDropped"]
        if duplicates:
            results[key] = {"status":"BLOCKED", "reason":"engine defect, C5: duplicate E1 action IDs",
                            "duplicatesDropped":duplicates, "assertion":value}
        else:
            results[key] = dict(value, duplicatesDropped=duplicates)
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
        pin_result("X2_pin_order_frames", {"ok": bool(pinned and moved)
            and [f[0] for f in pinned["frames"]] == [74, 102, 130], "strip":pinned, "moved":bool(moved)})
        # The old engine's duplicate pin model crashes in MovePinnedAction on
        # this drag. Keep the row blocked until the engine provides a clean list.
        if app.call("extensions")["duplicatesDropped"]:
            pin_result("X2_native_drag", {"ok":False,"reason":"MovePinnedAction crashes with duplicate engine IDs on 7b490905",
                "receipt":".re/extensions-ui/engine-native-drag-crash.ips"})
        else:
            # Native down/drag/up follows the same NSView path as a physical drag.
            before_drag = strip(); slots = before_drag["frames"]
            win_height = app.call("window-state")["frame"][3]
            for event, slot in (("down",slots[0]),("drag",slots[2]),("up",slots[2])):
                app.call("mouse", action=event, x=slot[0]+14, y=win_height-slot[1]-14)
            reordered = wait_until(lambda: strip()["ids"] == ids, timeout=5)
            pin_result("X2_native_drag", {"ok":bool(reordered), "before":before_drag, "after":strip()})
        expected_order = strip()["ids"]
        app.call("command", id="new-window")
        second = wait_until(lambda: (lambda s:s if s["ids"]==expected_order else None)(hover()), timeout=10)
        pin_result("X2_second_window", {"ok":bool(second), "strip":second})
        app.call("window-close")
        app.quit()
        # This run owns the profile. Disable Chromium's automatic pin policy
        # while it is closed so a user install can exercise the toast's Pin.
        for path in Path(app.user_data).rglob("Preferences"):
            preferences=json.loads(path.read_text())
            preferences.setdefault("extensions",{})["pinned_by_default"]=False
            path.write_text(json.dumps(preferences))
        app = factory(urls=("about:blank",))
        wait_until(lambda: len(actions()) >= 4, timeout=30)
        app.call("window-frame", frame=[80,60,1200,800])
        persisted = wait_until(lambda: (lambda s:s if s["ids"]==expected_order else None)(hover()), timeout=10)
        pin_result("X2_relaunch", {"ok":bool(persisted), "strip":persisted})
        hidden = hover(False); shown = hover(True)
        results["X3_hover"] = {"ok": not hidden["visible"] and shown["visible"] and len(shown["ids"]) == 3,
                                 "away": hidden, "over": shown}
        # Startup welcome tabs may be opened by the real store copies. Select a
        # stable local page before capturing Open's own window.
        blank = new_tab(app, "about:blank")
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
        developer = new_tab(app, "chrome://extensions")
        wait_until(lambda: app.eval(developer, "typeof chrome.developerPrivate") == "object", timeout=20)
        app.eval(developer, "new Promise(done=>chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode:true},()=>done(!chrome.runtime.lastError)))")
        app.call("close", tab=developer); app.call("select", tab=control)
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
        other = new_tab(app,"about:blank")
        other_chrome = app.call("engine-sleep")["chromeTabId"]
        app.eval(content,"Promise.all([chrome.action.setBadgeText({tabId:"+str(active)+",text:'7'}),chrome.action.setBadgeText({tabId:"+str(other_chrome)+",text:''})]).then(()=>true)")
        empty_on_b = wait_until(lambda: action(probe).get("badge") in (None,""), timeout=5)
        app.call("select",tab=control)
        seven_on_a = wait_until(lambda: action(probe).get("badge")=="7", timeout=5)
        results["X4_per_tab"] = {"ok":bool(empty_on_b and seven_on_a),"tabA":active,"tabB":other_chrome}
        layouts = strip()["layoutCount"]; draws = strip()["redraws"]
        app.call("ext-redraw-measure",start=True)
        app.eval(content, "Promise.all(Array.from({length:100},(_,i)=>chrome.action.setBadgeText({tabId:" + str(active) + ",text:String(i)}))).then(()=>true)")
        burst = wait_until(lambda: action(probe).get("badge") == "99", timeout=5)
        time.sleep(.1)
        after = strip()
        measured = app.call("ext-redraw-measure")
        results["X5_badge_burst"] = {"ok": bool(burst) and after["layoutCount"] == layouts
            and measured["frames"] > 0 and measured["maxPerActionPerFrame"] <= 1,
            "layoutDelta": after["layoutCount"]-layouts, "redrawDelta": after["redraws"]-draws, "displayFrames":measured,
            "source": "network-free action-probe, 100 action events in one renderer turn"}
        # Real store extensions use their bundled assets and APIs; no account or network is needed.
        for identifier, name in ((extensions["bitwarden"], "bitwarden"), (extensions["darkreader"], "darkreader")):
            close(); app.call("ext-pin", extension=identifier, pinned=True, index=0)
            shown = popup(identifier)
            dimensions = app.eval(page(), "({width:document.documentElement.scrollWidth,height:document.documentElement.scrollHeight})") if shown else {}
            if name == "bitwarden":
                popup_active=app.eval(page(),"chrome.tabs.query({active:true,currentWindow:true}).then(ts=>ts[0].id)") if shown else None
                results["X6_bitwarden"] = {"ok": bool(shown) and shown["key"] and frame(shown["contentSize"])[0] >= 350
                    and popup_active==app.call("engine-sleep")["chromeTabId"], "state":shown,"activeTab":popup_active}
            else:
                size = frame(shown["contentSize"]) if shown else [0,0]
                results["X7_darkreader_resize"] = {"ok": bool(shown) and all(abs(a-b)<=1 for a,b in zip(size, (dimensions.get("width",0), dimensions.get("height",0))))
                    and 25<=size[0]<=800 and 25<=size[1]<=600, "state":shown, "document":dimensions}
            if shown:
                for appearance in ("light", "dark"):
                    app.call("appearance", name=appearance); capture(name + "-popup-" + appearance, shown["window"])
            close()
        # Exercise Chromium's DNR counter in the real uBO Lite extension. The
        # requests stay on a per-run local server; none need the public network.
        class LocalPage(BaseHTTPRequestHandler):
            def do_GET(self):
                body=b"<!doctype html><title>Extension badge burst</title><p>Local extension acceptance</p>"
                self.send_response(200);self.send_header("Content-Type","text/html");self.end_headers();self.wfile.write(body)
            def log_message(self,*args): pass
        server=ThreadingHTTPServer(("127.0.0.1",0),LocalPage)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        local_origin="http://127.0.0.1:"+str(server.server_port)
        ubo_page=new_tab(app,"chrome-extension://"+extensions["ublock"]+"/dashboard.html")
        dnr_rule={"id":2147483000,"priority":2147483000,"action":{"type":"block"},
            "condition":{"urlFilter":local_origin+"/open-extension-blocked/","resourceTypes":["xmlhttprequest"]}}
        app.eval(ubo_page,"Promise.all([chrome.declarativeNetRequest.setExtensionActionOptions({displayActionCountAsBadgeText:true}),"
            "chrome.declarativeNetRequest.updateSessionRules({addRules:["+json.dumps(dnr_rule)+"]})]).then(()=>true)")
        local_tab=new_tab(app,local_origin)
        hover(); before_ubo=strip()
        app.call("ext-redraw-measure",start=True)
        blocked=app.eval(local_tab,"Promise.all(Array.from({length:40},(_,i)=>fetch('/open-extension-blocked/'+i).then(()=>false,()=>true))).then(v=>v.filter(Boolean).length)")
        counter=wait_until(lambda:(lambda a:a if int(a.get("badge") or 0)>0 else None)(action(extensions["ublock"])),timeout=10)
        after_ubo=strip()
        ubo_measure=app.call("ext-redraw-measure")
        results["X5_ublock_dnr_badge"]={"ok":blocked==40 and bool(counter) and after_ubo["layoutCount"]==before_ubo["layoutCount"]
            and ubo_measure["frames"]>0 and ubo_measure["maxPerActionPerFrame"]<=1,
            "blocked":blocked,"action":counter,"displayFrames":ubo_measure,"redrawDelta":after_ubo["redraws"]-before_ubo["redraws"],
            "layoutDelta":after_ubo["layoutCount"]-before_ubo["layoutCount"],"source":"uBO Lite DNR session rule, local HTTP requests"}
        app.eval(ubo_page,"chrome.declarativeNetRequest.updateSessionRules({removeRuleIds:[2147483000]}).then(()=>true)")
        bitwarden_menu=app.call("ext-menu",extension=extensions["bitwarden"])
        site_items=[child for item in bitwarden_menu for child in item["submenu"]]
        on_site=next((item["title"] for item in site_items if item["title"].startswith("On 127.0.0.1")),None)
        if on_site: app.call("ext-menu",extension=extensions["bitwarden"],select=on_site)
        site=wait_until(lambda:action(extensions["bitwarden"]).get("siteAccess")==2,timeout=5) if on_site else None
        before_options={t["id"] for t in app.call("tabs")}
        options_menu=app.call("ext-menu",extension=extensions["ublock"])
        if any(item["title"]=="Options" and item["enabled"] for item in options_menu):
            app.call("ext-menu",extension=extensions["ublock"],select="Options")
        option_tab=wait_until(lambda:next((t for t in app.call("tabs") if t["selected"]
            and t["url"].startswith("chrome-extension://"+extensions["ublock"])),None),timeout=10)
        results["X11_options_site_access"]={"ok":bool(site and option_tab) and not any(i["title"]=="Options" for i in bitwarden_menu),
            "menu":bitwarden_menu,"optionsMenu":options_menu,"onSite":on_site,"optionsTab":option_tab,
            "optionsCreatedNewTab":bool(option_tab and option_tab["id"] not in before_options),
            "siteAccess":action(extensions["bitwarden"]).get("siteAccess")}
        app.call("select",tab=control)
        app.call("ext-pin", extension=probe, pinned=True, index=0)
        # D1-D5 and F2 use the native key/event path, not a popup-controller call.
        dismissals = []
        close()
        for how in ("blur", "toggle", "escape", "window.close", "tab", "command-w", "sidebar-hide"):
            opened = popup(probe)
            if not opened: dismissals.append({"rule": how, "ok": False}); continue
            tabs_before={t["id"] for t in app.call("tabs")}
            if how == "blur": app.call("window-focus", id=app.call("window-state")["id"], activate=True)
            elif how == "toggle": app.call("ext-click", extension=probe, surface="url")
            elif how == "escape": app.call("key", key="escape", window="popup", route="app")
            elif how == "window.close": app.eval(page(), "window.close(); true")
            elif how == "tab": new_tab(app, "about:blank")
            elif how == "command-w": app.call("key", key="w", modifiers=["command"], window="popup", route="app")
            elif how == "sidebar-hide":
                app.call("key", key="s", modifiers=["command"], window="popup", route="app")
            ended = wait_until(lambda: not app.call("ext-popup-state")["open"], timeout=5)
            tabs_kept=how!="command-w" or tabs_before=={t["id"] for t in app.call("tabs")}
            dismissals.append({"rule": how, "ok": bool(ended) and tabs_kept, "tabsKept":tabs_kept,
                "state":app.call("ext-popup-state"), "events":app.call("events")})
            close()
            if app.call("window-state")["sidebarMode"] == "hidden": app.call("command", id="toggle-sidebar")
        results["X8_dismiss_D1_D5_F2_D7"] = {"ok": all(d["ok"] for d in dismissals), "rows": dismissals}
        shown = popup(probe)
        if shown:
            popup_page = page()
            app.call("ext-menu", extension=probe, select="Inspect Popup")
            inspected = wait_until(lambda: app.call("ext-popup-state").get("staysOpenOnBlur"), timeout=10)
            app.call("window-focus", id=app.call("window-state")["id"], activate=True)
            kept = app.call("ext-popup-state")
            current_popup=app.call("ext-popup")
            inspected_page=current_popup.get("page",{}).get("identifier")
            if inspected_page: app.call("devtools-close", tab=inspected_page)
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
        hover(); disabled_image = capture("disabled")
        app.eval(control, "chrome.action.enable().then(()=>true)")
        wait_until(lambda: action(probe).get("enabled"), timeout=5)
        hover(); enabled_image = capture("enabled")
        _,height,disabled_pixel = read_image(disabled_image); _,_,enabled_pixel = read_image(enabled_image)
        slot = strip()["frames"][0]; x,y,w,hh = slot; y=height-y-hh
        def colored(pixel):
            return sum(max(pixel(xx,yy)[:3])-min(pixel(xx,yy)[:3]) > 20
                for xx in range(int(x),int(x+w)) for yy in range(int(y),int(y+hh)))
        disabled_color,enabled_color=colored(disabled_pixel),colored(enabled_pixel)
        results["X10_grayscale_pixels"]={"ok":disabled_color < enabled_color,"disabledColoredPixels":disabled_color,"enabledColoredPixels":enabled_color}
        hover(); right = app.call("ext-click", extension=probe, surface="url", button="right")
        titles = [i["title"] for i in right.get("menu", [])]
        app.call("ext-menu", extension=probe, select="Unpin")
        unpinned = wait_until(lambda: not action(probe).get("pinned"), timeout=5)
        app.call("ext-pin", extension=probe, pinned=True, index=0)
        pin_result("X11_context_menu", {"ok": bool(unpinned) and "Remove from Open…" in titles and "Unpin" in titles
            and all("Chrome" not in t and "Chromium" not in t for t in titles), "titles": titles})
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
        command_settings=new_tab(app,"chrome://extensions/shortcuts")
        wait_until(lambda: app.eval(command_settings,"typeof chrome.developerPrivate.updateExtensionCommand")=="function",timeout=10)
        def bind_named(keys):
            return app.eval(command_settings,"new Promise(done=>chrome.developerPrivate.updateExtensionCommand("+
                json.dumps({"extensionId":probe,"commandName":"probe-named","keybinding":keys})+
                ",()=>done(chrome.runtime.lastError?.message||true)))")
        try:
            updated=bind_named("Command+T")
            conflict=wait_until(lambda:(lambda rows:rows if any(c["dropped"] and c["openCommandID"]=="new-tab" for c in rows) else None)(
                [c for c in app.call("ext-commands")["commands"] if c["extension"]==probe and c["name"]=="probe-named"]),timeout=5)
            app.call("key",key="t",modifiers=["command"],route="app")
            bar=app.call("commandbar-state")
            app.call("key",key="escape",route="app")
            results["X12_default_conflict"]={"ok":updated is True and bool(conflict) and bar.get("presented"),"rows":conflict,"bar":bar,"update":updated}
        finally:
            bind_named("Command+Shift+U")
            app.call("close",tab=command_settings)
            app.call("select",tab=control)
        picker = app.call("ext-picker")
        results["X13_picker"] = {"status":"BLOCKED", "reason":picker.get("blocked", "SCC extension picker not presented"), "state":picker}
        bar = app.call("ext-ui-menu", kind="bar")
        names = [a["name"] for a in sorted(actions(), key=lambda a: (not a["pinned"], a["pinnedIndex"] if a["pinned"] else a["name"]))]
        shown_names = [x["title"] for x in bar if not x["separator"]]
        results["X16_menu_bar"] = {"ok": shown_names == names + ["Manage Extensions…", "Add Extension…"], "titles": shown_names}
        app.call("ext-ui-menu", kind="bar", select=action(probe)["name"])
        from_menu = wait_until(lambda: app.call("ext-popup-state").get("visible"), timeout=10)
        results["X16_menu_run"] = {"ok": bool(from_menu), "state":app.call("ext-popup-state")}
        forced=hover(False)
        results["X3_popup_forces_visible"]={"ok":forced["visible"] and app.call("ext-popup-state")["open"],"strip":forced}
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
        probe_slot = shown_panes[0]["frames"][shown_panes[0]["ids"].index(probe)] if shown_panes else []
        results["X18_split"] = {"ok": len(panes["strips"]) == 2 and len(shown_panes) == 1 and anchored(p,probe_slot), "strips":panes, "popup":p}
        for appearance in ("light", "dark"):
            close(); app.call("appearance", name=appearance); capture("pane-" + appearance)
        app.call("split")
        samples,click_samples = [],[]
        for i in range(20):
            p = popup(probe)
            if p and p["readyToVisibleMs"] is not None: samples.append(p["readyToVisibleMs"])
            if p and p["clickToVisibleMs"] is not None: click_samples.append(p["clickToVisibleMs"])
            close()
        p95 = sorted(samples)[math.ceil(.95*len(samples))-1] if samples else None
        results["popup_ready_visible_p95"] = {"ok": len(samples) >= 20 and p95 <= 16.7,
            "samples": samples, "p95ms": p95, "load": os.getloadavg(),
            "clickToVisibleSamples":click_samples,"clickToVisibleP95ms":sorted(click_samples)[18] if len(click_samples)>=20 else None}
        # A real packed install owns and displays the same sheet that automation answers.
        crx = pack_probe(root, tmp, prefix="ui-install")
        installs = []
        for answer in ("cancel", "accept"):
            app.call("ext-manage", extension="local", action="install-crx", path=crx)
            prompt = wait_until(lambda: (lambda p:p if p.get("pending") else None)(app.call("ext-prompt")), timeout=20)
            if not prompt: installs.append({"ok": False}); continue
            if os.environ.get("OPEN_E2E_UI_FAIL_WITH_PROMPT") == "1":
                raise RuntimeError("deliberate failure with ExtensionPromptSheet visible")
            app.call("key",key="escape" if answer=="cancel" else "return",window=prompt["sheet"],route="app")
            installed = wait_until(lambda: any(e["id"] == prompt["extension"] for e in app.call("extensions")["installed"]) == (answer=="accept"), timeout=15)
            installs.append({"ok": bool(installed) and prompt["sheetVisible"] and prompt["sheetClass"] == "ExtensionPromptSheet"
                and prompt["title"] == "Add Open action probe extension to Open?" and prompt["buttons"] == ["Cancel","Add Extension"], "prompt":prompt})
        results["prompt_install_cancel_add"] = {"ok": all(p["ok"] for p in installs), "rows": installs}
        toasts = app.call("toasts")
        toast = next((t for t in toasts["toasts"] if t["title"]=="Added Open action probe"),{})
        results["install_toast"] = {"ok":toast.get("lifetime")==3,"state":toasts}
        if toast.get("accessory")=="pin":
            app.call("toast-action",index=0)
            pinned_toast = wait_until(lambda: action(installs[-1]["prompt"]["extension"]).get("pinned"),timeout=5)
            pin_result("install_toast_pin",{"ok":bool(pinned_toast),"toast":toast})
        else:
            results["install_toast_pin"]={"ok":False,"reason":"fresh user install should be unpinned with pinned_by_default=false","toast":toast}
        if installs[-1].get("prompt") and action(installs[-1]["prompt"]["extension"]):
            installed_id = installs[-1]["prompt"]["extension"]
            app.call("ext-menu", extension=installed_id, select="Remove from Open…")
            request = wait_until(lambda: (lambda p:p if p.get("pending") else None)(app.call("ext-prompt")), timeout=10)
            if request: app.call("ext-prompt", answer="cancel")
            retained = wait_until(lambda: not app.call("ext-prompt").get("pending"),timeout=5) and bool(action(installed_id))
            app.call("ext-menu",extension=installed_id,select="Remove from Open…")
            request = wait_until(lambda:(lambda p:p if p.get("pending") else None)(app.call("ext-prompt")),timeout=10)
            if request: app.call("ext-prompt",answer="accept")
            removed = wait_until(lambda: not action(installed_id), timeout=10)
            results["X15_remove_sheet"] = {"ok": bool(request and removed and retained) and request["sheetVisible"]
                and request["buttons"] == ["Cancel","Remove Extension"], "prompt": request}
        second_crx=pack_probe(root,tmp,prefix="ui-queued")
        for path in (crx,second_crx):
            app.call("ext-manage",extension="local",action="install-crx",path=path)
        first=wait_until(lambda:(lambda p:p if p.get("queued")==2 else None)(app.call("ext-prompt")),timeout=10)
        if first: app.call("key",key="escape",window=first["sheet"],route="app")
        second=wait_until(lambda:(lambda p:p if p.get("pending") and p.get("sheetVisible") and first and p["extension"]!=first["extension"] else None)(app.call("ext-prompt")),timeout=10)
        if second: app.call("key",key="escape",window=second["sheet"],route="app")
        drained=wait_until(lambda:not app.call("ext-prompt").get("pending"),timeout=5)
        results["prompt_fifo"]={"ok":bool(first and second and drained) and first["sheetVisible"],"first":first,"second":second,"drained":bool(drained)}
        wait_until(lambda:not any(not t["exiting"] for t in app.call("toasts")["toasts"]),timeout=5)
        for appearance in ("light", "dark"):
            close(); app.call("select",tab=blank)
            app.call("appearance", name=appearance)
            app.call("command", id="toggle-toolbar")
            time.sleep(.2); capture("toolbar-" + appearance)
            app.call("command", id="toggle-toolbar")
        # Four pinned actions exceed the URL strip's three-slot budget.
        for identifier in [probe,extensions["ublock"],extensions["darkreader"],extensions["bitwarden"]]:
            app.call("ext-pin",extension=identifier,pinned=True)
        hover(); overflow=strip()
        overflow_menu=app.call("ext-click",extension="more",surface="url",select=action(extensions["bitwarden"])["name"]) if overflow["more"] else {}
        overflow_popup=wait_until(lambda:(lambda p:p if p.get("visible") else None)(app.call("ext-popup-state")),timeout=10) if overflow_menu else None
        results["overflow_menu_anchor"]={"ok":overflow["more"] and anchored(overflow_popup,overflow["moreFrame"]),"strip":overflow,"menu":overflow_menu,"popup":overflow_popup}
        close()
        app.call("command",id="toggle-toolbar")
        toolbar=strip("toolbar")
        toolbar_popup=popup(probe,surface="toolbar")
        probe_slot=toolbar["frames"][toolbar["ids"].index(probe)] if probe in toolbar["ids"] else []
        results["toolbar_frames_anchor"]={"ok":toolbar["visible"] and anchored(toolbar_popup,probe_slot),"strip":toolbar,"popup":toolbar_popup}
        close();app.call("command",id="toggle-toolbar")
        find_rows = []
        for surface in ("url", "pane", "toolbar"):
            if surface == "pane": app.call("split")
            elif surface == "toolbar": app.call("command", id="toggle-toolbar")
            try:
                hover()
                app.call("key", key="f", modifiers=["command"], route="app")
                app.call("key", text="extension", route="app")
                find = app.call("focus-state")
                strips = strip(surface).get("strips", [])
                frames = [r for s in strips if s["visible"] for r in s["frames"] + ([s["moreFrame"]] if s["more"] else [])]
                url = strip()
                frames += url["frames"] if url["visible"] else []
                def overlaps(a, b):
                    return a[0] < b[0]+b[2] and b[0] < a[0]+a[2] and a[1] < b[1]+b[3] and b[1] < a[1]+a[3]
                cancel = find["findCancelFrame"]
                # The real NSSearchFieldCell cancel glyph receives native down/up.
                # Section 11 replaces this field with its viewport Find bar.
                app.call("mouse", action="click", x=cancel[0]+cancel[2]/2,
                    y=app.call("window-state")["frame"][3]-cancel[1]-cancel[3]/2)
                closed = wait_until(lambda: not app.call("focus-state")["findVisible"], timeout=3)
                find_rows.append({"surface":surface, "ok":find["findVisible"] and cancel[2]>0 and bool(closed)
                    and bool(frames) and not any(overlaps(find["findFrame"], f) for f in frames),
                    "find":find, "stripFrames":frames, "closedByNativeClick":bool(closed)})
            finally:
                if app.call("focus-state")["findVisible"]:
                    app.call("key", key="escape", route="app")
                if surface == "pane": app.call("split")
                elif surface == "toolbar": app.call("command", id="toggle-toolbar")
        results["find_strip_no_overlap_native_close"] = {"ok":all(r["ok"] for r in find_rows), "rows":find_rows}
        hover(True); time.sleep(1)
        baseline = strip()
        time.sleep(10)
        idle = strip()
        results["X21_idle"] = {"ok": idle["redraws"] == baseline["redraws"] and idle["layoutCount"] == baseline["layoutCount"],
            "redraws": idle["redraws"]-baseline["redraws"], "layouts": idle["layoutCount"]-baseline["layoutCount"], "seconds":10}
        # S9 owns page creation; this exercises its actual App presenter.
        before_little={row["id"] for row in app.call("little-open-state")["sessions"]}
        app.call("menu-perform",id="new-little-open-window")
        little=next(row for row in app.call("little-open-state")["sessions"] if row["id"] not in before_little)
        little_id=little["id"]
        try:
            app.call("key",window=little["window"],text=local_origin+"/little\r",route="app")
            little=wait_until(lambda:next((row for row in app.call("little-open-state")["sessions"]
                if row["id"]==little_id and row["state"]=="page" and not row["loading"]),None),timeout=15)
            little_strip=app.call("ext-strip",surface="little")
            little_menu=app.call("ext-click",extension="more",surface="little") if little_strip["visible"] else {"menu":[]}
            results["X19_button_menu"]={"ok":bool(little) and little_strip["visible"] and len(little_strip["ids"])>=4
                and little["titleElements"].get("extensions")==[little["frame"][2]-252,16,16,16]
                and [i["title"] for i in little_menu["menu"] if not i["separator"]][-2:]==["Manage Extensions…","Add Extension…"],
                "strip":little_strip,"session":little,"menu":little_menu}
            for appearance in ("light","dark"):
                app.call("appearance",name=appearance);capture("little-"+appearance,little["window"])
            if little_strip["ready"]:
                app.call("ext-click",extension="more",surface="little",select=action(probe)["name"])
                little_popup=wait_until(lambda:(lambda p:p if p.get("visible") else None)(app.call("ext-popup-state",surface="little")),timeout=15)
                queried=app.eval(little_popup["page"],"chrome.tabs.query({active:true,currentWindow:true}).then(ts=>ts.map(t=>t.id))") if little_popup else []
                button=little_strip["buttonFrame"];anchor=frame(little_popup["anchor"]) if little_popup else []
                expected=[button[0]+little["frame"][0],button[1]+little["frame"][1],*button[2:]]
                results["X19_run_popup_activeTab"]={"ok":bool(little_popup) and queried==[little_strip["activeTab"]]
                    and all(abs(a-b)<=1 for a,b in zip(anchor,expected)),"popup":little_popup,"queried":queried,"strip":little_strip}
                app.call("key",key="w",modifiers=["command"],window=little_popup["window"],route="app")
            else:
                results["X19_run_popup_activeTab"]={"status":"BLOCKED","reason":"waits for Section 9's Chrome-style Little Open page"}
            # Registry changes reach the standalone window without a polling loop.
            installed_actions=[a["id"] for a in actions()]
            try:
                for identifier in installed_actions: app.call("ext-manage",extension=identifier,action="disable")
                empty=wait_until(lambda:(lambda state:state if not state["visible"] and not state["ids"] else None)(app.call("ext-strip",surface="little")),timeout=10)
                results["X19_zero_actions"]={"ok":bool(empty),"strip":empty}
            finally:
                for identifier in installed_actions: app.call("ext-manage",extension=identifier,action="enable")
        finally:
            app.call("little-open-action",id=little_id,action="close")
        app.call("command",id="new-window")
        new_tab(app,"about:blank")
        app.call("ext-manage",extension="local",action="install-crx",path=crx)
        closing=wait_until(lambda:(lambda p:p if p.get("pending") else None)(app.call("ext-prompt")),timeout=15)
        closing_id=app.call("window-state")["id"]
        app.call("window-close")
        cancelled=wait_until(lambda:not app.call("ext-prompt").get("pending"),timeout=5)
        window_closed=wait_until(lambda:all(w["id"]!=closing_id for w in app.call("shell-windows")),timeout=5)
        results["prompt_window_close_cancels"]={"ok":bool(closing and cancelled and window_closed),"prompt":closing,
            "cancelled":bool(cancelled),"windowClosed":bool(window_closed)}
        app.call("ext-prompt",clear=True)
        app.call("ext-manage",extension="local",action="install-crx",path=crx)
        quitting=wait_until(lambda:(lambda p:p if p.get("pending") else None)(app.call("ext-prompt")),timeout=15)
        app.quit(); app=factory(urls=("about:blank",))
        wait_until(lambda:app.call("extensions")["ready"],timeout=20)
        installed_ids={e["id"] for e in app.call("extensions")["installed"]}
        results["prompt_quit_cancels"]={"ok":bool(quitting) and quitting["extension"] not in installed_ids and not app.call("ext-prompt").get("pending"),"prompt":quitting}
    finally:
        try:
            if not app.closed:
                try:
                    app.call("ext-prompt", clear=True)
                    close()
                except (OSError,RuntimeError,json.JSONDecodeError): pass
        finally:
            # Restore the real shared domain even after a crashed App.
            from engine_e2e import _restore_defaults
            _restore_defaults(app,saved)
            app.quit()
            if server: server.shutdown();server.server_close()
