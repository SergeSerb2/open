#!/usr/bin/env python3
"""Display identity and strict legacy PNG selection. No recording in normal runs."""
import hashlib
import json
from pathlib import Path
import re
import subprocess


def display_environment():
    result = subprocess.run(["/usr/bin/swift", str(Path(__file__).with_name("display-environment.swift"))],
                            capture_output=True, text=True, check=True, timeout=60)
    if len(result.stdout) > 2048:
        raise ValueError("oversized display metadata")
    value = json.loads(result.stdout)
    if (set(value) != {"key", "backingScale", "iccSHA256"} or value["backingScale"] not in (1, 2)
            or not re.fullmatch(r"[0-9a-f]{64}", value["iccSHA256"])
            or value["key"] != f"scale-{value['backingScale']}-icc-{value['iccSHA256']}"):
        raise ValueError("invalid display metadata")
    return value


def legacy_baseline(root):
    environment = display_environment()
    resources = root / "Packages/OpenKit/Sources/space-editor-render/Resources/space-schema1/portable"
    manifest = json.loads((resources / "manifest.json").read_text())
    entry = manifest["environments"].get(environment["key"])
    if entry is None:
        raise ValueError(f"unknown legacy display key {environment['key']}; record a new trusted-main reference; no fallback")
    if entry["renderScale"] != environment["backingScale"] or not re.fullmatch(r"[0-9a-f]{40}", entry["trustedMainCommit"]):
        raise ValueError("invalid trusted legacy baseline metadata")
    directory = root / "Packages/OpenKit/Fixtures/space-schema1" if entry.get("original") else resources / environment["key"] / "legacy"
    for space in range(3):
        name = f"window-{space}.png"
        path = directory / name
        if path.stat().st_size > 16_777_216 or hashlib.sha256(path.read_bytes()).hexdigest() != entry["pngSHA256"]["legacy"][name]:
            raise ValueError("legacy baseline digest mismatch: " + name)
    print(f"legacy baseline: {environment['key']}; trusted main {entry['trustedMainCommit']}; byte identity")
    return directory, entry["renderScale"]
