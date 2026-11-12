# Sidebar themes, editor, Spaces, Profiles and Boosts (capture session 3)

Observed in unmodified Arc 1.172.2 (90755) on the M1 built-in display at 2×, window 1280×800 pt, sidebar 366 pt,
2026-11-11. Colours are sRGB, converted from the display's embedded ICC profile. Every sample point comes from an AX
frame of the same shot. This file holds our own observations only: no Arc assets, images, titles, URLs or profile data.
Evidence names refer to the private `s3-sidebar-themes/m1/{arc,open}/<series>/<block>/` captures. Pages were synthetic
loopback fixtures; the test Spaces ("Capture Test", "Capture Test 2") and the test Boost were deleted afterwards.

## 1. Theme → sidebar colours

Only two sidebar roles take the Space hue: the background and the primary tab title. Every other role is plain black
(light content) or plain white (dark content) at a fixed opacity over what is under it, the same on all 45 theme shots
(`C-measurements-s3`, fits in `part-a-fits.json`):

| Role | Light content | Dark content |
|---|---|---|
| Tab subtitle (host, only with Developer Mode) | black 0.50 | white 0.50 |
| Space title | black 0.45 | white 0.45 |
| "New Tab" label / plus icon | black 0.30 / 0.50 | white 0.45 / 0.50 |
| URL field placeholder / loaded host | black 0.30 / 0.60 | white 0.30 / 0.60 |
| Bottom-bar icon | black 0.55 | white 0.58 |
| Toolbar back/forward (disabled) | black 0.22 | white 0.25 |
| Separator line | black 0.15 | white ≈ 0.15 |
| URL field and favourite tile fill | black ≈ 0.045 | white ≈ 0.10 |
| URL field hover fill | black 0.09 | white 0.15 |
| Row hover plate | black 0.08 (default theme 0.046) | white 0.06–0.10 |
| Active row plate | near-white hue tint (inference: palette `light.background`) | white ≈ 0.14–0.20 |

Primary titles are hue tints, for example `#001D26` on blue presets, `#36000A` red, `#090D4E` default light,
`#DEDFFF` default dark. Evidence: `s2/06-hues`, `s4..s6/09*-cases`, `s11/21-ct2-states`.

Text polarity is chosen from the Space key colour, not from the drawn sidebar. The decoded content-appearance rule
(`design-tokens.md` §6.5: contrast of the key against the two palette title colours) predicted 7 of 8 boundary pad
colours; the miss had a margin of −0.05 (on the boundary). A bias 0.05 ≤ b < 0.35 fits all 24 pad observations.
Because the drawn sidebar is lighter than the key, mid-tone keys get light text at only 2.2–2.7:1 (active row
1.8–2.3:1). Evidence: `s15/19b-polarity`, `s6/10-pad`, `s11/19-polarity`; script `polarity.py`.

The editor's sun/moon buttons do not force polarity in 1.172.2; they change the drawn lightness (Dark ≈ 0.85–0.92 ×
each channel of Light for presets) and the editor/web appearance. The default theme (no colour) follows Arc's View ›
Appearance: Light `#E4DFEF` with a diagonal gradient `#D9DAF4` → `#ECE3EC`, Dark `#2A2538`.

Shapes: one colour is flat; two colours blend top to bottom; three add an overlay toward the bottom right. Intensity
moves chroma between grey and full at about the same lightness; grain adds ≈ ±6 levels of speckle; neither changes
text colours. The active sidebar is opaque: the same theme gives identical values at three window positions
(`s9/16-blend`).

## 2. Theme editor

Entry points: menu bar "Edit Theme…", the Space context menu "Edit Theme Color…", the command bar ("theme" → "Edit
Theme…"), and "Choose a Theme" in the New Space form. AX popover 382 × 534 pt (content inset 13) whose left edge sits
on the sidebar's trailing edge; mode buttons (Automatic, Light, Dark) 32 × 32 at (135/175/215, 45); pad 340 × 340 at
(21, 21); Remove/Add 32 × 32 at (155/195, 313); preset pages with 9 swatches of 24 pt at a 29.5 pt pitch (5 pages:
Brand, gradient pairs, Pastel, Drab, Greyscale); intensity slider (31, 437, 224, 56); grain button and slider at
x 271. Every control applies live; the sidebar switches in one frame. Esc or a click on the page closes it. Motion:
open grows from the left edge, full size in ≈ 0.17 s, a ≈ 4 pt overshoot, rest by ≈ 0.33 s; close fades in ≈ 0.125 s.
Evidence: `s7/13-editor`, `s8/13b-editor-rest`, `s8/14-editor-motion`.

## 3. Sidebar anatomy and states (W = 366)

Traffic lights 16 pt at x 12/35/58; toolbar buttons 32 × 32 at x 77 and 260/294/328, y 7.5. URL field and every row
plate share x = 8 and width W − 16 (also at W = 286). Favourite tiles 111.3 × 47 in 3 columns at x 8/127.5/246.5.
Rows 41 pt (button 40); favicon 18 at x 17; title at x 43, W − 60 wide; folder children indent 16. Separator row
17 pt. Bottom bar: button at (8, 759), Space dots 36 × 34 at a 34 pt pitch, "+" at (326, 759).
Width: minimum ≈ 166 pt; dragging below it hides the sidebar and shows the hint toast "You can use ⌘S to easily
show and hide your Sidebar!"; maximum ≈ 500 pt; the grab zone is just right of the sidebar edge. ⌘S hide ≈ 0.07 s,
show starts ≈ 0.155 s after the key and runs ≈ 0.075 s.
Row states: hover adds the plate, a 26 pt close "×" and, after ≈ 0.6 s, a tooltip with "Double-click to rename";
playing audio adds a 26 pt speaker button at x 41 and moves the title to x 69; a pinned tab away from its URL shows
"/" before the title and a "—" reset button on hover; Rename turns the title into an inline field.
Drag: Arc opens two drop-target rails (80 pt at the window's left edge, 30 pt at the sidebar edge) and a full-screen
drag layer; over a folder the folder row fills and its glyph opens; inside Today a 2 pt drop line in the theme's
shadedDark colour with a ring at its left end marks the slot. Evidence: `s10/17-anatomy`, `s21/27-widths`,
`s22/32-show-width`, `s24/18-drag`, `s26/29-audio`, `s26/28b-rename`, `s18/28-states`.

URL field: Copy Link and Site Controls are absent at rest (not in AX) and appear when the pointer enters the
sidebar anywhere (`s5/11a`, `s5/11b`, `s7/12-devoff`).

## 4. Spaces, Profiles, Boosts

Spaces: ⌃1–9 select by dock order; ⌘⌥←/→ previous/next; a two-finger horizontal swipe on the tab list moves the
sidebar with the fingers and switches (60 pt at ≈ 170 pt/s was enough). A new Space is inserted after the current
one. Delete asks "Delete your "‹Space›" Space?" ("This will archive all the tabs and folders inside it.") and shows a
"Space deleted! Use ⌘Z to undo." toast. Evidence: `s21/22-spaces`, `s33/41-delete-spaces`.

Profiles: Settings › Profiles lists Profiles with their Space counts and per-Profile settings; "Change Profile" is a
centred dialog with a Profile pill; New Profile is a two-step dialog (name, then Space cards with checkboxes).
Favourites are per Profile: a Space on a new Profile shows a dashed "Drag to add Favorites" card; the Space dot
tooltip shows the Profile name. Evidence: `s25/24-profiles`, `s27/37-profile-create`, `s28/37b-profile`.

Boosts: entry points are the Site Controls panel, the command bar, the "+" popover ("New Boost") and Library ›
Boosts. The editor is a separate 183 × 588 pt panel (Done, "‹name› ⌄", Undo, colour pad with Invert / Advanced /
Reset, a 5 × 4 font grid, Size, Case, Zap, Code). Code widens it to 480 pt (CSS/JS tabs, Pick Selector, Show Developer
Tools). Invert darkens the page, Size zooms 110 % with a badge, Case upper-cases text, Zap fills the hovered element
yellow. A Boost is saved once a control changes the page; delete is in the title menu ("Delete this Boost" →
"Delete this Boost?"). Evidence: `s26/34-boost-editor`, `s32/38-boost-controls`, `s38/44-boost-title-menu`,
`s39/45-delete-boost`.

## 5. Open (main bac09a36) against Arc

The largest difference: Open chooses text polarity from the forced mode, Arc from the key colour, so Open's Dark mode
on light colours gives 1.0–1.7:1 titles where Arc gives 7.9–12.2:1. Open also keeps the same background in Light and
Dark and uses a neutral light default instead of Arc's lavender gradient. Evidence: `m1/open/s30/H1-themes-open`.
