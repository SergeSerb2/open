# OpenKit model design (M1 + M5 Profiles)

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
Runtime-only state lives in `tab.live: TabLiveState`: `hasWebContent`, `isLoading`, `progress`, `isAudible`, `isCrashed`, `canGoBack`, `canGoForward`, `faviconPNG`.
`TabLiveState` is never persisted.

`Folder`: `id`, `title`, `isExpanded`, `children: [SidebarNode]` (any depth).
`Split`: `id`, `orientation` (`.horizontal` / `.vertical`), `fractions`, `panes: [Tab]` (2–4), `focusedPaneID`.

`Space`: `id`, optional `title`, `icon` (`.emoji` / `.symbol` / `.named`), `theme: SpaceTheme`, `profileID`, `pinned`, `today`, `isPinnedCollapsed`.
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

`mergeImportedSidebar(_:profileMapping:spaces:tabs:favorites:folders:searchSettings:saving:)`
is the Settings import command. It copies new IDs, appends new Spaces, and
keeps live Space metadata, Profile assignments, item order, and selections.
It merges search-engine fields only when selected. Equal routing rule bodies
are duplicates even when the source importer assigns a new rule ID; the live
default destination stays authoritative. Source objects are unchanged.
Structural edits emit precise insert/remove events; new containers emit
reloads. The caller's synchronous snapshot save is part of the command.
Failure reverses the edits and registers no undo. Success registers one undo
step for the sidebar/search/routing merge. Archive rows have their own
per-Profile transaction and are not removed by sidebar Undo.

Space editor inputs live in `SpaceTheme.style: SpaceStyle?`. A style stores
only its key color, count, wheel, appearance, noise, texture, intensity, and
`mathVersion` (currently 1). Derived palettes are not persisted. Count is
clamped to 1–3, noise and intensity to 0–1, and key alpha to 1 on decode and
on writes. Unknown wheel, appearance, and texture strings decode to
analogous, automatic, and grain. The math version is preserved. Missing
style and icon override keys decode as nil; schemaVersion remains 1.

`Tab.iconOverride` and `Folder.iconOverride` are typed `SpaceIcon?` values.
Rows resolve that value before legacy `customIcon`, then use the favicon or
folder glyph. `setNodeIcon` writes the override and clears `customIcon` in
one undo step; undo restores both. New Arc imports write typed overrides.
Existing legacy strings keep their meaning (SF Symbol if available, else
emoji). Import keeps the raw Arc theme and never writes editor inputs.
Folders now draw a legacy `customIcon` through that precedence rule. Before
this step the folder renderer ignored that field, and no current writer
sets it. This is an intentional rendering change required by plan §3.3.
Empty imported tab emoji strings are absent; named tab icons share the
known/unknown counters used for Space icons.

Style fields other than the required key color use their documented
defaults when absent, null, or the wrong type. A style with no usable key
color (or an invalid object shape) decodes as nil on `SpaceTheme`, preserving
the rest of the snapshot and its legacy theme. Present valid key colors and
math versions keep their stored values.

`previewSpaceTheme` changes only the live theme, without undo or TreeChange.
`commitSpaceTheme(id:from:)` commits the entire preview gesture as one undo
step, or returns false for an equal value or missing Space. The caller owns
the save after commit. `setSpaceIcon` and `renameSpace` are single property
undo steps; whitespace-only Space titles become nil. Same-value commands
register no undo.

`createSpace(...at:moving:) -> Space?` validates the entire moving list
(existing nodes, no split panes, duplicate IDs, or ancestor/descendant pairs,
and valid placement) and an explicit index in `0...spaces.count` before any
write. A refusal returns
nil with no mutation, event, undo, or save. Success inserts the Space and
moves the nodes into Pinned by default, in order, as one undo step.
The New Space form uses `placement: .preserveSection` for tab and selection
moves: Pinned stays Pinned and Today stays Today, including nodes in folders.
Folder conversion passes `placement: .today` and `removingEmptyFolder:`;
the model validates the exact ordered children, moves them, and removes the
empty folder in that same transaction. An optional `creatingProfileNamed:`
creates the inline Profile in that transaction too; invalid names or moves
create neither object. Undo removes both and refocuses each window's previous
Space; redo preserves object IDs. Folder children,
object identities, source positions, and pinned URLs restore on undo. The
model buffers TreeChange events until every relocation succeeds. A late
failure reverses all earlier moves and removes the inserted Space, then
discards the events and registers no undo. A DEBUG-only CLI seam exercises
the rollback code; the seam does not exist in production builds.
Successful moves emit one `.move` per node and no source-parent reload.
An unknown Profile ID likewise refuses with no changes. The original
nonoptional overload requires a live Profile ID and delegates with an append
index and no moves; nil is a programmer error and its precondition names the
bad ID. Data/import/automation/restored IDs must use the failable overload.
Step 7's move-to-new-Space and folder conversion callers
must likewise return false or nil on refusal without partial changes.

Editor writes use `SpaceTheme(style:)`, clearing legacy theme fields. Older
builds ignore the additive style key and lose that edited appearance. This
is accepted because Open has no released users. Values written before the
editor retain their original decoding and render path.

`tools/verify-all.sh` runs the `space-legacy` gate. It copies the frozen
pre-Step-1 synthetic fixture, runs `openkit roundtrip` (byte-comparing its
encoded DTOs before and after save/load), compares all original semantic
fields, and renders all three Spaces against committed pre-change PNGs
byte for byte. The raw fixture can gain only `keepAliveSites: []`, an
additive default from the later main-branch keep-alive change. The source
fixture and its PNGs never change during verification. The window-buttons
change (PR #104) re-rendered the PNGs: every changed pixel lies in the
stand-in window buttons (x 13–73, y 17–31), which now draw the dimmed rest
look; all other pixels equal the pre-Step-1 renders. The window-chrome
follow-up refits the dark minimize/zoom rings against live session-2 pixels:
only `Fixtures/space-schema1/window-2.png` changes, by 168 pixels inside
x 36–72, y 17–30, all within the two ring bands. Spaces 0 and 1 remain
byte-identical. The bundled editor baselines are unchanged (`space-editor`
still passes). Evidence: the `space-legacy` real render and the pixel diff
recorded in the follow-up PR; live comparison in `design.md` §23.3.
The sidebar offscreen renderer supplies its Metal command queue to
`CARenderer` and synchronizes readback on that same queue. This prevents a
read-before-render race exposed by P1; 24 consecutive renders matched the
unchanged baseline PNGs after the fix.

State changes only through named commands on `BrowserModel`:
`newTab`, `closeTab` (archives via the injected `ArchiveSink`), `pinTab` / `unpinTab`, `addFavorite(tabID:to:at:)` / `removeFavorite(tabID:into:)`, `moveNode(id:to:at:)`, `createFolder(in:title:withNodes:)`, `renameNode`, `setExpanded`, `setPinnedSectionCollapsed(spaceID:collapsed:)`, `setMuted(tabID:muted:)`, `createSpace` / `updateSpace` / `deleteSpace` / `moveSpace`, `makeSplit(tabIDs:)` / `unsplit` / `removePane`, `resetPinnedTab`, `replacePinnedURL`, `restoreArchivedTab(_:)`, `clearToday(space:)`, `archiveExpiredTabs(now:)`, `focusSpace`, `selectNode`, `createProfile`, `renameProfile`, `setProfileIcon`, `updateProfileSettings`, `deleteProfile`, `moveSpace(id:toProfile:)`. See Profiles below for validation, queries, and repair.
Window commands: `createWindow(focusedSpaceID:)`, `closeWindow(windowID:)`,
`setSidebarWidth(windowID:width:)`, and `setSidebarMode(windowID:mode:)`.
They register property/window undo steps and emit no `TreeChange`: windows are
not sidebar structure. Creation refuses an unknown Space. Width refuses
non-finite input and clamps to 228–500. The App supplies window lifecycle and
snapshot scheduling; the model has no AppKit or engine dependency.

Query: `isPinned(tabID:)`. `newTab` without an explicit index inserts at the top of Today. Collapse and mute are property-only undo steps. Same-value or missing-target commands register no undo and send no event.

Untitled Spaces store `title == nil`; schema-1 snapshots accept both missing/null and existing string titles. `displayTitle(for:)` uses “Space N” for the current 1-based position when the title is nil or empty. `SpaceIcon.named` retains the imported identifier across snapshot save/load. [NamedSpaceIcons.swift](../Packages/OpenKit/Sources/OpenModel/NamedSpaceIcons.swift) supplies the checked SF Symbol mapping and neutral fallback. Older builds cannot decode the new named-icon enum case.

`TabLiveState.hasWebContent` defaults to false. The future engine adapter owns it. Snapshot save/load discards it with all other live state. Sidebar unload intents do not change or archive the model entry.
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
- A split that leaves the tree keeps its windows on a page. On a collapse (`removePane` with or without `archive`, `closeTab` on a pane), every window whose `selectedNodeBySpace` held the split selects the remaining tab. On `unsplit`, it selects the split's focused pane (else the first pane). Undo puts the split back and selects it again where the selection still points at that tab; redo repeats the move. Keys, menus, and scripts get this from the model; controllers do not re-select.
- `deleteSpace` keeps at least one Space. It archives the Space's tabs and moves window focus to the first remaining Space.
- `clearToday(space:)` archives every Today node of the Space in one pass.
- `archiveExpiredTabs(now:)` uses the Space profile's `autoArchiveAfter` and the tab's `lastActiveAt`. It checks Today tabs, split panes in Today, and tabs inside Today folders, at any depth. Pinned tabs and favorites never expire. A split left with fewer than 2 panes dissolves.
- Every archive entry stores the tab's direct parent as `originalLocation` (`pinned:<uuid>`, `today:<uuid>`, `folder:<uuid>`, `favorites:<uuid>`, `split:<uuid>`; see `NodeParent.archiveLocation`), plus the owning Space and profile.
- `restoreArchivedTab(_ record:)` rebuilds the tab from the record payload with its original ID. It places the tab, in this order: at the top of the original parent if that parent still exists (a split only while it has fewer than 4 panes); else at the top of the original Space's Today section; else at the top of the focused Space's Today section. The pinned-URL rule applies for the destination. The tab gets `lastActiveAt = now`, so auto-archive does not take it again at once. A record whose ID is already in the sidebar returns that tab unchanged. Undo sends the tab back to the archive.
- `ArchivedTabRecord` lives in OpenModel, so the model does not depend on OpenStore.
- `ArchiveSink` has asynchronous `archive(_ entries: [ArchiveEntry])` and `discardArchived(ids:)` paths, plus throwing `archiveForProfileDeletion(_:directoryName:)` for confirmed deletion writes. A bulk command makes one `archive` call for all of its tabs. When a tab comes back to the sidebar (restore, or undo of a close, clear, or Space delete), the model calls `discardArchived`. So a tab is never in the sidebar and in the archive at the same time.

#### Undo

- Every command registers undo on the injected `UndoManager?`, except `archiveExpiredTabs` and load maintenance (`repairMissingProfileReferences`). Auto-archive runs in the background, so Cmd-Z must not bring old tabs back. The archive is its history.
- One command is one undo step. With per-event grouping (the AppKit default), the event's group holds the step. With `groupsByEvent = false` (the CLI), the model opens one group per command. The model never changes the undo manager's settings.
- Undo and redo call internal primitives only, never public commands. So an undo step never registers a second step. Redo runs the change again and captures fresh state for the next undo.
- `archiveExpiredTabs` can remove Today tabs and dissolve Today splits under older undo steps. Each undo step checks that its nodes are still where it expects. It skips the ones that are gone, so it never duplicates a node or drops a tab that was not archived.

### Events and lookup

After each structural command, `BrowserModel` sends synchronous main-actor `TreeChange` events to registered observers: `.insert(parent:index:nodeID)`, `.remove(parent:index:nodeID)`, `.move(fromParent:fromIndex:toParent:toIndex:nodeID)`, `.reload(parent)`, `.spaceProfileChanged(spaceID:from:to:)`.
`NodeParent` is `.spacePinned`, `.spaceToday`, `.folder`, `.favorites`, or `.splitPane`.
Single-node commands send precise events: `newTab` one `.insert`, `moveNode` / `addFavorite` / `removeFavorite` one `.move`, `closeTab` one `.remove`. Commands that change several lists at once (`makeSplit`, `unsplit`, a split collapse) send one `.reload` per changed parent.
Bulk commands make one pass. `clearToday` sends one `.reload`. `archiveExpiredTabs(now:)` sends one `.reload` per parent whose list changed (the Today section, a folder, or a split).
Other property changes send no event. Observation covers them. A Space Profile change is an explicit event so the future engine adapter can recreate its web contents.

`BrowserModel` keeps `index: [ItemID: SidebarNode]` and `parentByID: [ItemID: NodeParent]`. Lookup is O(1).
Commands update both maps in place. Insert and remove cost O(size of the subtree). A move costs O(1) for the maps, because only the moved node's own parent entry changes. The pinned-URL rule adds O(tabs in the subtree) when a move enters or leaves Pinned or Favorites.
Child lists change in place, so a move does not copy the parent's array.
`rebuildIndex()` walks the whole tree. It runs only on load and import. The bench and `commands-demo` compare the live maps with a full rebuild after each phase.

## OpenStore

### SnapshotStore

DTOs are separate from the live classes. `SnapshotFileDTO.schemaVersion` is 1.
The file is `<root>/State/browser.json`. Root is injectable. Default root is `~/Library/Application Support/Open`.
`scheduleSave(model:)` encodes on the main actor, then writes on a background queue after a 1 s debounce.
`saveNow(model:)` throws on failure and returns only after the atomic write is durable. `flush()` drains the queue. Use `saveNow` at quit so the last state is on disk.
Writes are atomic: write a temp file, then rename over the target.
`load()` rebuilds the live model and calls `OpenDataRoot.prepare()` before returning. A missing file prepares the root and returns nil.

### ArchiveStore (SQLite)

App import uses throwing `importRecords(_:checking:)`: an unavailable store
or failed transaction is a per-kind import failure, never a duplicate count.
Only an existing ID counts as a duplicate. The legacy nonthrowing overload
remains available to package callers and returns zero counts on write failure.

`ArchiveStore(fileURL:)` opens a Profile file from `ProfileDirectories.archiveFileURL(for:)`. `ProfileArchiveSink` routes each model batch by Profile and forwards undo discards to every created store.

Table `archived_tabs`: `id`, `url`, `title`, `space_id`, `profile_id`, `archived_at`, `reason` (`closed` / `autoArchived` / `clearedToday` / `folderDeleted`), `original_location`, `payload` (full tab DTO JSON for restore).
`ArchiveStore` implements `ArchiveSink`. `archive(_:)` copies plain values on the main actor. JSON encoding and the SQLite writes run on a private serial queue, in one transaction per call. `discardArchived(ids:)` deletes rows on the same queue.
Query API: `recent(limit:)`, `search(_:limit:)`, `restore(id:)` (returns the record and deletes the row), `purge(olderThanDays:)`, `count()`. All are async.
`importRecords(_:)` stores imported archive records in one transaction. A record whose ID is already stored counts as a duplicate and keeps the stored row. It returns `(inserted, duplicates)`.
The restore flow is: `ArchiveStore.restore(id:)` returns the record, then `BrowserModel.restoreArchivedTab(_:)` puts the tab back.

### HistoryStore (SQLite + FTS5)

`HistoryStore(fileURL:)` opens a Profile file from `ProfileDirectories.historyFileURL(for:)`. The former `root:` initializer is removed.

Tables: `urls(id, url UNIQUE, title, visit_count, typed_count, last_visit)`, `visits(id, url_id, time, transition)`, and external-content FTS5 `history_fts(title, url)` kept in sync by triggers. WAL mode is on.
`recordVisit` upserts the URL and appends a visit. `recordVisitsBulk` remains the URL-only bench path. Phase 2 uses `importHistoryBatch` to write visits and recompute counts from those visits.
`search(_:limit:) async -> [HistoryMatch]`: the query splits on non-alphanumerics. Each piece becomes an FTS5 prefix term, so `site-123` matches. Results rank by frecency: `(visit_count + 3 * typed_count) / (1 + age in days)`. If FTS finds nothing, a substring `LIKE` search runs as a fallback.
Budget: under 5 ms on a 100k-URL database for selective command-bar queries. See the bench table. A broad query that matches most of the database (for example one common word) takes about 15–20 ms, because SQLite must score every match. The command bar sends selective queries in practice.

## OpenImport

Read order: sidebar, windows, routing, archive, session.
`ArcImporter` reads only `StorableSidebar.json`, `StorableWindows.json`, `StorableLinkRouting.json`, `StorableArchiveItems.json` (if present), and `StorableSessionRestorationData.json` (if present). It never writes to the Arc folder.
Arc IDs map to stable Open IDs. A UUID Arc ID keeps its UUID. A sentinel string ID gets a deterministic UUID from the ID text. The same Arc item therefore maps to the same Open item on every import.

Sidebar parsing follows [data-model.md](re/data-model.md):

- Alternating `[id, object, …]` arrays for `items`, `spaces`, and `topAppsContainerIDs`.
- Order comes from each parent `childrenIds`, never from the flat array order.
- Space containers come from `newContainerIDs` first, with fallback to legacy `containerIDs`.
- Each alternating `topAppsContainerIDs` ProfileRef/container pair becomes Favorites on that Profile.
- Tab fields: `savedURL`, `savedTitle`, item `title` (kept as `customTitle` only when it differs), `savedMuteStatus`, `customInfo.iconType`, timestamps.
- Timestamps use the 2001 epoch: `unix = value + 978307200`.
- Space icon: `emoji_v2`, then the `emoji` scalar, then the named `icon`.
- Space theme: the raw `windowTheme` JSON goes to `importedArcThemeJSON`. Light/dark background and foreground map from `semanticColorPalette` when present.
- Leniency: unknown keys and unknown `data` cases are skipped and counted. Nothing fails except a missing `sidebar.containers`.
- Orphans (tab, folder, or split objects that no root reaches) become today items in the first Space and are counted in the report.
- Easels and notes are skipped and counted. Welcome items import as ordinary tabs, retain their titles/timestamps, and use the public welcome page when the payload has no URL. `importedWelcome` is a subset of imported tabs, never an additional accounting term.
- `Space.profile` and Favorites share one Profile resolver. `{default:true}` selects Default; the observed named shape is `{custom:{_0:{directoryBasename:"Profile 1",machineID:…}}}`. The directory identifies the source Profile; the machine ID does not create another Profile. Names come from `User Data/Local State` → `profile.info_cache[directory].name`.
- Windows: one `BrowserWindowState` per entry. Focus, sidebar width and mode, style, and stay-on-top map over. Unknown styles become standard windows.
- Routing: `contains` becomes `.hostContains`, `equals` / `exact` becomes `.hostEquals`, `prefix` becomes `.urlPrefix`. Other match kinds are skipped and counted. A rule that points at the most recent Space maps to `.mostRecentSpace`. The file default destination maps directly.

`ImportReport` counts: `totalItems`, `spaces`, `pinnedTabs`, `todayTabs`, `favorites`, `folders`, `splits`, `routingRules`, imported welcome, named-icon counts, untitled Spaces, skipped easels / notes / unknown, `orphans`, and `skippedRoutingRules`.
Audit rule: imported nodes + folders + splits + skipped + structural containers = `totalItems`. The CLI prints this check on every import and exits non-zero on a mismatch.
Boost parsing reads the Firestore offline cache through a private copy, with an
own bounded LevelDB, Snappy and protobuf reader. It imports only live `boosts`
remote documents. `StorableBoostsData.json` supplies local enablement only.
See [Boost storage evidence](re/boosts-store.md) for the confirmed schema,
counted guesses, dropped color/zoom fields and limits. `ImportReport.boosts`
counts found, mapped, malformed, deleted, unknown and other-collection records,
mapped/dropped/unknown fields, Default Profile guesses and unknown enablement.
The real source on this Mac contains a deletion marker, not a populated Boost.

`ArcImportResult.boostsByProfile` carries values without writing files. All
account-scoped Boosts currently map to Default (a counted guess). The CLI writes
through `OpenBoosts` at `ProfileDirectories.boostsFileURL(for:)`, retaining the
exclusive data-root preparation token throughout. It refuses a root held by a
running App. Re-import preserves every existing stable ID and reads the saved
DTO back before reporting success. BoostStore stamps new records' modification
time at import, so `protectedEdits` counts newer destination records, including
unchanged imports. It cannot distinguish those from user edits.

The App has a report-only `recordBoostImport([ProfileID: [Boost]], counts:)`
seam. It reports source counts and `Not imported in this build`; it writes no
Boosts. Persistence, live apply, re-import and shared Undo remain **BLOCKED
(Section 12 AppBoosts)**. Follow-up must use
`app.stores.boosts.store(for: profileID).upsert(boost)`, then
`app.stores.boosts.refresh(profile: profileID)` once per Profile. No second App
BoostStore is allowed: its delayed save could overwrite the sole owner's data.

Archive (`StorableArchiveItems.json`, shape in [data-model.md](re/data-model.md) "Archive and session files (observed)"):

- The file holds an alternating `[id, entry, …]` array. Each entry holds `sidebarItem` (a full sidebar item), `reason`, `archivedAt`, and `source`.
- Parse is lenient. Unknown keys are ignored. Unknown item kinds, unknown reasons, unknown sources, malformed entries, duplicate IDs in the file, and items that are still live in the sidebar are skipped and counted. The import never fails on one bad entry.
- Welcome archive items import as ordinary tabs. Other non-tab items are skipped and counted by kind: easels, notes, and unknown kinds.
- Reason map: `manual` → `closed`, `auto` → `autoArchived`, `clearButton` → `clearedToday`, `clearTabGroup` → `clearedToday`. No new reason was added. Both clear actions end in Today's cleared state in Open.
- `archivedAt` converts from the 2001 epoch (`unix = value + 978307200`).
- The original Space comes from `source.space._0` through the Arc Space ID → Open Space ID map. An unknown Space ID falls back to the first Space. The profile comes from that Space.
- The archived item's parent folder is lost in Arc's file (`parentID` is null). The record therefore stores `originalLocation` as `today:<spaceID>`. `restoreArchivedTab` then puts the tab at the top of that Space's Today section.
- The payload holds the full tab fields (`id`, `url`, `title`, `customTitle`, `customIcon`, `createdAt`, `lastActiveAt`, `isMuted`, `isUnread`). `restoreArchivedTab` rebuilds the tab from it.
- `ArcImporter.importAll()` returns the archive records. It does not write them. The CLI stores them through `ArchiveStore.importRecords(_:)`. OpenImport depends on OpenModel, OpenRouting and OpenBoosts; it has no store writer.
- Re-import is idempotent by Arc item ID. Stable Open IDs plus the store duplicate check give zero new rows on a second import into the same output folder.

Session restoration (`StorableSessionRestorationData.json`):

- The file holds `mapping.keysToValues`, an alternating `[key, int, …]` array. Each key holds `browser.windowID`, `browser.contextID`, and `itemId`. The int is a Chromium SessionID.
- Used: which sidebar items were open in which window. For one window and one Space, the item with the newest `lastActiveAt` becomes `selectedNodeBySpace` for that Space. A Favorite selects in the focused Space only when that Space uses its owner Profile. If the window now focuses another Profile, the importer uses the owner Profile's first Space; that last Space choice is a marked guess because the source session key has no Space ID for Favorites. Pair order is only a tie-break.
- Ignored: the Chromium SessionID values (the report counts distinct values only), profile and context detail beyond the incognito check, incognito entries (counted), windows that are absent from `StorableWindows.json` (counted as unmapped windows), and items that are absent from the sidebar, for example archived items (counted as unmapped items). Chromium's own `Sessions/Tabs_*` files are not read.
- Historical snapshots included an empty live mapping and a session1 capture with 10 pairs and 2 applied selections. The 2026-11-06 two-Profile copy has 8 pairs and one window; its inactive-Profile Favorite entries exposed the owner-Profile selection fix ([audit](import-multiprofile.md)).

### Import from Arc, phase 2 (M8)

Implemented from [import-phase2.md](plans/import-phase2.md), with its Lead decisions appendix and the implementation brief's safety limits.
`ArcImporter`, `CLI.swift`, and suggestion ranking are unchanged.

`ArcHistoryReader` copies History and its WAL, or the rollback journal in rollback mode, into a private mode-700 directory. It never copies SHM; SQLite rebuilds that file. Copy destinations are created exclusively with mode 600 before any bytes are written. The CLI removes user-owned import directories older than one hour at startup. SQLite opens and recovers only the private copy. A failed quick check gets one fresh-copy retry after 200 ms. The reader deletes its copy on success and failure. It accepts History meta versions 65–75, converts Chromium microseconds with integer epoch subtraction, keeps http/https/file visits, and filters internal schemes, subframes, invalid times, and times more than 24 hours ahead. It maps transition core bits and counts typed visits only for core 1. No source aggregate count overrides visit rows.

`ArcImportResult.sourceProfileDirectories` maps each imported Profile ID to its original Chromium directory, before Open destination collision suffixes. `sourceDefaultProfileID` carries the resolver's `defaultID` for `{default:true}`. The App uses these values for background History imports through its shared Profile stores.

The App creates live imported Profiles through `BrowserModel.createProfile`,
with the stable import ID and Open's normal directory allocator. Named Arc
directories are source paths only; an existing Open folder with the same
basename is never adopted. Settings and any first-run path that merges into
the live model map Arc's `{default:true}` role to `app.model.defaultProfile`,
even when its ID and display name differ. This role mapping takes priority
over stable-ID lookup. It preserves the live Default's engine context and
logins. The same `profileMapping` routes its Spaces, Favorites, routing
destinations, Archive and History; no second mapping is used. Named Arc
Profiles match only their stable import ID. A same-name named Profile without
that ID stays separate; the new display name receives a suffix.
Profiles exist before Spaces or Archive/History stores use them. A Settings
merge keeps one model Undo, including its newly created Profiles. Physical
store/context deletion after Undo still needs Section 10's in-session deletion
contract; the current Settings deletion path requires confirmation and defers
loaded engine data until restart. Import does not bypass that path.
Older Settings imports from pre-release development builds get no provenance
migration. Existing Space assignments stay authoritative on re-import.
Settings preserves its live window layout. The inactive-Profile Favorite's
first-Space selection remains an accepted, marked guess.

An App import starts each added Today tab's `lastActiveAt` at the import time,
so startup auto-archive does not immediately remove old source tabs. Pinned tabs
and Favorites keep their source activity times. Settings re-import also treats
a stable tab/Favorite ID already in the target Profile's ArchiveStore as a
duplicate. The App awaits one batched ID lookup per Profile on the archive
queue, then passes the ID sets into the synchronous model merge. Live-ID
deduplication stays unchanged. Neither rule changes Arc's source files.

The reader retains the plan's array-returning API and adds an awaited batch-consumer overload. The CLI uses that overload to keep at most one 5,000-visit batch in flight, plus the source URL map. `HistoryStore(fileURL:)` accepts a full destination path. The writer uses one checked transaction per batch, reuses prepared statements, and rolls back all changes on failure. `history_import_keys` deduplicates by source profile directory and Chromium visit ID. The new `(url_id, time)` index supports count recomputation. A result success flag also detects a bad destination for an empty import.

The upsert skips unchanged or empty replacement titles. This preserves the specified title result and avoids redundant FTS trigger work. The first F2 run, before this guard, failed the timing gate at 3.307 s. The final streaming implementation passed at 1.443 s. Re-import updates no visit count by hand and inserts no duplicate visit.

`ChromiumCrypto` implements consent-gated Keychain lookup, the prescribed probe order, PBKDF2-HMAC-SHA1, v10 AES-CBC decryption, explicit PKCS7 final-block validation, and the empty-password fallback. Passwords, keys, decrypted values, and failure buffers are cleared after use. The CLI calls no Keychain API unless `--allow-keychain-access` is present. Without the flag it counts rows only and reports `keychain: not requested`. No real Keychain lookup, prompt, or real secret decryption was run for this milestone.

`ArcSecretsReader` parses passwords, cookies, addresses, form history, and cards in memory. It validates UTF-8 without making secret String copies, skips expired cookies, and counts blacklisted logins separately. The CLI uses `validateWithKey`; `readWithKey` lends one record at a time to typed callbacks and clears its secret buffer immediately afterward. No retaining API remains. Callbacks must not copy or retain records or fields. All four record types redact descriptions, debug descriptions, and reflection. Cookie schema 24 and later strips a matching SHA256 domain prefix. Valid UTF-8 values without a matching prefix remain eligible and increment `legacyNoHashPrefix`. Address use dates are Unix seconds. Evidence: local Chromium `net/extras/sqlite/sqlite_persistent_cookie_store.cc`, version-24 comment and `MakeCookiesFromSQLStatement`; `components/autofill/core/browser/webdata/addresses/address_autofill_table.cc`, `Time::FromTimeT` / `ToTimeT`; and the crypto sources listed in the plan's evidence index.

Extensions are the union of Secure Preferences and installed payload folders.
Classification uses path and payload rules. `ArcImportResult.extensionsByProfile`
holds only in-memory metadata for the original directories recorded in
`sourceProfileDirectories`. Candidates then use the live Profile mapping:
Arc Default maps to the live Default by role; named sources map to their live
Profiles. Destination directory collision suffixes never select a source.
`ImportReport.extensions` accounts for total,
internal, candidate, and missing-manifest records; unreadable Profiles have a
separate count. Preference JSON is limited to 16 MiB, 4,096 records per Profile,
256 payload versions per extension, 1 MiB per manifest, and 1,024 UTF-8 bytes
per display name. Symlinks cannot escape the Profile's source tree.

The App maps each candidate to the live destination Profile after importing.
The first-run and Settings report share `ImportExtensionsSection`. Names stay
in the UI and never enter CLI output. Nothing installs until the user clicks
Install Extensions. `AppImportExtensions` calls the destination context's
Web Store installer, serially, through the existing consent sheet. Cancel and
already installed are skipped; an engine error is shown per failed row. The
final line counts installed, skipped, and failed rows. Finishing first run does
not require installing. Undo Import leaves these separate user installs in
place. The automation-only fixture mapping uses signed local CRX3s and the
same consent sheet; production never installs from an Arc cache or payload.

The queue has no install timeout; a consent sheet can remain open indefinitely.
The offline App failure gate refuses a missing fixture before calling the
engine, reports the error, counts the failure, and continues. The separate
engine failure row is BLOCKED: local CRX initiation has no completion for a
damaged-signature rejection. The lead filed that engine need. A real production
Web Store failure receipt is INFO, with a two-minute harness observation bound
that never changes queue results.

The CLI prints counts only. An explicit manifest request writes only candidate
IDs, atomically with mode 600. It omits the destination path from its success
log. It refuses destinations inside Arc data or a repository outside `.re/`.
History destinations inside Arc data are also refused. Top Sites and site
engagement are not read. The import readers make no network requests; only an
explicit App extension-install click calls the engine's Web Store API. No
secret writer exists in OpenImport; engine password-store, cookie-store, and
autofill APIs remain a separate gate.

Verification on 2026-10-25, through the release `openkit` executable and the plan's throwaway synthetic Swift probes. Package builds used only `nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`, in a separate session. Commands used `.build/release/openkit` after building, to prevent implicit unrestricted builds. Probes lived in `/tmp` and compiled the production reader/crypto sources with optimization and Swift 6. No unit tests were added. Output was reduced to counts and timings.

| Verification | Result |
|---|---|
| Release package build | PASS; zero warnings, zero errors |
| History F1, first / repeat | PASS; 6 source visits, 3 kept, 1 internal, 1 subframe, 1 invalid time; inserted 3 / 0, duplicates 0 / 3; read/write checks OK |
| F1 stored aggregates and FTS | PASS; 3 visits, typed count 1; FTS matched the synthetic title |
| History F2 | PASS; 5,000 URLs, 100,000 visits inserted in 1.443 s, below 3.000 s |
| Real History, copied first | PASS; 12 URL rows, 24 visits; inserted 24 in 0.008 s; repeat inserted 0, duplicates 24 in 0.006 s; all accounting checks OK |
| Real `suggest`, offline and redacted | PASS; history rows increased from 0 to 6 |
| Missing History / out-of-range schema | PASS; exit 4; schema fixture version 99 refused |
| Open WAL, empty source, source protection | PASS; 4 kept WAL visits; valid empty import succeeds; source destination refused without source change |
| Write failure and empty invalid destination | PASS; exit 1; failed batch left 0 URLs, visits, and import keys; empty bad destination reports MISMATCH |
| Known-answer key derivation / AES round trip | PASS / PASS; no key or plaintext printed |
| Synthetic S1 | PASS; 1 login decrypted, 0 failed; no Keychain item created or accessed |
| Synthetic S2 logins | PASS; 6 rows: 3 OK, 2 failed, 1 blacklisted; includes legacy text, invalid UTF-8, malformed cipher, and fallback |
| Synthetic S2 cookies | PASS; 7 rows: 3 OK, 3 failed, 1 expired; domain hash, session, and plain-value paths covered |
| Synthetic S2 cards / addresses / form history | PASS; 4 cards: 1 OK, 3 failed; 1 address with 1 field, 1 form row, 1 keyword row |
| Live secrets without consent | PASS; 0 logins, 20 cookies, 0 addresses/cards, 27 keywords; Keychain not requested; stored 0 |
| Secrets without `--dry-run` / empty / absent files | PASS; exit 3 / zero rows and stored 0 / exit 4 |
| Live extension manifest | PASS; 3 total, 3 internal, 0 candidates; mode 600; manifest deleted |
| Synthetic extension union | PASS; 5 total, 2 internal, 3 candidates, 1 missing manifest; mode 600; manifest deleted |
| Existing `import-arc` / `roundtrip` | PASS / PASS; sidebar accounting and round trip OK |
| Existing `commands-demo` | PASS; 67 OK checks, 0 failures |
| Existing `suggest-check` | PASS; 31/31; local first-snapshot p95 1.919 ms |
| Existing `bench` | PASS; 100k URL insert 1333.4 ms; search p50 2.678 ms, p95 3.268 ms; bulk/index checks OK |
| Privacy and scope review | PASS; no new reads of Top Sites or site engagement, no network calls, no secret destination writes, no personal data staged |

Deviations from the earlier plan text: the Lead safety rule replaced test-Keychain and live Allow/Deny exercises with a known in-memory fixture password. No Keychain item needed deletion because none was created. The live consent/prompt path remains unverified. The writer adds the FTS guard and empty-destination success flag. The reader adds streaming and per-file validation APIs while preserving the requested APIs. Crypto adds explicit padding and modern cookie hash validation. Copying also includes `-journal`, as required by the brief. The manifest success line reports only its count. No engine build, desktop automation, secret storage, or real secret decryption ran.

All private source copies were deleted after reading. The real imported history and sidebar output were used only in a mode-700 temporary root and deleted after verification. Fixtures and manifests were never placed in the repository.

### PR #24 security corrections (2026-10-25)

Merged `origin/main` into `m8/import-phase2` first (`fb6d5aa`). The merge retains every package target and dependency, including OpenRouting and OpenScripting. The CLI help keeps both import commands and routing.

| Finding | Fix | Result |
|---|---|---|
| BLOCKING: CLI-only consent gate | Public final `SecretsImportConsent` has a private initializer and one explicit `grantedByUser(reason:)` factory. All six public Keychain/decrypt/read APIs require the token. The CLI issues it only after `--allow-keychain-access`. Internal reads carry user consent or access bound to a generated synthetic fixture. | PASS: external `swiftc -c` against the release module rejected all six calls without `consent` and rejected direct initialization. The same signatures compiled with a token parameter. No object was executed; scratch sources and object were deleted. |
| HIGH: unknown version prefixes accepted as plaintext | Every `v` plus two ASCII digits except `v10` throws `badPrefix`. Only unversioned blobs can use plaintext fallback. | PASS: generated login/cookie/card databases give `badPrefix=5` (v11 in each file, plus v20 and v99). Malformed v10 and invalid UTF-8 also fail; unversioned legacy values still pass. |
| HIGH: probe could prompt before warning | Probe query includes `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail` and an LAContext with `interactionNotAllowed=true`. The CLI prints and flushes “macOS may ask for Keychain access” before the first probe or fetch. | PASS by source inspection and external signature checks. Live Keychain prompt behavior remains UNVERIFIED under the Lead safety rule. |
| MEDIUM: copying live SHM | Copy the main DB and WAL in WAL mode; copy the journal only in rollback mode, selected from the copied database header. Delete stale private SHM and let SQLite rebuild it. Keep the 200 ms retry and required `PRAGMA quick_check`. | PASS: background Python writer added 330,900 visits during a successful WAL import. Private-copy quick_check is mandatory; destination quick_check returned `ok`. A hot rollback journal also recovered on the private copy and imported 10,000 committed visits. |
| MEDIUM: secret descriptions, retention, password copy | Redacted description/debug description and empty Mirror on login, cookie, address, and card records. Replace retaining arrays with borrowing callbacks. Swap byte ownership into each record and clear it after the callback. Derivation uses a mutable local password buffer and `withUnsafeMutableBytes`; deferred `zeroSecretBytes` uses `memset_s`. | PASS: real CLI fixture reports `redactedRecordKinds=4`, with `String(describing:)`, `String(reflecting:)`, and empty Mirror checks. Known PBKDF2 answer, AES round trips, and fallback paths pass. Buffer clearing is source-verified; this is not a heap-erasure proof. |
| MEDIUM: legacy cookies in schema 24+ | Strip 32 bytes only for a matching SHA256(host) prefix. Accept other valid UTF-8 as legacy and count it separately. Reject invalid UTF-8. | PASS: schema-24 fixture gives 5 accepted cookies, including 3 correctly stripped hash-prefixed values and 2 legacy values (`legacyNoHashPrefix=2`). All delivered values match the synthetic value. |
| LOW: temp-file creation and stale copies | Open destinations with `O_CREAT\|O_EXCL\|O_WRONLY\|O_NOFOLLOW`, mode 600, before copying. Startup sweep uses lstat, current-user ownership, directory type, prefix, and age >1 hour. Notices go to stderr to preserve JSON stdout. | PASS: CLI removed an old owned fixture directory and preserved a fresh directory, a symlink, and its target. Destination creation is source-verified; mode 700/600 was also observed during a real CLI copy of synthetic data. |
| LOW: invalid secret dates | Use the same positive Unix time through now+24h bound as History, with overflow-safe integer Chromium epoch conversion. Keep zero cookie expiry as the session-cookie sentinel. Validate address and form-history Unix timestamps too. | PASS: fixture reports 3 invalid login dates, 2 invalid cookie dates, 3 invalid address dates, and 3 invalid form-history dates; valid and session dates pass. Dates beyond the bound are counted and skipped, including far-future cookie expiry. |

The new `openkit verify-secrets-fixture` command generates its own example.com databases from a known in-memory password. It accepts no profile path, key, or ciphertext. Its public library entry point returns only counts and boolean results. It cannot be used to select real data or access the Keychain. The fixture covers the full database-copy → crypto → parser → borrowing-callback flow. It is a CLI verification command, with no unit-test target.

Release build command: only `nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`, in a separate process session. The build passed with zero errors and one SDK deprecation warning for the explicitly requested `kSecUseAuthenticationUIFail` constant. All commands used the prebuilt release executable. The final CLI-only rebuild also passed.

Additional regression results: F1 kept 3 of 6 visits and inserted 3 / 0 on first/repeat import; F2 inserted 100,000 visits in 2.602 s (<3.000 s). Real History gave 12 URL rows and 24 visits: first inserted 24 in 0.008 s; repeat inserted 0, duplicates 24 in 0.009 s. Existing `import-arc` accounted for 46/46 items; `roundtrip` passed; `commands-demo` passed 66/66; `suggest-check` passed 31/31 (local first-snapshot CPU p95 0.625 ms); `bench` passed (100k URL insert 2328.3 ms; search p50/p95 3.571/9.346 ms). Routing A1–A17 passed using only a synthetic commands-demo snapshot; A12–A17 exercised 35/48/3/11/4/6 CLI decisions. A11 used this synthetic snapshot, not the earlier routing review's private snapshot.

The external compile command used `xcrun swiftc -c -target arm64-apple-macos26.0 -I Packages/OpenKit/.build/out/Products/Release` with a tiny scratch source. The source called fetch, existence probe, pair probe, blob decrypt, readWithKey, and validateWithKey without a token. All six failed with `missing argument for parameter 'consent' in call`. The direct initializer failed with `private` protection. A separate unexecuted function that accepted a token compiled successfully.

No real Keychain item was read or created. No real Login Data, Cookies, or Web Data was decrypted or opened for this correction pass. No real secret consent run was attempted. All real sidebar and history output databases were deleted after verification. Counts-only receipts and synthetic driver files remain outside the repository under `/tmp/open-pr24-security-a9kcykir`; no personal data or generated data files are committed.

## Profiles (M5 core)

Implemented the model steps of [profiles.md](plans/profiles.md), including its Lead decisions. The App now repairs missing Profile references before host creation and on model installation, saves repairs, and reports the affected Space titles once. The model performs no I/O. No snapshot DTO changed; `schemaVersion` remains 1.

`createProfile` trims and validates names, rejects case-insensitive duplicates, and creates `Default` for the first Profile when that directory is available, or a unique `Profile-<8 uppercase hex>` name. Bootstrap reserves every existing `Profiles/` entry and every name in `State/retired-profile-dirs.json`, without case sensitivity. The deletion sink durably records that tombstone before removing the Profile. Undo and disk wipes retain the tombstone. Names have a 64-grapheme limit and reject path separators, colons, control characters, `.` and `..`. Rename never changes the directory. Default identity is the Profile whose directory is exactly `Default`, else the first Profile. Display order is array order.

`deleteProfile` refuses the default Profile and any Profile with assigned Spaces. It calls the throwing `archiveForProfileDeletion` path and waits for the FULL-synchronous SQLite commit before removing any model entries. An archive failure throws and keeps the Profile, Favorites, events, and undo stack unchanged. Redo failures reach `onArchiveError`. The model/CLI command remains undoable. Settings uses an irreversible flow: exact typed confirmation, directory capture, model removal with undo disabled, context release, disk cleanup, and `SnapshotStore.saveNow`. Older Undo actions are cleared. Open-owned files disappear at once. Loaded engine directories wait in the bounded, atomic, synced pending-wipe journal until the next launch, before the engine starts. Never-loaded engine/cache folders are removed immediately. Local State edits always wait for launch. `releaseContext` does not prove Chromium Profile destruction; see [profiles-shell.md](profiles-shell.md).

`moveSpace(id:toProfile:)` changes only the Space's Profile reference. Tabs keep their IDs, URLs and pinned URLs; Favorites remain with their owner Profile. It emits one `.spaceProfileChanged`, with an inverse event on undo. The combined `updateSpace` editor emits the same event and retains one undo step for all four edited values. A missing target Profile refuses the entire edit, with no event or undo step. `createSpace(...at:moving:)` refuses a missing Profile; the nonoptional overload requires a live Profile ID. `repairMissingProfileReferences` repairs dangling references in Space order, emits each change, and registers no undo. Snapshot mapping stays lossless; bootstrap/CLI maintenance owns repair.

`ProfilesSettingsModel` exposes ordered rows, name and delete reasons, command wrappers, the Profile indicator, and App-owned pending disk-wipe data. `spaceProfileChoices`, `SpaceCreationProfilePickerModel`, and `ChangeProfileRequest` supply the creation picker and confirm-before-move data. The picker starts with the window's focused Space Profile, then falls back to default. Failed Profile creation creates no Space. These types contain no views, persistence, engine calls, or UserDefaults writes.

The per-Profile layout is:

```text
<root>/State/browser.json                  global snapshot
<root>/State/favicons.sqlite3              global cache, deliberately shared
<root>/Profiles/<dataDirectoryName>/
  State/history.sqlite3
  State/archive.sqlite3
  State/sleep.sqlite3                      SleepStore(fileURL:)
  Boosts/boosts.json
  AdBlock/lists/                          future ad-block data
```

Chromium data lives separately at `<root>/Engine/<dataDirectoryName>/`.
Pending engine cleanup is recorded at `<root>/Profiles/.pending-wipe.json`.

`ProfileDirectories` owns these paths and creates empty directories. `OpenDataRoot.prepare()` runs migration before any store opens. Each history/archive/sleep SQLite set is copied into a staging `State` directory on the destination volume, flushed with `fsync`, and published with one atomic macOS directory swap. The JSON journal at `State/profile-migration.json` plus a commit marker resolves each interrupted step. Source cleanup follows durable publication and checks file identity, size, and modification time. Missing destination mains permit migration; destination orphan sidecars are retained under `State/.quarantine/`. A legacy WAL/SHM left by an older interrupted migration joins its destination main. Conflicting mains refuse store opens and retain the entire legacy set. Legacy symlinks are never moved: only regular targets inside the root are eligible; unsafe or dangling targets refuse the store and preserve the sources. This is a **ONE-WAY** disk-layout change: older builds ignore `Profiles/` and would open empty legacy-path databases. The favicon cache stays global and can disclose that some Profile visited an origin; no favicon isolation is claimed.

### Data-root lock

`OpenDataRoot.prepare()` returns a `Preparation` token with its canonical root
and `migrationReport`. Retain that token until the operation finishes. A
process-wide `Mutex` registry holds one fd and a reference count for each
`realpath` root. Repeated preparations, including symlink aliases, share the
same open file description. They do not take another BSD `flock` on a new fd.
Synchronous store queues can acquire and release references without an actor hop.
Migration and live-model directory setup still run on the main actor.

`SnapshotStore` retains a reference before reading snapshot bytes and across
its writes. Each SQLite connection retains its own reference until it closes,
including deferred SleepStore close. CLI bootstrap tokens cover the interval
before SQLite opens. The last reference unlocks and closes the fd and removes
the migration-cache entry. A later preparation rechecks migration on disk.
Failed acquisition or migration releases its temporary reference.

The file remains `State/.profile-data.lock`. Acquisition uses `LOCK_EX | LOCK_NB`
and `O_CLOEXEC`: another process using the same root fails at once with a
`lock data root` error. Different roots have independent locks. The lock file
stays on disk after release; its presence alone does not mean the root is busy.

Verification on 2026-10-25 (America/Vancouver), using the release `openkit`
and fresh synthetic roots only:

| Lock check | Result |
|---|---|
| `commands-demo`, 50 iterations | PASS: 103 checks per run; zero lock failures |
| `sleep-demo`, 50 iterations | PASS: 105 checks per run; zero lock failures; the second SQLite connection reloaded the same history in every run |
| Two processes, same root | PASS: pause the first `commands-demo` after observing its kernel lock; `profiles DIR list` exits 1 in 0.131 s with `lock data root` / `Resource temporarily unavailable`; the first then completes successfully |
| Two processes, symlink alias of the same root | PASS: the second process exits 1 with the same lock error in 0.122 s |
| Two processes, different roots | PASS: both hold their root locks concurrently, then both `commands-demo` processes finish with exit 0 |
| Root after its owner exits | PASS: a new `profiles DIR list` exits 0 |
| Last reference released before process exit | PASS: observe the `sleep-demo` review scenario root go from locked to unlocked; pause that still-live process and run `profiles` on the released root, exit 0; resume the first process, 105/105 and exit 0 |

The external Python drivers only launch the real CLIs, observe kernel `flock`,
and pause/resume their own child processes. Receipts and drivers are outside
Git at `/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-dataroot-fix-dkc382ib`.
The full runner result is recorded in [verification.md](verification.md).

### Profiles bootstrap

Bootstrap contract: load → migrate → repair → ensure directories → attach `ProfileArchiveSink` → observe events → save after commands. Profiles CLI mutations save repairs even if the requested command refuses, except deletion: an archive failure must not save any snapshot changes. A `list --json` result keeps maintenance notices on stderr. `suggest --history DIR` selects that snapshot's default Profile history file; a direct path must be `…/Profiles/<dir>/State/history.sqlite3`. The old `State/history.sqlite3` path is a usage error.

Import reserves `Default` for the actual default key, suffixes named claimants as `Default-named` (then numbered collisions), and always materializes that default key. Re-import preserves each matching Profile ID's directory, while new named Profiles avoid disk directories and tombstones. An unowned reserved `Default` directory refuses import. Import resolves all Space and `topApps` Profile refs, uses lenient Storable metadata and `Local State` precedence, preserves deterministic IDs, sanitizes directory basenames, and suffixes case-insensitive collisions. Space links missing from the sidebar can come from `StorableProfileContainers.json`. Local State directories with no Space still produce Profiles. The report prints Profile counts, guessed mappings, source-directory presence, and per-Profile Space/Favorite counts. Chromium data is recorded by the mapping; no engine files are copied. The real two-Profile install now confirms the nested custom reference in both Spaces and Favorites: 6 Spaces split 4/2 and 11 Favorites split 6/5. `StorableProfiles.json` and `StorableProfileContainers.json` remain unobserved, so those optional parsers remain guesses. See [the import audit](import-multiprofile.md).

Boosts landed before this change. `BoostStore(root:profileID:fileURL:)` now accepts the canonical `ProfileDirectories.boostsFileURL(for:)` destination without adding an OpenStore dependency. Its original standalone constructor remains compatible. The future App must pass the explicit Profile file URL; see [boosts.md](boosts.md).

### Profiles verification (2026-10-25)

Every package build used only `nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`. Baseline and final release builds passed with zero warnings and zero errors. Baseline `commands-demo` was 66/66; the final extension is 102/102. Merged `origin/main` (`f4f87da`) before final verification; no conflicts occurred and every existing package target remained present.

| Check | Observed result |
|---|---|
| P-1 | Empty root: `no snapshot at DIR`, exit 0 |
| P-2 | Personal gets `Default`; Work gets `Profile-XXXXXXXX`; 2 Profiles and all empty directory trees |
| P-3 | Duplicate `work` refused, exit 1; snapshot SHA-256 unchanged |
| P-4 | Work Space created on Work; Work has 1 Space, Personal 0 |
| P-5 | Assigned Work delete refused, exit 1; snapshot SHA-256 unchanged |
| P-6 | Work Space assigned to Personal; Work 0 Spaces, Personal 1 |
| P-7 | Default Personal delete refused, exit 1; snapshot SHA-256 unchanged |
| P-8 | Temp deleted, 0 archived Favorites; its disk directory remains |
| P-9 | Copied live JSON: 46/46 sidebar accounted, 10/10 archive accounted (9 imported, 1 skipped); 1 Default Profile, 4 Spaces, 6 Favorites; repeat inserts 0; roundtrip OK |
| P-10 | Dump shows the assigned Profile; roundtrip OK; schema 1 |
| P-11 | Rename and emoji survive reload; directory unchanged. Used the stable UUID for set-icon after rename because the plan's old `Work` name no longer resolves |
| P-12 | Legacy history/archive/sleep and WAL/SHM bytes moved intact; second call moves 0; existing destination and skipped legacy source preserved |

Additional Profile checks: invalid and duplicate names, unknown/ambiguous surface errors, missing snapshots, same-Profile refusal, malformed options, and repair saved before a refused mutation. The real CLI demo proves accepted-command undo after refusals, rename/icon/settings undo and redo, exact Space-change events, combined editor undo, unchanged tab identity/pinned URLs, Favorites staying with their owner, one-call Profile deletion, per-Profile archive routing, undo discard, repair without undo, and index consistency.

Synthetic import fixtures passed with two Profiles, one Space and one Favorite each, metadata precedence, stable IDs on repeat, ProfileContainer-only Space links, an unused Local State directory, unknown shapes/refs, unsafe directory names, and both case-only and exact directory collisions. No real multi-Profile Arc session was created or launched.

A temporary Swift caller loaded a copied real import, exercised Settings and picker commands, saved and reloaded the snapshot, checked default/assigned delete blocks, failed-create behavior, focused-window selection, and change-confirm data. It also verified the explicit disk wipe affects only its temporary Profile directory and that Boost files reload separately for two Profiles. The old BoostStore constructor still works. The caller used the Swift interpreter over a temporary dylib linked from the already-built release objects; no extra package build or test target was added. A separate real CLI migration of an actual SQLite WAL set retained 100 committed rows and returned `PRAGMA quick_check = ok`.

| Regression | Result |
|---|---|
| `import-arc` on a temporary copy of live `*.json` | PASS, sidebar 46/46 and archive 10/10 accounted; repeat stores 0 new rows |
| `roundtrip` | PASS on pre-change import, new import, profile CLI sequence, and both demo roots |
| `commands-demo` fresh + copied import | PASS, 102/102 each; default archive rows 19 and 28 |
| `suggest-check` | PASS, 31/31, including its local HTTP flows |
| `commands-dump` | PASS, `commands-dump OK` |
| `route` A1–A17 | PASS; A12–A17: 35/48/3/11/4/6 CLI decisions |
| `favicons` | PASS, 1,000 synthetic ingests and 10,000 lookups; stats, missing-icon failure, and empty fetch |
| `bench` | PASS, including 100k history URLs and 2,000 expired tabs through the composite archive sink |
| `verify-secrets-fixture` | PASS; generated fixture only, no real Keychain access |
| `suggest --history` | PASS for root and per-Profile file; old global file rejected with exit 2 |
| Adblock / sleep CLIs | Not present in merged main; no claim of verification |

Counts-only receipts and temporary drivers are under `/tmp` (the OS temporary directory). Copied user JSON and generated data were never committed. No Arc launch, desktop control, engine-tree command, engine build, unit test, or subagent was used.

Deferred: engine contexts, cross-Profile live content recreation, cookie/incognito isolation, per-context memory measurement, App persistence/confirmation/wipe wiring, real multi-Profile capture, idle context eviction, download-location settings, tab-level cross-Profile moves, and Chromium engine-data import. These are separate engine/App or later milestone gates; this CLI result does not claim them.

### PR #32 data-safety corrections (2026-10-25)

Merged `origin/main` at `006752759f02aae305b5b541dc382ca2f67d8e89` first
(merge commit `50b7400`). The only conflict was the additive CLI usage text;
Profiles and OpenSleep both remain in `Package.swift`. Every build used
`nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`.
The final build passed with zero warnings and zero errors.

| Finding | Fix | Result through the real CLI on temporary roots |
|---|---|---|
| 1. SQLite main/WAL/SHM could be split by a crash | Stage the complete set inside a destination-volume State directory; fsync files and directories; publish with one directory rename/swap. A durable JSON journal and marker drive recovery before source cleanup. Check source identity before removing it. | PASS: 27 injected abort boundaries across history, archive, and sleep; every resume retained 100 committed rows and `PRAGMA quick_check = ok`. A second run was inert. Changed sources after publication were preserved and refused. |
| 2. Orphans and store-open order stranded legacy data | `OpenDataRoot.prepare()` is shared by snapshot loads and all direct-store CLI/bench/suggest/Sleep paths. Quarantine destination sidecars when its main is missing. Resume legacy sidecars when a prior migration already moved the main. | PASS: destination orphan quarantine, older partial main/WAL migration, conflicting-main refusal, and legacy orphan-only refusal. CLI startup probes for dump, roundtrip, archive-list, commands-demo, route, suggest, and sleep-sim all stopped before store open. A separate suggest history root also prepared first. |
| 3. Profile deletion could drop Favorites after a failed archive | Throwing confirmed archive path waits for SQLite FULL commit before model removal; failed deletion does not save even load repairs. | PASS: `chmod 000` archive DB caused exit 1; snapshot SHA-256, Profile, and Favorite stayed intact. After unblocking, deletion committed exactly one archived Favorite. Existing undo/redo flows passed. |
| 4. `updateSpace` accepted a stale Profile ID | Refuse the whole edit before changes, events, or undo registration. | PASS: the real `commands-demo` flow now checks the stale-ID combined edit; 103/103 on fresh and imported roots. |
| 5. Named imports could take the default Profile identity | Only Arc's default key gets `Default`; named claimants get `Default-named` plus collision suffixes. Always materialize the default key. | PASS: a synthetic Arc fixture encountered the named claimant first; it remained non-default and Arc's default key remained default. Repeat import kept stable IDs/directories. |
| 6. Deleted directory names could be reused | Bootstrap reserves all existing `Profiles/` entries and durable `State/retired-profile-dirs.json` tombstones without case sensitivity. Both model creation and import honor reservations; matching import IDs retain their own directory. | PASS: delete/create picked another directory; mixed-case disk and tombstone reservations blocked `Default`; deleting and wiping a named import then re-importing chose `Default-named-2`. Unowned reserved Default data refused import and stayed intact. |
| 7. Legacy symlinks could move links or escape the root | Resolve legacy links; accept only regular targets inside the data root; refuse unsafe stores before opening them. Never move the link itself. | PASS: inside-root history target plus WAL retained 100 committed rows; outside-root target hash and original link stayed unchanged with exit 1. |
| 8. CLI reported success after a failed snapshot save | `SnapshotStore.saveNow` throws; durable atomic writes propagate errors; all CLI save sites use `try` and print success only after commit. | PASS: simulated disk full exited 1 with a clear error, no success line, and unchanged snapshot SHA-256. |

The failure switches are explicit diagnostics:
`OPENKIT_DEBUG_MIGRATION_CRASH=journal|copy-<filename>|staged|published|cleanup-<filename>`
exits 86 at that migration boundary. `OPENKIT_DEBUG_SNAPSHOT_WRITE_FAIL=1`
throws a simulated ENOSPC before the snapshot write. No isolated tests or
mock stores were added.

The now-implemented `SleepStore(fileURL:)` uses
`ProfileDirectories.sleepFileURL(for:)`. Its CLI adapter selects the owning
Profile for each tab. The Sleep benchmark now gives its four Profiles four
separate directories; committed row counts were 0/5/5/5 (15 total).

| Required verification | Final observed result |
|---|---|
| P-1–P-12 | PASS, including refused-mutation snapshot hashes, persisted icon/rename, default rules, and migration reruns |
| Copied live Arc `*.json` import | PASS: sidebar 46/46 and archive 10/10 accounted; 9 imported archive rows; repeat inserts 0 |
| `roundtrip` | PASS on profile sequence, imported snapshot, and routing legacy fixture |
| `commands-demo` | PASS: 103/103 on fresh root and copied import |
| `suggest-check` | PASS: 31/31, including local HTTP flows |
| `commands-dump` | PASS, exit 0 |
| `route` A1–A17 | PASS; A12–A17 used 35/48/3/11/4/6 CLI decisions |
| `sleep-demo` | PASS: 105/105; full 5,000-tab controller pass p50 0.336 ms, p95 0.799 ms, max 10.124 ms over 200 passes |
| `sleep-sim` | PASS: 48-hour gate and quiet-phase checks; 27 stored rows |
| `bench` | PASS: 100k history URLs; complete move/undo index checks; 2,000 archived rows |

Two preliminary Sleep runs each retained **FAILED: 104/105**, solely for
p95 timing (2.828 ms and 2.677 ms). The host then had active engine compiler,
Open renderer, and backup processes. Those results are retained; the final
run above used the final per-Profile fixture and passed the unchanged 2 ms
p95 limit. No background process was stopped and no threshold was changed.

Receipts and temporary CLI drivers are under `/tmp/open-pr32-final-evidence`;
preliminary receipts remain under `/tmp/open-pr32-evidence`. A supplemental
probe initially tried to delete an assigned Profile and correctly refused;
the corrected sequence moved its Space first. All copied user JSON and
full CLI trees remain outside Git. No Arc launch, desktop control, engine
build/sync, unit test, or subagent was used. App/engine isolation gates stay
deferred as listed above.

## openkit CLI

`Sources/openkit/main.swift` has one append-only `(name, handler)` table. Both dispatch and usage derive from it; registering a command adds one entry.

```text
openkit import-arc [--arc-dir PATH] --out DIR [--show-titles|--counts-only]
openkit import-arc-history --arc-user-data DIR --db PATH [--profile NAME]
openkit import-arc-secrets --arc-user-data DIR [--profile NAME] --dry-run [--allow-keychain-access] [--out-manifest PATH]
openkit verify-secrets-fixture
openkit archive-list DIR [--limit N] [--profile PROFILE]
openkit dump DIR
openkit roundtrip DIR
openkit bench
openkit commands-demo DIR
openkit profiles DIR list [--show-titles] [--json]
openkit profiles DIR create --name NAME [--icon emoji:TEXT|symbol:NAME] [--json]
openkit profiles DIR rename PROFILE --name NAME
openkit profiles DIR set-icon PROFILE [--icon emoji:TEXT|symbol:NAME|none]
openkit profiles DIR assign-space SPACE --to PROFILE
openkit profiles DIR create-space --title TITLE --profile PROFILE
openkit profiles DIR delete PROFILE
openkit profiles DIR show PROFILE [--show-titles]
```

`import-arc` imports, saves through `SnapshotStore`, stores archive records through `ArchiveStore`, prints the report, then prints the tree. The report holds sidebar counts, archive counts (file total, imported, stored new, stored duplicates, stored total, skipped by kind, and the archive accounted check), session mapping counts, and the final sidebar accounted check.
`archive-list` lists stored archive rows, newest first. It prints the row ID prefix, host only, reason, and archive time. Titles print as `•••`. `--limit N` caps the rows shown. The total row count always prints.
`--counts-only` omits the tree and per-Profile directory names; known icon identifiers are printed with counts, and unknown names are reported as a count only. Titles and URLs are redacted by default. The tree prints item kind, ID prefix, and host only. `--show-titles` prints full titles and URLs. Never paste `--show-titles` output into docs.
`dump` loads a snapshot and prints the tree (redacted).
`roundtrip` loads, saves, reloads, and compares the two DTOs byte for byte. It exits non-zero on a mismatch.
`bench` builds a synthetic model (5,000 items over 10 Spaces) and times snapshot encode / decode / save / load. It inserts 100k history URLs and times 1,000 selective searches (p50 / p95). Then it times `moveNode` ×10,000 on a 5,000-item model (with and without an UndoManager), undoes every move, and times `archiveExpiredTabs` on 2,000 expired tabs (model only, then with the real `ArchiveStore`).
`commands-demo` runs every command against the real `ArchiveStore` in `DIR` and prints OK or FAIL for each check (103 checks), plus the tree at key steps. It covers: new tab, pin, folder; a split in a folder (allowed) with undo and redo; favorite move and unfavorite with undo and redo; placement rejections (split or folder into Favorites, a favorite into a split, a folder into its own descendant) with no events and no undo; a pane close that collapses its split, with undo; pinned to Today moves that clear `pinnedURL`, for a tab and for a folder with a split inside, with undo; close, archive, restore, with undo and redo; both restore fallbacks; restore into a split; `deleteSpace` with undo; `clearToday` with undo and redo; `archiveExpiredTabs` with a fake clock; undo after auto-archive changed the tree, and the Profile command flows described above. It exits non-zero on any failure.

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

## Model followup verification (2026-10-25)

Merged `origin/main` at `5de74ee` before the final release build. Every build
used `nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`; the final
build had no warnings or errors. No unit tests or subagents were used.

| Real CLI / check | Result |
|---|---|
| `commands-demo` on a fresh root and a copy of the imported root | 115/115 each; both roundtrips OK |
| `sidebar-render check` | 103/103: the prior 81 plus 22 checks for live-state glyphs/actions, collapse/mute undo, Space titles/reordering, and named symbols |
| `import-arc --counts-only` on a temporary copy of live top-level JSON | Sidebar 46/46 and archive 10/10 accounted; 2 welcome tabs imported, 0 skipped; 1 untitled Space remains nil; named icons `planet=1`, unknown 0 |
| Import repeat and snapshot roundtrip | 0 new archive rows; roundtrip OK; copied inputs unchanged |
| Synthetic files through `import-arc` | All 55 named icons retained; 1 unknown reported with neutral fallback; orphan and archived welcome tabs imported; missing sidebar refused |
| `NSImage(systemSymbolName:)` in `sidebar-render check` | All 55 mappings plus the fallback exist on macOS 26 |
| `suggest-check` | 31/31 |
| `sleep-demo` | 105/105 |
| `adblock perf` | Lookup p95 0.1370 ms (<1); profile open p95 4.9870 ms (<10); 5,000 matches |
| Profiles P-1 through P-12 | PASS, including refusal snapshot hashes and legacy SQLite migration |
| Frozen sidebar renders against the existing baseline executable | All 13 state PNGs byte-identical; the Arc error tables in design.md §8 are unchanged |

The fixed archive clock in `commands-demo` predates imported activity, so the
demo's four expired tabs remain the only expiry candidates on a copied import.
Raw copies, rendered captures, logs, and temporary drivers stayed outside Git.
Engine unload wiring remains deferred; welcome items use a normal tab to the
public welcome page rather than Arc's native onboarding controller.

## Open design questions

1. Restore position. A restored tab goes to the top of its parent, because the record stores the parent but not the index. Arc's exact position is not verified.
2. `focusSpace` and `selectNode` register undo. Arc probably does not undo navigation. If not, Cmd-Z after a click would undo the click, not the last edit. Verify in Arc, then drop their undo.
3. `closeTab` archives pinned tabs and favorites too. In Arc, closing a pinned tab or a favorite may only unload it (guess). The UI layer must pick the right command until this is verified.

## Sidebar completion M1 (2026-10-26)

The bulk commands `moveNodes`, `archiveNodes`, `setPinned`, and `duplicateNodes`
use one undo step and per-node structural events. Bulk drop indexes count in the
destination before removal; single-node `moveNode` keeps its existing contract.
Selections skip duplicate IDs and descendants of selected containers. Split panes
are refused by moves and close through the existing collapse primitive on archive.
That primitive also emits a parent reload when a split collapses.

`createFolder` accepts an insertion index. Space commands expand/collapse every
folder, reset navigated pinned tabs, separate a navigated pin into Today, and turn
a Space into a folder in another Space. Clear can keep selected nodes or their
ancestors. Background tab creation and Move to Space support persisted unread
flags; undo restores old flags. The model adds no UI action names.

Release CLI verification: `commands-demo` 151/151; B1–B14 and unread/Clear flows
PASS; `roundtrip` PASS on the sidebar fixture. The existing `openkit bench` move
averages were 3.42 → 3.15 µs with undo and 2.29 → 2.08 µs without undo (within
10%); undo restored the tree and index. No unit tests, App edits, or desktop input.
The initial checkout did not yet have `iconOverride`; copies retain all fields
present there. Final merged-main verification is recorded in the PR.
Snapshot scheduling marks the live model dirty without preparing folders or
building a DTO. The one-second debounce captures the DTO on the main actor,
then queues the atomic file write. `saveNow(model:)` remains synchronous and
cancels pending generations. `flush()` captures pending dirty state on the main
actor before waiting for writes. Frame notifications only update window fields
and schedule this save; they do not notify the engine factory or tab mirror.

## Sidebar completion M2 (2026-10-26)

Delete (`closeTab` on a folder, or a folder in `archiveNodes`) now archives one
folder record with reason `folderDeleted`. `archiveFolder` provides the same model
behavior. No Archive Folder menu or command is added. `ArchiveRecordKind` is
explicit: old rows, including old `folderDeleted` rows, stay tabs. Mixed bulk
archives use one sink batch and one SQLite transaction per Profile. Folder payloads
retain nested folders, splits, original IDs, and customization. The optional
`originalSection` payload key preserves Pinned/Today fallback after a parent is
removed; the parent UUID alone cannot recover that information.

The archive opens and adds `kind TEXT NOT NULL DEFAULT 'tab'` with schema version 1
in one FULL-synchronous transaction. Repeat opens are inert. Diagnostic switch
`OPENKIT_DEBUG_ARCHIVE_MIGRATION_CRASH=alter|version` exits 86 before commit so the
real CLI runner can verify rollback and recovery. Existing row payloads are not
rewritten. Folder restore skips live child IDs, uses the original parent or section,
then a Today Space in the archived Profile (using the same fallback as tabs), and refreshes activity. One undo writes the folder row back.
Library folder child counts are decoded once per loaded page and cached by row ID; reload clears them. The Library saves the sidebar snapshot before deleting the archive row and rolls
back insertion on a save failure. It shows a folder glyph, a recursive tab count,
and "Folder restored to <Space>. Click to view." with View.

Release harness verification: `commands-demo` 166/166 including FA1–FA7 and the
M1 checks; `settings-preview check --only library-folder-archive` PASS for L2/L3,
View, durable save failure, and legacy row meaning. No unit tests or desktop input.
App restore-last-closed dispatch by record kind remains App-lane wiring.

### M2 Muse review corrections (2026-10-26)

Merged main after M1's squash merge; the PR diff contains only the M2 files. Folder
restore now preserves the archive Profile when the original Space is gone. FA3
uses two Profiles with A visible and a surviving B Space. FA4 also keeps one
archived split pane live in another split and checks the single-pane collapse.
FA7 checks the snapshot roundtrip only; the unrelated ArchiveStore before/after
comparison was removed. Library folder counts decode once per page load, cache
by row ID, and clear on reload. A failed archive-row deletion after folder restore
says "Folder restored", with a real SQLite delete-failure CLI scenario.

## Sidebar completion M3 (2026-10-26)

`Tab.displayTitle` now uses `customTitle ?? TidyTitles.tidy(title:url:)`. The
Open-written rule table follows sidebar-completion §3.7 for Gmail, Google Docs,
Drive, Calendar, YouTube, GitHub, X/Twitter, LinkedIn, Wikipedia, Stack Overflow,
Figma, Slack, Outlook, and Amazon. Host matching is exact after removing one
leading www. The first matching rule wins. Empty results keep the raw title.
No Arc JSON values were read or copied. Raw `Tab.title`, snapshot values, and
suggestion-search inputs are unchanged.

Regexes compile once. A main-actor cache holds at most 512 title/host/path/fragment
keys. The real commands-demo flow passes 40 fixture pairs, custom-title precedence,
no-match and empty-result cases, and snapshot roundtrip. T3 p95 was 0.334 µs for
10,000 cache hits and 4.875 µs for 1,000 misses (limits 5/50 µs). All 170 demo
checks pass. No suggestion code or suite checks changed.

The 13 capture-state comparisons could not run: `.re/vf/run-states.sh` and its
capture-time inputs are absent from this checkout and the current project/worktrees.
The full `sidebar-render check` remains part of verify-all; lane S owns TT1/TT2.
No claim of capture parity is made for this step.

## Sidebar M1 Muse follow-up (2026-10-26)

Bulk moves build one original-slot map per parent and use prefix removal counts to
update positions without per-node list searches. The primitive validates a supplied
slot before removal; the existing single-node path retains its normal lookup.
Same-slot nodes emit no move. Move to Space marks unread only on descendants of
actually relocated nodes and leaves every flag untouched with markUnread false.
Bulk archive builds each parent position map once, sorts by those values, and
removes known slots from highest to lowest (split collapse retains its existing path).

The CLI now asserts exact B4 removal IDs/order, B7 fresh IDs at every depth plus
split focus/fractions/orientation, and unread true/false through folders and splits
from two source Spaces. It also checks a same-slot pin stays read and a middle drop
with selected nodes on both sides. `commands-demo` passes 156/156 on the M1 base.

`openkit bench` runs 20 real command/undo rounds at 50 and 500 nodes, with exact
event counts, byte-equal undo snapshots, index checks, and the real SQLite sink.
Release p95 (ms): 50-node move/reorder/archive = 0.269/0.216/0.452;
500-node = 1.335/1.174/2.087. The 50-node 16 ms budget passes. No unit tests or
new target, dependency, timer, App edit, or desktop input was added.

## Sidebar completion M4 (2026-10-26)

Open's two sounds are generated from fixed-seed PCM with the Python standard
library and converted by afconvert. `tools/generate-sounds.py --check` regenerates
both files and compares their pinned SHA-256 and committed bytes. `SoundEffects`
loads AVAudioPlayer lazily, reads `open.advanced.playSoundEffects` at each use, and
loads/plays nothing when it is absent or false. The default remains false; there
is no production caller for the general event effect (lead Q6). The license
inventory records these assets as Open's own work, with no recorded reference audio.

The existing SettingsDefaults registry now owns the three sidebar hint/banner keys.
The lead Q3 Previews sources use `open.general.previewsFolders` and
`open.general.previewsPages` in the same UserDefaults store. ProfileSettings is
unchanged. The Previews sheet replaces its former hovering-links switch with
Folders and Pinned tabs and Favorites. The registry in settings-library.md records
the exact keys; no second settings store is introduced.

The release `features-render check` passes 150/150: SE1 loads the real bundled CAFs
at 0.450 s / -6.000 dBFS and 1.100 s / -8.000 dBFS; SE2 proves absent and false
preferences neither load nor play. The Settings CLI verifies defaults, disk writes,
and reload through the existing store. `features-render` and sound regeneration now
run in verify-all. No audio playback, unit tests, App edits, or desktop input.

## Sidebar completion M5 (2026-10-26)

LibrarySection.spaces is the first Library row. It hosts the native view supplied
by `SettingsActions.makeSpaceManagerView() -> NSView?`, through a source-compatible
optional SettingsActions injection in LibraryViewModel. The view is created only
on first entry, retained across section switches, and constrained to fill the host.
OpenSettings imports no OpenSidebar code and adds no library target. A nil factory
result shows the Library empty state. Spaces has no unrelated archive/search toolbar.
The selected section persists in the existing UserDefaults registry.

`settings-preview check --only library-spaces` passes L1 through the actual Library
view and the injected labeled native stand-in. It verifies lazy creation, render,
reuse, section persistence, and a nil factory. The empty-state check uses the native
headline AX label, as existing offscreen Library checks do; SwiftUI's combined
message label is not exposed in a never-ordered window. The normal render command
also includes Library Spaces at 1x and 2x. App presentation and the concrete sidebar
SpaceManagerView remain their separate lane steps. No unit tests or desktop input.

M5's first integrated full run passed all 35 Settings checks but retained a FAIL
in the render inventory gate: the first-run merge fixed its count at 214, while
Library Spaces adds two images. The verifier now requires exactly 216 and explicitly
requires both Library Spaces scales. The prior FAIL receipt remains in the run logs.
