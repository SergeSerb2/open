"""Real App Boost editor acceptance, site-control-boost-editor.md B1-B10."""
import json
import math
import os
import pathlib
import time
import traceback
import copy
import uuid
import statistics
import subprocess
from sitecontrol_fixtures import fixture_server


def run(factory, results, tmp, env):
    if os.environ.get("OPEN_E2E_BOOST_ZAP_REVIEW_ONLY") == "1":
        import boost_zap_review
        boost_zap_review.run(factory, results, tmp, env)
        return
    if os.environ.get("OPEN_E2E_BOOST_ZAP_ONLY") == "1":
        import boost_zap
        boost_zap.run(factory, results, tmp, env)
        return
    original_factory=factory
    def factory(**kwargs):
        if os.environ.get("OPEN_BOOST_NEGATIVE_APP"):
            kwargs["extra_env"]={"OPEN_E2E_APP_BUNDLE":os.environ["OPEN_BOOST_NEGATIVE_APP"]}
        return original_factory(**kwargs)
    wait_until, new_tab = env["wait_until"], env["new_tab"]
    app = None
    saved = {}
    keys = {"open.advanced.enableBoosts": True,
            "open.advanced.restoreWindowsOnLaunch": True,
            "open.boosts.hasDismissedInterstitial": False,
            "open.boosts.hasDismissedJSNotice": False,
            "open.boosts.codeEditorSize": "480x588",
            "open.library.lastSection": "spaces"}
    def call(action="state", **kw):
        return app.call("boost-editor", action=action, **kw)
    def items():
        return app.call("boosts", action="list")
    def probe(tab):
        try:
            return app.eval(tab, "({filter:getComputedStyle(document.documentElement).filter,font:getComputedStyle(document.querySelector('h1')).fontFamily,zoom:getComputedStyle(document.documentElement).zoom,transform:getComputedStyle(document.body).textTransform})")
        except RuntimeError as error:
            states=[t for t in app.call("tabs") if t["id"] == tab]
            raise RuntimeError(str(error)+"; page state="+json.dumps(states)) from error
    def row(name, fn):
        evidence = {}
        try:
            evidence = fn()
            assert evidence.pop("positive", False), "positive proof failed: " + json.dumps(evidence)
            assert evidence.get("negative") is True, "missing real-flow negative proof"
            results[name] = dict(evidence, ok=True, load=os.getloadavg())
            print(name, "PASS", flush=True)
        except env["FocusInterruption"]:
            raise
        except Exception as error:
            results[name] = dict(evidence, ok=False, error=str(error), trace=traceback.format_exc()[-1400:], load=os.getloadavg())
            print(name, "FAIL", str(error)[:160], flush=True)
    def active():
        return call().get("open", False)
    def ready():
        return wait_until(lambda: call().get("colorsReady"), timeout=10, step=.05)
    def tap(id):
        return call("tap", id=id)
    def close():
        return call("close")
    with fixture_server(tmp) as origin:
        try:
            app = factory(urls=(origin + "/boost.html",), fresh=True)
            tab = app.call("tabs")[0]["id"]
            app.call("wait", tab=tab)
            for key, value in keys.items():
                saved[key] = app.call("defaults", key=key, persistent=True)
                app.call("defaults", key=key, value=value)
            def b1():
                before = len(items()) == 1
                state = call("open")
                after = items()
                assert state["interstitial"]
                tap("firstRun.makeABoost")
                ready()
                return dict(positive=len(after) == 1 and after[0]["name"] == "My Boost" and after[0]["siteMatch"]["domain"] == "127.0.0.1" and state["mode"] == "simple" and not call()["interstitial"], negative=not before,
                            initial=state, stored=after)
            row("B1_create", b1)
            def b2():
                ready()
                state = call(); x,y,w,h = state["pad"]; cx,cy=x+w/2,y+h/2
                call("drag", points=[[cx-35,cy-20],[cx-20,cy+10],[cx,cy+40]])
                wait_until(lambda: "hue-rotate" in probe(tab)["filter"], timeout=5, step=.02)
                stored=items()[0]; wheel=stored["colorWheel"]; adjustment=stored["colorAdjustment"]
                expected=(wheel["intensity"]*((wheel["hue"]-wheel["baseHue"]+540)%360-180))%360
                positive=abs(wheel["baseHue"]-216)<10 and abs(wheel["hue"]-90)<.1 and abs(adjustment["hueRotateDegrees"]-expected)<1e-7 and "hue-rotate" in probe(tab)["filter"]
                tap("editor.color.reset")
                negative=bool(wait_until(lambda: probe(tab)["filter"] == "none", timeout=5, step=.02))
                tap("editor.undo")
                wait_until(lambda: "hue-rotate" in probe(tab)["filter"], timeout=5, step=.02)
                return dict(positive=positive,negative=negative,wheel=wheel,adjustment=adjustment,live=probe(tab))
            row("B2_filter_interim", b2)
            def b3():
                before=probe(tab)
                tap("font.Avenir");tap("size");tap("case")
                ok=wait_until(lambda: probe(tab)["font"].startswith("Avenir") and abs(float(probe(tab)["zoom"])-1.1)<.001 and probe(tab)["transform"] == "capitalize", timeout=5, step=.02)
                return dict(positive=bool(ok),negative=not (before["font"].startswith("Avenir") and str(before["zoom"]) == "1.1" and before["transform"] == "capitalize"),before=before,live=probe(tab))
            row("B3_font_text", b3)
            def b4():
                from boost_zap import PickerFlow
                picker = PickerFlow(app, tab, wait_until)
                picker.enter()
                picker.pick("#promo-banner", ".this")
                assert wait_until(lambda: call()["zapCount"] == 1 and picker.hidden("#promo-banner"), timeout=5, step=.02)
                picker.overlay_click(".reveal")
                assert wait_until(lambda: call()["zapCount"] == 0 and not picker.hidden("#promo-banner"), timeout=5, step=.02)
                tap("zap")
                stopped = wait_until(lambda: not call()["zap"] and picker.stopped(), timeout=5, step=.02)
                assert stopped, "toggle-off left a live page picker or observer"
                app.eval(tab, "window.s12B4Clicks=0;document.querySelector('h1').addEventListener('click',()=>window.s12B4Clicks++)")
                app.call("click", tab=tab, selector="h1")
                assert app.eval(tab, "window.s12B4Clicks") == 1, "picker still swallows page clicks"
                return dict(positive=True, negative=bool(stopped), pagePickerInactive=True, pageClicks=1, countAfterReveal=call()["zapCount"])
            row("B4_zap", b4)
            def b5():
                originalCSS=call()["boost"]["css"]
                first="window.boostEditorJSRuns=(window.boostEditorJSRuns||0)+1;window.boostEditorJSVersion='one';"
                second=first.replace("'one'","'two'")
                tap("code")
                assert wait_until(lambda: call()["mode"] == "code",timeout=5,step=.02)
                try:
                    call("type",text="h1 { text-decoration: underline !important; }")
                    assert wait_until(lambda: "underline" in app.eval(tab,"getComputedStyle(document.querySelector('h1')).textDecorationLine"),timeout=5,step=.02)
                    tap("editor.code.js")
                    assert call()["loadedJS"] is None and not call()["refreshToRun"]
                    call("type",text=first)
                    assert wait_until(lambda: call()["boost"]["js"] == first and call()["refreshToRun"],timeout=5,step=.02)
                    negative=app.eval(tab,"typeof window.boostEditorJSVersion") == "undefined"
                    assert negative
                    tap("editor.code.run");app.call("wait",tab=tab)
                    assert wait_until(lambda: call()["loadedJS"] == first and not call()["refreshToRun"],timeout=5,step=.02)
                    execution=app.eval(tab,"({version:window.boostEditorJSVersion??null,runs:window.boostEditorJSRuns??0,href:location.href})")
                    assert execution["version"] == "one" and execution["runs"] == 1, "document-start JS mismatch: "+json.dumps(execution)
                    call("type",text=second)
                    assert wait_until(lambda: call()["boost"]["js"] == second and call()["refreshToRun"],timeout=5,step=.02)
                    # A store/script refresh must not claim that the current
                    # document ran the newly saved JS or replay either version.
                    assert call()["loadedJS"] == first and app.eval(tab,"window.boostEditorJSVersion") == "one" and app.eval(tab,"window.boostEditorJSRuns") == 1
                    tap("editor.code.run");app.call("wait",tab=tab)
                    assert wait_until(lambda: call()["loadedJS"] == second and not call()["refreshToRun"],timeout=5,step=.02)
                    execution=app.eval(tab,"({version:window.boostEditorJSVersion??null,runs:window.boostEditorJSRuns??0,href:location.href})")
                    assert execution["version"] == "two" and execution["runs"] == 1, "document-start JS mismatch: "+json.dumps(execution)
                    app.eval(tab,"history.pushState({},'',location.pathname+'#code')")
                    assert call()["loadedJS"] == second and not call()["refreshToRun"]
                    return dict(positive=True,negative=negative,cssApplied=True,refreshAppearedAfterEdit=True,refreshDisappearedAfterReload=True,jsRunsPerDocument=1,sameDocumentKeptLoadedJS=True)
                finally:
                    if call().get("mode") == "code":
                        tap("editor.code.js");call("type",text="")
                        assert wait_until(lambda: call()["boost"]["js"] == "",timeout=5,step=.02)
                        app.call("command",id="reload");app.call("wait",tab=tab)
                        assert wait_until(lambda: call()["loadedJS"] is None and not call()["refreshToRun"],timeout=5,step=.02)
                        tap("editor.code.css");call("type",text=originalCSS)
                        assert wait_until(lambda: call()["boost"]["css"] == originalCSS,timeout=5,step=.02)
                        tap("editor.code.back")
                        assert wait_until(lambda: call()["mode"] == "simple",timeout=5,step=.02)
            row("B5_code",b5)
            def b6():
                # Code mode has its own undo steps. Create this row's text
                # change now so it verifies the editor's current undo owner.
                before=items()[0].get("textTransform")
                liveBefore=probe(tab)["transform"]
                tap("case")
                assert wait_until(lambda: items()[0].get("textTransform") != before,timeout=5,step=.02)
                negative=items()[0].get("textTransform") != before
                call("key", key="z", modifiers=["cmd"])
                ok=wait_until(lambda: items()[0].get("textTransform") == before and probe(tab)["transform"] == liveBefore, timeout=5, step=.02)
                return dict(positive=bool(ok),negative=negative,state=call(),live=probe(tab))
            row("B6_undo_app_key", b6)
            def b7():
                negative=items()[0]["name"] != "Docs Boost"
                tap("menu.Rename this Boost…")
                assert call()["alert"]["title"] == "Rename this Boost"
                call("type", text="Docs Boost");tap("alert.Done")
                wait_until(lambda: items()[0]["name"] == "Docs Boost",timeout=5,step=.02)
                tap("menu.Delete this Boost")
                alert=call()["alert"]
                assert alert["title"] == "Delete this Boost?" and alert["message"] == "This can't be undone."
                tap("alert.Cancel")
                assert len(items()) == 1
                tap("menu.Delete this Boost");tap("alert.Delete")
                ok=wait_until(lambda: not items() and not active(),timeout=5,step=.02)
                return dict(positive=bool(ok),negative=negative,alert=alert)
            row("B7_rename_delete", b7)
            def b8():
                call("open");ready();tap("font.Avenir");close()
                negative=len(items()) != 0
                call("open",boost=items()[0]["id"]);tap("menu.Delete this Boost");tap("alert.Delete")
                wait_until(lambda: not items(),timeout=5,step=.02)
                call("open");close()
                return dict(positive=not items() and not active(),negative=negative)
            row("B8_empty_draft", b8)
            def b9():
                nonlocal app,tab
                call("open");ready();tap("editor.color.invert");close()
                boost=items()[0]
                app.call("defaults",key="open.advanced.enableBoosts",value=False)
                app.quit();app=factory(urls=(origin+"/boost.html",))
                tab=app.call("tabs")[0]["id"];app.call("wait",tab=tab)
                negative=not bool(app.eval(tab,"window.styleAtDOMContentLoaded"))
                app.call("defaults",key="open.advanced.enableBoosts",value=True)
                app.quit();app=factory(urls=(origin+"/boost.html",))
                tab=app.call("tabs")[0]["id"];app.call("wait",tab=tab)
                first=app.eval(tab,"({filter:window.boostAtDOMContentLoaded,style:window.styleAtDOMContentLoaded})")
                call("open",boost=boost["id"])
                return dict(positive=first["style"] and "hue-rotate" in first["filter"] and call()["boost"]["id"] == boost["id"],negative=negative,documentStart=first)
            row("B9_restart_document_start",b9)
            def b26():
                nonlocal app,tab
                boost=items()[0]
                ready();tap("code")
                assert wait_until(lambda: call()["mode"] == "code",timeout=5,step=.02)
                tap("editor.code.js")
                call("type",text="window.boostRestoredFirstDocument='saved-before-launch';")
                assert wait_until(lambda: call()["boost"]["js"] == "window.boostRestoredFirstDocument='saved-before-launch';",timeout=5,step=.02)
                close()
                restored=new_tab(app,origin+"/boost-first.html")
                app.call("select",tab=restored);app.call("save")
                app.call("defaults",key="open.advanced.enableBoosts",value=False)
                app.quit();app=factory(urls=())
                selected=next(t for t in app.call("tabs") if t["selected"])
                assert selected["id"] == restored
                app.call("wait",tab=restored)
                off=app.eval(restored,"window.boostAtFirstScript")
                negative=not off["style"] and off["filter"] == "none" and off["js"] is None
                app.call("defaults",key="open.advanced.enableBoosts",value=True)
                app.quit();app=factory(urls=())
                selected=next(t for t in app.call("tabs") if t["selected"])
                assert selected["id"] == restored
                app.call("wait",tab=restored)
                first=app.eval(restored,"window.boostAtFirstScript")
                tab=restored;call("open",boost=boost["id"])
                ready();tap("code")
                assert wait_until(lambda: call()["mode"] == "code",timeout=5,step=.02)
                tap("editor.code.js");call("type",text=boost["js"]);tap("editor.code.back")
                return dict(positive=first["style"] and "hue-rotate" in first["filter"] and first["js"] == "saved-before-launch",negative=negative,
                            restoredTab=restored,firstDocumentFirstScript=first,disabledFirstDocument=off)
            row("B26_restored_first_document",b26)
            def b10():
                nonlocal app,tab
                negative=call()["globallyEnabled"]
                app.call("defaults",key="open.advanced.enableBoosts",value=False)
                wait_until(lambda: probe(tab)["filter"] == "none",timeout=5,step=.02)
                close();app.quit();app=factory(urls=(origin+"/boost.html",))
                tab=app.call("tabs")[0]["id"];app.call("wait",tab=tab)
                call("open",boost=items()[0]["id"])
                state=call()
                return dict(positive=not state["globallyEnabled"] and probe(tab)["filter"] == "none" and len(items()) == 1,negative=negative,state=state,live=probe(tab))
            row("B10_global_off",b10)
            def b11():
                nonlocal tab
                app.call("defaults",key="open.advanced.enableBoosts",value=True)
                wait_until(lambda: "hue-rotate" in probe(tab)["filter"],timeout=5,step=.02)
                negative=call()["active"]
                app.call("navigate",tab=tab,url=origin.replace("127.0.0.1","localhost")+"/boost.html")
                app.call("wait",tab=tab)
                assert active() and not call()["active"] and probe(tab)["filter"] == "none"
                app.call("navigate",tab=tab,url=origin+"/boost.html");app.call("wait",tab=tab)
                assert call()["active"]
                other=new_tab(app,origin+"/boost.html")
                closed=not active()
                app.call("select",tab=tab);app.call("wait",tab=tab);call("open",tab=tab,boost=items()[0]["id"])
                app.call("close",tab=tab)
                tab=other
                return dict(positive=closed and not active(),negative=negative)
            row("B11_navigation_tab_close",b11)
            def b12():
                # One window keeps eight hidden hosts. Use nine tabs plus a
                # second window's tab to measure ten actual live pages.
                original=app.call("window-state")["id"]
                # Earlier restart rows retain sidebar tabs. Remove those unrelated
                # pages before creating the measured nine-page window; otherwise
                # its eight-hidden-host cap can evict a measured page.
                close()
                for existing in app.call("tabs"):
                    if existing["id"] != tab: app.call("close",tab=existing["id"])
                app.call("select",tab=tab);app.call("wait",tab=tab)
                tabs=[tab];peer=None;other=None
                try:
                    tabs += [new_tab(app,origin+"/boost.html?tab="+str(i)) for i in range(8)]
                    measured=[t for t in app.call("tabs") if t["id"] in tabs]
                    assert len(measured) == 9 and all(t.get("page",{}).get("live") for t in measured), measured
                    handles=[t["page"]["identifier"] for t in measured]
                    app.call("command",id="new-window")
                    peer=app.call("window-state")["id"]
                    other=new_tab(app,origin+"/boost.html?peer=1")
                    handles.append(next(t["page"]["identifier"] for t in app.call("tabs") if t["id"] == other))
                    # Retain the peer page in its background Space, so it is
                    # hidden too: one foreground page and nine background pages.
                    app.call("space-create",title="Boost background retention")
                    assert len(handles) == 10 and len(set(handles)) == 10
                    app.call("window-focus",id=original,activate=True)
                    app.call("select",tab=tab);app.call("wait",tab=tab);call("open",boost=items()[0]["id"])
                    app.call("defaults",key="open.advanced.enableBoosts",value=False)
                    negative=bool(wait_until(lambda: all(probe(t)["filter"] == "none" for t in handles),timeout=5,step=.02))
                    app.call("defaults",key="open.advanced.enableBoosts",value=True)
                    wait_until(lambda: all("hue-rotate" in probe(t)["filter"] for t in handles),timeout=5,step=.02)
                    def page_counts():
                        pages=[p for p in app.call("pages") if p["identifier"] in handles]
                        return dict(live=sum(p["live"] for p in pages),background=sum(p["hidden"] for p in pages),
                                    matching=sum(p["url"].startswith(origin+"/") for p in pages))
                    counts=page_counts()
                    discarded=sum(app.call("engine-sleep",tab=h)["discarded"] for h in handles)
                    assert counts == {"live":10,"background":9,"matching":10} and discarded == 0, counts
                    before=call()["refreshCount"]
                    tap("font.Avenir")
                    wait_until(lambda: call()["completedRefreshCount"] > before and all(probe(t)["font"].startswith("Avenir") for t in handles),timeout=5,step=.02)
                    state=call()
                    after=page_counts()
                    return dict(positive=state["refreshPages"] == 10 and state["refreshSkippedPages"] == 0 and state["refreshMs"] < 100 and after == counts,
                                negative=negative,refreshMs=state["refreshMs"],pages=state["refreshPages"],counts=counts,afterCounts=after,discarded=discarded)
                finally:
                    if peer:
                        app.call("window-focus",id=peer,activate=True);app.call("window-close")
                    app.call("window-focus",id=original,activate=True)
                    for extra in tabs[1:]+([other] if other else []): app.call("close",tab=extra)
            row("B12_ten_live_pages",b12)
            def b13():
                close();app.call("command",id="view-boosts")
                wait_until(lambda: app.call("settings-state")["librarySection"] == "boosts",timeout=5,step=.05)
                def shown_text():
                    return [v for w in app.call("windows",accessibility=True) if w["visible"] for v in w.get("text",[])]
                wait_until(lambda: any("Made for 127.0.0.1" in v for v in shown_text()),timeout=5,step=.1)
                text=shown_text()
                negative="Nothing Boosted Yet!" not in text
                return dict(positive=any("My Boost" in v for v in text) and any("Made for 127.0.0.1" in v for v in text),negative=negative,text=text)
            row("B13_library_live",b13)
            def b14():
                nonlocal app,tab
                app.call("library-close");app.call("defaults",key="open.advanced.enableBoosts",value=True);app.quit()
                # A saved user Boost is the persisted input for launch injection.
                files=list(pathlib.Path(app.user_data).glob("Profiles/*/Boosts/boosts.json"))
                source=next(p for p in files if json.loads(p.read_text())["boosts"])
                dto=json.loads(source.read_text());base=dto["boosts"][0]
                base["js"]="window.__boostRuns=(window.__boostRuns||0)+1;"
                specific=copy.deepcopy(base);specific["id"]=str(uuid.uuid4()).upper();specific["name"]="Path Boost"
                specific["siteMatch"]["pathPrefix"]="/docs";specific["css"]="h1{color:rgb(1,2,3)}";specific["js"]="window.__pathRuns=(window.__pathRuns||0)+1;"
                dto["boosts"]=[base,specific];source.write_text(json.dumps(dto))
                folder=pathlib.Path(tmp)/"sitecontrol-fixtures"
                (folder/"docs").mkdir(exist_ok=True)
                (folder/"docs"/"boost.html").write_text((folder/"boost.html").read_text())
                app=factory(urls=(origin+"/docs/boost.html",));tab=app.call("tabs")[0]["id"]
                app.call("navigate",tab=tab,url=origin+"/docs/boost.html");app.call("wait",tab=tab)
                assert app.eval(tab,"({base:window.__boostRuns,path:window.__pathRuns,color:getComputedStyle(document.querySelector('h1')).color})") == {"base":1,"path":1,"color":"rgb(1, 2, 3)"}
                other=new_tab(app,origin+"/boost.html")
                negative=app.eval(other,"({base:window.__boostRuns,path:window.__pathRuns||0})") == {"base":1,"path":0}
                call("open",boost=base["id"]);tap("case")
                assert app.eval(other,"window.__boostRuns") == 1 and app.eval(tab,"window.__boostRuns") == 1
                close()
                unmatched=new_tab(app,origin.replace("127.0.0.1","localhost")+"/boost.html")
                clean=app.eval(unmatched,"typeof window.__openBoosts") == "undefined"
                return dict(positive=clean and app.eval(tab,"window.__pathRuns") == 1,negative=negative,unmatchedRuntimeAbsent=clean)
            row("B14_overlap_js_unmatched",b14)
            def b15():
                target=new_tab(app,origin.replace("127.0.0.1","localhost")+"/boost.html")
                samples={};loads={}
                for enabled in (False,True):
                    app.call("defaults",key="open.advanced.enableBoosts",value=enabled)
                    values=[]
                    for i in range(7):
                        app.call("navigate",tab=target,url=origin.replace("127.0.0.1","localhost")+"/boost.html?sample="+str(i))
                        app.call("wait",tab=target)
                        assert app.eval(target,"typeof window.__openBoosts") == "undefined"
                        values.append(app.eval(target,"performance.getEntriesByType('navigation')[0].domContentLoadedEventEnd"))
                    samples[str(enabled)]=values;loads[str(enabled)]=os.getloadavg()
                return dict(positive=all(v>0 for group in samples.values() for v in group),negative=app.eval(target,"!!document.getElementById('open-boosts-style')") == False,samplesMs=samples,mediansMs={k:statistics.median(v) for k,v in samples.items()},loads=loads)
            row("B15_unmatched_load_measurement",b15)
            def b16():
                app.call("select",tab=tab);app.call("wait",tab=tab);call("open",boost=items()[0]["id"])
                old=app.call("window-state")["id"]
                panel=call()["window"]
                negative=active()
                app.call("command",id="new-window")
                wait_until(lambda: app.call("window-state")["id"] != old,timeout=5,step=.02)
                assert not any(w["number"] == panel and w["visible"] for w in app.call("windows"))
                app.call("window-close");app.call("window-focus",id=old,activate=True)
                call("open",boost=items()[0]["id"])
                space=app.call("space-create",title="Boost scope switch")
                app.call("space",space=space)
                return dict(positive=not active(),negative=negative)
            row("B16_window_space_close",b16)
            def b17():
                other=new_tab(app,origin+"/boost.html");call("open",boost=items()[0]["id"]);ready()
                x,y,w,h=call()["pad"];point=[x+w/2,y+h/2]
                call("drag",points=[point]*2);call("drag",points=[point]*512)
                accepted=call()["open"]
                before=items()
                refused=[]
                for points in ([point],[point]*513,[[x-1,y-1],point]):
                    try:call("drag",points=points)
                    except RuntimeError:refused.append(True)
                try:app.call("boosts",action="list",profile="bad-id")
                except RuntimeError:refused.append(True)
                unchanged=before == items()
                boostID=call()["boost"]["id"]
                def renamed():
                    return next(b for b in items() if b["id"] == boostID)
                original=renamed()["name"]
                tap("menu.Rename this Boost…");call("type",text="x"*16_384);tap("alert.Done")
                atLimit=bool(wait_until(lambda: len(renamed()["name"].encode()) == 16_384,timeout=5,step=.02))
                tap("menu.Rename this Boost…")
                try:call("type",text="x"*16_385)
                except RuntimeError:refused.append(True)
                call("type",text=original);tap("alert.Done")
                wait_until(lambda: renamed()["name"] == original,timeout=5,step=.02)
                return dict(positive=accepted and atLimit and len(refused) == 5,negative=unchanged,acceptedCounts=[2,512],refusedCounts=[1,513],acceptedTextBytes=16_384,refusedTextBytes=16_385)
            row("B17_automation_limits",b17)
            def b18():
                panel=call()["window"]
                previous={s["id"] for s in app.call("little-open-state")["sessions"]}
                app.call("menu-perform",id="new-little-open-window")
                opened=next(s for s in app.call("little-open-state")["sessions"] if s["id"] not in previous)
                sid=opened["id"]
                app.call("key",window=opened["window"],text=origin+"/boost.html?little-open-boost=1\r")
                # A distinct URL keeps the command bar from selecting an
                # existing sidebar tab and closing this Little Open session.
                assert wait_until(lambda: any(s["id"] == sid and s["state"] == "page" and s["content"] and not s["loading"] for s in app.call("little-open-state")["sessions"]),timeout=10,step=.05), app.call("little-open-state")
                # B17's center drag leaves the saved font component intact.
                def heading():
                    return app.call("little-open-eval",id=sid,js="getComputedStyle(document.querySelector('h1')).fontFamily")
                initial=heading()
                app.call("defaults",key="open.advanced.enableBoosts",value=False)
                negative=bool(wait_until(lambda: not heading().startswith("Avenir"),timeout=5,step=.02))
                app.call("defaults",key="open.advanced.enableBoosts",value=True)
                ok=wait_until(lambda: heading().startswith("Avenir"),timeout=5,step=.02)
                editorClosed=not any(w["number"] == panel and w["visible"] for w in app.call("windows"))
                app.call("little-open-action",id=sid,action="close")
                return dict(positive=bool(ok) and initial.startswith("Avenir") and editorClosed,negative=negative)
            row("B18_little_open_live",b18)
            def b21():
                nonlocal tab
                close()
                # Use the broad match only; the earlier /docs Boost must not
                # override the component whose change this row observes.
                app.call("select",tab=tab);app.call("navigate",tab=tab,url=origin+"/boost.html");app.call("wait",tab=tab)
                sleeper=new_tab(app,origin+"/boost.html?discard-wake=1")
                app.call("select",tab=tab);app.call("wait",tab=tab)
                previous=app.call("sleep-clock")["offset"]
                try:
                    app.call("sleep-clock",advance=11)
                    wait_until(lambda: not app.call("sleep-state",tab=sleeper)["tabs"][0]["discardGate"],timeout=5,step=.05)
                    slept=app.call("sleep-now",tab=sleeper)["tab"]
                    assert slept["discarded"] and slept["phase"] == "sleeping", slept
                    engine=app.call("engine-sleep",tab=sleeper)
                    assert engine["discarded"] and engine["live"]
                    call("open",boost=next(b["id"] for b in items() if not b["siteMatch"].get("pathPrefix")))
                    before=call();oldFont=probe(tab)["font"]
                    tap("font.Courier")
                    assert wait_until(lambda: call()["completedRefreshCount"] > before["refreshCount"],timeout=5,step=.02)
                    after=call()
                    still=app.call("engine-sleep",tab=sleeper)
                    noToast=after["applyFailures"] == before["applyFailures"] and not any("Boosts." in t["title"] for t in app.call("toasts")["toasts"])
                    negative=still["discarded"] and still["identifier"] == engine["identifier"] and not oldFont.startswith("Courier")
                    assert after["refreshSkippedPages"] >= 1 and after["deliveryCount"]-before["deliveryCount"] == after["refreshPages"], after
                    close();app.call("select",tab=sleeper);app.call("wait",tab=sleeper)
                    awake=app.eval(sleeper,"({discarded:document.wasDiscarded,font:getComputedStyle(document.querySelector('h1')).fontFamily,atStart:window.styleAtDOMContentLoaded})")
                    state=app.call("sleep-state",tab=sleeper)["tabs"][0]
                    return dict(positive=noToast and awake["discarded"] and awake["font"].startswith("Courier") and awake["atStart"] and state["phase"] == "live" and not state["discarded"],
                                negative=negative,skipped=after["refreshSkippedPages"],delivered=after["refreshPages"],applyFailures=after["applyFailures"]-before["applyFailures"],wake=awake)
                finally:
                    app.call("sleep-clock",reset=True)
                    if previous:app.call("sleep-clock",advance=previous)
                    app.call("select",tab=tab);app.call("close",tab=sleeper)
            row("B21_discard_wake_refresh",b21)
            def b20():
                nonlocal app,tab
                close();app.quit()
                files=list(pathlib.Path(app.user_data).glob("Profiles/*/Boosts/boosts.json"))
                source=next(p for p in files if json.loads(p.read_text())["boosts"])
                dto=json.loads(source.read_text())
                disabled=next(b for b in dto["boosts"] if not b["siteMatch"].get("pathPrefix"))
                disabled["isEnabled"]=False;disabled["name"]="Disabled Boost"
                dto["boosts"]=[disabled];source.write_text(json.dumps(dto))
                app=factory(urls=(origin+"/boost.html",));tab=app.call("tabs")[0]["id"]
                app.call("wait",tab=tab)
                negative=app.eval(tab,"typeof window.__openBoosts") == "undefined"
                app.call("menu-perform",id="edit-boost")
                state=call()
                return dict(positive=state.get("open") and state["boost"]["id"] == disabled["id"] and not state["boost"]["isEnabled"] and len(items()) == 1,
                            negative=negative,storedEnabled=items()[0]["isEnabled"],disabledRuntimeAbsent=negative)
            row("B20_edit_disabled_match",b20)
            def b22():
                boostID=call()["boost"]["id"];original=call()["boost"].get("fontFamily")
                font="Courier" if (original or "").startswith("Avenir") else "Avenir"
                tap("font."+font);expected=call()["boost"]["fontFamily"]
                app.call("command",id="view-boosts")
                app.call("boost-library",action="rename",boost=boostID,name="x"*16_384)
                assert len(call()["boost"]["name"].encode()) == 16_384
                refused=False
                try:app.call("boost-library",action="rename",boost=boostID,name="x"*16_385)
                except RuntimeError:refused=True
                assert refused and len(call()["boost"]["name"].encode()) == 16_384
                app.call("boost-library",action="rename",boost=boostID,name="Library rename")
                app.call("boost-library",action="enabled",boost=boostID,enabled=True)
                synced=call()
                assert synced["open"] and synced["boost"]["name"] == "Library rename" and synced["boost"]["isEnabled"]
                call("key",key="z",modifiers=["cmd"])
                undone=call()["boost"]
                # One editor edit existed; Library changes add no undo step.
                assert not call()["canUndo"]
                call("key",key="z",modifiers=["cmd","shift"])
                redone=call()["boost"]
                tap("case");edited=call()["boost"]
                return dict(positive=undone.get("fontFamily") == original and redone.get("fontFamily") == expected and all(b["name"] == "Library rename" and b["isEnabled"] for b in [undone,redone,edited]),
                            negative=synced["boost"]["name"] != "Disabled Boost" and synced["boost"]["isEnabled"],editorStayedOpen=synced["open"],libraryAddedUndo=False,libraryNameBytesAccepted=16_384,libraryNameBytesRefused=16_385,originalFont=original,expectedFont=expected,
                            undo={k:undone.get(k) for k in ("name","isEnabled","fontFamily")},redo={k:redone.get(k) for k in ("name","isEnabled","fontFamily")})
            row("B22_library_reconcile_undo",b22)
            def b24():
                boostID=call()["boost"]["id"]
                app.call("boost-library",action="rename",boost=boostID,name="Library color rename")
                synced=call();assert synced["open"] and synced["boost"]["name"] == "Library color rename"
                before=synced["boost"].get("colorWheel")
                tap("editor.color.invert");edited=call()["boost"]
                call("key",key="z",modifiers=["cmd"]);undone=call()["boost"]
                call("key",key="z",modifiers=["cmd","shift"]);redone=call()["boost"]
                keptName=all(b["name"] == "Library color rename" for b in (edited,undone,redone))
                app.call("boost-library",action="rename",boost=boostID,name="Library rename")
                return dict(positive=keptName and undone.get("colorWheel") == before and redone.get("colorWheel") == edited.get("colorWheel"),
                            negative=edited.get("colorWheel") != before,editorStayedOpen=synced["open"],
                            undoName=undone["name"],redoName=redone["name"])
            row("B24_library_rename_color_undo",b24)
            def b25():
                boostID=call()["boost"]["id"]
                app.call("boost-library",action="enabled",boost=boostID,enabled=True)
                assert call()["boost"]["isEnabled"]
                app.call("boost-library",action="enabled",boost=boostID,enabled=False)
                synced=call();assert synced["open"] and not synced["boost"]["isEnabled"]
                before=synced["boost"].get("textTransform")
                tap("case");edited=call()["boost"]
                call("key",key="z",modifiers=["cmd"]);undone=call()["boost"]
                call("key",key="z",modifiers=["cmd","shift"]);redone=call()["boost"]
                keptDisabled=all(not b["isEnabled"] for b in (edited,undone,redone))
                app.call("boost-library",action="enabled",boost=boostID,enabled=True)
                return dict(positive=keptDisabled and undone.get("textTransform") == before and redone.get("textTransform") == edited.get("textTransform"),
                            negative=edited.get("textTransform") != before,editorStayedOpen=synced["open"],
                            undoEnabled=undone["isEnabled"],redoEnabled=redone["isEnabled"])
            row("B25_library_disable_edit_undo",b25)
            def b23():
                boostID=call()["boost"]["id"]
                tap("menu.Rename this Boost…");call("type",text="Editor rename");tap("alert.Done")
                app.call("boost-library",action="enabled",boost=boostID,enabled=False)
                call("key",key="z",modifiers=["cmd"]);undone=call()["boost"]
                call("key",key="z",modifiers=["cmd","shift"]);redone=call()["boost"]
                app.call("boost-library",action="delete",boost=boostID)
                return dict(positive=undone["name"] == "Library rename" and redone["name"] == "Editor rename" and not undone["isEnabled"] and not redone["isEnabled"] and not active() and not items(),
                            negative=undone["name"] != redone["name"],libraryDeleteClosedEditor=not active())
            row("B23_editor_rename_library_delete",b23)
            def b19():
                if items():call("open",boost=items()[0]["id"])
                else:call("open");ready();tap("font.Avenir")
                tap("menu.Rename this Boost…")
                caught=False
                try:
                    assert call()["alert"]["title"] == "Rename this Boost"
                    raise RuntimeError("deliberate early failure with rename sheet open")
                except RuntimeError:
                    caught=True
                finally:
                    app.quit()
                return dict(positive=app.quit_report.get("ok") is True,negative=caught,cleanup=app.quit_report)
            row("B19_failure_sheet_cleanup",b19)
            if app and not app.closed:
                app.quit()
            from boost_profile_retirement import run as profile_retirement
            profile_retirement(factory, results, tmp, env)
            from boost_script_update import run as script_update
            script_update(factory, results, tmp, env)
        finally:
            if app and not app.closed:
                try:
                    try:
                        call("close")
                    finally:
                        env["_restore_defaults"](app,saved)
                finally:
                    app.quit()
            elif saved:
                # A relaunch failure must also restore the shared preference keys.
                for key,value in saved.items():
                    cmd=["/usr/bin/defaults", "delete" if value is None else "write", "io.github.sergeserb2.open",key]
                    if value is not None:
                        cmd += ["-bool",str(value).lower()] if isinstance(value,bool) else ["-string",str(value)]
                    subprocess.run(cmd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=value is not None)
