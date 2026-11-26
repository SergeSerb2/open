// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_boosts_ui.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "open_unified/browser/open_boost_controller.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/open_window_controller.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/ui/webui/open_settings_ui.h"
#include "url/gurl.h"

namespace open_unified::webui {

namespace {

// The single site a Boost's host pattern names ("*.example.com" and
// "example.com" -> "example.com"); empty for wildcard patterns that do not
// name one site.
std::string SiteHostOf(const std::string& pattern) {
  std::string host =
      base::ToLowerASCII(base::TrimWhitespaceASCII(pattern, base::TRIM_ALL));
  if (base::StartsWith(host, "*.")) {
    host = host.substr(2);
  }
  if (host.empty() || host.find('*') != std::string::npos ||
      host.find('/') != std::string::npos ||
      host.find(' ') != std::string::npos) {
    return std::string();
  }
  return host;
}

std::optional<ItemID> FindTabIn(const std::vector<SidebarNode>& nodes,
                                const std::string& pattern) {
  for (const SidebarNode& node : nodes) {
    if (const Tab* tab = node.as_tab()) {
      const GURL url(tab->url);
      if (url.SchemeIsHTTPOrHTTPS() &&
          OpenBoostController::HostMatches(std::string(url.host()), pattern)) {
        return tab->id;
      }
    } else if (const Folder* folder = node.as_folder()) {
      if (auto found = FindTabIn(folder->children, pattern)) {
        return found;
      }
    } else if (const Split* split = node.as_split()) {
      for (const Tab& pane : split->panes) {
        const GURL url(pane.url);
        if (url.SchemeIsHTTPOrHTTPS() &&
            OpenBoostController::HostMatches(std::string(url.host()),
                                             pattern)) {
          return pane.id;
        }
      }
    }
  }
  return std::nullopt;
}

// A tab of |profile| on a site |pattern| matches: the focused Space first,
// then the Profile's other Spaces, then its Favorites.
std::optional<ItemID> FindMatchingTab(const BrowserModel& model,
                                      const ProfileID& profile,
                                      const std::optional<SpaceID>& focused,
                                      const std::string& pattern) {
  if (focused) {
    if (const Space* space = model.FindSpace(*focused)) {
      if (auto found = FindTabIn(space->today, pattern))
        return found;
      if (auto found = FindTabIn(space->pinned, pattern))
        return found;
    }
  }
  for (const Space& space : model.spaces()) {
    if (space.profile_id != profile || (focused && space.id == *focused)) {
      continue;
    }
    if (auto found = FindTabIn(space.today, pattern))
      return found;
    if (auto found = FindTabIn(space.pinned, pattern))
      return found;
  }
  if (const Profile* p = model.FindProfile(profile)) {
    for (const Tab& tab : p->favorites) {
      const GURL url(tab.url);
      if (url.SchemeIsHTTPOrHTTPS() &&
          OpenBoostController::HostMatches(std::string(url.host()), pattern)) {
        return tab.id;
      }
    }
  }
  return std::nullopt;
}

}  // namespace

OpenBoostsUI::OpenBoostsUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenBoostsUI::~OpenBoostsUI() = default;

void OpenBoostsUI::RegisterMethods() {
  auto bind =
      [this](void (OpenBoostsUI::*method)(const base::DictValue&, Reply)) {
        return base::BindRepeating(method, weak_factory_.GetWeakPtr());
      };
  Register(kBoostsList, bind(&OpenBoostsUI::List));
  Register(kBoostsSave, bind(&OpenBoostsUI::Save));
  Register(kBoostsDelete, bind(&OpenBoostsUI::Delete));
  Register(kBoostsToggle, bind(&OpenBoostsUI::Toggle));
  Register(kBoostsStartZap, bind(&OpenBoostsUI::StartZap));
  Register(kBoostsRemoveZap, bind(&OpenBoostsUI::RemoveZap));
  Register(boosts_rpc::kEditOnSite, bind(&OpenBoostsUI::EditOnSite));
}

void OpenBoostsUI::List(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  // Read the store itself (not the controller's cache) so the editor always
  // shows what is on disk.
  RunOnStore(ps->boosts,
             base::BindOnce([](BoostStore* store) { return store->List(); }),
             base::BindOnce(
                 [](Reply reply, std::vector<Boost> boosts) {
                   base::ListValue list;
                   for (const Boost& boost : boosts) {
                     list.Append(json::BoostToValue(boost));
                   }
                   OpenPreferences* prefs = OpenPreferences::Get();
                   const base::Value enabled =
                       prefs->GetValue("advanced.enableBoosts");
                   ReplyOk(
                       std::move(reply),
                       base::DictValue()
                           .Set("boosts", std::move(list))
                           .Set("global_enabled",
                                enabled.is_bool() ? enabled.GetBool() : true));
                 },
                 std::move(reply)));
}

// static
void OpenBoostsUI::ReplySaved(ProfileID profile,
                              Reply reply,
                              std::string error,
                              std::optional<Boost> saved) {
  if (OpenBrowserService* service = OpenBrowserService::Get();
      service && service->boost_controller()) {
    service->boost_controller()->ReloadBoosts(profile);
  }
  if (!saved) {
    ReplyError(std::move(reply), error);
    return;
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("boost", json::BoostToValue(*saved)));
}

void OpenBoostsUI::SaveAndReply(Boost boost, Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(boost.profile_id);
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  boost.modified_at = base::Time::Now().InSecondsFSinceUnixEpoch();
  const ProfileID profile = boost.profile_id;
  RunOnStore(
      ps->boosts,
      base::BindOnce(
          [](Boost boost, BoostStore* store) {
            return store->Save(std::move(boost));
          },
          std::move(boost)),
      base::BindOnce(
          [](ProfileID profile, Reply reply, Boost saved) {
            if (OpenBrowserService* service = OpenBrowserService::Get();
                service && service->boost_controller()) {
              service->boost_controller()->ReloadBoosts(profile);
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("boost", json::BoostToValue(saved)));
          },
          profile, std::move(reply)));
}

void OpenBoostsUI::Save(const base::DictValue& payload, Reply reply) {
  std::optional<Boost> boost = json::BoostFromValue(payload.Find("boost"));
  if (!boost) {
    ReplyError(std::move(reply), "invalid boost");
    return;
  }
  // A Boost belongs to an existing Profile; default to this page's.
  if (boost->profile_id.empty() ||
      !service()->model().FindProfile(boost->profile_id)) {
    boost->profile_id = profile_id();
  }
  SaveAndReply(std::move(*boost), std::move(reply));
}

void OpenBoostsUI::Delete(const base::DictValue& payload, Reply reply) {
  const std::string id = json::GetString(payload, "id");
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  if (!ps || id.empty()) {
    ReplyError(std::move(reply), "no such boost");
    return;
  }
  RunOnStore(ps->boosts,
             base::BindOnce([](std::string id,
                               BoostStore* store) { return store->Delete(id); },
                            id),
             base::BindOnce(
                 [](ProfileID profile, Reply reply, bool ok) {
                   if (OpenBrowserService* service = OpenBrowserService::Get();
                       service && service->boost_controller()) {
                     service->boost_controller()->ReloadBoosts(profile);
                   }
                   ReplyOk(std::move(reply), base::DictValue().Set("ok", ok));
                 },
                 profile, std::move(reply)));
}

void OpenBoostsUI::Toggle(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  const std::string id = json::GetString(payload, "id");
  std::optional<bool> enabled = payload.FindBool("enabled");
  if (!ps || id.empty() || !enabled) {
    ReplyError(std::move(reply), "no such boost");
    return;
  }
  // Read-modify-write on the store's own sequence: never a stale copy of
  // the controller's cache (a concurrent edit or Zap would be lost).
  RunOnStore(ps->boosts,
             base::BindOnce(
                 [](std::string id, bool enabled,
                    BoostStore* store) -> std::optional<Boost> {
                   std::optional<Boost> boost = store->GetBoost(id);
                   if (!boost) {
                     return std::nullopt;
                   }
                   boost->enabled = enabled;
                   boost->modified_at =
                       base::Time::Now().InSecondsFSinceUnixEpoch();
                   return store->Save(std::move(*boost));
                 },
                 id, *enabled),
             base::BindOnce(&OpenBoostsUI::ReplySaved, profile,
                            std::move(reply), std::string("no such boost")));
}

void OpenBoostsUI::StartZap(const base::DictValue& payload, Reply reply) {
  std::string message;
  const bool armed = service()->boost_controller()->StartZap(
      json::GetString(payload, "boost_id"), &message);
  ReplyOk(std::move(reply),
          base::DictValue().Set("armed", armed).Set("message", message));
}

void OpenBoostsUI::RemoveZap(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  const std::string boost_id = json::GetString(payload, "boost_id");
  const std::string zap_id = json::GetString(payload, "zap_id");
  if (!ps || boost_id.empty() || zap_id.empty()) {
    ReplyError(std::move(reply), "no such boost");
    return;
  }
  RunOnStore(
      ps->boosts,
      base::BindOnce(
          [](std::string boost_id, std::string zap_id,
             BoostStore* store) -> std::optional<Boost> {
            std::optional<Boost> boost = store->GetBoost(boost_id);
            if (!boost) {
              return std::nullopt;
            }
            const size_t before = boost->zapped_elements.size();
            std::erase_if(
                boost->zapped_elements,
                [&](const ZappedElement& zap) { return zap.id == zap_id; });
            if (boost->zapped_elements.size() == before) {
              return std::nullopt;
            }
            boost->modified_at = base::Time::Now().InSecondsFSinceUnixEpoch();
            return store->Save(std::move(*boost));
          },
          boost_id, zap_id),
      base::BindOnce(&OpenBoostsUI::ReplySaved, profile, std::move(reply),
                     std::string("no such boost or zap")));
}

void OpenBoostsUI::EditOnSite(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  const std::string id = json::GetString(payload, "id");
  if (!ps || id.empty()) {
    ReplyError(std::move(reply), "no such boost");
    return;
  }
  // The stored Boost (never a page-supplied host): the store is the truth.
  RunOnStore(
      ps->boosts,
      base::BindOnce(
          [](std::string id, BoostStore* store) { return store->GetBoost(id); },
          id),
      base::BindOnce(&OpenBoostsUI::OnEditBoostLoaded,
                     weak_factory_.GetWeakPtr(), profile,
                     json::GetBool(payload, "zap", false), std::move(reply)));
}

void OpenBoostsUI::OnEditBoostLoaded(ProfileID profile,
                                     bool zap,
                                     Reply reply,
                                     std::optional<Boost> boost) {
  OpenBrowserService* s = service();
  OpenTabBridge* bridge = s ? s->tab_bridge() : nullptr;
  OpenWindowController* windows = s ? s->window_controller() : nullptr;
  if (!boost) {
    ReplyError(std::move(reply), "no such boost");
    return;
  }
  if (!bridge || !windows) {
    ReplyError(std::move(reply), "no browser window");
    return;
  }
  BrowserModel& model = s->model();
  // The window of this page (its tab), else the main window.
  OpenWindowUi* ui = nullptr;
  if (content::WebUI* page = web_ui()) {
    if (std::optional<ItemID> self =
            OpenTabBridge::TabIdForWebContents(page->GetWebContents())) {
      if (BrowserWindowInterface* browser = bridge->BrowserForTab(*self)) {
        if (std::optional<WindowID> window =
                bridge->WindowIdForBrowser(browser)) {
          ui = windows->WindowUiFor(*window);
        }
      }
    }
  }
  if (!ui) {
    ui = windows->MainWindowUi();
  }
  const std::optional<SpaceID> focused =
      model_util::FocusedSpace(model, ui ? ui->window_id() : WindowID());

  std::optional<ItemID> tab =
      FindMatchingTab(model, profile, focused, boost->host_pattern);
  bool opened = false;
  if (!tab) {
    const std::string host = SiteHostOf(boost->host_pattern);
    if (host.empty() || !focused) {
      ReplyOk(std::move(reply),
              base::DictValue()
                  .Set("ok", false)
                  .Set("message",
                       "This Boost matches more than one site. Open one of "
                       "them, then choose Edit Boost."));
      return;
    }
    const ItemID id = bridge->OpenTabInSpace(
        GURL(base::StrCat({"https://", host, "/"})), *focused,
        /*background=*/false,
        ui ? std::optional<WindowID>(ui->window_id()) : std::nullopt);
    if (id.empty()) {
      ReplyError(std::move(reply), "could not open the site");
      return;
    }
    tab = id;
    opened = true;
  } else {
    bridge->SelectNode(*tab);
  }

  if (ui) {
    ui->ActivateWindow();
    // Shows the floating Boost editor for the window's active tab once
    // OpenWindowUi handles kEditBoost (see boosts_rpc::kEventEditRequested).
    ui->RunCommand("edit-boost");
  }

  // Zap needs a loaded, matching page; a tab that just opened is not there
  // yet, so the editor's own Zap button arms it after the load.
  bool zap_armed = false;
  std::string message;
  if (zap && !opened && s->boost_controller() &&
      bridge->WebContentsForTab(*tab)) {
    zap_armed =
        s->boost_controller()->StartZapForTab(*tab, boost->id, &message);
  }
  if (message.empty()) {
    message = opened ? "Opened the site to edit its Boost."
                     : "Switched to the site to edit its Boost.";
  }

  s->BroadcastEvent(
      boosts_rpc::kEventEditRequested,
      base::Value(base::DictValue()
                      .Set("boost_id", boost->id)
                      .Set("profile_id", boost->profile_id)
                      .Set("tab_id", *tab)
                      .Set("window_id", ui ? ui->window_id() : WindowID())
                      .Set("zap", zap)));
  ReplyOk(std::move(reply), base::DictValue()
                                .Set("ok", true)
                                .Set("tab_id", *tab)
                                .Set("opened_new_tab", opened)
                                .Set("zap_armed", zap_armed)
                                .Set("message", message));
}

}  // namespace open_unified::webui
