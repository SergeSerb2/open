#!/usr/bin/env python3
"""Record a new display reference with unchanged, freshly built trusted-main CLIs.

Run in a heavy slot after building --trusted-root. Outputs are proposals only.
The original references and all existing display keys are read-only.
"""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile


def command(*args, **kwargs):
    return subprocess.check_output([str(x) for x in args], timeout=180, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trusted-root", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    root = args.trusted_root.resolve()
    commit = command("git", "rev-parse", "origin/main", cwd=root).decode().strip()
    command("git", "diff", "--exit-code", commit, "--", "Packages/OpenKit", cwd=root)
    if command("git", "ls-files", "--others", "--exclude-standard", "Packages/OpenKit", cwd=root).strip():
        raise ValueError("untracked package source in trusted main")
    environment = runpy.run_path(str(Path(__file__).with_name("portable-baselines.py")))["display_environment"]()
    manifest = json.loads((Path(__file__).resolve().parents[2] /
        "Packages/OpenKit/Sources/space-editor-render/Resources/space-schema1/portable/manifest.json").read_text())
    if environment["key"] in manifest["environments"]:
        raise ValueError("existing display reference may not be regenerated")
    if environment["backingScale"] != 2:
        raise ValueError("original 1x references may not be regenerated")
    args.out.mkdir(mode=0o700, parents=True, exist_ok=False)
    binary = root / "Packages/OpenKit/.build/release"
    digests = {}
    metadata = {"trustedMainCommit": commit, "environment": environment, "renderScale": 2,
                "osBuild": command("sw_vers", "-buildVersion").decode().strip(),
                "binarySHA256": {name: hashlib.sha256((binary / name).read_bytes()).hexdigest()
                                 for name in ("openkit", "sidebar-render", "space-editor-render")}}
    with tempfile.TemporaryDirectory(prefix="open-legacy-record-") as temporary:
        data = Path(temporary) / "fixture"
        shutil.copytree(root / "Packages/OpenKit/Fixtures/space-schema1", data)
        command(binary / "openkit", "roundtrip", data)
        for kind in ("legacy", "editor"):
            directory = args.out / environment["key"] / kind
            directory.mkdir(parents=True)
            digests[kind] = {}
            for space in range(3):
                path = directory / f"window-{space}.png"
                renderer = binary / ("sidebar-render" if kind == "legacy" else "space-editor-render")
                source = ["--snapshot", data] if kind == "legacy" else ["--synthetic"]
                command(renderer, "render" if kind == "legacy" else "window", *source,
                        "--space", space, "--size", "900x700", "--scale", 2, "--out", path)
                digests[kind][path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
                print(kind, space, path.stat().st_size, digests[kind][path.name], flush=True)
    metadata["pngSHA256"] = digests
    (args.out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("trusted main", commit, "display", environment["key"])


if __name__ == "__main__":
    main()
