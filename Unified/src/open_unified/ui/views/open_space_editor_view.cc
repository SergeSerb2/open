// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_space_editor_view.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <numbers>
#include <string>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "build/build_config.h"
#include "cc/paint/paint_canvas.h"
#include "cc/paint/paint_flags.h"
#include "cc/paint/paint_shader.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_typography.h"
#include "third_party/skia/include/core/SkClipOp.h"
#include "third_party/skia/include/core/SkMatrix.h"
#include "third_party/skia/include/core/SkPath.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/cursor/cursor.h"
#include "ui/base/cursor/mojom/cursor_type.mojom-shared.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/models/menu_separator_types.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/events/event.h"
#include "ui/events/event_constants.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/animation/tween.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/color_utils.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/shadow_value.h"
#include "ui/gfx/skia_paint_util.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/border.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/controls/focus_ring.h"
#include "ui/views/controls/highlight_path_generator.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"
#include "ui/views/controls/textfield/textfield.h"
#include "ui/views/widget/widget_delegate.h"

namespace open_unified {

namespace space_editor {

namespace {

namespace m = metrics;
using theme::P3;
using theme::Rgba;
namespace cm = theme::color_math;

constexpr double kPi = std::numbers::pi;

SkColor BlackA(float a) {
  return SkColorSetA(SK_ColorBLACK, static_cast<U8CPU>(std::lround(
                                        std::clamp(a, 0.0f, 1.0f) * 255)));
}
SkColor WhiteA(float a) {
  return SkColorSetA(SK_ColorWHITE, static_cast<U8CPU>(std::lround(
                                        std::clamp(a, 0.0f, 1.0f) * 255)));
}
SkColor WithAlpha(SkColor c, float a) {
  return SkColorSetA(
      c, static_cast<U8CPU>(std::lround(SkColorGetA(c) * std::clamp(a, 0.0f, 1.0f))));
}
SkColor Pick(bool dark, SkColor light_color, SkColor dark_color) {
  return dark ? dark_color : light_color;
}

double Clamp01(double v) {
  return std::isfinite(v) ? std::clamp(v, 0.0, 1.0) : 0.0;
}
double Fract(double v) {
  return v - std::floor(v);
}

P3 KeyP3(const SpaceStyle& style) {
  return cm::ToP3(theme::FromModel(style.key_color));
}
RGBAColor ModelFromP3(const P3& c) {
  RGBAColor out = theme::ToModel(cm::ToExtendedSRGB(c));
  out.a = 1;
  return out;
}
SkColor SkFromP3(const P3& c) {
  return theme::ToSkColor(cm::ToExtendedSRGB(c));
}

// ThemeColorMath editor ranges.
struct Range {
  double lo = 0.01;
  double hi = 0.97;
};
Range AutoRange(double l) {
  return {std::max(0.01, l - 0.25), std::min(0.97, l + 0.25)};
}
Range ForcedRange(ThemeAppearance mode) {
  switch (mode) {
    case ThemeAppearance::kLight:
      return {0.575, 0.97};
    case ThemeAppearance::kDark:
      return {0.01, 0.425};
    case ThemeAppearance::kAutomatic:
      break;
  }
  return {0.01, 0.97};
}
Range EditorRange(const std::optional<P3>& key, ThemeAppearance mode) {
  if (!key) {
    return {};
  }
  const double l = cm::ToHsl(*key).l;
  if (mode == ThemeAppearance::kAutomatic) {
    return AutoRange(l);
  }
  const Range forced = ForcedRange(mode);
  return {std::min(forced.lo, l), std::max(forced.hi, l)};
}
gfx::PointF KnobFor(const P3& color, const Range& range) {
  const theme::Hsl v = cm::ToHsl(color);
  const double span = std::max(1e-9, range.hi - range.lo);
  const double r = 0.99 * Clamp01((v.l - range.lo) / span);
  return gfx::PointF(static_cast<float>(std::cos(2 * kPi * v.h) * r),
                     static_cast<float>(std::sin(2 * kPi * v.h) * r));
}
P3 ColorAt(const gfx::PointF& knob, double saturation, const Range& range) {
  const double h = Fract(std::atan2(knob.y(), knob.x()) / (2 * kPi));
  const double t = std::min(std::hypot(knob.x(), knob.y()) / 0.99, 1.0);
  return cm::FromHsl(h, saturation, range.lo + t * (range.hi - range.lo));
}

const gfx::FontList& Font(int size, gfx::Font::Weight weight) {
  return typography::Make(size, weight);
}

constexpr int kTextFlags = gfx::Canvas::NO_SUBPIXEL_RENDERING;

void DrawText(gfx::Canvas* canvas,
              std::u16string_view text,
              const gfx::FontList& font,
              SkColor color,
              const gfx::Rect& rect,
              int align = gfx::Canvas::TEXT_ALIGN_LEFT) {
  canvas->DrawStringRectWithFlags(text, font, color, rect, align | kTextFlags);
}

void FillRRect(gfx::Canvas* canvas,
               const gfx::RectF& rect,
               float radius,
               SkColor color) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(color);
  canvas->DrawRoundRect(rect, radius, flags);
}

void StrokeRRect(gfx::Canvas* canvas,
                 const gfx::RectF& rect,
                 float radius,
                 SkColor color,
                 float width) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kStroke_Style);
  flags.setStrokeWidth(width);
  flags.setColor(color);
  canvas->DrawRoundRect(rect, radius, flags);
}

void FillCircle(gfx::Canvas* canvas,
                const gfx::PointF& c,
                float r,
                SkColor color) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(color);
  canvas->DrawCircle(c, r, flags);
}

// Knob / thumb drop shadow: Swift shadowOpacity 0.06, radius 2, offset 2
// (black in light content, white in dark content).
cc::PaintFlags ShadowedFill(SkColor fill, SkColor shadow) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(fill);
  if (SkColorGetA(shadow) != 0) {
    const gfx::ShadowValues shadows{
        gfx::ShadowValue(gfx::Vector2d(0, 2), 4, shadow)};
    flags.setLooper(gfx::CreateShadowDrawLooper(shadows));
  }
  return flags;
}

void UpdateBubbleBackground(views::View* view, SkColor color) {
  views::Widget* widget = view->GetWidget();
  if (!widget || !widget->widget_delegate()) {
    return;
  }
  if (auto* bubble = widget->widget_delegate()->AsBubbleDialogDelegate()) {
    bubble->SetBackgroundColor(color);
  }
}

// --- Skia fallback glyphs (Windows, Linux) ---------------------------------
// Open's own line art; no copied icon assets.

cc::PaintFlags StrokeFlags(SkColor color, float width) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kStroke_Style);
  flags.setStrokeWidth(width);
  flags.setStrokeCap(cc::PaintFlags::kRound_Cap);
  flags.setStrokeJoin(cc::PaintFlags::kRound_Join);
  flags.setColor(color);
  return flags;
}

cc::PaintFlags FillFlags(SkColor color) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(color);
  return flags;
}

class HandEditorButton : public EditorButton {
 public:
  using EditorButton::EditorButton;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return GetEnabled() ? ui::Cursor(ui::mojom::CursorType::kHand)
                        : EditorButton::GetCursor(event);
  }
};

class HandPresetStripView : public PresetStripView {
 public:
  using PresetStripView::PresetStripView;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return ui::Cursor(ui::mojom::CursorType::kHand);
  }
};

class HandSineSliderView : public SineSliderView {
 public:
  using SineSliderView::SineSliderView;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return GetEnabled() ? ui::Cursor(ui::mojom::CursorType::kHand)
                        : SineSliderView::GetCursor(event);
  }
};

class HandNoiseDialView : public NoiseDialView {
 public:
  using NoiseDialView::NoiseDialView;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return GetEnabled() ? ui::Cursor(ui::mojom::CursorType::kHand)
                        : NoiseDialView::GetCursor(event);
  }
};

// A four-point sparkle with concave sides.
SkPath Sparkle(float cx, float cy, float r) {
  SkPathBuilder b;
  const float k = r * 0.18f;
  b.moveTo(cx, cy - r);
  b.quadTo(cx + k, cy - k, cx + r, cy);
  b.quadTo(cx + k, cy + k, cx, cy + r);
  b.quadTo(cx - k, cy + k, cx - r, cy);
  b.quadTo(cx - k, cy - k, cx, cy - r);
  b.close();
  return b.detach();
}

void DrawFallbackGlyph(gfx::Canvas* canvas,
                       EditorGlyph glyph,
                       const gfx::RectF& box,
                       SkColor color,
                       float s) {
  const float cx = box.CenterPoint().x();
  const float cy = box.CenterPoint().y();
  const float w = std::max(1.2f, s * 0.12f);
  cc::PaintCanvas* sk = canvas->sk_canvas();
  switch (glyph) {
    case EditorGlyph::kPlus: {
      const float h = s * 0.36f;
      sk->drawLine(cx - h, cy, cx + h, cy, StrokeFlags(color, w));
      sk->drawLine(cx, cy - h, cx, cy + h, StrokeFlags(color, w));
      return;
    }
    case EditorGlyph::kMinus: {
      const float h = s * 0.36f;
      sk->drawLine(cx - h, cy, cx + h, cy, StrokeFlags(color, w));
      return;
    }
    case EditorGlyph::kChevronLeft:
    case EditorGlyph::kChevronRight:
    case EditorGlyph::kChevronDown: {
      SkPathBuilder b;
      const float a = s * 0.20f;
      const float h = s * 0.38f;
      if (glyph == EditorGlyph::kChevronLeft) {
        b.moveTo(cx + a, cy - h).lineTo(cx - a, cy).lineTo(cx + a, cy + h);
      } else if (glyph == EditorGlyph::kChevronRight) {
        b.moveTo(cx - a, cy - h).lineTo(cx + a, cy).lineTo(cx - a, cy + h);
      } else {
        b.moveTo(cx - h, cy - a).lineTo(cx, cy + a).lineTo(cx + h, cy - a);
      }
      canvas->DrawPath(b.detach(), StrokeFlags(color, w));
      return;
    }
    case EditorGlyph::kSparkles:
      canvas->DrawPath(Sparkle(cx - s * 0.08f, cy + s * 0.06f, s * 0.38f),
                       FillFlags(color));
      canvas->DrawPath(Sparkle(cx + s * 0.30f, cy - s * 0.30f, s * 0.16f),
                       FillFlags(color));
      return;
    case EditorGlyph::kSun: {
      FillCircle(canvas, gfx::PointF(cx, cy), s * 0.21f, color);
      for (int i = 0; i < 8; ++i) {
        const double a = i * kPi / 4;
        const float c = static_cast<float>(std::cos(a));
        const float d = static_cast<float>(std::sin(a));
        sk->drawLine(cx + c * s * 0.32f, cy + d * s * 0.32f,
                     cx + c * s * 0.46f, cy + d * s * 0.46f,
                     StrokeFlags(color, std::max(1.2f, s * 0.09f)));
      }
      return;
    }
    case EditorGlyph::kMoon: {
      sk->save();
      sk->clipPath(SkPath::Circle(cx + s * 0.20f, cy - s * 0.16f, s * 0.32f),
                   SkClipOp::kDifference, true);
      FillCircle(canvas, gfx::PointF(cx - s * 0.02f, cy + s * 0.02f),
                 s * 0.40f, color);
      sk->restore();
      // The small star of moon.stars.
      canvas->DrawPath(Sparkle(cx + s * 0.32f, cy - s * 0.30f, s * 0.11f),
                       FillFlags(color));
      return;
    }
    case EditorGlyph::kUndo: {
      SkPathBuilder b;
      const float r = s * 0.30f;
      b.arcTo(SkRect::MakeLTRB(cx - r, cy - r + s * 0.08f, cx + r,
                               cy + r + s * 0.08f),
              200, 250, true);
      canvas->DrawPath(b.detach(), StrokeFlags(color, w));
      SkPathBuilder head;
      const float hx = cx - r * 0.94f;
      const float hy = cy - r * 0.34f + s * 0.08f;
      head.moveTo(hx - s * 0.02f, hy - s * 0.22f)
          .lineTo(hx, hy)
          .lineTo(hx + s * 0.22f, hy - s * 0.02f);
      canvas->DrawPath(head.detach(), StrokeFlags(color, w));
      return;
    }
    case EditorGlyph::kSmiley: {
      // Open's own placeholder art (SpaceCreationView.creationSmiley).
      const float x0 = cx - s / 2;
      const float y0 = cy - s / 2;
      cc::PaintFlags face = StrokeFlags(color, s * 0.065f);
      canvas->DrawCircle(gfx::PointF(cx, cy), s * 0.42f, face);
      FillCircle(canvas, gfx::PointF(x0 + s * 0.34f, y0 + s * 0.365f),
                 s * 0.045f, color);
      FillCircle(canvas, gfx::PointF(x0 + s * 0.66f, y0 + s * 0.365f),
                 s * 0.045f, color);
      SkPathBuilder smile;
      smile.moveTo(x0 + s * 0.30f, y0 + s * 0.59f)
          .cubicTo(x0 + s * 0.40f, y0 + s * 0.75f, x0 + s * 0.60f,
                   y0 + s * 0.75f, x0 + s * 0.70f, y0 + s * 0.59f);
      canvas->DrawPath(smile.detach(), StrokeFlags(color, s * 0.06f));
      return;
    }
    case EditorGlyph::kClose: {
      const float h = s * 0.30f;
      sk->drawLine(cx - h, cy - h, cx + h, cy + h, StrokeFlags(color, w));
      sk->drawLine(cx - h, cy + h, cx + h, cy - h, StrokeFlags(color, w));
      return;
    }
    case EditorGlyph::kMagnifier: {
      const float r = s * 0.28f;
      canvas->DrawCircle(gfx::PointF(cx - s * 0.06f, cy - s * 0.06f), r,
                         StrokeFlags(color, w));
      sk->drawLine(cx + r * 0.62f, cy + r * 0.62f, cx + s * 0.40f,
                   cy + s * 0.40f, StrokeFlags(color, w * 1.2f));
      return;
    }
  }
}

struct SymbolChoice {
  const char* name;
  glyphs::SymbolWeight weight;
};
SymbolChoice SymbolFor(EditorGlyph glyph) {
  using W = glyphs::SymbolWeight;
  switch (glyph) {
    case EditorGlyph::kPlus:
      return {"plus", W::kSemibold};
    case EditorGlyph::kMinus:
      return {"minus", W::kSemibold};
    case EditorGlyph::kChevronLeft:
      return {"chevron.left", W::kSemibold};
    case EditorGlyph::kChevronRight:
      return {"chevron.right", W::kSemibold};
    case EditorGlyph::kChevronDown:
      return {"chevron.down", W::kSemibold};
    case EditorGlyph::kSparkles:
      return {"sparkles", W::kMedium};
    case EditorGlyph::kSun:
      return {"sun.max.fill", W::kMedium};
    case EditorGlyph::kMoon:
      return {"moon.stars.fill", W::kMedium};
    case EditorGlyph::kUndo:
      return {"arrow.uturn.backward", W::kMedium};
    case EditorGlyph::kSmiley:
      return {"face.smiling", W::kRegular};
    case EditorGlyph::kClose:
      return {"xmark", W::kSemibold};
    case EditorGlyph::kMagnifier:
      return {"magnifyingglass", W::kMedium};
  }
  return {"circle.dotted", W::kRegular};
}

}  // namespace

// --- Shared drawing ---------------------------------------------------------

void DrawEditorGlyph(gfx::Canvas* canvas,
                     EditorGlyph glyph,
                     const gfx::RectF& box,
                     SkColor color,
                     float point_size) {
  const SymbolChoice symbol = SymbolFor(glyph);
  if (glyphs::DrawSystemSymbol(canvas, symbol.name, point_size, symbol.weight,
                               box, color)) {
    return;
  }
  DrawFallbackGlyph(canvas, glyph, box, color, point_size);
}

namespace {

// A Space icon in `box`: emoji text, SF Symbol (macOS) / Open's Skia art.
// No icon: the smiley placeholder (`placeholder`) or Open's planet mark.
void PaintSpaceIcon(gfx::Canvas* canvas,
                    const std::optional<SpaceIcon>& icon,
                    const gfx::RectF& box,
                    float symbol_size,
                    int emoji_size,
                    SkColor tint,
                    bool placeholder) {
  if (icon && icon->kind == SpaceIconKind::kEmoji && !icon->value.empty()) {
    gfx::RectF r = box;
    r.Offset(0, -1);  // emoji sit 1 pt above center (NCC fits, F0001)
    canvas->DrawStringRectWithFlags(
        base::UTF8ToUTF16(icon->value), Font(emoji_size, gfx::Font::Weight::NORMAL),
        tint, gfx::ToEnclosingRect(r),
        gfx::Canvas::TEXT_ALIGN_CENTER | gfx::Canvas::NO_ELLIPSIS | kTextFlags);
    return;
  }
  if (icon && !icon->value.empty()) {
    const std::string_view symbol =
        icon->kind == SpaceIconKind::kSymbol
            ? std::string_view(icon->value)
            : glyphs::NamedSpaceIconSymbol(icon->value);
    if (glyphs::DrawSystemSymbol(canvas, symbol, symbol_size,
                                 glyphs::SymbolWeight::kMedium, box, tint)) {
      return;
    }
    if (glyphs::DrawNamedSpaceIcon(canvas, icon->value, box, tint)) {
      return;
    }
    const SpaceIcon value = *icon;
    glyphs::DrawSpaceIcon(canvas, &value, u"", box,
                          Font(emoji_size, gfx::Font::Weight::NORMAL), tint, 1);
    return;
  }
  if (placeholder) {
    DrawEditorGlyph(canvas, EditorGlyph::kSmiley, box, tint, symbol_size);
    return;
  }
  glyphs::DrawSpaceIcon(canvas, nullptr, u"", box,
                        Font(emoji_size, gfx::Font::Weight::NORMAL), tint, 1);
}

}  // namespace

// --- Colors -----------------------------------------------------------------

EditorColors EditorColors::For(bool dark, std::optional<SkColor> panel) {
  EditorColors c;
  c.dark = dark;
  // Solid popover body (Open choice; Swift: PopoverMaterial).
  c.panel = panel.value_or(Pick(dark, SkColorSetRGB(0xF4, 0xF4, 0xF5),
                                SkColorSetRGB(0x2B, 0x2B, 0x2E)));
  c.pad_fill = Pick(dark, BlackA(0.055f), WhiteA(0.04f));
  c.dot = Pick(dark, BlackA(0.14f), WhiteA(0.20f));
  c.glyph = Pick(dark, BlackA(0.50f), WhiteA(0.50f));
  c.glyph_selected = c.glyph;
  c.selected_plate = Pick(dark, BlackA(0.10f), WhiteA(0.10f));
  c.hover_plate = Pick(dark, BlackA(0.11f), WhiteA(0.11f));
  c.secondary_text = Pick(dark, BlackA(0.74f), WhiteA(0.90f));
  c.primary_text = Pick(dark, BlackA(0.86f), WhiteA(0.92f));
  c.track_fill = Pick(dark, BlackA(0.085f), WhiteA(0.08f));
  c.wave_active = Pick(dark, BlackA(0.40f), WhiteA(0.53f));
  c.wave_inactive = Pick(dark, BlackA(0.15f), WhiteA(0.15f));
  c.thumb = SK_ColorWHITE;
  c.dot_unlit = Pick(dark, BlackA(0.15f), WhiteA(0.15f));
  c.dot_lit = Pick(dark, BlackA(0.40f), WhiteA(0.50f));
  c.card_fill = Pick(dark, BlackA(0.045f), WhiteA(0.06f));
  c.separator = Pick(dark, BlackA(0.08f), WhiteA(0.08f));
  c.focus_ring = SkColorSetARGB(0xB3, 0x2D, 0x7B, 0xF6);
  c.shadow = Pick(dark, BlackA(0.06f), WhiteA(0.06f));
  return c;
}

// --- Presets ----------------------------------------------------------------

namespace {

RGBAColor SrgbHex(uint32_t hex) {
  return theme::ToModel(Rgba::Hex(hex));
}
RGBAColor P3Hex(uint32_t hex) {
  const Rgba c = Rgba::Hex(hex);
  return ModelFromP3(P3{c.r, c.g, c.b});
}

// Session 2 item 17 frame 0016: measured sRGB stops of the 3-color page
// (facts); drawn as our own axial gradient.
constexpr std::array<std::array<uint32_t, 3>, 9> kGradientStops = {{
    {0xD3D2CA, 0xD2D4CA, 0xD4CFCC}, {0xD3939C, 0xD39D8E, 0xD293B1},
    {0x936882, 0x956874, 0x876984}, {0xD37B5E, 0xCF9B57, 0xD37C8C},
    {0xDCA24E, 0xD3CC45, 0xE19274}, {0xBCCA53, 0x95D652, 0xCAA25B},
    {0x35CCAA, 0x3FCACB, 0x5BCC98}, {0x6D8EC3, 0x7375C3, 0x699DB6},
    {0x685E7D, 0x735D7C, 0x67687C},
}};

void PaintPresetSwatch(gfx::Canvas* canvas,
                       size_t index,
                       const gfx::RectF& rect) {
  const auto& presets = ThemePresets();
  if (index >= presets.size()) {
    return;
  }
  const float r = rect.width() / 2;
  if (index / kSwatchesPerPage == 1) {
    const auto& stops = kGradientStops[index % kSwatchesPerPage];
    std::array<SkColor4f, 3> colors;
    for (size_t i = 0; i < colors.size(); ++i) {
      colors[i] = SkColor4f::FromColor(theme::ToSkColor(Rgba::Hex(stops[i])));
    }
    const SkScalar pos[3] = {0, 0.5f, 1};
    const SkPoint points[2] = {
        SkPoint::Make(rect.x() + rect.width() * 0.235f,
                      rect.y() + rect.height() * 0.235f),
        SkPoint::Make(rect.x() + rect.width() * 0.765f,
                      rect.y() + rect.height() * 0.765f)};
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setShader(cc::PaintShader::MakeLinearGradient(
        points, colors.data(), pos, 3, SkTileMode::kClamp));
    canvas->DrawCircle(rect.CenterPoint(), r, flags);
  } else {
    const SpaceStyle& style = presets[index].style;
    const auto colors =
        cm::Harmony(KeyP3(style), style.color_count, style.wheel);
    FillCircle(canvas, rect.CenterPoint(), r,
               colors.empty() ? SK_ColorGRAY : SkFromP3(colors[0]));
  }
  // 2 pt authored rim, black 0.10.
  canvas->DrawCircle(rect.CenterPoint(), r - 1, StrokeFlags(BlackA(0.10f), 2));
}

}  // namespace

const std::vector<ThemePreset>& ThemePresets() {
  static const base::NoDestructor<std::vector<ThemePreset>> presets([] {
    const std::array<RGBAColor, 9> brand = {
        SrgbHex(0xF2EAE4), SrgbHex(0xF29BBB), SrgbHex(0xA6729D),
        SrgbHex(0xF25E6B), SrgbHex(0xFF8558), P3Hex(0xF2D66D),
        P3Hex(0x73E59C),   P3Hex(0x7EB8D6),   P3Hex(0x666786)};
    auto p3 = [](std::array<uint32_t, 9> hex) {
      std::array<RGBAColor, 9> out;
      for (size_t i = 0; i < 9; ++i) {
        out[i] = P3Hex(hex[i]);
      }
      return out;
    };
    const auto pastel = p3({0xFDFBFA, 0xFBEAF3, 0xECD2EA, 0xF7CDD2, 0xFAE1D5,
                            0xFEF9E7, 0xE4FCEC, 0xE0F2FB, 0xC5C6E2});
    const auto drab = p3({0x4B3B58, 0x623856, 0x854444, 0xA77048, 0xD1B46A,
                          0xCDCCA8, 0x84A885, 0x34604B, 0x2D4468});
    const auto gray = p3({0xFFFFFF, 0xE5E5E5, 0xCCCCCC, 0xB2B2B2, 0x808080,
                          0x666666, 0x333333, 0x1A1A1A, 0x000000});
    const std::array<const std::array<RGBAColor, 9>*, 5> pages = {
        &brand, &brand, &pastel, &drab, &gray};
    const std::array<const char*, 5> sets = {"Brand", "Brand", "Pastel",
                                             "Drab", "Greyscale"};
    std::vector<ThemePreset> out;
    for (size_t page = 0; page < pages.size(); ++page) {
      for (size_t i = 0; i < 9; ++i) {
        ThemePreset preset;
        preset.name = base::UTF8ToUTF16(std::string(sets[page]) + " " +
                                        std::to_string(i + 1) +
                                        (page == 1 ? " gradient" : ""));
        preset.style = NewStyle((*pages[page])[i], ThemeAppearance::kAutomatic);
        preset.style.color_count = page == 1 ? 3 : 1;
        out.push_back(std::move(preset));
      }
    }
    return out;
  }());
  return *presets;
}

SpaceStyle NewStyle(const RGBAColor& key, ThemeAppearance appearance) {
  SpaceStyle style;
  style.key_color = key;
  style.key_color.a = 1;
  style.color_count = 1;
  style.wheel = ThemeWheel::kAnalogous;
  style.appearance = appearance;
  style.noise_factor = 0;
  style.texture = ThemeTexture::kGrain;
  style.intensity_factor = 0.8;
  return style;
}

std::optional<SpaceStyle> SeedStyle(const SpaceTheme& theme) {
  if (theme.style) {
    return theme.style;
  }
  if (!theme.gradient_stops_light.empty()) {
    auto first = std::min_element(
        theme.gradient_stops_light.begin(), theme.gradient_stops_light.end(),
        [](const GradientStop& a, const GradientStop& b) {
          return a.location < b.location;
        });
    return NewStyle(first->color, ThemeAppearance::kAutomatic);
  }
  // Imported Arc JSON without an editor style (or the default theme): the
  // editor opens empty and writes a style on the first edit.
  return std::nullopt;
}

SpaceTheme ThemeFromStyle(const std::optional<SpaceStyle>& style) {
  SpaceTheme theme;
  theme.style = style;
  return theme;
}

// --- ThemeEditorState -------------------------------------------------------

ThemeEditorState::ThemeEditorState(std::optional<SpaceStyle> style)
    : style_(std::move(style)) {
  std::optional<P3> key;
  if (style_) {
    key = KeyP3(*style_);
  }
  const Range range = EditorRange(
      key, style_ ? style_->appearance : ThemeAppearance::kAutomatic);
  range_lo_ = range.lo;
  range_hi_ = range.hi;
  saturation_ = key ? std::max(0.01, cm::ToHsl(*key).s) : 1;
}
ThemeEditorState::ThemeEditorState(const ThemeEditorState&) = default;
ThemeEditorState& ThemeEditorState::operator=(const ThemeEditorState&) =
    default;
ThemeEditorState::~ThemeEditorState() = default;

ThemeAppearance ThemeEditorState::appearance() const {
  return style_ ? style_->appearance : empty_appearance_;
}

void ThemeEditorState::set_preset_page(int page) {
  preset_page_ = std::clamp(page, 0, kPresetPageCount - 1);
}

std::vector<ThemeEditorState::Knob> ThemeEditorState::Knobs() const {
  std::vector<Knob> out;
  if (!style_) {
    return out;
  }
  const Range range{range_lo_, range_hi_};
  for (const P3& color :
       cm::Harmony(KeyP3(*style_), style_->color_count, style_->wheel)) {
    out.push_back({KnobFor(color, range), color});
    if (out.size() == 3) {
      break;
    }
  }
  return out;
}

std::optional<gfx::PointF> ThemeEditorState::KeyKnob() const {
  if (!style_) {
    return std::nullopt;
  }
  return KnobFor(KeyP3(*style_), Range{range_lo_, range_hi_});
}

bool ThemeEditorState::SetColorAt(const gfx::PointF& point) {
  const RGBAColor color =
      ModelFromP3(ColorAt(point, saturation_, Range{range_lo_, range_hi_}));
  const std::optional<SpaceStyle> before = style_;
  if (!style_) {
    style_ = NewStyle(color, empty_appearance_);
  } else {
    style_->key_color = color;
  }
  return before != style_;
}

bool ThemeEditorState::DragKnob(const gfx::PointF& point, bool relative) {
  if (!gesture_) {
    gesture_ = true;
    start_knob_ = KeyKnob();
    start_pointer_ = point;
    if (relative && style_) {
      return false;
    }
  }
  gfx::PointF target = point;
  if (relative && start_knob_ && start_pointer_) {
    if (point == *start_pointer_) {
      return false;
    }
    target = gfx::PointF(start_knob_->x() + point.x() - start_pointer_->x(),
                         start_knob_->y() + point.y() - start_pointer_->y());
  }
  return SetColorAt(target);
}

void ThemeEditorState::BeginKeyboardGesture() {
  gesture_ = true;
}

void ThemeEditorState::EndGesture() {
  gesture_ = false;
  start_knob_.reset();
  start_pointer_.reset();
}

bool ThemeEditorState::AddColor() {
  if (!style_ || style_->color_count >= 3) {
    return false;
  }
  if (style_->color_count == 1) {
    style_->wheel = ThemeWheel::kComplementary;
  }
  style_->color_count += 1;
  return true;
}

bool ThemeEditorState::RemoveColor() {
  if (!style_) {
    return false;
  }
  if (style_->color_count <= 1) {
    style_.reset();
    empty_appearance_ = ThemeAppearance::kAutomatic;
    range_lo_ = 0.01;
    range_hi_ = 0.97;
    saturation_ = 1;
  } else {
    style_->color_count -= 1;
  }
  return true;
}

bool ThemeEditorState::SetAppearance(ThemeAppearance mode) {
  if (mode == appearance()) {
    return false;
  }
  // Arc 1.172.2: the mode picks the window scheme only; the knob keeps the
  // key color (D2-report-t0).
  if (style_) {
    style_->appearance = mode;
    return true;
  }
  empty_appearance_ = mode;
  return false;
}

bool ThemeEditorState::SelectPreset(size_t index) {
  const auto& presets = ThemePresets();
  if (index >= presets.size()) {
    return false;
  }
  const SpaceStyle& preset = presets[index].style;
  const std::optional<SpaceStyle> before = style_;
  SpaceStyle result = style_ ? *style_ : NewStyle(preset.key_color, appearance());
  result.key_color = preset.key_color;
  result.color_count = preset.color_count;
  result.wheel = preset.wheel;
  const P3 key = KeyP3(preset);
  const theme::Hsl hsl = cm::ToHsl(key);
  if (appearance() == ThemeAppearance::kAutomatic) {
    const Range range = AutoRange(hsl.l);
    range_lo_ = range.lo;
    range_hi_ = range.hi;
  }
  saturation_ = std::max(0.01, hsl.s);
  style_ = result;
  return before != style_;
}

bool ThemeEditorState::SetIntensity(double value, bool final) {
  gesture_ = !final;
  if (!style_) {
    return false;
  }
  const double v = Clamp01(value);
  if (v == style_->intensity_factor) {
    return false;
  }
  style_->intensity_factor = v;
  return true;
}

bool ThemeEditorState::SetNoise(double value, bool final) {
  gesture_ = !final;
  if (!style_) {
    return false;
  }
  double v = Clamp01(value);
  if (std::abs(v) <= kNoiseInputEpsilon) {
    v = 0;
  }
  if (v == style_->noise_factor) {
    return false;
  }
  style_->noise_factor = v;
  return true;
}

bool ThemeEditorState::CycleTexture() {
  if (!style_) {
    return false;
  }
  SpaceStyle& s = *style_;
  if (s.noise_factor <= kNoiseInputEpsilon) {
    s.texture = ThemeTexture::kGrain;
    s.noise_factor = 0.8;
  } else if (s.texture == ThemeTexture::kTweed) {
    s.noise_factor = 0;
  } else {
    s.texture = static_cast<ThemeTexture>(static_cast<int>(s.texture) + 1);
    s.noise_factor = 0.8;
  }
  return true;
}

bool ThemeEditorState::KeyboardHue(double degrees) {
  if (!style_) {
    return false;
  }
  const theme::Hsl hsl = cm::ToHsl(KeyP3(*style_));
  const RGBAColor before = style_->key_color;
  style_->key_color =
      ModelFromP3(cm::FromHsl(hsl.h + degrees / 360, saturation_, hsl.l));
  return !(before == style_->key_color);
}

bool ThemeEditorState::KeyboardRadius(double delta) {
  const std::optional<gfx::PointF> position = KeyKnob();
  if (!position) {
    return false;
  }
  const double r = std::hypot(position->x(), position->y());
  const double target = std::clamp(r + delta, 0.0, 0.99);
  const double h = r > 0 ? std::atan2(position->y(), position->x()) : 0;
  return SetColorAt(gfx::PointF(static_cast<float>(std::cos(h) * target),
                                static_cast<float>(std::sin(h) * target)));
}

// --- EditorButton -----------------------------------------------------------

EditorButton::EditorButton(PressedCallback callback,
                           EditorGlyph glyph,
                           float point_size,
                           const std::u16string& accessible_name)
    : views::Button(std::move(callback)),
      glyph_(glyph),
      point_size_(point_size) {
  GetViewAccessibility().SetName(accessible_name);
  SetTooltipText(accessible_name);
  views::InstallRoundRectHighlightPathGenerator(this, gfx::Insets(), 8);
}

EditorButton::EditorButton(PressedCallback callback,
                           const std::u16string& label)
    : views::Button(std::move(callback)), label_(label) {
  GetViewAccessibility().SetName(label);
  views::InstallRoundRectHighlightPathGenerator(this, gfx::Insets(), 8);
}

EditorButton::~EditorButton() = default;

void EditorButton::SetColors(const EditorColors& colors) {
  colors_ = colors;
  SchedulePaint();
}

void EditorButton::SetSelected(bool selected) {
  if (selected_ == selected) {
    return;
  }
  selected_ = selected;
  GetViewAccessibility().SetCheckedState(
      selected ? ax::mojom::CheckedState::kTrue
               : ax::mojom::CheckedState::kFalse);
  SchedulePaint();
}

void EditorButton::SetGlyph(EditorGlyph glyph) {
  glyph_ = glyph;
  SchedulePaint();
}

void EditorButton::SetFilled(SkColor fill, SkColor text) {
  filled_ = fill;
  text_ = text;
  SchedulePaint();
}

void EditorButton::SetTextColor(SkColor text) {
  text_ = text;
  SchedulePaint();
}

void EditorButton::SetLabel(const std::u16string& label) {
  label_ = label;
  GetViewAccessibility().SetName(label);
  SchedulePaint();
}

void EditorButton::SetFontSize(int size, bool semibold) {
  font_size_ = size;
  semibold_ = semibold;
  SchedulePaint();
}

void EditorButton::SetTrailingChevron(bool chevron) {
  chevron_ = chevron;
  SchedulePaint();
}

void EditorButton::PaintButtonContents(gfx::Canvas* canvas) {
  const gfx::RectF bounds(GetLocalBounds());
  const bool enabled = GetEnabled();
  const bool hovering = enabled && (GetState() == STATE_HOVERED ||
                                    GetState() == STATE_PRESSED);
  if (filled_) {
    SkColor fill = *filled_;
    if (GetState() == STATE_PRESSED) {
      fill = color_utils::AlphaBlend(SK_ColorBLACK, fill, 0.08f);
    }
    FillRRect(canvas, bounds, 8, enabled ? fill : WithAlpha(fill, 0.45f));
  } else if (selected_ || hovering) {
    SkColor plate = selected_ ? colors_.selected_plate : colors_.hover_plate;
    if (selected_ && hovering) {
      // Selected + hover: 1 - (1 - a)(1 - hover a).
      const float a = SkColorGetA(colors_.selected_plate) / 255.0f;
      const float h = SkColorGetA(colors_.hover_plate) / 255.0f;
      plate = SkColorSetA(plate, static_cast<U8CPU>(
                                     std::lround((1 - (1 - a) * (1 - h)) * 255)));
    }
    FillRRect(canvas, bounds, 8, plate);
  }
  const float alpha = enabled ? 1.0f : (filled_ ? 0.45f : kDisabledGlyphAlpha);
  if (glyph_) {
    const SkColor color = WithAlpha(
        text_.value_or(selected_ ? colors_.glyph_selected : colors_.glyph),
        alpha);
    gfx::RectF box = bounds;
    box.Offset(0, glyph_offset_);
    DrawEditorGlyph(canvas, *glyph_, box, color, point_size_);
    return;
  }
  if (label_.empty()) {
    return;
  }
  const SkColor color = WithAlpha(text_.value_or(colors_.primary_text), alpha);
  const gfx::FontList& font = Font(
      font_size_, semibold_ ? gfx::Font::Weight::SEMIBOLD
                            : gfx::Font::Weight::MEDIUM);
  if (chevron_) {
    gfx::Rect text = GetLocalBounds();
    text.Inset(gfx::Insets::TLBR(0, 10, 0, 24));
    DrawText(canvas, label_, font, color, text);
    DrawEditorGlyph(canvas, EditorGlyph::kChevronDown,
                    gfx::RectF(bounds.right() - 22, bounds.y(), 14,
                               bounds.height()),
                    WithAlpha(color, 0.7f), 9);
    return;
  }
  DrawText(canvas, label_, font, color, GetLocalBounds(),
           gfx::Canvas::TEXT_ALIGN_CENTER);
}

BEGIN_METADATA(EditorButton)
END_METADATA

// --- ColorPadView -----------------------------------------------------------

ColorPadView::ColorPadView(Callbacks callbacks)
    : callbacks_(std::move(callbacks)) {
  SetFocusBehavior(FocusBehavior::ALWAYS);
  GetViewAccessibility().SetRole(ax::mojom::Role::kSlider);
  GetViewAccessibility().SetName(u"Color");
  scale_animation_.SetSlideDuration(base::Milliseconds(m::kScaleMs));
  scale_animation_.SetTweenType(gfx::Tween::EASE_OUT);
}

ColorPadView::~ColorPadView() = default;

void ColorPadView::Apply(const ThemeEditorState& state,
                         const EditorColors& colors) {
  knobs_ = state.Knobs();
  has_style_ = state.style().has_value();
  gesture_ = state.gesture_in_progress();
  colors_ = colors;
  if (has_style_) {
    const theme::Hsl hsl = cm::ToHsl(KeyP3(*state.style()));
    GetViewAccessibility().SetValue(base::UTF8ToUTF16(
        "Hue " + std::to_string(std::lround(hsl.h * 360)) +
        "\xC2\xB0, lightness " + std::to_string(std::lround(hsl.l * 100)) +
        "%"));
  } else {
    GetViewAccessibility().SetValue(std::u16string_view(u"No color"));
  }
  UpdateKnobScale();
  SchedulePaint();
}

gfx::PointF ColorPadView::Unit(const gfx::PointF& p) const {
  const gfx::PointF c = gfx::RectF(GetLocalBounds()).CenterPoint();
  return gfx::PointF((p.x() - c.x()) / m::kPadRadius,
                     (p.y() - c.y()) / m::kPadRadius);
}

gfx::PointF ColorPadView::KnobCenter(const gfx::PointF& unit) const {
  const gfx::PointF c = gfx::RectF(GetLocalBounds()).CenterPoint();
  return gfx::PointF(c.x() + unit.x() * m::kPadRadius,
                     c.y() + unit.y() * m::kPadRadius);
}

std::optional<gfx::RectF> ColorPadView::PrimaryKnobFrame() const {
  if (knobs_.empty()) {
    return std::nullopt;
  }
  const gfx::PointF c = KnobCenter(knobs_[0].position);
  return gfx::RectF(c.x() - m::kPrimaryKnob / 2, c.y() - m::kPrimaryKnob / 2,
                    m::kPrimaryKnob, m::kPrimaryKnob);
}

bool ColorPadView::OnPrimaryKnob(const gfx::PointF& p) const {
  if (knobs_.empty()) {
    return false;
  }
  const gfx::PointF c = KnobCenter(knobs_[0].position);
  return std::hypot(p.x() - c.x(), p.y() - c.y()) <= m::kPrimaryKnob / 2 + 4;
}

float ColorPadView::CurrentScale() const {
  return scale_from_ + (scale_to_ - scale_from_) *
                           static_cast<float>(scale_animation_.GetCurrentValue());
}

void ColorPadView::UpdateKnobScale() {
  const float desired = gesture_          ? m::kKnobDragScale
                        : pointer_on_knob_ ? m::kKnobHoverScale
                                           : 1.0f;
  if (std::abs(desired - scale_to_) < 0.001f) {
    return;
  }
  scale_from_ = CurrentScale();
  scale_to_ = desired;
  scale_animation_.Reset(0);
  scale_animation_.Show();
}

void ColorPadView::AnimationProgressed(const gfx::Animation* animation) {
  SchedulePaint();
}

const gfx::ImageSkia& ColorPadView::DotGrid(float scale) {
  if (dot_grid_.isNull() || dot_grid_color_ != colors_.dot ||
      dot_grid_scale_ != scale) {
    const int side = static_cast<int>(m::kPadRadius * 2);
    gfx::Canvas grid(gfx::Size(side, side), scale, /*is_opaque=*/false);
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setColor(colors_.dot);
    for (float y = m::kDotPitch / 2; y < side; y += m::kDotPitch) {
      for (float x = m::kDotPitch / 2; x < side; x += m::kDotPitch) {
        grid.DrawCircle(gfx::PointF(x, y), 0.5f, flags);
      }
    }
    dot_grid_ = gfx::ImageSkia::CreateFromBitmap(grid.GetBitmap(), scale);
    dot_grid_color_ = colors_.dot;
    dot_grid_scale_ = scale;
  }
  return dot_grid_;
}

void ColorPadView::OnPaint(gfx::Canvas* canvas) {
  const gfx::RectF bounds(GetLocalBounds());
  canvas->Save();
  canvas->ClipPath(SkPath::RRect(gfx::RectFToSkRect(bounds),
                                 m::kPadCornerRadius, m::kPadCornerRadius),
                   true);
  canvas->DrawColor(colors_.pad_fill);
  canvas->DrawImageInt(DotGrid(canvas->image_scale()), 0, 0);
  if (!has_style_) {
    DrawText(canvas, u"Tap to pick a color for this space",
             Font(13, gfx::Font::Weight::SEMIBOLD), colors_.secondary_text,
             gfx::Rect(static_cast<int>(bounds.CenterPoint().x()) - 110,
                       static_cast<int>(bounds.CenterPoint().y()) - 10, 220,
                       20),
             gfx::Canvas::TEXT_ALIGN_CENTER);
  }
  const float primary_scale = CurrentScale();
  const bool active = gesture_ || pointer_on_knob_;
  // Secondary knobs below the key knob.
  for (size_t i = knobs_.size(); i-- > 0;) {
    const bool primary = i == 0;
    const float scale =
        primary ? primary_scale : (active ? m::kSecondaryActiveScale : 1.0f);
    const float size = (primary ? m::kPrimaryKnob : m::kSecondaryKnob) * scale;
    const float ring = (primary ? m::kPrimaryRing : m::kSecondaryRing) * scale;
    const gfx::PointF c = KnobCenter(knobs_[i].position);
    canvas->DrawCircle(c, size / 2, ShadowedFill(colors_.thumb, colors_.shadow));
    FillCircle(canvas, c, size / 2 - ring, SkFromP3(knobs_[i].color));
  }
  canvas->Restore();
  if (HasFocus() && show_focus_) {
    StrokeRRect(canvas, gfx::RectF(bounds.x() + 1, bounds.y() + 1,
                                   bounds.width() - 2, bounds.height() - 2),
                m::kPadCornerRadius + 1, colors_.focus_ring, 2);
  }
}

bool ColorPadView::OnMousePressed(const ui::MouseEvent& event) {
  if (!event.IsOnlyLeftMouseButton()) {
    return false;
  }
  show_focus_ = false;
  RequestFocus();
  const gfx::PointF p = event.location_f();
  if (event.GetClickCount() == 2 && callbacks_.on_remove_color) {
    for (size_t i = 1; i < knobs_.size(); ++i) {
      const gfx::PointF c = KnobCenter(knobs_[i].position);
      if (std::hypot(p.x() - c.x(), p.y() - c.y()) <=
          m::kSecondaryKnob / 2 + 3) {
        callbacks_.on_remove_color.Run();
        return true;
      }
    }
  }
  dragging_ = true;
  drag_relative_ = OnPrimaryKnob(p);
  if (callbacks_.on_drag) {
    callbacks_.on_drag.Run(Unit(p), drag_relative_);
  }
  return true;
}

bool ColorPadView::OnMouseDragged(const ui::MouseEvent& event) {
  if (dragging_ && callbacks_.on_drag) {
    callbacks_.on_drag.Run(Unit(event.location_f()), drag_relative_);
  }
  return true;
}

void ColorPadView::OnMouseReleased(const ui::MouseEvent& event) {
  if (!dragging_) {
    return;
  }
  dragging_ = false;
  if (callbacks_.on_end_drag) {
    callbacks_.on_end_drag.Run();
  }
}

void ColorPadView::OnMouseCaptureLost() {
  if (!dragging_) {
    return;
  }
  dragging_ = false;
  if (callbacks_.on_end_drag) {
    callbacks_.on_end_drag.Run();
  }
}

void ColorPadView::OnMouseMoved(const ui::MouseEvent& event) {
  const bool hovered = OnPrimaryKnob(event.location_f());
  if (hovered != pointer_on_knob_) {
    pointer_on_knob_ = hovered;
    UpdateKnobScale();
    SchedulePaint();
  }
}

void ColorPadView::OnMouseExited(const ui::MouseEvent& event) {
  if (pointer_on_knob_) {
    pointer_on_knob_ = false;
    UpdateKnobScale();
    SchedulePaint();
  }
}

namespace {
int ArrowBit(ui::KeyboardCode code) {
  switch (code) {
    case ui::VKEY_LEFT:
      return 1;
    case ui::VKEY_RIGHT:
      return 2;
    case ui::VKEY_UP:
      return 4;
    case ui::VKEY_DOWN:
      return 8;
    default:
      return 0;
  }
}
}  // namespace

bool ColorPadView::OnKeyPressed(const ui::KeyEvent& event) {
  const int bit = ArrowBit(event.key_code());
  if (!bit) {
    return false;
  }
  show_focus_ = true;
  if (!keyboard_active_) {
    keyboard_active_ = true;
    if (callbacks_.on_begin_keyboard) {
      callbacks_.on_begin_keyboard.Run();
    }
  }
  arrow_keys_down_ |= bit;
  const bool shifted = event.IsShiftDown();
  switch (event.key_code()) {
    case ui::VKEY_LEFT:
      if (callbacks_.on_keyboard_hue) {
        callbacks_.on_keyboard_hue.Run(shifted ? -20 : -5);
      }
      break;
    case ui::VKEY_RIGHT:
      if (callbacks_.on_keyboard_hue) {
        callbacks_.on_keyboard_hue.Run(shifted ? 20 : 5);
      }
      break;
    case ui::VKEY_UP:
      if (callbacks_.on_keyboard_radius) {
        callbacks_.on_keyboard_radius.Run(shifted ? 0.1 : 0.03);
      }
      break;
    case ui::VKEY_DOWN:
      if (callbacks_.on_keyboard_radius) {
        callbacks_.on_keyboard_radius.Run(shifted ? -0.1 : -0.03);
      }
      break;
    default:
      break;
  }
  SchedulePaint();
  return true;
}

bool ColorPadView::OnKeyReleased(const ui::KeyEvent& event) {
  const int bit = ArrowBit(event.key_code());
  if (!bit || !(arrow_keys_down_ & bit)) {
    return false;
  }
  arrow_keys_down_ &= ~bit;
  if (arrow_keys_down_ == 0) {
    FinishKeyboardGesture();
  }
  return true;
}

void ColorPadView::OnBlur() {
  FinishKeyboardGesture();
  show_focus_ = false;
  SchedulePaint();
}

void ColorPadView::FinishKeyboardGesture() {
  arrow_keys_down_ = 0;
  if (!keyboard_active_) {
    return;
  }
  keyboard_active_ = false;
  if (callbacks_.on_end_keyboard) {
    callbacks_.on_end_keyboard.Run();
  }
}

BEGIN_METADATA(ColorPadView)
END_METADATA

// --- AppearanceModeBar ------------------------------------------------------

namespace {
constexpr std::array<ThemeAppearance, 3> kModes = {
    ThemeAppearance::kAutomatic, ThemeAppearance::kLight,
    ThemeAppearance::kDark};
}  // namespace

AppearanceModeBar::AppearanceModeBar(
    base::RepeatingCallback<void(ThemeAppearance)> on_select)
    : on_select_(std::move(on_select)) {
  GetViewAccessibility().SetRole(ax::mojom::Role::kRadioGroup);
  GetViewAccessibility().SetName(u"Appearance");
  constexpr std::array<EditorGlyph, 3> glyphs = {
      EditorGlyph::kSparkles, EditorGlyph::kSun, EditorGlyph::kMoon};
  constexpr std::array<const char16_t*, 3> names = {u"Automatic", u"Light",
                                                    u"Dark"};
  for (size_t i = 0; i < names.size(); ++i) {
    auto button = std::make_unique<HandEditorButton>(
        base::BindRepeating(
            [](AppearanceModeBar* bar, ThemeAppearance mode) {
              if (bar->on_select_) {
                bar->on_select_.Run(mode);
              }
            },
            base::Unretained(this), kModes[i]),
        glyphs[i], i == 2 ? 16.0f : 15.0f, names[i]);
    button->SetTooltipText(std::u16string(names[i]) + u" Appearance");
    button->GetViewAccessibility().SetRole(ax::mojom::Role::kRadioButton);
    if (i == 0) {
      button->SetGlyphOffset(-1);
    }
    buttons_.push_back(AddChildView(std::move(button)));
  }
  Apply(ThemeAppearance::kAutomatic, EditorColors::For(true));
}

AppearanceModeBar::~AppearanceModeBar() = default;

void AppearanceModeBar::Apply(ThemeAppearance mode,
                              const EditorColors& colors) {
  mode_ = mode;
  for (size_t i = 0; i < buttons_.size(); ++i) {
    buttons_[i]->SetColors(colors);
    buttons_[i]->SetSelected(kModes[i] == mode);
  }
}

void AppearanceModeBar::Layout(PassKey) {
  for (size_t i = 0; i < buttons_.size(); ++i) {
    buttons_[i]->SetBounds(static_cast<int>(i) * 40, 0, 32, 32);
  }
}

BEGIN_METADATA(AppearanceModeBar)
END_METADATA

// --- PresetStripView --------------------------------------------------------

PresetStripView::PresetStripView(Callbacks callbacks)
    : callbacks_(std::move(callbacks)) {
  SetFocusBehavior(FocusBehavior::ALWAYS);
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
  GetViewAccessibility().SetName(u"Color presets");
  page_animation_.SetSlideDuration(base::Milliseconds(m::kPresetPageMs));
  page_animation_.SetTweenType(gfx::Tween::EASE_OUT_3);
  previous_ = AddChildView(std::make_unique<HandEditorButton>(
      base::BindRepeating(
          [](PresetStripView* strip) {
            if (strip->callbacks_.on_page) {
              strip->callbacks_.on_page.Run(strip->page_ - 1);
            }
          },
          base::Unretained(this)),
      EditorGlyph::kChevronLeft, 16, u"Previous color presets"));
  previous_->SetGlyphOffset(1);
  next_ = AddChildView(std::make_unique<HandEditorButton>(
      base::BindRepeating(
          [](PresetStripView* strip) {
            if (strip->callbacks_.on_page) {
              strip->callbacks_.on_page.Run(strip->page_ + 1);
            }
          },
          base::Unretained(this)),
      EditorGlyph::kChevronRight, 16, u"Next color presets"));
  next_->SetGlyphOffset(1);
  Apply(0, EditorColors::For(true));
}

PresetStripView::~PresetStripView() = default;

float PresetStripView::StripOffset() const {
  return offset_from_ + (offset_to_ - offset_from_) *
                            static_cast<float>(page_animation_.GetCurrentValue());
}

void PresetStripView::Apply(int page, const EditorColors& colors) {
  colors_ = colors;
  previous_->SetColors(colors);
  next_->SetColors(colors);
  page = std::clamp(page, 0, kPresetPageCount - 1);
  if (page != page_) {
    offset_from_ = StripOffset();
    offset_to_ = -page * page_width_;
    page_ = page;
    focused_.reset();
    page_animation_.Reset(0);
    page_animation_.Show();
  }
  previous_->SetEnabled(page_ > 0);
  next_->SetEnabled(page_ < kPresetPageCount - 1);
  SchedulePaint();
}

void PresetStripView::SetSelected(std::optional<size_t> index) {
  selected_ = index;
  SchedulePaint();
}

void PresetStripView::SetCompact(bool compact) {
  compact_ = compact;
  InvalidateLayout();
}

void PresetStripView::Layout(PassKey) {
  previous_->SetVisible(!compact_);
  next_->SetVisible(!compact_);
  if (compact_) {
    viewport_x_ = 0;
    viewport_width_ = width();
  } else {
    previous_->SetBoundsRect(m::kPrevious);
    next_->SetBoundsRect(m::kNext);
    viewport_x_ = m::kSwatches.x();
    viewport_width_ = m::kSwatches.width();
  }
  // Swift: 260 pt viewport, 29.5 pt pitch, 265.5 pt page.
  pitch_ = (viewport_width_ - m::kSwatch) / (kSwatchesPerPage - 1);
  page_width_ = viewport_width_ + 5.5f;
  page_animation_.Reset(1);
  offset_from_ = offset_to_ = -page_ * page_width_;
}

gfx::RectF PresetStripView::SwatchRect(size_t index) const {
  const float scale = std::max(1.0f, device_scale_);
  const float column = static_cast<float>(index % kSwatchesPerPage);
  const float x = viewport_x_ + StripOffset() +
                  static_cast<float>(index / kSwatchesPerPage) * page_width_ +
                  std::floor(column * pitch_ * scale) / scale;
  return gfx::RectF(x, (height() - m::kSwatch) / 2.0f, m::kSwatch, m::kSwatch);
}

std::optional<size_t> PresetStripView::SwatchAt(const gfx::Point& p) const {
  if (p.x() < viewport_x_ || p.x() >= viewport_x_ + viewport_width_) {
    return std::nullopt;
  }
  const size_t first = static_cast<size_t>(page_) * kSwatchesPerPage;
  for (size_t i = first; i < first + kSwatchesPerPage; ++i) {
    if (SwatchRect(i).Contains(gfx::PointF(p))) {
      return i;
    }
  }
  return std::nullopt;
}

void PresetStripView::OnPaint(gfx::Canvas* canvas) {
  device_scale_ = canvas->image_scale();
  canvas->Save();
  canvas->ClipRect(gfx::RectF(viewport_x_, 0, viewport_width_, height()));
  for (size_t i = 0; i < ThemePresets().size(); ++i) {
    gfx::RectF r = SwatchRect(i);
    if (r.right() < viewport_x_ - 4 ||
        r.x() > viewport_x_ + viewport_width_ + 4) {
      continue;
    }
    const float scale = pressed_ == i ? 0.9f : hovered_ == i ? 1.1f : 1.0f;
    gfx::RectF art = r;
    art.Outset((r.width() * scale - r.width()) / 2);
    if (selected_ == i) {
      canvas->DrawCircle(r.CenterPoint(), r.width() / 2 + 3,
                         StrokeFlags(colors_.primary_text, 2));
    }
    PaintPresetSwatch(canvas, i, art);
    if (HasFocus() && focused_ == i) {
      canvas->DrawCircle(r.CenterPoint(), r.width() / 2 + 2,
                         StrokeFlags(colors_.focus_ring, 2));
    }
  }
  canvas->Restore();
}

bool PresetStripView::OnMousePressed(const ui::MouseEvent& event) {
  if (!event.IsOnlyLeftMouseButton()) {
    return false;
  }
  pressed_ = SwatchAt(event.location());
  SchedulePaint();
  return pressed_.has_value();
}

void PresetStripView::OnMouseReleased(const ui::MouseEvent& event) {
  const std::optional<size_t> pressed = pressed_;
  pressed_.reset();
  SchedulePaint();
  if (pressed && SwatchAt(event.location()) == pressed &&
      callbacks_.on_select) {
    callbacks_.on_select.Run(*pressed);
  }
}

void PresetStripView::OnMouseMoved(const ui::MouseEvent& event) {
  const std::optional<size_t> hovered = SwatchAt(event.location());
  if (hovered != hovered_) {
    hovered_ = hovered;
    SetTooltipText(hovered ? ThemePresets()[*hovered].name : std::u16string());
    SchedulePaint();
  }
}

void PresetStripView::OnMouseExited(const ui::MouseEvent& event) {
  hovered_.reset();
  SchedulePaint();
}

bool PresetStripView::OnMouseWheel(const ui::MouseWheelEvent& event) {
  const int dx = event.x_offset();
  const int dy = event.y_offset();
  // Full strip: horizontal swipes only (vertical scroll passes on). Compact
  // card: either axis.
  const float delta = std::abs(dx) > std::abs(dy) ? dx : (compact_ ? -dy : 0);
  if (delta == 0) {
    return false;
  }
  scroll_amount_ += delta;
  if (std::abs(scroll_amount_) >= 30 && callbacks_.on_page) {
    callbacks_.on_page.Run(page_ + (scroll_amount_ > 0 ? 1 : -1));
    scroll_amount_ = 0;
  }
  return true;
}

bool PresetStripView::OnKeyPressed(const ui::KeyEvent& event) {
  const size_t first = static_cast<size_t>(page_) * kSwatchesPerPage;
  const size_t current = focused_.value_or(first);
  switch (event.key_code()) {
    case ui::VKEY_LEFT:
      if (current > first) {
        focused_ = current - 1;
      } else if (page_ > 0 && callbacks_.on_page) {
        callbacks_.on_page.Run(page_ - 1);
        focused_ = first - 1;
      }
      SchedulePaint();
      return true;
    case ui::VKEY_RIGHT:
      if (current + 1 < first + kSwatchesPerPage) {
        focused_ = focused_ ? current + 1 : first;
      } else if (page_ < kPresetPageCount - 1 && callbacks_.on_page) {
        callbacks_.on_page.Run(page_ + 1);
        focused_ = first + kSwatchesPerPage;
      }
      SchedulePaint();
      return true;
    case ui::VKEY_RETURN:
    case ui::VKEY_SPACE:
      if (callbacks_.on_select) {
        callbacks_.on_select.Run(current);
      }
      return true;
    default:
      return false;
  }
}

void PresetStripView::OnFocus() {
  if (!focused_) {
    focused_ = static_cast<size_t>(page_) * kSwatchesPerPage;
  }
  SchedulePaint();
}

void PresetStripView::OnBlur() {
  SchedulePaint();
}

void PresetStripView::AnimationProgressed(const gfx::Animation* animation) {
  SchedulePaint();
}

BEGIN_METADATA(PresetStripView)
END_METADATA

// --- SineSliderView ---------------------------------------------------------

SineSliderView::SineSliderView(
    base::RepeatingCallback<void(double, bool)> on_change)
    : on_change_(std::move(on_change)) {
  SetFocusBehavior(FocusBehavior::ALWAYS);
  GetViewAccessibility().SetRole(ax::mojom::Role::kSlider);
  GetViewAccessibility().SetName(u"Intensity");
  SetTooltipText(u"Intensity");
  views::FocusRing::Install(this);
  views::InstallRoundRectHighlightPathGenerator(
      this, gfx::Insets::VH(static_cast<int>(m::kIntensityArtOffset), 0), 12);
}

SineSliderView::~SineSliderView() = default;

void SineSliderView::Apply(double value,
                           bool enabled,
                           const EditorColors& colors) {
  value_ = Clamp01(value);
  enabled_ = enabled;
  colors_ = colors;
  GetViewAccessibility().SetValue(
      base::NumberToString16(std::lround(value_ * 100)));
  SchedulePaint();
}

gfx::SizeF SineSliderView::ThumbSize() const {
  // Fitted against F0137/F0138 (thumb grows with the value).
  if (value_ <= 0.8) {
    return gfx::SizeF(12.2f + 12.2f * value_ / 0.8f, 44.4f + 11.6f * value_ / 0.8f);
  }
  const float t = static_cast<float>((value_ - 0.8) / 0.2);
  return gfx::SizeF(24.4f + 2.65f * t, 56 + 3.15f * t);
}

gfx::RectF SineSliderView::ThumbFrame() const {
  const gfx::SizeF size = ThumbSize();
  const float cx = m::kIntensityThumbStart +
                   m::kIntensityTravel * static_cast<float>(value_);
  const float cy = 28 + m::kIntensityArtOffset;
  return gfx::RectF(cx - size.width() / 2, cy - size.height() / 2,
                    size.width(), size.height());
}

void SineSliderView::OnPaint(gfx::Canvas* canvas) {
  const float o = m::kIntensityArtOffset;
  FillRRect(canvas, gfx::RectF(0, 20 + o, 224, 16), 8, colors_.track_fill);
  // The wave: amplitude 14.8 * value, period 37.9 pt, from x 7.8 to 216.2.
  const double amplitude = 14.8 * value_;
  SkPathBuilder b;
  b.moveTo(7.8f, 28 + o);
  for (double x = 8.05; x <= 216.2; x += 0.25) {
    b.lineTo(static_cast<float>(x),
             static_cast<float>(28 + o -
                                amplitude * std::sin((x - 7.8) * 2 * kPi / 37.9)));
  }
  b.lineTo(216.2f, 28 + o);
  const SkPath wave = b.detach();
  const gfx::RectF thumb = ThumbFrame();
  const float split = enabled_ ? thumb.CenterPoint().x() : 0;
  canvas->Save();
  canvas->ClipRect(gfx::RectF(split, 0, std::max(0.0f, width() - split), height()));
  canvas->DrawPath(wave, StrokeFlags(colors_.wave_inactive, 4.5f));
  canvas->Restore();
  if (!enabled_) {
    return;
  }
  canvas->Save();
  canvas->ClipRect(gfx::RectF(0, 0, split, height()));
  canvas->DrawPath(wave, StrokeFlags(colors_.wave_active, 4.5f));
  canvas->Restore();
  const float scale = (hovered_ || pressed_) ? 1.09f : 1.0f;
  const gfx::RectF art(
      thumb.CenterPoint().x() - thumb.width() * scale / 2,
      thumb.CenterPoint().y() - thumb.height() * scale / 2,
      thumb.width() * scale, thumb.height() * scale);
  canvas->DrawRoundRect(art, art.width() / 2,
                        ShadowedFill(colors_.thumb, colors_.shadow));
}

void SineSliderView::Drag(const gfx::PointF& p, bool final) {
  if (!enabled_ || !on_change_) {
    return;
  }
  const double target = Clamp01((p.x() - m::kIntensityThumbStart) /
                                m::kIntensityTravel);
  // A stationary click keeps the exact stored value (no undo step).
  on_change_.Run(std::abs(target - value_) < 1e-12 ? value_ : target, final);
}

bool SineSliderView::OnMousePressed(const ui::MouseEvent& event) {
  if (!enabled_ || !event.IsOnlyLeftMouseButton()) {
    return false;
  }
  wheel_end_.Stop();
  RequestFocus();
  pressed_ = true;
  Drag(event.location_f(), false);
  return true;
}

bool SineSliderView::OnMouseDragged(const ui::MouseEvent& event) {
  if (pressed_) {
    Drag(event.location_f(), false);
  }
  return true;
}

void SineSliderView::OnMouseReleased(const ui::MouseEvent& event) {
  if (!pressed_) {
    return;
  }
  pressed_ = false;
  Drag(event.location_f(), true);
  hovered_ = ThumbFrame().Contains(event.location_f());
  SchedulePaint();
}

void SineSliderView::OnMouseCaptureLost() {
  if (!pressed_) {
    return;
  }
  pressed_ = false;
  if (on_change_) {
    on_change_.Run(value_, true);
  }
  SchedulePaint();
}

void SineSliderView::OnMouseMoved(const ui::MouseEvent& event) {
  const bool hovered = enabled_ && ThumbFrame().Contains(event.location_f());
  if (hovered != hovered_) {
    hovered_ = hovered;
    SchedulePaint();
  }
}

void SineSliderView::OnMouseExited(const ui::MouseEvent& event) {
  hovered_ = false;
  SchedulePaint();
}

bool SineSliderView::OnMouseWheel(const ui::MouseWheelEvent& event) {
  if (!enabled_ || !on_change_ || event.y_offset() == 0) {
    return false;
  }
  // 0.02 per line (Swift deltaY * 0.02); a wheel notch is kWheelDelta.
  const double step = 0.02 * event.y_offset() / (ui::MouseWheelEvent::kWheelDelta / 3.0);
  on_change_.Run(Clamp01(value_ + step), false);
  wheel_end_.Start(FROM_HERE, base::Milliseconds(300),
                   base::BindOnce(
                       [](SineSliderView* view) {
                         if (view->on_change_) {
                           view->on_change_.Run(view->value_, true);
                         }
                       },
                       base::Unretained(this)));
  return true;
}

bool SineSliderView::OnKeyPressed(const ui::KeyEvent& event) {
  if (!enabled_ || !on_change_) {
    return false;
  }
  if (event.key_code() == ui::VKEY_LEFT) {
    on_change_.Run(Clamp01(value_ - 0.05), true);
    return true;
  }
  if (event.key_code() == ui::VKEY_RIGHT) {
    on_change_.Run(Clamp01(value_ + 0.05), true);
    return true;
  }
  return false;
}

BEGIN_METADATA(SineSliderView)
END_METADATA

// --- NoiseDialView ----------------------------------------------------------

NoiseDialView::NoiseDialView(Callbacks callbacks)
    : callbacks_(std::move(callbacks)) {
  SetFocusBehavior(FocusBehavior::ALWAYS);
  GetViewAccessibility().SetRole(ax::mojom::Role::kSlider);
  GetViewAccessibility().SetName(u"Noise");
  SetTooltipText(u"Noise");
  views::FocusRing::Install(this);
  views::InstallCircleHighlightPathGenerator(this, gfx::Insets::VH(0, 2));
}

NoiseDialView::~NoiseDialView() = default;

void NoiseDialView::Apply(double value,
                          ThemeTexture texture,
                          bool enabled,
                          const EditorColors& colors) {
  value_ = Clamp01(value);
  texture_ = texture;
  enabled_ = enabled;
  colors_ = colors;
  GetViewAccessibility().SetValue(
      base::NumberToString16(std::lround(value_ * 100)));
  SchedulePaint();
}

gfx::PointF NoiseDialView::RingPoint(double degrees) const {
  const double a = degrees * kPi / 180;
  return gfx::PointF(
      m::kNoiseCenter.x() + m::kNoiseRadius * static_cast<float>(std::sin(a)),
      m::kNoiseCenter.y() - m::kNoiseRadius * static_cast<float>(std::cos(a)));
}

double NoiseDialView::AngleAt(const gfx::PointF& p) const {
  const double a = std::atan2(p.x() - m::kNoiseCenter.x(),
                              m::kNoiseCenter.y() - p.y()) /
                   (2 * kPi);
  return a < 0 ? a + 1 : a;
}

bool NoiseDialView::DotHidden(int index) const {
  // Lead decision: non-wrapping distance to 0..342 degrees, half a slot of
  // tolerance; at the exact end point the tick sits on slot zero again.
  if (!enabled_) {
    return false;
  }
  const double angle = value_ == 1 ? 0 : value_ * 360;
  const int nearest =
      std::clamp(static_cast<int>(std::lround(angle / 18)), 0, 19);
  return index == nearest && std::abs(nearest * 18.0 - angle) <= 9;
}

bool NoiseDialView::InCenter(const gfx::PointF& p) const {
  return std::hypot(p.x() - m::kNoiseCenter.x(), p.y() - m::kNoiseCenter.y()) <=
         m::kNoiseButton / 2;
}

void NoiseDialView::OnPaint(gfx::Canvas* canvas) {
  const double tick_angle = value_ * 360;
  for (int i = 0; i < 20; ++i) {
    if (DotHidden(i)) {
      continue;
    }
    const bool lit = enabled_ && i * 18.0 <= tick_angle + 1e-9;
    FillCircle(canvas, RingPoint(i * 18.0), 2.5f,
               lit ? colors_.dot_lit : colors_.dot_unlit);
  }
  // Center texture button: 40 pt circle, 1 pt rim, texture preview.
  const gfx::RectF button(m::kNoiseCenter.x() - m::kNoiseButton / 2,
                          m::kNoiseCenter.y() - m::kNoiseButton / 2,
                          m::kNoiseButton, m::kNoiseButton);
  if (enabled_ && value_ > 0) {
    if (!preview_) {
      preview_ = std::make_unique<theme::ThemePainter>();
    }
    if (preview_texture_ != texture_) {
      theme::ThemeStyle style;
      style.fill_kind = theme::ThemeStyle::FillKind::kCorners;
      const Rgba gray{0.46, 0.46, 0.46, 1};  // noisePreviewBase
      style.corners = {gray, gray, gray, gray};
      style.noise_factor = 1;
      style.texture = texture_;
      style.uses_legacy_intensity = false;
      preview_->SetStyle(style);
      preview_texture_ = texture_;
    }
    canvas->Save();
    canvas->ClipPath(SkPath::Circle(button.CenterPoint().x(),
                                    button.CenterPoint().y(), button.width() / 2),
                     true);
    preview_->Paint(canvas, gfx::ToEnclosingRect(button), button);
    canvas->Restore();
  }
  canvas->DrawCircle(button.CenterPoint(), button.width() / 2 - 0.5f,
                     StrokeFlags(colors_.dot_unlit, 1));
  if (!enabled_) {
    return;
  }
  // The tick: 8 x 16, radius 4, rotated with the value; its shadow stays
  // below at every angle (rotate the geometry, not the shadow).
  const gfx::PointF center = RingPoint(tick_angle);
  const float scale = std::max(1.0f, canvas->image_scale());
  const float tx = std::round(center.x() * scale) / scale;
  const float ty = std::round(center.y() * scale) / scale;
  SkPathBuilder b;
  b.addRRect(SkRRect::MakeRectXY(
      SkRect::MakeXYWH(tx - m::kNoiseTickWidth / 2, ty - m::kNoiseTickHeight / 2,
                       m::kNoiseTickWidth, m::kNoiseTickHeight),
      4, 4));
  const SkMatrix rotation =
      SkMatrix::RotateDeg(static_cast<float>(tick_angle), SkPoint::Make(tx, ty));
  canvas->DrawPath(b.detach(&rotation),
                   ShadowedFill(colors_.thumb, colors_.shadow));
}

bool NoiseDialView::OnMousePressed(const ui::MouseEvent& event) {
  if (!enabled_ || !event.IsOnlyLeftMouseButton()) {
    return false;
  }
  wheel_end_.Stop();
  RequestFocus();
  const gfx::PointF p = event.location_f();
  if (InCenter(p)) {
    center_pressed_ = true;
    return true;
  }
  pressed_ = true;
  if (!callbacks_.on_change) {
    return true;
  }
  int nearest = 0;
  float best = 1e9f;
  for (int i = 0; i < 20; ++i) {
    const gfx::PointF d = RingPoint(i * 18.0);
    const float dist = std::hypot(p.x() - d.x(), p.y() - d.y());
    if (dist < best) {
      best = dist;
      nearest = i;
    }
  }
  callbacks_.on_change.Run(best <= 3 ? nearest * 0.05 : AngleAt(p), false);
  return true;
}

bool NoiseDialView::OnMouseDragged(const ui::MouseEvent& event) {
  if (!enabled_ || !pressed_ || !callbacks_.on_change) {
    return true;
  }
  const double raw = AngleAt(event.location_f());
  // No wrap-around: past the top the dial pins at 0 or 1.
  const double target =
      std::abs(raw - value_) > 0.5 ? (value_ < 0.5 ? 0.0 : 1.0) : raw;
  callbacks_.on_change.Run(target, false);
  return true;
}

void NoiseDialView::OnMouseReleased(const ui::MouseEvent& event) {
  if (center_pressed_) {
    center_pressed_ = false;
    if (enabled_ && InCenter(event.location_f()) &&
        callbacks_.on_cycle_texture) {
      callbacks_.on_cycle_texture.Run();
    }
    return;
  }
  if (!pressed_) {
    return;
  }
  pressed_ = false;
  if (callbacks_.on_change) {
    callbacks_.on_change.Run(value_, true);
  }
}

void NoiseDialView::OnMouseCaptureLost() {
  center_pressed_ = false;
  if (pressed_) {
    pressed_ = false;
    if (callbacks_.on_change) {
      callbacks_.on_change.Run(value_, true);
    }
  }
}

bool NoiseDialView::OnMouseWheel(const ui::MouseWheelEvent& event) {
  if (!enabled_ || !callbacks_.on_change || event.y_offset() == 0) {
    return false;
  }
  // 0.01 per line (Swift deltaY * 0.01).
  const double step =
      0.01 * event.y_offset() / (ui::MouseWheelEvent::kWheelDelta / 3.0);
  callbacks_.on_change.Run(Clamp01(value_ + step), false);
  wheel_end_.Start(FROM_HERE, base::Milliseconds(300),
                   base::BindOnce(
                       [](NoiseDialView* view) {
                         if (view->callbacks_.on_change) {
                           view->callbacks_.on_change.Run(view->value_, true);
                         }
                       },
                       base::Unretained(this)));
  return true;
}

bool NoiseDialView::OnKeyPressed(const ui::KeyEvent& event) {
  if (!enabled_) {
    return false;
  }
  switch (event.key_code()) {
    case ui::VKEY_LEFT:
      if (callbacks_.on_change) {
        callbacks_.on_change.Run(Clamp01(value_ - 0.05), true);
      }
      return true;
    case ui::VKEY_RIGHT:
      if (callbacks_.on_change) {
        callbacks_.on_change.Run(Clamp01(value_ + 0.05), true);
      }
      return true;
    case ui::VKEY_RETURN:
    case ui::VKEY_SPACE:
      if (callbacks_.on_cycle_texture) {
        callbacks_.on_cycle_texture.Run();
      }
      return true;
    default:
      return false;
  }
}

BEGIN_METADATA(NoiseDialView)
END_METADATA

}  // namespace space_editor

// ===========================================================================
// Profiles.
// ===========================================================================

std::vector<SpaceProfileChoice> SpaceProfileChoicesFrom(
    const std::vector<Profile>& profiles) {
  std::vector<SpaceProfileChoice> out;
  out.reserve(profiles.size());
  for (const Profile& profile : profiles) {
    out.push_back({profile.id,
                   base::UTF8ToUTF16(profile.name.empty() ? std::string("Profile")
                                                          : profile.name),
                   profile.icon});
  }
  return out;
}

// ===========================================================================
// OpenSpaceIconPickerView.
// ===========================================================================

namespace {

namespace m = space_editor::metrics;
using space_editor::EditorColors;
using space_editor::EditorGlyph;

struct EmojiEntry {
  const char* value;
  const char* name;
  int category;
};

// Curated emoji (Unicode characters with CLDR-style short names), in the
// eight picker categories.
constexpr EmojiEntry kEmoji[] = {
    // 0 Smileys & People
    {"\xF0\x9F\x98\x80", "grinning face smile happy", 0},
    {"\xF0\x9F\x98\x8A", "smiling face blush", 0},
    {"\xF0\x9F\x98\x82", "tears of joy laugh", 0},
    {"\xF0\x9F\x99\x82", "slightly smiling face", 0},
    {"\xF0\x9F\x98\x8D", "heart eyes love", 0},
    {"\xF0\x9F\x98\x8E", "sunglasses cool", 0},
    {"\xF0\x9F\xA4\x93", "nerd glasses", 0},
    {"\xF0\x9F\xA4\x94", "thinking face", 0},
    {"\xF0\x9F\x98\xB4", "sleeping face zzz", 0},
    {"\xF0\x9F\xA5\xB3", "partying face party", 0},
    {"\xF0\x9F\xA4\xAF", "exploding head mind blown", 0},
    {"\xF0\x9F\x98\x87", "halo angel innocent", 0},
    {"\xF0\x9F\x91\x8B", "waving hand hello", 0},
    {"\xF0\x9F\x91\x8D", "thumbs up like", 0},
    {"\xF0\x9F\x99\x8F", "folded hands please thanks", 0},
    {"\xF0\x9F\x92\xAA", "flexed biceps strong", 0},
    {"\xF0\x9F\xA7\xA0", "brain think", 0},
    {"\xF0\x9F\x91\x80", "eyes look", 0},
    {"\xF0\x9F\x91\xBB", "ghost", 0},
    {"\xF0\x9F\xA4\x96", "robot", 0},
    {"\xF0\x9F\x91\xBD", "alien", 0},
    // 1 Animals & Nature
    {"\xF0\x9F\x90\xB6", "dog face puppy", 1},
    {"\xF0\x9F\x90\xB1", "cat face kitten", 1},
    {"\xF0\x9F\xA6\x8A", "fox", 1},
    {"\xF0\x9F\x90\xBB", "bear", 1},
    {"\xF0\x9F\x90\xBC", "panda", 1},
    {"\xF0\x9F\x90\xA8", "koala", 1},
    {"\xF0\x9F\xA6\x81", "lion", 1},
    {"\xF0\x9F\x90\xB8", "frog", 1},
    {"\xF0\x9F\x90\xA7", "penguin", 1},
    {"\xF0\x9F\xA6\x89", "owl", 1},
    {"\xF0\x9F\xA6\x8B", "butterfly", 1},
    {"\xF0\x9F\x90\x99", "octopus", 1},
    {"\xF0\x9F\x90\xA2", "turtle", 1},
    {"\xF0\x9F\x8C\xB5", "cactus", 1},
    {"\xF0\x9F\x8C\xB2", "evergreen tree", 1},
    {"\xF0\x9F\x8C\xBF", "herb plant", 1},
    {"\xF0\x9F\x8C\xB8", "cherry blossom flower", 1},
    {"\xF0\x9F\x8C\xBB", "sunflower", 1},
    {"\xF0\x9F\x8D\x84", "mushroom", 1},
    {"\xF0\x9F\x8C\x8A", "water wave ocean", 1},
    {"\xF0\x9F\x8C\x99", "crescent moon night", 1},
    {"\xE2\x98\x80\xEF\xB8\x8F", "sun sunny", 1},
    {"\xE2\x9A\xA1", "high voltage lightning", 1},
    {"\xF0\x9F\x94\xA5", "fire flame", 1},
    // 2 Food & Drink
    {"\xF0\x9F\x8D\x8E", "red apple", 2},
    {"\xF0\x9F\x8D\x8B", "lemon", 2},
    {"\xF0\x9F\x8D\x89", "watermelon", 2},
    {"\xF0\x9F\x8D\x93", "strawberry", 2},
    {"\xF0\x9F\xA5\x91", "avocado", 2},
    {"\xF0\x9F\xA5\x95", "carrot", 2},
    {"\xF0\x9F\x8D\x9E", "bread", 2},
    {"\xF0\x9F\xA7\x80", "cheese", 2},
    {"\xF0\x9F\x8D\x95", "pizza", 2},
    {"\xF0\x9F\x8D\x94", "hamburger burger", 2},
    {"\xF0\x9F\x8C\xAE", "taco", 2},
    {"\xF0\x9F\x8D\xA3", "sushi", 2},
    {"\xF0\x9F\x8D\x9C", "steaming bowl ramen noodles", 2},
    {"\xF0\x9F\x8D\xA9", "doughnut donut", 2},
    {"\xF0\x9F\x8D\xAA", "cookie", 2},
    {"\xF0\x9F\x8E\x82", "birthday cake", 2},
    {"\xE2\x98\x95", "hot beverage coffee tea", 2},
    {"\xF0\x9F\x8D\xB5", "teacup", 2},
    {"\xF0\x9F\x8D\xB7", "wine glass", 2},
    {"\xF0\x9F\x8D\xBA", "beer mug", 2},
    // 3 Activities
    {"\xE2\x9A\xBD", "soccer ball football", 3},
    {"\xF0\x9F\x8F\x80", "basketball", 3},
    {"\xF0\x9F\x8E\xBE", "tennis", 3},
    {"\xE2\x9A\xBE", "baseball", 3},
    {"\xF0\x9F\x8F\x93", "ping pong table tennis", 3},
    {"\xF0\x9F\x8E\xAE", "video game controller", 3},
    {"\xF0\x9F\x8E\xB2", "game die dice", 3},
    {"\xE2\x99\x9F\xEF\xB8\x8F", "chess pawn", 3},
    {"\xF0\x9F\xA7\xA9", "puzzle piece jigsaw", 3},
    {"\xF0\x9F\x8E\xA8", "artist palette art paint", 3},
    {"\xF0\x9F\x8E\xAC", "clapper board movie film", 3},
    {"\xF0\x9F\x8E\xA7", "headphone music", 3},
    {"\xF0\x9F\x8E\xB8", "guitar", 3},
    {"\xF0\x9F\x8E\xB9", "musical keyboard piano", 3},
    {"\xF0\x9F\x8F\x86", "trophy win", 3},
    {"\xF0\x9F\x8E\xAF", "direct hit target bullseye", 3},
    {"\xF0\x9F\xA7\x98", "yoga meditate", 3},
    {"\xF0\x9F\x8F\x83", "running runner", 3},
    {"\xF0\x9F\x9A\xB4", "biking bicycle cyclist", 3},
    // 4 Travel & Places
    {"\xF0\x9F\x8F\xA0", "house home", 4},
    {"\xF0\x9F\x8F\xA2", "office building work", 4},
    {"\xF0\x9F\x8F\xAB", "school", 4},
    {"\xF0\x9F\x8F\xA5", "hospital", 4},
    {"\xF0\x9F\x8F\x96\xEF\xB8\x8F", "beach umbrella vacation", 4},
    {"\xE2\x9B\xB0\xEF\xB8\x8F", "mountain", 4},
    {"\xF0\x9F\x8F\x95\xEF\xB8\x8F", "camping tent", 4},
    {"\xF0\x9F\x97\xBA\xEF\xB8\x8F", "world map", 4},
    {"\xF0\x9F\x8C\x8D", "globe earth world", 4},
    {"\xF0\x9F\x9A\x80", "rocket launch", 4},
    {"\xE2\x9C\x88\xEF\xB8\x8F", "airplane travel flight", 4},
    {"\xF0\x9F\x9A\x97", "automobile car", 4},
    {"\xF0\x9F\x9A\x82", "locomotive train", 4},
    {"\xF0\x9F\x9A\xB2", "bicycle bike", 4},
    {"\xE2\x9B\xB5", "sailboat boat", 4},
    {"\xF0\x9F\x8C\x86", "cityscape city dusk", 4},
    // 5 Objects
    {"\xF0\x9F\x92\xBB", "laptop computer", 5},
    {"\xF0\x9F\x93\xB1", "mobile phone", 5},
    {"\xE2\x8C\xA8\xEF\xB8\x8F", "keyboard", 5},
    {"\xF0\x9F\x93\xB7", "camera photo", 5},
    {"\xF0\x9F\x92\xA1", "light bulb idea", 5},
    {"\xF0\x9F\x93\x9A", "books library read", 5},
    {"\xF0\x9F\x93\x9D", "memo note write", 5},
    {"\xF0\x9F\x93\x8C", "pushpin pin", 5},
    {"\xF0\x9F\x93\x8E", "paperclip", 5},
    {"\xF0\x9F\x93\x85", "calendar date", 5},
    {"\xF0\x9F\x93\x88", "chart increasing graph", 5},
    {"\xF0\x9F\x92\xBC", "briefcase work", 5},
    {"\xF0\x9F\x92\xB0", "money bag finance", 5},
    {"\xF0\x9F\x9B\x92", "shopping cart", 5},
    {"\xF0\x9F\x8E\x81", "wrapped gift present", 5},
    {"\xF0\x9F\x94\x91", "key", 5},
    {"\xF0\x9F\x94\xA7", "wrench tool", 5},
    {"\xF0\x9F\x94\xAC", "microscope science", 5},
    {"\xF0\x9F\x92\x8A", "pill medicine health", 5},
    {"\xF0\x9F\x93\xA6", "package box", 5},
    // 6 Symbols
    {"\xE2\x9D\xA4\xEF\xB8\x8F", "red heart love", 6},
    {"\xF0\x9F\x92\x9C", "purple heart", 6},
    {"\xF0\x9F\x92\x99", "blue heart", 6},
    {"\xF0\x9F\x92\x9A", "green heart", 6},
    {"\xF0\x9F\xA7\xA1", "orange heart", 6},
    {"\xE2\xAD\x90", "star", 6},
    {"\xE2\x9C\xA8", "sparkles", 6},
    {"\xF0\x9F\x92\xAF", "hundred points", 6},
    {"\xE2\x9C\x85", "check mark done", 6},
    {"\xE2\x9D\x97", "exclamation mark", 6},
    {"\xE2\x9D\x93", "question mark", 6},
    {"\xF0\x9F\x94\xB4", "red circle", 6},
    {"\xF0\x9F\x9F\xA2", "green circle", 6},
    {"\xF0\x9F\x94\xB5", "blue circle", 6},
    {"\xE2\x99\xBB\xEF\xB8\x8F", "recycling", 6},
    {"\xE2\x9A\x9B\xEF\xB8\x8F", "atom science", 6},
    {"\xE2\x99\xBE\xEF\xB8\x8F", "infinity", 6},
    {"\xF0\x9F\x8E\xB5", "musical note", 6},
    // 7 Flags
    {"\xF0\x9F\x8F\x81", "chequered flag finish", 7},
    {"\xF0\x9F\x9A\xA9", "triangular flag", 7},
    {"\xF0\x9F\x8F\xB3\xEF\xB8\x8F", "white flag", 7},
    {"\xF0\x9F\x8F\xB4", "black flag", 7},
    {"\xF0\x9F\x8F\xB3\xEF\xB8\x8F\xE2\x80\x8D\xF0\x9F\x8C\x88",
     "rainbow flag pride", 7},
    {"\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8", "flag united states", 7},
    {"\xF0\x9F\x87\xA8\xF0\x9F\x87\xA6", "flag canada", 7},
    {"\xF0\x9F\x87\xAC\xF0\x9F\x87\xA7", "flag united kingdom", 7},
    {"\xF0\x9F\x87\xA9\xF0\x9F\x87\xAA", "flag germany", 7},
    {"\xF0\x9F\x87\xAB\xF0\x9F\x87\xB7", "flag france", 7},
    {"\xF0\x9F\x87\xAF\xF0\x9F\x87\xB5", "flag japan", 7},
    {"\xF0\x9F\x87\xAA\xF0\x9F\x87\xB8", "flag spain", 7},
    {"\xF0\x9F\x87\xAE\xF0\x9F\x87\xB9", "flag italy", 7},
    {"\xF0\x9F\x87\xA7\xF0\x9F\x87\xB7", "flag brazil", 7},
    {"\xF0\x9F\x87\xAE\xF0\x9F\x87\xB3", "flag india", 7},
    {"\xF0\x9F\x87\xBA\xF0\x9F\x87\xA6", "flag ukraine", 7},
};

constexpr std::array<const char*, 8> kCategoryNames = {
    "Smileys & People", "Animals & Nature", "Food & Drink", "Activities",
    "Travel & Places",  "Objects",          "Symbols",      "Flags"};
constexpr std::array<const char*, 8> kCategorySymbols = {
    "face.smiling", "leaf", "fork.knife", "sportscourt",
    "car",          "lightbulb", "heart", "flag"};

// NamedSpaceIcons.order (stable picker order).
constexpr const char* kNamedIconOrder[] = {
    "star",       "bookmark",     "heart",        "flag",
    "flash",      "triangle",     "medical",      "notifications",
    "bulb",       "shapes",       "grid",         "apps",
    "layers",     "server",       "albums",       "copy",
    "folder",     "fileTrayFull", "calendar",     "mail",
    "checkbox",   "document",     "book",         "chatBubbleEllipses",
    "people",     "terminal",     "construction", "square",
    "ellipse",    "moon",         "sunny",        "planet",
    "leaf",       "cloud",        "gift",         "restaurant",
    "barbell",    "airplane",     "musicalNote",  "colorPallete",
    "video",      "bandage",      "code",         "baseball",
    "cloudOutline", "bonfire",    "pizza",        "skull",
    "receipt",    "thumbsUp",     "train",        "github",
    "linear",     "figma",        "search",
};

constexpr int kSegmentTop = 8;
constexpr int kSegmentHeight = 24;
constexpr int kSearchTop = 40;
constexpr int kSearchHeight = 24;
constexpr int kCategoryBar = 28;
constexpr int kRemoveBar = 28;
constexpr int kGridInsetTop = 4;

}  // namespace

OpenSpaceIconPickerView::OpenSpaceIconPickerView(
    std::optional<SpaceIcon> current,
    base::RepeatingCallback<void(const std::optional<SpaceIcon>&)> on_pick)
    : on_pick_(std::move(on_pick)), current_(std::move(current)) {
  SetFocusBehavior(FocusBehavior::ALWAYS);
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
  GetViewAccessibility().SetName(u"Choose Icon");
  auto search = std::make_unique<views::Textfield>();
  search->set_controller(this);
  search->SetBorder(views::CreateEmptyBorder(gfx::Insets::TLBR(0, 24, 0, 6)));
  search->SetBackgroundEnabled(false);
  search->SetFontList(space_editor::Font(12, gfx::Font::Weight::NORMAL));
  search->GetViewAccessibility().SetName(u"Search emoji");
  search_ = AddChildView(std::move(search));
  views::FocusRing::Remove(search_);
  // A named icon opens on the Icons page (IconPickerView: folder targets).
  if (current_ && current_->kind != SpaceIconKind::kEmoji) {
    page_ = Page::kIcons;
  }
  Filter();
}

OpenSpaceIconPickerView::~OpenSpaceIconPickerView() {
  if (search_) {
    search_->set_controller(nullptr);
  }
}

void OpenSpaceIconPickerView::SetCurrent(std::optional<SpaceIcon> current) {
  current_ = std::move(current);
  InvalidateLayout();
  SchedulePaint();
}

void OpenSpaceIconPickerView::SetColors(const EditorColors& colors) {
  colors_ = colors;
  search_->SetColor(colors.primary_text);
  SchedulePaint();
}

void OpenSpaceIconPickerView::SelectPage(Page page) {
  if (page_ == page) {
    return;
  }
  page_ = page;
  focused_.reset();
  hovered_.reset();
  scroll_ = 0;
  Filter();
  InvalidateLayout();
  SchedulePaint();
}

int OpenSpaceIconPickerView::Columns() const {
  const int w = std::max(width(), m::kIconPickerWidth);
  return std::max(1, (w - 20 + m::kIconSpacing) /
                         (m::kIconCell + m::kIconSpacing));
}

gfx::Size OpenSpaceIconPickerView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  return gfx::Size(m::kIconPickerWidth, m::kIconPickerHeight);
}

void OpenSpaceIconPickerView::Layout(PassKey) {
  search_->SetVisible(page_ == Page::kEmoji);
  search_->SetBounds(8, kSearchTop, width() - 16, kSearchHeight);
  ScrollTo(scroll_);
}

void OpenSpaceIconPickerView::Filter() {
  visible_.clear();
  if (page_ == Page::kIcons) {
    for (const char* id : kNamedIconOrder) {
      visible_.push_back(
          {SpaceIcon(SpaceIconKind::kNamed, id), base::UTF8ToUTF16(id), 0});
    }
  } else {
    const std::string query = base::ToLowerASCII(
        base::UTF16ToUTF8(search_ ? std::u16string(search_->GetText())
                                  : std::u16string()));
    const std::vector<std::string> words = base::SplitString(
        query, " \t", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
    for (const EmojiEntry& entry : kEmoji) {
      const std::string_view name(entry.name);
      const std::string_view value(entry.value);
      const bool match = std::all_of(
          words.begin(), words.end(), [&](const std::string& word) {
            return name.find(word) != std::string_view::npos ||
                   value.find(word) != std::string_view::npos;
          });
      if (match) {
        // Labels: the first name word capitalized is enough for tooltips.
        visible_.push_back({SpaceIcon(SpaceIconKind::kEmoji, entry.value),
                            base::UTF8ToUTF16(entry.name), entry.category});
      }
    }
  }
  focused_.reset();
  hovered_.reset();
  scroll_ = 0;
  UpdateCategory();
  SchedulePaint();
}

gfx::Rect OpenSpaceIconPickerView::SegmentRect(Page page) const {
  const int half = (width() - 16) / 2;
  return gfx::Rect(page == Page::kEmoji ? 8 : 8 + half, kSegmentTop, half,
                   kSegmentHeight);
}

gfx::Rect OpenSpaceIconPickerView::GridRect() const {
  const int top = page_ == Page::kEmoji ? kSearchTop + kSearchHeight + 6
                                        : kSegmentTop + kSegmentHeight + 8;
  int bottom = height() - (current_ ? kRemoveBar : 0) -
               (page_ == Page::kEmoji ? kCategoryBar : 0);
  return gfx::Rect(0, top, width(), std::max(0, bottom - top));
}

gfx::Rect OpenSpaceIconPickerView::CategoryRect(int index) const {
  const int bottom = height() - (current_ ? kRemoveBar : 0) - kCategoryBar;
  const int start = (width() - (8 * 29 - 2)) / 2;
  return gfx::Rect(start + index * 29, bottom + 3, 27, 24);
}

gfx::Rect OpenSpaceIconPickerView::RemoveRect() const {
  return gfx::Rect(10, height() - kRemoveBar + 3, 120, 22);
}

gfx::Rect OpenSpaceIconPickerView::CellRect(size_t index) const {
  const int columns = Columns();
  const int line = page_ == Page::kIcons ? 5 : 2;
  const int row_width = columns * m::kIconCell + (columns - 1) * m::kIconSpacing;
  const int left = (width() - row_width) / 2;
  const int col = static_cast<int>(index) % columns;
  const int row = static_cast<int>(index) / columns;
  const gfx::Rect grid = GridRect();
  return gfx::Rect(left + col * (m::kIconCell + m::kIconSpacing),
                   grid.y() + kGridInsetTop + row * (m::kIconCell + line) -
                       scroll_,
                   m::kIconCell, m::kIconCell);
}

int OpenSpaceIconPickerView::ContentHeight() const {
  const int columns = Columns();
  const int line = page_ == Page::kIcons ? 5 : 2;
  const int rows =
      (static_cast<int>(visible_.size()) + columns - 1) / columns;
  return kGridInsetTop * 2 + rows * m::kIconCell + std::max(0, rows - 1) * line;
}

std::optional<size_t> OpenSpaceIconPickerView::CellAt(
    const gfx::Point& p) const {
  if (!GridRect().Contains(p)) {
    return std::nullopt;
  }
  for (size_t i = 0; i < visible_.size(); ++i) {
    if (CellRect(i).Contains(p)) {
      return i;
    }
  }
  return std::nullopt;
}

void OpenSpaceIconPickerView::ScrollTo(int offset) {
  const int max_scroll = std::max(0, ContentHeight() - GridRect().height());
  scroll_ = std::clamp(offset, 0, max_scroll);
  UpdateCategory();
  SchedulePaint();
}

void OpenSpaceIconPickerView::ScrollToCell(size_t index) {
  const gfx::Rect grid = GridRect();
  const gfx::Rect cell = CellRect(index);
  if (cell.y() < grid.y()) {
    ScrollTo(scroll_ - (grid.y() - cell.y()) - kGridInsetTop);
  } else if (cell.bottom() > grid.bottom()) {
    ScrollTo(scroll_ + (cell.bottom() - grid.bottom()) + kGridInsetTop);
  }
}

void OpenSpaceIconPickerView::UpdateCategory() {
  if (page_ != Page::kEmoji || visible_.empty()) {
    return;
  }
  const gfx::Rect grid = GridRect();
  for (size_t i = 0; i < visible_.size(); ++i) {
    if (CellRect(i).bottom() > grid.y()) {
      highlighted_category_ = visible_[i].category;
      return;
    }
  }
}

void OpenSpaceIconPickerView::PickIndex(size_t index) {
  if (index < visible_.size() && on_pick_) {
    on_pick_.Run(visible_[index].icon);
  }
}

void OpenSpaceIconPickerView::OnPaint(gfx::Canvas* canvas) {
  using space_editor::DrawText;
  using space_editor::FillRRect;
  using space_editor::Font;
  using space_editor::StrokeRRect;
  // Emoji | Icons segmented control.
  const gfx::Rect segments(8, kSegmentTop, width() - 16, kSegmentHeight);
  FillRRect(canvas, gfx::RectF(segments), 7, colors_.card_fill);
  for (Page page : {Page::kEmoji, Page::kIcons}) {
    gfx::Rect r = SegmentRect(page);
    if (page == page_) {
      gfx::RectF plate(r);
      plate.Inset(2);
      FillRRect(canvas, plate, 5, colors_.selected_plate);
    }
    DrawText(canvas, page == Page::kEmoji ? u"Emoji" : u"Icons",
             Font(12, gfx::Font::Weight::MEDIUM),
             page == page_ ? colors_.primary_text : colors_.secondary_text, r,
             gfx::Canvas::TEXT_ALIGN_CENTER);
  }
  // Search field.
  if (page_ == Page::kEmoji) {
    const gfx::RectF field(search_->bounds());
    FillRRect(canvas, field, 6, colors_.card_fill);
    if (search_->HasFocus()) {
      StrokeRRect(canvas, field, 6, colors_.focus_ring, 1.5f);
    }
    space_editor::DrawEditorGlyph(
        canvas, EditorGlyph::kMagnifier,
        gfx::RectF(field.x() + 6, field.y(), 14, field.height()),
        colors_.glyph, 11);
    if (search_->GetText().empty()) {
      DrawText(canvas, u"Search", Font(12, gfx::Font::Weight::NORMAL),
               colors_.glyph,
               gfx::Rect(search_->x() + 24, search_->y(), search_->width() - 30,
                         search_->height()));
    }
  }
  // Grid.
  const gfx::Rect grid = GridRect();
  canvas->Save();
  canvas->ClipRect(grid);
  for (size_t i = 0; i < visible_.size(); ++i) {
    const gfx::Rect cell = CellRect(i);
    if (cell.bottom() < grid.y() || cell.y() > grid.bottom()) {
      continue;
    }
    const bool selected = current_ && visible_[i].icon == *current_;
    if (selected || hovered_ == i) {
      FillRRect(canvas, gfx::RectF(cell), 6,
                selected ? colors_.selected_plate : colors_.hover_plate);
    }
    if (focused_ == i && HasFocus()) {
      gfx::RectF ring(cell);
      ring.Inset(1);
      StrokeRRect(canvas, ring, 5, colors_.focus_ring, 2);
    }
    space_editor::PaintSpaceIcon(canvas, visible_[i].icon, gfx::RectF(cell), 17,
                                 20, colors_.primary_text, false);
  }
  canvas->Restore();
  if (page_ == Page::kEmoji && visible_.empty()) {
    DrawText(canvas, u"No emoji found", Font(12, gfx::Font::Weight::NORMAL),
             colors_.secondary_text,
             gfx::Rect(10, grid.y() + 35, width() - 20, 22),
             gfx::Canvas::TEXT_ALIGN_CENTER);
  }
  // Category bar.
  if (page_ == Page::kEmoji) {
    const int top = height() - (current_ ? kRemoveBar : 0) - kCategoryBar;
    canvas->FillRect(gfx::Rect(0, top, width(), 1), colors_.separator);
    for (int i = 0; i < 8; ++i) {
      const gfx::Rect r = CategoryRect(i);
      if (hovered_category_ == i) {
        FillRRect(canvas, gfx::RectF(r), 6, colors_.hover_plate);
      }
      const SkColor tint = i == highlighted_category_
                               ? colors_.primary_text
                               : space_editor::WithAlpha(colors_.glyph, 0.7f);
      if (!glyphs::DrawSystemSymbol(canvas,
                                    kCategorySymbols[static_cast<size_t>(i)],
                                    13,
                                    glyphs::SymbolWeight::kRegular,
                                    gfx::RectF(r), tint)) {
        // No SF Symbols: the category's first emoji, dimmed when inactive.
        const EmojiEntry* first = nullptr;
        for (const EmojiEntry& entry : kEmoji) {
          if (entry.category == i) {
            first = &entry;
            break;
          }
        }
        if (first) {
          canvas->SaveLayerAlpha(i == highlighted_category_ ? 255 : 110);
          DrawText(canvas, base::UTF8ToUTF16(first->value),
                   Font(13, gfx::Font::Weight::NORMAL), tint, r,
                   gfx::Canvas::TEXT_ALIGN_CENTER);
          canvas->Restore();
        }
      }
    }
  }
  // Remove icon.
  if (current_) {
    DrawText(canvas, u"Remove icon", Font(11, gfx::Font::Weight::NORMAL),
             remove_hovered_ ? colors_.primary_text : colors_.secondary_text,
             RemoveRect());
  }
}

bool OpenSpaceIconPickerView::OnMousePressed(const ui::MouseEvent& event) {
  if (!event.IsOnlyLeftMouseButton()) {
    return false;
  }
  const gfx::Point p = event.location();
  for (Page page : {Page::kEmoji, Page::kIcons}) {
    if (SegmentRect(page).Contains(p)) {
      SelectPage(page);
      return true;
    }
  }
  if (current_ && RemoveRect().Contains(p)) {
    if (on_pick_) {
      on_pick_.Run(std::nullopt);
    }
    return true;
  }
  if (page_ == Page::kEmoji) {
    for (int i = 0; i < 8; ++i) {
      if (!CategoryRect(i).Contains(p)) {
        continue;
      }
      if (!search_->GetText().empty()) {
        search_->SetText(std::u16string());
        Filter();
      }
      for (size_t j = 0; j < visible_.size(); ++j) {
        if (visible_[j].category == i) {
          ScrollTo(scroll_ + CellRect(j).y() - GridRect().y() - kGridInsetTop);
          break;
        }
      }
      highlighted_category_ = i;
      SchedulePaint();
      return true;
    }
  }
  pressed_ = CellAt(p);
  if (pressed_) {
    RequestFocus();
    focused_ = pressed_;
    SchedulePaint();
    return true;
  }
  return false;
}

void OpenSpaceIconPickerView::OnMouseReleased(const ui::MouseEvent& event) {
  const std::optional<size_t> pressed = pressed_;
  pressed_.reset();
  if (pressed && CellAt(event.location()) == pressed) {
    PickIndex(*pressed);
  }
}

void OpenSpaceIconPickerView::OnMouseMoved(const ui::MouseEvent& event) {
  const gfx::Point p = event.location();
  const std::optional<size_t> hovered = CellAt(p);
  int category = -1;
  if (page_ == Page::kEmoji) {
    for (int i = 0; i < 8; ++i) {
      if (CategoryRect(i).Contains(p)) {
        category = i;
      }
    }
  }
  const bool remove = current_ && RemoveRect().Contains(p);
  if (hovered != hovered_ || category != hovered_category_ ||
      remove != remove_hovered_) {
    hovered_ = hovered;
    hovered_category_ = category;
    remove_hovered_ = remove;
    if (hovered) {
      SetTooltipText(visible_[*hovered].label);
    } else if (category >= 0) {
      SetTooltipText(
          base::UTF8ToUTF16(kCategoryNames[static_cast<size_t>(category)]));
    } else {
      SetTooltipText(std::u16string());
    }
    SchedulePaint();
  }
}

void OpenSpaceIconPickerView::OnMouseExited(const ui::MouseEvent& event) {
  hovered_.reset();
  hovered_category_ = -1;
  remove_hovered_ = false;
  SchedulePaint();
}

bool OpenSpaceIconPickerView::OnMouseWheel(const ui::MouseWheelEvent& event) {
  if (event.y_offset() == 0) {
    return false;
  }
  ScrollTo(scroll_ - event.y_offset());
  return true;
}

bool OpenSpaceIconPickerView::HandleNavigationKey(const ui::KeyEvent& event) {
  const int count = static_cast<int>(visible_.size());
  const int columns = Columns();
  int delta = 0;
  switch (event.key_code()) {
    case ui::VKEY_LEFT:
      delta = -1;
      break;
    case ui::VKEY_RIGHT:
      delta = 1;
      break;
    case ui::VKEY_UP:
      delta = -columns;
      break;
    case ui::VKEY_DOWN:
      delta = columns;
      break;
    case ui::VKEY_RETURN:
      if (focused_) {
        PickIndex(*focused_);
        return true;
      }
      return false;
    default:
      return false;
  }
  if (count == 0) {
    return true;
  }
  const int next =
      focused_ ? std::clamp(static_cast<int>(*focused_) + delta, 0, count - 1)
               : 0;
  focused_ = static_cast<size_t>(next);
  ScrollToCell(*focused_);
  SchedulePaint();
  return true;
}

bool OpenSpaceIconPickerView::OnKeyPressed(const ui::KeyEvent& event) {
  if (HandleNavigationKey(event)) {
    return true;
  }
  // Typing on the emoji page goes to the search field.
  if (page_ == Page::kEmoji && !event.IsControlDown() &&
      !event.IsCommandDown() && !event.IsAltDown()) {
    const char16_t c = event.GetCharacter();
    if (c >= 0x20 && c != 0x7F) {
      search_->RequestFocus();
      search_->InsertOrReplaceText(std::u16string(1, c));
      return true;
    }
  }
  return false;
}

void OpenSpaceIconPickerView::OnFocus() {
  SchedulePaint();
}

void OpenSpaceIconPickerView::OnBlur() {
  SchedulePaint();
}

void OpenSpaceIconPickerView::ContentsChanged(
    views::Textfield* sender,
    const std::u16string& new_contents) {
  if (new_contents.size() > 128) {
    sender->SetText(new_contents.substr(0, 128));
  }
  Filter();
}

bool OpenSpaceIconPickerView::HandleKeyEvent(views::Textfield* sender,
                                             const ui::KeyEvent& key_event) {
  if (key_event.type() != ui::EventType::kKeyPressed) {
    return false;
  }
  switch (key_event.key_code()) {
    case ui::VKEY_DOWN:
    case ui::VKEY_UP:
    case ui::VKEY_RETURN:
      return HandleNavigationKey(key_event);
    default:
      return false;
  }
}

BEGIN_METADATA(OpenSpaceIconPickerView)
END_METADATA

// ===========================================================================
// OpenSpaceThemeEditorView.
// ===========================================================================

OpenSpaceThemeEditorParams::OpenSpaceThemeEditorParams() = default;
OpenSpaceThemeEditorParams::OpenSpaceThemeEditorParams(
    const OpenSpaceThemeEditorParams&) = default;
OpenSpaceThemeEditorParams& OpenSpaceThemeEditorParams::operator=(
    const OpenSpaceThemeEditorParams&) = default;
OpenSpaceThemeEditorParams::~OpenSpaceThemeEditorParams() = default;

OpenSpaceThemeEditorView::Callbacks::Callbacks() = default;
OpenSpaceThemeEditorView::Callbacks::Callbacks(Callbacks&&) = default;
OpenSpaceThemeEditorView::Callbacks&
OpenSpaceThemeEditorView::Callbacks::operator=(Callbacks&&) = default;
OpenSpaceThemeEditorView::Callbacks::~Callbacks() = default;

namespace {

using space_editor::AppearanceModeBar;
using space_editor::ColorPadView;
using space_editor::EditorButton;
using space_editor::NoiseDialView;
using space_editor::PresetStripView;
using space_editor::SineSliderView;
using space_editor::ThemeEditorState;

constexpr gfx::Rect kNameCard{8, 8, 340, 44};
constexpr gfx::Rect kPickerCard{8, 60, 340, 360};
constexpr gfx::Rect kProfileCard{8, 428, 340, 44};
constexpr int kFooterY = m::kThemeHeight;
constexpr int kNewProfileCommand = 10000;

std::u16string Trimmed(std::u16string_view text) {
  return std::u16string(base::TrimWhitespace(text, base::TRIM_ALL));
}

class HandIconPickerView : public OpenSpaceIconPickerView {
 public:
  using OpenSpaceIconPickerView::OpenSpaceIconPickerView;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    if (event.location().x() >= 8 && event.location().x() < width() - 8 &&
        event.location().y() >= 8 && event.location().y() < height() - 4) {
      return ui::Cursor(ui::mojom::CursorType::kHand);
    }
    return OpenSpaceIconPickerView::GetCursor(event);
  }
};

}  // namespace

OpenSpaceThemeEditorView::OpenSpaceThemeEditorView(
    OpenSpaceThemeEditorParams params,
    Callbacks callbacks)
    : params_(std::move(params)),
      callbacks_(std::move(callbacks)),
      state_(space_editor::SeedStyle(params_.theme)),
      colors_(EditorColors::For(true)),
      initial_(params_.theme),
      committed_(params_.theme),
      last_written_(params_.theme) {
  committed_name_ = base::UTF8ToUTF16(params_.title.value_or(std::string()));
  GetViewAccessibility().SetRole(ax::mojom::Role::kDialog);
  GetViewAccessibility().SetName(u"Edit Theme");

  // --- Theme page (Swift ThemeEditorContentView, 356 x 508). ---
  theme_page_ = AddChildView(std::make_unique<views::View>());
  ColorPadView::Callbacks pad;
  pad.on_drag = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v, const gfx::PointF& unit, bool relative) {
        if (!v->state_.gesture_in_progress()) {
          v->EndActiveGesture();
        }
        const bool changed = v->state_.DragKnob(unit, relative);
        v->Run(Kind::kGesture, changed);
      },
      base::Unretained(this));
  pad.on_end_drag = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v) {
        v->state_.EndGesture();
        v->Run(Kind::kGestureEnd, false);
      },
      base::Unretained(this));
  pad.on_begin_keyboard = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v) {
        if (!v->state_.gesture_in_progress()) {
          v->state_.BeginKeyboardGesture();
        }
      },
      base::Unretained(this));
  pad.on_end_keyboard = pad.on_end_drag;
  pad.on_keyboard_hue = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v, double degrees) {
        const bool changed = v->state_.KeyboardHue(degrees);
        v->Run(v->state_.gesture_in_progress() ? Kind::kGesture
                                               : Kind::kDiscrete,
               changed);
      },
      base::Unretained(this));
  pad.on_keyboard_radius = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v, double delta) {
        const bool changed = v->state_.KeyboardRadius(delta);
        v->Run(v->state_.gesture_in_progress() ? Kind::kGesture
                                               : Kind::kDiscrete,
               changed);
      },
      base::Unretained(this));
  pad.on_remove_color = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v) {
        v->EndActiveGesture();
        v->Run(Kind::kDiscrete, v->state_.RemoveColor());
      },
      base::Unretained(this));
  pad_ = theme_page_->AddChildView(std::make_unique<ColorPadView>(std::move(pad)));

  modes_ = theme_page_->AddChildView(std::make_unique<AppearanceModeBar>(
      base::BindRepeating(
          [](OpenSpaceThemeEditorView* v, ThemeAppearance mode) {
            v->EndActiveGesture();
            v->Run(Kind::kDiscrete, v->state_.SetAppearance(mode));
          },
          base::Unretained(this))));
  remove_ = theme_page_->AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(
          [](OpenSpaceThemeEditorView* v) {
            v->EndActiveGesture();
            v->Run(Kind::kDiscrete, v->state_.RemoveColor());
          },
          base::Unretained(this)),
      EditorGlyph::kMinus, 16, u"Remove color"));
  remove_->SetGlyphOffset(1);
  add_ = theme_page_->AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(
          [](OpenSpaceThemeEditorView* v) {
            v->EndActiveGesture();
            v->Run(Kind::kDiscrete, v->state_.AddColor());
          },
          base::Unretained(this)),
      EditorGlyph::kPlus, 16, u"Add color"));

  PresetStripView::Callbacks strip;
  strip.on_select = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v, size_t index) {
        v->EndActiveGesture();
        v->Run(Kind::kDiscrete, v->state_.SelectPreset(index));
      },
      base::Unretained(this));
  strip.on_page = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v, int page) {
        v->state_.set_preset_page(page);
        v->Render();
      },
      base::Unretained(this));
  presets_ = theme_page_->AddChildView(
      std::make_unique<space_editor::HandPresetStripView>(std::move(strip)));

  intensity_ = theme_page_->AddChildView(
      std::make_unique<space_editor::HandSineSliderView>(
      base::BindRepeating(
          [](OpenSpaceThemeEditorView* v, double value, bool final) {
            if (!final && !v->state_.gesture_in_progress()) {
              v->EndActiveGesture();
            }
            const bool changed = v->state_.SetIntensity(value, final);
            v->Run(final ? Kind::kGestureEnd : Kind::kGesture, changed);
          },
          base::Unretained(this))));
  NoiseDialView::Callbacks noise;
  noise.on_change = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v, double value, bool final) {
        if (!final && !v->state_.gesture_in_progress()) {
          v->EndActiveGesture();
        }
        const bool changed = v->state_.SetNoise(value, final);
        v->Run(final ? Kind::kGestureEnd : Kind::kGesture, changed);
      },
      base::Unretained(this));
  noise.on_cycle_texture = base::BindRepeating(
      [](OpenSpaceThemeEditorView* v) {
        v->EndActiveGesture();
        v->Run(Kind::kDiscrete, v->state_.CycleTexture());
      },
      base::Unretained(this));
  noise_ = theme_page_->AddChildView(
      std::make_unique<space_editor::HandNoiseDialView>(std::move(noise)));

  // --- Space page: name, icon, Profile. ---
  space_page_ = AddChildView(std::make_unique<views::View>());
  auto name = std::make_unique<views::Textfield>();
  name->set_controller(this);
  name->SetBorder(views::CreateEmptyBorder(gfx::Insets()));
  name->SetBackgroundEnabled(false);
  name->SetFontList(space_editor::Font(14, gfx::Font::Weight::NORMAL));
  name->SetText(committed_name_);
  name->GetViewAccessibility().SetName(u"Space name");
  name_field_ = space_page_->AddChildView(std::move(name));
  views::FocusRing::Remove(name_field_);
  icon_picker_ = space_page_->AddChildView(
      std::make_unique<HandIconPickerView>(
          params_.icon,
          base::BindRepeating(
              [](OpenSpaceThemeEditorView* v,
                 const std::optional<SpaceIcon>& icon) {
                v->params_.icon = icon;
                v->icon_picker_->SetCurrent(icon);
                if (v->callbacks_.on_change_icon) {
                  v->callbacks_.on_change_icon.Run(v->params_.space_id, icon);
                }
                v->SchedulePaint();
              },
              base::Unretained(this))));
  profile_button_ =
      space_page_->AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(&OpenSpaceThemeEditorView::ShowProfileMenu,
                          base::Unretained(this)),
      u"Profile"));
  profile_button_->SetTrailingChevron(true);
  profile_button_->SetFontSize(13, false);

  // --- Footer (Open addition). ---
  theme_tab_ = AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(&OpenSpaceThemeEditorView::SelectPage,
                          base::Unretained(this), Page::kTheme),
      u"Theme"));
  space_tab_ = AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(&OpenSpaceThemeEditorView::SelectPage,
                          base::Unretained(this), Page::kSpace),
      u"Space"));
  for (EditorButton* tab : {theme_tab_.get(), space_tab_.get()}) {
    tab->GetViewAccessibility().SetRole(ax::mojom::Role::kTab);
  }
  undo_button_ = AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(&OpenSpaceThemeEditorView::Undo,
                          base::Unretained(this)),
      EditorGlyph::kUndo, 14, u"Undo"));
  reset_button_ = AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(&OpenSpaceThemeEditorView::ResetToInitial,
                          base::Unretained(this)),
      u"Reset"));
  reset_button_->SetTooltipText(u"Restore the theme this Space had");
  done_button_ = AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(
          [](OpenSpaceThemeEditorView* v) {
            if (v->GetWidget()) {
              v->GetWidget()->Close();
            }
          },
          base::Unretained(this)),
      u"Done"));
  done_button_->SetFontSize(13, true);

  AddAccelerator(ui::Accelerator(ui::VKEY_Z, ui::EF_PLATFORM_ACCELERATOR));
  AddAccelerator(ui::Accelerator(ui::VKEY_Z,
                                 ui::EF_PLATFORM_ACCELERATOR | ui::EF_SHIFT_DOWN));

  if (!params_.show_identity) {
    params_.open_identity_page = false;
  }
  page_ = params_.open_identity_page ? Page::kSpace : Page::kTheme;
  theme_page_->SetVisible(page_ == Page::kTheme);
  space_page_->SetVisible(page_ == Page::kSpace);
  theme_tab_->SetVisible(params_.show_identity);
  space_tab_->SetVisible(params_.show_identity);
  Render();
}

OpenSpaceThemeEditorView::~OpenSpaceThemeEditorView() {
  if (name_field_) {
    name_field_->set_controller(nullptr);
  }
}

views::View* OpenSpaceThemeEditorView::initial_focus() const {
  return page_ == Page::kSpace ? static_cast<views::View*>(name_field_.get())
                               : static_cast<views::View*>(pad_.get());
}

bool OpenSpaceThemeEditorView::IsDark() const {
  switch (state_.appearance()) {
    case ThemeAppearance::kLight:
      return false;
    case ThemeAppearance::kDark:
      return true;
    case ThemeAppearance::kAutomatic:
      break;
  }
  // Automatic: the panel follows the system appearance.
  return params_.system_appearance == theme::ContentAppearance::kDark;
}

void OpenSpaceThemeEditorView::SetSystemAppearance(
    theme::ContentAppearance appearance) {
  params_.system_appearance = appearance;
  Render();
}

void OpenSpaceThemeEditorView::EndActiveGesture() {
  pad_->FinishKeyboardGesture();
  if (state_.gesture_in_progress()) {
    state_.EndGesture();
    Run(Kind::kGestureEnd, false);
  }
}

void OpenSpaceThemeEditorView::Run(Kind kind, bool changed) {
  if (closed_) {
    return;
  }
  Render();
  switch (kind) {
    case Kind::kGesture:
      if (changed) {
        WritePreview();
      }
      break;
    case Kind::kGestureEnd:
      WritePreview();
      Commit();
      break;
    case Kind::kDiscrete:
      if (changed) {
        WritePreview();
        Commit();
      }
      break;
    case Kind::kNone:
      break;
  }
  undo_button_->SetEnabled(CanUndo());
  reset_button_->SetEnabled(!(committed_ == initial_));
}

void OpenSpaceThemeEditorView::WritePreview() {
  const SpaceTheme theme = space_editor::ThemeFromStyle(state_.style());
  if (theme == last_written_) {
    return;
  }
  last_written_ = theme;
  if (callbacks_.on_live_theme_change) {
    callbacks_.on_live_theme_change.Run(params_.space_id, theme);
  }
}

void OpenSpaceThemeEditorView::Commit() {
  if (last_written_ == committed_) {
    return;
  }
  undo_.push_back(committed_);
  redo_.clear();
  committed_ = last_written_;
  if (callbacks_.on_commit_theme) {
    callbacks_.on_commit_theme.Run(params_.space_id, committed_);
  }
}

void OpenSpaceThemeEditorView::RestoreCommitted(const SpaceTheme& theme) {
  const int page = state_.preset_page();
  state_ = ThemeEditorState(space_editor::SeedStyle(theme));
  state_.set_preset_page(page);
  committed_ = theme;
  last_written_ = theme;
  if (callbacks_.on_live_theme_change) {
    callbacks_.on_live_theme_change.Run(params_.space_id, theme);
  }
  if (callbacks_.on_commit_theme) {
    callbacks_.on_commit_theme.Run(params_.space_id, theme);
  }
  Run(Kind::kNone, false);
}

void OpenSpaceThemeEditorView::Undo() {
  EndActiveGesture();
  if (undo_.empty()) {
    return;
  }
  redo_.push_back(committed_);
  const SpaceTheme theme = undo_.back();
  undo_.pop_back();
  RestoreCommitted(theme);
}

void OpenSpaceThemeEditorView::Redo() {
  EndActiveGesture();
  if (redo_.empty()) {
    return;
  }
  undo_.push_back(committed_);
  const SpaceTheme theme = redo_.back();
  redo_.pop_back();
  RestoreCommitted(theme);
}

void OpenSpaceThemeEditorView::ResetToInitial() {
  EndActiveGesture();
  if (committed_ == initial_) {
    return;
  }
  undo_.push_back(committed_);
  redo_.clear();
  RestoreCommitted(initial_);
}

void OpenSpaceThemeEditorView::SynchronizeTheme(const SpaceTheme& theme) {
  if (closed_ || theme == last_written_) {
    return;
  }
  const int page = state_.preset_page();
  state_ = ThemeEditorState(space_editor::SeedStyle(theme));
  state_.set_preset_page(page);
  committed_ = theme;
  last_written_ = theme;
  // The model moved under the editor: in-editor history no longer applies.
  undo_.clear();
  redo_.clear();
  Run(Kind::kNone, false);
}

void OpenSpaceThemeEditorView::CommitName() {
  if (!name_field_) {
    return;
  }
  const std::u16string trimmed = Trimmed(name_field_->GetText());
  if (trimmed == committed_name_) {
    return;
  }
  committed_name_ = trimmed;
  if (callbacks_.on_rename_space) {
    callbacks_.on_rename_space.Run(params_.space_id,
                                   base::UTF16ToUTF8(trimmed));
  }
}

void OpenSpaceThemeEditorView::FinishEditing() {
  EndActiveGesture();
  if (!(last_written_ == committed_)) {
    Commit();
  }
  CommitName();
}

void OpenSpaceThemeEditorView::NotifyClosed() {
  if (closed_) {
    return;
  }
  FinishEditing();
  closed_ = true;
  if (callbacks_.on_close) {
    std::move(callbacks_.on_close).Run();
  }
}

void OpenSpaceThemeEditorView::SelectPage(Page page) {
  if (!params_.show_identity) {
    page = Page::kTheme;
  }
  if (page == page_) {
    return;
  }
  if (page_ == Page::kSpace) {
    CommitName();
  } else {
    EndActiveGesture();
  }
  page_ = page;
  theme_page_->SetVisible(page_ == Page::kTheme);
  space_page_->SetVisible(page_ == Page::kSpace);
  Render();
  InvalidateLayout();
  if (views::View* focus = initial_focus()) {
    focus->RequestFocus();
  }
}

void OpenSpaceThemeEditorView::Render() {
  colors_ = EditorColors::For(IsDark(), params_.panel_color);
  const std::optional<SpaceStyle>& style = state_.style();
  pad_->Apply(state_, colors_);
  modes_->Apply(state_.appearance(), colors_);
  remove_->SetColors(colors_);
  add_->SetColors(colors_);
  remove_->SetEnabled(style.has_value());
  add_->SetEnabled(style.has_value() && style->color_count < 3);
  presets_->Apply(state_.preset_page(), colors_);
  intensity_->Apply(style ? style->intensity_factor : 0.8, style.has_value(),
                    colors_);
  noise_->Apply(style ? style->noise_factor : 0,
                style ? style->texture : ThemeTexture::kGrain,
                style.has_value(), colors_);
  icon_picker_->SetColors(colors_);
  name_field_->SetColor(colors_.primary_text);
  profile_button_->SetColors(colors_);
  const SpaceProfileChoice* profile = nullptr;
  for (const SpaceProfileChoice& choice : params_.profiles) {
    if (choice.id == params_.profile_id) {
      profile = &choice;
    }
  }
  profile_button_->SetLabel(profile ? profile->name : u"Choose Profile");
  profile_button_->SetEnabled(!params_.profiles.empty() &&
                              static_cast<bool>(callbacks_.on_change_profile));
  for (EditorButton* button :
       {theme_tab_.get(), space_tab_.get(), undo_button_.get(),
        reset_button_.get(), done_button_.get()}) {
    button->SetColors(colors_);
  }
  theme_tab_->SetSelected(page_ == Page::kTheme);
  space_tab_->SetSelected(page_ == Page::kSpace);
  done_button_->SetSelected(true);
  undo_button_->SetEnabled(CanUndo());
  reset_button_->SetEnabled(!(committed_ == initial_));
  space_editor::UpdateBubbleBackground(this, colors_.panel);
  SchedulePaint();
}

gfx::Size OpenSpaceThemeEditorView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  return gfx::Size(m::kContentWidth, m::kPanelHeight);
}

void OpenSpaceThemeEditorView::Layout(PassKey) {
  theme_page_->SetBounds(0, 0, m::kContentWidth, m::kThemeHeight);
  space_page_->SetBounds(0, 0, m::kContentWidth, m::kThemeHeight);
  pad_->SetBoundsRect(m::kPad);
  modes_->SetBoundsRect(m::kModeBar);
  remove_->SetBoundsRect(m::kRemove);
  add_->SetBoundsRect(m::kAdd);
  presets_->SetBoundsRect(m::kPresetStrip);
  intensity_->SetBoundsRect(m::kIntensity);
  noise_->SetBoundsRect(m::kNoise);

  name_field_->SetBounds(kNameCard.x() + 44, kNameCard.y() + 11,
                         kNameCard.width() - 52, 22);
  icon_picker_->SetBoundsRect(kPickerCard);
  const gfx::FontList& font = space_editor::Font(13, gfx::Font::Weight::MEDIUM);
  const SpaceProfileChoice* profile = nullptr;
  for (const SpaceProfileChoice& choice : params_.profiles) {
    if (choice.id == params_.profile_id) {
      profile = &choice;
    }
  }
  const int text = gfx::Canvas::GetStringWidth(
      profile ? profile->name : u"Choose Profile", font);
  const int w = std::min(kProfileCard.width() - 96, text + 36);
  profile_button_->SetBounds(kProfileCard.right() - 8 - w,
                             kProfileCard.y() + 8, w, 28);

  const int y = kFooterY + 6;
  theme_tab_->SetBounds(8, y, 72, 32);
  space_tab_->SetBounds(84, y, 72, 32);
  undo_button_->SetBounds(196, y, 32, 32);
  reset_button_->SetBounds(232, y, 56, 32);
  done_button_->SetBounds(292, y, 56, 32);
}

void OpenSpaceThemeEditorView::OnPaint(gfx::Canvas* canvas) {
  using space_editor::DrawText;
  using space_editor::FillRRect;
  canvas->FillRect(gfx::Rect(0, kFooterY, width(), 1), colors_.separator);
  if (page_ != Page::kSpace) {
    return;
  }
  FillRRect(canvas, gfx::RectF(kNameCard), 10, colors_.card_fill);
  space_editor::PaintSpaceIcon(
      canvas, params_.icon,
      gfx::RectF(kNameCard.x() + 6, kNameCard.y() + 6, 32, 32), 17, 20,
      params_.icon ? colors_.primary_text : colors_.secondary_text, true);
  if (name_field_->GetText().empty()) {
    DrawText(canvas, u"Space name",
             space_editor::Font(14, gfx::Font::Weight::NORMAL), colors_.glyph,
             name_field_->bounds());
  }
  FillRRect(canvas, gfx::RectF(kPickerCard), 10, colors_.card_fill);
  FillRRect(canvas, gfx::RectF(kProfileCard), 10, colors_.card_fill);
  DrawText(canvas, u"Profile",
           space_editor::Font(13, gfx::Font::Weight::MEDIUM),
           colors_.primary_text,
           gfx::Rect(kProfileCard.x() + 12, kProfileCard.y(), 80,
                     kProfileCard.height()));
}

void OpenSpaceThemeEditorView::OnThemeChanged() {
  views::View::OnThemeChanged();
  // Textfield resets its color from the color provider.
  name_field_->SetColor(colors_.primary_text);
  icon_picker_->SetColors(colors_);
}

bool OpenSpaceThemeEditorView::AcceleratorPressed(
    const ui::Accelerator& accelerator) {
  // Text fields keep their own typing undo.
  if ((name_field_ && name_field_->HasFocus()) || page_ != Page::kTheme) {
    return false;
  }
  if (accelerator.IsShiftDown()) {
    Redo();
  } else {
    Undo();
  }
  return true;
}

void OpenSpaceThemeEditorView::ContentsChanged(
    views::Textfield* sender,
    const std::u16string& new_contents) {
  SchedulePaint();
}

bool OpenSpaceThemeEditorView::HandleKeyEvent(views::Textfield* sender,
                                              const ui::KeyEvent& key_event) {
  if (key_event.type() == ui::EventType::kKeyPressed &&
      key_event.key_code() == ui::VKEY_RETURN) {
    CommitName();
    return true;
  }
  return false;
}

void OpenSpaceThemeEditorView::ShowProfileMenu() {
  if (params_.profiles.empty() || !GetWidget() ||
      (profile_menu_runner_ && profile_menu_runner_->IsRunning())) {
    return;
  }
  profile_menu_model_ = std::make_unique<ui::SimpleMenuModel>(this);
  for (size_t i = 0; i < params_.profiles.size(); ++i) {
    profile_menu_model_->AddCheckItem(static_cast<int>(i),
                                      params_.profiles[i].name);
  }
  profile_menu_runner_ = std::make_unique<views::MenuRunner>(
      profile_menu_model_.get(), views::MenuRunner::NO_FLAGS);
  profile_menu_runner_->RunMenuAt(
      GetWidget(), nullptr, profile_button_->GetBoundsInScreen(),
      views::MenuAnchorPosition::kTopLeft, ui::mojom::MenuSourceType::kMouse);
}

void OpenSpaceThemeEditorView::ExecuteCommand(int command_id,
                                              int event_flags) {
  if (command_id < 0 ||
      static_cast<size_t>(command_id) >= params_.profiles.size()) {
    return;
  }
  const ProfileID& id = params_.profiles[static_cast<size_t>(command_id)].id;
  if (id == params_.profile_id) {
    return;
  }
  params_.profile_id = id;
  if (callbacks_.on_change_profile) {
    callbacks_.on_change_profile.Run(params_.space_id, id);
  }
  Render();
  InvalidateLayout();
}

bool OpenSpaceThemeEditorView::IsCommandIdChecked(int command_id) const {
  return command_id >= 0 &&
         static_cast<size_t>(command_id) < params_.profiles.size() &&
         params_.profiles[static_cast<size_t>(command_id)].id ==
             params_.profile_id;
}

BEGIN_METADATA(OpenSpaceThemeEditorView)
END_METADATA

// ===========================================================================
// OpenSpaceCreationView.
// ===========================================================================

CreateSpaceRequest::CreateSpaceRequest() = default;
CreateSpaceRequest::CreateSpaceRequest(const CreateSpaceRequest&) = default;
CreateSpaceRequest& CreateSpaceRequest::operator=(const CreateSpaceRequest&) =
    default;
CreateSpaceRequest::~CreateSpaceRequest() = default;

OpenSpaceCreationParams::OpenSpaceCreationParams() = default;
OpenSpaceCreationParams::OpenSpaceCreationParams(
    const OpenSpaceCreationParams&) = default;
OpenSpaceCreationParams& OpenSpaceCreationParams::operator=(
    const OpenSpaceCreationParams&) = default;
OpenSpaceCreationParams::~OpenSpaceCreationParams() = default;

OpenSpaceCreationView::Callbacks::Callbacks() = default;
OpenSpaceCreationView::Callbacks::Callbacks(Callbacks&&) = default;
OpenSpaceCreationView::Callbacks& OpenSpaceCreationView::Callbacks::operator=(
    Callbacks&&) = default;
OpenSpaceCreationView::Callbacks::~Callbacks() = default;

namespace {

// SpaceCreationView (full width class) geometry, plus the preview pill.
constexpr int kCreationInset = 8;
constexpr int kHero = 80;
constexpr int kHeroTop = 16;
constexpr int kTitleTop = kHeroTop + kHero + 14;  // 110
constexpr int kSubtitleTop = kTitleTop + 32;       // 142
constexpr int kSubtitleLine = 18;
constexpr int kPillTop = kSubtitleTop + 2 * kSubtitleLine + 12;  // 190
constexpr int kPillHeight = 28;
constexpr int kCreationCardsTop = kPillTop + kPillHeight + 16;  // 234
constexpr int kCardGap = 8;
constexpr int kNameCardHeight = 44;
constexpr int kThemeCardHeight = 64;
constexpr int kPickerHeight = 300;

}  // namespace

OpenSpaceCreationView::OpenSpaceCreationView(OpenSpaceCreationParams params,
                                             Callbacks callbacks)
    : params_(std::move(params)),
      callbacks_(std::move(callbacks)),
      draft_(params_.initial_style),
      icon_(params_.initial_icon),
      painter_(std::make_unique<theme::ThemePainter>()) {
  selected_profile_ = params_.selected_profile_id;
  if (selected_profile_.empty() && !params_.profiles.empty()) {
    selected_profile_ = params_.profiles.front().id;
  }
  GetViewAccessibility().SetRole(ax::mojom::Role::kDialog);
  GetViewAccessibility().SetName(u"Create a Space");

  auto make_field = [this](std::u16string_view accessible_name) {
    auto field = std::make_unique<views::Textfield>();
    field->set_controller(this);
    field->SetBorder(views::CreateEmptyBorder(gfx::Insets()));
    field->SetBackgroundEnabled(false);
    field->SetFontList(space_editor::Font(14, gfx::Font::Weight::NORMAL));
    field->GetViewAccessibility().SetName(std::u16string(accessible_name));
    return field;
  };
  auto name = make_field(u"Space name");
  name->SetText(params_.initial_title);
  name_field_ = AddChildView(std::move(name));
  views::FocusRing::Remove(name_field_);

  icon_button_ = AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(&OpenSpaceCreationView::ToggleIconPicker,
                          base::Unretained(this)),
      std::u16string()));
  icon_button_->GetViewAccessibility().SetName(u"Change Space Icon");
  icon_button_->SetTooltipText(u"Change Space Icon");

  icon_picker_ = AddChildView(std::make_unique<HandIconPickerView>(
      icon_, base::BindRepeating(
                 [](OpenSpaceCreationView* v,
                    const std::optional<SpaceIcon>& icon) {
                   v->icon_ = icon;
                   v->icon_picker_->SetCurrent(icon);
                   v->ToggleIconPicker();
                   v->name_field_->RequestFocus();
                 },
                 base::Unretained(this))));
  icon_picker_->SetVisible(false);

  PresetStripView::Callbacks strip;
  strip.on_select = base::BindRepeating(
      [](OpenSpaceCreationView* v, size_t index) {
        const auto& presets = space_editor::ThemePresets();
        if (index >= presets.size()) {
          return;
        }
        const SpaceStyle& preset = presets[index].style;
        // Picking the selected swatch again returns to the default theme.
        if (v->draft_ && v->draft_->key_color == preset.key_color &&
            v->draft_->color_count == preset.color_count &&
            v->draft_->wheel == preset.wheel) {
          v->SetDraftStyle(std::nullopt);
          return;
        }
        ThemeEditorState state(v->draft_);
        state.SelectPreset(index);
        v->SetDraftStyle(state.style());
      },
      base::Unretained(this));
  strip.on_page = base::BindRepeating(
      [](OpenSpaceCreationView* v, int page) {
        v->swatches_->Apply(page, v->colors_);
        v->SchedulePaint();
      },
      base::Unretained(this));
  swatches_ = AddChildView(
      std::make_unique<space_editor::HandPresetStripView>(std::move(strip)));
  swatches_->SetCompact(true);

  profile_button_ =
      AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(&OpenSpaceCreationView::ShowProfileMenu,
                          base::Unretained(this)),
      u"Profile"));
  profile_button_->SetTrailingChevron(true);
  profile_button_->SetFontSize(13, false);
  profile_button_->SetTooltipText(
      u"You can use a Profile to give this Space its own logins, history, "
      u"and browsing data.");
  profile_name_field_ = AddChildView(make_field(u"Profile name"));
  views::FocusRing::Remove(profile_name_field_);
  profile_name_field_->SetVisible(false);

  create_button_ =
      AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(&OpenSpaceCreationView::Submit,
                          base::Unretained(this)),
      u"Create Space"));
  create_button_->SetFontSize(13, true);
  cancel_button_ =
      AddChildView(std::make_unique<space_editor::HandEditorButton>(
      base::BindRepeating(&OpenSpaceCreationView::Cancel,
                          base::Unretained(this)),
      u"Cancel"));

  // Open the swatch strip on the page of the initial draft's preset.
  for (size_t i = 0; draft_ && i < space_editor::ThemePresets().size(); ++i) {
    const SpaceStyle& preset = space_editor::ThemePresets()[i].style;
    if (draft_->key_color == preset.key_color &&
        draft_->color_count == preset.color_count) {
      swatches_->Apply(static_cast<int>(i) / space_editor::kSwatchesPerPage,
                       colors_);
      break;
    }
  }
  ApplyColors();
  RefreshSubmitState();
}

OpenSpaceCreationView::~OpenSpaceCreationView() {
  for (views::Textfield* field : {name_field_.get(), profile_name_field_.get()}) {
    if (field) {
      field->set_controller(nullptr);
    }
  }
}

bool OpenSpaceCreationView::ShowsProfileCard() const {
  return params_.profiles.size() > 1 || params_.allow_new_profile;
}

int OpenSpaceCreationView::CardsTop() const {
  return kCreationCardsTop;
}

int OpenSpaceCreationView::ThemeCardTop() const {
  return CardsTop() + kNameCardHeight + kCardGap +
         (picker_open_ ? kPickerHeight + kCardGap : 0);
}

int OpenSpaceCreationView::ProfileCardTop() const {
  return ThemeCardTop() + kThemeCardHeight + kCardGap;
}

int OpenSpaceCreationView::ProfileCardHeight() const {
  if (!creating_profile_) {
    return 44;
  }
  return profile_issue_ ? 112 : 82;
}

int OpenSpaceCreationView::ContentHeight() const {
  const int end = ShowsProfileCard() ? ProfileCardTop() + ProfileCardHeight()
                                     : ThemeCardTop() + kThemeCardHeight;
  return end + 12 + 64 + 12;
}

gfx::Rect OpenSpaceCreationView::PageDotRect(int page) const {
  const int right = width() - kCreationInset - 10;
  return gfx::Rect(right - (space_editor::kPresetPageCount - page) * 12,
                   ThemeCardTop() + 4, 12, 22);
}

SkColor OpenSpaceCreationView::body_color() const {
  const std::vector<theme::Rgba> samples = style_.FieldSamples();
  if (samples.size() > 4) {
    return theme::ToSkColor(samples[4]);
  }
  return mode_ == theme::ContentAppearance::kDark
             ? SkColorSetRGB(0x2B, 0x2B, 0x2E)
             : SkColorSetRGB(0xF4, 0xF4, 0xF5);
}

void OpenSpaceCreationView::SetDraftStyle(std::optional<SpaceStyle> style) {
  draft_ = std::move(style);
  ApplyColors();
  if (callbacks_.on_draft_theme) {
    callbacks_.on_draft_theme.Run(space_editor::ThemeFromStyle(draft_));
  }
}

void OpenSpaceCreationView::ApplyColors() {
  const SpaceTheme theme = space_editor::ThemeFromStyle(draft_);
  style_ = theme::ThemeStyle::FromSpaceTheme(theme, params_.system_appearance);
  mode_ = style_.ResolvedAppearance(params_.system_appearance);
  title_color_ = theme::ToSkColor(style_.TitleColor(mode_));
  const theme::SemanticPalette* palette = style_.PaletteFor(mode_);
  secondary_color_ = palette ? theme::ToSkColor(palette->subtitle)
                             : space_editor::WithAlpha(title_color_, 0.65f);
  const theme::SidebarRoles roles = theme::RolesFor(style_, mode_);
  card_fill_ = theme::ToSkColor(roles.field_fill);
  focus_fill_ = palette ? theme::ToSkColor(palette->focus) : card_fill_;
  painter_->SetStyle(style_);

  colors_ = EditorColors::For(mode_ == theme::ContentAppearance::kDark);
  colors_.primary_text = title_color_;
  colors_.secondary_text = secondary_color_;
  colors_.glyph = space_editor::WithAlpha(title_color_, 0.6f);
  colors_.glyph_selected = colors_.glyph;
  colors_.card_fill = card_fill_;
  colors_.panel = body_color();

  name_field_->SetColor(title_color_);
  profile_name_field_->SetColor(title_color_);
  icon_button_->SetColors(colors_);
  icon_picker_->SetColors(colors_);
  swatches_->Apply(swatches_->page(), colors_);
  std::optional<size_t> selected;
  for (size_t i = 0; draft_ && i < space_editor::ThemePresets().size(); ++i) {
    const SpaceStyle& preset = space_editor::ThemePresets()[i].style;
    if (draft_->key_color == preset.key_color &&
        draft_->color_count == preset.color_count &&
        draft_->wheel == preset.wheel) {
      selected = i;
      break;
    }
  }
  swatches_->SetSelected(selected);
  profile_button_->SetColors(colors_);
  const SpaceProfileChoice* profile = SelectedProfile();
  profile_button_->SetLabel(creating_profile_ ? u"New Profile…"
                            : profile         ? profile->name
                                              : u"Default");
  profile_button_->SetEnabled(params_.profiles.size() > 1 ||
                              params_.allow_new_profile);
  create_button_->SetColors(colors_);
  create_button_->SetFilled(focus_fill_, title_color_);
  cancel_button_->SetColors(colors_);
  cancel_button_->SetTextColor(secondary_color_);
  space_editor::UpdateBubbleBackground(this, body_color());
  SchedulePaint();
}

const SpaceProfileChoice* OpenSpaceCreationView::SelectedProfile() const {
  for (const SpaceProfileChoice& choice : params_.profiles) {
    if (choice.id == selected_profile_) {
      return &choice;
    }
  }
  return nullptr;
}

bool OpenSpaceCreationView::CanSubmit() const {
  // Create Space stays disabled while the name is empty (whitespace counts as
  // empty: the model trims titles).
  if (finished_ || Trimmed(name_field_->GetText()).empty()) {
    return false;
  }
  return creating_profile_ || SelectedProfile() || params_.profiles.empty();
}

void OpenSpaceCreationView::RefreshSubmitState() {
  create_button_->SetEnabled(CanSubmit());
}

void OpenSpaceCreationView::Submit() {
  if (!CanSubmit()) {
    return;
  }
  CreateSpaceRequest request;
  request.title = base::UTF16ToUTF8(Trimmed(name_field_->GetText()));
  request.icon = icon_;
  request.theme = space_editor::ThemeFromStyle(draft_);
  if (creating_profile_) {
    const std::u16string profile_name =
        Trimmed(profile_name_field_->GetText());
    if (profile_name.empty()) {
      profile_issue_ = u"Enter a name for the new Profile.";
      InvalidateLayout();
      PreferredSizeChanged();
      SchedulePaint();
      profile_name_field_->RequestFocus();
      return;
    }
    request.new_profile_name = base::UTF16ToUTF8(profile_name);
  } else {
    request.profile_id = selected_profile_;
  }
  finished_ = true;
  // Close first (asynchronous): the callback may release the popover owner.
  if (GetWidget()) {
    GetWidget()->Close();
  }
  if (callbacks_.on_create) {
    std::move(callbacks_.on_create).Run(request);
  }
}

void OpenSpaceCreationView::Cancel() {
  if (finished_) {
    return;
  }
  finished_ = true;
  if (GetWidget()) {
    GetWidget()->Close();
  }
  if (callbacks_.on_cancel) {
    std::move(callbacks_.on_cancel).Run();
  }
}

void OpenSpaceCreationView::NotifyClosed() {
  if (finished_) {
    return;
  }
  finished_ = true;
  if (callbacks_.on_cancel) {
    std::move(callbacks_.on_cancel).Run();
  }
}

void OpenSpaceCreationView::ToggleIconPicker() {
  picker_open_ = !picker_open_;
  icon_picker_->SetVisible(picker_open_);
  if (picker_open_) {
    icon_picker_->RequestFocus();
  }
  InvalidateLayout();
  PreferredSizeChanged();
  SchedulePaint();
}

gfx::Size OpenSpaceCreationView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  return gfx::Size(m::kCreationWidth, ContentHeight());
}

void OpenSpaceCreationView::Layout(PassKey) {
  const int cw = width() - 2 * kCreationInset;
  const int name_top = CardsTop();
  icon_button_->SetBounds(kCreationInset + 6, name_top + 6, 32, 32);
  name_field_->SetBounds(kCreationInset + 44, name_top + 11, cw - 52, 22);
  icon_picker_->SetBounds(kCreationInset, name_top + kNameCardHeight + kCardGap,
                          cw, kPickerHeight);
  const int theme_top = ThemeCardTop();
  swatches_->SetBounds(kCreationInset + 4, theme_top + 28, cw - 8, 32);

  const bool shows_profile = ShowsProfileCard();
  profile_button_->SetVisible(shows_profile);
  profile_name_field_->SetVisible(shows_profile && creating_profile_);
  if (shows_profile) {
    const int top = ProfileCardTop();
    const SpaceProfileChoice* profile = SelectedProfile();
    const std::u16string label = creating_profile_ ? u"New Profile…"
                                 : profile         ? profile->name
                                                   : u"Default";
    const int text = gfx::Canvas::GetStringWidth(
        label, space_editor::Font(13, gfx::Font::Weight::MEDIUM));
    const int w = std::min(cw - 80, text + 36);
    profile_button_->SetBounds(kCreationInset + cw - 8 - w, top + 8, w, 28);
    profile_name_field_->SetBounds(kCreationInset + 12, top + 48, cw - 24, 22);
  }
  const int end = shows_profile ? ProfileCardTop() + ProfileCardHeight()
                                : theme_top + kThemeCardHeight;
  create_button_->SetBounds(kCreationInset, end + 12, cw, 32);
  cancel_button_->SetBounds(kCreationInset, end + 50, cw, 26);
}

void OpenSpaceCreationView::PaintHeader(gfx::Canvas* canvas,
                                        const gfx::Rect& rect) {
  const gfx::PointF c = gfx::RectF(rect).CenterPoint();
  // Two tilted tiles behind the icon tile (Swift: -16 deg at (-15, -3) and
  // 20 deg at (18, -6) in y-up coordinates; mirrored here for y-down).
  struct Tile {
    float degrees, dx, dy;
  };
  for (const Tile& tile : {Tile{16, -15, 3}, Tile{-20, 18, 6}}) {
    canvas->Save();
    canvas->sk_canvas()->translate(c.x() + tile.dx, c.y() + tile.dy);
    canvas->sk_canvas()->rotate(tile.degrees);
    space_editor::FillRRect(canvas, gfx::RectF(-30, -30, 60, 60), 15,
                            card_fill_);
    canvas->Restore();
  }
  space_editor::FillRRect(canvas, gfx::RectF(rect), 20, card_fill_);
  const gfx::RectF icon(c.x() - 18, c.y() - 18, 36, 36);
  space_editor::PaintSpaceIcon(canvas, icon_, icon, 32, 36,
                               icon_ ? title_color_ : secondary_color_, true);
}

void OpenSpaceCreationView::PaintPill(gfx::Canvas* canvas,
                                      const gfx::Rect& rect) {
  const std::u16string name = Trimmed(name_field_->GetText());
  const std::u16string text = name.empty() ? u"New Space" : name;
  const gfx::FontList& font = space_editor::Font(13, gfx::Font::Weight::MEDIUM);
  const int text_width = gfx::Canvas::GetStringWidth(text, font);
  const int w = std::min(rect.width(), 12 + 16 + 6 + text_width + 14);
  const gfx::Rect pill(rect.x() + (rect.width() - w) / 2, rect.y(), w,
                       rect.height());
  space_editor::FillRRect(canvas, gfx::RectF(pill), rect.height() / 2.0f,
                          card_fill_);
  space_editor::PaintSpaceIcon(
      canvas, icon_,
      gfx::RectF(pill.x() + 12, pill.y() + (pill.height() - 16) / 2.0f, 16, 16),
      13, 14, icon_ ? title_color_ : secondary_color_, false);
  space_editor::DrawText(
      canvas, text, font, name.empty() ? secondary_color_ : title_color_,
      gfx::Rect(pill.x() + 34, pill.y(), pill.width() - 46, pill.height()));
}

void OpenSpaceCreationView::OnPaint(gfx::Canvas* canvas) {
  using space_editor::DrawText;
  using space_editor::FillRRect;
  using space_editor::Font;
  const gfx::Rect bounds = GetLocalBounds();
  const int cw = width() - 2 * kCreationInset;
  canvas->Save();
  canvas->ClipPath(SkPath::RRect(gfx::RectFToSkRect(gfx::RectF(bounds)),
                                 m::kCreationCornerRadius,
                                 m::kCreationCornerRadius),
                   true);
  // The draft theme's field is the card body: a live tint preview.
  painter_->Paint(canvas, bounds, gfx::RectF(bounds));

  PaintHeader(canvas, gfx::Rect((width() - kHero) / 2, kHeroTop, kHero, kHero));
  DrawText(canvas, u"Create a Space", Font(17, gfx::Font::Weight::SEMIBOLD),
           title_color_, gfx::Rect(kCreationInset, kTitleTop, cw, 24),
           gfx::Canvas::TEXT_ALIGN_CENTER);
  DrawText(canvas, u"Separate your tabs for life,",
           Font(13, gfx::Font::Weight::NORMAL), secondary_color_,
           gfx::Rect(kCreationInset, kSubtitleTop, cw, kSubtitleLine),
           gfx::Canvas::TEXT_ALIGN_CENTER);
  DrawText(canvas, u"work, projects, and more.",
           Font(13, gfx::Font::Weight::NORMAL), secondary_color_,
           gfx::Rect(kCreationInset, kSubtitleTop + kSubtitleLine, cw,
                     kSubtitleLine),
           gfx::Canvas::TEXT_ALIGN_CENTER);
  PaintPill(canvas, gfx::Rect(kCreationInset, kPillTop, cw, kPillHeight));

  // Name card.
  const int name_top = CardsTop();
  FillRRect(canvas, gfx::RectF(kCreationInset, name_top, cw, kNameCardHeight),
            10, card_fill_);
  space_editor::PaintSpaceIcon(canvas, icon_,
                               gfx::RectF(icon_button_->bounds()), 16, 18,
                               icon_ ? title_color_ : secondary_color_, true);
  if (name_field_->GetText().empty()) {
    DrawText(canvas, u"Space name", Font(14, gfx::Font::Weight::NORMAL),
             secondary_color_, name_field_->bounds());
  }
  if (picker_open_) {
    FillRRect(canvas, gfx::RectF(icon_picker_->bounds()), 10, card_fill_);
  }

  // Theme card: label, page dots, swatches.
  const int theme_top = ThemeCardTop();
  FillRRect(canvas,
            gfx::RectF(kCreationInset, theme_top, cw, kThemeCardHeight), 10,
            card_fill_);
  DrawText(canvas, u"Theme", Font(13, gfx::Font::Weight::MEDIUM), title_color_,
           gfx::Rect(kCreationInset + 12, theme_top + 4, 120, 22));
  for (int page = 0; page < space_editor::kPresetPageCount; ++page) {
    const gfx::Rect dot = PageDotRect(page);
    space_editor::FillCircle(
        canvas, gfx::RectF(dot).CenterPoint(), 3,
        page == swatches_->page() ? title_color_
                                  : space_editor::WithAlpha(title_color_, 0.3f));
  }

  // Profile card.
  if (ShowsProfileCard()) {
    const int top = ProfileCardTop();
    FillRRect(canvas,
              gfx::RectF(kCreationInset, top, cw, ProfileCardHeight()), 10,
              card_fill_);
    DrawText(canvas, u"Profile", Font(13, gfx::Font::Weight::MEDIUM),
             title_color_, gfx::Rect(kCreationInset + 12, top, 80, 44));
    if (creating_profile_) {
      canvas->FillRect(gfx::Rect(kCreationInset + 12, top + 44, cw - 24, 1),
                       space_editor::WithAlpha(title_color_, 0.12f));
      if (profile_name_field_->GetText().empty()) {
        DrawText(canvas, u"Profile name", Font(14, gfx::Font::Weight::NORMAL),
                 secondary_color_, profile_name_field_->bounds());
      }
      if (profile_issue_) {
        DrawText(canvas, *profile_issue_, Font(11, gfx::Font::Weight::NORMAL),
                 SkColorSetRGB(0xFF, 0x45, 0x3A),
                 gfx::Rect(kCreationInset + 12, top + 76, cw - 24, 30),
                 gfx::Canvas::TEXT_ALIGN_LEFT | gfx::Canvas::MULTI_LINE);
      }
    }
  }
  canvas->Restore();
}

void OpenSpaceCreationView::OnThemeChanged() {
  views::View::OnThemeChanged();
  ApplyColors();
}

bool OpenSpaceCreationView::OnMousePressed(const ui::MouseEvent& event) {
  if (!event.IsOnlyLeftMouseButton()) {
    return false;
  }
  for (int page = 0; page < space_editor::kPresetPageCount; ++page) {
    if (PageDotRect(page).Contains(event.location())) {
      swatches_->Apply(page, colors_);
      SchedulePaint();
      return true;
    }
  }
  return false;
}

void OpenSpaceCreationView::ContentsChanged(
    views::Textfield* sender,
    const std::u16string& new_contents) {
  if (sender == profile_name_field_ && profile_issue_) {
    profile_issue_.reset();
    InvalidateLayout();
    PreferredSizeChanged();
  }
  RefreshSubmitState();
  SchedulePaint();
}

bool OpenSpaceCreationView::HandleKeyEvent(views::Textfield* sender,
                                           const ui::KeyEvent& key_event) {
  if (key_event.type() != ui::EventType::kKeyPressed) {
    return false;
  }
  if (key_event.key_code() == ui::VKEY_RETURN) {
    Submit();
    return true;
  }
  if (key_event.key_code() == ui::VKEY_ESCAPE) {
    Cancel();
    return true;
  }
  return false;
}

void OpenSpaceCreationView::ShowProfileMenu() {
  if (!GetWidget() ||
      (profile_menu_runner_ && profile_menu_runner_->IsRunning())) {
    return;
  }
  profile_menu_model_ = std::make_unique<ui::SimpleMenuModel>(this);
  for (size_t i = 0; i < params_.profiles.size(); ++i) {
    profile_menu_model_->AddCheckItem(static_cast<int>(i),
                                      params_.profiles[i].name);
  }
  if (params_.allow_new_profile) {
    if (!params_.profiles.empty()) {
      profile_menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
    }
    profile_menu_model_->AddItem(kNewProfileCommand, u"New Profile…");
  }
  profile_menu_runner_ = std::make_unique<views::MenuRunner>(
      profile_menu_model_.get(), views::MenuRunner::NO_FLAGS);
  profile_menu_runner_->RunMenuAt(
      GetWidget(), nullptr, profile_button_->GetBoundsInScreen(),
      views::MenuAnchorPosition::kTopLeft, ui::mojom::MenuSourceType::kMouse);
}

void OpenSpaceCreationView::ExecuteCommand(int command_id, int event_flags) {
  if (command_id == kNewProfileCommand) {
    creating_profile_ = true;
    profile_issue_.reset();
  } else if (command_id >= 0 &&
             static_cast<size_t>(command_id) < params_.profiles.size()) {
    creating_profile_ = false;
    profile_issue_.reset();
    selected_profile_ = params_.profiles[static_cast<size_t>(command_id)].id;
  } else {
    return;
  }
  ApplyColors();
  RefreshSubmitState();
  InvalidateLayout();
  PreferredSizeChanged();
  if (creating_profile_) {
    profile_name_field_->SetVisible(true);
    profile_name_field_->RequestFocus();
  }
}

bool OpenSpaceCreationView::IsCommandIdChecked(int command_id) const {
  return !creating_profile_ && command_id >= 0 &&
         static_cast<size_t>(command_id) < params_.profiles.size() &&
         params_.profiles[static_cast<size_t>(command_id)].id ==
             selected_profile_;
}

BEGIN_METADATA(OpenSpaceCreationView)
END_METADATA

// ===========================================================================
// Popovers.
// ===========================================================================

SpaceEditorAnchor::SpaceEditorAnchor() = default;
SpaceEditorAnchor::SpaceEditorAnchor(const SpaceEditorAnchor&) = default;
SpaceEditorAnchor& SpaceEditorAnchor::operator=(const SpaceEditorAnchor&) =
    default;
SpaceEditorAnchor::~SpaceEditorAnchor() = default;

OpenSpaceEditorPopover::OpenSpaceEditorPopover() = default;

OpenSpaceEditorPopover::~OpenSpaceEditorPopover() {
  DiscardBubble(/*synchronous=*/true);
}

void OpenSpaceEditorPopover::DiscardBubble(bool synchronous) {
  weak_factory_.InvalidateWeakPtrs();
  theme_editor_ = nullptr;
  creation_ = nullptr;
  if (synchronous) {
    if (widget_) {
      widget_->CloseNow();
    }
    widget_.reset();
    bubble_delegate_.reset();
    return;
  }
  // Posted in order: the widget is deleted before its delegate, which must
  // outlive it.
  if (widget_) {
    widget_->Hide();
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(widget_));
  }
  if (bubble_delegate_) {
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(bubble_delegate_));
  }
}

std::unique_ptr<views::BubbleDialogDelegate>
OpenSpaceEditorPopover::MakeDelegate(const SpaceEditorAnchor& anchor,
                                     int corner_radius) {
  views::View* anchor_view = anchor.view.get();
  if (!anchor_view && !anchor.parent) {
    return nullptr;
  }
  auto delegate = std::make_unique<views::BubbleDialogDelegate>(
      anchor_view, anchor.arrow, views::BubbleBorder::DIALOG_SHADOW,
      /*autosize=*/true);
  if (!anchor_view) {
    delegate->set_parent_window(anchor.parent);
    delegate->SetAnchorRect(anchor.screen_rect);
  }
  delegate->set_margins(gfx::Insets());
  delegate->set_corner_radius(corner_radius);
  delegate->SetButtons(static_cast<int>(ui::mojom::DialogButton::kNone));
  delegate->SetShowCloseButton(false);
  delegate->SetShowTitle(false);
  delegate->set_close_on_deactivate(true);
  delegate->set_adjust_if_offscreen(true);
  return delegate;
}

void OpenSpaceEditorPopover::ReplaceCurrent() {
  OpenSpaceThemeEditorView* editor = theme_editor_;
  OpenSpaceCreationView* creation = creation_;
  DiscardBubble(/*synchronous=*/false);
  if (editor) {
    editor->NotifyClosed();
  }
  if (creation) {
    creation->NotifyClosed();
  }
}

void OpenSpaceEditorPopover::Open() {
  widget_ = views::BubbleDialogDelegate::CreateBubble(
      bubble_delegate_.get(),
      base::BindOnce(&OpenSpaceEditorPopover::OnWidgetClosed,
                     weak_factory_.GetWeakPtr()));
  widget_->Show();
}

OpenSpaceThemeEditorView* OpenSpaceEditorPopover::ShowThemeEditor(
    const SpaceEditorAnchor& anchor,
    OpenSpaceThemeEditorParams params,
    OpenSpaceThemeEditorView::Callbacks callbacks) {
  // Reopening replaces the popover: release the old bubble (and cancel its
  // closed callback) first, then let the old contents finish (commit a
  // running gesture, report on_close / on_cancel).
  ReplaceCurrent();
  bubble_delegate_ = MakeDelegate(anchor, m::kCornerRadius);
  if (!bubble_delegate_) {
    return nullptr;
  }
  bubble_delegate_->set_fixed_width(m::kContentWidth);
  theme_editor_ = bubble_delegate_->SetContentsView(
      std::make_unique<OpenSpaceThemeEditorView>(std::move(params),
                                                 std::move(callbacks)));
  bubble_delegate_->SetBackgroundColor(theme_editor_->panel_color());
  bubble_delegate_->SetInitiallyFocusedView(theme_editor_->initial_focus());
  bubble_delegate_->SetAccessibleTitle(u"Edit Theme");
  OpenSpaceThemeEditorView* view = theme_editor_;
  Open();
  return view;
}

OpenSpaceCreationView* OpenSpaceEditorPopover::ShowCreation(
    const SpaceEditorAnchor& anchor,
    OpenSpaceCreationParams params,
    OpenSpaceCreationView::Callbacks callbacks) {
  ReplaceCurrent();
  bubble_delegate_ = MakeDelegate(anchor, m::kCreationCornerRadius);
  if (!bubble_delegate_) {
    return nullptr;
  }
  bubble_delegate_->set_fixed_width(m::kCreationWidth);
  creation_ = bubble_delegate_->SetContentsView(
      std::make_unique<OpenSpaceCreationView>(std::move(params),
                                              std::move(callbacks)));
  bubble_delegate_->SetBackgroundColor(creation_->body_color());
  bubble_delegate_->SetInitiallyFocusedView(creation_->name_field());
  bubble_delegate_->SetAccessibleTitle(u"Create a Space");
  OpenSpaceCreationView* view = creation_;
  Open();
  return view;
}

void OpenSpaceEditorPopover::Close() {
  if (widget_ && !widget_->IsClosed()) {
    widget_->CloseWithReason(views::Widget::ClosedReason::kUnspecified);
  }
}

bool OpenSpaceEditorPopover::IsShowing() const {
  return widget_ && widget_->IsVisible();
}

void OpenSpaceEditorPopover::OnWidgetClosed(
    views::Widget::ClosedReason reason) {
  OpenSpaceThemeEditorView* editor = theme_editor_;
  OpenSpaceCreationView* creation = creation_;
  const bool self_owned = self_owned_;
  // Hide now and delete on the next task (the close can start inside the
  // widget's own event handling). The contents stay alive until then, so
  // the views can still report their final state below.
  DiscardBubble(/*synchronous=*/false);
  if (self_owned) {
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                               this);
  }
  // Last: these callbacks may release this popover's owner.
  if (editor) {
    editor->NotifyClosed();
  }
  if (creation) {
    creation->NotifyClosed();
  }
}

views::Widget* ShowSpaceThemeEditorPopover(
    const SpaceEditorAnchor& anchor,
    OpenSpaceThemeEditorParams params,
    OpenSpaceThemeEditorView::Callbacks callbacks) {
  auto* popover = new OpenSpaceEditorPopover();
  popover->self_owned_ = true;
  if (!popover->ShowThemeEditor(anchor, std::move(params),
                                std::move(callbacks))) {
    delete popover;
    return nullptr;
  }
  return popover->widget();
}

views::Widget* ShowSpaceCreationPopover(
    const SpaceEditorAnchor& anchor,
    OpenSpaceCreationParams params,
    OpenSpaceCreationView::Callbacks callbacks) {
  auto* popover = new OpenSpaceEditorPopover();
  popover->self_owned_ = true;
  if (!popover->ShowCreation(anchor, std::move(params),
                             std::move(callbacks))) {
    delete popover;
    return nullptr;
  }
  return popover->widget();
}

}  // namespace open_unified
