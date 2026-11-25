// Copyright 2026 The Open Authors. All rights reserved.
//
// One Space's sidebar page: the Space header (36 pt) above a scrolling,
// incremental tree of rows (port of OpenSidebar SpacePageView / SidebarRows):
//
//   spacer 3 | Pinned rows (tabs, folders with 16 pt/level children, splits)
//   | Pinned/Today divider 17 (only with Today tabs; "Clear" on hover)
//   | "+ New Tab" 41 | Today rows
//
// The tree never edits the model. Every action becomes an OpenIntent sent
// through OpenSidebarContext. Structure follows TreeChange events: rows are
// reconciled by node id, so a change creates/destroys only the affected row
// views and animates the rest (no full reload after the first build). Title,
// favicon, audio and sleep changes repaint only the affected row.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_TAB_TREE_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_TAB_TREE_VIEW_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/design/open_theme_math.h"
#include "ui/base/dragdrop/os_exchange_data.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/base/mojom/menu_source_type.mojom-forward.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/views/animation/bounds_animator.h"
#include "ui/views/view.h"

namespace ui {
class ClipboardFormatType;
class Compositor;
}  // namespace ui

namespace views {
class ScrollView;
}

namespace open_unified {

class OpenViewController;
struct OpenIntent;
struct OpenMenuTarget;

// Theme state of one Space, computed once per theme or appearance change.
struct OpenSpaceThemeState {
  theme::ThemeStyle style;
  theme::ContentAppearance appearance = theme::ContentAppearance::kDark;
  theme::SidebarRoles roles;
  // High-contrast accent (unread dot, focus marks); 3:1 over the field.
  theme::Rgba contrast_accent;
  // Folder glyphs and other accent marks.
  theme::Rgba accent;
};

// Services the sidebar views need from their window. Implemented by
// OpenBrowserView; one per window.
class OpenSidebarContext {
 public:
  virtual OpenViewController* controller() const = 0;
  virtual const WindowID& window_id() const = 0;

  // Cached theme state (style + content appearance + roles) per Space.
  virtual const OpenSpaceThemeState& ThemeStateFor(const SpaceID& space_id) = 0;
  virtual SpaceID FocusedSpaceId() const = 0;
  virtual bool IsWindowActive() const = 0;
  virtual float SidebarWidth() const = 0;

  virtual void Send(const OpenIntent& intent) = 0;
  virtual void ShowSidebarMenu(const OpenMenuTarget& target,
                               views::View* source,
                               const gfx::Point& screen_point,
                               ui::mojom::MenuSourceType source_type) = 0;
  // Decoded and cached favicon (controller image first, then the tab's
  // favicon PNG). Null image: draw the letter tile.
  virtual gfx::ImageSkia FaviconFor(const Tab& tab) = 0;

  // Space background transitions driven by the pager.
  virtual void BeginThemeTransition(const SpaceID& to) = 0;
  virtual void SetThemeTransitionProgress(double progress) = 0;
  virtual void EndThemeTransition(bool commit) = 0;
  virtual void CrossfadeTheme(const SpaceID& to, bool animated) = 0;

  // Compositor for display-rate animations (null when not in a widget).
  virtual ui::Compositor* AnimationCompositor() = 0;
  // Structural and Space animations run only in a visible window.
  virtual bool AnimationsEnabled() const = 0;

 protected:
  virtual ~OpenSidebarContext() = default;
};

// Drag and drop payload shared by the tree, Favorites and the switcher.
namespace sidebar_dnd {
const ui::ClipboardFormatType& NodeFormat();
void WriteNode(ui::OSExchangeData* data,
               const ItemID& node_id,
               const std::string& url,
               const std::u16string& title);
std::optional<ItemID> ReadNode(const ui::OSExchangeData& data);
}  // namespace sidebar_dnd

class OpenTabTreeView : public views::View {
  METADATA_HEADER(OpenTabTreeView, views::View)

 public:
  enum class RowKind { kSpacer, kNode, kDivider, kNewTab };

  // One displayed row. `parent`/`index` locate the node in the model.
  struct RowDescriptor {
    RowKind kind = RowKind::kSpacer;
    std::string key;  // node id, or "#spacer" / "#divider" / "#newtab"
    ItemID node_id;
    SidebarNode::Kind node_kind = SidebarNode::Kind::kTab;
    int depth = 0;
    NodeParent parent;
    size_t index = 0;
    bool in_pinned = false;
    bool operator==(const RowDescriptor&) const = default;
  };

  OpenTabTreeView(OpenSidebarContext* context, const SpaceID& space_id);
  OpenTabTreeView(const OpenTabTreeView&) = delete;
  OpenTabTreeView& operator=(const OpenTabTreeView&) = delete;
  ~OpenTabTreeView() override;

  const SpaceID& space_id() const { return space_id_; }

  // --- Model notifications (routed by OpenSidebarView) -----------------------
  void ApplyTreeChange(const TreeChange& change);
  void Reload();
  void OnSpaceChanged();             // title, icon, pinned collapsed
  void OnSpaceThemeChanged();        // roles / appearance
  void OnSelectionChanged();        // selected_node_by_space
  void OnTabLiveStateChanged(const ItemID& tab_id);
  void OnWindowActivationChanged();
  void SetPeekSourceNode(std::optional<ItemID> node_id);
  void SetNewTabCommandBarOpen(bool open);

  // --- Commands -----------------------------------------------------------------
  void BeginRename(const ItemID& node_id);
  void ScrollToNode(const ItemID& node_id);
  // Bounds of a node's row in screen coordinates (automation, menus, Peek).
  std::optional<gfx::Rect> GetRowBoundsInScreen(const ItemID& node_id) const;
  const std::vector<RowDescriptor>& rows() const { return rows_; }
  // Number of full rebuilds since creation (incremental-update check).
  int full_reload_count() const { return full_reload_count_; }

  // Horizontal scroll handed to the pager (two-finger Space swipe).
  views::ScrollView* scroll_view() { return scroll_view_; }

  // views::View:
  void Layout(PassKey) override;
  void OnThemeChanged() override;

 private:
  class HeaderView;
  class ListView;
  class RowView;
  friend class ListView;
  friend class RowView;
  friend class HeaderView;

  const Space* space() const;
  const OpenSpaceThemeState& theme_state() const;
  std::vector<RowDescriptor> BuildDescriptors() const;
  // Rebuilds descriptors and reconciles row views by key.
  void Reconcile(bool animate);
  RowView* FindRow(const ItemID& node_id) const;
  std::optional<ItemID> SelectedNodeId() const;

  // Drop target support (ListView forwards).
  struct DropTarget {
    NodeParent parent;
    std::optional<size_t> index;  // nullopt: append (into a folder)
    int indicator_y = -1;         // list coordinates; -1 for "into folder"
    std::optional<ItemID> into_folder;
  };
  std::optional<DropTarget> ComputeDropTarget(const gfx::Point& list_point,
                                              const std::optional<ItemID>&
                                                  dragged) const;

  raw_ptr<OpenSidebarContext> context_;
  SpaceID space_id_;
  raw_ptr<HeaderView> header_ = nullptr;
  raw_ptr<views::ScrollView> scroll_view_ = nullptr;
  raw_ptr<ListView> list_ = nullptr;
  std::vector<RowDescriptor> rows_;
  std::map<std::string, raw_ptr<RowView>> row_views_;
  std::optional<ItemID> peek_source_;
  std::optional<ItemID> last_selected_;
  bool new_tab_command_bar_open_ = false;
  int full_reload_count_ = 0;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_TAB_TREE_VIEW_H_
