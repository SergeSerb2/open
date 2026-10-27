# Full CLI verification

Run from any directory on macOS with Swift and Python 3 installed:

```sh
tools/verify-all.sh
tools/verify-all.sh --quick
tools/verify-all.sh --only route,favicons
tools/verify-all.sh --with-arc-data --keep-logs
```

The runner uses `/bin/bash` 3.2. It builds `Packages/OpenKit` exactly once with
`nice -n 10 swift build -c release -j "${VERIFY_JOBS:-6}"`. The build runs in its
own process session. A compiler error, any output line containing `warning:`,
or a nonzero build exit stops the run. The build log records warning/error line
counts. Checks use the resulting release executables; they never call `swift run`.

`--quick` selects commands-demo, suggest-check, and commands-dump after the build.
`--only NAME[,NAME]` selects checks from the table below, preserving table order.
The build always runs; `--only build` runs just the build. Combined with `--quick`,
`--only` must select from the quick set. Unknown names and invalid flags exit 2.
`VERIFY_JOBS` sets build concurrency. `VERIFY_LOG_DIR` can name a **new** log
directory; an existing directory is refused to protect earlier evidence.

Every check runs in a fresh `mktemp -d` directory, with its own working directory
and `TMPDIR`. Synthetic snapshot prerequisites come from commands-demo. A check
selected alone creates that prerequisite through the real CLI. Roundtrip copies
the demo's output before saving it. It does not change the original fixture.

Each command must exit as expected **and** print its required success evidence.
The runner records PASS, FAIL, or SKIP and elapsed whole seconds. A failed check
does not stop later checks, except for a failed build. Exit 0 means there were no
FAIL rows. An unavailable command or executable is SKIP, detected from openkit's
usage tokens or `.build/release/<executable>`. A command that exists but fails,
prints incomplete results, or misses a dependency is FAIL. Missing node or Chrome
also makes the optional Boosts check SKIP. Checks excluded by flags have no row.

| Name | What PASS proves | Typical duration after build |
|---|---|---|
| `commands-demo` | Real BrowserModel commands, undo/redo, placement refusal, archive/restore, and persistence report all checks passed and zero failed. See [model.md](model.md). | <1 s |
| `roundtrip` | A commands-demo snapshot loads, saves, and reloads with `roundtrip OK`. | <1 s |
| `suggest-check` | The existing suggestion CLI reports N/N passed, with N > 0, including local HTTP remote-provider paths and its main-thread CPU budget. See [suggest.md](suggest.md). | 5–20 s |
| `commands-dump` | The real headless NSMenu and keyboard registry match the reference table (`missing=0 extra=0 different=0`). Default and override bindings have no unexpected conflicts. See [commands.md](commands.md). | <1 s |
| `route` | Runs an existing `tools/route-check.sh`, `tools/verify-routing.sh`, `tools/verify-route.sh`, release `route-check`, or `openkit route-check` runner when present. Otherwise exercises [routing.md](routing.md) A1–A10 through `openkit route`: host boundaries, containment, first-match order, source normalization, toggle, rejected scheme, stale target, and JSON/text agreement. Every accepted result has an explicit expected destination. | <2 s |
| `favicons` | A tiny generated site served by Python http.server on loopback fetches through the release debug flags. Concurrent fetches succeed, a second process uses the cache, 32/64-pixel PNGs read back, and a page without an icon reports missing and absent readback. All requested page/icon URLs are local. See [favicons.md](favicons.md). | <2 s |
| `sleep-demo` | The existing real model/controller/store CLI reports N checks passed and zero failed. The 5,000-tab/200-pass gate uses thread CPU p95 <2 ms; wall time is informational. Its engine boundary and policy clock remain the CLI's simulation. Expected deliberate storage errors are allowed. See [sleep.md](sleep.md). | 1–5 s |
| `adblock-perf` | Both current budgets pass: 1,000 lookups p95 <1 ms and profile open with integrity scan p95 <10 ms. Ten groups yield exactly 5,000 matches in 10,000 lookups. Official default-list downloads may be needed. See [adblock-lists.md](adblock-lists.md). | 5–30 s; network dependent |
| `adblock-catalog` | Real CLI output contains all 46 catalog IDs, category counts 3/2/5/35/1, and only EasyList/EasyPrivacy enabled by default. | <1 s |
| `profiles` | When `openkit profiles` exists, exercises the planned P-1–P-8 and P-10 flow: create, duplicate refusal, assign Space, both delete refusals with unchanged snapshot bytes, reassignment, temporary-profile deletion with retained directory, and roundtrip. Contract: [profiles plan §9.1](plans/profiles.md#91-openkit-profiles--cli-new-file-openkitprofilescliswift). | <2 s |
| `sidebar-render` | When present, `sidebar-render check` reports N/N passed, N checks passed with zero failed, or `checks: N passed, 0 failed`. | 1–5 s |
| `commandbar-render` | When present, `commandbar-render check` accepts the same summary formats as sidebar-render. | 1–5 s |
| `boosts` | Headless system Chrome loads the actual Boosts harness and production scripts. A7 asserts banner highlight geometry/color, selector commit, hidden banner, and active picker. A11 asserts the precise pick, two aligned related previews, three-match replacement, and hidden posts. Saves both PNGs and rejects runtime errors. See [boosts.md](boosts.md). | 5–20 s; npm install dependent |
| `import-arc` | Opt-in only. Read-only copies of Arc's top-level JSON files pass sidebar/archive accounting, `archive-list --limit 0`, and roundtrip. Also inspects default-profile output when profiles exists (P-9). | <2 s |

### Focused checks for intermediate pushes

`AGENTS.md` rule 10 asks for the full gate before a PR opens and when it is reported ready. For pushes in between, run the build plus the checks for what you changed. Shared targets (`OpenDesign`, `OpenModel`, `OpenStore`) reach many checks, so use the full gate when you change them.

| You changed | Run at least |
|---|---|
| `OpenSidebar`, `OpenMedia` sidebar views | `sidebar-render,sidebar-compare,media-demo` |
| `OpenCommandBar`, `OpenSuggest`, `OpenCommands` | `commandbar-render,suggest-check,commands-dump` |
| `OpenFeatures` (Split, Peek, Little Open, PiP, Site Control) | `features-render` |
| `OpenSpaceEditor`, theme tokens | `space-editor,space-legacy` |
| `OpenSettings` | `settings-preview,profiles` |
| `OpenRouting` | `route` |
| `OpenSleep` | `sleep-demo` |
| `OpenAdBlock` | `adblock-perf,adblock-catalog` |
| `OpenBoosts` | `boosts` |
| `OpenWeb` favicons | `favicons` |
| `App/` or `Engine/` | the e2e suites for the flow (`tools/e2e/engine_e2e.py --only …`) plus `build` |

An initial release build usually takes 20–90 seconds. An incremental build usually
takes 1–3 seconds. Host load, cold compiler caches, npm, and list downloads can
increase these estimates. The final table and each log give actual times/results.
Performance budgets are never retried or relaxed by the runner.

### Sidebar color environments

`sidebar-compare` runs all 13 states through the release render/compare CLI.
Only its absolute Arc color caps use `macos-<build>-1x`. The build comes from
`sw_vers -buildVersion` and must contain 1..32 ASCII alphanumeric characters.
The renderer forces scale 1; the physical display scale is not part of the key.
Count and position limits stay shared. Main and branch still need exactly equal
element identities, sampling counts, position errors and ink boxes, with color
metric drift at most 0.15 ΔE00. The separate divider check stays unchanged.

`macos-26B5112a-1x` carries the original M5 caps unchanged as a proposed fixture,
pending lead review and same-head M5 proof. `macos-26A434-1x` comes from an actual
unmodified `origin/main` build at `49b566097423213d1bc9aca1426c7e2bb3f5f65b`.
The three former failing state caps are 1.31 (static-inactive), 2.71
(selected-pinned), and 2.25 (yellow). All 13 caps and the baseline binary SHA are
in [design.md §15.1](design.md#151-no-regression-on-the-matched-states).
The AGENTS.md M1 exception stays until M5 same-head proof and lead approval.

An unknown key fails before building or rendering, names the key, and prints
the record instruction. A malformed build also fails. Neither case falls back,
auto-records, or SKIPs. Exit 77 remains reserved for missing private inputs on
`--probe`. Record a proposal explicitly, with the whole job in one heavy slot:

```sh
/usr/bin/lockf /tmp/open-m1-validation.lock \
  ~/Library/Caches/OpenRE/scripts/heavy.sh \
  tools/verification/sidebar-compare-states.sh --record-limits
```

Recording pins the exact `origin/main` commit and builds its clean `git archive`
export through `build_main`. It refuses `--baseline-renderer` and any alternate
`--baseline-ref`. It prints that commit, the baseline binary SHA-256, environment
key, per-state measurements and a Python dictionary proposal. With the default
three main-only samples, each cap is the ceiling of the worst measured value to
0.01 ΔE00, with no added headroom. Any count or worst-position disagreement with
the shared metadata, or any element/proposed cap more than 1.00 ΔE00 above the
old M5 cap, refuses the proposal. No tracked repository file is written. Add a
new entry only through a reviewed PR. Ordinary comparisons with an override
binary need its trusted-main build receipt and verified commit/binary digest.

Private tables, renders and receipts default to a new 0700 directory under the
shared ignored `.re/sidebar-compare-runs/`, outside verify-all artifact logs.
An explicit `--out` must name a new private directory. Receipts include `envKey`,
`osBuild`, `renderScale`, shared metadata and the selected color caps, plus the
existing input/binary digests and per-attempt results. Recording receipts keep
all measurements and the proposed caps. Never commit private outputs.

## Logs and privacy

The default directory is `$TMPDIR/open-verify-<local timestamp>.<unique suffix>/`
(`/tmp` when TMPDIR is unset). The runner prints its absolute path at the end.
It contains a log per check, `openkit-usage.log`, `results.tsv`, `summary.txt`,
and available favicon/Boosts PNGs. Failed checks keep their output there.
`--keep-logs` additionally retains synthetic scratch files under `artifacts/`,
including the temporary npm installation. Ordinary runs remove scratch files.
Logs always remain, so the final path works with or without `--keep-logs`.

`--with-arc-data` is the only path that reads
`~/Library/Application Support/Arc/*.json`. The importer reads private copies.
Only allowlisted count/check lines reach the persistent log. Full importer output,
hosts, titles, source JSON copies, snapshots, and SQLite files are discarded when
the check ends, including on failure and with `--keep-logs`. No keychain, History,
Cookies, or browser profile databases are opened. Arc is never launched.

The Boosts check follows the temporary `puppeteer-core` approach used by
`.re/qa/shot.mjs`: it copies this repo's portable driver into its scratch directory,
runs `npm i puppeteer-core` there, and launches system Google Chrome with a fresh
headless profile. There is no repo npm dependency or lockfile. Both local servers
bind a dynamically assigned loopback port and stop in a `finally` block. Chrome
closes in the driver's `finally` block. The harness runs in the page world; this
check does not prove native session authority or the future isolated-world engine
adapter. The runner does not launch Open, drive the desktop, build Chromium, or
claim app/engine acceptance. [scripting.md](scripting.md) describes separate
App/AppleScript gates; no scripting CLI exists in this checkout.

## Verify the failure path

Use a disposable copy of the checkout and edit its copy of
`tools/verification/check.py` to point `cli` at a nonexistent absolute path. Run
`tools/verify-all.sh --only suggest-check`. The real package build must still
pass, then suggest-check must report FAIL with exit 1. Keep that edit outside the
working branch. A missing advertised command is SKIP; a missing executable at
execution time or a command with a wrong result is FAIL.

## Data-root and gate corrections, 2026-10-25

Verified `fix/dataroot-lock` against base `5de74ee` on macOS
(America/Vancouver). The initial release build used only
`nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`, in its own
process session: exit 0, zero warnings, zero errors, 75.93 s. No unit tests
were added. Host load was approximately 23–26 during the initial build.

The full run used `VERIFY_JOBS=6 tools/verify-all.sh --keep-logs`, with
`VERIFY_LOG_DIR` set to the receipt directory below. It exited 0 with
**13 PASS, 0 FAIL, 1 SKIP**. The runner's incremental release build also
reported zero warnings and zero errors.

| Name | Result | Seconds |
|---|---|---:|
| build | PASS | 3 |
| commands-demo | PASS | 0 |
| roundtrip | PASS | 0 |
| suggest-check | PASS | 15 |
| commands-dump | PASS | 0 |
| route | PASS | 1 |
| favicons | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| sidebar-render | PASS | 13 |
| commandbar-render | SKIP: target absent | 0 |
| boosts | PASS | 4 |

Sidebar's real output was `checks: 81 passed, 0 failed`. The shared parser
now accepts this format, the existing N/N formats, and `N checks passed,
0 failed`. It still refuses zero/incomplete pass counts, nonzero failed
counts, and explicit failure lines. No `docs/commandbar.md` or commandbar
target exists in this checkout, so its future check uses that same parser;
no commandbar runtime result is claimed. `import-arc` was not selected
because this run did not opt in to personal Arc data.

Additional real CLI checks used fresh synthetic roots:

| Check | Result |
|---|---|
| `commands-demo` loop | 50/50 PASS, 103 checks each; zero lock failures |
| `sleep-demo` loop | 50/50 PASS, 105 checks each; zero lock failures; second-connection reload passed every time |
| Sleep loop thread CPU p95 | 0.612–1.872 ms across 50 runs; all below 2 ms |
| Sleep loop wall p95, informational | 0.979–6.776 ms across 50 runs |
| Same-root processes | Second process exits 1 in 0.131 s with a clear lock error while the first holds the kernel lock; first exits 0 after resuming |
| Same root through a symlink | Second process exits 1 in 0.122 s with the same lock error |
| Different-root processes | Both hold their locks concurrently and finish with exit 0 |
| Release before owner process exits | A completed Sleep scenario releases its root; a second CLI opens that root while the first process remains alive; both finish with exit 0 |

The full runner's Sleep result was 105/105. Its 200-pass CPU p50/p95/max was
0.257/0.413/0.669 ms; wall p50/p95/max was 0.260/0.562/2.797 ms. The workload
and 2 ms p95 budget remain unchanged; only thread CPU time gates acceptance.
The adblock lookup/profile-open p95 values were 0.1461/2.8964 ms, within
their unchanged 1/10 ms budgets. No check was retried.

Receipts, external CLI drivers, and synthetic artifacts:
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-dataroot-fix-dkc382ib`.
The full table and per-check logs are in its `verify-all/` directory;
`cli-results.json` and `release-result.json` record the extra lock checks.
See [model.md](model.md#data-root-lock) for token ownership and process-check
details. No Chromium build/sync, Arc launch, desktop automation, personal-data
read, or subagent ran. These CLI results do not close native app/engine gates.

Release `openkit` SHA-256:
`b10ff50c87fee7ba6f8d59f2c6fa8c839a1cbe5f4803d6f469ebd8cb2b9a1db8`.
