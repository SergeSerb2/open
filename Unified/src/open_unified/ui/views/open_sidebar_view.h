// Copyright 2026 The Open Authors. All rights reserved.
//
// The Open sidebar (port of OpenSidebar SidebarView, docs/design.md 5.1):
//
//   ToolbarView     y 0..46   macOS: native traffic-light slot (x 0..77),
//                             then the sidebar toggle at x 77; Windows and
//                             Linux: no window controls, toggle at x 8.
//                             Back, Forward, Reload (compact < 219 pt: Back,
//                             Forward, More). Split View keeps only the toggle.
//   UrlPillView     [8, 46, W - 16, 36]  host + trailing-visible fade, Copy
//                             URL, Site Control, pinned extension actions;
//                             click opens the inline Command Bar.
//   FavoritesView   from y 82: balanced 3..4 column grid of 47 pt tiles.
//   OpenSpacePagerView        per-Space OpenTabTreeView pages.
//   (media stack)   Wave B's mini-player cards, preferred height.
//   BottomBarView   50 pt: Library [8, 9, 32, 32], Space switcher strip
//                             [42, 0, W - 84, 50], "+" [W - 40, 9, 32, 32].
//
// The sidebar is transparent: the window's ThemeBackgroundView shows through
// (anchored), or the hover-reveal card paints under it (floating card).

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_SIDEBAR_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_SIDEBAR_VIEW_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "open_unified/core/model/open_types.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/views/view.h"

namespace open_unified {

class OpenSidebarContext;
class OpenSpacePagerView;
class OpenTabTreeView;

class OpenSidebarView : public views::View {
  METADATA_HEADER(OpenSidebarView, views::View)

 public:
  class Delegate {
   public:
    virtual ~Delegate() = default;
    // Fired when the Win/Linux Open App Menu button is pressed.
    virtual void OnAppMenuRequested(views::View* anchor) {}
    // Fired when a pinned extension button in the URL pill is right-clicked.
    virtual void OnExtensionContextMenuRequested(
        const std::string& extension_id,
        views::View* anchor,
        const gfx::Point& screen_pt) {}
    // Fired when a Space is drag-reordered in the bottom Space switcher strip.
    virtual void OnSpaceReordered(const std::string& space_id,
                                  size_t to_index) {}
  };

  enum class Presentation { kAnchored, kFloatingCard };
  // kNativeReserved: macOS keeps the system traffic lights in the leading
  // 77 pt. kNone: no window controls in the sidebar (Windows, Linux).
  enum class WindowControlsSlot { kNativeReserved, kNone };

  explicit OpenSidebarView(OpenSidebarContext* context);
  OpenSidebarView(const OpenSidebarView&) = delete;
  OpenSidebarView& operator=(const OpenSidebarView&) = delete;
  ~OpenSidebarView() override;

  void SetPresentation(Presentation presentation);
  Presentation presentation() const { return presentation_; }
  void SetWindowControlsSlot(WindowControlsSlot slot);
  // On Linux with leading window buttons (close/min/max on the left), the
  // sidebar stays at y = 0 and shifts its toolbar buttons right of the cluster.
  void SetLeadingControlsInset(int px);
  // Keeps URL pill accessories (Copy, Site Control, pinned extensions) visible
  // while a popover anchored to one of them is open.
  void SetHasOpenPopover(bool open);
  bool has_open_popover() const { return has_open_popover_; }

  void SetDelegate(Delegate* delegate) { delegate_ = delegate; }
  Delegate* delegate() const { return delegate_; }

  // --- Model notifications (forwarded by OpenBrowserView) ------------------
  void OnTreeChanged(const TreeChange& change);
  void OnSpacesChanged();
  void OnSpaceThemeChanged(const SpaceID& space_id);
  void OnFavoritesChanged();
  void OnWindowStateChanged(bool animate);
  void OnTabLiveStateChanged(const ItemID& tab_id);
  void OnActiveTabChanged();
  void OnSplitViewChanged(bool active);
  void OnPeekChanged();
  void OnCommandBarStateChanged();
  void OnToolbarActionsChanged();
  void OnWindowActivationChanged();
  void OnAppearanceChanged();

  // --- Accessors for anchors and automation --------------------------------
  views::View* url_pill() const;
  views::View* site_control_button() const;
  views::View* GetAppMenuButton() const;
  OpenSpacePagerView* pager() const { return pager_; }
  OpenTabTreeView* GetTreeForSpace(const SpaceID& space_id) const;
  // Toolbar row and bottom bar dim while Peek shows (F0090).
  void SetPeekDimmed(bool dimmed);
  // Interactive children report HTCLIENT; the rest of the toolbar and bottom
  // bar backgrounds are window-drag regions.
  bool IsPointInDragRegion(const gfx::Point& point_in_sidebar) const;

  // Incognito windows (docs/incognito.md): fixed #26232B theme, eyeglasses +
  // "Private" header, no Favorites, Pinned section, Space switcher or
  // Library; white 15 % URL field.
  bool IsIncognito() const;

  // --- Slots for Wave B ----------------------------------------------------
  // Download progress ring around the bottom-bar Library button: 0..1, or
  // nullopt to hide it.
  void SetLibraryDownloadProgress(std::optional<double> progress);
  // Media mini-player card stack, laid out right above the bottom bar at its
  // preferred height (the Space pager shrinks). Null removes it.
  views::View* SetMediaPlayerStack(std::unique_ptr<views::View> stack);
  views::View* media_player_stack() const { return media_stack_; }
  // Favorite tile accessories: the Live Calendar countdown plate under the
  // icon, and the unread-count badge (top-right). Empty text clears.
  void SetFavoriteSubtitle(const ItemID& tab_id, const std::u16string& text);
  void SetFavoriteBadge(const ItemID& tab_id, const std::u16string& text);
  const std::u16string* FavoriteSubtitle(const ItemID& tab_id) const;
  const std::u16string* FavoriteBadge(const ItemID& tab_id) const;
  // "Drag to add Favorites" card while the Profile has no Favorites. On by
  // default; its "x" hides it and runs the callback (persist the dismissal).
  void SetFavoritesEmptyStateEnabled(bool enabled);
  void SetFavoritesEmptyStateDismissedCallback(base::RepeatingClosure callback);
  bool IsFavoritesEmptyStateVisible() const;

  // views::View:
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  void OnMouseEntered(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;

 private:
  class ToolbarButton;
  class ToolbarView;
  class UrlPillView;
  class FavoritesView;
  class FavoriteTileView;
  class BottomBarView;
  class SwitcherStripView;
  class FavoritesEmptyStateView;
  friend class ToolbarView;
  friend class UrlPillView;
  friend class FavoritesView;
  friend class FavoriteTileView;
  friend class BottomBarView;
  friend class SwitcherStripView;
  friend class FavoritesEmptyStateView;

  const Space* focused_space() const;
  const Profile* focused_profile() const;
  float favorites_section_height() const;
  void UpdateHover(bool hovered);
  void DismissFavoritesEmptyState();
  // Applies Incognito visibility to the chrome (favorites, bottom bar).
  void ApplyIncognitoChrome();
  void NotifyAppMenuRequested(views::View* anchor);
  void NotifyExtensionContextMenuRequested(const std::string& extension_id,
                                           views::View* anchor,
                                           const gfx::Point& screen_pt);
  void NotifySpaceReordered(const std::string& space_id, size_t to_index);

  raw_ptr<OpenSidebarContext> context_;
  raw_ptr<Delegate> delegate_ = nullptr;
  Presentation presentation_ = Presentation::kAnchored;
  raw_ptr<ToolbarView> toolbar_ = nullptr;
  raw_ptr<UrlPillView> url_pill_ = nullptr;
  raw_ptr<FavoritesView> favorites_ = nullptr;
  raw_ptr<OpenSpacePagerView> pager_ = nullptr;
  raw_ptr<BottomBarView> bottom_bar_ = nullptr;
  raw_ptr<views::View> media_stack_ = nullptr;
  std::map<ItemID, std::u16string> favorite_subtitles_;
  std::map<ItemID, std::u16string> favorite_badges_;
  bool favorites_empty_state_enabled_ = true;
  bool favorites_empty_state_dismissed_ = false;
  base::RepeatingClosure favorites_empty_state_dismissed_callback_;
  bool sidebar_hovered_ = false;
  bool has_open_popover_ = false;
  bool split_view_active_ = false;
  bool peek_dimmed_ = false;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_SIDEBAR_VIEW_H_
