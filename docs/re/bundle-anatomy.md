# Arc 1.170.0 — Bundle anatomy

Target: Arc 1.170.0 (build 89123, commit `9f5625b3`), bundle ID `company.thebrowser.Browser`, engine `ArcCore.framework` 156.0.8078.48 (Chromium branch 8078, `SCMRevision 2882d35e…-refs/branch-heads/8078@{#1314}`).

Method note. Every claim cites the command and the symbol, string, or file that proves it. Raw output is in `.re/architecture/` (git-ignored). Two `rea` calls failed and this report does not rely on them:

- `rea inspect-native-dispatch-metadata .re/bin/Arc-arm64 --max-records 5000` failed: "Apple static metadata input exceeds its 64 MiB snapshot budget" (80 MB binary). Swift/ObjC metadata here comes from `nm`, `otool`, `strings`, and `xcrun swift-demangle` instead.
- `rea inspect-asset-catalog` and `rea decode-interface-builder` rejected `.car` / `.nib` files as "unsupported binary format". Asset data here comes from `xcrun assetutil --info`.
- The shared Ghidra project was not usable: `.re/logs/ghidra-arcmain.log` ends with "Path element starting with '.' is not permitted". No decompilation was used.

Evidence commands used: `rea inspect-macho` (`.re/architecture/inspect-macho-arc.json`), `otool -L/-l/-o`, `size -m`, `nm`, `strings`, `xcrun swift-demangle`, `xcrun assetutil --info`, `plutil -p`, `codesign -d --entitlements -`, `du`, `md5`, `find`, `ls`.

## 1. Top-level layout

Evidence: `ls -la /Applications/Arc.app/Contents/`, `du -sh`, `plutil -p Contents/Info.plist`.

| Path | Size / fact | Notes |
|---|---|---|
| `Contents/MacOS/Arc` | 158 MB, Mach-O universal x86_64 + arm64 (`lipo -info`) | Swift main executable. `NSPrincipalClass = Arc.BrowserApp`. |
| `Contents/Frameworks/ArcCore.framework` | 591 MB (`du -sh`) | Chromium fork. See §2. |
| `Contents/Frameworks/*.framework` (7 others) | 96 KB–4.3 MB each | Thin shims + Lottie + Sparkle. See §3. |
| `Contents/Frameworks/libswiftCompatibilitySpan.dylib` | 184 KB | Weak-linked Swift compatibility shim (`otool -L` shows `@rpath/libswiftCompatibilitySpan.dylib … weak`). |
| `Contents/Resources/` | 109 MB (`du -sh`), 144 entries | 83 SwiftPM resource bundles + `Assets.car` + one nib + localizations. See §5. |
| `Contents/PlugIns/DockTilePlugIn.plugin` | tiny (114 KB thin slice, `size`) | Dock tile. See §4. |
| `Contents/Info.plist` | version 1.170.0 / 89123 | `LSMinimumSystemVersion 13.0.0`, SDK macosx26.4, Xcode 17E202. URL schemes: `http`, `https`, `mailto`, `arcBrowser`. Document types: PDF, HTML, XHTML (Viewer). |
| `Contents/embedded.provisionprofile` | present | Team `S6N382Y83G`. |
| Whole bundle | 870 MB (`du -sh /Applications/Arc.app`) | ArcCore is 68% of the bundle. |

Info.plist keys that matter for Open:

- `SUFeedURL = https://releases.arc.net/updates.xml`, `SUAutomaticallyUpdate = true`, `SUScheduledCheckInterval = 28800` (8 h) — Sparkle. Evidence: `plutil -p Contents/Info.plist`.
- `OSAScriptingDefinition = Arc.sdef`, `NSAppleScriptEnabled = true` — AppleScript support ships in v1 of Arc. Open should decide whether to keep it.
- `NSMainNibFile = MainMenu` — the main menu still comes from a nib (`Contents/Resources/Base.lproj/MainMenu.nib`, the only `.nib` under `Contents/Resources`, `find … -name "*.nib" | wc -l` = 1).
- `ATSApplicationFontsPath = Fonts` plus a large font bundle (§5) — Arc registers bundled fonts at launch.
- `MallocNanoZone = 0` in `LSEnvironment` — disables the nano malloc zone. Guess: Chromium/PartitionAlloc compatibility. Mark as guess; no symbol proves the reason.

## 2. ArcCore.framework

Evidence: `find …/ArcCore.framework -maxdepth 4`, `ls -lh Versions/A/`, `plutil -p Versions/A/Resources/Info.plist`, `size -m .re/bin/ArcCore-arm64`, `otool -L .re/bin/ArcCore-arm64`.

| Item | Fact |
|---|---|
| Binary | `Versions/A/ArcCore`, 478 MB fat (x86_64 + arm64); arm64 slice 228–239 MB. `__TEXT` 226 MB, of which `__text` 206 MB and `__const` 11.6 MB (`size -m`). |
| Identity | `company.thebrowser.browser.framework`, 156.0.8078.48. |
| Linked system frameworks | AppKit, WebKit-adjacent Chromium stack: Metal, IOSurface, ScreenCaptureKit (weak), VideoToolbox, CoreMedia, AVFoundation, Network, LocalAuthentication, CryptoTokenKit, SkyLight (weak, private). Full list in `otool -L .re/bin/ArcCore-arm64`. |
| `Versions/A/Resources/` | 236 entries: `chrome_100_percent.pak`, `chrome_200_percent.pak`, `resources.pak`, `icudtl.dat`, `v8_context_snapshot.arm64.bin` + `x86_64.bin`, ~200 `.lproj` locale dirs (including gender variants such as `en_MASCULINE.lproj`), `DevTools/`, `arc/`, `gpu_shader_cache.bin`, `ArcCore.sig`. |
| `Versions/A/Libraries/` | `libaperitif.dylib` (166 KB), `libvk_swiftshader.dylib` (20 MB), `libvulkan.dylib` (1.0 MB), `vk_swiftshader_icd.json`, plus component dirs `IwaKeyDistribution/`, `MEIPreload/`, `PrivacySandboxAttestationsPreloaded/`. |
| Helpers | 8 helper apps + `app_mode_loader` (1.6 MB). See §4. |

What Open should take from this: a CEF build will have the same shape (one large engine dylib, `.pak` files, ICU data, V8 snapshot, SwiftShader fallback). Do not try to shrink the engine by deleting locales blindly — Chromium needs `icudtl.dat` and at least one `.pak` set. The 20 MB SwiftShader dylib is only a software-rendering fallback; keep it, it is small next to the engine.

## 3. First-party and third-party frameworks in `Contents/Frameworks/`

Evidence: `ls -lh Contents/Frameworks/`, `du -sh Contents/Frameworks/*.framework`, `otool -L .re/bin/Arc-arm64`, `plutil -p` on each framework `Info.plist`.

| Framework | Size | Role in Arc | Evidence |
|---|---|---|---|
| `ArcCore.framework` | 591 MB | Chromium 156 fork (browser, renderer, GPU, network). | `Info.plist` 156.0.8078.48; `otool -L` on main binary links `@executable_path/../Frameworks/ArcCore.framework/Versions/A/ArcCore`. |
| `Lottie.framework` | 4.3 MB | Airbnb Lottie vector animation player. Binary 4.2 MB. | `com.airbnb.Lottie`; main binary links `@rpath/Lottie.framework/Versions/A/Lottie`. Strings: `AnimationView`, `ConfettiAnimationView`. |
| `Sparkle.framework` | 2.8 MB | App updates ( Sparkle 2.9.4, build 2059). Contains `Updater.app`, `XPCServices/Downloader.xpc`, `Installer.xpc`, `Autoupdate`. | `org.sparkle-project.Sparkle` 2.9.4; main binary links `@rpath/Sparkle.framework/Versions/B/Sparkle`. Strings: `SPUUpdater`, `startUpdater:`. |
| `Sentry.framework` | 96 KB shim | Sentry crash/error reporting (Sentry 8.53.1, `io.sentry.Sentry`). The real code is statically linked into the main binary (980 Sentry strings, `SentrySDK.start`, `SentryProfiler`). The 82 KB framework binary is a shim; do not read its size as the SDK's cost. | `plutil` 8.53.1; `strings` count §6. |
| `FirebaseFirestoreInternal.framework` | 100 KB shim | Firestore C++ core. Real Firestore code is in the main binary (gRPC + leveldb + abseil strings). | `ls` shows 82 KB binary; `strings` shows `N8firebase9firestore…` C++ symbols. |
| `absl.framework`, `grpc.framework`, `grpcpp.framework`, `openssl_grpc.framework` | 100 KB each (shim) | Abseil, gRPC, OpenSSL for Firestore. Each contains only an 82 KB stub binary; the implementation is statically linked into the main executable. | `du -sh` = 100 KB each; `ls -lh Versions/A/` shows 82 KB binaries. |

Key fact: `otool -L .re/bin/Arc-arm64` lists 62 `LC_LOAD_DYLIB` + 24 `LC_LOAD_WEAK_DYLIB`, but only three non-system dylibs are loaded dynamically: `ArcCore`, `Lottie`, `Sparkle` (plus the weak `libswiftCompatibilitySpan.dylib`). Everything else — Firebase, Datadog, LaunchDarkly, Sentry, SDWebImage, TCA, and ~80 Swift packages — is statically linked into the single 158 MB `Arc` executable. That is why the main binary's `__text` is 56 MB (`size -m`: `__text` 56,421,416 bytes) and `__swift5_typeref` is 1.9 MB. There is no per-module dylib to measure; §6 sizes SDKs by string/symbol counts instead.

System frameworks the main binary links (evidence: `otool -L .re/bin/Arc-arm64`): AppKit, SwiftUI, Combine, CloudKit, CoreData, CryptoKit, MetricKit (weak), NaturalLanguage, PDFKit, QuickLookThumbnailing, ScreenCaptureKit, ScriptingBridge, WebKit, AVKit/AVFoundation, Metal/MetalKit, GameplayKit. The breadth (GameplayKit, SceneKit/SpriteKit via weak Swift shims, NaturalLanguage) shows the binary links frameworks for small features; each one costs launch-time dyld work even if rarely used.

## 4. Helper apps, plug-ins, and XPC services

### 4.1 Chromium helpers and the "Aperitif" helpers

Evidence: `ls -lhR …/ArcCore.framework/Versions/A/Helpers/`, `plutil -p` on each helper `Info.plist`, `nm` and `md5` on each helper binary, `strings` on `libaperitif.dylib`.

There are 8 helper apps. All have `LSUIElement = 1` (no Dock icon) and `LSMinimumSystemVersion = 13.0`.

| Helper app | Binary size | Bundle ID | Kind |
|---|---|---|---|
| `Browser Helper.app` | 166 KB | `company.thebrowser.browser.helper` | Classic generic helper |
| `Browser Helper (GPU).app` | 166 KB | `company.thebrowser.browser.helper` | Classic GPU helper |
| `Browser Helper (Renderer).app` | 166 KB | `company.thebrowser.browser.helper.renderer` | Classic renderer helper |
| `Browser Helper (Alerts).app` | 166 KB | `company.thebrowser.browser.framework.AlertNotificationService` | Classic alerts helper |
| `Browser Helper (Aperitif).app` | 99 KB | `company.thebrowser.browser.helper` | Aperitif generic helper |
| `Browser Helper (Aperitif GPU).app` | 99 KB | `company.thebrowser.browser.helper` | Aperitif GPU helper |
| `Browser Helper (Aperitif Renderer).app` | 99 KB | `company.thebrowser.browser.helper.renderer` | Aperitif renderer helper |
| `Browser Helper (Aperitif Alerts).app` | 99 KB | `company.thebrowser.browser.framework.AlertNotificationService` | Aperitif alerts helper |

What "Aperitif" is. The two families have identical bundle IDs and identical roles; only the launcher binary differs:

- Classic helpers (166 KB): `nm` shows a full Chromium helper `main` that resolves `ChromeMain` itself — undefined symbols include `_dlopen`, `_dlsym`, `__NSGetExecutablePath`, plus sandbox and PartitionAlloc setup strings ("Failed to create seatbelt sandbox server", "DelegatingDefaultZoneForPartitionAlloc", "ChromeMain", "../../../../ArcCore" in `strings`).
- Aperitif helpers (99 KB): `nm` shows only 6 symbols — `_main`, undefined `_AperitifCheckInitialized` and `_ChromeMain`, `_exit`. They contain no sandbox, dlopen, or PartitionAlloc code. `otool -L` shows they link nothing beyond the implicit `libaperitif` path; the work is delegated.
- `Libraries/libaperitif.dylib` exports `_AperitifCheckInitialized` (`nm` shows `T _AperitifCheckInitialized`) and itself contains the sandbox/PartitionAlloc strings ("AperitifCheckInitialized: Aperitif has not been initialized", "Failed to create seatbelt sandbox server"). It links only `libsandbox.1.dylib` and `libSystem.B.dylib`.
- ArcCore selects the family with the feature flag string `kAperitifHelpers` (`strings .re/bin/ArcCore-arm64 | grep -i aperitif` shows `kAperitifHelpers` and the four "(Aperitif…)" suffixes).

Conclusion (evidence-based): Aperitif is a second, slimmer helper-launcher implementation. The classic helper binary embeds Chromium's sandbox + allocator bootstrap; the Aperitif binary is a thin stub that calls `AperitifCheckInitialized` in `libaperitif.dylib` and then `ChromeMain`. Same processes, same bundle IDs, less duplicated bootstrap code per helper. Guess: the name is an internal codename for the new launcher ("aperitif" = small drink before the main course). Mark as guess — no string states the reason for the name.

Why it matters for Open: CEF ships its own helper apps. If Open uses CEF, it gets the classic pattern for free and needs neither family. If Open later forks Chromium, the Aperitif pattern (one shared `libaperitif.dylib` + 99 KB stubs) is the lighter way to ship 4 helper roles. Do not ship both families.

Also in `Helpers/`: `app_mode_loader` (1.6 MB, universal). `strings` shows it loads the framework dylib for Chrome app-mode shortcuts ("Loading framework dylib %s", "ChromeAppModeStart_v8", "Couldn't get app shortcut ID"). This serves Chromium "app mode" (installed web apps / PWAs). Open needs an equivalent only if it supports installable web apps in v1; otherwise drop it.

### 4.2 Other plug-ins and services

| Item | Fact | Evidence |
|---|---|---|
| `Contents/PlugIns/DockTilePlugIn.plugin` | Bundle ID `company.thebrowser.Browser.DockTilePlugIn`, v2.0. Thin Swift plug-in (Foundation/AppKit only, `otool -L .re/bin/DockTile-arm64`). Draws the Dock tile (badge / progress). | `plutil -p …/DockTilePlugIn.plugin/Contents/Info.plist`; `NSDockTilePlugIn = DockTilePlugIn.plugin` in main `Info.plist`. |
| Sparkle `Downloader.xpc`, `Installer.xpc`, `Updater.app` | Standard Sparkle 2.x update machinery. | `ls …/Sparkle.framework/Versions/B/XPCServices/`. |
| Login items / LaunchAgents | None found. `find /Applications/Arc.app -name "*.xpc"` returns only Sparkle's two services; no `Library/LoginItems` or `LaunchAgents` in the bundle. | `find` output §3 batch. |

## 5. Resource bundles: the `ARC_*`, `ARCUI_*`, `ARCClients_*`, `ADK_*` bundles

Evidence: `ls Contents/Resources/` (144 entries), `du -sh Contents/Resources/*.bundle`, `find … -type f` per bundle.

There are 83 `*.bundle` entries. Each is a Swift Package Manager resource bundle with the layout `<Target>_<Target>.bundle/Contents/Resources/…` plus its own `_CodeSignature`. The prefix before the first `_` is the Swift package; the suffix is the target/module. So the bundle list is a direct map of Arc's Swift module graph (full mapping in [architecture-map.md](architecture-map.md)).

Largest bundles (`du -sh`, sorted):

| Bundle | Size | Contents (evidence: `find -type f`) |
|---|---|---|
| `ARC_WelcomeToArcFeature.bundle` | 35 MB | Onboarding (WelcomeToArcFeature). Largest single resource cost. |
| `ARC_AuthFeature.bundle` | 22 MB | Sign-in / onboarding media (AuthFeature). |
| `ARCUI_ARCUI.bundle` | 12 MB | Shared UI: `Assets.car`, `background.mp4`, `orb.mp4`, `logo-wave.json` (Lottie). |
| `ARCClients_FontsManager.bundle` | 11 MB | 80+ font files (`find | wc -l` = 88 entries): ABCFavorit, ABCOracle, Pitch, Söhne, Marlin, Inter, Inconsolata, GT-Ultra. See §7. |
| `ARCClients_BaseAssets.bundle` | 7.9 MB | Shared image assets. |
| `ARCClients_BlockListClient.bundle` | 3.5 MB | Ad-block lists: `manifest.json` + filter data. |
| `ARC_PreferencesFeature.bundle` | 2.5 MB | Settings UI assets + `smiley.json`. |
| `ARC_AskArc.bundle` | 1.9 MB | Arc Max / Ask Arc (out of scope for Open). |
| `ARC_ImportFeature.bundle` | 1.5 MB | Browser import UI. |
| `ARC_WindowThemeUI.bundle` | 1.0 MB | Window theme editor assets. |
| `ADK_ADK.bundle` | 268 KB | Engine bridge resources: `selectors.css`, `adblock_list.json`. Proves ADK ships content-blocking CSS/JSON. |
| `ARC_CommandBar.bundle` | 100 KB | `command_bar_behavior.json` + `Assets.car`. Command Bar behavior is data-driven. |

Other notable bundles: `ARC_StorableSidebar.bundle` (84 KB, `Assets.car` only — persistence code has almost no resources), `Settings_Settings.bundle` (200 KB, 44 files — the Sindre Sorhus `Settings` package UI), `Datadog_DatadogCore.bundle`, `LaunchDarkly_LaunchDarkly.bundle`, `SDWebImage_SDWebImage.bundle`, `YouTubePlayerKit_YouTubePlayerKit.bundle`, `ZIPFoundation_ZIPFoundation.bundle`, `DomainParser_DomainParser.bundle` (128 KB, public-suffix data), `leveldb_leveldb.bundle`, `nanopb_nanopb.bundle`, `swift-crypto_Crypto.bundle`, `gRPC_*Wrapper.bundle` ×3, `abseil_abslWrapper.bundle`, `GTMSessionFetcher_*`, `GoogleUtilities_*` ×6, `Firebase_*` ×5, `Promises_FBLPromises.bundle`.

Non-bundle resources: `Assets.car` (3.2 MB, main asset catalog; `xcrun assetutil --info` shows color assets such as `AddSpacePlusBackgroundColor`), `AppIcon.icns` (52 KB), `Arc.sdef` (AppleScript definitions), `GoogleService-Info.plist` (Firebase config — treat values as public client config, do not copy them into Open), `popularDomains.json`, `README.md`, and ~40 `.lproj` dirs that contain only `MainMenu.strings` (the main menu is localized; almost nothing else in the shell is in `.lproj`).

## 6. Third-party SDKs: what Arc uses each for, and what Open can drop

Evidence: `strings .re/bin/Arc-arm64` counts (raw hits / unique), `nm` undefined Swift module symbols, embedded source paths (`.re/architecture/source-paths.txt`, 539 paths), resource bundles (§5), `otool -L`. Counts are a size proxy only — statically linked code does not split by module on disk.

| SDK | Evidence in binary | What Arc uses it for | Open decision |
|---|---|---|---|
| Firebase Core + Auth + Firestore + Storage + Functions | 1,372 raw / 1,185 unique strings; `FirebaseStorage.Storage` accessors in demangled symbols; source paths `FirebaseClient/`, `FirebaseSidebarSyncCommon/` (8 files), `BoostsClient/BoostsStorageFirebaseImpl.swift`; `GoogleService-Info.plist` project `bcny-arc-server` | Account sign-in, sidebar sync (Firestore), Boosts cloud storage (Storage), callable functions. The sync state machine lives in `FirebaseSidebarSyncCommon/FeatureState+{Enable,Subscription,Upload,RemoteUpdate,Wipeout,ErrorHandling}.swift`. | DROP. Open has no account, login, or sync (AGENTS.md locked decision). This also removes gRPC, leveldb, abseil, nanopb, GTMSessionFetcher, GoogleUtilities, Promises, and the 5 Firebase shim frameworks. Largest single saving. |
| CloudKit (`SidebarSyncCloudKit`, 9 source files) | 133 CloudKit strings; `CKContainer`, `CKModifyRecordsOperation` in undefined ObjC classes; entitlement `iCloud.net.arc.sidebar` | Second sync backend for the sidebar (iCloud). Source: `SidebarSyncCloudKit/SidebarSync.swift`, `SpaceModel+CloudKit.swift`, `SidebarItemDecoder.swift`. | DROP with sync. Also drops the iCloud entitlement and `CloudKitContainerClient`. |
| Datadog (DatadogCore + OpenTelemetry) | 412 Datadog strings + 215 OpenTelemetry strings; `DatadogInternal.DatadogURLSessionDelegate`, `MethodSwizzler`; source `AnalyticsClient/ContextPlugin.swift`, `TelemetryClient/` | Product analytics, RUM, tracing, log forwarding. `AnalyticsClient` wraps Datadog; OpenTelemetry API provides spans/meters. | DROP (telemetry). Keep a local, opt-in crash log only. Removes URLSession swizzling at launch. |
| LaunchDarkly | 207 strings; `LDClient`, `LDConfig`, "LDClient.start() was called more than once!"; source `FeatureFlags/FeatureFlagsClient+Dependencies.swift`, `SharedAppFeature/ADKFeatureFlags.swift`, generated `FeatureFlags/*.generated.swift` | Remote feature flags and gradual rollout, including engine flags (`ADKFeatureFlags`) and Command Bar flags. | DROP (feature flags). Replace with compile-time constants or a local plist. Removes a network call and a background poller from launch. |
| Sentry | 827 strings; framework 8.53.1; `SentrySDK.start`, `SentryProfiler`, session-replay types (`SentryRRWebEvent`) | Crash reporting, performance profiling, session replay. Source: `AppFeature/SentryClient+LiveValue.swift`, `SharedAppFeature/SharedAppFeature+Sentry.swift`. | KEEP (reduced) or DROP. A crash reporter is useful for a beta, but drop the profiler and session replay. If kept, use a self-hosted endpoint and make it opt-in. |
| Sparkle 2.9.4 | 46 strings; `SPUUpdater`, `startUpdater:`; `SUFeedURL https://releases.arc.net/updates.xml` | Auto-update with 8 h check interval, EdDSA-signed (`SUPublicEDKey`). Source: `SoftwareUpdaterClient/SparkleVersionComparison.swift`. | KEEP. Open needs updates. Point the feed and key at Open's own server. |
| Lottie | framework 4.3 MB; `AnimationView`, `ConfettiAnimationView`; `ARCUI` bundle `logo-wave.json`; `ARC_SidebarBanner` `update-heart-animation.json` | Decorative vector animations (logo wave, confetti, onboarding). | DROP or shrink. Recreate the 2–3 needed animations as code-drawn or video assets. Saves 4.3 MB plus the ARCUI videos. Never copy Arc's `.json` animations (AGENTS.md rule 1). |
| SDWebImage | 222 strings; `SDImageIOAnimatedCoder`, `SDImageLoader`; bundle `SDWebImage_SDWebImage.bundle` | Animated image decoding and remote image loading/caching (favicons, previews, Easel images). | DROP. Use `NSImage` + `ImageIO` and a small disk cache. Favicon scale does not need SDWebImage. |
| YouTubePlayerKit | 30 strings; `YouTubePlayerBaseViewController`, `YouTubePlayerHostingView` | Embeds YouTube players (Media Controls / PiP previews). | DROP for v1. A plain `WKWebView` or the web content itself plays YouTube. Revisit only if Media Controls need it. |
| The Composable Architecture + Dependencies + CasePaths + SwiftUINavigation (Point-Free) | 755 TCA-related strings; `StoreOf`, `Reducer`, `DependencyKey` (246 hits), `TestStore`; 11 source files under vendored `ComposableArchitecture/`; `Dependencies/` (15 files) | The entire app state layer. See [architecture-map.md](architecture-map.md). | Open decision, not a drop: TCA is a design choice, not bloat by itself. Open's AGENTS.md favors AppKit performance; a lighter store (Observation + explicit reducers, or TCA only at the app root) is the open question. Do not vendor-copy Arc's TCA fork. |
| SwiftSoup + Fuzi | 233 strings; demangled `SwiftSoup.Element`, `Fuzi.XMLNode` accessors | HTML parsing/scraping: page-content extraction, Ask Arc, previews, import. Source: `Scraping/HTMLScrapingRulesProvider.swift`, `ADK/BrowserContext+PageContentExtraction.swift`. | KEEP one. Open needs HTML parsing for import and content extraction. Pick one parser, not both. |
| ZIPFoundation | bundle present; `Archive` type strings (mixed with app Archive feature — count not separable) | Zip handling (import/export, Boosts, Easels). | KEEP if import needs zip; it is small. |
| Settings (Sindre Sorhus) | `Settings_Settings.bundle` (44 files); strings `com.sindresorhus.Settings.FrameAutosaveName` | Preferences window scaffolding (tabbed settings, frame autosave). | Optional. Open can build Preferences with plain AppKit/SwiftUI and drop the dependency, or keep it — it is small and well-maintained. |
| SwiftUIIntrospect | 96 strings; `IntrospectionPlatformViewController` | Reaches through SwiftUI to the underlying AppKit views (needed because Arc embeds SwiftUI in AppKit windows). | DROP if Open keeps SwiftUI at the leaves only. Needed only where SwiftUI must be introspected. |
| DomainParser | bundle 128 KB; `TLDClient`, `ARC_TopDomains` `TopDomains.json`, `TLD-short-list.json` | Public-suffix / top-domain parsing for the Command Bar and URL input. | KEEP equivalent data, not necessarily the package. Open needs a public-suffix list for URL-vs-search decisions. |
| swift-crypto, EventSource, Motion, LLM clients | `EventSource.EventSource` (32 accessors: `readyState`, `eventStreamParser`); `LLM/OpenAI/ChatGPT.swift`, `UniversalLLMClient.swift`; `Motion.Animation` | Server-sent events and OpenAI calls for Arc Max / Ask Arc; `Motion` is a small animation helper. | DROP (Arc Max AI is out of scope). Removes `AskArc`, `LLM`, `EventSource`. |
| LiveNotionClient, LiveSlackClient, GitHubClient, Zendesk | source paths `LiveNotionClient/LiveNotionClient+FetchBlocks.swift`, `LiveSlackClient/`, `GitHubClient/`, `AppData+Zendesk.swift` | Live Folders / previews integrations (Notion, Slack, GitHub, calendar) and support. | DROP for v1 except what Open's Live Folders design needs. Each client is network + auth weight. |
| Firebase-adjacent: gRPC, leveldb, abseil, nanopb, GTMSessionFetcher, GoogleUtilities, FBLPromises | shim frameworks + bundles; C++ symbols `N8firebase9firestore…`, `N9grpc_core…` | Transitive Firestore dependencies. | DROP with Firebase. |

## 7. Fonts, media, and localization weight

Evidence: `find …/ARCClients_FontsManager.bundle -type f`, `du -sh` per bundle, `ls Contents/Resources/*.lproj`.

- Fonts: 11 MB in `ARCClients_FontsManager.bundle` — 80+ files across 8 families (ABCFavorit, ABCOracle, Pitch, Pitch Sans, Söhne, Söhne Breit, Marlin Soft, National 2, Inter, Inconsolata, GT-Ultra). Arc registers all of them (`ATSApplicationFontsPath`). Open must license or substitute its own fonts; do not copy Arc's font files (AGENTS.md rule 1). Two system-adjacent families (Inter, Inconsolata) cover most UI needs at a fraction of the size. Guess: most families exist for marketing/onboarding surfaces, not daily UI. Runtime data (§10) can confirm which fonts the running UI actually loads.
- Video: `ARCUI_ARCUI.bundle` contains `background.mp4` and `orb.mp4` inside its 12 MB. Onboarding bundles (`WelcomeToArcFeature` 35 MB + `AuthFeature` 22 MB = 57 MB) are larger than the main asset catalog. Open's onboarding should be native views, not video bundles.
- Localization: ~40 `.lproj` dirs in the shell (menu strings only) and ~200 in ArcCore (full Chromium locales, including gender variants). The shell's localization cost is small; the engine's is part of the 591 MB and not separately removable without a custom Chromium/CEF build.

## 8. Signing, entitlements, and update channel

Evidence: `codesign -d --entitlements - /Applications/Arc.app`, `plutil -p Contents/Info.plist`.

Entitlements: `com.apple.developer.icloud-container-identifiers = iCloud.net.arc.sidebar`, `icloud-services = CloudKit`, `associated-domains = webcredentials:arc.net`, `web-browser.public-key-credential = true`, device camera/audio/location, keychain groups `…webauthn` and `…auth`, `aps-environment = production` (push). Open drops iCloud, push, and `webcredentials` with the account system; it keeps camera/mic/location (web content needs them) and the WebAuthn keychain group.

## 9. Weight summary for bundle-anatomy (engine excluded)

| Source | Size | Removable for Open? |
|---|---|---|
| Main executable `Arc` (fat) | 158 MB (≈76 MB per arm64 slice, `.re/bin/Arc-arm64`) | Shrinks a lot: Firebase/Datadog/LaunchDarkly/Sentry-profiler/LLM statically linked code leaves with their features. |
| `Resources/` total | 109 MB | Onboarding + Auth (57 MB), fonts (11 MB), ARCUI video (part of 12 MB) are the targets. |
| Lottie.framework | 4.3 MB | Yes, or replace with 2–3 native animations. |
| Sparkle.framework | 2.8 MB | No — needed for updates. |
| Shim frameworks (Sentry, FirebaseFirestoreInternal, absl, grpc, grpcpp, openssl_grpc) | ~0.6 MB total | Misleading: their real code is in the main binary. Removing the feature removes the binary weight, not the shim. |
| Helpers (8 apps + loader) | ~1 MB + 1.6 MB loader | CEF provides its own; ship one family only. |

## 10. Open questions that need runtime data (user signed in to Arc)

1. Which fonts does the running UI actually register? Static data shows 80+ files; runtime font enumeration will show the used subset.
2. Does Arc launch the Aperitif helpers or the classic helpers by default? `kAperitifHelpers` is a flag; process listing at runtime (`Browser Helper (Aperitif Renderer)` vs `Browser Helper (Renderer)`) settles it.
3. How large is a real `StorableSidebar.json` after months of use, and how often is it rewritten? The test profile here has a 312 KB file (see architecture-map.md §6); a heavy user's file sizes the Open persistence budget.
4. Sparkle check behavior on a metered connection: feed fetches every 8 h per `SUScheduledCheckInterval`; runtime network logs confirm whether checks are deferred.

