// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// OpenHandoffController: publishes the focused window's active webpage for
// macOS Handoff (NSUserActivityTypeBrowsingWeb).
//
// Port of App/Handoff/HandoffPublisher.swift:
// - Publishes only non-Incognito http:// and https:// pages.
// - Immediately invalidates any active NSUserActivity when switching to an
//   Incognito window, internal URL (open://, chrome://, about:, file://),
//   empty tab, or when closing the window.
// - On Linux and Windows, compiles as a clean no-op stub with the same API.

#ifndef OPEN_UNIFIED_BROWSER_PLATFORM_OPEN_HANDOFF_H_
#define OPEN_UNIFIED_BROWSER_PLATFORM_OPEN_HANDOFF_H_

#include <memory>
#include <string>
#include <string_view>

#include "url/gurl.h"

namespace open_unified {

class OpenHandoffController {
 public:
  OpenHandoffController();
  ~OpenHandoffController();

  OpenHandoffController(const OpenHandoffController&) = delete;
  OpenHandoffController& operator=(const OpenHandoffController&) = delete;

  // Updates the published Handoff activity for the currently focused tab.
  // Immediately invalidates any existing activity when |is_incognito| is true
  // or |url| is not a valid http:// or https:// URL.
  void UpdateActiveTab(const GURL& url,
                       const std::u16string& title,
                       bool is_incognito);
  void UpdateActiveTab(const GURL& url,
                       std::string_view title_utf8,
                       bool is_incognito);

  // Re-asserts the current activity when this window becomes active/key.
  void OnWindowActivated();

  // Immediately invalidates any published activity when the window closes.
  void OnWindowClosed();

  // Immediately invalidates and clears the active Handoff activity.
  void Invalidate();

  // True while a web-browsing activity is currently published to the OS.
  bool IsPublishing() const;

  // The currently published URL and UTF-8 title (empty when not publishing).
  const GURL& published_url() const;
  const std::string& published_title() const;

  // True iff |url| may be advertised over Handoff (non-Incognito http/https).
  static bool IsEligibleUrl(const GURL& url, bool is_incognito);

  // True iff |activity_type| is the web browsing Handoff activity type
  // ("NSUserActivityTypeBrowsingWeb").
  static bool CanContinueActivityType(std::string_view activity_type);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_PLATFORM_OPEN_HANDOFF_H_
