"""P3 through the real Release app, local signed CRX3 and Chromium consent.

No network is needed. CRX packaging uses openssl and Python's zip/protobuf
encoding. Chromium verifies the signature and owns every install operation.
"""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import time
import zipfile
import zlib


def pack_probe(root, tmp, prefix="probe", icon_png=None, name=None):
    folder = Path(tmp) / (prefix + "-packed")
    shutil.copytree(Path(root) / "tools/e2e/fixtures/action-probe", folder, dirs_exist_ok=True)
    manifest = json.loads((folder / "manifest.json").read_text())
    if name is not None:
        manifest["name"] = name
    if icon_png is not None:
        manifest["name"] = "Open icon boundary " + prefix
        manifest["icons"] = {"128": "boundary.png"}
        manifest.pop("commands", None)
        manifest.pop("omnibox", None)
        # The boundary fixture exercises metadata icons, not background events.
        manifest.pop("background", None)
        (folder / "boundary.png").write_bytes(icon_png)
    manifest.pop("key", None)  # This run has its own signing key and extension id.
    (folder / "manifest.json").write_text(json.dumps(manifest))
    private, public = Path(tmp) / (prefix + ".pem"), Path(tmp) / (prefix + ".der")
    subprocess.run(["openssl", "genrsa", "-out", str(private), "2048"], check=True, capture_output=True)
    subprocess.run(["openssl", "rsa", "-in", str(private), "-pubout", "-outform", "DER", "-out", str(public)],
                   check=True, capture_output=True)
    archive = Path(tmp) / (prefix + ".zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for file in sorted(folder.rglob("*")):
            if file.is_file(): z.write(file, file.relative_to(folder))
    def varint(n):
        out = bytearray()
        while n >= 128: out.append((n & 127) | 128); n >>= 7
        out.append(n)
        return bytes(out)
    def field(n, data): return varint((n << 3) | 2) + varint(len(data)) + data
    key = public.read_bytes()
    signed = field(1, hashlib.sha256(key).digest()[:16])
    payload = Path(tmp) / (prefix + "-signature-input")
    payload.write_bytes(b"CRX3 SignedData\x00" + struct.pack("<I", len(signed)) + signed + archive.read_bytes())
    signature = Path(tmp) / (prefix + "-signature")
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private), "-out", str(signature), str(payload)],
                   check=True, capture_output=True)
    header = field(2, field(1, key) + field(2, signature.read_bytes())) + field(10000, signed)
    crx = Path(tmp) / (prefix + ".crx")
    crx.write_bytes(b"Cr24" + struct.pack("<II", 3, len(header)) + header + archive.read_bytes())
    return str(crx)


def run(app, results, tmp, root, wait_until, new_tab):
    crx = pack_probe(root, tmp)
    pending = lambda: (lambda p: p if p.get("pending") else None)(app.call("ext-prompt"))
    listed = lambda: app.call("extensions")["installed"]
    actions = lambda: app.call("actions")["actions"]
    def install():
        assert app.call("ext-manage", action="install-crx", extension="local", path=crx)
        return wait_until(pending, timeout=20)
    def installed(identifier): return next((x for x in listed() if x["id"] == identifier), None)
    def open_popup(identifier):
        app.call("ext-run", extension=identifier)
        def ready():
            p = app.call("ext-popup")
            if p.get("open") and p["page"]["live"]:
                try:
                    # The new popup first has a complete about:blank document.
                    # Wait for its extension document and API bindings, including
                    # after closing the last hosted tab and creating a browser.
                    if app.eval(p["page"]["identifier"],
                        "location.protocol === 'chrome-extension:' && "
                        "location.hostname === " + json.dumps(identifier) + " && "
                        "document.readyState === 'complete' && "
                        "typeof chrome.permissions?.request === 'function'"):
                        return p
                except RuntimeError: pass
        return wait_until(ready, timeout=15)
    def close_popup():
        app.call("popup-close")
        return wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10)
    try:
        app.call("ext-prompt", handler=True, clear=True)
        ready = wait_until(lambda: app.call("ext-commands").get("ready"), timeout=20)
        results["registry_ready"] = {"ok": bool(ready)}
        first = install()
        if not first:
            results["X1_local_install_prompt"] = {"ok": False, "reason": "no prompt for real signed CRX"}
            return
        identifier = first["extension"]
        app.call("ext-prompt", answer="cancel", twice=True)
        cancelled = wait_until(lambda: not pending(), timeout=5) and not installed(identifier)
        dropped = install()
        app.call("ext-prompt", hold=False)
        released = wait_until(lambda: not pending(), timeout=5) and not installed(identifier)
        final = install()
        answer = "accept"
        before_windows = {w["number"] for w in app.call("windows")}
        answer_receipt = app.call("ext-prompt", answer=answer, twice=True)
        accepted = wait_until(lambda: installed(identifier), timeout=20)
        extra_dialogs = [w["class"] for w in app.call("windows")
                         if w["number"] not in before_windows and w["visible"] and w["class"].startswith("NativeWidget")]
        results["X1_local_install_prompt"] = {
            "ok": bool(cancelled and dropped and released and final and accepted)
                  and first["type"] == "install" and first["title"] == "Add Open action probe extension to Open?"
                  and first["buttons"] == ["Cancel", "Add Extension"] and not extra_dialogs,
            "prompt": first, "cancelled": bool(cancelled), "release_cancelled": bool(released),
            "installed": bool(accepted), "answer": answer_receipt, "native_dialogs": extra_dialogs, "source": "local signed CRX3 -> CrxInstaller"}
        if not accepted: return
        metadata = installed(identifier)
        results["live_metadata"] = {"ok": metadata.get("hasAction") is True and metadata.get("omniboxKeyword") == "probe"
                                     and metadata.get("fromWebStore") is False and metadata["disableReasons"] == 0,
                                    "extension": metadata}
        events = wait_until(lambda: (lambda es: es if any(e.get("event") == "installed" and e.get("id") == identifier
            and e.get("byUser") is True for e in es) else None)(app.call("ext-prompt")["events"]), timeout=10) or []
        results["registry_delegate_events"] = {"ok": {"ready", "changed", "commands", "installed"} <= {e.get("event") for e in events},
                                               "events": events}
        command_list = wait_until(lambda: (lambda cs: cs if len([c for c in cs if c["extension"] == identifier]) == 2 else None)(
            app.call("ext-commands")["commands"]), timeout=10) or []
        own = {c["name"]: c for c in command_list if c["extension"] == identifier}
        # Cocoa uses an uppercase key equivalent to encode Shift, and drops
        # Shift from the modifier mask (platform_accelerator_cocoa.mm).
        want_modifiers = 1 << 20
        keys_ok = set(own) == {"_execute_action", "probe-named"} and all(
            own[name]["keyEquivalent"] == key.upper() and own[name]["modifierFlags"] == want_modifiers
            and own[name]["actionCommand"] == (name == "_execute_action") and not own[name]["global"]
            for name, key in (("_execute_action", "y"), ("probe-named", "u")))
        snapshot = next((x for x in actions() if x["id"] == identifier), {})
        results["commands_list_and_action_keys"] = {"ok": keys_ok and snapshot.get("shortcutKeyEquivalent", "").lower() == "y"
            and snapshot.get("shortcutModifierFlags") == want_modifiers, "commands": list(own.values()),
            "actionKey": snapshot.get("shortcutKeyEquivalent"), "actionModifiers": snapshot.get("shortcutModifierFlags")}
        pop = open_popup(identifier)
        page = pop["page"]["identifier"] if pop else 0
        if not page:
            results["popup_open"] = {"ok": False}
            return
        tab = app.eval(page, "chrome.tabs.query({active:true,currentWindow:true}).then(ts=>ts[0].id)")
        app.eval(page, "chrome.storage.session.set({commands:[]}).then(()=>true)")
        named = app.call("ext-run-command", extension=identifier, name="probe-named")
        state = wait_until(lambda: (lambda s: s if s.get("commands") == ["probe-named"] else None)(
            app.eval(page, "chrome.storage.session.get(['commands','lastCommandTab'])")), timeout=10)
        close_popup()
        action_ran = app.call("ext-run-command", extension=identifier, name="_execute_action")
        from_command = wait_until(lambda: (lambda p: p if p.get("open") and p.get("source") == "command" else None)(
            app.call("ext-popup")), timeout=10)
        unknown_refused = app.call("ext-run-command", extension=identifier, name="missing") is False
        results["commands_execute"] = {"ok": bool(named and state and state.get("lastCommandTab") == tab and action_ran and from_command and unknown_refused),
                                       "named": state, "actionSource": from_command and from_command["source"],
                                       "unknownRefused": unknown_refused}
        close_popup()
        kept_menu = app.call("ext-menu", extension=identifier, keep=True)
        menu_title = next(x["title"] for x in kept_menu if x["title"] in ("Pin", "Unpin"))
        for item in app.call("tabs"): app.call("close", tab=item["id"])
        idle = wait_until(lambda: not app.call("actions")["ready"], timeout=10)
        new_tab(app, "about:blank")
        live = wait_until(lambda: app.call("actions")["ready"], timeout=10)
        stale = app.call("ext-menu", extension=identifier, select=menu_title, stale=True)
        results["stale_menu_generation_refused"] = {"ok": bool(idle and live) and stale.get("ran") is False,
                                                   "ran": stale.get("ran")}
        permission_rows = []
        for answer in ("cancel", "accept"):
            pop = open_popup(identifier)
            page = pop["page"]["identifier"]
            app.eval(page, "window.permissionResult='pending'; chrome.permissions.request({permissions:['downloads']})"
                          ".then(value=>window.permissionResult=value, error=>window.permissionResult=String(error)); true")
            prompt = wait_until(pending, timeout=10)
            if prompt: app.call("ext-prompt", answer=answer)
            value = wait_until(lambda: (lambda value: {'value':value} if value != 'pending' else None)(
                app.eval(page, "window.permissionResult")), timeout=10)
            permission_rows.append({"prompt": prompt, "value": value and value["value"],
                "ok": bool(prompt) and prompt["type"] == "permissions" and prompt["buttons"] == ["Deny", "Allow"]
                      and prompt["title"] == "The extension Open action probe has requested additional permissions"
                      and bool(prompt["permissionLines"]) and value is not None and value["value"] == (answer == "accept")})
            close_popup()
        results["X14_permissions_deny_allow"] = {"ok": all(x["ok"] for x in permission_rows), "rows": permission_rows}
        pop = open_popup(identifier)
        app.call("ext-manage", extension=identifier, action="disable")
        disabled = wait_until(lambda: (lambda e: e if e and not e["enabled"] else None)(installed(identifier)), timeout=10)
        closed = wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10)
        action_gone = not [x for x in actions() if x["id"] == identifier]
        app.call("ext-manage", extension=identifier, action="enable")
        enabled = wait_until(lambda: (lambda e: e if e and e["enabled"] else None)(installed(identifier)), timeout=10)
        action_back = wait_until(lambda: [x for x in actions() if x["id"] == identifier], timeout=10)
        results["disable_enable_with_popup"] = {"ok": bool(pop and disabled and closed and action_gone and enabled and action_back),
                                               "disabled": disabled, "popupClosed": bool(closed), "actionGone": action_gone}
        app.call("ext-manage", extension=identifier, action="reload")
        reloaded = wait_until(lambda: [x for x in actions() if x["id"] == identifier], timeout=15)
        results["management_reload"] = {"ok": bool(reloaded)}
        # Both the menu entry and manager uninstall must go through consent.
        menu = app.call("ext-menu", extension=identifier)
        remove = next((x["title"] for x in menu if x["title"].startswith("Remove from")), None)
        if remove: app.call("ext-menu", extension=identifier, select=remove)
        prompt = wait_until(pending, timeout=10)
        if prompt: app.call("ext-prompt", answer="cancel")
        kept = installed(identifier) is not None
        pop = open_popup(identifier)
        app.call("ext-manage", extension=identifier, action="uninstall")
        confirm = wait_until(pending, timeout=10)
        if confirm: app.call("ext-prompt", answer="accept", twice=True)
        removed = wait_until(lambda: installed(identifier) is None and not [x for x in actions() if x["id"] == identifier], timeout=10)
        closed = wait_until(lambda: not app.call("ext-popup").get("open"), timeout=10)
        results["X15_uninstall_cancel_accept_with_popup"] = {
            "ok": bool(remove and prompt and kept and pop and confirm and removed and closed)
                  and confirm["type"] == "uninstall" and confirm["title"] == "Remove Open action probe extension from Open?"
                  and confirm["buttons"] == ["Cancel", "Remove Extension"],
            "cancelKept": kept, "prompt": confirm, "removed": bool(removed), "popupClosed": bool(closed),
            "alive": app.call("ping") is not None}
        # Real install -> live metadata at/over both icon decoder limits.
        def png(width, height, encoded_size=None, depth=8):
            def chunk(kind, data):
                return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
            body = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, 6, 0, 0, 0))
            body += chunk(b"IDAT", zlib.compress((b"\0" + b"\xff" * (width * 4 * (depth // 8))) * height))
            end = chunk(b"IEND", b"")
            if encoded_size:
                body += chunk(b"tEXt", b"padding\0" + b"x" * (encoded_size - len(body) - len(end) - 20))
            return body + end
        boundary_rows = []
        for label, width, height, encoded_size, depth, expected_icon in (
            ("dimensions-at", 2048, 2048, None, 8, "2048x2048"),
            ("dimensions-over", 2049, 2048, None, 8, ""),
            ("bytes-at", 128, 128, 4 * 1024 * 1024, 8, "128x128"),
            ("bytes-over", 128, 128, 4 * 1024 * 1024 + 1, 8, ""),
            ("depth-over", 128, 128, None, 16, "")):
            image = png(width, height, encoded_size, depth)
            if encoded_size: assert len(image) == encoded_size
            # Chromium sanitizes and re-encodes icons while installing. Install
            # a small valid icon first, then edit only this run's fixture copy.
            path = pack_probe(root, tmp, label, png(128, 128))
            app.call("ext-manage", action="install-crx", extension="local", path=path)
            request = wait_until(pending, timeout=20)
            if request: app.call("ext-prompt", answer="accept")
            record = wait_until(lambda: installed(request["extension"]), timeout=20) if request else None
            if record:
                icon_path = Path(record["directory"]) / "boundary.png"
                icon_path.resolve().relative_to(Path(app.user_data).resolve())
                icon_path.write_bytes(image)
                app.call("extensions", refresh=True)
                record = installed(request["extension"])
            boundary_rows.append({"case": label, "encodedBytes": len(image), "pixels": [width, height],
                "icon": record and record["icon"], "ok": bool(record) and record["icon"] == expected_icon})
            if record:
                app.call("ext-manage", action="uninstall", extension=record["id"])
                if wait_until(pending, timeout=10): app.call("ext-prompt", answer="accept")
                wait_until(lambda: installed(record["id"]) is None, timeout=10)
        results["metadata_icon_limits"] = {"ok": all(x["ok"] for x in boundary_rows), "rows": boundary_rows}
        # A new profile gets a separate registry and the same prompt hooks.
        original_space = next(x["id"] for x in app.call("spaces") if x["focused"])
        app.call("space-create", title="P3 profile", profile="P3 profile")
        new_tab(app, "about:blank")
        wait_until(lambda: app.call("ext-commands").get("ready"), timeout=20)
        second = install()
        if second: app.call("ext-prompt", answer="accept")
        second_installed = wait_until(lambda: installed(identifier), timeout=20)
        app.call("space", space=original_space)
        isolated = installed(identifier) is None
        results["non_default_profile"] = {"ok": bool(second and second_installed and isolated),
                                          "installedInSecond": bool(second_installed), "absentInDefault": isolated}
        # With no handler, keep the platform install prompt and install path.
        app.call("ext-prompt", handler=False)
        before = {w["number"] for w in app.call("windows")}
        app.call("ext-manage", action="install-crx", extension="local", path=crx)
        native = wait_until(lambda: [w for w in app.call("windows", accessibility=True)
            if w["number"] not in before and w["visible"] and w["class"].startswith("NativeWidget")
            and "Open action probe" in ' '.join([w["title"]] + w.get("text", []))], timeout=15)
        if native:
            # Chromium deliberately disables Add for its first 500 ms
            # (extension_install_dialog_view.cc:g_install_delay_in_ms).
            # This row checks fallback installation, not the timer deadline.
            time.sleep(1)
            # Establish the exact-PID native focus precondition through a
            # real in-process key route, then click the native accept button.
            app.call("key", key="tab", window=native[0]["number"], route="app")
            # This is the app's in-process mouse event helper, never desktop input.
            values = [float(x) for x in native[0]["frame"].replace('{','').replace('}','').split(',')]
            app.call("mouse", action="click", window=native[0]["number"], x=values[2]-81, y=values[3]-38)
        fallback = wait_until(lambda: installed(identifier), timeout=15)
        results["fallback_native_dialog_installs"] = {"ok": bool(native and fallback),
                                                      "native": native, "installed": bool(fallback)}
    finally:
        try: app.call("ext-prompt", clear=True, handler=False)
        finally: app.cleanup_surfaces()
