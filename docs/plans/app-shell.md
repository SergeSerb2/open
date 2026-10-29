# App shell — replace the plain M1 shell with the real Arc window

Status: Steps A and B implemented; acceptance and limits are in [docs/app-shell.md](../app-shell.md). Steps C–I remain planned. Amended 2026-10-26 for Arc capture session 2: sidebar width limits, drag-to-hide, double-click reset, Cmd+S and hover-reveal motion, the translucent card, and the Space-switch spring (§3.2, §3.3, D4, §6, Q3, Q11, lead decisions); the command bar (i) target (§4.2); Little Open frames (§3.8). Evidence: `docs/re/interaction-states.md` §20.1, §20.2, §20.12 (**S2 06/0029** = frame 0029 of `.re/runtime/sessions/20261026-101147-06-sidebar-width/`; **V 16.26 s** = time in `.re/runtime/video/21-motion.mov`). This file is the complete brief for the coding agents that implement it. Those agents have no other context. Read this file top to bottom, then read each source it names before you edit that area. Do not invent a second design.

User-visible name rule: never use the Arc brand in UI text. "Little Arc" is "Little Open" in Open. The only exception is "Import from Arc". Search aliases may keep old names (`docs/commands.md`).

Reference facts come from `AGENTS.md`, `docs/architecture.md`, `docs/engine-api.md`, `docs/automation.md`, `docs/engine-spike.md`, `docs/model.md`, `docs/design.md`, `docs/commands.md`, `docs/suggest.md`, `docs/routing.md`, `docs/plans/routing-little-open.md`, `docs/plans/m4-split-peek-littleopen.md`, `docs/sleep.md`, `docs/plans/memory-fork.md`, `docs/boosts.md`, `docs/adblock-lists.md`, `docs/scripting.md`, `docs/favicons.md`, `docs/plans/profiles.md`, `docs/plans/settings-library.md`. Where this plan and a library doc disagree on a library's own API, the library doc wins and you stop and report the conflict. Where this plan and `docs/plans/m4-split-peek-littleopen.md` disagree on a Little Open signature, the routing plan wins (M4 §0.3 rule 3).

## Goal

Replace the plain M1 shell in `App/` (`App/BrowserWindowController.swift`: `NSTableView` tab list, address field, `NSVisualEffectView` sidebar) with the real Arc window: `OpenSidebar` on the left, `OpenFeatures.WebContentContainer` on the right, command bar overlay, Peek overlay, and toasts. Wire every OpenKit library to the model and to `OpenEngine` end to end: sidebar intents, command bar, menus and keys, Little Open routing, Boosts, ad blocking, tab sleep, favicons, history, downloads, permissions, dialogs, find, context menus, AppleScript, and a Settings placeholder. Hit the cold-launch budgets in `docs/architecture.md`: sidebar drawn in ≤ 250 ms, first web paint in ≤ 700 ms (release build, M5 Pro).

## Success criteria

1. A release build launches to the Arc window. The sidebar matches Arc captures within the targets in `docs/design.md` §8 (layout ≤ 1 pt, fill and text ΔE00 ≤ 2). The web panel uses the measured insets, radius, and shadow.
2. Every `SidebarIntent` case in `Packages/OpenKit/Sources/OpenSidebar/SidebarIntent.swift` is handled. A refused intent returns `false`. No intent falls through silently.
3. Selecting a tab creates its web content lazily, attaches it in the container, and shows placeholder or sleeping state until it is live. Only the selected tab loads at launch.
4. Command bar (Cmd+T, Cmd+L), menus, and keys run the same `OpenCommands` command ids. App shortcuts work while a page has focus.
5. External links route through `OpenRouting` Phase B. The global hotkey opens Little Open.
6. Boosts inject at document start. Ad blocking blocks through the engine request hook until the fork ad-block engine lands. Sleep freezes and discards through the S6 adapter on today's engine API.
7. Favicons, history, downloads, permissions, JS dialogs, find, and native context menus work through real engine events.
8. Two or more windows, full screen, sidebar hide and hover-reveal, and window state restore all work. State survives quit and relaunch.
9. Each step below passes its automation suite and `tools/verify-all.sh` reports PASS for every target that exists. No unit tests are added (`AGENTS.md` rule 6).

## Non-goals

- No Easels, Notes, Arc Max AI, Arc account, login, or sync (`AGENTS.md` v1 scope).
- No fork patches in this plan. P1–P7 in `docs/engine-patches.md` and P-MEM-01…07 in `docs/plans/memory-fork.md` land in their own PRs. This plan uses today's stock-CEF `OpenEngine` API and names each place that waits for a patch.
- No Settings UI. Cmd+, opens a placeholder window until `OpenSettings` lands (`docs/plans/settings-library.md`). The placeholder wires only the three controls in §4.11; it holds no other preferences.
- No new OpenKit library. If a type is missing, add it to the library that owns the area, in that library's own PR step below.

## 0. Locked decisions

| # | Decision | Why |
|---|---|---|
| D1 | The App target owns exactly one window controller type: `OpenFeatures.BrowserWindowController` (`m4/split-peek-littleopen` branch, now moving into the `OpenFeatures` library). The App target creates it with an engine factory. Delete the plain M1 `App/BrowserWindowController.swift` in Step B. Never keep two window controllers. | M4 Steps 8–9 put `WebContentContainer`, Peek, Little Open, and this controller in `OpenFeatures`. A second App-side controller would drift. |
| D2 | Packages never import `OpenEngine` or CEF. Only `App/` joins OpenKit to the engine (`docs/architecture.md`). The bridge files are `App/EngineBridge.swift` (exists) plus the new files in §2.3. | Keeps the engine swappable. Already the rule for `OpenWeb`. |
| D3 | One `BrowserModel` per app, `@MainActor`. All state changes are named model commands. Views observe slices. The App maps engine events to model updates. | `docs/architecture.md` state rules; `docs/model.md`. |
| D4 | Sidebar width is per-window state: `BrowserWindowState.sidebarWidth` (default 228) and `sidebarMode` (`.anchored` / `.hidden`). Drag resizes between 164 and 500 pt (the compact toolbar shows below 219 pt); dragging past the minimum hides the sidebar while the button is still down; Cmd+S then restores the width from before the drag; a double-click on the edge resets to 228 (see §3.3). Persist on drag end, not per tick. | Measured in capture session 2 (S2 06/0009–0088; `docs/design.md` §2.2 "Sidebar width"). `WindowMetrics` in `OpenDesign`: `defaultSidebarWidth 228`, `minSidebarWidth 164` (measured; compact toolbar below 219), `maxSidebarWidth 500` (now measured), `sidebarDragHidePoint 82` (pointer x for the hide while pressed; guess inside the measured 65–85 band). `SidebarContext.sidebarWidth` already reads the model value. Supersedes the 2026-10-25 228–500 / 180 pt rule. |
| D5 | Command bar comes from branch `m3/commandbar-ui` (`OpenCommandBar` target: `CommandBarController`, `CommandBarDelegate`, `CommandBarIntent`, `CommandBarRequest`, `CommandBarMode`). Integrate against that delegate API exactly as documented in §4.2. If the branch has not merged when Step C starts, cherry-pick nothing; wait and report. | The Opus agent building `OpenCommandBar` owns that API. A guessed parallel API would need a rewrite. |
| D6 | Menus, keys, and the command bar share one registry: `OpenCommands.CommandRegistry`. The App implements `CommandDispatcher` once (in `OpenFeatures.BrowserWindowController`, which already conforms) and extends it in the App for engine commands. | `docs/commands.md`: one source of truth. |
| D7 | Engine contexts are lazy per profile. `OEEngine.shared.defaultContext` serves the default profile; other profiles use `context(identifier:directory:)` at `Engine/<dir>` (`ProfileDirectories.engineDirectory`), created when a Space of that profile is first shown. | `docs/engine-api.md`; `docs/plans/profiles.md` D-P7 and §6.2. `root_cache_path` is `<root>/Engine`; the default profile's engine data is `Engine/Default` (CEF's fixed global context). CEF loads a disk profile only for a direct child of `root_cache_path`. |
| D8 | Boosts: the managed applier and the Zap picker run in an isolated world. User-authored Boost JS runs in the main world. Stock CEF user scripts are main-world only (patch P7), so until P7 lands the App installs plans through `WebProfile.addUserScript` in the main world and marks the isolation gap in code with `// Blocked on P7: isolated world`. Never claim isolation before P7. | `docs/boosts.md` engine contract; `docs/engine-api.md` gap table. |
| D9 | Ad blocking: until the fork engine lands, the App builds a `RequestFilter` from `AdBlockStore` state and installs it with `WebProfile.setRequestFilter`. The filter runs on the network thread. It must be `@Sendable`, fast, and read only an immutable snapshot swapped atomically on list changes. | `docs/adblock-lists.md` (generation contract); `OpenWeb.RequestFilter` contract. |
| D10 | Sleep: implement the S6 adapter (`docs/plans/memory-fork.md` §12 S6, `docs/sleep.md`) on today's `OEWebContent` API (§4.7 table): freeze = hide + throttle, discard = `close()` + recreate on wake. Capabilities with no today equivalent (`captureHistory`, `hasUnloadHandlers`, real history restore) return `nil` / `false`. List every such stub in the PR. | S0 policy is done. The fork patches are not. A stub that returns `false` keeps the policy safe; a fake success corrupts state. |
| D11 | Automation first. Every step adds or extends a `--only` suite in `tools/e2e/engine_e2e.py` before or with the feature. A step is not done until its suite passes on the real app. | `AGENTS.md` rule 6; `docs/automation.md`. |
| D12 | Window state persistence uses the model snapshot (`BrowserWindowState` in `State/browser.json`), the StorableWindows-like store. No `NSWindow` frame autosave, no AppKit state restoration (`ApplePersistenceIgnoreState` stays on). | Current `App/main.swift` already disables AppKit restoration. One store, debounced save, flush on quit. |

## 1. Current state (verified 2026-10-25; re-verify before you edit)

Do not trust this section blindly. Run `git log --oneline -3`, `ls App Packages/OpenKit/Sources`, and read the file you are about to change.

| Area | State today | Evidence |
|---|---|---|
| App target | Plain M1 shell. `App/AppDelegate.swift` owns the model, `SnapshotStore`, `ProfileArchiveSink`, and `[BrowserWindowController]`. Windows build at the first of `applicationDidFinishLaunching` and `engineDidInitialize`. `prepareData()` loads the snapshot and runs `OpenDataRoot.prepare` before the engine starts. | Read both files in full. |
| Plain window | `App/BrowserWindowController.swift` (~1,200 lines): titled window, `titlebarAppearsTransparent`, `NSTableView` rows, address field, extension bar, find field, one `OEWebContent` per loaded tab in `contents`, one `OEBrowser` per profile in `browsers`, `syncTabStrips()`, dialogs, permissions, context menus, find, fullscreen, extension popups, auxiliary `window.open` panels. This file is the wiring inventory for §4: every behavior in it must land in a new owner or be dropped on purpose and named. | Read it in full before Step B. |
| Engine start | `App/main.swift`: `OEApplication.shared` first, `prepareData()`, `OEEngineConfiguration` (`userDataDirectory = <root>/Profiles`), `OEEngine.shared.start` (`CefInitialize`), `runMessageLoop()`, `saveState()`, `shutdown()`. `keyEquivalentHandler` routes reserved shortcuts to `MainMenu.performReservedShortcut`. | Read it in full before Step A. |
| Menus today | `App/MainMenu.swift`: hand-built subset, `reservedTag` items. Replaced by `OpenCommands.MenuBuilder` in Step C. | `docs/commands.md`. |
| Engine bridge | `App/EngineBridge.swift`: `OEWebContent: WebContent`, `EngineWebProfile: WebProfile`, `EngineExtensionHost: ExtensionHost`. Keep and extend; do not duplicate. | Read it in full. |
| OpenSidebar | Done. `SidebarView(context:)`, `SidebarContext(model:windowID:)`, `SidebarDelegate.sidebar(_:didRequest:) -> Bool`, `SidebarIntent` (all cases in `SidebarIntent.swift`), `ModelSidebarActions` for model-only intents, `SidebarView.Presentation.anchored / .floatingCard`, `SidebarContext.isNewTabCommandBarOpen`, `faviconProvider`. Host owns `ThemeBackgroundView` and assigns `sidebar.themeBackground`. | `docs/design.md` §5. |
| OpenDesign | Done. `WindowMetrics`, `PanelMetrics`, `Metrics`, `ThemeBackgroundView`, `WebPanelChromeLayer`, `SpaceThemeStyle`. Traffic lights are system-drawn; measured centers at x 12/35/58, y 16, 12 pt circles. | `docs/design.md` §2. |
| OpenFeatures | On branch `m4/split-peek-littleopen`, moving into the `OpenFeatures` library now: `WebContentContainer`, `WebContentHost`, `WebContentHostFactory`, `PaneSlotView`, `PlaceholderContentView`, `SplitViewController`, `PeekController`, `PeekOverlayView`, `LittleOpenCoordinator`, `LittleOpenSession`, `LittleOpenWindowController`, `AppVisibilityProvider`, and a `BrowserWindowController` that already conforms to `SidebarDelegate` and `CommandDispatcher` and owns sidebar + container + Peek + toasts. On `main` this target does not exist yet. Step B waits for that PR. | M4 plan Steps 1–7, §5, §9. If the library PR renamed a type, use the library name and report the rename. |
| OpenCommandBar | On branch `m3/commandbar-ui`: `CommandBarController` with `delegate: CommandBarDelegate`, `present(_ request: CommandBarRequest)`, `dismiss(reason:)`. `CommandBarIntent`: `.open(URL, destination, modifiers)`, `.search(query:url:siteSearchID:destination:modifiers)`, `.switchToTab(ItemID, spaceID:)`, `.runAction(id:spaceID:)`, `.copy(String)`, `.showHelp`, `.dismissed(reason)`. Not on `main` yet. | §4.2. Verify with `git show m3/commandbar-ui:Packages/OpenKit/Sources/OpenCommandBar/CommandBarTypes.swift` before Step C. |
| OpenCommands | Done on `main`: `CommandRegistry`, `MenuBuilder.buildMainMenu(dispatcher:spaces:tabs:overrides:)`, `CommandDispatcher` (`performCommand(_:)`, `performCommand(_:payload:)`, `isCommandEnabled(_:enabledKey:)`), `KeyBindings` / `KeyBindingStore`, `KeyboardRouter.route(shortcut:context:overrides:)`, `GlobalHotkeyService`, `makeSuggestRegistry()`. | `docs/commands.md`. |
| OpenSuggest | Done: `SuggestEngine(model:history:fetcher:)`, `query(_:context:) -> AsyncStream<SuggestionSnapshot>`, `SuggestContext`. The App owns one engine per window profile set (see §4.2). | `docs/suggest.md`. |
| OpenRouting | Phase A done: `RoutingEvaluator.evaluate(_:in:)`, `RoutingSnapshot`, `RoutingDecision`, `RoutingDecisionLog` (last 200, memory-only), `LinksSettingsModel`. Phase B (intake, default browser, Little Open wiring) is §4.4 of this plan. | `docs/routing.md`; routing plan §8–§9, §13 Steps 5–7. |
| OpenSleep | S0 done: `SleepController(model:engine:store:visibility:chromiumTag:)`, `SleepEngine`, `SleepVisibilityProviding`, `SleepHistoryStoring`, `SleepStore`, OPNH `SleepHistoryContainer`. S6 App adapter is §4.7. | `docs/sleep.md`; memory-fork §12 S6. Read the exact initializer in `SleepController.swift` before wiring. |
| OpenBoosts | Done, no App wiring: `BoostStore(root:profileID:fileURL:)` (App must pass `ProfileDirectories.boostsFileURL(for:)`), `BoostMatcher`, `BoostInjectionPlanner.plan(url:profileID:matcher:globalEnabled:context:) -> InjectionPlan`, `BoostPickerCoordinator`, `BoostResources.applierJS / pickerJS`, `BridgeDecode`. | `docs/boosts.md`. |
| OpenAdBlock | Done, no App wiring: `AdBlockStore(root:bundledDefaultsDirectory:)`, `openProfile(_:scheduleUpdates:)`, `setListEnabled`, `setExcluded(_:excluded:profile:)`, `listDirectory(for:)` returns the adblock root; the engine resolves `current.json` generations. Read the exact initializer in `AdBlockStore.swift`. | `docs/adblock-lists.md`. |
| OpenStore | Done: `SnapshotStore`, `HistoryStore.recordVisit(url:title:time:transition:typed:)`, `FaviconStore` (actor) + `FaviconFetcher`, `ProfileDirectories`, `OpenDataRoot.prepare`, `ProfileArchiveSink`, per-profile archive and history files. | `docs/model.md`, `docs/favicons.md`, profiles plan §5. |
| OpenScripting | Done, needs App hooks H1–H4: `ScriptHost.shared` providers, `ScriptEngineBridge`, `App/Resources/Open.sdef`, Info.plist keys. | `docs/scripting.md` §App hooks. |
| Automation | `App/Automation/AutomationServer.swift` + `AutomationController.swift`, socket at `<data root>/automation.sock`, `tools/openctl`, `tools/e2e/engine_e2e.py` with `--only shell|features|extensions|measure`. | `docs/automation.md`. |
| Measurements | Under load: sidebar shown 452 ms, first paint 649 ms. Budgets are 250 / 700 ms on an idle machine. The named wins: build the window before `CefInitialize` returns; keep the CEF framework signature stable. | `docs/engine-spike.md` Measurements. |

## 2. Target architecture

### 2.1 View and ownership tree (one standard window)

```text
NSWindow (titled, hidden titlebar, §3.1)      owned by OpenFeatures.BrowserWindowController
└── FeatureRootView (flipped, layer-backed)
    ├── ThemeBackgroundView                   OpenDesign; fills window; sidebar.themeBackground
    ├── SidebarView (one instance)            OpenSidebar; frame from BrowserWindowState;
    │                                         presentation .anchored, or .floatingCard for hover-reveal
    ├── WebContentContainer                   OpenFeatures; PanelMetrics frame (§3.4)
    │   └── PaneSlotView × 1–4                clip: radius 6, shadow; host view or PlaceholderContentView
    ├── PeekOverlayView                       OpenFeatures; scrim + panel + 3 buttons; above container
    ├── CommandBar panel (child window)       OpenCommandBar; §3.5
    ├── Find bar                              App; §4.9
    └── Toast view                            OpenFeatures controller already owns one; reuse it
```

Little Open windows use `LittleOpenWindowController` (OpenFeatures) with a single-pane `WebContentContainer`. Settings uses one shared placeholder `NSWindow` (§4.11). Extension popups, JS dialogs, permission prompts, and `window.open` sized popups keep the M1 panel behavior (§4.9, §4.12).

### 2.2 Who owns what

| Concern | Owner | App glue |
|---|---|---|
| Model, snapshot, undo | `AppDelegate` (exists) | `scheduleSave()` observer; `saveState()` on quit |
| Window lifecycle, sidebar, container, Peek, split, toasts | `OpenFeatures.BrowserWindowController` | App creates it per `BrowserWindowState`, sets `onOpenCommandBar`, `onVisibilityChange` |
| Engine page per tab | `EngineWebContentHost` (new, `App/WebContent/`) conforming to `WebContentHost` | `EngineWebContentHostFactory` maps `ProfileID` → `OEBrowserContext`, creates `OEWebContent` |
| Tab strip mirror for extensions | `App/TabStripMirror.swift` (new): keeps one `OEBrowser` per (window, profile) in sidebar order | Port `syncTabStrips()` from the M1 file |
| Menus | `OpenCommands.MenuBuilder` | `App/MainMenu.swift` becomes a thin builder call + rebuild triggers |
| Command dispatch | `BrowserWindowController: CommandDispatcher` (exists in OpenFeatures) + App extension for engine-only commands | §4.3 command table |
| Command bar | `CommandBarController` per window | `App/CommandBar/AppCommandBarDelegate.swift` (new) |
| Suggest backend | One `SuggestEngine` per app, rebuilt when the focused profile changes | §4.2 |
| External links | `App/ExternalLink/*` (new, routing plan §8) | §4.4 |
| Little Open sessions | `LittleOpenCoordinator` (OpenFeatures) | App executor conformance, hotkey, sweeper timer |
| Boosts | One `BoostStore` + `BoostMatcher` per loaded profile | `App/Boosts/BoostEngineAdapter.swift` (new) |
| Ad blocking | One `AdBlockStore` per app; one filter snapshot per profile | `App/AdBlock/AdBlockEngineAdapter.swift` (new) |
| Sleep | One `SleepController` per app | `App/WebContent/EngineSleepAdapter.swift`, `App/Sleep/AppSleepCoordinator.swift`, `AppVisibilityProvider` (OpenFeatures) |
| Favicons | One `FaviconStore` + `StoredFaviconCache` per app; fetcher remains an opt-in library/CLI API | Engine `.favicon` change → queued `ingest`; `SidebarContext.storedFavicons` supplies the bounded cache |
| History | One `HistoryStore` per loaded profile | Engine commit → `recordVisit` (§4.8) |
| Downloads, permissions, dialogs, context menus | `BrowserWindowController` engine delegate methods, ported from the M1 file | §4.9 |
| AppleScript | `ScriptHost.shared` providers + `AppScriptEngineBridge` | §4.10 |

### 2.3 New App files (create exactly these; no others without a plan change)

```text
App/WebContent/EngineWebContentHost.swift        WebContentHost over OEWebContent (M4 §8)
App/WebContent/EngineWebContentHostFactory.swift WebContentHostFactory; profile → context map
App/WebContent/EngineSleepAdapter.swift          SleepEngine over OEWebContent (memory-fork §8)
App/TabStripMirror.swift                         OEBrowser per (window, profile); sidebar order
App/CommandBar/AppCommandBarDelegate.swift       CommandBarDelegate → model + engine (§4.2)
App/ExternalLink/DefaultBrowserService.swift     routing plan §8.4
App/ExternalLink/ExternalLinkIntake.swift        routing plan §8.5
App/ExternalLink/SourceAppResolver.swift         routing plan §8.6
App/LittleOpen/AppLittleOpenExecutor.swift       routing plan §8.7 executor conformance
App/Boosts/BoostEngineAdapter.swift              InjectionPlan → WebProfile user scripts (§4.5)
App/AdBlock/AdBlockEngineAdapter.swift           AdBlockStore → RequestFilter snapshot (§4.6)
App/Sleep/AppSleepCoordinator.swift              SleepController + visibility + quit capture (§4.7)
App/Stores/AppStores.swift                       FaviconStore, HistoryStores, BoostStores, AdBlockStore registry
App/Scripting/AppScriptEngineBridge.swift        scripting.md H2 (only file importing OpenScripting + OpenEngine)
App/Resources/Open.sdef                          scripting.md H3 (copy to bundle Resources)
App/Settings/SettingsPlaceholder.swift           Cmd+, placeholder window (§4.11)
```

Files edited, not created: `App/main.swift`, `App/AppDelegate.swift`, `App/EngineBridge.swift`, `App/MainMenu.swift`, `App/Info.plist`, `project.yml` (link `OpenFeatures`, `OpenCommandBar`, `OpenCommands`, `OpenRouting`, `OpenBoosts`, `OpenAdBlock`, `OpenSleep`, `OpenScripting` products to the App target as each step needs them), `App/Automation/AutomationController.swift` (new commands per step), `tools/e2e/engine_e2e.py` (new suites per step).

Deleted in Step B: `App/BrowserWindowController.swift` (after its behaviors are ported; §4.13 is the port checklist) and the M1-only parts of `App/MainMenu.swift`.

### 2.4 Threading rules (apply everywhere; Swift 6 strict concurrency)

1. Everything in the App target is `@MainActor` unless a doc says otherwise. `OEWebContentDelegate`, `OEBrowserDelegate`, `OEBrowserContextDelegate` callbacks arrive on the main thread (`docs/engine-api.md`).
2. `OEBrowserContext.requestFilter` runs on the network thread. The closure captures only a `Sendable` immutable snapshot (compiled block set + exclusion set + counters). Never touch the model, `AdBlockStore`, or AppKit inside it. Swap the snapshot with one atomic reference write on the main actor.
3. `FaviconStore` and `FaviconFetcher` are actors. The store initializer performs no file I/O; its first actor operation opens SQLite off the main actor (§5). All store operations are `await`. Never block the main actor on SQLite.
4. `HistoryStore` opens per profile on first use. `recordVisit` calls from engine delegates are main-actor; the store serializes internally. Do not await history on the navigation path.
5. `BoostStore` is `@unchecked Sendable` with its own I/O queue. Load once per profile before mutation. `saveNow()` on quit; neither `saveNow()` nor `flush()` may run on its private I/O queue (`docs/boosts.md`).
6. Sleep capture and discard are `async`. `SleepController.captureAllForQuit()` must finish before engine shutdown (§4.7 quit order).
7. No `Task.detached` for UI work. No polling timers except: the sleep controller's own 5 s pass, the Little Open sweeper (routing plan §9.6), and the snapshot debounce that exists. Idle CPU must stay near zero (`docs/architecture.md`).

## 3. Window composition

Implement this section in `OpenFeatures.BrowserWindowController` plus the App factory. If the OpenFeatures PR already built part of it, keep that code and fill the gaps. Do not rebuild a parallel layout in the App target.

### 3.1 Window and traffic lights

- Style mask: `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`. Set `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `title = "Open"` (kept current with the selected tab title for accessibility and automation `windows`). `tabbingMode = .disallowed`, `isReleasedWhenClosed = false`, `isRestorable = false`, `isMovableByWindowBackground = false` (drag comes from the sidebar background and the empty toolbar area only; add `mouseDownCanMoveWindow` views there, never over rows or the page).
- Do not use a borderless window for standard windows. Arc keeps system traffic lights and the system window corner (continuous, about 16 pt, `WindowMetrics.cornerRadius`). The system draws the traffic lights: 12 pt circles centered at x 20 / 43 / 66, y 24 (16 pt button frames at x 12 / 35 / 58, y 16; `docs/design.md` §2.2, §16). Keep the system buttons for every behavior (actions, Option-click, the tiling menu, full screen, AX). Their rest look is Arc's dimmed one: the buttons are transparent at rest and `DimmedTrafficLightsView` draws the dimmed circles under them; the pointer over the group shows the system buttons (`docs/design.md` §23).
- Minimum standard window size: 640 × 480 (keeps the M1 floor). Default frame: the persisted frame, else 1280 × 800 at (100, 100) from `BrowserWindowState` defaults.
- `ThemeBackgroundView` fills the content view. It draws the Space theme behind both the sidebar and the web panel (`docs/design.md` §3). Assign it as `sidebar.themeBackground`. On Space switch the pager cross-fades it; do not rebuild the field per resize tick — coalesce through the existing display-link path (design.md §14 item 5).
- The window becomes key/main normally. `context.isWindowActive` follows `NSWindow.didBecomeKey / didResignKey` (and main equivalents) so inactive glyph tones and the lighter theme underlay draw (`docs/design.md` §5.3).

### 3.2 Layout (flipped root, top-left origin; `W` = window width, `H` = height, `S` = sidebar width)

| View | Frame | Source |
|---|---|---|
| `ThemeBackgroundView` | `[0, 0, W, H]` | design.md §5.1 |
| `SidebarView` anchored | `[0, 0, S, H]` | `BrowserWindowState.sidebarWidth` |
| `WebContentContainer` | `PanelMetrics.frame(windowSize:sidebarWidth:sidebarHidden:)` = `[S, 10, W − S − 10, H − 20]`; hidden sidebar: `[10, 10, W − 20, H − 20]` | `PanelMetrics` |
| Pane clip inside container | radius 6 continuous, shadow black 0.25, radius 3, offset 1 pt down; empty panel fill white ≈ 10 % over the gradient | `PanelMetrics`, `WebPanelChromeLayer` |
| Hover-reveal card | 5 pt from window edges, radius 12, 1 pt stroke `SidebarColors.border` (white ≈ 0.30) on all four sides; **translucent** fill over the blurred page (§3.3) | `WindowMetrics.revealCard*`; `docs/design.md` §2.2; S2 05/0014 (stroke on four sides, translucency) |
| Find bar | top-right of the container, 260 × 24, 8 pt from the container's top-right (port the M1 placement into the container's coordinate space) | §4.9 |
| Toast | top-right of the web panel, 8 pt from its top and 10 pt from its right edge; 42 pt tall (46 with a button) | `docs/plans/page-platform.md` §4.1 (replaces the bottom-center 280 × 34 toast) |

Layout runs in `layoutContent()` on resize, sidebar width change, sidebar mode change, Space switch, and fullscreen change. During a live sidebar drag, update frames per tick but do not rebuild the theme field and do not write the model (D4).

### 3.3 Sidebar resize, hide, and hover-reveal

**Floor (sidebar lane A1, 2026-10-27):** the measured 164 pt. Below 219 pt the toolbar is compact (Back, Forward, "More options"; `CompactToolbarMetrics`), so at 164 Back starts at x 74, where the zoom button ends. `BrowserWindowState.minimumSidebarWidth` (164) owns the shared model/live floor. The interim 218 pt floor of PR #122 review r1 is gone.

Owner of the window parts below (lead, 2026-10-26): the window-chrome follow-up of PR #104 builds the width limits, drag-to-hide, double-click reset, Cmd+S motion, card motion and material, and the Space-switch spring, and edits the matching `docs/design.md` §2.4 rows. The sidebar plan's lane A1 adds only the first-hide hint trigger and the compact toolbar (`docs/plans/sidebar-completion.md` §3.12, §3.16).

Part A implementation (window-chrome follow-up): width/drag/reset, motion tokens, and dark minimize/zoom rings are implemented. The `window` suite includes the real-event flows; `--window-chrome-only` runs just those flows and the session-2 pixel comparisons. Part B (card material and inactive-window darkening) stays deferred until the lead releases it after theme Step 9. No theme-file change is part of Part A.

Width (S2 06; AX width of the sidebar scroll area, `docs/re/interaction-states.md` §20.1):

| Event | Result | Mark, evidence |
|---|---|---|
| Drag the handle (the 4 pt strip at the sidebar's right edge, plus the container's left edge cursor `NSCursor.resizeLeftRight`) | `S` follows the pointer live, clamped to **164…500** pt. No model write per tick. | measured: slow drag 207, 197, 187, 167, **164** (stops; pointer at x ≈ 161), S2 06/0025–0029; right 357, 407, 482, **500** (stops), S2 06/0069–0072 |
| Pointer left of the 164 pt floor while the button is down | `S` stays at 164 until the pointer passes the hide point `WindowMetrics.sidebarDragHidePoint` = 82 pt (window x; half the minimum). Then the sidebar hides while the button is still down, with the Cmd+S hide motion (below), and the web panel takes the window (`sidebarMode = .hidden`). Pointer back at x ≥ 82 before release: it shows again at 164 with the show motion. | hide while pressed measured (S2 06/0035; notes 10:12:34: between pointer x 85 and 65). `sidebarDragHidePoint` 82 is a **guess** inside that measured 65–85 band (lead ruling 2026-10-26: one named token); the show-again rule is a guess |
| Release while hidden | Stays hidden. `window.sidebarWidth` = the width at drag start (not 164). Send `.sidebarHiddenByGesture` once (sidebar plan §3.12). The hover-reveal card is armed as for any hide; its toggle button's AX label is "Lock sidebar". | measured (S2 06/0053: the card's scroll area is offscreen at AX x −238, its URL field at x −218, and a "Lock sidebar" button is present) |
| Cmd+S after a drag-hide | Shows the sidebar at the width from before the drag. | measured: 228, not 164 (S2 06/0066) |
| Release while visible | Write `window.sidebarWidth = Double(S)` once and `scheduleSave()`. | existing rule |
| Double-click on the handle | `S = 228` (`defaultSidebarWidth`) from any width; write the model once. One layout, no animation. | measured from 364 and from 500 (S2 06/0009, 0088); no animation guess (frames 1.2–1.6 s apart) |
| `S` below the compact toolbar width | The sidebar toolbar shows only Back, Forward, and "More options" (sidebar plan §3.16). | measured at 207 and below (S2 06/0025–0029) |

Motion (video V, `docs/re/interaction-states.md` §20.12; tokens in `OpenDesign/Motion.swift`, rows in `docs/design.md` §2.4):

| Motion | Token and value | Evidence |
|---|---|---|
| Cmd+S hide (`toggle-sidebar`) | Starts with the key. The web panel's left edge moves 228 → 10 and the sidebar slides out in ≈ 0.10 s: `Motion.sidebarToggle` = spring, response 0.10 s, damping 0.95 (code today: response 0.30 s, damping 1.0; the old plan text said 0.22 s). `sidebarToggle` is for Cmd+S and the drag-hide only; the hover-reveal card no longer uses it (next rows). Animate the container frame and the sidebar layer transform; no per-tick layout of the rows. | V 16.26, 20.61, 24.93 s: e.g. 228, 218, 82, 27, 13, 10 in 0.108 s; fits spring R 0.09–0.105 s, ζ 0.9–1.0 |
| Cmd+S show | Starts with the key, like the hide (no delay; Open decision, §9 Q11). 10 → 228 in ≈ 0.10 s, no overshoot, same spring. For reference only: Arc starts its show 0.28–0.30 s after the key in 3 of 3 events (cause not known); Open does not copy that latency. | V 18.76, 23.08, 32.41 s (Arc's delay); Q11 |
| Hover-reveal card in | The card slides in from the left edge: new token `Motion.revealCardIn` = spring, response 0.164 s, **damping 0.81**. With `Motion.springProgress` (ω = 2π / response) this crosses the rest position at 0.112 s, peaks 2.9 pt past it at 0.140 s, and settles within 0.5 pt by 0.21 s. Transform of the card layer, its shadow, and the traffic lights only (existing rule). `BrowserWindowController.slideCard` (code: `Motion.sidebarToggle`) switches to `revealCardIn` for the slide in and `revealCardOut` for the slide out. | Measured (V 26.63 s): right edge 10 → peak 235–236 at ≈ 0.135 s, rest 233, so the overshoot is ≈ 3 pt on a 223 pt travel. Fit method: the response stays at PR #104's 0.164 s (its time fit); the damping comes from the closed-form peak overshoot of a damped spring, OS = exp(−πζ / √(1 − ζ²)), with OS = 3 / 223, which gives ζ = 0.808 → 0.81. Check by simulation of `Motion.springProgress`: ζ 0.86 gives 1.1 pt (too little), 0.80 gives 3.4 pt, 0.81 gives 2.9 pt; the 0.140 s peak time matches the measured ≈ 0.135 s within one video frame |
| Hover-reveal card out | New token `Motion.revealCardOut` = 0.105 s ease-in-out, no overshoot. | V 29.50 s (233 → 10) |
| Space switch slide | `Motion.spaceSwitch` = critically damped spring, response **0.20 s** (was 0.30); settled ≈ 0.27 s. The web content swaps in the first frame (existing rule). The theme cross-fade stays 0.21 s linear (not re-measured: both test Spaces had the same theme). | V 35.05, 43.63 s: remaining offset 103, 60, 33, 18, 12, 6, 4, 2, 1, 0 pt at ≈ 25 ms steps (RMS 0.003) |
| Reduce Motion | `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`: set frames with no animation. | existing rule |

Hover-reveal card:

- Reveal: while `sidebarMode == .hidden`, a pointer that dwells 0.15 s in a reveal zone reveals the sidebar as a card (zones and timing decoded from Arc, `docs/design.md` §16; this replaced the first guess of the left 8 pt for 0.35 s). Reuse the same `SidebarView` instance: set `presentation = .floatingCard`, frame `[5, 5, S, H − 10]`, keep it above the container. The pointer leaving the card and every zone for 0.15 s, any command-bar open, or any tab selection restores `presentation = .anchored` and hides it (frame off, `isHidden = true`). One sidebar view per window, always; two instances would split observation state.
- Material: the card is **translucent**. It shows the page under it, blurred: fill ≈ 0.885 × the theme tint + 0.115 × the page under the card blurred with σ ≈ 25 px (PR #104 fit, RMS 1.06 levels). Over a white page the card equals the anchored sidebar within ΔE00 0.6 from top to bottom (`#27253A` vs `#272538` at y 400); over a dark page (`#101418`) it is about 26 levels darker (`#0F0B21` at y 500), with a lighter patch over lighter page content. This also explains session 1's "darker bottom" (blue page content under F0129). Evidence: S2 05/0014 vs 0001, 05/0028, 0033; F0128 vs F0129. The #104 owner picks the mechanism (guess: an `NSVisualEffectView` with `.withinWindow` blending under the theme layer drawn at 0.885) and proves the formula within ΔE00 2 on S2 05/0014 and 05/0028. The blur runs only while the card shows; a hidden card holds no live backdrop (idle CPU budget). The card keeps its stroke on all four sides and its shadow. In macOS Light the card reads `#E2E1F9` at the top and `#EFE7F4` at the bottom over a white page, with a faint lighter stroke (`#EEECFA`) (S2 20/0040).
- Full screen and Peek: hover-reveal stays available in full screen. While a Peek is open, hover-reveal does not trigger (the scrim owns the pointer).

### 3.4 WebContentContainer (right side)

Use `OpenFeatures.WebContentContainer` as specified in M4 §5. The shell's duties:

- `show(ids:focusedID:orientation:fractions:)` on every selection, split, or Space change. Single-pane mode shows one tab or its placeholder.
- Placeholder and sleeping states: `PaneSlotView` shows `PlaceholderContentView` when the tab has no live host or `tab.live.sleepPhase != .live / .frozen` (read the exact condition in the library source). The App never creates an `OEWebContent` for a placeholder tab. A sleeping tab keeps its model row, favicon, and title; its host is created only on selection (wake, §4.7).
- Host cache: the container keeps at most `WebContentContainer.maxCachedHiddenHosts` (8) hidden hosts, LRU. Hidden hosts get `view.isHidden = true`, which throttles them in Chromium (`docs/engine-api.md`). Closing a tab calls `host.close()` and drops the cache entry at once.
- Split dividers, focus ring, pane chrome, and the split drop overlay are library behavior (M4 §3). The App only supplies `onDrop`, `onPaneClose`, `onFractionsCommitted` (→ `model.setSplitFractions`), and `onLinkClicked` (→ Peek policy first, then Opt+Cmd-click → Little Open, M4 §4.2 and §5).
- Moving a live page's view between windows (Little Open → Space, Peek expand) is expected to work but is untested in stock CEF (`docs/engine-api.md`). Where the container reparents a host view into another window, verify no reload happens; if a reload happens, log it and keep the tab's scroll restore to the sleep envelope path (M4 assumption A2 fallback).

### 3.5 Command bar overlay

- One `CommandBarController` per standard window, created lazily on first Cmd+T / Cmd+L (launch budget, §5). It presents as a child window/panel over the root, per the `m3/commandbar-ui` implementation. Do not reimplement its views.
- Open paths: Cmd+T (`new-tab`) in `.newTab` mode; Cmd+L (`open-command-bar`) in `.editCurrentURL` mode with the current URL filled and selected; sidebar `.openCommandBar(source)` intents map `.urlField → .editCurrentURL`, `.newTabRow / .plusButton → .newTab`. While the bar is open in `.newTab` mode, set `context.isNewTabCommandBarOpen = true`; clear it on any dismiss (the delegate's `didChangePresentation`).
- Esc closes the bar (one press, typed text or not). A second Esc reaches the App's `exit-modal` command. Click outside dismisses with `.clickOutside`. The bar never becomes the main window; focus returns to the page or the sidebar field that opened it.
- Backdrop: pass the `CommandBarBackdrop` from the library (dominant color under the panel; image snapshot when the library asks for it). Take the snapshot through the automation-safe path (`WindowSnapshot`), never `CGWindowListCreateImage` on other apps' windows.

### 3.6 Peek overlay

`PeekController` + `PeekOverlayView` per M4 §4: overlay fills the window content view (the sidebar dims too), scrim = theme dark background at alpha 0.70 (black 0.55 without a dark palette), panel 80 % width, three 33 pt buttons outside the panel's right edge. Esc, scrim click, and the close button dismiss the top Peek and show the "Peek closed" undo toast for 5 s. The App wires `onLinkClicked`, Cmd+O (`open-in-current-space`) while a Peek is topmost, and Back/Forward routing to the top Peek host (M4 §4.6). Peek state is transient: never in the model, never in the snapshot.

### 3.7 Toasts

Superseded by `docs/plans/page-platform.md` §4.1: one `ToastCenter` per window with Arc's look (Space-tinted, top-right of the web panel, overlap stacking, 3 s lifetime, 6 s with a button). Until that plan's Step 1 lands, reuse the toast in `OpenFeatures.BrowserWindowController` (black 0.85, radius 8, optional Undo button). Sources: Peek close undo, "tab closed" undo where Arc shows one (verify against captures; if unverified, show only the Peek toast in v1 and say so in the PR), Boost apply feedback (§4.5), and sleep discard failure ("a tab could not sleep; it stays open"). One toast at a time; a new toast replaces the old and cancels its undo. Toast lifetime 5 s. Toasts never steal focus.

### 3.8 Multiple windows, full screen, and persistence

- Windows: `AppDelegate.windowControllers` holds one controller per standard `BrowserWindowState` (`style == .standard`). Cmd+N (`new-window`) appends a `BrowserWindowState(focusedSpaceID:)` through the model (`BrowserModel` window commands; if no create-window command exists, add one in `OpenModel` in Step B following the existing command style: one undo step, no `TreeChange` for window create — windows are not sidebar structure; check `docs/model.md` first). Each window has its own `SidebarContext`, `OEBrowser` set, command bar, and Peek stack. The model, stores, and `SuggestEngine` are shared.
- Closing a standard window removes its `BrowserWindowState` on close (the scripting hook requires this, `docs/scripting.md` H1) unless it is the last window; closing the last window keeps its state so relaunch restores it. Quit saves all window states.
- Full screen: `toggleFullScreen` (Cmd+Ctrl+F, `toggle-full-screen`). In full screen the sidebar stays anchored unless the user hid it; the container uses the same `PanelMetrics` insets. HTML fullscreen is separate: `webContent(_:didRequestFullscreen:)` hides the sidebar and sets the container inset to 0 until exit (port `isPageFullscreen` from the M1 file). Automation `policy fullscreen=record` keeps the window size (exists).
- Persistence (StorableWindows-like): frame, `sidebarWidth`, `sidebarMode`, `focusedSpaceID`, and `selectedNodeBySpace` live in `BrowserWindowState` and save through the debounced snapshot (about 1 s) plus `saveNow` on quit. Write frame on `windowDidMove` / `windowDidEndLiveResize` only (port `saveWindowState()`). On launch, restore every standard window's frame and selection before the engine is ready (§5). Little Open windows are not in the snapshot and have no autosave frame: each opens at the routing plan's fixed first frame (§9.3 as amended 2026-10-26: 490 × 329 at the screen's top-right, then 1185 × 832 after load).
- Reopen: `applicationShouldHandleReopen` shows the front controller (exists). `frontWindowController` = key window's controller, else the first.


## 4. Wiring: each library to the engine and the model

### 4.1 SidebarDelegate: intents → model commands + engine

`OpenFeatures.BrowserWindowController` already conforms to `SidebarDelegate`. Its handler first offers each intent to `ModelSidebarActions` (model-only intents), then handles the App intents below. Return the model's `Bool`. A `false` means refused: no model change, no engine call, no save.

Rules that apply to every row:

- Selection (`select`, `selectFavorite`, `switchSpace`): call the model command without undo (`withoutUndo` pattern from the M1 file), then `container.show` for the new selection, then `TabStripMirror` sync, then sleep visibility hooks (§4.7), then `scheduleSave()`. Create web content lazily: only the newly selected tab (and every pane of a selected split) gets a host. A background tab gets no host.
- `close` on a Today tab archives it (`model.closeTab`); the tree change closes its host. `close` on a pinned tab or favorite unloads it instead (keep the entry, `host.close()`, `tab.live.hasWebContent = false`). `unloadTab` is that unload path for pinned rows. This matches the M1 `closeTab` behavior; keep it.
- Engine state mirrors into `tab.live` only through `EngineWebContentHost` callbacks (§4.13). The sidebar reads `tab.live` and `SidebarContext.faviconProvider`; it never talks to the engine.

| Intent group | App handling (after `ModelSidebarActions`) |
|---|---|
| `toggleSidebar` | §3.3 toggle. |
| `goBack / goForward / reload / stopLoading` | Focused host (split-aware: the focused pane; Peek-aware: the top Peek host first, M4 §4.6). No host → return `false`. |
| `openCommandBar(source)` | §3.5. Set `isNewTabCommandBarOpen` for `.newTabRow / .plusButton`. |
| `copyCurrentURL` | Pasteboard: plain URL string. No engine call. |
| `showSiteControls` | §4.9 Site Control Center popover for the current tab's origin. Until that UI lands, show the permissions sheet from §4.9. Name the gap in the PR. |
| `showLibrary` | Open the Library window placeholder (same shared-window pattern as §4.11) until `OpenSettings` Library lands. |
| `newSpace / manageSpaces / changeSpaceIcon / renameSpace / editSpaceTheme / setSpaceProfile / newProfile / shareSpace / exportSpaceIntoFolder / deleteSpace / moveSpace` | Model commands where they exist (`docs/model.md`). `setSpaceProfile` triggers §4.8 profile switch for that Space's tabs (destroy hosts, lazy recreate). Theme and icon editors: open the placeholder sheet until the editors land; the model value must still update through the existing commands so import and CLI paths work. Share uses `NSSharingServicePicker` with the tab/space URL. |
| `toggleMute` | `host.isMuted` toggle + `model.setMuted` (exists). |
| `resetToPinnedURL / replacePinnedURL / editPinnedURL` | Model commands; `editPinnedURL` opens the command bar in `.editCurrentURL` mode seeded with the pinned URL and saves through the model on confirm. |
| `share / copyLink / copyAllLinks` | Pasteboard (plain + Markdown forms) or `NSSharingServicePicker` anchored to the row view (`sidebar.rowFrame`). |
| `customizePage` | Boost editor entry for the tab's host (§4.5). Until the editor lands, enter Zap pick mode if a Boost exists for the host, else create an empty Boost and enter Zap. |
| `openInSplitView / addSplitView / separateSplit / newSplitView` | `model.makeSplit / addPane / unsplit` (M4 §2.2 commands), then `container.show`. Refuse at 4 panes with a beep and no change. |
| `openURL(url, in:, index:)` (external drop) | `model.newTab` in the drop parent, select it, lazy host. |
| All other intents | `ModelSidebarActions` owns them. If it returns `false` and no row above applies, return `false`. Never add a silent no-op. |

Automation: extend `tabs` to include `sleepPhase` and `hasWebContent` per tab (from `tab.live`). The `sidebar` suite (§6) drives selection, pin, close, and Space switch through `select`, `pin`, `space`, and `key route=app` events only.

### 4.2 CommandBar: intents → navigation, switch, actions

- One `SuggestEngine` per app (`AppStores`), built with the focused window's profile history store. Rebuild it when the focused profile changes; cancel the old query stream. Feed it `CommandRegistry.makeSuggestRegistry()` actions (`docs/commands.md`). History comes from that profile's `HistoryStore`; never mix profiles.
- One `CommandBarController` per window. `AppCommandBarDelegate` implements `CommandBarDelegate`:

| `CommandBarIntent` | App behavior |
|---|---|
| `.open(url, .newTab, mods)` | `model.newTab(in: focusedSpace, url:, at: 0)`, select it, lazy host, focus the page. With `.command` in mods, open in the background (create the host, do not select). Record the history visit as typed. |
| `.open(url, .currentTab, mods)` | `host.load(url)` on the current tab; set `tab.url` through the engine commit, not by hand. |
| `.search(query, url, siteSearchID, destination, mods)` | Same as `.open` with `url`. Pass `typed: true` to history. `siteSearchID` is log-only in v1. |
| `.switchToTab(id, spaceID)` | If `spaceID` names another Space, `model.focusSpace` first. Then select the node (expand its folder chain through the model so the row is visible), `sidebar.reveal(nodeID:)`, focus the page. |
| `.runAction(id, spaceID)` | `CommandDispatcher.performCommand(id, payload: spaceID)`. Never reimplement an action in the delegate. |
| `.copy(text)` | Pasteboard. Show the toast "Copied". |
| `.showHelp` | #85 (merged) handles it in `App/CommandBar/AppCommandBarDelegate.swift` by opening `AppCommand.helpURL` in a new tab. `docs/plans/commandbar-completion.md` Step 0 removes this case, because Arc's (i) shows an inline privacy footer inside the bar (CC-42) and the bar sends no intent for it. |
| `.openSearchSettings(profileID)` | New with commandbar-completion Step 0 (footer "Search Settings…"): the bar closes and the App runs the existing `search-settings` command (#85: Settings on the General pane). Step 9 of that plan points it at the Profile's search engine section. |
| `.dismissed(reason)` | Clear `isNewTabCommandBarOpen` (also done in `didChangePresentation`). Return focus to the page. The sidebar URL field is not a text editor in the real sidebar, so it never takes focus back. |

- `CommandBarRequest` fields come from the opening window: `mode`, focused `profileID / spaceID`, `currentTabID / currentTabURL / currentTabTitle`, `allowsRemoteSuggestions` from the profile's `searchSuggestEnabled`, `searchEngineID` from the profile settings.
- Performance: first results ≤ 50 ms (`docs/architecture.md`). The controller is created lazily; the `SuggestEngine` index build happens off the open path (build at first profile load, on a background queue, before first Cmd+T in the common case).

### 4.3 Menus, CommandDispatcher, KeyboardRouter, GlobalHotkey

- Menus: delete the hand-built `App/MainMenu.swift` content. `NSApp.mainMenu = MenuBuilder.buildMainMenu(dispatcher:spaces:tabs:overrides:)`. Rebuild on: Space list change, tab list change (dynamic Spaces/Tabs menus), and key-binding override change. The dispatcher is the key window's `BrowserWindowController`; when no window exists, `AppDelegate` is the fallback dispatcher for `new-window`, `settings`, `quit-open`, and Little Open commands.
- `CommandDispatcher.performCommand(_:payload:)`: `OpenFeatures.BrowserWindowController` already handles sidebar, split, and Peek commands and forwards the rest. The App adds one extension that handles exactly these engine/app commands; every other id returns without action only if `OpenCommands` marks it reserved — log any other unknown id in Debug.

| Command ids (from `docs/commands.md`; never rename) | Handler |
|---|---|
| `new-tab`, `open-command-bar` | §3.5 / §4.2 |
| `new-window`, `new-incognito-window`, `blank-window`, `close-window` | §3.8. Incognito: ephemeral context (§4.8) until profiles D-P8 UI lands; if not ready, disable with `isCommandEnabled = false` and name it. |
| `archive-tab`, `restore-last-closed-tab`, `pin-unpin-tab`, `duplicate-tab`, `rename-tab`, `reset-tab`, `clear-unpinned-tabs`, `next-tab`, `previous-tab`, `cycle-tab-forward/backward`, `tab-switcher-forward/backward`, `go-to-tab-1…9`, `go-to-space-1…9`, `next-space`, `previous-space`, `new-space`, `new-folder` | Model commands + selection sync (port the M1 `closeTab`, `restoreLastClosedTab`, `cycleTab`, `focus(space:)` logic). |
| `reload`, `force-reload`, `stop-loading`, `go-back`, `go-forward`, `zoom-in/out`, `zoom-actual-size`, `find`, `find-next`, `find-previous`, `print`, `save-page-as`, `share-page`, `copy-url`, `copy-url-markdown`, `developer-tools`, `javascript-console`, `view-source`, `inspect-elements` | Focused host methods (`OEWebContent` through `WebContentHost` where the protocol covers it; extend `OpenWeb.WebContent` only if a method is missing for all consumers, in the `OpenWeb` owner's PR). `save-page-as` uses `OEDownload` with an `NSSavePanel`. |
| `toggle-sidebar`, `toggle-full-screen`, `add-split-view`, `close-split-pane`, `focus-split-pane-1…4`, `next/previous-split-pane`, `reveal-current-tab`, `expand/collapse-pinned-section` | Window + container + model. |
| `settings` | §4.11 placeholder. |
| `view-downloads`, `view-library`, `view-boosts`, `manage-extensions`, `add-extension` | Downloads popover/sheet (§4.9), Library placeholder, Boosts list placeholder, `chrome://extensions` Chrome-style tab (stock-CEF path that exists today) until P3. |
| `new-little-open-window`, `open-in-current-space`, `little-open-global`, `peek-email` | §4.4. `peek-email` stays disabled in v1 (M4 non-goal). |
| `set-default-browser`, `import-from-browser`, `check-for-updates`, `about-open`, Help ids | §4.4 default browser; Import from Arc entry (existing `OpenImport` flow); updates/about use the standard panels. |

- `isCommandEnabled(_:enabledKey:)`: map each enabled key in `docs/commands.md` (`hasCurrentTab`, `canGoBack`, …) to live host/model state. `canGoBack / canGoForward` read the focused host. Never cache them; validation runs per menu open.
- Keyboard: two layers, both required.
  1. `OEApplication.keyEquivalentHandler` (exists in `main.swift`): replace `MainMenu.performReservedShortcut` with a call that builds a `KeyboardShortcut` from the event and asks `KeyboardRouter.route(shortcut:context:overrides:)`. Context: app active, command bar open?, sidebar focused?, text focused?, web content focused? (from `NSApp.keyWindow` first responder). On `.browserCommand(id)`, perform it and return `true`. This is the layer that makes app shortcuts work while a page has focus and the page calls `preventDefault()` (engine-spike shell check).
  2. `OEWebContentDelegate.webContent(_:handleUnconsumedKeyEvent:)`: route the same way for keys the page did not consume, then fall through to the main menu. `handleKeyEventBeforePage` stays for the router's `site-then-browser` double-press rule (0.4 s window, `docs/commands.md` rule 5); keep the router instance per window so its press history survives.
  - `KeyboardRouter` lives in `OpenCommands`; one instance per window (the OpenFeatures controller already holds one — reuse it, do not add a second in the App).
  - Key-binding overrides load from `KeyBindingStore` at launch (lazy, §5) and rebuild menus on change.
- GlobalHotkey: one `GlobalHotkeyService` in `AppDelegate`. Register `little-open-global` (Cmd+Opt+N) only while `open.links.littleOpenHotkeyEnabled` is on (fallback `true`, `docs/routing.md`). Re-register on setting change. The action opens or focuses a blank Little Open (§4.4). Unregister on quit. Carbon registration failure is logged, never fatal.

### 4.4 OpenRouting Phase B: intake, default browser, Little Open

Implement routing plan Steps 5–7 exactly (`docs/plans/routing-little-open.md` §8–§9, §13). This section fixes only the shell integration points.

- Registration: `App/Info.plist` gains the `CFBundleURLTypes` http/https handler entry (§8.2). Bundle id is `io.github.sergeserb2.open` (lead decision Q4).
- Intake funnel: Apple Events (`kInternetEventClass`) and `application(_:open:)` both call `ExternalLinkIntake.receive(urls:source:)` (§8.3, §8.5). Source from `SourceAppResolver` (sender PID → bundle id, §8.6). Cold launch: URLs that arrive before the first window exists are queued in the intake and flushed after `showWindowsIfNeeded` (§5). Never drop a cold-launch URL.
- Decision: build a `RoutingSnapshot` from live model values on the main actor. Windows in actual front-to-back AppKit order (not model order). Evaluate, append to `RoutingDecisionLog`, execute (§8.7):
  - `.space` → focus that Space in the front standard window (create a standard window if none), `model.newTab(at: 0)`, select, lazy host.
  - `.littleOpen` → `LittleOpenCoordinator` opens a session with the profile hint (§9.1–§9.3).
  - Rejected scheme → log only.
- Default browser: `DefaultBrowserService` (§8.4) wraps `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`. Verify the macOS 26 SDK shape first (routing plan Q1); use what the SDK declares. `set-default-browser` performs it; Settings placeholder shows the current state read-only. Never prompt at launch.
- Little Open window: `LittleOpenWindowController` (OpenFeatures) per the routing plan §9.3 as amended 2026-10-26: a 490 × 329 command-bar first frame at the screen's top-right, 1185 × 832 after load with the top-right fixed, Arc's 47 pt title bar, a full-bleed page, a new window per ⌥⌘N, no autosave frame (routing Step 6a). Entry points (§9.5): global hotkey, `new-little-open-window`, Opt+Cmd-click inside a page (only if the engine's modifier-aware navigation hook exists — check `OEWebContentDelegate`; if absent, ship without it and record the gap, M4 A3), external intake, and AppleScript (§4.10, may return 1011 until this lands).
- "Move Little Open or Peek to Space…" (`open-in-current-space`, Cmd+O): one App-level dispatcher checks the topmost surface: Peek open → expand the Peek into the chosen Space's Today top; Little Open key window → move its session into the chosen Space (create the tab, reparent or reload per §3.4, close the session); otherwise disabled.
- Sweeper: `LittleOpenCoordinator` auto-archive timer per §9.6, interval from the current profile's `littleOpenAutoArchiveAfter` (fresh default six hours). Manual close does not archive (Q7).
- No main window: Little Open works alone. It never creates a standard window implicitly (§9.7 table is normative).

### 4.5 Boosts: InjectionPlan → engine document-start injection

- Stores: `AppStores` keeps one `BoostStore` per loaded profile, created with `BoostStore(root:profileID:fileURL:)` where `fileURL = ProfileDirectories.boostsFileURL(for: profile)`. Load once before any mutation. `BoostMatcher` rebuilds on every store change.
- Apply path (`BoostEngineAdapter`): on each main-frame commit for a tab (from `EngineWebContentHost.onURLChange` after commit, §4.13), compute `BoostInjectionPlanner.plan(url:profileID:matcher:boostsGloballyEnabled:context:)` (`.incognito` for ephemeral contexts). Translate the `InjectionPlan` into `WebProfile` user scripts on that profile's `EngineWebProfile`:
  - Managed applier: one user script, id `open.boosts.applier.<planID>`, source = `BoostResources.applierJS` + the plan payload call, `.documentStart`, match patterns from the plan, main frame only. Replace the previous plan's scripts for that tab's profile atomically (remove old ids, add new) so SPA navigations never double-apply (check A5 in `docs/boosts.md`).
  - User-authored Boost JS: separate user scripts, main world, document start, per the plan. CSS-only components ride the applier's stylesheet path, never a raw `<style>` script.
  - On navigation away or plan `null`: remove that tab's scripts and send the clear command through the same channel.
- Isolation gap (D8): stock CEF injects user scripts in the main world. The applier and picker must run in an isolated world (patch P7). Until P7, install in the main world, add `// Blocked on P7: isolated world` at the install site, and state in the PR that overlay secrecy is not yet proven. Do not forward capabilities through page-visible DOM or globals as a substitute.
- Zap: `customizePage` (§4.1) calls `BoostPickerCoordinator.enterZap(boostID:for:)` with the engine document/frame identity as `pageID`. The engine adapter delivers outbound picker commands into the injection world and routes inbound messages through `BridgeDecode` after checking envelope version 1. Invalidate the session on navigation, frame destruction, and transport loss. The picker needs the same isolated world; before P7, Zap stays behind the same blocked marker and the menu item is disabled. Never ship a main-world picker as secure.
- Feedback: toast on apply/clear failure only. Success is silent (Arc behavior; verify against captures, else stay silent).

### 4.6 AdBlockStore → engine request-block hook

- One `AdBlockStore` per app (`AppStores`), opened with the bundled defaults directory from app Resources (`docs/adblock-lists.md` packaging step; if the bundle seed is absent, open with no seed and log — never block launch on it). `openProfile(_:scheduleUpdates:)` lazily per profile, mirroring engine context creation.
- Filter path (`AdBlockEngineAdapter`): the store owns list generations on disk. The App does not parse filter rules in v1. Until the fork ad-block engine reads `current.json` itself (adblock-fork plan), the App installs a bridge filter:
  - Build an immutable `Sendable` snapshot from the profile's `siteSnapshot(for:)` plus exclusions: enabled flag, excluded domains, and the compiled block data the store exposes. If the store exposes no rule-level API, the bridge blocks nothing and only exclusions apply — state this limit in the PR. Do not write a filter-rule parser in the App target; rule matching belongs to `OpenAdBlock` or the fork engine. If a rule API is needed, add it to `OpenAdBlock` in that library's own step with `openkit adblock` checks.
  - Install with `EngineWebProfile.setRequestFilter` on the profile's context. The closure captures only the snapshot and an atomic counter. Update = build a new snapshot, swap, reinstall. Per-site exclusion changes (`setExcluded`) rebuild that profile's snapshot at once.
  - Today's stock-CEF hook already passes the automation `filter / filter-stats` commands; keep those working by routing them to the same adapter (block substrings in Debug automation only).
- Site Control shows the per-site excluded state and toggles it (§4.9). Settings placeholder lists enabled lists read-only until `OpenSettings` lands.

### 4.7 OpenSleep S6 adapter on today's engine API

- One `SleepController` per app (`AppSleepCoordinator`), built after the model loads with: `model`, `EngineSleepAdapter` (`SleepEngine`), a routing `SleepHistoryStoring`, `AppVisibilityProvider` (OpenFeatures, M4 §7) fed by all window controllers + Peek + Little Open + PiP tab ids, and `chromiumTag` from `OEEngine.shared.chromiumVersion`. The controller takes one store (`SleepController(model:engine:store:visibility:chromiumTag:)` — verify in `SleepController.swift`). The routing store owns one `SleepStore` per profile (`ProfileDirectories.sleepFileURL(for:)`) and dispatches each call by the tab's owning profile. A tab with no known profile uses the default profile's store.
- `EngineSleepAdapter` over `OEWebContent` (one host per tab, shared with the container's factory cache — never a second page object per tab):

| `SleepEngine` call | Today (stock CEF) | Waits for |
|---|---|---|
| `createContent(tabID:url:history:)` | Create the host through the factory; load `url`. Ignore `history` beyond the URL. | Real history restore: P-MEM-04 envelope apply. |
| `destroyContent` | `host.close()`, drop cache entries. | — |
| `setVisible` | `view.isHidden` toggle (Chromium throttles hidden pages). | True visibility freeze: P-MEM-02. |
| `freeze` | Hide the view; return `true` only if the host exists. | Renderer freeze: P-MEM-02/03. |
| `discard` | Capture what is capturable (title, URL, favicon), then `host.close()`; return `true`. The tab wakes by recreate + load. | OPNH capture/restore: P-MEM-04; discard API: P-MEM-03. |
| `wasDiscarded` | Adapter-kept set of discarded tab ids. | Engine flag. |
| `captureHistory` | Return `nil` (no envelope today). The controller keeps the tab frozen on capture failure per policy — verify this path in the sleep suite; if `nil` blocks discard forever, return a minimal envelope with the current URL/title and no page state, and say so in the PR. | P-MEM-04. |
| `hasUnloadHandlers` | `false`. | P-MEM-06. Discard stays blocked for unload-protected tabs only when an event later supplies the state; never guess `true`. |
| `handleCriticalPressure` | Close hidden cached hosts beyond the visible set, oldest first. | Engine pressure hook. |

- Hard event contract (`docs/sleep.md`): call `tabDidCommit` and `tabAudioChanged` for every tab event, including background tabs and events between ticks. Feed capture, PiP, download, loading, DevTools, and form state on every engine event (§4.13 callback table). Sampling alone is forbidden. Call visibility hooks right after selection, split focus, Peek open/dismiss/expand, Little Open create/close/miniaturize, and window minimize/occlusion changes. The controller's 5 s pass re-reads the snapshot; no App timer.
- Wake: selecting a sleeping/discarded tab creates its host and loads `tab.url`. `tab.live.sleepPhase` drives the placeholder (§3.4). Pinned and favorite tabs sleep like other tabs (S0 rule).
- Quit order (normative): `applicationShouldTerminate` → `await sleepController.captureAllForQuit()` → snapshot `saveNow` → Boost `saveNow` per profile → `OEEngine.shared.shutdown()`. Capture includes all live split panes. Container teardown runs after quit capture, never before (M4 §7.1).
- Sleep settings: the profile `sleepMode` picker lands with `OpenSettings`; until then the mode comes from the snapshot default (`balanced`).

### 4.8 Favicons, history, profiles

- Favicons (implemented 2026-10-28, section 1 item 12): `EngineWebContentHost` receives `OEWebContentChange.favicon`, normalizes to 64-pixel PNG, updates live state and queues a page-specific report through `StoredFaviconCache`. `FaviconStore` opens, decodes and writes off the main actor. Shared `FaviconView` reads the bounded observable cache for unloaded pins, slept/imported rows and Favorites; the Space Manager uses it too. Library archive rows already read the same store. Custom icons and images from live hosts win; unloaded rows ignore retained stale live PNGs, and misses keep the placeholder. There is no automatic fetch on a miss; import has no mapped favicon payload. A new report replaces the stored page key and redraws that row. Limits and FV checks: `docs/favicons.md`. This closes only the favicon part of Step H; history and scripting remain separate.
- History: on main-frame commit (URL change with a finished load, §4.13), call the profile's `HistoryStore.recordVisit(url:title:time:transition:typed:)`. Transition: `link` for page navigations, `typed` for command-bar/address opens (flag carried from §4.2). Reload does not add a visit. Redirect chains record the final URL once. Incognito (ephemeral) tabs record nothing. History feeds `SuggestEngine` and never the engine (CEF exposes no Chromium history service).
- Profiles: contexts lazy per D7. On `.spaceProfileChanged(spaceID:from:to:)`: destroy every host of that Space's tabs, drop their `TabStripMirror` entries, clear per-tab live state, and let selection recreate hosts under the new context on demand. Cookies, cache, and extensions follow the new context at once. Incognito windows use `OEEngine.shared.makeEphemeralContext()`, one per window, released with `releaseContext(_:completion:)` on window close; incognito tabs live in the model only as long as the window (never persisted: exclude ephemeral windows from the snapshot save — if `BrowserModel` cannot express that today, keep incognito tabs in a separate in-memory list in `AppDelegate` and say so in the PR; do not write them to `browser.json`).

### 4.9 Downloads, permissions, JS dialogs, find bar, context menus, Site Control

Port these from the M1 `BrowserWindowController.swift` (read each method) into `OpenFeatures.BrowserWindowController` engine delegate handling plus the App factory's delegate. Keep the automation policies (`dialogPolicy`, `permissionPolicy`, `contextMenuPolicy`, `fullscreenPolicy`, `downloadDirectory`, `pendingDialogs`, `events` log) working with the same semantics.

- Downloads: `OEBrowserContextDelegate.browserContext(_:decideDestinationFor:suggestedFilename:completion:)` → profile `downloadDirectory` (default `~/Downloads`) or `NSSavePanel` when `askWhereToSaveEachFile`. Progress through `downloadDidUpdate`. UI: toolbar downloads button + popover listing `OEDownload` state, speed, cancel/pause/resume. `view-downloads` (Cmd+Shift+J) opens it. Completed downloads record no history.
- Permissions: `webContent(_:decidePermissionRequest:)` → stored `permissionState(for:origin:)` first (grant/block at once). Else show the Arc-style prompt anchored to the container (origin, kind, Allow/Block, remember checkbox). Automation `permissionPolicy` short-circuits. Grant/deny/dismiss exactly once. Geolocation may surface the macOS prompt; never suppress it.
- JS dialogs: `webContent(_:runJavaScriptDialog:)` → native sheet per kind (`alert/confirm/prompt/beforeunload`). Return `true`, complete later with `complete(accepted:text:)`. An unanswered dialog is cancelled when the host closes. Automation `dialogPolicy` (`accept/dismiss/hold`) and `dialog` command keep working. `beforeunload` on tab close: completing with dismiss keeps the tab.
- Find bar: Cmd+F shows the §3.2 find bar over the container. Return/Shift+Return → `find(_:forward:caseSensitive:)`; Esc or empty text → `stopFinding(clearSelection:)` and focus back to the page. `webContent(_:didUpdateFindResult:)` updates the count label (`OEFindResult`). Find acts on the focused pane/Peek host.
- Context menus: `webContent(_:showContextMenu:)` → build a native `NSMenu` from `OEContextMenu` targets: link items (Open, Open in New Tab, Open in Peek (M4 trigger D), Copy Link, Open in Little Open), image items, selection items, spelling suggestions, plus Chromium's own items including extension items in order. Finish with `select(command:)` or `cancel()` exactly once. Automation `contextMenuPolicy = record` records items and cancels. Never show Chromium's own menu.
- Site Control Center: sidebar `showSiteControls` and the URL-field button open a popover for the current origin: permission states (camera, microphone, geolocation, notifications, … through `EngineWebProfile.permission/setPermission`), ad-block exclusion toggle (§4.6), Boost entry (§4.5), cookie/cache clear for the origin (`clearBrowsingData(origin:)`), and zoom reset. Until the designed popover lands, use an `NSPopover` with rows; do not block other steps on its visual design.

### 4.10 AppleScript hooks H1–H4

Follow `docs/scripting.md` exactly.

- H1: in `applicationDidFinishLaunching`, after the model and window registry exist, fill `ScriptHost.shared.modelProvider`, `windowStateID` (skip panels and non-browser windows), `windowForState`, `makeWindow` (incognito returns `nil` → 1010 until §4.8 incognito lands), `makeLittleTab` (`nil` → 1011 until §4.4 lands), `engineBridge`. Weak model capture. Keep providers current across model replacement. The App model observer calls `ScriptHost.shared.purgeRemovedWrappers()` on external removals.
- H2: `App/Scripting/AppScriptEngineBridge.swift` is the only file importing both `OpenScripting` and `OpenEngine`. Implement `navigate / goBack / goForward / reload / stopLoading / executeJavaScript` on the main actor. Wake sleeping content as needed. JavaScript: 10 s timeout without pumping the run loop; throw `ScriptEngineError`; convert results to text in this file. Never log script text.
- H3: add `App/Resources/Open.sdef` through Copy Bundle Resources. No package copy.
- H4: Info.plist: `NSAppleScriptEnabled = true`, `OSAScriptingDefinition = Open.sdef`, `NSAppleEventsUsageDescription = "Scripts control Open windows, spaces, and tabs."` Confirm `CFBundleName = Open` and bundle id `io.github.sergeserb2.open`.

### 4.11 Settings window entry (Cmd+, placeholder)

- `settings` command → `SettingsPlaceholder` (App file): one shared titled `NSWindow`, 684 × 650 (the measured Settings size, settings plan §1), title = selected pane name, `NSHostingController` only if a trivial SwiftUI placeholder is cheaper — default to a plain AppKit content view with the text "Settings land with OpenSettings." and a read-only list: default-browser state (§4.4), Little Open hotkey toggle (writes `open.links.littleOpenHotkeyEnabled` and re-registers the hotkey), external-links toggle. These three controls are real because later steps depend on them; every other preference stays unwired. Reuse the window; never open a second copy. Last pane id persists in `UserDefaults`.
- When `OpenSettings` lands, it replaces this file's content view. The command id, shortcut, and window identity do not change.

### 4.12 Extensions in the shell (stock CEF limits stated)

- Toolbar: the sidebar URL field row and the container top area keep the M1 extension action behavior through `EngineExtensionHost`: one button per `OEExtensionAction` (icon, badge, enabled), click → `executeExtensionAction`. The popup hosts in a floating panel at the button (`browser(_:didOpenExtensionPopup:for:)`, resize 25×25…800×600, close on second click / `window.close()` / outside click). Port `reloadExtensionBar`, popup panel, and `AuxiliaryPage` handling from the M1 file.
- `chrome.tabs` does not see Alloy tabs until P1. Popups that need the current tab (Bitwarden class) stay broken; do not work around this in the shell. Web Store install and `chrome://extensions` keep the M1 Chrome-style tab path until P3. State both limits in the Step D PR.

### 4.13 Engine event map (the single place engine state enters the model)

`EngineWebContentHost` wraps one `OEWebContent` and sets itself as its delegate. Every callback guards a `closed` flag and a generation counter (M4 A7): no callback after `close()` touches the model.

| Engine callback | Model / App effect |
|---|---|
| `didChange` `.URL` | On commit: `tab.url`, history visit (§4.8), Boost plan (§4.5), sleep `tabDidCommit`, `scheduleSave`. Ignore `about:blank`. |
| `didChange` `.title` | `tab.title` when non-empty; window title if selected; `scheduleSave`. |
| `didChange` `.favicon` | `tab.live.faviconPNG`; async `FaviconStore.ingest` (§4.8). |
| `didChange` `.loading / .progress` | `tab.live.isLoading / progress`; sleep loading grace input. |
| `didChange` `.navigationHistory` | `tab.live.canGoBack / canGoForward`. |
| `didChange` `.audio` | `tab.live.isAudible`; sleep `tabAudioChanged` on every transition. |
| `didChange` `.crash` | `tab.live.isCrashed = crashState != .none`; placeholder offers reload. |
| `didChange` `.live` | `tab.live.hasWebContent`; placeholder ↔ host swap in the slot. |
| `createWebContentFor` (`OEOpenRequest`) | Disposition: `newForegroundTab` → select new Today tab at top; `newBackgroundTab` → background host, no select; `newPopup` with a size → auxiliary panel (§4.12 pattern); `newWindow` → new standard window. Check Peek policy and Opt+Cmd-click first (M4 §4.2 order). Return `nil` to block. |
| `webContentDidRequestClose` | Close that tab/panel as Cmd+W would. |
| `engineWebContent(forUnownedOpenRequest:)` | Adopt as a new Today tab in the front window (port `adoptUnownedRequest`). |
| Downloads, permissions, dialogs, context menu, find, fullscreen | §4.9. Fullscreen also feeds sleep visibility. |
| DevTools events, console | Automation `events` log only. No model writes. |

Port checklist from the M1 file (each item must exist in a new owner or be dropped by name in the Step B PR): `ensureContent/makeContent/dropContent`, `syncTabStrips`, `showSelection/select/focus(space:)`, `openNewTab/adoptUnownedRequest`, extension bar + popups, auxiliary pages, `closeTab/restoreLastClosedTab` neighbor selection, `togglePin`, `addSplitView`, print/reload/back/forward/zoom/devtools actions, find, address entry (deleted; the command bar replaces it — the sidebar URL field is display + command-bar entry, `docs/design.md` §5), fullscreen, status text (link hover → container status area; if the real design has none, drop it and say so), `content(forAutomationHandle:)`, `record/drainEvents`, `completePendingDialog`.

## 5. Startup sequence (cold-launch budget)

Budgets (release, M5 Pro, idle machine): sidebar drawn ≤ 250 ms from process start; first web paint of the restored tab ≤ 700 ms. Measure with `timing` (exists) plus two new marks below, through `--only measure`. Report medians of 5 launches on an idle machine; loaded-machine numbers are upper bounds only.

### 5.1 Order (normative; `T` = process start)

| Phase | Work | Budget mark |
|---|---|---|
| T0 `main.swift` first lines | `OEApplication.shared` (first AppKit call, required), `LaunchTiming.mark("main")`, `ApplePersistenceIgnoreState`, create `AppDelegate`, set `keyEquivalentHandler`. No file I/O, no store opens. | `main` ≤ 50 ms |
| T1 data root | `prepareData()`: resolve the data root, take the data-root lock, run layout migration (`OpenDataRoot.prepare`), load the snapshot (`SnapshotStore.load`). On load failure: log and start from the default model (existing behavior; never crash). Create `ProfileDirectories`. | `modelLoaded` ≤ 120 ms (existing profile) |
| T2 first window, no engine | Build every standard window from the snapshot (`OpenFeatures.BrowserWindowController` + sidebar + container + placeholders), restore frames and selections, `showWindow`. The selected tab shows its placeholder; no `OEWebContent` exists yet. Set `LaunchTiming.mark("sidebarDrawn")` after the first sidebar display. | `sidebarDrawn` ≤ 250 ms |
| T3 engine start | On the next main-runloop turn after T2, build `OEEngineConfiguration` and call `OEEngine.shared.start` (`CefInitialize`). Deferring start past the first window draw is the change that buys the sidebar budget (engine-spike named win). `engineDidInitialize` may still arrive before `applicationDidFinishLaunching`; `showWindowsIfNeeded` stays idempotent (existing guard). | `engineStarted` unbudgeted; log it |
| T4 first page | After engine readiness, create the host for each visible selected tab only (one per window, plus split panes of selected splits). Everything else stays a placeholder. | first paint ≤ 700 ms (`timing` first contentful paint) |
| T5 lazy systems | After first paint, in this order, each on first use or idle time: automation server (Debug; starts at `engineDidInitialize` today — keep), `FaviconStore` open (background), per-profile `HistoryStore` on first commit, `BoostStore` + ad-block `openProfile` for shown profiles only, `SleepController` start, key-binding overrides load, `GlobalHotkey` register, Little Open sweeper start, external-link queue flush. None of these may block T2 or T4. | — |

### 5.2 What must never happen at launch

- No `CefInitialize` before the first window draws (T3 after T2). If `OEApplication` or CEF forces earlier init, stop and report with the `timing` output; do not silently accept a 450 ms sidebar.
- No web content for unselected tabs. No engine context for profiles with no shown Space (D7). No `HistoryStore`, `FaviconStore`, or SQLite open on the main actor before T2.
- No network at launch: no favicon fetch, no list update, no suggestion fetch until a page commits or the command bar opens.
- No Settings, command bar, Peek, or editor construction. All lazy (§3.5, §4.11).
- No full sidebar rebuild after engine readiness. The T2 sidebar is final; engine events only fill `tab.live`.

### 5.3 Quit order

`applicationShouldTerminate` → sleep `captureAllForQuit()` (§4.7) → `saveState()` (window states into the model, `snapshotStore.saveNow`, `archiveSink.flushAll`, Boost `saveNow` per profile) → unregister the global hotkey → `OEEngine.shared.shutdown()`. A renderer that never answers must not block quit past the engine's 3 s bound (`docs/engine-api.md`).

## 6. Automation: new suites (extend `tools/e2e/engine_e2e.py`)

Add each suite with its step. Suites use a fresh user data dir per run, drive the real app through the socket, and write JSON results + PNGs under `docs/engine-spike/` (follow the existing suite shape). Never drive the desktop. New automation commands go in `AutomationController.swift` only when a suite cannot express the check with existing commands (`open`, `select`, `key route=app`, `snapshot`, `tabs`, `pages`, `events`, `timing`, `policy`, `script-add`, `filter`, …). Prefer `key route=app` (real `NSApplication.sendEvent` path) for every shortcut check.

| Suite | Proves | Key checks (all must pass) |
|---|---|---|
| `window` | §3.1–3.3, §3.8 | Two windows open with distinct frames; close + relaunch restores frame, sidebar width, mode, focused Space, selection. Sidebar drag to 300 pt persists; a drag to pointer x 150 stops at 164 with the compact toolbar; a drag right stops at 500; from 228, a drag to pointer x 60 hides the sidebar before the mouse-up event, release keeps it hidden, and Cmd+S restores 228; a double-click on the handle at 364 and at 500 gives 228; Cmd+S hide and Cmd+S show each start within one frame of the key and reach their end frame ≤ 0.13 s after the key (`timing` marks; no show delay, Q11); hover-reveal card appears and dismisses on selection; during the card's slide in (sampled with `timing` marks at ≥ 60 Hz) its right edge passes its rest position by ≥ 2 pt and settles back within 0.5 pt by 0.25 s; a Space switch settles ≤ 0.30 s after the click. Full screen enter/exit keeps the selection. |
| `sidebar` | §4.1 | Select, pin/unpin, close Today (archives), close pinned (unloads, row stays), folder toggle, Space switch, Clear Today, drag move — each checked in `tabs` order + `tab.live` flags. Compare `snapshot` PNG with the Arc capture set (below). |
| `commandbar` | §4.2 | Cmd+T opens `.newTab`; type a host, Return opens a top Today tab. Cmd+L edits the current URL. A switch-to-tab row jumps Spaces. A calculator row copies. Esc closes; second Esc reaches the page. First results timing from `timing` + suite clock ≤ 50 ms after open on an idle machine. |
| `split` | §3.4 (exists in part as the M1 shell check) | Add split, focus panes, divider drag persists fractions, close pane, unsplit. Two live pages in `pages`. |
| `peek` | §3.6 | Cross-host click on a pinned tab opens a Peek; same-host navigates in place; Esc dismisses with undo toast; expand-to-tab keeps the page; nested Peek caps and navigates in place. |
| `routing` | §4.4 | Queued cold-launch URL lands per the decision; rule → Space; default → Little Open; toggle off → most recent Space; hotkey opens a blank Little Open with no main window. Re-run `openkit route` A1–A17. |
| `boosts` | §4.5 | A Boost hides the fixture banner at document start (element hidden before first paint check through `eval`), clear restores it, SPA navigation keeps it applied once. The isolated-world check is reported as blocked on P7, not faked. |
| `adblock` | §4.6 | With the bridge filter on, the ad fixture request is blocked (`filter-stats` + page probe); excluded site loads it; disabling the profile filter loads it. |
| `sleep` | §4.7 | Hidden tab freezes (ticker stops), discarded tab recreates on select with its URL/title, audible tab never sleeps, quit captures without data loss after relaunch. Patch-dependent rows report `blocked: P-MEM-xx`, never pass. |

Screenshots: for `window`, `sidebar`, `commandbar`, `split`, and `peek`, save Open's window PNG (`snapshot`) next to the matching Arc capture (the `docs/design.md` §7 comparison method: same window size, sidebar width, 1x, masks for favicon/web content/traffic lights). The suite prints position and ΔE00 errors per element and fails past the §8 targets (≤ 1 pt, ΔE00 ≤ 2). Arc captures live in `.re/` (git-ignored); suites must skip the comparison with a clear message when captures are absent, and still run every functional check. Never commit user data or Arc assets (`AGENTS.md` rules 1, 5).

## 7. Implementation order (small PRs; each step: files, then acceptance)

Work in order. A step starts only when the step before it passes. Every PR: merge `origin/main` first, run `tools/verify-all.sh`, paste its summary table into the PR (`AGENTS.md` rule 10). One library target per PR where the table says so; `Package.swift` merge conflicts keep both sides.

| Step | Work | Files | Acceptance |
|---|---|---|---|
| A. Window before engine | Reorder launch (§5.1): windows at T2, `CefInitialize` on the next runloop turn. Add `sidebarDrawn` and `engineStarted` marks. No visual change (still the M1 window). | `App/main.swift`, `App/AppDelegate.swift` | `--only measure`: sidebar mark ≤ 250 ms median of 5 idle launches; first paint still ≤ 700 ms. `--only shell` passes. |
| B. Real window | Adopt `OpenFeatures.BrowserWindowController` (wait for the OpenFeatures library PR). Build the engine factory + host + `TabStripMirror`. Port §4.13. Delete `App/BrowserWindowController.swift`. §3 composition: sidebar, container, placeholders, toasts, resize/hide/reveal, multi-window, persistence. | §2.3 WebContent files, `App/TabStripMirror.swift`, `App/AppDelegate.swift`, `project.yml` | `window` + `sidebar` suites pass. `sidebar-render check` still passes. Screenshot comparison within targets. No M1 file remains. |
| C. Menus + keys + command bar | `MenuBuilder` menus, `CommandDispatcher` App extension (§4.3 table), `KeyboardRouter` in both key layers, `GlobalHotkey` (window half only; Little Open opens a stub session until Step E), command bar + `AppCommandBarDelegate` + `SuggestEngine` (wait for `m3/commandbar-ui`). Settings placeholder (§4.11). | `App/MainMenu.swift` (rewrite), `App/CommandBar/*`, `App/Settings/SettingsPlaceholder.swift`, `App/AppDelegate.swift` | `commandbar` suite passes. `commands-dump` exit 0. Cmd+T/L/W/S work with a page focused that swallows keys (`key route=window` check from the M1 shell suite). |
| D. Page chrome | Find bar, context menus, JS dialogs, permissions, downloads UI, Site Control popover (§4.9), extension popup panels (§4.12). | Controller + factory delegate code from Step B, `App/EngineBridge.swift` | `--only features` passes (all 19 M1 checks) against the new window. Dialog/permission automation policies verified. |
| E. Routing + Little Open | Routing plan Steps 5–7: Info.plist handlers, intake, default browser, executor, hotkey real target, sweeper (§4.4). Peek wiring if M4 Step 5 has landed; else land Peek here per M4 §4. | `App/ExternalLink/*`, `App/LittleOpen/*`, `App/Info.plist` | `routing` + `peek` suites pass. Cold-launch URL check passes (quit → `open https://…` → correct destination). |
| F. Boosts + ad block | `AppStores`, `BoostEngineAdapter`, `AdBlockEngineAdapter` (§4.5, §4.6). Zap stays disabled behind the P7 marker. | `App/Stores/AppStores.swift`, `App/Boosts/*`, `App/AdBlock/*` | `boosts` + `adblock` suites pass. `openkit adblock` and boosts harness checks unchanged. |
| G. Sleep S6 | `EngineSleepAdapter`, `AppSleepCoordinator`, visibility wiring, quit order (§4.7). | `App/WebContent/EngineSleepAdapter.swift`, `App/Sleep/*` | `sleep` suite passes with patch-dependent rows marked blocked. `openkit sleep-demo` still 105/105. |
| H. Stores + scripting | Favicon ingest + provider, history recording (§4.8), profile-switch host teardown, AppleScript H1–H4 (§4.10). | `App/Stores/*`, `App/Scripting/*`, `App/Resources/Open.sdef`, `App/Info.plist` | Relaunch shows favicons on unloaded tabs; history search finds a visited page; `sdef Open.app` + Script Editor A-checks from `docs/scripting.md` pass. |
| I. Measure + harden | Full `--only measure` on an idle machine, idle CPU, 10-tab memory, signature-stable CEF note. Fix only regressions this plan introduced. | — | Budgets met or each miss named with its `timing` evidence. `tools/verify-all.sh` all PASS. |

Split and Peek library work (M4 Steps 1–7) is not re-planned here. If a library piece is missing when its App step starts, land the library piece first in its own PR under the M4 plan, then return.

## 8. Global acceptance gates (every PR)

1. `tools/build.sh Debug` and the step's e2e suites pass. Release build for Steps A and I.
2. `tools/verify-all.sh` summary pasted in the PR. SKIP only for targets that do not exist yet.
3. No new unit tests. No third-party dependency without a written reason in the PR.
4. Swift 6 strict concurrency clean: no warnings. `grep` the diff for `Arc` in user-visible strings (allow "Import from Arc" and search aliases only), for `Little Arc` (same rule), and for any copied asset.
5. Performance: no step may regress the `measure` marks by more than 10 % without naming it in the PR.

## 9. Risks and open questions

These do not block Step A. Each names its owner and deadline. Implementers: build the stated default; do not invent another answer.

| # | Question | Default in this plan | Decide by |
|---|---|---|---|
| Q1 | `OpenFeatures.BrowserWindowController` exact API after the library move (init, callbacks, toast, find). | Step B reads the merged library source and adapts the factory to it; renames are reported, not worked around. | Step B |
| Q2 | `OpenCommandBar` delegate shape on `m3/commandbar-ui` at merge time. | §4.2 as documented on the branch 2026-10-25. Re-verify with `git show` before Step C. | Step C |
| Q3 | Sidebar 180 pt hide threshold and hover-reveal delays (0.35 s / 0.25 s) are guesses. | **Answered 2026-10-26.** Dwell 0.15 s decoded (`docs/design.md` §16). Capture session 2: minimum 164, maximum 500, hide while pressed past the minimum, Cmd+S restores the pre-drag width, double-click resets to 228 (§3.3). The hide point `WindowMetrics.sidebarDragHidePoint` (82 pt) stays a guess inside the measured 65–85 band. | done |
| Q4 | Peek Split-button semantics and expand state survival (M4 Q4/Q5, engine A2). | M4 §4.4 guess, marked in code; reload fallback if reparenting reloads. | Step E |
| Q5 | Opt+Cmd-click → Little Open needs a modifier-aware navigation hook. | Ship without it if the hook is absent; record the gap. | Step E |
| Q6 | Ad-block rule matching before the fork engine: does `OpenAdBlock` expose a rule-level API? | Bridge blocks nothing at rule level until it does; exclusions still work (§4.6). | Step F |
| Q7 | Sleep `captureHistory` returning `nil` may block discard. | Minimal envelope fallback, stated in the PR (§4.7). | Step G |
| Q8 | Incognito tab persistence in the model. | Never persisted; in-memory list if the model cannot exclude a window (§4.8). | Step C |
| Q9 | Fresh-profile `CefInitialize` cost (about 1.3 s extra) and framework signature checks. | Accept for v1; P5 trims it later. The 250 ms sidebar budget is measured on an existing profile. | Step I |
| Q10 | macOS 26 SDK shape for default-browser registration (routing Q1). | Read the SDK headers at Step E; use what they declare. | Step E |
| Q11 | Arc starts the Cmd+S show ≈ 0.29 s after the key (measured 0.28–0.30 s in 3 of 3 events, V 18.76, 23.08, 32.41 s; cause unknown; the hide starts at once). Copy the delay? | **Decided 2026-10-26 (lead), Open decision: no.** The show starts with the key (0 s delay). A delay before the animation is latency, not design, and Open's top goal is a snappy app. The show and hide animations stay ≈ 0.1 s (`Motion.sidebarToggle`). No `sidebarShowDelay` token exists. | done |

## Appendix — Lead decisions (2026-10-25)

- Approved with the stated defaults for every open question in §9 (180 pt hide threshold, Peek split semantics per the M4 lead decisions, ad-block via the request-filter hook until the fork engine lands, sleep history capture via today's API until P-MEM patches land).
- Ownership: the app-shell implementer owns App/ UI composition and wiring. The engine lead (fork bring-up + extension P1) owns Engine/, Engine/fork/, project.yml engine settings, and adds only small, clearly separated hooks in App/ (new OpenEngine delegate callbacks). Coordinate by merging origin/main often; on conflicts in App/, keep both sides' intent.
- Phasing: Steps A + B first (one PR each). Step C after the command bar PR (#43) merges. Steps D–I follow in order.

### Step C integration update (lead direction, 2026-10-25)

PR #43 supplies the merged command-bar delegate API. PR #51 (`dc62e65`) supplies
`OpenSettings`; Step C uses its real `SettingsPresenter` and `LibraryPresenter`
and their action protocols. The §4.11 placeholder is superseded.
`App/Settings/AppSettingsActions.swift` replaces the planned
`SettingsPlaceholder.swift`. Both view models receive the app's existing
`SnapshotStore`. Library uses the existing Archive/History stores, the engine
Downloads feed, and `FileCapturesProvider`. `view-downloads`, `view-archive`, and
`view-history` select the matching section in the shared Library window.
`SearchEngines.resolve(id:profile:)` resolves built-in and custom search engines.
The query gate uses `SettingsPresenter.prepareForRemoteSuggestions(profileID:)`
without opening a Settings window or changing its selected profile.

The App command extension lives with the registry menu bridge in `MainMenu.swift`.
Duplicate copies a tab, all split panes, or a complete folder subtree immediately
after its source, with fresh IDs and no hosts, as directed by the lead. A single
model undo removes the whole copy. CEF's AppKit pump uses explicit model command
undo groups, because its runloop does not supply AppKit event-group boundaries.

Engine adapter limits at this step remain explicit: the current public engine
has no initiate-download/save-page API. Save Page uses a native Save panel and
`Page.captureSnapshot` MHTML through OpenEngine. Data clearing supports only the
engine's all-time combined cookies/cache operation; other selections return a
plain error before mutation. Durable import, ad-block engine binding, and sleep
lifecycle binding stay in their planned later steps. Their Settings action
adapters do not claim those operations completed. Little Open remains the Step C
stub until Step E. No engine implementation or engine project setting changed.

## Appendix — Lead decisions (2026-10-26, capture session 2)

These supersede the 2026-10-25 entries where they conflict. Evidence: `docs/re/interaction-states.md` §20.1, §20.2, §20.12; `docs/re/capture-session-2-results.md` C16, C20, §2.1, §2.10.

- D4 and Q3 superseded: the sidebar resizes between **164** and **500** pt (not 228–500 with a 180 pt drop threshold). Dragging past the minimum hides the sidebar while the button is still down; Cmd+S then restores the width from before the drag. A double-click on the resize edge resets the width to 228.
- The drag-hide point is pointer x < 82, one named token `WindowMetrics.sidebarDragHidePoint`, a guess inside the measured 65–85 band.
- Motion: the Space switch spring response is **0.20 s** (not 0.30). Cmd+S hide and show take ≈ 0.10 s each (spring response 0.10 s). Q11 (Open decision): the show starts with the key; Open does not copy Arc's ≈ 0.29 s delay. The hover-reveal card slides in in ≈ 0.14 s with a 3 pt overshoot (spring response 0.164 s, damping 0.81, review r1) and out in ≈ 0.10 s.
- The hover-reveal card is translucent (≈ 0.885 theme tint + 0.115 blurred page).
- The PR #104 owner implements these window parts from §3.3 and edits the matching `docs/design.md` §2.4 rows; the sidebar plan's lane A1 adds the hint trigger and the compact toolbar.
- `.showHelp`: #85 opens `helpURL`; commandbar-completion Step 0 removes this case, because the command bar shows its own privacy footer (commandbar-completion lead decisions, same date). Step 0 edits the App delegate and builds the App.
- Review r1 (F4): `revealCardIn` = response 0.164 s, damping 0.81 (fitted to the ≈ 3 pt overshoot); `slideCard` uses `revealCardIn` / `revealCardOut`; `sidebarToggle` stays for Cmd+S and the drag-hide.
