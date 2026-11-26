// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// No-op Handoff stub for Linux and Windows.

#include "open_unified/browser/platform/open_handoff.h"

namespace open_unified {

struct OpenHandoffController::Impl {
  GURL empty_url;
  std::string empty_title;
};

OpenHandoffController::OpenHandoffController()
    : impl_(std::make_unique<Impl>()) {}

OpenHandoffController::~OpenHandoffController() = default;

void OpenHandoffController::UpdateActiveTab(const GURL& /*url*/,
                                            const std::u16string& /*title*/,
                                            bool /*is_incognito*/) {}

void OpenHandoffController::UpdateActiveTab(const GURL& /*url*/,
                                            std::string_view /*title_utf8*/,
                                            bool /*is_incognito*/) {}

void OpenHandoffController::OnWindowActivated() {}

void OpenHandoffController::OnWindowClosed() {}

void OpenHandoffController::Invalidate() {}

bool OpenHandoffController::IsPublishing() const {
  return false;
}

const GURL& OpenHandoffController::published_url() const {
  return impl_->empty_url;
}

const std::string& OpenHandoffController::published_title() const {
  return impl_->empty_title;
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
