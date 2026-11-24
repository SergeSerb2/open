#!/usr/bin/env python3
"""Determine whether a commit range or file list affects the shipped Open.app release.

Prints a JSON object describing whether a release is warranted, the reason,
and the partitioned file lists. Designed for both CI preflight and the
superseded-release watcher.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

RELEASE_PREFIXES = (
    "App/",
    "Helper/",
    "DockTile/",
    "Engine/",
    "Packages/",
    "assets/",
    "docs/release/licenses/",
    "docs/release/notes/",
    "tools/adblock-resources/",
)

RELEASE_EXACT_FILES = frozenset(
    {
        "project.yml",
        "docs/release/licenses.md",
        "tools/build.sh",
        "tools/embed-adblock.sh",
        "tools/embed-cef.sh",
        "tools/fetch-adblock-lists.sh",
        "tools/fetch-adblock-resources.py",
        "tools/fetch-cef.sh",
        "tools/fetch-engine.sh",
        "tools/generate-acknowledgements.py",
        "tools/generate-app-icons.sh",
        "tools/generate-intro-sound.py",
        "tools/generate-sounds.py",
        "tools/release-icon.swift",
        "tools/release-locales.txt",
        "tools/release.sh",
        "tools/render-app-icon.swift",
    }
)

SKIP_RE = re.compile(r"\[skip release\]", re.IGNORECASE)
FORCE_RE = re.compile(r"\[force release\]", re.IGNORECASE)


def is_release_path(path: str) -> bool:
    normalized = re.sub(r"^(?:\./)+", "", path.strip()).lstrip("/")
    if not normalized:
        return False
    if normalized in RELEASE_EXACT_FILES:
        return True
    return any(normalized.startswith(prefix) for prefix in RELEASE_PREFIXES)


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repo), *args],
        text=True,
        stderr=subprocess.PIPE,
    )


def changed_files_in_range(repo: Path, base: str, head: str) -> list[str]:
    # --no-renames ensures moving a shipped file into a non-release dir (e.g. docs/)
    # still reports the deletion under its shipped path.
    out = git(repo, "diff", "--no-renames", "--name-only", f"{base}..{head}")
    return [line.strip() for line in out.splitlines() if line.strip()]


def first_parent_messages(repo: Path, base: str, head: str) -> list[str]:
    out = git(repo, "log", "--first-parent", "--format=%B%x1e", f"{base}..{head}")
    return [chunk.strip() for chunk in out.split("\x1e") if chunk.strip()]


def evaluate(
    *,
    repo: Path,
    base: str | None,
    head: str | None,
    files: list[str] | None,
    check_markers: bool,
) -> dict:
    if files is not None:
        changed = [f for f in files if f.strip()]
        messages: list[str] = []
    else:
        assert base and head
        if base == head:
            return {
                "relevant": False,
                "reason": "base and head are identical",
                "relevant_files": [],
                "ignored_files": [],
            }
        changed = changed_files_in_range(repo, base, head)
        messages = first_parent_messages(repo, base, head) if check_markers else []

    if check_markers and messages:
        if any(FORCE_RE.search(msg) for msg in messages):
            relevant = [f for f in changed if is_release_path(f)]
            ignored = [f for f in changed if not is_release_path(f)]
            return {
                "relevant": True,
                "reason": "explicit [force release] commit marker",
                "relevant_files": relevant,
                "ignored_files": ignored,
            }
        if all(SKIP_RE.search(msg) for msg in messages):
            return {
                "relevant": False,
                "reason": "all commits in range marked [skip release]",
                "relevant_files": [],
                "ignored_files": changed,
            }

    relevant = [f for f in changed if is_release_path(f)]
    ignored = [f for f in changed if not is_release_path(f)]
    if relevant:
        return {
            "relevant": True,
            "reason": f"{len(relevant)} release-relevant file(s) changed",
            "relevant_files": relevant,
            "ignored_files": ignored,
        }
    return {
        "relevant": False,
        "reason": "only non-release files changed (docs, CI, tests, or SyncServer)",
        "relevant_files": [],
        "ignored_files": ignored,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."), help="Git repository root")
    parser.add_argument("--base", help="Base commit/ref")
    parser.add_argument("--head", help="Head commit/ref")
    parser.add_argument("--range", dest="commit_range", help="Commit range base..head")
    parser.add_argument("--files", nargs="*", help="Explicit file list instead of git diff")
    parser.add_argument(
        "--check-markers",
        action="store_true",
        help="Honor [skip release] / [force release] commit markers",
    )
    parser.add_argument(
        "--exit-code",
        action="store_true",
        help="Exit 0 if release-relevant, 1 if not",
    )
    args = parser.parse_args(argv)

    base, head = args.base, args.head
    if args.commit_range:
        if ".." not in args.commit_range:
            parser.error("--range must be in base..head format")
        base, head = args.commit_range.split("..", 1)

    if args.files is None and not (base and head):
        parser.error("provide either --files or --base/--head (or --range)")

    result = evaluate(
        repo=args.repo.resolve(),
        base=base,
        head=head,
        files=args.files,
        check_markers=args.check_markers,
    )
    print(json.dumps(result, indent=2))
    if args.exit_code:
        return 0 if result["relevant"] else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
