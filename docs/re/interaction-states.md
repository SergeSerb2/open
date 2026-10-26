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
2. **Traffic lights are grey in every frame** (`#CD866C` on `#E69679` in Space 1, `#696873` on `#252539` in Space 4), even while the user typed into Arc. Active-window colors were not captured. guess: the capture shows the inactive style, or Arc keeps them muted.
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
| Hover, light-content Space (Space 1) | `[8, y+2, W−16, 36]` | black, a ≈ 0.048 (C/B = 0.951/0.954/0.952 on R/G/B) | ≈ 12 circular fit (row insets 6.3, 4.8, 3.6, 2.7, 2.0, 1.4, 1.0, 0.6) | F0013 vs F0012, F0031 vs F0030 (New Tab row, same values) |
| Hover, dark Space (Space 4, no theme) | `[24, y+2, 196, 36]` for a folder child (indent 16) | white, a ≈ 0.10 (`#3B3A4C` on `#262538`) | same shape | F0079 |
| Selected, light-content Space | `[8, y+2, W−16, 36]` | `#F6EBE7` opaque look. Closest token: the Space's `light.background` `#F6EAE4` (guess). Not a white overlay: a white fit gives a = 0.62 / 0.81 / 0.82 per channel. | same as hover | F0014, Today row F0066 |
| Selected shadow (light) | below the fill | darkening 14% at 1 px below, 5.5% at 2 px, 2% at 3 px. 1% at 1 px above. 1–2 levels at the sides. guess: black ≈ 0.2, blur ≈ 1.5, y +1. | | F0014 rows 240, 277–279 |
| Selected, dark Space | `[8, y+2, 212, 36]` | white, a ≈ 0.20 (`#51505F` on `#272538`) | | F0084 (Today row) |
| Selected, dark-content theme (olive, grain) | `[16, y+2, …]` | white, a ≈ 0.20 (noisy because of grain) | | F0161 |

Row controls:

- **Close button** on hover and on the selected row: `[189, y+7, 26, 26]` (AX id `closeButton`, F0013, F0019, F0014). Its right edge is 4 pt inside the fill. The title frame shrinks from 168 to 146 wide while it shows (F0014).
- **Pinned selected row** shows a horizontal bar glyph ("—") in the close slot, not "x" (F0014 crop). guess: "reset to pinned URL / unload" (`features-core.md`).
- A pinned tab whose page moved away from its saved URL shows a "/" between icon and title (A0414, folder child). guess: the "navigated away from pinned URL" mark. Measured on F0090 and F0101 (depth 1): a 2 pt stroke about 14.5 pt tall (rows y+12 … y+26), about 8° from vertical (center x 57 at the top, 55 at the bottom), peak white ≈ 0.30 over the background (`TabCellSlash`). The title moves 2 pt to the right (AX title x 61 instead of 59).

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
| Fill | The Space's `light.title` color, opaque (`#320E00` in Space 1, exact match) | F0021, F0025, F0029, F0033 |
| Text | Light, tinted. About 13 pt (AX text frames 15 pt tall). guess: Medium. | `ax.json` of the tooltip windows |
| Second line | "Double-click to rename" on tab rows, dimmer, 14 pt frame | F0021 |
| Shortcut | Keycaps after the label, e.g. "⌘" + "[" or "⌃" + "2". Each key is its own text (13 pt frame) on a small rounded cap tinted with the Space color. | F0025, F0026, F0029 |
| Window | Capsule plus 33 pt of shadow margin on each side (window 93 pt tall for a 27 pt capsule). Shadow: soft, wide. | `windows.tsv`, F0029 |
| Placement | Toolbar tooltips below the button. Bottom-bar tooltips above the bar. Row tooltips beside the pointer. | F0025, F0029, F0021 |
| Animation | Fade out seen (F0026 is half transparent) | F0026 |

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
| Hint toast | First hide shows a toast at the window's top-right: "You can use [⌘S] to easily show and hide your Sidebar!". Dark, Space-tinted rounded rectangle with a keycap. Own window 600x600 (layer 0), anchored at the window's top-right. Gone after about 6 s. | F0128–F0131, A0438–A0447 |
| Hover-reveal | A floating card `[5, 5, W_sidebar, H−10]` (here 500 x 1384): 5 pt from the window edges. Corner ≈ 10 pt. 1 px light stroke (white a ≈ 0.25). Small shadow (7.5% at the edge, 0 by 8 pt). The card shows the Space background and all sidebar content, with the traffic lights at its top. | F0130 pixels and AX |
| Toolbar button | Its AX desc changes from "Hide sidebar" to "Lock sidebar" while the card shows | F0128, F0131 |
| Hide animation | The sidebar slides out to the left as a card while the web content grows | A0436–A0438 |
| Width | 228 → 500 in one drag. `sidebarWidth` = 500 on disk. guess: 500 is the maximum (the user aimed for the widest stop). | F0126–F0127, A0424 → A0431 |
| Minimum | Not captured. A0422 shows the sidebar sliding out during the narrow drag. guess: dragging below the minimum hides the sidebar. | A0422 |
| Other windows | A new window (Cmd+N) also uses 500 | F0157 AX |

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
