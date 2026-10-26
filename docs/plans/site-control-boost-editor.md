# Site Control Center and Boost editor — implementation plan for Open

Status: plan, revised 2026-10-26 from Arc capture session 2 (first version 2026-10-25).
Implementer: a coding agent with no other context. Follow this file top to bottom. Where it says
"Open choice", the choice is final for v1 unless a lead decision in Appendix C changes it. Where
it says "guess", build the stated value and keep the value in one token so a later capture changes
one line. Where it cites a frame ("S2 09/0010"), the value is measured; the notation is defined in
`docs/re/interaction-states.md` §20.0.

Read first, in this order: `AGENTS.md`; `docs/architecture.md`; `docs/re/interaction-states.md`
§20.5, §20.6 and §20.15 (the measured facts this revision uses); `docs/re/capture-session-2-results.md`
§1 (C1–C9) and §2.3–§2.4; `docs/re/features-advanced.md` §4 (Boosts), §5 (Zap), §6 (Site Control
Center), §7 (ad blocking); `docs/boosts.md`; `docs/plans/boosts-zap.md` §0.2, §3, §8–§9 and
Appendix C; `docs/plans/space-theme-editor.md` §2.2 and §5.3 (the pad this plan reuses);
`docs/adblock-lists.md`; `docs/plans/adblock-fork.md` §12; `docs/plans/app-shell.md` §2, §4.5,
§4.6, §4.9, §6; `docs/plans/settings-library.md` §2 and §5.5; `docs/engine-api.md`;
`docs/automation.md`; `docs/design.md` §2 and §7.

User-visible names: never "Arc". "Import from Arc" is the only exception. Arc strings quoted in
this plan are facts used for parity; any that name Arc are rewritten in Open's own words.

What changed in this revision (details in §12 and Appendix C): the Site Control Center drops down
from the URL field with a top arrow, has no header, is 236 pt wide and translucent, shows 4 action
buttons, and orders its sections Extensions, Boosts, Settings as rows (not tiles). The Boost editor
is a light 183 × 588 window with a square color pad (not a hue wheel), an advanced-colors popover,
a 5 × 4 font grid, and Size / Case / Zap / Code buttons. §12 says what changes in open PRs #69, #96
and #103.

## Goal

Ship the two Boost and site surfaces that `docs/plans/boosts-zap.md` §0.2 left out:

1. **Site Control Center** — the per-site panel that drops down from the URL field's Site Control
   button (and from a split pane's bar). It shows page actions (Share, New Boost, two Capture
   actions), the window's extensions, the Boosts that match the site, site settings (changed
   permissions and content blocking), the connection security state, and a "⋯" menu (clear cookies
   or cache, manage Boosts and extensions, all site settings).
2. **Boost editor** — a floating light window for one Boost on the current site: color pad, invert
   lightness, advanced color sliders, a font grid, text size, text case, Zap, CSS and JS code,
   rename, delete, shuffle, reset, undo, per-site scope, and live preview on every matching tab.
   Plus a **Boosts list** in the Library for all Boosts of a Profile.

Both surfaces only edit data that already has an owner: `BoostStore` (OpenBoosts),
`AdBlockStore` (OpenAdBlock), Chromium content settings (through `OpenWeb.WebProfile`), and the
engine extension state. This plan adds no second store for any of those values (§5).

## Success criteria

1. Clicking the URL field's Site Control button opens the panel in ≤ 1 frame of main-thread work
   (< 8 ms from click to first draw, release, M5 Pro). Esc, a click outside, or a second click on
   the button closes it. Idle CPU stays at zero while it is open.
2. Every control in §3 writes exactly the store in §5 and the live effect happens at once: a
   permission row changes the Chromium content setting; the ad-block row changes the Profile's
   `exclusions.json` and the engine exclusion set; a Boost row's circle changes `isEnabled` and the
   page re-renders without a reload (CSS components) within 100 ms.
3. "New Boost" creates a Boost for the site and opens the editor. Each editor control changes the
   live page within one frame of input for the active tab (drag) and within 150 ms for other
   matching tabs. Closing the editor on an unchanged new Boost deletes it.
4. Zap mode starts from the editor, picks elements on the live page with the existing picker, shows
   the count on the editor's Zap button, and exits on Esc, Done, the Zap button, editor close, tab
   switch, or navigation. No Zap message is accepted without the native session capability
   (`docs/boosts.md`).
5. The CSS panel applies live as the user types. The JS panel shows "Refresh to Run" until the page
   reloads with the new JS. Both editors are native AppKit text views with syntax colors, line
   numbers, and no third-party dependency.
6. Keyboard: every control is reachable with Tab; the panel and the editor have the key handling in
   §3.12 and §4.12. VoiceOver reads every row, button, and slider with a label and a value.
7. `sitecontrol-render check` passes: flows, a render of every state at 1x and 2x, the geometry
   probes in §8.1, and the budgets in §7. It runs in `tools/verify-all.sh`.
8. Two automation suites in `tools/e2e/engine_e2e.py` — `sitecontrol` and `boosteditor` — pass on
   the real app once the app-shell hooks exist (§8.2).
9. No unit tests (`AGENTS.md` rule 6). No Arc asset in the repo (`AGENTS.md` rule 1): the hue ring,
   the dot grid, the wavy footer, the first-run icon, and every glyph are drawn by Open.

## Non-goals

- Boost sharing, install links, the online Boost Gallery, "Report Boost", preview images, Boost
  authors (BO-6; accounts are out of v1 scope). `boost-gallery` stays disabled.
- Arc's palette-remap color engine. Open keeps the CSS-filter runtime (`ColorAdjustment`, lead
  decision Q4). §4.4.4 records what the capture shows about Arc's remap and Q12 asks the lead to
  revisit Q4 with that evidence.
- A certificate viewer of our own. The security pill opens the system certificate panel once the
  engine reports the chain (E3). Until then it shows the state only.
- A cookie browser or a site-data size display (SC-8: no evidence in Arc).
- The per-site Developer Mode tool bar and the per-site Preview toggle. Their rows stay hidden in v1
  (Q2, Q3), although Arc shows a "Developer Mode — Off" row by default (S2 09/0010).
- Monaco or any web-based code editor. Fonts beyond the macOS system set.
- Peek and Little Open entry points. The panel is unavailable in a Peek and in Little Open (§3.1).

---

## 0. Locked decisions

| # | Decision | Why / evidence |
|---|---|---|
| D-1 | New SwiftPM library target `OpenSiteControl` in `Packages/OpenKit`. It holds the Site Control Center view and controller, the Boost editor views and session, and the code editor. It depends on `OpenModel`, `OpenDesign`, `OpenBoosts`, `OpenAdBlock` (only for `AdBlockSites` registrable domains), `OpenWeb`, and — once it lands — `OpenExtensionsUI` (§3.6) only. The Library Boosts list is a SwiftUI section in `OpenSettings` (§4.13). It never imports `OpenEngine` or CEF. | `docs/architecture.md`: packages never import the engine. |
| D-2 | `OpenSiteControl` uses AppKit views only. No SwiftUI. Layer-backed, drawn with `OpenDesign` tokens. | The panel opens on a click on the hot path and must hit < 8 ms. |
| D-3 | **Kept, amended 2026-10-26.** The Site Control Center is an in-window overlay view (like the command bar overlay), not an `NSPopover` and not a separate window. It draws a top arrow, a translucent blurred material, and covers the sidebar and the page (§3.2). | Arc's panel is its own popover window (`windows.tsv` S2 09/0009: 262 x 323). Every captured property can be drawn in-window: the arrow, the blur over the sidebar and the page, and the browser window keeping its active look while the panel is open (sidebar pixel #252538 unchanged, IS §20.15). An in-window view keeps the window key and avoids Liquid Glass (`AGENTS.md`). Accepted difference: Arc's popover may extend past the window edge; Open clamps inside the window and scrolls (§3.1). Risk R-7 covers the blur over engine content. |
| D-4 | **Kept, amended 2026-10-26.** The Boost editor is a child `NSPanel` of the browser window: `.borderless`, `.nonactivatingPanel`, `becomesKeyOnlyIfNeeded = true`, always light (`NSAppearance(named: .aqua)`), system shadow, 12 pt corners. It becomes key only for text input (rename field, code editors). Placement in §4.2. | Arc's editor is its own window (AX id `boostsEditor`, subrole `AXSystemDialog`, layer 3, 183 x 588) and is light in macOS Dark (S2 10/0018). It is not key while simple controls are used and becomes key after a click into the code view (AX `focused,main` from S2 10/0079). Corner ≈ 12 (IS §20.15). |
| D-5 | Data owners do not change. Permissions: `WebProfile.permission(_:origin:)` / `setPermission(_:for:origin:)` (OpenWeb). Ad blocking: `AdBlockStore.setExcluded(_:excluded:profile:)` and `siteSnapshot(for:)`. Boosts: `BoostStore`. Global Boosts switch: `UserDefaults` `open.advanced.enableBoosts` (settings plan §2.1 A-5). The panel and the editor never write files themselves. | `docs/plans/settings-library.md` D-5: no second store for one value. |
| D-6 | Live preview goes through the App's `BoostEngineAdapter` (`docs/plans/app-shell.md` §4.5): store mutation → matcher rebuild → `BoostInjectionPlanner.plan` → `boost:apply` to each live page whose URL matches. During a drag, only the editor's own page gets frames (≤ 60 Hz); the store and other pages get the value on drag end. | BO-8, BO-13, BO-14, BO-15. |
| D-7 | **Amended 2026-10-26.** The pad maps a screen point to `BoostColorWheel` inputs (§4.4.2); the runtime math (`BoostColorWheel.adjustment`, CSS filters) does not change. `colorAdjustment` stays the runtime value and is derived from `colorWheel` when `colorWheel` is set. | Q4 (filters only). One derivation function, one writer (§5.2). |
| D-8 | **Amended 2026-10-26.** Zap keeps the existing in-page picker (`zap-picker.js`, closed shadow overlay). Its bar and popup take Arc's look (§4.8). The list of Zaps lives in the page bar ("Click to reveal"); the editor shows only the count on the Zap button. | Arc: bar, popup, and count measured (S2 10/0058, 0060, 0067; IS §20.6). Supersedes Q10. |
| D-9 | Code editors are `NSTextView` with a small regex highlighter and an `NSRulerView` gutter. No dependency. | Arc's code body is an internal web page that was disabled on the capture machine (S2 10/0071), so its look is not known; the native path keeps memory and cold start low. |
| D-10 | Boost editing and creation are disabled in incognito windows. Existing Boosts still apply there. | BO-10; lead Q6. |
| D-11 | **Superseded 2026-10-26.** The panel has no header. Order: action row, Extensions, Boosts, Settings, footer. Rows replace tiles (§3.3). | S2 09/0010, 11/0005 (C2). |
| D-12 | **New 2026-10-26.** The Boost color pad and the Space theme editor's pad share one AppKit core, `OpenDesign/ColorPad.swift` (plate, dot grid, knobs, drag and keyboard handling). Each owner supplies its geometry and color law. | Both pads are square dot-grid plates whose knob hue equals the screen angle, clockwise from 3 o'clock (theme: `space-theme-editor.md` §2.2; Boost: IS §20.15). One implementation, two styles. |

## 1. Current state (verified 2026-10-26 on `origin/main` b4b8817; re-verify before you edit)

| Area | State | Evidence |
|---|---|---|
| URL field button | Exists, sends `.showSiteControls`. Frame `[W − 42, 49, 30, 30]` in sidebar space, glyph `slider.horizontal.2.square` 18 pt, tooltip "Site Controls". Shown only while a page is loaded and the pointer is over the sidebar. No open or Boost state. | `OpenSidebar/ChromeViews.swift` `URLFieldView`; `OpenDesign/Metrics.swift` `URLFieldMetrics` (field `[8, 46, W − 16, 36]`). |
| Pane bar button | Exists in `PaneChromeView` (button index 4, "Site Control Center", frame `[w − 105, 2, 32, 28]`) and is always disabled. | `OpenFeatures/PaneChromeView.swift`. |
| Intents | `.showSiteControls` and `.customizePage(tabID:)` exist in `SidebarIntent`; no handler yet. | `OpenSidebar/SidebarIntent.swift`; `OpenFeatures/BrowserWindowController.swift`. |
| Commands | `new-boost`, `edit-boost`, `new-legacy-boost`, `boost-gallery` (File), `view-boosts` (Window) exist with no handler. "Customize Page…" exists in the pinned-tab menu. | `OpenCommands/CommandRegistry.swift`. |
| OpenBoosts | `Boost`, `SiteMatch`, `ColorAdjustment`, `ZappedElement`, `BoostStore`, `BoostMatcher`, `BoostInjectionPlanner`, `BoostPickerCoordinator`. No `colorWheel` on main (PR #103 adds it). | `Packages/OpenKit/Sources/OpenBoosts/*.swift`. |
| Zap picker | In-page bar "Zap mode · Zap all related (N) · Undo · Done", Esc exits, Cmd/Ctrl+Z undoes. | `OpenBoosts/Resources/zap-picker.js`. |
| OpenSiteControl | Not on main. Open PRs: #69 (Step 1 shell), #96 (Step 2 sections), #103 (Step 4 editor), stacked with merge commits (#96 contains #69; #103 contains both). They implement the 2026-10-25 version of this plan and must change (§12). | `gh pr view 69 / 96 / 103`. |
| Space theme pad | Not on main. PR #86 adds `OpenSpaceEditor/ColorPadView.swift` (square plate, dot grid, knobs, relative/jump drag, arrow keys). | `origin/t3/space-editor-shell`. |
| OpenAdBlock, OpenWeb, Engine, Settings | Unchanged from the first version of this plan: `AdBlockStore` exclusions, `WebProfile` 12 permission kinds, `clearBrowsingData(origin:)`, `showDevTools()`, `takeSnapshot()`, `SettingsDefaults.values` with `open.advanced.enableBoosts`. | Source files named in `docs/engine-api.md` and `docs/plans/settings-library.md`. |

---

## 2. Arc facts this plan builds on

Decoded facts (first version; evidence in `docs/re/features-advanced.md`):

| ID | Fact | Used in |
|---|---|---|
| SC-9 | The panel is an `NSPopover` hosting SwiftUI; its controller tracks an Option-key state and an extension-picker key monitor. | D-3, §3.12 |
| SC-10 | Section titles "Settings", "Boosts", "Extensions"; on hover each header shows an accessory text: "More" (Settings), "Manage" (Boosts, Extensions); clicking the header runs that action. | §3.5 |
| SC-11 | Setting rows: `contentSettings(type)`, `sidebarPreview`, `developerMode`, `contentBlocking`, `popupBlocking`; titles "Block Ads & Trackers", "Preview", "Developer Mode", "Block Pop-ups"; subtitles "Allowed"/"Blocked", "On"/"Off", "Enabled"/"Disabled". Ad-block tooltips for on, excluded, and master-off. | §3.8 |
| SC-12 | Arc reads the site's changed content settings (`getChangedContentSettingsForOrigin:`); display names come from one table. | §3.8, E1 |
| SC-13 | Boost rows: subtitle "Enabled"/"Disabled". | §3.7 |
| SC-14 | Extensions: buttons with click, right-click, a pin button ("Pin"/"Unpin"); an "Add Extension" item. | §3.6, E4 |
| SC-15 | Action enum order: Share, Copy URL, New Boost, Capture ("Capture a portion of this page"), Capture Full Page ("Capture the full page"), Capture in Portrait Mode. | §3.4 |
| SC-16 | Footer: a security button "Secure" / "Insecure", and a menu: Clear Cache · Clear Cookies · — · Manage Boosts… · New Boost… · — · Manage Extensions… · Add Extension… · — · All Site Settings…. | §3.9 |
| BO-14 | Editor window with modalities (`none`, `code`), a remembered code-editing window size, an interstitial, an overlay, and a shelf. | D-4, §4 |
| BO-15 | Editor actions include `undo`, `redo`, `shuffle`, `resetAll`, `resetColorMapping`, `rename`, `delete`, `showSelectorPicker`, `copySelectorToPasteboard`, `toggleDevTools`, `reloadPage`, `editCSS`, `editJS`. | §4.9 |
| BO-16 | Strings "Rename this Boost…", "Shuffle", "Delete this Boost", "Reset all Edits", "All Boosts…", "Delete this Boost?", "Delete"; default name "My Boost". | §4.9 |
| BO-17 | "Invert lightness", "Advanced color controls" with "Brightness", "Contrast", "Original Saturation", "Reset to original colors"; assets `HueRing`, `DotGrid` 8 pt, `AnalogousColorScheme`, `ComplementaryColorScheme`. | §4.4, §4.5 |
| BO-18 | "Change text size" (small, normal, medium, large, larger), "Change text case" (capitalize, uppercase, lowercase); font kinds `custom`, `system`; 18 macOS family names in binary order Helvetica Neue … Wingdings; "Arial Rounded MT Bold" near the editor strings. | §4.6, §4.7 |
| BO-19 | Code mode strings "Pick Selector" / "Hide Selector Picker", "Refresh to Run" ("Refresh this Page"), "Show Developer Tools" / "Hide Developer Tools", placeholders "your css here" / "your javascript here". | §4.10 |
| BO-20 | Zap strings "Click elements on the page to Zap them", "Zap this", "Zap all related elements", "Copy selector for this", "Copy selector for related". | §4.8 |
| BO-21 | First-run interstitial "Edit the Internet with Boosts"; dismissal stored (`hasDismissedBoostsInterstitial`). | §4.11 |

Measured facts (capture session 2; `interaction-states.md` §20.5, §20.6, §20.15; abbreviated "IS"):

| ID | Fact | Evidence | Used in |
|---|---|---|---|
| S2-1 | The panel drops down from the URL field with a **top arrow** centered on the Site Control button: arrow tip at the field's bottom edge (y 82), body top 9 pt lower (y 91), body 236 pt wide (x 83 … 318 at sidebar width 228), over the sidebar and the page. | S2 09/0010; IS §20.5, §20.15 | §3.1, §3.2 |
| S2-2 | No header. Order: action row, Extensions, Boosts (only with a matching Boost), Settings, footer. | S2 09/0010, 11/0011 | §3.3 |
| S2-3 | 4 action buttons 48 × 32, gap 8: Share, New Boost, Capture (camera), Capture area (viewfinder). No Copy URL. | S2 09/0010 | §3.4 |
| S2-4 | Body is translucent and blurred: #403E54 over the dark sidebar, #7B7B7B over white. | S2 09/0010; IS §20.15 | §3.2 |
| S2-5 | Rows: 32 pt icon circle, title, subtitle, pitch 43. On / allowed / enabled = light circle #ECEDFF with a dark glyph; off = translucent #84849A with a white glyph. Titles truncate with "…". | S2 09/0010, 11/0005 | §3.7, §3.8 |
| S2-6 | Extensions section shows with no extensions installed: one "+" tile 48 × 32. | S2 09/0010 | §3.6 |
| S2-7 | Footer: "Secure" pill (≈ 82 × 32) and a 32 pt round ⋯ (#595B5F). | S2 09/0010 | §3.9 |
| S2-8 | Section header hover shows "Manage" at the right; Boost row hover shows a chevron. | notes 10:47:57 | §3.5, §3.7 |
| S2-9 | ⋯ menu shows "New Boost…" and "Manage Boosts…" even while a Boosts section is shown. | S2 11/0011 | §3.9 |
| S2-10 | The Site Control button draws a filled variant while the panel is open, and small sparkles while the site has a Boost. ⌥-click on the button does not open the panel. | S2 11/0011, 0016; notes 10:28:02 | §3.10 |
| S2-11 | The panel grows from the button (popover window 38 × 47 at the button center during the open) and overshoots ≈ 1.5 % (266 × 405 before 262 × 398). | `windows.tsv` S2 09/0008, 11/0003 | §3.11 |
| S2-12 | Editor: own light window 183 × 588, centered on the browser window's right edge, 160 pt below its top (one sample). Header: Done (x circle), name button with chevron, Undo. | S2 10/0018, 0030; IS §20.6, §20.15 | §4.2, §4.3 |
| S2-13 | Color pad: square dot-grid plate 133 pt inside a 7 pt hue ring (frame 147); two knobs; the second knob sits 45° clockwise of the first on the same radius; knob hue = screen angle clockwise from 3 o'clock; grey ring before a color, rainbow after. | S2 10/0030, 0038–0041; IS §20.15 | §4.4 |
| S2-14 | Three 42 × 38 color buttons: Invert lightness (bulb), Advanced color controls (sliders), Reset to original colors (prohibited sign, disabled until a change). | S2 10/0030, 0039 | §4.5 |
| S2-15 | Advanced color controls is a light popover 250 × 232: Contrast, Brightness, Original Saturation, sliders 186 × 16 at value 50. | S2 10/0042 | §4.5 |
| S2-16 | Fonts: 5 × 4 grid of 26 pt "Aa" cells in a white card; selected cell = 26 pt grey circle. | S2 10/0030, 0046 | §4.6 |
| S2-17 | "Size" and "Case" half-width buttons (70 × 38); "Zap" and "Code" full-width rows (147 × 38). Zap on = #333333 with white text; count after a Zap ("Zap, 1"). | S2 10/0030, 0058, 0067 | §4.7 |
| S2-18 | Name menu: Rename this Boost… · Shuffle · Reset all Edits · Delete this Boost · — · All Boosts…. Delete alert "Delete this Boost?" / "This can't be undone." with Cancel (Esc) and a red Delete (Return). | notes 10:48:09, 10:48:18 | §4.3, §4.9 |
| S2-19 | Zap mode on the page: 3 pt blue content frame, 56 pt white bottom bar with the instruction and "Done", yellow hover tint, a popup with "Zap this", "Zap all related elements", "Cancel" and the selector; afterwards "Click to reveal". | S2 10/0060; notes 10:26:49 | §4.8 |
| S2-20 | Code mode widens the window to 480 × 588 to the left: "← Back", CSS · JS, a code view, a 70 pt bottom bar with "Pick Selector" and "Show Developer Tools". | S2 10/0071 | §4.10 |
| S2-21 | First-run card covers the lower part and dims the rest; "Edit the Internet with Boosts", "Make <host> your own!", "Make a Boost", "Maybe Later"; lavender footer with a wavy edge. | S2 10/0018 | §4.11 |
| S2-22 | One color on archive.org turned white areas pale toward the first knob's hue (#FFFFFF → #E4E2F3) and dark areas toward the second knob's hue (#222222 → #56285D); images kept their colors. | S2 10/0018 vs 0039 | §4.4.4, Q12 |

---

## 3. Site Control Center — design spec

All frames are points at 1x. Panel frames have their origin at the body's top-left (y down).
"S2 …" cites a measured value; "guess" and "Open choice" mark the rest. Put every number in
`OpenDesign/SiteControlTokens.swift` (Appendix A), never inline. Values were measured in macOS Dark;
macOS Light values are guesses (§13).

### 3.1 Entry points and anchoring

| Entry | Anchor | Rule |
|---|---|---|
| Sidebar URL field button (`.showSiteControls`) | Button frame `[W − 42, 49, 30, 30]` (sidebar space) | Arrow tip at `(button.midX, URLFieldMetrics.y + URLFieldMetrics.height)` = y 82. Body top = tip + 9 (y 91). Body x = `button.midX − 118` (S2 09/0010: 83 at W = 228). |
| Floating sidebar card (hover-reveal) | The card's URL field button | Same rule, relative to the card (guess: not captured). |
| Split pane bar button (`PaneChromeView` index 4, enable it) | Button frame in the pane bar | Arrow tip at the button's bottom edge + 2, centered on the button (guess: not captured). |
| Key binding with no visible anchor (`.contentTopLeading`) | Web content top-left | No arrow; body at 12 pt from the content's top-left (Open choice, unchanged). |

- Horizontal clamp (Open choice): keep the body ≥ 8 pt inside the window. When clamped, the arrow
  stays on `button.midX` but at least `cornerRadius + arrowBase / 2` from the body's left and right
  edges.
- Height: the body grows with its content up to `windowContentMaxY − 8 − bodyTop`; past that the
  sections scroll inside the body (overlay scroller; Open choice). Arc's popover window could
  extend past the window instead (accepted difference, D-3).
- The panel describes the tab of its anchor: the selected tab, or the focused split pane (SV-8).
- Not available: no page loaded (button hidden), a Peek, Little Open. Internal pages (`chrome://`,
  `open://`) show the action row (Share only enabled), the Extensions section, and the footer
  without a security label (Open choice; not captured).
- One panel per window. Opening it again on the same anchor closes it (toggle). Opening from
  another anchor moves it.

### 3.2 Panel chrome: shape, arrow, material

| Part | Value | Source |
|---|---|---|
| Body width | 236 | S2 09/0010 |
| Body corner radius | 16, continuous (`SiteControlShape`) | measured ≈ 16–18 (S2 09/0010); lead decision C kept |
| Arrow | Points up. Height 9, base 28, centered on the anchor x, rounded tip radius 3. One path with the body: fill, material mask, and shadow use the same `CGPath`. | S2 09/0010 (height, base, center); tip radius guess (≈ 10 px wide first row) |
| Material | `NSVisualEffectView`, material `.popover`, blending `.withinWindow`, state `.active`, appearance follows macOS (darkAqua in Dark), masked by the body + arrow path. Calibrate on the real app to the S2 probes: over the default dark sidebar #252538 → #403E54 ± 3 levels; over a white page → #7B7B7B ± 3 levels. If `.popover` misses, try `.hudWindow`, then a flat tint layer over the effect view; record the choice in `SiteControlTokens.swift`. | S2 09/0010; material choice is a guess |
| Offscreen fallback (harness only) | WindowServer blur is not available offscreen. `sitecontrol-render` draws `0.28 × blur(backdrop, σ 15) + 0.72 × #49475A` (blue channel 0.21 / 0.79). | fit, IS §20.15 |
| Edge | None visible at 1x. No stroke (guess: a 2x capture may show a hairline). | S2 09/0010 |
| Shadow | Not measurable (the composite window image has no popover shadow). Black 0.25, radius 12, y 4 (guess, close to a system popover). | guess |
| Appearance | Follows macOS (`NSApp.effectiveAppearance`). Dark measured; Light values are guesses. | Open choice |

### 3.3 Vertical layout

Body padding 10 on every side (S2 09/0010). Blocks from the top (S2 09/0010 without a Boost, total
297; S2 11/0005 with one Boost, total 372):

| y (body) | Block | Height | Source |
|---|---|---|---|
| 0 | top padding | 10 | S2 09/0010 |
| 10 | action row (§3.4) | 32 | S2 09/0010 |
| 42 | gap holding the "Extensions" label | 37 | S2 09/0010 |
| 79 | Extensions items (§3.6) | 32 per tile row | S2 09/0010 |
| … | gap holding the next section label | 43 | S2 09/0010, 11/0005 |
| … | section rows (§3.7, §3.8): row pitch 43 (32 circle + 11) | 32 + 43 · (n − 1) | S2 09/0010, 11/0005 |
| … | reload row (§3.8.1), when shown | 11 + 32 | Open choice |
| … | gap | 15 | S2 09/0010 |
| … | separator | 1 | S2 09/0010 |
| … | gap | 10 | S2 09/0010 |
| … | footer (§3.9) | 32 | S2 09/0010 |
| … | bottom padding | 10 | S2 09/0010 |

Section label: baseline 14 pt above the section's first item (S2 09/0010). A section with no items
is removed with its gap. Order: Extensions, Boosts, Settings (D-11 superseded; S2-2).

### 3.4 Action row

Four buttons, 48 × 32, gap 8, from x 10 (x 10, 66, 122, 178) (S2 09/0010). Corner radius 7 (visual,
guess). Fill #232323 (measured #212121–#262626), 1 pt top inner highlight #575757; hover: the
highlight drops to #484848 and nothing else changes (S2 09/0016, 0018, 0019, 0021); pressed: fill #1A1A1A
(guess). Glyph 17 pt Regular template, white 0.85 (visual guess). Disabled: glyph alpha × 0.3,
no hover. Tooltips were not captured: use the labels below with the shortcut keycaps (shared capsule
in `OpenDesign/TooltipView.swift`).

| # | Tooltip and AX label | Glyph (Open's own SF choice) | Runs | Enabled when |
|---|---|---|---|---|
| 1 | Share | `square.and.arrow.up` | `share-page` (system share picker anchored to the button) | page loaded |
| 2 | New Boost | `wand.and.sparkles` | §3.7 New Boost flow | http(s) page, not incognito, `open.advanced.enableBoosts` |
| 3 | Capture a portion of this page (⇧⌘2) | `camera` | `capture-page` | command enabled |
| 4 | Capture the full page | `doc.text.viewfinder` | `capture-full-page` | command enabled |

The mapping of the camera and viewfinder glyphs to the two SC-15 capture actions is a guess (no
tooltip was captured). Copy URL and Capture in Portrait Mode are not in the row (S2-3); Copy URL
stays on ⇧⌘C and on the URL field's copy button. A button action closes the panel first, then runs
the command (Open choice).

### 3.5 Section labels and header actions

| Part | Value | Source |
|---|---|---|
| Label | x 10, 13 pt Semibold, white 0.86 (#DBDBDF) | S2 09/0010 (size visual) |
| Hover | The whole label row (full width, 24 pt tall) shows the accessory text right-aligned at x `236 − 10`: 12 pt Medium, white 0.6 (guess). Fade `Motion.hoverFade`. Click anywhere on the label row runs the header action. | text "Manage" measured (notes 10:47:57); style guess |

| Section | Title | Hover accessory | Header action |
|---|---|---|---|
| Extensions | "Extensions" | "Manage" | `manage-extensions` |
| Boosts | "Boosts" | "Manage" | `view-boosts` → Library Boosts list (§4.13) |
| Settings | "Settings" | "More" (SC-10; not re-observed) | All Site Settings (§3.9 menu item 10) |

### 3.6 Extensions section

Always shown on http(s) and internal pages (S2-6). Items are tiles 48 × 32 in rows of 4, gap 8,
from x 10 (tile size S2 09/0010; 4 columns and gap guess, matching the action row). Tile fill white
0.08, corner 7 (guess; the measured tile sat over a blurred favicon). The last tile is always "+"
(`plus` 14 pt, white 0.85): AX label and tooltip "Add Extension", runs `add-extension`.

Body ownership is unchanged: `docs/plans/extensions-ui.md` owns `ExtensionsSectionBody` and
`ExtensionItemView` (style `.tile`, which must use the metrics above), item data, pin order, and the
item intents `.run(id, anchor)`, `.togglePin(id)`, `.contextMenu(id, anchor)`. This plan owns the
label, the section's place, the "+" tile until `OpenExtensionsUI` lands, and the footer menu.

| Part | Value |
|---|---|
| Before `OpenExtensionsUI` | The section shows only the "+" tile (supersedes "section hidden"; S2-6). |
| Click | `.run(id, anchor)` → App runs the action; the popup opens at the item's screen rect. The panel closes first. |
| Pin | `.togglePin(id)` (E4). Hidden until E4 lands. |
| Right-click | `.contextMenu(id, anchor)` → Chromium's extension context menu. Before E4: "Manage Extensions…" only. |

#### 3.6.1 Extension picker mode

- API (unchanged): `SiteControlController.present(anchor:tabID:mode:)`,
  `enum SiteControlPresentationMode { case standard, extensionPicker }`,
  `enum SiteControlAnchor { case urlField, paneBar(ItemID), contentTopLeading }`.
- `.extensionPicker`: the panel opens, then keyboard focus goes to the first extension item; arrows
  move; Return runs it; Esc closes. With no extensions the first item is the "+" tile, so Return runs
  `add-extension` (supersedes the "focus ⋯" fallback; guess on Arc's behavior).
- The key binding and its command id belong to the extensions-UI plan (Q11).

### 3.7 Boosts section

Shown when at least one Boost of the tab's Profile matches the page (`BoostMatcher.matching(url:)`
over all Boosts, enabled or not; build a second matcher from `allBoosts()` with `isEnabled` forced
true, cached per store change). Hidden otherwise.

Row (one per matching Boost, matcher order) — the shared `SiteControlRow` (§3.8 geometry):

| Part | Value | Source |
|---|---|---|
| Circle | 32 pt at x 10. Enabled: #ECEDFF with Open's Boost glyph (`wand.and.sparkles` 15 pt, #2B2A3C); disabled: white 0.28 (#84849A over the dark material) with a white glyph. | S2 11/0005 (enabled); disabled guess, from the settings "Off" circle |
| Title | Boost name (or the site domain when empty), x 50, 13 pt Semibold, #DFDFE2, one line, tail "…" | S2 11/0005 |
| Subtitle | "Enabled" / "Disabled", 12 pt Regular, #9F9EA9 | S2 11/0005 (SC-13) |
| Hover | Row plate white 0.06, corner 8; `chevron.right` 11 pt Semibold, white 0.6, at x `236 − 10 − 11` | chevron measured (notes 10:47:57); style guess |
| Sparkle animation | Arc animates the glyph's sparkles while the panel is open. Open draws them static (idle CPU near zero, Q15). | IS §20.15; Open choice |
| Global off | `open.advanced.enableBoosts` false: rows draw at 50 % alpha, circles do nothing, and a 28 pt note above the rows: "Boosts are off. Turn them on in Settings." | Open choice |
| Incognito | Circle and row actions disabled; tooltip "Boosts can't be edited in a private window." | D-10 |

Actions (guesses on Arc's click targets; Open choice):

- Click on the circle → `BoostStore.setEnabled(id:enabled:)` → adapter refresh (D-6). Subtitle and
  circle update at once; CSS components re-render without reload; JS stays until reload.
- Click elsewhere on the row, the chevron, or Return on a focused row → close the panel, open the
  editor on this Boost (§4).
- New Boost (action button 2 or ⋯ "New Boost…") → create
  `Boost(name: "My Boost", siteMatch: SiteMatch(domain: defaultDomain(host)))` (host without a
  leading `www.`); `BoostStore.upsert`; close the panel; open the editor with `isNew = true`.

### 3.8 Settings section

Rows, in this order, with the `SiteControlRow` geometry: height 32, pitch 43; circle 32 at x 10;
title x 50, cap top +2, baseline +13, 13 pt Semibold #DFDFE2; subtitle baseline +29, 12 pt Regular #9F9EA9;
text ends at x `236 − 10`, one line, tail "…" (S2 09/0010; font sizes visual). The two-line
title rule of the first version is superseded.

| # | Row | Shown when | Title | Subtitle | Circle on when | Click writes |
|---|---|---|---|---|---|---|
| 1 | Content blocking | http(s) page | "Block Ads & Trackers" | "On" / "Off" | on | `AdBlockStore.setExcluded(host, excluded: wasOn, profile:)`. Master switch off → state `unavailable`: circle off, click runs `openAdBlockSettings(tabID:)`, writes nothing (Q13). |
| 2… | One per changed content setting | E1: every changed setting; before E1: each of the 12 `SitePermission` kinds whose state is not `.ask` | Display name (table) | "Allowed" / "Blocked" | allowed | Toggle allow ↔ block through `WebProfile.setPermission(_:for:origin:)` (E1: `setSiteSetting`) |
| — | Developer Mode | Hidden in v1 (Q2) | "Developer Mode" | "On"/"Off" | — | — |
| — | Preview | Hidden in v1 (Q3) | "Preview" | "Enabled"/"Disabled" | — | — |

- Circle: on = #ECEDFF with the glyph in #2B2A3C; off = white 0.28 with a white glyph (S2 09/0010).
  Glyph 15 pt (visual). Hover plate white 0.06 (guess). Click anywhere on the row toggles (guess).
- In use (camera or microphone capturing): a 6 pt `Core.brandBlue` dot after the title (Open choice;
  recording states not captured, §13).
- Ad-block tooltips (Open's words): on — "The built-in ad blocker is on for this site."; excluded —
  "The built-in ad blocker is off for this site."; master off — "The built-in ad blocker is off.
  You can turn it on in Settings."
- Display names and glyphs (Open's own SF choices; titles from SC-12). Any kind without its own
  glyph uses `gearshape.fill` (Arc showed a gear for "Automatic Picture-In-Picture", S2 09/0010).

| `SitePermission` / E1 kind | Title | Glyph |
|---|---|---|
| camera | Camera | `video.fill` |
| microphone | Microphone | `mic.fill` |
| geolocation | Location | `location.fill` |
| notifications | Notifications | `bell.fill` |
| clipboard | Clipboard | `doc.on.clipboard.fill` |
| midi | MIDI Devices | `pianokeys` |
| screenCapture | Screen Sharing | `rectangle.on.rectangle` |
| automaticDownloads | Automatic Downloads | `arrow.down.circle.fill` |
| storageAccess | Storage Access | `externaldrive.fill` |
| windowManagement | Window Management | `macwindow.on.rectangle` |
| localFonts | Fonts | `textformat` |
| idleDetection | Idle Detection | `moon.zzz.fill` |
| E1 only: javascript, images, popups, sound, ads, backgroundSync, sensors, usb, hid, serial, bluetooth, localNetwork, protocolHandlers | JavaScript, Images, Pop-ups and Redirects, Sound, Intrusive Ads, Background Sync, Motion Sensors, USB Devices, HID Devices, Serial Ports, Bluetooth, Local Network, Protocol Handlers | `curlybraces`, `photo.fill`, `macwindow.badge.plus`, `speaker.wave.2.fill`, `rectangle.badge.xmark`, `arrow.triangle.2.circlepath`, `gyroscope`, `cable.connector`, `keyboard`, `cable.connector.horizontal`, `antenna.radiowaves.left.and.right`, `network`, `link.badge.plus` |

#### 3.8.1 Reload row (Open-only)

After any row change, a 32 pt row appears 11 pt under the last Settings row (height animation
`Motion.rowStructure`): "Reload to apply changes." 12 pt Regular #9F9EA9 at x 10, baseline row top +
20 (lead round 2), and a "Reload" text button 12 pt Semibold white at the right. Click reloads the
tab and closes the panel. The panel never reloads on its own (Q7).

### 3.9 Footer and ⋯ menu

| Part | Value | Source |
|---|---|---|
| Security pill | x 10, height 32, corner 8 (visual), fill white 0.05, padding 10. `lock.fill` 12 pt + "Secure" 13 pt Medium #DBDBDF; width fits the content (≈ 82). Insecure: `lock.open.fill` + "Insecure" in `CommandBarColors.lockInsecure` (guess: not captured). `https` → Secure, `http` → Insecure, any other scheme hides the pill and its AX element (lead decision). Click: E3 → certificate viewer; before E3 a static label. | S2 09/0010 |
| ⋯ button | 32 pt circle at x 194, fill black 0.28 over the material (#595B5F measured), `ellipsis` 13 pt Bold white. Opens a native `NSMenu` at the click point (top-left at the pointer; keyboard activation: under the button). | S2 09/0010, 11/0011 |

⋯ menu (S2 11/0011 order and titles):

| # | Item | Shown / enabled | Action |
|---|---|---|---|
| 1 | Clear Cache | http(s); hidden before E2 | `clearSiteData(origin:kinds:[.cache])`, then the reload row |
| 2 | Clear Cookies | http(s) | E2 → `[.cookies]`; before E2 → `clearBrowsingData(origin:)` (side effect stated in the PR); then the reload row |
| 3 | — | | |
| 4 | Manage Boosts… | always | `view-boosts` |
| 5 | New Boost… | always shown (S2-9); enabled when New Boost is | §3.7 New Boost |
| 6 | — | | |
| 7 | Manage Extensions… | always | `manage-extensions` |
| 8 | Add Extension… | always | `add-extension` |
| 9 | — | | |
| 10 | All Site Settings… | http(s) | `chrome://settings/content/siteDetails?site=<origin>` in a new Today tab |

### 3.10 URL field button states (new work, Step 3)

| State | Look | Source |
|---|---|---|
| Rest | Today's outline glyph `slider.horizontal.2.square`. | main |
| Panel open | Filled variant: white rounded square, dark sliders (`slider.horizontal.2.square.fill` tinted, or our own drawing). Shown while the panel is open even when the pointer leaves the sidebar. | S2 11/0011 |
| Site has an enabled matching Boost | Three small 4-point sparkles at the glyph's top-left, top-right, and bottom-right corners, white 0.8, ≈ 4 pt (our own drawing). | S2 11/0016 (meaning guess) |
| ⌥-click | Does not open the panel (S2-10). Open: no other effect (the small dot Arc showed afterwards is unexplained, §13). | notes 10:28:02 |

### 3.11 States and motion

| State | Visual | Source |
|---|---|---|
| Open | Body + arrow scale from 0.15 to 1 around the arrow tip, spring response 0.20 s, damping 0.8 (≈ 1.5 % overshoot); opacity 0 → 1 over the first 0.08 s. Token `Motion.popoverOpen` becomes a `SpringToken`. | S2 09/0008, 11/0003 (origin, overshoot); theme popover ≈ 0.20 s (IS §20.12); curve guess |
| Close | Scale 1 → 0.9 around the arrow tip and opacity 1 → 0, 0.19 s ease-in (`Motion.popoverClose`). | theme popover ≈ 0.19 s (IS §20.12); SCC close not timed |
| Reduce Motion | Opacity only, same durations. | Open choice |
| Row toggle | Circle fill and glyph color cross-fade 0.12 s (`Motion.selectionFade`); subtitle swaps at once. | guess |
| Hover | Fills fade 0.08 s (`Motion.hoverFade`). | guess |
| Rows added or removed while open | Height animates 0.22 s (`Motion.rowStructure`); the arrow stays fixed. | guess |
| Live data | Token-based observer per window (lead round 1); updates in place. No timers. | lead decision |

### 3.12 Keyboard

| Key | Effect |
|---|---|
| Esc | Close; focus returns to the saved first responder. |
| Tab / Shift+Tab | Action buttons → Extensions label → extension items → Boosts label → Boost rows (circle, then row) → Settings label → Settings rows → security pill → ⋯. Focus ring 2 pt `Core.focusRing`, keyboard focus only (lead round 2). |
| Arrow keys | Move inside the action row and the extension grid, and between rows. |
| Space / Return | Activate the focused control (Return on a Boost row = edit). Command-modified Return/Space do nothing (lead round 2). |
| Option held | No change inside the panel (Q8). |
| Any Command shortcut | Closes the panel, then routes normally through `KeyboardRouter`. |

Clicks outside close the panel and are delivered to their target (left, right, and other buttons;
lead round 2). The click that toggles the anchor button closes the panel and is consumed.

### 3.13 Accessibility

- Container: role `.popover`, label "Site Control Center", description = host (the host is exposed
  once; there is no visible host text).
- Section label row: `.button` "Extensions, Manage" etc., with a heading child.
- Row: `.checkBox` with label "<Title>" and value description "<Subtitle>"; the unavailable ad-block
  row is `.button` with help = the tooltip. Boost row: the circle is `.checkBox` "Enable <Name>", the
  row is `.button` "Edit <Name>".
- Action buttons: label = tooltip text without keycaps. "+": "Add Extension".
- Security: `.button` "Connection: Secure" (static text before E3); ⋯ `.menuButton` "More".

---

## 4. Boost editor — design spec

Frames are editor-window points (origin top-left, y down), measured from the AX tree of S2 10/0030
unless another frame is cited. The editor is always light; there are no dark tokens.

### 4.1 Lifecycle

| Event | Behavior |
|---|---|
| Open | From the Site Control Center (row, New Boost), `new-boost`, `edit-boost`, `new-legacy-boost`, and "Customize Page…". One editor per window. Opening for another Boost finalizes the current one first. |
| `new-boost` | Creates a new Boost (§3.7) and opens the editor in simple mode. |
| `edit-boost` / "Customize Page…" | Opens the first matching Boost in matcher order; if none, behaves as `new-boost`. |
| `new-legacy-boost` | As `new-boost`, then code mode on the CSS tab (Open choice). |
| `boost-gallery` | `isCommandEnabled` returns `false`. |
| Bound tab | The editor is bound to the tab (and pane) it opened for. Switching tab, Space, or window to another tab closes it (Open choice). Navigating the bound tab to a URL the Boost does not match keeps it open with the "Not active" banner (§4.3). |
| Close | Done (header), Esc (§4.12), the bound tab closes, or the profile closes. Close exits Zap, flushes pending state with `BoostStore.saveNow` (lead round 2), and deletes the Boost if it was created in this session and is still empty. |
| Incognito | The four open commands are disabled (D-10). |
| Global off | The commands stay enabled; the "Boosts are off" banner shows and live preview is skipped. |

### 4.2 Window and placement

| Part | Value | Source |
|---|---|---|
| Window | Child `NSPanel` (D-4), 183 × 588 in simple mode, corner radius 12, `hasShadow = true` (system shadow), opaque light content, level `.floating` relative to the parent. No padding layer of our own (supersedes the 30 / 24 / 36 shadow padding). | S2 10/0018 (size), IS §20.15 (corner) |
| Appearance | `NSAppearance(named: .aqua)` always. | S2 10/0018 (light in macOS Dark) |
| Placement | Window center x = browser window frame `maxX` (the editor straddles the right edge: 91 pt inside, 92 pt outside); top = browser window top + 160. Clamp to the screen's `visibleFrame` with 8 pt margins (then it moves inside the browser window). | S2 10/0018 `windows.tsv` (one sample; rule guess); clamp Open choice |
| Banners | An Open-only banner (§4.3) adds its height under the header and grows the window downward; everything below moves by that height. | Open choice |
| Code mode | Width 480, height 588, right edge fixed (grows to the left). Resizable from the left and bottom edges (8 pt hit strips); size persists on resize end in `open.boosts.codeEditorSize` (default `"480x588"`, min 360 × 420). | S2 10/0071 (480 × 588, right edge fixed); resizing Open choice (BO-14 `codeEditingWindowSize`) |
| Moving | The browser window drags the child panel with it. Dragging the header moves the panel (not persisted). | Open choice |

### 4.3 Header, name menu, banners

| Part | Frame | Value | Source |
|---|---|---|---|
| Header band | `[0, 0, 183, 40]` | Fill #F5F5F7; 1 pt hairline #E9E9EB at y 39. Body below: #FDFDFF. | S2 10/0041 |
| Done | `[0, 0, 40, 40]` | `xmark.circle.fill` 16 pt, #ACACAD. Closes the editor (keeps changes). AX "Done". | S2 10/0030 |
| Name button | `[46, 8, 91, 24]` | Boost name 15 pt Medium #252526 (size visual), tail "…", then `chevron.down` 10 pt #949495. Click opens the name menu. AX label = name. | S2 10/0030, 0041 |
| Undo | `[143, 0, 40, 40]` | `arrow.counterclockwise` 17 pt, #ACACAD. Undo one editor step; disabled when the stack is empty (same color in both captured states; enabled color guess = #6E6E70). Redo has no button: ⇧⌘Z only (Open choice). | S2 10/0030, 0041 |

Name menu (native `NSMenu` under the name button; S2-18 order, then Open's scope addition):

| # | Item | Action |
|---|---|---|
| 1 | Rename this Boost… | Alert "Rename this Boost" with a text field (prefilled, all selected), "Done" (default) / "Cancel". Empty text allowed. Writes `name`. (Rename alert look not captured.) |
| 2 | Shuffle | Random hue `θ ∈ [0, 360)`, intensity `ρ ∈ [0.6, 1.0]`, random font from the grid except Wingdings; text size and case unchanged. One undo step. |
| 3 | Reset all Edits | Clears color, font, size, case, Zaps, CSS, JS (keeps name, scope, enabled). Confirmation: "Reset all edits?" / "This removes every change in this Boost." / "Reset" / "Cancel" (Open's words). One undo step. |
| 4 | Delete this Boost | Alert "Delete this Boost?" / "This can't be undone." / "Cancel" (Esc) / "Delete" (red, default, Return). On Delete: `BoostStore.delete(id:)`, close the editor. (S2-18; Arc's alert is 450 × 273 and centered; Open uses the system alert as a sheet on the editor, Open choice.) |
| 5 | — | |
| 6 | All Boosts… | `showBoostsLibrary(profileID:)` (editor stays open) |
| 7 | — | Open addition (Arc's editor shows no scope control) |
| 8 | Apply to ▸ | Submenu with the scope items below |

Scope submenu (lead decisions 2026-10-25 23:46 and 2026-10-26 03:37 / 09:26, kept; writes `siteMatch`
through `BoostStore.upsert`, then refresh):

- "All of <registrable domain>" — `SiteMatch(domain: registrableDomain)`; omitted for IP hosts.
- "<host> and subdomains" for each host between the page host (without `www.`) and the registrable
  domain — `SiteMatch(domain: thatHost)`.
- "Only pages under /<segment>" — `SiteMatch(domain: current.domain, pathPrefix: "/<segment>")`;
  hidden when the path is `/`. A saved `pathPrefix` is always offered and checked, even on another
  path.
- IP hosts: one "<ip>" item plus the path item. The current choice has a checkmark.

Banners (Open-only; lead round 2 geometry, adapted to the narrow window): 14 pt text insets, 7 pt
vertical padding, 11 pt Medium #252526 text on `BoostEditorColors.warning` (`#FF5A5F`) at 15 %;
28 pt for one line, 42 pt for two; the 183 pt width wraps most texts to two lines.

- Not active: "This Boost doesn't apply to <host>."
- Global off: "Boosts are off. Changes show when you turn Boosts on in Settings."

### 4.4 Color pad

#### 4.4.1 Geometry and drawing (measured)

| Part | Value | Source |
|---|---|---|
| Ring frame | `[18, 58, 147, 147]`, outer corner radius 20 | AX "Color wheel"; IS §20.15 |
| Plate | `[25, 65, 133, 133]`, corner radius 13.5; the ring is the 7 pt band between frame and plate | AX "Color wheel" (inner image); IS §20.15 |
| Pad center, radius | `(91.5, 131.5)`, `R = 66.5` (half the plate side, the theme pad's rule) | center measured; R = theme law (guess for the Boost pad) |
| Frame shadow | Black 0.08, radius 4, y 2 (fit to a ≈ 9 pt fade under the frame; guess) | S2 10/0041 |
| Plate fill | #FAFAFA; after a color, a faint tint of the ring: the ring image blurred (σ 12) at 4 % over the plate (guess fit to #FBFFFA near green, #FDFAF6 near orange) | S2 10/0030, 0041 |
| Dot grid | 1 pt round dots, pitch 4.0, aligned to the plate origin, black 0.075. Our own cached `CGImage` tile per scale (as `ColorPadView.DotGrid`). | S2 10/0030 |
| Hue ring (color chosen) | Conic gradient centered on the pad center, angle 0 at 3 o'clock, increasing clockwise on screen. Stops (sRGB): 0° #EB4838 · 30° #EB7636 · 60° #F4BA49 · 90° #D4FD58 · 120° #90FC74 · 150° #80FCAD · 180° #7CF8F1 · 210° #356FF6 · 240° #392EF4 · 270° #8237F5 · 300° #DD31BF · 330° #DF3470 · 360° = 0°. Clipped to the 7 pt band. | IS §20.15 |
| Hue ring (no color) | The same stops converted to grey by Rec. 709 luma (for example 90° #EAEAEA, 225° #454545). | IS §20.15 (within ≈ 10 levels) |
| Ring vs knob hue | The ring's own hue leads or lags the angle by up to ≈ 20° (for example 90° reads HSL hue 75°), while each knob's fill hue equals its angle within 1.5°. Compute knob fills from θ (§4.4.2); never sample the ring. | IS §20.15 |
| Primary knob | 30 pt disc + 2 pt white ring (34 outside) + shadow black 0.10 radius 1.5 y 0.5 (guess). While dragging: disc 38 (scale 1.27), spring back to 30 on mouse up (response 0.2 s, guess). | S2 10/0039–0041 |
| Secondary knob | 19 pt disc + 2 pt white ring + 1 pt outline #C8C2CA (23 + 2 outside). Not draggable (guess: only the primary was dragged in the capture). | S2 10/0041 |
| Drag guide | While dragging: a 2 pt circle, black 0.06, centered on the pad center, through the primary knob's center. Removed on mouse up. | S2 10/0038–0040 |
| Knob z-order | Knobs draw above the ring and are not clipped by the plate (Open choice; the measured knobs stayed inside the plate). | guess |

#### 4.4.2 Interim mapping (Open's law until Arc's math is decoded)

Screen ↔ inputs (shared with the theme pad, `space-theme-editor.md` §2.2):

```text
p = point − padCenter                                 // points, y down
θ = (atan2(p.y, p.x) in degrees + 360) mod 360          // 0 at 3 o'clock, clockwise on screen
t = min(hypot(p.x, p.y) / R / 0.99, 1)                  // R = 66.5
knob center = padCenter + 0.99 · t · R · (cos θ, sin θ)
BoostColorWheel.hue = θ                                 // the target hue; screen angle = hue
BoostColorWheel.intensity = t
secondary knob: angle θ + 45°, same radius
```

Knob fills (fitted to S2 10/0041, one sample; guess elsewhere):

```text
primary   = HSB(θ,        s: t,        b: 0.78)        // measured #5C3CC8 at θ 252.3°, t 0.70
secondary = HSB(θ + 45°,  s: 0.68 · t, b: 0.24)        // measured #3D203C at 296.6°
no color (colorWheel nil or identity): knobs at θ 0°, t 0.61 (r = 40 pt), fills #717171 and #333333,
grey ring                                                // S2 10/0030, 0038
```

- `BoostColorWheel` keeps its fields and ranges; only the doc comment of `hue` changes ("target hue
  in degrees; drawn at the same screen angle, clockwise from 3 o'clock"). `adjustment` (the §4.4.5
  filter math) does not change. No stored data exists yet (the model is only on PR #103).
- The first press anywhere on the plate creates `colorWheel` if it is nil (sampling `baseHue` first,
  §4.4.5) and sets it from the press point; a press on the primary knob drags relatively, a press
  elsewhere jumps the knob there, then drags (theme pad rules). The default knob position before a
  color is only a drawing; it does not imply `t = 0.61`.
- Each drag event sends one live plan to the bound page (≤ 60 Hz, coalesced per display frame);
  the store commit and one undo step happen on mouse up (D-6).
- Keyboard (pad focused; shared with the theme pad): ←/→ hue ∓/± 5° (Shift 20°), ↑/↓ intensity
  ± 0.03 (Shift 0.1). Repeats coalesce for 1 s and commit on focus loss (lead round 2). Focus ring
  around the ring frame (radius 22), keyboard focus only.

#### 4.4.3 Reuse: one pad core (D-12)

Move the reusable part of `OpenSpaceEditor/ColorPadView.swift` (PR #86) into
`OpenDesign/ColorPad.swift`; do not copy it.

| `OpenDesign/ColorPad.swift` (shared) | Owner-specific |
|---|---|
| `ColorPadView` (`NSView`, layer-backed, flipped): plate layer, dot-grid layer from a cached tile, up to 3 knob layers, an optional ring layer, an optional guide layer; relative drag on the primary knob (hit radius = knob outer radius + 4), jump elsewhere; arrow keys with begin/end gesture callbacks; focus ring; AX role `.slider` with increment/decrement. | Geometry and colors: `ColorPadStyle` (plate size and corner, dot pitch and color, knob disc / ring / outline sizes, drag scale, ring width, guide). |
| Unit-disc conversion with `R` and the 0.99 rim clamp. | Color law: `ColorPadLaw` protocol — `knobs(for state) -> [ColorPadKnob]` (unit position + fill) and `value(at unit point, relative:)`. Theme: lightness by radius (`space-theme-editor.md` §2.2). Boost: §4.4.2. |
| Knob hover / drag scale animations. | AX value text. |

`OpenSpaceEditor.ColorPadView` becomes a thin wrapper with `ColorPadStyle.theme` (340 plate, pitch
4.25, 44 / 30 knobs). `OpenSiteControl.BoostColorPadView` uses `ColorPadStyle.boost` (values in
§4.4.1) plus the ring and guide layers. Landing order is in §12.4.

#### 4.4.4 What is still unknown about Arc's color math

| Unknown | What the capture says | Interim |
|---|---|---|
| Radius meaning | One sample: at t ≈ 0.70 the primary fill is HSB(253.6°, 0.70, 0.78). Two points cannot tell saturation from intensity or lightness. The theme pad's law (radius → lightness 0.01 … 0.97) predicts HSL L 0.68; measured 0.51, so the Boost knob does not follow the theme's lightness law with the theme's ranges (derived). | `t` = intensity (§4.4.2). |
| Pad radius `R` | The drag reached 46 pt; the rim was not tested. | `R = 66.5` (theme rule). |
| Secondary knob | Always +45° on the same radius in both samples; darker fill. BO-17 names analogous and complementary scheme assets, but no scheme control is visible in the captured editor. Whether the offset can change, or the knob can be dragged, is unknown. | Fixed +45°, not draggable. |
| Page remap | One color recolored white to a pale tint of the primary's hue and near-black to a saturated tint of the secondary's hue; images kept their colors (S2-22). Open's filters rotate hues and cannot tint white or grey (R-2). | Filters (Q4); Q12 asks the lead. |
| Invert lightness, sliders | Effects not measured. Sliders sit at 50 = neutral. | Map 0…100 → brightness and contrast 0.5…1.5 and original saturation 0…2 (50 → 1). |
| Theme pad law | Still being decoded in the Space editor lane; this plan reuses its geometry and angle law only. | Revisit both laws together. |

#### 4.4.5 Runtime math (unchanged) and notes

`BoostColorWheel.adjustment` (OpenBoosts) keeps the first version's normative math. `θ` is the
stored `hue` and `ρ` the stored `intensity`; only the screen mapping (§4.4.2) changed:

```text
inputs:  hue θ ∈ [0, 360), intensity ρ ∈ [0, 1], baseHue h0 ∈ [0, 360) or nil,
         invertLightness Bool, brightness b ∈ [0.5, 1.5] (1), contrast c ∈ [0.5, 1.5] (1),
         originalSaturation s0 ∈ [0, 2] (1)
Δ        = ((θ − (h0 ?? 0)) + 540) mod 360 − 180           // shortest signed turn, [−180, 180)
rotate   = ρ · Δ                                            // pull the page's main hue toward θ
sat      = s0 · (1 + 0.5 · ρ)
if invertLightness: invert = 1, rotate += 180 else invert = 0
ColorAdjustment(hueRotateDegrees: rotate mod 360 → [0, 360),
                saturation: clamp(sat, 0, 3), brightness: b, contrast: c, invert: invert)
identity (→ colorAdjustment = nil, colorWheel = nil) when ρ < 0.02, !invertLightness,
         b == 1, c == 1, s0 == 1
```

- `h0` is the page's dominant hue, sampled once when the Boost first gets a color: take
  `WebContent.snapshotPNG()`, draw it into a 64×64 sRGB bitmap, keep pixels with HSB saturation ≥
  0.25 and brightness ≥ 0.25, weight each by `saturation × brightness`, build a 36-bin hue histogram,
  take the peak bin and its two neighbours, and return their weighted circular mean. If the kept
  weight is < 2 % of the pixel count, `h0 = nil` (a neutral page). Store `h0` in
  `colorWheel.baseHue`; never re-sample while `colorWheel` exists (the page is already recolored).

- Neutral page (`baseHue == nil`): the hint "Few colors here. Try Invert lightness." (lead
  2026-10-26 09:32) draws inside the plate, centered on its lower third, 10 pt Medium #8E8E93, up to
  two lines, hidden while dragging (geometry amended for the 133 pt plate).
- Legacy filters (lead 2026-10-26 03:21, kept): a Boost with `colorAdjustment` but no `colorWheel`
  keeps that exact filter until the first color edit. Before that edit the pad shows the closest
  values it can represent and the note "Custom colors — editing replaces them." in the same place as
  the hint. The displayed pad keeps any representable hue and saturation, clamps brightness and
  contrast to their ranges, and picks the nearer invert endpoint (0.5 rounds up); these displayed
  values do not change the stored filter. The first color edit replaces the filter with
  pad-derived values as one undo step; undo restores the exact legacy `colorAdjustment` and leaves
  `colorWheel` nil. Non-color edits never convert the legacy filter.
- Reset to original colors: `colorWheel = nil`, `colorAdjustment = nil`; knobs animate to the
  no-color position (0.22 s ease-out) and the ring fades to grey (0.22 s); sliders reset to 50.

### 4.5 Color buttons and the advanced popover

Three buttons at y 220, height 38: x 18 (w 42), 70 (w 43), 123 (w 42), gap ≈ 10 (S2 10/0030). Fill #EBEBED,
corner 9 (visual), glyph 17 pt Regular #3A3A3B; pressed fill #DFDFE0 (S2 10/0041); disabled
glyph #BDBDBF (visual).

| Button | Glyph (Open's SF choice) | AX / tooltip | Behavior |
|---|---|---|---|
| Invert lightness | `lightbulb` (on: `lightbulb.fill`, fill #333333, white glyph — guess, same as Zap on) | "Invert lightness" | Toggles `colorWheel.invertLightness` (creates `colorWheel` with t 0 if needed). |
| Advanced color controls | `slider.horizontal.3` | "Advanced color controls" | Toggles the advanced popover. While it is open the button is #474747 with a white glyph (S2 10/0042). |
| Reset to original colors | `nosign` | "Reset to original colors" | Disabled until a color change (S2 10/0030 disabled, 0039 enabled). §4.4.5. |

Advanced popover (S2 10/0042): a light popover drawn by Open (not `NSPopover`, to avoid Liquid
Glass, D-3), in a child borderless panel of the editor because it extends past the editor's left
edge. Window 250 × 232 at editor (−34, 258); body 222 × 204 (14 pt shadow margins), corner 12,
arrow up 9 × 28 at the button center; material: light `.popover` (measured #E6E6E8–#EFEFF1 over the
editor; guess on the material). Content inset 18:

| Row | Label (13 pt Regular #3A3A3B) | Slider |
|---|---|---|
| 1 | "Contrast" at y 299 (editor space) | 186 × 16 at y 318 |
| 2 | "Brightness" at y 361 | 186 × 16 at y 380 |
| 3 | "Original Saturation" at y 423 | 186 × 16 at y 442 |

Slider: track 4 pt, unfilled #D8D8DA, filled #A9A9AB (visual), knob a white capsule 20 × 16 with
shadow black 0.15 radius 1.5 (AX value indicator 20 × 16). Range 0…100, 50 = neutral (S2 10/0042).
Drag previews live; one undo step per drag. Esc, a click outside, or the button closes the popover.

### 4.6 Font grid

| Part | Value | Source |
|---|---|---|
| Card | `[18, 273, 147, 120]`, white, corner 11, shadow black 0.06 radius 8 y 1 (fit to the 7–9 pt fades) | S2 10/0041 |
| Grid | 5 columns at x 23, 51, 79, 106, 134 (pitch ≈ 27.75); 4 rows at y 281, 307, 333, 359; cells 26 × 26 | AX S2 10/0018 |
| Cell | "Aa" ≈ 14 pt in the cell's family, #999999, centered | S2 10/0030 |
| Selected | A 26 pt circle #D9D9D9 behind the cell; glyph #8C8C8C. No cell is selected for "Original". | S2 10/0046 |
| Hover / pressed | Circle #ECECEC / #D9D9D9 (guess) | guess |

Fonts, row by row (the 18 named faces in the binary's string order; cells 1 and 6 are visual guesses,
IS §20.15): System (`system-ui, -apple-system, sans-serif`), Helvetica Neue, Avenir, Futura, DIN
Alternate · Arial Rounded MT Bold, PT Mono, Courier, Times New Roman, Charter · Baskerville, Hoefler
Text, Palatino, Chalkboard, SignPainter · Snell Roundhand, Papyrus, Apple Chancery, Luminari,
Wingdings. CSS values are `<Family>, <generic>` with no quotes or semicolons (the planner rejects
`;{}"`).

- Click a cell → `fontFamily` = its value. Click the selected cell → `fontFamily = nil` (Original;
  guess). One undo step.
- A family that is not installed: the cell draws "Aa" in the system font at 30 % and is disabled
  (Open choice; the grid keeps its shape).
- Tooltip and AX label: the family name (Open choice; Arc's AX label is "Aa"). AX group
  "Fonts", role grid; arrows move, Space/Return applies.

### 4.7 Size, Case, Zap, Code

| Button | Frame | Look | Behavior |
|---|---|---|---|
| Size | `[18, 408, 70, 38]` | #EBEBED, corner 9, "Size" 15 pt Medium #3A3A3B centered | Cycle small → normal → medium → large → larger → small (Shift-click: back; right-click: menu of the five, Open addition). Writes `textZoom` (0.9, nil, 1.1, 1.25, 1.5; values guess). AX "Change text size", value = option name. The label never shows the value (S2 10/0050). |
| Case | `[96, 408, 69, 38]` | same, "Case" | Cycle none → capitalize → uppercase → lowercase → none (Shift-click back; right-click menu). Writes `textTransform`. AX "Change text case", value "Original" / "Capitalize" / "Uppercase" / "Lowercase". |
| Zap | `[18, 461, 147, 38]` | "Zap" at x 15 (15 pt Medium), `bolt.fill` 15 pt at the right (15 pt inset). Zap mode on: fill #333333, white text and glyph. With Zaps: the count replaces the bolt ("1"). | Toggle Zap mode (§4.8). AX "Zap" or "Zap, <count>". Before P7: disabled, tooltip "Zap isn't available yet." (lead 09:32, kept). |
| Code | `[18, 514, 147, 38]` | "Code" + `curlybraces` at the right | Switch to code mode (§4.10). Before Step 7: disabled, tooltip "Code editing isn't available yet." |

The cycling behavior of Size and Case is a guess: the capture showed only the pressed fill and no
menu (IS §20.15). The four colored tool tiles and the editor accent colors of the first version are
removed.

### 4.8 Zap mode

Entry and exit (D-8):

| Event | Effect |
|---|---|
| Zap button on | `BoostPickerCoordinator.enterZap(boostID:for: pageID)` with the bound page's engine document identity; the adapter sends the command. Focus moves to the page so Esc and Cmd+Z reach the picker. The button turns dark (§4.7). |
| Picker commits (`zap:committed`, `zap:replaced`) | `coordinator.handle` persists; the editor reloads the count from `BoostStore`. One undo step per commit. |
| "Click to reveal" (page bar) | `BoostStore.removeZap(boostID:selector:)` and `coordinator.removeZap(selector:for:)`; refresh; one undo step. |
| Zap button off | `coordinator.exitZap(for:)`; send. |
| Picker exits by itself (`picker:exited`, Esc or Done) | The button turns light again. |
| Editor close, tab switch, navigation, frame destruction, transport loss | `exitZap` or `invalidate(pageID:)` per `docs/boosts.md`. |
| Before P7 | The button is disabled with the tooltip "Zap isn't available yet." and the adapter's Zap send path carries the `// Blocked on P7: isolated world` marker (app-shell D8). |

Page UI (in-page picker, restyled in Step 6 to Arc's look; S2 10/0058–0060, IS §20.6):

| Part | Value | Source |
|---|---|---|
| Content frame | 3 pt inner border #3139FF around the web content while Zap mode is on | S2 10/0060 |
| Bottom bar | 56 pt, #FBFBFD, full content width: "Click elements on the page to Zap them" centered, 13 pt, grey, with the word "Zap" in the accent color; "Done" button at the right (pill, #F0F0FA fill, 13 pt Medium) | S2 10/0060 (text color and button style visual) |
| Hover | The hovered element gets a yellow tint overlay (rgba(255, 214, 10, 0.35), guess) | S2 10/0060 |
| Click popup | White card ≈ 428 × 90, corner 12, shadow: "Zap this" (red fill), "Zap all related elements" (orange fill), "Cancel" (grey fill), each ≈ 38 tall, white 13 pt text; a grey band below with "<count> <selector>" in 11 pt monospace | S2 10/0060 |
| After a Zap | The bar offers "Click to reveal" with the zapped elements; clicking one reveals it (removes the Zap). Layout not captured: one chip per Zap, label = `ZappedElement.label` (guess). Hover on a chip previews the element (Arc `zapToPreview`). | notes 10:26:49 |

The bar label change replaces "Zap mode"; keep the "Zap all related (N)" check in
`tools/verification/boosts.mjs` by renaming it to the popup's "Zap all related elements" with the
count in the band.

### 4.9 Undo, rename, delete, shuffle, reset

- Undo model (unchanged): one `UndoManager` per session (`groupsByEvent = false`); each committed
  change registers the previous full `Boost` and restores it with `BoostStore.upsert` plus a refresh;
  drags register on mouse up; code editors register one Boost-level step on focus loss; owner tokens
  end a previous control's group (lead round 2).
- Undo: header button and Cmd+Z (editor key, outside text views). Redo: ⇧⌘Z only.
- Menu items in §4.3. Delete has no undo (Open choice).

### 4.10 Code mode

| Part | Value | Source |
|---|---|---|
| Header | 40 pt: "← Back" `[10, 9, 60, 23]` (`arrow.left` + "Back" 13 pt Medium) returns to simple mode; CSS · JS segmented control `[190, 8, 100, 24]` (two 50 × 24 segments, centered in the 480 window: x = width / 2 − 50). Done, name, and Undo are hidden in code mode. | S2 10/0071 |
| Code view | `[0, 40, width, height − 110]`; native `NSTextView` (D-9): monospaced system 12 pt, line height 16, inset 8 × 6, white background, gutter `NSRulerView` 36 pt (10 pt digits, #A0A0A5). Placeholders "your css here" / "your javascript here", 12 pt, black 30 %. Arc's body was not captured. | layout S2 10/0071; look Open choice |
| Bottom bar | 70 pt, white: "Pick Selector" `[15, h − 53, 38, 38]` (`eyedropper`) and "Show Developer Tools" `[63, h − 53, 38, 38]` (`hammer`), fill #EBEBED, corner 9. "Refresh to Run" (JS tab, when the JS differs from the JS the page loaded with): text button 13 pt Medium at the bar's right, x `width − 15 − w` (guess: not captured). | S2 10/0071 |

JS notice (Open's words, unchanged): the first time the JS tab has text, a 28 pt dismissible row
above the bottom bar: "JavaScript in a Boost runs on this site like the site's own code." with ×
(stores `open.boosts.hasDismissedJSNotice`).

Editing rules:

- Disable smart quotes, smart dashes, text replacement, automatic spelling correction, continuous
  spell checking, and data detectors. `usesFindBar = true` (Cmd+F). `allowsUndo = true`.
- Tab inserts two spaces; Shift+Tab outdents the selected lines by two spaces. Return keeps the
  current line's indentation and adds two spaces after a line ending in `{`; typing `}` on a
  whitespace-only line outdents it. Cmd+/ toggles `/* */` (CSS) or `//` (JS) on the selected
  lines. Cmd+] / Cmd+[ indent and outdent.
- Highlighter: re-color only the edited paragraph range ± 1 line and the visible range, on the main
  thread, after each edit (budget §7). Tokens (light only; the editor is always
  light): comments `#8E8E93`; strings `#C41A16`; numbers and units `#1C00CF`; CSS at-rules and JS
  keywords `#9B2393` Semibold; CSS property names `#326D74`; selectors and identifiers default text.
  (Open's own palette, Xcode-like; no Arc evidence.)
- CSS live: 150 ms after the last keystroke, write `css` with `BoostStore.upsert` and refresh all
  matching pages (D-6). Invalid CSS is applied as written (browsers skip bad rules).
- JS: 500 ms after the last keystroke, write `js` with `BoostStore.upsert`. The adapter reinstalls
  the Profile's document-start user scripts so the next load runs the new JS, and never runs it
  live (§5.3 JS rule). "Refresh to Run" is visible while the stored JS differs from the JS that was
  installed when the bound page last committed; it reloads the bound tab.
- The editor scrolls to and selects nothing on open; caret at the end of the text.

### 4.11 First-run card

Shown the first time an editor opens (`open.boosts.hasDismissedInterstitial` false; BO-21):

| Part | Value | Source |
|---|---|---|
| Dim | The whole window above the card is dimmed with black 0.30 (controls stay drawn under it, inactive). | S2 10/0018 |
| Card | White, from y 271 to the bottom, with a soft top shadow (black 0.25 fading over 9 pt). | S2 10/0018 |
| Icon | Open's own 70 pt rounded-square badge (brand blue #4848FF, white `wand.and.sparkles` 34 pt), rotated −12°, centered at x 91.5, overlapping the card top (bounding box ≈ `[49, 238, 86, 86]`). Not Arc's asset. | position S2 10/0018 AX `InterstitialIcon`; art Open's |
| Title | "Edit the Internet with Boosts", 20 pt Bold rounded system font (Open's font choice), #3139FF, centered, three lines at y 331, 354, 377 (line height 23) | S2 10/0018 |
| Body | "Make <host> your own!" with the host in Semibold, 13 pt, #95939F, centered, two lines from y 411 | S2 10/0018 |
| Footer | #CEDBFC from the wavy edge (≈ y 463) to the bottom. Wavy edge: our own sine path, amplitude 3, period 16 (guess). | S2 10/0018 |
| Make a Boost | `[14, 493, 155, 38]`, corner 10, vertical gradient #4848FF → #333AFF (direction guess), white 15 pt Semibold. Sets the flag and removes the card (fade 0.2 s, guess). | S2 10/0018 |
| Maybe Later | `[46, 541, 91, 31]`, text 13 pt Medium #7F819E. Closes the editor without setting the flag; an untouched new Boost is deleted (Open choice). | S2 10/0018 |

### 4.12 Keyboard (editor)

| Key | Where | Effect |
|---|---|---|
| Esc | Editor key, no field editing | Advanced popover open → close it. Zap on → exit Zap. Code mode → back to simple mode. Else close the editor. |
| Esc | Text field / code view | End editing (rename: cancel); a second Esc follows the row above. |
| Esc, Cmd+Z | Page key, Zap on | The picker exits / undoes (existing). |
| Cmd+Z / ⇧⌘Z | Editor key, outside a text view | Editor undo / redo. |
| Cmd+R | anywhere | Reload (existing); also runs changed JS. |
| Tab / Shift+Tab | Editor | Done → name → Undo → pad → color buttons → font grid → Size → Case → Zap → Code. |
| Arrows | Pad | §4.4.2. |
| Arrows | Font grid | Move the focus; Space / Return applies. |
| Cmd+1 / Cmd+2 | Code mode | CSS / JS tab (Open choice). |

### 4.13 Boosts list (Library)

The `view-boosts` command, the "Manage" header, and "All Boosts…" open the Library window on a new
section "Boosts". Arc keeps Boosts in its Home/Library (`BoostsPage`, `HomeBoostsDelegateAction`,
BO-12). Add `case boosts` to `LibrarySection` (after `captures`; symbol `paintbrush.pointed`), so
`open.library.lastSection` accepts `boosts`. The section is a SwiftUI view,
`Sources/OpenSettings/BoostsSection.swift`, like `DownloadsSection.swift`. Data follows the
existing snapshot-provider pattern in `LibraryTypes.swift`, so `OpenSettings` gains no `OpenBoosts`
dependency: `public struct BoostItemSnapshot: Identifiable, Sendable { id: String (Boost UUID),
name, domain, pathPrefix: String?, isEnabled }`, `@MainActor public protocol
BoostsProvider: AnyObject { func boosts(profileID: ProfileID) -> [BoostItemSnapshot] }`, and four
`LibraryActions` methods: `setBoostEnabled(id:enabled:profileID:)`, `renameBoost(id:to:profileID:)`,
`deleteBoost(id:profileID:)`, `editBoost(id:profileID:)`. The App implements them over `BoostStore`
(no second store). Profile scope: the Library's existing profile selection (`historyProfileID`
pattern in `LibraryViewModel`).

| Part | Value |
|---|---|
| Source | The selected Profile's `BoostStore.allBoosts()` (Profile picker at the top when more than one Profile exists). |
| Row | Height 52: site favicon 20 pt (`FaviconStore` by domain, fallback the Boost glyph `wand.and.sparkles` in `Core.brandBlue`), name 13 pt Semibold, subtitle "Made for <domain><pathPrefix>" 11 pt secondary (Arc's "Made for" form, BO-16 evidence), switch on the right, ⋯ menu: Edit…, Rename…, Delete…. |
| Edit… | Opens the site (`https://<domain><pathPrefix>`) in a new Today tab in the front window and opens the editor on that Boost when the tab commits its first URL. |
| Empty state | "Nothing Boosted Yet!" 15 pt Semibold, body "Open a site and choose New Boost in Site Controls." 12 pt (Open's words). |
| Global off | The same note as §3.7, plus a "Turn On" button that writes `open.advanced.enableBoosts = true`. |

---

## 5. Data and persistence

### 5.1 Where every value lives (no other writes)

Unchanged from the first version, with one default changed:

| Value | Written by | API | Storage |
|---|---|---|---|
| Site permission | Settings rows | `WebProfile.setPermission(_:for:origin:)` | Chromium content settings |
| Other content settings (E1) | Settings rows | `WebProfile.setSiteSetting(_:kind:origin:)` | Chromium |
| Per-site ad-block exclusion | Ad-block row; Settings allowlist | `AdBlockStore.setExcluded`, then `setAdBlockExcludedDomains(_:profileID:)` | `<root>/Profiles/<UUID>/adblock/exclusions.json` |
| Boost enabled | Boost row circle, Library switch | `BoostStore.setEnabled(id:enabled:)` | `boosts.json` |
| Boost name, scope, color, font, size, case, CSS, JS | Editor | `BoostStore.upsert` (color via `colorWheel`) | `boosts.json` |
| Zaps | Picker commits; "Click to reveal" | `BoostStore.appendZap` / `removeZap` | `boosts.json` |
| Global Boosts switch | Settings; Library "Turn On" | `open.advanced.enableBoosts` | `UserDefaults` |
| Interstitial dismissed | Editor ("Make a Boost") | `open.boosts.hasDismissedInterstitial` (false) | `UserDefaults` |
| JS notice dismissed | Editor | `open.boosts.hasDismissedJSNotice` (false) | `UserDefaults` |
| Code window size | Editor | `open.boosts.codeEditorSize` `"<w>x<h>"` (**`"480x588"`**, was `"560x640"`) | `UserDefaults` |
| Extension pin | Pin (E4) | `ExtensionHost.setPinned` | Chromium prefs |
| Cookies, cache | ⋯ menu | `WebProfile.clearSiteData(origin:kinds:)` (E2) | Chromium |
| Panel and editor position | — | none (Open choice) | — |

### 5.2 Model change (the only OpenBoosts model edit)

`BoostColorWheel` and `Boost.colorWheel` as in PR #103 (fields `hue`, `intensity`, `baseHue`,
`invertLightness`, `brightness`, `contrast`, `originalSaturation`; `clamped()`, `isIdentity`,
`adjustment`). The only change from #103: the `hue` doc comment (§4.4.2). `BoostStore.normalized`
clamps `colorWheel` and sets `colorAdjustment = colorWheel.adjustment` when it is non-nil. The
planner, the applier, the bridge, and the file schema version do not change.

### 5.3 Live preview path

```text
editor input ─┬─ drag event ──► BoostEditorSession.preview(boost')   (no store write)
              │                    └─► adapter.preview(plan for bound page only)   ≤ 60 Hz
              └─ commit ─────────► BoostStore.upsert(boost')  (1 s debounced save; saveNow on close/delete)
                                   └─► session publishes change
                                       └─► adapter.refresh(profile:)  rebuild matcher once,
                                           plan + boost:apply for every live page of the Profile
                                           whose URL matches any changed Boost's old or new siteMatch
```

- `adapter.preview` builds a plan with the in-memory Boost substituted for the stored one
  (`BoostInjectionPlanner.plan` over a matcher built from `allBoosts()` with the substitute) and
  sends it only to the bound page. On commit the normal refresh replaces it.
- Pages that no longer match after a scope change get `boost:clear` (or their new plan).
- JS rule: every live plan (preview and refresh) is sent with `combinedJS = ""` and
  `containsJS = false`. The applier runs a non-empty `js` once per new `planID`
  (`boost-applier.js` lines ~212–224, boosts plan §6.5), so a live plan with JS would execute
  half-typed code and repeat side effects. Boost JS runs only from the document-start user scripts
  the adapter installs (app-shell §4.5).
- Before P7 the adapter evaluates in the main world (app-shell D8). After P7 it delivers into the
  isolated world (E5).

---

## 6. API and code layout

### 6.1 Files

```text
Packages/OpenKit/Package.swift                         OpenSiteControl library + sitecontrol-render executable
Packages/OpenKit/Sources/OpenDesign/SiteControlTokens.swift   SiteControlMetrics, SiteControlColors, BoostEditorMetrics, BoostEditorColors, Motion, Typography (Appendix A)
Packages/OpenKit/Sources/OpenDesign/ColorPad.swift      shared pad core (D-12, §4.4.3)
Packages/OpenKit/Sources/OpenDesign/PopoverShape.swift  body + arrow path (continuous corners) for the panel and the advanced popover
Packages/OpenKit/Sources/OpenDesign/TooltipView.swift   shared capsule tooltip (moved from OpenSidebar in #69)
Packages/OpenKit/Sources/OpenBoosts/Boost.swift        BoostColorWheel + Boost.colorWheel (§5.2)
Packages/OpenKit/Sources/OpenBoosts/BoostStore.swift   normalization, saveNow, stale temp files (#103)
Packages/OpenKit/Sources/OpenBoosts/Resources/zap-picker.js   Arc-look bar, popup, frame, "Click to reveal" (Step 6); select mode (Step 8)
Packages/OpenKit/Sources/OpenSiteControl/
  SiteControlTypes.swift          value types (§6.2)
  SiteControlDataSource.swift     protocols the App implements (§6.3)
  SiteControlController.swift     overlay presentation, anchoring, arrow, dismissal, keyboard, menu
  SiteControlView.swift           panel: material, action row, sections, footer
  SiteControlRows.swift           SiteControlRow, section label row, action button, extension "+" tile, footer pill
  BoostEditorSession.swift        editing state, undo, preview/commit, baseHue sampling
  BoostEditorPanel.swift          BoostEditorController, NSPanel, placement, simple/code switch
  BoostEditorViews.swift          header, banners, color buttons, font grid, Size/Case/Zap/Code, first-run card
  BoostColorPadView.swift         Boost pad on the shared core (ring, guide, law)
  BoostAdvancedPopover.swift      child panel with the three sliders
  CodeEditorView.swift            NSTextView subclass, highlighter, gutter
Packages/OpenKit/Sources/OpenSpaceEditor/ColorPadView.swift   thin wrapper over OpenDesign/ColorPad (§12.4)
Packages/OpenKit/Sources/OpenSidebar/ChromeViews.swift        URL field button states (§3.10, Step 3)
Packages/OpenKit/Sources/OpenSettings/BoostsSection.swift, LibraryTypes.swift, SettingsTypes.swift   Library section and defaults
Packages/OpenKit/Sources/sitecontrol-render/          main, Scenes, Flows, Bench, FakeSources, EditorScenes, EditorFlows, EditorBench, NativeOverlayCapture
Packages/OpenKit/Sources/OpenFeatures/PaneChromeView.swift, BrowserWindowController.swift   anchors and handlers (§6.4)
App/SiteControl/AppSiteControlSource.swift, App/Boosts/BoostEngineAdapter.swift, App/Automation/AutomationController.swift
tools/e2e/engine_e2e.py, tools/verify-all.sh, tools/verification/check.py
```

`OpenSiteControl` must not import `OpenFeatures`, `OpenSidebar`, or `OpenSpaceEditor`.

### 6.2 Value types (`SiteControlTypes.swift`)

`SiteSettingTile` keeps its name (it is the data of a Settings row; renaming is not worth the
churn). `BoostItemSnapshot.accentIndex` is removed (§4.13).

```swift
public struct SiteControlContext: Sendable, Equatable {
    public var tabID: ItemID
    public var profileID: ProfileID
    public var url: URL
    public var displayHost: String          // humanReadableHost; AX description only (no header)
    public var isIncognito: Bool
    public var security: SiteSecurity       // .secure, .insecure, .unknown (before E3: by scheme)
}

public enum SiteSettingKind: Hashable, Sendable {
    case contentBlocking
    case permission(SitePermission)          // OpenWeb's 12 kinds
    case content(String)                     // E1 kind id, e.g. "javascript"; display via table §3.8
}

public enum SiteSettingState: Sendable, Equatable { case on, off, unavailable }

public struct SiteSettingTile: Sendable, Equatable, Identifiable {
    public var id: String                    // stable: "contentBlocking", "permission.camera", "content.javascript"
    public var kind: SiteSettingKind
    public var title: String
    public var subtitle: String              // "On"/"Off"/"Allowed"/"Blocked"
    public var state: SiteSettingState
    public var symbol: String                // default "gearshape.fill"
    public var inUse: Bool
    public var help: String?
}

public struct SiteControlSnapshot: Sendable, Equatable {
    public var context: SiteControlContext
    public var tiles: [SiteSettingTile]
    public var boosts: [Boost]               // matching, matcher order
    public var boostsGloballyEnabled: Bool
    // extensions: absent until OpenExtensionsUI (#96 decision); the "+" tile needs no data
    public var capabilities: Set<SiteCapability>   // which E-items exist (§9 E1–E5)
    public var commandsEnabled: [String: Bool]     // action buttons and menu items
}

public enum SiteCapability: Hashable, Sendable { case changedSettings, clearCache, securityState, certificateViewer, extensionPinning, isolatedWorld }
public enum SiteSecurity: Sendable, Equatable { case secure, insecure, unknown }
public struct SiteDataKinds: OptionSet, Sendable { public let rawValue: Int
    public static let cookies = SiteDataKinds(rawValue: 1), cache = SiteDataKinds(rawValue: 2), storage = SiteDataKinds(rawValue: 4) }
public enum SiteControlAction: Sendable, CaseIterable { case share, newBoost, capturePortion, captureFullPage }   // §3.4
public enum BoostCodeTab: Sendable, Equatable { case css, js }
public enum BoostEditorMode: Sendable, Equatable { case simple, code(BoostCodeTab) }
public enum SiteControlPresentationMode: Sendable, Equatable { case standard, extensionPicker }   // §3.6.1
public enum SiteControlAnchor: Sendable, Equatable { case urlField, paneBar(ItemID), contentTopLeading }
```

### 6.3 Protocols the App implements (`SiteControlDataSource.swift`)

As on PR #103 (lead round 1 and 2 changes kept), plus `browserWindowFrame(tabID:)`:

```swift
@MainActor public protocol SiteControlDataSource: AnyObject {
    /// Current snapshot for the anchor tab. Must not block: reads stores and engine state already in memory.
    func snapshot(for tabID: ItemID) -> SiteControlSnapshot?
    /// Called when anything in the snapshot may have changed (store change, permission answered, extension update).
    func observeChanges(_ observer: @escaping @MainActor (ItemID) -> Void) -> SiteControlObservationToken
    func removeChangeObserver(_ token: SiteControlObservationToken)
}

@MainActor public protocol SiteControlActions: AnyObject {
    func toggle(_ tile: SiteSettingTile, tabID: ItemID)            // writes per §5.1, then notify observers
    func setBoostEnabled(_ id: BoostID, enabled: Bool, tabID: ItemID)
    func openEditor(boostID: BoostID?, tabID: ItemID, mode: BoostEditorMode)   // nil = new Boost
    func perform(command: String, tabID: ItemID, anchor: NSRect?)  // share-page, capture-page, capture-full-page, view-boosts, manage-extensions, add-extension
    func runExtension(_ id: String, tabID: ItemID, anchor: NSRect)
    func setExtensionPinned(_ id: String, pinned: Bool)            // E4
    func showSecurityDetails(tabID: ItemID)                         // E3
    func clearSiteData(_ kinds: SiteDataKinds, tabID: ItemID)       // E2 / interim
    func openURLInNewTab(_ url: URL, tabID: ItemID)                 // chrome://settings site details
    func reload(tabID: ItemID)
    func openAdBlockSettings(tabID: ItemID)  // Settings → Advanced → Ad Blocking; App adapter in Step 3
}

@MainActor public protocol BoostEditorHost: AnyObject {
    func store(for profile: ProfileID) -> BoostStore
    func preview(_ boost: Boost, tabID: ItemID)                     // §5.3 bound page only
    func refresh(profile: ProfileID)                                // §5.3 all matching pages
    func pageSnapshot(tabID: ItemID) async -> Data?                 // PNG for baseHue
    func enterZap(boostID: BoostID, tabID: ItemID) -> Bool           // coordinator + send; false if blocked (P7)
    func exitZap(tabID: ItemID)
    func removeZapFromSession(_ selector: String, tabID: ItemID)
    func requestZapCounts(tabID: ItemID)                            // zap:list
    func observePickerEvents(_ observer: @escaping @MainActor (ItemID, BoostPickerEvent) -> Void) -> SiteControlObservationToken
    func removePickerObserver(_ token: SiteControlObservationToken)   // committed, removed, exited, listResult
    func setDevToolsVisible(_ visible: Bool, tabID: ItemID)
    func reload(tabID: ItemID)
    func currentURL(tabID: ItemID) -> URL?
    func showBoostsLibrary(profileID: ProfileID)
    func browserWindowFrame(tabID: ItemID) -> NSRect?               // §4.2 placement (screen coordinates)
}
```

`BoostPickerEvent` is a small enum in OpenSiteControl that the App fills from
`BoostPickerCoordinator.handle` results. The App's adapter stays the only code that touches
`BridgeDecode` and the engine.

### 6.4 Controller wiring (OpenFeatures)

`BrowserWindowController` gains `siteControl: SiteControlController` and
`boostEditor: BoostEditorController?` (both from OpenSiteControl), created with the App-provided
`SiteControlDataSource`, `SiteControlActions`, `BoostEditorHost` (new optional factory parameters;
the render harness passes fakes).

| Intent / command | Handler |
|---|---|
| `.showSiteControls` | `siteControl.toggle(anchor: .urlField, tabID: focused tab)` (toggle = `present(…, mode: .standard)` or close). ⌥-click is ignored (§3.10). |
| Pane bar button 4 | `siteControl.toggle(anchor: .paneBar(paneTabID), tabID: paneTabID)` |
| Extension picker key binding (extensions-UI plan, Q11) | `siteControl.present(anchor: §3.6.1 rule, tabID: focused tab, mode: .extensionPicker)` |
| `.customizePage(tabID:)` | `edit-boost` for that tab |
| `new-boost`, `edit-boost`, `new-legacy-boost` | §4.1 |
| `view-boosts` | Library window, section `boosts` |
| `boost-gallery` | disabled |
| Tab selection change, Space switch, window resign main | Close the panel; close the editor if its bound tab is no longer shown |
| Panel open/close; matcher result for the selected tab | Set the URL field's `siteControlState` (§3.10): `rest`, `open`, `boosted`, or `openBoosted` (enum declared in OpenSidebar next to `URLFieldView`, because OpenSidebar must not import OpenSiteControl) |

`isCommandEnabled` returns false for the Boost commands in incognito windows and on non-http(s)
pages.

---

## 7. Performance budgets (release build, M5 Pro, 2x)

| Path | Budget | How measured |
|---|---|---|
| Click → panel first draw | p95 < 8 ms main thread (material view included) | `sitecontrol-render bench`: 20 Boosts, 12 rows, 30 extensions |
| Panel open, idle | 0 timers, 0 % CPU after the open animation (no sparkle animation) | run-loop observer over 2 s |
| Pad drag event → preview plan handed to host | p95 < 2 ms | 500 synthetic drag events |
| Live preview rate | ≤ 60 Hz to the page | 1 s, 120 Hz drag = ≤ 61 calls |
| Commit → matching pages refreshed | < 100 ms for 10 tabs (fake host) | |
| Code editor keystroke → highlight | p95 < 2 ms on a 2,000-line CSS file | |
| Editor open (simple mode) | p95 < 12 ms (font grid images cached per family) | |
| baseHue sampling | < 15 ms, off the main thread | |

The lead's 2026-10-26 timing exception for a loaded machine still applies to review runs; rerun the
budgets before merge.

---

## 8. Verification (no unit tests)

### 8.1 Offscreen renders and flows: `sitecontrol-render`

Commands unchanged (`render`, `ax`, `flows`, `check`, `bench`, `screens`, `motion`, `compare`).

States: `scc-no-boosts` (S2 09/0010 content: "+", Developer Mode hidden, one allowed setting),
`scc-boost` (S2 11/0005 content plus one Boost), `scc-adblock-on`, `scc-adblock-excluded`,
`scc-adblock-unavailable`, `scc-insecure`, `scc-boosts-off`, `scc-incognito`, `scc-internal-page`,
`scc-many` (scrolls), `scc-pane-anchor`, `scc-clamped` (narrow window), `scc-light` (guess),
`scc-hover-label`, `scc-hover-boost`, `scc-keyboard-focus`, `scc-reload`, `scc-menu`, `scc-picker`;
`editor-first-run`, `editor-no-color`, `editor-color` (S2 10/0041 values), `editor-dragging`,
`editor-advanced`, `editor-font-selected`, `editor-zap-on`, `editor-zap-count`, `editor-name-menu`,
`editor-scope-menu`, `editor-delete-alert`, `editor-not-active`, `editor-global-off`,
`editor-legacy`, `editor-neutral-page`, `editor-code-css`, `editor-code-js-dirty` (code states from
Step 7). Editor states render in light only.

Flows (each asserts the fake's recorded calls and the view state):

| # | Flow | Pass |
|---|---|---|
| F1 | Click the anchor → presented; click again → closed | no action calls |
| F2 | Esc closes; outside clicks (left, right, other) close and reach their target | dismiss reasons; target hit counts |
| F3 | Tab order of §3.12; arrows in the action row and between rows; Space toggles the focused row | focus list; one `toggle` |
| F4 | Ad-block row on → off → on | `toggle` ×2; subtitles On/Off/On; reload row once |
| F5 | Unavailable ad-block row | one `openAdBlockSettings`, no `toggle` |
| F6 | Permission row toggle | Allowed → Blocked; circle on → off |
| F7 | Boost row: circle click, row click, chevron, Return | `setBoostEnabled` ×1; `openEditor(id)` ×3 |
| F8 | New Boost from action 2 and from ⋯ (with and without a Boosts section) | `openEditor(nil, .simple)` ×3 |
| F9 | Every ⋯ item in each capability set | §3.9 list, always with Manage Boosts… and New Boost… |
| F10 | Pad drag of 40 events from the knob and from the plate | ≤ frame-count previews; 1 store write and 1 undo step on mouse up; stored `colorAdjustment == colorWheel.adjustment` |
| F11 | Pad law table: 12 screen points → (θ, t) and back; knob centers for stored values; secondary at θ + 45° | equal to §4.4.2 within 0.01 pt / 1e-9 |
| F12 | Font cell select and reselect; Size cycle (5 steps, Shift back); Case cycle | store values per §4.6–§4.7 |
| F13 | Zap on/off, picker exit, commit (count updates), reveal | host calls in order; button label and AX |
| F14 | Undo / redo after F10–F13 | store returns to each previous value |
| F15 | Rename (Done, Cancel, empty), Shuffle, Reset all Edits (Cancel, Reset), Delete (Cancel, Delete) | store values; editor closed after Delete |
| F16 | Close a new untouched Boost; close after one change; "Maybe Later" on a new Boost | deleted, kept, deleted |
| F17 | Code editor: type CSS, wait 150 ms (Step 7) | one `upsert` with the text, one `refresh`; Tab inserts 2 spaces; Return after `{` indents; Cmd+/ comments |
| F18 | JS tab: type; "Refresh to Run" appears; host reload; after reload with equal JS it hides (Step 7) | host calls in order; button visibility |
| F19 | First-run "Make a Boost" sets the flag; "Maybe Later" does not | UserDefaults (suite-scoped) |
| F20 | Incognito | New Boost disabled, circles disabled, no `openEditor` |
| F21 | AX labels and roles for `scc-boost` and `editor-color` | every §3.13 label; no unlabeled button |
| F22 | Snapshot nil while opening | panel does not open; one error log |
| F23 | Anchor geometry at sidebar widths 228, 300, 500 and a 400 pt window | arrow tip `(button.midX, 82)`, body top 91, body x `midX − 118` or clamped with the arrow inside the corner limits |
| F24 | Advanced popover open/close by button, Esc, outside click; slider drag | one undo step per drag; popover frame `(−34, 258, 250, 232)` relative to the editor |

`check` adds render probes: body width 236 and height 297 / 372 for `scc-no-boosts` / `scc-boost`;
action buttons at x 10, 66, 122, 178; row circles at the §3.3 positions; editor control frames equal
to the §4 AX frames within 0.5 pt; the fallback material over the two S2 probe backdrops within
ΔE00 3 of #403E54 and #7B7B7B.

### 8.2 Real app: automation and e2e suites (after app-shell Steps B, D, F)

New automation commands (`App/Automation/AutomationController.swift`, Debug/automation builds only;
document them in `docs/automation.md`):

| Command | Args | Does |
|---|---|---|
| `site-controls` | `action: open\|close\|state\|tap\|menu`, `via: urlField\|pane`, `id` (row/button id), `item` (menu title) | `open` clicks the real anchor button (`performClick` on the `PlateButton` / pane button); `tap` performs the click on the real control view; `menu` picks a ⋯ item through the real `NSMenu` item action; `state` returns the snapshot as shown (titles, subtitles, states, rows, items, visible flags). |
| `boost-editor` | `action: open\|close\|state\|drag\|key\|tap\|type`, `boost`, `mode`, `points` (pad drag path in editor-window coordinates), `id`, `text`, `tab: css\|js` | Drives the real panel views with synthesized `NSEvent`s inside Open's own windows (no system input, `docs/automation.md`). `state` returns the session (Boost value, modality, Zap on, Zap count, undo count). |
| `boosts` | `action: list\|get`, `profile` | Reads `BoostStore` contents. |
| `pasteboard` | — | Returns the general pasteboard string (Copy URL / Copy Selector checks). |

Suites in `tools/e2e/engine_e2e.py` (fresh user data dir; results JSON + PNGs under
`docs/engine-spike/` like the other suites). Today's suites load public sites and `data:` URLs;
these two need a cookie, an ad request, and a known page color, so add one helper
`fixture_server(tmp)`: Python stdlib `http.server` on `127.0.0.1:<free port>` in a thread, serving
files the suite writes into `tmp`:

- `ads.html`: a heading, a `#promo-banner` div, a cookie set by script (`document.cookie =
  "f=1"`), and a request to `/ad.js` that the bridge filter blocks (`filter` command substring
  `ad.js`).
- `boost.html`: body background `#FFFFFF`, a 600×300 header block filled `#2E7DF6` (the page's
  dominant hue, h0 ≈ 216°), an `h1`, three `article` elements, and the same `#promo-banner`.

No external network is needed by these suites.

`--only sitecontrol`

| # | Check |
|---|---|
| S1 | Open `http://127.0.0.1:<port>/ads.html`. `site-controls open via=urlField` → `state` shows 4 action buttons, the Extensions section with the "+" tile, Settings with "Block Ads & Trackers — On", footer "Insecure" (scheme rule before E3), and the arrow tip at the Site Control button. Window `snapshot` PNG saved. |
| S2 | `tap id=row.contentBlocking` → subtitle "Off"; `exclusions.json` on disk contains `127.0.0.1`; reload row visible; `tap id=reload` → `filter-stats` shows the ad fixture request allowed. Tap again → "On", file no longer contains it, reload → blocked. |
| S3 | `permission origin=… kind=camera state=1` (existing command) → reopen panel → row "Camera — Allowed"; `tap id=row.permission.camera` → "Blocked"; `permission` read returns 2. |
| S4 | Create a Boost through `boost-editor open` (New Boost), set CSS `body{outline:3px solid red}`, close. Reopen panel → Boosts row "My Boost — Enabled"; `eval` shows the outline. `tap id=boost.<id>.circle` → "Disabled", `boosts get` `isEnabled == false`, `eval` shows no outline without reload. |
| S5 | `menu item="Clear Cookies"` after the fixture sets a cookie → reload → `eval document.cookie` is empty. "Clear Cache" absent before E2. |
| S6 | The panel has no Copy URL button: `state` lists exactly Share, New Boost, and the two Capture actions. Copy URL still works through ⇧⌘C (`key route=app key=c modifiers=["cmd","shift"]`) → `pasteboard` equals the page URL; toast event recorded. |
| S7 | Esc (`key route=app key=escape`) closes; `state` reports closed; a page `click` while open closes the panel and the page receives the click (`eval` counter + 1). |
| S8 | Split: `split` (existing) → `site-controls open via=pane` → `state` reports the focused pane's tab and host (AX description). |
| S9 | Empty case: `about:blank` → `site-controls open` returns error "no site"; internal page → action row (Share enabled), Extensions "+", footer without a security label. |
| S10 | Incognito window (when app-shell §4.8 lands): New Boost disabled, Boost circles disabled. Until then: reported `blocked: incognito`, never pass. |
| S11 | Material on engine content (R-7): with the default dark theme and a white page, window `snapshot` probes the body over the sidebar (#403E54 ± 3 levels) and over the page (#7B7B7B ± 3). |

`--only boosteditor`

| # | Check |
|---|---|
| B1 | New Boost from the panel → `boosts list` has one Boost named "My Boost" with `siteMatch.domain == 127.0.0.1`; editor `state` shows simple mode (first-run card first on a fresh profile; `tap id=firstRun.makeABoost`). |
| B2 | On `boost.html`: `drag points=[…]` on the pad (pad coordinates) → `eval getComputedStyle(document.documentElement).filter` contains `hue-rotate`; `boosts get` has `colorWheel.baseHue` within ± 10° of 216 (the fixture header `#2E7DF6`); `colorWheel.hue` equal to the screen angle of the last point (§4.4.2), and `colorAdjustment` equal to §4.4.5 for the stored θ, ρ, h0. |
| B3 | `tap id=font.Avenir` (grid cell) → the `h1` computed `font-family` starts with `Avenir`; one text-size click → root `zoom` is 1.1; one case click → body `text-transform` is `capitalize`. |
| B4 | Zap (after P7, else `blocked: P7`): Zap button on → `click` on the fixture banner (existing page click command) → `boosts get` has one Zap; banner hidden probe; the Zap button reads "Zap, 1"; "Click to reveal" on its chip → banner visible without reload. |
| B5 | Code: `type tab=css text="h1{color:rgb(1,2,3)}"` → within 300 ms `eval` reads the color; `type tab=js text="document.body.dataset.boosted=1"` → "Refresh to Run" visible → `reload` → `eval document.body.dataset.boosted == "1"`. |
| B6 | Undo: `key route=app key=z modifiers=["cmd"]` with the panel key → last change reverted in `boosts get`. |
| B7 | Name menu: Rename → "Docs Boost" stored; Delete (alert "This can't be undone.") → store empty, editor closed. |
| B8 | New Boost, close at once → store empty. |
| B9 | Quit and relaunch with a saved Boost → the style applies at document start (existing `boosts` suite probe) and the panel lists it. |
| B10 | `defaults write <bundle> open.advanced.enableBoosts -bool false` before launch → panel shows "Boosts are off…", editor banner, no `hue-rotate` on the page. |

Any check that needs a missing engine item reports `blocked: E<n>` or `blocked: P7` and never
passes by itself.

### 8.3 Visual comparison

The captures now exist locally (`.re/runtime/sessions/…-09-site-controls-first`, `…-10-boost-editor`,
`…-11-site-controls-full`). Run `sitecontrol-render compare` against S2 09/0010 (`scc-no-boosts`),
11/0005 (`scc-boost`), 10/0018 (`editor-first-run`), 10/0030 (`editor-no-color`), 10/0041
(`editor-color`), 10/0042 (`editor-advanced`), 10/0071 (code bars), with colors converted to sRGB
from the embedded profile (IS §20.0). Targets: layout ≤ 1 pt; fills and text ΔE00 ≤ 2; the panel
material ΔE00 ≤ 4 (blur differs offscreen). Update only token values. Never commit captures or crops
(`AGENTS.md` rules 1, 5); the frames also show the user's own Spaces in some menus.

---

## 9. Engine capabilities the UI needs

| ID | Capability | Needed for | Today | Proposed OpenEngine API (engine team owns the final shape) |
|---|---|---|---|---|
| E1 | List the content settings a site has changed, for every Chromium content-setting type (not only the 12 permission kinds), and set them | Settings rows beyond the 12 kinds (JavaScript, Images, Pop-ups, Sound, Ads, …) | 12 kinds, ask/allow/block, no enumeration | `-[OEBrowserContext changedSiteSettingsForOrigin:] -> NSArray<OESiteSetting *>` (`kind` string id, `state` allow/block/ask/session); `-setSiteSetting:state:origin:`. OpenWeb: `WebProfile.changedSiteSettings(origin:)`, `setSiteSetting(_:kind:origin:)`. Arc: `getChangedContentSettingsForOrigin:` |
| E2 | Clear one origin's cookies, cache, or storage separately | ⋯ Clear Cache / Clear Cookies | `clearBrowsingData(origin:)` = cookies of one origin + cache of all sites | `-clearSiteDataForOrigin:types:completion:` with `OESiteDataTypeCookies \| Cache \| Storage` (Chromium `BrowsingDataRemover` + origin filter). OpenWeb: `clearSiteData(origin:kinds:)` |
| E3 | Security state and certificate | Footer security pill | none | `OEWebContent.securityLevel` (`secure`, `neutral`, `insecure`, `dangerous`, `mixedContent`) + change flag `OEWebContentChangeSecurity`; `certificateChain -> NSArray (SecCertificateRef)` so Swift shows `SFCertificatePanel`. Arc: `ArcSecureContext`, `showCertificateDialog` |
| E4 | Extension pin state, pin/unpin, the per-action context menu, and the toolbar image | Extensions section pin, right-click, item icon | manifest defaults, no pin | Names owned by `docs/plans/extensions-ui.md` §7 (use these, not new ones): its E2 adds `OEExtensionAction.toolbarImage` (28×28 pt with Chromium's badge baked in), `pinned`, `pinnedIndex`; its E4 is `-[OEBrowser setExtensionAction:pinned:]` and `-moveExtensionAction:toPinnedIndex:`; its E7 is `-contextMenuForExtensionAction:source:` returning `OEExtensionActionMenu` (items reuse `OEContextMenuItem`; `select(command:)` / `cancel()`). Engine work rides P2 (`docs/engine-patches.md`). |
| E5 | Evaluate in the isolated world and deliver picker/applier messages there | Zap, secure live preview | main world only | P7 |
| E6 | Blocked request count per page | Not shown in v1 (Q5); automation only | — | adblock-fork §12.1 `blockedResourceCountForBrowser:` |

Interim behaviors are stated per row in §3 and are listed in the PR of the step that ships them.

---

## 10. Implementation order

Each PR: merge `origin/main`, run `tools/verify-all.sh`, paste the summary (`AGENTS.md` rule 10).
Steps 1, 2, and 4 are open PRs that are reworked in place (§12).

| Step | PR | Work | Acceptance |
|---|---|---|---|
| 1 | #69 (rework) | Target, tokens, panel chrome: body + arrow path, material, anchoring, open/close motion, action row, footer (pill, ⋯ button), no header; harness with geometry probes | F1, F2, F21 (partial), F22, F23 PASS; `scc-no-boosts` chrome renders at 1x/2x |
| 2 | #96 (rework) | Sections: label rows, `SiteControlRow` for Boosts and Settings, Extensions "+" tile, reload row, ⋯ menu (always with Boost items), keyboard, picker mode, AX, height animation | F3–F9, F20–F22 PASS; all `scc-*` states; height probes 297 / 372 |
| 3 | new (App) | App data source and actions; URL field and pane anchors; URL field button states (§3.10); intents and commands; automation; e2e `sitecontrol` | S1–S9, S11 PASS (S10 blocked) |
| 4 | #103 (rework) | `BoostColorWheel` (as is); `OpenDesign/ColorPad.swift` (§12.4); editor window, placement, header, name menu with scope submenu, pad, color buttons, advanced popover, font grid, Size/Case/Zap/Code (Zap and Code disabled), first-run card, banners | F10–F12, F14–F16, F19, F24 PASS; `editor-*` simple states; `boosts` harness 26/26 |
| 5 | new (App) | App editor host (placement frame, preview/refresh), Boost commands, Library Boosts section | B1–B3, B6–B10 PASS; `settings-preview check` PASS |
| 6 | new | Zap: picker restyle (frame, bar, popup, "Click to reveal"), count on the button, picker events | F13 PASS; `boosts` harness PASS; B4 after P7 |
| 7 | new | Code mode (480 × 588 window, header, code view, bottom bar, CSS live, JS refresh, devtools, size persistence) | F17, F18, B5 PASS |
| 8 | new | "Pick Selector": picker select mode (`zap:enter` with `mode: "select"`; page → native `picker:selected {boostID, sessionNonce, selector, matches}`; no commit, no hide); the editor inserts the selector at the CSS caret | `boosts` harness incl. a check that select mode commits nothing; flow "Pick Selector inserts the selector" |
| 9 | new | Engine items E1–E4 as they land | interim rows switch |

---

## 11. Risks and open questions

### 11.1 Risks

| # | Risk | Mitigation |
|---|---|---|
| R-1 | Several values are still guesses (§13): Light appearance, 2x shapes, tooltips, the shadow, the pane anchor, Size/Case behavior, the pad's radius law. | Every value is one token; §13 lists what a future capture must cover. |
| R-2 | CSS filters cannot tint white or grey pages; Arc's pad does (S2-22). Boosts on white sites look weak compared with Arc. | Q12. The neutral-page hint points to Invert lightness. |
| R-3 | Live preview through `evaluateJavaScript` per frame could cost the renderer. | ≤ 60 Hz, bound page only, small plans; drop to 30 Hz if page frame time grows > 4 ms. |
| R-4 | Main-world picker and applier before P7 leak Boost state to page scripts. | Zap stays disabled until P7. |
| R-5 | Users lose a Boost by closing a new one quickly. | Only an unchanged new Boost is deleted (F16). |
| R-6 | The overlay must stay above web content in every layout. | Reuse the command bar overlay container order; `scc-pane-anchor`, full-screen e2e. |
| R-7 | A `.withinWindow` material may not blur the engine's remote layer content. | S11 on the real app in Step 3. Fallback: host the panel in a borderless child window with `.behindWindow` blending (keyboard focus then needs `becomesKeyOnlyIfNeeded = false` and a key-window check in `docs/design.md` §5.3). |
| R-8 | The editor straddles the browser window's right edge; on a full-width window it moves inside and covers page content. | Clamp rule (§4.2); the user can drag it. |

### 11.2 Open questions (need a lead decision; recommendation first)

Q1–Q11 are answered (Appendix C). New:

| # | Question | Recommendation |
|---|---|---|
| Q12 | The capture shows Arc's pad remaps page colors: white → a pale tint of the primary hue, dark → a saturated tint of the secondary hue, images untouched (S2-22). Keep Q4 (filters only) for v1? | Keep filters for the first editor release (no runtime change in #103). Then plan a "duotone" runtime step in OpenBoosts: CSS custom-property overrides for `background-color` and `color` on computed light and dark colors, measured against a scroll-performance gate. Filters cannot reach Arc's look. |
| Q13 | Arc showed no "Block Ads & Trackers" row on the test Profile (its blocker state was not recorded). Hide the row when the master switch is off? | Keep the `unavailable` row (lead decision Q5 context) until a capture with the blocker on; it explains why ads show. |
| Q14 | Arc shows "Developer Mode — Off" in Settings by default. Q2 hides it. Keep? | Keep hidden (Q2) until `page-platform.md` defines Developer Mode. |
| Q15 | Arc animates the Boost icon's sparkles while the panel is open. Build it? | No (idle CPU budget). Static sparkles. |

---

## 12. Migration of the open PRs (#69, #96, #103)

The three PRs implement the 2026-10-25 plan. Rework each in place; do not open replacement PRs. The
only new code unit is `OpenDesign/ColorPad.swift`, which lands inside #103's rework (§12.4). Each
PR drops its own edits to this plan file when it merges `origin/main` (take main's version; record
nothing new here without a lead decision) and regenerates its `docs/sitecontrol/step-N/` renders and
`SHA256SUMS`.

### 12.1 Landing order

```text
this docs PR → main
      │
      ▼
#69 rework (chrome) ──merge──► main
      │  #96 merges the reworked #69 branch (merge commit, no rebase)
      ▼
#96 rework (sections, menu) ──merge──► main
      │  #103 merges the reworked #96 branch
      ▼
#103 rework (editor + OpenDesign/ColorPad.swift) ──merge──► main
      │
      ▼
#86 (Space editor shell) adopts OpenDesign/ColorPad.swift on its next merge of main (§12.4)
```

#69 and #96 can be reworked in parallel if #96 merges #69 again before its review. #103's
non-pad work (window, header, grid, buttons) can start at once; its pad work waits for §12.4.

### 12.2 #69 — Site Control Center Step 1 (library shell and render harness)

| Area | Change | Stays |
|---|---|---|
| `OpenDesign/SiteControlTokens.swift` | Rewrite `SiteControlMetrics` to Appendix A: width 236, padding 10, arrow 9 × 28, action button 48 × 32 gap 8, footer 32, pill and ⋯ metrics. Remove `headerHeight`, `faviconFrame`, `titleX`, `titleBaseline`, `sidebarPanelGap`, `panePanelGap`, `anchorAlignmentY`, `actionButtonInsetY`, `openScale` 0.66, `separatorInset` 12, `footerButton` 28, the 6-button and 44 × 36 values. Add `SiteControlColors` (dark measured values, light guesses) and the spring `Motion.popoverOpen`. | `cornerRadius` 16 and `SiteControlShape` (lead decision C) |
| `OpenDesign/PopoverShape.swift` (new, or inside `SiteControlShape`) | One path = continuous r16 body + top arrow (base 28, height 9, tip radius 3) at an x offset. Fill, mask, and shadow use it. | — |
| `OpenSiteControl/SiteControlView.swift` | `SiteControlPanelView`: delete the header (`SiteControlFaviconView`, the host `SiteControlBaselineLabel`); replace the opaque fill and inner edge with the material view masked by the shape (harness: fitted fallback layer); 4 action buttons at x 10/66/122/178, y 10; footer = pill + 32 pt circle; separator full width minus padding. | dismissal view, outside-click forwarding, Esc responder restore |
| `OpenSiteControl/SiteControlController.swift` | `geometry` returns the button rect and URL field max Y; place the arrow tip and body per §3.1 (clamp, arrow limits); open/close animate around the arrow tip (§3.11). | toggle/present API, observer tokens, unavailable-tab reporting, generation guard |
| `OpenSiteControl/SiteControlTypes.swift` | 4-case action enum; remove `faviconPNG`. | context, security, anchors, modes |
| `OpenDesign/TooltipView.swift` | — | the move and shared presenter |
| `sitecontrol-render/*` | Scenes draw the URL field anchor at sidebar width 228 and a page backdrop (dark sidebar + white page) so the arrow and material show; replace header probes with arrow, width, and action probes (F23); render `scc-no-boosts` chrome. | offscreen renderer, Metal capture queue, receipts, bench |
| Plan file | Drop #69's plan edits (decisions A, B, top-aligned buttons, top-leading scale); take main's. | — |

### 12.3 #96 — Site Control Center Step 2 (sections, menu, keyboard picker)

| Area | Change | Stays |
|---|---|---|
| `OpenSiteControl/SiteControlTiles.swift` → `SiteControlRows.swift` | Replace `SiteControlTileButton` (2-column 142 × 48 tiles, two-line titles) with `SiteControlRow` (32 pt circle, title, subtitle, pitch 43, one-line truncation, hover plate). Rebuild `SiteControlBoostRow` on `SiteControlRow`: circle toggles, row and hover chevron open the editor; delete `SiteControlSwitch` and the edit button. `SiteControlSectionButton` becomes the label row (13 pt Semibold, accessory text only, no chevron). Add the "+" extension tile. | `SiteControlButton` base, `SiteControlDrawing` caches, keyboard-only focus rings |
| `OpenSiteControl/SiteControlView.swift` | Section order Extensions, Boosts, Settings with the §3.3 gaps; Extensions shows the "+" tile without `OpenExtensionsUI`; reload row and global-off note keep their baselines (row top + 20). | height animation of surface, mask, shadow, viewport, footer |
| `OpenSiteControl/SiteControlController.swift` | ⋯ menu always lists Manage Boosts… and New Boost… (New Boost… disabled when not allowed); open the menu at the click point; picker fallback focuses the "+" tile (Return runs `add-extension`). | native `NSMenu` routing, cancellation handling, Command-modifier rejection, Return/Space fall-through |
| `OpenSiteControl/SiteControlTypes.swift`, `SiteControlDataSource.swift` | `SiteSettingTile.symbol` default `gearshape.fill`. | `openAdBlockSettings`, observer tokens |
| `sitecontrol-render/*` | New state list (§8.1); flows F3–F9 rewritten for rows; height probes 297 / 372; delete tile and two-line-title renders. | `NativeOverlayCapture` (popup readiness wait) |
| Plan file | Drop #96's plan edits (tile wrap rule, "focus ⋯" fallback); take main's. | — |

### 12.4 #103 — Boost editor Step 4 (native controls and undo)

| Area | Change | Stays |
|---|---|---|
| `OpenBoosts/Boost.swift` | `hue` doc comment only (§4.4.2). | `BoostColorWheel`, `colorWheel`, decoding, `clamped`, `adjustment` |
| `OpenBoosts/BoostStore.swift` | — | normalization, `saveNow`, stale temp-file cleanup |
| `OpenDesign/ColorPad.swift` (new) | The shared pad core (§4.4.3). If #86 is merged when this rework starts, move the core out of `OpenSpaceEditor/ColorPadView.swift` and make that file a thin wrapper in this PR. If #86 is not merged, build `ColorPad.swift` from #86's `ColorPadView` code (same drag and keyboard semantics), and #86 replaces its `ColorPadView` internals with it before #86 merges. Either way one implementation lands. | — |
| `OpenSiteControl/BoostColorPadView.swift` (new) | Boost style, ring layer (conic stops, grey variant), guide layer, law (§4.4.2), legacy and few-colors notes inside the plate. Replaces `BoostColorWheelView` (ring + disc + puck). | `BoostEditorSession` drag/commit/undo wiring |
| `OpenSiteControl/BoostEditorPanel.swift` | 183 × 588 window, `.aqua` appearance, system shadow, corner 12; remove `EditorSurface`'s own shadow and the 30/24/36 padding; placement per §4.2 via `browserWindowFrame`; banners grow the window; code mode grows leftward to 480 (Step 7 fills it). | child-panel setup, non-activating behavior, rename alert plumbing |
| `OpenSiteControl/BoostEditorViews.swift` | Header (Done, name ⌄, Undo) replaces glyph/name/scope line/⋯/×; name menu per §4.3 with the "Apply to ▸" scope submenu (same `BoostScopeChoice` logic); color buttons 42 × 38; advanced sliders move to `BoostAdvancedPopover.swift` (order Contrast, Brightness, Original Saturation; reuse `EditorSlider`); font grid card (5 × 4, 26 pt cells) replaces the scrolling strip, viewport, and fade; Size/Case half buttons and Zap/Code rows replace the four colored tiles; first-run card per §4.11 ("Make a Boost", "Maybe Later"); delete alert text "This can't be undone."; remove dark variants and accent colors. | `EditorButton`, `EditorSlider`, `EditorNameField`, banners (re-laid for 183 pt), AX values for Size and Case |
| `OpenSiteControl/BoostEditorSession.swift` | Shuffle picks fonts from the grid list; the default-knob drawing has no model effect. | session, owner tokens, coalescing, legacy round trip, scope choices |
| `OpenDesign/SiteControlTokens.swift` | Rewrite `BoostEditorMetrics` and `BoostEditorColors` to Appendix A (light only). | — |
| `OpenSettings/SettingsTypes.swift`, `docs/plans/settings-library.md` | `open.boosts.codeEditorSize` default `"480x588"`. | the three defaults in the one registry |
| `sitecontrol-render/Editor*.swift` | Light-only states (§8.1); F10–F12, F24; frame probes against the §4 AX frames; drop dark editor renders. | real store, matcher, planner in the fake host; bench |
| Plan file | Drop #103's plan edits; the kept lead decisions are in main's Appendix C. | — |

---

## 13. Not captured yet (every value here is a guess)

| Item | Status in this plan |
|---|---|
| Tooltips (action buttons, color buttons, font cells, "+") and the tooltip delay | Labels from SC-15 / BO-17 / BO-18; delay from the shared tooltip. |
| ⌥-click on the Site Control button | Does not open the panel (measured); the dot Arc showed afterwards is unexplained. Open does nothing. |
| Option held inside the panel | No change (Q8). |
| Microphone, camera, and recording states (in-use rows, button states) | The in-use dot is Open's choice. |
| The code editor body (Arc's was a disabled internal page), "Refresh to Run" placement, devtools toggle state, the code window's resize behavior | Native editor (D-9); placements in §4.10 are guesses. |
| Any 2x display: arrow tip shape, corner shapes, hairlines, glyph weights | 1x fits only. |
| macOS Light for the Site Control Center | Light material and black-based text are guesses. |
| The panel shadow and the hover-reveal card anchor | Guesses (§3.2, §3.1). |
| Split pane bar anchor | Guess (§3.1). |
| Pad radius law, rim behavior, secondary knob dragging and scheme switching, invert effect, slider effect ranges | §4.4.4. |
| Size and Case behavior (cycle vs. menu) | Cycle (guess). |
| Rename alert look; the Delete alert's exact layout | System alert sheet (Open choice). |
| "Click to reveal" list layout | Chips (guess). |
| Insecure and certificate states; Clear Cache / Clear Cookies feedback | Open's rules. |
| Close animation of the Site Control Center | Theme popover timing reused. |
| Whether the editor position is remembered | Not persisted (Open choice). |

---

## Appendix A — Tokens (`OpenDesign/SiteControlTokens.swift`)

```swift
public enum SiteControlMetrics {           // §3. m = measured (S2), g = guess, o = Open choice
    public static let width: CGFloat = 236, padding: CGFloat = 10                         // m
    public static let cornerRadius: CGFloat = 16                                           // m ≈ 16–18; lead C
    public static let arrowHeight: CGFloat = 9, arrowBase: CGFloat = 28                    // m
    public static let arrowTipRadius: CGFloat = 3                                          // g
    public static let windowMargin: CGFloat = 8, contentAnchorInset: CGFloat = 12          // o
    public static let actionButton = CGSize(width: 48, height: 32), actionGap: CGFloat = 8 // m
    public static let actionRadius: CGFloat = 7, actionGlyph: CGFloat = 17                 // g (visual)
    public static let gapAfterActions: CGFloat = 37, sectionGap: CGFloat = 43              // m
    public static let labelBaselineAboveContent: CGFloat = 14, labelRowHeight: CGFloat = 24 // m / g
    public static let extensionTile = CGSize(width: 48, height: 32), extensionColumns = 4  // m / g
    public static let rowIcon: CGFloat = 32, rowPitch: CGFloat = 43, rowTextX: CGFloat = 50 // m
    public static let rowTitleBaseline: CGFloat = 13, rowSubtitleBaseline: CGFloat = 29   // m (±1)
    public static let rowGlyph: CGFloat = 15, rowHoverRadius: CGFloat = 8                  // g
    public static let gapBeforeSeparator: CGFloat = 15, gapAfterSeparator: CGFloat = 10    // m
    public static let footerHeight: CGFloat = 32, pillRadius: CGFloat = 8, pillPadding: CGFloat = 10 // m / g / g
    public static let moreButton: CGFloat = 32                                             // m
    public static let reloadRowHeight: CGFloat = 32, reloadGap: CGFloat = 11, globalOffHeight: CGFloat = 28 // o
    public static let maxHeight: CGFloat = 640, inUseDot: CGFloat = 6                      // o
    public static let shadowOpacity: Float = 0.25, shadowRadius: CGFloat = 12, shadowOffsetY: CGFloat = 4 // g
}
public enum SiteControlColors {            // macOS Dark measured (IS §20.15); Light = guess
    public static let fallbackTint = RGBA(hex: 0x49475A), fallbackBackdropWeight: [CGFloat] = [0.28, 0.28, 0.21]
    public static let actionFill = DesignColor(light: .black(0.06), dark: RGBA(hex: 0x232323))
    public static let actionHighlight = DesignColor(light: .white(0.6), dark: RGBA(hex: 0x575757))
    public static let actionHighlightHover = DesignColor(light: .white(0.4), dark: RGBA(hex: 0x484848))
    public static let glyph = DesignColor(light: .black(0.75), dark: .white(0.85))
    public static let label = DesignColor(light: .black(0.80), dark: RGBA(hex: 0xDBDBDF))
    public static let rowTitle = DesignColor(light: .black(0.85), dark: RGBA(hex: 0xDFDFE2))
    public static let rowSubtitle = DesignColor(light: .black(0.50), dark: RGBA(hex: 0x9F9EA9))
    public static let circleOn = DesignColor(light: RGBA(hex: 0x2B2A3C), dark: RGBA(hex: 0xECEDFF))
    public static let circleOnGlyph = DesignColor(light: .white(1), dark: RGBA(hex: 0x2B2A3C))
    public static let circleOff = DesignColor(light: .black(0.10), dark: .white(0.28))
    public static let tileFill = DesignColor(light: .black(0.05), dark: .white(0.08))
    public static let separator = DesignColor(light: .black(0.12), dark: .white(0.22))
    public static let pillFill = DesignColor(light: .black(0.04), dark: .white(0.05))
    public static let moreFill = DesignColor(light: .black(0.10), dark: .black(0.28))
    public static let hoverPlate = DesignColor(light: .black(0.05), dark: .white(0.06))
}
public enum BoostEditorMetrics {           // §4, editor-window points; AX S2 10/0030 unless noted
    public static let window = CGSize(width: 183, height: 588), codeWindow = CGSize(width: 480, height: 588)
    public static let cornerRadius: CGFloat = 12, topOffset: CGFloat = 160, screenMargin: CGFloat = 8   // m / m (one sample) / o
    public static let headerHeight: CGFloat = 40, inset: CGFloat = 18
    public static let done = CGRect(x: 0, y: 0, width: 40, height: 40), name = CGRect(x: 46, y: 8, width: 91, height: 24)
    public static let undo = CGRect(x: 143, y: 0, width: 40, height: 40)
    public static let ringFrame = CGRect(x: 18, y: 58, width: 147, height: 147), plate = CGRect(x: 25, y: 65, width: 133, height: 133)
    public static let ringRadius: CGFloat = 20, plateRadius: CGFloat = 13.5, padRadius: CGFloat = 66.5  // m / m / g (theme rule)
    public static let dotPitch: CGFloat = 4, dotSize: CGFloat = 1                                     // m
    public static let primaryDisc: CGFloat = 30, primaryDragDisc: CGFloat = 38, knobRing: CGFloat = 2  // m
    public static let secondaryDisc: CGFloat = 19, secondaryOffsetDegrees: CGFloat = 45               // m
    public static let defaultKnobAngle: CGFloat = 0, defaultKnobRadius: CGFloat = 40, guideWidth: CGFloat = 2  // m
    public static let colorButtons = [CGRect(x: 18, y: 220, width: 42, height: 38), CGRect(x: 70, y: 220, width: 43, height: 38),
                                      CGRect(x: 123, y: 220, width: 42, height: 38)]
    public static let buttonRadius: CGFloat = 9                                                         // g (visual)
    public static let fontCard = CGRect(x: 18, y: 273, width: 147, height: 120), fontCardRadius: CGFloat = 11  // m / g (visual)
    public static let fontColumns: [CGFloat] = [23, 51, 79, 106, 134], fontRows: [CGFloat] = [281, 307, 333, 359], fontCell: CGFloat = 26
    public static let size = CGRect(x: 18, y: 408, width: 70, height: 38), textCase = CGRect(x: 96, y: 408, width: 69, height: 38)
    public static let zap = CGRect(x: 18, y: 461, width: 147, height: 38), code = CGRect(x: 18, y: 514, width: 147, height: 38)
    public static let rowLabelInset: CGFloat = 15                                                       // m (visual)
    public static let advancedWindow = CGRect(x: -34, y: 258, width: 250, height: 232), advancedSlider = CGSize(width: 186, height: 16)
    public static let advancedLabelY: [CGFloat] = [299, 361, 423], advancedSliderY: [CGFloat] = [318, 380, 442]
    public static let codeHeader: CGFloat = 40, codeBottomBar: CGFloat = 70, codeButton: CGFloat = 38
    public static let back = CGRect(x: 10, y: 9, width: 60, height: 23), segment = CGSize(width: 50, height: 24)
    public static let codeMinimum = CGSize(width: 360, height: 420), gutterWidth: CGFloat = 36   // o
    public static let firstRunCardTop: CGFloat = 271, makeABoost = CGRect(x: 14, y: 493, width: 155, height: 38)
    public static let maybeLater = CGRect(x: 46, y: 541, width: 91, height: 31), firstRunIcon: CGFloat = 70  // m / BO-17 asset size
    public static let titleLineY: [CGFloat] = [331, 354, 377], waveTop: CGFloat = 463
    public static let bannerLine: CGFloat = 28, bannerTwoLines: CGFloat = 42                       // o (lead round 2)
}
public enum BoostEditorColors {            // light only; IS §20.15 and §20.6
    public static let header = RGBA(hex: 0xF5F5F7), hairline = RGBA(hex: 0xE9E9EB), background = RGBA(hex: 0xFDFDFF)
    public static let button = RGBA(hex: 0xEBEBED), buttonPressed = RGBA(hex: 0xDFDFE0), buttonOn = RGBA(hex: 0x333333)
    public static let advancedOn = RGBA(hex: 0x474747), label = RGBA(hex: 0x3A3A3B), title = RGBA(hex: 0x252526)
    public static let headerGlyph = RGBA(hex: 0xACACAD), chevron = RGBA(hex: 0x949495), disabledGlyph = RGBA(hex: 0xBDBDBF)
    public static let fontGlyph = RGBA(hex: 0x999999), fontSelected = RGBA(hex: 0xD9D9D9), fontSelectedGlyph = RGBA(hex: 0x8C8C8C)
    public static let plate = RGBA(hex: 0xFAFAFA), dot = RGBA.black(0.075), guide = RGBA.black(0.06)
    public static let secondaryOutline = RGBA(hex: 0xC8C2CA)
    public static let ringStops: [(degrees: CGFloat, color: UInt32)] = [(0, 0xEB4838), (30, 0xEB7636), (60, 0xF4BA49), (90, 0xD4FD58),
        (120, 0x90FC74), (150, 0x80FCAD), (180, 0x7CF8F1), (210, 0x356FF6), (240, 0x392EF4), (270, 0x8237F5), (300, 0xDD31BF), (330, 0xDF3470), (360, 0xEB4838)]
    public static let noColorKnobs = (primary: RGBA(hex: 0x717171), secondary: RGBA(hex: 0x333333))
    public static let warning = RGBA(hex: 0xFF5A5F)                                   // BO-22; banners
    public static let firstRunDim = RGBA.black(0.30), firstRunTitle = RGBA(hex: 0x3139FF), firstRunBody = RGBA(hex: 0x95939F)
    public static let makeABoost = (top: RGBA(hex: 0x4848FF), bottom: RGBA(hex: 0x333AFF)), firstRunFooter = RGBA(hex: 0xCEDBFC)
    public static let maybeLater = RGBA(hex: 0x7F819E)
    public static let zapFrame = RGBA(hex: 0x3139FF), zapBar = RGBA(hex: 0xFBFBFD)
}
extension Motion {
    public static let popoverOpen = SpringToken(response: 0.20, dampingFraction: 0.8)   // m (overshoot) / g (curve)
    public static let popoverOpenFade: CFTimeInterval = 0.08, popoverClose: CFTimeInterval = 0.19   // g / m (theme popover)
    public static let knobRelease = SpringToken(response: 0.2, dampingFraction: 0.9)    // g
}
extension Typography {
    public static let siteControlLabel = FontToken(13, .semibold), siteControlRowTitle = FontToken(13, .semibold)
    public static let siteControlRowSubtitle = FontToken(12, .regular), siteControlPill = FontToken(13, .medium)
    public static let editorName = FontToken(15, .medium), editorButton = FontToken(15, .medium), editorSlider = FontToken(13, .regular)
}
```

Removed from the first version: the 320 width, header, tile, switch, and edit-button metrics; the
hue-ring wheel (128 / 18 / 46 / puck 24), font strip, tool tiles, accent colors, and every dark
editor color.

## Appendix B — Strings (Arc label → Open text)

Arc labels kept verbatim (no brand): "Settings", "More", "Boosts", "Manage", "Extensions",
"Block Ads & Trackers", "On", "Off", "Allowed", "Blocked", "Enabled", "Disabled", "Secure",
"Insecure", "Share", "New Boost", "Capture a portion of this page", "Capture the full page",
"Clear Cache", "Clear Cookies", "Manage Boosts…", "New Boost…", "Manage Extensions…",
"Add Extension…", "Add Extension", "All Site Settings…", "Pin", "Unpin", "My Boost", "Done",
"Undo", "Rename this Boost…", "Rename this Boost", "Cancel", "Shuffle", "Reset all Edits",
"Delete this Boost", "Delete this Boost?", "This can't be undone.", "Delete", "All Boosts…",
"Invert lightness", "Advanced color controls", "Reset to original colors", "Contrast",
"Brightness", "Original Saturation", "Change text size", "Change text case", "Size", "Case", "Zap",
"Code", "Back", "CSS", "JS", "Click elements on the page to Zap them", "Zap this",
"Zap all related elements", "Click to reveal", "Pick Selector", "Hide Selector Picker",
"Refresh to Run", "Refresh this Page", "Show Developer Tools", "Hide Developer Tools",
"your css here", "your javascript here", "Edit the Internet with Boosts", "Make <host> your own!",
"Make a Boost", "Maybe Later", "Nothing Boosted Yet!", "Made for".

Rewritten in Open's words: the three ad-block tooltips (§3.8), the reload row, the Boosts-off note,
the banners (§4.3), the neutral-page and legacy notes (§4.4.5), the Reset confirmation, "Apply to",
the private-window tooltip, the Library empty-state body. Dropped: "Copy URL" and "Capture in
Portrait Mode" from the action row, "Make your own!" (the 1.170 card says "Make a Boost"), Arc's JS
sharing banner, and "Report Boost…".

## Appendix C — Lead decisions

### 2026-10-25 (approval of the first version)

| Decision | Status after 2026-10-26 |
|---|---|
| Approved as the Site Control Center and Boost editor plan. | Kept; revised by this entry. |
| Q1 The panel is an in-window view, not a system popover (Arc's look, window stays key). | Kept (D-3 amended: arrow, material). |
| Q2 Developer Mode row hidden until `page-platform.md` defines Developer Mode. | Kept (Q14 notes Arc shows it). |
| Q3 Preview row hidden until Previews stores per-site state. | Kept. |
| Q4 Colors use CSS filters only in v1; tint later behind a scroll-performance check. | Kept; Q12 adds the capture evidence. |
| Q5 The ad-block row shows On/Off only. | Kept. |
| Q6 Boost editing is disabled in private windows. | Kept. |
| Q7 A "Reload" row after a setting change; never reload automatically. | Kept. |
| Q8 Holding Option does nothing in v1. | Kept for the panel; ⌥-click on the button does not open the panel (§3.10). |
| Q9 Ad-block paths: `AdBlockStore`'s path is the one path. | Kept. |
| Q10 The Zap list lives in the editor. | **Superseded**: the list lives in the page bar ("Click to reveal"); the editor shows the count (D-8). |
| Q11 Cmd+E is decided in `extensions-ui.md`. | Kept. |
| Engine needs E1–E6 go into the engine lead's queue after P2. | Kept. |
| Captures #21 and #22 go into the user's combined capture session. | Done (capture session 2, items 9–11). |

### 2026-10-26 (recorded on the PR branches #69, #96, #103 during review)

| Decision | Status |
|---|---|
| A (#69): no pointer; panel at the sidebar edge + 13 pt; anchor y 24 (`anchorAlignmentY`); F0137 as reference. | **Superseded** (C1): top arrow, drops from the URL field, centered on the button (§3.1). |
| B (#69): pane anchor `y = anchorMaxY + 11`, right-aligned, no pointer. | **Superseded**: arrow, centered on the button (guess, §3.1). |
| C (#69): corner radius 16, continuous; hover plates continuous. | Kept. |
| Action buttons top-aligned (`actionButtonInsetY = 0`). | **Superseded**: 10 pt top padding (S2 09/0010). |
| Open scale around the panel's top-leading corner. | **Superseded**: around the arrow tip, spring with overshoot (§3.11). |
| Security label only for `https` / `http`; other schemes hide it and its AX element. | Kept. |
| Host hidden from visible text in AX; the panel description exposes it once. | Kept (now the only host exposure). |
| Token-based observers per window; Escape restores the first responder; outside clicks of every button dismiss and forward. | Kept. |
| Extension picker fallback: focus only ⋯, Return opens the menu with "Add Extension…" highlighted. | **Superseded**: focus the "+" tile; Return runs `add-extension` (§3.6.1). |
| Round 2: long Setting tile titles wrap to two lines. | **Superseded**: rows, one line, tail "…" (S2 09/0010). |
| Round 2: reload and global-off baselines at row top + 20; focus rings for keyboard focus only; one continuous path for fill, edge, clip, and shadow. | Kept (the path now includes the arrow; there is no edge stroke). |
| Round 2: "geometry and palette remain guesses until capture session 2; F0137 supplies geometry only". | **Superseded** by the measured values in §3–§4. |
| Scope labels "<host> and subdomains" (2026-10-25 23:46); IP scope items (03:37); saved path always offered (09:26). | Kept; the scope moves into the name menu ("Apply to ▸"). |
| Legacy filters stay until the first color edit (03:21). | Kept (note placement amended, §4.4.5). |
| Few-colors hint "Few colors here. Try Invert lightness." on one centered line (09:32). | Kept; geometry amended (two lines inside the plate). |
| Zap / Code tooltips "Zap isn't available yet." / "Code editing isn't available yet." (09:32). | Kept. |
| Font strip of 56 pt chips, 6 pt gaps, scrolling in a 232 pt viewport (10:00). | **Superseded** (C6): 5 × 4 grid of 26 pt cells (§4.6). |
| Editor round 2: shadow padding 30 / 24 / 36; body 12 pt from the web content's top-right. | **Superseded**: system shadow; placement on the window's right edge (§4.2). |
| Editor round 2: header name and scope at x 40; header glyph alpha 0.9. | **Superseded**: Done / name ⌄ / Undo header (§4.3). |
| Editor round 2: dark first-run colors. | **Superseded**: the editor is always light (D-4). |
| Editor round 2: banners 14 pt insets, 7 pt padding, 11 pt Medium, 28 / 42 pt. | Kept. |
| Editor round 2: sliders at x 124, width 130; dark track white 0.12. | **Superseded** (C9): sliders 186 × 16 in the advanced popover. |
| Editor round 2: keyboard/AX repeats coalesce for 1 s; owner tokens; `saveNow` on close and delete; startup removes only abandoned temp files. | Kept. |
| Text case label "Original". | **Superseded**: fixed labels "Size" and "Case"; values in AX (§4.7). |
| Timing budgets may fail under heavy machine load in review; rerun before merge. | Kept. |

### 2026-10-26 — capture session 2 supersessions (this revision)

The lead instructed that the Site Control Center and Boost editor follow Arc as captured in session
2 (items 9–11). Effective with the merge of this revision:

1. Superseded, with the replacement in this plan: decision A and B (anchor, pointer, gaps), the
   top-aligned action row, the top-leading open scale, the 320 pt width, the header, the six-button
   action row, the opaque fill, D-11 (section order and tiles), SC-16's conditional "New Boost…",
   the two-line tile titles, the "focus ⋯" picker fallback, the hidden Extensions section, Q10 (Zap
   list in the editor), the 268 pt editor panel inside the content and its shadow padding, the
   editor header and dark variants, the hue-ring wheel with a disc pad and puck, the inline advanced
   sliders, the font strip, the four colored tool tiles, the "Original" case label, and the default
   code window size 560 × 640.
2. Kept: decision C, Q1–Q9 and Q11, D-1, D-2, D-5, D-6, D-9, D-10, the security-scheme rule, the
   observer and dismissal decisions, scope labels and IP rules, legacy filters, the Zap / Code
   tooltips, banners, coalescing, `saveNow`, and the review timing exception.
3. Amended: D-3 (in-window view with arrow and material), D-4 (light, placement, system shadow),
   D-7 (pad law), D-8 (Zap UI and list placement). New: D-12 (shared pad core).
4. Open for the lead: Q12 (color runtime), Q13 (ad-block row with the master off), Q14 (Developer
   Mode row), Q15 (sparkle animation).
5. Migration: rework #69, #96, and #103 in place in that order (§12).
