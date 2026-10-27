#!/usr/bin/env python3 -I
"""Exercise Settings → Previews in a real, isolated Open.app.

Build first. Hold both M1 validation and on-screen locks for each invocation.
--force-failure deliberately exits 1 with the sheet open, then proves cleanup.
Only the app's existing automation socket delivers input and captures pixels.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from engine_e2e import Open, ROOT, frame


def wait_for(read, predicate, message):
    deadline = time.monotonic() + 10
    while True:
        value = read()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise RuntimeError(message + ": " + repr(value))
        time.sleep(.05)


def owned_processes(bundle):
    rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    return [int(parts[0]) for row in rows.splitlines()
            if len(parts := row.strip().split(None, 1)) == 2 and parts[1].startswith(str(bundle) + "/")]


def visible_windows(pids):
    """Read window-server ownership only; never capture or act on other apps."""
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    pointer = ctypes.c_void_p
    cf.CFArrayGetCount.argtypes = [pointer]
    cf.CFArrayGetCount.restype = ctypes.c_long
    cf.CFArrayGetValueAtIndex.argtypes = [pointer, ctypes.c_long]
    cf.CFArrayGetValueAtIndex.restype = pointer
    cf.CFDictionaryGetValue.argtypes = [pointer, pointer]
    cf.CFDictionaryGetValue.restype = pointer
    cf.CFNumberGetValue.argtypes = [pointer, ctypes.c_int, pointer]
    cf.CFRelease.argtypes = [pointer]
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGWindowListCopyWindowInfo.restype = pointer
    windows = cg.CGWindowListCopyWindowInfo(17, 0)  # on-screen, exclude desktop
    result = []
    try:
        for index in range(cf.CFArrayGetCount(windows)):
            row = cf.CFArrayGetValueAtIndex(windows, index)
            def number(name):
                key = pointer.in_dll(cg, name)
                value = cf.CFDictionaryGetValue(row, key)
                out = ctypes.c_int32()
                if value:
                    cf.CFNumberGetValue(value, 3, ctypes.byref(out))
                return out.value
            pid = number("kCGWindowOwnerPID")
            if pid in pids:
                result.append({"pid": pid, "number": number("kCGWindowNumber")})
    finally:
        cf.CFRelease(windows)
    return result


def run(config, output, force_failure):
    output.mkdir(parents=True, exist_ok=False)
    scratch = Path(tempfile.mkdtemp(prefix="open-previews-"))
    name = "Open-E2E-previews-" + uuid.uuid4().hex[:16]
    domain = "com.open.previews-e2e." + uuid.uuid4().hex
    data = Path.home() / "Library/Application Support" / name
    cache = Path.home() / "Library/Caches" / name
    bundle = scratch / "Open.app"
    report = {"domain": domain, "data": str(data), "cache": str(cache), "forcedFailure": force_failure}
    app = None
    owned = set()
    cleanup_errors = []
    try:
        # A unique bundle ID gives UserDefaults.standard a fresh domain without
        # adding a preferences hook to the App or touching the user's choices.
        subprocess.run(["cp", "-cR", str(Path(ROOT) / "build" / config / "Open.app"), str(bundle)], check=True)
        info = bundle / "Contents/Info.plist"
        values = plistlib.loads(info.read_bytes())
        values["CFBundleIdentifier"] = domain
        info.write_bytes(plistlib.dumps(values))
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True, capture_output=True)
        subprocess.run(["defaults", "write", domain, "open.general.previewsDelaySeconds", "-float", "7"], check=True)
        app = Open(str(scratch), "chrome", str(data), ["--use-mock-keychain"], str(output / "app.log"))
        print("App ready; opening General Settings", flush=True)
        report["pid"] = app.pid
        report["ping"] = app.call("ping")
        app.call("menu-perform", id="settings")
        settings = wait_for(lambda: app.call("windows"),
                            lambda rows: any(w["visible"] and w["title"] == "General" for w in rows),
                            "General Settings did not open")
        parent = next(w for w in settings if w["visible"] and w["title"] == "General")
        app.call("snapshot", window=parent["number"], path=str(output / "general.png"))
        # Coordinates are in Open's window, at the existing General button.
        app.call("mouse", window=parent["number"], action="click", x=540, y=273)
        rows = wait_for(lambda: app.call("windows"),
                        lambda rows: any(w["number"] == parent["number"] and w["attachedSheet"] for w in rows),
                        "Previews sheet did not attach to General")
        sheet_id = next(w["attachedSheet"] for w in rows if w["number"] == parent["number"])
        sheet = next(w for w in rows if w["number"] == sheet_id)
        report["sheet"] = sheet
        print("Real Previews sheet attached: " + json.dumps(sheet), flush=True)
        assert sheet["visible"] and sheet["sheet"] and frame(sheet["frame"])[2:] == [480, 320], sheet
        if force_failure:
            raise RuntimeError("FORCED: early failure while the real Previews sheet is open")
        app.call("mouse", window=sheet_id, action="hover", x=240, y=220)
        report["rest"] = app.call("snapshot", window=sheet_id, path=str(output / "previews-rest@2x.png"))
        app.call("mouse", window=sheet_id, action="hover", x=426, y=284)
        report["hover"] = app.call("snapshot", window=sheet_id, path=str(output / "previews-hover@2x.png"))
        for image in ("previews-rest@2x.png", "previews-hover@2x.png"):
            assert struct.unpack(">II", (output / image).read_bytes()[16:24]) == (960, 640), "expected native 2x snapshot"
        print("Saved real-window rest and hover snapshots", flush=True)
        def preferences():
            raw = subprocess.check_output(["defaults", "export", domain, "-"])
            return plistlib.loads(raw)
        def click_switch(y, key, expected):
            app.call("mouse", window=sheet_id, action="click", x=438, y=y)
            return wait_for(preferences, lambda values: values.get(key) is expected, "switch did not persist " + key)
        click_switch(69, "open.general.previewsEnabled", False)
        app.call("mouse", window=sheet_id, action="click", x=438, y=101)
        assert "open.general.previewsFolders" not in preferences(), "disabled source accepted input"
        click_switch(69, "open.general.previewsEnabled", True)
        click_switch(101, "open.general.previewsFolders", False)
        report["preferences"] = click_switch(133, "open.general.previewsPages", False)
        assert report["preferences"]["open.general.previewsDelaySeconds"] == 7, "stored delay was changed or removed"
        app.call("mouse", window=sheet_id, action="click", x=426, y=284)
        wait_for(lambda: app.call("windows"), lambda rows: not any(w["visible"] and w["sheet"] for w in rows), "Done left a sheet")
        report["flow"] = "PASS: General → Previews, three switches, disabled source, persisted choices, Done; stored delay retained"
    except Exception as error:
        report["error"] = str(error)
    finally:
        if app:
            owned.update(owned_processes(bundle))
            owned.add(app.pid)
            try:
                rows = app.call("windows")
                report["cleanupBefore"] = rows
                # Done is the normal response, even on the forced-failure path.
                for sheet in rows:
                    if sheet["visible"] and sheet["sheet"]:
                        app.call("mouse", window=sheet["number"], action="click", x=426, y=284)
                app.call("dismiss")  # also cancel any unexpected native alert
                report["cleanupAfter"] = wait_for(lambda: app.call("windows"),
                    lambda rows: not any(w["visible"] and w["sheet"] for w in rows), "dialog left after cleanup")
            except Exception as error:
                cleanup_errors.append(str(error))
            finally:
                try:
                    app.quit()
                    report["quit"] = app.quit_report
                    if app.quit_report.get("forced"):
                        cleanup_errors.append("App required forced termination")
                except Exception as error:
                    cleanup_errors.append("quit: " + str(error))
        # Also cover a launch timeout before Open.__init__ returns an object.
        remaining = owned_processes(bundle)
        owned.update(remaining)
        for pid in remaining:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if remaining:
            cleanup_errors.append("suite-owned processes survived quit: " + repr(remaining))
        try:
            report["remainingWindows"] = wait_for(lambda: visible_windows(owned), lambda rows: not rows, "suite-owned window left")
        except Exception as error:
            cleanup_errors.append(str(error))
        report["remainingProcesses"] = owned_processes(bundle)
        subprocess.run(["defaults", "delete", domain], capture_output=True)
        for folder in (data, cache, scratch):
            shutil.rmtree(folder, ignore_errors=True)
        report["rootsRemoved"] = all(not folder.exists() for folder in (data, cache, scratch))
        if not report["rootsRemoved"]:
            cleanup_errors.append("suite-owned data, cache or bundle directory left")
        report["cleanupErrors"] = cleanup_errors
        report["cleanup"] = "PASS" if not cleanup_errors and not report["remainingProcesses"] else "FAIL"
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2), flush=True)
    return 0 if "error" not in report and report["cleanup"] == "PASS" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="Debug")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--force-failure", action="store_true")
    args = parser.parse_args()
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(143))
    sys.exit(run(args.config, args.out.resolve(), args.force_failure))
