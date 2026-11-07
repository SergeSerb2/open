#!/usr/bin/env python3
"""Reproduce docs/design.md §§7,15.1 using the real release render/compare CLI.

One render per process, sequentially. Compare.swift owns sRGB conversion and the
favicon, tile-icon, web-panel, traffic-light, and window-corner masks. Only the
explicit text mismatches documented in §15.1 are excluded below. No private text
or screenshot bytes are part of this script. The renderer locks (and may migrate)
the data root it reads, so each run renders from its own 0700 copy of the two
snapshot files under /tmp, deleted on exit. Concurrent runs never share a lock,
and the private inputs in .re are never written.
"""
import argparse
from decimal import Decimal, ROUND_CEILING
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import runpy

HISTORICAL_SHA = "2e79746492cc775d8b207bc5759084b74f3e96ab88e521c6ab9909790a278448"
ROOT = Path(__file__).resolve().parents[2]

# Lead gate (2026-10-26), docs/design.md §15.1. SHA is informational.
COLOR_DRIFT = Decimal("0.15")
# Expected compared elements, worst position, worst ΔE00 against Arc.
LIMITS = {
    "static-active": (31, "1.0", "1.59"), "static-inactive": (31, "1.0", "1.17"),
    "row-hover": (33, "1.0", "1.59"), "selected-pinned": (33, "1.0", "1.73"),
    "selected-favorite": (28, "1.0", "1.59"), "toggle-hover": (29, "1.0", "1.59"),
    "home-hover": (29, "2.0", "1.59"), "newtab-hover": (29, "1.0", "1.59"),
    "newtab-open": (35, "1.0", "2.00"), "selected-today": (36, "1.0", "2.03"),
    "default-dark": (31, "1.0", "1.77"), "yellow": (23, "1.0", "1.95"),
    "blue-grain": (19, "1.0", "2.38"),
}

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


def private_roots(root):
    """Per-run data roots holding only State/browser.json, outside verify-all's
    scratch dir (--keep-logs moves that into a possibly uploaded log directory)."""
    data = Path(tempfile.mkdtemp(prefix="open-sidebar-compare-data-", dir="/tmp"))
    for name in ("snap-static", "snap-real"):
        (data / name / "State").mkdir(mode=0o700, parents=True)
        shutil.copyfile(root / name / "State/browser.json", data / name / "State/browser.json")
    return data


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
    repository = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, text=True).strip()
    archive = subprocess.Popen(["git", "archive", ref, "Packages/OpenKit"], cwd=repository, stdout=subprocess.PIPE)
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
    if os.environ.get("OPEN_VERIFY_BREAK") in ("all", "color") and "branch" in target.parts:
        command(["/usr/bin/swift", Path(__file__).with_name("break-render.swift"), target / "render.png", "color"],
                target / "negative-proof.log")
    command([renderer, "compare", "--arc", capture, "--ours", target / "render.png", "--out", target,
             "--title", name, *common, *compare], target / "compare.log")
    return (target / "table.md").read_bytes()


def table_metrics(table):
    text = table.decode("utf-8")
    rows = []
    for line in text.splitlines():
        if not line.startswith("| ") or line.startswith("| Element |"):
            continue
        cells = [part.strip() for part in line.strip("|").split("|")]
        if len(cells) != 7:
            raise ValueError("unexpected comparison table columns")
        label = cells[0]
        # Background labels include their sampling count and maximum color
        # metric. Keep the count exact; compare the metric as a color value.
        extra = re.search(r" \((\d+) points, max ΔE ([0-9.]+)\)$", label)
        colors = [None if cells[2] == "—" else Decimal(cells[2])]
        if extra:
            label = label[:extra.start()] + " (" + extra[1] + " points)"
            colors.append(Decimal(extra[2]))
        rows.append({"element": label, "position": cells[1], "ink": cells[5:7], "colors": colors})
    summary = re.search(r"Worst position error ([0-9.]+) pt, worst ΔE00 ([0-9.]+), (\d+) elements\.", text)
    if not rows or not summary:
        raise ValueError("missing comparison rows or worst-value summary")
    return rows, (Decimal(summary[1]), Decimal(summary[2]), int(summary[3]))


def gate_tables(name, tables, color_limits):
    parsed = {kind: table_metrics(table) for kind, table in tables.items()}
    errors = []
    count, position_limit, original_color_limit = LIMITS[name]
    color_limit = color_limits.get(name, original_color_limit)
    for kind, (rows, worst) in parsed.items():
        if len(rows) != count or worst[2] != count:
            errors.append(f"{kind}: compared element count {len(rows)}/{worst[2]} != {count}")
        if worst[0] > Decimal(position_limit) or worst[1] > Decimal(color_limit):
            errors.append(f"{kind}: Arc worst {worst[0]} pt / {worst[1]} ΔE00 exceeds {position_limit} pt / {color_limit}")
    main_rows, branch_rows = parsed["main"][0], parsed["branch"][0]
    geometry_same = True
    max_drift = Decimal(0)
    if [row["element"] for row in main_rows] != [row["element"] for row in branch_rows]:
        errors.append("compared elements or sampling counts differ")
        geometry_same = False
    else:
        for main, branch in zip(main_rows, branch_rows):
            if main["position"] != branch["position"] or main["ink"] != branch["ink"]:
                geometry_same = False
                errors.append(main["element"] + ": position or ink box differs")
            if len(main["colors"]) != len(branch["colors"]):
                errors.append(main["element"] + ": color metrics differ in shape")
                continue
            for a, b in zip(main["colors"], branch["colors"]):
                if a is None or b is None:
                    if a != b:
                        errors.append(main["element"] + ": missing color metric")
                    continue
                drift = abs(a - b)
                max_drift = max(max_drift, drift)
                if drift > COLOR_DRIFT:
                    errors.append(f"{main['element']}: color-metric drift {drift} > {COLOR_DRIFT} ΔE00")
    return {"passed": not errors, "positionAndInkIdentical": geometry_same,
            "maxColorMetricDrift": str(max_drift), "errors": errors,
            "byteIdentical": tables["main"] == tables["branch"]}


def record_limits(baseline, data, captures, out, attempts, receipt):
    """Propose caps from every measured main attempt; never edit a fixture."""
    proposed = {}
    errors = []
    for state in STATES:
        name, frame, _, _, _ = state
        count, position = LIMITS[name][:2]
        measurements = []
        for attempt in range(1, attempts + 1):
            table = run_state(baseline, data, captures[frame], state,
                              out / "main" / name / f"attempt-{attempt}")
            rows, worst = table_metrics(table)
            measurements.append({"attempt": attempt, "count": len(rows),
                                 "summaryCount": worst[2], "position": str(worst[0]),
                                 "worstDeltaE00": str(worst[1])})
            if len(rows) != count or worst[2] != count or worst[0] != Decimal(position):
                errors.append(f"{name} attempt {attempt}: count/position disagrees with shared STATE_META")
            # Check all metrics, including the background sampled maximum,
            # before proposing a cap from the unchanged worst-value summary.
            if any(color > Decimal(LIMITS[name][2]) + Decimal("1.00")
                   for row in rows for color in row["colors"] if color is not None):
                errors.append(f"{name} attempt {attempt}: element exceeds M5 cap + {Decimal('1.00')} ΔE00")
        measured = max(Decimal(row["worstDeltaE00"]) for row in measurements)
        cap = (measured * 100).to_integral_value(rounding=ROUND_CEILING) / 100
        proposed[name] = f"{cap:.2f}"
        old = Decimal(LIMITS[name][2])
        if cap > old + Decimal("1.00"):
            errors.append(f"{name}: proposed cap {cap} exceeds M5 cap {old} + {Decimal('1.00')}")
        print(f"{name}: measured main worst {measured} ΔE00; proposed {proposed[name]}; "
              f"M5 {old}; diff {cap - old:+.2f}; attempts {attempts}", flush=True)
        receipt["states"].append({"name": name, "measurements": measurements})
    receipt.update({"proposedColorLimits": proposed, "errors": errors, "passed": not errors})
    if hashlib.sha256(baseline.read_bytes()).hexdigest() != receipt["baselineBinarySHA256"]:
        raise ValueError("baseline renderer changed during recording; rerun after its build completes")
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if errors:
        raise ValueError("record-limits refused: " + "; ".join(errors))
    print("Color limit proposal (read-only; add only by reviewed PR):")
    print(repr({receipt["envKey"]: proposed}))
    print(f"recorded states: {len(proposed)}/13; output: {out}")
    return 0


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
    parser.add_argument("--record-limits", action="store_true",
                        help="propose a new display key from a clean origin/main export; never overwrite a key")
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
    environment = runpy.run_path(str(Path(__file__).with_name("portable-baselines.py")))["display_environment"]()
    key = environment["key"]
    manifest = json.loads(Path(__file__).with_name("sidebar-color-baselines.json").read_text())
    entry = manifest["environments"].get(key)
    if entry is None and not args.record_limits:
        raise ValueError(f"unknown sidebar display key {key}; record new trusted-main limits; no fallback")
    color_limits = entry["colorLimits"] if entry else {}
    if args.record_limits and (entry or args.baseline_renderer or args.baseline_ref != "origin/main"):
        raise ValueError("recording requires a new key and a clean origin/main build, without baseline overrides")
    print(f"sidebar color environment: {key}; limits: {'recorded' if entry else 'original strict M5'}", flush=True)
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
    receipt = {"gate": {"positionAndInk": "identical", "colorMetricDrift": str(COLOR_DRIFT),
                        "arcLimits": LIMITS, "selectedColorLimits": color_limits, "sha": "informational"},
               "environment": environment, "envKey": key, "baselineRef": args.baseline_ref, "baselineCommit": ref_sha,
               "baselineBinarySHA256": hashlib.sha256(baseline.read_bytes()).hexdigest(),
               "snapshotSHA256": {name: hashlib.sha256((root / name / "State/browser.json").read_bytes()).hexdigest()
                                  for name in ("snap-static", "snap-real")},
               "captureSHA256": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in captures.items()}, "states": []}
    if not args.record_limits:
        receipt["branchBinarySHA256"] = hashlib.sha256(renderer.read_bytes()).hexdigest()
    combined = {"main": {}, "branch": {}}
    failed = []
    data = private_roots(root)
    try:
        if args.record_limits:
            return record_limits(baseline, data, captures, out, args.attempts, receipt)
        for state in STATES:
            name, frame, _, _, _ = state
            attempt_results = []
            for attempt in range(1, args.attempts + 1):
                tables = {kind: run_state(binary, data, captures[frame], state, out / kind / name / f"attempt-{attempt}")
                          for kind, binary in (("main", baseline), ("branch", renderer))}
                result = gate_tables(name, tables, color_limits)
                attempt_results.append({"attempt": attempt, **result})
                if result["passed"] or attempt == args.attempts:
                    for kind, table in tables.items():
                        combined[kind][name] = table
                        (out / kind / name / "table.md").write_bytes(table)
                    break
                print(f"{name}: gate failed on paired attempt {attempt}; preserving outputs and repeating both processes: " + "; ".join(result["errors"]), flush=True)
            worst = re.search(rb"Worst position error .*", tables["main"])
            print(f"{name}: {'PASS' if result['passed'] else 'FAIL'} (paired attempts {attempt}; position/ink {'identical' if result['positionAndInkIdentical'] else 'differ'}; max color drift {result['maxColorMetricDrift']} ΔE00) " + (worst[0].decode() if worst else "missing summary"), flush=True)
            receipt["states"].append({"name": name, "attempts": attempt, "attemptResults": attempt_results, **result})
            if not result["passed"]:
                failed.append(name)
                print("  " + "; ".join(result["errors"]), flush=True)
    finally:
        shutil.rmtree(data, ignore_errors=True)
    for kind in combined:
        payload = b"".join(combined[kind][name] for name in sorted(combined[kind]))
        digest = hashlib.sha256(payload).hexdigest()
        receipt[kind + "CombinedSHA256"] = digest
        (out / kind / "combined-tables.md").write_bytes(payload)
        (out / kind / "combined.sha256").write_text(digest + "\n")
        print(f"{kind} concatenated tables SHA-256 (informational): {digest}")
    print("historical SHA-256: " + HISTORICAL_SHA)
    if receipt["mainCombinedSHA256"] != HISTORICAL_SHA:
        print("baseline SHA re-derived: " + receipt["mainCombinedSHA256"])
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if (hashlib.sha256(baseline.read_bytes()).hexdigest() != receipt["baselineBinarySHA256"] or
            hashlib.sha256(renderer.read_bytes()).hexdigest() != receipt["branchBinarySHA256"]):
        raise ValueError("renderer changed during comparison; rerun after its build completes")
    identical = sum(state["byteIdentical"] for state in receipt["states"])
    print(f"states passed: {13 - len(failed)}/13; tables byte-identical (informational): {identical}/13; output: {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
