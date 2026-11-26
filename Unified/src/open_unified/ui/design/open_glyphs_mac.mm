// Copyright 2026 The Open Authors. All rights reserved.
//
// macOS SF Symbols for open_glyphs.h: the system symbol is configured with
// the Icons.swift point size and weight and rasterized once per (name, size,
// weight) into a template gfx::ImageSkia (black ink, alpha coverage) with a
// representation for every supported scale. Draw-time tinting is a SrcIn
// color filter (open_glyphs.cc DrawSystemSymbol). No icon assets are copied:
// the symbols come from the running system.

#include "open_unified/ui/design/open_glyphs.h"

#import <AppKit/AppKit.h>

#include <cmath>
#include <map>
#include <string>
#include <tuple>

#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_util_mac.h"

namespace open_unified::glyphs {

namespace {

NSFontWeight ToNSFontWeight(SymbolWeight weight) {
  switch (weight) {
    case SymbolWeight::kRegular:
      return NSFontWeightRegular;
    case SymbolWeight::kMedium:
      return NSFontWeightMedium;
    case SymbolWeight::kSemibold:
      return NSFontWeightSemibold;
    case SymbolWeight::kBold:
      return NSFontWeightBold;
  }
  return NSFontWeightRegular;
}

using SymbolKey = std::tuple<std::string, int, SymbolWeight>;

// Bounded: the sidebar uses a few dozen (glyph, size) pairs plus one entry
// per distinct Space symbol.
constexpr size_t kSymbolCacheLimit = 256;

std::map<SymbolKey, gfx::ImageSkia>& SymbolCache() {
  static base::NoDestructor<std::map<SymbolKey, gfx::ImageSkia>> cache;
  return *cache;
}

}  // namespace

gfx::ImageSkia SystemSymbolImage(std::string_view name,
                                 float point_size,
                                 SymbolWeight weight) {
  if (name.empty() || !(point_size > 0)) {
    return gfx::ImageSkia();
  }
  const SymbolKey key{std::string(name),
                      static_cast<int>(std::lround(point_size * 100)), weight};
  auto& cache = SymbolCache();
  if (auto it = cache.find(key); it != cache.end()) {
    return it->second;
  }
  gfx::ImageSkia result;
  @autoreleasepool {
    NSImage* base =
        [NSImage imageWithSystemSymbolName:base::SysUTF8ToNSString(name)
                  accessibilityDescription:nil];
    if (base) {
      NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration
          configurationWithPointSize:point_size
                              weight:ToNSFontWeight(weight)];
      NSImage* image = [base imageWithSymbolConfiguration:config] ?: base;
      [image setTemplate:YES];  // `template` is a C++ keyword.
      // The symbol's own size (points), so its ink keeps the tuned box.
      const NSSize size = image.size;
      if (size.width > 0 && size.height > 0) {
        result = gfx::ImageSkiaFromResizedNSImage(
            image, NSMakeSize(std::ceil(size.width), std::ceil(size.height)));
      }
    }
  }
  if (cache.size() >= kSymbolCacheLimit) {
    cache.clear();
  }
  // Unknown names cache a null image too (no repeated lookups).
  cache.emplace(key, result);
  return result;
}

}  // namespace open_unified::glyphs
