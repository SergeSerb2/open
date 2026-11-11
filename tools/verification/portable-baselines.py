#!/usr/bin/env python3
"""Display identity and strict legacy PNG selection. No recording in normal runs."""
import hashlib
import json
from pathlib import Path
import re
import subprocess


def read_manifest(path):
    if path.stat().st_size > 1_048_576:
        raise ValueError("oversized portable baseline metadata")
    value = json.loads(path.read_text())
    if (set(value) != {"schemaVersion", "environments"} or value["schemaVersion"] != 3
            or not isinstance(value["environments"], dict) or len(value["environments"]) > 16
            or any(not re.fullmatch(r"scale-[12]-icc-header-v1-[0-9a-f]{64}-mode-[0-9]{1,5}x[0-9]{1,5}-pixels-[0-9]{1,5}x[0-9]{1,5}-mhz-[0-9]{1,7}", key)
                   for key in value["environments"])):
        raise ValueError("invalid portable baseline manifest")
    return value


def display_environment():
    result = subprocess.run(["/usr/bin/swift", str(Path(__file__).with_name("display-environment.swift"))],
                            capture_output=True, text=True, check=True, timeout=60)
    if len(result.stdout) > 2048:
        raise ValueError("oversized display metadata")
    value = json.loads(result.stdout)
    mode = value.get("mode", {})
    if (set(mode) != {"points", "pixels", "refreshMilliHz"}
            or any(not isinstance(mode[k], str) or not re.fullmatch(r"[0-9]{1,5}x[0-9]{1,5}", mode[k]) for k in ("points", "pixels"))
            or not isinstance(mode["refreshMilliHz"], int) or not 0 < mode["refreshMilliHz"] <= 1_000_000):
        raise ValueError("invalid display mode")
    if (set(value) != {"key", "backingScale", "iccSHA256", "iccDigestScheme", "iccRawSHA256", "mode"} or value["backingScale"] not in (1, 2)
            or value["iccDigestScheme"] != "icc-header-v1"
            or not re.fullmatch(r"[0-9a-f]{64}", value["iccRawSHA256"])
            or not re.fullmatch(r"[0-9a-f]{64}", value["iccSHA256"])
            or value["key"] != f"scale-{value['backingScale']}-icc-header-v1-{value['iccSHA256']}-mode-{mode['points']}-pixels-{mode['pixels']}-mhz-{mode['refreshMilliHz']}"):
        raise ValueError("invalid display metadata")
    return value


def environment_entry(manifest, environment, label):
    entry = manifest["environments"].get(environment["key"])
    if entry is None:
        raise ValueError(f"unknown {label} display key {environment['key']}; record a new trusted-main reference; no fallback")
    return entry


def legacy_baseline(root):
    environment = display_environment()
    resources = root / "Packages/OpenKit/Sources/space-editor-render/Resources/space-schema1/portable"
    manifest = read_manifest(resources / "manifest.json")
    entry = environment_entry(manifest, environment, "legacy")
    if entry["renderScale"] != environment["backingScale"] or not re.fullmatch(r"[0-9a-f]{40}", entry["trustedMainCommit"]):
        raise ValueError("invalid trusted legacy baseline metadata")
    asset_key = entry.get("assetKey", environment["key"])
    if not entry.get("original") and not re.fullmatch(r"scale-[12]-icc(?:-header-v1)?-[0-9a-f]{64}(?:-mode-[0-9]{1,5}x[0-9]{1,5}-pixels-[0-9]{1,5}x[0-9]{1,5}-mhz-[0-9]{1,7})?", asset_key):
        raise ValueError("invalid legacy asset key")
    directory = root / "Packages/OpenKit/Fixtures/space-schema1" if entry.get("original") else resources / asset_key / "legacy"
    for space in range(3):
        name = f"window-{space}.png"
        path = directory / name
        if path.stat().st_size > 16_777_216 or hashlib.sha256(path.read_bytes()).hexdigest() != entry["pngSHA256"]["legacy"][name]:
            raise ValueError("legacy baseline digest mismatch: " + name)
    print(f"legacy baseline: {environment['key']}; trusted main {entry['trustedMainCommit']}; byte identity")
    return directory, entry["renderScale"], environment["key"]


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Inspect a retained ICC against both reference manifests in the live display mode. Does not qualify a render.")
    parser.add_argument("--check-icc", type=Path, required=True)
    args = parser.parse_args()
    environment = display_environment()
    digest = json.loads(subprocess.check_output(
        ["/usr/bin/swift", str(Path(__file__).with_name("display-environment.swift")), "--icc-digest", str(args.check_icc)],
        text=True, timeout=60))
    environment["key"] = environment["key"].replace(environment["iccSHA256"], digest["iccSHA256"])
    environment.update(digest)
    root = Path(__file__).resolve().parents[2]
    for path, label in ((root / "Packages/OpenKit/Sources/space-editor-render/Resources/space-schema1/portable/manifest.json", "legacy"),
                        (Path(__file__).with_name("sidebar-color-baselines.json"), "sidebar")):
        environment_entry(read_manifest(path), environment, label)
    print(json.dumps({"environment": environment, "referenceSelection": "PASS", "renderQualified": False}, sort_keys=True))
