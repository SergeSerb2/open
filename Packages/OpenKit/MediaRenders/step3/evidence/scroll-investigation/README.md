# MC9 scroll investigation: one paused mini-player card

## Question

A 12-pair MC9 run against merge base `15e261e` measured head with one paused
card slower than main without a card: paired p95 median +0.43 ms, 20%-trimmed
mean +0.47 ms ([run 1](mc9-12pair-run1-fail.json)). Does the paused card do
work on each scroll frame?

## Answer

No. The paused card adds no work to a scroll frame. Head with the card executes
about 1.6% fewer instructions per scroll step than main without a card. The
MC9 delta is wall-clock noise on a loaded machine (load average 9–15, partly
from VMs). An A/A control with the same binary and the same arguments on both
sides measures a larger "regression" than run 1. Two more MC9 runs of the same
head binary pass; the one on a quieter machine measures +0.01 ms.

Because there is no per-frame cost, there is no code fix. Product code is unchanged.

## Evidence

1. **No media view runs during scroll.** A scratch build counts calls in every
   media override (`MediaControlsView.layout/updateTrackingAreas`,
   `MiniPlayerCardView.layout/sync/updateTrackingAreas`,
   `MarqueeLabel.layout/refreshAnimation`, `PlateButton.layout/updateLayer/updateTrackingAreas`,
   `SidebarView.layout`) and every `draw(_:)` in OpenSidebar. All media counters
   stay at zero for the 338 scroll steps. This is also true when the window is
   ordered in and the run loop turns after every step, so deferred AppKit work,
   observation hops, KVO, and notifications get a chance to run.
   [Receipt](scroll-counters.txt), [scratch patch](scroll-counters.patch) (not applied).
2. **The rows draw the same.** With and without the card: 1212 `TextLabel`
   draws and 1277 `FaviconView` draws. The card run has one more
   `FolderIconView` draw because it has one more step (338 vs 337).
3. **Fewer instructions with the card.** `proc_pid_rusage` instruction counts
   per scroll step, same tool on every build ([tools](tools/)):

   | Comparison | Instructions/step | Paired median Δ | Higher |
   |---|---|---|---|
   | `15e261e` main, no card | 14.75 M | — | — |
   | #92 head, no card | 14.70 M | −0.24% | 4/12 |
   | #92 head, paused card | 14.53 M | −1.74% | 0/12 |
   | same #92 binary, card vs no card | | −1.6% | 1/16 |
   | A/A control (same binary, same args) | | +0.33% | 14/20 |

   Sources: [base/head/card](base-head-card-work.json), [same binary](same-binary-work.json),
   [A/A](aa-control-work.json). The card takes 76 pt from the list viewport, so
   each step lays out fewer visible rows.
4. **No extra waiting.** Off-CPU time per step (wall minus main-thread CPU) is
   0.2–0.3 ms with and without the card ([same binary](same-binary-work.json)).
   More than 90% of a step is main-thread CPU.
5. **Time Profiler.** Scroll-only traces (3 interleaved pairs, 12 scroll passes
   each) have no samples in media code during scroll. All `MediaControlsView`,
   `MiniPlayerCardView` and `MarqueeLabel` samples are in setup. Row drawing in
   the CA commit (`TextLabel.draw`, `FaviconView.draw`) dominates both runs.
   Traces stayed local (too large to commit).
6. **The wall-clock delta is noise.**

   | Run | Pairs | p95 paired median Δ | p95 trimmed Δ | Slower |
   |---|---|---|---|---|
   | MC9 run 1, base vs head+card | 12 | +0.43 ms | +0.47 ms | 9/12 |
   | Same #92 binary, card vs no card (1st) | 20 | +0.57 ms | +0.36 ms | 12/20 |
   | Same #92 binary, card vs no card (2nd) | 16 | +0.14 ms | −0.00 ms | 9/16 |
   | Base / head / head+card, 3 arms | 12 | −0.12 ms | −0.01 ms | 5/12 |
   | **A/A control, no card on either side** | 20 | **+0.49 ms** | **+0.52 ms** | 14/20 |
   | MC9 run 2, same head binary as run 1 | 12 | −0.51 ms | −0.31 ms | 5/12 |
   | MC9 run 3, same binaries, on-screen lock per run, load ≈ 5 | 12 | +0.01 ms | +0.00 ms | 7/12 |

   Original gate: run 2 median Δ −0.38 ms, mean Δ −0.27 ms; run 3 median Δ
   +0.01 ms, mean Δ −0.01 ms. Both PASS ([run 2](mc9-12pair-run2-pass.json),
   [run 3](mc9-12pair-run3-locked-pass.json)). All three runs have the same head
   binary SHA-256 (`01c09b93…`); runs 2 and 3 share one `15e261e` baseline binary.
   Run 3 holds `/tmp/open-onscreen-e2e.lock` for each bench run, so no other
   on-screen suite overlaps a measurement. Its p95 values span 1.25–1.75 ms;
   runs 1 and 2 span 1.5–5.2 ms.

## Title row and marquee

The always-visible title row and its marquee do not cause the delta. At rest the
marquee has no animation (paused source), and its layout and refresh counters
stay at zero during scroll. Its `CATextLayer`s do not redraw. A smaller 33 pt
rest card would not change scroll cost.

## Reproduce

```sh
# Scratch worktrees only: the instrumentation is not part of the product.
git worktree add /tmp/perf-base 15e261e && git worktree add /tmp/perf-head <head>
python3 tools/instrument-scroll-work.py /tmp/perf-base   # same patch on each version
python3 tools/instrument-scroll-work.py /tmp/perf-head
swift build --package-path /tmp/perf-base/Packages/OpenKit -c release --product sidebar-render -j 6
swift build --package-path /tmp/perf-head/Packages/OpenKit -c release --product sidebar-render -j 6
B=/tmp/perf-base/Packages/OpenKit/.build/release/sidebar-render
H=/tmp/perf-head/Packages/OpenKit/.build/release/sidebar-render
python3 tools/arms.py --rounds 12 --out /tmp/arms --arm "base=$B||" --arm "head=$H||" --arm "headcard=$H|--media-card|"
python3 tools/pairs.py --bin $H --pairs 16 --out /tmp/card            # card vs no card
python3 tools/pairs.py --bin $H --pairs 20 --b-args "" --out /tmp/aa  # A/A control
# MC9 logic extended to 12 pairs; expects a head checkout with a release build at /tmp/mc9-92.
python3 tools/mc9-12pair.py --baseline-ref 15e261e --out /tmp/mc9-run   # run 2
python3 tools/mc9-12pair.py --baseline-ref 15e261e --baseline-bin <run 2 baseline binary> \
    --lock /tmp/open-onscreen-e2e.lock --out /tmp/mc9-run3                # run 3
```
