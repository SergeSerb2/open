# Open design system and sidebar (M2)

Status: implemented. Package: [OpenKit](../Packages/OpenKit/Package.swift), targets `OpenDesign`, `OpenSidebar`, and the dev executable `sidebar-render`.
No third-party dependencies. No unit tests (AGENTS.md rule 6): the sidebar is checked end to end through real views in an offscreen window, and compared pixel by pixel with Arc's captures.

Sources of the measured values: [runtime-observations.md](re/runtime-observations.md) (idle window), [interaction-states.md](re/interaction-states.md) (states, motion), [design-tokens.md](re/design-tokens.md) (asset catalog tokens). Frame IDs (F0013, A0222) refer to the capture session indexed in `.re/runtime/sessions/index-20261024.json`. This file adds the values that the comparison loop fitted. Every fitted value names its evidence. Marks: **measured**, **fitted** (chosen to minimize the comparison error), **guess**.

## 1. Modules

| Target | Role |
|---|---|
| `OpenDesign` | Tokens (colors, metrics, type, motion), Space theme parsing and rendering (`SpaceThemeStyle`, `ThemeField`, `ThemeBackgroundView`), our own grain, the web panel chrome layer, the icon map. AppKit only. |
| `OpenSidebar` | The sidebar column: toolbar row, URL field, favorites grid, Space pager with header and tab list, bottom bar, menus, tooltips, drag and drop. Bound to `OpenModel`. Reports every action as a `SidebarIntent`. |
| `sidebar-render` | Dev tool: offscreen PNG renders with forced states, comparison with Arc captures, end-to-end checks, a 1,000-row bench, a synthetic snapshot. |

## 2. Tokens (`OpenDesign`)

### 2.1 Colors

Every catalog color from `design-tokens.md` §1 is a `DesignColor` (light and dark `RGBA`, color space kept per token): `Core`, `SidebarColors`, `CommandBarColors`, `GrayScale.gray` / `.grayA` / `.indigo`, `MenuColors`. `BrandBlue` is `Core.brandBlue` (Display P3 `#3139FB`).

"Light" and "dark" follow the content appearance of the Space, not the macOS setting (§3.4). The sidebar paints through role tokens in `SidebarRole`. Each role points to a catalog token where one fits within ΔE 2, else to a fitted value.

| Role | Light | Dark | Evidence |
|---|---|---|---|
| Tab title | theme `light.title` | theme `dark.title`; default theme `#DDDEFF` | F0001 core pixels equal the stored `#320E00`; F0079 core `#D9DAFA` corrected for anti-aliasing |
| Split-row titles | theme title | default theme white 0.80 (`ForegroundPrimary`) | F0079 |
| Space title | black 0.45 `SidebarForegroundDarker` | white 0.55 (fitted) | F0001 ΔE 0.40 (0.48 / `GrayA10` gave 1.8); F0079 |
| "New Tab" label | black 0.30 `SidebarForeground` | white 0.45 | F0001, F0079 |
| URL placeholder | black 0.30 `SidebarForeground` | white 0.30 (fitted) | F0001, F0079 |
| URL host (page loaded) | black 0.60 `CommandBarPlaceholderText` | same token | F0015 ΔE 0.35 |
| "New Tab" plus | black 0.48 `GrayA10` | white 0.51 (fitted) | F0001, F0079 |
| Magnifier | black 0.40 (fitted) | guess | F0001 core black ≈ 0.38 |
| Toolbar glyph, enabled (and the sidebar toggle always) | black 0.56 `GrayA11` | `GrayA11` | F0001 toggle core ≈ 0.56; Arc's AX says the toggle is disabled, but it draws enabled |
| Toolbar glyph, disabled; every chrome glyph in an inactive window | black 0.22 `GrayA8` | `GrayA8` | F0001 back/forward; inactive capture `arc-window-5245.png` |
| Bottom plus | `GrayA11`; inactive 0.30 | white 0.62 (fitted) | F0001, F0079, inactive capture |
| Home (our glyph) | black 0.52; inactive 0.26 (fitted for our shape) | guess | F0001, inactive capture |
| URL field and tile fill | `SidebarItemBackground` (`#0E0F10` 0.05 P3) | `#FAFBFF` 0.10 | ΔE ≤ 0.61 on 7 elements |
| Row hover, header hover, New Tab hover | `SidebarItemBackground` | same | F0013 ΔE 0.45, F0031 0.49, F0079 0.81 |
| Button hover plate | black 0.07 `GrayA4` | `GrayA4` | F0024 ΔE 0.38, F0027 0.72 |
| Selected row, selected tile, "New Tab" during Cmd+T | theme `light.background`, opaque | white 0.20 `TabCellBackgroundCurrent` | F0015 ΔE 1.05, F0016 1.15, F0063 2.00, F0066 2.03 |
| Selected shadow | black 0.20 `TabCellShadowSelected`, radius 1.5, 1 pt down | none (the dark token is clear) | F0014 edge profile |
| Pinned/Today divider | black 0.15 `SidebarSeparator` | white 0.15 | F0066 ΔE 0.33 |
| "Clear" | `SidebarForeground`; `SidebarForegroundDarker` on hover | same tokens | F0041 |
| Row close and unload glyphs | black 0.56 `GrayA11` | `GrayA11` | F0013 ΔE 1.39, F0015 1.23 |
| Switcher, other Spaces | emoji in grayscale (Rec. 709 luma) at opacity 0.55 | same | F0001 two-channel fit gives 0.48 at full coverage; 0.55 matches the darkest pixels at 12 pt |
| Tooltip | fill theme `light.title`; text theme `light.background` (guess); keycaps text at 18 % (guess) | same | F0021–F0033 fill exact |
| Split cells in a selected split row | black 0.07 `TabCellChildBackground` (guess: no light capture) | white 0.07 | F0081 ΔE 1.34 / 1.39 |
| Peek badge plate | `TabCellChildBackground` | same | F0090 ΔE 0.76 (F0101 white ≈ 0.075) |
| Source row while its Peek shows | `SidebarItemBackground` (black 0.05; guess) | white 0.10 | F0090 ΔE 0.09 |
| Toolbar row / bottom bar under a Peek | opacity 0.43 / 0.52 (fitted) | same | F0090 glyphs ΔE ≤ 1.98 |

### 2.2 Metrics (`Metrics.swift`)

All values are points at sidebar width 228, top-left origin. Widths that scale use `W` (sidebar width).

| Area | Value | Mark |
|---|---|---|
| Traffic lights | 12 pt circles centered in `[12/35/58, 16, 16, 16]` (system drawn) | measured |
| Toolbar buttons | 32×32 at y 7; toggle x 77; back / forward / reload at x `W − 106 / W − 72 / W − 38` (pitch 34, reload 6 pt from the edge); hover plate = button frame, radius 6 | measured |
| URL field | `[8, 46, W − 16, 36]`, radius 10 continuous; magnifier `[14, 52, 24, 24]`; placeholder origin x 42, baseline y 69; host origin x 21; copy and Site Control `[W − 70 / W − 42, 49, 30, 30]` | measured, text origin fitted |
| Favorites | inset 8, gaps 8, tile height 47, radius 10; columns = balanced rows of at most 4 (6 → 3 columns at width 228 and 500) | measured; rule for other counts guess |
| Space header | 36 pt band; icon frame `[13, 5, 26, 26]`; title origin x 44, baseline 23; hover fill `[8, 0, W − 16, 36]`, chevron in place of the icon, "…" at the right | measured, text origin fitted |
| Tab list | 3 pt spacer row, then 41 pt rows; favicon `[17, y + 11, 18, 18]` (16 ink); title origin x 44, baseline y + 25; fill `[8 + indent, y + 2, W − 16 − indent, 36]`, radius 10 continuous | measured, baseline fitted (ink bottom at y + 24) |
| Close / unload | `[W − 39, y + 7, 26, 26]`; the title then ends at its left edge | measured |
| Folders | 16 pt indent per level; folder title 14 Semibold | measured |
| Split row | cells of `(W − 16 − indent − 4) / n`; icon at cell + 0, title at cell + 28, divider 10 pt left of the next cell | measured at depth 1 (icons x 33 / 129) |
| Selected split row | card = the selected fill; pane cells `[12 + indent + i·pitch, y + 6, pitch − 4, 28]`, radius 8; no divider | measured F0081 (`[12, y+6, 100, 28]`, `[116, y+6, 100, 28]`) |
| Peek badge | plate `[W − 38, y + 8, 24, 24]`, radius 6; favicon 16 pt ink centered; title ends at `W − 39` | measured F0090, F0101 |
| "/" mark | 2 × 14.5 pt stroke, 0.14 rad, centered 3 pt left of the title origin at y + 19.5; title + 2 pt | measured F0090, F0101 |
| Row title truncation | 1 pt kept free at the right (2 pt with the inset) | fitted: F0001, F0081, F0090 truncation points |
| Divider row | 17 pt; 1 pt line at y + 7 from x 18 to W − 18; with "Clear" the line ends at W − 66, arrow `[W − 58, y + 3, 12, 9]`, label x W − 46 | measured |
| Bottom bar | 50 pt; Home `[8, 9, 32, 32]`; plus `[W − 40, 9, 32, 32]`; switcher items 36×34 at pitch 34, centered in `[42, 0, W − 84, 50]`; plate = item inset 1 | measured |
| Web panel | `[W, 10, winW − W − 10, winH − 20]`, radius 6, shadow black 0.25 radius 3 offset 1; hidden sidebar `[10, 10, winW − 20, winH − 20]` | measured |
| Hover-reveal card | 5 pt from the window edges, radius 10, 1 px stroke `SidebarBorderColor` (white 0.30; measured ≈ 0.25) | measured |
| Sidebar width | default 228; 500 is the widest seen; minimum 180 | 500 guess as max; minimum guess |

### 2.3 Typography

System font (SF Pro) only. We ship no fonts.

| Element | Size and weight | Evidence |
|---|---|---|
| Tab title, "New Tab" | 14 Regular | NCC 0.992–0.994 |
| Folder title | 14 Semibold | F0079 ink width |
| Space title | 13 Semibold | NCC 0.994 |
| URL placeholder | 13 Medium | NCC 0.991 |
| URL host (page loaded) | 13 Regular | F0015: ink width 59 vs 61 for Medium |
| "Clear" | 11 Semibold | F0041 ink 27×8 |
| Tooltip | 13 Medium; second line 12 Regular | AX frames; weight guess |
| Header emoji | 14 pt, 1 pt above center | NCC 0.988 (F0001) |
| Switcher emoji | 12 pt, 1 pt above center | NCC 0.983 (F0001) |
| Command bar input / rows | 18 Medium / 13 Medium | interaction-states §9 |

Labels draw with Core Text at an exact baseline (`TextLabel`). The text origin sits 1 pt inside Arc's AX text frame for rows, "New Tab", and the placeholder, and 3 pt inside for the Space title. This puts every measured ink box on Arc's pixels (0 pt error on 11 row titles).

### 2.4 Motion (provisional)

Arc keeps its springs in compiled code. The capture has about 0.47 s between frames, so only progress points exist. All animations use these tokens, so a better capture changes one place.

| Token | Value | Evidence |
|---|---|---|
| Space switch slide | spring, response 0.30 s, critically damped | fitted with the cross-fade to both progress pairs |
| Space theme cross-fade | linear, 0.21 s | model gives slide 0.645 / fade 0.50 and 0.855 / 0.78; measured 0.65 / 0.53 (A0222) and 0.88 / 0.77 (A0227) |
| Swipe snap | spring, response 0.26 s, damping 0.92 | guess |
| Hover fade / selection fade | 0.08 s / 0.12 s | guess |
| Row insert, remove, folder expand | 0.22 s, AppKit outline slide | measured "< 0.5 s" |
| Tooltip fade | 0.12 s, delay 0.6 s | guess; fade-out seen (F0026) |

## 3. Space themes

### 3.1 Input

`SpaceThemeStyle(theme:system:)` reads `SpaceTheme.importedArcThemeJSON`, the raw Arc `windowTheme` (schema in runtime-observations §3.3). It supports `blendedGradient` (2 base colors and 2 overlay colors) and `blendedSingleColor`. It reads `noiseFactor`, `intensityFactor`, `translucencyStyle`, `contentOverBackgroundAppearance`, `isVibrant`, both semantic palettes, and `primaryColorPalette.shaded` (accent). Without JSON it uses the mapped gradient stops. Without either it uses the default theme (§3.5). Parsed styles are cached by value.

### 3.2 Rendering model (`ThemeField`)

The field is computed on the CPU into a 64×64 float image (extended sRGB) and stretched over the window by the GPU. It is rebuilt only when the theme, the active state, or the window aspect ratio changes. The steps:

1. Two linear gradients in window uv space: base (angle 111°, length × 1.015, center offset 0.021) and overlay (angle 146.3°, length × 0.332). Each gradient parameter is computed at the 4 window corners, clamped to 0…1, and interpolated over the 2 triangles of the window quad (bottom-left to top-right diagonal), like a per-vertex varying.
2. Colors mix in OKLab. The base parameter is scaled by 4/3, so the base reaches its end color at 75 % of its line. An overlay whose first stop is clear fades in the second stop's own color, not black.
3. The overlay composites over the base in linear light. The result is encoded to sRGB with a sign-preserving transfer, so extended components stay valid.
4. The result is drawn at alpha 0.64 over a neutral underlay: gray 0.694 when the window is active, 0.83 when inactive (`translucencyStyle: light`).

Evidence for the structure: Arc's theme shader library (`ARC_WindowThemeUI`, `default.metallib`) has entry points `gradientVertex`, `gradientFragment`, `overlayVertex`, `overlayFragment`, `renderVertex`, `renderFragment`. The vertex stage uses `dot`, `clamp`, and `sqrt` (the per-vertex projection). The fragment stage holds the published OKLab constants: the LMS to linear sRGB matrix (4.0767417, −3.3077116, 0.2309699, −1.2684380, 2.6097574, −0.3413194, −0.7034186, 1.7076147) and the inverse cube matrix (0.3963378, 0.2158038, −0.1055613, −0.0894842, −1.2914855). It also holds the sRGB exponent 1/2.4 with `sign`, and `pow`. The angles, scales, alpha, and underlay grays are our fits to the captures. Our code is our own implementation of these facts. No shader code was copied.

### 3.3 Why Arc's window looks lighter than the stored colors

The stored stops are saturated (`#FF8558`, `#F0E941`, `#FF5598` in Space 1). On screen the top-left reads `#F2A686`, about 27 % lighter. Two things cause this (fitted, RMS 1.3–1.6 / 255 on two Spaces):

- The gradient layer draws at about 64 % opacity (`intensityFactor` 0.8 on both fitted Spaces).
- Under it lies a light, neutral material (`translucencyStyle: light`, `isVibrant: true`). It reads gray 0.694 while the window is active and 0.83 while inactive. On a real active window this material is vibrancy over the desktop, so the true underlay varies with the wallpaper. We use the fitted constant. The App can swap in an `NSVisualEffectView` later if a vibrant capture shows a difference.

### 3.4 Text appearance

`contentOverBackgroundAppearance` picks the semantic palette ("light" content uses `light.title` and dark text), not the macOS appearance. Each Space page sets its own `NSAppearance` from it, so every token in that page resolves against the right side. A Space without a theme follows the macOS appearance. Measured: macOS was Dark, yet Space 1 drew `light.title` (runtime-observations §3.3).

### 3.5 Default theme

Spaces without a stored theme draw measured corner colors: dark TL `#252538`, TR `#322438`, BL `#2C2437`, BR `#342237` (macOS Dark). Background ΔE 0.59 on F0079. The light variant is a guess (no light-mode capture). Its text colors are in §2.1.

### 3.6 Grain

Our grain is hashed white noise (`Grain.tile`), not Arc's tiles. It is one 100 pt tile, black with noise in alpha, repeated by two replicator layers (no large bitmaps). Monochrome multiply by `g` at strength `a` equals a black overlay of alpha `a · (1 − g)`, so plain source-over composites it. Strength: peak darkening `noiseFactor × 0.1`. This gives about ±1 % at `noiseFactor` 0.35, like the capture's 1st / 99th percentile spread (0.975–1.017).

### 3.7 Space switches

`ThemeBackgroundView` holds the current theme layer and, during a switch, an incoming one. `crossfade(to:animated:)` fades the incoming layer in. `beginTransition(to:)` + `setTransitionProgress(_:)` + `endTransition(commit:)` let a swipe drive it. A second request for the same target does not restart a running fade.

## 4. Icon map

SF Symbols where one fits. Sizes are tuned so the 1x ink box matches Arc's (measured boxes in the last column; "=" means our ink box now equals Arc's in the comparison).

| Glyph | Ours | Size, weight | Arc ink (1x) |
|---|---|---|---|
| Sidebar toggle | `sidebar.left` | 16 Regular | 19×15 (ours 18×14) |
| Back / forward | `arrow.left` / `arrow.right` | 16 Regular, 1 pt down | 14–15×12 (=) |
| Reload / stop | `arrow.clockwise` / `xmark` | 16 Regular, 1 pt down | 14×17 (=) |
| Magnifier | `magnifyingglass` | 12.5 Regular | 12×12 (=) |
| Copy URL | `link` | 14 Medium | 15×14 (ours 15×15) |
| Site Control Center | `slider.horizontal.2.square` | 18 Regular | 16×16 (=) |
| "New Tab" plus | `plus` | 13 Medium, 1 left 1 down | 11×10 (=) |
| Row close | `xmark` | 13 Semibold | 10×10 (=) |
| Row unload (loaded pinned) | `minus` | 17 Semibold | 14×2 (=) |
| Header chevron | `chevron.down` / `chevron.right` | 12 Bold | not measured |
| Header "…" | `ellipsis` | 13 Bold | not measured |
| "Clear" arrow | `arrow.down` | 9 Semibold | AX 12×9 |
| Audio / muted | `speaker.wave.2.fill` / `speaker.slash.fill` | 11 | not captured |
| Bottom plus | `plus` | 17 Medium | 14×14 (=) |
| Home (Library) | our vector `CustomIcon.library`: a filled box, a lid, two items above | 14×16 ink | 14×16 (=) |
| Folder closed / open | our vector `CustomIcon.folder` in the Space accent | 18 pt frame | shape not matched (§9) |
| Untitled Space mark | our vector `CustomIcon.planet` (Arc shows a planet for its named icon "planet") | 14 pt box | visual only |
| Missing favicon | our letter tile `CustomIcon.letterFavicon` (cached) | 16 pt | — |

## 5. Sidebar (`OpenSidebar`)

### 5.1 View tree

```
SidebarView (flipped, layer-backed, width = window.sidebarWidth)
├── SpacePagerView ─ PagerStrip ─ SpacePageView per Space (built on first use, kept)
│                                  ├── SpaceHeaderView (icon, title; hover: fill, chevron, "…")
│                                  └── PageScrollView ─ SidebarOutlineView (one column, rows 3 / 17 / 41 pt)
├── FavoritesView ─ NSCollectionView + FavoritesLayout (our layout, fixed metrics)
├── URLFieldView (fill, magnifier or host, copy and Site Control buttons)
├── ToolbarView (toggle, back, forward, reload; the system draws the traffic lights)
└── BottomBarView (Home, switcher items, plus)
```

The host window owns a `ThemeBackgroundView` behind the sidebar and the web panel and assigns it to `SidebarView.themeBackground`. The App owns the window, the traffic lights, and the web content. `WebPanelChromeLayer` draws the panel's radius, shadow, and empty-state fill.

### 5.2 Data flow

- The sidebar never changes the model. Every action becomes a `SidebarIntent` sent to `SidebarDelegate`. `ModelSidebarActions` maps the model-only intents to `BrowserModel` commands. The App handles the rest (engine, command bar, sharing, dialogs).
- Structure: one `BrowserModel` observer receives `TreeChange` events. Each page keeps the child lists the outline knows (root and each loaded folder). A change turns into a sequential diff (`ListDiff.steps`) applied as `removeItems` / `insertItems` / `moveItem` inside one `beginUpdates` block. A move between two displayed lists becomes one `moveItem`. The lists are edited in place, so a 1,000-row list is not copied per step. After the first build the outline never calls `reloadData` (checked by `SidebarDiagnostics.fullReloads`).
- Properties: views read model values inside `draw`, `layout`, or `updateLayer` through `tracked(_:invalidate:)`, a wrapper on `withObservationTracking`. A title, favicon, audio, or theme change redraws only the views that read it. Logic that needs the new value (selection, folder expansion, focused Space) uses `ObservationLoop`, which runs on the next main-actor turn.
- Rows: view-based outline with reuse (`makeView(withIdentifier:)`). A tab row has 3 layer-backed views. The close and audio buttons and the "/" mark are built only when shown (this cut the scroll p95 by about a third, §11).

### 5.3 States

| State | Behavior | Evidence |
|---|---|---|
| Row hover | fill; close × (Today) or − (loaded pinned) at the right | F0013, F0015 |
| Selected | fill + shadow, follows `selectedNodeBySpace`; no button unless hovered | F0014, F0066 |
| "New Tab" during Cmd+T | `context.isNewTabCommandBarOpen = true`: selected fill, label and plus in the title color; the selected tab loses its fill | F0063 |
| Divider and "Clear" | divider only with Today tabs; "↓ Clear" while the pointer is on the divider row | F0041, F0066 |
| Folder | glyph open or closed in the Space accent, 14 Semibold, click toggles, children indented 16; animated expand and collapse | F0072, F0079 |
| "/" mark | a pinned tab whose host or path left its pinned URL; title shifts 2 pt | A0414; geometry F0090, F0101 |
| Selected split row | card with one cell per pane, no divider; no mark on the focused pane | F0081 |
| Split selected | the toolbar keeps only the sidebar toggle | F0081, F0082 |
| Peek open | source row: badge with the Peek favicon (also while another row is selected); lighter fill while the Peek shows; URL field and toolbar follow the Peek page; toolbar row and bottom bar dimmed, URL field, Favorites, and list not dimmed | F0090, F0101 |
| Space header hover | fill, chevron (collapses Pinned), "…" menu | A0413 |
| URL field | placeholder with magnifier; with a page, the host; copy and Site Control buttons while the pointer is over the sidebar (guess) | F0015, F0016 |
| Inactive window | toolbar and bottom glyphs take the disabled tones; the theme underlay lightens | inactive capture |
| Switcher | current Space in color, others gray at 0.55 | F0001 |
| Hidden sidebar / hover-reveal | host hides the sidebar; `presentation = .floatingCard` draws the card with its own background | F0128–F0131 |

### 5.4 Space pager and swipe

Pages sit at `index × W` in a strip. A focus change slides the strip with a spring from its current presentation position, so a switch during a switch continues smoothly. Every page between the old and the new Space is shown during the slide (Arc passes through them, A0227). The background cross-fades at the same time. A two-finger horizontal scroll (phases began / changed / ended, momentum ignored) drags the strip one page at most, with rubber banding at the ends. It drives the cross-fade interactively. On release it switches when the drag passed half a page, or 8 % with a fast flick. Then it springs to the focused page. `PageScrollView` hands horizontal gestures from the tab list to the pager.

### 5.5 Drag and drop

Pasteboard type `com.open.sidebar.node` (local, the node ID) plus the URL for tabs. Drop targets map to model commands:

| Drop | Intent |
|---|---|
| Root list, above the first pinned row … right after the last pinned row | `.move(to: .spacePinned, index)` |
| Between the divider and the first Today row | `.move(to: .spaceToday, 0)` |
| Inside Today | `.move(to: .spaceToday, index)` |
| Onto a folder / between folder children | `.move(to: .folder, end / index)` |
| Onto a tab or split row | retargeted to just above it, in its parent |
| Favorites gap | `.addFavorite` / `.moveFavorite`; folders and splits are refused (model rule) |
| URLs from other apps | `.openURL(url, in: parent, index)` |

A same-parent move downward subtracts one, because the model counts the position after removal.

### 5.6 Menus and tooltips

Context menus are native `NSMenu`s built per target, in the captured order: Today tab (F0115), pinned tab (F0116), folder (F0119), and Space on the title or empty space (F0117). Favorite and bottom plus menus are guesses. The split row menu follows Arc's menu builder (`re/menus-and-hotkeys.md`, "Split row menu"): Separate All Tabs · Add Tab… · Convert to Vertical/Horizontal Split View · — · Tab Options · one submenu per pane (Separate from Split View · — · Mute · Copy Link · Copy Link as Markdown · — · Archive Item) · — · Duplicate · Move to · — · Archive Item. Each item sends an intent. "Rename…" starts the inline editor.

Tooltips are our own capsule (`TooltipView`) in a borderless child panel: 27 pt tall, radius = height / 2; two lines 42 pt. Fill is the theme's `light.title`. Keycaps follow the label. Placement: below toolbar buttons, above the bottom bar, beside the pointer on rows. Delay 0.6 s and fades are guesses.

### 5.7 Animations and offscreen windows

Structural and Space-switch animations run only when the window is visible (`animatesSidebarChanges`). AppKit never completes an animated collapse in a window that is never shown, and nobody would see it. `SidebarDiagnostics.forceAnimations` turns them on for frame captures.

## 6. `sidebar-render`

```text
sidebar-render render --snapshot DIR --out FILE.png [--size WxH] [--scale 1|2] [--space N] [--width W]
                      [--select ROW] [--hover TARGET] [--loaded] [--new-tab-open] [--hidden] [--reveal]
                      [--inactive] [--appearance light|dark] [--page] [--switch-to N --at SECONDS] …
sidebar-render tooltip --snapshot DIR --title TEXT [--subtitle TEXT] [--keys "⌘,["] --out FILE.png
sidebar-render compare --arc CAPTURE.png --ours RENDER.png --out DIR [--rows N] [--today N] [--hover-row I]
                       [--selected-row I] [--page-loaded] [--depths …] [--split-rows …] [--skip …]
sidebar-render check          # end-to-end checks, exits non-zero on failure
sidebar-render bench [--rows 1000]
sidebar-render synth --out DIR [--rows N]
```

Rendering: the composed window (`RenderScene`: theme background, web panel chrome, stand-in traffic lights, the real `SidebarView`) goes into a borderless window that is never shown. The window reports the requested backing scale, so 2x works on a 1x display. AppKit lays out and draws as usual. A deep copy of the layer tree is then rendered by `CARenderer` into a Metal texture. This path supports masks, shadows, replicators, and layer contents. With `--switch-to`, the copy uses presentation values to capture a frame of the transition.

## 7. Comparison method

1. Snapshot: copy `StorableSidebar.json`, `StorableWindows.json`, and `StorableLinkRouting.json` from `~/Library/Application Support/Arc` to a temp folder (read-only), then `openkit import-arc --arc-dir <copy> --out <snapshot>`. We used the copies taken at capture time, so the tree matches the frames. Render-only edits match a frame's exact state: `--clear-today`, `--drop-today N`, `--untitled N`, `--insert-folder-tab` (older snapshots omit Arc's welcome items).
2. Render the same window size and sidebar width at 1x (the captures are 1x).
3. `compare` loads both PNGs into sRGB. Core Graphics converts the capture through its embedded display profile, as runtime-observations §0 asks.
4. Elements come from the metrics (toolbar glyphs, URL field parts, each tile, header icon and title, each row title, fills, "New Tab", divider, bottom glyphs, background samples, panel fill). For each element, a plane `a + b·x + c·y` is fitted to the luminance of a 1 px ring around its region. Ink = pixels at least half of the peak contrast away from the plane. Position error = the largest of the 4 edge differences between the two ink boxes, in points. Fills scan the middle row and column against the sample's contrast. Emoji use the contrast-weighted centroid.
5. Color: fills compare the mean of a sample rectangle; text and glyphs the mean of their core pixels (≥ 85 % of peak contrast); the background averages ΔE over 70–140 points. ΔE is CIEDE2000.
6. Masks in the side-by-side and diff images: favicons, tile icons, the web panel, the system traffic lights, and the window corners. Output: `table.md` and `side-by-side.png` (Arc | Open | diff × 4).

Personal data stays in `.re/` (git-ignored). This file shows element names only. The screens in §10 come from the synthetic snapshot.

## 8. Results

### 8.1 Error per state

Targets: layout error ≤ 1 pt, fill and text ΔE00 ≤ 2.

| State | Frame | Elements | Worst position (pt) | Mean position (pt) | Worst ΔE00 | Mean ΔE00 |
|---|---|---|---|---|---|---|
| Static, active window | F0001 | 31 | 1.0 | 0.08 | 1.59 | 0.56 |
| Static, inactive window | `arc-window-5245.png` | 31 | 1.0 | 0.04 | 1.17 | 0.67 |
| Row hover | F0013 | 33 | 1.0 | 0.07 | 1.59 | 0.59 |
| Selected pinned row, page loaded | F0015 | 33 | 1.0 | 0.10 | 1.73 | 0.65 |
| Selected favorite tile | F0016 | 30 | 1.0 | 0.11 | 1.73 | 0.65 |
| Sidebar toggle hover | F0024 | 28 | 1.0 | 0.08 | 1.59 | 0.61 |
| Home hover | F0027 | 28 | 2.0 | 0.16 | 1.59 | 0.64 |
| "New Tab" hover | F0031 | 28 | 1.0 | 0.08 | 1.59 | 0.61 |
| Cmd+T open ("New Tab" selected, divider) | F0063 | 36 | 1.0 | 0.09 | 2.00 | 0.60 |
| Today tab selected, 6 Today rows | F0066 | 38 | 1.0 | 0.09 | 2.03 | 0.62 |
| Default dark Space, folder, split, child hover | F0079 | 31 | 1.0 | 0.11 | 1.77 | 0.58 |
| Yellow theme | F0070 | 23 | 1.0 | — | 1.95 | — |
| Blue theme with grain (intensity 1.0) | F0069 | 19 | 1.0 | — | 2.38 | — |

### 8.2 Static state, per element (F0001)

| Element | Position error (pt) | ΔE00 |
|---|---|---|
| Background, sidebar column (101 samples, max 0.87) | — | 0.58 |
| Panel fill, empty state (11 samples, max 0.94) | — | 0.51 |
| Toolbar: sidebar toggle | 1.0 | 0.78 |
| Toolbar: back | 0.0 | 0.23 |
| Toolbar: forward | 1.0 | 0.31 |
| Toolbar: reload | 0.0 | 0.17 |
| URL field fill | 0.0 | 0.37 |
| URL field magnifier | 0.0 | 0.69 |
| URL field placeholder | 0.0 | 0.43 |
| Favorite tiles 1–6 (fill) | 0.0 | 0.29–0.61 |
| Space icon (centroid) | 0.2 | — |
| Space title | 0.0 | 0.40 |
| Row titles 1–10 | 0.0 | 0.25–0.73 |
| "New Tab" plus | 0.0 | 1.32 |
| "New Tab" label | 0.0 | 0.41 |
| Bottom: Home | 0.0 | 0.55 |
| Bottom: plus | 0.0 | 1.59 |

State elements (other frames): row hover fill 0.0 pt / 0.45; close × 0.0 / 1.39; selected row fill 0.0 / 1.05; unload − 0.0 / 1.23; selected tile 0.0 / 1.15; toggle hover plate 0.0 / 0.38; Home hover plate 0.0 / 0.72; "New Tab" hover fill 0.0 / 0.49; "New Tab" selected fill 0.0 / 2.00; divider 0.0 / 0.33; URL host 0.0 / 0.35; copy button 1.0 / 0.48; Site Control 0.0 / 1.73; dark hover fill 0.0 / 0.81; dark row titles 0.0 / 0.40.

## 9. What still differs, and why

| Difference | Size | Why |
|---|---|---|
| Selected fill at lower rows | ΔE 2.00–2.03 (1.05 near the top) | Arc's selected fill varies slightly with position: at row y 709 its blue channel is 2–5 levels above `light.background`. No simple blend (white, `backgroundExtra`, partial alpha) fits both positions. The spread is at the ±2-level capture noise. |
| Blue grain Space | background ΔE 1.39 (max 2.4) | The theme fit used two Spaces with `intensityFactor` 0.8. This Space has 1.0 and grain 0.35. A per-intensity alpha made it worse; a better fit needs more themes (theme editor captures). |
| Home glyph on hover | 2 pt | Arc draws a larger Home glyph on hover (ink 16×17 vs 14×16 at rest). Its HomeButton bundle holds Lottie hover animations, so this is likely an animation frame (guess). We keep a still glyph; the animation is open. |
| Toggle, forward, copy ink boxes | 1 pt | SF Symbol shapes differ slightly from Arc's art. |
| Folder glyph | shape | Arc's open folder has an outlined back and a lighter rim. Ours is a simpler two-tone shape in the same accent. |
| Inactive switcher emoji | darkest pixels within 10 levels | Arc's desaturation method is not known; ours is luma at 0.55. |
| Traffic lights | not compared | System drawn; the renders draw stand-ins and the comparison masks them. |
| Favicons | not compared | Masked; renders have no engine favicons. |
| Light-mode default theme, dark tokens without a dark capture, motion numbers, favorites column rule for counts other than 6 | guesses | No capture yet (interaction-states §19). |

## 10. Screens (synthetic snapshot, our renders only)

`sidebar-render synth` builds three Spaces with neutral titles and our own theme colors (a warm gradient, a blue gradient with grain, and an untitled default Space with a folder and a split).

![Sidebar states](design/sidebar-states.png)

![Window states](design/window-states.png)

![Tooltips](design/tooltips.png)

## 11. Performance

`sidebar-render bench --rows 1000`, release build, 2x, Apple M5 Pro. Three runs while a Chromium build ran (load average ≈ 25), so these are upper bounds.

| Measure | Result |
|---|---|
| Build + first layout + first display, 1,000-row Space (cold process) | 74–84 ms |
| Same, second sidebar with warm caches | 26–36 ms |
| Scroll, 337 steps of 120 pt (layout + display of new rows) | median 3.1–3.5 ms, p95 5.5–5.6 ms (budget 8.33 ms at 120 Hz) |
| `moveNode` ×200 (model + diff + layout + display) | median 0.9–1.5 ms, p95 5.7–7.4 ms |
| `newTab` / `closeTab` ×100 | median 0.41–0.75 ms, p95 ≤ 1.6 ms |
| Space switch to an unvisited Space (builds its page) | 17–22 ms |
| Space switch back (page kept) | 7–12 ms |
| Full reloads | 1 per page built; 0 from edits |
| Rows match the model after 400 edits | yes, all runs |

Two fixes came from profiling: building the close and audio buttons on demand (scroll p95 from 8–12 ms to 5.5 ms), and editing cached child lists in place (move p95 from 13–20 ms to 6–7 ms).

## 12. End-to-end checks

`sidebar-render check` drives the real view stack in an offscreen window: 125 checks, all passing: the prior 81, 22 model-followup checks, and 22 from §15. Covered: rows match the model after `newTab`, `pinTab`, `moveNode`, `createFolder`, folder collapse and expand, `makeSplit` and `unsplit`, `closeTab` and its undo, `clearToday` and its undo (divider goes and comes back); no `reloadData` during edits; favorites add and remove; clicks (a mouse-down delivered to the hit-tested view, the mouse-up through the event queue) on a pinned row, a folder, "New Tab", and the URL field reach the delegate and the model; context menu item order for 4 targets; drop-target mapping for 4 positions; a Space switch moves the pager and the theme; a swipe switches Spaces and a short swipe snaps back.

## 13. Model and import changes needed

Implemented by the model followups:

1. `setPinnedSectionCollapsed(spaceID:collapsed:)` and `setMuted(tabID:muted:)`
   register undo/redo and emit no `TreeChange`. `ModelSidebarActions` calls them.
2. `TabLiveState.hasWebContent` is observable and never persisted. Hovered pinned
   tabs and Favorites show “−” while true and “×” otherwise. “−” sends
   `SidebarIntent.unloadTab(id)` to the App; engine wiring is still pending.
3. Untitled imported Spaces keep `title == nil`. The sidebar header and switcher
   use `BrowserModel.displayTitle(for:)`: “Space N” for the current 1-based position.
4. `SpaceIcon.named` preserves Arc's identifiers. A recreated mapping resolves
   them to checked SF Symbols; unknown names use a reported neutral fallback.
5. `welcomeToArc` items import as ordinary tabs, including archive records, and
   count as imported. Their stored title and timestamps are retained. Arc's
   payload has no saved URL, so Open uses its public welcome page as the normal-tab
   destination. This is an import policy, not a claim to reproduce Arc's native onboarding.
6. `newTab` defaults to index 0 in Today. An explicit index still wins.

The CLI checks exercise these changes through real model commands, snapshot
save/load, and the offscreen AppKit sidebar. The comparison error table in §8
is retained unchanged.


## 14. PR #33 review corrections (2026-10-25)

Merged `origin/main` before the corrections. The merge kept both the sidebar and sleep targets in `Package.swift`; no conflict repair was needed. The merged package and the final source both built with `nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`. No engine build, unit tests, or desktop input was used for this pass.

| Finding | Fix | Result |
|---|---|---|
| 1. Illegal drops looked accepted; acceptance discarded the command result. | Expose the model's existing `canMoveNode(id:to:)` placement predicate and use it for outline, Favorites, and Space-icon validation. Return the delegate/model Bool through `SidebarContext.send` and drop acceptance. | PASS: self/descendant folders, split-pane sources, and folders/splits in Favorites are refused. A legal pinned folder drop preserves pinned ancestry. Delegate refusals return false. |
| 2. Rows lacked accessibility and outline keyboard navigation. | Expose tab/folder/split rows and favorite tiles as named AX buttons. Folders expose expanded state; split labels name all panes. Label PlateButtons. Keep keyboard focus separate from model selection, with a lazy focus ring. | PASS: the harness dumps real NSAccessibility roles/labels/states, presses a favorite through AX, and sends real NSEvents for Up/Down, Return/Space, Left/Right, and Delete. The model selection, expansion, and archive flow match the events. |
| 3. Pointer movement restarted the tooltip delay. | Return early when the same owner and tooltip are pending or visible. | PASS: 16 pointer movements over the rendered row produce one schedule and one show. |
| 4. Teardown assumed main-actor isolation and left observation loops active. | Use Swift 6.2+ `isolated deinit`; cancel stored loops in Favorites, pager, bottom bar, and Space pages. Cancel Space-icon hover work on exit, drag end, and teardown. | PASS: a second real view stack releases with queued model observations after the harness drains AppKit's autorelease pool. |
| 5. Resizing repeatedly rebuilt the theme field. | Coalesce field work through a one-shot display link. Stretch existing field/grain geometry during `inLiveResize`, and request one refresh from `viewDidEndLiveResize`. Offscreen snapshots flush after layout. | PASS: 120 simulated live-resize steps cause zero field rebuilds during resizing and one after resize ends (limit: two). |
| 6. Favorites mixed moves with insertions/deletions in unsafe batches. | Reload for mixed plans and bulk `.reload` events. Reload offscreen updates as well, so AppKit does not keep stale items awaiting animation. Keep precise simple visible edits animated. | PASS: 32 seeded permutations with two removals and two insertions per `.reload` match the collection count, displayed IDs, and actual tile order each time. The harness forces animation eligibility for this check. No exceptions. |
| 7. Space icons did not support cross-Space drags. | Register sidebar/URL drag types on each icon. Switch Space after a 0.5 s hover without restarting the timer on drag updates. Validate every source, then move it to index zero in the matching Today/Pinned section, preserving each section's input order. | PASS: a mixed three-tab drag switches after the delay, preserves order and pinned URLs, and lands at the section tops. Pane/stale sources and delegate refusals fail. Leaving the icon cancels the pending switch. |

`sidebar-render check`: **81 passed, 0 failed**. Verification uses the real `RenderScene` → `SidebarView` → AppKit destination → delegate → `BrowserModel` flow in `sidebar-render check`. All fixture titles, URLs, pasteboards, and random batches are synthetic. The drag fixture supplies event data only; it does not replace views, validation, or model commands. The AX dump is part of the command output. No personal data is committed.

The Arc comparison repeats §7 with the same capture-time snapshots, 1x renders, sizes, sidebar width, forced states, masks, and compare arguments from `.re/design-compare/run-states.sh`, using the release executable in place of the old debug executable path. All 13 state tables are byte-for-byte unchanged, including every position/color error and the aggregate error rows in §8. Concatenating the 13 `table.md` files in sorted state-name order gives SHA-256 `2e79746492cc775d8b207bc5759084b74f3e96ab88e521c6ab9909790a278448` before and after. Tokens, metrics, colors, and the §8 error tables are unchanged. Raw captures, snapshots, renders, and run receipts remain in git-ignored `.re/`.

One F0031 render from the concurrent harness/comparison run had transient pixel differences, including pixels outside the sidebar. Its cause is not established. Rerunning that exact render/compare command alone produced the baseline PNG and table byte for byte; no source or visual values changed between those runs. The final set contains 13 baseline-identical PNGs as well as the 13 baseline-identical tables.


## 15. M4 visual finish (2026-10-25)

Split View and Peek reach the sidebar. All values come from F0081, F0082, F0090, F0101, and the fast frames A0264–A0271 (`re/interaction-states.md` §§3, 7, 11, 12).

| Change | Arc evidence | Result (§7 method) |
|---|---|---|
| Selected split row: card plus one cell per pane, no divider | F0081 pixels | card 0.0 pt / ΔE 1.53, cells 0.0 / 1.34, 1.39 |
| No focused-pane mark in the row (the plan's `ContentVisible` guess is dropped) | F0081: both cells pixel-identical; focus on pane 2 | both cells measured the same |
| Split selected: sidebar toolbar keeps only the toggle | F0081, F0082 AX and pixels | no ink in both, `sidebar-render check` |
| Peek badge on the source row, also while another row is selected | F0090, F0101 | plate 0.0 pt / ΔE 0.76 |
| Source row fill white 0.10 while its Peek shows | F0090, F0102 | 0.0 pt / ΔE 0.09 |
| Peek dim under the URL field, Favorites, and list; over the toolbar row and bottom bar | F0090 vs F0101 | row titles ΔE ≤ 0.45; toolbar ≤ 0.57; bottom bar ≤ 1.98 |
| URL field and toolbar follow the Peek page; back/forward/reload in the enabled tone under the dim | F0090 AX and pixels | host 0.0 / 0.14 |
| "/" mark: measured stroke; title + 2 pt (was a 4 pt guess) | F0090, F0101 | row title 0.0 / 0.39 |
| Row titles keep 1 pt free at the right when they truncate | AX widths 128, 152, 168 | F0090 source title 0.0 |
| A title box narrower than "…" draws nothing (four-pane split rows overflowed) | — | `sidebar-render check` |
| First hover of a row lays out its new close button | — (bug: zero frame until the next layout) | `sidebar-render check` |
| A Peek badge change reaches only its own row: on or off lays that row out, a new URL or favicon only redraws the badge (per-tab observable state in `SidebarContext`) | — (performance) | `sidebar-render check`: 1 row layout of 14 rows; 0 layouts and 1 draw on a URL change |

Split-row menu: see §5.6.

### 15.1 No regression on the matched states

The M2 run script (`.re/design-compare/run-states.sh`) was lost with its worktree. It is re-derived from the frames in `.re/vf/run-states.sh` (same snapshots, sizes, forced states). The table runs it with release builds of `origin/main` (`33aade1`) and of this branch, one state per process. All 13 PNGs and tables are byte-identical between the two builds.

| State | Frame | Elements | Worst position (pt) | Worst ΔE00 | Main vs branch |
|---|---|---|---|---|---|
| Static, active window | F0001 | 31 | 1.0 | 1.59 | identical |
| Static, inactive window | `arc-window-5245.png` | 31 | 1.0 | 1.17 | identical |
| Row hover | F0013 | 33 | 1.0 | 1.59 | identical |
| Selected pinned row, page loaded | F0015 | 33 | 1.0 | 1.73 | identical |
| Selected favorite tile | F0016 | 28 | 1.0 | 1.59 | identical |
| Sidebar toggle hover | F0024 | 29 | 1.0 | 1.59 | identical |
| Home hover | F0027 | 29 | 2.0 | 1.59 | identical |
| "New Tab" hover | F0031 | 29 | 1.0 | 1.59 | identical |
| Cmd+T open | F0063 | 35 | 1.0 | 2.00 | identical |
| Today tab selected | F0066 | 36 | 1.0 | 2.03 | identical |
| Default dark Space, folder, split, child hover | F0079 | 31 | 1.0 | 1.77 | identical |
| Yellow theme | F0070 | 23 | 1.0 | 1.95 | identical |
| Blue theme with grain | F0069 | 19 | 1.0 | 2.38 | identical |

Worst values equal §8.1 in 12 states. F0016 reads 1.59 instead of 1.73 because the re-derived script skips the URL copy and Site Control buttons there. Element counts differ in six states (F0016, F0024, F0027, F0031, F0063, F0066): the re-derived script skips URL-host, button, and row-title elements whose text or state differs between the snapshot and the capture. The known differences in §9 remain (Home hover 2 pt, F0063/F0066 selected fill ≈ 2.0, blue grain 2.38).

Offscreen renders are not fully deterministic. A run can return an empty image, a few 64 px tiles at the bottom edge can differ, or row text can differ by 1–4 levels. This happens with the main build too (F0063: one of three main runs differed). Each such state was run again alone, up to three times; then the outputs matched. The bottom-band glitch got more frequent under machine load.

## 16. Sidebar completion S1 (2026-10-26)

`SidebarContext.selection` owns transient multi-selection for one window.
Cmd-click first includes the visible current row (lead decision Q9). Shift-click
and Shift+Arrow use visible tabs, folders, and splits in display order, skipping
all sentinel rows. Esc, plain clicks, and Space switches clear it. Removing or
hiding rows prunes it; moves keep the IDs in display order. Favorites do not join.

Each row observes one `SidebarRowSelectionState.isSelected` flag. A toggle marks
only those row fills dirty, with no cell layout or full outline reload. Current
rows keep their fill and shadow; other selected rows use
`SidebarRole.rowMultiselected` (the existing `TabCellBackgroundMutiselected`
color, documented in [sidebar-completion.md §3](re/sidebar-completion.md#3-multi-select)).
Split pane cells appear only when the split is current. The multi-fill uses the
existing hover geometry and `Motion.hoverFade`.

Verification uses real window events and real offscreen AppKit views in
`sidebar-render check`, plus `sidebar-render bench --rows 1000 --selection`.
MS1–MS6 and MS13 cover current-row inclusion, range extension and shrinking,
keyboard input, empty current state, pruning, folder/split fills, and row order.
MS6 samples the rendered fill in light and dark appearances against the composited
token (ΔE00 0.304 / 0.302, limit 0.5), and checks its exact geometry and shadow.
The selection bench measured p95 0.46 ms with zero row layouts (limit 1 ms and at
most two layouts). Scroll p95 was 2.83 ms; the saved pre-change run was 3.80 ms.
These are local measurements, not a claim that S1 improves scroll performance.
No unit tests, desktop input, or engine build ran. App automation E1–E4 remains
with the later App lane.

### 16.1 Durable 13-state comparison

The old git-ignored runners were lost. The committed replacement is
`tools/verification/sidebar-compare-states.sh`, with a Python helper next to it.
It reconstructs §15.1 with one state per render process, using absolute private
input paths. The snapshot, frame, forced state, size, width, and compare switches
for every state are in the helper. It retains the existing `Compare.swift` masks.
F0079 uses the pre-theme static snapshot and reads the omitted first folder
child's title from that frame's private AX input inside the compare harness.
Blue-theme row text and New Tab differ from its snapshot, as in the earlier
comparison; their ink is excluded. No private value is part of the script.

```sh
tools/verification/sidebar-compare-states.sh \
  /absolute/path/to/.re/design-compare \
  --renderer /absolute/path/to/Packages/OpenKit/.build/release/sidebar-render
```

The runner resolves `origin/main` to an immutable commit, exports its package
source into `/tmp`, and makes a release build. `--baseline-renderer` can reuse an
existing release binary built from `--baseline-ref`. It renders and compares both
binaries sequentially and requires every state's table to be byte-identical.
Known offscreen nondeterminism (§15.1) permits at most three paired attempts per
state; every attempt is retained and the receipt lists the count. It never
changes or removes table rows to hide a main-versus-branch difference. Outputs
stay in a private `/tmp/open-sidebar-compare-*` directory, including images,
commands' logs, the binary/input SHA-256 receipts, per-state tables, and the
combined tables in sorted state-name order. Captures and snapshots stay in the
main checkout's `.re`.

All 13 per-state worst values and element counts reproduce §15.1, and all 13
main-versus-S1 tables are byte-identical. **Baseline SHA re-derived:**
`f820361b0b4baa3ad4e24b723ca807462f1b195d2f2391997815445ec77455e1`.
The historical `2e7974…a278448` is still printed for comparison. Its original
runner is unavailable, so main-versus-branch identity is the acceptance gate.
`tools/verify-all.sh` includes `sidebar-compare`: it runs where the private inputs
exist and SKIPs only when those inputs are absent. `SIDEBAR_CAPTURE_ROOT` selects
a different private input root; `SIDEBAR_BASELINE_RENDERER` supplies a prebuilt
main binary. The full local verification run passed every available row.
