// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_BOOSTS_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_BOOSTS_UI_H_

#include <optional>
#include <string>

#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace open_unified::webui {

// RPC names this domain adds beyond open_ipc_contract.h (mirrors
// Unified/webui/src/boosts/rpc.ts).
//
// boosts.editOnSite {id, profile_id?, zap?}: selects (or opens) a tab on the
// Boost's site and asks that window for the floating Boost editor
// ("edit-boost" command); with zap, also arms Zap on that page when it is
// loaded. Reply {ok, tab_id, opened_new_tab, zap_armed, message}.
namespace boosts_rpc {
inline constexpr char kEditOnSite[] = "boosts.editOnSite";
// Push event to OpenBrowserService observers and open:// pages:
// {boost_id, profile_id, tab_id, window_id, zap}. OpenWindowController shows
// OpenBoostEditorSession for that tab when it handles it.
inline constexpr char kEventEditRequested[] = "open.boostEditRequested";
}  // namespace boosts_rpc

// boosts.* methods of open://boosts (Boost gallery, manager, Zap).
class OpenBoostsUI : public OpenRpcDomain {
 public:
  explicit OpenBoostsUI(OpenWebUIMessageHandler* handler);
  ~OpenBoostsUI() override;

  void RegisterMethods() override;

 private:
  void List(const base::DictValue& payload, Reply reply);
  void Save(const base::DictValue& payload, Reply reply);
  void Delete(const base::DictValue& payload, Reply reply);
  void Toggle(const base::DictValue& payload, Reply reply);
  void StartZap(const base::DictValue& payload, Reply reply);
  void RemoveZap(const base::DictValue& payload, Reply reply);
  void EditOnSite(const base::DictValue& payload, Reply reply);
  void OnEditBoostLoaded(ProfileID profile,
                         bool zap,
                         Reply reply,
                         std::optional<Boost> boost);

  // Saves |boost| (store runner), refreshes the controller's cache and
  // replies {boost}.
  void SaveAndReply(Boost boost, Reply reply);
  // Reply of a read-modify-write store task (Toggle, RemoveZap): reloads
  // the controller's cache, then replies {boost} or |error|.
  static void ReplySaved(ProfileID profile,
                         Reply reply,
                         std::string error,
                         std::optional<Boost> saved);

  base::WeakPtrFactory<OpenBoostsUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_BOOSTS_UI_H_
