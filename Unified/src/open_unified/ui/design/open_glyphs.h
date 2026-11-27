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

#include <optional>
#include <string>
#include <string_view>

#include "open_unified/core/model/open_types.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/size_f.h"
#include "ui/gfx/geometry/vector2d_f.h"
#include "ui/gfx/image/image_skia.h"

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
  kWindowMaximize,
  kWindowRestore,
  kWindowZoom,
  kPuzzle,       // extension without icon
  kEyeglasses,   // Incognito header mark (SF eyeglasses on macOS)
  kLockOpen,     // insecure HTTP padlock (unlocked shackle)
  kInfo,         // info badge (toasts)
  kWarning,      // warning triangle (toasts)
  kError,        // error octagon/cross (toasts)
  kOpenDoorway,  // Open doorway-and-sun app menu mark (Win/Linux)
  kReturnArrow,  // Pinned-tab reset ("Back to Pinned URL")
};

// The measured ink box of a glyph, in points.
gfx::SizeF InkSize(Glyph glyph);

// --- System symbols (macOS SF Symbols) -------------------------------------
// On macOS every sidebar glyph that Icons.swift maps to an SF Symbol is drawn
// from the real system symbol at the Spec's point size and weight (tuned so
// the 1x ink matches Arc's measured ink box). Library, folders, the planet
// mark and the window glyphs stay Open's own vectors. Windows and Linux draw
// the Skia paths below.

enum class SymbolWeight { kRegular, kMedium, kSemibold, kBold };

struct SymbolSpec {
  const char* name = nullptr;
  float point_size = 0;
  SymbolWeight weight = SymbolWeight::kRegular;
};

// The Icons.swift spec of `glyph`, or nullopt for Open's own vectors.
std::optional<SymbolSpec> SystemSymbolFor(Glyph glyph);

// The SF Symbol for a named Space icon identifier (NamedSpaceIcons.swift),
// "circle.dotted" for unknown names.
std::string_view NamedSpaceIconSymbol(std::string_view name);

// Draws Open's crisp vector art for any named Space icon identifier (or its
// corresponding SF Symbol name) on platforms without SF Symbols. Returns false
// only for genuinely unknown names.
bool DrawNamedSpaceIcon(gfx::Canvas* canvas,
                        std::string_view name,
                        const gfx::RectF& box,
                        SkColor color);

// A template image (black ink with alpha) of the system symbol `name`,
// rasterized for every supported scale and cached. Null when the platform
// has no system symbols (Windows, Linux) or the name is unknown.
// Implemented in open_glyphs_mac.mm on macOS.
gfx::ImageSkia SystemSymbolImage(std::string_view name,
                                 float point_size,
                                 SymbolWeight weight);

// Draws the system symbol `name` tinted with `color`, centered in `bounds`
// (plus `offset`). Returns false (draws nothing) when it is unavailable.
bool DrawSystemSymbol(gfx::Canvas* canvas,
                      std::string_view name,
                      float point_size,
                      SymbolWeight weight,
                      const gfx::RectF& bounds,
                      SkColor color,
                      gfx::Vector2dF offset = gfx::Vector2dF());

// Draws `glyph` with its ink box centered in `bounds` (plus `offset`).
void Draw(gfx::Canvas* canvas,
          Glyph glyph,
          const gfx::RectF& bounds,
          SkColor color,
          gfx::Vector2dF offset = gfx::Vector2dF());

// Draws a window caption control glyph (`kWindowMinimize`, `kWindowMaximize`,
// `kWindowRestore`, `kWindowClose`) centered in `bounds` using physical-pixel-
// snapped stroke math (`1.0f / dsf` for Windows 11 Fluent, `1.25f` for Linux
// CSD).
void DrawWindowControlGlyph(gfx::Canvas* canvas,
                            Glyph glyph,
                            const gfx::RectF& bounds,
                            SkColor color,
                            bool linux_csd = false);

// A rounded tile with the first letter of `label` (missing favicon).
void DrawLetterTile(gfx::Canvas* canvas,
                    const gfx::RectF& rect,
                    std::u16string_view label,
                    SkColor background,
                    SkColor foreground);

// A Space icon: emoji text; SF Symbol and named icons as the real system
// symbol on macOS (NodeIconRenderer: point size = box height - 3, Medium);
// Open's planet mark when no icon is set and wherever a symbol is not
// available (Windows, Linux). Never the title's first letter. `title` is
// kept for API compatibility. `opacity` multiplies the color; `grayscale`
// desaturates (other Spaces in the bottom switcher are gray at 0.55).
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
