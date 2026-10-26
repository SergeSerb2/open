# Sidebar completion: RE findings (Arc 1.170.0)

Date: 2026-10-25. Target: Arc 1.170.0 (89123), arm64 slice `.re/bin/Arc-arm64`.
Scope: the sidebar gaps in `docs/status.md` §3 (gaps 6, 7, 10, 11, 17–21, 31–34, 36).
The plan that uses these facts is `docs/plans/sidebar-completion.md`.

This file is our own summary. Raw output stays in `.re/sidebar-completion/` (git-ignored):
`strings-topics.txt` (topic greps of `.re/features-core/strings-all.txt`), `ghidra1.txt` and
`ghidra1.log` (one batched read-only Ghidra run), and the `toast_measure*.py` / `decode*.py` scripts.
No Arc asset, sound, JSON file, or decompiled code is copied here. Space names, tab titles, and URLs
from the captures are not reproduced.

## 0. Method and evidence notation

| Tool | Use |
|---|---|
| `strings -a` dump (`.re/features-core/strings-all.txt`, cited `strings:N`) | Localized values, comments, type and key names |
| Shared Ghidra project `ArcMain`, `-readOnly -noanalysis`, one batch run of our script `AdrpBatch.java` with 25 needles (`~/Library/Caches/OpenRE/ghidra-scripts-sidebar/`) | Finds the functions that load a localized comment string, then decompiles them. Swift strings of 15 bytes or less are stored inline as two 64-bit constants; `decode3.py` turns them back into text. Cited as `FUN_<address>`. |
| Swift reflection field list (`.re/media/swift-fields.tsv`) | Type fields and enum cases (`Type{field, …}`) |
| `python3 -I` over `ARC_WebContentBehaviorConfigurationClient.bundle/.../web_content_behavior.json` | Key names and counts only. No values were printed or copied. |
| Captures (frames from `.re/runtime/sessions/20261024-213009-*`, index in `interaction-states.md` §1) | Pixels converted to sRGB with the embedded display profile (`analysis-20261024/lib.py`) |

Marks: **fact** (string, symbol, field, or pixel proves it), **derived** (follows from facts), **guess** (verify before you rely on it).

## 1. Delete confirmations

| Item | Value | Evidence |
|---|---|---|
| Delete Space alert title | "Delete your " + Space name + " Space?" | fact: `strings:132842–132844` ("Delete your ", " Space?", comment "Alert title; Confirmation alert that the user wants to delete the space") |
| Delete Space alert text | "This will archive all the tabs and folders inside it." | fact: `strings:132845` with comment `strings:132846` "Alert informative text; Text explaining that deleting the space will close all contained tabs." |
| Delete Space buttons | "Delete", "Cancel" | fact: inline strings in `FUN_102a8aab8` (loads the comment "Alert button; Delete the space and close all tabs within it.") |
| Delete folder alert title | "Delete your " + folder title + " folder?"; fallback "Are you sure?" when the title is missing | fact: `strings:132819–132820`; inline "Are you sure?" in `FUN_102a75b50`, used only on the branch where the title string is empty |
| Delete folder alert text | "Deleting this folder will archive the tabs inside it." | fact: `strings:132815` + comment `strings:132816` |
| Delete folder buttons | "Delete Folder", "Cancel" | fact: inline strings in `FUN_102a75b50` |
| Folder deleted toast | "Folder deleted" / "Folders deleted" | fact: inline strings in `FUN_102a76ff0` (comments "Confirmation toast when a sidebar far [sic] was been deleted", "…multiple sidebar folders are deleted") |
| Live Folder variant | "Delete your %@ Live Folder?" | fact: `strings:132823`. Out of scope (Live Folders). |
| Alert style | System `NSAlert` | guess: the strings are plain alert title / informative / button triples; no custom alert view type was found |

## 2. Space Manager and Space reorder

| Item | Value | Evidence |
|---|---|---|
| Entry | Spaces ▸ "Manage Spaces…" (`toggleSpaceManager:`); Space context menu "Manage Spaces…" | fact: nib selector; F0117 menu |
| Description | "Opens the Space Manager, where you can rearrange your Spaces, folders, tabs, and more." | fact: `strings:130423` |
| Host | A page of the Library ("Home") window, not the sidebar | derived (strong): analytics enum `LibraryCategory` = all, screenshots, downloads, desktop, documents, links, notesAndEasels, **spaceManager**, archive, boosts; `SpaceDisplayContext` = sidebar, **spaceManager** (the same Space display is used in both places); window layout pages `sidebarPage`, `home`, `spaces` next to `updateLayoutPresentation` (`strings:245320–245340`); Library hover Lottie `spaces.json` (`design-tokens.md` §4.1) |
| Per-Space header | `SpaceControlsView` with `State{spaceID, canDelete, title}`, `Action{didTapTurnIntoFolder, didTapDelete}`, fields `grabberView`, `moreMenu`, `stack`, `iconContainerDimension` | fact: reflection fields |
| Grabber | Tooltip "Drag to Reorder Space"; open-hand cursor | fact: `strings:111260`; `FUN_1001d728c` sets `NSCursor.openHandCursor` |
| More button | Tooltip "More options"; menu with Turn into Folder and Delete | fact: inline "More options" in `FUN_1001d6924`; actions above |
| Profile indicator | `spaceManagerSpaceHeaderIndicator` (profile chip in each Space header) | fact: `strings:118705` and analytics `ProfileAssignedToSpaceEntrypoint` |
| Drag to reorder in the bottom switcher | Flag `win-enable-drag-to-reorder-spaces` | fact: `strings:123683`. The `win-` prefix marks Arc for Windows flags (guess), so the macOS build likely reorders only in the Space Manager. |
| Layout of the page | Not captured | guess: one column per Space, side by side |

## 3. Multi-select

| Item | Value | Evidence |
|---|---|---|
| State | `isMultiSelected` on the tab cell state; `multiSelectedItems`; actions `setMultiSelection`, `removeMultiSelection`; selector `performMultiSelection:`; `deselectedItemsState` | fact: `strings:216058–217736`, `245660`, `245757`, `259596`, `92542` |
| Cell state | `{isHighlighted, isCurrentItem, isContentVisible, isKeyDraggedItem, isMultiSelected, isEditing, shouldDim, canResetTab, resetTabTitle, resetTabIcon, …}` | fact: reflection fields |
| Fill token | `TabCellBackgroundMutiselected` [sic]: light `#000000` a 0.10, dark `#FAFBFF` a 0.10 | fact: asset catalog (`design-tokens.md` §1.3) |
| Actions on a selection | `toggleSelectedItemsPinned:` (Cmd+D), `createFolderFromSelection`, `createFolderFromSelectionInCurrentSpace`, `createSpaceFromSelection`, `archiveUnselectedItems` | fact: `strings:245375–245483`, nib selector |
| Menu titles | "New Folder with " + N + " Items" (`FUN_102ecbdf4`); "Archive Item" / "Archive Items" (`FUN_102eca8c8`, mixed selection, and the tab menu builder `FUN_102ed0784`); "Pin Tab" / "Pin Tabs" / "Unpin Tab(s)" (`FUN_100314424`); "Copy links as Markdown" and "Copy item links as Markdown" (`strings:134695–134696`); "Duplicates selected tabs." (`strings:130470`); "New Folder from Selection" (`strings:111687`) | fact |
| Mixed selection (folders included) | Menu "Default Context Menu" / "Title for a mixed selection" holds "Delete" and "Archive Item(s)"; folders are deleted, not archived ("Delete sidebar items (e.g. Folders, since we don't archive them.)") | fact: `strings:134668–134669`, `134698–134699`, `FUN_102eca8c8` |
| Modifier keys | Shift+Click selects | fact (weak): `menus-and-hotkeys.md` "Gestures and mouse". Cmd+Click toggle and Shift+Arrow extend are guesses (standard macOS list rules). |

## 4. Clear unselected, Archive Other Tabs

| Item | Value | Evidence |
|---|---|---|
| Today "Clear" tooltips | "Clear Today tabs" (comment "Tooltip; Clear unpinned tabs in this space") and "Clear unselected Today tabs" (comment "Tooltip; Clear unselected tabs in this list") | fact: `strings:110993–110996` in `UnpinnedSectionHeaderCellView` |
| Tab menu alternates | "Archive Other Tabs" ("Deletes all unselected unpinned tabs from the sidebar."), "Archive Tabs Below", "Archive Tabs Above" | fact: `strings:134708–134713`; built after "Archive Item(s)" in `FUN_102ed0784` and `FUN_102eccc9c` |
| How the variant is reached | Not proven | guess: the Option key (macOS alternate items). The captured tab menus (F0115, F0116) do not show the three items. |
| Toast after a clear | "Cleared Tabs" | fact: inline in `FUN_102a68e2c` (comment "Title for toast that confirms tabs were cleared") |

## 5. Pinned tab reset and Separate From Pinned Tab

| Item | Value | Evidence |
|---|---|---|
| Strings | "Back to Pinned URL" (comment "String that describes the action of going back to a website"), "Separate From Pinned Tab" | fact: `strings:111559–111561`, both in `TabCellState.swift` |
| Cell fields | `canResetTab`, `resetTabTitle`, `resetTabIcon` | fact: reflection fields. derived: the row swaps in a reset icon with a title (tooltip) when the tab can be reset. |
| Semantics of Separate | Not proven | guess (`features-core.md` §3.2 r7): the navigated page becomes its own Today tab and the pinned tab goes back to its pinned URL |

## 6. Folders: expand/collapse all, archive, turn into Space

| Item | Value | Evidence |
|---|---|---|
| Expand / Collapse All | Tabs menu `expandAllFolders:` / `collapseAllFolders:`; "Expand all folders in your current space." / "Collapse all folders in your current space."; command bar aliases "Open Folders", "Show Folders" | fact: nib; `strings:130468–130469`; inline in `FUN_101d9cc80` |
| Archive a folder | Feature flag `enable-folder-archive`; folder menu builder `listContextMenu(listItemIDs:canArchiveFolders:)` shows "Delete" when `canArchiveFolders` is false, else "Archive Folder" / "Archive Folders" in the same slot | fact: `strings:123656`, `134665`; branch in `FUN_102eb3774` |
| Folder archive button | Tooltip "Archive" (comment "Tooltip for the button to archive a folder.") | fact: `FUN_10020eee0`; where the button sits is not proven |
| Restore toast | "Folder restored to " + Space + ". Click to view." and a plain variant; tabs: "Tab restored to " + Space | fact: `strings:125844–125849`, `125959` |
| Captured state | F0119 / F0134 show "Delete" | fact: the flag was off for this user |
| Turn folder into Space | Menu "Turn “" + title + "” into Space" with curly quotes | fact: inline `Turn “` and `” into` in `FUN_102eb4d38`; F0119 |
| Turn Space into folder | Space menu "Export “" + Space + "” into Folder ▸" (one item per Space; the current Space is disabled) | fact: `strings:134754` ("Export ", " into Folder", comment "Menu Item title to turn a space into a folder, argument is space name."); F0117 shows curly quotes |
| Model names | `turnSpaceIntoFolder`, `undoTurnSpaceIntoFolder`, `TurnSpaceIntoFolderOptions`, `spaceIntoFolder`, `didTapTurnIntoFolder` | fact |
| Undo names in the same undo builder | "Turn into Folder", "Move Item", "Move Items", "New Folder", "Delete Space", "New Space" | fact: `strings:132453`; inline strings in `FUN_10289083c` |

## 7. Hover Previews

| Item | Value | Evidence |
|---|---|---|
| Copy | "Save a click! Hover your mouse over an Arc Folder, Pinned, or Favorited tab to quickly preview what you need from that site!" | fact: `strings:130269` (`PreferencesFeature/PreviewSettingsDialog.swift`, header "Show Arc Previews:") |
| Sources (settings) | `folderPreviewEnabled`, `gmailPreviewEnabled`, `calendarPreviewEnabled`, `outlookEmailPreviewEnabled`, `outlookCalendarPreviewEnabled`, `notionCalendarPreviewEnabled`, `recentPagesPreviewEnabled` ("Recent pages on Linear, Notion, and Figma") | fact: `ArcUserDefaultSettings` cases; `strings:130271` |
| Tracker | `SidebarPreviewHoverTracker{lastMouseLocation, lastHovered, lastCommittedHover, extendedPresentationItemIDs, trackingArea, menuTrackingToken, showPreviewTask, viewWithHoverableItems, isEnabled}` | fact: reflection. derived: a delayed show task; no preview while a menu tracks; after one committed preview, nearby items can present at once (guess from `extendedPresentationItemIDs`). |
| Views | `PreviewView{backgroundView: PreviewBackgroundView, folderPreviewHostView, dataProvider, previewPresenter, previewContent: NSView}`, `FolderPreviewView{contentViewHeight, selectedItemID, searchQuery, previewPresenter}`, `StandardPreviewViewHost` | fact: reflection |
| Color | `PreviewBackgroundColor`: light `#FFFFFF`, dark `#212222` (main `Assets.car`) | fact: `.re/design/all-colors.txt` |
| Look, size, delay | Not captured | guess |

Note: Arc's pinned and favorite previews are site-specific glance views (mail, calendar, recent pages). Peek (`features-advanced.md` §2) is a different feature.

## 8. Tidy titles (schema only)

`web_content_behavior.json` has the top-level keys `keepaliveAllowList`, `pipDisallowList`, `pipSiteConfigs`, `tidyTitles`, `tabSuspensionBlocklist` (fact). `tidyTitles` is a map from a host (52 hosts, all dotted names) to `{siteName: String, rules: [{match, title}]}` (fact). Match kinds and counts: `pathEquals` 37, `pathContainsRegex` 31, `fragmentEquals` 10, `fragmentContainsRegex` 1. Title kinds: `always` 55 (a fixed title), `removingPattern` 41 (one regex removed from the page title), `removingPatterns` 8 (several regexes). Every host has at least one rule. Module types: `TidyTitleConfiguration`, `BundledTidyTitles` (fact, `strings:86328`, `86350`). The values were not read. Open writes its own table (AGENTS.md rule 1).

## 9. Unread badge

| Item | Value | Evidence |
|---|---|---|
| View | `SidebarItemUnreadBadgeView{dotLayer: CALayer, topImageView, bottomImageView, unreadBadgeType}` | fact: reflection. derived: the badge is a dot layer. |
| Type | `UnreadBadgeType` (cases not recovered) | fact: `strings:92410` |
| Triggers | `showNewItemsAsUnread` (Live Folders), toasts "New Tab Created in %@" and "Tab moved! Click to go there." | fact: `strings:131769`; `features-core.md` §1.2 r12 |
| Look and position | Not captured | guess |

## 10. Banners, hints, haptics, sounds, gesture

| Item | Value | Evidence |
|---|---|---|
| Auto-archive banner module | `SidebarBanner` (`SidebarBanner.State{content, presentationState, isHovered, …}`, action `autoArchiveEducation`) | fact: reflection, `strings:131950` |
| Banner copy | Title "We cleaned up!"; message "Arc archives tabs that you haven't used in the past 12 hours. You can adjust this in Settings." ("Settings" is a link, `autoArchiveBannerMessageLink://settings`); button "Got it" | fact: inline strings in `FUN_102551740`; `strings:131959–131965`. "12 hours" is literal in the string. |
| Banner keys | `eligibleToSeeAutoArchiveEducationBanner` (user default); analytics `auto_archive_education_displayed_when_tabs_auto_archive`, `auto_archive_education_dismissed` | fact. derived: the banner shows when auto-archive actually archives tabs. |
| First-hide hint copy | "You can use " + [⌘S keycap] + " to easily show and hide your Sidebar!" | fact: `strings:125806–125808` (second half and comments); the first half is inline and was read from capture A0440 |
| Hint key | `hasHiddenSidebarWithGesture` (user default) | fact |
| Hint frame (A0440, window 2216 wide, sidebar hidden) | Toast x 1812 … 2210, y 4 … 50 → `[W − 404, 4, 399, 47]` (right inset 5, top inset 4–5). Continuous corner ≈ 10 (row insets 7, 5, 4, 3, 2, 1, 0 from the top). 1 px darker rim (`#2A1B40`). Soft shadow below and left, ≈ 8 % darkening at the edge, gone after ≈ 9 pt. | measured: `toast_measure*.py`, diff of A0440 against A0447 (toast gone) |
| Hint fill | Vertical gradient, top `#442B68` (y 6) → bottom `#332350` (y 47), in the untitled default dark Space | measured |
| Hint text | SF Pro 14 Medium (NCC 0.965 / 0.964 for both halves), white `#F1F0F3`. "You can use" ink starts 12 pt from the left edge; the last ink ends 14 pt from the right edge. Lowercase ink rows 25–32 → baseline at toast y + 28. | measured: `fontmatch.py` |
| Hint keycap | Plate `[x + 98, y + 10, 37, 27]` relative to the toast, radius ≈ 6, white ≈ 0.10 over the fill; "⌘S" ink 19 pt wide, centered; 8 pt gap after "You can use", 6 pt before "to easily…" | measured |
| Hint lifetime | Present A0438–A0446 (21:33:45–21:33:50), gone at A0447 | measured: ≈ 5–6 s |
| Haptics | `tabReorderingHapticsDisabled` (default false → haptics on), `hapticFeedbackWhenReordering`, `isDragDropHapticFeedbackEnabled`, `dropHapticSubject`, `performsPageDetentHaptics`, `NSHapticFeedbackPerformer` | fact. derived: a haptic plays on drop and on page detents (Space paging). The feedback pattern is not proven. |
| Sounds | `SoundEffectClient{play, preload, isEnabled, setIsEnabled}`, `Sounds.swift`, two files (`capture`, `event`); user default `playUserInterfaceSoundsDisabled` | fact. derived: the polarity ("disabled") means sounds are on by default. Which events play `event` is not proven. |
| Gesture hide | `hideSidebarWithGesture`, `setIsPreviewingGestureHiddenSidebar`, `isPreviewingGestureHiddenSidebar`, next to `updateSidebarWidth` and `sidebarResizeGestureDidComplete`; recognizers `handleSidebarResizePanGestureRecognizer:` | fact. derived: the gesture is the sidebar resize pan. Dragging below the minimum previews the hidden sidebar (A0422 shows the sidebar sliding out) and release hides it. guess: no separate trackpad swipe exists (no string names one). |

## 11. Open questions for a capture session

See `docs/plans/sidebar-completion.md` §9 for the exact steps. In short: multi-select look and its menus; Space Manager page; both delete alerts; hover previews on a folder, a pinned tab, and a favorite; the unread dot; the "Back to Pinned URL" affordance and the key that turns it into "Separate From Pinned Tab"; the Clear control with Option held; the gesture hide at slow speed; the auto-archive banner (only if it can still be triggered).
