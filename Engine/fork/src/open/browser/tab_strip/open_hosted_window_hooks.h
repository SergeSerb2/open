// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#ifndef OPEN_BROWSER_TAB_STRIP_OPEN_HOSTED_WINDOW_HOOKS_H_
#define OPEN_BROWSER_TAB_STRIP_OPEN_HOSTED_WINDOW_HOOKS_H_

#include "ui/gfx/native_ui_types.h"

namespace content {
class WebContents;
}
namespace open_engine {
// Components cannot link to libcef. Open installs the AppKit host operation;
// an absent hook leaves Chromium's normal modal lifecycle unchanged.
struct HostedWindowHooks {
  void (*prepare_modal_dialog)(content::WebContents*, gfx::NativeWindow) = nullptr;
};
inline HostedWindowHooks& GetHostedWindowHooks() {
  static HostedWindowHooks hooks;
  return hooks;
}
}  // namespace open_engine
#endif
