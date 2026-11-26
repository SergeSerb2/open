// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenLittleOpenView: the Little Open window (Open's floating quick browser).
//
// Sources: LittleOpenMetrics in Packages/OpenKit/Sources/OpenDesign/
// Metrics.swift (capture session 2 item 19, interaction-states §20.10),
// Packages/OpenKit/Sources/OpenFeatures/LittleOpenTitleBarView.swift,
// CommandBarMetrics.littleOpen* and docs/m4.md.
//
// Two modes:
//   kBar  — 490 × 329 floating window holding Little Open's embedded command
//           bar (an OpenCommandBarView presented in CommandBarMode::
//           kLittleOpen, passed in through SetBarContents()).
//   kPage — after navigation: 1185 × 832 default (min 360 × 240 page), a
//           47 pt #272A37 title bar over the live page.
//
// Title bar (page mode): window buttons at x 9 / 32 / 55, the Profile switcher
// chip and host inside a #3D3D4A capsule (radius 8), Downloads progress
// indicator, Extension Actions strip, Copy URL, and the #050627 "Open in
// <Space>" pill (188 × 30, radius 15) with the target Space color dot,
// Cmd/Ctrl+O keycap, and chevron opening the Space target picker.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_LITTLE_OPEN_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_LITTLE_OPEN_VIEW_H_

#include <algorithm>
#include <array>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/views/view.h"
#include "url/gurl.h"

namespace content {
class WebContents;
}  // namespace content

namespace views {
class BubbleDialogDelegate;
class WebView;
class Widget;
class WidgetDelegate;
}  // namespace views

namespace open_unified {

namespace little_open_metrics {
inline constexpr gfx::Size kBarSize{490, 329};
inline constexpr int kScreenInset = 20;
inline constexpr gfx::Size kPageSize{1185, 832};
inline constexpr gfx::Size kMinimumPageSize{360, 240};
inline constexpr int kTitleBarHeight = 47;
inline constexpr int kWindowCornerRadius = 12;
inline constexpr std::array<int, 3> kWindowButtonX = {9, 32, 55};
inline constexpr int kWindowButtonY = 16;
inline constexpr int kWindowButtonSize = 16;
inline constexpr SkColor kTitleBarFill = SkColorSetRGB(0x27, 0x2A, 0x37);
inline constexpr SkColor kCapsuleFill = SkColorSetRGB(0x3D, 0x3D, 0x4A);
inline constexpr SkColor kPillFill = SkColorSetRGB(0x05, 0x06, 0x27);
// White ≈ 0.8; host 13 Regular, Profile 13 Medium.
inline constexpr SkColor kText = SkColorSetARGB(0xCC, 0xFF, 0xFF, 0xFF);
inline constexpr int kFontSize = 13;
inline constexpr int kCapsuleRadius = 8;
inline constexpr int kPillRadius = 15;
inline constexpr gfx::Rect kProfileIcon{97, 17, 14, 14};
inline constexpr int kProfileTextX = 114;
inline constexpr int kHostY = 15;  // 15.5 in points; text box is 16 tall.
inline constexpr int kHostHeight = 17;
inline constexpr int kHostGap = 8;
inline constexpr int kMaximumProfileWidth = 140;
inline constexpr int kMinimumHostWidth = 36;
inline constexpr float kDividerAlpha = 0.2f;
inline constexpr int kKeycapWidth = 27;
inline constexpr int kKeycapRadius = 4;
inline constexpr int kAccessoryPitch = 24;
inline constexpr int kMaxExtensionStripButtons = 4;
// Space / Profile picker (S2 19/0023).
inline constexpr int kPickerWidth = 244;
inline constexpr int kPickerHeader = 46;
inline constexpr int kPickerRowHeight = 46;
inline constexpr int kPickerInset = 8;
inline constexpr int kPickerIconSize = 30;
inline constexpr int kPickerIconRadius = 7;
inline constexpr int kPickerVisibleRows = 8;

// Width-relative frames (top-left origin, window coordinates).
inline gfx::Rect Capsule(int w) {
  return {84, 8, std::max(0, w - 289), 31};
}
inline gfx::Rect Copy(int w) {
  return {w - 228, 16, 16, 16};
}
inline gfx::Rect Extensions(int w) {
  return {w - 252, 16, 16, 16};
}
inline gfx::Rect Pill(int w) {
  return {w - 196, 8, 188, 30};
}
inline gfx::Rect PillLabel(int w) {
  return {w - 191, 15, 148, 17};
}
inline gfx::Rect Chevron(int w) {
  return {w - 29, 15, 16, 16};
}
inline gfx::Rect Divider(int w) {
  return {w - 37, 14, 1, 18};
}
}  // namespace little_open_metrics

struct LittleOpenSpaceChoice {
  SpaceID id;
  std::u16string title;
  std::optional<SpaceIcon> icon;
  SkColor color = SkColorSetRGB(0x49, 0x47, 0x5A);
  ProfileID profile_id;
  bool is_target = false;
};

struct LittleOpenProfileChoice {
  ProfileID id;
  std::u16string name;
  std::optional<SpaceIcon> icon;
  SkColor color = SkColorSetRGB(0x49, 0x47, 0x5A);
  bool active = false;
};

struct LittleOpenExtensionAction {
  std::string id;
  std::u16string name;
  gfx::ImageSkia icon;
  std::u16string badge_text;
  bool enabled = true;
};

struct LittleOpenState {
  std::u16string host;  // Without "www."; Track 6 strips it.
  std::u16string profile_name;
  std::optional<SpaceIcon> profile_icon;
  bool show_profile = false;
  // "Open in <space_title>"; empty disables the pill.
  std::optional<std::u16string> space_title;
  std::vector<LittleOpenSpaceChoice> spaces;
  bool show_extensions = false;

  // Wave E4 additions (all defaulted for full backward compatibility):
  ProfileID active_profile_id;
  std::optional<SpaceID> target_space_id;
  SkColor target_space_color = SkColorSetRGB(0x6F, 0x66, 0xD9);
  std::optional<SpaceIcon> target_space_icon;
  std::vector<LittleOpenProfileChoice> profiles;
  bool show_downloads = false;
  bool downloads_running = false;
  // 0.0..1.0 determinate download progress; nullopt = indeterminate ring.
  std::optional<double> download_progress;
  int active_download_count = 0;
  std::vector<LittleOpenExtensionAction> extension_actions;
};

class LittleOpenDelegate {
 public:
  virtual ~LittleOpenDelegate() = default;

  // The pill or Cmd/Ctrl+O (`space_id` empty: the routed default Space), or a
  // picker row. Track 6 moves the live page into that Space as a sidebar tab
  // via OpenTabBridge::AdoptLiveWebContentsAsTab and closes Little Open.
  virtual void OnLittleOpenOpenInSpace(std::optional<SpaceID> space_id) = 0;
  // A click on the host: edit the URL (Track 6 presents the command bar).
  virtual void OnLittleOpenEditUrl() = 0;
  virtual void OnLittleOpenCopyUrl() = 0;
  virtual void OnLittleOpenProfile(views::View* anchor) = 0;
  virtual void OnLittleOpenExtensions(views::View* anchor) = 0;
  // The window is closing (close button, OS close, Widget::Close()).
  virtual void OnLittleOpenClosed() = 0;

  // Optional Wave E4 callbacks (default no-op for backward compatibility):

  // User picked a different Profile from the Little Open Profile switcher pill.
  virtual void OnLittleOpenProfileSelected(const ProfileID& profile_id) {}
  // User changed the target Space for the "Open in <Space>" pill.
  virtual void OnLittleOpenTargetSpaceChanged(const SpaceID& space_id) {}
  // User clicked the compact Downloads indicator button.
  virtual void OnLittleOpenDownloads(views::View* anchor) {}
  // User clicked one of the pinned Extension action buttons in the strip.
  virtual void OnLittleOpenExtensionAction(const std::string& extension_id,
                                           views::View* anchor) {}
  // Fired when Little Open closes WITHOUT being moved to the main window, so
  // the browser can record the URL in Archive/History and respect auto-archive.
  virtual void OnLittleOpenArchiveOnClose(const GURL& url,
                                          const std::u16string& title,
                                          const ProfileID& profile_id) {}
};

class OpenLittleOpenView : public views::View {
  METADATA_HEADER(OpenLittleOpenView, views::View)

 public:
  enum class Mode {
    kBar,
    kPage,
  };

  using MoveToSpaceCallback =
      base::RepeatingCallback<void(std::unique_ptr<content::WebContents>,
                                   std::optional<SpaceID>)>;
  using ArchiveOnCloseCallback =
      base::RepeatingCallback<void(const GURL& url,
                                   const std::u16string& title,
                                   const ProfileID& profile_id)>;

  explicit OpenLittleOpenView(LittleOpenDelegate* delegate);
  OpenLittleOpenView(const OpenLittleOpenView&) = delete;
  OpenLittleOpenView& operator=(const OpenLittleOpenView&) = delete;
  ~OpenLittleOpenView() override;

  // Bar window: top-right of the work area, 20 pt inset (guess beyond S2).
  static gfx::Rect DefaultBarBounds(const gfx::Rect& work_area);
  // Page window: grows left and down from the bar's top-right corner,
  // clamped to the work area (S2 19/0011).
  static gfx::Rect PageBoundsFromBar(const gfx::Rect& bar_bounds,
                                     const gfx::Rect& work_area);

  void SetMode(Mode mode);
  Mode mode() const { return mode_; }
  void SetState(const LittleOpenState& state);
  const LittleOpenState& state() const { return state_; }

  // Bar mode contents (Little Open's OpenCommandBarView). Owned.
  void SetBarContents(std::unique_ptr<views::View> contents);
  views::View* bar_contents() { return bar_contents_; }

  // Page mode: non-owning attachment (backward compatible).
  void SetWebContents(content::WebContents* contents);
  // Page mode: owned attachment for zero-reload ReleaseWebContents() transfer.
  void SetOwnedWebContents(std::unique_ptr<content::WebContents> contents);
  // Detaches the live WebContents without destroying or reloading it so
  // "Move to Open" (Cmd/Ctrl+O) can transfer it straight into
  // OpenTabBridge::AdoptLiveWebContentsAsTab(). Marks the page as promoted so
  // closing Little Open will not double-archive it.
  std::unique_ptr<content::WebContents> ReleaseWebContents();
  // Detaches a non-owned WebContents* and marks the page as promoted.
  content::WebContents* DetachWebContents();
  void MarkPromoted() { promoted_to_main_ = true; }
  bool promoted_to_main() const { return promoted_to_main_; }

  // Optional direct callbacks (alternative to overriding LittleOpenDelegate).
  void SetMoveToSpaceCallback(MoveToSpaceCallback callback);
  void SetArchiveOnCloseCallback(ArchiveOnCloseCallback callback);

  // Called by OpenLittleOpenWindow's WidgetDelegate on window close; triggers
  // archive-on-close when the page was not promoted to the main window.
  void NotifyWindowClosing();

  views::WebView* web_view() { return web_view_; }

  // HTCAPTION over empty title bar areas, HTCLIENT elsewhere.
  int NonClientHitTest(const gfx::Point& point) const;

  // Title bar element frames for automation ("capsule", "profile", "host",
  // "downloads", "copy", "extensions", "pill", "open", "chevron", "divider").
  std::optional<gfx::Rect> GetElementBounds(std::string_view name) const;

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override;
  void Layout(PassKey) override;
  gfx::Size GetMinimumSize() const override;
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override;

 private:
  void LayoutTitleBar();
  void RebuildExtensionActionButtons();
  void TriggerOpenInSpace(std::optional<SpaceID> space_id);
  void PaintPill(gfx::Canvas* canvas, const gfx::Rect& bounds, bool hovered);
  void PaintProfile(gfx::Canvas* canvas, const gfx::Rect& bounds, bool hovered);
  void PaintHost(gfx::Canvas* canvas, const gfx::Rect& bounds, bool hovered);
  void PaintDownloads(gfx::Canvas* canvas,
                      const gfx::Rect& bounds,
                      bool hovered);
  void PaintExtensionAction(size_t index,
                            gfx::Canvas* canvas,
                            const gfx::Rect& bounds,
                            bool hovered);
  void PaintWindowButton(int index,
                         gfx::Canvas* canvas,
                         const gfx::Rect& bounds,
                         bool hovered);
  void PressWindowButton(int index);
  void ShowSpacePicker();
  void OnSpacePickerClosed();
  void ShowProfilePicker();
  void OnProfilePickerClosed();
  int ProfileTextWidth() const;
  std::u16string KeycapLabel() const;

  raw_ptr<LittleOpenDelegate> delegate_;
  Mode mode_ = Mode::kBar;
  LittleOpenState state_;

  std::array<raw_ptr<secondary::PaintedButton>, 3> window_buttons_{};
  raw_ptr<secondary::PaintedButton> profile_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> host_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> downloads_button_ = nullptr;
  std::vector<raw_ptr<secondary::PaintedButton>> extension_action_buttons_;
  raw_ptr<secondary::GlyphButton> copy_button_ = nullptr;
  raw_ptr<secondary::GlyphButton> extensions_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> pill_button_ = nullptr;
  raw_ptr<secondary::GlyphButton> chevron_button_ = nullptr;
  raw_ptr<views::WebView> web_view_ = nullptr;
  raw_ptr<views::View> bar_contents_ = nullptr;

  std::unique_ptr<content::WebContents> owned_contents_;
  bool promoted_to_main_ = false;
  bool archive_notified_ = false;
  MoveToSpaceCallback move_to_space_callback_;
  ArchiveOnCloseCallback archive_on_close_callback_;

  // Space picker bubble, client-owned (delegate outlives its widget).
  std::unique_ptr<views::BubbleDialogDelegate> picker_delegate_;
  std::unique_ptr<views::Widget> picker_widget_;

  // Profile switcher bubble, client-owned.
  std::unique_ptr<views::BubbleDialogDelegate> profile_picker_delegate_;
  std::unique_ptr<views::Widget> profile_picker_widget_;

  base::WeakPtrFactory<OpenLittleOpenView> weak_factory_{this};
};

// Owns one Little Open window: the frameless widget and its WidgetDelegate
// (Chromium 156 reserves widget-owned delegates for a friend list, so the
// delegate is client-owned and declared first, so it outlives the widget).
// Close the window with widget()->Close(); OnLittleOpenClosed() then arrives
// on the next task, where Track 6 may delete this object.
class OpenLittleOpenWindow {
 public:
  static std::unique_ptr<OpenLittleOpenWindow> Create(
      LittleOpenDelegate* delegate,
      const gfx::Rect& bounds_in_screen,
      OpenLittleOpenView::Mode mode);
  OpenLittleOpenWindow(const OpenLittleOpenWindow&) = delete;
  OpenLittleOpenWindow& operator=(const OpenLittleOpenWindow&) = delete;
  ~OpenLittleOpenWindow();

  views::Widget* widget() { return widget_.get(); }
  OpenLittleOpenView* view() { return view_; }
  void Show();

 private:
  OpenLittleOpenWindow();

  std::unique_ptr<views::WidgetDelegate> delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<OpenLittleOpenView> view_ = nullptr;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_LITTLE_OPEN_VIEW_H_
