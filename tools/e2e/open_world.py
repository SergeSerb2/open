"""P7 through the real App's OpenWeb automation path and a local page."""
import json
import os
from concurrent.futures import ThreadPoolExecutor
import runpy
from pathlib import Path
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def run(app, results, tmp, new_tab, wait_until):
    class Page(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            body = b'''<!doctype html><html><head><script nonce="p7">
              window.pageAtStart = {native:typeof __openNative, secret:typeof __p7,
                attr:document.documentElement.getAttribute('data-p7')};
              window.handoffAtStart = {
                page:document.documentElement.getAttribute('data-handoff-page'),
                open:document.documentElement.getAttribute('data-handoff-open')};
              window.privateAtStart = {
                page:document.documentElement.getAttribute('data-private-page'),
                open:document.documentElement.getAttribute('data-private-open')};
              </script></head><body>P7 local fixture<iframe src="/child"></iframe></body></html>'''
            if self.path.startswith('/child'):
                body = b'<!doctype html><html><body>child frame</body></html>'
            elif self.path.startswith('/unmatched'):
                body = body.replace(b'</body>', b'<iframe name="__openNative" src="/child"></iframe></body>')
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Security-Policy", "script-src 'nonce-p7'; frame-src 'self'")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    origin = "http://127.0.0.1:" + str(server.server_port)
    tab = other = None
    extension_id = None
    def evaluate(js): return app.call("eval", tab=tab, world="open", js=js)
    def messages(clear=False): return app.call("open-world-messages", tab=tab, clear=clear)
    try:
        # The App prelude preserves the runtime's abstract transport.
        source = '''window.__p7 = 'Open-only';
          window.__open.receive = msg => { window.__p7Received = msg; };
          const mark = () => document.documentElement.setAttribute('data-p7', 'early');
          if (document.documentElement) mark(); else new MutationObserver((m,o)=>{
            if(document.documentElement){o.disconnect();mark()}
          }).observe(document,{childList:true});
          __open.postMessage('p7:ready',{answer:42});'''
        app.call("script-add", id="p7-open", world="open", source=source,
                 matches=["http://127.0.0.1/open*"], allFrames=True, end=True)
        app.call("script-add", id="p7-open-css", world="open", css=True,
                 source="body { outline: 7px solid rgb(17, 34, 51) !important; }",
                 matches=["http://127.0.0.1/open*"])
        # An extension really executes in a separate isolated world.
        fake_root = Path(tmp) / "p7-probe-root"
        extension = fake_root / "tools/e2e/fixtures/action-probe"; extension.mkdir(parents=True)
        (extension / "manifest.json").write_text(json.dumps({
            "manifest_version": 3, "name": "Open P7 isolation probe", "version": "1.0",
            "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["probe.js"],
                                 "run_at": "document_start"}]}))
        (extension / "probe.js").write_text('''const result = JSON.stringify({native:typeof __openNative,secret:typeof __p7,
          extension:typeof chrome !== 'undefined' && !!chrome.runtime && chrome.runtime.id || null});
          const mark=()=>document.documentElement.setAttribute('data-p7-extension',result);
          if(document.documentElement)mark();else new MutationObserver((m,o)=>{
          if(document.documentElement){o.disconnect();mark()}}).observe(document,{childList:true});''')
        pack_probe = runpy.run_path(str(Path(__file__).with_name("extensions_p3.py")))["pack_probe"]
        crx = pack_probe(fake_root, tmp, prefix="p7")
        app.call("ext-prompt", handler=True, clear=True)
        assert app.call("ext-manage", action="install-crx", extension="local", path=crx)
        prompt = wait_until(lambda: (lambda p: p if p.get("pending") else None)(app.call("ext-prompt")), timeout=20)
        assert prompt, "local isolation extension install prompt"
        extension_id = prompt["extension"]
        app.call("ext-prompt", answer="accept")
        assert wait_until(lambda: any(x["id"] == extension_id for x in app.call("extensions")["installed"]), timeout=20)
        tab = new_tab(app, "about:blank")
        app.call("open-world-messages", tab=tab, subscribe=True)
        app.call("navigate", tab=tab, url=origin + "/open")
        app.call("wait", tab=tab, timeout=15)
        page = app.eval(tab, "({start:pageAtStart,secret:typeof __p7,native:typeof __openNative,child:frames[0].document.documentElement.getAttribute('data-p7')})")
        # Page eval keeps its existing user gesture. Let that transient
        # activation expire before checking the Open world's evaluation.
        time.sleep(6)
        isolated = evaluate("({secret:window.__p7 || null,gesture:navigator.userActivation.isActive})")
        ext = wait_until(lambda: app.eval(tab, "document.documentElement.getAttribute('data-p7-extension')"), timeout=10)
        other = new_tab(app, origin + "/unmatched", background=True)
        unmatched = app.call("eval", tab=other, world="open", js="typeof __p7")
        outline = app.eval(tab, "getComputedStyle(document.body).outlineColor")
        other_outline = app.eval(other, "getComputedStyle(document.body).outlineStyle")
        results["open_world_stylesheet"] = {
            "ok": outline == "rgb(17, 34, 51)" and other_outline == "none",
            "matchedOutline": outline, "unmatchedOutline": other_outline}
        app.call("eval", tab=other, world="open", js="__openNative.postMessage('p7:named','{}')")
        named_receipt = app.call("open-world-messages", tab=other)["messages"]
        results["open_world_document_start"] = {
            "ok": page["start"] == {"native": "undefined", "secret": "undefined", "attr": "early"}
                and page["secret"] == page["native"] == "undefined" and page["child"] is None
                and isolated == {"secret": "Open-only", "gesture": False} and unmatched == "undefined"
                and len(named_receipt) == 1 and named_receipt[0]["type"] == "p7:named",
            "page": page, "isolated": isolated, "unmatched": unmatched}
        results["open_world_extension_isolation"] = {
            "ok": json.loads(ext or "{}") == {"native": "undefined", "secret": "undefined", "extension": extension_id},
            "extension": json.loads(ext or "{}")}
        try:
            ready_receipt = messages()
            ready = ready_receipt["messages"]
            # The factory also records whether the Boost picker consumed a
            # message. The transport callback has only the four message fields.
            # This P7 message must remain unhandled by the picker.
            transport_keys = {"content", "type", "payloadJSON", "documentID"}
            message_schema_ok = all(set(m) == transport_keys | {"pickerAccepted"}
                and m["pickerAccepted"] is False for m in ready)
            transport_messages = [{k: m[k] for k in transport_keys} for m in ready]
            first = ready[0] if ready else {}
            evaluate("__open.receive({v:1,type:'p7:reply',payload:{ok:true}})")
            reply = evaluate("__p7Received")
            # Main-world mutations cannot replace the native transport.
            app.eval(tab, "window.__openNative={postMessage(){throw Error('page poison')}}; window.__p7='page-only'")
            evaluate("__open.postMessage('p7:after-poison',{safe:true})")
            poison_messages = [m for m in messages()["messages"] if m["type"] == "p7:after-poison"]
            promise_result = evaluate("Promise.resolve(17)")
            js_error = False
            try: evaluate("throw Error('p7 expected failure')")
            except RuntimeError: js_error = True
            app.call("navigate", tab=tab, url=origin + "/open#same-document")
            same = messages()["messages"][0]["documentID"]
            app.call("navigate", tab=tab, url=origin + "/open-next")
            app.call("wait", tab=tab, timeout=15)
            received = wait_until(lambda: [m for m in messages()["messages"]
                if m["type"] == "p7:ready" and m["documentID"] != first.get("documentID")], timeout=10)
            results["open_world_messages"] = {
                "ok": message_schema_ok and ready_receipt["callbacks"] == transport_messages
                    and len(ready) == 1 and first.get("type") == "p7:ready"
                    and first.get("payloadJSON") == '{"answer":42}' and bool(first.get("documentID"))
                    and same == first["documentID"] and len(received or []) == 1
                    and len(poison_messages) == 1 and poison_messages[0]["payloadJSON"] == '{"safe":true}'
                    and promise_result == 17
                    and reply == {"v": 1, "type": "p7:reply", "payload": {"ok": True}} and js_error,
                "first": first, "callbacks": ready_receipt["callbacks"], "messageSchemaOK": message_schema_ok,
                "nextDocumentID": (received or [{}])[0].get("documentID"),
                "sameDocumentID": same, "reply": reply, "exceptionReported": js_error}
        except Exception as error:
            results["open_world_messages"] = {"ok": False, "error": str(error)}
        time.sleep(1.1)
        before = messages(clear=True)["statistics"]
        evaluate("__openNative.postMessage('x', JSON.stringify('x'.repeat(65533)));"
                 "__openNative.postMessage('x', JSON.stringify('x'.repeat(65534)));"
                 "__openNative.postMessage('x', 'x'.repeat(65537));"
                 "__openNative.postMessage('x', 'é'.repeat(40000));"
                 "__openNative.postMessage('x',{})")
        boundary = messages()["statistics"]
        time.sleep(1.1)
        evaluate("for(let i=0;i<201;i++)__openNative.postMessage('p7:flood','{}')")
        after = messages()["statistics"]
        delta = {k: after[k] - boundary[k] for k in after}
        # Non-JSON values must reply with null, before the 10 s request timeout.
        non_json = {"ok": False}
        started = time.monotonic()
        try:
            value = evaluate("() => 1")
            non_json.update(ok=value is None, result=value)
        except Exception as error:
            non_json["error"] = str(error)
        elapsed = time.monotonic() - started
        results["open_world_non_json_result"] = {
            **non_json, "ok": non_json["ok"] and elapsed < 2,
            "elapsedMS": round(elapsed * 1000, 2), "load": list(os.getloadavg())}
        source_limit = evaluate("17" + " " * (1024 * 1024 - 2)) == 17
        refused_source = refused_result = False
        try: evaluate("17" + " " * (1024 * 1024 - 1))
        except RuntimeError: refused_source = True
        refused_nul = False
        try: evaluate("17\0+1")
        except RuntimeError: refused_nul = True
        result_limit = len(evaluate("'x'.repeat(1048574)")) == 1048574
        try: evaluate("'x'.repeat(1048575)")
        except RuntimeError: refused_result = True
        def unresolved(_):
            try: evaluate("new Promise(()=>{})")
            except RuntimeError as error: return str(error)
            return "unexpected resolution"
        with ThreadPoolExecutor(max_workers=65) as executor:
            pending = list(executor.map(unresolved, range(65)))
        evaluation = {"sourceAtLimit": source_limit, "sourceOverLimit": refused_source,
            "sourceNULRefused": refused_nul,
            "resultAtLimit": result_limit, "resultOverLimit": refused_result,
            "pendingAtLimit": sum("timed out" in x for x in pending),
            "pendingOverLimit": sum("over limit" in x for x in pending)}
        results["open_world_limits"] = {
            "ok": boundary["accepted"] - before["accepted"] == 1
                and boundary["oversized"] - before["oversized"] == 3
                and boundary["invalid"] - before["invalid"] == 1
                and delta["accepted"] == 200 and delta["rateLimited"] == 1
                and source_limit and refused_source and refused_nul and result_limit and refused_result
                and evaluation["pendingAtLimit"] == 64 and evaluation["pendingOverLimit"] == 1,
            "sizeBoundary": {k: boundary[k] - before[k] for k in before}, "flood": delta,
            "evaluation": evaluation}
        try:
            # |other| already exists: later scripts must also reach a new process.
            before_processes = app.call("metrics", interval=0)["processes"]
            for world in ("page", "open"):
                source = """(() => {
                  const mark = () => document.documentElement.setAttribute('data-handoff-%s', 'early');
                  if (document.documentElement) mark(); else new MutationObserver((m,o)=>{
                    if(document.documentElement){o.disconnect();mark()}
                  }).observe(document,{childList:true});
                })()""" % world
                app.call("script-add", id="p7-handoff-" + world, world=world,
                         source=source, matches=["http://*/*"])
            observations = []
            for host in ("localhost", "127.0.0.1"):
                app.call("navigate", tab=other,
                         url="http://%s:%d/handoff" % (host, server.server_port))
                app.call("wait", tab=other, timeout=15)
                observations.append(app.eval(other, "handoffAtStart"))
                if host == "localhost":
                    swapped_processes = app.call("metrics", interval=0)["processes"]
            before_ids = {p["pid"] for p in before_processes}
            new_renderers = [p for p in swapped_processes
                             if p["pid"] not in before_ids and "(Re" in p["name"]]
            results["open_world_replacement_renderer"] = {
                "ok": bool(new_renderers) and observations == [{"page": "early", "open": "early"}] * 2,
                "atDocumentStart": observations, "newRenderers": new_renderers,
                "processesBefore": before_processes, "processesAfterSwap": swapped_processes}
        except Exception as error:
            results["open_world_replacement_renderer"] = {"ok": False, "error": str(error)}
        runpy.run_path(str(Path(__file__).with_name("open_world_private.py")))["run"](
            app, results, new_tab, wait_until, server.server_port, other)
    finally:
        app.call("script-remove", id="p7-handoff-page")
        app.call("script-remove", id="p7-handoff-open")
        app.call("script-remove", id="p7-open")
        app.call("script-remove", id="p7-open-css")
        if extension_id:
            app.call("ext-manage", action="uninstall", extension=extension_id)
            pending = wait_until(lambda: app.call("ext-prompt").get("pending"), timeout=5)
            if pending: app.call("ext-prompt", answer="accept")
        app.call("ext-prompt", handler=False, clear=True)
        if other: app.call("close", tab=other)
        if tab:
            app.call("open-world-messages", tab=tab, subscribe=False)
            app.call("close", tab=tab)
        server.shutdown(); server.server_close(); worker.join(timeout=2)
