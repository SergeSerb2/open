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

Tool-reported differences (confirmed as measurement artifacts by design review r1):

- R3: back card 1's visible-strip right edge differs by 2 pt (Arc x=212,
  Open x=210 at the scan band). Cause: the 1 px ring samples the front card fill inside the rounded
  7 pt strip, placing nearly equal corner pixels on opposite sides of the
  threshold. Independent per-row reference crossings agree within 1 px. The 10 pt
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

## Design review r1 response

| Finding | Status | Change and evidence |
|---|---|---|
| F1: height-change fly-in | Fixed | Anchor-correct starts for pager/container; new checks compare animation starts with the on-screen position and sample the pager at +16 ms. They fail on `85fd361`. |
| F2: interrupted collapse snaps backward | Fixed | Capture presentation position, size, opacity and shadow path before model changes for container, pager, cards, child views and title fades. Stale title-fade completions are ignored. One- and three-card re-entry checks fail on `85fd361` and pass after the fix. |
| F3: title/drawer overlap controls | Fixed | Pin row frames using the reviewed formulas; the clipped content edge reveals them. Presentation samples during expand, collapse, re-entry and drawer opening show no control-row overlap. |
| F4: plate radius | Fixed | `MiniPlayerMetrics.buttonPlateRadius = 5`, continuous, applied only to mini-player buttons. Spec/design now label the value as an E3/E7 fit. |
| F5: default tooltip fill | Inherited from main #113 | The separate token task owns the measured `#0A0D4F` fill. The main merge brings it here; no mini-player-specific token fix. |
| F6: spring response | Fixed, still a guess | Mini-player stack response is 0.2 s, damping 1, based on the measured sidebar spring. O9 still needs a mini-player motion capture. |
| F7: native play/pause coverage | Added | Reduce Motion OFF: check the shipping `NSImageView` path, live AppKit ink, and native-event pause/play replacement. Actual App-window comparison remains with Step 6 integration. |

[Design motion regression proof and historical receipts](evidence/design-r1/README.md).

## Code review r1 fixes and verification

| Finding | Status | Change and evidence |
|---|---|---|
| C1: Reduce Motion blink | Fixed | One 0.1 s container CATransition cross-fades the subtree. Pager and child frames apply immediately. Hover in/out and same-height fourth-source checks reject opacity-from-zero and verify full pager/container opacity at +16 ms. |
| C2: width drag trails and re-animates | Fixed | Container/card flags allow animation only for media changes. Width drags cancel existing media animations and apply geometry with implicit actions disabled. 400 → 228 pt drags check every step for no keys and exact model/presentation widths, in both motion modes and expanded/collapsed states. |
| C3: missing assertions | Added | MC6 asserts exit collapse, MC8 asserts collapsed 33 pt rest, MC10 asserts Peek opacity restoration. Expanded add/remove checks assert visible title rows and C=145 → 74. MC15 asserts one root cross-fade and full presentation opacity. |
| C4: hidden sidebar keeps stale expansion | Fixed | Hide cancels collapse work and resets an unforced stack to collapsed without animation. Hide/show within the 0.3 s delay checks C=55, 33 pt cards, no pending collapse, and clean layers. |
| C5: removal under real pointer | Manual check pending | No tracking-area behavior change. §8.5 asks the user to expand two cards, click the top title or Close, move over the tab list, and confirm collapse. The agent cannot confirm this without driving the real pointer. |
| C6: stale flags and dead hitTest branch | Fixed | §8.2 uses expanded\|title:N and points to §13.8.4; the card returns super.hitTest after its visibility/retiring guard. |

`tools/verify-all.sh`: **20/20 PASS**, no skips or retries, exit 0, through
`heavy.sh` in a detached session after merging main `ebea09f`.
`sidebar-render check`: **558 passed, 0 failed**, including **49 motion** and
**30 lifecycle checks**. MC8 idle CPU: **0.013%** over 2 s, collapsed 33 pt,
no idle animation keys or collapse work, one store expiry item.
The identical lifecycle harness fails frozen `3504776` with **18 failures**
(12 PASS) and passes the fixes **30/30**. Existing motion remains **49/49**.

MC9: **PASS**, 12 interleaved pairs against pinned main `ebea09f`, with
`/tmp/open-onscreen-e2e.lock` held across the full series. Paired median delta
**-0.105 ms**, 20%-trimmed mean **-0.135 ms** (limit +0.3 ms).
Baseline/head median p95: 3.100/2.885 ms.
Collapsed 3-card report-only: 3.24 ms p95.

Tooltip F5 was owned by the separate token task. Its fix merged in main #113
and is inherited here; no mini-player-specific tooltip color change was made.
All 62 PNGs were regenerated with synthetic titles and this final renderer.
The §7 comparison tables retain the R3/R4 measurement artifacts accepted by
design review; no geometry token changed. C5 needs the manual §8.5 pointer check.

[Code review regression proof](evidence/code-r1/README.md),
[complete verification table](evidence/verify-summary.md),
[full sidebar checks](evidence/sidebar-check.log), [MC9](evidence/mc9.json),
[62-image synthetic manifest](evidence/render-manifest.json).

Renders, full verification and MC9 use the same final renderer SHA-256.
Prior-head receipts remain in `evidence/code-r1/pre-code-*` and
`evidence/design-r1/`; initial A/A receipts belong to the original binary.
No AX-title PNG or Arc pixels were committed or pushed.

## Latest main merge verification

Merged main `9e3473c` with a merge commit. The three conflicts were
`MediaControlsView.swift`, `Checks.swift` and `MediaChecks.swift`. Keep the
33/66/99 pt redesign, motion/lifecycle fixes, single-card hover and drawer prune;
retain main’s scheduled-collapse delay receipt, condition-based waits and UUID
preferences suite. `cancelCollapse()` clears both the work item and its delay.
No engine source or key routing was changed by the resolution.

`tools/verify-all.sh`: **20/20 PASS**, no skips or retries, through `heavy.sh`
in a detached session. `sidebar-render check`: **559 PASS, 0 FAIL**.
Focused motion: **49/49**; lifecycle: **30/30**. Two concurrent full sidebar
runs with separate temporary directories and UUID preferences suites each pass
**559/559**. Invalid state/hover CLI cases each exit 1 without writing a PNG.
MC8 idle CPU: **0.023%**, collapsed 33 pt, no idle animation keys or collapse work.

MC9: **PASS**, 12 interleaved pairs against pinned main `9e3473c`, with
`/tmp/open-onscreen-e2e.lock` held across the whole series, after all builds and
focused checks finished. Paired median delta **-0.705 ms**;
20%-trimmed mean **-0.520 ms** (limit +0.3 ms).
Baseline/head median p95: 4.035/3.465 ms.
Three-card report-only p95: 4.11 ms.

All 62 synthetic PNGs were regenerated (62/62 byte-identical to the
previous receipt). R1–R4 numeric comparisons remain unchanged. R3/R4 are the
previously accepted measurement artifacts. No Arc pixels or real-title PNGs
were committed. The renderer hash matches MC9, the render manifest and full
verification.

C5’s real-pointer check and Step 6 real-window snapshots remain pending;
§8.5, `docs/followups.md` and the PR checklist state that scope explicitly.
Historical negative-control receipts describe their original frozen harnesses;
this refresh retains their defect gates and adapts the delay assertions to main.

[Current merge/checklist receipts](evidence/main-refresh/README.md).
