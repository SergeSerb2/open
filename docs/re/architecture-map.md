# Arc 1.170.0 — Architecture map (Swift shell + Swift↔ArcCore bridge)

Scope: the Swift side of Arc and its use of `ArcCore`. ArcCore internals are covered by a companion report; this file covers only what the Swift binary reveals about the engine boundary.

Method and limits. Same evidence base as [bundle-anatomy.md](bundle-anatomy.md): `rea inspect-macho`, `nm` (8,508 symbols: only 862 defined — the binary is stripped, so most "types" below come from Swift reflection strings and embedded source paths, not from a symbol table), `otool -o` (ObjC class list, 12 MB dump in `.re/architecture/otool-o-arc.txt`), `strings` (192,722 lines in `.re/architecture/strings-arc.txt`), `xcrun swift-demangle` (`.re/architecture/demangled-defined.txt`), and 539 embedded source paths (`.re/architecture/source-paths.txt`) of the form `/Users/admin/actions-runner/_work/arc/arc/…`. The embedded paths are the strongest structural evidence: they give the real module layout. Stored properties are listed only where demangled accessors or reflection strings prove them; otherwise the report names the type and its files and marks the property list as unknown. Guesses are marked.

## 1. Swift module list and purpose

Derivation: the 539 embedded source paths group into 168 `Sources/<Module>` buckets (`.re/architecture/modules-from-paths.txt`); the 83 resource bundles (§5 of bundle-anatomy) confirm the package split. Only modules with file evidence are listed. "Files" = embedded `.swift` paths seen; the real module has more files (only paths with string literals survive).

### 1.1 Packages

| Package (path) | What it is | Evidence |
|---|---|---|
| `Browser/` (app target, module `Arc`) | Window/sidebar/command-bar chrome, `AppDelegate`, stores. Subdirs: `Application/` (22 files), `Windows/` (29), `Sidebar/` (11), `WindowContent/` (7), `CommandBar/`, `AppleScript/`, `DataStore/`, `PictureInPicture/`. | source paths `Browser/…` |
| `Frameworks/ARC/Sources/…` (~120 modules) | Feature + shared logic: TCA features, sidebar model, sync, settings. | source paths `Frameworks/ARC/Sources/…` |
| `Frameworks/ARCClients/Sources/…` (~60 modules) | Point-Free "clients": dependency interfaces + live implementations (`*Client`, `*ClientLive`). | source paths `Frameworks/ARCClients/Sources/…` |
| `Frameworks/ADK/Sources/ADK/` | Swift engine API over ArcCore (protocols + Chromium-backed impls). | `ADK/BrowserContext.swift`, `ADK/WebContentChromium.swift`, … |
| Vendored `ComposableArchitecture/`, `Dependencies/` | Point-Free state + DI, vendored (11 + 15 files seen). | `Frameworks/ARC/Sources/ComposableArchitecture/…` |

### 1.2 Core modules (purpose per module)

| Module | Purpose (from file names + type strings) |
|---|---|
| `Arc` (app target) | Chrome: `BrowserWindow`, `MainWindowController`, `WindowViewController`, `SidebarViewController`, `WebContentViewController`, `AppDelegate`. |
| `SharedAppFeature` (36 files) | App-level TCA feature: `AppData`, `AppReducer`-adjacent composition, sync, auth, preferences, profiles, remote config, Sentry wiring. Files: `AppData+{Auth,Sync,Profiles,Preferences,RemoteConfig,…}.swift` (18 extensions). |
| `SharedWindowFeature` (64 files) | Per-window TCA feature: `WindowData` + 60 `WindowData+*.swift` concern files (Tabs, Spaces, Folders, CommandBar, SplitView, Boosts, Peeks, TopBar…). The largest module; it is the window brain. |
| `SharedWindowsFeature` (19 files) | Multi-window coordination: `WindowsData`, window create/close/drag, Little Browser, split view, web-content framing across windows. |
| `CommandBar` (16 files) | Command Bar store + UI: `Store/CommandBar.swift`, `Instance/CommandBarInstance.swift`, `SearchClient.swift`, `UI_macOS/CommandBarContainer.swift`, suggestions. Ranking uses an on-device model (see §5, `ArcCommandBarRanking*`). |
| `BaseModels` (7 files) | Shared model types: `Sidebar/SidebarData+Spaces.swift`, `SidebarState+AncestryHelpers.swift`, `SpaceModel.swift`, `ThemeAwareHostingView/Controller` (demangled accessors show `subscriptions: Set<AnyCancellable>`). |
| `SidebarDataStore` | Sidebar mutation/query engine: `SidebarDataStore.swift`, `+MutationHelpers`. Protocol evidence: `SidebarDataStoreQuery`, `SidebarSpaceMutator`, `SidebarSpacesQuery`. |
| `StorableSidebar`, `StorableWindows`, `StorableArchive` | Persistence DTOs + defaults: `StorableSidebar+Dependencies.swift`, `AppSidebarReducerState+Default.swift`, `DefaultSidebarTabType.swift`. |
| `SidebarSyncCloudKit` (9), `FirebaseSidebarSyncCommon` (8), `FirebaseSidebarSyncClient` (6) | The two sync engines. DROP for Open. |
| `ADK`, `ADKClient`, `ADKClientLive`, `ADKApplicationFeature` | Engine bridge. See §5. |
| `WebContent` (5) | Per-tab web-content TCA state: `WebContentFeature.swift`, `WebContentState+{Boosts,Lifecycle,PictureInPicture,HoveredCapture,DeveloperTab}.swift`. |
| `WindowContents` (7) | Window-content collection: `WindowContentReducer.swift`, `WindowContentsReducer.swift`, split-view layout cache, find-in-page. |
| `Archive` | Archive + auto-archive: `ArchiveState.swift`, `ArchiveState+AutoArchive.swift`. |
| `AuthFeature` (7) | Sign-in wizard: `AuthReducer`, `SignInScreenReducer`, `SignUpScreenReducer`, `AuthWizard`. DROP. |
| `PreferencesFeature`, `ProfilesUI` | Settings feature; profile dialogs (`ProfileDialogUtils.swift`). |
| `ImportFeature` (6), `ImportMenuFeature` (3) | Import from other browsers: profile/bookmark/ad-blocker selection, Safari keychain import. Open's "Import from Arc" mirrors this shape. |
| `BoostsClient` (4), `BoostsDialog`, `BoostsEditor` | Boosts (user CSS/JS): storage incl. `BoostsStorageFirebaseImpl.swift` (cloud) + `StorableBoostsDataStore.swift` (local), editor UI with `SelectorPickerWebContents`. |
| `SiteControlCenter` | Per-site controls: `SiteControlCenterFeature.swift` + `SiteControlCenterViewController`. |
| `LittleBrowser` | Little Arc: `LittleBrowser.swift`; window side in `Arc.LittleBrowserWindow`, `LittleWindowViewController`. |
| `AdBlocking` (2) | Block-list management UI state: `AdBlocking.swift`, `ManageAdBlockersDialogContext.swift`. Engine data in `BlockListClient` + `ADK/adblock_list.json`. |
| `MediaControlsFeature` (4) | Media controls + mini-player: `MediaControlsFeature.swift`, `MiniPlayerFeature.swift`, state observations. |
| `PictureInPicture` (in app target) | PiP: `PIPWindowController`, `DocumentPiPWindowController` (demangled: `subscriptions`, `pipMenu`, `toggleAlwaysOnTop`, `updateWindowBehavior`). |
| `AskArc`, `AskInPage`, `LLM` (4), `SearchClientManager` (4) | Arc Max AI: page Q&A, OpenAI client (`LLM/OpenAI/ChatGPT.swift`, `UniversalLLMClient.swift`), search providers + ranking caches (`SearchClientManager.fuzzyMatchScoreCache`, `tokenizedTextMatchInfoCache` — demangled accessors). Out of scope; DROP. |
| `Easel`, `EaselUI`-adjacent, `ArcRichTextEditor`, `TextEditor` | Easels/Notes (whiteboard + rich text: `EaselReducer`, `EaselState`, 15 Easel view controllers). Out of scope; DROP. |
| `ARCUI` | Shared SwiftUI/AppKit components: `HostingView`, `TrackingHostingView`, `HoverableControl/View/Button`, `TooltipCardContainerView`, `SplitViewController` types, `SparklesOverlayView`. |
| `ARCFoundation`, `ARCFoundationBase` | Utilities: `MainActorBox`, `NSObject+AssumeMainActor`, emoji/SF-Symbol tables (`SFSymbolEmojiLookupTable.json`). |
| Clients (~60 in `ARCClients`) | One interface + live impl per service: `UserDefaultsClient`, `FileManagerClient`, `KeychainClient`, `PasteboardClient`, `AnalyticsClient`, `TelemetryClient` (in ARC), `FeatureFlags` client, `SoftwareUpdaterClient`, `SessionRestorationClient`, `TabSwitchingPerfTracker`, perf/instrumentation clients, etc. This is the TCA dependency pattern applied uniformly. |

Reading for Open: Arc splits "feature logic" (`ARC/Sources/<Feature>` with State/Action/Reducer) from "service interfaces" (`ARCClients/Sources/<X>Client` with a live implementation). The split is clean and worth copying in shape, but 60+ client modules is heavy; Open can start with ~10 clients (engine, files, keychain, pasteboard, defaults, updates, favicons, blocklists, import, perf).

## 2. State management

Finding: Arc uses The Composable Architecture (TCA) as its single state system, with Combine at the edges. Observation (`@Observable`) is not the app store; no `Observation` store types appear, while TCA types are everywhere.

Evidence:

- Vendored TCA source paths: `Frameworks/ARC/Sources/ComposableArchitecture/…` (11 files) and the app composes `AppReducer` (`Browser/Application/Store/AppReducer.swift`, `AppReducer+SyncedPreferences.swift`), `WindowReducer` (`Browser/Windows/Store/WindowReducer.swift`), `WindowsReducer`, `Sidebar` reducers (`AppSidebarReducer`), feature reducers (`ArchivePageReducer`, `HomeReducer`, `CommandBarViewReducer`, … — 26 `*Reducer` type strings).
- TCA vocabulary in strings: `StoreOf`, `TestStore`, `TestStoreTask`, `_DependencyKeyWritingReducer`, `BindingReducer`, `ScopedReducer`, `IfLetStore`, `ForEachStore`, `ViewStore`, `WithViewStore`, `PresentationStore` (36 `*Store` type strings). `DependencyKey` appears 246 times; client modules follow the `XClient` + `XClient+Dependencies` / `+LiveValue` file pattern (e.g. `SentryClient+LiveValue.swift`, `ADKClient+Dependencies.swift`).
- Combine at the boundary: demangled `PIPWindowController.subscriptions: Set<Combine.AnyCancellable>`, `BaseModels.ThemeAwareHostingView.subscriptions`; `Combine` has 744 undefined-symbol refs (second only to SwiftUI/Foundation). TCA effects run on Combine/`Effect` publishers; AppKit controllers subscribe with `AnyCancellable` sets.
- No competing store: searches for Redux-like custom stores find only TCA names; `SearchClientManager` etc. are clients, not stores.

State tree shape (from `AppState+*` / `AppData+*` / `WindowState+*` / `WindowData+*` file families — 18 + 18 + 25 + 60 extension files):

```
AppState / AppData            (Browser/Application/Store/, SharedAppFeature/AppData.swift)
├─ windows: WindowsState / WindowsData     (SharedWindowsFeature)
│  └─ each window: WindowState / WindowData (SharedWindowFeature, 60 concern files)
│     ├─ sidebar spaces + selection (SidebarSpaceState, WindowData+Spaces/Sidebar/Folders)
│     ├─ tabs + tab groups (WindowData+TabCreation/TabAttributes/TabGroups)
│     ├─ command bar (WindowData+CommandBarHelpers; CommandBar module store)
│     ├─ split view (WindowData+SplitViewHelpers; WindowContents)
│     ├─ web contents (WebContentState per tab; WindowData+WebContentFrame)
│     └─ boosts, peeks, toasts, modals, top bar, media (one WindowData+*.swift each)
├─ preferences / profiles / sync / auth (AppData+Preferences/Profiles/Sync/Auth)
├─ archive (ArchiveState, SharedArchiveFeature)
└─ downloads / library / home (SharedDownloadsFeature, HomeButton pages)
```

Dual naming (`AppState`/`AppData`, `WindowState`/`WindowData`, `WindowsState`/`WindowsData`) suggests a persisted value type (`*Data`) plus a reducer state (`*State`) per level. Guess: `*Data` is the `Storable*`-backed snapshot and `*State` adds ephemeral UI state. The file names support it (`StorableWindows/StorableWindows+Dependencies.swift`, `SidebarSyncState+Storable.swift`) but no demangled property list proves the field split. Mark as inference.

Threading: TCA reducers run on the main actor in practice; `ARCFoundationBase/MainActorBox.swift` and `NSObject+AssumeMainActor.swift` show explicit main-actor bridging helpers. Background work is isolated in clients (`UtilityQueue` module, `_utilityQueue`/`utilityQueue` strings). Web-content callbacks arrive from Chromium threads and are hopped to the store — the exact hop (queue vs `MainActor`) needs runtime/decompile data; static strings show both `MainActorBox` and dispatch-queue wrappers (`SentryDispatchQueueWrapper` is Sentry's, not Arc's). Do not over-claim: static evidence proves main-actor helpers exist, not that every reducer is `@MainActor`.

## 3. AppKit vs SwiftUI split

Finding: AppKit owns windows, the sidebar, and the web-content container; SwiftUI lives inside `NSHostingView` "islands" for dialogs, settings, editors, and small chrome. This matches Open's AGENTS.md direction — Arc already made that choice for its hottest surfaces.

Evidence:

- AppKit window layer: `NSPrincipalClass = Arc.BrowserApp`; view-controller types (61 `*ViewController` strings) are AppKit: `SidebarViewController`, `SidebarSpaceViewController`, `SidebarPagingContainerViewController`, `WindowContentViewController`, `WebContentViewController`, `WindowViewController`, `LittleWindowViewController`, `SiteControlCenterViewController`, `HoverCardViewController`, split-view and modal controllers.
- SwiftUI islands: 11 `*HostingView` types (`WebContentHostingView`, `TopBarHostingView`, `MediaControlsHostingView`, `ThemeAwareHostingView`, `AskInPageHostingView`, `DevToolsHostingView`, `YouTubePlayerHostingView`, …) plus `ARCUI.HostingView`, `ARCUI.HostingController` (demangled: `host` property), `SwiftUIViewHostingWindowManager`. Embedded settings/onboarding spaces (`SpaceCreationHostingViewController`) are SwiftUI hosted in AppKit controllers.
- SwiftUI is the largest undefined-symbol module (3,162 refs) because every island pulls SwiftUI runtime types; AppKit classes appear as 367 undefined ObjC classes (dominated by `NS*` system classes). Raw counts overstate SwiftUI's share of pixels: the sidebar tab cells are AppKit (`SidebarCells/TabCellView.swift`, `TabCellState.swift`, `SelectableCellView.swift`, `SidebarBouncyClickCell`, section header/divider cell views), which is the 120 Hz surface.
- `SwiftUIIntrospect` (96 strings) exists only to punch through islands to AppKit — a cost Open avoids by keeping islands shallow.

Per-feature split (type evidence):

| Feature | Shell tech | Evidence |
|---|---|---|
| Sidebar + tab rows | AppKit (`NSCollectionView`-style cells) | `SidebarViewController`, `TablistViewController`, `TabCellView/State`, `SidebarDockViewController` |
| Spaces strip / paging | AppKit container + SwiftUI creation sheet | `SidebarPagingContainerViewController`, `SidebarSpaceViewController` vs `SpaceCreationHostingViewController` |
| Web content | AppKit container hosting Chromium view | `WebContentViewController`, `WebContentHostingView`, `WebContentsContainerViewController` |
| Command Bar | SwiftUI view in AppKit window plumbing | `CommandBarView`, `SuggestionsView`, `CommandBarInputContainer` + `CommandBarDebugWindowController` |
| Settings / Preferences | SwiftUI (`Settings` package) + AppKit window | `SettingsWindowController`, `SettingsTabViewController`, `Settings_Settings.bundle` |
| Boosts editor, Space style editor | SwiftUI islands | `BoostsEditor`, `SpaceStyleEditorView`, hosting controllers |
| Top bar, media controls, PiP chrome | SwiftUI islands in AppKit windows | `TopBarHostingView`, `MediaControlsHostingView`, `PIPWindowController` (AppKit) |
| Easels / rich text | AppKit canvas + text | 15 `Easel*ViewController` — dropped for Open anyway |

## 4. Windows, sidebar, tabs, persistence, threading

### 4.1 App lifecycle and windows

Evidence: `Info.plist` (`NSPrincipalClass Arc.BrowserApp`), source paths, `*WindowController` strings (22), `*ViewController` strings (61).

- Entry: `Arc.BrowserApp` (NSApplication subclass named by `NSPrincipalClass`) + `AppDelegate` (`Browser/Application/AppDelegate.swift`, `AppDelegate+Applescript.swift`). `AppDelegate` also serves AppleScript (`Arc.sdef`, `AppleScriptSpaceWrapper`, `AppleScriptTabWrapper`).
- Main window: `MainWindowController` (`Browser/Application/MainWindowController.swift`) owns `BrowserWindow` (an `NSWindow` subclass, `_TtC3Arc13BrowserWindow`) whose content is `WindowViewController` → `WindowContentViewController` (`Browser/WindowContent/WindowContentViewController.swift` + `+State`/`+Menu`). `ModalV2WindowContentContainerViewController`, `WindowContentsContainerViewController`, and `WindowContentPlaceholderViewController` manage modal/placeholder content swapping.
- Sidebar: `SidebarViewController` + `SidebarSpaceViewController` (one per Space page) inside `SidebarPagingContainerViewController` (horizontal Space paging). Cells: `TabCellView`, folder/section headers, `AppTrayViewController` (favorites/top apps tray). Hover previews: `HoverCardViewController`, `SidebarPreviewHoverTrackerState`.
- Command Bar: presented over the window (placeholder types `CommandBarPlaceholderView`, `WindowState+CommandBarPlaceholder.swift`); no dedicated `NSPanel` type string appears — the strings show a view (`CommandBarView`, `CommandBarContainer`) plus a debug window controller only. Guess: the Command Bar is a child window or sheet-less overlay view, not a panel. Runtime window-list data will settle it (see §8).
- Other windows (each an `NSWindowController` string): Little Arc (`LittleBrowserWindow` + `LittleWindowViewController`), Settings, DevTools, Browser Extension windows/popups, PiP (`PIPWindowController`, `DocumentPiPWindowController`), Capture/Share, Tooltip, Tracing, Unboxing/onboarding, Web Dialog, Modal Item Switcher, Updater. Count: 22 `*WindowController` types. Open v1 needs ~8 of these; debug/tracing/unboxing controllers are droppable.

### 4.2 Spaces, tabs, favorites, folders

Evidence: `BaseModels/SpaceModel.swift`, `SharedWindowFeature/SidebarSpaceState.swift`, `SidebarDataStore`, Storable files (§4.4).

- Space = `SpaceModel` (BaseModels) + per-window presentation `SidebarSpaceState` (SharedWindowFeature) + sync mapping `SpaceModel+CloudKit`. A Space owns containers (pinned section, favorites/top-apps, folders, unpinned "today" tabs) via `SidebarData` / `SidebarContainer` (`BaseModels/Sidebar/SidebarData+Spaces.swift`, `SidebarContainer+Cleanup.swift`).
- Sidebar items are queried/mutated through `SidebarDataStore` (queries: `SidebarSpacesQuery`, `SidebarSpaceFoldersQuery`, `SidebarSpaceFoldersWithDepthQuery`; mutator: `SidebarSpaceMutator`). Tab rows bind `TabCellState` (per-item view state) to store items; cells also exist for folders, documents, Easels, shared objects (`SidebarCells/*CellState.swift`).
- Favorites = the top-apps/favorites tray (`AppTrayViewController`, `WindowData+TopApps.swift`, `HomeButton` pages). Pinned vs unpinned is a container distinction (`UnpinnedSectionHeaderCellView`, "Clear unpinned tabs in this space", auto-archive strings), not a tab flag alone. Guess: pinned/favorite/today differ by parent container ID in `SidebarData`. Schema detail belongs to the data-model report; static names prove the container model, not field names.
- Tab groups exist (`WindowData+TabGroups.swift`, `ArcTabGroupInfo`/`ArcTabGroupResult` at the engine boundary).

### 4.3 Tabs ↔ Chromium web contents

Evidence: `ADKClient` selector strings, `WebContentFrame`, `WebContentState`, `ArcSessionTab`, `ArcWebContentsConfiguration`.

- One sidebar tab ↔ one `WebContentFrame` (ADKClient) ↔ one Chromium web contents. `WebContentFrameIdentifier` keys the mapping; `ADKClient.ensureWebContentsCreated(_:windowID:contextID:restorableSessionID:configuration:)`, `getWebContentFrame`, `cloneWebContent`, `reassignWebContent`, `requestWebContentClose/Discard`, `storeBrowserlessWebContent` (offscreen/pre-render contents) appear as strings.
- Per-tab Swift state: `WebContentState` (WebContent module) mirrors title/URL/favicon/loading/audibility/Boosts/PiP; the native view is `WebContentViewController` (app target) hosting the Chromium view via `WebContentHostingView`. Session restore crosses the bridge as `ArcSessionTab` + `restorableSessionID` (`SessionRestorationClient`, `StorableSessionRestorationData.json`).
- Split View reuses the same frames: `WebContentViewControllerSplitView`, `SplitViewContentPaneViewController` (ARCUI), `SplitViewLayoutCache`. A split pane is a second presentation of a frame, not a second tab. Peek/hover previews use frame thumbnails (`WebContentFrameThumbnailListener`, `ContentSnapshotClient`) rather than live contents where possible — static strings prove the listener exists; when thumbnails vs live views are chosen needs runtime data.

### 4.4 Persistence

Evidence: `strings` for `Storable*.json` (29 files), `Storable*` types (160 hits), live dir listing `ls ~/Library/Application Support/Arc/` (read-only, names/sizes only — no file contents were read).

- Mechanism: `StorableDataStore` / `StorableDataStoreImpl` (`Storable/StorableDataStore.swift`, `+Effects`) — a generic Codable-to-JSON store. Writes are funneled through a TCA feature, `SharedWriteToDiskFeature` (`SharedAppFeature/SharedWriteToDiskFeature.swift`), with debounce/throttle helpers in the binary (`Debouncer`, `Throttler`, `AsyncDebounceSequence`, `setupObservers(writeThrottleInterval:)`). Exact intervals are not in strings; runtime file-mtime watching will measure them (see §8).
- Location: `~/Library/Application Support/Arc/*.json` at the root (observed: `StorableSidebar.json` 312 KB in a light profile, `StorableWindows.json`, `StorableArchive.json`, … all 4 KB stubs when fresh). The full file set from strings: Sidebar, Windows, Archive, ArchiveItems, Profiles, ProfileContainers, BoostsData, Captures, KeyBindings, Home, Library, LiveData, LinkRouting, AuthState, FeatureFlags, SessionRestorationData, DownloadMetadata, PasteboardHistory, PreviewsDataClient, CommandBarAdditionalRanking, DefaultBrowserPrompts, DeveloperModeState, DynamicLogLevels, MembershipCard, TodosData, ASEConfiguration, Firebase* (3). Plus Chromium's `User Data/` dir (139 MB in the observed profile: `Default/`, `Local State`, Safe Browsing, Widevine) and caches (`SidebarItemsFaviconCache`, `ArchiveSnapshotCache`, `BoostsImageCache`, `Captures/`).
- Preferences: `UserDefaults` domain `company.thebrowser.Browser` (28 keys observed; names only: Sparkle `SU*`, `machineID`, LaunchDarkly connection store, `nativeAdBlockEnabled`, `tidyTabsEnabled`, …) behind `UserDefaultsClient`; window frames use `NSWindow` autosave names (`.mainWindowAutosaveFrame`, `.littleWindowAutosaveFrame`, …).
- Open design rule: keep the one-file-per-store JSON idea (simple, importable, debuggable) but consolidate to fewer files (sidebar+windows+archive+profiles+prefs) and write atomically with a visible throttle. Arc's 29-file sprawl includes sync/auth/AI stores Open will not have.

### 4.5 Key types per area (names proven; properties only where demangled)

| Area | Key types (evidence) | Known stored properties |
|---|---|---|
| App lifecycle | `Arc.BrowserApp` (`NSPrincipalClass`), `AppDelegate`, `AppState`/`AppData`, `AppReducer` | Unknown statically (stripped). File structure §2 is the map. |
| Windows | `MainWindowController`, `BrowserWindow`, `WindowViewController`, `WindowContentViewController`, `WindowState`/`WindowData`, `WindowReducer` | — |
| Sidebar | `SidebarViewController`, `SidebarSpaceViewController`, `SidebarPagingContainerViewController`, `SidebarDataStore`, `SidebarSpaceState`, `TabCellView`/`TabCellState` | `ThemeAwareHostingView.subscriptions: Set<AnyCancellable>` (demangled, BaseModels) |
| Spaces | `SpaceModel`, `SidebarSpaceState`, `SpaceCreationHostingViewController`, `SpaceStyleEditorState` | — |
| Tabs | `WebContentState`, `WebContentFrame` (ADKClient), `ArcSessionTab` (engine), `TabCellState` | — |
| Favorites/top apps | `AppTrayViewController`, `WindowData+TopApps` | — |
| Folders | `SidebarSpaceFoldersQuery`, `WindowData+Folders`, `StorableFolderDataStore` (`StubStorableFolderDataStore` for tests) | — |
| Archive | `ArchiveState`, `ArchiveState+AutoArchive`, `PersistedArchiveState`, `StorableArchive`, `ArchiveDataStoreClient` | — |
| Command Bar | `CommandBar` (store), `CommandBarInstance`, `CommandBarView`, `SuggestionsView`, `SearchClientManager` | `SearchClientManager`: `providers`, `rankingData`, `fuzzyMatchScoreCache`, `tokenizedTextMatchInfoCache`, `profileSpecificStates` (demangled accessors) |
| Split View | `SplitViewController` (ARCUI), `SplitViewContentPaneViewController`, `SplitViewLayoutCache`, `WindowData+SplitViewHelpers` | — |
| Little Arc | `LittleBrowserWindow`, `LittleWindowViewController`, `LittleBrowser` (feature), `WindowState+LittleBrowser` | — |
| Peek / previews | `HoverCardViewController`, `PreviewsDataStore`, `WebContentFrameThumbnailListener`, `WindowData+EmailPeeking` (link Peek) | — |
| Profiles | `AppData+Profiles`, `ProfilePreferencesState`, `StorableProfiles`, `StorableProfileContainers`, `ProfilesUI` | — |
| Air Traffic Control | No dedicated Swift type found; strings only: "air traffic controller", `openAirTrafficControl`, `OpenAirTrafficControlCodingKeys`. Guess: ATC is a Command Bar / link-routing mode (`LinkRoutingClient`, `LinkRoutingEditor`, `AppState+DefaultLinkRoutes`) that chooses profile/window per link, not a separate window. Runtime use will confirm. | — |
| Boosts | `BoostsClient` (storage protocol: demangled `Boosts Storage`, `WebContentHelper`, `ImageCache`), `StorableBoostsData`, editor/dialog modules | — |
| Settings | `SettingsWindowController`, `PreferencesFeature`, `ProfilePreferencesState`, `ArcUserDefaultSettings` | — |
| PiP / media | `PIPWindowController`, `DocumentPiPWindowController`, `MediaControlsFeature`, `MiniPlayerFeature` | `PIPWindowController`: `subscriptions`, `pipMenu: NSMenu` (demangled) |

## 5. The Swift ↔ ArcCore bridge (ADK)

Finding: Arc does not call Chromium C++ directly from feature code. It defines a Swift protocol layer, module `ADK`, implements it against ArcCore's Objective-C classes in `ADKClientLive`, and injects it as a TCA dependency (`ADKClient`). Feature code sees only protocols. This is exactly the "engine layer" Open's AGENTS.md mandates for CEF — Arc's shape validates the plan.

Evidence and shape:

- ADK protocols (mangled `$s3ADK…P`, demangled with `xcrun swift-demangle`: `ADK.Browser`, `ADK.WebContent`, `ADK.BrowserContext`, `ADK.ADKApplicationDelegate`): `Browser`, `BrowserContext` (+ `BrowserContextDevTools`), `WebContent` (+ `WebContentUIDelegate`, `WebContentNavigationDelegate`/`Listener`, `WebContentPDFDelegate`, `WebContentOverscrollDelegate`, `WebContentTopBandColorDelegate`), `BrowserDelegate`, `ADKApplicationDelegate`, `Navigation`, `ADKURLLoader`, `JavaScriptExecuting`, `Downloadable`/`ContextDownloadDelegate`, `TracingController` (+ delegate), `BrowserSidePanelDelegate`, `BrowserExtensionsPopupDelegate`, `DeletableAutocompleteMatchesKeyProviding`. DevTools sub-protocols: `DevTools.Page/Runtime/Network/Console/Input/PerformanceTimeline` Command/Event pairs.
- Implementations (`ADK/*.swift` strings): `ADK.ChromiumBrowser` (`BrowserChromium.swift`), `ADK.WebContentChromium` (`WebContentChromium.swift` + Navigation/UIDelegate extensions), `ADK.BrowserContext` (`BrowserContext.swift`, `BrowserContextDelegateBridge.swift`), `ADK.TracingControllerChromium`, `ADK.ChromiumDownload`, `ADK.AccessibilityObserver`, `ADK.ImportDelegate`, `ADK.SessionRestorationBrowserDelegate`. App-side wiring: `ADKApplicationFeature` (`Frameworks/ARC/Sources/ADKApplicationFeature/ADKApplicationFeature.swift`), `SharedAppFeature/AppData+ADKApplicationFeature.swift`, `$__lazy_storage_$_adkApplicationDelegateBridge`, `ADK web view teardown complete` log string.
- Dependency client: `ADKClient` (operations as strings: `_browser`, `_browserContext`, `_createBrowserContext`, `_cloneWebContent`, `_navigateTab`, `_executeJavaScript`, `_performFindInPage`, `_respondToPermissionRequest`, `_favicon`, `_getDevToolsFor`, `_subscribeToADKEffects`, …) with live impl `ADKClientLive/ADKClient+Live.swift` and frame type `ADKClient.WebContentFrame` (`WebContentFrame.swift`, delegates `WebContentFrameDelegate`, `WebContentFrameThumbnailListener`).
- Objective-C classes imported from ArcCore (undefined `_OBJC_CLASS_$_Arc*` in the Swift binary, 63 classes, `.re/architecture/objc-arc-prefix.txt`): browser/context (`ArcBrowserApplication`, `ArcBrowserApplicationConfiguration`, `ArcBrowserContext`, `ArcBrowserContextAttributes`, `ArcWebContentsConfiguration`), tabs/sessions (`ArcSessionTab`, `ArcSessionID`, `ArcTabGroupInfo/Result`, `ArcBackForwardListItem`, `ArcNavigation`), data (`ArcHistoryItem`, `ArcHistoryQueryOptions`, `ArcBookmarkTreeNode`, `ArcDownloadItem`, `ArcCookie`, `ArcMostVisitedURL`, `ArcSiteEngagementDetails`, `ArcSiteSettingInfo`, `ArcSearchEngine`, `ArcAutocompleteMatch`), extensions (`ArcExtensionInfo`, `ArcExtensionCommand`, `ArcExtensionToolbarAction`), prompts/permissions (`ArcPermissionRequest`, `ArcLoginCredentialsSaveRequest`, `ArcCreditCardInfoSaveRequest`, `ArcAddressEntrySaveRequest`, `ArcNotification*`), import (`ArcImportSource`, `ArcImportSourceProfile`), media/misc (`ArcImageRep`, `ArcColor`, `ArcHSLAMatrix`, `ArcKeyEventData`, `ArcCpuInfo`, `ArcGPULogMessage`, `ArcPerformanceController`, `ArcCrashKeysReporter`, `ArcTracingConfiguration`, `ArcURLLoadConfiguration/CancellationToken`, `ArcURLUtilities`), and Arc Max ranking (`ArcCommandBarRanking*` tensor/model types, `ArcNomicEmbedText*`, `ArcAI*` — DROP with AI). No `ADK*` ObjC classes exist; ADK is pure Swift over these `Arc*` classes. System ObjC imports (367 total) are standard AppKit/Foundation/CloudKit/AVFoundation classes.
- Resources crossing the bridge: `ADK_ADK.bundle` (`selectors.css`, `adblock_list.json`) — content-blocking and page-extraction data ship as files, not code.

For Open: mirror this layering over CEF — `Engine` protocols (Browser/Context/WebContent + delegates), a `CEFClientLive` implementation, TCA/`Dependency` injection, and value types for history/downloads/permissions. Keep the ObjC surface as small as Arc's (~50 non-AI classes).

## 6. Why Arc is heavy, and what Open should do instead

Concrete weight sources (all measured above; no runtime profiling was done):

| # | Source | Evidence | Open countermeasure |
|---|---|---|---|
| 1 | Statically linked monolith shell: 158 MB fat executable, 56 MB `__text`, 1.9 MB `__swift5_typeref`, 4.4 MB exports trie | `size -m .re/bin/Arc-arm64`, `otool -l` | Drop whole feature families (sync, AI, Easels) so their code never links. Measure the arm64 slice, not the fat binary. |
| 2 | Eager SDK init at launch: Firebase, Datadog (+OpenTelemetry), LaunchDarkly, Sentry profiler, Sparkle | SDK start strings (§6 bundle-anatomy); clients wired in `SharedAppFeature` (`+Sentry`, `AppData+RemoteConfig/Instrumentation`) | Init nothing network-bound at launch except Sparkle's scheduled check. No swizzling (Datadog `MethodSwizzler`) in Open. |
| 3 | Sync duplication: two sync engines (Firestore + CloudKit) + encryption + debug stores | 23 sync source files, 6 `StorableFirebase*/Sync*` files, iCloud entitlement | One local store. No sync in v1 (locked decision). |
| 4 | Onboarding/Auth media: 57 MB bundles + ARCUI videos | `du -sh` bundle table | Native onboarding views; no video bundles. |
| 5 | Font payload: 11 MB, 80+ files, registered at launch | FontsManager bundle | License 1–2 families (or system fonts) for UI; lazy-register display fonts. |
| 6 | SwiftUI island overhead + introspection layer | 11 hosting views + `SwiftUIIntrospect`, `ThemeAwareHosting*` wrappers with Combine subscriptions | AppKit for sidebar/windows (already Arc's choice); SwiftUI only for settings/dialogs; no introspection. |
| 7 | TCA + client sprawl: ~120 feature modules, ~60 clients, 539 surviving file paths | source-path grouping | Keep the feature/client shape but start with far fewer modules; add a client only when a second implementation (test/import) needs it. |
| 8 | Per-window/per-tab object graph: `WindowData` × 60 concerns, `WebContentState` per tab, thumbnail/snapshot clients | SharedWindowFeature file list; `ContentSnapshotClient`, `ArchiveSnapshotCache` | Keep per-tab state value-typed and small; snapshots on demand, not per tab by default. Measure idle CPU with 100 tabs (runtime, §8). |
| 9 | Engine helpers duplicated (classic + Aperitif) and 200 engine locales | Helpers table; ArcCore Resources | Ship CEF's helpers once; trim locales only with a custom build. |
| 10 | Chromium itself: 591 MB framework, 139 MB observed `User Data` | `du` | Unavoidable with Chromium/CEF. Open's win is the shell (rows 1–8), not the engine. |

What to copy from Arc: (a) AppKit sidebar/windows with SwiftUI islands; (b) protocol-first engine layer (ADK shape) so CEF can be replaced; (c) one-file-per-store Codable JSON with a single write-to-disk funnel; (d) feature/client module split; (e) data-driven Command Bar (`command_bar_behavior.json`) and blocklists (`adblock_list.json`, BlockListClient) as files.

## 7. Design sketch for Open (derived, not Arc code)

- Shell: `NSApplication` + `AppDelegate`; `MainWindowController` → sidebar (AppKit collection view) + content container; Spaces as sidebar pages; Command Bar as overlay view (confirm Arc's mechanism at runtime first).
- State: one app store + one window store per window + per-tab value state. If TCA's testability is wanted, use upstream TCA at the app root only; otherwise Observation + explicit actions. Do not fork-vendor TCA as Arc did.
- Engine: `Engine` protocols copied in shape from §5 (Browser/Context/WebContent + delegates), `CEFClientLive` behind them, injected as a dependency.
- Persistence: `Sidebar.json`, `Windows.json`, `Archive.json`, `Profiles.json`, `Prefs` (UserDefaults). Atomic writes through one throttled writer. Import-from-Arc reads Arc's `Storable*.json` (schemas in the data-model report).
- Budgets: shell arm64 slice target well under Arc's ~76 MB; idle CPU near zero with no sync/analytics pollers; sidebar scroll 120 Hz on AppKit cells.

## 8. Open questions that need runtime data (user signed in to Arc)

1. Command Bar presentation: child window, panel, or overlay view? (No `NSPanel` type statically.) Observe the window list while the Command Bar is open.
2. Helper family in use: Aperitif or classic renderers/GPU processes? Settles whether `kAperitifHelpers` defaults on.
3. Persistence timing: real `writeThrottleInterval` and which `Storable*.json` files rewrite on a tab move vs on quit. Watch file mtimes during normal use.
4. Reducer threading: are `WindowData` mutations ever off the main thread? Needs Instruments/signposts, not strings.
5. Peek/Split View: when does Arc use frame thumbnails vs live web contents? Affects Open's memory design for previews.
6. Air Traffic Control: confirm it is link-routing (`LinkRoutingClient`) rather than a window type. Open `arc://` links per profile and observe.
7. Real heavy-profile sizes: `StorableSidebar.json`, favicon caches, and `User Data` after months of use; the observed profile is light (312 KB sidebar file).

