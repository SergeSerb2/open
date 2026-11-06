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
    original_factory=factory
    def factory(**kwargs):
        if os.environ.get("OPEN_BOOST_NEGATIVE_APP"):
            kwargs["extra_env"]={"OPEN_E2E_APP_BUNDLE":os.environ["OPEN_BOOST_NEGATIVE_APP"]}
        return original_factory(**kwargs)
    wait_until, new_tab = env["wait_until"], env["new_tab"]
    app = None
    saved = {}
    keys = {"open.advanced.enableBoosts": True,
            "open.boosts.hasDismissedInterstitial": False,
            "open.boosts.hasDismissedJSNotice": False,
            "open.boosts.codeEditorSize": "480x588",
            "open.library.lastSection": "spaces"}
    def call(action="state", **kw):
        return app.call("boost-editor", action=action, **kw)
    def items():
        return app.call("boosts", action="list")
    def probe(tab):
        return app.eval(tab, "({filter:getComputedStyle(document.documentElement).filter,font:getComputedStyle(document.querySelector('h1')).fontFamily,zoom:getComputedStyle(document.documentElement).zoom,transform:getComputedStyle(document.body).textTransform})")
    def row(name, fn):
        try:
            evidence = fn()
            assert evidence.pop("positive", False), "positive proof failed: " + json.dumps(evidence)
            assert evidence.get("negative") is True, "missing real-flow negative proof"
            results[name] = dict(evidence, ok=True, load=os.getloadavg())
        except Exception as error:
            results[name] = dict(ok=False, error=str(error), trace=traceback.format_exc()[-1400:], load=os.getloadavg())
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
            results["B4_zap"]={"status":"BLOCKED","reason":"P7: isolated world and native page-message channel"}
            results["B5_code"]={"status":"BLOCKED","reason":"code mode (Step 7)"}
            def b6():
                negative=items()[0].get("textTransform") != None
                call("key", key="z", modifiers=["cmd"])
                ok=wait_until(lambda: items()[0].get("textTransform") is None and probe(tab)["transform"] == "none", timeout=5, step=.02)
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
                tabs=[tab]+[new_tab(app,origin+"/boost.html?tab="+str(i),background=True) for i in range(9)]
                app.call("select",tab=tab);call("open",boost=items()[0]["id"])
                app.call("defaults",key="open.advanced.enableBoosts",value=False)
                negative=all(probe(t)["filter"] == "none" for t in tabs)
                app.call("defaults",key="open.advanced.enableBoosts",value=True)
                wait_until(lambda: all("hue-rotate" in probe(t)["filter"] for t in tabs),timeout=5,step=.02)
                before=call()["refreshCount"]
                tap("font.Avenir")
                wait_until(lambda: call()["refreshCount"] > before and all(probe(t)["font"].startswith("Avenir") for t in tabs),timeout=5,step=.02)
                state=call()
                return dict(positive=state["refreshPages"] == 10 and state["refreshMs"] < 100,negative=negative,refreshMs=state["refreshMs"],pages=state["refreshPages"])
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
                app.call("library-close");app.quit()
                # A saved user Boost is the public input while Code mode is blocked.
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
                app.call("select",tab=tab);call("open",boost=items()[0]["id"])
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
                return dict(positive=accepted and len(refused) == 4,negative=before == items(),acceptedCounts=[2,512],refusedCounts=[1,513])
            row("B17_automation_limits",b17)
            def b18():
                panel=call()["window"]
                opened=app.call("little-open-action",action="blank",then="submit",text=origin+"/boost.html")
                sid=opened["after"]["sessions"][0]["id"]
                wait_until(lambda: any(s["id"] == sid and s["content"] and not s["loading"] for s in app.call("little-open-state")["sessions"]),timeout=10,step=.05)
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
