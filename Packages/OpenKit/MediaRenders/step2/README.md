# Step 2 row media renders and verification

These are Open's own synthetic row renders. No Arc assets or user data are included.
Mini-player views and MC1–MC10 remain in Step 3, per the lead's 2026-10-26
00:34 America/Vancouver clarification.

Each image is a 2× crop of a real sidebar row, with 12 pt of surrounding space.
The full scene uses a 1280×900 pt canvas (1300 pt high for the deep-folder row).
`--media` uses the Reduce Motion glyph renderer to preserve the role tint in the
layer-cloning render harness. The normal animated path is exercised separately
by `sidebar-render check`.

```sh
swift build --package-path Packages/OpenKit -c release -j 6
Packages/OpenKit/.build/release/sidebar-render synth --out /tmp/open-media-scene
Packages/OpenKit/.build/release/sidebar-render render --snapshot /tmp/open-media-scene --out /tmp/row.png --width 228 --appearance dark --scale 2 --media today:0=audible:recording --media-theme default --crop-media
Packages/OpenKit/.build/release/sidebar-render check
python3 Packages/OpenKit/MediaRenders/step2/compare-bench.py --baseline-ref ab9ad37670da3ee733172ae5eccc4fac9879d131 --out /tmp/open-media-bench-review
```

The comparison builds a pinned baseline from `git archive`, copies only the
identical deterministic `Bench.swift` fixture instrumentation to it, and runs
the real 1,000-row command. Both builds receive a warm-up. Six measured pairs
alternate baseline/head and head/baseline order. Plain and mixed variants are
separate; mixed rows are audible, muted and capturing in thirds. The receipt
includes every run, means, medians, baseline revision and binary SHA-256 hashes.
Earlier comparisons and the rejected observation-loop experiment are retained
in `evidence/`; they are not replaced by a success claim.

## Native animation evidence

The lead's 00:59 clarification required proving the native effect absent
before using a fallback. `evidence/native-unwrapped-check.log` records the
unwrapped system replace call changing the image but producing no animation
key in the real, ordered-behind, offscreen AppKit window (146 passed, 1 failed).
It also proves that no image-view position/bounds animation ran and that the
image frame remained at x=2 in both states. Its source hash is recorded beside it.

Production keeps the unwrapped system replace call. Only when no native symbol
animation is found does it add a finite 0.25 s cross-fade. Its actual CA key is
`transition`; `openMediaFallback` metadata distinguishes it from a native effect.
The passing check observes the image change, the actual animation, no root
position/bounds animation, and no remaining keys afterward. Reduce Motion and
hidden-state changes remain static.

## Matrix

| State | Light 228 | Dark 228 | Light 500 | Dark 500 |
|---|---|---|---|---|
| audible | [PNG](audible-light-228.png) | [PNG](audible-dark-228.png) | [PNG](audible-light-500.png) | [PNG](audible-dark-500.png) |
| muted | [PNG](muted-light-228.png) | [PNG](muted-dark-228.png) | [PNG](muted-light-500.png) | [PNG](muted-dark-500.png) |
| recording | [PNG](recording-light-228.png) | [PNG](recording-dark-228.png) | [PNG](recording-light-500.png) | [PNG](recording-dark-500.png) |
| both | [PNG](both-light-228.png) | [PNG](both-dark-228.png) | [PNG](both-light-500.png) | [PNG](both-dark-500.png) |
| audible-muted | [PNG](audible-muted-light-228.png) | [PNG](audible-muted-dark-228.png) | [PNG](audible-muted-light-500.png) | [PNG](audible-muted-dark-500.png) |
| hovered | [PNG](hovered-light-228.png) | [PNG](hovered-dark-228.png) | [PNG](hovered-light-500.png) | [PNG](hovered-dark-500.png) |
| deep-hovered | [PNG](deep-hovered-light-228.png) | [PNG](deep-hovered-dark-228.png) | [PNG](deep-hovered-light-500.png) | [PNG](deep-hovered-dark-500.png) |
| red-theme | [PNG](red-theme-light-228.png) | [PNG](red-theme-dark-228.png) | [PNG](red-theme-light-500.png) | [PNG](red-theme-dark-500.png) |

## Final comparison after the archive merge

Baseline: main `ab9ad37670da3ee733172ae5eccc4fac9879d131`.
Six measured interleaved pairs per variant; all commands preserve row/model parity.

| Variant | Baseline median p95 | Head median p95 | Baseline mean p95 | Head mean p95 | Highest head p95 |
|---|---:|---:|---:|---:|---:|
| Plain | 2.855 ms | 2.000 ms | 2.670 ms | 2.093 ms | 2.760 ms |
| Mixed | 2.320 ms | 3.190 ms | 2.587 ms | 3.105 ms | 4.140 ms |

The lead's 2026-10-26 01:44 America/Vancouver decision requires no regression
for unchanged-looking rows and an absolute 4.2 ms p95 budget for mixed rows.
Both gates pass. Mixed cost is +0.518 ms mean and +0.870 ms median p95.
The rejected shape-layer experiment is retained as evidence; the final code
keeps the simpler static dot drawing. Final binary hashes are in the receipt.
