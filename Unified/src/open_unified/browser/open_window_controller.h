// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_WINDOW_CONTROLLER_H_
#define OPEN_UNIFIED_BROWSER_OPEN_WINDOW_CONTROLLER_H_

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/scoped_multi_source_observation.h"
#include "base/scoped_observation.h"
#include "base/values.h"
#include "components/web_modal/modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_capture_controller.h"
#include "open_unified/browser/open_chromium_hooks.h"
#include "open_unified/browser/open_download_bridge.h"
#include "open_unified/browser/open_extension_bridge.h"
#include "open_unified/browser/open_media_bridge.h"
#include "open_unified/browser/open_sidebar_menus.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/livedata/open_livedata_service.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/ui/views/open_boost_editor_view.h"
#include "open_unified/ui/views/open_browser_view.h"
#include "open_unified/ui/views/open_command_bar_view.h"
#include "open_unified/ui/views/open_find_bar_and_toasts.h"
#include "open_unified/ui/views/open_link_status_bubble.h"
#include "open_unified/ui/views/open_little_open_view.h"
#include "open_unified/ui/views/open_media_player_view.h"
#include "open_unified/ui/views/open_peek_overlay_view.h"
#include "open_unified/ui/views/open_sidebar_popovers.h"
#include "open_unified/ui/views/open_site_control_bubble.h"
#include "open_unified/ui/views/open_space_editor_view.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/events/event_observer.h"
#include "ui/views/controls/webview/unhandled_keyboard_event_handler.h"
#include "ui/views/view_observer.h"
#include "ui/views/widget/widget_observer.h"

class BrowserView;
class BrowserWindowInterface;
class GURL;

namespace content {
class WebContents;
}

namespace views {
class EventMonitor;
class MenuRunner;
class WebView;
class Widget;
}  // namespace views

namespace open_unified {

class OpenLittleOpenController;
class OpenWindowUi;

// The browser side of Open's views:
//
// - implements Track 4's OpenViewController (model reads, ~40 intents,
//   sidebar context menus, observer fan-out) for every OpenBrowserView,
// - implements hooks::OpenHookDelegate (quit guard, dock reopen, menu
//   commands, Peek/Split link interception, hover target URL, fullscreen,
//   web context menu commands, and Chromium bubble anchoring),
// - owns one OpenWindowUi per installed window, hosting Track 5 / Wave A-E
//   secondary surfaces (Command Bar, Peek, Split container, Site Control,
//   Find bar, Toasts, Ctrl+Tab switcher, Library Drawer, Boost Editor, Space
//   Editor, Media Mini-Player, Popovers, and Link Status Bubble),
// - owns standalone Settings and First Run (Onboarding) windows and the
//   floating Little Open windows (OpenLittleOpenController).
//
// UI thread only. Owned by OpenBrowserService.
class OpenWindowController : public OpenViewController,
                             public BrowserModel::Observer,
                             public OpenTabBridge::Observer,
                             public OpenExtensionBridge::Observer,
                             public OpenBrowserService::Observer,
                             public OpenDownloadBridge::Observer,
                             public OpenMediaBridge::Observer,
                             public OpenLiveDataService::Observer,
                             public OpenCaptureController::Delegate,
                             public hooks::OpenHookDelegate {
 public:
  explicit OpenWindowController(OpenBrowserService* service);
  ~OpenWindowController() override;

  OpenWindowController(const OpenWindowController&) = delete;
  OpenWindowController& operator=(const OpenWindowController&) = delete;

  void Start();
  void Shutdown();

  // Hook 0002, right after OpenBrowserView::Install / before Uninstall.
  void OnBrowserViewInstalled(BrowserView* browser_view);
  void OnBrowserViewDestroying(BrowserView* browser_view);

  // The coordinator of the main window (null before its window exists).
  OpenWindowUi* MainWindowUi();
  OpenWindowUi* WindowUiFor(const WindowID& window_id);
  // The coordinator of one Chromium window (hook 0012 / 0014 / 0015).
  OpenWindowUi* WindowUiForBrowserView(BrowserView* browser_view);
  OpenWindowUi* WindowUiForBrowser(BrowserWindowInterface* browser);

  // Standalone Settings window (960x660, min 800x540, single-instance).
  void OpenSettingsWindow(std::string_view section = "");
  void CloseSettingsWindow();
  bool settings_window_open() const;

  // Standalone First Run / Onboarding window (860x620 frameless centered).
  void OpenFirstRunWindow();
  void CloseFirstRunWindow();
  void OnOnboardingCompleted();
  bool first_run_window_open() const;

  // Automation window accessors (null when the window is not open).
  views::Widget* ActiveLittleOpenWidget() const;
  views::Widget* FirstRunWidget() const;
  views::Widget* SettingsWindowWidget() const;

  // Extension bridges of every Profile (OpenBrowserService adds each one
  // when its ProfileServices exist and removes it before they go away), so
  // a Profile switch or deletion never leaves an observer behind.
  void ObserveExtensionBridge(OpenExtensionBridge* bridge);
  void UnobserveExtensionBridge(OpenExtensionBridge* bridge);

  // Track 4 observers: Peek and Command Bar visibility of a window.
  void NotifyPeekChanged(const WindowID& window_id);
  void NotifyCommandBarStateChanged(const WindowID& window_id);

  // Little Open (Arc's Little Arc): a floating window with its own command
  // bar (|url| empty) or a live page. |profile_id| empty: the active
  // Profile; |target_space| empty: "Open in" uses the focused Space.
  OpenLittleOpenController* OpenLittleOpen(
      const std::optional<GURL>& url,
      const ProfileID& profile_id = ProfileID(),
      std::optional<SpaceID> target_space = std::nullopt);
  // An external link (OS handoff, automation `open-url --external`): Air
  // Traffic Control picks Little Open or a Space (RoutingEvaluator).
  void RouteExternalUrl(const GURL& url,
                        std::optional<std::string> source_app_id);
  // Called by a Little Open window once it has closed; deletes it.
  void OnLittleOpenClosed(OpenLittleOpenController* little_open);
  const std::vector<std::unique_ptr<OpenLittleOpenController>>&
  little_opens() const {
    return little_opens_;
  }

  // A shortcut changed (Settings): every window re-registers its Open
  // accelerators from CommandRegistry.
  void ReloadShortcuts();
  // Live Settings preference update (e.g. appearance.toolbar,
  // appearance.increaseContrast, appearance.fullUrl, shortcuts.priority,
  // previews.enabled). Empty |key| refreshes all live preference effects.
  void OnPreferencesChanged(std::string_view key = "");
  // Syncs appearance.toolbar back to OpenPreferences without recursing into
  // OnPreferencesChanged().
  void SyncToolbarPreference(bool visible);
  // User closes archived these tabs (ArchiveSink, reason "closed"): the
  // main window shows "Tab Archived" with Undo.
  void OnTabsArchivedByUser(std::vector<ArchivedTabRecord> records);

  // --- OpenViewController ---------------------------------------------------
  const BrowserWindowState* GetWindowState(
      const WindowID& window_id) const override;
  std::vector<SpaceID> GetWindowSpaceIds(
      const WindowID& window_id) const override;
  const Space* GetSpace(const SpaceID& space_id) const override;
  const Profile* GetProfile(const ProfileID& profile_id) const override;
  const SidebarNode* FindNode(const ItemID& node_id) const override;
  const Tab* GetActiveTab(const WindowID& window_id) const override;
  bool IsSplitViewActive(const WindowID& window_id) const override;
  bool IsSystemDarkMode() const override;
  WindowID WindowIdForBrowserView(BrowserView* browser_view) override;
  bool IsIncreaseContrastEnabled() const override;
  bool IsIncognitoWindow(const WindowID& window_id) const override;
  std::optional<ItemID> GetPeekSourceNode(
      const WindowID& window_id) const override;
  bool IsNewTabCommandBarOpen(const WindowID& window_id) const override;
  std::vector<OpenToolbarActionInfo> GetPinnedToolbarActions(
      const WindowID& window_id) const override;
  gfx::ImageSkia GetFavicon(const ItemID& tab_id) const override;
  bool IsDeveloperModeEnabled() const override;
  void HandleIntent(const WindowID& window_id,
                    const OpenIntent& intent) override;
  std::unique_ptr<ui::MenuModel> CreateMenuModel(
      const WindowID& window_id,
      const OpenMenuTarget& target) override;
  void AddViewObserver(OpenViewObserver* observer) override;
  void RemoveViewObserver(OpenViewObserver* observer) override;

  // BrowserModel::Observer:
  void OnTreeChanged(const TreeChange& change) override;
  // OpenTabBridge::Observer:
  void OnTabActivated(const ItemID& tab_id) override;
  void OnTabContentsAttached(const ItemID& tab_id,
                             content::WebContents* contents) override;
  void OnBrowserWindowBound(BrowserWindowInterface* browser,
                            const WindowID& window_id) override;
  // OpenExtensionBridge::Observer:
  void OnExtensionActionsChanged() override;
  void OnExtensionPopupVisibilityChanged(const std::string& extension_id,
                                         bool showing) override;
  // OpenBrowserService::Observer:
  void OnOpenEvent(const std::string& event_name,
                   const base::Value& payload) override;
  // OpenDownloadBridge::Observer:
  void OnDownloadUpdatedForProfile(const ProfileID& profile_id,
                                   const DownloadRecord& record) override;
  void OnDownloadRemoved(const std::string& id) override;
  // OpenMediaBridge::Observer:
  void OnMediaSessionsChanged() override;
  // OpenLiveDataService::Observer:
  void OnFavoriteSubtitleChanged(const ItemID& tab_id,
                                 const std::string& subtitle) override;
  void OnFavoriteBadgeChanged(const ItemID& tab_id,
                              const std::string& badge_text) override;
  void OnLiveFolderUpdated(const ItemID& folder_id,
                           const std::vector<LiveFolderItem>& items,
                           int unread_count) override;
  // OpenCaptureController::Delegate:
  void OnCaptureCompleted(const CaptureResult& result) override;
  void OnCaptureFailed(const std::string& error_message) override;
  void OnCaptureOpenInLibrary(const CaptureResult& result) override;
  void OnCaptureAddToEasel(const CaptureResult& result) override;

  // hooks::OpenHookDelegate:
  bool ShouldTerminateApp() override;
  bool HandleAppReopen(bool has_visible_windows) override;
  std::optional<bool> IsBrowserCommandEnabled(BrowserWindowInterface* browser,
                                              int command_id) override;
  bool HandleBrowserCommand(BrowserWindowInterface* browser,
                            int command_id) override;
  bool MaybeInterceptLinkOpen(BrowserWindowInterface* browser,
                              content::WebContents* source,
                              const content::OpenURLParams& params) override;
  bool MaybeInterceptAddNewContents(
      BrowserWindowInterface* browser,
      content::WebContents* source,
      std::unique_ptr<content::WebContents>& new_contents,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      bool user_gesture) override;
  void OnUpdateTargetURL(BrowserWindowInterface* browser,
                         content::WebContents* source,
                         const GURL& url) override;
  void OnFullscreenStateChanged(BrowserView* browser_view,
                                bool is_fullscreen) override;
  bool ExecuteWebContextMenuCommand(BrowserWindowInterface* browser,
                                    content::WebContents* source,
                                    const content::ContextMenuParams& params,
                                    int command_id,
                                    int event_flags) override;
  views::View* GetBubbleAnchorView(BrowserWindowInterface* browser) override;
  std::optional<gfx::Rect> GetBubbleAnchorRect(
      BrowserWindowInterface* browser) override;

  OpenBrowserService* service() { return service_; }
  // The visible page of the main window (automation, Little Open). Window
  // UIs use OpenWindowUi::ActiveWebContents() for their own window.
  content::WebContents* ActiveWebContents() const;
  // Favicon lookup by page URL across loaded tabs (used by Command Bar).
  gfx::ImageSkia GetFaviconForUrl(const GURL& page_url) const;

  // Builds a SidebarMenuContext and ui::MenuModel for `target` in `window_id`.
  std::unique_ptr<ui::SimpleMenuModel> BuildMenuModelForTarget(
      const WindowID& window_id,
      const OpenMenuTarget& target);

  // Syncs SuggestEngine extension actions from the active Profile's bridge.
  void RefreshSuggestExtensions();

  // Live Space theme preview while dragging inside Space Theme Editor (avoids
  // polluting undo history or writing browser.json per frame).
  void SetSpaceThemePreview(const SpaceID& space_id, const SpaceTheme& theme);
  void ClearSpaceThemePreview(const SpaceID& space_id);

  // Undo of a "Tab Archived" toast: takes the rows out of Archive.sqlite
  // and puts the tabs back where they were.
  void RestoreArchived(std::vector<ArchivedTabRecord> records);

 private:
  class StandaloneWebWindow;

  void AttachServiceObservers();
  void DetachServiceObservers();
  void NotifyWindowStateChanged();
  // -1 back, +1 forward, 0 reload, on |window_id|'s own page.
  void NavigateActive(const WindowID& window_id, int direction);
  // The page |window_id| shows (its Browser's active tab), else the main
  // window's.
  content::WebContents* ActiveWebContentsFor(const WindowID& window_id) const;
  const OpenWindowUi* WindowUiForConst(const WindowID& window_id) const;
  OpenExtensionBridge* ExtensionBridgeForWindow(
      const WindowID& window_id) const;

  void DispatchSidebarMenuCommand(const WindowID& window_id,
                                  const SidebarMenuCommand& cmd);
  void OnSettingsWindowClosed();
  void OnFirstRunWindowClosed();

  raw_ptr<OpenBrowserService> service_;
  bool started_ = false;
  bool service_observers_attached_ = false;
  bool syncing_toolbar_pref_ = false;
  raw_ptr<BrowserView> hidden_main_browser_view_for_first_run_ = nullptr;
  std::map<raw_ptr<BrowserView>, std::unique_ptr<OpenWindowUi>> windows_;
  std::vector<std::unique_ptr<OpenLittleOpenController>> little_opens_;
  std::unique_ptr<StandaloneWebWindow> settings_window_;
  std::unique_ptr<StandaloneWebWindow> first_run_window_;
  std::map<SpaceID, Space> theme_preview_spaces_;
  std::map<SpaceID, bool> space_header_shown_by_space_;
  std::map<std::string, bool> library_media_source_enabled_;
  base::ObserverList<OpenViewObserver> view_observers_;
  base::ScopedMultiSourceObservation<OpenExtensionBridge,
                                     OpenExtensionBridge::Observer>
      extension_observations_{this};
  base::WeakPtrFactory<OpenWindowController> weak_factory_{this};
};

// One Open window's Track 5 & Wave A-E secondary views and their delegates.
//
// Command Bar, Peek, Library Drawer, Find bar, Toasts, Boost Editor and the
// Ctrl+Tab switcher live in their own secondary::OverlayWidgetHost child
// widgets (created on first use, so a window that never opens them pays
// nothing), stacked above the page's native view.
class OpenWindowUi : public OpenBrowserView::Delegate,
                     public CommandBarDelegate,
                     public PeekDelegate,
                     public SiteControlDelegate,
                     public OpenSplitContainerDelegate,
                     public FindBarDelegate,
                     public TabSwitcherDelegate,
                     public ui::AcceleratorTarget,
                     public views::ViewObserver,
                     public views::WidgetObserver,
                     public ui::EventObserver,
                     public content::WebContentsDelegate,
                     public web_modal::WebContentsModalDialogManagerDelegate {
 public:
  OpenWindowUi(OpenWindowController* controller,
               BrowserView* browser_view,
               OpenBrowserView* open_view,
               WindowID window_id);
  ~OpenWindowUi() override;

  OpenWindowUi(const OpenWindowUi&) = delete;
  OpenWindowUi& operator=(const OpenWindowUi&) = delete;

  const WindowID& window_id() const { return window_id_; }
  void RebindWindowId(const WindowID& window_id);
  BrowserView* browser_view() const { return browser_view_; }
  OpenBrowserView* open_view() const { return open_view_; }

  // This window's own page: its Browser's active tab (the focused pane in
  // Split View), null for the empty state. Never another window's.
  content::WebContents* ActiveWebContents() const;
  std::optional<ItemID> ActiveTabId() const;

  // Command Bar (Cmd/Ctrl+T, Cmd/Ctrl+L, the + button).
  void ShowCommandBar(CommandBarMode mode,
                      const std::u16string& initial_text,
                      std::optional<gfx::Rect> anchor_in_screen);
  void HideCommandBar();
  bool command_bar_shown() const;
  void TypeInCommandBar(const std::u16string& text);
  // Return in the bar (automation `command-bar enter`): commits the
  // selected row like the real key path.
  void CommitCommandBar();

  // Peek: a page over the window (80% card, 0.70 scrim) with zero-reload
  // live WebContents adoption & promotion.
  void OpenPeek(const GURL& url, const std::optional<ItemID>& source_node);
  void OpenPeekWithContents(std::unique_ptr<content::WebContents> wc,
                            const std::optional<ItemID>& source_node);
  void ExpandPeek();
  void ClosePeek();
  bool peek_shown() const;
  std::optional<ItemID> peek_source() const { return peek_source_; }
  content::WebContents* PeekWebContents() const;

  // L3 in-window Library Drawer overlay on the left side of the browser window.
  void ShowLibraryDrawer(std::string_view section = "");
  void HideLibraryDrawer();
  bool library_drawer_shown() const;

  // Floating Boost Editor anchored to the right edge of the web panel.
  void OpenBoostEditor(const std::optional<std::string>& boost_id = std::nullopt,
                       bool arm_zap = false);
  void CloseBoostEditor();
  bool boost_editor_shown() const;

  // Space Theme / Identity Editor and New Space popovers.
  void ShowSpaceThemeEditor(const SpaceID& space_id,
                            bool open_identity_page = false,
                            views::View* anchor = nullptr);
  void ShowSpaceCreation(views::View* anchor = nullptr);

  // Sidebar popovers ("+", compact toolbar "More options", Recent Downloads).
  void TogglePlusPopover(views::View* anchor = nullptr);
  void ToggleToolbarMorePopover(
      std::optional<gfx::Rect> anchor_in_screen = std::nullopt);
  void ToggleDownloadsPopover(views::View* anchor = nullptr);
  // Windows/Linux Open Application Menu (top-left Open button, Alt+F, F10).
  void ShowAppMenu(views::View* anchor = nullptr);
  void SetExtensionPopupOpen(bool open);
  bool is_alt_down() const { return alt_down_; }
  void SyncSinglePaneToolbar();
  void SetSinglePaneToolbarVisible(bool visible, bool sync_pref = true);

  // Page translate popover anchored to the URL pill / Site Control anchor.
  void ShowTranslatePagePopover(views::View* anchor = nullptr);

  // Site Control bubble anchored to the URL pill (or a pane button).
  void ShowSiteControls(views::View* anchor);
  void HideSiteControls();
  bool site_controls_shown() const;

  // Split View: re-presents the selected node (single page or 2..4 panes).
  void UpdatePanel();
  void OpenLinkInSplitView(const GURL& url);
  bool split_active() const { return split_active_; }

  // Find in page (Cmd/Ctrl+F, Cmd/Ctrl+G, Shift+Cmd/Ctrl+G, Esc).
  void ShowFindBar(std::optional<std::u16string> query = std::nullopt);
  void FindNext(bool forward);
  void CloseFindBar();
  bool find_bar_shown() const;

  // Toasts at the top-right of the web panel.
  void ShowToast(ToastSpec spec);

  // Link hover URL capsule (Hook 0014 UpdateTargetURL) & fullscreen layout.
  void UpdateLinkStatusUrl(const GURL& url);
  void OnFullscreenStateChanged(bool is_fullscreen);

  // Ctrl+Tab / Ctrl+Shift+Tab: MRU switcher.
  void TabSwitcherStep(bool reverse);
  void TabSwitcherCommit();
  void TabSwitcherCancel();
  bool tab_switcher_active() const;

  // Model, media, download, extension and bridge notifications.
  void OnTabActivated(const ItemID& tab_id);
  void OnModelChanged();
  void AttachExtensionWindow();
  void DetachExtensionWindow();
  void RefreshMediaSessions();
  void RefreshDownloadProgress();
  void RefreshDownloadsPopover();
  void UpdateThemeForLiveSurfaces();

  // Registers Open's window accelerators dynamically from
  // CommandRegistry::WindowAcceleratorCommands().
  void RegisterAccelerators();
  void ActivateWindow();
  views::Widget* widget() const;
  secondary::Appearance CurrentAppearance() const;

  // Runs a CommandRegistry action (command bar rows, Little Open, hooks).
  void RunCommand(const std::string& action_id) { RunAction(action_id); }
  bool HandleCommand(CommandId command) { return RunShortcut(command); }
  // Hook 0012 compatibility entry point.
  bool HandleFindCommand(CommandId command);
  // The child widget hosting the Command Bar (automation key routing).
  views::Widget* command_bar_widget() const;

  // Automation readback (docs/automation.md).
  bool sidebar_hidden() const;
  bool single_pane_toolbar_visible() const {
    return single_pane_toolbar_visible_;
  }
  bool split_view_active() const { return split_active_; }
  base::DictValue AppMenuSnapshot();
  bool ExecuteAutomationCommand(std::string_view name,
                                const base::DictValue& args);
  base::DictValue CommandBarState() const;
  base::DictValue PeekState() const;
  base::DictValue SiteControlState() const;
  base::DictValue FindBarState() const;
  base::DictValue ToastState() const;
  base::DictValue TabSwitcherState() const;

  // CommandBarDelegate:
  CommandBarResults QuerySuggestions(const CommandBarQuery& query) override;
  std::optional<CommandBarScopeTarget> ResolveSiteSearch(
      std::u16string_view text,
      bool exact_keyword_only) override;
  void OnCommandBarIntent(const CommandBarIntent& intent) override;
  void OnCommandBarDismissed(CommandBarDismissReason reason,
                             std::optional<gfx::Point> click_location) override;
  void OnCommandBarRemoteQuery(const CommandBarQuery& query) override;
  void OnCommandBarOpenSearchSettings() override;
  void OnCommandBarDismissPrivacyNotice() override;

  // PeekDelegate:
  void OnPeekDismissed(PeekDismissReason reason) override;
  void OnPeekExpandToTab() override;
  void OnPeekOpenInSplit() override;
  void OnPeekDismissedWithUndo(PeekDismissReason reason,
                               const GURL& last_dismissed_url) override;
  bool OnPeekCopyUrl(const GURL& url) override;
  void OnPeekOpenInFavorite() override;
  void OnPeekOpenInSpace(const SpaceID& space_id) override;

  // SiteControlDelegate:
  void OnSiteControlAction(SiteControlAction action) override;
  void OnSiteControlExtensionPressed(const std::string& extension_id,
                                     views::View* anchor) override;
  void OnSiteControlPermissionChanged(SitePermissionKind kind,
                                      SitePermissionSetting setting) override;
  void OnSiteControlAdBlockToggled(bool enabled) override;
  void OnSiteControlClosed() override;

  // OpenBrowserView::Delegate:
  void OnAppMenuRequested(views::View* anchor) override;
  void OnExtensionContextMenuRequested(const std::string& extension_id,
                                       views::View* anchor,
                                       const gfx::Point& screen_pt) override;
  void OnSpaceReordered(const std::string& space_id, size_t to_index) override;
  void OnResetPinnedTab(const ItemID& id, bool separate) override;
  void OnTabDragStateChanged(bool dragging, const ItemID& tab_id) override;
  void OnSinglePaneToolbarCommand(PaneCommand command,
                                  views::View* anchor) override;
  void OnSinglePaneHostClicked(views::View* anchor) override;
  void OnSystemThemeChanged() override;

  // OpenSplitContainerDelegate:
  void OnSplitFractionsCommitted(const ItemID& split_id,
                                 const std::vector<double>& fractions) override;
  void OnPaneFocusRequested(const std::optional<ItemID>& split_id,
                            const ItemID& tab_id) override;
  bool OnPaneCommand(const std::optional<ItemID>& split_id,
                     const ItemID& tab_id,
                     PaneCommand command,
                     views::View* anchor) override;
  void OnEmptyPaneOpenCommandBar(const std::optional<ItemID>& split_id,
                                 const ItemID& tab_id) override;
  void OnPanesSwapped(const ItemID& split_id,
                      size_t index_a,
                      size_t index_b) override;
  void OnPaneHostClicked(const std::optional<ItemID>& split_id,
                         const ItemID& tab_id,
                         size_t pane_index,
                         views::View* anchor) override;
  bool CanDropInSplit(const std::optional<ItemID>& dragged_tab_id,
                      const GURL& dragged_url,
                      SplitDropZone zone,
                      std::optional<size_t> target_pane_index) override;
  bool OnDropInSplit(const std::optional<ItemID>& dragged_tab_id,
                     const GURL& dragged_url,
                     SplitDropZone zone,
                     std::optional<size_t> target_pane_index) override;

  // FindBarDelegate:
  void OnFindQueryChanged(const std::u16string& query) override;
  void OnFindNext(bool forward) override;
  void OnFindClosed() override;
  void OnFindTargetDestroyed() override;

  // TabSwitcherDelegate:
  void OnTabSwitcherVisibilityChanged(bool visible) override;
  void OnTabSwitcherCommit(const ItemID& tab_id) override;
  void OnTabSwitcherCancel() override;
  void OnTabSwitcherNeedsThumbnails(
      const std::vector<ItemID>& tab_ids) override;

  // ui::AcceleratorTarget:
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override;
  bool CanHandleAccelerators() const override;

  // views::ViewObserver (the panel tracker in kFindBarAndToasts):
  void OnViewBoundsChanged(views::View* observed_view) override;
  void OnViewIsDeleting(views::View* observed_view) override;

  // views::WidgetObserver (top-level browser widget):
  void OnWidgetActivationChanged(views::Widget* widget, bool active) override;
  void OnWidgetBoundsChanged(views::Widget* widget,
                             const gfx::Rect& new_bounds) override;
  void OnWidgetDestroying(views::Widget* widget) override;

  // ui::EventObserver (key releases while the switcher is active):
  void OnEvent(const ui::Event& event) override;

  // content::WebContentsDelegate (Peek & Library drawer pages):
  bool HandleKeyboardEvent(content::WebContents* source,
                           const input::NativeWebKeyboardEvent& event) override;
  content::JavaScriptDialogManager* GetJavaScriptDialogManager(
      content::WebContents* source) override;

  // web_modal::WebContentsModalDialogManagerDelegate (Peek's page):
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost(
      content::WebContents* web_contents) override;
  bool IsWebContentsVisible(content::WebContents* web_contents) override;

 private:
  class ModifierEventObserver;

  void ApplyWindowEffects();
  void SyncWindowChromeFromModel();
  void PersistWindowBounds(views::Widget* w, const gfx::Rect& bounds);
  void UpdateSidebarPopoverState();
  void OnAppMenuClosed();
  open_unified::SiteControlState BuildSiteControlState() const;
  SiteControlCallbacks BuildSiteControlCallbacks();
  ExtensionHostWindow MakeExtensionHostWindow() const;
  OpenExtensionBridge* ExtensionBridge() const;
  void OpenUrlWithDisposition(const GURL& url,
                              CommandBarDisposition disposition);
  void RunAction(const std::string& action_id);
  bool RunCommandId(CommandId command);
  void CopyUrl(const GURL& url);
  void CopyCleanUrl(const GURL& url);
  void CreateAndOpenDocument(bool is_easel, bool in_split);
  void HandleDownloadPopoverAction(DownloadPopoverAction action,
                                   const std::string& download_id);
  void OnTabThumbnailCaptured(ItemID tab_id,
                              const content::CopyFromSurfaceResult& result);
  OpenBrowserService* service() const;

  // Overlay widgets (lazy) and their anchors in widget coordinates.
  gfx::Rect PanelRectInWidget() const;
  gfx::Rect PanelRectInScreen() const;
  gfx::Rect WindowRectInWidget() const;
  gfx::Rect LibraryDrawerRectInWidget() const;
  void EnsureCommandBar();
  void EnsurePeek();
  void EnsureLibraryDrawer();
  void EnsureFindBar();
  void EnsureToasts();
  void EnsureTabSwitcher();
  void UpdateOverlayAnchors();
  void RestackVisibleOverlays();
  void PopulatePeekSpaceChoices();
  content::WebContents* FindTargetContents() const;
  find_in_page::FindTabHelper* FindHelper() const;
  enum class EscapePriority { kNone, kNormal, kHigh };

  void SetEscapePriority(EscapePriority priority);
  // Esc is a window accelerator only while an Open overlay shows.
  void UpdateEscapeRegistration();
  void RegisterSwitcherAccelerators();
  void UnregisterSwitcherAccelerators();
  bool RunShortcut(CommandId command);
  std::vector<TabSwitcherItem> BuildSwitcherItems() const;
  void StopSwitcherMonitor();
  void FocusPage();
  void MountMediaPlayerStack();
  void MountLinkStatusBubble();
  views::View* FindViewMatchingScreenRect(const gfx::Rect& rect) const;

  raw_ptr<OpenWindowController> controller_;
  raw_ptr<BrowserView> browser_view_;
  raw_ptr<OpenBrowserView> open_view_;
  WindowID window_id_;

  // Command Bar, Peek, Library Drawer (child widgets over the client area).
  std::unique_ptr<secondary::OverlayWidgetHost> command_bar_host_;
  raw_ptr<OpenCommandBarView> command_bar_ = nullptr;
  uint64_t remote_suggest_request_id_ = 0;

  std::unique_ptr<secondary::OverlayWidgetHost> peek_host_;
  raw_ptr<OpenPeekOverlayView> peek_ = nullptr;
  std::optional<ItemID> peek_source_;

  std::unique_ptr<secondary::OverlayWidgetHost> library_host_;
  raw_ptr<views::WebView> library_web_view_ = nullptr;
  std::string library_section_;

  // Boost editor, Space editor, Sidebar popovers, and App Menu.
  std::unique_ptr<OpenBoostEditorSession> boost_editor_;
  OpenSpaceEditorPopover space_editor_popover_;
  OpenPlusPopover plus_popover_;
  OpenToolbarMorePopover more_popover_;
  std::unique_ptr<OpenDownloadsPopover> downloads_popover_;
  std::unique_ptr<ui::SimpleMenuModel> app_menu_model_;
  std::unique_ptr<views::MenuRunner> app_menu_runner_;
  std::unique_ptr<ModifierEventObserver> modifier_observer_;
  std::unique_ptr<views::EventMonitor> modifier_monitor_;
  bool extension_picker_open_ = false;
  bool extension_popup_open_ = false;
  bool alt_down_ = false;

  raw_ptr<OpenSplitContainerView> split_ = nullptr;
  std::unique_ptr<OpenSiteControlBubble> site_controls_;
  CommandBarMode command_bar_mode_ = CommandBarMode::kNewTab;

  // Sidebar media mini-player stack (owned by OpenSidebarView) and link hover
  // status bubble (owned by panel_tracker_).
  raw_ptr<OpenMediaPlayerStackView> media_stack_ = nullptr;
  raw_ptr<OpenLinkStatusBubbleView> link_status_ = nullptr;

  views::UnhandledKeyboardEventHandler unhandled_keyboard_event_handler_;
  bool split_active_ = false;
  bool stay_on_top_ = false;
  bool single_pane_toolbar_visible_ = false;
  bool extension_window_attached_ = false;

  // Panel tracker (kFindBarAndToasts slot): its bounds are the panel's.
  raw_ptr<views::View> panel_tracker_ = nullptr;
  base::ScopedObservation<views::View, views::ViewObserver>
      panel_observation_{this};
  base::ScopedObservation<views::Widget, views::WidgetObserver>
      widget_observation_{this};

  // Find bar.
  std::unique_ptr<secondary::OverlayWidgetHost> find_host_;
  raw_ptr<OpenFindBarView> find_bar_ = nullptr;
  EscapePriority escape_priority_ = EscapePriority::kNone;

  // Toasts.
  std::unique_ptr<secondary::OverlayWidgetHost> toast_host_;
  raw_ptr<OpenToastStackView> toasts_ = nullptr;

  // Ctrl+Tab switcher: MRU order of this window's tabs (newest first).
  std::unique_ptr<secondary::OverlayWidgetHost> switcher_host_;
  raw_ptr<OpenTabSwitcherView> switcher_ = nullptr;
  std::unique_ptr<views::EventMonitor> switcher_monitor_;
  std::vector<ItemID> mru_;

  // Space Switched toast & Library theme push: the focused Space last seen.
  std::optional<SpaceID> last_focused_space_;

  // Registered accelerators -> Open command.
  std::map<ui::Accelerator, CommandId> accelerator_commands_;
  // Temporary high-priority accelerators registered while the Ctrl+Tab
  // switcher is active so Esc/arrows/Enter are swallowed before WebContents.
  std::vector<ui::Accelerator> switcher_accelerators_;
  // Suppresses a duplicate FocusManager accelerator fired on the same keypress
  // already handled by OnEvent() while the tab switcher was active.
  ui::KeyboardCode suppressed_switcher_key_ = ui::VKEY_UNKNOWN;
  // Double-press tracking for app-wide "website" shortcut priority when a
  // command has no explicit per-command priority override.
  std::optional<KeyboardShortcut> last_global_site_shortcut_;
  TimestampSec last_global_site_press_at_ = 0.0;

  base::WeakPtrFactory<OpenWindowUi> weak_factory_{this};
};

// One Little Open window (Arc's "Little Arc"): Track 5's OpenLittleOpenWindow
// in bar mode (an OpenCommandBarView in CommandBarMode::kLittleOpen) or page
// mode (a live WebContents owned by OpenLittleOpenView for zero-reload
// promotion). "Open in <Space>" (pill, Cmd/Ctrl+O, Space picker) transfers
// the live WebContents into a Today tab of that Space via
// OpenTabBridge::AdoptLiveWebContentsAsTab and closes Little Open.
class OpenLittleOpenController
    : public LittleOpenDelegate,
      public CommandBarDelegate,
      public content::WebContentsObserver,
      public content::WebContentsDelegate,
      public web_modal::WebContentsModalDialogManagerDelegate,
      public web_modal::WebContentsModalDialogHost {
 public:
  OpenLittleOpenController(OpenWindowController* owner,
                           ProfileID profile_id,
                           std::optional<SpaceID> target_space);
  ~OpenLittleOpenController() override;

  OpenLittleOpenController(const OpenLittleOpenController&) = delete;
  OpenLittleOpenController& operator=(const OpenLittleOpenController&) =
      delete;

  // Creates and shows the window: the bar when |url| is empty, else the
  // page loading |url|. False when the window could not be created.
  bool Show(const std::optional<GURL>& url);
  // Loads |url| in the page (creating it) and switches to page mode.
  void Navigate(const GURL& url);
  // Closes the window; OnLittleOpenClosed() follows on a later task.
  void Close();

  bool is_page() const;
  bool closing() const { return closing_; }
  content::WebContents* page() const { return contents_; }
  const ProfileID& profile_id() const { return profile_id_; }
  views::Widget* widget() const { return window_ ? window_->widget() : nullptr; }
  void RefreshState();
  // Automation readback (docs/automation.md little-open-state).
  base::DictValue State() const;

  // LittleOpenDelegate:
  void OnLittleOpenOpenInSpace(std::optional<SpaceID> space_id) override;
  void OnLittleOpenEditUrl() override;
  void OnLittleOpenCopyUrl() override;
  void OnLittleOpenProfile(views::View* anchor) override;
  void OnLittleOpenExtensions(views::View* anchor) override;
  void OnLittleOpenClosed() override;
  void OnLittleOpenProfileSelected(const ProfileID& profile_id) override;
  void OnLittleOpenTargetSpaceChanged(const SpaceID& space_id) override;
  void OnLittleOpenDownloads(views::View* anchor) override;
  void OnLittleOpenExtensionAction(const std::string& extension_id,
                                   views::View* anchor) override;
  void OnLittleOpenArchiveOnClose(const GURL& url,
                                  const std::u16string& title,
                                  const ProfileID& profile_id) override;

  // CommandBarDelegate (the embedded bar):
  CommandBarResults QuerySuggestions(const CommandBarQuery& query) override;
  std::optional<CommandBarScopeTarget> ResolveSiteSearch(
      std::u16string_view text,
      bool exact_keyword_only) override;
  void OnCommandBarIntent(const CommandBarIntent& intent) override;
  void OnCommandBarDismissed(CommandBarDismissReason reason,
                             std::optional<gfx::Point> click_location) override;
  void OnCommandBarRemoteQuery(const CommandBarQuery& query) override;
  void OnCommandBarOpenSearchSettings() override;

  // content::WebContentsObserver:
  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override;
  void WebContentsDestroyed() override;

  // content::WebContentsDelegate:
  bool HandleKeyboardEvent(content::WebContents* source,
                           const input::NativeWebKeyboardEvent& event) override;
  content::JavaScriptDialogManager* GetJavaScriptDialogManager(
      content::WebContents* source) override;

  // web_modal::WebContentsModalDialogManagerDelegate:
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost(
      content::WebContents* web_contents) override;
  bool IsWebContentsVisible(content::WebContents* web_contents) override;

  // web_modal::WebContentsModalDialogHost:
  gfx::NativeView GetHostView() const override;
  gfx::Point GetDialogPosition(const gfx::Size& size) override;
  gfx::Size GetMaximumDialogSize() override;
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override;
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override;

 private:
  OpenBrowserService* service() const;
  OpenExtensionBridge* ExtensionBridge() const;
  ExtensionHostWindow MakeExtensionHostWindow() const;
  // The Space "Open in" targets: the routed one, else the main window's
  // focused Space of this Profile, else any Space of this Profile.
  std::optional<SpaceID> DefaultTargetSpace() const;
  gfx::Rect WorkArea() const;
  void EnterBarMode(const std::u16string& initial_text);
  void EnterPageMode();
  void UpdateState();
  void HandleDownloadPopoverAction(DownloadPopoverAction action,
                                   const std::string& download_id);
  void AttachExtensionWindow();
  void DetachExtensionWindow();

  raw_ptr<OpenWindowController> owner_;
  ProfileID profile_id_;
  std::optional<SpaceID> target_space_;
  std::unique_ptr<OpenLittleOpenWindow> window_;
  raw_ptr<OpenCommandBarView> bar_ = nullptr;
  // Non-owning pointer to the live WebContents owned by OpenLittleOpenView.
  raw_ptr<content::WebContents> contents_ = nullptr;
  std::unique_ptr<OpenDownloadsPopover> downloads_popover_;
  uint64_t remote_suggest_request_id_ = 0;
  bool extension_window_attached_ = false;
  // Page bounds kept while the bar edits the URL (host click).
  std::optional<gfx::Rect> page_bounds_;
  views::UnhandledKeyboardEventHandler unhandled_keyboard_event_handler_;
  base::ObserverList<web_modal::ModalDialogHostObserver> modal_observers_;
  bool closing_ = false;
  base::WeakPtrFactory<OpenLittleOpenController> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_WINDOW_CONTROLLER_H_
