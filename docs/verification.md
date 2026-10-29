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

### Simple Boost editor open: load-robust gate (2026-10-28)

The old `EditorBench` row already used `CLOCK_THREAD_CPUTIME_ID`, rather than
wall time. Untouched `origin/main` `64e54195` failed only this row:
**17.964 ms CPU p95**, load1 **77.35**, **1470/1471** Site Control checks passed.
The same run's cold fixture printed 11.615 ms CPU / 189.481 ms wall p95 at
load1 84.21. That wall/CPU gap includes time off the CPU (preemption or blocked native
calls). Such waits were already excluded from the editor's old CPU gate.
CPU execution rate still varies under load.
Core choice, frequency and memory contention were not measured separately.

Temporary thread-CPU splits in `BoostEditorController.present` and the real
settle path located the cost. At load1 6.28, CPU p95 was 13.336 ms: presentation
7.432 ms, separate layout 0.069 ms, display 0.181 ms, transaction flush 6.328 ms.
These are independent p95 values; do not add them. Within presentation, fresh
view/session/panel construction took about 3.4–4.7 ms in the measured opens.
The font cells called font lookup and text rasterization on each fresh tree.
PNG hue sampling runs separately on a worker; it was 7.640 ms in the failing
stock run and is outside the open span. The temporary probes are removed.

`EditorButton` now caches only the fixed 26×26 font-cell images, keyed by family,
1x/2x scale, selected/pressed/hovered state and enabled state. The 128-entry cap
bounds retained images. Core Graphics measured a 224-byte row at 2x: 11,648 bytes
per bitmap, at most 1.43 MiB for the cache on this M5. Every native control,
accessibility node, focus layer and selection transition remains live.

`EditorOpenBench` retains the same workload: one real 2x editor panel creation,
layout, native first display and transaction flush; five discarded warmups and
20 measured opens. Each open now has its own autorelease pool; panel close and
pool draining remain outside the measured span. The full `check` path drains
completed UI suites before starting the next suite. It also requires successful presentation and a native content
view. The existing harness-only `ThreadInstructions` sampler brackets that span.
The hard regression gate uses the rounded-up median main-thread instruction
count, with the existing CPU-brand/macOS-build fixture and ×1.10 method.
Missing/backward counters or an invalid fixture fail. An unknown editor reference
reports INFO, with no cost PASS. No CPU or wall-time fallback or retry exists.
CPU p95, wall p95, presentation/settle CPU p95, lateness versus **12 ms**, and
load1 are printed on every run. A separate **INFO** table row prints main-thread
CPU p95 versus **12 ms**, its lateness and load1. It is excluded from acceptance
counts, including when p95 exceeds 12 ms. GPU completion and deferred work remain outside
this existing native-display span.

Cost acceptance and reference recording use only the complete
`sitecontrol-render check` procedure, as invoked by the verification runner.
Standalone `bench --group editor` prints raw instructions and CPU INFO but has
no instruction-budget acceptance. Its process history differs from the full
check. Only `check` passes `acceptInstructionCost: true` to `EditorBench`.

The **initial editor instruction reference** in `54b636bc` was recorded before
the font-image optimization. Three separate processes with the **original product
sources** produced the values below; the median of their medians was
**141,542,712**, with a ceiling of **155,696,984**. These values are retained as
history. The first parent review re-recorded the optimized product, but used a
standalone benchmark with different process history. Both references below are
historical; the current reference uses the corrected full gate procedure,
described after them. The cold-open and SM6 references remain unchanged.

| Process | Original median instructions | CPU p95 ms | Wall p95 ms | Load1 |
|---|---:|---:|---:|---:|
| 1 | 141,176,621 | 14.967 | 17.113 | 11.48 |
| 2 | 141,865,163 | 15.342 | 22.943 | 8.31 |
| 3 | 141,542,712 | 17.062 | 20.806 | 8.31 |

The instruction medians have 0.49% full spread, while CPU p95 varies by 14.0%.
With the font cache, the same three-process bench gave:

| Process | Cached median instructions | CPU p95 ms | Wall p95 ms | Load1 |
|---|---:|---:|---:|---:|
| 1 | 136,812,486 | 13.282 | 14.599 | 8.13 |
| 2 | 136,139,868 | 13.423 | 15.325 | 8.13 |
| 3 | 136,352,450 | 12.874 | 14.710 | 7.88 |

The median work fell **3.67%**. These loaded CPU values do not establish quiet
`<12 ms` acceptance. The parent explicitly prohibited synthetic burners; none were started. All later checks use real shared load.

The first parent review (`c3628d9e`) re-recorded a reference from the optimized product in
`54b636bc`, with the explicit INFO row added outside the measured span. Following
SM6's recording method, discard one fresh process, then take the median of five
fresh-process medians. Each editor process still discards five opens and measures
20. The exact command is
`Packages/OpenKit/.build/release/sitecontrol-render bench --group editor`.
The recording used the shipping font-image cache without product-source changes;
`review-reference.json` retains all 20 samples per process, source/binary hashes
and the raw logs. No process was retried or selected out of the five.

| Process | Optimized median instructions | CPU p95 ms | Wall p95 ms | Load1 |
|---|---:|---:|---:|---:|
| Discarded warmup | 136,266,026 | 13.930 | 16.686 | 14.55 |
| 1 | 136,469,336 | 13.835 | 18.617 | 14.55 |
| 2 | 136,091,821 | 12.957 | 15.291 | 14.91 |
| 3 | 135,985,517 | 13.295 | 14.156 | 14.75 |
| 4 | 136,063,236 | 8.981 | 10.841 | 14.37 |
| 5 | 135,987,601 | 9.525 | 11.424 | 13.94 |

That historical optimized reference was **136,063,236**; its ceiling was
**149,669,560 = ceil(136,063,236 × 1.10)**. It lowered the initial ceiling by
6,027,424 instructions, but the later review below found mismatched procedures.
The original **141,542,712** reference above is historical only. Some INFO values
are below 12 ms, but these are shared-load recordings; the lead's quiet-machine
acceptance before merge remains required.

The next parent review found a procedure mismatch: `c3628d9e`'s two full gate
runs measured **144,265,719 / 144,230,413**, or **+6.028% / +6.002%** above its
standalone reference. Instruction probes located the extra work in the global
`CATransaction.flush()`. Both paths used scale 2, five warmups and twenty measured
opens; they had different populations of autoreleased native windows.

| Instrumented procedure | Start/end native window list | Present median instructions | Layout/display median | Flush median | Total median |
|---|---:|---:|---:|---:|---:|
| Standalone bench | 2 → 27 | 90,921,755 | 1,225,610 | 44,258,568 | 136,524,128 |
| Full check, before pool fix | 133 → 158 | 90,896,645 | 1,230,301 | 51,708,916 | 143,835,526 |
| Full check, drain completed suites | 5 → 30 | 90,115,887 | 1,214,082 | 43,836,864 | 135,037,759 |

Phase medians are independent and need not sum to the total median. The first
two rows differ by **7,450,348 instructions in flush**, while presentation differs
by only 25,110. All three rows had **400 font-image cache hits and zero misses**
in the twenty measured opens. The cache had 20 entries in standalone and 44 in
the full path, but neither path decoded/rasterized font cells during measurement.

The controlled change was to drain autorelease pools after completed cold,
flow, editor-flow, render and skeleton suites. This released the earlier suites'
closed native window objects before the editor's global transaction flush.
The full gate's start list fell **133 → 5**, and its total work fell
**143,835,526 → 135,037,759**. This identifies prior-suite window lifetime as the
cause of the extra work; it is not a scheduler or warm/cold font-cache explanation.
Raw probes are `procedure-profile-bench.log`, `procedure-profile-check/` and
`procedure-pool-profile-check/`. All temporary `[DEBUG-procedure]` probes and
font-cache counters were removed before recording the final reference.

The benchmark also drains a pool after closing each sample's panel. This keeps
closed windows from accumulating across its own five warmups and twenty samples,
matching AppKit's usual event-loop pool lifetime. The real open/layout/display/
flush remains inside the counters; earlier suites and panel teardown are outside.
Every final run prints its procedure and before/after native-window counts.

The current accepted reference is recorded by **five complete fresh-process gate runs**, using exactly this command each time:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render
```

Each invokes the full `check` path, after pooled suites, at 2x with five discarded
opens and twenty measured opens in a per-open pool. No whole process was discarded
or retried. The reference is the median of the five process medians.

| Reference process | Median instructions | CPU p95 INFO ms | Load1 | Native window list | Full check |
|---|---:|---:|---:|---:|---|
| 1 | 135,418,826 | 14.775 | 8.70 | 5 → 5 | 1471/1471 PASS |
| 2 | 135,732,992 | 13.486 | 7.60 | 5 → 5 | 1471/1471 PASS |
| 3 | 135,059,155 | 11.272 | 9.94 | 5 → 5 | 1471/1471 PASS |
| 4 | 135,203,676 | 14.056 | 8.20 | 5 → 5 | 1471/1471 PASS |
| 5 | 134,606,189 | 10.124 | 10.00 | 5 → 5 | 1471/1471 PASS |

**Accepted reference: 135,203,676; ceiling: 148,724,044 = ceil(reference × 1.10)**.
The five medians span **0.833%** of the reference. Source hashes, executable
hashes, all twenty samples per process, per-command loads and the unchanged
procedure label are retained in `procedure-reference.json` and
`procedure-reference-1/`…`procedure-reference-5/`. All five started and ended
with five entries in the native window list. The fifth command waited 375 s
for a heavy slot; its on-screen check duration also includes lock queue time,
which is outside the unchanged 180 s execution deadline.

The 28 editor render images before/after cover 1x/2x and all editor states.
All 28 font-card regions are pixel-identical. 23 full images are identical;
the other five differ at nine pixels outside the font card by at most 1/255,
within the pre-existing `CLI.stablePixels` 2/255 native redraw tolerance. No
comparison threshold or saved render baseline changed.

Initial negative proof against the historical ceiling: temporarily construct four extra `BoostEditorView` trees inside
`BoostEditorController.present`, before constructing the actual view. Each tree
performs the real O(n) native font/control construction. The unchanged gate
reported:

```text
| FAIL | simple editor build/layout/first draw median 372869037 instructions <= 155696984 (ceil(141542712 x1.10)); Apple M5 Pro / 26B5112a |
5/6 passed
```

The other five benchmark checks passed (CPU p95 41.261 ms, load1 7.71). The
extra trees and all debug probes were then removed and the release binary
rebuilt. This proof adds real work inside the production open path; it does
not alter the gate or its fixture.

At `c3628d9e`, the parent-review negative proof repeated the real four-extra-tree construction
inside `BoostEditorController.present`, including each extra view's native
layout, against the **optimized** reference and lower ceiling:

```text
| INFO | simple editor build/layout/first draw main-thread CPU p95 38.466 ms vs 12 ms; lateness +26.466 ms; load1 17.04 (quiet-machine acceptance by lead) |
| FAIL | simple editor build/layout/first draw median 396669877 instructions <= 149669560 (ceil(136063236 x1.10)); Apple M5 Pro / 26B5112a |
5/6 passed
1 INFO (no acceptance result for these entries)
```

This run exited 1 as required; all five other acceptance checks passed. The
extra work was removed in a `finally` path and the release binary rebuilt.
`BoostEditorPanel.swift` is byte-identical to `54b636bc`. The new INFO row
therefore stays visible even on failure, without raising the pass count.
Raw evidence is `review-negative.log` and `review-negative-proof.json`.

The current negative proof uses the **same full gate command as calibration**:
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render`.
Temporarily construct and lay out four extra real `BoostEditorView` trees inside
`BoostEditorController.present`, before constructing the actual editor. The
unused sessions have no interactions and are released without calling the host's
close action, so the proof adds native construction/layout without changing the
flow's expected close count or deleting a new empty Boost. Against the current
reference, the real command reported:

```text
| INFO | simple editor build/layout/first draw main-thread CPU p95 22.861 ms vs 12 ms; lateness +10.861 ms; load1 11.95 (quiet-machine acceptance by lead) |
| FAIL | simple editor build/layout/first draw median 365893368 instructions <= 148724044 (ceil(135203676 x1.10)); Apple M5 Pro / 26B5112a |
1470/1471 passed
2 INFO (no acceptance result for these entries)
```

The full verification command exited **1**; only the editor instruction budget
failed. The renderer was reaped and no native app remained. The temporary trees
were removed in a `finally` path and the release binary rebuilt before the three
final gate runs. `BoostEditorPanel.swift` is byte-identical to `c3628d9e`.
Evidence: `procedure-negative/`, `procedure-negative-proof.json` and the restored
release-build log. The ×1.10 ceiling and 12 ms product target were unchanged.

F25 native focus also needed an environment classification. Earlier runs
closed and hid the editor while the app became inactive and its parent was not
key. At load1 29.45 all three old attempts lost activation (`green-8/`). The user
then confirmed active use of this Mac, often with T3 Pretty frontmost, plus other
agents that may activate apps. External foreground loss is **INTERRUPTED**, not
an Open failure.

F25 now follows `tools/e2e/engine_e2e.py`: at most three attempts, each from a
fresh registered app, model and windows. Every attempt records foreground app
name, bundle ID and PID plus load1; strings are bounded and line/pipe sanitized.
A focus-dependent assertion outside the owned harness/renderer processes is
recorded as `INTERRUPTED (foreground lost to <app>)`, even if its local assertion
was true. Historical interrupted rows remain visible and never count as passes.
A later complete attempt can PASS; an owned-foreground wrong-key/loss result is
FAIL without retry. The cached app flag alone is not sufficient. No app is
activated and no window is made key to repair a tested Done action.

If all three attempts are interrupted, the native CLI, locked worker and
`verify-all.sh` propagate **INTERRUPTED / exit 2**, not FAIL or PASS. Real failures
retain exit 1, and available interrupted checks are not relabeled SKIP. The
native 20 s process bound, 3 s setup/close bounds and configured 0.120 s close
remain unchanged. Foreground status is collected only from app identity, never
window titles or URLs.

A separate fixture isolation issue was proved. `padAndWindowFlows` had closed
two controllers but left their two offscreen `EditorParentWindow` objects ordered
in the renderer while the registered native suite ran. The new guard failed on
the old caller:

```text
| FAIL | F25 native key suite has no competing editor parent windows (found 2) |
93/94 passed
```

The other 93 editor flow checks passed. `EditorFlows` now closes both parents
before native launch, and the zero-competing-parents guard remains. The native
fixture creates its activating browser parent first, then waits for that window
to be active, frontmost, main and key before presenting the nonactivating panel.
This establishes a valid browser precondition without relying on a windowless
app becoming frontmost. Only the on-screen fixture changes; offscreen render
and benchmark geometry remain unchanged. Fixture isolation does not claim to
prevent the external app changes confirmed by the user.

A second runner flake was found before final verification. The old runner
applied `run(..., timeout=180)` to **lockf plus the renderer**, so lock queue time
consumed the execution deadline. It failed after 180 s and left renderer PID
40906 running with PPID 1 after lockf exited. That process had exited before the
resume audit; no owned renderer or harness app remained.

`check.py` now runs an internal worker **after** `/usr/bin/lockf` acquires the
shared lock. The outer lock wait has no suite deadline. The worker keeps the
unchanged **180-second** renderer deadline, owns a fresh process group, and
terminates the group and reaps its renderer on timeout or exception before
returning to lockf. Registered
LaunchServices apps escape that process group, so the worker also owns a private
suite root and removes only harness apps whose full executable path is under
that root. Foundation used its system temp directory despite `TMPDIR` in the
observed CLI; `OPEN_VERIFY_SUITE_ROOT` now explicitly places the registered app
copy under the owned root. A relative, missing or oversized root is refused.
The runner checks full paths before each signal and waits for app disappearance.

The real timeout proof held the lock with an explicit release handshake, observed
2.067 s queue time with no suite startup before release, then paused only its
renderer and real registered app. The unchanged deadline reported:

```text
On-screen cleanup: renderer 86332 reaped; native apps stopped=1
FAIL: on-screen suite timed out after 180s (owned children reaped)
```

Both PIDs were absent and the private root was removed. The log lifetime was
182.387 s including the queue and cleanup. The proof controller's final assertion
incorrectly assumed the shared lock would remain free; another job had acquired
it (observed lockf PID 90590). That assertion was corrected to check our wrapper's
exit, not exclude other users. The actual timeout artifacts and process absence
were independently audited in `runner-timeout-proof.json`; no extra 180-second
fault run was used to replace the recorded result. The invalid-root CLI also
failed as intended (`0/1 passed`) before launching any app.

Initial foreground verification for `54b636bc`, `verified-1`…`verified-6` (real shared load;
no synthetic burners):

| Run | Editor median instructions | CPU p95 ms | Wall p95 ms | Load1 | Result |
|---|---:|---:|---:|---:|---|
| 1 | 144,209,011 | 13.374 | 14.888 | 19.56 | 1471/1471 PASS; renderer reaped |
| 2 | 144,169,435 | 10.983 | 12.800 | 30.52 | 1471/1471 PASS; renderer reaped |
| 3 | 144,738,612 | 14.213 | 16.421 | 22.37 | 1471/1471 PASS; renderer reaped |
| 4 | 144,747,754 | 16.770 | 18.063 | 23.71 | 1471/1471 PASS; renderer reaped |
| 5 | 144,454,806 | 18.684 | 20.127 | 15.73 | 1471/1471 PASS; renderer reaped |
| 6 | 145,503,985 | 17.520 | 21.647 | 14.54 | 1471/1471 PASS; renderer reaped |

All six final native suites passed on attempt 1; no interruption was needed in
this series. The foreground app/bundle, PID and load are retained per attempt.
The full-run receipts recorded real load1 from 16.38 at entry to 14.54 at the
last exit, peaking at a run boundary of 30.52. These are observed shared-machine
conditions, not controlled quiet runs. Instruction medians stayed below
155,696,984 while CPU p95 varied from 10.983 to 18.684 ms. Quiet `<12 ms`
acceptance remains with the parent as requested.

`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render,settings-preview`
passed: build (no warnings/errors), sidebar **568/568**, features **288/288**,
settings **37/37** plus **216** render PNGs/dimension checks. Real load1 was
14.07 at entry and 8.25 at exit (`verified-7/`). No further flakes appeared in these targets.
Three earlier separate `sidebar-render check` runs also passed **568/568** each;
HP1 fired on its first attempt in 0.502 / 0.504 / 0.500 s, lateness +2 / +4 / +0 ms,
load1 7.94 / 7.41 / 10.18. SM4 and MC6 passed in all three. Main already contains
`1fe805a3` (PR #115); no sidebar timing code or baseline changed here.

Verification for `c3628d9e` used its historical **149,669,560** ceiling and the explicit
CPU INFO row. Both requested foreground runs of
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render`
passed **1471/1471**. The INFO rows do not change that acceptance count:

| Run | Editor median instructions | CPU p95 INFO ms | Lateness vs 12 ms | Load1 at INFO row | Result |
|---|---:|---:|---:|---:|---|
| 1 | 144,265,719 | 19.254 | +7.254 ms | 18.29 | 1471/1471 PASS; renderer reaped |
| 2 | 144,230,413 | 16.296 | +4.296 ms | 15.38 | 1471/1471 PASS; renderer reaped |

Run 1 recorded load1 18.02 at command entry and 18.29 at exit; run 2 recorded
16.78 and 14.55. Each complete CLI report has **2 INFO** entries: the existing
skeleton diagnostic and the new CPU-target row. The editor-only command has
**1 INFO** entry. Both native suites passed on attempt 1. Evidence:
`review-verify-1/`, `review-verify-2/`, `review-verification-results.json`.

The requested review command
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render`
also passed: build **PASS** (no warnings/errors), sidebar **568/568** and features
**288/288**. It recorded load1 **14.55** at entry and **12.59** at exit, with
145.261 s total command time (`review-verify-3/`). No synthetic load was started.

Current final verification repeats the **same full gate command and procedure**
as the five reference recordings, after restoring the negative-proof source:

| Gate run | Reference | Measured median instructions | Delta from reference | CPU p95 INFO ms | Load1 | Result |
|---|---:|---:|---:|---:|---:|---|
| 1 | 135,203,676 | 135,164,914 | -0.029% | 11.054 | 11.14 | 1471/1471 PASS |
| 2 | 135,203,676 | 134,538,031 | -0.492% | 10.786 | 9.46 | 1471/1471 PASS |
| 3 | 135,203,676 | 134,613,556 | -0.436% | 8.770 | 7.93 | 1471/1471 PASS |

All three medians are within **0.50%** of the accepted reference. All three
started and ended with **5 → 5** native window entries; all twenty samples per
process and the procedure label are retained in `procedure-verification-results.json`
and `procedure-verify-1/`…`procedure-verify-3/`. Each renderer was reaped and each
private suite root removed. No synthetic CPU load was started. The CPU INFO
values are shared-load diagnostics; quiet-machine acceptance remains with the
lead before merge.

A real standalone `bench --group editor` invocation also passed **5/5** behavior
checks with **2 INFO** rows and **2 → 2** native window entries. Its instruction
row explicitly requires `sitecontrol-render check` for cost acceptance; it has
no instruction-budget PASS. This verifies the CLI cannot silently compare the
standalone procedure with the full gate reference (`procedure-standalone.log`).

Merged-main verification at `013cdb45` ran the full command
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh`: **22/22 PASS**,
no FAIL or SKIP. Editor median **135,900,397** versus reference **135,203,676**
(**+0.515%**), CPU p95 11.314 ms at load1 17.19, native window list
**5 → 5**. The reference remains unchanged because the difference is below 2%.
The command waited 180 s for a heavy slot; total command time was 688.137 s.
Generated `docs/engine-spike/` files were restored before the merge commit.
Raw summary and logs: `.re/sidebar-flakes/merge-full-013cdb45/`.

Final merged-main verification includes `dee105e6` (items 9–10, PR #132) on top
of the tested `013cdb45` merge. The full command
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh` ran once on this
updated tree: **22/22 PASS**, no FAIL, INTERRUPTED or SKIP.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 59 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 0 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 3 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 13 |
| commands-dump | PASS | 1 |
| route | PASS | 0 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 78 |
| sidebar-render | PASS | 106 |
| sidebar-compare | PASS | 88 |
| commandbar-render | PASS | 15 |
| features-render | PASS | 42 |
| sitecontrol-render | PASS | 52 |
| boosts | PASS | 6 |

Editor median **135,491,848** versus reference **135,203,676**
(**+0.213%**), ceiling **148,724,044**. The native window list remained
**5 → 5**. No reference was re-recorded because the difference is below 2%.
CPU p95 INFO was **10.012 ms**, lateness versus 12 ms **-1.988 ms**, load1
**17.28**. The 12 ms target remains unchanged; lead quiet-machine acceptance
is still required before merge. The command recorded load1
**20.87 → 19.46**, waited 50 s for a heavy slot, and
completed in **521.831 s** including the wait.

The editor renderer was reaped, its private native-app root was removed, and
no owned Open/renderer process remained. `docs/engine-spike/` was restored to
the tested merge tree before the evidence commit. Raw summary and logs:
`.re/sidebar-flakes/merge-full-dee105e6/`; receipt:
`.re/sidebar-flakes/merge-dee-handoff-receipt.json`. No PR was opened.

Scope: `BoostEditorViews.swift` caches font pixels; `EditorBench.swift`, the new
`EditorOpenBench.swift`, `InstructionBaseline.swift` and `instruction-baselines.json`
own the editor cost gate. `main.swift` drains completed suites and is the sole
caller that enables editor cost acceptance; standalone bench is diagnostic only.
`EditorNativeKey.swift` owns the F25 activation barrier, wait/retry and
explicit suite-root contract; `EditorScenes.swift` establishes only the on-screen
parent activation/main/key precondition, and `EditorFlows.swift` closes the
competing offscreen parents before native launch. `tools/verification/check.py` owns lock ordering,
execution deadline, foreground-interruption propagation and child cleanup. No App/engine code, comparison assets,
sidebar timing logic, CPU-ms target, cold-open reference or SM6 reference changed.
Parent review lowers only the accepted editor reference to the optimized product.

| Review checklist | Result | Evidence |
|---|---|---|
| Input/memory limits | PASS | 128 fixed font images; bounded reference values/resource; absolute existing suite root capped at 4096 UTF-8 bytes; invalid-root CLI refuses input |
| Lifetimes/callbacks | PASS | Completed-suite and per-open pools keep the final native window list at 5 → 5 in five reference and three gate runs; native attempts and timeout cleanup release their owned processes |
| Real event paths | PASS / N/A | Existing real NSApp native key flow retained; no App key router or command path changed |
| Checks/proof/isolation | PASS | Old CPU gate red; real added native work red; real 180 s timeout/cleanup red as intended; two-window isolation guard red on old caller; unique suite root and UUID preferences |
| UI/motion | PASS | 28 exact font-card regions; full images within existing 2/255 tolerance; configured 0.120 s close unchanged |
| Docs | PASS | Full-gate reference, procedure mismatch evidence and original history recorded; quiet `<12 ms` lead acceptance remains open in followups |

Reproduction commands from the repo root:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render
# Standalone diagnostic only, wholly offscreen; no instruction cost acceptance.
Packages/OpenKit/.build/release/sitecontrol-render bench --group editor
Packages/OpenKit/.build/release/sidebar-render check
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render,settings-preview
```

The **lead must run the quiet-machine 12 ms acceptance check before merge**.
With other build/encode work idle and the load average recorded, run the same
full gate procedure from the repo root:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render
```

Read the `INFO` row `simple editor build/layout/first draw main-thread CPU p95
... vs 12 ms; lateness ...; load1 ...`. Quiet-machine acceptance requires CPU
p95 **<12 ms**; an instruction-gate PASS alone is not latency acceptance. The
lead records the value and actual load. This shared-machine task does not claim
that acceptance. The runner builds first, then serializes the native UI suite
with the on-screen lock. Standalone `bench --group editor` remains a timing
diagnostic and cannot replace the full procedure for acceptance or calibration.

Raw synthetic receipts, all 20 instruction samples per bench, build logs, phase
probes, binary SHA-256 and before/after render comparisons remain local under
`.re/sidebar-flakes/`. No Arc process, user data, desktop input, engine tree or
unit tests were used.

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
