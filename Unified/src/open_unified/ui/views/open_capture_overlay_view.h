// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Page Capture UI views (1:1 parity with OpenDesign/CaptureTokens.swift,
// OpenFeatures/Capture/CaptureOverlayView.swift, and CaptureResultView.swift):
//
//   - OpenCaptureOverlayView: full-panel dim scrim (alpha 0.35), crosshair
//     cursor, top hint capsule, hover element highlight, drag-to-select
//     cutout with inner/outer hairline edge and live W x H pixel dimension
//     badge, Esc to cancel, Return to capture full viewport.
//   - OpenCaptureResultCard: floating top-right preview card with rounded
//     thumbnail, "Saved to Library" / note subtitle, hover-pausing 8s
//     auto-dismiss timer, and action buttons (Copy, Save As, Open in Library,
//     Add to Easel, Retake, Delete, Dismiss).

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_CAPTURE_OVERLAY_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_CAPTURE_OVERLAY_VIEW_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/views/view.h"

namespace open_unified {

namespace capture_metrics {
inline constexpr float kDimAlpha = 0.35f;
inline constexpr float kEdgeWidth = 1.f;
inline constexpr float kElementOutlineWidth = 2.f;
inline constexpr float kElementOutlineRadius = 8.f;
inline constexpr int kMinimumSelection = 8;
inline constexpr int kPanelCornerRadius = 6;

inline constexpr int kSizeLabelHeight = 20;
inline constexpr float kSizeLabelRadius = 5.f;
inline constexpr int kSizeLabelPadding = 7;
inline constexpr int kSizeLabelGap = 6;
inline constexpr int kSizeLabelFontSize = 11;

inline constexpr int kHintHeight = 28;
inline constexpr float kHintRadius = 14.f;
inline constexpr int kHintPadding = 14;
inline constexpr int kHintTop = 16;
inline constexpr int kHintFontSize = 13;

// Result card (CaptureMetrics in CaptureTokens.swift).
inline constexpr int kCardWidth = 248;
inline constexpr int kCardPadding = 12;
inline constexpr float kCardRadius = 12.f;
inline constexpr float kCardShadowAlpha = 0.25f;
inline constexpr float kCardShadowBlur = 16.f;
inline constexpr float kCardShadowOffsetY = 6.f;
inline constexpr int kCardShadowMargin = 18;
inline constexpr int kThumbnailMaxHeight = 160;
inline constexpr float kThumbnailRadius = 8.f;
inline constexpr int kSavedLineFontSize = 11;
inline constexpr int kSavedLineHeight = 14;
inline constexpr int kLineGap = 8;
inline constexpr int kButtonSize = 28;
inline constexpr float kButtonRadius = 6.f;
inline constexpr int kButtonGap = 6;
inline constexpr float kButtonSymbolSize = 14.f;
inline constexpr int kAnchorTrailing = 10;
inline constexpr int kAnchorTop = 8;
inline constexpr base::TimeDelta kCardLifetime = base::Seconds(8);
inline constexpr base::TimeDelta kCardHoverResume = base::Seconds(2);
}  // namespace capture_metrics

// ===========================================================================
// Region Selection Overlay
// ===========================================================================

class CaptureOverlayDelegate {
 public:
  virtual ~CaptureOverlayDelegate() = default;

  // Called with the selected region in overlay view DIPs (top-left origin).
  virtual void OnCaptureRegionSelected(const gfx::Rect& selection_in_view) = 0;
  // Called when the user presses Esc, drags a tiny area with no hovered
  // element, or cancels programmatically.
  virtual void OnCaptureOverlayCancelled() = 0;
};

class OpenCaptureOverlayView : public views::View {
  METADATA_HEADER(OpenCaptureOverlayView, views::View)

 public:
  // Optional async probe for click-to-capture hovered DOM element bounds.
  using HoverElementCallback = base::RepeatingCallback<void(
      const gfx::Point& point_in_view,
      base::OnceCallback<void(std::optional<gfx::Rect>)> reply)>;

  explicit OpenCaptureOverlayView(CaptureOverlayDelegate* delegate);
  OpenCaptureOverlayView(const OpenCaptureOverlayView&) = delete;
  OpenCaptureOverlayView& operator=(const OpenCaptureOverlayView&) = delete;
  ~OpenCaptureOverlayView() override;

  void SetAppearance(const secondary::Appearance& appearance);
  // Device scale factor used to display pixel dimensions in the W x H badge.
  void SetDeviceScaleFactor(float scale);
  void SetHoverElementCallback(HoverElementCallback callback);
  void SetHoveredElementRect(std::optional<gfx::Rect> rect);

  // Programmatic / forwarded-drag controls (also useful for Cmd+Shift drag).
  void BeginSelectionAt(const gfx::Point& point);
  void UpdateSelectionTo(const gfx::Point& point);
  void EndSelection();
  void CaptureWholeViewport();
  void Cancel();
  void Reset();

  bool is_dragging() const { return anchor_.has_value(); }
  const std::optional<gfx::Rect>& selection() const { return selection_; }
  const std::optional<gfx::Rect>& hovered_element() const {
    return hovered_element_;
  }
  gfx::Rect ComputeSizeLabelBounds() const;
  std::u16string FormatSizeBadgeText() const;

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool OnMouseDragged(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseMoved(const ui::MouseEvent& event) override;
  void OnMouseCaptureLost() override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override;
  bool CanHandleAccelerators() const override;

 private:
  gfx::Point ClampPoint(const gfx::Point& p) const;
  void QueryHoverElement(const gfx::Point& p);
  void OnHoverElementResult(std::optional<gfx::Rect> rect);
  void FinishSelected(const gfx::Rect& rect);
  void FinishCancelled();

  raw_ptr<CaptureOverlayDelegate> delegate_;
  secondary::Appearance appearance_;
  float device_scale_factor_ = 1.f;
  HoverElementCallback hover_element_callback_;

  std::optional<gfx::Point> anchor_;
  std::optional<gfx::Rect> selection_;
  std::optional<gfx::Rect> hovered_element_;
  std::optional<gfx::Rect> pressed_element_;
  bool hint_visible_ = true;
  bool finished_ = false;
  bool hover_request_in_flight_ = false;
  std::optional<gfx::Point> pending_hover_point_;

  base::WeakPtrFactory<OpenCaptureOverlayView> weak_factory_{this};
};

// ===========================================================================
// Floating Capture Result Card
// ===========================================================================

enum class CaptureResultAction {
  kCopy,
  kSaveAs,
  kOpenInLibrary,
  kAddToEasel,
  kRetake,
  kDelete,
  kDismiss,
};

struct CaptureResultCardModel {
  CaptureResultCardModel();
  CaptureResultCardModel(const CaptureResultCardModel&);
  CaptureResultCardModel(CaptureResultCardModel&&) noexcept;
  CaptureResultCardModel& operator=(const CaptureResultCardModel&);
  CaptureResultCardModel& operator=(CaptureResultCardModel&&) noexcept;
  ~CaptureResultCardModel();

  gfx::ImageSkia thumbnail;
  gfx::Size pixel_size;
  base::FilePath saved_path;
  bool saved_to_library = true;
  bool can_retake = false;
  bool can_add_to_easel = true;
  std::u16string subtitle = u"Saved to Library";
  std::u16string note;
};

class CaptureResultCardDelegate {
 public:
  virtual ~CaptureResultCardDelegate() = default;

  virtual void OnCaptureResultAction(CaptureResultAction action) = 0;
  virtual void OnCaptureResultHoverChanged(bool hovered) {}
};

class OpenCaptureResultCard : public views::View {
  METADATA_HEADER(OpenCaptureResultCard, views::View)

 public:
  OpenCaptureResultCard(CaptureResultCardDelegate* delegate,
                        const CaptureResultCardModel& model,
                        const secondary::Appearance& appearance);
  OpenCaptureResultCard(const OpenCaptureResultCard&) = delete;
  OpenCaptureResultCard& operator=(const OpenCaptureResultCard&) = delete;
  ~OpenCaptureResultCard() override;

  void SetModel(const CaptureResultCardModel& model);
  void SetAppearance(const secondary::Appearance& appearance);
  const CaptureResultCardModel& model() const { return model_; }

  // Starts/resets the 8 s auto-dismiss timer (pauses while hovered).
  void StartAutoDismissTimer(
      base::TimeDelta lifetime = capture_metrics::kCardLifetime);
  void PauseAutoDismissTimer();
  void ResumeAutoDismissTimer();
  bool is_hovered() const { return hovered_; }

  // Computes aspect-fit thumbnail size inside 224 x 160.
  static gfx::Size ComputeThumbnailSize(const gfx::Size& pixel_size);
  // Anchor rect for OverlayWidgetHost::SetAnchor(..., kTopRight).
  static gfx::Rect ComputeAnchor(const gfx::Rect& content_rect);

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  void OnMouseEntered(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;

 private:
  struct ActionSpec {
    CaptureResultAction action;
    secondary::Glyph glyph;
    const char16_t* tooltip;
  };

  void RebuildButtons();
  void UpdateButtonColors();
  void OnButtonPressed(CaptureResultAction action);
  void OnAutoDismissTimeout();
  gfx::Rect CardRect() const;

  raw_ptr<CaptureResultCardDelegate> delegate_;
  CaptureResultCardModel model_;
  secondary::Appearance appearance_;

  std::vector<ActionSpec> action_specs_;
  std::vector<raw_ptr<secondary::GlyphButton>> action_buttons_;
  raw_ptr<secondary::GlyphButton> dismiss_button_ = nullptr;

  gfx::Rect thumbnail_rect_;
  gfx::Rect subtitle_rect_;
  gfx::Rect note_rect_;

  bool hovered_ = false;
  base::TimeDelta remaining_lifetime_ = capture_metrics::kCardLifetime;
  base::TimeTicks timer_started_at_;
  base::OneShotTimer dismiss_timer_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_CAPTURE_OVERLAY_VIEW_H_
