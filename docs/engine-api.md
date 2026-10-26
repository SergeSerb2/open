# OpenEngine API

OpenEngine is the only code that includes CEF headers. It is an ObjC++ framework (`Engine/OpenEngine/`) with a Swift-friendly API: every header is nullability-annotated, main-thread classes are `NS_SWIFT_UI_ACTOR` (Swift sees them as `@MainActor`), and completion blocks import as `async` functions. Swift uses the `OE`-prefixed class names directly, as Arc's Swift code uses `ArcWebContents`; this keeps them apart from OpenKit's `Tab` and `Profile`.

Headers: `Engine/OpenEngine/include/OpenEngine/` (`OpenEngine.h` is the umbrella). Implementation: `Engine/OpenEngine/src/`. The fork this layer will run on lives in `Engine/fork/` (docs/engine-fork.md).

## Shape

The layering copies Arc's ADK over ArcCore (docs/re/architecture-map.md §5, docs/re/arccore-engine.md §1-2): the shell allocates configuration and value objects; the engine allocates pages it creates itself (popups, extension popups), downloads, dialogs, and requests, and hands them over through delegates.

| OpenEngine | Arc (ArcCore / ADK) | Role |
|---|---|---|
| `OEEngine`, `OEEngineConfiguration`, `OEEngineDelegate`, `OEApplication` | `ArcBrowserApplication`, `ArcBrowserApplicationConfiguration`, `ADKApplicationDelegate` | Process lifecycle, message loop, contexts, diagnostics |
| `OEBrowserContext` + `OEBrowserContextDelegate` | `ArcBrowserContext` (+ Effects, Downloads, Extensions) | One profile: storage, user scripts, network filter, permissions, downloads, extensions |
| `OEBrowser` + `OEBrowserDelegate` | `ArcBrowser` + `BrowserDelegate` | One window's tab strip and its extension actions and popups |
| `OEWebContent` + `OEWebContentDelegate` | `ArcWebContents` + UI/navigation delegates, ADK `WebContent` | One page and its view |
| `OEExtensionManager`, `OEExtension`, `OEExtensionAction` | `ArcBrowserContextExtensions`, `ArcExtensionInfo`, `ArcExtensionToolbarAction` | Installed extensions and toolbar action snapshots |
| `OEOpenRequest`, `OEJavaScriptDialog`, `OEPermissionRequest`, `OEContextMenu`, `OEFindResult`, `OEDownload` | `ArcNavigationAction`, JS panels, `ArcPermissionRequest`, `ArcContextMenuElementInfo`, `ArcFindResult`, `ArcDownloadItem` | Engine-owned requests answered by the shell |

OpenKit never imports OpenEngine. It uses the Swift protocols in `Packages/OpenKit/Sources/OpenWeb` (`WebContent`, `WebProfile`, `ExtensionHost`); `App/EngineBridge.swift` makes the engine classes conform. The automation channel already calls the engine through these protocols (`eval`, `script-add`, `filter`, `extensions`).

## Build layout

```
Open.app/Contents/
  MacOS/Open                                  Swift app (App/)
  Frameworks/OpenEngine.framework             OpenEngine + libcef_dll_wrapper (1.3 MB)
  Frameworks/Chromium Embedded Framework.framework
  Frameworks/Open Helper.app                  utility, network, ...
  Frameworks/Open Helper (GPU|Renderer|Plugin|Alerts).app
```

- `project.yml` (XcodeGen; `Open.xcodeproj` is generated and git-ignored) defines `OpenEngine` (framework), five helper apps from one template (each `main()` calls `OEHelperMain`), and `Open`, which embeds OpenEngine and links the OpenKit products `OpenModel`, `OpenStore`, `OpenWeb`.
- `tools/fetch-cef.sh` puts a CEF distribution at `Vendor/cef/` (the contract from docs/plans/fork-infra.md, F-14) and builds `libcef_dll_wrapper.a` in `Vendor/cef/build/`. `CEF_SOURCE=fork` (default) runs `tools/fetch-engine.sh --run`, which copies the fork's recorded distribution (docs/engine-fork.md). `CEF_SOURCE=cdn` uses the pinned Spotify CDN build of the same CEF commit and Chromium tag as `Engine/fork/VERSIONS` (the script checks this), for comparisons; the archive and its extraction are cached in `~/Library/Caches/Open/cef`.
- `tools/embed-cef.sh` (a build phase) copies the CEF framework and the helpers into the app and signs them. `OPEN_KEEP_LOCALES="en"` ships only those locales.
- `tools/build.sh [Debug|Release]` runs everything at `nice 10` with at most 6 parallel jobs. `tools/run.sh` runs the built app.
- Helpers link `OpenEngine.framework`, so the renderer half of the engine (user-script injection, the audible probe) lives in the same code as the browser half.

## Lifecycle

```swift
let app = OEApplication.shared as! OEApplication      // first AppKit call
app.keyEquivalentHandler = { MainMenu.performReservedShortcut($0) }
let config = OEEngineConfiguration()
config.userDataDirectory = dataDir                     // symlinks are resolved
try OEEngine.shared.start(configuration: config)       // CefInitialize
OEEngine.shared.runMessageLoop()                       // runs NSApp; returns after terminate
saveState()
OEEngine.shared.shutdown()                             // CefShutdown
```

- `OEEngineDelegate.engineDidInitialize()` arrives once Chromium is ready. Its order relative to `applicationDidFinishLaunching` is not fixed (with the Chrome bootstrap, initialization finishes inside `CefInitialize`), so the shell builds its windows at whichever comes first. Web contents created earlier wait inside the engine.
- `-[OEApplication terminate:]` asks the app delegate (`applicationShouldTerminate`), then `-[OEEngine terminate]` closes every page and quits the loop. A renderer that never answers cannot block quit for more than 3 s.
- OpenEngine always adds `--disable-field-trial-config` in the browser process: non-official Chromium builds apply the field-trial testing config, which breaks child-process launch on macOS 27.2 beta (docs/followups.md). Since 2026-10-25 the fork's dev args set `disable_fieldtrial_testing_config=true`, so the switch is only a safety net (for example for `CEF_SOURCE=cdn` builds).
- Keychain: cookies and passwords are encrypted with a key in the keychain item `keychainServiceName`/`keychainAccountName` (default "Open Safe Storage"/"Open"), never Chromium's shared "Chromium Safe Storage" item, whose access prompt otherwise blocks page loads. `useMockKeychain` uses an in-memory key; the app turns it on for ad-hoc signed builds (no Team ID), whose signature changes on every build.

## Keyboard

- `OEApplication.keyEquivalentHandler` sees every Command or Control key-down in `-sendEvent:` before any view. Return `true` to consume it. The shell uses it for Arc's reserved shortcuts (Cmd-T, Cmd-W, Cmd-L, Cmd-S, Cmd-D, Cmd-Shift-T, Cmd-Opt-arrows, Ctrl-Tab), so a page cannot swallow them.
- `-webContent:handleKeyEventBeforePage:` (CEF `OnPreKeyEvent`) covers key events that reach the page view directly.
- Other shortcuts go to the page first; unconsumed ones come back through `-webContent:handleUnconsumedKeyEvent:` and then the main menu.

## OEEngine

| Member | Notes |
|---|---|
| `shared`, `delegate`, `configuration`, `isRunning`, `isInitialized` | |
| `chromiumVersion`, `cefVersion` | `156.0.8078.48`, `156.0.14+g4fa4ab5+chromium-156.0.8078.48` |
| `start(configuration:)`, `runMessageLoop()`, `terminate()`, `shutdown()` | Lifecycle above |
| `defaultContext`, `context(identifier:directory:)`, `context(identifier:)`, `makeEphemeralContext()`, `releaseContext(_:completion:)`, `contexts` | Profiles. `userDataDirectory` is Chromium's `root_cache_path`. The global context is the default profile, always at `<userDataDirectory>/Default`: CEF ignores any other child `cache_path` for it (`cef_types.h`, `CefSettings.cache_path`). Other contexts live under the root. Asking for the default folder returns `defaultContext`, so two contexts never share one Chromium profile folder. |
| `browsers`, `allWebContents`, `webContent(identifier:)` | Live objects (weak registry) |
| `sampleProcessMetrics(after:)` | Chromium task manager rows: kind, memory, GPU memory, CPU |

`OEEngineConfiguration`: `userDataDirectory`, `userAgentProduct`, `locale`, `defaultRuntimeStyle`, `remoteDebuggingPort`, `additionalSwitches`, `logFile`, `verboseLogging`, `keychainServiceName`, `keychainAccountName`, `useMockKeychain`.

The shell follows the profile layout of [plans/profiles.md](plans/profiles.md) §5-6 (`ProfileDirectories` in OpenStore): `userDataDirectory` = `<root>/Profiles`, and every non-default profile's context is `context(identifier: dir, directory: <root>/Profiles/<dir>/Engine)`, created when a Space of that profile is first shown. One deviation, forced by CEF: the plan sets the global `cache_path` to `<root>/Profiles/Default/Engine`, but CEF ignores child paths for the global context, so the default profile's engine data is `<root>/Profiles/Default/` itself (next to its `State/`). Mapping to the interface that plan assumed (§6.6):

| Plan | OpenEngine |
|---|---|
| E1 `contextHandle(forProfileID:cachePath:…)` | `context(identifier:directory:)` (cached by identifier; the default profile maps to `defaultContext`) |
| E2 `releaseContext(forProfileID:)` | `releaseContext(_:completion:)` |
| E3 `makeWebContent(tabID:context:initialURL:)` | `OEWebContent(configuration:url:)` with `OEWebContentConfiguration(context:)`; the shell keys pages by `ItemID` |
| E4 context ready | Pages created before a context is ready wait inside the engine; no public flag yet |
| E5 ad-block hand-off | The `CefRequestContext` behind each `OEBrowserContext` (plans/adblock-fork.md §11) |
| E6 `makeIncognitoContext(windowID:)` | `makeEphemeralContext()` + `releaseContext(_:completion:)` |

`OEEngineDelegate`: `engineDidInitialize()`, `engineWebContent(forUnownedOpenRequest:)` (Chromium opened a page on its own, for example an extension welcome page or `chrome.tabs.create` from a service worker: return a web content to show it as an Open tab; the engine closes Chromium's own window), `engineWillShutDown()`.

## OEBrowserContext (profile)

| Member | Notes |
|---|---|
| `identifier`, `directory`, `isEphemeral` | Ephemeral contexts are in memory only (incognito) |
| `extensions` | `OEExtensionManager` |
| `userScripts`, `addUserScript(_:)`, `removeUserScript(identifier:)`, `removeAllUserScripts()` | Boosts and Zap. `OEUserScript`: JavaScript or a style sheet, document start or end, Chrome match patterns, main frame only. New documents in every page of the context get changes at once. Main world only (patch P7). |
| `requestFilter` | `(OEResourceRequest) -> OERequestDecision`, called on the network thread for every request of the context, including service workers. Allowed requests get no per-request handler. |
| `permissionState(for:origin:)`, `setPermissionState(_:for:origin:)` | Chromium content settings for Site Control Center |
| `clearBrowsingData(origin:)` | Cookies (one origin or all) and the HTTP cache |
| `downloads`, `delegate` | `browserContext(_:decideDestinationFor:suggestedFilename:completion:)`, `browserContext(_:downloadDidUpdate:)`; `OEDownload` has state, bytes, speed, `cancel/pause/resume` |

## OEBrowser (window tab strip)

One per shell window and profile. The shell keeps it exact; with fork patch P1 it becomes the Chrome window that extensions see (docs/engine-patches.md).

| Member | Notes |
|---|---|
| `init(context:)`, `identifier`, `context`, `window`, `delegate` | |
| `webContents`, `insert(_:at:)`, `remove(_:)`, `move(_:to:)`, `setPinned(_:for:)`, `isPinned(_:)`, `activeWebContent` | Sidebar order: favorites, pinned, today. A page that closes leaves the strip by itself. |
| `extensionActions` | `[OEExtensionAction]`: extension id, title, icon, badge text and color, enabled, has popup, popup URL |
| `executeExtensionAction(_:)` | Like a click on the action's button. Opens the popup (a second click closes it, as in Chrome). Returns `false` for a popup-less action in stock CEF (patch P2). |
| `extensionPopup`, `closeExtensionPopup()`, `close()` | |

`OEBrowserDelegate`: `browserDidUpdateExtensionActions(_:)`, `browser(_:didOpenExtensionPopup:for:)` (host `popup.view` in a panel at the button), `browser(_:didResizeExtensionPopup:to:)` (Chrome's limits, 25×25 to 800×600), `browser(_:didCloseExtensionPopup:)` (`window.close()` in the popup, a new popup, or `closeExtensionPopup()`).

## OEWebContent (page)

Creation and lifetime:

- `OEWebContent(configuration:url:)`. `OEWebContentConfiguration(context:)` has `runtimeStyle` (`.alloy` default, `.chrome` for the stock-CEF extension experiments), `backgroundColor`, `showsChromeToolbar`.
- `view` is an NSView (flipped). Put it anywhere: several per window (Split View) or a panel (popups, extension popups). Moving a live page's view to another window is expected to work (Chromium follows its view) but is not tested yet. The Chromium browser is created when `view` first enters a window, so a tab that is never shown costs nothing (the shell restores only the selected tab at launch).
- `close()` destroys the Chromium browser; the object stays alive until Chromium confirms. A page whose last reference goes away without `close()` is closed too; its CEF view is parked so Chromium can finish.
- A hidden view (`isHidden` or a hidden ancestor) tells Chromium the page is hidden, which throttles it.
- `browser` (the `OEBrowser` it belongs to), `identifier` (unique per process, 0 until live), `isLive`, `isPopup`, `extensionPopupIdentifier`.

State (read the properties after `webContent(_:didChange:)`; the change set says what changed): `url`, `title`, `faviconURL`, `favicon`, `isLoading`, `estimatedProgress`, `canGoBack`, `canGoForward`, `isAudible`, `isMuted` (settable), `isFullscreen`, `crashState`, `isCapturingCamera`, `isCapturingMicrophone`, `statusText` (link hover), `zoomLevel` (settable). `.live` reports browser creation and destruction.

Commands: `load(_:)`, `goBack()`, `goForward()`, `reload()`, `reloadIgnoringCache()`, `stopLoading()`; `evaluateJavaScript(_:) async throws -> Any` (main world, awaits promises, user gesture); `sendDevToolsMethod(_:parameters:) async throws` (events go to `didReceiveDevToolsEvent`); `find(_:forward:caseSensitive:)`, `stopFinding(clearSelection:)`; `zoomIn()`, `zoomOut()`, `resetZoom()`; `showDevTools()`, `closeDevTools()`, `hasDevTools`; `showPrintPanel()`, `printToPDF(at:)`; `takeSnapshot() async throws -> Data` (PNG of the visible page, also when hidden); `enableAutoResize(minimumSize:maximumSize:)`; `focusPage()`; `exitFullscreen()`.

`OEWebContentDelegate` (all optional, all on the main thread):

| Method | Use |
|---|---|
| `webContent(_:didChange:)` | Observable state changed |
| `webContent(_:createWebContentFor:)` | `target=_blank`, `window.open`, Cmd-click, middle click. Return a new page (put its view in a window now) or `nil` to block. `OEOpenRequest`: url, disposition (`newForegroundTab`, `newBackgroundTab`, `newPopup` for sized `window.open`, `newWindow`, ...), user gesture, requested frame, opener, context. |
| `webContentDidRequestClose(_:)` | `window.close()` |
| `webContent(_:handleKeyEventBeforePage:)`, `webContent(_:handleUnconsumedKeyEvent:)` | Keyboard, above |
| `webContent(_:runJavaScriptDialog:)` | `alert`/`confirm`/`prompt`/`beforeunload`. Return `true` and call `complete(accepted:text:)` later. An unanswered dialog is cancelled when released. |
| `webContent(_:decidePermissionRequest:)` | Camera, microphone, screen, notifications, geolocation, ... `grant()`, `deny()`, `dismiss()` |
| `webContent(_:showContextMenu:)` | `OEContextMenu`: targets, media type, location, link, source, selection, spelling, and Chromium's own items (including extension items). Show our NSMenu and call `select(command:)` or `cancel()`. |
| `webContent(_:didUpdateFindResult:)` | Match count, active index |
| `webContent(_:didRequestFullscreen:)` | HTML fullscreen: hide the sidebar |
| `webContent(_:didRequestContentSize:)` | Auto-resize (Peek-style panels) |
| `webContent(_:didFinishLoadWithStatus:)`, `webContent(_:didFailLoadWithError:)` | Main frame |
| `webContent(_:didReceiveDevToolsEvent:parameters:)`, `webContent(_:didLogConsoleMessage:level:source:line:)` | Diagnostics, automation |

## Extensions

`OEExtensionManager` (per context): `installedExtensions` (`OEExtension`: id, name, version, summary, manifest version, enabled, unpacked, folder, icon, options URL, permissions, host permissions), `extension(identifier:)`, `reload()`, `managementPageURL` (`chrome://extensions`, Chrome style only), `webStorePageURL(extensionIdentifier:)`, and a delegate. In stock CEF the list comes from the profile's Preferences and manifests and refreshes when Chromium rewrites them; fork patch P3 replaces this with Chromium's live registry.

## Known gaps in stock CEF

Each has a fork patch in [engine-patches.md](engine-patches.md):

| Gap | Today | Patch |
|---|---|---|
| `chrome.tabs`/`chrome.windows` do not see Alloy pages | Works only for Chrome-style pages, one window per page | P1 |
| Pages that extensions open | Reloaded into a new Open tab (loses tab identity and opener) | P1 |
| Dynamic action state, `onClicked`, real popup host | Manifest defaults; popup is a plain page | P2 |
| Install, uninstall, enable from our UI; our own consent prompts | Web Store install needs a Chrome-style page and shows Chrome's dialog | P3 |
| H.264, AAC, Widevine | Not in stock CEF | P4 |
| Audible state for Web Audio | Media-element probe in the page | P6 |
| User scripts in an isolated world | Main world | P7 |

## Debugging crashes

The CEF framework is stripped. CEF publishes the matching symbols: `https://cef-builds.spotifycdn.com/cef_binary_<version>_macosarm64_release_symbols.tar.bz2` (2.1 GB for 156.0.14). Check the UUID with `dwarfdump --uuid` against the crash report's image UUID, then `atos -o "<dSYM>/Contents/Resources/DWARF/Chromium Embedded Framework" -arch arm64 -l 0x0 <imageOffset>...` with the offsets from the `.ips` report. Chromium's zombie detector (`CrZombie` in a stack) means a message to a freed Objective-C object.
