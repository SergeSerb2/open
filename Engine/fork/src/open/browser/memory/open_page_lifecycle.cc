// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Freeze, discard in place, and the unload-handler flag for tab sleeping
// (docs/plans/memory-fork.md §5.4-§5.6). The functions are declared in
// cef/include/cef_page_lifecycle.h; the embedder owns all sleep policy.

#include "cef/include/cef_page_lifecycle.h"

#include <utility>

#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/ref_counted.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/thread_util.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "content/public/common/content_features.h"

namespace open_engine {

namespace {

// Delay before the one retry of a discard that Chromium ignored because a
// navigation was about to commit (FrameTree::Discard).
constexpr int64_t kDiscardRetryDelayMs = 100;

// A discard settles at the latest after this long, even if the renderer never
// acknowledges it (RenderFrameHostImpl::DiscardFrame waits for the renderer).
constexpr int64_t kDiscardSettleDeadlineMs = 3000;

content::WebContents* WebContentsFor(CefRefPtr<CefBrowser> browser) {
  auto host = CefBrowserHostBase::FromBrowser(browser);
  return host ? host->GetWebContents() : nullptr;
}

// Freeze state of one page. WebContents has no "is frozen" getter, and only
// the embedder freezes Open's pages, so the flag follows our calls. Content
// unfreezes a page when it becomes visible; so does the flag.
class PageLifecycleState
    : public content::WebContentsObserver,
      public content::WebContentsUserData<PageLifecycleState> {
 public:
  PageLifecycleState(const PageLifecycleState&) = delete;
  PageLifecycleState& operator=(const PageLifecycleState&) = delete;
  ~PageLifecycleState() override = default;

  bool frozen() const { return frozen_; }
  void set_frozen(bool frozen) { frozen_ = frozen; }

 private:
  friend class content::WebContentsUserData<PageLifecycleState>;

  explicit PageLifecycleState(content::WebContents* web_contents)
      : content::WebContentsObserver(web_contents),
        content::WebContentsUserData<PageLifecycleState>(*web_contents) {}

  // content::WebContentsObserver:
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (visibility == content::Visibility::VISIBLE) {
      frozen_ = false;
    }
  }
  void PrimaryPageChanged(content::Page& page) override { frozen_ = false; }

  bool frozen_ = false;

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(PageLifecycleState);

void SetFrozenFlag(content::WebContents* web_contents, bool frozen) {
  if (frozen) {
    PageLifecycleState::CreateForWebContents(web_contents);
  }
  if (auto* state = PageLifecycleState::FromWebContents(web_contents)) {
    state->set_frozen(frozen);
  }
}

bool IsFrozen(content::WebContents* web_contents) {
  auto* state = PageLifecycleState::FromWebContents(web_contents);
  return state && state->frozen();
}

// Runs the embedder's callback exactly once on the UI thread: when Chromium
// reports the discard, when the retry gives up, at the deadline, or when the
// last reference goes away (Chromium drops its closure unrun when it ignores
// a discard or the page closes first).
class DiscardRequest : public base::RefCountedThreadSafe<DiscardRequest> {
 public:
  explicit DiscardRequest(CefRefPtr<CefCompletionCallback> callback)
      : callback_(std::move(callback)) {}
  DiscardRequest(const DiscardRequest&) = delete;
  DiscardRequest& operator=(const DiscardRequest&) = delete;

  void Settle() {
    CEF_REQUIRE_UIT();
    if (auto callback = std::move(callback_)) {
      callback_ = nullptr;
      callback->OnComplete();
    }
  }

 private:
  friend class base::RefCountedThreadSafe<DiscardRequest>;

  ~DiscardRequest() {
    if (!callback_) {
      return;
    }
    if (CEF_CURRENTLY_ON_UIT()) {
      callback_->OnComplete();
    } else {
      CEF_POST_TASK(CEF_UIT,
                    base::BindOnce(&CefCompletionCallback::OnComplete,
                                   std::move(callback_)));
    }
  }

  CefRefPtr<CefCompletionCallback> callback_;
};

bool CanDiscard(content::WebContents* web_contents) {
  return web_contents->GetVisibility() != content::Visibility::VISIBLE;
}

void AttemptDiscard(content::WebContents* web_contents,
                    scoped_refptr<DiscardRequest> request) {
  if (IsFrozen(web_contents)) {
    // The discard needs the renderer to answer: run its queues again first.
    web_contents->SetPageFrozen(false);
  }
  SetFrozenFlag(web_contents, false);
  web_contents->Discard(base::BindOnce(&DiscardRequest::Settle, request));
}

void RetryDiscard(CefRefPtr<CefBrowserHostBase> host,
                  scoped_refptr<DiscardRequest> request) {
  content::WebContents* web_contents = host->GetWebContents();
  if (web_contents && !web_contents->WasDiscarded() &&
      CanDiscard(web_contents)) {
    AttemptDiscard(web_contents, request);
  }
  if (!web_contents || !web_contents->WasDiscarded()) {
    request->Settle();  // Gave up; the embedder sees WasDiscarded() false.
    return;
  }
  CEF_POST_DELAYED_TASK(CEF_UIT,
                        base::BindOnce(&DiscardRequest::Settle, request),
                        kDiscardSettleDeadlineMs);
}

}  // namespace

}  // namespace open_engine

bool CefSetPageFrozen(CefRefPtr<CefBrowser> browser, bool frozen) {
  CEF_REQUIRE_UIT_RETURN(false);
  content::WebContents* web_contents = open_engine::WebContentsFor(browser);
  if (!web_contents) {
    return false;
  }
  if (frozen &&
      web_contents->GetVisibility() == content::Visibility::VISIBLE) {
    // Content's contract: a visible page is never frozen.
    return false;
  }
  if (frozen && web_contents->WasDiscarded()) {
    return false;  // No renderer to freeze.
  }
  web_contents->SetPageFrozen(frozen);
  open_engine::SetFrozenFlag(web_contents, frozen);
  return true;
}

bool CefIsPageFrozen(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN(false);
  content::WebContents* web_contents = open_engine::WebContentsFor(browser);
  return web_contents && open_engine::IsFrozen(web_contents);
}

bool CefDiscardBrowser(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefCompletionCallback> callback) {
  auto request =
      base::MakeRefCounted<open_engine::DiscardRequest>(std::move(callback));
  if (!CEF_CURRENTLY_ON_UIT()) {
    DCHECK(false) << "called on invalid thread";
    return false;  // |request| settles on the UI thread.
  }
  auto host = CefBrowserHostBase::FromBrowser(browser);
  content::WebContents* web_contents = host ? host->GetWebContents() : nullptr;
  if (!web_contents) {
    request->Settle();
    return false;
  }
  if (web_contents->WasDiscarded()) {
    request->Settle();
    return true;
  }
  if (!base::FeatureList::IsEnabled(features::kWebContentsDiscard)) {
    // WebContents::Discard is NOTREACHED() without the feature.
    LOG(WARNING) << "Open: discard refused: WebContentsDiscard is disabled";
    request->Settle();
    return false;
  }
  if (!open_engine::CanDiscard(web_contents)) {
    request->Settle();
    return false;
  }
  open_engine::AttemptDiscard(web_contents, request);
  if (!web_contents->WasDiscarded()) {
    CEF_POST_DELAYED_TASK(
        CEF_UIT,
        base::BindOnce(&open_engine::RetryDiscard, host, request),
        open_engine::kDiscardRetryDelayMs);
  } else {
    CEF_POST_DELAYED_TASK(
        CEF_UIT, base::BindOnce(&open_engine::DiscardRequest::Settle, request),
        open_engine::kDiscardSettleDeadlineMs);
  }
  return true;
}

bool CefWasDiscarded(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN(false);
  content::WebContents* web_contents = open_engine::WebContentsFor(browser);
  return web_contents && web_contents->WasDiscarded();
}

bool CefHasUnloadHandlers(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN(false);
  content::WebContents* web_contents = open_engine::WebContentsFor(browser);
  return web_contents && web_contents->NeedToFireBeforeUnloadOrUnloadEvents();
}
