# Capture session 2: results and routing (2026-10-26)

This file routes the facts from Arc capture session 2 to the plans and PRs that use them. The measurements and frame citations are in `interaction-states.md` §20 (and §9 of `runtime-observations.md` for conditions and data files). Raw frames, the video, and the notes stay in `.re/` (git-ignored); none of them are committed.

Conditions: Arc 1.170.0, one AW2726DM display at 2560 x 1440 and scale 1.0, macOS Dark with the multicolor accent (item 20 in Light), window 1728 x 1084, two test Spaces ("Capture A", "Capture B") on a test Profile. Colors are sRGB after the embedded display profile (`runtime-observations.md` §0). Evidence notation: **S2 07/0122** = frame 0122 of the item-07 folder; **V 16.31 s** = time in `video/21-motion.mov`; **notes hh:mm:ss** = a line in `s2-notes.txt` with no frame.

"Change?" values: **must change** (the PR or plan contradicts Arc), **check** (the PR may already be right; verify), **agrees** (no change), **new work** (no open PR owns it yet), **open** (not captured).

## 1. Contradictions with lead decisions and plan answers

Read these first. Each row is a decision or a written plan answer that the capture contradicts.

| # | Decision or answer (file, section) | Arc fact (evidence) | PR |
|---|---|---|---|
| C1 | Site Control lead decision A: no pointer, panel at sidebar edge + 13 pt, anchor y 24 (`plans/site-control-boost-editor.md` §3.1, #69) | The panel has a **top arrow** at the Site Control button and **drops down from the URL field**, centered on the button (236 pt wide body at x 83–318 for a 228 sidebar), over the sidebar and the page. Only the theme editor sits on the sidebar edge without an arrow. (S2 09/0010; §20.5) | #69 must change; #96 follows |
| C2 | Site Control D-11: sections "header, actions, Settings, Boosts, Extensions" (§3.2–§3.3) | No header. Order is action row, **Extensions, Boosts, Settings**, footer. (S2 09/0010, 11/0011) | #69, #96 must change |
| C3 | Site Control action row: 6 buttons 44 x 36 incl. Copy URL, full page, portrait (§3.2) | **4** buttons 48 x 31, gap 8: Share, New Boost, Capture, Capture area. No Copy URL. (S2 09/0010) | #69 must change |
| C4 | SC-16: "New Boost…" in the ⋯ menu only when Boosts are not shown as a section (§3.7) | Shown also with a Boosts section. (S2 11/0011) | #96 must change |
| C5 | Sidebar Q3: the Previews sheet becomes "Show Open Previews:" with **two** switches (`plans/sidebar-completion.md` §8) | Arc's sheet has **7** source checkboxes (Arc Folders, Google Calendar, Google Mail, Outlook Calendar, Outlook Mail, Recent pages on Linear/Notion/Figma, Notion Calendar), and the General row has no master switch. Two switches can stay as an Open product choice, but it is not Arc parity. (S2 02/0050) | #102 check (decision for the lead) |
| C6 | Boost editor lead decision (Design 10, #103): font strip of 56 pt chips, 6 pt gaps, scrolling in a 232 pt viewport | A **5 x 4 grid** of 26 pt "Aa" buttons in a white card; no scrolling. (S2 10/0030) | #103 must change |
| C7 | Boost editor §4.4: hue ring 128 pt + disc pad (r 46) + 24 pt puck; three 28 pt round side buttons | A **147 pt square dot-grid pad** (a hue ring frames it after a color is chosen), **two** knobs, three **42 x 38** rounded buttons. (S2 10/0030, 0039) | #103 must change |
| C8 | Boost editor §4.5: four 54 x 54 colored tool tiles (Zap, Code, Text size, Text case) | "Size" and "Case" are half-width buttons (70 x 38); "Zap" and "Code" are full-width rows (147 x 38); fill `#EBEBED`, Zap dark `#333333` when on. The editor is light even in macOS Dark, 183 pt wide. (S2 10/0030, 0058) | #103 must change |
| C9 | Boost editor advanced sliders: inline block, order Brightness, Contrast, Original Saturation | An `NSPopover` (250 x 232), order **Contrast, Brightness, Original Saturation**. (S2 10/0042) | #103 must change |
| C10 | Theme Q2: a new Space starts with Brand preset `spaces.count mod 9` (`plans/space-theme-editor.md` §15) | A new Space gets **no theme** (the default theme) unless a color is picked in the New Space form. (both test Spaces; `appsupport/s2-final`) | #68 must change |
| C11 | Theme §5.8: the dial center cycles grain → sand → denim → tweed → grain | It cycles 4 textures, then **none** (noise 0), then repeats; each texture click sets noise to ≈ 0.8. (S2 17/0107–0123) | #89 must change |
| C12 | Theme §5.5: Remove and Add hidden in the empty state (guess) | Shown, both disabled. (S2 17/0006 AX) | #86 must change |
| C13 | Command bar Q1: hold-⌘ hints on by default (`plans/commandbar-completion.md` §8) | No hints after 2–4 s. (S2 18/0001–0003) | plan must change (not implemented) |
| C14 | Command bar Q9: (i) opens the Essential Keyboard Shortcuts window | (i) opens an **inline footer** in the bar ("We talk to your search engine…", "Search Settings…", "Dismiss"). (S2 18/0044) | plan must change |
| C15 | Little Open Q2: 720 x 540 centered on the pointer's display (`plans/routing-little-open.md` §14) | First frame **490 x 329 at the screen's top-right** (20 pt insets), a bare command bar; after load **1185 x 832**, same top-right corner. A second ⌥⌘N opens another window. (S2 19/0003, 0011, 0029) | plan must change |
| C16 | Sidebar §3.16: minimum 228; below it the sidebar slides; release under 180 hides | The resize **continues down to 164**; dragging past 164 slides it out while pressed. Cmd+S restores the pre-drag width. Double-click on the edge resets to 228. (S2 06/0009–0066) | sidebar lane A1 (not opened); app-shell's 180 pt rule |
| C17 | Sidebar Q13: no hint after a Cmd+S hide | Session 1 showed the hint after a Cmd+S hide (A0438); session 2 showed none on any path. So the hint shows once, on the first hide by any path (guess). (S2 04; notes 10:11:20) | sidebar lane A1 (not opened) |
| C18 | Media §4.1: speaker 20 x 20 after the title, filled glyphs | **Leading**: 26 x 26 button right after the favicon (x 41), title moves to x 69; outline glyphs. (S2 12/0022, 0027) | merged #67: follow-up PR needed |
| C19 | Media §4.2.3: card 68 pt with a title row, fill `SidebarColors.itemBackground`, corner 10, play group at the left | At rest a **33 pt** controls-only card: favicon, previous, play/pause, next, volume, evenly spaced (pitch 42); **opaque** `#050627` (default dark theme); corner 10 continuous (fit; the first read, ≈ 6, was visual). The title row appears only when expanded (66 pt). (S2 14b/0014, 0024) | #92 must change (spec: `plans/media-pip.md` §13) |
| C20 | Motion tokens: Space switch spring 0.30 s; command bar opens with a 0.22 s spring | Space switch: critically damped spring **0.20 s**; command bar: **no animation**. (V 35.05, 43.63 s; V 9.70–14.20 s) | #104 has the follow-ups (design.md §2.4 rows) |

## 2. Routing table by area

### 2.1 Window chrome (items 3, 5, 6)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Active traffic lights (`interaction-states.md` §0 caveat 2; status §5.2) | Session 1's grey was the inactive style, or Arc keeps them muted | Grey `#686973` with a colored 1 px ring while active; system colors and glyphs on hover; grey without a ring while inactive (S2 03/0001, 0007, 0016) | window buttons #104 | agrees (#104 already uses session 2) |
| Inactive window (design.md §3.3: 0.694 active / 0.83 inactive) | Fitted on light themes: lighter when inactive | The default dark theme **darkens** by ≈ 27 levels when inactive (`#282538` → `#0D0A1D`) (S2 03/0016). PR #104's card blend over black (`#0E091D`) matches it within ΔE00 0.4–1.1 (checked here) | #104 (follow-up filed there) | new work |
| Toolbar glyphs, dark (design.md §2.1) | Dark Home value a guess | Enabled white ≈ 0.59, disabled and inactive ≈ 0.25; Home and plus 0.59 active, 0.30 inactive (S2 03/0001, 0016) | — | check (design.md §2.1 updated) |
| Card bottom (design.md §16.4, ΔE00 10.8) | The card darkens toward its bottom | The card is **translucent**: it shows the blurred page under it (over white = the anchored sidebar within ΔE00 0.6; over a dark page 26 levels darker). F0129's bottom sat over blue page content (S2 05/0014, 0028; F0128) | #104 (follow-up filed) | new work |
| Card stroke | Seen on one side | On all four sides (S2 05/0014) | — | agrees |
| Sidebar minimum (app-shell Q3; sidebar C10, §3.16; design.md §2.2) | 180 pt hide threshold; 228 minimum | Minimum **164**; hide past it while pressed (S2 06/0029, 0035) | sidebar lane A1; app-shell | must change (C16) |
| Sidebar maximum (interaction-states §13) | 500 guess | **500** (S2 06/0072) | — | agrees |
| Double-click on the edge (menus-and-hotkeys "Gestures") | A recognizer exists | Resets the width to **228** (S2 06/0009, 0088) | — | new work |
| Narrow toolbar | — | At 207 and below: Back, Forward, "More options" (28 x 28); no toggle, no Reload (S2 06/0025–0029) | — | new work |
| First-hide hint (sidebar §3.12, Q13) | No hint after Cmd+S | None on any path in session 2; session 1 showed it after Cmd+S (S2 04; A0438) | sidebar lane A1 | must change (C17) |
| Link status bubble | — | Capsule 23 pt at the content's bottom-left (10 / 12 pt insets), `#0A0D4F` in the default dark theme (S2 04/0021) | — | new work |

### 2.2 Favorites, Today, and folders (items 7, 8)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Favorites columns (design.md §2.2, status row "Favorites grid") | Balanced rows of at most 4; only 6 seen | 1–4 in one row (tile widths 212, 102, 65.33, 47); 5 → 3 + 2 left-aligned (S2 07/0043–0139) | — | agrees |
| Empty Favorites (design.md §16.4 "not captured"; features-core §1 rule 2) | An 8 pt empty section | A dashed card "Drag to add Favorites" / "Favorites keep your most used sites and apps close", star icon, Dismiss button; section 105 pt (S2 07/0001) | sidebar lane (none) | new work |
| Selected Favorite tile, dark (design.md §2.1) | White 0.20 like a row | White ≈ **0.44**; inactive 0.24 + 2 px ring (S2 07/0140, 0163) | sidebar lane (none) | new work |
| Favorite tile menu (design.md §5.6; interaction-states §15) | Guessed | Copy Link · Share ▸ · — · Change Icon… · Rename… · Mute · Customize Page… · Edit Pinned Page ▸ · — · Open in Split View · Duplicate · Move to ▸ (Profiles) · — · Remove Favorite (S2 07/0185) | sidebar lane (none) | must change (Open's guess) |
| Space "More" button (interaction-states §2) | Expands on hover (guess) | 26 x 26 at `[W − 39, 205]`, plate white ≈ 0.08 (S2 07/0202) | — | agrees |
| "Archive Tabs Below / Above", "Archive Other Tabs" (sidebar Q14, Q16, C8) | ⌥ until C8; defer Below/Above | The visible Today tab menu ends with the normal items "Archive Tab" and "Archive Tabs Below" (lane S design reviewer agrees). AX lists "Archive Other Tabs" and "Archive Tabs Above" on the same frames, so they are their hidden **⌥ alternates** (derived; ⌥ was not held) (S2 07/0242, 0255) | Sidebar S2 #91 | check (#91 builds ⌥ Clear and Archive Other Tabs) |
| Folder expansion (sidebar S3) | `expandedItems` `{expanded: {}}` | Also `{peeked: {_0: [childID]}}`: a collapsed folder shows its last active child, its glyph shows "•••" (`FolderEllipses*` images; the lane S design reviewer saw the same); a click collapses fully, the next expands (S2 08/0090, 0100; V 46.49–55.04 s) | Sidebar S3 #95 | must change (state and glyph); import too |
| Folder row hover | — | White 0.10 fill and a "—" at the right (S2 08/0090) | #95 | check |
| New Folder placement | — | Above the Today divider (S2 08/0100) | — | check |
| Folder hover preview (sidebar §3.6, C4) | Look, size, delay guessed | Not captured (did not appear for synthetic events) | Sidebar S5 #102 | open |
| Previews sheet (sidebar Q3) | Two switches | 7 checkboxes (S2 02/0050) | #102 | C5 |
| Auto-archive banner (sidebar §3.11, C6, Q12) | Copy from strings | Not captured: options are 12 hours (default), 24 hours, 7 days, 30 days (S2 02/0034) | #102 | open |

### 2.3 Site Control Center (items 9, 11)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Anchor and arrow (§3.1; lead decision A) | No pointer, sidebar edge + 13 | Top arrow; drops from the URL field, centered on the button (S2 09/0010) | #69 | must change (C1) |
| Width (§3.2) | 320 | Body **236** pt | #69 | must change |
| Corner | 16 continuous (lead) | ≈ 16–18, continuous-looking (1x) | #69 | agrees |
| Fill (§3.2) | Opaque `Core.popoverBackground` | Translucent, blurred material: `#47455A` over the dark sidebar, `#7C7C7C` over white (S2 09/0010) | #69 | must change |
| Header | 48 pt favicon + host | None | #69 | must change (C2) |
| Action row | 6 buttons | 4 buttons (C3) | #69 | must change |
| Section order | Settings, Boosts, Extensions | Extensions, Boosts, Settings (C2) | #96 | must change |
| Section header hover | Accessory text + chevron | "Manage" at the right; Boost row hover shows a chevron (notes 10:47:57) | #96 | check |
| Footer (§3.7) | Security button + 28 x 28 ⋯ | "Secure" pill + **32 pt round** ⋯ button (`#5A5C60`) (S2 09/0010) | #69, #96 | check |
| ⋯ menu (SC-16) | Conditional "New Boost…" | Always shown (C4) | #96 | must change |
| Option held (Q8) | No change in v1 | ⌥ + click did not open the panel (notes 10:28:02) | #96 | agrees |
| Button state | — | Filled symbol while the panel is open; sparkles around it when the site has a Boost (S2 11/0011, 0016) | #69 | new work |
| Boost row menu | — | Rename this Boost… · Shuffle · Reset all Edits · Delete this Boost · — · All Boosts…; alert "Delete this Boost?" 450 x 273 (notes 10:48:09) | #96 or #103 | new work |

### 2.4 Boost editor and Zap (item 10)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Window (D-4) | Child `NSPanel` 268 pt wide (guess) | Its own window `boostsEditor`, 183 x 588, layer 3, at the browser window's right edge; light in macOS Dark (S2 10/0018) | #103 | must change (size, appearance) |
| First-run card | Interstitial | Wavy-edged card: "Edit the Internet with Boosts", "Make <host> your own!", "Make a Boost" (`#4848FF`), "Maybe Later" (S2 10/0018) | #103 | check |
| Color control (Q4; FA §4.6 q5) | Hue ring + disc + puck | Square pad + hue ring + 2 knobs (C7) | #103 | must change |
| Advanced sliders | Inline | Popover, Contrast · Brightness · Original Saturation (C9) | #103 | must change |
| Fonts (FA §4.6 q4) | Scrolling chips (lead) | 5 x 4 grid, 20 fonts (C6) | #103 | must change |
| Tools | 4 colored tiles | Size / Case halves; Zap and Code rows (C8) | #103 | must change |
| Zap (boosts-zap; SCB Q10) | List placement unknown | Bottom bar 56 pt "Click elements on the page to Zap them" + "Done", 3 pt blue content frame, yellow hover tint, popup "Zap this" / "Zap all related elements" / "Cancel" + selector; count on the Zap button; "Click to reveal" afterwards (S2 10/0060; notes 10:26:49) | #103 (later steps) | new work |
| Code mode (§4.8) | Panel switches mode | Window widens to 480 pt leftward: "← Back", CSS · JS, web view, "Pick Selector", "Show Developer Tools" (S2 10/0071). Body not captured | #103 | check |

### 2.5 Media (items 12–16)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Row speaker (MP §4.1, S9; design.md §4) | Trailing 20 x 20, filled | Leading 26 x 26, outline (C18) | merged #67 | must change (follow-up) |
| Visible tab (FA §8.5 q3) | No mini player (guess) | No mini player for the selected tab (S2 12) | #92 | agrees |
| Mini player placement (Q1, D-3, PP-20) | Above the bottom bar, 4 pt margins | Card bottom on the bottom bar's top edge (0 gap), 8 pt below the tab list (S2 14b/0014) | #92 | must change (margins) |
| Card layout (§4.2.3) | 68 pt with title row | 33 pt controls-only at rest; 66 pt expanded (C19) | #92 | must change |
| Volume (S5, Q8) | Drawer | Click expanded the card; no drawer seen; tooltip "Adjust Tab Volume" (S2 14b/0024) | #92 | check |
| Stack (S6, Q2, PP-14) | Back cards 5 pt up, 6 pt inset, opacity 1 − 0.3·i; expanded gap 6 | Back cards **7** pt up, insets **5 / 10** per side (AX button positions), opacity ≈ 0.8 / 0.6, not masked; expanded 66 pt cards, gap **5**, newest at the bottom (S2 16/0005, 0012) | #92 | must change (numbers; `plans/media-pip.md` §13.3.4) |
| How many (Q2) | 3 | At least 3 shown (S2 16) | #92 | agrees |
| Auto-PiP window (S1) | Chromium window in phase 1 | 320 x 180, 10 pt from the screen's bottom-right, corner ≈ 6, video only at rest (S2 13/0002; the media lane measured the same). The lead's first-open rule `visibleFrame` / 8 gives 2560 / 8 = 320 here; one display and one 16 : 9 video, so consistent but not proven | #101 | agrees (size and inset); check (other screens) |
| PiP and the sidebar (MS1) | Source with open PiP has no card | Confirmed: no mini player while PiP shows (S2 13) | #92 | agrees |
| Return to the tab (Q6) | Manual PiP stays | Auto-PiP closes when its tab is shown (notes 10:32:08); manual PiP not tested | #101 | check |
| PiP hover controls, menu, back-to-PiP, close behavior (S2, S4, S7, Q5, Q17) | — | Not captured | #101 | open |

### 2.6 Theme editor and New Space (items 1, 17)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Automatic flip (Q3; design-tokens §6.4) | Bias 0.0 (data allows −0.78 … 1.60) | Dark text for grey swatches 1–5, light for 6–9: the flip lies between keys `#808080` and `#666666`. derived: with the measured text colors as titles, bias must be in about −0.78 … 1.42, so 0.0 still fits (S2 17/0028–0044) | #82, #89 | agrees |
| 3 colors (Q10) | Harmony knobs 30 pt, not draggable | Max 3; extra knobs ≈ 28 pt, move with the primary (draggable not tested); "+" adds nothing on a grey (S2 17/0052–0082) | #86, #89 | check |
| Pad radius | Lightness by radius (decoded) | Confirmed: center deep, edge pale (S2 17/0092–0096) | #86 | agrees |
| Intensity (Q4) | `alpha = 0.8 × intensity` | At 0 the wave is a flat line and the color turns almost grey (`#CEC6C7`); at 1 `#E5CACB` (S2 17/0099–0103) | #82, #89 | check (calibrate) |
| Noise dial | 4-texture cycle | + none; texture click sets ≈ 0.8 (C11) | #89 | must change |
| Modes (§12.3) | Remap lightness | Light/Dark force the popover's and the page's appearance; a pale color keeps the sidebar pale; no mode key found on disk (S2 17/0156–0163) | #68, #89 | check |
| Preset page 2 (Q5) | Brand with 3 analogous colors | Swatches drawn as two-tone gradients (supports Q5); not clicked (S2 17/0016) | #89 | agrees |
| Empty state | Remove/Add hidden | Disabled (C12) | #86 | must change |
| New Space form (Q6) | Sidebar page | Confirmed: "Create a Space" sidebar page with a full-width "Create Space" button and "Cancel"; the theme editor opens beside it with a left arrow (S2 01/0132–0136) | #68 / #86 | agrees |
| First theme (Q2) | Brand preset | No theme (C10) | #68 | must change |
| Editor in Light (Q9) | Light guesses | White popover, dark icons (S2 20/0027) | #86 | check |

### 2.7 Command bar (item 18; plan not implemented)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Hold-⌘ hints (Q1) | On | Off (C13) | plan | must change |
| Completion keys (Q6, Q7) | Native rules | Completion with the added part selected; Backspace removes it (S2 18/0009–0010). Right and Left not isolated | plan | open (arrows) |
| Site Search (commandbar.md §11 q5) | Scope chip | Orange chip "Wikipedia" (`#FFA000`), empty field after it, orange selection; Backspace on empty removes the chip (S2 18/0016–0021) | plan | new work |
| (i) target (Q9) | Shortcuts window | Inline footer (C14) | plan | must change |
| Open/close motion (commandbar.md §11 q4) | Scale from center | None (V 9.70–14.20 s) | #104 follow-up | must change (Open animates) |
| Light appearance (commandbar.md §11 q3) | — | `#F8F8F8` fill, `#8E95FF` selection (S2 20/0018) | plan | new work |

### 2.8 Little Arc (item 19)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Size and position (RLO Q2; FA §3.5 q1; M4 Q7) | 720 x 540 centered | C15 | plan | must change |
| Reuse (FA §3.5 q4, q6) | — | A new window each time (S2 19/0029) | plan | new work |
| Title bar | — | 47 pt: buttons at x 9 / 32 / 55, Profile chip, centered host, copy-link, "Open in <Space> ⌘O" pill + chevron "More Spaces" (S2 19/0011, 0025) | plan | new work |
| Move to Space (RLO Q8; FA LA-6) | Today top only; list of Spaces | The chevron opens a searchable Space list (S2 19/0023); placement not captured | plan | agrees in part |
| Window state on disk (DM §6 item 4) | Unknown style key | `style.little {…, session {entryPoint, preferredFrame {anchor {topRight}, size}}}` (`appsupport/s2-little-arc-open`) | import plan | new work |

### 2.9 Light appearance (item 20)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Default theme in Light (design.md §3.5) | `#EDEDF1` … (guess) | `#DBDBF3` / `#ECE0E4` / `#E8E0ED` / `#F1E2E2`; ΔE00 4.7–9.1 from Open's guess (S2 20/0015) | sidebar lane (none) | must change (`SpaceThemeStyle.defaultTheme`) |
| What follows the system (interaction-states §19 item 6) | — | A Space without a stored theme follows macOS; themed Spaces follow `contentOverBackgroundAppearance` (session 1) | — | agrees |
| Card in Light (design.md §16.5 `card_edges_appearance`) | Faint stroke | Faint lighter stroke, visible shadow; fill a little lighter than the sidebar over a white page (S2 20/0040) | — | agrees |
| Toast on a light Space (PP C-T1) | Theme fill rule | Lavender pill, dark text (S2 20/0048) | — | check |
| Mini player in Light (MP S3) | — | Not captured. Provisional rule: the fill is the Space palette's `light.backgroundExtra` (`#FDFDFF` for the default theme), guess (`plans/media-pip.md` §13.4.2) | #92 | open |

### 2.10 Motion (item 21, video)

PR #104's agent timed the same video independently (Cmd+S ≈ 0.1 s each way, show ≈ 0.29 s after the key, card in ≈ 0.14 s with a 3 pt overshoot, no Cmd+T animation, folders ≈ 0.22 s). The rows below agree with it within one video frame.

| Token (design.md §2.4) | Open value | Arc (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Space switch slide | spring 0.30 s, critically damped | spring **0.20 s**, critically damped, settled ≈ 0.27 s (V 35.05, 43.63 s) | #104 (row) | must change |
| Row insert, folder expand | 0.22 s | expand ≈ 0.20 s ease-out; collapse ≈ 0.25 s (V 46.49–55.04 s) | — | agrees |
| Cmd+S hide / show | 0.22 s | ≈ 0.10 s each (spring ≈ 0.1 s, damping 0.9–1.0); show starts ≈ 0.29 s after the key (V 16.26–32.41 s) | #104 (follow-up) | must change |
| Hover-reveal card | spring 0.30 s, critically damped | in ≈ 0.13 s, 3 pt overshoot, settled ≈ 0.24 s (spring ≈ 0.16–0.18 s, damping ≈ 0.8–0.86); out ≈ 0.10 s (V 26.63, 29.50 s) | #104 (follow-up) | must change |
| Command bar open/close | spring 0.22 s | none | #104 (follow-up) | must change |
| Toast | scale-up | in ≈ 0.20 s from the top center, shown ≈ 4.95 s, out ≈ 0.16 s (V 69.99–75.11 s) | — | check |
| Popover open (`Motion.popoverOpen`, SCB §3.8: 0.18 s) | 0.18 s | theme popover in ≈ 0.20 s with a small overshoot, out ≈ 0.19 s (V 79.06, 80.74 s) | #69, #86 | agrees |
| Tooltip delay (0.6 s guess), Peek | — | Not captured | — | open |

### 2.11 Settings (item 2)

| Plan item | Old guess | New fact (evidence) | Open PR | Change? |
|---|---|---|---|---|
| Fresh Profile defaults (FC App. C 1–2; settings-library 1, 6) | — | Google; suggestions on; "12 hours (default)" of 12 h / 24 h / 7 d / 30 d; New documents "——"; Downloads (S2 02/0012, 0034) | — | new work (settings-library) |
| Banner threshold text (sidebar Q12) | Insert the Profile's threshold | The menu's labels are "12 hours (default)", "24 hours", "7 days", "30 days" (S2 02/0034) | #102 | check |

## 3. Top findings

1. The Site Control Center has a top arrow and drops down from the URL field, centered on its button (C1).
2. Its sections are action row, Extensions, Boosts, Settings, with no header and 4 action buttons (C2, C3).
3. The hover-reveal card and the Site Control Center are translucent: they show the blurred page behind them. This explains the card's "darker bottom" (§2.1). PR #104 derives the same blend for the inactive window background (guess there).
4. The Boost editor is a light, 183 pt window with a square pad, a 5 x 4 font grid, and row-style tools (C6–C9).
5. Mini players are 33 pt controls-only cards at rest; the speaker on a row is leading, after the favicon (C18, C19).
6. The sidebar minimum is 164; a double-click on the edge resets to 228 (C16).
7. A collapsed folder can show its last active child, stored as `peeked` (§2.2).
8. Little Arc opens as a 490 x 329 command bar at the top-right and grows to 1185 x 832 (C15).
9. A new Space starts with no theme; the noise dial cycles through "none" (C10, C11).
10. Motion is faster than Open's tokens: Space switch 0.20 s, Cmd+S ≈ 0.1 s, and no command bar animation (C20).
11. The Previews sheet has 7 sources (C5); hold-⌘ hints are off; (i) opens an inline footer (C13, C14).
12. The default theme in macOS Light is lavender to pink, ΔE00 4.7–9.1 from Open's guess (§2.9).

## 4. Not captured (still open)

- Item 15: back-to-PiP, and what Close on a mini player or PiP does to playback.
- Item 22: the auto-archive banner. The shortest "Archive tabs after" option is 12 hours, so it could not trigger in the session.
- The folder hover-preview card (no preview for synthetic pointer events).
- PiP hover controls and the PiP menu (no response to synthetic events).
- The microphone and recording states (skipped), so the recording dot and recording mini player stay open.
- The Boost code editor body ("Internal debugging pages are currently disabled").
- Peek motion (the Shift-click hid the sidebar instead) and the tooltip delay (the pointer missed Reload).
- Favorites with 7 or more tiles, Favorite tile hover, and the first-hide hint (none showed).
- A 2x display: corner shapes and glyph opacity are still 1x fits.
