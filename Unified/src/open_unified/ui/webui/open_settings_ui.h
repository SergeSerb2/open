// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_SETTINGS_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_SETTINGS_UI_H_

#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/values.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace open_unified::webui {

// App-wide preferences of open://settings that are not Profile settings
// (general.*, appearance.*, links.*, advanced.*, ...). Defaults mirror
// DEFAULT_PREFERENCES in Unified/webui/src/shared/bridge.ts. Stored in
// <user data>/State/Preferences.json; loaded once, off the UI thread.
// Keys that map to ProfileSettings (tabs.archiveAfter, tabs.sleepMode,
// search.*, downloads.*) are read from and written to the BrowserModel.
class OpenPreferences {
 public:
  static OpenPreferences* Get();

  // Runs |done| once the file is loaded (at once when it already is).
  void WhenLoaded(base::OnceClosure done);
  bool loaded() const { return loaded_; }

  // Merged values for |profile_id| (defaults < file < Profile settings).
  base::DictValue Values(const ProfileID& profile_id) const;
  static const base::DictValue& Defaults();
  // Validates |key| and the type of |value| against the defaults.
  bool Set(const std::string& key,
           const base::Value& value,
           const ProfileID& profile_id,
           bool all_profiles,
           std::string* error);
  void Reset(const std::string& key, const ProfileID& profile_id);
  // A stored app preference (or its default).
  base::Value GetValue(const std::string& key) const;

 private:
  friend class base::NoDestructor<OpenPreferences>;
  OpenPreferences();
  ~OpenPreferences();
  void Save();

  bool loading_ = false;
  bool loaded_ = false;
  base::DictValue stored_;
  std::vector<base::OnceClosure> waiters_;
  base::WeakPtrFactory<OpenPreferences> weak_factory_{this};
};

// settings.* and sync.* methods (open_ipc_contract.h).
class OpenSettingsUI : public OpenRpcDomain {
 public:
  explicit OpenSettingsUI(OpenWebUIMessageHandler* handler);
  ~OpenSettingsUI() override;

  void RegisterMethods() override;

  // Shared with open://onboarding.
  static base::DictValue ProfileSummary(const ProfileID& profile_id);
  static base::DictValue AdBlockState(const ProfileID& profile_id);

 private:
  // settings.*
  void GetAll(const base::DictValue& payload, Reply reply);
  void SetPreference(const base::DictValue& payload, Reply reply);
  void ResetPreference(const base::DictValue& payload, Reply reply);
  void ListProfiles(const base::DictValue& payload, Reply reply);
  void CreateProfile(const base::DictValue& payload, Reply reply);
  void RenameProfile(const base::DictValue& payload, Reply reply);
  void DeleteProfile(const base::DictValue& payload, Reply reply);
  void GetShortcuts(const base::DictValue& payload, Reply reply);
  void SetShortcut(const base::DictValue& payload, Reply reply);
  void ResetShortcut(const base::DictValue& payload, Reply reply);
  void GetRoutingRules(const base::DictValue& payload, Reply reply);
  void SaveRoutingRule(const base::DictValue& payload, Reply reply);
  void DeleteRoutingRule(const base::DictValue& payload, Reply reply);
  void TestRoutingUrl(const base::DictValue& payload, Reply reply);
  void GetAdBlockState(const base::DictValue& payload, Reply reply);
  void SetAdBlockEnabled(const base::DictValue& payload, Reply reply);
  void ToggleAdBlockList(const base::DictValue& payload, Reply reply);
  void AddAdBlockExclusion(const base::DictValue& payload, Reply reply);
  void RemoveAdBlockExclusion(const base::DictValue& payload, Reply reply);
  void ClearBrowsingData(const base::DictValue& payload, Reply reply);
  void SetDefaultBrowser(const base::DictValue& payload, Reply reply);
  void GetExtensions(const base::DictValue& payload, Reply reply);
  void ToggleExtension(const base::DictValue& payload, Reply reply);

  // sync.*
  void SyncGetStatus(const base::DictValue& payload, Reply reply);
  void SyncConfigureServer(const base::DictValue& payload, Reply reply);
  void SyncRegister(const base::DictValue& payload, Reply reply);
  void SyncLogin(const base::DictValue& payload, Reply reply);
  void SyncLogout(const base::DictValue& payload, Reply reply);
  void SyncTriggerNow(const base::DictValue& payload, Reply reply);
  void SyncRecover(const base::DictValue& payload, Reply reply);
  void SyncListDevices(const base::DictValue& payload, Reply reply);
  void SyncRevokeDevice(const base::DictValue& payload, Reply reply);

  void ChangeExclusion(const base::DictValue& payload,
                       bool excluded,
                       Reply reply);
  base::DictValue ShortcutsValue() const;
  base::DictValue RoutingValue() const;

  base::WeakPtrFactory<OpenSettingsUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_SETTINGS_UI_H_
