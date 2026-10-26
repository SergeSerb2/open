# Open engine fork

This directory stores pins, small patches, and new-file overlays for Open's
Chromium fork with CEF's embedding layer. It does not store a Chromium mirror.
New engine code belongs under `//open/`. Swift talks only to `OpenEngine`.

Read [the implementation plan](../../docs/plans/fork-infra.md),
[the operator guide](../../docs/engine-fork.md), and
[the ad-block design](../../docs/adblock-design.md).

Steps 1–6 are repo-only. Steps 7, 9, and 11 ran on 2026-10-25 (Phase B
bring-up in the operator guide); Step 8 waits for the ad-block work and
Step 10 waits for the PGO profile. Only the engine lead writes to the shared
tree. Never run gclient by hand. Never run two tree writers. Never clean
CEF's normal dirty Chromium tree with reset or checkout-all.

From the repo root, these commands are safe during a build:

```bash
Engine/fork/scripts/engine-status
Engine/fork/scripts/engine-apply --dry-run
```

`engine-status` reports a missing overlay as S-4 FAIL until the first real
apply, and unbuilt outputs as S-6 WARN. S-2 runs CEF's own read-only
"already applied" check for every `patch.cfg` entry.

Modifying commands (the argument forms also appear in each script's
`--help`):

```bash
Engine/fork/scripts/engine-bootstrap --run
Engine/fork/scripts/engine-apply --all
Engine/fork/scripts/engine-build --detach
Engine/fork/scripts/engine-refresh-patches --all
Engine/fork/scripts/engine-distrib --run
tools/fetch-engine.sh --run
Engine/fork/scripts/engine-rebase
```

Run bootstrap and distrib in their own session; see the operator guide.
Build `--detach` starts its own session and prints the log and `tail -f`
command. Default builds use dev args, `cefsimple`, 10 jobs, `nice -n 10`,
and `caffeinate -dimsu`. `--target` also takes a quoted list. Distrib builds
`"cefsimple cefclient"` (CEF's packager copies the framework out of
`cefclient.app`) and calls `cef/tools/make_distrib.py --minimal --no-symbols`
directly. Release uses a separate output directory and needs the exact
published PGO profile. Release distribution stops until Step 10 resolves
CEF's fixed dev output directory. It never packages dev as release.

Pins live only in `VERSIONS`. Status checks the real tree against them.
`OPEN_ENGINE_ROOT` selects a different tree; the default is
`~/Developer/open-engine`. State and logs go under that root. Help and
dry-run paths do not write logs, locks, state, or tree files.

CEF's patches run first, then Open's chromium/cef/rust series, then the
overlay. All series start empty. `.open` Rust fragments record future intent;
normal apply never runs Cargo or gnrt. Step 8 captures generated output in
the Rust series and adds the crate license. No feature patch ships here.

No-argument scripts show help, except build (dev build), status (read-only
checks), and rebase (read-only checklist). Use `--run` or `--all` above to
start a modifying command. This resolves the plan's no-argument help rule
against its earlier command examples.
