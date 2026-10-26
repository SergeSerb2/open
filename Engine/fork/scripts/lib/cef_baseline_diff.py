#!/usr/bin/env python3
"""Diff Chromium files against their CEF-patched baseline.

Open's Chromium patches apply after CEF's own patches (engine-apply runs CEF's
patcher first). A plain `git diff HEAD` of a file that CEF also patches would
repeat CEF's hunks, and the result would not apply on top of them. For each
path this script builds the baseline the Open patch applies to: the HEAD blob
plus the hunks of every CEF patch (cef/patch/patch.cfg order) that touches the
path. It then prints a `git diff` between that baseline and the working file,
with a/ and b/ prefixes, so `git apply -p1` (and `--3way`: the baseline blob is
written to the object store) reproduces the change.

Usage: cef_baseline_diff.py <chromium-src> <path>...   (stdout: the patch)
Only modified, tracked files of the src repository are supported. Read-only
except for `git hash-object -w` of baseline blobs.
"""
import ast
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def run(args, cwd=None, ok=(0,)):
    result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode not in ok:
        sys.exit("cef_baseline_diff: %s failed (%d): %s" % (" ".join(args), result.returncode,
                                                              result.stderr.decode(errors="replace")))
    return result.stdout


def cef_patches(src):
    cfg = src / "cef/patch/patch.cfg"
    tree = ast.parse(cfg.read_text())
    patches = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                   and any(isinstance(t, ast.Name) and t.id == "patches" for t in n.targets))
    result = []
    for patch in patches:
        if "condition" in patch and patch["condition"] not in os.environ:
            continue
        result.append((cfg.parent / "patches" / (patch["name"] + ".patch"), patch.get("path", "")))
    return result


def touches(patch_text, rel):
    return re.search(r"^\+\+\+ (b/)?%s(\t|$)" % re.escape(rel), patch_text, re.M) is not None


def baseline(src, path, patches, scratch):
    head = run(["git", "-C", str(src), "show", "HEAD:" + path])
    for patch_file, patch_dir in patches:
        rel = path[len(patch_dir) + 1:] if patch_dir and path.startswith(patch_dir + "/") else (
            None if patch_dir else path)
        if rel is None:
            continue
        text = patch_file.read_text(errors="replace")
        if not touches(text, rel):
            continue
        work = Path(tempfile.mkdtemp(dir=scratch))
        target = work / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(head)
        # The same options CEF's patcher uses (cef/tools/git_util.py).
        run(["git", "apply", "-p0", "--ignore-whitespace", "--include=" + rel, str(patch_file)], cwd=work)
        head = target.read_bytes()
    return head


def main():
    src = Path(sys.argv[1]).resolve()
    paths = sorted(set(sys.argv[2:]))
    patches = cef_patches(src)
    out = []
    with tempfile.TemporaryDirectory(prefix="open-cef-baseline-") as scratch:
        for path in paths:
            if not run(["git", "-C", str(src), "ls-files", "--", path]).strip():
                sys.exit("cef_baseline_diff: %s is not tracked; new files belong in the overlay" % path)
            base = baseline(src, path, patches, scratch)
            base_file = Path(scratch) / "base"
            base_file.write_bytes(base)
            # Store the baseline blob so `git apply --3way` can use it.
            run(["git", "-C", str(src), "hash-object", "-w", "--", str(base_file)])
            diff = run(["git", "-C", str(src), "diff", "--no-index", "--no-color", "--binary", "--full-index",
                        "--", str(base_file), str(src / path)], ok=(0, 1))
            if not diff:
                continue
            text = diff.decode()
            lines = text.split("\n")
            # Rewrite the temp/working paths in the header to a/<path> b/<path>.
            for i, line in enumerate(lines[:6]):
                if line.startswith("diff --git "):
                    lines[i] = "diff --git a/%s b/%s" % (path, path)
                elif line.startswith("--- "):
                    lines[i] = "--- a/%s" % path
                elif line.startswith("+++ "):
                    lines[i] = "+++ b/%s" % path
            out.append("\n".join(lines))
    sys.stdout.write("".join(out))


if __name__ == "__main__":
    main()
