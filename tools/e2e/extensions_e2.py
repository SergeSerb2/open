"""E11/E12 and sidebar tab events through the real Open application and extensions."""
import json
import os
from pathlib import Path
import shutil
import time

def fixtures(root, tmp, extensions):
    source = Path(root) / "tools/e2e/fixtures/action-probe"
    action = Path(tmp) / "action-probe-e2"
    shutil.copytree(source, action)
    manifest = json.loads((action / "manifest.json").read_text())
    manifest["name"] = "Action Probe"
    (action / "manifest.json").write_text(json.dumps(manifest))
    conflict = Path(tmp) / "keyword-conflict"
    conflict.mkdir()
    (conflict / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "YouTube Conflict Probe", "version": "1.0",
        "omnibox": {"keyword": "yt"}}))
    pin_probes = []
    for suffix in ("B", "C"):
        probe = Path(tmp) / ("pin-probe-" + suffix)
        probe.mkdir()
        (probe / "manifest.json").write_text(json.dumps({
            "manifest_version": 3, "name": "Pinned order probe " + suffix,
            "version": "1.0", "action": {"default_title": "Pin probe " + suffix}}))
        pin_probes.append(str(probe))
    native_drag = [str(Path(extensions) / name) for name in ("ublock-lite", "darkreader")]
    if not all((Path(p) / "manifest.json").is_file() for p in native_drag):
        raise RuntimeError("extensions-e2 requires unpacked ublock-lite and darkreader in --extensions")
    return [str(action), str(conflict), str(Path(root) / "tools/e2e/fixtures/tabs-probe")] + pin_probes + native_drag


def run(app, results, tmp, root, wait, new_tab, factory, restore_defaults):
    # Use the manifest key's actual id, also guarding accidental fixture replacement.
    installed = wait(lambda: (lambda rows: rows if any(x["name"] == "Action Probe" for x in rows) else None)(
        app.call("extensions")["installed"]), timeout=30)
    action = next(x["id"] for x in installed if x["name"] == "Action Probe")
    tabs = next(x["id"] for x in installed if x["name"] == "Open tabs probe")
    preference = app.call("ext-windows", preference=True)
    app.call("ext-windows", preference=True, value=None)
    reporter = new_tab(app, "chrome-extension://%s/popup.html" % action)
    app.call("wait", tab=reporter)

    def js(code, page=None):
        return app.eval(reporter if page is None else page, code)

    def storage():
        return js("chrome.storage.session.get(null)")

    def rows():
        return app.call("commandbar-state")

    def key(name, modifiers=()):
        return app.call("key", key=name, modifiers=list(modifiers), route="app")

    def type_text(text):
        app.call("key", text=text)

    def open_bar(mode="t", keyword="probe"):
        key(mode, ["cmd"])
        key("a", ["cmd"])
        type_text(keyword)
        key("tab")
        return wait(lambda: rows() if rows().get("scope") else None, timeout=5)

    def native_window(cid):
        return next((w for w in app.call("ext-windows") if w["chromeWindowId"] == cid), None)

    def chrome_windows():
        return js("chrome.windows.getAll({populate:true})")

    try:
        focus = os.environ.get("OPEN_E2E_E2_SCOPE")
        if focus == "pins":
            pin_order(app, results, wait)
            return
        if focus == "drag":
            app = native_drag_safety(app, results, wait, action, factory)
            return
        if focus == "tabs":
            tab_events(app, results, tabs, wait, new_tab)
            return
        if focus == "e1":
            profile_lifetime(app, results, wait, new_tab, action, popup=os.environ.get("OPEN_E2E_E1_POPUP", "1") == "1")
            return
        if focus == "sweep3":
            app = sweep3(app, results, wait, new_tab, action, reporter, factory)
            return
        # X20: actual native controller, view ownership, type, bounds, update and remove.
        made = js("chrome.windows.create({type:'popup',url:chrome.runtime.getURL('popup.html'),"
                  "left:120,top:140,width:430,height:510,focused:false})")
        cid = made["id"]
        native = wait(lambda: native_window(cid), timeout=10)
        if os.environ.get("OPEN_E2E_E2_FORCE_FAILURE") in ("popup", "popup-quit"):
            if os.environ["OPEN_E2E_E2_FORCE_FAILURE"] == "popup-quit": app.quit()
            raise RuntimeError("forced E2 failure with extension popup open")
        chrome = next((w for w in chrome_windows() if w["id"] == cid), {})
        results["X20_popup_window"] = {"ok": bool(native) and native["controller"] == "ExtensionWindowController"
            and native["pageIsContentView"] and not native["hasToolbar"] and native["autosave"] == "ExtensionPopupWindow"
            and native["style"] & 15 == 15
            and chrome.get("type") == "popup" and [chrome.get(k) for k in ("left", "top", "width", "height")] == [120, 140, 430, 510]
            and native["frame"][2:] == [430, 510], "native": native, "chrome": chrome}
        if focus == "windows":
            js("chrome.windows.remove(%d).then(()=>true)" % cid)
            wait(lambda: native_window(cid) is None, timeout=5)
            return
        changed = js("chrome.windows.update(%d,{left:160,top:180,width:460,height:540})" % cid)
        resized = wait(lambda: (lambda w: w if w and w["frame"][2:] == [460, 540] else None)(native_window(cid)), timeout=5)
        js("chrome.windows.remove(%d).then(()=>true)" % cid)
        removed = wait(lambda: native_window(cid) is None and not any(w["id"] == cid for w in chrome_windows()), timeout=5)
        results["X20_update_remove"] = {"ok": bool(resized and removed), "updated": changed, "native": resized, "removed": bool(removed)}
        saved = app.call("ext-windows", preference=True)
        # Relaunch the same real profile; the next popup has no explicit bounds.
        app.quit()
        app = factory(urls=())
        wait(lambda: app.call("extensions")["ready"], timeout=30)
        reporter = next(t["id"] for t in app.call("tabs") if t["url"] == "chrome-extension://%s/popup.html" % action)
        app.call("select", tab=reporter)
        app.call("wait", tab=reporter)
        restored = js("chrome.windows.create({type:'popup',url:chrome.runtime.getURL('popup.html'),focused:false})")
        restored_native = wait(lambda: native_window(restored["id"]), timeout=10)
        results["X20_autosave_relaunch"] = {"ok": bool(saved and restored_native) and restored_native["frame"] == resized["frame"],
            "saved": saved, "before": resized and resized["frame"], "after": restored_native}
        js("chrome.windows.remove(%d).then(()=>true)" % restored["id"])

        keyed = js("chrome.windows.create({type:'popup',url:chrome.runtime.getURL('popup.html')})")
        keyed_native = wait(lambda: native_window(keyed["id"]), timeout=10)
        title = wait(lambda: (lambda w: w if w and w["title"] == "Action probe popup" else None)(native_window(keyed["id"])), timeout=10)
        app.call("focus", tab=keyed_native["page"])
        tabs_before = len(app.call("tabs"))
        app.call("key", key="w", modifiers=["cmd"], window=keyed_native["number"], route="app")
        key_closed = wait(lambda: native_window(keyed["id"]) is None, timeout=5)
        results["E11_native_title_and_cmd_w"] = {"ok": bool(title and key_closed) and len(app.call("tabs")) == tabs_before,
            "title": title and title["title"], "closed": bool(key_closed), "sidebarTabsKept": len(app.call("tabs")) == tabs_before}

        parent = next(w["id"] for w in chrome_windows() if w["type"] == "normal")
        normal = js("chrome.windows.create({type:'normal',url:'https://example.com/?e11normal'})")
        today = wait(lambda: [t for t in app.call("tabs") if "e11normal" in t["url"] and t["visible"]], timeout=10)
        results["E11_normal_today"] = {"ok": normal["id"] == parent and bool(today) and today[0]["section"] == "today"
            and not app.call("ext-windows"), "window": normal["id"], "parent": parent, "today": today}

        # Keep the reporter out of the selected target so current-tab navigation cannot destroy it.
        target = new_tab(app, "https://example.com/?target")
        key("t", ["cmd"]); type_text("action pro")
        found = wait(lambda: [r for r in rows().get("rows", []) if r["kind"] == "extensionAction" and r["extension"] == action], timeout=5)
        results["X22_action_row"] = {"ok": bool(found) and found[0]["keycaps"] == ["⇧", "⌘", "Y"], "rows": found}
        if focus == "actions": return
        # Select the matched action through real arrows and Return.
        index = next(i for i, r in enumerate(rows()["rows"]) if r["kind"] == "extensionAction" and r["extension"] == action)
        for _ in range(index): key("down")
        key("return")
        popup = wait(lambda: app.call("ext-popup") if app.call("ext-popup").get("open") else None, timeout=5)
        results["X22_return_action"] = {"ok": bool(popup) and popup["source"] == "user", "popup": popup}
        app.call("popup-close")

        js("chrome.storage.session.set({onInputCancelled:0}).then(()=>true)")
        scoped = open_bar()
        type_text("al")
        suggested = wait(lambda: rows() if [r["title"] for r in rows().get("rows", [])] == ["Probe: al", "alpha"] else None, timeout=5)
        before_default = storage().get("omniboxInputs")
        js("chrome.omnibox.setDefaultSuggestion({description:'Changed: %s'}).then(()=>true)")
        refreshed = wait(lambda: rows() if [r["title"] for r in rows().get("rows", [])] == ["Changed: al", "alpha"] else None, timeout=5)
        results["E12_live_default_change"] = {"ok": bool(refreshed) and storage().get("omniboxInputs") == before_default,
            "bar": refreshed, "inputsBefore": before_default, "inputsAfter": storage().get("omniboxInputs")}
        js("chrome.omnibox.setDefaultSuggestion({description:'Probe: %s'}).then(()=>true)")
        key("escape")
        cancelled = wait(lambda: storage().get("onInputCancelled") == 1, timeout=5)
        time.sleep(.35)
        results["X23_keyword_suggestions_cancel"] = {"ok": bool(scoped and scoped["scope"] == "Action Probe" and suggested and cancelled)
            and storage().get("onInputCancelled") == 1, "scope": scoped, "suggestions": suggested, "cancelled": storage().get("onInputCancelled")}

        for mode, disposition in (("l", "currentTab"), ("t", "newForegroundTab")):
            app.call("select", tab=target)
            before = {t["id"] for t in app.call("tabs")}
            open_bar(mode); type_text("beta")
            wait(lambda: rows().get("final"), timeout=5)
            key("return")
            entered = wait(lambda: (lambda s: s if s.get("omniboxEntered", {}).get("disposition") == disposition else None)(storage()), timeout=5)
            loaded = wait(lambda: [t for t in app.call("tabs") if t["url"] == "https://example.com/?q=beta" and t["visible"]], timeout=10)
            correct = bool(loaded) and (loaded[0]["id"] == target if mode == "l" else loaded[0]["id"] not in before and loaded[0]["section"] == "today")
            results["X24_" + disposition] = {"ok": bool(entered) and correct, "entered": entered and entered.get("omniboxEntered"), "loaded": loaded}

        open_bar(); type_text("a"); type_text("l"); type_text("p")
        latest = wait(lambda: rows() if rows().get("text") == "alp" and rows().get("final") else None, timeout=5)
        time.sleep(.5)
        late = rows()
        results["X25_latest_only"] = {"ok": bool(latest) and late["text"] == "alp" and [r["title"] for r in late["rows"]] == ["Probe: alp", "alpha"], "latest": latest, "afterLateReply": late}
        key("escape")
        conflict = open_bar(keyword="yt")
        results["X26_site_search_wins"] = {"ok": bool(conflict) and conflict["scope"] == "YouTube", "bar": conflict}
        key("escape")

        open_bar(); type_text("b")
        delete_rows = wait(lambda: rows() if len(rows().get("rows", [])) == 2 else None, timeout=5)
        key("down"); key("delete", ["shift"])
        deleted = wait(lambda: storage().get("omniboxDeleted") == "beta", timeout=5)
        results["E12_delete_suggestion"] = {"ok": bool(delete_rows and deleted) and len(rows().get("rows", [])) == 1,
            "before": delete_rows, "after": rows()}
        key("escape")

        app.call("ext-manage", extension=action, action="disable")
        wait(lambda: not any(e["id"] == action and e["enabled"] for e in app.call("extensions")["installed"]), timeout=5)
        key("t", ["cmd"]); type_text("action pro")
        wait(lambda: rows().get("final"), timeout=5)
        disabled_rows = rows()
        results["E12_disabled_action_hidden"] = {"ok": not any(r["extension"] == action for r in disabled_rows.get("rows", [])), "bar": disabled_rows}
        key("escape")
        app.call("ext-manage", extension=action, action="enable")
        wait(lambda: any(e["id"] == action and e["enabled"] for e in app.call("extensions")["installed"]), timeout=5)
        reporter = new_tab(app, "chrome-extension://%s/popup.html" % action)
        app.call("wait", tab=reporter)

        # Bounds through the public engine API and the real extension worker.
        app.call("ext-omnibox", extension=action, op="start")
        accepted = app.call("ext-omnibox", extension=action, op="input", text="x" * 16384)
        replied = wait(lambda: app.call("ext-omnibox", extension=action, op="reply") or None, timeout=5)
        refused = app.call("ext-omnibox", extension=action, op="input", text="x" * 16385)
        limits = []
        for length in (16384, 16385):
            js("chrome.omnibox.setDefaultSuggestion({description:'x'.repeat(%d)}).then(()=>true)" % length)
            result = app.call("ext-omnibox", extension=action, op="default")
            limits.append({"length": length, "result": result})
        for count in (256, 257):
            js("chrome.omnibox.setDefaultSuggestion({description:'<match>x</match>'.repeat(%d)}).then(()=>true)" % count)
            result = app.call("ext-omnibox", extension=action, op="default")
            limits.append({"styles": count, "result": result})
        results["E12_engine_bounds"] = {"ok": accepted is True and bool(replied) and refused is False
            and [x["result"]["present"] for x in limits] == [True, False, True, False],
            "inputAtLimit": accepted, "replyAtLimit": replied, "inputOverLimit": refused, "defaults": limits}
        app.call("ext-omnibox", extension=action, op="cancel")
        js("chrome.omnibox.setDefaultSuggestion({description:'Probe: %s'}).then(()=>true)")

        pin_order(app, results, wait)
        tab_events(app, results, tabs, wait, new_tab)
        app = native_drag_safety(app, results, wait, action, factory)
        reporter = new_tab(app, "chrome-extension://%s/popup.html" % action)
        app.call("wait", tab=reporter)
        app = sweep3(app, results, wait, new_tab, action, reporter, factory)
    finally:
        try:
            app.quit()
        finally:
            # Quit can save the popup frame. Restore afterwards, with the
            # harness's defaults fallback when the App/socket is already gone.
            restore_defaults(app, {"NSWindow Frame ExtensionPopupWindow": preference})


def pin_order(app, results, wait):
    names = {"Action Probe", "Pinned order probe B", "Pinned order probe C"}
    available = wait(lambda: (lambda rows: rows if len([a for a in rows if a["name"] in names]) == 3 else None)(
        app.call("actions")["actions"]), timeout=10)
    if not available:
        results["actions_pin_move_unique"] = {"ok": False, "error": "three live actions not ready"}
        return
    ids = [a["id"] for a in available if a["name"] in names]
    expected, snapshots = [], []

    def check(stage):
        def state():
            rows = app.call("actions")["actions"]
            all_ids = [a["id"] for a in rows]
            pinned = [a for a in rows if a["pinned"]]
            extension_state = app.call("extensions")
            dropped = extension_state.get("duplicatesDropped", 0)
            ok = len(all_ids) == len(set(all_ids)) and [a["id"] for a in pinned] == expected \
                and [a["pinnedIndex"] for a in pinned] == list(range(len(expected))) and dropped == 0
            return {"ok": ok, "stage": stage, "ids": all_ids,
                "pinned": [[a["id"], a["pinnedIndex"]] for a in pinned],
                "expected": list(expected), "duplicatesDropped": dropped,
                "appGuardPresent": "duplicatesDropped" in extension_state}
        settled = wait(lambda: (lambda s: s if s["ok"] else None)(state()), timeout=1)
        snapshots.append(settled or state())

    for id in ids: app.call("ext-pin", extension=id, pinned=False)
    check("all unpinned")
    for id in ids:
        app.call("ext-pin", extension=id, pinned=True); expected.append(id)
        check("pin " + id)
        app.call("ext-pin", extension=id, pinned=True)
        check("repeat pin " + id)
        app.call("ext-move", extension=id, index=0)
        expected.remove(id); expected.insert(0, id)
        check("move to first " + id)
        app.call("ext-move", extension=id, index=0)
        check("repeat move " + id)
    for id in reversed(ids):
        app.call("ext-move", extension=id, index=len(expected) - 1)
        expected.remove(id); expected.append(id)
        check("move to last " + id)
        app.call("ext-pin", extension=id, pinned=False); expected.remove(id)
        check("unpin " + id)
        app.call("ext-pin", extension=id, pinned=False)
        check("repeat unpin " + id)
    results["actions_pin_move_unique"] = {"ok": all(s["ok"] for s in snapshots), "snapshots": snapshots}


def native_drag_safety(app, results, wait, action, factory):
    # Official keys in the real third-party fixtures, also used by the actions suite.
    ubo, dark = "ddkjiahejlhfcafbddmgiahcphecmpfh", "eimadpbcbfnmbkopoojfekhnkhdbieeh"
    ids = [ubo, dark, action]
    ready = wait(lambda: set(ids) <= {a["id"] for a in app.call("actions")["actions"]}, timeout=30)
    if not ready:
        results["actions_native_drag_safety"] = {"ok": False, "error": "native drag fixtures not ready"}
        return app
    expected, snapshots = [], []
    def check(stage):
        def state():
            rows = app.call("actions")["actions"]
            all_ids = [a["id"] for a in rows]
            pins = [a for a in rows if a["pinned"]]
            guard = app.call("extensions")
            return {"ok": len(all_ids) == len(set(all_ids)) and [a["id"] for a in pins] == expected
                and [a["pinnedIndex"] for a in pins] == list(range(len(expected)))
                and guard.get("duplicatesDropped", 0) == 0,
                "stage": stage, "ids": all_ids, "pinned": [[a["id"], a["pinnedIndex"]] for a in pins],
                "expected": list(expected), "duplicatesDropped": guard.get("duplicatesDropped", 0),
                "appGuardPresent": "duplicatesDropped" in guard}
        settled = wait(lambda: (lambda s: s if s["ok"] else None)(state()), timeout=1)
        snapshots.append(settled or state())
    try:
        for id in ids: app.call("ext-pin", extension=id, pinned=False)
        for id in ids:
            app.call("ext-pin", extension=id, pinned=True); expected.append(id)
        check("pin uBO, Dark Reader, probe")
        app.call("ext-move", extension=action, index=0)
        expected.remove(action); expected.insert(0, action)
        check("probe 2 to 0")
        app.call("ext-move", extension=action, index=2)
        expected.remove(action); expected.append(action)
        check("probe 0 to 2")
        app.call("ext-pin", extension=action, pinned=True)
        check("repeat pin probe")
        negative_refused = False
        try:
            app.call("ext-move", extension=ubo, index=-1)
        except RuntimeError as error:
            negative_refused = "index must be nonnegative" in str(error)
        check("refuse negative automation index")
        snapshots[-1]["ok"] &= negative_refused
        for index in (len(expected), 99, 2**32 + 1, 2**63 - 1):
            app.call("ext-move", extension=ubo, index=index, engine=True)
            check("refuse index " + str(index))
        unknown = "a" * 32
        app.call("ext-pin", extension=unknown, pinned=True)
        app.call("ext-move", extension=unknown, index=0)
        check("refuse unknown id")
        app.call("ext-pin", extension=action, pinned=False); expected.remove(action)
        app.call("ext-move", extension=action, index=0)
        check("refuse unpinned probe")
        for id in ids: app.call("ext-pin", extension=id, pinned=False)
        expected.clear()
        app.call("ext-move", extension=ubo, index=0)
        check("refuse empty pinned list")
        # Reopen a real profile in the state left by the former pin setter.
        # Only this suite's stopped, isolated Chromium profile is modified.
        profile = Path(app.call("ping")["userData"])
        if not profile.parent.name.startswith("Open-E2E-"):
            raise RuntimeError("refusing to modify a non-E2E profile")
        for id in ids: app.call("ext-pin", extension=id, pinned=True)
        app.quit()
        preferences = profile / "Default/Preferences"
        stored = json.loads(preferences.read_text())
        stored["extensions"]["pinned_extensions"] = ids + [action]
        preferences.write_text(json.dumps(stored))
        app = factory(urls=())
        wait(lambda: app.call("actions")["ready"], timeout=30)
        expected[:] = ids
        check("repair persisted duplicate after relaunch")
        app.call("ext-move", extension=action, index=0)
        expected.remove(action); expected.insert(0, action)
        check("repaired profile probe 2 to 0")
        app.call("ext-move", extension=action, index=2)
        expected.remove(action); expected.append(action)
        check("repaired profile probe 0 to 2")
        results["actions_native_drag_safety"] = {"ok": all(s["ok"] for s in snapshots),
            "alive": app.call("ping") is not None, "snapshots": snapshots}
    finally:
        for id in ids:
            try: app.call("ext-pin", extension=id, pinned=False)
            except Exception: pass
    return app


def tab_events(app, results, extension, wait, new_tab):
    reporter = new_tab(app, "chrome-extension://%s/popup.html" % extension)
    app.call("wait", tab=reporter)
    def js(code): return app.eval(reporter, code)
    def events(): return js("chrome.storage.session.get({events:[]}).then(s=>s.events)")
    def row(tab): return next((t for t in app.call("tabs") if t["id"] == tab), None)
    def cid(tab): return row(tab)["page"]["chromeTabId"]
    def moved_since(start, ids):
        return [e for e in events()[start:] if e["type"] == "moved" and e["tabId"] in ids]

    a, b, c, d = [new_tab(app, "https://example.com/?move=" + x) for x in "abcd"]
    ids = [cid(x) for x in (a, b, c)]
    # Chrome returns the final order. Match it to the sidebar after every deferred observer reply.
    reply = js("chrome.tabs.move(%s,{index:0}).then(()=>chrome.tabs.query({currentWindow:true}).then(ts=>ts.map(t=>t.id)))" % json.dumps(ids))
    actual = wait(lambda: (lambda current: current if current == reply else None)(
        [t["page"]["chromeTabId"] for t in app.call("tabs") if t.get("page") and t["page"]["live"]]), timeout=5)
    results["tabs_array_move"] = {"ok": bool(actual), "chrome": reply, "sidebar": actual}
    start = len(events()); app.call("sidebar-move", tab=a, index=1)
    moved = wait(lambda: moved_since(start, [cid(a)]), timeout=5)
    results["tabs_sidebar_move_event"] = {"ok": bool(moved), "events": moved}
    for pinned in (True, False):
        start = len(events()); app.call("pin", tab=b)
        got = wait(lambda: [e for e in events()[start:] if e["type"] == "pinned" and e["tabId"] == cid(b) and e["pinned"] == pinned], timeout=5)
        results["tabs_sidebar_" + ("pin" if pinned else "unpin")] = {"ok": bool(got), "events": got}
    for pinned in (True, False):
        js("chrome.tabs.update(%d,{pinned:%s}).then(()=>true)" % (cid(c), json.dumps(pinned)))
        changed = wait(lambda: row(c) if (row(c)["section"] == "pinned") == pinned else None, timeout=5)
        results["tabs_extension_" + ("pin" if pinned else "unpin")] = {"ok": bool(changed), "tab": changed}
    old_space = next(s["id"] for s in app.call("spaces") if s["focused"])
    new_space = app.call("space-create", title="E2 event Space")
    start = len(events())
    app.call("sidebar-drop", nodes=[a], parent={"kind": "today", "id": new_space}, index=0)
    cross = wait(lambda: moved_since(start, [cid(a)]), timeout=5)
    results["tabs_cross_space_move_event"] = {"ok": bool(cross) and row(a)["space"] == new_space, "events": cross, "tab": row(a)}
    app.call("space", space=old_space)
    app.call("select", tab=d); panes = app.call("split")
    if len(panes) == 2:
        # Automation makes a split from existing tabs, retaining the first
        # pane's focus. The real command must change model focus to the second.
        start = len(events()); app.call("command", id="focus-split-pane-2")
        focus_id = cid(panes[1]["id"])
        changed = wait(lambda: [e for e in events()[start:] if e["type"] == "activated" and e["tabId"] == focus_id], timeout=5)
        highlighted = wait(lambda: [e for e in events()[start:] if e["type"] == "highlighted" and e["tabIds"] == [focus_id]], timeout=5)
    else: changed = highlighted = None
    results["tabs_split_focus_events"] = {"ok": bool(changed and highlighted), "activated": changed, "highlighted": highlighted}
    app.call("split")


def screen_frames():
    # AppKit's own visible frames (Cocoa coordinates), the same space as ext-windows frames.
    script = ('ObjC.import("AppKit"); var s=$.NSScreen.screens, out=[]; for (var i=0;i<s.count;i++)'
              '{var f=s.objectAtIndex(i).visibleFrame; out.push([f.origin.x,f.origin.y,f.size.width,f.size.height]);}'
              ' JSON.stringify(out)')
    import subprocess
    return json.loads(subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                                     capture_output=True, text=True, timeout=10).stdout)


def on_screen(frame, screens):
    if not frame: return False
    x, y, w, h = frame
    return any(x >= sx - .5 and y >= sy - .5 and x + w <= sx + sw + .5 and y + h <= sy + sh + .5 for sx, sy, sw, sh in screens)


def sweep3(app, results, wait, new_tab, action, reporter, factory):
    """Bug sweep round 3 (EXT3): extension windows, popups and the toolbar snapshot."""
    def js(code, page=None):
        return app.eval(reporter if page is None else page, code)

    def native_window(cid):
        return next((w for w in app.call("ext-windows") if w["chromeWindowId"] == cid), None)

    def popup_tabs(cid):
        return js("chrome.windows.get(%d,{populate:true}).then(w=>w.tabs.map(t=>t.url||t.pendingUrl),()=>null)" % cid)

    def sidebar(marker):
        return [t for t in app.call("tabs") if marker in t["url"]]

    def remove(cid):
        js("chrome.windows.remove(%d).then(()=>true,()=>false)" % cid)
        wait(lambda: native_window(cid) is None, timeout=5)

    # E4: one action whose title is over the 4 KiB UI bound must not empty the whole
    # toolbar snapshot. A list reload (another extension disabled and enabled) rebuilds it.
    installed = app.call("extensions")["installed"]
    other = next(x["id"] for x in installed if x["name"] == "Pinned order probe B")
    before = app.call("ext-strip")["contextIDs"]
    js("chrome.action.setTitle({title:'x'.repeat(5000)}).then(()=>true)")
    app.call("ext-manage", extension=other, action="disable")
    wait(lambda: other not in app.call("ext-strip")["contextIDs"], timeout=5)
    app.call("ext-manage", extension=other, action="enable")
    after = wait(lambda: (lambda ids: ids if other in ids else None)(app.call("ext-strip")["contextIDs"]), timeout=5) or []
    titled = next((a for a in app.call("actions")["actions"] if a["id"] == action), {})
    results["R3_E4_long_title_keeps_toolbar"] = {"ok": action in before and action in after and other in after
        and set(before) <= set(after), "before": before, "after": after,
        "engineTitleLength": len(titled.get("title", ""))}
    js("chrome.action.setTitle({title:''}).then(()=>true)")

    # L13 (rejected seed): Chromium's windows API itself refuses bounds that are less than half on a
    # screen, at create and at update, so no off-screen frame reaches ExtensionWindowController.
    def refused(code):
        try:
            js(code); return None
        except RuntimeError as error:
            return str(error) if "50% within visible screen space" in str(error) else "other: " + str(error)
    create_refused = refused("chrome.windows.create({type:'popup',url:chrome.runtime.getURL('popup.html'),"
                             "left:-30000,top:-30000,width:430,height:510,focused:false})")
    made = js("chrome.windows.create({type:'popup',url:chrome.runtime.getURL('popup.html'),"
              "left:120,top:140,width:430,height:510,focused:false})")
    created = wait(lambda: native_window(made["id"]), timeout=10) or {}
    update_refused = refused("chrome.windows.update(%d,{left:40000,top:40000})" % made["id"])
    time.sleep(.3)
    kept = native_window(made["id"]) or {}
    screens = screen_frames()
    results["R3_L13_engine_refuses_offscreen_bounds"] = {"ok": bool(create_refused) and not create_refused.startswith("other")
        and bool(update_refused) and not update_refused.startswith("other") and on_screen(kept.get("frame"), screens),
        "create": create_refused, "update": update_refused, "frame": kept.get("frame"), "screens": screens}

    # E12: chrome.tabs.create into the popup window opens a visible sidebar tab in the
    # Profile's window; the popup keeps only its own page.
    cid = made["id"]
    js("chrome.tabs.create({windowId:%d,url:'https://example.com/?r3e12'}).then(()=>true,()=>false)" % cid)
    landed = wait(lambda: [t for t in sidebar("r3e12") if t["visible"]], timeout=10)
    popup = native_window(cid) or {}
    results["R3_E12_tab_into_popup_window"] = {"ok": bool(landed) and popup_tabs(cid) is not None
        and len(popup_tabs(cid)) == 1 and popup.get("pageIsContentView") is True,
        "sidebar": landed, "popupTabs": popup_tabs(cid), "native": popup}

    # L26: window.open from the hosted popup page (with and without window features).
    page = popup.get("page")
    found = {}
    for name, features in (("tab", ""), ("popup", "width=420,height=320")):
        marker = "r3l26" + name
        try:
            js("window.open('https://example.com/?%s','_blank','%s'); true" % (marker, features), page=page)
        except RuntimeError as error:
            found[name] = {"error": str(error)}
            continue
        found[name] = wait(lambda: [t for t in sidebar(marker) if t["visible"]], timeout=10) or []
    # Refused: URLs a page could not open itself must not become browser-initiated tabs.
    refused_urls = ("file:///etc/hosts", "chrome://settings/", "open://welcome")
    for target in refused_urls:
        try: js("window.open(%s,'_blank'); true" % json.dumps(target), page=page)
        except RuntimeError: pass
    time.sleep(1.5)
    leaked = [t["url"] for t in app.call("tabs") if t["url"].startswith(("file:", "chrome://settings", "open://welcome"))]
    results["R3_L26_window_open_from_popup"] = {"ok": all(isinstance(v, list) and v for v in found.values())
        and len(popup_tabs(cid) or []) == 1 and not leaked, "found": {k: len(v) if isinstance(v, list) else v for k, v in found.items()},
        "popupTabs": popup_tabs(cid), "refusedLeaked": leaked}
    remove(cid)
    profile_lifetime(app, results, wait, new_tab, action)
    return private_lifetime(app, results, wait, new_tab, action, factory)


def private_lifetime(app, results, wait, new_tab, action, factory):
    """E1, Incognito half (rejected seed, regression guard): an extension allowed in Incognito opens
    a popup window in the private session; closing the last Incognito window ends the session, which
    closes the popup too (the engine's releaseContext closes the context's Browsers)."""
    evidence = {}
    try:
        management = new_tab(app, "chrome://extensions")
        wait(lambda: app.eval(management, "typeof chrome.developerPrivate") == "object", timeout=20)
        evidence["grant"] = app.eval(management, "new Promise(done=>chrome.developerPrivate.updateExtensionConfiguration("
                                     "{extensionId:%s,incognitoAccess:true},()=>done(chrome.runtime.lastError?"
                                     "chrome.runtime.lastError.message:'ok')))" % json.dumps(action))
        app.call("close", tab=management)
        # The grant applies from the next launch (as in engine_e2e's extension_isolation row).
        app.call("save"); app.quit()
        app = factory(urls=())
        wait(lambda: app.call("extensions")["ready"], timeout=30)
        def allowed_reporter():
            page = new_tab(app, "chrome-extension://%s/popup.html" % action)
            try:
                if app.eval(page, "chrome.extension.isAllowedIncognitoAccess()") is True: return page
            except RuntimeError: pass
            app.call("close", tab=page); time.sleep(.5)
        reporter = wait(allowed_reporter, timeout=20)
        assert reporter, "the Incognito grant did not reach the extension"
        normal = app.call("window-state")["id"]
        app.call("menu-perform", id="new-incognito-window")
        private = wait(lambda: (lambda w: w if w["id"] != normal else None)(app.call("window-state")), timeout=5)
        app.call("open", url="about:blank")
        session = wait(lambda: (lambda s: s if s.get("context") and not s.get("closed") else None)(
            app.call("incognito-state", private=True).get("session", {})), timeout=10)
        evidence["session"] = session
        app.call("window-focus", id=normal, activate=True)
        made = app.eval(reporter, "chrome.windows.create({type:'popup',incognito:true,url:'about:blank',focused:false})"
                        ".then(w=>({id:w.id,incognito:w.incognito}),e=>({error:String(e)}))")
        evidence["created"] = made
        native = wait(lambda: next((w for w in app.call("ext-windows") if w["chromeWindowId"] == made.get("id")), None), timeout=10)
        evidence["popup"] = native and {k: native.get(k) for k in ("context", "ephemeral", "contextClosed")}
        app.call("window-focus", id=private["id"], activate=True)
        app.call("window-close")
        gone = wait(lambda: not any(w["chromeWindowId"] == made.get("id") for w in app.call("ext-windows")), timeout=10)
        evidence["popupClosedWithSession"] = bool(gone)
        contexts = app.call("engine-contexts")
        evidence["sessionContextLeft"] = bool(session) and session["context"] in contexts
        results["R3_E1_private_session_closes_popup"] = dict(evidence, ok=evidence["grant"] == "ok" and bool(session)
            and bool(native) and native.get("ephemeral") is True and native.get("context") == session["context"]
            and bool(gone) and not evidence["sessionContextLeft"])
    except Exception as error:
        results["R3_E1_private_session_closes_popup"] = dict(evidence, ok=False, error=repr(error)[:400])
    return app


def profile_lifetime(app, results, wait, new_tab, action, popup=True):
    """E1 (rejected seed, regression guard): deleting a Profile with an extension popup window
    open finishes at once and closes the popup (the engine's deleteContext closes the context's
    Browsers, popups included). popup=False is the control run without a popup."""
    name = "R3 Popup Profile"
    evidence = {}
    try:
        home = next(s["id"] for s in app.call("spaces") if s["focused"])
        space = app.call("space-create", title="R3 Popup Space", profile=name)
        page = new_tab(app, "chrome-extension://%s/popup.html" % action)
        app.call("wait", tab=page)
        context = app.page(page)["context"]
        made = app.eval(page, "chrome.windows.create({type:'popup',url:'about:blank',focused:false})") if popup else {"id": -1}
        native = wait(lambda: next((w for w in app.call("ext-windows") if w["chromeWindowId"] == made["id"]), None), timeout=10) if popup else {"control": True}
        evidence["pageContext"] = context
        app.call("space", space=home)
        assert app.call("space-profile", space=space, profile="Default")
        profile = next(p for p in app.call("profiles-shell")["profiles"] if p["name"] == name)
        if profile["spaces"]:
            app.call("alert", button="Change Profile")
        wait(lambda: next(p for p in app.call("profiles-shell")["profiles"] if p["id"] == profile["id"])["spaces"] == 0, timeout=5)
        app.call("profiles-shell", action="show", profile=name)
        time.sleep(.15)
        app.press_profile_delete()
        wait(lambda: app.call("profiles-shell")["sheet"] > 0, timeout=5)
        app.call("profiles-shell", action="type-delete", text=name)
        evidence["popupAtPress"] = next((w for w in app.call("ext-windows") if w["chromeWindowId"] == made["id"]), None) if popup else None
        started = time.monotonic()
        app.call("profiles-shell", action="press", label="Delete")
        timeline = []
        def done():
            shell = app.call("profiles-shell")
            row = [round(time.monotonic() - started, 1), shell.get("teardownStage"), shell.get("deleting"), shell.get("sheet")]
            if not timeline or timeline[-1][1:] != row[1:]: timeline.append(row)
            # `sheet` is a window number, not a count: the wipe is over when its stage is done.
            return not shell["deleting"] and shell.get("teardownStage") == "done"
        finished = wait(done, timeout=40, step=.1)
        evidence["timeline"] = timeline
        evidence["deleteSeconds"] = round(time.monotonic() - started, 2)
        shell = app.call("profiles-shell")
        evidence["stage"] = shell.get("teardownStage"); evidence["error"] = shell.get("errorText")
        evidence["popupsLeft"] = [w for w in app.call("ext-windows") if w["chromeWindowId"] == made["id"]]
        evidence["modelGone"] = not any(p["id"] == profile["id"] for p in shell["profiles"])
        at_press = evidence["popupAtPress"]
        results["R3_E1_profile_delete_closes_popup"] = dict(evidence, ok=bool(native)
            and (not popup or (bool(at_press) and at_press.get("context") == context))
            and bool(finished) and evidence["deleteSeconds"] < 10 and not evidence["popupsLeft"] and evidence["modelGone"])
    except Exception as error:
        results["R3_E1_profile_delete_closes_popup"] = dict(evidence, ok=False, error=str(error))
    finally:
        try: app.call("profiles-shell", action="cancel")
        except Exception: pass
