# Extensions UI — implementation plan for Open (shell side of fork patches P2/P3)

Status: shell/engine implemented on main (2026-11-06), except the explicit Section 12 X-13 presenter dependency. Little Open X-19 follow-up passes nine real-App rows; the full UI suite passes 53 rows with only X-13 BLOCKED. Verification notes below map Steps 1–8 to PRs and real evidence. Reference captures and unverified global/update gates remain open. Original plan: 2026-10-25. Implementer: a coding agent with no other
context. Follow this file literally. "Open choice" means the choice is
final for v1. "guess" means no Arc capture proves the value: build the
value as written, and §12 lists the capture that will confirm or change
it. Never copy Arc's assets or code (AGENTS.md rule 1). Never show the
Arc brand in UI text; the only exception is "Import from Arc".

This plan covers the shell: where extension actions show, how they look
and behave, the popup panel, menus, prompts, keyboard shortcuts, and the
Site Control Center item component. It also states the OpenEngine API
contract that the shell needs from fork patches P2 and P3 (§7). It does
not plan fork patch code. The engine lead owns the fork.

Read first, in this order:

1. `AGENTS.md` (rules 1–10; locked decision: "Chrome Web Store
   extensions must work in v1 at Arc level").
2. `docs/engine-patches.md` (P1–P3 and the lead decisions of
   2026-10-25) and `docs/engine-api.md` (`OEBrowser`, Extensions).
3. Branch `origin/m7/ext-p1-tabstrip` (P1, engine lead):
   `Engine/OpenEngine/include/OpenEngine/OEBrowser.h`,
   `Engine/fork/src/cef/include/cef_tab_strip.h`, its `docs/engine-patches.md`
   section "Status: implemented".
4. `docs/re/features-advanced.md` §11 (the evidence for this plan,
   items EX-1 … EX-20) and §6 (Site Control Center).
5. `docs/re/arccore-engine.md` §4 and `docs/re/menus-and-hotkeys.md`
   (Extensions menu).
6. `docs/plans/app-shell.md` §2, §4.3, §4.9, §4.12, §4.13 and
   `docs/plans/m4-split-peek-littleopen.md` §3.5 (pane top bar).
7. `docs/plans/site-control-boost-editor.md` (merged in #61; it owns
   the Site Control Center popover and reuses §3.9 of this plan).
8. `docs/status.md` §3.3 gap 37 (extension shortcuts in Settings ▸
   Shortcuts; extension omnibox keywords in the command bar), covered by
   §3.14 and §6.3; `docs/suggest.md` (providers, Site Search scope) and
   `docs/re/features-core.md` §4.2 rule 4, §4.4, §4.6.

## Goal

Ship Arc's extension UI on Open's own views:

1. Pinned extension actions in the sidebar URL field and in the pane top
   bar, with Chromium's badge, title, enabled state, and icon.
2. Action popups in an Open panel anchored to the clicked button, with
   Chrome's sizing and dismissal rules.
3. The action context menu (pin, options, site access, remove, manage).
4. The Extensions menu in the menu bar, the overflow menu, and the Little
   Open Extensions button.
5. The Extensions section of the Site Control Center (shared item view)
   and the Cmd+E extension picker.
6. Install, remove, and permission prompts as Open sheets (no Chrome
   dialogs).
7. Extension keyboard shortcuts (`chrome.commands`) and Arc's own
   extension shortcut, with their place in Settings ▸ Shortcuts.
8. Extensions in the command bar: run an extension by name, and
   `chrome.omnibox` keywords as a scoped mode.

## Success criteria

- With Bitwarden, uBlock Origin Lite, and Dark Reader installed from the
  Chrome Web Store, and the `action-probe` fixture (§10.3) loaded, every
  check in §10.3 passes in the real app through the automation channel.
- A Web Store install shows Open's install sheet (§3.11), never a Chrome
  dialog or a separate window. Accept installs; Cancel does not.
- Pinned order survives quit and relaunch and is the same in every window
  of the profile. It is stored once, in Chromium's profile preferences
  (§5).
- Badge text, badge color, title, icon, and enabled state follow
  `chrome.action` calls per tab within one frame of the engine event.
- Popups open within 1 frame after the engine reports the popup ready,
  resize to content within Chrome's limits, and close on every rule in
  §3.7.
- `extensions-render` renders every surface in §3 at 1x and 2x, light and
  dark, and `extensions-render check` passes (§10.1).
- Idle cost is zero: no timers, no polling. With 20 extensions installed,
  a tab switch adds at most 1 ms of main-thread time for extension UI
  (§9).
- An omnibox keyword (`action-probe`'s "probe") enters a scoped mode in
  the command bar, shows the extension's suggestions, and sends the
  accepted text to the extension (X-22–X-25).
- Settings ▸ Shortcuts reaches `chrome://extensions/shortcuts` and shows
  extension shortcuts that Open's own shortcuts switched off (X-27).
- No unit tests (AGENTS.md rule 6).

## Non-goals (do not build)

- A native extensions management page. "Manage Extensions" opens
  Chromium's `chrome://extensions` in a tab, as Arc does (EX-5, EX-11).
- A native shortcut editor for extension commands. "Extension Shortcuts"
  opens `chrome://extensions/shortcuts` (EX-11).
- `chrome.sidePanel` hosting (EX-17). Lead question Q6.
- Crash attribution and the "disabled after a crash" alert (EX-16).
- Arc-only extras: JSON Formatter auto-install, iCloud Passwords
  install, the onboarding extensions step (EX-17).
- Pinned extensions in the Favorites tray (`AppTray.PinnedExtension…`,
  `arccore-engine.md` §4 notes): no evidence of when it shows.
- Chrome's "requests access" toolbar chips and the Views extensions menu.
  Site access lives in the action context menu, as in Arc (EX-9).
- Toolbar mode (Show/Hide Toolbar, Cmd+Shift+D) itself. This plan only
  states that its top bar reuses the pane-bar strip (§3.3).

## 0. Locked decisions and inputs (do not re-derive)

- The shell talks only to OpenEngine. OpenKit never imports OpenEngine;
  it uses the Swift protocols in `OpenWeb` (`docs/engine-api.md`).
- One Chrome window per Open window; its tab strip holds every live tab
  of that window across Spaces; the focused tab is the active tab
  (engine-patches lead decision 2). Extension action state is always the
  state for the window's active tab.
- Pinned order and pin state are Chromium's (`ToolbarActionsModel`,
  pref `extensions.pinned_extensions`). The shell keeps no copy (§5).
- Chromium draws the badge into the action image (EX-14). The shell
  draws that image as-is. Open choice: this matches Arc pixel for pixel
  because Arc uses the same Chromium code.
- System `NSMenu` for every menu (`features-advanced.md` AM-1 allows it).
- AppKit for every view in this plan. No SwiftUI.

## 1. Historical starting state (merged tree `d1720e3`, P1 branch `a03d2a5`)

| Area | What exists | File |
|---|---|---|
| M1 extension bar | A plain `NSStackView` of buttons in the M1 sidebar; click → `executeExtensionAction`; "⋯" opens `chrome://extensions`; popup in a titled floating `NSPanel` 360×480 at the button | `App/BrowserWindowController.swift` (`reloadExtensionBar`, `makePanel`, `OEBrowserDelegate` extension) |
| Engine actions | `OEBrowser.extensionActions` (`OEExtensionAction`: id, title, icon, badge text and color, enabled, has popup, popup URL); `executeExtensionAction(_:)`; `extensionPopup`; `closeExtensionPopup()`; delegate: `browserDidUpdateExtensionActions`, `didOpenExtensionPopup`, `didResizeExtensionPopup`, `didCloseExtensionPopup` | `Engine/OpenEngine/include/OpenEngine/OEBrowser.h`, `OEExtension.h` |
| P1 (branch) | Hidden Chrome window per `OEBrowser`; `chrome.tabs`/`chrome.windows` see sidebar tabs; badge text and color, title, and enabled come from Chrome's action model (`CefTabStrip::GetExtensionAction*`, `OnExtensionActionUpdated`); icon is still the manifest's; popups are still Alloy pages; popup-less actions still return NO | `origin/m7/ext-p1-tabstrip` |
| Management | `OEExtensionManager` reads Preferences and manifests; `managementPageURL`; `webStorePageURL(extensionIdentifier:)`; delegate `extensionManagerDidChange` | `OEExtension.h` |
| OpenWeb | `ExtensionActionInfo` (id, title, PNG icon, badge text, enabled, has popup); `ExtensionHost` (`extensionActions`, `executeAction`) | `Packages/OpenKit/Sources/OpenWeb/OpenWeb.swift` |
| Sidebar URL field | `URLFieldView` with Copy URL `[W−70, 49, 30, 30]` and Site Control Center `[W−42, 49, 30, 30]`, shown while a page is loaded and the pointer is over the sidebar | `Packages/OpenKit/Sources/OpenSidebar/ChromeViews.swift`, `OpenDesign/Metrics.swift` (`URLFieldMetrics`) |
| Pane top bar | `PaneChromeView`, 32 pt; Site Control Center at `[w−105, 2, 32, 28]`; host group centered; unfocused pane shows back, forward, copy, host, close | `Packages/OpenKit/Sources/OpenFeatures/PaneChromeView.swift`, `OpenDesign/FeatureMetrics.swift` |
| Little Open | Toolbar 40 pt; right buttons Profile, Downloads, Open in Space at `x = w − 100 + 32k`, 30×28 | `Packages/OpenKit/Sources/OpenFeatures/LittleOpenWindowController.swift` |
| Commands | `manage-extensions`, `add-extension` (Extensions menu); `use-selection-to-find` has Cmd+E | `Packages/OpenKit/Sources/OpenCommands/CommandRegistry.swift` |
| Automation | `extensions`, `popup`, `popup-close` | `App/Automation/AutomationController.swift`, `docs/automation.md` |
| Settings | Shortcuts pane with a "…" menu (Revert Unsaved Changes, Shortcut Help); no Extension Shortcuts item | `Packages/OpenKit/Sources/OpenSettings/ShortcutsPane.swift` (PR #51) |
| App shell | Steps A+B in progress (PRs #45, #52) replace the M1 window; §4.12 keeps the M1 extension behavior until this plan lands | `docs/plans/app-shell.md` |

## 2. Arc facts this plan uses

All from `docs/re/features-advanced.md` §11. "Strong" = several
independent pieces of evidence; "guess" = one weak piece.

| Id | Fact | Strength |
|---|---|---|
| EX-1 | Pinned actions sit in the URL field, left of Copy URL and Site Control Center, on a 28 pt pitch, and show with them on hover | position strong; hover guess |
| EX-2 | The pane top bar has an extensions area, shows as many as fit, and has a more button | strong (field names); order of dropping guess |
| EX-3 | Little Arc has one "Extensions" button | strong |
| EX-5 | Menu bar Extensions menu: one item per extension (16×16 icon, enabled state), then Manage Extensions…, Add Extension… | strong |
| EX-6–8 | Site Control Center: section "Extensions", hover "Manage", items with pin button ("Pin"/"Unpin"), "Add Extension" item, footer menu order | strong |
| EX-9 | Site access lives in Chromium's action context menu, not in native UI | strong |
| EX-10 | Cmd+E "Open Extensions" opens the extension picker (binding `openExtensionsPicker`), hosted by the Site Control Center | key strong; picker look guess |
| EX-11 | "Extension Shortcuts" opens `chrome://extensions/shortcuts` | strong |
| EX-12–13 | One popup manager per window; action updates are batched | strong |
| EX-14 | Badge is baked into the action image by Chromium | strong |
| EX-15 | Prompts are window sheets with Arc's own text | strong |
| EX-19 | The command bar has a result source for extension omnibox keywords; the engine runs Chromium's keyword path | strong (source name, selectors); look guess |
| EX-20 | The command bar can run an extension's action by name | strong (strings); row look guess |

## 3. Surfaces

All coordinates are points, origin top-left (flipped views). `W` is the
sidebar width; `w` is a pane width. New metrics go in a new file
`Packages/OpenKit/Sources/OpenDesign/ExtensionsMetrics.swift` (enum
`ExtensionsMetrics`) and new colors in `ExtensionsRole` in the same file.
Every value below names its token.

### 3.1 Action button (one anatomy everywhere)

View: `ExtensionActionButton` (`OpenExtensionsUI`, §8).

| Property | Value | Token / evidence |
|---|---|---|
| Image | The engine's `toolbarImage`: 28×28 pt, with the 16 pt icon centered and Chromium's badge at the bottom right (14 px tall, ≥ 14 px wide, at most 23 px of text, corner radius 4, 1 px cut-out); grayscale when disabled; blocked-action ring when the extension wants to run | `ExtensionsMetrics.iconArea = 28×28`, `actionIconSize = 16` (Chromium `kDefaultIconAreaSize`, `ExtensionAction::ActionIconSize()`); EX-14 |
| Drawing | Draw the image at its frame center, no tint, no scaling. Use the image rep that matches the backing scale (the engine supplies 1x and 2x). | — |
| Hover plate | The button frame, corner radius 6, `SidebarRole.buttonHover` (`GrayA4`); pressed `SidebarRole.buttonPressed` (`GrayA6`); fade `Motion.hoverFade` (0.08 s) | `ChromeMetrics.buttonPlateRadius`; same as the URL field accessories |
| Popup open | The plate stays at `buttonPressed` while this action's popup is open | Chrome toolbar behavior; Arc guess |
| Tooltip | Open's capsule tooltip (`Tooltip`, `TooltipMetrics`): title = `tooltip` from the engine; keycaps = the `_execute_action` shortcut, if any | Open choice (Open tooltips show shortcuts) |
| Click (enabled) | `execute(id, source: .toolbarButton)` | Chrome `ToolbarActionView::ButtonPressed` |
| Click (disabled) | Show the action context menu (§3.6) at the button | Chrome: "If the action isn't enabled, show the context menu as a fallback" (`toolbar_action_view.cc`) |
| Second click while its popup is open | Close the popup (`closeExtensionPopup`) | Chrome toggle; engine-api.md |
| Right click, Ctrl-click | Action context menu (§3.6) | EX-1 `onRightClickExtensionButton` |
| Drag | Horizontal drag in a strip reorders pinned actions: 3 pt threshold, the button follows the pointer, the others slide with `Motion.rowStructure` (0.22 s); drop calls `movePinned(id, to:)`; Esc or a drop outside the strip cancels | EX-2 `onDidMoveExtensionToIndex`; slide timing Open choice |
| Accessibility | Role button; label = `accessibleName` (Chromium adds the badge text); identifier `extensionAction.<extensionID>` | — |

### 3.2 Sidebar URL field strip

Owner: `URLFieldView` (`OpenSidebar`) hosts one `ExtensionStripView`
(`OpenExtensionsUI`) in `.urlField` style.

Layout in sidebar coordinates. The URL field is `[8, 46, W − 16, 36]`.

| Element | Frame | Token |
|---|---|---|
| Site Control Center (exists) | `[W − 42, 49, 30, 30]` | `URLFieldMetrics` |
| Copy URL (exists) | `[W − 70, 49, 30, 30]` | `URLFieldMetrics` |
| Extension slot `i` of `n` (`i = 0` is the leftmost) | `[W − 70 − 28·(n − i), 49, 30, 30]` | `URLFieldMetrics.accessorySize` (30), `.accessoryPitch` (28); EX-1 |
| Host text right edge | leftmost slot `minX − 2` (today: Copy URL `minX − 2`) | existing rule |

At `W = 228` with 3 pinned: slots at x 74, 102, 130.

Rules:

1. Order: slots show pinned actions in pinned order, left to right (EX-1:
   the enum order puts pinned actions first). guess: the first pinned is
   leftmost.
2. Fit: `nMax = floor((W − 70 − (hostX + hostMinimum + 2)) / 28)` with
   `hostX = 20` (`URLFieldMetrics.hostX`) and `hostMinimum = 44`
   (`ExtensionsMetrics.urlFieldHostMinimum`; guess: about 4 characters).
   That is `floor((W − 136) / 28)`: 3 at 228, 5 at 300, 13 at 500.
3. Overflow: when `pinnedCount > nMax`, show `nMax − 1` pinned actions
   and a more button in the leftmost slot. The more button is a
   `PlateButton` with glyph `.extensionsMore` (SF Symbol `ellipsis`,
   13 pt bold; same spec as `.spaceMore`), tooltip "More Extensions". It
   opens the overflow menu (§3.5.2) below itself. EX-2 proves a more
   button for the pane bar; using it here is a guess.
4. Visibility: the strip shows and hides with Copy URL and Site Control
   Center (`URLFieldView.showsButtons` and `hasPage`; EX-1, guess). It
   also stays visible while any of these is true: a popup that it
   anchors is open; its context menu or overflow menu is open; a drag is
   in progress. When the strip is hidden, its buttons are hidden (not
   just transparent), so they take no clicks and no AX focus.
5. No page: the strip is hidden (no tab means no action target).
6. Peek: while a Peek shows, the URL field shows the Peek page's host
   (`interaction-states.md` §12). The strip still shows the window's
   active tab state (the Peek page is not a tab in Chromium's strip).
   guess.
7. Split View: the URL field strip shows the focused pane's state (it is
   the active tab). The focused pane's top bar (§3.3) shows the same
   actions. Both stay. guess: Arc shows both.

### 3.3 Pane top bar strip (Split View; toolbar mode later)

Owner: `PaneChromeView` (`OpenFeatures`) hosts one `ExtensionStripView`
in `.paneBar` style. Only the focused pane shows it (an unfocused pane
shows back, forward, copy, host, close: F0081). Toolbar mode, when it is
planned, reuses this strip in its single top bar.

Layout in pane-bar coordinates (`w` = pane width, bar height 32,
`SplitMetrics.barHeight`):

| Element | Frame | Token |
|---|---|---|
| Site Control Center (exists) | `[w − 105, 2, 32, 28]` | `PaneChromeView` |
| Extension slot `i` of `n` | `[w − 105 − 28·(n − i), 2, 28, 28]` | `ExtensionsMetrics.paneSlot = 28×28`, pitch 28 |
| Host group right limit | leftmost slot `minX − SplitMetrics.barControlGap` (4) | M4 code |

Fit (EX-2: the domain gets room before the extensions):

1. `left = reload.maxX + barControlGap` (115). `right = w − 105`.
2. `hostReserve = 2·SplitMetrics.hostSlot + clamp(hostTextWidth + 4, SplitMetrics.hostMinimumWidth, 160)`
   (50 + 28…160). The 160 pt cap is `ExtensionsMetrics.paneHostCap`
   (guess).
3. `nMax = floor(max(0, right − left − hostReserve) / 28)`.
4. Overflow as §3.2 rule 3. If `nMax = 0` and at least one action is
   pinned, show only the more button when `right − left − (50 + 28) ≥ 28`
   (the host shrinks to its minimum first); else show nothing (the Site
   Control Center still lists every extension).
5. Plates draw over the pane's page color: `buttonHover`/`buttonPressed`
   as in §3.1 (the bar is light in every capture; dark page colors use
   the same `DesignColor` dark values, guess).

Examples: `w = 984` with a host at the 160 pt cap → 19 slots; `w = 600`
with a 120 pt host → 7 slots; `w = 400` with a 120 pt host → 0 slots,
more button only.

### 3.4 Little Open toolbar

**Lead update 2026-11-05 22:32:** Section 9 now owns a 47 pt title bar.
The Extensions button is inside its URL capsule, left of Copy URL. Its
glyph/hit frame is `[w − 252, 16, 16, 16]`, matching Copy URL's button
style, with `LittleOpenMetrics.text` and symbol `puzzlepiece.extension`.
While shown, host text ends at `extensions.minX − hostGap`; when hidden,
the existing layout is unchanged. It shows for at least one action and
uses the same menu and popup anchor below. This replaces the original frame
and URL-field width. **guess (lead), capture S-7.**

Owner: `LittleOpenWindowController`. Add one `PlateButton`-style button
"Extensions" (EX-3):

- Frame `[w − 252, 16, 16, 16]`, inside the 47 pt title bar's URL capsule,
  left of Copy URL. Host text ends at `extensions.minX − hostGap`.
  This supersedes the original `[w − 132, 6, 30, 28]` plan.
  **guess (lead), S-7.**
- Glyph `.extensions`: SF Symbol `puzzlepiece.extension`, 16 pt regular,
  tint `LittleOpenMetrics.text`. Our glyph, not Arc's `ExtensionsIcon`
  asset.
- Tooltip "Extensions".
- Shown only when the window's profile has at least one action (Arc
  fields `shouldDisplayExtensionsButton`, `shouldRenderExtensionsButton`,
  EX-2/EX-3; guess for the rule).
- Click: the Little Open extensions menu (§3.5.3) below the button.
  Choosing an item runs the action with source `.menuEntry`; its popup
  anchors to this button.

### 3.5 Menus

All menus are `NSMenu`, built by `ExtensionsMenuBuilder` (§8). Item icons
are the engine's `icon` (16×16 pt, no badge; EX-5: `0x4030…` = 16.0).

#### 3.5.1 Menu bar "Extensions"

Order (EX-5):

1. One item per action of the key window's `OEBrowser`: pinned actions in
   pinned order, then unpinned actions by extension name
   (`localizedStandardCompare`). Title = extension name. Image = `icon`.
   Enabled = action enabled for the active tab. Action: run with source
   `.menuEntry`; its popup anchors per §3.7 rule A4.
2. Separator (only when step 1 added items).
3. "Manage Extensions…" (`manage-extensions`), "Add Extension…"
   (`add-extension`), as today.

Build the injected items in `menuNeedsUpdate(_:)` only (no work while the
menu is closed). Remove the previous injected items first (Arc does the
same: `injectedMenuItems`).

#### 3.5.2 Overflow menu (strip more button)

1. The pinned actions that did not fit, in pinned order, then a
   separator.
2. Unpinned actions by name (enabled items run the action; this is the
   only strip path to an unpinned action besides the Site Control
   Center).
3. Separator, "Manage Extensions…", "Add Extension…".

Popups from this menu anchor to the more button.

#### 3.5.3 Little Open extensions menu

Same as §3.5.2 with all pinned actions in step 1.

### 3.6 Action context menu

Source: Chromium's `ExtensionContextMenuModel` through the engine (§7
E7). The shell renders the model as an `NSMenu` and sends the chosen
command back. It does not add or reorder items. It relabels these titles
(brand rule; Arc's own labels are not in the binary, §12 S-6):

| Chromium title | Open title |
|---|---|
| "Remove from Chrome…" | "Remove from Open…" |
| "Pin to Toolbar" | "Pin" |
| "Unpin from Toolbar" | "Unpin" |
| any other title | unchanged: it can hold the extension's name or its own `chrome.contextMenus` items, and the engine already brands Chromium's strings (patch 0509) |

"Pin"/"Unpin" match Arc's own pin tooltips (EX-6). Open choice until
S-6 shows Arc's labels.

Expected items (Chromium 156, `ExtensionContextMenuModel::MenuEntries`):
extension name (opens its home page or Web Store page), separator,
"This Can Read and Change Site Data ▸" (radio items "When You Click the
Extension", "On <host>", "On All Sites", then "Learn More About Site
Access") or the disabled "Can't Read or Change Site's Data", "Options"
(when the extension has an options page), "Remove from Open…",
"Pin"/"Unpin", "Manage Extension", "View Web Permissions", and "Inspect
Popup" (developer mode and popup actions only). Site access changes need
no shell code: Chromium applies them and the action state updates.

Command results the shell must handle:

- "Remove from Open…" → the engine asks for the remove sheet (§3.11).
- "Options", "Manage Extension", home page → the engine opens a tab
  through P1 (`browser(_:didOpen:active:)`); the shell adopts it as a
  selected Today tab (app-shell §4.13).
- "Inspect Popup" → DevTools window (engine); the popup stays open while
  DevTools is attached (§3.7 D1, `extensionPopupStaysOpenOnBlur`).

### 3.7 Popup panel

View: `ExtensionPopupPanel` (`OpenExtensionsUI`), one per window
(EX-12). The engine owns the popup page; the shell owns the panel.

Window:

| Property | Value |
|---|---|
| Class | `NSPanel` subclass, style `[.borderless]`, `canBecomeKey = true`, `canBecomeMain = false`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false` |
| Parent | Child window of the browser window (`addChildWindow(_:ordered: .above)`), so it moves, hides, and orders with it |
| Shape | Content view layer: corner radius `ExtensionsMetrics.popupCornerRadius = 10` (guess; same as `URLFieldMetrics.cornerRadius`), `cornerCurve = .continuous`, `masksToBounds = true`; panel `backgroundColor = .clear`, `isOpaque = false` |
| Edge | 0.5 pt inner stroke `ExtensionsRole.popupStroke` = `SidebarColors.tabListOverlapBorder` (black 0.05 / white 0.05) so a white popup stays visible over a white page (guess) |
| Shadow | System window shadow (`hasShadow = true`); call `invalidateShadow()` after every resize |
| Content | `popup.view` fills the content view (autoresizing width and height). Set `popup.delegate` to the window's page delegate so dialogs, context menus, downloads, and new tabs work as in any page |

Placement (A rules):

- A1. Anchor = the frame of the clicked button in screen coordinates.
- A2. The panel's top edge is `ExtensionsMetrics.popupGap` (6 pt, guess;
  M1 used 4) below the anchor's bottom edge. The panel's left edge is the
  anchor's left edge.
- A3. Clamp to the anchor screen's `visibleFrame` inset by
  `ExtensionsMetrics.popupScreenMargin` (8 pt): move left if the right
  edge overflows; if the panel does not fit below, put its bottom edge
  6 pt above the anchor's top edge when that side has more room.
- A4. Anchor when the click did not come from a visible button (menu bar
  item, `_execute_action` shortcut, `chrome.action.openPopup()`, Cmd+E
  picker): the action's visible slot in the focused pane bar, else in the
  URL field strip (force the strip visible), else the URL field's Site
  Control Center button (force it visible), else (sidebar hidden) a 1×1
  point at `(contentPanel.minX + 16, contentPanel.minY + 8)`. Open choice.

Size:

- S1. Size = the size the engine reports
  (`browser(_:didResizeExtensionPopup:to:)`), clamped to
  `ExtensionsMetrics.popupMinimum` 25×25 … `popupMaximum` 800×600
  (Chromium `kExtensionPopupMinSize`/`kExtensionPopupMaxSize`,
  `chrome/browser/ui/extensions/extension_popup_types.h`), then clamped to
  the space left by A3. A popup that wants more scrolls inside.
- S2. Resize keeps the top-left corner fixed (it grows down and right),
  then re-applies A3. No animation (Chrome has none; fewer frames).
- S3. The popup shows only when the engine reports it ready (§7 E6:
  Chrome shows its bubble after the popup's first load stops). Until
  then the panel is ordered front at `alphaValue = 0` with
  `ignoresMouseEvents = true` and is not key: the page view is in a
  visible window, so Chromium creates, lays out, and does not throttle
  it. On ready: alpha 1, accept mouse events, make key (F1). The button
  shows the pressed plate from the click on.
- S4. If the popup is not ready after 10 s (seen under load in the
  spike), show it anyway at its last size (at least 25×25).

Focus:

- F1. On show, make the panel key and call `popup.focusPage()`. The
  browser window stays main.
- F2. Keys while the panel is key: the popup's delegate sees them first
  (`webContent(_:handleKeyEventBeforePage:)`, as for a tab), then the page,
  then `webContent(_:handleUnconsumedKeyEvent:)`. Esc closes the popup
  inside Chrome (`ExtensionViewHost`). Cmd+W in the before-page call closes
  the popup, not the tab (guess); the debug shell does this today. Every
  other app shortcut goes through `OEApplication.keyEquivalentHandler` and
  the main menu as usual and acts on the browser window.

Dismissal (D rules; Chrome `ExtensionPopup` behavior unless marked):

- D1. The panel resigns key to anything else (another Open window, the
  browser window, another app) → close, unless
  `browser.extensionPopupStaysOpenOnBlur` is true at that moment: a
  JavaScript dialog, a web-modal dialog of the popup (a WebAuthn or
  passkey request), or DevTools on the popup ("Inspect Popup") is showing
  (Chrome's `CloseUnlessBlockedByInspectionOrJSDialog`). The shell adds
  its own JavaScript dialogs for tabs. Closing then would drop the
  dialog's request (a Bitwarden passkey request).
- D2. Click on the same action button → close. Click on another action →
  the engine closes the first and opens the second.
- D3. Esc → the engine closes the popup (`ExtensionViewHost`).
- D4. `window.close()` in the popup → the engine reports
  `didCloseExtensionPopup`.
- D5. The window's active tab changes (tab switch, Space switch, focused
  pane change) → close. The engine closes the popup itself when
  Chromium's active tab changes (Chrome's `ExtensionPopup`); the shell
  still closes it for a change that does not reach the strip.
- D6. The browser window closes, miniaturizes, or enters or leaves full
  screen → close.
- D7. The sidebar hides (Cmd+S) while the anchor is in the sidebar →
  close (guess).
- D8. The app deactivates → close (follows from D1).
- Closing always means `browser.closeExtensionPopup()`. The shell
  removes the view and orders the panel out only on
  `didCloseExtensionPopup`.

Multiple windows: each window has its own panel and at most one popup
(the engine allows one per `OEBrowser`). D1 makes two open popups
impossible in practice. A popup never moves to another window.

### 3.8 Extension popup windows (`chrome.windows.create({type: "popup"})`)

Bitwarden's "pop out" and similar flows open a small window (EX-12;
Arc `BrowserExtensionWindow` with an autosaved frame). E11 now covers
this on main ([#184](https://github.com/SergeSerb2/open/pull/184)); the original
P1 Chrome Views window gap is closed. Engine contract: E11 (§7).

Shell: `ExtensionWindowController` (App). A standard titled window
(`.titled, .closable, .miniaturizable, .resizable`), title = page title,
content = the page view, no sidebar, no toolbar. Initial frame = the
requested frame if the extension gave one, else 400×600 centered on the
parent window. `setFrameAutosaveName("ExtensionPopupWindow")` (AppKit's
own default; Open choice: one autosave name, as Arc has one key).
Closing the window closes the page; `chrome.windows.remove` closes the
window.

### 3.9 Site Control Center Extensions section and the shared item view

The Site Control Center popover, its section headers, its footer menu,
and its order of sections belong to `docs/plans/site-control-boost-editor.md`.
This plan defines the two views that plan reuses for SC-4.

Coordination (2026-10-25, agreed with that plan's author; it is on main as #61 and uses these names in its §3.6, §3.6.1, and E4): `OpenExtensionsUI`
owns the section body, the items, pin order, and the intents. The SCC
plan owns the section header ("Extensions", hover "Manage" →
`manage-extensions`), section order, the panel, the footer menu, and the
entry point `SiteControlController.present(anchor:tabID:mode:)` with
`SiteControlPresentationMode.extensionPicker` (its §3.6.1). It hides the
section until `OpenExtensionsUI` lands and builds no second grid. Rules
for implementers: one extension item view exists, `ExtensionItemView`;
the engine request names in §7 of this plan (E4, E7) are the ones the
engine lead implements; the "Add Extension" item opens Arc's URL
`https://chromewebstore.google.com/category/extensions` (§3.12). The
Cmd+E conflict is this plan's Q1 (the SCC plan's Q11 defers to it).

#### 3.9.1 `ExtensionItemView` (shared)

One extension. Input: `ExtensionItem` (OpenWeb, §8.2). Output:
`ExtensionItemIntent` (`.run(id, anchor: NSView)`, `.togglePin(id)`,
`.contextMenu(id, anchor: NSView, event: NSEvent?)`). Two styles (EX-7).
Every size here is a guess until §12 S-5.

`.row` style:

| Element | Frame (item coordinates, width `iw`) | Token |
|---|---|---|
| Item | height 32 | `ExtensionsMetrics.itemRowHeight` |
| Hover fill | `[0, 0, iw, 32]`, radius 6, `SidebarRole.buttonHover` | — |
| Image | `toolbarImage` at `[2, 2, 28, 28]` (badge shows) | `iconArea` |
| Name | x 36, baseline 21, width to the pin button − 6, 13 Regular, tail truncation, color `Core.foregroundPrimary` | `Typography.extensionName = FontToken(13, .regular)` (new) |
| Pin button | `[iw − 28, 4, 24, 24]`, glyph `pin` (unpinned, shown on hover) or `pin.fill` (pinned, always shown), 12 pt, tint `SidebarRole.toolbarGlyph`; tooltip "Pin" / "Unpin" (EX-6) | `ExtensionsMetrics.itemPinButton = 24` |
| Disabled action | name color `Core.foregroundSecondary`; the image is already grayscale | — |

`.tile` style:

| Element | Frame (tile 44×44) | Token |
|---|---|---|
| Tile | 44×44, radius 8, resting fill none, hover `SidebarRole.buttonHover` | `ExtensionsMetrics.itemTile = 44` |
| Image | `toolbarImage` at `[8, 8, 28, 28]` | — |
| Pin mark | 14×14 circle at `[30, 0, 14, 14]`, fill `Core.backgroundPrimary`, glyph `pin.fill` 8 pt; shown when pinned; on hover the circle shows `pin`/`pin.fill` and becomes the pin button | guess |
| Tooltip | extension name, then the action tooltip on a second line when it differs | `Tooltip` two-line |

Shared behavior (both styles):

- Click → `.run(id, anchor: self)` with source `.menuEntry`. The Site
  Control Center closes first (owned by that plan); the popup anchors per
  §3.7 A4 (the item view is gone). guess: §12 S-5.
- Right click → `.contextMenu` (§3.6).
- Pin button → `.togglePin(id)`; the strip updates from the engine event,
  not from local state.
- Focus ring (picker mode, §3.10): 2 pt `Core.focusRing`, outside the
  item, radius = item radius + 2.
- Accessibility: role button, label = `accessibleName`, custom action
  "Pin"/"Unpin".

#### 3.9.2 `ExtensionsSectionBody` (shared)

The section body under the Site Control Center's "Extensions" header
(header text "Extensions", hover text "Manage" → `manage-extensions`;
EX-6; the header view itself belongs to the SCC plan).

- Content: every action of the window's `OEBrowser` (§3.5.1 order:
  pinned first in pinned order, then unpinned by name), then the "Add
  Extension" item (glyph `plus`, label and tooltip "Add Extension",
  runs `add-extension`; EX-6).
- Layout: `.row` items in one column when there are at most 4 extensions;
  `.tile` items in a grid otherwise, 5 columns, 4 pt gaps, left-aligned
  (EX-7 proves both layouts exist; the switch rule and the column count
  are guesses, §12 S-5).
- Empty (no extensions): only the "Add Extension" row.
- Height: the body reports its intrinsic height; the SCC plan sizes the
  popover.
- Picker mode: §3.10.

### 3.10 Extension picker (Cmd+E)

Command `open-extensions-picker` (§6). EX-10.

1. Cmd+E calls `SiteControlController.present(anchor:tabID:mode:)`
   (target `OpenSiteControl`, `site-control-boost-editor.md` §3.6.1) with
   `mode: .extensionPicker`, the focused tab, and the anchor rule of that
   plan: `.urlField` when the sidebar shows, else `.paneBar(<pane tab>)`
   for a focused split pane, else `.contentTopLeading`.
2. Picker mode: `focusedID` = the first pinned action, else the first
   item. Arrow keys move focus (rows: up/down; grid: all four, wrapping
   to the next row). Typing letters moves focus to the first item whose
   name starts with the typed text (type-select; resets after 1 s).
   Return runs the focused item (§3.9.1 click). Esc closes the SCC.
   Cmd+E again closes it (toggle).
3. No page loaded → the command beeps (`NSSound.beep()`) and does
   nothing (the SCC needs a site).
4. With no extensions, the SCC opens in `.standard` mode (the SCC
   plan's rule).

### 3.11 Install, remove, and permission prompts

View: `ExtensionPromptView` in an `ExtensionPromptSheet`
(`OpenExtensionsUI`): an `NSPanel` subclass with style `.borderless`
and `hasShadow = true`, shown with `beginSheet(_:)` on the window of the
requesting page (EX-15: Arc's `Dialogs.SheetWindow`). Our own shape, not
the system sheet look (locked decision: Arc's look, not Liquid Glass). One sheet
at a time per window; later prompts wait in a FIFO queue. A prompt with
no window (for example from a background service worker) uses the key
browser window of the same profile, else the frontmost browser window.

Text (Arc's text with the Open brand, EX-15):

| Prompt (Chromium type) | Title | Buttons (default last) |
|---|---|---|
| Install (`INSTALL_PROMPT`, `EXTERNAL_INSTALL_PROMPT`, `REMOTE_INSTALL_PROMPT`) | "Add <name> extension to Open?" | "Cancel" (Esc), "Add Extension" (Return) |
| Repair (`REPAIR_PROMPT`) | Chromium's title (`GetDialogTitle`) with the brand rule | Chromium's labels (`GetAbortButtonLabel`, `GetAcceptButtonLabel`) |
| More permissions (`PERMISSIONS_PROMPT` for `chrome.permissions.request`, `RE_ENABLE_PROMPT` after an update) | "The extension <name> has requested additional permissions" | "Deny" (Esc), "Allow" (Return) |
| Remove (uninstall dialog) | "Remove <name> extension from Open?"; when another extension asks: Chromium's title with the brand rule | "Cancel" (Esc), "Remove Extension" (Return) |

Body: "It can:" (13 Semibold) and one bullet per permission message
(Chromium `GetPermission(i)`), each with its details indented below; or
"This extension requires no special permissions." when there are none
(EX-15). Remove and Repair have no body.

Layout (our own dialog; values are guesses until §12 S-4):

| Element | Value | Token |
|---|---|---|
| Sheet | width 420, padding 24, background `Core.popoverBackground`, corner radius 12 | `ExtensionsMetrics.promptWidth`, `.promptPadding`, `.promptCornerRadius` |
| Icon | extension icon 48×48 at `[24, 24]` | `.promptIcon` |
| Title | x 88, top 24, width 308, 15 Semibold, up to 3 lines, `Core.foregroundPrimary` | `Typography.promptTitle = FontToken(15, .semibold)` |
| Body | below the icon and title block + 16; "It can:" 13 Semibold; bullets 13 Regular, bullet 4 pt dot at x 4, text x 16, 6 pt between bullets; details 12 Regular `Core.foregroundSecondary`, indent 16 | `Typography.promptBody`, `.promptDetail` |
| Scroll | body scrolls when taller than 240 | `.promptBodyMaxHeight` |
| Buttons | bottom right, 24 pt from the edges; height 28, corner radius 8, min width 88, gap 8; default button fill `Core.brandBlue`, text white 13 Medium; other button fill `SidebarColors.itemBackground`, text `Core.foregroundPrimary`; each shows its key hint ("esc", "↩") in `Typography.keycap` at 0.6 opacity after the label (Arc `ButtonHotkeyHint`) | `.promptButtonHeight` |

Behavior:

- Return = default button, Esc = the other. Closing the window or
  quitting = Cancel/Deny.
- Answer exactly once (`accept()`/`cancel()`); a released prompt cancels
  (engine rule, §7 E10).
- After an install by the user, show a toast (app-shell §3.7) "Added
  <name>" for 3 s (guess; §12 S-8). If the extension has an action and
  is not pinned, the toast has a "Pin" button that calls `setPinned`.

### 3.12 Manage Extensions, Add Extension, page context menu

- `manage-extensions`: select the existing `chrome://extensions` tab in
  the focused Space if there is one, else open it as a new selected
  Today tab (Chrome's singleton-tab rule; Arc opened `arc://extensions`,
  displayed as `open://extensions` by the display-only alias). The page renders because P1 tabs are Chrome
  style.
- `add-extension`: open `https://chromewebstore.google.com/category/extensions`
  (the URL string in Arc's binary, `.re/extensions-ui/ext-strings.txt`)
  as a new selected Today tab.
- "Extension Shortcuts": Settings › Shortcuts
  (`Packages/OpenKit/Sources/OpenSettings/ShortcutsPane.swift`, merged in
  #51) gets a menu item "Extension Shortcuts" in the pane's "…" menu,
  after "Shortcut Help" (Arc also has it as a menu item there). It calls `SettingsActions.openURL(chrome://extensions/shortcuts,
  profileID: <selected profile>)`; the App's `openURL` applies the
  singleton rule for `chrome://extensions*` URLs (EX-11). The code-only command
  `extension-shortcuts` does the same from the command bar.
- Page context menu: append "Manage Extensions" (EX-18) after the last
  extension-contributed item when the page menu has any; otherwise do not
  add it (guess: §12 S-9). Owner: the page context-menu builder
  (app-shell §4.9).

### 3.13 Errors, disabled extensions, and lifecycle

| Event | UI |
|---|---|
| Extension disabled (user, policy, or permissions increase) | Its action leaves every strip and menu (Chromium removes it from `ToolbarActionsModel`). A permissions increase also queues the More permissions prompt (§3.11). |
| Extension uninstalled | Same as disabled; an open popup of it closes (engine). |
| Unpacked load failed (developer use) | Toast "Couldn't load extension" + Chromium's message on a second line, 6 s (guess). |
| Action disabled for this tab | Grayscale image (engine); click opens the context menu (§3.1). |
| Extension wants to run (site access "on click" with blocked scripts) | Chromium's ring in the image (engine); click runs the blocked scripts (Chromium `ExecuteUserAction`). |
| Popup page crashed | The popup closes (engine `didCloseExtensionPopup`). No sad view in the panel. guess. |
| Extension system not ready yet (early launch) | Strips are empty and take no space; they fill on the first `browserDidUpdateExtensionActions`. |

### 3.14 Command bar: extension actions and omnibox keywords (status gap 37)

Owner: `OpenSuggest` (providers) and `OpenCommandBar` (scope chip,
intents). Both stay engine-free: they use the protocol
`ExtensionCommandBarSource` (§8.5), which the App implements over the
engine.

#### 3.14.1 Run an extension by name (EX-20)

- Provider `ExtensionActionsProvider` (local, synchronous, < 0.2 ms with
  50 extensions). Only outside a scope.
- Source data: the key window's action list (E1), enabled actions only.
- Match: the query against the extension name with the same folding and
  match quality as browser actions (`docs/suggest.md` "Match quality").
  Score: the actions weight (`docs/suggest.md` "Score").
- Row: kind `.extensionAction` (new), title = extension name, subtitle
  "Extension" (guess), icon `IconHint.extension(id)` (new; the command
  bar draws the engine's 16 pt `icon` through a provider closure, like
  favicons), trailing keycaps = the `_execute_action` shortcut if any.
- Return: the bar closes, then intent `.runExtensionAction(id)`: the
  action runs with source `.menuEntry`; its popup anchors per §3.7 A4.

#### 3.14.2 Omnibox keywords (`chrome.omnibox`, EX-19)

An extension with `"omnibox": {"keyword": "…"}` in its manifest gets a
scoped mode in the command bar. It works like Site Search (FC §4.6
rule 15; `docs/suggest.md` §7), so the gestures are the same:

| Step | User action | UI | Engine call (E12) |
|---|---|---|---|
| Hint | Type text that equals a keyword (folded) | The Site Search trailing hint (`CommandBarInput.trailing = .siteSearchHint(name:space:)`) with the extension's name; Space is allowed because the match is exact | — |
| Enter scope | Tab or Space | Chip with the extension's 16 pt icon and name (the Site Search chip view); placeholder `CommandBarText.siteSearchPlaceholder(name)` | `omniboxStartSession(extension)` |
| Type | Each keystroke | Row 1: the default row (the typed text; title = the extension's default suggestion with `%s` replaced, else the typed text; subtitle = extension name). Then the extension's suggestions in its order (title = description without markup, `match` ranges in semibold; subtitle = content when it differs), at most 5 rows in all (`CommandBarMetrics.maxVisibleRows`) | `omniboxInputChanged(text)` → suggestions arrive async; rows for an older text are dropped |
| Accept | Return on a row | The bar closes | `omniboxInputEntered(row content, disposition)` |
| Leave | Esc, Backspace on an empty query, closing the bar, or another window | Chip goes | `omniboxInputCancelled` (once per session) |
| Delete | Shift+Delete on a row the extension marked deletable | Row goes | `omniboxDeleteSuggestion(content)` |

Rules:

1. Disposition: a bar opened for a new tab (Cmd+T) → new foreground tab;
   a bar opened on the current tab (Cmd+L, URL field) → current tab;
   Cmd+Return → new background tab. Same mapping as the bar's existing
   `CommandBarDestination` and modifiers. The extension then navigates
   or opens tabs itself (`chrome.tabs`, P1).
2. Keywords come from the key window's profile only (E8/E12 keyword
   list, rebuilt on registry events).
3. Conflict: a keyword equal to a Site Search name or keyword loses; the
   Site Search scope wins (Open choice; Q9).
4. An extension that never answers leaves only the default row. Return
   still sends `omniboxInputEntered`.
5. Ranking inside the scope: no reranking; the extension's order is kept.
6. Recording: the command bar records nothing about extension rows in
   history (the page the extension opens is recorded as usual).

## 4. State matrix (what each surface shows)

| State | URL field strip | Pane bar strip | SCC section | Menu bar menu | Little Open |
|---|---|---|---|---|---|
| No extensions | nothing | nothing | "Add Extension" row only | Manage…, Add… | no Extensions button |
| Extensions, none pinned | nothing | nothing | all items | items + Manage…, Add… | button |
| 1–3 pinned (W 228) | slots on hover | slots (focused pane) | pinned first | pinned first | button |
| Many pinned | `nMax − 1` + more | `nMax − 1` + more | grid | all | button |
| Badge set | badge in image | badge in image | badge in image | no badge (16 pt icon) | menu: no badge |
| Disabled for tab | grayscale; click → context menu | same | grayscale, name secondary | item disabled | item disabled |
| Popup open | pressed plate; strip forced visible | pressed plate | SCC closed | — | button pressed |
| Picker active (Cmd+E) | unchanged | unchanged | focus ring on one item | — | — |
| Popup page loading | pressed plate, panel transparent (§3.7 S3) | same | — | — | — |

## 5. Persistence (one store per fact)

| Fact | Store | Writer | Reader |
|---|---|---|---|
| Pinned set and order | Chromium pref `extensions.pinned_extensions` in the profile's engine folder (`Engine/Default/Preferences` or `Engine/<dir>/Preferences`, docs/plans/profiles.md §6.2) | `ToolbarActionsModel` (`SetActionVisibility`, `MovePinnedAction`) through §7 E4 | `OEExtensionAction.pinned`, `.pinnedIndex` |
| Installed set, enabled state, permissions, site access | Chromium (`Secure Preferences`, `Extensions/`, `extension_prefs`) | Chromium | §7 E2, E8 |
| Extension shortcuts | Chromium (`extensions.commands` pref via `CommandService`) | `chrome://extensions/shortcuts` | §7 E9 |
| Extension popup window frame | AppKit frame autosave `ExtensionPopupWindow` (UserDefaults) | AppKit | AppKit |
| Open's Cmd+E binding override | `KeyBindings` (exists, `settings-library.md` §2.4) | Settings | `OpenCommands` |

The shell never writes a pinned list, an installed list, or a cache of
action state to `State/browser.json` or anywhere else. Per-profile
separation is automatic: each profile is its own Chromium profile.

Pin-by-default for new installs: Chromium 156 has
`features::kExtensionsPinnedByDefault` and pref
`prefs::kExtensionsPinnedByDefault` (`toolbar_actions_model.cc:146`).
Lead question Q4.

## 6. Keyboard shortcuts

### 6.1 Open's own

| Command id | Title | Default | Scope | Customizable | Evidence |
|---|---|---|---|---|---|
| `open-extensions-picker` (new) | "Open Extensions" | Cmd+E | window | yes (`arcKeyBindingID` exists in Arc) | EX-10 |
| `manage-extensions` (exists) | "Manage Extensions…" | — | window | — | menus-and-hotkeys |
| `add-extension` (exists) | "Add Extension…" | — | window | — | same |
| `extension-shortcuts` (new, code only) | "Extension Shortcuts" | — | window | no | EX-11 |

`open-extensions-picker` is a hidden item in the Extensions menu
(`isHidden = true`, `allowsKeyEquivalentWhenHidden = true`), as in Arc.
Aliases for the command bar: "Extensions picker", "Pinned extensions",
"Run extension".

Conflict: `use-selection-to-find` has Cmd+E today
(`CommandRegistry.swift:139`). Arc's nib gives "Use Selection to Find" no
key. Lead question Q1 (recommendation: follow Arc; remove Cmd+E from
`use-selection-to-find`).

### 6.2 Extension commands (`chrome.commands`)

Arc reads all commands from the engine and runs them on key press
(EX-11). The hidden Chrome window of P1 has no Views key registry, so
the shell must route in-window commands. Global commands stay in the
engine.

1. Table: `ExtensionShortcutTable` (App) holds, per profile, every active
   command with a shortcut: `(extensionID, name, key, modifiers,
   isGlobal, isActionCommand)` from §7 E9. Rebuild on
   `extensionManagerDidChangeCommands`. Lookup is a dictionary keyed by
   `(key, modifiers)`.
2. Routing order for a key-down in a browser window (extends app-shell
   §4.3): (1) Open's reserved shortcuts (`keyEquivalentHandler`);
   (2) Open's menu and router shortcuts that are not page-first;
   (3) extension commands of the key window's profile, non-global only;
   (4) the page; (5) the rest of the main menu. guess for (3) before (4):
   Chrome registers extension keys as browser accelerators.
3. Conflicts: an extension shortcut equal to any Open default or
   user-bound shortcut is ignored by the router and reported (Settings ›
   Shortcuts shows it as a conflict row; `settings-library.md` §5.4.3
   owns the display). Open always wins, like Chrome, which refuses
   suggested keys that collide with browser shortcuts.
4. Run: `_execute_action` → the action runs with source `.command`;
   its popup anchors per §3.7 A4. A named command →
   `browser.executeExtensionCommand(name, forExtension: id)` (§7 E9).
5. Global commands (`"global": true`): the engine registers and runs them
   (Chromium `ExtensionCommandsGlobalRegistry` with
   `GlobalAcceleratorListenerMac`). The shell does nothing but list them.
6. Editing: "Extension Shortcuts" opens `chrome://extensions/shortcuts`
   (§3.12). No native editor in v1.

### 6.3 Settings ▸ Shortcuts and the command registry (status gap 37)

Arc's Shortcuts pane has "Extension Shortcuts" (MH "Custom shortcuts")
as a menu item that opens Chromium's page (EX-11: `extensions/shortcuts`
sits in Arc's list of Chromium settings sub-pages next to
`settings/languages`, `settings/searchEngines`, and others). Open does
the same and adds one notice for conflicts.

Registry fit (one store per fact):

| Kind | Where it lives | Edited in | In `CommandRegistry`? |
|---|---|---|---|
| Open commands (`open-extensions-picker`, `extension-shortcuts`, `manage-extensions`, `add-extension`) | `CommandRegistry` + user overrides in `State/keybindings.json` (`KeyBindingStore`) | Settings ▸ Shortcuts list | yes |
| Extension commands (`chrome.commands`) | Chromium pref `extensions.commands` per profile (`CommandService`) | `chrome://extensions/shortcuts` | no: dynamic, per profile; `ExtensionShortcutTable` (§6.2) |

`KeyBindingStore` never stores an extension shortcut, and
`CommandRegistry` never lists one. `commands-dump` and
`expected-menu.json` stay static.

Pane changes (`Packages/OpenKit/Sources/OpenSettings/ShortcutsPane.swift`):

1. The pane's "…" menu gets "Extension Shortcuts" after "Shortcut Help".
   It calls `model.root.actions.openURL(URL(string: "chrome://extensions/shortcuts")!, profileID: model.root.selectedProfileID)`
   (`SettingsViewModel.actions`, `.selectedProfileID`).
   The App opens it as a selected Today tab with the singleton rule
   (§3.12).
2. Conflict notice: `SettingsActions` gains
   `func extensionShortcutConflicts(profileID: ProfileID) -> [ExtensionShortcutConflict]`
   (default implementation returns `[]`; the App answers from
   `ExtensionShortcutTable`). `ExtensionShortcutConflict` (OpenSettings):
   `extensionName`, `commandDescription`, `shortcut:
   OpenCommands.KeyboardShortcut`, `openCommandID`. When the list is not
   empty, the pane shows one 11 pt secondary line per conflict under the
   status area: "<extension>: <⇧⌘Y> is used by <Open command title>, so
   it is off." and one link button "Extension Shortcuts…" (same action as
   item 1). Open choice; Arc has no such notice in its strings.
3. Recording an Open shortcut that equals an active extension shortcut
   is allowed (Open wins, §6.2 rule 3). After the save, the conflict
   notice lists that extension command.
4. The pane does not list extension commands as rows (Arc does not;
   Chromium's page is the editor).

## 7. Engine API contract (requests for the P2/P3 queue)

The engine lead owns the fork and the exact C++; these are the ObjC
shapes the shell will call and the Chromium code each one comes from.
All main thread, `NS_SWIFT_UI_ACTOR`, nullability-annotated, like the
existing headers. "P1+" = P1 follow-up. The shell plan does not change
if the engine lead renames a selector, as long as the meaning stays.

### E1. Action list and order (P2) — `OEBrowser`

```objc
/// Every toolbar action of the enabled extensions of this window's profile,
/// for the active tab: pinned actions in pinned order first, then the rest
/// in ToolbarActionsModel order. (Today: "toolbar actions of enabled
/// extensions, in pin order" — this widens it to unpinned actions.)
@property(nonatomic, readonly, copy) NSArray<OEExtensionAction*>* extensionActions;
/// NO until ToolbarActionsModel::actions_initialized().
@property(nonatomic, readonly) BOOL extensionActionsReady;
```

Source: `ToolbarActionsModel` (`chrome/browser/ui/toolbar/toolbar_actions_model.h:44`:
`action_ids()`, `pinned_action_ids()`, `IsActionPinned`,
`actions_initialized()`).

### E2. Action snapshot (P2) — `OEExtensionAction`

```objc
typedef NS_ENUM(NSInteger, OEExtensionSiteAccess) {
  OEExtensionSiteAccessNone,        // no host permission for this site
  OEExtensionSiteAccessOnClick,     // PermissionsManager::UserSiteAccess::kOnClick
  OEExtensionSiteAccessOnSite,      // kOnSite
  OEExtensionSiteAccessOnAllSites,  // kOnAllSites
  OEExtensionSiteAccessBlocked,     // UserSiteSetting::kBlockAllExtensions for this site
} NS_SWIFT_NAME(OEExtensionAction.SiteAccess);

@interface OEExtensionAction (P2)
@property(nonatomic, readonly, copy) NSString* extensionName;
@property(nonatomic, readonly, copy) NSString* accessibleName;   // GetAccessibleName (includes badge text)
@property(nonatomic, readonly, copy) NSString* tooltip;          // GetTooltip(active tab)
/// 28×28 pt image with 1x and 2x reps: icon + badge + disabled grayscale +
/// blocked-action decoration, exactly as Chrome's toolbar draws it.
@property(nonatomic, readonly) NSImage* toolbarImage;
/// 16×16 pt plain action icon (no badge), for menus. Replaces today's
/// manifest-icon meaning of `icon`.
@property(nonatomic, readonly, nullable) NSImage* icon;
@property(nonatomic, readonly, copy, nullable) NSColor* badgeTextColor; // nil = automatic contrast
@property(nonatomic, readonly, getter=isPinned) BOOL pinned;
@property(nonatomic, readonly) NSInteger pinnedIndex;            // -1 when unpinned
@property(nonatomic, readonly) BOOL wantsToRun;                  // ExtensionActionRunner::WantsToRun
@property(nonatomic, readonly) OEExtensionSiteAccess siteAccess;
@property(nonatomic, readonly, getter=isShowingPopup) BOOL showingPopup;
/// The _execute_action shortcut, Cocoa form; nil when none.
@property(nonatomic, readonly, copy, nullable) NSString* shortcutKeyEquivalent;
@property(nonatomic, readonly) NSEventModifierFlags shortcutModifierFlags;
@end
```

Sources: `ExtensionActionViewModel` (`chrome/browser/ui/extensions/extension_action_view_model.h`:
`GetIcon(web_contents, size)`, `GetActionName`, `GetAccessibleName`,
`GetTooltip`, `IsEnabled`, `IsShowingPopup`);
`IconWithBadgeImageSource` (`chrome/browser/ui/extensions/icon_with_badge_image_source.cc`)
for `toolbarImage`; `ExtensionAction::GetBadgeText/GetBadgeBackgroundColor/GetBadgeTextColor`
(`extensions/browser/extension_action.h`); `ExtensionActionRunner::WantsToRun`
(`chrome/browser/extensions/extension_action_runner.h:105`);
`PermissionsManager::GetUserSiteAccess` / `UserSiteSetting`
(`extensions/browser/permissions_manager.h:84-99`);
`CommandService::GetExtensionActionCommand`
(`chrome/browser/extensions/commands/command_service.h:120`).

### E3. Change events (P2) — `OEBrowserDelegate`

```objc
/// The list or the order changed (install, uninstall, enable, disable,
/// pin, unpin, move, models initialized). Redraw from -extensionActions.
- (void)browserDidUpdateExtensionActions:(OEBrowser*)browser;   // exists
/// One action's state changed (icon, badge, title, enabled, wants-to-run,
/// site access, active tab change). Coalesced: at most one call per action
/// per run-loop turn (Arc batches too, EX-13).
- (void)browser:(OEBrowser*)browser didUpdateExtensionAction:(OEExtensionAction*)action
    NS_SWIFT_NAME(browser(_:didUpdate:));
```

Sources: `ToolbarActionsModel::Observer` (`OnToolbarActionAdded/Removed/Updated`,
`OnToolbarModelInitialized`, `OnToolbarPinnedActionsChanged`, header
lines 82–100); `ExtensionActionViewModel` icon observer
(`OnIconUpdated`); `ExtensionActionDispatcher::Observer` (already used by
P1's `OnExtensionActionUpdated`); the strip's active-tab change.

### E4. Pin and reorder (P2) — `OEBrowser`

```objc
- (void)setExtensionAction:(NSString*)extensionIdentifier pinned:(BOOL)pinned
    NS_SWIFT_NAME(setExtensionAction(_:pinned:));
- (void)moveExtensionAction:(NSString*)extensionIdentifier toPinnedIndex:(NSUInteger)index
    NS_SWIFT_NAME(moveExtensionAction(_:toPinnedIndex:));
```

Writes `extensions.pinned_extensions` (`extensions/browser/pref_names.h:131`)
through `ToolbarActionsModel::SetActionVisibility` and `MovePinnedAction`
(header lines 124, 147). Every `OEBrowser` of the profile gets E3.

### E5. Run with a source (P2) — `OEBrowser`

```objc
typedef NS_ENUM(NSInteger, OEExtensionActionSource) {
  OEExtensionActionSourceToolbarButton,  // InvocationSource::kToolbarButton
  OEExtensionActionSourceMenuEntry,      // kMenuEntry
  OEExtensionActionSourceCommand,        // kCommand
};
/// Opens the popup or fires chrome.action.onClicked (also for popup-less
/// actions, which return NO today). Runs blocked scripts when the
/// extension wants to run. Returns NO only for an unknown id.
- (BOOL)executeExtensionAction:(NSString*)extensionIdentifier
                        source:(OEExtensionActionSource)source
    NS_SWIFT_NAME(executeExtensionAction(_:source:));
```

Source: `ExtensionActionViewModel::ExecuteUserAction(InvocationSource)`.

### E6. Popup host (P2) — `OEBrowser` / `OEBrowserDelegate`

The popup must be a real `ExtensionViewHost` of view type
`kExtensionPopup` (so `chrome.extension.getViews({type: "popup"})` works)
whose `WebContents` view OpenEngine wraps in an `OEWebContent` (engine-patches
P2). Keep the three existing delegate calls; add:

```objc
// OEBrowserDelegate
/// The popup's first load stopped: show it now (Chrome shows its bubble
/// at this point). Arrives after didOpenExtensionPopup.
- (void)browser:(OEBrowser*)browser extensionPopupIsReady:(OEWebContent*)popup
    NS_SWIFT_NAME(browser(_:extensionPopupIsReady:));

// OEBrowser
typedef NS_ENUM(NSInteger, OEExtensionPopupSource) {
  OEExtensionPopupSourceUser,     // a click, menu, or the shell's run call
  OEExtensionPopupSourceCommand,  // _execute_action
  OEExtensionPopupSourceAPI,      // chrome.action.openPopup()
};
/// Valid from didOpenExtensionPopup until didCloseExtensionPopup.
@property(nonatomic, readonly) OEExtensionPopupSource extensionPopupSource;
@property(nonatomic, readonly, copy, nullable) NSString* extensionPopupExtensionIdentifier;
```

Sources: `ExtensionActionDelegate::TriggerPopup`
(`chrome/browser/ui/extensions/extension_action_delegate.h:63`),
`ExtensionViewHostFactory::CreatePopupHost`
(`chrome/browser/extensions/extension_view_host_factory.h`),
`ExtensionsContainer::HideActivePopup` / `ShowToolbarActionPopupForAPICall`
(`chrome/browser/ui/extensions/extensions_container.h:37,44`), the Android
template `extension_action_popup_contents.{h,cc}` for auto-resize and
close, and `kExtensionPopupMinSize`/`kExtensionPopupMaxSize`
(`extension_popup_types.h:14-15`) for `didResizeExtensionPopup`.
`-closeExtensionPopup` = `HideActivePopup`.

### E7. Action context menu (P2) — `OEBrowser`

```objc
typedef NS_ENUM(NSInteger, OEExtensionMenuSource) {
  OEExtensionMenuSourceToolbarAction,  // ExtensionContextMenuModel::ContextMenuSource::kToolbarAction
  OEExtensionMenuSourceMenuItem,       // kMenuItem (SCC item, overflow)
};
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionActionMenu : NSObject
@property(nonatomic, readonly, copy) NSString* extensionIdentifier;
/// Reuses OEContextMenuItem (commandIdentifier, title, enabled, separator,
/// checked, submenu). Radio items come as checked items.
@property(nonatomic, readonly, copy) NSArray<OEContextMenuItem*>* items;
/// Call one of these exactly once.
- (void)selectCommand:(NSInteger)commandIdentifier NS_SWIFT_NAME(select(command:));
- (void)cancel;
@end

- (nullable OEExtensionActionMenu*)contextMenuForExtensionAction:(NSString*)extensionIdentifier
                                                          source:(OEExtensionMenuSource)source
    NS_SWIFT_NAME(contextMenu(forExtensionAction:source:));
```

Source: `ExtensionContextMenuModel(extension, browser, is_pinned,
popup_delegate, can_show_icon_in_toolbar = true, source)`
(`chrome/browser/extensions/extension_context_menu_model.h:119`) and its
`ExecuteCommand`. The menu object keeps the C++ model alive until
`select`/`cancel`. Arc does the same through
`-[ArcBrowser showExtensionContextMenu:]` (EX-9).

### E8. Live registry and management (P3) — `OEExtensionManager`

```objc
@property(nonatomic, readonly, getter=isReady) BOOL ready;              // ExtensionSystem::ready()
@property(nonatomic, readonly, copy) NSArray<OEExtension*>* installedExtensions; // now live
- (void)setEnabled:(BOOL)enabled forExtension:(NSString*)identifier;
/// Shows the remove prompt (E10) first; removes on confirm.
- (void)uninstallExtension:(NSString*)identifier window:(nullable NSWindow*)window;
- (void)reloadExtension:(NSString*)identifier;
/// Web Store install by id with the normal prompt (used later by Import from Arc).
- (void)installFromWebStore:(NSString*)identifier
                     window:(nullable NSWindow*)window
                 completion:(void (^)(BOOL installed, NSString* _Nullable error))completion;

// OEExtensionManagerDelegate (all optional)
- (void)extensionManagerDidChange:(OEExtensionManager*)manager;          // exists (add the argument)
- (void)extensionManager:(OEExtensionManager*)manager
     didInstallExtension:(OEExtension*)extension byUser:(BOOL)byUser;
- (void)extensionManager:(OEExtensionManager*)manager
didFailToLoadExtensionAt:(NSURL*)path error:(NSString*)message;
- (void)extensionManagerDidBecomeReady:(OEExtensionManager*)manager;
```

`OEExtension` gains `hasAction`, `fromWebStore`, `homepageURL`,
`disableReasons` (bit set). Sources: `ExtensionRegistry` +
`ExtensionRegistryObserver`, `ExtensionRegistrar`
(enable/disable/uninstall), `ExtensionSystem::ready()`,
`LoadErrorReporter`, `WebstoreInstallWithPrompt`
(`chrome/browser/extensions/webstore_install_with_prompt.h`). This
replaces the Preferences reader in `OEExtensions.mm` (engine-patches P3).

### E9. Commands (P3) — `OEExtensionManager`, `OEBrowser`

```objc
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionCommand : NSObject
@property(nonatomic, readonly, copy) NSString* extensionIdentifier;
@property(nonatomic, readonly, copy) NSString* name;          // "_execute_action" for the action command
@property(nonatomic, readonly, copy) NSString* summary;       // manifest description
@property(nonatomic, readonly, copy) NSString* keyEquivalent; // Cocoa form; empty = no shortcut
@property(nonatomic, readonly) NSEventModifierFlags modifierFlags;
@property(nonatomic, readonly, getter=isGlobal) BOOL global;
@property(nonatomic, readonly, getter=isActionCommand) BOOL actionCommand;
@end

@property(nonatomic, readonly, copy) NSArray<OEExtensionCommand*>* commands;   // OEExtensionManager, active ones
- (void)extensionManagerDidChangeCommands:(OEExtensionManager*)manager;        // delegate

// OEBrowser: what ExtensionKeybindingRegistry::CommandExecuted does for one window.
- (void)executeExtensionCommand:(NSString*)name forExtension:(NSString*)extensionIdentifier
    NS_SWIFT_NAME(executeExtensionCommand(_:forExtension:));
```

Sources: `CommandService::GetNamedCommands`, `GetExtensionActionCommand`,
`Observer::OnExtensionCommandAdded/Removed`
(`chrome/browser/extensions/commands/command_service.h:81-131`);
`ExtensionKeybindingRegistry::CommandExecuted`
(`chrome/browser/extensions/extension_keybinding_registry.h:119`): an
action command runs the action (E5, source command), a named command
dispatches `commands.onCommand` with the active tab. Global commands:
`ExtensionCommandsGlobalRegistry`
(`chrome/browser/extensions/extension_commands_global_registry.h`) with
`ui/base/accelerators/global_accelerator_listener/global_accelerator_listener_mac.h`;
the engine must create it for every profile (verify in §10.3 X-12).

### E10. Prompts (P3) — `OEExtensionManagerDelegate`

```objc
typedef NS_ENUM(NSInteger, OEExtensionPromptType) {
  OEExtensionPromptTypeInstall,         // INSTALL_PROMPT
  OEExtensionPromptTypeReEnable,        // RE_ENABLE_PROMPT
  OEExtensionPromptTypePermissions,     // PERMISSIONS_PROMPT
  OEExtensionPromptTypeExternalInstall, // EXTERNAL_INSTALL_PROMPT
  OEExtensionPromptTypeRemoteInstall,   // REMOTE_INSTALL_PROMPT
  OEExtensionPromptTypeRepair,          // REPAIR_PROMPT
  OEExtensionPromptTypeUninstall,       // ExtensionUninstallDialog
};
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionPermissionMessage : NSObject
@property(nonatomic, readonly, copy) NSString* message;
@property(nonatomic, readonly, copy) NSArray<NSString*>* details;
@end
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionPrompt : NSObject
@property(nonatomic, readonly) OEExtensionPromptType type;
@property(nonatomic, readonly, copy) NSString* extensionIdentifier;
@property(nonatomic, readonly, copy) NSString* extensionName;
@property(nonatomic, readonly, nullable) NSImage* icon;
@property(nonatomic, readonly, copy) NSString* chromiumTitle;        // GetDialogTitle()
@property(nonatomic, readonly, copy) NSString* chromiumAcceptLabel;  // GetAcceptButtonLabel()
@property(nonatomic, readonly, copy) NSString* chromiumCancelLabel;  // GetAbortButtonLabel()
@property(nonatomic, readonly, copy) NSArray<OEExtensionPermissionMessage*>* permissions;
@property(nonatomic, readonly, copy) NSArray<NSString*>* retainedFiles;
@property(nonatomic, readonly, copy) NSArray<NSString*>* retainedDevices;
@property(nonatomic, readonly, copy, nullable) NSString* triggeringExtensionName; // uninstall by another extension
@property(nonatomic, readonly, weak, nullable) OEWebContent* webContent;          // requesting page
@property(nonatomic, readonly, weak, nullable) OEBrowser* browser;                // its window
/// Exactly one of these. A prompt released without an answer cancels.
- (void)accept;
- (void)cancel;
@end

- (void)extensionManager:(OEExtensionManager*)manager showPrompt:(OEExtensionPrompt*)prompt
    NS_SWIFT_NAME(extensionManager(_:show:));
```

Sources: `ExtensionInstallPrompt::GetDefaultShowDialogCallback()`
(`chrome/browser/extensions/extension_install_prompt.h`) replaced by the
CEF implementation (engine-patches 0308); prompt data from
`extensions/browser/install_prompt_data.h` (`PromptType`,
`GetDialogTitle`, `GetAcceptButtonLabel`, `GetAbortButtonLabel`,
`GetPermissionCount`, `GetPermission`, `GetPermissions` with details,
`icon()`); the uninstall prompt from a CEF
`ExtensionUninstallDialog` platform implementation
(`chrome/browser/extensions/extension_uninstall_dialog.h:70,81,87`).
The Web Store install must work from a hosted P1 tab
(`webstorePrivate.beginInstallWithManifest3`).

### E11. Extension popup windows (P1+) — `OEEngineDelegate`

```objc
/// chrome.windows.create({type: "popup"}): a hidden Chrome Browser of
/// TYPE_POPUP with its own tab strip; `window` is its OEBrowser (so
/// chrome.windows sees a popup window). Host `content.view` in a window and
/// set window.window.
- (void)engine:(OEEngine*)engine
    didOpenExtensionWindow:(OEBrowser*)window
                   content:(OEWebContent*)content
            requestedFrame:(NSRect)frame        // NSZeroRect when not given
                 extension:(NSString*)extensionIdentifier
    NS_SWIFT_NAME(engine(_:didOpenExtensionWindow:content:requestedFrame:extension:));
/// chrome.windows.update({left, top, width, height, focused, state}).
- (void)engine:(OEEngine*)engine extensionWindow:(OEBrowser*)window requestsFrame:(NSRect)frame focused:(BOOL)focused;
```

`chrome.windows.remove` arrives as `webContentDidRequestClose`. Source:
`ChromeBrowserDelegate` / `Browser::Create(TYPE_POPUP)` in the P1
tab-strip code (ArcCore's equivalent is `createPopupBrowser:withDelegate:`).

### E12. Omnibox keywords (P3) — `OEExtension`, `OEBrowser`

```objc
// OEExtension
@property(nonatomic, readonly, copy, nullable) NSString* omniboxKeyword;

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEOmniboxSuggestion : NSObject
@property(nonatomic, readonly, copy) NSString* content;          // sent back on accept
@property(nonatomic, readonly, copy) NSString* descriptionText;  // markup removed
@property(nonatomic, readonly, copy) NSArray<NSValue*>* matchRanges; // NSRange values styled "match"
@property(nonatomic, readonly, copy) NSArray<NSValue*>* dimRanges;
@property(nonatomic, readonly, copy) NSArray<NSValue*>* urlRanges;
@property(nonatomic, readonly, getter=isDeletable) BOOL deletable;
@end

typedef NS_ENUM(NSInteger, OEOmniboxDisposition) {
  OEOmniboxDispositionCurrentTab,
  OEOmniboxDispositionNewForegroundTab,
  OEOmniboxDispositionNewBackgroundTab,
};

// OEBrowser (the key window; "entered" acts on its active tab)
- (void)omniboxStartSessionForExtension:(NSString*)extensionIdentifier;
/// NO when the extension has no onInputChanged listener. The completion
/// runs at most once, on the main thread, and only for the latest text.
- (BOOL)omniboxInputChanged:(NSString*)text
               forExtension:(NSString*)extensionIdentifier
                 completion:(void (^)(NSArray<OEOmniboxSuggestion*>* suggestions))completion;
/// The extension's setDefaultSuggestion, with "%s" still in it; nil = none.
- (nullable OEOmniboxSuggestion*)omniboxDefaultSuggestionForExtension:(NSString*)extensionIdentifier;
- (void)omniboxInputEntered:(NSString*)text
               forExtension:(NSString*)extensionIdentifier
                disposition:(OEOmniboxDisposition)disposition;
- (void)omniboxInputCancelledForExtension:(NSString*)extensionIdentifier;
- (void)omniboxDeleteSuggestion:(NSString*)content forExtension:(NSString*)extensionIdentifier;

// OEBrowserDelegate
- (void)browser:(OEBrowser*)browser omniboxDefaultSuggestionDidChangeForExtension:(NSString*)extensionIdentifier;
```

Sources: `OmniboxInfo::GetKeyword`
(`chrome/common/extensions/api/omnibox/omnibox_handler.h:27`);
`ExtensionOmniboxEventRouter::OnInputStarted`, `OnInputChanged`,
`OnInputEntered`, `OnInputCancelled`, `OnDeleteSuggestion`
(`chrome/browser/extensions/api/omnibox/omnibox_api.h:64-90`);
`OmniboxSuggestionsWatcher::Observer::OnOmniboxSuggestionsReady` and
`OnOmniboxDefaultSuggestionChanged`
(`components/omnibox/browser/omnibox_suggestions_watcher.h:22,27`);
`ApplyDefaultSuggestionForExtensionKeyword` and
`StyleTypesToACMatchClassifications` (`omnibox_api.h:220,228`); the
template is `KeywordExtensionsDelegateImpl::OnOmniboxSuggestionsReady`
(`chrome/browser/autocomplete/keyword_extensions_delegate_impl.cc:141`).
Arc's equivalents: `ArcExtensionInfo.omniboxKeyword`,
`-[ArcBrowser triggerExtensionOmniboxInput:inputText:disposition:]`, and
`autocomplete:…keyword:…` (`arccore-engine.md` §2). Open does not run
Chromium's `AutocompleteController`; OpenSuggest is the command bar
backend, so the engine exposes the omnibox events directly.

### E13. Not requested (and why)

- Site-access setters: the context menu (E7) covers them, as in Arc.
- `ExtensionsMenuViewModel` (`chrome/browser/ui/extensions/extensions_menu_view_model.h`,
  host access requests, `UpdateSiteAccess`): Chrome's newer menu; Arc
  does not show it. If the lead wants Chrome-style access toggles in the
  SCC (Q5), this is the model to wrap.
- Side panel (Q6).

## 8. Shell architecture

### 8.1 New target `OpenExtensionsUI` (OpenKit library)

`Package.swift` (keep both sides on merge, AGENTS.md rule 10):

```swift
.library(name: "OpenExtensionsUI", targets: ["OpenExtensionsUI"]),
.executable(name: "extensions-render", targets: ["extensions-render"]),
.target(name: "OpenExtensionsUI", dependencies: ["OpenModel", "OpenDesign", "OpenWeb"]),
.executableTarget(name: "extensions-render",
                  dependencies: ["OpenModel", "OpenDesign", "OpenWeb", "OpenExtensionsUI", "OpenSidebar", "OpenFeatures"]),
```

`OpenSidebar` and `OpenFeatures` add `OpenExtensionsUI` (and `OpenWeb`)
to their dependencies.

Files (create exactly these):

```text
Packages/OpenKit/Sources/OpenDesign/ExtensionsMetrics.swift   ExtensionsMetrics, ExtensionsRole
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionActionButton.swift   §3.1
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionStripView.swift      §3.2, §3.3 (styles .urlField, .paneBar); fit, overflow, drag reorder
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionStripLayout.swift    pure layout math (nMax, frames) shared by the view and `extensions-render check`
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionItemView.swift       §3.9.1
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionsSectionBody.swift   §3.9.2, §3.10 picker focus
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionsMenuBuilder.swift   §3.5, §3.6 rendering of engine menus, brand relabel table
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionPopupPanel.swift     §3.7 window, placement, size, dismissal hooks
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionPopupPlacement.swift pure placement math (A1–A4, S1–S2)
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionPromptSheet.swift    §3.11 view and sheet queue
Packages/OpenKit/Sources/OpenExtensionsUI/ExtensionsUIContext.swift     per-window state: actions, popup state, forced visibility, intents
Packages/OpenKit/Sources/extensions-render/main.swift
Packages/OpenKit/Sources/extensions-render/Scenes.swift
Packages/OpenKit/Sources/extensions-render/Checks.swift
Packages/OpenKit/Sources/extensions-render/Synthetic.swift              synthetic actions and engine-like images (drawn in code)
```

Edited: `OpenSidebar/ChromeViews.swift` (URL field hosts the strip; host
text right edge), `OpenSidebar/SidebarContext.swift` (an
`extensionsUI: ExtensionsUIContext?` reference),
`OpenFeatures/PaneChromeView.swift` (pane strip, host right limit),
`OpenFeatures/LittleOpenWindowController.swift` (§3.4),
`OpenCommands/CommandRegistry.swift` and `MenuBuilder.swift` (§6.1),
`OpenSettings/ShortcutsPane.swift` (§3.12 menu item),
`OpenWeb/OpenWeb.swift` (§8.2), `OpenDesign/Typography.swift` (new font
tokens), `OpenDesign/Icons.swift` (new `Glyph` cases `.extensions`,
`.extensionsMore`; an enum cannot gain cases in another file).

### 8.2 OpenWeb changes (OpenKit's view of the engine)

```swift
/// An engine image, immutable. CGImage is thread-safe to read.
/// Equality and hash by object identity (one object per engine image change).
public final class ExtensionImage: @unchecked Sendable, Hashable {
    public let cgImage: CGImage        // 2x rep
    public let pointSize: CGSize       // 28×28 or 16×16
}

public struct ExtensionActionInfo: Sendable, Hashable, Identifiable {
    public var id: String { extensionID }
    public var extensionID: String
    public var name: String
    public var accessibleName: String
    public var tooltip: String
    public var toolbarImage: ExtensionImage?
    public var menuIcon: ExtensionImage?
    public var badgeText: String?            // automation and accessibility only; never drawn by the shell
    public var isEnabled: Bool
    public var hasPopup: Bool
    public var isPinned: Bool
    public var pinnedIndex: Int?             // nil when unpinned
    public var wantsToRun: Bool
    public var isShowingPopup: Bool
    public var shortcutKeys: [String]        // keycaps for the tooltip, e.g. ["⇧", "⌘", "Y"]; empty = none
}
public typealias ExtensionItem = ExtensionActionInfo   // the SCC item input (§3.9)

public enum ExtensionRunSource: Sendable { case toolbarButton, menuEntry, command }

@MainActor
public protocol ExtensionHost: AnyObject {
    var extensionActions: [ExtensionActionInfo] { get }       // E1 order
    var actionsReady: Bool { get }
    @discardableResult func executeAction(extensionID: String, source: ExtensionRunSource) -> Bool
    func setPinned(_ pinned: Bool, extensionID: String)
    func movePinned(extensionID: String, to index: Int)
    func contextMenu(extensionID: String, fromMenuItem: Bool) -> ExtensionMenu?
    func closePopup()
    var onActionsChanged: (@MainActor () -> Void)? { get set }
    var onActionChanged: (@MainActor (ExtensionActionInfo) -> Void)? { get set }
}

/// A Chromium menu to show once.
@MainActor public protocol ExtensionMenu: AnyObject {
    var items: [ExtensionMenuItem] { get }
    func select(command: Int)
    func cancel()
}
public struct ExtensionMenuItem: Sendable {
    public var command: Int; public var title: String
    public var isEnabled: Bool; public var isSeparator: Bool; public var isChecked: Bool
    public var submenu: [ExtensionMenuItem]
}
```

The existing `executeAction(extensionID:)` stays as a wrapper with source
`.toolbarButton` so the automation code keeps compiling.

### 8.3 App glue (files under `App/Extensions/`)

```text
App/Extensions/EngineExtensionHost.swift        ExtensionHost over OEBrowser (moved from EngineBridge.swift); OEBrowserDelegate forwarding for E3/E6
App/Extensions/ExtensionPopupController.swift   one per window: owns ExtensionPopupPanel; D1–D8 observers; anchor resolution (A4)
App/Extensions/ExtensionPromptPresenter.swift   OEExtensionManagerDelegate → ExtensionPromptSheet; window choice; toast after install
App/Extensions/ExtensionShortcutTable.swift     §6.2 table and router hook
App/Extensions/ExtensionsMainMenuProvider.swift §3.5.1 menuNeedsUpdate injection
App/Extensions/ExtensionWindowController.swift  §3.8 popup windows (E11)
App/Extensions/EngineCommandBarSource.swift     §3.14 ExtensionCommandBarSource over OEBrowser (E1, E12)
```

These join the app-shell file list (app-shell §2.3 says "no others
without a plan change"; this plan is that change). `App/TabStripMirror.swift`
(app-shell) stays the owner of `OEBrowser` objects; `EngineExtensionHost`
wraps the window's `OEBrowser` for the focused profile. When the focused
Space switches to another profile, the window's strips switch to that
profile's `OEBrowser` (a window has one `OEBrowser` per profile).

The M1 code in `App/BrowserWindowController.swift` (`reloadExtensionBar`,
`extensionButtonClicked`, `openExtensionsPage`, popup `makePanel` path,
`OEBrowserDelegate` extension) is deleted in Step 6 (§11). Port checklist:
each item has a new owner above.

### 8.4 Threading

Everything in this plan runs on the main actor. Engine callbacks arrive
on the main thread (`docs/engine-api.md`). `ExtensionImage` holds an
immutable `CGImage`; build it once per engine image change, never per
draw.

### 8.5 Command bar and Settings glue (§3.14, §6.3)

```swift
// OpenSuggest/ExtensionProviders.swift (new)
@MainActor public protocol ExtensionCommandBarSource: AnyObject {
    var actions: [ExtensionCommandBarAction] { get }        // id, name, shortcutKeys; enabled only
    var keywords: [ExtensionKeyword] { get }                // id, name, keyword
    func startSession(extensionID: String)
    func inputChanged(_ text: String, extensionID: String) async -> [ExtensionOmniboxRow]?
    func defaultRow(extensionID: String, text: String) -> ExtensionOmniboxRow
    func cancelSession(extensionID: String)
    func deleteSuggestion(_ content: String, extensionID: String)
}
public struct ExtensionOmniboxRow: Sendable, Hashable {
    public var content: String; public var title: String; public var boldRanges: [Range<Int>]
    public var deletable: Bool
}
public struct ExtensionActionsProvider: SuggestProvider { … }   // §3.14.1, id "extensions"
public struct ExtensionOmniboxProvider: SuggestProvider { … }   // §3.14.2, id "extension-omnibox"; asyncOperation for inputChanged
```

- `SuggestTypes.swift`: kinds `.extensionAction`, `.extensionKeywordHint`,
  `.extensionSuggestion`; field `extensionID: String?`;
  `IconHint.extension(String)`; `SuggestContext.extensionScopeID`.
- `SuggestEngine`: registers both providers when a source is set
  (`SuggestEngine.extensionSource`, weak).
- `OpenCommandBar/CommandBarController.swift`: the extension scope uses
  the Site Search chip, hint, Tab/Space, and Backspace code paths; new
  intents `.runExtensionAction(extensionID:)` and
  `.extensionOmnibox(extensionID:, content:, CommandBarDestination, CommandBarModifiers)`.
- `App/Extensions/EngineCommandBarSource.swift` (new):
  `ExtensionCommandBarSource` over `OEBrowser` (E1, E12) for the key
  window; bridges the E12 completion to `async`.
- `OpenSettings/SettingsActions.swift`, `ShortcutsPane.swift`: §6.3.

## 9. Performance rules

- No polling, no timers. The strip redraws only on E3 events.
- `didUpdateExtensionAction` updates one button: set its image and
  tooltip, `needsDisplay` on that button only. No strip layout unless
  pinned membership or count changed (a badge change never relayouts).
- Image conversion (`NSImage` → `ExtensionImage`) happens once per
  engine event, in `EngineExtensionHost`; cache by object identity.
- The menu bar menu builds in `menuNeedsUpdate` only.
- The popup panel is created on first use per window and reused.
- Budget (Release, M5 Pro, idle machine; measure with `--only measure`):
  a tab switch with 20 extensions installed and 6 pinned adds ≤ 1 ms of
  main-thread time in extension UI code (signpost
  `ExtensionsUI.update`); a uBlock Origin Lite badge burst (one update
  per blocked request) causes at most one redraw per action per frame.

## 10. Verification (no unit tests; AGENTS.md rule 6)

### 10.1 `extensions-render` (offscreen, like `sidebar-render`)

CLI: `swift run -c release extensions-render <scene|all|check> [--scale 1|2] [--appearance light|dark] [--out DIR]`.
Synthetic actions come from `Synthetic.swift`: images drawn in code that
imitate the engine's 28×28 image (16 pt colored rounded square + a badge
pill drawn with Chromium's rules from EX-14). No Arc assets.

Scenes (each at 1x and 2x, light and dark Space themes):

| Scene | Content |
|---|---|
| `url-strip` | Sidebar width 228, 300, 500; 0, 1, 3, 6 pinned; hover on/off; badges "1", "99", "999+", "NEW"; one disabled; one wants-to-run; one popup-open (pressed) |
| `url-strip-overflow` | 228 with 6 pinned → 2 + more |
| `pane-strip` | Pane widths 984, 600, 400, 250; focused and unfocused; host 40 and 160 pt |
| `little-open` | Toolbar 720 wide with and without the Extensions button |
| `scc-rows`, `scc-grid` | 0, 3, 4, 5, 12 extensions; pinned mixed; hover pin button; picker focus on item 2 |
| `prompt-install` | Long name; 0, 3, 12 permissions (scrolls); one permission with details |
| `prompt-permissions`, `prompt-remove` | — |
| `popup-frame` | Panel chrome around a solid content view at 25×25, 320×480, 800×600 |

System menus cannot be drawn offscreen. As in `sidebar-render` (its
`menuTitles` checks), menu checks compare item titles, order,
separators, enabled state, and icon size; `extensions-render menus
--out DIR` also writes them as JSON for the PR.

`extensions-render check` (exit code 0 only when all pass) runs the real
layout and placement code and prints one row per check:

| Check | Expectation |
|---|---|
| `strip.nmax` | `nMax` = 3 at W 228, 5 at 300, 13 at 500 (§3.2) |
| `strip.overflow` | 6 pinned at 228 → 2 actions + more; overflow menu lists the other 4 first |
| `strip.order` | slots follow `pinnedIndex` |
| `strip.badge-no-layout` | changing badge text causes 0 strip layouts (counter) |
| `pane.nmax` | 19 at w 984 with a 160 pt host; 7 at w 600 and 0 + more at w 400 with a 120 pt host (§3.3) |
| `pane.unfocused` | unfocused pane has no slots |
| `placement.below` | panel below the anchor, left-aligned, 6 pt gap |
| `placement.clamp-right`, `placement.flip-above` | A3 |
| `placement.size-clamp` | 1200×900 request → 800×600; 10×10 → 25×25 |
| `menu.bar` | §3.5.1 order, separator rule, disabled item |
| `menu.relabel` | "Remove from Chrome…" → "Remove from Open…"; "Pin to Toolbar" → "Pin" |
| `picker.keys` | arrows, type-select, Return, Esc on the synthetic section |
| `prompt.text` | titles and buttons per type (§3.11) |

Add `extensions-render` to `NAMES` in `tools/verify-all.sh` (build, then
`all` and `check`) in Step 1.

Command bar and Settings checks run in the existing CLIs (all in
`verify-all.sh`):

- `openkit suggest-check` gains scenarios with a synthetic
  `ExtensionCommandBarSource`: `ext-action-by-name` (row kind and rank
  next to browser actions), `ext-keyword-hint` (hint row for an exact
  keyword), `ext-scope-default` (default row with `%s` replaced),
  `ext-scope-async` (async rows replace nothing but follow the default
  row; a late answer for old text is dropped), `ext-keyword-conflict`
  (Site Search wins).
- `commandbar-render` gains scenes `extension-action-row` and
  `extension-scope` (chip, default row, 3 suggestions with bold match
  ranges), light and dark.
- `settings-preview` gains the Shortcuts pane with two conflict lines
  and the "…" menu item (its title check).

### 10.2 Automation channel additions (`App/Automation/AutomationController.swift`, `docs/automation.md`)

| Command | Args | Result |
|---|---|---|
| `extensions` (extend) | — | add per action: `name`, `pinned`, `pinnedIndex`, `tooltip`, `badge`, `badgeColor`, `enabled`, `wantsToRun`, `showingPopup`, `siteAccess` |
| `ext-strip` | `surface` (`url`, `pane`, `little`) | visible slots: ids in order, `more` flag, frames in window coordinates, visible flag |
| `ext-click` | `extension`, `surface`, `button` (`left`/`right`) | clicks the slot like a user (an event built inside Open); `right` returns the context menu items without showing it |
| `ext-menu` | `extension`, `select` (title) | opens the action context menu and selects an item by title |
| `ext-pin` | `extension`, `pinned`, `index` | pin, unpin, or move |
| `ext-popup-state` | — | panel visible, key, frame, content size, anchor frame |
| `ext-prompt` | `answer` (`accept`/`cancel`), `hold` | returns the pending prompt (type, title, buttons, permission lines) and answers it |
| `ext-picker` | `keys` | sends keys to the open picker; returns `focusedID` |
| `ext-commands` | — | the shortcut table (§6.2), including dropped conflicts |
| `commandbar` (new or extended, owned with the command bar) | `text`, `keys` | opens the bar, types, sends keys (Tab, Return, Esc, Backspace), returns rows (kind, title, extension id) and the chip |
| `snapshot` (exists) | `window` | use with the popup panel number for pixels |

### 10.3 End-to-end suite `--only extensions-ui` (`tools/e2e/engine_e2e.py`)

Runs on the real Release app with the fork engine and P2/P3 in place.
Extensions: Bitwarden (`nngceckbapebfimnlniiiahkandclblb`), uBlock Origin
Lite (`ddkjiahejlhfcafbddmgiahcphecmpfh`, the badge-heavy one: its
"show the number of blocked requests" option sets the badge through
`declarativeNetRequest.setExtensionActionOptions`), Dark Reader
(`eimadpbcbfnmbkopoojfekhnkhdbieeh`, popup resize), and the new unpacked
fixture `tools/e2e/fixtures/action-probe` (per-tab `setBadgeText`,
`setBadgeBackgroundColor`, `setTitle`, `setIcon`, `disable`/`enable`, a
popup-less `onClicked` counter, `chrome.action.openPopup()`, two
commands: `_execute_action` Cmd+Shift+Y and a named command
Cmd+Shift+U, one optional permission for `chrome.permissions.request`,
and `"omnibox": {"keyword": "probe"}` with `setDefaultSuggestion`
"Probe: %s", suggestions "alpha"/"beta" (deletable), and
`onInputEntered` → `chrome.tabs.update`/`create` to
`https://example.com/?q=<text>`).
Install Bitwarden, uBO Lite, and Dark Reader through the Web Store page
in a P1 tab (X-1), not with `--load-extension`.

| # | Check | Pass when |
|---|---|---|
| X-1 | Web Store install | "Add to Chrome" → `ext-prompt` shows type install, title "Add Bitwarden Password Manager extension to Open?" (the store name), buttons Cancel/Add Extension; `cancel` → not installed; second try `accept` → installed; no window other than Open's own opened (`windows`) |
| X-2 | Pin and order | `ext-pin` pins 3; `ext-strip url` shows them in order at the §3.2 frames (W 228); move index 2 → 0 reorders; quit and relaunch → same order; a second window shows the same order |
| X-3 | Hover rule | strip hidden with the pointer away, visible with the pointer over the sidebar (synthetic mouse-moved events inside Open) |
| X-4 | Badge | `action-probe` sets "7" on tab A and "" on tab B: `extensions` badge follows the selected tab within one engine event; pixel check of the slot shows a badge on A and none on B |
| X-5 | Badge burst | load a page with many ad requests with uBO Lite's count on: badge > 0; redraw counter ≤ 1 per frame per action |
| X-6 | Popup | `ext-click` Bitwarden → panel visible below the slot (A2), key, content not the 25×25 minimum; its `chrome.tabs.query({active: true, currentWindow: true})` (eval in the popup) returns the selected tab |
| X-7 | Resize | Dark Reader popup: `ext-popup-state` size equals the page's `document.documentElement.scrollWidth/Height` within 1 pt, inside 800×600 |
| X-8 | Dismissal | each of D1 (focus the main window), D2 (click again), D3 (Esc), D4 (`window.close()` via eval), D5 (select another tab) closes the popup; Inspect Popup keeps it open on D1 |
| X-9 | Popup-less action | `ext-click action-probe` (no popup) → `onClicked` counter +1 |
| X-10 | Disabled action | `chrome.action.disable()` on the tab → image grayscale (pixel), click opens the context menu (returned items) |
| X-11 | Context menu | items match §3.6 for Bitwarden; "Unpin" unpins; "Options" opens a selected Today tab; site access "On <host>" → `siteAccess` = onSite |
| X-12 | Commands | Cmd+Shift+Y opens the action-probe popup anchored per A4; Cmd+Shift+U fires `commands.onCommand`; an extension shortcut equal to Cmd+T is ignored and listed as a conflict |
| X-13 | Cmd+E | opens the SCC picker (when the SCC exists; skip with a reason before that); arrows move focus; Return runs the focused action |
| X-14 | Permission request | `chrome.permissions.request` from action-probe → prompt type permissions, title "The extension … has requested additional permissions", Deny → promise false; Allow → true |
| X-15 | Remove | context menu "Remove from Open…" → remove prompt; Cancel keeps it; Remove Extension removes it from every strip and menu |
| X-16 | Menu bar | `Extensions` menu (built via `menuNeedsUpdate`) lists pinned first, then the rest, then Manage…/Add…; choosing an item runs the action |
| X-17 | Manage | `manage-extensions` twice → one `chrome://extensions` tab, selected |
| X-18 | Split View | split two tabs, focus pane 2: pane-bar strip shows only in pane 2; slot click anchors the popup to the pane-bar slot |
| X-19 | Little Open | Button visible for ≥1 action and hidden for 0; popup-less onClicked reports the standalone page id/URL; activeTab script fails before click and succeeds after click; popup tabs.query returns that page and its panel anchors 6 pt below the Extensions button; extra extension tabs open selected in the most recent main window's Today while Little Open keeps its page; Profile replacement changes the action list/target and clears the old delegate/list |
| X-20 | Popup window | Bitwarden "pop out" → an `ExtensionWindowController` window, not a Chrome Views window; `chrome.windows.getAll()` includes it as type popup |
| X-21 | Idle | 10 s idle with all extensions loaded: 0 extension UI redraws (signpost counter) |
| X-22 | Run by name | command bar "action pro" → `.extensionAction` row "Action Probe"; Return → popup opens anchored per A4 |
| X-23 | Omnibox scope | type "probe", Tab → chip "Action Probe"; type "al" → rows: default "Probe: al", then "alpha"; Esc → the fixture records `onInputCancelled` once |
| X-24 | Omnibox accept | in scope, "beta" + Return from a Cmd+L bar → the current tab loads `https://example.com/?q=beta`; from a Cmd+T bar → a new selected Today tab |
| X-25 | Omnibox stale rows | type fast ("a", "al", "alp"): the rows match "alp" only (the fixture answers "a" late on purpose) |
| X-26 | Keyword conflict | an extension keyword "yt" → Tab enters Site Search YouTube, not the extension (Q9) |
| X-27 | Settings ▸ Shortcuts | the real "…" menu item "Extension Shortcuts" opens/selects one Today `chrome://extensions/shortcuts` tab on two invocations; saving Cmd+Shift+U for New Tab through `ShortcutsViewModel.record` → `KeyBindingStore` shows exactly "Action Probe: ⇧⌘U is used by New Tab…, so it is off.", reports `probe-named` dropped, and the real key opens the Open command bar without changing the extension counter; resetting the binding clears the notice and the key fires the extension again. `settings-preview` separately covers the engine-free notice scene. |

Screenshots for the PR: one per surface in light and dark, Open's own
windows only.

### 10.4 Historical staging before P2/P3 landed

Steps 1–3 (§11) run on today's engine and P1: the strip, menus, and
popup panel work with P1's action data (badge text and title live,
manifest icon, popups as Alloy pages). The shell draws P1's badge itself
until `toolbarImage` exists (a temporary `BadgeFallback` in
`ExtensionActionButton` with Chromium's numbers from EX-14), and deletes
that code in Step 5. X-1 and X-14–X-15 wait for P3; X-9, X-11, X-20 wait
for P2/P1+.

## 11. Step-by-step order (one PR each; files and acceptance)

| Step | Content | Acceptance |
|---|---|---|
| 1 | `ExtensionsMetrics.swift`, `OpenExtensionsUI` target with `ExtensionActionButton`, `ExtensionStripView`, `ExtensionStripLayout`, `ExtensionPopupPlacement`, `extensions-render` (scenes `url-strip`, `url-strip-overflow`, `pane-strip`, `popup-frame`; checks `strip.*`, `pane.*`, `placement.*`); OpenWeb §8.2 | `extensions-render all` and `check` pass; added to `verify-all.sh` |
| 2 | URL field and pane bar host the strip; `App/Extensions/EngineExtensionHost.swift`; `ExtensionPopupController` + `ExtensionPopupPanel` (D1–D8 with today's delegate calls); automation `ext-strip`, `ext-click`, `ext-pin` (pin via P1 is not available: `ext-pin` returns "needs P2" until E4), `ext-popup-state` | X-3, X-4 (badge via fallback), X-6, X-7, X-8 (D1–D5), X-18 on the P1 engine |
| 3 | Menus: `ExtensionsMenuBuilder`, `ExtensionsMainMenuProvider`, overflow menu, Little Open button; commands `open-extensions-picker`, `extension-shortcuts`; `manage-extensions` singleton | X-16, X-17, X-19; `menu.*` checks |
| 4 | SCC pieces: `ExtensionItemView`, `ExtensionsSectionBody`, picker focus; scenes `scc-rows`, `scc-grid`; handed to the SCC plan | `picker.keys` check; SCC plan wires X-13 |
| 5 | P2 arrives: E1–E7 wired; context menu; pin/move; `toolbarImage` replaces the fallback badge; `extensionPopupIsReady` replaces S4's guess path | X-2, X-5, X-9, X-10, X-11, X-21 |
| 6 | P3 arrives: prompts (`ExtensionPromptSheet`, `ExtensionPromptPresenter`), live registry, commands (`ExtensionShortcutTable`), install toast; delete the M1 extension code | X-1, X-12, X-14, X-15 |
| 7 | P1+ arrives: `ExtensionWindowController` (E11) | X-20 |
| 8 | Command bar and Settings (§3.14, §6.3): `ExtensionActionsProvider` first (needs only E1), then `ExtensionOmniboxProvider` when E12 lands; Shortcuts pane menu item and conflict notice | `suggest-check`, `commandbar-render`, `settings-preview` scenarios; X-22–X-27 |

Every PR: merge `origin/main`, run `tools/verify-all.sh`, paste the
table (AGENTS.md rule 10).

## 12. Screenshots needed from the user (Arc, their own machine)

No capture shows extension UI (§11 of the RE report). Ask the user for
these, in a light Space and in a dark Space, window at 2× if possible,
pointer positions as stated. Each settles the guesses named. Captures
stay in `.re/` (they may hold personal data); delete crops after
measuring.

| Id | Setup | Settles |
|---|---|---|
| S-1 | Install Bitwarden, uBlock Origin Lite, Dark Reader; pin all three. Window idle, pointer outside the sidebar | Whether pinned actions show without hover (EX-1, §3.2 rule 4) |
| S-2 | Same, pointer over the URL field; then sidebar width dragged to its minimum | Slot frames and order, more button, host minimum (§3.2) |
| S-3 | Click Bitwarden's slot; capture with the popup open, then Dark Reader's popup | Popup corner, gap, alignment, shadow, edge stroke (§3.7) |
| S-4 | Install any extension from the Chrome Web Store: capture the install sheet; then right-click → remove: capture the remove sheet | Prompt layout and text (§3.11) |
| S-5 | Open the Site Control Center with 3 extensions, then with 6+ | Rows vs grid, item size, pin button (§3.9) |
| S-6 | Right-click a pinned action | Context menu labels, especially pin and remove (§3.6) |
| S-7 | Little Arc with extensions installed: toolbar, then click its Extensions button | Button position and its menu (§3.4) |
| S-8 | Right after an install completes | Toast or bubble; auto-pin (Q4) |
| S-9 | Right-click a page that has extension context-menu items (for example with Dark Reader) | "Manage Extensions" position (§3.12) |
| S-10 | Split View with two tabs, focus the right pane, 3 pinned | Pane-bar slots (§3.3) |
| S-11 | Press Cmd+E | Picker look (§3.10) |
| S-12 | A badge with "999+" and one with a custom color | Badge drawing (EX-14) |

## 13. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| P2/P3 slip | Popups stay Alloy pages; no context menu; no prompts | Steps 1–4 do not need them (§10.4); `chrome://extensions` still manages |
| `toolbarImage` font differs from Arc | Badge text looks a little different (Views `CONTEXT_BADGE` font on macOS) | Same Chromium code as Arc; compare with S-12 |
| Hover-only slots hide badges | Users miss counts | Arc 1:1 per EX-1; Q2 lets the lead decide |
| Popup focus and child windows | Some extensions open a native file picker or a dialog from the popup; focus moves and D1 would close the popup | D1 reads `extensionPopupStaysOpenOnBlur` (JavaScript dialogs, web-modal dialogs such as WebAuthn, DevTools), as Chrome does. Sheets from the popup attach to the panel |
| Extension shortcut conflicts with page shortcuts | Router order §6.2 (3) before the page may surprise | Matches Chrome; reported in Settings |
| Many profiles | One `OEBrowser` per window and profile | Strips always follow the focused Space's profile |

## 14. Open questions for the lead (recommendation first)

| # | Question | Recommendation |
|---|---|---|
| Q1 | Cmd+E: Arc's "Open Extensions" picker, or Open's current "Use Selection to Find"? | Follow Arc: Cmd+E = `open-extensions-picker`; "Use Selection to Find" keeps no default key (as in Arc's nib) |
| Q2 | URL field slots only on hover (Arc evidence, guess) or always visible? | Hover, as Arc; revisit after S-1 |
| Q3 | Context menu labels for pin and remove before S-6 | "Pin"/"Unpin" and "Remove from Open…" |
| Q4 | Pin new installs by default (`kExtensionsPinnedByDefault`)? | Yes; switch off if S-8 shows Arc does not |
| Q5 | Chrome-style site-access toggles in the SCC, beyond Arc's context menu? | No (Arc parity); the context menu covers site access |
| Q6 | `chrome.sidePanel` in v1? Arc has it behind `extension-side-panel-enabled` | Not in v1; separate plan if users need it |
| Q7 | Manage page URL: show `chrome://extensions`, or add an `open://extensions` alias like Arc's `arc://extensions`? | `chrome://extensions`; an alias adds WebUI work for no user value |
| Q8 | Engine order: E11 (popup windows) with P1+ or after P3? | With P1+ (small; Bitwarden's pop-out needs it) |
| Q9 | An extension omnibox keyword equal to a Site Search name or keyword: which wins? | Site Search (built in, predictable); the extension stays reachable by name (§3.14.1) |

## Appendix — Lead decisions (2026-10-26)

- Approved as the extensions UI plan. The engine API needs go into the engine lead's P2/P3 queue, after #53 (P1) merges.
- Q1 Cmd+E opens Arc's extension picker. Remove Cmd+E from "Use Selection to Find".
- Q2 The URL field shows the extension slots only on hover, as Arc does. Re-check this after screenshot S-1.
- Q3 Context menu labels: "Pin" / "Unpin" and "Remove from Open…".
- Q4 A new install is pinned by default.
- Q5 The Site Control Center has no Chrome-style site-access toggles. The context menu covers site access.
- Q6 No `chrome.sidePanel` in v1.
- Q7 **Changed:** Chromium pages show in the URL field and command bar as `open://…`. This is a display alias only, matching Arc's `arc://…`; the engine still loads `chrome://`. It applies to `open://extensions` too. This aligns with the passwords plan Q-4.
- Q8 E11 (extension popup windows) ships with the P1 follow-ups.
- Q9 When a keyword is the same, Site Search wins over an extension omnibox keyword. The extension stays reachable by its name.
- Extension keyboard shortcuts (`chrome.commands`) need a keybinding registry without a focus manager; see PR #53 follow-up E15.
- The screenshots go into the user's single combined Arc capture session.

## Appendix — Engine P2 as built (2026-10-26, branch `m7/ext-p2-actions`)

The engine side of E1–E7 is in (docs/engine-patches.md, P2 status; docs/engine-api.md, `OEBrowser`). What the shell steps need to know:

- **E1.** As specified. `extensionActions` comes from Chrome's model while the window has a live Chrome style tab (`extensionActionsReady`, `isLive`). Without one (a new window, all tabs asleep) it is the profile's list: pins, names, default titles and icons, `isLive` false; nothing runs, and there is no manifest popup fallback (engine review r1). The shell hears `browserDidUpdateExtensionActions` when the live model comes or goes.
- **E2.** As specified, except `shortcutKeyEquivalent` and `shortcutModifierFlags`. They need the keybinding registry (E9, `docs/followups.md`). `toolbarImage` is nullable (nil without P2). `icon` is the current plain action icon (`setIcon` included), not the manifest icon. Both images are shared objects: copy one before you change its size. An unchanged image keeps its object across updates. `siteAccess` adds `.thisTab` (an `activeTab` grant).
- **E3.** As specified. A delegate without `browser(_:didUpdate:)` gets `browserDidUpdateExtensionActions` for single-action changes too.
- **E4.** As specified. Q4 is on: a new install (Web Store, Load unpacked) is pinned at the end of the pinned list. Extensions loaded with `--load-extension` at startup are not pinned; Chrome does the same.
- **E5.** As specified. The engine also gives D2: running the action whose popup is open closes it (Chrome's `ExecuteUserAction` does not toggle). An action with no popup for the tab fires `onClicked`. Example: 1Password without an account calls `setPopup({popup: ""})`, so its click opens its welcome tab through `browser(_:didOpen:active:)`. A disabled action asks for its context menu (`browser(_:requestsContextMenuForExtensionAction:)`), as Chrome shows it.
- **E6.** As specified. `didOpenExtensionPopup` comes first. `extensionPopupIsReady` comes once, when the first load stops. `didResizeExtensionPopup` comes whenever the page's size changes, so one can arrive after ready. `chrome.action.openPopup()` opens the popup with `extensionPopupSource == .api` (A4 anchor rules). Chrome allows that only for the profile's active window, and not while a popup is open. The engine closes the popup on an active-tab change (D5) and reports Chrome's keep-open state for D1 (`extensionPopupStaysOpenOnBlur`).
- **E7.** As specified. Chromium 156 titles in this build: the extension name, "Remove from Chromium" (no ellipsis; the product name is not branded yet), "Pin"/"Unpin" (not "Pin to Toolbar"), "Manage Extension", "View Web Permissions", plus "Options", the site-access submenu, and "Inspect Popup" when they apply. The §3.6 relabel table must match "Chromium", not only "Chrome". Each `OEExtensionActionMenu` keeps its own Chrome model, so an overflow menu and a Site Control Center menu can be open together; `select(command:)` returns whether it ran. Command results seen end to end:
  - Pin: pins.
  - Manage Extension: opens `chrome://extensions/?id=…` as a new tab.
  - View Web Permissions: opens `chrome://settings/content/siteDetails?site=…` as a new tab.
  - Remove: shows Chrome's own uninstall dialog until P3 (E10).

## Verification notes — Step 1: UI kit and metrics

[#175](https://github.com/SergeSerb2/open/pull/175) adds `OpenExtensionsUI`,
`ExtensionsMetrics`, immutable engine-image wrappers and `extensions-render`.
The saved acceptance has 16/16 checks, 11 scenes × light/dark × 1x/2x
(44 PNGs), and five menu models. `strip.*`, `pane.*`, `toolbar.nmax`,
`placement.*` and `strip.no-idle-work` prove geometry, ordering, hidden hit
refusal, drag intents and idle scheduling. These are real library CLI flows;
real browser behavior belongs to the later App suites.

## Verification notes — Step 2: hosted strips and popup panel

[#189](https://github.com/SergeSerb2/open/pull/189) wires URL/pane/toolbar
strips, `EngineExtensionHost` and `ExtensionPopupController`. `extensions-ui`
X3/X4 prove native hover/forced visibility, per-tab badges and pixel changes;
X6/X7 prove active-tab queries, key/ready panel state and content resize;
X8 proves native dismissal, popup Cmd+W, sidebar hiding and Inspect Popup's
blur exception; X18 proves the focused Split View pane's strip and anchor.
`actions` independently covers real popup hosts, callbacks and API popups.
The old M1 root bar, panel and placement/hiding bridge are removed.

The App receipt also runs `find` (58 PASS) with pinned actions. Its six F33
native-close rows cover toolbar off/on, both split panes, narrow panes and
Peek. `extensions-ui find_strip_no_overlap_native_close` checks actual Find
frames against URL/pane/toolbar/Peek strips, clicks the native close control,
and requires page focus plus visible strips. Section 11's `FindController`
([#187](https://github.com/SergeSerb2/open/pull/187)) is the only placement path.

## Verification notes — Step 3: menus and management entry points

[#175](https://github.com/SergeSerb2/open/pull/175) supplies native menu
builders; [#179](https://github.com/SergeSerb2/open/pull/179) supplies the
registry/management singleton; [#189](https://github.com/SergeSerb2/open/pull/189)
wires lazy menu updates, overflow and Little Open's button/menu.
`extensions-render menu.bar/menu.relabel` proves order and relabeling;
`extensions-ui X16_menu_bar`, `X16_menu_run`, `X17_manage_singleton` and
`overflow_menu_anchor` prove real actions and singleton selection.
`X19_button_menu` and `X19_zero_actions` prove the Little Open control/list.
Section 9 [#185](https://github.com/SergeSerb2/open/pull/185) supplies the standalone Chrome browser. The X-19 follow-up [#192](https://github.com/SergeSerb2/open/pull/192) binds only `factory.standaloneBrowser`, clears the old delegate/list on replacement, and keeps pending-page actions from borrowing a main-window target. Nine real-App rows PASS: button/menu, popup-less target, activeTab, popup tabs.query, popup anchor, extra-tab routing to main Today, one/zero actions and Profile replacement. Wrong-main-target and skipped re-attach faults each FAIL the intended row. Discarding extra tabs, or recreating them before their real URL arrives, FAILs the extra-tab row. All faults are removed and the restored flow PASSes; each final proof reports cleanup PASS. The final `extensions-ui` run has 53 PASS and only X-13 BLOCKED; 20 popup samples have ready-to-visible p95 7.55 ms (budget 16.7 ms, load1 7.49). The fixture requests optional activeTab/scripting permissions only for X-19, preserving the existing disabled-action checks. Section 9’s page creation and the engine are unchanged.
The page-context-menu "Manage Extensions" hook remains open in Section 11;
`PageContextMenuHooks.extensionItems` still defaults to empty.

## Verification notes — Step 4: SCC body and keyboard picker

[#175](https://github.com/SergeSerb2/open/pull/175) adds shared rows/tiles,
pin/context intents, arrow/wrap/type-select/Return/Esc and scroll-to-focus.
`extensions-render picker.keys` and `sitecontrol-render extensions-check`
(17 native-host checks) prove the library paths, including capped scroll
height and focus preservation across refresh. The App supplies a per-window
`extensionsUIContext`/refresh seam in [#189](https://github.com/SergeSerb2/open/pull/189).
`extensions-ui X13_picker` is BLOCKED: `.showSiteControls` is still a stub.
Section 12 owns the App SCC presenter/data source and the real Cmd+E gate.
**guess (child), S-5/S-11:** the 236 pt grid uses the SCC's whole width;
rows keep the existing 10 pt inset. This existing guess is not new closeout work.

## Verification notes — Step 5: P2 actions, pin/order and native drawing

Engine [#93](https://github.com/SergeSerb2/open/pull/93), safety fixes
[#177](https://github.com/SergeSerb2/open/pull/177) / [#184](https://github.com/SergeSerb2/open/pull/184),
and App [#189](https://github.com/SergeSerb2/open/pull/189) complete E1–E7.
`actions` (26 PASS) proves live snapshots, `setIcon`, real Chrome popup hosts,
`onClicked`, API popup refusal/blur behavior and native menus. `extensions-ui`
X2/X5/X9/X10/X11/X21 proves persisted pin/order, second-window consistency,
native drag, uBO Lite DNR badge burst, popup-less execution, grayscale pixels,
Options/site access, and ten seconds with zero redraws/layouts.
`extensions-e2 actions_pin_move_unique` / `actions_native_drag_safety` prove
repeated pins/moves, invalid indices and persisted-duplicate repair.
`tabstrip` (35 PASS) remains the independent sidebar/Chrome identity gate.

Chromium supplies the complete `toolbarImage`; no shell badge fallback remains.
Per-action changes update one button; image conversion caches by identity.
The App keeps the first occurrence of a duplicate ID in engine order, logs
it and reports `extensions.duplicatesDropped`. Pin/order/drag acceptance
requires that count to be zero; the guard does not hide an engine failure.
The App refuses unknown/unpinned moves, clamps destinations and skips no-ops.
The exact old crash sequence is pin uBO Lite, Dark Reader and probe; move
2→0; native drag 0→2. #184 fixes the model itself, distribution `3f45b07b`.

## Verification notes — Step 6: P3 management, prompts and commands

[#177](https://github.com/SergeSerb2/open/pull/177) implements E8–E10 and
P2 lifetime/cache fixes; [#175](https://github.com/SergeSerb2/open/pull/175)
supplies sheets/queue; [#189](https://github.com/SergeSerb2/open/pull/189)
wires the real presenters, toast and in-window shortcut table/router.
`extensions-p3` (14 PASS) proves live registry, named/action commands, stale
menu refusal, disable/re-enable, popup disable/uninstall, non-default Profile
install and the native-dialog fallback. Its hosted-store receipt and
`extensions` (8 PASS) prove the store/real-extension path.
`extensions-ui prompt_install_cancel_add`, X12/X14/X15, FIFO, toast Pin,
window-close and quit rows prove Open's exact sheets and routing. The UI
suite uses packed local CRX3 for deterministic consent; it does not by itself
prove a live Web Store install. The specific-sheet early-failure receipt in
#189 proves zero owned windows/processes after an aborted dialog case.

Open sheets are the normal handler. Chromium dialogs are used only when no
shell handler implements `showPrompt:`. Optional-permission Deny/Allow and
normal disable/re-enable are proven. Packed permission-increase update and
re-enable consent remain UNVERIFIED. Chromium creates each Profile's global
command registry, but OS delivery for `"global": true` remains UNVERIFIED;
in-process dispatch does not prove it. Extensions follow their Profile's own
context; Section 10 owns remaining per-Profile UI gaps. Q6 excludes
`chrome.sidePanel` from v1.

## Verification notes — Step 7: native extension windows (E11)

[#184](https://github.com/SergeSerb2/open/pull/184) implements the hidden
popup Browser/strip and `ExtensionWindowController`. `extensions-e2 X20_*`
proves native controller class, retained page/view/window identity, requested
bounds, resize/focus/update/remove, `chrome.windows` popup type and popup
Cmd+W. The same suite proves normal extension windows become selected Today
tabs and the sidebar move/pin/focus event mapping. Sized page `window.open`
panels remain a separate P1 follow-up.

## Verification notes — Step 8: command bar and Settings (X-22–X-27)

[#179](https://github.com/SergeSerb2/open/pull/179) supplies providers,
scopes and Settings; [#184](https://github.com/SergeSerb2/open/pull/184)
supplies E12 / `EngineCommandBarSource`; [#189](https://github.com/SergeSerb2/open/pull/189)
wires it to the focused Profile. `extensions-e2 X22–X26` proves by-name action
execution, scope chip/suggestions/cancel, current/new/background acceptance,
latest-text-only replies and Site Search priority. Its remaining E12 rows
prove delete/default refresh, disabled filtering and text/style bounds.
`suggest-check` extension scenarios, `commandbar-render` extension scenes
and `settings-preview` conflict scenes separately prove the library/UI paths.
`commands-dump` keeps missing/extra/different 0/0/0 and 11 allowed-missing rows.

[Closeout PR](https://github.com/SergeSerb2/open/pull/190)
adds `extensions-ui X27_shortcuts_menu_singleton`, `X27_binding_input_bounds`,
`X27_user_binding_conflict` and `X27_restored_extension_command`. The real pane's native menu item opens
and reselects one Today shortcuts tab. Its `record()` saves a New Tab user
binding through `KeyBindingStore` and `AppSettingsActions.keyBindingsDidChange`.
The rendered notice is exactly "Action Probe: ⇧⌘U is used by New Tab…, so it is off."
The table reports the named command dropped; Cmd+Shift+U opens Open's New Tab
command bar and leaves the extension counter unchanged. Reset removes the
notice and the next key fires the extension command once. Each run resets
bindings/defaults and restores them in `finally`. [Closeout receipt](../engine-spike/extensions-closeout-receipt.md)
records the deliberate conflict-filter break, FAIL and restored PASS.
Gap 37 is closed; global OS delivery remains separate.

## Verification notes — lead decisions and remaining captures

- **Toolbar, guess (lead), C1:** rightmost extension slot maxX = w−5;
  host-group left limit 115. Capacities are 23 at w 984/host 160 and 10 at
  w 600/host 120. SCC sits 4 pt left through
  `ToolbarMetrics.siteControls(width:stripWidth:)`.
- **Little Open, guess (lead), S-7:** button inside the URL capsule at
  [w−252,16,16,16], replacing the original §3.4 frame after Section 9's
  title bar changed. Host text yields to it.
- **Little Open, lead ruling A:** pages become Chrome-style tabs of their
  own `OEBrowser`; Section 9 implements this. Extension action/activeTab/
  tabs.query must target that page, with no main-window fallback.
- **Little Open extra extension tabs, guess (child), Section 6 lead ruling:**
  keep the standalone page and open each extra tab selected in the most
  recent main window's Today list. Hosted Chrome contents cannot change
  browsers, so retain the unshown extra content until its real address
  arrives, then recreate that URL there before closing the original on the
  next main-loop turn. Arc parity is unconfirmed; capture
  needed. `X19_extra_tab_main_today` exercises this route.
- Prompt fallback and the App duplicate-ID guard are the policies stated in
  Steps 5–6; the guard exposes `duplicatesDropped`, which acceptance requires
  to be zero. Neither is a second extension state store.

Raw receipts, negative patches and light/dark Open-only captures stay in
`.re/extensions-ui/` (closeout receipts in `.re/extensions-closeout/`). The
user's combined Arc session still owns §12 captures S-1…S-12 and toolbar C1;
Open-only renders do not establish Arc pixel parity. No baseline, comparator,
threshold or allowlist is loosened by this closeout.
