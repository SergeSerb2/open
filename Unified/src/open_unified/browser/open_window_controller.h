// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_WINDOW_CONTROLLER_H_
#define OPEN_UNIFIED_BROWSER_OPEN_WINDOW_CONTROLLER_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/scoped_observation.h"
#include "base/values.h"
#include "components/find_in_page/find_result_observer.h"
#include "components/find_in_page/find_tab_helper.h"
#include "content/public/browser/web_contents_observer.h"
#include "open_unified/browser/open_extension_bridge.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/ui/views/open_browser_view.h"
#include "open_unified/ui/views/open_command_bar_view.h"
#include "open_unified/ui/views/open_find_bar_and_toasts.h"
#include "open_unified/ui/views/open_little_open_view.h"
#include "open_unified/ui/views/open_peek_overlay_view.h"
#include "open_unified/ui/views/open_site_control_bubble.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/events/event_observer.h"
#include "ui/views/view_observer.h"

class BrowserView;
class GURL;

namespace content {
class WebContents;
}

namespace views {
class EventMonitor;
}

namespace open_unified {

class OpenBrowserService;
class OpenLittleOpenController;
class OpenWindowUi;

// The browser side of Open's views:
//
// - implements Track 4's OpenViewController (model reads, ~40 intents,
//   observer fan-out) for every OpenBrowserView, and
// - owns one OpenWindowUi per installed window, which creates Track 5's
//   secondary views (Command Bar, Peek, Split container, Site Control,
//   Find bar, Toasts, Ctrl+Tab switcher) and implements their delegates,
// - owns the floating Little Open windows (OpenLittleOpenController).
//
// UI thread only. Owned by OpenBrowserService.
class OpenWindowController : public OpenViewController,
                             public BrowserModel::Observer,
                             public OpenTabBridge::Observer,
                             public OpenExtensionBridge::Observer {
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
  bool IsIncognitoWindow(const WindowID& window_id) const override;
  std::optional<ItemID> GetPeekSourceNode(
      const WindowID& window_id) const override;
  bool IsNewTabCommandBarOpen(const WindowID& window_id) const override;
  std::vector<OpenToolbarActionInfo> GetPinnedToolbarActions(
      const WindowID& window_id) const override;
  void HandleIntent(const WindowID& window_id,
                    const OpenIntent& intent) override;
  void AddViewObserver(OpenViewObserver* observer) override;
  void RemoveViewObserver(OpenViewObserver* observer) override;

  // BrowserModel::Observer:
  void OnTreeChanged(const TreeChange& change) override;
  // OpenTabBridge::Observer:
  void OnTabActivated(const ItemID& tab_id) override;
  void OnTabContentsAttached(const ItemID& tab_id,
                             content::WebContents* contents) override;
  // OpenExtensionBridge::Observer:
  void OnExtensionActionsChanged() override;

  OpenBrowserService* service() { return service_; }
  content::WebContents* ActiveWebContents() const;

 private:
  void NotifyWindowStateChanged();
  void NavigateActive(int direction);  // -1 back, +1 forward, 0 reload

  // Undo of a "Tab Archived" toast: takes the rows out of Archive.sqlite
  // and puts the tabs back where they were.
  void RestoreArchived(std::vector<ArchivedTabRecord> records);

  raw_ptr<OpenBrowserService> service_;
  bool started_ = false;
  std::map<raw_ptr<BrowserView>, std::unique_ptr<OpenWindowUi>> windows_;
  std::vector<std::unique_ptr<OpenLittleOpenController>> little_opens_;
  base::ObserverList<OpenViewObserver> view_observers_;
  base::WeakPtrFactory<OpenWindowController> weak_factory_{this};
};

// One Open window's Track 5 views and their delegates.
//
// Find bar, Toasts and the Ctrl+Tab switcher live in their own
// secondary::OverlayWidgetHost child widgets (created on first use, so a
// window that never finds or toasts pays nothing), above the page's native
// view. Their anchors follow the web panel through an empty view in
// OpenBrowserView's kFindBarAndToasts slot, which Track 4 lays out to the
// panel's bounds.
class OpenWindowUi : public CommandBarDelegate,
                     public PeekDelegate,
                     public SiteControlDelegate,
                     public OpenSplitContainerDelegate,
                     public FindBarDelegate,
                     public TabSwitcherDelegate,
                     public ui::AcceleratorTarget,
                     public views::ViewObserver,
                     public find_in_page::FindResultObserver,
                     public ui::EventObserver {
 public:
  OpenWindowUi(OpenWindowController* controller,
               BrowserView* browser_view,
               OpenBrowserView* open_view,
               WindowID window_id);
  ~OpenWindowUi() override;

  OpenWindowUi(const OpenWindowUi&) = delete;
  OpenWindowUi& operator=(const OpenWindowUi&) = delete;

  const WindowID& window_id() const { return window_id_; }

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

  // Peek: a page over the window (80% card, 0.70 scrim).
  void OpenPeek(const GURL& url, const std::optional<ItemID>& source_node);
  void ExpandPeek();
  void ClosePeek();
  bool peek_shown() const;
  std::optional<ItemID> peek_source() const { return peek_source_; }

  // Site Control bubble anchored to the URL pill (or a pane button).
  void ShowSiteControls(views::View* anchor);
  void HideSiteControls();
  bool site_controls_shown() const;

  // Split View: re-presents the selected node (single page or 2..4 panes).
  void UpdatePanel();
  bool split_active() const { return split_active_; }

  // Find in page (Cmd/Ctrl+F, Cmd/Ctrl+G, Shift+Cmd/Ctrl+G, Esc). The bar
  // is seeded with |query|, else the page's selection (40 characters), else
  // the previous query of the page.
  void ShowFindBar(std::optional<std::u16string> query = std::nullopt);
  void FindNext(bool forward);
  void CloseFindBar();
  bool find_bar_shown() const;

  // Toasts at the top-right of the web panel.
  void ShowToast(ToastSpec spec);

  // Ctrl+Tab / Ctrl+Shift+Tab: MRU switcher (first press begins, further
  // presses advance; Ctrl release commits).
  void TabSwitcherStep(bool reverse);
  void TabSwitcherCommit();
  void TabSwitcherCancel();
  bool tab_switcher_active() const;

  // Model and bridge notifications from OpenWindowController.
  void OnTabActivated(const ItemID& tab_id);
  void OnModelChanged();

  // Registers Open's window accelerators on the window's FocusManager at
  // high priority (ahead of Chromium's table and of the page).
  void RegisterAccelerators();
  void ActivateWindow();
  views::Widget* widget() const;
  // Runs a CommandRegistry action (command bar rows, Little Open).
  void RunCommand(const std::string& action_id) { RunAction(action_id); }

  // Automation readback (docs/automation.md command-bar-state, peek-state,
  // site-controls state).
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

  // PeekDelegate:
  void OnPeekDismissed(PeekDismissReason reason) override;
  void OnPeekExpandToTab() override;
  void OnPeekOpenInSplit() override;

  // SiteControlDelegate:
  void OnSiteControlAction(SiteControlAction action) override;
  void OnSiteControlExtensionPressed(const std::string& extension_id,
                                     views::View* anchor) override;
  void OnSiteControlPermissionChanged(SitePermissionKind kind,
                                      SitePermissionSetting setting) override;
  void OnSiteControlAdBlockToggled(bool enabled) override;
  void OnSiteControlClosed() override;

  // OpenSplitContainerDelegate:
  void OnSplitFractionsCommitted(const ItemID& split_id,
                                 const std::vector<double>& fractions) override;
  void OnPaneFocusRequested(const std::optional<ItemID>& split_id,
                            const ItemID& tab_id) override;
  bool OnPaneCommand(const std::optional<ItemID>& split_id,
                     const ItemID& tab_id,
                     PaneCommand command,
                     views::View* anchor) override;

  // FindBarDelegate:
  void OnFindQueryChanged(const std::u16string& query) override;
  void OnFindNext(bool forward) override;
  void OnFindClosed() override;

  // TabSwitcherDelegate:
  void OnTabSwitcherVisibilityChanged(bool visible) override;
  void OnTabSwitcherCommit(const ItemID& tab_id) override;
  void OnTabSwitcherCancel() override;

  // ui::AcceleratorTarget:
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override;
  bool CanHandleAccelerators() const override;

  // views::ViewObserver (the panel tracker in kFindBarAndToasts):
  void OnViewBoundsChanged(views::View* observed_view) override;
  void OnViewIsDeleting(views::View* observed_view) override;

  // find_in_page::FindResultObserver:
  void OnFindResultAvailable(content::WebContents* web_contents) override;
  void OnFindTabHelperDestroyed(find_in_page::FindTabHelper* helper) override;

  // ui::EventObserver (key releases while the switcher is active):
  void OnEvent(const ui::Event& event) override;

 private:
  secondary::Appearance CurrentAppearance() const;
  open_unified::SiteControlState BuildSiteControlState() const;
  void OpenUrlWithDisposition(const GURL& url,
                              CommandBarDisposition disposition);
  void RunAction(const std::string& action_id);
  void CopyUrl(const GURL& url);
  OpenBrowserService* service() const;

  // Overlay widgets (lazy) and their anchors in widget coordinates.
  gfx::Rect PanelRectInWidget() const;
  gfx::Rect WindowRectInWidget() const;
  void EnsureFindBar();
  void EnsureToasts();
  void EnsureTabSwitcher();
  void UpdateOverlayAnchors();
  find_in_page::FindTabHelper* FindHelper() const;
  void SetEscapeRegistered(bool registered);
  bool RunShortcut(CommandId command);
  std::vector<TabSwitcherItem> BuildSwitcherItems() const;
  void StopSwitcherMonitor();
  void FocusPage();

  raw_ptr<OpenWindowController> controller_;
  raw_ptr<BrowserView> browser_view_;
  raw_ptr<OpenBrowserView> open_view_;
  WindowID window_id_;

  raw_ptr<OpenCommandBarView> command_bar_ = nullptr;
  raw_ptr<OpenPeekOverlayView> peek_ = nullptr;
  raw_ptr<OpenSplitContainerView> split_ = nullptr;
  std::unique_ptr<OpenSiteControlBubble> site_controls_;
  CommandBarMode command_bar_mode_ = CommandBarMode::kNewTab;

  std::unique_ptr<content::WebContents> peek_contents_;
  std::optional<ItemID> peek_source_;
  bool split_active_ = false;

  // Panel tracker (kFindBarAndToasts slot): its bounds are the panel's.
  raw_ptr<views::View> panel_tracker_ = nullptr;
  base::ScopedObservation<views::View, views::ViewObserver>
      panel_observation_{this};

  // Find bar.
  std::unique_ptr<secondary::OverlayWidgetHost> find_host_;
  raw_ptr<OpenFindBarView> find_bar_ = nullptr;
  base::ScopedObservation<find_in_page::FindTabHelper,
                          find_in_page::FindResultObserver>
      find_observation_{this};
  bool escape_registered_ = false;

  // Toasts.
  std::unique_ptr<secondary::OverlayWidgetHost> toast_host_;
  raw_ptr<OpenToastStackView> toasts_ = nullptr;

  // Ctrl+Tab switcher: MRU order of this window's tabs (newest first).
  std::unique_ptr<secondary::OverlayWidgetHost> switcher_host_;
  raw_ptr<OpenTabSwitcherView> switcher_ = nullptr;
  std::unique_ptr<views::EventMonitor> switcher_monitor_;
  std::vector<ItemID> mru_;

  // Space Switched toast: the focused Space last seen.
  std::optional<SpaceID> last_focused_space_;

  // Registered accelerators -> Open command.
  std::map<ui::Accelerator, CommandId> accelerator_commands_;

  base::WeakPtrFactory<OpenWindowUi> weak_factory_{this};
};

// One Little Open window (Arc's "Little Arc"): Track 5's OpenLittleOpenWindow
// in bar mode (an OpenCommandBarView in CommandBarMode::kLittleOpen) or page
// mode (a live WebContents this object owns). "Open in <Space>" (pill,
// Cmd/Ctrl+O, Space picker) turns the page into a Today tab of that Space and
// closes the window. Owned by OpenWindowController; UI thread only.
class OpenLittleOpenController : public LittleOpenDelegate,
                                 public CommandBarDelegate,
                                 public content::WebContentsObserver {
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
  content::WebContents* page() const { return contents_.get(); }
  const ProfileID& profile_id() const { return profile_id_; }
  // Automation readback (docs/automation.md little-open-state).
  base::DictValue State() const;

  // LittleOpenDelegate:
  void OnLittleOpenOpenInSpace(std::optional<SpaceID> space_id) override;
  void OnLittleOpenEditUrl() override;
  void OnLittleOpenCopyUrl() override;
  void OnLittleOpenProfile(views::View* anchor) override;
  void OnLittleOpenExtensions(views::View* anchor) override;
  void OnLittleOpenClosed() override;

  // CommandBarDelegate (the embedded bar):
  CommandBarResults QuerySuggestions(const CommandBarQuery& query) override;
  std::optional<CommandBarScopeTarget> ResolveSiteSearch(
      std::u16string_view text,
      bool exact_keyword_only) override;
  void OnCommandBarIntent(const CommandBarIntent& intent) override;
  void OnCommandBarDismissed(CommandBarDismissReason reason,
                             std::optional<gfx::Point> click_location) override;

  // content::WebContentsObserver:
  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override;

 private:
  OpenBrowserService* service() const;
  // The Space "Open in" targets: the routed one, else the main window's
  // focused Space of this Profile, else any Space of this Profile.
  std::optional<SpaceID> DefaultTargetSpace() const;
  gfx::Rect WorkArea() const;
  void EnterBarMode(const std::u16string& initial_text);
  void EnterPageMode();
  void UpdateState();

  raw_ptr<OpenWindowController> owner_;
  const ProfileID profile_id_;
  const std::optional<SpaceID> target_space_;
  std::unique_ptr<OpenLittleOpenWindow> window_;
  raw_ptr<OpenCommandBarView> bar_ = nullptr;
  std::unique_ptr<content::WebContents> contents_;
  // Page bounds kept while the bar edits the URL (host click).
  std::optional<gfx::Rect> page_bounds_;
  bool closing_ = false;
  base::WeakPtrFactory<OpenLittleOpenController> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_WINDOW_CONTROLLER_H_
