// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_peek_overlay_view.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "content/public/browser/web_contents.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/rounded_corners_f.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/controls/webview/webview.h"

namespace open_unified {

namespace {

using secondary::Glyph;
using secondary::GlyphButton;
namespace m = peek_metrics;

}  // namespace

OpenPeekOverlayView::OpenPeekOverlayView(PeekDelegate* delegate)
    : delegate_(delegate) {
  SetVisible(false);
  GetViewAccessibility().SetRole(ax::mojom::Role::kDialog);
  GetViewAccessibility().SetName(u"Peek");

  web_view_ = AddChildView(std::make_unique<views::WebView>());

  struct Spec {
    Glyph glyph;
    const char16_t* name;
    float glyph_size;
  };
  // Close (xmark), Expand (arrows out), Open in Split View; F0090 glyph ink
  // 12, 14 and 14 px.
  const std::array<Spec, kButtonCount> specs = {{
      {Glyph::kClose, u"Close", 12.f},
      {Glyph::kExpand, u"Open as Tab", 14.f},
      {Glyph::kSplit, u"Open in Split View", 15.f},
  }};
  for (int i = 0; i < kButtonCount; ++i) {
    auto button = std::make_unique<GlyphButton>(
        base::BindRepeating(&OpenPeekOverlayView::PressButton,
                            base::Unretained(this), static_cast<Button>(i)),
        specs[i].glyph, specs[i].name);
    button->SetGlyphSize(specs[i].glyph_size);
    buttons_[i] = AddChildView(std::move(button));
  }
  SetAppearance(appearance_);

  AddAccelerator(ui::Accelerator(ui::VKEY_ESCAPE, ui::EF_NONE));
  AddAccelerator(ui::Accelerator(ui::VKEY_O, secondary::kPrimaryModifier));
}

OpenPeekOverlayView::~OpenPeekOverlayView() {
  web_view_->SetWebContents(nullptr);
}

// static
gfx::Rect OpenPeekOverlayView::ComputeCardBounds(
    const gfx::Rect& content_rect) {
  const int width =
      static_cast<int>(std::lround(content_rect.width() * m::kWidthFraction));
  return gfx::Rect(content_rect.x() + (content_rect.width() - width) / 2,
                   content_rect.y() + m::kVerticalInset, width,
                   std::max(0, content_rect.height() - 2 * m::kVerticalInset));
}

void OpenPeekOverlayView::Show(content::WebContents* contents,
                               const gfx::Rect& content_rect) {
  content_rect_ = content_rect;
  showing_ = true;
  if (web_view_->web_contents() != contents) {
    web_view_->SetWebContents(contents);
  }
  SetVisible(true);
  InvalidateLayout();
  SchedulePaint();
  web_view_->RequestFocus();
}

void OpenPeekOverlayView::Hide() {
  showing_ = false;
  SetVisible(false);
  web_view_->SetWebContents(nullptr);
}

void OpenPeekOverlayView::SetContentRect(const gfx::Rect& content_rect) {
  if (content_rect_ == content_rect) {
    return;
  }
  content_rect_ = content_rect;
  InvalidateLayout();
  SchedulePaint();
}

void OpenPeekOverlayView::SetAppearance(
    const secondary::Appearance& appearance) {
  appearance_ = appearance;
  for (auto& button : buttons_) {
    button->SetPlate(GlyphButton::Plate::kCircle, appearance_.peek_controls,
                     m::kButtonDiameter / 2.f);
    button->SetGlyphColor(appearance_.peek_glyph);
    button->SetHoverFill(secondary::WithAlpha(SK_ColorWHITE, 0.10f));
  }
  SchedulePaint();
}

content::WebContents* OpenPeekOverlayView::ReleaseWebContents() {
  content::WebContents* contents = web_view_->web_contents();
  Hide();
  return contents;
}

gfx::Rect OpenPeekOverlayView::GetButtonBounds(Button button) const {
  return buttons_[button]->bounds();
}

void OpenPeekOverlayView::Layout(PassKey) {
  card_ = ComputeCardBounds(content_rect_);
  web_view_->SetBoundsRect(card_);
  web_view_->holder()->SetNativeViewCornerRadii(
      gfx::RoundedCornersF(m::kCardCornerRadius));
  for (int i = 0; i < kButtonCount; ++i) {
    buttons_[i]->SetBoundsRect(
        gfx::Rect(card_.right() + m::kButtonGap,
                  card_.y() + m::kButtonTop + i * m::kButtonPitch,
                  m::kButtonHitWidth, m::kButtonDiameter));
  }
}

void OpenPeekOverlayView::OnPaint(gfx::Canvas* canvas) {
  if (!showing_) {
    return;
  }
  canvas->FillRect(GetLocalBounds(), appearance_.peek_scrim);
  // Card backing and shadow; the page paints over the backing.
  secondary::FillRoundRectWithShadow(
      canvas, gfx::RectF(card_), m::kCardCornerRadius, SK_ColorBLACK,
      secondary::WithAlpha(SK_ColorBLACK, m::kShadowAlpha), m::kShadowOffsetY,
      m::kShadowBlur);
}

bool OpenPeekOverlayView::OnMousePressed(const ui::MouseEvent& event) {
  // Only the scrim reaches here: the page and buttons take their own clicks.
  if (showing_ && !card_.Contains(event.location())) {
    Dismiss(PeekDismissReason::kScrimClick);
    return true;
  }
  return false;
}

bool OpenPeekOverlayView::AcceleratorPressed(
    const ui::Accelerator& accelerator) {
  if (!showing_) {
    return false;
  }
  if (accelerator.key_code() == ui::VKEY_ESCAPE) {
    Dismiss(PeekDismissReason::kEscape);
    return true;
  }
  if (accelerator.key_code() == ui::VKEY_O) {
    PressButton(kExpandButton);
    return true;
  }
  return false;
}

bool OpenPeekOverlayView::CanHandleAccelerators() const {
  return showing_ && views::View::CanHandleAccelerators();
}

void OpenPeekOverlayView::Dismiss(PeekDismissReason reason) {
  if (!showing_) {
    return;
  }
  if (delegate_) {
    delegate_->OnPeekDismissed(reason);
  }
}

void OpenPeekOverlayView::PressButton(Button button) {
  if (!showing_ || !delegate_) {
    return;
  }
  switch (button) {
    case kCloseButton:
      Dismiss(PeekDismissReason::kCloseButton);
      break;
    case kExpandButton:
      delegate_->OnPeekExpandToTab();
      break;
    case kSplitButton:
      delegate_->OnPeekOpenInSplit();
      break;
    case kButtonCount:
      break;
  }
}

BEGIN_METADATA(OpenPeekOverlayView)
END_METADATA

}  // namespace open_unified
