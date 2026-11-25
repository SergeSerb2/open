// Copyright 2026 The Open Authors. All rights reserved.
//
// Open's Space theme math, ported from Packages/OpenKit/Sources/OpenDesign:
// OKLab.swift, ThemeColorMath.swift, ThemeField.swift, SpaceThemeStyle.swift,
// SidebarThemeRoles.swift, WindowMaterial.swift, Grain.swift and
// ThemeTexture.swift. Pure C++20 (std only): no Chromium, no Skia. The Skia
// shader layer lives in open_theme_shader.h.
//
// Color conventions:
//  - `Rgba` is gamma-encoded *extended* sRGB (components may leave 0..1).
//  - `P3` is gamma-encoded Display P3 in 0..1.
//  - Linear values are explicitly named.

#ifndef OPEN_UNIFIED_UI_DESIGN_OPEN_THEME_MATH_H_
#define OPEN_UNIFIED_UI_DESIGN_OPEN_THEME_MATH_H_

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "open_unified/core/model/open_types.h"

namespace open_unified::theme {

// ---------------------------------------------------------------------------
// Basic color types.

struct Rgba {
  double r = 0;
  double g = 0;
  double b = 0;
  double a = 1;

  static constexpr Rgba Hex(uint32_t rgb, double alpha = 1.0) {
    return {((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0,
            (rgb & 0xFF) / 255.0, alpha};
  }
  static constexpr Rgba White(double alpha) { return {1, 1, 1, alpha}; }
  static constexpr Rgba Black(double alpha) { return {0, 0, 0, alpha}; }
  constexpr Rgba WithAlpha(double alpha) const { return {r, g, b, alpha}; }
  // `top` composited over this opaque color (source-over, encoded sRGB).
  Rgba Under(const Rgba& top) const;

  bool operator==(const Rgba&) const = default;
};

Rgba FromModel(const RGBAColor& c);
RGBAColor ToModel(const Rgba& c);

struct P3 {
  double r = 0;
  double g = 0;
  double b = 0;
  bool operator==(const P3&) const = default;
};

struct Lab {
  double L = 0;
  double a = 0;
  double b = 0;
  double chroma() const;
  bool operator==(const Lab&) const = default;
};

struct Hsl {
  double h = 0;  // 0..1
  double s = 0;
  double l = 0;
};

enum class ContentAppearance { kLight, kDark };
enum class Translucency { kLight, kDark };

// ---------------------------------------------------------------------------
// OKLab (Bjorn Ottosson's published matrices).
namespace oklab {
// Sign-preserving sRGB transfer, so extended components stay valid.
double Decode(double c);
double Encode(double c);
Lab FromSRGB(double r, double g, double b);
Lab FromLinear(double r, double g, double b);
std::array<double, 3> ToLinear(const Lab& c);
Lab Mix(const Lab& x, const Lab& y, double t);
}  // namespace oklab

// ---------------------------------------------------------------------------
// Decoded and fitted constants (ThemeTuning, SidebarThemeRules).
namespace tuning {
inline constexpr double kIntensityAlphaFloor = 0.2;
inline constexpr double kIntensityAlphaSlope = 0.55;
inline constexpr double kDarkWashAlpha = 0.35;
inline constexpr double kWashOpacityCap = 0.5;
inline constexpr double kPolarityBias = 0.2;
inline constexpr double kFillLightnessMin = 0.01;
inline constexpr double kFillLightnessMax = 0.97;
inline constexpr double kLightUnderlay = 0.91;
inline constexpr double kLightUnderlaySlope = 0.177;
inline constexpr double kDarkUnderlay = 0.67;
inline constexpr double kIncreasedTitleContrast = 4.5;
inline constexpr double kIncreasedContrastMargin = 0.15;
// Legacy (imported) underlays.
inline constexpr double kLegacyLightUnderlayActive = 0.694;
inline constexpr double kLegacyLightUnderlayInactive = 0.83;
inline constexpr double kLegacyDarkUnderlayActive = 0.16;  // guess
inline constexpr double kLegacyAlpha = 0.64;
// Texture layer multipliers and fitted tile darkness (index = ThemeTexture).
inline constexpr double kTextureNoiseScale[4] = {0.80, 0.15, 0.60, 0.40};
inline constexpr double kTextureTileDarkness[4] = {0.060, 0.316, 0.122, 0.262};
// Gradient lines (CSS style: 0 deg points up, 90 deg right).
inline constexpr double kBaseAngle = 111.0;
inline constexpr double kBaseLengthScale = 1.015;
inline constexpr double kBaseCenterOffset = 0.021;
inline constexpr double kBaseParameterScale = 4.0 / 3.0;
inline constexpr double kOverlayAngle = 146.3;
inline constexpr double kOverlayLengthScale = 0.332;
inline constexpr double kOverlayCenterOffset = 0.0;
// Field image resolution.
inline constexpr int kFieldResolution = 64;
// Background cross-fade between Spaces: linear, 0.21 s.
inline constexpr double kThemeCrossfadeSeconds = 0.21;
}  // namespace tuning

// Editor layer opacity: 0.2 + 0.55 * intensity.
double LayerAlpha(double intensity);

// ---------------------------------------------------------------------------
// Display P3 / HSL color math (ThemeColorMath).
namespace color_math {
P3 ToP3(const Rgba& extended_srgb);  // clamps to 0..1 like ColorSync
Rgba ToExtendedSRGB(const P3& c);
std::array<double, 3> LinearSRGBToLinearP3(double r, double g, double b);
std::array<double, 3> LinearP3ToLinearSRGB(double r, double g, double b);
// Encoded P3 -> encoded extended sRGB (no clamp).
std::array<double, 3> P3ToSRGB(const P3& c);
// Linear sRGB -> encoded P3 clamped to 0..1.
P3 FromLinearSRGB(double r, double g, double b);

Hsl ToHsl(const P3& c);
P3 FromHsl(double h, double s, double l);
double Luminance(const P3& c);  // WCAG, 0.03928 threshold
double Contrast(const P3& a, const P3& b);
P3 Rotate(const P3& c, double degrees);
P3 Band(const P3& c, double lo, double hi);
// analogous [0, 40, -40]; complementary [0, 180] (2) or [0, 150, 210] (3).
std::vector<P3> Harmony(const P3& key, int count, ThemeWheel wheel);

struct PrimaryPalette {
  P3 tinted_light;
  P3 mid_tone;
  P3 shaded;
  P3 shaded_dark;
};
PrimaryPalette PrimaryPaletteFor(const P3& key);
}  // namespace color_math

// The 12 role colors Arc stores per content appearance.
struct SemanticPalette {
  Rgba background;
  Rgba background_extra;
  Rgba title;
  Rgba subtitle;
  Rgba hover;
  Rgba focus;
  Rgba foreground_primary;
  Rgba foreground_secondary;
  Rgba foreground_tertiary;
  Rgba min_contrast;
  Rgba max_contrast;
  Rgba cutout;
  bool operator==(const SemanticPalette&) const = default;
};

namespace color_math {
struct SemanticPalettePair {
  SemanticPalette light;
  SemanticPalette dark;
};
SemanticPalettePair SemanticPalettes(const PrimaryPalette& p);
// Content polarity: dark content when the key contrasts more with the dark
// title (plus `bias`) than with the light title.
ContentAppearance ContentAppearanceFor(const P3& key,
                                       const SemanticPalette& light,
                                       const SemanticPalette& dark,
                                       double bias = tuning::kPolarityBias);
}  // namespace color_math

// ---------------------------------------------------------------------------
// Window material (WindowMaterial.swift).
namespace window_material {
inline constexpr double kBackdropWeight = 0.115;
inline constexpr double kPageBlurSigma = 25;
double ActiveBackdrop(Translucency t);
double InactiveBackdrop(Translucency t);
double InactiveShift(Translucency t);
double Tint(double active, Translucency t);
double Inactive(double active, Translucency t);
}  // namespace window_material

// ---------------------------------------------------------------------------
// Everything the background renderer and the sidebar need from a Space theme
// (port of SpaceThemeStyle).
struct ThemeStyle {
  enum class FillKind { kBlended, kCorners };

  FillKind fill_kind = FillKind::kCorners;
  // kBlended: base 1..2 colors, overlay 0 or 2 colors (first may be clear).
  std::vector<Rgba> base;
  std::vector<Rgba> overlay;
  // kCorners: TL, TR, BL, BR final colors.
  std::vector<Rgba> corners;

  double noise_factor = 0;
  double intensity_factor = 0.8;
  ContentAppearance window_color_scheme = ContentAppearance::kDark;
  ThemeTexture texture = ThemeTexture::kGrain;
  bool uses_legacy_intensity = false;
  Translucency translucency = Translucency::kLight;
  // nullopt: follows the system appearance (default theme only).
  std::optional<ContentAppearance> content_appearance = ContentAppearance::kLight;
  bool is_vibrant = true;
  std::optional<SemanticPalette> light_palette;
  std::optional<SemanticPalette> dark_palette;
  std::optional<Rgba> accent;
  std::optional<Rgba> shaded_dark_accent;
  std::optional<Rgba> tinted_light_accent;

  bool operator==(const ThemeStyle&) const = default;

  // Builders.
  static ThemeStyle Default(ContentAppearance system);
  static ThemeStyle Incognito();
  static ThemeStyle FromSpaceStyle(const SpaceStyle& style,
                                   ContentAppearance system);
  // Stored editor style, else imported Arc JSON, else legacy stops, else default.
  static ThemeStyle FromSpaceTheme(const SpaceTheme& theme,
                                   ContentAppearance system);
  // Parses Arc's `customInfo.windowTheme` object. Implemented in
  // open_theme_arc_import.cc (uses base::JSONReader). nullopt on unknown shapes.
  static std::optional<ThemeStyle> FromArcWindowThemeJson(
      const std::string& json);

  bool IsDefaultTheme() const;
  ContentAppearance ResolvedAppearance(ContentAppearance system) const {
    return content_appearance.value_or(system);
  }
  Translucency BackdropScheme() const;
  const SemanticPalette* PaletteFor(ContentAppearance appearance) const;

  Rgba TitleColor(ContentAppearance appearance) const;
  Rgba SplitTitleColor(ContentAppearance appearance) const;
  Rgba AccentColor(ContentAppearance appearance) const;
  Rgba ContrastAccent(ContentAppearance appearance,
                      std::optional<Rgba> against = std::nullopt,
                      double minimum_contrast = 3) const;
  Rgba TooltipFill() const;
  Rgba TooltipText() const;
  Rgba MiniPlayerFill(ContentAppearance appearance) const;

  // The active window's background at 3 x 3 points over the window.
  std::vector<Rgba> FieldSamples() const;
  // Content appearance with Increase Contrast (keep polarity if the raised
  // title reaches 4.5:1, else flip).
  ContentAppearance IncreasedContrastAppearance(ContentAppearance system) const;
};

// Default-theme text (DefaultThemeText) and core tokens used by roles.
namespace default_theme {
inline constexpr Rgba kTitleLight = Rgba::Hex(0x090D4E);
inline constexpr Rgba kTitleDark = Rgba::Hex(0xDEDFFF);
// Core.foregroundPrimary: light #0E0F10 @0.90 (P3), dark white 0.80.
inline constexpr Rgba kSplitTitleLight = Rgba::Hex(0x0E0F10, 0.90);
inline constexpr Rgba kSplitTitleDark = Rgba::White(0.80);
// Core.brandBlue #3139FB (Display P3 hex; drawn as sRGB here).
inline constexpr Rgba kBrandBlue = Rgba::Hex(0x3139FB);
inline constexpr Rgba kTooltipFill = Rgba::Hex(0x0A0D4F);
inline constexpr Rgba kTooltipText = Rgba::Hex(0xF4F4F6);
inline constexpr Rgba kDarkBackgroundExtra = Rgba::Hex(0x050627);
inline constexpr Rgba kLightBackgroundExtra = Rgba::Hex(0xFDFDFF);
inline constexpr Rgba kIncognitoSidebar = Rgba::Hex(0x26232B);
}  // namespace default_theme

// ---------------------------------------------------------------------------
// Field evaluation (ThemeField.Evaluator).
class ThemeEvaluator {
 public:
  ThemeEvaluator(const ThemeStyle& style,
                 double window_width,
                 double window_height,
                 bool is_active,
                 bool card_tint = false);

  // Final color (extended, gamma-encoded sRGB) at window uv (0..1, y down).
  std::array<double, 3> Color(double u, double v) const;
  // Unblended editor fill at uv: encoded Display P3 and its coverage.
  std::pair<P3, double> Fill(double u, double v) const;

  double alpha() const { return alpha_; }
  double underlay() const { return underlay_; }

 private:
  struct Param {
    double tl = 0, bl = 0, tr = 0, br = 0;
    double At(double u, double v) const;
  };
  static Param MakeParam(double angle, double length_scale,
                         double center_offset, double w, double h);
  std::array<double, 3> ActiveColor(double u, double v) const;
  std::array<double, 4> LinearFill(double u, double v) const;

  std::vector<Lab> base_;
  std::vector<std::pair<Lab, double>> overlay_;
  std::vector<Rgba> corners_;
  Param base_param_;
  Param overlay_param_;
  double alpha_ = 0;
  double underlay_ = 0;
  bool legacy_ = false;
  std::optional<P3> solid_key_;
  std::optional<std::array<double, 3>> solid_color_;
  Translucency translucency_ = Translucency::kLight;
  bool is_active_ = true;
  bool card_tint_ = false;
  bool uses_inactive_underlay_fit_ = false;
  bool mixes_in_srgb_ = false;
};

// The whole-window field as RGBA float pixels (premultiplied, alpha 1),
// resolution x resolution, row-major, uv sampled at pixel centers. Stretch it
// over the window with bilinear filtering.
std::vector<float> MakeFieldPixels(const ThemeStyle& style,
                                   double window_width,
                                   double window_height,
                                   bool is_active,
                                   bool card_tint = false,
                                   int resolution = tuning::kFieldResolution);

// Linear cross-fade helpers (0.21 s).
double CrossfadeProgress(double elapsed_seconds,
                         double duration = tuning::kThemeCrossfadeSeconds);
Rgba Lerp(const Rgba& from, const Rgba& to, double t);
std::vector<float> LerpFieldPixels(const std::vector<float>& from,
                                   const std::vector<float>& to,
                                   double t);

// ---------------------------------------------------------------------------
// Procedural textures (Grain.swift, ThemeTexture.swift). Open's own art.
namespace texture {
inline constexpr float kGrainTilePoints = 100;
inline constexpr double kGrainStrength = 0.1;
float PeriodPoints(ThemeTexture t);  // grain 100, sand 96, denim 300, tweed 128
// Layer opacity for editor themes: noise * kTextureNoiseScale[texture].
double LayerAlpha(ThemeTexture t, double noise_factor);

struct Tile {
  int size = 0;                // pixels per side
  std::vector<float> alpha;    // size * size, black with this alpha
  double mean_alpha = 0;
  double standard_deviation = 0;
};
// Legacy grain tile: noise alpha in 0..noise * 0.1, 8-bit quantized like Swift.
Tile LegacyGrain(double noise_factor, double scale, uint32_t seed = 0x9E3779B9u);
// Intrinsic editor texture tile (drawn at LayerAlpha).
Tile Intrinsic(ThemeTexture t, double scale);
}  // namespace texture

// ---------------------------------------------------------------------------
// Sidebar color roles (SidebarRoles). Built once per theme change.
struct SidebarRoles {
  ContentAppearance content = ContentAppearance::kDark;
  Rgba title;
  Rgba subtitle;
  Rgba space_title;
  Rgba new_tab_label;
  Rgba new_tab_glyph;
  Rgba placeholder;
  Rgba url_text;
  Rgba bottom_glyph;
  Rgba toolbar_glyph;
  Rgba toolbar_glyph_disabled;
  Rgba separator;
  Rgba field_fill;
  Rgba field_hover;
  Rgba tile_fill;
  Rgba row_hover;
  Rgba active_plate;
  std::optional<Rgba> edge_band;

  static constexpr float kEdgeBandWidth = 3;
  // Light content active plate: #F3F3F3 at 0.916; dark: white 0.20.
  static constexpr Rgba kActivePlateLight = Rgba::Hex(0xF3F3F3, 0.916);
  static constexpr Rgba kActivePlateDark = Rgba::White(0.20);

  SidebarRoles() = default;
  SidebarRoles(ContentAppearance content,
               const Rgba& title,
               bool is_default_theme,
               bool increase_contrast = false);
  bool operator==(const SidebarRoles&) const = default;
};

// The sidebar's role set for `appearance`. With Increase Contrast the title
// is raised to 4.5:1 (+0.15 margin) and failing plates/fields are corrected.
SidebarRoles RolesFor(const ThemeStyle& style,
                      ContentAppearance appearance,
                      bool increase_contrast = false);

// WCAG helpers on encoded sRGB (clamped).
double LuminanceSRGB(const Rgba& c);
double WorstContrast(const Rgba& color, const std::vector<Rgba>& backgrounds);
Rgba RaiseContrast(const Rgba& color,
                   const std::vector<Rgba>& backgrounds,
                   bool dark);

}  // namespace open_unified::theme

#endif  // OPEN_UNIFIED_UI_DESIGN_OPEN_THEME_MATH_H_
