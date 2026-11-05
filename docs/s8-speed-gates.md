# Section 8 speed gates

The new gate observes the real `BrowserWindowController`, `ToastCenter` with `SystemToastClock`, and `WebContentContainer.showHistorySwipe` in the existing offscreen harness. The web host remains the existing fake host. The temporary native observer is loaded only into `features-render`; it is never linked into Open. Product behavior and visuals are unchanged.

## Acceptance scope

Per the lead's final user instruction on November 5, this PR requires negative proofs and before/after speed numbers, then a main merge and one build. Full `verify-all`, targeted `features-render` regression, `commandbar`/`app-actions` e2e suites, page/media/sleep suites, and display-dependent origin/main comparisons are deferred to Section 8's single regression on final main. No baseline or threshold was regenerated or changed. Earlier diagnostic display runs are not part of this PR's sign-off.

The final Release App build passed after merging `18c14f33`. The later `bd092d33` merge contains docs only. Both A and B App distributions use framework SHA-256 `f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939`. All before/after values below were collected today, after the 09:00 cutoff, with the built-in display as main: main display ID 1, 1728×1117 logical, 3456×2234 mode pixels, backing scale 2. The previous day's comparison and e949 engine receipts are superseded and excluded.

A is `f401ef3a`, the first parent of the toast merge #153. B's CLI measurements are from the branch merged with `03a0d5cb` (`91345e2f`); the measured OpenSidebar/OpenCommandBar/OpenSuggest and renderer sources are unchanged by the subsequent main merges. The App cold-open measurement uses the final built App. Builds use `heavy.sh`. Timing batches hold `/tmp/open-m5-quiet.lock`; App measurements also hold `/tmp/open-onscreen-e2e.lock` and reap only owned processes.

## Before/after numbers

### Sidebar scroll

Command: `.build/release/sidebar-render bench --rows 1000`, Release, default 2x, no extra warmup environment. Twenty alternating A/B pairs were already complete when the final instruction reduced the minimum to three; no further timing batch was run.

Median of the per-run scroll p95 values: **A 5.605 ms → B 4.680 ms (-16.50%)**. This is faster, but **outside the literal ±10% unchanged band**. It is not reported as a parity PASS. The lead accepted the faster result as non-regressing on November 5 at 11:00. No samples were dropped or thresholds widened. Load columns are the 1/5/15-minute averages before → after each command.

| Pair | A p95 ms | A load | B p95 ms | B load |
|---|---:|---|---:|---|
| 1 | 5.07 | 8.50/7.50/6.98 → 8.54/7.52/6.99 | 6.37 | 8.54/7.52/6.99 → 8.54/7.52/6.99 |
| 2 | 6.30 | 8.54/7.52/6.99 → 8.74/7.58/7.02 | 6.18 | 8.74/7.58/7.02 → 8.74/7.58/7.02 |
| 3 | 6.70 | 8.74/7.58/7.02 → 9.64/7.79/7.09 | 6.31 | 9.64/7.79/7.09 → 9.64/7.79/7.09 |
| 4 | 6.06 | 9.64/7.79/7.09 → 9.80/7.89/7.14 | 5.63 | 9.80/7.89/7.14 → 9.80/7.89/7.14 |
| 5 | 6.80 | 9.80/7.89/7.14 → 10.29/8.02/7.19 | 6.18 | 10.29/8.02/7.19 → 10.29/8.02/7.19 |
| 6 | 5.67 | 10.29/8.02/7.19 → 10.83/8.17/7.25 | 5.12 | 10.83/8.17/7.25 → 10.83/8.17/7.25 |
| 7 | 4.76 | 10.83/8.17/7.25 → 10.60/8.17/7.25 | 3.50 | 10.60/8.17/7.25 → 10.60/8.17/7.25 |
| 8 | 3.36 | 10.60/8.17/7.25 → 10.60/8.17/7.25 | 3.22 | 10.60/8.17/7.25 → 10.08/8.10/7.23 |
| 9 | 5.84 | 10.08/8.10/7.23 → 10.08/8.10/7.23 | 4.24 | 10.08/8.10/7.23 → 10.39/8.20/7.27 |
| 10 | 5.62 | 10.39/8.20/7.27 → 10.39/8.20/7.27 | 5.95 | 10.39/8.20/7.27 → 10.84/8.33/7.32 |
| 11 | 4.87 | 10.84/8.33/7.32 → 10.84/8.33/7.32 | 5.47 | 10.84/8.33/7.32 → 10.93/8.39/7.35 |
| 12 | 5.98 | 10.93/8.39/7.35 → 10.93/8.39/7.35 | 3.68 | 10.93/8.39/7.35 → 10.93/8.39/7.35 |
| 13 | 4.62 | 10.93/8.39/7.35 → 11.02/8.45/7.38 | 2.72 | 11.02/8.45/7.38 → 11.02/8.45/7.38 |
| 14 | 5.94 | 11.02/8.45/7.38 → 11.82/8.65/7.46 | 7.20 | 11.82/8.65/7.46 → 11.82/8.65/7.46 |
| 15 | 5.59 | 11.82/8.65/7.46 → 11.67/8.68/7.47 | 6.10 | 11.67/8.68/7.47 → 11.67/8.68/7.47 |
| 16 | 5.78 | 11.67/8.68/7.47 → 11.67/8.68/7.47 | 4.03 | 11.67/8.68/7.47 → 11.30/8.65/7.47 |
| 17 | 2.60 | 11.30/8.65/7.47 → 11.30/8.65/7.47 | 2.34 | 11.30/8.65/7.47 → 11.30/8.65/7.47 |
| 18 | 2.30 | 11.30/8.65/7.47 → 10.71/8.57/7.45 | 2.92 | 10.71/8.57/7.45 → 10.71/8.57/7.45 |
| 19 | 3.37 | 10.71/8.57/7.45 → 10.71/8.57/7.45 | 3.39 | 10.71/8.57/7.45 → 10.33/8.53/7.44 |
| 20 | 3.82 | 10.33/8.53/7.44 → 10.33/8.53/7.44 | 2.83 | 10.33/8.53/7.44 → 10.33/8.53/7.44 |

### Section 2 keystroke and completion gates

The existing limits and workloads are unchanged: 5,000 tabs, 100,000 history URLs, 2x, 218 measured keystrokes; CPU p95 <8 ms, completion added p95 ≤0.3 ms, at most one layout pass.

| Metric | A | A load | B | B load |
|---|---|---|---|---|
| Keystroke CPU p95 | 8.25 ms FAIL | 10.33/8.53/7.44 → 9.27/8.48/7.47 | 3.91 ms PASS | 9.27/8.48/7.47 → 8.59/8.44/7.50 |
| Completion added p95 | +0.248 ms PASS | 10.33/8.53/7.44 → 9.27/8.48/7.47 | +0.040 ms PASS | 9.27/8.48/7.47 → 8.59/8.44/7.50 |
| Panel layout passes, max | 1 PASS | 10.33/8.53/7.44 → 9.27/8.48/7.47 | 1 PASS | 9.27/8.48/7.47 → 8.59/8.44/7.50 |
| commandbar-render check | 131/132 (keystroke budget FAIL) | 10.33/8.53/7.44 → 9.27/8.48/7.47 | 132/132 PASS | 9.27/8.48/7.47 → 8.59/8.44/7.50 |
| suggest-check | 47/47 PASS | 8.59/8.44/7.50 → 8.02/8.33/7.47 | 47/47 PASS | 8.02/8.33/7.47 → 8.73/8.47/7.53 |

The baseline CPU-budget failure is retained as measured; the current result passes. No retry was used to turn either outcome into a PASS. This benchmark measures main-thread work through rows drawn, not physical frame presentation.

### Cold Cmd+T

| Revision | Cold first results ms | Load at gate (1/5/15) | Cleanup |
|---|---:|---|---|
| A | 4.729 | 10.03/6.77/6.71 | PASS |
| B | 4.922 | 10.27/6.88/6.75 | PASS |

Both values pass the existing ≤50 ms limit. These are two isolated cold App launches, not an e2e suite. They reuse the existing Section 2 window key route and scope: showCommandBar entry to first snapshot applied, excluding preceding key routing, socket transport and frame presentation. There were no focus interruptions and both owned-process/window cleanup checks passed.

## Idle gate and negative proofs

Each two-second sample requires zero feature-owned registered CF run-loop timers, uncancelled dispatch timer sources (including sources without a deadline), running CVDisplayLink, registered CADisplayLink/NSView display links, CA animation keys, draw/layout/layer-display/invalidation calls, and new GCD work submissions. It watches the actual native view/layer trees and actual scheduler APIs. A native canary proves the observer works and sees teardown. Missing instrumentation or tracking overflow fails closed (fixed storage: 512 entries). The gate samples never-shown/dismissed toasts and never-started/completed/cancelled swipes, in both Reduce Motion modes. It makes no whole-App CPU or physical-gesture/frame-presentation claim.

Completed break-and-revert proofs inserted faults into the actual ToastOverlayView and SwipeIndicatorView, built and ran the existing flow, then restored the original sources. The six resource-channel proofs were recorded on November 4; the hardened GCD pure-work proof and final clean 19/19 command ran today on the built-in display. These are count/teardown proofs, independent of CEF, and are not reused as before/after timings. The toast/swipe source blobs remain byte-identical on final main: `c3bee7dbe07c8654f04a27b2e477ad0e009ff1ac` (ToastOverlayView) and `6f0053fb0b3e7c2114007c1c9d82ed1d6ef7e4c6` (SwipeIndicatorView).

| Injected fault | Exit | Idle FAIL lines |
|---|---:|---:|
| timer | 1 | 10 |
| dispatch | 1 | 10 |
| displaylink | 1 | 10 |
| cvlink | 1 | 10 |
| animation | 1 | 8 |
| redraw | 1 | 8 |
| workloop | 1 | 10 |

Representative unmodified FAIL lines (one toast and one swipe per fault):

```text
FAIL S8 idle toast dismissed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[1, 0, 0, 0]→[1, 0, 0, 0]; CA=0→0; 2.004 s; load 10.29/10.56/9.64
FAIL S8 idle swipe completed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[2, 0, 0, 0]→[2, 0, 0, 0]; CA=0→0; 2.128 s; load 9.87/10.47/9.61
FAIL S8 idle toast dismissed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 1, 0, 0]→[0, 1, 0, 0]; CA=0→0; 2.116 s; load 8.48/9.93/9.46
FAIL S8 idle swipe completed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 2, 0, 0]→[0, 2, 0, 0]; CA=0→0; 2.133 s; load 8.28/9.86/9.44
FAIL S8 idle toast dismissed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 2]→[0, 0, 0, 2]; CA=0→0; 2.002 s; load 6.88/9.19/9.21
FAIL S8 idle swipe completed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 4]→[0, 0, 0, 4]; CA=0→0; 2.132 s; load 6.57/9.08/9.18
FAIL S8 idle toast dismissed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 1, 0]→[0, 0, 1, 0]; CA=0→0; 2.125 s; load 7.61/8.88/9.09
FAIL S8 idle swipe completed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 2, 0]→[0, 0, 2, 0]; CA=0→0; 2.019 s; load 8.12/8.97/9.12
FAIL S8 idle toast dismissed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 0]→[0, 0, 0, 0]; CA=1→1; 2.013 s; load 8.42/8.91/9.08
FAIL S8 idle swipe completed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 0]→[0, 0, 0, 0]; CA=1→1; 2.097 s; load 8.95/9.01/9.12
FAIL S8 idle toast dismissed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 37, 74, 74148, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 0]→[0, 0, 0, 0]; CA=0→0; 2.011 s; load 7.07/8.48/8.92
FAIL S8 idle swipe completed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 76, 38, 114304, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 0]→[0, 0, 0, 0]; CA=0→0; 2.032 s; load 7.22/8.49/8.92
FAIL S8 idle toast dismissed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 35, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 0]→[0, 0, 0, 0]; CA=0→0; 2.009 s; load 6.03/6.87/6.98
FAIL S8 idle swipe completed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 70, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 0]→[0, 0, 0, 0]; CA=0→0; 2.003 s; load 5.87/6.82/6.96
```

The pure O(n) work-loop proof walks 1,000 rows and requeues every 50 ms without touching UI. Its failure has zero timers, links, animations and drawing events; only the real scheduling counter moves. The animation and redraw resource proofs fail eight samples because the two never-started swipe samples have no allocated indicator. Both post-exit paths and both motion modes fail.

After reverting all faults:

```text
PASS S8 idle toast dismissed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 0]→[0, 0, 0, 0]; CA=0→0; 2.086 s; load 6.16/6.69/6.90
PASS S8 idle swipe completed; reduced=false: events [draw,layout,display,invalidate,schedule,overflow]=[0, 0, 0, 0, 0, 0]; live [Timer,DispatchTimer,CVLink,CALink]=[0, 0, 0, 0]→[0, 0, 0, 0]; CA=0→0; 2.018 s; load 6.30/6.71/6.91
features-render idle check: 19 passed, 0 failed
```

Invalid `features-render check` options also fail with exit 1 instead of silently running the general checks. The final App build succeeded; regression suites are explicitly deferred as described above.
