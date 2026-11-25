// Copyright 2026 The Open Authors. All rights reserved.
//
// Open's own vector glyphs, drawn with Skia paths (no copied icon assets).
// Ink boxes follow docs/design.md section 4 so the 1x ink matches the
// measured Arc ink boxes (toggle 19 x 15, back/forward 15 x 12, reload
// 14 x 17, magnifier 12 x 12, copy 15 x 14, Site Control 16 x 16, New Tab
// plus 11 x 11, row close 10 x 10, unload 14 x 2, bottom plus 14 x 14,
// Library 14 x 16).

#ifndef OPEN_UNIFIED_UI_DESIGN_OPEN_GLYPHS_H_
#define OPEN_UNIFIED_UI_DESIGN_OPEN_GLYPHS_H_

#include <string>
#include <string_view>

#include "open_unified/core/model/open_types.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/size_f.h"
#include "ui/gfx/geometry/vector2d_f.h"

namespace gfx {
class Canvas;
class FontList;
}

namespace open_unified::glyphs {

enum class Glyph {
  kSidebarToggle,
  kBack,
  kForward,
  kReload,
  kStop,
  kMore,         // horizontal ellipsis
  kMagnifier,
  kLink,         // Copy URL
  kSiteControls,
  kPlus,         // New Tab row
  kBottomPlus,
  kClose,        // row close
  kMinus,        // row unload
  kChevronDown,
  kChevronRight,
  kArrowDown,    // "Clear"
  kSpeaker,
  kSpeakerMuted,
  kLibrary,
  kFolderClosed,
  kFolderOpen,
  kPlanet,
  kWindowClose,
  kWindowMinimize,
  kWindowZoom,
  kPuzzle,       // extension without icon
};

// The measured ink box of a glyph, in points.
gfx::SizeF InkSize(Glyph glyph);

// Draws `glyph` with its ink box centered in `bounds` (plus `offset`).
void Draw(gfx::Canvas* canvas,
          Glyph glyph,
          const gfx::RectF& bounds,
          SkColor color,
          gfx::Vector2dF offset = gfx::Vector2dF());

// A rounded tile with the first letter of `label` (missing favicon).
void DrawLetterTile(gfx::Canvas* canvas,
                    const gfx::RectF& rect,
                    std::u16string_view label,
                    SkColor background,
                    SkColor foreground);

// A Space icon: emoji text, the planet mark for "planet"/unknown named
// icons, a dot for SF Symbol names (not portable), else the title's first
// letter. `opacity` multiplies the color; `grayscale` desaturates (other
// Spaces in the bottom switcher are gray at 0.55).
void DrawSpaceIcon(gfx::Canvas* canvas,
                   const SpaceIcon* icon,
                   std::u16string_view title,
                   const gfx::RectF& box,
                   const gfx::FontList& emoji_font,
                   SkColor tint,
                   float opacity,
                   bool grayscale = false);

}  // namespace open_unified::glyphs

#endif  // OPEN_UNIFIED_UI_DESIGN_OPEN_GLYPHS_H_
