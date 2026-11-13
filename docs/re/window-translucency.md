# Window translucency capture, 2026-11-13

Arc 1.172.2 (90755) shows wallpaper through an active browser window. An inactive browser window becomes opaque while another window of the same application is main. This capture does not establish behavior after application deactivation.

The fixture uses an original synthetic page and three original analytical wallpapers. No Arc asset is used in Open. C14-T records default and custom themes in Light and Dark appearance, each over dark, light, and patterned colorful wallpapers, with both main-window states. All 24 frames have an actual 1280×800 point browser window at global top-origin position (20,60). The M1 display is 3024×1964 pixels at 2× with its embedded Color LCD ICC profile. Geometry, appearance checkmark, stored theme, and the main-window state are checked separately from the image.

Evidence: C3 `C14-T-handoff.json`, `C14-T-frames.md`, and `m1/material-analysis/final-v2/{manifest.json,result/material-summary.json}` under the private ignored `.re/capture/s14/` evidence tree. Source runs are `m1/arc/v21/110-material-default-light`, `v22/111-material-default-dark`, `v29/112-material-custom-light`, and `v30/113-material-custom-dark`. The stored custom `windowTheme` is unchanged between Light and Dark. Its single color is extended sRGB (0.9489999413, 0.3690000176, 0.4199999869), intensity 0.8, noise 0, `translucencyStyle: light`, and `isVibrant: true`. These are stored fixture facts, not inferred compositor parameters.

## Qualified image regions

The clear comparison rectangles are global top-origin points:

| Region | x, y, width, height |
|---|---|
| Lower sidebar | 240, 796, 80, 12 |
| Top frame | 500, 63, 100, 4 |
| Left frame | 23, 790, 4, 12 |
| 128-point wallpaper pattern | 40, 728, 300, 48 |

Each source region is checked against an unoccluded backdrop capture in the same appearance. The upper sidebar and step edge have desktop widgets behind them and are rejected. A persistent top-right notification banner lies outside these regions. Raw full-screen frames remain private; the lossless sidebar crops exclude the banner. All color values below use the original ICC profile to convert to sRGB. Per-matrix wallpaper restoration passes an independent fresh-process check of the saved URL and nonempty options. The earlier v17 baseline had empty options; exact options before that session cannot be proved.

## Measured output

The table gives the lower-sidebar median sRGB values, in 0–255 units. The inactive value is identical across the three wallpaper captures for each theme and appearance.

| Theme / appearance | Active, dark wallpaper | Active, light wallpaper | Inactive, all wallpapers | Colorful 128-point pattern transfer |
|---|---|---|---|---|
| Default / Light | 199,193,206 | 242,234,245 | 247,238,249 | 0.20939 |
| Default / Dark | 22,14,32 | 51,44,64 | 19,10,29 | 0.01896 |
| Custom / Light | 217,122,133 | 244,150,158 | 247,153,161 | 0.11718 |
| Custom / Dark | 181,88,99 | 227,133,140 | 233,137,144 | 0.15968 |

Transfer is observed linear RGB sine-amplitude norm divided by input amplitude at the same location. It measures the combined blur, tint, and saturation response. It is not a layer opacity. The 128-point signal has SNR 12.0–13.4. Fewer than three frequencies are identifiable and the step source is occluded, so an independent Gaussian radius is unresolved.

A model with one wallpaper gain and a constant RGB tint in linear sRGB is rejected for active Default-Light, Custom-Light, and Custom-Dark (RMS 0.0278–0.0415). Active Default-Dark is approximate at gain 0.03209 and RMS 0.00331. These results do not establish an independent tint alpha or saturation value. Matching the real system material must use its rendered colors and spatial response across the wallpapers.

## Open implementation and validation status

Real browser windows use a native `NSVisualEffectView` with `.behindWindow` blending below the theme field. The theme retains its fitted coverage. The provisional materials are `.sidebar` with Aqua for a light backdrop and `.underWindowBackground` with Dark Aqua for a dark backdrop. Existing window activation events select the material state. Non-vibrant themes remain opaque. The window server performs the blur; no periodic sampling or new display loop is used.

The Custom-Light real-window comparison is pending. Material selection and the broader C14-T fit are provisional until that comparison passes ΔE00 ≤ 2 for the qualified sidebar and frame regions. System material selection is not a claim about Arc's internal blur radius.

Paired M1 Release idle CPU samples before and after the prepared implementation are 0.1477% / 0.1375% for an empty window and 0.2129% / 0.2955% for ten verified loaded static tabs. Each is one 60-second process CPU sample after a 90-second settle and two load1 readings ≤ 3.5, ten seconds apart. These samples pass the 0.5% budget; they do not establish a causal speed change. The field rebuild counter remains unchanged and no display update is pending at rest. An informational inventory of other system CPU was not retained. Evidence: private `.re/d2-translucency/{cpu-readout.md,cpu-qualification.json,receipts/m1-idle-v3.tar}` in the D2 worktree, with the empty-window samples in v1/v2 receipts.
