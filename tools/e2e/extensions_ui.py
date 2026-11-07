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
    from profiles_extensions import run as profiles_extensions
    profiles_extensions(factory, results, tmp, root, wait_until)
    if os.environ.get("OPEN_E2E_EXTENSIONS_UI_SCOPE") in ("profiles", "profiles-memory"):
        return
    class Progress:
        def __init__(self, target): self.target = target
        def __setitem__(self, key, value):
            self.target[key] = value
            recorded = self.target[key]
            print(key, recorded.get("status", "PASS" if recorded.get("ok") else "FAIL"), flush=True)
        def __getitem__(self, key): return self.target[key]
    results = Progress(results)
    app = factory(urls=("about:blank",), fresh=True)
    saved = {}
    bindings = Path(app.user_data) / "State/keybindings.json"
    previous_bindings = bindings.read_bytes() if bindings.exists() else None
    server = None
    x27_disabled = False
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
        results[key] = dict(value, ok=bool(value.get("ok")) and duplicates == 0,
                            duplicatesDropped=duplicates)
    try:
        for key, value in {"open.advanced.showToolbar": False,
                           "open.advanced.playSoundEffects": False,
                           "open.settings.lastPane": "general",
                           "open.links.littleOpenProfileSwitchConfirmed": False,
                           "open.links.littleOpenNUXSeen": True,
                           "open.shortcuts.defaultPriority": "browser"}.items():
            saved[key] = app.call("defaults", key=key, persistent=True)
            app.call("defaults", key=key, value=value)
        app.call("settings-pane", pane="shortcuts")
        app.call("ext-shortcuts", action="reset-all")
        app.call("ext-shortcuts", action="close")
        app.call("window-frame", frame=[80, 60, 1200, 800])
        app.call("window-focus", id=app.call("window-state")["id"], activate=True)
        wait_until(lambda: len(actions()) >= 4, timeout=30)
        probe = next(a["id"] for a in actions() if a["name"] == "Action Probe")
        ids = [extensions["ublock"], extensions["darkreader"], probe]
        for a in actions(): app.call("ext-pin", extension=a["id"], pinned=False)
        for identifier in ids: app.call("ext-pin", extension=identifier, pinned=True)
        hover()
        pinned = wait_until(lambda: (lambda s: s if s["ids"] == ids else None)(strip()), timeout=10)
        app.call("ext-pin", extension=probe, pinned=True, index=0)
        moved = wait_until(lambda: strip()["ids"] == [probe] + ids[:2], timeout=5)
        pin_result("X2_pin_order_frames", {"ok": bool(pinned and moved)
            and [f[0] for f in pinned["frames"]] == [74, 102, 130], "strip":pinned, "moved":bool(moved)})
        # Exact former crash sequence: pin uBO, Dark Reader, probe; move 2→0;
        # then native drag 0→2. C5 repaired the model; duplicates now fail.
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
            pin_result("X2_native_drag", {"ok":before_drag["ids"] == [probe] + ids[:2] and bool(reordered),
                "before":before_drag, "after":strip(),
                "sequence":"pin uBO Lite, Dark Reader, probe; move 2→0; native drag 0→2"})
        guard_states = []
        for identifier, index, expected in (("a" * 32, 0, ids), (extensions["bitwarden"], 0, ids),
                (probe, 9999, ids), (probe, 0, [probe] + ids[:2]),
                (probe, 0, [probe] + ids[:2]), (probe, 9999, ids)):
            app.call("ext-move", extension=identifier, index=index)
            settled = wait_until(lambda: strip()["ids"] == expected, timeout=5)
            guard_states.append({"ok":bool(settled), "extension":identifier, "index":index, "strip":strip()})
        pin_result("X2_App_move_guards", {"ok":all(s["ok"] for s in guard_states), "rows":guard_states})
        expected_order = strip()["ids"]
        app.call("command", id="new-window")
        new_tab(app, "about:blank")
        second = wait_until(lambda: (lambda s:s if s["ids"]==expected_order else None)(hover()), timeout=10)
        pin_result("X2_second_window", {"ok":bool(second), "strip":second or strip()})
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
        badge_strip = strip()
        slot = badge_strip["frames"][badge_strip["ids"].index(probe)]
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
        # The fixture stores the click after its asynchronous scripting probe.
        count = wait_until(lambda:(lambda value:value if value!=before else None)(
            app.eval(control, "chrome.storage.session.get('clicks').then(v=>v.clicks||0)")), timeout=10)
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
        # X-27: perform the real Shortcuts pane's native menu item twice,
        # selecting another tab in between to prove the singleton is reselected.
        # Bitwarden ships a separate default conflict (⇧⌘L / View Library).
        # Isolate the requested one-line notice, then restore its enabled state.
        app.call("ext-manage", extension=extensions["bitwarden"], action="disable")
        x27_disabled = True
        wait_until(lambda: not action(extensions["bitwarden"]), timeout=5)
        app.call("settings-pane", pane="general")
        app.call("settings-pane", pane="shortcuts")
        app.call("ext-shortcuts", action="reset-all")
        clean_shortcuts = app.call("ext-shortcuts")
        shortcuts_tabs = []
        try:
            for _ in range(2):
                app.call("ext-shortcuts", action="menu", select="Extension Shortcuts")
                selected = wait_until(lambda: next((t for t in app.call("tabs")
                    if t["url"] == "chrome://extensions/shortcuts" and t["selected"]), None), timeout=10)
                shortcuts_tabs.append(selected)
                app.call("select", tab=control)
                app.call("settings-pane", pane="shortcuts")
            all_shortcuts = [t for t in app.call("tabs") if t["url"] == "chrome://extensions/shortcuts"]
            results["X27_shortcuts_menu_singleton"] = {"ok":len(all_shortcuts) == 1
                and all(t and t["id"] == all_shortcuts[0]["id"] for t in shortcuts_tabs)
                and all_shortcuts[0]["section"] == "today",
                "menu":clean_shortcuts["menu"], "invocations":shortcuts_tabs, "tabs":all_shortcuts}
            at_limit = app.call("ext-shortcuts", action="record", id="new-tab", key="u",
                modifiers=["control", "option", "shift", "command"])
            app.call("ext-shortcuts", action="reset", id="new-tab")
            unchanged = bindings.read_bytes()
            refused = []
            for key, modifiers in (("", ["command"]), ("uu", ["command"]), ("u", ["command"] * 5)):
                try:
                    app.call("ext-shortcuts", action="record", id="new-tab", key=key, modifiers=modifiers)
                    refused.append(False)
                except RuntimeError as error:
                    refused.append("invalid shortcut" in str(error))
            results["X27_binding_input_bounds"] = {"ok":at_limit["status"] == "Saved." and all(refused)
                and bindings.read_bytes() == unchanged, "fourModifiers":at_limit["status"], "refused":refused}
            # record() saves KeyBindingStore and calls the real App reload hook.
            bound = app.call("ext-shortcuts", action="record", id="new-tab", key="u", modifiers=["command", "shift"])
            expected_notice = action(probe)["name"] + ": ⇧⌘U is used by " + bound["openCommandTitle"] + ", so it is off."
            notice = wait_until(lambda: (lambda s:s if s["notices"] == [expected_notice] else None)(app.call("ext-shortcuts")), timeout=5)
            conflicts = [c for c in app.call("ext-commands")["commands"] if c["extension"] == probe and c["name"] == "probe-named"]
            saved_binding = json.loads(bindings.read_text())["bindings"].get("new-tab")
            app.call("ext-shortcuts", action="close")
            app.call("select", tab=control); app.call("focus", target="page")
            def command_count():
                return app.eval(control, "chrome.storage.session.get('commands').then(v=>(v.commands||[]).filter(c=>c==='probe-named').length)")
            before_command = command_count()
            app.call("key", key="u", modifiers=["command", "shift"], route="app")
            open_command = wait_until(lambda: (lambda s:s if s.get("presented") else None)(app.call("commandbar-state")), timeout=5)
            # A restored command below proves the worker/event path is live;
            # this unchanged count alone would not prove it was suppressed.
            time.sleep(.2)
            suppressed_count = command_count()
            app.call("key", key="escape", route="app")
            results["X27_user_binding_conflict"] = {"ok":clean_shortcuts["notices"] == [] and bool(notice)
                and bound["status"] == "Saved." and saved_binding == {"shortcuts":[{"key":"u","modifiers":["shift","command"]}], "priority":"browser"}
                and len(conflicts)==1 and conflicts[0]["dropped"] and conflicts[0]["openCommandID"] == "new-tab"
                and bool(open_command) and open_command["mode"] == "newTab" and suppressed_count == before_command,
                "expectedNotice":expected_notice, "pane":notice or bound,
                "savedBinding":saved_binding, "commands":conflicts, "openCommand":open_command,
                "counterBefore":before_command, "counterAfter":suppressed_count}
        finally:
            app.call("settings-pane", pane="shortcuts")
            app.call("ext-shortcuts", action="reset", id="new-tab")
        restored = app.call("ext-shortcuts")
        restored_commands = [c for c in app.call("ext-commands")["commands"] if c["extension"] == probe and c["name"] == "probe-named"]
        app.call("ext-shortcuts", action="close")
        app.call("select", tab=control); app.call("focus", target="page")
        before_restored = command_count()
        app.call("key", key="u", modifiers=["command", "shift"], route="app")
        fired = wait_until(lambda: command_count() == before_restored + 1, timeout=5)
        results["X27_restored_extension_command"] = {"ok": restored["notices"] == [] and restored["bindingCount"] == 0
            and len(restored_commands) == 1 and not restored_commands[0]["dropped"] and bool(fired)
            and not app.call("commandbar-state").get("presented"), "pane":restored, "commands":restored_commands,
            "counterBefore":before_restored, "counterAfter":command_count()}
        app.call("ext-manage", extension=extensions["bitwarden"], action="enable")
        wait_until(lambda: action(extensions["bitwarden"]), timeout=5)
        x27_disabled = False
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
        for surface in ("url", "pane", "toolbar", "peek"):
            if surface == "pane": app.call("split")
            elif surface == "toolbar": app.call("command", id="toggle-toolbar")
            elif surface == "peek":
                app.call("peek-open", tab=blank, url=local_origin+"/find-peek")
                app.call("wait")
            try:
                hover()
                app.call("key", key="f", modifiers=["command"], route="app")
                app.call("key", text="extension", route="app")
                find_state = app.call("find-state")
                find = next(p for p in find_state["panes"] if p["tab"] == find_state["focusedTab"])
                strips = strip("url" if surface == "peek" else surface).get("strips", [])
                frames = [r for s in strips if s["visible"] for r in s["frames"] + ([s["moreFrame"]] if s["more"] else [])]
                url = strip()
                frames += url["frames"] if url["visible"] else []
                def overlaps(a, b):
                    return a[0] < b[0]+b[2] and b[0] < a[0]+a[2] and a[1] < b[1]+b[3] and b[1] < a[1]+a[3]
                cancel = find["controls"]["close"]
                # Section 11's native Find close button receives down/up through Open.
                app.call("mouse", action="click", x=cancel[0]+cancel[2]/2,
                    y=app.call("window-state")["frame"][3]-cancel[1]-cancel[3]/2)
                closed = wait_until(lambda: not app.call("focus-state")["findVisible"] and app.call("focus-state")["owner"] == "page", timeout=3)
                find_rows.append({"surface":surface, "ok":find["visible"] and find["controls"]["closeHitMatches"] and cancel[2]>0 and bool(closed)
                    and bool(frames) and not any(overlaps(find["frame"], f) for f in frames)
                    and strip("url" if surface == "peek" else surface)["visible"],
                    "find":find, "stripFrames":frames, "closedByNativeClick":bool(closed)})
            finally:
                if app.call("focus-state")["findVisible"]:
                    app.call("key", key="escape", route="app")
                if surface == "pane": app.call("split")
                elif surface == "toolbar": app.call("command", id="toggle-toolbar")
                elif surface == "peek": app.call("peek-close")
        results["find_strip_no_overlap_native_close"] = {"ok":all(r["ok"] for r in find_rows), "rows":find_rows}
        hover(True); time.sleep(1)
        baseline = strip()
        time.sleep(10)
        idle = strip()
        results["X21_idle"] = {"ok": idle["redraws"] == baseline["redraws"] and idle["layoutCount"] == baseline["layoutCount"],
            "redraws": idle["redraws"]-baseline["redraws"], "layouts": idle["layoutCount"]-baseline["layoutCount"], "seconds":10}
        little_open_checks(app, results, local_origin, probe, control, extensions, wait_until, frame, capture)
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
                    if x27_disabled:
                        app.call("ext-manage", extension=extensions["bitwarden"], action="enable")
                    app.call("ext-prompt", clear=True)
                    close()
                except (OSError,RuntimeError,json.JSONDecodeError): pass
        finally:
            # Restore the real shared domain even after a crashed App.
            from engine_e2e import _restore_defaults
            _restore_defaults(app,saved)
            if previous_bindings is None: bindings.unlink(missing_ok=True)
            else: bindings.write_bytes(previous_bindings)
            app.quit()
            if server: server.shutdown();server.server_close()


def little_open_checks(app, results, local_origin, probe, control, extensions, wait_until, frame, capture):
    def actions(): return app.call("extensions")["actions"]
    def action(identifier): return next(a for a in actions() if a["id"]==identifier)
    original_main=app.call("window-state")
    original_profile=next(s["profile"] for s in app.call("spaces") if s["id"]==original_main["space"])
    # Enable this probe only for X-19. activeTab changes Chrome's disabled
    # action semantics, so the existing X-10/P2 fixture must keep its defaults.
    prompt_handler=app.call("ext-prompt")["handler"]
    app.call("ext-prompt",handler=False)
    app.eval(control,"window.x19Permissions='pending'; chrome.permissions.request({permissions:['activeTab','scripting']}).then(v=>window.x19Permissions=v,e=>window.x19Permissions=String(e));true")
    permission=wait_until(lambda:(lambda p:p if p.get("pending") else None)(app.call("ext-prompt")),timeout=10)
    if permission: app.call("ext-prompt",answer="accept")
    granted=wait_until(lambda:app.eval(control,"window.x19Permissions===true"),timeout=10)
    # S9 owns page creation; this exercises its actual App presenter.
    before_little={row["id"] for row in app.call("little-open-state")["sessions"]}
    app.call("menu-perform",id="new-little-open-window")
    little=next(row for row in app.call("little-open-state")["sessions"] if row["id"] not in before_little)
    little_id=little["id"]
    def little_call(command, **args):
        return app.call(command, surface="little", window=little["window"], **args)
    try:
        app.call("key",window=little["window"],text=local_origin+"/little\r",route="app")
        little=wait_until(lambda:next((row for row in app.call("little-open-state")["sessions"]
            if row["id"]==little_id and row["state"]=="page" and not row["loading"]),None),timeout=15)
        little_strip=little_call("ext-strip")
        little_menu=little_call("ext-click",extension="more") if little_strip["visible"] else {"menu":[]}
        results["X19_button_menu"]={"ok":bool(little) and little_strip["visible"] and len(little_strip["ids"])>=4
            and little["titleElements"].get("extensions")==[little["frame"][2]-252,16,16,16]
            and [i["title"] for i in little_menu["menu"] if not i["separator"]][-2:]==["Manage Extensions…","Add Extension…"],
            "strip":little_strip,"session":little,"menu":little_menu}
        for appearance in ("light","dark"):
            app.call("appearance",name=appearance);capture("little-"+appearance,little["window"])
        # Compare to Section 9's page, never to the UI host's own target.
        # A wrong main-browser binding must fail even if internally consistent.
        target_url=local_origin+"/little"
        target_tab=app.call("little-open-eval",id=little_id,js="location.href")
        main_tab=app.call("engine-sleep")["chromeTabId"]
        app.eval(control,"chrome.storage.session.set({probeScript:true}).then(()=>true)")
        before_grant=app.eval(control,"chrome.scripting.executeScript({target:{tabId:"+str(little["chromeTabID"])+"},func:()=>location.href}).then(r=>({url:r[0].result}),e=>({error:String(e)}))")
        app.eval(control,"chrome.action.setPopup({popup:''}).then(()=>true)")
        before=app.eval(control,"chrome.storage.session.get('clicks').then(v=>v.clicks||0)")
        little_call("ext-click",extension="more",select=action(probe)["name"])
        clicked=wait_until(lambda:(lambda v:v if v.get("clicks",0)>before else None)(app.eval(control,
            "chrome.storage.session.get(['clicks','lastClickTab','lastClickURL','lastClickScript'])")),timeout=10)
        results["X19_popup_less_target"]={"ok":bool(clicked) and clicked["clicks"]==before+1
            and clicked["lastClickTab"]==little_strip["activeTab"] and clicked["lastClickTab"]!=main_tab
            and clicked.get("lastClickURL")==target_url and target_tab==target_url,"clicked":clicked,"mainTab":main_tab}
        results["X19_activeTab_grant"]={"ok":bool(granted) and "error" in before_grant and bool(clicked)
            and clicked.get("lastClickScript")=={"url":target_url},"permissionsGranted":bool(granted),"beforeClick":before_grant,"clicked":clicked}
        app.eval(control,"chrome.action.setPopup({popup:'popup.html'}).then(()=>true)")
        little_call("ext-click",extension="more",select=action(probe)["name"])
        little_popup=wait_until(lambda:(lambda p:p if p.get("visible") else None)(little_call("ext-popup-state")),timeout=15)
        queried=app.eval(little_popup["page"],"chrome.tabs.query({active:true,currentWindow:true}).then(ts=>ts.map(t=>({id:t.id,url:t.url})))") if little_popup else []
        actual_tab=app.call("little-open-state")["sessions"][0]["browser"]["active"]
        # The actual page's Chrome tab id is independently read by Section 9.
        button=little_strip["buttonFrame"];anchor=frame(little_popup["anchor"]) if little_popup else []
        expected=[button[0]+little["frame"][0],button[1]+little["frame"][1],*button[2:]]
        panel=frame(little_popup["frame"]) if little_popup else []
        # A3 clamps the panel to the visible screen's 8 pt inset when Little
        # Open's top-right frame puts the button near that edge.
        screen=little["visibleFrame"]
        expected_left=min(max(anchor[0],screen[0]+8),screen[0]+screen[2]-8-panel[2]) if little_popup else None
        results["X19_popup_tabs_query"]={"ok":bool(little_popup) and queried==[{"id":little["chromeTabID"],"url":target_url}]
            and queried[0]["id"]!=main_tab,"queried":queried,"session":little,"mainTab":main_tab,"page":actual_tab}
        results["X19_popup_anchor"]={"ok":bool(little_popup) and little_popup["anchorKind"]=="littleOpen"
            and len(anchor)==4 and all(abs(a-b)<=1 for a,b in zip(anchor,expected))
            and abs(panel[0]-expected_left)<=1 and abs(panel[1]+panel[3]-(anchor[1]-6))<=1,
            "popup":little_popup,"expectedAnchor":expected,"expectedLeft":expected_left}
        if little_popup: app.call("key",key="w",modifiers=["command"],window=little_popup["window"],route="app")
        # guess (child), Section 6 lead ruling: extra extension tabs leave
        # Little Open for the most recent main window's selected Today list.
        main_window=app.call("window-state")["id"]
        extra_url=local_origin+"/extension-extra"
        little_call("ext-click",extension="more",select=action(probe)["name"])
        extra_popup=wait_until(lambda:(lambda p:p if p.get("visible") else None)(little_call("ext-popup-state")),timeout=15)
        try:
            if extra_popup:
                app.eval(extra_popup["page"],"chrome.tabs.query({active:true,currentWindow:true}).then(ts=>chrome.runtime.sendMessage({type:'create-tab',windowId:ts[0].windowId,url:"+repr(extra_url)+"}));true")
            extra=wait_until(lambda:next((t for t in app.call("tabs") if t["url"]==extra_url and t["selected"]),None),timeout=15)
            if extra: app.call("wait",tab=extra["id"],timeout=15)
            main_page=app.eval(extra["id"],"location.href") if extra else None
            kept=next(s for s in app.call("little-open-state")["sessions"] if s["id"]==little_id)
            created_result=app.eval(control,"chrome.storage.session.get('createdTab').then(v=>v.createdTab||null)")
            results["X19_extra_tab_main_today"]={"ok":bool(extra_popup and extra) and extra["section"]=="today"
                and extra["visible"] and app.call("window-state")["id"]==main_window
                and main_page==extra_url
                and bool(created_result) and created_result["windowId"]==little["browser"]["chromeWindowID"]
                and (created_result.get("pendingUrl") or created_result.get("url"))==extra_url
                and kept["chromeTabID"]==little["chromeTabID"] and kept["content"]==little["content"]
                and kept["url"]==target_url and len(kept["browser"]["tabs"])==1,
                "mainWindow":main_window,"mainPage":main_page,"createdTab":created_result,
                "mainTabs":app.call("tabs"),"extra":extra,"little":kept}
        finally:
            for tab in app.call("tabs"):
                if tab["url"]==extra_url: app.call("close",tab=tab["id"])
            app.call("little-open-action",id=little_id,action="focus")
        # Registry changes reach the standalone window without a polling loop.
        app.eval(control,"chrome.storage.session.set({probeScript:false}).then(()=>true)")
        installed_actions=[a["id"] for a in actions()]
        try:
            for identifier in installed_actions:
                if identifier!=probe: app.call("ext-manage",extension=identifier,action="disable")
            single=wait_until(lambda:(lambda state:state if state["visible"] and state["ids"]==[probe] else None)(little_call("ext-strip")),timeout=10)
            results["X19_one_action"]={"ok":bool(single),"strip":single}
            app.call("ext-manage",extension=probe,action="disable")
            empty=wait_until(lambda:(lambda state:state if not state["visible"] and not state["ids"] else None)(little_call("ext-strip")),timeout=10)
            results["X19_zero_actions"]={"ok":bool(empty),"strip":empty}
        finally:
            for identifier in installed_actions: app.call("ext-manage",extension=identifier,action="enable")
        wait_until(lambda:len(little_call("ext-strip")["ids"])==len(installed_actions),timeout=10)
        old=little_call("ext-strip",retainBrowser=True)
        # Create a second real Profile and seed its distinct action list.
        other_space=app.call("space-create",title="X19 Profile",profile="X19 Profile")
        other_profile=next(s["profile"] for s in app.call("spaces") if s["id"]==other_space)
        app.call("little-open-action",id=little_id,action="switch-profile",profile=other_profile)
        alert=app.call("little-open-profile-alert")
        if alert.get("visible"): app.call("little-open-profile-alert",action="confirm")
        switched=wait_until(lambda:next((s for s in app.call("little-open-state")["sessions"]
            if s["id"]==little_id and s["profile"]==other_profile and s.get("content") and not s["loading"]),None),timeout=20)
        rebound=little_call("ext-strip")
        if not switched or not rebound["visible"] or rebound["browser"]!=switched["browserID"]:
            results["X19_profile_switch"]={"ok":False,"old":old,"rebound":rebound,"session":switched}
            return
        # Disable one action only in this Profile, then execute its probe.
        little_call("ext-manage",extension=extensions["bitwarden"],action="disable")
        changed=wait_until(lambda:(lambda s:s if extensions["bitwarden"] not in s["ids"] and probe in s["ids"] else None)(little_call("ext-strip")),timeout=10)
        little_call("ext-click",extension="more",select="Action Probe")
        new_popup=wait_until(lambda:(lambda p:p if p.get("visible") else None)(little_call("ext-popup-state")),timeout=15)
        new_query=app.eval(new_popup["page"],"chrome.tabs.query({active:true,currentWindow:true}).then(ts=>ts.map(t=>({id:t.id,url:t.url})))") if new_popup else []
        results["X19_profile_switch"]={"ok":bool(switched and changed and new_popup)
            and rebound["browser"]==switched["browserID"] and rebound["browser"]!=old["browser"]
            and rebound["context"]!=old["context"] and rebound["delegateMatches"] and rebound["retainedDelegateCleared"]
            and rebound["retainedActionIDs"]==[]
            and rebound["retainedBrowser"]==old["browser"] and set(changed["ids"])==set(old["ids"])-{extensions["bitwarden"]}
            and new_query==[{"id":switched["chromeTabID"],"url":target_url}],
            "old":old,"rebound":rebound,"changed":changed,"session":switched,"queried":new_query}
        if new_popup: app.call("key",key="w",modifiers=["command"],window=new_popup["window"],route="app")
        # Little Open stays in B while the most recent main window returns to A.
        # There is no B main window, so routing must create one with B's Space.
        app.call("space",space=original_main["space"])
        app.call("window-focus",id=original_main["id"],activate=True)
        front_a=app.call("window-state")
        a_tabs={t["id"] for t in app.call("tabs")}
        main_windows={w["id"] for w in app.call("shell-windows")}
        profile_url=local_origin+"/extension-extra-profile-b"
        routed=None
        try:
            little_call("ext-click",extension="more",select="Action Probe")
            profile_popup=wait_until(lambda:(lambda p:p if p.get("visible") else None)(little_call("ext-popup-state")),timeout=15)
            if profile_popup:
                app.eval(profile_popup["page"],"chrome.runtime.sendMessage({type:'create-tab',windowId:"+str(switched["browser"]["chromeWindowID"])+",url:"+repr(profile_url)+"});true")
            routed=wait_until(lambda:next((t for t in app.call("tabs") if t["url"]==profile_url and t["selected"]),None),timeout=15)
            if routed: app.call("wait",tab=routed["id"],timeout=15)
            destination=app.call("window-state")
            destination_space=next((s for s in app.call("spaces") if s["id"]==destination["space"]),None)
            loaded=app.eval(routed["id"],"location.href") if routed else None
            app.call("window-focus",id=original_main["id"],activate=True)
            untouched_a=app.call("window-state")
            after_a=app.call("tabs")
            results["X19_extra_tab_profile"]={"ok":bool(profile_popup and routed and destination_space)
                and front_a["space"]==original_main["space"] and original_profile!=other_profile
                and destination["id"]!=original_main["id"] and destination_space["profile"]==other_profile
                and routed["profile"]==other_profile and routed["space"]==destination_space["id"]
                and routed["section"]=="today" and routed["visible"] and loaded==profile_url
                and untouched_a["space"]==original_main["space"] and {t["id"] for t in after_a}==a_tabs,
                "frontA":front_a,"destination":destination,"destinationSpace":destination_space,
                "routed":routed,"loaded":loaded,"afterA":after_a}
            kept=wait_until(lambda:next((s for s in app.call("little-open-state")["sessions"]
                if s["id"]==little_id and len(s["browser"]["tabs"])==1),None),timeout=10)
            blank={"skipped":"no Profile-B destination"}
            blank_ok=True
            if routed and routed["profile"]==other_profile:
                app.call("window-focus",id=destination["id"],activate=True)
                b_control=app.call("open",url="chrome-extension://"+probe+"/popup.html")["id"]
                app.call("wait",tab=b_control,timeout=15)
                before_blank={t["id"] for t in app.call("tabs")}
                app.eval(b_control,"chrome.storage.session.remove('createdTab').then(()=>chrome.runtime.sendMessage({type:'create-tab',windowId:"+str(switched["browser"]["chromeWindowID"])+",url:'about:blank'}))")
                blank=wait_until(lambda:app.eval(b_control,"chrome.storage.session.get('createdTab').then(v=>v.createdTab||null)"),timeout=10)
                kept_blank=wait_until(lambda:next((s for s in app.call("little-open-state")["sessions"]
                    if s["id"]==little_id and len(s["browser"]["tabs"])==1),None),timeout=10)
                blank_ok=bool(blank and kept_blank) and not blank.get("error") and {t["id"] for t in app.call("tabs")}==before_blank
            results["X19_extra_tab_strip_cleanup"]={"ok":bool(kept) and blank_ok
                and kept["content"]==switched["content"] and kept["chromeTabID"]==switched["chromeTabID"]
                and kept["url"]==target_url,
                "afterRoute":kept,"blankCreated":blank,"blankClosedWithoutMainTab":blank_ok}
        finally:
            for window in app.call("shell-windows"):
                if window["id"] not in main_windows:
                    app.call("window-focus",id=window["id"],activate=True)
                    app.call("window-close")
            app.call("window-focus",id=original_main["id"],activate=True)
            for tab in app.call("tabs"):
                if tab["url"]==profile_url: app.call("close",tab=tab["id"])
        little_call("ext-strip",retainBrowser=False)
    finally:
        if app.call("ext-prompt").get("pending"): app.call("ext-prompt",answer="cancel")
        app.call("ext-prompt",handler=prompt_handler)
        alert=app.call("little-open-profile-alert")
        if alert.get("visible"): app.call("little-open-profile-alert",action="cancel")
        app.call("little-open-action",id=little_id,action="close")
