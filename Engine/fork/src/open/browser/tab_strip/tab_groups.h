// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_TAB_STRIP_TAB_GROUPS_H_
#define OPEN_BROWSER_TAB_STRIP_TAB_GROUPS_H_

// Only chrome/browser/ui/browser.cc (patch 0304) and open_tab_strip.cc
// include this, so the CEF header below reaches no other Chromium file.
#include "cef/libcef/browser/chrome/browser_delegate.h"

namespace open_engine {

// False for the CEF params of a hidden tab-strip Browser: it gets no tab
// group model, as Chrome's app windows do (patch 0304). Open v1 decision:
// folders are not tab groups. There is no evidence that Arc maps folders to
// groups (docs/re/arccore-engine.md §4.3.1); that chrome.tabs.group fails
// and that folder tabs report pinned: true are Open's choices, not Arc facts.
bool SupportsTabGroups(const cef::BrowserDelegate::CreateParams* cef_params);

}  // namespace open_engine

#endif  // OPEN_BROWSER_TAB_STRIP_TAB_GROUPS_H_
