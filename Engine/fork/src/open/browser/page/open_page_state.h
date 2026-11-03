// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_PAGE_OPEN_PAGE_STATE_H_
#define OPEN_BROWSER_PAGE_OPEN_PAGE_STATE_H_

namespace content {
class WebContents;
}

namespace open_engine {

// History swipe hooks (patch 0501, chrome_render_widget_host_view_mac_*):
// the swiper asks these before it starts and before it draws its overlay,
// and reports its phases. All UI thread; |web_contents| may be null.
bool HistorySwipeEnabled(content::WebContents* web_contents);
bool HistorySwipeDrawsOverlay(content::WebContents* web_contents);
// phase: 0 began, 1 changed, 2 completed, 3 cancelled; direction: 0 back,
// 1 forward.
void ReportHistorySwipe(content::WebContents* web_contents,
                        int phase,
                        int direction,
                        double progress);

// Fills the swiper hook table once and gives |web_contents| a
// HistorySwipingControl that reads HistorySwipeEnabled
// (open_history_swipe_mac.mm).
void InstallHistorySwipeHooks(content::WebContents* web_contents);

}  // namespace open_engine

#endif  // OPEN_BROWSER_PAGE_OPEN_PAGE_STATE_H_
