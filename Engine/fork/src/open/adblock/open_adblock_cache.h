// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_CACHE_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_CACHE_H_

class CefBrowserContext;

namespace open_engine {

class OpenAdBlockService;

// Called by the CEF owner at service creation, before any control or load.
// UI thread only. The stored callback uses the context's weak getter, so it
// cannot keep a context alive or use it after shutdown.
void ConfigureAdBlockRendererCache(CefBrowserContext* context,
                                  OpenAdBlockService* service);

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_CACHE_H_
