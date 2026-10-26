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

Apply validates both HEAD pins before writes. It applies CEF's own patches,
then Open series in file order, then copies changed overlay files. It never
deletes stale overlay files. It skips `.open` fragments and `.gitkeep`.
Conflicts stop the run and produce a report in `logs/conflicts/<timestamp>/`.
The report contains the patch, Git output, status, diff, and fix instructions.

Build defaults to dev with 10 jobs. An explicit `--jobs` above 10 warns
about the recorded watchdog panics. The command always uses `nice` and
`caffeinate`. Existing dev args stay untouched unless `--regen` is explicit.
Dev args match the active stock build byte-for-byte, including its missing
final newline and local Widevine adapter setting. Release args disable
Widevine per the lead decision; v1 does not ship it.

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
Refresh follows series order, sorts pathspecs, captures working-tree and
staged changes, and refuses empty patches or new files outside the overlay.
Rust refresh stages ignored vendor files and captures the staged binary diff.

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
until the rebase PR merges. Same-pin rehearsal verifies state and does not
change the tree or pins.

No unit tests, real builds, gnrt, smoke launches, or engine-tree changes are
part of Steps 1–6. The [smoke checklist](../Engine/fork/verification/smoke-checklist.md)
records the later build proof. Bundle IDs and MPL approval follow the lead
appendix; branding assets and feature code remain outside this milestone.
