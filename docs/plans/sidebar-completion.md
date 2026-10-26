# Sidebar completion — implementation plan for Open

Status: plan (2026-10-25). Base: `main` at `d1720e3`. Implementers: two coding
agents with no other context (§7 splits the work). Follow this file literally.
Where it says "Open choice", the choice is final for v1. A value marked
**guess** ships as written until §8 (open questions) or a capture changes it.
Do not copy Arc assets, icons, sounds, Lottie files, JSON data, or decompiled
code (`AGENTS.md` rule 1). Draw every asset yourself; SF Symbols are allowed.
User-visible text never says "Arc" (`AGENTS.md` naming rule).

This plan closes the sidebar rows of `docs/status.md` §3: gaps 6, 7, 10, 11,
17–21, 31–34, and 36. RE facts with evidence are in
`docs/re/sidebar-completion.md` (cited as **SC §n**).

Read first, in this order:

1. `AGENTS.md` (rules 1–10).
2. `docs/status.md` §1.1–§1.6 and §3 (the gap rows this plan closes).
3. `docs/re/sidebar-completion.md` (all of it), then `docs/re/features-core.md`
   §1.2–§1.8, §2.2, §3.2–§3.3, `docs/re/interaction-states.md` §3, §6, §7,
   §13, §15, §16, and `docs/re/design-tokens.md` §1.3.
4. `docs/design.md` §2 (tokens), §5 (sidebar), §6–§8 (harness, compare, targets).
5. `docs/model.md` (commands, undo, events, archive).
6. `docs/plans/space-theme-editor.md` §3.3, §7, §8, §10.1 and its lead
   decisions (it owns the icon picker and "Turn folder into Space").
7. `docs/plans/app-shell.md` §3.3, §3.7, §4.1, §4.3 and `docs/plans/settings-library.md` §2.1, §5.1.1, §6.2.

## Goal

Ship the sidebar features that Arc has and Open lacks, in Arc's look and
behavior, without any full reload of the tab list:

1. Multi-select (Shift-click, Cmd-click, Shift+Arrow), with New Folder from
   Selection, bulk archive, move to Space, pin, duplicate, copy, and drag.
2. The Space Manager (Spaces ▸ Manage Spaces…) and drag to reorder Spaces.
3. Delete Space and delete folder confirmations with Arc's copy.
4. Expand All Folders, Collapse All Folders, Reset all tabs in this Space.
5. Export “Space” into Folder (Turn Space into Folder). Turn folder into Space
   stays with the theme plan.
6. Hover Previews of folders, pinned tabs, and Favorites.
7. Tidy titles for known sites from an Open-written rule table.
8. The unread dot on rows added in the background.
9. Back to Pinned URL and Separate From Pinned Tab on navigated pinned rows.
10. Clear unselected Today tabs and Archive Other Tabs.
11. The auto-archive education banner.
12. The hint the first time the sidebar is hidden.
13. Haptics when reordering; Open's own sound effects (infrastructure and assets).
14. Change Icon… for folders and pinned tabs (owned by the theme plan; checks here).
15. Archive a whole folder and restore it as a folder.
16. Hide the sidebar with the resize gesture, with a live preview.

## Success criteria

- Every feature in §3 works in the real app (after app-shell Steps B and C)
  and in the offscreen harnesses. Every check in §5 passes.
- Every structural command is one model command, one undo step, and sends
  per-node `TreeChange` events (or one diffed `.reload` where §2.3 says so).
  `SidebarDiagnostics.fullReloads` does not grow after the first build of a page.
- Where a capture exists, Open's render matches it within 1 pt and ΔE00 ≤ 2
  (§5.5). The 13 baseline states of `docs/design.md` §15.1 stay within their
  recorded worst values.
- Performance (release, `sidebar-render bench`, 1,000-row Space): selection
  toggle ≤ 1 ms main-thread p95 and at most 2 row layouts; bulk move or
  archive of 50 rows ≤ 16 ms p95; Expand All on 50 folders ≤ 16 ms; scroll
  p95 stays ≤ 5.6 ms. No new repeating timer. Idle CPU unchanged.
- No unit tests (`AGENTS.md` rule 6). No new third-party dependency.

## Non-goals

- Live Folders, Easels, Notes, Arc Max (Tidy Tabs AI), Share Space (`AGENTS.md`).
- Arc's site-specific glance views (Gmail unread list, calendar events,
  "recent pages" of Linear, Notion, Figma). §3.6 uses a live page preview
  instead (Q2).
- The Today auto-archive timer itself (status gap 4, app-shell Step G/H). The
  banner (§3.11) only listens to it.
- The Arc toast look (status gap 15). New toasts here use the existing
  OpenFeatures toast; the hint (§3.12) has its own measured view.
- "Archive Tabs Below" and "Archive Tabs Above" (Q16).
- Mapping the generic sound to sidebar events (no evidence; Q6).

## 0. Locked decisions

| # | Decision | Evidence / reason |
|---|---|---|
| D-1 | Multi-selection is per-window view state in `SidebarContext` (`SidebarSelection`). It is never in the model, the snapshot, or undo. Each row observes its own flag, so a change lays out only the rows that changed. | Arc keeps `multiSelectedItems` in window state (SC §3). `docs/design.md` §5.2 per-row observation; the Peek badge uses the same pattern (`SidebarPeekBadgeState`). |
| D-2 | Every bulk action is one new `BrowserModel` command and one undo step. It sends one `.insert` / `.remove` / `.move` per node. Only the two Clear variants send one `.reload(.spaceToday)`, as `clearToday` does today; the outline diffs it row by row. | `docs/model.md` "Events and lookup"; `SpacePageView.apply(target:in:)` never calls `reloadData`. |
| D-3 | No new library target. New code goes into `OpenModel`, `OpenStore`, `OpenSidebar`, `OpenDesign`, `OpenFeatures`, `OpenSettings`, and the existing harnesses. | `docs/plans/app-shell.md` non-goal "No new OpenKit library". |
| D-4 | The icon picker, `setNodeIcon`, `iconOverride`, Change Icon… for tabs and folders, and Turn folder into Space come from `docs/plans/space-theme-editor.md` (Steps 1, 6, 7). This plan adds no picker code. | Theme plan lead decision Q8. |
| D-5 | The Space Manager is a section of the Library window. Its view (`SpaceManagerView`) lives in `OpenSidebar`. `OpenSettings` hosts it through an injected `NSView` and gains no `OpenSidebar` dependency. | SC §2: `LibraryCategory.spaceManager`, `SpaceDisplayContext.spaceManager`. |
| D-6 | A page Hover Preview shows the tab's own web content host. A hidden cached host moves into the card; otherwise the factory makes a host with the tab's ID. On dismiss the host goes back to the container cache, so selecting the tab later shows the page with no reload. Folder previews are native AppKit. | Task brief ("reuse the Peek host"); `WebContentContainer.takeHost(for:)` / `adopt(_:for:)` exist. |
| D-7 | Destructive confirmations are system `NSAlert` sheets on the browser window, with Arc's copy (§2.6). | SC §1. |
| D-8 | Menu titles that wrap a name use curly quotes: `Turn “<folder>” into Space`, `Export “<Space>” into Folder`. | SC §6 (inline `Turn “`; capture F0117). Today `SidebarMenus.swift` uses straight quotes. |
| D-9 | Haptics go through one helper, `SidebarHaptics`, gated by `open.advanced.hapticOnTabReorder` (default true). | SC §10: `tabReorderingHapticsDisabled` defaults off. |
| D-10 | Sounds are Open's own, generated by our script `tools/generate-sounds.py`. Never Arc's files. | `AGENTS.md` rule 1; SC §10. |
| D-11 | The model holds no UI strings. The window controller sets undo action names (§2.3) after each intent, as the theme plan does (its D-11). | `docs/plans/space-theme-editor.md` D-11. |
| D-12 | No new command ids. The registry ids `manage-spaces`, `expand-all-folders`, `collapse-all-folders`, `reset-all-tabs-in-space`, `new-folder`, `pin-unpin-tab`, `duplicate-tab`, and `clear-unpinned-tabs` get handlers (§2.5). | `OpenCommands/CommandRegistry.swift`; `docs/commands.md` (never rename an id). |

## 1. Current state (verified at `d1720e3`; re-verify before you edit)

| Area | State today | Evidence |
|---|---|---|
| Outline | `SidebarOutlineView` with `shouldSelectItem → false`; the current row follows the model's `selectedNodeBySpace`. Keyboard Up/Down move a focus ring (`keyboardItem`); Delete archives a focused tab. Drag writes one node per row (`pasteboardWriterForItem`) and drops one node (`SidebarPasteboard.nodeID`). | `OpenSidebar/SpacePageView.swift` |
| Row fills | `SidebarRowView.updateFill`: current (selected fill + shadow), Peek source, hover/drop target. No multi-select state. | `OpenSidebar/SidebarRows.swift` |
| Menus | Today tab, pinned tab, favorite (guess), split, folder, Space, plus. Folder and Space menus use straight quotes. Folder "Delete" and Space "Delete Space" act at once. | `OpenSidebar/SidebarMenus.swift` |
| Intents | `deleteFolder` → `closeTab(folder)` and `deleteSpace` → `deleteSpace` run directly in `ModelSidebarActions`. `manageSpaces`, `exportSpaceIntoFolder`, `turnFolderIntoSpace`, `changeIcon` return false. | `OpenSidebar/ModelSidebarActions.swift` |
| Model | `moveNode`, `closeTab`, `createFolder(in:title:withNodes:)` (appends the folder at the end), `clearToday`, `resetPinnedTab`, `setExpanded`, `moveSpace(id:to:)` (no event), `deleteSpace`. No bulk commands, no duplicate, no folder archive. `selectNode` and `focusSplitPane` already clear `Tab.isUnread`. | `OpenModel/BrowserModel.swift` |
| Archive | One row per tab (`archived_tabs`, no kind column). The Library treats rows with reason `folderDeleted` as folders and reads `payload.children`. | `OpenStore/ArchiveStore.swift`; `OpenSettings/ArchiveSection.swift`, `LibraryViewModel.archivedChildCount` |
| Settings keys | `open.general.previewsEnabled` (true), `open.general.previewsDelaySeconds` (0.5), `open.advanced.hapticOnTabReorder` (true), `open.advanced.playSoundEffects` (false). | `OpenSettings/SettingsTypes.swift` |
| Window | On `main`, `OpenFeatures.BrowserWindowController` is the M4 version. PR #52 adds sidebar hide, resize (hide below 180 pt), hover-reveal, `showToast`, and `model.setSidebarMode`. | `git show origin/t3/app-shell-real-window:Packages/OpenKit/Sources/OpenFeatures/BrowserWindowController.swift` |
| Theme plan | Merged (#62). Adds `Tab.iconOverride` / `Folder.iconOverride`, `setNodeIcon`, the picker, and `createSpace(…, moving:)`. Not implemented yet. | `docs/plans/space-theme-editor.md` |

## 2. Shared definitions

### 2.1 Transient selection (`OpenSidebar/SidebarSelection.swift`, new)

```swift
@MainActor @Observable public final class SidebarSelection {
    /// Selected node IDs in display order (top to bottom of the page). Never persisted.
    public private(set) var ids: [ItemID] = []
    /// Shift-click and Shift+Arrow extend from here.
    public private(set) var anchor: ItemID?
    public var isEmpty: Bool { ids.isEmpty }
    public func contains(_ id: ItemID) -> Bool
    public func toggle(_ id: ItemID, order: [ItemID])          // Cmd-click
    public func extend(to id: ItemID, order: [ItemID])          // Shift-click / Shift+Arrow
    public func select(_ ids: [ItemID], anchor: ItemID?)
    public func clear()
    public func prune(keeping visible: Set<ItemID>)             // after removes and collapses
    /// One observable object per row; a row reads only its own flag.
    func rowState(for id: ItemID) -> SidebarRowSelectionState    // { isSelected: Bool }
}
```

`SidebarContext` gains a stored `public let selection = SidebarSelection()`
(one per window).

`order` is the page's visible selectable rows (tabs, splits, folders; not the
spacer, divider, or New Tab row), built from the outline's rows on demand.

### 2.2 New `SidebarIntent` cases (`OpenSidebar/SidebarIntent.swift`)

```swift
case moveNodes(ids: [ItemID], to: NodeParent, index: Int?)      // drag of a selection
case moveNodesToSpace(ids: [ItemID], space: SpaceID)            // Move to ▸ <Space>
case archiveNodes(ids: [ItemID])                                 // "Archive Items" (tabs, splits)
case deleteFolders(ids: [ItemID])                                // App confirms first (§3.3)
case newFolderFromSelection(ids: [ItemID])
case setPinned(ids: [ItemID], pinned: Bool)                      // "Pin Tabs" / "Unpin Tabs", Cmd+D
case duplicateNodes(ids: [ItemID])
case copyLinks(ids: [ItemID], markdown: Bool)
case clearTodayKeeping(space: SpaceID, keep: Set<ItemID>)        // ⌥ Clear, "Archive Other Tabs"
case separateFromPinned(tabID: ItemID)
case archiveFolder(folderID: ItemID)
case openProfileSettings(ProfileID)                              // banner "Settings" link
case dismissAutoArchiveBanner
case hoverPreview(SidebarHoverPreviewRequest?)                   // nil hides
case sidebarHiddenByGesture                                       // §3.16, for the hint
```

```swift
public struct SidebarHoverPreviewRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case folder(ItemID), page(tabID: ItemID) }
    public var kind: Kind
    public var anchorInWindow: CGRect     // the hovered row or tile, window coordinates
}
```

`ModelSidebarActions` maps every new case that only touches the model
(`moveNodes`, `moveNodesToSpace`, `archiveNodes`, `newFolderFromSelection`,
`setPinned`, `duplicateNodes`, `clearTodayKeeping`, `archiveFolder`, and the
existing `exportSpaceIntoFolder(space:destination:)`, which calls
`turnSpaceIntoFolder`). The App owns `deleteFolders`, `deleteFolder`,
`deleteSpace` (alerts first), `copyLinks` (pasteboard), `separateFromPinned`
(host handoff, then the model), `openProfileSettings`,
`dismissAutoArchiveBanner`, `hoverPreview`, and `sidebarHiddenByGesture`.
`ModelSidebarActions` keeps performing `deleteFolder` and `deleteSpace`
directly, because the harness uses it as its whole delegate; the App
intercepts those two intents before it calls `ModelSidebarActions`.

### 2.3 Model commands (`OpenModel/BrowserModel.swift`)

Rules from `docs/model.md` apply: a refused command changes nothing, sends no
event, and registers no undo. Undo and redo call primitives only.

| Command | Behavior | Events | Undo name (set by the controller) |
|---|---|---|---|
| `moveNodes(ids:to:at:) -> Int` | Moves the nodes in the given order to consecutive slots from `at` (nil = end; Favorites accept tabs only). `at` counts in the destination list before the move; the model subtracts moved nodes that sat above it. Skips nodes `canMoveNode` refuses and nodes whose ancestor folder is also in `ids`. Pinned-URL rule per node. Returns the moved count. | one `.move` per moved node, in order | "Move Items" / "Move Item" (Arc literals, SC §6) |
| `moveNodes(ids:toSpace:markUnread:) -> Int` | Each node goes to the top of its section in the target Space (pinned ancestry → Pinned, else Today), in selection order. `markUnread` sets `isUnread` on moved tabs; undo restores old values. | one `.move` per node | "Move Items" / "Move Item" |
| `archiveNodes(ids:) -> Int` | Archives tabs and splits with reason `closed`, folders with reason `folderDeleted` (their tabs), wherever they live. One sink call. Split panes in `ids` close as panes (existing collapse rule). | one `.remove` per node, highest index first per parent | "Archive Items" / "Archive Item"; folders only: "Delete Folders" / "Delete Folder" |
| `createFolder(in:at:title:withNodes:) -> Folder?` | Adds `at` (default nil = today's behavior). New Folder from Selection passes the first selected node's parent and index. | `.insert` (folder) + one `.move` per node | "New Folder" (Arc literal) |
| `setPinned(ids:pinned:) -> Int` | `pinned: false` moves every pinned tab or split in `ids` to the top of its Space's Today, in order. `pinned: true` moves every Today tab or split to the end of its Space's Pinned, in order. Favorites and folders are skipped. | one `.move` per node | "Pin Tabs" / "Unpin Tabs" (Arc menu literals) |
| `duplicateNodes(ids:) -> [ItemID]` | Tab: new ID, same `url`, `title`, `customTitle`, `customIcon`, `iconOverride`, `isMuted`, `pinnedURL` (if pinned); inserted right after the source. A favorite's copy goes to the top of the focused Space's Today (**guess**, FC §1.4 r18). Split: new split with duplicated panes. Folder: deep copy with new IDs. Returns the new top-level IDs. | one `.insert` per new node | "Duplicate" |
| `setAllFoldersExpanded(spaceID:expanded:) -> Int` | Every folder at any depth in the Space's Pinned and Today. Same-value folders are skipped; none changed → no undo. | none (property change; outline syncs expansion) | "Expand All Folders" / "Collapse All Folders" |
| `resetPinnedTabs(spaceID:) -> [ItemID]` | Every tab with pinned ancestry in the Space (folders and splits included; Favorites excluded) whose host or path differs from `pinnedURL`: `url = pinnedURL`, `lastActiveAt = now`. Returns the reset IDs (the App navigates live hosts). | none | "Reset Tabs" |
| `clearToday(space:keeping:)` | Like `clearToday(space:)`, but keeps every top-level Today node that is in `keeping` or has a descendant in `keeping`. Reason `clearedToday`. | one `.reload(.spaceToday)` | "Clear Tabs" |
| `separateFromPinnedTab(id:) -> Tab?` | Refuses unless the tab has pinned ancestry and `url` differs from `pinnedURL` (host or path). Creates `T(url, title, isMuted)` at index 0 of the tab's Space Today; sets the pinned tab's `url = pinnedURL`. Returns `T`. | `.insert(spaceToday, 0, T)` | "Separate From Pinned Tab" |
| `turnSpaceIntoFolder(id:destination:) -> Folder?` | Refuses when `id == destination`, either Space is missing, or only one Space exists. Builds `Folder(title: displayTitle(source))` (its `iconOverride` = the Space icon when the theme plan's field exists) holding the source's Pinned nodes, then its Today nodes, in order. Inserts it at index 0 of the destination's Pinned; pinned-URL rule per tab. Removes the source Space; windows focused on it move to the destination. Undo restores the Space at its slot, its lists, exact `pinnedURL`s, and window focus. | `.insert(spacePinned(dest), 0, folder)`, then `.reload(.spaceToday(source))` (the existing Space-removal event) | "Turn into Folder" (Arc literal) |
| `archiveFolder(id:) -> Bool` | Detaches a folder subtree and writes one folder archive entry (§3.15). | one `.remove` | "Archive Folder" |
| `restoreArchivedFolder(_:) -> Folder?` | §3.15. | one `.insert` | "Restore Folder" |
| `newTab(in:url:title:at:unread:)` | Adds `unread: Bool = false`. No extra undo step. | unchanged | unchanged |
| `moveSpace(id:to:)` | Exists. | none (observation of `spaces`) | "Move Space" |

### 2.4 Persistence changes

| Store | Change | Compatibility |
|---|---|---|
| Snapshot (`State/browser.json`) | None. `Tab.isUnread` already persists. Selection, previews, banners, and hints are transient. | — |
| Archive (`archived_tabs`) | New column `kind TEXT NOT NULL DEFAULT 'tab'`, values `tab` / `folder`. On open: if `PRAGMA user_version` is 0 and the column is missing, run `ALTER TABLE archived_tabs ADD COLUMN kind TEXT NOT NULL DEFAULT 'tab'` and set `user_version = 1`, in one transaction on the store's queue. | Old rows read as tabs. Older builds ignore the column. |
| `ArchivedTabRecord` (OpenModel) | New `kind: ArchiveRecordKind` (`.tab`, `.folder`), default `.tab`. | Source compatible. |
| `UserDefaults` (app scope; add to `settings-library.md` §2.1 registry and `SettingsTypes.swift` defaults) | `open.sidebar.hideHintShown` Bool false; `open.sidebar.autoArchiveBannerDismissed` Bool false; `open.sidebar.autoArchiveBannerEligible` Bool true. | New keys only. |

### 2.5 Menus, hotkeys, and registry ids

| Feature | Menu bar (registry id) | Context menu | Keys |
|---|---|---|---|
| Multi-select actions | Tabs ▸ Pin/Unpin Tab (`pin-unpin-tab`), Tabs ▸ Duplicate (`duplicate-tab`), Tabs ▸ New Folder… (`new-folder`, sidebar focused) act on the selection when it is not empty | §3.1 selection menu | Cmd+D, Cmd+Shift+N (sidebar focused), Delete, Esc, Shift+Up/Down |
| Space Manager | Spaces ▸ Manage Spaces… (`manage-spaces`) | Space menu "Manage Spaces…" | none (Arc has none) |
| Expand / Collapse All | Tabs ▸ Expand All Folders (`expand-all-folders`), Collapse All Folders (`collapse-all-folders`) | — | none |
| Reset all | Tabs ▸ Reset all tabs in this Space (`reset-all-tabs-in-space`) | — | none |
| Clear | Tabs ▸ Clear Unpinned Tabs (`clear-unpinned-tabs`) | Today tab "Archive Item" ⌥ alternate "Archive Other Tabs" | Cmd+Shift+K |
| Delete | — | Space "Delete Space"; folder "Delete"; selection "Delete" | Delete key on a focused folder row |
| Archive folder | — | folder "Archive Folder" (above "Delete") | — |
| Turn Space into folder | — | Space "Export “<Space>” into Folder ▸"; Space Manager "…" ▸ "Turn into Folder ▸" | — |

`isCommandEnabled` keys (App, app-shell §4.3): `expand-all-folders` when the
focused Space has a collapsed folder; `collapse-all-folders` when it has an
expanded folder; `reset-all-tabs-in-space` when a pinned tab there left its
pinned URL; the others as today.

### 2.6 Copy (Arc's text; "Arc" becomes "Open")

| Where | Text | Source |
|---|---|---|
| Delete Space alert | Title "Delete your <Space display title> Space?"; text "This will archive all the tabs and folders inside it."; buttons "Delete", "Cancel" | SC §1 |
| Delete folder alert | Title "Delete your <folder title> folder?" ("Are you sure?" when the title is empty or when several folders are deleted, **guess** for the plural); text "Deleting this folder will archive the tabs inside it."; buttons "Delete Folder", "Cancel" | SC §1 |
| Folder deleted toast | "Folder deleted" / "Folders deleted", with Undo | SC §1 |
| Clear toast | "Cleared Tabs", with Undo | SC §4 |
| Clear tooltips | "Clear Today tabs"; with ⌥ "Clear unselected Today tabs" | SC §4 |
| Pinned reset tooltips | "Back to Pinned URL"; with ⌥ "Separate From Pinned Tab" | SC §5 |
| Selection menu | "New Folder with <N> Items", "Archive Items", "Pin Tabs", "Unpin Tabs", "Copy Links", "Copy Links as Markdown", "Duplicate", "Delete" | SC §3 ("Copy Links" plural is an Open choice built from Arc's singular "Copy Link") |
| Folder archive | "Archive Folder" / "Archive Folders" | SC §6 |
| Folder restore toast | "Folder restored to <Space>. Click to view." | SC §6 |
| Space Manager | Grabber tooltip "Drag to Reorder Space"; "…" tooltip "More options"; menu "Turn into Folder", "Delete" | SC §2 |
| Banner | Title "We cleaned up!"; message "Open archives tabs that you haven't used in the past <threshold>. You can adjust this in Settings."; button "Got it" | SC §10 (Arc's message says "12 hours" literally; Open inserts the profile's threshold, Q12) |
| First-hide hint | "You can use [⌘S] to easily show and hide your Sidebar!" | SC §10 |

### 2.7 New tokens (`OpenDesign`)

| Token | Value | Mark |
|---|---|---|
| `SidebarColors.tabMultiselected` | light `#000000` a 0.10, dark `#FAFBFF` a 0.10 (P3), from `TabCellBackgroundMutiselected` | fact (SC §3) |
| `SidebarRole.rowMultiselected` | = `SidebarColors.tabMultiselected` | — |
| `SidebarRole.unreadDot` | the Space accent (`SpaceThemeStyle.accentColor`) | guess |
| `PreviewColors.background` | light `#FFFFFF`, dark `#212222` (`PreviewBackgroundColor`) | fact (SC §7) |
| `SpaceListMetrics.unreadDotSize` 6, `unreadDotCenterX` `W − 26`, `unreadDotCenterY` `y + 20` | | guess |
| `SpaceListMetrics.resetGlyphPlate` `[17 + indent − 2, y + 9, 22, 22]`, radius 6 | | guess |
| `BannerMetrics` inset 8, padding 12, radius 10, title 13 Semibold, message 12 Regular, line height 15, button 24 pt tall | | guess |
| `HoverPreviewMetrics` page card 420 × min(560, H − 20), folder card 300 wide, row 32, gap to sidebar 8, radius 10, shadow black 0.25 radius 12 y +4 | | guess |
| `HintToastMetrics` (OpenFeatures, new file `OpenDesign/HintToastTokens.swift`) | §3.12 | measured |
| `Motion.previewIn` 0.15 s, `Motion.previewOut` 0.10 s, `Motion.hintIn` 0.20 s, `Motion.hintOut` 0.25 s, `Motion.hintLifetime` 5.5 s, `Motion.bannerIn` 0.22 s | | guess (lifetime measured ≈ 5–6 s) |

## 3. Feature specs

Each feature lists interaction, visuals, motion, model, persistence, menus and
keys, and verification. Check IDs refer to §5.

### 3.1 Multi-select (gap 6)

**Interaction (mouse).**

- Cmd-click a tab, split, or folder row: toggles it in the selection. When the
  selection was empty and the page's current row is visible, the current row
  joins first, so the result holds both rows (**guess**, Q9). The anchor
  becomes the clicked row. The model selection and the page on screen do not
  change.
- Shift-click: selects every visible selectable row between the anchor and the
  clicked row in display order, across Pinned and Today. Rows inside collapsed
  folders are not visible and not selected. The spacer, divider, and New Tab
  rows are skipped. Rows that were Cmd-selected outside the range stay
  selected (standard `NSTableView` rule).
- Plain click on any row: clears the selection, then selects as today.
- Right-click a selected row while 2 or more rows are selected: the selection
  menu (below). Right-click any other row: clears the selection, then shows
  that row's own menu.
- Favorites tiles never join the selection (**guess**).
- The selection clears on: a Space switch in the window, Esc, a plain click,
  and the command that consumes it (New Folder from Selection, Archive Items,
  Delete, Move to). Removed or hidden rows leave the selection (`prune`).

**Interaction (keyboard, outline focused).** Shift+Down / Shift+Up: adds the
focus row (if not selected), moves the focus to the next / previous selectable
row, and adds it. Up / Down without Shift: as today, and clears the selection.
Esc: clears it. Delete / Forward Delete with a selection: tabs and splits →
`archiveNodes`; folders → the folder alert (§3.3). Cmd+D, Cmd+Shift+N, and
Tabs ▸ Duplicate act on the selection when it is not empty (§2.5).

**Interaction (drag).** Dragging any selected row drags the whole selection:
the outline's `selectedRowIndexes` mirror `SidebarSelection` for this page
(`selectionHighlightStyle` stays `.none`), so `NSOutlineView` writes one
pasteboard item per selected row, in display order. A drop in the outline,
on a folder, or on Favorites sends `.moveNodes`. A drop on a switcher Space
icon sends `.moveNodesToSpace` (one undo step; replaces today's one move per
node). A drop on the web content to make a split accepts one row only; with
more rows the split overlay refuses (**guess**). During the drag the source
rows draw at alpha 0.4 (`shouldDim`, **guess** value).

**Selection menu** (2+ rows; order **guess**, built from the single-row
menus and SC §3):

- Tabs and splits only: Copy Links · Copy Links as Markdown · — · New Folder
  with <N> Items · Move to ▸ (each Space · — · New Space…) · — · Pin Tabs or
  Unpin Tabs ("Unpin Tabs" when every selected node is pinned) · Duplicate ·
  — · Archive Items.
- With one or more folders: Copy Links · Copy Links as Markdown · — · New
  Folder with <N> Items · Move to ▸ · — · Duplicate · — · Archive Items (acts
  on the tabs and splits) · Delete (acts on the folders, alert first).
- Copy forms: one line per tab, depth-first through folders and split panes;
  plain `url`, Markdown `[title](url)` (same as Copy All Links).
- "Move to ▸ New Space…" opens the theme plan's form with `moving:` = the
  selection (`createSpaceFromSelection`, SC §3).

**Visuals.** A selected row that is not the current row draws
`SidebarRole.rowMultiselected` in the normal fill rect `[8 + indent, y + 2,
W − 16 − indent, 36]`, radius 10 continuous, no shadow. The current row keeps
its selected fill and shadow. Hover over a selected row keeps the multi fill
(0.10 is darker than the 0.05 hover). Split rows use the same fill; their
pane cells show only when current. A selected folder fills only its own row.

**Motion.** Fill fade 0.08 s (`Motion.hoverFade`) in and out. Bulk moves and
removes use the existing 0.22 s row animations, one step per event.

**Model.** `moveNodes`, `moveNodes(toSpace:)`, `archiveNodes`,
`createFolder(in:at:…)`, `setPinned`, `duplicateNodes` (§2.3). After New
Folder from Selection the sidebar starts inline rename on the new folder
(Arc keeps `renameHintItemID` in window state, SC §3; **guess**).

**Persistence.** None.

**Verification.** `sidebar-render check` MS1–MS14; `sidebar-render render
--multi-select`; `sidebar-render bench --selection`; `openkit commands-demo`
B1–B8; e2e E1–E4. No capture exists (§8.2 C1): fills are checked against the
token (ΔE00 ≤ 0.5 against the composited token) and the hover-fill geometry
(0 pt).

### 3.2 Space Manager and Space reorder (gap 7)

**Entry.** Spaces ▸ Manage Spaces… (`manage-spaces`), the Space menu
"Manage Spaces…", the command bar, and a new Library sidebar row "Spaces"
(symbol `rectangle.split.3x1`). All open the Library window on the Spaces
section (`LibrarySection.spaces`, new, placed first).

**Layout** (all **guess**; no capture, §8.2 C2). The section shows
`SpaceManagerView` (OpenSidebar): a horizontal `NSScrollView` of Space columns
in Space order. Leading inset 16, gap 12, top inset 16, bottom inset 16.
Column = a card 244 pt wide (sidebar default 228 + 16), full height, radius
10 continuous, that draws that Space's theme (`ThemeBackgroundView`, one per
column, built when the column first scrolls into view). Column content:

- Header (`SpaceControlsView`, 44 pt): grabber `[8, 10, 24, 24]`
  (`line.3.horizontal`, 13 pt, `SidebarRole.spaceTitle`, open-hand cursor,
  closed-hand while dragging, tooltip "Drag to Reorder Space"); Space icon
  `[34, 9, 26, 26]` (`SpaceIconView`); title 13 Semibold at x 66; Profile chip
  when 2+ Profiles exist (Profile name, 11 Medium, `GrayA4` capsule, 18 pt
  tall; `spaceManagerSpaceHeaderIndicator`); "…" button `[W − 32, 10, 24, 24]`
  (tooltip "More options") with menu "Turn into Folder ▸" (every other Space)
  · — · "Delete" (enabled when 2+ Spaces exist; alert §3.3).
- Body: a `SpacePageView` for the Space (same rows, menus, rename, drag and
  drop, folder expansion, and multi-select). Favorites are not shown.

**Interaction.** Rows behave as in the sidebar. A drop into another column
moves the nodes into that Space (`.move` / `.moveNodes`). Dragging the grabber
starts a column reorder: the column lifts (shadow black 0.25, radius 8, y +4;
scale 1.02), follows the pointer horizontally, and the other columns slide to
make room with `Motion.spaceSwitch` when the pointer crosses their midpoints.
Release → `moveSpace(id:to:)`; Esc → the column springs back. Haptic
`.alignment` on each slot change (§3.13).

**Switcher reorder** (Open choice; Arc's flag for it is Windows-only, Q5).
Press a bottom-bar Space item and move 4 pt or more horizontally: the item
follows the pointer within the strip, the other items shift by the 34 pt
pitch with `Motion.spaceSwipeSnap` as the pointer crosses their midpoints, and
release commits `moveSpace(id:to:)`. No Space switch happens on that release.
Esc, or a vertical move of more than 40 pt, cancels (spring back). A click
without the 4 pt move still switches Spaces. This is a mouse tracking loop,
not an `NSDraggingSession`, so tab drops onto Space icons keep working.

**Model.** `moveSpace(id:to:)` (exists), `turnSpaceIntoFolder` (§3.5),
`deleteSpace` (exists, behind the alert). `SpacePagerView` must reorder its
pages without rebuilding them when `model.spaces` order changes (the existing
page cache is keyed by Space).

**Persistence.** None beyond the existing Space order in the snapshot.

**Verification.** `sidebar-render space-manager` scene; checks SM1–SM6,
SW1–SW4; `settings-preview check` L1 (the Spaces section hosts the injected
view); e2e E5–E6. No capture (§8.2 C2).

### 3.3 Delete Space and delete folder confirmations (gaps 10, 11)

**Interaction.** Space menu "Delete Space", the Space Manager "…" ▸ "Delete",
folder menu "Delete", the selection menu "Delete", and the Delete key on a
focused folder row all show the alert first. The alert is a sheet on the
browser window (`beginSheetModal`), style `.warning`, app icon. Buttons in
order: the destructive button (first, `hasDestructiveAction = true`, Return)
and "Cancel" (Esc). Copy in §2.6. Delete Space uses the display title ("Space
N" for untitled Spaces). The alert shows even for an empty Space or folder
(**guess**). There is no "Don't ask again".

On confirm: Space → `deleteSpace(id:)`; folders → `archiveNodes(ids:)` (one
undo step), then the toast "Folder deleted" / "Folders deleted" with Undo
(existing OpenFeatures toast, 5 s). Cancel changes nothing and registers no
undo. While a sheet is open, a second delete request is ignored.

**Visuals.** System alert (no custom drawing).

**Model.** Existing commands; no change.

**Verification.** `features-render check` DA1–DA5 (real `NSAlert` sheet in an
offscreen window; the check presses buttons through `NSButton.performClick`);
e2e E7–E8 through the automation `alert` command. No capture exists (§8.2 C3).

### 3.4 Expand / Collapse All Folders and Reset all tabs (gap 17)

**Interaction.** Tabs ▸ Expand All Folders, Collapse All Folders, and Reset
all tabs in this Space, plus the command bar ("Open Folders" and "Show Folders"
are extra aliases, SC §6; add them to `expand-all-folders`). They act on the
key window's focused Space.

**Visuals and motion.** Expand / Collapse: every changed folder animates in
one `NSAnimationContext` group of 0.22 s (`Motion.rowStructure`), so rows move
once. The first visible row stays in place when it remains visible
(**guess**). Reset: the "/" marks of the reset rows disappear; live pages
navigate to their pinned URL (App).

**Model.** `setAllFoldersExpanded`, `resetPinnedTabs` (§2.3). The outline
already syncs expansion from `Folder.isExpanded` (`SpacePageView.syncExpansion`);
make sure folders that were never expanded get their child lists when they
expand (the data source loads them).

**Verification.** `sidebar-render check` EA1–EA4; `openkit commands-demo`
B9–B10; `sidebar-render bench --expand-all` (50 folders × 10 rows ≤ 16 ms); e2e
E9.

### 3.5 Turn Space into folder; Turn folder into Space (gap 18)

**Turn folder into Space** belongs to the theme plan (its §8 entry table and
Step 7: the New Space form with `moving:` = the folder children). This plan only changes the
menu title to curly quotes (D-8).

**Export “<Space>” into Folder ▸ <destination>** (Space menu) and Space
Manager "…" ▸ "Turn into Folder ▸ <destination>": `turnSpaceIntoFolder(id:
destination:)` (§2.3). No confirmation (undo covers it, **guess**). The new
folder lands at the top of the destination's Pinned section; the source's
Today tabs become pinned children (Q8). If the acting window was focused on
the source Space, the pager slides to the destination with the normal Space
switch, and the new folder row appears with the insert animation. If the
destination uses another Profile, the App tears down the moved tabs' hosts,
as for any cross-Profile move (app-shell §4.8).

**Verification.** `openkit commands-demo` B11–B13; `sidebar-render check`
TF1–TF3; e2e E10.

### 3.6 Hover Previews (gap 19)

**Targets.** Folder rows; pinned tab rows (pinned ancestry, also inside
folders); Favorites tiles. Not: Today tabs, split rows, the current row or
tile (already on screen), and any row while a drag, rename, menu, or Space
swipe is active.

**Arm and show.** `HoverPreviewTracker` (OpenSidebar) arms when the pointer
rests on a target for `open.general.previewsDelaySeconds` (default 0.5 s).
Pointer moves inside the same target do not restart the timer. After a
preview has shown, moving to another target swaps at once for 1.0 s after
the last preview hid (Arc `lastCommittedHover`; **guess**). While a preview is
armed or shown, the row tooltip does not show. The tracker sends
`.hoverPreview(request)`; nil hides. Gate: `open.general.previewsEnabled`;
when false the tracker does no work at all.

**Dismiss.** The pointer is outside both the row and the card for 0.25 s; a
click on the row (normal select; the card hides with no animation); Esc;
scroll; a menu opens (`menuTrackingToken`); window resigns key; Space switch;
drag start.

**Page preview** (OpenFeatures `HoverPreviewController`). A borderless child
panel at x = sidebarWidth + 8 (window coordinates), y = row top − 10 clamped to
`[10, H − 10 − h]`, size 420 × min(560, H − 20), radius 10 continuous, shadow
black 0.25 radius 12 y +4, fill `PreviewColors.background` under the page.
Host: `container.takeHost(for: tab.id)` when the tab has a hidden cached host;
otherwise `factory.makeHost(tabID: tab.id, profileID:, url: tab.url)`. At most
one preview host exists. On dismiss: `container.adopt(host, for: tab.id)`, so
the host joins the hidden LRU (8) and the sleep policy. A click inside the card
selects the tab; the container shows the same host (no reload) and focuses it.

**Folder preview** (OpenSidebar `FolderPreviewView`, shown by the same
controller). Card 300 pt wide, same panel, radius, shadow, and fill. Header 36
pt: folder glyph 16 pt at x 12 and the title, 13 Semibold. A search field
(`NSSearchField`, 24 pt) under the header when the folder has more than 8 tabs
(**guess**; Arc's view has `searchQuery`). Rows 32 pt: favicon 16 at x 12,
title 13 Regular at x 36, depth-first, at most 10 rows visible, then it
scrolls. Hover row fill `SidebarColors.itemHoveredBackground`. Click a row →
select that tab (the model expands its folder chain). Up / Down move a
highlight, Return opens it. The card follows the Space's content appearance.

**Motion.** In: alpha 0 → 1 and scale 0.97 → 1.0, 0.15 s ease-out. Out: alpha
1 → 0, 0.10 s. Swap: content crossfade 0.10 s, frame animates 0.15 s.

**Persistence.** None. Q3 proposes better Previews settings keys.

**Verification.** `sidebar-render check` HP1–HP6 (tracker timing and gates,
folder card layout); `features-render check` HP7–HP10 (host reuse with
`FakeWebContentHost`); e2e E11–E12 (no reload after select: a JavaScript
global set during the preview survives). No capture (§8.2 C4).

### 3.7 Tidy titles (gap 20)

**Data.** `OpenModel/TidyTitles.swift` (new) holds Open's own table as Swift
literals. The shape follows the schema facts in SC §8 (never Arc's values):

```swift
public struct TidySite: Sendable { public let host: String; public let siteName: String; public let rules: [TidyRule] }
public struct TidyRule: Sendable { public let match: TidyMatch; public let title: TidyTitle }
public enum TidyMatch: Sendable { case any, pathEquals(String), pathMatches(String), fragmentEquals(String), fragmentMatches(String) }
public enum TidyTitle: Sendable { case always(String), removing([String]) }   // regex patterns
public enum TidyTitles { public static func tidy(title: String, url: URL) -> String }
```

Host match: exact host, with a leading `www.` ignored. The first matching rule
wins; no match returns the title unchanged. An empty result returns the raw
title. Seed table (Open-written from each site's public page-title format;
the implementer may add sites, each with a fixture pair in `commands-demo`):

| Host | Rules |
|---|---|
| `mail.google.com` | fragment `inbox` → "Inbox"; `starred` → "Starred"; `sent` → "Sent"; `drafts` → "Drafts"; any → remove ` - [^ ]+@[^ ]+ - Gmail$` |
| `docs.google.com` | any → remove ` - Google (Docs|Sheets|Slides|Forms)$` |
| `drive.google.com` | any → remove ` - Google Drive$` |
| `calendar.google.com` | any → remove `^Google Calendar - ` |
| `www.youtube.com` | any → remove `^\(\d+\) ` and ` - YouTube$` |
| `github.com` | any → remove ` · GitHub$` |
| `x.com`, `twitter.com` | any → remove ` / X$` and `^\(\d+\) ` |
| `www.linkedin.com` | any → remove `^\(\d+\) ` and ` \| LinkedIn$` |
| `en.wikipedia.org` | any → remove ` - Wikipedia$` |
| `stackoverflow.com` | any → remove ` - Stack Overflow$` |
| `www.figma.com` | any → remove ` – Figma$` |
| `app.slack.com` | any → remove ` - Slack$` |
| `outlook.live.com`, `outlook.office.com` | any → remove ` - Outlook$` |
| `www.amazon.com` | any → remove `^Amazon\.com ?: ?` |

**Where.** `Tab.displayTitle` becomes `customTitle ?? TidyTitles.tidy(title:,
url:)`. Every surface that shows `displayTitle` (rows, menus, AX labels,
tooltips) follows. Searches that match `title` keep matching the raw title.
A main-actor cache (512 entries, keyed by title + host + path + fragment)
holds results; regexes compile once. Budget: ≤ 5 µs per cached call, ≤ 50 µs
per miss. No setting (Arc has none for this; `tidyTabsEnabled` is a different
feature).

**Verification.** `openkit commands-demo` T1–T3 (40 synthetic title/URL
pairs, one per rule plus no-match cases, and timing);
`sidebar-render check` TT1–TT2 (a Gmail fixture row draws "Inbox (3)"; a
title change redraws only that row). Re-run the 13 baseline comparisons
(§5.5): report any row whose title text changed and keep every state within
its recorded worst values.

### 3.8 Unread badge (gap 21)

**When.** `Tab.isUnread` (exists, persisted) is set by the App when a tab is
created and not selected: a link opened in the background (Cmd-click in a
page), command bar `.open` with Cmd (background), an external link routed to
a Space that the front window does not show, and Little Open "open in Space"
into an unfocused Space. `moveNodes(toSpace:markUnread: true)` sets it when
"Move to ▸ <Space>" targets a Space that the acting window does not show
(**guess**, Q11). `selectNode` / `focusSplitPane` clear it (exists).

**Visuals** (**guess**, §8.2 C5; Arc draws a dot layer, SC §9). A 6 pt dot,
`SidebarRole.unreadDot`, centered at `(W − 26, y + 20)` (the close slot's
center). Hidden while the row is hovered (the close button wins) and while a
Peek badge shows. The title ends 6 pt before the dot. A collapsed folder row
shows the dot when any descendant tab is unread (**guess**).

**Motion.** Appear: scale 0 → 1, 0.2 s spring (`response 0.2`, damping 0.8).
Clear: fade 0.12 s.

**Model.** `newTab(…, unread:)`, `moveNodes(toSpace:markUnread:)` (§2.3).

**Verification.** `sidebar-render check` UB1–UB5 (`--unread today:0`); e2e
E13.

### 3.9 Back to Pinned URL and Separate From Pinned Tab (gap 31)

**Interaction.** On a pinned row with the "/" mark (`hasLeftPinnedURL`),
hovering the favicon slot swaps the favicon for a reset plate
(`SpaceListMetrics.resetGlyphPlate`, glyph `arrow.uturn.backward` 11 pt
Semibold, `SidebarRole.rowAccessory`; plate `SidebarRole.rowPressed` while the
pointer is on it). Tooltip "Back to Pinned URL"; click → `.resetToPinnedURL`
(exists). While ⌥ is held (**guess**, Q10) the glyph is `arrow.up.forward.square`
and the tooltip "Separate From Pinned Tab"; click → `.separateFromPinned`.
`flagsChanged` updates the plate while hovered. Facts: SC §5 (`canResetTab`,
`resetTabTitle`, `resetTabIcon`).

**App.** `separateFromPinned`: take the pinned tab's live host H (if any);
call `model.separateFromPinnedTab(id:)` → new tab T; rebind H to T
(`WebContentHost.rebind(to:)` and `WebContentContainer.rekey(from:to:)`, new);
mark the pinned tab unloaded; select T. T shows the same page with its
history. If the host cannot rebind, close H and let T load its URL (log it).

**Motion.** Plate swap 0.08 s fade. T inserts with the 0.22 s row animation.

**Verification.** `sidebar-render check` SP1–SP4; `features-render check`
SP5–SP6 (rekey keeps the host object); `openkit commands-demo` B14; e2e E14.

### 3.10 Clear unselected Today tabs (gap 31)

**Interaction.** The Today divider's "Clear" control gets a tooltip (the
existing capsule tooltip, 0.6 s): "Clear Today tabs" with keycaps ⇧⌘K
(**guess** for the keycaps). While ⌥ is held over the control, the tooltip
reads "Clear unselected Today tabs" and the label stays "↓ Clear"
(**guess**). Click with ⌥ → `.clearTodayKeeping(space, keep: current node ∪
selection)`. The Today tab menu's "Archive Item" gains a ⌥ alternate "Archive
Other Tabs" (`NSMenuItem.isAlternate`, modifier ⌥) → `.clearTodayKeeping(space,
keep: that tab ∪ selection)`. Every Clear shows the toast "Cleared Tabs" with
Undo.

**Model.** `clearToday(space:keeping:)` (§2.3).

**Verification.** `sidebar-render check` CU1–CU5; e2e E15. The divider at rest
and with "Clear" must still match F0041 / F0066 (§5.5).

### 3.11 Auto-archive education banner (gap 31)

**When.** The App's auto-archive sweep (status gap 4; not this plan) returns
the archived entries. When at least one archived tab belonged to a Space
shown in a window, `open.sidebar.autoArchiveBannerEligible` is true, and
`open.sidebar.autoArchiveBannerDismissed` is false, every window shows the
banner (Arc shows it "when tabs auto archive", SC §10). It hides in all
windows on "Got it" or on the Settings link, and the dismissed key becomes
true.

**Visuals** (**guess**, §8.2 C6). `SidebarBannerView` (OpenSidebar) sits above
the bottom bar: frame `[8, H − 50 − 8 − h, W − 16, h]`. The tab list's bottom
content inset grows by `h + 8`, so no row hides under it. Card radius 10
continuous, fill = the Space's selected-row fill with the selection shadow.
Padding 12. Title "We cleaned up!" 13 Semibold, title color. Message 12
Regular, `SidebarRole.secondaryText`, line height 15; "Settings" is a link in
the Space accent, underlined on hover; it sends `.openProfileSettings(space
profile)`. "Got it" button: 12 Medium, `GrayA4` capsule, 24 pt tall,
trailing-aligned, sends `.dismissAutoArchiveBanner`. The threshold text comes
from the Profile setting: "1 hour", "6 hours", "12 hours", "24 hours", "7
days", "30 days" (Q12). At width 228 the card is about 106 pt tall.

**Motion.** In: slide up 12 pt + fade, 0.22 s ease-out, the inset animates
with it. Out: fade + slide down 0.18 s.

**Verification.** `sidebar-render render --banner auto-archive`; checks BN1–BN4;
e2e E16 (automation `archive-sweep now=<date>` drives the real sweep path).

### 3.12 First-hide hint (gap 31)

**When.** The first time the sidebar hides by the toolbar toggle button or by
the gesture (§3.16) while `open.sidebar.hideHintShown` is false. Set the key
when the hint shows. A hide by Cmd+S or the menu sets the key without showing
the hint (the user knows the shortcut; **guess**, Q13).

**Visuals** (measured on A0440, SC §10; `OpenFeatures/HintToastView.swift`,
tokens in `OpenDesign/HintToastTokens.swift`):

| Part | Value |
|---|---|
| Frame | top-right of the window: x = W − 5 − w, y = 4, height 47; w = 12 + text₁ + 8 + plate + 6 + text₂ + 14 (399 at the measured text) |
| Shape | continuous corner, radius 10 |
| Fill | vertical gradient top `#442B68` → bottom `#332350` in the default dark theme; other themes: the theme's tooltip fill lightened 6 % (top) and darkened 6 % (bottom) in OKLab L (**guess**) |
| Rim | 1 px, black a 0.20 (fits `#2A1B40` over the fill; **fitted**) |
| Shadow | black a 0.10, radius 8, y +2 (**fitted** to ≈ 8 % at the edge) |
| Text | SF Pro 14 Medium, white a 0.95; "You can use" starts at x + 12, baseline y + 28 |
| Keycap | plate at (12 + text₁ + 8, 10), 27 tall, width = keycap ink + 18 (37 for "⌘S"), radius 6, white a 0.10; "⌘S" 14 Medium white, centered. The keys come from the live binding of `toggle-sidebar` (user overrides apply). |
| Layer | above the web panel; ignores mouse events (**guess**) |

**Motion.** In: scale 0.9 → 1.0 and alpha 0 → 1, 0.2 s ease-out (IS §16
"scale-up", **guess** duration). It stays 5.5 s (measured 5–6 s), then fades
out in 0.25 s. A sidebar show during the hint does not hide it.

**Verification.** `features-render check` HT1–HT3; `features-render compare
--spec hint-toast` against A0440 (§5.5); e2e E17.

### 3.13 Haptics and sound effects (gap 32)

**Haptics** (`OpenSidebar/SidebarHaptics.swift`).
`NSHapticFeedbackManager.defaultPerformer.perform(_:performanceTime: .now)`,
only when `open.advanced.hapticOnTabReorder` is true (read at use). Events:

| Event | Pattern |
|---|---|
| A sidebar drag's insertion point (parent, index) changes in the outline, Favorites, or the Space Manager | `.alignment` (**guess**) |
| A sidebar node drop succeeds (outline, folder, Favorites, switcher icon, Space Manager column) | `.generic` (fact: Arc fires a drop haptic; pattern **guess**) |
| A Space swipe crosses the commit threshold (once per crossing) | `.levelChange` (fact: page detent haptics exist; pattern **guess**) |
| Switcher or Space Manager reorder slot change | `.alignment` (**guess**) |

`SidebarDiagnostics.haptics[pattern]` counts calls for the checks.

**Sounds** (`OpenFeatures/SoundEffects.swift`, resources in
`OpenFeatures/Resources/Sounds/`). Open's two sounds are made by our script
`tools/generate-sounds.py` (Python `wave` module only, fixed seed, SHA-256 of
each output pinned in the script), then converted with `afconvert -f caff -d
LEI16@48000`:

| File | Content |
|---|---|
| `open-capture.caf` | 0.45 s: two filtered noise clicks 30 ms apart plus a 2 kHz sine blip of 40 ms; peak −6 dBFS |
| `open-event.caf` | 1.1 s: two-note chime, 1046.5 Hz then 1568 Hz 300 ms later, 5 ms attack, exponential decay τ 0.25 s; peak −8 dBFS |

`SoundEffects.shared.play(.capture | .event)` loads an `AVAudioPlayer` on
first use (never at launch) and plays only when `open.advanced.playSoundEffects`
is true. Callers in v1: none in the sidebar. `.capture` is for the Capture
tool (status gap 13). `.event` waits for evidence of its trigger (Q6). Add a
row "Open-generated sounds (own work)" to `docs/release/licenses.md`.

**Verification.** `sidebar-render check` HG1–HG4 (counter values; zero calls
with the setting off); `features-render check` SE1–SE2 (both files load,
duration and peak level within 5 % of the table; no play when the setting is
off). Haptic feel cannot be captured.

### 3.14 Change Icon… for folders and pinned tabs (gap 33)

Owned by `docs/plans/space-theme-editor.md` Step 1 (`iconOverride`,
`setNodeIcon`, draw precedence) and Step 6 (picker, `changeIcon` wiring). This
plan adds no code for it. It adds checks that the override shows in the new
surfaces: the folder preview header (HP3), the Space Manager column header
(SM2), and the separated tab (B14 keeps no icon override; the pinned tab keeps
its own). The selection menu has no Change Icon… item.

### 3.15 Archive a whole folder; restore it as a folder (gap 34)

**Interaction.** Folder menu: "Archive Folder" directly above "Delete" (Open
choice, Q1; Arc puts it in Delete's slot behind a flag). Selection of folders
only: "Archive Folders" above "Delete". No confirmation (it is restorable).
Cmd+Z undoes.

**Model.** `archiveFolder(id:)`: detach the subtree (one `.remove`), call the
new `ArchiveSink.archiveFolder(_ entry: ArchiveFolderEntry)` (default method
does nothing), and register undo (reattach at the old slot and
`discardArchived(ids: [folderID])`). `ArchiveFolderEntry { folder: Folder,
originalLocation: String, spaceID: SpaceID?, profileID: ProfileID?,
archivedAt: Date }`.

**Store.** `ArchiveStore.archiveFolder` copies the subtree into DTO values on
the main actor, then writes one row on its queue: `id` = folder ID, `url` =
`about:blank`, `title` = folder title, `reason` = `closed`, `kind` = `folder`,
`original_location`, `payload` = JSON of `{ "kind": "folder", "id", "title",
"isExpanded", "customIcon", "iconOverride", "children": [NodeDTO] }` (the
`FolderDTO` keys plus `kind`). `ProfileArchiveSink` routes it by Profile.
Auto-archive, Clear, and Delete never write folder rows.

**Restore.** Library ▸ Archive: a folder row shows the `folder` symbol and
"Folder · <N> tabs" (N counts tabs at any depth). Restore →
`ArchiveStore.restore(id:)` → `model.restoreArchivedFolder(record)`: rebuild
the subtree with its original IDs from the payload (OpenModel decodes it with
a private mirror of the `NodeDTO` keys; read `OpenStore/SnapshotDTOs.swift`
first and keep both in sync). Any child whose ID is already live is skipped.
Destination: index 0 of the original parent if it exists; else the top of the
same section (Pinned or Today) of the original Space; else the top of the
focused Space's Today. Pinned-URL rule per tab; `lastActiveAt = now`. One undo
step sends it back as a folder row. The Library status reads "Folder restored
to <Space>. Click to view." with View.

**Verification.** `openkit commands-demo` FA1–FA7; `settings-preview check`
L2–L3; e2e E18.

### 3.16 Hide the sidebar with the gesture (gap 36)

Arc's gesture is the sidebar resize pan, not a trackpad swipe (SC §10).
PR #52 already hides the sidebar when a drag ends below 180 pt. Add the live
preview Arc shows (A0422):

- Let `x` be the dragged edge position in window points. While `x` is below
  the 228 pt minimum, the sidebar width stays 228 and the whole sidebar slides
  left by `o = x − 228` (clamped to `[−228, 0]`); the
  web panel's left edge follows (`max(10, 228 + o)`). No model write per tick.
- Release with `x < 180`: the slide finishes in 0.22 s, `sidebarMode =
  .hidden`, and the window controller sends `.sidebarHiddenByGesture`
  (triggers §3.12). Release at 180 or more: spring back to 228
  (`Motion.sidebarToggle`).
- Under Reduce Motion: no slide; the release decides.

**Verification.** `features-render check` GH1–GH4 (synthesized drags through
the real resize handle); e2e E19 (extends the `window` suite).

## 4. Harness and automation additions

### 4.1 `sidebar-render`

New `render` flags: `--multi-select ROW,ROW…` (row specs as for `--select`),
`--unread ROW,…`, `--banner auto-archive`, `--option-held`,
`--hover-favicon ROW`, `--preview folder:N`. New subcommand `space-manager
--snapshot DIR|--synthetic --out FILE.png [--size WxH]`. New bench modes
`--selection`, `--bulk 50`, `--expand-all 50`. All new checks live in a new
file `Sources/sidebar-render/CompletionChecks.swift`, called from `Checks.run`.

### 4.2 `features-render`

New scenes `hint-toast`, `alert`, `preview`, `gesture-hide`; new spec
`compare --spec hint-toast`. New checks in
`Sources/features-render/CompletionChecks.swift`; add the file to the target's
explicit `sources` list in `Package.swift`. Add `features-render` to
`tools/verify-all.sh` `NAMES` (it is not there yet). `sidebar-render` has no
`sources` list, so lane S never edits `Package.swift`.

### 4.3 `openkit commands-demo`

New checks B1–B14, T1–T3, FA1–FA7 in the existing demo, on the real
`ArchiveStore`. Each prints OK or FAIL and the events it saw.

### 4.4 App automation (`App/Automation/AutomationController.swift`)

| Command | Arguments | Effect |
|---|---|---|
| `sidebar-click` | `node`, `modifiers` (`cmd`, `shift`, `option`) | Sends a real mouse-down/up `NSEvent` pair at the row's center through `NSApplication.sendEvent` (window events only, never the desktop) |
| `sidebar-key` | `key`, `modifiers` | Makes the outline first responder, then sends a real key event |
| `selection` | — | The window's selection IDs in order |
| `sidebar-menu` | `node`, `item` (title path, e.g. `Move to/Space 2`), `alternate` | Builds the same `NSMenu` the right-click shows and performs the item |
| `alert` | `button` (title) | Presses a button of the window's attached alert sheet |
| `hover` | `node` or `favorite`, `ms` | Sends real `mouseMoved` events over the target for `ms` |
| `preview-state` | — | Shown kind, target ID, host object ID |
| `library-open` | `section` | Opens the Library at a section |
| `space-manager-drag` | `space`, `to` | Drives the grabber through real mouse events |
| `archive-sweep` | `now` (ISO date) | Runs the App's sweep path with that date |
| `defaults` | `key` | Reads a `UserDefaults` value |

### 4.5 e2e suite `sidebar-completion`

`tools/e2e/engine_e2e.py --only sidebar-completion` (add the choice). Fresh
data dir, socket only, no desktop input. Checks E1–E19 in §5.4. Results go to
`docs/engine-spike/results-sidebar-completion-*.json`.

## 5. Checks

### 5.1 `sidebar-render check` (offscreen, real views and model)

| ID | Check |
|---|---|
| MS1 | Cmd-click on a Today row with a pinned row current: selection = {current, clicked}; model selection unchanged; only those 2 rows lay out (`tabRowLayouts` delta ≤ 2) |
| MS2 | Shift-click from a pinned row to the 3rd Today row selects the visible rows between them in display order and skips spacer, divider, and New Tab |
| MS3 | Rows inside a collapsed folder are not selected by Shift-click; collapsing a folder prunes its selected children |
| MS4 | Plain click clears the selection and selects the row (model) |
| MS5 | Shift+Down ×3 from the focus row selects 4 rows; Esc clears; Up without Shift clears |
| MS6 | Selected rows draw `rowMultiselected` (ΔE00 ≤ 0.5 against the composited token, light and dark) in the hover-fill rect (0 pt); the current row keeps its fill and shadow |
| MS7 | Selection menu item order and titles for tabs only, and for a mixed selection (§3.1) |
| MS8 | "New Folder with 3 Items": one `.insert` + 3 `.move`; the folder sits at the first item's slot; inline rename starts; one undo step restores everything; `fullReloads` unchanged |
| MS9 | "Archive Items" on 3 tabs: 3 `.remove`, one sink call, rows match the model; undo |
| MS10 | Move to ▸ Space 2 with 3 rows: 3 `.move`, order kept, tops of the matching sections |
| MS11 | Cmd+D with a mixed pinned/Today selection pins all; again unpins all |
| MS12 | Drag of a 3-row selection: the pasteboard holds 3 items in display order; the drop moves all 3 with one undo step; a refused node (split pane) is skipped |
| MS13 | Space switch clears the selection |
| MS14 | 1,000-row bench: toggle p95 ≤ 1 ms; bulk move of 50 ≤ 16 ms p95 |
| SM1 | `space-manager` scene: one column per Space in order; column frames per §3.2 |
| SM2 | Column header shows the Space icon (emoji, named icon, or symbol), the title, and the Profile chip only with 2+ Profiles |
| SM3 | Grabber drag of column 1 past column 2 calls `moveSpace(id:to: 1)` once; Esc cancels with no model change |
| SM4 | A tab dragged from column 1 into column 2 moves to that Space (one `.move`) |
| SM5 | "…" menu items and enabled state ("Delete" disabled with one Space) |
| SM6 | Building 10 columns × 100 rows ≤ 120 ms; no `reloadData` after the build |
| SW1 | Switcher: press + 4 pt move enters reorder; a click without it switches Spaces |
| SW2 | Reorder 3 → 1 commits `moveSpace` once; items and pager pages reorder without rebuilding pages |
| SW3 | Esc and a 41 pt vertical move cancel |
| SW4 | A tab drop on a Space icon still moves the tab (no regression) |
| EA1 | Expand All opens every folder at every depth; rows match the model |
| EA2 | Collapse All closes them; one undo step reopens all |
| EA3 | Same-value Expand All registers no undo |
| EA4 | 50 folders × 10 rows: the pass ≤ 16 ms |
| TF1 | Export “Space 2” into Folder ▸ Space 1: menu title with curly quotes (D-8) |
| TF2 | Space 1 page shows the new folder at the top of Pinned with Space 2's rows inside; the switcher loses Space 2 |
| TF3 | Undo restores Space 2, its rows, and the window focus |
| HP1 | Folder, pinned row, and Favorite tile send `.hoverPreview` after 0.5 s ± 50 ms; Today rows and the current row never do |
| HP2 | With `open.general.previewsEnabled` false the tracker installs no work (no timer scheduled) |
| HP3 | Folder card layout (§3.6) at 228 and 500 widths; the header shows the folder's `iconOverride` when set (theme plan Step 1), else the folder glyph |
| HP4 | Moving to another target within 1.0 s after a preview hid swaps at once |
| HP5 | Menu open, drag start, and Space switch hide the preview |
| HP6 | Row tooltips do not schedule while a preview is armed |
| TT1 | A row with a Gmail fixture title draws "Inbox (3)" |
| TT2 | A title change redraws only its row |
| UB1 | `--unread today:0` draws the dot at `(W − 26, y + 20)`, 6 pt |
| UB2 | Hover hides the dot; the close button shows |
| UB3 | A real click selects the row and clears the dot; only that row lays out |
| UB4 | A collapsed folder with an unread child shows the dot; expanding moves it to the child |
| UB5 | Peek badge wins over the dot |
| SP1 | Hover on a navigated pinned row's favicon shows the reset plate and the tooltip "Back to Pinned URL" |
| SP2 | ⌥ held swaps glyph and tooltip to "Separate From Pinned Tab" |
| SP3 | Click sends `.resetToPinnedURL`; ⌥-click sends `.separateFromPinned` |
| SP4 | A pinned row without the "/" mark shows no plate |
| CU1 | "Clear" tooltip text without and with ⌥ |
| CU2 | ⌥-click keeps the current Today tab and the selection; archives the rest with one `.reload` |
| CU3 | "Archive Other Tabs" is a ⌥ alternate of "Archive Item" in the Today tab menu |
| CU4 | One undo step brings every archived row back |
| CU5 | The divider renders byte-identical to the pre-change build at rest and with "Clear" |
| BN1 | Banner frame and text layout at widths 228 and 500; the list inset grows by `h + 8` |
| BN2 | "Settings" link sends `.openProfileSettings`; "Got it" sends `.dismissAutoArchiveBanner` |
| BN3 | Threshold text follows the Profile setting |
| BN4 | No banner when dismissed or not eligible |
| HG1 | One drag with 3 insertion-point changes and a drop: `.alignment` ×3, `.generic` ×1 |
| HG2 | A Space swipe past the threshold: `.levelChange` ×1; a short swipe: 0 |
| HG3 | Setting off: 0 calls |
| HG4 | Switcher reorder across 2 slots: `.alignment` ×2 |

### 5.2 `features-render check`

| ID | Check |
|---|---|
| DA1 | Delete Space shows a sheet with the §2.6 title (display title for an untitled Space), text, and buttons in order |
| DA2 | "Cancel": no model change, no undo step |
| DA3 | "Delete": the Space is gone; one undo step restores it |
| DA4 | Folder alert: title with the folder name; "Are you sure?" for an empty title; "Delete Folder" archives the tabs and shows "Folder deleted" with Undo |
| DA5 | Two folders: one alert, "Folders deleted" |
| HP7 | Page preview of a pinned tab with a cached hidden host reuses that host object (no `makeHost` call) |
| HP8 | Without a cached host, exactly one `makeHost(tabID: tab.id …)` call; dismiss adopts it into the container cache |
| HP9 | Selecting the previewed tab shows the same host object (no reload in the fake host's log) |
| HP10 | Card frame per §3.6, clamped at the window bottom |
| SP5 | `separateFromPinned` rekeys the live host to the new tab ID; the pinned tab has no host |
| SP6 | A host without rebind support closes; the new tab loads its URL |
| HT1 | Hint shows on the first toggle-button hide only; the key becomes true |
| HT2 | Cmd+S as the first hide sets the key and shows nothing |
| HT3 | Lifetime 5.5 s then 0.25 s fade (driven by the forced animation clock) |
| GH1 | Drag below 228: sidebar offset follows `x − 228`; width stays 228; no model write |
| GH2 | Release at 170: hidden, `.sidebarHiddenByGesture` sent once |
| GH3 | Release at 200: springs back, still anchored |
| GH4 | Reduce Motion: no slide frames |
| SE1 | Both sound files load; duration and peak within 5 % of §3.13 |
| SE2 | `play` does nothing when the setting is off |

### 5.3 `openkit commands-demo` and `settings-preview check`

| ID | Check |
|---|---|
| B1 | `moveNodes` of 3 nodes into a folder: 3 `.move` in order; undo restores order and exact `pinnedURL`s; redo repeats |
| B2 | `moveNodes` skips a split pane and a node whose ancestor folder is also moved |
| B3 | Same-parent `moveNodes` with `at` below the moved nodes lands where the drop asked |
| B4 | `archiveNodes`: tabs `closed`, folders `folderDeleted`; one sink call; undo discards the rows |
| B5 | `createFolder(in:at:withNodes:)` places the folder at `at` |
| B6 | `setPinned` both ways; Favorites and folders skipped |
| B7 | `duplicateNodes` for a tab, a pinned tab (keeps `pinnedURL`), a split, and a folder (deep, new IDs); undo removes the copies |
| B8 | Refused bulk commands send no event and register no undo |
| B9 | `setAllFoldersExpanded` counts and undo |
| B10 | `resetPinnedTabs` returns only navigated pinned tabs (folders and splits included, Favorites excluded) |
| B11 | `turnSpaceIntoFolder` builds the folder (Pinned then Today order), removes the Space, moves window focus |
| B12 | Its undo restores the Space slot, lists, `pinnedURL`s (Today tabs back to nil), and focus |
| B13 | Refusals: same Space, last Space, missing destination |
| B14 | `separateFromPinnedTab` creates the Today tab at index 0 and resets the pinned URL; undo |
| T1 | 40 fixture pairs give the expected tidy titles |
| T2 | No-match and empty-result cases return the raw title |
| T3 | 10,000 cached lookups p95 ≤ 5 µs; 1,000 misses p95 ≤ 50 µs |
| FA1 | `archiveFolder` writes one row with `kind = folder`; the tab rows are not written |
| FA2 | `restoreArchivedFolder` rebuilds nested folders and a split with the original IDs and order |
| FA3 | Restore falls back to the section top, then to the focused Space Today, when parents are gone |
| FA4 | A child already live is skipped |
| FA5 | Undo of restore writes the folder row back; undo of archive drops it |
| FA6 | The store migrates a pre-change archive file (adds `kind`, keeps every row) |
| FA7 | A round trip through snapshot save and load does not change archived rows |
| L1 | `settings-preview`: the Library Spaces section hosts the injected view (preview injects a labeled stand-in) |
| L2 | Folder rows show "Folder · N tabs" with N counted at any depth |
| L3 | Folder restore status text and View action |

### 5.4 e2e `sidebar-completion` (real app; after app-shell Steps B and C)

| ID | Check |
|---|---|
| E1 | `sidebar-click` with `cmd` and `shift` builds the expected `selection` |
| E2 | `sidebar-menu item="New Folder with 3 Items"` → `tabs` shows the folder with the 3 tabs; Cmd+Z (`key route=app`) undoes |
| E3 | Cmd+D on a selection pins all; `tabs` sections change; engine pin flags follow (P1 bridge when present) |
| E4 | Drag of a selection through the production drop intent; order kept |
| E5 | `manage-spaces` opens the Library on Spaces (`snapshot window=library`) |
| E6 | `space-manager-drag` reorders; `spaces` order and the switcher change; relaunch keeps it |
| E7 | Delete Space: `alert button=Cancel` changes nothing; `alert button=Delete` archives (`archive-list` count grows) |
| E8 | Delete folder: alert copy; toast "Folder deleted"; Undo restores |
| E9 | `command id=expand-all-folders` then `collapse-all-folders`; `reset-all-tabs-in-space` navigates a live pinned page back (`pages` URL) |
| E10 | Export a Space into a folder; `spaces` count −1; Cmd+Z restores |
| E11 | `hover` a pinned row 600 ms → `preview-state` page with the tab's host; move away → hidden |
| E12 | Set `window.__peekProbe = 1` in the preview with `eval`; select the tab; the value is still 1 (no reload) |
| E13 | A background tab (command bar open with Cmd) shows `isUnread` in `tabs`; select clears it |
| E14 | Separate From Pinned Tab keeps a JavaScript global on the new Today tab; the pinned tab URL equals its pinned URL |
| E15 | ⌥-Clear keeps the current tab and archives the rest |
| E16 | `archive-sweep` with a date 13 h ahead archives a Today tab and shows the banner; "Got it" hides it; relaunch keeps it hidden |
| E17 | First hide by the toolbar button shows the hint; `defaults key=open.sidebar.hideHintShown` is true; a second hide shows nothing |
| E18 | Archive Folder → Library restore → the folder returns with its tabs and IDs |
| E19 | Drag the resize handle to 150 pt and release: hidden; the hint shows (if not shown before) |

### 5.5 Comparisons with Arc captures

Method: `docs/design.md` §7 (1x, same window size and sidebar width, masks,
sRGB through the embedded profile). Targets: position ≤ 1 pt, ΔE00 ≤ 2.
Captures stay in `.re/` and are never committed or cropped into the repo.

| State | Capture | Elements | Tool |
|---|---|---|---|
| First-hide hint | A0440 (anim session, window 2216 × 1394, sidebar hidden) | toast frame, fill at y + 2 and y + 43, text ink boxes (both halves), keycap plate frame and fill, keycap ink | `features-render compare --spec hint-toast` |
| Gesture slide-out | A0422 | motion only: sidebar slides, no width change below 228 | `features-render render --scene gesture-hide --at` (visual check, no numeric target) |
| Divider with "Clear" | F0041, F0066 | unchanged (CU5) | `sidebar-render compare` |
| Menus | F0115, F0116, F0117, F0119 | single-row menu order unchanged; curly quotes in F0117 and F0119 titles | `sidebar-render check` (menu dumps) |
| 13 baseline states | `docs/design.md` §15.1 | every state within its recorded worst values; report tidy-title text changes | `.re/vf/run-states.sh` |

Every other new surface has no capture. Its checks are geometry and token
checks, and §8.2 lists the capture that would calibrate it.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Mirroring the selection into `selectedRowIndexes` lets AppKit draw or change selection. | `selectionHighlightStyle = .none` and `shouldSelectItem → false` stay; the page sets the indexes only from `SidebarSelection`; MS12 proves the multi-row pasteboard. If AppKit still interferes, write all IDs from `pasteboardWriterForItem` of the clicked row instead (the drop side already reads many items). |
| Reparenting a live host into the preview card reloads it in stock CEF. | E12 detects it. Fallback: show a fresh host for previews only, and close it on dismiss (costs a load per preview). |
| Many folder previews or page previews cost memory. | One preview host at most; it joins the hidden LRU of 8 and the sleep policy. |
| Tidy titles change the baseline comparison titles. | Report per state; titles are user data, so the comparison masks text that differs from the capture (as the M4 re-derived script already does). |
| The folder archive payload drifts from `NodeDTO`. | FA2 and FA7 round-trip through the real store and snapshot code. |
| Expand All animates hundreds of rows. | One animation group; EA4 budget. |
| The theme plan's Step 1 is not landed when M1 starts. | `duplicateNodes` copies `iconOverride` only if the field exists; add it when Step 1 lands (one line). |

## 7. Implementation order

Two implementers work in parallel. **Implementer M** owns the model, store,
Settings, CLI, and later the App lane. **Implementer S** owns the sidebar
views, tokens, and the sidebar harness. Each step is one PR. Before each PR:
merge `origin/main`, run `tools/verify-all.sh`, paste its summary (`AGENTS.md`
rule 10). Build: `nice -n 10 swift build -c release -j 6` in
`Packages/OpenKit`.

File ownership (no file is edited by both lanes):

| Lane | Files |
|---|---|
| M | `OpenModel/BrowserModel.swift`, `OpenModel/TidyTitles.swift` (new), `OpenModel/LiveNodes.swift`, `OpenStore/ArchiveStore.swift`, `OpenStore/ProfileArchiveSink.swift`, `OpenSettings/*`, `Sources/openkit/*`, `Sources/settings-preview/*`, `tools/generate-sounds.py` (new), `OpenFeatures/SoundEffects.swift` + `Resources/Sounds/*` (new), `Package.swift`, `docs/model.md`, `docs/release/licenses.md` |
| S | `OpenSidebar/*`, `OpenDesign/Metrics.swift`, `Palette.swift`, `Motion.swift`, `Sources/sidebar-render/*`, `docs/design.md` |
| A (Implementer M, after its M steps) | `OpenFeatures/*` except `SoundEffects.swift`, `OpenDesign/HintToastTokens.swift` (new), `Sources/features-render/*`, `App/*`, `tools/e2e/engine_e2e.py`, `tools/verify-all.sh`, `docs/app-shell.md` |

| Step | Lane | Work | Needs | Acceptance |
|---|---|---|---|---|
| M1 | M | Bulk and Space commands of §2.3 (all but folder archive), `newTab(unread:)`, `moveNodes(toSpace:markUnread:)` | — | B1–B14 PASS; `commands-demo` all PASS; `roundtrip` PASS; `openkit bench` move numbers within 10 % |
| S1 | S | `SidebarSelection`, row selection state and fill, Cmd/Shift-click, Shift+Arrow, Esc, pruning; tokens §2.7 (selection); `--multi-select` | — | MS1–MS6, MS13, MS14 (toggle part) PASS; 13 baseline states unchanged |
| M2 | M | Folder archive: `ArchiveSink.archiveFolder`, `kind` column and migration, `archiveFolder`, `restoreArchivedFolder`, Library folder rows and restore text | M1 | FA1–FA7, L2, L3 PASS |
| S2 | S | Selection menus, drag of a selection, new intents and `ModelSidebarActions` mapping, Cmd+D/Delete/Duplicate on selection, ⌥ Clear and "Archive Other Tabs", curly quotes, "Archive Folder" items, `exportSpaceIntoFolder` mapping | M1, M2 | MS7–MS12, MS14, CU1–CU5, TF1–TF3 PASS |
| M3 | M | Tidy titles and `displayTitle` | — | T1–T3 PASS; `suggest-check` unchanged |
| S3 | S | Unread dot; reset / separate plate; Expand/Collapse All sync; tidy-title row checks | M1, M3 | UB1–UB5, SP1–SP4, EA1–EA4, TT1–TT2 PASS |
| M4 | M | Sounds: generator, assets, `SoundEffects`, license row; Settings keys of §2.4 registered | — | SE1–SE2 PASS in `features-render check` |
| S4 | S | Space switcher reorder; `SpaceManagerView` and `SpaceControlsView`; `SidebarHaptics` and its call sites | M1 | SW1–SW4, SM1–SM6, HG1–HG4 PASS |
| M5 | M | Library `.spaces` section that hosts an injected view (`SettingsActions.makeSpaceManagerView() -> NSView?`) | — | L1 PASS |
| S5 | S | `HoverPreviewTracker`, `FolderPreviewView`, `SidebarBannerView` | M3 | HP1–HP6, BN1–BN4 PASS |
| A1 | A | OpenFeatures intents: alerts, toasts, Clear toast, Expand/Reset/Space Manager commands, `HintToastView`, gesture-hide preview; add `features-render` to `verify-all.sh` | app-shell Step B (PR #52) merged; S2 | DA1–DA5, HT1–HT3, GH1–GH4 PASS; hint compare within §5.5 targets |
| A2 | A | `HoverPreviewController` (host reuse), host `rebind` / `rekey`, separate flow, banner trigger from the sweep, unread triggers | A1, S3, S5 | HP7–HP10, SP5–SP6 PASS |
| A3 | A | App: menu and command handlers (§2.5) once app-shell Step C lands, Library Spaces wiring, automation commands (§4.4), e2e suite | A2, M5, app-shell Step C | E1–E19 PASS on the real app; `tools/verify-all.sh` all PASS |
| C | S | Calibration after the §8.2 capture session: replace guessed values with measured ones, each citing its frame | captures | each changed value meets ≤ 1 pt / ΔE00 ≤ 2 on its capture |

Parallel schedule: M1 ‖ S1 → M2 ‖ (S2 waits for M2) → M3 ‖ S2 → M4 ‖ S3 →
M5 ‖ S4 → A1 ‖ S5 → A2 → A3, then C when captures exist. Lanes never edit the
same file. Each lane records its results in its own doc (`docs/model.md`,
`docs/design.md`, `docs/app-shell.md`) and in the PR. Neither lane edits this file.

## 8. Open questions and capture requests

### 8.1 Questions (the recommendation ships until the lead decides)

| # | Question | Recommendation |
|---|---|---|
| Q1 | Folder menu: Arc shows "Delete" (flag off, captured) or "Archive Folder" in the same slot (flag on, code). | Show both: "Archive Folder" above "Delete". Both v1 features stay one click away; the captured items keep their order. |
| Q2 | Pinned and Favorite previews: Arc shows site-specific glance views (mail, calendar, recent pages). | Ship the live page preview through the tab's own host (D-6). Glance views need site APIs and are not v1. |
| Q3 | The Settings Previews sheet has "Show previews when hovering links" and a delay, which do not exist in Arc. Arc's sheet lists sources ("Show Arc Previews:"). | Change the sheet to "Show Open Previews:" with two switches, "Folders" and "Pinned tabs and Favorites" (keys `open.general.previewsFolders`, `open.general.previewsPages`, default true), and keep the delay pop-up. Until then the master switch and the delay apply. |
| Q4 | Space Manager: Library section or its own window. | Library section (SC §2 evidence). |
| Q5 | Drag to reorder in the bottom switcher (Arc's flag is Windows-only). | Ship it; the task asks for it and it does not conflict with any Arc behavior. |
| Q6 | Which events play the generic sound; default of the sound switch (Arc's key polarity means on). | Keep the switch off and no `.event` caller until a capture session (§8.2 C9) names the events; then turn the default on. |
| Q7 | Recorded or generated sounds. | Generated by our script (reproducible, clear license). The user can replace the files later; the code does not change. |
| Q8 | Turn Space into folder: where Today tabs go. | One folder at the top of the destination's Pinned, Pinned children first, then Today children (which become pinned). |
| Q9 | Does the current row join the selection on the first Cmd-click? | Yes. |
| Q10 | Modifier for Separate From Pinned Tab. | ⌥, until C7. |
| Q11 | Unread triggers. | Background-created tabs, plus "Move to" into a Space the window does not show. |
| Q12 | Banner threshold text. | Insert the Profile's threshold ("12 hours" by default, which is Arc's text). |
| Q13 | Hint after a Cmd+S hide. | No hint; mark it shown. |
| Q14 | Key for "Clear unselected". | ⌥, until C8. |
| Q15 | Alert title for several folders. | "Are you sure?" (Arc's own fallback string). |
| Q16 | "Archive Tabs Below / Above". | Defer until C8 shows how Arc reaches them. |

### 8.2 Screenshots needed from the user

Run the recorder from `docs/re/runtime-observations.md` §7 (`capture-loop.sh
-i 1`, and `-i 0.2 -A` for motion). Hold each state 2 s. Use neutral pages.

| # | Label | Steps | Calibrates |
|---|---|---|---|
| C1 | `multiselect` | In a Space with 6+ Today tabs: Cmd-click two rows, then Shift-click a third; right-click a selected row; press Esc. Repeat in a dark Space. Then drag the selection into a folder. | §3.1 fill, menu order, drag look |
| C2 | `space-manager` | Spaces ▸ Manage Spaces…; hover a Space header; drag one Space by its grabber; open its "…" menu. | §3.2 layout |
| C3 | `delete-alerts` | Right-click a folder ▸ Delete, then Cancel; Space menu ▸ Delete Space, then Cancel. | §3.3 (system look; confirms button order) |
| C4 | `previews` | Turn Previews on. Hover a folder, a pinned tab, and a Gmail favorite for 2 s each. | §3.6 size, place, delay |
| C5 | `unread` | Cmd-click a link in a page so a tab opens in the background; then move a tab to another Space with Move to. | §3.8 dot |
| C6 | `banner` | Only if possible: set Archive tabs after to 1 hour on a test Profile, leave a Today tab for an hour. | §3.11 (skip if the banner was already dismissed) |
| C7 | `pinned-reset` | Navigate a pinned tab to another page; hover its favicon; hold ⇧, then ⌥, then ⌘ (one at a time). | §3.9 plate, key |
| C8 | `clear-option` | Hover the Today "Clear" control, then hold ⌥; right-click a Today tab and hold ⌥ with the menu open. | §3.10 |
| C9 | `sounds` | Turn "Play Arc sound effects" on; for 5 minutes use the sidebar normally and say aloud (or note the time) when a sound plays. | §3.13 event mapping |
| C10 | `gesture-hide` | Drag the sidebar edge slowly to the left past its minimum, hold, then release. | §3.16 |

## 9. Verification log

Each lane records its results in its own doc (§7). The lead fills this table with the PR links.

| Step | PR | Result |
|---|---|---|
| M1 | | |
| S1 | | |
| M2 | | |
| S2 | | |
| M3 | | |
| S3 | | |
| M4 | | |
| S4 | | |
| M5 | | |
| S5 | | |
| A1 | | |
| A2 | | |
| A3 | | |
| C | | |

## Appendix — Lead decisions (2026-10-26)

- Approved as the sidebar completion plan. The two lanes run in parallel with separate implementers. App-wiring steps wait for app-shell Step B (#52) and Step C.
- Q1 The folder menu shows **"Delete" only**, as Arc does in the captured build (the Archive Folder flag is off). Delete archives the folder's tabs as one folder record, so restoring it brings back a folder (status gap 34). "Archive Folder" is not shown.
- Q2 Previews of pinned tabs and Favorites show the tab's live page through the Peek host. No site-specific views in v1.
- Q3 The Previews sheet uses Arc's switches ("Folders", "Pinned tabs and Favorites"), not a "hovering links" switch.
- Q4 The Space Manager is a page in the Library window.
- Q5 **No** drag to reorder in the bottom Space switcher. Arc's flag for it is Windows-only. Spaces are reordered in the Space Manager.
- Q6 No event plays the general sound until capture C9 shows which events do. The sound setting stays off until then.
- Q7 Sounds are generated by our own script, never recorded from Arc.
- Q8 Turn Space into Folder puts the Today tabs in one folder at the top of the target's Pinned section.
- Q9 The current tab joins the selection on the first Cmd-click.
- Q10 ⌥ turns "Back to Pinned URL" into "Separate From Pinned Tab".
- Q11 Unread means: opened in the background, or moved with "Move to" into a Space the window isn't showing.
- Q12 The auto-archive banner shows the profile's real threshold.
- Q13 No hint when the first hide was Cmd+S.
- Q14 ⌥ shows "Clear unselected".
- Q15 The alert title for deleting several folders is "Are you sure?".
- Q16 "Archive Tabs Below / Above" is deferred until a capture shows how Arc reaches them.
- Captures C1–C10 go into the user's single combined Arc capture session.
