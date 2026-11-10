// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_RENDERER_OPEN_ADBLOCK_ISOLATED_WORLD_H_
#define OPEN_ADBLOCK_RENDERER_OPEN_ADBLOCK_ISOLATED_WORLD_H_

#include "chrome/common/chrome_isolated_world_ids.h"

namespace open_engine {

// macOS world 7, reserved by Chromium patch 0902 below extensions (8).
// Chrome internal features use 4; Open/P7 page scripts and Boosts use 6.
inline constexpr int kOpenAdBlockIsolatedWorldId = ISOLATED_WORLD_ID_OPEN + 1;
static_assert(kOpenAdBlockIsolatedWorldId == 7);
static_assert(kOpenAdBlockIsolatedWorldId ==
              ISOLATED_WORLD_ID_OPEN_ADBLOCK_RESERVED);
static_assert(kOpenAdBlockIsolatedWorldId < ISOLATED_WORLD_ID_EXTENSIONS);
static_assert(kOpenAdBlockIsolatedWorldId <= content::ISOLATED_WORLD_ID_MAX);

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_RENDERER_OPEN_ADBLOCK_ISOLATED_WORLD_H_
