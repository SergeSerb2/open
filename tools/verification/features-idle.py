#!/usr/bin/env python3
"""Run the real feature flow with a harness-only dyld/Objective-C observer."""
import os
import pathlib
import signal
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="open-feature-idle-") as scratch:
    probe = pathlib.Path(scratch) / "idle-probe.dylib"
    subprocess.run(["xcrun", "clang", "-dynamiclib", "-fblocks", "-fobjc-arc", "-Wno-deprecated-declarations",
                    str(ROOT / "tools/verification/feature-idle-probe.m"),
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "CoreVideo",
                    "-o", str(probe)], check=True, timeout=30)
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(probe))
    binary = ROOT / "Packages/OpenKit/.build/release/features-render"
    # Bound a broken gate and reap only the child this invocation owns.
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    child = subprocess.Popen([str(binary), "check", "--only", "idle"], env=env)
    try:
        try:
            status = child.wait(timeout=90)
        except subprocess.TimeoutExpired:
            print("FAIL S8 idle observer: flow exceeded 90 s", flush=True)
            status = 1
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
    sys.exit(status)
