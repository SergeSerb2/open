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
| Settings sheet (runtime) | General ▸ "Previews Settings…" (the row has no switch) opens a 422 x 370 sheet: "Show Arc Previews:", the copy above with a "Learn more" link, and 7 checkboxes, all on by default: Arc Folders · Google Calendar · Google Mail · Outlook Calendar · Outlook Mail · Recent pages on Linear, Notion, and Figma · Notion Calendar; then "Done". | measured: capture session 2, S2 02/0050 AX (`interaction-states.md` §20.13) |
| Look, size, delay | Item 8's 5 s synthetic hover did not open it. The session-2 video caught the folder card once (positions only): ≈ 240 pt wide, 4 pt right of the sidebar, centered on the row, a "Search \<folder\>…" field, rows ≈ 45 pt with "N minutes ago", hover-to-card ≈ 0.42 s. Colors, radius, and type not captured. | measured once: V 45.69, 46.11–46.46 s (`interaction-states.md` §20.4); notes 10:23:34 |

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
| Hint trigger (session 2) | No hint on any path: the toolbar button, Cmd+S, and View ▸ Hide Sidebar, each held 7 s. Consistent with a once-per-install hint that already showed in session 1. | measured: S2 04/0001–0094; notes 10:11:20. guess: `hasHiddenSidebarWithGesture` was already set (not read; reading it would need `defaults`, skipped) |
| Haptics | `tabReorderingHapticsDisabled` (default false → haptics on), `hapticFeedbackWhenReordering`, `isDragDropHapticFeedbackEnabled`, `dropHapticSubject`, `performsPageDetentHaptics`, `NSHapticFeedbackPerformer` | fact. derived: a haptic plays on drop and on page detents (Space paging). The feedback pattern is not proven. |
| Sounds | `SoundEffectClient{play, preload, isEnabled, setIsEnabled}`, `Sounds.swift`, two files (`capture`, `event`); user default `playUserInterfaceSoundsDisabled` | fact. derived: the polarity ("disabled") means sounds are on by default. Which events play `event` is not proven. |
| Gesture hide | `hideSidebarWithGesture`, `setIsPreviewingGestureHiddenSidebar`, `isPreviewingGestureHiddenSidebar`, next to `updateSidebarWidth` and `sidebarResizeGestureDidComplete`; recognizers `handleSidebarResizePanGestureRecognizer:` | fact. derived: the gesture is the sidebar resize pan. Dragging below the minimum previews the hidden sidebar (A0422 shows the sidebar sliding out) and release hides it. guess: no separate trackpad swipe exists (no string names one). |

## 11. Open questions for a capture session

See `docs/plans/sidebar-completion.md` §9 for the exact steps. In short: multi-select look and its menus; Space Manager page; both delete alerts; hover previews on a folder, a pinned tab, and a favorite; the unread dot; the "Back to Pinned URL" affordance and the key that turns it into "Separate From Pinned Tab"; the Clear control with Option held; the gesture hide at slow speed; the auto-archive banner (only if it can still be triggered).

## 12. Capture session 2 results (2026-10-26)

Measured in `interaction-states.md` §20 (frames in `.re/runtime/sessions/20261026-*`, notation there):

| Topic | Result | Evidence |
|---|---|---|
| Minimum width and drag-to-hide | The resize drag stops at 164 pt. Dragging further left slides the sidebar out while the button is still down; release keeps it hidden. Cmd+S then restores the width from before the drag (228), not 164. | S2 06/0029, 0035, 0066 |
| Maximum width | 500 pt. | S2 06/0072 |
| Double-click on the resize edge | Resets the width to 228 (from 364 and from 500). | S2 06/0009, 0088 |
| Compact toolbar | At 207 pt and below: Back, Forward, and "More options" (28 x 28), no toggle and no Reload. | S2 06/0025–0029 |
| "Archive Tabs Above" and "Archive Other Tabs" (Q16, C8) | They are the ⌥ alternates of "Archive Tabs Below" and "Archive Tab" in the Today tab menu (AX: each pair shares one frame). | S2 07/0242, 0255 |
| Folder placement | "New Folder" on the Space menu puts the folder above the Today divider. | S2 08/0100 |
| Collapsed folder with a child | A collapsed folder can show one child (the last active one); its glyph then shows "•••". On disk: `expandedItems` `{peeked: {_0: [childID]}}`. A click collapses it fully, the next click expands it. | S2 08/0090, 0100; V 46.49–55.04 s |
| Folder row hover | White 0.10 fill and a "—" glyph at the right (no AX element). | S2 08/0090 |
| Favorites empty state | Dashed card "Drag to add Favorites" with a dismiss button. | S2 07/0001 (§20.3) |
| Auto-archive banner (C6, Q12) | Not captured: the Profile's "Archive tabs after" offers 12 hours, 24 hours, 7 days, and 30 days only, so it could not trigger within the session. | S2 02/0034; notes 10:07:27 |
| Previews (C4, Q3) | The 7-source sheet above. The folder card was seen once in the video (positions only, `interaction-states.md` §20.4); its colors were not captured. | S2 02/0050 |


## 13. Numbered shortcuts and recent-tab switcher (2026-10-28)

Target: Arc 1.170.0 (89123), verified with `plutil` on the installed Info.plist.
`dwarfdump --uuid` matches the installed arm64 slice and shared analysis input:
`BE2EB88A-675C-357B-8143-840A9196E154`. This investigation did not launch Arc or read personal
browser state. Raw output is in the local `.re/tab-switcher/` folder. The saved
`ArcMain` project was queried with `-process Arc-arm64 -noanalysis -readOnly`.
`tools/rea-env.sh` names an old Ghidra installation; these queries used installed
Ghidra 12.2 and JDK 25. The snapshot's missing Swift compiler spec falls back to
the default spec; Swift argument names and some register data flow are uncertain.
No re-import or analysis ran.

| ID | Finding | Evidence | Confidence |
|---|---|---|---|
| TS-R1 | Numbered navigation can start with Favorites or after Favorites. The stored Arc preference is inverted. | `strings -a /Applications/Arc.app/Contents/MacOS/Arc`: `excludeFavoritesInSwitchToNthTab`, `Include Favorites in ordering.`, description prefixes `starting with your Favorites at the top.` / `after your Favorites at the top.`; shared `ArcMain` `0x1005a4098` registers the preference key. | Fact. Arc's default remains unknown. |
| TS-R2 | Item nine has two meanings: ninth item or the last sidebar item. | Same string dump: `switchToNinthSidebarItemEnabled`, `Switch to ninth tab.`, `Jumps to the ninth item`, `Jumps to the last item at the bottom of your Sidebar.`; `menus-and-hotkeys.md`, code-only shortcut table. | Fact for semantics; the literal default Cmd+9 binding was previously marked a static-analysis guess. Open uses the requested Cmd+9. |
| TS-R3 | Ctrl+Tab / Ctrl+Shift+Tab are recent-tab commands, distinct from sidebar-order navigation. | `menus-and-hotkeys.md`, Tabs nib rows (`cycleToNextRecentTab:` / `cycleToPreviousRecentTab:`). Binary strings describe forward/backward recent tabs like Command+Tab. `0x10295ba78` builds and sorts candidate IDs using comparator `0x10295ebb4` → `0x10295bf18`; the comparator reads activity-date maps with a stored-date fallback and uses `Swift.Comparable.>` on `Foundation.Date`. | Fact: descending dates, not sidebar order. Exact tie order is not decoded. |
| TS-R4 | The normal recent-items path has a visual overlay with a focused item and horizontal cards. | Binary types `ModalItemSwitcherView`, `ItemView`, `ModalItemSwitcherWindowController`; fields `focusedItemID`, `snapshot`, `components`, `layoutOrientation`, `horizontal`, `icon`, `snapshotStyle`, `_scrollViewWidth`, `_itemRects`. `0x102994b24` constructs items and localizes `Recent Items` with comment `Title for the recent tabs overlay`. | Fact for overlay, title and supported horizontal layout. Exact card layout remains a guess. |
| TS-R5 | Presentation waits until 0.1 s after the request. A quick switch need not show the overlay. | `0x1024b69e8` subtracts elapsed request time from `0.1`, then shows via `0x1024b6c24` or schedules a non-repeating timer for the remainder. `0x1024b788c` invalidates that timer on completion/cancel paths. | Fact. |
| TS-R6 | The switcher watches key-down and modifier changes. Releasing the initiating modifier completes; cancellation sends no selected item. | `0x1024b7520` installs local-event mask `0x1400` (keyDown + flagsChanged); `0x1024b788c` handles event types 10/12, compares shortcut modifiers, invalidates the presentation timer, and sends its completion action. The same handler has a separate nil-item cancellation path. | Derived: Ctrl-release commit and Escape cancel. The two key-constant getters need a runtime capture to confirm their exact mapping. |
| TS-R7 | A separate linear-switcher mode exists in this binary. | Strings `linear-tab-switcher-enabled`, `linearTabSwitcherEnabled`, `LinearTabSwitcherState`, `LinearTabSwitcherSpaceState`; shared `ArcMain` getters `0x1013d9028` / `0x1013daa30` reference the feature-flag key. | Fact: feature flag. No public user setting, label, default, or enabled state was established. |
| TS-R8 | The recent switcher is described as five recent tabs. | Arc Help Center's indexed article, [How Do You Switch Between Tabs Quickly on Arc Desktop?](https://resources.arc.net/hc/en-us/articles/25619402657303-How-Do-You-Switch-Between-Tabs-Quickly-on-Arc-Desktop), says five most recently visited tabs. The direct page returned 404 during this investigation; this is supplementary historical help text. Binary presentation state also has `includesCurrentTab` and `maxNumberOfItemsToDisplay`. | Historical primary-source evidence for five; not a fresh runtime observation. |

Query receipts: `strings -a` and `nm -a` on the installed executable;
`otool -ov ~/Library/Caches/OpenRE/bin/Arc-arm64`; shared-project scripts
`AdrpBatch.java` (strings), `DecompAt.java` (addresses above), and
`SwitchTrace.java` (callers of `0x102994b24` and the existing modal-window functions).
Their output files are `arc-strings.txt`, `arc-nm.txt`, `objc.txt`, `decomp.txt`,
`candidates.txt`, `controller.txt`, `events.txt`, and the corresponding logs,
all under `.re/tab-switcher/`.

### Open implementation and limits

Open defaults to including Favorites, with Cmd+9 selecting the last tab. The
existing `Switch to ninth tab.` preference restores the ninth-item meaning.
Both keys and the native Tabs menu use the same candidate list. These defaults
are Open choices, not recovered Arc defaults. Next/Previous Tab and Cycle Tab
keep their existing sidebar order.

The recent switcher freezes the five most recent candidates for one held-Control
session, with the current tab first. Open includes Favorites and Pinned tabs,
including collapsed-folder children and split panes, across Spaces in the current
Profile. **Guess:** those exact candidate boundaries match Arc. The snapshot
filters item types and an identity pair (`0x102995fd4`), but this investigation did
not decode that pair far enough to prove cross-Space and cross-Profile scope.
Open keeps the Profile boundary explicit and restores the destination Space on
commit. From an empty Space, forward cycling starts with the most recent
candidate instead of skipping it. No highlighting changes selection, activity
timestamps, or page focus.

The 100 ms delay is anchored to the request with a monotonic deadline. The
offscreen harness waits for visible readiness before its rendering assertions;
a fixed 130 ms sleep raced queued main-actor work in the composed suite. This
readiness wait is not a performance gate or a change to the 100 ms app delay.

The App uses its existing `OEApplication.sendEvent` → `MainMenu` →
`BrowserWindowController.handleKeyDown` → `KeyboardRouter` command path. Modifier
release and Escape go through AppKit's local event path. A single AppKit drawing
view renders at most five cards. Only already-existing hosts can supply preview
images, after the presentation delay; no preview loads a tab. Ending a session
cancels pending work and releases the drawing view, images and callbacks. Hidden
state has no repeating timer or polling job.

**Visual guesses:** centered placement; 180 × 140 pt cards; 8 pt gaps; 16 pt
insets/corner; 28 pt title area; 13/12/11 pt type; `Core.popoverBackground`,
`Core.foregroundPrimary`, `Core.foregroundSecondary` and `Core.baseQuaternary`.
The image/label split and thumbnail crop are guesses too. No switcher AX record
or frame was found in the runtime session text/AX search, and sessions 1/2 do not
list it. Thus no ≤1 pt / ΔE00 ≤2 Arc comparison is claimed. Render receipts use
`features-render switcher --out FILE --size 1280x800 --scale 1|2`. Capture TS-C1 in
`docs/followups.md` must calibrate this surface; S2 input PNGs must first be
converted from AW2726DM ICC to Display P3 for color measurement.


### Local verification receipts (2026-10-28)

All checks ran in foreground jobs. Build commands held a heavy slot; the two
on-screen suites each held the machine on-screen lock, after builds finished.
The branch starts at local A3 `e6454aba`. No PR, merge acceptance, or Arc pixel
parity is claimed by these receipts.

| Command | Final result |
|---|---|
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only features-render,sidebar-render,commands-demo` | PASS: warning-free release build; commands-demo 232/232, sidebar-render 564/564, features-render 296/296 (TS1–TS10). |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | PASS: Debug Open.app, recorded fork distribution; no Chromium tree build. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --style chrome --only sidebar-completion` | PASS: 121/121 suite rows, including 16 TS rows. Engine fingerprint and owned-process cleanup also PASS. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --style chrome --only app-actions` | PASS: 47/47 action rows, plus engine fingerprint and cleanup (49 checks total). |
| `Packages/OpenKit/.build/release/features-render switcher --out .re/tab-switcher/switcher-1x.png --size 1280x800 --scale 1` | PASS: inspected 1280 × 800 render. |
| Same renderer with `--out .re/tab-switcher/switcher-2x.png --scale 2` | PASS: 2560 × 1600 render. No matching Arc frame exists for comparison. |

Each final on-screen suite first had one **INTERRUPTED** attempt due to lost
foreground (`library_section_click_fills_cache` and `command_return_background`).
The existing runner's subsequent complete attempts passed. Interrupted attempts
are retained separately in the JSON receipts, not counted as passes.

The first build found an omitted explicit Package.swift source entry. Initial
TS1–TS6 failures found a missing harness command-validation hook; TS3 then exposed
the fixed-sleep readiness race described above. These intermediate failures are
retained in `.re/tab-switcher/`; the final pass does not relabel them.

Final logs: `.re/tab-switcher/verify-final-head.log`,
`app-build-final-head.log`, `e2e-sidebar-completion-final.log`,
`e2e-app-actions-final.log`. JSON receipts:
`sidebar-completion-results-final.json`, `app-actions-results-final.json`.
The real overlay snapshot is `real-switcher.png`; the two offscreen renders are
`switcher-1x.png` and `switcher-2x.png`. All these local artifacts are git-ignored.
Generated `docs/engine-spike` result/debug files were restored before commit.
