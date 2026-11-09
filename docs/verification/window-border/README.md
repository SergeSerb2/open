# Window border (rim) receipt — 2026-11-09, M5 (AW2726DM, 1x)

The "black border" is the WindowServer window rim. Its style follows the NSWindow's own appearance: a
darkAqua window gets a 1 px near-black line outside the frame, an aqua window only a faint shadow edge.
Open's window followed the macOS appearance, so in macOS Dark a light Space showed a black line.
Fix: the window appearance follows the focused Space's light/dark mode; content, sheets and Open's own
child panels keep the system appearance (private windows: dark). Foreign child windows (ViewBridge,
SafariPlatformSupport, Chromium) are never touched.

Method: real-screen captures (`screencapture -R` with a 20 pt desktop margin; window-only captures omit
the rim), macOS in Dark, the test profile's Space themed light through the app (no system defaults).
Before = main 518471aa Debug; after = 69ac88e1 Debug. Pixels: the outer line (first pixel outside the
frame) against the backdrop next to it.

| Case | Left before (outer / backdrop) | Left after | Top before | Top after | After checks |
|---|---|---|---|---|---|
| light | (5, 5, 4) / (179, 161, 134) | (143, 130, 117) / (188, 170, 142) | (1, 1, 1) / (52, 55, 52) | (6, 25, 37) / (7, 32, 47) | liveEditorUpdatesRim, explicitEditorStaysDark |
| split | (5, 5, 4) / (179, 161, 134) | (143, 130, 117) / (188, 170, 142) | (1, 1, 1) / (52, 55, 52) | (6, 25, 37) / (7, 32, 47) | all PASS |
| default | (5, 5, 4) / (179, 161, 134) | (5, 5, 4) / (179, 161, 134) | (1, 1, 1) / (52, 55, 52) | (0, 1, 2) / (7, 31, 47) | all PASS |
| dark | (5, 5, 4) / (179, 161, 134) | (5, 5, 4) / (179, 161, 134) | (1, 1, 1) / (52, 55, 52) | (0, 1, 2) / (7, 31, 47) | all PASS |
| private | (5, 5, 4) / (179, 161, 134) | (5, 5, 4) / (179, 161, 134) | (1, 1, 1) / (52, 55, 52) | (0, 1, 2) / (7, 31, 47) | all PASS |
| littleopen | (5, 5, 4) / (179, 161, 134) | (143, 130, 117) / (188, 170, 142) | (1, 1, 1) / (52, 55, 52) | (6, 25, 37) / (7, 32, 47) | all PASS |
| fullscreen | n/a | n/a | n/a | n/a | all PASS |

Light, Split View and Little Open (light Space): the black line is gone. Default, dark Space and private
windows keep the dark rim on purpose: the window is dark, as in Arc. Full screen draws no rim.

Crops (top-left corner, 6x): `light-before-topleft.png` / `light-after-topleft.png`,
`split-*`, `private-*` (private is unchanged by design).

Not covered: the theme editor's Light/Dark mode buttons through `editor-act`. Its control frames place
the mode buttons inside the color pad, so the synthetic click hits nothing (`previews` stays 0). This
also happened before the change. A theme change updating the rim is covered by `profileSpaceUpdatesRim`
and `rimAfterAppChange`. Followup filed.
