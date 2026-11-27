// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_window_controls_view.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "cc/paint/paint_flags.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_metrics.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/hit_test.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/point_f.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/size.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/controls/button/button.h"
#include "ui/views/widget/widget.h"

namespace open_unified {

namespace {

namespace wc = metrics::win_controls;

class CaptionButton : public views::Button {
  METADATA_HEADER(CaptionButton, views::Button)

 public:
  CaptionButton(const OpenWindowControlsView* owner,
                WindowControlButton kind,
                PressedCallback callback)
      : views::Button(std::move(callback)), owner_(owner), kind_(kind) {
    SetFocusBehavior(FocusBehavior::ACCESSIBLE_ONLY);
    SetInstallFocusRingOnFocus(false);
    SetRequestFocusOnPress(false);
    SetHasInkDropActionOnClick(false);
  }
  CaptionButton(const CaptionButton&) = delete;
  CaptionButton& operator=(const CaptionButton&) = delete;
  ~CaptionButton() override = default;

  // views::Button:
  void StateChanged(ButtonState old_state) override {
    views::Button::StateChanged(old_state);
    SchedulePaint();
  }

  void OnFocus() override {
    views::Button::OnFocus();
    SchedulePaint();
  }

  void OnBlur() override {
    views::Button::OnBlur();
    SchedulePaint();
  }

  void PaintButtonContents(gfx::Canvas* canvas) override {
    const bool is_close = (kind_ == WindowControlButton::kClose);
    const bool is_linux =
        owner_->mode() == OpenWindowControlsView::Mode::kLinuxCsd;
    const bool dark = owner_->dark_content();
    const bool active = owner_->window_active();
    const bool high_contrast = owner_->increase_contrast();
    const ButtonState state = GetState();
    const bool hovered = (state == STATE_HOVERED);
    const bool pressed = (state == STATE_PRESSED);
    const bool focused = HasFocus();

    const gfx::RectF bounds(GetLocalBounds());

    // 1. Background fill (Windows flush rect or Linux 24x24 circular plate).
    SkColor fill_color = SK_ColorTRANSPARENT;
    if (is_linux) {
      if (is_close) {
        if (pressed) {
          fill_color = SkColorSetARGB(242, 0xC0, 0x16, 0x1E);
        } else if (hovered) {
          fill_color = SkColorSetARGB(217, 0xE0, 0x1B, 0x24);
        }
      } else if (dark) {
        if (pressed) {
          fill_color = SkColorSetARGB(41, 0xFF, 0xFF, 0xFF);
        } else if (hovered) {
          fill_color = SkColorSetARGB(26, 0xFF, 0xFF, 0xFF);
        }
      } else {
        if (pressed) {
          fill_color = SkColorSetARGB(33, 0x00, 0x00, 0x00);
        } else if (hovered) {
          fill_color = SkColorSetARGB(20, 0x00, 0x00, 0x00);
        }
      }
    } else {
      if (is_close) {
        if (pressed) {
          fill_color = SkColorSetRGB(0xB2, 0x27, 0x19);
        } else if (hovered) {
          fill_color = SkColorSetRGB(0xC4, 0x2B, 0x1C);
        }
      } else if (dark) {
        if (pressed) {
          fill_color = SkColorSetARGB(33, 0xFF, 0xFF, 0xFF);  // 0.13
        } else if (hovered) {
          fill_color = SkColorSetARGB(20, 0xFF, 0xFF, 0xFF);  // 0.08
        }
      } else {
        if (pressed) {
          fill_color = SkColorSetARGB(26, 0x00, 0x00, 0x00);  // 0.10
        } else if (hovered) {
          fill_color = SkColorSetARGB(15, 0x00, 0x00, 0x00);  // 0.06
        }
      }
    }

    if (SkColorGetA(fill_color) > 0) {
      cc::PaintFlags fill_flags;
      fill_flags.setAntiAlias(is_linux);
      fill_flags.setStyle(cc::PaintFlags::kFill_Style);
      fill_flags.setColor(fill_color);
      if (is_linux) {
        const float plate = static_cast<float>(wc::kLinuxButtonPlate);
        const float cx = bounds.CenterPoint().x();
        const float cy = bounds.CenterPoint().y();
        canvas->DrawCircle(gfx::PointF(cx, cy), plate * 0.5f, fill_flags);
      } else {
        canvas->DrawRect(bounds, fill_flags);
      }
    }

    // 2. Glyph color.
    SkColor glyph_color = SK_ColorWHITE;
    if (is_close && (hovered || pressed)) {
      glyph_color = SK_ColorWHITE;
    } else if (high_contrast) {
      const uint8_t alpha = active ? 255 : 191;
      glyph_color = dark ? SkColorSetARGB(alpha, 0xFF, 0xFF, 0xFF)
                         : SkColorSetARGB(alpha, 0x00, 0x00, 0x00);
    } else if (dark) {
      // Dark Space: #FFFFFF @ 0.88 active, 0.45 inactive.
      const uint8_t alpha = active ? 224 : 115;
      glyph_color = SkColorSetARGB(alpha, 0xFF, 0xFF, 0xFF);
    } else {
      // Light Space: #000000 @ 0.85 active, 0.45 inactive.
      const uint8_t alpha = active ? 217 : 115;
      glyph_color = SkColorSetARGB(alpha, 0x00, 0x00, 0x00);
    }

    // 3. High-contrast / keyboard focus 1 DIP outline.
    if ((high_contrast && (hovered || pressed || focused)) || focused) {
      cc::PaintFlags outline;
      outline.setAntiAlias(true);
      outline.setStyle(cc::PaintFlags::kStroke_Style);
      outline.setStrokeWidth(1.0f);
      outline.setColor(glyph_color);
      if (is_linux) {
        const float radius = static_cast<float>(wc::kLinuxButtonPlate) * 0.5f -
                             0.5f;
        canvas->DrawCircle(bounds.CenterPoint(), radius, outline);
      } else {
        gfx::RectF stroke_rect = bounds;
        stroke_rect.Inset(0.5f);
        canvas->DrawRect(stroke_rect, outline);
      }
    }

    // 4. Crisp physical-pixel-snapped glyph.
    glyphs::Glyph glyph = glyphs::Glyph::kWindowClose;
    switch (kind_) {
      case WindowControlButton::kMinimize:
        glyph = glyphs::Glyph::kWindowMinimize;
        break;
      case WindowControlButton::kMaximize:
        glyph = owner_->maximized() ? glyphs::Glyph::kWindowRestore
                                    : glyphs::Glyph::kWindowMaximize;
        break;
      case WindowControlButton::kClose:
        glyph = glyphs::Glyph::kWindowClose;
        break;
    }
    glyphs::DrawWindowControlGlyph(canvas, glyph, bounds, glyph_color,
                                   is_linux);
  }

 private:
  raw_ptr<const OpenWindowControlsView> owner_;
  WindowControlButton kind_;
};

BEGIN_METADATA(CaptionButton)
END_METADATA

int HitTestForButton(WindowControlButton kind) {
  switch (kind) {
    case WindowControlButton::kMinimize:
      return HTMINBUTTON;
    case WindowControlButton::kMaximize:
      return HTMAXBUTTON;
    case WindowControlButton::kClose:
      return HTCLOSE;
  }
  return HTNOWHERE;
}

}  // namespace

OpenWindowControlsView::OpenWindowControlsView(
    Mode mode,
    std::vector<WindowControlButton> buttons,
    bool allow_maximize)
    : mode_(mode) {
  // Paint directly onto the parent OpenBrowserView surface (no extra layer).
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);

  for (WindowControlButton kind : buttons) {
    if (kind == WindowControlButton::kMaximize && !allow_maximize) {
      continue;
    }
    auto callback = base::BindRepeating(
        [](OpenWindowControlsView* self, WindowControlButton action) {
          views::Widget* widget = self->GetWidget();
          if (!widget) {
            return;
          }
          switch (action) {
            case WindowControlButton::kMinimize:
              widget->Minimize();
              break;
            case WindowControlButton::kMaximize:
              if (widget->IsMaximized()) {
                widget->Restore();
              } else {
                widget->Maximize();
              }
              break;
            case WindowControlButton::kClose:
              widget->Close();
              break;
          }
        },
        base::Unretained(this), kind);

    auto* button = AddChildView(
        std::make_unique<CaptionButton>(this, kind, std::move(callback)));
    switch (kind) {
      case WindowControlButton::kMinimize:
        button->GetViewAccessibility().SetName(u"Minimize");
        button->SetTooltipText(u"Minimize");
        break;
      case WindowControlButton::kMaximize:
        button->GetViewAccessibility().SetName(u"Maximize");
        button->SetTooltipText(u"Maximize");
        break;
      case WindowControlButton::kClose:
        button->GetViewAccessibility().SetName(u"Close");
        button->SetTooltipText(u"Close");
        break;
    }
    buttons_.push_back(ButtonSlot{kind, button});
  }
}

OpenWindowControlsView::~OpenWindowControlsView() = default;

void OpenWindowControlsView::SetThemeState(bool dark_content,
                                           bool window_active,
                                           bool increase_contrast) {
  if (dark_content_ == dark_content && window_active_ == window_active &&
      increase_contrast_ == increase_contrast) {
    return;
  }
  dark_content_ = dark_content;
  window_active_ = window_active;
  increase_contrast_ = increase_contrast;
  for (const ButtonSlot& slot : buttons_) {
    slot.button->SchedulePaint();
  }
  SchedulePaint();
}

void OpenWindowControlsView::SetMaximized(bool maximized) {
  if (maximized_ == maximized) {
    return;
  }
  maximized_ = maximized;
  UpdateMaximizeMetadata();
  for (const ButtonSlot& slot : buttons_) {
    if (slot.kind == WindowControlButton::kMaximize) {
      slot.button->SchedulePaint();
    }
  }
}

int OpenWindowControlsView::HitTestCode(const gfx::Point& point_in_this) const {
  if (!GetVisible()) {
    return HTNOWHERE;
  }
  for (const ButtonSlot& slot : buttons_) {
    if (slot.button->GetVisible() &&
        slot.button->bounds().Contains(point_in_this)) {
      return HitTestForButton(slot.kind);
    }
  }
  return HTNOWHERE;
}

gfx::Size OpenWindowControlsView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  const int count = static_cast<int>(buttons_.size());
  if (count <= 0) {
    return gfx::Size();
  }
  if (mode_ == Mode::kWindowsFluent) {
    return gfx::Size(count * wc::kWinButtonW, wc::kWinButtonH);
  }
  return gfx::Size(count * wc::kLinuxButtonSize +
                       (count - 1) * wc::kLinuxButtonGap,
                   wc::kLinuxButtonSize);
}

void OpenWindowControlsView::Layout(PassKey) {
  const bool is_windows = (mode_ == Mode::kWindowsFluent);
  const int btn_w = is_windows ? wc::kWinButtonW : wc::kLinuxButtonSize;
  const int btn_h = is_windows ? wc::kWinButtonH : wc::kLinuxButtonSize;
  const int gap = is_windows ? 0 : wc::kLinuxButtonGap;
  const int y = std::max(0, (height() - btn_h) / 2);

  int x = 0;
  for (const ButtonSlot& slot : buttons_) {
    slot.button->SetBounds(x, y, btn_w, btn_h);
    x += btn_w + gap;
  }
}

void OpenWindowControlsView::UpdateMaximizeMetadata() {
  const std::u16string label = maximized_ ? u"Restore" : u"Maximize";
  for (const ButtonSlot& slot : buttons_) {
    if (slot.kind == WindowControlButton::kMaximize) {
      slot.button->GetViewAccessibility().SetName(label);
      slot.button->SetTooltipText(label);
    }
  }
}

BEGIN_METADATA(OpenWindowControlsView)
END_METADATA

}  // namespace open_unified
