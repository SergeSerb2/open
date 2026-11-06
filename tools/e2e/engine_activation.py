"""Browser close/key-window lifetime through the real App and CEF tab strip."""


def run(factory, results):
    app = factory(urls=("data:text/html,<title>Activation lifetime</title><p>ready</p>",),
                  fresh=True, extra_args=["--style=chrome"])
    try:
        tab = app.call("tabs")[0]
        app.call("wait", tab=tab["id"])
        original = app.call("window-state")
        app.call("space-create", title="Activation Profile", profile="Activation Profile")
        other = app.call("open", url="data:text/html,<title>Other profile</title><p>ready</p>")
        app.call("wait", tab=other["id"])
        app.call("engine-activation-state", reset=True)
        app.call("close", tab=other["id"])
        # The X19 setup: return to Profile A, then focus immediately. There
        # is no wait or polling command between the switch and native focus.
        app.call("space", space=original["space"])
        app.call("window-focus", id=original["id"], activate=True)
        focused = app.call("engine-activation-state")
        # One command holds the main run-loop turn across Close and native
        # key notifications. No sleeps, mock Browser, or desktop input.
        state = app.call("engine-close-activation")
        results["engine_close_host_activation"] = {
            "ok": state.get("prepared") is True and state["before"] >= 0
                  and state["after"] == -1 and state["closed"]
                  and state["hostVisible"] and state["hostKey"]
                  and focused["expectedChromeWindowID"] >= 0
                  and focused["activeChromeWindowID"] == focused["expectedChromeWindowID"]
                  and state["diagnostic"]["invalidActivationRequests"] == 0,
            "state": state, "profileFocus": focused,
        }
    finally:
        app.quit()
