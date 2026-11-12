#!/usr/bin/env python3
"""Replace the current display key's legacy and editor P1 PNGs with renders of this head.

Only for a lead-approved intentional render change (D2, LEAD 2026-11-12 02:10: sidebar
colour roles follow Arc 1.172.2). Run in a heavy slot after a release build of
openkit, sidebar-render and space-editor-render. It uses the gates' own render paths:
check.py `legacy_space_fixture` (legacy) and space-editor-render P1 `persistence` (editor),
then rewrites the PNGs and the manifest digests for this display key only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "Packages/OpenKit/Sources/space-editor-render/Resources/space-schema1"
BIN = ROOT / "Packages/OpenKit/.build/release"


def run(*args, env=None):
    return subprocess.check_output([str(a) for a in args], timeout=600, env=env, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reason", required=True)
    args = parser.parse_args()
    if run("git", "status", "--porcelain", "--", "Packages/OpenKit").strip():
        raise ValueError("commit package sources first: the manifest records this head")
    head = run("git", "rev-parse", "HEAD").strip()
    portability = runpy.run_path(str(Path(__file__).with_name("portable-baselines.py")))
    environment = portability["display_environment"]()
    manifest_path = RES / "portable/manifest.json"
    manifest = portability["read_manifest"](manifest_path)
    entry = manifest["environments"].get(environment["key"])
    if entry is None:
        raise ValueError("no reference for this display key; use record-legacy-baselines.py for a new key")
    scale = entry["renderScale"]
    if entry.get("original"):
        targets = {"legacy": ROOT / "Packages/OpenKit/Fixtures/space-schema1", "editor": RES}
    else:
        asset = RES / "portable" / entry.get("assetKey", environment["key"])
        targets = {"legacy": asset / "legacy", "editor": asset / "editor"}
    with tempfile.TemporaryDirectory(prefix="open-p1-rerecord-") as temporary:
        temporary = Path(temporary)
        fixture = temporary / "legacy-space"
        shutil.copytree(ROOT / "Packages/OpenKit/Fixtures/space-schema1", fixture)
        run(BIN / "openkit", "roundtrip", fixture)
        renders = {"legacy": temporary / "legacy", "editor": temporary / "editor"}
        for directory in renders.values():
            directory.mkdir()
        env = dict(os.environ, OPEN_VERIFY_DISPLAY_KEY=environment["key"])
        for space in range(3):
            run(BIN / "sidebar-render", "render", "--snapshot", fixture, "--space", space, "--size", "900x700",
                "--scale", scale, "--out", renders["legacy"] / f"window-{space}.png", env=env)
        # The P1 check fails its byte rows here (old references); it still writes its renders.
        subprocess.run([str(BIN / "space-editor-render"), "check"], timeout=1200, capture_output=True,
                       env=dict(os.environ, OPEN_P1_RECORD_DIR=str(renders["editor"])))
        digests = {}
        for kind, directory in renders.items():
            digests[kind] = {}
            for space in range(3):
                name = f"window-{space}.png"
                data = (directory / name).read_bytes()
                (targets[kind] / name).write_bytes(data)
                digests[kind][name] = hashlib.sha256(data).hexdigest()
                print(kind, name, digests[kind][name])
    entry["pngSHA256"] = digests
    entry["trustedMainCommit"] = head
    entry["rerecord"] = {"commit": head, "reason": args.reason,
                         "binarySHA256": {n: hashlib.sha256((BIN / n).read_bytes()).hexdigest()
                                          for n in ("openkit", "sidebar-render", "space-editor-render")}}
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print("re-recorded", environment["key"], "from", head)


if __name__ == "__main__":
    main()
