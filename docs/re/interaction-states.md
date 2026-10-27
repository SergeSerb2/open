# Arc interaction states (live capture, 2026-10-24)

This file is the measured spec for Arc's interactive states: hover, selection, the command bar, Space switching, Split View, Peek, menus, and windows. It extends `runtime-observations.md`, which covers the idle window. All values come from the running Arc 1.170.0. We only read data. The user gave all input; the recorders only read AX attributes and window pixels.

Personal data is not in this file. Space names, tab titles, and URLs are placeholders. Raw frames stay in `.re/` (git-ignored).

## 0. Capture conditions and method

| Item | Value |
|---|---|
| Time | 21:30:09–21:34:57 PDT |
| Display | 2560x1440, backing scale 1.0 (1 px = 1 pt). macOS appearance Dark. |
| Main window | id 5245, 2216x1394 pt |
| Full recorder | `.re/runtime/sessions/20261024-213009-session-full/`: 169 frames with `ax.json`, `windows.tsv`, and screenshots. Frames are about 1.5 s apart (the AX dump takes time), not 1 s. |
| Fast recorder | `.re/runtime/sessions/20261024-213009-session-anim/`: 565 frames, screenshots and window lists only. Frames are 0.40–0.65 s apart (median about 0.47 s), not 0.2 s. A 2216x1394 capture takes that long. |
| Frame index | `.re/runtime/sessions/index-20261024.json`: one entry per state with frame ids, window ids, and notes |
| Scripts | `.re/runtime/analysis-20261024/` (`axdiff.py` AX diff per frame, `imdiff.py` pixel-change boxes, `fill.py` / `fillq.py` overlay fits, `radius.py` corner fits, `ink.py` text ink bounds, `menus.py` menu dump, `crops.py` / `animsheet.py` sRGB crops). Colors use the embedded display profile to sRGB, as in `runtime-observations.md` §0. |

Evidence notation: **F0013** = full-session frame 0013. **A0222** = fast-session frame 0222. Marks: **measured**, **derived**, **guess**.

Spaces in this session (order = switcher order):

| Name here | Theme |
|---|---|
| Space 1 | Light content, orange-to-yellow gradient, pink overlay (`runtime-observations.md` §3). Text palette `light`. |
| Space 2 | Light content, blue gradient |
| Space 3 | Light content, yellow gradient |
| Space 4 | The untitled default Space. It had no `windowTheme` until F0137. In macOS Dark it draws a dark navy sidebar (`#262538` ± 2) with white text. At F0137 the user gave it a single olive color with grain (see §14). |

Three caveats:

1. **Window moves are not Arc's.** The window x position jumps between 94, 336, 8, −356, and −1888 (`windows.tsv`). Other windows slide in beside it. guess: a third-party tiling or scrolling window manager. Ignore all window x/y changes.
2. **Traffic lights are grey in every frame** (`#CD866C` on `#E69679` in Space 1, `#696873` on `#252539` in Space 4), even while the user typed into Arc. Active-window colors were not captured. guess: the capture shows the inactive style, or Arc keeps them muted. Measured 2026-10-26: the grey is not macOS's own inactive drawing. The fill is Arc's catalog color `DimmedWindowControls` (`ARCUI_ARCUI.bundle` `Assets.car`: black; dark `(0.953, 0.953, 0.918)`) over the background at 0.10 (light, F0001: 0.099–0.103 per channel) and 0.33 (dark, F0079/F0129/F0131: 0.326–0.332; plain white would need 0.295 on blue against 0.31 on red and green). A faint 1 pt ring in each button's color sits just outside the 12 pt circle (fitted: 0.06 light, 0.34 dark). macOS 27's own inactive buttons, measured in Open's window when not key, are lighter on light content (`#E6A78E` over `#E49678`) and white ≈ 0.18 on dark. The buttons themselves are system buttons: AX shows `AXButton` with `AXCloseButton` / `AXMinimizeButton` / `AXFullScreenButton` while Arc imports no AX subrole constants (`nm -u`) and sets none; Arc calls `standardWindowButton:` and `standardWindowButton:forStyleMask:`, and `performClose:`, `performMiniaturize:`, `performZoom:`, `zoom:`, `toggleFullScreen:` (strings). Its own `Arc.WindowControlButton` (`Arc/WindowControlsButton.swift`) is an `NSControl` with an icon image view, hover and press state, and click, right-click, and drag-begin closures (`otool -ov`: `mouseEntered:`, `mouseDown:`, `rightMouseDown:`, `mouseDragged:`, `updateLayer`; no accessibility overrides); guess: it serves other window controls (`LeftAccessoryType.windowControls`, `TopBarConfiguration.shouldShowWindowControls`). Capture session 2 (2026-10-26, item 3, `sessions/20261026-100848-03-active-window/`, 1x, macOS Dark, default dark theme; timeline `s2-notes.txt` "03 step") settles the active state. Active and key with the pointer on the page (frames 0003–0005): grey, `#686973` on `#252538`, `DimmedWindowControls` at 0.326–0.331, colored rings `#5F3F4A` / `#5E533C` / `#39543E` at r 6.5. Pointer over the group (0007–0008): the standard red, yellow, and green with glyphs (rings `#D06A67` / `#D0AD27` / `#4CB035`). Pointer on Back, Forward, Reload (0010–0015): grey, unchanged. Arc inactive, Finder frontmost (0016–0018): the same fill alpha (0.328–0.331) over a darker underlay, `#565761` on `#0A0B1D`, and no colored ring (`#202132` at r 6.5). Session 1's values equal the active ones to the level, so its frames were taken while Arc was active, and the colored ring marks the active window. The AX frames are the same `[12/35/58, 16, 16, 16]` (close `[457, 238]` with the window at `[445, 222]`). On the hover-reveal card (item 5, `sessions/20261026-101324-05-reveal-card/`, frames 0009–0034) the buttons keep this look at (25, 29), (48, 29), (71, 29), with the fill at 0.327–0.331 and the rings; with the pointer on them (0018) they show the system colors and glyphs (§13.1). Open follows this (`docs/design.md` §23). Their geometry does not depend on the style: AX gives 16 pt buttons at window `[12, 16]`, `[35, 16]`, `[58, 16]` (F0001 close `[106, 54, 16, 16]` screen; F0131 `[348, 54]` with the window at `[336, 38]`), and the drawn 12 pt circles are centered in them at x 20 / 43 / 66, y 24 (F0001 pixels). On the hover-reveal card they move with the card to `[17, 21]` (F0128, F0129); see §13.
3. **AX and pixels can disagree by one state.** `ax.json` is written before the screenshot, so a frame's AX can lag its image by up to about 1 s.

## 1. Timeline

| Time (PDT) | Frames | State |
|---|---|---|
| 21:30:09–21:30:25 | F0001–F0012 | Idle in Space 1. No tab selected. Sidebar 228. All 12 frames are pixel-identical. |
| 21:30:26 | F0013 | Hover on a pinned row (row hover + close button) |
| 21:30:28–21:30:29 | F0014–F0015 | Click a pinned tab: selected row. Page loads (white, then loaded). |
| 21:30:31–21:30:37 | F0016–F0020 | Click a Favorite tile: selected tile. F0019 = row hover with close button. |
| 21:30:39 | F0021 | Tab tooltip (title + "Double-click to rename") |
| 21:30:44–21:30:56 | F0024–F0030 | Hover: sidebar toggle (F0024), tooltips "Go back ⌘[" and "Reload this page ⌘R" (F0025–F0026), Home (F0027), Space switcher icon (F0028), Space tooltip "<Space> ⌃2" (F0029), plus (F0030) |
| 21:30:57–21:31:03 | F0031–F0034 | Hover "New Tab" row. Hover the Site Control Center button in the URL field (tooltip only). |
| 21:31:07–21:31:12 | F0036–F0039 | Browsing inside the Favorite page |
| 21:31:14–21:31:23 | F0040–F0045 | Cmd+T, type, Return: first Today tab. Today divider and "Clear" appear (F0041). Cmd+T again (F0043). |
| 21:31:28–21:31:42 | F0048–F0057 | Cmd+L (URL prefilled and selected), type, Esc. Twice. |
| 21:31:44–21:31:55 | F0058–F0065 | More Cmd+T. Empty Cmd+T bar at F0063. Six Today tabs by F0066. |
| 21:32:00–21:32:06 | F0069–F0072, A0221–A0233 | Space switches 1→2→1→3→1→4. Mid-transition frames A0222 and A0227. |
| 21:32:07–21:32:18 | F0073–F0079, A0236–A0258 | Space 4: folder collapse and expand (mid-animation A0237, A0239, A0256). Folder and New Tab hover. |
| 21:32:19–21:32:30 | F0080–F0085 | Seeded tabs selected. Split View of two seeded tabs (F0081–F0082). |
| 21:32:31–21:32:50 | F0086–F0097 | Folder tabs selected. Peek loads (F0089) and stays open (F0090–F0097). |
| 21:32:52–21:32:54 | F0098–F0099, A0327–A0330 | Cmd+N: second window with the command bar open, closed after 2 s |
| 21:32:57–21:33:07 | F0100–F0106 | Tab switches. Peek comes back with its source tab (F0102). |
| 21:33:08–21:33:10 | F0107 (list only), A0359–A0362 | A window titled "Space 1" with a window-only sidebar (guess: Blank Window, §17) |
| 21:33:13–21:33:23 | F0108–F0114 | Peek open, pointer over its buttons |
| 21:33:25–21:33:34 | F0115–F0121, A0393–A0412 | Context menus: Today tab (F0115), pinned tab (F0116), Space (F0117), folder (F0119–F0121) |
| 21:33:35–21:33:36 | A0413–A0415 | Space header hover, then the Space menu |
| 21:33:39 | A0422 | Sidebar slides out to the left (guess: dragged below its minimum) |
| 21:33:42–21:33:44 | F0126–F0127, A0431 | Sidebar width 228 → 500 |
| 21:33:45–21:33:51 | F0128–F0131, A0436–A0448 | Cmd+S: sidebar hidden, hint toast, hover-reveal card, shown again |
| 21:33:55–21:33:58 | F0134–F0136, A0458–A0464 | Folder menu again. Space menu → Edit Theme Color… |
| 21:34:00–21:34:04 | F0137–F0139, A0465–A0472 | Theme editor popover. Color picked, grain dial turned. |
| 21:34:07–21:34:16 | F0141–F0146, A0481–A0492 | Page zoom toasts (110%, 125%, 100%) |
| 21:34:17–21:34:26 | F0147–F0151, A0493–A0508 | Settings window, all 8 tabs |
| 21:34:31–21:34:35 | F0154–F0156, A0519–A0525 | "Copied Current URL" toast (Cmd+Shift+C) |
| 21:34:36–21:34:42 | F0157–F0160, A0526–A0534 | Cmd+N second window. Command bar open. Space switched to Space 2. Window closed. |
| 21:34:44–21:34:57 | F0161–F0169 | Idle |

## 2. States captured and missing

Captured: tab row hover and close button, selected pinned tab, selected Today tab, selected Favorite tile, toolbar and bottom-bar hovers, tooltips, Today divider and "Clear", folder rows (collapsed, expanded, mid-animation), split row, Space header hover, command bar (Cmd+T empty, Cmd+T typing, Cmd+L), Space switching (two mid-frames), Split View, Peek, context menus for 4 targets, sidebar width 500, sidebar hidden and hover-reveal, theme editor, toasts, Settings (8 tabs), two Cmd+N windows, a window-only-sidebar window.

Not captured:

| State | Why |
|---|---|
| Active-window traffic lights and glyph colors | Every frame shows grey traffic lights (§0) |
| Favorite tile hover, Space "More" button hover alone | No frame shows them |
| Context menu for a Favorite, and for empty sidebar space | A0414–A0415 is the Space menu, not a Favorite menu |
| Sidebar minimum width | The narrow drag collapsed the sidebar (A0422). No static narrow frame. |
| Little Arc | No small standard window appeared |
| Library / Home view | Home was hovered (F0027) but not opened |
| Site Control Center popover | Only its tooltip (F0033–F0034) |
| Light macOS appearance | Not done |
| Exact animation durations | Frame spacing is about 0.47 s. Only progress points exist (§10). |

## 3. Sidebar tab rows

Frames: rows are `[0, y, W, 41]` and the button is `[0, y, W, 40]` (`runtime-observations.md` §1.1). W = sidebar width.

| State | Fill frame (pt) | Fill | Radius | Evidence |
|---|---|---|---|---|
| Hover, light-content Space (Space 1) | `[8, y+2, W−16, 36]` | black, a ≈ 0.048 (C/B = 0.951/0.954/0.952 on R/G/B) | 12 continuous. Row insets 6.3, 4.8, 3.6, 2.7, 2.0, 1.4, 1.0, 0.6 match the 12 continuous curve from row 1 (6.21, 4.65, 3.50, 2.61, 1.90, 1.36, 0.92, 0.64). Corrected 2026-10-26: see the corner note below this table | F0013 vs F0012, F0031 vs F0030 (New Tab row, same values) |
| Hover, dark Space (Space 4, no theme) | `[24, y+2, 196, 36]` for a folder child (indent 16) | white, a ≈ 0.10 (`#3B3A4C` on `#262538`) | same shape | F0079 |
| Selected, light-content Space | `[8, y+2, W−16, 36]` | `#F6EBE7` opaque look. Closest token: the Space's `light.background` `#F6EAE4` (guess). Not a white overlay: a white fit gives a = 0.62 / 0.81 / 0.82 per channel. | same as hover | F0014, Today row F0066 |
| Selected shadow (light) | below the fill | darkening 14% at 1 px below, 5.5% at 2 px, 2% at 3 px. 1% at 1 px above. 1–2 levels at the sides. guess: black ≈ 0.2, blur ≈ 1.5, y +1. | | F0014 rows 240, 277–279 |
| Selected, dark Space | `[8, y+2, 212, 36]` | white, a ≈ 0.20 (`#51505F` on `#272538`) | | F0084 (Today row) |
| Selected, dark-content theme (olive, grain) | `[16, y+2, …]` | white, a ≈ 0.20 (noisy because of grain) | | F0161 |

Corner note (2026-10-26): selected-row corners were re-measured against Core Animation renders (`CALayer` at 1x, `cornerCurve .continuous` and `.circular`) and per-row edge profiles. Session 2 (default dark theme): 14b/0014 fits 12 continuous with coverage RMS 0.046 (11: 0.075; 10: 0.128; 12 circular: 0.056); 03/0001 gives 0.024 (11: 0.070; 10: 0.127); 16/0004 gives 0.045. Session 1 gives the same result: F0015 and F0066 (themed light content) 0.029, and F0084 (dark Space) 0.024, with 11 at 0.070–0.091 and 10 at 0.127–0.143. Edge profiles agree (RMS 0.04–0.20 px for 12 continuous; 0.39–0.51 px for 11; 0.75–0.86 px for 10). Session 2 item 20 (default theme in macOS Light, low contrast, shadow under the fill) is weaker: 12 continuous 0.116 and 13 continuous 0.113, both better than 11 (0.150) and 10 (0.177). The two sessions do not disagree: both ran on the same AW2726DM display at backing scale 1.0 (`displays.tsv`), and session 1 frames fit 12 when the corners alone are measured. The earlier "radius 10 continuous" in `docs/design.md` §2.2 came from the sidebar comparison loop, which samples element centers and does not isolate corner pixels (derived). The row-by-row insets recorded here before this note ("≈ 12 circular fit") already pointed at 12; only the curve label changes. Method notes and scripts stay in `.re/tooltip-radius/` (local only).

Row controls:

- **Close button** on hover and on the selected row: `[189, y+7, 26, 26]` (AX id `closeButton`, F0013, F0019, F0014). Its right edge is 4 pt inside the fill. The title frame shrinks from 168 to 146 wide while it shows (F0014).
- **Pinned selected row** shows a horizontal bar glyph ("—") in the close slot, not "x" (F0014 crop). guess: "reset to pinned URL / unload" (`features-core.md`).
- A pinned tab whose page moved away from its saved URL shows a "/" between icon and title (A0414, folder child). guess: the "navigated away from pinned URL" mark. Measured on F0090 and F0101 (depth 1): a 2 pt stroke about 14.5 pt tall (rows y+12 … y+26), about 8° from vertical (center x 57 at the top, 55 at the bottom), peak white ≈ 0.30 over the background (`TabCellSlash`). The title moves 2 pt to the right (AX title x 61 instead of 59).

Sidebar URL field hover: with the pointer on the field (F0033, the Site Control button), the whole field fill darkens from `#D99273` (F0032) to `#CF8B6F` over the background `#E49978`, at the same frame `[8, 46, 212, 36]`. That is the catalog token `SidebarItemHoveredBackground` (`#0E0F10` at 0.10; predicted `#CF8B6E`) instead of the resting `SidebarItemBackground` (0.05).

Sidebar URL field with a page loaded (F0014): the field text becomes the host (AX `commandBarPlaceholderTextField` `[20, 55, 196, 18]`, no magnifier). Two buttons sit at its right end: Copy Current URL `[158, 49, 30, 30]` and Site Control Center `[186, 49, 30, 30]`. They come and go between frames (F0019, F0035, F0123). guess: they show only while the pointer is over the sidebar top.

## 4. Favorite tiles

| State | Measured | Evidence |
|---|---|---|
| Selected tile | Fill covers the tile frame (65.33x47). Fill `#F7E8E2` (like the selected row). Shadow: 1–2 px soft below (diff 13 → 4 → 0), about 1 px at the sides. Corner shape as in `runtime-observations.md` §1.3. | F0016 vs F0013 |
| Hover | not captured | |

## 5. Toolbar, bottom bar, tooltips

Hover fills (Space 1, light content):

| Control | Fill frame | Fill | Radius | Evidence |
|---|---|---|---|---|
| Sidebar toggle (toolbar) | `[77, 7, 32, 32]` = the button frame | black a ≈ 0.067 | ≈ 6 (insets 4.0, 2.1, 1.2, 0.6, 0.4) | F0024 vs F0023 |
| Home (bottom bar) | `[8, 1353, 32, 32]` | black a ≈ 0.07 | ≈ 6 | F0027 vs F0026 |
| Space switcher item | `[46, 1353, 34, 32]` (item frame inset by 1) | black a ≈ 0.07 | ≈ 6–7 | F0028 |
| Plus (bottom bar) | `[188, 1353, 32, 32]` | black a ≈ 0.07 | | F0030 vs F0031 |

guess: dark Spaces use white at a similar alpha (rows use 0.10).

**Tooltips** are Arc's own windows (layer 25, AX subrole `AXUnknown`, a hosting view with static text), not system tooltips.

| Property | Value | Evidence |
|---|---|---|
| Shape | Capsule. Ends are full half-circles (radius = height / 2). | F0029 corner coverage |
| Height | 27 pt for one line. 42 pt with a second line. | F0025, F0029, F0033; F0021 |
| Fill | The Space's `light.title` color, opaque (`#320E00` in themed Space 1, exact match). Default theme (no stored palette): `#0A0D4F` in the dark theme (measured 2026-10-26; see the fill note below) | F0021, F0025, F0029, F0033; S2 14b/0024, 03/0010, 03/0014, 19/0025 |
| Text | Light, tinted. About 13 pt (AX text frames 15 pt tall). guess: Medium. | `ax.json` of the tooltip windows |
| Second line | "Double-click to rename" on tab rows, dimmer, 14 pt frame | F0021 |
| Shortcut | Keycaps after the label, e.g. "⌘" + "[" or "⌃" + "2". Each key is its own text (13 pt frame) on a small rounded cap tinted with the Space color. | F0025, F0026, F0029 |
| Window | Capsule plus 33 pt of shadow margin on each side (window 93 pt tall for a 27 pt capsule). Shadow: soft, wide. | `windows.tsv`, F0029 |
| Placement | Toolbar tooltips below the button. Bottom-bar tooltips above the bar. Row tooltips beside the pointer. | F0025, F0029, F0021 |
| Animation | Fade out seen (F0026 is half transparent) | F0026 |

Fill note (2026-10-26): the fill follows the Space theme, not a fixed color. Session 1 themed Space 1 (sidebar `#E59878`): the capsule interior's main color, converted from the embedded display profile to sRGB, is `#320E00` in F0021, F0025, F0029, and F0033. That equals the Space's stored `light.title` (`runtime-observations.md` §3.3). Session 2 default dark theme (sidebar `#252538` at the toolbar, `#272538` below; both test Spaces had no `windowTheme`, §20.0): the same method gives `#0A0D4F` exact in 14b/0024 ("Adjust Tab Volume"), 03/0010 ("Go back"), 03/0014 ("Reload this page"), and 19/0025 (Little Arc window). Fading frames do not give the fill: F0026 is half transparent (above), and S2 03/0015 reads `#1D1D5A` in between. The value agrees with the link status bubble in the same default dark theme (`#0A0D4F`, S2 04/0021 and 0033; 4,910 exact pixels in each frame, re-counted 2026-10-26). It also fits the decoded palette math: `light.title` is `shadedDark` @0.30 over black and `dark.backgroundExtra` is the same color @0.15 over black (`design-tokens.md` §6.5), so the second role is half of the first; the mini player card fill in the same frame 14b/0024 reads `#050627`, half of `#0A0D4F` within one level per channel (derived). No tooltip window exists in session 2 item 20 (default theme in macOS Light) or in item 17 (the one themed session 2 Space), and no other themed Space has a tooltip capture, so the same fill in macOS Light is a guess from the `light.title` role. Confidence: fact for the default dark theme and for themed Space 1; the `light.title` rule for other themes is derived from those two cases. Scripts stay in `.re/tooltip-radius/` (local only).

## 6. Today section

| Element | Measured | Evidence |
|---|---|---|
| Divider row | AX row `[0, y, W, 17]` between the last pinned row and "New Tab" | F0066 AX |
| Divider line | 1 pt at row y + 7, x 18 … W − 19 (18 pt inset each side). Black a ≈ 0.15 (C/B 0.852 / 0.850 / 0.854). | F0066, y 656 |
| "Clear" control | Shows while the pointer is near the divider. The line then ends at x ≈ 162. A down arrow (AX `[170, y+3, 12, 9]`, desc "arrow pointing down") and the label "Clear" (AX `[182, y, 29, 15]`). Label ink 27x8: about 11 pt Semibold. Color black a ≈ 0.3. | F0041 crop, AX of F0079 |
| Order | Pinned rows, divider row, "New Tab" row, Today tabs | F0066 AX |
| Today rows | Same 41 pt rows and states as pinned rows. The newest tab is at the top, right under "New Tab" (guess from one session: each new tab appeared there selected). | F0066 |
| "New Tab" row during Cmd+T | Shows the selected fill (`#F6EBE9`) while a Cmd+T command bar is open. Not with Cmd+L. | F0040, F0043, F0058, F0061, F0063 vs F0049, F0064 |

`runtime-observations.md` §1.1 says the divider is not drawn when Today is empty. That holds: it appears with the first Today tab (F0041).

## 7. Folders and the split row

| Element | Measured | Evidence |
|---|---|---|
| Folder row | Normal 41 pt row. Folder glyph instead of a favicon. The glyph is a closed folder when collapsed and an open folder when expanded. No chevron. Title 14 pt Semibold (ink 70 = SF 14 Semibold). Glyph color in Space 4 `#1E29FF` (guess: the Space accent). | F0072, F0079 |
| Indent step | 16 pt per level. Child button `[16, y, W−16, 40]`, icon x 33, title x 59. | F0079 AX |
| Child title | 14 pt Regular (ink 97 vs 98) | F0079 |
| Expand animation | Children slide down from under the folder row while the rows below move down. Labels are visible during the slide. Done in < 0.5 s. | A0237, A0256 |
| Collapse animation | Labels fade first. Icons slide up into the folder row. Done in < 0.5 s. | A0239 |
| Expand and collapse duration | The sidebar changes for 0.20–0.24 s per expand or collapse (4 of 4, 9–10 video frames each). Open's `Motion.rowStructure` is 0.22 s. | §13.1, `21-motion.mov` |
| State on disk | `StorableWindows.windows[].expandedItems` gains `[folderId, {expanded:{}}]` (see `data-model.md`, "Archive and session files") | |
| Split row (in a folder) | One 41 pt row with two cells: icon at x 33 and x 129, titles at x 61 and x 157, each 56 pt wide and truncated. A thin vertical divider between the cells. | F0079 AX and crop |
| Split row (Today, selected) | The selected fill is a card `[8, y+2, 212, 36]` (white 0.20, `#50505F` on `#272438`). Inside it each pane has its own cell, 4 pt inside the card and 4 pt apart: `[12, y+6, 100, 28]` and `[116, y+6, 100, 28]`, corner ≈ 8 (row-by-row edge profile), white 0.07 over the card (`#5D5C6A`, `TabCellChildBackground`). No divider. Icons x 17 / 121, titles x 45 / 149, 64 wide, tail-truncated with "…". | F0081 AX and pixels |
| Focused pane in the row | Not marked. Focus was on pane 2, yet the two cells are pixel-identical apart from their outer edges, and the titles have the same color (`#DBDBDE` / `#DADADD`). F0082 and the fast frames A0264–A0271 (the whole split, focus never moved) show the same. The `TabCellBackgroundContentVisible` guess for the focused cell does not hold in this capture. | F0081 pixel diff of the two cells |

## 8. Space header

| State | Measured | Evidence |
|---|---|---|
| Hover | Fill `[8, 200, 212, 36]`, white a ≈ 0.10 in the dark Space. The Space icon is replaced by a collapse chevron ("⌄"). A "…" button shows at the right end. | A0413 vs A0412 |
| Context menu | §15 | |

## 9. Command bar

The command bar is **not a separate window**. It is an overlay inside the browser window (AX `commandBarTextField` and `commandBarSuggestions` are children of the `bigBrowserWindow`). It sits above the web content.

### 9.1 Geometry (window 2216x1394, sidebar 228)

| Part | Frame / value | Evidence |
|---|---|---|
| Panel (outer edge) | x 725 … 1490, y 528 … 866 → 766 x 339 with 5 rows. Centered on the window (center x 1107.5 = 2216 / 2), not on the web content. | F0049 vs F0047 |
| Corner | ≈ 12 pt. The edge curve spans ~18 px, so guess: a continuous corner. | F0049 corner dump |
| Border | 1 px outer black (a ≈ 0.94) and 1 px inner white (a ≈ 0.23) | F0049 row/column profiles |
| Fill | `#181819`, opaque in practice (same over a dark page and over photos) | F0049, F0040 |
| Shadow | Very soft and wide. Darkening at the edge: sides 25%, top 15%, bottom 32%. It reaches ≈ 100 pt at the sides and ≈ 120 pt below. Fit: black a ≈ 0.55, Gaussian σ ≈ 40, y offset ≈ +15 (fit hit the σ limit; treat as approximate). No page dimming outside the shadow. | F0049 vs F0047 |
| Input row | y 530 … 591 (62 pt). Leading icon `[748, 551, 18, 18]`. Text field `[778, 548, …, 23]`. Trailing: info button `[1444, 547, 26, 26]`, or the hint group `[1256, 548, 213, 24]` while typing. | F0049, F0063, F0040 AX |
| Separator | 1 px at y 592, white a ≈ 0.07 (`#2F2F30`) | F0049 |
| List | Table `[732, 596, 752, …]`. Rows `[733, y, 750, 50]` (50 pt pitch). The scroll area shows at most 5 rows (`250` tall) even when the table holds 10. Bottom padding ≈ 16 pt. | F0040, F0049 AX |
| Row content | Icon 16x16 at row x + 16, vertically centered (row y + 17). Title at row x + 43. Subtitle follows the title after " — ". | F0049 AX |
| Selection | Fill `[row x+2, row y+2, 746, 46]`. Radius ≈ 6–8, continuous-looking. Color `#9A4B26` = the Space's `dark.focus` (`#B85727` a 0.8075) over `#181819`; predicted `#994B24`. | F0049 |
| "Switch to Tab" accessory | Label at `[1351, y+16, 86, 18]` and a 21x21 arrow image at `[1446, y+14]`. Brighter on the selected row. | F0063 AX |

### 9.2 Type and color

| Text | Font | Color | Evidence |
|---|---|---|---|
| Input text and placeholder | SF Pro 18 Medium (ink 95 = 18 Medium for the typed text; 179 = 18 Medium for "Search or Enter URL…") | text white; placeholder grey | F0040, F0063 |
| Row title | 13 Medium (ink 44 / 109) | white a ≈ 0.8 (`#D1D1D1`); white on the selected row | F0049 |
| Row subtitle | 13 Medium (ink 238) | `#646465` | F0049 |
| Caret | system accent blue | | F0040 |

### 9.3 Cmd+T, Cmd+L, typing

| Mode | What shows | Evidence |
|---|---|---|
| Cmd+T, empty | Placeholder "Search or Enter URL…", magnifier icon, info button. Suggestions: open tabs with "Switch to Tab →". The sidebar "New Tab" row shows the selected style. | F0063 |
| Cmd+L | The current URL fills the field and is selected. Leading icon = the page favicon. Row 1 = the current page. No "New Tab" highlight. | F0049 |
| Typing | Leading icon = globe. No inline completion in this frame: the AX value lags the image by one key (corrected 2026-10-25, `commandbar-completion.md` CC-8). Inline completion shows in F0043 and F0062: the completed part is selected (CC-1…CC-5). Trailing hint "Search <default engine> [Tab] or [Space]" with keycaps. Rows: URL matches ("host — host"), a search row (magnifier), history, and open tabs with "Switch to Tab". | F0040 |
| Return (Cmd+T) | A new Today tab appears right under "New Tab" and is selected. | F0041–F0042 |
| New window (Cmd+N) | Opens with the command bar already open | F0098, F0157 AX |
| Open/close animation | AX shows a shrunken field (width 2) and table (98x52) mid-animation. guess: scale from the center with a fade. | F0060, F0064 |
| Open/close timing | No animation on screen: in 4 of 4 Cmd+T and Esc events the bar appears or disappears between two video frames 17–39 ms apart, with no frame in between. The same recording has 3–9 frames inside each 0.1–0.24 s motion (§13.1). The shrunken AX frames above are a layout state, not a visible scale. | §13.1, `21-motion.mov` |

## 10. Space switching

| Property | Measured | Evidence |
|---|---|---|
| What moves | The Space page (header + tab list) slides horizontally. Favorites, toolbar, URL field, and bottom bar stay fixed. | A0222, A0227 |
| Direction | Going to a Space on the right moves content left (the new page enters from the right). Going left moves content right. Pages are adjacent: the old and new page offsets differ by exactly W (228). | A0222: new page at +79, old at −149 |
| Multi-step | Space 3 → Space 1 slides 2 pages (456 pt) and passes through Space 2 | A0227: target at −54, Space 2 at +174 |
| Background | The window gradient cross-fades between the two themes | A0222, A0227 |
| Web content | Swaps at once to the target Space's last tab (or empty state). It does not slide. | A0222 |
| Progress pairs | A0222: slide 0.65, fade 0.53. A0227: slide 0.88, fade 0.77. The slide leads the fade. guess: ease-out or spring slide plus a linear or ease-in-out fade over the same time. | `fade()` / shift-match in the analysis scripts |
| Duration | Not measurable at 0.47 s spacing. 2 of 5 switches were caught mid-flight, so the visible part is about 0.2–0.35 s (guess). | A0221–A0233 |
| Duration (video) | The sidebar changes for 0.28–0.29 s (2 switches, 11 frames each); the web content swaps in one frame. Only 2 of the 4 clicks switched. | §13.1, `21-motion.mov` |
| Window title | Becomes the Space name, or the selected tab title | `windows.tsv` |

## 11. Split View

| Property | Measured | Evidence |
|---|---|---|
| Panes | Two panes `[228, 10, 984, 1374]` and `[1222, 10, 984, 1374]`. Gap 10 pt. Outer insets are the same as the single panel (10 pt top, right, bottom). Pane width = (content width − 10) / 2. | F0081 AX |
| Pane top bar | Each pane has its own 32 pt bar `[x, 10, 984, 32]` (AX `topBarPanel`). Back `[x+5, 14, 32, 24]`, forward `[x+42, …]`, reload `[x+79, …]` (back/forward pitch 37). Host text centered with a 24x24 copy-link button before it. At the right: Site Control Center `[x+879, 12, 32, 28]`, Split View Menu `[x+915, 14, 32, 24]` (id `square.split.2x1`), Close pane `[x+947, 14, 32, 24]` (id `xmark`). The host group is centered on the bar: copy button 24 · 3 · host text · 3 · an empty 24 pt AX button (focused pane: x+425 / x+452 / x+535; unfocused: x+443 / x+470 / x+517). The unfocused pane shows back and forward (disabled here), the copy button, its host, and Close; it has no reload, Site Control Center, or Split View Menu. | F0081 AX and pixels |
| Bar color | Takes the page's own background color (lavender page → `#DEDEFA` bar, white page → white bar). The lavender is not the pixels under the bar (`#A8AAC7` ± 13 there, page content), so it is a color the page reports. guess: the page's background or theme color. | F0081 |
| Web area | Starts below the bar: `[x, 42, 984, 1342]` | F0081 AX |
| Focus ring | 2 pt solid line inside the focused pane's edge, following its corners. Color `#3139FF` in the untheme'd Space 4 (guess: the Space accent). | F0081 rows 10–11, 1382–1383, cols 1222–1223, 2204–2205 |
| Pane corner | ≈ 6 pt (same as the single panel) | F0081 corner map |
| Sidebar | The URL field shows the focused pane's host. The split shows as one row with two cells (§7). The sidebar toolbar keeps only the toggle: back, forward, and reload are gone from AX and pixels while the split is selected (F0081, F0082) and come back with a tab (F0080, F0084). | F0081 |

## 12. Peek

| Property | Measured | Evidence |
|---|---|---|
| Kind | In-window overlay, not a window | F0090 AX |
| Frame | Web area `[427, 12, 1590, 1370]`. Width = 80% of (window width − sidebar width) = 0.8 × 1988 = 1590, centered in x 228 … 2216 (center 1222). Top and bottom 2 pt inside the content panel. | F0090 AX |
| Corner | ≈ 6–7 pt | F0102 corner dump |
| Chrome | No toolbar. Three round buttons outside the right edge: Close (`confirmCloseModal`, "Close"), Expand (`openInSpaceExpander`, "Enter Full Screen"), Split (`openInSplit`, "Square Split Two By One"). AX frames `[2030, 21, 35, 33]`, `[2030, 64, 35, 33]`, `[2030, 107, 34, 32]`: 13 pt right of the panel, 43 pt pitch. Drawn as dark circles ≈ 33 pt with a white glyph. | F0090 AX, F0102 pixels |
| Backdrop | The dim covers the window background, the margins, the page, the sidebar's toolbar row, and its bottom bar. It does not cover the URL field, Favorites, or the Space list: their text keeps its color (row titles `#D7D9F8` in F0090 and `#D8D9F9` in F0101), white 0.55 text only follows its darker background (Space title `#9A9AA3` → `#8D8D97`), and white-alpha fills composite over the darkened background (tile and URL field `#222234` = white 0.10 over `#0A0B1E`). Toolbar and bottom glyphs darken with the background (toggle `#A2A3AB` → `#464654`, Home `#9E9AA3` → `#514C5A`). Under the dim, back, forward, and reload draw in the same tone as the toggle (`#444452`–`#464654`) although AX reports them disabled. Background and glyph values fit a multiply of ≈ 0.165 in linear light (R, G), not one sRGB alpha. Background fit against F0122: about 70% of a dark, theme-tinted color (≈ `#0E0019` in Space 4). F0089 (loading) and F0108–F0114 (pointer over the Peek buttons) show the Peek without the dim. guess: the dim fades in after load and lifts while the pointer is on the buttons. | F0090, F0101, F0102, F0108, F0122 |
| Shadow | Light, ≈ 16 pt wide on the sides (90 → 78 lum at the edge) | F0090 row profile |
| Loading | A black panel with the three buttons shows before the page paints | F0089 |
| Persistence | Peek belongs to its source tab. Selecting another tab hides it. Selecting the source tab again shows it. | F0101 → F0102 |
| Sidebar mark | The source row shows the Peek page's favicon (AX image `[W−35, y+11, 18, 18]`, 16 pt ink) on a 24 pt plate `[W−38, y+8, 24, 24]`, corner ≈ 6, white ≈ 0.07 (`TabCellChildBackground`: `#373647` on `#272438`; `#343343` on the row fill). The title then ends at W−39 (AX width 128 from x 61). The badge stays while another tab is selected and the Peek is hidden (F0101), and goes with the Peek (F0115). | F0089–F0114 AX, F0090 and F0101 pixels |
| Source row fill | While its Peek shows, the source row draws white 0.10 instead of the 0.20 selected fill (`#232234` over `#0A0A1D`, F0090, F0102). Without the dim it is the usual 0.20 (F0089, F0108). | F0090, F0102 |
| URL field and toolbar | The URL field shows the Peek page's host; back and forward follow the Peek's history (AX disabled). | F0090 AX |

## 13. Sidebar hide, hover-reveal, and width

| Property | Measured | Evidence |
|---|---|---|
| Hidden layout | Web content `[10, 10, W−20, H−20]` (10 pt on every side). No traffic lights or toolbar are visible. | F0128 AX, A0439 |
| Inactive window, default dark theme | The window background darkens when Arc is inactive: sidebar `#272538` → `#0B0B1C`, top margin `#252538` → `#0B0B1D`, right and bottom margins `#352337` → `#19091D`; about 26–28 levels down on every channel, like losing a white layer of ≈ 0.11 (fit 0.115 / 0.107 / 0.123 on R / G / B). The reveal card's translucency explains it: the window background is the same blend as the card, over a near-white backdrop while active and over black while inactive (§13.1). Open's default theme does not change yet (`docs/followups.md`). | session 2, 03 frames 0003 vs 0016 (sRGB) |
| Hint toast | First hide shows a toast at the window's top-right: "You can use [⌘S] to easily show and hide your Sidebar!". Dark, Space-tinted rounded rectangle with a keycap. Own window 600x600 (layer 0), anchored at the window's top-right. Gone after about 6 s. Session 2 showed no hint on any path (toolbar button, Cmd+S, View > Hide Sidebar); guess: it shows once per install and had already shown. | F0128–F0131, A0438–A0447; session 2 item 4 (`s2-notes.txt` 10:11:20) |
| Hover-reveal | A floating card `[5, 5, W_sidebar, H−10]` (here 500 x 1384): 5 pt from the window edges. Corner ≈ 10 pt. 1 px light stroke (white a ≈ 0.25). Small shadow (7.5% at the edge, 0 by 8 pt). The card shows the Space background and all sidebar content, with the traffic lights at its top. | F0130 pixels and AX |
| Card corner | The card's edge per pixel row at all four corners (the stroke's outer edge, F0129 against F0128) fits a circular corner of radius 11.75 (RMS 0.08 px over 8 rows); a continuous corner fits worse (radius 11.5, RMS 0.22 px). derived: circular, radius 12. The "≈ 10" above was a visual estimate. | F0129 vs F0128, edge measure in `tools/e2e/engine_e2e.py` `card_edges` |
| Card stroke | The outermost pixel row and column inside the card frame (x 5 and 504, y 5 and 1388), `#696875` over the card fill `#272739`: white 0.30 over the fill (0.30–0.32 per channel), the `SidebarBorderColor` token. Nothing outside the frame is lighter. | F0129 sRGB rows y 700, x 250 |
| Card shadow | The same on all four sides, so no offset. Against F0128 (the same view without the card), the page right of the card is 7.5 % darker at 0.5 px, 5.9 % at 1.5, 4.3 % at 2.5, 3.1 % at 3.5, 2.0 % at 4.5, 1.6 % at 5.5, 0.8 % at 6.5, 0.4 % at 7.5, and unchanged from 8.5 px; above, below, and left of the card the window background is 8 % darker at 0.5 px. derived: a black shadow, peak ≈ 0.17, Gaussian σ ≈ 4 pt. | F0129 vs F0128 luminance ratios |
| Traffic lights | Hidden while the sidebar is hidden (F0128 pixels; AX still lists them, at the card position). On the card at `[17, 21]`, `[40, 21]`, `[63, 21]`, 16 pt: the card offset (5, 5) plus the anchored frames. | F0128, F0129 AX and pixels |
| Reveal zones (code) | Arc's `WindowHoverTracker` class (fields `offLeftEdgeZoneRect`, `windowTrafficLightZoneRect`, `sidebarZoneRect`, lazy `innerLeftEdgeZoneRect`, `innerTopLeftEdgeZoneRect`, `windowBounds`) registers named regions with a region tracker: "WindowTrafficLightRegion", "InnerLeftEdge", "OuterLeftEdge", "ArcSidebar", and "ArcWindow". A hover-state struct keeps one state per region (`sidebarHoverState`, `floatingSidebarOuterLeftEdgeHoverState`, `windowTrafficLightRegionHoverState`, `innerLeftEdgeHoverState`, `innerTopLeftEdgeHoverState`, `windowHoverState`). | `__swift5_fieldmd` records; class descriptor `0x103c9cda4`; region names as inline string immediates in the functions below |
| Reveal dwell | Each region is registered with a delay: 0.15 s (`0x3fc3333333333333`) for the traffic-light region, the inner left edge, the sidebar, and the window; 0.16 s (`0x3fc47ae147ae147b`) for the outer left edge. | registration function `0x100030670` (`llvm-objdump`, `.re/bin/Arc-arm64`) |
| Inner left edge zone | x 0 … 0.6 u while the pointer is elsewhere in the window; x −2 u … 1.5 u (widened) once the pointer is in the zone or outside the window. Full window height (minus 16 pt when a flag is set). u is one value read from the window view store (two doubles; this zone uses the second). guess: u = the 10 pt content inset. | `0x10002fbd4` (`fmul` by 0.6 = `0x3fe3333333333333`; `fadd d0,d0` and `fmul` by 1.5), `0x100030c50` (height, 16.0) |
| Outer left edge zone | Left of the window: 250 pt wide while the pointer is in the window or the zone, 50 pt when it comes from elsewhere. | `0x1000301f8` (250.0 = `0x406f400000000000`, 50.0 = `0x4049000000000000`) |
| Top-left zone | 40 pt wide at the window's top-left corner (40.0 = `0x4044000000000000`), from 1.5 u above the top edge to 2 u below it while the pointer is in the window (same u, first double). | `0x10002fed0`, `0x10002ff7c` |
| Traffic-light zone | From the window buttons' frames to about 50 pt below the top (adds 50.0, keeps at least 10.0). | `0x100030390`, `0x100030564` |
| Card slide | Session 1 could not time it: A0439 (hidden) and A0440 (card) are 1 s apart. The session 2 video does: in ≈ 0.14 s with a 3 pt overshoot, out in ≈ 0.10 s (§13.1). `WindowLayoutController` holds a lazy `sidebarTransformAnimation` (`CABasicAnimation`), so the card likely moves by a layer transform (guess). | field names; A0439–A0440; `21-motion.mov` |
| Toolbar button | Its AX desc changes from "Hide sidebar" to "Lock sidebar" while the card shows | F0128, F0131 |
| Hide animation | The sidebar slides out to the left as a card while the web content grows. Cmd+S hide and show each take ≈ 0.1 s; the show starts ≈ 0.29 s after the key (§13.1). | A0436–A0438; `21-motion.mov` |
| Width | 228 → 500 in one drag. `sidebarWidth` = 500 on disk. guess: 500 is the maximum (the user aimed for the widest stop). | F0126–F0127, A0424 → A0431 |
| Minimum | Not captured. A0422 shows the sidebar sliding out during the narrow drag. guess: dragging below the minimum hides the sidebar. | A0422 |
| Other windows | A new window (Cmd+N) also uses 500 | F0157 AX |

### 13.1 Capture session 2: reveal card, hide, and motion (2026-10-26)

Sources (raw frames stay local; never committed):

- `sessions/20261026-101324-05-reveal-card/`: frames 1.4 s apart, 1x, window 1728 × 1084, macOS Dark. Both Spaces ("Capture A" and "Capture B") use the default dark theme. Their anchored sidebars are equal to the level (frames 0001 and 0043). Capture A shows a white page, Capture B a dark page (`#101418`).
- `sessions/20261026-101007-04-hide-hint/`: 0.2 s was requested, but frames came 0.45–0.6 s apart.
- `video/21-motion.mov`: the window region, 3054 frames over 95 s at a variable rate (`ffprobe` `pts_time`; 17–47 ms apart during motion). Positions come from the first white pixel on row y 600. The video clock is aligned to `s2-notes.txt` on the four Cmd+T and Esc responses (t0 = 10:38:40.52 ± 0.02 s). Clicks show a constant ≈ 0.72 s lag after their note, so the dwell and exit delays cannot be timed.

Still frames were converted from the display profile to sRGB (§7 method). The video gives positions and times only, not colors.

| Property | Measured | Evidence |
|---|---|---|
| Buttons on the card | Centers (25, 29), (48, 29), (71, 29), ±0.05 px: the anchored centers + (5, 5). At rest: `DimmedWindowControls` at 0.327–0.331 over the card fill, with the colored rings (`#5F3F4B` / `#5F543C` / `#3B5540`) because the window is active. With the pointer on them: the system colors and glyphs. | 05 frames 0009, 0021, 0029, 0034; 0018 (hover) |
| Card fill is translucent | Over the white page, the card is 1.5–2 levels lighter than the anchored sidebar. Over the dark page it is `#0E0B20`, 26 levels darker. Where the page under it has a lighter band (y 680–940), the card is lighter there too. Fit over both Spaces (x 120–220, y 420–1040): card = k + a × blur(page), a = 0.115 / 0.115 / 0.113 (R / G / B), k = (14.4, 9.2, 29.2), Gaussian σ ≈ 25 px, RMS 1.06 levels (2.29 at σ 5; 3.35 with no blur). derived: ≈ 0.885 × a tint `#100A21` + 0.115 × the page under the card, blurred. | 05 frames 0009 vs 0006 (A), 0029 vs 0037 (B) |
| Window background, same blend | Inactive window, sidebar rows y 440–1000: (12.4…17.0, 9.9, 29.0), equal to k within about 1 level, so the blend over black. Active: k + 0.115 × ≈ `#E6EEF1`. Strings in the Arc binary (`strings -a`): `WindowBackgroundTranslucencyViewAppKit` (`WindowBackground/WindowBackgroundTranslucencyViewAppKit.swift`), lazy `behindWindowBlurView`, `translucencyWashView`, `translucencyView`, `blurView`, and `Arc.FloatingSidebarBackgroundView` (`Arc/FloatingSidebarBackgroundView.swift`). Which class owns which view is not known. guess: the active backdrop is the desktop behind the window, seen through a behind-window blur, and macOS drops it while the window is inactive. No capture with a different desktop exists. | 03 frames 0003, 0016; 05 frames 0001, 0043 |
| "Darkens toward its bottom" | Not a gradient. The card shows the page under it. Over the white page the card's bottom is lighter than its top (it follows the theme). Over the dark page the lighter band follows the page's footer. The F0129 bottom (`#180E3A`) sat over dark page content. | as above; `docs/design.md` §16.4 |
| Card hide | Present in 0036 (pointer far right), gone in 0037. No timing at this frame spacing. | 05 frames 0036–0037 |
| First-hide hint | None on any path (above). Each hide and show is complete in the next frame (< 0.46 s). No frame shows a transition. | 04 frames 0001–0094 |
| Cmd+S hide | 3 of 3: the page edge goes 228 → 10 in 0.095–0.122 s, from the last frame at rest to the first frame at the end (228, 122, 38, 14, 10 at 16.260, 16.307, 16.332, 16.357, 16.382 s). It starts with the key (0.02–0.03 s before the note, on the Cmd+T alignment). Spring fit: response 0.09–0.16 s, damping 0.76–0.92, RMS ≤ 1.1 px. | `21-motion.mov` 16.26, 20.61, 24.93 s |
| Cmd+S show | 3 of 3: 10 → 228 in 0.091–0.096 s (fit 0.10–0.12 s, damping 0.84–0.94). Motion starts 0.28–0.29 s after the key note in all three; nothing in the window changes before that. Cause not known. guess: while the sidebar is hidden, the key goes to the page first. | `21-motion.mov` 18.76, 23.08, 32.41 s |
| Card in | The card's right edge goes 10 → 236 in 0.137 s, 3 px past its rest position (233), then back to 233 by 0.242 s (10, 26, 84, 162, 189, 225, 236, 235, 234, 233). Spring fit: response 0.164 s, damping 0.86, RMS 2.2 px. | `21-motion.mov` 26.63 s |
| Card out | 233 → 10 in 0.100 s (233, 203, 117, 38, 10). | `21-motion.mov` 29.50 s |
| Space switch, folders, Cmd+T, toast | §10, §7, §9.3, §16 rows marked `21-motion.mov`. | |

Each duration is ± one frame (17–47 ms). The spring fits rest on 4–10 points, so they are ranges, not tokens.

## 14. Theme editor

Opened from the Space menu, "Edit Theme Color…" (F0136 → F0137).

| Part | Frame / value | Evidence |
|---|---|---|
| Container | AX `AXPopover` `[500, 35, 382, 534]`, attached to the sidebar's right edge near the top. Own window 5401 (382x534). Content `[513, 48, 356, 508]` (13 pt inset). Translucent grey material, ≈ 16 pt corners (visual). | F0137 AX, crop |
| Mode buttons | 3 × 32x32 at x 635 / 675 / 715 (pitch 40), y 80: sparkles, sun, moon. guess: auto, light, dark text appearance. | F0137 AX |
| Color pad | `DotGrid` image `[521, 56, 340, 340]` with a draggable knob (≈ 44 pt white ring around the color) | F0137 |
| Remove / Add | 32x32 at `[655, 348]` and `[695, 348]`, drawn as "−" and "+" | F0137 AX |
| Presets | Previous / next page buttons 32x32 at y 412. Swatches 24x24 at y 416, pitch 29.5, 9 per page. AX names show the sets `ColorPickerBrand1…`, `ColorPickerPastel1–9`, `ColorPickerDrab1–9`, `ColorPickerGreyscale1–9`. | F0137 AX |
| Intensity slider | `AXSlider [531, 472, 224, 56]`, drawn as a sine-wave track with a capsule thumb | F0137 |
| Grain dial | "Cycle noise texture" button `[771, 460, 84, 36]` + `AXSlider [771, 504, 84, 36]`, drawn as a knob in a dotted ring | F0137, F0138 (turned) |
| Open animation | Window 253x354 (66%) one frame before full size: scale-up | A0465 → A0466 |
| Result on disk | Space 4 gained `background.single._0.style.color._0.blendedSingleColor` with `noiseFactor` 0.45 and `contentOverBackgroundAppearance: "dark"` (see `data-model.md`) | session1 `StorableSidebar.json` |

Added 2026-10-25 from the same frames (sRGB-converted pixels; content coordinates are relative to the content frame origin `[513, 48]`) and from code constants (`llvm-objdump` on `.re/bin/Arc-arm64`):

| Part | Measured / decoded | Evidence |
|---|---|---|
| Arrow | None visible. The panel's left edge sits on the sidebar's trailing edge (x 500 = `sidebarWidth`), top 35 pt below the window top. | F0137 crop |
| Pad plate | Content `(8, 8, 340, 340)`. White ≈ 0.04 over the popover fill. Small corner radius (≈ 3 pt, visual). Dot grid: pitch ≈ 4.25 pt, dots ≈ 1 pt, white ≈ 0.2. | F0137 rows y 150 / x 560 |
| Mode buttons | Content `(122, 32)`, `(162, 32)`, `(202, 32)`, 32×32, pitch 40, centered. Selected plate: white ≈ 0.10, radius ≈ 8. Unselected glyphs: white ≈ 0.5. Order: Automatic (sparkles), Light (sun), Dark (moon). Tooltips "Automatic Appearance", "Light Appearance", "Dark Appearance". Icons are looping Lottie files in Arc (`automatic.json`, `sun.json`, `moon.json`). | F0137 AX + pixels; small-string literals at `0x1017b4d60`, `0x1017b4f8c` |
| Knob | 44 pt outer diameter, 5 pt white ring, 34 pt color disc that shows the knob color exactly (`#916500` vs stored `#926400`). | F0137 row through the knob center |
| Pad mapping | Knob center = pad center + unit position × 170 pt. Angle = P3 HSL hue, y down. See `design-tokens.md` §6.5. | F0137: offset (32.5, 31.5), 44.1° |
| Remove / Add | Content `(142, 300)` and `(182, 300)`, 32×32, glyphs `minus` / `plus`. Tooltips "Remove color" / "Add color". | AX; literals at `0x1017b7c6c`, `0x1017b7f78` |
| Preset strip | Previous / next buttons content `(9, 364)` and `(315, 364)`, 32×32. Swatches 24×24 at content y 368, gap 5.5 (pitch 29.5). One page = 9 swatches = 260 pt. Pages step by 265.5 pt. 5 pages, 45 swatches: Brand 1–9, Brand 1–9 again, Pastel 1–9, Drab 1–9, Greyscale 1–9. The previous button is disabled on page 1. Swatch rim ≈ 0.9 × the fill color (1 pt). | AX frames; constants 24, 5.5, 260, −265.5 at `0x1017bbdbc…0x1017bbf40` |
| Intensity slider | Track `(18, 424, 224, 56)` hit area; drawn capsule 224 × 16 pt, white ≈ 0.08. Sine wave stroke ≈ 4.5 pt, wavelength ≈ 37.5 pt, amplitude ≈ 13.75 pt; bright left of the thumb, dim right of it. Thumb: white capsule 24 × 56 pt. Travel 200 pt; thumb center at 0.8075 of travel for the stored 0.8. Tooltip/label "Intensity". | F0137 zoom; literal at `0x1017c5878` |
| Noise dial | Hit areas content `(258, 412, 84, 36)` (button "Cycle noise texture") and `(258, 456, 84, 36)` (slider). Ring of 20 dot slots at an 18° pitch, radius ≈ 32.5 pt, dots ≈ 4.5 pt. Tick: white capsule ≈ 7.5 × 15.5 pt on the ring at angle `noiseFactor × 360°` clockwise from 12 o'clock (0.45 → ≈ 162°; measured ≈ 164°). Dots before the tick are lit. Center disc 40 pt: outline only at noise 0; otherwise it shows the selected texture. Label "Noise". | F0137 / F0138 zoom; constant 18 at `0x1017c2de4` |
| Popover fill | Gray system material: `#797979` over a white page in macOS Dark. | F0137 |

The capture shows only one color and the Automatic mode. Not captured: 2 or 3 knobs, a forced mode, page 2 of the presets, a hovered swatch, and the light system appearance.

## 15. Context menus

All are native `NSMenu` (AX `AXMenu`, items with action `performWithSender:`). Item height 24 pt. Separator height 11 pt. AX also lists one untitled 24 pt item at the end of each menu (guess: a hidden item). AX did not record key equivalents. No shortcuts were visible in the captured menu images. Names in angle brackets are placeholders.

**Today (unpinned) tab** (F0115, window 5378):
Copy Link · — · Open in Split View · Move to ▸ (each Space · — · New Space…) · — · Archive Item

**Pinned tab** (a folder child, F0116, window 5380):
Copy Link · Share ▸ (AirDrop, Mail, Messages, Notes, Open in News, Freeform, Journal, Reminders — system share services) · — · Change Icon… · Rename… · Mute (disabled) · Customize Page… · Edit Pinned Page ▸ (Replace Pinned URL with Current, Edit…) · — · Add Split View · Duplicate · Move to ▸ · — · Remove Pin

**Space** (right-click on empty sidebar space F0117, and on the Space title A0414 / F0136; the same menu):
Change Space Icon… · Rename Space… · Edit Theme Color… · Set Profile ▸ (Default · — · New Profile…) · — · New Folder · Live Folders ▸ (GitHub) · — · Share Space… · Export "<Space>" into Folder ▸ (each Space; the current one disabled) · — · Manage Spaces… · — · Delete Space

**Folder** (F0119, F0134):
Share Folder… · — · New Nested Folder… · Turn "<folder>" into Space · Copy All Links · Copy All Links as Markdown · — · Change Icon… · Rename… · — · Duplicate · Move to ▸ · — · Delete

Not captured: Favorite tile, split row, bottom-bar Space icon. The split-row menu's items and order come from Arc's code instead (`menus-and-hotkeys.md`, "Split row menu").

## 16. Toasts

| Property | Measured | Evidence |
|---|---|---|
| Host | Each toast gets its own borderless window (AX subrole `AXUnknown`, layer 0) with the size and origin of the web content area (here 1706 x 687 at `[W_sidebar, 10]`) | F0142, F0155 |
| Position | Top-right of the web content. Text frame top ≈ 20 pt below the content top. Right inset ≈ 12 pt. | F0142, F0155 AX |
| Shape | Rounded rectangle, radius ≈ 10–12, height ≈ 41–42 | F0142 crop |
| Fill | Space-tinted dark color (`#6E5A2F` with the olive theme). guess: derived from the theme like the tooltip fill. | F0142, F0155 |
| Text | White. "Copied Current URL" ink 131 → 14 Medium or Semibold. | F0155 |
| Variants | Page zoom ("110%", "125%", "100%"). "Copied Current URL" with a Share button (`square.and.arrow.up`, 32.5x27.5, lighter rounded square). | F0142–F0147, F0155 |
| Stacking | Each zoom step opens a new toast window. Up to 4 overlap while older ones fade. | `windows.tsv` A0487 |
| Appear | Scale-up from small (AX text 12x6 mid-animation) | F0144 |
| Timing (Cmd+Shift+C) | Appears over ≈ 0.15 s (7 frames), shows ≈ 4.9 s, fades out over ≈ 0.09 s (5 frames). | §13.1, `21-motion.mov` |

## 17. Windows

| Window | Measured | Evidence |
|---|---|---|
| Cmd+N | New `bigBrowserWindow-<new id>` with the same size, the same Space, and the command bar open. The sidebar width follows `sidebarWidth`. The window was not saved in `StorableWindows.json` after it closed. | F0098, F0157–F0160 |
| Close animation | One frame shows the window 2172x1366 (−44 / −28, ≈ 98%) before it disappears. The same for all three closed windows and for Settings (684x650 → 670x638). guess: Arc scales the window down ≈ 2% and fades it. | A0330, A0362, A0534, A0508 |
| Window-only sidebar | Title "Space 1". Sidebar shows a header "This Window", a selected "New Tab" row, no Favorites, no Space switcher (bottom bar: Home and plus only). Command bar open, selection color indigo (visual estimate, not measured). guess: Blank Window (Ctrl+Cmd+N, `menus-and-hotkeys.md`). It was not in any AX dump. | A0359–A0362 |
| Settings | §18 | |

## 18. Settings window

| Property | Value | Evidence |
|---|---|---|
| Window | 684 x 650, standard titled window, follows the macOS appearance (dark here). Title = the selected tab name. | F0147–F0151, `windows.tsv` |
| Tabs | `NSToolbar`-style icon tabs, in order: <account tab, named after the user> · General · Profiles · Max · Links · Shortcuts · Icon · Advanced. The selected tab has a blue rounded highlight. | A0495–A0507 |
| Layout | Grouped rounded boxes with rows: label left, control right (switches, pop-up buttons, push buttons) | A0499–A0507 |

Rows per tab (labels only; values are user data):

- **Account**: "Arc isn't your default browser." + "Make Arc your default"; a membership card (left); Account (email, "…" menu); "Verify your email…" + "Send Verification Email"; "Sync Sidebar with iCloud" switch; "Arc Sync is replacing iCloud Sync soon!…" + "Switch Now"; "Gift Arc to a Friend" + "Share Arc"; a note about unlocking app icons.
- **General**: Automatically update my Arc (ⓘ) · Warn before quitting (AX id `warnBeforeQuitPreference`) · Previews + "Previews Settings…" · "Manage your default search engine, Auto-Archive, and downloads in Profile Settings." + "Profile Settings…"
- **Profiles**: intro text with "Learn more."; left list "Your Profiles" (Default — N Spaces) with +, −, and edit buttons; right: Search engine (pop-up) · Manage search ("Search Settings…") · Include search engine suggestions · Archive tabs after (ⓘ, "12 hours (default)") · New documents · Download location; "Your Data and Settings": Privacy and Security · Passwords · Credit Cards · Notifications · Clear Browsing Data (colored icon rows with arrows).
- **Max**: banner; "Enable Max" + "Turn On Max"; Automatically enable future Arc Max features; feature rows with preview images (Tidy Tabs, Instant Links, 5-Second Previews, and more below).
- **Links**: Little Arc illustration and text; Open Little Arc when I press ⌥⌘N in any app · Open Little Arc when clicking on links with ⌥⌘ held · Links from other apps open in Little Arc · Archive Little Arcs after ("6 hours (default)"); Peek text; Open a Peek window when clicking on links with Shift held · Open a Peek window when clicking on links to other sites ("Note: This only affects Favorites and Pinned tabs").
- **Shortcuts**: segmented "Start with the basics | Learn the Essential Shortcuts"; search field; "Default Shortcuts" list (Add Split View ⌃⇧=, Archive Tab ⌘W, Blank Window ⌃⌘N, Capture Full Page, Capture in Portrait Mode, Capture… ⇧⌘2, Cast, Clear Archive, …); "Custom Shortcuts" panel; "Reset All Shortcuts" and "…".
- **Icon**: radio list of 6 app icons with names (The Original Arc — "CURRENT ICON", Candy Arc, Neon, Fluted Glass, Schoolbook, Colorful).
- **Advanced**: Play Arc sound effects · Haptic feedback when reordering tabs · When opening Arc, restore windows from previous session · Allow window dragging from the top of webpages · Show full URL when Toolbar is enabled · Enable Shared Quotes when highlighting text · Enable Picture in Picture when you leave a video tab · Allow websites to get your theme data · Enable Boosts on websites you visit; buttons "More Settings…", "Reset Translated-site Prompts", "Export Data".

## 19. What to re-capture

Essential for a 1:1 build:

1. **Animation timing.** Record Space switch, folder expand, Peek open, command bar open, and sidebar hide with a real video recorder (60 fps), not window screenshots. The screenshot loop cannot go below ~0.4 s per frame at this window size. A smaller window or a cropped `screencapture -R` region would help.
2. **Active-window state.** Traffic lights and toolbar glyphs while Arc is key. Confirm why they render grey here.
3. **Sidebar minimum width.** Drag slowly to the narrowest point and hold, without crossing into the collapse.
4. **Little Arc** (⌥⌘N), **Library** (Home button), **Site Control Center** popover (click the sliders icon in the URL field).
5. **Favorite tile hover and its context menu.**
6. **Light macOS appearance**, to see which colors follow the system and which follow `contentOverBackgroundAppearance`.
7. **2x display** for corner shapes and glyph opacity (all radii here are 1x fits).

Status after capture session 2 (2026-10-26): items 2, 3, 5, and 6 are answered in §20. Item 4 is answered for Little Arc only (§20.10); Library is still open. Item 1 is answered for the Cmd+S hide and show, the card, the Space switch, folders, the command bar, the toast, and the theme popover (§20.12); Peek motion and the tooltip delay are still open. Item 7 is still open: session 2 ran on a 1x display only.

## 20. Capture session 2 (2026-10-26)

This section records the facts from the second capture session. It follows the plan in `.re/capture-session-2.md` (local only). Raw frames, crops, and the video stay in `.re/`. Personal data is not in this section: the user's own Spaces and tabs are not named, and only the two test Spaces ("Capture A", "Capture B") and the test Profile ("TestHome") are named. The routing table for open plans and PRs is `capture-session-2-results.md`.

### 20.0 Conditions and notation

| Item | Value |
|---|---|
| Time | 2026-10-26, 09:59–10:48 PDT. Timeline: `.re/runtime/sessions/s2-notes.txt`. |
| Display | AW2726DM, 2560 x 1440, backing scale 1.0 (`displays.tsv`). No 2x display was used. |
| Appearance | macOS Dark, multicolor accent. Item 20 ran in macOS Light (`session.txt` `appearance=Light`). |
| Main window | 1728 x 1084 at screen (445, 222), in every frame. No window moves (unlike session 1). |
| Sidebar | 228 pt, except items 3 and 4 (364 pt, the user's width before item 6). |
| Spaces | "Capture A" and "Capture B" on the test Profile "TestHome". Both use the default theme (no `windowTheme`) until item 17 gives Capture B one pale color. |
| Recorders | `capture-loop.sh -i 1`: frames 1.2–1.6 s apart (the AX dump takes time). Item 4 used `-i 0.2 -A`: frames 0.45–0.6 s apart. Several recorders kept running in parallel, so one moment can appear in more than one session folder. |
| Window images | `screencapture -l` of a popover or a menu that belongs to the main window returns the composite main window, so those panels appear in `win-<main>.png`. Separate top-level windows (Boost editor, PiP, Little Arc, native menus, tooltips) have their own images. |
| Video | `video/21-motion.mov`: the window region, 3054 frames over 95 s, variable rate (17–47 ms apart during motion, `ffprobe` `pts_time`). |
| Colors | Screenshots converted from the embedded display profile to sRGB, as in §0. The video gives positions and times only, not colors. |

Notation: **S2 07/0122** = frame `0122-*` in `sessions/20261026-101443-07-favorites/`. The two-digit prefix is the item label of the session folder (`01-new-spaces` … `20-light-mode`, `14b-mini-player`). **V 16.31 s** = the presentation time in `21-motion.mov`; wall clock = 10:38:40.52 + t (aligned on the four Cmd+T and Esc responses, ± 0.02 s). **notes 10:12:34** = a line in `s2-notes.txt` that has no frame (a live observation by the person at the keyboard). Frames are window-relative points, as in §0.

Personal data seen in frames (not copied here): the account tab in Settings, the user's own Space names in the bottom switcher, menus, and the Little Arc Space picker, and one of the user's own Spaces with its tabs in S2 18/0003–0035.

### 20.1 Window chrome (items 3 and 6)

Window buttons and glyphs (S2 03, default dark theme, sidebar 364):

| State | Frames | Measured |
|---|---|---|
| Active, pointer on the page | 0001, 0003–0005, 0019 | Window buttons grey `#686973` over the toolbar background `#252538`, each with a 1 px colored ring at its edge (edge pixels `#6A3740` / `#6C5624` / `#2F5629` on the center row). Session 1's grey buttons (§0 caveat 2) match this state, so session 1 was active. |
| Pointer over the buttons | 0007–0008 | System colors with glyphs: `#F35146` / `#FCB800` / `#00BB00` bodies (center rows). |
| Pointer on Back, Forward, Reload | 0010–0015 | Buttons unchanged (grey). Tooltips "Go back ⌘[" and "Reload this page ⌘R" in 27 pt capsules (windows 180 x 93 and 229 x 93). No Forward tooltip was seen (Forward was disabled). |
| Inactive (Finder frontmost) | 0016–0018 | Buttons `#565761` over `#0A0B1D`, no ring. The sidebar and toolbar background darken from `#282538` to `#0D0A1D` (about 27 levels on every channel). PR #104's agent fits the reveal card as ≈ 0.885 × a theme tint + 0.115 × the blurred page, and finds the same blend over black matches the inactive window. Checked here: the fit's constant `#0E091D` is within ΔE00 0.4–1.1 of the inactive sidebar at y 450, 700, and 950. guess (#104): the window background is the same translucent material, over a light backdrop while active. |
| Fill model | — | `docs/design.md` §23 in PR #104 fits the grey as `DimmedWindowControls` at 0.33 over the background, with the ring only while the window is active. These frames agree with that fit. |

Toolbar and bottom-bar glyph peaks (brightest 12 pixels; white alpha over the local background; 1x, so lower bounds):

| Glyph | Active (0001) | Inactive (0016) |
|---|---|---|
| Sidebar toggle, Back, Reload (enabled) | 0.59 (`#A6A6AE`) | 0.25 (`#484856`) |
| Forward (disabled) | 0.25 (`#5D5B69`) | 0.25 |
| Home, bottom plus | 0.59 | 0.30 |

So in an inactive window every toolbar glyph takes the disabled tone, and the bottom-bar glyphs drop to about half.

Sidebar width (S2 06; AX width of the sidebar scroll area):

| Step | Frames | Width | Notes |
|---|---|---|---|
| Start | 0001 | 364 | |
| Double-click on the resize edge | 0009 | 228 | Resets to the default 228. A double-click at 500 also gives 228 (0088). |
| Slow drag to the left | 0025–0029 | 207, 197, 187, 167, 164 | Stops at **164** (minimum). notes 10:12:34: the pointer was at window x ≈ 161 there. |
| Keep dragging, still pressed | 0035 | hidden | The sidebar slides out while the button is still down (notes 10:12:34: between pointer x 85 and 65). Release keeps it hidden; AX then shows the card offscreen at x −218 with "Lock sidebar" (0053). |
| Cmd+S after a drag-hide | 0066 | 228 | Restores the width before the drag, not 164. |
| Drag to the right | 0069–0072 | 357, 407, 482, **500** | Stops at **500** (maximum). |

Compact toolbar: at width 207 and below (0025–0029; 228 in 0009 is still full) the toolbar has no sidebar toggle and no Reload. It shows Back, Forward, and a "More options" button, each 28 x 28 at y 9, right-aligned with the last one ending 6 pt from the sidebar edge (`[W − 34, 9, 28, 28]`, pitch 28). At 164 the full-screen button's AX frame is clipped to 13 pt (0029). The exact width where the toolbar switches lies between 207 and 228 (not seen). The empty Favorites card grows taller as its text wraps (105 pt at 228, 136 pt at 164).

Link status bubble (S2 04/0021, 0033; bonus): a capsule at the bottom-left of the web content, 10 pt from its left edge and 12 pt above its bottom edge, 23 pt tall, fill `#0A0D4F` (default dark theme), white text, showing the hovered link's URL without the scheme. It has no AX element.

### 20.2 Hover-reveal card (item 5)

| Property | Measured | Evidence |
|---|---|---|
| Card fill is translucent | The card shows the page under it, blurred. Over a white page (Capture A) the fill equals the anchored sidebar within ΔE00 0.5–0.6 from top to bottom (`#27253A` vs `#272538` at y 400; `#2E263A` vs `#2C2438` at y 1000). Over a dark page (Capture B, page `#101418`) it is about 26 levels darker (`#0F0B21` at y 500), with a soft lighter patch where the page has a lighter box. | S2 05/0014 vs 0001; 05/0028, 0033 (dark page) |
| Session 1's darker bottom | Explained: the page under F0129's bottom was saturated blue (`#4246FC` in F0128), and the card reads `#180F3B` there; over white parts it reads `#2A273A`. | F0128 vs F0129, rows y 1000–1370 |
| Fit | PR #104 (§13.1 there) fits fill ≈ 0.885 × a tint + 0.115 × the blurred page (σ ≈ 25 px, RMS 1.06 levels). This section's numbers agree with that fit. | |
| Stroke | On all four sides: the outermost pixel inside the card is lighter (left x 5 `#6A6673`, right x 232 `#6C6775`, top y 5 `#676673`, bottom y 1078 `#6D6573`), white ≈ 0.30 over the fill. | S2 05/0014 |
| Window buttons on the card | Grey with rings at rest; system colors with glyphs when the pointer is on them. | S2 05/0014; 0020 |
| Card hide | Present in 0036 (pointer far right), gone in 0037 (1.4 s later). The video gives the slide times (§20.12). The exit delay is not measurable (the clicks and moves have an unknown automation lag). | S2 05/0036–0037 |
| Light appearance | §20.11. | |

### 20.3 Favorites (item 7)

Empty card (no Favorites in the Space; S2 07/0001 at width 228, S2 03/0001 at 364):

| Part | Measured |
|---|---|
| Section | AX hosting view `[0, 82, W, 105]`. The Space title then sits at y 204 (versus 154 with one tile row and 209 with two). |
| Card | Dashed 1 pt outline at x 7 … W − 8, y 89 … 183 (a 214 x 95 rectangle at width 228), dash 5 pt, gap 5 pt, color `#616173` over `#252538` (white ≈ 0.19). A faint accent-blue hairline lies just inside the dashes (`#242257`). Corner ≈ 12 (visual). Inside fill `#202035`, a little darker than the sidebar. |
| Star icon | AX image `star.circle.fill` desc "Favourite", 17 x 17, centered at x W/2, y 101. White disc `#EDEEFF` with the star in dark indigo (`#262471`). |
| Dismiss | AX button "Dismiss", id `sidebarFavoritesEmptyStateDismissButton`, 14 x 14 at `[W − 30, 98]`, an "x" glyph (ink 7 x 8). |
| Title | "Drag to add Favorites", centered, AX `[18, 123, W − 36, 16]`. Ink 132 pt wide: SF 13 Semibold gives 134 (fitted). Color `#DEDFFF`. |
| Body | "Favorites keep your most used sites and apps close", centered on two lines (AX 150 x 30 at width 228). Ink 136 and 140 pt wide: SF 11.5 Regular fits best (12 Regular gives 140 and 146; fitted). Color `#A5A7C4`. |
| Drop target | While a tab is dragged over the card, its text and icon dim (S2 07/0040–0041; the frames are partly black from Arc's drag windows, so no color). The dropped tab replaces the card with one full-width tile. |
| Hover | No change seen (S2 07/0003; the pointer may not have been on the card). |

Grid by count (S2 07; AX frames at width 228; tile height always 47, gaps 8):

| Count | Frame | Layout | Tile width |
|---|---|---|---|
| 1 | 0043 | 1 row, 1 column | 212 |
| 2 | 0064 | 1 row, 2 columns | 102 |
| 3 | 0090 | 1 row, 3 columns | 65.33 |
| 4 | 0122 | 1 row, 4 columns | 47 (square) |
| 5 | 0139 | 2 rows, 3 columns (3 + 2, the short row left-aligned) | 65.33 |
| 6 | F0016 (session 1) | 2 rows, 3 columns | 65.33 |

The section is 63 pt for one row and 118 pt for two. Counts 6 and 7 were not reached in this session (the drags made a split instead, notes 10:20:12). While a tab is dragged over the grid, the grid already shows the new layout with an empty slot (0053, 0062: one tile at 102 for a second tile; 0100, 0113: three tiles at 47 for a fourth; 0133: the fifth slot at `[81, 90]`).

| State | Measured | Evidence |
|---|---|---|
| Selected tile, active window, default dark theme | Fill `#84858E` over `#242639`: white ≈ 0.44, much brighter than a selected row (white 0.19 here, `#515060` over `#282539`). | S2 07/0140; S2 03/0001 |
| Selected tile, inactive window | Fill `#434150` over `#0B0B1D` (white ≈ 0.24) with a 2 px lighter ring `#636174` (white ≈ 0.36). A selected row drops to white ≈ 0.10 (`#252335` over `#0C0A1D`). | S2 07/0163; S2 03/0016 |
| Tile at rest | `#3A3A4C` over `#252538` (white 0.10), as in session 1. | S2 07/0146 |
| Tile hover | Not isolated in any frame. | |
| Tile menu | Copy Link · Share ▸ (system share services) · — · Change Icon… · Rename… · Mute (disabled) · Customize Page… · Edit Pinned Page ▸ (Replace Pinned URL with Current (disabled), Edit…) · — · Open in Split View · Duplicate · Move to ▸ (Profile ▸ (Default · TestHome ✓)) · — · Remove Favorite. "Move to" lists Profiles, not Spaces. | S2 07/0185 (AX menu `[41, 107, 174, 307]`, native `NSMenu`) |
| Space "More" button alone | AX `sidebarSpaceEditButton` grows from 2 to 26 pt: `[W − 39, 205, 26, 26]`, and the title frame shrinks to 174. Plate white ≈ 0.08 (`#373647` over `#262538`), radius ≈ 6. Glyph "•••" peak `#ADACB3`. No header fill while only the button is hovered. | S2 07/0202 |

### 20.4 Today and folder rows (items 7 and 8)

| Property | Measured | Evidence |
|---|---|---|
| Where "New Folder" puts a folder | Above the Today divider (pinned area), even with no pinned tabs: rows are folder, its children, divider + "Clear", "New Tab", Today tabs. | S2 08/0100 AX |
| Collapsed folder with a peeking child | A collapsed folder keeps one child visible under it (the child that was last active, here "Bird"). Its folder glyph then shows three dots ("•••", the hidden children) in a filled accent folder (`#202AFF`, dots `#8287FE`). Arc ships images named `FolderEllipsesDark` and `FolderEllipsesLight` (`design-tokens.md` §2.3); guess: this glyph. On disk: `StorableWindows.windows[].expandedItems` holds `[folderID, {peeked: {_0: [childID]}}]`. The lane S design reviewer reported the same last-active child and three-dot glyph. | S2 08/0090, 0100; `appsupport/s2-little-arc-open/StorableWindows.json` |
| Clicks on the folder row | Peeking → fully collapsed (the peeking child slides up into the folder) → expanded (all children) → collapsed. | V 46.49, 49.33, 52.19, 55.04 s |
| Folder row hover | Fill white 0.10 (`#3B3A4C` over `#262538`) on the row frame, and a "—" glyph at the right (ink 12 x 2 at `[196, y + 19]`, peak `#B0AEB6`). It has no AX element. guess: the same "unload" action as on a loaded pinned tab. | S2 08/0090 |
| Today tab menu | Visible items: Copy Link · Share ▸ · — · Change Icon… · Rename… · Mute (disabled) · Customize Page… · — · Open in Split View · Duplicate · Move to ▸ (each Space · — · New Space…) · — · Archive Tab · Archive Tabs Below. The menu ends with these two normal items (the lane S design reviewer saw the same). AX also lists **Archive Other Tabs** and **Archive Tabs Above**, each on the frame of the item before it, so they are the hidden ⌥ alternates of Archive Tab and Archive Tabs Below. ⌥ was not held in this capture, so the swap is derived from AX, not seen. The menu draws as a dark translucent menu. | S2 07/0255 (image and AX), 0260 |
| Today tab menu, other variant | "Add Split View" instead of "Open in Split View", and "Archive Tabs Above" disabled. guess: right-click on the selected tab, at the top of Today. | S2 07/0242 |
| Split row in Today, not selected | The same two cells as the selected split row (§7): icons x 17 / 121, titles x 45 / 149, 64 wide. | S2 08/0100 AX |
| Folder hover preview | Item 8: did not appear for the synthetic pointer (5 s on the row, with Previews ▸ Arc Folders on). The video caught it once (added 2026-10-26, PR #108 review r1; positions only, colors are not read from the video): on the **peeked** (collapsed) folder the row gets its hover state (fill and "—") at V 45.69 s; the card fades in from V 46.11 to 46.19 s and fades out from V 46.36 to 46.46 s, when the click arrives. Card ≈ `[232, 163, 240, 191]` (4 pt right of the 228 sidebar; its center y 258.5 matches the row center 259). It has a "Search \<folder title\>…" field with a magnifier and a caret (≈ 48 pt band and a separator), then rows ≈ 45 pt apart, each with a favicon, a title, and "N minutes ago"; the first row has a highlight plate. Hover-to-card ≈ 0.42 s (one sample, synthetic pointer). During a 3 s hover on the **expanded** folder (V 56–61 s) no card appeared (guess: expanded folders get none). | notes 10:23:34; V 45.69, 46.11–46.46 s; V 56–61 s (no card) |

### 20.5 Site Control Center (items 9 and 11)

| Property | Measured | Evidence |
|---|---|---|
| Kind | Its own window (`windows.tsv`: 262 x 323 at screen (515, 300), 262 x 398 with a Boost), composited into the main window image. Not in the AX dump. | S2 09/0009–0010; 11/0004 |
| Placement | Drops **down** from the URL field. Body x 83 … 318 (236 wide), centered on the Site Control button (button center x 201 at width 228). It covers the sidebar and the page. Body top y 91, 9 pt below the field's bottom edge; the arrow tip reaches the field. | S2 09/0010 pixel diff against 0007 |
| Arrow | Yes. A top arrow points up at the button: tip at y ≈ 82, base y 91, base width ≈ 28, centered at x ≈ 200.5. | same |
| Corners | ≈ 16–18 pt, continuous-looking (row insets 16, 12, 10, 8, 7, 6, 5, 4 at the bottom-left). | same |
| Material | Translucent and blurred, like the reveal card: over the sidebar `#47455A` (sidebar `#252538`), over a white page `#7C7C7C`. A red favicon behind the panel shows through as a soft red patch. | S2 09/0010 |
| Height | 297 pt without Boosts (y 91 … 387); 372 pt with one Boost row (y 91 … 462, inclusive, as for 297). | S2 09/0010; 11/0011 |
| Header | None: no favicon and no host title. | same |
| Action row | 4 buttons, each 48 x 31, gap 8, inset 10, top inset 10: Share (`square.and.arrow.up`), New Boost (wand), Capture (camera), Capture area (viewfinder). Fill `#212121` (opaque, the same over the sidebar and the page). No Copy URL button. Tooltips did not show for the synthetic pointer. | S2 09/0010 |
| Section order | **Extensions** (a "+" tile ≈ 47 x 32), **Boosts** (only when the site has a Boost: one row, wand icon in a white 32 pt circle, "My Boost" / "Enabled"), **Settings** (rows with a 32 pt icon circle, title, and subtitle: "Developer Mode" / "Off" (hammer, grey circle); "Automatic Picture-In-P…" / "Allowed" (gear, white circle)). Headers ≈ 13–14 pt Semibold, white (visual). | S2 09/0010; 11/0011 |
| Section header hover | Shows "Manage" at the right. A Boost row hover shows a chevron. | notes 10:47:57 (no frame) |
| Footer | 1 pt separator (`#66667B` line) at y 335, then a "🔒 Secure" pill (≈ 80 x 31 at x 96) and a round "⋯" button (32 pt circle, `#5A5C60`) at the right. | S2 09/0010 |
| ⋯ menu | Native `NSMenu`: Clear Cache · Clear Cookies · — · Manage Boosts… · New Boost… · — · Manage Extensions… · Add Extension… · — · All Site Settings…. "New Boost…" shows even while a Boosts section is shown. | S2 11/0011 (`win-74748.png`) |
| Button while open | The Site Control button draws its filled variant (white square, dark sliders) while the panel is open. With a Boost on the site, small sparkles surround it (0016). guess: the sparkles mark an active Boost. | S2 11/0011, 0016 |
| ⌥ + click | Did not open the panel. | notes 10:28:02 |
| Boost name menu | Rename this Boost… · Shuffle · Reset all Edits · Delete this Boost · — · All Boosts…. Delete asks in a centered alert 450 x 273: "Delete this Boost?" / "This can't be undone." with [Cancel ESC] and a red [Delete ⏎]. | notes 10:48:09, 10:48:18 (no frames) |

### 20.6 Boost editor and Zap (item 10)

The editor is its own window: AX subrole `AXSystemDialog`, id `boostsEditor`, layer 3, 183 x 588, at screen (2082, 382), next to the Arc window's right edge. It is **light** (white) even in macOS Dark. The test Boost was made on archive.org (the WebRTC sample was skipped: no live microphone, notes 10:23:47).

| Part | Frame / value | Evidence |
|---|---|---|
| Header | Done `[0, 0, 40, 40]` (circled x), name button "My Boost ⌄" `[46, 8, 91, 24]`, Undo `[143, 0, 40, 40]`. A 1 pt line `#E9E9EB` at y 39. Background `#FDFDFF`. | S2 10/0030 |
| First-run card | Covers the lower half; the top half dims grey. A wavy top edge (AX image "SquigglyFooter"), an icon, "Edit the Internet with Boosts" (title color `#303AFF`), "Make archive.org your own!" (host in bold), a blue "Make a Boost" button (`#4848FF`, `[14, 493, 155, 38]`), and "Maybe Later" `[46, 541, 91, 31]`. The bottom area is lavender `#CEDBFC`. | S2 10/0018 |
| Color control | A square dot-grid pad, not a wheel: AX "Color wheel" images `[18, 58, 147, 147]` and `[25, 65, 133, 133]`. Corner ≈ 20 (visual). Before a color is chosen, the pad's frame is a grey ring; after, a rainbow hue ring. Two knobs: a large primary and a smaller second one. A thin circle guide shows the radius while dragging (0039). | S2 10/0018, 0030, 0039 |
| Color buttons | Three 42 x 38 buttons at y 220, x 18 / 70 / 123: "Invert lightness" (bulb), "Advanced color controls" (sliders), "Reset to original colors" (a prohibited sign; disabled until a change). Fill `#EBEBED`. | S2 10/0030 |
| Advanced color controls | An `NSPopover` 250 x 232 under the button: "Contrast", "Brightness", "Original Saturation", in that order, each a slider 186 x 16 at value 50 (middle). | S2 10/0042 (window 74512) |
| Fonts | A white card with a 5 x 4 grid of 26 x 26 "Aa" buttons (`[23 … 160, 281 … 385]`), 20 fonts drawn in their own faces. The font names are not in AX. | S2 10/0030 |
| Text controls | "Size" `[18, 408, 70, 38]` and "Case" `[96, 408, 69, 38]` (AX "Change text size", "Change text case"). | same |
| Zap | Full-width button `[18, 461, 147, 38]` with a bolt. While Zap is on it is dark `#333333` with white text. After one Zap it shows the count ("Zap, 1"). | S2 10/0030, 0058, 0071 |
| Zap mode on the page | The web content gets a 3 pt brand-blue frame (`#3139FF`). A 56 pt white bar (`#FBFBFD`) sits at the content's bottom: "Click elements on the page to Zap them" (centered, grey) and "Done" at the right. The hovered element is tinted yellow. A click shows a white popup next to it: red "Zap this", orange "Zap all related elements", grey "Cancel", and a selector line under them ("1 [lang="en"] app-root"). After a Zap the bar offers "Click to reveal" (notes 10:26:49). | S2 10/0060 |
| Code | Full-width `[18, 514, 147, 38]` with "{}". Opening it widens the window to 480 x 588 to the left (right edge fixed): "← Back", a CSS | JS segmented control, a web view, and "Pick Selector" (eyedropper) and "Show Developer Tools" (hammer), 38 x 38 at the bottom-left. The web view showed "Internal debugging pages are currently disabled." (a Chromium internal page), so the code editor itself was not captured. | S2 10/0071 |

### 20.7 Media (items 12–16)

| Property | Measured | Evidence |
|---|---|---|
| Row speaker | **Leading**: AX button `sidebarTabCellMuteButton` `[41, y + 7, 26, 26]`, right after the favicon. The title moves from x 43 to x 69 and narrows by 26. Outline glyphs: speaker with waves (ink 19 x 13), and a slashed speaker when muted (ink 16 x 16). Peak `#B8B8BE` on the selected row (white ≈ 0.65). It shows from the first frame with audio (S2 12/0013). The speaker tooltip did not show for the synthetic pointer. | S2 12/0022, 0027, 0029 |
| Auto-PiP window | Arc's own window (`AXSystemDialog`, layer 3), 320 x 180 at screen (2230, 1250): 10 pt from the right and bottom edges of the screen. Corner ≈ 6 pt (alpha profile). At rest it shows only the video. Hover controls and the PiP menu did not respond to synthetic events (not captured). The media lane measured the same frame, and the lead adopted a first-open rule of the screen's `visibleFrame` / 8 for Open. Here 2560 / 8 = 320 wide, and 180 is that width at the video's 16 : 9. This capture has one display and one video, so it agrees with that rule but does not prove it (other screen sizes and aspect ratios were not seen). | S2 13/0002 |
| While PiP shows | The source row keeps the speaker; the sidebar shows no mini player. Selecting the source tab again closes the PiP window. | S2 13 (no `mediaControlsPauseButton` in any frame); notes 10:31:21, 10:32:08 |
| Mini player (auto-PiP off) | One compact card `[8, 1001, W − 16, 33]`: its bottom touches the bottom bar (y 1034); the tab list ends 8 pt above it. Fill `#050627` (opaque, default dark theme). Corner: radius 10 continuous (a fit against Core Animation renders, `plans/media-pip.md` §13.3.2; an earlier "≈ 6" was a visual estimate). A shadow on all four sides (black ≈ 0.21, radius 4, fit). No title row at rest. Five 24 x 24 buttons at y 1006, x 18 / 60 / 102 / 144 / 186 (pitch 42): the source favicon, previous (AX "Go To End", disabled), Pause (`mediaControlsPauseButton`), next (AX "Go To Start", disabled), volume (AX "Volume Higher"). Glyphs `#ABAAB5` (white ≈ 0.65), disabled `#3C3C56`. | S2 14b/0014 |
| Mini player expanded | After a click on the volume button the card grows upward to `[8, 968, W − 16, 66]`: a title row with the title (`[22, 976.5, 130, 16]`, `#CDCDD4`, the page title + " - YouTube", truncated), "Picture In Picture Window" `[162, 973, 24, 24]`, and "Close" `[186, 973, 24, 24]`. Volume tooltip "Adjust Tab Volume" (window 193 x 93). A volume drawer did not appear. A click on the card body goes back to the tab, and the card goes away. The pointer was on the card too (a plate on volume), and 1.2 s later, with no plate, the card is at rest again (14b/0025), so hover alone may expand it; the synthetic click and the pointer arrived together and cannot be separated (`plans/media-pip.md` §13.5, §13.7 O6). The title is 13 Regular, tail-truncated with "…" (Core Text fit). | S2 14b/0024, 0025; notes 10:33:43 |
| Three players, pointer away | One front card with two cards behind it, each peeking 7 pt above the one in front: the second inset 5 pt per side (card 13 … 215, `#090827`), the third 10 pt (card 18 … 210, `#14112C`), both dimmer. The insets come from the AX button positions (23 / 63 / 102 / 142 / 181 and 28 / 65 / 102 / 139 / 176, evenly spread over each card); the pixel edges lose the anti-aliased corners. A plain opacity of 0.8 and 0.6, each card over what lies behind it and not masked, matches both strips within ΔE00 0.52 (`plans/media-pip.md` §13.3.4). AX: one hosting view `[8, 987, W − 16, 47]` with the three Pause buttons at y 992 / 999 / 1006. | S2 16/0005 |
| Three players, pointer over | Three full cards (title row + controls), 66 pt each, 5 pt apart, from `[8, 826, W − 16, 208]`. Order top to bottom: the first-started video, the second, the most recent at the bottom. The hovered button gets a plate. | S2 16/0012 |
| Not captured | Back-to-PiP (item 15), what Close does to playback, the volume drawer, paused and muted card glyphs, recording rows, the mini player in macOS Light. | |

### 20.8 Theme editor (item 17) and the New Space form (item 1)

Edit Theme Color on Capture B (S2 17; popover `[228, 9, 382, 534]`, content `[241, 22, 356, 508]`, the same geometry as §14). It has no arrow and sits on the sidebar edge.

| Property | Measured | Evidence |
|---|---|---|
| No color yet | The pad shows "Tap to pick a color for this space"; Remove and Add are disabled. | S2 17/0006 |
| Preset pages | 5 pages of 9 (AX ids as §14). Swatch centers (sRGB): page 1 Brand `#F2EBE4 #F29ABC #A6729D #F15E6B #FF8558 #F8D558 #35E895 #6DBAD9 #666789`; page 2 the same hues drawn as diagonal two-tone gradients (muted, e.g. `#CF9957`, `#3DCAC9`); page 3 Pastel `#FEFBFA … #C5C6E5`; page 4 Drab `#4E3A5B #693557 #8F4042 #B16D40 #D7B35E #CDCCA4 #7AA982 #236149 #26456B`; page 5 Greyscale `#FFFFFF #E5E5E5 #CCCCCC #B3B3B3 #808080 #666666 #333333 #191919 #000000`. The next button gets a plate on hover. Page 2 was not clicked. | S2 17/0014–0021 |
| Automatic text flip | Text is dark for greys 1–5 and light for greys 6–9. The sidebar reads `#909090` (relative luminance 0.28) at grey 5 and `#808080` (0.22) at grey 6; the swatches are `#808080` and `#666666`. So the flip lies between those two. A pure WCAG contrast rule would keep dark text at `#808080`; Arc does not. | S2 17/0028–0044 |
| Greys and "+" | On a grey preset, "+" adds no second color and then shows disabled. | S2 17/0052–0054; notes 10:42:19 |
| Up to 3 colors | On a color, "+" adds a second knob, then a third; "+" is disabled at 3. Added knobs sit at harmony positions and move with the primary while it is dragged. Primary knob ≈ 44–46 pt, extra knobs ≈ 28 pt. "−" removes one. | S2 17/0065–0082 |
| Pad radius | Radius sets lightness: center deep (sidebar `#B45D7C`), middle `#D28C8E`, edge pale `#DDC5C6` (one pink hue). A one-color Space is flat: top, middle, and bottom of the sidebar are equal. | S2 17/0092, 0094, 0096 |
| Intensity | 0 → the sine wave becomes a straight line and the color turns almost grey (`#CEC6C7`); middle `#D1C0C1`; full `#E5CACB`. The wave amplitude follows the value. | S2 17/0099, 0101, 0103 |
| Noise dial | Each click on the center cycles: texture 1 (fine dark grain), 2 (coarse grey noise), 3 (diagonal lines), 4 (soft grey noise), none (noise 0: tick at 12 o'clock, empty center), then texture 1 again. A texture click sets the tick to ≈ 288° (≈ 0.8). Full = tick at 12 o'clock with every dot lit; zero = tick at 12 o'clock with dim dots and an empty center. Dots light clockwise from 12 o'clock up to the tick. | S2 17/0107–0154 |
| Modes | Light (sun) turns the popover and the web page light; Dark (moon) and Automatic (macOS Dark) keep them dark. The pale sidebar color does not change with the mode. In Light the white intensity thumb is hard to see on the light popover. | S2 17/0156–0163 |
| Stored result | `blendedSingleColor` `#F7D3D4` (0.9695, 0.8282, 0.8314), `intensityFactor` 1, `noiseFactor` 0.8, `contentOverBackgroundAppearance` "light", `semanticColorPalette.appearanceBased`. No key for the chosen Dark mode was found in `StorableSidebar.json`. | `appsupport/s2-final/StorableSidebar.json` (the `s2-theme` copy was taken before Arc wrote the theme) |

New Space (S2 01): the plus menu (an Arc popover with a bottom arrow at the plus button, which turns into "x" while open) lists New Space · New Folder · — · New Easel ⌃⇧E · New Boost (disabled) · — · New Split ⌃⇧= (disabled) · New Tab ⌘T, rows 40 pt (0093). "New Space" turns the **sidebar into a form page**: "Create a Space", "Separate your tabs for life,\nwork, projects, and more.", a name field, a full-width "Create Space" button `[14, 952, W − 28, 36]` (id `spaceCreationCreateSpaceButton`, disabled while the name is empty), and "Cancel" (0132, 0208). The theme editor opens beside it **with a left arrow** pointing at the form, with an empty pad (0135–0136). A new Space starts with no theme (both test Spaces). Set Profile ▸ New Profile… shows a centered 450 x 426 dialog "Create a new Profile" with a name field and [Cancel ESC] / [Create Profile ⏎] (0157).

### 20.9 Command bar (item 18)

| Property | Measured | Evidence |
|---|---|---|
| Hold ⌘ | No hints after 2–4 s. | S2 18/0001–0003; notes 10:38:02 |
| Inline completion | "wiki" shows "wikipedia.org" with the completed part selected. The trailing hint reads "Search Wikipedia [Tab]" (AX button "Search Wikipedia, Tab" `[1078, 393, 147, 24]`). Row 1 "Wikipedia — wikipedia.org". | S2 18/0009 |
| Backspace, Right, Left | Backspace removes the completion (value "wiki", 0010). Right and Left were sent; no frame isolates them. | S2 18/0010 |
| Site Search | Tab turns the text into a chip "Wikipedia" (orange `#FFA000` fill with a soft glow, white text, x 535 … 615), and the field moves to x 627 with an empty placeholder. Typing "bird" shows one row (search icon + "bird") with an orange selection `#FFA000`. Backspace on an empty field removes the chip and gives back "wikipedia". guess: the chip color is a per-engine color. | S2 18/0016, 0018, 0021 |
| (i) button | Opens an inline footer at the bottom of the bar, not a window: a black band (y 641 … 700) with "We talk to your search engine to help us suggest results." and "Learn more about your data on Arc here." ("here" is a link), and two buttons "Search Settings…" and "Dismiss" (fill `#302F63`, 1 pt `#494988` edge). The list loses one visible row. | S2 18/0044 |
| Fill and selection | The bar fill and the selection follow the Space: `#2F2D2E` / `#484DDB` in Capture A (default dark), `#1B2832` / `#2A68A3` in a blue Space. Session 1 measured `#181819` and the Space's `dark.focus` (§9). | S2 18/0044, 0009 |
| Close mid-animation in AX | AX shows the field at width 2 and the table shrunk (0029, 0047), but the video shows no visible animation (§20.12). | |

### 20.10 Little Arc (item 19)

| Property | Measured | Evidence |
|---|---|---|
| Window | AX `AXSystemDialog`, id `littleBrowserWindow-<UUID>`, title "Space 1" at first. | S2 19/0003 |
| First frame | 490 x 329 at screen (2050, 50): top-right, 20 pt from the right edge and 20 pt below the menu bar. It is a bare command bar: the field `[53, 20, 380, 23]`, a close "x" `[443, 19, 26, 26]`, and Arc's default suggestions in 50 pt rows. | S2 19/0003 |
| After a page loads | 1185 x 832 at (1355, 50): the window grows to the left and down, keeping its top-right corner. | S2 19/0011 |
| Title bar | 47 pt. Window buttons at `[9/32/55, 16, 16, 16]` (3 pt left of the main window's). A Profile chip (AX `littleBrowserProfileIndicator`: a 14 pt icon + "TestHome"). The host centered (`[497.5, 15.5, 129, 16]`). A copy-link button `[957, 16, 16, 16]`. A dark pill "Open in **Capture A** ⌘O" `[994, 15, 148, 17]` and a chevron `[1156, 15, 16, 16]` (tooltip "More Spaces"). The page starts at y 47. | S2 19/0011, 0025 |
| Space picker | The chevron opens a dark popover (≈ 244 wide at the window's top-right): "Search Spaces…" field, then the Spaces with their icons on colored rounded squares, the current Space first with a highlight, other rows 46 pt apart. | S2 19/0023 |
| Second ⌥⌘N | Opens a new Little Arc window at the same first frame (490 x 329 at (2050, 50)), on top of the first. | S2 19/0029 |
| On disk | `StorableWindows.windows[].style.little` = `{modalState: {initial: {}}, downloads: {downloads: []}, shouldShowProfileIndicators: true, profile: {custom: {_0: {directoryBasename, machineID}}}, session: {id, entryPoint: {externalLink: true}, preferredFrame: {anchor: {topRight: {_0: [2544, 1394]}}, size: [500, 300]}, startTime}}`. ⌥⌘N also records `entryPoint.externalLink`. | `appsupport/s2-little-arc-open/StorableWindows.json` (`analysis/schema.py`) |

### 20.11 macOS Light (item 20)

| Property | Measured | Evidence |
|---|---|---|
| Default theme follows macOS | Both test Spaces (no stored theme) turn light. Corners: sidebar top `#DBDBF3`, top-right margin `#ECE0E4`, sidebar bottom `#E8E0ED`, bottom-right margin `#F1E2E2` (lavender top, pink bottom). Open's light guess (`#EDEDF1` …) differs by ΔE00 4.7–9.1. | S2 20/0015 |
| Rows and text | Selected row `#F4F3F5` (near white, opaque look). Tab titles `#0F1152` (dark indigo). "New Tab" `#9E9CAB`. URL host `#53545D`. Toolbar glyph peak `#5F5F6A`. URL field and tiles `#D1D1E8`. | S2 20/0015 |
| Command bar | Light: fill `#F8F8F8`, selection `#8E95FF`, placeholder `#7D7D7D`, separator `#E0E0DF`. The same in Capture B. | S2 20/0018, 0053 |
| Theme editor | White popover (`#FFFFFF` / `#FAFAFF`), dark mode icons, the same layout. | S2 20/0027 |
| Hover-reveal card | Fill `#E2E1F9` top → `#EFE7F4` bottom (a little lighter than the anchored sidebar over the white page); the stroke is a faint lighter line (`#EEECFA`); the shadow is visible outside. | S2 20/0040 vs 0035 |
| Copy URL toast | Lavender pill (`#CABEEB` area) with dark text "Copied Current URL" and a share button. | S2 20/0048 |
| Context menu, Settings | Native light menus; the Settings window follows macOS. | S2 20/0046, 0063 |
| Not captured | The mini player in Light (step 8 was skipped). | |

### 20.12 Motion (item 21, video)

All times are from `21-motion.mov` (§20.0). A duration runs from the last frame at rest to the first frame at the end state, ± one frame (17–47 ms). Fits use the curve families in `.re/runtime/analysis-s2/fitmotion.py` (CA timing curves and a spring with response R and damping ζ), with a free start time per event.

| Motion | Events | Measured | Best fits |
|---|---|---|---|
| Command bar open and close | 4 (V 9.70, 10.88, 13.02, 14.20 s) | The whole bar appears or goes in one frame (38 ms or less), with no frame in between. | none (no animation) |
| Cmd+S hide | 3 (V 16.26, 20.61, 24.93 s) | Web content edge 228 → 10 in ≈ 0.10 s (e.g. 228, 218, 82, 27, 13, 10 at 20.612 … 20.720 s). Starts with the key. | spring R 0.09–0.105 s, ζ 0.9–1.0 (RMS 0.008); CA default curve 0.09 s |
| Cmd+S show | 3 (V 18.76, 23.08, 32.41 s) | 10 → 228 in ≈ 0.10 s, no overshoot. It starts 0.28–0.30 s after the key note in all three events, while the hide starts at once. Cause not known. | spring R 0.09–0.105 s, ζ 0.9–1.0 |
| Card in | 1 (V 26.63 s) | Right edge 10 → 236 by 0.13 s, 3 pt past its rest (233), settled by ≈ 0.24 s. | spring R ≈ 0.18 s, ζ ≈ 0.8 (a 1.3 % overshoot matches ζ 0.8); PR #104 fit: R 0.164 s, ζ 0.86 |
| Card out | 1 (V 29.50 s) | 233 → 10 in ≈ 0.10 s, no overshoot. | ease-in-out 0.105 s (RMS 0.005) |
| Space switch | 2 (A→B V 35.05 s, B→A V 43.63 s) | The web content swaps in the first frame. The Space page slides 228 pt; the remaining offset is 103, 60, 33, 18, 12, 6, 4, 2, 1, 0 pt at steps of ≈ 25 ms; settled ≈ 0.27 s after the start. Both Spaces had the same theme, so no cross-fade was visible. Only 2 of 4 clicks switched Spaces. | critically damped spring, R 0.20 s (RMS 0.003) |
| Folder expand | 2 (V 49.33, 55.04 s) | Rows below move down 123 pt in ≈ 0.20 s. | ease-out 0.20 s (RMS 0.009) |
| Folder collapse | 2 (V 46.49 peeking child, 52.19 s) | Rows move up 123 pt (41 pt for the peeking child) in ≈ 0.24 s. | CA default curve 0.245–0.25 s; spring R 0.27 s, ζ 0.9 |
| Copy URL toast | 1 (V 69.99 s) | Grows from a small pill at the top center of its final place, moving down while it grows, in ≈ 0.20 s, then settles until ≈ 0.46 s; visible ≈ 4.95 s; shrinks back up in ≈ 0.16 s (V 74.95–75.11 s). | — |
| Theme editor popover | 1 (V 79.06 s open, 80.74 s close) | Scales up from the sidebar side with a fade in ≈ 0.20 s, a 1–2 % overshoot at the top edge, settled by ≈ 0.25 s; closes the same way in ≈ 0.19 s. | — |
| Folder hover card | 1 (V 46.11 s in, 46.36 s out; added 2026-10-26, review r1) | The peeked folder row shows its hover state at V 45.69 s; the card fades in over ≈ 0.08 s (V 46.11–46.19 s) and fades out over ≈ 0.10 s (V 46.36–46.46 s, when the click arrives). Hover-to-card ≈ 0.42 s, one sample, synthetic pointer. No scale is visible at the video rate. Layout in §20.4. | — |
| URL field buttons | 1 (V 65.48 s) | The copy and Site Control buttons fade out over ≈ 0.07–0.09 s when the pointer leaves the sidebar. | — |
| Not captured | | Peek (the Shift-click hid and showed the sidebar instead, V 82.85, 83.38 s), the tooltip delay (the pointer missed Reload, V 65.5 s), the folder hover card's colors (its positions and timing are in §20.4: V 45.69–46.46 s; no card for the expanded folder at V 57–60 s), the dwell and exit delays (unknown click lag). | |

Cross-check: PR #104's agent measured the same video independently: Cmd+S hide and show ≈ 0.1 s, the show starting ≈ 0.29 s after the key; the card in over ≈ 0.14 s with a 3 pt overshoot (spring response 0.164 s, damping 0.86); no Cmd+T animation; folder expand and collapse 0.20–0.24 s (≈ 0.22 s). The values in the table above agree within one video frame.

Single clicks (Space switch, folder) start 0.71–0.78 s after their notes, so click-to-start latencies include the automation's own delay and are not Arc's. Keys (Cmd+T, Esc, Cmd+S hide, Esc on the popover) start within 0.03 s of their notes.

### 20.13 Settings and the test Profile (items 1 and 2)

| Property | Measured | Evidence |
|---|---|---|
| Settings opens on | The account tab (the first tab). | notes 10:06:32 |
| Fresh Profile defaults | Search engine "Google"; "Include search engine suggestions" on; "Archive tabs after" "12 hours (default)" with the options 12 hours (default) · 24 hours · 7 days · 30 days (no 1 hour); New documents "——"; Download location "Downloads". The Profile list shows "<name> — N Spaces". | S2 02/0012, 0034 |
| Manage search | "Search Settings…" opens Chromium's search-engine settings in the main window (window title "Settings - Manage search …"). | S2 02/0018 |
| General ▸ Previews | No switch on the row, only "Previews Settings…". The sheet (422 x 370): "Show Arc Previews:", the copy in `sidebar-completion.md` §7 with a "Learn more" link, and **7 checkboxes**, all on: Arc Folders · Google Calendar · Google Mail · Outlook Calendar · Outlook Mail · Recent pages on Linear, Notion, and Figma · Notion Calendar; then "Done". | S2 02/0050 |
| A Space's Profile on disk | A Space on a non-default Profile stores `profile: {custom: {_0: {directoryBasename: "Profile 1", machineID: <UUID>}}}` (the default Profile is `{default: true}`, `data-model.md` §2.3). | `appsupport/s2-final/StorableSidebar.json` |

### 20.14 Not captured in session 2

- Item 15 (back-to-PiP) and what closing a mini player does to playback.
- Item 22, the auto-archive banner: Arc's "Archive tabs after" options are 12 hours, 24 hours, 7 days, and 30 days, so it could not be triggered within the session.
- The folder hover-preview card's colors, radius, and type: the card appeared once in the video (V 46.11–46.46 s, positions only, §20.4), not in any still frame.
- PiP hover controls and the PiP menu: they did not respond to synthetic events.
- The microphone and recording states (skipped: no live microphone).
- The Boost code editor body (it showed "Internal debugging pages are currently disabled").
- Peek motion, the tooltip delay, the first-hide hint (none showed on any path, notes 10:11:20), Favorite tile hover, and counts 6 and 7 in the grid.
- Any 2x display: corner shapes and glyph opacity stay 1x fits.

### 20.15 Site Control Center and Boost editor: design-pass measurements (items 9–11)

A second pass over the same frames for `plans/site-control-boost-editor.md` (2026-10-26). Method: window-point pixel scans and flood fills at 1x; colors converted from the embedded display profile to sRGB (as in §0); scripts in `.re/scb-design/tools/` (local only). Frame positions are window points; editor positions are editor-window points. "±1" means one pixel at 1x.

Site Control Center (S2 09/0010 without a Boost, 11/0005 with one; body x 83…318):

| Property | Measured | Evidence |
|---|---|---|
| Vertical stack (body top = 0) | padding 10 · action row 32 · gap 37 (holds the "Extensions" label) · extension tile row 32 · gap 43 (holds the next label) · rows of 32 pt icon circles, pitch 43 · 15 · separator 1 · 10 · footer 32 · 10. Total 297 without Boosts; one Boosts section adds 75 (372). | x 103/109 column scans, ±1 |
| Horizontal | 10 pt side padding for every block. Action buttons x 10, 66, 122, 178 (48 wide, gap 8). Icon circle x 10…42; row title x 50. Footer pill x 10, ≈ 82 wide; ⋯ circle x 194…226. | row scans, ±1 |
| Action buttons | 48 x 32 (edge rows included; §20.5 rounds to 31). Fill: a vertical gradient #272727 (y 103) → #212121 (112) → #1A1A1A (124) → #161616 (131) at x 96; 1 pt top highlight #575757 (first row). A 1 px dark ring outside the button (#343340 at x 92 and y 100 next to the material #47475B, ≈ black 0.3) and a 1 pt drop shadow (#212027 at y 132, #434154 at y 133). Corner insets ≈ 2.5, 1, 0.5, 0 per row (radius ≈ 6). On hover the highlight drops to #484848; nothing else changes. | S2 09/0010 vs 0016, 0018, 0019, 0021; PR #107 design review r1 |
| Labels | Section label 14 pt Semibold, #D9D9DD–#E0DBDE (ink width 55 for "Settings", 72 for "Extensions"; SF 14 Semibold advances 56.3 / 73.5, 13 Semibold 52.8 / 68.9); its baseline ≈ 14 above the section's first row. Row title 14 pt Semibold #DFDFE2 ("Developer Mode" ink 108 vs 109.6), cap top +2 and baseline +13 from the circle top; subtitle 13 pt Regular #9B9AA6–#A3A2AC ("Off" 19 vs 19.2, "Allowed" 47 vs 47.5), baseline +29. "Secure" 14 pt Medium (ink 46 vs 46.3); lock ink 10 x 14, 6 pt gap. Long titles end in "…" on one line ("Automatic Picture-In-P…"). Ink is about 1–1.5 pt narrower than the advance. | S2 09/0010; ink widths vs Core Text advances (PR #107 design review r1) |
| Icon circles | Disc #ECEDFF when on or allowed ("Allowed", "Enabled"); disc #84849A (translucent) when off. In both states the glyph is a **knock-out**: its pixels equal the panel material just outside the circle. "Allowed" gear core #545467 vs material #565669 (row y 304, x 92); "Off" hammer core #4E4E63–#525268 vs #515167 (row y 261); Boost brush #4A485F–#4C4A61 vs #4E4D65 (S2 11/0005, row y 261, x 88). So the "off" glyph reads darker than its disc. The Boost row uses the same circle with a filled paintbrush and sparkles. The open-state URL field button is the same kind: #ECEDFF square with see-through slider strokes (#454558–#67677A over the field #3A3A4C, S2 11/0011 y 66). | S2 09/0010; 11/0005; 11/0011 |
| Material fit | Probe coordinates are window points (3 x 3 mean). Fit probes: P1 (88, 215) over the dark sidebar (#252538) → #403E54; P2 (300, 140) over white → #7B7B7B. Per channel ≈ 0.28 × blur(backdrop, σ 5) + 0.72 × #49475A (blue keeps less of the backdrop: weight 0.21). Validation probes, not in the fit (ΔE00 of the fit vs Arc): (150, 330) #454459 → 2.1; (180, 240) #444257 → 1.7; (240, 330) #7F7F81 → 1.8; (260, 250) #7A7A7B → 1.2; misses near page content: (235, 180) #807F83 → 3.6; (300, 330) #7A7E88 over blue link text → 5.0. σ 15 fits worse (7.1 at (240, 330), where the blur pulls in the sidebar). The body is not uniform: §20.5's #47455A is another, unrecorded point. | S2 09/0004 vs 0010 |
| Separator, pill, ⋯ | Separator #66667B over the sidebar, #9C9EA1 over white (translucent white line). Pill fill #4A4A5E–#4C4C60 over #403E54; "Secure" #DBDBDF. ⋯ circle #595B5F. | S2 09/0010 |
| Arrow | The standard macOS popover arrow. Widths per row (partial pixels counted): y 81 ≈ 6.5, 82 ≈ 9, 83 ≈ 10.3, 84 ≈ 12.3, 86 ≈ 16.3, 88 ≈ 20.3, 90 ≈ 26 + base fillets; body top y 91. Width grows 2 pt per row, so the sides are at 45°; a 90° apex rounded with r ≈ 7 fits the ≈ 6 pt cap at the visible tip (y ≈ 81, 2 pt below the button's bottom edge y 79 and 1 pt over the URL field's bottom edge y 82). Centered at x ≈ 200.5 (button center 201 at width 228). | S2 09/0010 diff against 0004; PR #107 reviews r1 |
| Rim | A 1 px inner rim, ≈ white 0.20: top edge y 91 over the sidebar #75738F (x 120), #747390 (x 140), #7A7A8D (x 215), lighter than both the sidebar above (#252538) and the interior below (#515163–#636374); bottom edge y 387 #706C87–#77738E over the interior #4C4A60; arrow right side +0x1F over its interior. The left body edge reads only +4 to +6 levels (a 0.5 pt hairline is possible). The material is also ≈ 8 levels lighter in the first ≈ 6 pt inside the top and bottom edges. | S2 09/0010 with the 09/0004 backdrop; PR #107 design review r1 |
| Open motion | The popover window grows from the button: 38 x 47 at the button's center x during the open (`windows.tsv` in S2 09/0008); 266 x 405 (+1.5 %) one frame before 262 x 398 (S2 11/0003, 0004). | `windows.tsv` |
| Window stays active | The sidebar keeps its active color (#252538 at (20, 500) in both 09/0004 and 09/0010). | pixel probe |
| Boost row icon | Three 4-point sparkles (top-left, top-right, bottom-right of the wand glyph) fade in and out one by one while the pointer is elsewhere (an idle animation; 18 x 18 pt diff inside the icon). Period, fade duration, and curve are not measurable: the item 10 and 11 recorders give frame pairs 0.03–0.2 s apart with 1.6–2.5 s gaps, and `21-motion.mov` does not show the panel. | S2 11/0004–0017 and 10/0095–0108 (file times) |
| Site Control button sparkles | The three sparkles around the button also come and go from frame to frame, with the panel open and after it closed (10:27:44). Not measurable for the same reason. | S2 11/0011–0031 |
| ⋯ menu position | The native menu's top-left sat at the ⋯ center, where the synthetic click was (menu window 160 x 211 at screen (738, 654); ⋯ center (738, 660)). | S2 11/0011 `windows.tsv` |

Boost editor (editor-window points; S2 10/0030 unless noted):

| Property | Measured | Evidence |
|---|---|---|
| Window | Corner radius ≈ 12 (alpha profile). Not key while the simple controls are used; it becomes key and main only after a click into the code view (AX flags `focused,main` from S2 10/0079). While it is not key the browser window keeps its active look (sidebar (20, 500) #272538 in 10/0018–0070); once it is key the browser shows its inactive look (#0C0A1D in 10/0078). | S2 10/0041 alpha; AX; main-window probes |
| Placement | Screen x 2082…2265 for a browser window spanning x 445…2173: horizontally centered on the browser window's right edge (91 / 92 pt). Top 160 pt below the browser window's top. One sample; the rule is a guess (it may be a remembered position). | `windows.tsv` S2 10/0018 |
| Colors | Header #F5F5F7, hairline #E9E9EB at y 39, body #FDFDFF, buttons #EBEBED, font card #FFFFFF, labels #252526 (name) and #3A3A3B (buttons), Done circle #ACACAD, font glyphs #999999. | S2 10/0041 |
| Pad frame | Ring frame `[18, 58, 147, 147]`, plate `[25, 65, 133, 133]`, so the ring is 7 pt wide. Ring outer corner ≈ 20, plate corner ≈ 13–14. A soft shadow under the frame fades over ≈ 9 pt (#E8E8EA at the edge on #FDFDFF). | AX; S2 10/0041 scans |
| Dot grid | 1 pt dots on a 4.0 pt pitch, aligned to the plate origin; a dot reads #E8EDEB–#EAEAEA on the near-white plate (≈ black 0.07–0.08). | S2 10/0030 rows 141, 145 … and columns 33, 37 … |
| Plate | Near white (#FAFAFA … #FEFEFE before a color). After a color it carries a faint tint of the nearest ring color (for example #FBFFFA near green, #FDFAF6 near orange). | S2 10/0030, 0041 |
| Hue ring | A conic gradient around the pad center. sRGB at the ring midline, by screen angle clockwise from 3 o'clock: 0° #EB4838 · 30° #EB7636 · 60° #F4BA49 · 90° #D4FD58 · 120° #90FC74 · 150° #80FCAD · 180° #7CF8F1 · 210° #356FF6 · 240° #392EF4 · 270° #8237F5 · 300° #DD31BF · 330° #DF3470. Before a color the ring is grey; its grey levels follow the colored ring's Rec. 709 luma within ≈ 10 levels (for example 90° #EAEAEA, 225° #454545). | S2 10/0030, 0041 |
| Knobs | Primary: 30 pt disc, 2 pt white ring (34 outside), faint shadow; 38 pt disc during the drag (0039), 32 pt one frame later (0040). Secondary: 19 pt disc, 2 pt white ring, 1 pt grey outline (#C8C2CA). Each disc has a vertical gradient (center column, top / center / bottom): primary #4A2ABE / #5C3CC8 / #694CCB and secondary #321533 / #3D203C / #533953 (10/0041); no-color primary #636363 / #717171 / #7D7D7D and secondary #252525 / #333333 / #414141 (10/0030). | flood fills S2 10/0038–0044; gradients PR #107 design review r1 |
| Knob law | The secondary knob sits **45° clockwise** of the primary on the same radius: (0.0°, 40.0 pt) and (44.5°, 40.0 pt) before a color; (252.3°, 46.2 pt) and (296.6°, 45.8 pt) after. Each knob's fill hue equals its screen angle: primary #5C3CC8 (hue 253.6°), secondary #3D203C (hue 297.9°). Before a color: primary #717171, secondary #333333. | S2 10/0030, 0038, 0041 |
| Drag guide | While dragging, a ≈ 2 pt circle (≈ black 0.06) through the primary knob, centered on the pad center. Gone after the drag. | S2 10/0038–0040 vs 0041 |
| Page effect of one color | With the primary at hue 253.6° (archive.org): white #FFFFFF → #E4E2F3 (hue 247°, S 0.07); #FCF5E6 → #D4C7F8; #222222 → #56285D and #333333 → #632F6F (hue ≈ 290°, the secondary's hue, S 0.57). Icons and images keep their own colors. | S2 10/0018 vs 0039 (main window) |
| Font grid | Cells 26 x 26 at columns x 23, 51, 79, 106, 134 and rows y 281, 307, 333, 359 inside a white card `[18, 273, 147, 120]` (corner ≈ 11, soft shadow). The selected cell gets a full 26 pt circle #D9D9D9. No cell is selected before a font is chosen. | AX; S2 10/0030, 0046 |
| Font faces (visual) | Row 1: a system sans, Helvetica Neue, Avenir, Futura, DIN Alternate. Row 2: a bold rounded sans (guess: "Arial Rounded MT Bold", a string near the editor strings), PT Mono, Courier, Times New Roman, Charter. Row 3: Baskerville, Hoefler Text, Palatino, Chalkboard, SignPainter. Row 4: Snell Roundhand, Papyrus, Apple Chancery, Luminari, Wingdings. The 18 named faces follow the binary's string order (BO-18); the first and sixth cells are guesses. | S2 10/0030 zoom; `strings` on the Arc binary |
| Size and Case | A click shows a darker pressed fill only. No menu or popover window appeared and the page image did not change in the next frames. | S2 10/0050, 0056; `windows.tsv` |
| Advanced popover | Light `NSPopover` window 250 x 232 at editor (−34, 258), arrow up at the sliders button. Arrow (editor space, column-coverage scan): tip row y 260 ≈ 4.5 wide (2 pt below the button's bottom edge 258), then 7.7, 10, 11.9, 13.9, 15.8 (2 pt per row, 45° sides), then a flare into the body over y 266–270; body top y 271; centered at x ≈ 90.5 (button center 91.5). Material: translucent light, #EDEDED over the editor's #FDFDFF at editor (91, 300) and #E5E5E6 over the Zap button's #EBEBED at editor (26, 470). Body ≈ 222 x 205; labels 13 pt at y 299, 361, 423; sliders 186 x 16 at x −2 (18 pt body inset), knob 20 x 16, value 50 for each. The sliders button turns dark (≈ #474747) with a white glyph while the popover is open. | AX S2 10/0042; window 74512 (sRGB scan, this pass) |
| Code mode bars | Header 40: "Back" `[10, 9, 60, 23]`, CSS · JS segments `[190, 8, 50, 24]` + `[240, 8, 50, 24]`. Web view y 40…518. Bottom bar 70 pt, white, with "Pick Selector" `[15, 535, 38, 38]` and "Show Developer Tools" `[63, 535, 38, 38]`. | AX S2 10/0071 |
| Zap popup and bar | A white card ≈ 428 x 90 next to the element: "Zap this" (red), "Zap all related elements" (orange), "Cancel" (grey), each ≈ 38 tall, and a grey band with the match count and selector ("1 [lang="en"] app-root"). In the bar text, the word "Zap" is drawn in a light accent color; with the popup open the text is very faint lavender (darkest #DBDFFF on #FBFBFD). The bar's "Done" is a rounded rect 59 x 38, corner ≈ 8, fill #EDEEFF, 10 pt below the bar top. | S2 10/0060 |
| First-run card | The card starts at y 271; the area above it is dimmed by black ≈ 0.30 (#FDFDFF → #B1B1B3). Title #3139FF, flat terminals (not a rounded design), three lines with cap tops y 332 / 355 / 378 and baselines 347 / 370 / 393, ink widths 78 / 131 / 69 (SF Pro 22 Bold advances 78.3 / 130.8 / 71.3); body #95939F, two lines at y 411 (ink 107, 13 pt with the host Semibold); "Make a Boost" a vertical gradient #4E4FFF (y 493) → #4848FF (500) → #333AFF (530), flat horizontally, text ink 85 (14 Medium 88.8); "Maybe Later" ink 69 (12 Medium 71.8). Footer #CEDBFC under a sine edge: crests y 463.06 at x 7, 24, 41, 58, troughs y 466.98 (period 17, peak-to-trough 3.9). The badge has a ≈ 3 pt white border and tilts with its top edge rising to the right. | S2 10/0018; PR #107 design review r1 |
| Editor labels | Name "My Boost" ink x 51–107 (57; SF 13 Medium 58.0, 15 Medium 65.8), cap ≈ 9; chevron ink x 119–129 (11 x 6), gap ≈ 11; the group centers on x 90. "Size" 27, "Case" 32, "Zap" 25, "Code" 34 (14 Medium 27.8 / 33.2 / 25.5 / 34.9). "Zap" and "Code" ink starts at x 30 (12 pt inside the button at x 18); the bolt and braces end at x 150 / 165 (15 pt from the right edge). | S2 10/0030; PR #107 design review r1 |
