// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenWindowControlsView: native-style client-side window caption controls for
// Windows 11 Fluent (46 x 32 DIP flush cluster) and Linux CSD (28 x 28 DIP
// circular hover plates with desktop-ordered leading/trailing clusters).

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_WINDOW_CONTROLS_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_WINDOW_CONTROLS_VIEW_H_

#include <vector>

#include "base/memory/raw_ptr.h"
#include "open_unified/browser/platform/open_platform.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/views/view.h"

namespace gfx {
class Point;
class Size;
}  // namespace gfx

namespace views {
class Button;
}  // namespace views

namespace open_unified {

class OpenWindowControlsView : public views::View {
  METADATA_HEADER(OpenWindowControlsView, views::View)

 public:
  enum class Mode { kWindowsFluent, kLinuxCsd };

  explicit OpenWindowControlsView(
      Mode mode,
      std::vector<WindowControlButton> buttons =
          {WindowControlButton::kMinimize, WindowControlButton::kMaximize,
           WindowControlButton::kClose},
      bool allow_maximize = true);
  OpenWindowControlsView(const OpenWindowControlsView&) = delete;
  OpenWindowControlsView& operator=(const OpenWindowControlsView&) = delete;
  ~OpenWindowControlsView() override;

  // Updates foreground/hover styling for the active Space's content appearance,
  // window active state, and OS high-contrast setting.
  void SetThemeState(bool dark_content,
                     bool window_active,
                     bool increase_contrast);

  // Toggles the Maximize button between Maximize and Restore glyph/label.
  void SetMaximized(bool maximized);

  // Returns HTMINBUTTON, HTMAXBUTTON, HTCLOSE, or HTNOWHERE for a point in
  // this view's local coordinate space.
  int HitTestCode(const gfx::Point& point_in_this) const;

  Mode mode() const { return mode_; }
  bool dark_content() const { return dark_content_; }
  bool window_active() const { return window_active_; }
  bool increase_contrast() const { return increase_contrast_; }
  bool maximized() const { return maximized_; }

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;

 private:
  struct ButtonSlot {
    WindowControlButton kind;
    raw_ptr<views::Button> button = nullptr;
  };

  void UpdateMaximizeMetadata();

  Mode mode_;
  bool dark_content_ = true;
  bool window_active_ = true;
  bool increase_contrast_ = false;
  bool maximized_ = false;
  std::vector<ButtonSlot> buttons_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_WINDOW_CONTROLS_VIEW_H_
