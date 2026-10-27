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

### SM6 structural and machine-specific cost gates

`sidebar-render sm6-measure` runs only the real 10-Space × 100-row Library
construction and first layout in a fresh process. It shares its fixture and
measured body with SM6 in `check`: `SidebarContext`, `SpaceManagerView`, a
900×700 frame, and `OffscreenRenderer.host(scale: 1)` with three synchronous
settle passes. Fixture creation precedes the counters. Scroll-in and property
reload checks run after measurement. The host stays at −20000,−20000, is never
ordered front, and closes in `defer`, including `--fail-after-host` (expected
exit 1). Unknown or extra arguments fail before host creation.

Both `check` and `sm6-measure` gate page builds equal to the 1–4 built visible
columns, exactly one full outline reload per built page, and each built outline's
actual row count equal to the model. Existing scroll-builds-once and rename-no-
reload checks remain. Manager/page/row layout callback counts are printed but
unpinned until all samples on both Macs/loads agree exactly. The three new
production hook sites each execute one main-actor integer increment, with no
lock, allocation, or logging.

`SM6_JSON` retains raw counters, work deltas, per-outline rows, wall/main-thread
CPU/load diagnostics, and Mach thread censuses. Wall lateness versus 120 ms is
informational. Unavailable/zero/backward cost counters are explicitly reported;
they never become a CPU fallback. Known-machine counter failures fail the separate
cost check. Drawing/GPU/CA completion and deferred work remain unbounded; see
`docs/followups.md`. No other check's gate or tolerance changes.

Build before sampling, through the machine's heavy wrapper.
On M1, wrap each build, proof, or validation job once with
`/usr/bin/lockf /tmp/open-m1-validation.lock` to exclude other M1 validation
work; keep the heavy and on-screen locks inside it. Do not acquire it recursively.
For example:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only build
python3 tools/sm6-proof.py --binary Packages/OpenKit/.build/release/sidebar-render \
  --out /tmp/sm6-low-UNIQUE --load low --runs 5
python3 tools/sm6-proof.py --binary Packages/OpenKit/.build/release/sidebar-render \
  --out /tmp/sm6-high-UNIQUE --load high --runs 5
python3 tools/sm6-proof.py --binary Packages/OpenKit/.build/release/sidebar-render \
  --out /tmp/sm6-cleanup-UNIQUE --load low --case early-failure --runs 1
```

Output directories must be new. Runs are bounded to 1…5. Each invocation gets
a temporary working/data directory, `TMPDIR`, `CFFIXED_USER_HOME`, and preferences
suite. The high-load driver starts exactly twice the active CPU count of owned
`/usr/bin/yes` children. It waits at most 120 seconds for load1 ≥15, then fails
if unmet. The low-load target is ≤2; if unmet after 120 seconds it reports the
actual load and samples without claiming low-load acceptance. `finally` checks
burner commands, terminates/reaps only recorded children, and verifies PIDs gone.
The full default suite can be recorded with `--case check --runs 1`; wrap that
driver invocation in `/usr/bin/lockf /tmp/open-onscreen-e2e.lock`, without a
concurrent build. Its timeout is 300 seconds; standalone runs allow 90 seconds.

The census is outside the counter window and spans a slightly wider interval.
It identifies threads by Mach thread ID and reports CPU deltas and names,
including newly observed threads. Exited threads have no final CPU sample;
threads born and exited between censuses can be missed. CPU is evidence about
contamination, not per-thread instructions. Report any helper over ~1 ms and
any low/high median instruction shift over 5% to the lead. A separate process
alone does not prove clean counts. Cold process caches can also change this
workload from the original suite's cached SM6 section.

The initial M1 run measured a −12.56% median process-instruction shift under burners,
with busy helper threads even in the standalone process. The lead rejected a
process-wide instruction budget on that evidence. These counters stay diagnostic.
M5 subsequently approved the structural gate above and one bounded main-thread
instruction probe, confined to sidebar-render. `sm6-measure --thread-instructions`
resolves `thread_selfcounts` from libSystem with `dlsym`; missing/unsupported
symbols print `unavailable`. The ABI comes from Apple's pinned
[XNU resource_private.h](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/sys/resource_private.h#L36-L108):
`THSC_CPI=1`, two UInt64 fields (instructions, cycles), and an int return from
`thread_selfcounts(uint32_t, void *, size_t)`. There is no private symbol lookup
in App or an OpenKit library.

The M1 driver's sole `--thread-probe` campaign stops at 2026-10-27 04:35:40 UTC,
including research/build/wait time. It converts remaining absolute time to a
monotonic deadline once per job and reserves cleanup time. Five low and five
burner samples used the original acceptance rule: valid positive monotonic
thread counters and combined `(max-min)/median ≤0.03`. Failure or expiration ended
the probe; there is no replacement probe or padding. The sole M1 campaign
completed with ten valid positive monotonic samples but failed the range limit:
637,692,002 / 655,362,864 / 661,030,831 instructions (min/median/max), spread
3.5612%. Low/high medians were 657,614,454 / 641,516,335 (−2.4480%). The two groups
used byte-identical release binary SHA-256
`777284c2416419257340410449ea36e3dab955678918e7d1b9af91dd338e0fce`;
Swift sources are in `ccf0b31`, with later engine/docs-only main merge `4a5b9d3`.
All samples had page builds/reloads 4/4, manager/page/row layouts 1/4/60 and four
model-matching 105-row outlines. That probe stopped and failed its original rule.
No callback constant is pinned. The later policy below does not relabel that result.
The later M5 ruling expressly authorizes versioned per-machine cost fixtures.
`sidebar-render sm6-cost` (also called by the default `check`) declares one
separate discarded warm-up process, then takes the median of five **fresh CLI
processes**, each running `sm6-measure --thread-instructions`. It never reuses a
manager or compares an in-process warmed span with fresh-process fixtures.
Each child has a fresh home/tmp/preferences root, a 15-second timeout, a 65,536-
byte output limit, and owned-PID terminate/kill/wait cleanup. The parent retains
all six raw outputs. `--fail-child-after-host` exercises the real child failure
and cleanup path. No on-screen window or dialog is opened by these commands.

The fixture resource `sidebar-render/Resources/sm6-cost-baselines.json` is keyed
by exact CPU brand and macOS build. Version 1 fixes the 10×100, 900×700, scale-1,
three-settle span. Updates require lead approval in a PR. Known keys enforce
`median <= ceil(acceptedMedian × 1.10)`; invalid/missing known-machine counters
fail without fallback. Unknown keys print the measured median and INFO, and
never claim cost PASS. No automatic calibration or fixture update occurs.

| CPU / OS build | Discarded process | Five measured fresh-process counts | Accepted median / limit |
|---|---:|---|---:|
| Apple M5 Pro / 26B5112a | 682990080 | 694796165, 674645279, 672852510, 677429195, 683766007 | 677429195 / 745172115 |
| Apple M1 Pro / 26A434 | 663641860 | 657636745, 657154236, 657462453, 657058841, 656898616 | 657154236 / 722869660 |

M5 expressly accepted its 3.24% full range/median and the earlier M1 high-group
2.5368% variation under the new 10% policy. M1's new fixed calibration had
0.1123% spread, load1 1.99. It was declared before execution, used all five
measured samples, and did not reopen the closed discovery probe. Both references
use the original `4a5b9d3` construction span; binary hashes and approval records
are in the fixture. M1 calibration receipt: `.re/sm6-cost/m1-fixed-calibration`.
The repository head at execution was `9fe359e`, using the preserved reference
binary, not the newly merged Theme Step 9 build. Later code is checked against
the accepted reference rather than automatically recalibrated.

Run the cost cross-check after the release build:

```sh
/usr/bin/lockf /tmp/open-m1-validation.lock \
  Packages/OpenKit/.build/release/sidebar-render sm6-cost
```

Real negative proofs on M1: an added native `outline.reloadData()` produced
8 full reloads for 4 page builds and failed at load1 1.94 and 15.68. After its
restoration, focused `sidebar-render` passed. A separate temporary 64-pass loop
inside the measured span visited the real model tabs and sized each title with
`NSString.size(withAttributes:)` and the real system font. All six processes
kept the structural 4-build/4-reload result, but the five-process instruction
median was 8,965,841,854 >722,869,660 and the cost command exited 1. All children
were reaped and the source was restored before focused verification (558 checks,
0 failures; cost median 657,086,884 <=722,869,660). These
negative edits are not committed. Raw receipts are in
`.re/sm6-work/negative-receipt.json` and `.re/sm6-cost/negative-cost-receipt.json`.

The absolute 120 ms product budget remains a separate M5 check in a quiet
window. Historical same-section M5 wall time was 59.7…87.2 ms (median ≈70 ms),
which is not the earlier 33.7…36 ms Library-build number. The instruction gate
bounds synchronous main-thread computation on accepted keys; helper-thread,
drawing/GPU and deferred work remain gaps. Structural checks still apply on
all machines. No other check or tolerance changes.
Instructions measure work; later timeout gates must still assert schedules and
behavior because waiting alone retires little work.

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
