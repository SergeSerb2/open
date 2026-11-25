// Copyright 2026 The Open Authors. All rights reserved.
//
// The Open sidebar (port of OpenSidebar SidebarView, docs/design.md 5.1):
//
//   ToolbarView     y 0..46   window controls slot (x 0..77), sidebar toggle,
//                             Back, Forward, Reload (compact < 219 pt: Back,
//                             Forward, More). Split View keeps only the toggle.
//   UrlPillView     [8, 46, W - 16, 36]  host + trailing-visible fade, Copy
//                             URL, Site Control, pinned extension actions;
//                             click opens the inline Command Bar.
//   FavoritesView   from y 82: balanced 3..4 column grid of 47 pt tiles.
//   OpenSpacePagerView        per-Space OpenTabTreeView pages.
//   BottomBarView   50 pt: Library [8, 9, 32, 32], Space switcher strip
//                             [42, 0, W - 84, 50], "+" [W - 40, 9, 32, 32].
//
// The sidebar is transparent: the window's ThemeBackgroundView shows through
// (anchored), or the hover-reveal card paints under it (floating card).

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_SIDEBAR_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_SIDEBAR_VIEW_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

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
  enum class Presentation { kAnchored, kFloatingCard };
  enum class WindowControlsSlot { kNativeReserved, kCustom, kNone };

  explicit OpenSidebarView(OpenSidebarContext* context);
  OpenSidebarView(const OpenSidebarView&) = delete;
  OpenSidebarView& operator=(const OpenSidebarView&) = delete;
  ~OpenSidebarView() override;

  void SetPresentation(Presentation presentation);
  Presentation presentation() const { return presentation_; }
  void SetWindowControlsSlot(WindowControlsSlot slot);

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
  OpenSpacePagerView* pager() const { return pager_; }
  OpenTabTreeView* GetTreeForSpace(const SpaceID& space_id) const;
  // Toolbar row and bottom bar dim while Peek shows (F0090).
  void SetPeekDimmed(bool dimmed);
  // Interactive children report HTCLIENT; the rest of the toolbar and bottom
  // bar backgrounds are window-drag regions.
  bool IsPointInDragRegion(const gfx::Point& point_in_sidebar) const;

  // views::View:
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  void OnMouseEntered(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;

 private:
  class ToolbarButton;
  class ToolbarView;
  class WindowControlsView;
  class UrlPillView;
  class FavoritesView;
  class FavoriteTileView;
  class BottomBarView;
  class SwitcherStripView;
  friend class ToolbarView;
  friend class UrlPillView;
  friend class FavoritesView;
  friend class FavoriteTileView;
  friend class BottomBarView;
  friend class SwitcherStripView;

  const Space* focused_space() const;
  const Profile* focused_profile() const;
  float favorites_section_height() const;
  void UpdateHover(bool hovered);

  raw_ptr<OpenSidebarContext> context_;
  Presentation presentation_ = Presentation::kAnchored;
  raw_ptr<ToolbarView> toolbar_ = nullptr;
  raw_ptr<UrlPillView> url_pill_ = nullptr;
  raw_ptr<FavoritesView> favorites_ = nullptr;
  raw_ptr<OpenSpacePagerView> pager_ = nullptr;
  raw_ptr<BottomBarView> bottom_bar_ = nullptr;
  bool sidebar_hovered_ = false;
  bool split_view_active_ = false;
  bool peek_dimmed_ = false;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_SIDEBAR_VIEW_H_
