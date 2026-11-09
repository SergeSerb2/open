"""PR 277 round-1 proofs through the real App and persisted synthetic Boosts.

Run only after both holds end, with OPEN_E2E_BOOST_ZAP_REVIEW_ONLY=1 and the
normal engine_e2e --only boosteditor caller under the on-screen lock.
Break-and-restore recipes are in docs/boosts.md; no runtime validation bypasses.
"""
import json
import os
import pathlib

from boost_zap import PickerFlow
from sitecontrol_fixtures import fixture_server


def run(factory, results, tmp, env):
    wait = env["wait_until"]
    app = None
    saved = {}
    with fixture_server(tmp) as origin:
        selectors = ["#s12-long-" + str(i) + "-" + "a" * (4085 - len(str(i))) for i in range(24)]
        # Two matches per long selector, without copying a long selector into
        # result logs. The input/output snapshots each exceed one 64 KiB IPC.
        markup = "".join('<div id="%s">Zap match</div>' % s[1:] for s in selectors for _ in range(2))
        url = origin + "/zap-review.html"
        fixture = pathlib.Path(tmp) / "sitecontrol-fixtures" / "zap-review.html"
        fixture.write_text('<!doctype html><title>Zap round 1</title><body><h1>Zap round 1</h1>'
                           '<button id="normal-button">Click</button>' + markup +
                           '<script>window.normalClicks=0;document.querySelector("button").onclick=()=>window.normalClicks++</script></body>', encoding="utf-8")

        def launch(fresh=False):
            kwargs = dict(urls=(url,), fresh=fresh)
            if os.environ.get("OPEN_BOOST_NEGATIVE_APP"):
                kwargs["extra_env"] = {"OPEN_E2E_APP_BUNDLE": os.environ["OPEN_BOOST_NEGATIVE_APP"]}
            return factory(**kwargs)

        def row(name, fn):
            try:
                evidence = fn()
                assert evidence.get("negative") is True, "missing real-flow negative control"
                results[name] = dict(evidence, ok=True, load=os.getloadavg())
                print(name, "PASS", flush=True)
            except Exception as error:
                results[name] = dict(ok=False, error=str(error)[:400], load=os.getloadavg())
                raise

        def seed(zaps):
            nonlocal app, tab, flow
            # Persisted user-file input, edited only with the owned App stopped.
            # All launches use the same suite-private user-data root.
            app.call("boost-editor", action="close")
            app.quit()
            files = pathlib.Path(app.user_data).glob("Profiles/*/Boosts/boosts.json")
            source = next(p for p in files if any(b["id"] == boost_id for b in json.loads(p.read_text())["boosts"]))
            dto = json.loads(source.read_text())
            boost = next(b for b in dto["boosts"] if b["id"] == boost_id)
            boost["zaps"] = [dict(z, createdAt=z.get("createdAt", boost["createdAt"])) for z in zaps]
            source.write_text(json.dumps(dto))
            app = launch()
            tab = next(t["id"] for t in app.call("tabs") if t["selected"])
            app.call("navigate", tab=tab, url=url); app.call("wait", tab=tab)
            app.call("boost-editor", action="open", boost=boost_id)
            flow = PickerFlow(app, tab, wait)
            assert wait(lambda: flow.state()["colorsReady"], timeout=10, step=.02)

        def complete_counts():
            receipts = app.call("open-world-messages", tab=tab)["messages"]
            replies = [(json.loads(r["payloadJSON"]), r["pickerAccepted"]) for r in receipts if r["type"] == "zap:list-result"]
            complete = next((p for p, accepted in reversed(replies) if p.get("complete") is True and accepted), None)
            if not complete:
                return None
            snapshot = [(p, accepted) for p, accepted in replies if p.get("listID") == complete["listID"]]
            assert all(accepted for _, accepted in snapshot), "native refused a counts chunk"
            return [e for p, _ in snapshot for e in p["entries"]]

        def page_click(target_flow):
            before = app.eval(target_flow.tab, "window.normalClicks")
            app.call("click", tab=target_flow.tab, selector="#normal-button")
            assert app.eval(target_flow.tab, "window.normalClicks") == before + 1

        try:
            app = launch(fresh=True)
            tab = next(t["id"] for t in app.call("tabs") if t["selected"])
            app.call("wait", tab=tab)
            for key, value in {"open.advanced.enableBoosts": True,
                               "open.boosts.hasDismissedInterstitial": True}.items():
                saved[key] = app.call("defaults", key=key, persistent=True)
                app.call("defaults", key=key, value=value)
            state = app.call("boost-editor", action="open", mode="code")
            boost_id = state["boost"]["id"]
            app.call("boost-editor", action="type", text="/* persisted round-1 fixture */")
            # Closing flushes the ordinary CSS debounce and preserves the Boost.
            app.call("boost-editor", action="close")

            def chunks():
                zaps = [dict(selector=s, label="L" * 1024) for s in selectors]
                assert all(len(s.encode()) == 4096 for s in selectors)
                assert len(json.dumps(dict(selectors=selectors, labels={z["selector"]: z["label"] for z in zaps})).encode()) > 65536
                seed(zaps)
                assert flow.stopped(), "negative control: picker active before entry"
                app.call("open-world-messages", tab=tab, clear=True)
                flow.enter()
                entries = wait(complete_counts, timeout=10, step=.02)
                assert entries and len(entries) == len(selectors)
                assert {e["selector"] for e in entries} == set(selectors)
                assert all(e["matchCount"] == 2 and e["label"] == "L" * 1024 for e in entries)
                replies = flow.messages("zap:list-result")
                assert len(replies) > 2 and all(len(json.dumps(p, ensure_ascii=False, separators=(",", ":")).encode()) + len("zap:list-result") <= 65536 for p in replies)
                assert sum(len(json.dumps(p).encode()) for p in replies) > 65536
                assert flow.state()["zap"] and flow.active()
                shelf = app.call("devtools", tab=tab, method="DOM.querySelectorAll",
                                 params={"nodeId": flow.dom(".reveals"), "selector": ".reveal"})
                assert len(shelf["nodeIds"]) == len(selectors)
                flow.overlay_click(".done")
                assert wait(lambda: flow.stopped() and not flow.state()["zap"], timeout=5, step=.02)
                return dict(negative=True, stored=len(selectors), matchesPerSelector=2, replyChunks=len(replies),
                            requestAndReplyOver64KiB=True, selectorBytes=len(selectors[0].encode()), labelBytes=1024)
            row("Z9_chunked_counts_F1", chunks)

            def caps():
                seed([dict(selector="#cap-%d" % i, label="") for i in range(1024)])
                flow.enter()
                assert wait(lambda: len(complete_counts() or []) == 1024, timeout=10, step=.02)
                assert flow.state()["zap"] and flow.active()
                rejected = []
                for name, zaps in [
                    ("entries", [dict(selector="#cap-%d" % i, label="") for i in range(1025)]),
                    ("selector", [dict(selector="#" + "a" * 4096, label="")]),
                    ("label", [dict(selector="#normal-button", label="L" * 1025)]),
                ]:
                    seed(zaps)
                    state = flow.state()
                    control = next(c for c in state["controls"] if c["id"] == "editor.tool.zap")
                    assert not state["zapAvailable"] and not control["enabled"]
                    assert control["tooltip"] == "Zap isn't available yet."
                    refused = False
                    try:
                        flow.tap("zap")
                    except RuntimeError:
                        refused = True
                    assert refused and flow.stopped() and not flow.state()["zap"]
                    rejected.append(name)
                return dict(negative=True, acceptedEntries=1024, rejectedOverCap=rejected, disabledReason=True)
            row("Z10_stored_caps_F8", caps)

            def adoption():
                seed([])
                destination = app.call("open", url=url, background=True)["id"]
                identity = app.page(tab)["identifier"]
                flow.enter(); assert flow.state()["zap"] and flow.active()
                assert app.call("boost-editor", action="adopt-bound-page", destination=destination) is True
                moved = PickerFlow(app, destination, wait)
                # Check before selection: a tab-switch exit must not mask a
                # missing rebind exit hook.
                assert wait(lambda: moved.stopped() and not flow.state().get("zap", False), timeout=5, step=.02)
                assert app.page(destination)["identifier"] == identity
                app.call("select", tab=destination); app.call("wait", tab=destination)
                page_click(moved)
                return dict(negative=True, armedBefore=True, stoppedBeforeSelection=True, sameContent=True, pageClick=True)
            row("Z11_host_adoption_F2", adoption)

            def discard():
                seed([])
                flow.enter(); assert flow.state()["zap"] and flow.active()
                # Hide the real engine page without changing shell selection,
                # so the independent F5 hook cannot hide a broken discard hook.
                app.call("engine-sleep", tab=tab, op="hide")
                try:
                    assert app.call("boost-editor", action="discard-bound-page") is True
                    assert app.call("engine-sleep", tab=tab)["discarded"]
                    assert not flow.state()["zap"], "discard left native picker armed"
                finally:
                    app.call("engine-sleep", tab=tab, op="show")
                assert wait(lambda: not app.call("engine-sleep", tab=tab)["discarded"], timeout=5, step=.02)
                app.call("wait", tab=tab)
                assert not app.call("engine-sleep", tab=tab)["discarded"]
                assert flow.stopped() and not flow.state()["zap"]
                page_click(flow)
                return dict(negative=True, armedBefore=True, flagClearedBeforeWake=True, stoppedAfterWake=True, pageClick=True)
            row("Z12_discard_wake_F3", discard)

            def selection():
                seed([])
                other = app.call("open", url=url, background=True)["id"]
                flow.enter(); assert flow.state()["zap"] and flow.active()
                app.call("select", tab=other); app.call("wait", tab=other)
                assert wait(lambda: flow.stopped() and not flow.state().get("zap", False), timeout=5, step=.02)
                assert flow.evaluate("window.__openZap.isObserving()") is False
                app.call("select", tab=tab); app.call("wait", tab=tab)
                assert flow.stopped() and not flow.state().get("zap", False)
                page_click(flow)
                return dict(negative=True, armedBefore=True, hiddenPickerStopped=True, hiddenObserverStopped=True, pageClick=True)
            row("Z13_tab_switch_F5", selection)
        finally:
            if app:
                # A failure while replacing persisted input can occur between
                # quit and relaunch. Restore shared defaults through an owned App.
                if app.closed:
                    app = launch()
                try:
                    env["_restore_defaults"](app, saved)
                finally:
                    app.quit()
