"""Zap and Pick Selector through the real App, native panel, and P7 transport."""
import json
import os
import pathlib
import time

from sitecontrol_fixtures import fixture_server


class PickerFlow:
    def __init__(self, app, tab, wait_until):
        self.app, self.tab, self.wait_until = app, tab, wait_until

    def state(self):
        return self.app.call("boost-editor")

    def tap(self, control):
        return self.app.call("boost-editor", action="tap", id=control)

    def evaluate(self, source):
        return self.app.eval(self.tab, source, world="open")

    def active(self):
        return self.evaluate("window.__openZap?.isActive() === true")

    def enter(self, select=False):
        control = "editor.code.pick" if select else "zap"
        assert self.wait_until(lambda: any(c["id"] == control and c["enabled"]
                                          for c in self.state()["controls"]), timeout=10, step=.02), "picker control did not enable"
        self.tap(control)
        assert self.wait_until(self.active, timeout=5, step=.02), "picker did not enter"

    def dom(self, selector):
        root = self.app.call("devtools", tab=self.tab, method="DOM.getDocument", params={"depth": -1, "pierce": True})["root"]
        def find(node):
            attrs = node.get("attributes", [])
            if any(attrs[i:i+2] == ["id", "open-zap-overlay-host"] for i in range(0, len(attrs), 2)):
                return node
            for child in node.get("children", []) + node.get("shadowRoots", []):
                found = find(child)
                if found:
                    return found
        host = find(root)
        assert host and host.get("shadowRoots"), "no picker closed shadow root"
        result = self.app.call("devtools", tab=self.tab, method="DOM.querySelector",
                               params={"nodeId": host["shadowRoots"][0]["nodeId"], "selector": selector})
        assert result["nodeId"], "no overlay element " + selector
        return result["nodeId"]

    def overlay_click(self, selector, expected_count=None):
        node = self.dom(selector)
        box = self.app.call("devtools", tab=self.tab, method="DOM.getBoxModel", params={"nodeId": node})["model"]["content"]
        x, y = sum(box[::2])/4, sum(box[1::2])/4
        if selector == ".reveal":
            # Long but valid labels can overflow their scrollable shelf.
            shelf = self.app.call("devtools", tab=self.tab, method="DOM.getBoxModel", params={"nodeId": self.dom(".reveals")})["model"]["content"]
            x = (max(min(box[::2]), min(shelf[::2]))+min(max(box[::2]), max(shelf[::2])))/2
        self.app.call("devtools", tab=self.tab, method="Input.dispatchMouseEvent",
                      params={"type": "mouseMoved", "x": x, "y": y})
        if expected_count is not None:
            html = self.app.call("devtools", tab=self.tab, method="DOM.getOuterHTML", params={"nodeId": self.dom(".band")})["outerHTML"]
            assert ">%d " % expected_count in html, "wrong related count band: " + html
        for kind in ("mousePressed", "mouseReleased"):
            self.app.call("devtools", tab=self.tab, method="Input.dispatchMouseEvent",
                          params={"type": kind, "x": x, "y": y, "button": "left", "clickCount": 1})

    def hidden(self, selector):
        return self.app.eval(self.tab, "getComputedStyle(document.querySelector(%s)).display === 'none'" % json.dumps(selector))

    def pick(self, target, action, expected_count=None):
        point = self.app.eval(self.tab, "(() => {const r=document.querySelector(%s).getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()" % json.dumps(target))
        self.app.call("devtools", tab=self.tab, method="Input.dispatchMouseEvent",
                      params={"type": "mouseMoved", "x": point[0], "y": point[1]})
        def highlighted():
            attributes = self.app.call("devtools", tab=self.tab, method="DOM.getAttributes", params={"nodeId": self.dom(".hl")})["attributes"]
            return "hidden" not in attributes[::2]
        assert self.wait_until(highlighted, timeout=5, step=.02), "no hover highlight"
        self.app.call("click", tab=self.tab, selector=target)
        self.overlay_click(action, expected_count=expected_count)

    def messages(self, kind):
        rows = self.app.call("open-world-messages", tab=self.tab)["messages"]
        return [json.loads(r["payloadJSON"]) for r in rows if r["type"] == kind]


def run(factory, results, tmp, env):
    wait = env["wait_until"]
    app = None
    saved = {}
    keys = {"open.advanced.enableBoosts": True, "open.boosts.hasDismissedInterstitial": True,
            "open.boosts.codeEditorSize": "480x588"}
    with fixture_server(tmp) as origin:
        fixture = pathlib.Path(tmp)/"sitecontrol-fixtures"/"zap.html"
        fixture.write_text("""<!doctype html><html><head><script>
window.zapFirstScript={style:!!document.getElementById('open-boosts-style'),css:document.getElementById('open-boosts-style')?.textContent||'',picker:typeof window.__openZap};
window.pageShadowCalls=0;const attach=Element.prototype.attachShadow;Element.prototype.attachShadow=function(...args){window.pageShadowCalls++;return attach.apply(this,args)};
</script><title>Zap fixture</title><style>body{margin:24px}header{height:70px;background:#ddd;width:500px}article{height:40px;width:500px;background:#eee;margin:10px 0}#promo-banner{height:50px;width:500px;background:#fdd}</style></head>
<body><header>Header</header><div id="promo-banner">One banner</div><main><article class="card">First</article><article class="card">Second</article><article class="card">Third</article></main><button id="normal-button">Normal click</button>
<script>window.normalClicks=0;document.getElementById('normal-button').onclick=()=>window.normalClicks++;</script></body></html>""", encoding="utf-8")
        try:
            kwargs = {"urls": (origin+"/zap.html",), "fresh": True}
            if os.environ.get("OPEN_BOOST_NEGATIVE_APP"):
                kwargs["extra_env"] = {"OPEN_E2E_APP_BUNDLE": os.environ["OPEN_BOOST_NEGATIVE_APP"]}
            app = factory(**kwargs)
            tab = next(t["id"] for t in app.call("tabs") if t["selected"])
            app.call("wait", tab=tab)
            for key, value in keys.items():
                saved[key] = app.call("defaults", key=key, persistent=True)
                app.call("defaults", key=key, value=value)
            flow = PickerFlow(app, tab, wait)
            state = app.call("boost-editor", action="open")
            assert wait(lambda: flow.state()["colorsReady"], timeout=10, step=.02)
            boost_id = state["boost"]["id"]

            def row(name, run):
                try:
                    evidence = run()
                except Exception as error:
                    print(name+" FAIL "+str(error), flush=True)
                    results[name] = dict(ok=False, error=str(error), load=os.getloadavg())
                    raise
                results[name] = dict(evidence or {}, ok=True, load=os.getloadavg())
                print(name+" PASS", flush=True)

            def z1():
                assert flow.state()["zapAvailable"] and not flow.hidden("#promo-banner")
                flow.enter()
                flow.pick("#promo-banner", ".this")
                assert wait(lambda: flow.state()["zapCount"] == 1 and flow.hidden("#promo-banner"), timeout=5, step=.02)
                assert not flow.hidden("article")
                assert app.eval(tab, "({picker:typeof window.__openZap,native:typeof window.__openNative,applier:typeof window.__openBoosts,shadowCalls:window.pageShadowCalls})") == {
                    "picker":"undefined", "native":"undefined", "applier":"undefined", "shadowCalls":0}
                return {"storedSelectors": [z["selector"] for z in flow.state()["boost"]["zaps"]], "hoverHighlight": True}
            row("Z1_zap_one", z1)

            def z2():
                flow.pick("article", ".related", expected_count=3)
                assert wait(lambda: flow.state()["zapCount"] == 2 and app.eval(tab, "[...document.querySelectorAll('article')].every(e=>getComputedStyle(e).display==='none')"), timeout=5, step=.02)
                assert wait(lambda: any(e["matchCount"] == 3 for p in flow.messages("zap:list-result") for e in p["entries"]), timeout=5, step=.02)
                return {"relatedMatches":3, "nativeCount":flow.state()["zapCount"]}
            row("Z2_all_related_counts", z2)

            def z3():
                old_content = next(t["page"]["identifier"] for t in app.call("tabs") if t["id"] == tab)
                def renderers():
                    app.discover_owned_processes()
                    return {pid for pid, path in app.owned_processes.items()
                            if path.endswith("/Open Helper (Renderer)") and app.process_path(pid) == path}
                before_renderers = renderers()
                app.call("command", id="reload");app.call("wait", tab=tab)
                assert not flow.state()["zap"] and not flow.active()
                assert flow.hidden("#promo-banner") and flow.hidden("article")
                first = app.eval(tab, "window.zapFirstScript")
                assert first["style"] and first["picker"] == "undefined", first
                assert all(z["selector"] in first["css"] for z in flow.state()["boost"]["zaps"]), first
                app.call("navigate", tab=tab, url=origin.replace("127.0.0.1","localhost")+"/zap.html")
                app.call("wait", tab=tab)
                assert not flow.hidden("#promo-banner") and not flow.active()
                assert wait(lambda: renderers()-before_renderers, timeout=5, step=.05), "no replacement renderer observed"
                replacement_count = len(renderers()-before_renderers)
                app.call("back", tab=tab);app.call("wait", tab=tab)
                assert flow.hidden("#promo-banner") and flow.hidden("article") and not flow.active()
                assert flow.state()["boost"]["id"] == boost_id
                return {"firstScript": first, "stableContent":old_content == next(t["page"]["identifier"] for t in app.call("tabs") if t["id"] == tab), "replacementRenderers":replacement_count, "crossSiteAndBack":True}
            row("Z3_reload_renderer_navigation", z3)

            def z4():
                flow.enter()
                flow.overlay_click(".reveal")
                assert wait(lambda: flow.state()["zapCount"] == 1 and not flow.hidden("#promo-banner"), timeout=5, step=.02)
                assert flow.hidden("article")
                flow.overlay_click(".reveal")
                assert wait(lambda: flow.state()["zapCount"] == 0 and not flow.hidden("article"), timeout=5, step=.02)
                app.call("command", id="reload");app.call("wait", tab=tab)
                assert not flow.hidden("#promo-banner") and not flow.hidden("article")
                return {"removedLiveAndReload":True}
            row("Z4_reveal_chip", z4)

            def z5():
                flow.tap("code")
                assert wait(lambda: flow.state()["mode"] == "code", timeout=5, step=.02)
                original = "/* before */\n/* after */"
                app.call("boost-editor", action="type", text=original)
                app.call("boost-editor", action="key", key="left", modifiers=["cmd"])
                caret = flow.state()["codeSelection"][0]
                js = flow.state()["boost"]["js"]
                flow.enter(select=True)
                flow.pick("header", ".select")
                assert wait(lambda: flow.messages("picker:selected"), timeout=5, step=.02)
                picked = flow.messages("picker:selected")[-1]["selector"]
                expected = original[:caret]+picked+original[caret:]
                assert wait(lambda: not flow.state()["selecting"] and flow.state()["boost"]["css"] == expected, timeout=5, step=.02)
                assert flow.state()["boost"]["js"] == js
                assert flow.state()["zapCount"] == 0 and not flow.active()
                flow.tap("editor.code.js")
                assert not next(c for c in flow.state()["controls"] if c["id"] == "editor.code.pick")["enabled"]
                flow.tap("editor.code.back")
                assert wait(lambda: flow.state()["mode"] == "simple", timeout=5, step=.02)
                return {"insertedAtCaret":caret,"selected":picked,"jsUnchanged":True}
            row("Z5_selector_css_caret", z5)

            def z6():
                flow.enter()
                app.call("focus", tab=tab)
                app.call("key", key="escape", route="app")
                assert wait(lambda: not flow.state()["zap"] and not flow.active(), timeout=5, step=.02)
                app.call("click", tab=tab, selector="#normal-button")
                assert app.eval(tab, "window.normalClicks") == 1
                flow.enter();flow.overlay_click(".done")
                assert wait(lambda: not flow.state()["zap"] and not flow.active(), timeout=5, step=.02)
                flow.enter();app.call("boost-editor", action="close")
                assert wait(lambda: not flow.active(), timeout=5, step=.02)
                app.call("boost-editor", action="open", boost=boost_id)
                assert wait(lambda: flow.state()["colorsReady"], timeout=10, step=.02)
                return {"escape":True,"done":True,"editorClose":True,"pageClicks":1}
            row("Z6_exit_cleanup", z6)

            def authority():
                flow.enter()
                assert wait(lambda: bool(flow.messages("picker:ready")), timeout=5, step=.02)
                capability = flow.messages("picker:ready")[-1]
                before = app.call("boosts", action="get", boost=boost_id)
                # A page-world forgery has neither the binding nor its capability.
                app.eval(tab, "window.postMessage({v:1,type:'zap:committed',payload:{boostID:%s,sessionNonce:'invented-nonce',selector:'#promo-banner',matches:1}},'*')" % json.dumps(boost_id))
                base = dict(capability, selector="#promo-banner", matches=1)
                bad = [dict(base, sessionNonce="invented-nonce"), dict(base, selector="x"*4097),
                       dict(base, label="x"*1025), dict(base, matches=True), dict(base, matches=-1),
                       dict(base, extra=True)]
                for payload in bad:
                    flow.evaluate("__openNative.postMessage('zap:committed',%s);true" % json.dumps(json.dumps(payload)))
                assert app.call("boosts", action="get", boost=boost_id) == before
                # Native transport and coordinator accept the exact selector and
                # label limits, then the real reveal control removes that entry.
                boundary = dict(base, selector="#"+"a"*4095, label="L"*1024)
                flow.evaluate("__openNative.postMessage('zap:committed',%s);true" % json.dumps(json.dumps(boundary)))
                assert wait(lambda: flow.state()["zapCount"] == 1, timeout=5, step=.02)
                flow.overlay_click(".reveal")
                assert wait(lambda: flow.state()["zapCount"] == 0, timeout=5, step=.02)
                app.call("command", id="reload");app.call("wait", tab=tab)
                # The old capability is refused even through a new Open world.
                flow.enter()
                assert wait(lambda: flow.messages("picker:ready")[-1]["sessionNonce"] != capability["sessionNonce"], timeout=5, step=.02)
                flow.evaluate("__openNative.postMessage('zap:committed',%s);true" % json.dumps(json.dumps(base)))
                assert flow.state()["zapCount"] == 0 and flow.active()
                flow.overlay_click(".done")
                return {"pageForgeryRefused":True,"malformedRefused":len(bad),"selectorBytesAccepted":4096,"labelBytesAccepted":1024,"expiredRefused":True}
            row("Z7_native_authority_limits", authority)

            def unavailable():
                app.call("navigate", tab=tab, url="about:blank");app.call("wait", tab=tab)
                assert app.call("boost-editor", action="zap-available", tab=tab) is False
                app.call("close", tab=tab)
                assert app.call("boost-editor", action="zap-available", tab=tab) is False
                return {"internal":False,"closed":False}
            row("Z8_unavailable", unavailable)
        finally:
            env["_restore_defaults"](app, saved)
            if app:
                app.quit()
