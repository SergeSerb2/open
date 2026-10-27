# Cold-open instruction comparison

The real `sitecontrol-render cold-measure --thread-instructions` path constructs a fresh controller and native view tree, sends the anchor click through `window.sendEvent`, lays out, and includes the first native display and transaction flush. It uses 20 Boosts and 12 Settings rows at 2x. Each process runs five warmups and 30 measured opens. Five independent A/B pairs alternate before/after on the same machine. No controls are pooled or removed from the accessibility tree.

Before product sources: `3654f548`. After product sources: `0643c94`. Both executables use the identical instruction harness from `d5e1928`. Only the two `OpenSiteControl/SiteControlView.swift` and `SiteControlRows.swift` product files differ between the builds. The source files were restored before the after build. Both builds passed through `heavy.sh`. Binary hashes are in `instructions-summary.json`; binaries and raw Instruments traces are not committed.

The counter reads the current main thread with `thread_selfcounts(THSC_CPI=1)`, dynamically resolved from libSystem. The 16-byte instructions/cycles ABI is checked. This optional SPI exists only in the harness executable. Missing or invalid counters fail this diagnostic command; it never substitutes process totals, CPU time, or wall time.

| Pair | Before median instructions | After median instructions | Before CPU p95 (ms) | After CPU p95 (ms) | Load1 before / after |
|---|---|---|---|---|---|
| 1 | 125,376,057 | 95,076,269 | 10.209 | 8.983 | 20.12 / 20.12 |
| 2 | 125,480,554 | 94,896,697 | 12.466 | 9.850 | 20.12 / 20.12 |
| 3 | 125,485,667 | 95,035,968 | 13.304 | 9.932 | 20.12 / 20.12 |
| 4 | 125,439,846 | 94,988,707 | 12.494 | 10.693 | 19.15 / 19.15 |
| 5 | 125,788,131 | 95,078,338 | 15.919 | 10.929 | 19.15 / 19.15 |

Median of the five run medians: **125,480,554 → 95,035,968 instructions**, a **24.26% reduction**. The range of run medians divided by their median is **0.328% before / 0.191% after**. Individual sample min/max values and all 30 samples per run remain in the numeric logs.

Changes: cache the shared panel path; avoid duplicate initial row application; construct row drawing layers only when first exposed by the scroll clip; skip clipped display work; give Boost circles only their glyph and focus layers. Rows remain in the native hierarchy. A real keyboard/scroll flow also checks newly exposed Settings title pixels.

These A/B logs predate the lead’s instruction-gate ruling below. Every after CPU p95 above exceeds the 8 ms product target under load 19–20. The pre-pause 11 ms result also failed the former CPU gate. No wall-clock limit was added.


## Time Profiler attribution

The top three non-wrapper inclusive stacks are below. Button construction is nested inside section construction; these values must not be added. The old profile covered 105 opens and the new profile 35. Raw traces remain local in `/tmp`; only numeric own-code summaries are committed. Absolute CPU sample weights differ with machine load and profiling overhead. The instruction A/B above is the evidence of work reduction.

| Inclusive stack | Before sampled CPU (ms), 105 opens | After sampled CPU (ms), 35 opens |
|---|---|---|
| `prepareAnimationAnchor` (first native layout/display) | 650 | 108 |
| `rebuildSections` (row construction and attachment) | 594 | 130 |
| `SiteControlButton.init` (native control construction, nested) | 465 | 101 |

The older profile's load1 was 14.57. The final profiling invocation uses a time-limited `Time Profiler` recording and exits successfully; its counter output is not part of the five A/B pairs. The intermediate row-lazy trace failed to finalize and export; it is not evidence for this comparison.


## Current acceptance method (lead ruling at 21:21)

The A/B CPU-gate statement above records the state when that experiment ran.
The lead then replaced the hard CPU-ms regression gate with main-thread
instructions: M5 Pro / 26B5112a accepted 95,035,968; ceiling 104,539,565
(`ceil(accepted × 1.10)`). Unknown machines report INFO. The absolute 8 ms product
target remains for the lead's quiet-machine check. The lighter skeleton run is
informational. See `docs/verification.md` and the negative-proof log below.

Quiet-machine command from the repo root, after a release build:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh Packages/OpenKit/.build/release/sitecontrol-render bench --fixture cold
```


## Gate failure proof

An intentional second native section/row construction pass was inserted inside
the measured span, before `afterPresent`:

```swift
let redundant = SiteControlController(source: stage.source,actions: stage.source)
redundant.view.panel.apply(stage.source.value!)
withExtendedLifetime(redundant) {}
```

`apply` performs another O(n) pass through the 20 Boost / 12 Settings rows. The
real CLI then **FAILED** at 140,209,910 median main-thread instructions against
the unchanged 104,539,565 ceiling (load1 15.20). After restoring the source and
rebuilding, the same command **PASSED** at 94,997,086 (load1 14.55). The temporary
code is absent from the committed source. Both builds ran through `heavy.sh`.
See `gate-negative.txt` and `gate-restored.txt`.

For the missing-baseline flow, the copied release resource was temporarily given
an empty machine list, then restored in a `finally` block. The real CLI reported
94,888,857 instructions, the missing-machine reason, and **INFO** with no PASS.
See `gate-unknown-machine.txt`. The source fixture was unchanged. The initial
accepted run passed at 95,372,047; see `gate-accepted.txt`.

Final full-gate result after the main/theme Step 9 merge: 102,283,082 median instructions, below104,539,565. CPU p95 13.891 ms, wall15.428 ms, load1 37.60. See `../checks.txt` and `../verify-all.txt`. These loaded timings do not establish quiet-machine <8 ms acceptance.
