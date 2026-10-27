# Full CLI verification

Run from any directory on macOS with Swift and Python 3 installed:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --quick
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only route,favicons
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --with-arc-data --keep-logs
```

The Site Control check opens native menus and acquires
`/tmp/open-onscreen-e2e.lock` around that suite. Do not hold this lock around the
whole runner: the release build needs no on-screen lock. Standalone native-menu
harness commands still need the lock, per AGENTS.md rule 11.

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

## Performance gates for offscreen harnesses

Offscreen performance regression gates use **main-thread retired instructions**
with accepted counts per CPU brand and macOS build. CPU p95, wall p95 and load
remain printed diagnostics. Scheduling onto different cores under heavy load can
change CPU milliseconds; it does not change the amount of instruction work in
the same span. Absolute product time targets still need a quiet-machine check.

`sitecontrol-render` applies this method to the full 2x cold-open workload
(20 Boosts, 12 Settings rows, fresh native tree and first draw). It discards five
warmups, measures 30 opens, takes their median (rounded up to an instruction), and
requires `median <= ceil(accepted × 1.10)`. The small versioned fixture is
`Packages/OpenKit/Sources/sitecontrol-render/Fixtures/instruction-baselines.json`.
M5 Pro / 26B5112a records the lead-accepted 95,035,968 instructions; the limit is
104,539,565. Add an M1 entry only after its accepted measurement. An unknown
CPU/build prints the count and reason as **INFO**, not PASS. A missing counter
or invalid fixture fails; neither CPU nor process totals substitute for it.
The lightweight skeleton timing is informational; the full cold workload owns
the regression gate.

The helper resolves `thread_selfcounts` with `dlsym`, checks the THSC_CPI=1 C ABI,
and reads the current main thread. It is compiled only in the harness executable,
never in App or library targets. It reuses the SM6 measurement helper. A negative
proof adds an O(n) native row-construction pass inside the measured span and must
fail the unchanged instruction limit, then restores the source.

After a release build, this exact command prints the CPU p95 for the lead's
quiet M5 check (the product target remains **<8 ms**):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh Packages/OpenKit/.build/release/sitecontrol-render bench --fixture cold
```

`cold-measure --thread-instructions` prints the sample counts for independent A/B
runs. Raw traces stay local; commit only synthetic numeric evidence and hashes.
The Site Control A/B report is in `docs/sitecontrol/step-2/performance/README.md`.
This method does not claim that other existing harnesses have already migrated.

### SM6 structural and machine-specific cost gates

SM6 constructs the real 10-Space × 100-row Library and lays it out at 900×700,
scale 1, with three synchronous settle passes. It requires page builds to equal
built visible columns (1…4), exactly one full outline reload per built page,
zero incremental outline item updates during first layout, and model-matching
row counts. Existing scroll-builds-once and rename-no-reload checks remain.
Production diagnostics use plain main-actor integer increments without locks,
allocation or logging. AppKit layout callback counts remain unpinned.

The default `sidebar-render check` also runs `sm6-cost`: one discarded warm-up
process, then five fresh `sm6-measure --thread-instructions` processes. Each child
has isolated home/tmp/preferences, a 15-second timeout, a 65,536-byte output cap
and owned-PID cleanup. Known CPU-brand/macOS-build keys enforce
`median <= ceil(acceptedMedian × 1.10)` from the versioned resource
`sidebar-render/Resources/sm6-cost-baselines.json`. Fixture updates need lead
approval. Unknown keys report the measured count as INFO, never cost PASS.
Invalid or unavailable known-machine counters fail without fallback.

Only the harness binary resolves `thread_selfcounts` through `dlsym`; no App or
OpenKit library uses it. Wall time, lateness versus 120 ms, thread CPU, process
instructions, load and the wider thread census are diagnostics. Raw output and
cleanup state are retained in `SM6_JSON`. Instructions do not guarantee latency:
the 120 ms product budget is checked separately in a quiet M5 window. Helper
threads, draw/GPU completion and deferred work remain gaps; see
`docs/followups.md`.

Build before running:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only build
Packages/OpenKit/.build/release/sidebar-render sm6-measure --thread-instructions
Packages/OpenKit/.build/release/sidebar-render sm6-cost
python3 tools/sm6-proof.py --binary Packages/OpenKit/.build/release/sidebar-render \
  --out /tmp/sm6-cleanup-UNIQUE --load low --case early-failure --runs 1
```

`sm6-measure --fail-after-host` and `sm6-cost --fail-child-after-host` intentionally
fail and must clean all owned hosts/processes. Proof output directories must be
new. The proof tool bounds runs to 1…5, reaps only its recorded children and
records cleanup in `receipt.json`. Its `--load high` mode starts owned burners;
use it only for an explicitly authorized load proof. A full `--case check` run
also needs `/usr/bin/lockf /tmp/open-onscreen-e2e.lock`, with no concurrent build.

M5 review r2 (section 1, 2026-10-27, M5 Pro / 26B5112a, built-in 2x panel as the
main display, load1 4.5–5.2). The sampler is stable: three `sm6-cost` runs gave
medians 680,241,245 / 680,144,454 / 683,041,525 (within-run range/median 0.6–0.8 %),
0.4–0.8 % above the accepted 677,429,195, so the accepted M5 fixture stands. Wall time
stayed diagnostic at 61.7–67.8 ms. Negative proof: one temporary O(n) pass in
`SpaceManagerView.layout` that sizes every row title once with the real system font
(1,000 rows) kept every structural check at 4 builds / 4 reloads / 0 item updates but
raised the median to 785,999,099 > 745,172,115, and `sm6-cost` exited 1. The source was
restored and the gate passed again at 680,827,395. `sm6-proof.py --case early-failure`
and `sm6-cost --fail-child-after-host` both reaped their children (`cleanup: True`,
hosts 0, visible 0).

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
