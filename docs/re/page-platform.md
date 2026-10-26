# Arc 1.170.0 — page and platform features: evidence for Open

Scope: toasts, Copy URL as Quote, zoom and pinch, two-finger page swipe, web
notifications, Capture, page translation, website appearance, Clear Cache /
Clear Cookies and Refresh, the Developer menu, Help ▸ Troubleshooting, and
Cast. The plan that uses these facts is
[`docs/plans/page-platform.md`](../plans/page-platform.md). Rule IDs are
**PG-n**. Every rule names its evidence. "guess" marks anything the evidence
does not prove.

## 0. Method and raw output

No Arc launch, no desktop input, no Arc user data beyond file names and one
empty folder listing. Raw output is in the git-ignored `.re/page-platform/`.

| Source | Command or file | Notes |
|---|---|---|
| Strings, Arc main binary | `.re/arccore/strings-arc-main.txt` (made earlier with `strings .re/bin/Arc-arm64`) | Line numbers below are lines in this file (`strings:N`). |
| ArcCore ObjC metadata | `.re/arccore/objc-methods.txt`, `objc-selectors.txt`, `objc-classes.txt` (earlier `rea inspect-native-dispatch-metadata` run on ArcCore) | Class methods and delegate selectors. |
| ArcCore strings | `.re/arccore/strings-arccore.txt` | Counts only for anything key-shaped. |
| Ghidra, shared project | `analyzeHeadless ~/Library/Caches/OpenRE/ghidra ArcMain -process Arc-arm64 -noanalysis -readOnly -postScript AdrpDecomp.java …` (our own read-only script: find a string, find `adrp`+`add` references, decompile the callers). Two batches. | Output: `.re/page-platform/ghidra-pageplat.txt`, `ghidra-pageplat2.txt`. Function addresses below (`FUN_…`) come from these files. |
| Bundle metadata | `plutil -p "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Versions/A/Helpers/Browser Helper (Alerts).app/Contents/Info.plist"`, `ls …/Helpers/` | Read-only. |
| Live capture session | `.re/runtime/sessions/20261024-213009-session-{full,anim}/` frames F0142–F0147, F0155–F0156 (full) and A0481–A0499, A0519–A0527 (fast) | Pixels and window lists only. Display scale 1.0, so 1 px = 1 pt (`docs/re/interaction-states.md` §0). Pixel values below are raw display RGB, not color-managed. |
| Arc user data | `ls ~/Library/Application Support/Arc/` and `…/Captures/` | File names only. `StorableDeveloperModeState.json` and `StorableCaptures.json` do not exist on this Mac. `Captures/` is empty. |

## PG-1 Toasts

Code: module `Toasts` (`Toasts/ToastController.swift`, `ToastColors.swift`,
`ShinyToastView.swift`, `NSWindow+ShinyToast.swift`; strings:~125850–125960
and the type list `ToastController`, `ToastWindow`, `ToastAnimator`,
`ToastConstants`, `ToastColorPalette`, `ToastShareButton`, `ToastHotkeyPill`,
`ToastBigKeyView`, `ShortcutToastContentOptions`, `UndoableToastContentOptions`,
`TracingToastContentOptions`).

- **PG-1.1 Host and position (measured).** Each toast is its own borderless
  window over the web content area (`docs/re/interaction-states.md` §16). The
  toast body sits at the top-right of the web panel. Pixel scans of F0142
  (zoom toast) and F0155 (copy toast): the body's top edge is at window y 18
  and the panel's top edge is at y 10, so the top inset is **8 pt**. The
  body's right edge is at x 2196 and the panel's right edge is at x 2206, so
  the trailing inset is **10 pt**. (§16 gives the AX text frame, which is
  about 23 pt below the panel top; both agree.) The first-hide sidebar hint
  is a different case: it sits at the window's top-right (x = W − 5 − w,
  y = 4) on A0440 (`docs/re/sidebar-completion.md`, `docs/plans/sidebar-completion.md`
  §3.12).
- **PG-1.2 Size (measured).** Text-only toast ("110%"): x 2138–2197, y 18–59
  → **60 × 42 pt**. Toast with a button ("Copied Current URL" + Share): x
  2004–2195, y 18–63 → **192 × 46 pt**.
- **PG-1.3 Insides (measured, F0155).** Text starts at x 2016 → 12 pt
  leading padding. AX text frame 133 × 17 pt ends at x 2146; the Share
  button spans x 2154–2186, y 28–55 (32 × 27 pt; §16 says 32.5 × 27.5) → 8 pt
  from text to button, 10 pt from button to the trailing edge, 10 pt from the
  top. Button fill raw (130,123,97) over the toast fill (95,85,51) → derived
  white overlay ≈ 0.22. Symbol `square.and.arrow.up` (§16).
- **PG-1.4 Corner (measured).** The zoom toast's first fill pixel per row
  moves from x 2149 (row 18) to x 2138 (row 28) and back from row 50 to 59:
  radius about **10–11 pt**, continuous-looking.
- **PG-1.5 Fill (measured, derived).** Vertical gradient. F0155 column x
  2010: row 20 raw (102,90,52), row 40 (91,80,47), row 62 (78,68,40). The
  bottom is about 0.77 × the top in every channel. Rows 19 and 63 are darker
  by one step (raw (89,79,45) and (67,59,34)): a 1 px inner edge. The Space
  in that session had a single olive theme color; §16 reads `#6E5A2F`
  color-managed. The hint toast measured on A0440 (default dark theme) has
  the same shape of gradient, `#442B68` → `#332350` (bottom ≈ 0.75–0.81 ×
  top), with a fitted 1 px rim of black 0.20 (sidebar-completion §3.12). guess:
  the base is derived from the theme like the tooltip fill
  (`SpaceThemeStyle.tooltipFill`).
- **PG-1.6 Text (measured).** White (brightest pixel 255,255,255). 14 pt,
  Medium or Semibold (§16, ink height); the hint toast fits 14 pt Medium,
  white 0.95 (sidebar-completion §3.12).
- **PG-1.7 Lifetime.** The removal path `FUN_1018e22f8` (references "Toast
  will be removed.") holds one duration-sized double, **3.0**, and one 3600.0
  (`.re/page-platform/toast-funcs.txt`). Fast frames: zoom toast window 5404
  appears at 21:34:07 (A0481) and is gone at 21:34:10–11 (A0485–A0486), so
  about 3 s. The copy toast with a Share button (window 5420) stays from
  21:34:31 (A0519) to at least 21:34:36 (A0525), so ≥ 5 s. guess: plain
  toasts 3 s; toasts with a button stay longer.
- **PG-1.8 Stacking (measured).** Each zoom step opens a new toast window
  at the same frame. A0487 shows four toast windows (5405–5408) at one
  frame while the older ones fade (`windows.tsv`). So "stacking" is overlap
  at one anchor, not a vertical list.
- **PG-1.9 Appear (measured).** Scale-up from small: mid-animation the AX
  text frame is 12 × 6 pt (F0144). Exit: fade (guess: plus a small scale).
- **PG-1.10 Copy toast titles (proven).** `FUN_1018ef384` picks the title:
  "Copied Current URL" (one item), "Copied URLs" (several items; decoded
  inline string), and, when tracking parameters were removed, "Copied a clean
  link without trackers" / "Copied clean links without trackers"
  (strings:125939–125949).
- **PG-1.11 Other proven toast texts.** "Capture in Progress" (comment
  "Letting user know a full page capture is in progress", strings:125936),
  "Saved to Library" (strings:111738), "Share a link directly to this text
  instead?" with symbol `quote.bubble.fill` (strings:125929–125932),
  "Translated back to %@", "Translated to %@", "Translation error (%@)"
  (strings:125865–125869), "… and drag your mouse to capture any time." with
  "Letting the member know about the draggable capture shortcut."
  (strings:125863–125864), "Toast indicating that
  the Arc version was copied to the clipboard.", "Toast indicating that the
  user can press the same hotkey again to run the browser action.". The quote
  toast title and the "Copied Image" title are short inline strings that the
  scan did not decode (guess).

## PG-2 Copy URL family and quotes

- **PG-2.1 Copy URL strips trackers (proven).** Shortcut text "Copies the
  current URL to your clipboard without any trackers" (`docs/re/features-core.md`
  §1.4 r19). Arc ships a tracking-parameter table (strings:268525–268615,
  saved to `.re/page-platform/arc-tracking-params.txt`): global names
  (`fbclid`, `gclid`, `gclsrc`, `gad_source`, `msclkid`, `mcid`, `_hsenc`,
  `_hsmi`, `igsh`, `oly_anon_id`, …), global prefixes ending in `_` (`utm_`, `hsa_`, `mtm_`,
  `matomo_`, `piwik_`, `stm_`, `trk_`, `vero_`), and per-host names (an
  Amazon group with `pd_rd_`, `pf_rd_`, `ascsubtag`, …; an eBay group with
  `_trkparms`, `_trksid`, …; a YouTube group with `feature`,
  `source_ve_path`; twitter.com / x.com). Open writes its own table; it does
  not copy this file.
- **PG-2.2 Copy URL as Quote (proven).** Menu item Edit ▸ Copy URL as Quote,
  Cmd+Ctrl+Shift+C, selector `copyCurrentURLAsQuote:` (MH Edit). Description
  string: "Copies the current URL to your clipboard without any trackers as a
  quote with the current selected text." (`FUN_10205d150`, the shortcut
  description table). Related strings: "Copy Current URL as Quote", "Copy
  Quote as URL", `CopyQuoteLinkContentView`, `WindowState+CopyQuote.swift`,
  "Letting user know the URL for the currently selected quote has been
  copied.", "Sublabel letting user know the current URL was copied as a quote
  link." ArcCore exposes `ArcWebContents.selectedText` (property
  `T@"NSString",C,N,V_selectedText`) and `findTextWithDirectives:completion:`
  plus `ArcFindTextWithDirectiveResult` (text-fragment directives). guess: the
  copied link is the page URL with a text-fragment directive (`#:~:text=`).
- **PG-2.3 Share Quote affordance (proven).** `FUN_10014bc74` returns the
  title of a status button under the URL field
  (`Arc.CommandBarPlaceholderStatusButton`): case 2 = "Share Quote"
  (comment "Title for the share quote affordance below the URL"). Settings:
  "Enable Shared Quotes when highlighting text" ("If disabled, you can still
  copy URL as a quote…", FC §7 Advanced). guess: it appears while page text
  is selected.

## PG-3 Zoom, pinch, smart zoom

- **PG-3.1 Zoom toast (measured).** "110%", "125%", "100%" (F0142–F0147):
  Chromium's preset zoom steps. Text only.
- **PG-3.2 Pinch is Chromium's.** ArcCore keeps Chromium's
  `magnifyWithEvent:`, `smartMagnifyWithEvent:`,
  `magnifyWithEvent:isSyntheticallyInjected:` (objc-selectors:956, 1381,
  1383). `ArcWebContents` has `resetZoomAndScaleFactors`, `setZoomFactor:`,
  `isScaleFactorOne` (page zoom and pinch scale are separate). Arc main has
  `zoomAtPinchBegin` / `lastRecordedZoom` right after the text-layout field
  `lineFragments` (strings:237312–237314); guess: that is the Easel/Notes
  canvas, not web pages. guess: Arc shows no toast on pinch.

## PG-4 Two-finger page swipe

- **PG-4.1 Arc owns the swipe UI (proven).** ArcCore's web-contents gesture
  bridge (`web_contents_gesture_handler_bridge`) sends the shell
  `webContents:handleEvent:`, `webContents:touchesBeganWithEvent:` /
  `Moved` / `Cancelled` / `Ended`, `webContents:rendererHandledWheelEventConsumed:`,
  `webContents:rendererHandledGestureScrollEvent:consumed:`,
  `webContents:rendererHandledOverscrollEvent:`, and asks
  `webContentsWantsOverscrollSwipeEvents:` (objc-selectors around 5270–5310).
  `ArcOverscrollBehavior` (x, y) and `ArcOverscrollParams` carry the page's
  CSS `overscroll-behavior`. ArcCore keeps Chromium's history-swiper
  selectors (`_historySwiper`, `cancelHistorySwipe`,
  `trackSwipeEventWithOptions:…`) and reads the macOS "Swipe between pages"
  setting (`isSwipeTrackingFromScrollEventsEnabled`, objc-selectors:2154),
  which stock Chromium 156 does not read (`git grep` in `chrome/`,
  `content/`, `ui/` finds no use).
- **PG-4.2 Shell side (proven names).** Arc main: `PageSwipeController`
  (module ARCUI, nested `Page`, `SettlingAnimation`, `PagingPosition`,
  `Resolution`, `NonGesturalScrollState`), `PageSwipeTrackingState`,
  `WebContentOverscrollDelegate`, keys `useChromiumOverscroll`,
  `wantsWebContentOverscroll`, flags
  `page-swipe-controller-internal-scrolling-state-optimization-enabled` and
  `modal-v2-chromium-overscroll-enabled` (strings:123539, 123554; getters
  `FUN_1013d7e30`, `FUN_1013d8088`). Swipe goes Back/Forward (MH "Gestures").
- **PG-4.3 Visual unknown.** No capture shows a page swipe. No asset name
  proves the indicator. guess only (plan §4.4).

## PG-5 Web notifications

- **PG-5.1 Engine model (proven).** ArcCore classes `ArcNotification` (34
  members: title, message, origin, `documentURL`, icon, image, buttons,
  `renotify`, `permanent`, `didClick:input:`, `didClose:`,
  `didClickSettings`), `ArcNotificationButton`, `ArcNotificationItem`;
  `ArcBrowserApplication setNotificationCenter:` (objc-methods). So ArcCore
  hands web notifications to the Swift shell.
- **PG-5.2 Shell posts and handles clicks (proven).** Arc main:
  `ArcNotificationCenter`, `UNUserNotificationCenterDelegate`,
  `userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:`,
  `addNotificationRequest:withCompletionHandler:`,
  `UserNotificationsClient.requestAuthorization` (`FUN_1014f4e88`).
- **PG-5.3 Arc's own prompt (proven).** "Allow %@ to send you
  notifications?" (`FUN_101ec1174`, the permission prompt title builder).
  Per-profile pref `notificationPermissionRequestsEnabled`
  (`ArcBrowserContextPreferences`) toggled by
  `onToggleWebNotificationPermissionRequests`.
- **PG-5.4 Alerts helper (proven).** `Browser Helper (Alerts).app`
  Info.plist: `CFBundleDisplayName` "Arc", `CFBundleIdentifier`
  `company.thebrowser.browser.framework.AlertNotificationService`,
  `NSUserNotificationAlertStyle` = `alert`. Arc's main Info.plist has no
  notification key (banner is the macOS default).

## PG-6 Capture

- **PG-6.1 Kinds and entry points (proven).** File ▸ Capture… (Cmd+Shift+2,
  `capturePage:`), Capture Full Page (`captureFullPage:`), Capture in
  Portrait Mode (`capturePrettyScreenshot:`) (MH File). Site Control action
  buttons (SC-15). Hint: "Hold Command and Shift to start a Capture."
  (`FUN_10205b850`, a SwiftUI `Text`).
- **PG-6.2 Keys (proven).** One registration function `FUN_1005a4098`
  references `captureShortcutLastSeen`, `dragToCaptureDisabled`,
  `portraitCaptureColorPercentage` next to `developerModeEnabledForHosts`
  (guess: a UserDefaults key table).
- **PG-6.3 Engine (proven).** `ArcWebContents captureViewport:`,
  `captureFullPage:`, `captureRegion:completion:`; delegate
  `webContents:didCaptureImage:`.
- **PG-6.4 Full page (proven strings).** `FullPageCaptureDelay`,
  "Unable to get imageData from full page capture.", "Unable to generate a
  filename for the full page capture.", then the literals
  `[^a-zA-Z0-9\-_ ]`, `' MM-dd`, `' h.mma '` (strings:111359–111364). guess:
  the file name is the cleaned page title plus a date and a time.
- **PG-6.5 Result and storage (proven names).** `CapturedImageView`,
  `CapturedImageActionsView`, `CaptureImageMenuView`, "Save Capture Image",
  "Saved to Library", `saveCaptureToLibrary`, "Action to retake capture.",
  `ArcCaptureWatermark`, `portraitCaptureHidesWatermark`. Folder
  `~/Library/Application Support/Arc/Captures` (empty here).
- **PG-6.6 Unknown.** Overlay look, result panel layout, portrait aspect and
  background. No capture exists. guess only.

## PG-7 Page translation

- **PG-7.1 Engine API (proven).** `ArcWebContents translateToTargetLanguage:`,
  `revertTranslation`, `supportedTranslateLanguages`; delegate
  `webContents:didDetermineSourceLanguage:isTranslateEnabled:targetLanguage:isTranslationPending:`,
  `webContents:showTranslateBubble:withTargetLanguage:`,
  `webContentsShowTranslateInProgress:`, `webContents:showTranslateComplete:`,
  `webContents:showTranslateError:`, `webContents:onTranslateCompleteToLanguage:`,
  `webContents:onTranslateError:` (objc-selectors:5132–5322, objc-methods:1669–1701).
- **PG-7.2 Arc uses Chromium translate with Google keys (proven, partly).**
  ArcCore holds `https://translate.googleapis.com/translate_a/element.js` and
  `translate_a/l?client=chrome` (strings-arccore). Arc main holds the names
  `GOOGLE_API_KEY`, `GOOGLE_DEFAULT_CLIENT_ID`, `GOOGLE_DEFAULT_CLIENT_SECRET`
  (strings:110510–110512) and two strings with the shape of a Google API key
  (count only; not read, not copied). ArcCore holds no key-shaped string.
  guess: the Arc app sets the keys in the environment before the engine
  starts. Open cannot reuse them.
- **PG-7.3 UI (proven strings, `TranslateFeature.swift`,
  `TranslateBubblePopoverView.swift`).** Status button under the URL field
  (`FUN_10014bc74`): "Translation Available" when the width parameter is
  above 200, "Translation…" (decoded) at 200 or less, "Translated" after
  translation. Popover: "Translate this page to %@?", "Translated from %@.",
  buttons (request, revert, options), submenu "Choose Another Language",
  "Never Translate This Site", "Language Settings" (strings:110920, 123466–123478).
  Toasts: PG-1.11. Undo action name "Translate" (`FUN_1013c616c`, comment
  "Name of undo/redo item for changing a page's language").
- **PG-7.4 Memory (proven).** Never-translate is per host in Arc's own user
  defaults (`UserDefaultsClient.setTranslateDisabledForHost`,
  `translateDisabledForHost`, `resetTranslateSettings`), plus "Reset
  Translated-site Prompts" in Settings (FA §9.2 TR-3).

## PG-8 Website appearance

- **PG-8.1 Menu (proven).** View ▸ Appearance: header "Websites, Easels, and
  Notes will use:" (no selector), items Automatic (`setAutomaticAppearance:`),
  Light (`setLightAppearance:`), Dark (`setDarkAppearance:`) (MH "Untitled
  submenu"). Open drops Easels and Notes from the header.
- **PG-8.2 Engine (proven).** `ArcBrowserContextEffects
  registerColorScheme:forHostPattern:` / `unregisterColorScheme:` (also
  `registerZoomFactor:forHostPattern:`, `registerColorFilter:…`);
  `ArcWebContents removeColorScheme`; selector `applyColorScheme:`; Boost type
  `BoostColorScheme`. guess: the menu sets one pattern for every host and
  Boosts set per-host patterns.
- **PG-8.3 Not this feature.** `FUN_1017b4b94` builds a three-way SwiftUI
  picker labeled "Light Appearance" / "Automatic Appearance" / "Dark
  Appearance" with a 0.45 tooltip delay. guess: a theme or window appearance
  control, not the website menu.

## PG-9 Clear Cache and Refresh, Clear Cookies and Refresh

- Proven: menu outlets `clearCacheAndRefresh`, `clearCookiesAndRefresh`;
  strings "Clear cookies and refresh the current page.", "A button which will
  clear cookies for and refresh the current page", log name
  `ADKClient.clearCookiesAndRefreshPage` (`FUN_100df82e4`); engine
  `ArcWebContents clearSiteDataAndReload:`. guess: per-site (the current
  site's data), not all sites.

## PG-10 Developer menu and Developer Mode

- **PG-10.1 Panels (proven).** `ArcWebContentsDevTools openInspectView`,
  `openConsoleView`, `openNetworkView`. Network Inspector's description:
  "Opens the network inspector developer tool."
- **PG-10.2 Developer Mode is per site (proven).** `DeveloperModeClient`
  (`setDeveloperModeStatusForHost`, `getDeveloperModeState`, `reset`,
  `subscription`), file `StorableDeveloperModeState.json`, key
  `developerModeEnabledForHosts`, "Reset developer mode enabled hosts",
  "Toggles developer mode on or off for the current site.", Site Control row
  "Developer Mode" On/Off (SC-11). Menu validation `FUN_100314424` retitles the
  View ▸ Developer item to "Turn on Developer Mode for this site" or "Turn off
  Developer Mode for this site" and can hide it (`setHidden_`).
- **PG-10.3 Effect unknown.** No string proves what Developer Mode changes
  on the page or in the chrome. guess only.
- **PG-10.4 JavaScript from Apple Events (proven).** `ArcBrowser
  isJavaScriptFromAppleEventsAllowed` / `toggleJavaScriptFromAppleEventsAllowed`
  (Chromium's pref; default false in Chromium,
  `chrome/browser/ui/browser_ui_prefs.cc:190`).

## PG-11 Help ▸ Troubleshooting

- Task Manager: `ArcBrowserApplication showTaskManager`,
  `supportsTaskManager`, menu outlet `openTaskManagerMenuItem`. guess:
  Chromium's own task manager window.
- Traces: `ArcTracingController` (`start:`, `stop`, `abort`, `isTracing`),
  `ArcTracingConfiguration` (`filePath`, `tracingDuration`,
  `privacyFilteringEnabled`), toast type `TracingToastContentOptions`.
- Copy Arc Info: `copyArcInfo:`; toast comment "the Arc version was copied
  to the clipboard". Reveal Arc Data: `revealArcData:`.
- Network log (not a menu item here): `ArcNetworkActivityMonitor
  startLogging:with:error:` with `ArcNetworkLoggingConfiguration` (`filePath`,
  `loggingDurationInSeconds`).

## PG-12 Cast

- Proven: View ▸ Cast… (`cast:`), `ArcBrowser isCastEnabled`,
  `WindowData+Cast.swift`. guess: Chromium's media router and Cast dialog.

## PG-13 Needs a person (captures for the user's next Arc session)

| # | What to record | Fixes |
|---|---|---|
| C-T1 | Toast on a dark Space and a light Space: Cmd+Shift+C on a page with and without selected text; Cmd+= three times | PG-1.5 fill rule, quote offer layout, lifetime |
| C-S1 | Two-finger swipe back and forward on a page, slow and fast, as a screen recording | PG-4.3 visual |
| C-C1 | Capture… (Cmd+Shift+2): overlay, drag, result panel; Cmd+Shift drag | PG-6.6 |
| C-C2 | Capture Full Page on a long page; Capture in Portrait Mode | PG-6.4, PG-6.6 |
| C-R1 | A French page: the "Translation Available" button, its popover, the translated state, Show Original | PG-7.3 layout |
| C-D1 | Ctrl+D on a localhost page: what changes | PG-10.3 |
| C-N1 | A site notification banner and a click on it while the tab is in another Space | PG-5 click behavior |
| C-Q1 | Copy URL as Quote, then paste into TextEdit (plain text) | PG-2.2 clipboard format |

## PG-14 Capture session 2 results (2026-10-26)

Measured in the second capture session (1x, sRGB after the display profile; `interaction-states.md` §20, notation S2 `<item>/<frame>` and V `<seconds>` for `video/21-motion.mov`).

| Item | Result | Evidence |
|---|---|---|
| C-T1, light Space | In macOS Light with the default theme, the "Copied Current URL" toast is a lavender pill (`#CABEEB` area) with dark text and the share button. Selected text, the quote offer, and the zoom toasts were not captured. | S2 20/0048 |
| C-T1, lifetime and motion | The copy toast grows from a small pill at the top center of its final place while moving down (≈ 0.20 s, settled by ≈ 0.46 s), stays ≈ 4.95 s, and shrinks back up in ≈ 0.16 s. | V 69.99–75.11 s |
| Link status bubble (new) | Hovering a link shows a capsule at the bottom-left of the web content: 10 pt from its left edge, 12 pt above its bottom edge, 23 pt tall, fill `#0A0D4F` in the default dark theme, white text, the URL without the scheme. No AX element. | S2 04/0021, 0033 |
| Developer Mode tile | The Site Control Center lists "Developer Mode" / "Off" under Settings on a public site. ⌃D was not tested. | S2 09/0010 |
| C-C1, C-C2 | The Site Control Center action row has "Capture" (camera) and a second capture button (viewfinder). Not opened. | S2 09/0010 |

C-S1, C-R1, C-D1, C-N1, and C-Q1 stay open.
