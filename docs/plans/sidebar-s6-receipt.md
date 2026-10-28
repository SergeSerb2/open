# Sidebar S6 local handoff

Base: 2d51f14a1207c00157edb90f51459d97b7b1096b (A2 over A1).
Branch: t3/sidebar-s6-folder-peek. Local only; no push or PR.

## Matched plain-toggle and rendering round after fffe0395 (2026-10-28)

The pinned parent is `2d51f14a1207c00157edb90f51459d97b7b1096b`. The wrapper exports
that exact commit under `.re/s6/fp10-parent`, adds measurement hooks and the same
portable plain-toggle driver, then builds both release CLIs with the same toolchain.
It does not apply branch rendering or reconciliation changes to the parent.
Each attempt rotates parent plain expand/collapse, branch plain expand/collapse,
and branch expanded → peeked → collapsed → expanded. The metric is the same sum
of real AX input, completed observed reconciliation (including display/CA commit),
and final layout/display. Each sample verifies real native row membership. All
fixtures use 1,000 displayed rows, scale 2, a 1,280×900 window and 228 pt sidebar.
Plain expanded has the same three direct children as the toggled peek folder.
Fixture construction, warm-up, IPC wait, queued observation wait and animation wall
time are excluded; reconciliation/display work is included.

**Parent gate decision:** if the pinned parent plain p95 is >2.00 ms, use
`max(2.00 ms, matched branch plain p95 ×1.10 +0.05 ms)` for that attempt. Otherwise
peek must be ≤2.00 ms. Using the branch control for the allowance is conservative
when the parent is slower. A missing pinned parent gets no exemption. Run all
three attempts to show the requested baseline table; the bounded review retry
rule accepts a run if an attempt meets every gate. Scroll still requires native
layouts/frame peek ≤baseline, peek p95 ≤8.33 ms and ≤baseline p95 ×1.10 +0.05 ms.
The reason is measured existing plain-toggle cost, rather than a fitted tolerance
for peek. §3.17 and FP10 record this rule. The original strict gate's historical
failures below remain failures of that earlier definition.

Final default-window run: **3/3 PASS** (`fp10-geometry-final.log`). Times in ms;
plain columns are median/p95, peek is median/p95/max. Loads print at attempt start
and sample completion; scroll loads below are recorded when scrolling completes.

| Attempt | Load1 start / transition | Parent plain median / p95 | Branch plain median / p95 | Peek median / p95 / max | Computed p95 limit | Result |
|---|---|---|---|---|---:|---|
| 1 | 8.55 / 8.67 | 2.32 / 3.260 | 1.92 / 2.983 | 1.81 / 3.114 / 4.79 | 3.331 | PASS |
| 2 | 8.67 / 8.72 | 2.42 / 3.517 | 2.05 / 3.239 | 1.80 / 3.167 / 4.57 | 3.613 | PASS |
| 3 | 8.72 / 9.06 | 2.43 / 3.275 | 2.09 / 2.892 | 1.79 / 2.883 / 3.48 | 3.231 | PASS |

The parent plain p95 exceeds 2 ms in all three attempts; branch plain also retains
that floor. The earlier parent-run c095ca1d figure was peek median/p95/max
1.84/2.87/5.27 ms at load1 7.5. A median well under 1 ms is **not achieved**.
Remaining outline/AppKit/backing-layer rendering work is tracked in followups;
the paired gate measures added peek cost without relabelling that goal as met.

### Rendering evidence and retained changes

- Before this round, the one-transition trace shows AppKit asking every available
  row for display and then calling their `updateLayer`. The folder glyph uses
  `draw` with dirty rect `{{-16,-10},{228,41}}`; a newly exposed bottom cell title
  uses `{{-43,0},{228,24}}`. These are dirty rectangles in their local coordinates,
  not evidence that every neighbor's title/favicon was painted.
- `SidebarRowView` already uses `wantsUpdateLayer`. It now discards native clean
  invalidations before `super.needsDisplay`; model identity/selection observation
  explicitly marks the fill dirty. Hover/current/appearance updates retain their
  direct layer path. The trace after the change shows only the entering/reused row
  background update; unchanged neighbors receive no effective display request.
- The folder glyph now uses `wantsUpdateLayer` and cached CGImage layer contents
  rendered from Open's own existing vectors. The cache holds at most 64 images
  of ≤64×64 RGBA pixels (1 MiB); larger/custom one-off images cap at 256×256
  (262,144 bytes). Typed/legacy/emoji overrides keep their precedence; scale and
  accent are in the cache key. No Arc asset is copied. FP6 remains identical.
- Native insertion does schedule layout across the visible row containers.
  Bounds/indent caching now avoids repeated fill/ring/shadow geometry assignment
  for rows that only moved. In the final 240-transition sample there are about
  19.33 native row-container layouts per transition but **zero layer geometry
  updates**, about 2.33 content-cell layouts and 2.33 visited cached items.
- After warming the real three-state cycle, all three main attempts report
  **zero row allocations and zero cell allocations**. Native reuse supplies
  398–400 cells per 240 transitions (1.66–1.67 per transition). No per-node view
  cache was added. Height queries total 240; `noteHeightOfRows` calls/rows are 0.
  There is no whole-outline reload or all-row height invalidation.
- Final phase medians on attempt 3: native walk/edits 0.41 ms, layout 0.11 ms,
  display 0.24 ms, CA flush 0.89 ms. CA commit remains the largest individual phase.
  The correct-PID sample from the previous round points to
  `syncExpansion → CA::Transaction::flush → NSViewBackingLayer display`.

Each change was measured separately. At load1 17.21/16.40/16.52, the instrumented
pre-change peek medians were 2.18/2.06/2.17 ms, p95 3.29/3.89/3.64 ms. Glyph-only
medians were 1.98/2.62/2.70 ms at load1 16.44/17.37/17.18; p95 2.98/4.09/4.45 ms.
Clean row invalidation medians were 2.32/2.23/2.12 ms (full numbers in
`fp10-row-layer.log`). Final geometry-guard numbers are in the table above.
Loads differ, so these are not a controlled percentage speedup. The deterministic
reductions are the discarded clean invalidations, cached glyph draws, zero view
allocation and zero repeated row layer-geometry assignment.

### Commands and current checks

One command prepares the pinned parent, builds the current CLI and runs all three
matched attempts (offscreen; invoke from this worktree):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py
```

Add `--trace-transition` for one bounded draw/updateLayer/dirty-rect trace per
attempt (excluded from timed samples); add `--visible-rows 10` or
`--visible-rows 30` for the exact native viewport counts. Both negative proofs
are fast, one-attempt real-interface commands and must exit 1 on their intended
gate, using the same baseline measured in that run:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py --negative-proof
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py --negative-transition-proof
```

| Attempt | Scroll load1 | Baseline / peek scroll p95 (ms) | Native cell layouts/frame baseline / peek | Result |
|---|---:|---|---|---|
| 1 | 8.55 | 1.50 / 1.47 | 18 / 18 | PASS |
| 2 | 8.69 | 2.06 / 1.83 | 18 / 18 | PASS |
| 3 | 8.72 | 1.46 / 1.39 | 18 / 18 | PASS |

Exact native viewport experiment (same fixture/scale, changing only window height;
three attempts each, 3/3 PASS). Timing/load differences preclude claiming a precise
slope. CA commit does not grow threefold when native row-layout calls do.

| Native visible rows | Attempt loads1 at transition | Transition medians / p95 (ms) | CA-flush medians (ms) | Native row layouts per transition | Layer geometry updates per transition |
|---|---|---|---|---:|---|
| 10 (372 pt clip) | 21.43 / 21.00 / 20.84 | 1.50/2.69; 1.61/2.66; 1.44/2.78 | 0.70 / 0.74 / 0.64 | 10.33 | 0 / 0 / 0 |
| 30 (1,192 pt clip) | 11.49 / 11.29 / 11.35 | 1.71/2.69; 1.78/2.96; 1.91/3.04 | 0.80 / 0.80 / 0.84 | 30.33 | 0 / 0 / 0.67 |

The small number of required geometry updates in the last 30-row case is allowed
only when bounds/indent changes; unchanged neighbor geometry still skips. The
initial exploratory 11/31-row measurements were superseded by these exact 10/30
viewports; the fixture now counts the actual 3 pt spacer.

| Failure control | Measured evidence | Result |
|---|---|---|
| O(n) native layout pass per frame | Load1 10.44, baseline/peek p95 2.50/440.05 ms; native layouts/frame 3/1,000 | Intended work gate FAIL, exit 1 |
| Real 3 ms CPU spin inside transition | Load1 11.16, busy phase median/p95 3.00/3.00 ms; plain/parent/peek transition p95 2.516/3.145/6.037 ms; computed limit 2.817 ms | Intended transition gate FAIL, exit 1 |

Private artifacts: `fp10-paired-before.log`, `fp10-layer-only.log`,
`fp10-row-layer.log`, `fp10-geometry-final.log`, `fp10-visible-10-exact.log`,
`fp10-visible-30-exact.log`, `fp10-fullrow-final.log`, `fp10-busy-final.log`.
Parent export provenance is in `.re/s6/fp10-parent/fp10-manifest.json` (pinned SHA,
portable driver/script fingerprint, measurement-only patch description). No raw
Arc/private content is in those synthetic fixtures.

| Final check / exact command | Result |
|---|---|
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render --keep-logs` | PASS: build 32 s; sidebar-render **595/595** (106 s, inherited SW1–SW4 skips); features-render **293/293** (31 s). |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | PASS: rebuilt Debug Open. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion` | **80/80 PASS**, including **16/16 E20**; first suite invocation, 0 interruptions, owned-process/window cleanup PASS. No retries required. |
| `sidebar-render plain-toggle-probe --rows 0` | Expected rejection before fixture allocation, exit 1; bounded 1,000-row control enforced. |

The initial functional run before the last geometry guard also passed 595/595 and
293/293; the table above is the repeated final-source check. Default FP10 is a
separate opt-in performance command, not counted as an implicit functional PASS.
A final bench-only review moved fixture cleanup registration before the potentially
throwing parent launch. The release CLI rebuilt successfully (22.08 s), and
`sidebar-render bench --rows 1000 --scale 2 --folder-peek 50 --parent-renderer /does-not-exist/FP10-parent`
rejected all three attempted launches and returned exit 1 before any measurement.
Logs: `probe-cleanup-build.log`, `fp10-missing-parent.log`. The production rendering
and App source used by the green checks did not change.

Native JSON/PNG/log receipts are retained under `.re/s6/results-completion-paired-final.json`,
`E20-folder-peek-paired-final.png` and `e2e-paired-1.log`; generated tracked output
was restored, and no existing baseline image was changed. Verification logs:
`verify-paired-final.log` and `/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-164254.1zEKHO/`.

FP6 final-source render/compare (commands in the historical reproduction section,
using `peek-paired-final.png` and `compare-paired-fp6`): **PASS**. Dot ΔE00 remains
1.434/0.837/1.511 with one solid #B5AFFF token; body 0.000, pitch 4 pt, position
error 0, hover dash ΔE00 0.15. The 0.65 opacity guess remains superseded by the
capture-authoritative minimax fit.

`SIDEBAR_BASELINE_REF=fffe03953a5adacb704696ddf1b73222197f3fec ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-compare --keep-logs`
**PASS 13/13**, tables byte-identical **13/13**, position/ink identical, maximum
paired color drift **0 ΔE00**. CU5 **2/2**, exact divider pixels. Both concatenated
table hashes are `f72963370205cfc5c1eb3b18873eac96cbeb86012a735d20e1c1193b4fcfe203`.
This is the current round's comparison to fffe0395; the previous round's 1/13
byte-identical comparison to c095ca1d remains historical. The check waited 400 s
for a heavy slot, then passed in 117 s. Logs: `compare-paired-final.log` and
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-165502.qriNHX/`.
No baseline file or visual limit changed. Final process check finds no Open or
sidebar-render process from this worktree.


Changed files in this round:

- `Packages/OpenKit/Sources/OpenSidebar/Controls.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarRows.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarView.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SpacePageView.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderToggleProbe.swift` (new portable driver)
- `Packages/OpenKit/Sources/sidebar-render/RenderCLI.swift`
- `tools/verification/folder-peek-bench.py` (new pinned-parent wrapper)
- `tools/verification/check.py`
- `docs/plans/sidebar-completion.md`
- `docs/plans/sidebar-s6-receipt.md`
- `docs/status.md`
- `docs/followups.md`

New implementation choices: use the branch plain-toggle control for the relative
allowance, with the pinned parent only establishing whether the exemption applies;
run all three requested measurement attempts even after a pass; use bounded shared
own-vector image contents, rather than a per-node cell cache. The original plan's
keyboard/import/selection/Q17/Q18 choices remain listed below and unchanged.


### Review checklist for this round

| Item | Result / evidence |
|---|---|
| Inputs and allocations | PASS: exact 1,000-row paired fixture, visible rows 1…64, response ≤16 KiB, glyph cache ≤1 MiB, largest bitmap 262,144 bytes; invalid row input rejects. |
| Lifetime and callbacks | PASS: private probe exits/closes its window on quit/EOF; each attempt closes all windows; App native cleanup PASS. No new delegate/engine lifecycle path. |
| Real interface and failure sensitivity | PASS: AX input and native row counts, unchanged functional harnesses, App E20 16/16. O(n) and busy-wait controls both fail their intended computed gates. |
| UI/motion | PASS functional/native E20 duration and presentation checks; cached own vector and clean layer guards preserve geometry/selection semantics. Visual receipt is recorded below. |
| Performance | PASS under the parent's conditional gate, 3/3 default attempts, both controls reject. Sub-1-ms median remains open as outline-wide work. |
| Docs and scope | PASS: §3.17/FP10, §9, status and followups agree. No unit tests, Arc launch, computer use, subagents, engine-tree edits, push or PR. |



## Historical fffe0395 round after c095ca1d (2026-10-28)

Parent's c095ca1d run at load1 7.5: transition median/p95/max 1.84/2.87/5.27 ms; reconciliation+display median 1.74 ms; baseline/peek scroll p95 2.26/2.31 ms; native layouts/frame 18/18.

Profiling used completed-callback phase clocks, native work/draw counters, and `/usr/bin/sample` against the exact bench PID. The first split, before optimization, at load1 17.70 measured reconciliation+display median 1.87 ms: walk/native edits 0.44 ms and forced layout/display 1.41 ms. It visited 1,002 cached items and configured 21 row views per transition. A longer 2,400-transition diagnostic sample after targeting the observation showed Core Animation commit / AppKit backing-layer drawing as the remaining dominant cost (`fp10-transitions.sample`: `SpacePageView.syncExpansion` → `CA::Transaction::flush` → `NSViewBackingLayer display`). Actual title/favicon draws were about two per transition; the trace did not prove painting of unrelated node rows.

Changes retained:

- Each exposed folder owns a weak Observation loop, cancelled when its cache drops. A folder property change starts reconciliation at that folder, rather than scanning the 1,000-row root and every loaded folder. New/hidden Manager folders still reconcile through the existing structural/visibility paths.
- A subset removal/insertion uses one native `IndexSet` edit. A collapsed item's children are supplied once by native expansion. No reloadData, whole-outline reloadItem, height invalidation, or all-row view lookup was added.
- New child rows configure through `didAdd`; only the folder row needs an explicit state refresh. Unrelated row fills and the header are untouched. The measured case visits about two items and configures two row views, with two cell layouts.
- A tab's title and favicon share its cell backing context. Buttons and badges retain separate layers. The native-image-view, bitmap-cache, binding-cache, and transparent-document experiments did not establish a useful reduction and were removed.
- Bench output now reports phase timing, real work, draw counts, and thread CPU time as a diagnostic. It checks the native row count after every measured transition, so a no-op/broken expansion cannot satisfy the timing gate.

The parent's gate definition replaces the earlier max-time and clock-overhead guesses: **transition wall p95 ≤2.00 ms**, up to three fresh matched attempts; maximum native row layouts/frame peek ≤ baseline; scroll p95 ≤8.33 ms and ≤baseline p95 ×1.10 +0.05 ms in each paired, alternating run. Max remains diagnostic. The parent chose the time allowance for shared-machine jitter while retaining the deterministic work detector. CPU time does not change the verdict. All attempts and load1 values are printed. A real 3 ms CPU busy wait inside the transition callback is the second negative control, scoped to its diagnostic window and disabled in the App.

fffe0395 strict command: the historical strict command below, three attempts, all **FAIL** on transition p95. The <1 ms median target is **not met**. CPU diagnostic medians 1.70/1.83/1.80 ms are close to wall time; this is not explained away as scheduling noise. Further rendering/commit optimization is required before FP10 can be accepted.

| Attempt | Load1 start / sample | Transition median / p95 / max (ms) | Reconcile+display median (ms) | Baseline / peek scroll p95 (ms) | Layouts/frame baseline / peek |
|---|---|---|---:|---|---|
| 1 | 5.60 / 5.60 | 1.72 / 2.91 / 3.76 | 1.65 | 1.59 / 1.65 | 18 / 18 |
| 2 | 5.60 / 5.63 | 1.86 / 2.78 / 5.03 | 1.78 | 1.34 / 1.28 | 18 / 18 |
| 3 | 5.63 / 5.63 | 1.83 / 3.20 / 4.18 | 1.72 | 1.23 / 1.25 | 18 / 18 |

All three paired scroll comparisons meet the parent's absolute, relative and native-work conditions. The numerical relative limits were 1.802/1.524/1.401 ms. First-attempt phase medians: walk/native edits 0.36 ms, row-state refresh <0.01 ms, layout 0.10 ms, display 0.10 ms, CA flush 1.06 ms. The work bound improved; complete transition latency did not reach the requested target. Before/after runs had different load; no claimed percentage reduction.

| Required follow-up check / exact command | Result |
|---|---|
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render --keep-logs` | PASS: sidebar-render 595/595, inherited SW1–SW4 skips; features-render 293/293. |
| `SIDEBAR_BASELINE_REF=c095ca1d2472b9763e187f5490ef6560975bf619 ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-compare --keep-logs` | PASS 13/13; same position/ink, max paired color drift ΔE00 0.13; CU5 2/2. Tables byte-identical 1/13, not 13/13. No thresholds or baseline files changed. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | PASS, rebuilt Debug Open. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion` | INTERRUPTED after 3 bounded focus attempts: 18 accepted checks PASS, 0 FAIL, E20 not reached. Owned-process/window cleanup PASS. The c095ca1d 80/80 receipt below is historical, not a new-head pass. |
| Strict bench (command below) | FAIL 3/3 as shown; FP10 acceptance PENDING. |
| Strict bench plus `--negative-proof` | Expected FAIL, exit 1: actual full native pass gives 1,000 layouts/frame vs 3; baseline/peek p95 1.76/239.21 ms, load1 4.27. |
| Strict bench plus `--negative-transition-proof` | Expected FAIL, exit 1: 24 actual UI transitions, busy-wait phase median/p95 3.00/3.01 ms; transition median/p95/max 4.75/5.83/6.28 ms, load1 5.48. Native scroll layouts 3/3; it fails the transition gate. |
| FP6 capture render/compare (same commands below with `peek-optimized.png` / `compare-optimized`) | PASS: same single dot token, per-dot ΔE00 1.434/0.837/1.511, body 0.000, pitch/footprints/accessory within unchanged limits. |

Current private artifacts: `.re/s6/fp10-profile-before.log`, `fp10-transitions.sample` (2,400-transition diagnostic, not an acceptance run), `fp10-optimized-final.log`, `fp10-negative-optimized.log`, `fp10-negative-transition.log`, `verify-optimization.log`, `compare-optimization.log`, `app-build-optimization.log`, `e2e-completion-optimization.log`. Discarded experiments remain as private logs only; they are not accepted performance receipts.

### Follow-up review status

| Item | Result / evidence |
|---|---|
| Input/model/persistence scope | PASS: no model command, import format, undo behavior or external input size changed in this follow-up. |
| Lifetimes | PASS: per-folder loops hold weak owners and cancel on cache removal/deinit; native interrupted-suite cleanup reports no remaining owned processes/windows. |
| Functional and visual regression | PASS: 595/595 + 293/293; 13/13 unchanged-limit gates, position/ink identical and max color drift 0.13; FP6 capture PASS. No existing image or threshold changed. |
| Failure sensitivity | PASS: real O(n) frame work and real 3 ms transition CPU-spin controls each return exit 1 on the intended gate. |
| Native event path | INTERRUPTED before E20 after three foreground losses to T3 Pretty Internal (Nightly). The prior-head 80/80 receipt does not establish this head. |
| Performance acceptance | FAIL: transition p95 remains >2 ms and median remains >1 ms. Scroll/work gates pass; further rendering/commit optimization is open. |

### Follow-up changed files

- `Packages/OpenKit/Sources/OpenSidebar/Controls.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarRows.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarView.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SpacePageView.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift`
- `Packages/OpenKit/Sources/sidebar-render/RenderCLI.swift`
- `docs/followups.md`
- `docs/plans/sidebar-completion.md`
- `docs/plans/sidebar-s6-receipt.md`
- `docs/status.md`
- `tools/verification/check.py`

## Acceptance boundary

Functional/model/import/render/native verification for c095ca1d is preserved below. The latest matched-baseline round at the top supersedes earlier FP10 gate interpretations and outcomes. Historical native passes do not prove the current head. No image baseline or visual threshold changed. The parent handles pre-PR acceptance.

Historical fffe0395 strict command (no pinned-parent exemption):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh Packages/OpenKit/.build/release/sidebar-render bench --rows 1000 --scale 2 --folder-peek 50
```

Fast O(n) negative proof (expected nonzero exit, actual full-row work versus the matched baseline):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh Packages/OpenKit/.build/release/sidebar-render bench --rows 1000 --scale 2 --folder-peek 50 --negative-proof
```

Fast transition negative proof (expected nonzero exit on transition p95):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh Packages/OpenKit/.build/release/sidebar-render bench --rows 1000 --scale 2 --folder-peek 50 --negative-transition-proof
```

`SIDEBAR_FOLDER_PEEK_PERF=1` also enables the strict bench in the `sidebar-render` verification dispatcher. The default functional gate identifies FP10 as a separate performance command and does not count it as a performance pass.

## Measured color fit

Capture S2 08/0090, 1728×1084, sidebar228, row239, scale1. Both embedded ICC inputs are drawn into Display P3, then into sRGB for Lab D65 / CIEDE2000. The old white alpha0.65 guess was replaced by the lead because it missed the measured pixels: worst actual ΔE00 3.268, best possible white-opacity third-dot fit2.209. The capture is authoritative.

One solid token, `SidebarRole.folderPeekDots = #B5AFFF` sRGB, fills all three vector circles. Exhaustive integer sRGB fit over R170…192/G162…186/B248…255 minimizes maximum center ΔE00, then total ΔE00. No per-dot color or opacity is used.

| Sample | Capture sRGB | Render sRGB | ΔE00 |
|---|---|---|---:|
| (22,260) | #B9B4FF | #B5AFFF |1.434|
| (26,260) | #B6B2FF | #B5AFFF |0.837|
| (30,260) | #B0AAFF | #B5AFFF |1.511|
| body(26,264) | #202AFF | #202AFF |0.000|

Dot footprints:3×3 pixels at(21,259),(25,259),(29,259), position error0pt, pitch4pt. The native 20pt host remains; the nominal18pt peek vector aligns to pixel centers. Default peek body is calibrated #202AFF; custom theme accents remain theme-driven. The old open/closed art is unchanged. Hover dash:12×2 at(196,258), position error0pt, ΔE00 .15. §3.17 records the replacement and fit.

## Native evidence

E20 includes actual own-window mouse input, real native outline rows, saved DTO false/b, same-root relaunch with the same IDs/Today selection, second click to full collapse, re-expand/elsewhere/empty cases, and Q18 unloading an actually loaded Pinned descendant while preserving all entries and peek.

`sidebar-completion`:80/80 PASS, no focus interruptions in final run, owned-process/window cleanup PASS. `sidebar`:18/18 PASS, comparison PASS; durable_profile_storage is the existing separate-profiles-suite SKIP.

Installed native row-position animations: collapse.25s with CA default control points(.25,.1,.25,1); expand.20s with easeOut(0,0,.58,1). Presentation samples show41pt/82pt upward movement and123pt expansion. Unread-dot spring/opacity animations remain separate. E20 asserts installed duration/curve and changing row presentations, rather than only checking tokens.

Additional `app-actions`: 1 PASS plus suite INTERRUPTED after 3 exact-PID focus attempts. `window`: 5 PASS plus suite INTERRUPTED after 3 attempts. UserNotificationCenter held foreground; `active=false`, `keyWindow=0`. Both owned-process/window cleanups PASS. These are environment outcomes, not green receipts.

## Implementation choices

- Three model states shared by windows; the acting window alone chooses its selected direct tab/split. No history store.
- Nested descendant selection collapses; Right expands; Left on peek collapses; Return/Space use the common activation cycle. These are the plan's keyboard/nested guesses.
- Exact Expand All/Collapse All clear peek, and Collapse All remains enabled for a peek-only Space.
- Same-parent reorder keeps peek; copies remap to copied direct children; destructive/move/pane/sweep commands clear it with their existing undo record. Stale undo normalizes without resurrecting a child.
- Archive drops root/nested peek metadata; deletion undo retains the live original. Snapshot absent/malformed/stale values normalize safely.
- First standard window supplies both expansion and Pinned section state; little/littleArc windows are excluded. Unknown/absent map entries collapse; no standard window keeps the previous expanded default. These are import guesses selected by the plan.
- Retained row identity and content stay stable; layout compacts it directly under the folder, with no blank gap. Incremental lists/transactions only; untouched root/child lists remain cached.
- Pixel-center geometry, cached own vector paths, custom-icon precedence, and immediate Reduce Motion follow the plan's proposals and the measured capture.
- Pinned hover dash unloads loaded descendant hosts once and keeps entries/expansion; no loaded descendants is a no-op; Today has no dash. Q17/Q18 and expanded-folder hover exclusion remain user-capture questions C11, not confirmed Arc behavior.
- No collapse menu labels were invented; the current folder menu has no collapse entry.

## Original c095ca1d checks and remaining items

All commands below ran from `/Users/serge/.t3/worktrees/open/t3-85f17ccf`, sequentially with heavy-slot/on-screen locks as applicable. The parent handles the stack and the pre-PR merge/full gate. This local receipt does not claim PR or merge acceptance.

| Check / exact command | Result |
|---|---|
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render,roundtrip,commands-demo --keep-logs` | PASS: build; sidebar-render 595/595 (SW1–SW4 inherited lead-Q5 skips); features-render 293/293; commands-demo 301/301 plus FP11 6 synthetic import variants; roundtrip PASS. FP10 explicitly PENDING. |
| `SIDEBAR_BASELINE_REF=2d51f14a1207c00157edb90f51459d97b7b1096b ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-compare --keep-logs` | PASS: all 13 states, byte-identical parent/branch tables; maximum paired color drift 0 ΔE00, same position/ink. CU5 2/2. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only settings-preview,commands-dump --keep-logs` | PASS: settings-preview 37/37 and 216 rendered PNGs; command registry 192 commands, missing=0/extra=0/different=0. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | PASS, final Debug app. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion` | PASS: final rebuilt app 80/80, no focus interruptions, owned-process/window cleanup PASS. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar` | PASS: final rebuilt app 18/18, comparison PASS; 1 existing profiles-suite SKIP. One interrupted earlier attempt; bounded retry accepted all 18 checks. Cleanup PASS. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only app-actions` | INTERRUPTED: 1 PASS, no accepted full-suite pass; 3 bounded focus attempts, cleanup PASS. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only window` | INTERRUPTED: 5 PASS, no accepted full-suite pass; 3 bounded focus attempts, cleanup PASS. |

FP1–FP4 use the real public model command/UndoManager/SnapshotStore/SQLite archive flows in `openkit commands-demo`; FP11 uses the real `openkit import-arc` and `roundtrip` commands with six synthetic Arc-shaped variants. FP5–FP9 use real AppKit row views, AX actions, keyboard activation, context menus, multi-selection and the production drop path in `sidebar-render`; `features-render` covers hover eligibility/lifetime, the full folder card and unload behavior. E20 proves the App/engine path, actual native row membership and saved/reloaded DTOs. FP6 and FP10 remain separately reported below.

### Historical FP10 measured receipt and failure control (superseded gate)

The strict run uses 1,000 displayed node rows, 50 folders, 1,100 model nodes, 1,002 native rows including spacer/New Tab, scale 2, 1280×900 window, sidebar 228. Baseline one-child expanded folders and peek folders have matching visible positions. Scroll order alternates; fixture build, queued wait and animation wall time are excluded. Transition timing includes input, completed observed reconciliation/display and final forced layout. No positive performance acceptance is claimed.

| Run | Load1 start / sample | Baseline scroll p95 | Peek scroll p95 | Transition median / p95 / max | Result |
|---|---|---:|---:|---:|---|
| Strict, 400 frames each / 240 transitions | 5.82 / 6.07 | 2.02 ms | 2.39 ms | 2.38 / 3.84 / 4.88 ms | FAIL; acceptance PENDING quiet parent run |
| Fast O(n) negative, 12 frames each | 7.12 / 6.79 | 1.95 ms | 239.47 ms | Not sampled (fails earlier) | Expected exit 1; negative proof PASS |

Strict paired p95 delta +0.363250 ms versus measured clock/read overhead 0.000042 ms. Row layouts/frame 18 baseline / 18 peek. Transition input p95/max 0.24/0.65 ms; reconciliation+display 3.53/4.59 ms; final layout 0.14/0.26 ms. This sample misses the 2 ms transition gate and the unchanged relative-scroll gate; it meets the 8.33 ms absolute scroll limit. The deferral does not assert that load alone explains the miss.

The negative proof adds an actual O(n) pass laying out all native row cells on each frame for the diagnostic peek window only. It detected 1,000 layouts/frame versus 3 in the matched baseline, then returned `FP10 FAIL full-row per-frame work`. Paired p95 delta +237.525792 ms; measured clock/read overhead 0.000042 ms. It runs 2 warm-up plus 12 measured frames per side and fails on measured work even under timing noise. The process-only hook defaults off; there is no artificial sleep.

An earlier extreme-load run gave baseline/peek scroll p95 59.97/59.10 ms and transition max 175.99 ms. That old bench did not print contemporaneous load. Separate `uptime` observations were 83.59 at 12:49 and 85.22 at 12:51; these are context, not a claimed paired load sample.

### FP6 reproduction and artifact receipts

```sh
Packages/OpenKit/.build/release/sidebar-render synth --out .re/s6/final-capture-fixture --folder-peek
Packages/OpenKit/.build/release/sidebar-render render --snapshot .re/s6/final-capture-fixture --out .re/s6/peek-fit-final.png --size 1728x1084 --width 228 --scale 1 --hover pinned:0 --folder-peek
Packages/OpenKit/.build/release/sidebar-render compare --spec folder-peek --arc /Users/serge/.t3/projects/open/.re/runtime/sessions/20261026-102027-08-folder-preview/0090-102246/win-70352.png --ours .re/s6/peek-fit-final.png --out .re/s6/compare-final --scale 1 --width 228 --folder-row-top 239
```

Final FP6 rerun PASS: all three center pixels, uniform dot color, body, footprints/pitch and hover accessory meet the unchanged limits. Raw capture stays outside tracked files. The comparison reads only glyph/accessory pixels, honors the ICC profile, rejects missing samples, checks one uniform rendered dot color, and never emits personal titles or images.

Private local artifacts under `.re/s6/`: `verify-final.log`, `baseline-compare.log`, `app-build-final.log`, `fp10-sample-final.log`, `fp10-negative-final.log`, `compare-final/table.md`, `E20-folder-peek-final.png`, `e2e-completion-final.log`, `e2e-sidebar-final.log`, `results-completion-final.json`, `results-sidebar-final.json`, `verify-extra.log`, and the extra interrupted-suite JSON/logs. Parent/branch concatenated baseline-table SHA-256: `f820361b0b4baa3ad4e24b723ca807462f1b195d2f2391997815445ec77455e1`.

### Review checklist

| Area | Result / evidence |
|---|---|
| Input / persistence | PASS for added optional UUID field and direct-child validation; malformed/stale/missing UUID, expanded+peek, invalid foreign/nested/pane targets covered. No new external file format or increased allocator ceiling. Existing snapshot/import limits remain unchanged. |
| Lifetimes / callbacks | PASS: native view identity retained; undo restores before structural events; stale undo normalizes; hover cancels on state change. Test windows and exact owned process trees clean up. |
| Real event paths | PASS for new row input: E20 uses own-window `NSApp.sendEvent` down plus queued up; hidden row fails. Existing no-argument `tabs` response is unchanged. No new global hotkey or popup focus context. |
| Regression sensitivity | PASS for actual rejected FP6 color fits and FP10 O(n) negative control. Per-case break-and-revert for every new functional assertion was not performed; parent review should not infer that evidence. |
| Pixel / motion checks | PASS FP6 capture pixels, 13 identical baseline tables, native installed .20/.25 curves and changing presentations, Reduce Motion immediate path. No baseline PNG or thresholds changed. Real-window E20 PNG retained; capture comparison uses matched 1x offscreen geometry, not a claim of full native screenshot color parity. |
| Isolation / cleanup | PASS: synthetic roots/profiles, unchanged exact-owned-PID cleanup in finally, no Arc launch or desktop events; no remaining owned processes. E20 adds no dialog. Extra suite focus interruptions retained. |
| Performance | PENDING FP10 strict quiet run; limits unchanged; expected negative FAIL recorded. |
| Docs / scope | PASS: §3.17 fit, §9 row, status and follow-ups agree. No dependency or engine-tree changes; no unit tests, push or PR. |

### Changed files

- `App/Automation/AutomationController.swift`
- `App/MainMenu.swift`
- `App/WebContent/EngineWebContentHostFactory.swift`
- `Packages/OpenKit/Sources/OpenDesign/Icons.swift`
- `Packages/OpenKit/Sources/OpenDesign/Metrics.swift`
- `Packages/OpenKit/Sources/OpenDesign/Motion.swift`
- `Packages/OpenKit/Sources/OpenDesign/Palette.swift`
- `Packages/OpenKit/Sources/OpenFeatures/BrowserWindowController.swift`
- `Packages/OpenKit/Sources/OpenFeatures/HoverPreviewController.swift`
- `Packages/OpenKit/Sources/OpenImport/ArcImport.swift`
- `Packages/OpenKit/Sources/OpenModel/BrowserModel.swift`
- `Packages/OpenKit/Sources/OpenModel/LiveNodes.swift`
- `Packages/OpenKit/Sources/OpenSidebar/Controls.swift`
- `Packages/OpenKit/Sources/OpenSidebar/FolderPreviewView.swift`
- `Packages/OpenKit/Sources/OpenSidebar/HoverPreviewTracker.swift`
- `Packages/OpenKit/Sources/OpenSidebar/ModelSidebarActions.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarContext.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarIntent.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarRows.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarView.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SpacePageView.swift`
- `Packages/OpenKit/Sources/OpenStore/ArchiveStore.swift`
- `Packages/OpenKit/Sources/OpenStore/SnapshotDTOs.swift`
- `Packages/OpenKit/Sources/features-render/CompletionChecks.swift`
- `Packages/OpenKit/Sources/openkit/CLI.swift`
- `Packages/OpenKit/Sources/openkit/CommandsDemo.swift`
- `Packages/OpenKit/Sources/openkit/FolderPeekDemo.swift`
- `Packages/OpenKit/Sources/sidebar-render/Bench.swift`
- `Packages/OpenKit/Sources/sidebar-render/Checks.swift`
- `Packages/OpenKit/Sources/sidebar-render/Compare.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekChecks.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekCompare.swift`
- `Packages/OpenKit/Sources/sidebar-render/PreviewChecks.swift`
- `Packages/OpenKit/Sources/sidebar-render/RenderCLI.swift`
- `docs/followups.md`
- `docs/plans/sidebar-completion.md`
- `docs/plans/sidebar-s6-receipt.md`
- `docs/status.md`
- `tools/e2e/engine_e2e.py`
- `tools/verification/check.py`
