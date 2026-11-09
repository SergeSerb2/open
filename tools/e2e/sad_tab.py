"""Sad Tab acceptance via real renderer termination and real AppKit buttons.

Every renderer termination uses the existing crash-probe opt-out. No faulting URL,
synthetic crash flag, desktop input, or preferences writes.
"""
import os


KILL_ROWS = ("sad_tab_appears", "sad_tab_reload_identity", "sad_tab_close",
             "sad_tab_sibling_unaffected", "sad_tab_split", "sad_tab_peek")


def run(app, results, new_tab, wait_until, sibling):
    c = new_tab(app, "https://example.com/")
    try:
        healthy = app.call("sad-tab-state", tab=c)
        refused = False
        try:
            app.call("sad-tab-action", tab=c, action="reload")
        except RuntimeError as error:
            refused = "no shown Sad Tab" in str(error)
        results["sad_tab_healthy_absent"] = {"ok": healthy == {"shown": False} and refused,
                                              "state": healthy, "action_refused": refused}
        app.call("split")
        pane = next(t["id"] for t in app.call("tabs") if t["visible"] and t["id"] != c)
        try:
            app.call("navigate", tab=pane, url="https://example.org/")
            app.call("wait", tab=pane)
            results["sad_tab_healthy_split"] = {"ok": not app.call("sad-tab-state", tab=c)["shown"]
                and not app.call("sad-tab-state", tab=pane)["shown"]
                and app.eval(c, "document.title") == "Example Domain" and app.eval(pane, "document.title") == "Example Domain"}
        finally:
            app.call("close", tab=pane)
        app.call("peek-open", tab=c, url="https://example.org/")
        try:
            content = app.call("peek-state")["stack"][-1]["content"]
            app.call("wait", tab=content)
            results["sad_tab_healthy_peek"] = {"ok": not app.call("sad-tab-state", peek=True)["shown"]
                and app.eval(content, "document.title") == "Example Domain" and not app.tab(c)["crashed"]}
        finally:
            app.call("peek-close")
    finally:
        app.call("close", tab=c)
        app.call("select", tab=sibling)
    if os.environ.get("OPEN_E2E_NO_CRASH_PROBES") == "1":
        for name in KILL_ROWS:
            results[name] = {"status": "DEFERRED", "reason": "M1-only by rule; not run"}
        return

    def shown(tab=None, peek=False):
        return app.call("sad-tab-state", **({"peek": True} if peek else {"tab": tab}))["shown"]

    def kill(tab):
        # SIGTERM, not a renderer fault. The caller must have machine clearance.
        app.call("navigate", tab=tab, url="chrome://kill")

    pid = app.call("ping")["pid"]
    sibling_title = app.eval(sibling, "document.title")
    c = new_tab(app, "https://example.com/")
    try:
        before = app.page(c)
        url = app.tab(c)["url"]
        history_before = app.call("history-state")["rows"]
        kill(c)
        appeared = wait_until(lambda: app.page(c).get("crash") == 2 and app.tab(c)["crashed"] and shown(c), timeout=5, step=.05)
        state = app.call("sad-tab-state", tab=c)
        results["sad_tab_appears"] = {"ok": bool(appeared) and state.get("default")
            and [b["label"] for b in state.get("buttons", [])] == ["Reload", "Close Tab"], "state": state}
        app.call("sad-tab-action", tab=c, action="reload")
        recovered = wait_until(lambda: app.page(c).get("crash") == 0 and not app.tab(c)["crashed"] and not shown(c), timeout=20, step=.05)
        app.call("wait", tab=c, timeout=20)
        after = app.page(c)
        identity = {"ok": bool(recovered) and app.tab(c)["id"] == c
            and app.tab(c)["url"] == url and after["identifier"] == before["identifier"]
            and after["chromeTabId"] == before["chromeTabId"]
            and (before["style"] != "chrome" or before["chromeTabId"] > 0)
            and app.eval(c, "document.title") == "Example Domain",
            "same_tab": app.tab(c)["id"] == c, "before": before, "after": after,
            "chrome_identity_available": before["style"] == "chrome"}
        # Existing navigation entries must survive a renderer reload.
        app.call("navigate", tab=c, url="https://example.com/?sad-tab-history")
        app.call("wait", tab=c)
        kill(c)
        wait_until(lambda: shown(c), timeout=5, step=.05)
        # Return travels through NSApplication and the focused default button.
        app.call("key", key="return", route="app")
        wait_until(lambda: not shown(c), timeout=20, step=.05)
        app.call("wait", tab=c)
        app.call("back", tab=c)
        app.call("wait", tab=c)
        history_after = app.call("history-state")["rows"]
        identity["history_survived"] = app.page(c)["url"] == url and {
            r["url"] for r in history_before} <= {r["url"] for r in history_after}
        identity["ok"] &= identity["history_survived"]
        results["sad_tab_reload_identity"] = identity
        kill(c)
        wait_until(lambda: shown(c), timeout=5, step=.05)
        app.call("sad-tab-action", tab=c, action="close")
        closed = wait_until(lambda: all(t["id"] != c for t in app.call("tabs")), timeout=5, step=.05)
        results["sad_tab_close"] = {"ok": bool(closed)}
        results["sad_tab_sibling_unaffected"] = {"ok": app.call("ping")["pid"] == pid
            and app.eval(sibling, "document.title") == sibling_title and not app.tab(sibling)["crashed"]}
    finally:
        if any(t["id"] == c for t in app.call("tabs")):
            app.call("close", tab=c)
        app.call("select", tab=sibling)

    # Each pane is independent, including the unfocused pane.
    c = new_tab(app, "https://example.com/")
    try:
        app.call("split")
        pane = next(t["id"] for t in app.call("tabs") if t["visible"] and t["id"] != c)
        app.call("navigate", tab=pane, url="https://example.org/")
        app.call("wait", tab=pane)
        pane_title = app.eval(pane, "document.title")
        app.call("focus", tab=pane)
        kill(c)
        appeared = wait_until(lambda: shown(c), timeout=5, step=.05)
        independent = not shown(pane) and app.eval(pane, "document.title") == pane_title and not app.tab(pane)["crashed"]
        app.call("sad-tab-action", tab=c, action="reload")
        recovered = wait_until(lambda: not shown(c) and not app.tab(c)["crashed"], timeout=20, step=.05)
        app.call("wait", tab=c)
        kill(c)
        wait_until(lambda: shown(c), timeout=5, step=.05)
        app.call("sad-tab-action", tab=c, action="close")
        closed = wait_until(lambda: all(t["id"] != c for t in app.call("tabs")), timeout=5, step=.05)
        results["sad_tab_split"] = {"ok": bool(appeared) and independent and bool(recovered) and bool(closed)
            and app.eval(pane, "document.title") == pane_title, "sibling_pane_alive": independent}
    finally:
        for tab in (c, locals().get("pane")):
            if tab and any(t["id"] == tab for t in app.call("tabs")):
                app.call("close", tab=tab)
        app.call("select", tab=sibling)

    app.call("peek-open", tab=sibling, url="https://example.com/")
    try:
        content = app.call("peek-state")["stack"][-1]["content"]
        app.call("wait", tab=content)
        kill(content)
        appeared = wait_until(lambda: shown(peek=True), timeout=5, step=.05)
        source_alive = not app.tab(sibling)["crashed"] and app.eval(sibling, "document.title") == sibling_title
        app.call("sad-tab-action", peek=True, action="reload")
        recovered = wait_until(lambda: not shown(peek=True), timeout=20, step=.05)
        app.call("wait", tab=content)
        same_content = app.call("peek-state")["stack"][-1]["content"] == content
        kill(content)
        wait_until(lambda: shown(peek=True), timeout=5, step=.05)
        app.call("sad-tab-action", peek=True, action="close")
        closed = wait_until(lambda: not app.call("peek-state")["stack"], timeout=5, step=.05)
        results["sad_tab_peek"] = {"ok": bool(appeared) and source_alive and bool(recovered) and same_content and bool(closed)}
    finally:
        if app.call("peek-state")["stack"]:
            app.call("peek-close")
