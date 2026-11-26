// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/views/open_capture_overlay_view.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "cc/paint/paint_flags.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/cursor/cursor.h"
#include "ui/base/cursor/mojom/cursor_type.mojom-shared.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/border.h"

namespace open_unified {

namespace {

namespace m = capture_metrics;
using secondary::Glyph;
using secondary::GlyphButton;

constexpr char16_t kHintText[] =
    u"Click or drag to capture a portion of this page";

}  // namespace

// ===========================================================================
// OpenCaptureOverlayView
// ===========================================================================

OpenCaptureOverlayView::OpenCaptureOverlayView(CaptureOverlayDelegate* delegate)
    : delegate_(delegate) {
  SetFocusBehavior(FocusBehavior::ALWAYS);
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
  GetViewAccessibility().SetName(u"Capture area");

  AddAccelerator(ui::Accelerator(ui::VKEY_ESCAPE, ui::EF_NONE));
  AddAccelerator(ui::Accelerator(ui::VKEY_RETURN, ui::EF_NONE));
}

OpenCaptureOverlayView::~OpenCaptureOverlayView() = default;

void OpenCaptureOverlayView::SetAppearance(
    const secondary::Appearance& appearance) {
  appearance_ = appearance;
  SchedulePaint();
}

void OpenCaptureOverlayView::SetDeviceScaleFactor(float scale) {
  device_scale_factor_ = scale > 0.f ? scale : 1.f;
  SchedulePaint();
}

void OpenCaptureOverlayView::SetHoverElementCallback(
    HoverElementCallback callback) {
  hover_element_callback_ = std::move(callback);
}

void OpenCaptureOverlayView::SetHoveredElementRect(
    std::optional<gfx::Rect> rect) {
  if (finished_ || anchor_.has_value()) {
    return;
  }
  std::optional<gfx::Rect> clipped;
  if (rect.has_value()) {
    gfx::Rect r = gfx::IntersectRects(*rect, GetLocalBounds());
    if (r.width() >= 4 && r.height() >= 4) {
      clipped = r;
    }
  }
  if (hovered_element_ != clipped) {
    hovered_element_ = clipped;
    SchedulePaint();
  }
}

void OpenCaptureOverlayView::BeginSelectionAt(const gfx::Point& point) {
  if (finished_) {
    return;
  }
  pressed_element_ = hovered_element_;
  anchor_ = ClampPoint(point);
  selection_ = gfx::Rect(*anchor_, gfx::Size());
  hint_visible_ = false;
  SchedulePaint();
}

void OpenCaptureOverlayView::UpdateSelectionTo(const gfx::Point& point) {
  if (finished_ || !anchor_.has_value()) {
    return;
  }
  const gfx::Point clamped = ClampPoint(point);
  const int left = std::min(anchor_->x(), clamped.x());
  const int top = std::min(anchor_->y(), clamped.y());
  const int width = std::abs(clamped.x() - anchor_->x());
  const int height = std::abs(clamped.y() - anchor_->y());
  const gfx::Rect next(left, top, width, height);
  if (selection_ != next) {
    selection_ = next;
    SchedulePaint();
  }
}

void OpenCaptureOverlayView::EndSelection() {
  if (finished_) {
    return;
  }
  if (selection_.has_value() && selection_->width() >= m::kMinimumSelection &&
      selection_->height() >= m::kMinimumSelection) {
    FinishSelected(*selection_);
    return;
  }
  if (pressed_element_.has_value() &&
      (!selection_.has_value() ||
       (selection_->width() < m::kMinimumSelection &&
        selection_->height() < m::kMinimumSelection))) {
    gfx::Rect elem = gfx::IntersectRects(*pressed_element_, GetLocalBounds());
    if (elem.width() >= m::kMinimumSelection &&
        elem.height() >= m::kMinimumSelection) {
      FinishSelected(elem);
      return;
    }
  }
  FinishCancelled();
}

void OpenCaptureOverlayView::CaptureWholeViewport() {
  if (finished_) {
    return;
  }
  gfx::Rect bounds = GetLocalBounds();
  if (bounds.IsEmpty()) {
    FinishCancelled();
    return;
  }
  FinishSelected(bounds);
}

void OpenCaptureOverlayView::Cancel() {
  FinishCancelled();
}

void OpenCaptureOverlayView::Reset() {
  weak_factory_.InvalidateWeakPtrs();
  anchor_.reset();
  selection_.reset();
  hovered_element_.reset();
  pressed_element_.reset();
  pending_hover_point_.reset();
  hover_request_in_flight_ = false;
  hint_visible_ = true;
  finished_ = false;
  SchedulePaint();
}

std::u16string OpenCaptureOverlayView::FormatSizeBadgeText() const {
  if (!selection_.has_value()) {
    return std::u16string();
  }
  const int px_w = std::max(
      1, static_cast<int>(std::lround(selection_->width() *
                                      device_scale_factor_)));
  const int px_h = std::max(
      1, static_cast<int>(std::lround(selection_->height() *
                                      device_scale_factor_)));
  return base::NumberToString16(px_w) + u" \u00D7 " +
         base::NumberToString16(px_h);
}

gfx::Rect OpenCaptureOverlayView::ComputeSizeLabelBounds() const {
  if (!selection_.has_value() || selection_->IsEmpty()) {
    return gfx::Rect();
  }
  const gfx::FontList font =
      secondary::FontOfSize(m::kSizeLabelFontSize, gfx::Font::Weight::MEDIUM);
  const std::u16string text = FormatSizeBadgeText();
  const int width = secondary::TextWidth(text, font) + 2 * m::kSizeLabelPadding;
  const int height = m::kSizeLabelHeight;
  const gfx::Rect bounds = GetLocalBounds();

  int x = selection_->CenterPoint().x() - width / 2;
  x = std::clamp(x, 0, std::max(0, bounds.width() - width));

  int y = selection_->bottom() + m::kSizeLabelGap;
  if (y + height > bounds.height()) {
    y = selection_->y() - m::kSizeLabelGap - height;
  }
  if (y < 0) {
    y = std::max(0, selection_->bottom() - m::kSizeLabelGap - height);
  }
  return gfx::Rect(x, y, width, height);
}

void OpenCaptureOverlayView::OnPaint(gfx::Canvas* canvas) {
  const gfx::Rect bounds = GetLocalBounds();
  if (bounds.IsEmpty()) {
    return;
  }

  canvas->Save();
  // Clip scrim to the web content panel's rounded corners.
  SkPathBuilder clip_builder;
  clip_builder.addRRect(SkRRect::MakeRectXY(
      gfx::RectToSkRect(bounds), static_cast<float>(m::kPanelCornerRadius),
      static_cast<float>(m::kPanelCornerRadius)));
  canvas->ClipPath(clip_builder.detach(), /*do_anti_alias=*/true);

  const SkColor dim_color = secondary::WithAlpha(SK_ColorBLACK, m::kDimAlpha);

  if (selection_.has_value() && !selection_->IsEmpty()) {
    // Even-odd fill dims everything outside the selection cutout cleanly.
    SkPathBuilder scrim(SkPathFillType::kEvenOdd);
    scrim.addRect(gfx::RectToSkRect(bounds));
    scrim.addRect(gfx::RectToSkRect(*selection_));
    cc::PaintFlags scrim_flags;
    scrim_flags.setStyle(cc::PaintFlags::kFill_Style);
    scrim_flags.setColor(dim_color);
    canvas->DrawPath(scrim.detach(), scrim_flags);

    // Outer dark hairline + inner bright hairline around the selection.
    const gfx::RectF sel_f(*selection_);
    {
      cc::PaintFlags outer;
      outer.setStyle(cc::PaintFlags::kStroke_Style);
      outer.setStrokeWidth(m::kEdgeWidth);
      outer.setColor(secondary::WithAlpha(SK_ColorBLACK, 0.25f));
      gfx::RectF outer_rect = sel_f;
      outer_rect.Outset(m::kEdgeWidth / 2.f);
      canvas->DrawRect(outer_rect, outer);
    }
    {
      cc::PaintFlags inner;
      inner.setStyle(cc::PaintFlags::kStroke_Style);
      inner.setStrokeWidth(m::kEdgeWidth);
      inner.setColor(secondary::WithAlpha(SK_ColorWHITE, 0.95f));
      gfx::RectF inner_rect = sel_f;
      inner_rect.Inset(m::kEdgeWidth / 2.f);
      canvas->DrawRect(inner_rect, inner);
    }

    // Live W x H pixel dimension badge.
    const gfx::Rect badge_rect = ComputeSizeLabelBounds();
    if (!badge_rect.IsEmpty()) {
      secondary::FillRoundRect(canvas, gfx::RectF(badge_rect),
                               m::kSizeLabelRadius,
                               secondary::WithAlpha(SK_ColorBLACK, 0.65f));
      const gfx::FontList font = secondary::FontOfSize(
          m::kSizeLabelFontSize, gfx::Font::Weight::MEDIUM);
      secondary::DrawText(canvas, FormatSizeBadgeText(), font, SK_ColorWHITE,
                          badge_rect, gfx::Canvas::TEXT_ALIGN_CENTER);
    }
  } else if (hovered_element_.has_value() && !hovered_element_->IsEmpty()) {
    // Hovered element cutout with white rounded outline.
    const SkRRect hole = SkRRect::MakeRectXY(
        gfx::RectToSkRect(*hovered_element_), m::kElementOutlineRadius,
        m::kElementOutlineRadius);
    SkPathBuilder scrim(SkPathFillType::kEvenOdd);
    scrim.addRect(gfx::RectToSkRect(bounds));
    scrim.addRRect(hole);
    cc::PaintFlags scrim_flags;
    scrim_flags.setAntiAlias(true);
    scrim_flags.setStyle(cc::PaintFlags::kFill_Style);
    scrim_flags.setColor(dim_color);
    canvas->DrawPath(scrim.detach(), scrim_flags);

    gfx::RectF outline_rect(*hovered_element_);
    outline_rect.Outset(m::kElementOutlineWidth / 2.f);
    secondary::StrokeRoundRect(
        canvas, outline_rect,
        m::kElementOutlineRadius + m::kElementOutlineWidth / 2.f, SK_ColorWHITE,
        m::kElementOutlineWidth);
  } else {
    canvas->FillRect(bounds, dim_color);
  }

  // Top-center hint capsule before the drag begins.
  if (hint_visible_) {
    const gfx::FontList hint_font =
        secondary::FontOfSize(m::kHintFontSize, gfx::Font::Weight::MEDIUM);
    const int hint_width =
        secondary::TextWidth(kHintText, hint_font) + 2 * m::kHintPadding;
    const gfx::Rect hint_rect((bounds.width() - hint_width) / 2, m::kHintTop,
                              hint_width, m::kHintHeight);
    secondary::FillRoundRectGradient(canvas, gfx::RectF(hint_rect),
                                     m::kHintRadius, appearance_.toast_fill_top,
                                     appearance_.toast_fill_bottom);
    secondary::DrawText(canvas, kHintText, hint_font, appearance_.toast_text,
                        hint_rect, gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  canvas->Restore();
}

ui::Cursor OpenCaptureOverlayView::GetCursor(const ui::MouseEvent& event) {
  return ui::mojom::CursorType::kCross;
}

bool OpenCaptureOverlayView::OnMousePressed(const ui::MouseEvent& event) {
  if (!event.IsOnlyLeftMouseButton()) {
    return false;
  }
  RequestFocus();
  BeginSelectionAt(event.location());
  return true;
}

bool OpenCaptureOverlayView::OnMouseDragged(const ui::MouseEvent& event) {
  UpdateSelectionTo(event.location());
  return true;
}

void OpenCaptureOverlayView::OnMouseReleased(const ui::MouseEvent& event) {
  UpdateSelectionTo(event.location());
  EndSelection();
}

void OpenCaptureOverlayView::OnMouseMoved(const ui::MouseEvent& event) {
  QueryHoverElement(event.location());
}

void OpenCaptureOverlayView::OnMouseCaptureLost() {
  if (anchor_.has_value() && !finished_) {
    FinishCancelled();
  }
}

bool OpenCaptureOverlayView::OnKeyPressed(const ui::KeyEvent& event) {
  if (event.key_code() == ui::VKEY_ESCAPE) {
    Cancel();
    return true;
  }
  if (event.key_code() == ui::VKEY_RETURN) {
    CaptureWholeViewport();
    return true;
  }
  return false;
}

bool OpenCaptureOverlayView::AcceleratorPressed(
    const ui::Accelerator& accelerator) {
  if (finished_) {
    return false;
  }
  if (accelerator.key_code() == ui::VKEY_ESCAPE) {
    Cancel();
    return true;
  }
  if (accelerator.key_code() == ui::VKEY_RETURN) {
    CaptureWholeViewport();
    return true;
  }
  return false;
}

bool OpenCaptureOverlayView::CanHandleAccelerators() const {
  return !finished_ && views::View::CanHandleAccelerators();
}

gfx::Point OpenCaptureOverlayView::ClampPoint(const gfx::Point& p) const {
  const gfx::Rect bounds = GetLocalBounds();
  return gfx::Point(std::clamp(p.x(), 0, std::max(0, bounds.width())),
                    std::clamp(p.y(), 0, std::max(0, bounds.height())));
}

void OpenCaptureOverlayView::QueryHoverElement(const gfx::Point& p) {
  if (finished_ || anchor_.has_value() || !hover_element_callback_) {
    return;
  }
  if (hover_request_in_flight_) {
    pending_hover_point_ = p;
    return;
  }
  hover_request_in_flight_ = true;
  hover_element_callback_.Run(
      ClampPoint(p),
      base::BindOnce(&OpenCaptureOverlayView::OnHoverElementResult,
                     weak_factory_.GetWeakPtr()));
}

void OpenCaptureOverlayView::OnHoverElementResult(
    std::optional<gfx::Rect> rect) {
  hover_request_in_flight_ = false;
  SetHoveredElementRect(std::move(rect));
  if (pending_hover_point_.has_value() && !finished_ && !anchor_.has_value()) {
    gfx::Point next = *pending_hover_point_;
    pending_hover_point_.reset();
    QueryHoverElement(next);
  }
}

void OpenCaptureOverlayView::FinishSelected(const gfx::Rect& rect) {
  if (finished_) {
    return;
  }
  finished_ = true;
  if (delegate_) {
    delegate_->OnCaptureRegionSelected(rect);
  }
}

void OpenCaptureOverlayView::FinishCancelled() {
  if (finished_) {
    return;
  }
  finished_ = true;
  if (delegate_) {
    delegate_->OnCaptureOverlayCancelled();
  }
}

BEGIN_METADATA(OpenCaptureOverlayView)
END_METADATA

// ===========================================================================
// CaptureResultCardModel
// ===========================================================================

CaptureResultCardModel::CaptureResultCardModel() = default;
CaptureResultCardModel::CaptureResultCardModel(const CaptureResultCardModel&) =
    default;
CaptureResultCardModel::CaptureResultCardModel(
    CaptureResultCardModel&&) noexcept = default;
CaptureResultCardModel& CaptureResultCardModel::operator=(
    const CaptureResultCardModel&) = default;
CaptureResultCardModel& CaptureResultCardModel::operator=(
    CaptureResultCardModel&&) noexcept = default;
CaptureResultCardModel::~CaptureResultCardModel() = default;

// ===========================================================================
// OpenCaptureResultCard
// ===========================================================================

OpenCaptureResultCard::OpenCaptureResultCard(
    CaptureResultCardDelegate* delegate,
    const CaptureResultCardModel& model,
    const secondary::Appearance& appearance)
    : delegate_(delegate), model_(model), appearance_(appearance) {
  SetBorder(views::CreateEmptyBorder(gfx::Insets(m::kCardShadowMargin)));
  SetNotifyEnterExitOnChild(true);
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
  GetViewAccessibility().SetName(u"Page Capture Result");
  RebuildButtons();
}

OpenCaptureResultCard::~OpenCaptureResultCard() {
  dismiss_timer_.Stop();
}

void OpenCaptureResultCard::SetModel(const CaptureResultCardModel& model) {
  model_ = model;
  RebuildButtons();
  PreferredSizeChanged();
  InvalidateLayout();
  SchedulePaint();
}

void OpenCaptureResultCard::SetAppearance(
    const secondary::Appearance& appearance) {
  appearance_ = appearance;
  UpdateButtonColors();
  SchedulePaint();
}

void OpenCaptureResultCard::StartAutoDismissTimer(base::TimeDelta lifetime) {
  remaining_lifetime_ = lifetime;
  dismiss_timer_.Stop();
  if (hovered_ || !remaining_lifetime_.is_positive()) {
    return;
  }
  timer_started_at_ = base::TimeTicks::Now();
  dismiss_timer_.Start(
      FROM_HERE, remaining_lifetime_,
      base::BindOnce(&OpenCaptureResultCard::OnAutoDismissTimeout,
                     base::Unretained(this)));
}

void OpenCaptureResultCard::PauseAutoDismissTimer() {
  if (!dismiss_timer_.IsRunning()) {
    return;
  }
  const base::TimeDelta elapsed = base::TimeTicks::Now() - timer_started_at_;
  remaining_lifetime_ =
      std::max(base::TimeDelta(), remaining_lifetime_ - elapsed);
  dismiss_timer_.Stop();
}

void OpenCaptureResultCard::ResumeAutoDismissTimer() {
  if (hovered_) {
    return;
  }
  const base::TimeDelta delay =
      std::max(remaining_lifetime_, m::kCardHoverResume);
  StartAutoDismissTimer(delay);
}

// static
gfx::Size OpenCaptureResultCard::ComputeThumbnailSize(
    const gfx::Size& pixel_size) {
  const int max_w = m::kCardWidth - 2 * m::kCardPadding;
  const int max_h = m::kThumbnailMaxHeight;
  if (pixel_size.width() <= 0 || pixel_size.height() <= 0) {
    return gfx::Size(max_w, 120);
  }
  const double scale =
      std::min(static_cast<double>(max_w) / pixel_size.width(),
               static_cast<double>(max_h) / pixel_size.height());
  return gfx::Size(
      std::max(1, static_cast<int>(std::lround(pixel_size.width() * scale))),
      std::max(1, static_cast<int>(std::lround(pixel_size.height() * scale))));
}

// static
gfx::Rect OpenCaptureResultCard::ComputeAnchor(const gfx::Rect& content_rect) {
  return gfx::Rect(content_rect.x(), content_rect.y() + m::kAnchorTop,
                   std::max(0, content_rect.width() - m::kAnchorTrailing),
                   std::max(0, content_rect.height() - m::kAnchorTop));
}

gfx::Size OpenCaptureResultCard::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  const gfx::Size thumb = ComputeThumbnailSize(model_.pixel_size);
  int h = m::kCardPadding + thumb.height();
  if (model_.saved_to_library && !model_.subtitle.empty()) {
    h += m::kLineGap + m::kSavedLineHeight;
  }
  if (!model_.note.empty()) {
    h += m::kLineGap + m::kSavedLineHeight;
  }
  h += m::kLineGap + m::kButtonSize + m::kCardPadding;
  const gfx::Insets insets = GetInsets();
  return gfx::Size(m::kCardWidth + insets.width(), h + insets.height());
}

void OpenCaptureResultCard::Layout(PassKey) {
  const gfx::Rect card = CardRect();
  const int content_w = std::max(0, card.width() - 2 * m::kCardPadding);

  const gfx::Size thumb = ComputeThumbnailSize(model_.pixel_size);
  thumbnail_rect_ = gfx::Rect(card.x() + (card.width() - thumb.width()) / 2,
                              card.y() + m::kCardPadding, thumb.width(),
                              thumb.height());

  // Compact dismiss button tucked at the top-right corner of the card.
  if (dismiss_button_) {
    constexpr int kDismissSize = 22;
    dismiss_button_->SetBoundsRect(
        gfx::Rect(card.right() - m::kCardPadding / 2 - kDismissSize,
                  card.y() + m::kCardPadding / 2, kDismissSize, kDismissSize));
  }

  int y = thumbnail_rect_.bottom();
  if (model_.saved_to_library && !model_.subtitle.empty()) {
    y += m::kLineGap;
    subtitle_rect_ =
        gfx::Rect(card.x() + m::kCardPadding, y, content_w, m::kSavedLineHeight);
    y += m::kSavedLineHeight;
  } else {
    subtitle_rect_ = gfx::Rect();
  }

  if (!model_.note.empty()) {
    y += m::kLineGap;
    note_rect_ =
        gfx::Rect(card.x() + m::kCardPadding, y, content_w, m::kSavedLineHeight);
    y += m::kSavedLineHeight;
  } else {
    note_rect_ = gfx::Rect();
  }

  y += m::kLineGap;
  const int count = static_cast<int>(action_buttons_.size());
  const int row_w =
      count * m::kButtonSize + std::max(0, count - 1) * m::kButtonGap;
  int x = card.x() + (card.width() - row_w) / 2;
  for (auto& button : action_buttons_) {
    button->SetBoundsRect(gfx::Rect(x, y, m::kButtonSize, m::kButtonSize));
    x += m::kButtonSize + m::kButtonGap;
  }
}

void OpenCaptureResultCard::OnPaint(gfx::Canvas* canvas) {
  const gfx::Rect card = CardRect();
  if (card.IsEmpty()) {
    return;
  }

  const SkColor body_fill = appearance_.dark ? SkColorSetRGB(0x23, 0x24, 0x2B)
                                             : SkColorSetRGB(0xFA, 0xFA, 0xFC);
  const SkColor border_color = appearance_.dark
                                   ? secondary::WithAlpha(SK_ColorWHITE, 0.12f)
                                   : secondary::WithAlpha(SK_ColorBLACK, 0.10f);
  const SkColor secondary_text =
      appearance_.dark ? secondary::WithAlpha(SK_ColorWHITE, 0.65f)
                       : secondary::WithAlpha(SK_ColorBLACK, 0.55f);

  secondary::FillRoundRectWithShadow(
      canvas, gfx::RectF(card), m::kCardRadius, body_fill,
      secondary::WithAlpha(SK_ColorBLACK, m::kCardShadowAlpha),
      m::kCardShadowOffsetY, m::kCardShadowBlur);
  secondary::StrokeRoundRect(canvas, gfx::RectF(card), m::kCardRadius,
                             border_color, 1.f);

  // Clipped rounded thumbnail.
  if (!thumbnail_rect_.IsEmpty()) {
    canvas->Save();
    SkPathBuilder thumb_clip;
    thumb_clip.addRRect(SkRRect::MakeRectXY(
        gfx::RectToSkRect(thumbnail_rect_), m::kThumbnailRadius,
        m::kThumbnailRadius));
    canvas->ClipPath(thumb_clip.detach(), /*do_anti_alias=*/true);

    // Subtle backing behind transparent PNGs.
    canvas->FillRect(thumbnail_rect_,
                     appearance_.dark ? SkColorSetRGB(0x16, 0x17, 0x1D)
                                      : SkColorSetRGB(0xEC, 0xED, 0xF2));
    if (!model_.thumbnail.isNull()) {
      secondary::DrawImageInRect(canvas, model_.thumbnail, thumbnail_rect_);
    }
    canvas->Restore();

    secondary::StrokeRoundRect(
        canvas, gfx::RectF(thumbnail_rect_), m::kThumbnailRadius,
        appearance_.dark ? secondary::WithAlpha(SK_ColorWHITE, 0.08f)
                         : secondary::WithAlpha(SK_ColorBLACK, 0.08f),
        1.f);
  }

  const gfx::FontList line_font =
      secondary::FontOfSize(m::kSavedLineFontSize, gfx::Font::Weight::NORMAL);
  if (!subtitle_rect_.IsEmpty()) {
    secondary::DrawText(canvas, model_.subtitle, line_font, secondary_text,
                        subtitle_rect_, gfx::Canvas::TEXT_ALIGN_CENTER);
  }
  if (!note_rect_.IsEmpty()) {
    secondary::DrawText(canvas, model_.note, line_font, secondary_text,
                        note_rect_, gfx::Canvas::TEXT_ALIGN_CENTER);
  }
}

void OpenCaptureResultCard::OnMouseEntered(const ui::MouseEvent& event) {
  if (hovered_) {
    return;
  }
  hovered_ = true;
  PauseAutoDismissTimer();
  if (delegate_) {
    delegate_->OnCaptureResultHoverChanged(true);
  }
}

void OpenCaptureResultCard::OnMouseExited(const ui::MouseEvent& event) {
  if (!hovered_) {
    return;
  }
  hovered_ = false;
  ResumeAutoDismissTimer();
  if (delegate_) {
    delegate_->OnCaptureResultHoverChanged(false);
  }
}

bool OpenCaptureResultCard::OnMousePressed(const ui::MouseEvent& event) {
  // Consume clicks on the card body so they never fall through to the page.
  return CardRect().Contains(event.location());
}

void OpenCaptureResultCard::RebuildButtons() {
  RemoveAllChildViews();
  action_buttons_.clear();
  action_specs_.clear();
  dismiss_button_ = nullptr;

  action_specs_.push_back({CaptureResultAction::kCopy, Glyph::kCopy, u"Copy"});
  action_specs_.push_back(
      {CaptureResultAction::kSaveAs, Glyph::kExpand, u"Save As\u2026"});
  if (model_.saved_to_library) {
    action_specs_.push_back({CaptureResultAction::kOpenInLibrary, Glyph::kSquare,
                             u"Open in Library"});
    if (model_.can_add_to_easel) {
      action_specs_.push_back(
          {CaptureResultAction::kAddToEasel, Glyph::kPlus, u"Add to Easel"});
    }
    if (model_.can_retake) {
      action_specs_.push_back(
          {CaptureResultAction::kRetake, Glyph::kReload, u"Retake"});
    }
    action_specs_.push_back(
        {CaptureResultAction::kDelete, Glyph::kTrash, u"Delete"});
  }

  for (const auto& spec : action_specs_) {
    auto button = std::make_unique<GlyphButton>(
        base::BindRepeating(&OpenCaptureResultCard::OnButtonPressed,
                            base::Unretained(this), spec.action),
        spec.glyph, spec.tooltip);
    button->SetTooltipText(spec.tooltip);
    button->SetGlyphSize(m::kButtonSymbolSize);
    action_buttons_.push_back(AddChildView(std::move(button)));
  }

  auto dismiss = std::make_unique<GlyphButton>(
      base::BindRepeating(&OpenCaptureResultCard::OnButtonPressed,
                          base::Unretained(this), CaptureResultAction::kDismiss),
      Glyph::kClose, u"Dismiss");
  dismiss->SetTooltipText(u"Dismiss");
  dismiss->SetGlyphSize(10.f);
  dismiss_button_ = AddChildView(std::move(dismiss));

  UpdateButtonColors();
}

void OpenCaptureResultCard::UpdateButtonColors() {
  const SkColor glyph_color =
      appearance_.dark ? secondary::WithAlpha(SK_ColorWHITE, 0.88f)
                       : secondary::WithAlpha(SK_ColorBLACK, 0.85f);
  const SkColor hover_fill = appearance_.dark
                                 ? secondary::WithAlpha(SK_ColorWHITE, 0.12f)
                                 : secondary::WithAlpha(SK_ColorBLACK, 0.07f);
  for (auto& button : action_buttons_) {
    button->SetGlyphColor(glyph_color);
    button->SetPlate(GlyphButton::Plate::kHoverRounded, SK_ColorTRANSPARENT,
                     m::kButtonRadius);
    button->SetHoverFill(hover_fill);
  }
  if (dismiss_button_) {
    dismiss_button_->SetGlyphColor(SK_ColorWHITE);
    dismiss_button_->SetPlate(GlyphButton::Plate::kCircle,
                              secondary::WithAlpha(SK_ColorBLACK, 0.55f), 11.f);
    dismiss_button_->SetHoverFill(secondary::WithAlpha(SK_ColorBLACK, 0.78f));
  }
}

void OpenCaptureResultCard::OnButtonPressed(CaptureResultAction action) {
  if (delegate_) {
    delegate_->OnCaptureResultAction(action);
  }
}

void OpenCaptureResultCard::OnAutoDismissTimeout() {
  if (delegate_) {
    delegate_->OnCaptureResultAction(CaptureResultAction::kDismiss);
  }
}

gfx::Rect OpenCaptureResultCard::CardRect() const {
  gfx::Rect r = GetLocalBounds();
  r.Inset(GetInsets());
  return r;
}

BEGIN_METADATA(OpenCaptureResultCard)
END_METADATA

}  // namespace open_unified
