# Sidebar S6 local handoff

Base: 2d51f14a1207c00157edb90f51459d97b7b1096b (A2 over A1).
Branch: t3/sidebar-s6-folder-peek. Local only; no push or PR.

## FP10 follow-up after c095ca1d (2026-10-28)

Parent's c095ca1d run at load1 7.5: transition median/p95/max 1.84/2.87/5.27 ms; reconciliation+display median 1.74 ms; baseline/peek scroll p95 2.26/2.31 ms; native layouts/frame 18/18.

Profiling used completed-callback phase clocks, native work/draw counters, and `/usr/bin/sample` against the exact bench PID. The first split, before optimization, at load1 17.70 measured reconciliation+display median 1.87 ms: walk/native edits 0.44 ms and forced layout/display 1.41 ms. It visited 1,002 cached items and configured 21 row views per transition. A longer 2,400-transition diagnostic sample after targeting the observation showed Core Animation commit / AppKit backing-layer drawing as the remaining dominant cost (`fp10-transitions.sample`: `SpacePageView.syncExpansion` → `CA::Transaction::flush` → `NSViewBackingLayer display`). Actual title/favicon draws were about two per transition; the trace did not prove painting of unrelated node rows.

Changes retained:

- Each exposed folder owns a weak Observation loop, cancelled when its cache drops. A folder property change starts reconciliation at that folder, rather than scanning the 1,000-row root and every loaded folder. New/hidden Manager folders still reconcile through the existing structural/visibility paths.
- A subset removal/insertion uses one native `IndexSet` edit. A collapsed item's children are supplied once by native expansion. No reloadData, whole-outline reloadItem, height invalidation, or all-row view lookup was added.
- New child rows configure through `didAdd`; only the folder row needs an explicit state refresh. Unrelated row fills and the header are untouched. The measured case visits about two items and configures two row views, with two cell layouts.
- A tab's title and favicon share its cell backing context. Buttons and badges retain separate layers. The native-image-view, bitmap-cache, binding-cache, and transparent-document experiments did not establish a useful reduction and were removed.
- Bench output now reports phase timing, real work, draw counts, and thread CPU time as a diagnostic. It checks the native row count after every measured transition, so a no-op/broken expansion cannot satisfy the timing gate.

The parent's gate definition replaces the earlier max-time and clock-overhead guesses: **transition wall p95 ≤2.00 ms**, up to three fresh matched attempts; maximum native row layouts/frame peek ≤ baseline; scroll p95 ≤8.33 ms and ≤baseline p95 ×1.10 +0.05 ms in each paired, alternating run. Max remains diagnostic. The parent chose the time allowance for shared-machine jitter while retaining the deterministic work detector. CPU time does not change the verdict. All attempts and load1 values are printed. A real 3 ms CPU busy wait inside the transition callback is the second negative control, scoped to its diagnostic window and disabled in the App.

Final-source strict command: the single strict command below, three attempts, all **FAIL** on transition p95. The <1 ms median target is **not met**. CPU diagnostic medians 1.70/1.83/1.80 ms are close to wall time; this is not explained away as scheduling noise. Further rendering/commit optimization is required before FP10 can be accepted.

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

Functional/model/import/render/native verification for c095ca1d is preserved below. The follow-up above supersedes its FP10 gate interpretation. Performance acceptance remains **PENDING** until the revised gate passes; no image baseline or visual threshold changed. The parent handles pre-PR acceptance.

Strict command (from this worktree, after the release CLI build):

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
