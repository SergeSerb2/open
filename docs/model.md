# OpenKit model design (M1)

Status: implemented. Package: [OpenKit](../Packages/OpenKit/Package.swift).
No third-party dependencies. SQLite uses the system `SQLite3` module.
No unit tests, per AGENTS.md. All verification is end to end through the `openkit` CLI.

## Modules

| Target | Role |
|---|---|
| `OpenModel` | Live browser model. UI-free, engine-free. |
| `OpenStore` | Persistence: JSON snapshot, SQLite archive, SQLite + FTS5 history. |
| `OpenImport` | Read-only Import from Arc. |
| `openkit` | Dev executable. This is the verification surface. |

## OpenModel

### IDs

`Identifier<Tag>` is UUID-backed, `Codable`, `Hashable`, `Sendable`.
Aliases: `ItemID`, `SpaceID`, `ProfileID`, `WindowID`, `RuleID`.
Arc string IDs (including sentinel IDs) never enter the live model.
The importer maps each Arc ID to a fresh Open ID.

### Live objects

All live objects are `@MainActor @Observable final class`:
`Tab`, `Folder`, `Split`, `Space`, `Profile`, `BrowserWindowState`, and root `BrowserModel`.
A view that reads one object redraws only when that object changes.

`SidebarNode` is an enum: `.tab(Tab)`, `.folder(Folder)`, `.split(Split)`. It exposes `id`.

Persisted `Tab` fields: `id`, `url`, `title`, `customTitle`, `pinnedURL`, `customIcon`, `createdAt`, `lastActiveAt`, `isMuted`, `openerID`, `isUnread`.
`pinnedURL` is set when a tab is pinned or made a favorite.
Runtime-only state lives in `tab.live: TabLiveState`: `isLoading`, `progress`, `isAudible`, `isCrashed`, `canGoBack`, `canGoForward`, `faviconPNG`.
`TabLiveState` is never persisted.

`Folder`: `id`, `title`, `isExpanded`, `children: [SidebarNode]` (any depth).
`Split`: `id`, `orientation` (`.horizontal` / `.vertical`), `fractions`, `panes: [Tab]` (2–4), `focusedPaneID`.

`Space`: `id`, `title`, `icon` (`.emoji` / `.symbol`), `theme: SpaceTheme`, `profileID`, `pinned`, `today`, `isPinnedCollapsed`.
`SpaceTheme` holds mapped light/dark background and foreground colors, gradient stops, and `importedArcThemeJSON: Data?` for the raw Arc theme.

`Profile`: `id`, `name`, `icon`, `favorites: [Tab]` (per profile, as in Arc), `settings`, `dataDirectoryName`.
Settings: `autoArchiveAfter` (`never` / 1h / 6h / 12h / 24h / 7d / 30d, default 12h), `littleOpenAutoArchiveAfter` (default 6h), `searchEngineID`.

`BrowserWindowState`: `id`, `focusedSpaceID`, `selectedNodeBySpace`, `sidebarWidth` (default 228), `sidebarMode` (`.anchored` / `.hidden`), frame (`frameX/Y/Width/Height`), `style` (`.standard` / `.littleOpen`), `stayOnTop`.

Link routing: `RoutingRule { id, match, destination, sourceBundleID? }`. See [routing.md](routing.md) for the evaluator, settings data, CLI, and Phase A verification.
Match: `.hostContains`, `.hostEquals`, `.urlPrefix`.
Destination: `.space(SpaceID)`, `.littleOpen`, `.mostRecentSpace`. A rule can target the most recent Space, as Arc rules do.
`defaultDestination`: `.mostRecentSpace`, `.littleOpen`, `.space(id)`.
The snapshot DTOs stay at `schemaVersion` 1. The `littleArc` → `littleOpen` snapshot change is a **ONE-WAY migration**: new snapshots do not load in builds before this PR. This is acceptable because Open has no released users. Live and DTO routing destinations decode both `littleOpen` and legacy `littleArc`, and encode only `littleOpen`. The window mapper accepts the old style string. Live and DTO profile settings read the new auto-archive key, then the legacy key, then default to 6h. Explicit stored values are preserved. `RoutingRule.sourceBundleID` is optional; old snapshots decode it as nil. The mapper normalizes bundle ids to trimmed lowercase and writes no empty string. Fresh models default to `.littleOpen`; stored defaults are preserved.

### Commands

State changes only through named commands on `BrowserModel`:
`newTab`, `closeTab` (archives via the injected `ArchiveSink`), `pinTab` / `unpinTab`, `addFavorite(tabID:to:at:)` / `removeFavorite(tabID:into:)`, `moveNode(id:to:at:)`, `createFolder(in:title:withNodes:)`, `renameNode`, `setExpanded`, `createSpace` / `updateSpace` / `deleteSpace` / `moveSpace`, `makeSplit(tabIDs:)` / `unsplit` / `removePane`, `resetPinnedTab`, `replacePinnedURL`, `restoreArchivedTab(_:)`, `clearToday(space:)`, `archiveExpiredTabs(now:)`, `focusSpace`, `selectNode`.
Query: `isPinned(tabID:)`.
`moveNode`, `addFavorite`, and `removeFavorite` return `false` when they refuse a move. `makeSplit` and `createFolder` return `nil`. A refused command changes nothing, emits no event, and registers no undo.

#### Placement rules

- Favorites hold tabs only. Folders and splits can never enter Favorites.
- A split lives in a Space's pinned section, in a Space's Today section, or in any folder. It never lives in Favorites. `makeSplit` puts the split in the first tab's slot. It refuses a tab that is a favorite or already a split pane, duplicate IDs, and counts outside 2–4. `moveNode` refuses to move a split into Favorites.
- Split panes move only through split commands (`makeSplit`, `unsplit`, `removePane`, `closeTab`). `moveNode` refuses a pane as source and a split as destination.
- `moveNode` refuses to move a folder into itself or its own descendant. The check walks `parentByID` up from the destination folder.

#### Favorites move, they never copy

- `addFavorite(tabID:to:at:)` moves the same tab (same ID, same object) into the profile's Favorites. It emits one `.move` event and registers undo like `moveNode`. A `nil` `pinnedURL` becomes the current URL.
- `removeFavorite(tabID:into:)` moves the tab to the top of a Space's Today section, which clears `pinnedURL`. The default Space is the focused Space of the first window that shows the favorite's profile. Undo puts the tab back in Favorites with its old `pinnedURL`.
- This follows the review finding on M1: in Arc, adding a tab to Favorites moves that tab. Item 30 of [features-core.md](re/features-core.md) guessed a copy. The move is the rule here.

#### Pinned state comes from ancestry

- A tab counts as pinned when its ancestor chain reaches a Space's pinned section. This includes tabs inside folders and splits there. `isPinned(tabID:)` answers this.
- Pinned and Favorites tabs keep a `pinnedURL`. Today tabs do not.
- A move into pinned ancestry or Favorites sets `pinnedURL` to the current URL when it is `nil`.
- A move from pinned ancestry or Favorites into Today ancestry clears `pinnedURL`.
- The rule applies to every tab inside a moved folder or split. `makeSplit` and `createFolder` apply it to each tab they move.
- Undo restores the exact old `pinnedURL` values, even if the tab navigated after the move.

#### Archive and restore

- `closeTab` archives. On a folder it archives every tab inside, with reason `folderDeleted`. On a split pane it archives that pane. A split left with one pane collapses: the remaining tab takes the split's slot.
- `deleteSpace` keeps at least one Space. It archives the Space's tabs and moves window focus to the first remaining Space.
- `clearToday(space:)` archives every Today node of the Space in one pass.
- `archiveExpiredTabs(now:)` uses the Space profile's `autoArchiveAfter` and the tab's `lastActiveAt`. It checks Today tabs, split panes in Today, and tabs inside Today folders, at any depth. Pinned tabs and favorites never expire. A split left with fewer than 2 panes dissolves.
- Every archive entry stores the tab's direct parent as `originalLocation` (`pinned:<uuid>`, `today:<uuid>`, `folder:<uuid>`, `favorites:<uuid>`, `split:<uuid>`; see `NodeParent.archiveLocation`), plus the owning Space and profile.
- `restoreArchivedTab(_ record:)` rebuilds the tab from the record payload with its original ID. It places the tab, in this order: at the top of the original parent if that parent still exists (a split only while it has fewer than 4 panes); else at the top of the original Space's Today section; else at the top of the focused Space's Today section. The pinned-URL rule applies for the destination. The tab gets `lastActiveAt = now`, so auto-archive does not take it again at once. A record whose ID is already in the sidebar returns that tab unchanged. Undo sends the tab back to the archive.
- `ArchivedTabRecord` lives in OpenModel, so the model does not depend on OpenStore.
- `ArchiveSink` has two calls: `archive(_ entries: [ArchiveEntry])` and `discardArchived(ids:)`. A bulk command makes one `archive` call for all of its tabs. When a tab comes back to the sidebar (restore, or undo of a close, clear, or Space delete), the model calls `discardArchived`. So a tab is never in the sidebar and in the archive at the same time.

#### Undo

- Every command registers undo on the injected `UndoManager?`, except `archiveExpiredTabs`. Auto-archive runs in the background, so Cmd-Z must not bring old tabs back. The archive is its history.
- One command is one undo step. With per-event grouping (the AppKit default), the event's group holds the step. With `groupsByEvent = false` (the CLI), the model opens one group per command. The model never changes the undo manager's settings.
- Undo and redo call internal primitives only, never public commands. So an undo step never registers a second step. Redo runs the change again and captures fresh state for the next undo.
- `archiveExpiredTabs` can remove Today tabs and dissolve Today splits under older undo steps. Each undo step checks that its nodes are still where it expects. It skips the ones that are gone, so it never duplicates a node or drops a tab that was not archived.

### Events and lookup

After each structural command, `BrowserModel` sends synchronous main-actor `TreeChange` events to registered observers: `.insert(parent:index:nodeID)`, `.remove(parent:index:nodeID)`, `.move(fromParent:fromIndex:toParent:toIndex:nodeID)`, `.reload(parent)`.
`NodeParent` is `.spacePinned`, `.spaceToday`, `.folder`, `.favorites`, or `.splitPane`.
Single-node commands send precise events: `newTab` one `.insert`, `moveNode` / `addFavorite` / `removeFavorite` one `.move`, `closeTab` one `.remove`. Commands that change several lists at once (`makeSplit`, `unsplit`, a split collapse) send one `.reload` per changed parent.
Bulk commands make one pass. `clearToday` sends one `.reload`. `archiveExpiredTabs(now:)` sends one `.reload` per parent whose list changed (the Today section, a folder, or a split).
Property changes send no event. Observation covers them.

`BrowserModel` keeps `index: [ItemID: SidebarNode]` and `parentByID: [ItemID: NodeParent]`. Lookup is O(1).
Commands update both maps in place. Insert and remove cost O(size of the subtree). A move costs O(1) for the maps, because only the moved node's own parent entry changes. The pinned-URL rule adds O(tabs in the subtree) when a move enters or leaves Pinned or Favorites.
Child lists change in place, so a move does not copy the parent's array.
`rebuildIndex()` walks the whole tree. It runs only on load and import. The bench and `commands-demo` compare the live maps with a full rebuild after each phase.

## OpenStore

### SnapshotStore

DTOs are separate from the live classes. `SnapshotFileDTO.schemaVersion` is 1.
The file is `<root>/State/browser.json`. Root is injectable. Default root is `~/Library/Application Support/Open`.
`scheduleSave(model:)` encodes on the main actor, then writes on a background queue after a 1 s debounce.
`saveNow(model:)` writes at once. `flush()` drains the queue. Use `saveNow` at quit so the last state is on disk.
Writes are atomic: write a temp file, then rename over the target.
`load()` rebuilds the live model. A missing file returns nil.

### ArchiveStore (SQLite)

Table `archived_tabs`: `id`, `url`, `title`, `space_id`, `profile_id`, `archived_at`, `reason` (`closed` / `autoArchived` / `clearedToday` / `folderDeleted`), `original_location`, `payload` (full tab DTO JSON for restore).
`ArchiveStore` implements `ArchiveSink`. `archive(_:)` copies plain values on the main actor. JSON encoding and the SQLite writes run on a private serial queue, in one transaction per call. `discardArchived(ids:)` deletes rows on the same queue.
Query API: `recent(limit:)`, `search(_:limit:)`, `restore(id:)` (returns the record and deletes the row), `purge(olderThanDays:)`, `count()`. All are async.
`importRecords(_:)` stores imported archive records in one transaction. A record whose ID is already stored counts as a duplicate and keeps the stored row. It returns `(inserted, duplicates)`.
The restore flow is: `ArchiveStore.restore(id:)` returns the record, then `BrowserModel.restoreArchivedTab(_:)` puts the tab back.

### HistoryStore (SQLite + FTS5)

Tables: `urls(id, url UNIQUE, title, visit_count, typed_count, last_visit)`, `visits(id, url_id, time, transition)`, and external-content FTS5 `history_fts(title, url)` kept in sync by triggers. WAL mode is on.
`recordVisit` upserts the URL and appends a visit. `recordVisitsBulk` is the fast path for import and bench.
`search(_:limit:) async -> [HistoryMatch]`: the query splits on non-alphanumerics. Each piece becomes an FTS5 prefix term, so `site-123` matches. Results rank by frecency: `(visit_count + 3 * typed_count) / (1 + age in days)`. If FTS finds nothing, a substring `LIKE` search runs as a fallback.
Budget: under 5 ms on a 100k-URL database for selective command-bar queries. See the bench table. A broad query that matches most of the database (for example one common word) takes about 15–20 ms, because SQLite must score every match. The command bar sends selective queries in practice.

## OpenImport

Read order: sidebar, windows, routing, archive, session.
The importer reads only `StorableSidebar.json`, `StorableWindows.json`, `StorableLinkRouting.json`, `StorableArchiveItems.json` (if present), and `StorableSessionRestorationData.json` (if present). It never writes to the Arc folder.
Arc IDs map to stable Open IDs. A UUID Arc ID keeps its UUID. A sentinel string ID gets a deterministic UUID from the ID text. The same Arc item therefore maps to the same Open item on every import.

Sidebar parsing follows [data-model.md](re/data-model.md):

- Alternating `[id, object, …]` arrays for `items`, `spaces`, and `topAppsContainerIDs`.
- Order comes from each parent `childrenIds`, never from the flat array order.
- Space containers come from `newContainerIDs` first, with fallback to legacy `containerIDs`.
- `topApps` becomes Favorites on the default profile.
- Tab fields: `savedURL`, `savedTitle`, item `title` (kept as `customTitle` only when it differs), `savedMuteStatus`, `customInfo.iconType`, timestamps.
- Timestamps use the 2001 epoch: `unix = value + 978307200`.
- Space icon: `emoji_v2`, then the `emoji` scalar, then the named `icon`.
- Space theme: the raw `windowTheme` JSON goes to `importedArcThemeJSON`. Light/dark background and foreground map from `semanticColorPalette` when present.
- Leniency: unknown keys and unknown `data` cases are skipped and counted. Nothing fails except a missing `sidebar.containers`.
- Orphans (tab, folder, or split objects that no root reaches) become today items in the first Space and are counted in the report.
- Easels, notes, and welcome items are skipped and counted.
- One Open profile is created per distinct `Space.profile` value. All observed data uses `{default: true}`, so one profile serves all Spaces.
- Windows: one `BrowserWindowState` per entry. Focus, sidebar width and mode, style, and stay-on-top map over. Unknown styles become standard windows.
- Routing: `contains` becomes `.hostContains`, `equals` / `exact` becomes `.hostEquals`, `prefix` becomes `.urlPrefix`. Other match kinds are skipped and counted. A rule that points at the most recent Space maps to `.mostRecentSpace`. The file default destination maps directly.

`ImportReport` counts: `totalItems`, `spaces`, `pinnedTabs`, `todayTabs`, `favorites`, `folders`, `splits`, `routingRules`, skipped easels / notes / welcome / unknown, `orphans`, and `skippedRoutingRules`.
Audit rule: imported nodes + folders + splits + skipped + structural containers = `totalItems`. The CLI prints this check on every import and exits non-zero on a mismatch.
Boosts import does not run yet. No real `StorableBoostsData.json` exists on this Mac. The report states "not imported" for Boosts.

Archive (`StorableArchiveItems.json`, shape in [data-model.md](re/data-model.md) "Archive and session files (observed)"):

- The file holds an alternating `[id, entry, …]` array. Each entry holds `sidebarItem` (a full sidebar item), `reason`, `archivedAt`, and `source`.
- Parse is lenient. Unknown keys are ignored. Unknown item kinds, unknown reasons, unknown sources, malformed entries, duplicate IDs in the file, and items that are still live in the sidebar are skipped and counted. The import never fails on one bad entry.
- Non-tab items are skipped and counted by kind: easels, notes, welcome items, and unknown kinds.
- Reason map: `manual` → `closed`, `auto` → `autoArchived`, `clearButton` → `clearedToday`, `clearTabGroup` → `clearedToday`. No new reason was added. Both clear actions end in Today's cleared state in Open.
- `archivedAt` converts from the 2001 epoch (`unix = value + 978307200`).
- The original Space comes from `source.space._0` through the Arc Space ID → Open Space ID map. An unknown Space ID falls back to the first Space. The profile comes from that Space.
- The archived item's parent folder is lost in Arc's file (`parentID` is null). The record therefore stores `originalLocation` as `today:<spaceID>`. `restoreArchivedTab` then puts the tab at the top of that Space's Today section.
- The payload holds the full tab fields (`id`, `url`, `title`, `customTitle`, `customIcon`, `createdAt`, `lastActiveAt`, `isMuted`, `isUnread`). `restoreArchivedTab` rebuilds the tab from it.
- `ArcImporter.importAll()` returns the archive records. It does not write them. The CLI stores them through `ArchiveStore.importRecords(_:)`. OpenImport therefore still depends only on OpenModel.
- Re-import is idempotent by Arc item ID. Stable Open IDs plus the store duplicate check give zero new rows on a second import into the same output folder.

Session restoration (`StorableSessionRestorationData.json`):

- The file holds `mapping.keysToValues`, an alternating `[key, int, …]` array. Each key holds `browser.windowID`, `browser.contextID`, and `itemId`. The int is a Chromium SessionID.
- Used: which sidebar items were open in which window. For one window and one Space, the item with the newest `lastActiveAt` becomes `selectedNodeBySpace` for that Space. A session item that is a Favorite selects in the window's focused Space. Pair order is only a tie-break.
- Ignored: the Chromium SessionID values (the report counts distinct values only), profile and context detail beyond the incognito check, incognito entries (counted), windows that are absent from `StorableWindows.json` (counted as unmapped windows), and items that are absent from the sidebar, for example archived items (counted as unmapped items). Chromium's own `Sessions/Tabs_*` files are not read.
- The live file on this Mac at the last check held an empty mapping and `StorableWindows.json` held no windows. The session1 snapshot holds 10 pairs in one window and gives 2 applied selections.

## openkit CLI

```text
openkit import-arc [--arc-dir PATH] --out DIR [--show-titles]
openkit archive-list DIR [--limit N]
openkit dump DIR
openkit roundtrip DIR
openkit bench
openkit commands-demo DIR
```

`import-arc` imports, saves through `SnapshotStore`, stores archive records through `ArchiveStore`, prints the report, then prints the tree. The report holds sidebar counts, archive counts (file total, imported, stored new, stored duplicates, stored total, skipped by kind, and the archive accounted check), session mapping counts, and the final sidebar accounted check.
`archive-list` lists stored archive rows, newest first. It prints the row ID prefix, host only, reason, and archive time. Titles print as `•••`. `--limit N` caps the rows shown. The total row count always prints.
Titles and URLs are redacted by default. The tree prints item kind, ID prefix, and host only. `--show-titles` prints full titles and URLs. Never paste `--show-titles` output into docs.
`dump` loads a snapshot and prints the tree (redacted).
`roundtrip` loads, saves, reloads, and compares the two DTOs byte for byte. It exits non-zero on a mismatch.
`bench` builds a synthetic model (5,000 items over 10 Spaces) and times snapshot encode / decode / save / load. It inserts 100k history URLs and times 1,000 selective searches (p50 / p95). Then it times `moveNode` ×10,000 on a 5,000-item model (with and without an UndoManager), undoes every move, and times `archiveExpiredTabs` on 2,000 expired tabs (model only, then with the real `ArchiveStore`).
`commands-demo` runs every command against the real `ArchiveStore` in `DIR` and prints OK or FAIL for each check (66 checks), plus the tree at key steps. It covers: new tab, pin, folder; a split in a folder (allowed) with undo and redo; favorite move and unfavorite with undo and redo; placement rejections (split or folder into Favorites, a favorite into a split, a folder into its own descendant) with no events and no undo; a pane close that collapses its split, with undo; pinned to Today moves that clear `pinnedURL`, for a tab and for a folder with a split inside, with undo; close, archive, restore, with undo and redo; both restore fallbacks; restore into a split; `deleteSpace` with undo; `clearToday` with undo and redo; `archiveExpiredTabs` with a fake clock; and undo after auto-archive changed the tree. It exits non-zero on any failure.

## Verification (real runs, 2026-10-24)

Build: `swift build -c release` in `Packages/OpenKit` after `swift package clean` — zero warnings, zero errors (Swift 6.4, strict concurrency).

Real Arc import. The `*.json` files were copied to a temp folder first, because Arc may be running.
The runtime snapshot in `.re/runtime/appsupport` gives the same counts as at M1:

```text
import report:
  totalItems=46 accounted=37 spaces=4
  pinnedTabs=27 todayTabs=0 favorites=6
  folders=1 splits=1 routingRules=1
  skipped easels=1 notes=0 welcome=1 unknown=0
  orphans=0 skippedRoutingRules=0
  archive: not imported (no real file exists)
  boosts: not imported (no real file exists)
  containers(structural)=9 check imported+skipped+containers=46 total=46
```

A fresh copy of the live Arc folder (2026-10-25) gives the same totals: 46 items, 46 accounted. The skipped split differs (easels 0, welcome 2) because the user kept using Arc. The check line still reads `imported+skipped+containers=46 total=46`.
`todayTabs=0` in the runtime snapshot is correct. Its only Today item is one easel, and easels are skipped by design.
The one routing rule targets the most recent Space. It now imports as `{"mostRecentSpace":{}}`.

Roundtrip: `roundtrip OK` on both imports and on the `commands-demo` folder.

### Archive and session import (2026-10-25)

Build: `nice -n 10 swift build -c release -j 6` in `Packages/OpenKit` — zero warnings, zero errors.
The Arc `*.json` files were copied to a temp folder first. Each import ran twice into the same output folder. The second run must store zero new archive rows. Titles and URLs stay redacted. Hosts and ID prefixes are the only values shown.

Live Arc folder, first run:

```text
import report:
  totalItems=46 accounted=37 spaces=4
  pinnedTabs=27 todayTabs=0 favorites=6
  folders=1 splits=1 routingRules=1
  skipped easels=0 notes=0 welcome=2 unknown=0
  orphans=0 skippedRoutingRules=0
  archive: imported 9 of 10
  archive filePresent=true total=10 imported=9 storedNew=9 storedDuplicates=0 storedTotal=9
  archive skipped easels=1 notes=0 welcome=0 unknownKind=0 unknownReason=0 unknownSource=0 malformed=0 duplicatesInFile=0 alreadyLive=0
  archive check accounted=10 total=10 OK
  session filePresent=true totalPairs=0 mapped=0 unmappedItems=0 unmappedWindows=0 ignoredIncognito=0 windows=0 appliedSelections=0 distinctChromiumIDs=0 malformedPairs=0
  containers(structural)=9 check imported+skipped+containers=46 total=46
  accounted check: OK
```

Live Arc folder, second run into the same output folder. `storedNew=0` proves idempotent re-import:

```text
  archive filePresent=true total=10 imported=9 storedNew=0 storedDuplicates=9 storedTotal=9
  archive check accounted=10 total=10 OK
  accounted check: OK
```

Live `archive-list` (redacted):

```text
archive rows total=9 showing=9
  archive D6533F59 ••• <www.google.com> reason=autoArchived archivedAt=2026-10-25T16:33:01Z
  archive 15AABB55 ••• <www.google.com> reason=autoArchived archivedAt=2026-10-25T16:33:01Z
  archive E10F3ED8 ••• <www.google.com> reason=autoArchived archivedAt=2026-10-25T16:33:01Z
  archive 5EC187C6 ••• <www.google.com> reason=autoArchived archivedAt=2026-10-25T16:33:01Z
  archive 22E1B63E ••• <www.google.com> reason=autoArchived archivedAt=2026-10-25T16:33:01Z
  archive 26E214FD ••• <www.google.com> reason=autoArchived archivedAt=2026-10-25T16:33:01Z
  archive CDE65C16 ••• <www.thebrowser.company> reason=closed archivedAt=2026-10-25T04:33:24Z
  archive 7A134AB6 ••• <x.com> reason=closed archivedAt=2026-10-25T04:33:00Z
  archive AA769F4F ••• <same.energy> reason=closed archivedAt=2026-10-25T04:32:26Z
```

The live archive file holds 10 entries: 9 tabs and 1 easel. The easel is skipped and counted. Six tabs hold reason `auto`. Three tabs hold reason `manual`. The live session file holds an empty mapping. It gives no selections.

Session1 snapshot (`.re/runtime/appsupport/session1`), first run:

```text
import report:
  totalItems=53 accounted=44 spaces=4
  pinnedTabs=27 todayTabs=6 favorites=6
  folders=1 splits=1 routingRules=1
  skipped easels=1 notes=0 welcome=2 unknown=0
  orphans=0 skippedRoutingRules=0
  archive: imported 3 of 3
  archive filePresent=true total=3 imported=3 storedNew=3 storedDuplicates=0 storedTotal=3
  archive check accounted=3 total=3 OK
  session filePresent=true totalPairs=10 mapped=10 unmappedItems=0 unmappedWindows=0 ignoredIncognito=0 windows=1 appliedSelections=2 distinctChromiumIDs=10 malformedPairs=0
  containers(structural)=9 check imported+skipped+containers=53 total=53
  accounted check: OK
```

Session1, second run: `storedNew=0 storedDuplicates=3 storedTotal=3`. Session1 `archive-list` shows the same 3 `closed` rows as the last 3 rows of the live list. `roundtrip OK` on the live import, on session1, and on `commands-demo`. `commands-demo` on a fresh folder and on a copy of the imported snapshot: `commands-demo OK: 66 checks passed, 0 failed`.

Restore check: one imported session1 record went through `ArchiveStore.restore(id:)` and `BrowserModel.restoreArchivedTab(_:)`. The tab came back in the Today section of its source Space. This check ran in a throwaway probe outside the repo. It is not a unit test.

Edge check: a synthetic archive with one good tab, one unknown reason, one unknown source, one easel, one unknown kind, and one duplicate ID gave `imported=1` and one count in each skip bucket. The archive check still read OK. `archive-list` on an empty folder reads `archive rows total=0 showing=0`.

Old files still decode. A schema 1 snapshot with the pre-change rule encoding (`{"space":{"_0":…}}` in place of `{"mostRecentSpace":{}}`) loads with `dump` and round-trips with `roundtrip OK`.

`commands-demo` on a fresh folder: `commands-demo OK: 66 checks passed, 0 failed`. Selected output (synthetic demo data):

```text
  OK   one event: ["move(today[1] -> favorites[0])"]
  OK   one event: ["move(favorites[0] -> today[0])"]
  OK   undo: back in Pinned with the exact old pinnedURL, not the navigated URL
  OK   folder moved pinned -> today: every tab inside cleared, split panes too
  archived: Restorable reason=closed location=today space=original
  restored: Restorable id=53466EBB at today[0]
  OK   Today empty, one event: ["reload(today)"]
  archiveExpiredTabs archived=4 events=["reload(folder E0ABE511)", "reload(split F632278D)", "reload(today)"]
  OK   undo of the dissolved split does nothing: U1 once, U2 stays archived
```

The same 66 checks also pass on a copy of the imported Arc snapshot (output filtered to check lines, so no titles are printed).

Bench (Apple Silicon, release build). Three runs; ranges shown:

| Bench | Result |
|---|---|
| snapshot encode / decode / save / load (5,000 items) | 17.8–18.7 / 15.6–19.0 / 17.5–19.6 / 21.0–23.8 ms |
| history insert 100k URLs | 1,162–1,400 ms |
| history search p50 / p95 (1,000 selective queries) | 2.51–2.73 / 3.18–3.30 ms |
| `moveNode` ×10,000 on a 5,000-item model, UndoManager on | 3.3–4.3 µs average (target < 50 µs) |
| `moveNode` ×10,000, no UndoManager | 2.3–2.8 µs average |
| undo ×10,000 of those moves | 41–48 ms total; tree equals the original; index equals a full rebuild |
| `archiveExpiredTabs` on 2,000 expired tabs, model only | 1.1–1.3 ms, 21 `.reload` events |
| `archiveExpiredTabs` on 2,000 expired tabs, real `ArchiveStore` | 1.9–2.3 ms on the main actor + 12–14 ms background write (one transaction) |

The move bench picks random tabs and moves them to random slots in random Pinned, Today, and folder parents across all 10 Spaces (seeded, so runs are comparable). The expiry bench has 1,500 top-level tabs, 400 tabs in 20 folders, and 100 panes in 50 three-pane splits that collapse, plus 450 fresh tabs.

## Open design questions

1. Restore position. A restored tab goes to the top of its parent, because the record stores the parent but not the index. Arc's exact position is not verified.
2. `focusSpace` and `selectNode` register undo. Arc probably does not undo navigation. If not, Cmd-Z after a click would undo the click, not the last edit. Verify in Arc, then drop their undo.
3. `closeTab` archives pinned tabs and favorites too. In Arc, closing a pinned tab or a favorite may only unload it (guess). The UI layer must pick the right command until this is verified.
