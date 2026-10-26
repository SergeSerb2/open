# Fork infrastructure — implementation plan for Open

Status: plan for implementation. Implementer: follow this file top to bottom.
Do not spawn subagents (AGENTS.md rule 8). Do not write unit tests (rule 6).
Verify end to end only: real scripts, real build, real `cefsimple` launch.
This file is the complete context. The implementer has no other context.
If a fact in this file conflicts with a real file in the repo or in
`~/Developer/open-engine`, stop and report the conflict. Do not redesign silently.

Authoritative inputs (read only §0.3 before you start):

- [architecture.md](../architecture.md) — module borders. The Swift shell talks
  only to `OpenEngine`. Packages never import CEF.
- [adblock-design.md](../adblock-design.md) — Option B is locked: Brave
  `adblock-rust` (crate `adblock`, MPL-2.0) in the browser process, matched
  through a `blink::URLLoaderThrottle`. This plan designs the build glue only.
  It does not re-decide the ad-block engine.
- `docs/engine-patches.md` — **does not exist yet** at plan time
  (checked 2026-10-25). An engine agent owns WHICH patches Open needs.
  This plan owns HOW patches are stored, applied, refreshed, and rebased.
  Where a patch name is needed as an example, this plan uses the ad-block
  patch set from adblock-design §"Chromium fork patches". Treat every other
  patch name as a placeholder until `docs/engine-patches.md` lands.
  Do not invent patch content that the engine plan has not specified.
- Local engine tree (READ ONLY in Phase A, see §11):
  `~/Developer/open-engine/chromium_git/chromium/src`
  with `src/cef` inside it, CEF patches already applied, and a Release build
  running now in `out/Release_GN_arm64`. Never run `gclient`, `gn`, `ninja`,
  `autoninja`, `git checkout`, or `git apply` in that tree until §11 Phase B
  says the running build has finished and the lead has said so in the thread.

How to use this plan:

1. Work §11 in order. Steps marked **[NOW]** touch only this repo
   (`/Users/serge/.t3/projects/open`). Do them while the stock build runs.
   Steps marked **[WAIT]** touch `~/Developer/open-engine`. Do not start a
   [WAIT] step while any `autoninja` / `siso` / `ninja` process for
   `out/Release_GN_arm64` is alive. Check with the command in §11.0.
2. Each step lists exact files, exact content or pseudocode, and acceptance
   checks. A step is done only when every check passes. Paste real command
   output into the PR description. Do not claim a check you did not run.
3. Write ONLY the files listed in §3.3 in Phase A. Do not edit Swift sources,
   `Packages/OpenKit`, or the Chromium tree in Phase A.
4. Long jobs (sync, build) must run in their own session so an app restart
   does not kill them (AGENTS.md rule 9). §6.5 gives the exact wrapper.
   Never start a long job as a bare background `&` job.
5. User-visible text never uses the Arc brand. Exception: "Import from Arc".
   The product name in every new file in this plan is **Open**.

---

## 0. Scope and non-scope

### 0.1 In scope (this plan)

| Area | Deliverable |
|---|---|
| Repo layout | `Engine/fork/` tree in §3: `VERSIONS`, `patches/`, `src/` overlay, `gn/`, `branding/`, `licenses/`, `verification/`, `scripts/`, `series` files |
| Pins | One machine-readable pin file for Chromium, CEF, depot_tools, Rust toolchain, and the `adblock` crate (§4) |
| Scripts | Six idempotent scripts in §6: `engine-bootstrap`, `engine-apply`, `engine-refresh-patches`, `engine-build`, `engine-distrib`, `engine-rebase`, plus `engine-status` (§10.1) and `tools/fetch-engine.sh` (§6.6) |
| Patch method | CEF patches first (CEF's own tool), Open patches second (`git apply --3way`), overlay copy third, GN regen last (§6.3) |
| Rust crates | Chromium-way vendoring of `adblock` + transitive deps with `gnrt`, inside the overlay + one patch (§7) |
| GN args | Checked-in dev and release arg files (§5). Dev file matches the live `args.gn` byte-for-byte at Step 2 |
| Branding | Placeholder branding files only (§5.3). No icons drawn, no Arc assets copied |
| Rebuild rules | Cost table and patch-size rules (§9) |
| Verification | `engine-status`, `nm` symbol check, `cefsimple` smoke list (§10). No unit tests |
| Rebase | Step-by-step move to a new Chromium/CEF version (§6.7, §12) |

### 0.2 Out of scope (do not build)

- The content of Open's feature patches (ad-block throttle, extension bridge,
  tab bridge, etc.). That is `docs/engine-patches.md`. This plan creates the
  empty series slots and the ad-block build-glue slot only.
- Any Swift code. `Engine/OpenEngine/` does not exist yet. This plan defines
  only the contract that `tools/fetch-engine.sh` fills: a CEF binary
  distribution under `Vendor/cef/` (already git-ignored).
- Drawing icons or final bundle-ID registration. §5.3 ships placeholders with
  `TODO(lead)` markers. Do not invent a final bundle ID in C++.
- CI machines, notarization, Sparkle, Widevine licensing. Note them as risks
  (§14) only.
- A Chromium mirror, submodule, or `git subtree` in this repo. The repo stores
  pins + patches + overlay files only. This is a locked decision in AGENTS.md.
- Editing CEF's own 117–118 patches. CEF owns them. Open never copies them
  into `Engine/fork/patches/cef/` as duplicates (see §3.2 for the one
  exception: Open patches that modify files inside `src/cef/`).

### 0.3 Milestone fit

This is the infrastructure half of M0 ("engine spike: build system") in
[plan.md](../plan.md), and it unblocks M6 ad blocking. It has no Swift
dependency. It must not block on `docs/engine-patches.md`: Steps 1–6 land
with zero feature patches (empty series + ad-block build-glue placeholder
disabled by default, see §7.6).

---

## 1. Locked facts (do not re-derive)

Verified 2026-10-25 by read-only inspection. Re-check each pin at Step 2
with the exact commands in §4.3. If a value differs, stop and report.

| ID | Fact | Evidence (read-only command) |
|---|---|---|
| F-1 | Chromium tag `156.0.8078.48`, commit `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c` | `git -C ~/Developer/open-engine/chromium_git/chromium/src rev-parse HEAD` → that hash; commit subject "Incrementing VERSION to 156.0.8078.48" |
| F-2 | CEF branch `8078`, commit `4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f` ("Fix renderer frame reconnection after hidden BFCache restores") | `git -C ~/Developer/open-engine/chromium_git/chromium/src/cef rev-parse HEAD` |
| F-3 | depot_tools commit `b52fe87d04af61df3dd07748ff2c2c0b649dca09` | `git -C ~/Developer/open-engine/depot_tools rev-parse HEAD` |
| F-4 | CEF applies its own patches with `cef/tools/patcher.py` driven by `cef/patch/patch.cfg` (117–118 files in `cef/patch/patches/`). The patcher skips patches that are already applied. Stock-build log: "117 patches total (0 applied, 117 skipped, 0 failed)" | `cef/patch/README.txt`; tail of `~/Developer/open-engine/build-stock.log` |
| F-5 | The Chromium working tree is dirty BY DESIGN after CEF patching (`git status` shows `M .gn`, `M BUILD.gn`, `M DEPS`, `M base/...`, …). A dirty `src/` tree is the normal state. Never "clean" it with `git checkout .` or `git reset --hard` | `git -C …/src status --short` |
| F-6 | Live GN out dir is `out/Release_GN_arm64`. Its `args.gn` is the dev arg set reproduced verbatim in §5.1 | `cat …/src/out/Release_GN_arm64/args.gn` |
| F-7 | Stock build command that works on this Mac: `caffeinate -dimsu nice -n 10 autoninja -C out/Release_GN_arm64 cefsimple -j 10` (see `~/Developer/open-engine/build-engine.sh`). Default parallelism caused two kernel watchdog panics on macOS 27.2 beta. `-j 10` + `nice` is mandatory, not a preference | `build-engine.sh`; AGENTS task brief |
| F-8 | Sync facts: shallow fetches from `chromium.googlesource.com` run at ~0.5 MB/s. Always set `GIT_CACHE_PATH=$HOME/Developer/open-engine/git_cache`. `gclient sync --nohooks` must be followed by `gclient runhooks` (see `hooks-and-build.sh`: `gclient runhooks -j 12`). Xcode 27 needs `xcodebuild -downloadComponent MetalToolchain` once per machine | `sync-chromium.sh`, `hooks-and-build.sh`; task brief |
| F-9 | CEF distrib output dir is `<src>/cef/binary_distrib/` (child dirs per config). `automate-git.py --force-distrib --minimal-distrib` creates it. `CEF_ARCHIVE_FORMAT=tar.bz2` selects the archive form | `grep binary_distrib automate/automate-git.py` (line ~1839: `artifacts_path = …/cef/binary_distrib`) |
| F-10 | This Mac: macOS 27.2 (26B5112a), Xcode 27.1 (27A9275), SDK 27.0. Chromium 156 expects an older SDK, so the dev build sets `treat_warnings_as_errors=false` (F-6). Keep that in dev args | `sw_vers`; `xcodebuild -version` |
| F-11 | Chromium Rust: `enable_rust = build_with_chromium` by default. Vendoring tool is `gnrt`: `vpython3 tools/crates/run_gnrt.py {add,update,vendor,gen}`. Layout: `third_party/rust/<crate>/v<epoch>/{BUILD.gn,README.chromium}` + sources in `third_party/rust/chromium_crates_io/vendor/<crate>-v<epoch>/`. Direct deps are listed in `third_party/rust/chromium_crates_io/Cargo.toml`; Chromium-specific config in `gnrt_config.toml` | `third_party/rust/README.md`, `README-importing-new-crates.md` in the tree |
| F-12 | Chromium's pinned Rust toolchain in this tree reports `rustc 1.100.0 1edd55dcfcd573872c727fa3e086369a71661ee0` (`third_party/rust-toolchain/VERSION`). This is NOT the system `cargo 1.99.1` used in the ad-block benchmark. Crate builds must be proven under the Chromium toolchain, not the system one | `cat …/src/third_party/rust-toolchain/VERSION` |
| F-13 | `adblock` crate pin that builds: `adblock = "=0.8.11"` + `rmp = "=0.8.11"` (MPL-2.0). `adblock 0.10`/`0.13.3` fail on newer `rustc` via `rmp-serde`. Serialized engine for EasyList+EasyPrivacy: 6.78 MiB; ~47 ms deserialize; ~2.2 µs per network check | [adblock-design.md](adblock-design.md) §Benchmark |
| F-14 | The app consumes the engine as a CEF binary distribution copied to `Vendor/cef/` in this repo (git-ignored today: `.gitignore` has `Vendor/cef/`). No fetch script exists yet. Architecture calls it `tools/fetch-cef`; this plan names it `tools/fetch-engine.sh` (§6.6) | `.gitignore`; [architecture.md](architecture.md) source-tree note |
| F-15 | CEF throttle hook for ad blocking: CEF does not override `CreateURLLoaderThrottles` today. The patch adds the override in `ChromeContentBrowserClientCef`. Stepping stone with zero fork patch: `CefResourceRequestHandler::OnBeforeResourceLoad` | [adblock-design.md](adblock-design.md) §Integration plan, Appendix |

### 1.1 Lessons that are rules in this plan

| Rule | Why |
|---|---|
| Always `export GIT_CACHE_PATH`, `DEPOT_TOOLS_UPDATE=0` | F-8. Without the cache a fresh sync takes days at 0.5 MB/s |
| Always `gclient sync --nohooks` THEN `gclient runhooks` as two steps | Hooks generate `LASTCHANGE` and toolchain files. Skipping them fails later with stale errors |
| Always `-j 10` (env `JOBS`, default 10) + `nice -n 10` + `caffeinate -dimsu` | F-7. Watchdog panics at default parallelism on this beta OS |
| Never run two writers in the Chromium tree at once | `gn`, `ninja`, `patcher.py`, and `gclient` corrupt each other's state. Scripts take the lock in §6.1 |
| Never hand-edit a file in the Chromium tree and call it a patch | Every change must round-trip: tree → `engine-refresh-patches` → patch file → clean apply (§8) |

---

## 2. Key decisions

| # | Decision | Rejected alternative | Reason |
|---|---|---|---|
| D-1 | Three layers, applied in order: (1) CEF's own patches via CEF's `patcher.py`, (2) Open patches via `git apply --3way`, (3) Open overlay files copied verbatim | One flat patch stack for everything | CEF already owns layer 1 and its tool skips applied patches (F-4). Duplicating CEF patches into our repo creates a second source of truth that drifts on every CEF bump |
| D-2 | New code lives in the overlay (`Engine/fork/src/` → `chromium/src/`), not inside patch hunks. Patches touch ONLY existing upstream files, and only the smallest hunk that wires the new code in (a `deps` line, an override, an include) | Put whole new files inside `.patch` files | New-file hunks conflict on every rebase and are unreadable in review. Overlay files never conflict; only the small wiring hunk can |
| D-3 | Patch granularity: one patch file = one logical change = one series line with a one-line rationale. Never one giant `open.patch` | Per-directory or per-author patch files | `engine-refresh-patches` (§6.4) regenerates per series entry from path lists. Fine granularity is what makes rebase conflicts local (§12) |
| D-4 | Series files are the source of truth for order. File names carry a numeric prefix only as a sort hint; the series file wins if they disagree, and `engine-status` flags the disagreement | Rely on alphabetical file order alone | Rebase needs to drop, disable, or reorder a patch without renaming files on disk |
| D-5 | Pins live in ONE file, `Engine/fork/VERSIONS` (shell-sourceable `KEY=value`, §4). Every script sources it. No script hard-codes a version | Versions repeated in each script / in docs prose | One bump = one file edit + one rebase run. `engine-status` diffs the tree against this one file |
| D-6 | Rust crates enter via Chromium's `gnrt` flow (F-11), vendored into `third_party/rust/`, driven by overlay copies of the two hand-edited files (`chromium_crates_io/Cargo.toml`, `gnrt_config.toml`) plus generated files captured as ONE patch (§7) | Brave-style "run cargo, link a prebuilt `.a`" (adblock-design's first sketch) | The Chromium way survives rebases, gets `README.chromium` license records for free, and uses the pinned toolchain (F-12). A prebuilt `.a` breaks silently on toolchain bumps. Note: adblock-design §Integration plan item 1 sketches the cargo shape; this plan supersedes the build mechanics only, not the service/throttle design |
| D-7 | Dev and release use separate out dirs and separate checked-in arg files. Dev reuses the live `out/Release_GN_arm64` incrementally. Release uses `out/Release_Official_arm64` and is never built until §11 Step 10 | One out dir, args edited in place | Editing `args.gn` in a live out dir forces a full `gn gen` + near-full rebuild. Separate dirs keep the fast dev loop intact |
| D-8 | Scripts are Bash (`#!/bin/bash`, `set -euo pipefail`) with one Python helper for status (`engine-status` may be Python 3). No new third-party dependencies | Python for everything; Makefile; Swift script | Matches the working scripts in `~/Developer/open-engine/*.sh`. Bash is what the next engineer can debug at 2 a.m. during a rebase |
| D-9 | Every script is idempotent and safe to re-run. "Already done" is a success exit (0) with a clear log line, never an error | Scripts that assume a virgin tree | Rebase and refresh are iterative. The operator will run apply → fix → apply many times |
| D-10 | All state the scripts need outside the repo lives under `~/Developer/open-engine/` (`logs/`, `.open-engine-state/`). Nothing stateful is written into this repo except the deliverables in §3 | State files committed to the repo | Patch state depends on the local tree. Committing it would lie for every other machine |

---

## 3. Repo layout

### 3.1 The tree to create (all paths relative to repo root)

```text
Engine/
  fork/
    README.md                     # what this dir is, link to this plan, 1-page operator guide
    VERSIONS                      # §4 — the only pin file (sourceable KEY=value)
    patches/
      chromium/
        series                    # §4.2 — ordered list, one patch per line + rationale
      cef/
        series                    # patches whose target files live under src/cef/
      rust/
        series                    # generated-vendor capture patch(es), §7.5 (0 or 1 entries in v1)
    src/                          # overlay: mirrors chromium/src/ paths exactly
      open/
        adblock/                  # placeholder in Phase A: README.md only (§7.6)
          README.md
      cef/                        # overlay files that belong inside src/cef/ (none in Phase A)
        .gitkeep
      third_party/
        rust/
          chromium_crates_io/     # hand-edited inputs ONLY (§7.3)
            Cargo.toml.open       # fragment, not a full Cargo.toml (see §7.3)
            gnrt_config.toml.open # fragment
    gn/
      dev.args.gn                 # §5.1 — byte-identical to live args.gn at Step 2
      release.args.gn             # §5.2
    branding/
      README.md                   # §5.3 — placeholder, TODO(lead) bundle IDs
      icons/
        .gitkeep                  # no icon assets in Phase A; never copy Arc assets
    licenses/
      THIRD_PARTY.md              # §7.7 — dependency note table (adblock MPL-2.0 row first)
      MPL-2.0.txt                 # copied from the vendored crate at Step 8 [WAIT]
    verification/
      expected-symbols.txt        # §10.2 — one exported symbol per line
      smoke-checklist.md          # §10.3 — cefsimple + Open app manual list
    scripts/
      lib/
        common.sh                 # §6.1 — sourced by every script; never executed directly
      engine-bootstrap            # §6.2  (bash, executable)
      engine-apply                # §6.3  (bash, executable)
      engine-refresh-patches      # §6.4  (bash, executable)
      engine-build                # §6.5  (bash, executable)
      engine-distrib              # §6.6  (bash, executable)
      engine-rebase               # §6.7  (bash, executable; mostly a guarded checklist runner)
      engine-status               # §10.1 (python3, executable)
tools/
  fetch-engine.sh                 # §6.6 — copies Vendor/cef/ from the local distrib
```

Notes on names:

- Script names have no `.sh` suffix, matching the task contract
  (`engine-bootstrap`, `engine-apply`, …). They are invoked as
  `Engine/fork/scripts/engine-apply`. `tools/fetch-engine.sh` keeps the `.sh`
  suffix because `tools/` already holds `rea-env.sh`.
- `Engine/fork/src/` mirrors the Chromium `src/` root. Example:
  `Engine/fork/src/open/adblock/open_adblock_service.cc` in the repo copies to
  `~/Developer/open-engine/chromium_git/chromium/src/open/adblock/open_adblock_service.cc`
  in the tree. The `cef/` subtree works the same way:
  `Engine/fork/src/cef/libcef/browser/open/…` → `src/cef/libcef/browser/open/…`.
  (adblock-design puts new CEF-side code in `cef/libcef/browser/open/*` or in
  `//open/...`; both are overlay paths. Prefer `//open/...` for new code and
  reserve `src/cef/` overlay files for code that must live beside CEF classes.)

### 3.2 What goes where: patch vs overlay vs series

| Change kind | Home | Rule |
|---|---|---|
| Edit to an existing Chromium file outside `src/cef/` | `patches/chromium/<nnnn>-<slug>.patch` + one `series` line | Smallest hunk that works (D-2). One logical change per file (D-3) |
| Edit to an existing file under `src/cef/` (e.g. `chrome_content_browser_client_cef.cc`) | `patches/cef/<nnnn>-<slug>.patch` + one line in `patches/cef/series` | Same hunk rule. This is the ONLY sense of "CEF patch" in our repo. Never copy CEF's own `cef/patch/patches/*.patch` files here |
| Brand-new file (any dir) | `src/<same path>` in the overlay | Never a patch hunk (D-2). Needs a wiring hunk somewhere only if GN or C++ must reference it |
| Generated Rust vendor output (`BUILD.gn`, `README.chromium`, vendored sources) | Captured as patch(es) in `patches/rust/` | Generated files must not be hand-edited. Regenerate with `gnrt`, then recapture (§7.5). Vendored crate SOURCES are not copied into this repo by hand; the capture patch is produced by `git diff` in the tree (§7.5 step R6) — see size warning there |
| GN arg change | `gn/*.args.gn` | Never a patch. Args are build input, not source |
| New third-party dependency note | `licenses/THIRD_PARTY.md` row + license text file | Required by repo rule for every new dependency |

### 3.3 Files the implementer creates in Phase A (exact list, nothing else)

Phase A creates: every file in §3.1 EXCEPT `licenses/MPL-2.0.txt` (Step 8,
[WAIT]) and except any `.patch` file content (series start empty, §4.2).
`src/open/adblock/` contains only `README.md` in Phase A.
Also edit exactly one existing file in Phase A: `.gitignore` (add the two
lines in §3.4). Do not edit any other existing file in Phase A.

### 3.4 `.gitignore` additions

Append exactly:

```gitignore
# Open fork-infrastructure local state (pins and patches are committed; state is not)
Engine/fork/scripts/.cache/
*.rej
*.orig
```

Do NOT git-ignore `Engine/fork/patches/`, `Engine/fork/src/`, or
`Engine/fork/gn/`. Those are the deliverable. `Vendor/cef/` is already ignored.

---

## 4. VERSIONS and series files

### 4.1 `Engine/fork/VERSIONS` — exact initial content

Create with exactly this content (comments allowed, keys must not change
without updating every script in §6 in the same PR):

```sh
# Open engine pins. Source this file; do not parse it with regex.
# One key per line, KEY=value, no spaces around =. See docs/plans/fork-infra.md §4.
CHROMIUM_TAG=156.0.8078.48
CHROMIUM_COMMIT=d0c02bfad08ec92a6ffcf989e53cd995e6381a4c
CEF_BRANCH=8078
CEF_COMMIT=4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f
DEPOT_TOOLS_COMMIT=b52fe87d04af61df3dd07748ff2c2c0b649dca09
# Chromium-bundled Rust toolchain (third_party/rust-toolchain/VERSION in the tree).
RUST_TOOLCHAIN_REV=1edd55dcfcd573872c727fa3e086369a71661ee0
RUST_TOOLCHAIN_VERSION=1.100.0
# Brave adblock crate pin (docs/adblock-design.md §Benchmark). Exact pins, MPL-2.0.
ADBLOCK_CRATE_VERSION=0.8.11
RMP_CRATE_VERSION=0.8.11
# Layout pins (not versions, but every script needs the same answers).
ENGINE_ROOT_DEFAULT=Developer/open-engine
CHROMIUM_SRC_SUBDIR=chromium_git/chromium/src
OUT_DIR_DEV=out/Release_GN_arm64
OUT_DIR_RELEASE=out/Release_Official_arm64
BUILD_JOBS_DEFAULT=10
TARGET_CPU=arm64
```

Rules:

- Scripts read pins with `set -a; . "$FORK_DIR/VERSIONS"; set +a` (via
  `common.sh` §6.1). A missing key is a hard error that names the key.
- A version bump edits this file and nothing else in the same commit, then
  runs `engine-rebase` (§6.7). Never bump a pin inside a feature PR.

### 4.2 Series files — format

One patch per line. Blank lines and lines that start with `#` are ignored.
Each entry line has the form:

```text
<file>.patch  # <one-line rationale: what + why, ≤ 100 chars>
```

Example `patches/chromium/series` after the ad-block milestone lands
(illustrative only — do not create these patch files in Phase A):

```text
0001-adblock-rust-build-glue.patch  # GN deps so //open/adblock links the vendored adblock crate (§7)
0002-adblock-throttle-hook.patch    # ChromeContentBrowserClientCef::CreateURLLoaderThrottles override appends the throttle
```

Rules:

- Order in the file IS apply order. Numeric prefixes are a sort hint only (D-4).
- A line that starts with `# DISABLED: ` names a patch that stays on disk but
  is not applied. `engine-apply` logs it as skipped-disabled. Use this during
  rebase (§12), never as a permanent state on `main`.
- Phase A ships both series files with a header comment and ZERO entries:

```text
# Open patches for Chromium. One patch per line: <file>.patch  # rationale
# Order in this file is apply order. See docs/plans/fork-infra.md §4.2.
```

### 4.3 Pin verification commands (Step 2 acceptance)

Run read-only. Every output must equal the `VERSIONS` value:

```sh
git -C ~/Developer/open-engine/chromium_git/chromium/src rev-parse HEAD
git -C ~/Developer/open-engine/chromium_git/chromium/src/cef rev-parse HEAD
git -C ~/Developer/open-engine/depot_tools rev-parse HEAD
git -C ~/Developer/open-engine/chromium_git/chromium/src describe --tags   # → 156.0.8078.48
head -n 1 ~/Developer/open-engine/chromium_git/chromium/src/third_party/rust-toolchain/VERSION
diff ~/Developer/open-engine/chromium_git/chromium/src/out/Release_GN_arm64/args.gn Engine/fork/gn/dev.args.gn
```

The last `diff` must print nothing. If the live `args.gn` has drifted from
§5.1, copy the LIVE file (the tree is truth for dev args) and note the drift
in the PR description.

---

## 5. GN args and branding

### 5.1 `gn/dev.args.gn` — exact initial content

Copy the live `args.gn` (F-6). At plan time it is exactly:

```gn
alternate_cdm_storage_id_key="968b476909da4373b08903c28e859454"
blink_symbol_level=0
chrome_pgo_phase=0
clang_use_chrome_plugins=false
dcheck_always_on=false
enable_background_mode=false
enable_cdm_host_verification=true
enable_cdm_storage_id=true
enable_downgrade_processing=false
enable_precompiled_headers=false
enable_resource_allowlist_generation=false
enable_rlz=true
enable_widevine=true
ffmpeg_branding="Chrome"
forbid_non_component_debug_builds=false
is_component_build=false
is_debug=false
is_official_build=false
optimize_webui=true
proprietary_codecs=true
symbol_level=0
target_cpu="arm64"
treat_warnings_as_errors=false
v8_symbol_level=0
```

Meaning for the implementer: fast dev build. No official LTO/PGO, no DCHECKs,
no symbols. `proprietary_codecs=true` + `ffmpeg_branding="Chrome"` match the
stock CEF build. Do not "improve" these values in Phase A. Any change needs
its own PR with a rebuild-time note (§9).

CEF note: CEF's `cef_create_projects` / automate flow may rewrite `args.gn`
in the out dir. The checked-in file is the INPUT. `engine-build` (§6.5)
copies it into the out dir only when the out dir is created or when
`--regen` is passed. It never edits the live out dir's `args.gn` silently.

### 5.2 `gn/release.args.gn` — exact initial content

```gn
# Open release args. Official build: LTO + PGO when a profile is present.
# Start from dev, then apply the release deltas below. engine-build merges
# by copying dev.args.gn and appending these lines (later GN assignments win
# for scalars; do not rely on list-append semantics).
is_official_build=true
is_debug=false
is_component_build=false
dcheck_always_on=false
symbol_level=1
blink_symbol_level=0
v8_symbol_level=0
treat_warnings_as_errors=false
target_cpu="arm64"
proprietary_codecs=true
ffmpeg_branding="Chrome"
enable_widevine=true
chrome_pgo_phase=2
use_thin_lto=true
thin_lto_enable_optimizations=true
```

Rules and edge cases:

- `chrome_pgo_phase=2` needs a PGO profile file in the tree
  (`chrome/build/pgo/profiles/` or the path CEF/Chromium 156 uses).
  If no profile file exists, `engine-build --config release` must FAIL
  before `gn gen` with: `release: no PGO profile found; set chrome_pgo_phase=0 explicitly in gn/release.args.gn or add the profile`. Do not silently
  ship a phase-0 build and call it release.
- Official builds make CEF build a separate `cef_sandbox` target
  (automate-git handles this; see its `is_official_build` branch). Expect a
  longer build and a different distrib layout. Verify at Step 10, not before.
- Release is never the default. `engine-build` with no flags is ALWAYS dev.
- arm64 only in v1 (`target_cpu="arm64"`). No universal (x64+arm64) build
  until the lead asks. A universal build doubles build time (§9).

### 5.3 Branding — placeholder only

Create `branding/README.md` with exactly these sections (fill the TODOs only
when the lead decides; do not guess final values in code):

```markdown
# Open engine branding (placeholder)

Status: placeholder. No final assets. Never copy Arc assets (AGENTS.md rule 1).

- Product name (user-visible): Open
- Framework name in v1: Chromium Embedded Framework (unchanged CEF name).
  Renaming the framework is a future patch; it changes signing, helper
  lookup, and update paths. Do not rename in the fork-infra milestone.
- App bundle ID: TODO(lead) — placeholder in scripts: app.open.Open
- Helper bundle ID suffixes: keep CEF defaults in v1
  (Helper, Helper (GPU), Helper (Renderer), Helper (Plugin), Helper (Alerts)).
- Icons: none. branding/icons/ stays empty (.gitkeep) until the designer
  delivers Open-owned icons. The build must succeed with no icon override.
- Where branding lands later (for the engine-patches plan, not this plan):
  CEF embedder product override + Chromium product strings, as small
  patches/chromium/ hunks. No branding hunk is in scope for fork-infra.
```

Script rule: no script in §6 hard-codes a bundle ID. Scripts that later need
one read `OPEN_APP_BUNDLE_ID` from the environment with the placeholder
default `app.open.Open` and log the value they used.

---

## 6. Scripts

### 6.1 Common conventions (`scripts/lib/common.sh`)

Every script in §6.2–§6.7 and `tools/fetch-engine.sh`:

- Starts with:

```bash
#!/bin/bash
set -euo pipefail
```

- Sources `common.sh` as its first action. Path resolution must work from
  any working directory:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
```

(`tools/fetch-engine.sh` inlines the same three helpers instead of sourcing;
`tools/` must not depend on `Engine/fork/scripts/` layout.)

`common.sh` provides exactly these functions and variables. Implement them
once; do not duplicate them per script:

| Name | Behavior |
|---|---|
| `FORK_DIR` | Absolute path to `Engine/fork/` (two levels up from `lib/`) |
| `REPO_ROOT` | `git -C "$FORK_DIR" rev-parse --show-toplevel` |
| `ENGINE_ROOT` | `$OPEN_ENGINE_ROOT` if set, else `$HOME/$ENGINE_ROOT_DEFAULT` from `VERSIONS` (= `~/Developer/open-engine`) |
| `SRC_DIR` | `$ENGINE_ROOT/$CHROMIUM_SRC_SUBDIR` (= `…/chromium_git/chromium/src`) |
| `STATE_DIR` | `$ENGINE_ROOT/.open-engine-state/` (created on demand) |
| `LOG_DIR` | `$ENGINE_ROOT/logs/` (created on demand) |
| `load_versions` | `set -a; . "$FORK_DIR/VERSIONS"; set +a`, then verifies every key in §4.1 exists and is non-empty. Missing key → `die "VERSIONS: missing key <KEY>"` |
| `log <msg>` | `printf '[%s] %s\n' "$(basename "$0")" "$*"` to stdout AND appends to `$LOG_DIR/<script>.log` with an ISO timestamp prefix |
| `die <msg>` | Logs `ERROR: <msg>` to stderr + log file, exits 1 |
| `require_macos_arm64` | Dies unless `uname -s` = `Darwin` and `uname -m` = `arm64`. Message names the offending value |
| `require_no_build_running` | Dies if `pgrep -f 'autoninja.*Release_GN|autoninja.*Release_Official|siso.*out/Release'` matches. Message: `a build is running in <out dir>; wait for it to finish (see build log)`. Used by apply, bootstrap (sync phase), rebase, refresh. NOT used by `engine-status` (read-only) |
| `acquire_lock <name>` | `mkdir "$STATE_DIR/lock-<name>"` or die `another <name> operation holds the lock (if stale, remove <path> by hand)`. Releases via `trap … EXIT`. Prevents two writers in the tree (§1.1) |
| `export_engine_env` | Exports `PATH="$ENGINE_ROOT/depot_tools:/opt/homebrew/bin:$PATH"`, `GIT_CACHE_PATH="$ENGINE_ROOT/git_cache"`, `DEPOT_TOOLS_UPDATE=0`, `CEF_ARCHIVE_FORMAT=tar.bz2` |

Idempotency contract (D-9): every script may be run twice in a row. The
second run does no redundant work, prints `already up to date` (or the
per-step equivalent), and exits 0. A script that cannot prove it is safe to
re-run must die with instructions, never guess.

Dry-run: `engine-apply`, `engine-refresh-patches`, and `fetch-engine.sh`
accept `--dry-run`. Dry-run prints every file it would write or copy and
writes nothing. Exit 0.

Help: every script with no arguments and `--help` prints usage to stdout and
exits 0 (except `engine-build`, where no arguments means "dev build", §6.5).

### 6.2 `engine-bootstrap` — fresh machine to pinned tree

Purpose: take a Mac with Xcode + Homebrew to a synced, patched, hook-complete
tree at the pinned versions. Safe to re-run: completed phases are skipped.

Usage:

```text
engine-bootstrap [--skip-sync] [--skip-hooks]
Env: OPEN_ENGINE_ROOT (default ~/Developer/open-engine), JOBS (default 10)
```

Phases in order. Log each phase start and end. Write a phase stamp file
`$STATE_DIR/bootstrap-<phase>.done` (contains the pin values it used) only
after the phase succeeds. On re-run, skip a phase only if its stamp matches
the CURRENT `VERSIONS` values; a pin change invalidates downstream stamps.

| Phase | Actions (exact) | Skip condition |
|---|---|---|
| 0. Preflight | `require_macos_arm64`. Check `xcodebuild -version`, `python3 --version`, `git --version`. Check Metal toolchain: `xcodebuild -downloadComponent MetalToolchain` is NOT run automatically (it needs a download + possible prompt). Instead check and die with the exact command to run (F-8) | Never skipped |
| 1. depot_tools | If `$ENGINE_ROOT/depot_tools/.git` missing: `git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$ENGINE_ROOT/depot_tools"`. Then `git -C … fetch --quiet` + `git -C … checkout --quiet $DEPOT_TOOLS_COMMIT`. Die if the checkout is dirty | Stamp matches + `rev-parse HEAD` = pin |
| 2. git cache | If `$ENGINE_ROOT/git_cache` missing or empty: print the warning that the first fill is slow and must come from the GCS bootstrap / an existing cache copy, then STOP with instructions (see edge cases). Do not start a multi-day googlesource fetch silently | Cache dir non-empty |
| 3. Sync | `export_engine_env`; `require_no_build_running`; `acquire_lock sync`. Mirror `sync-chromium.sh` semantics: fetch the Chromium tag into `chromium_git/chromium/src`, checkout `$CHROMIUM_TAG`, then `gclient sync --nohooks --with_branch_heads --force --reset -D -j 12`, then the CEF automate step with `--branch=$CEF_BRANCH --no-chromium-update --no-depot-tools-update --no-build --no-distrib --arm64-build` (copies `cef/` in, applies CEF patches via `patcher.py`). Then verify `cef` HEAD = `$CEF_COMMIT`; if CEF moved, `git -C src/cef checkout --quiet $CEF_COMMIT` and re-run the CEF patch step, in that order | `--skip-sync`, or stamps + both HEADs match pins |
| 4. Hooks | `gclient runhooks -j 12` (in `chromium_git/chromium`). Verify `src/build/util/LASTCHANGE.committime` exists (as `hooks-and-build.sh` does) | `--skip-hooks`, or stamp + file exists |
| 5. Verify | Run `engine-status` (§10.1). Bootstrap succeeds only if status exits 0 or reports only "Open patches not yet applied" on a zero-patch series | Never skipped |

Edge cases (handle exactly as written):

- **Empty git cache on a fresh machine.** The cache is ~tens of GB and comes
  from Google's GCS snapshots or a copy from another Open machine. The script
  must NOT invent a GCS URL. It dies with: `git cache is empty. Copy a warm
  cache to <path> or follow the GCS bootstrap in ~/Developer/open-engine/sync.sh
  comments, then re-run.` (If `sync.sh` has no such comment at implementation
  time, die with the copy instruction only and file the gap in the PR.)
- **Disk space.** Before Phase 3, require ≥ 150 GB free on the volume that
  holds `$ENGINE_ROOT` (`df -k`). Die with the free-space number if short.
  (Chromium tree + out dir + cache exceed 100 GB. 150 GB is the safe gate.)
- **Network failure mid-sync.** `gclient` is resumable. The script leaves the
  stamp unwritten, logs the failing command, and exits 1. Re-running resumes.
  Never add `--reset` beyond what Phase 3 already specifies.
- **Xcode license / first-launch.** If `xcodebuild -version` fails, die with
  `run: sudo xcodebuild -license accept && xcodebuild -runFirstLaunch`.

Acceptance: on this Mac (already synced), `engine-bootstrap` runs in
seconds, skips Phases 1–4 with stamp messages, and ends with a green
`engine-status`. On a fresh machine it reaches the same green status with no
manual git commands.

### 6.3 `engine-apply` — CEF patches, then Open patches, then overlay

Purpose: make the tree exactly match `VERSIONS` + series + overlay.
Idempotent: a second run applies nothing and exits 0.

Usage:

```text
engine-apply [--dry-run] [--only chromium|cef|rust|overlay] [--status-file <path>]
```

Steps in order:

1. `load_versions`, `export_engine_env`, `require_no_build_running`,
   `acquire_lock apply`.
2. **Pin check.** `git -C "$SRC_DIR" rev-parse HEAD` must equal
   `$CHROMIUM_COMMIT` and `git -C "$SRC_DIR/cef" rev-parse HEAD` must equal
   `$CEF_COMMIT`. On mismatch, die and name both values + the expected pin +
   `run engine-bootstrap or engine-rebase`. Never auto-checkout in apply.
3. **CEF's own patches.** Run CEF's patcher the way CEF does:
   `python3 "$SRC_DIR/cef/tools/patcher.py"` from `$SRC_DIR/cef` (this is the
   command in `cef/tools/gclient_hook.py`). The patcher skips applied patches
   (F-4). Capture its summary line (`N patches total (…)`). If it reports any
   `failed`, die and point at the log. Do not pass `--force` or edit
   `patch.cfg`.
4. **Open patches**, for each series in order `chromium`, then `cef`, then
   `rust` (skip a series with `--only`). For each non-comment, non-DISABLED
   line:
   - Patch path = `patches/<series>/<file>`. Missing file → die.
   - Already applied? `git -C "$SRC_DIR" apply --reverse --check <patch>`
     succeeds → log `already applied: <file>`, continue.
   - Else apply: `git -C "$SRC_DIR" apply --3way --whitespace=nowarn <patch>`.
     `--3way` is mandatory (it uses blob hashes to land a patch whose context
     drifted but whose base is known).
   - On failure: STOP. Do not try the next patch. Write the conflict report
     (§ below), print its path, exit 1.
5. **Overlay copy.** For every file under `Engine/fork/src/` (except
   `*.open` fragments, §7.3, and `.gitkeep`): destination = `$SRC_DIR/<relpath>`.
   Copy only if content differs (`cmp -s`). Log each copied file.
   Never delete a tree file because an overlay file vanished; deletions are
   manual and are called out in the PR (a stale overlay file in the tree is
   caught by `engine-status` §10.1 overlay-hash check).
   The two `.open` fragments are merged by the Rust step (§7.4), not copied.
6. **State write.** Write `$STATE_DIR/applied.json`:
   `{"chromium": "<commit>", "cef": "<commit>", "patches": {"<file>": "applied|already-applied|disabled", …}, "overlay_files": <n>, "applied_at": "<ISO 8601>"}`.
   Write to a temp file, then rename (atomic). `--status-file` also copies it
   there (used by `engine-status` and CI later).
7. Log `apply complete: <a> applied, <b> already applied, <c> disabled, <d> overlay files copied`.

Conflict report (on any patch failure). Create
`$ENGINE_ROOT/logs/conflicts/<YYYYmmdd-HHMMSS>/` with:

- `patch.txt` — copy of the failing `.patch` file.
- `git-apply.out` — full stdout+stderr of the failed `apply` command.
- `status.txt` — `git -C "$SRC_DIR" status --short` output.
- `diff.txt` — `git -C "$SRC_DIR" diff` output (the partial state).
- `README.txt` — exactly: the patch name, the series line, the instruction
  `fix the tree or the patch, then run engine-refresh-patches, then re-run engine-apply`, and the note that `.rej` files (if any) are in the tree and
  must be resolved by hand. Never auto-delete `.rej`/`.orig` files.

Edge cases:

- **Patch file has Windows line endings or no trailing newline:** `git apply`
  handles both; `--whitespace=nowarn` keeps it quiet. Do not "fix" patch
  files by hand-editing hunks — regenerate with §6.4.
- **`--3way` cannot find the base blob** (patch was made in a different tree):
  `git apply` falls back to direct apply and may fail. The fix is always
  §8's workflow (re-make the patch in this tree), never `--reject` as a
  shipping path. `--reject` is allowed only as a manual debugging step by the
  operator, outside the script.
- **Series lists a patch twice:** die before applying anything
  (`series <name> lists <file> twice`).

Acceptance: with the Phase A empty series, `engine-apply` verifies pins,
runs the CEF patcher (all skipped), copies the overlay placeholders, writes
state, exits 0. Run twice: second run copies 0 files. `--dry-run` writes
nothing (prove with `git -C "$SRC_DIR" status --short` before/after — the
CEF-dirty baseline must be identical).

### 6.4 `engine-refresh-patches` — regenerate patch files from the tree

Purpose: the inverse of apply. The operator edited the tree (to fix a
conflict or write a patch); this script regenerates the `.patch` files so
the repo again matches the tree. Stable output: no timestamps, deterministic
order, re-runnable with zero diff when the tree matches the patches.

Usage:

```text
engine-refresh-patches [--dry-run] [--series chromium|cef|rust]…
Config: each series has a sibling manifest (see below).
```

Manifest (new file per series, created in Phase A with header only):

- `patches/chromium/manifest`, `patches/cef/manifest`, `patches/rust/manifest`.
- Format: one patch per block:

```text
# <file>.patch
paths: <space-separated pathspecs relative to src/>
```

Example (illustrative, ad-block wiring patch):

```text
# 0002-adblock-throttle-hook.patch
paths: cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc cef/libcef/browser/chrome/chrome_content_browser_client_cef.h
```

Regeneration algorithm per patch block, in series order:

1. `require_no_build_running`, `acquire_lock refresh`.
2. For the block's `paths:` list, run:
   `git -C "$SRC_DIR" diff --no-color --binary --src-prefix=a/ --dst-prefix=b/ -- <paths…>`
   plus `git -C "$SRC_DIR" diff --no-color --cached -- …` if the index is
   non-empty for those paths (operator staged work). Concatenate working-tree
   diff first, then staged diff. If the combined output is empty AND the
   patch file already exists → die: `patch <file> is now empty; remove its series line and the file, or restore the change`. Never write an empty
   patch file silently.
3. Write to `patches/<series>/<file>.tmp`, then rename over the patch file.
   `git diff` output contains no timestamps, so a no-change refresh is
   byte-identical. Verify: run refresh twice; `git status` in THIS repo must
   show no change after the second run.
4. Overlay files are NOT refreshed (they are copied, not diffed). New
   untracked files in the tree (`git status` `??` under a manifest path) →
   die with: `untracked file <path> is not in the overlay; copy it to Engine/fork/src/<path> (new files are overlay, §3.2)`.

Ordering guarantee: blocks are processed in series order; paths within a
block are sorted (`LC_ALL=C sort`). Two runs on the same tree produce
byte-identical patch files (`diff` clean). `common.sh` sets `LC_ALL=C` for
all refresh git commands.

Acceptance: on the Phase A tree (no Open patches), refresh with empty
manifests prints `no patches to refresh` and exits 0, and `git status` in
the repo stays clean.

### 6.5 `engine-build` — dev or release, bounded, detached-safe

Usage:

```text
engine-build [--config dev|release] [--target <gn-target>] [--regen] [--detach] [--jobs <n>]
Defaults: --config dev --target cefsimple --jobs $BUILD_JOBS_DEFAULT (10)
```

Behavior:

1. `load_versions`, `export_engine_env`, `acquire_lock build`.
   Out dir = `$OUT_DIR_DEV` or `$OUT_DIR_RELEASE` from `VERSIONS`.
2. **Out dir setup.** If `$SRC_DIR/<out>/args.gn` does not exist, or `--regen`
   is passed: copy the arg file in and run `gn gen`:
   - dev: `cp gn/dev.args.gn <out>/args.gn`
   - release: copy `gn/dev.args.gn`, append `gn/release.args.gn` (§5.2 merge
     rule), run the PGO-profile gate (§5.2), then
     `gn gen <out>` via depot_tools `gn` (on PATH after `export_engine_env`;
     use `vpython3` form only if plain `gn` is absent — detect, do not assume).
   If `args.gn` exists and `--regen` is not passed, do NOT touch it and do
   NOT re-run `gn gen` unless a `BUILD.gn` in the tree is newer (ninja
   re-runs gen itself when needed; trust ninja, log that you are trusting it).
3. **Build.** Exactly this shape (F-7), from `$SRC_DIR`:

```bash
caffeinate -dimsu nice -n 10 autoninja -C "<out>" "<target>" -j "<jobs>"
```

   Tee output to `$LOG_DIR/build-<config>-<YYYYmmdd-HHMMSS>.log`. On exit,
   print a summary block: config, target, out dir, elapsed seconds, exit
   code, last 5 log lines, and the path of the built target
   (`<out>/cefsimple` for the default target; `<out>/Chromium Embedded Framework.framework` for framework targets). Non-zero ninja exit → script
   exits with the same code. Never retry automatically.
4. **`--detach` (own session, rule 9).** Re-executes itself detached:

```bash
python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  "$0" --config "<config>" --target "<target>" --jobs "<jobs>" >>"$LOG_DIR/build-<config>-detached.log" 2>&1
```

   The parent prints `detached build started: log <path>` plus the exact
   `tail -f` command, and exits 0 immediately. The detached child must NOT
   also pass `--detach` (guard with an env var `OPEN_ENGINE_DETACHED=1`).

Edge cases:

- **Kernel panic history (F-7):** `--jobs` above 10 prints a warning that
  names the watchdog-panic history and requires `--jobs` to be passed
  explicitly (it is, by construction) — then proceeds. Never default above 10.
- **`cefsimple` vs framework target:** `cefsimple` is the smoke target
  (§10.3). The framework the app consumes comes from `engine-distrib` (§6.6),
  not from a direct framework ninja target in v1.
- **Stale lock from a crashed build:** `acquire_lock` message (§6.1) tells
  the operator the exact path to remove. The script never removes it.

Acceptance: `engine-build --dry-run` is not required. Acceptance is:
`engine-build` (dev, default target) on the current tree exits 0,
`out/Release_GN_arm64/cefsimple` exists and is newer than the log start, and
the summary block prints. While the stock build is still running, do NOT
run this for acceptance (§11 gates it).

### 6.6 `engine-distrib` and `tools/fetch-engine.sh`

`engine-distrib` — make the binary distribution the app consumes:

```text
engine-distrib [--config dev|release] [--skip-build]
```

1. Unless `--skip-build`: run the `engine-build` logic for the same config
   with the default target (call the script; do not duplicate its code:
   `"$SCRIPT_DIR/engine-build" --config "<config>"`).
2. Run the CEF distrib step exactly as the proven `build-engine.sh` does,
   from `$SRC_DIR`, with `export_engine_env` active:

```bash
export CEF_ARCHIVE_FORMAT=tar.bz2
python3 "$ENGINE_ROOT/automate/automate-git.py" \
  --download-dir="$ENGINE_ROOT/chromium_git" \
  --depot-tools-dir="$ENGINE_ROOT/depot_tools" \
  --branch="$CEF_BRANCH" --no-update --no-build --force-distrib \
  --minimal-distrib --no-debug-build --arm64-build
```

   Note: `automate/` lives at `$ENGINE_ROOT/automate/automate-git.py`
   (outside `chromium_git`). Verify that path at Step 9; if it differs,
   stop and report (do not search the disk for another copy).
3. Discover the result: list `$SRC_DIR/cef/binary_distrib/` (F-9). There must
   be exactly one new/updated child dir (or one `.tar.bz2`). If more than
   one candidate matches, die and list them. Write the chosen path to
   `$STATE_DIR/distrib.txt` (single line, absolute path). Print its size
   (`du -sh`) and its top-level entries (`ls`).

`tools/fetch-engine.sh` — point the app at that distrib:

```bash
#!/bin/bash
set -euo pipefail
# Copies the CEF binary distribution built by engine-distrib into Vendor/cef/.
ENGINE_ROOT="${OPEN_ENGINE_ROOT:-$HOME/Developer/open-engine}"
STATE_FILE="$ENGINE_ROOT/.open-engine-state/distrib.txt"
DEST="$(git rev-parse --show-toplevel)/Vendor/cef"
[ -f "$STATE_FILE" ] || { echo "fetch-engine: no distrib recorded; run Engine/fork/scripts/engine-distrib first" >&2; exit 1; }
SRC="$(cat "$STATE_FILE")"
[ -d "$SRC" ] || { echo "fetch-engine: recorded distrib $SRC does not exist" >&2; exit 1; }
mkdir -p "$DEST"
rsync -a --delete "$SRC"/ "$DEST"/
echo "fetch-engine: $SRC -> $DEST"
```

Rules: `--delete` is safe here because `Vendor/` is git-ignored build input
(F-14). If `$SRC` is a `.tar.bz2` file instead of a dir, extract to a temp
dir first (`tar -xjf` into `mktemp -d`, trap-cleanup), then rsync its single
top-level dir. Acceptance: after distrib + fetch, `Vendor/cef/` exists,
contains `Chromium Embedded Framework.framework` (or the CEF distrib
equivalent), and `git status` in the repo shows NO new tracked changes.

### 6.7 `engine-rebase` — move to a new Chromium/CEF version

Usage: `engine-rebase --chromium <tag> --cef-branch <n> [--cef-commit <hash>]`.
With no flags it prints the checklist and exits 0 (checklist mode is the
default until Step 11 has run once for real).

The script is a guarded checklist runner, not a fully automatic rebase.
It executes the mechanical steps, stops at every conflict, and prints the
exact next manual step. Full narrative: §12. Mechanical sequence:

1. Print the plan (old pins → new pins from flags) and require the operator
   to type the new Chromium tag to confirm. No `--yes` flag. Rebases are rare
   and deliberate.
2. `require_no_build_running`, `acquire_lock rebase`. Verify the tree is in
   the applied state (`engine-status` clean). If Open patches are not fully
   applied, die: `rebase needs a fully applied tree; run engine-apply first`.
3. Record the pre-rebase state: `git -C "$SRC_DIR" diff > $STATE_DIR/pre-rebase-tree.diff`
   (this is the safety net; it can be large, it stays out of the repo).
4. Update `VERSIONS` in a scratch copy, sync to the new pins (bootstrap
   Phases 3–4 with the new values), run CEF's `patch_updater.py` equivalent
   flow ONLY as CEF documents it (`cef/CHROMIUM_UPDATE.txt` in the tree is
   the authority — read it at rebase time; do not hard-code its steps here).
5. Re-apply Open patches with `engine-apply`. For each conflicting patch:
   stop, print the conflict report path (§6.3), and print the fix loop:
   `resolve in tree → engine-refresh-patches → engine-apply → continue`.
   A patch that no longer applies because upstream absorbed it gets a
   `# DISABLED: absorbed upstream (<crrev or cef commit>)` series line and a
   note in the PR. Never delete the patch file in the rebase PR.
6. Regenerate Rust vendor files if `third_party/rust` moved (§7.5).
7. Build dev (§6.5), run the full verification (§10), then commit `VERSIONS`
   + refreshed patches + overlay changes as ONE rebase PR. The PR description
   lists: old → new pins, each patch (clean / fixed / disabled + why), build
   time, and smoke results.

---

## 7. Rust third-party crates: the Chromium way

This section implements D-6. It covers HOW the `adblock` crate enters the
build. The service, throttle, and cosmetic design are in
[adblock-design.md](../adblock-design.md) §Integration plan. Do not redesign
them here.

### 7.1 Shape in the tree (target state after Step 8)

```text
chromium/src/
  third_party/rust/
    chromium_crates_io/
      Cargo.toml            # PATCHED by us: + adblock (+ rmp pin) direct dep
      gnrt_config.toml      # PATCHED by us: + [crate.adblock] config if needed
      Cargo.lock            # regenerated by gnrt (captured in the rust patch)
      vendor/
        adblock-v0/…        # GENERATED by gnrt vendor (captured, never hand-edited)
        <each transitive dep>-v<epoch>/…
    adblock/
      v0/BUILD.gn           # GENERATED by gnrt gen (captured)
      v0/README.chromium    # GENERATED by gnrt vendor (license record)
  open/adblock/             # OVERLAY (our code, §3.1): service, throttle, FFI wrapper
    BUILD.gn
    open_adblock_service.{h,cc}
    open_adblock_url_loader_throttle.{h,cc}
    rust_wrapper/…          # CXX bridge crate if needed (see §7.4)
```

Epoch note: `gnrt` maps version `0.8.11` to epoch dir `v0`. Verify the exact
dir name from `gnrt` output at Step 8. Do not hard-code `v0` in GN deps
until you have seen the generated target name
(`//third_party/rust/adblock/v0:lib` or the name `gnrt gen` prints).

### 7.2 Which files are hand-edited, generated, or overlay

| File | Kind | Home in this repo |
|---|---|---|
| `third_party/rust/chromium_crates_io/Cargo.toml` (add `adblock`) | Hand-edited upstream file | Overlay fragment `src/third_party/rust/chromium_crates_io/Cargo.toml.open` merged by §7.4, PLUS the merged result captured in the rust patch so a clean apply reproduces it without running Cargo |
| `third_party/rust/chromium_crates_io/gnrt_config.toml` | Hand-edited upstream file | Same pattern: `gnrt_config.toml.open` fragment + captured result |
| `Cargo.lock`, `vendor/**`, `adblock/v0/{BUILD.gn,README.chromium}`, every transitive dep's `BUILD.gn`/`README.chromium` | Generated | Captured as patch file(s) in `patches/rust/` by §7.5. Never hand-edit. To change: re-run `gnrt`, recapture |
| `open/adblock/**` (service, throttle, wrapper) | Our new code | Overlay `Engine/fork/src/open/adblock/**` |
| Wiring: `cef` BUILD deps, `ChromeContentBrowserClientCef` override | Edits to existing files | `patches/cef/` or `patches/chromium/` per §3.2 (content from engine-patches/adblock plan) |

Why both a fragment AND a captured patch? The fragment records INTENT
(human-readable, reviewable, survives rebase). The captured patch records
the exact RESULT (applies on a clean tree with no network and no Cargo).
`engine-apply` uses the patch. `engine-rebase` uses the fragment to redo the
intent on the new tree, then recaptures. If the two disagree, the patch wins
for apply and `engine-status` flags the drift.

### 7.3 The overlay fragments — exact initial content

`src/third_party/rust/chromium_crates_io/Cargo.toml.open`:

```toml
# Open fragment. Merged into third_party/rust/chromium_crates_io/Cargo.toml
# by the Rust step (§7.4). Direct dependencies only; gnrt finds transitive deps.
# Pins: docs/adblock-design.md §Benchmark (adblock 0.8.11 + rmp 0.8.11, MPL-2.0).
adblock = "=0.8.11"
```

Plus, ONLY if `gnrt` resolves a newer `rmp` than 0.8.11 (check
`Cargo.lock` after vendor), add the pin line `rmp = "=0.8.11"` to the
fragment and note why in `licenses/THIRD_PARTY.md`. Do not add speculative
pins for other transitive deps; let `gnrt` resolve them, then review the
full list (§7.5 step R5).

`src/third_party/rust/chromium_crates_io/gnrt_config.toml.open`:

```toml
# Open fragment. Merged into gnrt_config.toml by §7.4.
# Add a [crate.adblock] table ONLY if gnrt vendor/gen requires one
# (license file name, allow_unsafe, group). Default: no table.
# The crate runs in the browser process. If the security review (F-11
# checklist) finds the rule of 2 is not met, set group = "sandbox" here
# and STOP — the ad-block design assumes browser-process execution;
# a sandbox move needs a design change, not a config tweak.
```

### 7.4 Merge + vendor + gen procedure (run by the operator; scripted as `engine-apply --only rust` helper steps)

The script does these steps in order. Each step logs its command. Any
failure stops the script. Network is required (crates.io via Cargo) except
in the pure-apply path (patch already captured).

- **R1. Merge fragments.** In the tree: insert the fragment's dep lines into
  `third_party/rust/chromium_crates_io/Cargo.toml` under `[dependencies]`
  (sorted, `LC_ALL=C`). If the line already exists with the same version,
  skip (idempotent). If it exists with a DIFFERENT version, die and name
  both versions. Same rule for `gnrt_config.toml`.
- **R2. Vendor.** From `$SRC_DIR`: `vpython3 tools/crates/run_gnrt.py vendor`.
  This downloads crate sources into `chromium_crates_io/vendor/` and applies
  any `chromium_crates_io/patches/`. Requires network. On failure, log the
  full output; the usual cause is a version that does not build under the
  Chromium toolchain (F-12) — do NOT "fix" it by switching to system cargo.
- **R3. Gen.** `vpython3 tools/crates/run_gnrt.py gen`. Generates every
  `BUILD.gn`. If it reports missing inputs (`include_str!` files), add them
  via `gnrt_config.toml` (`extra_input_roots`) per
  `README-importing-new-crates.md` troubleshooting, then re-run R3.
- **R4. Build the crate alone before wiring it in:**
  `autoninja -C out/Release_GN_arm64 third_party/rust/adblock/v0:lib -j 10`
  (use the real generated target name from R3). This must pass under the
  Chromium toolchain. Record the exact `rustc` version in the PR
  (`third_party/rust-toolchain/VERSION` first line).
- **R5. Review the transitive closure.** List every new dir under
  `chromium_crates_io/vendor/` that R2 created. For each: record name,
  version, license (from its `README.chromium`) in
  `licenses/THIRD_PARTY.md` (§7.7). Flag any copyleft beyond MPL-2.0
  (GPL/LGPL/AGPL) and STOP for lead review. Flag any crate with `unsafe`
  for the rule-of-2 note (F-11). Do not proceed to wiring with an
  unreviewed closure.
- **R6. Capture.** Run §7.5. Commit the capture patch + fragments +
  `THIRD_PARTY.md` together.

Apply path (no network): once R6 has landed, `engine-apply` treats
`patches/rust/` like any other series (git apply). `gnrt` is NOT run during
a normal apply. Re-running R1–R3 is a deliberate refresh/rebase action only.

### 7.5 Capturing generated files (`patches/rust/`)

Command (from `$SRC_DIR`, after R3):

```bash
git add -f third_party/rust/chromium_crates_io/vendor third_party/rust
git diff --cached --no-color --binary > "$FORK_DIR/patches/rust/0001-adblock-vendor.patch.tmp"
```

Then rename over `patches/rust/0001-adblock-vendor.patch` and add the series
line:

```text
0001-adblock-vendor.patch  # gnrt vendor+gen output for adblock 0.8.11 closure (generated; §7.5)
```

Size warning (decide at Step 8, record the decision in the PR): vendored
sources for the `adblock` closure may be several MB of patch. That is
expected and is the Chromium way (Chromium commits vendored sources). If the
patch exceeds ~20 MB, STOP and ask the lead: alternatives are (a) accept it,
(b) keep vendor output out of the repo and make `engine-apply --only rust`
run R1–R3 with network on every fresh machine. Do not silently pick (b);
(a) is the default because apply must work offline.

Manifest for refresh: `patches/rust/manifest` gets one block:

```text
# 0001-adblock-vendor.patch
paths: third_party/rust
```

`engine-refresh-patches --series rust` then recaptures with the same
`git add -f` + `diff --cached` rule (refresh must use the staged form for
this series, because vendored files are git-ignored inside crates).

### 7.6 Phase A placeholder (no tree access needed)

In Phase A, create ONLY:

- `src/open/adblock/README.md` — states: crate pin, MPL-2.0, target shape
  (`OpenAdBlockService` + `OpenAdBlockURLLoaderThrottle` per adblock-design),
  "no code until Step 8", and the R1–R6 pointer to this section.
- The two `.open` fragments (§7.3).
- `patches/rust/series` + `patches/rust/manifest` with headers and zero entries.
- The `adblock` row in `licenses/THIRD_PARTY.md` (§7.7).

### 7.7 License tracking

`licenses/THIRD_PARTY.md` format — one row per crate, header exactly:

```markdown
# Third-party dependencies in the engine fork

Every new dependency needs a row here in the same PR that introduces it
(repo rule: minimal dependencies, each with a written reason).

| Crate / library | Version | License | Used by | Reason | Source offer / notes |
|---|---|---|---|---|---|
| adblock (Brave adblock-rust) | 0.8.11 | MPL-2.0 | //open/adblock (browser process) | Network + cosmetic matching at uBlock quality; see docs/adblock-design.md | MPL files stay under MPL-2.0; source offer in this repo (vendored sources in patches/rust/) + LICENSE text in licenses/MPL-2.0.txt |
```

Rules:

- `licenses/MPL-2.0.txt` is copied verbatim from the vendored crate
  (`vendor/adblock-v0/LICENSE*`) at Step 8. Do not type it from memory.
- Transitive deps each get a row at Step 8 (R5). Their `README.chromium`
  files (generated) are the per-crate license record in the tree; this file
  is the human index in the repo.
- Filter lists (EasyList etc.) are DATA, not code deps. They are tracked by
  the ad-block feature plan, not here. Do not add them to this table.
- Any license change on a version bump blocks the bump PR until this file is
  updated. `engine-status` does not check licenses; the reviewer does.

---

## 8. Patch authoring workflow (daily use)

How a new Open patch is born. The engine-patches plan says WHAT; this says HOW.

1. Start from a fully applied, verified tree (`engine-apply`, then
   `engine-status` green).
2. Edit the tree directly. Keep the change to one logical unit (D-3).
   New files go straight into `Engine/fork/src/<path>` (copy them there now;
   also copy into the tree, or let the next `engine-apply` do it — but say
   which in the PR).
3. Add the patch block to the right `manifest` (`paths:` list) and the line
   to the right `series`. Pick the next free numeric prefix.
4. Run `engine-refresh-patches`. Review the generated `.patch` file IN FULL
   in this repo. If the diff contains files you did not intend, fix the
   manifest `paths:` list. Never hand-edit the `.patch` file.
5. Prove the round-trip: in the tree, revert ONLY your change
   (`git -C "$SRC_DIR" checkout -- <paths>` for tracked files — operator
   action, never scripted), run `engine-apply`, confirm the patch lands and
   `git -C "$SRC_DIR" diff -- <paths>` matches what refresh produced.
6. Build (`engine-build`), verify (§10), open the PR. One patch (or one
   overlay feature) per PR where practical.

Patch-size rules (also §9):

- A patch that touches a widely-included header (`.h` included from many
  `.cc` files) needs a rebuild-cost note in the PR (§9.2).
- Prefer a new overlay file + a 5-line wiring hunk over a 200-line hunk in
  an upstream file. Reviewers read hunks; builders rebuild headers.
- Never mix a version bump, a GN arg change, and a feature patch in one PR.

---

## 9. Rebuild cost: keep the dev loop fast

### 9.1 What triggers what (Chromium/GN/Ninja facts for this tree)

| Change | `gn gen` needed? | Typical rebuild | Notes |
|---|---|---|---|
| Overlay `.cc` edit (one file in `//open/…`) | No (ninja re-gens if `BUILD.gn` changed) | That file + link of its targets (minutes) | The fast loop. Stay here |
| Overlay `BUILD.gn` edit | Ninja auto-reruns `gn gen` | Gen (~10 s class) + affected targets | Fine |
| Patch hunk in one `.cc` | No | That file + dependents link | Fine |
| Patch hunk in a header included everywhere (e.g. a `blink` public header, `content` browser header) | No | Hundreds to thousands of files (tens of minutes to hours) | Avoid. Forward-declare, use a new header, or move the declaration to a `.cc`-private header |
| `gn/*.args.gn` change in a live out dir | Yes, explicit | Near-full rebuild (flags change everywhere) | Never edit live `args.gn` casually. New out dir instead (D-7) |
| `third_party/rust` vendor/gen update | Ninja handles | Affected Rust crates + link | One crate bump can cascade through dependents; build the crate target alone first (§7.4 R4) |
| CEF patch update (upstream CEF bump) | Via CEF project gen | Large | Only inside `engine-rebase` (§12) |
| `is_official_build` flip | Yes | Full rebuild in a new out dir | Release dir is separate for this reason |

### 9.2 Rules to keep patches cheap

1. New code in new overlay files. Existing-file hunks only wire it in.
2. Never add a method or field to a widely-included upstream header when a
   free function in `//open/…` or a CEF-side class in `src/cef/…/open/` does
   the job.
3. Never change an upstream `BUILD.gn` beyond the one `deps`/`sources` line
   the wiring needs.
4. Keep the incremental out dir alive: always build in
   `out/Release_GN_arm64` for dev. A deleted out dir costs a full rebuild
   (hours). Scripts never delete out dirs; `engine-rebase` keeps the old out
   dir until the new build is green.
5. Use `engine-build` (bounded `-j 10` + `nice`) for every build, including
   "quick" ones. An unbounded manual `autoninja` risks the watchdog panic
   (F-7) and starves the Mac.
6. Measure before optimizing: `autoninja -C out/Release_GN_arm64 <target> -j 10`
   prints elapsed time; record it in the PR for any header-touching patch.

---

## 10. Verification (no unit tests)

Three layers. All must pass for a build to be called good. Record real
output in the PR. Do not use computer use (desktop driving) for any check.

### 10.1 `engine-status` — patch and pin status script

Path: `Engine/fork/scripts/engine-status`. Language: Python 3 (stdlib only).
Executable. Read-only: it must never write to the Chromium tree. It may write
only its own stdout/stderr and, with `--json <path>`, one JSON file in the
repo working dir or `$STATE_DIR`.

Usage: `engine-status [--json <path>] [--strict]`. Exit 0 = all checks pass.
Exit 1 = at least one check failed. `--strict` also fails on warnings.

Checks in order. Print one line per check: `PASS|FAIL|WARN  <name>  <detail>`.

| # | Check | Pass condition | Failure detail must name |
|---|---|---|---|
| S-1 | Pins | `src` HEAD = `CHROMIUM_COMMIT`, `cef` HEAD = `CEF_COMMIT`, `depot_tools` HEAD = `DEPOT_TOOLS_COMMIT`, `describe --tags` = `CHROMIUM_TAG` | expected vs actual for each |
| S-2 | CEF patches | `cef` patcher state: re-running the check form of the patcher logic (or parsing its summary on a dry invocation if the tool supports it; otherwise verify a known CEF-patched file contains its marker change — pick `src/.gn` diff presence) shows CEF patches applied. If the method is uncertain at implementation time, implement S-2 as: `git -C src diff --stat` is non-empty AND `cef/patch/patch.cfg` files all exist. Mark the check `WARN` with the method used, never fake a PASS | which file/marker was probed |
| S-3 | Open patches | For each series entry: `git apply --reverse --check` succeeds (= applied) → PASS. `# DISABLED:` entries → WARN (listed). Unapplied → FAIL | patch file name |
| S-4 | Overlay | For each overlay file (excluding `*.open`, `.gitkeep`): tree copy exists and `cmp` is byte-identical → PASS. Missing or different → FAIL. Tree files under `open/` and `cef/libcef/browser/open/` with no overlay counterpart → WARN (stale file) | relative path |
| S-5 | GN args | If `<out>/args.gn` exists: every key in `gn/dev.args.gn` matches the live value → PASS. Drift → WARN with the differing keys (CEF automate may add keys; extra keys are WARN, changed values are FAIL under `--strict`, WARN otherwise) | key names |
| S-6 | Build outputs | `<out>/cefsimple` exists (dev) → PASS/WARN if missing ("not built yet" is WARN, not FAIL, before Step 7). Framework dir present in the latest distrib (`distrib.txt`) → same treatment | paths probed |
| S-7 | Symbols | §10.2. Missing expected symbol → FAIL (after Step 8; before that, `expected-symbols.txt` holds only stock CEF symbols) | symbol name |
| S-8 | Series sanity | No duplicate entries, every listed patch file exists, numeric order matches file order (D-4) | file/line |

Final line: `engine-status: <p> pass, <f> fail, <w> warn`.

### 10.2 Symbol check (`verification/expected-symbols.txt`)

Format: one symbol per line, `#` comments. Use the exact `nm` spelling
(leading underscore on macOS). Initial content (stock CEF, prove at Step 7):

```text
# Stock CEF C API entry points (prove with nm at Step 7; fix spellings from real output)
_cef_execute_process
_cef_initialize
_cef_shutdown
_cef_version_info
```

Check command (in `engine-status` S-7 and runnable by hand):

```bash
FW="$SRC_DIR/out/Release_GN_arm64/Chromium Embedded Framework.framework/Chromium Embedded Framework"
# If the framework binary path differs, find it: find <out> -name "Chromium Embedded Framework" -type f
nm -gU "$FW" | awk '{print $NF}' | sort -u > /tmp/open-symbols.txt
# Every non-comment line of expected-symbols.txt must appear in that list.
```

When the engine-patches plan adds Open API (ad-block service entry points,
extension bridge, …), add each new exported symbol there in the same PR that
adds the API. A symbol that is C++-mangled must be listed mangled AND with a
`# demangled: …` comment (`xcrun swift-demangle` or `c++filt` to read it).
Never list a symbol you have not seen in real `nm` output.

### 10.3 Smoke checks — `verification/smoke-checklist.md`

Create this file with exactly these sections. Each item is a checkbox with
the expected result stated. Run by a human or by scripted launch + log
inspection. Never by driving the user's desktop.

**A. `cefsimple` launch (after every dev build).**

```bash
OUT=~/Developer/open-engine/chromium_git/chromium/src/out/Release_GN_arm64
"$OUT/cefsimple" --url=https://example.com --enable-logging=stderr --v=0 &
# wait for the window process to stay alive 10 s, then quit it cleanly (SIGTERM to that PID only)
```

Pass: process starts, no `FATAL` in stderr, page title/load completes (log
line), clean exit. Scripted form: launch with a timeout, capture stderr to
`$LOG_DIR/smoke-<date>.log`, grep for `FATAL|Check failed`, require the
process to still be alive at 10 s, then terminate ONLY that PID.

Checklist items: (1) window opens, (2) example.com renders (screenshot via
the app's own window capture only when the Open app hosts it; for raw
`cefsimple`, log-based pass is enough), (3) a second launch reuses the same
profile dir without error, (4) quit leaves no child renderer processes
(`pgrep -f cefsimple` empty after quit).

**B. Ad-block build-glue (after Step 8, before any service code).**
(1) `third_party/rust/adblock/v0:lib` (real target name) builds alone.
(2) `engine-status` S-7 still passes. (3) `cefsimple` smoke A still passes
with the crate linked or not yet linked (state which in the PR).

**C. Ad-block feature (after the engine-patches plan lands the service).**
Follow [adblock-design.md](../adblock-design.md) §Verification items 1–4
(blocked analytics URL + panel count, cosmetic hide + per-site restore,
list toggle rebuild, `engine.dat` restart). Restate them in
`smoke-checklist.md` at that time. Do not copy them into Phase A files.

**D. Open app (when `Engine/OpenEngine` exists).**
Open the real app, load a page, confirm the sidebar tab shows title + URL,
quit, relaunch, confirm restore. This section is written by the app
milestone, not fork-infra. Fork-infra ships sections A–B only.

### 10.4 What "verified" means for each PR type

| PR type | Required evidence in PR description |
|---|---|
| Scripts/layout only (Steps 1–6) | `engine-status` output, `engine-apply --dry-run` output, second-run idempotency output |
| First build wiring (Step 7) | Build summary block (§6.5), smoke A log path, `nm` check output |
| Rust vendor (Step 8) | R4 crate-build output, R5 closure table, patch size (`du -h` the patch file) |
| Any feature patch | Build summary, relevant smoke section, rebuild-time note if a header was touched (§9.2) |
| Rebase | §12 PR list (pins, per-patch outcome, build time, smoke) |

---

## 11. Implementation order (acceptance per step)

### 11.0 Gate check (run before every step)

```bash
pgrep -fl 'autoninja|siso' || echo "no build running"
ls ~/Developer/open-engine/chromium_git/chromium/src/out/Release_GN_arm64/cefsimple 2>/dev/null || echo "cefsimple not built yet"
```

If a build is running, do [NOW] steps only. Never kill the running build.

### Phase A — repo only. Run while the stock build is still running.

| Step | Work | Acceptance (all must pass) |
|---|---|---|
| 1 **[NOW]** Layout | Create every dir + file in §3.1/§3.3 with header content (§4.2 series headers, §5.3 branding README, §7.6 placeholders, empty manifests). Append §3.4 to `.gitignore` | `find Engine/fork -type f \| LC_ALL=C sort` matches §3.1 (minus `MPL-2.0.txt`); `git status` shows only new `Engine/`, `tools/fetch-engine.sh`, and the `.gitignore` edit |
| 2 **[NOW]** Pins | Write `VERSIONS` (§4.1) and `gn/dev.args.gn` (§5.1) + `gn/release.args.gn` (§5.2). Run §4.3 read-only checks | Every §4.3 output matches. `diff` of dev args vs live `args.gn` is empty (or drift copied + noted) |
| 3 **[NOW]** Common lib | Write `scripts/lib/common.sh` with exactly the §6.1 API | `bash -n` clean on the file; a throwaway probe in `/tmp` sources it and prints `FORK_DIR`, `SRC_DIR`, and a `load_versions` success line. Probe stays in `/tmp`, never in the repo |
| 4 **[NOW]** Scripts (no tree writes in test) | Write `engine-bootstrap`, `engine-apply`, `engine-refresh-patches`, `engine-build`, `engine-distrib`, `engine-rebase`, `tools/fetch-engine.sh` per §6. Each must handle `--help` without touching the tree | `bash -n` clean on all; `--help` exits 0 for each; `engine-apply --dry-run` on the current tree exits 0 and writes nothing (prove: `git -C "$SRC_DIR" status --short \| md5` before = after; CEF-patcher step in dry-run must be check-only — if `patcher.py` has no dry mode, skip it in dry-run and log `dry-run: CEF patch step skipped`) |
| 5 **[NOW]** Status + verification files | Write `engine-status` (§10.1, Python stdlib), `expected-symbols.txt` (§10.2 initial), `smoke-checklist.md` (§10.3 sections A–B) | `engine-status` runs read-only and prints the summary line. On the Phase A tree it must report S-1 PASS (pins match the live tree) and must NOT fail the run solely because `cefsimple` is unbuilt (S-6 WARN). `--json` writes valid JSON (`python3 -m json.tool` parses it) |
| 6 **[NOW]** Fork README | Write `Engine/fork/README.md`: purpose, pin/apply/build/distrib/fetch command list (copy the exact commands from §6), link to this plan + adblock-design, "never run gclient by hand" warning | README commands match the scripts' `--help` output verbatim. A reader with only the README can run status + dry-run apply |

Phase A PR: one PR, `Engine/fork/**` + `tools/fetch-engine.sh` + `.gitignore`.
Description includes Step 4–5 real outputs. No Chromium tree writes were
needed, so the running build is untouched.

### Phase B — touches the tree. Start only when §11.0 shows no build running AND the lead confirms in the thread.

| Step | Work | Acceptance |
|---|---|---|
| 7 **[WAIT]** First apply + build proof | `engine-bootstrap` (expect fast skips), `engine-apply`, `engine-build` (dev, `cefsimple`), smoke A | Bootstrap ends green; apply state file written; build summary exit 0; smoke A log has no `FATAL`; `engine-status` all PASS (S-7 with stock symbols; fix `expected-symbols.txt` spellings from real `nm` output in this PR if needed) |
| 8 **[WAIT]** Rust vendor (build glue only, no service code) | §7.4 R1–R6: merge fragments, `gnrt vendor`, `gnrt gen`, build the crate target alone (R4), review closure (R5), capture patch (§7.5), copy `MPL-2.0.txt`, fill `THIRD_PARTY.md` rows | R4 build passes under Chromium toolchain; closure table complete with licenses; patch file size recorded (STOP for lead if > ~20 MB, §7.5); re-apply on the patched tree is a no-op (`engine-apply` second run: 0 applied); smoke B passes. No service/throttle code in this PR |
| 9 **[WAIT]** Distrib + fetch | `engine-distrib`, then `tools/fetch-engine.sh`. First verify the automate path in §6.6 step 2 exists | Distrib path recorded in `distrib.txt`; `Vendor/cef/` populated; repo `git status` shows no tracked changes from the fetch; framework binary exists under `Vendor/cef/` (`find Vendor/cef -name "Chromium Embedded Framework" -type f` non-empty) |
| 10 **[WAIT]** Release config proof (can defer) | `engine-build --config release --target cefsimple` in `out/Release_Official_arm64` | Either: build green + smoke A against the release out dir, OR the PGO gate (§5.2) fires with its exact message and the PR records "release blocked on PGO profile" as a known gap. Never fake a release by copying dev output |
| 11 **[WAIT]** Rebase rehearsal (no version change) | `engine-rebase` with the SAME pins (checklist mode + mechanical steps that are safe at equal pins) | Script prints the §12 checklist, verifies applied state, and exits without changing `VERSIONS` or the tree. This proves the guard rails before a real rebase needs them |

After Step 8, the ad-block service/throttle work proceeds under
`docs/engine-patches.md` + adblock-design, using §8 for every patch. This
plan's job is done when Step 9 passes (Step 10–11 may land as follow-ups).

---

## 12. Rebase playbook (narrative for §6.7)

Frequency: CEF/Chromium bumps are deliberate, lead-scheduled events. Never
rebase inside a feature PR.

1. **Announce and freeze.** No feature patches land during the rebase.
   Confirm §11.0: no build running.
2. **Snapshot.** `engine-rebase` records `pre-rebase-tree.diff` (§6.7 step 3)
   and the old `VERSIONS` values go into the PR description verbatim.
3. **Sync new pins.** Bootstrap Phases 3–4 at the new tag/branch. CEF's own
   update flow (`cef/CHROMIUM_UPDATE.txt`, `patch_updater.py`) refreshes
   CEF's patches against new Chromium. If CEF's patcher reports failures,
   that is a CEF-version problem: pick a CEF commit built for the new
   Chromium (check `cef/CHROMIUM_BUILD_COMPATIBILITY.txt`) before touching
   any Open patch.
4. **Re-apply Open patches one series at a time** (`engine-apply --only …`).
   Conflict loop per patch: read the conflict report (§6.3) → fix in the
   tree (port the intent, do not force the hunks) → `engine-refresh-patches`
   → re-apply. If upstream absorbed the change, mark the series line
   `# DISABLED: absorbed upstream (<ref>)`. Keep the patch file.
5. **Redo Rust intent if needed.** If `third_party/rust/chromium_crates_io/`
   changed upstream, re-merge the `.open` fragments (§7.4 R1), re-run
   vendor/gen only if the crate or toolchain rev moved, recapture (§7.5).
   A `RUST_TOOLCHAIN_REV` change in `VERSIONS` always forces R2–R4.
6. **Overlay conflicts do not exist** (files are copied). But upstream may
   have created a file at an overlay path. `engine-status` S-4 WARN/FAIL
   surfaces it. Resolve by porting the overlay file to the new upstream
   neighbour files (includes, BUILD deps), never by overwriting upstream
   blindly — the apply step already overwrote it, so use
   `pre-rebase-tree.diff` + `git log` on that path to see what upstream did.
7. **Build dev, verify all of §10, build release if Step 10 is unblocked.**
   Record build times. Long builds run detached (§6.5 `--detach`).
8. **One PR.** `VERSIONS` + series/patches + overlay + `gn/` (only if args
   must change for the new version; call each arg change out) + licenses if
   the Rust closure changed. Description: old → new pins, per-patch outcome
   table, smoke output, known gaps.
9. **Rollback.** The old out dir and `pre-rebase-tree.diff` stay until the
   rebase PR merges. To roll back: restore old `VERSIONS`, re-sync (bootstrap
   at old pins), `engine-apply`, rebuild in the old out dir. State this in
   the PR so the reviewer sees the exit path.

Verification gate for a rebase PR: `engine-status` all PASS (WARN only for
DISABLED-absorbed patches, each explained), smoke A (+ C when ad blocking
exists), and a cold `cefsimple` launch on the new framework via distrib +
fetch (Step 9 flow).

---

## 13. Risks

| Risk | Impact | Mitigation in this plan |
|---|---|---|
| Patch capture patch (Rust vendor) is very large | Slow clones, painful reviews | §7.5 size gate (~20 MB) with an explicit lead decision; generated files are never hand-reviewed line-by-line (review = closure table + `BUILD.gn` spot check) |
| Chromium Rust toolchain bump breaks `adblock 0.8.11` (as `rmp-serde` broke before, F-13) | Ad-block schedule slips | Pin exact versions; prove builds under the Chromium toolchain (R4), never system cargo; D1 fallback in adblock-design stays available. Treat toolchain rev change as an engine change (§12 step 5) |
| CEF patcher and our `git apply` disagree about tree state after a crash mid-apply | Tree neither stock nor patched | Apply is ordered + idempotent (§6.3); `applied.json` is written last and atomically; `engine-status` S-2/S-3 name the exact divergent patch. Fix is always re-run apply or §8 revert, never hand-waving |
| Operator runs scripts while a build is running | Corrupt out dir, wasted hours | `require_no_build_running` + locks (§6.1); §11.0 gate; scripts die with a clear message |
| `gn gen` / automate rewrites `args.gn` unexpectedly | Silent config drift | S-5 args check; build only copies args on create/`--regen` (§6.5) |
| Framework/distrib layout differs between dev and official builds | App fetch breaks at release time | Step 10 proves release early-or-records the gap; `fetch-engine.sh` keys off the recorded `distrib.txt`, never a guessed path |
| MPL-2.0 source-offer obligation missed | License non-compliance | §7.7 table + license file in the same PR as the crate; reviewer gate. Counsel check is Open Question Q-2 |

---

## 14. Open questions (lead decides; defaults stated so work can proceed)

| # | Question | Default until decided | Blocks |
|---|---|---|---|
| Q-1 | Final app/helper bundle IDs (placeholder `app.open.Open` in §5.3) | Keep CEF helper names, placeholder app ID in scripts only | Nothing in fork-infra; blocks signing work later |
| Q-2 | MPL-2.0 distribution review (source offer form) — counsel confirmed? (adblock-design Risk 2) | Ship vendored sources + `licenses/MPL-2.0.txt` + THIRD_PARTY row; no external release before counsel OK | External builds, not Step 8 |
| Q-3 | Rust vendor patch size: accept a multi-MB generated patch in the repo, or vendor at apply time with network? (§7.5) | Accept the patch (offline apply) unless > ~20 MB | Step 8 PR shape |
| Q-4 | Does `docs/engine-patches.md` want new code under `//open/…` or `cef/libcef/browser/open/…` as the primary home? (This plan prefers `//open/…`, §3.1) | `//open/…` for new code; `cef/…/open/` only beside CEF classes | Overlay paths in feature PRs, not Steps 1–9 |
| Q-5 | PGO profile source for release (`chrome_pgo_phase=2`): use Chromium's shipped profile, collect our own, or ship phase 0 for v1? (§5.2 gate forces the question) | Gate stays; release proof (Step 10) records the gap until decided | Step 10 only |
| Q-6 | Widevine: `enable_widevine=true` is in the stock dev args (F-6). Open needs its own Widevine licensee agreement for DRM playback (arccore-engine Risk 2). Keep the flag on in dev? | Keep flags byte-identical to stock in dev (Step 2); licensing tracked outside this plan | DRM playback, not fork-infra |

None of Q-1–Q-6 blocks Phase A (Steps 1–6).

---

## Appendix A. Command cheat sheet (copy-paste)

```bash
# Status (read-only, any time)
Engine/fork/scripts/engine-status

# Apply (after the running build finishes; see §11.0)
Engine/fork/scripts/engine-apply
Engine/fork/scripts/engine-apply --dry-run

# Build dev cefsimple, detached (own session, Rule 9)
Engine/fork/scripts/engine-build --detach
tail -f ~/Developer/open-engine/logs/build-dev-detached.log

# Refresh patches after fixing a conflict in the tree
Engine/fork/scripts/engine-refresh-patches

# Distrib + app fetch
Engine/fork/scripts/engine-distrib
tools/fetch-engine.sh

# Fresh machine
Engine/fork/scripts/engine-bootstrap
```

## Appendix B. File inventory for the Phase A PR (reviewer checklist)

The reviewer confirms: (1) every file is in §3.1/§3.3 and no other file
changed except `.gitignore`; (2) no `.patch` file has content yet and both
series have zero entries; (3) `VERSIONS` values match §4.3 real output pasted
in the PR; (4) no script contains a hard-coded version string (search the PR
diff for `156.0` / `8078` / `0.8.11` — hits allowed only in `VERSIONS`,
comments, and `dev.args.gn`); (5) no Arc assets, names (except allowed
"Import from Arc", which Phase A does not use), or user data anywhere in the
diff.




## Appendix — Lead decisions (2026-10-25)

- Bundle ids: app `io.github.sergeserb2.open`; helpers `io.github.sergeserb2.open.helper`, `.helper.gpu`, `.helper.renderer`, `.helper.plugin`, `.helper.alerts`. Product name "Open".
- Home for our engine code: a top-level `//open/` directory in the Chromium tree (overlay `Engine/fork/src/open/...`), with thin hook patches into `cef/` and Chromium. Keep hook patches small.
- PGO for release builds: use Chromium's published profiles for this exact revision (`checkout_pgo_profiles=True`, `chrome_pgo_phase=2`). Dev builds stay `chrome_pgo_phase=0`.
- adblock-rust (MPL-2.0): approved. MPL is file-level copyleft: publish changes to MPL files if we modify them. Track in `licenses/THIRD_PARTY.md`; a license review happens before any public release.
- Vendor-patch size gate: accept ~20 MB.
- Widevine: out of v1 (needs a Google license).
- Phasing: Steps 1–6 now (repo only; READ ONLY access to ~/Developer/open-engine). Steps 7–11 wait for the lead, after the stock build finishes.

## Implementation deviation notes — Phase A (2026-10-25)

These decisions were confirmed by the lead during implementation:

- Keep `gn/dev.args.gn` byte-identical to the running build, including
  `enable_widevine=true`. Disable Widevine in `gn/release.args.gn` with a
  comment pointing to the lead decision. The local dev adapter ships nothing.
- Use `--minimal-distrib-only` in §6.6 instead of `--minimal-distrib`.
  Read-only inspection of the live `automate-git.py` distrib-types block
  shows the latter creates both standard and minimal outputs. Minimal-only
  meets the one-directory discovery contract and contains the app's inputs.
- Gate `engine-distrib --config release` before any build or packaging.
  The live `cef/tools/make_distrib.py` builds its input path from `Release`
  plus `_GN_arm64`; it has no official-output override. Exit nonzero with:
  `release packaging not wired yet: CEF's make_distrib expects out/Release_GN_arm64; see docs/plans/fork-infra.md Step 10`.
  Resolve this at Step 10; do not package dev output as release.

Operator details that reconcile earlier instructions:

- §6.1 requires no-argument help, but the cheat sheet uses bare modifying
  commands. Use `--all` for apply/refresh and `--run` for bootstrap/distrib/
  fetch. Build, status, and rebase keep their specified defaults.
- CEF is a separate Git repository. CEF hook patch headers retain `cef/`
  paths relative to src; apply uses the CEF repo with `-p2`, and refresh uses
  `a/cef/` and `b/cef/` prefixes. This lets mandatory three-way apply use the
  correct index and blob objects.
- The requested `docs/engine-fork.md` operator guide is added alongside the
  Phase A file inventory. These deviation notes are also an authorized
  exception to §3.3's original file boundary.

## Implementation deviation notes — Phase B (2026-10-25)

Results are in [docs/engine-fork.md](../engine-fork.md), "Phase B bring-up".

- Step 7 bootstrap ran with `--skip-sync --skip-hooks`. The stock scripts
  had synced the pinned tree and run its hooks. A sync on the CEF-dirty tree
  stops at the local-change guard, and a `gclient runhooks` rerun could touch
  `LASTCHANGE` and force a wide rebuild for no gain.
- §6.6 step 2: `engine-distrib` calls `cef/tools/make_distrib.py --minimal
  --no-symbols --no-docs --no-archive` directly instead of `automate-git.py
  --minimal-distrib-only`. On branch 8078, automate never adds
  `--no-symbols` for the minimal type, and dev builds have no dSYMs to copy.
  It also builds `cefclient`, which `make_distrib.py` needs for `Release/`.
- §10.1 S-2 runs CEF's own applied test per `patch.cfg` entry (read-only)
  and reports PASS, instead of the file-presence WARN fallback.
- Step 8 is deferred to the ad-block work (it queues behind P1). Step 10
  stops at the PGO gate (known gap, docs/followups.md).
- `gn/dev.args.gn` is no longer byte-identical to the stock args: it adds
  `disable_fieldtrial_testing_config=true` (docs/followups.md, lead).
