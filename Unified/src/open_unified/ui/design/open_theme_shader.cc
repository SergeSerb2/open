// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/design/open_theme_shader.h"

#include <algorithm>
#include <cmath>
#include <list>
#include <utility>
#include <vector>

#include "cc/paint/paint_flags.h"
#include "cc/paint/paint_image_builder.h"
#include "cc/paint/paint_shader.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkBlendMode.h"
#include "third_party/skia/include/core/SkColorSpace.h"
#include "third_party/skia/include/core/SkImageInfo.h"
#include "third_party/skia/include/core/SkMatrix.h"
#include "third_party/skia/include/core/SkPixmap.h"
#include "third_party/skia/include/core/SkSamplingOptions.h"
#include "third_party/skia/include/core/SkTileMode.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/skia_conversions.h"

namespace open_unified::theme {

namespace {

uint8_t ToByte(double v) {
  return static_cast<uint8_t>(
      std::lround(std::min(1.0, std::max(0.0, v)) * 255.0));
}

sk_sp<SkImage> FieldImageFromPixels(const std::vector<float>& pixels,
                                    int n,
                                    sk_sp<SkColorSpace> color_space = nullptr) {
  if (!color_space) {
    color_space = SkColorSpace::MakeSRGB();
  }
  const SkImageInfo dst_info = SkImageInfo::Make(
      n, n, kRGBA_F16_SkColorType, kPremul_SkAlphaType, color_space);
  SkBitmap bitmap;
  if (!bitmap.tryAllocPixels(dst_info)) {
    return nullptr;
  }
  const SkImageInfo src_info = SkImageInfo::Make(
      n, n, kRGBA_F32_SkColorType, kPremul_SkAlphaType, color_space);
  const SkPixmap src(src_info, pixels.data(),
                     static_cast<size_t>(n) * 4 * sizeof(float));
  // F16 is unclamped: extended (wide-gamut) components survive.
  if (!bitmap.writePixels(src, 0, 0)) {
    return nullptr;
  }
  bitmap.setImmutable();
  return SkImages::RasterFromBitmap(bitmap);
}

sk_sp<SkImage> TileImageFromAlpha(const texture::Tile& tile) {
  if (tile.size <= 0) {
    return nullptr;
  }
  SkBitmap bitmap;
  if (!bitmap.tryAllocPixels(SkImageInfo::MakeN32Premul(tile.size, tile.size))) {
    return nullptr;
  }
  for (int y = 0; y < tile.size; ++y) {
    uint32_t* row = bitmap.getAddr32(0, y);
    for (int x = 0; x < tile.size; ++x) {
      const float a = tile.alpha[static_cast<size_t>(y) *
                                     static_cast<size_t>(tile.size) +
                                 static_cast<size_t>(x)];
      // Premultiplied black: RGB stay 0, noise lives in alpha.
      row[x] = SkPreMultiplyARGB(ToByte(a), 0, 0, 0);
    }
  }
  bitmap.setImmutable();
  return SkImages::RasterFromBitmap(bitmap);
}

sk_sp<SkColorSpace> DisplayP3() {
  return SkColorSpace::MakeRGB(SkNamedTransferFn::kSRGB,
                               SkNamedGamut::kDisplayP3);
}

// ThemeField.makeWindowTint, pixel for pixel (premultiplied RGBA).
std::vector<float> MakeWindowTintPixels(const ThemeStyle& style,
                                        double width,
                                        double height,
                                        int n) {
  const ThemeEvaluator e(style, width, height, /*is_active=*/true);
  const bool corners = style.fill_kind == ThemeStyle::FillKind::kCorners;
  double correction[3] = {0, 0, 0};
  if (corners && style.translucency == Translucency::kDark) {
    // Default corners store final fitted pixels, not a raw fill. Native
    // material fit across the three C14-T wallpapers.
    correction[0] = -0.12938;
    correction[1] = -0.12318;
    correction[2] = -0.12659;
  }
  const bool display_space = WindowTintUsesDisplayP3(style);
  std::vector<float> pixels(static_cast<size_t>(n) * n * 4, 0.0f);
  for (int y = 0; y < n; ++y) {
    const double v = (y + 0.5) / n;
    for (int x = 0; x < n; ++x) {
      const double u = (x + 0.5) / n;
      const size_t i = (static_cast<size_t>(y) * n + x) * 4;
      if (display_space) {
        // Keep the editor's display-space law: unmixing after conversion
        // to sRGB would change its fitted colors.
        const auto [c, a] = e.Fill(u, v);
        pixels[i] = static_cast<float>(c.r * a);
        pixels[i + 1] = static_cast<float>(c.g * a);
        pixels[i + 2] = static_cast<float>(c.b * a);
        pixels[i + 3] = static_cast<float>(a);
        continue;
      }
      const auto rgb = e.Color(u, v);
      const double a = corners ? e.alpha() : e.Fill(u, v).second;
      // Unmix in the field's encoded space; extended channels keep colors
      // outside sRGB until the window's color conversion.
      const double gray = e.underlay() * (1 - a);
      pixels[i] = static_cast<float>(rgb[0] - gray + correction[0] * a);
      pixels[i + 1] = static_cast<float>(rgb[1] - gray + correction[1] * a);
      pixels[i + 2] = static_cast<float>(rgb[2] - gray + correction[2] * a);
      pixels[i + 3] = static_cast<float>(a);
    }
  }
  return pixels;
}

// Small LRU of texture tiles. Key: texture, scale, and for legacy grain the
// noise peak (legacy tiles bake their alpha; editor tiles are intrinsic and
// noise only changes the layer opacity).
struct TileKey {
  bool legacy = false;
  ThemeTexture texture = ThemeTexture::kGrain;
  int scale_milli = 0;
  int noise_milli = 0;
  bool operator==(const TileKey&) const = default;
};

struct TileCacheEntry {
  TileKey key;
  sk_sp<SkImage> image;
  cc::PaintImage paint_image;
};

constexpr size_t kTileCacheLimit = 8;

std::list<TileCacheEntry>& TileCache() {
  static std::list<TileCacheEntry>* cache = new std::list<TileCacheEntry>();
  return *cache;
}

std::optional<TileKey> KeyFor(const ThemeStyle& style, float device_scale) {
  if (!(style.noise_factor > 0) || !std::isfinite(style.noise_factor) ||
      !(device_scale > 0)) {
    return std::nullopt;
  }
  TileKey key;
  key.legacy = style.uses_legacy_intensity;
  key.texture = key.legacy ? ThemeTexture::kGrain : style.texture;
  key.scale_milli = static_cast<int>(std::lround(device_scale * 1000));
  key.noise_milli =
      key.legacy ? static_cast<int>(std::lround(style.noise_factor * 1000)) : 0;
  return key;
}

const TileCacheEntry* CachedTile(const ThemeStyle& style, float device_scale) {
  const std::optional<TileKey> key = KeyFor(style, device_scale);
  if (!key) {
    return nullptr;
  }
  auto& cache = TileCache();
  for (auto it = cache.begin(); it != cache.end(); ++it) {
    if (it->key == *key) {
      cache.splice(cache.begin(), cache, it);
      return &cache.front();
    }
  }
  const texture::Tile tile =
      key->legacy ? texture::LegacyGrain(style.noise_factor, device_scale)
                  : texture::Intrinsic(key->texture, device_scale);
  sk_sp<SkImage> image = TileImageFromAlpha(tile);
  if (!image) {
    return nullptr;
  }
  TileCacheEntry entry;
  entry.key = *key;
  entry.paint_image = cc::PaintImageBuilder::WithDefault()
                          .set_id(cc::PaintImage::GetNextId())
                          .set_image(image, cc::PaintImage::GetNextContentId())
                          .TakePaintImage();
  entry.image = std::move(image);
  cache.push_front(std::move(entry));
  while (cache.size() > kTileCacheLimit) {
    cache.pop_back();
  }
  return &cache.front();
}

SkMatrix FieldMatrix(int n, const gfx::RectF& window_rect) {
  return SkMatrix::RectToRect(SkRect::MakeWH(static_cast<float>(n), static_cast<float>(n)),
                              gfx::RectFToSkRect(window_rect));
}

SkMatrix TileMatrix(float device_scale, const gfx::PointF& origin) {
  // A zero, negative, or NaN scale draws the tile at 1:1.
  const float inverse = device_scale > 0.0f ? 1.0f / device_scale : 1.0f;
  SkMatrix m = SkMatrix::Scale(inverse, inverse);
  m.postTranslate(origin.x(), origin.y());
  return m;
}

}  // namespace

SkColor4f ToSkColor4f(const Rgba& c) {
  return SkColor4f{static_cast<float>(c.r), static_cast<float>(c.g),
                   static_cast<float>(c.b), static_cast<float>(c.a)};
}

SkColor ToSkColor(const Rgba& c) {
  return SkColorSetARGB(ToByte(c.a), ToByte(c.r), ToByte(c.g), ToByte(c.b));
}

sk_sp<SkImage> MakeFieldImage(const ThemeStyle& style,
                              const gfx::SizeF& window_size,
                              bool is_active,
                              bool card_tint,
                              int resolution) {
  const int n = std::max(resolution, 2);
  return FieldImageFromPixels(
      MakeFieldPixels(style, window_size.width(), window_size.height(),
                      is_active, card_tint, n),
      n);
}

bool WindowTintUsesDisplayP3(const ThemeStyle& style) {
  // Blended editor fills that do not mix in sRGB (ThemeEvaluator's
  // mixes_in_srgb: light window scheme) keep the display-space law.
  return style.fill_kind == ThemeStyle::FillKind::kBlended &&
         !style.uses_legacy_intensity &&
         style.window_color_scheme != ContentAppearance::kLight;
}

sk_sp<SkImage> MakeWindowTintImage(const ThemeStyle& style,
                                   const gfx::SizeF& window_size,
                                   int resolution) {
  const int n = std::max(resolution, 2);
  return FieldImageFromPixels(
      MakeWindowTintPixels(style, window_size.width(), window_size.height(),
                           n),
      n,
      WindowTintUsesDisplayP3(style) ? DisplayP3() : SkColorSpace::MakeSRGB());
}

sk_sp<SkShader> MakeFieldShader(const sk_sp<SkImage>& field,
                                const gfx::RectF& window_rect) {
  if (!field) {
    return nullptr;
  }
  const SkMatrix m = FieldMatrix(field->width(), window_rect);
  return field->makeShader(SkTileMode::kClamp, SkTileMode::kClamp,
                           SkSamplingOptions(SkFilterMode::kLinear), &m);
}

sk_sp<SkImage> TextureTileImage(const ThemeStyle& style, float device_scale) {
  const TileCacheEntry* entry = CachedTile(style, device_scale);
  return entry ? entry->image : nullptr;
}

float TextureOpacity(const ThemeStyle& style) {
  if (style.uses_legacy_intensity) {
    return 1.0f;
  }
  return static_cast<float>(
      texture::LayerAlpha(style.texture, style.noise_factor));
}

sk_sp<SkShader> MakeTextureShader(const sk_sp<SkImage>& tile,
                                  float device_scale,
                                  float opacity,
                                  const gfx::PointF& origin) {
  if (!tile || !(opacity > 0)) {
    return nullptr;
  }
  const SkMatrix m = TileMatrix(device_scale, origin);
  sk_sp<SkShader> shader =
      tile->makeShader(SkTileMode::kRepeat, SkTileMode::kRepeat,
                       SkSamplingOptions(SkFilterMode::kNearest), &m);
  if (opacity >= 1.0f) {
    return shader;
  }
  // dst-in with a constant alpha scales the tile's coverage.
  return SkShaders::Blend(SkBlendMode::kDstIn, std::move(shader),
                          SkShaders::Color(SkColor4f{0, 0, 0, opacity},
                                           /*colorSpace=*/nullptr));
}

sk_sp<SkShader> MakeThemeShader(const ThemeStyle& style,
                                const gfx::RectF& window_rect,
                                bool is_active,
                                float device_scale,
                                bool card_tint) {
  sk_sp<SkShader> field = MakeFieldShader(
      MakeFieldImage(style, window_rect.size(), is_active, card_tint),
      window_rect);
  if (!field) {
    return nullptr;
  }
  sk_sp<SkShader> grain =
      MakeTextureShader(TextureTileImage(style, device_scale), device_scale,
                        TextureOpacity(style), window_rect.origin());
  if (!grain) {
    return field;
  }
  return SkShaders::Blend(SkBlendMode::kSrcOver, std::move(field),
                          std::move(grain));
}

sk_sp<SkShader> MakeCrossfadeShader(sk_sp<SkShader> from,
                                    sk_sp<SkShader> to,
                                    float t) {
  t = std::clamp(t, 0.0f, 1.0f);
  if (t <= 0.0f || !to) {
    return from;
  }
  if (t >= 1.0f || !from) {
    return to;
  }
  sk_sp<SkShader> faded =
      SkShaders::Blend(SkBlendMode::kDstIn, std::move(to),
                       SkShaders::Color(SkColor4f{0, 0, 0, t}, nullptr));
  return SkShaders::Blend(SkBlendMode::kSrcOver, std::move(from),
                          std::move(faded));
}

// ---------------------------------------------------------------------------
// ThemePainter

ThemePainter::ThemePainter() : style_(ThemeStyle::Default(ContentAppearance::kDark)) {}

ThemePainter::~ThemePainter() = default;

bool ThemePainter::SetStyle(const ThemeStyle& style) {
  if (style == style_) {
    return false;
  }
  style_ = style;
  field_size_.reset();
  tile_scale_ = 0;
  return true;
}

bool ThemePainter::SetActive(bool is_active) {
  if (is_active == is_active_) {
    return false;
  }
  is_active_ = is_active;
  if (!PaintsOpaque()) {
    // The window tint is built active: the native material owns the
    // window's active look, so nothing repaints.
    return false;
  }
  field_size_.reset();
  return true;
}

bool ThemePainter::SetCardTint(bool card_tint) {
  if (card_tint == card_tint_) {
    return false;
  }
  card_tint_ = card_tint;
  field_size_.reset();
  return true;
}

bool ThemePainter::SetTranslucentWindow(bool translucent) {
  if (translucent == translucent_window_) {
    return false;
  }
  translucent_window_ = translucent;
  field_size_.reset();
  return true;
}

bool ThemePainter::PaintsOpaque() const {
  return !(translucent_window_ && style_.is_vibrant && !card_tint_);
}

void ThemePainter::Prepare(const gfx::SizeF& window_size, float device_scale) {
  if (!field_size_ || *field_size_ != window_size) {
    const int n = tuning::kFieldResolution;
    sk_sp<SkImage> image =
        !PaintsOpaque()
            ? MakeWindowTintImage(style_, window_size, n)
            : FieldImageFromPixels(
                  MakeFieldPixels(style_, window_size.width(),
                                  window_size.height(), is_active_,
                                  card_tint_, n),
                  n);
    field_ = image ? cc::PaintImageBuilder::WithDefault()
                         .set_id(cc::PaintImage::GetNextId())
                         .set_image(std::move(image),
                                    cc::PaintImage::GetNextContentId())
                         .TakePaintImage()
                   : cc::PaintImage();
    field_size_ = window_size;
  }
  if (tile_scale_ != device_scale) {
    const TileCacheEntry* entry = CachedTile(style_, device_scale);
    tile_ = entry ? entry->paint_image : cc::PaintImage();
    tile_opacity_ = TextureOpacity(style_);
    tile_scale_ = device_scale;
  }
}

void ThemePainter::Paint(gfx::Canvas* canvas,
                         const gfx::Rect& dest,
                         const gfx::RectF& window_rect) {
  const float scale = canvas->image_scale();
  Prepare(window_rect.size(), scale);
  if (!field_) {
    return;
  }
  const int n = tuning::kFieldResolution;
  const SkMatrix field_matrix = FieldMatrix(n, window_rect);
  cc::PaintFlags field_flags;
  field_flags.setShader(cc::PaintShader::MakeImage(
      field_, SkTileMode::kClamp, SkTileMode::kClamp, &field_matrix));
  field_flags.setFilterQuality(cc::PaintFlags::FilterQuality::kLow);
  field_flags.setAntiAlias(false);
  canvas->DrawRect(gfx::RectF(dest), field_flags);

  if (tile_ && tile_opacity_ > 0) {
    const SkMatrix tile_matrix = TileMatrix(scale, window_rect.origin());
    cc::PaintFlags grain_flags;
    grain_flags.setShader(cc::PaintShader::MakeImage(
        tile_, SkTileMode::kRepeat, SkTileMode::kRepeat, &tile_matrix));
    grain_flags.setFilterQuality(cc::PaintFlags::FilterQuality::kNone);
    grain_flags.setAlphaf(std::min(1.0f, tile_opacity_));
    canvas->DrawRect(gfx::RectF(dest), grain_flags);
  }
}

}  // namespace open_unified::theme
