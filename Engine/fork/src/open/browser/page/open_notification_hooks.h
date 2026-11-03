// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_PAGE_OPEN_NOTIFICATION_HOOKS_H_
#define OPEN_BROWSER_PAGE_OPEN_NOTIFICATION_HOOKS_H_

#include <string>

class GURL;
class Profile;

namespace open_engine {

// Web notification click hook (page-platform EP-6, patch 0504).
// NotificationDisplayServiceImpl::ProcessNotificationOperation calls it for
// every click (body or button), before Chromium dispatches the click to the
// page; open_notifications.cc fills it when an embedder sets a notification
// handler. Header-only for the same reason as open_history_swipe_hooks.h.
// UI thread. |handler_type| is NotificationHandler::Type.
struct NotificationHooks {
  void (*clicked)(Profile* profile,
                  int handler_type,
                  const GURL& origin,
                  const std::string& notification_id) = nullptr;
};

inline NotificationHooks& GetNotificationHooks() {
  static NotificationHooks hooks;
  return hooks;
}

}  // namespace open_engine

#endif  // OPEN_BROWSER_PAGE_OPEN_NOTIFICATION_HOOKS_H_
