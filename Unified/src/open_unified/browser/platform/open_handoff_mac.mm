// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// macOS NSUserActivity Handoff adapter (compiled with ARC).

#include "open_unified/browser/platform/open_handoff.h"

#import <Foundation/Foundation.h>

#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"

namespace open_unified {

struct OpenHandoffController::Impl {
  NSUserActivity* __strong activity = nil;
  GURL published_url;
  std::string published_title;

  ~Impl() { Invalidate(); }

  void Invalidate() {
    @autoreleasepool {
      if (activity) {
        [activity invalidate];
        activity = nil;
      }
      published_url = GURL();
      published_title.clear();
    }
  }
};

OpenHandoffController::OpenHandoffController()
    : impl_(std::make_unique<Impl>()) {}

OpenHandoffController::~OpenHandoffController() {
  Invalidate();
}

void OpenHandoffController::UpdateActiveTab(const GURL& url,
                                            const std::u16string& title,
                                            bool is_incognito) {
  UpdateActiveTab(url, base::UTF16ToUTF8(title), is_incognito);
}

void OpenHandoffController::UpdateActiveTab(const GURL& url,
                                            std::string_view title_utf8,
                                            bool is_incognito) {
  if (!IsEligibleUrl(url, is_incognito)) {
    Invalidate();
    return;
  }

  if (impl_->activity && impl_->published_url == url &&
      impl_->published_title == title_utf8) {
    return;
  }

  @autoreleasepool {
    NSString* url_string = base::SysUTF8ToNSString(url.spec());
    NSURL* ns_url = url_string ? [NSURL URLWithString:url_string] : nil;
    if (!ns_url) {
      Invalidate();
      return;
    }

    const bool created = (impl_->activity == nil);
    NSUserActivity* next =
        impl_->activity
            ? impl_->activity
            : [[NSUserActivity alloc]
                  initWithActivityType:NSUserActivityTypeBrowsingWeb];
    next.eligibleForHandoff = YES;
    next.eligibleForSearch = NO;
    next.eligibleForPublicIndexing = NO;
    next.webpageURL = ns_url;
    next.title =
        title_utf8.empty() ? nil : base::SysUTF8ToNSString(title_utf8);

    impl_->published_url = url;
    impl_->published_title.assign(title_utf8.begin(), title_utf8.end());

    if (created) {
      impl_->activity = next;
      [next becomeCurrent];
    } else {
      next.needsSave = YES;
      [next becomeCurrent];
    }
  }
}

void OpenHandoffController::OnWindowActivated() {
  @autoreleasepool {
    if (impl_->activity) {
      [impl_->activity becomeCurrent];
    }
  }
}

void OpenHandoffController::OnWindowClosed() {
  Invalidate();
}

void OpenHandoffController::Invalidate() {
  if (impl_) {
    impl_->Invalidate();
  }
}

bool OpenHandoffController::IsPublishing() const {
  return impl_ && impl_->activity != nil && impl_->published_url.is_valid();
}

const GURL& OpenHandoffController::published_url() const {
  return impl_->published_url;
}

const std::string& OpenHandoffController::published_title() const {
  return impl_->published_title;
}

// static
bool OpenHandoffController::IsEligibleUrl(const GURL& url, bool is_incognito) {
  return !is_incognito && url.is_valid() && url.SchemeIsHTTPOrHTTPS();
}

// static
bool OpenHandoffController::CanContinueActivityType(
    std::string_view activity_type) {
  return activity_type == "NSUserActivityTypeBrowsingWeb";
}

}  // namespace open_unified
