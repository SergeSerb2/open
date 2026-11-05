# Page and platform features — implementation plan for Open

Status: plan (2026-10-26). Implementers: coding agents with no other
context, plus the engine lead for §6. Follow this file literally. Where it
says "Open choice", the choice is final for v1 unless the lead changes it in
the appendix. Where it says "guess", build the stated value and keep it in
one token, so a later capture fixes it in one edit. Cite the rule IDs (PG-n)
from [`docs/re/page-platform.md`](../re/page-platform.md) in code comments
where a behavior comes from Arc.

User-visible text never uses the Arc brand (AGENTS.md). Do not copy Arc
assets, code, or data files. SF Symbols are system glyphs and are allowed.
No unit tests (AGENTS.md rule 6): verify through the offscreen render
harnesses and the real app over the automation channel (§8).

Read first, in this order: `AGENTS.md`; `docs/re/page-platform.md` (the
evidence for this plan); `docs/status.md` §1.17 and §3 (gaps 8, 9, 12–16,
27–30); `docs/engine-api.md`; `docs/engine-patches.md` (P1, P5, P7);
`docs/plans/app-shell.md` §3.2, §3.7, §4.3, §4.9, §4.13;
`docs/plans/site-control-boost-editor.md` §3.2, §8.2, §9 (E2, E5);
`docs/plans/settings-library.md` §2 and §5.5; `docs/sleep.md`;
`docs/automation.md`; `docs/design.md` §2.

## Goal

Ship these page and platform features in Open, with Arc's look and
behavior where the evidence proves it:

1. Toasts with Arc's look (Space tint, top-right, overlap stacking),
   replacing the plain bottom toast of the app shell.
2. Copy URL family: tracker-free copy, the "Copied Current URL" toast with
   Share, Copy URL as Quote (Cmd+Ctrl+Shift+C), and the Share Quote
   affordance.
3. The zoom level toast ("110%"), plus checks that pinch zoom and smart
   zoom work.
4. Two-finger swipe back and forward on pages, with Open's indicator.
5. Web notifications end to end: banners and alerts in macOS Notification
   Center, macOS authorization, a click that focuses the right tab, and
   correct behavior with tab sleep.
6. The Capture tool: area, full page, and portrait captures; Cmd+Shift+2;
   Cmd+Shift drag; the Site Control buttons; saving into Library ▸ Captures.
7. Page translation without Google services: offer, translate, revert,
   choose another language, never translate a site, reset prompts.
8. The website appearance menu (Automatic, Light, Dark).
9. Clear Cache and Refresh, Clear Cookies and Refresh.
10. Developer menu extras (JavaScript Console, Inspect Elements, Network
    Inspector, Toggle Developer Mode, Allow JavaScript from Apple Events)
    and Help ▸ Troubleshooting (Open Task Manager, Record Trace, Cancel
    Trace, Copy Open Info, Reveal Open Data).
11. A decision for Cast (out of v1, §4.12).

## Success criteria

1. Toast geometry matches the measured Arc toast within 1 pt (PG-1.1–1.4):
   top inset 8, trailing inset 10, height 42 (46 with a button), radius 11.
   Fill and text colors reach ΔE00 ≤ 2 once capture C-T1 exists
   (`docs/design.md` §7 method).
2. Cmd+Shift+C puts the URL without tracking parameters on the pasteboard.
   The toast reads "Copied Current URL" or "Copied a clean link without
   trackers" (PG-1.10). Share opens the system share picker.
3. Copy URL as Quote copies a link that, opened in a new Open tab, scrolls to
   and highlights the selected text.
4. Each zoom command shows the zoom percent toast with Chromium's preset
   steps (90, 100, 110, 125 …).
5. A two-finger swipe goes back or forward on every page type (tab, split
   pane, Peek, Little Open) and shows Open's indicator; no indicator shows
   where navigation is impossible.
6. A local fixture page's notification reaches macOS Notification Center as
   a banner (and as an alert with `requireInteraction`). A click selects that
   tab in its Space and window. A tab whose site may notify never freezes or
   discards.
7. Area, full-page, and portrait captures appear in Library ▸ Captures with
   a correct `State/captures.json` row. Cmd+Shift+2 and Cmd+Shift drag start
   a capture; a Cmd+Shift click on a link still opens it.
8. A French fixture page offers translation to the system language;
   Translate, Show Original, another language, and Never Translate This Site
   work; Settings ▸ Reset Translated-site Prompts clears the site list. No
   network request is made for translation, and no Google API key exists.
9. View ▸ Appearance changes `prefers-color-scheme` in every open page
   without a reload.
10. Clear Cookies and Refresh removes only the current site's cookies. Clear
    Cache and Refresh is enabled only when per-site cache clearing exists.
11. Every Developer and Troubleshooting item performs its action. No
    user-visible string says "Arc".
12. View ▸ Cast… is hidden; Chromium never starts media-router discovery.
13. `tools/verify-all.sh` reports PASS for every target. No unit tests.

## Non-goals

- Cast in v1 (§4.12 gives the cost and the decision).
- Google-served page translation and Google API keys (§4.7.1).
- Easels, Notes, Arc Max (including pinch to summarize, PG-3.2).
- Hover capture of single images (FA CA-4). Deferred.
- Developer Mode effects beyond §4.10.3 until capture C-D1 exists.
- Sound effect files and the player (sidebar-completion §3.13 owns them; §4.6.8 only calls it).
- The Site Control Center panel itself (its plan owns it). This plan owns the
  commands its Capture, Copy URL, and Clear buttons run.

## 0. Locked decisions

| # | Decision | Why |
|---|---|---|
| D-1 | One `ToastCenter` per window (and per Little Open window) in `OpenFeatures`. Toasts are layer-backed views in one overlay view, not one window per toast. This plan replaces app-shell §3.7. | Same look as Arc's per-toast windows (PG-1.1) at a fraction of the cost: no window server work per toast. |
| D-2 | Translation runs on-device: Apple's `Translation` framework translates, `NaturalLanguage` detects the language, and Open's own page runtime swaps text. Chromium's translate stays off. | Chromium translate is disabled without Google API keys (§2.1 T-1), and Chromium's keys policy forbids shipping developer keys. Arc ships Google keys (PG-7.2); Open cannot. On-device fits "no account, no sync". |
| D-3 | Two-finger swipe keeps Chromium's `HistorySwiper` for gesture recognition and navigation. A small fork hook reports phase and progress; the shell draws Open's indicator. | Chromium's state machine already handles trackpad and Magic Mouse, the renderer's scroll consumption, and `overscroll-behavior`. Arc rebuilt it (PG-4.1); Open does not need to. |
| D-4 | Notifications use Chromium's native macOS path: banners from the browser process, alerts from the `Open Helper (Alerts)` app. The shell never sets `UNUserNotificationCenter.delegate`. | Chromium's service owns the delegate (`mac_notification_service_un.mm:101-105`). Two owners would drop clicks. |
| D-5 | The Copy URL family strips tracking parameters with Open's own table (`OpenModel/URLCleaner.swift`). | PG-2.1. Arc's table is evidence of the behavior; Open writes its own list. |
| D-6 | Quote links are text-fragment URLs (`#:~:text=`) from Chromium's own generator. | PG-2.2 (ArcCore has text-directive find). Chromium's generator picks prefix and suffix context, so links stay unique. |
| D-7 | Website appearance is one app-wide value for all profiles. | Arc's menu is app-level (PG-8.1). |
| D-8 | Open Task Manager shows Chromium's task manager window. | PG-11 (Arc calls Chromium's). Zero UI work. Fallback in §4.11.1. |
| D-9 | Cast is out of v1. The menu item is hidden and Chromium's media router is off. | §4.12. |
| D-10 | New SwiftPM target `OpenTranslate`. Every other UI part lives in `OpenFeatures`, `OpenSidebar`, and `OpenDesign`. App glue lives in `App/Page/`. | Translation has its own runtime and backend; the rest are window overlays and commands. |
| D-11 | Engine fork series `05xx` (media uses `04xx`, extensions `03xx`). New `OEWebContentChange` bits start at `1u << 15` (media uses 13 and 14). | No collisions with plans in flight. |
| D-12 | Every engine-dependent behavior has an interim path on today's API, or its command is disabled through a named enabled key until the engine item lands. Interim limits are named in the PR that ships them. | Same rule as app-shell D10 and the Site Control plan. |

## 1. Current state (origin/main `bfef13c`, 2026-10-26; re-verify before you edit)

| Area | State | Evidence |
|---|---|---|
| App window | `main` runs the real window (app-shell Step B, PR #52 merged): `OpenFeatures.BrowserWindowController`, `App/WebContent/EngineWebContentHost.swift`, `App/TabStripMirror.swift`. Menus and keys are Step C (not merged). | `git log origin/main` (`bfef13c`) |
| Toast | `OpenFeatures.BrowserWindowController.showToast(_:undo:)`: one bottom-center toast, 280 × 34, black 0.85, radius 8, optional Undo. Sources: Peek close (`PeekController.onToast`), the pane Copy button (`WebContentContainer.onToast("Copied Current URL")`). The sidebar-completion plan adds "Folder deleted", "Cleared Tabs", and "Folder restored…" toasts on it, and its own first-hide hint view (`HintToastView`, measured on A0440). | `BrowserWindowController.swift:76-130, 220, 287-292`, `PeekController.swift:63-193`, `WebContentContainer.swift:89, 190`; `docs/plans/sidebar-completion.md` §3.12, §5 |
| Engine page API | `OEWebContent`: `takeSnapshot` (visible page PNG), `evaluateJavaScript` (DevTools `Runtime.evaluate`, main world), `sendDevToolsMethod`, `zoomLevel`, `zoomIn/zoomOut/resetZoom` (CEF preset steps), `showDevTools`, `OEWebContentChangeZoom`. No selection, no history-swipe, no panel, no full-page API. | `Engine/OpenEngine/include/OpenEngine/OEWebContent.h`, `OEWebContent.mm:842-868` |
| Engine app API | `OEEngine.sampleProcessMetrics` over `CefTaskManager`. No tracing wrapper. | `OEEngine.mm:661-688` |
| Commands | Every id exists: `copy-url-quote`, `capture-page` (Cmd+Shift+2), `capture-full-page`, `capture-portrait`, `clear-cache-and-refresh`, `clear-cookies-and-refresh`, `cast`, `appearance-*`, `network-inspector`, `toggle-developer-mode` (Ctrl+D), `allow-js-apple-events`, `task-manager`, `record-trace`, `cancel-trace`, `copy-open-info`, `reveal-open-data`. `MenuBuilder` already adds the "Websites will use:" header. It has no checkmark, dynamic title, or hidden state. | `CommandRegistry.swift`, `MenuBuilder.swift:45-262` |
| Settings | `open.advanced.enableSharedQuotes` (A-7) and the "Reset Translated-site Prompts" button (logs `resetTranslatePrompts`) exist. Library ▸ Captures reads `<root>/Captures/` and `State/captures.json`. | `settings-library.md` §2.1, §2.6, §5.5, §6.4 |
| Site Control plan | Merged (#61). Its Capture ×3 and Copy URL buttons run this plan's commands. It defines engine items E2 (per-site data clear) and E5 (isolated-world evaluate), and the automation command `pasteboard` and the e2e helper `fixture_server(tmp)`. Its lead decision Q2 waits for this plan to define Developer Mode. | `site-control-boost-editor.md` §3.2, §8.2, §9, Appendix |
| Sleep | `OpenSleep` gates: visible, keepAlive (built-in host list plus per-profile `keepAliveSites`), audible, loading, capturing, devTools, downloading, unload, form. No notification gate. | `SleepPolicy.swift:19`; `docs/sleep.md` "Keep-alive sites" |
| Helpers | Five helpers share `Helper/Info.plist`. The Alerts helper has no `NSUserNotificationAlertStyle` and shows "Open Helper (Alerts)". | `Helper/Info.plist`, `project.yml:51-122` |
| P1 | PR #53: the shell's tabs are Chrome-style pages hosted in one hidden Chrome `Browser` per window. | `docs/engine-patches.md` P1 status (branch `m7/ext-p1-tabstrip`) |

## 2. Engine findings

### 2.1 What our build does today (Chromium 156.0.8078.48 + CEF 8078)

All paths are under `~/Developer/open-engine/chromium_git/chromium/src`.

| # | Feature | Works today? | Evidence | Gap |
|---|---|---|---|---|
| T-1 | Chromium page translation | **No.** Our build has no Google API key, so `google_apis::HasAPIKeyConfigured()` is false. `TranslateManager` then calls `PreventAllTriggering()` and also blocks the menu path. | `google_apis/default_api_keys.h:19` (`kUnsetApiToken = "dummytoken"`), `default_api_keys-inc.cc` (`GOOGLE_API_KEY` defaults to it), `Engine/fork/gn/*.args.gn` (no `google_api_key`), `components/translate/core/browser/translate_manager.cc:202-211, 761-765, 946-955` | Even with a key: the language model download is also key-gated (`components/optimization_guide/core/delivery/prediction_model_download_manager.cc:216`), so detection would read only the page's `lang` attribute (`components/translate/content/renderer/translate_agent.cc:255-276`); and the bubble needs a Views browser window (`chrome/browser/translate/chrome_translate_client.cc:473-503`; P1's hidden window returns `kBrowserWindowNotValid`, `open_browser_window.mm` `ShowTranslateBubble`). |
| T-2 | Two-finger history swipe | **Probably yes, with Chrome's arrow overlay** (not verified). Every WebContents, Alloy or Chrome style, gets `ChromeWebContentsViewDelegateCef`, whose widget delegate owns a `HistorySwiper`. Navigation uses `chrome::GoBack(WebContents*)`, which needs no `Browser`. | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc:732-746` and `_mac.mm`; `cef/libcef/browser/alloy/browser_platform_delegate_alloy.cc:195`; `chrome/browser/ui/views/tab_contents/chrome_web_contents_view_delegate_views_mac.mm:53-61`; `chrome/browser/renderer_host/chrome_render_widget_host_view_mac_delegate.mm` (`initWithRenderWidgetHost:`, `navigateInDirection:`); `chrome/browser/ui/browser_commands.cc:1097` | The overlay is Chrome's 140 × 140 semicircle (`chrome/browser/ui/cocoa/history_overlay_controller.mm`). No embedder hook. |
| T-3 | Pinch zoom, smart zoom | Probably yes (native `RenderWidgetHostViewCocoa` handlers). Not verified. | ArcCore keeps the same selectors (PG-3.2) | `resetZoom` does not reset the pinch scale. |
| T-4 | Web notifications | Partly. Chromium's macOS bridge is on: banners from the browser process, alerts (`requireInteraction`, progress) from the `(Alerts)` helper. | `chrome/browser/notifications/mac/mac_notification_provider_factory.cc:21-80`; `notification_utils.cc:197-201`; `chrome/browser/chrome_content_browser_client.cc:8950-8965`; features on by default, `chrome/common/chrome_features.cc:1467, 1480` | Alerts helper plist lacks the alert style and the display name; no e2e beyond the permission grant; CEF Alloy pages ignore `window.focus()` (no `ActivateContents` in `cef/libcef`). |
| T-5 | Capture | Visible viewport only (`takeSnapshot`, DevTools `Page.captureScreenshot`). | `OEWebContent.h` | Full page needs DevTools tiling; no area UI. |
| T-6 | Page selection | No API. `evaluateJavaScript` runs in the main frame's main world only. | `OEWebContent.h` | Iframes and a page that overrides `getSelection` are missed. |
| T-7 | Website color scheme | Stock CEF has `CefRequestContext::SetChromeColorScheme(variant, user_color)`, which sets Chrome's `ThemeService` color scheme. Chrome derives `prefers-color-scheme` from `web_contents->GetColorMode()`. | `cef/include/cef_request_context.h:337-346`; `cef/libcef/browser/request_context_impl.cc:992-1020`; `chrome/browser/chrome_content_browser_client.cc:4064-4097, 4946-4949` | Unverified for pages with no Views color source (Alloy, and hosted tabs in a Views-less window). |
| T-8 | Per-site cache or cookie clear | `clearBrowsingData(origin:)` clears one origin's cookies but the HTTP cache of every site. | `OEBrowserContext.h:174-179` | Site Control plan E2. |
| T-9 | DevTools panels | Only plain DevTools. CEF passes default `DevToolsOptions()`; Chrome supports `panel_id` and an Inspect action. Chrome-style browsers can run Chrome commands. | `cef/libcef/browser/devtools/devtools_window_runner.cc:36-44`; `chrome/browser/devtools/devtools_window.cc:896-913, 2140-2144`; `cef/include/cef_browser.h:1036-1056` (`ExecuteChromeCommand`); `chrome/app/chrome_command_ids.h:222-224, 241, 279-282` | No network panel id. |
| T-10 | Task manager | `CefTaskManager` lists, kills, and maps tasks to browsers. Chrome's window opens with `IDC_TASK_MANAGER_MAIN_MENU`. | `cef/include/cef_task_manager.h`; `chrome_command_ids.h:282` | Not wrapped. |
| T-11 | Tracing | `CefBeginTracing` / `CefEndTracing`. | `cef/include/cef_trace.h` | Not wrapped. No privacy-filter switch. |
| T-12 | Cast | `CefMediaRouter` discovers Cast and DIAL sinks and launches `cast:`/`dial:` apps. It cannot mirror a tab. Chrome's Cast dialog is Views. The `MediaRouter` feature is on by default. | `cef/include/cef_media_router.h:54-150`; `chrome/browser/media/router/media_router_feature.cc:47, 102-106` | §4.12. |
| T-13 | JavaScript from Apple Events | Chrome's pref defaults to false. Open's AppleScript is its own (`OpenScripting`) and has no gate. | `chrome/browser/ui/browser_ui_prefs.cc:190`; `docs/plans/applescript.md` Q5 | §4.10.2. |

### 2.2 What P1 (PR #53) gives for free, and what needs a bridge

The shell creates Chrome-style tabs inside one hidden `Browser` per window
(`docs/engine-patches.md` P1 status). That changes some of the rows above.

| Feature | With P1 | Evidence |
|---|---|---|
| Notification click → tab focus | **Free for hosted tabs.** `window.focus()` in a notification `click` handler, or `client.focus()` in a service worker, reaches `WebContentsImpl::Activate` → `BrowserWebContentsDelegate::ActivateContents`, which activates the tab in the hidden strip and calls `window_->Activate()`. PR #53 turns the strip activation into `browser(_:requestsActivationOf:)` and brings the NSWindow front. | `content/browser/service_worker/service_worker_client_utils.cc:470-506`; `content/browser/web_contents/web_contents_impl.cc:4735-4739`; `chrome/browser/ui/browser_web_contents_delegate/browser_web_contents_delegate.cc:744-753`; PR #53 `open_tab_strip.cc:366-397, 504-505`, `open_browser_window.mm` `Activate()` |
| `clients.openWindow()` from a notification | Free: Chromium opens a tab in the window's hidden strip, which PR #53 reports as `browser(_:didOpen:active:)` (adopted as a Today tab). | PR #53 `docs/engine-api.md` "Tab requests from Chromium" |
| Console panel, Inspect mode, Task Manager | Free on hosted tabs through `CefBrowserHost::ExecuteChromeCommand` (Chrome style only). | T-9, T-10 |
| Two-finger swipe | Not related to P1 (the view delegate is per WebContents, T-2). | T-2 |
| Translate UI | **Needs a bridge.** The hidden window's `ShowTranslateBubble` returns `kBrowserWindowNotValid`. Not used: this plan does not use Chromium translate (D-2). | PR #53 `open_browser_window.mm` |
| Cast dialog | **Needs a bridge** (Views dialog anchored to a `BrowserView`). Chrome's "Cast…" item already leaks into `OEContextMenu` for hosted tabs; filter it. | `docs/followups.md` (PR #53) |
| Chrome's zoom bubble | Does not show (no location bar in the hidden window) and is not wanted: Open draws its own zoom toast. Verify it stays hidden. | PR #53 `GetLocationBar()` returns null |
| Website color scheme | Unknown. The hidden window has a color provider but no Views widget. Verify (Step 5). | T-7 |
| Copy link to highlight | Chrome's context-menu item comes with hosted tabs (`LinkToTextMenuObserver`), but a keyboard command still needs EP-2. | `chrome/browser/renderer_context_menu/link_to_text_menu_observer.cc:55-61, 284` |

## 3. Architecture

### 3.1 Files (create exactly these; edit only what is listed)

```text
Packages/OpenKit/Sources/OpenDesign/PageTokens.swift            NEW  ToastMetrics, SwipeIndicatorMetrics, CaptureMetrics,
                                                                     URLStatusMetrics, TranslateMetrics; SpaceThemeStyle toast colors
Packages/OpenKit/Sources/OpenDesign/Motion.swift                 EDIT toastIn, toastOut, swipeIndicator tokens
Packages/OpenKit/Sources/OpenDesign/Typography.swift             EDIT toast, toastSubtitle, statusButton, captureSizeLabel
Packages/OpenKit/Sources/OpenModel/URLCleaner.swift              NEW  tracker stripping (D-5)
Packages/OpenKit/Sources/OpenModel/LiveNodes.swift               EDIT TabLiveState.notificationsAllowed (§4.5.6)
Packages/OpenKit/Sources/OpenCommands/MenuBuilder.swift          EDIT CommandMenuState + CommandDispatcher.menuState(for:)
Packages/OpenKit/Sources/OpenCommands/Command.swift              EDIT new EnabledKey values (§7.1)
Packages/OpenKit/Sources/OpenFeatures/Toasts/ToastCenter.swift   NEW
Packages/OpenKit/Sources/OpenFeatures/Toasts/ToastView.swift     NEW
Packages/OpenKit/Sources/OpenFeatures/Toasts/ToastOverlayView.swift NEW
Packages/OpenKit/Sources/OpenFeatures/PageSwipe/SwipeIndicatorView.swift NEW
Packages/OpenKit/Sources/OpenFeatures/Capture/CaptureController.swift   NEW
Packages/OpenKit/Sources/OpenFeatures/Capture/CaptureOverlayView.swift  NEW
Packages/OpenKit/Sources/OpenFeatures/Capture/CaptureResultView.swift   NEW
Packages/OpenKit/Sources/OpenFeatures/Capture/CaptureComposer.swift     NEW  crop, stitch, portrait canvas
Packages/OpenKit/Sources/OpenFeatures/Translate/TranslatePopoverView.swift NEW
Packages/OpenKit/Sources/OpenFeatures/BrowserWindowController.swift EDIT remove the old toast; own ToastCenter, CaptureController
Packages/OpenKit/Sources/OpenFeatures/WebContentHost.swift       EDIT members in §3.2
Packages/OpenKit/Sources/OpenFeatures/PeekController.swift       EDIT onToast → ToastCenter
Packages/OpenKit/Sources/OpenFeatures/WebContentContainer.swift  EDIT onToast → ToastCenter; swipe indicator host
Packages/OpenKit/Sources/OpenFeatures/LittleOpenWindowController.swift EDIT own ToastCenter
Packages/OpenKit/Sources/OpenSidebar/URLStatusButton.swift       NEW  "Translation Available" / "Share Quote" under the URL field
Packages/OpenKit/Sources/OpenSidebar/ChromeViews.swift           EDIT host the status button; push content down while it shows
Packages/OpenKit/Sources/OpenSidebar/SidebarIntent.swift         EDIT .showTranslation(anchor:), .shareQuote(anchor:)
Packages/OpenKit/Sources/OpenTranslate/PageLanguageDetector.swift NEW  (target OpenTranslate, D-10)
Packages/OpenKit/Sources/OpenTranslate/TranslationBackend.swift   NEW  protocol + AppleTranslationBackend
Packages/OpenKit/Sources/OpenTranslate/PageTranslationSession.swift NEW one page's translate state machine
Packages/OpenKit/Sources/OpenTranslate/TranslatePreferences.swift NEW never-translate hosts, reset
Packages/OpenKit/Sources/OpenTranslate/Resources/translate-runtime.js NEW page runtime (§4.7.4)
Packages/OpenKit/Sources/OpenSleep/SleepPolicy.swift             EDIT gate .notifications (§4.5.6)
Packages/OpenKit/Sources/OpenSettings/SettingsTypes.swift        EDIT SettingsDefaults.values (§5)
Packages/OpenKit/Sources/openkit/PageCLI.swift                   NEW  `openkit url-clean`, `openkit lang-detect`
Packages/OpenKit/Sources/features-render/…                       EDIT scenes toast, swipe, capture, translate (§8.1)
Packages/OpenKit/Sources/sidebar-render/…                        EDIT scene url-status (§8.1)
Packages/OpenKit/Package.swift                                   EDIT target OpenTranslate (+ resource), product, openkit dep; new
                                                                     features-render files go into that target's explicit `sources` list
App/Page/PageCommands.swift            NEW  CommandDispatcher extension for this plan's ids (§7.1)
App/Page/NotificationAuthorization.swift NEW macOS authorization + System Settings link
App/Page/TranslateAdapter.swift        NEW  OpenTranslate ↔ OEWebContent (evaluate, events)
App/Page/CaptureLibraryWriter.swift    NEW  <root>/Captures + State/captures.json
App/Page/DeveloperModeStore.swift      NEW  per-host Developer Mode set
App/Page/TroubleshootingActions.swift  NEW  task manager, traces, info, data folder
App/EngineBridge.swift                 EDIT OpenWeb conformance for §3.2
App/Info.plist                         EDIT NSUserNotificationAlertStyle = banner
Helper/Info-Alerts.plist               NEW  alert style + display name (§4.5.2)
project.yml                            EDIT OpenHelperAlerts uses Helper/Info-Alerts.plist; link OpenTranslate
App/Automation/AutomationController.swift EDIT commands in §8.3
App/WebContent/EngineWebContentHost.swift EDIT EP-1 forwarding, swipe enable rules, zoomPercent (file from app-shell Step B)
App/TabStripMirror.swift               EDIT activation rules on requestsActivationOf (§4.5.4) (file from app-shell Step B)
App/Scripting/AppScriptEngineBridge.swift EDIT error 1013 gate (§4.10.2) (file from app-shell Step H)
Packages/OpenKit/Sources/OpenCommands/SuggestAdapter.swift EDIT hide `cast` from command-bar actions
Engine/OpenEngine/include/OpenEngine/*.h, Engine/OpenEngine/src/*.mm EDIT EP items (engine lead)
Engine/fork/patches/*, Engine/fork/src/cef/include/cef_open_page.h, Engine/fork/src/open/browser/page/* NEW fork items (engine lead)
tools/e2e/engine_e2e.py                EDIT suite `page` (§8.3)
tools/e2e/fixtures/page-platform/*     NEW  fixture pages (§8.3)
docs/automation.md                     EDIT new commands
```

`project.yml` engine settings belong to the engine lead (app-shell
appendix). The Alerts-helper plist line is an App change; coordinate in the
PR.

### 3.2 Protocol additions (OpenKit never imports OpenEngine)

`OpenWeb.WebContent` (the App makes `OEWebContent` conform in
`App/EngineBridge.swift`):

```swift
public struct PageSelection: Sendable, Equatable {
    public var text: String              // trimmed; "" when nothing is selected
    public var linkToHighlight: URL?     // page URL + #:~:text=…, nil if none could be made
}
public enum DevToolsPanel: Sendable { case `default`, elements, console, network, inspectMode }

public protocol WebContent: AnyObject {
    // … existing members …
    func selection() async -> PageSelection                 // EP-2, interim §4.2.4
    func fullPagePNG(maxDevicePixels: Int) async throws -> Data // EP-8
    func showDevTools(panel: DevToolsPanel)                  // EP-4
    func resetZoomAndScale()                                 // EP-5
}
```

`OpenFeatures.WebContentHost` (the App's `EngineWebContentHost` implements):

```swift
public enum HistorySwipePhase: Sendable { case began, changed, completed, cancelled }
public enum HistorySwipeDirection: Sendable { case back, forward }
public struct HistorySwipeEvent: Sendable { public var phase: HistorySwipePhase; public var direction: HistorySwipeDirection; public var progress: Double }

// added to WebContentHost
var onHistorySwipe: ((HistorySwipeEvent) -> Void)? { get set }   // EP-1
var zoomPercent: Int { get }                                     // round(100 * pow(1.2, zoomLevel))
var webContent: (any WebContent)? { get }                        // for capture, selection, translate
```

## 4. Feature specs

All frames are points. "Panel" means the web panel: the
`WebContentContainer` frame (`PanelMetrics.frame`, app-shell §3.2). Put every
number in `OpenDesign/PageTokens.swift`, never inline.

### 4.1 Toasts

#### 4.1.1 Behavior

- Anchor: the panel's top-right corner. Toast `maxX = panel.maxX − 10`,
  `minY = panel.minY + 8` (flipped coordinates) (PG-1.1). In Split View the
  anchor is the whole panel, not the focused pane (Open choice; guess). In
  HTML fullscreen the panel is the window content (inset 0). In Little Open
  the anchor is its page view.
- Overlap stacking (PG-1.8): a new toast appears at the anchor above the
  others. Every older visible toast starts its exit at once. At most 4 toast
  views exist; the oldest is removed first.
- Lifetime (PG-1.7): 3.0 s for a plain toast; 6.0 s for a toast with an
  accessory (guess, ≥ 5 s measured); an undo toast uses its source's undo
  window (Peek: 5 s, M4). The pointer over a toast pauses the timer; leaving
  restarts it with 1.5 s left (Open choice).
- A toast never takes focus and never becomes key. Only its accessory
  button takes clicks; the body passes clicks through
  (`ToastOverlayView.hitTest` returns nil outside accessories).
- Coalescing: a toast with the same `coalescingKey` (zoom) still makes a new
  toast view (Arc opens a new one per step, PG-1.8); the older one exits.
- Accessibility: post `NSAccessibility.Notification.announcementRequested`
  with the title (and subtitle) at medium priority. The accessory has an AX
  label ("Share", "Undo", "Stop", "Show in Finder", "Copy Quote Link").
- Reduce Motion (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`):
  fade only, no scale.

#### 4.1.2 Look (`ToastMetrics`, `SpaceThemeStyle` toast colors)

| Token | Value | Source |
|---|---|---|
| `ToastMetrics.height` | 42 | PG-1.2 (F0142) |
| `ToastMetrics.heightWithAccessory` | 46 | PG-1.2 (F0155) |
| `ToastMetrics.heightTwoLine` | 60 (title 14 pt + subtitle 12 pt) | guess |
| `ToastMetrics.topInset` / `trailingInset` | 8 / 10 | PG-1.1 |
| `ToastMetrics.cornerRadius` | 11, continuous | PG-1.4 |
| `ToastMetrics.leadingPadding` / `trailingPadding` | 12 / 12 | PG-1.3; trailing for text-only toasts is a guess (symmetric) |
| `ToastMetrics.labelToAccessory` | 8 | PG-1.3 |
| `ToastMetrics.accessoryTrailing` / `accessoryTop` | 10 / 10 | PG-1.3 |
| `ToastMetrics.accessorySize` | 32 × 27, radius 6 | PG-1.3; radius guess |
| `ToastMetrics.accessoryFill` | white 0.22 over the toast fill; pressed white 0.32 | PG-1.3 derived; pressed guess |
| `ToastMetrics.accessorySymbolSize` | 13 pt, white | guess |
| `ToastMetrics.minWidth` / `maxWidth` | 60 / 380; the title truncates in the middle | PG-1.2; max guess |
| `ToastMetrics.maxVisible` | 4 | PG-1.8 |
| `ToastMetrics.lifetime` / `accessoryLifetime` | 3.0 / 6.0 s | PG-1.7 |
| `ToastMetrics.shadow` | black 0.10, radius 8, y 2 | fitted on the hint toast (sidebar-completion §3.12) |
| `ToastMetrics.rim` | 1 px inner rim, black 0.20 | fitted on the hint toast (sidebar-completion §3.12); PG-1.5 shows the same darker edge rows |
| `Typography.toast` | 14 pt Medium, white 0.95 | PG-1.6; weight and alpha as measured on the hint toast (sidebar-completion §3.12) |
| `Typography.toastSubtitle` | 12 pt Regular, white 0.80 | guess |
| `SpaceThemeStyle.toastFillTop` / `toastFillBottom` | One rule shared with `HintToastTokens` (sidebar-completion §3.12): default dark theme `#442B68` → `#332350` (measured); other themes: the theme's tooltip fill lightened 6 % (top) and darkened 6 % (bottom) in OKLab L (guess there). Move the rule into `SpaceThemeStyle` so both views read one source. | PG-1.5: the olive Space measures bottom ≈ 0.77 × top in RGB, the same ratio as the hint's measured pair; use it as the second calibration point |
| `Motion.toastIn` | scale 0.3 → 1.0 with `SpringToken(response: 0.32, dampingFraction: 0.8)`; alpha 0 → 1 over 0.12 s linear | PG-1.9 (mid-animation text 12 × 6 pt against about 36 × 17 final, so the start scale is far below 0.9); numbers guess. sidebar-completion §3.12 guesses scale 0.9 for the hint; both should read this token |
| `Motion.toastOut` | alpha → 0 and scale → 0.96 over 0.20 s ease-out | guess |

Layout of one toast: `[icon?][title / subtitle][accessory?]`. Optional
leading SF Symbol 14 pt white at x 12, then 6 pt to the title. Title
baseline centered in the 42 pt height. With a subtitle the height is 60 and
the two lines center as a block with 2 pt between them.

#### 4.1.3 API (`OpenFeatures/Toasts/ToastCenter.swift`)

```swift
public struct ToastContent: Sendable, Equatable {
    public enum Accessory: Sendable, Equatable {
        case none
        case button(symbol: String, accessibilityLabel: String)   // 32×27 icon button
        case keycaps([String])                                    // "⌘", "⇧" plates before the title
    }
    public var title: String
    public var subtitle: String? = nil
    public var symbol: String? = nil
    public var accessory: Accessory = .none
    public var lifetime: TimeInterval? = nil      // nil → 3.0, or 6.0 with an accessory
    public var coalescingKey: String? = nil
    public var isSticky = false                   // stays until dismissed (trace recording)
}

@MainActor public final class ToastCenter {
    public init(overlay: ToastOverlayView, style: @escaping () -> SpaceThemeStyle)
    @discardableResult
    public func show(_ content: ToastContent, onAccessory: (() -> Void)? = nil) -> ToastHandle
    public func dismissAll()
    public var visible: [ToastContent] { get }    // automation
}
@MainActor public final class ToastHandle {
    public func update(_ content: ToastContent)   // same view, new text (trace timer, async quote offer)
    public func dismiss()
}
```

Undo toasts (Peek, and the sidebar-completion toasts) use
`.button(symbol: "arrow.uturn.backward", accessibilityLabel: "Undo")` and
the source's lifetime. Keycaps use the hint toast's measured plate: 27 pt
tall, radius 6, white 0.10, width = keycap ink + 18 (sidebar-completion
§3.12). The first-hide hint keeps its own window-anchored view (that plan);
it reads the same fill, rim, shadow, and text tokens.

#### 4.1.4 Toast catalog (every toast this plan adds or moves)

| Source | Title | Accessory | Lifetime | Evidence |
|---|---|---|---|---|
| Copy URL, nothing stripped | "Copied Current URL" | Share | 6 s | PG-1.10, F0155 |
| Copy URL, trackers stripped | "Copied a clean link without trackers" | Share | 6 s | PG-1.10 |
| Copy URL with a text selection and Shared Quotes on | title as above; subtitle "Share a link directly to this text instead?" | button `quote.bubble.fill` (copies the quote link) | 6 s | PG-1.11, PG-2.3 |
| Copy URL as Markdown | same titles as Copy URL | Share | 6 s | guess (Arc has no separate string) |
| Copy URL as Quote | "Copied Quote Link" | `quote.bubble.fill` symbol, no button | 3 s | guess (inline string not decoded, PG-1.11) |
| Zoom | "110%" (the percent) | none; `coalescingKey "zoom"` | 3 s | PG-3.1 |
| Full page capture running | "Capture in Progress" | none; sticky until done | — | PG-1.11 |
| Capture copied | "Copied Image" | none | 3 s | guess (comment "Confirmation toast when copying a captured image") |
| Capture shortcut hint | keycaps ⌘ ⇧ + "and drag your mouse to capture any time." | keycaps | 6 s | PG-1.11 |
| Translation done | "Translated to English" (target language name in the user's locale) | none | 3 s | PG-1.11 |
| Translation reverted | "Translated back to French" | none | 3 s | PG-1.11 |
| Translation failed | "Translation error (<reason>)" | none | 6 s | PG-1.11 |
| Developer Mode | "Developer Mode On" / "Developer Mode Off" | none | 3 s | guess |
| Trace recording | "Recording Trace…" with subtitle "m:ss" | button `stop.fill` (Stop) | sticky | PG-11 (`TracingToastContentOptions`) |
| Trace saved | "Trace Saved" | button `folder` (Show in Finder) | 6 s | guess |
| Copy Open Info | "Copied Open Info" | none | 3 s | PG-11 (wording guess) |
| Peek closed | "Peek closed" | Undo | 5 s | M4 (moved) |
| Folder deleted, Cleared Tabs, Folder restored | the sidebar-completion texts | Undo / none | 5 s | sidebar-completion §3 (moved onto `ToastCenter`) |
| Sleep discard failed, Boost failure | existing texts (app-shell §3.7) | none | 3 s | app-shell §3.7 (moved) |

### 4.2 Copy URL family

#### 4.2.1 Tracker stripping (`OpenModel/URLCleaner.swift`)

```swift
public enum URLCleaner {
    /// Removes known tracking query items. Keeps order, keeps the fragment.
    /// Returns the input unchanged for non-http(s) URLs.
    public static func clean(_ url: URL) -> (url: URL, removed: [String])
}
```

- Open's own table, three groups (PG-2.1 shows Arc has the same three
  classes). Global names: `fbclid`, `gclid`, `gclsrc`, `dclid`, `gbraid`,
  `wbraid`, `gad_source`, `msclkid`, `twclid`, `ttclid`, `yclid`, `igsh`,
  `igshid`, `mc_cid`, `mc_eid`, `_hsenc`, `_hsmi`, `mkt_tok`, `oly_anon_id`,
  `oly_enc_id`, `rb_clickid`, `s_kwcid`, `vero_id`, `wickedid`, `si` (only on
  `youtu.be`, `youtube.com`, `open.spotify.com`). Global prefixes:
  `utm_`, `hsa_`, `pk_`, `mtm_`, `matomo_`, `piwik_`. Per host (registrable
  domain): `amazon.*` → `pd_rd_*`, `pf_rd_*`, `ref_`, `ascsubtag`;
  `ebay.*` → `_trkparms`, `_trksid`; `youtube.com` → `feature`;
  `twitter.com`, `x.com` → `s`, `t`, `ref_src`.
- Case-insensitive name match. A URL with only tracking items loses its `?`.
- Used by `copy-url`, `copy-url-markdown`, `copy-url-quote`, the sidebar
  Copy button, the pane bar Copy button, and the Site Control Copy URL
  button. Share pickers get the cleaned URL. Navigation never changes.
- `openkit url-clean <url>` prints the cleaned URL and the removed names
  (§8.2).

#### 4.2.2 `copy-url` (Cmd+Shift+C)

1. Clean the focused page's URL (Peek: the top Peek page).
2. Write it to the general pasteboard as both `.URL` and `.string`.
3. Show the toast (§4.1.4). Share opens `NSSharingServicePicker` with the
   cleaned URL, anchored to the accessory button.
4. If `open.advanced.enableSharedQuotes` is on, ask `selection()` with a
   150 ms budget. When text is selected, update the same toast in place
   (`ToastHandle.update`) with the subtitle "Share a link directly to this
   text instead?" and the `quote.bubble.fill` button. The button runs
   `copy-url-quote`. A late answer (after the toast left) is dropped.

#### 4.2.3 `copy-url-markdown` (Cmd+Opt+Shift+C)

`[<title>](<clean URL>)`. Escape `\`, `[`, `]` in the title with `\`. An
empty title uses the host. Same toast as Copy URL.

#### 4.2.4 `copy-url-quote` (Cmd+Ctrl+Shift+C)

1. `selection()` (no budget; the user asked for it).
2. Non-empty text and a `linkToHighlight`: the link is the cleaned page URL
   plus the fragment directive from Chromium's generator (EP-2). Write the
   link as `.URL` and `.string`. Toast "Copied Quote Link".
3. Non-empty text but no link (generator error): if the text is at most 300
   characters, build `#:~:text=<percent-encoded text>` (exact match, no
   context) and continue as in 2; otherwise fall back to 4.
4. No text: behave as `copy-url` (Open choice; guess).
- Interim before EP-2 (`[OpenEngine only]`, marked in code `// Interim until
  EP-2`): `evaluateJavaScript("String(getSelection())")` in the main frame;
  the link always uses rule 3. Limits: no iframe selections; ambiguous text
  may scroll to the first match.
- Clipboard text form is a guess (PG-2.2). Capture C-Q1 decides whether
  Arc also writes the quote text.

#### 4.2.5 Share Quote affordance (under the URL field)

- Shows while `open.advanced.enableSharedQuotes` is on and the selected tab
  has a non-empty selection (EP-3 change bit; no interim: the affordance
  ships with EP-3). Title "Share Quote", symbol `quote.bubble` (PG-2.3).
- Click: runs `copy-url-quote` and shows its toast.
- Same view as the translation affordance (§4.7.3, `URLStatusButton`). If
  both apply, translation wins (Open choice).

### 4.3 Zoom toast, pinch zoom, smart zoom

- `zoom-in`, `zoom-out`, `zoom-actual-size` (and their duplicate key
  carriers): after the engine call, show the toast with
  `host.zoomPercent` (`round(100 × 1.2^zoomLevel)`; CEF steps through
  Chromium's presets, `components/zoom/page_zoom.cc:61-90`). Only commands
  show it; a per-host zoom restore on navigation does not (guess).
- `zoom-actual-size` also resets the pinch scale (Arc
  `resetZoomAndScaleFactors`, PG-3.2) through EP-5.
- Pinch and smart zoom: no code. Verify both on a fixture page (§8.3 Z2,
  Z3). No toast on pinch (guess, PG-3.2).
- Chrome's own zoom bubble must not appear on hosted tabs (§2.2). Check Z4.

### 4.4 Two-finger swipe back and forward

#### 4.4.1 Behavior

- Gesture recognition, direction (including the system "natural scrolling"
  inversion), the 8 % trackpad threshold, the Magic Mouse path, page
  scrolling priority, and `overscroll-behavior` stay Chromium's (D-3;
  `chrome_render_widget_host_view_mac_history_swiper.mm:20-32, 366-394,
  458-506`).
- The macOS "Swipe between pages" setting: Chromium 156 does not read it
  (`git grep isSwipeTrackingFromScrollEventsEnabled` finds nothing in
  `chrome/`, `content/`, `ui/`), but ArcCore does (`objc-selectors.txt:2154`).
  The shell sets `historySwipeEnabled` to
  `NSEvent.isSwipeTrackingFromScrollEventsEnabled` (re-read when the app
  becomes active), combined with the rules below.
- Every page host gets it: tab, each split pane, Peek page, Little Open.
  The swipe navigates the host under the pointer.
- Disabled (EP-1 `historySwipeEnabled = NO`) while: a capture overlay is
  up, a Zap picker is active, or the page is the command-bar backdrop.
- Before EP-1 lands, Chrome's own overlay shows. That is acceptable for the
  interim (D-12); name it in the PR.

#### 4.4.2 Indicator (`SwipeIndicatorView`, guess pending capture C-S1)

| Token | Value |
|---|---|
| `SwipeIndicatorMetrics.diameter` | 40 |
| `SwipeIndicatorMetrics.edgeInset` | 16 (from the page view edge when fully revealed) |
| Position | vertical center of the page view; x travels from `−diameter` (hidden) to `edgeInset` as progress goes 0 → 1 (mirrored for forward) |
| Fill | `SpaceThemeStyle.toastFillTop`; alpha `0.35 + 0.65 × progress` |
| Glyph | `chevron.backward` / `chevron.forward`, 17 pt Semibold, white |
| Ready state | at progress 1: scale 1.0 → 1.12 with `Motion.toastIn` spring; no haptic (no evidence) |
| Completed | fade out 0.18 s while the page navigates |
| Cancelled | slide back to hidden over 0.20 s ease-out |
| Reduce Motion | no slide: fade in at the final position |

#### 4.4.3 Wiring

`EngineWebContentHost` forwards EP-1 events to `onHistorySwipe`; the
container places one `SwipeIndicatorView` per pane, above the page view and
below the Peek scrim. The shell sets `drawsEngineHistorySwipeOverlay = NO`
on every host once the indicator ships.

### 4.5 Web notifications, end to end

#### 4.5.1 Flow

```text
page: new Notification() / SW showNotification()
  → Chromium permission check (content setting, per profile)      [OEWebContent decidePermissionRequest → Open prompt]
  → NotificationPlatformBridgeMac
      banner: MacNotificationServiceUN in the browser process (Open.app bundle)
      alert (requireInteraction / progress): Open Helper (Alerts).app
  → macOS Notification Center (needs macOS authorization for Open)
user clicks
  → Chromium UN delegate → NotificationDisplayServiceImpl → page click / SW notificationclick
  → [EP-6] browserContext:didClickNotification:… to the shell (fork)
  → page calls window.focus() / client.focus() → hosted tab: browser(_:requestsActivationOf:) (P1, free)
  → shell fallback after 500 ms if no activation arrived (§4.5.4)
```

#### 4.5.2 Bundle setup `[APP]`

- `App/Info.plist`: `NSUserNotificationAlertStyle = banner` (Chrome's app
  plist does the same, `chrome/app/app-Info.plist:715-716`).
- `Helper/Info-Alerts.plist` (new, for `OpenHelperAlerts` only): the keys of
  `Helper/Info.plist`, plus `NSUserNotificationAlertStyle = alert`,
  `CFBundleDisplayName = Open`, and the app icon file. Bundle id stays the
  release plan's (`io.github.sergeserb2.open.helper.alerts`). Evidence:
  `chrome/app/helper-alerts-Info.plist`; Arc's Alerts helper (PG-5.4).
- Never set `UNUserNotificationCenter.current().delegate` in the App (D-4).

#### 4.5.3 macOS authorization `[APP]` (`NotificationAuthorization.swift`)

- When the user picks Allow for a site's notifications (the permission
  prompt of app-shell §4.9, or the Site Control tile), and
  `getNotificationSettings().authorizationStatus == .notDetermined`, call
  `requestAuthorization(options: [.alert, .sound, .badge])` (Arc does the
  same, PG-5.2). The site permission is stored either way.
- `.denied`: the Site Control notifications tile shows the line
  "Notifications are off for Open in System Settings." and a button "Open
  System Settings" →
  `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=<main bundle id>`.
  Copy is Open's.
- Re-read the status when the app becomes active (it can change in System
  Settings).

#### 4.5.4 Click → tab

- Hosted tabs (the shell's default style): the page's own `focus()` call
  selects the tab through P1 (§2.2). The shell's `requestsActivationOf`
  handler must: focus the tab's Space in the tab's window, select the tab,
  bring the window front (it may be minimized: deminiaturize), and wake the
  tab if it sleeps.
- Fallback (Open choice; Arc behavior unknown, C-N1): EP-6 tells the shell
  which origin (and which live page, if any) the click belongs to. If no
  activation request arrives within 500 ms, select that page's tab; if the
  page is gone (discarded or closed), select the most recently active tab of
  that profile whose URL has the same origin; if none, do nothing beyond
  the app activation macOS already did.
- Persistent notifications that call `clients.openWindow(url)` open a new
  Today tab (P1 `didOpen`); nothing else to do.

#### 4.5.5 Settings and prompts

- Per-site state lives in Chromium's content settings (existing
  `permission`/`setPermission`). The Profiles pane row "Notifications"
  (settings P-10) opens the profile's notification settings page.
- Open does not add Arc's per-profile "notification permission requests"
  switch in v1 (PG-5.3; no Settings row is planned for it). guess: low value.

#### 4.5.5a As built (Step 7, s8/notifications, 2026-11-02)

- Bundles (§4.5.2): `App/Info.plist` has `NSUserNotificationAlertStyle =
  banner`; `Helper/Info-Alerts.plist` (only `OpenHelperAlerts`, set in
  `project.yml`) has `alert` and `CFBundleDisplayName = Open`. Section 8
  decision: no icon key yet, because the App has no icon file (both bundles
  show the generic icon); add `CFBundleIconFile` to both when the App gets
  its icon (`docs/followups.md`).
- Authorization (§4.5.3): `App/Page/NotificationAuthorization.swift`
  (`NotificationAuthorization.shared`, created on first use, re-read on every
  app activation, no timer). The prompt's Allow and
  `EngineWebProfile.setPermission(.allow, for: .notifications, …)` (Site
  Control) call `userAllowedNotifications()`, which asks macOS once while the
  status is `.notDetermined`. The automation `policy permissions=grant`
  short-circuit is not the user and asks nothing. Section 12 hook: `isDenied`,
  `deniedLine`, `openSettingsTitle`, `openSystemSettings()`,
  `didChangeNotification`.
- Activation (§4.5.4): `browser(_:requestsActivationOf:)` focuses the tab's
  Space in its window and selects the tab; selecting wakes it (the App's only
  wake path until OpenSleep is wired in the App; its wake call goes in that
  handler). The window comes front through Chromium's `ActivateContents` →
  `OpenBrowserWindow::Activate` (`[NSApp activate]`, `makeKeyAndOrderFront:`),
  which also restores a minimized window (N3). The shell adds no window code.
- e2e (`--only page --style chrome`): N3 triggers the activation with
  DevTools `Page.bringToFront`, which calls the same `WebContents::Activate`
  as `window.focus()` and `client.focus()`
  (`content/browser/devtools/protocol/page_handler.cc` `BringToFront`). Rows
  that need a notification click or the engine list report `BLOCKED: EP-7`.
  The App runs with `OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION=record`, so a
  run never shows the macOS prompt; U-N1 is the same suite with
  `OPEN_E2E_NOTIFICATION_PROMPT=1` (`docs/automation.md`).

#### 4.5.6 Tab sleep `[OpenKit]`

- New never-sleep gate `.notifications` in `SleepPolicy`: a tab whose
  origin has notification permission **Allow** in its profile is never
  frozen and never discarded by the sleep timers or debug sleep. Critical
  memory pressure may still discard it, as in Chrome, which protects such
  pages from freezing (`CannotFreezeReason::kNotificationPermission`,
  `components/performance_manager/freezing/freezing_policy.cc:794`) and from
  proactive discards only (`CannotDiscardReason::kNotificationsEnabled` under
  `is_proactive_or_suggested`,
  `chrome/browser/performance_manager/policies/discard_eligibility_policy.cc:361-365`).
- Input: `TabLiveState.notificationsAllowed: Bool`. The App sets it on every
  committed navigation (from `permissionState(for: .notifications, origin:)`)
  and on every permission change, and calls the sleep controller's existing
  change hook.
- Order: put `.notifications` right after `.keepAlive` in
  `SleepPolicy.Gate` (`SleepPolicy.swift:19`).
- `openkit sleep-demo` gains rows: a notification-allowed tab stays live
  past every mode's discard time; flipping the permission to Block lets it
  freeze on the next pass.

### 4.6 Capture

#### 4.6.1 Entry points

| Entry | Mode | Notes |
|---|---|---|
| File ▸ Capture… (Cmd+Shift+2), Site Control "Capture a portion of this page", page context menu "Capture" | area | PG-6.1 |
| File ▸ Capture Full Page, Site Control, page context menu "Capture Full Page" | full page | PG-6.1 |
| File ▸ Capture in Portrait Mode, Site Control | portrait | PG-6.1 |
| Hold Cmd+Shift, then drag on a page | area, starting at the press point | PG-6.1; `open.capture.dragToCaptureEnabled` |

Enabled key `hasWebPage` (§7.1): a live http(s), file, or data page in the
focused host. Captures also work in incognito windows, but they are not
saved to the Library there (Open choice: incognito leaves no history). The
result card then offers Copy, Save…, and Share only.

#### 4.6.2 Cmd+Shift drag

- A local mouse-down monitor in the window controller sees a left
  mouse-down with exactly Cmd+Shift over a page view. It holds the event.
- If the pointer moves ≥ 4 pt before mouse-up, start the area overlay with
  the press point as one corner.
- If mouse-up comes first, replay the held mouse-down and the mouse-up to
  the page view, so Cmd+Shift-click on a link still opens a foreground tab
  (Open choice; guarded by check C6).
- Off when `open.capture.dragToCaptureEnabled` is false (Arc's
  `dragToCaptureDisabled`, PG-6.2).

#### 4.6.3 Area overlay (`CaptureOverlayView`, guess pending capture C-C1)

| Token | Value |
|---|---|
| Covers | the focused page view only (Open choice; FA §9.15 q1 is open) |
| Dim | black 0.35 outside the selection |
| Selection edge | 1 pt white 0.95 inside, 1 pt black 0.25 outside |
| Size label | `W × H` in page points, `Typography.captureSizeLabel` (11 pt Medium, monospaced digits), white on black 0.65, height 20, radius 5, 6 pt below the selection (above it if there is no room) |
| Hint capsule | "Drag to capture. Press Esc to cancel." 13 pt Medium, white on `toastFillTop`, height 28, radius 14, centered, 16 from the page top; fades out when the drag starts |
| Cursor | `NSCursor.crosshair` |
| Minimum | 8 × 8 pt; a smaller drag cancels |
| Keys | Esc cancels; Return captures the whole visible page |

#### 4.6.4 Pipeline

- Area: `takeSnapshot` (device pixels of the visible page), then crop to
  the selection × `png.width / view.bounds.width`. No engine change.
- Full page (EP-8): run in the page `document.querySelectorAll('img[loading=lazy]').forEach(i => i.loading = 'eager')`,
  wait up to `CaptureMetrics.fullPageSettle` = 1.0 s for pending images
  (PG-6.4 `FullPageCaptureDelay`, value guess), then capture tiles. Show the
  sticky "Capture in Progress" toast while it runs. Cap at
  `CaptureMetrics.fullPageMaxDevicePixels` = 32 768 px tall (guess; memory
  bound); a taller page is cut, and the result card says "Page cut at
  32,768 px."
- Portrait (guess pending capture C-C2): visible page snapshot on a 4:5
  canvas. Canvas width = snapshot width ÷ 0.86. Background:
  `open.capture.portraitBackground` (`theme` = the Space theme field
  rendered with `ThemeField`; `white`; `black`). The page image is
  centered, width 86 % of the canvas, corner radius 2 % of its width,
  shadow black 0.25, blur 3 % of its width, y offset 1 %. No watermark
  (Open never draws a brand mark).
- Encode the PNG off the main actor (a utility-priority task that gets only
  the image data). Encoding is not UI work, so app-shell §2.4 rule 7 does not
  apply.

#### 4.6.5 Result card (`CaptureResultView`, guess pending C-C1)

- Shows at the toast anchor (§4.1.1) and replaces visible toasts.
  Chrome: same as the Site Control panel (`site-control-boost-editor.md`
  §3.2: `Core.popoverBackground`, radius 12, hairline edge, shadow black
  0.25 radius 16 y 6).
- Width 248. Padding 12. Thumbnail aspect-fit, max height 160, radius 8.
  Line under it: "Saved to Library" (11 pt, `Core.foregroundSecondary`),
  or nothing in incognito.
- Action row: 28 × 28 buttons, radius 6, gap 6, symbols 15 pt: Copy
  (`doc.on.doc`), Save… (`square.and.arrow.down`), Share
  (`square.and.arrow.up`), Show in Library (`photo.on.rectangle`), Retake
  (`arrow.counterclockwise`, area only; PG-6.5 "Action to retake capture."),
  Delete (`trash`).
- Cmd+C copies the image while the card shows. Esc closes it. Lifetime 8 s;
  pointer over the card pauses it.
- Save… opens `NSSavePanel` with the default name
  `<title> <MM-dd> at <h.mma>.png`: title with characters outside
  `[A-Za-z0-9-_ ]` removed (PG-6.4; assembly guess).

#### 4.6.6 Storage (`CaptureLibraryWriter`, App)

- Every non-incognito capture writes `<root>/Captures/<uuid>.png` and
  appends `{ "id", "fileName", "createdAt", "kind": "area|fullPage|portrait",
  "sourceHost" }` to `<root>/State/captures.json` (the schema in
  settings-library §2.6), atomically (temp file, then rename). Library ▸
  Captures shows it on its next refresh (Library reads the index).
- Delete on the card removes the file and the row in one step.

#### 4.6.7 Shortcut hint

After a capture started from a menu, the Site Control panel, or the context
menu, show the keycap toast (§4.1.4) when
`now − open.capture.shortcutHintLastShown > 14 days` (guess for Arc's
`captureShortcutLastSeen` cadence), then store `now`.

#### 4.6.8 Sound hook

`CaptureController.onCaptured` calls `SoundEffects.shared.play(.capture)`
(sidebar-completion §3.13: Open's own `open-capture.caf`, played only when
`open.advanced.playSoundEffects` is on). If that plan's step has not landed,
leave a `// TODO(sound)` at this call site.

### 4.7 Page translation

#### 4.7.1 Options considered

| Option | What | Cost | Verdict |
|---|---|---|---|
| A. Chromium translate + Google key | Turn on Chromium's pipeline with a Google API key | Needs a Google agreement for a shipping key; Chromium's own key notice says developer keys are for personal builds only. Also needs a bubble bridge (§2.1 T-1) and the language model (key-gated). | Not possible without a Google deal |
| B. Chromium state machine + Open backend | Keep Chromium's translate UI state, swap `element.js` (`--translate-script-url`) for an Open shim that calls a local backend; patch out the key gate | Two fork patches, a CEF scheme handler, a shim of Google's element API, and still no language model | High cost for little reuse |
| **C. Open-owned, on-device (chosen, D-2)** | Apple `Translation` + `NaturalLanguage`, Open's page runtime | No fork patch; needs the isolated world (P7 / Site Control E5) for safety | Recommended |
| D. Nothing in v1 | — | — | Status gap 8 stays open |

Option C limits: Apple supports fewer languages than Google (about 20
pairs; `LanguageAvailability().supportedLanguages`); a language pair may
need a one-time download that macOS asks for. Name both in the PR.

#### 4.7.2 Detection and offer (`PageLanguageDetector`, `PageTranslationSession`)

1. On a main-frame load that finishes with status 2xx on an http(s) page,
   and only for the focused host of a visible window (no work for
   background tabs): skip when `open.translate.enabled` is false or the
   host is in `open.translate.neverTranslateHosts`.
2. Run the probe in the page: `{ lang: document.documentElement.lang,
   text: <first 2,000 characters of body.innerText> }`.
3. `NLLanguageRecognizer` on the text. Use its dominant language when the
   top hypothesis is ≥ 0.80 (guess); else use the `lang` attribute; else stop.
4. Target = the first `Locale.preferredLanguages` entry whose language
   `LanguageAvailability().status(from:to:)` reports as `.installed` or
   `.supported`. Stop when the source language equals the target language
   (compare `Locale.Language.languageCode`), or when no target is supported.
5. Offer: show the status button "Translation Available" (§4.7.3). No
   automatic popover (Open choice; Arc's trigger is unknown).

#### 4.7.3 UI

Status button (`OpenSidebar/URLStatusButton.swift`, `URLStatusMetrics`;
PG-7.3, values guess pending capture C-R1):

| Token | Value |
|---|---|
| Frame | `[8, 88, W − 16, 28]` in sidebar space (6 pt under the URL field `[8, 46, W − 16, 36]`, `docs/design.md` §2.2); content below moves down 34 pt with `Motion.rowStructure` |
| Fill / radius | `SidebarItemBackground` (the URL field fill) / 8 |
| Content | symbol `translate` 13 pt + 6 pt + title, `Typography.statusButton` (12 pt Medium), sidebar secondary text color; centered |
| Titles | "Translation Available"; "Translation…" when the button is 200 pt wide or less; "Translated" after translation; "Translating…" with a 12 pt spinner while it runs (guess) |
| Hidden | sidebar hidden (the hover-reveal card shows it), Peek showing, no offer |

Popover (`OpenFeatures/Translate/TranslatePopoverView.swift`, a child panel
with the Site Control panel chrome, `site-control-boost-editor.md` §3.2):

| Part | Value |
|---|---|
| Anchor | under the status button, arrow up (sidebar hidden: the toast anchor) |
| Width / padding | 300 / 16 |
| Offer state | title "Translate this page to English?" (13 pt Semibold; `%@` = target name in the user's locale); buttons in one row: "Translate" (primary: height 28, radius 7, `Core.brandBlue` fill, white 13 pt Medium) and "Options" (a pull-down, plain) |
| Translated state | title "Translated from French."; buttons "Show Original" (primary) and "Options" |
| Options menu | "Choose Another Language" ▸ (each supported target, current checked) · "Never Translate This Site" · separator · "Language Settings…" (opens System Settings ▸ General ▸ Language & Region, where macOS manages translation languages) |
| Errors | inline line 12 pt `Core.foregroundSecondary` under the title, plus the error toast |
| Close | Esc, click outside, or any action |

Button labels "Translate", "Show Original", "Options" are guesses (inline
strings, PG-7.3). The other strings are Arc's (PG-7.3).

#### 4.7.4 Page runtime (`translate-runtime.js`)

- Injected on demand (after the user asks) into an **isolated world**
  through P7 / Site Control E5. Until that lands, run in the main world and
  mark the install site `// Blocked on P7: isolated world` (app-shell D8
  rule). Page scripts can see the runtime until then; state it in the PR.
- Text units: walk `document.body` with a `TreeWalker`. Skip `script`,
  `style`, `noscript`, `code`, `pre`, `kbd`, `samp`, `textarea`, `input`,
  `select`, `[translate=no]`, `.notranslate`, `[contenteditable]`, and SVG
  text. A unit is one block element's inline content with inline elements
  replaced by numbered markers `⟦n⟧…⟦/n⟧`; if the backend drops a marker,
  that unit falls back to per-text-node translation (Open choice).
  Attributes: `placeholder`, `title`, `alt`, `aria-label`, and the `value`
  of `input[type=button|submit|reset]`.
- Order: units in or near the viewport first (`IntersectionObserver`,
  `rootMargin: "100% 0px"`), then the rest as they come near. New nodes
  (`MutationObserver`, 300 ms debounce) join the queue while the page is in
  translated mode.
- Batches: at most 40 units or 4,000 characters. Channel: the shell pulls
  with `evaluate("__openTranslate.nextBatch()")`, which resolves when a
  batch is ready (no polling timer), then returns results with
  `__openTranslate.apply(batchID, results)`.
- Revert: originals are kept in a `WeakMap`; `restore()` puts every text
  node and attribute back and stops the observers.
- Same-document navigation (`pushState`) keeps translated mode. A new
  document resets it; if the user translated this host in this tab, the
  new page translates automatically to the same target until Show Original
  (Open choice, like Chrome's per-tab behavior).

#### 4.7.5 Backend (`AppleTranslationBackend`)

- `TranslationSession(installedSource:target:)` (macOS 26.0,
  `Translation.swiftinterface:187-188`) and `translate(batch:)`
  (line 182) for installed pairs.
- Pair `.supported` but not installed: create the session through a
  zero-size `NSHostingView` with `.translationTask(configuration)` inside
  the popover and call `prepareTranslation()` (line 184), which shows the
  system download prompt. This is the only SwiftUI in the feature.
- Errors map to the toast "Translation error (<localized reason>)".
- One backend per window; one session per (source, target) pair, reused.

#### 4.7.6 Undo and toasts

- Translate and Show Original register undo actions named "Translate" in
  the window's undo manager (PG-7.3), so Edit ▸ Undo Translate reverts.
- Toasts: §4.1.4.

#### 4.7.7 Memory

- "Never Translate This Site" appends the host (lowercased, without
  `www.`) to `open.translate.neverTranslateHosts`, reverts the page if it is
  translated, and hides the status button.
- Settings ▸ Advanced ▸ "Reset Translated-site Prompts" clears the list
  (the settings action `resetTranslatePrompts` calls
  `TranslatePreferences.reset()`).

#### 4.7.8 As built (Steps 9 and 10, s8/translate, 2026-11-02)

Section 8 decisions, where this section left a choice open:

- Tokens live in `OpenDesign/TranslateTokens.swift` (not `PageTokens.swift`),
  so Step 1 and Step 9 never edit one new file at once.
- The push-down is in `SidebarView.layout` (the view that places Favorites and
  the Space list); `ChromeViews.swift` is unchanged.
- The status button also hides while the content toolbar replaces the URL
  field (guess; no capture).
- Detection also runs when a tab whose current document was never probed
  becomes focused (a page loaded in the background still offers once seen).
  Background tabs still cost nothing.
- The popover is a borderless child panel that never becomes key, so it shows
  above Chrome-style pages; Esc and Return reach it through
  `BrowserWindowController.keyInterceptor`.
- Context menu: Chromium never adds `IDC_CONTENT_CONTEXT_TRANSLATE` without a
  Google key, so the App adds "Translate to <language>" / "Show Original".
- Edit ▸ Undo Translate works with the focus outside the page; Cmd+Z in a
  focused page is Chromium's editing undo (`docs/followups.md`).
- e2e runs on an automation-only fixture backend (French → English word list)
  because no Apple language pair is installed on the test Mac (U-X1); the row
  `X1_apple_backend` runs on Apple's backend once the pair is installed.
- Runtime limits: 20,000 units per start, 20,000 characters per unit, batches
  of 40 units / 4,000 characters (`translate-runtime.js`, `TranslationBatch`).

### 4.8 Website appearance

- View ▸ Appearance: the existing header "Websites will use:" and three
  radio items Automatic, Light, Dark with a checkmark on the current value
  (`menuState`, §7.1). Store `open.web.colorScheme`.
- On change (and at launch for each context as it is created), set every
  `OEBrowserContext.websiteColorScheme` (EP-9). Open pages update without a
  reload (`prefers-color-scheme` change event).
- First try stock CEF (EP-9a). If check A1 or A2 fails on hosted or Alloy
  pages, the engine lead lands EP-9b.
- Boost color schemes per site are the Boost editor's (Site Control plan).

### 4.9 Clear Cache and Refresh, Clear Cookies and Refresh

| Command | With Site Control E2 | Before E2 |
|---|---|---|
| `clear-cookies-and-refresh` | `clearSiteData(origin:kinds:[.cookies])` for the focused page's origin, then `reload()` | `clearBrowsingData(origin:)`, then `reload()`; this also drops every site's HTTP cache (state it in the PR) |
| `clear-cache-and-refresh` | `clearSiteData(origin:kinds:[.cache])`, then `reloadIgnoringCache()` | disabled (enabled key `siteDataClearAvailable`), like the Site Control panel's Clear Cache |

Scope follows Chromium's Clear-Site-Data rules for the origin's site
(PG-9: per site; guess). No toast: the reload is the feedback (guess).
Peek: the top Peek page.

### 4.10 Developer menu

#### 4.10.1 Panels

| Command | Action | Engine |
|---|---|---|
| `developer-tools` (F12, Cmd+Opt+I) | `showDevTools(panel: .default)` | exists |
| `javascript-console` (Cmd+Opt+J) | `.console` | EP-4a |
| `inspect-elements` (Cmd+Opt+C) | `.inspectMode` (DevTools opens with the element picker on) | EP-4a |
| `network-inspector` | `.network` | EP-4b; before it, `.default` and the PR names the gap |
| `view-source` (Cmd+Opt+U) | open `view-source:<url>` as a new Today tab under the current one | none (app-shell §4.3) |

#### 4.10.2 Allow JavaScript from Apple Events

- Checkmark item. Store `open.developer.allowJavaScriptFromAppleEvents`,
  default **false** (Chromium's default, T-13; Arc keeps Chromium's pref,
  PG-10.4).
- When false, OpenScripting's `execute` returns error 1013 with the text
  "JavaScript from Apple Events is off. Turn it on in View ▸ Developer."
  This changes applescript plan Q5 (open question Q3 here).

#### 4.10.3 Developer Mode (per site)

Proven (PG-10.2): a per-host on/off state, Ctrl+D, the menu title "Turn on
Developer Mode for this site" / "Turn off Developer Mode for this site",
and a Site Control row "Developer Mode" On/Off. The effect is unknown
(PG-10.3). v1 (Open choice, open question Q6):

- `DeveloperModeStore` keeps `open.developer.modeHosts` (lowercased hosts).
- `toggle-developer-mode`: toggles the focused page's host; toast "Developer
  Mode On" / "Developer Mode Off". The menu item is hidden when the focused
  page is not http(s) or file (`menuState.isHidden`).
- Effect in v1: the sidebar URL field shows the full URL (host, port, path,
  query) instead of the host for that host (guess), and the Site Control
  Developer Mode tile shows and toggles the same state (this lifts
  `site-control-boost-editor.md` Q2).
- Anything else waits for capture C-D1.

### 4.11 Help ▸ Troubleshooting

#### 4.11.1 Open Task Manager

`OEEngine.showTaskManager()` (EP-10a): Chromium's task manager window
(D-8). If check H1 shows it fails in our hidden-window setup, build the
fallback: one Open window (`NSPanel`, 560 × 420, titled "Task Manager"),
an `NSTableView` with columns Task (favicon + title), Memory, CPU, refreshed
every 1.0 s only while the window is visible (idle CPU rule), and an "End
Process" button for killable rows (EP-10b). The window title says "Open"
where Chromium's says "Chromium" once the branding patch lands; until then
name the gap in the PR.

#### 4.11.2 Record Trace, Cancel Trace

- `record-trace`: `OEEngine.beginTracing(categories: nil)` (EP-11), then the
  sticky toast "Recording Trace…" with the elapsed time and a Stop button.
  It stops by itself after `TroubleshootingDefaults.maxTraceSeconds` = 60
  (guess for Arc's `tracingDuration`).
- Stop: `endTracing(to:)` writes
  `~/Downloads/Open Trace <yyyy-MM-dd HH.mm.ss>.json`, then the toast "Trace
  Saved" with Show in Finder.
- `cancel-trace` (enabled only while recording): `OEEngine.cancelTracing()`
  (ends into a temporary file and deletes it).
- `record-trace` is disabled while recording. Traces can contain URLs;
  CEF's API has no privacy filter (Arc has one, PG-11). State it in the
  PR.

#### 4.11.3 Copy Open Info

Pasteboard text, then the toast "Copied Open Info":

```text
Open <CFBundleShortVersionString> (<CFBundleVersion>)
Engine: Chromium <OEEngine.chromiumVersion>, CEF <OEEngine.cefVersion>
macOS <ProcessInfo.operatingSystemVersionString>
Mac: <hw.model> (<architecture>)
```

No URLs, no profile names, no paths.

#### 4.11.4 Reveal Open Data

`NSWorkspace.shared.activateFileViewerSelecting([dataRoot])` with the data
root (`~/Library/Application Support/Open`, or the automation root).

### 4.12 Cast (decision: out of v1)

- What Cast needs: Chrome's tab and desktop mirroring runs through the
  media router UI model and the mirroring service. Chrome's dialog is a
  Views dialog anchored to a browser view; the hidden P1 window has none.
  CEF's public `CefMediaRouter` only launches `cast:`/`dial:` apps on a
  device (T-12); it cannot mirror a tab.
- Cost estimate (guess): engine bridge (sinks, start and stop tab mirroring
  through `MediaRouterUI` without Views) 2–3 weeks; Open's device picker
  and casting indicator 1 week; macOS Local Network permission
  (`NSLocalNetworkUsageDescription`, `NSBonjourServices` `_googlecast._tcp`)
  and its prompt; a real Chromecast or Google TV for every test (an
  automation fixture would need Open Screen's standalone receiver built from
  the Chromium tree).
- Arc has it (PG-12). It is not in the AGENTS.md v1 list.
- v1 actions:
  1. Hide View ▸ Cast… (`menuState(for: "cast").isHidden = true`) and remove
     it from command-bar actions.
  2. Start the engine with `--disable-features=MediaRouter`
     (`OEEngine` default switch, EP-12). `MediaRouterEnabled()` then
     returns false (`media_router_feature.cc:102-106`): no discovery, no
     Cast button on `<video>` controls, no Local Network prompt.
  3. Drop Chrome's "Cast…" item from `OEContextMenu` on hosted tabs (PR #53
     follow-up).
- Revisit after v1 with the cost above.

## 5. Settings keys

Add these rows to `docs/plans/settings-library.md` §2.1 (this PR does) and
to `SettingsDefaults.values` (Step 1 of this plan's library work). All are
app scope (`UserDefaults.standard`). No new per-profile field.

| Key | Type | Default | Used by |
|---|---|---|---|
| `open.translate.enabled` | Bool | `true` | Translation offer (§4.7.2). No Settings row in v1 (Arc's `translate-enabled`). |
| `open.translate.neverTranslateHosts` | [String] (lowercase hosts) | `[]` | §4.7.7. Cleared by "Reset Translated-site Prompts". |
| `open.capture.dragToCaptureEnabled` | Bool | `true` | Cmd+Shift drag (§4.6.2). No Settings row in v1. |
| `open.capture.shortcutHintLastShown` | Double (Unix time) | `0` | §4.6.7 |
| `open.capture.portraitBackground` | String (`theme`/`white`/`black`) | `theme` | §4.6.4 (guess) |
| `open.web.colorScheme` | String (`automatic`/`light`/`dark`) | `automatic` | §4.8 |
| `open.developer.allowJavaScriptFromAppleEvents` | Bool | `false` | §4.10.2 |
| `open.developer.modeHosts` | [String] (lowercase hosts) | `[]` | §4.10.3 |

Existing keys this plan reads: `open.advanced.enableSharedQuotes` (A-7,
§4.2), `open.advanced.playSoundEffects` (A-8, §4.6.8). Existing action:
"Reset Translated-site Prompts" (§5.5 buttons row).

## 6. Engine API requests (for the engine lead's queue)

Fork series `05xx` (D-11). Effort numbers are guesses for one engineer who
knows Chromium. `[OpenEngine only]` items need no fork patch.

| ID | Request | Kind (built in) | Needed by | Effort (guess) |
|---|---|---|---|---|
| EP-1 | History swipe events and overlay control | ENGINE fork `0501` (Step 11) | Step 12 | 3–4 days |
| EP-2 | Page selection and link to highlight | ENGINE fork `0502` (Step 14) | Step 15 (interim JS from Step 3) | 3 days |
| EP-3 | Selection change bit | ENGINE fork `0502` (Step 14) | Step 15 | 1 day with EP-2 |
| EP-4a | Console panel and Inspect mode on hosted tabs | OpenEngine only (Step 4) | Step 5 | 1 day |
| EP-4b | Network panel | ENGINE fork `0503` (Step 16) | Step 16 | 1–2 days |
| EP-5 | `resetZoom` also resets pinch scale | OpenEngine only (Step 3) | Step 3 | 0.5 day |
| EP-6 | Notification click report | ENGINE fork `0504` (Step 16) | Step 16 | 2–3 days |
| EP-7 | Notification test hooks (automation builds) | ENGINE fork `0504` (Step 16) | Step 16 | 1 day |
| EP-8 | Full-page capture | OpenEngine only (Step 13) | Step 13 | 2 days |
| EP-9a | Website color scheme via stock CEF | OpenEngine only (Step 4) | Step 5 | 0.5 day |
| EP-9b | Website color scheme via web prefs (only if A1 or A2 fails) | ENGINE fork `0505` | Step 17 | 2 days |
| EP-10a | Show Chromium's task manager | OpenEngine only (Step 4) | Step 5 | 0.5 day |
| EP-10b | Kill task, killable flag, task for a page (fallback only) | OpenEngine only (Step 4) | Step 5 (if H1 fails) | 1 day |
| EP-11 | Tracing | OpenEngine only (Step 4) | Step 5 | 1 day |
| EP-12 | Media router off by default | OpenEngine only (Step 4) | Step 5 | 0.5 day |
| (reuse) | Per-site data clear | Site Control E2 | Step 6 | — |
| (reuse) | Isolated-world evaluate | P7 / Site Control E5 | Step 19 (Step 10 runs without it) | — |

New public CEF API goes into one Open header,
`Engine/fork/src/cef/include/cef_open_page.h` (translator rules as in
`docs/engine-patches.md`, `CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`),
with overlay code under `Engine/fork/src/open/browser/page/`.

### EP-1. History swipe events and overlay control

```objc
typedef NS_ENUM(NSInteger, OEHistorySwipePhase) {
  OEHistorySwipePhaseBegan = 0, OEHistorySwipePhaseChanged,
  OEHistorySwipePhaseCompleted, OEHistorySwipePhaseCancelled,
};
typedef NS_ENUM(NSInteger, OEHistorySwipeDirection) {
  OEHistorySwipeDirectionBack = 0, OEHistorySwipeDirectionForward,
};

@protocol OEWebContentDelegate <NSObject>
@optional
/// Chromium's history swiper changed state. `progress` is 0...1; 1 means the
/// swipe will navigate when the gesture ends. Main thread.
- (void)webContent:(OEWebContent*)webContent
      historySwipe:(OEHistorySwipePhase)phase
         direction:(OEHistorySwipeDirection)direction
          progress:(double)progress
    NS_SWIFT_NAME(webContent(_:historySwipe:direction:progress:));
@end

@interface OEWebContent (HistorySwipe)
/// Default YES. NO makes Chromium's swiper ignore gestures on this page.
@property(nonatomic) BOOL historySwipeEnabled;
/// Default YES. NO hides Chromium's own arrow overlay (the shell draws its own).
@property(nonatomic) BOOL drawsEngineHistorySwipeOverlay;
@end
```

Chromium source: `chrome/browser/renderer_host/chrome_render_widget_host_view_mac_history_swiper.mm`
(`showHistoryOverlay:`, `updateProgressBar` lines 366-394, `removeHistoryOverlay`,
the Magic Mouse handler lines 458-506) and
`chrome/browser/renderer_host/chrome_render_widget_host_view_mac_delegate.mm`
(`shouldAllowHistorySwiping`, `navigateInDirection:onWindow:`). Patch: one
hook call at each of the four points into
`open/browser/page/history_swipe_hook.{h,mm}`, which finds the CEF browser
for the WebContents (`CefBrowserHostBase::GetBrowserForContents`) and calls
`CefOpenPageHandler::OnHistorySwipe`; `shouldAllowHistorySwiping` also reads
the per-page enabled flag; the overlay controller is skipped when the page
asked for no engine overlay. Arc equivalent: the gesture-handler bridge
(PG-4.1), which is larger.

### EP-2. Page selection and link to highlight

```objc
@interface OEWebContent (Selection)
/// Selected text of the focused frame (any frame, including cross-site
/// iframes) and a link that scrolls to it: the page URL plus a text-fragment
/// directive from Chromium's generator. `link` is nil when no unique
/// selector could be made. Empty string when nothing is selected.
- (void)requestSelectionWithCompletion:
    (void (^NS_SWIFT_UI_ACTOR)(NSString* text, NSURL* _Nullable link))completion
    NS_SWIFT_NAME(requestSelection(completion:));
@end
```

Chromium source: text from `WebContents::GetFocusedFrame()->GetView()->GetSelectedText()`
(`content/public/browser/render_widget_host_view.h:156`); selector from
`blink::mojom::TextFragmentReceiver::RequestSelectorForSelection()`
(`third_party/blink/public/mojom/link_to_text/link_to_text.mojom:77-79`)
through the focused frame's remote interfaces, as
`LinkToTextMenuObserver` does
(`chrome/browser/renderer_context_menu/link_to_text_menu_observer.cc:55-61`);
URL from `shared_highlighting::AppendFragmentDirectives`
(`components/shared_highlighting/core/common/fragment_directives_utils.h:45`).
For a selection inside an iframe, `link` is nil (a text directive on the
top URL cannot reach a child document); `text` is still returned (Open
choice). Arc equivalent: `ArcWebContents.selectedText` (PG-2.2).

### EP-3. Selection change bit

`OEWebContentChangeSelection = 1u << 15`: the selection became empty or
non-empty (not every caret move), at most every 100 ms. Source:
`RenderWidgetHostViewBase::GetTextInputManager()` observer
`OnTextSelectionChanged` (`content/browser/renderer_host/text_input_manager.h`).
Property: `@property(nonatomic, readonly) BOOL hasSelection;`.

### EP-4. DevTools panels

```objc
typedef NS_ENUM(NSInteger, OEDevToolsPanel) {
  OEDevToolsPanelDefault = 0, OEDevToolsPanelElements, OEDevToolsPanelConsole,
  OEDevToolsPanelNetwork, OEDevToolsPanelInspectMode,
};
@interface OEWebContent (DevToolsPanels)
- (void)showDevToolsPanel:(OEDevToolsPanel)panel NS_SWIFT_NAME(showDevTools(panel:));
@end
```

- EP-4a (OpenEngine only): Chrome-style pages call
  `CefBrowserHost::ExecuteChromeCommand` with `IDC_DEV_TOOLS_CONSOLE`
  (40005) or `IDC_DEV_TOOLS_INSPECT` (40023) (`chrome/app/chrome_command_ids.h:223, 241`;
  map names with `cef_id_for_command_id_name`). Alloy pages fall back to
  `ShowDevTools`.
- EP-4b (fork `0503`): add `panel_id` to CEF's show-DevTools parameters
  and pass `DevToolsOptions{.panel_id = "network"}` in
  `CefDevToolsWindowRunner::ShowDevTools`
  (`cef/libcef/browser/devtools/devtools_window_runner.cc:41-43`). Chrome
  uses `panel_id` for `kShow` (`chrome/browser/devtools/devtools_window.cc:896-913`).
  Arc equivalent: `ArcWebContentsDevTools openNetworkView` (PG-10.1).

### EP-5. Reset pinch scale with zoom

`-[OEWebContent resetZoom]` also sends DevTools `Emulation.resetPageScaleFactor`
(`third_party/blink/public/devtools_protocol/domains/Emulation.pdl:226`).
No new API. Arc equivalent: `resetZoomAndScaleFactors` (PG-3.2).

### EP-6. Notification click report

```objc
@protocol OEBrowserContextDelegate <NSObject>
@optional
/// The user clicked a web notification of this context (body or button),
/// before Chromium dispatches the click to the page. `webContent` is the
/// page that created a non-persistent notification while that document is
/// alive; nil for service-worker notifications and gone documents.
- (void)browserContext:(OEBrowserContext*)context
    didClickNotificationWithIdentifier:(NSString*)identifier
                                origin:(NSURL*)origin
                            webContent:(nullable OEWebContent*)webContent
                            persistent:(BOOL)persistent
    NS_SWIFT_NAME(browserContext(_:didClickNotification:origin:webContent:persistent:));
@end
```

Chromium source: `NotificationDisplayServiceImpl::ProcessNotificationOperation`
(`chrome/browser/notifications/notification_display_service_impl.cc`), the
non-persistent listener map with its `WeakDocumentPtr`
(`content/browser/notifications/notification_event_dispatcher_impl.h:74-90`).
Arc equivalent: `ArcNotification didClick:input:` (PG-5.1).

### EP-7. Notification test hooks (automation builds only)

```objc
@interface OEBrowserContext (NotificationTesting)
- (void)displayedNotificationsWithCompletion:
    (void (^NS_SWIFT_UI_ACTOR)(NSArray<NSDictionary<NSString*, id>*>* items))completion; // id, origin, title, body
- (void)simulateClickOnNotificationWithIdentifier:(NSString*)identifier;
@end
```

Active only when the engine runs with the `--open-automation` switch
(OpenEngine adds it in Debug and `OPEN_AUTOMATION=1` builds); otherwise the
list is empty and the click does nothing. Source:
`NotificationDisplayService::GetDisplayed` and the same
`ProcessNotificationOperation(kClick, …)` path as a real click after macOS
hands the response to Chromium.

### EP-8. Full-page capture (OpenEngine only)

```objc
@interface OEWebContent (Capture)
/// PNG of the whole page at device scale, at most `maxDevicePixels` tall.
- (void)captureFullPageWithMaxDevicePixels:(NSInteger)maxDevicePixels
                                completion:(void (^NS_SWIFT_UI_ACTOR)(NSData* _Nullable png,
                                                                       BOOL truncated,
                                                                       NSError* _Nullable error))completion
    NS_SWIFT_NAME(captureFullPage(maxDevicePixels:completion:));
@end
```

DevTools (`third_party/blink/public/devtools_protocol/domains/Page.pdl:587-601, 862`):
`Page.getLayoutMetrics` (`cssContentSize`), then
`Page.captureScreenshot` with `captureBeyondViewport: true`,
`fromSurface: true`, and a `clip` per tile of at most 4,096 device pixels,
stitched with Core Graphics. Arc equivalent: `captureFullPage:` (PG-6.3).

### EP-9. Website color scheme

```objc
typedef NS_ENUM(NSInteger, OEColorSchemePreference) {
  OEColorSchemePreferenceAutomatic = 0, OEColorSchemePreferenceLight, OEColorSchemePreferenceDark,
};
@interface OEBrowserContext (Appearance)
@property(nonatomic) OEColorSchemePreference websiteColorScheme;
@end
```

- EP-9a (OpenEngine only): `CefRequestContext::SetChromeColorScheme(CEF_COLOR_VARIANT_SYSTEM | LIGHT | DARK, 0)`
  (`cef/include/cef_request_context.h:337-346`).
- EP-9b (fork `0505`, only if check A1 or A2 fails): in
  `ChromeContentBrowserClientCef::OverrideWebPreferences` set
  `preferred_color_scheme` (and `preferred_root_scrollbar_color_scheme`)
  from a per-context value, and call `WebContents::OnWebPreferencesChanged()`
  for the context's live pages on change. Chrome's computation:
  `chrome/browser/chrome_content_browser_client.cc:4064-4097`. Arc equivalent:
  `ArcBrowserContextEffects registerColorScheme:forHostPattern:` (PG-8.2).

### EP-10. Task manager (OpenEngine only)

```objc
@interface OEEngine (TaskManager)
/// Shows Chromium's task manager window. NO if no Chrome-style page exists.
- (BOOL)showTaskManager;
/// Fallback only (EP-10b):
- (BOOL)killTaskWithIdentifier:(int64_t)taskIdentifier;
@end
@interface OEProcessMetrics (Killable)
@property(nonatomic, readonly, getter=isKillable) BOOL killable;
@end
@interface OEWebContent (TaskManager)
@property(nonatomic, readonly) int64_t taskIdentifier; // -1 if none
@end
```

Source: `ExecuteChromeCommand(IDC_TASK_MANAGER_MAIN_MENU)` (`chrome_command_ids.h:282`)
on any live Chrome-style browser; `CefTaskManager::KillTask`,
`GetTaskIdForBrowserId`, `CefTaskInfo.is_killable` (`cef/include/cef_task_manager.h`).

### EP-11. Tracing (OpenEngine only)

```objc
@interface OEEngine (Tracing)
@property(nonatomic, readonly, getter=isTracing) BOOL tracing;
- (BOOL)beginTracingWithCategories:(nullable NSString*)categories   // nil = CEF defaults
    NS_SWIFT_NAME(beginTracing(categories:));
- (void)endTracingToFile:(NSURL*)fileURL
              completion:(void (^NS_SWIFT_UI_ACTOR)(NSURL* _Nullable file, NSError* _Nullable error))completion
    NS_SWIFT_NAME(endTracing(to:completion:));
- (void)cancelTracing;   // ends into a temporary file and deletes it
@end
```

Source: `CefBeginTracing`, `CefEndTracing` (`cef/include/cef_trace.h`).
Arc equivalent: `ArcTracingController start:/stop/abort` (PG-11).

### EP-12. Media router off (OpenEngine only)

OpenEngine adds `--disable-features=MediaRouter` to the browser command
line (merged with any `--disable-features` the shell passes in
`additionalSwitches`). Source: `chrome/browser/media/router/media_router_feature.cc:47, 102-106`.

## 7. App wiring

### 7.1 Commands (`App/Page/PageCommands.swift`)

`OpenCommands` change (Step 2):

```swift
public struct CommandMenuState: Equatable, Sendable {
    public var title: String? = nil          // replaces the registry title
    public var isChecked: Bool? = nil        // .on / .off
    public var isHidden: Bool? = nil
}
public protocol CommandDispatcher: AnyObject {
    // … existing …
    func menuState(for id: String) -> CommandMenuState?   // default nil
}
```

`MenuCommandTarget.validateMenuItem` applies the state before it returns
the enabled answer. `commands-dump` must still pass (it reads registry
titles, not runtime titles).

New `EnabledKey` values: `hasWebPage` (live http(s), file, or data page in
the focused host), `siteDataClearAvailable` (E2 landed and the page is
http(s)), `isTracing`, `notTracing`.

| Command id | Handler | Enabled key | Menu state |
|---|---|---|---|
| `copy-url`, `copy-url-markdown`, `copy-url-quote` | §4.2 | `hasCurrentTab` | — |
| `zoom-in`, `zoom-out`, `zoom-actual-size` | existing host calls + §4.3 toast | `hasCurrentTab` | — |
| `capture-page`, `capture-full-page`, `capture-portrait` | `CaptureController` (§4.6) | `hasWebPage` | — |
| `appearance-automatic`, `-light`, `-dark` | §4.8 | always | checkmark on the current value |
| `clear-cache-and-refresh` | §4.9 | `siteDataClearAvailable` | — |
| `clear-cookies-and-refresh` | §4.9 | `hasWebPage` | — |
| `javascript-console`, `inspect-elements`, `network-inspector` | §4.10.1 | `hasCurrentTab` | — |
| `toggle-developer-mode` | §4.10.3 | always | title "Turn on/off Developer Mode for this site"; hidden without an http(s) or file page |
| `allow-js-apple-events` | §4.10.2 | always | checkmark |
| `task-manager` | §4.11.1 | always | — |
| `record-trace` / `cancel-trace` | §4.11.2 | `notTracing` / `isTracing` | — |
| `copy-open-info`, `reveal-open-data` | §4.11.3–4 | always | — |
| `cast` | none | — | hidden (§4.12) |

The command-bar action list hides `cast` too (`SuggestAdapter` filter by the
same menu state).

### 7.2 Engine event map additions (app-shell §4.13 table)

| Engine callback | Effect |
|---|---|
| `historySwipe` (EP-1) | `host.onHistorySwipe` → the pane's `SwipeIndicatorView` |
| `didChange .selection` (EP-3) | selected tab only: show or hide the Share Quote status button |
| `didFinishLoadWithStatus` (2xx, focused host) | `PageTranslationSession.pageLoaded` (§4.7.2) |
| `didChange .URL` (commit) | `tab.live.notificationsAllowed` refresh (§4.5.6); translation same-document rule |
| `browser(_:requestsActivationOf:)` (P1) | §4.5.4 focus rules (wake, Space, window) |
| `didClickNotification` (EP-6) | §4.5.4 fallback timer |
| permission change for `.notifications` | `notificationsAllowed` refresh + macOS authorization (§4.5.3) |

### 7.3 Context menu (app-shell §4.9)

Add "Capture" and "Capture Full Page" to the page context menu after the
selection items and before Chromium's Inspect item (order is a guess, MH
"Context menus"). Drop Chromium's "Cast…" item. Keep Chromium's "Copy link
to highlight" (it uses the same generator as EP-2).

## 8. Verification (no unit tests)

### 8.1 Offscreen renders

`features-render` gains `toast`, `swipe`, `capture`, `translate`
subcommands (same options as `split`/`peek`: `--out`, `--size`, `--scale`)
and these `check` rows:

| ID | Check |
|---|---|
| R-T1 | One plain toast: frame `[panel.maxX − 10 − w, panel.minY + 8, w, 42]`, radius 11, text 14 pt Medium white 0.95, top and bottom fill per `toastFillTop`/`toastFillBottom` within 1 unit |
| R-T2 | Copy toast with Share: 46 tall, button `[w − 42, 10, 32, 27]` |
| R-T3 | Four toasts at one anchor: the newest is on top, three are exiting; a fifth removes the oldest |
| R-T4 | Lifetime with a fake clock: plain 3.0 s, accessory 6.0 s, hover pause, sticky stays |
| R-T5 | Split View and hidden sidebar anchors; Little Open anchor |
| R-T6 | Light content Space, dark content Space, default Space: fills differ, text white |
| R-T7 | Reduce Motion: no scale animation |
| R-W1 | Swipe indicator at progress 0, 0.5, 1.0, completed, cancelled (fed through `onHistorySwipe` of a fake host) |
| R-C1 | Area overlay: dim, selection, size label below and above, hint capsule |
| R-C2 | Result card: thumbnail fit, six buttons, incognito variant (no Library line, no Show in Library) |
| R-C3 | Portrait composer: 4:5 canvas, image 86 % wide, three backgrounds |
| R-X1 | Translate popover offer, translated, error states; Options menu items in order |

`sidebar-render` gains scene `url-status`: the status button in all four
title states, at W = 228 and W = 300, and the 34 pt push-down; `check` row
S-US1 for its frame `[8, 88, W − 16, 28]`.

Commit renders under `docs/plans/page-platform/` (our own renders only).
When the user's captures exist (§12), compare with the `docs/design.md` §7
method; targets ≤ 1 pt and ΔE00 ≤ 2.

### 8.2 CLI over the real library

- `openkit url-clean` runs a fixed list of 30 URLs (each table group, mixed
  case, fragment kept, non-http unchanged, only-tracking query) and prints
  PASS/FAIL per row (same style as `commands-demo`).
- `openkit lang-detect` runs `PageLanguageDetector` over the fixture texts in
  `tools/e2e/fixtures/page-platform/` and prints the detected language and
  confidence (French, German, Japanese, English; one 40-character text that
  must fall back to the `lang` attribute).
- `openkit sleep-demo` rows from §4.5.6.

### 8.3 Real app: automation commands and the `page` suite

New automation commands (`App/Automation/AutomationController.swift`,
Debug and automation builds only; document them in `docs/automation.md`):

| Command | Args | Does |
|---|---|---|
| `toasts` | — | The visible toasts of the key window: title, subtitle, accessory, frame, age |
| `toast-action` | `index` | Performs the accessory of a visible toast through its real button |
| `command` | `id` | Runs a command through the real `CommandDispatcher` (same path as the menu) |
| `menu-state` | `id` | Title, checkmark, hidden, enabled as the menu would show them |
| `select-text` | `tab`, `selector` | Selects an element's text with DevTools input (a real drag in the page) |
| `swipe` | `tab`, `direction`, `progress` | Replays a two-finger swipe into the page view the way Chromium's own history-swiper browser test does (`chrome_render_widget_host_view_mac_history_swiper_browsertest.mm`: CGEvent scroll phases plus touch callbacks) |
| `capture` | `mode`, `rect` | Starts a capture; `rect` drives the overlay drag with events inside Open's window |
| `captures` | — | Rows of `State/captures.json` and file sizes |
| `translate` | `action: state\|offer\|translate\|revert\|never` , `target` | Reads or drives the page's translation session through the popover's real buttons |
| `notifications` | — | Delivered notifications from `UNUserNotificationCenter.current().getDeliveredNotifications` (proves macOS got them) and the engine list (EP-7) |
| `notification-click` | `id` | EP-7 simulated click |
| `app-appearance` | `value: light\|dark\|system` | Sets `NSApp.appearance` (Chromium's native theme follows the app's effective appearance) |
| `pasteboard` | — | From the Site Control plan (reuse) |

Fixtures (`tools/e2e/fixtures/page-platform/`, served by the Site Control
plan's `fixture_server(tmp)`; no external network):

- `fr.html` (`lang="fr"`, 3 paragraphs, a `<b>` inside a sentence, a
  button, an `input placeholder`, a `.notranslate` span), `fr-spa.html`
  (adds a paragraph after 1 s through `pushState`), `en.html`.
- `long.html` (12,000 px tall, colored bands every 1,000 px, lazy images).
- `quote.html` (a repeated sentence, so a context-free quote is ambiguous).
- `notify.html` (requests permission; buttons for `new Notification(...)`
  and `requireInteraction`; `onclick = () => window.focus()`),
  `notify-sw.html` + `sw.js` (`showNotification`, `notificationclick` →
  `clients.matchAll` + `focus()`).
- `scheme.html` (`@media (prefers-color-scheme: dark)` body color; exposes
  `matchMedia` results).
- `cookies.html` (sets a cookie; a second fixture host on another port sets
  its own).
- `links.html` (a link for the Cmd+Shift-click replay).
- `zoom.html` (text and a known-size box for pinch checks).

`--only page` checks (each must pass; checks that wait for an engine item
report `blocked: EP-n`, never pass):

| ID | Check |
|---|---|
| T-E1 | `command copy-url` on `/en.html?utm_source=x&id=1#top` → `pasteboard` = `/en.html?id=1#top`; `toasts` = "Copied a clean link without trackers" with Share; frame insets 8/10 |
| T-E2 | Same without trackers → "Copied Current URL"; `toast-action` opens the share picker (window list shows it); Esc closes it |
| Q1 | `select-text` a unique sentence in `quote.html`, `command copy-url-quote` → link has `#:~:text=`; `open` it → `eval` reads the highlighted range's text (CSS `::target-text` computed) |
| Q2 | Ambiguous sentence → with EP-2 the link carries prefix or suffix context and lands on the second copy; interim reports `blocked: EP-2` |
| Q3 | No selection → behaves as `copy-url` |
| Q4 | Shared Quotes on, selection, `copy-url` → the toast updates with the quote offer; `toast-action` copies the quote link |
| Z1 | `command zoom-in` ×2 → toasts "110%", "125%"; `zoom-actual-size` → "100%" |
| Z2 | `devtools Input.synthesizePinchGesture` (`Input.pdl:272`, scale 2) on `zoom.html` → `eval visualViewport.scale` ≈ 2; `command zoom-actual-size` → scale 1 (EP-5). The AppKit trackpad path is U-S1. |
| Z3 | Smart zoom has no synthetic path; U-S1 covers it |
| Z4 | Hosted tab: no Chromium zoom bubble window appears in `windows` |
| SW1 | `navigate` a→b, `swipe direction=back progress=1.2` → URL is a; `swipe forward` → b |
| SW2 | `progress=0.5` → no navigation; indicator cancelled (EP-1 events in `events`) |
| SW3 | Split pane and Peek: the swipe navigates the host under the pointer only |
| SW4 | `historySwipeEnabled = NO` during a capture overlay: no navigation |
| N1 | `policy permissions=grant`, `notify.html` → `notifications` lists the banner in macOS (needs U-N1) and in the engine list |
| N2 | `requireInteraction` → `ps` shows `Open Helper (Alerts)` running; `notifications` lists it |
| N3 | Tab in Space 2, Space 1 focused, `notification-click` → `tabs` shows the tab selected and Space 2 focused (P1 path) |
| N4 | Page without `focus()`: fallback selects it after 500 ms (EP-6) |
| N5 | Permission Allow → a debug-sleep request for that tab (OpenSleep's debug path, `docs/sleep.md`, driven by the app-shell `sleep` suite's command) is refused with gate `notifications`; after Block it sleeps |
| N6 | `notify-sw.html` notification click with no tab open → a new Today tab opens (`clients.openWindow`) |
| C1 | `capture mode=area rect=[100,100,300,200]` → `captures` has one `area` row; PNG is 600 × 400 at 2x |
| C2 | Full page on `long.html` → height = 12,000 × scale; bands at the right offsets (pixel probe of the PNG) |
| C3 | Portrait → 4:5 PNG |
| C4 | Esc during the overlay → no row |
| C5 | Cmd+Shift drag (events inside Open's window) → overlay starts at the press point |
| C6 | Cmd+Shift click on a link in `links.html` → a new foreground tab opens (replay path) |
| C7 | Incognito window → no row; Copy works |
| X1 | `fr.html` → status button "Translation Available"; `translate translate` → body text is not French (`NLLanguageRecognizer` on `eval innerText`); `.notranslate` text unchanged; button text translated |
| X2 | `revert` → DOM text equals the original byte for byte |
| X3 | `fr-spa.html` → the new paragraph is translated too |
| X4 | `never` → status button hidden; reload → no offer; Settings reset action → offer returns |
| X5 | `filter block=["translate"]` installed first; `filter-stats` after X1 shows zero matching requests (no network use) |
| X6 | Undo after translate → original text |
| A1 | `command appearance-dark` → `scheme.html` `matchMedia` dark in Alloy and hosted tabs, no reload (`events` has no load) |
| A2 | `appearance-automatic` + `app-appearance value=dark` then `value=light` → `scheme.html` follows each time |
| K1 | `cookies.html` on two hosts → `clear-cookies-and-refresh` on host 1 → host 1 cookie gone, host 2 cookie kept (E2), page reloaded |
| K2 | `clear-cache-and-refresh` disabled before E2 (`menu-state`) |
| D1 | `javascript-console` opens DevTools on the Console panel (DevTools page URL has `panel=console` or its first view is Console via `pages`) |
| D2 | `network-inspector` → Network panel (EP-4b) |
| D3 | `toggle-developer-mode` → `menu-state` title flips; URL field shows the full URL |
| D4 | `allow-js-apple-events` off → `osascript` `execute` returns error 1013; on → result |
| H1 | `task-manager` → a window titled "Task Manager…" appears (`windows`) |
| H2 | `record-trace`, wait 2 s, Stop → a JSON file with `traceEvents` in the test Downloads folder |
| H3 | `copy-open-info` → `pasteboard` matches the §4.11.3 shape; no `http` in it |
| H4 | `cast` hidden (`menu-state`); `ps` / engine log shows no media-router discovery |

Before an engine item exists, its rows report `blocked: EP-n` (or `E2`,
`P7`). A blocked row never counts as a pass.

### 8.4 Checks only a person can do (the user, at their Mac)

| ID | Why | Steps |
|---|---|---|
| U-N1 | macOS asks once to allow notifications for the test build; no agent may click it (AGENTS.md rule 4) | Run `--only page` once; click Allow in the macOS prompt |
| U-N2 | A real banner click | Click one banner from N1; the right tab shows |
| U-S1 | Real trackpad behavior | Two-finger swipe back and forward on 3 sites; pinch in and out; two-finger double tap (smart zoom) |
| U-X1 | Apple language assets | If French → system language is not installed, macOS asks to download it on the first X1 run; allow it |

## 9. Implementation order

Each step is one PR. Each PR merges `origin/main` first, runs
`tools/verify-all.sh`, and pastes its summary (AGENTS.md rule 10). Steps
tagged `[APP]` need app-shell Steps B and C on `main` (real window, menus,
`CommandDispatcher`); notification and context-menu steps also need Step D.

| Step | Tag | Work | Depends on | Acceptance |
|---|---|---|---|---|
| 1 | [OpenKit] | `PageTokens`, motion and type tokens; `ToastCenter`, `ToastView`, `ToastOverlayView`; move Peek and pane-Copy toasts; settings defaults (§5) | — | `features-render check` R-T1–R-T7 pass; the existing 147 checks pass |
| 2 | [OpenKit] | `CommandMenuState` + `menuState(for:)`; new enabled keys; `URLCleaner`; `openkit url-clean` | — | `commands-dump` exit 0; `url-clean` 30/30 |
| 3 | [APP] + [OpenEngine only] | Copy URL family (interim quote), zoom toast, EP-5 | 1, 2, app-shell C | T-E1, T-E2, Q1, Q3, Q4, Z1–Z4 pass; Q2 blocked |
| 4 | [OpenEngine only] | EP-4a, EP-9a, EP-10a(+b), EP-11, EP-12 | — | `docs/engine-api.md` updated; `--only features` still passes; Step 5's D1, A1, H1, H2, H4 pass once Step 5 lands |
| 5 | [APP] | Website appearance, Developer panels, Allow JS from Apple Events, Troubleshooting, Cast hidden | 2, 4 | A1, A2, D1, D4, H1–H4 pass; D2 blocked until EP-4b |
| 6 | [APP] | Clear Cache / Clear Cookies and Refresh (interim cookie path) | 2; Site Control E2 for the cache row | K1 (interim: host-1 cookie gone), K2 |
| 7 | [APP] | Notifications: plists, authorization, Site Control tile line, P1 activation rules | app-shell D, P1 | N1, N2, N3, N6 pass (U-N1 done once) |
| 8 | [OpenKit] | Sleep `.notifications` gate | — (keep-alive gate is on `main`) | `sleep-demo` new rows; N5 |
| 9 | [OpenKit] | `OpenTranslate` target, runtime JS, detector, backend; `URLStatusButton`; popover | 1 | `openkit lang-detect`; `features-render` R-X1; `sidebar-render` S-US1 |
| 10 | [APP] | Translation wiring (main world, `// Blocked on P7`) | 9 | X1–X6 pass |
| 11 | [ENGINE fork] | EP-1 (`0501`) | P1 merged (shared tree queue) | engine-api.md; e2e SW1 with Chrome overlay off |
| 12 | [OpenKit] + [APP] | Swipe indicator and wiring; `swipe` command | 1, 11 | R-W1; SW1–SW4; U-S1 |
| 13 | [OpenKit] + [APP] | Capture overlay, result card, composer; capture wiring, Library writer, Cmd+Shift drag, context menu items, EP-8 | 1, 4 | R-C1–R-C3 renders; C1–C7 e2e |
| 14 | [ENGINE fork] | EP-2 + EP-3 (`0502`) | P1 | Q2 passes |
| 15 | [APP] | Quote via EP-2; Share Quote status button | 9, 14 | Q1–Q4 pass with EP-2 |
| 16 | [ENGINE fork] + [APP] | EP-4b (`0503`); EP-6 + EP-7 (`0504`); click fallback | 7 | D2, N4 pass |
| 17 | [ENGINE fork] | EP-9b (`0505`), only if A1 or A2 fails on any page style | 5 | A1 and A2 pass on every style |
| 18 | [APP] | Developer Mode v1 (§4.10.3) and the Site Control tile | 5; lead answer to Q6 | D3 |
| 19 | [APP] | When P7 / E5 lands: move the translate runtime to the isolated world | 10, P7 | X1–X6 pass; `eval` in the main world cannot see `__openTranslate` |

Step 13 status (Section 8, branch `s8/capture`): built. `features-render check` covers R-C1–R-C3
plus the controller flow (renders in `docs/plans/page-platform/capture-*.png`); e2e `--only page`
passes C1–C6 and the context-menu row; C7 is blocked (no incognito window yet). Interim: the
capture toasts use the window's old toast until Step 1's `ToastCenter`, and `hasWebPage` is
computed in `App/Page/CaptureCommands.swift` until Step 2. Leftovers: `docs/followups.md`,
"Capture tool leftovers".

Priority: steps 1–3 unblock every toast; 7–10 and 11–12 close the P1 gaps
(notifications, translation, swipe; `docs/status.md` §3.2 items 8, 9, 12);
the rest are P2.

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| R-1 | No capture of Arc's swipe indicator, capture overlay, result card, translate popover, or Developer Mode | Every value is one token; captures C-S1, C-C1, C-C2, C-R1, C-D1 (§12) |
| R-2 | Apple's translation languages are fewer than Google's; some pages get no offer | Stated in Settings help text later; offer only when `LanguageAvailability` supports the pair |
| R-3 | Inline markers lost by the translator garble mixed-markup sentences | Per-node fallback per unit (§4.7.4); X1 checks a sentence with `<b>` |
| R-4 | Ad-hoc signed builds: macOS may ask for notification permission after each signature change | U-N1 per new signing identity; release builds are Developer ID (release plan) |
| R-5 | `SetChromeColorScheme` may not reach Views-less pages | EP-9b fallback, gated by A1 |
| R-6 | Chromium's Views task manager may misbehave without a `BrowserView` | H1 decides; Open fallback window (§4.11.1) |
| R-7 | The swipe replay command cannot prove real trackpad behavior | U-S1 manual check |
| R-8 | Holding Cmd+Shift mouse-down and replaying it may break page drag-and-drop with those modifiers | C6; the setting turns drag-to-capture off |
| R-9 | Translation runtime in the main world before P7 is visible to pages | Same rule and marker as Boosts (app-shell D8); Step 19 |
| R-10 | Notification gate keeps more tabs awake (memory) | Only sites the user allowed; Chrome does the same |

## 11. Open questions (default = the recommendation, until the lead decides)

| # | Question | Recommendation |
|---|---|---|
| Q1 | Translation backend: on-device Apple (C), Google with a negotiated key (A), or no translation in v1 (D)? | **C.** It needs no account, no key, and no fork patch, and it keeps page text on the Mac. |
| Q2 | Cast in v1? | **No** (§4.12). Hide the item, turn the media router off. Revisit after v1 (3–4 weeks plus a test device). |
| Q3 | Gate AppleScript `execute` behind "Allow JavaScript from Apple Events" (changes applescript Q5)? | **Yes, default off** (Chromium's default; Arc keeps it). The error text tells the user where to turn it on. |
| Q4 | Select the source tab on a notification click when the page does not call `focus()`? | **Yes**, after 500 ms (§4.5.4). Users expect the click to show the site. |
| Q5 | Never sleep a tab whose site may send notifications? | **Yes**: no freeze and no timer discard; critical memory pressure may still discard (Chrome parity, §4.5.6). |
| Q6 | Developer Mode in v1? | **Yes, minimal**: per-site toggle, title, Site Control tile, full URL in the URL field. Add more after capture C-D1. |
| Q7 | Task Manager: Chromium's window or Open's own? | **Chromium's** (Arc parity, zero UI); Open's window only if H1 fails. |
| Q8 | Cmd+Shift drag vs Cmd+Shift click on links | **Both**: drag ≥ 4 pt captures; a click replays to the page (§4.6.2). |
| Q9 | Website appearance per profile or app-wide? | **App-wide** (Arc's menu is app-level). |
| Q10 | Toast anchor in Split View | **Top-right of the whole web panel.** |
| Q11 | Copy URL as Quote with no selection | **Behave as Copy URL.** |
| Q12 | Keep translating new pages of the same host in the same tab? | **Yes**, until Show Original. |

## 12. Captures needed from the user

Add these to the user's single combined Arc capture session
(`docs/re/runtime-observations.md` §7). IDs match
`docs/re/page-platform.md` PG-13.

| ID | What | Unblocks |
|---|---|---|
| C-T1 | Toasts on a dark and a light Space; Copy URL with and without selected text; three zoom steps | §4.1.2 fill rule, quote offer layout |
| C-S1 | Screen recording of a two-finger swipe back and forward | §4.4.2 indicator |
| C-C1 | Capture… overlay, a drag, the result panel; a Cmd+Shift drag | §4.6.3, §4.6.5 |
| C-C2 | Capture Full Page and Capture in Portrait Mode results (the saved images) | §4.6.4 |
| C-R1 | A French page: the "Translation Available" button, the popover, the translated state, Show Original | §4.7.3 |
| C-D1 | Ctrl+D on a localhost page: what changes | §4.10.3 |
| C-N1 | A notification banner click while the tab is in another Space | §4.5.4 |
| C-Q1 | Copy URL as Quote pasted into TextEdit (plain text) | §4.2.4 clipboard form |

## 13. Evidence index

- Arc evidence: `docs/re/page-platform.md` (PG-1…PG-13) and its raw files
  in `.re/page-platform/`.
- Chromium and CEF sources: §2 and §6 (paths under
  `~/Developer/open-engine/chromium_git/chromium/src`).
- Apple SDK: `MacOSX27.0.sdk/System/Library/Frameworks/Translation.framework/Versions/A/Modules/Translation.swiftmodule/arm64e-apple-macos.swiftinterface`
  lines 29-37 (`LanguageAvailability`), 96 (`TranslationSession`), 179-190
  (`translate`, `translate(batch:)`, `prepareTranslation()`,
  `init(installedSource:target:)` macOS 26.0).
- Open code: §1 table.
- PR #53 (`m7/ext-p1-tabstrip` at `a03d2a5`): `Engine/fork/src/open/browser/tab_strip/open_tab_strip.cc`,
  `open_browser_window.mm`, `docs/engine-api.md` diff.

## Appendix — Lead decisions (2026-10-26)

- Approved as the page and platform features plan.
- Q1 Translation uses Apple's on-device Translation framework. No account, no API key, no fork patch.
- Q2 No Cast in v1. Hide the menu item and turn the media router off.
- Q3 AppleScript `execute` is gated behind "Allow JavaScript from Apple Events", off by default (Chromium default). This overrides applescript plan Q5; update that plan's appendix in the implementing PR.
- Q4 A notification click selects its tab after 500 ms if the page does not call `focus()`.
- Q5 Tabs with notification permission never sleep: no freeze and no timer discard (Chrome parity). This works alongside the keep-alive site list (#65).
- Q6 Developer Mode in v1 is minimal: a per-site toggle, the menu title, a Site Control tile, and the full URL in the URL field. The Site Control Center plan shows its Developer Mode row once this lands.
- Q7 Task Manager uses Chromium's window. Build Open's own only if Chromium's fails.
- Q8 Cmd+Shift drag and Cmd+Shift click: a drag of at least 4 pt captures; a click replays to the page.
- Q9–Q12 Appearance is app-wide. The split-view toast anchors at the whole panel's top-right. Quote without a selection acts as Copy URL. Auto-translate covers the same host.
- The captures go into the user's single combined Arc capture session.

## Appendix — Section 8 implementation notes (Steps 1–2)

These replace the plan text where they differ; each cites its evidence.

- D-5: there is one tracker table. `OpenModel/URLCleaner.swift` is a thin API (`clean(_:) -> (url, removed)`) over Section 2's `TrackerStripping`, Arc's decoded rule (RE CC-31a). The §4.2.1 name list is not used. The rule matches names case-sensitively; `openkit url-clean` checks 30 rows of the real rule (§8.2). Kept items keep their percent-encoding. Non-http(s) URLs stay unchanged (§4.2.1).
- `ToastMetrics.accessoryLifetime` is 5.0 s, not 6.0: PG-14 measured the copy toast with Share for ≈ 4.95 s (V 69.99–75.11 s).
- `Motion.toastIn` grows from 0.3 at the top center of the toast and `Motion.toastOut` shrinks back to it over 0.16 s (PG-14), not a 0.20 s fade to 0.96.
- Toast text is opaque white, the value the hint toast fit chose (ΔE00 0.05); `Typography.toast` is 14 pt Medium.
- Default theme in macOS Light: lavender `#D0C6F0` → `#C2B4E9` with dark text `#0D0D10` (S2 20/0048). Themed Spaces keep the §4.1.2 guess (tooltip fill ± 0.06 OKLab L, white text).
- `ToastCenter.show(_:onAccessory:)` passes the `ToastHandle` to the accessory closure (an Undo dismisses its own toast); `ToastHandle.hold(_:)` keeps a toast while its share picker is open.
- Renders: `features-render toast --variant … [--crop]`, committed under `docs/plans/page-platform/`.

### Step 3 notes (Section 8)

- The zoom percent is `round(100 × 1.2^zoomLevel)` read from the page right after the CEF zoom command (`App/Page/PageCommands.swift`); `WebContentHost.zoomPercent` is not added yet (no OpenKit caller needs it).
- The copy toast's Share button opens the window's one `NSSharingServicePicker` (the sidebar Share uses the same one), anchored to the button; `ToastHandle.hold` keeps the toast until the picker closes.
- Quote links (interim until EP-2): `String(getSelection())` in the main frame; an exact `#:~:text=` directive (ASCII letters, digits and `._~` stay, everything else is percent-encoded); more than 300 characters or no selection: Copy URL.
- EP-5 needs no code: CEF's `CEF_ZOOM_COMMAND_RESET` runs `zoom::PageZoom::Zoom` (`cef/libcef/browser/browser_host_base.cc:397`), and its `PAGE_ZOOM_RESET` calls `WebContents::SetPageScale(1)` (`components/zoom/page_zoom.cc:81-83`). A build with `Emulation.resetPageScaleFactor` removed still passed Z2 on a sidebar tab and a Peek page, so the DevTools call was dropped (no DevTools session per Actual Size).
- e2e `page`: T-E1, T-E2, Q1, Q3, Q4, Z1, Z2 (tab and Peek), Z4 pass; Q2 reports `BLOCKED: EP-2`, Z3 `DEFERRED` (U-S1).
