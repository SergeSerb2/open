"""Sad Tab flows through real renderer termination, AppKit controls and app keys.

All termination rows use the shared crash-probe gate. No synthetic crash state,
faulting URL, desktop input, or preferences writes.
"""
from contextlib import contextmanager
import os


KILL_ROWS = (
    "sad_tab_appears", "sad_tab_reload_identity", "sad_tab_close",
    "sad_tab_sibling_unaffected", "sad_tab_split", "sad_tab_peek",
    "sad_tab_navigation", "sad_tab_background_select", "sad_tab_split_close",
    "sad_tab_return_unfocused_pane", "sad_tab_return_peek_over_crashed_pane",
    "sad_tab_split_focus", "sad_tab_keypad_enter", "sad_tab_shortcuts",
    "sad_tab_pinned_close", "sad_tab_favorite_close", "sad_tab_private",
)


def run(app, results, new_tab, wait_until, sibling, run_row):
    def exists(tab):
        return any(t["id"] == tab for t in app.call("tabs"))

    def page(handle):
        # Peek owns engine content without a sidebar tab UUID.
        if isinstance(handle, int):
            return next((p for p in app.call("pages") if p["identifier"] == handle), {})
        return app.page(handle)

    def state(tab=None, peek=False):
        return app.call("sad-tab-state", **({"peek": True} if peek else {"tab": tab}))

    def shown(tab=None, peek=False):
        return state(tab, peek)["shown"]

    def key(name, modifiers=()):
        return app.call("key", key=name, modifiers=list(modifiers), route="app")

    def focus_sad(tab=None, peek=False):
        app.call("sad-tab-action", action="focus", **({"peek": True} if peek else {"tab": tab}))
        assert state(tab, peek).get("focused"), "Sad Tab did not take focus"

    def dispose(tab):
        if not exists(tab):
            return
        split = app.call("split", op="state")
        if split["id"] and any(p["id"] == tab for p in split["panes"]):
            # Selecting a child UUID selects it outside its split. Separate via
            # the enabled split menu, then close the requested fixture tab.
            # Cleanup must also work when the pane-focus behavior under test fails.
            app.call("split", op="menu", item="Separate All Tabs")
            assert wait_until(lambda: not app.call("split", op="state")["id"], timeout=5, step=.05), "split cleanup did not separate panes"
        if app.tab(tab)["section"] in ("pinned", "favorites"):
            space = next(s["id"] for s in app.call("spaces") if s["focused"])
            app.call("sidebar-drop", nodes=[tab], parent={"kind": "today", "id": space}, index=0)
        app.call("close", tab=tab)

    @contextmanager
    def tab(url="https://example.com/", background=False):
        c = new_tab(app, url, background=background)
        try:
            yield c
        finally:
            try:
                dispose(c)
            finally:
                if exists(sibling):
                    app.call("select", tab=sibling)

    @contextmanager
    def split_pair():
        with tab() as c:
            app.call("split")
            pane = next(p["id"] for p in app.call("split", op="state")["panes"] if p["id"] != c)
            try:
                app.call("navigate", tab=pane, url="https://example.org/")
                app.call("wait", tab=pane)
                yield c, pane
            finally:
                dispose(pane)

    @contextmanager
    def peek(source, url="https://example.org/"):
        app.call("peek-open", tab=source, url=url)
        try:
            def ready_content():
                value = app.call("peek-state")
                return value["stack"][-1]["content"] if value["shown"] and value["stack"] else 0
            # The Peek entry precedes asynchronous engine content creation (ID 0).
            content = wait_until(ready_content, timeout=5, step=.05)
            assert content and content > 0, "Peek content did not become ready"
            app.call("wait", tab=content)
            yield content
        finally:
            if app.call("peek-state")["stack"]:
                app.call("peek-close")
                assert wait_until(lambda: not app.call("peek-state")["stack"], timeout=5, step=.05)

    def pane_key(tab):
        panes = app.call("split", op="state")["panes"]
        return str(next(i + 1 for i, pane in enumerate(panes) if pane["id"] == tab))

    def healthy_absent():
        with tab() as c:
            healthy = state(c)
            refused = False
            try:
                app.call("sad-tab-action", tab=c, action="reload")
            except RuntimeError as error:
                refused = "no shown Sad Tab" in str(error)
            return {"ok": healthy == {"shown": False} and refused, "state": healthy, "action_refused": refused}

    def healthy_split():
        with split_pair() as (c, pane):
            # Prove the same setup and pane-key mapping without terminating a renderer.
            for target in (c, pane, c):
                app.call("focus", tab=app.call("split", op="state")["focused"])
                key(pane_key(target), ("ctrl", "shift"))
                assert wait_until(lambda: app.call("split", op="state")["focused"] == target,
                                  timeout=3, step=.05), "healthy pane shortcut did not focus its target"
            return {"ok": not shown(c) and not shown(pane)
                    and app.eval(c, "document.title") == "Example Domain"
                    and app.eval(pane, "document.title") == "Example Domain"}

    def healthy_peek():
        with tab() as c, peek(c) as content:
            return {"ok": not shown(peek=True) and app.eval(content, "document.title") == "Example Domain"
                    and page(content).get("crash") == 0 and not app.tab(c)["crashed"]}

    healthy_rows = (("sad_tab_healthy_absent", healthy_absent), ("sad_tab_healthy_split", healthy_split),
                    ("sad_tab_healthy_peek", healthy_peek))
    for name, fn in healthy_rows:
        run_row(name, fn)

    if os.environ.get("OPEN_E2E_NO_CRASH_PROBES") == "1":
        for name in KILL_ROWS:
            results[name] = {"status": "DEFERRED", "reason": "M1-only by rule; not run"}
        return {"ok": all(results[name].get("ok", False) for name, _ in healthy_rows)}

    def kill(c, peek=False, visible=True):
        # SIGTERM only. The caller must have machine and screen clearance.
        app.call("navigate", tab=c, url="chrome://kill")
        assert wait_until(lambda: page(c).get("crash") == 2, timeout=5, step=.05), "kill state 2 missing"
        if visible:
            assert wait_until(lambda: shown(None if peek else c, peek), timeout=5, step=.05), "Sad Tab did not appear"

    def recovered(c, url, peek=False):
        assert wait_until(lambda: page(c).get("crash") == 0 and not shown(None if peek else c, peek),
                          timeout=20, step=.05), "Sad Tab did not recover"
        app.call("wait", tab=c, timeout=20)
        assert page(c)["url"] == url, "recovery changed the URL"
        assert app.eval(c, "document.title") == "Example Domain", "recovery did not restore the page"

    def appears():
        with tab() as c:
            kill(c)
            value = state(c)
            return {"ok": app.tab(c)["crashed"] and value.get("default")
                    and value.get("label") == "This page crashed. Something went wrong while showing this page."
                    and [b["label"] for b in value.get("buttons", [])] == ["Reload", "Close Tab"], "state": value}

    def reload_identity():
        with tab() as c:
            before = app.page(c)
            url = app.tab(c)["url"]
            history_before = {r["url"] for r in app.call("history-state")["rows"]}
            kill(c)
            app.call("sad-tab-action", tab=c, action="reload")
            recovered(c, url)
            after = app.page(c)
            assert app.tab(c)["id"] == c and app.tab(c)["url"] == url
            assert after["identifier"] == before["identifier"] and after["chromeTabId"] == before["chromeTabId"]
            assert before["style"] != "chrome" or before["chromeTabId"] > 0
            next_url = url + "?sad-tab-history"
            app.call("navigate", tab=c, url=next_url)
            app.call("wait", tab=c)
            kill(c)
            focus_sad(c)
            key("return")
            # Assert the wait and post-Return URL before Back can mask a failure.
            recovered(c, next_url)
            assert app.tab(c)["url"] == next_url
            app.call("back", tab=c)
            app.call("wait", tab=c)
            history_after = {r["url"] for r in app.call("history-state")["rows"]}
            return {"ok": app.page(c)["url"] == url and history_before <= history_after,
                    "before": before, "after": after, "post_return_url": next_url}

    def close():
        with tab() as c:
            # Closing must not ask the terminated renderer about this handler.
            app.eval(c, "window.onbeforeunload = () => true; true")
            kill(c)
            app.call("sad-tab-action", tab=c, action="close")
            return {"ok": bool(wait_until(lambda: not exists(c), timeout=5, step=.05))}

    def sibling_unaffected():
        pid = app.call("ping")["pid"]
        title = app.eval(sibling, "document.title")
        with tab() as c:
            kill(c)
            return {"ok": app.call("ping")["pid"] == pid and not app.tab(sibling)["crashed"]
                    and app.eval(sibling, "document.title") == title}

    def split_reload():
        with split_pair() as (c, pane):
            app.call("focus", tab=pane)
            url = app.tab(c)["url"]
            kill(c)
            independent = not shown(pane) and not app.tab(pane)["crashed"]
            app.call("sad-tab-action", tab=c, action="reload")
            recovered(c, url)
            return {"ok": independent and app.eval(pane, "document.title") == "Example Domain"}

    def peek_reload_close():
        with tab() as c, peek(c) as content:
            url = page(content)["url"]
            kill(content, peek=True)
            app.call("sad-tab-action", peek=True, action="reload")
            recovered(content, url, peek=True)
            same = app.call("peek-state")["stack"][-1]["content"] == content
            kill(content, peek=True)
            app.call("sad-tab-action", peek=True, action="close")
            closed = wait_until(lambda: not app.call("peek-state")["stack"], timeout=5, step=.05)
            return {"ok": same and bool(closed) and not app.tab(c)["crashed"]
                    and app.eval(c, "document.title") == "Example Domain"}

    def navigation():
        with tab() as c:
            kill(c)
            destination = "https://example.org/?sad-tab-navigation"
            app.call("navigate", tab=c, url=destination)
            recovered(c, destination)
            return {"ok": not app.tab(c)["crashed"] and app.tab(c)["id"] == c}

    def background_select():
        app.call("select", tab=sibling)
        with tab(background=True) as c:
            kill(c, visible=False)
            assert not shown(c), "background replacement is visible before selection"
            app.call("select", tab=c)
            appeared = wait_until(lambda: shown(c), timeout=5, step=.05)
            return {"ok": bool(appeared) and not app.tab(sibling)["crashed"]}

    def split_close():
        with split_pair() as (c, pane):
            kill(c)
            app.call("sad-tab-action", tab=c, action="close")
            closed = wait_until(lambda: not exists(c), timeout=5, step=.05)
            split = app.call("split", op="state")
            return {"ok": bool(closed) and not split["id"] and split["focused"] == pane
                    and app.eval(pane, "document.title") == "Example Domain", "split": split}

    def return_unfocused():
        with split_pair() as (c, pane):
            kill(c)
            app.call("focus", tab=pane)
            assert wait_until(lambda: app.call("split", op="state")["focused"] == pane, timeout=3, step=.05)
            app.call("events")
            key("return")
            # A JavaScript round trip on the sibling follows native key dispatch.
            assert app.eval(pane, "document.title") == "Example Domain"
            changed = wait_until(lambda: app.page(c)["crash"] != 2, timeout=.5, step=.05)
            events = app.call("events")
            return {"ok": not changed and shown(c) and app.page(c)["crash"] == 2
                    and not any(e.get("type") == "load" and e.get("tab") == c for e in events), "events": events}

    def return_peek():
        with tab() as c:
            kill(c)
            with peek(c) as content:
                url = page(content)["url"]
                # A healthy Peek must also shield the underlying default button.
                key("return")
                assert app.eval(content, "document.title") == "Example Domain"
                assert shown(c) and app.page(c)["crash"] == 2
                kill(content, peek=True)
                focus_sad(peek=True)
                key("return")
                recovered(content, url, peek=True)
                return {"ok": shown(c) and app.page(c)["crash"] == 2 and not shown(peek=True)}

    def split_focus():
        with split_pair() as (c, pane):
            kill(c)
            focus_sad(c)
            key(pane_key(c), ("ctrl", "shift"))
            assert wait_until(lambda: app.call("split", op="state")["focused"] == c, timeout=3, step=.05)
            key(pane_key(pane), ("ctrl", "shift"))
            assert wait_until(lambda: app.call("split", op="state")["focused"] == pane, timeout=3, step=.05)
            key(pane_key(c), ("ctrl", "shift"))
            assert wait_until(lambda: state(c).get("focused"), timeout=3, step=.05)
            with peek(c) as content:
                kill(content, peek=True)
                focus_sad(peek=True)
                key(pane_key(pane), ("ctrl", "shift"))
                return {"ok": bool(wait_until(lambda: app.call("split", op="state")["focused"] == pane,
                                             timeout=3, step=.05))}

    def keypad_enter():
        with tab() as c:
            url = app.tab(c)["url"]
            kill(c)
            focus_sad(c)
            key("enter")
            recovered(c, url)
            return {"ok": not app.tab(c)["crashed"]}

    def shortcuts():
        with tab() as c:
            kill(c)
            focus_sad(c)
            key("t", ("cmd",))
            assert wait_until(lambda: app.call("commandbar-state").get("presented"), timeout=5, step=.05)
            assert app.call("commandbar-state")["mode"] == "newTab", "Cmd+T failed from Sad Tab"
            key("escape")
            assert wait_until(lambda: not app.call("commandbar-state").get("presented"), timeout=5, step=.05)
            assert shown(c), "Esc dismissed the crashed tab"
            focus_sad(c)
            key("l", ("cmd",))
            assert wait_until(lambda: app.call("commandbar-state").get("presented"), timeout=5, step=.05)
            assert app.call("commandbar-state")["mode"] == "editCurrentURL", "Cmd+L failed from Sad Tab"
            key("escape")
            assert wait_until(lambda: not app.call("commandbar-state").get("presented"), timeout=5, step=.05)
            focus_sad(c)
            key("escape")
            assert shown(c) and app.page(c)["crash"] == 2, "Esc changed a standalone Sad Tab"
            focus_sad(c)
            key("w", ("cmd",))
            return {"ok": bool(wait_until(lambda: not exists(c), timeout=5, step=.05))}

    def retained_close(section):
        with tab() as c:
            app.call("pin" if section == "pinned" else "favorite", tab=c)
            app.call("select", tab=c)
            assert app.tab(c)["section"] == section
            kill(c)
            app.call("sad-tab-action", tab=c, action="close")
            unloaded = wait_until(lambda: exists(c) and not app.tab(c)["hasWebContent"], timeout=5, step=.05)
            return {"ok": bool(unloaded) and app.tab(c)["section"] == section and not shown(c), "tab": app.tab(c)}

    def private_window():
        windows_before = {w["id"] for w in app.call("incognito-state")["windows"]}
        number = app.call("window-state")["number"]
        normal = next(w for w in app.call("shell-windows") if w["number"] == number)
        app.call("menu-perform", id="new-incognito-window")
        try:
            private = wait_until(lambda: next((w for w in app.call("incognito-state")["windows"]
                                 if w["private"] and w["id"] not in windows_before), None), timeout=5, step=.05)
            assert private, "private window did not open"
            app.call("window-focus", id=private["id"], activate=True)
            key("escape")
            c = new_tab(app, "https://example.com/")
            url = app.tab(c)["url"]
            before = app.page(c)
            kill(c)
            app.call("sad-tab-action", tab=c, action="reload")
            recovered(c, url)
            assert app.call("incognito-state", private=True)["ephemeral"]
            assert app.page(c)["identifier"] == before["identifier"]
            kill(c)
            app.call("sad-tab-action", tab=c, action="close")
            return {"ok": bool(wait_until(lambda: not exists(c), timeout=5, step=.05))}
        finally:
            try:
                for window in app.call("incognito-state")["windows"]:
                    if window["private"] and window["id"] not in windows_before:
                        app.call("window-focus", id=window["id"], activate=True)
                        app.call("window-close")
            finally:
                app.call("window-focus", id=normal["id"], activate=True)

    flows = (appears, reload_identity, close, sibling_unaffected, split_reload, peek_reload_close,
             navigation, background_select, split_close, return_unfocused, return_peek,
             split_focus, keypad_enter, shortcuts,
             lambda: retained_close("pinned"), lambda: retained_close("favorites"), private_window)
    assert len(KILL_ROWS) == len(flows)
    for name, fn in zip(KILL_ROWS, flows):
        run_row(name, fn)
    return {"ok": all(results[name].get("ok", False) for name in KILL_ROWS)
            and all(results[name].get("ok", False) for name, _ in healthy_rows)}
