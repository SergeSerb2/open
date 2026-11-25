// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenPeekOverlayView: Peek, a page shown over the current page without
// becoming a sidebar tab (docs/m4.md; PeekMetrics in
// Packages/OpenKit/Sources/OpenDesign/FeatureMetrics.swift;
// Packages/OpenKit/Sources/OpenFeatures/PeekOverlayView.swift).
//
// Look: a 0.70 scrim over the overlay, a card 80 % of the content panel's
// width (2 pt top and bottom inset) holding a live `views::WebView`, and
// three 33 pt round buttons right of the card at a 43 pt pitch: Close,
// Expand to a full tab (Cmd/Ctrl+O), Open in Split View.
//
// Card corner: 6 pt. This is PanelMetrics.cornerRadius, the value the Swift
// Peek clip uses and the one the F0090 panel-edge comparison matched with a
// 0.0 pt error (docs/m4.md "M4 peek, 1x"). The Track 5 brief listed 12 pt;
// the measured 6 pt wins under the Arc-parity rule.
//
// Hosting: the scrim takes clicks over the page, so the view lives in a
// `secondary::OverlayWidgetHost` (Alignment::kFill) covering the browser
// window's client area. `content_rect` is the page panel inside that overlay.
// Esc and Cmd/Ctrl+O are view accelerators; Track 6 forwards unhandled page
// key events to the FocusManager (as Chromium's BrowserView does).

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_PEEK_OVERLAY_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_PEEK_OVERLAY_VIEW_H_

#include <array>

#include "base/memory/raw_ptr.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/views/view.h"

namespace content {
class WebContents;
}  // namespace content

namespace views {
class WebView;
}  // namespace views

namespace open_unified {

namespace peek_metrics {
inline constexpr float kWidthFraction = 0.8f;
inline constexpr int kVerticalInset = 2;
inline constexpr int kButtonDiameter = 33;
inline constexpr int kButtonHitWidth = 35;
inline constexpr int kButtonGap = 13;
inline constexpr int kButtonTop = 9;
inline constexpr int kButtonPitch = 43;
inline constexpr int kCardCornerRadius = 6;
// Fitted F0090 shadow: opacity 0.18, radius 8 (blur 16), 2 pt down.
inline constexpr float kShadowAlpha = 0.18f;
inline constexpr float kShadowBlur = 16.f;
inline constexpr float kShadowOffsetY = 2.f;
}  // namespace peek_metrics

enum class PeekDismissReason {
  kEscape,
  kScrimClick,
  kCloseButton,
  kProgrammatic,
};

class PeekDelegate {
 public:
  virtual ~PeekDelegate() = default;

  // Esc, a scrim click or Close. Track 6 hides the overlay widget and closes
  // (or sleeps) the Peek WebContents.
  virtual void OnPeekDismissed(PeekDismissReason reason) = 0;
  // Expand button or Cmd/Ctrl+O: promote the page to a real sidebar tab.
  // Call ReleaseWebContents() to take the same WebContents (history, scroll
  // and form state survive) and attach it to the new tab's pane.
  virtual void OnPeekExpandToTab() = 0;
  // Open in Split View: same transfer, into a split beside the current tab.
  virtual void OnPeekOpenInSplit() = 0;
};

class OpenPeekOverlayView : public views::View {
  METADATA_HEADER(OpenPeekOverlayView, views::View)

 public:
  enum Button : int {
    kCloseButton = 0,
    kExpandButton,
    kSplitButton,
    kButtonCount,
  };

  explicit OpenPeekOverlayView(PeekDelegate* delegate);
  OpenPeekOverlayView(const OpenPeekOverlayView&) = delete;
  OpenPeekOverlayView& operator=(const OpenPeekOverlayView&) = delete;
  ~OpenPeekOverlayView() override;

  // Shows `contents` (not owned) in the card over `content_rect` (this
  // view's coordinates) and focuses the page.
  void Show(content::WebContents* contents, const gfx::Rect& content_rect);
  // Hides and detaches the page without destroying it.
  void Hide();
  bool is_showing() const { return showing_; }
  void SetContentRect(const gfx::Rect& content_rect);
  // Controls take the Space's light title color; the scrim its dark
  // background at 0.70 (BrowserWindowController peek styling).
  void SetAppearance(const secondary::Appearance& appearance);

  // Detaches and returns the Peek page for promotion; the overlay hides.
  content::WebContents* ReleaseWebContents();
  views::WebView* web_view() { return web_view_; }

  gfx::Rect card_bounds() const { return card_; }
  gfx::Rect GetButtonBounds(Button button) const;

  // Card frame for a content panel (PeekOverlayView.layout()).
  static gfx::Rect ComputeCardBounds(const gfx::Rect& content_rect);

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override;
  void Layout(PassKey) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override;
  bool CanHandleAccelerators() const override;

 private:
  void Dismiss(PeekDismissReason reason);
  void PressButton(Button button);

  raw_ptr<PeekDelegate> delegate_;
  raw_ptr<views::WebView> web_view_ = nullptr;
  std::array<raw_ptr<secondary::GlyphButton>, kButtonCount> buttons_{};
  secondary::Appearance appearance_;
  gfx::Rect content_rect_;
  gfx::Rect card_;
  bool showing_ = false;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_PEEK_OVERLAY_VIEW_H_
