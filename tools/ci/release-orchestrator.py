#!/usr/bin/env python3
"""Smart per-PR release orchestrator for Open (runs locally on M5 macOS).

Wraps tools/release.sh with:
  1. Origin-main ancestry verification (never ships non-main branches).
  2. Release-relevance filtering (skips docs/CI/SyncServer-only merges).
  3. Automatic monotonic version + build planning and sanitized release notes.
  4. Live-feed-paired predecessor DMG caching for Sparkle binary deltas.
  5. Mid-run superseding cancellation: if a newer release-relevant PR merges to
     main while this release is still before the point-of-no-return phase
     (default: 09-dmg, ~70-80% of release wall-clock time), cleanly terminates
     tools/release.sh (including SIGTERM/SIGINT forwarding so heavy.sh/locks
     clean up), removes partial staging, and exits with code 2 (superseded) so
     the daemon immediately builds and ships both PRs together. Once at/past
     09-dmg, finishes publishing cleanly.
  6. Strict exit-code + fresh-stamp validation of every automated acceptance row
     before uploading assets to SergeSerb2/open-releases, updating gh-pages
     appcast.xml, verifying the live feed + Ed25519 signature, and pushing the
     origin v<version> tag LAST.
  7. Live GitHub commit status updates (`release/macos`) on SergeSerb2/open.

Exit codes:
  0 = published (or skipped because already released / non-release changes)
  2 = cleanly cancelled because superseded by a newer release-relevant main commit
  1 / other = build, verification, or publish failure
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
EXIT_SUPERSEDED = 2

PHASE_ORDER = [
    "arguments",
    "01-preflight",
    "02-engine",
    "03-notes-inputs",
    "03-version-notes",
    "04-acknowledgements",
    "05-app-build",
    "06-hygiene",
    "07-sign",
    "08-notarize-app",
    "09-dmg",
    "10-appcast",
    "11-manifest",
    "12-summary",
    "13-publish",
]

# Automated checks that MUST be PASS in production before any artifact is published.
REQUIRED_PROD_PASS_ROWS = ("A-1", "A-4", "A-5", "A-6", "A-7", "A-8", "A-9", "A-10", "A-15")
# Rows that release.sh marks FAIL solely because automated CI obeys the M5 STOP-rule
# (no automated exact-artifact GUI launch on M5) or because A-12 checks the live URL
# before assets are uploaded (re-verified post-upload in publish_release).
ALLOWED_PRE_PUBLISH_PENDING_ROWS = frozenset({"A-2", "A-3", "A-11", "A-12", "A-13", "A-14"})
REQUIRED_DRY_PASS_ROWS = ("A-4", "A-8", "A-9", "A-10", "A-15")


def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    print(f"[release-orchestrator {ts}] {msg}", flush=True)


def phase_index(phase: str) -> int:
    try:
        return PHASE_ORDER.index(phase.strip())
    except ValueError:
        return len(PHASE_ORDER)


def is_past_no_cancel(current_phase: str, cutoff_phase: str) -> bool:
    if not current_phase:
        return False
    return phase_index(current_phase) >= phase_index(cutoff_phase)


def run_cmd(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    capture: bool = True,
    check: bool = True,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        capture_output=capture,
        check=check,
        timeout=timeout,
    )


def load_optional_token_file() -> str:
    """Optionally read a fine-grained PAT from ~/.config/open-release/token (mode 600)."""
    token_path = Path(os.environ.get("OPEN_RELEASES_TOKEN_FILE", str(Path.home() / ".config/open-release/token")))
    if not token_path.is_file():
        return ""
    mode = stat.S_IMODE(token_path.stat().st_mode)
    if mode & 0o077:
        raise RuntimeError(f"refusing insecure token file {token_path} (mode {oct(mode)}; must be 0600)")
    return token_path.read_text(encoding="utf-8").strip()


def gh_publish_env() -> dict[str, str]:
    """Environment for gh calls targeting SergeSerb2/open-releases and status reporting."""
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
    explicit = env.get("OPEN_RELEASES_TOKEN", "").strip() or load_optional_token_file()
    if explicit:
        env["GH_TOKEN"] = explicit
        env.pop("GITHUB_TOKEN", None)
    else:
        env.pop("GH_TOKEN", None)
        env.pop("GITHUB_TOKEN", None)
    return env


def gh_origin_env() -> dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
    return env


def post_commit_status(
    source_repo: str,
    sha: str,
    state: str,
    description: str,
    target_url: str = "",
    enabled: bool = True,
) -> None:
    if not enabled or not source_repo or not sha:
        return
    cmd = [
        "gh",
        "api",
        "-X",
        "POST",
        f"repos/{source_repo}/statuses/{sha}",
        "-f",
        f"state={state}",
        "-f",
        "context=release/macos",
        "-f",
        f"description={description[:140]}",
    ]
    if target_url:
        cmd.extend(["-f", f"target_url={target_url}"])
    proc = run_cmd(cmd, env=gh_origin_env(), check=False, timeout=20)
    if proc.returncode != 0:
        log(f"WARN: failed to post release/macos status ({state}) on {sha[:10]}: {proc.stderr.strip()}")


def remote_main_sha(repo: Path, branch: str = "main") -> str | None:
    proc = run_cmd(
        ["git", "-C", str(repo), "ls-remote", "origin", f"refs/heads/{branch}"],
        check=False,
        timeout=20,
    )
    if proc.returncode != 0:
        return None
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] == f"refs/heads/{branch}":
            return parts[0].strip()
    return None


def check_relevant(repo: Path, base: str, head: str, *, check_markers: bool = True) -> dict:
    script = repo / "tools/ci/check-release-relevant.py"
    cmd = [sys.executable, str(script), "--repo", str(repo), "--base", base, "--head", head]
    if check_markers:
        cmd.append("--check-markers")
    proc = run_cmd(cmd, check=True, timeout=30)
    return json.loads(proc.stdout)


def run_planner(
    repo: Path,
    *,
    head: str,
    feed_url: str,
    releases_repo: str,
    apply: bool,
    allow_offline_feed: bool,
) -> dict:
    script = repo / "tools/ci/plan-release.py"
    cmd = [
        sys.executable,
        str(script),
        "--repo",
        str(repo),
        "--head",
        head,
        "--feed-url",
        feed_url,
        "--releases-repo",
        releases_repo,
        "--releases-remote-url",
        f"https://github.com/{releases_repo}.git",
    ]
    if apply:
        cmd.append("--apply")
    if allow_offline_feed:
        cmd.append("--allow-offline-feed")
    proc = run_cmd(cmd, check=True, timeout=60)
    return json.loads(proc.stdout)


def fetch_validated_feed_bytes(feed_url: str) -> bytes:
    req = urllib.request.Request(feed_url, headers={"User-Agent": "open-release-orch/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read(4 * 1024 * 1024 + 1)
    if len(raw) > 4 * 1024 * 1024:
        raise RuntimeError("live appcast feed exceeds 4 MiB")
    ET.fromstring(raw)
    return raw


def atomic_write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    try:
        tmp.write_bytes(data)
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


def seed_predecessor_cache(
    repo: Path,
    cache_dir: Path,
    feed_version: str | None,
    feed_build: int | None,
    releases_repo: str,
    feed_url: str,
    dry_run: bool,
) -> None:
    """Populate build/release/<feed_ver>-<feed_build> for Sparkle delta generation.

    Uses the matched (version, build) pair from the live appcast.xml and always
    refreshes appcast.xml from the live feed atomically (never trusting a stale
    cached feed that might reintroduce removed items).
    """
    if dry_run or not feed_version or not feed_build:
        return
    key = f"{feed_version}-{feed_build}"
    cached = cache_dir / key
    dmg_name = f"Open-{feed_version}.dmg"
    cached_dmg = cached / dmg_name
    cached_manifest = cached / "RELEASE-MANIFEST.txt"
    cached_feed = cached / "appcast.xml"

    try:
        live_feed_bytes = fetch_validated_feed_bytes(feed_url)
        atomic_write_bytes(cached_feed, live_feed_bytes)
    except Exception as exc:
        log(f"WARN: could not refresh live appcast.xml for predecessor {key} ({exc}); skipping delta seeding")
        return

    if not (cached_dmg.is_file() and cached_manifest.is_file()):
        log(f"Seeding predecessor DMG for {key} from {releases_repo}")
        cached.mkdir(parents=True, exist_ok=True)
        dmg_url = f"https://github.com/{releases_repo}/releases/download/v{feed_version}/{dmg_name}"
        tmp_dmg = cached / f"{dmg_name}.part.{os.getpid()}"
        try:
            run_cmd(
                ["curl", "-fsSL", "--retry", "2", "--max-time", "180", "-o", str(tmp_dmg), dmg_url],
                check=True,
                timeout=200,
            )
            tmp_dmg.replace(cached_dmg)
            manifest_lines = [
                f"marketing={feed_version}",
                f"build={feed_build}",
                "mode=production",
                "channel=stable",
            ]
            atomic_write_bytes(cached_manifest, ("\n".join(manifest_lines) + "\n").encode("utf-8"))
            log(f"Predecessor DMG cached at {cached_dmg}")
        except Exception as exc:
            tmp_dmg.unlink(missing_ok=True)
            log(f"WARN: could not download predecessor DMG {key} ({exc}); continuing with full DMG")
            return

    dest = repo / "build/release" / key
    dest.mkdir(parents=True, exist_ok=True)
    for fname in (dmg_name, "RELEASE-MANIFEST.txt", "appcast.xml"):
        src = cached / fname
        dst = dest / fname
        if src.is_file():
            dst.unlink(missing_ok=True)
            try:
                os.link(src, dst)
            except OSError:
                shutil.copy2(src, dst)
    log(f"Predecessor {key} linked into {dest} for Sparkle delta generation")


def save_predecessor_and_prune(
    rel_dir: Path,
    cache_dir: Path,
    symbols_dir: Path,
    version: str,
    build: int,
) -> None:
    key = f"{version}-{build}"
    dmg_name = f"Open-{version}.dmg"
    dst = cache_dir / key
    dst.mkdir(parents=True, exist_ok=True)
    for fname in (dmg_name, "RELEASE-MANIFEST.txt", "appcast.xml"):
        src = rel_dir / fname
        if src.is_file():
            shutil.copy2(src, dst / fname)

    preds = sorted(
        (p for p in cache_dir.iterdir() if p.is_dir()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for old in preds[2:]:
        log(f"Pruning old predecessor cache {old.name}")
        shutil.rmtree(old, ignore_errors=True)

    src_syms = rel_dir / "symbols"
    if src_syms.is_dir():
        sym_dst = symbols_dir / key
        if sym_dst.exists():
            shutil.rmtree(sym_dst, ignore_errors=True)
        sym_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src_syms, sym_dst, symlinks=True)
        sym_dirs = sorted(
            (p for p in symbols_dir.iterdir() if p.is_dir()),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        for old in sym_dirs[5:]:
            log(f"Pruning old archived symbols {old.name}")
            shutil.rmtree(old, ignore_errors=True)


def clear_stale_release_lock(rel_dir: Path) -> None:
    """Remove a stale .release-lock left by SIGKILL or power loss if its PID is dead."""
    lock_dir = rel_dir / ".release-lock"
    if not lock_dir.is_dir():
        return
    pid_file = lock_dir / "pid"
    pid: int | None = None
    if pid_file.is_file():
        text = pid_file.read_text(encoding="utf-8").strip()
        if text.isdecimal():
            pid = int(text)
    if pid is not None and pid > 1:
        try:
            os.kill(pid, 0)
            raise RuntimeError(f"live process PID {pid} still owns {lock_dir}; refusing to steal lock")
        except ProcessLookupError:
            pass
        except PermissionError:
            raise RuntimeError(f"process PID {pid} still owns {lock_dir}; refusing to steal lock")
    log(f"Removing stale {lock_dir} (dead or missing PID {pid})")
    pid_file.unlink(missing_ok=True)
    try:
        lock_dir.rmdir()
    except OSError:
        shutil.rmtree(lock_dir, ignore_errors=True)


def terminate_process_group(proc: subprocess.Popen[str] | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        pgid = os.getpgid(proc.pid)
    except ProcessLookupError:
        return
    log(f"Sending SIGTERM to release.sh process group {pgid}")
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 25.0
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.5)
    log(f"release.sh process group {pgid} did not exit within 25s; sending SIGKILL")
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def parse_acceptance_tsv(path: Path) -> dict[str, tuple[str, str]]:
    if not path.is_file():
        raise RuntimeError(f"missing acceptance table: {path}")
    rows: dict[str, tuple[str, str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        rows[parts[0].strip()] = (parts[1].strip(), parts[2].strip())
    return rows


def verify_automated_acceptance(
    rel_dir: Path,
    version: str,
    dry_run: bool,
    exit_code: int,
    run_started_at: float,
) -> dict[str, tuple[str, str]]:
    if exit_code not in (0, 1):
        raise RuntimeError(f"tools/release.sh exited abnormally with code {exit_code} (expected 0 or 1)")

    summary_result = rel_dir / ".stamps/12-summary.result"
    if not summary_result.is_file():
        raise RuntimeError(f"tools/release.sh exited {exit_code} without producing 12-summary.result")
    # Allow 2s filesystem timestamp granularity tolerance
    if summary_result.stat().st_mtime + 2.0 < run_started_at:
        raise RuntimeError(f"12-summary.result is stale (not written during this run); refusing to publish")

    rows = parse_acceptance_tsv(rel_dir / ".staging/acceptance.tsv")
    if len(rows) != 15:
        raise RuntimeError(f"expected 15 acceptance rows, got {len(rows)}")

    required = REQUIRED_DRY_PASS_ROWS if dry_run else REQUIRED_PROD_PASS_ROWS
    failures: list[str] = []
    for row_id in required:
        status, evidence = rows.get(row_id, ("MISSING", ""))
        if status != "PASS":
            failures.append(f"{row_id}={status} ({evidence})")

    if not dry_run:
        # Ensure no unexpected row failed outside the explicitly allowed manual/pre-upload set
        for row_id, (status, evidence) in rows.items():
            if status != "PASS" and row_id not in ALLOWED_PRE_PUBLISH_PENDING_ROWS:
                failures.append(f"unexpected non-PASS row {row_id}={status} ({evidence})")

    # A-11 combines automated DMG mount/signature/entitlement checks with manual launch.
    a11_status, a11_evidence = rows.get("A-11", ("MISSING", ""))
    if not a11_evidence.startswith("DMG verified, mounted, exact entitlements verified, detached;"):
        failures.append(f"A-11 DMG verification incomplete: {a11_status} ({a11_evidence})")

    appcast_result_file = rel_dir / ".stamps/10-appcast.result"
    if not appcast_result_file.is_file() or not appcast_result_file.read_text().startswith("PASS\t"):
        failures.append("phase 10-appcast did not PASS")

    dmg_path = rel_dir / f"Open-{version}.dmg"
    sha_path = rel_dir / f"Open-{version}.dmg.sha256"
    if not dmg_path.is_file() or not sha_path.is_file():
        failures.append(f"missing DMG or checksum at {dmg_path}")
    else:
        run_cmd(["shasum", "-a", "256", "-c", sha_path.name], cwd=rel_dir, check=True)

    if failures:
        raise RuntimeError("automated release acceptance failed:\n  - " + "\n  - ".join(failures))
    return rows


def create_git_askpass(tmpdir: Path) -> Path:
    script = tmpdir / "git-askpass.sh"
    script.write_text(
        "#!/bin/sh\n"
        'case "$1" in\n'
        '  *Username*|*username*) printf "%s\\n" "x-access-token" ;;\n'
        '  *) printf "%s\\n" "$OPEN_GIT_ASKPASS_TOKEN" ;;\n'
        "esac\n",
        encoding="utf-8",
    )
    os.chmod(script, stat.S_IRWXU)
    return script


def publish_release(
    *,
    repo: Path,
    rel_dir: Path,
    version: str,
    build: int,
    head_sha: str,
    releases_repo: str,
    feed_url: str,
    phase_file: Path,
) -> str:
    """Publish in strict order:
    1. Upload assets to SergeSerb2/open-releases (fail if tag belongs to another commit)
    2. Verify live HTTP HEAD + exact Content-Length on DMG and every .delta
    3. Push appcast.xml + release-notes/<ver>.md to gh-pages
    4. Wait for and verify live appcast.xml XML + Ed25519 signature
    5. Push annotated tag v<ver> to origin (SergeSerb2/open) LAST so a failed
       publish can never look already-released.
    """
    phase_file.write_text("13-publish\n", encoding="utf-8")
    tag = f"v{version}"
    dmg_name = f"Open-{version}.dmg"
    dmg_path = rel_dir / dmg_name
    sha_path = rel_dir / f"{dmg_name}.sha256"
    body_path = rel_dir / "release-body.md"
    notes_path = rel_dir / f"Open-{version}.md"
    feed_path = rel_dir / "appcast.xml"

    body_text = body_path.read_text(encoding="utf-8").rstrip()
    if f"Source commit: {head_sha}" not in body_text:
        body_text += f"\nSource commit: {head_sha}\n"
    body_path.write_text(body_text, encoding="utf-8")

    # 1. Upload assets to SergeSerb2/open-releases FIRST
    rel_env = gh_publish_env()
    assets = [str(dmg_path), str(sha_path)]
    deltas = sorted(rel_dir.glob("*.delta"))
    assets.extend(str(p) for p in deltas)
    for extra in ("Acknowledgements.txt", "CREDITS.html"):
        p = rel_dir / extra
        if p.is_file():
            assets.append(str(p))

    existing = run_cmd(
        ["gh", "release", "view", tag, "--repo", releases_repo, "--json", "body"],
        env=rel_env,
        check=False,
        timeout=20,
    )
    if existing.returncode == 0:
        existing_body = ""
        try:
            existing_body = json.loads(existing.stdout).get("body", "")
        except ValueError:
            pass
        if f"Source commit: {head_sha}" not in existing_body:
            raise RuntimeError(
                f"refusing to overwrite existing release {tag} on {releases_repo}: "
                f"it does not belong to Source commit {head_sha}"
            )
        log(f"Release {tag} already exists for this exact commit {head_sha[:10]}; re-uploading assets with --clobber")
        run_cmd(
            ["gh", "release", "upload", tag, "--repo", releases_repo, "--clobber", *assets],
            env=rel_env,
            capture=False,
            check=True,
            timeout=600,
        )
    else:
        log(f"Creating GitHub Release {tag} on {releases_repo} ({len(assets)} asset(s))")
        run_cmd(
            [
                "gh",
                "release",
                "create",
                tag,
                "--repo",
                releases_repo,
                "--target",
                "main",
                "--title",
                f"Open {version}",
                "--notes-file",
                str(body_path),
                *assets,
            ],
            env=rel_env,
            capture=False,
            check=True,
            timeout=600,
        )

    # 2. Verify live uploaded assets before touching appcast.xml
    prefix = f"https://github.com/{releases_repo}/releases/download/{tag}/"
    for check_file in [dmg_path, *deltas]:
        url = prefix + check_file.name
        expected_len = check_file.stat().st_size
        headers = run_cmd(
            ["curl", "-fsIL", "--retry", "3", "--connect-timeout", "10", "--max-time", "30", url],
            check=True,
            timeout=60,
        ).stdout
        lengths = [
            int(line.split(":", 1)[1].strip())
            for line in headers.splitlines()
            if line.lower().startswith("content-length:")
        ]
        if not lengths or lengths[-1] != expected_len:
            raise RuntimeError(f"live asset {url} Content-Length mismatch: got {lengths}, expected {expected_len}")
        log(f"Verified live asset {check_file.name} ({expected_len} bytes)")

    # 3. Publish Sparkle appcast.xml + release-notes/<version>.md to gh-pages
    token = rel_env.get("GH_TOKEN") or run_cmd(["gh", "auth", "token"], env=rel_env, check=True, timeout=15).stdout.strip()
    if not token:
        raise RuntimeError("could not obtain GitHub token for gh-pages push to " + releases_repo)

    with tempfile.TemporaryDirectory(prefix="open-gh-pages-") as tmp:
        tmp_path = Path(tmp)
        askpass = create_git_askpass(tmp_path)
        git_env = dict(rel_env)
        git_env["GIT_ASKPASS"] = str(askpass)
        git_env["GIT_TERMINAL_PROMPT"] = "0"
        git_env["OPEN_GIT_ASKPASS_TOKEN"] = token
        pages_dir = tmp_path / "pages"
        pages_url = f"https://github.com/{releases_repo}.git"
        run_cmd(
            ["git", "clone", "--quiet", "--single-branch", "--branch", "gh-pages", pages_url, str(pages_dir)],
            env=git_env,
            check=True,
            timeout=60,
        )
        shutil.copy2(feed_path, pages_dir / "appcast.xml")
        (pages_dir / "release-notes").mkdir(parents=True, exist_ok=True)
        shutil.copy2(notes_path, pages_dir / "release-notes" / f"{version}.md")
        run_cmd(["git", "-C", str(pages_dir), "add", "--", "appcast.xml", f"release-notes/{version}.md"], env=git_env, check=True)
        diff = run_cmd(["git", "-C", str(pages_dir), "diff", "--cached", "--quiet"], env=git_env, check=False)
        if diff.returncode != 0:
            run_cmd(
                [
                    "git",
                    "-C",
                    str(pages_dir),
                    "-c",
                    "user.name=Open Release Bot",
                    "-c",
                    "user.email=open-release-bot@users.noreply.github.com",
                    "commit",
                    "-qm",
                    f"Publish Open {version} ({build}) stable feed",
                ],
                env=git_env,
                check=True,
            )
            run_cmd(["git", "-C", str(pages_dir), "push", "origin", "gh-pages"], env=git_env, check=True, timeout=60)
            log(f"Pushed appcast.xml and release-notes/{version}.md to {releases_repo} gh-pages")

    # 4. Wait for GitHub Pages to serve the new feed and verify live Ed25519 signature
    verify_live_feed(
        repo=repo,
        rel_dir=rel_dir,
        version=version,
        build=build,
        feed_url=feed_url,
        expected_dmg_url=prefix + dmg_name,
    )

    # 5. Push annotated tag v<VERSION> on SergeSerb2/open (origin) LAST
    info_plist = plistlib.loads((repo / "App/Info.plist").read_bytes())
    engine_stamp = info_plist.get("OpenEngineStamp", "")
    tag_msg = f"Open {version} ({build}) · {engine_stamp}"
    log(f"Creating and pushing annotated tag {tag} on origin at {head_sha[:10]}")
    origin_token = run_cmd(["gh", "auth", "token"], env=gh_origin_env(), check=False, timeout=15).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="open-origin-tag-") as tmp:
        git_env = gh_origin_env()
        if origin_token:
            askpass = create_git_askpass(Path(tmp))
            git_env["GIT_ASKPASS"] = str(askpass)
            git_env["GIT_TERMINAL_PROMPT"] = "0"
            git_env["OPEN_GIT_ASKPASS_TOKEN"] = origin_token
        run_cmd(["git", "-C", str(repo), "tag", "-f", "-a", tag, "-m", tag_msg, head_sha], env=git_env, check=True)
        run_cmd(["git", "-C", str(repo), "push", "origin", f"refs/tags/{tag}"], env=git_env, check=True, timeout=60)

    return f"https://github.com/{releases_repo}/releases/tag/{tag}"


def verify_live_feed(
    *,
    repo: Path,
    rel_dir: Path,
    version: str,
    build: int,
    feed_url: str,
    expected_dmg_url: str,
) -> None:
    log(f"Waiting up to 600s for GitHub Pages to serve build {build} at {feed_url}")
    deadline = time.monotonic() + 600.0
    live_xml = b""
    while time.monotonic() < deadline:
        try:
            cache_bust = f"{feed_url}?t={int(time.time())}"
            req = urllib.request.Request(cache_bust, headers={"User-Agent": "open-release-verify/1.0"})
            with urllib.request.urlopen(req, timeout=20) as resp:
                body = resp.read(4 * 1024 * 1024 + 1)
            root = ET.fromstring(body)
            items = [i for i in root.iter("item") if (i.findtext(SPARKLE_NS + "version") or "").strip() == str(build)]
            if len(items) == 1:
                live_xml = body
                break
        except (OSError, urllib.error.URLError, ET.ParseError):
            pass
        time.sleep(10)

    if not live_xml:
        raise RuntimeError(f"timed out waiting for {feed_url} to serve build {build}")

    with tempfile.TemporaryDirectory(prefix="open-live-verify-") as tmp:
        tmp_path = Path(tmp)
        feed_file = tmp_path / "appcast.xml"
        feed_file.write_bytes(live_xml)
        run_cmd(["xmllint", "--noout", str(feed_file)], check=True)
        root = ET.fromstring(live_xml)
        item = next(i for i in root.iter("item") if (i.findtext(SPARKLE_NS + "version") or "").strip() == str(build))
        enclosure = item.find("enclosure")
        dmg_path = rel_dir / f"Open-{version}.dmg"
        if item.findtext(SPARKLE_NS + "shortVersionString") != version:
            raise RuntimeError("live appcast shortVersionString mismatch")
        if enclosure is None or enclosure.get("url") != expected_dmg_url:
            raise RuntimeError(f"live appcast enclosure URL mismatch: {enclosure.get('url') if enclosure is not None else None}")
        if enclosure.get("length") != str(dmg_path.stat().st_size):
            raise RuntimeError("live appcast enclosure length mismatch")
        public_key = plistlib.loads((repo / "App/Info.plist").read_bytes())["SUPublicEDKey"]
        verifier = rel_dir / ".staging/verify-ed25519"
        run_cmd(
            [str(verifier), public_key, enclosure.get(SPARKLE_NS + "edSignature", ""), str(dmg_path)],
            check=True,
        )
    log(f"Live appcast XML, enclosure URL/length, and Ed25519 signature verified for {version} ({build})")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--source-repo", default="SergeSerb2/open")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--releases-repo", default="SergeSerb2/open-releases")
    parser.add_argument("--feed-url", default="https://sergeserb2.github.io/open-releases/appcast.xml")
    parser.add_argument(
        "--no-cancel-phase",
        default=os.environ.get("OPEN_RELEASE_NO_CANCEL_PHASE", "09-dmg"),
        help="Phase at/after which a running release is 'nearly done' and will NOT be cancelled (default: 09-dmg)",
    )
    parser.add_argument(
        "--poll-seconds",
        type=float,
        default=float(os.environ.get("OPEN_RELEASE_POLL_SECONDS", "12")),
        help="Seconds between origin/main checks during cancellable phases",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=float(os.environ.get("OPEN_RELEASE_TIMEOUT_SECONDS", "5400")),
        help="Hard timeout for tools/release.sh (default: 5400s = 90m)",
    )
    parser.add_argument("--force", action="store_true", help="Release even if only non-release files changed")
    parser.add_argument("--dry-run", action="store_true", help="Run tools/release.sh --dry-run and skip publishing")
    parser.add_argument("--no-status", action="store_true", help="Do not post release/macos commit statuses to GitHub")
    args = parser.parse_args(argv)

    if args.no_cancel_phase not in PHASE_ORDER:
        parser.error(f"unknown --no-cancel-phase {args.no_cancel_phase!r}; choose from {', '.join(PHASE_ORDER)}")

    repo = args.repo.resolve()
    post_status = not args.no_status and not args.dry_run

    run_cmd(["git", "-C", str(repo), "fetch", "--quiet", "origin", args.branch, "--tags"], check=False, timeout=60)
    head_sha = run_cmd(["git", "-C", str(repo), "rev-parse", "HEAD"], check=True).stdout.strip()
    log(f"Starting release orchestrator for {head_sha[:10]} (no-cancel cutoff: {args.no_cancel_phase}, dry_run={args.dry_run})")

    # Guard: production releases may only ever ship commits on origin/<branch>
    if not args.dry_run:
        anc = run_cmd(
            ["git", "-C", str(repo), "merge-base", "--is-ancestor", head_sha, f"origin/{args.branch}"],
            check=False,
        )
        if anc.returncode != 0:
            raise SystemExit(f"FAIL: HEAD {head_sha[:10]} is not an ancestor of origin/{args.branch}; refusing to release")

    # Step 0a: Already superseded before starting?
    latest_main = remote_main_sha(repo, args.branch)
    if latest_main and latest_main != head_sha and not args.dry_run:
        run_cmd(["git", "-C", str(repo), "fetch", "--quiet", "origin", args.branch], check=False, timeout=30)
        rel_check = check_relevant(repo, head_sha, latest_main, check_markers=True)
        if rel_check["relevant"]:
            log(f"Superseded before start by {latest_main[:10]} ({rel_check['reason']})")
            return EXIT_SUPERSEDED
        log(f"origin/{args.branch} moved to {latest_main[:10]}, but diff is non-release ({rel_check['reason']}); continuing")

    # Step 0b: Plan version & check if there are release-relevant changes since last live release
    plan = run_planner(
        repo,
        head=head_sha,
        feed_url=args.feed_url,
        releases_repo=args.releases_repo,
        apply=False,
        allow_offline_feed=args.dry_run,
    )
    last_sha = plan["last_released_sha"]
    log(
        f"Planned version {plan['next_version']} (build {plan['next_build']}) "
        f"[last released: {last_sha[:10] if last_sha else 'none'} via {plan['last_released_source']}]"
    )

    if not args.force and not args.dry_run:
        if last_sha == head_sha:
            log(f"Commit {head_sha[:10]} is already live as v{plan['latest_feed_version']}; skipping")
            return 0
        if last_sha:
            since_last = check_relevant(repo, last_sha, head_sha, check_markers=True)
            if not since_last["relevant"]:
                log(f"No release-relevant changes since {last_sha[:10]}: {since_last['reason']}")
                return 0

    # Step 1: Apply version bump + release notes in workspace & seed live-feed-paired predecessor cache
    plan = run_planner(
        repo,
        head=head_sha,
        feed_url=args.feed_url,
        releases_repo=args.releases_repo,
        apply=True,
        allow_offline_feed=args.dry_run,
    )
    version = plan["next_version"]
    build = int(plan["next_build"])
    rel_dir = repo / "build/release" / f"{version}-{build}"

    post_commit_status(
        args.source_repo,
        head_sha,
        "pending",
        f"Building & notarizing Open v{version} (build {build}) on M5",
        enabled=post_status,
    )

    dist_root = Path(os.environ.get("OPEN_RELEASE_DIST_ROOT", str(Path.home() / "Developer/open-dist")))
    cache_dir = dist_root / "ci-predecessor"
    symbols_dir = dist_root / "ci-symbols"
    seed_predecessor_cache(
        repo=repo,
        cache_dir=cache_dir,
        feed_version=plan["latest_feed_version"],
        feed_build=plan["latest_feed_build"],
        releases_repo=args.releases_repo,
        feed_url=args.feed_url,
        dry_run=args.dry_run,
    )

    # Step 2: Run tools/release.sh with signal forwarding + phase-aware cancellation supervisor
    active_proc: dict[str, subprocess.Popen[str] | None] = {"proc": None}
    external_signal: dict[str, int | None] = {"sig": None}
    stop_watch = threading.Event()

    class _ExternalSignal(BaseException):
        def __init__(self, signum: int) -> None:
            self.signum = signum

    def on_signal(signum: int, _frame: object) -> None:
        # Never call proc.poll()/proc.wait() inside a signal handler (deadlocks
        # subprocess._waitpid_lock if main thread is inside proc.wait()). Raise a
        # BaseException to unwind proc.wait() cleanly, then terminate outside.
        external_signal["sig"] = signum
        stop_watch.set()
        raise _ExternalSignal(signum)

    prev_sigterm = signal.signal(signal.SIGTERM, on_signal)
    prev_sigint = signal.signal(signal.SIGINT, on_signal)

    try:
        with tempfile.TemporaryDirectory(prefix="open-release-orch-") as orch_tmp:
            phase_file = Path(orch_tmp) / "current-phase.txt"
            phase_file.write_text("arguments\n", encoding="utf-8")

            # Strip GitHub tokens from build env so xcodebuild/SwiftPM/scripts never see them.
            rel_env = dict(os.environ)
            for secret_key in ("OPEN_RELEASES_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "OPEN_GIT_ASKPASS_TOKEN"):
                rel_env.pop(secret_key, None)
            rel_env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + rel_env.get("PATH", "")
            rel_env.setdefault("OPEN_ENGINE_ROOT", str(Path.home() / "Developer/open-engine"))
            rel_env.setdefault("OPEN_BUILD_JOBS", "6")
            rel_env.setdefault("OPEN_SIGN_IDENTITY", "Developer ID Application: Serge Serbinenko (78A5P57U23)")
            rel_env.setdefault("OPEN_NOTARY_PROFILE", "open-notary")
            rel_env.setdefault("OPEN_SPARKLE_KEY_ACCOUNT", "ed25519")
            rel_env["OPEN_RELEASE_FEED_URL"] = args.feed_url
            rel_env["OPEN_RELEASE_DOWNLOAD_PREFIX"] = f"https://github.com/{args.releases_repo}/releases/download/v{version}/"
            rel_env["OPEN_RELEASE_PHASE_FILE"] = str(phase_file)
            rel_env.pop("OPEN_AUTOMATION", None)
            rel_env.pop("OPEN_SPARKLE_KEY_FILE", None)

            cmd = ["/bin/bash", str(repo / "tools/release.sh")]
            if args.dry_run:
                cmd.append("--dry-run")

            if external_signal["sig"] is not None:
                return 128 + int(external_signal["sig"])

            clear_stale_release_lock(rel_dir)

            log(f"Running {' '.join(cmd)} for Open {version} ({build})")
            run_started_at = time.time()
            proc = subprocess.Popen(
                cmd,
                cwd=str(repo),
                env=rel_env,
                start_new_session=True,
            )
            active_proc["proc"] = proc
            if external_signal["sig"] is not None:
                terminate_process_group(proc)
                return 128 + int(external_signal["sig"])
            state: dict[str, object] = {
                "superseded_by": None,
                "superseded_phase": None,
                "notified_no_cancel": False,
                "timed_out": False,
            }

            def watcher() -> None:
                last_checked = head_sha
                deadline = time.monotonic() + args.timeout_seconds
                while not stop_watch.wait(args.poll_seconds):
                    if proc.poll() is not None:
                        return
                    if time.monotonic() >= deadline:
                        log(f"Hard timeout ({args.timeout_seconds}s) reached; terminating release.sh")
                        state["timed_out"] = True
                        terminate_process_group(proc)
                        return
                    if args.dry_run:
                        continue
                    remote_sha = remote_main_sha(repo, args.branch)
                    if not remote_sha or remote_sha == head_sha or remote_sha == last_checked:
                        continue
                    last_checked = remote_sha
                    try:
                        run_cmd(["git", "-C", str(repo), "fetch", "--quiet", "origin", args.branch], check=False, timeout=25)
                        diff_info = check_relevant(repo, head_sha, remote_sha, check_markers=True)
                    except Exception as exc:
                        log(f"WARN: supersede check failed for {remote_sha[:10]}: {exc}")
                        continue

                    if not diff_info["relevant"]:
                        log(f"Ignoring non-release commit {remote_sha[:10]} on {args.branch} ({diff_info['reason']})")
                        continue

                    current_phase = phase_file.read_text(encoding="utf-8").strip() if phase_file.is_file() else ""
                    if not is_past_no_cancel(current_phase, args.no_cancel_phase):
                        # Only mark superseded if release.sh is still running (never mask an early build failure)
                        if proc.poll() is not None:
                            return
                        log(
                            f"SUPERSEDED by {remote_sha[:10]} ({diff_info['reason']}) during phase "
                            f"{current_phase!r} (< {args.no_cancel_phase!r}); cancelling this build cleanly"
                        )
                        state["superseded_by"] = remote_sha
                        state["superseded_phase"] = current_phase or "unknown"
                        terminate_process_group(proc)
                        return

                    if not state["notified_no_cancel"]:
                        state["notified_no_cancel"] = True
                        log(
                            f"Newer release-relevant commit {remote_sha[:10]} landed during phase "
                            f"{current_phase!r} (>= {args.no_cancel_phase!r} point-of-no-return). "
                            f"Continuing to finish publishing v{version}; follow-up release will run next."
                        )

            watch_thread = threading.Thread(target=watcher, name="supersede-watcher", daemon=True)
            watch_thread.start()

            exit_code = proc.wait()
            stop_watch.set()
            watch_thread.join()  # Wait unconditionally so watcher never races with publish_release

            if external_signal["sig"] is not None:
                shutil.rmtree(rel_dir, ignore_errors=True)
                return 128 + int(external_signal["sig"])

            if state["timed_out"]:
                shutil.rmtree(rel_dir, ignore_errors=True)
                post_commit_status(
                    args.source_repo,
                    head_sha,
                    "failure",
                    f"Release v{version} timed out after {int(args.timeout_seconds)}s",
                    enabled=post_status,
                )
                raise RuntimeError(f"release.sh timed out after {args.timeout_seconds}s")

            if state["superseded_by"]:
                sup_sha = str(state["superseded_by"])
                sup_phase = str(state["superseded_phase"])
                log(f"Cleaning up partial staging dir {rel_dir}")
                shutil.rmtree(rel_dir, ignore_errors=True)
                post_commit_status(
                    args.source_repo,
                    head_sha,
                    "success",
                    f"Superseded at {sup_phase} by {sup_sha[:10]}; shipping together in next release",
                    enabled=post_status,
                )
                return EXIT_SUPERSEDED

            log(f"tools/release.sh exited with code {exit_code}; validating automated acceptance rows")
            verify_automated_acceptance(rel_dir, version, args.dry_run, exit_code, run_started_at)
            log("All automated release acceptance checks PASSED")

            if args.dry_run:
                log(f"Dry run complete for Open v{version} (build {build}); nothing published")
                return 0

            # Point of no return: ignore SIGTERM/SIGINT while publishing assets,
            # gh-pages feed, live verification, and origin tag so a daemon restart
            # cannot interrupt publishing halfway.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)

            release_url = publish_release(
                repo=repo,
                rel_dir=rel_dir,
                version=version,
                build=build,
                head_sha=head_sha,
                releases_repo=args.releases_repo,
                feed_url=args.feed_url,
                phase_file=phase_file,
            )

            save_predecessor_and_prune(rel_dir, cache_dir, symbols_dir, version, build)
            shutil.rmtree(rel_dir, ignore_errors=True)

            post_commit_status(
                args.source_repo,
                head_sha,
                "success",
                f"Published Open v{version} (build {build}) to Sparkle feed",
                target_url=release_url,
                enabled=post_status,
            )
            log(f"Release Open v{version} (build {build}) completed and verified live: {release_url}")
            return 0
    except _ExternalSignal as sig_exc:
        log(f"Received signal {sig_exc.signum}; terminating child release.sh process group")
        stop_watch.set()
        terminate_process_group(active_proc["proc"])
        shutil.rmtree(rel_dir, ignore_errors=True)
        return 128 + sig_exc.signum
    except Exception as exc:
        log(f"FAIL: {exc}")
        post_commit_status(
            args.source_repo,
            head_sha,
            "failure",
            f"Release v{version} failed: {exc}",
            enabled=post_status,
        )
        return 1
    finally:
        signal.signal(signal.SIGTERM, prev_sigterm)
        signal.signal(signal.SIGINT, prev_sigint)
        # Always leave ephemeral version/notes edits reset in the release checkout
        run_cmd(["git", "-C", str(repo), "checkout", "--", "project.yml"], check=False)
        run_cmd(["git", "-C", str(repo), "clean", "-fd", "docs/release/notes"], check=False)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
