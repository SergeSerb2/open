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
