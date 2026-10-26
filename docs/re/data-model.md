# Arc persisted data model (for Open Import from Arc)

Target: Arc 1.170.0 (build 89123), `company.thebrowser.Browser`, engine Chromium 156.0.8078.48.
This file is our own summary of facts (names, keys, shapes). It is not copied code.
Raw dumps stay in `.re/data-model/` (git-ignored).

How to read the marks:

- **confirmed (disk)** — seen in a real file on this Mac, read read-only.
- **confirmed (binary)** — seen as a string or symbol in `.re/bin/Arc-arm64` via `strings -a`, `nm`, or `otool`. That proves the name exists. It does not prove the full shape.
- **inferred** — our best guess from the two sources above. Verify before you rely on it.

Evidence on this machine is stronger than usual. The prompt expected no Arc folder yet, but `~/Library/Application Support/Arc` already exists with a real `StorableSidebar.json` (312 KB, 46 item objects, 4 Spaces). So sections 1–2 are mostly **confirmed (disk)**. Files that need a feature the user has not used yet (Boosts, extra Profiles, archived items) are still binary-only. Section 5 says exactly which files to re-check after sign-in and after first use of each feature.

All JSON below uses Swift `Codable` output style: sorted keys are not guaranteed, dates are numbers, enums encode as single-key objects. Do not assume pretty printing on disk matches this doc.

---

## 1. Every file Arc writes

Base folder: `~/Library/Application Support/Arc` (**confirmed (disk)**, `ls`).

### 1.1 Present on this Mac now

| File / folder | Meaning | Mark |
|---|---|---|
| `StorableSidebar.json` | Spaces, sidebar items, favorites. The import source. | confirmed (disk) |
| `StorableWindows.json` | Open windows, focused Space, sidebar width/mode, split state per window. | confirmed (disk) |
| `StorableArchive.json` | Auto-archive clock only on this install. See §2.7. | confirmed (disk) |
| `StorableLinkRouting.json` | Air Traffic Control rules + default destination. | confirmed (disk) |
| `StorableHome.json` | Home / media page sources and folder permissions. | confirmed (disk) |
| `StorableLiveData.json` | Live Folders data per profile. Empty here (`liveDataPerProfile: []`). | confirmed (disk) |
| `StorableCommandBarAdditionalRanking.json` | Command Bar ranking boost per profile. Empty here, `version: 2`. | confirmed (disk) |
| `StorableKeyBindings.json` | User hotkey overrides (`userOverrides: []` here). | confirmed (disk) |
| `StorableDefaultBrowserPrompts.json` | Default-browser prompt display history. | confirmed (disk) |
| `StorablePreviewsDataClient.json` | Sidebar preview widgets (calendar etc.). | confirmed (disk) |
| `StorableAuthState.json` | Arc account session (name, email, id). Open must ignore this. Never import. | confirmed (disk) |
| `StorableFirebaseEncryptionKey.json` | Sync encryption keys. Ignore. Never import or log. | confirmed (disk) |
| `SidebarItemsFaviconCache/`, `ArchiveItemsFaviconCache/` | PNG favicons, file name = 32-hex hash (e.g. `0b95c2ca…`, `file` shows PNG 16×16 / 192×192). Not needed for import. | confirmed (disk) |
| `ArchiveSnapshotCache/`, `BoostsImageCache/`, `Captures/` | Empty folders on this install. Filled by archive snapshots, Boost previews, captures. | confirmed (disk) |
| `RemoteAssetDirectory/` | Downloaded remote config (`BlockListConfiguration_*`, `CommandBarRemoteConfiguration_*`, `WebContentBehaviorConfiguration_*`). Ad-block / content rules, not user data. | confirmed (disk) |
| `User Data/` | Standard Chromium user-data dir (see §4). | confirmed (disk) |

### 1.2 Known to the binary but not created yet on this Mac

These names come from `strings -a .re/bin/Arc-arm64` (see `.re/data-model/strings-storable.txt`). The file appears only after the feature is used or after an older Arc version wrote it. An importer must treat every one as optional.

| File | Likely content | Mark |
|---|---|---|
| `StorableArchiveItems.json` | Archived tabs list. `StorableArchive.json` alone does not hold items here. | confirmed (binary): strings `StorableArchiveItems.json`, `StorableArchivedItems`, type path `StorableArchive/StorableArchive.swift` |
| `StorableBoostsData.json` | Boosts store. Source path `ARCClients/Sources/BoostsClient/StorableBoostsDataStore.swift`. | confirmed (binary) |
| `StorableCaptures.json` | Capture items (`StorableCaptureItems`). | confirmed (binary) |
| `StorableProfiles.json`, `StorableProfileContainers.json` | Arc Profile definitions and Space→profile containers (`storableProfileContainers`). | confirmed (binary) |
| `StorableLibrary.json`, `StorableTodosData.json`, `StorablePasteboardHistory.json`, `StorableDownloadMetadata.json`, `StorableSessionRestorationData.json`, `StorableDeveloperModeState.json`, `StorableDynamicLogLevels.json`, `StorableFeatureFlags.json`, `StorableMembershipCard.json`, `StorableASEConfiguration.json`, `StorableFirebaseLastSeenSchemaVersion.json`, `StorableFirebaseSyncDebugState.json` | Library, todos, pasteboard, downloads, session restore, dev/feature state. Out of import scope except session restore (maybe). | confirmed (binary) |

### 1.3 Outside Application Support

| Location | Content | Mark |
|---|---|---|
| `~/Library/Preferences/company.thebrowser.Browser.plist` | App settings (`plutil -p`): `arc_quitAlwaysKeepsWindows`, `nativeAdBlockEnabled`, `tidyTabsEnabled`, `instantLinksEnabled`, app icon, `machineID`. Import only if Open wants setting parity. | confirmed (disk) |
| `~/Library/Caches/Arc/User Data/Default/Cache/…`, `~/Library/Caches/company.thebrowser.Browser/` | Chromium cache + URL cache DB. Never import. | confirmed (disk) |
| `~/Library/Caches/Arc/EaselImagesCache/` (under `Caches/Arc`) | Easel images. Skip. | confirmed (disk) |

Rule for the importer: read only `StorableSidebar.json`, `StorableWindows.json`, `StorableLinkRouting.json`, `StorableArchiveItems.json` (if present), `StorableBoostsData.json` (if present), and `User Data/` (later phase). Ignore auth, Firebase, ranking, and cache files.

---

## 2. Schemas

Notation is TypeScript-like. It is our notation, not Arc source. `Time` means `CFAbsoluteTime`: a JSON number, seconds since 2001-01-01 00:00 UTC. Convert with `unixSeconds = value + 978307200`. Evidence: `createdAt: 713894758` lands in 2023, `timeLastActiveAt: 721008255` also plausible only under that epoch (**confirmed (disk)** + epoch math).

Every top-level Storable file carries `version: number`. Observed: sidebar/windows/archive/link routing/home/live data `1`, command-bar ranking `2` (**confirmed (disk)**). There is no per-item schema version. That is the main drift risk (§5).

### 2.1 Sidebar root

```ts
// StorableSidebar.json — confirmed (disk)
interface StorableSidebarFile {
  version: 1;
  sidebar: { containers: SidebarContainers }; // see below
  sidebarSyncState?: unknown;   // CloudKit sync mirror. Importer: ignore.
  firebaseSyncState?: unknown;  // Firebase sync mirror. Importer: ignore.
}
```

`sidebarSyncState` holds `{ items, spaceModels, container, syncMetadata, lastSuccessfulSyncDate }` and `firebaseSyncState` holds `{ syncData: { items, spaceModels, orderedSpaceIDs }, … }` (**confirmed (disk)**, top-level keys only). These duplicate the sidebar for sync. Never import from them. Always read `sidebar`.

#### The alternating array pattern

Arc encodes ordered maps as flat arrays that alternate key then value: `[id, object, id, object, …]`. You see it in `containers` siblings, in `spaces`, in `items`, and in `topAppsContainerIDs`. Any parser that assumes a plain object array breaks. This matches the public parsers in §3.

```ts
// containers is a 2-element alternating array — confirmed (disk)
type SidebarContainers = [
  { global: {} },                       // global (favorites) container marker
  {
    items: FlatArray<SidebarItem>;      // [id, item, id, item, …], 92 entries = 46 items here
    spaces: FlatArray<Space>;           // [id, space, id, space, …], 8 entries = 4 spaces here
    topAppsContainerIDs: [ProfileRef, string]; // [{default:true}, "<container item id>"]
  }
];

type FlatArray<T> = (string | T)[]; // even index = id string, odd index = object with same id
type ProfileRef = { default: true } | { /* named profile id */ }; // only {default:true} observed
```

`topAppsContainerIDs` still uses the old name. In the UI these are Favorites (the pinned row above Spaces). Strings confirm both names: `topApps`, `topAppsContainerIDs`, `favorite`, `selectedFavorites` (**confirmed (binary)**). Import them as Favorites.

### 2.2 SidebarItem — one row of the sidebar

```ts
// confirmed (disk): all 46 objects share these 8 keys
interface SidebarItem {
  id: string;              // UUID (upper-case) OR sentinel / short string id, see §2.5
  parentID: string | null; // container item id, folder id, split id, or null (top-level containers)
  childrenIds: string[];   // ordered child ids. Spelling is "childrenIds" (lower-case d).
  title: string | null;    // user-visible override. null in 27 of 46 here.
  createdAt: Time;
  isUnread: boolean;
  originatingDevice: string | null; // device UUID or null
  data: ItemData;
}

type ItemData =
  | { tab: TabData }
  | { itemContainer: { containerType: ContainerType } }
  | { list: {} }                 // folder
  | { splitView: SplitViewData }
  | { easel: EaselData }
  | { welcomeToArc: { tabType: string; timeLastActiveAt: Time | null } }
  | { note: unknown };           // confirmed (binary) string "note"; not present in this install

type ContainerType =
  | { spaceItems: { _0: string } }        // _0 = Space id this container belongs to
  | { topApps: { _0: ProfileRef } };      // favorites container for a profile
```

Field notes:

- `data` is a single-key enum. Branch on the key. Unknown keys must be skipped, not fatal (future Arc builds add cases like `note`).
- `title` vs `tab.savedTitle`: both exist. Items with a non-null `title` here are mostly pinned/favorite tabs and the one folder. Best rule (**inferred**): display title = `title ?? tab.savedTitle ?? host`. Import should store `title` as the custom name only when it differs from `savedTitle`, else leave the tab title live.
- Order lives in the parent's `childrenIds`, not in array order of `items`. The flat `items` array order is not the sidebar order. Rebuild order from `childrenIds` (root containers have `parentID: null`).

#### TabData

```ts
// confirmed (disk): 33 tab items
interface TabData {
  savedURL: string;                       // always present
  savedTitle: string;                     // always present (key exists in all 33)
  savedMuteStatus: "allowAudio" | "mute"; // "allowAudio" observed; "mute" is the binary string pair
  timeLastActiveAt?: Time;                // present in 27 of 33
  activeTabBeforeCreationID?: string;     // present in 22 of 33. Tab that was active when this tab opened.
  referrerID?: string;                    // present in 4 of 33. Opener tab id.
  customInfo?: { iconType: IconType };    // 1 of 33. Custom emoji icon for the tab.
}
```

There is no favicon URL, no scroll state, no Chromium tab id in the sidebar file. Favicons come from `SidebarItemsFaviconCache/` (hash-named PNGs) or from Chromium `Favicons`. Do not try to map cache file names back to items without more evidence (**inferred**: hash input unknown).

#### Containers, folders, splits

- **Container rows** (`itemContainer`, 9 here) are structural. Their `childrenIds` are the real tab lists. A `spaceItems` container is either the Space's pinned section or its today (unpinned) section — which one is decided by the Space's container id lists (§2.3), not by the container row itself. The `topApps` container's children are Favorites.
- **Folder** is `data: { list: {} }` (1 here, "Arc Basics", 6 children). The payload is empty. Folder name = item `title`. Nesting is only via `parentID` + `childrenIds`, so folders nest to any depth (**confirmed (disk)** structure; deep nesting beyond 1 level **inferred**).
- **Split View** is an item too:

```ts
// confirmed (disk): 1 split, 2 child tabs
interface SplitViewData {
  layoutOrientation: "horizontal" | "vertical"; // "horizontal" observed
  itemWidthFactors: number[];  // pane ratios. Empty here.
  focusItemID: string | null;
  customInfo: unknown | null;
  timeLastActiveAt: Time | null;
}
```

The split item's `childrenIds` are its pane tabs (here `browserCompanySubstack`, `arcTwitter`), and each pane tab's `parentID` is the split id. Import as a Split group with ordered panes. Do not flatten splits into loose tabs.

- **Easel** (`easel`, 1 here): `{ easelID, creatorID, title, shareStatus: "readOnly", timeLastActiveAt }` (**confirmed (disk)**). Notes are expected as a sibling case (`note` string, **confirmed (binary)**) but absent here. Open v1 scope excludes Easels and Notes. Importer: skip both, count them, and report the count. Never drop them silently.

### 2.3 Space

```ts
// confirmed (disk): 4 spaces. spaces is the alternating array from §2.1.
interface Space {
  id: string;                 // UUID or "thebrowser.company.defaultPersonalSpaceID"
  title?: string;             // absent on the default personal Space (title is null/absent there)
  profile: ProfileRef;        // { default: true } on all 4 here
  containerIDs: (string | "unpinned" | "pinned")[]; // legacy flat form, see below
  newContainerIDs: (string | { pinned: {} } | { unpinned: { _0: { shared: {} } } })[];
  customInfo: {
    iconType?: IconType;
    windowTheme?: WindowTheme;
  };
}

type IconType =
  | { emoji: number; emoji_v2: string }  // emoji = Unicode scalar (e.g. 128188 = 💼), emoji_v2 = the string
  | { icon: string };                    // named icon, e.g. { icon: "planet" }

interface WindowTheme { // full shape: runtime-observations.md §3.3
  semanticColorPalette: { appearanceBased: { light: ColorSet; dark: ColorSet } };
  primaryColorPalette: { tintedLight; midTone; shaded; shadedDark };  // each a Color
  background: { single: { _0: { style; contentOverBackgroundAppearance?: "light" | "dark"; isVibrant: boolean } } };
  windowAppearance?: "light" | "dark";  // confirmed (binary) as an optional field; not seen on disk
}
// ColorSet: 12 keys (background, backgroundExtra, title, subtitle, hover, focus,
// foregroundPrimary/Secondary/Tertiary, minContrastColor, maxContrastColor, cutoutColor),
// each { red, green, blue, alpha, colorSpace: "extendedSRGB" }
```

Background style cases, confirmed (binary) from the Swift reflection records (`__swift5_fieldmd`, 2026-10-25):

- `color._0` is one of `basicColor { color, translucencyStyle? }`, `blendedSingleColor { color, translucencyStyle?, modifiers }`, `blendedGradient { baseColors, overlayColors, translucencyStyle?, modifiers, wheel }`. `basicColor` was not seen on disk.
- `translucencyStyle`: `light`, `dark`, `auto`. Only `light` was seen on disk.
- `modifiers`: `{ noiseFactor, intensityFactor, overlay }`. `overlay` is the grain texture: `grain`, `sand`, `denim`, `tweed`. Only `grain` was seen on disk.
- `wheel`: `{ analogous: {} }` or `{ complimentary: {} }` (Arc's spelling). Only `analogous` was seen on disk.
- How the editor derives the colors and palettes: `design-tokens.md` §6.5.

Container id lists need care. One Space here reads:

```json
"containerIDs":    ["unpinned", "<todayContainerItemId>", "pinned", "<pinnedContainerItemId>"],
"newContainerIDs": [{ "pinned": {} }, "<pinnedContainerItemId>",
                    { "unpinned": { "_0": { "shared": {} } } }, "<todayContainerItemId>"]
```

So `containerIDs` alternates too: marker, id, marker, id. `newContainerIDs` is the newer typed form and its order differs per Space (do not assume pinned first). Import rule (**confirmed (disk)** shape, mapping **inferred** but strongly implied by markers):

- The container item whose id follows `pinned` → its `childrenIds`, in order, are the Space's pinned tabs and folders.
- The container item whose id follows `unpinned` → its `childrenIds` are the Space's today (unpinned) tabs.
- Prefer `newContainerIDs` when present; fall back to `containerIDs`. Keep both parsers. Arc is mid-migration between the two.

`profile: { default: true }` on every Space here means one Arc Profile serves all Spaces in this install. A named profile would replace `default` with an id object (**inferred** from `ProfileRef` use in `topApps` and in `sidebarSyncState`). See §2.6.

Default sentinel ids (**confirmed (disk)**): `thebrowser.company.defaultPersonalSpaceID`, `…defaultPersonalSpacePinnedContainerID`, `…defaultPersonalSpaceUnpinnedContainerID`, `thebrowser.company.arcBasicsFolderID`, `thebrowser.company.arcBasics.splitViewID`, plus short ids like `arcTwitter`, `arcResources`, `sameEnergy` for seeded content. Treat any non-UUID id as opaque. Never generate or parse them.

### 2.4 Windows

```ts
// StorableWindows.json — confirmed (disk), 1 window here
interface StorableWindowsFile {
  version: 1;
  lastFocusedSpaceID: string;
  sidebarViewPreferences: { sidebarMode: "anchored" /* … */; sidebarWidth: number }; // 228 here
  windows: WindowState[];
}

interface WindowState {
  id: string; // UUID
  style: { standard: { sidebarContext: { global: {} } } }; // littleArc style inferred, see below
  focusedSpaceID: string;
  stayOnTop: boolean;
  sidebarMode: string;
  sidebarWidth: number;
  spacesWithCollapsedPinnedSections: string[];
  expandedItems: string[];       // expanded folder item ids (key present, empty here)
  itemCreatedDates: unknown[];   // alternating array when non-empty (inferred)
  itemLastActiveDates: unknown[];
  contents: {
    windowContents: (string | { id: string })[]; // alternating; one content = one shown item/split
    splitViewState: { windowContentIDs: string[]; focusedContentID: string };
    windowContentSidebarItemMap: { keysToValues: unknown[] }; // content id -> sidebar item id
  };
}
```

Importer use: restore one window per entry, focus `focusedSpaceID`, and reopen `windowContents` in order. `style` variants: only `standard` is on disk. Binary strings show `WindowStyle`, `littleArc`, `peek`, `incognito` as window concepts (**confirmed (binary)**), so expect `style: { littleArc: … }` on machines that had Little Arc windows open. Parse `style` as a single-key enum and default unknown styles to a standard window.

### 2.5 IDs and ordering summary

- Item, Space, window, and rule ids are upper-case UUID strings, except seeded/sentinel string ids (§2.3). Never assume UUID format.
- Parent/child is stored twice: child `parentID` and parent `childrenIds`. Trust `childrenIds` for order. Cross-check `parentID` and repair mismatches by preferring `childrenIds` (**inferred** repair rule).
- Arrays named `items`, `spaces`, `windowContents`, `containerIDs`, `topAppsContainerIDs`, `folderToPermissions`, `dataSourcePreferences` are alternating `[key, value, …]` encodings of ordered dictionaries. This is the single most important parser fact.

### 2.6 Profiles, Boosts, site settings (partial)

**Arc Profiles.** No `StorableProfiles.json` exists on this Mac, yet the binary knows `StorableProfiles.json` and `StorableProfileContainers.json`, plus keys `profileDirectoryBasename`, `defaultProfileDirectoryBasename`, `sourceProfileDirectoryBasename` (**confirmed (binary)**). Model (**inferred**): an Arc Profile has an id, a display name, and a `profileDirectoryBasename` that names its Chromium folder under `User Data/` (`Default` for the default profile). Spaces point at a profile via `Space.profile`. Multiple Spaces can share one profile (all 4 do here). Importer: create one Open profile per distinct `Space.profile` value, defaulting to a single profile. Verify field names against a real multi-profile install before shipping (§5).

**Boosts.** `StorableBoostsData.json` is absent here. Binary evidence: `StorableBoostsDataStore.swift`, `BoostsStorageFirebaseImpl` (so Boosts also sync via Firebase), keys `boostID`, `boostTitle`, `activeBoosts`, `boostSnapshots` (**confirmed (binary)** names only). The Boost payload (CSS/JS/Zap rules per host) was not recoverable without a real file or a Ghidra query, and inventing fields would be worse than omitting them. Importer v1: if the file exists, preserve it raw and surface Boost names only if a `title`-like key is present; do not guess the rule schema. This is the weakest part of this doc and is flagged in §5.

**Site settings / Site Control Center.** These live in Chromium, not in Storable files: `User Data/Default/Preferences` → `profile.content_settings.exceptions` (103 exception types present here, mostly empty) plus per-site entries when the user changes a site (**confirmed (disk)** keys). Content-blocking lists live in `RemoteAssetDirectory/BlockListConfiguration_*` and `WebContentBehaviorConfiguration_*`. Import site settings from Chromium Preferences in the Chromium phase (§4), not from the sidebar.

### 2.7 Remaining Storable files (shapes as found)

```ts
// StorableArchive.json — confirmed (disk). No item list here.
{ version: 1, autoArchiveStartTime: Time }
// Items, when they exist, are expected in StorableArchiveItems.json with
// per-item archivedAt / archiveReason (strings confirmed (binary): archivedAt,
// archiveReason, manuallyArchived, autoArchived). Exact wrapper shape: inferred.

// StorableLinkRouting.json (Air Traffic Control) — confirmed (disk)
{
  version: 1,
  rules: [{
    id: string, // UUID
    destination: { space: { _0: { mostRecent: {} } } } // | { littleArc: … } inferred for other rules
           | { littleArc: { _0: { mostRecent: {} } } }, // defaultDestination uses this form
    sourceComponents: [{
      id: string,
      componentType: { urlMatch: { _0: { contains: {} }, _1: string } } // _1 = host/pattern, e.g. "meet.google.com"
    }]
  }],
  defaultDestination: { littleArc: { _0: { mostRecent: {} } } }
}
// Enum spellings from binary: LinkRoutingURLMatchType, LinkRoutingWindowType (confirmed (binary)).
// Other match kinds (exact, suffix, app source) are inferred. Parse leniently.

// StorableHome.json — confirmed (disk)
{ version: 1, isOnboardedToMediaPage: boolean,
  preferences: { dataSourcePreferences: (string|boolean)[] }, // alternating: "documents", true, "screenshot", true, …
  permissions: { folderToPermissions: (string|{hasPermissions:boolean})[] } } // alternating: file:// URL, grant

// StorableLiveData.json — confirmed (disk), empty here
{ version: 1, liveDataPerProfile: [] } // Live Folder definitions appear after a Live Folder is created. Shape inferred.

// StorableKeyBindings.json — confirmed (disk)
{ version: 1, userOverrides: [] } // non-empty shape needs a customized-hotkeys install. Inferred: [{action, keys}].

// StorableWindows / CommandBar / others: see §2.4; ranking file is { version: 2, dataByProfile: {} }.
```

Little Arc has no sidebar item type. It appears as a window style (§2.4) and as a routing destination above. A standalone Little Arc window's tab is a normal `tab` item shown in a `littleArc`-style window (**inferred**).

---

## 3. Cross-check with public sources

We searched for open parsers of `StorableSidebar.json`. Findings agree with the disk evidence above on the one point that matters: importers read `sidebar.containers` and walk `childrenIds`.

| Source | What it shows | URL |
|---|---|---|
| `ivnvxd/arc-export` (via DeepWiki mirror; direct fetch was rate-limited, so treat details as second-hand) | A tool whose whole job is to locate and parse `StorableSidebar.json` on macOS and Windows (`…\LocalCache\Local\Arc\StorableSidebar.json`). Confirms the file is the canonical export surface on both platforms. | [deepwiki.com/ivnvxd/arc-export/3.3.1-json-parsing](https://deepwiki.com/ivnvxd/arc-export/3.3.1-json-parsing) |
| Chrome Side Bar for Arc Users (open source) | Chrome extension that imports "pinned sites, spaces, and bookmarks" from `StorableSidebar.json`. Confirms pinned + Spaces + favorites all come from this one file. | [github.com/monemone-org/ChromeSideBar](https://github.com/monemone-org/ChromeSideBar) |
| SigmaOS migration docs | Commercial importer that offers Arc → SigmaOS import of "bookmarks, history, saved passwords, cookies, and extensions". Confirms history/passwords/cookies/extensions are a separate Chromium-level import (§4), not part of the sidebar file. Search-snippet evidence only in this session. | [docs.sigmaos.com/arc](https://docs.sigmaos.com/arc) |
| SupaSidebar guide | States Arc can export `StorableSidebar.json` from settings and that third-party tools import it. Weak, marketing-grade evidence. | [supasidebar.com/blog/how-to-replicate-arc-features-any-browser-mac](https://supasidebar.com/blog/how-to-replicate-arc-features-any-browser-mac) |

What public sources did **not** give us: a published JSON schema, CodingKeys list, or version history. No Raycast Arc extension that reads `StorableSidebar.json` was found (Raycast results were generic bookmark tooling). So versioning knowledge is: every file self-versions (`version: 1`, ranking `2`), and Arc keeps a legacy (`containerIDs`) and a new (`newContainerIDs`) container encoding side by side. That dual encoding is itself the drift warning. Parser must accept both, plus unknown `data` cases, forever.

Caveat: the `arc-export` details above come from a DeepWiki summary because GitHub fetches returned HTTP 429 in this session. Re-check the repo README directly before coding against it.

---

## 4. Chromium profile data inside `User Data/`

`~/Library/Application Support/Arc/User Data/` is a stock Chromium user-data directory (**confirmed (disk)**). `Local State` → `profile.info_cache` lists exactly one profile here: `"Default"` (display name "Your Arc"), `profiles_order: ["Default"]`, `last_active_profiles: ["Default"]`. There is no `Bookmarks` file in `Default` — Arc does not use Chromium bookmarks for sidebar data. Do not look for bookmarks there.

Mapping (**confirmed (disk)** for `Default`; multi-profile part **inferred** from §2.6): Arc Profile → `User Data/<profileDirectoryBasename>/`, default → `User Data/Default/`. Spaces do not get their own Chromium folder. History, cookies, and logins are per Arc Profile, shared by every Space on that profile.

| Data | Location (per profile dir) | Format | Import note |
|---|---|---|---|
| History | `History` (+ `-journal`) | SQLite, standard Chromium schema. Tables incl. `urls(id,url,title,visit_count,typed_count,last_visit_time,hidden)`, `visits`, `downloads`. Schema dumped to `.re/data-model/sqlite-schemas.txt` from a copied file (live DB was locked). | Read `urls` + `visits`. Times are Chromium epoch (µs since 1601). Copy the DB before reading; Arc keeps it locked while running. |
| Cookies | `Cookies` | SQLite `cookies(host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,…)` (**confirmed (disk)** schema). | `encrypted_value` needs the profile key. On macOS Chromium that key lives in Keychain (`company.thebrowser.Browser` / Chrome Safe Storage pattern). Do not attempt decryption without a Keychain prompt design. |
| Logins | `Login Data` | SQLite `logins(origin_url,username_value,password_value BLOB,date_created,blacklisted_by_user,…)` + `password_notes` (**confirmed (disk)** schema via copy). | Same encryption caveat as cookies. `Login Data For Account` is the account-sync twin; prefer `Login Data`. |
| Autofill / payments | `Web Data` | SQLite `autofill`, `credit_cards(card_number_encrypted)`, `addresses`, `keywords` (search engines) (**confirmed (disk)**). | Import `keywords` early (cheap). Cards need decryption; defer. |
| Favicons | `Favicons` | SQLite (Chromium `favicons` + `icon_mapping`). DB was locked in session; schema is standard Chromium (**inferred** for this install). | Optional. Sidebar favicon PNG cache is easier for pinned tabs. |
| Extensions | `Secure Preferences` → `extensions.settings.<id>.manifest`, state in `Extension State/`, `Extension Rules/`, `Extension Scripts/` (LevelDB) | JSON + LevelDB (**confirmed (disk)**: 3 extension ids present, `last_chrome_version: 156.0.8078.48`). Extension payloads (`.crx`) cache in `User Data/extensions_crx_cache/` and `component_crx_cache/`. | Reinstall from the Web Store by id where possible. Copying `Extensions/<id>/<version>/` folders (absent here — no unpacked folder on this install) is the fallback; verify path on a machine with more extensions. |
| Sessions | `Sessions/`, `Sessions_Encrypted/` (both empty dirs here), `StorableSessionRestorationData.json` (binary-known) | Chromium session files + Arc restore file. | Prefer Arc's own `StorableWindows.json` for restore. |
| Site settings | `Preferences` → `profile.content_settings.exceptions` | JSON (**confirmed (disk)**). | Map per-origin exceptions in the Chromium phase. |
| Downloads | `History.downloads` + `StorableDownloadMetadata.json` (binary-known) | SQLite + JSON. | Low priority. |

`Local State` on this install has no `os_crypt` key (**confirmed (disk)**). That suggests cookie/password encryption keys are not in `Local State` here (Keychain-held, or ArcCore holds them). Flag this for the passwords phase; do not assume Chrome's `Local State.os_crypt.encrypted_key` flow works.

Engine note: `Preferences` → `extensions.last_chrome_version` and ArcCore version both read `156.0.8078.48`. Chromium 156 schemas above should match stock Chromium 156 docs. If they diverge, the dumped `.re/data-model/sqlite-schemas.txt` wins.

---

## 5. Importer mapping

Read order: sidebar first (structure), windows second (what was open), routing third, archive/boosts if present, Chromium profile data last (separate consent step for passwords/cookies).

| Arc concept | Where it lives | Fields to read | Open concept | Risk |
|---|---|---|---|---|
| Space | `StorableSidebar.json` → `sidebar.containers[1].spaces` (odd indices) | `id`, `title`, `profile`, `customInfo.iconType`, `customInfo.windowTheme`, container ids | Space (name, emoji/named icon, theme colors) | Default Space may have no `title`. Theme palette is deep; map foreground/background only, keep raw theme JSON aside. |
| Pinned section | Space `newContainerIDs`/`containerIDs` `pinned` id → that container item's `childrenIds` | Ordered child ids | Pinned tabs + folders in that Space | Dual encoding (§2.3). Prefer `newContainerIDs`. |
| Today (unpinned) section | Same, `unpinned` id → container `childrenIds` | Ordered child ids | Today tabs in that Space | Arc auto-archives these. Import all as open today tabs; let Open's auto-archive age them later. |
| Favorite | `topApps` container item's `childrenIds` (via `topAppsContainerIDs[1]`) | Ordered tab item ids | Favorite (top app) | Old name `topApps`. One favorites container per profile (**inferred** for multi-profile). |
| Tab | Sidebar item with `data.tab` | `savedURL`, `savedTitle`, `title`, `createdAt`, `timeLastActiveAt`, `customInfo.iconType` | Tab (pinned / today / favorite per parent) | `savedTitle` can be stale. Open should refresh titles on first load. Skip `welcomeToArc` tabs or import as a normal tab (**inferred**: they are onboarding pages). |
| Folder | Item with `data.list`, name in `title` | `title`, `childrenIds` (recursive) | Folder | Empty payload. Depth is unbounded; cap import depth and report truncation. |
| Split View | Item with `data.splitView`, panes in `childrenIds` | `layoutOrientation`, `itemWidthFactors`, `focusItemID`, pane tab ids in order | Split group | `itemWidthFactors` may be empty (equal panes). Pane tabs also appear as flat items; do not double-import them as loose tabs. |
| Archive item | `StorableArchiveItems.json` (if present) | Item shape + `archivedAt`, `archiveReason` (**inferred** wrapper) | Archived tab (closed, restorable) | File absent on this install. Build the parser after capturing a real file (§6). Until then, import nothing and say so. |
| Arc Profile | `Space.profile` (+ `StorableProfiles.json` if present) | Profile id, (name, `profileDirectoryBasename` **inferred**) | Profile + its Chromium data folder | Single-profile evidence only. Multi-profile field names unverified. |
| Window | `StorableWindows.json` → `windows[]` | `focusedSpaceID`, `contents.windowContents`, `splitViewState`, sidebar width/mode | Window with focused Space and open contents | `style` variants beyond `standard` unverified. Unknown style → standard window. |
| Air Traffic Control rule | `StorableLinkRouting.json` → `rules[]` | `sourceComponents[].componentType.urlMatch._1`, `destination` | Link-routing rule (host → Space / Little Arc) | Enum has more match kinds than the one observed. Import `contains` host rules; skip and count others. |
| Default link destination | `StorableLinkRouting.json` → `defaultDestination` | `littleArc` / `space` + `mostRecent` | Default external-link behavior | `mostRecent: {}` means "most recent Space" (**inferred**). |
| Boost | `StorableBoostsData.json` (if present) | Unverified (§2.6) | Boost (defer) | Highest risk. Do not ship a guessed Boost parser. |
| Easel / Note | Item `data.easel` / `data.note` | `easelID`, `title` | Skip in v1 | Count and report skipped items. Never fail the import over them. |
| History / passwords / cookies / extensions | `User Data/<profile>/` (§4) | Per-table fields in §4 | History, logins, cookies, extensions | Passwords/cookies need Keychain decryption design. This is a separate phase with separate user consent. |

General importer rules:

1. Parse leniently: ignore unknown keys, unknown `data` cases, and both sync states. Fail only if `sidebar.containers` is missing.
2. Walk `childrenIds` from the four roots (favorites container + per-Space pinned/today containers). Any item object never reached is an orphan — import orphans as today tabs in the first Space and log them (**inferred** recovery rule; better than dropping tabs).
3. Convert all `Time` values with the 2001 epoch (§2). Convert Chromium times with the 1601 µs epoch. Mixing these up is the easiest silent bug.
4. Keep Arc item ids in an import map (Arc id → Open id) so windows, splits, and routing can resolve references. Sentinel string ids map like any other id.
5. Never write back to Arc's folder. Copy `History`/`Login Data` before opening them (Arc locks them while running).

---

## 6. What to inspect once the user signs in / uses more features

The current install already has a signed-in sidebar, so most of §2 is verified. These checks close the remaining gaps. All reads are read-only; quit Arc first for the SQLite files.

1. `StorableArchiveItems.json` — archive one tab in Arc, quit Arc, then record the file's top-level keys and one full item. This locks the archive wrapper shape in §2.7.
2. `StorableBoostsData.json` — install or create one Boost, quit Arc, record top-level keys and one Boost object (redact any personal CSS selectors that name accounts). This replaces the §2.6 guess.
3. `StorableProfiles.json` + `StorableProfileContainers.json` + `User Data/` listing — create a second Arc Profile, assign it to one Space, quit Arc. Record: profile object fields, the new `User Data/<dir>` name, and whether `Space.profile` changes from `{default:true}`. This verifies §2.6 and §4 mapping.
4. `StorableWindows.json` with a Little Arc window and a split open — record the `style` variant key for Little Arc and a non-empty `windowContentSidebarItemMap.keysToValues`.
5. `StorableLiveData.json` after creating a Live Folder, and `StorableKeyBindings.json` after remapping one hotkey — record one entry of each.
6. `StorableCaptures.json` after one Capture, if Captures stay in scope.
7. Re-dump `StorableSidebar.json` structure counts (items by `data` kind) after normal use. Watch for a `note` item to confirm its payload keys.
8. On the Chromium side: with Arc quit, copy `User Data/Default/Favicons` and dump its schema (it was locked in this session), and confirm whether an `Extensions/` folder appears once an unpacked extension exists.

Status after capture session 2 (2026-10-26; copies in `.re/runtime/appsupport/s2-*`, details in `runtime-observations.md` §9):

- Item 2: still open. The test Boost was deleted before the final copy, so no `StorableBoostsData.json` exists.
- Item 3: in part. A Space on a second Profile stores `profile: {custom: {_0: {directoryBasename: "Profile 1", machineID: <UUID>}}}`. No `StorableProfiles.json` or `StorableProfileContainers.json` appeared in the copies. The `User Data/` listing was not taken.
- Item 4: done for Little Arc. `style.little` holds `modalState`, `downloads`, `shouldShowProfileIndicators`, `profile`, and `session {id, entryPoint {externalLink}, preferredFrame {anchor {topRight: [x, y]}, size}, startTime}`. Its `windowContentSidebarItemMap.keysToValues` has one pair in one Little Arc window and none in the other. A split with entries was not open at copy time.
- New: a collapsed folder that shows one child stores `expandedItems: [folderID, {peeked: {_0: [childID]}}]`.
- Item 5: `StorableKeyBindings.json` gained two timestamped copies (`StorableKeyBindings.<yyyy-MM-dd-HH-mm-ss-SSS>.json`); no custom binding was made.

Until items 1–3 are done, the importer should ship with archive, Boost, and multi-profile support disabled and visibly reported as "not imported", not silently skipped.

---

## Archive and session files (observed)

Source: read-only copies of `~/Library/Application Support/Arc/*.json`. Before: `.re/runtime/appsupport/*.json` (copied 21:07 PDT). After: `.re/runtime/appsupport/session1/*.json` (copied 21:35 PDT), right after a live UI session on 2026-10-24, 21:30–21:35 PDT (frames: `.re/runtime/sessions/20261024-213009-session-full/`). Tools: `python3 -I analysis/schema.py <file>`, `python3 -I analysis/redact.py <file>`, and our cross-file scripts `.re/runtime/analysis-20261024/schema/scripts/{archive,session,sbdiff,more,win,tla,theme,cbr,tabsids,order}.py` (outputs in `out-*.txt` next to them). Binary names: `strings -a .re/bin/Arc-arm64` → `.re/runtime/analysis-20261024/schema/arc-strings.txt`. Marks: **confirmed (disk)**, **confirmed (binary)**, **guess**. "Space 1–4" = position in `sidebar.containers[1].spaces`. Space 4 is the untitled default Space.

Time check: Storable `Time` + 978307200 = Unix seconds (§2). Example: `archivedAt` 814595546.33 → 2026-10-25 04:32:26 UTC = 21:32:26 PDT. Every time set during the session lands in 21:30:27–21:34:57 PDT (**confirmed (disk)**, `out-archive.txt`, `out-win.txt`).

### A. `StorableArchiveItems.json` (new, 2468 bytes, 3 entries)

```ts
// confirmed (disk) shape. Enum lists marked "binary" come from arc-strings.txt lines 233651–233665.
interface StorableArchivedItems {        // type name confirmed (binary)
  version: 1;
  items: FlatArray<ArchivedItem>;         // [itemId, entry, …]; key == entry.sidebarItem.id in 3/3
}
interface ArchivedItem {                  // all 4 keys present in 3/3
  sidebarItem: SidebarItem;               // full §2.2 item, same 8 keys
  reason: ArchiveReason;                  // plain string (raw-value enum), NOT a single-key object
  archivedAt: Time;
  source: ArchivedItemSource;             // single-key enum object
}
type ArchiveReason = "manual"             // 3 of 3 on disk
  | "auto" | "clearButton" | "clearTabGroup";       // binary only
type ArchivedItemSource =
  | { space: { _0: string } }             // 3 of 3; _0 = a Space id
  | { littleArc: unknown } | { standaloneSidebar: unknown } | { unknown: unknown }; // binary only, payloads unknown
```

- Full tab snapshot: yes. `data.tab.savedURL` and `savedTitle` are in 3/3 entries. `title` null 3/3, `isUnread` false 3/3, `childrenIds` [] 3/3. Optional tab keys vary as in the sidebar: `timeLastActiveAt` 2/3, `savedMuteStatus` 1/3, `referrerID` 1/3, `activeTabBeforeCreationID` 1/3. One entry has only `savedURL` + `savedTitle`.
- `sidebarItem.parentID` is null in 3/3, even for the entry that had a parent before. The old container is lost. Only `source` says where the item lived.
- No snapshot image or favicon field. guess: these live in `ArchiveSnapshotCache/` and `ArchiveItemsFaviconCache/`, keyed by item id (strings `ArchiveSnapshotCache`, `ArchiveItemsFaviconCache`, `faviconItemID` sit next to the archive types).
- §2.7 guessed a key `archiveReason`. The stored key is `reason`. The strings `archiveReason`, `autoArchived`, `manuallyArchived` exist in the binary but not in the file. guess: they are a close-action parameter and Archive-UI filter names (arc-strings.txt lines 244486, 245275).
- `spaceID_legacy` follows `items` in the same string run. guess: an older encoding of `source`. Parse leniently.

ID links (`archive.py`, matched by exact id):

| Entry | Key | Before sidebar | After sidebar | Notes |
|---|---|---|---|---|
| 1 | seeded `sameEnergy` | yes, child of the `topApps` (Favorites) container | gone | `createdAt` and `savedURL` equal the before item. Only `parentID` (→ null) and `tab.timeLastActiveAt` differ. |
| 2 | UUID | no | no | Created 21:32:57, archived 21:33:00. `referrerID` = `activeTabBeforeCreationID` = seeded tab `importLoginsAndBookmarks` (in both sidebars). |
| 3 | UUID | no | no | Created and archived 21:33:24. No `timeLastActiveAt`. |

- Result: 1 of 3 ids matched a before-sidebar item. 0 of 3 match the after sidebar, after `sidebarSyncState.items`, `StorableWindows.json`, or `StorableSessionRestorationData.json`.
- `source.space._0` = `thebrowser.company.defaultPersonalSpaceID` in 3/3. It is a valid Space id in both files. Entry 1 came from Favorites, not a Space container, yet its source is a Space. guess: `source` records the window's focused Space at archive time. Capture frame `0081-213221` shows the main window on Space 4 from 21:32:21.
- `originatingDevice`: null on the seeded item. Entries 2–3 carry the same device UUID as all 8 items created in this session.
- Reasons. All 3 are `manual`. guess: `manual` = the user closed or removed the item (entries 2–3 look like short-lived Peek or Little Arc tabs); `auto` = the auto-archive timer; `clearButton` = Today's "Clear"; `clearTabGroup` = clearing one group. Only `manual` is verified.
- Archived ids stay referenced. The first new Today tab's `activeTabBeforeCreationID` = the archived `sameEnergy` id (`out-sbdiff.txt`). Importer: tolerate dangling ids.
- `StorableArchive.json` is byte-identical before and after. `autoArchiveStartTime` = 20:54:22 PDT, before the session.

Importer: entries = odd indices of `items`. Display title = `sidebarItem.title ?? data.tab.savedTitle`. Restore target = `source.space._0`, else the first Space. Sort by `archivedAt`. Skip unknown `reason` and `source` cases; do not fail.

### B. `StorableSessionRestorationData.json` (new, 3894 bytes)

```ts
// confirmed (disk)
interface StorableSessionRestorationData {
  version: 1;
  mapping: { keysToValues: (RestorationKey | number)[] }; // alternating [key, int, …]; 10 pairs; keys are OBJECTS
}
interface RestorationKey {
  browser: {
    windowID: string;                     // = StorableWindows.windows[].id (10/10, one window)
    contextID: {
      contextType: { normal: {} };        // 10/10; "incognito" is the other case in the same string run (binary)
      profile: ProfileRef;                // { default: true } 10/10
    };
  };
  itemId: string;                         // = an after-sidebar item id (10/10, all `tab` items)
}
```

- `itemId` targets (`session.py`): 6 new Today tabs of Space 1, 1 pinned tab of Space 1, the new Favorite copy (D), and 2 seeded tabs in the Arc Basics folder (`arcMaxTutorial`, `importLoginsAndBookmarks`). 3 of 10 existed before the session. 0 are archived. 9 of 10 also appear in the window's `itemLastActiveDates`.
- Values: integers 541791020–541791031, 10 distinct, gaps at …021 and …029. They are not times. guess (strong): Chromium `SessionID`s of each item's WebContents. Evidence: `User Data/Default/Sessions/Tabs_<µs since 1601>` (SNSS header, Chromium's closed-tab store, file time 21:32:28 PDT) holds the int32 values …029, …035, …037 and none of the 10 mapped values (`tabsids.py`, counts only, nothing decoded). The binary logs "Web content came to SessionRestorationBrowserDelegate that doesn't have window id set. It would be impossible to bind later…" (**confirmed (binary)**). So the file binds Chromium tabs to Arc sidebar items per window and profile.
- No blob, base64, or Chromium session bytes in this file. Chromium's own files exist: `Sessions/Tabs_*` 4865 B and `Sessions_Encrypted/Tabs_*` 4985 B, both SNSS. There is no `Session_*` file. guess: Arc restores windows from its own Storable files and uses Chromium only for closed-tab history. Not decoded.
- Importer: ignore. The ints are Chromium runtime ids and mean nothing to Open.

### C. `StorableMembershipCard.json` (new, 242 bytes)

```ts
// confirmed (disk); values withheld
{ version: 1; title: string; shapeName: string; paletteNumber: number; backgroundBlobInfo: number[] /* 15 small ints */ }
```

Binary: `ARC/Sources/MembershipCard/StorableMembershipCardState+Dependencies.swift`, `AnimatingCardBlob`, "One year with Arc!" (**confirmed (binary)**). guess: the cosmetic Arc member card. `title` may be personal. Out of scope. Never import or log.

### D. What changed between before and after (structure only)

`StorableSidebar.json`, 319310 → 374405 bytes (`sbdiff.py`, `more.py`, `order.py`):

- Unchanged: top-level keys, `containers` keys, Space ids, Space order, the favorites container id.
- Items by `data` kind: tab 33 → 39, welcomeToArc 1 → 2, itemContainer 9 → 9, list 1 → 1, splitView 1 → 1, easel 1 → 1. Total 46 → 53: 8 new, 1 removed (archived `sameEnergy`, see A).
- Section children, pinned / today: Space 1 10/0 → 10/6. Space 2 9/1 → 9/1. Space 3 2/0 → 2/0. Space 4 1/0 → 1/1. Favorites 6 → 6.
- New Today tabs: 6 in Space 1, created 21:31:15–21:31:54. Each `activeTabBeforeCreationID` = the tab created just before it, a chain. The first one points to the then-active favorite. None has `referrerID`.
- Favorite swap: the seeded favorite in slot 6 was archived. A new UUID tab with the same `savedURL` and `savedTitle` took slot 6 (created 21:32:21, no `timeLastActiveAt`).
- In the same second, `thebrowser.company.arcGettingStarted` (`welcomeToArc`) moved from the Arc Basics folder to Space 4's today container (`parentID` changed). A new UUID `welcomeToArc` item with the same `tabType: "legacy"` took its index 0 in the folder. guess: the first visit to Space 4 forks some seeded items into UUID copies. Other seeded tabs (`arcMaxTutorial`, `importLoginsAndBookmarks`) were opened and kept their ids.
- Edits on existing items: `timeLastActiveAt` added or changed on 4 items. One seeded tab's `savedTitle` changed. No new keys inside any `data` kind. No new `data` cases.
- Space 4 gained `customInfo.windowTheme` (it had only `iconType`). New enum cases vs runtime-observations §3.3: background style `blendedSingleColor: { _0: { color: Color; modifiers: { overlay: "grain"; noiseFactor; intensityFactor }; translucencyStyle: "light" } }` (one color, no `baseColors`, `overlayColors`, or `wheel`), and `contentOverBackgroundAppearance: "dark"` (`out-theme.txt`; string `blendedSingleColor` **confirmed (binary)**). guess: the user picked a color in the theme editor.
- Split view item unchanged (`itemWidthFactors: []`, `focusItemID: null`). No new `splitView` item. guess: a Split View made in the session was not kept.
- `sidebarSyncState.items` 92 → 106 array entries (53 items, mirrors the sidebar). `lastSuccessfulSyncDate` → 21:34:57 PDT. `firebaseSyncState` same shape (`syncHealthStatus: {off: {}}`).

`StorableWindows.json`, 1235 → 2731 bytes (`win.py`, `tla.py`):

- `windows[]`: 1 → 1, same window id. Extra browser windows show in capture frames at 21:32:52 and 21:33:10 (`windows.tsv`), but the file at 21:35 has none of them. guess: closed windows are dropped.
- `lastFocusedSpaceID` and `windows[0].focusedSpaceID`: Space 1 → `thebrowser.company.defaultPersonalSpaceID`.
- `sidebarWidth`: 228 → 500, in `sidebarViewPreferences` and in the window. guess: 500 is the drag maximum (verify with runtime-observations §7 item 14).
- `expandedItems`: [] → `["thebrowser.company.arcBasicsFolderID", {expanded: {}}]`. It is an alternating map: item id → single-key enum. guess: folders absent from the map are collapsed.
- `itemCreatedDates`: [] → 8 pairs `[itemId, Time]`. The id set equals the 8 new sidebar items exactly. Each value equals the item's `createdAt`.
- `itemLastActiveDates`: [] → 10 pairs `[itemId, Time]`. Each value equals the item's `timeLastActiveAt` in the sidebar (10/10, difference 0). guess: a per-window copy of activity.
- `contents.windowContents`: still 1 entry, with a new content UUID that is not a sidebar id. `splitViewState.windowContentIDs` = [that id] and `focusedContentID` = that id. `windowContentSidebarItemMap.keysToValues`: [] → `[contentId, "importLoginsAndBookmarks"]`, so content id → shown sidebar item id.
- Unchanged: `spacesWithCollapsedPinnedSections: []`, `style: {standard: …}`, `stayOnTop: false`. No `littleArc` style was saved.

Other top-level files (`cmp`, byte size, parsed-key diff):

| File | Bytes before → after | Key-level change |
|---|---|---|
| `StorableCommandBarAdditionalRanking.json` | 47 → 2271 | `dataByProfile: {}` → `{ Default: { queriesToSelectedArchetype: {}, recentlySwitchedToTabs: [itemId, {elements: Time[], maxSize: 10}], typeTravelUsage: [{typeTravel: {_0: string}}, {executed: {elements: Time[], maxSize: 15}, frequency: number}, …] } }`. 1 switched-to item (= `sameEnergy`, at 21:32:21), 5 type-travel strings (typed text; withheld). The profile key is the Chromium folder name `Default`. |
| `StorablePreviewsDataClient.json` | 360 → 362 | Same keys. `lastRefreshed` and `currentDate` moved to 21:34:56 PDT. |
| `StorableLiveData.json` | 52 → 52 | Bytes differ; parsed JSON is equal (key order only). |
| `StorableArchive`, `AuthState`, `DefaultBrowserPrompts`, `FirebaseEncryptionKey`, `Home`, `KeyBindings`, `LinkRouting` | same | Byte-identical. |
| `StorableArchiveItems`, `StorableSessionRestorationData`, `StorableMembershipCard` | absent → 2468 / 3894 / 242 | New files (A–C). |
