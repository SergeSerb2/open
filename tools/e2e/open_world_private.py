"""Real-App private-context script delivery across replacement renderers."""


def run(app, results, new_tab, wait_until, port, normal_tab):
    normal_window = app.call("window-state")["id"]
    normal_context = app.call("incognito-state", private=True)["context"]
    private_window = None
    private_scripts = []
    observations = []
    try:
        app.call("menu-perform", id="new-incognito-window")
        private_window = wait_until(lambda: next((w for w in
            app.call("incognito-state")["windows"] if w["private"]), None), timeout=10)
        assert private_window, "private window did not open"
        app.call("window-focus", id=private_window["id"], activate=True)
        private_tab = new_tab(app, "http://127.0.0.1:%d/handoff" % port)
        private_state = app.call("incognito-state", private=True)
        initial = app.eval(private_tab, "({normal:handoffAtStart,private:privateAtStart})")
        # Install only in the private context, after this browser already exists.
        for world in ("page", "open"):
            identifier = "p7-private-" + world
            app.call("script-add", id=identifier, world=world, matches=["http://*/*"],
                source="""(() => {
                  const mark = () => document.documentElement.setAttribute('data-private-%s', 'early');
                  if (document.documentElement) mark(); else new MutationObserver((m,o)=>{
                    if(document.documentElement){o.disconnect();mark()}
                  }).observe(document,{childList:true});
                })()""" % world)
            private_scripts.append(identifier)
        before_processes = app.call("metrics", interval=0)["processes"]
        for host in ("localhost", "127.0.0.1"):
            app.call("navigate", tab=private_tab, url="http://%s:%d/handoff" % (host, port))
            app.call("wait", tab=private_tab, timeout=15)
            observations.append(app.eval(private_tab, "({normal:handoffAtStart,private:privateAtStart})"))
            if host == "localhost":
                swapped_processes = app.call("metrics", interval=0)["processes"]
        before_ids = {p["pid"] for p in before_processes}
        new_renderers = [p for p in swapped_processes
                         if p["pid"] not in before_ids and "(Re" in p["name"]]
        app.call("window-focus", id=normal_window, activate=True)
        app.call("navigate", tab=normal_tab, url="http://localhost:%d/handoff" % port)
        app.call("wait", tab=normal_tab, timeout=15)
        normal = app.eval(normal_tab, "({normal:handoffAtStart,private:privateAtStart})")
        empty = {"page": None, "open": None}
        early = {"page": "early", "open": "early"}
        results["open_world_private_renderer"] = {
            "ok": private_state["private"] and private_state["ephemeral"]
                and private_state["context"] != normal_context and bool(new_renderers)
                and initial == {"normal": empty, "private": empty}
                and observations == [{"normal": empty, "private": early}] * 2
                and normal == {"normal": early, "private": empty},
            "initialPrivateDocument": initial, "privateAtDocumentStart": observations,
            "normalAtDocumentStart": normal, "privateContext": private_state["context"],
            "normalContext": normal_context, "newRenderers": new_renderers,
            "processesBefore": before_processes, "processesAfterSwap": swapped_processes}
    except Exception as error:
        results["open_world_private_renderer"] = {"ok": False, "error": str(error),
                                                   "privateAtDocumentStart": observations}
    finally:
        if private_window:
            app.call("window-focus", id=private_window["id"], activate=True)
            for identifier in private_scripts:
                app.call("script-remove", id=identifier)
            app.call("window-close")
        app.call("window-focus", id=normal_window, activate=True)
