// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_SETTINGS_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_SETTINGS_UI_H_

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/values.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace open_unified {
class OpenMediaBridge;
}  // namespace open_unified

namespace open_unified::webui {

// App-wide preferences of open://settings that are not Profile settings
// (general.*, appearance.*, links.*, advanced.*, privacy.*). Defaults mirror
// DEFAULT_PREFERENCES in Unified/webui/src/shared/bridge.ts. Stored in
// <user data>/State/Preferences.json; loaded once, off the UI thread.
// Keys that map to ProfileSettings (tabs.archiveAfter, tabs.sleepMode,
// search.*, downloads.*) are read from and written to the BrowserModel.
//
// A successful Set() or Reset() also applies the value to the running
// browser at once (Chromium DownloadPrefs, privacy prefs, the app icon, the
// global Little Open hotkey, Auto Picture-in-Picture; see ApplyEffects()).
class OpenPreferences {
 public:
  static OpenPreferences* Get();

  // Runs |done| once the file is loaded (at once when it already is).
  void WhenLoaded(base::OnceClosure done);
  bool loaded() const { return loaded_; }

  // Merged values for |profile_id| (defaults < file < Profile settings).
  base::DictValue Values(const ProfileID& profile_id) const;
  static const base::DictValue& Defaults();
  // Translates a legacy Swift Open preference key ("open.*") to its
  // open://settings key, or returns |key| unchanged.
  static std::string TranslateLegacyKey(std::string_view key);
  // Validates |key| and the type of |value| against the defaults.
  bool Set(const std::string& key,
           const base::Value& value,
           const ProfileID& profile_id,
           bool all_profiles,
           std::string* error);
  void Reset(const std::string& key, const ProfileID& profile_id);
  // A stored app preference (or its default).
  base::Value GetValue(const std::string& key) const;
  // The app preferences that differ from their defaults (snapshot export).
  const base::DictValue& stored() const { return stored_; }

  // Pushes |key| (for |profile_ids|) into the running browser. Safe to call
  // for keys without a runtime effect.
  static void ApplyEffects(const std::string& key,
                           const std::vector<ProfileID>& profile_ids);
  // Pushes every preference with a runtime effect (startup, profile switch).
  static void ApplyAllEffects();
  // Pushes app-level Chromium preference effects (website appearance, font
  // size, default zoom, Do Not Track, HTTPS-Only, extension developer mode)
  // plus search-suggest state onto a single newly attached Profile.
  static void ApplyEffectsForProfile(const ProfileID& profile_id);

 private:
  friend class base::NoDestructor<OpenPreferences>;
  OpenPreferences();
  ~OpenPreferences();
  void Save();

  bool loading_ = false;
  bool loaded_ = false;
  bool applying_service_prefs_ = false;
  base::DictValue stored_;
  std::set<std::string> dirty_keys_;
  std::vector<base::OnceClosure> waiters_;
  base::WeakPtrFactory<OpenPreferences> weak_factory_{this};
};

// settings.* and sync.* methods (open_ipc_contract.h plus the
// settings.<area>.<verb> methods of the Settings redesign, listed in
// open_settings_ui.cc kSettings* constants).
class OpenSettingsUI : public OpenRpcDomain {
 public:
  explicit OpenSettingsUI(OpenWebUIMessageHandler* handler);
  ~OpenSettingsUI() override;

  void RegisterMethods() override;

  // Shared with open://onboarding.
  static base::DictValue ProfileSummary(const ProfileID& profile_id);
  static base::DictValue AdBlockState(const ProfileID& profile_id);

  // The app-wide OpenMediaBridge (Auto Picture-in-Picture). The owner calls
  // SetMediaBridge(bridge) once it exists and SetMediaBridge(nullptr) before
  // destroying it; the current advanced.pictureInPicture preference is
  // applied at once.
  static void SetMediaBridge(OpenMediaBridge* bridge);
  static OpenMediaBridge* media_bridge();

  // Open Unified's own version ("0.2.0"; the macOS bundle's
  // CFBundleShortVersionString when present), distinct from Chromium's.
  static std::string OpenVersion();

 private:
  class FileDialog;
  struct ImportRecord;

  // --- settings.* (open_ipc_contract.h) ------------------------------------
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
  void GetDefaultBrowser(const base::DictValue& payload, Reply reply);
  void SetDefaultBrowser(const base::DictValue& payload, Reply reply);
  void GetExtensions(const base::DictValue& payload, Reply reply);
  void ToggleExtension(const base::DictValue& payload, Reply reply);

  // --- Window, theme, navigation, files -------------------------------------
  void GetTheme(const base::DictValue& payload, Reply reply);
  void OpenChromeUrl(const base::DictValue& payload, Reply reply);
  void PickFolder(const base::DictValue& payload, Reply reply);
  void PickDownloadFolder(const base::DictValue& payload, Reply reply);
  void ExportSnapshot(const base::DictValue& payload, Reply reply);

  // --- settings.profiles.* ---------------------------------------------------
  void ProfilesList(const base::DictValue& payload, Reply reply);
  void ProfilesSwitch(const base::DictValue& payload, Reply reply);
  void ProfilesCreate(const base::DictValue& payload, Reply reply);
  void ProfilesRename(const base::DictValue& payload, Reply reply);
  void ProfilesSetIcon(const base::DictValue& payload, Reply reply);
  void ProfilesSetSearchEngine(const base::DictValue& payload, Reply reply);
  void ProfilesSetCustomSearchEngines(const base::DictValue& payload,
                                      Reply reply);
  void ProfilesDelete(const base::DictValue& payload, Reply reply);
  void ProfilesCleanupUnused(const base::DictValue& payload, Reply reply);

  // --- settings.spaces.* -----------------------------------------------------
  void SpacesList(const base::DictValue& payload, Reply reply);
  void SpacesCreate(const base::DictValue& payload, Reply reply);
  void SpacesRename(const base::DictValue& payload, Reply reply);
  void SpacesSetProfile(const base::DictValue& payload, Reply reply);

  // --- settings.atc.* --------------------------------------------------------
  void AtcGet(const base::DictValue& payload, Reply reply);
  void AtcSetDefaultDestination(const base::DictValue& payload, Reply reply);
  void AtcAddRule(const base::DictValue& payload, Reply reply);
  void AtcUpdateRule(const base::DictValue& payload, Reply reply);
  void AtcDeleteRule(const base::DictValue& payload, Reply reply);
  void AtcReorderRules(const base::DictValue& payload, Reply reply);
  void AtcListRunningApps(const base::DictValue& payload, Reply reply);
  void AtcTestUrl(const base::DictValue& payload, Reply reply);
  void AtcRecentDecisions(const base::DictValue& payload, Reply reply);

  // --- settings.shortcuts.* --------------------------------------------------
  void ShortcutsList(const base::DictValue& payload, Reply reply);
  void ShortcutsSet(const base::DictValue& payload, Reply reply);
  void ShortcutsClear(const base::DictValue& payload, Reply reply);
  void ShortcutsReset(const base::DictValue& payload, Reply reply);
  void ShortcutsResetAll(const base::DictValue& payload, Reply reply);
  void ShortcutsSetPriority(const base::DictValue& payload, Reply reply);
  void ShortcutsExportJson(const base::DictValue& payload, Reply reply);
  void ShortcutsImportJson(const base::DictValue& payload, Reply reply);

  // --- settings.adblock.* ----------------------------------------------------
  void AdBlockGet(const base::DictValue& payload, Reply reply);
  void AdBlockUpdateNow(const base::DictValue& payload, Reply reply);
  void AdBlockResetLists(const base::DictValue& payload, Reply reply);
  void AdBlockSetCustomRules(const base::DictValue& payload, Reply reply);
  void AdBlockCopyDebugInfo(const base::DictValue& payload, Reply reply);
  void AdBlockDetectConflicts(const base::DictValue& payload, Reply reply);

  // --- settings.extensions.* -------------------------------------------------
  void ExtensionsRemove(const base::DictValue& payload, Reply reply);
  void ExtensionsOpenOptions(const base::DictValue& payload, Reply reply);

  // --- settings.sync.* and sync.* -------------------------------------------
  void SyncDetailed(const base::DictValue& payload, Reply reply);
  void SyncSignIn(const base::DictValue& payload, Reply reply);
  void SyncSignUp(const base::DictValue& payload, Reply reply);
  void SyncSignOut(const base::DictValue& payload, Reply reply);
  void SyncCompleteInitial(const base::DictValue& payload, Reply reply);
  void SyncNowDetailed(const base::DictValue& payload, Reply reply);
  void SyncChangePassword(const base::DictValue& payload, Reply reply);
  void SyncUpdateDisplayName(const base::DictValue& payload, Reply reply);
  void SyncDeleteAccount(const base::DictValue& payload, Reply reply);
  void SyncRevokeDeviceDetailed(const base::DictValue& payload, Reply reply);
  void SyncSetServerUrl(const base::DictValue& payload, Reply reply);
  void SyncSetCategory(const base::DictValue& payload, Reply reply);
  void SyncRecoverDetailed(const base::DictValue& payload, Reply reply);

  void SyncGetStatus(const base::DictValue& payload, Reply reply);
  void SyncConfigureServer(const base::DictValue& payload, Reply reply);
  void SyncRegister(const base::DictValue& payload, Reply reply);
  void SyncLogin(const base::DictValue& payload, Reply reply);
  void SyncLogout(const base::DictValue& payload, Reply reply);
  void SyncTriggerNow(const base::DictValue& payload, Reply reply);
  void SyncRecover(const base::DictValue& payload, Reply reply);
  void SyncListDevices(const base::DictValue& payload, Reply reply);
  void SyncRevokeDevice(const base::DictValue& payload, Reply reply);

  // --- settings.import.* -----------------------------------------------------
  void ImportDetect(const base::DictValue& payload, Reply reply);
  void ImportPickHtml(const base::DictValue& payload, Reply reply);
  void ImportRun(const base::DictValue& payload, Reply reply);
  void ImportUndo(const base::DictValue& payload, Reply reply);
  void ImportReceipts(const base::DictValue& payload, Reply reply);

  // --- settings.about.* ------------------------------------------------------
  void AboutGet(const base::DictValue& payload, Reply reply);
  void AboutShowDataFolder(const base::DictValue& payload, Reply reply);
  void AboutCopySystemInfo(const base::DictValue& payload, Reply reply);
  void AboutCheckForUpdates(const base::DictValue& payload, Reply reply);
  void AboutReplayOnboarding(const base::DictValue& payload, Reply reply);

  // --- Helpers ---------------------------------------------------------------
  void ChangeExclusion(const base::DictValue& payload,
                       bool excluded,
                       Reply reply);
  base::DictValue ShortcutsValue() const;
  base::DictValue ShortcutsDetailedValue() const;
  base::DictValue RoutingValue() const;
  base::DictValue AtcValue() const;
  base::DictValue ThemeValue() const;
  // The window that shows this page, else the main window.
  WindowID HostWindowId() const;
  // Opens |url| in a tab of the main browser window and activates it. When
  // |profile_id| is given and valid, opens in a Space belonging to that
  // Profile so the page loads in its Chromium Profile.
  bool OpenInBrowser(const GURL& url,
                     const std::optional<ProfileID>& profile_id = std::nullopt);
  // Shows a native file dialog anchored to this page's window. One dialog at
  // a time; |done| gets std::nullopt on cancel or when one is already open.
  void RunFileDialog(int type,
                     const std::u16string& title,
                     const base::FilePath& default_path,
                     const std::vector<std::string>& extensions,
                     base::OnceCallback<void(std::optional<base::FilePath>)>
                         done);
  void OnFileDialogDone(
      base::OnceCallback<void(std::optional<base::FilePath>)> done,
      std::optional<base::FilePath> path);
  void SetShortcutAndReply(const std::string& id,
                           const std::string& keys,
                           Reply reply);
  void AfterShortcutChange(const std::string& id);
  static std::unique_ptr<ImportRecord> ReadImportBlocking(
      std::string source_id,
      std::vector<std::string> kinds,
      base::FilePath html_path);
  void FinishImport(std::string source_id,
                    ProfileID profile,
                    Reply reply,
                    std::unique_ptr<ImportRecord> record);

  std::unique_ptr<FileDialog> file_dialog_;
  // The bookmarks file the user picked in settings.import.pickHtml; the
  // page never sends a path of its own.
  base::FilePath picked_html_path_;
  base::WeakPtrFactory<OpenSettingsUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_SETTINGS_UI_H_
