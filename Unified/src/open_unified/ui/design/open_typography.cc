// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/design/open_typography.h"

#include <array>
#include <cmath>
#include <string>

#include "base/check_op.h"
#include "ui/base/resource/resource_bundle.h"

namespace open_unified::typography {

namespace {

using Weight = gfx::Font::Weight;

int BaseFontSize() {
  static const int size = ui::ResourceBundle::GetSharedInstance()
                              .GetFontListWithDelta(0)
                              .GetFontSize();
  return size;
}

}  // namespace

FontToken TokenFor(OpenFont font) {
  switch (font) {
    case OpenFont::kTabTitle:
      return {14, Weight::NORMAL};
    case OpenFont::kFolderTitle:
      return {14, Weight::SEMIBOLD};
    case OpenFont::kNewTab:
      return {14, Weight::NORMAL};
    case OpenFont::kSpaceTitle:
      return {13, Weight::SEMIBOLD};
    case OpenFont::kUrlPlaceholder:
      return {13, Weight::MEDIUM};
    case OpenFont::kUrlHost:
      return {13, Weight::NORMAL};
    case OpenFont::kClearLabel:
      return {11, Weight::SEMIBOLD};
    case OpenFont::kTooltip:
      return {13, Weight::MEDIUM};
    case OpenFont::kTooltipSubtitle:
      return {12, Weight::NORMAL};
    case OpenFont::kKeycap:
      return {12, Weight::MEDIUM};
    case OpenFont::kCommandBarInput:
      return {18, Weight::MEDIUM};
    case OpenFont::kCommandBarRow:
      return {13, Weight::MEDIUM};
    case OpenFont::kSwitcherEmoji:
      return {12, Weight::NORMAL};
    case OpenFont::kHeaderEmoji:
      return {14, Weight::NORMAL};
    case OpenFont::kToast:
      return {14, Weight::MEDIUM};
    case OpenFont::kToastSubtitle:
      return {12, Weight::NORMAL};
    case OpenFont::kExtensionName:
      return {13, Weight::NORMAL};
    case OpenFont::kLittleOpenHost:
      return {13, Weight::NORMAL};
    case OpenFont::kLittleOpenProfile:
      return {13, Weight::MEDIUM};
    case OpenFont::kSplitCellTitle:
      return {13, Weight::NORMAL};
    case OpenFont::kCount:
      break;
  }
  return {13, Weight::NORMAL};
}

const gfx::FontList& Make(int size, gfx::Font::Weight weight) {
  // ResourceBundle caches font lists per (typeface, delta, weight) and
  // returns a stable reference.
  return ui::ResourceBundle::GetSharedInstance().GetFontListForDetails(
      ui::ResourceBundle::FontDetails(std::string(), size - BaseFontSize(),
                                      weight));
}

const gfx::FontList& Get(OpenFont font) {
  DCHECK_LT(static_cast<int>(font), static_cast<int>(OpenFont::kCount));
  static std::array<const gfx::FontList*, static_cast<size_t>(OpenFont::kCount)>
      cache{};
  const gfx::FontList*& slot = cache[static_cast<size_t>(font)];
  if (!slot) {
    const FontToken token = TokenFor(font);
    slot = &Make(token.size, token.weight);
  }
  return *slot;
}

int TextTopForBaseline(const gfx::FontList& font_list, float baseline_y) {
  return static_cast<int>(std::lround(baseline_y)) - font_list.GetBaseline();
}

}  // namespace open_unified::typography
