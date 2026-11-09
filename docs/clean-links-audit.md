# Clean link copy and share audit

Section 11, feature-gap 2026-11-09 §8 item 7 / §3 Clean-link.
All changed tab/page URL payloads use `OpenModel.URLCleaner`; the navigation URL stays intact.

| Call site | Decision and reason |
|---|---|
| `EngineWebContentHostFactory.copyLinks` | Clean every leaf tab before formatting. Covers Today, pinned, favorite and split-pane Copy Link, multi-selection Copy Links, folder Copy All Links, plain and Markdown. Keep traversal order and descendant deduplication. Show the singular/plural clean toast only after a successful write that removed a tracker. Count copied links, including unchanged links, for plural wording. Tracker-free sidebar copies had no toast and still have none. |
| `AppSettingsActions` Space Manager `.copyLink` fallback | Clean plain/Markdown links when no browser factory exists. The live-browser route already uses `copyLinks`. No new toast surface. |
| `SplitViewController.menu` Copy Link | Clean each split pane URL before joining the lines. Show the clean-link toast only when a tracker was removed; otherwise keep its current no-toast behavior. |
| `LittleOpenWindowController.copyURL` | Clean the current page/session URL before copying. Keep the title-bar and command routes. |
| `PiPMenuBuilder` Copy URL | Clean both string and URL pasteboard representations of the source page URL. |
| `shareSidebarTab` | Clean the row tab URL before constructing the native picker. |
| `shareFromToast` | Clean at the payload boundary as well as in the existing Copy URL command. |
| page `share-page` / `sharePage` | Clean the focused page URL and use the window's owned native picker/delegate, as row/toast Share does. |
| `PageCommands.writeLink`, Copy URL Markdown, Copy URL Quote | Keep. Callers already clean the URL. Quote copies preserve the generated text fragment. The Copy URL command, existing plain toast and quote offer are unchanged. |
| `PaneChromeView` copy button | Keep. Already uses `URLCleaner`; the App routes its real button to Copy URL. |
| `OpenSidebar/DragDrop.swift` URL/string fields | Keep raw. This is drag transport, including browser navigation and local node moves, rather than a Copy Link or Share command. Changing it would change destination navigation. |
| `DownloadsCenter` copy | Keep. Copies a local downloaded file URL, not its source tab URL. |
| `CaptureController` Share / copy | Keep. Shares a local image file or copies image data, not a tab URL. |
| `AppCommandBarDelegate` / Little Open `.copy(text)` | Keep. Calculator result text (`CommandBarController` `.calculator`), not tab URLs. |
| `AppSettingsActions.copyText` | Keep. Settings/debug report text, not a tab URL copy command. |
| `TroubleshootingActions` copy | Keep. Static Open information, not a tab URL. |
| automation pasteboard writers / sidebar drag fixture | Keep. Synthetic transport and sentinels used by existing real-App flows. |

The audit searched `setString`, `writeObjects`, `NSSharingServicePicker`, `copyLinks`, and `absoluteString` across `App` and `Packages/OpenKit/Sources`. Engine page-context operations copy their own selected/link/media content; they are not shell tab-URL payloads and are outside this shell change.

Real-App rows are in `tools/e2e/clean_links.py`, called by the existing page copy-command suite. `OPEN_E2E_PAGE_COPY_ONLY=1 tools/e2e/engine_e2e.py --only page` runs the copy/quote/zoom group without unrelated page features. The App preserves and restores all clipboard item types in memory; the harness only reads its own synthetic clipboard contents. Native share assertions check the actual delegate `items` payload as well as picker lifecycle. The focused run changes only the existing Shared Quotes preference, restored in `finally`.
