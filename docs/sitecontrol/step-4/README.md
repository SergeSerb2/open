# Step 4: shared pad and native Boost editor

All page data, preferences, Boosts, and backdrops in these renders are synthetic. No capture pixels or personal data are committed. The editor is always light. The old wheel, strip, dark variants, and duplicate pad drawing/input implementation are removed.

The 28 full contact sheets cover 14 states at 1x and 2x. [SHA256SUMS](SHA256SUMS) binds each image. Six [detail renders](detail/) show only our native editor/popover; their [receipts](detail/SHA256SUMS) are also verified by `sitecontrol-render check`. The comparison command rendered those details on the synthetic host; it used the private captures only for numeric comparison.

The shared `OpenDesign/ColorPad.swift` owns dots, knobs, gradients, and input. The theme editor is a thin state/law wrapper; its existing verification targets and baselines are unchanged. The Boost adapter owns the two-knob color law, ring, guide, legacy note, and AX axes.

## Verification

- [Native flows](checks.txt): 103/103 PASS. Real BoostStore, matcher, planner, fresh-store durability, undo groups, legacy byte-identical restore, saved IP paths, native sheets, and keyboard events.
- [Frame, gradient, and AX probes](probes.txt): 82/82 PASS at 1x/2x.
- [Registered native-app focus suite](native-key-checks.txt): 10/10 PASS; no `isKeyWindow` override. This temporary harness app is launched and cleaned under the machine-wide on-screen lock.
- [Bench](bench.txt): six budgets PASS; CPU p95 and wall diagnostics are named separately. Full drag-frame display work is included.
- The full consolidated gate is recorded in the PR body on the pushed head.
- S11–S13 and the real-app snapshot compare are **deferred to Step 3 per plan §12/§11**. Zap mode and code mode remain deferred to P7/Steps 6–7.

## Capture comparisons

The original limits remain position ≤1 pt and non-text core/fill ΔE00 ≤2. Remaining rows below are FAIL, not hidden or relabeled PASS. The lead's final token ruling requires publishing these residuals. [Stability and fit values](comparisons/stability-and-fits.json) record ImageCms conversion from the embedded AW2726DM profile to Display P3. Ring/font 0030–0031 and badge 0018–0019 regions are byte-stable after conversion (maximum channel difference 0).

| Child-window capture | State | Passed | Remaining |
|---|---|---:|---|
| S2 10/0018 | [editor-first-run](comparisons/editor-first-run.md) | 22/22 | None |
| S2 10/0030 | [editor-no-color](comparisons/editor-no-color.md) | 55/60 | Name chevron, Undo, color glyph 1, color glyph 2, color glyph 3 |
| S2 10/0039 | [editor-dragging](comparisons/editor-dragging.md) | 4/7 | guide circle 45 degrees, guide circle 135 degrees, guide circle 225 degrees |
| S2 10/0041 | [editor-color](comparisons/editor-color.md) | 54/60 | Name chevron, Undo, knob 1 gradient bottom, color glyph 1, color glyph 2, color glyph 3 |
| S2 10/0042 | [editor-advanced](comparisons/editor-advanced.md) | 11/25 | advanced arrow row 2, advanced arrow row 3, advanced arrow row 4, advanced arrow row 5, advanced arrow row 6, advanced arrow row 7, advanced arrow row 8, advanced arrow row 9, advanced arrow row 10, advanced arrow row 11, advanced arrow row 12, Contrast, Brightness, Original Saturation |
| S2 10/0046 | [editor-font-selected](comparisons/editor-font-selected.md) | 2/2 | None |

The popover's 0042 PNG includes the editor backing image (250×588); its child is selected at y258 with the recorded 250×232 window frame. Arrow/label rows and the three guide-circle samples still have the reported ink/color residuals. No threshold was widened. The font boxes, grey stops, first-run card, and selected font pass.

## Renders

| State | Light 1x | Light 2x |
|---|---|---|
| editor-advanced | [1x](editor-advanced-light@1x.png) | [2x](editor-advanced-light@2x.png) |
| editor-color | [1x](editor-color-light@1x.png) | [2x](editor-color-light@2x.png) |
| editor-delete-alert | [1x](editor-delete-alert-light@1x.png) | [2x](editor-delete-alert-light@2x.png) |
| editor-dragging | [1x](editor-dragging-light@1x.png) | [2x](editor-dragging-light@2x.png) |
| editor-first-run | [1x](editor-first-run-light@1x.png) | [2x](editor-first-run-light@2x.png) |
| editor-font-selected | [1x](editor-font-selected-light@1x.png) | [2x](editor-font-selected-light@2x.png) |
| editor-global-off | [1x](editor-global-off-light@1x.png) | [2x](editor-global-off-light@2x.png) |
| editor-legacy | [1x](editor-legacy-light@1x.png) | [2x](editor-legacy-light@2x.png) |
| editor-name-menu | [1x](editor-name-menu-light@1x.png) | [2x](editor-name-menu-light@2x.png) |
| editor-neutral-page | [1x](editor-neutral-page-light@1x.png) | [2x](editor-neutral-page-light@2x.png) |
| editor-no-color | [1x](editor-no-color-light@1x.png) | [2x](editor-no-color-light@2x.png) |
| editor-not-active | [1x](editor-not-active-light@1x.png) | [2x](editor-not-active-light@2x.png) |
| editor-scope-menu | [1x](editor-scope-menu-light@1x.png) | [2x](editor-scope-menu-light@2x.png) |
| editor-zap-count | [1x](editor-zap-count-light@1x.png) | [2x](editor-zap-count-light@2x.png) |
