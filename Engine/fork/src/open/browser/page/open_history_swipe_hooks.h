// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_PAGE_OPEN_HISTORY_SWIPE_HOOKS_H_
#define OPEN_BROWSER_PAGE_OPEN_HISTORY_SWIPE_HOOKS_H_

namespace open_engine {

// History swipe hooks (page-platform EP-1, patch 0501). Chromium's
// HistoryOverlayController (chrome/browser/ui/cocoa) calls them for the
// trackpad and the Magic Mouse swipe; the Open page API fills the table
// (open_history_swipe_mac.mm) the first time an embedder sets a page handler
// or swipe options. Header-only on purpose: chrome/browser/ui cannot depend
// on libcef, and both are linked into the one framework binary. Main thread.
struct HistorySwipeHooks {
  // The CEF browser id of the page whose view is |ns_view| (an NSView*), or 0.
  int (*browser_for_view)(void* ns_view) = nullptr;
  // False if that page asked for no engine overlay.
  bool (*draws_overlay)(int browser_id) = nullptr;
  // phase: 0 began, 1 changed, 2 completed, 3 cancelled; direction: 0 back,
  // 1 forward; progress 0...1.
  void (*report)(int browser_id, int phase, int direction, double progress) =
      nullptr;
};

inline HistorySwipeHooks& GetHistorySwipeHooks() {
  static HistorySwipeHooks hooks;
  return hooks;
}

}  // namespace open_engine

#endif  // OPEN_BROWSER_PAGE_OPEN_HISTORY_SWIPE_HOOKS_H_
