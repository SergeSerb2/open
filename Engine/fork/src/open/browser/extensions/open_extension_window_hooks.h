// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#ifndef OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSION_WINDOW_HOOKS_H_
#define OPEN_BROWSER_EXTENSIONS_OPEN_EXTENSION_WINDOW_HOOKS_H_
#include <string>
#include <vector>
#include "ui/gfx/geometry/rect.h"
#include "url/gurl.h"
class BrowserWindowInterface;
class Profile;
namespace open_engine {
// Chromium cannot depend on libcef. Missing hooks or parents fail closed;
// extension requests must never fall through to a Chrome Views window.
struct ExtensionWindowHooks {
  BrowserWindowInterface* (*create)(Profile*, bool, const gfx::Rect&,
      const std::string&, const std::vector<GURL>&, bool) = nullptr;
};
inline ExtensionWindowHooks& GetExtensionWindowHooks() {
  static ExtensionWindowHooks hooks;
  return hooks;
}
}  // namespace open_engine
#endif
