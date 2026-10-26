# Step 3b: capture session 2 mini player

Own synthetic renders from the real composed sidebar, media store, and fake
WebMediaHost. All rendering is offscreen through `sidebar-render`. No Arc pixels,
private titles, or external assets are committed. Light/themed fills, drawer,
recording controls and motion retain the guesses in media plan §13.7.

The replacement removes the 68 pt card, hover fill, masked back cards, stack edge,
Close width animation and marquee, with their old checks and render fixtures.
Step 3's historical verification receipts remain in `../step3/evidence/`.

## Reproduce

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 swift build --package-path Packages/OpenKit -c release -j 6
Packages/OpenKit/.build/release/sidebar-render check
python3 Packages/OpenKit/MediaRenders/step3b/render-scenes.py
python3 Packages/OpenKit/MediaRenders/step3b/compare-bench.py --baseline-ref f3c9cc5 --out .re/step3b-mc9
```

Start long commands in a detached session and write logs. The benchmark script
holds `/tmp/open-onscreen-e2e.lock` for every run. `--series-lock` holds it for
the entire series when `--baseline-bin` is supplied. It uses 12 interleaved pairs and
gates the paired median and 20%-trimmed mean p95 deltas at ≤ 0.3 ms. `--aa` runs 20 pairs with
the same head binary without a card on both sides. `--baseline-bin PATH` reuses
an immutable baseline; hashes before and after detect a changed binary. One
collapsed stack run is report-only.

## Arc comparison

`compare-media` uses sRGB conversion through the embedded ICC profile, a plane fit
to the 1 px ring, 50% ink boxes, ≥85% core colors, and CIEDE2000 (design §7).
Geometry is in points. Tables hold element names and numbers only. Local
capture-derived renders and Arc/Open/diff images stay under `.re/step3b/`.
The four committed 1x images use synthetic titles; local compares use the AX title
in memory. R1 uses E3's title and R3 uses E7's title because collapsed cards have no
AXStaticText. E3's PNG has an extra trailing row; compare-media drops only that
row and preserves the top-left origin. Masks exclude fill/background samples
and the diff pane only; ink boxes and glyph/title core colors are still measured.
R2 masks the tooltip capsule plus shadow at `198,1018,30,66`, leaving Volume
measurable. Favicon slots and the bottom bar are masked in the diff. Shadow
samples below y 1034 are exempt from the bottom-bar mask. Local Arc/Open panes
remain intact and private.

| Run/frame | Worst edge error (pt), target ≤1 | Worst ΔE00, target ≤2 | Worst shadow error (pp), target ≤1.5 |
|---|---|---|---|
| [R1, E2](comparison/R1.md) | 0 | 0.56 | 0.91 |
| [R2, E3](comparison/R2.md) | 0 | 0.73 | 0.93 |
| [R3, E6](comparison/R3.md) | 2 | 0.56 | 0.91 |
| [R4, E7](comparison/R4.md) | 2 | 0.86 | 0.93 |

Named misses (the §13.8.6 pass rule permits quantified, explained misses):

- R3: back card 1's visible-strip right edge differs by 2 pt (Arc x=212,
  Open x=210 at the scan band). Cause (inference): this is a contrast-threshold box on the rounded,
  translucent 7 pt strip, over slightly different background pixels. The 10 pt
  continuous corner remains the E2/E3 fit; native MC6 confirms the exact 202 pt
  card frame. The other visible strip edge is within 1 pt. Occluded bottom edges
  cannot be measured from pixels; MC6 checks all complete card frames.
- R4: the middle title's bottom ink edge differs by 2 pt (Arc y=919, Open y=921).
  The strings differ: Arc's title has no descender there. Its top edge matches;
  its left edge differs by 1 pt. The specified 13 Regular font and baseline 22
  remain unchanged. All other glyph/title edges match exactly.

Every card fill matches exactly (ΔE00 0). Back-strip colors differ by 0.14/0.29.
Shadow samples are below the front card at 0.5/2.5/4.5 pt against the same scene
without media. All shadow differences are below 1.5 percentage points.

## Render matrix (2x)

| Scene | Light 228 | Dark 228 | Light 500 | Dark 500 |
|---|---|---|---|---|
| rest | [PNG](rest-light-228.png) | [PNG](rest-dark-228.png) | [PNG](rest-light-500.png) | [PNG](rest-dark-500.png) |
| paused | [PNG](paused-light-228.png) | [PNG](paused-dark-228.png) | [PNG](paused-light-500.png) | [PNG](paused-dark-500.png) |
| muted | [PNG](muted-light-228.png) | [PNG](muted-dark-228.png) | [PNG](muted-light-500.png) | [PNG](muted-dark-500.png) |
| disabled-tracks | [PNG](disabled-tracks-light-228.png) | [PNG](disabled-tracks-dark-228.png) | [PNG](disabled-tracks-light-500.png) | [PNG](disabled-tracks-dark-500.png) |
| audio-expanded | [PNG](audio-expanded-light-228.png) | [PNG](audio-expanded-dark-228.png) | [PNG](audio-expanded-light-500.png) | [PNG](audio-expanded-dark-500.png) |
| video-expanded | [PNG](video-expanded-light-228.png) | [PNG](video-expanded-dark-228.png) | [PNG](video-expanded-light-500.png) | [PNG](video-expanded-dark-500.png) |
| button-pressed | [PNG](button-pressed-light-228.png) | [PNG](button-pressed-dark-228.png) | [PNG](button-pressed-light-500.png) | [PNG](button-pressed-dark-500.png) |
| tooltip | [PNG](tooltip-light-228.png) | [PNG](tooltip-dark-228.png) | [PNG](tooltip-light-500.png) | [PNG](tooltip-dark-500.png) |
| stack-collapsed | [PNG](stack-collapsed-light-228.png) | [PNG](stack-collapsed-dark-228.png) | [PNG](stack-collapsed-light-500.png) | [PNG](stack-collapsed-dark-500.png) |
| stack-expanded | [PNG](stack-expanded-light-228.png) | [PNG](stack-expanded-dark-228.png) | [PNG](stack-expanded-light-500.png) | [PNG](stack-expanded-dark-500.png) |
| drawer | [PNG](drawer-light-228.png) | [PNG](drawer-dark-228.png) | [PNG](drawer-light-500.png) | [PNG](drawer-dark-500.png) |
| recording | [PNG](recording-light-228.png) | [PNG](recording-dark-228.png) | [PNG](recording-light-500.png) | [PNG](recording-dark-500.png) |
| increase-contrast | [PNG](increase-contrast-light-228.png) | [PNG](increase-contrast-dark-228.png) | [PNG](increase-contrast-light-500.png) | [PNG](increase-contrast-dark-500.png) |

[Red light](red-light-228.png), [red dark](red-dark-228.png),
[164 rest light](rest-light-164.png), [164 rest dark](rest-dark-164.png),
[164 expanded light](expanded-light-164.png), [164 expanded dark](expanded-dark-164.png).

1x: [R1 rest](R-rest-dark-228.png), [R2 expanded](R-video-expanded-dark-228.png),
[R3 stack](R-stack-dark-228.png), [R4 expanded stack](R-stack-expanded-dark-228.png).

62 PNGs. The renderer now preserves `allowsGroupOpacity` when cloning layers;
this is required for the translucent back cards to composite as one image.

## Spec review r1

F1–F11 from the Muse review are reflected in media plan §13 and this code:

- Every committed PNG is rendered with synthetic text. AX-title output is rejected
  outside `.re/`; no real-title PNG was committed or pushed.
- The shadow color is opaque black. `MiniPlayerMetrics.shadowOpacity` (0.21) is
  the single alpha source; MC12 checks color alpha 1 and the path after resizing.
- `measure()` sets expansion before reading card heights. Collapse clears drawer IDs.
- The public `titleState` receipt reports the real Core Text line, tail ellipsis,
  width, baseline and font size. Only mini-player titles install the optional receipt.
- MC5 retains fading-card hit refusal, source replacement in one turn, and drawer
  prune/undo restore. Slot rounding uses the actual window backing scale.
- PP-16 Close-width and track-symbol evidence wording is reconciled with the capture.

## Verification

`sidebar-render check`: **476 passed, 0 failed**. MC8: **0.011% CPU** over
2 seconds, no animation keys, no pending collapse, and one store expiry item.
The actual ellipsis/baseline hook and retiring/replacement/drawer-prune flows pass.
The privacy-output rejection, removed-hover-flag rejection and expired-source CLI
flows all pass. The expired render reserves zero media height.

| Scroll measurement | Pairs | Paired median Δ (ms) | 20%-trimmed mean Δ (ms) | Result |
|---|---|---|---|---|
| [Pre-review, contended, per-run lock](evidence/mc9-pre-review-contended.json) | 12 | +0.390 | +0.402 | FAIL retained |
| [A/A, same final binary/args, whole-series lock](evidence/aa-control.json) | 20 | +0.070 | +0.121 | control PASS |
| [Final MC9, main f3c9cc5 vs paused card, whole-series lock](evidence/mc9.json) | 12 | −0.005 | −0.085 | PASS |

The final baseline/head median p95 values are 2.035/1.980 ms. The three-card stack
run is report-only: 2.22 ms p95. The first run's failure is preserved; the media layout was not tuned to make the gate pass. All series-lock measurements
hold the shared on-screen lock across every warmup, pair and stack run.

[Sidebar check receipt](evidence/sidebar-check.log), [CLI flow receipt](evidence/cli-cases.json),
[62-image synthetic render manifest](evidence/render-manifest.json). A/A, final MC9
and the renders share the same head renderer SHA-256.

`origin/main` was merged at `f3c9cc5` (after `6778fc2`). Main's new theme/traffic-light
work is in both the final baseline and the feature binary. The earlier
[pre-merge passing gate](evidence/mc9-pre-merge.json) and [A/A control](evidence/aa-pre-merge.json)
remain available. Renders and locked benchmarks were refreshed after the merge.

`tools/verify-all.sh`: **20/20 PASS**, no skips or retries, exit 0, after the
main merges. Run through `heavy.sh` in a detached session. The head renderer
hash is unchanged by full verification.

[Complete verification table](evidence/verify-summary.md).
