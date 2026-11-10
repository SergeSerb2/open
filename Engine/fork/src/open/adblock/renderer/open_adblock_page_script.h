// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_RENDERER_OPEN_ADBLOCK_PAGE_SCRIPT_H_
#define OPEN_ADBLOCK_RENDERER_OPEN_ADBLOCK_PAGE_SCRIPT_H_

#include <string_view>

namespace open_engine {
// Fixed code only. Never interpolate selectors, exceptions or page text.
std::string_view AdBlockClassIdObserverScript();
}  // namespace open_engine

#endif  // OPEN_ADBLOCK_RENDERER_OPEN_ADBLOCK_PAGE_SCRIPT_H_
