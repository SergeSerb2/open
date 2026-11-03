// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Web notification click report and test hooks (page-platform EP-6, EP-7).
// Clicks come from patch 0504 (open_notification_hooks.h); the test list
// observes NotificationDisplayService, filtered by Chromium's own list of
// displayed notifications.

#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/utf_string_conversions.h"
#include "base/supports_user_data.h"
#include "cef/include/cef_open_page.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/notifications/notification_common.h"
#include "chrome/browser/notifications/notification_display_service.h"
#include "chrome/browser/notifications/notification_display_service_factory.h"
#include "chrome/browser/notifications/notification_display_service_impl.h"
#include "chrome/browser/notifications/notification_handler.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/notifications/notification_operation.h"
#include "content/browser/notifications/notification_id_generator.h"
#include "open/browser/page/open_notification_hooks.h"
#include "ui/message_center/public/cpp/notification.h"
#include "url/gurl.h"

namespace open_engine {

namespace {

const char kNotificationStateKey[] = "open_engine.notifications";
const char kAutomationSwitch[] = "open-automation";

bool AutomationEnabled() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch(kAutomationSwitch);
}

// One Profile's notification handler and, with --open-automation, the web
// notifications it showed (id -> type, origin, title, body).
class NotificationState : public base::SupportsUserData::Data,
                          public NotificationDisplayService::Observer {
 public:
  struct Shown {
    NotificationHandler::Type type;
    std::string origin;
    std::string title;
    std::string body;
  };

  explicit NotificationState(Profile* profile) : profile_(profile) {
    if (AutomationEnabled()) {
      if (auto* service =
              NotificationDisplayServiceFactory::GetForProfile(profile)) {
        observation_.Observe(service);
      }
    }
  }

  CefRefPtr<CefOpenNotificationHandler> handler;
  std::map<std::string, Shown> shown;

  // NotificationDisplayService::Observer:
  void OnNotificationDisplayed(
      const message_center::Notification& notification,
      const NotificationCommon::Metadata* const metadata) override {
    // Chromium's web notification ids say the kind (NotificationIdGenerator):
    // persistent (service worker, "p[b]#…") or non-persistent (a page, "n#…").
    // Other notifications (extensions, Chrome's own) are not web notifications.
    const std::string& id = notification.id();
    const bool persistent =
        content::NotificationIdGenerator::IsPersistentNotification(id);
    if (!persistent &&
        !content::NotificationIdGenerator::IsNonPersistentNotification(id)) {
      return;
    }
    shown[id] = Shown{
        persistent ? NotificationHandler::Type::WEB_PERSISTENT
                   : NotificationHandler::Type::WEB_NON_PERSISTENT,
        notification.origin_url().spec(), base::UTF16ToUTF8(notification.title()),
        base::UTF16ToUTF8(notification.message())};
  }
  void OnNotificationClosed(const std::string& notification_id) override {
    shown.erase(notification_id);
  }
  void OnNotificationDisplayServiceDestroyed(
      NotificationDisplayService* service) override {
    observation_.Reset();
  }

 private:
  raw_ptr<Profile> profile_;
  base::ScopedObservation<NotificationDisplayService,
                          NotificationDisplayService::Observer>
      observation_{this};
};

NotificationState* StateFor(Profile* profile, bool create) {
  if (!profile) {
    return nullptr;
  }
  auto* state = static_cast<NotificationState*>(
      profile->GetUserData(kNotificationStateKey));
  if (!state && create) {
    auto owned = std::make_unique<NotificationState>(profile);
    state = owned.get();
    profile->SetUserData(kNotificationStateKey, std::move(owned));
  }
  return state;
}

void OnClicked(Profile* profile,
               int handler_type,
               const GURL& origin,
               const std::string& notification_id) {
  using Type = NotificationHandler::Type;
  const Type type = static_cast<Type>(handler_type);
  if (type != Type::WEB_PERSISTENT && type != Type::WEB_NON_PERSISTENT) {
    return;
  }
  NotificationState* state = StateFor(profile, false);
  if (!state || !state->handler) {
    return;
  }
  // Section 8 decision: no page is reported. Chromium keeps the creating
  // document of a non-persistent notification inside content's dispatcher;
  // the embedder finds the tab by origin (page-platform §4.5.4).
  state->handler->OnNotificationClick(notification_id, origin.spec(), nullptr,
                                      type == Type::WEB_PERSISTENT);
}

Profile* ProfileFor(CefRefPtr<CefRequestContext> request_context) {
  if (!request_context) {
    return nullptr;
  }
  auto* impl = static_cast<CefRequestContextImpl*>(request_context.get());
  return impl->VerifyBrowserContext()
             ? CefRequestContextImpl::GetProfile(request_context)
             : nullptr;
}

}  // namespace

}  // namespace open_engine

bool CefSetOpenNotificationHandler(
    CefRefPtr<CefRequestContext> request_context,
    CefRefPtr<CefOpenNotificationHandler> handler) {
  CEF_REQUIRE_UIT_RETURN(false);
  Profile* profile = open_engine::ProfileFor(request_context);
  if (!profile) {
    return false;
  }
  open_engine::GetNotificationHooks().clicked = &open_engine::OnClicked;
  open_engine::StateFor(profile, true)->handler = handler;
  return true;
}

bool CefGetDisplayedNotifications(
    CefRefPtr<CefRequestContext> request_context,
    CefRefPtr<CefNotificationListCallback> callback) {
  CEF_REQUIRE_UIT_RETURN(false);
  if (!callback) {
    return false;
  }
  CefRefPtr<CefListValue> items = CefListValue::Create();
  Profile* profile = open_engine::ProfileFor(request_context);
  auto* state = open_engine::AutomationEnabled()
                    ? open_engine::StateFor(profile, true)
                    : nullptr;
  // What Chromium showed for this profile, from its display service (shown, then closed by the
  // user or a click). Not NotificationDisplayService::GetDisplayed: on macOS that is
  // Notification Center's list, which is empty while macOS has not authorized the app, and a
  // test hook must not depend on that (manual check U-N1 covers delivery). A notification
  // closed by its page (Notification.close()) reaches no observer and stays listed until the
  // page shows another with its tag.
  if (state) {
    for (const auto& [id, shown] : state->shown) {
      CefRefPtr<CefDictionaryValue> item = CefDictionaryValue::Create();
      item->SetString("id", id);
      item->SetString("origin", shown.origin);
      item->SetString("title", shown.title);
      item->SetString("body", shown.body);
      items->SetDictionary(items->GetSize(), item);
    }
  }
  callback->OnNotifications(items);
  return true;
}

bool CefSimulateNotificationClick(CefRefPtr<CefRequestContext> request_context,
                                  const CefString& id) {
  CEF_REQUIRE_UIT_RETURN(false);
  if (!open_engine::AutomationEnabled()) {
    return false;
  }
  Profile* profile = open_engine::ProfileFor(request_context);
  auto* state = open_engine::StateFor(profile, false);
  if (!state) {
    return false;
  }
  auto it = state->shown.find(id.ToString());
  if (it == state->shown.end()) {
    return false;
  }
  // The same entry point macOS's response reaches (ProfileLoadedCallback).
  NotificationDisplayServiceImpl::GetForProfile(profile)
      ->ProcessNotificationOperation(
          NotificationOperation::kClick, it->second.type,
          GURL(it->second.origin), it->first, std::nullopt, std::nullopt,
          std::nullopt, std::nullopt, base::DoNothing());
  return true;
}
