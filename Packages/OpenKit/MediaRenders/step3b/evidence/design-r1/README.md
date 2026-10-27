# Design review r1 regression evidence

The same composed offscreen motion harness was compiled against frozen production
source `85fd361` and the fixes. The frozen production files were checked byte for
byte against that commit. Both copies used identical `MediaMotionChecks.swift`
and `Checks.swift` files; the harness SHA is in the receipt.

- Old production: **13 PASS, 36 FAIL**. F1/F2 start and interruption gates fail.
- Fixed production: **49 PASS, 0 FAIL** in the focused native flow.
- Final merged build: **525 PASS, 0 FAIL** in the complete sidebar flow, which
  includes the same motion checks; full verification is 20/20 PASS.
- One-card and three-card flows cover hover, real delayed collapse, re-entry
  50 ms into collapse, +16 ms presentation continuity, drawer opening, clipped
  row separation and animation cleanup.
- F7 runs with Reduce Motion OFF and uses the live native image/ink path.

```sh
Packages/OpenKit/.build/release/sidebar-render check --media-motion-only
```

[Old failures](old-motion-check.log), [fixed focused flow](fixed-motion-check.log),
[provenance and hashes](negative-control.json), [full final sidebar flow](../sidebar-check.log).

| Finding | Status | Change and evidence |
|---|---|---|
| F1: height-change fly-in | Fixed | Anchor-correct starts for pager/container; new checks compare animation starts with the on-screen position and sample the pager at +16 ms. They fail on `85fd361`. |
| F2: interrupted collapse snaps backward | Fixed | Capture presentation position, size, opacity and shadow path before model changes for container, pager, cards, child views and title fades. Stale title-fade completions are ignored. One- and three-card re-entry checks fail on `85fd361` and pass after the fix. |
| F3: title/drawer overlap controls | Fixed | Pin row frames using the reviewed formulas; the clipped content edge reveals them. Presentation samples during expand, collapse, re-entry and drawer opening show no control-row overlap. |
| F4: plate radius | Fixed | `MiniPlayerMetrics.buttonPlateRadius = 5`, continuous, applied only to mini-player buttons. Spec/design now label the value as an E3/E7 fit. |
| F5: default tooltip fill | Deferred to assigned token-fix task | No tooltip color change here. Open remains `#1C1B22`; Arc is `#0A0D4F` (E3/S2 04/0021, review ΔE00 19.5). |
| F6: spring response | Fixed, still a guess | Mini-player stack response is 0.2 s, damping 1, based on the measured sidebar spring. O9 still needs a mini-player motion capture. |
| F7: native play/pause coverage | Added | Reduce Motion OFF: check the shipping `NSImageView` path, live AppKit ink, and native-event pause/play replacement. Actual App-window comparison remains with Step 6 integration. |
