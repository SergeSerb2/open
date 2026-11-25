// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenSiteControlBubble: the Site Control Center panel.
//
// Sources: SiteControlMetrics / SiteControlColors in
// Packages/OpenKit/Sources/OpenDesign/SiteControlTokens.swift (S2 09/0010,
// Arc 1.172 session 2 14c), ExtensionsMetrics.swift.
//
// Layout (236 wide, padding 10, radius 16, at most 640 tall):
//   quick-action tiles (48 × 32, radius 6, gap 8): Copy URL, New Boost,
//     Split, Capture;
//   Extensions: a 4-column grid of pinned/active extension actions (48 × 32
//     tiles, 16 pt icon, badge overlay). A click hands the tile to Track 6,
//     which runs the real ToolbarActionsModel / ExtensionActionViewController
//     action and anchors the real Chromium extension popup to that tile;
//   Permissions: Camera, Microphone, Location, Notifications, Pop-ups rows
//     (32 pt circle, 43 pt pitch) with an Ask / Allow / Block menu;
//   Ad blocking: native toggle with the live blocked count for this host;
//   footer (32 pt): the security pill (lock + host) opens Site Settings; the
//     round trash button clears site data.
//
// Construction note: Chromium 156 makes BubbleDialogDelegateView's
// constructors private (friend list), so this uses the public
// views::BubbleDialogDelegate with a contents view, the same pattern as
// Chromium's ExtensionsMenuCoordinator.
//
// Material: Arc's panel is a backdrop blur with a Space tint. Views has no
// cheap backdrop blur, so the panel uses a solid body (Open choice; Track 4
// can pass a themed color through `SiteControlState::panel_color`).

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_SITE_CONTROL_BUBBLE_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_SITE_CONTROL_BUBBLE_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"

namespace views {
class BubbleDialogDelegate;
class MenuRunner;
}  // namespace views

namespace open_unified {

namespace site_control_metrics {
inline constexpr int kWidth = 236;
inline constexpr int kPadding = 10;
inline constexpr int kCornerRadius = 16;
inline constexpr int kMaxHeight = 640;
inline constexpr int kActionWidth = 48;
inline constexpr int kActionHeight = 32;
inline constexpr int kActionGap = 8;
inline constexpr int kActionRadius = 6;
inline constexpr int kActionGlyph = 17;
inline constexpr int kGapAfterActions = 37;
inline constexpr int kSectionGap = 43;
inline constexpr int kLabelBaselineAboveContent = 14;
inline constexpr int kExtensionColumns = 4;
inline constexpr int kExtensionRowPitch = 40;
inline constexpr int kExtensionIcon = 16;
inline constexpr int kTileRadius = 6;
inline constexpr int kRowIcon = 32;
inline constexpr int kRowPitch = 43;
inline constexpr int kRowTextX = 50;
inline constexpr int kRowTitleBaseline = 13;
inline constexpr int kRowSubtitleBaseline = 29;
inline constexpr int kRowGlyph = 15;
inline constexpr int kGapBeforeSeparator = 15;
inline constexpr int kGapAfterSeparator = 10;
inline constexpr int kFooterHeight = 32;
inline constexpr int kPillRadius = 8;
inline constexpr int kPillPadding = 10;
inline constexpr int kPillLockGlyph = 13;
inline constexpr int kPillLockGap = 6;
inline constexpr int kMoreButton = 32;
inline constexpr int kInUseDot = 6;
}  // namespace site_control_metrics

enum class SiteControlAction {
  kCopyUrl,
  kNewBoost,
  kSplit,
  kCapture,
  kSiteSettings,
  kClearSiteData,
};

enum class SitePermissionKind {
  kCamera,
  kMicrophone,
  kLocation,
  kNotifications,
  kPopups,
};

enum class SitePermissionSetting {
  kAsk,
  kAllow,
  kBlock,
};

struct SitePermissionRow {
  SitePermissionKind kind = SitePermissionKind::kCamera;
  SitePermissionSetting setting = SitePermissionSetting::kAsk;
  bool in_use = false;  // Draws the 6 pt in-use dot.
};

struct SiteControlExtensionItem {
  std::string id;
  std::u16string name;
  gfx::ImageSkia icon;
  std::u16string badge_text;
  SkColor badge_color = SkColorSetRGB(0xD9, 0x30, 0x25);
  bool enabled = true;
};

struct SiteControlState {
  std::u16string host;
  bool secure = true;
  bool boost_active = false;
  bool split_available = true;
  // Pinned and active extension actions for this tab, in toolbar order.
  std::vector<SiteControlExtensionItem> extensions;
  // Rows shown, in order (Track 6 omits kinds the site never asked for, or
  // passes all five).
  std::vector<SitePermissionRow> permissions;
  bool ad_block_available = true;
  bool ad_block_enabled = true;
  int ad_block_blocked_count = 0;
  // Solid panel body; empty uses Open's light/dark default.
  std::optional<SkColor> panel_color;
};

class SiteControlDelegate {
 public:
  virtual ~SiteControlDelegate() = default;

  virtual void OnSiteControlAction(SiteControlAction action) = 0;
  // Run the extension's action (ExtensionActionViewController::
  // ExecuteUserAction) and anchor any popup to `anchor`.
  virtual void OnSiteControlExtensionPressed(const std::string& extension_id,
                                             views::View* anchor) = 0;
  virtual void OnSiteControlPermissionChanged(
      SitePermissionKind kind,
      SitePermissionSetting setting) = 0;
  virtual void OnSiteControlAdBlockToggled(bool enabled) = 0;
  // The bubble closed (deactivation, Esc, or Close()).
  virtual void OnSiteControlClosed() {}
};

// The panel contents. Usable on its own (e.g. inside an automation snapshot)
// but normally created by OpenSiteControlBubble.
class OpenSiteControlView : public views::View,
                            public ui::SimpleMenuModel::Delegate {
  METADATA_HEADER(OpenSiteControlView, views::View)

 public:
  OpenSiteControlView(SiteControlDelegate* delegate,
                      const SiteControlState& state,
                      const secondary::Appearance& appearance);
  OpenSiteControlView(const OpenSiteControlView&) = delete;
  OpenSiteControlView& operator=(const OpenSiteControlView&) = delete;
  ~OpenSiteControlView() override;

  void SetState(const SiteControlState& state);
  const SiteControlState& state() const { return state_; }
  // Live counter: repaints the ad-block row only.
  void SetAdBlockState(bool enabled, int blocked_count);
  SkColor panel_color() const;

  // Extension tile for `extension_id` (popup anchor), or null.
  views::View* GetExtensionAnchor(const std::string& extension_id);

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMouseWheel(const ui::MouseWheelEvent& event) override;

  // ui::SimpleMenuModel::Delegate:
  void ExecuteCommand(int command_id, int event_flags) override;
  bool IsCommandIdChecked(int command_id) const override;

 private:
  void Rebuild();
  int ContentHeight() const;
  void ShowPermissionMenu(size_t row_index);

  void PaintActionTile(int index,
                       gfx::Canvas* canvas,
                       const gfx::Rect& bounds,
                       bool hovered);
  void PaintExtensionTile(size_t index,
                          gfx::Canvas* canvas,
                          const gfx::Rect& bounds,
                          bool hovered);
  void PaintPermissionRow(size_t index,
                          gfx::Canvas* canvas,
                          const gfx::Rect& bounds,
                          bool hovered);
  void PaintAdBlockRow(gfx::Canvas* canvas,
                       const gfx::Rect& bounds,
                       bool hovered);
  void PaintPill(gfx::Canvas* canvas, const gfx::Rect& bounds, bool hovered);
  void PaintRowCircle(gfx::Canvas* canvas,
                      const gfx::Rect& circle,
                      bool on,
                      secondary::Glyph glyph,
                      bool in_use);

  SkColor Color(SkColor light, SkColor dark) const {
    return appearance_.dark ? dark : light;
  }

  raw_ptr<SiteControlDelegate> delegate_;
  SiteControlState state_;
  secondary::Appearance appearance_;

  std::vector<raw_ptr<secondary::PaintedButton>> action_tiles_;
  std::vector<raw_ptr<secondary::PaintedButton>> extension_tiles_;
  std::vector<raw_ptr<secondary::PaintedButton>> permission_rows_;
  raw_ptr<secondary::PaintedButton> ad_block_row_ = nullptr;
  raw_ptr<secondary::PaintedButton> pill_ = nullptr;
  raw_ptr<secondary::GlyphButton> clear_button_ = nullptr;

  // Section label baselines and the separator, set by Layout().
  int extensions_label_y_ = -1;
  int permissions_label_y_ = -1;
  int separator_y_ = 0;
  int scroll_ = 0;

  size_t menu_row_ = 0;
  std::unique_ptr<ui::SimpleMenuModel> menu_model_;
  std::unique_ptr<views::MenuRunner> menu_runner_;
};

// Owns the bubble widget for one browser window.
class OpenSiteControlBubble {
 public:
  explicit OpenSiteControlBubble(SiteControlDelegate* delegate);
  OpenSiteControlBubble(const OpenSiteControlBubble&) = delete;
  OpenSiteControlBubble& operator=(const OpenSiteControlBubble&) = delete;
  ~OpenSiteControlBubble();

  // Opens anchored to `anchor` (the sidebar URL field's Site Controls button
  // or a pane bar's Site Control button). Reopening replaces the panel.
  void Show(views::View* anchor,
            const SiteControlState& state,
            const secondary::Appearance& appearance);
  void Close();
  bool IsShowing() const;

  void UpdateState(const SiteControlState& state);
  void SetAdBlockState(bool enabled, int blocked_count);

  OpenSiteControlView* contents() { return contents_; }
  views::Widget* widget() { return widget_.get(); }

 private:
  void OnWidgetClosed(views::Widget::ClosedReason reason);

  raw_ptr<SiteControlDelegate> delegate_;
  std::unique_ptr<views::BubbleDialogDelegate> bubble_delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<OpenSiteControlView> contents_ = nullptr;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_SITE_CONTROL_BUBBLE_H_
