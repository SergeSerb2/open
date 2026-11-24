#!/usr/bin/env python3
"""Compute the next monotonic Open release version, build number, and release notes.

Reads:
  - project.yml (MARKETING_VERSION, CURRENT_PROJECT_VERSION)
  - App/Info.plist (OpenEngineStamp)
  - Live Sparkle appcast.xml (default: https://sergeserb2.github.io/open-releases/appcast.xml)
  - Remote release tags from SergeSerb2/open-releases and origin (SergeSerb2/open)

Computes:
  - latest_feed_version / latest_feed_build: matched pair from the highest-build
    <item> in the live appcast.xml (used for Sparkle delta predecessor seeding).
  - next_build   = max(live_build + 1, project_yml_build)
  - next_version = project_yml_version if > max(published_versions) else bump_patch(max_published)
  - last_released_sha: exact commit in origin matching the live published release
    (never trusting an orphaned origin tag that has no live feed item).
  - release notes Markdown (uses hand-written docs/release/notes/<version>.md if present
    and non-template; otherwise generates clean Markdown from merged PRs/commits since
    last_released_sha, sanitized for tools/release.sh's validation rules).

Optionally writes project.yml and docs/release/notes/<version>.md in place when --apply is passed.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
MERGE_PR_RE = re.compile(r"^Merge pull request #(\d+) from .+$")
MAX_NOTES_BYTES = 60 * 1024  # Safely below tools/release.sh's 64 KiB cap


def parse_semver(value: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(value.strip())
    if not match:
        raise ValueError(f"invalid semver: {value!r}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def format_semver(parts: tuple[int, int, int]) -> str:
    return f"{parts[0]}.{parts[1]}.{parts[2]}"


def bump_patch(parts: tuple[int, int, int]) -> tuple[int, int, int]:
    return (parts[0], parts[1], parts[2] + 1)


def read_project_version(project_yml: Path) -> tuple[str, int]:
    text = project_yml.read_text(encoding="utf-8")

    def extract(key: str) -> str:
        match = re.search(rf'^\s+{key}:\s*"?([\w.]+)"?\s*$', text, re.M)
        if not match:
            raise ValueError(f"missing {key} in {project_yml}")
        return match.group(1)

    marketing = extract("MARKETING_VERSION")
    build_str = extract("CURRENT_PROJECT_VERSION")
    parse_semver(marketing)
    if not re.fullmatch(r"[1-9]\d*", build_str):
        raise ValueError(f"invalid CURRENT_PROJECT_VERSION: {build_str!r}")
    return marketing, int(build_str)


def write_project_version(project_yml: Path, version: str, build: int) -> None:
    text = project_yml.read_text(encoding="utf-8")
    new_text, count_v = re.subn(
        r'^(\s+MARKETING_VERSION:\s*)"?[\w.]+"?(\s*)$',
        rf'\g<1>"{version}"\g<2>',
        text,
        count=1,
        flags=re.M,
    )
    new_text, count_b = re.subn(
        r'^(\s+CURRENT_PROJECT_VERSION:\s*)"?[\w.]+"?(\s*)$',
        rf'\g<1>"{build}"\g<2>',
        new_text,
        count=1,
        flags=re.M,
    )
    if count_v != 1 or count_b != 1:
        raise RuntimeError(f"failed to update MARKETING_VERSION/CURRENT_PROJECT_VERSION in {project_yml}")
    project_yml.write_text(new_text, encoding="utf-8")


def fetch_feed(
    feed_url: str, feed_file: Path | None
) -> tuple[list[tuple[int, int, int]], tuple[tuple[int, int, int], int] | None]:
    """Return (all_semver_versions, (newest_item_version, newest_item_build) | None)."""
    if feed_file is not None:
        raw = feed_file.read_bytes()
    else:
        req = urllib.request.Request(feed_url, headers={"User-Agent": "open-release-planner/1.0"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read(4 * 1024 * 1024 + 1)
            if len(raw) > 4 * 1024 * 1024:
                raise RuntimeError("appcast feed exceeds 4 MiB safety limit")

    root = ET.fromstring(raw)
    versions: list[tuple[int, int, int]] = []
    paired: list[tuple[int, tuple[int, int, int]]] = []
    for item in root.iter("item"):
        ver_text = (item.findtext(SPARKLE_NS + "shortVersionString") or "").strip()
        bld_text = (item.findtext(SPARKLE_NS + "version") or "").strip()
        parsed_ver = parse_semver(ver_text) if SEMVER_RE.fullmatch(ver_text) else None
        if parsed_ver is not None:
            versions.append(parsed_ver)
        if parsed_ver is not None and bld_text.isdecimal():
            paired.append((int(bld_text), parsed_ver))

    if not paired:
        return versions, None
    best_build, best_ver = max(paired, key=lambda pair: (pair[0], pair[1]))
    return versions, (best_ver, best_build)


def ls_remote_semver_tags(remote_url: str, *, allow_failure: bool) -> dict[tuple[int, int, int], str]:
    proc = subprocess.run(
        ["git", "ls-remote", "--tags", remote_url],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if proc.returncode != 0:
        if allow_failure:
            return {}
        raise RuntimeError(f"git ls-remote --tags {remote_url} failed (exit {proc.returncode}): {proc.stderr.strip()}")
    tags: dict[tuple[int, int, int], str] = {}
    peeled: dict[tuple[int, int, int], str] = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        sha, ref = parts
        if not ref.startswith("refs/tags/"):
            continue
        name = ref[len("refs/tags/") :]
        is_peeled = name.endswith("^{}")
        if is_peeled:
            name = name[:-3]
        match = TAG_RE.fullmatch(name)
        if not match:
            continue
        ver = (int(match.group(1)), int(match.group(2)), int(match.group(3)))
        if is_peeled:
            peeled[ver] = sha
        else:
            tags[ver] = sha
    tags.update(peeled)
    return tags


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repo), *args],
        text=True,
        stderr=subprocess.PIPE,
    )


def commit_exists(repo: Path, sha: str) -> bool:
    if not sha or not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        return False
    proc = subprocess.run(
        ["git", "-C", str(repo), "cat-file", "-e", f"{sha}^{{commit}}"],
        capture_output=True,
        check=False,
    )
    return proc.returncode == 0


def find_last_released_sha(
    repo: Path,
    origin_tags: dict[tuple[int, int, int], str],
    latest_feed_version: tuple[int, int, int] | None,
    releases_repo: str | None,
) -> tuple[str | None, str]:
    # 1. Source commit recorded in the SergeSerb2/open-releases release matching the live feed item.
    # This prevents an orphaned/unpublished origin tag from ever hiding an unshipped PR.
    if releases_repo and latest_feed_version is not None:
        tag_name = f"v{format_semver(latest_feed_version)}"
        env = dict(os.environ)
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
        proc = subprocess.run(
            ["gh", "release", "view", tag_name, "--repo", releases_repo, "--json", "tagName,body"],
            capture_output=True,
            text=True,
            env=env,
            timeout=20,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            try:
                data = json.loads(proc.stdout)
                match = re.search(r"Source commit:\s*([0-9a-f]{40})", data.get("body", ""))
                if match and commit_exists(repo, match.group(1)):
                    return match.group(1), f"release body {tag_name}"
            except ValueError:
                pass

    # 2. Origin vX.Y.Z tag ONLY if it corresponds to a live feed version (<= latest_feed_version)
    eligible_tags = {
        ver: sha
        for ver, sha in origin_tags.items()
        if latest_feed_version is None or ver <= latest_feed_version
    }
    if eligible_tags:
        best_ver = max(eligible_tags)
        sha = eligible_tags[best_ver]
        if commit_exists(repo, sha):
            return sha, f"origin tag v{format_semver(best_ver)}"

    # 3. Bootstrap fallback: last commit touching docs/release/notes/<latest_feed_version>.md
    if latest_feed_version is not None:
        ver_str = format_semver(latest_feed_version)
        notes_rel = f"docs/release/notes/{ver_str}.md"
        if (repo / notes_rel).is_file():
            sha = git(repo, "log", "-n", "1", "--first-parent", "--format=%H", "--", notes_rel).strip()
            if commit_exists(repo, sha):
                return sha, f"bootstrap from {notes_rel}"

    return None, "no prior release commit found"


def sanitize_note_text(text: str) -> str:
    """tools/release.sh forbids raw '<...>' (template-placeholder guard) and
    the literal phrase 'release-notes template' in production notes."""
    cleaned = re.sub(r"<([^<>\n]+)>", r"`\1`", text)
    cleaned = cleaned.replace("<", "").replace(">", "")
    cleaned = re.sub(r"release-notes template", "release notes", cleaned, flags=re.IGNORECASE)
    return cleaned.strip()


def collect_change_bullets(repo: Path, base_sha: str | None, head_ref: str) -> list[str]:
    rev_range = f"{base_sha}..{head_ref}" if base_sha else f"{head_ref}~1..{head_ref}"
    proc = subprocess.run(
        ["git", "-C", str(repo), "log", "--first-parent", "--format=%H%x1f%s%x1f%b%x1e", rev_range],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return []

    bullets: list[str] = []
    seen: set[str] = set()
    for record in proc.stdout.split("\x1e"):
        record = record.strip()
        if not record:
            continue
        fields = record.split("\x1f")
        if len(fields) < 2:
            continue
        sha = fields[0].strip()
        subject = fields[1].strip()
        body = fields[2].strip() if len(fields) > 2 else ""

        pr_match = MERGE_PR_RE.match(subject)
        if pr_match:
            pr_num = pr_match.group(1)
            title_lines = [line.strip() for line in body.splitlines() if line.strip()]
            title = title_lines[0] if title_lines else subject
            entry = f"{sanitize_note_text(title)} (#{pr_num})"
        else:
            if subject.startswith("Merge remote-tracking branch ") or subject.startswith("Merge branch "):
                continue
            entry = f"{sanitize_note_text(subject)} ({sha[:7]})"

        if entry and entry not in seen:
            seen.add(entry)
            bullets.append(f"- {entry}")
    return bullets


def build_release_notes(
    repo: Path,
    version: str,
    build: int,
    engine_stamp: str,
    base_sha: str | None,
    head_ref: str,
) -> tuple[str, str]:
    manual_path = repo / "docs/release/notes" / f"{version}.md"
    if manual_path.is_file():
        existing = manual_path.read_text(encoding="utf-8")
        if not re.search(r"<[^>]+>|release-notes template", existing):
            return existing, "manual"

    bullets = collect_change_bullets(repo, base_sha, head_ref)
    if not bullets:
        short_sha = git(repo, "rev-parse", "--short", head_ref).strip()
        bullets = [f"- Maintenance and reliability update ({short_sha})."]

    header = (
        f"# Open {version} ({build})\n\n"
        f"Engine: {engine_stamp}. macOS 26 or later, Apple silicon.\n\n"
        "## What changed\n"
    )
    lines = [header]
    total = len(header.encode("utf-8"))
    for idx, bullet in enumerate(bullets):
        line = bullet + "\n"
        encoded = line.encode("utf-8")
        if total + len(encoded) > MAX_NOTES_BYTES:
            remaining = len(bullets) - idx
            lines.append(f"- Plus {remaining} additional merged change(s).\n")
            break
        lines.append(line)
        total += len(encoded)
    return "".join(lines), "generated"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--head", default="HEAD")
    parser.add_argument(
        "--feed-url",
        default="https://sergeserb2.github.io/open-releases/appcast.xml",
    )
    parser.add_argument("--feed-file", type=Path, help="Local appcast.xml override (testing/offline)")
    parser.add_argument(
        "--releases-repo",
        default="SergeSerb2/open-releases",
        help="Target GitHub releases repository (owner/name)",
    )
    parser.add_argument(
        "--releases-remote-url",
        default="https://github.com/SergeSerb2/open-releases.git",
        help="Git URL for reading existing release tags (set empty to skip)",
    )
    parser.add_argument(
        "--origin-remote-url",
        default="origin",
        help="Git remote name or URL for reading source release tags (set empty to skip)",
    )
    parser.add_argument(
        "--allow-offline-feed",
        action="store_true",
        help="Allow falling back to project.yml if live appcast.xml or remote tags cannot be fetched",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write computed version/build into project.yml and notes into docs/release/notes/<ver>.md",
    )
    args = parser.parse_args(argv)

    repo = args.repo.resolve()
    project_yml = repo / "project.yml"
    info_plist = repo / "App/Info.plist"

    proj_ver_str, proj_build = read_project_version(project_yml)
    proj_ver = parse_semver(proj_ver_str)
    plist_data = plistlib.loads(info_plist.read_bytes())
    engine_stamp = str(plist_data.get("OpenEngineStamp", "")).strip() or "Chromium · CEF"

    feed_versions: list[tuple[int, int, int]] = []
    latest_feed_pair: tuple[tuple[int, int, int], int] | None = None
    feed_status = "ok"
    try:
        feed_versions, latest_feed_pair = fetch_feed(args.feed_url, args.feed_file)
    except (OSError, urllib.error.URLError, ET.ParseError, RuntimeError) as exc:
        if not args.allow_offline_feed:
            raise SystemExit(f"FAIL: could not fetch live appcast feed ({args.feed_url}): {exc}")
        feed_status = f"offline ({exc})"

    releases_tags = (
        ls_remote_semver_tags(args.releases_remote_url, allow_failure=args.allow_offline_feed)
        if args.releases_remote_url
        else {}
    )
    origin_tags = (
        ls_remote_semver_tags(args.origin_remote_url, allow_failure=args.allow_offline_feed)
        if args.origin_remote_url
        else {}
    )

    published_versions = set(feed_versions) | set(releases_tags.keys()) | set(origin_tags.keys())
    latest_published_ver = max(published_versions) if published_versions else None
    latest_feed_ver = latest_feed_pair[0] if latest_feed_pair else None
    latest_feed_build = latest_feed_pair[1] if latest_feed_pair else None

    if latest_published_ver is None:
        next_ver = proj_ver
    elif proj_ver > latest_published_ver:
        next_ver = proj_ver
    else:
        next_ver = bump_patch(latest_published_ver)

    if latest_feed_build is None:
        next_build = proj_build
    else:
        next_build = max(latest_feed_build + 1, proj_build)
        if next_build <= latest_feed_build:
            next_build = latest_feed_build + 1

    next_ver_str = format_semver(next_ver)
    last_sha, last_sha_source = find_last_released_sha(
        repo=repo,
        origin_tags=origin_tags,
        latest_feed_version=latest_feed_ver,
        releases_repo=args.releases_repo if args.releases_remote_url else None,
    )

    notes_text, notes_source = build_release_notes(
        repo=repo,
        version=next_ver_str,
        build=next_build,
        engine_stamp=engine_stamp,
        base_sha=last_sha,
        head_ref=args.head,
    )

    notes_path = repo / "docs/release/notes" / f"{next_ver_str}.md"
    if args.apply:
        write_project_version(project_yml, next_ver_str, next_build)
        notes_path.parent.mkdir(parents=True, exist_ok=True)
        notes_path.write_text(notes_text, encoding="utf-8")

    head_sha = git(repo, "rev-parse", args.head).strip()
    summary = {
        "head_sha": head_sha,
        "last_released_sha": last_sha,
        "last_released_source": last_sha_source,
        "latest_published_version": format_semver(latest_published_ver) if latest_published_ver else None,
        "latest_feed_version": format_semver(latest_feed_ver) if latest_feed_ver else None,
        "latest_feed_build": latest_feed_build,
        "project_yml_version": proj_ver_str,
        "project_yml_build": proj_build,
        "next_version": next_ver_str,
        "next_build": next_build,
        "tag": f"v{next_ver_str}",
        "notes_path": str(notes_path),
        "notes_source": notes_source,
        "notes_bytes": len(notes_text.encode("utf-8")),
        "feed_status": feed_status,
        "applied": bool(args.apply),
    }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
