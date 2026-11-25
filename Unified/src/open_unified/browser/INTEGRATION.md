# Track 6 integration notes

How `browser/` (Track 6) wires Chromium 156.0.8078.48 to the code of Tracks
2–5 and 7, and what each track still needs to align. All C++ is in
`namespace open_unified`, UI thread unless noted. Values use
`base::DictValue` / `base::ListValue` (156 removed `base::Value::Dict`).

## Files (Track 6)

| File | Role |
|---|---|
| `open_chromium_hooks.{h,cc}` | The only header patched Chromium files include (`// nogncheck`). One function per hook in `Unified/patches/chromium/series`. |
| `open_browser_main_extra_parts.{h,cc}` | `ChromeBrowserMainExtraParts` (hook 0009): factory registration in `PreProfileInit`, service creation in `PreBrowserStart`, `Start()` in `PostBrowserStart`, teardown in `PostMainMessageLoopRun`. |
| `open_browser_service.{h,cc}` | Process coordinator: `BrowserModel` + `SnapshotStore`, per-Profile stores on one `MayBlock` sequence (`RunOnStore()`), `SyncEngine`, ad-block KeyedService, `CommandRegistry`, `SuggestEngine`, `RoutingEvaluator`, the bridges and the automation server. Implements `BrowserModel::ArchiveSink`. |
| `open_tab_bridge.{h,cc}` | `TabStripModel` <-> `BrowserModel`. One Chromium Browser per (window, Profile); loaded tabs only, in sidebar order; lazy WebContents; adoption of Chromium-created tabs; page -> model propagation. |
| `open_window_controller.{h,cc}` | Track 4's `OpenViewController` and one `OpenWindowUi` per window that hosts Track 5's views and implements their delegates. |
| `open_sleep_controller.{h,cc}` | Track 2's `SleepScheduler` callbacks -> freeze / OPNH capture + `WebContents::Discard` / destroy / restore. |
| `open_boost_controller.{h,cc}` | Boost CSS (Track 3 `BoostStore::GenerateCssForBoosts`) in world 6, user JS in the main world, Zap picker with nonce validation. |
| `open_extension_bridge.{h,cc}` | `ToolbarActionsModel` / `ExtensionRegistry` / `ExtensionActionRunner` / `ExtensionPopup` for the URL pill, Site Control and Settings. |
| `open_automation_server.{h,cc}` | NDJSON automation (AF_UNIX + loopback TCP with token), only with `open_enable_automation`. |
| `open_model_util.{h,cc}` | Space/Profile of a node, sidebar order, live-state update. |
| `open_json.{h,cc}` | `open_types.h` <-> JSON for WebUI (snake_case, `bridge.ts`). |

## Track 2 (core/model, store, sleep, routing, suggest, commands)

Used as delivered: `BrowserModel` (observer `OnTreeChanged`, `NewTab`,
`CloseTab` + `ArchiveSink`, `PinTab`/`UnpinTab`, `AddFavorite`,
`MakeSplit`/`Unsplit`/`AddPane`/`RemovePane`, `SelectNode`, `FocusSpace`,
`UpdateTabNavigation`, `UpdateTabLiveState`, `RestoreArchivedTab`,
`SidebarSelectionId`, `SelectedNodeId`, ...), `SnapshotStore(data_root)`
with `Load()` / `ScheduleSave()` / `ScheduleMetadataSave()` / `SaveNow()`,
`sqlite_stores.h` (each store `Open()`ed on its sequence),
`opnh_codec.h` (`CaptureOpnhWithFallback`, `EncodeOpnh`, `DecodeOpnh`),
`SleepScheduler` (callbacks + `Tick(model, visible, now)`),
`RoutingEvaluator::Evaluate(request, model, little_open)`,
`SuggestEngine::Query`, `CommandRegistry` (overrides persisted through a
throwaway registry on a file sequence).

Resolved (Polish A/B):
- Command bar history: `SuggestEngine::SetRecentHistory()` gets the newest
  500 entries of the active Profile (`OpenBrowserService::
  RefreshRecentHistory()`): at `Start()`, in the same store task as each
  active-Profile `RecordVisit()`, after `library.deleteHistory`, after an
  onboarding history import, and when the active Profile changes. Replies
  carry a generation; older ones are dropped.
- `library.deleteHistory` uses `HistoryStore::DeleteIds()`.
- `settings.renameProfile` with an icon uses `BrowserModel::SetProfileIcon()`
  (undoable; its tree change schedules the save).

## Track 3 (sync, adblock, boosts, documents, import, platform)

Used as delivered: `OpenAdBlockProfileService` (+ factory, registered in
`PreProfileInit`), its `ExposeInterfacesToRenderer` (hook 0003),
`EnsureTabHelper`, `Get*Count`, `GetSnapshot`, `GetCatalog`,
`Add/RemoveExcludedDomain`; `BoostStore(profile_id, profile_dir)`;
`DocumentStore(profile_dir)`; `SyncEngine(state_dir, model, secrets,
loader_factory)`; `BrowserImporter` (Chromium and Firefox bookmarks and
history; Arc sidebar import is a separate flow); `OpenPlatform`.

Asks:
- Renderer MemoryCache invalidation for ad-block changes: hook 0003 applies
  Engine patch 0903 (`WebCacheManager::ClearCacheForProcessOnNavigation`).
  `OpenAdBlockProfileService` should install
  `OpenAdBlockService::SetRendererCacheInvalidator` with it (the CEF-only
  `ConfigureAdBlockRendererCache` is not copied by unified-apply).
- `SyncStatusInfo.state` is camelCase (`signedOut`, `needsReauth`);
  Track 6 maps it to bridge.ts `signed_out|idle|syncing|error`.
- `import.probeBrowsers` reports `DetectedBrowserProfile::bookmark_count` /
  `history_count` (Polish A).

## Tracks 4 and 5 (ui/views)

- Hook 0002 calls `OpenBrowserView::Install(browser_view,
  service->view_controller())`, then `OpenWindowController::
  OnBrowserViewInstalled()`, which puts `OpenCommandBarView` (kCommandBar),
  `OpenPeekOverlayView` (kPeek) and `OpenSplitContainerView`
  (`SetSplitContainer`) into the window. Before `Uninstall`, the window UI is
  destroyed.
- Hook 0002 also starts `BrowserViewLayoutImpl::Layout()` with
  `LayoutOpenBrowserView(host)`: while `OpenBrowserView` is installed it gets
  the whole client area and Chromium's layout returns.
- Split View: a page can be attached to one WebView only, so while a Split
  is selected Track 6 detaches the page from
  `BrowserView::GetActiveContentsWebView()` and gives the panes to the split
  container; it re-presents after every activation.
- `OpenViewController::CreateMenuModel` and `GetFavicon` keep Track 4's
  defaults for now.
- Find bar, Toasts and the Ctrl+Tab switcher (`OpenWindowUi`) live in their
  own `secondary::OverlayWidgetHost` child widgets, created on first use.
  An empty, event-transparent view in the `kFindBarAndToasts` slot tracks
  the web panel's bounds; its `OnViewBoundsChanged` re-anchors the widgets
  (window resize, sidebar slide).
- Accelerators: `OpenWindowUi` registers the CommandRegistry shortcuts of
  `find`, `find-next`, `find-previous`, `tab-switcher-forward/backward` and
  `new-little-open-window` (user overrides included; re-registered by
  `PersistShortcuts()`) on the window's FocusManager at
  `kHighPriority`, ahead of Chromium's table and, through
  `BrowserView::PreHandleKeyboardEvent`, ahead of the page. Esc is
  registered only while the find bar shows.
  - Ask (hooks owner, macOS): Cmd+F/Cmd+G are also NSMenu key equivalents
    (IDC_FIND, IDC_FIND_NEXT). If the menu wins over the views accelerator
    on macOS, route those IDC ids to `OpenWindowUi::ShowFindBar()` /
    `FindNext()` from `chrome::ExecuteCommand` (new hook) so Chromium's own
    find bar never appears.
- Find bar: drives `find_in_page::FindTabHelper` of the active page
  (`StartFinding` / `StopFinding`, results through `FindResultObserver`).
  Seed: the page's selection (40 characters), else the previous query. A
  tab switch closes the session.
- Toasts: "Copied Current URL" (Copy URL intent and command, Site Control,
  pane bar), "Tab Archived" with Undo (ArchiveSink records with reason
  `closed`; Undo runs `ArchiveStore::Restore()` and
  `BrowserModel::RestoreArchivedTab()`), "Space Switched" on a focused-Space
  change while the sidebar is hidden (guess: no Arc capture of this toast).
- Tab switcher: per-window MRU from `OnTabActivated`; the HUD lists the
  current tab, then MRU, then the focused Space's tabs when MRU is short. A
  `views::EventMonitor` on the window forwards the Ctrl release (and an
  early Esc) to the HUD before it has focus.
- Little Open: `OpenLittleOpenController` (owned by `OpenWindowController`)
  hosts an `OpenCommandBarView` in `kLittleOpen` mode, then a WebContents
  it owns (tab helpers + ad block attached). Entry points: the
  `new-little-open-window` shortcut and action, `little-open-global`
  action, and `OpenWindowController::RouteExternalUrl()` (Air Traffic
  Control through `RoutingEvaluator`, honoring
  `links.externalLinksLittleOpen`). "Open in <Space>" reopens the URL as a
  Today tab of that Space (Peek's approach; form state does not carry over
  yet) and closes the window. Ask (hooks owner): call
  `RouteExternalUrl()` for OS-handed URLs (macOS `application:openURLs:`,
  Windows/Linux command-line URLs) so Air Traffic Control runs for them.
- Peek and Little Open pages are not tab-strip tabs. Chromium 156 keeps
  `TabHelpers::AttachTabHelpers()` private (friend list), so they get
  `FindTabHelper` and Open's ad-block helper only. Ask (hooks owner): a
  friend for an Open adopter class in `tab_helpers.h` (as CEF's
  `CefBrowserPlatformDelegateAlloy`) if they need permission prompts,
  JavaScript dialogs or autofill.
- Automation (`open_enable_automation`): `find-bar`, `toasts`,
  `tab-switcher`, `little-open` (open, route, open-in-space, close, state).

## Track 7 (Unified/webui)

- `AdBlockState.lists` now carries the full catalog (Track 3's
  `GetCatalog()`: id, display_name, info_url, category, bundled,
  default_enabled, unavailable_reason) with `enabled` per list.
- Routes Track 6 opens: `open://library/spaces/<space id>` (Space editor),
  `open://library/{history,archive,downloads,media}`,
  `open://boosts/new?host=<host>`, `open://settings/shortcuts`,
  `open://welcome/help`. Each host serves `<host>.html` for every path.
- Shortcut strings are `Mod+Shift+T` style (`Mod` = Command on macOS,
  Control elsewhere).
