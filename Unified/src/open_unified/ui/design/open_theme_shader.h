// Copyright 2026 The Open Authors. All rights reserved.
//
// Skia rendering of Open's Space theme field (port of ThemeBackgroundView's
// field and grain layers). The field is computed on the CPU into a 64 x 64
// RGBA F16 image (extended sRGB) and stretched over the window with bilinear
// sampling; it is rebuilt only when the theme, the active state or the window
// size changes. The texture (grain / sand / denim / tweed) is one procedural
// tile of black-with-alpha repeated from the window origin.

#ifndef OPEN_UNIFIED_UI_DESIGN_OPEN_THEME_SHADER_H_
#define OPEN_UNIFIED_UI_DESIGN_OPEN_THEME_SHADER_H_

#include <optional>

#include "cc/paint/paint_image.h"
#include "open_unified/ui/design/open_theme_math.h"
#include "third_party/skia/include/core/SkColor.h"
#include "third_party/skia/include/core/SkImage.h"
#include "third_party/skia/include/core/SkRefCnt.h"
#include "third_party/skia/include/core/SkShader.h"
#include "ui/gfx/geometry/point_f.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/size_f.h"

namespace gfx {
class Canvas;
}

namespace open_unified::theme {

// --- Color conversion -------------------------------------------------------
SkColor4f ToSkColor4f(const Rgba& c);
// 8-bit, clamped to sRGB.
SkColor ToSkColor(const Rgba& c);

// --- Raw Skia builders (SkCanvas / snapshots / automation PNGs) -------------
// 64 x 64 extended-sRGB F16 field image for `window_size`.
sk_sp<SkImage> MakeFieldImage(const ThemeStyle& style,
                              const gfx::SizeF& window_size,
                              bool is_active,
                              bool card_tint = false,
                              int resolution = tuning::kFieldResolution);
// Bilinear field stretched over `window_rect` (pixel centers map to uv).
sk_sp<SkShader> MakeFieldShader(const sk_sp<SkImage>& field,
                                const gfx::RectF& window_rect);
// Texture tile at `device_scale` (cached, LRU of 8). Null when the theme has
// no texture (noise 0).
sk_sp<SkImage> TextureTileImage(const ThemeStyle& style, float device_scale);
// Opacity the tile is drawn at: legacy imports 1 (alpha baked into the
// tile), editor themes noise * scale (grain 0.80, sand 0.15, denim 0.60,
// tweed 0.40).
float TextureOpacity(const ThemeStyle& style);
// Repeating texture shader, tiles anchored at `origin` (window top-left).
sk_sp<SkShader> MakeTextureShader(const sk_sp<SkImage>& tile,
                                  float device_scale,
                                  float opacity,
                                  const gfx::PointF& origin);
// The complete Space background: field with the texture source-over.
sk_sp<SkShader> MakeThemeShader(const ThemeStyle& style,
                                const gfx::RectF& window_rect,
                                bool is_active,
                                float device_scale,
                                bool card_tint = false);
// Linear cross-fade: `to` at opacity t over `from` (both opaque).
sk_sp<SkShader> MakeCrossfadeShader(sk_sp<SkShader> from,
                                    sk_sp<SkShader> to,
                                    float t);

// --- Views painter -------------------------------------------------------------
// Caches the field and tile as cc::PaintImages (stable ids, so the GPU raster
// cache uploads them once) and paints them into a gfx::Canvas.
class ThemePainter {
 public:
  ThemePainter();
  ThemePainter(const ThemePainter&) = delete;
  ThemePainter& operator=(const ThemePainter&) = delete;
  ~ThemePainter();

  // Returns true when the painted result changes.
  bool SetStyle(const ThemeStyle& style);
  bool SetActive(bool is_active);
  bool SetCardTint(bool card_tint);
  const ThemeStyle& style() const { return style_; }

  // Fills `dest` (canvas coordinates). The field maps to `window_rect`, also
  // in canvas coordinates, so a child view can paint its own part of the
  // window field (e.g. the hover-reveal card).
  void Paint(gfx::Canvas* canvas,
             const gfx::Rect& dest,
             const gfx::RectF& window_rect);

  // Rebuilds the field for `window_size` now (cheap: 4096 evaluations).
  void Prepare(const gfx::SizeF& window_size, float device_scale);

 private:
  ThemeStyle style_;
  bool is_active_ = true;
  bool card_tint_ = false;
  std::optional<gfx::SizeF> field_size_;
  cc::PaintImage field_;
  float tile_scale_ = 0;
  cc::PaintImage tile_;
  float tile_opacity_ = 0;
};

}  // namespace open_unified::theme

#endif  // OPEN_UNIFIED_UI_DESIGN_OPEN_THEME_SHADER_H_
