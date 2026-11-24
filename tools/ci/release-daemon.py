#!/usr/bin/env python3
"""Local M5 macOS release daemon for SergeSerb2/open.

Runs as a LaunchAgent (`com.serge.open-release`) inside the M5 user's Aqua
session (gui/501) so no persistent self-hosted runner is ever attached to the
public SergeSerb2/open repository.

Behavior:
  - Polls `origin/main` every `--poll-seconds` (default 15s).
  - Keeps a dedicated warm release checkout at `--worktree` (preserving
    `Vendor/cef` and `Vendor/adblock` across builds while resetting all tracked
    source files cleanly to exact `origin/main`).
  - Whenever `origin/main` has unshipped release-relevant commits (compared to
    the live `appcast.xml` release), invokes `tools/ci/release-orchestrator.py`.
  - If `release-orchestrator.py` exits with code 2 (superseded before `09-dmg`
    by a newer merged PR), immediately loops with zero delay to build the new
    `origin/main` HEAD (coalescing both PRs).
  - If a release fails for a given SHA, backs off (10m, 30m, 60m) on that same
    SHA instead of burning CPU/notary quota, and resets backoff immediately as
    soon as a new commit lands on `origin/main`.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

EXIT_SUPERSEDED = 2
STOP = False


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[open-release-daemon {ts}] {msg}", flush=True)


def run_cmd(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    capture: bool = True,
    check: bool = True,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        capture_output=capture,
        check=check,
        timeout=timeout,
    )


def ensure_checkout(worktree: Path, repo_url: str, branch: str) -> None:
    if not (worktree / ".git").exists():
        log(f"Cloning {repo_url} into {worktree}")
        worktree.parent.mkdir(parents=True, exist_ok=True)
        run_cmd(["git", "clone", "--branch", branch, repo_url, str(worktree)], timeout=300)
    run_cmd(["git", "-C", str(worktree), "fetch", "--quiet", "origin", branch, "--tags"], timeout=60)


def sync_checkout_to_sha(worktree: Path, sha: str) -> None:
    run_cmd(["git", "-C", str(worktree), "reset", "--hard", sha], timeout=60)
    # Clean untracked repo files while keeping warm Vendor/cef, Vendor/adblock, and build/DerivedData
    run_cmd(
        [
            "git",
            "-C",
            str(worktree),
            "clean",
            "-fd",
            "--exclude=Vendor",
            "--exclude=build/DerivedData",
            "--exclude=build/Release",
        ],
        timeout=60,
    )


def remote_head(worktree: Path, branch: str) -> str | None:
    proc = run_cmd(
        ["git", "-C", str(worktree), "ls-remote", "origin", f"refs/heads/{branch}"],
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


def main(argv: list[str]) -> int:
    global STOP
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--worktree",
        type=Path,
        default=Path.home() / "Developer/open-release-worktree",
        help="Dedicated local checkout for automated releases",
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=Path.home() / ".local/share/open-release-daemon",
    )
    parser.add_argument("--repo-url", default="https://github.com/SergeSerb2/open.git")
    parser.add_argument("--source-repo", default="SergeSerb2/open")
    parser.add_argument("--releases-repo", default="SergeSerb2/open-releases")
    parser.add_argument("--feed-url", default="https://sergeserb2.github.io/open-releases/appcast.xml")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--no-cancel-phase", default="09-dmg")
    parser.add_argument("--poll-seconds", type=float, default=15.0)
    parser.add_argument("--once", action="store_true", help="Run a single check/release pass and exit")
    args = parser.parse_args(argv)

    args.state_dir.mkdir(parents=True, exist_ok=True)
    lock_file = (args.state_dir / "daemon.lock").open("w")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("Another open-release-daemon instance already holds daemon.lock; exiting")
        return 0

    state_file = args.state_dir / "state.json"

    def load_state() -> dict:
        if state_file.is_file():
            try:
                return json.loads(state_file.read_text(encoding="utf-8"))
            except ValueError:
                pass
        return {}

    def save_state(data: dict) -> None:
        tmp = state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        tmp.replace(state_file)

    active_child: dict[str, subprocess.Popen[str] | None] = {"proc": None}

    def handle_stop(signum: int, _frame: object) -> None:
        global STOP
        STOP = True
        log(f"Received signal {signum}; shutting down cleanly")
        child = active_child["proc"]
        if child is not None and child.poll() is None:
            child.send_signal(signal.SIGTERM)

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)

    ensure_checkout(args.worktree, args.repo_url, args.branch)
    log(
        f"Daemon up: watching {args.source_repo} ({args.branch}) -> {args.releases_repo} "
        f"[worktree={args.worktree}, cutoff={args.no_cancel_phase}]"
    )

    backoff_schedule = (600, 1800, 3600)

    while not STOP:
        try:
            sha = remote_head(args.worktree, args.branch)
            if not sha:
                log("WARN: ls-remote failed; retrying after poll interval")
                if args.once:
                    return 1
                time.sleep(args.poll_seconds)
                continue

            st = load_state()
            # Already handled cleanly (published or skipped as non-release)?
            if st.get("handled_sha") == sha:
                if args.once:
                    return 0
                time.sleep(args.poll_seconds)
                continue

            # Backoff if this exact SHA previously failed
            if st.get("failed_sha") == sha:
                next_retry = float(st.get("next_retry_at", 0))
                if time.time() < next_retry:
                    if args.once:
                        return 1
                    time.sleep(args.poll_seconds)
                    continue

            log(f"New origin/{args.branch} commit {sha[:10]} detected; syncing worktree")
            run_cmd(["git", "-C", str(args.worktree), "fetch", "--quiet", "origin", args.branch, "--tags"], timeout=60)
            sync_checkout_to_sha(args.worktree, sha)

            orch_script = args.worktree / "tools/ci/release-orchestrator.py"
            if not orch_script.is_file():
                log(f"Commit {sha[:10]} does not yet contain tools/ci/release-orchestrator.py; waiting for merge")
                save_state({"handled_sha": sha, "status": "no-orchestrator", "updated_at": time.time()})
                if args.once:
                    return 0
                time.sleep(args.poll_seconds)
                continue

            cmd = [
                sys.executable,
                str(orch_script),
                "--repo",
                str(args.worktree),
                "--source-repo",
                args.source_repo,
                "--branch",
                args.branch,
                "--releases-repo",
                args.releases_repo,
                "--feed-url",
                args.feed_url,
                "--no-cancel-phase",
                args.no_cancel_phase,
            ]
            env = dict(os.environ)
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
            proc = subprocess.Popen(cmd, cwd=str(args.worktree), env=env)
            active_child["proc"] = proc
            rc = proc.wait()
            active_child["proc"] = None

            if rc == 0:
                log(f"Orchestrator succeeded for {sha[:10]}")
                save_state({"handled_sha": sha, "status": "ok", "updated_at": time.time()})
                if args.once:
                    return 0
                # Immediately re-check origin/main in case a newer PR merged past 09-dmg
                continue
            elif rc == EXIT_SUPERSEDED:
                log(f"Orchestrator cleanly superseded for {sha[:10]}; immediately looping for latest main")
                save_state({"superseded_sha": sha, "status": "superseded", "updated_at": time.time()})
                if args.once:
                    return EXIT_SUPERSEDED
                continue
            elif STOP or rc in (130, 143):
                log(f"Orchestrator interrupted by clean shutdown signal (exit {rc}) for {sha[:10]}; no failure backoff recorded")
                if args.once:
                    return rc
                break
            else:
                attempts = int(st.get("failed_attempts", 0)) + 1 if st.get("failed_sha") == sha else 1
                delay = backoff_schedule[min(attempts - 1, len(backoff_schedule) - 1)]
                log(f"Orchestrator failed for {sha[:10]} (exit {rc}, attempt {attempts}); backing off {delay}s")
                save_state(
                    {
                        "failed_sha": sha,
                        "failed_attempts": attempts,
                        "last_exit_code": rc,
                        "next_retry_at": time.time() + delay,
                        "updated_at": time.time(),
                    }
                )
                if args.once:
                    return rc
        except Exception as exc:
            log(f"ERROR in daemon loop: {exc}")
            if args.once:
                return 1
        time.sleep(args.poll_seconds)

    log("Daemon stopped cleanly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
