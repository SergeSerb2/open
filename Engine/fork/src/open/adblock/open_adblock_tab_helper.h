// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_TAB_HELPER_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_TAB_HELPER_H_

#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"

namespace open_engine {

// Per-WebContents blocked and redirected counts for the Site Control Center
// (Arc's blockedResourceCount; adblock-fork §7.5). Owned by the WebContents;
// UI thread only. A new primary main-frame document resets both counts; a
// same-document navigation (pushState) keeps them.
class OpenAdBlockTabHelper
    : public content::WebContentsUserData<OpenAdBlockTabHelper>,
      public content::WebContentsObserver {
 public:
  static OpenAdBlockTabHelper* GetOrCreate(content::WebContents* web_contents);
  // Adds counts for |document| when it still exists and belongs to its
  // tab's primary page; else drops them (§7.5: a lost count is fine, a
  // count of a closed document leaking into the next page is not).
  static void AddStopsForDocument(content::WeakDocumentPtr document,
                                  int blocked,
                                  int redirected);

  OpenAdBlockTabHelper(const OpenAdBlockTabHelper&) = delete;
  OpenAdBlockTabHelper& operator=(const OpenAdBlockTabHelper&) = delete;
  ~OpenAdBlockTabHelper() override;

  void AddStops(int blocked, int redirected);
  int blocked_count() const { return blocked_; }
  int redirected_count() const { return redirected_; }
  int total_count() const { return blocked_ + redirected_; }
  void ResetCounts();

  // content::WebContentsObserver:
  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override;
  void DidFinishLoad(content::RenderFrameHost* render_frame_host,
                     const GURL& validated_url) override;

 private:
  explicit OpenAdBlockTabHelper(content::WebContents* web_contents);
  friend class content::WebContentsUserData<OpenAdBlockTabHelper>;

  // Development builds with --open-adblock-dir: the smoke harness's count
  // line on stderr (adblock-fork §13.1), the host only (§6.4).
  void MaybeLogSmoke() const;

  int blocked_ = 0;
  int redirected_ = 0;
  bool loaded_ = false;

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_TAB_HELPER_H_
