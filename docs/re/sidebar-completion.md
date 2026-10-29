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

The recent switcher freezes the five most recent candidates for one held shortcut
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

### Integration with main #127–#130 (2026-10-28, afternoon)

The integration merge starts from `69ab7471` and takes main at `013cdb45`.
It retains A2's shared preview-host ownership handoff, A3's reviewed handlers,
#129's fidelity changes, and #130's auto-archive scheduler and selection policy.
The `features-render` target has one definition, retains `OpenSettings`, and runs
both `TabSwitcherChecks` and `AutoArchiveChecks`. The sidebar-completion suite
runs the A3, TS, and archive helpers once each, keeping the relaunched App returned
by the archive helper. Python definitions and outer automation command cases were
audited for duplicates; `archive-list` uses main's single archive implementation.

Ctrl+Tab still uses the MRU switcher. Its commit calls `selectTabForCommand`, then
refreshes through `WebContentContainer.show`. Main's `onReturnPreviewHost` callback
returns any borrowed page before the container binds the selected page. E12 now
visits the pinned tab before the current tab, highlights through the real Ctrl+Tab
route, then releases Control through the real modifier event. It checks that the
page's JavaScript marker survives and that no new host was created. The pending
highlight must leave the current selection unchanged.

The model's #130 shown-tab/departure bookkeeping is unchanged. The cross-Space TS
fixture now remembers its intended current tab before visiting the other Space;
returning does not introduce an intervening selection departure into MRU order.
The e2e runner has an optional `--focus-retry-delay-seconds` argument (default 0,
range 0–600). These merge-validation runs use 180 seconds between environment
interruptions, with the existing maximum of three fresh workflow attempts.


Merge-validation commands and results (same worktree, foreground):

| Command | Result |
|---|---|
| `git diff --check` | PASS |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only features-render,sidebar-render,commands-demo` | PASS: zero build warnings/errors; commands-demo 232/232, sidebar-render 564/564, features-render 335/335. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | PASS: Debug Open.app. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --style chrome --only sidebar-completion --focus-retry-delay-seconds 180` | PASS: 135/135 suite rows, plus fingerprint and cleanup (137 total). Both E12 rows, all 16 TS rows, and E16/AA_APP passed. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --style chrome --only app-actions --focus-retry-delay-seconds 180` | FAIL: 46/47 action rows on each of three runs. Fingerprint and cleanup passed on all runs. The only failed row is the unchanged 50 ms `first_open_results_budget`. |

App-actions cold-open results: **113.94 ms**, **57.45 ms**, **52.55 ms** against
50 ms. Runs two and three began after gaps of at least three minutes. The second start's load
averages were 11.78/11.04/11.55; the third's were 16.42/13.76/12.69. All other
functional action rows passed each time. Both suites had zero foreground
interruptions; these timing failures are not relabeled as environment
interruptions or accepted passes. No threshold, native event route, or
command-bar source was changed to clear the check. The cause remains unproven.
Stored older cold-open receipts are 43.98 ms on `013cdb45` and 18.84 ms on
`69ab7471`; they are not live baseline runs under this validation's conditions.
The branch is not green on the full app-actions suite.

Static audits found no duplicate Python definitions in the same scope, no
duplicate outer automation command cases, and no duplicate package targets.
Python compilation and the runner's `--help` path passed. Receipts are in
`.re/tab-switcher-merge/`: `verify.log`, `build.log`, `sidebar-completion.log`,
`sidebar-completion-results.json`, and `app-actions-attempt-{1,2,3}*` logs/JSON.
Generated `docs/engine-spike` changes were restored to the imported main version;
that directory has no merge-resolution differences from `013cdb45`.


### Cold command-bar investigation (2026-10-28, evening)

This is Open runtime evidence, not an Arc reverse-engineering claim. The 50 ms
`first_open_results_budget` remains unchanged. The timing still starts at
`EngineWebContentHostFactory.showCommandBar` entry and ends after the first
snapshot is applied to the actual command-bar views; it excludes key routing,
socket transport and frame presentation.

Both comparison apps were built with `heavy.sh tools/build.sh`, in detached
verification worktrees, from the same recorded engine distribution. Runs used
fresh app profiles, the same `engine_e2e.py` runner, local Shell C page, native
window-key route, no computer use, and the shared on-screen lock. Full app-actions
runs were back to back:

| Build | Cold first results | Suite rows |
|---|---:|---:|
| main `013cdb45` | 55.96 ms (FAIL) | 46/47 |
| branch `b7953e3d`, immediately afterward | 24.59 ms | 47/47 |
| main `dee105e6` | 21.81 ms | 47/47 |
| branch `b7953e3d`, immediately afterward | 33.59 ms | 47/47 |

The tight real-app cold flow also reproduced a 55.58 ms branch failure. In a later
interleaved run, main `dee105e6` measured 44.47 and 54.63 ms; the instrumented branch
measured 38.89, 32.14 and 46.91 ms. No timing row had foreground loss. One earlier
phase-probe attempt lost focus to UserNotificationCenter before the cold key; it
has no timing result and was retried after three minutes.

The phase probe found that local query work completed by 0.33–0.39 ms after
presentation entry (0.24–0.30 ms inside `runQuery`), while first application
waited 28.28–43.18 ms after query submission. `CommandBarController.present` called `runQuery`,
then synchronous layout, text-field focus, animation and its delegate. `runQuery`
consumed its already buffered initial snapshot only in a new main-actor Task.
Cold focus alone took 8.58–9.94 ms in these runs. `/usr/bin/sample <pid> 4 1 -file
<.re output>` captured `CommandBarController.present → focusInput →
NSWindow._realMakeFirstResponder → NSTextField.selectText → NSTextInputContext`
and cold TextInputUIMacHelper/InputAnalytics setup. Both sampled builds show this
path. Sampling perturbed timings; those timings are not acceptance measurements.

The branch defaults observer fired once per launch in the phase probe. No
TabSwitcher/snapshotPNG stack appeared in the samples. Source inspection confines
MRU sorting and host preview capture to `showTabSwitcher`/its delayed session;
`BrowserModel` selection bookkeeping remains main's implementation. The evidence
does not establish a branch-only cause. It does identify a removable wait for
results that are ready before AppKit focus and unrelated queued main-thread work.

The product now applies the initial local snapshot when opening the bar, in the
query call after provider work and action validation, before focus/animation.
Text edits retain their existing next-turn boundary, so pending Return can still
be cancelled by another edit, present or dismiss. Later async provider updates
retain their cancellable stream. Other SuggestEngine callers still get
the initial snapshot buffered in their stream. No result is fabricated or timed
before it reaches the actual views. The cold bar remains lazy. The switcher is
also now lazy; selection/layout/ordinary commands use optional existing state,
inactive cancel is a no-op, and its modifier monitor exists only while active.
`tab-switcher-state` reads lifecycle state without constructing a switcher.

After this change, the same interleaved cold flow measured main `dee105e6` at
17.86 and 17.08 ms, and the fixed branch at 3.34, 3.12 and 3.30 ms. No foreground
loss occurred. Raw full-suite receipts, minimized real-flow runner/results,
phase-probe results and samples are under `.re/tab-switcher-cold-open/`.
Final validation ran after merging `origin/main` at `dee105e6`. MainMenu keeps
last-tab/Favorites validation alongside #132's rename/Profile/Archive validation.
The merge keeps both sidebar helper bodies and invokes TS, items 9–10 and archive
flows once in the default suite. Ctrl+Tab still commits through
`selectTabForCommand` and the preview-host return path. The outer automation
commands (144 names), Python definitions per scope and package targets have no
duplicates. No new PR was opened.

| Final check, merged code | Result |
|---|---|
| `git diff --check` and staged whitespace check | PASS |
| `heavy.sh tools/verify-all.sh --only features-render,sidebar-render,commands-demo,commandbar-render,suggest-check` | PASS: build 0 warnings/errors, commands 232/232, sidebar 564/564, features 335/335, command bar 78/78, suggest 34/34. |
| `heavy.sh tools/build.sh` | PASS, Debug real app. |
| Locked `--only app-actions`, run 1 | PASS 48/48 feature rows + fingerprint/cleanup = 50/50; cold 3.3503 ms. |
| Locked `--only app-actions`, run 2 | PASS 50/50; cold 3.4163 ms. |
| Locked `--only app-actions`, run 3 | PASS 50/50; cold 3.2755 ms. |
| Locked `--only sidebar-completion` | PASS 164/164 feature rows + fingerprint/cleanup = 166/166; E12 2/2, TS 16/16, I9/I10 29/29, AA_APP 7/7. |

Each on-screen suite was a separate lock invocation, with no concurrent build.
All final runs had zero foreground interruptions and passed owned-process cleanup.
The new app-actions feature row verifies that launch and the first real Cmd+T
leave the switcher uncreated, without a view or modifier monitor. TS verifies the
monitor exists while active and disappears on Control release and Esc. The bar's
existing pending-Return checks are unchanged and pass. The first broader attempt
to apply text-edit results synchronously failed three of those checks; the final
opening-only path preserves their cancellation boundary.

Final receipts are `final-verify.log`, `final-verify-details/`, `final-build.log`,
`final-app-actions-{1,2,3}.log`, their `-results.json` files, and
`final-sidebar-completion.log` / `final-sidebar-completion-results.json`, all under
`.re/tab-switcher-cold-open/`. Generated `docs/engine-spike` artifacts were restored
before committing. Exact switcher visual values and Profile-wide candidate scope
remain guesses as documented in TS-R8/TS-C1; this performance fix claims no new Arc
capture or visual proof.


### Cmd+9 native menu parity correction (2026-10-28, evening)

The committed Arc menu reference `docs/re/menus-and-hotkeys.md`, “Tabs (23
items)”, has no Go to Last Tab / Last / Ninth item and no static Cmd+9 row.
Its “Shortcuts that live in code, not in the nib” table instead lists sidebar
items 1–9 and the last-item Cmd+9 variant. The following paragraph cites
`switchToNinthSidebarItemEnabled` and the ninth/last-item description strings.
Those facts support the shortcut behavior, not a new native menu entry.

Evidence: `commands-dump/main.swift` loads that committed reference through
`OpenCommands/ExpectedMenu.swift` and `MenuComparator`. The parent full gate on
`52839435` reported `extra: Tabs > Go to Last Tab []` with missing=0, extra=1.
`rg -n 'Last|Ninth|Cmd\+9' docs/re/menus-and-hotkeys.md` plus its Tabs table
confirms the distinction. No Arc app was launched or new Arc extraction made.

Open removes only the extra static native menu entry. Cmd+9 keeps its
`go-to-tab-9` keyboard route and `numberedTab(9)` preference-dependent target;
existing dynamic tab menu rows retain the Cmd+9 equivalent on the last or ninth
tab. The pre-existing code-only registry action remains available to command
routing. No comparison reference or allowed-extra rule changes. The TS real-App
row now performs the dynamic last-tab menu item by its identifier and asserts
that no separate Go to Last Tab row exists. The empty, fewer-than-nine,
more-than-nine, Include Favorites and ninth-option key flows remain in the suite.


Validation for this correction (same real build and event paths, separate locked
suite invocations, no build concurrent with the on-screen suites):

| Check | Result |
|---|---|
| `heavy.sh tools/verify-all.sh --only commands-dump,commands-demo,features-render` | PASS; build 0 warnings/errors, commands-demo 232/232, features-render 335/335. |
| `commands-dump` reference comparison | PASS: missing=0, extra=0, different=0; the existing 11 out-of-scope allowed-missing rows are unchanged. |
| `heavy.sh tools/build.sh` | PASS, real Debug app. |
| Locked Chrome `--only sidebar-completion` | PASS 164/164 feature rows + provenance/cleanup = 166/166; all 16 TS rows including dynamic Cmd+9 menu dispatch. |
| Locked Chrome `--only app-actions` | PASS 48/48 feature rows + provenance/cleanup = 50/50; cold first results 3.6755 ms against the unchanged 50 ms budget. |

Both e2e runs had zero foreground interruptions and passed cleanup. Raw receipts
are under `.re/tab-switcher-menu-parity/`: `verify.log`, `verify-details/`,
`build.log`, both suite logs and their `-results.json` files. Generated
`docs/engine-spike` artifacts were restored before committing.


### PR #134: rebound modifiers and auxiliary-window lifetime (2026-10-28)

This is Open routing evidence, not a new Arc behavior or visual claim. Review
comments 4407760174 and 4407760178 identified two gaps in custom shortcut and
auxiliary-window handling. The baseline product was `d6eeb860`; only
`features-render/TabSwitcherChecks.swift` changed for the red run. The normal
release harness exercised the real BrowserWindowController key router, model,
AppKit windows/local event monitor and lifecycle notification path. The baseline
had 335 passing rows and these four failures:

| Row | Baseline failure |
|---|---|
| TS11 | Bare F6 opened a session instead of selecting the next recent tab immediately. |
| TS12 | A Cmd+Option binding committed after the first modifier release. |
| TS13 | Control release delivered through NSApplication from an owned auxiliary panel did not commit. |
| TS14 | App-deactivation notification left the session and its pending work active. |

Evidence: `heavy.sh tools/verify-all.sh --only features-render`, raw
`.re/tab-switcher-review/before-verify.log` / `before-details/features-render.log`;
`before-product-head.txt` pins the baseline and `before-harness.patch` records the
only baseline change. The new rows extend the existing full-window harness,
not an isolated controller test. No unit tests were added.

The key router now exposes the initiating NSEvent only during dispatch of a
switcher command. The App factory passes it and the existing
`ownsAdditionalKeyWindow` predicate into `TabSwitcherController.advance`.
The first event freezes the held Command/Option/Control/Shift set; function,
caps-lock and numeric-pad flags do not count. With no held shortcut modifier,
the next candidate commits through the existing selection/preview-host return
path without creating a view, timer, monitor or deferred session. Otherwise,
commit waits until the event's flags intersect none of the initial modifiers.
Later advances keep the same session context.

Flags and keys accept the parent window, the weak initiating window, or another
window accepted by the same ownership predicate. Active-only observers cancel
on app deactivation, owned-window key loss or close. Finish removes those
observers and the modifier monitor, cancels pending work and releases previews.
The offscreen switcher renderer now supplies an explicit held-Control event.
Geometry, candidate scope, the menu-parity fix and cold command-bar work are
unchanged. The TS-C1 capture request remains open.


First integration checks ran after merging main `61ae275a2d2bb5c68a7652c8b0f56d547c773253`
(#133). The merge retained both sides without conflicts, including the new
verification runner and Site Control gate. The targeted
`heavy.sh tools/verify-all.sh --only features-render,sidebar-render,commands-dump,commands-demo`
passes: build 0 warnings/errors, commands 232/232, sidebar 564/564, features
339/339 (TS11–TS14 now PASS), menu comparison missing/extra/different 0/0/0.
The merged Debug App build passes. The offscreen `features-render switcher`
command renders the overlay with an explicit initiating Control event.

The full `heavy.sh tools/verify-all.sh` passes every default check (22/22):

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 2 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 0 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 2 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 13 |
| commands-dump | PASS | 0 |
| route | PASS | 1 |
| favicons | PASS | 0 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 77 |
| sidebar-render | PASS | 106 |
| sidebar-compare | PASS | 80 |
| commandbar-render | PASS | 14 |
| features-render | PASS | 42 |
| sitecontrol-render | PASS | 57 |
| boosts | PASS | 7 |

Locked real-App sidebar-completion passes 164/164 feature rows, 166 total with
provenance and cleanup. Locked app-actions passes 48/48 feature rows, 50 total;
cold command-bar results are 3.3301 ms at the unchanged 50 ms limit.
Both suites ran separately, with no concurrent build, zero foreground
interruptions and successful owned-process cleanup. No generated
`docs/engine-spike` artifacts are committed.

Receipts: `.re/tab-switcher-review/merged-targeted.log`,
`merged-targeted-details/`, `merged-build.log`, `full-verify.log`, `full-details/`,
`full-summary.md`, `render.log`, `switcher.png`, the two e2e logs and their
`-results.json` files. The red run remains in `before-*` separately.


#### Final integration with stored favicons, main `786b19ad`

After the green `61ae275a` run above, main advanced to
`786b19ad067197f18713397b4cbd07e5f2d927a1` (#131). The second merge retains
one features-render target with OpenSidebar/OpenSettings and both
TabSwitcherChecks/FaviconChecks sources. Both run once before AutoArchiveChecks.
The default e2e sequence runs TS, then assigns the relaunched App returned by
`sidebar_favicon_checks`, then keeps items 9–10 and archive flows. The duplicate
shared items 9–10 followup was retained once; the new favicon notes and all
switcher notes remain. Factory favicon handling and the initiating-event/preview
return path both remain. Audits found 144 unique outer automation command names,
no duplicate Python definitions per scope, no duplicate package targets and one
definition of each TS/FV/intents/archive helper.

The FULL `heavy.sh tools/verify-all.sh` passes again on this merged result,
22/22, including all TS11–TS14 and stored-favicon checks (features 372/372):

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 66 |
| commands-demo | PASS | 0 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 2 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 14 |
| commands-dump | PASS | 0 |
| route | PASS | 1 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 79 |
| sidebar-render | PASS | 107 |
| sidebar-compare | PASS | 145 |
| commandbar-render | PASS | 20 |
| features-render | PASS | 62 |
| sitecontrol-render | PASS | 112 |
| boosts | PASS | 7 |

The merged Debug App build passes. Locked sidebar-completion passes 172/172
feature rows plus provenance/cleanup (174 total), including all 16 TS rows and
all 8 FV rows. Locked app-actions passes 48/48 feature rows plus provenance/cleanup
(50 total); cold command-bar results 4.7755 ms at the unchanged 50 ms limit.
Both final suites had zero foreground interruptions and passed cleanup. Each
suite had its own lock invocation, after all builds and full verification ended.
Generated engine-spike artifacts were restored before commit.

Final receipts are `.re/tab-switcher-review/final-full-verify.log`,
`final-full-details/`, `final-full-summary.md`, `final-build.log`,
`final-sidebar-completion.log` / `final-sidebar-completion-results.json`, and
`final-app-actions.log` / `final-app-actions-results.json`. The earlier red and
`61ae275a` green receipts remain separately named.
