# OpenKit model design (M1)

Status: implemented on branch `m1/openkit-core`. Package: [OpenKit](/Users/serge/.t3/worktrees/open/t3-eea14f87/Packages/OpenKit/Package.swift).
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
Settings: `autoArchiveAfter` (`never` / 1h / 6h / 12h / 24h / 7d / 30d, default 12h), `littleArcAutoArchiveAfter`, `searchEngineID`.

`BrowserWindowState`: `id`, `focusedSpaceID`, `selectedNodeBySpace`, `sidebarWidth` (default 228), `sidebarMode` (`.anchored` / `.hidden`), frame (`frameX/Y/Width/Height`), `style` (`.standard` / `.littleArc`), `stayOnTop`.

Link routing: `RoutingRule { id, match, destination }`.
Match: `.hostContains`, `.hostEquals`, `.urlPrefix`.
Destination: `.space(SpaceID)`, `.littleArc`.
`defaultDestination`: `.mostRecentSpace`, `.littleArc`, `.space(id)`.

### Commands

State changes only through named commands on `BrowserModel`:
`newTab`, `closeTab` (archives via the injected `ArchiveSink`), `pinTab` / `unpinTab`, `addFavorite` / `removeFavorite`, `moveNode(id:to:at:)`, `createFolder(in:title:withNodes:)`, `renameNode`, `setExpanded`, `createSpace` / `updateSpace` / `deleteSpace` / `moveSpace`, `makeSplit(tabIDs:)` / `unsplit` / `removePane`, `resetPinnedTab`, `replacePinnedURL`, `clearToday(space:)`, `archiveExpiredTabs(now:)`, `focusSpace`, `selectNode`.

Rules that matter:

- `closeTab` on a folder archives every tab inside it. On a split pane it removes that pane. A split that drops below 2 panes collapses back to a lone tab.
- `moveNode` refuses to move a folder into its own descendant. Moving across the pinned/today boundary sets or clears `pinnedURL`.
- `archiveExpiredTabs(now:)` uses the Space profile `autoArchiveAfter` and the tab `lastActiveAt`. It checks today tabs, split panes in today, and tabs inside today folders. Pinned tabs and favorites never expire.
- `deleteSpace` keeps at least one Space. It archives the Space tabs and moves window focus to the first remaining Space.
- Commands register inverse operations on the injected `UndoManager?`. Archiving commands register no undo. The archive record is the history.

### Events and lookup

After each structural command, `BrowserModel` sends one synchronous main-actor `TreeChange` to registered observers: `.insert(parent:index:nodeID)`, `.remove(parent:index:nodeID)`, `.move(fromParent:fromIndex:toParent:toIndex:nodeID)`, `.reload(parent)`.
`NodeParent` is `.spacePinned`, `.spaceToday`, `.folder`, `.favorites`, or `.splitPane`.
Property changes send no event. Observation covers them.
`BrowserModel` keeps `index: [ItemID: SidebarNode]` and `parentByID: [ItemID: NodeParent]`. Lookup is O(1). The index rebuilds after structural mutations.

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
The `ArchiveSink` entry point runs on the main actor and snapshots values there. Every SQLite statement runs on a private serial queue.
API: `recent(limit:)`, `search(_:limit:)`, `restore(id:)` (returns the record and deletes the row), `purge(olderThanDays:)`, `count()`. All are async.

### HistoryStore (SQLite + FTS5)

Tables: `urls(id, url UNIQUE, title, visit_count, typed_count, last_visit)`, `visits(id, url_id, time, transition)`, and external-content FTS5 `history_fts(title, url)` kept in sync by triggers. WAL mode is on.
`recordVisit` upserts the URL and appends a visit. `recordVisitsBulk` is the fast path for import and bench.
`search(_:limit:) async -> [HistoryMatch]`: the query splits on non-alphanumerics. Each piece becomes an FTS5 prefix term, so `site-123` matches. Results rank by frecency: `(visit_count + 3 * typed_count) / (1 + age in days)`. If FTS finds nothing, a substring `LIKE` search runs as a fallback.
Budget: under 5 ms on a 100k-URL database for selective command-bar queries. See the bench table. A broad query that matches most of the database (for example one common word) takes about 15–20 ms, because SQLite must score every match. The command bar sends selective queries in practice.

## OpenImport

Read order: sidebar, windows, routing.
The importer reads only `StorableSidebar.json`, `StorableWindows.json`, and `StorableLinkRouting.json`. It never writes to the Arc folder.

Sidebar parsing follows [data-model.md](/Users/serge/.t3/worktrees/open/t3-eea14f87/docs/re/data-model.md):

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
- Routing: `contains` becomes `.hostContains`, `equals` / `exact` becomes `.hostEquals`, `prefix` becomes `.urlPrefix`. Other match kinds are skipped and counted. A rule that points at the most recent Space maps to the first Space, because a rule needs a fixed destination. The file default destination maps directly.

`ImportReport` counts: `totalItems`, `spaces`, `pinnedTabs`, `todayTabs`, `favorites`, `folders`, `splits`, `routingRules`, skipped easels / notes / welcome / unknown, `orphans`, and `skippedRoutingRules`.
Audit rule: imported nodes + folders + splits + skipped + structural containers = `totalItems`. The CLI prints this check on every import.
Archive import and Boosts import do not run yet. No real `StorableArchiveItems.json` or `StorableBoostsData.json` exists on this Mac. The report states "not imported" for both.

## openkit CLI

```text
openkit import-arc [--arc-dir PATH] --out DIR [--show-titles]
openkit dump DIR
openkit roundtrip DIR
openkit bench
openkit commands-demo DIR
```

`import-arc` imports, saves through `SnapshotStore`, prints the report, then prints the tree.
Titles and URLs are redacted by default. The tree prints item kind, ID prefix, and host only. `--show-titles` prints full titles and URLs. Never paste `--show-titles` output into docs.
`dump` loads a snapshot and prints the tree (redacted).
`roundtrip` loads, saves, reloads, and compares the two DTOs byte for byte. It exits non-zero on a mismatch.
`bench` builds a synthetic model (5,000 items over 10 Spaces), times snapshot encode / decode / save / load, then inserts 100k history URLs and times 1,000 selective searches (p50 / p95).
`commands-demo` runs new tab, pin, folder, move, split, `clearToday`, `archiveExpiredTabs` with a fake clock, and undo. It prints the tree after each step and proves events, undo, and the archive sink work.

## Verification (real runs, 2026-10-24)

Build: `swift build -c release` in `Packages/OpenKit` — zero warnings, zero errors (Swift 6.4, strict concurrency).

Real Arc import. Files were copied to a temp folder first, because Arc may be running. Both the live folder copy and the runtime snapshot in `.re/runtime/appsupport` give the same counts:

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

Every one of the 46 item objects is accounted for: 37 imported or skipped nodes + 9 structural containers.
`todayTabs=0` is correct for this data. The only today item in the file is one easel, and easels are skipped by design.

Roundtrip on the imported snapshot: `roundtrip OK`.

Commands demo on a fresh folder (titles shown here are synthetic demo data):

```text
events after newTab: 1
made split (2 panes)
archived after clearToday: 2 tabs (clearedToday)
archiveExpiredTabs archived=1, sink total=3
after undo: today count=0
commands-demo OK
```

Bench (Apple Silicon, release build). One run is shown. Runs vary by a few ms:

```text
bench: synthetic model (5000 items over 10 spaces)
  snapshot encode: 20.6 ms
  snapshot decode: 19.3 ms
  snapshot save:   21.0 ms
  snapshot load:   24.3 ms
bench: history (100k URLs, 1000 searches)
  history insert 100k: 1673.4 ms (urls=100000)
  history search p50: 2.866 ms  p95: 3.667 ms
```

## Open design questions

1. Split panes inside a folder: `makeSplit` puts the split where its first tab lived. Confirm that a split inside a folder is a valid Arc state, or restrict splits to space-level parents.
2. Favorite identity: `addFavorite` copies the tab (new ID). Arc may keep one item that is both a favorite and a tab. Copy keeps the model simple. It means rename and mute do not sync between the two rows.
3. Routing rules that target the most recent Space have no fixed destination. The importer maps them to the first Space. A future `RoutingDestination.mostRecent` case may fit better.
4. `ArchiveStore.restore` returns the stored record. The command that puts a restored tab back into a Space is not part of this milestone.
