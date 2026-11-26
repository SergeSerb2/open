// Copyright 2026 The Open Authors. All rights reserved.
//
// Sidebar popovers drawn by Open (not native menus):
//
//  - OpenPlusPopover: the bottom-bar "+" card (PlusPopover.swift,
//    PlusPopoverTokens.swift; capture session 8 item 7, Arc 1.172.2).
//    Body 210 wide, rows 194 x 40 inset 8, 17 pt between groups with a 1 pt
//    line, icon centered 20 pt into the row, label at 39 pt (14 semibold),
//    shortcut 7 pt before the row end (13 medium), body radius 14, row
//    radius 10. Body right edge 8 pt inside the sidebar, above the "+".
//    Opens with the last enabled row ("New Tab") highlighted; Up / Down move
//    and wrap, Return runs the row, Esc or a click outside closes.
//  - OpenToolbarMorePopover: the compact toolbar's "More options" card
//    (ToolbarMorePopover.swift; capture session 9 `46-pb5-a6-compact-more`).
//    200 wide, padding 8, rows 39 with a 1 pt gap, row radius 8, card radius
//    12; icon center 27.5 pt from the card's left, title at 50 pt (13
//    medium), shortcut 21 pt from the right (12 regular). Two rows give the
//    measured 200 x 95 card.
//  - OpenDownloadsPopover: recent downloads above the Library button. No
//    Swift or Arc capture exists for this card: Open's own design in the
//    "+" card's material (fill, highlight, radius), with live progress.
//
// The "+" and "More options" rows come from a ui::MenuModel (the same model
// BuildSidebarMenuModel() makes for OpenMenuTarget::kPlusButton and
// kToolbarMore), as in Swift: one list of items, titles, shortcuts and
// enabled rules for the popover and the menu fallback. Running a row calls
// MenuModel::ActivatedAt(), so its SidebarMenuCommand reaches the window
// controller's one dispatch switch.
//
// Material: Views has no cheap backdrop blur; the cards use the solid
// measured fills (PlusPopoverColors). Chromium 156's visible bubble arrow
// requires bubble-border insets that conflict with the platform dialog
// shadow (BubbleBorder DCHECK), so the cards have no arrow; their body sits
// 2 pt from the anchor, where the Swift arrow tip points.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_SIDEBAR_POPOVERS_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_SIDEBAR_POPOVERS_H_

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "open_unified/browser/open_download_bridge.h"
#include "open_unified/ui/design/open_theme_math.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/base/mojom/menu_source_type.mojom-forward.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"

namespace ui {
class MenuModel;
}

namespace views {
class BubbleDialogDelegate;
class MenuRunner;
}  // namespace views

namespace open_unified {

struct OpenSpaceThemeState;

namespace popover_metrics {
// PlusPopoverMetrics (capture session 8 item 7).
inline constexpr int kPlusBodyWidth = 210;
inline constexpr int kPlusRowWidth = 194;
inline constexpr int kPlusRowHeight = 40;
inline constexpr int kPlusRowInset = 8;
inline constexpr int kPlusGroupGap = 17;
inline constexpr int kPlusSeparatorOffset = 8;
inline constexpr int kPlusSeparatorInset = 12;
inline constexpr int kPlusIconCenterX = 20;
inline constexpr int kPlusIconPointSize = 17;
inline constexpr int kPlusLabelX = 39;
inline constexpr int kPlusShortcutTrailing = 7;
inline constexpr int kPlusBodyRadius = 14;  // guess from pixel edges
inline constexpr int kPlusRowRadius = 10;   // guess from pixel edges
inline constexpr int kPlusTrailingInset = 8;
inline constexpr int kPlusLabelFontSize = 14;     // semibold
inline constexpr int kPlusShortcutFontSize = 13;  // medium
// ToolbarMorePopover.Metrics (capture session 9).
inline constexpr int kMoreWidth = 200;
inline constexpr int kMorePadding = 8;
inline constexpr int kMoreRowHeight = 39;
inline constexpr int kMoreRowGap = 1;
inline constexpr int kMoreRowRadius = 8;
inline constexpr int kMoreCardRadius = 12;  // guess
inline constexpr float kMoreIconCenterX = 27.5f;
inline constexpr int kMoreTitleX = 50;
inline constexpr int kMoreShortcutInset = 21;
inline constexpr int kMoreTitleFontSize = 13;     // medium, guess
inline constexpr int kMoreShortcutFontSize = 12;  // regular, guess
// Body gap to the anchor (the Swift arrow tip sits 2 pt above the "+").
inline constexpr int kAnchorGap = 2;
// Downloads card (Open's design).
inline constexpr int kDownloadsWidth = 300;
inline constexpr int kDownloadsPadding = 8;
inline constexpr int kDownloadsHeaderHeight = 36;
inline constexpr int kDownloadsRowHeight = 52;
inline constexpr int kDownloadsRowRadius = 10;
inline constexpr int kDownloadsIcon = 32;
inline constexpr int kDownloadsIconRadius = 7;
inline constexpr int kDownloadsButton = 24;
inline constexpr int kDownloadsProgressHeight = 3;
inline constexpr int kDownloadsFooterHeight = 36;
inline constexpr int kDownloadsMaxRows = 6;
}  // namespace popover_metrics

// PlusPopoverColors: the Space's `backgroundExtra` fill, the palette hover as
// the row highlight and the separator, and the measured default-theme label,
// disabled and shortcut inks (light and dark).
struct OpenPopoverColors {
  SkColor fill = SkColorSetRGB(0xFD, 0xFD, 0xFF);
  SkColor highlight = SkColorSetRGB(0xD3, 0xD4, 0xFF);
  SkColor separator = SkColorSetRGB(0xD3, 0xD4, 0xFF);
  SkColor label = SK_ColorBLACK;
  SkColor secondary_label = SkColorSetARGB(0x99, 0x00, 0x00, 0x00);
  SkColor disabled = SkColorSetRGB(0xAB, 0xAB, 0xAB);
  SkColor shortcut = SkColorSetRGB(0xA5, 0xAA, 0xFF);
  // Shortcut ink on the highlighted row (More options: #A6AAFB on #D3D4FD).
  SkColor shortcut_highlighted = SkColorSetRGB(0xA5, 0xAA, 0xFF);
  // Downloads progress track and fill.
  SkColor track = SkColorSetARGB(0x24, 0x00, 0x00, 0x00);
  SkColor progress = SkColorSetRGB(0x6F, 0x66, 0xD9);
  bool dark = false;

  // The "+" card's colors for a Space theme. `system` is the OS appearance
  // (legacy-intensity themes follow it; others use the window scheme).
  static OpenPopoverColors ForTheme(const theme::ThemeStyle& style,
                                    theme::ContentAppearance system);
  static OpenPopoverColors ForThemeState(const OpenSpaceThemeState& state,
                                         theme::ContentAppearance system);
  // The More options card's own measured colors (light measured; dark guess).
  static OpenPopoverColors ToolbarMore(bool dark);
};

// ---------------------------------------------------------------------------
// Popover lifetime: one BubbleDialogDelegate + widget, the same pattern as
// OpenSiteControlBubble (Chromium 156 makes BubbleDialogDelegateView's
// constructors private). Closes on deactivation and Esc.
class OpenPopoverHost {
 public:
  OpenPopoverHost();
  OpenPopoverHost(const OpenPopoverHost&) = delete;
  OpenPopoverHost& operator=(const OpenPopoverHost&) = delete;
  ~OpenPopoverHost();

  // Shows `contents` anchored to `anchor` with `arrow` (BOTTOM_*: above the
  // anchor; TOP_*: below it). Replaces an open popover. `on_closed` runs once
  // when this popover closes for any reason (not when it is replaced).
  views::View* Show(views::View* anchor,
                    views::BubbleBorder::Arrow arrow,
                    std::unique_ptr<views::View> contents,
                    SkColor fill,
                    int corner_radius,
                    int fixed_width,
                    std::string_view name,
                    base::OnceClosure on_closed = base::OnceClosure());
  void Close();
  bool IsShowing() const;
  // Re-fits the widget to the contents' preferred size.
  void SizeToContents();
  views::View* contents() const { return contents_; }
  views::Widget* widget() const { return widget_.get(); }
  // True right after a close: a click on the anchor button deactivated the
  // popover, so that click must not reopen it (Swift `closesOnly`).
  bool JustClosed() const;

 private:
  void OnWidgetClosed(views::Widget::ClosedReason reason);
  void DiscardBubble(bool synchronous);

  std::unique_ptr<views::BubbleDialogDelegate> bubble_delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<views::View> contents_ = nullptr;
  base::OnceClosure on_closed_;
  base::TimeTicks last_closed_;
  base::WeakPtrFactory<OpenPopoverHost> weak_factory_{this};
};

// ---------------------------------------------------------------------------
// A card of rows built from a ui::MenuModel (commands and separators; other
// item types are skipped). Drawn rows, keyboard navigation, one
// accessibility menu item per row.
class OpenMenuCardView : public views::View {
  METADATA_HEADER(OpenMenuCardView, views::View)

 public:
  enum class Style { kPlus, kToolbarMore };
  // Runs row `index` of the model (MenuModel index) with `event_flags`.
  using RunCallback =
      base::RepeatingCallback<void(size_t model_index, int event_flags)>;

  OpenMenuCardView(Style style,
                   ui::MenuModel* model,
                   const OpenPopoverColors& colors,
                   RunCallback on_run);
  OpenMenuCardView(const OpenMenuCardView&) = delete;
  OpenMenuCardView& operator=(const OpenMenuCardView&) = delete;
  ~OpenMenuCardView() override;

  void SetColors(const OpenPopoverColors& colors);
  // Highlighted row (row index, not model index); nullopt for none.
  std::optional<size_t> highlighted() const { return highlighted_; }
  void SetHighlighted(std::optional<size_t> row);
  // Moves the highlight over enabled rows, wrapping (Up -1, Down +1).
  void MoveHighlight(int delta);
  void RunHighlighted(int event_flags);
  size_t row_count() const { return rows_.size(); }
  std::u16string RowTitle(size_t row) const;

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  void OnThemeChanged() override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseMoved(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;

 private:
  class RowAccessibilityView;
  struct Row {
    size_t model_index = 0;
    std::u16string title;
    std::u16string shortcut;
    bool enabled = true;
    gfx::Rect bounds;
  };

  void Rebuild(ui::MenuModel* model);
  void Run(size_t row, int event_flags);
  std::optional<size_t> RowAt(const gfx::Point& point) const;
  void PaintRow(gfx::Canvas* canvas, const Row& row, bool highlighted);
  void PaintRowIcon(gfx::Canvas* canvas,
                    const Row& row,
                    const gfx::RectF& box,
                    SkColor ink);

  Style style_;
  OpenPopoverColors colors_;
  RunCallback on_run_;
  std::vector<Row> rows_;
  std::vector<int> separator_ys_;
  int content_height_ = 0;
  std::optional<size_t> highlighted_;
  std::optional<size_t> pressed_;
  // More options: the pointer has not entered a row yet.
  bool pointer_seen_ = false;
};

// ---------------------------------------------------------------------------
// The "+" popover. `model` is BuildSidebarMenuModel(kPlusButton). The
// popover keeps the model alive until the chosen row ran.
class OpenPlusPopover {
 public:
  OpenPlusPopover();
  OpenPlusPopover(const OpenPlusPopover&) = delete;
  OpenPlusPopover& operator=(const OpenPlusPopover&) = delete;
  ~OpenPlusPopover();

  // Anchored above `plus_button` (right-aligned to it).
  void Show(views::View* plus_button,
            std::unique_ptr<ui::MenuModel> model,
            const OpenPopoverColors& colors,
            base::OnceClosure on_closed = base::OnceClosure());
  void Close();
  bool IsShowing() const;
  // The "+" button should toggle: a click on it while shown only closes.
  void Toggle(views::View* plus_button,
              std::unique_ptr<ui::MenuModel> model,
              const OpenPopoverColors& colors,
              base::OnceClosure on_closed = base::OnceClosure());
  OpenMenuCardView* card() const;
  views::Widget* widget() const { return host_.widget(); }

 private:
  void Run(size_t model_index, int event_flags);

  OpenPopoverHost host_;
  std::unique_ptr<ui::MenuModel> model_;
  base::WeakPtrFactory<OpenPlusPopover> weak_factory_{this};
};

// The compact toolbar's "More options" popover, below the More button.
// `model` is BuildSidebarMenuModel(kToolbarMore).
class OpenToolbarMorePopover {
 public:
  OpenToolbarMorePopover();
  OpenToolbarMorePopover(const OpenToolbarMorePopover&) = delete;
  OpenToolbarMorePopover& operator=(const OpenToolbarMorePopover&) = delete;
  ~OpenToolbarMorePopover();

  // The button shows "x" while the card is open; `on_closed` restores it.
  void Show(views::View* more_button,
            std::unique_ptr<ui::MenuModel> model,
            const OpenPopoverColors& colors,
            base::OnceClosure on_closed = base::OnceClosure());
  void Close();
  bool IsShowing() const;
  // A click on the More button while shown only closes.
  void Toggle(views::View* more_button,
              std::unique_ptr<ui::MenuModel> model,
              const OpenPopoverColors& colors,
              base::OnceClosure on_closed = base::OnceClosure());
  OpenMenuCardView* card() const;
  views::Widget* widget() const { return host_.widget(); }

 private:
  void Run(size_t model_index, int event_flags);

  OpenPopoverHost host_;
  std::unique_ptr<ui::MenuModel> model_;
  base::WeakPtrFactory<OpenToolbarMorePopover> weak_factory_{this};
};

// ---------------------------------------------------------------------------
// Recent downloads.

enum class DownloadPopoverAction {
  kOpen,             // download_id
  kReveal,           // download_id: Finder on macOS, the folder elsewhere
  kPause,            // download_id
  kResume,           // download_id
  kCancel,           // download_id
  kRetry,            // download_id
  kCopyLink,         // download_id (source URL)
  kRemove,           // download_id (from the list; the file stays)
  kViewAllDownloads, // Library > Downloads
  kClearCompleted,
};

using DownloadPopoverCallback =
    base::RepeatingCallback<void(DownloadPopoverAction action,
                                 const std::string& download_id)>;

// "Show in Finder" on macOS, "Show in Folder" elsewhere.
std::u16string RevealInFolderLabel();
// "4.5 MB", "820 KB" (1000-based, like Finder).
std::u16string FormatDownloadBytes(int64_t bytes);

class OpenDownloadsView : public views::View,
                          public ui::SimpleMenuModel::Delegate {
  METADATA_HEADER(OpenDownloadsView, views::View)

 public:
  OpenDownloadsView(std::vector<RecentDownloadEntry> entries,
                    const OpenPopoverColors& colors,
                    DownloadPopoverCallback on_action);
  OpenDownloadsView(const OpenDownloadsView&) = delete;
  OpenDownloadsView& operator=(const OpenDownloadsView&) = delete;
  ~OpenDownloadsView() override;

  // Live refresh: rows are kept by download id; only changed rows repaint.
  void UpdateDownloads(std::vector<RecentDownloadEntry> entries);
  void SetColors(const OpenPopoverColors& colors);
  const std::vector<RecentDownloadEntry>& entries() const { return entries_; }

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;

  // ui::SimpleMenuModel::Delegate (row context menu):
  void ExecuteCommand(int command_id, int event_flags) override;
  bool IsCommandIdEnabled(int command_id) const override;

 private:
  class RowView;
  class TextButton;
  friend class RowView;

  void RebuildRows();
  void ShowRowMenu(const std::string& id,
                   views::View* source,
                   const gfx::Point& screen_point,
                   ui::mojom::MenuSourceType source_type);
  const RecentDownloadEntry* Find(const std::string& id) const;
  void Run(DownloadPopoverAction action, const std::string& id);

  std::vector<RecentDownloadEntry> entries_;
  OpenPopoverColors colors_;
  DownloadPopoverCallback on_action_;
  std::vector<raw_ptr<RowView>> rows_;
  raw_ptr<TextButton> clear_button_ = nullptr;
  raw_ptr<TextButton> view_all_button_ = nullptr;
  std::string menu_download_id_;
  std::unique_ptr<ui::SimpleMenuModel> menu_model_;
  std::unique_ptr<views::MenuRunner> menu_runner_;
};

// The downloads card above the Library button (left-aligned to it).
class OpenDownloadsPopover {
 public:
  explicit OpenDownloadsPopover(DownloadPopoverCallback on_action);
  OpenDownloadsPopover(const OpenDownloadsPopover&) = delete;
  OpenDownloadsPopover& operator=(const OpenDownloadsPopover&) = delete;
  ~OpenDownloadsPopover();

  void Show(views::View* library_button,
            std::vector<RecentDownloadEntry> entries,
            const OpenPopoverColors& colors,
            base::OnceClosure on_closed = base::OnceClosure());
  void Close();
  bool IsShowing() const;
  // Live refresh while open (OpenDownloadBridge::Observer updates). No-op
  // while closed.
  void UpdateDownloads(std::vector<RecentDownloadEntry> entries);
  OpenDownloadsView* contents() const;
  views::Widget* widget() const { return host_.widget(); }

 private:
  void OnAction(DownloadPopoverAction action, const std::string& id);

  DownloadPopoverCallback on_action_;
  OpenPopoverHost host_;
  base::WeakPtrFactory<OpenDownloadsPopover> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_SIDEBAR_POPOVERS_H_
