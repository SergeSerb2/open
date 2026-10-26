// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_TAB_STRIP_HIDDEN_BROWSER_H_
#define OPEN_BROWSER_TAB_STRIP_HIDDEN_BROWSER_H_

class BrowserWindowInterface;

namespace content {
class WebContents;
}

namespace open_engine {

// True if |browser| is the hidden Browser of an open_engine::OpenTabStrip: a
// real Browser with no BrowserView (docs/engine-patches.md, P1). Chrome code
// that treats "no Views UI" as "unit test" (CHECK_IS_TEST) checks this first
// (Engine/fork/patches/chromium/0302-open-hidden-browser-ui.patch).
bool IsHiddenTabStripBrowser(const BrowserWindowInterface* browser);

// True if |contents| is a tab of a hidden tab-strip Browser. Chrome's own
// discarding skips these tabs: a discard replaces the tab's WebContents, and
// the embedder sleeps tabs itself (tab_lifecycle_unit.cc, patch 0303).
bool IsHostedTab(content::WebContents* contents);

// chrome.tabs.discard of a hosted tab: asks the embedder, whose tab sleep
// unloads the tab later. True if it will (tabs_api.cc, patch 0303).
bool RequestHostedTabDiscard(content::WebContents* contents);

}  // namespace open_engine

#endif  // OPEN_BROWSER_TAB_STRIP_HIDDEN_BROWSER_H_
