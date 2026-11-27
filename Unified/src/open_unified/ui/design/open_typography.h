// Copyright 2026 The Open Authors. All rights reserved.
//
// Open's type scale (port of Packages/OpenKit/Sources/OpenDesign/
// Typography.swift). Sizes are absolute DIP sizes of the platform UI font
// (SF Pro on macOS, Segoe UI Variable / Segoe UI on Windows, the desktop UI
// font on Linux). Chromium's base UI font size differs per OS, so each token
// is resolved as a delta from the base font and cached by ResourceBundle.

#ifndef OPEN_UNIFIED_UI_DESIGN_OPEN_TYPOGRAPHY_H_
#define OPEN_UNIFIED_UI_DESIGN_OPEN_TYPOGRAPHY_H_

#include "ui/gfx/font.h"
#include "ui/gfx/font_list.h"

namespace open_unified::typography {

enum class OpenFont {
  kTabTitle,         // 14 Regular (NCC 0.992..0.994)
  kFolderTitle,      // 14 Semibold
  kNewTab,           // 14 Regular
  kSpaceTitle,       // 13 Semibold (Space header)
  kUrlPlaceholder,   // 13 Medium
  kUrlHost,          // 13 Regular
  kClearLabel,       // 11 Semibold (Pinned/Today "Clear")
  kTooltip,          // 13 Medium (guess)
  kTooltipSubtitle,  // 12 Regular (guess)
  kKeycap,           // 12 Medium (guess)
  kCommandBarInput,  // 18 Medium
  kCommandBarRow,    // 13 Medium
  kSwitcherEmoji,    // 12 Regular (bottom switcher emoji)
  kHeaderEmoji,      // 14 Regular (Space header emoji)
  kToast,            // 14 Medium
  kToastSubtitle,    // 12 Regular (guess)
  kExtensionName,    // 13 Regular
  kLittleOpenHost,   // 13 Regular
  kLittleOpenProfile,  // 13 Medium
  kSplitCellTitle,   // 13 Regular (guess: split row cell titles)
  kCount,
};

struct FontToken {
  int size = 13;
  gfx::Font::Weight weight = gfx::Font::Weight::NORMAL;
};

FontToken TokenFor(OpenFont font);

// Cached font list for a token. UI thread only.
const gfx::FontList& Get(OpenFont font);

// Font list for an arbitrary absolute size and weight.
const gfx::FontList& Make(int size, gfx::Font::Weight weight);

// Clears cached font lists and base font size so DPI or theme/font changes
// refresh metrics on the next lookup. UI thread only.
void InvalidateCache();

// Top y of a text box whose baseline must sit at `baseline_y` (Swift frames
// record baselines: tab titles 25 pt below the row top, URL text 14 pt below
// the text frame top, Space title 14 pt below its frame top).
int TextTopForBaseline(const gfx::FontList& font_list, float baseline_y);

}  // namespace open_unified::typography

#endif  // OPEN_UNIFIED_UI_DESIGN_OPEN_TYPOGRAPHY_H_
