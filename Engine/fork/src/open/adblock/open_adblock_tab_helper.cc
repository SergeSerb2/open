// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_tab_helper.h"

#include <cstdio>
#include <string>

#include "base/command_line.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "open/adblock/open_adblock_url_loader_factory.h"
#include "url/gurl.h"

namespace open_engine {

// static
OpenAdBlockTabHelper* OpenAdBlockTabHelper::GetOrCreate(
    content::WebContents* web_contents) {
  CreateForWebContents(web_contents);
  return FromWebContents(web_contents);
}

// static
void OpenAdBlockTabHelper::AddStopsForDocument(
    content::WeakDocumentPtr document,
    int blocked,
    int redirected) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  content::RenderFrameHost* rfh = document.AsRenderFrameHostIfValid();
  // Gone, or not the primary page (back/forward cache, prerender).
  if (!rfh || !rfh->GetPage().IsPrimary()) {
    return;
  }
  content::WebContents* web_contents =
      content::WebContents::FromRenderFrameHost(rfh);
  if (web_contents) {
    GetOrCreate(web_contents)->AddStops(blocked, redirected);
  }
}

OpenAdBlockTabHelper::OpenAdBlockTabHelper(content::WebContents* web_contents)
    : content::WebContentsUserData<OpenAdBlockTabHelper>(*web_contents),
      content::WebContentsObserver(web_contents) {}

OpenAdBlockTabHelper::~OpenAdBlockTabHelper() = default;

void OpenAdBlockTabHelper::AddStops(int blocked, int redirected) {
  blocked_ += blocked;
  redirected_ += redirected;
  if (loaded_) {
    // A count that arrives after the load still reaches the harness.
    MaybeLogSmoke();
  }
}

void OpenAdBlockTabHelper::ResetCounts() {
  blocked_ = 0;
  redirected_ = 0;
}

void OpenAdBlockTabHelper::DidFinishNavigation(
    content::NavigationHandle* navigation_handle) {
  if (navigation_handle->IsInPrimaryMainFrame() &&
      navigation_handle->HasCommitted() &&
      !navigation_handle->IsSameDocument()) {
    ResetCounts();
    loaded_ = false;
  }
}

void OpenAdBlockTabHelper::DidFinishLoad(
    content::RenderFrameHost* render_frame_host,
    const GURL& validated_url) {
  if (render_frame_host->IsInPrimaryMainFrame()) {
    loaded_ = true;
    MaybeLogSmoke();
  }
}

void OpenAdBlockTabHelper::MaybeLogSmoke() const {
#if !defined(OFFICIAL_BUILD)
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch("open-adblock-dir")) {
    return;
  }
  const GURL url = web_contents()->GetPrimaryMainFrame()->GetLastCommittedURL();
  // busy_us: process-wide, for the G-5 harness (§7.8).
  fprintf(stderr, "OpenAdBlockSmoke: blocked_count=%d url_host=%s busy_us=%llu\n",
          total_count(), std::string(url.host()).c_str(),
          static_cast<unsigned long long>(AdBlockMatcherBusyMicroseconds()));
#endif
}

WEB_CONTENTS_USER_DATA_KEY_IMPL(OpenAdBlockTabHelper);

}  // namespace open_engine
