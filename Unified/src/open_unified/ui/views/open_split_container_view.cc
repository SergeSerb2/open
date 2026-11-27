// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_split_container_view.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <numbers>
#include <numeric>
#include <utility>

#include "base/callback_list.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/utf_string_conversions.h"
#include "cc/paint/paint_filter.h"
#include "cc/paint/paint_flags.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/reload_type.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_typography.h"
#include "open_unified/ui/views/open_tab_tree_view.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/base/clipboard/clipboard_format_type.h"
#include "ui/base/cursor/cursor.h"
#include "ui/base/cursor/mojom/cursor_type.mojom-shared.h"
#include "ui/base/dragdrop/drag_drop_types.h"
#include "ui/base/dragdrop/drop_target_event.h"
#include "ui/base/dragdrop/mojom/drag_drop_types.mojom.h"
#include "ui/base/dragdrop/os_exchange_data.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/compositor/compositor.h"
#include "ui/compositor/layer.h"
#include "ui/compositor/layer_nine_patch.h"
#include "ui/compositor/layer_tree_owner.h"
#include "ui/events/event.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/outsets_f.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/rounded_corners_f.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/gfx/image/image_skia_rep.h"
#include "ui/gfx/shadow_value.h"
#include "ui/gfx/skia_paint_util.h"
#include "ui/gfx/text_constants.h"
#include "ui/gfx/text_elider.h"
#include "ui/gfx/text_utils.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/background.h"
#include "ui/views/controls/webview/webview.h"
#include "ui/views/widget/widget.h"
#include "url/gurl.h"

#if defined(USE_AURA)
#include "ui/aura/window.h"
#endif

namespace open_unified {

// ===========================================================================
// A. Shared primitives.
// ===========================================================================
namespace secondary {

namespace {

uint8_t ToByte(double unit) {
  return static_cast<uint8_t>(std::clamp(std::lround(unit * 255.0), 0L, 255L));
}

// Builds glyph geometry in a unit square mapped onto `box`.
class GlyphSpace {
 public:
  explicit GlyphSpace(const gfx::RectF& box) {
    size_ = std::min(box.width(), box.height());
    origin_ = gfx::PointF(box.x() + (box.width() - size_) / 2.f,
                          box.y() + (box.height() - size_) / 2.f);
  }
  float size() const { return size_; }
  SkPoint P(float x, float y) const {
    return SkPoint::Make(origin_.x() + x * size_, origin_.y() + y * size_);
  }
  SkRect R(float l, float t, float r, float b) const {
    return SkRect::MakeLTRB(origin_.x() + l * size_, origin_.y() + t * size_,
                            origin_.x() + r * size_, origin_.y() + b * size_);
  }
  float S(float v) const { return v * size_; }

 private:
  gfx::PointF origin_;
  float size_ = 0;
};

void Polyline(SkPathBuilder& b,
              const GlyphSpace& g,
              std::initializer_list<std::pair<float, float>> points,
              bool close = false) {
  bool first = true;
  for (const auto& [x, y] : points) {
    if (first) {
      b.moveTo(g.P(x, y));
      first = false;
    } else {
      b.lineTo(g.P(x, y));
    }
  }
  if (close) {
    b.close();
  }
}

void RoundRectPath(SkPathBuilder& b, const SkRect& r, float radius) {
  b.addRRect(SkRRect::MakeRectXY(r, radius, radius));
}

void CirclePath(SkPathBuilder& b, SkPoint c, float radius) {
  b.addOval(SkRect::MakeLTRB(c.x() - radius, c.y() - radius, c.x() + radius,
                             c.y() + radius));
}

// A capsule outline between centers p0 and p1 with radius r.
void CapsulePath(SkPathBuilder& b, SkPoint p0, SkPoint p1, float r) {
  const float dx = p1.x() - p0.x();
  const float dy = p1.y() - p0.y();
  const float theta = std::atan2(dy, dx) * 180.f / std::numbers::pi_v<float>;
  const float len = std::max(0.001f, std::hypot(dx, dy));
  const float nx = -dy / len * r;
  const float ny = dx / len * r;
  b.moveTo(p0.x() - nx, p0.y() - ny);
  b.lineTo(p1.x() - nx, p1.y() - ny);
  b.arcTo(SkRect::MakeLTRB(p1.x() - r, p1.y() - r, p1.x() + r, p1.y() + r),
          theta - 90.f, 180.f, false);
  b.lineTo(p0.x() + nx, p0.y() + ny);
  b.arcTo(SkRect::MakeLTRB(p0.x() - r, p0.y() - r, p0.x() + r, p0.y() + r),
          theta + 90.f, 180.f, false);
  b.close();
}

}  // namespace

std::u16string PrimaryShortcutLabel(char16_t key) {
#if BUILDFLAG(IS_MAC)
  return std::u16string(u"⌘") + key;
#else
  return std::u16string(u"Ctrl+") + key;
#endif
}

bool HasPrimaryModifier(int flags) {
  return (flags & kPrimaryModifier) != 0;
}

SkColor ToSkColor(const RGBAColor& color) {
  return SkColorSetARGB(ToByte(color.a), ToByte(color.r), ToByte(color.g),
                        ToByte(color.b));
}

SkColor WithAlpha(SkColor color, float alpha) {
  return SkColorSetA(color, ToByte(std::clamp(alpha, 0.f, 1.f)));
}

SkColor Mix(SkColor a, SkColor b, float t) {
  t = std::clamp(t, 0.f, 1.f);
  auto lerp = [t](U8CPU x, U8CPU y) {
    return static_cast<U8CPU>(std::lround(x + (static_cast<float>(y) - x) * t));
  };
  return SkColorSetARGB(lerp(SkColorGetA(a), SkColorGetA(b)),
                        lerp(SkColorGetR(a), SkColorGetR(b)),
                        lerp(SkColorGetG(a), SkColorGetG(b)),
                        lerp(SkColorGetB(a), SkColorGetB(b)));
}

bool IsDark(SkColor color) {
  const double luma =
      (0.2126 * SkColorGetR(color) + 0.7152 * SkColorGetG(color) +
       0.0722 * SkColorGetB(color)) /
      255.0;
  return luma < 0.5;
}

gfx::FontList FontOfSize(int size, gfx::Font::Weight weight) {
  return typography::Make(size, weight);
}

int TextWidth(std::u16string_view text, const gfx::FontList& font) {
  return text.empty() ? 0 : gfx::GetStringWidth(text, font);
}

void DrawText(gfx::Canvas* canvas,
              std::u16string_view text,
              const gfx::FontList& font,
              SkColor color,
              const gfx::Rect& rect,
              int align) {
  if (text.empty() || rect.width() <= 0 || rect.height() <= 0) {
    return;
  }
  const std::u16string elided =
      gfx::ElideText(text, font, rect.width(), gfx::ELIDE_TAIL);
  const int line = font.GetHeight();
  const gfx::Rect line_rect(rect.x(), rect.y() + (rect.height() - line) / 2,
                            rect.width(), line);
  canvas->DrawStringRectWithFlags(
      elided, font, color, line_rect,
      (align ? align : gfx::Canvas::TEXT_ALIGN_LEFT) |
          gfx::Canvas::NO_SUBPIXEL_RENDERING);
}

void FillRoundRect(gfx::Canvas* canvas,
                   const gfx::RectF& rect,
                   float radius,
                   SkColor color) {
  if (SkColorGetA(color) == 0 || rect.IsEmpty()) {
    return;
  }
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kFill_Style);
  flags.setColor(color);
  canvas->DrawRoundRect(rect, radius, flags);
}

void StrokeRoundRect(gfx::Canvas* canvas,
                     const gfx::RectF& rect,
                     float radius,
                     SkColor color,
                     float width) {
  if (SkColorGetA(color) == 0 || rect.IsEmpty()) {
    return;
  }
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kStroke_Style);
  flags.setStrokeWidth(width);
  flags.setColor(color);
  gfx::RectF inset = rect;
  inset.Inset(width / 2.f);
  canvas->DrawRoundRect(inset, std::max(0.f, radius - width / 2.f), flags);
}

void FillRoundRectGradient(gfx::Canvas* canvas,
                           const gfx::RectF& rect,
                           float radius,
                           SkColor top,
                           SkColor bottom) {
  if (rect.IsEmpty()) {
    return;
  }
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kFill_Style);
  const gfx::Rect r = gfx::ToEnclosingRect(rect);
  flags.setShader(
      gfx::CreateGradientShader(r.origin(), r.bottom_left(), top, bottom));
  canvas->DrawRoundRect(rect, radius, flags);
}

void FillRoundRectWithShadow(gfx::Canvas* canvas,
                             const gfx::RectF& rect,
                             float radius,
                             SkColor fill,
                             SkColor shadow_color,
                             float shadow_offset_y,
                             float shadow_blur) {
  if (rect.IsEmpty()) {
    return;
  }
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kFill_Style);
  flags.setColor(fill);
  if (SkColorGetA(shadow_color) != 0 && shadow_blur > 0) {
    const gfx::ShadowValues shadows{
        gfx::ShadowValue(gfx::Vector2d(0, std::lround(shadow_offset_y)),
                         shadow_blur, shadow_color)};
    flags.setLooper(gfx::CreateShadowDrawLooper(shadows));
  }
  canvas->DrawRoundRect(rect, radius, flags);
}

void DrawImageInRect(gfx::Canvas* canvas,
                     const gfx::ImageSkia& image,
                     const gfx::Rect& rect) {
  if (image.isNull() || rect.IsEmpty()) {
    return;
  }
  canvas->DrawImageInt(image, 0, 0, image.width(), image.height(), rect.x(),
                       rect.y(), rect.width(), rect.height(), true);
}

void PaintGlyph(gfx::Canvas* canvas,
                Glyph glyph,
                const gfx::RectF& box,
                SkColor color,
                float stroke_width) {
  if (glyph == Glyph::kNone || box.IsEmpty() || SkColorGetA(color) == 0) {
    return;
  }
  const GlyphSpace g(box);
  const float width =
      stroke_width > 0 ? stroke_width : std::clamp(g.size() / 11.f, 1.2f, 2.f);

  cc::PaintFlags stroke;
  stroke.setAntiAlias(true);
  stroke.setStyle(cc::PaintFlags::kStroke_Style);
  stroke.setStrokeWidth(width);
  stroke.setStrokeCap(cc::PaintFlags::kRound_Cap);
  stroke.setStrokeJoin(cc::PaintFlags::kRound_Join);
  stroke.setColor(color);

  cc::PaintFlags fill;
  fill.setAntiAlias(true);
  fill.setStyle(cc::PaintFlags::kFill_Style);
  fill.setColor(color);

  SkPathBuilder b;
  SkPathBuilder filled;
  switch (glyph) {
    case Glyph::kNone:
      return;
    case Glyph::kBack:
      Polyline(b, g, {{0.80f, 0.5f}, {0.22f, 0.5f}});
      Polyline(b, g, {{0.47f, 0.25f}, {0.22f, 0.5f}, {0.47f, 0.75f}});
      break;
    case Glyph::kForward:
      Polyline(b, g, {{0.20f, 0.5f}, {0.78f, 0.5f}});
      Polyline(b, g, {{0.53f, 0.25f}, {0.78f, 0.5f}, {0.53f, 0.75f}});
      break;
    case Glyph::kReload: {
      // Clockwise arc from 10° to 310°, arrowhead at the end.
      const SkPoint c = g.P(0.5f, 0.52f);
      const float r = g.S(0.30f);
      b.addArc(SkRect::MakeLTRB(c.x() - r, c.y() - r, c.x() + r, c.y() + r),
               10.f, 300.f);
      const float a = 310.f * std::numbers::pi_v<float> / 180.f;
      const SkPoint end =
          SkPoint::Make(c.x() + r * std::cos(a), c.y() + r * std::sin(a));
      const float tx = -std::sin(a), ty = std::cos(a);  // Clockwise tangent.
      const float nx = std::cos(a), ny = std::sin(a);   // Radial.
      const float t = g.S(0.07f), back = g.S(0.11f), wing = g.S(0.13f);
      b.moveTo(end.x() - tx * back + nx * wing,
               end.y() - ty * back + ny * wing);
      b.lineTo(end.x() + tx * t, end.y() + ty * t);
      b.lineTo(end.x() - tx * back - nx * wing,
               end.y() - ty * back - ny * wing);
      break;
    }
    case Glyph::kStop:
    case Glyph::kClose:
      Polyline(b, g, {{0.27f, 0.27f}, {0.73f, 0.73f}});
      Polyline(b, g, {{0.73f, 0.27f}, {0.27f, 0.73f}});
      break;
    case Glyph::kLink:
      CapsulePath(b, g.P(0.24f, 0.76f), g.P(0.46f, 0.54f), g.S(0.14f));
      CapsulePath(b, g.P(0.54f, 0.46f), g.P(0.76f, 0.24f), g.S(0.14f));
      Polyline(b, g, {{0.40f, 0.60f}, {0.60f, 0.40f}});
      break;
    case Glyph::kCopy:
      RoundRectPath(b, g.R(0.32f, 0.32f, 0.84f, 0.84f), g.S(0.09f));
      Polyline(b, g, {{0.18f, 0.68f}, {0.18f, 0.18f}, {0.68f, 0.18f}});
      break;
    case Glyph::kSiteControl:
      Polyline(b, g, {{0.14f, 0.34f}, {0.86f, 0.34f}});
      Polyline(b, g, {{0.14f, 0.66f}, {0.86f, 0.66f}});
      CirclePath(filled, g.P(0.36f, 0.34f), g.S(0.11f));
      CirclePath(filled, g.P(0.64f, 0.66f), g.S(0.11f));
      break;
    case Glyph::kSplit:
      RoundRectPath(b, g.R(0.12f, 0.20f, 0.88f, 0.80f), g.S(0.10f));
      Polyline(b, g, {{0.5f, 0.20f}, {0.5f, 0.80f}});
      break;
    case Glyph::kSplitVertical:
      RoundRectPath(b, g.R(0.16f, 0.14f, 0.84f, 0.86f), g.S(0.10f));
      Polyline(b, g, {{0.16f, 0.5f}, {0.84f, 0.5f}});
      break;
    case Glyph::kSwap:
      Polyline(b, g, {{0.18f, 0.36f}, {0.80f, 0.36f}});
      Polyline(b, g, {{0.64f, 0.22f}, {0.80f, 0.36f}, {0.64f, 0.50f}});
      Polyline(b, g, {{0.82f, 0.64f}, {0.20f, 0.64f}});
      Polyline(b, g, {{0.36f, 0.50f}, {0.20f, 0.64f}, {0.36f, 0.78f}});
      break;
    case Glyph::kSeparate:
      Polyline(b, g,
               {{0.40f, 0.26f},
                {0.16f, 0.26f},
                {0.16f, 0.84f},
                {0.74f, 0.84f},
                {0.74f, 0.60f}});
      Polyline(b, g, {{0.44f, 0.56f}, {0.86f, 0.14f}});
      Polyline(b, g, {{0.60f, 0.14f}, {0.86f, 0.14f}, {0.86f, 0.40f}});
      break;
    case Glyph::kChevronDown:
      Polyline(b, g, {{0.26f, 0.38f}, {0.5f, 0.62f}, {0.74f, 0.38f}});
      break;
    case Glyph::kChevronUp:
      Polyline(b, g, {{0.26f, 0.62f}, {0.5f, 0.38f}, {0.74f, 0.62f}});
      break;
    case Glyph::kChevronRight:
      Polyline(b, g, {{0.40f, 0.26f}, {0.64f, 0.5f}, {0.40f, 0.74f}});
      break;
    case Glyph::kExpand:
      Polyline(b, g, {{0.28f, 0.72f}, {0.72f, 0.28f}});
      Polyline(b, g, {{0.48f, 0.22f}, {0.78f, 0.22f}, {0.78f, 0.52f}});
      Polyline(b, g, {{0.22f, 0.48f}, {0.22f, 0.78f}, {0.52f, 0.78f}});
      break;
    case Glyph::kSearch:
      CirclePath(b, g.P(0.44f, 0.44f), g.S(0.26f));
      Polyline(b, g, {{0.63f, 0.63f}, {0.82f, 0.82f}});
      break;
    case Glyph::kGlobe:
      CirclePath(b, g.P(0.5f, 0.5f), g.S(0.36f));
      b.addOval(g.R(0.35f, 0.14f, 0.65f, 0.86f));
      Polyline(b, g, {{0.14f, 0.5f}, {0.86f, 0.5f}});
      break;
    case Glyph::kPlus:
      Polyline(b, g, {{0.5f, 0.22f}, {0.5f, 0.78f}});
      Polyline(b, g, {{0.22f, 0.5f}, {0.78f, 0.5f}});
      break;
    case Glyph::kMinus:
      Polyline(b, g, {{0.24f, 0.5f}, {0.76f, 0.5f}});
      break;
    case Glyph::kSquare:
      RoundRectPath(b, g.R(0.26f, 0.26f, 0.74f, 0.74f), g.S(0.06f));
      break;
    case Glyph::kCamera:
      RoundRectPath(b, g.R(0.10f, 0.28f, 0.66f, 0.72f), g.S(0.10f));
      Polyline(b, g,
               {{0.66f, 0.44f}, {0.90f, 0.30f}, {0.90f, 0.70f}, {0.66f, 0.56f}},
               /*close=*/true);
      break;
    case Glyph::kMicrophone:
      RoundRectPath(b, g.R(0.38f, 0.12f, 0.62f, 0.58f), g.S(0.12f));
      b.addArc(g.R(0.24f, 0.24f, 0.76f, 0.70f), 0.f, 180.f);
      Polyline(b, g, {{0.5f, 0.70f}, {0.5f, 0.86f}});
      Polyline(b, g, {{0.38f, 0.86f}, {0.62f, 0.86f}});
      break;
    case Glyph::kLocation:
      Polyline(b, g,
               {{0.18f, 0.48f}, {0.84f, 0.18f}, {0.54f, 0.84f}, {0.47f, 0.55f}},
               /*close=*/true);
      break;
    case Glyph::kBell:
      b.moveTo(g.P(0.22f, 0.70f));
      b.lineTo(g.P(0.30f, 0.58f));
      b.lineTo(g.P(0.30f, 0.44f));
      b.arcTo(g.R(0.30f, 0.20f, 0.70f, 0.64f), 180.f, 180.f, false);
      b.lineTo(g.P(0.70f, 0.58f));
      b.lineTo(g.P(0.78f, 0.70f));
      b.close();
      Polyline(b, g, {{0.43f, 0.82f}, {0.57f, 0.82f}});
      break;
    case Glyph::kPopup:
      Polyline(b, g,
               {{0.44f, 0.26f},
                {0.14f, 0.26f},
                {0.14f, 0.86f},
                {0.74f, 0.86f},
                {0.74f, 0.56f}});
      Polyline(b, g, {{0.48f, 0.52f}, {0.86f, 0.14f}});
      Polyline(b, g, {{0.62f, 0.14f}, {0.86f, 0.14f}, {0.86f, 0.38f}});
      break;
    case Glyph::kShield:
      b.moveTo(g.P(0.5f, 0.12f));
      b.lineTo(g.P(0.82f, 0.24f));
      b.lineTo(g.P(0.80f, 0.50f));
      b.quadTo(g.P(0.76f, 0.78f), g.P(0.5f, 0.90f));
      b.quadTo(g.P(0.24f, 0.78f), g.P(0.20f, 0.50f));
      b.lineTo(g.P(0.18f, 0.24f));
      b.close();
      break;
    case Glyph::kBoost:
      Polyline(b, g, {{0.84f, 0.16f}, {0.50f, 0.50f}});
      b.moveTo(g.P(0.44f, 0.48f));
      b.quadTo(g.P(0.22f, 0.50f), g.P(0.18f, 0.84f));
      b.quadTo(g.P(0.50f, 0.80f), g.P(0.52f, 0.56f));
      b.close();
      break;
    case Glyph::kCapture:
      Polyline(b, g, {{0.14f, 0.34f}, {0.14f, 0.14f}, {0.34f, 0.14f}});
      Polyline(b, g, {{0.66f, 0.14f}, {0.86f, 0.14f}, {0.86f, 0.34f}});
      Polyline(b, g, {{0.86f, 0.66f}, {0.86f, 0.86f}, {0.66f, 0.86f}});
      Polyline(b, g, {{0.34f, 0.86f}, {0.14f, 0.86f}, {0.14f, 0.66f}});
      CirclePath(b, g.P(0.5f, 0.5f), g.S(0.14f));
      break;
    case Glyph::kGear: {
      CirclePath(b, g.P(0.5f, 0.5f), g.S(0.13f));
      CirclePath(b, g.P(0.5f, 0.5f), g.S(0.27f));
      for (int k = 0; k < 8; ++k) {
        const float a = k * std::numbers::pi_v<float> / 4.f;
        b.moveTo(g.P(0.5f + 0.27f * std::cos(a), 0.5f + 0.27f * std::sin(a)));
        b.lineTo(g.P(0.5f + 0.39f * std::cos(a), 0.5f + 0.39f * std::sin(a)));
      }
      break;
    }
    case Glyph::kTrash:
      Polyline(b, g, {{0.18f, 0.28f}, {0.82f, 0.28f}});
      Polyline(
          b, g,
          {{0.27f, 0.28f}, {0.31f, 0.86f}, {0.69f, 0.86f}, {0.73f, 0.28f}});
      Polyline(
          b, g,
          {{0.40f, 0.28f}, {0.40f, 0.16f}, {0.60f, 0.16f}, {0.60f, 0.28f}});
      break;
    case Glyph::kLock:
      RoundRectPath(b, g.R(0.22f, 0.46f, 0.78f, 0.88f), g.S(0.08f));
      b.moveTo(g.P(0.33f, 0.46f));
      b.lineTo(g.P(0.33f, 0.34f));
      b.arcTo(g.R(0.33f, 0.16f, 0.67f, 0.52f), 180.f, 180.f, false);
      b.lineTo(g.P(0.67f, 0.46f));
      break;
    case Glyph::kPuzzle:
      RoundRectPath(b, g.R(0.18f, 0.30f, 0.74f, 0.86f), g.S(0.08f));
      CirclePath(b, g.P(0.46f, 0.22f), g.S(0.09f));
      CirclePath(b, g.P(0.82f, 0.58f), g.S(0.09f));
      break;
    case Glyph::kUndo:
      Polyline(b, g, {{0.38f, 0.22f}, {0.18f, 0.40f}, {0.38f, 0.58f}});
      b.moveTo(g.P(0.18f, 0.40f));
      b.lineTo(g.P(0.60f, 0.40f));
      b.arcTo(g.R(0.42f, 0.40f, 0.80f, 0.80f), 270.f, 180.f, false);
      b.lineTo(g.P(0.40f, 0.80f));
      break;
    case Glyph::kCheck:
      Polyline(b, g, {{0.22f, 0.52f}, {0.42f, 0.72f}, {0.80f, 0.30f}});
      break;
    case Glyph::kEquals:
      Polyline(b, g, {{0.24f, 0.40f}, {0.76f, 0.40f}});
      Polyline(b, g, {{0.24f, 0.60f}, {0.76f, 0.60f}});
      break;
    case Glyph::kBolt:
      Polyline(b, g,
               {{0.56f, 0.10f},
                {0.24f, 0.56f},
                {0.48f, 0.56f},
                {0.42f, 0.90f},
                {0.76f, 0.42f},
                {0.52f, 0.42f}},
               /*close=*/true);
      break;
    case Glyph::kStar:
      Polyline(b, g,
               {{0.50f, 0.14f},
                {0.61f, 0.37f},
                {0.86f, 0.40f},
                {0.68f, 0.58f},
                {0.72f, 0.84f},
                {0.50f, 0.71f},
                {0.28f, 0.84f},
                {0.32f, 0.58f},
                {0.14f, 0.40f},
                {0.39f, 0.37f}},
               /*close=*/true);
      break;
    case Glyph::kDownload:
      Polyline(b, g, {{0.50f, 0.18f}, {0.50f, 0.70f}});
      Polyline(b, g, {{0.30f, 0.52f}, {0.50f, 0.72f}, {0.70f, 0.52f}});
      Polyline(b, g, {{0.22f, 0.82f}, {0.78f, 0.82f}});
      break;
    case Glyph::kStack:
      RoundRectPath(b, g.R(0.18f, 0.28f, 0.74f, 0.84f), g.S(0.08f));
      Polyline(b, g,
               {{0.30f, 0.18f}, {0.82f, 0.18f}, {0.82f, 0.70f}});
      break;
    case Glyph::kLockOpen:
      RoundRectPath(b, g.R(0.22f, 0.46f, 0.78f, 0.88f), g.S(0.08f));
      b.moveTo(g.P(0.33f, 0.46f));
      b.lineTo(g.P(0.33f, 0.34f));
      b.arcTo(g.R(0.33f, 0.14f, 0.69f, 0.50f), 180.f, 145.f, false);
      CirclePath(filled, g.P(0.50f, 0.67f), g.S(0.06f));
      break;
    case Glyph::kInfo:
      CirclePath(b, g.P(0.50f, 0.50f), g.S(0.38f));
      CirclePath(filled, g.P(0.50f, 0.32f), g.S(0.055f));
      Polyline(b, g, {{0.50f, 0.46f}, {0.50f, 0.70f}});
      break;
    case Glyph::kWarning:
      Polyline(b, g, {{0.50f, 0.14f}, {0.88f, 0.84f}, {0.12f, 0.84f}},
               /*close=*/true);
      Polyline(b, g, {{0.50f, 0.38f}, {0.50f, 0.60f}});
      CirclePath(filled, g.P(0.50f, 0.72f), g.S(0.05f));
      break;
    case Glyph::kError:
      Polyline(b, g,
               {{0.34f, 0.12f},
                {0.66f, 0.12f},
                {0.88f, 0.34f},
                {0.88f, 0.66f},
                {0.66f, 0.88f},
                {0.34f, 0.88f},
                {0.12f, 0.66f},
                {0.12f, 0.34f}},
               /*close=*/true);
      Polyline(b, g, {{0.35f, 0.35f}, {0.65f, 0.65f}});
      Polyline(b, g, {{0.65f, 0.35f}, {0.35f, 0.65f}});
      break;
    case Glyph::kOpenDoorway:
      b.moveTo(g.P(0.20f, 0.86f));
      b.lineTo(g.P(0.20f, 0.46f));
      b.arcTo(g.R(0.20f, 0.14f, 0.80f, 0.74f), 180.f, 180.f, false);
      b.lineTo(g.P(0.80f, 0.86f));
      Polyline(b, g, {{0.12f, 0.86f}, {0.88f, 0.86f}});
      CirclePath(filled, g.P(0.50f, 0.54f), g.S(0.14f));
      break;
    case Glyph::kMidi:
      // Piano keys: rounded frame + key dividers + filled black keys.
      RoundRectPath(b, g.R(0.12f, 0.22f, 0.88f, 0.78f), g.S(0.08f));
      Polyline(b, g, {{0.37f, 0.22f}, {0.37f, 0.78f}});
      Polyline(b, g, {{0.63f, 0.22f}, {0.63f, 0.78f}});
      filled.addRect(g.R(0.31f, 0.22f, 0.43f, 0.54f));
      filled.addRect(g.R(0.57f, 0.22f, 0.69f, 0.54f));
      break;
    case Glyph::kFonts:
      // Typography "Aa" mark.
      Polyline(b, g, {{0.14f, 0.78f}, {0.34f, 0.22f}, {0.54f, 0.78f}});
      Polyline(b, g, {{0.21f, 0.60f}, {0.47f, 0.60f}});
      CirclePath(b, g.P(0.74f, 0.64f), g.S(0.14f));
      Polyline(b, g, {{0.88f, 0.50f}, {0.88f, 0.78f}});
      break;
    case Glyph::kIdle:
      // Crescent moon + sleep "z" accent.
      b.arcTo(g.R(0.16f, 0.22f, 0.74f, 0.82f), -45.f, 275.f, true);
      b.quadTo(g.P(0.40f, 0.52f), g.P(0.65f, 0.30f));
      Polyline(b, g,
               {{0.68f, 0.20f}, {0.86f, 0.20f}, {0.68f, 0.38f}, {0.86f, 0.38f}});
      break;
    case Glyph::kSensors:
      // Gyroscope: two crossed orbital rings + center dot.
      b.addOval(g.R(0.14f, 0.32f, 0.86f, 0.68f));
      b.addOval(g.R(0.32f, 0.14f, 0.68f, 0.86f));
      CirclePath(filled, g.P(0.50f, 0.50f), g.S(0.08f));
      break;
    case Glyph::kJavaScript:
      // Curly braces { }.
      b.moveTo(g.P(0.40f, 0.18f));
      b.quadTo(g.P(0.26f, 0.18f), g.P(0.26f, 0.32f));
      b.lineTo(g.P(0.26f, 0.42f));
      b.quadTo(g.P(0.26f, 0.50f), g.P(0.16f, 0.50f));
      b.quadTo(g.P(0.26f, 0.50f), g.P(0.26f, 0.58f));
      b.lineTo(g.P(0.26f, 0.68f));
      b.quadTo(g.P(0.26f, 0.82f), g.P(0.40f, 0.82f));
      b.moveTo(g.P(0.60f, 0.18f));
      b.quadTo(g.P(0.74f, 0.18f), g.P(0.74f, 0.32f));
      b.lineTo(g.P(0.74f, 0.42f));
      b.quadTo(g.P(0.74f, 0.50f), g.P(0.84f, 0.50f));
      b.quadTo(g.P(0.74f, 0.50f), g.P(0.74f, 0.58f));
      b.lineTo(g.P(0.74f, 0.68f));
      b.quadTo(g.P(0.74f, 0.82f), g.P(0.60f, 0.82f));
      break;
    case Glyph::kSound:
      // Speaker cone + two sound wave arcs.
      Polyline(b, g,
               {{0.14f, 0.38f},
                {0.32f, 0.38f},
                {0.52f, 0.22f},
                {0.52f, 0.78f},
                {0.32f, 0.62f},
                {0.14f, 0.62f}},
               /*close=*/true);
      b.addArc(g.R(0.48f, 0.32f, 0.72f, 0.68f), -45.f, 90.f);
      b.addArc(g.R(0.48f, 0.20f, 0.86f, 0.80f), -45.f, 90.f);
      break;
    case Glyph::kHid:
      // Compact keyboard / HID device.
      RoundRectPath(b, g.R(0.10f, 0.26f, 0.90f, 0.74f), g.S(0.09f));
      for (float kx : {0.26f, 0.42f, 0.58f, 0.74f}) {
        CirclePath(filled, g.P(kx, 0.42f), g.S(0.04f));
      }
      Polyline(b, g, {{0.28f, 0.60f}, {0.72f, 0.60f}});
      break;
    case Glyph::kBluetooth:
      // Classic Bluetooth rune.
      Polyline(b, g,
               {{0.30f, 0.32f},
                {0.72f, 0.68f},
                {0.50f, 0.86f},
                {0.50f, 0.14f},
                {0.72f, 0.32f},
                {0.30f, 0.68f}});
      break;
    case Glyph::kHandTracking:
      // Open hand silhouette (palm + fingers).
      Polyline(b, g, {{0.30f, 0.54f}, {0.30f, 0.24f}});
      Polyline(b, g, {{0.45f, 0.50f}, {0.45f, 0.16f}});
      Polyline(b, g, {{0.60f, 0.50f}, {0.60f, 0.20f}});
      Polyline(b, g, {{0.74f, 0.56f}, {0.74f, 0.30f}});
      b.moveTo(g.P(0.22f, 0.52f));
      b.lineTo(g.P(0.30f, 0.76f));
      b.quadTo(g.P(0.52f, 0.90f), g.P(0.74f, 0.74f));
      b.lineTo(g.P(0.74f, 0.56f));
      break;
    case Glyph::kPointerLock:
      // Cursor arrow pointer.
      Polyline(b, g,
               {{0.24f, 0.16f},
                {0.24f, 0.80f},
                {0.42f, 0.62f},
                {0.56f, 0.86f},
                {0.66f, 0.80f},
                {0.54f, 0.58f},
                {0.78f, 0.58f}},
               /*close=*/true);
      break;
  }
  canvas->DrawPath(b.detach(), stroke);
  SkPath dots = filled.detach();
  if (!dots.isEmpty()) {
    canvas->DrawPath(dots, fill);
  }
}

// --- GlyphButton -----------------------------------------------------------

GlyphButton::GlyphButton(PressedCallback callback,
                         Glyph glyph,
                         const std::u16string& accessible_name)
    : views::Button(std::move(callback)), glyph_(glyph) {
  SetTooltipText(accessible_name);
  GetViewAccessibility().SetName(accessible_name);
}

GlyphButton::~GlyphButton() = default;

void GlyphButton::SetGlyph(Glyph glyph) {
  if (glyph_ == glyph) {
    return;
  }
  glyph_ = glyph;
  SchedulePaint();
}

void GlyphButton::SetGlyphColor(SkColor color) {
  if (glyph_color_ == color) {
    return;
  }
  glyph_color_ = color;
  SchedulePaint();
}

void GlyphButton::SetGlyphSize(float size) {
  glyph_size_ = size;
  SchedulePaint();
}

void GlyphButton::SetGlyphOffset(const gfx::Vector2dF& offset) {
  glyph_offset_ = offset;
  SchedulePaint();
}

void GlyphButton::SetSystemSymbol(std::string symbol_name, float point_size) {
  system_symbol_name_ = std::move(symbol_name);
  system_symbol_point_size_ = point_size;
  SchedulePaint();
}

void GlyphButton::SetPlate(Plate plate, SkColor fill, float radius) {
  plate_ = plate;
  plate_fill_ = fill;
  plate_radius_ = radius;
  SchedulePaint();
}

void GlyphButton::SetHoverFill(SkColor fill) {
  hover_fill_ = fill;
  SchedulePaint();
}

void GlyphButton::SetDimsWhenDisabled(bool dims) {
  dims_when_disabled_ = dims;
  SchedulePaint();
}

void GlyphButton::PaintButtonContents(gfx::Canvas* canvas) {
  const gfx::RectF bounds(GetLocalBounds());
  const bool enabled = GetEnabled();
  const bool hovered =
      enabled && (GetState() == STATE_HOVERED || GetState() == STATE_PRESSED);
  switch (plate_) {
    case Plate::kNone:
      break;
    case Plate::kHoverRounded:
      if (hovered) {
        FillRoundRect(canvas, bounds, plate_radius_, hover_fill_);
      }
      break;
    case Plate::kRounded:
      FillRoundRect(canvas, bounds, plate_radius_, plate_fill_);
      if (hovered) {
        FillRoundRect(canvas, bounds, plate_radius_, hover_fill_);
      }
      break;
    case Plate::kCircle: {
      const float d = std::min(bounds.width(), bounds.height());
      const gfx::RectF circle(bounds.x() + (bounds.width() - d) / 2.f,
                              bounds.y() + (bounds.height() - d) / 2.f, d, d);
      FillRoundRect(canvas, circle, d / 2.f, plate_fill_);
      if (hovered) {
        FillRoundRect(canvas, circle, d / 2.f, hover_fill_);
      }
      break;
    }
  }
  SkColor color = glyph_color_;
  if (!enabled && dims_when_disabled_) {
    color = WithAlpha(color, 0.24f);
  }
  const gfx::RectF box(
      bounds.x() + (bounds.width() - glyph_size_) / 2.f + glyph_offset_.x(),
      bounds.y() + (bounds.height() - glyph_size_) / 2.f + glyph_offset_.y(),
      glyph_size_, glyph_size_);
  if (!system_symbol_name_.empty()) {
    const float pt = system_symbol_point_size_ > 0.f ? system_symbol_point_size_
                                                     : glyph_size_;
    if (glyphs::DrawSystemSymbol(canvas, system_symbol_name_, pt,
                                 glyphs::SymbolWeight::kMedium, bounds, color,
                                 glyph_offset_)) {
      return;
    }
  }
  PaintGlyph(canvas, glyph_, box, color);
}

ui::Cursor GlyphButton::GetCursor(const ui::MouseEvent& event) {
  return GetEnabled() ? ui::Cursor(ui::mojom::CursorType::kHand)
                      : views::Button::GetCursor(event);
}

BEGIN_METADATA(GlyphButton)
END_METADATA

// --- PaintedButton ---------------------------------------------------------

PaintedButton::PaintedButton(PressedCallback callback,
                             Painter painter,
                             const std::u16string& accessible_name)
    : views::Button(std::move(callback)), painter_(std::move(painter)) {
  SetTooltipText(accessible_name);
  GetViewAccessibility().SetName(accessible_name);
}

PaintedButton::~PaintedButton() = default;

void PaintedButton::SetPainter(Painter painter) {
  painter_ = std::move(painter);
  SchedulePaint();
}

void PaintedButton::PaintButtonContents(gfx::Canvas* canvas) {
  if (!painter_) {
    return;
  }
  const bool hovered = GetEnabled() && (GetState() == STATE_HOVERED ||
                                        GetState() == STATE_PRESSED);
  painter_.Run(canvas, GetLocalBounds(), hovered);
}

ui::Cursor PaintedButton::GetCursor(const ui::MouseEvent& event) {
  return GetEnabled() ? ui::Cursor(ui::mojom::CursorType::kHand)
                      : views::Button::GetCursor(event);
}

BEGIN_METADATA(PaintedButton)
END_METADATA

// --- OverlayWidgetHost -----------------------------------------------------

// static
bool OverlayWidgetHost::DefaultActivatableFor(std::string_view name) {
  // Toasts and the Ctrl+Tab switcher never take key focus from the page.
  return name != "OpenToasts" && name != "OpenTabSwitcher";
}

OverlayWidgetHost::OverlayWidgetHost(views::Widget* parent,
                                     std::unique_ptr<views::View> contents,
                                     std::string_view name)
    : OverlayWidgetHost(parent,
                        std::move(contents),
                        name,
                        DefaultActivatableFor(name)) {}

OverlayWidgetHost::OverlayWidgetHost(views::Widget* parent,
                                     std::unique_ptr<views::View> contents,
                                     std::string_view name,
                                     bool activatable)
    : activatable_(activatable), parent_(parent) {
  views::Widget::InitParams params(
      views::Widget::InitParams::CLIENT_OWNS_WIDGET,
      views::Widget::InitParams::TYPE_CONTROL);
  params.SetParent(parent);
  params.opacity = views::Widget::InitParams::WindowOpacity::kTranslucent;
  params.shadow_type = views::Widget::InitParams::ShadowType::kNone;
  params.activatable = activatable
                           ? views::Widget::InitParams::Activatable::kYes
                           : views::Widget::InitParams::Activatable::kNo;
  params.name = std::string(name);
  widget_ = std::make_unique<views::Widget>();
  widget_->Init(std::move(params));
  contents_ = widget_->SetContentsView(std::move(contents));
  // NativeWidgetAura auto-shows TYPE_CONTROL windows during InitNativeWidget();
  // keep the overlay hidden until Show() so invisible overlays never intercept
  // clicks, scroll events, or cursors over the page.
  widget_->Hide();
  observation_.Observe(contents_.get());
  widget_observation_.Observe(widget_.get());
}

OverlayWidgetHost::~OverlayWidgetHost() {
  widget_observation_.Reset();
  paint_as_active_lock_.reset();
  observation_.Reset();
  contents_ = nullptr;
  widget_.reset();
}

void OverlayWidgetHost::SetAnchor(const gfx::Rect& anchor_in_parent,
                                  Alignment alignment) {
  anchor_ = anchor_in_parent;
  alignment_ = alignment;
  ApplyBounds();
}

// static
void OverlayWidgetHost::StackWidgetAtTop(views::Widget* widget) {
  if (!widget || widget->IsClosed()) {
    return;
  }
#if defined(USE_AURA)
  aura::Window* win = widget->GetNativeWindow();
  aura::Window* parent = win ? win->parent() : nullptr;
  if (win && parent && win->layer_managed_by_parent() && win->layer()) {
    const auto& children = parent->children();
    size_t win_index = children.size();
    size_t target_index = 0;
    aura::Window* target = nullptr;
    for (size_t i = 0; i < children.size(); ++i) {
      aura::Window* child = children[i];
      if (child == win) {
        win_index = i;
      } else if (child->layer_managed_by_parent() && child->layer()) {
        target = child;
        target_index = i;
      }
    }
    if (target && win_index < target_index) {
      parent->StackChildAbove(win, target);
    }
  }
  if (win && win->layer() && win->layer()->parent()) {
    win->layer()->parent()->StackAtTop(win->layer());
  }
#else
  widget->StackAtTop();
#endif
}

void OverlayWidgetHost::Show() {
  ApplyBounds();
  StackWidgetAtTop(widget_.get());
  if (activatable_) {
    // Lock before the overlay takes key status, so the parent never paints
    // one inactive frame.
    UpdatePaintAsActiveLock(true);
    widget_->Show();
  } else {
    widget_->ShowInactive();
  }
}

void OverlayWidgetHost::Hide() {
  widget_->Hide();
  UpdatePaintAsActiveLock(false);
}

void OverlayWidgetHost::UpdatePaintAsActiveLock(bool visible) {
  if (!activatable_ || !parent_) {
    paint_as_active_lock_.reset();
    return;
  }
  if (visible && !paint_as_active_lock_) {
    paint_as_active_lock_ = parent_->LockPaintAsActive();
  } else if (!visible) {
    paint_as_active_lock_.reset();
  }
}

void OverlayWidgetHost::OnWidgetVisibilityChanged(views::Widget* widget,
                                                  bool visible) {
  // Also covers callers that show or hide widget() directly.
  UpdatePaintAsActiveLock(visible);
}

void OverlayWidgetHost::OnWidgetDestroying(views::Widget* widget) {
  paint_as_active_lock_.reset();
  widget_observation_.Reset();
  parent_ = nullptr;
}

bool OverlayWidgetHost::IsVisible() const {
  return widget_ && widget_->IsVisible();
}

void OverlayWidgetHost::OnViewPreferredSizeChanged(views::View* observed_view) {
  if (alignment_ != Alignment::kFill) {
    ApplyBounds();
  }
}

void OverlayWidgetHost::ApplyBounds() {
  if (!widget_ || !contents_) {
    return;
  }
  gfx::Rect bounds = anchor_;
  if (alignment_ != Alignment::kFill) {
    const gfx::Size pref = contents_->GetPreferredSize();
    const gfx::Insets insets = contents_->GetInsets();
    const int inner_w = pref.width() - insets.width();
    const int inner_h = pref.height() - insets.height();
    int x = anchor_.x();
    int y = anchor_.y();
    switch (alignment_) {
      case Alignment::kFill:
        break;
      case Alignment::kCenter:
        x = anchor_.x() + (anchor_.width() - inner_w) / 2;
        y = anchor_.y() + (anchor_.height() - inner_h) / 2;
        break;
      case Alignment::kTopCenter:
        x = anchor_.x() + (anchor_.width() - inner_w) / 2;
        break;
      case Alignment::kTopRight:
        x = anchor_.right() - inner_w;
        break;
    }
    bounds = gfx::Rect(x - insets.left(), y - insets.top(), pref.width(),
                       pref.height());
  }
  widget_->SetBounds(bounds);
}

}  // namespace secondary

// ===========================================================================
// B. OpenPaneChromeView.
// ===========================================================================

namespace {

using secondary::Glyph;
using secondary::GlyphButton;

enum MenuCommand : int {
  kMenuAddSplit = 1,
  kMenuSwap,
  kMenuOrientation,
  kMenuSeparate,
  kMenuClose,
};

// Glyph tints over a light page (PaneChromeView init: black 0.55 nav and
// Site Control, 0.60 copy, 0.59 split menu and close, label 0.6). On a dark
// page the same alphas apply to white (guess: Arc's dark pane bar is not
// captured).
float ControlAlpha(OpenPaneChromeView::Control control) {
  switch (control) {
    case OpenPaneChromeView::kCopyControl:
      return 0.60f;
    case OpenPaneChromeView::kSplitMenuControl:
    case OpenPaneChromeView::kCloseControl:
      return 0.59f;
    default:
      return 0.55f;
  }
}

constexpr float kHostLabelAlpha = 0.6f;
constexpr int kHostFontSize = 13;

}  // namespace

OpenPaneChromeView::OpenPaneChromeView(Role role, CommandCallback callback)
    : role_(role), callback_(std::move(callback)) {
  struct Spec {
    Glyph glyph;
    const char16_t* name;
    float size;
    gfx::Vector2dF offset;
  };
  // PaneChromeView glyph sizes: back/forward/reload 14, copy 12, Site
  // Control 16, split menu and close 16.
  const std::array<Spec, kControlCount> specs = {{
      {Glyph::kBack, u"Go back", 14.f, {1.f, 1.f}},
      {Glyph::kForward, u"Go forward", 14.f, {1.f, 1.f}},
      {Glyph::kReload, u"Reload", 14.f, {0.f, 1.f}},
      {Glyph::kLink, u"Copy Current URL", 12.f, {1.f, 1.f}},
      {Glyph::kSiteControl, u"Site Control Center", 16.f, {}},
      {Glyph::kSplit, u"Split View Menu", 16.f, {0.f, 1.f}},
      {Glyph::kClose, u"Close This Pane", 16.f, {}},
  }};
  for (int i = 0; i < kControlCount; ++i) {
    auto button = std::make_unique<GlyphButton>(
        base::BindRepeating(&OpenPaneChromeView::Press, base::Unretained(this),
                            static_cast<Control>(i)),
        specs[i].glyph, specs[i].name);
    button->SetGlyphSize(specs[i].size);
    button->SetGlyphOffset(specs[i].offset);
    button->SetPlate(GlyphButton::Plate::kHoverRounded, SK_ColorTRANSPARENT,
                     6.f);
    if (i == kSiteControlControl) {
      button->SetDimsWhenDisabled(false);
    }
    buttons_.push_back(AddChildView(std::move(button)));
  }
  ApplyColors();
}

OpenPaneChromeView::~OpenPaneChromeView() = default;

void OpenPaneChromeView::SetRole(Role role) {
  if (role_ == role) {
    return;
  }
  role_ = role;
  InvalidateLayout();
  SchedulePaint();
}

void OpenPaneChromeView::SetState(const State& state) {
  if (state_ == state) {
    return;
  }
  const bool layout_changed = state.focused != state_.focused ||
                              state.host != state_.host ||
                              state.hides_copy != state_.hides_copy;
  state_ = state;
  buttons_[kBackControl]->SetEnabled(state_.can_go_back);
  buttons_[kForwardControl]->SetEnabled(state_.can_go_forward);
  buttons_[kSiteControlControl]->SetEnabled(state_.site_controls_available);
  buttons_[kReloadControl]->SetGlyph(state_.is_loading ? Glyph::kStop
                                                       : Glyph::kReload);
  const std::u16string reload_label =
      state_.is_loading ? u"Stop loading" : u"Reload";
  buttons_[kReloadControl]->SetTooltipText(reload_label);
  buttons_[kReloadControl]->GetViewAccessibility().SetName(reload_label);
  ApplyColors();
  if (layout_changed) {
    InvalidateLayout();
  }
  SchedulePaint();
}

views::View* OpenPaneChromeView::site_control_anchor() {
  return buttons_[kSiteControlControl];
}

bool OpenPaneChromeView::IsControlVisible(Control control) const {
  return buttons_[control]->GetVisible();
}

gfx::Rect OpenPaneChromeView::GetControlBounds(Control control) const {
  return buttons_[control]->bounds();
}

bool OpenPaneChromeView::IsRoleHidden(Control control) const {
  if (control == kCopyControl && state_.hides_copy) {
    return true;
  }
  if (role_ == Role::kToolbar) {
    return control == kSplitMenuControl || control == kCloseControl;
  }
  if (state_.focused) {
    return false;
  }
  // F0081: an unfocused pane shows Back, Forward, Copy + host, Close.
  return !(control == kBackControl || control == kForwardControl ||
           control == kCopyControl || control == kCloseControl);
}

void OpenPaneChromeView::ApplyColors() {
  draws_on_dark_ = secondary::IsDark(state_.background);
  const SkColor ink = draws_on_dark_ ? SK_ColorWHITE : SK_ColorBLACK;
  for (int i = 0; i < kControlCount; ++i) {
    buttons_[i]->SetGlyphColor(
        secondary::WithAlpha(ink, ControlAlpha(static_cast<Control>(i))));
    buttons_[i]->SetHoverFill(
        secondary::WithAlpha(ink, draws_on_dark_ ? 0.10f : 0.07f));
  }
}

void OpenPaneChromeView::OnPaint(gfx::Canvas* canvas) {
  // Page-tinted fill with the panel's 6 pt top corners; the page below
  // supplies the bottom corners.
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(state_.background);
  const float r = split_metrics::kPanelCornerRadius;
  const SkVector radii[4] = {{r, r}, {r, r}, {0, 0}, {0, 0}};
  SkRRect rrect;
  rrect.setRectRadii(gfx::RectFToSkRect(gfx::RectF(GetLocalBounds())), radii);
  canvas->sk_canvas()->drawRRect(rrect, flags);

  if (host_fits_) {
    const SkColor ink = draws_on_dark_ ? SK_ColorWHITE : SK_ColorBLACK;
    if (host_hovered_ && state_.focused) {
      gfx::RectF plate(host_rect_);
      plate.Outset(gfx::OutsetsF::VH(2.f, 4.f));
      secondary::FillRoundRect(
          canvas, plate, 5.f,
          secondary::WithAlpha(ink, draws_on_dark_ ? 0.10f : 0.07f));
    }
    secondary::DrawText(canvas, state_.host,
                        secondary::FontOfSize(kHostFontSize),
                        secondary::WithAlpha(ink, kHostLabelAlpha), host_rect_,
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  }
}

void OpenPaneChromeView::Layout(PassKey) {
  using namespace split_metrics;
  const int w = width();
  const bool toolbar = role_ == Role::kToolbar;
  buttons_[kBackControl]->SetBoundsRect(kBack);
  buttons_[kForwardControl]->SetBoundsRect(kForward);
  buttons_[kReloadControl]->SetBoundsRect(kReload);
  buttons_[kSiteControlControl]->SetBoundsRect(
      toolbar ? gfx::Rect(w - kToolbarSiteControlFromRight, 2, 32, 28)
              : gfx::Rect(w - kSiteControlFromRight, 2, 32, 28));
  buttons_[kSplitMenuControl]->SetBoundsRect(
      gfx::Rect(w - kSplitMenuFromRight, 4, 32, 24));
  buttons_[kCloseControl]->SetBoundsRect(
      gfx::Rect(w - kCloseFromRight, 4, 32, 24));

  std::array<bool, kControlCount> hidden{};
  for (int i = 0; i < kControlCount; ++i) {
    hidden[i] = IsRoleHidden(static_cast<Control>(i));
  }
  auto left_edge = [&] {
    int edge = 0;
    for (Control c : {kBackControl, kForwardControl, kReloadControl}) {
      if (!hidden[c]) {
        edge = std::max(edge, buttons_[c]->bounds().right());
      }
    }
    return edge;
  };
  auto right_edge = [&] {
    int edge = w;
    for (Control c : {kSiteControlControl, kSplitMenuControl, kCloseControl}) {
      if (!hidden[c]) {
        edge = std::min(edge, buttons_[c]->x());
      }
    }
    return edge;
  };
  // squeezeOrder: Reload, Forward, Site Control, Split Menu, Back.
  for (Control c : {kReloadControl, kForwardControl, kSiteControlControl,
                    kSplitMenuControl, kBackControl}) {
    if (left_edge() + kBarControlGap > right_edge()) {
      hidden[c] = true;
    }
  }
  for (Control c : {kBackControl, kForwardControl, kReloadControl,
                    kSiteControlControl, kSplitMenuControl, kCloseControl}) {
    buttons_[c]->SetVisible(!hidden[c]);
  }

  // Centered host group: copy 24 · 3 · host · 3 · empty 24 (F0081 AX).
  const int left = left_edge() + kBarControlGap;
  const int right = right_edge() - kBarControlGap;
  const int text =
      state_.host.empty()
          ? 0
          : secondary::TextWidth(state_.host,
                                 secondary::FontOfSize(kHostFontSize)) +
                4;
  const int box = std::min(text, right - left - 2 * kHostSlot);
  host_fits_ = !state_.host.empty() && box >= kHostMinimumWidth;
  const int x = std::max(left + kHostSlot,
                         std::min((w - box) / 2 - 2, right - kHostSlot - box));
  host_rect_ = gfx::Rect(x, 8, std::max(0, box), 16);
  buttons_[kCopyControl]->SetBoundsRect(gfx::Rect(x - 25, 4, 24, 24));
  buttons_[kCopyControl]->SetVisible(host_fits_ && !hidden[kCopyControl]);
  SchedulePaint();
}

gfx::Size OpenPaneChromeView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  return gfx::Size(0, split_metrics::kBarHeight);
}

void OpenPaneChromeView::SetFocusRequestCallback(
    base::RepeatingClosure callback) {
  focus_callback_ = std::move(callback);
}

void OpenPaneChromeView::SetHostClickCallback(
    base::RepeatingClosure callback) {
  host_click_callback_ = std::move(callback);
}

void OpenPaneChromeView::SetDragSwapCallback(DragCallback callback) {
  drag_swap_callback_ = std::move(callback);
}

ui::Cursor OpenPaneChromeView::GetCursor(const ui::MouseEvent& event) {
  if (host_fits_ && host_rect_.Contains(event.location())) {
    return ui::Cursor(ui::mojom::CursorType::kHand);
  }
  return views::View::GetCursor(event);
}

void OpenPaneChromeView::OnMouseMoved(const ui::MouseEvent& event) {
  const bool over_host = host_fits_ && host_rect_.Contains(event.location());
  if (over_host != host_hovered_) {
    host_hovered_ = over_host;
    SchedulePaint();
  }
}

void OpenPaneChromeView::OnMouseExited(const ui::MouseEvent& event) {
  if (host_hovered_) {
    host_hovered_ = false;
    SchedulePaint();
  }
}

bool OpenPaneChromeView::OnMousePressed(const ui::MouseEvent& event) {
  const bool was_focused = state_.focused;
  pressed_on_focused_host_ = event.IsOnlyLeftMouseButton() && was_focused &&
                             host_fits_ &&
                             host_rect_.Contains(event.location());
  // A click on the bar's empty area focuses its pane; dragging the bar across
  // another pane swaps them.
  if (focus_callback_) {
    focus_callback_.Run();
  }
  if (event.IsOnlyLeftMouseButton() && role_ == Role::kPane &&
      state_.pane_count >= 2 && drag_swap_callback_) {
    drag_press_origin_ = event.location();
    drag_swap_active_ = false;
  }
  return true;
}

bool OpenPaneChromeView::OnMouseDragged(const ui::MouseEvent& event) {
  if (!drag_swap_callback_ || role_ != Role::kPane || state_.pane_count < 2) {
    return false;
  }
  const gfx::Vector2d delta = event.location() - drag_press_origin_;
  if (!drag_swap_active_ &&
      (std::abs(delta.x()) >= 12 || std::abs(delta.y()) >= 12)) {
    drag_swap_active_ = true;
    pressed_on_focused_host_ = false;
  }
  if (drag_swap_active_) {
    drag_swap_callback_.Run(event.location(), /*finished=*/false);
    return true;
  }
  return false;
}

void OpenPaneChromeView::OnMouseReleased(const ui::MouseEvent& event) {
  const bool was_dragging = drag_swap_active_;
  const bool was_host_press = pressed_on_focused_host_;
  pressed_on_focused_host_ = false;
  if (drag_swap_active_ && drag_swap_callback_) {
    drag_swap_active_ = false;
    drag_swap_callback_.Run(event.location(), /*finished=*/true);
  }
  if (!was_dragging && was_host_press && host_fits_ &&
      host_rect_.Contains(event.location()) && host_click_callback_) {
    host_click_callback_.Run();
  }
}

void OpenPaneChromeView::OnMouseCaptureLost() {
  pressed_on_focused_host_ = false;
  if (drag_swap_active_ && drag_swap_callback_) {
    drag_swap_active_ = false;
    drag_swap_callback_.Run(drag_press_origin_, /*finished=*/true);
  }
}

void OpenPaneChromeView::Press(Control control) {
  if (focus_callback_) {
    focus_callback_.Run();
  }
  if (!callback_) {
    return;
  }
  views::View* anchor = buttons_[control];
  switch (control) {
    case kBackControl:
      callback_.Run(PaneCommand::kBack, anchor);
      break;
    case kForwardControl:
      callback_.Run(PaneCommand::kForward, anchor);
      break;
    case kReloadControl:
      callback_.Run(
          state_.is_loading ? PaneCommand::kStop : PaneCommand::kReload,
          anchor);
      break;
    case kCopyControl:
      callback_.Run(PaneCommand::kCopyUrl, anchor);
      break;
    case kSiteControlControl:
      callback_.Run(PaneCommand::kSiteControl, anchor);
      break;
    case kSplitMenuControl:
      ShowSplitMenu();
      break;
    case kCloseControl:
      callback_.Run(PaneCommand::kClosePane, anchor);
      break;
    case kControlCount:
      break;
  }
}

void OpenPaneChromeView::ShowSplitMenu() {
  if (menu_runner_ && menu_runner_->IsRunning()) {
    return;
  }
  menu_model_ = std::make_unique<ui::SimpleMenuModel>(this);
  menu_model_->AddItem(kMenuAddSplit, u"Add Split");
  menu_model_->AddItem(kMenuSwap, u"Swap");
  menu_model_->AddItem(kMenuOrientation,
                       state_.orientation == SplitOrientation::kHorizontal
                           ? u"Vertical Split"
                           : u"Horizontal Split");
  menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
  menu_model_->AddItem(kMenuSeparate, u"Separate Tab");
  menu_model_->AddItem(kMenuClose, u"Close Pane");
  menu_runner_ = std::make_unique<views::MenuRunner>(
      menu_model_.get(), views::MenuRunner::HAS_MNEMONICS);
  menu_runner_->RunMenuAt(
      GetWidget(), nullptr, buttons_[kSplitMenuControl]->GetBoundsInScreen(),
      views::MenuAnchorPosition::kTopRight, ui::mojom::MenuSourceType::kMouse);
}

void OpenPaneChromeView::ExecuteCommand(int command_id, int event_flags) {
  if (!callback_) {
    return;
  }
  views::View* anchor = buttons_[kSplitMenuControl];
  switch (command_id) {
    case kMenuAddSplit:
      callback_.Run(PaneCommand::kAddSplit, anchor);
      break;
    case kMenuSwap:
      callback_.Run(PaneCommand::kSwapPanes, anchor);
      break;
    case kMenuOrientation:
      callback_.Run(PaneCommand::kToggleOrientation, anchor);
      break;
    case kMenuSeparate:
      callback_.Run(PaneCommand::kSeparateTab, anchor);
      break;
    case kMenuClose:
      callback_.Run(PaneCommand::kClosePane, anchor);
      break;
    default:
      break;
  }
}

bool OpenPaneChromeView::IsCommandIdEnabled(int command_id) const {
  switch (command_id) {
    case kMenuAddSplit:
      return state_.pane_count < 4;
    case kMenuSwap:
      return state_.pane_count >= 2;
    default:
      return true;
  }
}

BEGIN_METADATA(OpenPaneChromeView)
END_METADATA

// ===========================================================================
// C. OpenSplitContainerView.
// ===========================================================================

namespace split_internal {

// Soft rounded nine-patch drop shadow rendered behind each split pane.
class SplitPaneShadowView : public views::View {
  METADATA_HEADER(SplitPaneShadowView, views::View)

 public:
  SplitPaneShadowView() {
    SetPaintToLayer(ui::LAYER_NINE_PATCH);
    layer()->SetFillsBoundsOpaquely(false);
    SetCanProcessEventsWithinSubtree(false);
    GetViewAccessibility().SetIsInvisible(true);
    margin_ = static_cast<int>(std::ceil(3 * kSigma + std::abs(kOffsetY))) + 1;
  }

  void SetContentBounds(const gfx::Rect& content) {
    gfx::Rect b = content;
    b.Outset(margin_);
    SetBoundsRect(b);
    UpdateImageIfNeeded();
    layer()->AsNinePatch()->UpdateNinePatchOcclusion(
        gfx::Rect(margin_, margin_, content.width(), content.height()));
  }

  // views::View:
  void AddedToWidget() override {
    scale_ = 0.f;
    UpdateImageIfNeeded();
    if (views::Widget* widget = GetWidget()) {
      UpdateActiveOpacity(widget->ShouldPaintAsActive());
      paint_as_active_subscription_ =
          widget->RegisterPaintAsActiveChangedCallback(base::BindRepeating(
              &SplitPaneShadowView::OnPaintAsActiveChanged,
              base::Unretained(this)));
    }
  }

  void RemovedFromWidget() override {
    paint_as_active_subscription_ = {};
  }

  void OnDeviceScaleFactorChanged(float old_scale, float new_scale) override {
    scale_ = 0.f;
    UpdateImageIfNeeded();
  }

 private:
  static constexpr float kRadius =
      static_cast<float>(split_metrics::kPanelCornerRadius);
  static constexpr float kSigma = 3.0f;
  static constexpr float kOpacity = 0.25f;
  static constexpr float kOffsetY = 1.0f;

  void OnPaintAsActiveChanged() {
    if (const views::Widget* widget = GetWidget()) {
      UpdateActiveOpacity(widget->ShouldPaintAsActive());
    }
  }

  void UpdateActiveOpacity(bool active) {
    if (layer()) {
      layer()->SetOpacity(active ? 1.0f : 0.55f);
    }
  }

  void UpdateImageIfNeeded() {
    const views::Widget* widget = GetWidget();
    const float scale = widget && widget->GetCompositor()
                            ? widget->GetCompositor()->device_scale_factor()
                            : 1.0f;
    if (scale == scale_) {
      return;
    }
    scale_ = scale;
    const int corner = margin_ + static_cast<int>(std::ceil(kRadius));
    const int size = 2 * corner + 1;
    gfx::Canvas canvas(gfx::Size(size, size), scale, /*is_opaque=*/false);
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setColor(SkColorSetA(
        SK_ColorBLACK, static_cast<U8CPU>(std::lround(kOpacity * 255))));
    flags.setImageFilter(sk_make_sp<cc::BlurPaintFilter>(
        kSigma, kSigma, SkTileMode::kDecal, nullptr));
    canvas.DrawRoundRect(
        gfx::RectF(margin_, margin_ + kOffsetY, size - 2 * margin_,
                   size - 2 * margin_),
        kRadius, flags);
    layer()->AsNinePatch()->UpdateNinePatchLayerImage(
        gfx::ImageSkia(gfx::ImageSkiaRep(canvas.GetBitmap(), scale)));
    layer()->AsNinePatch()->UpdateNinePatchLayerAperture(
        gfx::Rect(corner, corner, 1, 1));
    layer()->AsNinePatch()->UpdateNinePatchLayerBorder(
        gfx::Rect(corner, corner, 2 * corner, 2 * corner));
  }

  int margin_ = 0;
  float scale_ = 0.f;
  base::CallbackListSubscription paint_as_active_subscription_;
};

BEGIN_METADATA(SplitPaneShadowView)
END_METADATA

// The 2 pt ring on the focused pane, and a quiet 1 pt inset border on
// unfocused split panes. It paints on its own layer above the page's native
// view and never takes events (Chromium's ContentsContainerOutline uses the
// same arrangement).
class FocusRingView : public views::View {
  METADATA_HEADER(FocusRingView, views::View)

 public:
  FocusRingView() {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    SetCanProcessEventsWithinSubtree(false);
    GetViewAccessibility().SetIsInvisible(true);
  }

  void SetColor(SkColor color) {
    if (color_ == color) {
      return;
    }
    color_ = color;
    SchedulePaint();
  }

  void SetFocused(bool focused) {
    if (focused_ == focused) {
      return;
    }
    focused_ = focused;
    SchedulePaint();
  }

  void SetDarkContent(bool dark) {
    if (dark_content_ == dark) {
      return;
    }
    dark_content_ = dark;
    SchedulePaint();
  }

  // views::View:
  void AddedToWidget() override {
    if (views::Widget* widget = GetWidget()) {
      window_active_ = widget->ShouldPaintAsActive();
      paint_as_active_subscription_ =
          widget->RegisterPaintAsActiveChangedCallback(base::BindRepeating(
              &FocusRingView::OnPaintAsActiveChanged, base::Unretained(this)));
      SchedulePaint();
    }
  }

  void RemovedFromWidget() override { paint_as_active_subscription_ = {}; }

  void OnPaint(gfx::Canvas* canvas) override {
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setStyle(cc::PaintFlags::kStroke_Style);
    gfx::RectF r(GetLocalBounds());
    if (focused_) {
      // WebContentContainer: path inset 1 pt, radius cornerRadius - 1, width 2.
      // Refined alpha: 0.78 when active, 0.35 when the browser window is inactive.
      flags.setStrokeWidth(split_metrics::kRingWidth);
      flags.setColor(
          secondary::WithAlpha(color_, window_active_ ? 0.78f : 0.35f));
      r.Inset(split_metrics::kRingWidth / 2.f);
      canvas->DrawRoundRect(
          r, split_metrics::kPanelCornerRadius - split_metrics::kRingWidth / 2.f,
          flags);
      return;
    }
    // Unfocused split pane: subtle 1 DIP inset border.
    flags.setStrokeWidth(1.f);
    flags.setColor(dark_content_ ? SkColorSetARGB(26, 0xFF, 0xFF, 0xFF)
                                 : SkColorSetARGB(20, 0x00, 0x00, 0x00));
    r.Inset(0.5f);
    canvas->DrawRoundRect(r, split_metrics::kPanelCornerRadius - 0.5f, flags);
  }

 private:
  void OnPaintAsActiveChanged() {
    const views::Widget* widget = GetWidget();
    if (!widget) {
      return;
    }
    const bool active = widget->ShouldPaintAsActive();
    if (window_active_ != active) {
      window_active_ = active;
      SchedulePaint();
    }
  }

  SkColor color_ = SkColorSetRGB(0x45, 0x8A, 0xFF);
  bool focused_ = true;
  bool dark_content_ = false;
  bool window_active_ = true;
  base::CallbackListSubscription paint_as_active_subscription_;
};

BEGIN_METADATA(FocusRingView)
END_METADATA

// Translucent Space-accented drop preview overlay rendered above all panes
// while dragging a sidebar tab, link, or pane handle over the content panel.
class SplitDropOverlayView : public views::View {
  METADATA_HEADER(SplitDropOverlayView, views::View)

 public:
  SplitDropOverlayView() {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    SetCanProcessEventsWithinSubtree(false);
    GetViewAccessibility().SetIsInvisible(true);
    SetVisible(false);
  }

  void SetPreview(std::optional<SplitDropZone> zone,
                  const gfx::Rect& preview_rect,
                  SkColor accent) {
    zone_ = zone;
    preview_rect_ = preview_rect;
    accent_ = accent;
    SetVisible(zone_.has_value() && !preview_rect_.IsEmpty());
    SchedulePaint();
  }

  void OnPaint(gfx::Canvas* canvas) override {
    if (!zone_ || preview_rect_.IsEmpty()) {
      return;
    }
    gfx::RectF card(preview_rect_);
    card.Inset(4.f);
    if (card.IsEmpty()) {
      return;
    }
    constexpr float kRadius = 8.f;
    secondary::FillRoundRect(canvas, card, kRadius,
                             secondary::WithAlpha(accent_, 0.16f));
    secondary::StrokeRoundRect(canvas, card, kRadius,
                               secondary::WithAlpha(accent_, 0.72f), 2.f);

    std::u16string label;
    switch (*zone_) {
      case SplitDropZone::kLeft:
        label = u"Split Left";
        break;
      case SplitDropZone::kRight:
        label = u"Split Right";
        break;
      case SplitDropZone::kTop:
        label = u"Split Top";
        break;
      case SplitDropZone::kBottom:
        label = u"Split Bottom";
        break;
      case SplitDropZone::kReplacePane:
        label = u"Swap / Replace";
        break;
    }
    const gfx::FontList font =
        secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM);
    const int pill_w =
        std::min(static_cast<int>(card.width()) - 24,
                 secondary::TextWidth(label, font) + 28);
    constexpr int kPillH = 30;
    if (pill_w >= 48 && card.height() >= kPillH + 16) {
      const gfx::Rect pill(
          static_cast<int>(card.x() + (card.width() - pill_w) / 2.f),
          static_cast<int>(card.y() + (card.height() - kPillH) / 2.f), pill_w,
          kPillH);
      secondary::FillRoundRect(canvas, gfx::RectF(pill), kPillH / 2.f,
                               secondary::WithAlpha(accent_, 0.90f));
      secondary::DrawText(canvas, label, font, SK_ColorWHITE, pill,
                          gfx::Canvas::TEXT_ALIGN_CENTER);
    }
  }

 private:
  std::optional<SplitDropZone> zone_;
  gfx::Rect preview_rect_;
  SkColor accent_ = SkColorSetRGB(0x6F, 0x66, 0xD9);
};

BEGIN_METADATA(SplitDropOverlayView)
END_METADATA

// Interactive empty-pane fallback card shown when a split pane has no loaded
// tab yet ("Drop a tab or press ⌘T" + "Open Command Bar" button).
class EmptyPanePlaceholderView : public views::View {
  METADATA_HEADER(EmptyPanePlaceholderView, views::View)

 public:
  EmptyPanePlaceholderView(base::RepeatingClosure on_focus,
                           base::RepeatingClosure on_open_command_bar)
      : on_focus_(std::move(on_focus)),
        on_open_command_bar_(std::move(on_open_command_bar)) {
    button_ = AddChildView(std::make_unique<secondary::PaintedButton>(
        base::BindRepeating(&EmptyPanePlaceholderView::OnOpenPressed,
                            base::Unretained(this)),
        base::BindRepeating(&EmptyPanePlaceholderView::PaintActionButton,
                            base::Unretained(this)),
        u"Open Command Bar"));
  }

  void SetColors(SkColor page_bg, SkColor accent) {
    page_bg_ = page_bg;
    accent_ = accent;
    SchedulePaint();
    if (button_) {
      button_->SchedulePaint();
    }
  }

  void Layout(PassKey) override {
    const gfx::Rect b = GetLocalBounds();
    constexpr int kButtonW = 168;
    constexpr int kButtonH = 32;
    const int btn_x = b.x() + (b.width() - kButtonW) / 2;
    const int btn_y = b.y() + b.height() / 2 + 12;
    button_->SetBoundsRect(gfx::Rect(btn_x, btn_y, kButtonW, kButtonH));
  }

  bool OnMousePressed(const ui::MouseEvent& event) override {
    if (on_focus_) {
      on_focus_.Run();
    }
    return true;
  }

  void OnPaint(gfx::Canvas* canvas) override {
    const gfx::Rect b = GetLocalBounds();
    const bool dark = secondary::IsDark(page_bg_);
    const SkColor ink = dark ? SK_ColorWHITE : SK_ColorBLACK;

    // Centered subtle dashed/rounded placeholder frame.
    const int card_w = std::min(320, std::max(0, b.width() - 32));
    const int card_h = std::min(148, std::max(0, b.height() - 32));
    if (card_w > 60 && card_h > 60) {
      const gfx::RectF card(b.x() + (b.width() - card_w) / 2.f,
                            b.y() + (b.height() - card_h) / 2.f, card_w,
                            card_h);
      secondary::FillRoundRect(canvas, card, 12.f,
                               secondary::WithAlpha(ink, dark ? 0.05f : 0.03f));
      secondary::StrokeRoundRect(
          canvas, card, 12.f, secondary::WithAlpha(ink, dark ? 0.16f : 0.12f),
          1.f);
    }

    const std::u16string hint =
        u"Drop a tab or press " + secondary::PrimaryShortcutLabel(u'T');
    const gfx::Rect text_rect(b.x() + 20, b.y() + b.height() / 2 - 28,
                              std::max(0, b.width() - 40), 24);
    secondary::DrawText(
        canvas, hint, secondary::FontOfSize(14, gfx::Font::Weight::MEDIUM),
        secondary::WithAlpha(ink, 0.72f), text_rect,
        gfx::Canvas::TEXT_ALIGN_CENTER);
  }

 private:
  void OnOpenPressed() {
    if (on_focus_) {
      on_focus_.Run();
    }
    if (on_open_command_bar_) {
      on_open_command_bar_.Run();
    }
  }

  void PaintActionButton(gfx::Canvas* canvas,
                         const gfx::Rect& bounds,
                         bool hovered) {
    const SkColor fill = secondary::WithAlpha(accent_, hovered ? 0.95f : 0.82f);
    secondary::FillRoundRect(canvas, gfx::RectF(bounds), 8.f, fill);
    secondary::DrawText(canvas, u"Open Command Bar",
                        secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM),
                        SK_ColorWHITE, bounds, gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  base::RepeatingClosure on_focus_;
  base::RepeatingClosure on_open_command_bar_;
  raw_ptr<secondary::PaintedButton> button_ = nullptr;
  SkColor page_bg_ = SK_ColorWHITE;
  SkColor accent_ = SkColorSetRGB(0x6F, 0x66, 0xD9);
};

BEGIN_METADATA(EmptyPanePlaceholderView)
END_METADATA

// One pane: optional bar, the live WebView (or an empty-pane placeholder),
// optional docked/overlaid DevTools view, and the focus ring. Observes its
// WebContents for loading, history and background color so the bar stays
// current without a model round trip.
class SplitPaneView : public views::View,
                      public content::WebContentsObserver,
                      public views::ViewObserver {
  METADATA_HEADER(SplitPaneView, views::View)

 public:
  SplitPaneView(OpenSplitContainerView* container, const SplitPaneSpec& spec)
      : container_(container), spec_(spec) {
    chrome_ = AddChildView(std::make_unique<OpenPaneChromeView>(
        OpenPaneChromeView::Role::kPane,
        base::BindRepeating(&SplitPaneView::OnChromeCommand,
                            base::Unretained(this))));
    chrome_->SetFocusRequestCallback(base::BindRepeating(
        &SplitPaneView::RequestFocusFromBar, base::Unretained(this)));
    chrome_->SetHostClickCallback(base::BindRepeating(
        &SplitPaneView::OnChromeHostClicked, base::Unretained(this)));
    chrome_->SetDragSwapCallback(base::BindRepeating(
        &SplitPaneView::OnChromeDragSwap, base::Unretained(this)));
    web_view_ = AddChildView(std::make_unique<views::WebView>());
    empty_placeholder_ = AddChildView(std::make_unique<EmptyPanePlaceholderView>(
        base::BindRepeating(&SplitPaneView::RequestFocusFromBar,
                            base::Unretained(this)),
        base::BindRepeating(&SplitPaneView::RequestEmptyPaneCommandBar,
                            base::Unretained(this))));
    empty_placeholder_->SetVisible(false);
    ring_ = AddChildView(std::make_unique<FocusRingView>());
    ring_->SetVisible(false);
    AttachWebContents();
  }

  SplitPaneView(const SplitPaneView&) = delete;
  SplitPaneView& operator=(const SplitPaneView&) = delete;

  ~SplitPaneView() override {
    ClearDevToolsOverlay();
    Observe(nullptr);
    web_view_->SetWebContents(nullptr);
  }

  const ItemID& tab_id() const { return spec_.tab_id; }
  views::WebView* web_view() { return web_view_; }
  views::View* devtools_overlay() const { return devtools_view_; }

  // Releases the shown WebContents when the next Update() brings another, so
  // the old one is free before any pane attaches it. Update() then sees a
  // change and attaches the new one.
  void DetachWebContentsIfChanging(content::WebContents* next) {
    if (spec_.web_contents == next || !spec_.web_contents) {
      return;
    }
    Observe(nullptr);
    web_view_->SetWebContents(nullptr);
    web_view_->SetVisible(false);
    spec_.web_contents = nullptr;
    applied_radii_.reset();
  }
  OpenPaneChromeView* chrome() { return chrome_; }

  struct Context {
    bool show_bar = false;
    OpenPaneChromeView::Role role = OpenPaneChromeView::Role::kPane;
    bool focused = false;
    bool show_ring = false;
    bool dark_content = false;
    size_t pane_count = 1;
    SplitOrientation orientation = SplitOrientation::kHorizontal;
    SkColor fallback_color = SK_ColorWHITE;
    SkColor ring_color = SkColorSetRGB(0x31, 0x39, 0xFF);
  };

  void Update(const SplitPaneSpec& spec, const Context& context) {
    const bool contents_changed = spec.web_contents != spec_.web_contents;
    const bool bar_changed = context.show_bar != context_.show_bar;
    const bool placeholder_changed =
        spec.is_empty_placeholder != spec_.is_empty_placeholder ||
        spec.is_sleeping != spec_.is_sleeping;
    spec_ = spec;
    context_ = context;
    if (contents_changed) {
      AttachWebContents();
    }
    chrome_->SetVisible(context_.show_bar);
    chrome_->SetRole(context_.role);
    ring_->SetVisible(context_.show_ring);
    ring_->SetFocused(context_.focused);
    ring_->SetDarkContent(context_.dark_content);
    ring_->SetColor(context_.ring_color);
    UpdateEmptyPlaceholder();
    RefreshChrome();
    if (bar_changed || contents_changed || placeholder_changed) {
      applied_radii_.reset();
      InvalidateLayout();
    }
    SchedulePaint();
  }

  void SetBarVisible(bool show_bar, OpenPaneChromeView::Role role) {
    if (context_.show_bar == show_bar && context_.role == role) {
      return;
    }
    context_.show_bar = show_bar;
    context_.role = role;
    chrome_->SetVisible(show_bar);
    chrome_->SetRole(role);
    RefreshChrome();
    applied_radii_.reset();
    InvalidateLayout();
    SchedulePaint();
  }

  void SetFocused(bool focused) {
    if (context_.focused == focused) {
      return;
    }
    context_.focused = focused;
    ring_->SetVisible(context_.show_ring);
    ring_->SetFocused(focused);
    RefreshChrome();
  }

  void SetDarkContent(bool dark) {
    if (context_.dark_content == dark) {
      return;
    }
    context_.dark_content = dark;
    ring_->SetDarkContent(dark);
  }

  void SetBackgroundOverride(SkColor color) {
    spec_.page_background = color;
    UpdateEmptyPlaceholder();
    RefreshChrome();
    SchedulePaint();
  }

  void SetHostLabel(const std::u16string& host) {
    spec_.host_label = host;
    RefreshChrome();
  }

  void SetSiteControlsAvailable(bool available) {
    spec_.site_controls_available = available;
    RefreshChrome();
  }

  void SetDevToolsOverlay(views::View* devtools_view,
                          PaneDevToolsDock dock,
                          float ratio) {
    ClearDevToolsOverlay();
    if (!devtools_view) {
      return;
    }
    devtools_dock_ = dock;
    devtools_ratio_ = std::clamp(ratio, 0.15f, 0.80f);
    devtools_view_ = devtools_view;
    devtools_owned_ = false;
    if (devtools_view->parent() != this) {
      // Non-owned external view: observe its lifetime, lay it out in our
      // coordinates if already added to our subtree.
      devtools_observation_.Observe(devtools_view);
    } else {
      devtools_observation_.Observe(devtools_view);
      ReorderChildView(ring_, children().size() - 1);
    }
    InvalidateLayout();
    SchedulePaint();
  }

  void SetDevToolsOverlayOwned(std::unique_ptr<views::View> devtools_view,
                               PaneDevToolsDock dock,
                               float ratio) {
    ClearDevToolsOverlay();
    if (!devtools_view) {
      return;
    }
    devtools_dock_ = dock;
    devtools_ratio_ = std::clamp(ratio, 0.15f, 0.80f);
    devtools_view_ = AddChildView(std::move(devtools_view));
    devtools_owned_ = true;
    devtools_observation_.Observe(devtools_view_.get());
    ReorderChildView(ring_, children().size() - 1);
    InvalidateLayout();
    SchedulePaint();
  }

  void ClearDevToolsOverlay() {
    devtools_observation_.Reset();
    if (devtools_view_) {
      views::View* doomed = devtools_view_.ExtractAsDangling();
      const bool owned = devtools_owned_;
      devtools_owned_ = false;
      if (owned && doomed->parent() == this) {
        RemoveChildViewT(doomed);
      }
      InvalidateLayout();
      SchedulePaint();
    }
  }

  // views::ViewObserver:
  void OnViewIsDeleting(views::View* observed_view) override {
    if (observed_view == devtools_view_) {
      devtools_observation_.Reset();
      devtools_view_ = nullptr;
      devtools_owned_ = false;
      InvalidateLayout();
      SchedulePaint();
    }
  }

  // views::View:
  void Layout(PassKey) override {
    const gfx::Rect bounds = GetLocalBounds();
    int top = 0;
    if (context_.show_bar) {
      chrome_->SetBoundsRect(
          gfx::Rect(0, 0, bounds.width(), split_metrics::kBarHeight));
      top = split_metrics::kBarHeight;
    }
    gfx::Rect content_area(0, top, bounds.width(),
                           std::max(0, bounds.height() - top));
    gfx::Rect page_rect = content_area;
    if (devtools_view_ && devtools_view_->GetVisible()) {
      gfx::Rect devtools_rect;
      switch (devtools_dock_) {
        case PaneDevToolsDock::kBottom: {
          const int dt_h = std::max(
              100, static_cast<int>(
                       std::lround(content_area.height() * devtools_ratio_)));
          const int clamped_h = std::min(dt_h, content_area.height());
          page_rect.set_height(content_area.height() - clamped_h);
          devtools_rect = gfx::Rect(content_area.x(), page_rect.bottom(),
                                    content_area.width(), clamped_h);
          break;
        }
        case PaneDevToolsDock::kRight: {
          const int dt_w = std::max(
              160, static_cast<int>(
                       std::lround(content_area.width() * devtools_ratio_)));
          const int clamped_w = std::min(dt_w, content_area.width());
          page_rect.set_width(content_area.width() - clamped_w);
          devtools_rect = gfx::Rect(page_rect.right(), content_area.y(),
                                    clamped_w, content_area.height());
          break;
        }
        case PaneDevToolsDock::kOverlay:
          devtools_rect = content_area;
          break;
      }
      if (devtools_view_->parent() == this) {
        devtools_view_->SetBoundsRect(devtools_rect);
      } else if (devtools_view_->parent()) {
        gfx::Point origin = devtools_rect.origin();
        views::View::ConvertPointToTarget(this, devtools_view_->parent(),
                                          &origin);
        devtools_view_->SetBoundsRect(gfx::Rect(origin, devtools_rect.size()));
      }
    }
    web_view_->SetBoundsRect(page_rect);
    empty_placeholder_->SetBoundsRect(page_rect);
    ring_->SetBoundsRect(bounds);
    ApplyCornerRadii();
  }

  void OnPaint(gfx::Canvas* canvas) override {
    // Shows under the page while it loads, and for placeholder panes.
    secondary::FillRoundRect(canvas, gfx::RectF(GetLocalBounds()),
                             split_metrics::kPanelCornerRadius, PageColor());
  }

  // content::WebContentsObserver:
  void DidStartLoading() override { RefreshChrome(); }
  void DidStopLoading() override { RefreshChrome(); }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    RefreshChrome();
  }
  void OnBackgroundColorChanged() override {
    UpdateEmptyPlaceholder();
    RefreshChrome();
    SchedulePaint();
  }
  void OnWebContentsFocused(content::RenderWidgetHost* host) override {
    container_->OnPaneFocused(spec_.tab_id);
  }
  void WebContentsDestroyed() override {
    spec_.web_contents = nullptr;
    web_view_->SetWebContents(nullptr);
    web_view_->SetVisible(false);
    UpdateEmptyPlaceholder();
    RefreshChrome();
  }

 private:
  void AttachWebContents() {
    content::WebContents* contents = spec_.web_contents.get();
    Observe(contents);
    if (web_view_->web_contents() != contents) {
      web_view_->SetWebContents(contents);
    }
    web_view_->SetVisible(contents != nullptr && !spec_.is_empty_placeholder);
    UpdateEmptyPlaceholder();
    applied_radii_.reset();
    ApplyCornerRadii();
  }

  void UpdateEmptyPlaceholder() {
    const bool show_empty =
        spec_.is_empty_placeholder ||
        (spec_.web_contents == nullptr && !spec_.is_sleeping);
    empty_placeholder_->SetVisible(show_empty);
    empty_placeholder_->SetColors(PageColor(), context_.ring_color);
  }

  void ApplyCornerRadii() {
    if (!web_view_->web_contents()) {
      return;
    }
    const float r = split_metrics::kPanelCornerRadius;
    const gfx::RoundedCornersF radii = context_.show_bar
                                           ? gfx::RoundedCornersF(0, 0, r, r)
                                           : gfx::RoundedCornersF(r);
    if (applied_radii_ == radii) {
      return;
    }
    // Returns false until the native view is attached; retried next layout.
    if (web_view_->holder()->SetNativeViewCornerRadii(radii)) {
      applied_radii_ = radii;
    }
  }

  SkColor PageColor() const {
    if (spec_.page_background) {
      return *spec_.page_background;
    }
    if (spec_.web_contents) {
      if (std::optional<SkColor> color =
              spec_.web_contents->GetBackgroundColor()) {
        if (SkColorGetA(*color) == 0xFF) {
          return *color;
        }
      }
    }
    return context_.fallback_color;
  }

  std::u16string HostLabel() const {
    if (!spec_.host_label.empty() || !spec_.web_contents) {
      return spec_.host_label;
    }
    std::string host(spec_.web_contents->GetLastCommittedURL().host());
    if (host.starts_with("www.")) {
      host.erase(0, 4);
    }
    return base::UTF8ToUTF16(host);
  }

  void RefreshChrome() {
    const SkColor page = PageColor();
    web_view_->SetBackground(views::CreateSolidBackground(page));
    if (!context_.show_bar) {
      return;
    }
    OpenPaneChromeView::State state;
    state.focused = context_.focused;
    content::WebContents* contents = spec_.web_contents.get();
    if (contents) {
      state.can_go_back = contents->GetController().CanGoBack();
      state.can_go_forward = contents->GetController().CanGoForward();
      state.is_loading = contents->IsLoading();
    }
    state.site_controls_available = spec_.site_controls_available;
    state.hides_copy = spec_.hides_copy;
    state.host = HostLabel();
    state.background = page;
    state.pane_count = context_.pane_count;
    state.orientation = context_.orientation;
    chrome_->SetState(state);
  }

  void RequestFocusFromBar() { container_->OnPaneFocused(spec_.tab_id); }

  void OnChromeHostClicked() {
    container_->OnPaneHostClicked(spec_.tab_id, chrome_);
  }

  void RequestEmptyPaneCommandBar() {
    container_->OnEmptyPaneOpenCommandBar(spec_.tab_id);
  }

  void OnChromeDragSwap(const gfx::Point& location_in_chrome, bool finished) {
    gfx::Point in_container = location_in_chrome;
    views::View::ConvertPointToTarget(chrome_, container_, &in_container);
    container_->OnPaneChromeDragSwap(spec_.tab_id, in_container, finished);
  }

  void OnChromeCommand(PaneCommand command, views::View* anchor) {
    container_->OnPaneCommand(spec_.tab_id, command, anchor);
  }

  raw_ptr<OpenSplitContainerView> container_;
  SplitPaneSpec spec_;
  Context context_;
  raw_ptr<OpenPaneChromeView> chrome_ = nullptr;
  raw_ptr<views::WebView> web_view_ = nullptr;
  raw_ptr<EmptyPanePlaceholderView> empty_placeholder_ = nullptr;
  raw_ptr<views::View> devtools_view_ = nullptr;
  bool devtools_owned_ = false;
  PaneDevToolsDock devtools_dock_ = PaneDevToolsDock::kBottom;
  float devtools_ratio_ = 0.35f;
  base::ScopedObservation<views::View, views::ViewObserver>
      devtools_observation_{this};
  raw_ptr<FocusRingView> ring_ = nullptr;
  std::optional<gfx::RoundedCornersF> applied_radii_;
};

BEGIN_METADATA(SplitPaneView)
END_METADATA

// The 10 pt gap between two panes. Dragging it resizes the two neighbours
// (SplitDividerView.swift); a double-click makes them equal.
class SplitDividerView : public views::View {
  METADATA_HEADER(SplitDividerView, views::View)

 public:
  SplitDividerView(OpenSplitContainerView* container, size_t pair_index)
      : container_(container), pair_index_(pair_index) {
    GetViewAccessibility().SetIsInvisible(true);
  }

  void set_pair_index(size_t index) { pair_index_ = index; }
  void set_orientation(SplitOrientation orientation) {
    orientation_ = orientation;
  }
  void set_dark_content(bool dark) {
    if (dark_content_ != dark) {
      dark_content_ = dark;
      SchedulePaint();
    }
  }

  // views::View:
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return orientation_ == SplitOrientation::kHorizontal
               ? ui::mojom::CursorType::kColumnResize
               : ui::mojom::CursorType::kRowResize;
  }

  bool OnMousePressed(const ui::MouseEvent& event) override {
    if (!event.IsOnlyLeftMouseButton()) {
      return false;
    }
    start_ = ToContainer(event);
    container_->BeginDividerDrag(pair_index_);
    if (event.GetClickCount() == 2) {
      container_->UpdateDividerDrag(pair_index_, 0, /*equalize=*/true);
      container_->EndDividerDrag(pair_index_, /*commit=*/true);
      dragging_ = false;
      return true;
    }
    dragging_ = true;
    SchedulePaint();
    return true;
  }

  bool OnMouseDragged(const ui::MouseEvent& event) override {
    if (!dragging_) {
      return false;
    }
    const gfx::Point p = ToContainer(event);
    const int delta = orientation_ == SplitOrientation::kHorizontal
                          ? p.x() - start_.x()
                          : p.y() - start_.y();
    container_->UpdateDividerDrag(pair_index_, delta, /*equalize=*/false);
    return true;
  }

  void OnMouseReleased(const ui::MouseEvent& event) override { Finish(); }
  void OnMouseCaptureLost() override { Finish(); }

  void OnMouseEntered(const ui::MouseEvent& event) override {
    hovered_ = true;
    SchedulePaint();
  }
  void OnMouseExited(const ui::MouseEvent& event) override {
    hovered_ = false;
    if (!dragging_) {
      if (views::Widget* w = GetWidget()) {
        w->SetCursor(ui::Cursor());
      }
    }
    SchedulePaint();
  }

  void OnPaint(gfx::Canvas* canvas) override {
    if (!hovered_ && !dragging_) {
      return;
    }
    // Grabber pill while hovered or dragged. guess: Arc shows no grabber in
    // F0081; a quiet 4 × 32 pill helps discoverability and stays faint.
    const gfx::Rect b = GetLocalBounds();
    const bool horizontal = orientation_ == SplitOrientation::kHorizontal;
    const int length = std::min(32, horizontal ? b.height() : b.width());
    const gfx::RectF pill =
        horizontal ? gfx::RectF(b.CenterPoint().x() - 2.f,
                                b.CenterPoint().y() - length / 2.f, 4, length)
                   : gfx::RectF(b.CenterPoint().x() - length / 2.f,
                                b.CenterPoint().y() - 2.f, length, 4);
    const SkColor pill_color = dark_content_ ? SK_ColorWHITE : SK_ColorBLACK;
    secondary::FillRoundRect(
        canvas, pill, 2.f,
        secondary::WithAlpha(pill_color, dragging_ ? 0.55f : 0.35f));
  }

 private:
  gfx::Point ToContainer(const ui::MouseEvent& event) const {
    gfx::Point p = event.location();
    views::View::ConvertPointToTarget(this, container_, &p);
    return p;
  }

  void Finish() {
    if (!dragging_) {
      return;
    }
    dragging_ = false;
    container_->EndDividerDrag(pair_index_, /*commit=*/true);
    SchedulePaint();
  }

  raw_ptr<OpenSplitContainerView> container_;
  size_t pair_index_;
  SplitOrientation orientation_ = SplitOrientation::kHorizontal;
  bool dark_content_ = true;
  gfx::Point start_;
  bool dragging_ = false;
  bool hovered_ = false;
};

BEGIN_METADATA(SplitDividerView)
END_METADATA

}  // namespace split_internal

namespace {

std::vector<double> NormalizedFractions(const std::vector<double>& raw,
                                        size_t count) {
  std::vector<double> out(count, count ? 1.0 / count : 0.0);
  if (raw.size() != count || count == 0) {
    return out;
  }
  double sum = 0;
  for (double f : raw) {
    if (!std::isfinite(f) || f < 0) {
      return out;
    }
    sum += f;
  }
  if (sum <= 0) {
    return out;
  }
  for (size_t i = 0; i < count; ++i) {
    out[i] = raw[i] / sum;
  }
  return out;
}

}  // namespace

OpenSplitContainerView::OpenSplitContainerView(
    OpenSplitContainerDelegate* delegate)
    : delegate_(delegate) {
  GetViewAccessibility().SetName(u"Page content");
  drop_overlay_ =
      AddChildView(std::make_unique<split_internal::SplitDropOverlayView>());
}

OpenSplitContainerView::~OpenSplitContainerView() = default;

// static
SplitDropZone OpenSplitContainerView::ComputeDropZoneAt(
    const gfx::Rect& bounds,
    const gfx::Point& point) {
  if (bounds.IsEmpty()) {
    return SplitDropZone::kReplacePane;
  }
  const int edge_x =
      std::min(bounds.width() / 2,
               std::max(80, static_cast<int>(bounds.width() * 0.25)));
  const int edge_y =
      std::min(bounds.height() / 2,
               std::max(80, static_cast<int>(bounds.height() * 0.25)));
  const int local_x = point.x() - bounds.x();
  const int local_y = point.y() - bounds.y();
  if (local_x < edge_x) {
    return SplitDropZone::kLeft;
  }
  if (local_x > bounds.width() - edge_x) {
    return SplitDropZone::kRight;
  }
  if (local_y < edge_y) {
    return SplitDropZone::kTop;
  }
  if (local_y > bounds.height() - edge_y) {
    return SplitDropZone::kBottom;
  }
  return SplitDropZone::kReplacePane;
}

// static
gfx::Rect OpenSplitContainerView::ComputeDropPreviewRect(
    const gfx::Rect& container_bounds,
    const std::vector<gfx::Rect>& pane_bounds,
    SplitDropZone zone,
    std::optional<size_t> target_pane_index) {
  if (container_bounds.IsEmpty()) {
    return gfx::Rect();
  }
  const gfx::Rect target =
      (target_pane_index && *target_pane_index < pane_bounds.size())
          ? pane_bounds[*target_pane_index]
          : container_bounds;
  switch (zone) {
    case SplitDropZone::kLeft:
      return gfx::Rect(target.x(), target.y(), target.width() / 2,
                       target.height());
    case SplitDropZone::kRight:
      return gfx::Rect(target.x() + target.width() / 2, target.y(),
                       target.width() - target.width() / 2, target.height());
    case SplitDropZone::kTop:
      return gfx::Rect(target.x(), target.y(), target.width(),
                       target.height() / 2);
    case SplitDropZone::kBottom:
      return gfx::Rect(target.x(), target.y() + target.height() / 2,
                       target.width(), target.height() - target.height() / 2);
    case SplitDropZone::kReplacePane:
      return target;
  }
  return target;
}

// static
std::vector<gfx::Rect> OpenSplitContainerView::ComputePaneFrames(
    const gfx::Rect& content,
    SplitOrientation orientation,
    const std::vector<double>& fractions,
    size_t pane_count,
    int gap,
    int min_pane) {
  const size_t n = std::clamp<size_t>(pane_count, 1, 4);
  const bool horizontal = orientation == SplitOrientation::kHorizontal;
  const double axis =
      std::max(0, horizontal ? content.width() : content.height());
  const double g =
      std::min<double>(std::max(0, gap), n > 1 ? axis / (n - 1) : 0.0);
  const double usable = std::max(0.0, axis - g * (n - 1));
  const std::vector<double> f = NormalizedFractions(fractions, n);
  std::vector<double> sizes(n);
  for (size_t i = 0; i < n; ++i) {
    sizes[i] = f[i] * usable;
  }
  const double minimum = std::min<double>(std::max(0, min_pane), usable / n);
  if (usable < static_cast<double>(min_pane) * n) {
    std::fill(sizes.begin(), sizes.end(), usable / n);
  } else {
    for (size_t i = 0; i < n; ++i) {
      if (sizes[i] >= minimum) {
        continue;
      }
      double left = minimum - sizes[i];
      sizes[i] = minimum;
      std::vector<size_t> order(n);
      std::iota(order.begin(), order.end(), 0);
      std::sort(order.begin(), order.end(),
                [&](size_t a, size_t b) { return sizes[a] > sizes[b]; });
      for (size_t j : order) {
        if (j == i) {
          continue;
        }
        const double take = std::min(left, std::max(0.0, sizes[j] - minimum));
        sizes[j] -= take;
        left -= take;
        if (left <= 0) {
          break;
        }
      }
    }
  }
  // Integer boundaries; the last pane owns the remainder.
  double used = 0;
  for (size_t i = 0; i + 1 < n; ++i) {
    sizes[i] = std::floor(sizes[i]);
    used += sizes[i];
  }
  sizes[n - 1] = std::max(0.0, usable - used);

  std::vector<gfx::Rect> frames;
  frames.reserve(n);
  double cursor = 0;
  const int gap_px = static_cast<int>(std::lround(g));
  for (size_t i = 0; i < n; ++i) {
    const int start = static_cast<int>(std::lround(cursor));
    const int size = static_cast<int>(std::lround(sizes[i]));
    if (horizontal) {
      frames.emplace_back(content.x() + start, content.y(), size,
                          std::max(0, content.height()));
    } else {
      frames.emplace_back(content.x(), content.y() + start,
                          std::max(0, content.width()), size);
    }
    cursor += sizes[i] + gap_px;
  }
  return frames;
}

void OpenSplitContainerView::SetPresentation(SplitPresentation presentation) {
  presentation_ = std::move(presentation);
  if (presentation_.panes.size() > 4) {
    presentation_.panes.resize(4);
  }
  if (presentation_.panes.size() < 2) {
    // One pane is a single tab even if a split id was passed.
    presentation_.split_id.reset();
  }
  drag_initial_frames_.clear();
  drag_current_frames_.clear();

  // Detach before attach: a WebContents can move between panes (or from a
  // removed pane to a new one). Every pane that lets go of a WebContents does
  // so before any pane attaches one, so no late detach pulls a WebContents's
  // native view out of the pane that now shows it.
  // 1. Remove the panes that are no longer shown (their destructors detach).
  {
    std::vector<raw_ptr<split_internal::SplitPaneView>> kept;
    kept.reserve(panes_.size());
    for (auto& old : panes_) {
      if (!old) {
        continue;
      }
      const bool wanted = std::any_of(
          presentation_.panes.begin(), presentation_.panes.end(),
          [&](const SplitPaneSpec& spec) {
            return spec.tab_id == old->tab_id();
          });
      if (wanted) {
        kept.push_back(old);
      } else {
        split_internal::SplitPaneView* doomed = old.get();
        old = nullptr;
        RemoveChildViewT(doomed);
      }
    }
    panes_ = std::move(kept);
  }
  // 2. Kept panes whose WebContents changes release the old one now.
  for (const SplitPaneSpec& spec : presentation_.panes) {
    if (split_internal::SplitPaneView* pane = FindPane(spec.tab_id)) {
      pane->DetachWebContentsIfChanging(spec.web_contents);
    }
  }
  // 3. Create the new panes (they attach in their constructors); kept panes
  // attach their new WebContents in Update() below.
  std::vector<raw_ptr<split_internal::SplitPaneView>> next;
  next.reserve(presentation_.panes.size());
  for (const SplitPaneSpec& spec : presentation_.panes) {
    split_internal::SplitPaneView* pane = FindPane(spec.tab_id);
    if (!pane) {
      pane = AddChildView(
          std::make_unique<split_internal::SplitPaneView>(this, spec));
    }
    next.push_back(pane);
  }
  panes_ = std::move(next);
  for (size_t i = 0; i < panes_.size(); ++i) {
    ReorderChildView(panes_[i], i);
  }

  live_fractions_ =
      NormalizedFractions(presentation_.fractions, presentation_.panes.size());
  const bool split = is_split();
  const bool dark_content = EffectiveDarkContent();
  const ItemID focused = presentation_.focused_pane_id.value_or(
      presentation_.panes.empty() ? ItemID() : presentation_.panes[0].tab_id);
  for (size_t i = 0; i < panes_.size(); ++i) {
    split_internal::SplitPaneView::Context context;
    context.show_bar = split || presentation_.show_single_pane_toolbar;
    context.role = split ? OpenPaneChromeView::Role::kPane
                         : OpenPaneChromeView::Role::kToolbar;
    context.focused = split ? presentation_.panes[i].tab_id == focused : true;
    context.show_ring = split;
    context.dark_content = dark_content;
    context.pane_count = panes_.size();
    context.orientation = presentation_.orientation;
    context.fallback_color = presentation_.fallback_page_color;
    context.ring_color = presentation_.focus_ring_color;
    panes_[i]->Update(presentation_.panes[i], context);
  }
  SyncPaneShadows();
  SyncDividers();
  ReorderSplitChildren();
  UpdateDropOverlay();
  InvalidateLayout();
  SchedulePaint();
}

void OpenSplitContainerView::SetSinglePaneToolbarVisible(bool shows_toolbar) {
  if (presentation_.show_single_pane_toolbar == shows_toolbar) {
    return;
  }
  presentation_.show_single_pane_toolbar = shows_toolbar;
  if (!is_split() && panes_.size() == 1 && panes_[0]) {
    panes_[0]->SetBarVisible(shows_toolbar, OpenPaneChromeView::Role::kToolbar);
  }
}

void OpenSplitContainerView::SetDropZonePreview(
    std::optional<SplitDropZone> zone,
    std::optional<size_t> target_pane_index) {
  if (drop_zone_preview_ == zone &&
      drop_target_pane_index_ == target_pane_index) {
    return;
  }
  drop_zone_preview_ = zone;
  drop_target_pane_index_ = target_pane_index;
  UpdateDropOverlay();
}

void OpenSplitContainerView::SetDropOverlayAccentColor(SkColor color) {
  drop_overlay_accent_ = color;
  UpdateDropOverlay();
}

void OpenSplitContainerView::SetDarkContent(bool dark) {
  if (dark_content_override_ == dark) {
    return;
  }
  dark_content_override_ = dark;
  for (auto& pane : panes_) {
    pane->SetDarkContent(dark);
  }
  for (auto& divider : dividers_) {
    divider->set_dark_content(dark);
  }
  SchedulePaint();
}

bool OpenSplitContainerView::EffectiveDarkContent() const {
  return dark_content_override_.value_or(
      secondary::IsDark(presentation_.fallback_page_color));
}

bool OpenSplitContainerView::SwapPanes(size_t index_a, size_t index_b) {
  if (index_a >= panes_.size() || index_b >= panes_.size() ||
      index_a == index_b) {
    return false;
  }
  std::swap(panes_[index_a], panes_[index_b]);
  if (index_a < presentation_.panes.size() &&
      index_b < presentation_.panes.size()) {
    std::swap(presentation_.panes[index_a], presentation_.panes[index_b]);
  }
  if (index_a < live_fractions_.size() && index_b < live_fractions_.size()) {
    std::swap(live_fractions_[index_a], live_fractions_[index_b]);
  }
  if (index_a < presentation_.fractions.size() &&
      index_b < presentation_.fractions.size()) {
    std::swap(presentation_.fractions[index_a],
              presentation_.fractions[index_b]);
  }
  ReorderSplitChildren();
  const bool split = is_split();
  ApplyFrames(ComputePaneFrames(GetLocalBounds(), presentation_.orientation,
                                live_fractions_, panes_.size(),
                                split ? split_metrics::kGap : 0,
                                split_metrics::kMinimumPane));
  SchedulePaint();
  if (delegate_ && presentation_.split_id) {
    delegate_->OnPanesSwapped(*presentation_.split_id, index_a, index_b);
  }
  return true;
}

views::WebView* OpenSplitContainerView::GetWebViewForPane(size_t index) {
  return index < panes_.size() && panes_[index] ? panes_[index]->web_view()
                                                : nullptr;
}

OpenPaneChromeView* OpenSplitContainerView::GetPaneChromeForPane(size_t index) {
  return index < panes_.size() && panes_[index] ? panes_[index]->chrome()
                                                : nullptr;
}

std::optional<ItemID> OpenSplitContainerView::GetTabIdForPane(
    size_t index) const {
  if (index >= panes_.size() || !panes_[index]) {
    return std::nullopt;
  }
  return panes_[index]->tab_id();
}

void OpenSplitContainerView::SetPaneDevToolsOverlay(size_t index,
                                                    views::View* devtools_view,
                                                    PaneDevToolsDock dock,
                                                    float ratio) {
  if (index < panes_.size() && panes_[index]) {
    panes_[index]->SetDevToolsOverlay(devtools_view, dock, ratio);
  }
}

void OpenSplitContainerView::SetPaneDevToolsOverlay(const ItemID& tab_id,
                                                    views::View* devtools_view,
                                                    PaneDevToolsDock dock,
                                                    float ratio) {
  if (auto index = FindPaneIndex(tab_id)) {
    SetPaneDevToolsOverlay(*index, devtools_view, dock, ratio);
  }
}

void OpenSplitContainerView::SetPaneDevToolsOverlayOwned(
    size_t index,
    std::unique_ptr<views::View> devtools_view,
    PaneDevToolsDock dock,
    float ratio) {
  if (index < panes_.size() && panes_[index]) {
    panes_[index]->SetDevToolsOverlayOwned(std::move(devtools_view), dock,
                                           ratio);
  }
}

void OpenSplitContainerView::ClearPaneDevToolsOverlay(size_t index) {
  if (index < panes_.size() && panes_[index]) {
    panes_[index]->ClearDevToolsOverlay();
  }
}

void OpenSplitContainerView::ClearPaneDevToolsOverlay(const ItemID& tab_id) {
  if (auto index = FindPaneIndex(tab_id)) {
    ClearPaneDevToolsOverlay(*index);
  }
}

views::View* OpenSplitContainerView::GetPaneDevToolsOverlay(
    size_t index) const {
  return index < panes_.size() && panes_[index]
             ? panes_[index]->devtools_overlay()
             : nullptr;
}

void OpenSplitContainerView::SetFocusedPane(const ItemID& tab_id) {
  presentation_.focused_pane_id = tab_id;
  if (!is_split()) {
    return;
  }
  for (auto& pane : panes_) {
    pane->SetFocused(pane->tab_id() == tab_id);
  }
}

void OpenSplitContainerView::SetPaneBackgroundColor(const ItemID& tab_id,
                                                    SkColor color) {
  if (auto* pane = FindPane(tab_id)) {
    pane->SetBackgroundOverride(color);
  }
}

void OpenSplitContainerView::SetPaneHostLabel(const ItemID& tab_id,
                                              const std::u16string& host) {
  if (auto* pane = FindPane(tab_id)) {
    pane->SetHostLabel(host);
  }
}

void OpenSplitContainerView::SetPaneSiteControlsAvailable(const ItemID& tab_id,
                                                          bool available) {
  if (auto* pane = FindPane(tab_id)) {
    pane->SetSiteControlsAvailable(available);
  }
}

views::WebView* OpenSplitContainerView::GetWebViewForTab(const ItemID& tab_id) {
  auto* pane = FindPane(tab_id);
  return pane ? pane->web_view() : nullptr;
}

OpenPaneChromeView* OpenSplitContainerView::GetPaneChromeForTab(
    const ItemID& tab_id) {
  auto* pane = FindPane(tab_id);
  return pane ? pane->chrome() : nullptr;
}

std::vector<gfx::Rect> OpenSplitContainerView::GetPaneBounds() const {
  std::vector<gfx::Rect> out;
  for (const auto& pane : panes_) {
    out.push_back(pane->bounds());
  }
  return out;
}

void OpenSplitContainerView::Layout(PassKey) {
  if (drop_overlay_) {
    drop_overlay_->SetBoundsRect(GetLocalBounds());
  }
  if (panes_.empty()) {
    UpdateDropOverlay();
    return;
  }
  if (!drag_current_frames_.empty()) {
    ApplyFrames(drag_current_frames_);
    UpdateDropOverlay();
    return;
  }
  const bool split = is_split();
  ApplyFrames(ComputePaneFrames(GetLocalBounds(), presentation_.orientation,
                                live_fractions_, panes_.size(),
                                split ? split_metrics::kGap : 0,
                                split_metrics::kMinimumPane));
  UpdateDropOverlay();
}

bool OpenSplitContainerView::GetDropFormats(
    int* formats,
    std::set<ui::ClipboardFormatType>* format_types) {
  *formats = ui::OSExchangeData::URL;
  format_types->insert(sidebar_dnd::NodeFormat());
  return true;
}

bool OpenSplitContainerView::CanDrop(const ui::OSExchangeData& data) {
  return data.HasCustomFormat(sidebar_dnd::NodeFormat()) ||
         data.HasURL(ui::FilenameToURLPolicy::CONVERT_FILENAMES);
}

void OpenSplitContainerView::OnDragEntered(const ui::DropTargetEvent& event) {
  dnd_tab_id_ = sidebar_dnd::ReadNode(event.data());
  dnd_url_ = GURL();
  if (!dnd_tab_id_) {
    const std::vector<ui::ClipboardUrlInfo> urls =
        event.data().GetURLs(ui::FilenameToURLPolicy::CONVERT_FILENAMES);
    if (!urls.empty()) {
      dnd_url_ = urls.front().url;
    }
  }
}

int OpenSplitContainerView::OnDragUpdated(const ui::DropTargetEvent& event) {
  if (!dnd_tab_id_ && !dnd_url_.is_valid()) {
    OnDragEntered(event);
  }
  const SplitDropZone zone =
      ComputeDropZoneAt(GetLocalBounds(), event.location());
  const std::optional<size_t> pane_idx =
      zone == SplitDropZone::kReplacePane ? PaneIndexAtPoint(event.location())
                                          : std::nullopt;
  if (delegate_ &&
      !delegate_->CanDropInSplit(dnd_tab_id_, dnd_url_, zone, pane_idx)) {
    SetDropZonePreview(std::nullopt);
    return ui::DragDropTypes::DRAG_NONE;
  }
  SetDropZonePreview(zone, pane_idx);
  return dnd_tab_id_ ? ui::DragDropTypes::DRAG_MOVE
                     : ui::DragDropTypes::DRAG_COPY |
                           ui::DragDropTypes::DRAG_LINK;
}

void OpenSplitContainerView::OnDragExited() {
  dnd_tab_id_.reset();
  dnd_url_ = GURL();
  SetDropZonePreview(std::nullopt);
}

views::View::DropCallback OpenSplitContainerView::GetDropCallback(
    const ui::DropTargetEvent& event) {
  const std::optional<SplitDropZone> zone = drop_zone_preview_;
  const std::optional<size_t> target_pane = drop_target_pane_index_;
  std::optional<ItemID> tab_id = dnd_tab_id_;
  GURL url = dnd_url_;
  OnDragExited();
  if (!zone || !delegate_) {
    return base::NullCallback();
  }
  return base::BindOnce(&OpenSplitContainerView::PerformDrop,
                        weak_factory_.GetWeakPtr(), std::move(tab_id),
                        std::move(url), *zone, target_pane);
}

void OpenSplitContainerView::PerformDrop(
    std::optional<ItemID> dragged_tab_id,
    GURL dragged_url,
    SplitDropZone zone,
    std::optional<size_t> target_pane_index,
    const ui::DropTargetEvent& event,
    ui::mojom::DragOperation& output_drag_op,
    std::unique_ptr<ui::LayerTreeOwner> drag_image_layer_owner) {
  const bool accepted =
      delegate_ && delegate_->OnDropInSplit(dragged_tab_id, dragged_url, zone,
                                            target_pane_index);
  if (!accepted) {
    output_drag_op = ui::mojom::DragOperation::kNone;
    return;
  }
  output_drag_op = dragged_tab_id ? ui::mojom::DragOperation::kMove
                                  : ui::mojom::DragOperation::kCopy;
}

void OpenSplitContainerView::UpdateDropOverlay() {
  if (!drop_overlay_) {
    return;
  }
  if (!drop_zone_preview_) {
    drop_overlay_->SetPreview(std::nullopt, gfx::Rect(),
                              presentation_.focus_ring_color);
    return;
  }
  const SkColor accent =
      drop_overlay_accent_.value_or(presentation_.focus_ring_color);
  const gfx::Rect preview =
      ComputeDropPreviewRect(GetLocalBounds(), GetPaneBounds(),
                             *drop_zone_preview_, drop_target_pane_index_);
  drop_overlay_->SetPreview(drop_zone_preview_, preview, accent);
  ReorderChildView(drop_overlay_, children().size() - 1);
}

void OpenSplitContainerView::ApplyFrames(const std::vector<gfx::Rect>& frames) {
  const size_t n = std::min(frames.size(), panes_.size());
  for (size_t i = 0; i < n; ++i) {
    panes_[i]->SetBoundsRect(frames[i]);
    if (i < pane_shadows_.size()) {
      pane_shadows_[i]->SetContentBounds(frames[i]);
    }
  }
  const bool horizontal =
      presentation_.orientation == SplitOrientation::kHorizontal;
  for (size_t i = 0; i < dividers_.size() && i + 1 < n; ++i) {
    const gfx::Rect& a = frames[i];
    const gfx::Rect& b = frames[i + 1];
    dividers_[i]->SetBoundsRect(
        horizontal
            ? gfx::Rect(a.right(), a.y(), b.x() - a.right(), a.height())
            : gfx::Rect(a.x(), a.bottom(), a.width(), b.y() - a.bottom()));
  }
}

void OpenSplitContainerView::SyncPaneShadows() {
  const size_t wanted = is_split() ? panes_.size() : 0;
  while (pane_shadows_.size() > wanted) {
    split_internal::SplitPaneShadowView* doomed = pane_shadows_.back().get();
    pane_shadows_.pop_back();
    RemoveChildViewT(doomed);
  }
  while (pane_shadows_.size() < wanted) {
    pane_shadows_.push_back(
        AddChildView(std::make_unique<split_internal::SplitPaneShadowView>()));
  }
}

void OpenSplitContainerView::SyncDividers() {
  const size_t wanted = is_split() ? panes_.size() - 1 : 0;
  while (dividers_.size() > wanted) {
    split_internal::SplitDividerView* doomed = dividers_.back().get();
    dividers_.pop_back();
    RemoveChildViewT(doomed);
  }
  while (dividers_.size() < wanted) {
    dividers_.push_back(
        AddChildView(std::make_unique<split_internal::SplitDividerView>(
            this, dividers_.size())));
  }
  const bool dark_content = EffectiveDarkContent();
  for (size_t i = 0; i < dividers_.size(); ++i) {
    dividers_[i]->set_pair_index(i);
    dividers_[i]->set_orientation(presentation_.orientation);
    dividers_[i]->set_dark_content(dark_content);
  }
}

void OpenSplitContainerView::ReorderSplitChildren() {
  size_t index = 0;
  for (auto& shadow : pane_shadows_) {
    ReorderChildView(shadow, index++);
  }
  for (auto& pane : panes_) {
    ReorderChildView(pane, index++);
  }
  for (auto& divider : dividers_) {
    ReorderChildView(divider, index++);
  }
  if (drop_overlay_) {
    ReorderChildView(drop_overlay_, children().size() - 1);
  }
}

split_internal::SplitPaneView* OpenSplitContainerView::FindPane(
    const ItemID& tab_id) {
  for (auto& pane : panes_) {
    if (pane && pane->tab_id() == tab_id) {
      return pane;
    }
  }
  return nullptr;
}

std::optional<size_t> OpenSplitContainerView::FindPaneIndex(
    const ItemID& tab_id) const {
  for (size_t i = 0; i < panes_.size(); ++i) {
    if (panes_[i] && panes_[i]->tab_id() == tab_id) {
      return i;
    }
  }
  return std::nullopt;
}

std::optional<size_t> OpenSplitContainerView::PaneIndexAtPoint(
    const gfx::Point& point) const {
  for (size_t i = 0; i < panes_.size(); ++i) {
    if (panes_[i] && panes_[i]->bounds().Contains(point)) {
      return i;
    }
  }
  return std::nullopt;
}

void OpenSplitContainerView::BeginDividerDrag(size_t pair_index) {
  drag_initial_frames_ = GetPaneBounds();
  drag_current_frames_ = drag_initial_frames_;
}

void OpenSplitContainerView::UpdateDividerDrag(size_t pair_index,
                                               int delta,
                                               bool equalize) {
  if (pair_index + 1 >= drag_initial_frames_.size()) {
    return;
  }
  const size_t i = pair_index;
  const size_t j = i + 1;
  const bool horizontal =
      presentation_.orientation == SplitOrientation::kHorizontal;
  const gfx::Rect& a = drag_initial_frames_[i];
  const gfx::Rect& b = drag_initial_frames_[j];
  const int first = horizontal ? a.width() : a.height();
  const int second = horizontal ? b.width() : b.height();
  const int total = first + second;
  const int minimum = std::min(split_metrics::kMinimumPane, total / 2);
  const int size = equalize ? total / 2
                            : std::clamp(first + delta, minimum,
                                         std::max(minimum, total - minimum));
  const int gap = horizontal ? b.x() - a.right() : b.y() - a.bottom();
  drag_current_frames_ = drag_initial_frames_;
  if (horizontal) {
    drag_current_frames_[i].set_width(size);
    drag_current_frames_[j].set_x(a.x() + size + gap);
    drag_current_frames_[j].set_width(total - size);
  } else {
    drag_current_frames_[i].set_height(size);
    drag_current_frames_[j].set_y(a.y() + size + gap);
    drag_current_frames_[j].set_height(total - size);
  }
  // Bounds only: each pane lays out its own bar and page; nothing forces a
  // layout pass through the web subtree (m4.md review fix 8).
  ApplyFrames(drag_current_frames_);

  double usable = 0;
  for (const gfx::Rect& r : drag_current_frames_) {
    usable += horizontal ? r.width() : r.height();
  }
  if (usable > 0) {
    live_fractions_.resize(drag_current_frames_.size());
    for (size_t k = 0; k < drag_current_frames_.size(); ++k) {
      live_fractions_[k] = (horizontal ? drag_current_frames_[k].width()
                                       : drag_current_frames_[k].height()) /
                           usable;
    }
  }
  if (delegate_ && presentation_.split_id) {
    delegate_->OnSplitFractionsLive(*presentation_.split_id, live_fractions_);
  }
}

void OpenSplitContainerView::EndDividerDrag(size_t pair_index, bool commit) {
  // A press without movement commits nothing: rebuilt fractions would differ
  // slightly from the stored ones and add an undo step that changes nothing.
  const bool changed = drag_current_frames_ != drag_initial_frames_;
  drag_initial_frames_.clear();
  drag_current_frames_.clear();
  if (!commit || !changed || !presentation_.split_id) {
    return;
  }
  presentation_.fractions = live_fractions_;
  if (delegate_) {
    delegate_->OnSplitFractionsCommitted(*presentation_.split_id,
                                         live_fractions_);
  }
}

void OpenSplitContainerView::OnPaneCommand(const ItemID& tab_id,
                                           PaneCommand command,
                                           views::View* anchor) {
  if (delegate_ && delegate_->OnPaneCommand(presentation_.split_id, tab_id,
                                            command, anchor)) {
    return;
  }
  // Default engine actions.
  split_internal::SplitPaneView* pane = FindPane(tab_id);
  content::WebContents* contents =
      pane && pane->web_view() ? pane->web_view()->web_contents() : nullptr;
  if (!contents) {
    return;
  }
  content::NavigationController& controller = contents->GetController();
  switch (command) {
    case PaneCommand::kBack:
      if (controller.CanGoBack()) {
        controller.GoBack();
      }
      break;
    case PaneCommand::kForward:
      if (controller.CanGoForward()) {
        controller.GoForward();
      }
      break;
    case PaneCommand::kReload:
      controller.Reload(content::ReloadType::NORMAL, /*check_for_repost=*/true);
      break;
    case PaneCommand::kStop:
      contents->Stop();
      break;
    default:
      break;
  }
}

void OpenSplitContainerView::OnPaneFocused(const ItemID& tab_id) {
  const bool changed = presentation_.focused_pane_id != tab_id;
  // Optimistic: the ring moves at once; the model confirms later.
  SetFocusedPane(tab_id);
  if (changed && delegate_) {
    delegate_->OnPaneFocusRequested(presentation_.split_id, tab_id);
  }
}

void OpenSplitContainerView::OnPaneHostClicked(const ItemID& tab_id,
                                               views::View* anchor) {
  if (!delegate_) {
    return;
  }
  const size_t pane_index = FindPaneIndex(tab_id).value_or(0);
  delegate_->OnPaneHostClicked(presentation_.split_id, tab_id, pane_index,
                               anchor);
}

void OpenSplitContainerView::OnEmptyPaneOpenCommandBar(const ItemID& tab_id) {
  OnPaneFocused(tab_id);
  if (delegate_) {
    delegate_->OnEmptyPaneOpenCommandBar(presentation_.split_id, tab_id);
  }
}

void OpenSplitContainerView::OnPaneChromeDragSwap(
    const ItemID& source_tab_id,
    const gfx::Point& point_in_container,
    bool finished) {
  const std::optional<size_t> source_idx = FindPaneIndex(source_tab_id);
  const std::optional<size_t> target_idx = PaneIndexAtPoint(point_in_container);
  if (!finished) {
    if (source_idx && target_idx && *source_idx != *target_idx) {
      SetDropZonePreview(SplitDropZone::kReplacePane, *target_idx);
    } else {
      SetDropZonePreview(std::nullopt);
    }
    return;
  }
  SetDropZonePreview(std::nullopt);
  if (source_idx && target_idx && *source_idx != *target_idx) {
    SwapPanes(*source_idx, *target_idx);
  }
}

BEGIN_METADATA(OpenSplitContainerView)
END_METADATA

}  // namespace open_unified
