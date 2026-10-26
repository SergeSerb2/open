# Site Control Center and Boost editor — implementation plan for Open

Status: plan (2026-10-25). Implementer: a coding agent with no other context. Follow this file
top to bottom. Where it says "Open choice", the choice is final for v1 unless a lead decision in
the appendix changes it. Where it says "guess", build the stated value and keep the value in one
token so a later capture changes one line.

Read first, in this order: `AGENTS.md`; `docs/architecture.md`; `docs/re/features-advanced.md`
§4 (Boosts), §5 (Zap), §6 (Site Control Center), §7 (ad blocking) — §4.7 and §6.5 hold the new
findings this plan uses; `docs/boosts.md`; `docs/plans/boosts-zap.md` §0.2, §3, §8–§9 and Appendix
C; `docs/adblock-lists.md`; `docs/plans/adblock-fork.md` §12; `docs/plans/app-shell.md` §2,
§4.5, §4.6, §4.9, §6; `docs/plans/settings-library.md` §2 and §5.5; `docs/engine-api.md`;
`docs/automation.md`; `docs/design.md` §2 and §7.

User-visible names: never "Arc". "Import from Arc" is the only exception. Arc strings quoted in
this plan are facts used for parity; any that name Arc are rewritten in Open's own words.

## Goal

Ship the two Boost and site surfaces that `docs/plans/boosts-zap.md` §0.2 left out:

1. **Site Control Center** — the per-site panel that opens from the URL field (and from a split
   pane's bar). It shows site settings (permissions and content blocking), the Boosts that match
   the site, the window's extensions, page actions (Share, Copy URL, Capture ×3, New Boost), the
   connection security state, and a "⋯" menu (clear cookies or cache, manage Boosts and
   extensions, all site settings).
2. **Boost editor** — a floating editor panel for one Boost on the current site: color wheel,
   invert lightness, advanced color sliders, fonts, text size, text case, Zap entry and the list
   of Zaps, CSS and JS code panels, rename, delete, shuffle, undo and redo, per-site scope, live
   preview on every matching tab. Plus a **Boosts list** in the Library for all Boosts of a Profile.

Both surfaces only edit data that already has an owner: `BoostStore` (OpenBoosts),
`AdBlockStore` (OpenAdBlock), Chromium content settings (through `OpenWeb.WebProfile`), and the
engine extension state. This plan adds no second store for any of those values (§5).

## Success criteria

1. Clicking the URL field's Site Controls button opens the panel in ≤ 1 frame of main-thread work
   (< 8 ms from click to first draw, release, M5 Pro). Esc, a click outside, or a second click on
   the button closes it. Idle CPU stays at zero while it is open.
2. Every control in §3 writes exactly the store in §5 and the live effect happens at once: a
   permission tile changes the Chromium content setting; the ad-block tile changes the Profile's
   `exclusions.json` and the engine exclusion set; a Boost switch changes `isEnabled` and the page
   re-renders without a reload (CSS components) within 100 ms.
3. "New Boost" from the panel creates a Boost for the site and opens the editor. Each editor control
   changes the live page within one frame of input for the active tab (drag) and within 150 ms for
   other matching tabs. Closing the editor on an unchanged new Boost deletes it.
4. Zap mode starts from the editor, picks elements on the live page with the existing picker, lists
   them in the editor, and exits on Esc, Done, the editor toggle, editor close, tab switch, or
   navigation. No Zap message is accepted without the native session capability (`docs/boosts.md`).
5. The CSS panel applies live as the user types. The JS panel shows "Refresh to Run" until the page
   reloads with the new JS. Both editors are native AppKit text views with syntax colors, line
   numbers, and no third-party dependency.
6. Keyboard: every control is reachable with Tab; the panel and the editor have the key handling in
   §3.9 and §4.10. VoiceOver reads every tile, row, switch, and button with a label and a value.
7. `sitecontrol-render check` (new, `commandbar-render` style) passes: flows, a render of every
   state at 1x and 2x, and the budgets in §7. It runs in `tools/verify-all.sh`.
8. Two new automation suites in `tools/e2e/engine_e2e.py` — `sitecontrol` and `boosteditor` — pass
   on the real app once the app-shell hooks exist (§8.2).
9. No unit tests (`AGENTS.md` rule 6). No Arc asset in the repo (`AGENTS.md` rule 1).

## Non-goals

- Boost sharing, install links, the online Boost Gallery, "Report Boost", preview images, Boost
  authors (BO-6; accounts are out of v1 scope). `boost-gallery` stays disabled.
- Arc's palette-remap color engine (`colorWheelDriven` / `themeDriven` schemes with curves). Open
  keeps the existing CSS-filter runtime (`ColorAdjustment`, lead decision Q7 in
  `docs/plans/boosts-zap.md`). The analogous / complementary secondary hue has no filter
  equivalent and is not built (§4.4, open question Q4).
- A certificate viewer of our own. The security button opens the system certificate panel once the
  engine reports the chain (E3). Until then it shows the state only.
- A cookie browser or a site-data size display (SC-8: no evidence in Arc).
- The per-site Developer Mode tool bar and the per-site Preview toggle. Their rows are hidden in v1
  (§3.4, Q2, Q3).
- Monaco or any web-based code editor. Fonts beyond the macOS system set.
- Peek and Little Open entry points. The panel is unavailable in a Peek and in Little Open (§3.1).

---

## 0. Locked decisions

| # | Decision | Why / evidence |
|---|---|---|
| D-1 | New SwiftPM library target `OpenSiteControl` in `Packages/OpenKit`. It holds the Site Control Center view and controller, the Boost editor views and session, and the code editor. It depends on `OpenModel`, `OpenDesign`, `OpenBoosts`, `OpenAdBlock` (only for `AdBlockSites` registrable domains), `OpenWeb`, and — once it lands — `OpenExtensionsUI` (§3.6) only. The Library Boosts list is a SwiftUI section in `OpenSettings` (§4.11), because the Library window is SwiftUI (settings plan D-2). It never imports `OpenEngine` or CEF. | `docs/architecture.md`: packages never import the engine. One target keeps shared parts (tiles, rows, switches) in one place. |
| D-2 | `OpenSiteControl` uses AppKit views only. No SwiftUI. Layer-backed, drawn with `OpenDesign` tokens. | The panel opens on a click on the hot path and must hit < 8 ms. `AGENTS.md`: SwiftUI only where cheap. The Library section (§4.11) follows the Library window's SwiftUI rule instead. |
| D-3 | The Site Control Center is an in-window overlay view (like the command bar overlay in `OpenCommandBar`), not an `NSPopover` and not a separate window. | Arc uses an `NSPopover` (`onPopoverClose`, SC-9). On macOS 26 a system popover draws Liquid Glass; `AGENTS.md` says keep Arc's look. An in-window overlay also keeps the browser window key, so the sidebar never flips to its inactive tones (`docs/design.md` §5.3). The command bar already proves an overlay above CEF content works. |
| D-4 | The Boost editor is a child `NSPanel` of the browser window: `.borderless`, `.nonactivatingPanel`, `becomesKeyOnlyIfNeeded = true`. It becomes key only for text input (rename field, code editors). | Arc's editor is a window (`BoostsEditorWindowController`, `BoostsEditorWindowContent`, `codeEditingWindowSize`, BO-14). `becomesKeyOnlyIfNeeded` keeps the browser window active while the user drags the wheel or clicks tools. |
| D-5 | Data owners do not change. Permissions: `WebProfile.permission(_:origin:)` / `setPermission(_:for:origin:)` (OpenWeb, exists). Ad blocking: `AdBlockStore.setExcluded(_:excluded:profile:)` and `siteSnapshot(for:)` (exists). Boosts: `BoostStore` (exists). Global Boosts switch: `UserDefaults` `open.advanced.enableBoosts` (settings plan §2.1 A-5). The panel and the editor never write files themselves. | `docs/plans/settings-library.md` D-5: no second store for one value. |
| D-6 | Live preview goes through the App's `BoostEngineAdapter` (`docs/plans/app-shell.md` §4.5): store mutation → matcher rebuild → `BoostInjectionPlanner.plan` → `boost:apply` to each live page whose URL matches. During a drag, only the editor's own page gets frames (≤ 60 Hz); the store and other pages get the value on drag end. | BO-8 (apply on edit), BO-13 (live preview), Arc state `boostDataBeforeInteractiveUpdates` / `_interactivelyUpdating` (BO-14, BO-15). |
| D-7 | Color wheel → `ColorAdjustment` math is fixed in §4.4 and lives in one function in OpenBoosts (`BoostColorWheel.adjustment`). The editor's inputs are stored in a new optional field `Boost.colorWheel`; `colorAdjustment` stays the runtime value and is always derived from `colorWheel` when `colorWheel` is set. | `docs/plans/boosts-zap.md` Q7 left the conversion to this plan. One derivation function, one writer (§5.2). |
| D-8 | Zap keeps the existing in-page picker (`zap-picker.js`, closed shadow overlay, its bottom bar). The editor adds the native Zap toggle and the list of Zaps. No native page overlay. | The picker is built and verified 26/26 (`docs/boosts.md`). Arc draws hover rects natively (`BoostsEditorOverlayController`, BO-13, BO-14); Open's in-page overlay already covers that need. |
| D-9 | Code editors are `NSTextView` with a small regex highlighter and an `NSRulerView` gutter. No dependency. | Arc ships a native text-view path next to Monaco: placeholder strings "your css here" / "your javascript here" drawn at 12 pt, black 30 % (`placeholderAttributedString`, BO-19). Monaco is a web page per editor (memory, cold start) and a large dependency. |
| D-10 | Boost editing and creation are disabled in incognito windows. Existing Boosts still apply there (boosts plan Q4 default). | Arc refuses Boost install in Incognito ("Open this link outside Incognito Mode to install this Boost", BO-10). Editing in incognito would write a site visit into the persistent Profile store. Lead question Q6 confirms. |
| D-11 | The panel shows Arc's sections in Arc's order: header, actions, Settings, Boosts, Extensions, footer. Labels are Arc's decoded labels (§2, Appendix B). Layout values are Open choices or guesses until a capture exists (§11.1 R-1). | No capture of the panel exists (`docs/re/interaction-states.md` §2, "Only its tooltip"). Labels and structure are proven by strings and decompiled constants (SC-9 to SC-16). |

## 1. Current state (verified 2026-10-25 on `origin/main` c95be65, after M5 #51 and #56; re-verify before you edit)

Run `git log --oneline -3` and read each file below before you change its area.

| Area | State | Evidence |
|---|---|---|
| URL field button | Exists, sends `.showSiteControls`. Frame `[W − 42, 49, 30, 30]` in sidebar space, glyph `slider.horizontal.2.square` 18 pt, tooltip "Site Controls". Shown only while a page is loaded and the pointer is over the sidebar. | `Packages/OpenKit/Sources/OpenSidebar/ChromeViews.swift` `URLFieldView`; `OpenDesign/Metrics.swift` `URLFieldMetrics.siteControlsTrailing = 12`. |
| Pane bar button | Exists in `PaneChromeView` (button index 4, "Site Control Center", frame `[w − 105, 2, 32, 28]`) and is always disabled. | `Packages/OpenKit/Sources/OpenFeatures/PaneChromeView.swift`. |
| Intents | `.showSiteControls` and `.customizePage(tabID:)` exist in `SidebarIntent`. Neither `OpenFeatures.BrowserWindowController` nor `ModelSidebarActions` handles them today: they fall through and return `false`. | `OpenSidebar/SidebarIntent.swift`; `OpenFeatures/BrowserWindowController.swift` (the `default:` branch). |
| Commands | `new-boost`, `edit-boost`, `new-legacy-boost`, `boost-gallery` (File), `view-boosts` (Window) exist with no handler. "Customize Page…" exists in the pinned-tab menu. | `OpenCommands/CommandRegistry.swift`; `OpenSidebar/SidebarMenus.swift`; `docs/re/interaction-states.md` §15. |
| OpenBoosts | `Boost`, `SiteMatch`, `ColorAdjustment`, `ZappedElement`, `BoostStore(root:profileID:fileURL:)`, `BoostMatcher`, `BoostInjectionPlanner`, `BoostPickerCoordinator`, `BridgeDecode`, `BoostResources`. No `colorWheel` field yet. Text zoom clamps 0.5–2; transforms none/uppercase/lowercase/capitalize. | `Packages/OpenKit/Sources/OpenBoosts/*.swift`, `docs/boosts.md`. |
| Zap picker | In-page bar "Zap mode · Zap all related (N) · Undo · Done", Esc exits, Cmd/Ctrl+Z undoes. Click commits a Zap. No "select only" mode. | `OpenBoosts/Resources/zap-picker.js` lines ~246–366. |
| OpenAdBlock | `AdBlockStore` (`@MainActor`): `isEnabled` (global, `<root>/adblock-settings.json` `nativeAdBlockEnabled`), `setExcluded(_:excluded:profile:)` writes `<root>/Profiles/<profile UUID>/adblock/exclusions.json` and emits `AdBlockEngineEvent.exclusions`, `siteSnapshot(for:).isAllowlisted(host:)`. Registrable-domain scope via the bundled public suffix list. | `Packages/OpenKit/Sources/OpenAdBlock/AdBlockStore.swift`, `SiteRules.swift`; `docs/adblock-lists.md`. |
| OpenWeb | `WebProfile.permission(_:origin:)`, `setPermission(_:for:origin:)` for 12 `SitePermission` kinds with `ask/allow/block`. `WebContent.snapshotPNG()`, `evaluateJavaScript` (main world). | `Packages/OpenKit/Sources/OpenWeb/OpenWeb.swift`. |
| Engine | `OEBrowserContext.permissionState/setPermissionState` (12 kinds → Chromium content settings), `clearBrowsingData(origin:completion:)` (cookies for one origin and the HTTP cache of all sites), user scripts (main world only, P7), `OEWebContent.showDevTools()`, `takeSnapshot()`, `isCapturingCamera/Microphone`, `OEExtensionManager.installedExtensions`, `OEBrowser.extensionActions` (manifest defaults until P2). No security state. No per-origin cache clear. No "changed settings" query. No extension pin API. | `Engine/OpenEngine/include/OpenEngine/OEBrowserContext.h`, `OEWebContent.h`; `docs/engine-api.md`. |
| App wiring | None for this feature. `app-shell.md` §4.5 (Boost adapter), §4.6 (ad-block adapter), §4.9 (an interim `NSPopover` with rows) and Step D/F own the hooks. This plan (§3, §6.4) replaces the §4.9 interim popover. | `docs/plans/app-shell.md`. |
| Settings / Library | `OpenSettings` exists (M5, #51): SwiftUI Settings and Library windows. `LibrarySection` = `archive, downloads, captures, media, history`; section files sit at `Sources/OpenSettings/*Section.swift`; data comes through snapshot providers (`DownloadsProvider`, `CapturesProvider`) and `LibraryActions`. `SettingsDefaults.values` registers `open.advanced.enableBoosts = true`; the Advanced pane shows the tile "Enable Boosts on websites you visit". No App code reads the key yet. The ad-block allowlist (`AdBlockSettingsModel.setExcluded`) calls `AdBlockStore.setExcluded` and then `SettingsActions.setAdBlockExcludedDomains(_:profileID:)`. `settings-preview` runs in `tools/verify-all.sh`. | `Packages/OpenKit/Sources/OpenSettings/LibraryTypes.swift`, `SettingsTypes.swift`, `AdvancedPane.swift`, `AdBlockSettingsModel.swift`. |
| Harness | `features-render`, `commandbar-render`, `sidebar-render` exist; `commandbar-render check` runs in `tools/verify-all.sh`. | `Packages/OpenKit/Package.swift`, `tools/verify-all.sh` `NAMES`. |

Path note (not this plan's to fix): `ProfileDirectories.adBlockListsDirectory` builds
`Profiles/<dataDirectoryName>/AdBlock/lists`, while `AdBlockStore` uses `Profiles/<UUID>/adblock/`.
The Site Control Center only calls `AdBlockStore`, so it is not affected. Report it to the
ad-block owner (Q9).

---

## 2. Arc facts this plan builds on (summary; full evidence in `docs/re/features-advanced.md`)

| ID | Fact | Used in |
|---|---|---|
| SC-9 | The panel is an `NSPopover` hosting SwiftUI; its controller tracks an Option-key state and an extension-picker key monitor. | D-3, §3.9 |
| SC-10 | Sections and labels: section titles "Settings", "Boosts", "Extensions"; on hover each header shows an accessory text: "More" (Settings), "Manage" (Boosts, Extensions); clicking the header runs that action. | §3.3–§3.6 |
| SC-11 | Setting rows are an enum `contentSettings(type)`, `sidebarPreview`, `developerMode`, `contentBlocking`, `popupBlocking` with titles "Block Ads & Trackers", "Preview", "Developer Mode", "Block Pop-ups". Subtitles: content settings "Allowed" (Chromium ALLOW or SESSION_ONLY) or "Blocked" (anything else); content blocking "On" (enabled) or "Off" (disabled or unavailable); developer mode "On"/"Off"; preview "Enabled"/"Disabled". Pop-up blocking logs "not supported" and returns no subtitle. Ad-block tooltips: "The built-in ad blocker is turned on for this site." / "…is disabled for this site." / "…is off. You can change this in Settings." | §3.4 |
| SC-12 | Arc reads the site's changed content settings (`getChangedContentSettingsForOrigin:`), not every kind. Content-setting display names come from one table (camera, microphone, location, notifications, javascript, images, popups, intrusive ads, background sync, sound, MIDI devices, clipboard, usb, hid, serial port, fonts, bluetooth, hand tracking, idle detection, keyboard lock, pointer lock, local network, …). | §3.4, E1 |
| SC-13 | Boost rows: subtitle "Enabled"/"Disabled", a toggle and an edit action. | §3.5 |
| SC-14 | Extensions: buttons with click, right-click, and a pin button whose tooltip is "Pin"/"Unpin"; an "Add Extension" button. | §3.6, E4 |
| SC-15 | Action buttons in enum order: Share, Copy URL, New Boost, Capture ("Capture a portion of this page"), Capture Full Page ("Capture the full page"), Capture in Portrait Mode. Each can carry a keyboard shortcut. | §3.2 |
| SC-16 | Footer: a security button titled "Secure" / "Insecure", and a menu: Clear Cache · Clear Cookies · — · Manage Boosts… · New Boost… (only when Boosts are not shown as a section) · — · Manage Extensions… · Add Extension… · — · All Site Settings…. | §3.7 |
| BO-14 | Editor window with two modalities (`none`, `code`), a remembered code-editing window size, an interstitial, an overlay, and a shelf. | D-4, §4 |
| BO-15 | Editor actions include `undo`, `redo`, `shuffle`, `resetAll`, `resetColorMapping`, `rename`, `delete`, `showSelectorPicker`, `copySelectorToPasteboard`, `toggleDevTools`, `reloadPage`, `editCSS`, `editJS`. A change stack holds before/after pairs. | §4.6, §4.7 |
| BO-16 | Menu items: "Undo", "Rename this Boost…", "Shuffle", "Delete this Boost", "Report Boost…" (Arc only), "Reset all Edits", "All Boosts…". Rename alert buttons "Done"/"Cancel"; delete alert "Delete this Boost?" with "Delete". Default name "My Boost". | §4.7 |
| BO-17 | Color controls: a hue ring (asset 256 px @2x = 128 pt), "Invert lightness" (lightbulb), "Advanced color controls" (`slider.horizontal.3`) with "Brightness", "Contrast", "Original Saturation", "Reset to original colors" (`arrow.counterclockwise`), scheme icons for analogous and complementary. | §4.4 |
| BO-18 | Text controls: "Change text size" with options small, normal, medium, large, larger; "Change text case" with capitalize, uppercase, lowercase. A font picker of font options. A macOS font list sits beside the Boost strings (Helvetica Neue … Wingdings; guess on ownership). | §4.5 |
| BO-19 | Code mode: "your css here" / "your javascript here" placeholders, 12 pt, black 30 %; buttons "Pick Selector" / "Hide Selector Picker", "Refresh to Run" (tooltip "Refresh this Page"), "Show Developer Tools" / "Hide Developer Tools". | §4.8 |
| BO-20 | Zap UI: "Click elements on the page to Zap them", "Zap this", "Zap all related elements", "Copy selector for this", "Copy selector for related". Shelf of Zap tiles; hovering a tile previews it (`zapToPreview`). Preview color `ZapPreviewBackground #D9D9D9`. | §4.6 |
| BO-21 | First-run interstitial: "Edit the Internet with Boosts", button "Make your own!". Dismissal stored (`hasDismissedBoostsInterstitial`). | §4.9 |
| BO-22 | Editor colors (BoostsEditor bundle): segmented background black 7 % / white 10 %, selection white / white 30 %, slider track `#3B3746` 5 %, slider tint `#017AFF`, warning `#FF5A5F`, puck `#FAFBFF`, label white / black 80 %, interstitial `#2E2740` on `#CEDBFC`, accents Blue `#300EFF`, Green `#55B948` (P3), Magenta `#DD0EFF`, Orange `#FF560E`, Pink `#FF0E82`, Purple `#860EFF`, Red `#FF0E0E`, Yellow `#F1A23C` (P3). | §3.8, §4.3 |

---

## 3. Site Control Center — design spec

All frames are points, origin at the panel's top-left, y down. "guess" marks a value with no
capture behind it. Put every number below in `OpenDesign/SiteControlTokens.swift` (§6.1), never
inline.

### 3.1 Entry points and anchoring

| Entry | Anchor | Edge |
|---|---|---|
| Sidebar URL field button (`.showSiteControls`) | The button frame `[W − 42, 49, 30, 30]` (sidebar space) | Panel opens 13 pt right of the sidebar edge, without a pointer (lead decision A, 2026-10-26 review of PR #69; supplied capture F0137). |
| Floating sidebar card (hover-reveal) | The card's URL field button | Same as above, relative to the card. |
| Split pane bar button (`PaneChromeView` index 4, enable it) | The button frame in the pane bar | Panel opens below the bar, right-aligned to the button, without a pointer. |

- The panel always describes the tab of its anchor: the selected tab, or the focused split pane
  (SV-8). Opening it from an unfocused pane's bar is impossible (the unfocused bar hides the
  button, F0081).
- Not available: no page loaded (button hidden today), a Peek (no URL field; guess, SC-1), Little
  Open (no button in its toolbar; Open choice), `chrome://` and `open://` internal pages show only
  header, actions (Copy URL, Share) and footer (Open choice; Boosts cannot match them because
  `BoostMatcher` needs an http(s) host).
- Geometry (lead decisions A/B, 2026-10-26 review of PR #69): no arrow. For the sidebar
  anchor: `x = sidebarMaxX + 13`, `y = clamp(anchorMidY − 24, 8, H − panelHeight − 8)`.
  At the standard anchor this is y 40; the title baseline is y 69, aligned with the URL host.
  The supplied reference capture F0137 has no visible arrow and a 13 pt sidebar gap.
  For the pane anchor: `y = anchorMaxY + 11`, panel right edge = anchor right edge + 8,
  clamped inside the window with 8 pt margins.
- One panel per window. Opening it again on the same anchor closes it (toggle). Opening from
  another anchor moves it.

### 3.2 Panel chrome, header, and action row

| Part | Value | Source |
|---|---|---|
| Width | 320 | guess (Arc's theme popover content is 356, `interaction-states.md` §14) |
| Max height | `min(windowContentHeight − 16, 640)`; content scrolls inside (overlay scroller) | Open choice |
| Corner radius | 16, continuous (`.continuous`); hover plates also use continuous corners | Lead decision C, 2026-10-26 review of PR #69 |
| Fill | `Core.popoverBackground` (light `#FAFBFF`, dark `#151C30`, P3) | Arc's own popover token name (`ARCClients_BaseAssets`); its use here is a guess |
| Edge | 1 px `CommandBarColors.hairlineDivider` (black 10 % / white 10 %) inside the edge | guess |
| Shadow | black 0.25, radius 16, y offset 6 | guess (smaller than the command bar's σ 48) |
| Appearance | Follows the macOS appearance (`NSApp.effectiveAppearance`), not the Space's content appearance | Open choice: system popovers follow the system |
| Header | Height 48. Favicon 16×16 at `[14, 16]` (fallback `Glyph.globe`, 14 pt Regular, `Core.foregroundSecondary`). Title = human-readable host (host without a leading `www.`; TopDomains display name when it exists, TD-1) in a frame at x 36 (ink starts at 38), 14 pt Semibold (`Typography.siteControlTitle`), `Core.foregroundPrimary`, baseline 29, tail truncation | SC-9 `humanReadableHost`, TD-1 |
| Action row | y 48, height 44. Buttons are top-aligned (`actionButtonInsetY = 0`, lead decision 2026-10-26). Six buttons 44×36, gap 4, centered (284 pt wide). Radius 8. Rest fill clear; hover `SidebarColors.itemBackground`; pressed `SidebarColors.itemHoveredBackground`. Glyph 18 pt Regular template, `Core.foregroundSecondary`; multiply its resolved alpha by 0.3 when disabled. Tooltip = Arc label + shortcut keycaps (shared capsule and presenter in `OpenDesign/TooltipView.swift`). | SC-15 |
| Separator | 1 px `CommandBarColors.hairlineDivider`, inset 12 left and right, after the action row and between sections. Stroke center = separator y + half a device pixel (first separator: `92 + px/2`). | guess; pixel snapping per PR #69 lead review |

Action buttons (enum order, SC-15). Each runs an existing command id so menus, keys, and the panel
share one implementation (`docs/commands.md`):

| # | Tooltip | Glyph (Open's own) | Runs | Enabled when |
|---|---|---|---|---|
| 1 | Share | `square.and.arrow.up` | `share-page` (system share picker anchored to the button) | page loaded |
| 2 | Copy URL (⇧⌘C) | `link` | `copy-url` (existing toast "Copied Current URL") | always |
| 3 | New Boost | `paintbrush.pointed` | §3.5 "New Boost" flow | http(s) page, not incognito, `open.advanced.enableBoosts` |
| 4 | Capture a portion of this page (⇧⌘2) | `viewfinder` | `capture-page` | command enabled |
| 5 | Capture the full page | `doc.viewfinder` | `capture-full-page` | command enabled |
| 6 | Capture in Portrait Mode | `rectangle.portrait` | `capture-portrait` | command enabled |

Disabled buttons draw at 30 % alpha and do not show a hover fill. A button action closes the panel
first, then runs the command (Open choice: the share picker and capture overlay must not sit under
the panel).

### 3.3 Sections (shared shape)

| Part | Value |
|---|---|
| Section header | Height 28. Title at x 14, 12 pt Semibold, `Core.foregroundSecondary`. Hover over the header row shows the accessory text right-aligned at `W − 14`: 12 pt Medium, `Core.brandBlue`, followed by `chevron.right` 9 pt. The accessory fades in over `Motion.hoverFade` (0.08 s). Click anywhere on the header runs the header action. |
| Section body | Starts 2 pt below the header. Bottom padding 10. |
| Order | Settings, Boosts, Extensions (D-11). A section with no rows is hidden, except Settings, which always has the ad-block tile on http(s) pages. |

| Section | Title | Hover accessory | Header action |
|---|---|---|---|
| Settings | "Settings" | "More" | All Site Settings (§3.7 menu item 10) |
| Boosts | "Boosts" | "Manage" | `view-boosts` → Library Boosts list (§4.11) |
| Extensions | "Extensions" | "Manage" | `manage-extensions` (§3.7 menu item 7) |

### 3.4 Settings section (tiles)

Tile grid: 2 columns, tile 142×48, column gap 8, row gap 8, grid inset 14 (2 × 142 + 8 = 292 =
320 − 2 × 14). Radius 10. Tile fill `SidebarColors.itemBackground` (black 5 % / white 10 %), hover
`SidebarColors.itemHoveredBackground`. Icon circle 28 at `[10, 10]`: on state `Core.brandBlue` with
a white 14 pt glyph; off state `GrayScale.a(4)` with a `Core.foregroundSecondary` glyph. Title at x
46, 12 pt Semibold, baseline 21. Subtitle at x 46, 11 pt Regular, `Core.foregroundSecondary`,
baseline 36. Both truncate at the tile's right edge − 8. All values guess except the labels (SC-11).

Rows, in this order:

| # | Tile | Shown when | Title | Subtitle | Click writes | Live effect |
|---|---|---|---|---|---|---|
| 1 | Content blocking | http(s) page | "Block Ads & Trackers" | "On" when `AdBlockStore.isEnabled && !isAllowlisted(host)`; "Off" otherwise | `AdBlockStore.setExcluded(host, excluded: wasOn, profile:)` where `wasOn` is the tile state before the click (the store keeps the registrable domain). When the master switch is off the tile is in state `unavailable`: drawn off, click opens Settings → Advanced → Ad Blocking (`settings` command with pane `advanced`) and writes nothing. | `AdBlockEngineEvent.exclusions` reaches the engine; the change applies on the next navigation (adblock-fork §1.1). The panel shows the reload row (§3.4.1). |
| 2… | One tile per changed content setting | E1 available: every setting the engine reports as changed for the origin. Before E1: each of the 12 `SitePermission` kinds whose state is not `.ask`. | Display name (table below) | "Allowed" (allow) or "Blocked" (block) | Toggle: allow ↔ block through `WebProfile.setPermission(_:for:origin:)` (E1: `setSiteSetting`) | Takes effect on the next permission request; the panel shows the reload row. A tile whose permission is in use right now (camera or microphone capture) shows a 6 pt `Core.brandBlue` dot after the title (Open choice). |
| — | Preview | Hidden in v1 (Q3) | "Preview" | "Enabled"/"Disabled" | — | — |
| — | Developer Mode | Hidden in v1 (Q2) | "Developer Mode" | "On"/"Off" | — | — |
| — | Pop-ups | Never (Arc logs "not supported", SC-11) | — | — | — | — |

Ad-block tooltips (Open's words for Arc's three states, SC-11): on — "The built-in ad blocker is on
for this site."; excluded — "The built-in ad blocker is off for this site."; master off — "The
built-in ad blocker is off. You can turn it on in Settings."

Display names and glyphs (Open's own SF Symbol choices; titles capitalized from SC-12's table):

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

#### 3.4.1 Reload row

After any tile change, a 32 pt row slides in under the Settings tiles (height animation 0.22 s,
`Motion.rowStructure`): text "Reload to apply changes." 12 pt Regular, `Core.foregroundSecondary`,
at x 14, and a "Reload" text button 12 pt Semibold `Core.brandBlue` at the right. Click reloads
the tab and closes the panel. Open choice: Arc's reload follow-up for ad blocking
(`AdBlockReloadFollowUpAction`) is listed among Dia analytics events and its UI is not proven in
Arc 1.170 (SC-6 correction in `docs/re/features-advanced.md`). The panel never reloads on its own.

### 3.5 Boosts section

Shown when at least one Boost of the tab's Profile matches the page (`BoostMatcher.matching(url:)`
over **all** Boosts, enabled or not — the matcher index holds only enabled ones, so build a second
`BoostMatcher` from `allBoosts()` with every `isEnabled` forced true, cached per store change).
When none match, the section is hidden and the ⋯ menu shows "Manage Boosts…" and "New Boost…"
(SC-16 `includeBoostsInContextMenu`; inferred).

Row (one per matching Boost, matcher order): height 40, inset 14.

| Part | Value |
|---|---|
| Icon | 18 pt `paintbrush.pointed.fill`, tinted with the Boost's accent (§4.3, from its ID) at x 14, centered |
| Name | `boost.name`, or the site domain when empty (boosts-zap §3.3), 13 pt Medium, `Core.foregroundPrimary`, x 42, baseline 18 |
| Subtitle | "Enabled" / "Disabled", 11 pt Regular, `Core.foregroundSecondary`, baseline 32 (SC-13) |
| Switch | Our switch 26×16 at `W − 14 − 26`, centered: on `Core.brandBlue`, off `GrayScale.a(6)`, knob white 12 pt, knob slide 0.12 s |
| Edit | `pencil` 13 pt in a 24×24 button left of the switch (gap 6); visible on row hover or keyboard focus |
| Global off | When `open.advanced.enableBoosts` is false: rows draw at 50 % alpha, switches disabled, and a 28 pt note above the rows: "Boosts are off. Turn them on in Settings." (Open choice) |
| Incognito | Rows show; switch and edit disabled with tooltip "Boosts can't be edited in a private window." (D-10) |

Actions:

- Switch → `BoostStore.setEnabled(id:enabled:)` → adapter refresh (D-6). The subtitle updates at
  once; the page re-renders CSS components without reload. JS components stay until reload
  (applier contract A5).
- Edit (or double-click the row, or Return on a focused row) → close the panel, open the editor on
  this Boost for the anchor tab (§4).
- New Boost (action button 3, or ⋯ "New Boost…") → create
  `Boost(name: "My Boost", siteMatch: SiteMatch(domain: defaultDomain(host)))` with
  `defaultDomain` = host without a leading `www.`; `BoostStore.upsert`; close the panel; open the
  editor with `isNew = true` (§4.1).

### 3.6 Extensions section

Shared with `docs/plans/extensions-ui.md` (extensions-UI plan, in review on branch
`docs/plan-extensions-ui`). That plan owns the section **body**: `ExtensionsSectionBody` and
`ExtensionItemView` in its new target `OpenExtensionsUI` (item styles `.tile` for this grid and
`.row`), the item data (`ExtensionItem` from the extended OpenWeb `ExtensionHost`), pin order
(Chromium pref `extensions.pinned_extensions`, no second store), and the item intents
`.run(id, anchor)`, `.togglePin(id)`, `.contextMenu(id, anchor)`. This plan owns the section
header, its place in the panel, the panel itself, and the footer menu.

Arc evidence (SC-14 plus the extensions-UI planner's findings): items are an extension button and a
pin button; fields name, isPinned, isFocused, fallbackIcon, title, isActive; grid and row layouts;
"Add Extension" as the last item; per-site access is **not** in the panel — it is in Chromium's
extension context menu on right-click.

| Part | Value |
|---|---|
| Shown | When the tab's window has at least one extension item. |
| Body frame | x 14, width 292 (panel width − 2 × 14), height from `ExtensionsSectionBody` (its grid metrics). |
| Click | `.run(id, anchor)` → the App runs the action; the popup opens at the item's screen rect (app-shell §4.12). The Site Control Center closes first. |
| Pin | `.togglePin(id)` → App → `ExtensionHost.setPinned` (E4). Hidden until E4 lands. |
| Icon and badge | Drawn by `ExtensionItemView` from `toolbarImage` (Chromium's badge is baked in). This plan draws no badge of its own. |
| Right-click | `.contextMenu(id, anchor)` → App → Chromium's extension context menu (site access lives there). Before E4: an NSMenu with "Manage Extensions…" only. |
| Add Extension | Runs the `add-extension` command (exists in `OpenCommands`). |
| Header "Manage" | Runs the `manage-extensions` command (exists). |

Until `OpenExtensionsUI` lands, the section stays hidden (the ⋯ menu still has both extension
items). No second grid implementation is built here.

#### 3.6.1 Extension picker mode

The panel has a presentation mode for keyboard use of the Extensions section (Arc's extension picker,
`ExtensionPickerState`, SC-9):

- API: `SiteControlController.present(anchor: SiteControlAnchor, tabID: ItemID,
  mode: SiteControlPresentationMode)` with `enum SiteControlPresentationMode { case standard,
  extensionPicker }` and `enum SiteControlAnchor { case urlField, paneBar(ItemID), contentTopLeading }`.
- `.extensionPicker`: the panel opens as usual, then sets keyboard focus on the first extension item
  (`ExtensionsSectionBody.focusedID`); arrow keys move, Return runs the focused item, Esc closes the
  panel. With no extension items it opens in `.standard` mode and focuses only the ⋯ button.
  It does not open the menu on its own. Return opens the menu with "Add Extension…" highlighted;
  Esc closes the panel. **Guess, to confirm against capture #22** (lead decision, 2026-10-26).
- Anchor when the call comes from a key binding: `.urlField` when the sidebar is shown, else
  `.paneBar` for a focused split pane, else `.contentTopLeading` (panel at 12 pt from the web
  content's top-left, no arrow).
- The key binding and its command id belong to the extensions-UI plan (Q11).

### 3.7 Footer

Height 44, separator above.

| Part | Value |
|---|---|
| Security button | Left, x 10, height 28, padding 6. Glyph `lock.fill` 12 pt + "Secure" (12 pt Medium) in `CommandBarColors.lockSecure`, or `lock.open.fill` + "Insecure" in `CommandBarColors.lockInsecure` (`#F53714` / `#F25E6B`). Hover fill `SidebarColors.itemBackground`, radius 6. Click: E3 available → `showCertificateViewer` for the tab; before E3 → no action (button stays a status label, AX role static text). State before E3: `https` → Secure, `http` → Insecure, and every other scheme hides the label and its AX element (including `chrome`, `open`, `chrome-extension`, `about`, `data`, and `file`; lead decision 2026-10-26) (limitation: misses certificate errors and mixed content; named in E3). |
| ⋯ button | Right, 28×28 at `W − 10 − 28`, `ellipsis` 13 pt Bold. Opens an `NSMenu` (native, `MenuColors` do not apply). |

⋯ menu (SC-16 order; titles are Arc's):

| # | Item | Shown | Action |
|---|---|---|---|
| 1 | Clear Cache | http(s) page | E2 available → `clearSiteData(origin:kinds:[.cache])`. Before E2 → hidden (today's API clears the cache of every site; not acceptable). Then the reload row. |
| 2 | Clear Cookies | http(s) page | E2 → `clearSiteData(origin:kinds:[.cookies])`. Before E2 → `clearBrowsingData(origin:)` (also drops the shared HTTP cache; side effect stated in the PR). Then the reload row. |
| 3 | — | | |
| 4 | Manage Boosts… | Boosts section hidden | `view-boosts` |
| 5 | New Boost… | Boosts section hidden and New Boost enabled | §3.5 New Boost |
| 6 | — | | |
| 7 | Manage Extensions… | always | `manage-extensions` command (extensions-UI plan owns its target page; today `OEExtensionManager.managementPageURL`, Chrome-style tab until P3) |
| 8 | Add Extension… | always | `add-extension` command (opens `https://chromewebstore.google.com/category/extensions`, the URL in Arc's binary; extensions-UI plan §3.12 owns it) |
| 9 | — | | |
| 10 | All Site Settings… | http(s) page | Opens `chrome://settings/content/siteDetails?site=<origin>` in a new Today tab (same mechanism as Settings "More Settings…", settings plan §5.5) |

### 3.8 States and animation

| State | Visual |
|---|---|
| Open | Scale 0.66 → 1.0 around the panel's top-leading corner (lead decision A, PR #69) plus opacity 0 → 1, 0.18 s ease-out (`Motion.popoverOpen`, new). Evidence: Arc's theme popover is 66 % size one frame before full (A0465 → A0466). Duration guess. |
| Close | Opacity 1 → 0 and scale 1.0 → 0.96, 0.12 s ease-in (`Motion.popoverClose`, new). |
| Reduce Motion | Opacity only, same durations. |
| Tile toggle | Icon circle fill cross-fade 0.12 s (`Motion.selectionFade`); subtitle swaps at once. |
| Hover | Fills fade 0.08 s (`Motion.hoverFade`). |
| Rows added or removed while open (store change, permission prompt answered) | Height animates 0.22 s (`Motion.rowStructure`). |
| Live data | The panel registers an independent, token-based data source observer per window; changes arriving while open update in place (no reopen). No timers. |

### 3.9 Keyboard

The overlay takes first responder when it opens; the page loses key focus until it closes.

| Key | Effect |
|---|---|
| Esc | Close; focus returns to the page (or to the sidebar if the click came from there). |
| Tab / Shift+Tab | Next / previous control: action buttons, section headers, tiles, Boost switches and edit buttons, extension buttons, security button, ⋯. Focus ring 2 pt `Core.focusRing`, radius = control radius + 2. |
| Arrow keys | Move inside the current grid (action row, tiles, extension items) and between Boost rows. In `.extensionPicker` mode focus starts on the first extension item (§3.6.1). |
| Space / Return | Activate the focused control (Return on a Boost row = Edit). |
| Option held | No change in v1 (Arc's `_optionKeyDown` purpose is unknown, Q8). |
| Any Command shortcut (for example Cmd+Shift+C) | Closes the panel, then routes normally through `KeyboardRouter`. |

Clicks outside the panel close it and are delivered to their target (transient behavior). The
click that toggles the anchor button closes the panel and is consumed.

### 3.10 Accessibility

- Container: `NSAccessibility.Role.popover`, label "Site Control Center", description = host.
- Section header: role `.button`, label "Settings, More" etc.; a heading child with the title.
- Tile: role `.checkBox` for on/off tiles (value 1/0) with label "<Title>" and value description
  "<Subtitle>"; the unavailable ad-block tile is `.button` with help = the tooltip text.
- Boost row: group "<Name>, Enabled"; switch `.checkBox` "Enable <Name>"; edit `.button` "Edit
  <Name>".
- Extension button: `.button` "<Title>", help "Pin"/"Unpin" when E4 exists.
- The visible host label is hidden from AX; the panel description exposes the host once.
- Security: `.button` "Connection: Secure" (static text before E3); ⋯ `.menuButton` "More".
- Every action button has an AX label equal to its tooltip text without the keycaps.

---

## 4. Boost editor — design spec

### 4.1 Lifecycle

| Event | Behavior |
|---|---|
| Open | From the Site Control Center (row edit, New Boost), `new-boost`, `edit-boost`, `new-legacy-boost`, and "Customize Page…". One editor per window. Opening for another Boost closes the current one first (finalizing it). |
| `new-boost` | Always creates a new Boost (§3.5 New Boost) and opens the editor in simple mode. |
| `edit-boost` / "Customize Page…" | Opens the first matching Boost in matcher order (enabled or not); if none, behaves as `new-boost`. |
| `new-legacy-boost` | As `new-boost`, then switches to code mode on the CSS tab (Arc's "Legacy Boost (Advanced)" is its code-first editor; Open choice mapping). |
| `boost-gallery` | `isCommandEnabled` returns `false`. |
| Bound tab | The editor is bound to the tab (and pane) it opened for. Switching tab, Space, or window focus to another tab closes the editor (Open choice; Arc behavior unknown). Navigating the bound tab to a URL the Boost does not match keeps the editor open and shows the "Not active" banner (§4.3). |
| Close | Header ×, Esc (§4.10), the bound tab closes, or the profile is closed. Close exits Zap first, flushes pending live state to the store, and if the Boost was created in this session (`isNew`) and `Boost.isEmpty` is still true, deletes it (`BoostStore.delete`). |
| Incognito | `new-boost`, `edit-boost`, `new-legacy-boost`, and "Customize Page…" are disabled in incognito windows (D-10). |
| Global off | When `open.advanced.enableBoosts` is false the same commands stay enabled; the editor opens with a banner "Boosts are off. Changes show when you turn Boosts on in Settings." and live preview is skipped (the planner gets `boostsGloballyEnabled: false`). Open choice: editing still works. |

### 4.2 Window and placement

- Child `NSPanel` (D-4), `hasShadow = false` (we draw the shadow), clear background, level
  `.floating` relative to its parent (child window ordering keeps it above the parent only).
- Simple mode: width 268, height = content (≈ 470 with no Zaps; max `contentHeight − 24`, then the
  Zaps list scrolls). Position: top-right of the web content panel, inset 12 from the panel's
  right edge and 12 from its top (`docs/re/interaction-states.md` §16 toast inset). guess.
- Drag the header to move the panel within the window; the position is not persisted
  (Open choice). Window resize keeps the panel's offset from the content's top-right corner.
- Code mode: the panel grows to `open.boosts.codeEditorSize` (default 560×640, min 420×360, max
  content size − 24) anchored at its top-right corner; it is resizable from its left and bottom
  edges (8 pt hit strips). The size persists on resize end (BO-14 `codeEditingWindowSize`).
- Chrome: radius 12, fill `Core.popoverBackground`, 1 px `CommandBarColors.hairlineDivider` edge,
  shadow black 0.25 radius 16 y 6 (same recipe as §3.2). Appearance follows macOS.

### 4.3 Header and banners

| Part | Value |
|---|---|
| Header | Height 52, inset 14. Boost glyph 18 pt `paintbrush.pointed.fill` in the Boost's accent at x 14. Name 14 pt Semibold at x 40, baseline 22, tail truncation; double-click starts inline rename. Scope button below the name: "<domain><pathPrefix> ▾" 11 pt Regular `Core.foregroundSecondary`, baseline 39. Right: ⋯ menu button 24×24 at `W − 14 − 24 − 6 − 24` and close × 24×24 at `W − 14 − 24` (`xmark` 11 pt Semibold). |
| Accent | `BoostEditorColors.accents[hash(boost.id) % 8]` (Blue, Green, Magenta, Orange, Pink, Purple, Red, Yellow, BO-22). Use: header glyph, the Boost icon in the panel and Library rows. guess on Arc's use of these colors. |
| Not active banner | 28 pt row under the header, fill `BoostEditorColors.warning` (`#FF5A5F`) at 15 % alpha, text 11 pt Medium `Core.foregroundPrimary`: "This Boost doesn't apply to <host>." Shown when the bound tab's URL does not match the Boost's `siteMatch`. |
| Global-off banner | Same shape, text from §4.1. |

Scope menu (writes `siteMatch` through `BoostStore.upsert`, then refresh):

- "All of <registrable domain>" — `SiteMatch(domain: registrableDomain)` (via `AdBlockSites.registrableDomain`; omitted for IP hosts).
- "<host> and subdomains" for each intermediate host between the page host (without `www.`) and the
  registrable domain — `SiteMatch(domain: thatHost)`.
- "Only pages under /<segment>" — `SiteMatch(domain: current.domain, pathPrefix: "/<segment>")`; hidden when the path is `/`.
- IP hosts offer one "<ip>" host item, without "and subdomains" or a registrable-domain item,
  plus "Only pages under /<segment>" when the path is not `/`. A saved IP/path scope checks the
  path item. Lead clarification: 2026-10-26 03:37 America/Vancouver.
- The labels above follow the lead's 2026-10-25 23:46 America/Vancouver message: keep the
  matcher unchanged because stored values retain their meaning; change the host labels instead.
- The current choice has a checkmark. Default for a new Boost: host without `www.` (§3.5).
  Arc uses a host pattern only (`hostPattern`, BO-1); path prefixes are an Open addition the model
  already supports.

### 4.4 Color controls (simple mode)

Layout (y from the panel top, simple mode, no banner):

| Part | Frame / value |
|---|---|
| Wheel area | y 60, height 176. Hue ring outer diameter 128 at the area's center (BO-17 asset size), ring width 18, drawn by us as a conic gradient: hue = angle, saturation 0.85, brightness 1.0 (sRGB), with a 1 px black 8 % inner and outer stroke. The ring's inside is the drag pad: a disc of radius 46 filled `BoostEditorColors.puckPad` (black 4 % / white 6 %). |
| Puck | 24 pt circle filled with the current target color (`hsb(hue, 0.85 × intensity, 1)` blended over white), 3 pt white ring, shadow black 0.25 radius 3 y 1. Center = pad center + `(r · sin θ, −r · cos θ)` (y down, θ = 0 at 12 o'clock) with `r = intensity × 46`. At intensity 0 the puck sits in the center and draws hollow (ring only). |
| Side buttons | Under the wheel, y 240: three 28 pt round buttons, gap 12, centered: "Invert lightness" (`lightbulb` / `lightbulb.fill` when on), "Advanced color controls" (`slider.horizontal.3`), "Reset to original colors" (`arrow.counterclockwise`). Fill `BoostEditorColors.segmentBackground`; on state `Core.brandBlue` with white glyph. Tooltips = Arc labels. |
| Advanced sliders | When "Advanced color controls" is on, a block of three 28 pt rows slides in under the side buttons (0.22 s): label 11 pt Medium at x 14 ("Brightness", "Contrast", "Original Saturation"), slider x 110 to `W − 14`, track 4 pt `BoostEditorColors.sliderTrack` (`#3B3746` 5 %), fill and knob tint `BoostEditorColors.sliderTint` (`#017AFF`), knob 14 pt white with shadow. |

Interaction:

- Drag on the pad or ring: angle `θ` (0° at 12 o'clock, clockwise) and `ρ = min(distance / 46, 1)`.
  Dragging on the ring itself keeps `ρ = 1`. Clicking without drag sets the value at that point.
- Each drag event sends a live plan to the bound page (≤ 60 Hz, coalesced per display frame); the
  store commit and one undo entry happen on mouse-up (D-6).

Math (normative; `BoostColorWheel.adjustment` in OpenBoosts):

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
- Neutral page (`h0 == nil`): the wheel still works on colored elements. Under the wheel a 11 pt
  hint shows: "This page has few colors. Try Invert lightness." (Open choice.)
- Reset to original colors: `colorWheel = nil`, `colorAdjustment = nil`; puck animates to the
  center (0.22 s ease-out); advanced sliders reset to 1.
- Invert lightness toggles `colorWheel.invertLightness` (creating `colorWheel` with `ρ = 0` if
  needed). The applier already counter-inverts images and video (`docs/boosts.md` "Picture
  invert").
- Analogous and complementary schemes (BO-17) are not built: a CSS filter has one hue rotation
  (Q4).

Legacy filters (lead decision, 2026-10-26 03:21 America/Vancouver): a Boost with
`colorAdjustment` but no `colorWheel` keeps that exact legacy filter until the first color edit.
Before that edit the wheel shows the closest values it can represent and the 11 pt note
"Custom colors — editing replaces them." beneath the ring, in place of the neutral-page hint.
The displayed wheel preserves any representable hue and saturation, clamps brightness/contrast
to their wheel ranges, and chooses the nearer invert endpoint (0.5 rounds up). These displayed
values do not change the stored filter.
The first color edit replaces the filter with wheel-derived values as one undoable operation.
Undo restores the exact legacy `colorAdjustment` and leaves `colorWheel` nil. Non-color edits
never convert the legacy filter. The legacy round-trip is checked through the editor and real store.

### 4.5 Font and text controls

| Part | Value |
|---|---|
| Font strip | y after the color block + 12. Height 44: a horizontal scroll of chips 56×36, gap 6, inset 14, inside a track filled `BoostEditorColors.segmentBackground` radius 10. Each chip draws "Aa" 17 pt in its family (fallback system font when not installed; then hidden), with the family name as tooltip and AX label. Selected chip: `BoostEditorColors.segmentSelection` fill (white / white 30 %) with shadow black 0.10 radius 2. Scroll with trackpad, Shift+wheel, or arrow keys. |
| Fonts | "Original" (no override, `fontFamily = nil`), "System" (`system-ui, -apple-system, sans-serif`), then Helvetica Neue, Avenir, Futura, DIN Alternate, PT Mono, Courier, Times New Roman, Charter, Baskerville, Hoefler Text, Palatino, Chalkboard, SignPainter, Snell Roundhand, Papyrus, Apple Chancery, Luminari, Wingdings (BO-18 list; each written as `<Family>, <generic>` with generic serif / sans-serif / monospace / cursive / fantasy). Values contain no quotes or semicolons (the planner rejects `;{}"` and newlines, boosts-zap §3.5). |
| Tool tiles | y after the font strip + 12. Four square tiles 54×54, gap 8, inset 14 (4 × 54 + 3 × 8 = 240 = 268 − 28). Radius 12. Fill = accent color (Zap `Yellow`, Code `Blue`, Text size `Pink`, Text case `Green`; BO-22 colors, guess on Arc's mapping) at 100 % when on, 14 % when off; glyph 18 pt + label 10 pt Semibold below it; label color `BoostEditorColors.label` (white) when on, `Core.foregroundPrimary` when off. |

Tool tiles:

| Tile | Glyph | Label | Click | Writes |
|---|---|---|---|---|
| Zap | `bolt.fill` | "Zap" | Toggle Zap mode (§4.6) | — (Zaps write on commit) |
| Code | `chevron.left.forwardslash.chevron.right` | "Code" | Switch to code mode (§4.8) | — |
| Text size | `textformat.size` | current option: "Small", "Normal", "Medium", "Large", "Larger" | Cycle forward (Shift-click: back). Right-click: menu with the five options. | `textZoom`: small 0.9, normal nil, medium 1.1, large 1.25, larger 1.5 (BO-18 names; values guess) |
| Text case | `textformat` | "Aa", "Abc" (capitalize), "AB" (uppercase), "ab" (lowercase) | Cycle none → capitalize → uppercase → lowercase → none. Right-click: menu. | `textTransform`: nil / "capitalize" / "uppercase" / "lowercase" |

A tile is "on" when its value is not the default (Zap: picker active).

### 4.6 Zap: entry, list, exit

Entry and exit (D-8):

| Event | Effect |
|---|---|
| Zap tile on | `BoostPickerCoordinator.enterZap(boostID:for: pageID)` with the bound page's engine document identity; send the command through the adapter. The editor shows the Zaps list header "Click elements on the page to Zap them" (BO-20) in 11 pt Medium. Focus moves to the page so Esc and Cmd+Z reach the picker. |
| Picker commits (`zap:committed`, `zap:replaced`) | `coordinator.handle` persists; the editor reloads the list from `BoostStore` and asks `zap:list` for match counts. One undo entry per commit (§4.7). |
| Zap tile off | `coordinator.exitZap(for:)`; send. |
| Picker exits by itself (`picker:exited` esc / done) | Editor turns the tile off. |
| Editor close, tab switch, navigation, frame destruction, transport loss | `exitZap` or `invalidate(pageID:)` per `docs/boosts.md`. |
| Before P7 | The Zap tile is disabled with tooltip "Zap needs the isolated script world (engine patch P7)." and the adapter's Zap send path carries the `// Blocked on P7: isolated world` marker (app-shell D8). The list still shows and removes stored Zaps. |

Zaps list (Open's form of Arc's shelf, BO-20; placed in the editor, not over the page — D-8):

| Part | Value |
|---|---|
| Header | "Zaps" 12 pt Semibold `Core.foregroundSecondary` at x 14, count on the right ("3"); while Zap mode is on, the instruction text replaces the title. Hidden when there are no Zaps and Zap mode is off. |
| Row | Height 30. Label (`ZappedElement.label`, else the selector) 12 pt Regular, middle truncation, x 14 to `W − 70`. Match count from the last `zap:list-result` ("4 hidden", 11 pt, secondary; "—" before a result). Remove × 20×20 at `W − 14 − 20`, visible on hover and focus. |
| Hover a row | Preview: send a live plan without that selector, so the element shows again, and draw nothing else (Arc `zapToPreview`). On hover end, send the full plan again. Debounce 50 ms. |
| Remove | `BoostStore.removeZap(boostID:selector:)`; if picker active, also `coordinator.removeZap(selector:for:)` so the session list stays in sync; refresh; undo entry. |
| Context menu | "Copy Selector" (pasteboard; Arc `copySelectorToPasteboard`), "Remove Zap". |
| Max height | 5 rows visible, then the list scrolls. |

Picker bar text change (small runtime edit, Step 6): the picker's bar label "Zap mode" becomes
"Click elements on the page to Zap them" (Arc string, BO-20). The "Zap all related (N)" text stays
(`tools/verification/boosts.mjs` line 95 asserts it).

### 4.7 Menu, undo, rename, delete, shuffle

⋯ menu (BO-16, Open drops "Report Boost…"):

| # | Item | Enabled | Action |
|---|---|---|---|
| 1 | Undo | undo stack not empty | `undoManager.undo()` |
| 2 | Redo | redo stack not empty | `undoManager.redo()` (Arc has `redo`; menu label is Open's) |
| 3 | — | | |
| 4 | Rename this Boost… | always | Sheet on the panel: title "Rename this Boost", text field (prefilled, select all), buttons "Done" (default) / "Cancel". Empty text is allowed (display falls back to the domain). Writes `name`. |
| 5 | Shuffle | always | Random `θ ∈ [0, 360)`, `ρ ∈ [0.6, 1.0]`, random font from the list except Original and Wingdings, `textZoom`/`textTransform` unchanged. One undo entry. |
| 6 | Reset all Edits | Boost not empty | Clears color, font, text size, case, Zaps, CSS, JS (keeps name, scope, enabled). Confirmation alert: "Reset all edits?" / "This removes every change in this Boost." / "Reset" / "Cancel". One undo entry. |
| 7 | All Boosts… | always | `view-boosts` (the editor stays open) |
| 8 | — | | |
| 9 | Delete this Boost | always | Alert "Delete this Boost?" / "This removes the Boost and its changes from this site." / "Delete" (destructive) / "Cancel". On Delete: `BoostStore.delete(id:)`, close the editor (no undo; Open choice). |

Undo model: one `UndoManager` per editor session (`groupsByEvent = false`). Each committed change
registers the previous full `Boost` value (a Boost is small) and restores it with
`BoostStore.upsert` plus a refresh; when the picker is active, a restore also sends `zap:list` so
the picker's view of the Boost matches. Drags register on mouse-up only. Typing in a code editor
uses the text view's own undo (one group per 1 s pause) and registers one Boost-level entry when
the code editor loses focus. Undo stacks die with the session.

### 4.8 Code mode (CSS and JS)

| Part | Value |
|---|---|
| Header | Same header (§4.3), plus a back button `chevron.left` 24×24 left of the glyph that returns to simple mode. |
| Tabs | y 52 + 8: segmented control 2 segments "CSS" / "JS", height 28, width 160, at x 14. Track `BoostEditorColors.segmentBackground`, radius 8; selected segment `BoostEditorColors.segmentSelection`, 12 pt Semibold. |
| Tool bar | Same row, right-aligned, 12 pt Medium text buttons with 8 pt gaps: "Pick Selector" ↔ "Hide Selector Picker" (Step 8; hidden before it lands), "Refresh to Run" (JS tab only, shown when the JS text differs from the JS the page loaded with; tooltip "Refresh this Page"), "Show Developer Tools" ↔ "Hide Developer Tools" (`OEWebContent.showDevTools()` / `closeDevTools()` through the App). Arc labels (BO-19). |
| Editor | Under the tool bar, inset 0, fills the rest; top hairline. `NSScrollView` + `NSTextView`: font `NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)`, line height 16, text inset 8×6, background `Core.backgroundPrimary` at 60 % over the panel fill. Gutter: `NSRulerView` 36 pt, line numbers 10 pt monospaced digits, `Core.foregroundTertiary`, right-aligned with 6 pt padding. Placeholder (empty text): "your css here" / "your javascript here", 12 pt, black 30 % / white 30 % (BO-19). |
| Footer note (JS only) | First time the JS tab has text: a 28 pt dismissible row "JavaScript in a Boost runs on this site like the site's own code." with × (stores `open.boosts.hasDismissedJSNotice`). Open's words; Arc's banner is about sharing (BO-19), which Open does not have. |

Editing rules:

- Disable smart quotes, smart dashes, text replacement, automatic spelling correction, continuous
  spell checking, and data detectors. `usesFindBar = true` (Cmd+F). `allowsUndo = true`.
- Tab inserts two spaces; Shift+Tab outdents the selected lines by two spaces. Return keeps the
  current line's indentation and adds two spaces after a line ending in `{`; typing `}` on a
  whitespace-only line outdents it. Cmd+/ toggles `/* */` (CSS) or `//` (JS) on the selected
  lines. Cmd+] / Cmd+[ indent and outdent.
- Highlighter: re-color only the edited paragraph range ± 1 line and the visible range, on the main
  thread, after each edit (budget §7). Tokens: comments `GrayScale.a(9)`; strings `#C41A16` / `#FC6A5D`;
  numbers and units `#1C00CF` / `#D0BF69`; CSS at-rules, JS keywords `#9B2393` / `#FC5FA3` Semibold;
  CSS property names `#326D74` / `#67B7A4`; selectors and identifiers default text. (Open's own
  palette, Xcode-like; no Arc evidence.)
- CSS live: 150 ms after the last keystroke, write `css` with `BoostStore.upsert` and refresh all
  matching pages (D-6). Invalid CSS is applied as written (browsers skip bad rules).
- JS: 500 ms after the last keystroke, write `js` with `BoostStore.upsert`. The adapter reinstalls
  the Profile's document-start user scripts so the next load runs the new JS, and never runs it
  live (§5.3 JS rule). "Refresh to Run" is visible while the stored JS differs from the JS that was
  installed when the bound page last committed; it reloads the bound tab.
- The editor scrolls to and selects nothing on open; caret at the end of the text.

### 4.9 First-run interstitial

The first time an editor opens (`open.boosts.hasDismissedInterstitial` false), the panel shows an
interstitial instead of the controls (BO-21):

| Part | Value |
|---|---|
| Art | Our own drawn illustration, 70×70, `paintbrush.pointed.fill` in a 70 pt circle of the Boost accent; a wavy line under it drawn with `NSBezierPath` (no Arc asset). |
| Title | "Edit the Internet with Boosts", 16 pt Bold, `BoostEditorColors.interstitialForeground` (`#2E2740`) |
| Body | "Change colors, fonts, and text on any site, hide parts of a page, or add your own CSS." 12 pt Regular (Open's words) |
| Footer | Fill `BoostEditorColors.interstitialFooter` (`#CEDBFC`) 64 pt with a button "Make your own!" (Arc label) 13 pt Semibold. Click sets the flag and shows the controls. × closes the editor without setting the flag. |

### 4.10 Keyboard (editor)

| Key | Where | Effect |
|---|---|---|
| Esc | Panel key, no field editing | Zap on → exit Zap. Else close the editor. |
| Esc | Text field / code editor | End editing (rename: cancel); second Esc follows the row above. |
| Esc | Page key, Zap on | The picker exits (existing). |
| Cmd+Z / Cmd+Shift+Z | Panel key, outside a text view | Editor undo / redo (§4.7). |
| Cmd+Z | Page key, Zap on | Picker undo (existing). |
| Cmd+R | anywhere | Reload command (existing) — also runs changed JS. |
| Tab / Shift+Tab | Panel | Header controls → wheel → side buttons → sliders → font strip → tiles → Zaps rows. |
| Arrow keys | Wheel focused | Left/Right: hue ∓/± 5° (Shift: 15°). Up/Down: intensity ± 0.05. One undo entry per 1 s of key repeat. |
| Arrow keys | Font strip / tiles | Move selection; Space or Return applies. |
| Cmd+1 / Cmd+2 | Code mode | CSS / JS tab (Open choice; the browser's Cmd+1…9 tab jumps apply only while the page or sidebar is key). |

### 4.11 Boosts list (Library)

The `view-boosts` command, the "Manage" header, and "All Boosts…" open the Library window on a new
section "Boosts". Arc keeps Boosts in its Home/Library (`BoostsPage`, `HomeBoostsDelegateAction`,
BO-12). Add `case boosts` to `LibrarySection` (after `captures`; symbol `paintbrush.pointed`), so
`open.library.lastSection` accepts `boosts`. The section is a SwiftUI view,
`Sources/OpenSettings/BoostsSection.swift`, like `DownloadsSection.swift`. Data follows the
existing snapshot-provider pattern in `LibraryTypes.swift`, so `OpenSettings` gains no `OpenBoosts`
dependency: `public struct BoostItemSnapshot: Identifiable, Sendable { id: String (Boost UUID),
name, domain, pathPrefix: String?, isEnabled, accentIndex: Int }`, `@MainActor public protocol
BoostsProvider: AnyObject { func boosts(profileID: ProfileID) -> [BoostItemSnapshot] }`, and four
`LibraryActions` methods: `setBoostEnabled(id:enabled:profileID:)`, `renameBoost(id:to:profileID:)`,
`deleteBoost(id:profileID:)`, `editBoost(id:profileID:)`. The App implements them over `BoostStore`
(no second store). Profile scope: the Library's existing profile selection (`historyProfileID`
pattern in `LibraryViewModel`).

| Part | Value |
|---|---|
| Source | The selected Profile's `BoostStore.allBoosts()` (Profile picker at the top when more than one Profile exists). |
| Row | Height 52: site favicon 20 pt (`FaviconStore` by domain, fallback the Boost glyph in its accent), name 13 pt Semibold, subtitle "Made for <domain><pathPrefix>" 11 pt secondary (Arc's "Made for" form, BO-16 evidence), switch on the right, ⋯ menu: Edit…, Rename…, Delete…. |
| Edit… | Opens the site (`https://<domain><pathPrefix>`) in a new Today tab in the front window and opens the editor on that Boost when the tab commits its first URL. |
| Empty state | "Nothing Boosted Yet!" 15 pt Semibold, body "Open a site and choose New Boost in Site Controls." 12 pt (Open's words). |
| Global off | The same note as §3.5, plus a "Turn On" button that writes `open.advanced.enableBoosts = true`. |

---

## 5. Data and persistence

### 5.1 Where every value lives (complete; no other writes)

| Value | Written by | API | Storage |
|---|---|---|---|
| Site permission (12 kinds today) | Settings tiles | `WebProfile.setPermission(_:for:origin:)` → `OEBrowserContext.setPermissionState` | Chromium content settings of the Profile's engine directory (`Preferences`, `profile.content_settings.exceptions`). Open keeps no copy. |
| Other content settings (E1) | Settings tiles | `WebProfile.setSiteSetting(_:kind:origin:)` (new, E1) | Same Chromium store |
| Per-site ad-block exclusion | Ad-block tile; Settings allowlist (`AdBlockSettingsModel.setExcluded`) | `AdBlockStore.setExcluded(_:excluded:profile:)`, then the App's `setAdBlockExcludedDomains(_:profileID:)` engine path — the same two calls the Settings allowlist makes, so both writers behave the same | `<root>/Profiles/<profile UUID>/adblock/exclusions.json` (registrable domains). Engine via `AdBlockEngineEvent.exclusions`. |
| Ad-block master switch | Settings only (the panel reads it) | `AdBlockStore.setEnabled` | `<root>/adblock-settings.json` `nativeAdBlockEnabled` |
| Boost enabled | Boost switch, Library switch | `BoostStore.setEnabled(id:enabled:)` | `<root>/Profiles/<dataDirectoryName>/Boosts/boosts.json` (`ProfileDirectories.boostsFileURL(for:)`) |
| Boost name, scope, color, font, text size, case, CSS, JS | Editor | `BoostStore.upsert` | same file |
| Zaps | Picker commits (coordinator), editor remove | `BoostStore.appendZap` / `removeZap` | same file |
| Editor color inputs | Editor | `BoostStore.upsert` with `colorWheel` set (§5.2) | same file |
| Global Boosts switch | Settings (A-5); Library "Turn On" | `UserDefaults` `open.advanced.enableBoosts` (default true) | `UserDefaults.standard` |
| Interstitial dismissed | Editor | `open.boosts.hasDismissedInterstitial` Bool (false) | `UserDefaults` |
| JS notice dismissed | Editor | `open.boosts.hasDismissedJSNotice` Bool (false) | `UserDefaults` |
| Code editor size | Editor | `open.boosts.codeEditorSize` String `"<w>x<h>"` ("560x640") | `UserDefaults` |
| Extension pin | Pin button (E4) | `ExtensionHost.setPinned` → `-[OEBrowser setExtensionAction:pinned:]` (extensions-UI plan E4) | Chromium prefs (`extensions.pinned_extensions`) |
| Cookies, cache | ⋯ menu | `WebProfile.clearSiteData(origin:kinds:)` (E2) | Chromium |
| Panel state | — | none | Arc has `PersistedSiteControlCenterState` (contents unknown); Open persists nothing (Open choice) |

Register the three new `open.boosts.*` defaults in `SettingsDefaults.values`
(`Sources/OpenSettings/SettingsTypes.swift`, the one registry) and add them to the settings plan's
§2.1 table in the same PR. `OpenSiteControl` reads them with `UserDefaults.standard` and the same
fallbacks.

### 5.2 Model change (the only OpenBoosts model edit)

Add to `Packages/OpenKit/Sources/OpenBoosts/Boost.swift`:

```swift
/// Editor inputs for the color wheel (docs/plans/site-control-boost-editor.md §4.4).
/// When set, `Boost.colorAdjustment` is derived from it; the runtime reads only colorAdjustment.
public struct BoostColorWheel: Codable, Hashable, Sendable {
    public var hue: Double                 // θ, degrees, 0 at 12 o'clock, clockwise
    public var intensity: Double           // ρ, 0...1
    public var baseHue: Double?            // h0, page dominant hue at first color; nil = neutral page
    public var invertLightness: Bool       // default false
    public var brightness: Double          // 0.5...1.5, default 1
    public var contrast: Double            // 0.5...1.5, default 1
    public var originalSaturation: Double  // 0...2, default 1
    public init(hue: Double = 0, intensity: Double = 0, baseHue: Double? = nil, invertLightness: Bool = false,
                brightness: Double = 1, contrast: Double = 1, originalSaturation: Double = 1)
    public func clamped() -> BoostColorWheel     // wrap hue, clamp ranges, NaN → default
    public var isIdentity: Bool { get }          // §4.4 identity rule
    public var adjustment: ColorAdjustment? { get } // §4.4 math; nil when identity
}

// In Boost: an optional, defaulted Codable field (old files decode without it).
public var colorWheel: BoostColorWheel?
```

- `BoostStore.normalized` (private) also clamps `colorWheel` and, when it is non-nil, sets
  `colorAdjustment = colorWheel.adjustment` (single writer of the derived value). When
  `colorWheel` is nil, `colorAdjustment` is left as stored (imported or hand-edited Boosts).
- `Boost.isEmpty` treats `colorWheel` like `colorAdjustment` (identity or nil = empty).
- The planner, the applier, the bridge, and the file schema version do not change.
- `docs/boosts.md` gets one API line for the new type in the same PR.

### 5.3 Live preview path

```text
editor input ─┬─ drag event ──► BoostEditorSession.preview(boost')   (no store write)
              │                    └─► adapter.preview(plan for bound page only)   ≤ 60 Hz
              └─ commit ─────────► BoostStore.upsert(boost')  (1 s debounced save)
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
Packages/OpenKit/Package.swift                         add OpenSiteControl library + sitecontrol-render executable
Packages/OpenKit/Sources/OpenDesign/SiteControlTokens.swift   SiteControlMetrics, BoostEditorMetrics, BoostEditorColors, new Motion and Typography tokens
Packages/OpenKit/Sources/OpenBoosts/Boost.swift        BoostColorWheel + Boost.colorWheel (§5.2)
Packages/OpenKit/Sources/OpenBoosts/BoostStore.swift   normalization of colorWheel (§5.2)
Packages/OpenKit/Sources/OpenBoosts/Resources/zap-picker.js   bar label (Step 6); select mode (Step 8)
Packages/OpenKit/Sources/OpenBoosts/PickerMessages.swift      select-mode messages (Step 8)
Packages/OpenKit/Sources/OpenSiteControl/
  SiteControlTypes.swift          value types (§6.2)
  SiteControlDataSource.swift     protocols the App implements (§6.3)
  SiteControlController.swift     overlay presentation, anchoring, dismissal, keyboard
  SiteControlView.swift           panel view: header, actions, sections, footer
  SiteControlTiles.swift          tile, Boost row, extension button, switch, section header
  BoostEditorSession.swift        editing state, undo, preview/commit, wheel math use, h0 sampling
  BoostEditorPanel.swift          BoostEditorController (public entry), NSPanel, placement, resize, simple/code switch
  BoostEditorViews.swift          header, banners, wheel, sliders, font strip, tool tiles, Zaps list, interstitial
  CodeEditorView.swift            NSTextView subclass, highlighter, gutter, indentation rules
Packages/OpenKit/Sources/OpenSettings/BoostsSection.swift          Library "Boosts" section (SwiftUI, §4.11)
Packages/OpenKit/Sources/OpenSettings/LibraryTypes.swift           LibrarySection.boosts, BoostItemSnapshot, BoostsProvider, LibraryActions additions
Packages/OpenKit/Sources/OpenSettings/SettingsTypes.swift          three open.boosts.* defaults in SettingsDefaults.values
Packages/OpenKit/Sources/settings-preview/LibraryPreview.swift     boosts section states (empty, 3 Boosts, global off)
Packages/OpenKit/Sources/sitecontrol-render/          main.swift, Scenes.swift, Flows.swift, Bench.swift, FakeSources.swift (+ reuse OffscreenRenderer pattern)
Packages/OpenKit/Sources/OpenFeatures/PaneChromeView.swift   enable button 4, forward its action
Packages/OpenKit/Sources/OpenFeatures/BrowserWindowController.swift  handle .showSiteControls, .customizePage, commands (§6.4)
App/SiteControl/AppSiteControlSource.swift            SiteControlDataSource over the engine and stores (§6.3)
App/Boosts/BoostEngineAdapter.swift                   (app-shell §4.5) + preview/refresh API (§5.3)
App/Automation/AutomationController.swift             site-controls, boost-editor, boosts, pasteboard commands (§8.2)
tools/e2e/engine_e2e.py                               --only sitecontrol, --only boosteditor
tools/verify-all.sh, tools/verification/check.py      add sitecontrol-render (runs `sitecontrol-render check`)
docs/boosts.md, docs/commands.md, docs/plans/settings-library.md   one-line updates each (§5.1, §4.1, §4.11)
```

`OpenSiteControl` must not import `OpenFeatures` (the controller sits in OpenFeatures and imports
OpenSiteControl, not the other way round) or `OpenSidebar`.

### 6.2 Value types (`SiteControlTypes.swift`)

```swift
public struct SiteControlContext: Sendable, Equatable {
    public var tabID: ItemID
    public var profileID: ProfileID
    public var url: URL
    public var displayHost: String          // humanReadableHost (§3.2)
    public var isIncognito: Bool
    public var security: SiteSecurity       // .secure, .insecure, .unknown (before E3: by scheme)
    public var faviconPNG: Data?
}

public enum SiteSettingKind: Hashable, Sendable {
    case contentBlocking
    case permission(SitePermission)          // OpenWeb's 12 kinds
    case content(String)                     // E1 kind id, e.g. "javascript"; display via table §3.4
}

public enum SiteSettingState: Sendable, Equatable { case on, off, unavailable }

public struct SiteSettingTile: Sendable, Equatable, Identifiable {
    public var id: String                    // stable: "contentBlocking", "permission.camera", "content.javascript"
    public var kind: SiteSettingKind
    public var title: String
    public var subtitle: String              // "On"/"Off"/"Allowed"/"Blocked"
    public var state: SiteSettingState
    public var symbol: String
    public var inUse: Bool
    public var help: String?
}

public struct SiteControlSnapshot: Sendable, Equatable {
    public var context: SiteControlContext
    public var tiles: [SiteSettingTile]
    public var boosts: [Boost]               // matching, matcher order
    public var boostsGloballyEnabled: Bool
    public var extensions: [ExtensionActionInfo]
    public var capabilities: Set<SiteCapability>   // which E-items exist (§9 E1–E5)
    public var commandsEnabled: [String: Bool]     // action buttons and menu items
}

public enum SiteCapability: Hashable, Sendable { case changedSettings, clearCache, securityState, certificateViewer, extensionPinning, isolatedWorld }
public enum SiteSecurity: Sendable, Equatable { case secure, insecure, unknown }
public struct SiteDataKinds: OptionSet, Sendable { public let rawValue: Int
    public static let cookies = SiteDataKinds(rawValue: 1), cache = SiteDataKinds(rawValue: 2), storage = SiteDataKinds(rawValue: 4) }
public enum BoostCodeTab: Sendable, Equatable { case css, js }
public enum BoostEditorMode: Sendable, Equatable { case simple, code(BoostCodeTab) }
public enum SiteControlPresentationMode: Sendable, Equatable { case standard, extensionPicker }   // §3.6.1
public enum SiteControlAnchor: Sendable, Equatable { case urlField, paneBar(ItemID), contentTopLeading }
```

### 6.3 Protocols the App implements (`SiteControlDataSource.swift`)

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
    func perform(command: String, tabID: ItemID, anchor: NSRect?)  // share-page, copy-url, capture-*, view-boosts, settings
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
    func pageSnapshot(tabID: ItemID) async -> Data?                 // PNG for h0
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
| `.showSiteControls` | `siteControl.toggle(anchor: .urlField, tabID: focused tab)` (toggle = `present(…, mode: .standard)` or close) |
| Pane bar button 4 | `siteControl.toggle(anchor: .paneBar(paneTabID), tabID: paneTabID)` |
| Extension picker key binding (extensions-UI plan, Q11) | `siteControl.present(anchor: §3.6.1 rule, tabID: focused tab, mode: .extensionPicker)` |
| `.customizePage(tabID:)` | `edit-boost` for that tab |
| `new-boost`, `edit-boost`, `new-legacy-boost` | §4.1 |
| `view-boosts` | Library window, section `boosts` |
| `boost-gallery` | disabled |
| Tab selection change, Space switch, window resign main | Close the panel; close the editor if its bound tab is no longer shown |

`isCommandEnabled` returns false for the Boost commands in incognito windows and on non-http(s)
pages.

---

## 7. Performance budgets (release build, M5 Pro, 2x)

| Path | Budget | How measured (`sitecontrol-render bench`) |
|---|---|---|
| Click → panel first draw | p95 < 8 ms main thread | build view + layout + first `display`, 20 Boosts, 12 tiles, 30 extensions |
| Panel open, idle | 0 timers, 0 % CPU after the open animation | run loop observer counts timer fires over 2 s = 0 |
| Wheel drag event → preview plan handed to host | p95 < 2 ms | 500 synthetic drag events |
| Live preview frame rate | ≤ 60 Hz to the page, coalesced | count preview calls during a 1 s, 120 Hz drag = ≤ 61 |
| Commit → all matching pages refreshed | < 100 ms for 10 open matching tabs (fake host) | |
| Code editor keystroke → highlight done | p95 < 2 ms on a 2,000-line CSS file | insert 200 characters at the middle |
| Editor open (simple mode) | p95 < 12 ms | |
| h0 sampling (64×64 histogram from a 2216×1394 PNG) | < 15 ms, off the main thread | |

Never parse or highlight on the network thread; never hold the store lock during layout.

---

## 8. Verification (no unit tests)

### 8.1 Offscreen renders and flows: `sitecontrol-render`

New executable target in `commandbar-render` style: real `OpenSiteControl` views and controllers,
fake data source/host (`FakeSources.swift`) that records every action call, a synthetic window
backdrop (sidebar + page color) so the panel renders over realistic content.

```text
sitecontrol-render render --state NAME --out FILE.png [--scale 1|2] [--appearance light|dark]
sitecontrol-render ax --state NAME          # accessibility tree of the rendered state
sitecontrol-render flows                    # scripted keyboard and mouse flows; exit 1 on failure
sitecontrol-render check                    # flows + render of every state at 1x and 2x + bench budgets (verify-all)
sitecontrol-render bench
sitecontrol-render screens --out DIR        # every state, for docs (our renders only)
sitecontrol-render motion --out DIR         # open/close frames (presentation values)
sitecontrol-render compare --arc CAPTURE.png --ours RENDER.png --out DIR   # when a capture exists (R-1)
```

States: `scc-basic` (https, ad block on, camera allowed + notifications blocked, 2 Boosts one
disabled, 3 extensions), `scc-insecure`, `scc-adblock-excluded`, `scc-adblock-unavailable`,
`scc-no-boosts` (menu shows Boost items), `scc-boosts-off`, `scc-incognito`, `scc-internal-page`,
`scc-many` (scrolls), `scc-pane-anchor`, `scc-dark`, `editor-interstitial`, `editor-simple`,
`editor-advanced-color`, `editor-neutral-page`, `editor-not-active`, `editor-zap-on` (3 Zaps),
`editor-zap-blocked-p7`, `editor-code-css`, `editor-code-js-dirty`, `editor-menu`, `editor-global-off`, and `editor-legacy` (legacy color migration). Step 4 adds the
simple states; Zap and code states follow in Steps 6 and 7. (The Library
section renders through `settings-preview`, not here.)

Flows (each asserts the fake's recorded calls and the view state):

| # | Flow | Pass |
|---|---|---|
| F1 | Click the anchor → panel presented; click again → closed | presented/closed, no action calls |
| F2 | Esc closes; click outside closes and the click reaches the backdrop view | `dismissed(.escape)`, `.outside`, backdrop hit count 1 |
| F3 | Tab cycles in §3.9 order; arrows move in the tile grid; Space toggles the focused tile | focus order list matches; one `toggle(tile)` |
| F4 | Ad-block tile on → off → on | `toggle` ×2 with `contentBlocking`; subtitle On/Off/On; reload row appears once |
| F5 | Unavailable ad-block tile | one `perform(command: "settings")`, no `toggle` |
| F6 | Permission tile toggle | `toggle(permission.camera)`; subtitle Allowed → Blocked |
| F7 | Boost switch, edit button, Return on a row | `setBoostEnabled`, `openEditor(id)` ×2 |
| F8 | New Boost (action button and ⋯ item when the section is hidden) | `openEditor(nil, .simple)` ×2 |
| F9 | Every ⋯ menu item in each capability set | exact item list per §3.7; each action call once |
| F10 | Editor wheel drag of 40 events | ≤ frame-count `preview` calls, exactly 1 store write and 1 undo entry on mouse-up; stored `colorAdjustment == colorWheel.adjustment` |
| F11 | Wheel math table: 12 fixed inputs (θ, ρ, h0, invert, b, c, s0) | outputs equal §4.4 to 1e-9 |
| F12 | Font chip, text size cycle (5 steps + Shift-click back), case cycle | store values per §4.5 |
| F13 | Zap tile on/off, picker exit event, commit event, remove row, hover row | host calls in order; list rows; hover sends a preview without the selector, then the full plan |
| F14 | Undo/redo after F10–F13 | store returns to each previous value |
| F15 | Rename (Done, Cancel, empty), Shuffle, Reset all Edits (Cancel, Reset), Delete (Cancel, Delete) | store values; editor closed after Delete |
| F16 | Close a new untouched Boost; close a new Boost after one change | first deleted, second kept |
| F17 | Code editor: type CSS, wait 150 ms | one `upsert` with the text, one `refresh`; Tab inserts 2 spaces; Return after `{` indents; Cmd+/ comments |
| F18 | JS tab: type, "Refresh to Run" appears; host reload; after reload with equal JS it hides | |
| F19 | Interstitial "Make your own!" sets the flag; × does not | UserDefaults (suite-scoped) |
| F20 | Incognito context | New Boost disabled, Boost switches disabled, no `openEditor` on click |
| F21 | VoiceOver labels and roles for every control in `scc-basic` and `editor-simple` | AX dump contains every §3.10 label; no unlabeled button |
| F22 | Empty/failure: snapshot returns nil (tab closed while opening) | panel does not open; no crash; error logged once |

`check` adds a render smoke per state (panel pixels differ from the backdrop at a probe point,
image size correct) and the §7 budgets. Add `sitecontrol-render` to `NAMES` in
`tools/verify-all.sh` and to `tools/verification/check.py` (same branch as `commandbar-render`).

### 8.2 Real app: automation and e2e suites (after app-shell Steps B, D, F)

New automation commands (`App/Automation/AutomationController.swift`, Debug/automation builds only;
document them in `docs/automation.md`):

| Command | Args | Does |
|---|---|---|
| `site-controls` | `action: open\|close\|state\|tap\|menu`, `via: urlField\|pane`, `id` (tile/row/button id), `item` (menu title) | `open` clicks the real anchor button (`performClick` on the `PlateButton` / pane button); `tap` performs the click on the real control view; `menu` picks a ⋯ item through the real `NSMenu` item action; `state` returns the snapshot as shown (titles, subtitles, states, rows, items, visible flags). |
| `boost-editor` | `action: open\|close\|state\|drag\|key\|tap\|type`, `boost`, `mode`, `points` (wheel drag path in panel coordinates), `id`, `text`, `tab: css\|js` | Drives the real panel views with synthesized `NSEvent`s inside Open's own windows (no system input, `docs/automation.md`). `state` returns the session (Boost value, modality, Zap on, list rows, undo count). |
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
| S1 | Open `http://127.0.0.1:<port>/ads.html`. `site-controls open via=urlField` → `state` shows header host, Settings with "Block Ads & Trackers — On", footer "Insecure" (scheme rule before E3). Window `snapshot` PNG saved. |
| S2 | `tap id=contentBlocking` → subtitle "Off"; `exclusions.json` on disk contains `127.0.0.1`; reload row visible; `tap id=reload` → `filter-stats` shows the ad fixture request allowed. Tap again → "On", file no longer contains it, reload → blocked. |
| S3 | `permission origin=… kind=camera state=1` (existing command) → reopen panel → tile "Camera — Allowed"; `tap id=permission.camera` → "Blocked"; `permission` read returns 2. |
| S4 | Create a Boost through `boost-editor open` (New Boost), set CSS `body{outline:3px solid red}`, close. Reopen panel → Boosts row "My Boost — Enabled"; `eval` shows the outline. `tap id=boost.<id>.switch` → "Disabled", `boosts get` `isEnabled == false`, `eval` shows no outline without reload. |
| S5 | `menu item="Clear Cookies"` after the fixture sets a cookie → reload → `eval document.cookie` is empty. "Clear Cache" absent before E2. |
| S6 | `tap id=action.copyURL` → `pasteboard` equals the page URL; toast event recorded. |
| S7 | Esc (`key route=app key=escape`) closes; `state` reports closed; a page `click` while open closes the panel and the page receives the click (`eval` counter + 1). |
| S8 | Split: `split` (existing) → `site-controls open via=pane` → header shows the focused pane's host. |
| S9 | Empty case: `about:blank` → `site-controls open` returns error "no site"; internal page → only header, Copy URL, Share, footer. |
| S10 | Incognito window (when app-shell §4.8 lands): New Boost disabled, Boost switch disabled. Until then: reported `blocked: incognito`, never pass. |

`--only boosteditor`

| # | Check |
|---|---|
| B1 | New Boost from the panel → `boosts list` has one Boost named "My Boost" with `siteMatch.domain == 127.0.0.1`; editor `state` shows simple mode (interstitial first on a fresh profile; `tap id=interstitial.start`). |
| B2 | On `boost.html`: `drag points=[…]` on the wheel → `eval getComputedStyle(document.documentElement).filter` contains `hue-rotate`; `boosts get` has `colorWheel.baseHue` within ± 10° of 216 (the fixture header `#2E7DF6`) and `colorAdjustment` equal to §4.4 for the stored θ, ρ, h0. |
| B3 | `tap id=font.Avenir` → the `h1` computed `font-family` starts with `Avenir`; one text-size click → root `zoom` is 1.1; one case click → body `text-transform` is `capitalize`. |
| B4 | Zap (after P7, else `blocked: P7`): tile on → `click` on the fixture banner (existing page click command) → `boosts get` has one Zap; banner hidden probe; list row shows "div#promo-banner" with "1 hidden"; remove row → banner visible without reload. |
| B5 | Code: `type tab=css text="h1{color:rgb(1,2,3)}"` → within 300 ms `eval` reads the color; `type tab=js text="document.body.dataset.boosted=1"` → "Refresh to Run" visible → `reload` → `eval document.body.dataset.boosted == "1"`. |
| B6 | Undo: `key route=app key=z modifiers=["cmd"]` with the panel key → last change reverted in `boosts get`. |
| B7 | Menu: Rename → "Docs Boost" stored; Delete → store empty, editor closed. |
| B8 | New Boost, close at once → store empty. |
| B9 | Quit and relaunch with a saved Boost → the style applies at document start (existing `boosts` suite probe) and the panel lists it. |
| B10 | `defaults write <bundle> open.advanced.enableBoosts -bool false` before launch → panel shows "Boosts are off…", editor banner, no `hue-rotate` on the page. |

Any check that needs a missing engine item reports `blocked: E<n>` or `blocked: P7` and never
passes by itself.

### 8.3 Visual comparison

When the user records captures #19, #21, and #22 of `docs/re/runtime-observations.md` §7 (Site
Control Center, Boost editor, full Site Control Center; rows #21 and #22 are added with this plan), run
`sitecontrol-render compare` against our render at the same size and appearance, using the
`docs/design.md` §7 method. Targets: layout ≤ 1 pt, fills and text ΔE00 ≤ 2. Update only
`SiteControlTokens.swift` values. Never commit the captures (`AGENTS.md` rules 1, 5).

---

## 9. Engine capabilities the UI needs (not in `docs/engine-api.md` today)

| ID | Capability | Needed for | Today | Proposed OpenEngine API (engine team owns the final shape) |
|---|---|---|---|---|
| E1 | List the content settings a site has changed, for every Chromium content-setting type (not only the 12 permission kinds), and set them | Settings tiles beyond the 12 kinds (JavaScript, Images, Pop-ups, Sound, Ads, …) | 12 kinds, ask/allow/block, no enumeration | `-[OEBrowserContext changedSiteSettingsForOrigin:] -> NSArray<OESiteSetting *>` (`kind` string id, `state` allow/block/ask/session); `-setSiteSetting:state:origin:`. OpenWeb: `WebProfile.changedSiteSettings(origin:)`, `setSiteSetting(_:kind:origin:)`. Arc: `getChangedContentSettingsForOrigin:` |
| E2 | Clear one origin's cookies, cache, or storage separately | ⋯ Clear Cache / Clear Cookies | `clearBrowsingData(origin:)` = cookies of one origin + cache of all sites | `-clearSiteDataForOrigin:types:completion:` with `OESiteDataTypeCookies \| Cache \| Storage` (Chromium `BrowsingDataRemover` + origin filter). OpenWeb: `clearSiteData(origin:kinds:)` |
| E3 | Security state and certificate | Footer security button | none | `OEWebContent.securityLevel` (`secure`, `neutral`, `insecure`, `dangerous`, `mixedContent`) + change flag `OEWebContentChangeSecurity`; `certificateChain -> NSArray (SecCertificateRef)` so Swift shows `SFCertificatePanel`. Arc: `ArcSecureContext`, `showCertificateDialog` |
| E4 | Extension pin state, pin/unpin, the per-action context menu, and the toolbar image | Extensions section pin, right-click, item icon | manifest defaults, no pin | Names owned by `docs/plans/extensions-ui.md` §7 (use these, not new ones): its E2 adds `OEExtensionAction.toolbarImage` (28×28 pt with Chromium's badge baked in), `pinned`, `pinnedIndex`; its E4 is `-[OEBrowser setExtensionAction:pinned:]` and `-moveExtensionAction:toPinnedIndex:`; its E7 is `-contextMenuForExtensionAction:source:` returning `OEExtensionActionMenu` (items reuse `OEContextMenuItem`; `select(command:)` / `cancel()`). Engine work rides P2 (`docs/engine-patches.md`). |
| E5 | Evaluate in the isolated world and deliver picker/applier messages there | Zap, secure live preview | main world only | P7 |
| E6 | Blocked request count per page | Not shown in v1 (Q5); automation only | — | adblock-fork §12.1 `blockedResourceCountForBrowser:` |

Interim behaviors are stated per row in §3 and are listed in the PR of the step that ships them.

---

## 10. Implementation order (small PRs; each step: files, then acceptance)

Each PR: merge `origin/main`, run `tools/verify-all.sh`, paste the summary (`AGENTS.md` rule 10).

| Step | Work | Files | Acceptance |
|---|---|---|---|
| 1 | Target skeleton, tokens, empty panel with header/actions/footer on fake data; harness with `render`, `ax`, `check` | `Package.swift`, `OpenDesign/SiteControlTokens.swift`, `OpenSiteControl/SiteControlTypes.swift`, `SiteControlDataSource.swift`, `SiteControlController.swift`, `SiteControlView.swift`, `sitecontrol-render/*`, `tools/verify-all.sh`, `tools/verification/check.py` | `sitecontrol-render check` PASS (F1, F2, F21 partial, F22), renders `scc-basic` header/footer at 1x/2x; `verify-all` row PASS |
| 2 | Sections: tiles, Boost rows, Extensions section host (body from `OpenExtensionsUI` when it exists, else hidden), ⋯ menu, reload row, keyboard, picker mode, AX, animations | `SiteControlTiles.swift`, `SiteControlView.swift`, `SiteControlController.swift` | F3–F9, F20–F22 PASS; all `scc-*` states render; bench "click → first draw" < 8 ms |
| 3 | App data source + actions; anchors (URL field, pane bar); intents and commands; automation `site-controls`, `pasteboard`; e2e `sitecontrol` | `App/SiteControl/AppSiteControlSource.swift`, `OpenFeatures/BrowserWindowController.swift`, `OpenFeatures/PaneChromeView.swift`, `App/Automation/AutomationController.swift`, `tools/e2e/engine_e2e.py`, `docs/automation.md` | `--only sitecontrol` S1–S9 PASS (S10 blocked) on the real app; `--only features` still PASS |
| 4 | OpenBoosts `BoostColorWheel` + normalization; editor session (undo, preview/commit, h0); simple-mode views; interstitial; menu | `OpenBoosts/Boost.swift`, `BoostStore.swift`, `docs/boosts.md`, `OpenSiteControl/BoostEditorSession.swift`, `BoostEditorPanel.swift`, `BoostEditorViews.swift` | F10–F12, F14–F16, F19 PASS; `editor-*` simple states render; `boosts` harness (verify-all) still 26/26 |
| 5 | App editor host: adapter preview/refresh, commands `new-boost`/`edit-boost`/`new-legacy-boost`/`view-boosts`, `.customizePage`; Library Boosts section + App provider; automation `boost-editor`, `boosts`; e2e `boosteditor` B1–B3, B6–B10 | `App/Boosts/BoostEngineAdapter.swift`, `OpenFeatures/BrowserWindowController.swift`, `OpenSettings/BoostsSection.swift`, `OpenSettings/LibraryTypes.swift`, `settings-preview/LibraryPreview.swift`, the App's Library provider, automation, e2e | Listed e2e checks PASS on the real app; `settings-preview check` (verify-all) PASS with the new `boosts` section states |
| 6 | Zap integration: tile, list, hover preview, remove, picker events; picker bar label | `BoostEditorViews.swift`, `BoostEditorSession.swift`, `App/Boosts/BoostEngineAdapter.swift`, `zap-picker.js` | F13 PASS; `boosts` harness PASS; B4 PASS after P7, else `blocked: P7` |
| 7 | Code mode: code editor, highlighter, gutter, CSS live, JS refresh, devtools toggle, size persistence | `CodeEditorView.swift`, `BoostEditorPanel.swift`, `BoostEditorViews.swift` | F17, F18 PASS; bench keystroke < 2 ms; B5 PASS |
| 8 | "Pick Selector": picker select mode (`zap:enter` with `mode: "select"`; page → native `picker:selected {boostID, sessionNonce, selector, matches}`; no commit, no hide); the editor inserts the selector at the CSS caret | `zap-picker.js`, `PickerMessages.swift`, `docs/boosts.md` (bridge table), `tools/verification/boosts.mjs` (new check: select mode commits nothing and returns the same selector a click would commit) | `boosts` harness PASS including the new check; flow "Pick Selector inserts the selector" PASS |
| 9 | Engine items as they land: E1 tiles, E2 menu items, E3 security, E4 pins | the source + views | The interim rows in §3 switch; S5 "Clear Cache" and E-dependent checks PASS |

Steps 1–2 and 4 need no App or engine and can run before app-shell Step B. Step 3 needs app-shell
Steps B and D. Step 5 needs Step F.

---

## 11. Risks and open questions

### 11.1 Risks

| # | Risk | Mitigation |
|---|---|---|
| R-1 | No capture of Arc's panel or editor: layout values are guesses. | Every value is one token in `SiteControlTokens.swift`. This PR adds capture rows #21 (Boost editor) and #22 (full Site Control Center, hover and ⋯ menu, Option held) to `docs/re/runtime-observations.md` §7; #19 already covers a first look. After a user records them, run §8.3. |
| R-2 | CSS filters cannot tint white backgrounds the way Arc's palette remap does, so the wheel looks weak on white sites. | §4.4 "pull" math moves the page's own hue and keeps the center at identity; the neutral-page hint points to Invert lightness. Q4 asks the lead about a tint component. |
| R-3 | Live preview through `evaluateJavaScript` per frame could cost the renderer. | ≤ 60 Hz, bound page only, plans are small (CSS text + numbers); the applier is rAF-throttled. Bench in Step 5 on a heavy page; drop to 30 Hz if the page frame time grows > 4 ms. |
| R-4 | Main-world picker and applier before P7 leak Boost state to page scripts. | Zap stays disabled until P7 (app-shell D8); live preview of CSS/filters in the main world is acceptable (the page can already see its own styles). |
| R-5 | Users lose a Boost by closing a new one quickly. | Only an unchanged new Boost is deleted (F16). |
| R-6 | The in-window overlay must stay above web content in every layout (split, full screen, hover-reveal sidebar). | Reuse the command bar overlay container order; render states `scc-pane-anchor` and a full-screen e2e check. |

### 11.2 Open questions (need a lead decision; recommendation first)

| # | Question | Recommendation |
|---|---|---|
| Q1 | Panel host: in-window overlay (D-3) or `NSPopover` with a custom background? | Overlay. Keeps Arc's look on macOS 26, keeps the window key, matches the command bar. |
| Q2 | Developer Mode row (`toggle-developer-mode`, Ctrl+D, exists in the registry): ship the per-site Developer Mode feature (Arc's tool bar with console, network, inspect, and a store like `StorableDeveloperModeState.json`) in v1? | No. Hide the row in v1; plan Developer Mode separately if wanted. The command stays a no-op toast "Developer Mode is not available yet." |
| Q3 | Preview row (per-site sidebar Preview): show it? | Hide until the Previews feature (settings plan G-3) has per-site state; then add the row with its own store. |
| Q4 | Color: keep filters only (this plan), or add a `tint` component (multiply overlay) so white pages take the hue? | Filters only for v1 (no runtime change, no compositing cost). Re-evaluate with captures; if the lead wants tint, add it as a separate OpenBoosts runtime step with a scroll-performance gate. |
| Q5 | Show the blocked-request count on the ad-block tile (adblock-design asked for it; Arc shows only On/Off)? | No (Arc parity). Keep the count for automation and debug info. |
| Q6 | Disable Boost editing in incognito (D-10)? | Yes. |
| Q7 | After a tile change: reload row (this plan), auto-reload on close, or nothing? | Reload row. It never surprises and works for permissions and ad blocking alike. |
| Q8 | Option key in the panel (Arc tracks it; purpose unknown). | Ignore in v1; revisit with capture #22 (Option held). |
| Q9 | Ad-block path mismatch: `ProfileDirectories.adBlockListsDirectory` (`Profiles/<dataDirectoryName>/AdBlock/lists`) vs `AdBlockStore` (`Profiles/<UUID>/adblock/`). | Ad-block owner picks one (recommend `AdBlockStore`'s, it is the code that writes) and removes the other helper. This plan only calls `AdBlockStore`. |
| Q10 | Zap list placement: in the editor (this plan) or Arc-style shelf over the page bottom? | In the editor. The in-page picker bar already sits at the page bottom; a second strip there would overlap it. Revisit with capture #21. |
| Q11 | Arc binds Cmd+E to a hidden "Open Extensions" item that opens the extension picker (extensions-UI planner's finding), but Open's registry binds Cmd+E to `use-selection-to-find`. Which wins? | Owned by the extensions-UI plan. This plan only provides `present(anchor:tabID:mode: .extensionPicker)` (§3.6.1). |

## Appendix A — New tokens (`OpenDesign/SiteControlTokens.swift`)

```swift
public enum SiteControlMetrics {          // §3; all guess unless a section cites evidence
    public static let width: CGFloat = 320, maxHeight: CGFloat = 640, cornerRadius: CGFloat = 16
    public static let sidebarPanelGap: CGFloat = 13, panePanelGap: CGFloat = 11
    public static let anchorAlignmentY: CGFloat = 24, actionButtonInsetY: CGFloat = 0
    public static let inset: CGFloat = 14, headerHeight: CGFloat = 48, actionRowHeight: CGFloat = 44
    public static let actionButton = CGSize(width: 44, height: 36), actionGap: CGFloat = 4, actionRadius: CGFloat = 8
    public static let sectionHeaderHeight: CGFloat = 28, sectionBottomPadding: CGFloat = 10
    public static let tile = CGSize(width: 142, height: 48), tileGap: CGFloat = 8, tileRadius: CGFloat = 10, tileIcon: CGFloat = 28
    public static let boostRowHeight: CGFloat = 40   // extension item metrics belong to OpenExtensionsUI (§3.6)
    public static let footerHeight: CGFloat = 44, reloadRowHeight: CGFloat = 32
    public static let shadowOpacity: Float = 0.25, shadowRadius: CGFloat = 16, shadowOffsetY: CGFloat = 6
}
public enum BoostEditorMetrics {          // §4
    public static let width: CGFloat = 268, inset: CGFloat = 14, headerHeight: CGFloat = 52
    public static let wheelArea: CGFloat = 176, ringDiameter: CGFloat = 128, ringWidth: CGFloat = 18, padRadius: CGFloat = 46, puck: CGFloat = 24
    public static let sideButton: CGFloat = 28, sliderRow: CGFloat = 28
    public static let fontChip = CGSize(width: 56, height: 36), toolTile: CGFloat = 54, toolGap: CGFloat = 8
    public static let zapRow: CGFloat = 30, zapVisibleRows = 5
    public static let codeDefault = CGSize(width: 560, height: 640), codeMinimum = CGSize(width: 420, height: 360)
    public static let gutterWidth: CGFloat = 36, codeFontSize: CGFloat = 12, codeLineHeight: CGFloat = 16
    public static let contentInset: CGFloat = 12   // from the web panel's top-right corner
}
public enum BoostEditorColors {           // BO-22 values (facts); usage per §4 (guess)
    public static let segmentBackground = DesignColor(light: .black(0.07), dark: .white(0.10))
    public static let segmentSelection = DesignColor(light: .white(1), dark: .white(0.30))
    public static let sliderTrack = DesignColor(RGBA(hex: 0x3B3746, alpha: 0.05))
    public static let sliderTint = DesignColor(RGBA(hex: 0x017AFF))
    public static let warning = DesignColor(RGBA(hex: 0xFF5A5F))
    public static let puck = DesignColor(RGBA(hex: 0xFAFBFF))
    public static let puckPad = DesignColor(light: .black(0.04), dark: .white(0.06))
    public static let label = DesignColor(light: .white(1), dark: .black(0.80))
    public static let zapPreview = DesignColor(RGBA(hex: 0xD9D9D9))
    public static let interstitialForeground = DesignColor(RGBA(hex: 0x2E2740))
    public static let interstitialFooter = DesignColor(RGBA(hex: 0xCEDBFC))
    public static let accents: [DesignColor] = [0x300EFF, 0x55B948, 0xDD0EFF, 0xFF560E, 0xFF0E82, 0x860EFF, 0xFF0E0E, 0xF1A23C]
        .enumerated().map { DesignColor(RGBA(hex: UInt32($0.element), [1, 7].contains($0.offset) ? .displayP3 : .sRGB)) }
}
extension Motion { public static let popoverOpen: CFTimeInterval = 0.18, popoverClose: CFTimeInterval = 0.12 }
extension Typography {
    public static let siteControlTitle = FontToken(14, .semibold), sectionTitle = FontToken(12, .semibold)
    public static let tileTitle = FontToken(12, .semibold), tileSubtitle = FontToken(11, .regular)
    public static let boostRowTitle = FontToken(13, .medium), editorTitle = FontToken(14, .semibold)
}
```

## Appendix B — Strings (Arc label → Open text)

Arc labels kept verbatim (no brand): "Settings", "More", "Boosts", "Manage", "Extensions", "Block
Ads & Trackers", "On", "Off", "Allowed", "Blocked", "Enabled", "Disabled", "Secure", "Insecure",
"Share", "Copy URL", "New Boost", "Capture a portion of this page", "Capture the full page",
"Capture in Portrait Mode", "Clear Cache", "Clear Cookies", "Manage Boosts…", "New Boost…",
"Manage Extensions…", "Add Extension…", "Add Extension", "All Site Settings…", "Pin", "Unpin",
"My Boost", "Undo", "Rename this Boost…", "Rename this Boost", "Done", "Cancel", "Shuffle",
"Reset all Edits", "All Boosts…", "Delete this Boost", "Delete this Boost?", "Delete",
"Invert lightness", "Advanced color controls", "Reset to original colors", "Brightness",
"Contrast", "Original Saturation", "Change text size", "Change text case", "Click elements on
the page to Zap them", "Pick Selector", "Hide Selector Picker", "Refresh to Run", "Refresh this
Page", "Show Developer Tools", "Hide Developer Tools", "your css here", "your javascript here",
"Edit the Internet with Boosts", "Make your own!", "Nothing Boosted Yet!", "Made for".

Rewritten in Open's words: the three ad-block tooltips (§3.4), every alert body, the notices and
banners (§3.5, §4.1, §4.3, §4.8), the interstitial body (§4.9), the Library empty-state body
(§4.11). Arc's JS sharing banner and "Report Boost…" are dropped.

## Appendix — Lead decisions (2026-10-25)

- Approved as the Site Control Center and Boost editor plan.
- Q1 The panel is an in-window view, not a system popover. It keeps Arc's look (no Liquid Glass), and the window stays key.
- Q2 The Developer Mode row stays hidden until docs/plans/page-platform.md (in progress) defines Developer Mode. Then show it as that plan specifies.
- Q3 The per-site Preview row stays hidden until Previews stores per-site state.
- Q4 Colors use CSS filters only in v1. Add a tint later, and only if it passes a scroll-performance check.
- Q5 The ad-block tile shows On/Off only, with no blocked count (Arc parity).
- Q6 Boost editing is disabled in private windows.
- Q7 After a setting change, show a "Reload" row. Never reload automatically.
- Q8 Holding Option does nothing in v1. Revisit after capture #22.
- Q9 Ad-block paths: `AdBlockStore`'s path is the one path. Remove the `ProfileDirectories` duplicate in the first step that touches ad-block storage, and migrate if any file exists at the old path.
- Q10 The Zap list lives in the editor.
- Q11 Cmd+E is decided in docs/plans/extensions-ui.md.
- The engine needs E1–E6 go into the engine lead's queue after P2. The stopgaps in this plan ship first.
- Captures #21 and #22 go into the user's single combined Arc capture session.

### Round-2 lead clarifications (2026-10-26)

Long Setting tile titles wrap to two lines (baselines 19 and 33), omitting the subtitle.
Reload and global-off note baselines are row top + 20. Focus rings indicate keyboard focus only.
Fill, edge, clip and shadow use one continuous r16 path. Geometry and palette remain guesses
until capture session 2; F0137 supplies geometry only.
