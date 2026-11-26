// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_boosts_ui.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/time/time.h"
#include "open_unified/browser/open_boost_controller.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/ui/webui/open_settings_ui.h"

namespace open_unified::webui {

OpenBoostsUI::OpenBoostsUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenBoostsUI::~OpenBoostsUI() = default;

void OpenBoostsUI::RegisterMethods() {
  auto bind = [this](void (OpenBoostsUI::*method)(const base::DictValue&,
                                                  Reply)) {
    return base::BindRepeating(method, weak_factory_.GetWeakPtr());
  };
  Register(kBoostsList, bind(&OpenBoostsUI::List));
  Register(kBoostsSave, bind(&OpenBoostsUI::Save));
  Register(kBoostsDelete, bind(&OpenBoostsUI::Delete));
  Register(kBoostsToggle, bind(&OpenBoostsUI::Toggle));
  Register(kBoostsStartZap, bind(&OpenBoostsUI::StartZap));
  Register(kBoostsRemoveZap, bind(&OpenBoostsUI::RemoveZap));
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
  RunOnStore(
      ps->boosts,
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
            ReplyOk(std::move(reply),
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
            ReplyOk(std::move(reply), base::DictValue().Set(
                                          "boost", json::BoostToValue(saved)));
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
  RunOnStore(
      ps->boosts,
      base::BindOnce(
          [](std::string id, BoostStore* store) { return store->Delete(id); },
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
  RunOnStore(
      ps->boosts,
      base::BindOnce(
          [](std::string id, bool enabled,
             BoostStore* store) -> std::optional<Boost> {
            std::optional<Boost> boost = store->GetBoost(id);
            if (!boost) {
              return std::nullopt;
            }
            boost->enabled = enabled;
            boost->modified_at = base::Time::Now().InSecondsFSinceUnixEpoch();
            return store->Save(std::move(*boost));
          },
          id, *enabled),
      base::BindOnce(&OpenBoostsUI::ReplySaved, profile, std::move(reply),
                     std::string("no such boost")));
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
            std::erase_if(boost->zapped_elements,
                          [&](const ZappedElement& zap) {
                            return zap.id == zap_id;
                          });
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

}  // namespace open_unified::webui
