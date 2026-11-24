# CI and Automatic Per-PR Releases

This document describes the GitHub Actions CI setup, local CI fallback, and automatic per-PR macOS release daemon for `SergeSerb2/open` and `SergeSerb2/open-releases`.

## Architecture Overview

| Component | Trigger | Where it runs | Cost & Security Model |
|---|---|---|---|
| `.github/workflows/ci.yml` | PRs to `main`, pushes to `main`, manual dispatch | `ubuntu-latest` first; automatic fallback to `[self-hosted, linux, open-ci]` (`mesh-ci`) | Free on public repo (`SergeSerb2/open`). If the repo goes private and hits the $0 GitHub Actions spending limit, `linux-hosted` fails before step 1 (`started != 'true'`) and `linux-local-fallback` runs automatically on the 4-machine `mesh-ci` throwaway VM fleet (`m5`, `m1-dev`, `windows`, `sanas`). Set repo variable `OPEN_FORCE_LOCAL_CI=true` to force local `mesh-ci`. Fork PRs never run on `mesh-ci` (enforced by both workflow `if:` and `mesh.py`'s `head_repository` guard). |
| `com.serge.open-release` (`tools/ci/release-daemon.py`) | Polls `origin/main` every 15s | Native M5 macOS LaunchAgent in `gui/501` Aqua session | **Zero** persistent self-hosted GitHub Actions runners are attached to the public `SergeSerb2/open` repo, so fork PRs can never execute code on M5 or reach signing keys. Zero GitHub Actions minutes. Keeps a dedicated warm release worktree (`~/Developer/open-release-worktree`) and reports live `release/macos` commit statuses back to `SergeSerb2/open`. |

## Per-PR Release and Smart Cancellation

Whenever `origin/main` advances, `tools/ci/release-daemon.py` syncs `~/Developer/open-release-worktree` to `origin/main` and runs `tools/ci/release-orchestrator.py`:

1. **Origin-main ancestry & release-relevance filter (`tools/ci/check-release-relevant.py`):**
   - Production releases refuse any commit that is not an ancestor of `origin/main`.
   - Uses `git diff --no-renames --name-only` so renames out of shipped directories are never missed.
   - Changes touching `App/`, `Helper/`, `DockTile/`, `Engine/`, `Packages/`, `assets/`, `project.yml`, `docs/release/licenses*`, `docs/release/notes/`, or build/release scripts trigger a release.
   - Changes touching only `docs/` (other than licenses/notes), `.github/`, `SyncServer/`, `tools/ci/`, `tools/e2e/`, `tools/perf/`, `tools/verification/`, or `README.md`/`AGENTS.md` are skipped automatically.
   - Commit markers `[skip release]` (if every first-parent commit since the last live release carries it) and `[force release]` override path filtering.
   - **Engine PR note:** A merged PR that updates `Engine/` without an updated local official engine build will fail cleanly at `02-engine` (publishing nothing) until the lead rebuilds and records the new official engine distribution on M5.

2. **Automatic monotonic versioning and notes (`tools/ci/plan-release.py`):**
   - Reads `project.yml`, live `https://sergeserb2.github.io/open-releases/appcast.xml`, and remote `v*` tags on `SergeSerb2/open-releases` and `SergeSerb2/open` (remote tag fetch failures are fatal in production).
   - Identifies the last live released source commit from the `Source commit:` line of the `SergeSerb2/open-releases` release matching the live feed's newest item (ignoring any orphaned origin tag that never reached the live feed).
   - Computes `next_build = max(live_build + 1, project_yml_build)` and `next_version = project_yml_version` if manually bumped above the latest published version, otherwise increments the patch version (e.g. `0.1.9` -> `0.1.10`).
   - Uses a hand-written `docs/release/notes/<version>.md` if present; otherwise generates sanitized Markdown notes from all merged PRs/commits since the last live released commit (including PRs coalesced after a cancellation).
   - Applies version/notes only inside the dedicated release worktree and resets them after each run — no bot commits are pushed back to `main`.

3. **Smart cancellation vs "nearly done" point of no return:**
   - `tools/release.sh` atomically writes its active phase to `OPEN_RELEASE_PHASE_FILE`.
   - While `tools/release.sh` runs (with tokens stripped from its build environment and `SIGTERM`/`SIGINT` forwarded to its process group so `heavy.sh` slots and `.release-lock` always clean up), `release-orchestrator.py` polls `origin/main` every 12 seconds:
     - **Before `09-dmg` (`01-preflight` through `08-notarize-app`, ~0–75% of build time):** if a newer release-relevant PR merges to `main`, `release-orchestrator.py` cleanly terminates `tools/release.sh`, cleans partial staging, marks the superseded commit status, and exits with code `2`. The daemon immediately loops with zero delay to build and ship the latest `origin/main` (combining both PRs).
     - **At or after `09-dmg` (`09-dmg`, `10-appcast`, `11-manifest`, `12-summary`, `13-publish`, ~75%+ complete — "nearly done"):** the running release is **not** cancelled. It finishes DMG creation/notarization, appcast generation, and publishing cleanly; the daemon then immediately picks up the newer `origin/main` commit on its next loop.
   - If a commit fails to build/notarize/publish, the daemon posts `release/macos = failure` and backs off (10m, 30m, 60m) on that same SHA, resetting immediately as soon as a new PR merges to `main`.

4. **Acceptance checks and strict publish order:**
   - `release-orchestrator.py` checks `tools/release.sh`'s exit code (`0` or `1` only) and verifies `12-summary.result` was written during the current run.
   - **Automated hard-required rows (must all PASS):** `A-1` (official engine provenance), `A-4` (inside-out Developer ID + Hardened Runtime signatures & exact entitlements), `A-5` (Gatekeeper `spctl` on App & DMG), `A-6` (Apple notarization staple validation on App & DMG), `A-7` (bundle size <= 345 MB), `A-8` (locales), `A-9` (no dSYMs/fixtures in app), `A-10` (no automation socket), `A-11` static DMG verify/mount/entitlements, `10-appcast` XML + Ed25519 signature (pre-upload; live `A-12` enclosure reachability + Ed25519 signature are verified immediately after asset upload and feed deployment), and `A-15` (no private keys in outputs).
   - **Not run automatically (per M5 STOP-rule / 2026-11-24 release policy):** `A-2`, `A-3`, `A-11` interactive app launch, `A-13` interactive predecessor update, and `A-14` visual About receipt are not executed on M5's desktop during unattended releases.
   - **Strict publish order:**
     1. Upload `Open-<ver>.dmg`, `.sha256`, any Sparkle `*.delta`, `Acknowledgements.txt`, and `CREDITS.html` to `SergeSerb2/open-releases` (refusing `--clobber` unless the existing tag belongs to the exact same `Source commit`).
     2. Verify live HTTP `HEAD` and exact `Content-Length` on the DMG and every `.delta`.
     3. Push `appcast.xml` and `release-notes/<ver>.md` to `SergeSerb2/open-releases` `gh-pages` (preserving earlier release notes).
     4. Wait up to 600s for GitHub Pages to serve the new build and verify live XML + Ed25519 signature against `App/Info.plist`'s `SUPublicEDKey`.
     5. Push annotated tag `v<ver>` to `SergeSerb2/open` **last**, so a failed publish never looks already-released.
   - Predecessor DMGs are paired from the live feed and cached at `~/Developer/open-dist/ci-predecessor/` (keeping newest 2) for Sparkle binary deltas; `symbols/` are archived locally at `~/Developer/open-dist/ci-symbols/` (keeping newest 5) and never uploaded.

## Local Service Operations

### M5 Release Daemon (`com.serge.open-release`)
- Install / update on M5: `bash tools/ci/install-m5-release-daemon.sh`
- LaunchAgent: `~/Library/LaunchAgents/com.serge.open-release.plist` (Aqua `gui/501`, shares M5 login Keychain)
- Optional scoped PAT: place a fine-grained token (contents:write on `SergeSerb2/open-releases`) at `~/.config/open-release/token` (`chmod 600`); otherwise uses M5's `gh` Keychain session.
- Logs: `~/Library/Logs/com.serge.open-release/{stdout,stderr}.log`
- State: `~/.local/share/open-release-daemon/state.json`

### Local Linux CI Fallback (`mesh-ci`, label `open-ci`)
- Pool `open` in `mesh-ci` `config.json` across `m5`, `m1-dev`, `windows`, and `sanas` watches `SergeSerb2/open` for `[self-hosted, linux, open-ci]` jobs and runs each in a throwaway VM with no host credentials.
