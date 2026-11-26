// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_link_status_bubble.h"

#include <algorithm>
#include <cmath>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "cc/paint/paint_flags.h"
#include "open_unified/ui/design/open_theme_shader.h"
#include "open_unified/ui/design/open_typography.h"
#include "open_unified/ui/views/open_tab_tree_view.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/compositor/layer.h"
#include "ui/compositor/layer_animator.h"
#include "ui/gfx/animation/tween.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/text_elider.h"
#include "ui/gfx/text_utils.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/animation/animation_builder.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

namespace lm = link_status_metrics;

const gfx::FontList& BubbleFont() {
  return typography::Get(typography::OpenFont::kTooltip);
}

}  // namespace

OpenLinkStatusBubbleView::OpenLinkStatusBubbleView() {
  SetPaintToLayer();
  layer()->SetFillsBoundsOpaquely(false);
  // Pointer events reach the page under the capsule.
  SetCanProcessEventsWithinSubtree(false);
  // The hovered URL never reaches accessibility.
  GetViewAccessibility().SetIsIgnored(true);
  SetVisible(false);
}

OpenLinkStatusBubbleView::~OpenLinkStatusBubbleView() = default;

// static
std::u16string OpenLinkStatusBubbleView::DisplayText(const GURL& url) {
  if (!url.is_valid() || url.is_empty()) {
    return std::u16string();
  }
  std::string spec = url.spec();
  for (std::string_view scheme : {"https://", "http://"}) {
    if (base::StartsWith(spec, scheme, base::CompareCase::INSENSITIVE_ASCII)) {
      spec.erase(0, scheme.size());
      break;
    }
  }
  return base::UTF8ToUTF16(spec);
}

void OpenLinkStatusBubbleView::SetTargetUrl(const GURL& url,
                                            const OpenSpaceThemeState& theme) {
  SetStatusText(DisplayText(url), theme);
}

void OpenLinkStatusBubbleView::SetStatusText(
    const std::u16string& text,
    const OpenSpaceThemeState& theme) {
  std::u16string trimmed;
  base::TrimWhitespace(text, base::TRIM_ALL, &trimmed);
  if (trimmed.empty()) {
    // The pointer left the link.
    Hide(/*animated=*/true);
    return;
  }
  Show(trimmed, theme);
}

void OpenLinkStatusBubbleView::Show(const std::u16string& text,
                                    const OpenSpaceThemeState& theme) {
  ++generation_;
  showing_ = true;
  const SkColor fill = theme::ToSkColor(theme.style.TooltipFill());
  const SkColor color = theme::ToSkColor(theme.style.TooltipText());
  const bool changed = text != text_ || fill != fill_ || color != text_color_;
  text_ = text;
  fill_ = fill;
  text_color_ = color;
  // A running fade is dropped: the capsule shows at once.
  layer()->GetAnimator()->AbortAllAnimations();
  layer()->SetOpacity(1.0f);
  if (changed) {
    PreferredSizeChanged();
    SchedulePaint();
  }
  ApplyPageArea();
  SetVisible(!bounds().IsEmpty() || !page_area_.has_value());
}

void OpenLinkStatusBubbleView::Hide(bool animated) {
  ++generation_;
  showing_ = false;
  if (!animated || !GetVisible() || !GetWidget()) {
    FinishHide(generation_);
    return;
  }
  const int token = generation_;
  views::AnimationBuilder()
      .SetPreemptionStrategy(ui::LayerAnimator::PreemptionStrategy::
                                 IMMEDIATELY_ANIMATE_TO_NEW_TARGET)
      .OnEnded(base::BindOnce(&OpenLinkStatusBubbleView::FinishHide,
                              weak_factory_.GetWeakPtr(), token))
      .Once()
      .SetDuration(lm::kFadeOut)
      .SetOpacity(layer(), 0.0f, gfx::Tween::EASE_OUT);
}

void OpenLinkStatusBubbleView::FinishHide(int generation) {
  if (generation != generation_) {
    return;
  }
  layer()->GetAnimator()->AbortAllAnimations();
  SetVisible(false);
  layer()->SetOpacity(1.0f);
  // Hidden, it keeps no URL.
  text_.clear();
}

bool OpenLinkStatusBubbleView::IsShowing() const {
  return showing_ && GetVisible();
}

int OpenLinkStatusBubbleView::TextWidth() const {
  return text_.empty() ? 0 : gfx::GetStringWidth(text_, BubbleFont());
}

gfx::Size OpenLinkStatusBubbleView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  return gfx::Size(TextWidth() + 2 * lm::kPadding, lm::kHeight);
}

gfx::Rect OpenLinkStatusBubbleView::PreferredBoundsInParent(
    const gfx::Rect& parent_bounds) const {
  const int area_w = parent_bounds.width();
  const int limit = std::max(
      0, std::min(area_w - 2 * lm::kLeadingInset,
                  static_cast<int>(std::floor(area_w * lm::kMaxWidthShare))));
  const int width = std::min(limit, TextWidth() + 2 * lm::kPadding);
  if (width < 2 * lm::kPadding || text_.empty()) {
    return gfx::Rect();
  }
  return gfx::Rect(parent_bounds.x() + lm::kLeadingInset,
                   parent_bounds.bottom() - lm::kBottomInset - lm::kHeight,
                   width, lm::kHeight);
}

void OpenLinkStatusBubbleView::SetPageArea(
    const gfx::Rect& page_area_in_parent) {
  page_area_ = page_area_in_parent;
  ApplyPageArea();
  if (showing_) {
    SetVisible(!bounds().IsEmpty());
  }
}

void OpenLinkStatusBubbleView::ApplyPageArea() {
  if (page_area_) {
    SetBoundsRect(PreferredBoundsInParent(*page_area_));
  }
}

void OpenLinkStatusBubbleView::OnPaint(gfx::Canvas* canvas) {
  if (text_.empty() || bounds().IsEmpty()) {
    return;
  }
  const gfx::RectF capsule(GetLocalBounds());
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(fill_);
  canvas->DrawRoundRect(capsule, capsule.height() / 2, flags);
  // Label inset (padding - 2) on each side, as the Swift label frame.
  const gfx::FontList& font = BubbleFont();
  const int text_x = lm::kPadding - 2;
  const int text_w = std::max(0, width() - 2 * lm::kPadding + 4);
  const std::u16string elided =
      gfx::ElideText(text_, font, text_w, gfx::ELIDE_MIDDLE);
  const int line = font.GetHeight();
  canvas->DrawStringRectWithFlags(
      elided, font, text_color_,
      gfx::Rect(text_x, (height() - line) / 2, text_w, line),
      gfx::Canvas::TEXT_ALIGN_LEFT | gfx::Canvas::NO_SUBPIXEL_RENDERING);
}

BEGIN_METADATA(OpenLinkStatusBubbleView)
END_METADATA

}  // namespace open_unified
