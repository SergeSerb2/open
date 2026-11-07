# Profiles — implementation plan for Open

Section 10 shell errata (2026-11-06): the App deletion flow supersedes the
separate wipe and undo wording in §3.4, §5.5, §6.5 and §7.1. Settings asks
for the exact Profile name, or `DELETE` for unused Profiles. It captures the
directory, deletes the model with undo registration disabled, tears down the
context, wipes Open-owned files, then calls `saveNow`. It clears older Undo
actions so create/redo cannot restore the deleted identity. The model/CLI
command remains undoable when used outside that irreversible App flow.

`releaseContext` proves page closure only. An engine directory loaded during
this launch stays on disk until the next launch. A bounded, atomic, synced
`Profiles/.pending-wipe.json` journal records cleanup. Before engine startup,
the App removes those engine/cache directories and their `Local State`
`profile.info_cache`, `last_used`, and `last_active_profiles` references.
Never-loaded engine/cache directories are removed in-session; their Local
State cleanup still waits for launch. No restart prompt is shown.

App bootstrap and every `installModel` path repair missing Profile refs and
save repairs. The first standard window shows one informational sheet with
the affected Space titles. Settings rows use Section 4's shared icon picker.
Header geometry and the more-than-one-Profile visibility rule are **guess
S10-I1**; editable Profile icons and a new Little Open page for a Profile
without a Space are also guesses. See [profiles-shell.md](../profiles-shell.md)
for the acceptance receipt and evidence limits.

Status: plan for implementation. Implementer: follow this file top to bottom.
Do not spawn subagents (AGENTS.md rule 8). Do not write unit tests (rule 6).
Verify end to end only: real `swift build`, real `openkit` CLI on real
snapshots, and (for the engine steps) the real app / `cefsimple` against a
local test server. This file is the complete context. The implementer has no
other context. If a fact in this file conflicts with a real file in the repo
or in `~/Developer/open-engine`, stop and report the conflict. Do not redesign
silently.

Authoritative inputs (read before you start):

- [AGENTS.md](../../AGENTS.md) — locked decisions and hard rules. User-visible
  text never uses the Arc brand (exception: "Import from Arc"). Swift 6 +
  AppKit, macOS 26+. The Swift shell talks only to `OpenEngine`, never to
  Chromium or CEF directly.
- [architecture.md](../architecture.md) — module borders: `OpenModel` has no UI
  and no I/O; all state changes go through named commands on `BrowserModel`;
  one CEF request context and cache path per Open Profile (persistence table);
  root is `~/Library/Application Support/Open/`.
- [model.md](../model.md) — the implemented M1 model. `Profile` already has
  `id`, `name`, `icon`, `favorites: [Tab]`, `settings`, `dataDirectoryName`;
  `Space` already has `profileID`. Commands, undo, `TreeChange`, and the
  `openkit` CLI patterns in that file are the contract this plan extends.
- [routing.md](../routing.md) — `LinksSettingsModel` is the settings-data
  pattern to mirror (§7 of this plan): `@MainActor @Observable`, no views, no
  persistence, `issues()` validation, App owns saving.
- [features-core.md](../re/features-core.md) §5 — what Arc isolates per
  Profile (proven): cookies, history, logins/passwords, extensions,
  Favorites, auto-archive thresholds, ad-block lists, download location,
  search engine, site permissions, memory. Many Spaces share one Profile;
  one Space has exactly one Profile (§2.6 rule 15, §5).
- [data-model.md](../re/data-model.md) §2.6, §4, §5 — Arc profile refs
  (`Space.profile`, `topApps` `ProfileRef`), `StorableProfiles.json`,
  `profileDirectoryBasename`, and the Chromium `User Data/<dir>/` mapping.
  Multi-profile field names are **inferred**, single-profile is confirmed.
- [memory-design.md](../memory-design.md) and
  [memory-fork.md](memory-fork.md) §7.5 — the planned `SleepStore`. This plan
  fixes its on-disk path per Profile (§5). Memory S0 is not implemented yet,
  so there is no migration cost for that change.
- [adblock-design.md](../adblock-design.md) and
  [adblock-fork.md](adblock-fork.md) §9.2, §12.3 — the per-Profile ad-block
  engine service (one `Engine` per Profile / `CefBrowserContext`) and its
  `<profile-dir>/AdBlock/` storage. This plan defines `<profile-dir>` exactly
  (§5.2), which that plan left as "the cache path's parent convention".
- [boosts-zap.md](boosts-zap.md) §4 — the planned per-Profile Boost store.
  This plan supersedes its file path (§5.2). `OpenBoosts` is not implemented
  yet, so there is no migration cost for that change.
- `docs/engine-api.md` does **not** exist. There is no `App/` target and no
  `Engine/OpenEngine/` yet (`Packages/OpenKit/Package.swift` has only
  `OpenModel`, `OpenRouting`, `OpenStore`, `OpenImport`, `OpenSuggest`,
  `OpenCommands`, `OpenScripting`, `openkit`, `commands-dump`). §6 therefore
  **assumes** a minimal `OpenEngine` interface and lists it in full (§6.6).
  Only the App adapter touches it. OpenKit never imports it.

Prerequisite gate (check first, stop if false):

1. `git status` is clean enough that you can name every file you touch. Work
   on a feature branch, one PR per milestone step group (§10).
2. Baseline build is green:
   `nice -n 10 swift build -c release -j 6` in `Packages/OpenKit` — zero
   warnings, zero errors. Baseline CLI: `.build/release/openkit commands-demo
   <fresh DIR>` prints `66 checks passed, 0 failed`, and
   `.build/release/openkit roundtrip <DIR>` prints `roundtrip OK`.
3. Never run `gclient`, `gn`, `ninja`, `autoninja`, or `git` commands in
   `~/Developer/open-engine/chromium_git`. That tree is read-only for this
   plan (a build is running). CEF facts below were read from
   `chromium/src/cef/include/cef_request_context.h` and
   `chromium/src/cef/include/internal/cef_types.h` (CEF branch 8078,
   Chromium 156.0.8078.48).

How to use this plan:

1. Work §10 in order. Each step lists exact files, signatures, and acceptance
   checks. A step is done only when every check passes. Paste real command
   output into the PR description.
2. Steps 1–5 need **no engine**. Steps 6–7 are marked **[NEEDS ENGINE]** and
   must not start until the engine spike delivers the §6.6 interface (or the
   lead re-scopes them). Do not invent a second CEF wrapper to fill the gap.
3. Names: Swift types use the `Profile…` prefix already in the codebase
   (`Profile`, `ProfileID`, `ProfileSettings`). User-visible strings say
   "Profile" and "Open", never "Arc" (exception: "Import from Arc").

---

## 0. Scope and non-scope

### 0.1 In scope (this plan)

| Area | Deliverable |
|---|---|
| Model commands | `createProfile`, `renameProfile`, `setProfileIcon`, `updateProfileSettings`, `deleteProfile`, `moveSpace(id:toProfile:)`, default-Profile rules, missing-Profile repair, undo, `TreeChange` (§3) |
| Disk layout | `Profiles/<dataDirectoryName>/` tree for engine data + per-Profile Open stores; `ProfileDirectories`; migration from the current single-Profile layout (§5) |
| Engine contract | Lazy `CefRequestContext` per Profile, `root_cache_path`/`cache_path` rules, cross-Profile Space switch in one window, incognito as an ephemeral Profile (§6) **[NEEDS ENGINE]** |
| UI data | `ProfilesSettingsModel`, Space-creation Profile picker data, Change-Profile menu data, Profile indicator data. Data/view-model only; the designer owns visuals (§7) |
| Import from Arc | Multiple Arc Profiles → multiple Open Profiles; per-Profile Favorites; Chromium directory mapping recorded for the later engine-data import (§8) |
| Acceptance | `openkit profiles …` CLI on the real model + `commands-demo` extension (§9.1–§9.2); app-phase cookie-isolation check (§9.3) **[NEEDS ENGINE]** |

### 0.2 Out of scope (do not build)

- Any Settings, sidebar, or Space-creation **visuals**. §7 delivers data
  types only. No `View`, no `NSView`, no SwiftUI in this plan.
- Engine-data import (cookies, passwords, Chromium `History` rows,
  extensions) beyond recording the directory mapping. That is the M8
  phase-2 work in [import-phase2.md](import-phase2.md); §8.4 states the
  hand-off. Never copy encrypted Chromium blobs into an Open Profile.
- A `downloadLocation` Profile setting. Arc has one per Profile
  ([features-core.md](../re/features-core.md) §5.2), but the implemented
  `ProfileSettings` (`Containers.swift:20`) has only `autoArchiveAfter`,
  `littleOpenAutoArchiveAfter`, `searchEngineID`. Adding the download field
  belongs to the downloads milestone; §11 lists it as an open question.
- Profile reordering UI/data (`profileOrdering` exists in Arc). The
  `profiles` array order **is** the display order in v1 (§3.7).
- Deleting a Profile's disk data from inside `BrowserModel`. The model has
  no I/O (architecture rule). Disk deletion is an App/OpenStore operation
  (§5.5) that runs only after engine teardown (§6.5).
- A global "switch Profile" command. Arc has none: you switch by focusing a
  Space on the desired Profile ([features-core.md](../re/features-core.md)
  §5.3 rule 7). Do not add one.

### 0.3 Milestone fit

This is M5 ("Profiles + routing + settings") in [plan.md](../plan.md),
Profiles half. It depends on M1 (done: `OpenKit` model/store/CLI) and M2
sidebar data (Spaces, Favorites). Routing (Phase A) is done
([routing.md](../routing.md)). The engine steps depend on the M0 engine
spike delivering `OpenEngine`.

---

## 1. Current state (verified facts)

Read these files before coding. Line numbers are from `main` at the time of
writing; re-check them, and report drift instead of redesigning.

| Fact | Evidence |
|---|---|
| `Profile` is a live `@MainActor @Observable` class: `id`, `name`, `icon: SpaceIcon?`, `favorites: [Tab]`, `settings: ProfileSettings`, `dataDirectoryName: String` | `Packages/OpenKit/Sources/OpenModel/Containers.swift:53–68` |
| `ProfileSettings` = `autoArchiveAfter` (default 12h), `littleOpenAutoArchiveAfter` (default 6h), `searchEngineID` (default `"duckduckgo"`); legacy `littleArc…` key decodes, new key encodes | `Containers.swift:20–51` |
| `Space.profileID: ProfileID` is set at creation; `createSpace(title:profileID:icon:theme:)`, `updateSpace(…profileID:…)`, `deleteSpace`, `moveSpace(id:to:)` (reorder) already exist | `BrowserModel.swift:741–827` |
| **No Profile commands exist.** Nothing creates, renames, or deletes a `Profile` after `BrowserModel.init`. `profiles` is a plain `var [Profile]` | `BrowserModel.swift:94–124` (whole-file search: no `func …Profile`) |
| Favorites are indexed under `.favorites(profileID)`; `addFavorite`/`removeFavorite` move (never copy) the same `Tab` object | `BrowserModel.swift:540–556`, `model.md` "Favorites move, they never copy" |
| Undo: every command registers one step via `registerUndo`/`registerChange`; undo/redo call primitives only; `archiveExpiredTabs` is the sole no-undo command | `BrowserModel.swift:434–468`, `model.md` "Undo" |
| Events: `TreeChange` = `.insert` / `.remove` / `.move` / `.reload(parent)`; property changes emit nothing (Observation covers them) | `BrowserModel.swift:84–90, 102–108` |
| Snapshot DTOs already carry every Profile field; `schemaVersion` stays 1; file is `<root>/State/browser.json` | `SnapshotDTOs.swift:5–26`, `SnapshotStore.swift:4–20` |
| `ArchiveStore` and `HistoryStore` each take `init(root:)` and append `State/archive.sqlite3` / `State/history.sqlite3` — one global file each today | `ArchiveStore.swift:26–28`, `HistoryStore.swift:19–21` |
| Archive rows already store `profile_id`; `ArchivedTabRecord.profileID` exists; restore falls back by Profile | `ArchiveStore.swift:35–40`, `BrowserModel.swift:26–44, 588–597` |
| Importer creates one Open Profile per distinct `Space.profile` value; `{default:true}` → name `Default`, dir `Default`; any other key → name `Profile`, `dataDirectoryName` = the raw key | `ArcImport.swift:166–192` |
| Importer attaches **all** Favorites to the default Profile (single `topApps` container assumed) | `ArcImport.swift:399–419` |
| `openkit` commands today: `import-arc`, `archive-list`, `dump`, `roundtrip`, `bench`, `commands-demo` (66 checks), `suggest`, `route`, `favicons`. Exit 0 ok / 1 data failure / 2 usage | `openkit/main.swift:11–31`, `CLI.swift`, `CommandsDemo.swift` |
| Command-bar and routing code already resolve a Space's Profile (`SuggestEngine`, `RoutingSnapshot`, `LinksSettingsModel`) and already exclude other Profiles' results | `OpenSuggest/SuggestEngine.swift:139`, `docs/routing.md` "API" |

Consequence: this plan is mostly **additive**. No DTO field is added, no
`schemaVersion` bump, no change to tab/folder/split commands. The breaking
changes are confined to store file locations (§5.4) and one new
`TreeChange` case (§3.6).

---

## 2. Key decisions

| ID | Decision | Rejected alternative | Why |
|---|---|---|---|
| D-P1 | `deleteProfile` **refuses** while any Space uses the Profile, and always refuses for the default Profile. Favorites of a deletable (Space-free) Profile are archived, not dropped | Cascade-delete the Spaces; or move Spaces to default silently | Arc (proven): "Only Profiles not assigned to any Spaces can be deleted." / "The Default Profile cannot be deleted." ([features-core.md](../re/features-core.md) §5.1 rule 3). Cascade would destroy pinned/today structure the user never confirmed |
| D-P2 | `moveSpace(id:toProfile:)` is **allowed** (Arc: Spaces ▸ "Change Profile"). The model moves instantly; the confirm dialog ("Each Profile has different browser data…", with don't-show-again) is App/UI data (§7.3), not a model gate | Forbid cross-Profile Space moves | Arc allows it in two flows (§5.1 rule 2 creation picker, §5.4 rule 9). Forbidding would break Import repair and the create-Profile flow |
| D-P3 | `dataDirectoryName` is minted once at creation (`Default`, or `Profile-<8 uppercase hex>`), stored in the snapshot, and **never** changes on rename | Derive the directory from the display name; rename the directory on rename | Rename must not move gigabytes of engine data or orphan cookies. Arc separates display name from `profileDirectoryBasename` ([data-model.md](../re/data-model.md) §2.6) |
| D-P4 | The default Profile is the one with `dataDirectoryName == "Default"`; if none exists, `profiles.first` acts as default. No new `isDefault` flag | Add `isDefault: Bool` to `Profile` + DTO | The DTO already round-trips `dataDirectoryName`; a flag adds a schema-1 optional field and a two-sources-of-truth bug (flag vs. position) for zero user gain |
| D-P5 | Archive becomes **one SQLite file per Profile** (`Profiles/<dir>/State/archive.sqlite3`). A composite sink routes by `ArchiveEntry.profileID` | Keep one global `archive.sqlite3` filtered by `profile_id` | Task scope and Arc isolation both point per-Profile; the global file would be the one store that survives a Profile disk-delete (§5.5), leaking its tab titles/URLs. The `profile_id` column stays (restore + import dedupe use it) |
| D-P6 | History becomes **one SQLite file per Profile**. Favicons stay **one global file** | Per-Profile favicons | History is private browsing data (isolated in Arc, proven). Favicon bytes are public site icons keyed by origin (`FaviconStore` has no Profile key) and the sidebar draws icons for every Space at once; splitting it would duplicate fetches per Profile. The accepted leak is stated in §5.3, not hidden |
| D-P7 | Request contexts load **lazily**: a Profile's `CefRequestContext` is created when a Space of that Profile is first shown (or a Little Open window first hints it), never for all Profiles at launch. Loaded contexts stay loaded until quit in v1 | Load all at launch; evict idle contexts | Arc evidence points lazy (`shouldLoadAllProfilesAtStartup`, [features-core.md](../re/features-core.md) §5.2 rule 6, marked Guess). Each loaded context costs a Chrome Profile in the browser process (§6.4); eviction correctness (live browsers, extensions) is a follow-up, not v1 |
| D-P8 | Incognito is an **ephemeral Profile**: an in-memory request context (`cache_path` empty) shared by windows of one requested parent; a synthetic Profile lives only in each private window's separate model, never in `app.model.profiles` or an Open store (Section 10 lead erratum, 2026-11-06) | A hidden persisted `Profile` row | Arc: incognito cookies are never seeded and nothing persists (§5.2 rule 6, §8.1 rule 3). A model row would leak into Settings, the snapshot, and `openkit profiles list` |
| D-P9 | One new `TreeChange` case, `.spaceProfileChanged(spaceID:from:to:)`. `updateSpace(profileID:)` keeps its combined-edit undo but emits the same case | Emit only `.reload` and let the engine diff `profileID` | The engine must destroy/recreate web contents on a Profile change; a diff-on-reload rule is implicit and easy to miss. One explicit case, two existing switch sites to update (§3.6) |
| D-P10 | No DTO/schema change. `schemaVersion` stays 1; old snapshots load unchanged; `repairMissingProfileReferences()` runs explicitly at App/CLI load, not inside the mapper | Bump to schema 2; auto-repair inside `SnapshotMapper` | Every Profile field already persists. Hidden mapper repair would make `roundtrip` compare a repaired tree against its file and hide data loss |

---

## 3. Model commands (`OpenModel`) — scope item 1

Files: edit `Packages/OpenKit/Sources/OpenModel/BrowserModel.swift` (add a
`// MARK: Profiles` section after the Spaces section, and the §3.6
`TreeChange` case) and `Packages/OpenKit/Sources/OpenModel/Containers.swift`
(no new stored fields; only the §3.1 validation helper if you place it there
— the plan places it in `BrowserModel.swift` to keep `Containers.swift` a
pure type file). Do not create a `BrowserModel+Profiles.swift` extension
file: `registerUndo`, `registerChange`, `profileByIDCache`, `register`,
`unregister`, and `emit` are `private`, and an extension in another file
cannot reach them. Follow the existing style exactly: `@MainActor`,
synchronous commands, one undo step per command, refused commands change
nothing, emit no event, and register no undo.

### 3.1 Name validation (shared by create/rename and §7)

Add to `BrowserModel.swift`: `ProfileNameIssue` as a **top-level** enum,
and `profileNameIssue` as a `public static` method **inside** `BrowserModel`:

```swift
public enum ProfileNameIssue: Sendable, Equatable {
    case empty          // trimmed name is empty
    case tooLong        // more than 64 grapheme clusters
    case invalidCharacters // contains a slash, colon, backslash, or control character, or is "." / ".."
    case duplicate      // case-insensitive trimmed match with another Profile
}

public static func profileNameIssue(_ raw: String, in profiles: [Profile],
                                    excluding excludedID: ProfileID? = nil) -> ProfileNameIssue?
```

Rules, in this order: trim `whitespacesAndNewlines`; empty → `.empty`;
count > 64 → `.tooLong`; contains `/`, `:`, `\`, any
`CharacterSet.controlCharacters` scalar, or equals `.` / `..` →
`.invalidCharacters`; any other Profile whose trimmed name compares equal
with `caseInsensitiveCompare` → `.duplicate`; else `nil`. The stored name is
the **trimmed** name. This mirrors Arc's proven behaviour ("A Profile with
that name already exists.", "Invalid Profile name.",
[features-core.md](../re/features-core.md) §5.1 rule 2) without copying its
strings into validation logic. The 64-char cap is an Open choice (Arc's cap
is unverified); it keeps Settings rows and CLI output bounded.

### 3.2 `createProfile`

```swift
@discardableResult
public func createProfile(name: String, icon: SpaceIcon? = nil,
                          settings: ProfileSettings = ProfileSettings()) -> Profile?
```

Behaviour:

1. Return `nil` (no change, no event, no undo) when
   `Self.profileNameIssue(name, in: profiles) != nil`.
2. Mint `dataDirectoryName` (D-P3): if `profiles` is empty, use `"Default"`;
   otherwise use `"Profile-" + String(UUID().uuidString.prefix(8)).uppercased()`,
   retrying with a fresh UUID while the value collides case-insensitively
   with an existing `dataDirectoryName`. The first Profile of a fresh model
   is therefore always the default Profile (D-P4).
3. Append the new `Profile` to `profiles`, insert it into
   `profileByIDCache`, and register undo. There are no Favorites to index.
4. Emit **no** `TreeChange` (the `profiles` array is observed; there is no
   sidebar parent for a Profile). Settings and the sidebar Profile indicator
   observe `profiles` directly.
5. Undo removes the Profile (and its cache entry). Redo re-inserts it at the
   same index with the same `ProfileID` and the same `dataDirectoryName`.
   Undo/redo call private primitives only, like every other command.
6. The command does **not** create any directory or engine context. The App
   layer calls `ProfileDirectories.ensureProfileDirectories` (§5.2) after
   the command succeeds and the snapshot saves. `openkit profiles create`
   does the same (§9.1), so the CLI proves the layout without the engine.

The App's "create Profile, then move these Spaces into it" flow (Arc §5.1
rule 2) is `createProfile` followed by one `moveSpace` per selected Space —
one undo step for the create plus one per Space moved. Do not add a
combined command; the settings data layer (§7.2) sequences them.

### 3.3 `renameProfile`, `setProfileIcon`, `updateProfileSettings`

```swift
@discardableResult
public func renameProfile(id: ProfileID, to name: String) -> Bool
public func setProfileIcon(id: ProfileID, icon: SpaceIcon?)
@discardableResult
public func updateProfileSettings(id: ProfileID, settings: ProfileSettings) -> Bool
```

- `renameProfile` returns `false` (no change/undo) when the Profile is
  missing or `profileNameIssue(name, in: profiles, excluding: id) != nil`.
  Renaming to the same trimmed name is a no-op that returns `true` and
  registers no undo. Otherwise set `profile.name` to the trimmed name via
  `registerChange` (undo restores the old name). It never touches
  `dataDirectoryName`, Spaces, or Favorites (Arc, proven: "This won't affect
  the names of any of the Spaces associated with this Profile.").
- `setProfileIcon` sets `profile.icon` via `registerChange`; missing Profile
  is a silent no-op, matching `renameNode`/`setExpanded`. No event.
- `updateProfileSettings` replaces the whole `ProfileSettings` value via
  `registerChange` and returns `true`; missing Profile returns `false`.
  Whole-value replace (not per-field setters) keeps the Settings pane's
  draft-then-save flow (§7.1) atomic under one undo step. Callers that
  change one field copy, mutate, and pass the copy — the same pattern
  `LinksSettingsModel.currentRouting()` uses.
- All three are property changes: **no** `TreeChange`. Observation redraws
  the Settings row and the Profile indicator. Auto-archive picks up a new
  `autoArchiveAfter` on its next `archiveExpiredTabs(now:)` pass, which
  already reads `profile(id: space.profileID)?.settings` live
  (`BrowserModel.swift:1053–1055`) — do not add caching.

### 3.4 `deleteProfile`

```swift
@discardableResult
public func deleteProfile(id: ProfileID) -> Bool
```

Refuse (return `false`; no change, no event, no undo) when any of these
holds: the Profile does not exist; `id == defaultProfile?.id` (D-P4); or
`spaces.contains { $0.profileID == id }` (D-P1). The CLI and Settings layer
must explain the refusal with `deleteBlockReason(for:)` (§3.7) instead of
guessing.

On success, in one undo step:

1. Build one `ArchiveEntry` per Favorite tab (reason `.closed`,
   `originalLocation` = `NodeParent.favorites(id).archiveLocation`,
   `spaceID: nil`, `profileID: id`, one shared `archivedAt`), mirroring
   `archiveEntries(for:in:reason:at:)` but for the Favorites list, which
   that helper does not cover. Call the injected `archiveSink` **once**
   with the whole batch (bulk-command rule from `model.md`).
2. Unregister every Favorite from `index`/`parentByID`, remove the Profile
   from `profiles`, and drop its `profileByIDCache` entry.
3. Emit one `.reload(parent: .favorites(id))` so any observer holding the
   Favorites section clears it. No other event: Spaces cannot reference a
   deleted Profile by construction.
4. Undo re-inserts the same `Profile` object at its original index,
   re-registers its Favorites, restores the cache entry, emits the same
   `.reload`, and calls `archiveSink?.discardArchived(ids:)` so no tab is
   ever in the sidebar and the archive at once (existing invariant).
   Redo re-runs the delete and captures fresh state, per the
   `registerUndo` contract (`BrowserModel.swift:436–449`).

Disk data is **not** deleted here (model has no I/O). §5.5 defines the
separate, irreversible disk wipe the App offers after this command, and
§6.5 orders it after engine teardown. Undo after a disk wipe restores the
sidebar Profile with empty engine data (fresh cookies/history) — the App's
wipe confirmation must say so (§7.1).

### 3.5 `moveSpace(id:toProfile:)` — and `updateSpace` reconciliation

```swift
@discardableResult
public func moveSpace(id: SpaceID, toProfile profileID: ProfileID) -> Bool
```

Note the existing `moveSpace(id:to:)` (`BrowserModel.swift:817`) reorders
Spaces. Keep both; the argument label `toProfile:` keeps call sites
unambiguous. Do not rename the reorder command.

Behaviour: return `false` (no change/undo) when the Space or the target
Profile is missing, or the Space already uses that Profile. Otherwise, in
one undo step: set `space.profileID`, emit
`.spaceProfileChanged(spaceID:from:to:)` (§3.6), and register undo that
restores the old `profileID` and emits the inverse event. Nothing else
moves: pinned/today/folder/split nodes keep their IDs, URLs, and
`pinnedURL`s; Favorites stay with the **old** Profile (they belong to the
Profile, not the Space — [features-core.md](../re/features-core.md) §5.2
rule 5). The engine consequence (live web contents must be recreated under
the new context) is the App's job on receiving the event (§6.3).

Reconcile the existing `updateSpace(…profileID:…)` combined editor
(`BrowserModel.swift:754–767`): when its `profileID` argument differs from
the current value, it must emit the same `.spaceProfileChanged` event in
addition to applying title/icon/theme, still as **one** undo step that
restores all four old values and emits the inverse event. Implement this by
capturing `oldProfile` before `apply()` (already captured) and emitting
after `apply()` when `space.profileID != oldProfile`. Do not implement
`updateSpace` by calling `moveSpace` — that would register two undo steps
for one editor save.

`createSpace` hardening (same step, no signature change): if the passed
`profileID` does not exist, fall back to `defaultProfile?.id`; if there is
no Profile at all, still create the Space with the passed ID and let
`repairMissingProfileReferences()` (§3.7) fix it at load. This preserves
the current non-optional return that `CommandsDemo` and the importer rely
on. The CLI resolves the Profile first and exits 1 on a bad reference
(§9.1), so the fallback is a safety net, not the normal path.

Single-tab cross-Profile moves: Arc has a tab-level "move to another
Profile" action (§5.4 rule 9). Open v1 does **not** add a model command for
it. A tab's Profile is derived from its Space (or its Favorites owner);
there is no per-tab Profile field to set, and inventing one would split
tab identity from Space identity. The UI offers "move tab to Space" into a
Space on the target Profile instead. Record this as a deliberate v1 cut.

### 3.6 `TreeChange` addition and its two switch sites

Add one case to `TreeChange` (`BrowserModel.swift:85`):

```swift
case spaceProfileChanged(spaceID: SpaceID, from: ProfileID, to: ProfileID)
```

Update every exhaustive switch (search for `TreeChange` before building):

1. `Packages/OpenKit/Sources/openkit/CommandsDemo.swift` `describe(_:)` —
   add: `profile(space <8-char prefix>: <from 8>-><to 8>)` using the same
   `prefix(8)` style as the other cases.
2. Any sidebar/App observer added later must handle it (§6.3). There is no
   sidebar target yet, so no other site exists today; the build proves it.

`insert`/`remove`/`move`/`reload` semantics do not change. Profile
create/rename/icon/settings/delete emit nothing except the single
`.reload(.favorites(id))` on delete (§3.4) — Profiles have no sidebar
parent, and Observation already covers `profiles`.

### 3.7 Default Profile, queries, and missing-Profile repair

Add to `BrowserModel`:

```swift
public var defaultProfile: Profile? {
    profiles.first { $0.dataDirectoryName == "Default" } ?? profiles.first
}
public func spaces(using profileID: ProfileID) -> [Space]
public func deleteBlockReason(for id: ProfileID) -> ProfileDeleteBlock?
public func repairMissingProfileReferences() -> [SpaceID]
```

`ProfileDeleteBlock` is a **top-level** enum in the same file (outside
`BrowserModel`, like `TreeChange`), so `OpenModel` clients write it bare:

```swift
public enum ProfileDeleteBlock: Sendable, Equatable {
    case isDefault
    case spacesAssigned(count: Int)
}
```

- `defaultProfile` is computed, never stored (D-P4). `deleteBlockReason`
  returns `.isDefault` first, then `.spacesAssigned(count:)` with the live
  count, then `nil` (deletable / missing Profile also returns `nil`; callers
  check existence separately). `deleteProfile` refuses exactly when this
  returns non-`nil` or the Profile is missing — implement the refusal
  through this function so model, CLI, and Settings can never disagree.
- `spaces(using:)` returns matching Spaces in `spaces` array order.
- `repairMissingProfileReferences()`: for each Space whose `profileID` has
  no Profile, set it to `defaultProfile.id` and collect its ID; return the
  repaired IDs in `spaces` order. If there are no Profiles at all, return
  `[]` and change nothing (bootstrap owns that case, §5.4). Register **no**
  undo and emit one `.spaceProfileChanged` per repaired Space (from the
  dangling ID to the default), so an already-running engine adapter fixes
  live contents too. This is Arc's missing-Profile guard
  ([features-core.md](../re/features-core.md) §5.3 rule 8: fall back to
  Default and tell the user). Call sites: App bootstrap after
  `SnapshotStore.load()`, and `openkit profiles list` (§9.1) which prints
  the repaired IDs. `SnapshotMapper` must **not** call it (D-P10).
- Display order is `profiles` array order everywhere (Settings list,
  pickers, CLI). No reorder command in v1 (§0.2).

### 3.8 Undo summary (acceptance checks these rows)

| Command | Undo restores | Redo | Event |
|---|---|---|---|
| `createProfile` | Profile removed | Same Profile, index, dir name re-inserted | none |
| `renameProfile` / `setProfileIcon` / `updateProfileSettings` | Old value | New value | none |
| `deleteProfile` | Profile + Favorites back, archive rows discarded | Delete + archive again | `.reload(.favorites(id))` both ways |
| `moveSpace(id:toProfile:)` | Old `profileID` | New `profileID` | `.spaceProfileChanged` both ways |
| `updateSpace` with Profile change | All four old values | All four new values | `.spaceProfileChanged` when Profile changed |
| `repairMissingProfileReferences` | — (no undo, like `archiveExpiredTabs`) | — | `.spaceProfileChanged` per Space |

Refused commands (`nil`/`false` returns above) register no undo and emit
no event. The §9.2 demo extension asserts this for duplicate-name create,
delete-with-Spaces, delete-default, and move-to-missing-Profile.

---

## 4. Persistence impact (no schema change)

- `SnapshotDTOs.swift`: **no edit**. `ProfileDTO` already carries `id`,
  `name`, `icon`, `favorites`, `settings`, `dataDirectoryName`
  (`SnapshotDTOs.swift:19–26`), and `SnapshotMapper` already maps all six
  both ways (`:285–297`). `schemaVersion` stays 1 (D-P10). Prove it in
  §9.1: a pre-change snapshot loads, gains a Profile through the CLI, saves,
  reloads, and `roundtrip` still prints `roundtrip OK`.
- `SnapshotStore.swift`: **no edit**. Root stays injectable; default root
  stays `~/Library/Application Support/Open`; the file stays
  `<root>/State/browser.json`. All Profiles, Spaces, windows, and routing
  rules stay in this one app-wide file — Spaces are shared across Profiles
  and a Space only *points at* a Profile (Arc §5.2 rule 5), so splitting
  the snapshot per Profile would duplicate the Spaces list.
- The only persistence work is store **locations** (§5) and the importer
  (§8). If you find yourself editing a DTO, stop: you have left this plan.

---

## 5. Data layout on disk — scope item 2

### 5.1 Root and tree

`root` everywhere below is the injectable OpenStore root. Default:
`~/Library/Application Support/Open`. The `openkit` CLI's `DIR` argument is
always this root (existing convention: `SnapshotStore(root: DIR)` reads
`DIR/State/browser.json`). Tests and the CLI use a temp `DIR`; the App uses
the default. Never hardcode the default outside `SnapshotStore` /
`ProfileDirectories.defaultRoot`.

```text
<root>/
  State/
    browser.json                 app-wide snapshot (unchanged, §4)
    favicons.sqlite3             GLOBAL favicon cache (path fixed here; CLI already takes --db)
  Engine/                        CefSettings.root_cache_path (§6.2; lead decision 2026-10-25), mode 0700
    .open-layout                 "2": the engine layout is done (EngineLayoutMigration)
    Default/                     the default Profile's Chromium profile dir (CEF's global context), 0700
    <dataDirectoryName>/         every other Profile's Chromium profile dir (its context's cache_path), 0700
    Local State, WidevineCdm/…   Chromium's installation-wide files
  Profiles/
    <dataDirectoryName>/         one directory per Profile; name from Profile.dataDirectoryName
      State/
        history.sqlite3          this Profile's HistoryStore (Open's own history, FTS5)
        archive.sqlite3          this Profile's ArchiveStore
        sleep.sqlite3            this Profile's SleepStore (planned, memory-fork §7.5)
      Boosts/
        boosts.json              this Profile's BoostStore file (supersedes boosts-zap §4 path)
      AdBlock/
        catalog-state.json       Swift-owned ad-block state (adblock-fork §9.2)
        exclusions.json          Swift-owned per-Profile exclusions (adblock-fork §9.2)
        lists/
          <listID>.txt           last good list text (Swift writes, atomic)
          resources.txt          scriptlet/redirect resources (adblock-fork §9.3)
          engine.dat             browser-owned serialized engine; Swift never writes it
```

Chromium keeps each Profile's HTTP and code caches outside the root when the
root is under `~/Library/Application Support`: `Engine/<dir>` caches in
`~/Library/Caches/<root name>/Engine/<dir>` (`chrome_paths_mac.mm`,
`GetUserCacheDirectory`; any other root keeps them inside `Engine/<dir>`).
`ProfileDirectories.engineCacheDirectory` computes it the same way.
`Profiles/<dir>/` is created with mode 0700, as Chromium's profile folders are.

Incognito gets **no** directory under `Profiles/` (D-P8). Its only disk
trace is what CEF itself persists under `root_cache_path` as
installation-specific data; its ad-block lists, when the ad-block milestone
lands, use a per-session `NSTemporaryDirectory()` directory that the App
deletes at window close (adblock-fork §12.3 rule).

### 5.2 `ProfileDirectories` (new file)

Create `Packages/OpenKit/Sources/OpenStore/ProfileDirectories.swift`.
`import Foundation` and `import OpenModel` only. Value type, `Sendable`,
no I/O except the two explicit operations at the bottom:

```swift
public struct ProfileDirectories: Sendable {
    public let root: URL
    public init(root: URL)
    public static var defaultRoot: URL { get } // ~/Library/Application Support/Open

    public func profileDirectory(dataDirectoryName: String) -> URL
    public func engineDirectory(dataDirectoryName: String) -> URL
    public func engineCacheDirectory(dataDirectoryName: String) -> URL
    public func historyFileURL(dataDirectoryName: String) -> URL
    public func archiveFileURL(dataDirectoryName: String) -> URL
    public func sleepFileURL(dataDirectoryName: String) -> URL
    public func boostsFileURL(dataDirectoryName: String) -> URL
    public func adBlockDirectory(dataDirectoryName: String) -> URL
    public func adBlockListsDirectory(dataDirectoryName: String) -> URL

    public func ensureProfileDirectories(dataDirectoryName: String) throws
    public func deleteProfileData(dataDirectoryName: String) throws
}
```

Path rules (implement exactly; these are the §5.1 tree, nothing else):

- `profileDirectory` = `root/Profiles/<dataDirectoryName>`.
- `engineRoot` = `root/Engine` (`root_cache_path`).
- `engineDirectory` = `engineRoot/<dataDirectoryName>`. CEF loads a disk
  profile only for a direct child of `root_cache_path` (§6.2). The default
  Profile's engine data is always `engineRoot/Default`, whatever its
  `dataDirectoryName` (CEF's global context).
- `historyFileURL` / `archiveFileURL` / `sleepFileURL` =
  `profileDirectory/State/<name>.sqlite3`.
- `boostsFileURL` = `profileDirectory/Boosts/boosts.json`.
- `adBlockDirectory` = `profileDirectory/AdBlock`;
  `adBlockListsDirectory` = `adBlockDirectory/lists`.
- Reject a `dataDirectoryName` that is empty, `.`/`..`, or contains `/` by
  precondition failure in the path builders — directory names are minted by
  §3.2/§8 and validated there; a bad value here is a programmer error, not
  user input. (Do not silently sanitize: two Profiles must never collide
  onto one directory.)
- `ensureProfileDirectories` creates `State/`, `Boosts/`,
  `AdBlock/lists/` with intermediate directories. It is idempotent and
  creates no files. Call sites: App after `createProfile` succeeds;
  `openkit profiles create`; App bootstrap for every loaded Profile
  (covers Profiles created before this plan shipped).
- `engineCacheDirectory` = Chromium's cache folder for `engineDirectory`:
  the same path under `~/Library/Caches` for a root under
  `~/Library/Application Support`, else `engineDirectory` itself (§5.1).
- `deleteProfileData` removes the whole `profileDirectory` tree, the
  Profile's `Engine/<dir>`, and its Chromium cache folder. It throws
  on failure and never touches any other Profile. Preconditions and
  ordering are §5.5 — the function itself only deletes.

Convenience for call sites that hold a live `Profile` (add as an extension
in the same file): `profileDirectory(for profile: Profile) -> URL` and
siblings that forward `profile.dataDirectoryName`. Prefer these so no call
site re-derives the name.

### 5.3 Store inventory — what lives where, and what is isolated

| Store | Path | Scope | Status today | This plan |
|---|---|---|---|---|
| Snapshot | `<root>/State/browser.json` | Global | Implemented | Unchanged |
| Engine (cookies, cache, logins, extensions, site settings, Chromium prefs) | `Engine/<dir>/` (default Profile: `Engine/Default/`) | Per Profile | No engine yet | CEF owns the contents; Open only passes the path (§6). One request context each |
| History (Open) | `Profiles/<dir>/State/history.sqlite3` | Per Profile | Global `State/history.sqlite3` | Move + re-init (§5.4) |
| Archive | `Profiles/<dir>/State/archive.sqlite3` | Per Profile | Global `State/archive.sqlite3` | Move + composite sink (§5.4) |
| Sleep (`SleepStore`) | `Profiles/<dir>/State/sleep.sqlite3` | Per Profile | Planned only (memory-fork §7.5 said `State/sleep.sqlite3`) | Adopt the per-Profile path now; tell the memory implementer this plan supersedes that line |
| Boosts | `Profiles/<dir>/Boosts/boosts.json` | Per Profile | Planned only (boosts-zap §4 said `<root>/Boosts/<profileID>.json`) | Adopt this path; the Boost store's ProfileID file-naming is superseded. Boost data is per-Site, but the enabled set is per Profile (Arc), so the file follows the Profile |
| Ad block | `Profiles/<dir>/AdBlock/…` | Per Profile | Planned (adblock-fork §9.2) | `<profile-dir>` in that plan **means** `Profiles/<dir>/` from now on. No path change beyond that definition |
| Favicons | `<root>/State/favicons.sqlite3` | **Global (deliberate)** | `FaviconStore(databaseURL:)` implemented; App path unfixed | Fix the App/CLI default to this path. Accepted leak: the cache proves *some* Profile visited an origin. Do not claim favicon isolation anywhere (D-P6) |
| Downloads | Inside `Engine/` (Chromium) | Per Profile | Not implemented | No Open store. The per-Profile download-location *setting* is out of scope (§0.2) |
| Search engine, auto-archive | In `browser.json` (`ProfileSettings`) | Per Profile | Implemented | Unchanged; read live, never cached (§3.3) |
| Routing rules, windows | In `browser.json` | Global | Implemented | Unchanged. A rule targets a Space; the Space implies the Profile |

Per-Profile means *isolated* for: cookies, history (both Chromium's inside
`Engine/` and Open's SQLite), logins/passwords, extensions, Favorites,
search engine, auto-archive (incl. Little Open), ad-block lists/exclusions,
Boosts, sleep history. That is Arc's proven list
([features-core.md](../re/features-core.md) §5.2 rule 4) plus Open's own
stores. Shared across Profiles: the Spaces list, windows, routing rules,
app settings, and the favicon cache (above).

### 5.4 Refactor: per-Profile `HistoryStore` / `ArchiveStore` + migration

Signature change (breaking; update every call site in the same PR):

```swift
// HistoryStore.swift — actor, fileURL already stored; only the init changes
public init(fileURL: URL)            // was: init(root: URL) appending State/history.sqlite3

// ArchiveStore.swift — @MainActor class; only the init changes
public init(fileURL: URL)            // was: init(root: URL) appending State/archive.sqlite3
```

Delete the `root.appendingPathComponent("State/…")` lines; keep every
other line (queues, schema, WAL via `SQLiteSupport`). Update these call
sites (search `HistoryStore(` / `ArchiveStore(` to confirm, and fix what
you find):

- `openkit/CLI.swift` (`runImportArc`, `runArchiveList`, `runBench`),
- `openkit/CommandsDemo.swift`, `openkit/BulkBench.swift`,
  `openkit/SuggestCheck.swift`, `openkit/SuggestCLI.swift`.

Each site builds its URL through `ProfileDirectories` (CLI) with the
default Profile's `dataDirectoryName` (`"Default"` for bench/demo temp
roots, which must call `ensureProfileDirectories` first). One site is
special: `SuggestCLI.historyStore(at:)` (`SuggestCLI.swift:18–26`) takes
an explicit `--history` argument. Keep that explicit-path contract, but
redefine what it accepts: a root `DIR` now means that root's **default**
Profile file (`ProfileDirectories(root: DIR).historyFileURL("Default")`),
and a direct `.sqlite3` path is accepted only in the new per-Profile form
`…/Profiles/<dir>/State/history.sqlite3` (validate the last three path
components, then `HistoryStore(fileURL:)`). Update its comment and the
` suggest` usage/error text to match; the old `<root>/State/history.sqlite3`
form returns `nil` (usage exit 2) after this change — that is the §5.4
one-way migration at the CLI surface. Callers who need a non-default
Profile pass its file path directly.

Composite archive sink (App + CLI wiring, new type in
`ProfileDirectories.swift` or a small new `OpenStore` file
`ProfileArchiveSink.swift` — pick the new file):

```swift
@MainActor
public final class ProfileArchiveSink: ArchiveSink {
    public init(directories: ProfileDirectories, directoryNameFor: @escaping @MainActor (ProfileID?) -> String)
    public func archive(_ entries: [ArchiveEntry])
    public func discardArchived(ids: [ItemID])
    public func store(for profileID: ProfileID?) -> ArchiveStore // cached per directory name
    public func flushAll()
}
```

It keeps one `ArchiveStore` per `dataDirectoryName`, created lazily and
cached. `archive(_:)` groups entries by `entry.profileID`, maps each group
through `directoryNameFor` (a ProfileID → its current `dataDirectoryName`;
`nil` or unknown → the default Profile's directory), and forwards one call
per group. `discardArchived(ids:)` must forward to **every** created store
(the sink does not track which Profile archived which ID; stores are
small and delete-by-ID is idempotent). `BrowserModel.archiveSink` is set
to this composite wherever the App or CLI runs mutating commands.
`CommandsDemo`'s `CountingSink` wraps the composite exactly as it wraps
today's single store.

Migration (new file `Packages/OpenKit/Sources/OpenStore/ProfileMigration.swift`):

```swift
public struct ProfileMigrationReport: Sendable {
    public var moved: [String] = []     // e.g. "history.sqlite3 -> Profiles/Default/State/history.sqlite3"
    public var skipped: [String] = []   // destination already existed; source left in place
    public var missing: [String] = []   // no legacy file (fresh install)
}

public enum ProfileMigration {
    public static func migrateSingleProfileLayout(root: URL, profiles: [Profile]) -> ProfileMigrationReport
}
```

Behaviour (idempotent; safe to run on every launch before any store opens):

1. Target Profile = the default Profile (D-P4 rule: `dataDirectoryName ==
   "Default"` first, else `profiles.first`). No Profiles → report all
   `missing`, do nothing.
2. For each of `history.sqlite3`, `archive.sqlite3`, `sleep.sqlite3`:
   legacy = `<root>/State/<name>`, dest = that Profile's
   `Profiles/<dir>/State/<name>` (via `ProfileDirectories`). If dest
   exists → `skipped` (never overwrite; the per-Profile file wins). Else
   if legacy exists → create `State/` under the Profile dir and
   `FileManager.moveItem` (same volume, atomic rename; also move the
   `-wal`/`-shm` sidecars when present so an unclean shutdown does not
   lose the last writes). Else → `missing`.
3. Never delete a legacy file that was `skipped`. The App logs the report;
   `openkit profiles list` prints it (§9.1). A legacy file left behind is
   inert: new code never opens `<root>/State/history.sqlite3` again.
4. `browser.json` does not move. There is no engine data to migrate (no
   engine has shipped). `Boosts/` legacy naming never shipped; no step.

Call order at App bootstrap (and in `openkit profiles` commands):
`SnapshotStore.load()` → `ProfileMigration.migrateSingleProfileLayout` →
`repairMissingProfileReferences()` → `ensureProfileDirectories` for every
Profile → open per-Profile stores. Fresh-install bootstrap (no snapshot):
create the fresh model with one `"Default"` Profile (via `createProfile`
on an empty model, which mints `"Default"` per §3.2), one Space, one
window — the same shape `CommandsDemo` seeds — then the same steps.

Rollback note: builds from before this plan ignore `Profiles/` and would
open empty legacy-path databases. That is acceptable (Open has no released
users; precedent: the `littleArc` → `littleOpen` one-way migration in
[routing.md](../routing.md)). State "ONE-WAY" in the PR description.

### 5.5 Deleting a Profile's disk data (App-level, irreversible)

`BrowserModel.deleteProfile` (§3.4) never touches disk. The Settings flow
(§7.1) offers, as a **separate explicit action** after a successful model
delete, "Delete Profile data from disk" which the App runs in this order:

1. Engine teardown for that Profile first (§6.5): destroy every web content
   on its context, then release the context. Deleting files under a live
   Chromium Profile corrupts it.
2. `ProfileDirectories.deleteProfileData(dataDirectoryName:)` with the name
   captured **before** the model delete (the Profile object is gone after).
   It removes `Profiles/<dir>/`, `Engine/<dir>/`, and the Profile's cache
   folder (`~/Library/Caches/<root name>/Engine/<dir>`, §5.1): a deleted
   Profile's browsing cache must not stay behind. Also unload the Chromium
   Profile through the engine first and drop its `Local State` entry
   (`releaseContext` completes when no page is left, not when Chromium's
   Profile is destroyed; `docs/followups.md`).
3. `SnapshotStore.saveNow` so a crash cannot resurrect a Profile whose
   directory is gone. (If it did resurrect, `repairMissing…` does not apply
   — the Profile exists; its stores simply recreate empty. The save-first
   ordering is what prevents that.)

Undo of the model delete after a disk wipe restores sidebar data only
(§3.4). There is no undo for the wipe. The confirmation copy in §7.1 must
say both things.

---

## 6. Engine contract — scope item 3 **[NEEDS ENGINE]**

Nothing in this section is OpenKit code. OpenKit (Steps 1–5) must compile
and pass §9.1–§9.2 with no engine present. This section is the contract the
App target implements over `OpenEngine` when the engine spike lands. Swift
never sees a CEF type (architecture rule): every call below crosses through
the assumed `OpenEngine` interface in §6.6, implemented by one App-side
registry. If the real `OpenEngine` API differs, only that registry changes.

### 6.1 CEF facts this contract rests on (read in the local tree)

Source: `~/Developer/open-engine/chromium_git/chromium/src/cef/include/`
(CEF branch 8078, Chromium 156.0.8078.48). Do not rebuild or sync that tree.

1. `CefRequestContext::CreateContext(CefRequestContextSettings, handler)`
   creates an independent context; `CreateContext(other, handler)` creates
   one that **shares storage** with `other` — never use the sharing form
   for two Open Profiles (`cef_request_context.h:121–132`).
2. `CefRequestContextSettings.cache_path`: empty → incognito (in-memory,
   nothing persisted); non-empty → must be an absolute path equal to or
   under `CefSettings.root_cache_path`; a value equal to the global
   `CefSettings.cache_path` shares the global cache and the per-context
   `persist_session_cookies` / language / cookie-scheme values are ignored
   (`internal/cef_types.h:545–583`). Therefore every non-default Profile
   must get a `cache_path` **different** from the global one.
3. `CefSettings.cache_path` has the same under-`root_cache_path` rule; any
   child-directory value for the *global* context is ignored and the
   "default" profile is used (`cef_types.h:285–296`). Therefore set the
   global context to the default Open Profile explicitly (below) instead
   of relying on a child path being honoured.
4. "Browser objects with different request contexts will never be hosted in
   the same render process." Same-context browsers may share one
   (`cef_request_context.h:100–107`). Isolation is at the context, not the
   window — the fact §6.3 relies on.
5. A browser is bound to its context at creation:
   `CefBrowserHost::CreateBrowser(…, request_context)` /
   `CreateBrowserSync`, and `CefBrowserHost::GetRequestContext()` reads it
   back (`cef_browser.h:292–325, 444`). There is no re-parenting call. A
   tab that changes Profile needs a **new** browser (§6.3).
6. In CEF's Chrome style, each request context with its own `cache_path`
   under `root_cache_path` maps to a Chrome Profile (its own cookies,
   storage, preferences, and extension system). That mapping is the whole
   reason for the §5.1 `Engine/` layout; Open adds no second isolation
   mechanism on top.

### 6.2 Context creation (exact mapping)

One-time CEF init (OpenEngine, before any browser):

- `CefSettings.root_cache_path` = `<root>/Engine` (absolute;
  `ProfileDirectories.engineRoot`). Lead decision 2026-10-25, replacing
  `<root>/Profiles`: CEF loads a disk profile only when `cache_path`'s parent
  equals `root_cache_path` as a string
  (`ChromeBrowserContext::InitializeAsync`); `Profiles/<dir>/Engine` is a
  grandchild, so CEF fell back to an in-memory off-the-record profile.
- `CefSettings.cache_path` = `<root>/Engine/Default` — the global
  context **is** the default Profile. If the default Profile's
  `dataDirectoryName` is not `"Default"` (degenerate repair case), use that
  Profile's directory name instead; CEF keeps the global context at
  `<root_cache_path>/Default` whatever is passed, so the rule is
  "global = default Profile = `Engine/Default`".
- `CefSettings.persist_session_cookies` = true, so session logins survive
  restart the way a Chromium Profile's do. Per-context override below.

Per Profile (lazy, §6.4), for every Profile except the one backing the
global context:

- `CefRequestContextSettings.cache_path` =
  `ProfileDirectories.engineDirectory(dataDirectoryName:)` (absolute,
  under `root_cache_path`, different from the global path — fact 2).
- `persist_session_cookies` = true. Language/cookie schemes: leave unset
  (inherit global) in v1.
- `CefRequestContext::CreateContext(settings, handler)` with the shared
  OpenEngine request-context handler. Keep the returned
  `CefRefPtr<CefRequestContext>` in the registry for the app's lifetime
  (v1 release policy, §6.4).

For the global/default Profile, browsers pass the global context
(`GetGlobalContext()`); do not also create a second context with the same
`cache_path` — two contexts on one Chromium Profile directory is the
corruption case fact 2 warns about. The registry therefore stores, per
ProfileID, either `.global` or a created context handle, and answers
browsers accordingly.

Incognito (D-P8): `CefRequestContextSettings` with **empty** `cache_path`
and `persist_session_cookies` = false. Section 10 lead erratum (2026-11-06):
private windows of one requested parent share a session context; each window
has a separate in-memory model. The last private window releases the context.
The current `IncognitoContextProvider` uses Default OTR until 0701 supplies
per-parent OTR creation. No cookies are seeded (Open privacy requirement;
the Arc hidden-profile assertion alone does not prove every general window).

### 6.3 What "Profile switch" means in one window

There is no global Profile switch (Arc §5.3 rule 7). A window shows one
focused Space; that Space's `profileID` is the window's current Profile.
Switching the focused Space to a Space on another Profile therefore means:

1. The sidebar selection changes first (existing `focusSpace` command).
2. The content area swaps the visible web-content view: each live tab's
   browser was created with **its own Space's** context (§6.1 fact 5), so
   showing Space B's tab shows a browser that already belongs to B's
   Profile. Nothing is re-parented and no cookie jar is swapped under a
   live page.
3. Browsers of different contexts coexisting in one `NSWindow` (one
   visible, the rest hidden/detached with their tabs) is allowed: CEF
   separates them by render process (fact 4). In Chrome style each browser
   still owns its native view; Open's AppKit container shows one at a
   time (Split View panes belong to one Space, hence one Profile, so a
   split never mixes contexts on screen).
4. `moveSpace(id:toProfile:)` / `updateSpace` Profile changes arrive as
   `.spaceProfileChanged` (§3.6). The App adapter must, for every live or
   sleeping tab of that Space: capture sleep history first when the memory
   milestone provides it (otherwise the tab keeps only its model URL),
   destroy the browser, and mark the tab placeholder. The next show
   creates a fresh browser on the new Profile's context and loads the
   model URL. Pinned URLs stay; logins come from the new Profile. This is
   the "you might get logged out" warning in §7.3. Because the model moves
   the instant the command runs, the App must show that confirmation
   **before** calling the command (§7.3) — there is no pending state in
   the model to confirm against afterwards.
5. Two windows may show Spaces on different Profiles at once. Each window
   resolves contexts through the same registry; no per-window context
   copies for regular Profiles.

Little Open windows carry a `profileHint` (routing plan: resolved from the
most recent Space). The hint selects the context for that window's single
browser; changing it in the window's Profile control destroys and
recreates the browser on the new context and reloads the URL (routing
plan §9.2 LA-7). Little Open tabs are not sidebar tabs and never enter
`BrowserModel`.

### 6.4 Lazy loading and memory

- Create a Profile's context on **first need only**: first show of a Space
  on that Profile, first Little Open hint of it, or first extension /
  site-settings access for it. Launch creates only the global (default)
  context, so cold launch keeps the architecture budget (sidebar ≤ 250 ms;
  engine work stays off the sidebar path).
- Cost model to design against (measure on the real build and record the
  numbers in the Step 6 PR; do not invent a budget): one loaded context =
  one Chrome Profile in the browser process — cookie/storage services,
  preference service, extension system host — plus one renderer per live
  tab. An idle loaded Profile with no live tabs still costs browser-process
  memory; that is why loading all Profiles at launch is rejected (D-P7).
  Per-Profile ad-block engines add their own documented cost (adblock-fork
  §9: one `Engine` per Profile, ~15–30 MiB heap with two lists — that
  plan's number to verify, not this plan's).
- v1 release policy: a created context lives until app quit. Do not
  release on Space close, window close (except incognito), or Profile
  delete without the §6.5 teardown. Idle-context eviction (release after
  last browser + timeout) is a follow-up once the sleep milestone provides
  history capture for every tab; note it in the Step 6 PR, do not build it.
- Tab browsers stay lazy as today: placeholders create browsers only when
  shown or recently used (architecture tactic). Profile laziness is one
  level above that and must not force placeholder tabs live.

### 6.5 Destroying contexts (delete and quit)

Only two teardown paths exist:

- **Profile delete** (§5.5): the App holds the Profile's
  `dataDirectoryName`, calls the model delete, then — through the
  registry — destroys every browser on that Profile's context, drops its
  registry entry (releasing the `CefRefPtr`), waits for OpenEngine to
  confirm release, and only then calls
  `ProfileDirectories.deleteProfileData`. If the Profile backed the global
  context this path can never run (default is undeletable, D-P1), so the
  global context is never released mid-session.
- **Incognito close**: destroy the window's browser, then release its
  context. No store writes follow (D-P8).
- **Quit**: destroy browsers, release non-global contexts, then
  `CefShutdown` (OpenEngine owns the order). Snapshot `saveNow` and store
  `flush()` calls happen before teardown completes, per §5.4's bootstrap
  order in reverse.

### 6.6 Assumed minimal `OpenEngine` interface (list — confirm, do not extend silently)

`docs/engine-api.md` does not exist, so this plan assumes exactly these
App-facing calls (ObjC++ in `Engine/OpenEngine/`, Swift-visible through the
App target only; names follow the adblock plan's `OpenEngineAdBlock.h`
convention). Steps 6–7 implement the Profile registry against this list.
If the engine spike ships different names, adapt the registry and record
the mapping in the Step 6 PR — do not change OpenKit to match.

| # | Assumed call | Contract |
|---|---|---|
| E1 | `OEProfileContextManager.shared` with `contextHandle(forProfileID:cachePath:persistSessionCookies:) -> OEContextHandle` (creates lazily, caches, `.global` for the default Profile) | One handle per ProfileID; repeat calls return the same handle |
| E2 | `releaseContext(forProfileID:) async` (destroys attached browsers first; completion after CEF release) | Used by §6.5 only |
| E3 | `makeWebContent(tabID:context:initialURL:) -> OEWebContent` with an `NSView`, `load(URL)`, `destroy()` | One web content per live sidebar tab; tab identity is Open's `ItemID`, never a CEF browser integer |
| E4 | Context events: `onCookieChanged` / storage-ready callback per context (or a pollable `isReady`) | App enables history/cookie-dependent UI only after ready |
| E5 | Ad-block hand-off: the `CefRequestContext` behind a handle accepts the adblock-fork §11 calls (`SetOpenAdBlock…`) | Profiles only supplies the handle + `AdBlock/lists/` directory (§5.1) |
| E6 | Incognito: `makeIncognitoContext(windowID:) -> OEContextHandle` (empty cache path) + `releaseContext` on close | No disk directory is ever passed |

OpenKit additions for the engine steps: **none**. The registry lives in
the App target (`App/ProfileContextRegistry.swift`, created by Step 7)
and reads `BrowserModel` + `ProfileDirectories`. Packages never import
`OpenEngine` or CEF.

---

## 7. UI data (view-models only) — scope item 4

The designer owns every visual. This section delivers data types the views
bind to. New file:
`Packages/OpenKit/Sources/OpenModel/ProfilesSettingsModel.swift`
(`@MainActor @Observable`, `import Foundation` + `import OpenModel` is
unnecessary inside the same target — the file is *in* `OpenModel`; keep
imports to `Foundation` and `Observation`). Follow
`LinksSettingsModel` ([routing.md](../routing.md) "Settings data"): drafts
stay visible when invalid, invalid drafts never reach save output,
validation is `issues()`, and the App hydrates a fresh model whenever the
Space/Profile set changes.

### 7.1 Settings › Profiles pane data

```swift
public struct ProfileRowData: Identifiable, Sendable {
    public var id: ProfileID
    public var name: String
    public var icon: SpaceIcon?
    public var spaceCount: Int
    public var favoriteCount: Int
    public var isDefault: Bool
    public var deleteBlock: ProfileDeleteBlock? // nil = deletable
    public var settings: ProfileSettings
}

@MainActor @Observable
public final class ProfilesSettingsModel {
    public private(set) var rows: [ProfileRowData] // BrowserModel order
    public func refresh(from model: BrowserModel)
    public func nameIssue(for name: String, excluding id: ProfileID?) -> ProfileNameIssue?
    public func createProfile(in model: BrowserModel, name: String, icon: SpaceIcon?) -> Profile?
    public func renameProfile(in model: BrowserModel, id: ProfileID, to name: String) -> Bool
    public func setIcon(in model: BrowserModel, id: ProfileID, icon: SpaceIcon?)
    public func updateSettings(in model: BrowserModel, id: ProfileID, settings: ProfileSettings)
    public func deleteProfile(in model: BrowserModel, id: ProfileID) -> Bool
    public func indicator(for spaceID: SpaceID, in model: BrowserModel) -> (name: String, icon: SpaceIcon?)?
    public var pendingDiskWipe: (name: String, directoryName: String)?
}
```

Rules:

- `refresh(from:)` rebuilds rows from the live model (space counts via
  `spaces(using:)`, delete state via `deleteBlockReason(for:)`, `isDefault`
  via identity with `defaultProfile`). The App calls it whenever
  `model.profiles` or `model.spaces` changes; the model never pushes.
- Create/rename delegate to §3 and surface `profileNameIssue` so the pane
  can show a reason next to the field. User-facing reason text (new Open
  copy; do not copy Arc's strings verbatim into the binary — the *facts*
  from §5.1 rule 2 are what §3.1 mirrors): empty → "Enter a name.";
  duplicate → "A Profile with that name already exists."; invalid →
  "That name cannot be used."; too long → "Use 64 characters or fewer.".
  Delete-blocked text: default → "The default Profile cannot be deleted.";
  spaces → "Move or delete its Spaces first. This Profile is used by
  N Space(s)." (compose with the live count).
- The pane edits `autoArchiveAfter`, `littleOpenAutoArchiveAfter`, and
  `searchEngineID` for the selected row by copying its `ProfileSettings`,
  mutating the copy, and saving through `updateProfileSettings` (one undo
  step, §3.3). Search-engine choices come from the existing search-engine
  table the command bar uses — do not hardcode a list here.
- Disk wipe (§5.5) is a separate row action, enabled only for a Profile
  that no longer exists in the model (post-delete, pre-`saveNow` the App
  holds its directory name in App state — this settings model exposes
  `pendingDiskWipe: (name: String, directoryName: String)?` set by the App,
  not by `deleteProfile(in:)`). Confirmation copy must state: data deletion
  is permanent, cookies/history/logins/extensions for that Profile are
  removed, and Undo can restore the sidebar Profile afterwards but not its
  browsing data. No visual is specified; the App wires the designer's
  dialog to this data.
- Clear-browsing-data and download-location rows (Arc Profiles pane,
  §7.2) have no data in this plan: history clearing needs the engine
  (§6) and the download setting does not exist (§0.2). Omit both rows in
  v1 rather than shipping dead controls.

### 7.2 Space creation Profile picker data

Space creation already takes a `ProfileID` (`createSpace`). The creation
sheet's data layer:

```swift
public struct SpaceProfileChoice: Identifiable, Sendable {
    public var id: ProfileID
    public var name: String
    public var icon: SpaceIcon?
    public var isDefault: Bool
}

public func spaceProfileChoices(in model: BrowserModel) -> [SpaceProfileChoice] // in ProfilesSettingsModel.swift
```

- Order is `model.profiles` order; the initially selected choice is the
  Profile of the window's current focused Space, else the default Profile.
- "Create a new Profile…" is a sheet-local mode, not a choice row with a
  sentinel ID: the sheet collects a name (validated by §3.1 through
  `nameIssue(for:excluding:)`), calls `createProfile`, then creates the
  Space on the returned Profile. On create failure the sheet stays open
  with the §7.1 reason text and no Space is created.
- Arc's create-Profile flow also offers "which Spaces should use this
  Profile?" (§5.1 rule 2). In Open that multi-select reuses
  `moveSpace(id:toProfile:)` per selected Space (§3.2). The data for it is
  `model.spaces` with each Space's current Profile name; no new type.

### 7.3 Change-Profile menu + confirm data (Spaces)

```swift
public struct ChangeProfileRequest: Sendable {
    public var spaceID: SpaceID
    public var spaceTitle: String
    public var fromProfileID: ProfileID
    public var toProfileID: ProfileID
    public var toProfileName: String
    public var warning: String // composed below
    public var dontShowAgainKey: String // "open.profiles.confirmInterProfileMove"
}
```

- Menu data: `spaceProfileChoices(in:)` with the Space's current Profile
  marked; choosing the current Profile is a no-op (the command returns
  `false`, §3.5).
- Confirm **before** the command (the model moves immediately, §6.3 step
  4). Warning copy (Open wording, Arc facts §5.4 rule 9): "Each Profile
  has different browser data, so you might get logged out or lose your
  progress in <Space title>. Its tabs will reopen with <Profile name>
  data." The don't-show-again toggle persists under
  `open.profiles.confirmInterProfileMove` in `UserDefaults` (App-owned,
  like the routing pane's `open.links.*` keys in
  [routing.md](../routing.md) "Persistence ownership"); when suppressed,
  the App calls `moveSpace` directly. Little Open Profile changes reuse
  the same request/key through the routing plan's coordinator.
- Profile indicator data (sidebar Space header / Little Open toolbar):
  expose `(name: String, icon: SpaceIcon?)` for a Space's Profile from
  `ProfilesSettingsModel` (`indicator(for spaceID:in:)`); show it only
  when `model.profiles.count > 1` (Arc's `shouldShowProfileIndicators`
  behaviour is a designer call; the data supports both).

### 7.4 What the App does with this data (wiring contract, no visuals)

App bootstrap order (extends §5.4): load snapshot → migrate → repair
(print/toast repaired Space titles + "reverted to using your Default
profile" fact from Arc §5.3 rule 8, in Open wording) → ensure directories →
set `ProfileArchiveSink` → observe `TreeChange` (handle
`.spaceProfileChanged` per §6.3 once the engine exists) → schedule snapshot
saves after every command (existing `SnapshotStore.scheduleSave`). A
`createProfile` success triggers `ensureProfileDirectories` for the new
directory name. No step in this list blocks first sidebar paint on engine
or store I/O beyond today's snapshot load.

---

## 8. Import from Arc: multiple Profiles — scope item 5

File: `Packages/OpenKit/Sources/OpenImport/ArcImport.swift`. The importer
stays read-only against the Arc folder and free of `OpenStore` (existing
layering: the CLI writes stores, §9.1). Chromium profile directories are
**recorded, not copied** (§8.4).

### 8.1 What changes in `profileID(for:)` (current: `ArcImport.swift:166–192`)

Keep the deterministic-ID scheme (`deterministicUUID(for:namespace:
"profile")` — re-import stays idempotent). Replace the key/name/dir
derivation with:

1. Build an Arc-Profile table **before** the Space loop, from up to three
   read-only sources, in this precedence order for each field:
   a. `StorableProfiles.json` when present. Its exact shape is unverified
      (no file exists on this Mac — [data-model.md](../re/data-model.md)
      §2.6). Parse leniently, mirroring the sidebar parser: accept an
      alternating `[id, object, …]` array or a keyed object; read `id`,
      then any of `name` / `displayName` / `title` for the display name,
      and any of `profileDirectoryBasename` / `directoryBasename` /
      `directory` for the Chromium directory. Unknown shapes contribute
      nothing and never fail the import (the existing "fail only on
      missing `sidebar.containers`" rule).
   b. `StorableProfileContainers.json` when present (same leniency) for
      Space→Profile links the sidebar does not carry.
   c. `User Data/Local State` → `profile.info_cache` (confirmed shape,
      [data-model.md](../re/data-model.md) §4): keys are Chromium
      directory names (`"Default"`), values carry the display `name`.
      Use it to name directories and to mint Profiles for directories no
      Space references (they still own history/cookies worth mapping).
2. For each distinct `Space.profile` value (existing loop), resolve:
   `{default:true}` → the default Arc Profile; a named ref → the table
   entry whose ID matches any string value in the ref object (the named
   ref's inner shape is inferred — accept the first `String` value, as
   today, but look the table up with it instead of using it raw).
3. Open Profile fields:
   - `id`: `deterministicUUID(for: <arc profile key>, namespace:
     "profile")` (unchanged scheme; key = `"default"` for the default,
     else the matched Arc ID / directory basename).
   - `name`: table display name when found, else `"Default"` for the
     default Profile, else `"Profile"`. Never overwrite a found name with
     a guessed one on re-import (IDs are stable; the CLI imports into a
     fresh output dir in v1, so this is about determinism, not merging).
   - `dataDirectoryName`: the Chromium `profileDirectoryBasename` when
     found (`"Default"` for the default), else
     `"Profile-" + <first 8 of the deterministic UUID, uppercase>`. Run it
     through the §3.1 path check: strip/replace `/` and `:` and reject
     `.`/`..` by falling back to the UUID form. Two Arc Profiles must
     never map to one directory: on a case-insensitive collision, suffix
     `-2`, `-3`, … in Space order. (Today's code uses the raw key as the
     directory name — a key containing `/` would escape `Profiles/`. This
     plan fixes that; single-Profile installs are unaffected because the
     default still maps to `"Default"`.)
4. A Space whose Profile ref matches nothing still creates its Profile
   (step 2 creates on demand, as today) — Import never falls back to
   Default silently. Snapshot-load repair (§3.7) is the fallback path;
   Import's job is to preserve what Arc had. Count these as
   `profilesGuessed` (§8.3) when neither name nor directory was found.

### 8.2 Per-Profile Favorites (fix the single-container assumption)

`topAppsContainerIDs` is an alternating `[ProfileRef, containerID, …]`
array ([data-model.md](../re/data-model.md) §2.1). Parse **all** pairs:
for each pair, resolve the `ProfileRef` through §8.1 and attach that
container's tabs (existing `buildNode` walk, `pinnedURL` set as today) to
that Profile's `favorites`, replacing the current "everything to default"
block (`ArcImport.swift:399–419`). A pair whose ref resolves to no Profile
creates it (§8.1 step 4). Single-Profile installs produce exactly today's
result; `report.favorites` stays the cross-Profile total.

Archive import already derives each record's Profile from its Space
(`model.md` "Archive and session import") — with §8.1 Spaces now map to
distinct Profiles, archive records follow with no code change beyond the
sink routing in §9.1 (the CLI groups `archiveRecords` by `profileID` into
per-Profile stores via `ProfileArchiveSink.store(for:)`).

### 8.3 Report additions (`ImportReport`, printed by `import-arc`)

Add and print (redacted: counts and directory basenames only, never names
with `--show-titles` off — directory basenames are not titles, but treat
them like hosts: print them, they are needed to verify the mapping):

```text
profiles=<n> profilesGuessed=<n> chromiumDirsFound=<n> chromiumDirsMissing=<n>
  profile dir=<basename> spaces=<n> favorites=<n>   (one line per Profile, Space order)
```

`chromiumDirsFound/Missing` counts §8.1 sources (a)/(c) directories that
do / do not exist as folders under `User Data/` in the copied Arc tree.
The sidebar accounted check and archive check are unchanged and must still
read OK, including on the live single-Profile data (acceptance §9.1 P-9).

### 8.4 Engine-data hand-off (later phase; this plan only records)

Do not copy any file out of `User Data/<dir>/` in this plan. Record the
mapping the phase-2 importer ([import-phase2.md](import-phase2.md)) needs
by making the §8.1 table deterministic: Arc directory basename ↔ Open
`dataDirectoryName` ↔ Open `ProfileID`. Phase 2 then, per Profile and with
its own consent steps: imports Chromium `History` into that Profile's
`HistoryStore` (its `--profile NAME` becomes the Arc basename, output
resolved through this mapping), imports search keywords, and defers
cookies/passwords to the engine `ProfileWriter` path (never blob copies —
import-phase2 §"Never copy Arc blobs"). Extensions are reinstalled by ID
from `Secure Preferences`, not copied. Open Profiles whose Arc directory
is missing (`chromiumDirsMissing`) import as empty engine Profiles; their
sidebar Spaces/tabs still import fully.

### 8.5 Verification limit (state it, do not hide it)

No multi-Profile Arc install exists on this Mac, and Arc must not be
launched by agents (AGENTS.md rule 4). §8.1–§8.2 are therefore verified
against a **synthetic copied fixture** (two Spaces on two refs, two
`topApps` pairs, hand-built `Local State`) plus the live single-Profile
regression (§9.1). The real multi-Profile capture is data-model.md §5
item 3 (user creates a second Arc Profile, quits Arc, agent reads the
files). Until then the importer ships with the lenient parser above and
the report lines make any mismatch visible instead of silent.

---

## 9. Acceptance — scope item 6

No unit tests (AGENTS.md rule 6). Every check below drives the real model
through the real CLI or the real app. Never paste `--show-titles` output
(URLs/titles) into docs or PRs; the §9.1 fixture uses synthetic names, so
its output is safe.

### 9.1 `openkit profiles …` CLI (new file `openkit/ProfilesCLI.swift`)

Register `profiles` in `openkit/main.swift` (usage line + `switch` case,
delegating to `runProfiles(args:)` on the main actor, following
`runRoute`). All subcommands take `DIR` (the OpenStore root, §5.1) as the
first argument, matching `dump`/`route`. A Profile reference
(`<profileRef>`) is: a full UUID, else an 8-char UUID prefix that matches
exactly one Profile, else an exact name, else a case-insensitive name that
matches exactly one. A Space reference is a full UUID or exact title (the
`route` convention). Ambiguous or unknown references exit 2 with
`error: unknown profile <ref>` / `error: unknown space <ref>` on stderr.

```text
openkit profiles DIR list [--show-titles] [--json]
openkit profiles DIR create --name NAME [--icon emoji:<text>|symbol:<name>] [--json]
openkit profiles DIR rename <profileRef> --name NAME
openkit profiles DIR set-icon <profileRef> [--icon emoji:<text>|symbol:<name>|none]
openkit profiles DIR assign-space <spaceRef> --to <profileRef>
openkit profiles DIR create-space --title TITLE --profile <profileRef>
openkit profiles DIR delete <profileRef>
openkit profiles DIR show <profileRef> [--show-titles]
```

Shared behaviour for every subcommand:

- Load with `SnapshotStore(root: DIR)`. Missing snapshot: `list` prints
  `no snapshot at DIR` and exits 0 (the `dump` behaviour). `create` alone
  starts from an empty `BrowserModel()` (no pre-seeded Profile/Space), runs
  the command, and saves — so the first `create` on a brand-new `DIR`
  mints the `Default` directory (§3.2). Every other mutating subcommand
  on a missing snapshot prints `error: no snapshot at DIR` and exits 1
  without writing. (The App's fresh-install model, with its seeded Space
  and window, is §5.4; the CLI deliberately starts emptier so P-2 can
  observe directory minting.)
- Before reading rows, run `ProfileMigration` + `repairMissing…` (§5.4
  order) and print one `repaired space <8> -> default profile` line per
  repaired Space. Mutating commands save after repair even when the
  command itself then refuses (repair is load maintenance, not part of
  the command's undo). This is the one case where a refused command still
  writes the snapshot; the §9.2 sequence hashes account for it by listing
  first.
- Mutating commands attach an `UndoManager` with `groupsByEvent = false`
  (the `CommandsDemo` pattern), run exactly one §3 command, and on success
  call `store.saveNow(model:)`. `create` additionally calls
  `ensureProfileDirectories` for the new Profile. Exit 0 on success.
- Model refusal (`nil`/`false`) prints the reason and exits 1 **without
  saving** (except the repair save above): duplicate/invalid name →
  `error: profile name <issue>` where `<issue>` is the `ProfileNameIssue`
  case name; delete of default → `error: profile is default`; delete with
  Spaces → `error: profile has N space(s)` (live count from
  `deleteBlockReason`); assign to missing/same Profile →
  `error: cannot assign space`. Usage errors exit 2.
- Output lines (IDs are 8-char prefixes, matching `printTree`):
  - `list`: one `profile <8> dir=<dataDirectoryName> spaces=<n>
    favorites=<n> default=<true|false>` per Profile in model order,
    name shown only with `--show-titles` (else `name=•••`), then
    `profiles=<n> spaces=<n>`. `--json`: sorted-keys JSON array of
    `{id, name, dataDirectoryName, spaceIDs, favoriteCount, isDefault}`
    (full names — JSON is a machine surface like `route --json`; do not
    paste it into docs with real data).
  - `create`: `created profile <8> dir=<dataDirectoryName>`.
  - `rename` / `set-icon`: `updated profile <8>`.
  - `assign-space`: `assigned space <8> -> profile <8>`. (The event
    proof for this command is the demo in §9.2; the CLI prints no event
    line.)
  - `create-space`: `created space <8> profile=<8>`.
  - `delete`: `deleted profile <8> archivedFavorites=<n>`.
  - `show`: the `list` line for one Profile plus one
    `space <8> title=•••` line per assigned Space (title only with
    `--show-titles`).
- `import-arc` wiring change in `CLI.swift`: after saving the snapshot,
  group `result.archiveRecords` by `profileID` and store each group
  through `ProfileArchiveSink.store(for:)` (replacing the single
  `ArchiveStore(root:)`), calling `ensureProfileDirectories` per imported
  Profile first. `archive-list DIR [--profile <profileRef>]` reads that
  Profile's store (default: the default Profile's). Report lines from
  §8.3 print here too.

Acceptance sequence (run in order on a fresh temp `DIR`; capture output):

| # | Command | Expected |
|---|---|---|
| P-1 | `profiles DIR list` (empty DIR) | `no snapshot at DIR`, exit 0 |
| P-2 | `profiles DIR create --name Personal`, then `profiles DIR create --name Work`, then `list --show-titles` | `Personal` (created first) gets `dir=Default` and `default=true`; `Work` gets `dir=Profile-…` and `default=false`; `profiles=2`, exit 0 |
| P-3 | `profiles DIR create --name work` (case-variant duplicate) | `error: profile name duplicate`, exit 1; snapshot file hash unchanged (`shasum -a 256 DIR/State/browser.json` before/after) |
| P-4 | `profiles DIR create-space --title Work Space --profile Work`, then `profiles DIR list` | Work shows `spaces=1`; Personal shows `spaces=0` |
| P-5 | `profiles DIR delete Work` | `error: profile has 1 space(s)`, exit 1, file hash unchanged (D-P1 at the CLI surface, non-default Profile) |
| P-6 | `profiles DIR assign-space "Work Space" --to Personal`, then `show Work` / `show Personal` | Space now under Personal (`spaces=1`); Work `spaces=0` |
| P-7 | `profiles DIR delete Personal` | `error: profile is default`, exit 1, file hash unchanged (default wins over the Spaces reason, §3.7 order) |
| P-8 | `profiles DIR create --name Temp`, then `profiles DIR delete Temp` | `deleted profile … archivedFavorites=0`, exit 0; `Profiles/<Temp's dir>/` was created by `create` and remains on disk (model delete never wipes, §5.5) — assert with `ls` |
| P-9 | `import-arc` on a copied live Arc folder into a second temp DIR, then `profiles DIR list`, `roundtrip DIR`, `archive-list DIR` | Sidebar/archive checks OK (existing behaviour), `profiles=1 dir=Default`, §8.3 lines print, `roundtrip OK` |
| P-10 | `dump DIR` + `roundtrip DIR` on the P-2…P-8 DIR | Tree shows both Profiles and correct `profile=` per Space; `roundtrip OK` (schema still 1) |
| P-11 | `profiles DIR rename Work --name "Work & Life"`, `set-icon Work --icon emoji:💼`, reload with `show "Work & Life" --show-titles` | New name/icon persisted; `dir=` unchanged (D-P3) |
| P-12 | Legacy migration: hand-place a dummy `DIR2/State/history.sqlite3` (+ a schema-1 snapshot with one Default Profile), run `profiles DIR2 list` twice | First run moves it to `Profiles/Default/State/history.sqlite3` (migration line/file check with `ls`); second run moves nothing; legacy path never reopens |

### 9.2 `commands-demo` extension (Step 3; Step 1 adds only the `describe` case)

Append a `profiles` section to `runCommandsDemo`
(`openkit/CommandsDemo.swift`), after the auto-archive sections and
before the final save, using the existing `check`/`step` helpers and
synthetic `example.com` data. Cover, at minimum (each is one `check`):

1. `createProfile` succeeds; duplicate (case-insensitive) returns `nil`
   with no event and no undo (undo afterwards removes the *previous*
   accepted command's effect, mirroring the placement-rejection check).
2. `renameProfile` + undo/redo; rename to duplicate returns `false`.
3. `moveSpace(id:toProfile:)` emits exactly one
   `.spaceProfileChanged` (`describe` output asserted), tabs keep IDs and
   `pinnedURL`s, Favorites stay with the old Profile; undo/redo.
4. `updateSpace(profileID:)` with a Profile change emits the same single
   event inside its combined undo.
5. `deleteProfile` with Spaces assigned returns `false` (nothing changes);
   default Profile returns `false`.
6. Unassign (move the Space away), seed a Favorite into the Profile,
   `deleteProfile` succeeds: one archive sink call, Favorite archived,
   undo restores Profile + Favorite and discards the archive row, redo
   re-deletes.
7. `repairMissingProfileReferences()`: point a Space at a random
   `ProfileID`, repair, assert it now uses the default and the returned
   ID list matches.
8. `indexMatchesRebuild(model)` after the section (existing helper).

The demo total grows from 66; acceptance is "`commands-demo` prints
`0 failed`" with the new checks included, on a fresh DIR and on a copy of
the imported snapshot (existing dual-run pattern in `model.md`).

### 9.3 App-phase cookie isolation **[NEEDS ENGINE]** (Step 7 gate)

Prerequisite: Steps 6–7 done; the app's automation channel exists (the
channel `architecture.md` "Testing" describes — open URLs, read tab/sidebar
state, run JavaScript, capture PNGs; never desktop driving). If the
channel cannot run JavaScript in a page yet, use the fallback below and
report the gap — do not substitute a unit test.

Local test server (one command, temp dir, synthetic data only):

```sh
python3 -m http.server 8931 --directory <fixture-dir>   # fixture sets a cookie
```

Serve one page `/set` that runs `document.cookie =
"open_profile_probe=A; path=/"` and one page `/read` that writes
`document.cookie` into `document.title`. Then, through the automation
channel on the real app:

1. Profile A Space (create `ProbeA` + Space via §7 data, or reuse the
   default): open `http://localhost:8931/set`, then `/read`. Assert the
   evaluated `document.cookie` contains `open_profile_probe=A`.
2. Switch the window's focused Space to a Profile B Space (new context
   loads lazily here). Open `/read` first: assert
   `open_profile_probe` is **absent**. Then open `/set` with value `B`
   (second fixture page or query-driven value) and assert `/read` now
   shows `B`.
3. Switch back to Profile A: `/read` still shows `A`, not `B`. Assert the
   two Engine directories each gained Chromium cookie data under
   `Engine/<dirA>/` and `Engine/<dirB>/` (`ls`; do not
   dump cookie values into the PR).
4. Incognito window: `/read` shows no probe cookie; set one, close the
   window, reopen incognito: still none. Assert no new directory appeared
   under `Profiles/`.
5. Cross-check Open stores: visit distinct URLs in A and B; each
   Profile's `history.sqlite3` (opened read-only via `openkit` suggest/
   history surface for that Profile, or `sqlite3` counts) contains only
   its own visits.

Fallback before the app exists (Step 6 only): drive two `cefsimple`
instances (or one harness with two request contexts, adblock-fork §13
style) with `--user-data-dir` roots whose request contexts use two
different `cache_path`s under one `root_cache_path`, load the same
fixture, and assert the same cookie outcomes over CDP
(`Network.getCookies` / `document.cookie`). Label the result
"cefsimple two-context check", never "app check".

### 9.4 Regression gate (every OpenKit PR in §10)

```sh
nice -n 10 swift build -c release -j 6   # in Packages/OpenKit; zero warnings/errors
.build/release/openkit roundtrip <DIR>
.build/release/openkit commands-demo <fresh DIR>        # 0 failed
.build/release/openkit commands-demo <import copy DIR>  # 0 failed
.build/release/openkit suggest-check                     # existing 31/31
.build/release/commands-dump                             # exit 0
```

Plus the §9.1 table for the step that touches the CLI/importer. Paste real
output into the PR description (the `model.md` verification style).

---

## 10. Step-by-step order — scope item 7

One PR per step unless a step says otherwise. Each step's acceptance is
its gate; do not start the next step on a red gate.

### Step 1 — Model commands (§3). Files: `OpenModel/BrowserModel.swift`, `OpenModel/Containers.swift` (no-op expected), `openkit/CommandsDemo.swift` (describe case only)

- Implement §3.1–§3.8 exactly: validation, create/rename/icon/settings,
  delete (archive Favorites), `moveSpace(id:toProfile:)`,
  `updateSpace` event reconciliation, `createSpace` fallback,
  `TreeChange.spaceProfileChanged`, default/query/repair helpers.
- Extend `CommandsDemo.describe(_:)` for the new case (required for the
  build). Do not add demo *checks* yet (Step 3).
- Acceptance: build gate (§9.4 build line); `commands-demo` on a fresh DIR
  still prints `66 checks passed, 0 failed` (no behaviour regression);
  `roundtrip` OK on an imported snapshot copy.

### Step 2 — Disk layout (§5.2, §5.4). Files: new `OpenStore/ProfileDirectories.swift`, new `OpenStore/ProfileArchiveSink.swift`, new `OpenStore/ProfileMigration.swift`, edits `OpenStore/HistoryStore.swift`, `OpenStore/ArchiveStore.swift`, and every `HistoryStore(`/`ArchiveStore(` call site in `openkit/`

- Implement `ProfileDirectories`, the `init(fileURL:)` refactor, the
  composite sink, and `ProfileMigration` exactly as §5 specifies.
- Acceptance: build gate; `commands-demo` 66/66 (now on per-Profile
  archive paths — assert `Profiles/Default/State/archive.sqlite3` exists
  under the demo DIR); `bench` still completes. Migration at this step is
  proven without the CLI (it lands in Step 3): a throwaway `/tmp` driver
  calling `ProfileMigration` on a temp root with a hand-placed legacy
  `State/history.sqlite3` shows the file moved, then a second call moves
  nothing. The CLI form of that check is §9.1 P-12, gated in Step 3.

### Step 3 — CLI (§9.1, §9.2). Files: new `openkit/ProfilesCLI.swift`, edits `openkit/main.swift`, `openkit/CLI.swift` (import/archive wiring), `openkit/CommandsDemo.swift` (profile checks)

- Implement the full `profiles` command set, the `import-arc` per-Profile
  archive grouping, `archive-list --profile`, and the §9.2 demo section.
- Acceptance: every row P-1…P-12; `commands-demo` 0 failed with the new
  checks on fresh + imported DIRs; full §9.4 gate.

### Step 4 — Import (§8). Files: `OpenImport/ArcImport.swift`, `openkit/CLI.swift` (report lines)

- Implement §8.1–§8.3 (profile table, per-Profile Favorites, report).
- Acceptance: P-9 live-data regression (counts unchanged from `model.md`'s
  recorded live import: 46 items accounted OK, same Spaces/favorites
  totals); synthetic two-Profile fixture (build it under a temp dir from
  copied live files: duplicate one Space onto a named ref, add a second
  `topApps` pair and a `Local State` with two `info_cache` entries) shows
  `profiles=2`, correct per-Profile `spaces=`/`favorites=` lines, and
  `roundtrip OK`. Redact as usual; synthetic fixture output is safe.

### Step 5 — UI data (§7). Files: new `OpenModel/ProfilesSettingsModel.swift`

- Implement rows/choices/request types and the wiring contract's data
  half. No views, no App target (it does not exist yet — this step is
  data-only and compiles into `OpenModel`).
- Acceptance: build gate; §9.4 gate; a throwaway `/tmp` driver (Swift
  interpreter against the release build, the routing plan's Settings-probe
  pattern — not a committed test) loads an imported snapshot, lists rows,
  creates/renames/deletes through the settings model, and asserts the
  §7.1 block reasons. Delete the driver or leave it in `/tmp`; commit
  nothing extra.

### Step 6 — Engine contexts (§6.2, §6.4–§6.6). **[NEEDS ENGINE]** Files: `Engine/OpenEngine/` profile-context manager (per §6.6), App registry `App/ProfileContextRegistry.swift`

- Gate: the engine spike has delivered `OpenEngine` + an App target. If
  either is missing, stop and report; Steps 1–5 stand alone as the M5
  OpenKit deliverable.
- Implement E1–E6 wiring: global = default Profile, lazy per-Profile
  contexts, incognito contexts, teardown. No OpenKit edits.
- Acceptance: §9.3 fallback (cefsimple two-context cookie check) passes;
  launch with 3 Profiles creates only the default context (registry log /
  `Engine/` directory mtimes: only `Engine/Default/` touched);
  showing a second Profile's Space creates exactly its context.

### Step 7 — App wiring + full isolation (§6.3, §6.5, §9.3). **[NEEDS ENGINE]** Files: App target (Space-focus content swap, `.spaceProfileChanged` handling, delete teardown, §7.4 bootstrap)

- Wire §7.4 bootstrap, §6.3 switch semantics, confirm-before-move (§7.3),
  and §5.5/§6.5 delete ordering.
- Acceptance: §9.3 in full on the real app (cookies, incognito, per-
  Profile history), plus a `moveSpace` live check: a logged-in fixture
  page in a Space shows the logged-out state after the Space moves to a
  fresh Profile and its tab is reshown, and the original state returns
  when moved back (fresh browser each way; sidebar IDs unchanged —
  assert tab ID equality through the automation channel).

### Step 8 — Hand-off record (docs only). Files: this plan (errata), `docs/model.md` (Profiles section), `docs/followups.md` if needed

- Record: measured per-context memory (Step 6), the real
  `OpenEngine` name mapping if §6.6 drifted, the multi-Profile Arc
  capture status (§8.5), and the deferred items (idle-context eviction,
  download-location setting, tab-level cross-Profile move, Chromium
  engine-data import per §8.4). Update `model.md` so the next agent reads
  Profiles as implemented, not planned.

PR slicing: Steps 1–3 may land as one OpenKit PR only if the diff stays
reviewable; otherwise 1+2 together, 3 alone. Steps 4 and 5 are separate
PRs. Steps 6–7 are engine/App PRs. Branch names follow the repo pattern
(`t3/profiles-model`, `t3/profiles-cli`, …); one PR per branch against
`main`, verified as above.

---

## 11. Risks and open questions

| # | Item | Handling |
|---|---|---|
| Q1 | Named Arc Profile ref shape and `StorableProfiles.json` fields are unverified (no multi-Profile install; Arc must not be launched by agents) | Lenient parser + report lines (§8); real capture is a user action (data-model.md §5 item 3). Does not block Steps 1–3 |
| Q2 | `ProfileSettings` has no download-location field, though Arc scopes it per Profile | Out of scope (§0.2); add with the downloads milestone as a whole-settings replace (no DTO break: `ProfileDTO.settings` gains a keyed field with a decode-default, planned there, not here) |
| Q3 | Idle request-context eviction could cut memory but risks destroying extension/session state | v1 keeps contexts until quit (D-P7); follow-up after sleep history capture exists (§6.4) |
| Q4 | Global favicon cache leaks "some Profile visited this origin" | Accepted and documented (D-P6, §5.3); revisit only if a privacy review flags it — the fix is a `profile` column + per-Profile files, contained in `OpenStore` |
| Q5 | Undo after disk wipe restores a Profile with empty browsing data | Confirmation copy states it (§7.1); wipe is a separate user action, never automatic (§5.5) |
| Q6 | Arc's exact Profile-name length cap and invalid-character set are unverified | Open rules in §3.1 (64 chars; path-unsafe set). Verify on a fresh Arc Profile only if the user offers a runtime check; do not block on it |
| Q7 | Two windows on different Profiles + one global ad-block/UI state could mix Profile-scoped panels (Site Control Center, Settings selection) | Panels must resolve their Profile from their window's focused Space at open time (routing/suggest already do); Step 7 acceptance spot-checks the cookie check in the second window |
| Q8 | `updateSpace` currently lets any caller change `profileID` silently | §3.5 makes it emit `.spaceProfileChanged`; existing callers (Space editor) gain correct engine behaviour without signature change. Flagged here so the Step 1 reviewer checks both call sites |

## 12. Sources and evidence index

- Repo: [AGENTS.md](../../AGENTS.md), [architecture.md](../architecture.md),
  [model.md](../model.md), [routing.md](../routing.md),
  [plan.md](../plan.md); code in `Packages/OpenKit/Sources/` as cited per
  section (file:line at time of writing).
- Reverse engineering (facts in our own words, per AGENTS.md rule 2):
  [features-core.md](../re/features-core.md) §2.6, §5, §7–§8;
  [data-model.md](../re/data-model.md) §2.1, §2.6, §4–§5.
- Sibling plans coordinated on paths: [adblock-fork.md](adblock-fork.md)
  §9.2/§12.3, [boosts-zap.md](boosts-zap.md) §4,
  [memory-fork.md](memory-fork.md) §7.5,
  [import-phase2.md](import-phase2.md), [routing-little-open.md](routing-little-open.md).
- CEF (local tree, read-only): `cef/include/cef_request_context.h`,
  `cef/include/cef_browser.h`, `cef/include/internal/cef_types.h`
  (CEF branch 8078, Chromium 156.0.8078.48).

---



## Appendix — Lead decisions (2026-10-25)

- Engine root (supersedes engine-patches lead decision 4, "default profile engine data at `Profiles/Default/`"): Chromium's profile data lives under one engine root, `<root>/Engine/` = `root_cache_path`. `Engine/Default` is the default Profile, `Engine/<dir>` every other Profile. Open's own per-Profile files stay in `Profiles/<dir>/`. A one-time, crash-safe move (`OpenStore/EngineLayoutMigration.swift`) brings older data over. The App runs it as its own launch step (`OpenDataRoot.prepareEngineLayout`), before the snapshot loads and before the engine starts; it never runs inside `SnapshotStore.load()`.
  - It runs only when `Engine/.open-layout` is absent and the old location holds a Chromium file (`Profiles/Default/Preferences` or `Profiles/Local State`). Fresh installs just write the marker.
  - It renames the ~30 top-level entries (same volume: no copy, no per-file fsync). A journal (`Engine/.open-layout-journal.json`) written first lists every rename, so at any crash each entry is in exactly one place and the next launch finishes. The default Profile's entries gather in `Engine/.migrating-Default`, published as `Engine/Default` with one rename; installation-wide files in `Profiles/` move to `Engine/`.
  - Before the publish, a failure (a locked entry, found by a pre-flight check, or a rename error) renames everything back. That launch uses the old layout (`root_cache_path` = `Profiles/`) and the next launch retries. A live owner of `Profiles/SingletonLock` also defers it.
  - **A legacy launch (lead decision 2026-10-26).** The default Profile runs on its old data. Every other Profile is deferred for that launch: it gets no engine context at all, never a memory-only (off-the-record) one, because that is the leak the E5 guard exists to prevent. Switching to a Space of a deferred Profile, selecting its tabs or opening a new tab there does nothing harmful: the tabs stay unloaded (a new tab's URL waits in the queue), nothing crashes, and stderr gets one line per Profile per launch (`Open: profile <dir> unavailable this launch (engine data still in the old layout)`). All context requests go through `EngineWebContentHostFactory.context(for:)`, which refuses them. The next launch retries the migration. Verified by e2e `migration_locked_file` (a locked file forces the legacy launch: the default cookie is there, the Work tab and a new Work tab stay unloaded, every page's context is `Default`, one log line). A user-visible notice is a follow-up (docs/followups.md).
  - After the publish, the rest is best effort and logged: the cache folder moves from `~/Library/Caches/<root>/Profiles/Default` to `…/Engine/Default`, stale `Singleton*` links and empty `Profiles/<dir>/Engine/` folders go away.
  - `Engine/Default` already holding a profile (anything but `.DS_Store`) is never mixed with the old one: the old files stay and the skip is logged (stderr and the system log, category `engine-layout`).
  - 27,005 files move in about 6–12 ms (it was 13.7 s with the earlier clone-and-compare design).
  Verified by `tools/e2e/engine_e2e.py --only profiles` (relaunch with persistent and session cookies, both-direction extension isolation with incognito access, disk profiles on disk, the legacy migration with a full file inventory, unreadable and locked files, a profile already in use, and a crash at each step).

- Approved as written: deleting a Profile is refused while Spaces use it and always for the default Profile; Space→Profile moves allowed after a confirmation; `dataDirectoryName` is permanent; schema stays 1.
- Q1 (named Arc profiles, StorableProfiles.json): keep the lenient parser; verify when a multi-profile Arc install is available.
- Q2: per-Profile download location is deferred to the downloads milestone.
- Phasing: model, disk layout, migration, import mapping, and the `openkit profiles` CLI now; [NEEDS ENGINE] steps after the App target + engine foundation land.
