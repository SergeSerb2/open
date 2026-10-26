// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_TAB_STRIP_HIDDEN_BROWSER_H_
#define OPEN_BROWSER_TAB_STRIP_HIDDEN_BROWSER_H_

#include "cef/libcef/browser/chrome/browser_delegate.h"

class BrowserWindowInterface;

namespace open_engine {

// True if |browser| is the hidden Browser of an open_engine::OpenTabStrip: a
// real Browser with no BrowserView (docs/engine-patches.md, P1). Chrome code
// that treats "no Views UI" as "unit test" (CHECK_IS_TEST) checks this first
// (Engine/fork/patches/chromium/0302-open-hidden-browser-ui.patch).
bool IsHiddenTabStripBrowser(const BrowserWindowInterface* browser);

// False for the CEF params of a hidden tab-strip Browser: Open does not map
// its folders to tab groups (Arc does not either; docs/re/arccore-engine.md
// §4.3), so the Browser gets no tab group model and chrome.tabs.group fails
// with Chrome's "does not support tab groups" error instead of making groups
// the sidebar cannot show. Called from the Browser constructor
// (Engine/fork/patches/chromium/0303-open-hidden-browser-no-tab-groups.patch).
bool SupportsTabGroups(const cef::BrowserDelegate::CreateParams* cef_params);

}  // namespace open_engine

#endif  // OPEN_BROWSER_TAB_STRIP_HIDDEN_BROWSER_H_
