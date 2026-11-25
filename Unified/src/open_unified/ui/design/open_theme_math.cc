// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/design/open_theme_math.h"

#include <algorithm>
#include <cmath>
#include <numbers>
#include <utility>

namespace open_unified::theme {

namespace {

constexpr double kPi = std::numbers::pi;

double Clamp01(double v) {
  return std::min(1.0, std::max(0.0, v));
}

double Fract(double v) {
  return v - std::floor(v);
}

double Finite(double v) {
  return std::isfinite(v) ? v : 0.0;
}

// Row-major pixel index without sign-conversion surprises.
size_t Idx(int x, int y, int n) {
  return static_cast<size_t>(y) * static_cast<size_t>(n) +
         static_cast<size_t>(x);
}

// Linear sRGB <-> linear Display P3 (both D65; exact from the primaries).
constexpr double kSRGBToP3[3][3] = {
    {0.8224619687, 0.1775380313, 0.0000000000},
    {0.0331941989, 0.9668058011, 0.0000000000},
    {0.0170826307, 0.0723974407, 0.9105199286},
};
constexpr double kP3ToSRGB[3][3] = {
    {1.2249401763, -0.2249401763, 0.0000000000},
    {-0.0420569547, 1.0420569547, 0.0000000000},
    {-0.0196375546, -0.0786360456, 1.0982736001},
};

std::array<double, 3> Apply(const double (&m)[3][3],
                            double r,
                            double g,
                            double b) {
  return {m[0][0] * r + m[0][1] * g + m[0][2] * b,
          m[1][0] * r + m[1][1] * g + m[1][2] * b,
          m[2][0] * r + m[2][1] * g + m[2][2] * b};
}

// Seamless integer hash noise shared by the procedural textures.
double HashRandom(int x, int y, uint32_t salt) {
  uint32_t h = (static_cast<uint32_t>(x) * 0x8DA6B343u) ^
               (static_cast<uint32_t>(y) * 0xD8163841u) ^
               (salt * 0x9E3779B9u);
  h ^= h >> 13;
  h *= 0x5BD1E995u;
  h ^= h >> 15;
  return static_cast<double>(h & 0xFFFFu) / 65535.0;
}

// Seamless value noise in -0.5..0.5 on a `cells`-periodic lattice.
double ValueNoise(double u, double v, int cells, uint32_t salt) {
  const int gx = static_cast<int>(std::floor(u));
  const int gy = static_cast<int>(std::floor(v));
  const double fx = u - std::floor(u);
  const double fy = v - std::floor(v);
  const double sx = fx * fx * (3 - 2 * fx);
  const double sy = fy * fy * (3 - 2 * fy);
  auto at = [&](int x, int y) {
    return HashRandom(x % cells, y % cells, salt) - 0.5;
  };
  const double a = at(gx, gy), b = at(gx + 1, gy);
  const double c = at(gx, gy + 1), d = at(gx + 1, gy + 1);
  return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy;
}

int TextureIndex(ThemeTexture t) {
  switch (t) {
    case ThemeTexture::kGrain:
      return 0;
    case ThemeTexture::kSand:
      return 1;
    case ThemeTexture::kDenim:
      return 2;
    case ThemeTexture::kTweed:
      return 3;
  }
  return 0;
}

}  // namespace

// ---------------------------------------------------------------------------

Rgba Rgba::Under(const Rgba& top) const {
  const double t = top.a;
  return {r * (1 - t) + top.r * t, g * (1 - t) + top.g * t,
          b * (1 - t) + top.b * t, 1.0};
}

Rgba FromModel(const RGBAColor& c) {
  return {c.r, c.g, c.b, c.a};
}

RGBAColor ToModel(const Rgba& c) {
  return {c.r, c.g, c.b, c.a};
}

double Lab::chroma() const {
  return std::sqrt(a * a + b * b);
}

double LayerAlpha(double intensity) {
  return tuning::kIntensityAlphaFloor +
         tuning::kIntensityAlphaSlope * Clamp01(Finite(intensity));
}

// ---------------------------------------------------------------------------
// OKLab

namespace oklab {

double Decode(double c) {
  const double a = std::abs(c);
  const double v = a <= 0.04045 ? a / 12.92 : std::pow((a + 0.055) / 1.055, 2.4);
  return c < 0 ? -v : v;
}

double Encode(double c) {
  const double a = std::abs(c);
  const double v =
      a <= 0.0031308 ? a * 12.92 : 1.055 * std::pow(a, 1 / 2.4) - 0.055;
  return c < 0 ? -v : v;
}

Lab FromSRGB(double r, double g, double b) {
  return FromLinear(Decode(r), Decode(g), Decode(b));
}

Lab FromLinear(double r, double g, double b) {
  const double l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
  const double m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
  const double s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
  const double l_ = std::cbrt(l), m_ = std::cbrt(m), s_ = std::cbrt(s);
  return {0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
          1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
          0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_};
}

std::array<double, 3> ToLinear(const Lab& c) {
  const double l_ = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b;
  const double m_ = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b;
  const double s_ = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b;
  const double l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
  return {4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
          -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
          -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s};
}

Lab Mix(const Lab& x, const Lab& y, double t) {
  return {x.L + (y.L - x.L) * t, x.a + (y.a - x.a) * t, x.b + (y.b - x.b) * t};
}

}  // namespace oklab

// ---------------------------------------------------------------------------
// Color math

namespace color_math {

std::array<double, 3> LinearSRGBToLinearP3(double r, double g, double b) {
  return Apply(kSRGBToP3, r, g, b);
}

std::array<double, 3> LinearP3ToLinearSRGB(double r, double g, double b) {
  return Apply(kP3ToSRGB, r, g, b);
}

P3 ToP3(const Rgba& c) {
  const auto lin = LinearSRGBToLinearP3(oklab::Decode(Finite(c.r)),
                                        oklab::Decode(Finite(c.g)),
                                        oklab::Decode(Finite(c.b)));
  return {Clamp01(oklab::Encode(lin[0])), Clamp01(oklab::Encode(lin[1])),
          Clamp01(oklab::Encode(lin[2]))};
}

Rgba ToExtendedSRGB(const P3& c) {
  const auto e = P3ToSRGB(c);
  return {e[0], e[1], e[2], 1.0};
}

std::array<double, 3> P3ToSRGB(const P3& c) {
  const auto lin = LinearP3ToLinearSRGB(oklab::Decode(c.r), oklab::Decode(c.g),
                                        oklab::Decode(c.b));
  return {oklab::Encode(lin[0]), oklab::Encode(lin[1]), oklab::Encode(lin[2])};
}

P3 FromLinearSRGB(double r, double g, double b) {
  const auto p = LinearSRGBToLinearP3(r, g, b);
  return {Clamp01(oklab::Encode(p[0])), Clamp01(oklab::Encode(p[1])),
          Clamp01(oklab::Encode(p[2]))};
}

Hsl ToHsl(const P3& c) {
  const double high = std::max({c.r, c.g, c.b});
  const double low = std::min({c.r, c.g, c.b});
  const double delta = high - low;
  const double l = (high + low) / 2;
  // A neutral color's undefined hue is canonically 0.
  if (!(delta > 1e-6)) {
    return {0, 0, l};
  }
  const double s = delta / (1 - std::abs(2 * l - 1));
  double h;
  if (high == c.r) {
    h = (c.g - c.b) / delta;
  } else if (high == c.g) {
    h = (c.b - c.r) / delta + 2;
  } else {
    h = (c.r - c.g) / delta + 4;
  }
  return {Fract(h / 6), s, l};
}

P3 FromHsl(double h, double s, double l) {
  h = Fract(h);
  s = Clamp01(s);
  l = Clamp01(l);
  const double chroma = (1 - std::abs(2 * l - 1)) * s;
  const double x = chroma * (1 - std::abs(std::fmod(h * 6, 2.0) - 1));
  const double m = l - chroma / 2;
  P3 r;
  switch (static_cast<int>(h * 6)) {
    case 0:
      r = {chroma, x, 0};
      break;
    case 1:
      r = {x, chroma, 0};
      break;
    case 2:
      r = {0, chroma, x};
      break;
    case 3:
      r = {0, x, chroma};
      break;
    case 4:
      r = {x, 0, chroma};
      break;
    default:
      r = {chroma, 0, x};
      break;
  }
  return {r.r + m, r.g + m, r.b + m};
}

double Luminance(const P3& c) {
  auto lin = [](double x) {
    return x <= 0.03928 ? x / 12.92 : std::pow((x + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

double Contrast(const P3& a, const P3& b) {
  const double x = Luminance(a), y = Luminance(b);
  return (std::max(x, y) + 0.05) / (std::min(x, y) + 0.05);
}

P3 Rotate(const P3& c, double degrees) {
  const Hsl v = ToHsl(c);
  return FromHsl(v.h + degrees / 360, v.s, v.l);
}

P3 Band(const P3& c, double lo, double hi) {
  const Hsl v = ToHsl(c);
  double l = v.l;
  P3 result = c;
  if (Luminance(c) < lo) {
    while (Luminance(result) < lo && l < 1) {
      l = std::min(1.0, l + 0.01);
      result = FromHsl(v.h, v.s, l);
    }
  } else if (Luminance(c) > hi) {
    while (Luminance(result) > hi && l > 0) {
      l = std::max(0.0, l - 0.01);
      result = FromHsl(v.h, v.s, l);
    }
  }
  return result;
}

std::vector<P3> Harmony(const P3& key, int count, ThemeWheel wheel) {
  if (count < 1 || count > 3) {
    return {};
  }
  std::vector<double> angles;
  if (wheel == ThemeWheel::kAnalogous) {
    angles = {0, 40, -40};
  } else if (count == 2) {
    angles = {0, 180};
  } else {
    angles = {0, 150, 210};
  }
  std::vector<P3> out;
  for (size_t i = 0; i < static_cast<size_t>(count) && i < angles.size();
       ++i) {
    out.push_back(Rotate(key, angles[i]));
  }
  return out;
}

PrimaryPalette PrimaryPaletteFor(const P3& key) {
  return {Band(key, 0.85, 0.95), Band(key, 0.30, 0.50), Band(key, 0, 0.50),
          Band(key, 0, 0.10)};
}

SemanticPalettePair SemanticPalettes(const PrimaryPalette& p) {
  const Rgba tinted = ToExtendedSRGB(p.tinted_light);
  const Rgba mid = ToExtendedSRGB(p.mid_tone);
  const Rgba shaded = ToExtendedSRGB(p.shaded);
  const Rgba s = ToExtendedSRGB(p.shaded_dark);
  auto over = [](const Rgba& source, double alpha, double gray,
                 double background_alpha = 1.0) {
    const double a = alpha + background_alpha * (1 - alpha);
    const double b = gray * background_alpha * (1 - alpha);
    return Rgba{(source.r * alpha + b) / a, (source.g * alpha + b) / a,
                (source.b * alpha + b) / a, a};
  };
  SemanticPalettePair out;
  out.light = {over(s, 0.10, 1), over(s, 0.01, 1), over(s, 0.30, 0),
               over(s, 0.40, 1), over(s, 0.20, 1), over(s, 0.50, 1),
               shaded,           mid,              tinted,
               tinted,           s,                tinted};
  out.dark = {over(s, 0.30, 0),       over(s, 0.15, 0),
              over(s, 0.15, 1),       over(tinted, 0.50, 0),
              over(s, 0.35, 1, 0.20), over(s, 0.65, 1, 0.45),
              tinted,                 mid,
              shaded,                 s,
              tinted,                 s};
  return out;
}

ContentAppearance ContentAppearanceFor(const P3& key,
                                       const SemanticPalette& light,
                                       const SemanticPalette& dark,
                                       double bias) {
  return Contrast(key, ToP3(dark.title)) + bias >=
                 Contrast(key, ToP3(light.title))
             ? ContentAppearance::kDark
             : ContentAppearance::kLight;
}

}  // namespace color_math

// ---------------------------------------------------------------------------
// Window material

namespace window_material {

namespace {
// The light themes' fitted inactive lift at the legacy alpha 0.64.
constexpr double kLightInactiveLift =
    (1 - tuning::kLegacyAlpha) * (tuning::kLegacyLightUnderlayInactive -
                                  tuning::kLegacyLightUnderlayActive);
}  // namespace

double ActiveBackdrop(Translucency t) {
  return t == Translucency::kDark ? 0.91
                                  : 1 - kLightInactiveLift / kBackdropWeight;
}

double InactiveBackdrop(Translucency t) {
  return t == Translucency::kDark ? 0.0 : 1.0;
}

double InactiveShift(Translucency t) {
  return kBackdropWeight * (InactiveBackdrop(t) - ActiveBackdrop(t));
}

double Tint(double active, Translucency t) {
  const double v =
      (active - kBackdropWeight * ActiveBackdrop(t)) / (1 - kBackdropWeight);
  return active >= 0 ? std::max(0.0, v) : v;
}

double Inactive(double active, Translucency t) {
  const double v = active + InactiveShift(t);
  return active >= 0 ? std::min(std::max(0.0, v), std::max(1.0, active)) : v;
}

}  // namespace window_material

// ---------------------------------------------------------------------------
// ThemeStyle

ThemeStyle ThemeStyle::Default(ContentAppearance system) {
  ThemeStyle s;
  s.fill_kind = FillKind::kCorners;
  if (system == ContentAppearance::kDark) {
    s.corners = {Rgba::Hex(0x252538), Rgba::Hex(0x322438),
                 Rgba::Hex(0x2C2437), Rgba::Hex(0x342237)};
    s.translucency = Translucency::kDark;
  } else {
    s.corners = {Rgba::Hex(0xD9DAF4), Rgba::Hex(0xEFE5EB),
                 Rgba::Hex(0xE7E0EE), Rgba::Hex(0xFDECE3)};
    s.translucency = Translucency::kLight;
  }
  s.noise_factor = 0;
  s.content_appearance = std::nullopt;
  s.is_vibrant = true;
  s.window_color_scheme = system;
  return s;
}

ThemeStyle ThemeStyle::Incognito() {
  ThemeStyle s;
  s.fill_kind = FillKind::kCorners;
  s.corners.assign(4, default_theme::kIncognitoSidebar);
  s.translucency = Translucency::kDark;
  s.content_appearance = ContentAppearance::kDark;
  s.is_vibrant = false;
  s.window_color_scheme = ContentAppearance::kDark;
  return s;
}

ThemeStyle ThemeStyle::FromSpaceStyle(const SpaceStyle& style,
                                      ContentAppearance system) {
  // Never reinterpret inputs whose derivation version is not implemented.
  if (style.math_version != 1) {
    return Default(system);
  }
  const P3 key = color_math::ToP3(FromModel(style.key_color));
  const auto primary = color_math::PrimaryPaletteFor(key);
  const auto palettes = color_math::SemanticPalettes(primary);
  // The fill clamps the key's lightness; palettes and polarity use the key.
  const Hsl hsl = color_math::ToHsl(key);
  const bool is_gray =
      std::max({key.r, key.g, key.b}) - std::min({key.r, key.g, key.b}) <
      1.0 / 255;
  const bool in_range = hsl.l >= tuning::kFillLightnessMin &&
                        hsl.l <= tuning::kFillLightnessMax;
  const P3 fill_key =
      in_range ? key
               : color_math::FromHsl(
                     hsl.h, is_gray ? 0 : hsl.s,
                     std::min(tuning::kFillLightnessMax,
                              std::max(tuning::kFillLightnessMin, hsl.l)));
  std::vector<Rgba> colors;
  for (const P3& c :
       color_math::Harmony(fill_key, style.color_count, style.wheel)) {
    colors.push_back(color_math::ToExtendedSRGB(c));
  }

  ThemeStyle s;
  s.fill_kind = FillKind::kBlended;
  for (size_t i = 0; i < colors.size() && i < 2; ++i) {
    s.base.push_back(colors[i]);
  }
  if (colors.size() == 3) {
    s.overlay = {Rgba{0, 0, 0, 0}, colors[2]};
  }
  s.noise_factor = style.noise_factor;
  s.intensity_factor = style.intensity_factor;
  s.content_appearance = color_math::ContentAppearanceFor(
      key, palettes.light, palettes.dark, tuning::kPolarityBias);
  s.light_palette = palettes.light;
  s.dark_palette = palettes.dark;
  s.accent = color_math::ToExtendedSRGB(primary.shaded);
  s.shaded_dark_accent = color_math::ToExtendedSRGB(primary.shaded_dark);
  s.tinted_light_accent = color_math::ToExtendedSRGB(primary.tinted_light);
  s.texture = style.texture;
  s.uses_legacy_intensity = false;
  // The Space mode picks the window scheme, never the text polarity.
  switch (style.appearance) {
    case ThemeAppearance::kAutomatic:
      s.window_color_scheme = system;
      break;
    case ThemeAppearance::kLight:
      s.window_color_scheme = ContentAppearance::kLight;
      break;
    case ThemeAppearance::kDark:
      s.window_color_scheme = ContentAppearance::kDark;
      break;
  }
  return s;
}

ThemeStyle ThemeStyle::FromSpaceTheme(const SpaceTheme& theme,
                                      ContentAppearance system) {
  if (theme.style.has_value()) {
    return FromSpaceStyle(*theme.style, system);
  }
  if (theme.imported_arc_theme_json.has_value()) {
    if (auto parsed = FromArcWindowThemeJson(*theme.imported_arc_theme_json)) {
      return *parsed;
    }
  }
  if (!theme.gradient_stops_light.empty()) {
    std::vector<GradientStop> stops = theme.gradient_stops_light;
    std::stable_sort(stops.begin(), stops.end(),
                     [](const GradientStop& a, const GradientStop& b) {
                       return a.location < b.location;
                     });
    ThemeStyle s;
    s.fill_kind = FillKind::kBlended;
    for (size_t i = 0; i < stops.size() && i < 2; ++i) {
      s.base.push_back(FromModel(stops[i].color));
    }
    s.content_appearance = std::nullopt;
    s.uses_legacy_intensity = true;
    return s;
  }
  return Default(system);
}

bool ThemeStyle::IsDefaultTheme() const {
  return fill_kind == FillKind::kCorners && !content_appearance.has_value() &&
         !light_palette.has_value() && !dark_palette.has_value();
}

Translucency ThemeStyle::BackdropScheme() const {
  if (uses_legacy_intensity) {
    return translucency;
  }
  return window_color_scheme == ContentAppearance::kDark ? Translucency::kDark
                                                         : Translucency::kLight;
}

const SemanticPalette* ThemeStyle::PaletteFor(
    ContentAppearance appearance) const {
  const auto& p =
      appearance == ContentAppearance::kDark ? dark_palette : light_palette;
  return p.has_value() ? &*p : nullptr;
}

Rgba ThemeStyle::TitleColor(ContentAppearance appearance) const {
  if (const auto* p = PaletteFor(appearance)) {
    return p->title;
  }
  return appearance == ContentAppearance::kDark ? default_theme::kTitleDark
                                                : default_theme::kTitleLight;
}

Rgba ThemeStyle::SplitTitleColor(ContentAppearance appearance) const {
  if (const auto* p = PaletteFor(appearance)) {
    return p->title;
  }
  return appearance == ContentAppearance::kDark
             ? default_theme::kSplitTitleDark
             : default_theme::kSplitTitleLight;
}

Rgba ThemeStyle::AccentColor(ContentAppearance) const {
  return accent.value_or(default_theme::kBrandBlue);
}

Rgba ThemeStyle::ContrastAccent(ContentAppearance appearance,
                                std::optional<Rgba> against,
                                double minimum_contrast) const {
  const std::vector<Rgba> backgrounds =
      against.has_value() ? std::vector<Rgba>{*against} : FieldSamples();
  std::vector<Rgba> candidates = {AccentColor(appearance)};
  if (shaded_dark_accent.has_value()) {
    candidates.push_back(*shaded_dark_accent);
  }
  for (const Rgba& candidate : candidates) {
    const double ink = LuminanceSRGB(candidate);
    const bool ok = std::all_of(
        backgrounds.begin(), backgrounds.end(), [&](const Rgba& background) {
          const double bg = LuminanceSRGB(background);
          return (std::max(ink, bg) + 0.05) / (std::min(ink, bg) + 0.05) >=
                 minimum_contrast;
        });
    if (ok) {
      return candidate.WithAlpha(1);
    }
  }
  return TitleColor(appearance).WithAlpha(1);
}

Rgba ThemeStyle::TooltipFill() const {
  return light_palette ? light_palette->title.WithAlpha(1)
                       : default_theme::kTooltipFill;
}

Rgba ThemeStyle::TooltipText() const {
  return light_palette ? light_palette->background.WithAlpha(1)
                       : default_theme::kTooltipText;
}

Rgba ThemeStyle::MiniPlayerFill(ContentAppearance appearance) const {
  if (const auto* p = PaletteFor(appearance)) {
    return p->background_extra.WithAlpha(1);
  }
  return appearance == ContentAppearance::kDark
             ? default_theme::kDarkBackgroundExtra
             : default_theme::kLightBackgroundExtra;
}

std::vector<Rgba> ThemeStyle::FieldSamples() const {
  const ThemeEvaluator field(*this, 1000, 1000, /*is_active=*/true);
  std::vector<Rgba> out;
  out.reserve(9);
  for (double u : {0.0, 0.5, 1.0}) {
    for (double v : {0.0, 0.5, 1.0}) {
      const auto c = field.Color(u, v);
      out.push_back({c[0], c[1], c[2], 1});
    }
  }
  return out;
}

ContentAppearance ThemeStyle::IncreasedContrastAppearance(
    ContentAppearance system) const {
  const ContentAppearance base_appearance = ResolvedAppearance(system);
  const auto samples = FieldSamples();
  const Rgba raised =
      RaiseContrast(TitleColor(base_appearance).WithAlpha(1), samples,
                    base_appearance == ContentAppearance::kDark);
  if (!(WorstContrast(raised, samples) < tuning::kIncreasedTitleContrast)) {
    return base_appearance;
  }
  return base_appearance == ContentAppearance::kDark ? ContentAppearance::kLight
                                                     : ContentAppearance::kDark;
}

// ---------------------------------------------------------------------------
// ThemeEvaluator

double ThemeEvaluator::Param::At(double u, double v) const {
  return u + v <= 1 ? tl + (tr - tl) * u + (bl - tl) * v
                    : br + (bl - br) * (1 - u) + (tr - br) * (1 - v);
}

ThemeEvaluator::Param ThemeEvaluator::MakeParam(double angle,
                                                double length_scale,
                                                double center_offset,
                                                double width,
                                                double height) {
  const double w = std::max(width, 1.0), h = std::max(height, 1.0);
  const double t = angle * kPi / 180;
  const double dx = std::sin(t), dy = -std::cos(t);
  const double length =
      (std::abs(w * std::sin(t)) + std::abs(h * std::cos(t))) * length_scale;
  const double cx = w / 2 + dx * center_offset * length;
  const double cy = h / 2 + dy * center_offset * length;
  const double x0 = (cx - dx * length / 2) / w, y0 = (cy - dy * length / 2) / h;
  const double x1 = (cx + dx * length / 2) / w, y1 = (cy + dy * length / 2) / h;
  const double ddx = x1 - x0, ddy = y1 - y0;
  const double l2 = std::max(ddx * ddx + ddy * ddy, 1e-12);
  auto s = [&](double u, double v) {
    return std::min(std::max(((u - x0) * ddx + (v - y0) * ddy) / l2, 0.0), 1.0);
  };
  Param p;
  p.tl = s(0, 0);
  p.bl = s(0, 1);
  p.tr = s(1, 0);
  p.br = s(1, 1);
  return p;
}

ThemeEvaluator::ThemeEvaluator(const ThemeStyle& style,
                               double window_width,
                               double window_height,
                               bool is_active,
                               bool card_tint)
    : translucency_(style.BackdropScheme()),
      is_active_(is_active),
      card_tint_(card_tint) {
  legacy_ = style.uses_legacy_intensity;
  const bool is_corners = style.fill_kind == ThemeStyle::FillKind::kCorners;
  if (!is_corners) {
    if (!legacy_ && style.base.size() == 1 && style.overlay.empty()) {
      solid_key_ = color_math::ToP3(style.base[0]);
    }
    for (const Rgba& c : style.base) {
      base_.push_back(oklab::FromSRGB(c.r, c.g, c.b));
    }
    for (const Rgba& c : style.overlay) {
      overlay_.emplace_back(oklab::FromSRGB(c.r, c.g, c.b), c.a);
    }
    // A clear first stop fades in the second stop's own color.
    if (overlay_.size() == 2 && overlay_[0].second == 0) {
      overlay_[0].first = overlay_[1].first;
    }
  } else {
    corners_ = style.corners;
  }
  base_param_ = MakeParam(tuning::kBaseAngle, tuning::kBaseLengthScale,
                          tuning::kBaseCenterOffset, window_width,
                          window_height);
  overlay_param_ = MakeParam(tuning::kOverlayAngle, tuning::kOverlayLengthScale,
                             tuning::kOverlayCenterOffset, window_width,
                             window_height);
  alpha_ = legacy_ ? tuning::kLegacyAlpha : LayerAlpha(style.intensity_factor);
  uses_inactive_underlay_fit_ = legacy_ && !is_active && !card_tint &&
                                translucency_ == Translucency::kLight &&
                                !is_corners;
  mixes_in_srgb_ = !legacy_ && !is_corners &&
                   style.window_color_scheme == ContentAppearance::kLight;
  double fitted;
  if (style.translucency == Translucency::kLight) {
    fitted = uses_inactive_underlay_fit_ ? tuning::kLegacyLightUnderlayInactive
                                         : tuning::kLegacyLightUnderlayActive;
  } else {
    fitted = tuning::kLegacyDarkUnderlayActive;
  }
  if (legacy_ || is_corners) {
    underlay_ = fitted;
  } else if (style.window_color_scheme == ContentAppearance::kDark) {
    // Wash law, preserving U0 at and above the wash cap.
    underlay_ = tuning::kDarkUnderlay *
                (1 - tuning::kDarkWashAlpha *
                         std::min(alpha_, tuning::kWashOpacityCap)) /
                (1 - tuning::kDarkWashAlpha * tuning::kWashOpacityCap);
  } else {
    underlay_ = tuning::kLightUnderlay -
                tuning::kLightUnderlaySlope *
                    std::max(0.0, tuning::kWashOpacityCap - alpha_);
  }
  if (solid_key_.has_value()) {
    const P3& key = *solid_key_;
    const double u0 = underlay_ * (1 - alpha_);
    if (mixes_in_srgb_) {
      const auto c = color_math::P3ToSRGB(key);
      solid_color_ = std::array<double, 3>{
          c[0] * alpha_ + u0, c[1] * alpha_ + u0, c[2] * alpha_ + u0};
    } else {
      solid_color_ = color_math::P3ToSRGB(
          {key.r * alpha_ + u0, key.g * alpha_ + u0, key.b * alpha_ + u0});
    }
  }
}

std::array<double, 3> ThemeEvaluator::Color(double u, double v) const {
  auto c = ActiveColor(u, v);
  if (card_tint_) {
    for (double& x : c) {
      x = window_material::Tint(x, translucency_);
    }
    return c;
  }
  if (!is_active_ && !uses_inactive_underlay_fit_) {
    for (double& x : c) {
      x = window_material::Inactive(x, translucency_);
    }
  }
  return c;
}

std::array<double, 3> ThemeEvaluator::ActiveColor(double u, double v) const {
  if (solid_color_.has_value()) {
    return *solid_color_;
  }
  if (!legacy_ && corners_.empty()) {
    const auto [color, a] = Fill(u, v);
    const double u0 = underlay_ * (1 - a);
    if (mixes_in_srgb_) {
      const auto c = color_math::P3ToSRGB(color);
      return {c[0] * a + u0, c[1] * a + u0, c[2] * a + u0};
    }
    return color_math::P3ToSRGB(
        {color.r * a + u0, color.g * a + u0, color.b * a + u0});
  }
  if (!corners_.empty()) {
    const auto& c = corners_;
    auto lerp = [](double a, double b, double t) { return a + (b - a) * t; };
    auto ch = [&](double Rgba::*k) {
      return lerp(lerp(c[0].*k, c[1].*k, u), lerp(c[2].*k, c[3].*k, u), v);
    };
    return {ch(&Rgba::r), ch(&Rgba::g), ch(&Rgba::b)};
  }
  const auto f = LinearFill(u, v);
  const double out_a = f[3];
  const double u0 = underlay_ * (1 - out_a);
  return {oklab::Encode(f[0]) * out_a + u0, oklab::Encode(f[1]) * out_a + u0,
          oklab::Encode(f[2]) * out_a + u0};
}

std::pair<P3, double> ThemeEvaluator::Fill(double u, double v) const {
  if (solid_key_.has_value()) {
    return {*solid_key_, alpha_};
  }
  const auto f = LinearFill(u, v);
  return {color_math::FromLinearSRGB(f[0], f[1], f[2]), f[3]};
}

std::array<double, 4> ThemeEvaluator::LinearFill(double u, double v) const {
  Lab b;
  if (base_.size() >= 2) {
    const double t = std::min(
        std::max(base_param_.At(u, v) * tuning::kBaseParameterScale, 0.0), 1.0);
    b = oklab::Mix(base_[0], base_[1], t);
  } else {
    b = base_.empty() ? Lab{0.5, 0, 0} : base_.front();
  }
  auto lin = oklab::ToLinear(b);
  double r = lin[0], g = lin[1], bl = lin[2];
  double out_a = alpha_;
  if (overlay_.size() == 2) {
    const double t = overlay_param_.At(u, v);
    const Lab o = oklab::Mix(overlay_[0].first, overlay_[1].first, t);
    const double oa =
        (overlay_[0].second + (overlay_[1].second - overlay_[0].second) * t) *
        alpha_;
    const auto ol = oklab::ToLinear(o);
    const double ba = alpha_;
    out_a = oa + (1 - oa) * ba;
    if (out_a > 0) {
      r = (ol[0] * oa + r * ba * (1 - oa)) / out_a;
      g = (ol[1] * oa + g * ba * (1 - oa)) / out_a;
      bl = (ol[2] * oa + bl * ba * (1 - oa)) / out_a;
    }
  }
  return {r, g, bl, out_a};
}

std::vector<float> MakeFieldPixels(const ThemeStyle& style,
                                   double window_width,
                                   double window_height,
                                   bool is_active,
                                   bool card_tint,
                                   int resolution) {
  const int n = std::max(resolution, 2);
  const ThemeEvaluator e(style, window_width, window_height, is_active,
                         card_tint);
  std::vector<float> pixels(Idx(0, n, n) * 4, 1.0f);
  for (int y = 0; y < n; ++y) {
    const double v = (y + 0.5) / n;
    for (int x = 0; x < n; ++x) {
      const double u = (x + 0.5) / n;
      const auto c = e.Color(u, v);
      const size_t i = Idx(x, y, n) * 4;
      pixels[i] = static_cast<float>(c[0]);
      pixels[i + 1] = static_cast<float>(c[1]);
      pixels[i + 2] = static_cast<float>(c[2]);
      pixels[i + 3] = 1.0f;
    }
  }
  return pixels;
}

double CrossfadeProgress(double elapsed_seconds, double duration) {
  if (!(duration > 0)) {
    return 1.0;
  }
  return Clamp01(elapsed_seconds / duration);
}

Rgba Lerp(const Rgba& from, const Rgba& to, double t) {
  return {from.r + (to.r - from.r) * t, from.g + (to.g - from.g) * t,
          from.b + (to.b - from.b) * t, from.a + (to.a - from.a) * t};
}

std::vector<float> LerpFieldPixels(const std::vector<float>& from,
                                   const std::vector<float>& to,
                                   double t) {
  if (from.size() != to.size()) {
    return t < 0.5 ? from : to;
  }
  std::vector<float> out(from.size());
  const float k = static_cast<float>(Clamp01(t));
  for (size_t i = 0; i < from.size(); ++i) {
    out[i] = from[i] + (to[i] - from[i]) * k;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Textures

namespace texture {

float PeriodPoints(ThemeTexture t) {
  switch (t) {
    case ThemeTexture::kGrain:
      return 100;
    case ThemeTexture::kSand:
      return 96;
    case ThemeTexture::kDenim:
      return 300;
    case ThemeTexture::kTweed:
      return 128;
  }
  return 100;
}

double LayerAlpha(ThemeTexture t, double noise_factor) {
  const double noise = std::isfinite(noise_factor) ? Clamp01(noise_factor) : 0;
  return noise * tuning::kTextureNoiseScale[TextureIndex(t)];
}

Tile LegacyGrain(double noise_factor, double scale, uint32_t seed) {
  Tile tile;
  const int px = static_cast<int>(std::lround(kGrainTilePoints * scale));
  if (px <= 0 || !(noise_factor > 0)) {
    return tile;
  }
  const double peak = std::min(std::max(noise_factor * kGrainStrength, 0.0), 1.0);
  tile.size = px;
  tile.alpha.resize(Idx(0, px, px));
  double total = 0, squared = 0;
  for (int y = 0; y < px; ++y) {
    for (int x = 0; x < px; ++x) {
      // xorshift-mixed integer hash: stable and seamless (wraps at px).
      uint32_t h = (static_cast<uint32_t>(x) * 0x8DA6B343u) ^
                   (static_cast<uint32_t>(y) * 0xD8163841u) ^ seed;
      h ^= h >> 13;
      h *= 0x5BD1E995u;
      h ^= h >> 15;
      const double n = static_cast<double>(h & 0xFFFFu) / 65535.0;
      const auto a = static_cast<uint8_t>(std::round(n * peak * 255));
      const float stored = a / 255.0f;
      tile.alpha[Idx(x, y, px)] = stored;
      total += stored;
      squared += static_cast<double>(stored) * stored;
    }
  }
  const double count = static_cast<double>(tile.alpha.size());
  tile.mean_alpha = total / count;
  tile.standard_deviation = std::sqrt(
      std::max(0.0, squared / count - tile.mean_alpha * tile.mean_alpha));
  return tile;
}

Tile Intrinsic(ThemeTexture t, double scale) {
  Tile tile;
  if (!(scale > 0) || !std::isfinite(scale)) {
    return tile;
  }
  const int n =
      std::max(1, static_cast<int>(std::lround(PeriodPoints(t) * scale)));
  std::vector<double> marks(Idx(0, n, n), 0.0);
  switch (t) {
    case ThemeTexture::kGrain: {
      const Tile grain = LegacyGrain(1.0, scale);
      if (grain.size != n) {
        return tile;
      }
      for (size_t i = 0; i < marks.size(); ++i) {
        marks[i] = grain.alpha[i];
      }
      break;
    }
    case ThemeTexture::kSand: {
      // Dense even sand: white noise softened by a 0.47 pt Gaussian that
      // wraps at the tile edge and scales with the backing scale.
      const double sigma = 0.47 * scale;
      const int radius = static_cast<int>(std::ceil(3 * sigma));
      struct K {
        int dx, dy;
        double w;
      };
      std::vector<K> kernel;
      for (int dy = -radius; dy <= radius; ++dy) {
        for (int dx = -radius; dx <= radius; ++dx) {
          kernel.push_back(
              {dx, dy, std::exp(-static_cast<double>(dx * dx + dy * dy) /
                                (2 * sigma * sigma))});
        }
      }
      std::vector<double> white(marks.size());
      for (int i = 0; i < n * n; ++i) {
        white[static_cast<size_t>(i)] = HashRandom(i % n, i / n, 3) - 0.5;
      }
      for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) {
          double sum = 0;
          for (const K& k : kernel) {
            sum += k.w * white[Idx((x + k.dx + n) % n, (y + k.dy + n) % n, n)];
          }
          marks[Idx(x, y, n)] = sum;
        }
      }
      break;
    }
    case ThemeTexture::kDenim: {
      // Open's own twill in points: fine "\" hatch, warp lines every 2.5 pt
      // with slow shade changes, a weak 5.3 pt column beat and fine noise.
      // Every period divides the 300 pt tile.
      for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) {
          const double u = (x + 0.5) / scale, v = (y + 0.5) / scale;
          const double twill =
              std::cos(2 * kPi * (0.40 * u - 0.44 * v)) *
              (1 + 0.7 * ValueNoise(u / 3, v / 3, 100, 61));
          const double warp = 0.42 * std::cos(2 * kPi * 0.40 * u);
          const double beat = 0.17 * std::cos(2 * kPi * 0.19 * u + 1);
          const int thread = static_cast<int>(std::floor(0.40 * u)) % 120;
          const double run = v / 30;
          const int step = static_cast<int>(std::floor(run));
          const double f = run - std::floor(run);
          const double blend = f * f * (3 - 2 * f);
          const double shade =
              0.8 * (HashRandom(thread, step % 10, 5) * (1 - blend) +
                     HashRandom(thread, (step + 1) % 10, 5) * blend - 0.5);
          marks[Idx(x, y, n)] =
              twill + warp + beat + shade + 1.3 * (HashRandom(x, y, 9) - 0.5);
        }
      }
      break;
    }
    case ThemeTexture::kTweed: {
      // Own fine grain plus a weak seamless low-frequency term.
      constexpr int kCells = 32;
      auto fine = [&](int x, int y) {
        return HashRandom((x + n) % n, (y + n) % n, 92) - 0.5;
      };
      for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) {
          marks[Idx(x, y, n)] =
              fine(x, y) + 0.18 * fine(x - 1, y) + 0.38 * fine(x, y - 1) +
              0.65 * ValueNoise(static_cast<double>(x) * kCells / n,
                                static_cast<double>(y) * kCells / n, kCells,
                                91);
        }
      }
      break;
    }
  }

  const double count = static_cast<double>(marks.size());
  double mean = 0;
  for (double m : marks) {
    mean += m;
  }
  mean /= count;
  double var = 0;
  for (double m : marks) {
    var += (m - mean) * (m - mean);
  }
  const double deviation = std::sqrt(var / count);
  const double darkness = tuning::kTextureTileDarkness[TextureIndex(t)];
  double spread = 0;
  switch (t) {
    case ThemeTexture::kGrain:
      spread = 1.25 * deviation * darkness / mean;
      break;
    case ThemeTexture::kSand:
      spread = 0.167;
      break;
    case ThemeTexture::kDenim:
      spread = 0.0353;
      break;
    case ThemeTexture::kTweed:
      spread = 0.0371;
      break;
  }
  std::vector<double> alphas(marks.size());
  double alpha_sum = 0;
  for (size_t i = 0; i < marks.size(); ++i) {
    alphas[i] = Clamp01(darkness + (marks[i] - mean) * spread /
                                       std::max(1e-12, deviation));
    alpha_sum += alphas[i];
  }
  // Contrast tuning may clip the lowest grain values: renormalize the mean.
  const double normalization = darkness / (alpha_sum / count);
  tile.size = n;
  tile.alpha.resize(marks.size());
  double total = 0, squared = 0;
  for (size_t i = 0; i < alphas.size(); ++i) {
    const double stored =
        std::round(std::min(1.0, alphas[i] * normalization) * 65535) / 65535;
    tile.alpha[i] = static_cast<float>(stored);
    total += stored;
    squared += stored * stored;
  }
  tile.mean_alpha = total / count;
  tile.standard_deviation = std::sqrt(
      std::max(0.0, squared / count - tile.mean_alpha * tile.mean_alpha));
  return tile;
}

}  // namespace texture

// ---------------------------------------------------------------------------
// Sidebar roles

namespace {
Rgba Ink(ContentAppearance content, double light, double dark) {
  return content == ContentAppearance::kDark ? Rgba::White(dark)
                                             : Rgba::Black(light);
}
}  // namespace

SidebarRoles::SidebarRoles(ContentAppearance c,
                           const Rgba& t,
                           bool is_default_theme,
                           bool ic)
    : content(c), title(t) {
  subtitle = Ink(c, ic ? 0.75 : 0.50, ic ? 0.75 : 0.50);
  space_title = Ink(c, ic ? 0.75 : 0.45, ic ? 0.75 : 0.45);
  new_tab_label = Ink(c, ic ? 0.60 : 0.30, ic ? 0.60 : 0.45);
  new_tab_glyph = Ink(c, 0.50, 0.50);
  placeholder = Ink(c, 0.30, 0.30);
  url_text = Ink(c, ic ? 1 : 0.60, ic ? 1 : 0.60);
  bottom_glyph = Ink(c, ic ? 0.85 : 0.565, ic ? 0.85 : 0.60);
  toolbar_glyph = Ink(c, ic ? 0.85 : 0.56, ic ? 0.85 : 0.60);
  toolbar_glyph_disabled = Ink(c, 0.22, 0.25);
  separator = Ink(c, ic ? 0.30 : 0.15, ic ? 0.30 : 0.15);
  field_fill = Ink(c, 0.043, 0.10);
  field_hover = Ink(c, 0.09, 0.15);
  tile_fill = Ink(c, 0.045, 0.10);
  row_hover = Ink(c, is_default_theme ? 0.046 : 0.08,
                  is_default_theme ? 0.10 : 0.08);
  active_plate =
      c == ContentAppearance::kDark ? kActivePlateDark : kActivePlateLight;
  // Light content: measured black 0.05..0.10 (start 0.07). Dark: none.
  if (c == ContentAppearance::kLight) {
    edge_band = Rgba::Black(0.07);
  }
}

double LuminanceSRGB(const Rgba& c) {
  auto linear = [](double value) {
    const double x = Clamp01(value);
    return x <= 0.04045 ? x / 12.92 : std::pow((x + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
}

double WorstContrast(const Rgba& color, const std::vector<Rgba>& backgrounds) {
  if (backgrounds.empty()) {
    return 21;
  }
  double worst = 21;
  const double ink = LuminanceSRGB(color);
  for (const Rgba& b : backgrounds) {
    const double l = LuminanceSRGB(b);
    worst = std::min(worst, (std::max(ink, l) + 0.05) / (std::min(ink, l) + 0.05));
  }
  return worst;
}

Rgba RaiseContrast(const Rgba& color,
                   const std::vector<Rgba>& backgrounds,
                   bool dark) {
  const double target =
      tuning::kIncreasedTitleContrast + tuning::kIncreasedContrastMargin;
  if (!(WorstContrast(color, backgrounds) < target)) {
    return color;
  }
  const Hsl hsl = color_math::ToHsl(color_math::ToP3(color));
  double l = hsl.l;
  Rgba result = color;
  for (int i = 0; i < 100 && WorstContrast(result, backgrounds) < target; ++i) {
    l = dark ? std::min(1.0, l + 0.01) : std::max(0.0, l - 0.01);
    result = color_math::ToExtendedSRGB(color_math::FromHsl(hsl.h, hsl.s, l));
    if (l == 0 || l == 1) {
      break;
    }
  }
  return result.WithAlpha(1);
}

SidebarRoles RolesFor(const ThemeStyle& style,
                      ContentAppearance appearance,
                      bool increase_contrast) {
  Rgba title = style.TitleColor(appearance).WithAlpha(1);
  if (!increase_contrast) {
    return SidebarRoles(appearance, title, style.IsDefaultTheme());
  }
  const auto samples = style.FieldSamples();
  const bool dark = appearance == ContentAppearance::kDark;
  title = RaiseContrast(title, samples, dark);
  SidebarRoles roles(appearance, title, style.IsDefaultTheme(), true);
  const double target =
      tuning::kIncreasedTitleContrast + tuning::kIncreasedContrastMargin;
  auto under_all = [&](const Rgba& fill) {
    std::vector<Rgba> out;
    out.reserve(samples.size());
    for (const Rgba& s : samples) {
      out.push_back(s.Under(fill));
    }
    return out;
  };
  // A white plate under light text on a mid-tone Space can fall below AA:
  // darken it only where it would fail.
  if (dark && WorstContrast(title, under_all(roles.active_plate)) < target) {
    roles.active_plate = Rgba::Black(0.25);
  }
  const Rgba url_text = roles.url_text;
  auto fails = [&](const Rgba& fill) {
    return WorstContrast(url_text, under_all(fill)) < target;
  };
  if (fails(roles.field_fill) || fails(roles.field_hover)) {
    auto away = [&](double a) { return dark ? Rgba::Black(a) : Rgba::White(a); };
    constexpr double kSteps[] = {0.12, 0.2, 0.3, 0.45};
    double alpha = kSteps[3];
    for (double s : kSteps) {
      if (!fails(away(s)) && !fails(away(s + 0.06))) {
        alpha = s;
        break;
      }
    }
    roles.field_fill = away(alpha);
    roles.field_hover = away(alpha + 0.06);
  }
  return roles;
}

}  // namespace open_unified::theme
