// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_boost_editor_view.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <numbers>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/rand_util.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "build/build_config.h"
#include "cc/paint/paint_flags.h"
#include "cc/paint/paint_shader.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/font.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/gfx/geometry/vector2d.h"
#include "ui/gfx/scoped_canvas.h"
#include "ui/gfx/text_constants.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/border.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"
#include "ui/views/controls/textarea/textarea.h"
#include "ui/views/controls/textfield/textfield.h"
#include "ui/views/widget/widget.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/views/open_split_container_view.h"

namespace open_unified {

namespace m = boost_editor_metrics;

namespace {

using secondary::PaintedButton;

constexpr float kPi = std::numbers::pi_v<float>;

// Arc's Size button cycle (BoostEditorSession.textSizes, capture C11):
// index 1 is Normal; the cycle runs 100 > 110 > 125 > 150 > 90 > 100 %.
constexpr std::array<double, 5> kCycleSizes = {0.9, 1.0, 1.1, 1.25, 1.5};
// Every size the Size menu offers (right-click).
constexpr std::array<double, 8> kMenuSizes = {0.75, 0.9, 1.0,  1.1,
                                              1.15, 1.25, 1.5, 2.0};
// BoostEditorSession.textCases.
constexpr std::array<const char*, 4> kCases = {"", "capitalize", "uppercase",
                                               "lowercase"};
constexpr std::array<const char16_t*, 4> kCaseLabels = {u"Case", u"Aa", u"AA",
                                                        u"aa"};
constexpr std::array<const char16_t*, 4> kCaseNames = {
    u"Original", u"Capitalize", u"Uppercase", u"Lowercase"};
constexpr std::array<const char16_t*, 3> kSliderNames = {
    u"Contrast", u"Brightness", u"Original Saturation"};

constexpr size_t kMaxUndo = 50;
constexpr base::TimeDelta kNoticeLifetime = base::Seconds(4);

enum MenuCommand : int {
  kCmdHost = 1,
  kCmdRename,
  kCmdShuffle,
  kCmdToggleEnabled,
  kCmdCustomFont,
  kCmdUndoZap,
  kCmdClearZaps,
  kCmdResetAll,
  kCmdDelete,
  kCmdShare,
  kCmdAllBoosts,
  kCmdSizeBase = 100,
  kCmdCaseBase = 200,
};

// BoostEditorColors.ringStops (degrees, 0 at 3 o'clock, clockwise).
struct RingStop {
  float degrees;
  SkColor color;
};
constexpr RingStop kRingStops[] = {
    {0, SkColorSetRGB(0xEB, 0x48, 0x38)},   {30, SkColorSetRGB(0xEB, 0x76, 0x36)},
    {60, SkColorSetRGB(0xF4, 0xBA, 0x49)},  {90, SkColorSetRGB(0xD4, 0xFD, 0x58)},
    {120, SkColorSetRGB(0x90, 0xFC, 0x74)}, {150, SkColorSetRGB(0x80, 0xFC, 0xAD)},
    {180, SkColorSetRGB(0x7C, 0xF8, 0xF1)}, {210, SkColorSetRGB(0x35, 0x6F, 0xF6)},
    {240, SkColorSetRGB(0x39, 0x2E, 0xF4)}, {270, SkColorSetRGB(0x82, 0x37, 0xF5)},
    {300, SkColorSetRGB(0xDD, 0x31, 0xBF)}, {330, SkColorSetRGB(0xDF, 0x34, 0x70)},
    {360, SkColorSetRGB(0xEB, 0x48, 0x38)},
};
// BoostEditorColors.greyRingStops (the "no color" ring, grey levels).
constexpr int kGreyRingLevels[] = {113, 141, 191, 233, 226, 227, 227,
                                   117, 72,  92,  110, 107, 113};

double Clamp(double value, double lo, double hi, double fallback) {
  return std::isfinite(value) ? std::clamp(value, lo, hi) : fallback;
}

double WrapDegrees(double degrees) {
  double d = std::fmod(std::isfinite(degrees) ? degrees : 0.0, 360.0);
  return d < 0.0 ? d + 360.0 : d;
}

// (-180, 180].
double Wrap180(double degrees) {
  double d = std::fmod(WrapDegrees(degrees) + 180.0, 360.0) - 180.0;
  return d <= -180.0 ? d + 360.0 : d;
}

SkColor HsvColor(float hue, float saturation, float value) {
  const SkScalar hsv[3] = {static_cast<SkScalar>(WrapDegrees(hue)),
                           std::clamp(saturation, 0.f, 1.f),
                           std::clamp(value, 0.f, 1.f)};
  return SkHSVToColor(0xFF, hsv);
}

SkPath RoundRectPath(const gfx::RectF& rect, float radius) {
  SkPathBuilder builder;
  builder.addRRect(SkRRect::MakeRectXY(gfx::RectFToSkRect(rect), radius,
                                       radius));
  return builder.detach();
}

// Draws the macOS SF Symbol |symbol| when the platform has it, else runs
// |fallback| (Open's own Skia glyph).
template <typename Fallback>
void Symbol(gfx::Canvas* canvas,
            const char* symbol,
            float point_size,
            const gfx::RectF& box,
            SkColor color,
            Fallback fallback) {
  if (!glyphs::DrawSystemSymbol(canvas, symbol, point_size,
                                glyphs::SymbolWeight::kRegular, box, color)) {
    fallback();
  }
}

cc::PaintFlags StrokeFlags(SkColor color, float width) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kStroke_Style);
  flags.setStrokeCap(cc::PaintFlags::kRound_Cap);
  flags.setStrokeJoin(cc::PaintFlags::kRound_Join);
  flags.setStrokeWidth(width);
  flags.setColor(color);
  return flags;
}

cc::PaintFlags FillFlags(SkColor color) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kFill_Style);
  flags.setColor(color);
  return flags;
}

// --- Open's own fallback glyphs (Windows, Linux) ---------------------------

void PaintLightbulb(gfx::Canvas* canvas, const gfx::RectF& box, SkColor color,
                    bool filled) {
  const gfx::PointF c = box.CenterPoint();
  const float r = 4.5f;
  const gfx::PointF bulb(c.x(), c.y() - 2.f);
  if (filled) {
    canvas->DrawCircle(bulb, r, FillFlags(color));
  } else {
    canvas->DrawCircle(bulb, r, StrokeFlags(color, 1.4f));
  }
  const cc::PaintFlags line = StrokeFlags(color, 1.4f);
  canvas->DrawLine(gfx::PointF(c.x() - 2.f, c.y() + 4.f),
                   gfx::PointF(c.x() + 2.f, c.y() + 4.f), line);
  canvas->DrawLine(gfx::PointF(c.x() - 1.5f, c.y() + 6.5f),
                   gfx::PointF(c.x() + 1.5f, c.y() + 6.5f), line);
}

void PaintSliders(gfx::Canvas* canvas, const gfx::RectF& box, SkColor color) {
  const gfx::PointF c = box.CenterPoint();
  const cc::PaintFlags line = StrokeFlags(color, 1.3f);
  const float knob_x[3] = {-2.5f, 2.5f, -0.5f};
  for (int i = 0; i < 3; ++i) {
    const float y = c.y() - 4.5f + 4.5f * i;
    canvas->DrawLine(gfx::PointF(c.x() - 7.f, y), gfx::PointF(c.x() + 7.f, y),
                     line);
    canvas->DrawCircle(gfx::PointF(c.x() + knob_x[i], y), 1.9f,
                       FillFlags(SK_ColorWHITE));
    canvas->DrawCircle(gfx::PointF(c.x() + knob_x[i], y), 1.9f,
                       StrokeFlags(color, 1.2f));
  }
}

void PaintNoSign(gfx::Canvas* canvas, const gfx::RectF& box, SkColor color) {
  const gfx::PointF c = box.CenterPoint();
  canvas->DrawCircle(c, 6.f, StrokeFlags(color, 1.5f));
  const float d = 6.f * std::numbers::sqrt2_v<float> / 2.f;
  canvas->DrawLine(gfx::PointF(c.x() - d, c.y() - d),
                   gfx::PointF(c.x() + d, c.y() + d), StrokeFlags(color, 1.5f));
}

void PaintCircleX(gfx::Canvas* canvas, const gfx::PointF& center,
                  float radius, SkColor fill, SkColor cross) {
  canvas->DrawCircle(center, radius, FillFlags(fill));
  const float d = radius * 0.38f;
  const cc::PaintFlags x = StrokeFlags(cross, 1.4f);
  canvas->DrawLine(gfx::PointF(center.x() - d, center.y() - d),
                   gfx::PointF(center.x() + d, center.y() + d), x);
  canvas->DrawLine(gfx::PointF(center.x() + d, center.y() - d),
                   gfx::PointF(center.x() - d, center.y() + d), x);
}

// A Gaussian shadow plus fill under a circle.
void PaintKnob(gfx::Canvas* canvas, const gfx::PointF& center, float diameter,
               SkColor fill, SkColor ring, float ring_width) {
  const float r = diameter / 2.f;
  cc::PaintFlags shadow = FillFlags(SkColorSetA(SK_ColorBLACK, 0x2E));
  canvas->DrawCircle(gfx::PointF(center.x(), center.y() + 1.f), r + 0.5f,
                     shadow);
  canvas->DrawCircle(center, r, FillFlags(ring));
  // Vertical gradient: a little lighter at the top, darker at the bottom.
  const float inner = std::max(1.f, r - ring_width);
  const SkPoint points[2] = {SkPoint::Make(0, center.y() - inner),
                             SkPoint::Make(0, center.y() + inner)};
  const SkColor4f colors[2] = {
      SkColor4f::FromColor(secondary::Mix(fill, SK_ColorWHITE, 0.08f)),
      SkColor4f::FromColor(secondary::Mix(fill, SK_ColorBLACK, 0.06f))};
  cc::PaintFlags body = FillFlags(fill);
  body.setShader(cc::PaintShader::MakeLinearGradient(points, colors, nullptr,
                                                     2, SkTileMode::kClamp));
  canvas->DrawCircle(center, inner, body);
}

// Click catcher under the advanced card: a press anywhere else closes it.
class ClickCatcherView : public views::View {
  METADATA_HEADER(ClickCatcherView, views::View)

 public:
  explicit ClickCatcherView(base::RepeatingClosure on_press)
      : on_press_(std::move(on_press)) {}
  bool OnMousePressed(const ui::MouseEvent& event) override {
    on_press_.Run();
    return true;
  }

 private:
  base::RepeatingClosure on_press_;
};

BEGIN_METADATA(ClickCatcherView)
END_METADATA

// The advanced card's body (a rounded card with a caret toward the
// Advanced button).
class AdvancedCardView : public views::View {
  METADATA_HEADER(AdvancedCardView, views::View)

 public:
  AdvancedCardView() = default;
  void SetColors(SkColor fill, SkColor shadow) {
    fill_ = fill;
    shadow_ = shadow;
    SchedulePaint();
  }
  void SetCaretX(float x) { caret_x_ = x; }
  void OnPaint(gfx::Canvas* canvas) override {
    const gfx::RectF card = gfx::RectF(GetLocalBounds());
    gfx::RectF body = card;
    body.Inset(gfx::InsetsF::TLBR(7.f, 0.f, 0.f, 0.f));
    secondary::FillRoundRectWithShadow(canvas, body, 10.f, fill_, shadow_,
                                       4.f, 16.f);
    SkPathBuilder caret;
    caret.moveTo(caret_x_ - 8.f, body.y() + 0.5f);
    caret.lineTo(caret_x_, 0.f);
    caret.lineTo(caret_x_ + 8.f, body.y() + 0.5f);
    caret.close();
    canvas->DrawPath(caret.detach(), FillFlags(fill_));
  }
  bool OnMousePressed(const ui::MouseEvent& event) override { return true; }

 private:
  SkColor fill_ = SkColorSetRGB(0xEE, 0xEE, 0xEE);
  SkColor shadow_ = SkColorSetA(SK_ColorBLACK, 0x33);
  float caret_x_ = 85.f;
};

BEGIN_METADATA(AdvancedCardView)
END_METADATA

}  // namespace

// ===========================================================================
// BoostWheelState
// ===========================================================================

bool BoostWheelState::IsIdentity() const {
  return intensity < 0.02 && !invert && std::fabs(brightness - 1.0) < 1e-6 &&
         std::fabs(contrast - 1.0) < 1e-6 &&
         std::fabs(original_saturation - 1.0) < 1e-6;
}

BoostColorAdjustment BoostWheelState::ToColor() const {
  BoostColorAdjustment color;
  if (IsIdentity()) {
    return color;  // enabled = false
  }
  const double t = Clamp(intensity, 0.0, 1.0, 0.0);
  const double delta = Wrap180(hue);  // base hue 0
  color.enabled = true;
  color.hue_degrees = WrapDegrees(t * delta + (invert ? 180.0 : 0.0));
  color.saturation = std::clamp(
      Clamp(original_saturation, 0.0, 2.0, 1.0) * (1.0 + 0.5 * t), 0.0, 3.0);
  color.lightness = Clamp(brightness, 0.5, 1.5, 1.0) - 1.0;
  color.contrast = Clamp(contrast, 0.5, 1.5, 1.0);
  color.invert = invert;
  return color;
}

// static
BoostWheelState BoostWheelState::FromColor(const BoostColorAdjustment& c) {
  BoostWheelState state;
  if (!c.enabled) {
    return state;
  }
  state.invert = c.invert;
  state.brightness = Clamp(1.0 + c.lightness, 0.5, 1.5, 1.0);
  state.contrast = Clamp(c.contrast, 0.5, 1.5, 1.0);
  const double rotation =
      Wrap180(c.hue_degrees - (c.invert ? 180.0 : 0.0));
  const double saturation = Clamp(c.saturation, 0.0, 3.0, 1.0);
  if (std::fabs(rotation) < 0.5 && std::fabs(saturation - 1.0) < 1e-3) {
    return state;  // No tint: knob at the center.
  }
  // Exact inverse when saturation came from the wheel alone
  // (original 1): saturation = 1 + 0.5 * intensity.
  const double t = (saturation - 1.0) / 0.5;
  if (t >= 0.02 && t <= 1.0 && std::fabs(rotation) <= 180.0 * t + 1e-6) {
    state.intensity = t;
    state.hue = WrapDegrees(rotation / t);
    state.original_saturation = 1.0;
    return state;
  }
  // Otherwise put the knob on the rim and keep the filter exact.
  state.intensity = 1.0;
  state.hue = WrapDegrees(rotation);
  state.original_saturation = std::clamp(saturation / 1.5, 0.0, 2.0);
  return state;
}

const std::vector<BoostEditorFont>& BoostEditorFonts() {
  static const base::NoDestructor<std::vector<BoostEditorFont>> fonts([] {
    // BoostEditorFonts.available (BoostEditorViews.swift): System, then
    // these families with their CSS generic fallback.
    struct Family {
      const char* name;
      const char* generic;
    };
#if BUILDFLAG(IS_MAC)
    static constexpr Family kFamilies[] = {
        {"Helvetica Neue", "sans-serif"},
        {"Avenir", "sans-serif"},
        {"Futura", "sans-serif"},
        {"DIN Alternate", "sans-serif"},
        {"Arial Rounded MT Bold", "sans-serif"},
        {"PT Mono", "monospace"},
        {"Courier", "monospace"},
        {"Times New Roman", "serif"},
        {"Charter", "serif"},
        {"Baskerville", "serif"},
        {"Hoefler Text", "serif"},
        {"Palatino", "serif"},
        {"Chalkboard", "cursive"},
        {"SignPainter", "cursive"},
        {"Snell Roundhand", "cursive"},
        {"Papyrus", "fantasy"},
        {"Apple Chancery", "cursive"},
        {"Luminari", "fantasy"},
        {"Wingdings", "fantasy"},
    };
#elif BUILDFLAG(IS_WIN)
    static constexpr Family kFamilies[] = {
        {"Segoe UI", "sans-serif"},
        {"Cascadia Code", "monospace"},
        {"Consolas", "monospace"},
        {"Georgia", "serif"},
        {"Cambria", "serif"},
        {"Calibri", "sans-serif"},
        {"Bahnschrift", "sans-serif"},
        {"Trebuchet MS", "sans-serif"},
        {"Verdana", "sans-serif"},
        {"Comic Sans MS", "cursive"},
        {"Impact", "fantasy"},
        {"Courier New", "monospace"},
        {"Times New Roman", "serif"},
        {"Arial", "sans-serif"},
        {"Tahoma", "sans-serif"},
        {"Palatino Linotype", "serif"},
        {"Segoe Script", "cursive"},
        {"Lucida Console", "monospace"},
        {"Franklin Gothic Medium", "sans-serif"},
    };
#else
    static constexpr Family kFamilies[] = {
        {"Ubuntu", "sans-serif"},
        {"Noto Sans", "sans-serif"},
        {"Liberation Sans", "sans-serif"},
        {"DejaVu Sans", "sans-serif"},
        {"DejaVu Serif", "serif"},
        {"JetBrains Mono", "monospace"},
        {"Liberation Mono", "monospace"},
        {"Noto Serif", "serif"},
        {"Ubuntu Mono", "monospace"},
        {"Cantarell", "sans-serif"},
        {"FreeSans", "sans-serif"},
        {"FreeSerif", "serif"},
        {"FreeMono", "monospace"},
        {"Monospace", nullptr},
        {"Serif", nullptr},
        {"Sans-Serif", nullptr},
    };
#endif
    std::vector<BoostEditorFont> list;
    list.push_back({u"System", std::string(), std::string()});
    for (const Family& family : kFamilies) {
      std::string css = family.generic
                            ? std::string(family.name) + ", " + family.generic
                            : base::ToLowerASCII(family.name);
      list.push_back({base::UTF8ToUTF16(family.name), std::move(css),
                      family.name});
    }
    return list;
  }());
  return *fonts;
}

// ===========================================================================
// BoostColorWheelView
// ===========================================================================

BoostColorWheelView::BoostColorWheelView(ChangedCallback on_changed)
    : on_changed_(std::move(on_changed)) {
  SetFocusBehavior(FocusBehavior::ALWAYS);
  GetViewAccessibility().SetRole(ax::mojom::Role::kSlider);
  GetViewAccessibility().SetName(u"Color");
  GetViewAccessibility().SetDescription(
      u"Drag to tint the page. Arrow keys change hue and intensity.");
}

BoostColorWheelView::~BoostColorWheelView() = default;

void BoostColorWheelView::SetState(const BoostWheelState& state) {
  state_ = state;
  SchedulePaint();
}

void BoostColorWheelView::SetDark(bool dark) {
  dark_ = dark;
  SchedulePaint();
}

gfx::Size BoostColorWheelView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  return m::kRing.size();
}

gfx::PointF BoostColorWheelView::Center() const {
  return gfx::RectF(GetLocalBounds()).CenterPoint();
}

gfx::PointF BoostColorWheelView::KnobCenter(float angle_degrees) const {
  const bool identity = state_.IsIdentity() && state_.intensity < 0.02;
  const float radius =
      identity ? m::kDefaultKnobRadius
               : static_cast<float>(std::clamp(state_.intensity, 0.0, 1.0)) *
                     m::kPadRadius * 0.99f;
  const float a = angle_degrees * kPi / 180.f;
  const gfx::PointF c = Center();
  return gfx::PointF(c.x() + radius * std::cos(a), c.y() + radius * std::sin(a));
}

void BoostColorWheelView::OnPaint(gfx::Canvas* canvas) {
  const gfx::RectF ring(GetLocalBounds());
  const gfx::PointF c = ring.CenterPoint();
  const bool grey = state_.intensity < 0.02 && !state_.invert;

  // Hue ring: a sweep gradient clipped to the rounded square.
  {
    std::vector<SkColor4f> colors;
    std::vector<SkScalar> positions;
    for (size_t i = 0; i < std::size(kRingStops); ++i) {
      SkColor color = kRingStops[i].color;
      if (grey) {
        const int level = kGreyRingLevels[i];
        color = SkColorSetRGB(level, level, level);
        if (dark_) {
          color = secondary::Mix(color, SK_ColorBLACK, 0.35f);
        }
      }
      colors.push_back(SkColor4f::FromColor(color));
      positions.push_back(kRingStops[i].degrees / 360.f);
    }
    cc::PaintFlags flags = FillFlags(SK_ColorWHITE);
    flags.setShader(cc::PaintShader::MakeSweepGradient(
        c.x(), c.y(), colors.data(), positions.data(),
        static_cast<int>(colors.size()), SkTileMode::kClamp, 0.f, 360.f));
    canvas->DrawPath(RoundRectPath(ring, m::kRingRadius), flags);
  }

  // Plate with its dot grid.
  gfx::RectF plate = ring;
  plate.Inset(m::kPlateInset);
  const SkPath plate_path = RoundRectPath(plate, m::kPlateRadius);
  const SkColor plate_color =
      dark_ ? SkColorSetRGB(0x2A, 0x2A, 0x2D) : SkColorSetRGB(0xFA, 0xFA, 0xFA);
  canvas->DrawPath(plate_path, FillFlags(plate_color));
  {
    gfx::ScopedCanvas scoped(canvas);
    canvas->ClipPath(plate_path, true);
    SkPathBuilder dots;
    for (float y = plate.y() + m::kDotPitch / 2.f; y < plate.bottom();
         y += m::kDotPitch) {
      for (float x = plate.x() + m::kDotPitch / 2.f; x < plate.right();
           x += m::kDotPitch) {
        dots.addRect(SkRect::MakeXYWH(x - m::kDotSize / 2.f,
                                      y - m::kDotSize / 2.f, m::kDotSize,
                                      m::kDotSize));
      }
    }
    canvas->DrawPath(dots.detach(),
                     FillFlags(dark_ ? SkColorSetA(SK_ColorWHITE, 0x1A)
                                     : SkColorSetA(SK_ColorBLACK, 0x13)));
  }

  const float primary_angle = static_cast<float>(state_.hue);
  const float secondary_angle = primary_angle + m::kSecondaryOffsetDegrees;
  const gfx::PointF primary = KnobCenter(primary_angle);
  const gfx::PointF companion = KnobCenter(secondary_angle);
  const float t = static_cast<float>(std::clamp(state_.intensity, 0.0, 1.0));

  if (!grey) {
    canvas->DrawLine(c, primary,
                     StrokeFlags(dark_ ? SkColorSetA(SK_ColorWHITE, 0x1F)
                                       : SkColorSetA(SK_ColorBLACK, 0x0F),
                                 m::kGuideWidth));
  }
  const SkColor primary_fill =
      grey ? SkColorSetRGB(0x71, 0x71, 0x71) : HsvColor(primary_angle, t, 0.78f);
  const SkColor secondary_fill =
      grey ? SkColorSetRGB(0x33, 0x33, 0x33)
           : HsvColor(secondary_angle, t * 0.68f, 0.24f);
  PaintKnob(canvas, companion, m::kSecondaryDisc, secondary_fill,
            SkColorSetRGB(0xC8, 0xC2, 0xCA), 1.f);
  PaintKnob(canvas, primary,
            dragging_ ? m::kPrimaryDragDisc : m::kPrimaryDisc, primary_fill,
            SK_ColorWHITE, m::kKnobRing);

  if (HasFocus()) {
    canvas->DrawPath(RoundRectPath(gfx::RectF(ring.x() + 1, ring.y() + 1,
                                              ring.width() - 2,
                                              ring.height() - 2),
                                   m::kRingRadius - 1),
                     StrokeFlags(SkColorSetA(SK_ColorBLACK, 0x40), 2.f));
  }
}

void BoostColorWheelView::UpdateFromPoint(const gfx::Point& point,
                                          bool dragging) {
  const gfx::PointF c = Center();
  const float dx = point.x() - c.x();
  const float dy = point.y() - c.y();
  const float distance = std::hypot(dx, dy);
  state_.intensity =
      std::clamp(static_cast<double>(distance / (m::kPadRadius * 0.99f)), 0.0,
                 1.0);
  if (distance > 0.5f) {
    state_.hue = WrapDegrees(std::atan2(dy, dx) * 180.0 / std::numbers::pi);
  }
  Notify(dragging);
}

void BoostColorWheelView::Notify(bool dragging) {
  SchedulePaint();
  if (on_changed_) {
    on_changed_.Run(state_, dragging);
  }
}

bool BoostColorWheelView::OnMousePressed(const ui::MouseEvent& event) {
  if (!event.IsOnlyLeftMouseButton()) {
    return false;
  }
  RequestFocus();
  dragging_ = true;
  UpdateFromPoint(event.location(), /*dragging=*/true);
  return true;
}

bool BoostColorWheelView::OnMouseDragged(const ui::MouseEvent& event) {
  if (!dragging_) {
    return false;
  }
  UpdateFromPoint(event.location(), /*dragging=*/true);
  return true;
}

void BoostColorWheelView::OnMouseReleased(const ui::MouseEvent& event) {
  if (!dragging_) {
    return;
  }
  dragging_ = false;
  UpdateFromPoint(event.location(), /*dragging=*/false);
}

void BoostColorWheelView::OnMouseCaptureLost() {
  if (!dragging_) {
    return;
  }
  dragging_ = false;
  Notify(/*dragging=*/false);
}

bool BoostColorWheelView::OnKeyPressed(const ui::KeyEvent& event) {
  switch (event.key_code()) {
    case ui::VKEY_LEFT:
      state_.hue = WrapDegrees(state_.hue - 5.0);
      break;
    case ui::VKEY_RIGHT:
      state_.hue = WrapDegrees(state_.hue + 5.0);
      break;
    case ui::VKEY_UP:
      state_.intensity = std::min(1.0, state_.intensity + 0.05);
      break;
    case ui::VKEY_DOWN:
      state_.intensity = std::max(0.0, state_.intensity - 0.05);
      break;
    default:
      return false;
  }
  Notify(/*dragging=*/false);
  return true;
}

BEGIN_METADATA(BoostColorWheelView)
END_METADATA

// ===========================================================================
// BoostEditorSliderView: a label over a thin track with a round thumb
// (the advanced card's Contrast / Brightness / Original Saturation).
// ===========================================================================

class BoostEditorSliderView : public views::View {
  METADATA_HEADER(BoostEditorSliderView, views::View)

 public:
  using Callback = base::RepeatingCallback<void(double value, bool dragging)>;

  BoostEditorSliderView(std::u16string label,
                        double min,
                        double max,
                        Callback callback)
      : label_(std::move(label)),
        min_(min),
        max_(max),
        callback_(std::move(callback)) {
    SetFocusBehavior(FocusBehavior::ALWAYS);
    GetViewAccessibility().SetRole(ax::mojom::Role::kSlider);
    GetViewAccessibility().SetName(label_);
  }

  void SetValue(double value) {
    value_ = std::clamp(value, min_, max_);
    SchedulePaint();
  }
  void SetColors(SkColor label, SkColor track, SkColor fill) {
    label_color_ = label;
    track_color_ = track;
    fill_color_ = fill;
    SchedulePaint();
  }
  bool dragging() const { return dragging_; }

  void OnPaint(gfx::Canvas* canvas) override {
    const int label_height = 18;
    secondary::DrawText(canvas, label_,
                        secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM),
                        label_color_,
                        gfx::Rect(0, 0, width(), label_height),
                        gfx::Canvas::TEXT_ALIGN_LEFT);
    const gfx::RectF track = TrackRect();
    const float x = ThumbX();
    canvas->DrawRoundRect(track, 2.f, FillFlags(track_color_));
    canvas->DrawRoundRect(
        gfx::RectF(track.x(), track.y(), x - track.x(), track.height()), 2.f,
        FillFlags(fill_color_));
    PaintKnob(canvas, gfx::PointF(x, track.CenterPoint().y()), 20.f,
              SK_ColorWHITE, SkColorSetRGB(0xF4, 0xF4, 0xF4), 0.5f);
    if (HasFocus()) {
      canvas->DrawCircle(gfx::PointF(x, track.CenterPoint().y()), 11.f,
                         StrokeFlags(SkColorSetA(SK_ColorBLACK, 0x40), 1.5f));
    }
  }

  bool OnMousePressed(const ui::MouseEvent& event) override {
    if (!event.IsOnlyLeftMouseButton()) {
      return false;
    }
    RequestFocus();
    dragging_ = true;
    Update(event.location().x(), true);
    return true;
  }
  bool OnMouseDragged(const ui::MouseEvent& event) override {
    if (dragging_) {
      Update(event.location().x(), true);
    }
    return dragging_;
  }
  void OnMouseReleased(const ui::MouseEvent& event) override {
    if (dragging_) {
      dragging_ = false;
      Update(event.location().x(), false);
    }
  }
  void OnMouseCaptureLost() override {
    if (dragging_) {
      dragging_ = false;
      callback_.Run(value_, false);
    }
  }
  bool OnKeyPressed(const ui::KeyEvent& event) override {
    const double step = (max_ - min_) / 40.0;
    if (event.key_code() == ui::VKEY_LEFT) {
      SetValue(value_ - step);
    } else if (event.key_code() == ui::VKEY_RIGHT) {
      SetValue(value_ + step);
    } else {
      return false;
    }
    callback_.Run(value_, false);
    return true;
  }

 private:
  gfx::RectF TrackRect() const {
    const float y = height() - m::kSliderHeight / 2.f - 2.f;
    return gfx::RectF(10.f, y, std::max(0, width() - 20), 4.f);
  }
  float ThumbX() const {
    const gfx::RectF track = TrackRect();
    const double f = (value_ - min_) / std::max(1e-9, max_ - min_);
    return track.x() + static_cast<float>(f) * track.width();
  }
  void Update(int x, bool dragging) {
    const gfx::RectF track = TrackRect();
    const double f =
        std::clamp((x - track.x()) / std::max(1.f, track.width()), 0.f, 1.f);
    value_ = min_ + f * (max_ - min_);
    // Snap to the neutral value near the middle.
    const double neutral = (min_ + max_) / 2.0;
    if (std::fabs(value_ - neutral) < (max_ - min_) * 0.015) {
      value_ = neutral;
    }
    SchedulePaint();
    callback_.Run(value_, dragging);
  }

  std::u16string label_;
  double min_;
  double max_;
  double value_ = 1.0;
  bool dragging_ = false;
  Callback callback_;
  SkColor label_color_ = SkColorSetRGB(0x3A, 0x3A, 0x3B);
  SkColor track_color_ = SkColorSetRGB(0xD9, 0xD9, 0xD9);
  SkColor fill_color_ = SkColorSetRGB(0x9A, 0x9A, 0x9A);
};

BEGIN_METADATA(BoostEditorSliderView)
END_METADATA

// ===========================================================================
// BoostEditorConfirmView: "Delete this Boost?" card over a dimmed panel.
// ===========================================================================

class BoostEditorConfirmView : public views::View {
  METADATA_HEADER(BoostEditorConfirmView, views::View)

 public:
  BoostEditorConfirmView(base::RepeatingClosure on_cancel,
                         base::RepeatingClosure on_delete) {
    GetViewAccessibility().SetRole(ax::mojom::Role::kAlertDialog);
    GetViewAccessibility().SetName(u"Delete this Boost?");
    cancel_ = AddChildView(std::make_unique<PaintedButton>(
        std::move(on_cancel),
        base::BindRepeating(&BoostEditorConfirmView::PaintButton,
                            base::Unretained(this), false),
        u"Cancel"));
    delete_ = AddChildView(std::make_unique<PaintedButton>(
        std::move(on_delete),
        base::BindRepeating(&BoostEditorConfirmView::PaintButton,
                            base::Unretained(this), true),
        u"Delete"));
  }

  void SetName(const std::u16string& name) {
    name_ = name;
    SchedulePaint();
  }
  void SetDark(bool dark) {
    dark_ = dark;
    SchedulePaint();
  }
  void Focus() { cancel_->RequestFocus(); }

  void Layout(PassKey) override {
    const gfx::Rect card = CardRect();
    const int w = (card.width() - 16 * 2 - 8) / 2;
    const int y = card.bottom() - 16 - 30;
    cancel_->SetBoundsRect(gfx::Rect(card.x() + 16, y, w, 30));
    delete_->SetBoundsRect(gfx::Rect(card.x() + 16 + w + 8, y, w, 30));
  }

  void OnPaint(gfx::Canvas* canvas) override {
    canvas->DrawPath(RoundRectPath(gfx::RectF(GetLocalBounds()),
                                   m::kCornerRadius),
                     FillFlags(SkColorSetA(SK_ColorBLACK, 0x4D)));
    const gfx::Rect card = CardRect();
    secondary::FillRoundRectWithShadow(
        canvas, gfx::RectF(card), 12.f,
        dark_ ? SkColorSetRGB(0x2C, 0x2C, 0x2E) : SK_ColorWHITE,
        SkColorSetA(SK_ColorBLACK, 0x40), 4.f, 16.f);
    const SkColor title = dark_ ? SkColorSetRGB(0xF2, 0xF2, 0xF4)
                                : SkColorSetRGB(0x25, 0x25, 0x26);
    const SkColor body = dark_ ? SkColorSetRGB(0xA0, 0xA0, 0xA5)
                               : SkColorSetRGB(0x7C, 0x7C, 0x7D);
    secondary::DrawText(canvas, u"Delete this Boost?",
                        secondary::FontOfSize(13, gfx::Font::Weight::SEMIBOLD),
                        title,
                        gfx::Rect(card.x() + 12, card.y() + 16,
                                  card.width() - 24, 18),
                        gfx::Canvas::TEXT_ALIGN_CENTER);
    secondary::DrawText(canvas, u"“" + name_ + u"”",
                        secondary::FontOfSize(11), body,
                        gfx::Rect(card.x() + 12, card.y() + 38,
                                  card.width() - 24, 15),
                        gfx::Canvas::TEXT_ALIGN_CENTER);
    secondary::DrawText(canvas, u"This can’t be undone.",
                        secondary::FontOfSize(11), body,
                        gfx::Rect(card.x() + 12, card.y() + 54,
                                  card.width() - 24, 15),
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  bool OnMousePressed(const ui::MouseEvent& event) override { return true; }

 private:
  gfx::Rect CardRect() const {
    const int w = std::min(155, width() - 28);
    const int h = 124;
    return gfx::Rect((width() - w) / 2, (height() - h) / 2, w, h);
  }

  void PaintButton(bool destructive,
                   gfx::Canvas* canvas,
                   const gfx::Rect& bounds,
                   bool hovered) {
    SkColor fill = destructive ? SkColorSetRGB(0xFF, 0x5A, 0x5F)
                               : (dark_ ? SkColorSetRGB(0x3A, 0x3A, 0x3C)
                                        : SkColorSetRGB(0xEB, 0xEB, 0xED));
    if (hovered) {
      fill = secondary::Mix(fill, SK_ColorBLACK, 0.08f);
    }
    secondary::FillRoundRect(canvas, gfx::RectF(bounds), 8.f, fill);
    const SkColor text =
        destructive ? SK_ColorWHITE
                    : (dark_ ? SkColorSetRGB(0xF2, 0xF2, 0xF4)
                             : SkColorSetRGB(0x3A, 0x3A, 0x3B));
    secondary::DrawText(canvas, destructive ? u"Delete" : u"Cancel",
                        secondary::FontOfSize(13, gfx::Font::Weight::SEMIBOLD),
                        text, bounds, gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  std::u16string name_;
  bool dark_ = false;
  raw_ptr<PaintedButton> cancel_ = nullptr;
  raw_ptr<PaintedButton> delete_ = nullptr;
};

BEGIN_METADATA(BoostEditorConfirmView)
END_METADATA

// ===========================================================================
// OpenBoostEditorView
// ===========================================================================

// static
OpenBoostEditorView::Palette OpenBoostEditorView::PaletteFor(bool dark) {
  if (!dark) {
    // BoostEditorColors (light, measured).
    return Palette{
        .header = SkColorSetRGB(0xF5, 0xF5, 0xF7),
        .hairline = SkColorSetRGB(0xE9, 0xE9, 0xEB),
        .body = SkColorSetRGB(0xFD, 0xFD, 0xFF),
        .button = SkColorSetRGB(0xEB, 0xEB, 0xED),
        .button_hover = SkColorSetRGB(0xE4, 0xE4, 0xE6),
        .button_pressed = SkColorSetRGB(0xDF, 0xDF, 0xE0),
        .button_on = SkColorSetRGB(0x33, 0x33, 0x33),
        .advanced_on = SkColorSetRGB(0x47, 0x47, 0x47),
        .on_glyph = SK_ColorWHITE,
        .label = SkColorSetRGB(0x3A, 0x3A, 0x3B),
        .title = SkColorSetRGB(0x25, 0x25, 0x26),
        .header_glyph = SkColorSetRGB(0xAC, 0xAC, 0xAD),
        .chevron = SkColorSetRGB(0x7C, 0x7C, 0x7D),
        .disabled_glyph = SkColorSetRGB(0xBD, 0xBD, 0xBF),
        .row_label = SkColorSetRGB(0xAC, 0xAC, 0xAD),
        .font_card = SK_ColorWHITE,
        .font_glyph = SkColorSetRGB(0x99, 0x99, 0x99),
        .font_selected = SkColorSetRGB(0xD9, 0xD9, 0xD9),
        .font_selected_glyph = SkColorSetRGB(0x8C, 0x8C, 0x8C),
        .card = SkColorSetRGB(0xEE, 0xEE, 0xEF),
        .shadow = SkColorSetA(SK_ColorBLACK, 0x33),
        .warning = SkColorSetRGB(0xFF, 0x5A, 0x5F),
        .segment_selected = SkColorSetRGB(0xC8, 0xC8, 0xC8),
        .segment_idle = SkColorSetRGB(0xE4, 0xE4, 0xE4),
        .code_background = SK_ColorWHITE,
        .primary_fill = SkColorSetRGB(0x33, 0x33, 0x33),
        .primary_text = SK_ColorWHITE,
    };
  }
  // Open choice: the light structure on macOS dark materials.
  return Palette{
      .header = SkColorSetRGB(0x2B, 0x2B, 0x2E),
      .hairline = SkColorSetRGB(0x3A, 0x3A, 0x3E),
      .body = SkColorSetRGB(0x1F, 0x1F, 0x22),
      .button = SkColorSetRGB(0x34, 0x34, 0x38),
      .button_hover = SkColorSetRGB(0x3C, 0x3C, 0x40),
      .button_pressed = SkColorSetRGB(0x44, 0x44, 0x48),
      .button_on = SkColorSetRGB(0xE8, 0xE8, 0xEA),
      .advanced_on = SkColorSetRGB(0xD0, 0xD0, 0xD3),
      .on_glyph = SkColorSetRGB(0x1F, 0x1F, 0x22),
      .label = SkColorSetRGB(0xE5, 0xE5, 0xE7),
      .title = SkColorSetRGB(0xF2, 0xF2, 0xF4),
      .header_glyph = SkColorSetRGB(0x8E, 0x8E, 0x93),
      .chevron = SkColorSetRGB(0xA0, 0xA0, 0xA5),
      .disabled_glyph = SkColorSetRGB(0x5C, 0x5C, 0x60),
      .row_label = SkColorSetRGB(0x9A, 0x9A, 0x9F),
      .font_card = SkColorSetRGB(0x2A, 0x2A, 0x2D),
      .font_glyph = SkColorSetRGB(0x9A, 0x9A, 0x9F),
      .font_selected = SkColorSetRGB(0x48, 0x48, 0x4C),
      .font_selected_glyph = SkColorSetRGB(0xE5, 0xE5, 0xE7),
      .card = SkColorSetRGB(0x2C, 0x2C, 0x2F),
      .shadow = SkColorSetA(SK_ColorBLACK, 0x66),
      .warning = SkColorSetRGB(0xFF, 0x6B, 0x70),
      .segment_selected = SkColorSetRGB(0x55, 0x55, 0x5A),
      .segment_idle = SkColorSetRGB(0x36, 0x36, 0x3A),
      .code_background = SkColorSetRGB(0x1A, 0x1A, 0x1C),
      .primary_fill = SkColorSetRGB(0xE8, 0xE8, 0xEA),
      .primary_text = SkColorSetRGB(0x1F, 0x1F, 0x22),
  };
}

OpenBoostEditorView::OpenBoostEditorView(Callbacks callbacks,
                                         const Boost& boost,
                                         bool zap_armed,
                                         bool dark)
    : callbacks_(std::move(callbacks)),
      boost_(boost),
      wheel_(BoostWheelState::FromColor(boost.color)),
      palette_(PaletteFor(dark)),
      dark_(dark),
      zap_armed_(zap_armed),
      zap_count_(static_cast<int>(boost.zapped_elements.size())) {
  // Every edit addresses one Boost id from the start: a new Boost gets its
  // id here and is created by its first commit.
  if (boost_.id.empty()) {
    boost_.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  }
  if (boost_.name.empty()) {
    boost_.name = "My Boost";
  }
  SetBorder(views::CreateEmptyBorder(gfx::Insets(m::kShadowMargin)));
  GetViewAccessibility().SetRole(ax::mojom::Role::kDialog);
  GetViewAccessibility().SetName(u"Boost editor");
  AddAccelerator(ui::Accelerator(ui::VKEY_ESCAPE, ui::EF_NONE));

  for (const BoostEditorFont& font : BoostEditorFonts()) {
    font_samples_.push_back(
        font.family.empty()
            ? secondary::FontOfSize(13)
            : gfx::FontList(gfx::Font(font.family, 13)));
  }
  BuildSimpleControls();
  BuildCodeControls();
  SetDark(dark);
  UpdateVisibility();
  UpdateTooltips();
}

OpenBoostEditorView::~OpenBoostEditorView() {
  if (prompt_field_) {
    prompt_field_->set_controller(nullptr);
  }
  if (code_area_) {
    code_area_->set_controller(nullptr);
  }
}

PaintedButton* OpenBoostEditorView::AddButton(
    const std::u16string& name,
    base::RepeatingCallback<void(gfx::Canvas*, const gfx::Rect&, bool)>
        painter,
    base::RepeatingClosure on_press) {
  return AddChildView(std::make_unique<PaintedButton>(
      std::move(on_press), std::move(painter), name));
}

void OpenBoostEditorView::BuildSimpleControls() {
  auto self = base::Unretained(this);
  // Header.
  close_button_ = AddButton(
      u"Close",
      base::BindRepeating(
          [](OpenBoostEditorView* v, gfx::Canvas* canvas,
             const gfx::Rect& bounds, bool hovered) {
            PaintCircleX(canvas, gfx::RectF(bounds).CenterPoint(), 7.f,
                         hovered ? v->palette_.chevron
                                 : v->palette_.header_glyph,
                         v->palette_.header);
          },
          self),
      base::BindRepeating(
          [](OpenBoostEditorView* v) {
            if (v->callbacks_.on_close) {
              v->callbacks_.on_close.Run();
            }
          },
          self));
  name_button_ = AddButton(
      u"Boost menu",
      base::BindRepeating(&OpenBoostEditorView::PaintHeaderName, self),
      base::BindRepeating(&OpenBoostEditorView::ShowBoostMenu, self));
  undo_button_ = AddButton(
      u"Undo",
      base::BindRepeating(
          [](OpenBoostEditorView* v, gfx::Canvas* canvas,
             const gfx::Rect& bounds, bool hovered) {
            const SkColor color =
                v->undo_stack_.empty()
                    ? v->palette_.disabled_glyph
                    : (hovered ? v->palette_.chevron
                               : v->palette_.header_glyph);
            const gfx::RectF box(gfx::RectF(bounds).CenterPoint().x() - 8.f,
                                 gfx::RectF(bounds).CenterPoint().y() - 8.f,
                                 16.f, 16.f);
            Symbol(canvas, "arrow.counterclockwise", 15.f, box, color, [&] {
              secondary::PaintGlyph(canvas, secondary::Glyph::kUndo, box,
                                    color);
            });
          },
          self),
      base::BindRepeating(&OpenBoostEditorView::Undo, self));

  // Color pad.
  wheel_view_ = AddChildView(std::make_unique<BoostColorWheelView>(
      base::BindRepeating(&OpenBoostEditorView::OnWheelChanged, self)));
  wheel_view_->SetState(wheel_);
  wheel_view_->SetDark(dark_);

  // Invert / Advanced / No color.
  static constexpr const char16_t* kColorButtonNames[3] = {
      u"Invert lightness", u"Advanced color", u"No color"};
  for (int i = 0; i < 3; ++i) {
    color_buttons_.push_back(AddButton(
        kColorButtonNames[i],
        base::BindRepeating(&OpenBoostEditorView::PaintColorButton, self, i),
        base::BindRepeating(
            [](OpenBoostEditorView* v, int index) {
              if (index == 0) {
                v->ToggleInvert();
              } else if (index == 1) {
                v->ToggleAdvanced();
              } else {
                v->ResetColor();
              }
            },
            self, i)));
  }

  // Font card.
  const std::vector<BoostEditorFont>& fonts = BoostEditorFonts();
  for (size_t i = 0; i < fonts.size() && i < 20; ++i) {
    font_cells_.push_back(AddButton(
        fonts[i].name,
        base::BindRepeating(&OpenBoostEditorView::PaintFontCell, self, i),
        base::BindRepeating(&OpenBoostEditorView::SelectFont, self, i)));
  }

  // Size / Case (left click cycles; Shift cycles back; right click lists).
  size_button_ = AddChildView(std::make_unique<PaintedButton>(
      base::BindRepeating(
          [](OpenBoostEditorView* v, const ui::Event& event) {
            if (event.flags() & ui::EF_RIGHT_MOUSE_BUTTON) {
              v->ShowSizeMenu();
            } else {
              v->CycleTextSize(event.IsShiftDown());
            }
          },
          self),
      base::BindRepeating(
          [](OpenBoostEditorView* v, gfx::Canvas* canvas,
             const gfx::Rect& bounds, bool hovered) {
            const double zoom = v->boost_.text_zoom;
            const bool normal = std::fabs(zoom - 1.0) < 1e-6;
            const std::u16string label =
                normal ? u"Size"
                       : base::NumberToString16(
                             static_cast<int>(std::lround(zoom * 100))) +
                             u"%";
            v->PaintTextButton(label, !normal, canvas, bounds, hovered);
          },
          self),
      u"Text size"));
  size_button_->SetTriggerableEventFlags(ui::EF_LEFT_MOUSE_BUTTON |
                                         ui::EF_RIGHT_MOUSE_BUTTON);
  case_button_ = AddChildView(std::make_unique<PaintedButton>(
      base::BindRepeating(
          [](OpenBoostEditorView* v, const ui::Event& event) {
            v->CycleTextCase(event.IsShiftDown() ||
                             (event.flags() & ui::EF_RIGHT_MOUSE_BUTTON));
          },
          self),
      base::BindRepeating(
          [](OpenBoostEditorView* v, gfx::Canvas* canvas,
             const gfx::Rect& bounds, bool hovered) {
            const int index = v->TextCaseIndex();
            v->PaintTextButton(kCaseLabels[index], index != 0, canvas, bounds,
                               hovered);
          },
          self),
      u"Text case"));
  case_button_->SetTriggerableEventFlags(ui::EF_LEFT_MOUSE_BUTTON |
                                         ui::EF_RIGHT_MOUSE_BUTTON);

  // Zap row and its armed tools.
  zap_button_ = AddButton(
      u"Zap", base::BindRepeating(&OpenBoostEditorView::PaintZapRow, self),
      base::BindRepeating(&OpenBoostEditorView::ToggleZap, self));
  zap_undo_button_ = AddButton(
      u"Undo Last Zap",
      base::BindRepeating(
          [](OpenBoostEditorView* v, gfx::Canvas* canvas,
             const gfx::Rect& bounds, bool hovered) {
            v->PaintTextButton(u"Undo", false, canvas, bounds, hovered);
          },
          self),
      base::BindRepeating(
          [](OpenBoostEditorView* v) {
            if (v->zap_count_ > 0 && v->callbacks_.on_undo_zap) {
              v->callbacks_.on_undo_zap.Run(v->boost_.id);
            }
          },
          self));
  zap_clear_button_ = AddButton(
      u"Clear All Zaps",
      base::BindRepeating(
          [](OpenBoostEditorView* v, gfx::Canvas* canvas,
             const gfx::Rect& bounds, bool hovered) {
            v->PaintTextButton(u"Clear All", false, canvas, bounds, hovered);
          },
          self),
      base::BindRepeating(
          [](OpenBoostEditorView* v) {
            if (v->zap_count_ > 0 && v->callbacks_.on_clear_zaps) {
              v->callbacks_.on_clear_zaps.Run(v->boost_.id);
            }
          },
          self));

  code_button_ = AddButton(
      u"Code", base::BindRepeating(&OpenBoostEditorView::PaintCodeRow, self),
      base::BindRepeating(
          [](OpenBoostEditorView* v) { v->SetMode(Mode::kCode); }, self));

  // Advanced card (above everything else in simple mode).
  advanced_scrim_ = AddChildView(std::make_unique<ClickCatcherView>(
      base::BindRepeating(&OpenBoostEditorView::ToggleAdvanced, self)));
  auto* card = AddChildView(std::make_unique<AdvancedCardView>());
  advanced_card_ = card;
  static constexpr double kRanges[3][2] = {{0.5, 1.5}, {0.5, 1.5}, {0.0, 2.0}};
  for (int i = 0; i < 3; ++i) {
    sliders_.push_back(AddChildView(std::make_unique<BoostEditorSliderView>(
        kSliderNames[i], kRanges[i][0], kRanges[i][1],
        base::BindRepeating(&OpenBoostEditorView::OnSliderChanged, self, i))));
  }

  // Inline text prompt (rename, custom font).
  auto field = std::make_unique<views::Textfield>();
  field->set_controller(this);
  field->SetFontList(secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM));
  field->SetBorder(views::CreateEmptyBorder(gfx::Insets::VH(2, 6)));
  prompt_field_ = AddChildView(std::move(field));

  confirm_view_ = AddChildView(std::make_unique<BoostEditorConfirmView>(
      base::BindRepeating(&OpenBoostEditorView::ShowDeleteConfirm, self,
                          false),
      base::BindRepeating(
          [](OpenBoostEditorView* v) {
            v->ShowDeleteConfirm(false);
            if (v->callbacks_.on_delete_boost) {
              v->callbacks_.on_delete_boost.Run(v->boost_.id);
            }
          },
          self)));
}

void OpenBoostEditorView::BuildCodeControls() {
  auto self = base::Unretained(this);
  back_button_ = AddButton(
      u"Back",
      base::BindRepeating(
          [](OpenBoostEditorView* v, gfx::Canvas* canvas,
             const gfx::Rect& bounds, bool hovered) {
            if (hovered) {
              secondary::FillRoundRect(canvas, gfx::RectF(bounds), 6.f,
                                       v->palette_.button);
            }
            const SkColor color = v->palette_.title;
            const gfx::RectF box(bounds.x() + 3, bounds.y(), 16,
                                 bounds.height());
            Symbol(canvas, "arrow.left", 13.f, box, color, [&] {
              secondary::PaintGlyph(canvas, secondary::Glyph::kBack, box,
                                    color);
            });
            secondary::DrawText(
                canvas, u"Back",
                secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM), color,
                gfx::Rect(bounds.x() + 26, bounds.y(), bounds.width() - 26,
                          bounds.height()),
                gfx::Canvas::TEXT_ALIGN_LEFT);
          },
          self),
      base::BindRepeating(
          [](OpenBoostEditorView* v) { v->SetMode(Mode::kSimple); }, self));
  css_segment_ = AddButton(
      u"CSS",
      base::BindRepeating(&OpenBoostEditorView::PaintSegment, self,
                          CodeTab::kCss),
      base::BindRepeating(&OpenBoostEditorView::SelectCodeTab, self,
                          CodeTab::kCss));
  js_segment_ = AddButton(
      u"JS",
      base::BindRepeating(&OpenBoostEditorView::PaintSegment, self,
                          CodeTab::kJs),
      base::BindRepeating(&OpenBoostEditorView::SelectCodeTab, self,
                          CodeTab::kJs));

  auto area = std::make_unique<views::Textarea>();
  area->set_controller(this);
  area->SetFontList(gfx::FontList(
      {"Menlo", "SF Mono", "Consolas", "DejaVu Sans Mono", "monospace"},
      gfx::Font::NORMAL, m::kCodeFont, gfx::Font::Weight::NORMAL));
  area->SetBorder(views::CreateEmptyBorder(
      gfx::Insets::VH(m::kCodeInsetY, m::kCodeInsetX)));
  area->SetBackgroundEnabled(false);
  area->GetViewAccessibility().SetName(u"Boost code");
  code_area_ = AddChildView(std::move(area));

  code_reset_button_ = AddButton(
      u"Reset",
      base::BindRepeating(&OpenBoostEditorView::PaintCodeButton, self, false,
                          std::u16string(u"Reset")),
      base::BindRepeating(&OpenBoostEditorView::ResetCode, self));
  code_apply_button_ = AddButton(
      u"Apply",
      base::BindRepeating(&OpenBoostEditorView::PaintCodeButton, self, true,
                          std::u16string(u"Apply")),
      base::BindRepeating(&OpenBoostEditorView::ApplyCode, self));
}

void OpenBoostEditorView::UpdateVisibility() {
  const bool simple = mode_ == Mode::kSimple;
  for (views::View* view :
       std::initializer_list<views::View*>{close_button_, name_button_,
                                           undo_button_, wheel_view_,
                                           size_button_, case_button_,
                                           zap_button_, code_button_}) {
    view->SetVisible(simple);
  }
  for (auto& button : color_buttons_) {
    button->SetVisible(simple);
  }
  for (auto& cell : font_cells_) {
    cell->SetVisible(simple);
  }
  zap_undo_button_->SetVisible(simple && zap_armed_);
  zap_clear_button_->SetVisible(simple && zap_armed_);
  zap_undo_button_->SetEnabled(zap_count_ > 0);
  zap_clear_button_->SetEnabled(zap_count_ > 0);
  const bool advanced = simple && advanced_open_;
  advanced_scrim_->SetVisible(advanced);
  advanced_card_->SetVisible(advanced);
  for (auto& slider : sliders_) {
    slider->SetVisible(advanced);
  }
  prompt_field_->SetVisible(simple && prompt_ != TextPrompt::kNone);
  confirm_view_->SetVisible(simple && confirming_delete_);

  const bool code = mode_ == Mode::kCode;
  for (views::View* view : std::initializer_list<views::View*>{
           back_button_, css_segment_, js_segment_, code_area_,
           code_reset_button_, code_apply_button_}) {
    view->SetVisible(code);
  }
  color_buttons_[2]->SetEnabled(!wheel_.IsIdentity());
  InvalidateLayout();
  SchedulePaint();
}

void OpenBoostEditorView::UpdateTooltips() {
  name_button_->SetTooltipText(
      base::UTF8ToUTF16(boost_.name) +
      (boost_.host_pattern.empty()
           ? std::u16string()
           : u" — " + base::UTF8ToUTF16(boost_.host_pattern)));
  size_button_->SetTooltipText(u"Text size (right-click for all sizes)");
  case_button_->SetTooltipText(
      std::u16string(u"Text case: ") + kCaseNames[TextCaseIndex()]);
  zap_button_->SetTooltipText(
      zap_armed_ ? u"Done zapping (Esc)"
                 : u"Zap: click elements on the page to hide them");
  color_buttons_[0]->SetTooltipText(u"Invert lightness");
  color_buttons_[1]->SetTooltipText(u"Contrast, brightness and saturation");
  color_buttons_[2]->SetTooltipText(u"Remove color");
}

// --- Public API --------------------------------------------------------------

void OpenBoostEditorView::SetBoost(const Boost& boost) {
  if (boost.id != boost_.id) {
    // A different Boost: start over.
    boost_ = boost;
    wheel_ = BoostWheelState::FromColor(boost.color);
    undo_stack_.clear();
    css_dirty_ = js_dirty_ = false;
    pending_js_.clear();
  } else {
    // Zaps always follow the store.
    boost_.zapped_elements = boost.zapped_elements;
    if (!interacting_) {
      const std::string name = boost_.name;
      const std::string css = boost_.custom_css;
      boost_.enabled = boost.enabled;
      boost_.host_pattern = boost.host_pattern;
      boost_.font_family = boost.font_family;
      boost_.text_zoom = boost.text_zoom;
      boost_.text_transform = boost.text_transform;
      boost_.custom_js = boost.custom_js;
      boost_.created_at = boost.created_at;
      boost_.modified_at = boost.modified_at;
      boost_.profile_id = boost.profile_id;
      boost_.name = prompt_ == TextPrompt::kRename ? name : boost.name;
      boost_.custom_css =
          (css_dirty_ || css_save_timer_.IsRunning()) ? css : boost.custom_css;
      // Keep the wheel the user set unless the stored color differs (a
      // filter has several wheel positions; FromColor picks one).
      const BoostColorAdjustment mine = wheel_.ToColor();
      const BoostColorAdjustment& theirs = boost.color;
      const bool same =
          mine.enabled == theirs.enabled &&
          (!mine.enabled ||
           (std::fabs(mine.hue_degrees - theirs.hue_degrees) < 0.01 &&
            std::fabs(mine.saturation - theirs.saturation) < 0.001 &&
            std::fabs(mine.lightness - theirs.lightness) < 0.001 &&
            std::fabs(mine.contrast - theirs.contrast) < 0.001 &&
            mine.invert == theirs.invert));
      boost_.color = theirs;
      if (!same) {
        wheel_ = BoostWheelState::FromColor(theirs);
      }
    }
  }
  if (!zap_armed_) {
    zap_count_ = static_cast<int>(boost_.zapped_elements.size());
  }
  wheel_view_->SetState(wheel_);
  if (mode_ == Mode::kCode && !code_area_->HasFocus()) {
    code_area_->SetText(base::UTF8ToUTF16(
        code_tab_ == CodeTab::kCss
            ? boost_.custom_css
            : (js_dirty_ ? base::UTF16ToUTF8(pending_js_) : boost_.custom_js)));
  }
  UpdateVisibility();
  UpdateTooltips();
  SchedulePaint();
}

void OpenBoostEditorView::SetZapState(bool armed, int zap_count) {
  const bool layout_changed = armed != zap_armed_;
  zap_armed_ = armed;
  zap_count_ = std::max(0, zap_count);
  UpdateVisibility();
  UpdateTooltips();
  if (layout_changed) {
    PreferredSizeChanged();
  }
  SchedulePaint();
}

void OpenBoostEditorView::SetDark(bool dark) {
  dark_ = dark;
  palette_ = PaletteFor(dark);
  wheel_view_->SetDark(dark);
  confirm_view_->SetDark(dark);
  static_cast<AdvancedCardView*>(advanced_card_.get())
      ->SetColors(palette_.card, palette_.shadow);
  for (auto& slider : sliders_) {
    slider->SetColors(palette_.label,
                      dark ? SkColorSetRGB(0x48, 0x48, 0x4C)
                           : SkColorSetRGB(0xD9, 0xD9, 0xD9),
                      dark ? SkColorSetRGB(0xA0, 0xA0, 0xA5)
                           : SkColorSetRGB(0x9A, 0x9A, 0x9A));
  }
  SchedulePaint();
  for (views::View* child : children()) {
    child->SchedulePaint();
  }
}

void OpenBoostEditorView::SetBoostsGloballyEnabled(bool enabled) {
  if (enabled == global_enabled_) {
    return;
  }
  global_enabled_ = enabled;
  PreferredSizeChanged();
  InvalidateLayout();
  SchedulePaint();
}

void OpenBoostEditorView::ShowNotice(const std::u16string& text) {
  const bool had_banner = BannerShift() > 0;
  notice_ = text;
  notice_timer_.Start(FROM_HERE, kNoticeLifetime,
                      base::BindOnce(
                          [](OpenBoostEditorView* v) {
                            const bool had = v->BannerShift() > 0;
                            v->notice_.clear();
                            if (had != (v->BannerShift() > 0)) {
                              v->PreferredSizeChanged();
                            }
                            v->InvalidateLayout();
                            v->SchedulePaint();
                          },
                          base::Unretained(this)));
  if (had_banner != (BannerShift() > 0)) {
    PreferredSizeChanged();
  }
  InvalidateLayout();
  SchedulePaint();
}

void OpenBoostEditorView::SetMode(Mode mode) {
  if (mode == mode_) {
    return;
  }
  if (mode_ == Mode::kCode) {
    // Leaving code mode saves pending CSS (JavaScript waits for Apply).
    if (css_save_timer_.IsRunning()) {
      css_save_timer_.Stop();
      CommitCss();
    }
  }
  mode_ = mode;
  advanced_open_ = false;
  confirming_delete_ = false;
  if (prompt_ != TextPrompt::kNone) {
    EndPrompt(false);
  }
  if (mode_ == Mode::kCode) {
    SelectCodeTab(code_tab_);
  }
  UpdateVisibility();
  PreferredSizeChanged();
  if (mode_ == Mode::kCode) {
    code_area_->RequestFocus();
  } else {
    code_button_->RequestFocus();
  }
}

gfx::Rect OpenBoostEditorView::PanelBounds() const {
  return GetContentsBounds();
}

int OpenBoostEditorView::BannerShift() const {
  return (mode_ == Mode::kSimple && (!global_enabled_ || !notice_.empty()))
             ? m::kBannerHeight
             : 0;
}

int OpenBoostEditorView::ZapToolsShift() const {
  return (mode_ == Mode::kSimple && zap_armed_) ? m::kZapToolsHeight : 0;
}

gfx::Rect OpenBoostEditorView::P(const gfx::Rect& panel_rect) const {
  gfx::Rect r = panel_rect;
  int dy = 0;
  if (r.y() >= m::kHeaderHeight) {
    dy += BannerShift();
  }
  if (r.y() >= m::kCode.y()) {
    dy += ZapToolsShift();
  }
  r.Offset(m::kShadowMargin, m::kShadowMargin + dy);
  return r;
}

gfx::Size OpenBoostEditorView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  gfx::Size panel = mode_ == Mode::kCode
                        ? gfx::Size(m::kCodeWidth, m::kCodeHeight)
                        : gfx::Size(m::kWidth, m::kHeight + BannerShift() +
                                                   ZapToolsShift());
  panel.Enlarge(2 * m::kShadowMargin, 2 * m::kShadowMargin);
  return panel;
}

void OpenBoostEditorView::Layout(PassKey) {
  const gfx::Rect panel = PanelBounds();
  if (mode_ == Mode::kSimple) {
    close_button_->SetBoundsRect(P(m::kDone));
    name_button_->SetBoundsRect(P(m::kName));
    undo_button_->SetBoundsRect(P(m::kUndo));
    wheel_view_->SetBoundsRect(P(m::kRing));
    for (int i = 0; i < 3; ++i) {
      color_buttons_[i]->SetBoundsRect(P(m::kColorButtons[i]));
    }
    for (size_t i = 0; i < font_cells_.size(); ++i) {
      const int col = static_cast<int>(i % 5);
      const int row = static_cast<int>(i / 5);
      font_cells_[i]->SetBoundsRect(P(gfx::Rect(m::kFontColumns[col],
                                                m::kFontRows[row], m::kFontCell,
                                                m::kFontCell)));
    }
    size_button_->SetBoundsRect(P(m::kSize));
    case_button_->SetBoundsRect(P(m::kCase));
    zap_button_->SetBoundsRect(P(m::kZap));
    zap_undo_button_->SetBoundsRect(P(m::kZapUndo));
    zap_clear_button_->SetBoundsRect(P(m::kZapClear));
    code_button_->SetBoundsRect(P(m::kCode));

    advanced_scrim_->SetBoundsRect(panel);
    const gfx::Rect card = P(m::kAdvancedCard);
    advanced_card_->SetBoundsRect(card);
    // Caret over the Advanced button's center.
    static_cast<AdvancedCardView*>(advanced_card_.get())
        ->SetCaretX(P(m::kColorButtons[1]).CenterPoint().x() - card.x());
    for (int i = 0; i < 3; ++i) {
      const int top = m::kAdvancedLabelY[i] - 14;
      const int height = m::kAdvancedSliderY[i] - top + m::kSliderHeight;
      sliders_[i]->SetBoundsRect(
          P(gfx::Rect(m::kInset, top, m::kSliderWidth, height)));
    }
    if (prompt_ == TextPrompt::kRename) {
      prompt_field_->SetBoundsRect(P(gfx::Rect(40, 8, 103, 24)));
    } else if (prompt_ == TextPrompt::kCustomFont) {
      prompt_field_->SetBoundsRect(
          P(gfx::Rect(m::kFontCard.x() + 4, m::kFontCard.y() + 4,
                      m::kFontCard.width() - 8, 26)));
    }
    confirm_view_->SetBoundsRect(panel);
  } else {
    const int x0 = panel.x();
    const int y0 = panel.y();
    back_button_->SetBoundsRect(m::kBack + gfx::Vector2d(x0, y0));
    const int seg_x =
        x0 + (panel.width() - 2 * m::kSegmentWidth) / 2;
    css_segment_->SetBoundsRect(gfx::Rect(seg_x, y0 + m::kSegmentTop,
                                          m::kSegmentWidth,
                                          m::kSegmentHeight));
    js_segment_->SetBoundsRect(gfx::Rect(seg_x + m::kSegmentWidth,
                                         y0 + m::kSegmentTop,
                                         m::kSegmentWidth, m::kSegmentHeight));
    const int notice =
        code_tab_ == CodeTab::kJs ? m::kCodeNoticeHeight : 0;
    const int top = y0 + m::kHeaderHeight + notice;
    const int bottom = panel.bottom() - m::kCodeBottomBar;
    code_area_->SetBoundsRect(
        gfx::Rect(x0, top, panel.width(), std::max(0, bottom - top)));
    const int button_y = bottom + m::kCodeBarTop;
    const int button_w = 96;
    code_reset_button_->SetBoundsRect(gfx::Rect(
        x0 + m::kCodeBarInset, button_y, button_w, m::kCodeButton));
    code_apply_button_->SetBoundsRect(
        gfx::Rect(panel.right() - m::kCodeBarInset - button_w, button_y,
                  button_w, m::kCodeButton));
  }
}

// --- Painting ----------------------------------------------------------------

void OpenBoostEditorView::OnPaint(gfx::Canvas* canvas) {
  PaintPanel(canvas);
}

void OpenBoostEditorView::PaintPanel(gfx::Canvas* canvas) {
  const gfx::RectF panel(PanelBounds());
  secondary::FillRoundRectWithShadow(canvas, panel, m::kCornerRadius,
                                     palette_.body, palette_.shadow, 3.f,
                                     12.f);
  gfx::ScopedCanvas scoped(canvas);
  canvas->ClipPath(RoundRectPath(panel, m::kCornerRadius), true);

  // Header and hairline.
  canvas->DrawRect(
      gfx::RectF(panel.x(), panel.y(), panel.width(), m::kHeaderHeight),
      FillFlags(palette_.header));
  canvas->DrawRect(gfx::RectF(panel.x(), panel.y() + m::kHeaderHeight - 1,
                              panel.width(), 1),
                   FillFlags(palette_.hairline));

  if (mode_ == Mode::kSimple) {
    if (const int banner = BannerShift(); banner > 0) {
      const gfx::Rect rect(panel.x(), panel.y() + m::kHeaderHeight,
                           panel.width(), banner);
      canvas->DrawRect(gfx::RectF(rect),
                       FillFlags(SkColorSetA(palette_.warning, 0x1F)));
      const std::u16string text =
          !notice_.empty() ? notice_ : u"Boosts are off in Settings";
      secondary::DrawText(canvas, text,
                          secondary::FontOfSize(11, gfx::Font::Weight::MEDIUM),
                          palette_.warning,
                          gfx::Rect(rect.x() + 10, rect.y(),
                                    rect.width() - 20, rect.height()),
                          gfx::Canvas::TEXT_ALIGN_CENTER);
    }
    secondary::FillRoundRectWithShadow(
        canvas, gfx::RectF(P(m::kFontCard)), m::kFontCardRadius,
        palette_.font_card, SkColorSetA(SK_ColorBLACK, dark_ ? 0x33 : 0x0F),
        1.f, 8.f);
  } else {
    if (code_tab_ == CodeTab::kJs) {
      const gfx::Rect notice(panel.x(), panel.y() + m::kHeaderHeight,
                             panel.width(), m::kCodeNoticeHeight);
      canvas->DrawRect(gfx::RectF(notice), FillFlags(palette_.header));
      canvas->DrawRect(gfx::RectF(notice.x(), notice.bottom() - 1,
                                  notice.width(), 1),
                       FillFlags(palette_.hairline));
      secondary::DrawText(
          canvas,
          u"JavaScript in a Boost runs on this site like the site’s own "
          u"code. It runs when you click Apply.",
          secondary::FontOfSize(11), palette_.chevron,
          gfx::Rect(notice.x() + 12, notice.y(), notice.width() - 24,
                    notice.height()),
          gfx::Canvas::TEXT_ALIGN_LEFT);
    }
    const int bar_top = panel.bottom() - m::kCodeBottomBar;
    const int code_top = panel.y() + m::kHeaderHeight +
                         (code_tab_ == CodeTab::kJs ? m::kCodeNoticeHeight : 0);
    canvas->DrawRect(gfx::RectF(panel.x(), code_top, panel.width(),
                                bar_top - code_top),
                     FillFlags(palette_.code_background));
    canvas->DrawRect(gfx::RectF(panel.x(), bar_top, panel.width(), 1),
                     FillFlags(palette_.hairline));
    const std::u16string hint =
        code_tab_ == CodeTab::kCss
            ? (css_dirty_ || css_save_timer_.IsRunning() ? u"Saving…"
                                                          : u"CSS updates live")
            : (js_dirty_ ? u"Not applied yet" : u"Applied");
    const int hint_x = panel.x() + m::kCodeBarInset + 96 + m::kCodeBarGap;
    secondary::DrawText(
        canvas, hint, secondary::FontOfSize(11), palette_.chevron,
        gfx::Rect(hint_x, bar_top + m::kCodeBarTop,
                  panel.width() - 2 * (m::kCodeBarInset + 96 + m::kCodeBarGap),
                  m::kCodeButton),
        gfx::Canvas::TEXT_ALIGN_CENTER);
  }
  // Panel outline for definition on white pages.
  canvas->DrawPath(
      RoundRectPath(gfx::RectF(panel.x() + 0.5f, panel.y() + 0.5f,
                               panel.width() - 1.f, panel.height() - 1.f),
                    m::kCornerRadius - 0.5f),
      StrokeFlags(dark_ ? SkColorSetA(SK_ColorWHITE, 0x1A)
                        : SkColorSetA(SK_ColorBLACK, 0x14),
                  1.f));
}

void OpenBoostEditorView::PaintHeaderName(gfx::Canvas* canvas,
                                          const gfx::Rect& bounds,
                                          bool hovered) {
  if (hovered) {
    secondary::FillRoundRect(canvas, gfx::RectF(bounds), 6.f,
                             SkColorSetA(dark_ ? SK_ColorWHITE : SK_ColorBLACK,
                                         0x0D));
  }
  const gfx::FontList font =
      secondary::FontOfSize(13, gfx::Font::Weight::SEMIBOLD);
  const int chevron_w = 11;
  const int gap = 6;
  std::u16string name = base::UTF8ToUTF16(boost_.name);
  if (!boost_.enabled) {
    name += u" (Off)";
  }
  const int max_text = bounds.width() - chevron_w - gap - 4;
  const int text_w = std::min(max_text, secondary::TextWidth(name, font));
  const int x = bounds.x() + (bounds.width() - text_w - gap - chevron_w) / 2;
  secondary::DrawText(canvas, name, font,
                      boost_.enabled ? palette_.title : palette_.chevron,
                      gfx::Rect(x, bounds.y(), text_w, bounds.height()),
                      gfx::Canvas::TEXT_ALIGN_LEFT);
  const gfx::RectF chevron(x + text_w + gap, bounds.y(), chevron_w,
                           bounds.height());
  Symbol(canvas, "chevron.down", 11.f, chevron, palette_.chevron, [&] {
    secondary::PaintGlyph(canvas, secondary::Glyph::kChevronDown, chevron,
                          palette_.chevron);
  });
}

void OpenBoostEditorView::PaintColorButton(int index,
                                           gfx::Canvas* canvas,
                                           const gfx::Rect& bounds,
                                           bool hovered) {
  const bool on = (index == 0 && wheel_.invert) ||
                  (index == 1 && advanced_open_);
  const bool enabled = index != 2 || !wheel_.IsIdentity();
  SkColor fill = palette_.button;
  if (on) {
    fill = index == 0 ? palette_.button_on : palette_.advanced_on;
  } else if (hovered && enabled) {
    fill = palette_.button_hover;
  }
  secondary::FillRoundRect(canvas, gfx::RectF(bounds), m::kButtonRadius, fill);
  const SkColor glyph =
      on ? palette_.on_glyph
         : (enabled ? palette_.label : palette_.disabled_glyph);
  const gfx::RectF box(gfx::RectF(bounds).CenterPoint().x() - 9.f,
                       gfx::RectF(bounds).CenterPoint().y() - 9.f, 18.f, 18.f);
  switch (index) {
    case 0:
      Symbol(canvas, on ? "lightbulb.fill" : "lightbulb", 15.f, box, glyph,
             [&] { PaintLightbulb(canvas, box, glyph, on); });
      break;
    case 1:
      Symbol(canvas, "slider.horizontal.3", 14.f, box, glyph,
             [&] { PaintSliders(canvas, box, glyph); });
      break;
    default:
      Symbol(canvas, "nosign", 14.f, box, glyph,
             [&] { PaintNoSign(canvas, box, glyph); });
      break;
  }
}

void OpenBoostEditorView::PaintFontCell(size_t index,
                                        gfx::Canvas* canvas,
                                        const gfx::Rect& bounds,
                                        bool hovered) {
  const bool selected = static_cast<int>(index) == FontIndex();
  if (selected) {
    canvas->DrawCircle(gfx::RectF(bounds).CenterPoint(), m::kFontCell / 2.f,
                       FillFlags(palette_.font_selected));
  } else if (hovered) {
    canvas->DrawCircle(gfx::RectF(bounds).CenterPoint(), m::kFontCell / 2.f,
                       FillFlags(dark_ ? SkColorSetRGB(0x3A, 0x3A, 0x3E)
                                       : SkColorSetRGB(0xEC, 0xEC, 0xEC)));
  }
  if (index < font_samples_.size()) {
    secondary::DrawText(
        canvas, u"Aa", font_samples_[index],
        selected ? palette_.font_selected_glyph : palette_.font_glyph, bounds,
        gfx::Canvas::TEXT_ALIGN_CENTER);
  }
}

void OpenBoostEditorView::PaintTextButton(const std::u16string& label,
                                          bool on,
                                          gfx::Canvas* canvas,
                                          const gfx::Rect& bounds,
                                          bool hovered) {
  SkColor fill = on ? palette_.button_pressed
                    : (hovered ? palette_.button_hover : palette_.button);
  secondary::FillRoundRect(canvas, gfx::RectF(bounds), m::kButtonRadius, fill);
  secondary::DrawText(canvas, label,
                      secondary::FontOfSize(14, gfx::Font::Weight::SEMIBOLD),
                      palette_.label, bounds, gfx::Canvas::TEXT_ALIGN_CENTER);
}

void OpenBoostEditorView::PaintZapRow(gfx::Canvas* canvas,
                                      const gfx::Rect& bounds,
                                      bool hovered) {
  const SkColor fill =
      zap_armed_ ? (hovered ? secondary::Mix(palette_.button_on,
                                             palette_.body, 0.12f)
                            : palette_.button_on)
                 : (hovered ? palette_.button_hover : palette_.button);
  secondary::FillRoundRect(canvas, gfx::RectF(bounds), m::kButtonRadius, fill);
  const SkColor text = zap_armed_ ? palette_.on_glyph : palette_.row_label;
  const gfx::FontList font =
      secondary::FontOfSize(14, gfx::Font::Weight::SEMIBOLD);
  secondary::DrawText(
      canvas, u"Zap", font, text,
      gfx::Rect(bounds.x() + m::kRowLabelInset, bounds.y(), 80, bounds.height()),
      gfx::Canvas::TEXT_ALIGN_LEFT);
  const gfx::RectF glyph(bounds.right() - m::kRowGlyphTrailingInset - 14,
                         bounds.y(), 14, bounds.height());
  if (zap_armed_ || zap_count_ == 0) {
    Symbol(canvas, "bolt.fill", 15.f, glyph, text, [&] {
      secondary::PaintGlyph(canvas, secondary::Glyph::kBolt, glyph, text);
    });
  }
  if (zap_count_ > 0) {
    // Not armed: the count replaces the bolt (editor-zap-count frame).
    // Armed: "N zapped" before the bolt.
    const std::u16string count =
        zap_armed_ ? base::NumberToString16(zap_count_) + u" zapped"
                   : base::NumberToString16(zap_count_);
    const int right = zap_armed_ ? static_cast<int>(glyph.x()) - 6
                                 : bounds.right() - m::kRowGlyphTrailingInset;
    secondary::DrawText(canvas, count,
                        secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM),
                        zap_armed_ ? SkColorSetA(text, 0xB3) : text,
                        gfx::Rect(right - 70, bounds.y(), 70, bounds.height()),
                        gfx::Canvas::TEXT_ALIGN_RIGHT);
  }
}

void OpenBoostEditorView::PaintCodeRow(gfx::Canvas* canvas,
                                       const gfx::Rect& bounds,
                                       bool hovered) {
  secondary::FillRoundRect(canvas, gfx::RectF(bounds), m::kButtonRadius,
                           hovered ? palette_.button_hover : palette_.button);
  const bool has_code = !boost_.custom_css.empty() || !boost_.custom_js.empty();
  const SkColor text = has_code ? palette_.label : palette_.row_label;
  secondary::DrawText(
      canvas, u"Code", secondary::FontOfSize(14, gfx::Font::Weight::SEMIBOLD),
      text,
      gfx::Rect(bounds.x() + m::kRowLabelInset, bounds.y(), 80, bounds.height()),
      gfx::Canvas::TEXT_ALIGN_LEFT);
  const gfx::RectF glyph(bounds.right() - m::kRowGlyphTrailingInset - 16,
                         bounds.y(), 18, bounds.height());
  Symbol(canvas, "curlybraces", 15.f, glyph, text, [&] {
    secondary::DrawText(canvas, u"{ }", secondary::FontOfSize(14), text,
                        gfx::ToEnclosingRect(glyph),
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  });
}

void OpenBoostEditorView::PaintSegment(CodeTab tab,
                                       gfx::Canvas* canvas,
                                       const gfx::Rect& bounds,
                                       bool hovered) {
  const bool selected = tab == code_tab_;
  SkColor fill = selected ? palette_.segment_selected : palette_.segment_idle;
  if (hovered && !selected) {
    fill = secondary::Mix(fill, palette_.segment_selected, 0.4f);
  }
  // One rounded pill split in two: round only the outer corners.
  const gfx::RectF r(bounds);
  SkRRect rrect;
  const float rad = m::kSegmentRadius;
  const SkVector radii[4] = {
      tab == CodeTab::kCss ? SkVector{rad, rad} : SkVector{0, 0},
      tab == CodeTab::kJs ? SkVector{rad, rad} : SkVector{0, 0},
      tab == CodeTab::kJs ? SkVector{rad, rad} : SkVector{0, 0},
      tab == CodeTab::kCss ? SkVector{rad, rad} : SkVector{0, 0}};
  rrect.setRectRadii(gfx::RectFToSkRect(r), radii);
  SkPathBuilder path;
  path.addRRect(rrect);
  canvas->DrawPath(path.detach(), FillFlags(fill));
  secondary::DrawText(canvas, tab == CodeTab::kCss ? u"CSS" : u"JS",
                      secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM),
                      palette_.title, bounds, gfx::Canvas::TEXT_ALIGN_CENTER);
}

void OpenBoostEditorView::PaintCodeButton(bool primary,
                                          const std::u16string& label,
                                          gfx::Canvas* canvas,
                                          const gfx::Rect& bounds,
                                          bool hovered) {
  SkColor fill = primary ? palette_.primary_fill : palette_.button;
  if (hovered) {
    fill = secondary::Mix(fill, primary ? palette_.body : SK_ColorBLACK,
                          primary ? 0.12f : 0.05f);
  }
  secondary::FillRoundRect(canvas, gfx::RectF(bounds), 8.f, fill);
  secondary::DrawText(canvas, label,
                      secondary::FontOfSize(13, gfx::Font::Weight::SEMIBOLD),
                      primary ? palette_.primary_text : palette_.label, bounds,
                      gfx::Canvas::TEXT_ALIGN_CENTER);
}

// --- State helpers -----------------------------------------------------------

int OpenBoostEditorView::FontIndex() const {
  const std::vector<BoostEditorFont>& fonts = BoostEditorFonts();
  if (!boost_.font_family || boost_.font_family->empty()) {
    return 0;
  }
  const std::string current = base::ToLowerASCII(*boost_.font_family);
  for (size_t i = 1; i < fonts.size(); ++i) {
    const std::string family = base::ToLowerASCII(fonts[i].family);
    if (current == base::ToLowerASCII(fonts[i].css) ||
        current == family ||
        base::StartsWith(current, family + ",")) {
      return static_cast<int>(i);
    }
  }
  return -1;  // A custom font.
}

int OpenBoostEditorView::TextSizeIndex() const {
  for (size_t i = 0; i < kCycleSizes.size(); ++i) {
    if (std::fabs(boost_.text_zoom - kCycleSizes[i]) < 1e-6) {
      return static_cast<int>(i);
    }
  }
  return 1;
}

int OpenBoostEditorView::TextCaseIndex() const {
  for (size_t i = 0; i < kCases.size(); ++i) {
    if (boost_.text_transform == kCases[i]) {
      return static_cast<int>(i);
    }
  }
  return 0;
}

// --- Edits -------------------------------------------------------------------

void OpenBoostEditorView::PushUndo() {
  undo_stack_.push_back(boost_);
  if (undo_stack_.size() > kMaxUndo) {
    undo_stack_.erase(undo_stack_.begin());
  }
  undo_button_->SchedulePaint();
}

void OpenBoostEditorView::Undo() {
  if (undo_stack_.empty()) {
    return;
  }
  Boost previous = std::move(undo_stack_.back());
  undo_stack_.pop_back();
  // Zaps have their own Undo; the stored list stays.
  previous.zapped_elements = boost_.zapped_elements;
  wheel_ = BoostWheelState::FromColor(previous.color);
  ApplyDraft(std::move(previous), /*commit=*/true, /*undoable=*/false);
}

void OpenBoostEditorView::ApplyDraft(Boost updated, bool commit, bool undoable) {
  if (undoable) {
    PushUndo();
  }
  boost_ = std::move(updated);
  wheel_view_->SetState(wheel_);
  sliders_[0]->SetValue(wheel_.contrast);
  sliders_[1]->SetValue(wheel_.brightness);
  sliders_[2]->SetValue(wheel_.original_saturation);
  UpdateVisibility();
  UpdateTooltips();
  Preview();
  if (commit) {
    Commit();
  }
  SchedulePaint();
  for (views::View* child : children()) {
    child->SchedulePaint();
  }
}

void OpenBoostEditorView::Preview() {
  if (callbacks_.on_live_preview) {
    callbacks_.on_live_preview.Run(boost_);
  }
}

void OpenBoostEditorView::Commit() {
  if (callbacks_.on_commit_boost) {
    callbacks_.on_commit_boost.Run(boost_);
  }
}

void OpenBoostEditorView::SetWheel(const BoostWheelState& state,
                                   bool dragging) {
  if (!interacting_ && dragging) {
    // First event of a drag: one Undo step for the whole drag.
    PushUndo();
  }
  interacting_ = dragging;
  wheel_ = state;
  Boost updated = boost_;
  updated.color = wheel_.ToColor();
  // Drag events preview only; the release commits.
  ApplyDraft(std::move(updated), /*commit=*/!dragging, /*undoable=*/false);
}

void OpenBoostEditorView::OnWheelChanged(const BoostWheelState& state,
                                         bool dragging) {
  BoostWheelState next = wheel_;
  next.hue = state.hue;
  next.intensity = state.intensity;
  const bool was_interacting = interacting_;
  if (!dragging && !was_interacting) {
    PushUndo();  // A keyboard step.
  }
  SetWheel(next, dragging);
}

void OpenBoostEditorView::OnSliderChanged(int index,
                                          double value,
                                          bool dragging) {
  BoostWheelState next = wheel_;
  if (index == 0) {
    next.contrast = value;
  } else if (index == 1) {
    next.brightness = value;
  } else {
    next.original_saturation = value;
  }
  if (!dragging && !interacting_) {
    PushUndo();  // A keyboard step.
  }
  SetWheel(next, dragging);
}

void OpenBoostEditorView::ToggleInvert() {
  BoostWheelState next = wheel_;
  next.invert = !next.invert;
  PushUndo();
  wheel_ = next;
  Boost updated = boost_;
  updated.color = wheel_.ToColor();
  ApplyDraft(std::move(updated), true, false);
}

void OpenBoostEditorView::ToggleAdvanced() {
  advanced_open_ = !advanced_open_;
  sliders_[0]->SetValue(wheel_.contrast);
  sliders_[1]->SetValue(wheel_.brightness);
  sliders_[2]->SetValue(wheel_.original_saturation);
  UpdateVisibility();
  if (advanced_open_) {
    sliders_[0]->RequestFocus();
  }
  color_buttons_[1]->SchedulePaint();
}

void OpenBoostEditorView::ResetColor() {
  if (wheel_.IsIdentity()) {
    return;
  }
  PushUndo();
  wheel_ = BoostWheelState();
  Boost updated = boost_;
  updated.color = BoostColorAdjustment();
  ApplyDraft(std::move(updated), true, false);
}

void OpenBoostEditorView::SelectFont(size_t index) {
  const std::vector<BoostEditorFont>& fonts = BoostEditorFonts();
  if (index >= fonts.size()) {
    return;
  }
  Boost updated = boost_;
  if (fonts[index].css.empty() || static_cast<int>(index) == FontIndex()) {
    // System, or a second click on the selected font: no font override.
    updated.font_family.reset();
  } else {
    updated.font_family = fonts[index].css;
  }
  ApplyDraft(std::move(updated), true, true);
}

void OpenBoostEditorView::CycleTextSize(bool backwards) {
  const int count = static_cast<int>(kCycleSizes.size());
  const int next = (TextSizeIndex() + (backwards ? count - 1 : 1)) % count;
  Boost updated = boost_;
  updated.text_zoom = kCycleSizes[next];
  ApplyDraft(std::move(updated), true, true);
}

void OpenBoostEditorView::CycleTextCase(bool backwards) {
  const int count = static_cast<int>(kCases.size());
  const int next = (TextCaseIndex() + (backwards ? count - 1 : 1)) % count;
  Boost updated = boost_;
  updated.text_transform = kCases[next];
  ApplyDraft(std::move(updated), true, true);
}

void OpenBoostEditorView::ShowSizeMenu() {
  if (menu_runner_ && menu_runner_->IsRunning()) {
    return;
  }
  menu_model_ = std::make_unique<ui::SimpleMenuModel>(this);
  for (size_t i = 0; i < kMenuSizes.size(); ++i) {
    menu_model_->AddCheckItem(
        kCmdSizeBase + static_cast<int>(i),
        base::NumberToString16(
            static_cast<int>(std::lround(kMenuSizes[i] * 100))) +
            u"%");
  }
  menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
  for (size_t i = 0; i < kCases.size(); ++i) {
    menu_model_->AddCheckItem(kCmdCaseBase + static_cast<int>(i),
                              kCaseNames[i]);
  }
  menu_runner_ = std::make_unique<views::MenuRunner>(
      menu_model_.get(), views::MenuRunner::NO_FLAGS);
  menu_runner_->RunMenuAt(GetWidget(), nullptr,
                          size_button_->GetBoundsInScreen(),
                          views::MenuAnchorPosition::kTopLeft,
                          ui::mojom::MenuSourceType::kMouse);
}

void OpenBoostEditorView::ToggleZap() {
  if (callbacks_.on_toggle_zap) {
    callbacks_.on_toggle_zap.Run(!zap_armed_, boost_.id);
  }
}

void OpenBoostEditorView::Shuffle() {
  PushUndo();
  BoostWheelState next = wheel_;
  next.hue = base::RandDouble() * 360.0;
  next.intensity = 0.45 + base::RandDouble() * 0.5;
  wheel_ = next;
  Boost updated = boost_;
  updated.color = wheel_.ToColor();
  const std::vector<BoostEditorFont>& fonts = BoostEditorFonts();
  const size_t font = static_cast<size_t>(
      base::RandIntInclusive(0, static_cast<int>(fonts.size()) - 1));
  if (fonts[font].css.empty()) {
    updated.font_family.reset();
  } else {
    updated.font_family = fonts[font].css;
  }
  ApplyDraft(std::move(updated), true, false);
}

void OpenBoostEditorView::ResetAll() {
  PushUndo();
  wheel_ = BoostWheelState();
  Boost updated = boost_;
  updated.color = BoostColorAdjustment();
  updated.font_family.reset();
  updated.text_zoom = 1.0;
  updated.text_transform.clear();
  updated.custom_css.clear();
  updated.custom_js.clear();
  css_dirty_ = js_dirty_ = false;
  pending_js_.clear();
  ApplyDraft(std::move(updated), true, false);
  if (zap_count_ > 0 && callbacks_.on_clear_zaps) {
    callbacks_.on_clear_zaps.Run(boost_.id);
  }
}

void OpenBoostEditorView::ShowBoostMenu() {
  if (menu_runner_ && menu_runner_->IsRunning()) {
    return;
  }
  menu_model_ = std::make_unique<ui::SimpleMenuModel>(this);
  if (!boost_.host_pattern.empty()) {
    menu_model_->AddItem(kCmdHost, base::UTF8ToUTF16(boost_.host_pattern));
    menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
  }
  menu_model_->AddItem(kCmdRename, u"Rename this Boost…");
  menu_model_->AddItem(kCmdShuffle, u"Shuffle");
  menu_model_->AddItem(kCmdToggleEnabled,
                       boost_.enabled ? u"Turn Off this Boost"
                                      : u"Turn On this Boost");
  menu_model_->AddItem(kCmdCustomFont, u"Custom Font…");
  menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
  menu_model_->AddItem(kCmdUndoZap, u"Undo Last Zap");
  menu_model_->AddItem(kCmdClearZaps, u"Clear All Zaps");
  menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
  menu_model_->AddItem(kCmdResetAll, u"Reset all Edits");
  menu_model_->AddItem(kCmdDelete, u"Delete this Boost");
  menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
  menu_model_->AddItem(kCmdShare, u"Share Boost…");
  menu_model_->AddItem(kCmdAllBoosts, u"All Boosts…");
  menu_runner_ = std::make_unique<views::MenuRunner>(
      menu_model_.get(), views::MenuRunner::NO_FLAGS);
  menu_runner_->RunMenuAt(GetWidget(), nullptr,
                          name_button_->GetBoundsInScreen(),
                          views::MenuAnchorPosition::kTopRight,
                          ui::mojom::MenuSourceType::kMouse);
}

void OpenBoostEditorView::ExecuteCommand(int command_id, int event_flags) {
  if (command_id >= kCmdCaseBase) {
    const size_t index = static_cast<size_t>(command_id - kCmdCaseBase);
    if (index < kCases.size()) {
      Boost updated = boost_;
      updated.text_transform = kCases[index];
      ApplyDraft(std::move(updated), true, true);
    }
    return;
  }
  if (command_id >= kCmdSizeBase) {
    const size_t index = static_cast<size_t>(command_id - kCmdSizeBase);
    if (index < kMenuSizes.size()) {
      Boost updated = boost_;
      updated.text_zoom = kMenuSizes[index];
      ApplyDraft(std::move(updated), true, true);
    }
    return;
  }
  switch (command_id) {
    case kCmdRename:
      BeginPrompt(TextPrompt::kRename);
      break;
    case kCmdShuffle:
      Shuffle();
      break;
    case kCmdToggleEnabled: {
      Boost updated = boost_;
      updated.enabled = !updated.enabled;
      ApplyDraft(std::move(updated), true, true);
      break;
    }
    case kCmdCustomFont:
      BeginPrompt(TextPrompt::kCustomFont);
      break;
    case kCmdUndoZap:
      if (callbacks_.on_undo_zap) {
        callbacks_.on_undo_zap.Run(boost_.id);
      }
      break;
    case kCmdClearZaps:
      if (callbacks_.on_clear_zaps) {
        callbacks_.on_clear_zaps.Run(boost_.id);
      }
      break;
    case kCmdResetAll:
      ResetAll();
      break;
    case kCmdDelete:
      ShowDeleteConfirm(true);
      break;
    case kCmdShare:
      if (callbacks_.on_share_boost) {
        callbacks_.on_share_boost.Run(boost_);
      }
      break;
    case kCmdAllBoosts:
      if (callbacks_.on_show_all_boosts) {
        callbacks_.on_show_all_boosts.Run();
      }
      break;
    default:
      break;
  }
}

bool OpenBoostEditorView::IsCommandIdEnabled(int command_id) const {
  switch (command_id) {
    case kCmdHost:
      return false;
    case kCmdUndoZap:
    case kCmdClearZaps:
      return zap_count_ > 0;
    case kCmdResetAll:
      return !wheel_.IsIdentity() || boost_.font_family.has_value() ||
             std::fabs(boost_.text_zoom - 1.0) > 1e-6 ||
             !boost_.text_transform.empty() || !boost_.custom_css.empty() ||
             !boost_.custom_js.empty() || zap_count_ > 0;
    case kCmdShare:
      return !callbacks_.on_share_boost.is_null();
    case kCmdAllBoosts:
      return !callbacks_.on_show_all_boosts.is_null();
    default:
      return true;
  }
}

bool OpenBoostEditorView::IsCommandIdChecked(int command_id) const {
  if (command_id >= kCmdCaseBase) {
    return command_id - kCmdCaseBase == TextCaseIndex();
  }
  if (command_id >= kCmdSizeBase) {
    const size_t index = static_cast<size_t>(command_id - kCmdSizeBase);
    return index < kMenuSizes.size() &&
           std::fabs(kMenuSizes[index] - boost_.text_zoom) < 1e-6;
  }
  return false;
}

void OpenBoostEditorView::BeginPrompt(TextPrompt prompt) {
  prompt_ = prompt;
  if (prompt == TextPrompt::kRename) {
    prompt_field_->SetPlaceholderText(u"Boost name");
    prompt_field_->SetText(base::UTF8ToUTF16(boost_.name));
    prompt_field_->GetViewAccessibility().SetName(u"Boost name");
  } else {
    prompt_field_->SetPlaceholderText(u"Font family, e.g. Inter");
    prompt_field_->SetText(
        FontIndex() < 0 && boost_.font_family
            ? base::UTF8ToUTF16(*boost_.font_family)
            : std::u16string());
    prompt_field_->GetViewAccessibility().SetName(u"Custom font");
  }
  UpdateVisibility();
  DeprecatedLayoutImmediately();
  prompt_field_->RequestFocus();
  prompt_field_->SelectAll(false);
}

void OpenBoostEditorView::EndPrompt(bool commit) {
  const TextPrompt prompt = prompt_;
  prompt_ = TextPrompt::kNone;
  const std::string text(base::TrimWhitespaceASCII(
      base::UTF16ToUTF8(prompt_field_->GetText()), base::TRIM_ALL));
  UpdateVisibility();
  if (!commit) {
    return;
  }
  if (prompt == TextPrompt::kRename && !text.empty() && text != boost_.name) {
    Boost updated = boost_;
    updated.name = text.substr(0, 120);
    ApplyDraft(std::move(updated), true, true);
  } else if (prompt == TextPrompt::kCustomFont) {
    Boost updated = boost_;
    if (text.empty()) {
      updated.font_family.reset();
    } else if (text.find_first_of(";{}\"\r\n<") == std::string::npos) {
      // A bare family name gets a generic fallback.
      updated.font_family = text.find(',') == std::string::npos
                                ? text + ", sans-serif"
                                : text;
    } else {
      ShowNotice(u"That font name can’t be used.");
      return;
    }
    ApplyDraft(std::move(updated), true, true);
  }
}

void OpenBoostEditorView::ShowDeleteConfirm(bool show) {
  confirming_delete_ = show;
  confirm_view_->SetName(base::UTF8ToUTF16(boost_.name));
  UpdateVisibility();
  if (show) {
    confirm_view_->Focus();
  }
}

void OpenBoostEditorView::SelectCodeTab(CodeTab tab) {
  if (code_tab_ == CodeTab::kCss && css_save_timer_.IsRunning()) {
    css_save_timer_.Stop();
    CommitCss();
  }
  code_tab_ = tab;
  code_area_->SetText(base::UTF8ToUTF16(
      tab == CodeTab::kCss
          ? boost_.custom_css
          : (js_dirty_ ? base::UTF16ToUTF8(pending_js_) : boost_.custom_js)));
  code_area_->SetPlaceholderText(
      tab == CodeTab::kCss ? u"/* CSS for this site */"
                           : u"// JavaScript for this site");
  css_segment_->SchedulePaint();
  js_segment_->SchedulePaint();
  InvalidateLayout();
  SchedulePaint();
}

void OpenBoostEditorView::CommitCss() {
  css_dirty_ = false;
  Commit();
  SchedulePaint();
}

void OpenBoostEditorView::ApplyCode() {
  if (code_tab_ == CodeTab::kCss) {
    css_save_timer_.Stop();
    CommitCss();
    return;
  }
  Boost updated = boost_;
  updated.custom_js = base::UTF16ToUTF8(
      js_dirty_ ? pending_js_ : std::u16string(code_area_->GetText()));
  js_dirty_ = false;
  pending_js_.clear();
  ApplyDraft(std::move(updated), true, true);
}

void OpenBoostEditorView::ResetCode() {
  css_save_timer_.Stop();
  Boost updated = boost_;
  if (code_tab_ == CodeTab::kCss) {
    updated.custom_css.clear();
    css_dirty_ = false;
  } else if (js_dirty_) {
    // Unapplied edits: go back to the saved script.
    js_dirty_ = false;
    pending_js_.clear();
    code_area_->SetText(base::UTF8ToUTF16(boost_.custom_js));
    SchedulePaint();
    return;
  } else {
    updated.custom_js.clear();
  }
  code_area_->SetText(std::u16string());
  ApplyDraft(std::move(updated), true, true);
}

// --- Events ------------------------------------------------------------------

bool OpenBoostEditorView::AcceleratorPressed(
    const ui::Accelerator& accelerator) {
  if (accelerator.key_code() != ui::VKEY_ESCAPE) {
    return false;
  }
  if (menu_runner_ && menu_runner_->IsRunning()) {
    return false;
  }
  if (prompt_ != TextPrompt::kNone) {
    EndPrompt(false);
  } else if (confirming_delete_) {
    ShowDeleteConfirm(false);
  } else if (advanced_open_) {
    ToggleAdvanced();
  } else if (mode_ == Mode::kCode) {
    SetMode(Mode::kSimple);
  } else if (zap_armed_) {
    ToggleZap();
  } else if (callbacks_.on_close) {
    callbacks_.on_close.Run();
  }
  return true;
}

bool OpenBoostEditorView::OnMousePressed(const ui::MouseEvent& event) {
  // A click on the panel background closes an open prompt.
  if (prompt_ != TextPrompt::kNone) {
    EndPrompt(true);
  }
  return PanelBounds().Contains(event.location());
}

void OpenBoostEditorView::ContentsChanged(views::Textfield* sender,
                                          const std::u16string& new_contents) {
  if (sender != code_area_) {
    return;
  }
  if (code_tab_ == CodeTab::kCss) {
    if (!css_dirty_ && !css_save_timer_.IsRunning()) {
      PushUndo();
    }
    boost_.custom_css = base::UTF16ToUTF8(new_contents);
    css_dirty_ = true;
    Preview();
    css_save_timer_.Start(FROM_HERE,
                          base::Milliseconds(m::kCssSaveDelayMs),
                          base::BindOnce(&OpenBoostEditorView::CommitCss,
                                         base::Unretained(this)));
  } else {
    pending_js_ = new_contents;
    js_dirty_ = true;
  }
  SchedulePaint();
}

bool OpenBoostEditorView::HandleKeyEvent(views::Textfield* sender,
                                         const ui::KeyEvent& key_event) {
  if (key_event.type() != ui::EventType::kKeyPressed) {
    return false;
  }
  if (sender == prompt_field_) {
    if (key_event.key_code() == ui::VKEY_RETURN) {
      EndPrompt(true);
      return true;
    }
    if (key_event.key_code() == ui::VKEY_ESCAPE) {
      EndPrompt(false);
      return true;
    }
    return false;
  }
  if (sender == code_area_ && key_event.key_code() == ui::VKEY_RETURN &&
      secondary::HasPrimaryModifier(key_event.flags())) {
    // Cmd/Ctrl+Return applies.
    ApplyCode();
    return true;
  }
  return false;
}

BEGIN_METADATA(OpenBoostEditorView)
END_METADATA

// ===========================================================================
// OpenBoostEditorHost
// ===========================================================================

OpenBoostEditorHost::OpenBoostEditorHost() = default;

OpenBoostEditorHost::~OpenBoostEditorHost() {
  view_ = nullptr;
  host_.reset();
}

OpenBoostEditorView* OpenBoostEditorHost::ShowForBoost(
    views::Widget* parent_widget,
    const gfx::Rect& page_bounds_in_screen,
    const Boost& boost,
    bool zap_armed,
    bool dark,
    OpenBoostEditorView::Callbacks callbacks) {
  view_ = nullptr;
  host_.reset();
  if (!parent_widget) {
    return nullptr;
  }
  parent_ = parent_widget;
  page_bounds_in_screen_ = page_bounds_in_screen;
  callbacks.on_close = base::BindRepeating(
      [](base::WeakPtr<OpenBoostEditorHost> host,
         base::RepeatingClosure on_close) {
        if (host) {
          host->Hide();
        }
        if (on_close) {
          on_close.Run();
        }
      },
      weak_factory_.GetWeakPtr(), std::move(callbacks.on_close));
  auto view = std::make_unique<OpenBoostEditorView>(std::move(callbacks),
                                                    boost, zap_armed, dark);
  view_ = view.get();
  host_ = std::make_unique<secondary::OverlayWidgetHost>(
      parent_widget, std::move(view), "OpenBoostEditor",
      /*activatable=*/true);
  ApplyAnchor();
  host_->Show();
  return view_;
}

void OpenBoostEditorHost::UpdatePageBounds(
    const gfx::Rect& page_bounds_in_screen) {
  page_bounds_in_screen_ = page_bounds_in_screen;
  ApplyAnchor();
}

void OpenBoostEditorHost::ApplyAnchor() {
  if (!host_ || !parent_ || !view_ || !parent_->GetRootView()) {
    return;
  }
  const gfx::Rect page = views::View::ConvertRectFromScreen(
      parent_->GetRootView(), page_bounds_in_screen_);
  const gfx::Size pref = view_->GetPreferredSize();
  const int panel_h = pref.height() - 2 * m::kShadowMargin;
  const int max_offset =
      std::max(m::kScreenMargin, page.height() - panel_h - m::kScreenMargin);
  const int offset = std::clamp(m::kTopOffset, m::kScreenMargin, max_offset);
  const gfx::Rect anchor(page.x(), page.y() + offset,
                         std::max(0, page.width() - m::kScreenMargin),
                         panel_h);
  host_->SetAnchor(anchor, secondary::OverlayWidgetHost::Alignment::kTopRight);
}

void OpenBoostEditorHost::Hide() {
  if (host_) {
    host_->Hide();
  }
}

bool OpenBoostEditorHost::IsVisible() const {
  return host_ && host_->IsVisible();
}

// ===========================================================================
// OpenBoostEditorSession
// ===========================================================================

OpenBoostEditorSession::OpenBoostEditorSession(OpenBoostController* controller,
                                               ProfileID profile_id,
                                               ItemID tab_id)
    : controller_(controller),
      profile_id_(std::move(profile_id)),
      tab_id_(std::move(tab_id)) {}

OpenBoostEditorSession::~OpenBoostEditorSession() {
  observation_.Reset();
  if (controller_ && !closing_ && host_.IsVisible()) {
    controller_->EndPreview(tab_id_);
    if (controller_->zap_boost_id() == boost_id_) {
      controller_->CancelZap();
    }
  }
}

void OpenBoostEditorSession::Show(views::Widget* parent_widget,
                                  const gfx::Rect& page_bounds_in_screen,
                                  const Boost& boost,
                                  bool dark) {
  auto weak = weak_factory_.GetWeakPtr();
  OpenBoostEditorView::Callbacks callbacks;
  callbacks.on_live_preview = base::BindRepeating(
      [](base::WeakPtr<OpenBoostEditorSession> self, const Boost& draft) {
        if (self && self->controller_) {
          self->controller_->PreviewBoost(self->tab_id_, draft);
        }
      },
      weak);
  callbacks.on_commit_boost =
      base::BindRepeating(&OpenBoostEditorSession::Commit, weak);
  callbacks.on_delete_boost = base::BindRepeating(
      [](base::WeakPtr<OpenBoostEditorSession> self, const std::string& id) {
        if (!self || !self->controller_) {
          return;
        }
        self->seen_in_store_ = false;
        self->controller_->EndPreview(self->tab_id_);
        if (self->controller_->FindBoost(self->profile_id_, id)) {
          self->controller_->DeleteBoost(self->profile_id_, id);
        }
        self->Close();
      },
      weak);
  callbacks.on_toggle_zap = base::BindRepeating(
      [](base::WeakPtr<OpenBoostEditorSession> self, bool armed,
         const std::string& id) {
        if (!self || !self->controller_ || !self->view()) {
          return;
        }
        if (!armed) {
          self->controller_->CancelZap();
          return;
        }
        // A new Boost exists in the store before it can hold Zaps
        // (SaveBoost updates the cache at once).
        if (!self->controller_->FindBoost(self->profile_id_, id)) {
          self->Commit(self->view()->boost());
        }
        std::string message;
        if (!self->controller_->StartZapForTab(self->tab_id_, id, &message)) {
          self->view()->ShowNotice(base::UTF8ToUTF16(message));
        }
      },
      weak);
  callbacks.on_undo_zap = base::BindRepeating(
      [](base::WeakPtr<OpenBoostEditorSession> self, const std::string& id) {
        if (self && self->controller_) {
          self->controller_->UndoLastZap(id);
        }
      },
      weak);
  callbacks.on_clear_zaps = base::BindRepeating(
      [](base::WeakPtr<OpenBoostEditorSession> self, const std::string& id) {
        if (self && self->controller_) {
          self->controller_->ClearAllZaps(id);
        }
      },
      weak);
  if (on_share_) {
    callbacks.on_share_boost = on_share_;
  }
  if (on_show_all_) {
    callbacks.on_show_all_boosts = on_show_all_;
  }
  callbacks.on_close = base::BindRepeating(
      [](base::WeakPtr<OpenBoostEditorSession> self) {
        if (self) {
          self->Close();
        }
      },
      weak);

  boost_id_ = boost.id;
  const bool armed = controller_ && !boost.id.empty() &&
                     controller_->zap_boost_id() == boost.id;
  OpenBoostEditorView* view = host_.ShowForBoost(
      parent_widget, page_bounds_in_screen, boost, armed, dark,
      std::move(callbacks));
  if (!view) {
    return;
  }
  // The view assigns an id to a new Boost.
  boost_id_ = view->boost().id;
  seen_in_store_ =
      controller_ && controller_->FindBoost(profile_id_, boost_id_).has_value();
  if (controller_) {
    view->SetZapState(armed, controller_->ZapCount(boost_id_));
    view->SetBoostsGloballyEnabled(
        OpenBoostController::BoostsGloballyEnabled());
    if (!observation_.IsObserving()) {
      observation_.Observe(controller_.get());
    }
  }
}

void OpenBoostEditorSession::UpdatePageBounds(
    const gfx::Rect& page_bounds_in_screen) {
  host_.UpdatePageBounds(page_bounds_in_screen);
}

void OpenBoostEditorSession::Close() {
  if (closing_) {
    return;
  }
  closing_ = true;
  if (controller_) {
    controller_->EndPreview(tab_id_);
    if (controller_->zap_boost_id() == boost_id_) {
      controller_->CancelZap();
    }
  }
  observation_.Reset();
  host_.Hide();
  closing_ = false;
  if (on_closed_) {
    // Posted: the embedder may destroy this session (and the panel widget)
    // in response, which must not happen inside the panel's own event.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, std::move(on_closed_));
  }
}

void OpenBoostEditorSession::Commit(const Boost& boost) {
  if (!controller_) {
    return;
  }
  controller_->SaveBoost(profile_id_, boost);
  seen_in_store_ = true;
}

void OpenBoostEditorSession::OnBoostsChanged(const ProfileID& profile_id) {
  OpenBoostEditorView* panel = view();
  if (profile_id != profile_id_ || !panel || !controller_) {
    return;
  }
  panel->SetBoostsGloballyEnabled(OpenBoostController::BoostsGloballyEnabled());
  if (std::optional<Boost> stored =
          controller_->FindBoost(profile_id_, boost_id_)) {
    seen_in_store_ = true;
    panel->SetBoost(*stored);
    return;
  }
  if (seen_in_store_) {
    // Deleted elsewhere (Boosts manager, sync).
    Close();
  }
}

void OpenBoostEditorSession::OnZapStateChanged(bool armed,
                                               const std::string& boost_id,
                                               int zap_count) {
  OpenBoostEditorView* panel = view();
  if (!panel || !controller_) {
    return;
  }
  if (boost_id == boost_id_) {
    panel->SetZapState(armed, zap_count);
  } else if (panel->zap_armed() && controller_->zap_boost_id() != boost_id_) {
    panel->SetZapState(false, controller_->ZapCount(boost_id_));
  }
}

}  // namespace open_unified
