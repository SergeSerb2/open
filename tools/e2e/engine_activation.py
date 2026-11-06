"""Browser close/key-window lifetime through the real App and CEF tab strip."""


def run(factory, results):
    app = factory(urls=("data:text/html,<title>Activation lifetime</title><p>ready</p>",), fresh=True)
    try:
        tab = app.call("tabs")[0]
        app.call("wait", tab=tab["id"])
        # One command holds the main run-loop turn across Close and native
        # key notifications. No sleeps, mock Browser, or desktop input.
        state = app.call("engine-close-activation")
        results["engine_close_host_activation"] = {
            "ok": state.get("prepared") is True and state["before"] >= 0
                  and state["after"] == -1 and state["closed"]
                  and state["hostVisible"] and state["hostKey"],
            "state": state,
        }
    finally:
        app.quit()
