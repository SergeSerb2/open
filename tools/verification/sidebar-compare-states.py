#!/usr/bin/env python3
"""Reproduce docs/design.md §§7,15.1 using the real release render/compare CLI.

One render per process, sequentially. Compare.swift owns sRGB conversion and the
favicon, tile-icon, web-panel, traffic-light, and window-corner masks. Only the
explicit text mismatches documented in §15.1 are excluded below. No private text
or screenshot bytes are part of this script. Never copies its private inputs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HISTORICAL_SHA = "2e79746492cc775d8b207bc5759084b74f3e96ab88e521c6ab9909790a278448"
ROOT = Path(__file__).resolve().parents[2]

# name, capture, snapshot, render arguments, comparison arguments.
# Capture-time snapshots: static has no Today tabs, real has six Today tabs.
# F0079 uses the pre-theme-edit static snapshot, plus its omitted first child.
STATES = [
    ("static-active", "F0001", "snap-static", [], []),
    ("static-inactive", "inactive", "snap-static", ["--inactive"], []),
    ("row-hover", "F0013", "snap-static", ["--hover", "pinned:1"], ["--hover-row", "1"]),
    ("selected-pinned", "F0015", "snap-static", ["--select", "pinned:0", "--hover", "pinned:0", "--loaded", "--page"],
     ["--selected-row", "0", "--page-loaded"]),
    ("selected-favorite", "F0016", "snap-static", ["--select", "favorite:5", "--loaded", "--page"],
     ["--selected-tile", "5", "--page-loaded", "--skip", "URL field host,URL field copy,URL field site"]),
    ("toggle-hover", "F0024", "snap-static", ["--select", "favorite:5", "--loaded", "--page", "--hover", "toolbar:toggle"],
     ["--page-loaded", "--selected-tile", "5", "--hover-button", "toggle", "--skip", "URL field host,URL field copy,URL field site"]),
    ("home-hover", "F0027", "snap-static", ["--select", "favorite:5", "--loaded", "--page", "--hover", "home"],
     ["--page-loaded", "--selected-tile", "5", "--hover-button", "home", "--skip", "URL field host,URL field copy,URL field site"]),
    ("newtab-hover", "F0031", "snap-static", ["--select", "favorite:5", "--loaded", "--page", "--hover", "newtab"],
     ["--page-loaded", "--selected-tile", "5", "--hover-newtab", "--skip", "URL field host,URL field copy,URL field site"]),
    ("newtab-open", "F0063", "snap-real", ["--drop-today", "1", "--new-tab-open", "--select", "today:0", "--loaded", "--page"],
     ["--today", "5", "--new-tab-open", "--page-loaded", "--skip", "URL field host,URL field copy,URL field site"]),
    ("selected-today", "F0066", "snap-real", ["--select", "today:0", "--loaded", "--page"],
     ["--today", "6", "--selected-row", "10", "--page-loaded", "--skip", "URL field host,URL field copy,URL field site,row 11 title"]),
    ("default-dark", "F0079", "snap-static", ["--space", "3", "--untitled", "3", "--hover", "folder:0/0"],
     ["--rows", "7", "--dark", "--depths", "0,1,1,1,1,1,1", "--split-rows", "6", "--hover-row", "1"]),
    ("yellow", "F0070", "snap-static", ["--space", "2"], ["--rows", "2"]),
    ("blue-grain", "F0069", "snap-static", ["--space", "1"], ["--rows", "9", "--skip", "row ,New Tab"]),
]


def default_inputs():
    result = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, text=True, capture_output=True, check=True)
    common = (ROOT / result.stdout.strip()).resolve()
    return common.parent / ".re/design-compare"


def inputs(root):
    frames = root.parent / "runtime/sessions/20261024-213009-session-full"
    captures = {}
    for _, frame, _, _, _ in STATES:
        if frame == "inactive":
            path = root.parent / "runtime/shots/arc-window-5245.png"
        else:
            found = sorted(frames.glob(frame[1:] + "-*/win-5245.png"))
            if len(found) != 1:
                raise FileNotFoundError("expected one capture for " + frame)
            path = found[0]
        if not path.is_file():
            raise FileNotFoundError("missing capture " + frame)
        captures[frame] = path
    for name in ("snap-static", "snap-real"):
        if not (root / name / "State/browser.json").is_file():
            raise FileNotFoundError("missing " + name + "/State/browser.json")
    return captures


def command(args, log):
    with log.open("wb") as stream:
        try:
            subprocess.run([str(a) for a in args], stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=600)
        except subprocess.SubprocessError:
            raise ValueError("state command failed; inspect its private log: " + str(log)) from None


def build_main(out, ref):
    source = out / "main-source"
    source.mkdir()
    # This is a disposable source export, not a worktree or a copy of private data.
    archive = subprocess.Popen(["git", "archive", ref, "Packages/OpenKit"], cwd=ROOT, stdout=subprocess.PIPE)
    try:
        subprocess.run(["tar", "-x", "-C", str(source)], stdin=archive.stdout, check=True)
    finally:
        archive.stdout.close()
    if archive.wait() != 0:
        raise RuntimeError("git archive failed")
    package = source / "Packages/OpenKit"
    with (out / "main-build.log").open("wb") as log:
        subprocess.run(["nice", "-n", "10", "swift", "build", "--package-path", str(package), "-c", "release", "-j", os.environ.get("VERIFY_JOBS", "6")],
                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True, check=True, timeout=900)
    return package / ".build/release/sidebar-render"


def run_state(renderer, root, capture, state, target):
    name, _, snapshot, render, compare = state
    target.mkdir(parents=True)
    if name == "default-dark":
        # The old snapshot omits the capture's first folder child. Read its title
        # only inside this private compare harness; never embed it in source.
        ax = json.loads((capture.parent / "ax.json").read_text())
        def walk(node):
            yield node
            for child in node.get("children", []):
                yield from walk(child)
        title = next((node.get("value") for tree in ax for node in walk(tree)
                      if node.get("role") == "AXStaticText" and node.get("rel", [])[:2] == [59, 290]), None)
        if not isinstance(title, str) or not title:
            raise ValueError("F0079 missing first folder-child title in private AX input")
        render = [*render, "--insert-folder-tab", "0/0=" + title]
    # PNG dimensions come from IHDR, without decoding or changing the capture.
    import struct
    width, height = struct.unpack(">II", capture.read_bytes()[16:24])
    common = ["--width", "228", "--scale", "1"]
    command([renderer, "render", "--snapshot", root / snapshot, "--out", target / "render.png", "--size", f"{width}x{height}",
             "--appearance", "dark", *([] if "--space" in render else ["--space", "0"]), *common, *render], target / "render.log")
    command([renderer, "compare", "--arc", capture, "--ours", target / "render.png", "--out", target,
             "--title", name, *common, *compare], target / "compare.log")
    return (target / "table.md").read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture_root", type=Path, nargs="?", help="absolute .re/design-compare directory")
    parser.add_argument("--renderer", type=Path, default=ROOT / "Packages/OpenKit/.build/release/sidebar-render")
    parser.add_argument("--baseline-renderer", type=Path, help="release binary already built from --baseline-ref")
    parser.add_argument("--baseline-ref", default="origin/main")
    parser.add_argument("--out", type=Path, help="new output directory outside the checkout (default: /tmp)")
    parser.add_argument("--probe", action="store_true", help="check private input presence only; exit 77 when absent")
    parser.add_argument("--attempts", type=int, choices=range(1, 4), default=3,
                        help="bounded paired repeats for known offscreen nondeterminism (§15.1); retains every attempt")
    args = parser.parse_args()
    root = (args.capture_root or default_inputs()).resolve()
    try:
        captures = inputs(root)
    except FileNotFoundError as error:
        print("SKIP: sidebar captures absent: " + str(error))
        return 77 if args.probe else 1
    if args.probe:
        print("13 sidebar capture states available")
        return 0
    # verify-all gives each check a disposable TMPDIR. Private comparison evidence
    # must survive that cleanup and must stay outside the repository/artifact logs.
    out = args.out.resolve() if args.out else Path(tempfile.mkdtemp(prefix="open-sidebar-compare-", dir="/tmp"))
    if out.is_relative_to(ROOT) and not out.is_relative_to(default_inputs().parent):
        raise ValueError("outputs must be outside the checkout")
    if args.out:
        out.mkdir(mode=0o700, parents=True, exist_ok=False)
    renderer = args.renderer.resolve()
    ref_sha = subprocess.check_output(["git", "rev-parse", args.baseline_ref], cwd=ROOT, text=True).strip()
    baseline = args.baseline_renderer.resolve() if args.baseline_renderer else build_main(out, ref_sha)
    receipt = {"baselineRef": args.baseline_ref, "baselineCommit": ref_sha,
               "baselineBinarySHA256": hashlib.sha256(baseline.read_bytes()).hexdigest(),
               "branchBinarySHA256": hashlib.sha256(renderer.read_bytes()).hexdigest(),
               "snapshotSHA256": {name: hashlib.sha256((root / name / "State/browser.json").read_bytes()).hexdigest()
                                  for name in ("snap-static", "snap-real")},
               "captureSHA256": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in captures.items()}, "states": []}
    combined = {"main": {}, "branch": {}}
    failed = []
    for state in STATES:
        name, frame, _, _, _ = state
        for attempt in range(1, args.attempts + 1):
            tables = {kind: run_state(binary, root, captures[frame], state, out / kind / name / f"attempt-{attempt}")
                      for kind, binary in (("main", baseline), ("branch", renderer))}
            same = tables["main"] == tables["branch"]
            if same or attempt == args.attempts:
                for kind, table in tables.items():
                    combined[kind][name] = table
                    (out / kind / name / "table.md").write_bytes(table)
                break
            print(f"{name}: tables differ on paired attempt {attempt}; preserving outputs and repeating both processes", flush=True)
        worst = re.search(rb"Worst position error .*", tables["main"])
        print(f"{name}: {'PASS' if same else 'FAIL'} (paired attempts {attempt}) " + (worst[0].decode() if worst else "missing summary"), flush=True)
        receipt["states"].append({"name": name, "identical": same, "attempts": attempt})
        if not same:
            failed.append(name)
    for kind in combined:
        payload = b"".join(combined[kind][name] for name in sorted(combined[kind]))
        digest = hashlib.sha256(payload).hexdigest()
        receipt[kind + "CombinedSHA256"] = digest
        (out / kind / "combined-tables.md").write_bytes(payload)
        (out / kind / "combined.sha256").write_text(digest + "\n")
        print(f"{kind} concatenated tables SHA-256: {digest}")
    print("historical SHA-256: " + HISTORICAL_SHA)
    if receipt["mainCombinedSHA256"] != HISTORICAL_SHA:
        print("baseline SHA re-derived: " + receipt["mainCombinedSHA256"])
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if (hashlib.sha256(baseline.read_bytes()).hexdigest() != receipt["baselineBinarySHA256"] or
            hashlib.sha256(renderer.read_bytes()).hexdigest() != receipt["branchBinarySHA256"]):
        raise ValueError("renderer changed during comparison; rerun after its build completes")
    print(f"tables identical: {13 - len(failed)}/13; output: {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
