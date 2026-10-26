# Arc 1.170.0 — Advanced features: behavior and settings spec for Open

Target: Arc 1.170.0 (build 89123, commit `9f5625b3`), bundle ID `company.thebrowser.Browser`, engine `ArcCore.framework` 156.0.8078.48.

Scope: Split View, Peek, Little Arc, Boosts, Zap, Site Control Center, ad blocking, Picture in Picture and media controls, small features (Capture, Translation, Mini Player, Tidy Tabs, downloads, Library, sound effects, Arc Menu, Sidebar plus button, Sad Tab, URL inputter, TopDomains), and AppleScript. Out of scope, listed only where needed: Arc Max AI, Easels, Notes, accounts, sync, Boost sharing backend. Open has no accounts or sync; where Arc uses Firebase or CloudKit, Open stores the same shape locally.

Method note. Every claim cites the command, symbol, string, or file that proves it. Raw output stays in `.re/features-advanced/` (git-ignored). No Arc assets or code are copied; facts (names, keys, sizes, behaviors) are restated in our own words.

Evidence commands used: `strings -a .re/bin/Arc-arm64` (270,339 lines, `.re/features-advanced/strings-main.txt`), `strings -a .re/bin/ArcCore-arm64`, `nm`, `otool -L`, `plutil -p`, `xcrun assetutil --info`, `cat` / `python3 -m json.tool` on bundle resources, and read-only `defaults read company.thebrowser.Browser` plus schema-only inspection of `~/Library/Application Support/Arc/Storable*.json` (keys and types only; URLs and titles are not reproduced except for one redacted structural example that proves the schema). Help-center cross-checks cite `https://resources.arc.net` article URLs found in the binary; the help center now redirects to Zendesk login, so article titles come from the binary strings and from search results, not from fetched article bodies.

Tool limits, stated plainly:

- `rea inspect-asset-catalog` and `rea decode-interface-builder` rejected every `.car` and the single `MainMenu.nib` as "unsupported binary format". Asset names here come from `xcrun assetutil --info`. Menu structure comes from strings, not from a decoded nib.
- `rea inspect-native-dispatch-metadata` cannot use `--token-limit` with structured output, and the 80 MB binary exceeds the snapshot budget on other agents' runs. Swift type evidence here comes from `strings` (mangled names, `*.swift` file paths, selector names) and `nm`, not from dispatch metadata.
- The shared Ghidra project at `.re/ghidra/ArcMain` was still importing when this report was written (`.re/logs/ghidra-arcmain.log` ends inside the import). No `rea search` / `decompile` / `function` / `xrefs` call was run on the two large binaries. Behavior that only decompilation can prove is marked as a guess or an open question.
- `defaults read` reflects one signed-in user's current values, not factory defaults. Where this report gives a "default", it says whether the value was observed on this machine or inferred from strings. Factory defaults that need a fresh profile are listed as open questions.

Conventions in this spec:

- "Rule" numbers (for example `SV-1`) are stable IDs an engineer can implement and verify.
- Settings name the exact string found in the binary. `UserDefaults` keys, feature-flag keys (hyphenated, LaunchDarkly style), and `Storable*.json` fields are kept verbatim because Open must read the same names for Import from Arc.
- Each feature ends with **Settings**, **Evidence**, and **Open questions**. Guesses are marked `Guess:`.

---

## 1. Split View

Module evidence: Swift types `SplitViewController`, `SplitViewContentPane`, `SplitViewLayout`, `SplitViewState`, `SplitViewState_Legacy`, `WindowSplitViewLayout`, `SidebarSplitViewData` (`strings`: `SplitViewController`, `SplitViewLayoutOrientation`, `SplitViewState`). UI lives in `ARCUI/SplitViewController.swift` and `ARCUI/SplitViewContentPaneView.swift`; sidebar integration in `Arc/SidebarSpaceState+SplitView.swift`, `SidebarFeature/SidebarState+SplitView.swift`, and `Frameworks/ARC/Sources/SharedWindowsFeature/WindowsData+SplitView.swift`. The help article is `https://resources.arc.net/hc/en-us/articles/19335393146775-Split-View-View-Multiple-Tabs-at-Once` (string in binary).

### 1.1 Behavior spec

- **SV-1 — A Split View is one sidebar item with two or more child tabs.** The sidebar stores it as a single item whose `data` is `splitView`, with `childrenIds` listing the pane tabs in order. Proven by the on-disk schema: `StorableSidebar.json` → `sidebar.containers[].items[]` contains an item with `data.splitView = { itemWidthFactors: [], focusItemID: null, layoutOrientation: "horizontal", customInfo: null, timeLastActiveAt: null }`, `childrenIds: ["browserCompanySubstack", "arcTwitter"]`, and `parentID` pointing at its folder. Open must use the same shape for import: one parent item, ordered `childrenIds`, `layoutOrientation` of `horizontal` or `vertical`, `itemWidthFactors` as relative pane sizes, `focusItemID` as the focused child (or null).
- **SV-2 — The window tracks split state separately from the sidebar item.** `StorableWindows.json` → `windows[].contents.splitViewState = { windowContentIDs: [...], focusedContentID: ... }`. The sidebar item is the durable identity; the window state is the live pane list and focus. Open should restore both: reopen the sidebar item, then restore pane order and focus from the window state.
- **SV-3 — Maximum panes is 4.** Evidence: the binary contains exactly four jump commands — "Jumps to the first Split View page in your current window.", "…second…", "…third…", "…fourth…" — and no fifth-page jump for Split View (the "fifth item" string belongs to a generic list, not to Split View). Guess: the pane cap is enforced at 4 in `SplitViewController`; no string states the cap directly. Open implements a hard cap of 4 and disables "add pane" at 4. This needs a runtime check (see open questions).
- **SV-4 — Layout is horizontal or vertical, and it can be flipped.** Types: `SplitViewLayoutOrientation`, `SplitViewLayout`, `ConvertToHorizontalSplitView`, `ConvertToVerticalSplitView`. Menu strings: "Convert to Horizontal Split View", "Convert to Vertical Split View", "Flip to horizontal split view", "Flip to vertical split view", "A menu item to change a split view layout to horizontal layout", "A menu item to change split view layout to vertical layout". Rule: a split has one orientation; flipping swaps the axis and keeps pane order and focus.
- **SV-5 — Create a split five ways.** All five are proven by strings:
  1. Keyboard shortcut. Selector `addSplitViewKeyboardShortcut`, menu item `addSplitViewMenuItem`, titles "Add Vertical Split View", "New Vertical Split View", "Create Split View".
  2. Drag a sidebar tab onto the web view. String: "Drag a tab from your sidebar into the middle of the screen to create a Split View." Drag types: `SplitViewDragItem`, `SplitDragPreviewView`, flag `drag-to-combine-tabs-into-split-enabled`, `sidebar-drag-to-split-preview-ui-enabled`, `win-drag-to-split-enabled`, state `isDraggingToCreateSplitView`.
  3. Drag one tab onto another tab (combine). Same drag flags; action `openItemsInSplitView`.
  4. Context menu on a tab or link. Strings: "Open in Split View", "Open %@ in Split View", "Add to Split View", "Open item in split view", `explains a link opens in Split View`.
  5. Sidebar plus button. Release-note string: "You can now create a new Split from the plus button at the bottom of the Sidebar." (search result for the 2023 release notes; treat the exact menu label as runtime-checkable).
- **SV-6 — Add a pane to an existing split.** Strings: "Add a new split view", "Adds a new page to your current Split View.", "A menu item to add a bottom split view pane", "A menu item to add a right split view pane", "Action to add a vertical split view pane", `NewVerticalSplitViewPane`, `AddRightSplitCodingKeys`, `AddLeftSplitCodingKeys`, `AddTopSplitCodingKeys`, `AddBottomSplitCodingKeys`. Rule: "add right" and "add bottom" are the two directional adds; left and top exist as coding keys for state restoration and for flipped layouts. Each add appends one child ID and one width factor.
- **SV-7 — Resize by dragging the divider.** Types: `SplitViewDraggerHandleView`, `SplitViewBottomDraggerHandleView`, `SplitViewControllerDraggerHandleType`, `SplitViewConstraintType`, callbacks `onDidBeginWindowContentsSplitViewPaneResize` / `onDidEndWindowContentsSplitViewPaneResize`, and `itemWidthFactors` in the persisted item. Rule: dragging updates the two adjacent factors; the sum of factors stays constant; factors persist in the sidebar item so a restored split keeps its proportions. `SplitViewLayoutCache` (`SplitViewLayoutCache.layoutForWindowID`, `storeLayoutForWindowID`) caches the computed layout per window. Guess: minimum pane width exists but its value is not in strings; Open should pick 200 pt and verify at runtime.
- **SV-8 — Focus: exactly one pane is focused.** Persisted as `focusItemID` (sidebar) and `focusedContentID` (window). Clicking a pane focuses it; keyboard navigation ("Switch to next Split View", "Switch to previous Split View", and the first–fourth jump commands) moves focus without changing pane order. The focused pane owns the URL bar and the Site Control Center (see §6). Types: `SplitViewPaneMenuOperation`, `TabSplitViewPosition`, `hasActiveSplitViewInteraction`.
- **SV-9 — The sidebar shows one row for the whole split.** Types: `SplitViewCellView`, `SplitViewCellChildrenContainerView`, `SplitViewCellChildItemView`, `SplitViewCellItemCountIconView`, `SplitViewCellCustomInfoView`, `SplitViewCellState`, `SplitViewCellStrings`. The cell renders one child view per pane (favicon per pane, in pane order), a count icon, and an optional custom-info view. Fallback strings: "Fallback title for a sidebar split view item", "Placeholder for an untitled shared split view in the sidebar.", "Split view title text field placeholder". Rule: the row title is editable; if no title is set, show the focused pane's title (guess — verify at runtime). Selecting the row activates the split with its remembered focus.
- **SV-10 — Close a pane, separate a pane, close the split.** Strings and selectors: "Close Split View Pane" (`closeFocusedSplitViewPanel`, `closeSplitView`), "Remove Tab from Split View" ("Remove tab from split view button", tooltip "removes the child item from its split view and opens it in a separate tab."), "Separate Page from Split View.", "Separate from Split View" (`separateTabFromSplitView`, `separateFromSplitView`, menu item `separateTabFromSplitViewMenuItem`, "Title for a menu item that separates a tab from its split view container", "Title for menu item to separate all tabs from a split view sidebar item"). Rules:
  - Close pane: removes that child; if one pane remains, the split collapses to a normal tab (the "zombie split" guard proves Arc deletes empty splits: "Noticed zombie split view (without any children) in:", "Zombie split view found in", type `ZombieSplitSeenLocation`).
  - Separate pane: removes the child from the split and opens it as its own sidebar tab in the same Space; the split keeps the remaining panes.
  - Option-click the pane close button to unsplit, gated by flag `option-click-split-tab-close-button-to-unsplit-enabled`. Newer affordances are gated by `new-split-separation-mechanisms-enabled` and `split-view-actions-hover-button-enabled`.
- **SV-11 — Maximize one pane temporarily.** Selector `maximizeCurrentSplitViewPane:`, type `ARCUISplitViewMazimizeCurrentPane` (spelling as in binary). Rule: maximize expands the focused pane to fill the content area without destroying the split; restoring returns to the stored factors. Guess: this is the "expand" affordance on the pane toolbar.
- **SV-12 — Each pane has its own toolbar strip.** Types: `SplitViewContentPaneView`, `SplitViewContentPaneWithInsets`, `SplitViewContentPlaceholderView`, `WebContentViewControllerSplitView`, `ContentToolbarInteractionTracker`, flag `show-toolbar-in-split-view-enabled`, controls `shareSplitButton`, `contentToolbarCloseSplitButton`, `contentToolbarSplitViewMenu`. Placeholder: `SplitViewContentPlaceholderView` shows an empty state for a pane with no tab yet ("Add extension title for button in split view top drawer.", "Manage extensions title for button in split view top drawer."). Rule: every pane shows its own URL/title and its own close and menu buttons; the split-level menu ("Split View Options", "Split View Controls Menu", "Split View Context Menu", `SplitScreenMenu`) holds flip, add, separate-all, and share actions.
- **SV-13 — Share a split.** Strings: "Share Split View", "Button to copy a link to the current split view", `onTapShareSplitView`, `SplitViewShareIconView`, `sharedSplitView`, `SplitTabSource`, `SplitTabTarget`. Arc shares splits by link (account-backed). Open: sharing is out of scope; implement "Copy link" as a copy of the pane URLs, and import shared splits as local splits. Mark the link format as not reverse-engineered (needs a captured link).
- **SV-14 — Persistence.** The split survives quit and restore through the two stores in SV-1 and SV-2. `SplitViewState_Legacy` proves an older on-disk shape exists; Open's importer must accept both `SplitViewState` and `SplitViewState_Legacy`. Layout proportions persist via `itemWidthFactors`; per-window computed frames persist via `SplitViewLayoutCache` and `restorableSplitViewLayout`.

### 1.2 Settings (Split View)

| Key (verbatim) | Kind | Default | Evidence |
|---|---|---|---|
| `drag-to-combine-tabs-into-split-enabled` | feature flag | on (guess) | string in binary; no observed value |
| `sidebar-drag-to-split-preview-ui-enabled` | feature flag | on (guess) | string in binary |
| `win-drag-to-split-enabled` | feature flag | on (guess) | string in binary |
| `show-toolbar-in-split-view-enabled` | feature flag | on (guess) | string in binary |
| `option-click-split-tab-close-button-to-unsplit-enabled` | feature flag | on (guess) | string in binary |
| `new-split-separation-mechanisms-enabled` | feature flag | on (guess) | string in binary |
| `split-view-actions-hover-button-enabled` | feature flag | on (guess) | string in binary |

No `UserDefaults` boolean for Split View was found. Open should ship these as internal constants (all on) and not expose toggles unless Arc's Settings UI shows one (runtime check).

### 1.3 Evidence (Split View)

- Types and files: listed in §1 header; full list in `.re/features-advanced/split-strings.txt` (246 lines).
- On-disk schema: `StorableSidebar.json` split item and `StorableWindows.json` `splitViewState`, inspected read-only; structural fields quoted in SV-1 and SV-2.
- Help URL string: `https://resources.arc.net/hc/en-us/articles/19335393146775-Split-View-View-Multiple-Tabs-at-Once`.

### 1.4 Open questions (Split View)

1. Exact pane cap: is 4 enforced for both orientations, and does the "add pane" menu disable or hide at the cap?
2. Minimum pane width/height, and whether factors are equal by default on creation.
3. Default orientation for each creation path (shortcut, drag, context menu, plus button). The shortcut is named "Add Vertical Split View", which suggests side-by-side panes; confirm.
4. Sidebar row title rule when the split has no custom title.
5. Whether closing the focused pane moves focus to the left/top or right/bottom neighbor.
6. Whether a split can contain the same tab twice, a pinned tab, or a tab from another Space.
7. Exact keyboard shortcuts for add-split, next/previous pane, and jump-to-pane 1–4. (Owned by the hotkeys report; cross-check there.)

---

## 2. Peek

Module evidence: types `PeekState`, `PeekIntroduction`, selectors `openPeek`, `closePeek`, `peekItem`, `addPeekedItems`, `removePeekedItems`, state fields `isPeeked`, `peekedItemID`, `peekedPinnedSidebarItemID`, `transientPeekedItems`, `peekGroup` (`strings`, `.re/features-advanced/peek-strings.txt`). Email-specific peeking is a sibling path: `WindowData+EmailPeeking.swift`, `EmailPeeking`, `peekEmail`, `PeekedEmailAuthResult`. The general link Peek and the email Peek share the floating-preview chrome but have different triggers; this section covers link Peek and notes email where it differs.

### 2.1 Behavior spec

- **PK-1 — Peek is a floating preview of a link target, shown over the current page.** String: "Peek is a way to preview a link without opening a new tab." The preview is modal over the current web content; the underlying tab does not navigate. Types: `PeekState` holds the peeked item; `transientPeekedItems` holds peeks that are not persisted as tabs.
- **PK-2 — Trigger A: click a link inside a pinned or favorite tab.** This is the defining rule of Peek. When the active tab is pinned (including favorites, which are pinned tabs in the top grid), a normal click on a link to a different site opens Peek instead of navigating the pinned tab away. The pinned tab's URL is protected; Peek lets the user glance and either expand or dismiss. Evidence: the feature exists to keep pinned tabs fixed; strings `peekedPinnedSidebarItemID`, `opensInPeek`, `isPeeked`, plus the Settings strings in PK-5. Guess on the exact boundary: same-site links navigate in place, cross-site links peek. The binary has no string that states the same-site rule; verify at runtime.
- **PK-3 — Trigger B: Shift-click a link in any tab.** Settings string: "Open a Peek window when clicking on links with Shift held". Shift-click is the explicit, works-anywhere trigger. It applies in unpinned tabs as well.
- **PK-4 — Trigger C: email links.** `WindowData+EmailPeeking.swift` and `peekEmail:` show that links clicked inside the built-in email previews (Gmail and calendar previews) open as Peeks. Evidence: "d and favorited for email peeking." (truncated string), `EmailPeeking`, `PeekEmailCancellation`. Rule: mail and calendar preview links peek; expanding promotes the peek per PK-6.
- **PK-5 — Settings control both triggers.** Two Settings labels found verbatim: "Open a Peek window when clicking on links to other sites" and "Open a Peek window when clicking on links with Shift held". Rule: the first toggle gates PK-2; the second gates PK-3. A third string, `topBarInPeekWindowContentOverlapEnabled`, is a layout flag for the peek top bar, not a user setting. Flag `peeked-modal-controls-alternate-order-enabled` (also `peekedModalControlsAlternateOrderEnabled`) controls the order of the peek's modal controls (expand/close). Open: expose the two toggles with the same labels; keep the flags internal.
- **PK-6 — Expand a Peek into a full tab.** The peek chrome offers an expand action that converts the transient peek into a real tab in the current Space, placed with the unpinned (today) tabs, and selects it. The peek's loaded page is handed over, not reloaded (guess — verify that scroll position and form state survive). After expand, the originating pinned tab is unchanged.
- **PK-7 — Dismiss a Peek without creating a tab.** Dismiss by: clicking outside the preview, pressing Escape (string: "Exit the current context. Such as closing a Peek window or exiting fullscreen."), or the close control. On dismiss, the peeked page is discarded; no sidebar item is created. Undo affordance: string "Undo prompt for re-opening a closed Peek" proves Arc offers an undo toast after a peek is closed, which reopens the same URL as a peek (or as a tab — verify at runtime).
- **PK-8 — Peeks stack as a group.** Field `peekGroup` and the plural `transientPeekedItems`, plus `addPeekedItems` / `removePeekedItems`, prove more than one peek can exist. Guess: following a link inside a Peek pushes a nested peek onto the group; dismiss pops one level. Verify navigation and back behavior inside a peek at runtime.
- **PK-9 — A Peek is not a tab.** It has no sidebar row, is not in `StorableSidebar.json`, does not appear in tab cycling, and is gone after quit. Only expand (PK-6) creates a sidebar item. The `peeked` coding keys (`PeekedCodingKeys`) persist only enough to restore an in-session peek across window state changes, not across launches (guess).
- **PK-10 — Peek versus Little Arc.** Both show a page without a sidebar tab. Peek is anchored to the current window and Space and expands in place; Little Arc is a separate window that moves into a chosen Space (§3). A help-center snippet states the same distinction: with Little Arc you choose the workspace, with Peek the window opens in the current workspace (ZDNet summary of Arc behavior; treat as corroboration, not proof).

### 2.2 Settings (Peek)

| Setting (label verbatim) | Gates | Default |
|---|---|---|
| "Open a Peek window when clicking on links to other sites" | PK-2 (pinned/favorite clicks) | on (guess; needs fresh-profile check) |
| "Open a Peek window when clicking on links with Shift held" | PK-3 (Shift-click) | on (guess) |
| `peeked-modal-controls-alternate-order-enabled` | internal flag: control order in peek chrome | unknown |
| `topBarInPeekWindowContentOverlapEnabled` | internal flag: peek top-bar layout | unknown |

No `UserDefaults` key for Peek was found by name; the toggles likely live in the synced preferences store. Open stores them as two booleans with the same labels.

### 2.3 Evidence (Peek)

- Strings: `.re/features-advanced/peek-strings.txt`.
- Files: `Frameworks/ARC/Sources/SharedWindowFeature/WindowData+EmailPeeking.swift`.
- Preview help article: `https://resources.arc.net/hc/en-us/articles/19335284431639-Previews-Glance-Top-Sites` covers the related hover Preview; Peek and Preview are different features (Preview is hover glance, Peek is click). Open must not merge them.

### 2.4 Open questions (Peek)

1. Same-site versus cross-site rule for PK-2: what counts as "other sites" (exact host, registrable domain, or any different URL)?
2. Does Peek trigger from folder previews and from the command bar, or only from web content clicks?
3. Inside a Peek: do normal clicks navigate the peek, peek again, or open tabs? Is there back/forward inside a peek?
4. Does expand keep the loaded page (scroll, form state) or reload?
5. What does the close-undo prompt actually reopen: a peek or a tab? How long does it live?
6. Peek window size: fixed, proportional to the main window, or remembered? No size string was found.

---

## 3. Little Arc (Little Browser)

Module evidence: bundle `ARC_LittleBrowser.bundle`; types `LittleBrowserWindow`, `LittleBrowserSession`, `LittleBrowserEntryPoint`, `PersistedLittleBrowserState`, `LittleBrowserConstants`; view controllers `LittleWindowViewController` (`Browser/Windows/LittleWindowViewController.swift`), `LittleBrowserMoveMenuWindowController`, `LittleBrowserDownloadsTrayViewController`, `LittleBrowserNUXView`; store integration `WindowState+LittleBrowser.swift`, `WindowsData+LittleBrowser.swift` (`strings`, `.re/features-advanced/little-strings.txt`).

### 3.1 Behavior spec

- **LA-1 — Little Arc is a small, separate browser window with minimal chrome.** String: "Little Arc is a smaller, simpler Arc window." It has a compact toolbar (`LittleBrowserToolbar`, `LittleBrowserToolbarAction`), a command-bar-style URL field (colors `LittleBrowserCommandBarPlaceholderBackground`), a downloads tray (`LittleBrowserDownloadsTrayViewController`), and a profile indicator (`littleBrowserProfileIndicator`, `changeProfileInLittleBrowser`). It has no sidebar, no Spaces switcher, and no tab strip; one window shows one page. Window identity: `Arc.LittleBrowserWindow`, autosave name `.littleWindowAutosaveFrame`, size key `LittleBrowserWindow_size`. Types `WindowConstants.isLittleArc` and `little_arc_window_count` distinguish these windows from standard windows.
- **LA-2 — Entry point A: links from other apps, when Arc is the default browser.** Setting string: "Links from other apps open in Little Arc"; defaults key `openExternalLinksInLittleBrowserEnabled`; toggle handler `onToggleOpensExternalLinksInLittleBrowser`. Rule: an `http`/`https` link opened from another app creates (or reuses) a Little Arc window instead of a tab in the main window, provided the toggle is on and Air Traffic Control (§3.6) does not route the link elsewhere. Release-note corroboration: "If you click the same link within an external app, we'll simply resurface the existing Little Arc window instead of creating a duplicate one." Rule: dedupe by URL — resurface, do not duplicate.
- **LA-3 — Entry point B: global shortcut from anywhere.** Registration: `GlobalHotkeyListenerClient.registerLittleBrowserShortcut`, `GlobalHotkeyManager`, `newLittleBrowserHotkeyRegistration`, `registerLittleBrowserShortcut`, keys `globalLittleBrowserHotkeyEnabled`, `littleArcShortcut`, `openLittleArcKeyboardShortcut`. Settings label: "Open Little Arc when I press" (followed by the shortcut recorder). The shortcut works while other apps are frontmost; it opens a fresh Little Arc window ready for a search or URL ("Open Little Arc window for quick searches.", "Presents the Little Arc", menu "Show Little Arc"). The default shortcut is Cmd+Opt+N. Evidence for the keys: corroborated by press coverage ("Press Command-Option-N in any app to bring up a miniature Arc browser", Digital Trends) and by the `keyboardShortcutCommandOptionG` family of named shortcuts in the hotkey client; the exact default is not spelled out in strings. Marked as high-confidence, still verify at runtime. Open must register the same default and let the user change or disable it (`onToggleGlobalLittleBrowserHotkey`).
- **LA-4 — Entry point C: Option+Cmd-click a link inside Arc.** Keys: `optionCommandClickLittleArcEntryPointEnabled`, `onToggleOptionCommandClickLittleArcEntryPointEnabled`; label: "Open Little Arc when clicking on links with" (followed by the modifier glyphs). Rule: Option+Cmd-click on a web link opens that link in a Little Arc window, leaving the current tab untouched.
- **LA-5 — Entry point D: explicit open.** AppleScript can create tabs on the application object, whose element is documented as "a write-only collection that allows you to create new Little Arc tabs" (see §10). In-app menus also expose it: `newLittleWindowOpen`, `showLittleArc`, `onCreateLittleBrowserWindow`, `setLittleBrowserMenuItem:`. Dock and window menus: "Show Little Arc Windows" ("Makes all Little Arc windows visible"), "Close Little Arc Windows" ("Closes all open Little Arc windows"), flag `add-show-and-close-little-arc-window-to-dock-menu`. Behavior flag `little-arc-shows-under-command-bar-enabled` suggests Little Arc can appear under the command bar; treat as internal.
- **LA-6 — "Open in Arc": move the page into a Space.** The move control (`LittleBrowserMoveButton`, `littleBrowserMoveButton`, `LittleBrowserMoveMenu`, `LittleBrowserMoveMenuView`, `LittleBrowserMoveMenuWindow`, `showLittleArcOpenInMenu`, "Opens your current Little Arc tab in the Space of your choosing.", "A menu title for an action which presents options for moving a Little Arc tab to various spaces", types `LittleBrowserMoveToStandardWindowDestination`, `LittleBrowserMoveToListOption`) opens a menu of destinations: each Space (and, guess, pinned versus unpinned placement). Choosing one creates a real tab for the loaded page in that Space of the main window, selects it, and closes the Little Arc window. Analytics string `little_arc_moved_to_standard_window` confirms the move is a tracked, named action. Guess: if the main window is closed, moving opens it. Verify.
- **LA-7 — Profile handling.** A Little Arc window belongs to a Profile (`LittleBrowserCreationProfileType`, `profile_changed_in_little_browser`, `shouldBypassConfirmLittleBrowserProfileDialog`, string "Each Profile has different browser data, so this webpage might look a little different."). Rule: the window shows its profile; switching profile reloads the page with that profile's cookies and data; a confirmation appears unless bypassed. Open: one profile per Little Arc window, shown in the toolbar, switchable from the move menu or toolbar.
- **LA-8 — Auto-archive of stale Little Arc windows.** Settings: "Archive Little Arcs after:" with keys `autoArchiveLittleArcTimeThreshold`, `currentArchiveLittleArcThreshold`, `onSetAutoArchiveLittleArcTimeThreshold`, flag `auto-archive-little-arc-windows-enabled`. Rule: a Little Arc window idle longer than the threshold is closed and its page is kept in the Library archive (filter "Library Archive Tabs Little Arc Filter Title", §9.6). The threshold is a duration chosen in Settings; candidate values are not in strings (open question).
- **LA-9 — First-run education.** `LittleBrowserNUXView`, `LittleBrowserNUXState`, `hasDismissedLittleBrowserNUX`, `littleBrowserNUXPresentationCount`, image `NewLittleBrowserImage`, `LittleBrowserIntroduction`. Rule: the first Little Arc window shows a dismissible intro that explains the move-to-Space action; it shows a bounded number of times. Open reproduces the intro once.
- **LA-10 — Downloads inside Little Arc.** The downloads tray (`LittleBrowserDownloadsTrayItemView`, `LittleBrowserDownloadsTrayAction`) lists downloads started from Little Arc windows with the same states as the main downloads UI (§9.5). Rule: downloads are shared with the main window's download list; the tray is a compact view of the same data.
- **LA-11 — When Arc is not the default browser.** Little Arc still works for LA-3, LA-4, and LA-5; only LA-2 needs default-browser status, because the system delivers external links to the default browser. Open must not claim the external-link behavior unless Open is the default browser, and must say so in Settings next to the toggle (guess that Arc does this; verify).

### 3.2 Air Traffic Control interaction

Air Traffic Control is Arc's link-routing layer (which app or Space a link opens in). Evidence: `StorableLinkRouting.json` (on disk, schema inspected read-only), strings `OpenAirTrafficControlCodingKeys`, `openAirTrafficControl`, "air traffic control", "air traffic controller".

- **LA-12 — Routing rules are stored as source-component → destination rules.** On-disk shape: `{ rules: [{ id, sourceComponents: [{ id, componentType: { urlMatch: { _0: { contains: {} }, _1: "meet.google.com" } } }], destination: { space: { _0: { mostRecent: {} } } } }], defaultDestination: { littleArc: { _0: { mostRecent: {} } } }, version: 1 }`. The observed default destination is Little Arc (most recent Space context). Destinations seen in strings and schema: a specific Space, the most recent Space, and Little Arc. Guess: destinations also include "current Space" and specific external apps; the full destination enum needs runtime data.
- **LA-13 — Order of decision for an external link.** (1) Match routing rules by URL components; first match wins. (2) Else the default destination. (3) The default is Little Arc only if `openExternalLinksInLittleBrowserEnabled` is on; otherwise the link opens as a tab in the most recent main window. Open implements this order and imports `StorableLinkRouting.json` verbatim.

### 3.3 Settings (Little Arc)

| Key / label (verbatim) | Kind | Default | Evidence |
|---|---|---|---|
| `openExternalLinksInLittleBrowserEnabled` / "Links from other apps open in Little Arc" | toggle | on (observed pattern; verify fresh) | strings + `StorableLinkRouting.json` default |
| `globalLittleBrowserHotkeyEnabled` / "Open Little Arc when I press" | toggle + shortcut recorder | on, Cmd+Opt+N (high-confidence) | `GlobalHotkeyListenerClient.registerLittleBrowserShortcut` |
| `optionCommandClickLittleArcEntryPointEnabled` / "Open Little Arc when clicking on links with" | toggle | on (guess) | strings |
| `autoArchiveLittleArcTimeThreshold` / "Archive Little Arcs after:" | duration picker | unknown (open question) | strings |
| `auto-archive-little-arc-windows-enabled` | feature flag for LA-8 | on (guess) | string |
| `hasDismissedLittleBrowserNUX`, `littleBrowserNUXPresentationCount` | internal state | — | strings |
| `LittleBrowserWindow_size`, `.littleWindowAutosaveFrame` | persisted window frame | unknown size (open question) | strings |

### 3.4 Evidence (Little Arc)

- Strings: `.re/features-advanced/little-strings.txt`.
- Files: `Browser/Windows/LittleWindowViewController.swift`, `Frameworks/ARC/Sources/LittleBrowser/LittleBrowser.swift`.
- On-disk: `StorableLinkRouting.json` schema quoted in LA-12; `StorableWindows.json` distinguishes standard windows (Little Arc windows are counted separately as `littleArcWindowCount` in metrics).

### 3.5 Open questions (Little Arc)

1. Default window size and position (centered? under the pointer? remembered per display?). `LittleBrowserWindow_size` exists but its value is not in strings.
2. Auto-archive threshold options and default (hours? days?).
3. Full Air Traffic Control destination enum and source-component types (domain, URL contains, app source?).
4. Does the global shortcut open a new window each time or reuse an empty one? Does it focus the URL field?
5. Move-to-Space: pinned or unpinned placement, and behavior when the page is already open as a tab.
6. Multiple Little Arc windows: cap, cycling, and "Show/Close all" exact behavior.

---

## 4. Boosts

Module evidence: bundles `ARC_BoostsEditor.bundle`, `ARC_BoostsDialog.bundle`; client `BoostsClient` (`Frameworks/ARCClients/Sources/BoostsClient/BoostsClient.swift`), storage `LocalBoostsDataStore`, `StorableBoostsData`, file `StorableBoostsData.json`; editor `BoostsEditor` (`Frameworks/ARC/Sources/BoostsEditor/BoostsEditor.swift`), dialogs `BoostsDialog` (`BoostsInstallationDialog.swift`, `BoostsSharingDialog.swift`); web-content glue `WebContentState+Boosts.swift`, `WindowState+Boosts.swift`, `BoostsWebContentHelper` / `BoostsWebContentHelperImpl`; help article `https://resources.arc.net/hc/en-us/articles/19212718608151-Boosts-Customize-Any-Website`. Strings in `.re/features-advanced/boost-strings.txt` (334 lines).

### 4.1 Data model

- **BO-1 — A Boost is a per-site customization record.** Core types: `BoostData`, `BoostFile`, `BoostType`, `BoostID`, `BoostConfiguration`, `BoostKeys`, `BoostAttribute`, `BoostSignature`, `BoostSnapshotData` / `BoostSnapshotID` / `BoostSnapshotAttribute`. The client API proves the shape: `BoostsClient.createBoost`, `setBoostData`, `queryBoostData(id:)`, `boostData`, `boostsMatching`, `boostSnapshotsMatching`, `boostSnapshotData`, `createBoostSnapshot`, `deleteBoost`, `setEnabled`, `subscribeToBoostsMatching`. Rule: a Boost has an ID, a target site pattern (host match), a title, an author, an enabled flag, and one or more data components. Open stores the same fields locally in `StorableBoostsData.json` (path proven by the string `StorableBoostsData.json`) so Import from Arc can read Arc's file.
- **BO-2 — Components: CSS, JavaScript, fonts, text controls, color, and Zaps.** Evidence by type: CSS — `arc://boost/v2/css/` URL scheme, field pair `boostID` + `css` (`SS7boostID_SS3csst`), file type `BoostFile`; JavaScript — `BoostsEditor/JS.swift`, `WebContentBoostIDE`, strings "!!! fyi: you cannot share Boosts that contain javascript !!!" and "BoostData unexpectedly includes JS; rejecting as invalidData" (the second proves JS is validated separately from CSS-only boosts); fonts — `BoostFont`, `BoostFontOption`, `BoostsEditorFontPicker`, bundle `ARCClients_FontsManager.bundle`; text — `BoostTextZoom` / `BoostTextZoomOption` / `BoostsEditorTextZoomButton`, `BoostTextTransform` / `BoostsEditorTextTransformButton`; color — `BoostColorScheme`, `BoostColorWheelScheme`, color assets `BoostsBlue`, `BoostsYellow`, `BoostsOrange`, `BoostsRed`, `BoostsLabel`; element hiding — field `zaps` (see §5). Rule: a Boost is a bundle of independent components; any subset can be present. The simple "Customize" panel edits the non-code components; the full editor edits CSS and JS as text.
- **BO-3 — Color model: hue-based site recolor.** `BoostColorScheme` and `BoostColorWheelScheme` plus the wheel UI prove the simple panel offers a color wheel that remaps the site's colors. The generated CSS is served from `arc://boost/v2/css/<id>` (guess: the engine fetches the generated stylesheet from this internal scheme at injection time). Open: store the wheel choice (hue rotation and scheme) and generate equivalent CSS variables/filters; do not store Arc's generated CSS verbatim for import fidelity — store both the wheel state and the final CSS text when present.
- **BO-4 — Fonts and text controls are declarative.** `BoostFont` selects a font family (from the bundled FontsManager set plus system fonts; exact list needs runtime data); `BoostTextZoom` scales text; `BoostTextTransform` changes case transforms. These compile to CSS. Rule: they apply site-wide, not per-element.
- **BO-5 — Enable state is per Boost and per site.** Client: `BoostsClient.setEnabled`, fields `areBoostsEnabled`, `locallyEnabledBoostIDs`, `has_active_boost`, analytics `boost_set_is_active`, `hasDisabledBoostsInPreferences`. Matching: `boostsMatching` and `subscribeToBoostsMatching` take the current URL and return applicable boosts. Rule: a Boost applies only when its site pattern matches the page host AND the Boost is enabled AND the global Boosts preference is on. Disabling is per Boost; the global toggle (`onToggleBoostsEnabled`, `isBoostsPreferenceToggleEnabled`, flag `boosts-v2-enabled`) turns the whole system off without deleting data.
- **BO-6 — Snapshots are the shareable form.** `BoostSnapshotData` is an immutable copy of a Boost at a moment in time; install flow: `BoostsInstallationDialog`, strings "Add this Boost to Arc?", "Boost installed!", "Boost cannot be installed", "Open this link outside Incognito Mode to install this Boost", `didInstallBoostFromSnapshot`, `forkedFromBoostID`, `onUserWantsToCopyBoostSnapshot`. Rule: installing copies the snapshot into a local Boost with a new ID and `forkedFromBoostID` pointing at the source. Sharing itself (link creation, Firebase storage `BoostsStorageFirebaseImpl`, `BoostsFirebaseRefs`, `BoostsImageCache`) is out of scope for Open; Open imports the local `StorableBoostsData.json` and ignores remote refs, and must reject JS-containing snapshots on import only if Arc does (the "rejecting as invalidData" string suggests validation rejects JS in one path — see open questions).
- **BO-7 — Lifecycle events.** Analytics strings prove the named actions Open should mirror as operations (not telemetry): `boost_created`, `boost_edited`, `boost_deleted`, `boost_installed`, `boost_shuffled`, `boost_share_dialog_opened/completed/closed`, `boost_install_dialog_opened/closed`, `boost_edit_source` with `BoostEditSource`. Editor state: `BoostsEditorViewState`, `lastActiveBoostID`, `latestBoostSnapshotID`.

### 4.2 Injection

- **BO-8 — Boosts are applied to every matching web content by a dedicated helper.** `BoostsWebContentHelperImpl` with `BoostsClient.applyToWebContent` and `applyToAllWebContents`. Rule: on navigation (and on Boost edit), the helper computes the matching set for the new URL and applies it; editing a Boost re-applies to all open matching tabs without reload (guess — verify).
- **BO-9 — CSS is injected as a stylesheet; JS as a user script.** The `arc://boost/v2/css/` scheme proves CSS is delivered as a fetchable stylesheet resource. JS goes through the Boost IDE bridge: `ArcWebContentsBoostIDEDelegate`, `boostIDE:didRequestExecuteCommand:jsonString:`, `BoostIDECommand`, `BoostIDERequest` / `BoostIDEResponse`, `BoostIDEEvent`, `sendEvent(boostID:event:)`. Guess: CSS injects at document start so the page never paints unstyled; JS injects at document start as a user script in the page world. Neither timing is spelled out in strings; Open should use document-start for both and flag the guess for runtime verification (check for flash of unstyled content and for whether Boost JS can run before page JS).
- **BO-10 — Incognito and unsupported contexts.** The install dialog refuses Incognito ("Open this link outside Incognito Mode to install this Boost"). Guess: Boosts do not apply in Incognito windows. Verify.

### 4.3 Editor UI

- **BO-11 — Two editing surfaces.** (a) The simple panel ("Customize" panel): opened from the Site Control Center (§6) for the current site; offers color (wheel/schemes), font, text zoom/transform, and Zap (§5) without code. Evidence: `SiteControlCenterBoostsView`, `Customize Page`, the Boost button in the toolbar (`BoostIndicatorButtonState`, icon `boost.fill` / `boost.sparkle`). (b) The full editor window: `BoostsEditorWindowController`, `BoostsEditorWindowContent`, `BoostsEditorView`, `BoostsEditorHeader`, `BoostsEditorCodeInputPanel`, `BoostsEditorShelfController` / `BoostsEditorShelfView` / `BoostsEditorShelfConstants`, `BoostsEditorOverlayController` / `BoostsEditorOverlayView`. The shelf holds the simple controls; the code panel holds CSS/JS text with Monaco (flag `boosts-v2-monaco-enabled`, `BoostsEditor` v2). Rule: both surfaces edit the same `BoostData`; switching does not create a second Boost.
- **BO-12 — Editor lifecycle.** Strings: "Edit the Internet with Boosts", "Enable Boosts on websites you visit", "Nothing Boosted Yet!", `BoostsEditorInterstitial`, `hasDismissedBoostsInterstitial`, `BoostsEmptyStateView`, `canShowBoostsEditor`, `hideBoostsEditor`, `hideEditorsOfBoost`. First open shows an interstitial; the gallery/empty state lists existing Boosts (`BoostCell`, `BoostsPage`, `HomeBoostsDelegateAction`, flag `boosts-in-arc-home-enabled` for the Arc Home Boosts page). Delete flow: "Delete this Boost?", "Delete and unshare this Boost?", "Links to this Boost will stop working. People who have installed it from those links will keep it.", "Deleting a Boost can" (truncated). Rename flow: "Rename this Boost". Open mirrors these dialogs in its own wording; the Firebase sentences are Arc-specific and Open omits the sharing consequence.
- **BO-13 — The editor previews live.** `HoveredElementTracker`, `HandleGesturesMarkerView`, and the overlay controller prove the editor draws over the live page (element hover highlight for Zap, §5) and updates the page as controls change. Preview images: `BoostsClient.uploadPreviewImage`, `setLocalPreviewImage`, `localPreviewImage`, `BoostsImageCache`. Open: live preview is required; preview-image upload is out of scope (store locally only).

### 4.4 Settings (Boosts)

| Key / label (verbatim) | Kind | Default | Evidence |
|---|---|---|---|
| Global Boosts preference (`onToggleBoostsEnabled`, `isBoostsPreferenceEnabled`) | toggle | on (guess) | strings |
| `hasDisabledBoostsInPreferences` | state: user turned Boosts off in Settings | — | string |
| `boosts-v2-enabled` | feature flag (v2 editor) | on | string |
| `boosts-v2-monaco-enabled` | feature flag (Monaco code editor) | on (guess) | string |
| `boost-sharing-enabled` | feature flag | on in Arc; off/absent in Open | string |
| `boosts-in-arc-home-enabled` | feature flag (Home gallery) | on (guess) | string |
| `areBoostsEnabled`, `locallyEnabledBoostIDs` | runtime state | — | strings |

Observed on this machine: no Boost defaults appear in `defaults read` output, so the preference lives in the app's synced/store layer, not in plain `UserDefaults`. Open stores it in its own preferences with the same semantics.

### 4.5 Evidence (Boosts)

- Strings: `.re/features-advanced/boost-strings.txt`.
- Files: `Frameworks/ARCClients/Sources/BoostsClient/BoostsClient.swift`, `Frameworks/ARC/Sources/BoostsEditor/BoostsEditor.swift`, `ADK/WebContentBoostIDE.swift`.
- Selector picker script (also §5): `ARC_BoostsEditor.bundle/Contents/Resources/SelectorPicker.js`, copied to `.re/features-advanced/SelectorPicker.js`.

### 4.6 Open questions (Boosts)

1. Site-pattern syntax: exact host, domain + subdomains, or full URL pattern? Does one Boost cover `example.com` and `www.example.com`?
2. CSS/JS injection timing and world (document start/end; main world versus isolated world). Does Boost JS see page JS variables?
3. The JS validation rule behind "BoostData unexpectedly includes JS; rejecting as invalidData": which path rejects JS, and is it a sharing restriction or an import restriction?
4. Font list offered by the simple panel, and whether custom fonts can be added.
5. Color wheel semantics: hue rotation only, or full palette remap? What does `BoostColorWheelScheme` enumerate?
6. Do Boosts apply in Peek, Little Arc, and Split View panes? (Guess: yes, everywhere the helper runs.)
7. Conflict order when two Boosts match one site.

---

## 5. Zap

Zap is the element-hiding component of a Boost. Evidence: bundle script `SelectorPicker.js`; types `IndividualZapCell`; functions `appendZap`, `removeZap`, `setZapToPreview`, field `zapToPreview`, array field `zaps`; strings "Zap all related elements", "Failed to run Zap JS", color `ZapPreviewBackground`. Zap has no separate bundle; it lives inside `BoostsEditor`.

### 5.1 Behavior spec

- **ZA-1 — Zap is an element picker over the live page.** From the Boost editor (simple panel or full editor), the user enters Zap mode, hovers the page (the editor's `HoveredElementTracker` highlights the element under the pointer), and clicks to hide that element. The highlight uses the `ZapPreviewBackground` color. Rule: hover shows the candidate element's box; click commits one Zap.
- **ZA-2 — The picker computes a robust CSS selector, not a single brittle path.** The bundled `SelectorPicker.js` proves the algorithm in detail (file copied to `.re/features-advanced/SelectorPicker.js`; facts restated here, code not copied):
  - It assigns each visited element a stable temporary ID (`__arc_id`) and scores candidate selector terms by "semanticness": known semantic class/ID words score `+1`, gibberish-looking names score `-1` (detected by digit count, mixed case, rare letter pairs, and long consonant runs), semantic tags (`article`, `nav`, `h1`–`h6`, and similar) score `+0.5`, plain tags `-0.1`, `aria-label` `+0.8`, `data-testid` `+1`, `href` `+0.6`, positional pseudo-classes `-0.1`.
  - It generates candidates from the element and its ancestors (up to 8 levels) and descendants (up to 2 levels, using `:has(...)`), counts matches for each candidate with `querySelectorAll`, discards candidates with 0 matches or more than 100 matches, prefers selectors whose matches all share computed style, and returns at most 15 candidates sorted by match count, with a diversity pass that buckets candidates so near-duplicates do not fill the list.
  - Exposed functions: `window.getHoveredElement(x, y)` returns the element rect and a hash of tag + ID + classes + sibling index; `window.getSelectorCandidates(x, y)` returns `[{selector, matches}]`; `window.rectsForSelector(selector)` returns all matching rects for preview.
  Open must implement the same behavior (same scoring intent and the same three entry points) in its own code, because imported Boosts store the resulting selectors and Arc's picker quality is the feature.
- **ZA-3 — "Zap all related elements" widens one pick to its siblings.** String verbatim: "Zap all related elements". After a pick, the editor offers to expand the selector so it matches the repeated similar elements (the candidate whose match set covers the siblings). The `matches` count and `rectsForSelector` preview show exactly what will hide before the user confirms. Rule: preview first (all matching rects highlight), then commit.
- **ZA-4 — Storage: Zaps are selector strings inside the Boost.** The Boost's `zaps` array holds the committed selectors; `appendZap` adds one, `removeZap` deletes one, `setZapToPreview` / `zapToPreview` hold the hover candidate. The editor lists them as `IndividualZapCell` rows. Rule: each Zap is one selector string; order does not matter; duplicates are not stored twice (guess).
- **ZA-5 — Application: Zaps hide by CSS.** At injection time (§4, BO-9), each Zap selector becomes a hide rule (`display: none` — guess on the exact declaration; the picker script itself only computes selectors, and "Failed to run Zap JS" proves a JS step runs the Zap logic in the page). Rule: zapped elements are hidden on every load of a matching site while the Boost is enabled; disabling the Boost or deleting the Zap restores them on next load or live (verify live versus reload).
- **ZA-6 — Undo and management.** Inside the editor, each Zap row can be deleted (`removeZap`), which un-hides that element set. There is no separate global undo stack for Zaps in strings; the editor's own undo (if any) is not evidenced. Rule for Open: per-Zap delete in the editor, plus the editor's standard undo for the last Zap action (mark as guess until runtime check).

### 5.2 Settings (Zap)

No user-facing Zap setting exists. Zap availability follows the Boosts global toggle (§4.4). The picker constants worth copying as behavior (from `SelectorPicker.js`): max 15 returned candidates, discard selectors matching more than 100 elements, ancestor depth 8, descendant depth 2.

### 5.3 Evidence (Zap)

- Script: `/Applications/Arc.app/Contents/Resources/ARC_BoostsEditor.bundle/Contents/Resources/SelectorPicker.js` → `.re/features-advanced/SelectorPicker.js`.
- Strings: `.re/features-advanced/zap-strings.txt` (small set; Zap is mostly implemented in the editor and the script).

### 5.4 Open questions (Zap)

1. Exact hide declaration (`display:none !important`?) and whether hiding is live without reload after commit and after delete.
2. Does Zap mode work on elements inside iframes or shadow DOM?
3. Selector stability: are stored selectors re-validated when the site changes, and is the user warned when a Zap matches nothing?
4. Is there a keyboard shortcut or menu item that enters Zap mode directly, outside the Boost editor?

---

## 6. Site Control Center

Module evidence: bundle `ARC_SiteControlCenter.bundle`; feature `SiteControlCenterFeature` (`Frameworks/ARC/Sources/SiteControlCenter/SiteControlCenterFeature.swift`); views `SiteControlCenterViewController`, `SiteControlCenterSettingsView`, `SiteControlCenterBoostsView`, `SiteControlCenterExtensionsView`, `SiteControlCenterFooterView`, `SiteControlCenterSectionView`, `SiteControlCenterSettingView` (`SiteSetting+Display.swift`); state `PersistedSiteControlCenterState`, `SiteControlCenterButtonState`, `SiteControlCenterButtonInteraction`. Strings in `.re/features-advanced/sitec-strings.txt`.

### 6.1 Behavior spec

- **SC-1 — The Site Control Center is a popover panel for the current site, opened from the URL area.** Entry: the site icon / lock button in the sidebar URL bar ("Site Control Center Button", "Site Control Center button", "Accessibility label for command bar placeholder button that opens site control center", `onTapSiteControlCenterButton`, `siteControlCenterButton`, `siteControlCenterView`). The security affordance is labeled by state: "Title for the site control center security button on a secure site." and the matching insecure-site title. Rule: clicking the URL icon opens the panel anchored to the URL bar; in Split View it describes the focused pane's site (§1, SV-8); in Peek it is unavailable or describes the peeked site (guess — verify).
- **SC-2 — Section 1: site settings (permissions).** `SiteControlCenterSettingsView` lists per-site settings for the current origin. The setting type is `ArcSiteSetting` / `SiteSetting` with display strings in `SiteSetting+Display.swift`; the write path is `setContentSettingsForOrigin:withContentSettingTypes:withSiteSetting:` and `setPermissionsForOrigin:withPermissionTypes:withSiteSetting:`, with callbacks `didChangeSiteSetting`, `onSiteSettingClick`, `advancedSiteSettingsClicked`, `reloadSiteSettings`. Permission prompt strings prove the categories are Chromium content settings (notifications, storage, multi-download, `mailto:` handling, idle detection, and the rest of the Chromium set). Rule: each row shows the current value for this origin (allow/block/ask, per Chromium) and lets the user change it; changes write through to the engine's content-settings store for that origin and profile. Header actions: "View Site Settings", "All Site Settings" (`onAllSiteSettingsClick`) opens the full settings page; `UserDefaultsClient.resetTranslateSettings` has a sibling reset here ("Reset Translated-site Prompts" belongs to Translation, §9.2).
- **SC-3 — Section 2: Boosts for this site.** `SiteControlCenterBoostsView` / `SiteControlCenterBoostView` ("Title for Boosts section in site control center", "Text shown on hover of Boosts section in site control center", "Tooltip for the new Boost button in the site control center."). Rule: the section lists Boosts matching the current site with per-Boost enable toggles, an edit action that opens the Boost editor (§4), and a new-Boost button that creates a Boost scoped to this site and opens the simple editor.
- **SC-4 — Section 3: extensions for this site.** `SiteControlCenterExtensionsView`, `SiteControlCenterExtensionButton`, `SiteControlCenterExtensionPinButton`. Rule: lists extensions that have access to (or request access to) the current site, with pin/unpin and per-site access controls, mirroring Chromium's extension site-access model. Exact row contents need runtime data.
- **SC-5 — Footer actions.** `SiteControlCenterFooterView` plus `SiteControlCenterActionButton`. Tooltips prove the action set: "Tooltip for the capture button in the site control center." (§9.1), "Tooltip for the capture in Portrait Mode button in the site control center.", "Tooltip for the full-page capture button in the site control center.", "Tooltip for the copy URL button in the site control center.", "Tooltip for the share button in the site control center.". Rule: the footer offers Capture, Capture in Portrait Mode, Capture Full Page, Copy URL, and Share for the current page.
- **SC-6 — Ad blocker toggle lives here.** The panel shows the native ad-block state for the site with a per-site disable. Evidence: `AdBlockDisableScopeAction`, `nativeAdBlockDisableScopeDialogAction`, `nativeAdBlockDisableScopeDialogShown`, and the reload follow-up `AdBlockReloadFollowUpAction` / `nativeAdBlockReloadFollowUpShown` (changing the state offers or performs a reload). Detail in §7. The disable scope dialog asks how broadly to disable (this site, or wider); exact options need runtime data.
- **SC-7 — Security info.** The panel header shows connection security for the origin (secure versus insecure titles above). Guess: it also shows certificate details on click-through, following Chromium's page-info model. No certificate strings were found; verify at runtime and keep Open's first version to the secure/insecure state plus origin display if the detail is absent.
- **SC-8 — Cookies and site data.** No cookie-specific strings were found in the Site Control Center module. Chromium content settings (SC-2) cover cookies as one setting type, but a dedicated cookie viewer is not evidenced. Open: expose cookies only through the content-settings row; do not invent a cookie browser. Marked as an open question.

### 6.2 Settings (Site Control Center)

| Item | Kind | Default | Evidence |
|---|---|---|---|
| `PersistedSiteControlCenterState` | persisted panel state | — | string |
| Per-origin content settings | Chromium content settings store | Chromium defaults | `setContentSettingsForOrigin:...` |
| Per-site ad-block disable | exclusion list (§7) | empty | `AdBlockDisableScopeAction` |

### 6.3 Evidence (Site Control Center)

- Strings: `.re/features-advanced/sitec-strings.txt`.
- Files: `SiteControlCenter/SiteControlCenterFeature.swift`, `SiteControlCenter/SiteSetting+Display.swift`, `SiteControlCenter/SiteControlCenterSettingsView.swift`, `SiteControlCenter/SiteControlCenterBoostsView.swift`, `SiteControlCenter/SiteControlCenterExtensionsView.swift`.

### 6.4 Open questions (Site Control Center)

1. Full section order and which sections collapse; does the panel show the site's cookies/storage size?
2. Certificate/security detail depth (issuer, validity, "connection is secure" text?).
3. Ad-block disable scope options (this page, this site, this session, everywhere?).
4. Extension row actions (pin, remove, manage, site-access toggle labels).
5. Does the panel open from the command bar as well as the URL icon?

---

## 7. Ad blocking

Module evidence: client `BlockListClient` (`Frameworks/ARCClients/Sources/BlockListClient/BlockListClient.swift`, `BlockListConfiguration.swift`, `BlockListClient+Live.swift`, `BlockListClient+FeedInfo.swift`), bundle `ARCClients_BlockListClient.bundle` with bundled `EasyList.txt`, `EasyPrivacy.txt`, and `manifest.json`; UI `ARC_AdBlocking.bundle` (`AdBlocking/AdBlocking.swift`, `ManageAdBlockersDialogContext.swift`, `AdBlockAdvancedSettingsDialog`); engine glue `ADKClient.setBlockLists`. Strings in `.re/features-advanced/adblock-strings.txt`; manifest copied to `.re/features-advanced/blocklist-manifest.json`.

### 7.1 Engine and lists

- **AD-1 — Arc has a native ad blocker separate from extensions.** Keys: `nativeAdBlockEnabled`, `native.adblocker.enabled`, `nativeAdBlockFeatureEnabled`, `nativeAdBlockerEnabled`, `supportsNativeAdBlocker`, states `nativeAdBlockActive`, `nativeAdBlockAvailable`. The user can also install extension blockers; Arc detects them (`AdBlockerExtensionID`, known IDs in strings: `adblockPlus`, `uBlock`, `adblockerultimate`, `bestAdBlock`, `fairAdBlocker`, `totalAdBlock`, `adBlockMax`, `adBlockForChrome`, "AdBlock", "AdGuard AdBlocker", "AdLock"). Rule: native blocking and extension blocking are independent; Settings and onboarding (`AdBlockersSelection`, `hasCompletedMultipleAdBlockersSelection`, `multipleAdBlockersPromptShown`) warn when several blockers run at once.
- **AD-2 — Filter lists are Adblock Plus syntax text lists.** The bundled `EasyList.txt` starts with `[Adblock Plus 2.0]` and holds 80,608 lines; `EasyPrivacy.txt` holds 57,052 lines (both counted with `wc -l`). The manifest lists 46 known lists in 5 categories. Open must parse the same syntax (network rules with `$third-party`, `$script`, `$domain=` options, and `##` cosmetic rules) because users' enabled-list choices import by list ID.
- **AD-3 — The known-list catalog (46 lists).** From `manifest.json` (verbatim IDs and display names; full file in `.re/features-advanced/blocklist-manifest.json`):

| Category | Count | Lists (ID — display name) |
|---|---|---|
| generic | 3 | `EasyList` — EasyList; `AdGuardAds` — AdGuard - Ads; `uBlock` — uBlock Origin filters |
| cookies | 2 | `CookieMonster` — CookieMonster by Fanboy; `AdGuardCookies` — AdGuard – Cookie Notices |
| privacy | 5 | `EasyPrivacy` — EasyPrivacy; `AdGuardSpyware` — AdGuard Tracking Protection; `EasyListSocial` — EasyList - Social Widgets; `AdGuardSocial` — AdGuard – Social Widgets; `FanBoyThirdParty` — Fanboy – Anti-Facebook |
| regional | 35 | `pl`, `ua`, `al`, `bg`, `zn`, `cssk`, `de`, `ee`, `ar`, `espt`, `es`, `fi`, `fr`, `gr`, `hr`, `hu`, `ind`, `il`, `in`, `persian`, `cold`, `it`, `jp`, `kr`, `lt`, `lv`, `mk`, `ndk`, `nodkice`, `ro`, `se`, `slovenia`, `th`, `tr`, `vn` (display names in the manifest) |
| bcny | 1 | `BCNYBlocklists` — BCNY Blocklists (Arc's own additions) |

  Types: `KnownBlockList`, `BlockListCategory`, fields `id`, `display_name`, `type`, `info_url`, `urls`, `resource_name`. Only `EasyList` and `EasyPrivacy` carry `resource_name`, proving only those two ship inside the bundle; the rest download on first enable.
- **AD-4 — Update mechanism: remote manifest plus per-list files, ETag-cached.** Manifest URL: `https://dia-blocklists-release.diabrowser.engineering/manifest.json`; every list URL is under `https://dia-blocklists-release.diabrowser.engineering/…` (a mirror of the upstream sources). Strings: "Updating blocklists...", "Done updating blocklists, new content for", "Got 304 while updating blocklist with etag", "Skipping unknown blocklist during refresh:", "Was looking for bundled blocklist", "Contents of bundled blocklist". Rule: on a schedule (interval not in strings; EasyList header says "Expires: 4 days"), the client fetches the manifest, then each enabled list with its stored ETag; `304` keeps the cache. Unknown IDs in the remote manifest are skipped, not fatal. Open: same URLs are Arc's infrastructure; Open should fetch the upstream sources directly (the `info_url` and upstream paths are inside the mirrored URLs) and keep ETag caching. Do not depend on Arc's mirror.
- **AD-5 — Which engine applies the rules is not proven by strings.** Candidates checked: no `adblock-rust` or Brave adblock strings exist in either binary (the only "Brave" hits are `BraveSearchEngine` for search). `ArcCore-arm64` contains Chromium's `subresource_filter` (`SubresourceFilter`, `subresource-filter-internals`, `BlockedSubresource`), and the main binary calls `ADKClient.setBlockLists`. Guess: Arc parses the text lists itself (or in ArcCore) and compiles them into Chromium's subresource-filter ruleset plus cosmetic rules, rather than embedding Brave's Rust engine. Open, on CEF, should do the equivalent: parse ABP syntax, apply network rules in the resource handler, and inject cosmetic `##` rules as CSS at document start. The cosmetic question matters: ABP lists are mostly cosmetic for cookie/social widgets, so Open must support `##` and `#@#` (exception) rules; this is required by AD-2's list contents even though the binary does not name the mechanism.
- **AD-6 — Defaults.** Strings: `defaultEnabledBlockLists`, `enabledBlockLists`, `blockListsPerProfile`, `BlockListConfiguration`, `applyBlockListStates`, `toggleBlockList`. Observed on this machine: `defaults read` gives `nativeAdBlockEnabled = 0` — the native blocker is currently off for this user (they may use an extension instead). Factory default is therefore not proven by this machine. Guess: fresh installs enable the native blocker with EasyList + EasyPrivacy after the onboarding picker (`AdBlockersSelectionView`, `onboardingAdBlockerStarted/Finished`). Open questions below. Enabled lists are per Profile (`blockListsPerProfile`).
- **AD-7 — Per-site toggle.** From the Site Control Center (§6, SC-6): disabling shows a scope dialog (`AdBlockDisableScopeAction`), stores an exclusion (`setAdBlockExcludedDomains`, `autoDisableAdBlockOnAllowListedURLsCompleteProfileIDs`), and offers a reload (`AdBlockReloadFollowUpAction`, "Automatically disabled uBlock on YouTube for profile" proves an automatic allowlist behavior for at least uBlock on YouTube: `autoDisableUBlockOnAllowListedDomainsIfNecessary(in:)`, flag `auto-disable-u-block-on-allow-listed-domains-enabled`). Rule: excluded domains bypass native blocking; the panel toggle reflects the exclusion; changing it prompts or performs a reload. Open mirrors the exclusion list per Profile.
- **AD-8 — Management UI.** `ManageAdBlockersDialog` / `ManageAdBlockersSheetWindow`, `AdBlockerSelector`, `AdBlockerView`, `AdBlockersManagementReducer`, `AdBlockPreferences`, `AdBlockAdvancedSettingsDialog` ("Title for advanced AdBlock settings dialog"), banner `SidebarBannerManageAdBlockersView`, debug action "Copy AdBlock debug info" (`getAdBlockDebugInfo:completion:`, `onCopyAdBlockDebugInfo`). Rule: Settings offers the list picker by category with per-list toggles and info links (`info_url`), an advanced dialog, and a debug-info copy for support. The reset item (`resetAdBlockDialogMenuItem`, `onSelectResetAdBlockDialogMenuItem`) restores the picker state.

### 7.2 Settings (ad blocking)

| Key (verbatim) | Kind | Default | Evidence |
|---|---|---|---|
| `nativeAdBlockEnabled` / `native.adblocker.enabled` | master toggle | observed `0` on this machine; factory unknown | `defaults read` + strings |
| `enabledBlockLists`, `blockListsPerProfile` | per-Profile list ID sets | EasyList + EasyPrivacy (guess) | strings + bundled resources |
| `setAdBlockExcludedDomains` list | per-site exclusions | empty | strings |
| `hasCompletedMultipleAdBlockersSelection` | onboarding state | false | string |
| `autoDisableAdBlockOnAllowListedURLsCompleteProfileIDs` | auto-allowlist state | — | string |

Help article: `https://resources.arc.net/hc/en-us/articles/24789101226903-Block-ads-trackers-and-popups-with-Arc-s-built-in-ad-blocker`.

### 7.3 Evidence (ad blocking)

- Manifest: `.re/features-advanced/blocklist-manifest.json` (46 lists, `manifest_url` field).
- Bundled lists: `ARCClients_BlockListClient.bundle/Contents/Resources/EasyList.txt` (80,608 lines), `EasyPrivacy.txt` (57,052 lines).
- Strings: `.re/features-advanced/adblock-strings.txt`.
- Observed value: `defaults read company.thebrowser.Browser` → `nativeAdBlockEnabled = 0`.

### 7.4 Open questions (ad blocking)

1. Factory default: is the native blocker on for a fresh profile, and which lists are enabled by default (EasyList only, or EasyList + EasyPrivacy + a regional list by locale)?
2. Rule engine: confirm whether ArcCore compiles lists into `subresource_filter` rules or uses its own matcher; does it support `$removeparam`, scriptlets (`##+js(...)`), and extended CSS (`:has`, `:style`)?
3. Cosmetic filtering: are `##` rules applied before first paint? Are cookie-notice lists on by default?
4. Update interval and whether updates happen only on launch or also periodically in the background.
5. Disable-scope options and whether the exclusion is per page, per site, or per Profile.
6. Why uBlock is auto-disabled on YouTube (breakage mitigation?) and which domains are on that allowlist.

---

## 8. Picture in Picture and media controls

Module evidence: bundle `ARC_PictureInPicture.bundle` (`PictureInPicture/PIPWindowController.swift`, `DocumentPiPWindowController.swift`, `PIPWindowContent.swift`, `ObservablePlayback.swift`), bundle `ARC_MediaControlsFeature.bundle` (`MediaControlsFeature/MediaControlsFeature.swift`, `MediaControlsFeatureController.swift`, `MiniPlayerFeature.swift`, `MiniPlayerView.swift`); data store `MediaControlsDataStore` (`MediaControlsDataStore/MediaControlsData.swift`); integration `WindowData+MediaControls.swift`, `WindowsData+MediaControls.swift`, `WindowsData+PictureInPicture.swift`, `WebContentState+PictureInPicture.swift`, `WindowState+GoogleMeetAutoPiP.swift`; state `PictureInPictureState` (`Browser/PictureInPicture/PictureInPictureState.swift`). Strings in `.re/features-advanced/pip-media-strings.txt`.

Second pass (2026-10-25, media/PiP plan). New evidence sources, all local in `.re/media/`:

- `swift-fields.tsv`: every Swift type with its field or enum-case names, read from the `__swift5_fieldmd` section of `.re/bin/Arc-arm64` by our own parser (`.re/media/swift_fields.py`, `python3 -I swift_fields.py bin/Arc-arm64`). Rules below cite these as "fields of `Type`".
- `ghidra-media.txt`: read-only decompiles from the shared `ArcMain` Ghidra project (`AdrpDecomp.java`, `-readOnly -noanalysis`), one function per string anchor. Short Swift strings (15 bytes or fewer) are stored inline as 64-bit words; we decoded them (`.re/media/decode_all.py`). They are cited as "inline string".
- `assets-MediaControlsFeature.json`, `assets-PictureInPicture.json`: `xcrun assetutil --info` of the two bundles' `Assets.car`.
- `/Applications/Arc.app/Contents/Resources/ARC_WebContentBehaviorConfigurationClient.bundle/Contents/Resources/web_content_behavior.json` (keys `pipDisallowList`, `pipSiteConfigs`), read in place.
- No runtime capture shows a media player or a PiP window. `grep` of every `ax.json` in `.re/runtime/sessions/` finds only "Mute"/"Unmute" in a tab context menu (F0116) and page content. Layout values below are therefore code constants or guesses, never measurements.

### 8.1 Picture in Picture

- **PP-1 — Two PiP kinds: video PiP and Document PiP.** Types: `PictureInPictureAction`, `DocumentPictureInPictureAction`, `PictureInPictureSource`, `PictureInPictureContext`, `PictureInPictureContentState`, `PictureInPictureViewState`; controllers `PIPWindowController` (with `PIPWindowContent`, `PIPOverlayHostView`, `TopBarHostingView`, `AVPlaybackController`, `PIPPlaybackController`, `ObservablePlayer`) and `DocumentPiPWindowController` (with `DocumentPiPWindowContent`, `DocumentPiPTopBarView`). `PictureInPictureContentState` is `video(VideoPipState{sourceContentID, customPIPConfig})` or `document(DocumentPipState{sourceContentID, frameID, browserContextID})` (fields). Rule: video PiP floats one video element in Arc's own window; Document PiP hosts the page's `documentPictureInPicture` child page in Arc's own window with a top bar.
- **PP-2 — Request and exit go through the engine client.** `ADKClient.requestPictureInPicture`, `ADKClient.exitPictureInPicture`, callbacks `didRequestPictureInPicture`, `setupPictureInPictureObservers(with:adkClient:)`, error strings "adkClient.requestPictureInPicture has failed." and "adkClient.closePictureInPicture has failed." Rule: the shell asks the engine to start PiP for the active media element; failure is silent to the user (log only). State flags `isPictureInPictureActive`, `allowsPictureInPictureMediaPlayback`. ArcCore also has `skipUserActivationForPiP:` and `ignoreDisablePiPAttribute:` on `ArcWebContents` (docs/re/arccore-engine.md §2.6): shell requests do not need a user gesture.
- **PP-3 — Auto-PiP when the tab stops being visible.** Keys: `autoPictureInPictureOnWindowOccluded`, request type string "automatic picture-in-picture" / `autoPictureInPicture request type`, action `autoPipTurnedOffUntilReenabled(host:)` (case of `PictureInPictureAction`), `WindowContentPictureInPictureVisibilityUpdate{contentID, isVisible}`, `PictureInPictureVisibilityUpdateResult{didRequestPictureInPicture, effect}`. The decision input is `WebContent.PictureInPictureContext{isWebContentVisible, isWebContentFullscreen, isApplicationHidden, isMediaPlayerActive, isPictureInPictureActive}` (fields). Rule: when the web content that plays a video stops being visible (tab switch, Space switch), Arc requests PiP; when it becomes visible again, Arc exits PiP. `autoPictureInPictureOnWindowOccluded` sits in the cluster of engine/remote flags next to `useChromiumAutoPiP`, `macCoalescedResizing`, `chromiumDisabledFeatures` (`strings-main.txt:113617-113620`), and Chromium 156 has a feature of the same name, `media::kAutoPictureInPictureOnWindowOccluded`, disabled by default (`media/base/media_switches.cc:374`). Guess: window occlusion is a separate trigger behind that flag; its value in Arc's remote config is unknown.
- **PP-4 — Google Meet gets special auto-PiP.** Flags `google-meet-auto-picture-in-picture-enabled`, `google-meet-chromium-auto-picture-in-picture-enabled`, keys `useChromiumAutoPiP`, `useChromiumAutoPiPForGMeetOnly`, file `WindowState+GoogleMeetAutoPiP.swift`, `GoogleMeetPiPTransition{direction: open|close}`, `applyWindowContentPresentationChanges(isPerformingGoogleMeetPiP:changes:)`, string `googleMeetBackgroundPictureInPictureTriggered`, a script that clicks Meet's own PiP menu item (`strings-main.txt:111309-111311`), assets `meet-pip-chat-selected`/`-unselected` (24 pt). ArcCore exports `notifyAutoPipTabActivationChanged:error:` on `ArcWebContentsMediaSession` (`.re/arccore/objc-methods.txt`), which matches Chromium's `AutoPictureInPictureTabHelper::OnTabActivatedChanged(bool)` (`chrome/browser/picture_in_picture/auto_picture_in_picture_tab_helper.h:83`). Rule: Meet calls use Chromium's own auto-PiP path (Meet registers the `enterpictureinpicture` media session action and gets a Document PiP window); Arc's general video rule (PP-3) excludes Meet (PP-12).
- **PP-5 — Video PiP window controls.** View types and fields: `PIPOverlayView{player, windowState, onClose, onMinimize, onBackToTab, hoveringOnWindow, movedRecently, sustainedMovement, lastMoveToken, currentlyRenderedSize}`; `Controls{isVisible, …, onBackToTab, onClose, onMinimize, onPlayPauseTapped}` with view model `{showPlaybackControls, closeEnabled, minimizeEnabled, scrubEnabled, showMeetingControls, origin}`; `PlayControls` view model `{skipButtonEnabled, playPauseEnabled, showNextButton, showPreviousButton, isPlaying}`; `MeetingControls` view model `{showHangUpButton, showMicrophoneButton, showCameraButton, cameraOn, microphoneOn}`; buttons `CloseButton`, `BackToTabButton{title}`, `BackForwardButton{forward}` (previous/next track), `AnimatedSkipButton{forward}`, `PlayButton{playing}`, button styles `CornerButtonStyle`, `PIPPillActionButtonStyle{height, horizontalPadding, baseBackground, hoverBackground, pressedBackground}`, `GrowOnHover{scale}`, `VisualEffectView{blendingMode, material}`, environment key `PIPSizeClassKey`. Rule: controls appear while the pointer is over the window or moved recently, and hide otherwise; play/pause in the middle with skip buttons on both sides, previous/next track when the page offers them, a scrubber, a "Back to Tab" pill, and Close and Minimize corner buttons. Exact positions are not proven (no capture).
- **PP-6 — PiP control constants.** From the decompiles: Close and Minimize corner buttons are 28 pt, with 8 pt padding in the small size class and 10 pt in the large one (doubles 28.0, 8.0, 10.0 in the functions that use "Tooltip; closes the pip window" and "Tooltip; minimizes the pip window"; inline strings "Close", "Minimize"). Skip buttons move 15 s ("Skip back 15 seconds", "Skip ahead 15 seconds"); their images `GoBack`/`GoForward` are 54×54 pt vector canvases (`assets-PictureInPicture.json`). Tooltips on PiP and mini-player buttons use a 0.45 s delay (double 0.45 passed with every tooltip string; guess: the tooltip modifier's delay argument).
- **PP-7 — Precision scrubbing.** `BasicScrubber{player, scrubSpeed, barHeight, draggableHeight, onInteraction, width, dragState, hovered}`, `DragState{dragStartTime, dragStartLocation, relativeTranslation, totalTranslation, wasPlayingAtDragBegin}`, `ScrubSpeedLabel{multiple: Int?}`. Strings: "Drag upwards to seek precisely" (shown when the multiple is below 2) and the interpolation "Seeking at %lld× precision" (inline strings "Seeking at ", "× precision"). Rule: dragging the scrubber seeks; moving the pointer upward while dragging makes seeking finer, and a label states the factor. Playback pauses during the drag and resumes if it was playing (`wasPlayingAtDragBegin`).
- **PP-8 — PiP settings menu (fact, order from the decompile).** `PIPWindowController.pipMenu` is built by one function (`FUN_1024c5a00` in `.re/media/ghidra-media.txt`): (1) "Keep Window on Top" with a check mark for the current state, then a separator; (2) when the source URL has a host: a disabled header "Picture-in-picture on " + host + ":", then "Open automatically" (checked) and "Turn off" (its action captures the host), a separator, and "Copy URL"; (3) "Mute" or "Unmute" for the source tab. `toggleAlwaysOnTop()` and `updateWindowBehavior()` exist on both window controllers (`nm`). The Document PiP menu (`FUN_1024c1dac`) has "Keep Window on Top" and the same host header. Guess: "Turn off" adds the host to `autoPipDisabledForHosts`; "Open automatically" is the checked state of the same choice.
- **PP-9 — PiP session states.** `MediaControlsDataStore.PIPSessionState`: `pendingActive`, `active`, `pendingHidden`, `hidden`, `pendingRemoved`, `removed`, `userRequestedClose`, `userRequestedMinimize`, `userClosed`, `closeFailed`, `requestFailed`; `PIPSessionHistory{recentStates}`; `MediaControlsData.pipSessions` (fields). Rule: Arc tracks every PiP session through pending and final states, and records whether the user closed or minimized it. A minimized session hides the window and shows a "back to PiP" button in the sidebar mini player (PP-15).
- **PP-10 — Engine contract for the PiP window.** ArcCore's `ArcWebContentsMediaSessionPiPController` has `videoView` (an NSView) and `sourceElementBounds` (a CGRect) (`.re/arccore/objc-methods.txt`). The Swift side receives `WebContentPiPAction`: `didCreatePiPController`, `didChangePiPVideoResolution(CGSize)`, `didChangePiPPlaybackState`, `didChangePiPFeatureState`, `didChangePiPMediaPosition(ArcMediaPosition)`, `didDestroyPiPController`, `shouldShowPiP`, `shouldHidePiP`, `shouldClosePiP` (fields). `ADK.PiPFeature`: `cameraOn`, `hangupButtonVisible`, `microphoneMuted`, `nextTrackButtonVisible`, `playPauseButtonVisible`, `previousTrackButtonVisible`, `skipAdButtonVisible`, `toggleCamerButtonVisible` (sic), `toggleMicrophoneButtonVisible`, `nextSlideButtonVisible`, `previousSlideButtonVisible`; `ADK.PiPPlaybackState`: `playing`, `paused`, `endOfVideo`. These names match Chromium's `content::VideoOverlayWindow` setters one to one (`content/public/browser/overlay_window.h:43-72`). Rule: Arc replaces Chromium's PiP window with its own; the engine hands the video surface view and the window state to the shell.
- **PP-11 — Per-site PiP behavior (data file).** `web_content_behavior.json` `pipSiteConfigs` (type `PIPSiteConfig{urlRegex, customAttributes}`, attributes `PIPCustomAttribute`: `disablePlayButton`, `disableScrubButton`, `disableSkipButton`, `disableCloseButton`, `activatesWhenInaudible`): Twitch hides play, scrub, and skip; Meet hides close; YouTube auto-PiPs even when inaudible; Spotify and Netflix hide skip and scrub. `CustomPIPConfig{customAttributes, minimizeEnabled}`. Rule: auto-PiP normally needs audible video; a site config can relax that, and can remove controls for live or DRM content. Open ships its own copy of these facts in its own file format.
- **PP-12 — Auto-PiP disallow list.** `pipDisallowList` (`PipDisallowedURL{urlRegex}`): Slack, Google Meet, Microsoft Teams. Rule: Arc never auto-PiPs these sites through its general rule (calls are handled by PP-4 or not at all).
- **PP-13 — Auto-PiP preferences.** `ArcUserDefaultSettings` cases `autoPipDisabledForHosts` and `autoPipDisabledDeadlines`; app-state key `autoPipGloballyDisabled`; `AdvancedPreferencesViewState.autoPipGloballyDisabled` (fields); Settings accessibility id `enablePipPreference`; label "Enable Picture in Picture when you leave a video tab" (`strings-main.txt:130133`). `AutoPipStatus`: `disabled(…)`, `on`, `off`. The live profile's defaults have no `autoPipGloballyDisabled` key (runtime-observations §5.1 list), so the setting is at its default there: auto-PiP on. Guess: `autoPipDisabledDeadlines` holds a time limit per host (a temporary snooze); its duration was not found.

### 8.2 Media controls (sidebar mini players)

- **PP-14 — The sidebar media controls are a stack of mini players.** One `MediaControlsFeatureController` per window (errors "`MediaControlsFeatureController` instance already exists for window ID", "No `MediaControlsFeatureController` instance found for window ID"); input `MediaControlsFeatureControllerInput{windowID, windowIsIncognito, colorPalette, miniPlayerMarqueeTitleEnabled}`; `MediaControlsFeature.Action`: `miniPlayer(…)`, `receiveColorPalette`, `receiveMiniPlayerMarqueeTitleEnabled`, `delegate(toggleMuteStatusRequested | backToTabRequested | backToPIPRequested)`, `setUp`, `tearDown`; internal `receiveVisibleMediaControls`; log " active media control sources" (fields, strings). The view: `MediaControlsView{store, onUpdateHeight, convertToScreen, immediateOnHoverOffSubject, debouncedOnHoverOffSubject, stateChangeAnimation, isExpanded}` whose view state holds `miniPlayers: [MiniPlayerViewState{miniPlayer, height, opacity, yOffset, widthOffset}]`. Rule: each window shows its own visible media sources as mini players. Several players form a stack: back players are offset, narrower, and faded; hovering expands the stack (hover-off is debounced). The view reports its height to the AppKit container. "Mini Player" is the name of each card; there is no other media widget.
- **PP-15 — Mini player state and actions.** `MiniPlayerFeature.State{id, hostWindowID, source, title, icon{image, tintColor}, volume, isTabMuted, isBackToPIPButtonEnabled, tabURL, isVolumeExpanded, mediaType}`; `mediaType` is `audioVideo{mediaSessionStatus, hasNextTrack, hasPreviousTrack}` or `recording{canToggleMicrophone, canToggleCamera, isMicrophoneOn, isCameraOn}`. View actions: `setVolume(to:)`, `setIsPaused(to:)`, `backToPipClicked`, `toggleVolumeDrawer(to:)`, `backToTabClicked`, `titleRowClicked`, `controlsRowClicked`, `playNextTrack`, `playPreviousTrack`, `closeButtonClicked`, `toggleMuted`, `toggleCamera`, `toggleMicrophone`. The player observes only `title`, `icon`, `mediaSessionState`, `isTabMuted`, `tabURL` (`ObservationCancellationID.Target`). Rule: the title is the tab title and the image is the tab favicon (no artwork, no artist, no progress bar). Analytics `MediaControlType` adds `volumeDrawerOpened`/`volumeDrawerClosed` and `unmute`.
- **PP-16 — Mini player controls (fact, from the decompiles).** Title row: SF Symbol `pip` at 12 pt with tooltip "Open Picture in Picture" (the back-to-PiP button), SF Symbol `xmark` at 14 pt with tooltip "Close Mini Player"; the close button's frame is 24 pt wide only while hovered and 0 otherwise. Controls row (all 14 pt symbols): `mic.fill`/`mic.slash.fill` "Toggle Microphone", `video.fill`/`video.slash.fill` "Toggle Camera", `backward.end.fill` "Previous Track", `play.fill`/`pause.fill` "Play"/"Pause", `forward.end.fill` "Next Track", and a volume button "Adjust Tab Volume" whose drawer has `speaker.wave.1.fill` and `speaker.wave.3.fill` at its ends; 24 pt frames. Every tooltip uses the 0.45 s delay (PP-6). Glyph color asset `PlaybackControlForeground`: black 0.50 (light), white 0.66 (dark). `MiniPlayerView{colorPalette, colorScheme, store, isExpanded, usesMarqueeTextView, convertToScreen, stateChangeAnimation, backToTabTitle}`, `VolumeRowViewState{isVolumeRowShown, volume, isMuted, isVolumeExpanded}`, `ControlsSpacer{controlsAreGrouped}`, `AssetButton{systemName, symbolFontSize, action}`.
- **PP-17 — Marquee title.** `ARCUI.MarqueeText{text, leftMaskingDistance, rightMaskingDistance, cycleSpacing, scrollDelay, scrollSpeed}`; the mini player builds it with the numbers 4, 8, 32, 3.0, 1.0 (decompile of the "Close Mini Player" function). Guess: left fade 4 pt, right fade 8 pt, 32 pt gap between loops, 3 s pause before scrolling, speed factor 1.0 (unit unknown). Flag `mini-player-marquee-title-enabled` turns it on; off shows a static title.
- **PP-18 — Media state is shared across windows.** `MediaControlsData{maxActiveMediaControls: Int, activeMediaControls, idsBySourceContentID, pipSessions}`, `MediaControlData{id, type: MediaControlsType (recording | audioVideo), source}`, `MediaControlsDataStoreImpl`, `addMediaControl(_:)`, "Manager already has a media control source associated with this media content ID". Rule: sources register by content ID in one app-wide store; windows read their visible subset; closing the source removes it. The value of `maxActiveMediaControls` was not found.
- **PP-19 — Recording sources.** `MediaControlsType.recording`, flag `media-tray-for-recording-tabs-enabled`, tab cell fields `isRecording` and `hasLeadingRecordingIndicator`, tooltip "This tab is using your camera or microphone" (`strings-main.txt:111574-111575`). Rule: a tab that uses the camera or microphone gets a mini player with microphone and camera toggles, and its row shows a recording indicator.
- **PP-20 — Placement.** The sidebar view controller class (the parser could not resolve its name; it holds `sidebarHeader`, `pagingController`, `dockController`, `homeButtonView`, and `Arc.SidebarViewController.ViewState` carries `miniPlayerMarqueeTitleEnabled`) has an `NSStackView` (`$__lazy_storage_$_stackView`) and separate `mediaControlsContainer` and `sidebarBannerContainer` views next to `dockController` (the bottom bar) (fields). The measured bottom bar has no media button (runtime-observations §1.1: Home, Space switcher, plus). Guess: the mini players sit in their own container between the Space list and the bottom bar, and the container is zero height when no player shows.
- **PP-21 — No menu or shortcut for media or PiP.** `MainMenuAction` has no media or PiP case (`swift-fields.tsv`); the only media commands are command-bar actions `muteAllTabs` / `unmuteAllTabs` ("Action to mute all tabs", "Action to unmute all tabs") and the tab context menu's Mute/Unmute (`SidebarContextMenuItemAction.Tab.toggleMuted`). Media keys and macOS Now Playing come from the engine (PP-22).
- **PP-22 — macOS Now Playing and media keys are Chromium's.** ArcCore links `MediaPlayer.framework` and imports `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, `MPMediaItemArtwork` and the Now Playing property keys (`otool -L`, `nm -u .re/bin/ArcCore-arm64`); its strings include `components/system_media_controls/mac/now_playing_info_center_delegate.mm`, `NowPlayingInfoCenterDelegateCocoa`, `RemoteCommandCenterDelegate`, `MediaKeysListenerManager`, `kHardwareMediaKeyHandling` (`.re/media/arccore-strings.txt`). The Swift app imports no MediaPlayer symbol (`nm -u .re/bin/Arc-arm64`). Rule: Arc shows the active page's media session in Control Center and answers the keyboard media keys through Chromium's stock system media controls (`kHardwareMediaKeyHandling` is on by default on macOS: `media/base/media_switches.cc:659-661`); Arc adds nothing of its own (guess, from the missing imports).

### 8.3 Settings (PiP and media)

| Key (verbatim) | Kind | Default | Evidence |
|---|---|---|---|
| `autoPipGloballyDisabled` | app state (inverse of the Advanced toggle) | `false` (auto-PiP on) | field of `AdvancedPreferencesViewState`; absent from the live defaults |
| `autoPipDisabledForHosts` | user default, host list | empty | `ArcUserDefaultSettings` case |
| `autoPipDisabledDeadlines` | user default, per-host deadline | empty | `ArcUserDefaultSettings` case; duration unknown |
| `autoPictureInPictureOnWindowOccluded` | engine/remote flag | unknown | `strings-main.txt:113617-113620` |
| `useChromiumAutoPiP`, `useChromiumAutoPiPForGMeetOnly` | engine/remote flags | unknown (guess: Meet only) | same cluster |
| `google-meet-auto-picture-in-picture-enabled` | feature flag | on | string |
| `google-meet-chromium-auto-picture-in-picture-enabled` | feature flag | on | string |
| `media-tray-for-recording-tabs-enabled` | feature flag | on (guess) | string |
| `mini-player-marquee-title-enabled` | feature flag | on (guess) | string |

The only user-facing setting is Advanced "Enable Picture in Picture when you leave a video tab". The per-host choice lives in the PiP window's menu (PP-8). "Keep Window on Top" is a window toggle; whether it persists is unknown.

### 8.4 Evidence (PiP and media)

- Strings: `.re/features-advanced/pip-media-strings.txt`, `.re/features-advanced/strings-main.txt` (line numbers above).
- Types and fields: `.re/media/swift-fields.tsv` (parser `.re/media/swift_fields.py`).
- Decompiles: `.re/media/ghidra-media.txt` (functions `FUN_10249b63c` mini player title row, `FUN_10249c5c4` controls row, `FUN_10249e37c` play/pause tooltip, `FUN_1024c5a00` PiP menu, `FUN_1024c1dac` Document PiP menu, `FUN_1024d1170` corner buttons, `FUN_1024dfdcc`/`FUN_1024d2c70` skip and scrubber labels).
- Assets: `.re/media/assets-MediaControlsFeature.json`, `.re/media/assets-PictureInPicture.json`.
- Files: `Browser/PictureInPicture/PictureInPictureState.swift`, `Frameworks/ARC/Sources/MediaControlsFeature/MediaControlsFeature.swift`, `MiniPlayerFeature.swift`.

### 8.5 Open questions (PiP and media)

1. Does a window minimize, window occlusion, or app switch open auto-PiP in the shipping config (PP-3 flag value)?
2. Mini player placement and stack look (PP-20 guess): where exactly, card size, how many players (`maxActiveMediaControls`), and how the stack expands.
3. Does the selected (visible) tab ever get a mini player? Guess: no (`receiveVisibleMediaControls`, `isWebContentVisible`).
4. What does closing a mini player or an auto-PiP window do to playback (pause or keep playing), and how long does the per-host deadline last?
5. Document PiP window chrome: top bar height and contents; the colors are known (`design-tokens.md` §1.8).
6. Does a manual PiP stay open when its tab becomes visible again?

---

## 9. Other small features

### 9.1 Capture (screenshot tool)

Module: bundle `ARC_Capture.bundle`; client `CaptureClient` (`Frameworks/ARCClients/Sources/CaptureClient/CaptureClient.swift`, `CaptureClientImp.swift`); UI `Capture/ContentCaptureView.swift`, `ContentCaptureViewController.swift`, `CapturedImageView.swift`, `CapturedImageActionsView.swift`; store glue `WindowState+Capture.swift`; persisted file `StorableCaptures.json` (from `StorableCaptureItems`). Strings in `.re/features-advanced/misc-strings.txt`.

- **CA-1 — Three capture kinds.** Labels: "Capture" ("Capture a portion of this page"), "Capture Full Page" ("Capture the full page"), "Capture in Portrait Mode". Types: `CaptureType`, `CaptureMode`, `CaptureBackground`, `CaptureInitiationType`, `CaptureActionType`, `FullPageCaptureDelay`. Rule: area capture drags a rectangle over the page; full-page capture stitches the whole scroll height (with a delay for lazy content, `FullPageCaptureDelay`); portrait capture frames a portrait crop of the page. Entry points: the Site Control Center footer (§6, SC-5), the page context menu ("Title for the 'Capture' context menu action.", "Title for the 'Capture Full Page' context menu action."), and a keyboard shortcut (`captureShortcut`, `captureShortcutLastSeen`, "Hold Command and Shift to start a Capture.", "Letting the member know about the capture shortcut.", `dragToCaptureDisabled`). The exact default shortcut is owned by the hotkeys report.
- **CA-2 — After capture: preview with actions.** Types: `CapturedImageView`, `CapturedImageActionsView`, `CaptureImageMenuView`, `CaptureMenuRowView`, `CaptureMenuExpandableSection`, strings "Save Capture Image", "Default filename for saving a Capture image from the web", `saveCaptureToLibrary`, "Saved to Library", watermark key `ArcCaptureWatermark` with `portraitCaptureHidesWatermark`, `portraitCaptureColorPercentage`, `portraitCaptureBackground`. Rule: the captured image shows with actions to save to a file, copy (`CapturePasteboardWriter` / `CapturePasteboardReader`), add to the Library (Captures collection), and (Arc-only) add to an Easel — Open omits the Easel action. Portrait captures can hide the watermark and tint the background. Sound: capturing plays the capture sound (§9.7).
- **CA-3 — Storage.** `CaptureClient.storeCapture`, `getImage`, `getImageCachePath`, `deleteCapture`, `clearCaptureStore`, `subscription`; on-disk `~/Library/Application Support/Arc/Captures` directory exists (listed read-only) plus the `StorableCaptures.json` index and `capturePrettyScreenshot`. Library integration: "Menu item title to view all Screenshots & Captures.", "Menu item title to hide all Screenshots & Captures", `LibraryCapture`. Rule: captures persist in the Library's Captures collection until deleted ("Alert message description: this will permanently delete your capture", "Capture client failed to remove item.").
- **CA-4 — Hover capture on web content.** `WebContentState+HoveredCapture.swift`, `CaptureProvider`, `ContentCaptureOverlayBubble` prove a hover affordance on images/media offers capture of that element. Guess: hovering an image shows a capture handle. Verify at runtime; Open may defer this sub-behavior.

### 9.2 Translation

Module: bundle `ARC_Translation.bundle`; feature `Translation/TranslateFeature.swift` (`TranslateFeature`, `TranslateState`, `TranslateBubbleView`, `TranslateBubblePopoverView.swift`); window glue `WindowData+Translate.swift` (`SharedWindowTranslateFeature`); engine calls `ADKClient._translate`, `ADKClient._revertTranslation`.

- **TR-1 — The engine translates; the shell offers and reports.** Strings: "Translation Available", "Translate this page to %@?", "Prompt string for a translate offer", "Prompt string for a translated page", "Translated from %@.", "Translated to %@", "Translated back to %@", toasts for complete/error/reverted ("Toast message when page translation is complete", "Toast message when a translation error has occurred", "Toast message when page translation was reverted"), error type `TranslateError` / `chromiumTranslateError`. Rule: when the engine detects a page language different from the user's, a bubble offers translation to the default target language; accepting calls the engine translate; the bubble then offers revert and options.
- **TR-2 — Controls.** "Translation Options", "Translation button", `contentToolbarTranslateButton`, "Button to request translation", "Button to revert translation to original language", "Button to select among translation options", "Heading for submenu allowing the user to request translation to a language other than the browser's default", "Menu item requesting that translation never be applied to this site", "Never Translate This Site". Rule: the toolbar translation button opens the bubble; options include translate to another language and never translate this site.
- **TR-3 — Per-site and per-language memory.** `UserDefaultsClient.setTranslateDisabledForHost`, `translateDisabledForHost`, `isTranslateDisabledForHost`, `UserDefaultsClient.resetTranslateSettings`, "Button Label; Clicking resets any user preference to automatically or never translate specific languages or sites.", "Reset Translated-site Prompts". Detection callback: `webContents:didDetermineSourceLanguage:isTranslateEnabled:targetLanguage:isTranslationPending:`. Flag `translate-enabled`. Rule: "never translate" is remembered per host; Settings can reset all such choices. Open stores the same per-host disabled set.

### 9.3 Copy link, open in other Space, and link affordances

- **LK-1 — Copy link to page / highlight.** Types: `CopyLinkViewModel`, `CopyLinkContentView`, `CopyQuoteLinkContentView`, actions `didTapCopyLink`, `onCopyLinkToHighlight`, strings "Copy link button", "Copy link as Markdown", "Copy link faster by pressing" (truncated; shortcut owned by hotkeys report), "Copy All Links as Markdown", "Copy item link as Markdown". Rule: the share/copy actions copy the page URL, optionally as Markdown `[title](url)`, and for a text selection copy a link to the highlight (scroll-to-text fragment). Open implements URL copy, Markdown copy, and highlight link.
- **LK-2 — Open link in other Space.** The Little Arc move menu (§3, LA-6) and tab context menus route an existing page to another Space; `onOpenModalContentInCurrentSpaceSelected` proves modal content can be claimed into the current Space. Guess: a tab's context menu offers "Open in" / move-to-Space for every other Space. The exact menu label needs runtime data; Open provides move-to-Space on tab and link context menus regardless of the label.

### 9.4 Tidy Tabs (non-AI renaming)

Module: `TidyTabTitlesClient` (`TidyTabTitles`, `TidyTabTitle`, `TidyTitleConfiguration`, `BundledTidyTitles`), glue `WindowData+TidyTabTitles.swift`; downloads sibling `DownloadNamingFeature` (auto-rename downloads).

- **TT-1 — Tidy renames unpinned tabs (and downloads) to short, clean titles.** Strings: "Button Title; Tidy unpinned tabs in this space" on `Arc.SidebarTidyButton` / `SidebarTidyButton` / `TidyTabsButtonImageView`, preview `TidyTabsPreview`, feedback `tidyTabTitlesFeedback`, "Auto-Renamed Tabs and Downloads:", download strings "Download renamed to:", "Letting user know that their download has been automatically renamed by Tidy Downloads." Rule: invoking Tidy in a Space proposes shortened titles for its unpinned tabs; the preview shows before/after and the user confirms. Downloads get the same treatment automatically (rename suggestion with revert: "Download name reverted!", "Download renamed!").
- **TT-2 — It is not Arc Max.** The title cleanup uses bundled rules (`BundledTidyTitles`) and the prompt-like rules visible in strings for title rewriting; whether any step calls an AI model is not proven. Key `tidyTabsEnabled` gates it; observed on this machine: `tidyTabsEnabled = 0` (off for this user). Toggle handler `onToggleTidyTabsEnabled`, state `isTidyTabsEnabled`. Open: implement rule-based tidying (strip site suffixes, tracking cruft, and redundant prefixes per the bundled-rules idea, our own rules) behind the same toggle, default off until runtime data shows the fresh-install default.

### 9.5 Downloads UI

Module: `DownloadsPageReducer` (`HomeButton/DownloadsPageReducer.swift`, `Downloads/DownloadsPageReducer.swift`), `SharedDownloadsFeature`, `DownloadManager` (`ADKClient/DownloadManager.swift`), `DownloadsUI` (`DownloadToLibraryViewModel`, `DownloadToLibraryWindowController`), Little Arc tray (§3, LA-10).

- **DL-1 — Downloads live in the Library/Home downloads page and in trays.** Strings: "Downloads in progress", "Filter Downloads", "Download list filter - profiles section", "Opens the Downloads section of your Library.", empty states ("Downloads Home page empty state title."), item UI (`DownloadCell`, `DownloadItemView`, `DownloadProgressBarBackground`, `DownloadProgressBadge`, `DownloadLocationView`). Rule: every download shows name, source domain ("Download from [source domain]"), progress, and location; the list filters by Profile. Little Arc shows the same downloads in its tray.
- **DL-2 — Rename on download (Tidy Downloads).** `DownloadNamingFeature`, `PersistedDownloadNamingFeatureState`, `DownloadRenamePreview`, `DownloadRenamedToastContentView`, toast strings in TT-1. Rule: a finished download may be auto-renamed to a cleaner name with a toast offering revert.
- **DL-3 — Save to Library.** `DownloadToLibrary` flow (`downloadToLibraryWindowController`) offers to keep the file in the Library's Downloads collection (§9.6). Rule: "Save to Library" copies or registers the file so it appears in the Library even if the original moves.

### 9.6 Library

Module: `LibraryDataClient` (`LibraryData/LibraryDataClient.swift`), `DocumentsLibraryClient`, `EaselLibraryClient` (Easel out of scope), Home store `StorableHome.json`.

- **LB-1 — The Library is one collection view over several sources.** Strings: "Opens your Library, which is like your Camera Roll within Arc. Screenshots, Captures, Downloads, and more can appear here.", "Quickly grab screenshots, images, and videos from your computer by showing them in the Arc Library!", "Allow Arc to show your Documents, Desktop, and Download Folders to see them here alongside your Captures.", "Save media to your Documents, Desktop, and Download Folders to see them here, alongside your Captures in Arc." On-disk `StorableHome.json` proves the source toggles: `preferences.dataSourcePreferences = [documents, true, screenshot, true, desktop, true, download, true, capture, true]` with `permissions.folderToPermissions` for the folders. Rule: the Library shows Captures, Screenshots, Downloads, and the user's Documents/Desktop/Downloads folders (with permission), filterable by source ("Library Downloads Page Filter Title", "Library Arhives Page Filter Title" [spelling as in binary], archive filters by Space, close type, and Little Arc). Types: `LibraryDataItem`, `LibraryCategory`, `LibrarySource`, `LibraryDataQuery` / `LibraryDataQueryBuilder`. Open: same five sources, same filter dimensions, local-only.
- **LB-2 — Library actions.** `LibraryDataClient.deleteItem`, `hideItem` (with explicit non-support errors: "LibraryDataClient does not support hiding captures." and siblings for documents/easels/files, and "LibraryDataClient does not support deleting files."). Rule: Arc-captured items can be deleted; filesystem-backed items can only be hidden (and some kinds cannot even be hidden). Open mirrors the delete-versus-hide split.

### 9.7 Sound effects

Module: bundle `ARC_SoundEffects.bundle` containing exactly two audio files (listed with `ls`): `capture.wav` (178 KB, RIFF PCM 24-bit stereo 48 kHz, per `file`) and `event.m4a` (140 KB, AAC/ALAC in M4A). Client: `SoundEffects/SoundEffectClient.swift` (`SoundEffectClient`, `SoundEffectClientImplementation`, `Sounds.swift`, `soundsByFilename`, `sound(forEffect:)`), API `play`, `preload`, `isEnabled`, `setIsEnabled`.

- **SE-1 — One toggle: "Play Arc sound effects".** Label verbatim from strings. Rule: a single Settings toggle enables or disables all UI sounds (`SoundEffectClient.setIsEnabled` / `isEnabled`). Default unknown (open question).
- **SE-2 — Two sounds ship; their event mapping is not named in strings.** Files `capture.wav` and `event.m4a` with `SoundEffect` enum and `Unable to load sound effect` error. Guess: `capture.wav` plays on Capture (§9.1) and `event.m4a` is the generic event sound (tab or window events). Open must record its own two sounds (never copy Arc's files) and map them: capture sound on capture; event sound on the events found at runtime. Which events play sounds is a runtime question.

### 9.8 Arc Menu

Module: bundle `ARC_ArcMenu.bundle`; types `ArcMenu`, `ArcMenuWindow`, `ArcMenuConfiguration`, `ArcMenuItem`, `ArcMenuItemType`, `ArcMenuItemView`, `ArcMenuSeparator`, `ArcMenuTextView`, `ArcMenuToggleAccessoryView`, `ArcMenuBackgroundView`, `ArcMenuContentViewController`, `ArcMenuFeature`, delegate `ArcMenuDelegate`, `ArcMenuWindowBehaviorCustomizing`; strings `WindowArcMenuType`, `ArcMenuExtensionButtonSource`, `BrowserAppDidSelectArcMenuItem`.

- **AM-1 — ArcMenu is Arc's custom menu component, not the system menu bar.** It renders its own window (`ArcMenuWindow`) with items, separators, text items, and toggle accessories. It backs the app's custom popups (app menu, extension menus per `ArcMenuExtensionButtonSource`, and other `WindowArcMenuType` variants). Rule for Open: this is an implementation detail, not a user feature; Open may use system menus except where the design-tokens report requires the custom look. No behavior spec beyond "menus built with ArcMenu look and behave as one component" is needed.

### 9.9 Sidebar plus button menu

Module: bundle `ARC_SidebarPlusButton.bundle`; types `SidebarPlusButton`, `SidebarPlusButtonState`, `SidebarPlusButtonMenuItemType`, `SidebarPlusButtonAction`, `SidebarPlusButtonDelegateAction`, `SidebarPlusButtonConstants`, `SidebarPlusButtonGradientBackgroundViewView`.

- **SP-1 — The plus button at the bottom of the sidebar opens a creation menu.** Items are enumerated by `SidebarPlusButtonMenuItemType`. Proven members from strings elsewhere: new tab, new Split View ("You can now create a new Split from the plus button at the bottom of the Sidebar."), and (guess) new folder, new Space-adjacent actions, and new Boost/Easel/Note entries in Arc (Easel and Note out of scope in Open). Rule: Open's plus menu offers New Tab, New Split View, and New Folder at minimum, in Arc's order (order needs runtime data).

### 9.10 Sad Tab page

Module: bundle `ARC_SadTab.bundle`; types `SadTab`, `SadTabView`, `SadTabHostView`, `SadTabAction`, state `WebContentSadTabState`.

- **ST-1 — A crashed or failed web content shows the Sad Tab page.** The host view replaces the dead web content with Arc's error page and offers its actions (`SadTabAction`; string "Action to retake capture." is Capture, not Sad Tab). Guess: actions are Reload and Close, following Chromium's sad-tab model. Open: same replacement behavior with its own page; exact copy and buttons need a runtime screenshot.

### 9.11 URL inputter (command-bar URL field)

Module: bundle `ARC_URLInputter.bundle`; types `URLInputter`, `URLInputterView`, `URLInputterFeature`, `URLInputterSubmitButton`, `URLInputterSearchOutput`; files `URLInputter/FaviconProvider.swift`, `URLInputter/URLInputSearchClient.swift`, `URLInputter/URLInputterReducer.swift`.

- **UI-1 — The URL field is a search-and-navigate input with favicon and submit affordances.** It resolves typed text to a URL or a search (`URLInputterSearchOutput`), shows the site's favicon (`FaviconProvider`), and submits on Enter. It is the same field used in the command bar and in Little Arc (colors shared with `LittleBrowserCommandBarPlaceholderBackground`). Rule: Open's command-bar field matches this behavior; ranking and suggestion sources are owned by the core-features report.

### 9.12 TopDomains and popularDomains.json

Module: bundle `ARC_TopDomains.bundle` with `TopDomains.json` and `TLD-short-list.json`; app-level `Resources/popularDomains.json`. Types: `TopDomains`, `TopDomain`, `TopDomainItem`, `TopDomainInfo`, `TopDomainKeys`, `TopDomainsCandidatesProvider`.

- **TD-1 — `TopDomains.json` maps domains to display site names.** Format: a JSON array of `{ "domain": "google.com", "siteName": "Google" }` objects (first entries inspected: google.com, blogger.com, youtube.com, linkedin.com, wordpress.org, …). Rule: when Arc shows a site by name (tabs, suggestions, Site Control Center headers), it prefers this curated name over the raw host.
- **TD-2 — `popularDomains.json` is a ranked list of popular hosts.** Format: a JSON array of host strings in popularity order (`facebook.com`, `twitter.com`, `youtube.com`, `google.com`, `instagram.com`, …; 54 KB, copied to `.re/features-advanced/popularDomains.json`). Combined with `TopDomainsCandidatesProvider`, it feeds address-bar completion: typed prefixes complete to popular domains before history. Rule: Open bundles an equivalent list (its own curation; the file is data, not code, but Open should generate its list rather than ship Arc's file verbatim — the domains themselves are facts).
- **TD-3 — `TLD-short-list.json` is the list of known top-level domains.** Format: a JSON array of TLD strings (`.aaa`, `.aarp`, `.abarth`, …). Rule: the URL inputter uses it to decide whether typed text is a host (contains a known TLD) or a search query. Open uses the public suffix list for the same decision.

### 9.13 Settings summary (small features)

| Feature | Key / label (verbatim) | Default | Evidence |
|---|---|---|---|
| Capture | `captureShortcut` (+ `dragToCaptureDisabled`, `portraitCaptureHidesWatermark`) | shortcut set (value in hotkeys report) | strings |
| Translation | `translate-enabled`, per-host `translateDisabledForHost` | on; no disabled hosts | strings |
| Tidy Tabs | `tidyTabsEnabled` | observed `0` on this machine | `defaults read` |
| Sound | "Play Arc sound effects" (`SoundEffectClient.setIsEnabled`) | unknown | strings |
| Library | `StorableHome.json` `dataSourcePreferences` | all five sources on | on-disk schema |

### 9.14 Evidence (small features)

- Strings: `.re/features-advanced/misc-strings.txt`.
- Bundles and files: `ARC_Capture.bundle`, `ARC_Translation.bundle`, `ARC_SoundEffects.bundle` (file list and `file` output), `ARC_ArcMenu.bundle`, `ARC_SidebarPlusButton.bundle`, `ARC_SadTab.bundle`, `ARC_URLInputter.bundle`, `ARC_TopDomains.bundle` (`TopDomains.json`, `TLD-short-list.json`), `Resources/popularDomains.json`.
- On-disk: `StorableHome.json` preferences quoted in LB-1.

### 9.15 Open questions (small features)

1. Capture: default shortcut; portrait aspect ratio; whether area capture can span the full window or only the web content.
2. Sound: which events play `event.m4a`; factory default of the toggle; volume.
3. Sad Tab: exact text and actions.
4. Plus menu: full item list and order.
5. Tidy: bundled-rule examples (before/after title pairs) and whether any step uses an on-device or cloud model.
6. Downloads: whether "Save to Library" copies or references the file; retention.

---

## 10. AppleScript

Source: `/Applications/Arc.app/Contents/Resources/Arc.sdef` (copied to `.re/features-advanced/Arc.sdef.xml`), declared by `Info.plist` keys `OSAScriptingDefinition = Arc.sdef` and `NSAppleScriptEnabled = true` (via `plutil -p`). The file defines one suite, the Standard Suite (`core`). Open implements the same terms with its own code so Raycast and user scripts keep working.

### 10.1 Classes

| Class (code) | Plural / Cocoa class | Elements | Properties (name — code — type — access — meaning) |
|---|---|---|---|
| `application` (`capp`) | `NSApplication` | `window` (ordered front to back); `tab` — write-only: "allows you to create new Little Arc tabs" (`appleScriptTabs`) | `name` — `pnam` — text — r; `frontmost` — `pisf` — boolean — r ("Is this the frontmost (active) application?"); `version` — `vers` — text — r. Responds to `quit`. |
| `window` (`WiND`) | `AppleScriptWindowWrapper` | `tab` (rw, `appleScriptTabs`); `space` (`appleScriptSpaces`) | `id` — `ID  ` — text — r ("The unique identifier of the window."); `name` — `pnam` — text — r ("The full title of the window."); `index` — `pidx` — integer — rw ("ordered front to back"); `closeable` — `hclb` — boolean — r; `minimizable` — `ismn` — boolean — r; `minimized` — `pmnd` — boolean — rw; `resizable` — `prsz` — boolean — r; `visible` — `pvis` — boolean — rw; `zoomable` — `iszm` — boolean — r; `zoomed` — `pzum` — boolean — rw; `active tab` — `acTa` — tab — r ("Returns the currently selected tab"); `active space` — `acSp` — space — r ("Returns the currently active space"); `incognito` — `inco` — boolean — rw ("Whether the window is an incognito window."); `mode` — `mode` — text — rw ("can be 'normal' or 'incognito', can be set only once during creation of the window."). Responds to `close`. |
| `tab` (`tAbB`) | `AppleScriptTabWrapper` | — | `id` — `ID  ` — text — r; `title` — `pnam` — text — r ("The full title of the tab."); `URL` — `URL ` — text — rw ("The url of the tab."); `loading` — `ldng` — boolean — r ("Is loading?"); `location` — `loca` — text — rw ("Represents the location of the tab in the sidebar. Can be 'topApp', 'pinned', or 'unpinned'."). Responds to `select`, `go back`, `go forward`, `reload`, `stop`, `execute`, `close`. |
| `space` (`sPaC`) | `AppleScriptSpaceWrapper` | `tab` (rw, `appleScriptTabs`) | `id` — `ID  ` — text — r; `title` — `pnam` — text — r ("The full title of the space."). Responds to `focus`. |

Notes on semantics Open must match:

- `tab.location` uses the exact strings `topApp` (favorites), `pinned`, and `unpinned` (today tabs). Setting `location` moves the tab between sidebar sections.
- A `window` created with `mode = "incognito"` cannot later change mode ("can be set only once during creation").
- Creating a `tab` on the `application` (not on a window or space) creates a Little Arc tab. This is the scriptable Little Arc entry point (§3, LA-5).
- `window.active tab` and `window.active space` are read-only conveniences; there is no "make tab active" property — use the `select` command.

### 10.2 Commands

| Command (code) | Direct parameter | Other parameters | Result | Notes |
|---|---|---|---|---|
| `make` (`corecrel`) | — | `new` (`kocl`, type, required: "The class of the new object."); `with properties` (`prdt`, record, optional) | specifier ("to the new object") | Standard `NSCreateCommand`. Used to create windows and tabs (including Little Arc tabs per §10.1). |
| `count` (`corecnte`) | specifier ("the object whose elements are to be counted") | `each` (`kocl`, type, optional) | integer ("the number of elements") | Standard `NSCountCommand`. |
| `close` (`coreclos`) | specifier ("The object to execute the command on.") | — | — | Implemented by `window` and `tab` (`close:`). |
| `select` (`CrSelect`) | tab ("The tab to execute the command in.") | — | — | Makes the tab the window's active tab. |
| `go back` (`CrSuBack`) | tab | — | — | "Go Back (If Possible)." No-op if there is no back entry (behavior inferred from the description). |
| `go forward` (`CrSuFwd `) | tab | — | — | "Go Forward (If Possible)." Note the trailing space in the code `CrSuFwd ` — Open must use the same four-character code including the space. |
| `reload` (`CrSuRlod`) | tab | — | — | Reloads the tab. |
| `stop` (`CrSustop`) | tab | — | — | "Stop the current tab from loading." Cocoa selector `stopLoading:`. |
| `execute` (`CrSuExJa`) | tab | `javascript` (`JvSc`, text: "The javascript code to execute.") | text | Runs JavaScript in the tab and returns its result as text. Selector `executeJavascript:`. |
| `focus` (`SpaFocus`) | space ("The space to focus.") | — | — | Brings the space forward in its window. Selector `focus:`. |
| `quit` (responded to by `application`) | — | — | — | Declared via `responds-to` with `handleQuitScriptCommand:`; no separate `command` element in the file. |

### 10.3 Rules for Open

- **AS-1 — Ship the same dictionary.** Same suite name and code (`Standard Suite`, `core`), same class names, codes, property names, codes, and command codes — including quirks: the trailing space in `CrSuFwd `, the space-padded `ID  ` and `URL ` codes, and the `WiND` / `tAbB` / `sPaC` class codes. Scripts address terms by code, so any deviation breaks them.
- **AS-2 — Match access modes.** Read-only stays read-only (`id`, `title`, `loading`, `active tab`, `active space`); `URL`, `location`, `minimized`, `visible`, `zoomed`, `index` stay writable. The `application`'s `tab` element stays write-only in behavior (create Little Arc tabs) even though the sdef marks the element with `access="w"`.
- **AS-3 — Match the object graph.** `application` → `window` → (`tab`, `space`); `space` → `tab`. Tab IDs and space IDs are stable strings (UUIDs in Arc's stores; Open uses its own UUIDs with the same stability guarantee).
- **AS-4 — Implementation is ours.** Cocoa bridge classes in Arc are named `AppleScriptWindowWrapper`, `AppleScriptTabWrapper`, `AppleScriptSpaceWrapper` (from the sdef `cocoa class` attributes). Open writes its own wrappers; only the scripting surface must match.

### 10.4 Evidence and open questions (AppleScript)

- Evidence: `Arc.sdef` quoted and summarized above; `plutil -p Contents/Info.plist` for `OSAScriptingDefinition` and `NSAppleScriptEnabled`.
- Open questions: (1) Does `execute` return the JS completion value stringified, and what happens on a JS error? (2) Does `make` support creating `space` objects, or only windows and tabs? (The sdef does not restrict `new` by class.) (3) What does setting `tab.location` to each value do to ordering within the section? All three need a script run against Arc by the user (forbidden for agents to launch Arc).

---

## Appendix A. Evidence index (raw files in `.re/features-advanced/`)

| File | Contents |
|---|---|
| `strings-main.txt` | `strings -a .re/bin/Arc-arm64` (270,339 lines) |
| `split-strings.txt`, `peek-strings.txt`, `little-strings.txt`, `boost-strings.txt`, `zap-strings.txt`, `sitec-strings.txt`, `adblock-strings.txt`, `pip-media-strings.txt`, `misc-strings.txt` | Per-feature filtered, sorted string sets |
| `blocklist-manifest.json` | `ARCClients_BlockListClient.bundle` manifest (46 lists) |
| `SelectorPicker.js` | BoostsEditor Zap selector-picker script (Arc's file, kept only in `.re/` as evidence; Open reimplements the behavior) |
| `Arc.sdef.xml` | `Resources/Arc.sdef` (evidence copy; §10 is our summary) |
| `popularDomains.json` | `Resources/popularDomains.json` (evidence copy) |
| `localizable-en.txt`, `assets.txt`, `assetutil-little.txt`, `nm-sample.txt`, `mainmenu.json` | Supporting dumps, including the failed `rea` attempts |

## Appendix B. Cross-report dependencies

- Keyboard shortcuts for Split View, Capture, and Little Arc are owned by the hotkeys report; this spec names the actions and flags.
- Sidebar item and window persistence shapes (`StorableSidebar.json`, `StorableWindows.json`) are owned by the data-model report; this spec quotes only the Split View and link-routing fields.
- Engine mapping (CEF user scripts, subresource filtering, PiP) is owned by the ArcCore engine report; this spec states the required behavior at the shell boundary.

