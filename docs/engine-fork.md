# Engine fork operator guide

Open stores the engine's pins, patches, overlays, and scripts in
[`Engine/fork/`](../Engine/fork/README.md). Chromium and CEF source stay
outside this repo. The [fork-infra plan](plans/fork-infra.md), including its
lead decisions, defines the contract. This guide covers Steps 1–6.

## Safe checks during the stock build

```bash
Engine/fork/scripts/engine-status
Engine/fork/scripts/engine-apply --dry-run
Engine/fork/scripts/engine-refresh-patches --dry-run
Engine/fork/scripts/engine-bootstrap --dry-run
Engine/fork/scripts/engine-build --dry-run
Engine/fork/scripts/engine-distrib --dry-run
Engine/fork/scripts/engine-rebase
```

These commands write no engine files. Apply skips CEF's patcher in dry-run
because it has no dry mode. It checks existing patches with Git's check
mode. It does not simulate three-way merges or the intermediate states of
an unapplied stack. A direct-check failure needs review in a disposable tree.
Status uses `GIT_OPTIONAL_LOCKS=0`. To save JSON, pass `--json <path>` with
an existing parent in this repo or `.open-engine-state`; never in Chromium.
Status exits 1 for failed checks; `--strict` also rejects warnings.

Phase A has no feature patches. The placeholder `open/adblock/README.md`
does not exist in the real engine yet, so S-4 correctly fails. S-6 and S-7
warn until outputs and symbols can be proved in Step 7. S-2 uses the plan's
limited fallback: a nonempty Chromium diff and all CEF patch files present.
It reports WARN, never a full CEF patch PASS.

## First apply and dev build — wait for the lead

Do not start any modifying command until the lead approves Phase B and
the active build has ended. The scripts also check for live build processes
and use one shared writer lock, plus a named operation lock. A stale lock
must be removed by hand only after its owner has stopped.

Use this session wrapper for bootstrap, which can sync and run hooks:

```bash
python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  Engine/fork/scripts/engine-bootstrap --run
Engine/fork/scripts/engine-apply --all
Engine/fork/scripts/engine-build --detach
```

`OPEN_ENGINE_ROOT` selects another tree. The default comes from `VERSIONS`.
Logs live in `<root>/logs/`; stamps, locks, and `applied.json` live in
`<root>/.open-engine-state/`. Do not run gclient by hand. Bootstrap exports
the cache path, disables depot_tools self-update, and sets
`checkout_pgo_profiles=True` for Chromium's published profiles.

Bootstrap requires Xcode, the Metal toolchain, Python 3, Git, a warm Git
cache, the CEF automate script at `<root>/automate/automate-git.py`, and at
least 150 GB free before sync. It does not download Metal or invent a GCS
cache URL. It prints the exact manual action if either is missing. The
local `sync.sh` mentions GCS snapshots but provides no bootstrap command.
Before a checkout or reset sync, bootstrap prints Git status counts and
the first 20 paths for the affected repositories. Dirty trees require
`--yes-discard-local-changes`. Preserve needed work before using this flag;
CEF's normal dirty baseline also needs this explicit consent when syncing.
Bootstrap reads `.gclient` solutions with `ast.literal_eval` and replaces
that assignment in place. It preserves other settings and removes duplicate
solutions assignments left by earlier runs.

Apply validates both HEAD pins before writes. It applies CEF's own patches,
then Open series in file order, then copies changed overlay files. It never
deletes stale overlay files. It skips `.open` fragments and `.gitkeep`.
Conflicts stop the run and produce a report in `logs/conflicts/<timestamp>/`.
The report contains the patch, Git output, status, diff, and fix instructions.
`--only overlay` skips CEF's patcher. Patch selections retain the CEF
prerequisite step. Partial apply merges its patch records into `applied.json`
and preserves the overlay count unless it processes the overlay itself.

Build defaults to dev with 10 jobs. An explicit `--jobs` above 10 warns
about the recorded watchdog panics. The command always uses `nice` and
`caffeinate`. Existing dev args stay untouched unless `--regen` is explicit.
Dev args match the active stock build byte-for-byte, including its missing
final newline and local Widevine adapter setting. Release args disable
Widevine per the lead decision; v1 does not ship it.
The parent takes the writer/build lock before spawning a detached build.
The child inherits the lock and releases it at exit. A concurrent detach
fails with a nonzero exit and the lock paths. Each build gets a unique
`.log` file, including two builds with the same timestamp.

## Patch and overlay workflow

New code goes in `Engine/fork/src/open/`; existing upstream files get small
hook patches. Add one rationale line to the correct `series` and a block
to its sibling `manifest`:

```text
# 0001-example.patch
paths: path/to/existing_file.cc
```

Use src-relative paths. CEF manifests start with `cef/`. CEF is a separate
Git repo, so its diff headers include `a/cef/` and `b/cef/`, and apply uses
that repository with `-p2`. Chromium and Rust patches use the src repo.
Refresh follows series order, sorts pathspecs, and captures staged and
working-tree changes in one `git diff HEAD --binary` per Chromium/CEF patch.
This replaces the concatenation described in the original plan's §6.4.
Refresh refuses empty patches or new files outside the overlay. Rust refresh
stages ignored vendor files and captures only the staged binary diff. It
then unstages the captured Rust paths while keeping their working files.
An exit trap also unstages those paths if capture fails or is empty.

```bash
Engine/fork/scripts/engine-refresh-patches --all
Engine/fork/scripts/engine-apply --all
Engine/fork/scripts/engine-status
```

Review every generated patch. Revert only the intended change by hand in a
safe tree, then prove apply reproduces it. Never hand-edit patch hunks.
Paths for different logical patches must not overlap. CEF's own patch
files stay in CEF; do not duplicate them in Open's series.

The ad-block fragments are disabled intent in Phase A. Step 8 follows
[R1–R6](plans/fork-infra.md#74-merge--vendor--gen-procedure-run-by-the-operator-scripted-as-engine-apply---only-rust-helper-steps)
with Chromium's Rust toolchain. Normal `--only rust` applies captured patches
offline. It does not merge fragments or run gnrt. Track the full crate
closure and license text when vendoring lands. No Rust dependency is
enabled by these placeholders.

## Distribution and app fetch — wait for the lead

```bash
python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  Engine/fork/scripts/engine-distrib --run
tools/fetch-engine.sh --dry-run
tools/fetch-engine.sh --run
```

Distrib records one selected output in `.open-engine-state/distrib.txt`.
The approved command uses `--minimal-distrib-only`. The plan's earlier
`--minimal-distrib` flag asks CEF for both standard and minimal output and
conflicts with its one-directory discovery rule. Only minimal output is
needed for the app: framework, headers, wrapper sources, and CMake files.
Fetch copies it to ignored `Vendor/cef/` with `rsync --delete`. A tar.bz2
input is checked for safe paths and a single top-level directory, then
extracted to a temporary directory. Fetch works from any current directory.
It writes only `Vendor/cef/` and temporary extraction files.
Distrib holds its lock across the child build and packaging. Fetch resolves
the recorded path with realpath and requires a child of
`<root>/chromium_git/chromium/src/cef/binary_distrib/`. It also requires the
framework binary before changing `Vendor/cef/`. Directory and archive
dry-runs check the source and write nothing.

The live CEF packaging code fixes its input to `out/Release_GN_arm64`.
`engine-distrib --config release` therefore stops before building or
packaging with: `release packaging not wired yet: CEF's make_distrib expects
out/Release_GN_arm64; see docs/plans/fork-infra.md Step 10`. The lead approved
this gate. Step 10 must resolve the official output path; dev output cannot
prove release. This milestone does not change the packaging tool or outputs.

## Rebase — wait for the lead

No arguments print the nine-point checklist and change nothing. With new
pins, the script requires the operator to type the tag, checks the applied
tree, and saves Chromium and CEF diffs plus old pins. It resolves proposed
commits into a scratch `rebase-VERSIONS` under state and passes that file to
bootstrap through `OPEN_ENGINE_VERSIONS`. It then stops for the documented
CEF update review, rather than inventing patch_updater commands. Review and
install the scratch pins, update Rust pins from the new tree, then apply,
refresh, build, and run the smoke checks. Keep the old output and snapshots
until the rebase PR merges. Same-pin rehearsal verifies state without a
confirmation prompt and does not change the tree or pins. New pins still
require the typed tag confirmation.

No unit tests, real builds, gnrt, smoke launches, or engine-tree changes are
part of Steps 1–6. The [smoke checklist](../Engine/fork/verification/smoke-checklist.md)
records the later build proof. Bundle IDs and MPL approval follow the lead
appendix; branding assets and feature code remain outside this milestone.

## PR #25 review fixes — 2026-10-25

All modifying verification used disposable trees with real Git repositories
for `src/` and `src/cef/`. The fake CEF patcher reproduced successful skip
output, nonzero exits, and an exit-zero summary with `3 failed`. Local
stand-ins for GN, Ninja, gclient, preflight, and packaging exercised the real
CLI control flow. These checks prove script behavior, not a Chromium build.
No unit tests were added. Every Bash script targets macOS `/bin/bash` 3.2.

| # | Finding | Fix | Result |
|---|---|---|---|
| 1 | Refresh concatenated staged and unstaged diffs | Capture one `git diff HEAD --binary` per Chromium/CEF patch; keep Rust staged-only | PASS: mixed staged/unstaged text and binary edits refresh, apply cleanly, pass reverse-check and S-3, then report `0 applied, 3 already applied, 0 overlay files copied`. Second refresh hashes match. |
| 2 | BSD mktemp template ended in `.log` | Create with trailing `XXXXXX`, then rename to `.log` | PASS: two script runs with the same timestamp label create distinct nonempty logs using macOS BSD mktemp. |
| 3 | Overlay-only apply ran CEF's patcher | Skip the patcher for `--only overlay` | PASS: the overlay copies and the patcher invocation counter stays unchanged. CEF failure summaries and nonzero exits still stop patch selections. |
| 4 | Partial apply replaced all state | Merge patch outcomes and preserve unrelated records and overlay count | PASS: overlay-only and Chromium-only runs retain all three series records and the overlay count. |
| 5 | Distrib released the lock around its child build | Acquire distrib's lock before calling build; share the owner | PASS: the same owner holds the lock through build and packaging; competing writers fail in both phases. Repeat distrib skips packaging. |
| 6 | Concurrent detach callers both reported success | Acquire the build lock in the parent; transfer cleanup to the child | PASS: simultaneous callers return one 0 and one 1 with a clear lock message. The child uses a separate session and releases both locks. |
| 7 | Empty `OPEN_ENGINE_ROOT` selected the current directory | Use `os.environ.get(...) or default` | PASS: real-tree status output and exit code match for empty and unset values. |
| 8 | Fetch accepted arbitrary recorded paths | Resolve the source under `binary_distrib/` and require the framework binary before copy | PASS: directory/archive copies and stale-file deletion work. External paths, symlink escapes, the root itself, missing frameworks, and unsafe archives fail before Vendor changes. |
| 9 | Bootstrap could discard dirty work without consent | Print status counts and first 20 paths before checkout/reset sync; require `--yes-discard-local-changes` for dirty repos | PASS: a 25-path fixture stops without consent and prints exactly 20 paths plus the remaining count. Explicit consent proceeds. |
| 10 | Rust capture left paths staged | Unstage after capture and in the exit trap | PASS: successful and empty captures leave Rust paths unstaged; empty capture keeps the original patch and removes its temporary file. |
| 11 | Stale-lock guidance omitted one lock | Name both the writer and operation lock paths | PASS: writer-lock and named-lock failures print both exact directories; existing stale locks remain intact. |
| 12 | `.gclient` gained duplicate solutions lines and used exec | Parse literal RHS values; replace solutions in place and collapse duplicates | PASS: repeated bootstrap leaves one byte-identical solutions assignment, preserves other settings, and rejects an expression RHS without executing it. Build's PGO read also uses literal parsing. |
| 13 | Same-pin rehearsal prompted for confirmation | Put the prompt after the same-pin read-only branch | PASS: rehearsal succeeds with closed stdin, without a prompt, locks, or pin changes. |
| 14 | Empty arrays could fail with Bash 3.2 and `set -u` | Guard array expansions and add target-shell notes | PASS: all CLI flows run through `/bin/bash` 3.2; an empty-array probe passes under `set -u`. |

Final checks: `shellcheck -x` is clean for the seven Bash entry points and
`lib/common.sh`; all eight `--help` commands exit 0; Bash syntax and Python
AST checks pass. The fixture passed 17 CLI flow groups. Apply/refresh
dry-runs left every fixture file hash unchanged. The fixture's script bytes
match the worktree scripts.
Directory and archive fetch also pass with the framework's internal
`Versions/Current` symlinks intact.

On the real engine, only `engine-status` and `engine-apply --dry-run` ran.
Dry-run exits 0 and skips CEF's patcher. Status remains **4 pass, 1 fail,
3 warn** (exit 1): S-4 reports the expected missing
`open/adblock/README.md`; S-2 uses the documented fallback, and build outputs
and symbols remain unverified. No apply, refresh, sync, build, or packaging
ran against that tree.

A SHA-256 snapshot of 603 monitored paths (Git metadata, CEF patch inputs
and target paths, GN args, Rust toolchain version, and the overlay target)
was identical before and after the real checks:
`f7abc13879abdf7e640e00cfbafd361d694d1e5d070d3a11586de47a9dccc42f`.
This is a bounded input snapshot, not a hash of changing build outputs.
Local receipts are in ignored `.re/pr25-review/`: `fixture-results.json`,
`fixture-commands.log`, `fixture-distrib.log`, the dry-run outputs,
`real-check-receipt.json`, and both hash manifests.

## Phase B bring-up (Steps 7–11) — 2026-10-25

The stock build ended at 19:11. The engine lead owns the shared tree from
then on. All commands below ran on the real tree.

| Step | Command | Result |
|---|---|---|
| 7 bootstrap | `engine-bootstrap --run --skip-sync --skip-hooks` | Phases 0–2 and 5 pass. The stock scripts already synced the tree and ran its hooks (`hooks.done`), so a sync would only stop at the dirty-tree guard. |
| 7 apply | `engine-apply --all`, twice | First run: `117 patches total (0 applied, 117 skipped, 0 failed)`, 1 overlay file copied. Second run: 0 copied. `applied.json` written. |
| 7 args | `gn/dev.args.gn` + `disable_fieldtrial_testing_config=true` | `engine-build --regen --target "cefsimple cefclient" --detach`: 649 steps, 85 s, exit 0. `gen/components/variations/service/buildflags.h` now has `FIELDTRIAL_TESTING_ENABLED() (0)`. |
| 7 smoke A | `cefsimple --url=https://example.com --use-mock-keychain --user-data-dir=<one dir>`, twice | Alive at 10 s; title "Example Domain" via the DevTools endpoint; clean SIGTERM exit; no `FATAL`/`Check failed`, no GPU `1003`, no `sandbox_extension` line; no leftover process. cefsimple does not pass `--disable-field-trial-config`, so the GN arg alone fixes child launch. |
| 8 Rust vendor | — | Not run. It is ad-block build glue; the ad-block series queues behind P1 (lead decision 1 in docs/engine-patches.md). |
| 9 distrib + fetch | `engine-distrib --run`, `tools/build.sh Release` | `distrib.txt` → `cef_binary_156.0.14+g4fa4ab5+chromium-156.0.8078.48_macosarm64_minimal` (551 MB). Open.app embeds the fork framework (same UUID `4C4C44A5-5555-3144-A14B-F02030962C73` as `out/Release_GN_arm64`), `codesign -v --deep --strict` passes. |
| 10 release | `engine-build --config release --target cefsimple` | The PGO gate stops it: `release: no PGO profile found; set chrome_pgo_phase=0 explicitly in gn/release.args.gn or add the profile`. `.gclient` has `checkout_pgo_profiles: False` and `chrome/build/pgo_profiles/` is absent. Known gap: release is blocked on the PGO profile, and the packaging gate stays. |
| 11 rebase rehearsal | `engine-rebase --chromium 156.0.8078.48 --cef-branch 8078 </dev/null` | Prints the checklist, `same pins: verified applied state; no tree or VERSIONS changes`, exit 0. `VERSIONS` hash and tree status hash unchanged. |

`engine-status` after Step 9: **8 pass, 0 fail, 0 warn**.

Fixes found on the way:

- CEF's `make_distrib.py` copies the framework out of `cefclient.app`. The
  stock flow built only `cefsimple`, so its distributions had no `Release/`
  folder ("No Release build files"). Distrib now builds both targets.
- On branch 8078, `automate-git.py` never passes `--no-symbols` for the
  minimal type, so `make_distrib.py` copies dSYMs. Dev builds make none
  (`FileNotFoundError: … Chromium Embedded Framework.dSYM`). Distrib now
  calls `make_distrib.py --minimal --no-symbols --no-docs --no-archive`
  directly; the app uses the directory, not the archive.
- The macOS output of the `cefsimple` target is `cefsimple.app`. S-6 and the
  build summary checked `out/…/cefsimple`.
- S-2 now runs CEF's own read-only applied check
  (`git apply -p0 --ignore-whitespace --reverse --check`, from
  `cef/tools/git_util.py`) for each `patch.cfg` entry, instead of the
  file-presence fallback. It takes about 6 s.
- A raw `cefsimple` without `--use-mock-keychain` never commits its first
  navigation (`location.href` stays `about:blank`): the network service waits
  on the shared "Chromium Safe Storage" keychain item. Open.app already uses
  its own item (docs/engine-spike.md, "Bugs found").

The app now builds against the fork by default (`tools/fetch-cef.sh`,
`CEF_SOURCE=fork`). `CEF_SOURCE=cdn` stays for comparisons only.

## Open patch series and the CEF layer (P1, 2026-10-25)

| Series | Patch | Size | Files |
|---|---|---|---|
| chromium | `0301-open-headless-browser-window.patch` | +14/−8 | `chrome/browser/ui/browser_window/internal/browser_window_features.cc` |
| chromium | `0302-open-hidden-browser-ui.patch` | +12/−3 | `read_anything_side_panel_controller.cc`, `tabs/tab_features.cc`, `toasts/toast_controller.cc` |
| chromium | `0303-open-hosted-tab-lifecycle.patch` | +43/−0 | `extensions/api/tabs/tabs_api.cc`, `resource_coordinator/tab_lifecycle_unit.cc` |
| chromium | `0304-open-hidden-browser-no-tab-groups.patch` | +10/−2 | `chrome/browser/ui/browser.cc` (includes the overlay's `tab_groups.h` only) |
| cef | `0302-open-hosted-tabs.patch` | +79/−6 | `BUILD.gn`, `browser_host_base.h`, `browser_info_manager.cc`, `browser_platform_delegate_create.cc`, `chrome/chrome_browser_delegate.cc`, `chrome/chrome_browser_host_impl.cc` |
| cef | `0303-open-context-menu-submenu-commands.patch` | +15/−1 | `chrome/chrome_context_menu_handler.cc` |
| cef | `0310-open-adblock-service-owner.patch` (ad-block Step 3) | +43/−0 | `browser/browser_context.{h,cc}`: the per-Profile `open_engine::OpenAdBlockService` and the self-test switches. 0302 also gains `deps += open_libcef_deps` (list in `open/open_libcef_sources.gni`) |
| cef | `0314-open-adblock-cefsimple-smoke.patch` (test only, keep last) | +5/−0 | `tests/cefsimple/simple_app.cc`: no window in `--open-adblock-selftest` mode. Run `cefsimple --use-mock-keychain --open-adblock-dir=<root> --open-adblock-selftest`: without the mock keychain, a rebuilt (newly signed) cefsimple waits on a Keychain access prompt at shutdown, and Chrome's 10 s teardown watchdog exits 2 after PASS. The self-test writes `engine.dat` and its receipt into `<root>`: give each concurrent run its own copy of the root |
| rust | `0001-adblock-vendor.patch` (ad-block Step 1, 2026-10-26) | 11.3 MB, generated | `third_party/rust/**`: `gnrt vendor` + `gen` output for the adblock 0.8.11 closure, the merged `Cargo.toml` and `gnrt_config.toml`, three crate patches (docs/engine-patches.md P8 "Security review") |

Overlay: `open/browser/tab_strip/*` and `open/open_libcef_sources.gni`
(about 1,600 lines, compiled into `libcef_static`), and the API header
`cef/include/cef_tab_strip.h`. What each part does:
[engine-patches.md](engine-patches.md), P1 status.

Open's Chromium patches can change lines that CEF's own patches added
(`browser_window_features.cc` is one). Three tool changes follow from that:

- `engine-refresh-patches` writes Chromium patches against the CEF-patched
  baseline (`scripts/lib/cef_baseline_diff.py`: the HEAD blob plus each CEF
  patch's hunks for that file, in `patch.cfg` order), so a patch holds only
  Open's hunks. The baseline blob goes into the object store for `--3way`.
- `engine-status` S-2 and `engine-apply` check CEF's patches "under" Open's
  layer: files that both touch are checked in a scratch copy with Open's
  hunks undone. Apply skips CEF's patcher when its layer is complete; when it
  is not, apply peels Open's applied Chromium patches (reverse order), runs
  the patcher, and re-applies them.
- `git apply --3way` refuses files whose working copy differs from the index
  ("does not match index"), which is every file CEF patched. Apply falls back
  to a direct apply when the direct check passes; other failures still stop
  with a conflict report.

When an overlay header under `cef/include/` changes, `engine-apply` runs
`cef/tools/version_manager.py -u --fast-check` (CEF's own gclient-hook
command), which regenerates the C API, the wrapper sources, and the
untracked API hashes. None of the generated files are tracked by CEF or this
repo.

Round-trip proof on the real tree: `views_textfield_5399416` (a one-file CEF
patch) and Open's three patches reversed by hand, then `engine-apply --all`:
CEF's patcher `1 applied, 116 skipped`, Open `3 applied`; all 10 touched
files byte-identical to before; a second run `0 applied, 3 already applied`
with the patcher skipped. With only the CEF patch reversed, apply peeled both
Open Chromium patches, ran the patcher, and re-applied them (same 10 files
identical).

## PartitionAlloc and the launch race (2026-10-26)

A Release launch in the window suite crashed 1 s after start with
`[FATAL:allocator_shim_apple.cc(61)] Check failed: false. Oops! No zone found`
on a CoreSpotlight dispatch queue (`Open-2026-10-26-110130.ips`: SIGTRAP in
`allocator_shim::TryFreeDefaultFallbackToFindZoneAndFree`, called from
`-[__NSDictionaryM dealloc]` in `-[CSInlineDonation _reportErrorWithCode:…]`).

Cause, in our startup order, not in the fork's patches. The framework's
PartitionAlloc makes itself the default malloc zone from a load-time
constructor (`InitializeDefaultMallocZoneWithPartitionAlloc`,
`partition_alloc/shim/allocator_shim_override_apple_default_zone.h`). When no
delegating zone is registered, it takes the path its own comment calls racy:
`malloc_zone_register(PartitionAlloc)`, `malloc_zone_unregister(system)`,
`malloc_zone_register(system)`. Between the last two, a `free()` of a system
pointer on another thread reaches PartitionAlloc's `try_free_default`, finds
no zone that owns the pointer, and the CHECK fires. Chrome avoids this with
`partition_alloc::EarlyMallocZoneRegistration()` at the top of `main()`
(`chrome/app/chrome_exe_main_mac.cc`); CEF's samples load the framework
before any thread starts. Open shows its first window before it loads the
framework (`App/main.swift` calls `OEEngine.start(configuration:)` after the
first frame, and that loads it with `CefScopedLibraryLoader::LoadInMain`), so
AppKit, CoreSpotlight and other system threads are already running then.

Fix: `Engine/OpenEngine/src/OEMallocZone.mm`, a load-time constructor of the
OpenEngine framework (so it runs before `main()` in the app and in every
helper), installs Chrome's delegating zone: it forwards allocations to the
system zone, owns nothing, and is named `DelegatingDefaultZoneForPartitionAlloc`
with zone version 13. PartitionAlloc recognizes the name and swaps itself in
for it in one step; the system zone is registered throughout. The code is
adapted from Chromium's `base/allocator/early_zone_registration_apple.cc`
(BSD license).

Evidence:

- Repro (`.re/malloc-zone-race/probe.mm`): 8 threads free system-zone blocks
  while the main thread dlopens the fork's framework, as `LoadInMain` does.
  Without the zone: 50 of 50 runs end in the same `Oops! No zone found` FATAL.
  With `OEMallocZone.mm` linked: 50 of 50 exit cleanly; zone 0 is
  `DelegatingDefaultZoneForPartitionAlloc` before the dlopen and
  `PartitionAlloc` after it.
- In the app: `ping` reports the zone names (`mallocZones`); the window
  suite's `malloc_zones_early` check requires `PartitionAlloc` first and the
  system zone before the purgeable zone (on the racy path the system zone is
  registered again at the end).

Rebase watch: the zone name and `kZoneVersion` in OEMallocZone.mm must match
`partition_alloc/shim/early_zone_registration_utils_apple.h`
(`kDelegatingZoneName`, `kZoneVersion`). If they drift, PartitionAlloc takes
the racy path again and `malloc_zones_early` fails.
