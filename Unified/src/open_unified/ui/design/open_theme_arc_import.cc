// Copyright 2026 The Open Authors. All rights reserved.
//
// Parser for Arc's `customInfo.windowTheme` object (schema in
// docs/re/runtime-observations.md section 3.3). Port of
// SpaceThemeStyle.init?(arcWindowThemeJSON:). Kept apart from
// open_theme_math.cc so the math stays std-only.

#include <optional>
#include <string>

#include "base/json/json_reader.h"
#include "base/values.h"
#include "open_unified/ui/design/open_theme_math.h"

namespace open_unified::theme {

namespace {

// Arc color object: {red, green, blue, alpha, colorSpace: "extendedSRGB"}.
std::optional<Rgba> ArcColor(const base::DictValue* d) {
  if (!d) {
    return std::nullopt;
  }
  const std::optional<double> r = d->FindDouble("red");
  const std::optional<double> g = d->FindDouble("green");
  const std::optional<double> b = d->FindDouble("blue");
  if (!r || !g || !b) {
    return std::nullopt;
  }
  return Rgba{*r, *g, *b, d->FindDouble("alpha").value_or(1.0)};
}

std::vector<Rgba> ArcColors(const base::ListValue* list) {
  std::vector<Rgba> out;
  if (!list) {
    return out;
  }
  for (const base::Value& v : *list) {
    if (const base::DictValue* d = v.GetIfDict()) {
      if (auto c = ArcColor(d)) {
        out.push_back(*c);
      }
    }
  }
  return out;
}

// Swift enums with payloads encode as {"case": {"_0": payload}}.
const base::DictValue* Payload(const base::DictValue* d, const char* key) {
  if (!d) {
    return nullptr;
  }
  const base::DictValue* wrapped = d->FindDict(key);
  return wrapped ? wrapped->FindDict("_0") : nullptr;
}

ThemeTexture TextureFromString(const std::string* s) {
  if (!s) {
    return ThemeTexture::kGrain;
  }
  if (*s == "sand") {
    return ThemeTexture::kSand;
  }
  if (*s == "denim") {
    return ThemeTexture::kDenim;
  }
  if (*s == "tweed") {
    return ThemeTexture::kTweed;
  }
  return ThemeTexture::kGrain;
}

Translucency TranslucencyFromString(const std::string* s) {
  return s && *s == "dark" ? Translucency::kDark : Translucency::kLight;
}

std::optional<SemanticPalette> Palette(const base::DictValue& root,
                                       const char* key) {
  const base::DictValue* semantic = root.FindDict("semanticColorPalette");
  const base::DictValue* based =
      semantic ? semantic->FindDict("appearanceBased") : nullptr;
  const base::DictValue* p = based ? based->FindDict(key) : nullptr;
  if (!p) {
    return std::nullopt;
  }
  auto c = [&](const char* k) { return ArcColor(p->FindDict(k)); };
  const std::optional<Rgba> background = c("background");
  const std::optional<Rgba> title = c("title");
  if (!background || !title) {
    return std::nullopt;
  }
  SemanticPalette out;
  out.background = *background;
  out.background_extra = c("backgroundExtra").value_or(*background);
  out.title = *title;
  out.subtitle = c("subtitle").value_or(*title);
  out.hover = c("hover").value_or(*background);
  out.focus = c("focus").value_or(*background);
  out.foreground_primary = c("foregroundPrimary").value_or(*title);
  out.foreground_secondary = c("foregroundSecondary").value_or(*title);
  out.foreground_tertiary = c("foregroundTertiary").value_or(*title);
  out.min_contrast = c("minContrastColor").value_or(*background);
  out.max_contrast = c("maxContrastColor").value_or(*title);
  out.cutout = c("cutoutColor").value_or(*background);
  return out;
}

}  // namespace

// static
std::optional<ThemeStyle> ThemeStyle::FromArcWindowThemeJson(
    const std::string& json) {
  std::optional<base::DictValue> parsed = base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
  if (!parsed) {
    return std::nullopt;
  }
  const base::DictValue& root = *parsed;
  const base::DictValue* background = root.FindDict("background");
  const base::DictValue* single = Payload(background, "single");
  const base::DictValue* style = single ? single->FindDict("style") : nullptr;
  const base::DictValue* color = Payload(style, "color");
  if (!color) {
    return std::nullopt;
  }

  ThemeStyle s;
  s.fill_kind = FillKind::kBlended;
  const base::DictValue* modifiers = nullptr;
  if (const base::DictValue* g = Payload(color, "blendedGradient")) {
    std::vector<Rgba> base_colors = ArcColors(g->FindList("baseColors"));
    std::vector<Rgba> overlay = ArcColors(g->FindList("overlayColors"));
    if (base_colors.empty()) {
      return std::nullopt;  // "BlendedGradientConfiguration has no colors."
    }
    if (base_colors.size() > 2) {
      base_colors.resize(2);
    }
    s.base = std::move(base_colors);
    if (overlay.size() >= 2) {
      overlay.resize(2);
      s.overlay = std::move(overlay);
    }
    modifiers = g->FindDict("modifiers");
    s.translucency = TranslucencyFromString(g->FindString("translucencyStyle"));
  } else if (const base::DictValue* single_color =
                 Payload(color, "blendedSingleColor")) {
    const std::optional<Rgba> c = ArcColor(single_color->FindDict("color"));
    if (!c) {
      return std::nullopt;
    }
    s.base = {*c};
    modifiers = single_color->FindDict("modifiers");
    s.translucency =
        TranslucencyFromString(single_color->FindString("translucencyStyle"));
  } else {
    return std::nullopt;
  }

  if (modifiers) {
    s.noise_factor = modifiers->FindDouble("noiseFactor").value_or(0.0);
    s.intensity_factor = modifiers->FindDouble("intensityFactor").value_or(0.8);
    s.texture = TextureFromString(modifiers->FindString("overlay"));
  }

  const std::string* appearance =
      single->FindString("contentOverBackgroundAppearance");
  s.content_appearance = appearance && *appearance == "dark"
                             ? ContentAppearance::kDark
                             : ContentAppearance::kLight;
  s.is_vibrant = single->FindBool("isVibrant").value_or(true);
  s.light_palette = Palette(root, "light");
  s.dark_palette = Palette(root, "dark");
  const base::DictValue* primary = root.FindDict("primaryColorPalette");
  if (primary) {
    s.accent = ArcColor(primary->FindDict("shaded"));
    s.shaded_dark_accent = ArcColor(primary->FindDict("shadedDark"));
    s.tinted_light_accent = ArcColor(primary->FindDict("tintedLight"));
  }
  s.uses_legacy_intensity = true;
  return s;
}

}  // namespace open_unified::theme
