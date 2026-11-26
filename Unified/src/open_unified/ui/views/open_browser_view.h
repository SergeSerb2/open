// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenBrowserView: the root client-area view of an Open browser window,
// built on Chromium Views. It owns:
//
//  - the full-window ThemeBackgroundView (OKLab 64 x 64 field + texture),
//    drawn under the 10 pt frame inset and the sidebar, with the 0.21 s
//    linear cross-fade between Spaces;
//  - the anchored OpenSidebarView (164..500 pt, default 228) with its resize
//    sash and the Cmd/Ctrl+S spring slide (R 0.10 s, zeta 0.95);
//  - the hover-reveal floating sidebar card while the sidebar is hidden;
//  - the web panel: a 6 pt rounded clip with its shadow, hosting either the
//    single web contents view or Track 5's OpenSplitContainerView;
//  - overlay slots for Track 5 (Command Bar, Peek, Find bar + Toasts).
//
// It never edits the model. Reads and intents go through OpenViewController,
// which Track 6's OpenBrowserService implements.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_BROWSER_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_BROWSER_VIEW_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/callback_list.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/observer_list_types.h"
#include "base/scoped_observation.h"
#include "base/timer/timer.h"
#include "build/build_config.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/design/open_motion.h"
#include "open_unified/ui/design/open_theme_math.h"
#include "open_unified/ui/views/open_tab_tree_view.h"
#include "ui/base/class_property.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget_observer.h"

class BrowserView;  // //chrome/browser/ui/views/frame/browser_view.h

namespace ui {
class Event;
class MenuModel;
}  // namespace ui

namespace views {
class EventMonitor;
class MenuRunner;
class NativeViewHost;
}  // namespace views

namespace open_unified {

class OpenSidebarView;

// ---------------------------------------------------------------------------
// Intents: everything the hot-path views ask the browser to do.

enum class OpenIntentKind {
  // Window and toolbar.
  kToggleSidebar,
  kSidebarHiddenByGesture,
  kSetSidebarWidth,  // value = width (commit on release / double-click)
  kGoBack,
  kGoForward,
  kReload,
  kStopLoading,
  kShowToolbarMore,     // compact toolbar "More options"
  kOpenCommandBar,      // command_bar_source, anchor_in_screen
  kCopyCurrentUrl,
  kShowSiteControls,    // anchor_in_screen
  kRunToolbarAction,    // text = extension action id, anchor_in_screen
  // Spaces, Library, creation.
  kSelectNode,          // node_id, space_id, secondary_id = split pane
  kSelectFavorite,      // node_id = favorite tab id
  kSwitchSpace,         // space_id
  kShowLibrary,
  kNewSpace,
  kNewFolder,           // parent
  kNewEasel,
  kNewNote,
  kSetPinnedCollapsed,  // space_id, flag
  kClearToday,          // space_id
  kRenameSpace,         // space_id, text
  kEditSpaceTheme,      // space_id
  kChangeSpaceIcon,     // space_id
  // Rows.
  kClose,               // node_id
  kUnloadTab,           // node_id
  kUnloadFolder,        // node_id
  kToggleMute,          // node_id
  kResetToPinnedUrl,    // node_id
  kRename,              // node_id, text
  kSetFolderExpanded,   // node_id, flag
  kMove,                // node_id, parent, index (nullopt = append)
  kAddFavorite,         // node_id, index
  kMoveFavorite,        // node_id, index
  kRemoveFavorite,      // node_id
  kOpenUrl,             // text = URL, parent, index
};

enum class CommandBarSource { kUrlField, kNewTabRow, kPlusButton };

struct OpenIntent {
  OpenIntentKind kind = OpenIntentKind::kToggleSidebar;
  ItemID node_id;
  ItemID secondary_id;
  SpaceID space_id;
  NodeParent parent;
  std::optional<size_t> index;
  std::string text;
  bool flag = false;
  double value = 0;
  CommandBarSource command_bar_source = CommandBarSource::kUrlField;
  std::optional<gfx::Rect> anchor_in_screen;

  static OpenIntent Of(OpenIntentKind kind);
  static OpenIntent ForNode(OpenIntentKind kind, const ItemID& node_id);
  static OpenIntent ForSpace(OpenIntentKind kind, const SpaceID& space_id);
  static OpenIntent Select(const ItemID& node_id,
                           const SpaceID& space_id,
                           const ItemID& pane_id = ItemID());
  static OpenIntent Move(const ItemID& node_id,
                         const NodeParent& parent,
                         std::optional<size_t> index);
  static OpenIntent CommandBar(CommandBarSource source,
                               std::optional<gfx::Rect> anchor);
};

// What a context menu is for. The controller builds the ui::MenuModel.
struct OpenMenuTarget {
  enum class Kind {
    kNode,          // node_id, space_id
    kFavorite,      // node_id, profile_id
    kSpace,         // space_id (header title, "..." button, empty list)
    kSwitcherItem,  // space_id
    kPlusButton,    // space_id (falls back to Open's default plus menu)
    kToolbarMore,
    kUrlField,       // URL pill right-click (Copy URL, Site Controls, ...)
    kToolbarAction,  // text = action id
    kLibrary,        // bottom-bar Library button right-click (media sources)
  };
  Kind kind = Kind::kNode;
  ItemID node_id;
  SpaceID space_id;
  ProfileID profile_id;
  std::string text;
};

// A pinned extension action shown in the URL pill.
struct OpenToolbarActionInfo {
  std::string id;
  std::u16string tooltip;
  gfx::ImageSkia icon;
  bool has_badge = false;
};

// ---------------------------------------------------------------------------
// Model notifications the views need. All on the UI thread.

class OpenViewObserver : public base::CheckedObserver {
 public:
  virtual void OnTreeChanged(const TreeChange& change) {}
  // Spaces added, removed, reordered, renamed or re-iconed.
  virtual void OnSpacesChanged(const WindowID& window_id) {}
  virtual void OnSpaceThemeChanged(const SpaceID& space_id) {}
  virtual void OnFavoritesChanged(const ProfileID& profile_id) {}
  // Focused Space, selection, sidebar width or mode.
  virtual void OnWindowStateChanged(const WindowID& window_id) {}
  // Loading, audio, favicon, sleep phase, navigation state.
  virtual void OnTabLiveStateChanged(const ItemID& tab_id) {}
  // The focused page (or pane) changed: URL pill, nav buttons.
  virtual void OnActiveTabChanged(const WindowID& window_id) {}
  virtual void OnSplitViewChanged(const WindowID& window_id) {}
  virtual void OnPeekChanged(const WindowID& window_id) {}
  virtual void OnCommandBarStateChanged(const WindowID& window_id) {}
  virtual void OnToolbarActionsChanged(const WindowID& window_id) {}
  virtual void OnSystemAppearanceChanged() {}

 protected:
  ~OpenViewObserver() override = default;
};

// ---------------------------------------------------------------------------
// The browser side of the views. Track 6's OpenBrowserService implements it.
// Pointers returned by the read methods stay valid until the next
// notification for that object.

class OpenViewController {
 public:
  virtual ~OpenViewController() = default;

  // --- Model reads ------------------------------------------------------------
  virtual const BrowserWindowState* GetWindowState(
      const WindowID& window_id) const = 0;
  // Spaces shown in this window's switcher, in order.
  virtual std::vector<SpaceID> GetWindowSpaceIds(
      const WindowID& window_id) const = 0;
  virtual const Space* GetSpace(const SpaceID& space_id) const = 0;
  virtual const Profile* GetProfile(const ProfileID& profile_id) const = 0;
  virtual const SidebarNode* FindNode(const ItemID& node_id) const = 0;
  // The focused page (the focused pane in Split View, the Peek page while
  // Peek shows). Null for an empty window.
  virtual const Tab* GetActiveTab(const WindowID& window_id) const = 0;
  virtual bool IsSplitViewActive(const WindowID& window_id) const = 0;
  virtual bool IsSystemDarkMode() const = 0;
  // Hook 0002: the model window for a Chromium BrowserView (created on
  // first use).
  virtual WindowID WindowIdForBrowserView(BrowserView* browser_view) = 0;

  // --- Optional state --------------------------------------------------------
  virtual bool IsIncreaseContrastEnabled() const;
  virtual bool IsIncognitoWindow(const WindowID& window_id) const;
  virtual std::optional<ItemID> GetPeekSourceNode(
      const WindowID& window_id) const;
  virtual bool IsNewTabCommandBarOpen(const WindowID& window_id) const;
  virtual std::vector<OpenToolbarActionInfo> GetPinnedToolbarActions(
      const WindowID& window_id) const;
  // Favicon from the FaviconStore; empty to fall back to the tab's PNG.
  virtual gfx::ImageSkia GetFavicon(const ItemID& tab_id) const;
  virtual bool IsDeveloperModeEnabled() const;

  // --- Intents and menus ---------------------------------------------------
  virtual void HandleIntent(const WindowID& window_id,
                            const OpenIntent& intent) = 0;
  // Null: no menu (the plus button then shows Open's default menu).
  virtual std::unique_ptr<ui::MenuModel> CreateMenuModel(
      const WindowID& window_id,
      const OpenMenuTarget& target);

  // --- Observation ----------------------------------------------------------------
  virtual void AddViewObserver(OpenViewObserver* observer) = 0;
  virtual void RemoveViewObserver(OpenViewObserver* observer) = 0;
};

// Optional interface for panel content (Track 5's OpenSplitContainerView).
// During the Cmd/Ctrl+S slide the panel's clip changes every frame, but web
// content must not resize per frame: the client keeps its pages at
// `stable_content_size` (e.g. NativeViewHost::SetNativeViewSize) until
// OnPanelSlideEnd, then takes the final bounds once.
class OpenPanelSlideClient {
 public:
  virtual void OnPanelSlideBegin(const gfx::Size& stable_content_size) = 0;
  virtual void OnPanelSlideEnd() = 0;

 protected:
  virtual ~OpenPanelSlideClient() = default;
};

// Views under this key (default false) are window-drag regions when they
// receive the hit: toolbar and bottom-bar backgrounds, the frame inset.
extern const ui::ClassProperty<bool>* const kOpenWindowDragKey;

// ---------------------------------------------------------------------------

class OpenBrowserView : public views::View,
                        public OpenSidebarContext,
                        public OpenViewObserver,
                        public views::WidgetObserver {
  METADATA_HEADER(OpenBrowserView, views::View)

 public:
  // Track 5 composes into these slots.
  enum class OverlaySlot {
    kCommandBar,        // laid out over the whole window (Arc centers it)
    kPeek,              // whole window
    kFindBarAndToasts,  // the web panel's bounds (top-right anchored)
  };

  enum class WindowControls {
    kNativeMac,  // macOS system traffic lights; the sidebar reserves x 0..77
    kNone,       // Windows / Linux: no window controls in the sidebar
  };

  // Native traffic-light placement for the macOS adapter: `origin` is the
  // close button frame origin in window coordinates; called every frame of
  // the sidebar slide and card motion.
  using TrafficLightsCallback =
      base::RepeatingCallback<void(const gfx::Point& origin, bool visible)>;

  OpenBrowserView(OpenViewController* controller, const WindowID& window_id);
  OpenBrowserView(const OpenBrowserView&) = delete;

  // --- Chromium integration (hook 0002, browser/INTEGRATION.md) -------------
  // End of BrowserView::AddedToWidget() for TYPE_NORMAL browsers: covers
  // |browser_view| with Open's chrome, hides Chromium's top container and
  // hosts BrowserView's contents container in the web panel. Owned by the
  // views hierarchy. OpenBrowserService passes itself (it implements
  // OpenViewController). BrowserViewLayout must skip top_container() and
  // contents_container() while FromBrowserView() is non-null (patch 0002).
  static void Install(BrowserView* browser_view, OpenViewController* controller);
  // Start of BrowserView::~BrowserView(): gives the contents container back
  // to BrowserView, then removes Open's chrome.
  static void Uninstall(BrowserView* browser_view);
  static OpenBrowserView* FromBrowserView(BrowserView* browser_view);
  // BrowserWidget::InitBrowserWidget(): Open draws its own frame inset and
  // rounded corners on every platform (macOS keeps the traffic lights).
  static bool WantsFramelessWindow();
  views::View* sidebar_view();
  OpenBrowserView& operator=(const OpenBrowserView&) = delete;
  ~OpenBrowserView() override;

  const WindowID& window_id() const override;
  OpenViewController* controller() const override;

  // --- Panel slots -----------------------------------------------------------------
  // Single-pane web contents host (e.g. a views::WebView). Gets 6 pt corner
  // radii on its NativeViewHost when it is a views::WebView.
  views::View* SetWebContentsHost(std::unique_ptr<views::View> host);
  views::View* web_contents_host() const { return web_contents_host_; }
  // Track 5's OpenSplitContainerView; shown instead of the single host while
  // Split View is active.
  views::View* SetSplitContainer(std::unique_ptr<views::View> container,
                                 OpenPanelSlideClient* slide_client = nullptr);
  views::View* split_container() const { return split_container_; }
  void SetSplitViewActive(bool active);
  bool split_view_active() const { return split_view_active_; }

  // --- Overlay slots ---------------------------------------------------------------
  views::View* SetOverlay(OverlaySlot slot, std::unique_ptr<views::View> view);
  views::View* GetOverlay(OverlaySlot slot) const;
  // Anchors for bubbles and the inline Command Bar.
  views::View* GetUrlPillView() const;
  views::View* GetSiteControlAnchorView() const;
  gfx::Rect GetPanelBounds() const;    // this view's coordinates
  gfx::Rect GetSidebarBounds() const;  // anchored or card
  OpenSidebarView* sidebar() const { return sidebar_; }

  // --- Sidebar ------------------------------------------------------------------------
  // Sends kToggleSidebar; the model change animates it (OnWindowStateChanged).
  void RequestToggleSidebar();
  // Applies a mode directly (used by the controller-less automation path).
  void SetSidebarHidden(bool hidden, bool animate);
  bool sidebar_hidden() const { return sidebar_hidden_; }
  float sidebar_width() const { return sidebar_width_; }
  bool IsRevealCardShown() const;

  // --- Theme ---------------------------------------------------------------------------
  const OpenSpaceThemeState& FocusedThemeState();

  // --- Frame ---------------------------------------------------------------------------
  // HTCAPTION / HTCLIENT / resize codes for a point in this view. Track 6's
  // frame view forwards its NonClientHitTest here.
  int NonClientHitTest(const gfx::Point& point) const;
  void SetWindowControls(WindowControls controls);
  WindowControls window_controls() const { return window_controls_; }
  void SetTrafficLightsCallback(TrafficLightsCallback callback);
  // Linux translucent frameless windows clip to the 16 pt window corner.
  void SetClipsWindowCorners(bool clips);

  // --- Tab (HTML5) fullscreen ---------------------------------------------------
  // While a page is fullscreen (video, requestFullscreen), the web panel
  // fills the whole window full-bleed: no sidebar, no traffic lights, no
  // 10 pt inset, corner radius or shadow. Layout() also derives it from
  // BrowserView::IsFullscreen() and the active WebContents, so callers that
  // observe FullscreenController only need to call this to force a relayout.
  void SetTabFullscreen(bool fullscreen);
  bool IsTabFullscreen() const;

  // macOS: the native behind-window material shows under the theme tint.
  bool translucent_window() const { return translucent_window_; }

  // --- OpenSidebarContext ----------------------------------------------------------
  const OpenSpaceThemeState& ThemeStateFor(const SpaceID& space_id) override;
  SpaceID FocusedSpaceId() const override;
  bool IsWindowActive() const override;
  float SidebarWidth() const override;
  void Send(const OpenIntent& intent) override;
  void ShowSidebarMenu(const OpenMenuTarget& target,
                       views::View* source,
                       const gfx::Point& screen_point,
                       ui::mojom::MenuSourceType source_type) override;
  gfx::ImageSkia FaviconFor(const Tab& tab) override;
  void BeginThemeTransition(const SpaceID& to) override;
  void SetThemeTransitionProgress(double progress) override;
  void EndThemeTransition(bool commit) override;
  void CrossfadeTheme(const SpaceID& to, bool animated) override;
  ui::Compositor* AnimationCompositor() override;
  bool AnimationsEnabled() const override;

  // --- OpenViewObserver -----------------------------------------------------------------
  void OnTreeChanged(const TreeChange& change) override;
  void OnSpacesChanged(const WindowID& window_id) override;
  void OnSpaceThemeChanged(const SpaceID& space_id) override;
  void OnFavoritesChanged(const ProfileID& profile_id) override;
  void OnWindowStateChanged(const WindowID& window_id) override;
  void OnTabLiveStateChanged(const ItemID& tab_id) override;
  void OnActiveTabChanged(const WindowID& window_id) override;
  void OnSplitViewChanged(const WindowID& window_id) override;
  void OnPeekChanged(const WindowID& window_id) override;
  void OnCommandBarStateChanged(const WindowID& window_id) override;
  void OnToolbarActionsChanged(const WindowID& window_id) override;
  void OnSystemAppearanceChanged() override;

  // --- views::View --------------------------------------------------------------------
  void Layout(PassKey) override;
  void AddedToWidget() override;
  void RemovedFromWidget() override;
  void OnThemeChanged() override;

  // --- views::WidgetObserver ---------------------------------------------------------
  // Kept for API compatibility; the active look follows
  // Widget::ShouldPaintAsActive() (OnPaintAsActiveChanged), so a Command Bar
  // or Find bar child window never paints the browser window inactive.
  void OnWidgetActivationChanged(views::Widget* widget, bool active) override;
  void OnWidgetVisibilityChanged(views::Widget* widget, bool visible) override;
  void OnWidgetDestroying(views::Widget* widget) override;

 private:
  class ThemeBackgroundView;
  class PanelShadowView;
  class PanelHostView;
  class ResizeHandle;
  class RevealCardView;
  class RevealObserver;
  class PlusMenuDelegate;
  class BrowserViewTracker;
  friend class ResizeHandle;
  friend class RevealObserver;

  enum class CardState { kOff, kShowing, kShown, kHiding };

  // Layout helpers.
  gfx::Rect PanelBoundsFor(bool sidebar_hidden, float sidebar_width) const;
  void LayoutPanel(const gfx::Rect& panel);
  gfx::Rect RevealCardBounds() const;
  void LayoutOverlays();
  void UpdatePanelChildren();
  void ApplySidebarOffset(double offset);
  void ApplyPanelSlide(double progress);
  void NotifyTrafficLights();
  // Window active look (theme, card, sidebar, traffic-light rings).
  void OnPaintAsActiveChanged();
  // Tab fullscreen: full-bleed panel on enter, Open's frame on exit.
  void ApplyTabFullscreen(bool fullscreen);
  // Empty Space: no active tab hides Chromium's contents container so the
  // empty-panel canvas shows (never a raw blank page or NTP).
  bool HasActiveTab() const;
  // macOS live window material (OpenPlatform::UpdateWindowEffects).
  void UpdateWindowMaterial();
  // Drops Chromium's opaque frame paint so the material shows through.
  void EnableTranslucentChrome();

  // Sidebar mode and width.
  void SyncFromWindowState(bool animate);
  void AnimateSidebar(bool hidden);
  void OnSidebarSlideSettled();
  void SetLiveSidebarWidth(float width);
  void BeginPanelSlide(const gfx::Size& stable_content_size);
  void EndPanelSlide();
  void ReparentSidebar(bool into_card);
  views::NativeViewHost* ActiveWebHolder() const;
  void ApplyWebCornerRadii();
  void OnResizeDrag(float proposed_width, bool released);
  void OnResizeDoubleClick();

  // Hover-reveal card.
  void OnRevealEvent(const ui::Event& event);
  void StartRevealMonitor();
  void StopRevealMonitor();
  bool PointInRevealZone(const gfx::Point& point) const;
  bool PointInHoldZone(const gfx::Point& point) const;
  void ShowRevealCard();
  void HideRevealCard();
  void ApplyCardOffset(double offset);
  void OnCardMotionSettled();

  // Theme.
  void InvalidateThemeCache();
  OpenSpaceThemeState MakeThemeState(const SpaceID& space_id) const;
  theme::ContentAppearance SystemAppearance() const;

  raw_ptr<OpenViewController> controller_;
  WindowID window_id_;
  // Set by Install(); the BrowserView this view covers.
  raw_ptr<BrowserView> browser_view_ = nullptr;
  raw_ptr<views::View> browser_contents_container_ = nullptr;
  std::unique_ptr<BrowserViewTracker> browser_view_tracker_;

  raw_ptr<ThemeBackgroundView> theme_background_ = nullptr;
  raw_ptr<PanelShadowView> panel_shadow_ = nullptr;
  raw_ptr<PanelShadowView> card_shadow_ = nullptr;
  raw_ptr<PanelHostView> panel_host_ = nullptr;
  raw_ptr<OpenSidebarView> sidebar_ = nullptr;
  raw_ptr<ResizeHandle> resize_handle_ = nullptr;
  raw_ptr<RevealCardView> reveal_card_ = nullptr;
  raw_ptr<views::View> web_contents_host_ = nullptr;
  raw_ptr<views::View> overlay_host_ = nullptr;
  raw_ptr<views::View> split_container_ = nullptr;
  raw_ptr<OpenPanelSlideClient> split_slide_client_ = nullptr;
  std::map<OverlaySlot, raw_ptr<views::View>> overlays_;

  // Sidebar state. `sidebar_width_` is the live width (drag); the model
  // width is committed on release.
  float sidebar_width_;
  float drag_start_width_ = 0;
  bool sidebar_hidden_ = false;
  bool hidden_by_drag_ = false;
  bool resizing_ = false;
  bool split_view_active_ = false;
  // Cmd/Ctrl+S slide: offset 0 (shown) .. -width (hidden).
  std::unique_ptr<motion::OpenSpringAnimator> sidebar_slide_;
  double sidebar_offset_ = 0;
  gfx::Rect slide_from_panel_;
  gfx::Rect slide_to_panel_;
  bool sliding_ = false;

  // Hover-reveal card.
  CardState card_state_ = CardState::kOff;
  std::unique_ptr<RevealObserver> reveal_observer_;
  std::unique_ptr<views::EventMonitor> reveal_monitor_;
  base::OneShotTimer reveal_dwell_timer_;
  base::OneShotTimer reveal_exit_timer_;
  // Last pointer position seen by the reveal monitor (view coordinates).
  std::optional<gfx::Point> last_reveal_point_;
  std::unique_ptr<motion::OpenSpringAnimator> card_motion_;

  // Window and frame.
  WindowControls window_controls_;
  TrafficLightsCallback traffic_lights_callback_;
  bool clips_window_corners_ = false;
  bool window_active_ = true;
  bool widget_visible_ = false;
  base::CallbackListSubscription paint_as_active_subscription_;

  // Tab fullscreen: set by SetTabFullscreen(); applied_ is what Layout() did.
  bool tab_fullscreen_ = false;
  bool tab_fullscreen_applied_ = false;

  // macOS window material.
  bool translucent_window_ = false;
#if BUILDFLAG(IS_MAC)
  bool translucent_chrome_enabled_ = false;
  std::optional<WindowMaterialSpec> applied_material_;
#endif

  // Theme cache per Space (cleared on theme or appearance changes).
  std::map<SpaceID, OpenSpaceThemeState> theme_cache_;
  std::optional<SpaceID> shown_theme_space_;
  std::optional<SpaceID> transition_space_;

  // Favicon decode cache: tab id -> (PNG size, image).
  struct FaviconEntry {
    size_t png_size = 0;
    gfx::ImageSkia image;
  };
  std::map<ItemID, FaviconEntry> favicon_cache_;

  std::unique_ptr<PlusMenuDelegate> plus_menu_delegate_;
  std::unique_ptr<ui::MenuModel> menu_model_;
  std::unique_ptr<views::MenuRunner> menu_runner_;

  base::ScopedObservation<views::Widget, views::WidgetObserver>
      widget_observation_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_BROWSER_VIEW_H_
