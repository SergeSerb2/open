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
- Helpers link `OpenEngine.framework`, so the renderer half of the engine (user-script injection) lives in the same code as the browser half.

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
| `defaultContext`, `context(identifier:directory:)`, `context(identifier:)`, `makeIncognitoContext(for:completion:)`, `deleteContext(_:completion:)`, `releaseContext(_:completion:)`, `contexts` | Profiles. `userDataDirectory` is Chromium's `root_cache_path`. The global context is the default profile, always at `<userDataDirectory>/Default`: CEF ignores any other child `cache_path` for it (`cef_types.h`, `CefSettings.cache_path`). Other contexts must be direct children of the root: CEF loads a disk profile only when `cache_path`'s parent is `root_cache_path`, compared as strings, and otherwise silently makes an in-memory profile. `context(identifier:directory:)` names the folder through the resolved root (`/tmp` → `/private/tmp`) and refuses (returns nil, and asserts in Debug) a folder that is not a direct child: Chromium would keep that profile in memory as an off-the-record profile of the default profile. New `Engine/<dir>` folders get mode 0700. Asking for the default folder returns `defaultContext`, so two contexts never share one Chromium profile folder. |
| `browsers`, `allWebContents`, `webContent(identifier:)` | Live objects (weak registry) |
| `sampleProcessMetrics(after:)` | Chromium task manager rows: kind, memory, GPU memory, CPU |
| `showTaskManager()` | Chromium's task manager window (plans/page-platform.md EP-10a, D-8): runs `IDC_TASK_MANAGER_MAIN_MENU` through `CefBrowserHost::ExecuteChromeCommand` on the first live Chrome style page (a hosted tab's hidden window works). `false` when no live Chrome style page exists. A second call brings the open window to the front (Chrome's `TaskManagerView::Show`). |
| `isTracing`, `beginTracing(categories:)`, `endTracing(to:completion:)`, `cancelTracing()` | Performance traces (EP-11) over `CefBeginTracing` / `CefEndTracing`. `categories` nil = CEF's default categories. `isTracing` is true from a successful begin until the end or cancel callback; a second begin in that time returns `false`. `endTracing` writes Chromium's JSON trace (`traceEvents`) to the file and reports it (or an error) on the main thread; `cancelTracing` ends into a CEF temporary file and deletes it. CEF has no privacy filter: traces can contain page URLs. |

`OEEngineConfiguration`: `userDataDirectory`, `userAgentProduct` (leave nil: it replaces the `Chrome/<version>` token, and sites and extensions such as Bitwarden then take their Safari code path), `locale`, `defaultRuntimeStyle`, `remoteDebuggingPort`, `additionalSwitches` (OpenEngine always adds `MediaRouter` to `--disable-features`, merged with any list given here or on the command line: Cast is out of v1, so Chromium never starts Cast or DIAL discovery, shows no Cast button on `<video>` controls, and never asks for Local Network access; plans/page-platform.md §4.12, EP-12), `logFile`, `verboseLogging`, `keychainServiceName`, `keychainAccountName`, `useMockKeychain`.

The shell follows the profile layout of [plans/profiles.md](plans/profiles.md) §5-6 (`ProfileDirectories` in OpenStore): `userDataDirectory` = `ProfileDirectories.engineRoot` = `<root>/Engine`, the default profile is the global context at `<root>/Engine/Default`, and every other profile's context is `context(identifier: dir, directory: <root>/Engine/<dir>)`, created when a Space of that profile is first shown. Open's own per-profile files stay in `<root>/Profiles/<dir>/`. The launch step `OpenDataRoot.prepareEngineLayout` moves data from the older layout (`root_cache_path` = `<root>/Profiles`) before the snapshot loads and before the engine starts; if it cannot finish, that launch passes the old root and other profiles' contexts are not created (plans/profiles.md appendix). Mapping to the interface that plan assumed (§6.6):

| Plan | OpenEngine |
|---|---|
| E1 `contextHandle(forProfileID:cachePath:…)` | `context(identifier:directory:)` (cached by identifier; the default profile maps to `defaultContext`) |
| E2 `releaseContext(forProfileID:)` | `deleteContext(_:completion:)` / `try await deleteContext(_:)` for permanent deletion; `releaseContext` is only a page-close operation |
| E3 `makeWebContent(tabID:context:initialURL:)` | `OEWebContent(configuration:url:)` with `OEWebContentConfiguration(context:)`; the shell keys pages by `ItemID` |
| E4 context ready | Pages created before a context is ready wait inside the engine; no public flag yet |
| E5 ad-block hand-off | The `CefRequestContext` behind each `OEBrowserContext` (plans/adblock-fork.md §11) |
| E6 `makeIncognitoContext(windowID:)` | `makeIncognitoContext(for:completion:)` selects the regular parent; its primary OTR is shared until the last private Browser closes |

`OEEngineDelegate`: `engineDidInitialize()`, `engineWebContent(forUnownedOpenRequest:)` (Chromium opened a page on its own, for example an extension welcome page or `chrome.tabs.create` from a service worker: return a web content to show it as an Open tab; the engine closes Chromium's own window), `engineWillShutDown()`.

## OEBrowserContext (profile)

| Member | Notes |
|---|---|
| `identifier`, `directory`, `isEphemeral` | Ephemeral contexts are in memory only (incognito) |
| `originalContext`, `state` | A private context has its chosen regular parent. State is `.live` or `.closed`; retained closed wrappers and managers stay inert. Unknown native contexts never fall back to Default. |
| `extensions` | `OEExtensionManager` |
| `userScripts`, `addUserScript(_:)`, `removeUserScript(identifier:)`, `removeAllUserScripts()` | Boosts and Zap. `OEUserScript`: JavaScript or a style sheet, document start or end, Chrome match patterns, main frame only. New documents in every page of the context get changes at once. Main world only (patch P7). |
| `requestFilter` | `(OEResourceRequest) -> OERequestDecision`, called on the network thread for every request of the context, including service workers. Allowed requests get no per-request handler. |
| `permissionState(for:origin:)`, `setPermissionState(_:for:origin:)` | Chromium content settings for Site Control Center |
| `clearBrowsingData(origin:)` | With an origin: the host cookies of that URL's host, any path (`CefCookieManager::DeleteCookies` with a URL and no name; `Domain=` cookies stay), and nothing else: the HTTP cache is untouched. With nil: every cookie and the whole HTTP cache. Per-site cache clearing (Site Control E2) needs a fork patch: DevTools `Storage.clearDataForOrigin` has no HTTP cache type and CEF's `ClearHttpCache` clears every site. |
| `clearBrowsingData(_:from:to:completion:)` | Per-Profile Chromium history, cookies and site data, cached files, and download records, from begin through end, inclusive (Chromium semantics). Requires begin < end. Uses Chromium's browsing-data remover and reports its real completion or an error. Site data includes localStorage, IndexedDB, service workers and cache storage. Downloaded files and Open's separate HistoryStore are not removed by this API. |
| `websiteColorScheme` | `.automatic`, `.light`, `.dark` (EP-9a): Chrome's browser color scheme of the context's profile (`CefRequestContext::SetChromeColorScheme`, user color transparent). Chrome derives `prefers-color-scheme` from it (`GetPreferredColorScheme` in `chrome_content_browser_client.cc`); open pages update without a reload. Chrome keeps the value in the profile's prefs, so the first set always reaches Chromium, later sets only on a change. Chrome's default incognito policy follows device appearance. The setter also calls `CefSetWebsiteColorScheme` (fork 0505, EP-9b, #158/#164), which sets the web preference on both styles and after navigation. |
| `downloads`, `delegate` | `browserContext(_:decideDestinationFor:suggestedFilename:completion:)`, `browserContext(_:downloadDidUpdate:)`; `OEDownload` has state, bytes, speed, `cancel/pause/resume` |

`OEEngine.makeIncognitoContext(for:completion:)` rejects a null, uninitialized,
closed, closing, private, guest or system parent and policy-disabled standard
incognito. It never copies cookies or selects a different parent. Chrome owns
extension opt-in and spanning/split semantics through the selected primary OTR.

`OEEngine.deleteContext(_:completion:)` rejects Default and private contexts and
coalesces duplicate requests. It blocks new contexts/installs for the directory,
closes dependent pages, private children, popups and downloads, then waits for
`WIPE_PROFILE`. It invalidates every shell wrapper and releases CEF handles,
waits for an independent late Profile-destruction sentinel, removes the Local
State attributes and active/last-used entries, and commits Local State. Only a
successful completion permits `ProfileDirectories.deleteProfileData`. Errors
include disabled native unload, remaining keep-alive origins/counts, wipe
failure and timeout; they leave folders intact. No keep-alive is force-cleared.

Before `CefShutdown`, OpenEngine invalidates disk, private, Default and retained
retired wrappers after browser close callbacks, including the three-second
quit-deadline path. Automation builds can qualify that path without a blocked
renderer using `OPEN_AUTOMATION_QUIT_AT_DEADLINE=1`. The shutdown log records only
context counts and the selected path.

## OEBrowser (window tab strip)

One per shell window and profile. With fork patch P1 (docs/engine-patches.md) it owns a hidden Chrome window (`CefTabStrip`: a Chrome `Browser` with a `TabStripModel` and no Views), and every Chrome style page inserted here is one of its tabs, hosted in our view. `chrome.tabs` and `chrome.windows` see these tabs in `webContents` order (pinned first), with `activeWebContent` as the active tab. Alloy pages and pages that are not live are bookkeeping only. Chrome closes a window without tabs, so the hidden window goes away with the last live tab and the next tab gets a new one (and a new `chromeWindowIdentifier`).

| Member | Notes |
|---|---|
| `init(context:)`, `identifier`, `context`, `window`, `delegate` | `window` is the hidden window's native window: bounds and focus for `chrome.windows`, and the most recently focused window is the extensions' "current window" |
| `chromeWindowIdentifier` | The `chrome.windows` id, or -1 while the window has no live Chrome style tab |
| `webContents`, `insert(_:at:)`, `remove(_:)`, `move(_:to:)`, `setPinned(_:for:)`, `isPinned(_:)`, `activeWebContent` | Sidebar order: favorites, pinned, today. A page that closes leaves the strip by itself. |
| `extensionActions`, `extensionActionsReady` | `[OEExtensionAction]`: pinned actions in pinned order, then the rest. With a live model (`extensionActionsReady`) it is Chrome's toolbar model for the active tab (`ToolbarActionsModel`, `ExtensionActionViewModel`): every `chrome.action` setter and per-tab state. The live model needs the window's hidden Chrome window, which exists only while the window has a live Chrome style tab: a new window, or one whose tabs all sleep, has none. Then the list is the profile's (`isLive` false): pins, names, default titles and icons, no per-tab state, and pin changes made in other windows show at its next update. Nothing runs without the live model. The engine sends `browserDidUpdateExtensionActions` when the live model comes or goes. Empty until the profile's context is ready (an update follows). |
| `setExtensionAction(_:pinned:)`, `moveExtensionAction(_:toPinnedIndex:)` | Pin, unpin, and order: the profile's `extensions.pinned_extensions`, so every window of the profile gets `browserDidUpdateExtensionActions`. Pinning is idempotent. Unknown actions, unpinned moves, policy/incognito changes, and indices outside the real model's pinned range are refused with a diagnostic. Indices that cannot fit the engine's integer type are refused before conversion. Opening a standard window repairs duplicate pinned preferences left by older Open builds, preserving first occurrence and unloaded actions. A new install is pinned (Chromium's `ExtensionsPinnedByDefault`, on in Open). |
| `executeExtensionCommand(_:forExtension:)` | Runs an active command of this profile after flushing the window's pending tab sync. Action commands use `executeExtensionAction` with source `.command`; named commands grant `activeTab` as Chromium does and send `commands.onCommand` with the active tab. Unknown or inactive commands return `false`. In-window key routing belongs to the shell; Chromium's global registry is created for every profile. |
| `executeExtensionAction(_:source:)` | Runs the action as the user would (`.toolbarButton`, `.menuEntry`, `.command`): opens its popup, or fires `chrome.action.onClicked` when it has no popup for this tab, and runs scripts the extension asked to run on click. Running the action whose popup is open closes it. Returns `false` for an unknown id or without a live model. `executeExtensionAction(_:)` is `.toolbarButton`. |
| `extensionPopup`, `extensionPopupSource`, `extensionPopupExtensionIdentifier`, `closeExtensionPopup()` | The open popup (one per window), what opened it (`.user`, `.command`, `.api` for `chrome.action.openPopup()`), and its extension. Valid from `didOpenExtensionPopup` to `didCloseExtensionPopup`. While a popup is open, `chrome.action.openPopup()` fails with "Failed to open popup." (Chrome's desktop rule). The popup page's `close()` closes the popup; its `load(_:)` refuses any URL outside its own extension. |
| `extensionPopupStaysOpenOnBlur` | Chrome's rule for closing a popup on blur (`ExtensionPopup::CloseUnlessBlockedByInspectionOrJSDialog`): `true` while an app-modal JavaScript dialog shows, a web-modal dialog of the popup shows (WebAuthn, passkeys), or DevTools inspects the popup. Read it when the popup's panel resigns key and keep the panel open while it is `true` (plan rule D1). The shell's own JavaScript dialogs for tabs are not included. |
| `contextMenu(forExtensionAction:source:)` | `OEExtensionActionMenu`: Chrome's action context menu (`ExtensionContextMenuModel`) as `OEContextMenuItem`s (name, site access, options, remove, pin, manage, inspect popup). Show it, then call `select(command:)` (returns `false` if the menu was used or is gone, or the item is not an enabled item) or `cancel()` once. Each menu owns its Chrome model until then (or until it is released, the action goes away, or the live model goes away), so several menus can be open at once. Titles are Chromium's ("&&" comes as "&"): the shell relabels them (plans/extensions-ui.md §3.6). `source`: `.toolbarAction` or `.menuItem`. |
| `close()` | |

### Extension windows and omnibox

`OEEngineDelegate.engine(_:didOpenExtensionWindow:content:requestedFrame:extension:)`
delivers a popup's own `OEBrowser` and page outside Chromium observers. Retain
them, put `content.view` in an AppKit window, and set `browser.window`. The
requested frame uses Cocoa screen coordinates; zero means no explicit bounds.
`engine(_:extensionWindow:requestsFrame:focused:)` reports bounds/focus requests.
`chrome.windows.remove` calls the page delegate's `webContentDidRequestClose`.
The App's `ExtensionWindowController` owns the native frame and its
`ExtensionPopupWindow` autosave entry. Extension-created normal windows become
selected Today tabs in the active Open window of the profile; the API returns
that window's existing id (guess (lead)).

Each `OEBrowser` has one extension omnibox session:

| Call | Contract |
|---|---|
| `omniboxStartSession(forExtension:)` | Enabled keyword extensions only; repeated start does not resend the event. |
| `omniboxInputChanged(_:forExtension:completion:)` | Returns whether a listener exists. Completion is main-thread, at most once, and only for the latest text. Superseded completions are dropped; App async callers resolve them as nil on cancellation. |
| `omniboxDefaultSuggestion(forExtension:)` | Parsed `OEOmniboxSuggestion`, with literal `%s` placeholders for the shell to replace. |
| `omniboxInputEntered(_:forExtension:disposition:)` | Flushes pending tab sync and ends the session. Dispositions: current, new foreground, new background tab. The extension performs navigation. |
| `omniboxInputCancelled(forExtension:)` | Sends cancellation once per session. |
| `omniboxDeleteSuggestion(_:forExtension:)` | Sends the selected suggestion's exact content. |

`browser(_:omniboxDefaultSuggestionDidChangeForExtension:)` tells the shell to
refresh the current default row. Suggestions carry content, plain description,
UTF-16 match/dim/url ranges, and deletability. The bridge accepts at most four
async rows plus the default; text is capped at 16,384 UTF-16 units and style
ranges at 256 per row. Request ids are process-wide and never reused.

`OEBrowserDelegate`: `browserDidUpdateExtensionActions(_:)` (the list or the order changed: install, uninstall, enable, pin, move, model ready), `browser(_:didUpdate:)` (one action's state changed: icon, badge, title, enabled, wants-to-run, site access, popup shown, or the active tab changed; at most once per action per run loop turn; without this method the engine sends `browserDidUpdateExtensionActions` instead), `browser(_:didOpenExtensionPopup:for:)` (host `popup.view` in a panel at the button, hidden until ready), `browser(_:didResizeExtensionPopup:to:)` (Chrome's limits, 25×25 to 800×600), `browser(_:extensionPopupIsReady:)` (the popup's first load stopped: show it now, as Chrome shows its bubble), `browser(_:didCloseExtensionPopup:)` (`window.close()` in the popup, Escape, the action run again, `closeExtensionPopup()`, the active tab changed (as Chrome does), the extension unloaded, reloaded, updated or crashed, or the window closed; calls caused by `closeExtensionPopup()` and `executeExtensionAction` arrive inside them), `browser(_:requestsContextMenuForExtensionAction:)` (the user ran a disabled action: Chrome shows the action's context menu instead, so show `contextMenu(forExtensionAction:source:)` at its button).

Popup keys: `ExtensionViewHost`, not CEF, is the popup's `WebContentsDelegate`. Escape closes the popup inside Chrome. A popup's keys reach its `OEWebContentDelegate` like a tab's: `handleKeyEventBeforePage` first (`ExtensionViewHost` pre-handles keys through the hidden Browser's delegate, which is CEF's), then the page, then `handleUnconsumedKeyEvent` for keys the page did not consume. The shell must treat a popup's before-page keys as the popup's: a reserved shortcut there acts on the window otherwise (Cmd+W would close the tab; plan rule F2 closes the popup). A popup whose renderer crashed is gone: Chrome terminates the extension and its action leaves the list until the extension reloads, so the shell must not reload a popup page.

`OEExtensionAction` (P2 values): `extensionIdentifier`, `extensionName`, `title`, `accessibleName`, `tooltip`, `toolbarImage` (28 pt with 1x and 2x reps: icon, badge, disabled grayscale and the wants-to-run decoration, as Chrome's toolbar draws it), `icon` (16 pt plain icon, for menus), `badgeText`, `badgeBackgroundColor`, `badgeTextColor` (nil: automatic contrast), `isEnabled`, `hasPopup`, `isPinned`, `pinnedIndex` (-1 when unpinned), `wantsToRun`, `siteAccess` (`.none`, `.onClick`, `.onSite`, `.onAllSites`, `.blocked`, `.thisTab`: granted for this tab only, as after an `activeTab` click), `isShowingPopup`, `isLive` (from the live model; `false` for the profile's list). The images are shared: copy one before you change it. An image whose pixels did not change is the same object in the next snapshot (the engine copies raw pixels and compares a hash; no PNG encode or decode).

Browser close and deallocation first detach the strip's host view. This removes native key-window observers before Chromium unregisters its Browser, so closing the popup/panel cannot reactivate that Browser during asynchronous deletion.

Popup callbacks may request `closeExtensionPopup()`, `close()` or execute another action. During `didOpenExtensionPopup`, `didResizeExtensionPopup` and `extensionPopupIsReady`, OpenEngine defers those requests to the next main-queue turn. Chromium's `ExtensionViewHost` can then finish its callback before it is destroyed. A deferred popup close checks the popup's identity and never closes a replacement.

Action execution and action-menu construction flush pending tab-strip changes first. A toolbar click that focuses another Split View pane and runs an action in the same event uses that pane's Chromium tab.

The app-level `OEApplication.sendEvent` handler sees popup shortcuts before the before-page hook. Both paths use the window's command router; the reserved Archive Tab command closes a focused popup and keeps the tab. Unconsumed popup keys are recorded and offered to the same router with its existing duplicate-event guard.

Tab requests from Chromium (P1). The shell owns its tabs; Chromium's own changes arrive as requests, the shell applies them to its model, and the engine then puts Chromium's tab strip back in `webContents` order. All optional:

| Method | Chromium asks for | Default without the method |
|---|---|---|
| `browser(_:didOpen:active:)` | A page Chromium opened in this window (`chrome.tabs.create`, an extension's welcome or options page). It is live and not shown: set its delegate, show its view, insert it; or close it. `active`: select it. | The page is closed |
| `browser(_:requestsActivationOf:)` | `chrome.tabs.update({active: true})` | `activeWebContent` follows Chromium |
| `browser(_:requestsMoveOf:to:)` | `chrome.tabs.move`, as an index in `webContents` order | `move(_:to:)` |
| `browser(_:requestsPinned:for:)` | `chrome.tabs.update({pinned})` | `setPinned(_:for:)` |
| `browser(_:requestsDiscardOf:) -> Bool` | `chrome.tabs.discard(tabId)`. Return `true` if the shell will unload the tab with its own sleep; do not close it inside the call. Chromium never discards these tabs itself. | Refused |
| `browserRequestsClose(_:)` | `chrome.windows.remove` on this window while it has tabs. The window stays open. | Refused and logged |

`chrome.tabs.remove` and `window.close()` arrive as `webContentDidRequestClose(_:)`, as before. `insert(_:at:)` refuses a page of another profile, or a hosted tab of another window: tabs stay in their window. A browser whose context gets no hidden Chrome window (`CefTabStrip::Create` refused it) hosts its `.chrome` tabs as `.alloy` pages. Extension action popups are Chrome popups (P2): `chrome.extension.getViews({type: "popup"})` lists them, and their `chrome.tabs` calls see this window as the current window, so `query({active: true, currentWindow: true})` returns the shell's selected tab. A window without a live Chrome style tab opens no popup (no plain page with the manifest popup URL either: extensions such as Bitwarden do not work there).

## OEWebContent (page)

Creation and lifetime:

- `OEWebContent(configuration:url:)`. `OEWebContentConfiguration(context:)` has `runtimeStyle` (the engine's `defaultRuntimeStyle`; the shell uses `.chrome`), `backgroundColor`, `showsChromeToolbar`. A `.chrome` page that is in an `OEBrowser` when its Chromium browser is created becomes a hosted tab of that window (P1); its popups (`target=_blank`, `window.open`) join the same window. Any other `.chrome` page gets its own Chrome Views window glued over the view (the pre-P1 path). `.alloy` pages are content-layer pages that Chromium's tab APIs do not see.
- `view` is an NSView (flipped). Put it anywhere: several per window (Split View) or a panel (popups, extension popups). Moving a live page's view to another window is expected to work (Chromium follows its view) but is not tested yet. The Chromium browser is created when `view` first enters a window, so a tab that is never shown costs nothing (the shell restores only the selected tab at launch).
- `close()` destroys the Chromium browser; the object stays alive until Chromium confirms. A page whose last reference goes away without `close()` is closed too; its CEF view is parked so Chromium can finish.
- A hidden view (`isHidden` or a hidden ancestor) tells Chromium the page is hidden, which throttles it.
- `browser` (the `OEBrowser` it belongs to), `identifier` (unique per process, 0 until live), `chromeTabIdentifier` (the `chrome.tabs` id of a hosted tab, else -1), `isLive`, `isPopup`, `extensionPopupIdentifier`.

State (read the properties after `webContent(_:didChange:)`; the change set says what changed): `url`, `title`, `faviconURL`, `favicon`, `isLoading`, `estimatedProgress`, `canGoBack`, `canGoForward`, `isAudible` (Chromium's tab audio signal, "Media" below), `isMuted` (settable), `isFullscreen`, `crashState`, `isCapturingCamera`, `isCapturingMicrophone`, `statusText` (link hover), `zoomLevel` (settable). `.live` reports browser creation and destruction.

Commands: `load(_:)`, `goBack()`, `goForward()`, `reload()`, `reloadIgnoringCache()`, `stopLoading()`; `evaluateJavaScript(_:) async throws -> Any` (main world, awaits promises, user gesture); `sendDevToolsMethod(_:parameters:) async throws` (events go to `didReceiveDevToolsEvent`); `find(_:forward:caseSensitive:)`, `stopFinding(clearSelection:)`; `zoomIn()`, `zoomOut()`, `resetZoom()` (Chromium's preset steps; `resetZoom` also resets the pinch scale: CEF's reset runs `zoom::PageZoom::Zoom`, whose `PAGE_ZOOM_RESET` calls `WebContents::SetPageScale(1)` (`cef/libcef/browser/browser_host_base.cc:397`, `components/zoom/page_zoom.cc:81-83`), so page-platform EP-5 (Arc's `resetZoomAndScaleFactors`, PG-3.2) needs no extra call; e2e `page` Z2 checks it on a sidebar tab and on a Peek page); `showDevTools()`, `closeDevTools()`, `hasDevTools`; `showDevTools(panel:)` (EP-4a: `.console` runs Chrome's `IDC_DEV_TOOLS_CONSOLE` and `.inspectMode` runs `IDC_DEV_TOOLS_INSPECT` (element picker; a second call turns it off) through `ExecuteChromeCommand` on Chrome style pages, ids from `cef_id_for_command_id_name`; `.elements`, `.network` (EP-4b) and `.console` where Chrome's command cannot run (a hosted tab that is not Chromium's active tab in the hidden strip, Alloy pages) open DevTools and select the panel through the front end's `DevToolsAPI.showPanel`, retried until selected (at most 15 s); `.default` opens DevTools as `showDevTools()` does; returns NO only for that plain fallback); `evaluateInDevToolsFrontend(_:)` (diagnostics: `Runtime.evaluate` in the page's open DevTools window, the front end, which OpenEngine tracks through its DevTools window client); `showPrintPanel()`, `printToPDF(at:)`; `takeSnapshot() async throws -> Data` (PNG of the visible page, also when hidden); `captureFullPage(maxDevicePixels:completion:)` (whole page, below); `enableAutoResize(minimumSize:maximumSize:)`; `focusPage()`; `exitFullscreen()`.

`OEWebContentDelegate` (all optional, all on the main thread):

| Method | Use |
|---|---|
| `webContent(_:didChange:)` | Observable state changed |
| `webContent(_:createWebContentFor:)` | `target=_blank`, `window.open`, Cmd-click, middle click. Return a new page (put its view in a window now) or `nil` to block. `OEOpenRequest`: url, disposition (`newForegroundTab`, `newBackgroundTab`, `newPopup` for sized `window.open`, `newWindow`, ...), user gesture, requested frame, opener, context. |
| `webContentDidRequestClose(_:)` | `window.close()` |
| `webContent(_:handleKeyEventBeforePage:)`, `webContent(_:handleUnconsumedKeyEvent:)` | Keyboard, above |
| `webContent(_:runJavaScriptDialog:)` | `alert`/`confirm`/`prompt`/`beforeunload`. Return `true` and call `complete(accepted:text:)` later. An unanswered dialog is cancelled when released. |
| `webContent(_:decidePermissionRequest:)` | Camera, microphone, screen, notifications, geolocation, ... `grant()`, `deny()`, `dismiss()` |
| `webContent(_:showContextMenu:)` | `OEContextMenu`: targets, media type, location, link, source, selection, spelling, and Chromium's own items (including extension items), filtered by Open's allowlist ("Context menu items" below). Show our NSMenu and call `select(command:)` or `cancel()`. |
| `webContent(_:didUpdateFindResult:)` | Match count, active index |
| `webContent(_:didRequestFullscreen:)` | HTML fullscreen: hide the sidebar |
| `webContent(_:didRequestContentSize:)` | Auto-resize (Peek-style panels) |
| `webContent(_:didFinishLoadWithStatus:)`, `webContent(_:didFailLoadWithError:)` | Main frame |
| `webContent(_:didReceiveDevToolsEvent:parameters:)`, `webContent(_:didLogConsoleMessage:level:source:line:)` | Diagnostics, automation |

### Tab sleeping (memory fork)

The engine half of [plans/memory-fork.md](plans/memory-fork.md): honest visibility, freeze, discard in place, and capture/restore of the back/forward list. The shell owns all policy (`OpenSleep`); these calls only do what they are told. They work for hosted tabs (Chrome style pages in an `OEBrowser`, the shell's tabs) and Alloy pages. All are main-thread calls on a live page; on a page that is not live they return `false`/`nil`.

| Member | Notes |
|---|---|
| `setPageHidden(_:)` | `CefBrowserHost::WasHidden`. The view's hidden state already reports this (a background hosted tab is `document.visibilityState == "hidden"`); use it when a page's view stays in a visible window. Fork patch 0101 (Alloy windowed) and 0302 (Chrome style) make it reach `WebContents::UpdateWebContentsVisibility`. |
| `setPageFrozen(_:) -> Bool`, `isPageFrozen` | Depth 1. Only a hidden page can be frozen (`false` for a visible or discarded page). Showing the page unfreezes it; `isPageFrozen` follows. |
| `discard() async -> Bool` (`discardWithCompletion:`), `isDiscarded` | Depth 2, in place: the renderer and frame tree go; the `OEWebContent`, its history and its `chrome.tabs` id stay, and the page reloads from its entry when shown (`document.wasDiscarded` is true for that load). Refused for a visible page. The completion runs exactly once with the re-check of `isDiscarded` (memory-fork D-5): `false` means still live, keep the tab frozen and retry later. A navigation about to commit makes Chromium ignore a discard; the engine retries once after 100 ms. Needs the `WebContentsDiscard` feature, which OpenEngine turns on. `isDiscarded` is true from the discard (or a history restore) until the page starts loading again. |
| `hasUnloadHandlers` | The page has `beforeunload`/`unload` handlers (sleep policy keeps such pages frozen, never discarded). |
| `captureNavigationHistory() -> OENavigationHistory?` | The whole back/forward list with scroll and form state, read in the browser process (works for frozen, discarded and crashed pages, and at quit). Page state is dropped when the list would not fit 2 MiB with it (`hasPageState` false); `nil` if it does not fit without it, or nothing was committed. |
| `init(configuration:navigationHistory:fallbackURL:)`, `navigationHistoryRestore` | A page that comes up with a history instead of a URL: its Chromium page is created (when the view enters a window) with no renderer process, the history is installed before it can show, and the current entry loads when it becomes visible. `.restored` on success. If an entry does not decode (the pickles are tied to the Chromium version) or the page is a Views-window Chrome page, it loads `fallbackURL` (default: the history's `currentURL`) and reports `.failed`; log `sleep-restore-fallback`. |

`OENavigationHistory` is Open's OPNH v1 container (memory-fork §7.1), byte-identical to `SleepHistoryContainer` in OpenSleep: `init(container:)` validates it whole (nil on any violation, never a partial history); `container`, `entryCount`, `currentIndex`, `hasPageState`, and for a capture `currentURL`, `title`, `faviconURL` (store these as sidecars; a history parsed from stored bytes has none). Immutable and `Sendable`.

Engine switches (memory-fork §10, browser process, `OEApp.mm`): `--enable-features` gains `WebContentsDiscard`; `--disable-features` gains `OptimizationHints`, `OptimizationTargetPrediction`, `OptimizationGuidePageContentExtraction`, `OptimizationGuideModelExecution`, `SegmentationPlatform`, `SegmentationPlatformUkmEngine`, `MediaRouter`, `TranslateRankerQuery`, `TranslateRankerEnforcement` (each string read from its `BASE_FEATURE` in the tree). On Macs with 8 GB or less, `--renderer-process-limit=32`. Both lists are merged with values the shell passes in `additionalSwitches`.

The fork API under these calls is C++ free functions in two overlay headers, not `CefBrowserHost` methods: `cef_page_lifecycle.h` (`CefSetPageFrozen`, `CefIsPageFrozen`, `CefDiscardBrowser`, `CefWasDiscarded`, `CefHasUnloadHandlers`) and `cef_navigation_history.h` (`CefNavigationHistory`, `CefGetNavigationHistory`, `CefRestoreNavigationHistory`), plus `CefBrowserSettings.no_renderer` (patch 0105) and `CefNavigationEntry::GetReferrerURL`/`GetFaviconURL` (patch 0104). See [engine-patches.md](engine-patches.md), "Tab sleeping".

### Page selection and history swipe (page-platform EP-1, EP-2, EP-3)

Fork API `cef/include/cef_open_page.h` (docs/engine-patches.md, "Page platform"). Every page gets a page handler when its browser is created.

- `hasSelection` and `OEWebContentChangeSelection` (`1u << 15`): the page's text selection became empty or non-empty (input selections; a script-only selection that never reaches the browser's text input state does not count). Not sent for caret moves.
- `requestSelection(completion:)`: the focused frame's selected text and a link that scrolls to it (the page URL plus Chromium's text-fragment directive, with prefix/suffix context when the text is not unique). `link` is nil for a selection in a child frame or when the generator fails. The completion runs exactly once.
- `historySwipeEnabled` (default YES; NO makes Chromium's swiper ignore gestures on this page) and `drawsEngineHistorySwipeOverlay` (default YES; NO hides Chromium's arrow). Delegate `webContent(_:historySwipe:direction:progress:)`: began / changed / completed / cancelled, back or forward, progress 0…1. Completed arrives after the navigation started.
- `simulateHistorySwipe(direction:progress:)`: test hook (engine switch `--open-automation`); replays the overlay sequence and the navigation; NO when swipes are off or the page cannot go that way.

### Notifications (page-platform EP-6, EP-7)

- `OEBrowserContextDelegate.browserContext(_:didClickNotification:origin:persistent:)`: a web notification of the context was clicked (body or button), before Chromium dispatches the click to the page. No page is reported; find the tab by origin.
- `OEBrowserContext.displayedNotifications(completion:)` and `simulateClickOnNotification(identifier:)`: test hooks, active only with `--open-automation` (otherwise an empty list and NO). The list is the display-service observer's set (`Engine/fork/src/open/browser/page/open_notifications.cc`, #160), independent of macOS delivery. Each item has id, origin, title and body.

### Context menu items

A Chrome style page gets Chrome's full page context menu. OpenEngine keeps only the items on an explicit allowlist (`Engine/OpenEngine/src/OEContextMenuAllowlist.mm`, applied in `OEClient::OnBeforeContextMenu`). It then removes empty submenus and extra separators. An item a later Chromium adds stays hidden until it is added to the list. Alloy style menus are CEF's short list and are not filtered. The shell adds Open's own items (Capture, Share, Copy URL, Little Open, Split View, and Arc's "Manage Extensions", EX-18) to what remains. `select(command:)` runs only the id of an enabled item in the delivered `items` (submenus included); any other id is refused, logged, and the menu is cancelled, because CEF would run it directly without checking the list. Alloy pages (Peek; CEF's short list, by design) are not filtered. Extension windows use hosted Chrome style pages and the same allowlist.

Kept (Chromium `IDC_*` ids):

| Target | Items |
|---|---|
| Page | Back, Forward, Reload, Reload Frame, Exit Full Screen, Save As…, Print…, View Page Source, View Frame Source, Inspect, Inspect background page (extension pages) |
| Link | Open Link in New Tab, Open Link in New Window (both become Open tabs through P1), Open Link With (the page's protocol handlers), Save Link As…, Copy Link Address, Copy Link Text |
| Image | Open Image in New Tab, Open Original Image in New Tab, Load Image, Save Image As…, Copy Image, Copy Image Address |
| Audio, video, plugin | Loop, Show All Controls, Picture in Picture, Open Video/Audio in New Tab, Save Video/Audio As…, Copy Video/Audio Address, Video Frame (Copy, Save), Save plugin as, Rotate |
| Selection | Copy, Go to <URL>, Copy Link to Highlight, Remove Highlight, Reshare Highlight, Look Up |
| Editable | Undo, Redo, Cut, Copy, Paste, Paste and Match Style, Delete, Select All, Emoji & Symbols, Start Dictation; spelling suggestions, Add to / Remove from Dictionary, No Suggestions, Spelling and Grammar (submenu) |
| Passwords | Select Password, Use a Passkey from Another Device (Chromium's own fill UI stays: plans/passwords-autofill.md D-3) |
| macOS | Speech and Writing Direction submenus |
| Others | Items the page adds and items extensions add (`chrome.contextMenus`) |

Removed, and why (all seen in Open before this list, Chromium 156):

| Item | Why |
|---|---|
| Cast… | Chrome's Cast dialog anchors to a toolbar that Open's hidden window does not have. Open's Cast entry is View ▸ Cast… (Arc: docs/re/page-platform.md PG-12). |
| Open in Reading Mode | Chrome's Read Anything side panel; Open has no Chrome side panels (Chromium patch 0302 only keeps it from crashing in hidden windows). |
| Create QR Code for this Page / Image / Link | Chrome's QR code bubble anchors to the toolbar (Chromium patch 0301 removes its controller without a toolbar). |
| Search Image / Video Frame with Google, Google Lens items, Translate Image | Google Lens and its side panel or overlay. |
| Translate to …, Translate selection | Chrome's translate bubble needs Chrome's toolbar; Open's own translation UI is planned (plans/page-platform.md, Arc PG-7). |
| Open Link in Split View | Chrome's split tabs; Open's Split View has its own item (shell). |
| Open Link in Incognito Window, Open Link as <profile> | Chrome windows and Chrome profiles; Open's windows and profiles are its own. |
| Send to Your Devices, Shared clipboard, Add to Reading List, Follow/Unfollow | Sync, sign-in and Chrome features Open does not have. |
| Import Passwords, Suggest Strong Password, Show All Passwords | Chrome's password manager pages; generation is off (plans/passwords-autofill.md D-7). |
| Language Settings, Protocol handler settings, Page Info | Chrome settings pages and bubbles. |
| Search <engine> for “…” (current or new tab) | It uses Chromium's default search engine (Google), not the search engine of the page's profile. App-shell Step D adds Open's own "Search <engine> for “…”" item (`docs/followups.md`). |
| Get Image Descriptions from Google, Live Caption, PDF OCR, Listen to This Page, Gemini, Ask Google, Compose, AI items | Google services and AI (out of v1 scope). |

### Media (`OEMediaSession`)

From the fork's `CefMediaController` (overlay `cef/include/cef_media_controller.h`, `open/browser/media/open_media_controller.cc`; docs/engine-patches.md "Media"). OpenEngine attaches it to every page in `OnAfterCreated`; it works for Chrome style and Alloy pages and covers all frames.

- `isAudible` is Chromium's tab audio signal (`WebContentsObserver::OnAudioStateChanged`, patch P6): media elements, Web Audio and WebRTC, background pages too. `.audio` fires on every change. There is no page probe any more.
- `mediaSession` (`OEMediaSession`, a snapshot; nil until a player of the page has played, and again when none is playing or paused mid-way). `.media` fires at most once per message-loop turn and only for a real change: state, actions, metadata, a seek, a rate or duration change, the end. A position report that only continues the clock is not a change; read `position` (`OEMediaPosition`: duration, `INFINITY` for live; position at `lastUpdated`; rate; ended) and extrapolate. `.pictureInPicture` fires when a video of the page enters or leaves PiP.
- Values: `playbackState` (from the players: playing if one plays, paused if one played and stopped before its end), `isControllable` (Chromium's media session: a player with sound that is not a short effect or a MediaStream; while the tab is muted Chromium leaves its players out of the session, so the session part (controllable, actions, metadata, position, microphone, camera) keeps its last unmuted value), `hasVideo`, `hasAudio`, `largestVideoSize` (natural size in video pixels of the playing video with the largest natural area, not CSS px), `isPictureInPictureDisabled` (that video's own availability report: `disablePictureInPicture`, no video track yet, or permissions policy), `actions` (the session's actions and the page's handlers; `enterPictureInPicture` when the largest playing video can enter PiP, `exitPictureInPicture` while in PiP, `enterAutoPictureInPicture` when the page handles `enterpictureinpicture`), `title`/`artist`/`album` (Chromium fills the title from the page when the page sets no metadata), `microphoneMuted`, `cameraOn`, `volume`.
- Commands (`play`, `pause`, `stop`, `previousTrack`, `nextTrack`, `seek(by:)`, `seek(to:)`, `scrub(to:)`, `skipAd`, `toggleMicrophone`, `toggleCamera`, `hangUp`) go to Chromium's media session, which routes them to the page's action handlers when it has them. A session that is not controllable (muted tab, MediaStream-only page) gets play, pause, stop and seeks on its players directly. Track, ad, slide and meeting actions always go to the session, which routes them to the page's handler even when it is not controllable: a meeting page (camera or microphone streams only) is never controllable, and its recording card's toggles still reach the page.
- `mediaVolume` (settable, 0...1, default 1, not persisted): a tab volume that Chromium's media session multiplies into every player's volume, players added later too (chromium/0401). The page's own `element.volume` does not change. Web Audio is not a session player and is not affected; use `isMuted` for silence.
- `requestPictureInPicture(completion:)` enters video PiP for the largest playing video (`largestVideoSize`) from the browser, so no user gesture is needed. It fails at once for a video that cannot enter PiP (Blink's browser-initiated path does not check `disablePictureInPicture`, so the engine checks the player's availability first). Completion YES when the page is in PiP, NO otherwise after at most 2 s (Chromium has no direct reply). `exitPictureInPicture(pausing:)` closes this page's PiP window only (one app-wide): without pausing as Chromium's own exit, with pausing as the user's close.
- Open's own PiP window (EM-4, `OEPictureInPicture.h`). While `OEEngine.pictureInPictureDelegate` is set (`supportsShellPictureInPicture` is YES), video PiP opens in the App's window instead of Chromium's.
  - `pictureInPictureDidOpen:` is synchronous, inside Chromium's session start. The App makes its window there, puts `videoView` in it and sets `windowFrame`, because Chromium reads the window size for the renderer right after.
  - `videoView` shows the video. It is a layer-hosting view with the engine's compositor and takes no mouse events.
  - The App's controls call the commands (`togglePlayPause`, `seek(to:)`, `setMuted:`, the track, slide and meeting actions, `close(pausingVideo:)`).
  - `pictureInPicture:didChange:` reports the changed parts (natural size, playback, controls, position, title, meeting state, muted), at most once per turn.
  - `pictureInPictureDidClose:` follows every end (the App's close, the page, a navigation, a crash, a new PiP, the tab closing). Afterwards the object is invalid and its commands do nothing.
  - Chromium keeps its own rules: one PiP app-wide; close on navigation, crash and destruction; "user closed" bookkeeping for auto-PiP (the close goes through `ExitPictureInPictureViaWindowUi`).
  - Without a delegate (phase 1), the window is Chromium's own (`VideoOverlayWindowViews`).

### Page background color

TODO(engine): `OEWebContent` has no page color yet. The M4 split pane bar needs one (`WebContentHost.pageBackgroundColor` and `onPageBackgroundChange` in OpenFeatures). Arc paints each pane's 32 pt bar in the page's own color (F0081: lavender page → `#DEDEFA` bar, white page → white bar; `re/interaction-states.md` §11). The color is not the pixels under the bar, so the engine must report it: the page's `theme-color` or its document background (guess: which one Arc uses). Report it as a state change after the URL change of the same navigation, and again when the page changes it. The App adapter now performs a guarded renderer query after loading ends and emits `onPageBackgroundChange`: valid theme-color, then a nontransparent body/root background, then white. That priority is an App fallback policy, not a confirmed Arc rule. The Space color remains the fallback before the answer. Changes without another loading-end event are not observed yet; a real engine color event is still needed.

### Full-page capture (EP-8)

`captureFullPage(maxDevicePixels:completion:)` (Swift: `OEWebContent.fullPagePNG(maxDevicePixels:)` through OpenWeb) returns one PNG of the whole page at device scale and `truncated`. OpenEngine only, no fork patch (page-platform plan §6 EP-8, Arc's `captureFullPage:`, PG-6.3):

1. DevTools `Page.getLayoutMetrics` → `cssContentSize` (CSS pixels; the same size Chromium's own full-page path uses, `LocalFrameMojoHandler::GetFullPageSize`).
2. Device scale = one visible-page `Page.captureScreenshot`'s pixel width ÷ the page view's width in points. That follows the window's backing scale and DevTools device emulation (`Emulation.setDeviceMetricsOverride`), which the screenshots follow; `contentSize` from the layout metrics does not (it stays in CSS pixels on the Mac, also under emulation). Fallback: the window's backing scale, else the main screen's. Width is capped at 4,096 device pixels; height at `maxDevicePixels` (the App passes `CaptureMetrics.fullPageMaxDevicePixels` = 32,768). A taller page is cut there and `truncated` is YES.
3. One `Page.captureScreenshot` per tile, top to bottom: `format: png`, `fromSurface: true`, `captureBeyondViewport: true`, `clip: {x: 0, y, width, height ≤ 4,096 / scale, scale: 1}` in document CSS pixels. Each call temporarily resizes the widget and restores it (`PageHandler::CaptureScreenshot`), so tiles run one at a time.
4. The tiles are decoded, drawn top-down into one sRGB bitmap with Core Graphics, and encoded to PNG on a utility queue; only `NSData` crosses threads. Worst allocation: 4,096 × 32,768 × 4 B = 512 MiB. The completion runs on the main thread.

The caller makes lazy images load first (`img[loading=lazy]` → `eager`, wait ≤ 1 s) through `evaluateJavaScript`; the engine call itself does not change the page. Page zoom is not applied to the clip (Chromium's own full-page capture does the same).

## Extensions

`OEExtensionManager` is per `OEBrowserContext`, including non-default profiles. P3 uses Chromium's live `ExtensionRegistry`, `ExtensionRegistrar`, `CommandService`, and `ExtensionSystem::ready()`. There is no Preferences reader, folder watcher or polling timer. Snapshots are cached until registry/command events; they do not wait for Chromium to write its preferences.

| Member | Behavior |
|---|---|
| `isReady`, `installedExtensions`, `extension(identifier:)` | Non-component installed extensions, including disabled ones, sorted by name. `OEExtension` has id, name, version, summary, manifest version, enabled, unpacked, directory, icon, options URL, required permissions/hosts, `hasAction`, `fromWebStore`, `homepageURL`, `disableReasons`, and `omniboxKeyword`. The command bar filters disabled extensions before it exposes keywords. |
| `setEnabled(_:forExtension:)` | Disable/enable through the registrar. Re-enabling an extension disabled for increased permissions first asks for Chromium's re-enable consent; it never grants those permissions silently. |
| `uninstallExtension(_:window:)` | Shows removal consent first. Cancel keeps the extension; accept uses Chromium's uninstall dialog controller. |
| `reloadExtension(_:)` | Registrar reload, including its normal load-error reporting. |
| `install(fromWebStore:window:completion:)` | `WebstoreInstallWithPrompt`; reports success/error once on the main thread and uses the same consent hook as a hosted Web Store tab. An install owns a dummy requestor through completion; a narrow CEF hook lets its internal CRX download proceed without a CEF browser. No browsing page is used as a referrer. Duplicate ids, more than 32 pending requests, and ephemeral profiles fail explicitly. |
| `commands` | Active named and action commands with shortcuts: `OEExtensionCommand` (`extensionIdentifier`, `name`, `summary`, Cocoa `keyEquivalent`/`modifierFlags`, `isGlobal`, `isActionCommand`). Chromium's Cocoa pair uses uppercase letters for Shift (`"Y"` + Command is Command-Shift-Y); key routers must account for that implied Shift. `OEExtensionAction.shortcutKeyEquivalent` and `.shortcutModifierFlags` carry the action command's shortcut too. |
| `reload()` | Invalidates the live snapshot and notifies observers; no disk read. |
| `managementPageURL`, `webStorePageURL(extensionIdentifier:)` | The existing management and store URLs. |
| `installLocalCRX(_:webContent:)` | Automation hook, only with the engine's `--open-automation` switch. A real local CRX3 goes through `CrxInstaller` and its consent prompt. This is the network-free install gate. |
| `installLocalCRX(_:completion:)` | Automation-only 0704 completion. Exactly once on a later main-queue turn: `OEExtensionInstallResult.installed` with extension ID, `.cancelled` with neither ID nor error, or `.failed` with Chromium's error text (including `CRX_SIGNATURE_VERIFICATION_FAILED`). Rejected requests and context closure also complete. No requesting page is required; consent uses this manager's profile presenter. At most 32 local requests may be pending; file paths are capped at 4,096 UTF-8 bytes and error text at 65,536 UTF-16 units. Completion may close/replace the context. This result does not use the delegate; Web Store installs keep their existing completion. |

Optional delegate events: `extensionManagerDidChange(_:)`, `extensionManagerDidBecomeReady(_:)`, `extensionManagerDidChangeCommands(_:)`, `extensionManager(_:didInstall:byUser:)`, and `extensionManager(_:didFailToLoadExtensionAt:error:)`. Events arrive on the main thread outside Chromium model notifications. Callbacks may close/replace their context or window. Managers must be released on the main thread.

`extensionManager(_:show:)` receives an `OEExtensionPrompt`: type, extension id/name/icon, Chromium's title and button labels, permission messages with details, retained files/devices, optional triggering extension name, and weak requesting page/browser references. Accept/cancel settle once, on a later main-loop turn; releasing an unanswered prompt cancels. Chromium 156's `InstallPromptData` has no retained-file/device fields, so those two arrays are empty in this build. Permissions requests and uninstalls can supply only a native window: `webContent` is then nil and `browser` is the owning window when CEF can resolve it. Otherwise the presenter chooses a window of the manager's profile.

**Fallback:** if the delegate does not implement `extensionManager(_:show:)`, the existing Chromium install and uninstall dialogs run unchanged. Install, external/remote install, repair, optional permissions and re-enable share the install hook. Removal uses an `ExtensionUninstallDialog` implementation. The shell supplies the Open text/layout from extensions-ui §3.11; raw Chromium labels remain available for its repair/triggering-extension cases.

P2 menu objects must be answered and released on the main thread. Menu ids are process-wide and never recycled, so a menu from a destroyed hidden Browser cannot select or release a newer menu. Removed extensions' image-cache entries are dropped. Same-document navigation does not refresh action images; a selected-tab change invalidates the snapshot without a duplicate list-change rebuild.

## Known gaps in stock CEF

Each has a fork patch in [engine-patches.md](engine-patches.md):

| Gap | Today | Patch |
|---|---|---|
| `chrome.tabs`/`chrome.windows` do not see Alloy pages | Fixed by P1 for Chrome style pages (the shell's default) | P1, done |
| Pages that extensions open | Fixed by P1: adopted as Today tabs with their identity and opener | P1, done |
| Dynamic action state | Fixed by P2: Chrome's toolbar model (icon, badge, title, enabled, pin, order, context menu, `onClicked`) and real popup hosts (`getViews({type: "popup"})`, `chrome.action.openPopup()`). P3 adds commands/shortcut fields; App #189 routes in-window keys and draws native strips/panels. | P2/P3 and App, done |
| Install, uninstall, enable from our UI; our own consent prompts | P3 exposes live management and optional shell consent (#177). App #189 supplies Open sheets/queue/toasts. Chromium dialogs remain only without a shell handler. Packed permission-increase update/re-enable acceptance remains unverified. | P3 and App, implemented |
| H.264, AAC, Widevine | Not in stock CEF | P4 |
| Audible state for Web Audio | Fixed: Chromium's tab audio signal through `CefMediaController` (no page probe) | P6, done |
| Media session, tab volume, PiP without a gesture | Fixed: `OEMediaSession`, `mediaVolume`, `requestPictureInPicture` from the fork's `CefMediaController` | media 0401, done |
| User scripts in an isolated world | Main world | P7 |

## Debugging crashes

The CEF framework is stripped. CEF publishes the matching symbols: `https://cef-builds.spotifycdn.com/cef_binary_<version>_macosarm64_release_symbols.tar.bz2` (2.1 GB for 156.0.14). Check the UUID with `dwarfdump --uuid` against the crash report's image UUID, then `atos -o "<dSYM>/Contents/Resources/DWARF/Chromium Embedded Framework" -arch arm64 -l 0x0 <imageOffset>...` with the offsets from the `.ips` report. Chromium's zombie detector (`CrZombie` in a stack) means a message to a freed Objective-C object.

Chrome page-menu filtering removes invisible items before delivery. The execution
allowlist contains only delivered, enabled leaf commands and does not descend
through a disabled submenu. An invisible item or an enabled child under a
disabled parent therefore cannot be selected through OpenEngine.

## Section 8 API index (merged)

The public contract is `Engine/OpenEngine/include/OpenEngine/`. Implementations
are in `Engine/OpenEngine/src/`. The tables above give behavior and limits.

| PR | Header | Added surface |
|---|---|---|
| [#154](https://github.com/SergeSerb2/open/pull/154) | `OEWebContent.h` | `captureFullPage(maxDevicePixels:completion:)`: tiled PNG and truncation result (EP-8). |
| [#158](https://github.com/SergeSerb2/open/pull/158) | `OENavigationHistory.h`, `OEWebContent.h` | OPNH container/metadata; history initializer, `navigationHistoryRestore`, `captureNavigationHistory`, `setPageHidden`, `setPageFrozen`, `isPageFrozen`, `discard(completion:)`, `isDiscarded`, `hasUnloadHandlers`. |
| [#158](https://github.com/SergeSerb2/open/pull/158) | `OEWebContent.h` | `OEWebContentChangeSelection`, `hasSelection`, `requestSelection(completion:)`; swipe direction/phase enums, `historySwipeEnabled`, `drawsEngineHistorySwipeOverlay`, historySwipe delegate and `simulateHistorySwipe`. |
| [#158](https://github.com/SergeSerb2/open/pull/158) + [#160](https://github.com/SergeSerb2/open/pull/160) | `OEBrowserContext.h` | Notification click delegate, `displayedNotifications(completion:)`, `simulateClickOnNotification(identifier:)`. Test hooks require `--open-automation`. [#160](https://github.com/SergeSerb2/open/pull/160) fixes the observer list and persistent kind; no new public method. |
| [#164](https://github.com/SergeSerb2/open/pull/164) | `OEWebContent.h` | `OEDevToolsPanel`, `showDevTools(panel:)`, `evaluateInDevToolsFrontend(_:completion:)`; front-end client tracking, bounded panel selection retries. |
| [#164](https://github.com/SergeSerb2/open/pull/164) | `OEBrowserContext.h` | `OEColorSchemePreference`, `websiteColorScheme` (wired to fork 0505), `clearBrowsingData(origin:completion:)` (host cookies; nil clears all cookies/cache). |
| [#164](https://github.com/SergeSerb2/open/pull/164) | `OEEngine.h` | `showTaskManager`, `isTracing`, `beginTracing(categories:)`, `endTracing(to:completion:)`, `cancelTracing`; MediaRouter always disabled in additionalSwitches handling. |

[#163](https://github.com/SergeSerb2/open/pull/163) uses existing `resetZoom` for EP-5: it already resets pinch scale.
[#152](https://github.com/SergeSerb2/open/pull/152)/[#153](https://github.com/SergeSerb2/open/pull/153)/[#156](https://github.com/SergeSerb2/open/pull/156)/[#162](https://github.com/SergeSerb2/open/pull/162)/[#163](https://github.com/SergeSerb2/open/pull/163) add App/OpenKit behavior over these APIs.
[#149](https://github.com/SergeSerb2/open/pull/149) adds relaunch evidence, not a public API. G2 App sleep integration
merged in [#165](https://github.com/SergeSerb2/open/pull/165); e2e `sleep` F0/F2/F4/F5 prove the App paths.
`sleep_f3_capture` remains BLOCKED without a camera/mic grant.
