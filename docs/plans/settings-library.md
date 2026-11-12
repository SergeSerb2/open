# Settings and Library — implementation plan for Open

Library update (2026-11-11): the Library portions of this historical plan are
superseded by [Library](../library.md). Library now uses a native AppKit panel
inside each browser window, with six sections and History always enabled.
Settings retains its own window and design. Easels and filesystem sources are
in scope under the current project rules; their Library entry points remain
default-off until implemented.

Status: plan (2026-10-25). Implementer: a coding agent with no other
context. Follow this file literally. Where this file says "Open choice",
the choice is final for v1. Do not re-derive it. Where this file cites
an RE fact, the citation is the evidence. Do not copy Arc assets, icons,
sounds, or text that names the Arc brand. The only allowed brand text
is "Import from Arc". Arc's "Little Arc" is "Little Open" in all
user-visible text. Search aliases may keep the old names.

Read first, in this order: `AGENTS.md`, `docs/architecture.md`,
`docs/model.md`, `docs/routing.md`, `docs/commands.md`,
`docs/suggest.md`, `docs/adblock-design.md`,
`docs/plans/adblock-fork.md` section 12, `docs/plans/import-phase2.md`
sections 3.5–3.7, `docs/memory-design.md` sections 1 and 3.3,
`docs/re/features-core.md` section 7, `docs/re/interaction-states.md`
section 18, and `docs/re/features-advanced.md` sections 7 and 9.5–9.6.
`docs/sleep.md` and `docs/adblock-lists.md` do not exist. Use
`docs/memory-design.md` for sleeping and `docs/adblock-design.md` plus
`docs/re/features-advanced.md` section 7 for lists.
`docs/design.md` does not exist yet. Visual values (colors, spacing,
fonts, radii) come from the `OpenDesign` design system when it lands.
This plan uses token names only. Do not hard-code color or font values.
Use the measured facts in section 1 for window size and layout.

## Goal

Ship two windows:

1. The Settings window. It edits every v1 preference. Each edit writes
   the right store at once and fires the right live effect at once.
2. The Library window. It shows the Archive, Downloads, and Captures.
   The user can search, restore, delete, reveal, and retry there.

Both windows use SwiftUI. The architecture allows SwiftUI for
low-frequency panels such as settings (`docs/architecture.md`).
The sidebar, tab rows, and window chrome stay AppKit. Do not use
SwiftUI for them.

## Success criteria

- Cmd+, opens Settings on the last used pane. The window is 684x650 pt.
  It has 6 tabs: General, Profiles, Links, Shortcuts, App Icon,
  Advanced. It has no Account, Max, or Staff tab.
- Every option in section 5 exists with the stated control, default,
  store, and live effect. No option is a dead control.
- The Shortcuts pane edits `OpenCommands` overrides. It shows
  conflicts. A save with an unexpected conflict does not write the file.
- The Links pane binds `LinksSettingsModel` (`OpenRouting`). It has the
  rules list, the default destination, and test-a-URL.
- The Advanced pane has ad blocking (global, per-list, allowlist),
  tab sleeping, and links to search-engine management.
- "Import from Arc" runs as a wizard from Settings. The secrets step
  asks for consent before any Keychain read. Phase 2 counts only.
- Home / Library (Cmd+Shift+L) opens the Library window. Archive,
  Downloads, and Captures each work end to end (section 6).
- `settings-preview` renders every pane to PNG at 1x and 2x with a
  synthetic profile. CLI checks prove each option writes the right
  store and logs the right action call (section 8).
- No unit tests. Verify end to end only (`AGENTS.md` rule 6).

## 0. Locked decisions (do not revisit)

| # | Decision | Why |
|---|---|---|
| D-1 | New SwiftPM target `OpenSettings` in `Packages/OpenKit`. It holds SwiftUI views plus view models. It imports no engine code and no `OpenEngine` / CEF. The app target implements the action protocols in section 3. | `docs/architecture.md`: packages never import the engine. Only the app joins the two. |
| D-2 | Settings window and Library window are each one shared `NSWindow` with an `NSHostingController`. Reuse the window. Do not open a second copy. | Arc uses one Settings window (`SettingsWindowController`, `docs/re/features-core.md` section 7.1; 684x650 in `docs/re/interaction-states.md` section 18). |
| D-3 | Ship 6 Settings tabs. Out of scope: Account, Max, Staff. | `docs/re/features-core.md` section 7.1 marks Account (account/sync), Max (AI), Staff (internal) as skip. `AGENTS.md` puts accounts, sync, and Arc Max AI out of v1 scope. |
| D-4 | App Icon ships with Open's own icons only. Referral unlocks do not ship. | `docs/re/features-core.md` section 7.1: App Icon is optional/cosmetic; unlocks are account. Hard rule 1 forbids copying Arc assets. Recreate icons. |
| D-5 | Per-profile values live in the browser snapshot (`ProfileSettings` and friends). App values live in `UserDefaults`. Key bindings live in one JSON file. Ad-block lists live in per-profile files. Routing rules live in the browser snapshot. Section 2 is the full registry. Do not invent a second store for the same value. | `docs/re/features-core.md` section 7.3 (Arc splits UserDefaults, JSON stores, Chromium prefs). `docs/routing.md` fixes routing ownership. |
| D-6 | The Links pane owns no second rule list. It binds the existing `LinksSettingsModel`. Saves go through `currentRouting()` into `BrowserModel`, then the normal snapshot save. | `docs/routing.md` "Settings data". Reuse beats rewrite. |
| D-7 | The Shortcuts pane owns no second key map. It reads and writes `KeyBindingStore` (`OpenCommands`) and uses `ConflictChecker` as the only conflict rule. | `docs/commands.md` "Key binding overrides". |
| D-8 | Search stays per-profile. The picker lives in the Profiles pane. Advanced only links to it and hosts the custom-engine editor sheet. | `docs/re/features-core.md` sections 4.5 and 7.2: search engine, suggestions, and custom engines are per Profile. |
| D-9 | Library v1 = Archive + Downloads + Captures (app-owned items only). Filesystem folder sources (Documents, Desktop, Downloads folders, Screenshots permission) are deferred to v1.1. Easels and Notes sources never ship. **Superseded (scope 2026-11-10; PB1 2026-11-12): folder sources ship in v1, see `docs/status.md`.** | Section 6.3 gives the justification. |
| D-10 | Fresh-profile search default is Google. Stored values never change. | `docs/suggest.md`: "Google is the default (Arc section 4.5 rule 11)." `ProfileSettings.init` now defaults to `duckduckgo`. That is a bug for fresh profiles. Fix the default only (Step 2). Do not migrate stored snapshots. |
| D-11 | Names: "Little Open" in all UI text. "Import from Arc" is the one allowed brand string. Command ids never change (`settings`, `view-library`, `view-downloads`, `view-archive`, `view-history`, `import-from-browser`). | `AGENTS.md` naming; `docs/commands.md` registry. |
| D-12 | No new third-party dependency. PNG rendering uses AppKit (`NSBitmapImageRep`, `cacheDisplay`). | `AGENTS.md` code conventions. |

## 1. Measured facts (use as-is; do not re-measure)

Source: `docs/re/interaction-states.md` section 18 and frames
F0147–F0151 / A0495–A0507 in
`.re/runtime/sessions/20261024-213009-session-full/`
(index: `.re/runtime/sessions/index-20261024.json`, state
`settings-window`). The PNGs contain personal data on the account tab.
View them to understand layout only. Never commit or copy them.

| Fact | Value |
|---|---|
| Settings window size | 684 x 650 pt. Standard titled window. It follows the macOS appearance. The window title is the selected tab name. |
| Tab bar | `NSToolbar`-style icon tabs. Arc order (8 tabs): account (named after the user), General, Profiles, Max, Links, Shortcuts, Icon, Advanced. The selected tab has a blue rounded highlight. |
| Open tab order (6 tabs) | General, Profiles, Links, Shortcuts, App Icon, Advanced. Keep the Arc relative order. Drop account, Max, Staff. |
| Pane layout | Grouped rounded boxes. Each row: label on the left, control on the right (switch, pop-up button, push button). |
| Profiles pane shape | Left list "Your Profiles" (name plus "N Spaces") with +, −, and edit buttons. Right side holds the per-profile form. |
| Shortcuts pane shape | A callout "Start with the basics" with one button "Learn the Essential Shortcuts" that opens the Essential Keyboard Shortcuts window (corrected by commandbar-completion Step 6, RE CC-29/CC-30: Arc's control is not a filter), a search field, a "Default Shortcuts" list, a "Custom Shortcuts" panel, "Reset All Shortcuts". |
| Links pane shape | Little Open section (illustration plus text, 3 toggles plus "Archive Little Arcs after: 6 hours (default)"), then Peek section (2 toggles). The Air Traffic Control rules editor is in the same pane (section 5.3). |
| Advanced pane shape | 9 toggle rows, then buttons "More Settings…", "Reset Translated-site Prompts", "Export Data". Open adds the Ad Blocking and Tab Sleeping groups (section 5.5). |
| General pane shape | 2 toggles, then "Previews" plus "Previews Settings…", then the Profile Settings hint plus "Profile Settings…" button. Open adds the rows in section 5.1. |

Design tokens: use `OpenDesign` tokens for the grouped box, row
padding, label font, control spacing, selected-tab highlight, and
section spacing when `docs/design.md` lands. Until then, use system
grouped-form defaults. A later design pass will swap the tokens. Do
not block this plan on tokens.

## 2. Persistence registry (every key; no others without a plan change)

Root: `~/Library/Application Support/Open/` (injectable in tests and
preview; `SnapshotStore` already uses this root). Snapshot file:
`State/browser.json` (`schemaVersion` 1; `docs/model.md`).
`UserDefaults` means `UserDefaults.standard` with the exact key below.
"Write" means the value changes at once on edit (no Apply button),
except where a section says Save.

### 2.1 App scope — `UserDefaults` (prefix `open.`)

| Key | Type | Default | Used by |
|---|---|---|---|
| `open.settings.lastPane` | String (`general`/`profiles`/`links`/`shortcuts`/`appIcon`/`advanced`) | `general` | Window restore |
| `open.general.automaticallyUpdate` | Bool | `true` | General; Sparkle (M9) |
| `open.general.warnBeforeQuitting` | Bool | `true` | General; quit confirm |
| `open.general.previewsEnabled` | Bool | `true` | General; hover Previews |
| `open.general.previewsFolders` | Bool | `true` | Previews sheet; folders (sidebar completion lead Q3); seeded once from stored previewsOnHover when absent |
| `open.general.previewsPages` | Bool | `true` | Previews sheet; pinned tabs and Favorites (lead Q3); seeded once from stored previewsOnHover when absent |
| ~~`open.general.previewsDelaySeconds`~~ | — | — | **Removed (lead ruling 2026-10-26)** to match Arc, which has no delay setting. The hover delay is fixed at 0.5 s (Open choice; one Arc sample ≈ 0.42 s) (`HoverPreviewMetrics.armDelay`, sidebar-completion §3.6). A stored value is ignored, not migrated. Removal: sidebar-completion Step S5b. |
| `open.sidebar.hideHintShown` | Bool | `false` | First-hide hint (sidebar completion §2.4) |
| `open.sidebar.autoArchiveBannerDismissed` | Bool | `false` | Auto-archive education dismissal |
| `open.sidebar.autoArchiveBannerEligible` | Bool | `true` | Auto-archive education eligibility |
| `open.links.externalInLittleOpen` | Bool (fallback `true`) | `true` | Links; routing (exists; `docs/routing.md`) |
| `open.links.littleOpenHotkeyEnabled` | Bool (fallback `true`) | `true` | Links; `GlobalHotkeyService` (exists) |
| `open.links.optionCommandClickLittleOpen` | Bool (fallback `true`) | `true` | Links; link clicks (exists) |
| `open.links.openPeekOtherSites` | Bool | `true` | Links; Peek trigger B (`docs/re/features-advanced.md` section 2.2, guess ON) |
| `open.links.openPeekShiftClick` | Bool | `true` | Links; Peek trigger C (guess ON) |
| `open.advanced.restoreWindowsOnLaunch` | Bool | `true` | Advanced; launch (`docs/re/features-core.md` section 3.7, guess ON) |
| `open.advanced.enablePictureInPictureOnLeave` | Bool | `true` | Advanced; PiP (`docs/plans/media-pip.md` §5; Arc `autoPipGloballyDisabled` is the inverse) |
| `open.pip.autoDisabledHosts` | [String] (lowercase hosts) | `[]` | PiP window menu "Turn off" / "Open automatically" (`docs/plans/media-pip.md` §4.4.5, §5). No Settings UI, as in Arc. |
| `open.pip.keepOnTop` | Bool | `true` | PiP and Document PiP menu "Keep Window on Top" (`docs/plans/media-pip.md` §4.4.5, §5). No Settings UI. |
| `open.advanced.allowWindowDraggingFromWebTop` | Bool | `false` | Advanced (Arc default unknown; Open choice OFF = safer) |
| `open.advanced.showFullURLWithToolbar` | Bool | `false` | Advanced (unknown; Open choice OFF = trimmed) |
| `open.advanced.enableBoosts` | Bool | `true` | Advanced; Boosts gate (feature plan owns detail) |
| `open.boosts.hasDismissedInterstitial` | Bool | `false` | Boost editor first-run dismissal |
| `open.boosts.hasDismissedJSNotice` | Bool | `false` | Boost code editor JS notice |
| `open.boosts.codeEditorSize` | String | `"480x588"` | Boost code editor size |
| `open.advanced.allowSitesThemeData` | Bool | `true` | Advanced; ON as in Arc 1.172.2 (capture C-report-s6 §6; LEAD 2026-11-12 10:45) |
| `open.advanced.enableSharedQuotes` | Bool | `true` | Advanced |
| `open.advanced.playSoundEffects` | Bool | `true` | Advanced; Open-generated sounds. LEAD 11:40 (2026-11-12): on, as Arc (inverse key `playUserInterfaceSoundsDisabled`); GUESS until capture PB5-e |
| `open.advanced.hapticOnTabReorder` | Bool | `true` | Advanced (guess ON, section 7.2) |
| `open.advanced.tabSleepMode` | String (`automatic`/`conservative`/`aggressive`/`never`) | `automatic` | Advanced; sleep policy (section 5.5) |
| `open.appIcon.selectedID` | String (`openDefault`/`openDark`/`openLight`/`openMono`/`openColor`/`openRetro`) | `openDefault` | App Icon; `NSApp.applicationIconImage` / alternate icon |
| `open.import.lastArcDir` | String (path) | none | Import wizard (path only; never commit) |
| `open.library.lastSection` | String (`spaces`/`archive`/`downloads`/`captures`/`media`/`history`) | `archive` | Library restore |
| `open.translate.enabled` | Bool | `true` | Page translation offer (`docs/plans/page-platform.md` §4.7); no Settings row |
| `open.translate.neverTranslateHosts` | [String] (lowercase hosts) | `[]` | "Never Translate This Site"; cleared by "Reset Translated-site Prompts" (page-platform §4.7.7) |
| `open.capture.dragToCaptureEnabled` | Bool | `true` | Cmd+Shift drag to capture (page-platform §4.6.2); no Settings row |
| `open.capture.shortcutHintLastShown` | Double (Unix time) | `0` | Capture shortcut hint toast cadence (page-platform §4.6.7) |
| `open.capture.portraitBackground` | String (`theme`/`white`/`black`) | `theme` | Portrait capture background (page-platform §4.6.4, guess) |
| `open.web.colorScheme` | String (`automatic`/`light`/`dark`) | `automatic` | View ▸ Appearance for websites (page-platform §4.8) |
| `open.developer.allowJavaScriptFromAppleEvents` | Bool | `false` | View ▸ Developer ▸ Allow JavaScript from Apple Events; gates AppleScript `execute` (page-platform §4.10.2) |
| `open.developer.modeHosts` | [String] (lowercase hosts) | `[]` | Per-site Developer Mode (page-platform §4.10.3) |

Register app defaults once at launch with
`UserDefaults.standard.register(defaults:)` using this table. Reads
still use the `object(forKey:) as? Bool ?? fallback` form where
`docs/routing.md` already fixes the fallback (three `open.links.*`
keys). Do not change those fallbacks.

### 2.2 Per-profile scope — browser snapshot (`ProfileSettings` and friends)

Owner: `BrowserModel` profiles, saved by `SnapshotStore` (1 s debounce,
atomic write; flush on quit). Edit = mutate the live `Profile`, then
`scheduleSave`. No second copy.

| Field | Type | Fresh default | Used by |
|---|---|---|---|
| `ProfileSettings.autoArchiveAfter` | `AutoArchiveInterval` | `twelveHours` | Auto-archive sweep (exists) |
| `ProfileSettings.littleOpenAutoArchiveAfter` | `AutoArchiveInterval` | `sixHours` | Little Open sweep (exists) |
| `ProfileSettings.searchEngineID` | String | `google` after Step 2 (now `duckduckgo`; fix the init default only) | Command bar (exists) |
| `ProfileSettings.searchSuggestEnabled` | Bool | `true` | NEW. Remote suggestions on/off. Add with `decodeIfPresent ?? true`. |
| `ProfileSettings.downloadDirectory` | String (path) | `~/Downloads` | NEW. Add with `decodeIfPresent` fallback to the Downloads folder. Empty string means "system Downloads". |
| `ProfileSettings.askWhereToSaveEachFile` | Bool | `false` | NEW. Add with `decodeIfPresent ?? false`. |
| `ProfileSettings.customSearchEngines` | `[SearchEngine]` | `[]` | NEW. Add with `decodeIfPresent ?? []`. `SearchEngine` is already `Codable` (`OpenSuggest`). |
| `ProfileSettings.keepAliveSites` | `[String]`, entries `host[/path]` | `[]` | OpenSleep freeze + discard exemption. Decode missing keys as `[]`; encode always, like the other array fields. |

Keep `schemaVersion` at 1. New fields must decode old snapshots
without failure and encode always. Follow the legacy-key pattern
already in `ProfileSettings` (new key first, legacy key, default).

Keep-alive additions use `BrowserModel.updateProfileSettings(id:settings:)`
and the existing snapshot save path, per D-5. Host suffixes include
subdomains. A final `.*` allows any TLD, including multiple labels; the
optional path is a case-sensitive prefix. Invalid rules are ignored for
matching but retained in storage unchanged. Built-in rules always remain
active. No Settings UI ships with this field. The Site Control Center
plan will add a per-site "Keep this site awake" toggle that edits the
current profile's array. See [sleep.md](../sleep.md).

Profile create/rename/delete and Space assignment follow
`docs/re/features-core.md` section 5: names must be unique ("A Profile
with that name already exists.") and reject invalid characters
("Invalid Profile name."). Only a profile with no Spaces can be
deleted. The default profile can never be deleted. Deletion wipes
that profile's Chromium data directory (app action; section 3).

### 2.3 Routing — browser snapshot (exists; do not duplicate)

Rules, optional `sourceBundleID`, and `defaultDestination` live in the
snapshot (`BrowserModel.routingRules`, `defaultDestination`). The
Settings model is `LinksSettingsModel` only. See section 5.3.

### 2.4 Key bindings — one JSON file (exists as a type; fix the path)

File: `<root>/State/keybindings.json`. Shape: `KeyBindingStore`
(`{ "version": 1, "bindings": { "<commandID>": { "shortcuts": [...],
"priority": "browser|site|site-then-browser" } } }`;
`docs/commands.md`). `shortcuts: []` clears a command's keys. Only
`isCustomizable == true` commands accept new keys. The file is the
only override store. The app loads it at launch and passes it to
`MenuBuilder.buildMainMenu` and `KeyboardRouter`. Settings writes it
atomically (temp file, then rename), then asks the app to rebuild
menus and re-register the global hotkey.

### 2.5 Ad blocking — per-profile files (contract in `docs/plans/adblock-fork.md` section 12)

Under `<root>/Profiles/<profileDataDirectoryName>/AdBlock/`:
`catalog-state.json` (enabled list IDs, ETag per list, last-check
times, catalog version, `last_error`), `lists/<listID>.txt` (last
good text), `engine.dat` (serialized engine), `exclusions.json`
(allowlist domains). The 46-list catalog (IDs, names, categories,
info URLs, upstream download URLs) ships as Open data. Only EasyList
and EasyPrivacy ship inside the app. All other lists download on
first enable. Open fetches upstream sources. Open never fetches
Arc's mirror (`docs/re/features-advanced.md` AD-4). Master toggle:
per-profile Bool in `catalog-state.json` (`enabled`, default `true`
for a fresh profile; `docs/adblock-design.md` "Default lists").
EasyList plus EasyPrivacy start enabled for a fresh profile.

### 2.6 Library stores (exist; Library only reads/writes through them)

| Data | Store | Notes |
|---|---|---|
| Archive | `ArchiveStore` (SQLite) | `recent`, `search`, `restore(id:)`, `purge`, `count`, `discardArchived` (exists; `docs/model.md`). Library adds `delete(id:)` and `deleteAll()` calls if missing — add them to `ArchiveStore`, same serial queue, one transaction. |
| History | `HistoryStore` (SQLite + FTS5) | Read-only in Library. `search` exists. |
| Downloads | Engine download list via `DownloadsProvider` (section 3) | No new file. The engine owns the list. |
| Captures | `<root>/Captures/` plus index `<root>/State/captures.json` | Index shape: `[{ "id": "<uuid>", "fileName": "...", "createdAt": <unix>, "kind": "area|fullPage|portrait", "sourceHost": "..." }]`. The capture feature writes it. Library reads, deletes, and reveals. |

## 3. Code layout — new target `OpenSettings`

### 3.1 Package change (exact)

In `Packages/OpenKit/Package.swift` add one library product and one
executable product. Keep all existing products. Dependencies must
match this list. `OpenSettings` must never import `OpenEngine`, CEF,
or AppKit view classes in view-model files. Views may import SwiftUI
and AppKit hosting helpers only.

```swift
.library(name: "OpenSettings", targets: ["OpenSettings"]),
.executable(name: "settings-preview", targets: ["settings-preview"]),
// targets:
.target(name: "OpenSettings", dependencies: ["OpenModel", "OpenRouting", "OpenCommands", "OpenSuggest", "OpenStore"]),
.executableTarget(name: "settings-preview", dependencies: ["OpenSettings", "OpenModel", "OpenRouting", "OpenCommands", "OpenSuggest", "OpenStore"]),
```

`OpenStore` is needed for `ArchiveStore` / `HistoryStore` types in
Library view models. If a build cycle appears, split Library view
models to depend on store value types only. Do not add an engine
dependency to break a cycle.

### 3.2 Files (create exactly these; no extra files without need)

```text
Packages/OpenKit/Sources/OpenSettings/
  SettingsTypes.swift        PaneID, AppIconOption, TabSleepMode, DownloadItemSnapshot, CaptureItemSnapshot
  SettingsActions.swift      Protocols the app implements (section 3.3). No views here.
  SettingsViewModel.swift    Root VM: selected pane, profile selection, save routing
  GeneralPane.swift          View + GeneralViewModel (same file: view model first, view second)
  ProfilesPane.swift         View + ProfilesViewModel. Profile list, per-profile form, Your Data rows
  SearchEnginesSheet.swift   Custom-engine editor (list, add, remove). Opened from Profiles and Advanced
  LinksPane.swift            View only. Binds LinksSettingsModel. Rules editor + defaults + Peek + test
  ShortcutsPane.swift        View + ShortcutsViewModel. Search, capture, conflict display, reset
  AppIconPane.swift          View + AppIconViewModel. Radio grid of Open's own icons
  AdvancedPane.swift         View + AdvancedViewModel. Toggles, ad blocking, sleeping, import entry
  AdBlockSettingsModel.swift Catalog state VM over the per-profile files (section 5.5)
  ImportWizard.swift         View + ImportWizardViewModel. Steps: choose, review, secrets consent, progress, report
  LibraryTypes.swift         LibrarySection, ArchiveFilter, Library actions protocol (section 6)
  LibraryViewModel.swift     Section state, search, filters, selection
  ArchiveSection.swift       Archive list view
  DownloadsSection.swift     Downloads list view
  CapturesSection.swift      Captures/Media grid view
  HistorySection.swift       History list view (read-only)
  SettingsWindow.swift       NSWindow factory + tab bar hosting (AppKit glue, still no engine import)
  LibraryWindow.swift        NSWindow factory + section sidebar hosting
  SyntheticData.swift        Synthetic profile, spaces, rules, archive, downloads for preview (section 8)
Packages/OpenKit/Sources/settings-preview/
  main.swift                 CLI: render panes, run --check flows, print action log (section 8)
```

Each pane file holds its view model first, then its view. Keep view
models `@MainActor @Observable final class`. Views read the view
model and `OpenDesign` tokens only. Views never touch
`UserDefaults`, files, or `BrowserModel` directly. All writes go
through the view model. All side effects go through
`SettingsActions` (section 3.3) or the stores in section 2.

### 3.3 Action protocols (the app implements; preview fakes log)

Define in `SettingsActions.swift`. The app target conforms. The
preview target conforms with a logger that prints one line per call
(section 8). Every method is `@MainActor`. No method throws to the
view. On failure the method returns a user string. The view shows it.

```swift
public protocol SettingsActions: AnyObject {
  // App and browser state
  func setAsDefaultBrowser() -> String?          // nil = started OK; else error text. Uses OpenEngine default-browser call.
  func isDefaultBrowser() -> Bool
  func checkForUpdates()                          // Sparkle; no-op with log line before M9
  func openMoreSettings()                         // Opens Chromium settings page in a tab (arc://settings equivalent)
  func revealOpenDataFolder()
  func copyOpenInfoToPasteboard()
  // Profiles and data (engine / Chromium profile prefs)
  func deleteProfileData(profileID: ProfileID) -> String?  // Wipes the CEF data dir. Caller removes the model profile first only on success.
  func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds) async -> String?
  func openProfileSubpage(profileID: ProfileID, page: ProfilePage)  // Privacy, Passwords, Payment, Notifications. Opens the engine page.
  func openPreviewsSettings()                     // Opens the Previews sub-settings sheet in Settings (section 5.1)
  // Key bindings
  func keyBindingsDidChange(store: KeyBindingStore)  // Rebuild menus, re-register global hotkey
  // Import
  func runImport(plan: ImportPlan) async -> ImportOutcome  // OpenImport + snapshot/store writes. Secrets only when plan.secretsConsented.
  // Engine toggles (no-ops with log lines until the engine lands)
  func setAdBlockEnabled(_ on: Bool, profileID: ProfileID)
  func setEnabledBlockLists(_ ids: [String], profileID: ProfileID)
  func setAdBlockExcludedDomains(_ domains: [String], profileID: ProfileID)
  func adBlockDebugInfo(profileID: ProfileID) -> String
  func setTabSleepMode(_ mode: TabSleepMode)
  func setApplicationIcon(id: String)             // NSApp alternate icon. Preview logs only.
}

public enum ClearDataKinds: OptionSet, Sendable { /* history, cookies, cache, downloads */ }
public enum ProfilePage: Sendable { case privacy, passwords, paymentMethods, notifications }
public struct ImportPlan: Sendable { /* toggles from ImportWizard; secretsConsented: Bool */ }
public struct ImportOutcome: Sendable { /* counts per kind; errorText: String? */ }
```

Rules:

- A view model calls an action only after it writes the store. Order:
  write store, call action, show result. A failed action never rolls
  back the store write. Show the error text in the pane.
- Before the engine exists, the app still conforms. Engine calls log
  and return success. Settings must work in preview with no engine.
- `SettingsViewModel` holds `actions: SettingsActions`,
  `model: BrowserModel`, `links: LinksSettingsModel`,
  `defaults: UserDefaults`, and `root: URL` (data root). The app
  builds it. The preview builds it with fakes and a temp root.

### 3.4 How the app presents the windows

App target glue (create when the app shell exists; preview proves the
package side first):

- Menu: Open menu item "Settings…" (command `settings`, Cmd+,)
  calls `SettingsPresenter.show(pane:)`. The command-bar action
  `settings` (Cmd+,) and `search-settings` call the same presenter.
  `search-settings` opens Profiles for the focused Profile (Section 7 lead ruling).
- `SettingsPresenter` owns one `NSWindow` from
  `SettingsWindow.makeWindow(viewModel:)`. First call creates it.
  Later calls call `makeKeyAndOrderFront` and set the pane. Closing
  hides the window. It never quits the app.
- Library: commands `view-library` (Cmd+Shift+L), `view-downloads`
  (Cmd+Shift+J), `view-archive`, `view-history` (Cmd+Y), and the
  sidebar Home button call `LibraryPresenter.show(section:)`. One
  shared window from `LibraryWindow.makeWindow(viewModel:)`. Same
  reuse rule.
- Cmd+, must work when a browser window is key and when Settings is
  already key (it then does nothing new). It must not fire while the
  command bar text field captures keys for typing, except Escape.

## 4. Root view model API (exact)

```swift
@MainActor @Observable public final class SettingsViewModel {
  public enum PaneID: String, CaseIterable, Sendable { case general, profiles, links, shortcuts, appIcon, advanced }
  public var selectedPane: PaneID                 // Writes open.settings.lastPane on change
  public var selectedProfileID: ProfileID         // Profiles pane selection; Advanced ad-block binds this profile
  public let general: GeneralViewModel
  public let profiles: ProfilesViewModel
  public let shortcuts: ShortcutsViewModel
  public let advanced: AdvancedViewModel
  public let appIcon: AppIconViewModel
  // links uses LinksSettingsModel directly (no wrapper VM)
}
```

- On init, read `open.settings.lastPane`. Unknown value means
  `general`.
- `selectedProfileID` starts as the focused window's Space profile.
  Preview starts as the synthetic "Personal" profile.
- Any per-profile edit acts on `selectedProfileID` only. Profiles
  that share a Space keep their own values. Never write all profiles
  unless the auto-archive "apply to all" dialog says so (section 5.2).

## 5. Pane specs (every option; control, default, store, live effect)

Read "Live effect" as code that runs on edit. "None (read at use)"
means the consumer reads the store when it acts. No Apply button.
Toggles write at once. Pop-ups write at once. Text fields write on
commit (Return or focus loss), never per keystroke, except where a
section says so.

Shared threshold control: `AutoArchiveInterval` cases in order:
Never, 1 hour, 6 hours, 12 hours, 24 hours, 7 days, 30 days
(`docs/re/features-core.md` section 3.3 rule 11). The pop-up shows
"12 hours (default)" for Today tabs and "6 hours (default)" for
Little Open. The hidden "20 seconds" debug value never ships.

### 5.1 General

Window title "General". Grouped boxes top to bottom: Updates and
Quit, Previews, Profile Settings hint, Default Browser, Import.

| # | Label (exact Open text) | Control | Default | Store | Live effect |
|---|---|---|---|---|---|
| G-1 | Automatically update Open | Switch | ON | `open.general.automaticallyUpdate` | Read at update check (M9 Sparkle). Change logs `checkForUpdates` eligibility only. Show info "(i)" help: "Open checks for updates in the background." |
| G-2 | Warn before quitting | Switch | ON | `open.general.warnBeforeQuitting` (AX id `warnBeforeQuitPreference` parity) | Quit flow reads it. ON + active downloads shows "There are downloads in progress. Closing the application will cancel them." (`docs/re/features-core.md` section 8.1). |
| G-3 | Previews | Switch plus button "Previews Settings…" | ON | `open.general.previewsEnabled` | OFF stops hover Previews at once. Button calls `actions.openPreviewsSettings()`, which shows the Previews sheet (section 5.1.1). |
| G-4 | "Manage your default search engine, Auto-Archive, and downloads in Profile Settings." plus button "Profile Settings…" | Push buttons | — | — | Button sets `selectedPane = profiles`. No store write. |
| G-5 | Default browser row: state text plus button | Push button | — | — | State text: "Open is your default browser." or "Open isn't your default browser." from `actions.isDefaultBrowser()`. Button "Set as Default Browser" calls `actions.setAsDefaultBrowser()`. Show the returned error text inline on failure. Command `set-default-browser` calls the same action. |
| G-6 | Import from Arc… | Push button | — | `open.import.lastArcDir` (path only) | Opens `ImportWizard` as a sheet on the Settings window (section 5.6). Menu command `import-from-browser` ("Import from Another Browser…") opens the same wizard. |

#### 5.1.1 Previews sheet (from G-3)

Sheet size 480x320. Title "Previews". Rows: "Show Open Previews:" master
switch, then "Folders" and "Pinned tabs and Favorites" source switches (sidebar
completion lead Q3 overrides the former hovering-links switch). No delay
pop-up: lead ruling 2026-10-26 removes Open's delay setting to match Arc, and
the hover delay is fixed at 0.5 s (sidebar-completion §3.6, Step S5b; the
pop-up built in `GeneralPane.swift` goes away there). Keys are registered in §2.1 through SettingsDefaults.
The former previewsOnHover key is no longer read. Close button "Done".
App values use UserDefaults; no ProfileSettings fields or second store are added.
Hover Preview reads these keys when it arms.

Lead decision (2026-10-26, capture session 2): Open v1 keeps the **two**
source switches, "Folders" and "Pinned tabs and Favorites", as an Open product
choice. Arc's sheet (422 × 370, "Show Arc Previews:", a "Learn more" link,
"Done") has **seven** source checkboxes, all on in a fresh Profile: Arc
Folders · Google Calendar · Google Mail · Outlook Calendar · Outlook Mail ·
Recent pages on Linear, Notion, and Figma · Notion Calendar
(`docs/re/interaction-states.md` §20.13, S2 02/0050). "Folders" is Arc
Folders. The other six read the user's accounts and site APIs (Arc's live-data
integrations); v1 has no such integrations, so they are **post-v1** and the
sheet does not list them. Arc's sheet has no delay pop-up, so Open removes
its delay setting (lead ruling 2026-10-26; the delay is fixed at 0.5 s). One
difference stays open (open question 7): Arc's General row has no switch,
only "Previews Settings…".

### 5.2 Profiles

Window title "Profiles". Left: profile list. Right: form for
`selectedProfileID`. Intro text: "Profiles keep your data separate
across Spaces — like history, logins, cookies, and extensions. You
can use any Profile across one or more Spaces." plus "Learn more."
(link opens the Profiles help in a tab).

Left list behaviors:

| Control | Behavior |
|---|---|
| List row | Profile name plus "<N> Spaces" (count of Spaces with that `profileID`). Select sets `selectedProfileID`. |
| "+" button | Opens create sheet: name field ("What do you want to call this Profile?"), validation (unique, invalid characters), then Space picker ("Which Spaces should use this Profile?" / "These Spaces will start fresh in your brand new Profile"). Create calls `BrowserModel.createProfile` path (add the command if missing: name, then reassign picked Spaces). Schedule snapshot save. The new profile gets fresh `ProfileSettings` (Google default). |
| "−" button | Enabled only when the selected profile has 0 Spaces and is not the default profile. Click shows confirm: "Deleting this Profile will permanently remove any cookies, history, preferences, and logins that belong to it." Buttons: Cancel, Delete Profile. Delete calls `actions.deleteProfileData` first. On success, remove the profile from the model and save. On failure, keep the profile and show the error. |
| Edit (pencil) button | Rename sheet: name field. Save validates unique and valid. Rename never changes Space names. |
| "Delete unused Profiles" button (footer) | Enabled when any profile has 0 Spaces (except default). Confirm text: "Deleting unused Profiles will permanently remove any cookies, history, preferences, and logins that belong to those Profiles." Deletes each unused profile with the same action order as "−". |

Right form (all values act on `selectedProfileID` only):

| # | Label | Control | Default | Store | Live effect |
|---|---|---|---|---|---|
| P-1 | Search engine | Pop-up (built-in plus custom names) | Google | `ProfileSettings.searchEngineID` | Next command-bar query uses it. `SuggestEngine` reads `searchEngineID` per query (`docs/suggest.md`). Unknown ID falls back to Google (`SearchEngines.engine(id:)`) and the pop-up shows Google. |
| P-2 | Manage search… ("Search Settings…") | Push button | — | — | Opens `SearchEnginesSheet` (section 5.2.1) for this profile. |
| P-3 | Include search engine suggestions | Switch | ON | `ProfileSettings.searchSuggestEnabled` (NEW) | Next keystroke honors it. It also sets `allowsRemoteSuggestions` false in `SuggestContext`. First turn-on after install shows the privacy notice once: "We talk to your search engine to help us suggest results." with a dismiss button. Track dismissal in `open.general.searchSuggestNoticeDismissed` (Bool, default false; add to registry). Never send suggestions while the notice is up. |
| P-4 | Archive tabs after | Pop-up (7 thresholds) | 12 hours | `ProfileSettings.autoArchiveAfter` | Next sweep uses it. On change, show the apply-scope dialog (section 5.2.2). Pinned tabs and Favorites never expire. |
| P-5 | Download location | Path row plus "Choose…" | `~/Downloads` | `ProfileSettings.downloadDirectory` (NEW) | Next download uses it. "Choose…" opens `NSOpenPanel` (folders only). Store the path string. No copy. |
| P-6 | Ask where to save each file | Switch | OFF | `ProfileSettings.askWhereToSaveEachFile` (NEW) | Next download prompts when ON. |
| P-7 | Your Data and Settings: Privacy and Security | Row with arrow | — | — | `actions.openProfileSubpage(profileID, .privacy)` |
| P-8 | Your Data and Settings: Passwords | Row with arrow | — | — | `actions.openProfileSubpage(profileID, .passwords)` |
| P-9 | Your Data and Settings: Payment Methods | Row with arrow | — | — | `actions.openProfileSubpage(profileID, .paymentMethods)`. Label is "Payment Methods" (never show stored card data in Settings). |
| P-10 | Your Data and Settings: Notifications | Row with arrow | — | — | `actions.openProfileSubpage(profileID, .notifications)` |
| P-11 | Your Data and Settings: Clear Browsing Data… | Push button (destructive style) | — | — | Opens clear sheet (section 5.2.3). |

Do not ship a "Default Document App" row. Notes are out of scope
(`docs/re/features-core.md` section 7.2, Profiles row 4).

#### 5.2.1 SearchEnginesSheet

Sheet 520x420. Title "Search Engines". Top: default-engine pop-up
(same binding as P-1). Middle: table of custom engines for this
profile (Name, Keyword, URL template with `%s`). Buttons: Add,
Remove, "Restore built-ins" (clears custom list). Add/edit form:
Name (required), Keyword (required, no spaces), Search URL (required,
must contain `%s`). Invalid form shows inline error and disables
Save. Save writes `ProfileSettings.customSearchEngines`, then the
snapshot save. Remove asks no confirm. The command bar builds its
engine list as `SearchEngines.all + customSearchEngines` for that
profile. Site Search seeds every engine with id `engine-<id>`
(`docs/suggest.md` section 7). Deleting the current default custom
engine resets `searchEngineID` to `google` in the same save.

#### 5.2.2 Auto-archive apply-scope dialog (P-4)

Arc asks which profiles get a new threshold
(`docs/re/features-core.md` section 3.3 rule 12). Show a sheet:
"Open will now archive your tabs after <choice>." (or "Open will
never auto-archive your tabs." for Never). Buttons: "This Profile
Only", "All Profiles", Cancel. "This Profile Only" writes the one
profile. "All Profiles" writes every profile's `autoArchiveAfter`
in one snapshot save. Cancel writes nothing and the pop-up returns
to the old value. Little Open threshold (Links pane) never shows
this dialog. It writes the one field at once.

#### 5.2.3 Clear Browsing Data sheet (P-11)

Sheet 460x360. Checkboxes: Browsing history (ON), Cookies and site
data (ON), Cached files (ON), Download history (OFF). Time range
pop-up: Last hour, Last 24 hours, Last 7 days, All time (default All
time). Buttons: Cancel, "Clear Data" (destructive). Clear runs
`actions.clearBrowsingData(profileID, kinds)` with the checked
kinds. History kind also clears the profile `HistoryStore` rows for
the range (app implements; preview logs the kinds). Show progress,
then "Done". Failure shows the returned text. Never clear another
profile.

### 5.3 Links (binds `LinksSettingsModel`; no wrapper VM)

Window title "Links". The view binds `LinksSettingsModel` directly.
The app builds the model from the live snapshot, spaces, and the
three `open.links.*` toggles (`docs/routing.md` "Settings data").
Recreate the model when Spaces or profile assignments change. On
every edit: call `issues()`. Errors block the save copy. Warnings
show but still save. Save = copy `currentRouting()` into
`BrowserModel`, write the `UserDefaults` toggles, then schedule the
snapshot save. Invalid drafts stay visible. They never enter the
evaluator or the save output.

Sections top to bottom: Little Open, Air Traffic Control, Peek,
Test a Link.

Little Open section:

| # | Label | Control | Default | Store | Live effect |
|---|---|---|---|---|---|
| L-1 | Open Little Open when I press the shortcut in any app | Switch | ON | `open.links.littleOpenHotkeyEnabled` + `links.littleOpenHotkeyEnabled` | ON registers `little-open-global` (Cmd+Opt+N) with `GlobalHotkeyService`. OFF unregisters it. Show the current shortcut text from the effective key bindings. |
| L-2 | Open Little Open when clicking links with Option+Command held | Switch | ON | `open.links.optionCommandClickLittleOpen` + `links.optionCommandClickLittleOpen` | Link-click handler reads it at click time. |
| L-3 | Links from other apps open in Little Open | Switch | ON | Snapshot external toggle + `links.externalLinksInLittleOpen` | External-link routing reads it at open time. Help text: "Only links from other apps need Open as your default browser. Links inside Open work either way." A rule that picks Little Open still wins when this is OFF. Only a Little Open default is suppressed (`docs/routing.md`). |
| L-4 | Archive Little Open windows after | Pop-up (7 thresholds) | 6 hours | `ProfileSettings.littleOpenAutoArchiveAfter` for the focused profile; `links.littleOpenAutoArchiveAfter` mirrors it | Next Little Open sweep uses it. Hydrate from the current profile on open (`docs/routing.md`). |
| L-5 | Default link destination | Pop-up: Little Open / Most Recent Space / each Space by title | Little Open (fresh) | Snapshot `defaultDestination` via `links.defaultDestinationKind` + `defaultSpaceID` | Next external link uses it. A missing Space shows an issue under `defaultDestinationIssueID` and falls back to Most Recent Space. Never crash. |

Air Traffic Control (rules) section:

- Header "Air Traffic Control" plus help: "Routes let you choose
  where specific sites open inside Open. For example, you can route
  Spotify links to always open inside your Personal space."
- Table columns: On (per-rule enabled is NOT in the model — do not
  add a toggle; order and presence are the control), Match (pop-up:
  Host contains / Host equals / URL starts with), Pattern (text
  field), Opens in (pop-up: Little Open / Most Recent Space / Space
  titles), From app (optional text field, bundle ID; empty = any
  app), Delete (minus button).
- Buttons: Add Rule (`links.addRule()`), Delete (`deleteRule(id:)`),
  drag rows to reorder (`moveRule(from:to:)`; `to == count` means
  the end). First match wins. Show `issues()` inline: errors in red
  under the row (empty pattern, spaces in pattern, bad URL prefix,
  missing Space), warnings for duplicates and for host-contains
  substring semantics ("google.com also matches notgoogle.com").
- Source field: trim and lowercase on save. Empty stores nil. The
  evaluator matches unknown sources only to rules with no source.
- No rule count limit. An empty list is valid.

Peek section:

| # | Label | Control | Default | Store | Live effect |
|---|---|---|---|---|---|
| L-6 | Open a Peek window when clicking links to other sites | Switch | ON | `open.links.openPeekOtherSites` | Gates Peek from Favorites and Pinned tabs only. Help: "This only affects Favorites and Pinned tabs." |
| L-7 | Open a Peek window when clicking links with Shift held | Switch | ON | `open.links.openPeekShiftClick` | Gates Shift-click Peek in any tab. The model key is inverted in Arc (`disableShiftClick...`). Open stores the positive form only. |

Test a Link section:

- Fields: URL text field (`links.testURLString`), From app bundle ID
  (`testSourceBundleID`, optional), Most Recent Space pop-up
  (`testMostRecentSpaceID`, optional).
- Button "Test" calls `links.runTest()`. It never opens a URL and
  never changes rules. Invalid input clears the old result and sets
  `testInputIsValid == false`; show "Enter a valid URL." Valid input
  shows the decision report (`RoutingDecisionFormatter.report`) in a
  read-only mono block: normalized host, each rule trace, `via`,
  resolved Space title or Little Open. Bare hosts gain `https://`
  (`RoutingRequest.parseURL`). Non-HTTP(S) shows "rejected".

### 5.4 Shortcuts (edits `OpenCommands` overrides)

Window title "Shortcuts". Top: a callout (359×35, radius 6) with the
label "Start with the basics" and a button "Learn the Essential
Shortcuts" (`command.circle.fill`) that opens the Essential Keyboard
Shortcuts window through `SettingsActions.openEssentialShortcuts()`
(commandbar-completion Step 6; RE CC-29/CC-30 corrected the earlier
filter reading). Search field (filters by title, id, aliases; the list
shows every active command), priority pop-up (section 5.4.2). Middle:
list. Bottom: "Reset All Shortcuts" plus status line.

#### 5.4.1 List and capture

`ShortcutsViewModel` holds `store: KeyBindingStore` (loaded from
section 2.4), `query: String`, `recordingCommandID: String?`,
`conflicts: [ShortcutConflict]` (from `ConflictChecker.check`),
`statusText: String`.

- Rows group as "Default Shortcuts" (no override) and "Custom
  Shortcuts" (has override), each sorted by title. Each row: title,
  scope badge (Global / Window / Sidebar / Command Bar / Web), key
  display (all effective shortcuts; first is the menu carrier),
  buttons: Record, Clear (sets `shortcuts: []`), Reset (removes the
  override for that command).
- Only `isCustomizable == true` rows show Record/Clear/Reset.
  Reserved rows (`isReserved == true`) never appear. Show their keys
  only in the conflict text ("reserved key").
- Record: click Record, then press keys. Capture one
  `KeyboardShortcut` (key plus modifiers). Escape cancels. Delete
  with no modifiers clears. A capture replaces the command's list
  with that one shortcut (keep alternates only via Clear/Reset; the
  editor is single-shortcut per edit — repeated Record appends when
  Shift is held during Record click). Write the draft store, run the
  checker, then apply section 5.4.3.
- Priority per row: pop-up Browser / Site / Site, then Browser
  (double-press). It writes `KeyBindingOverride.priority`. No value
  keeps the command default (`effectivePriority`).

#### 5.4.2 Global priority and numbering rows

Above the list, three rows (they write the same per-binding
priority default only when a binding has no priority; they do not
rewrite every binding):

| Label | Control | Default | Store |
|---|---|---|---|
| When shortcuts conflict | Pop-up: Open wins / Website wins / Website first, Open on double-press | Open choice: Website first, Open on double-press OFF; default `browser` | New bindings use this priority until changed. Existing bindings keep theirs. Store the picker in `open.shortcuts.defaultPriority` (String, default `browser`; add to registry). |
| Include Favorites in Go to Tab numbering | Switch | ON (include) | `open.shortcuts.includeFavoritesInTabNumbering` (Bool, default true; add to registry). OFF excludes Favorites (`excludeFavoritesInSwitchToNthTab` semantics). |
| Switch to ninth tab | Switch | ON | `open.shortcuts.switchToNinthEnabled` (Bool, default true; add to registry). OFF makes Cmd+9 / Ctrl+9 a no-op. |

Go to Tab is Cmd+1…9. Go to Space is Ctrl+1…9. Split pane focus is
Ctrl+Shift+1…4 (`docs/commands.md` command table).

#### 5.4.3 Conflict display and save rule

- After each draft edit, run
  `ConflictChecker.check(commands:overrides:)`. Split the result
  with `ConflictChecker.unexpected(_:)`. Known pairs (3 in Arc:
  New Folder / New Incognito Window, Show Fonts / New Tab, Little
  Open global/window twins) show as notes. They never block.
- Unexpected conflicts (`duplicate`, `reserved-key-reuse`) show in a
  red banner above the list: "<Keys> is used by <A> and <B>." plus
  "Clear one shortcut to save." While any unexpected conflict
  exists, do not write the file and do not call
  `keyBindingsDidChange`. Keep the draft in the view model so the
  user can fix it. A "Revert" button restores the last saved store.
- Clean draft: write the file at once (atomic), call
  `actions.keyBindingsDidChange(store:)`, show "Saved." Menus show
  the new keys at once. The global hotkey re-registers at once.
- "Reset All Shortcuts": confirm sheet ("Reset all shortcuts to
  their defaults?"). Yes writes an empty store (`bindings: [:]`),
  runs the same save path, clears the banner. "Reset Shortcut to
  Default" (per row) removes that one override.

### 5.5 Advanced

Window title "Advanced". Groups: Browsing, Appearance and Input,
Features, Ad Blocking, Tab Sleeping, Data and Developer.

Browsing / Appearance / Features toggles (all switches, write at
once to section 2.1 keys, read at use; no engine call unless noted):

| # | Label | Key | Default |
|---|---|---|---|
| A-1 | When opening Open, restore windows from previous session | `open.advanced.restoreWindowsOnLaunch` | ON |
| A-2 | Enable Picture in Picture when you leave a video tab | `open.advanced.enablePictureInPictureOnLeave` | ON |
| A-3 | Allow window dragging from the top of webpages | `open.advanced.allowWindowDraggingFromWebTop` | OFF |
| A-4 | Show full URL when Toolbar is enabled | `open.advanced.showFullURLWithToolbar` | OFF |
| A-5 | Enable Boosts on websites you visit | `open.advanced.enableBoosts` | ON (Boosts plan owns the editor; OFF hides all Boost effects at once) |
| A-6 | Allow websites to get your theme data | `open.advanced.allowSitesThemeData` | ON |
| A-7 | Enable Shared Quotes when highlighting text | `open.advanced.enableSharedQuotes` | ON |
| A-8 | Play Open sound effects | `open.advanced.playSoundEffects` | ON (LEAD 11:40; Open records its own sounds; never copy Arc files) |
| A-9 | Haptic feedback when reordering tabs | `open.advanced.hapticOnTabReorder` | ON |

Buttons row: "More Settings…" (`actions.openMoreSettings()`; opens
the Chromium settings page for the selected profile), "Reset
Translated-site Prompts" (clears translate prompts via the engine;
preview logs `resetTranslatePrompts`; show "Done" after), "Export
Data…" (save panel; writes a JSON export of the snapshot plus
archive index; never includes passwords or cookies).

Search row: "Search engine for <Profile>: <Name>" plus button
"Manage Search Engines…". The button sets `selectedPane = profiles`,
selects the profile, and opens `SearchEnginesSheet`. No duplicate
editor in Advanced.

Ad Blocking group (binds `AdBlockSettingsModel` for
`selectedProfileID`; profile picker at the group top mirrors the
Profiles selection):

| Control | Behavior | Store / effect |
|---|---|---|
| Master switch "Block ads, trackers, and popups" | ON/OFF for this profile | `catalog-state.json` `enabled`. Live: `actions.setAdBlockEnabled`. OFF keeps lists and allowlist. |
| Category list (Generic 3, Cookies 2, Privacy 5, Regional 35, Open additions 1; 46 total) | One switch per list. Name, info "i" link (opens `info_url` in a tab), state text (Bundled / Downloaded / Not downloaded) | Enabled IDs in `catalog-state.json`. Live: `actions.setEnabledBlockLists`. First enable downloads the list text (ETag flow). Failure keeps the old engine and sets `last_error`; show it under the list. |
| Search field | Filters lists by name and ID | View only. |
| Allowlist ("Don't block on these sites") | List of domains, Add (text field, host only), Remove | `exclusions.json`. Live: `actions.setAdBlockExcludedDomains`. Validate as host (lowercase, no scheme, no path). The Site Control Center writes the same file for its per-site toggle. Scope is the registrable domain. No "everywhere" row here. That is the master switch. |
| Buttons | "Copy Ad Block Debug Info" (copies `actions.adBlockDebugInfo`), "Reset List Choices" (restores EasyList plus EasyPrivacy, clears `last_error`) | Clipboard / catalog write plus `setEnabledBlockLists`. |
| Warning row | Shows when a known blocker extension runs with the built-in blocker ("More than one ad blocker is on. Blocking may double-block or break sites.") | App supplies the extension state. Preview hides it. |

Tab Sleeping group:

| Control | Behavior | Store / effect |
|---|---|---|
| Mode pop-up: Automatic / Conservative / Aggressive / Never | Automatic = freeze hidden tabs, discard after 5 min hidden. Conservative = discard after 15 min. Aggressive = discard after 2 min and drop the spare renderer. Never = no freeze, no discard, no 24 h destroy, and no loaded-page hidden-cache eviction. Battery Saver (OS low power) acts as Aggressive in Automatic only. | `open.advanced.tabSleepMode`. Live: `actions.setTabSleepMode`. Never sleep: the visible tab, tabs with audio, tabs in the visible Split, keep-alive hosts (mail, chat, docs, calendar; `docs/re/features-core.md` section 3.4). Pinned tabs and Favorites sleep like other tabs in modes other than Never (ratified memory policy). The global key is authoritative; launch and Profile creation reconcile the snapshot mode without another Undo step. |
| "Sleep inactive tabs to save memory" note | Static help text | — |

### 5.6 App Icon

Window title "App Icon". Radio grid, 2 columns, 6 large options.
Open's own artwork only. Create 6 original icons. Do not trace Arc
icons.

| ID | Name (Open text) |
|---|---|
| `openDefault` | The Original Open |
| `openDark` | Midnight |
| `openLight` | Daylight |
| `openMono` | Graphite |
| `openColor` | Spectrum |
| `openRetro` | Notebook |

Each cell: icon preview, name, "Current Icon" badge on the
selection. Click writes `open.appIcon.selectedID`, then calls
`actions.setApplicationIcon(id:)`. The app renders the existing original picker artwork at 1024 px, caches
per ID, and sets `NSApp.applicationIconImage`. `openDefault` resets it to nil.
Saved selection restores after the first window and content paint, with measured
cost and no signed-bundle writes. Failure shows the error text. No restart. Preview logs the
call and still writes the key.

### 5.7 Out of scope panes (do not build; keep the reason in code)

- Account: no account, login, or sync in Open. No tab, no disabled
  tab, no sign-in prompt.
- Max: Arc Max AI is out of scope. No tab. Command-bar ChatGPT scope
  stays out too.
- Staff: internal. No tab.
- Do not add Easels, Notes, or "Default Document App" UI anywhere.

### 5.8 Import from Arc wizard (`ImportWizard.swift`)

Entry: General G-6 and menu `import-from-browser`. Sheet on the
Settings window, 640x520, steps in a top stepper. The wizard never
writes to the Arc folder. It reads only from
`~/Library/Application Support/Arc` (user can pick another folder).
It reuses `OpenImport.ArcImporter` and the Phase 2 readers
(`docs/plans/import-phase2.md`). No personal data in logs. Counts
and hosts only. Never print titles or URLs.

Step 1 — Choose. Checkboxes with live counts (count-only reads):
Spaces, Pinned and Today tabs, Favorites, Folders (ON), Archive (ON),
History (OFF), Search settings (ON: engine choice only). Each row
shows "Found: N". A missing Arc folder shows "No Arc data found at
<path>." with a "Choose Folder…" button. Next stays disabled until
at least one box is on and the folder reads.

Step 2 — Review. Shows the mapping: Arc Spaces to Open Spaces,
profiles found, routing rules found, and skip counts (Easels, Notes,
welcome items, unknown). Text: "Easels and Notes do not import.
Open has no Easels or Notes." Button "Import" runs
`actions.runImport(plan:)` with `secretsConsented == false`. Progress
bar plus phase text. The importer maps Arc IDs to stable Open IDs.
Re-import adds zero new archive rows (idempotent;
`docs/model.md` OpenImport).

Step 3 — Secrets consent (separate; shown only when Step 1 History
or a "Passwords and cookies" box is on; that box starts OFF and OFF
means skip). Content: names the data (passwords, cookies, addresses,
cards). States: "macOS will show a Keychain prompt. Choose Allow to
continue." One "Allow and Import Secrets" button. One "Skip Secrets"
button. Cancel ends the wizard. Rules from Phase 2 section 3.5:
without consent, read row counts only and touch no Keychain item.
On denial, show "Keychain access denied. No secret data read." and
stop. Read the key one time. Never ask again in the same run. Until
the engine Part B lands, the secrets step imports counts only and
shows "Secret import needs the browser engine. Your counts are
ready. Nothing was copied." Do not decrypt into Settings files.

Step 4 — Report. Counts per kind (imported, duplicates, skipped by
kind), the archive accounted check, and errors. Buttons: "Done"
(closes the sheet; sets `open.import.lastArcDir`), "Open Library"
(closes Settings, opens Library on Archive). A failed import keeps
the old snapshot. Show the error and a "Try Again" button.

## 6. Library window

### 6.1 Window and entry points

- One shared window, 960x640 pt, min 720x480. Standard titled
  window. Title "Library". Left sidebar (sections), right content.
  It follows the macOS appearance. It stays AppKit-hosted SwiftUI
  like Settings (`LibraryWindow.swift`).
- Entry: sidebar Home button, Window menu "View Library"
  (`view-library`, Cmd+Shift+L) opens on `open.library.lastSection`.
  "View Downloads" (`view-downloads`, Cmd+Shift+J) opens Downloads.
  "View Archive" (`view-archive`) opens Archive. "View History"
  (`view-history`, Cmd+Y) opens History. Command-bar actions
  `view-library`, `view-downloads`, `view-archive`, `view-history`
  call the same presenter (`docs/suggest.md` section 6).
- Sections in order: Archive, Downloads, Captures, Media, History.
  Media is the combined grid (Captures plus Screenshots from Open).
  Captures shows Captures only. Both read the same index. There is
  no separate top-level window per section.
- Search field in the toolbar filters the current section. It never
  searches another section. Selection survives a section switch.
  Closing hides the window. Reopen restores the section and query.
- `LibraryViewModel` in `OpenSettings`:

```swift
@MainActor @Observable public final class LibraryViewModel {
  public enum Section: String, CaseIterable, Sendable { case archive, downloads, captures, media, history }
  public var section: Section
  public var query: String = ""
  public var archiveSpaceFilter: SpaceID?      // nil = all Spaces
  public var archiveReasonFilter: ArchiveReason? // nil = all reasons
  public var archiveOriginFilter: OriginFilter = .all // .all, .spaces, .littleOpen
  public var selectedIDs: Set<String> = []
  public var statusText: String = ""
}
public enum OriginFilter: Sendable { case all, spaces, littleOpen }
```

  Actions go through `LibraryActions` (app implements; preview
  logs): `restoreArchived(id:)`, `deleteArchived(id:)`,
  `clearArchive()`, `revealDownload(id:)`, `retryDownload(id:)`,
  `cancelDownload(id:)`, `deleteCapture(id:)`, `revealCapture(id:)`,
  `openHistoryItem(url:)`. Define it in `LibraryTypes.swift` next to
  `SettingsActions`. Downloads and captures data come from providers
  the app injects (`DownloadsProvider`, `CapturesProvider` value
  snapshots). View models never call the engine.

### 6.2 Archive section (full v1)

Data: `ArchiveStore` (`docs/model.md`). Load newest first. Page in
100-row loads on scroll. Never load the full table at open.

- Toolbar: search field (title and URL host), Space pop-up (All
  Spaces plus each Space title), Reason pop-up (All, Closed, Auto-
  archived, Cleared, Folder deleted — maps to `closed`,
  `autoArchived`, `clearedToday`, `folderDeleted`), Origin pop-up
  (All, Spaces, Little Open — from `original_location` prefix;
  Little Open rows store the Little Open window origin when the
  feature writes them), "Clear Archive…" button.
- Row: favicon (from `FaviconStore`; placeholder icon when missing),
  title, host, Space name, reason text, archive date. Folder
  archives show "Folder" plus child count from the payload.
- Actions: double-click or "Restore" puts the tab back
  (`ArchiveStore.restore(id:)` then
  `BrowserModel.restoreArchivedTab(_:)`) and shows the toast
  "Restored to <Space>." with a "View" action. "Delete" removes the
  record after confirm ("Delete this archived tab? This cannot be
  undone."). Select plus Delete handles many rows in one confirm.
  Context menu: Restore, Restore to Space (submenu), Delete.
- "Clear Archive…": confirm "Are you sure you'd like to Clear
  Archive?" plus "This deletes every archived tab. This cannot be
  undone." Clear calls the store delete-all in one transaction.
  Show "Archive cleared." Empty state: title "No archived tabs"
  plus text "Tabs you close or auto-archive appear here."
- Undo: restore registers undo in `BrowserModel` (exists). Delete
  and Clear have no undo. Say so in the confirm.

### 6.3 Downloads section (full v1)

Data: engine download list as value snapshots
(`DownloadItemSnapshot`: id, fileName, sourceHost, receivedBytes,
totalBytes (nil = unknown), state (inProgress, paused, completed,
failed, cancelled), filePath (nil until done), startedAt, profileID).
The app maps CEF download items to snapshots. Little Open tray shows
the same snapshots. There is no second list.

- Row: file icon by type, name, source host ("Download from
  <host>"), progress bar plus bytes and speed when active, location
  when done. Filter pop-up: All, In Progress, Completed, Failed,
  plus Profile pop-up (All Profiles plus names). Search by name and
  host.
- Actions: Pause / Resume (engine), Cancel, Retry (failed only;
  starts a new download of the same URL), "Show in Finder" (reveal;
  disabled when the file moved — show "File moved or deleted."),
  "Open" (completed only), Remove from List (keeps the file).
  Double-click a completed row reveals it.
- Quit with active downloads shows the warn dialog from G-2.
  Downloads use the profile download folder and prompt setting
  (P-5, P-6) at start. Tidy rename (auto-rename with revert toast)
  is out of this plan. Show the engine name as-is.
- Empty state: "No downloads" plus "Files you download appear here."

### 6.4 Captures and Media sections (app-owned items only in v1)

Data: `CapturesProvider` over `<root>/Captures/` plus
`State/captures.json` (section 2.6). Item: thumbnail (load off the
main actor, cache by ID), name, kind badge (Capture / Full Page /
Portrait / Screenshot), date, source host, byte size.

- Grid: adaptive columns, thumbnail, name below. Sort pop-up:
  Newest, Oldest, Name. Search by name and host. Actions: Open
  (Preview), Copy Image, Save As…, Show in Finder, Delete (confirm:
  "This will permanently delete your capture." Deletes file plus
  index row in one step).
- Media shows Captures plus Screenshots together with a kind
  filter (All, Captures, Screenshots). Captures section shows
  Captures only. Screenshots enter only when the capture feature
  writes them with kind `screenshot`. No folder watching in v1.

### 6.5 Decision: what ships and what waits (with reasons)

| Source | v1 | Reason |
|---|---|---|
| Archive | Ship full (section 6.2) | Auto-archive, close, and restore need a home. The store exists (`ArchiveStore`). `AGENTS.md` v1 scope has auto-archive. Arc filters (Space, reason, Little Open) are proven (`docs/re/features-core.md` section 3.6). No engine needed. |
| Downloads | Ship full (section 6.3) | Downloads need progress, reveal, and retry. The list is one engine feed with two views (Library plus Little Open tray; `docs/re/features-advanced.md` DL-1, LA-10). Deferring it leaves downloads with no UI. |
| Captures (app-owned) | Ship grid (section 6.4) | Capture ships in v1 scope (Site Control Center footer, `capture-page` commands). Saved captures need a home (`docs/re/features-advanced.md` CA-2, CA-3). The cost is one folder plus one index file. No permission needed. |
| Media = Captures + Screenshots (Open-made) | Ship as a combined grid | Arc Media merges sources (LB-1). Open-made screenshots cost no permission. The grid code is shared with Captures. |
| Folders: Documents, Desktop, Downloads folders, system Screenshots | Defer to v1.1 (show no toggle in v1) | Each folder needs a permission grant, a security-scoped bookmark, and a file watcher. That work can delay the Archive. The value is browse-only (hide, never delete; LB-2). Ship it after the core browser. Do not show disabled toggles. |
| Easels, Notes sources | Never | Out of v1 scope (`AGENTS.md`). Library delete/hide rules prove Arc treats them apart (LB-2). |
| History as a Library section | Ship read-only (section 6.6) | `view-history` (Cmd+Y) needs a target. `HistoryStore` exists. Read-only keeps the cost low. |

### 6.6 History section (read-only)

Data: `HistoryStore.search` for the selected profile (Profile
pop-up; default = focused profile). Rows: title, host, visit count,
last visit. Search field drives FTS. Double-click opens the URL in
a new Today tab. No delete in v1 (Clear lives in Profiles P-11).
Empty state: "No history" plus "Pages you visit appear here."

## 7. Build and run commands (use exactly these)

```sh
nice -n 10 swift build -c release -j 6   # in Packages/OpenKit; zero warnings, zero errors
.build/release/settings-preview --help   # prints usage; exit 0
.build/release/openkit commands-demo ... # existing checks must stay green
.build/release/commands-dump             # existing checks must stay green
```

Swift 6 strict concurrency. Every view model is `@MainActor`.
No `swift test`. No unit-test target. Verification is preview PNGs,
CLI checks (section 8), and the real app (section 9).

## 8. Acceptance without the full app — `settings-preview`

The preview proves layout, stores, and action calls with no browser
window and no engine. It uses the real `OpenSettings` views and view
models, a temp data root, and fake actions that log. It never touches
the user's real root, real `UserDefaults`, or Arc data.

### 8.1 CLI (exact)

```text
settings-preview render --out DIR [--scale 1|2|both]   # one PNG per pane and Library section
settings-preview check [--only NAME]                   # scripted edit flows; exit 1 on first failure
settings-preview dump-keys --root DIR                  # prints every store value under DIR (sorted)
```

- `render` builds the synthetic fixture (section 8.2), hosts each
  view offscreen at 684x650 (Settings panes) and 960x640 (Library
  sections), and writes PNGs: `general.png`, `profiles.png`,
  `links.png`, `shortcuts.png`, `app-icon.png`, `advanced.png`,
  `library-archive.png`, `library-downloads.png`,
  `library-captures.png`, `library-media.png`,
  `library-history.png`. At `--scale both` (default) it writes
  `<name>@1x.png` and `<name>@2x.png`. Render path: `NSHostingView`
  in an offscreen `NSWindow`, `layout()`, then
  `bitmapImageRepForCachingDisplay` plus `cacheDisplay`. Set
  appearance to Dark for half the panes and Light for the other
  half, then render both appearances for `general` and `profiles`
  (`general-light.png`, `general-dark.png`, same at 2x). A zero-size
  or all-transparent PNG fails the run (check pixel size and a
  non-empty content hash). Print each path and size. Exit 0 only
  when every PNG exists and passes.
- Visual check (human or reviewer): open the PNGs. Check: no
  clipped text, no overlapping rows, tab bar shows 6 tabs, Profiles
  shows the left list, Shortcuts shows key caps, Advanced shows all
  groups, Library shows rows and grid. The later Opus design pass
  owns pixel polish. This plan owns structure. Ugly but correct
  passes. Broken layout fails.
- `check` runs each flow in section 8.3 in order against a fresh
  temp root. It prints `PASS <name>` or `FAIL <name>: <detail>` per
  flow, then a summary. Exit 0 only when all pass. `--only NAME`
  runs one flow. Fakes log one line per action call:
  `ACTION <method> <args>` (for example
  `ACTION setTabSleepMode aggressive`). Store checks read the files
  and defaults back from disk. A flow that only checks memory fails
  review. Always assert on disk.
- `dump-keys` prints `default <key> = <value>`,
  `snapshot profile <name> <field> = <value>`,
  `keybindings <id> = <shortcuts> priority=<p>`,
  `adblock <profile> enabled=<bool> lists=<ids> exclusions=<hosts>`,
  sorted, one per line. Hosts only in test data. No titles or URLs
  from real data ever print (preview uses synthetic data only).

### 8.2 Synthetic fixture (`SyntheticData.swift`; exact content)

Build in code. No file input. Fixed UUIDs (seeded, stable across
runs). Contents:

- Profiles: "Personal" (default, 2 Spaces) and "Work" (1 Space).
  Personal: Google, suggestions ON, archive 12 hours, downloads
  default. Work: DuckDuckGo, suggestions OFF, archive 24 hours,
  one custom engine ("Docs Search", keyword `docs`, template
  `https://example.com/search?q=%s`).
- Spaces: "Home" (Personal), "Reading" (Personal), "Office" (Work).
  Each has 2 pinned tabs and 1 folder. URLs use `example.com`,
  `example.org`, `example.net` only.
- Routing: 3 rules (Host equals `example.com` to Home, Host contains
  `docs` to Work Office, URL starts with `https://example.net/a` to
  Little Open), default Little Open, all toggles ON.
- Key bindings: one override (`new-tab` to Ctrl+T) plus one cleared
  command (`zoom-in` with `[]`). No conflicts.
- Ad blocking (Personal): master ON, EasyList plus EasyPrivacy ON,
  one Regional OFF, exclusions `example.com`. Work: master OFF.
- Archive: 6 records (2 closed, 2 auto, 1 cleared, 1 folder) across
  both profiles. Downloads: 4 snapshots (1 active at 40%, 1 paused,
  1 done, 1 failed). Captures: 3 items with tiny generated PNGs.
  History: 5 rows. All titles are "Example …" text.

### 8.3 Check flows (each asserts store on disk plus action log)

| Name | Edit (via view model calls, not view taps) | Assert |
|---|---|---|
| `general-toggles` | Turn Warn OFF, Updates OFF | `dump-keys` shows both false. No ACTION lines. Relaunch VM still shows OFF. |
| `default-browser` | Call General Set as Default | Log has `ACTION setAsDefaultBrowser`. Fake returns error once: pane shows the error and the store stays unset. |
| `profile-search` | Set Work engine to Bing, add a custom engine, delete it | Snapshot Work `searchEngineID` = `bing`, custom list round-trips, delete of the default custom resets to `google`. Personal stays Google. |
| `profile-archive-scope` | Change Personal archive to 24 hours, pick This Profile Only; change again, pick All Profiles | First: Work stays 24 hours by its own value, Personal = 24 hours. Second (to 7 days, All): both = 7 days. Cancel path writes nothing. |
| `profile-downloads` | Set download folder to a temp path, Ask ON | Snapshot fields match. Next-download read returns them (call the VM read path). |
| `clear-data` | Check History plus Cookies, Clear | Log has `ACTION clearBrowsingData` with those kinds and the right profile. Other profile log stays empty. |
| `links-rules` | Add a rule, reorder to top, run Test with `example.com/x`, edit pattern to empty | Save copy holds the new order. Test report resolves to the top rule Space. Empty pattern shows an error, blocks the save copy, and the rule stays visible. Deleted-Space rule falls through to the next rule. |
| `links-toggles` | Turn external OFF, hotkey OFF | Defaults keys read back false. Log shows hotkey unregister via `keyBindingsDidChange` or the hotkey action (pick one owner: the app. Preview asserts the ACTION line exists). Rule-to-Little-Open still wins with external OFF (evaluator check). |
| `shortcuts-save` | Record Ctrl+T for New Tab (known-pair rules apply), Clear Zoom In, set priority | File on disk holds both. Log has `ACTION keyBindingsDidChange`. Menu-effective keys read back via `KeyBindingStore.effectiveShortcuts`. |
| `shortcuts-conflict` | Record the same keys for two window commands | Banner text names both commands. File on disk still holds the old store. Revert restores the draft. Reset All writes empty bindings. |
| `advanced-toggles` | Flip A-3 ON, sleep to Aggressive | Defaults read back. Log has `ACTION setTabSleepMode aggressive`. |
| `adblock` | Master OFF, enable one Regional list, add a bad exclusion (`https://x/path`), add `example.org` | Bad host is rejected with inline error and no file change. Good host lands in `exclusions.json`. Log has `setEnabledBlockLists` with the new ID and `setAdBlockEnabled false`. |
| `app-icon` | Pick `openColor` | Key reads `openColor`. Log has `ACTION setApplicationIcon openColor`. |
| `import-counts` | Run the wizard count path on a fixture Arc folder (tiny `Storable*.json` with 2 Spaces, 3 tabs, 1 easel) | Counts match the fixture. Secrets box OFF touches no Keychain (fake keychain counter = 0). Report skips the easel. Old snapshot unchanged on failure case. |
| `library-archive` | Search, filter by Space, Restore one row, Delete one row | Restore log plus the tab exists in the model Today list. Deleted row is gone from the store. Clear asks confirm (assert confirm state, then clear to 0). |
| `library-downloads` | Retry the failed snapshot, Reveal the done one | Log has `retryDownload` and `revealDownload` with the right IDs. Active row shows a progress value (not text only). |

Add one failure flow: `empty-states` renders Library with zero
archive, zero downloads, zero captures. Assert the three empty-state
strings exist in the view tree (accessibility labels) and the PNGs
still pass the size check.

## 9. Step-by-step implementation order (files and acceptance per step)

Do the steps in order. Each step ends green before the next starts.
One PR per step unless the step says otherwise. Keep diffs small.
Run the section 7 build after each step. Zero warnings, zero errors.

### Step 1 — Package skeleton and window shells (no pane logic)

Files: `Package.swift` (products and targets per section 3.1),
`OpenSettings/SettingsTypes.swift`, `SettingsActions.swift` (with
logging fake support), `SettingsViewModel.swift`,
`SettingsWindow.swift`, `LibraryTypes.swift`,
`LibraryViewModel.swift`, `LibraryWindow.swift`,
`settings-preview/main.swift` (render stub that writes placeholder
PNGs through the real hosting path), `SyntheticData.swift`
(fixture builders, even if panes are still empty).

Do: tab bar with 6 tabs, empty grouped panes with correct titles,
Library sidebar with 5 sections and empty content. Settings window
684x650, title follows the tab. Library 960x640.

Accept: build green. `settings-preview render` writes 11 PNGs at 1x
and 2x. Open them. The shells look right. No store writes yet.

### Step 2 — Model additions (snapshot fields plus Google default)

Files: `OpenModel/Containers.swift` (`ProfileSettings` new fields
per section 2.2; fresh init `searchEngineID` default `google`),
`OpenStore/SnapshotDTOs.swift` (matching DTO fields, same decode
rules), `OpenModel` profile create command if missing (name plus
Space reassignment; used by Step 4).

Do not change stored values. Old snapshots must load. New fields
encode always.

Accept: build green. `openkit roundtrip` on an old fixture prints
`roundtrip OK`. `openkit dump` on the old fixture shows Google only
where no value was stored. `commands-demo` still passes 66 checks.

### Step 3 — General, App Icon, and Advanced toggles (defaults only)

Files: `GeneralPane.swift`, `AppIconPane.swift`,
`AdvancedPane.swift` (toggles, search row, buttons; ad-block and
sleep groups show "Needs the browser engine" placeholder rows with
the stored values read-only in this step), `ImportWizard.swift`
(shell with Step 1 counts disabled until Step 7).

Do: every `UserDefaults` row in sections 5.1, 5.5 (toggles), 5.6.
App Icon ships 6 original placeholder icons (simple shapes; the
design pass replaces art). Do not copy Arc icons.

Accept: preview checks `general-toggles`, `app-icon`,
`advanced-toggles` (without the sleep ACTION assert until Step 6)
pass. Render PNGs show the three panes full. Quit and relaunch the
VM: values persist.

### Step 4 — Profiles pane and search engines

Files: `ProfilesPane.swift`, `SearchEnginesSheet.swift`.

Do: list plus create/rename/delete with the section 5.2 rules,
P-1 to P-11, the apply-scope dialog, the clear sheet (action call
only), the suggestions privacy notice.

Accept: preview checks `profile-search`, `profile-archive-scope`,
`profile-downloads`, `clear-data` pass. Delete guards hold: default
profile and in-use profiles refuse with the right text. A second
profile's values never change.

### Step 5 — Links pane on `LinksSettingsModel`

Files: `LinksPane.swift` only (plus app wiring notes). No new model.

Do: all of section 5.3. The save path copies `currentRouting()`
into the model and schedules the snapshot save. The view recreates
the model when Spaces change (preview rebuilds it by hand).

Accept: preview checks `links-rules` and `links-toggles` pass.
`openkit route` on the saved fixture agrees with the Test panel for
the same URL. Invalid drafts never reach the file (assert the file
JSON has no empty pattern).

### Step 6 — Shortcuts, Ad Blocking, and Tab Sleeping (full Advanced)

Files: `ShortcutsPane.swift`, `AdBlockSettingsModel.swift`,
`AdvancedPane.swift` (replace the Step 3 placeholders).

Do: section 5.4 (capture, conflicts, save block, reset),
section 5.5 ad-block group over the per-profile files (catalog data
ships in code; 46 entries with upstream URLs), sleep pop-up with
the `setTabSleepMode` action.

Accept: preview checks `shortcuts-save`, `shortcuts-conflict`,
`adblock`, `advanced-toggles` (with the sleep assert) pass.
`commands-dump` still exits 0. The keybindings file round-trips
through `KeyBindingStore.load`.

### Step 7 — Library sections and Import wizard (full)

Files: `ArchiveSection.swift`, `DownloadsSection.swift`,
`CapturesSection.swift`, `HistorySection.swift`,
`ImportWizard.swift` (full steps), `OpenStore/ArchiveStore.swift`
(add `delete(id:)` and `deleteAll()` if missing).

Do: sections 6.2–6.6 and 5.8. Folder sources stay out. No toggles
for them.

Accept: preview checks `library-archive`, `library-downloads`,
`import-counts`, `empty-states` pass. Render PNGs show Archive
rows, a progress bar, and the Captures grid. Re-import of the
fixture adds zero rows.

### Step 8 — App presentation (when the app shell exists)

Files: app target only (`App/` lifecycle, window controllers,
presenters, `SettingsActions` and `LibraryActions` conformance,
menu wiring for `settings`, `view-library`, `view-downloads`,
`view-archive`, `view-history`, `import-from-browser`,
`set-default-browser`).

Do: section 3.4. Cmd+, opens Settings. Home opens Library. Engine
actions forward to `OpenEngine`. Before the engine lands, they log
and succeed.

Accept: section 10 end-to-end list passes on the real app. If the
app shell does not exist yet, this step waits. Steps 1–7 still ship
and prove the package. Say so in the PR. Do not fake an app check.

## 10. End-to-end acceptance on the real app (no unit tests)

Run on the built app. Each line must pass. Note the result in the PR.

1. Cmd+, opens Settings on General. Switch all 6 tabs. Close and
   press Cmd+, again. The last pane returns. Window is 684x650.
2. General: turn Warn OFF, quit with a download running. No warn
   dialog. Turn it ON, quit again. The dialog shows.
3. Profiles: create "Test", assign one Space, set Bing and 24 hours.
   Restart the app. The Space still uses Test with Bing. Delete
   guards block the in-use delete. Unassign, then delete works.
4. Links: add Host equals `example.com` to a Space. Test shows that
   Space. Open `https://example.com` from another app. It lands in
   that Space (or Little Open per the rule). Break the pattern. The
   save blocks and the file keeps the old rule.
5. Shortcuts: rebind New Tab to Ctrl+T. Menus show Ctrl+T. The keys
   work. Create a duplicate. The banner blocks the save. Reset All
   restores Cmd+T.
6. Advanced: set sleep to Aggressive, open 6 background tabs, wait.
   Hidden tabs discard sooner than in Automatic. Set Never. No tab
   discards. Turn the ad-block master OFF on a test page. Ads return
   after reload. Add the host to the allowlist. Same result. Remove
   it. Blocking returns.
7. Library: close 3 tabs, auto-archive 1. Library Archive finds all
   4 with the right filters. Restore 1. It appears in Today. Delete
   1. It stays gone after restart. Download a file. Downloads shows
   progress, Reveal works, Retry works after a failed download.
   Take a Capture. It appears in Captures and Media.
8. Import: run Import from Arc with History OFF. Spaces and tabs
   arrive. Run it again. Counts show duplicates, no new tabs. Turn
   the secrets box ON, cancel the consent. No Keychain prompt
   appears and no secret copies.

## Risks

| Risk | Guard |
|---|---|
| SwiftUI list cost in Shortcuts and Library with many rows | Use `List` with stable IDs. Page Archive loads (100 rows). If scroll drops frames, move that one list to AppKit in a later step. Do not pre-build AppKit lists. |
| Snapshot schema drift | New fields decode with defaults. Keep `schemaVersion` 1. `roundtrip` must stay green (Step 2). |
| Keybinding file and menus drift | One writer (Shortcuts pane), one reader (app launch). `commands-dump` compares menus to `expected-menu.json` after each change. |
| Ad-block catalog URLs go stale | Upstream URLs plus ETag. A failed download keeps the old engine and sets `last_error`. Never block browsing on a list fetch. |
| Secrets consent scope creep | Consent gates every Keychain touch. Counts only until the engine Part B. No secret bytes in Settings files, logs, or preview output. |
| Design tokens land late | Panes use system defaults now. Token swap is a view-only change. View models carry no visual values. |

## Open questions (need a human or runtime answer; defaults ship until then)

1. Factory defaults marked Unknown in the RE report (Peek toggles,
   toolbar full-URL, sound effects, theme data, download prompt,
   auto-archive on a fresh profile). This plan ships the Open
   choices in section 5. Verify on a fresh Arc profile if 1:1
   parity matters, then change one default per key. No code shape
   changes.
2. Does Arc sleep pinned tabs? This plan freezes but never discards
   pinned tabs. Verify with many pinned tabs, then allow discard if
   Arc does it (`docs/memory-design.md` open question 8).
3. Capture: exact default shortcut, portrait ratio, and area limits
   (`docs/re/features-advanced.md` section 9.8). The Library grid
   does not depend on the answers. The capture feature does.
4. Downloads: does "Save to Library" copy or reference the file
   (same source)? This plan omits that flow. Add it only with the
   answer.
5. App Icon artwork: 6 original icons need the design pass. The IDs
   and names in section 5.6 are final. Art is not.
6. Search privacy notice exact text and whether suggestions start ON
   need a fresh-profile check (`docs/re/features-core.md` Appendix
   C items 2 and 10). This plan ships ON with a one-time notice.
   Capture session 2 (2026-10-26): a fresh Arc Profile has suggestions
   ON (S2 02/0012), and the notice text is "We talk to your search engine
   to help us suggest results." with "Learn more about your data on Arc
   here." ("Open" in Open), shown by the command bar's (i) button as a
   footer with "Search Settings…" and "Dismiss"
   (`docs/plans/commandbar-completion.md` §4.8, which reuses
   `open.general.searchSuggestNoticeDismissed`).
7. Previews row switch (2026-10-26): Arc has no switch on the General ▸
   Previews row, only "Previews Settings…" (S2 02/0050). This plan keeps
   Open's master switch (built) until the lead decides; following Arc means
   removing the row switch (previews are off when both sources are off).
   The delay part of this question is decided: no delay setting, fixed
   0.5 s (lead ruling 2026-10-26).






## Appendix — Lead decisions (2026-10-25)

- Approved with the stated defaults for every open question (fresh-profile defaults, pinned-tab discard policy, Capture, Save-to-Library, icon art, search notice wording).
- Sequencing: implementation starts after the Profiles model, OpenSleep S0, and ad-block lists PRs merge (it binds to their models). Visual styling follows OpenDesign tokens; an Opus design pass reviews the rendered panes before the PR merges.

## Appendix — Lead decisions (2026-10-26, capture session 2)

- Previews: Open v1 keeps two source switches, "Folders" and "Pinned tabs and Favorites", as an Open product choice. Arc's seven sources are mostly its live-data integrations (Google and Outlook Calendar and Mail, Notion, Linear, Figma), which v1 does not include; they are post-v1 (§5.1.1). This confirms the sidebar plan's Q3 decision with the captured source list.
- Previews delay (lead ruling): Open's delay setting (`open.general.previewsDelaySeconds` and its pop-up) is removed to match Arc. The hover delay stays fixed at 0.5 s. Sidebar-completion Step S5b does the removal.
