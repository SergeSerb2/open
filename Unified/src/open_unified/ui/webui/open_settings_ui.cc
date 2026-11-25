// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_settings_ui.h"

#include <algorithm>
#include <utility>

#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/version_info/version_info.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/web_contents.h"
#include "open/adblock/open_adblock_service.h"
#include "open_unified/browser/open_extension_bridge.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/routing/routing_evaluator.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "open_unified/core/sync/sync_engine.h"

namespace open_unified::webui {

namespace {

constexpr char kPreferencesFile[] = "Preferences.json";

// Preference keys stored in the Profile's settings (browser.json) instead of
// Preferences.json, with their ProfileSettings field (open_json.h names).
struct ProfileKey {
  const char* preference;
  const char* field;
};
constexpr ProfileKey kProfileKeys[] = {
    {"tabs.archiveAfter", "auto_archive_after"},
    {"tabs.littleOpenArchiveAfter", "little_open_auto_archive_after"},
    {"tabs.sleepMode", "sleep_mode"},
    {"search.engine", "search_engine_id"},
    {"search.suggestions", "search_suggest_enabled"},
    {"downloads.location", "download_directory"},
    {"downloads.askEachTime", "ask_where_to_save_each_file"},
};

const ProfileKey* FindProfileKey(std::string_view key) {
  for (const ProfileKey& entry : kProfileKeys) {
    if (key == entry.preference) {
      return &entry;
    }
  }
  return nullptr;
}

base::FilePath PreferencesPath() {
  OpenBrowserService* service = OpenBrowserService::Get();
  return service ? service->user_data_dir()
                       .AppendASCII("State")
                       .AppendASCII(kPreferencesFile)
                 : base::FilePath();
}

std::string_view SyncPlatformLabel(std::string_view platform) {
  const std::string lower = base::ToLowerASCII(platform);
  if (lower == "macos" || lower == "mac") return "macOS";
  if (lower == "windows" || lower == "win") return "Windows";
  return "Linux";
}

// SyncStatusInfo.state is camelCase ("signedOut", "awaitingInitialChoice",
// "needsReauth"); bridge.ts SyncStatus.state is one of four snake_case
// values.
std::string BridgeSyncState(const SyncStatusInfo& info) {
  const std::string& state = info.state;
  if (state == "syncing") return "syncing";
  if (state == "error" || state == "needsReauth") return "error";
  if (state == "signedOut" || !info.signed_in) return "signed_out";
  return "idle";
}

base::DictValue SyncStatusToValue(
    const SyncStatusInfo& info,
    const std::vector<SyncDeviceInfo>& devices) {
  base::DictValue categories;
  for (const auto& [name, enabled] : info.categories) {
    categories.Set(name, enabled);
  }
  base::ListValue device_list;
  for (const SyncDeviceInfo& device : devices) {
    device_list.Append(
        base::DictValue()
            .Set("id", device.device_id)
            .Set("name", device.device_name)
            .Set("platform", SyncPlatformLabel(device.platform))
            .Set("is_current", device.is_current)
            .Set("last_seen_at",
                 device.last_seen_at_ms
                     ? static_cast<double>(*device.last_seen_at_ms) / 1000.0
                     : 0.0));
  }
  const std::string state = BridgeSyncState(info);
  base::DictValue d;
  d.Set("signed_in", info.signed_in);
  if (!info.email.empty()) {
    d.Set("email", info.email);
  }
  d.Set("server_url", info.server_url);
  d.Set("state", state);
  if (info.last_sync_at) {
    d.Set("last_sync_at", *info.last_sync_at);
  }
  d.Set("revision", static_cast<double>(info.revision));
  d.Set("categories", std::move(categories));
  if (info.error_message) {
    d.Set("error_message", *info.error_message);
  }
  d.Set("devices", std::move(device_list));
  return d;
}

base::ListValue DevicesToValue(const std::vector<SyncDeviceInfo>& devices) {
  return SyncStatusToValue(SyncStatusInfo(), devices)
      .Extract("devices")
      .value_or(base::Value(base::ListValue()))
      .TakeList();
}

SyncEngine* SyncFor(const ProfileID& profile_id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  ProfileServices* ps = service ? service->ProfileServicesFor(profile_id)
                                : nullptr;
  return ps ? ps->sync.get() : nullptr;
}

std::string NormalizeHost(std::string host) {
  host = base::ToLowerASCII(base::TrimWhitespaceASCII(host, base::TRIM_ALL));
  if (base::StartsWith(host, "www.")) {
    host = host.substr(4);
  }
  while (!host.empty() && host.back() == '.') {
    host.pop_back();
  }
  return host;
}

bool IsPlausibleHost(const std::string& host) {
  return !host.empty() && host.size() <= 253 &&
         std::all_of(host.begin(), host.end(), [](char c) {
           return base::IsAsciiAlphaNumeric(c) || c == '.' || c == '-' ||
                  c == ':' || c == '[' || c == ']';
         });
}

// "Mod+Shift+T" <-> KeyboardShortcut (bridge.ts ShortcutBinding.keys).
// "Mod" is the platform's primary modifier (Command on macOS, Control
// elsewhere), so one string works on every platform.
std::optional<KeyboardShortcut> ParseShortcut(const std::string& text) {
  std::vector<std::string> parts = base::SplitString(
      text, "+", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  if (parts.empty() || parts.size() > 5) {
    return std::nullopt;
  }
  KeyboardShortcut shortcut;
  shortcut.key = base::ToLowerASCII(parts.back());
  parts.pop_back();
  for (const std::string& raw : parts) {
    const std::string m = base::ToLowerASCII(raw);
    if (m == "mod") {
      shortcut.modifiers |= kModPrimary;
    } else if (m == "ctrl" || m == "control") {
      shortcut.modifiers |= kModCtrl;
    } else if (m == "alt" || m == "option") {
      shortcut.modifiers |= kModAlt;
    } else if (m == "shift") {
      shortcut.modifiers |= kModShift;
    } else if (m == "cmd" || m == "meta" || m == "super") {
      shortcut.modifiers |= kModMeta;
    } else {
      return std::nullopt;
    }
  }
  if (shortcut.key.empty() || shortcut.key.size() > 16) {
    return std::nullopt;
  }
  return shortcut.Normalized();
}

std::string FormatShortcut(const KeyboardShortcut& shortcut) {
  std::vector<std::string> parts;
  uint32_t modifiers = shortcut.modifiers;
  if (modifiers & kModPrimary) {
    parts.push_back("Mod");
    modifiers &= ~static_cast<uint32_t>(kModPrimary);
  }
  if (modifiers & kModCtrl) parts.push_back("Ctrl");
  if (modifiers & kModAlt) parts.push_back("Alt");
  if (modifiers & kModShift) parts.push_back("Shift");
  if (modifiers & kModMeta) parts.push_back("Meta");
  std::string key = shortcut.key;
  if (key.size() == 1) {
    key = base::ToUpperASCII(key);
  } else if (!key.empty()) {
    key[0] = base::ToUpperASCII(key[0]);
  }
  parts.push_back(key);
  return base::JoinString(parts, "+");
}

// bridge.ts categories from the command's menu path.
std::string ShortcutCategory(const CommandDefinition& command) {
  const std::string menu =
      command.menu_path.empty() ? std::string() : command.menu_path.front();
  if (menu == "Tabs" || menu == "Tab") return "Tabs";
  if (menu == "Spaces") return "Spaces";
  if (menu == "View") return "View";
  if (menu == "Window") return "Window";
  if (menu == "History" || menu == "Go" || menu == "Navigation" ||
      menu == "Archive") {
    return "Navigation";
  }
  return "Tools";
}

std::string RoutingExplanation(const RoutingDecision& decision) {
  switch (decision.via) {
    case RoutingVia::kRule:
      return "Matched a rule.";
    case RoutingVia::kDefaultDestination:
      return "No rule matched; the default destination applies.";
    case RoutingVia::kFallbackMissingSpace:
      return "The rule's Space no longer exists; the default applies.";
    case RoutingVia::kFallbackMissingProfile:
      return "The rule's Profile no longer exists; the default applies.";
    case RoutingVia::kDefaultSuppressedByToggle:
      return "External links open in the most recent Space (Little Open is "
             "off for links from other apps).";
    case RoutingVia::kRejectedNonHttp:
      return "Only http and https links are routed.";
    case RoutingVia::kNoSpaces:
      return "There is no Space to open the link in.";
  }
  return std::string();
}

// Removes browsing data of one Chromium Profile, then deletes itself.
class DataRemovalObserver : public content::BrowsingDataRemover::Observer {
 public:
  static void Start(content::BrowsingDataRemover* remover,
                    base::Time begin,
                    uint64_t mask,
                    base::OnceClosure done) {
    auto* observer = new DataRemovalObserver(remover, std::move(done));
    remover->RemoveAndReply(
        begin, base::Time::Max(), mask,
        content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB, observer);
  }

  void OnBrowsingDataRemoverDone(uint64_t failed_data_types) override {
    remover_->RemoveObserver(this);
    std::move(done_).Run();
    delete this;
  }

 private:
  DataRemovalObserver(content::BrowsingDataRemover* remover,
                      base::OnceClosure done)
      : remover_(remover), done_(std::move(done)) {
    remover_->AddObserver(this);
  }

  raw_ptr<content::BrowsingDataRemover> remover_;
  base::OnceClosure done_;
};

}  // namespace

// ===========================================================================
// OpenPreferences
// ===========================================================================

// static
OpenPreferences* OpenPreferences::Get() {
  static base::NoDestructor<OpenPreferences> instance;
  return instance.get();
}

OpenPreferences::OpenPreferences() = default;
OpenPreferences::~OpenPreferences() = default;

// static
const base::DictValue& OpenPreferences::Defaults() {
  static const base::NoDestructor<base::DictValue> defaults(
      base::DictValue()
          .Set("general.automaticUpdates", true)
          .Set("general.warnBeforeQuitting", true)
          .Set("general.restoreWindows", true)
          .Set("general.userName", "")
          .Set("appearance.appIcon", "open-indigo")
          .Set("appearance.websiteAppearance", "automatic")
          .Set("appearance.toolbar", true)
          .Set("appearance.fullUrl", false)
          .Set("tabs.archiveAfter", "12h")
          .Set("tabs.littleOpenArchiveAfter", "6h")
          .Set("tabs.sleepMode", "balanced")
          .Set("tabs.includeFavoritesInSwitcher", true)
          .Set("tabs.ninthTabGoesToLast", true)
          .Set("search.engine", "google")
          .Set("search.suggestions", true)
          .Set("downloads.location", "~/Downloads")
          .Set("downloads.askEachTime", false)
          .Set("previews.enabled", true)
          .Set("previews.folders", true)
          .Set("previews.pages", true)
          .Set("links.littleOpenHotkey", "Mod+Option+N")
          .Set("links.optionCommandClick", true)
          .Set("links.externalLinksLittleOpen", true)
          .Set("links.peekShiftClick", true)
          .Set("links.peekOtherSites", true)
          .Set("shortcuts.priority", "open")
          .Set("advanced.soundEffects", true)
          .Set("advanced.haptics", true)
          .Set("advanced.windowDragging", true)
          .Set("advanced.sharedQuotes", true)
          .Set("advanced.pictureInPicture", true)
          .Set("advanced.themeData", true)
          .Set("advanced.enableBoosts", true)
          .Set("advanced.translateOffer", true));
  return *defaults;
}

void OpenPreferences::WhenLoaded(base::OnceClosure done) {
  if (loaded_) {
    std::move(done).Run();
    return;
  }
  waiters_.push_back(std::move(done));
  if (loading_) {
    return;
  }
  loading_ = true;
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
      base::BindOnce(
          [](base::FilePath path) -> std::optional<base::DictValue> {
            std::string contents;
            if (path.empty() ||
                !base::ReadFileToStringWithMaxSize(path, &contents,
                                                   1024 * 1024)) {
              return std::nullopt;
            }
            return base::JSONReader::ReadDict(contents, base::JSON_PARSE_RFC);
          },
          PreferencesPath()),
      base::BindOnce(
          [](base::WeakPtr<OpenPreferences> self,
             std::optional<base::DictValue> stored) {
            if (!self) {
              return;
            }
            if (stored) {
              // Keep only known keys with the default's type.
              for (auto [key, value] : *stored) {
                const base::Value* def = Defaults().Find(key);
                if (def && def->type() == value.type() &&
                    !FindProfileKey(key)) {
                  self->stored_.Set(key, value.Clone());
                }
              }
            }
            self->loaded_ = true;
            self->loading_ = false;
            auto waiters = std::move(self->waiters_);
            for (auto& waiter : waiters) {
              std::move(waiter).Run();
            }
          },
          weak_factory_.GetWeakPtr()));
}

base::Value OpenPreferences::GetValue(const std::string& key) const {
  if (const base::Value* v = stored_.Find(key)) {
    return v->Clone();
  }
  const base::Value* def = Defaults().Find(key);
  return def ? def->Clone() : base::Value();
}

base::DictValue OpenPreferences::Values(const ProfileID& profile_id) const {
  base::DictValue values = Defaults().Clone();
  values.Merge(stored_.Clone());
  OpenBrowserService* service = OpenBrowserService::Get();
  const Profile* profile =
      service ? service->model().FindProfile(profile_id) : nullptr;
  if (profile) {
    base::DictValue settings =
        json::ProfileSettingsToValue(profile->settings);
    for (const ProfileKey& entry : kProfileKeys) {
      if (base::Value* v = settings.Find(entry.field)) {
        values.Set(entry.preference, v->Clone());
      }
    }
  }
  return values;
}

bool OpenPreferences::Set(const std::string& key,
                          const base::Value& value,
                          const ProfileID& profile_id,
                          bool all_profiles,
                          std::string* error) {
  const base::Value* def = Defaults().Find(key);
  if (!def) {
    *error = "unknown preference " + key;
    return false;
  }
  if (def->type() != value.type() &&
      !(def->is_double() && value.is_int())) {
    *error = "wrong type for " + key;
    return false;
  }
  if (const ProfileKey* entry = FindProfileKey(key)) {
    OpenBrowserService* service = OpenBrowserService::Get();
    if (!service) {
      *error = "shutting down";
      return false;
    }
    std::vector<ProfileID> targets;
    if (all_profiles) {
      for (const Profile& profile : service->model().profiles()) {
        targets.push_back(profile.id);
      }
    } else {
      targets.push_back(profile_id);
    }
    base::DictValue patch;
    patch.Set(entry->field, value.Clone());
    for (const ProfileID& id : targets) {
      const Profile* profile = service->model().FindProfile(id);
      if (!profile) {
        continue;
      }
      ProfileSettings settings = profile->settings;
      if (!json::ApplyProfileSettings(patch, &settings)) {
        *error = "invalid value for " + key;
        return false;
      }
      service->model().UpdateProfileSettings(id, settings);
    }
    return true;
  }
  stored_.Set(key, value.Clone());
  Save();
  return true;
}

void OpenPreferences::Reset(const std::string& key,
                            const ProfileID& profile_id) {
  const base::Value* def = Defaults().Find(key);
  if (!def) {
    return;
  }
  if (FindProfileKey(key)) {
    std::string error;
    Set(key, *def, profile_id, /*all_profiles=*/false, &error);
    return;
  }
  stored_.Remove(key);
  Save();
}

void OpenPreferences::Save() {
  std::optional<std::string> json = base::WriteJsonWithOptions(
      stored_, base::JSONWriter::OPTIONS_PRETTY_PRINT);
  const base::FilePath path = PreferencesPath();
  if (!json || path.empty()) {
    return;
  }
  base::ThreadPool::PostTask(
      FROM_HERE,
      {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN},
      base::BindOnce(
          [](base::FilePath path, std::string json) {
            base::CreateDirectory(path.DirName());
            // Atomic replace: write a sibling, then rename over.
            const base::FilePath temp = path.AddExtensionASCII("tmp");
            if (base::WriteFile(temp, json)) {
              base::ReplaceFile(temp, path, nullptr);
            }
          },
          path, std::move(*json)));
}

// ===========================================================================
// OpenSettingsUI
// ===========================================================================

OpenSettingsUI::OpenSettingsUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenSettingsUI::~OpenSettingsUI() = default;

void OpenSettingsUI::RegisterMethods() {
  auto bind = [this](void (OpenSettingsUI::*method)(const base::DictValue&,
                                                    Reply)) {
    return base::BindRepeating(method, weak_factory_.GetWeakPtr());
  };
  Register(kSettingsGetAll, bind(&OpenSettingsUI::GetAll));
  Register(kSettingsSetPreference, bind(&OpenSettingsUI::SetPreference));
  Register(kSettingsResetPreference, bind(&OpenSettingsUI::ResetPreference));
  Register(kSettingsListProfiles, bind(&OpenSettingsUI::ListProfiles));
  Register(kSettingsCreateProfile, bind(&OpenSettingsUI::CreateProfile));
  Register(kSettingsRenameProfile, bind(&OpenSettingsUI::RenameProfile));
  Register(kSettingsDeleteProfile, bind(&OpenSettingsUI::DeleteProfile));
  Register(kSettingsGetShortcuts, bind(&OpenSettingsUI::GetShortcuts));
  Register(kSettingsSetShortcut, bind(&OpenSettingsUI::SetShortcut));
  Register(kSettingsResetShortcut, bind(&OpenSettingsUI::ResetShortcut));
  Register(kSettingsGetRoutingRules, bind(&OpenSettingsUI::GetRoutingRules));
  Register(kSettingsSaveRoutingRule, bind(&OpenSettingsUI::SaveRoutingRule));
  Register(kSettingsDeleteRoutingRule,
           bind(&OpenSettingsUI::DeleteRoutingRule));
  Register(kSettingsTestRoutingUrl, bind(&OpenSettingsUI::TestRoutingUrl));
  Register(kSettingsGetAdBlockState, bind(&OpenSettingsUI::GetAdBlockState));
  Register(kSettingsSetAdBlockEnabled,
           bind(&OpenSettingsUI::SetAdBlockEnabled));
  Register(kSettingsToggleAdBlockList,
           bind(&OpenSettingsUI::ToggleAdBlockList));
  Register(kSettingsAddAdBlockExclusion,
           bind(&OpenSettingsUI::AddAdBlockExclusion));
  Register(kSettingsRemoveAdBlockExclusion,
           bind(&OpenSettingsUI::RemoveAdBlockExclusion));
  Register(kSettingsClearBrowsingData,
           bind(&OpenSettingsUI::ClearBrowsingData));
  Register(kSettingsSetDefaultBrowser,
           bind(&OpenSettingsUI::SetDefaultBrowser));
  Register(kSettingsGetExtensions, bind(&OpenSettingsUI::GetExtensions));
  Register(kSettingsToggleExtension, bind(&OpenSettingsUI::ToggleExtension));

  Register(kSyncGetStatus, bind(&OpenSettingsUI::SyncGetStatus));
  Register(kSyncConfigureServer, bind(&OpenSettingsUI::SyncConfigureServer));
  Register(kSyncRegister, bind(&OpenSettingsUI::SyncRegister));
  Register(kSyncLogin, bind(&OpenSettingsUI::SyncLogin));
  Register(kSyncLogout, bind(&OpenSettingsUI::SyncLogout));
  Register(kSyncTriggerNow, bind(&OpenSettingsUI::SyncTriggerNow));
  Register(kSyncRecover, bind(&OpenSettingsUI::SyncRecover));
  Register(kSyncListDevices, bind(&OpenSettingsUI::SyncListDevices));
  Register(kSyncRevokeDevice, bind(&OpenSettingsUI::SyncRevokeDevice));
}

// --- Preferences -------------------------------------------------------------

void OpenSettingsUI::GetAll(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  OpenPreferences::Get()->WhenLoaded(base::BindOnce(
      [](ProfileID profile, Reply reply) {
        OpenPreferences* prefs = OpenPreferences::Get();
        OpenPlatform* platform = OpenPlatform::Get();
        ReplyOk(std::move(reply),
                base::DictValue()
                    .Set("preferences", prefs->Values(profile))
                    .Set("defaults", OpenPreferences::Defaults().Clone())
                    .Set("is_default_browser",
                         platform && platform->IsDefaultBrowser())
                    .Set("app_version", version_info::GetVersionNumber())
                    .Set("chromium_version", version_info::GetVersionNumber())
                    .Set("active_profile_id", profile));
      },
      profile, std::move(reply)));
}

void OpenSettingsUI::SetPreference(const base::DictValue& payload,
                                   Reply reply) {
  const std::string key = json::GetString(payload, "key");
  const base::Value* value = payload.Find("value");
  if (key.empty() || !value) {
    ReplyError(std::move(reply), "key and value are required");
    return;
  }
  const ProfileID profile = ProfileFromPayload(payload);
  const bool all = json::GetBool(payload, "apply_all_profiles", false);
  OpenPreferences::Get()->WhenLoaded(base::BindOnce(
      [](std::string key, base::Value value, ProfileID profile, bool all,
         Reply reply) {
        std::string error;
        OpenPreferences* prefs = OpenPreferences::Get();
        if (!prefs->Set(key, value, profile, all, &error)) {
          ReplyError(std::move(reply), error);
          return;
        }
        ReplyOk(std::move(reply),
                base::DictValue()
                    .Set("ok", true)
                    .Set("preferences", prefs->Values(profile)));
      },
      key, value->Clone(), profile, all, std::move(reply)));
}

void OpenSettingsUI::ResetPreference(const base::DictValue& payload,
                                     Reply reply) {
  const std::string key = json::GetString(payload, "key");
  const ProfileID profile = ProfileFromPayload(payload);
  OpenPreferences::Get()->WhenLoaded(base::BindOnce(
      [](std::string key, ProfileID profile, Reply reply) {
        OpenPreferences* prefs = OpenPreferences::Get();
        prefs->Reset(key, profile);
        ReplyOk(std::move(reply),
                base::DictValue()
                    .Set("ok", true)
                    .Set("preferences", prefs->Values(profile)));
      },
      key, profile, std::move(reply)));
}

// --- Profiles ----------------------------------------------------------------

// static
base::DictValue OpenSettingsUI::ProfileSummary(const ProfileID& profile_id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  const BrowserModel& model = service->model();
  const Profile* profile = model.FindProfile(profile_id);
  if (!profile) {
    return base::DictValue();
  }
  const int space_count = static_cast<int>(std::count_if(
      model.spaces().begin(), model.spaces().end(),
      [&](const Space& space) { return space.profile_id == profile_id; }));
  const SpaceIcon icon =
      profile->icon.value_or(SpaceIcon{SpaceIconKind::kEmoji, "🙂"});
  return base::DictValue()
      .Set("id", profile->id)
      .Set("name", profile->name)
      .Set("icon", json::SpaceIconToValue(icon))
      .Set("data_directory_name", profile->data_directory_name)
      .Set("is_default", !model.profiles().empty() &&
                             model.profiles().front().id == profile->id)
      .Set("space_count", space_count)
      .Set("favorites_count", static_cast<int>(profile->favorites.size()))
      .Set("settings", json::ProfileSettingsToValue(profile->settings));
}

void OpenSettingsUI::ListProfiles(const base::DictValue& payload,
                                  Reply reply) {
  base::ListValue profiles;
  for (const Profile& profile : service()->model().profiles()) {
    profiles.Append(ProfileSummary(profile.id));
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("profiles", std::move(profiles)));
}

void OpenSettingsUI::CreateProfile(const base::DictValue& payload,
                                   Reply reply) {
  const std::string name = std::string(base::TrimWhitespaceASCII(
      json::GetString(payload, "name"), base::TRIM_ALL));
  if (name.empty() || name.size() > 64) {
    ReplyError(std::move(reply), "a profile name of 1-64 characters is needed");
    return;
  }
  std::optional<SpaceIcon> icon =
      json::SpaceIconFromValue(payload.Find("icon"));
  if (service()->model().ValidateProfileName(name) !=
      ProfileNameIssue::kNone) {
    ReplyError(std::move(reply), "that profile name is not available");
    return;
  }
  service()->CreateProfile(
      name, icon,
      base::BindOnce(
          [](Reply reply, ProfileID id) {
            if (id.empty() || !OpenBrowserService::Get()) {
              ReplyError(std::move(reply), "the profile could not be created");
              return;
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("profile", ProfileSummary(id)));
          },
          std::move(reply)));
}

void OpenSettingsUI::RenameProfile(const base::DictValue& payload,
                                   Reply reply) {
  const std::string id = json::GetString(payload, "profile_id");
  const std::string name = std::string(base::TrimWhitespaceASCII(
      json::GetString(payload, "name"), base::TRIM_ALL));
  if (name.empty() || name.size() > 64 ||
      service()->model().ValidateProfileName(name, id) !=
          ProfileNameIssue::kNone ||
      !service()->model().RenameProfile(id, name)) {
    ReplyError(std::move(reply), "cannot rename profile");
    return;
  }
  if (std::optional<SpaceIcon> icon =
          json::SpaceIconFromValue(payload.Find("icon"))) {
    // Undoable model change; its tree change schedules the snapshot save.
    service()->model().SetProfileIcon(id, std::move(icon));
  }
  ReplyOk(std::move(reply), base::DictValue().Set("profile",
                                                    ProfileSummary(id)));
}

void OpenSettingsUI::DeleteProfile(const base::DictValue& payload,
                                   Reply reply) {
  const std::string id = json::GetString(payload, "profile_id");
  const Profile* profile = service()->model().FindProfile(id);
  if (!profile) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  // Typed confirmation (the page asks for the Profile's name).
  if (json::GetString(payload, "confirm_name") != profile->name) {
    ReplyError(std::move(reply), "the confirmation does not match the name");
    return;
  }
  switch (service()->model().GetProfileDeleteBlock(id)) {
    case ProfileDeleteBlock::kIsDefault:
      ReplyError(std::move(reply), "the default profile cannot be deleted");
      return;
    case ProfileDeleteBlock::kSpacesAssigned:
      ReplyError(std::move(reply),
                 "move or delete this profile's spaces first");
      return;
    case ProfileDeleteBlock::kNone:
      break;
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("ok", service()->model().DeleteProfile(id)));
}

// --- Shortcuts ---------------------------------------------------------------

base::DictValue OpenSettingsUI::ShortcutsValue() const {
  CommandRegistry& registry = service()->commands();
  // Duplicate bindings: command id -> the other command using its keys.
  std::map<std::string, std::string> conflicts;
  for (const ShortcutConflict& conflict : registry.DetectConflicts()) {
    if (conflict.command_ids.size() < 2 || conflict.is_known_arc_duplicate) {
      continue;
    }
    conflicts[conflict.command_ids[0]] = conflict.command_ids[1];
    conflicts[conflict.command_ids[1]] = conflict.command_ids[0];
  }
  base::ListValue shortcuts;
  for (const CommandDefinition& command : registry.all_commands()) {
    if (!command.is_customizable) {
      continue;
    }
    base::DictValue d;
    d.Set("id", command.id);
    d.Set("title", command.title);
    d.Set("category", ShortcutCategory(command));
    const std::vector<KeyboardShortcut> keys =
        registry.EffectiveShortcuts(command.command_id);
    d.Set("keys", keys.empty() ? std::string() : FormatShortcut(keys.front()));
    d.Set("default_keys", command.default_shortcuts.empty()
                              ? std::string()
                              : FormatShortcut(command.default_shortcuts[0]));
    if (auto it = conflicts.find(command.id); it != conflicts.end()) {
      d.Set("conflict_with", it->second);
    }
    shortcuts.Append(std::move(d));
  }
  OpenPreferences* prefs = OpenPreferences::Get();
  const base::Value priority = prefs->GetValue("shortcuts.priority");
  return base::DictValue()
      .Set("shortcuts", std::move(shortcuts))
      .Set("priority", priority.is_string() ? priority.GetString() : "open");
}

void OpenSettingsUI::GetShortcuts(const base::DictValue& payload,
                                  Reply reply) {
  ReplyOk(std::move(reply), ShortcutsValue());
}

void OpenSettingsUI::SetShortcut(const base::DictValue& payload,
                                 Reply reply) {
  const std::string id = json::GetString(payload, "id");
  const std::string keys = json::GetString(payload, "keys");
  if (id.empty() || keys.size() > 64) {
    ReplyError(std::move(reply), "bad shortcut");
    return;
  }
  std::optional<KeyboardShortcut> shortcut = ParseShortcut(keys);
  CommandRegistry& registry = service()->commands();
  if (!shortcut || !registry.FindByStringId(id)) {
    ReplyError(std::move(reply), "unknown command or shortcut");
    return;
  }
  KeyBindingOverride binding;
  binding.shortcuts.push_back(*shortcut);
  if (!registry.SetOverride(id, std::move(binding))) {
    ReplyError(std::move(reply), "that shortcut is reserved");
    return;
  }
  service()->PersistShortcuts();
  base::DictValue result = ShortcutsValue();
  result.Remove("priority");
  for (const ShortcutConflict& conflict : registry.DetectConflicts()) {
    if (!conflict.is_known_arc_duplicate &&
        std::find(conflict.command_ids.begin(), conflict.command_ids.end(),
                  id) != conflict.command_ids.end()) {
      for (const std::string& other : conflict.command_ids) {
        if (other != id) {
          result.Set("conflict", other);
        }
      }
    }
  }
  ReplyOk(std::move(reply), std::move(result));
}

void OpenSettingsUI::ResetShortcut(const base::DictValue& payload,
                                   Reply reply) {
  if (json::GetBool(payload, "reset_all", false)) {
    service()->commands().ResetAllOverrides();
  } else {
    service()->commands().ResetOverride(json::GetString(payload, "id"));
  }
  service()->PersistShortcuts();
  base::DictValue result = ShortcutsValue();
  result.Remove("priority");
  ReplyOk(std::move(reply), std::move(result));
}

// --- Routing (Air Traffic Control) -------------------------------------------

base::DictValue OpenSettingsUI::RoutingValue() const {
  base::ListValue rules;
  for (const RoutingRule& rule : service()->model().routing_rules()) {
    rules.Append(json::RoutingRuleToValue(rule));
  }
  return base::DictValue()
      .Set("rules", std::move(rules))
      .Set("default_destination",
           json::RoutingDestinationToValue(
               service()->model().default_destination()));
}

void OpenSettingsUI::GetRoutingRules(const base::DictValue& payload,
                                     Reply reply) {
  ReplyOk(std::move(reply), RoutingValue());
}

void OpenSettingsUI::SaveRoutingRule(const base::DictValue& payload,
                                     Reply reply) {
  std::optional<RoutingRule> rule =
      json::RoutingRuleFromValue(payload.Find("rule"));
  if (!rule) {
    ReplyError(std::move(reply), "invalid routing rule");
    return;
  }
  if (rule->id.empty()) {
    rule->id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  }
  if (rule->destination.space_id &&
      !service()->model().FindSpace(*rule->destination.space_id)) {
    ReplyError(std::move(reply), "the destination space does not exist");
    return;
  }
  std::vector<RoutingRule> rules = service()->model().routing_rules();
  auto it = std::find_if(rules.begin(), rules.end(), [&](const RoutingRule& r) {
    return r.id == rule->id;
  });
  if (it != rules.end()) {
    *it = *rule;
  } else {
    rules.push_back(*rule);
  }
  service()->model().SetRoutingRules(std::move(rules));
  if (std::optional<RoutingDestination> dest =
          json::RoutingDestinationFromValue(
              payload.Find("default_destination"))) {
    service()->model().SetDefaultDestination(*dest);
  }
  ReplyOk(std::move(reply), RoutingValue());
}

void OpenSettingsUI::DeleteRoutingRule(const base::DictValue& payload,
                                       Reply reply) {
  const std::string id = json::GetString(payload, "id");
  std::vector<RoutingRule> rules = service()->model().routing_rules();
  std::erase_if(rules, [&](const RoutingRule& r) { return r.id == id; });
  service()->model().SetRoutingRules(std::move(rules));
  base::DictValue result = RoutingValue();
  result.Remove("default_destination");
  ReplyOk(std::move(reply), std::move(result));
}

void OpenSettingsUI::TestRoutingUrl(const base::DictValue& payload,
                                    Reply reply) {
  const std::string url = json::GetString(payload, "url");
  if (!GURL(url).is_valid()) {
    ReplyError(std::move(reply), "invalid URL");
    return;
  }
  RoutingRequest request;
  request.url = url;
  request.source_app_id = json::FindString(payload, "source_app_id");
  request.received_at = base::Time::Now().InSecondsFSinceUnixEpoch();
  const base::Value little_open =
      OpenPreferences::Get()->GetValue("links.externalLinksLittleOpen");
  const RoutingDecision decision = service()->routing().Evaluate(
      request, service()->model(),
      little_open.is_bool() ? little_open.GetBool() : true);
  base::DictValue d;
  if (decision.matched_rule_id) {
    d.Set("matched_rule_id", *decision.matched_rule_id);
    for (const RoutingRule& rule : service()->model().routing_rules()) {
      if (rule.id == *decision.matched_rule_id) {
        d.Set("matched_rule_name", rule.name);
      }
    }
  }
  RoutingDestination destination;
  if (decision.resolved) {
    destination.kind = decision.resolved->kind;
    destination.space_id = decision.resolved->space_id;
    destination.profile_id = decision.resolved->profile_id;
  }
  d.Set("destination", json::RoutingDestinationToValue(destination));
  d.Set("explanation", RoutingExplanation(decision));
  ReplyOk(std::move(reply), std::move(d));
}

// --- Ad blocking -------------------------------------------------------------

// static
base::DictValue OpenSettingsUI::AdBlockState(const ProfileID& profile_id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  ProfileServices* ps = service->ProfileServicesFor(profile_id);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  open_engine::OpenAdBlockService* engine =
      adblock ? adblock->service() : nullptr;
  base::DictValue d;
  d.Set("profile_id", profile_id);
  if (!adblock || !engine) {
    d.Set("global_enabled", false);
    d.Set("generation", 0);
    d.Set("lists", base::ListValue());
    d.Set("exclusions", base::ListValue());
    d.Set("blocked_count_session", 0);
    d.Set("last_error", "Ad blocking is not available for this profile.");
    return d;
  }
  const AdBlockProfileSnapshot snapshot = adblock->GetSnapshot();
  const open_engine::AdBlockStatus& status = snapshot.engine_status;
  // The full catalog (Track 3's 46 lists) with this Profile's switches.
  base::ListValue lists;
  for (const AdBlockListInfo& info : OpenAdBlockProfileService::GetCatalog()) {
    base::DictValue item;
    item.Set("id", info.id);
    item.Set("display_name", info.display_name);
    item.Set("info_url", info.info_url);
    item.Set("category", info.category);
    item.Set("bundled", info.bundled);
    item.Set("default_enabled", info.default_enabled);
    if (info.unavailable_reason) {
      item.Set("unavailable_reason", *info.unavailable_reason);
    }
    item.Set("enabled", std::find(snapshot.enabled_list_ids.begin(),
                                  snapshot.enabled_list_ids.end(),
                                  info.id) != snapshot.enabled_list_ids.end());
    lists.Append(std::move(item));
  }
  base::ListValue exclusions;
  for (const std::string& domain : snapshot.excluded_domains) {
    exclusions.Append(domain);
  }
  int blocked = 0;
  for (const auto& [tab_id, contents] : service->tab_bridge()->LoadedTabs()) {
    if (model_util::ProfileOfNode(service->model(), tab_id) == profile_id) {
      blocked += OpenAdBlockProfileService::GetTotalStoppedCount(contents);
    }
  }
  d.Set("global_enabled", snapshot.enabled);
  d.Set("generation", static_cast<double>(status.generation));
  d.Set("lists", std::move(lists));
  d.Set("exclusions", std::move(exclusions));
  d.Set("blocked_count_session", blocked);
  if (!status.last_error.empty()) {
    d.Set("last_error", status.last_error);
  }
  return d;
}

void OpenSettingsUI::GetAdBlockState(const base::DictValue& payload,
                                     Reply reply) {
  ReplyOk(std::move(reply), AdBlockState(ProfileFromPayload(payload)));
}

void OpenSettingsUI::SetAdBlockEnabled(const base::DictValue& payload,
                                       Reply reply) {
  std::optional<bool> enabled = payload.FindBool("enabled");
  if (!enabled) {
    ReplyError(std::move(reply), "enabled is required");
    return;
  }
  // The master switch applies to every Profile (Arc: one global toggle).
  for (const Profile& profile : service()->model().profiles()) {
    ProfileServices* ps = service()->ProfileServicesFor(profile.id);
    if (OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr) {
      adblock->SetEnabled(*enabled);
    }
  }
  base::DictValue state = AdBlockState(profile_id());
  Emit(kEventAdBlockUpdated, base::Value(state.Clone()));
  ReplyOk(std::move(reply), std::move(state));
}

void OpenSettingsUI::ToggleAdBlockList(const base::DictValue& payload,
                                       Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  const std::string list_id = json::GetString(payload, "list_id");
  std::optional<bool> enabled = payload.FindBool("enabled");
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  if (!adblock || list_id.empty() || list_id.size() > 64 || !enabled) {
    ReplyError(std::move(reply), "cannot change that list");
    return;
  }
  adblock->SetListEnabled(list_id, *enabled);
  base::DictValue state = AdBlockState(profile);
  Emit(kEventAdBlockUpdated, base::Value(state.Clone()));
  ReplyOk(std::move(reply), std::move(state));
}

void OpenSettingsUI::ChangeExclusion(const base::DictValue& payload,
                                     bool excluded,
                                     Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  const std::string host = NormalizeHost(json::GetString(payload, "host"));
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  if (!adblock || !IsPlausibleHost(host)) {
    ReplyError(std::move(reply), "invalid site");
    return;
  }
  if (excluded) {
    adblock->AddExcludedDomain(host);
  } else {
    adblock->RemoveExcludedDomain(host);
  }
  base::DictValue state = AdBlockState(profile);
  Emit(kEventAdBlockUpdated, base::Value(state.Clone()));
  ReplyOk(std::move(reply), std::move(state));
}

void OpenSettingsUI::AddAdBlockExclusion(const base::DictValue& payload,
                                         Reply reply) {
  ChangeExclusion(payload, /*excluded=*/true, std::move(reply));
}

void OpenSettingsUI::RemoveAdBlockExclusion(const base::DictValue& payload,
                                            Reply reply) {
  ChangeExclusion(payload, /*excluded=*/false, std::move(reply));
}

// --- Privacy -----------------------------------------------------------------

void OpenSettingsUI::ClearBrowsingData(const base::DictValue& payload,
                                       Reply reply) {
  const ProfileID profile_id = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile_id);
  if (!ps || !ps->chrome_profile) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  const std::string range = json::GetString(payload, "range", "hour");
  base::TimeDelta age;
  if (range == "hour") {
    age = base::Hours(1);
  } else if (range == "day") {
    age = base::Days(1);
  } else if (range == "week") {
    age = base::Days(7);
  } else if (range == "month") {
    age = base::Days(30);
  } else if (range != "all") {
    ReplyError(std::move(reply), "unknown range");
    return;
  }
  const base::Time begin =
      range == "all" ? base::Time() : base::Time::Now() - age;

  uint64_t mask = 0;
  int kinds = 0;
  bool history = false;
  if (const base::ListValue* list = payload.FindList("kinds")) {
    for (const base::Value& kind : *list) {
      if (!kind.is_string()) {
        continue;
      }
      const std::string& k = kind.GetString();
      if (k == "history") {
        history = true;
      } else if (k == "cookies") {
        mask |= content::BrowsingDataRemover::DATA_TYPE_COOKIES;
      } else if (k == "cache") {
        mask |= content::BrowsingDataRemover::DATA_TYPE_CACHE;
      } else if (k == "downloads") {
        mask |= content::BrowsingDataRemover::DATA_TYPE_DOWNLOADS;
      } else if (k == "site_data") {
        mask |= content::BrowsingDataRemover::DATA_TYPE_DOM_STORAGE;
      } else {
        continue;
      }
      ++kinds;
    }
  }
  if (history) {
    // Open's own history store (not Chromium's HistoryService).
    RunOnStore(ps->history,
               base::BindOnce(
                   [](std::optional<TimestampSec> since, TimestampSec through,
                      HistoryStore* store) {
                     store->ClearRange(since, through);
                   },
                   range == "all" ? std::nullopt
                                  : std::optional<TimestampSec>(
                                        begin.InSecondsFSinceUnixEpoch()),
                   base::Time::Now().InSecondsFSinceUnixEpoch() + 1));
  }
  auto done = base::BindOnce(
      [](Reply reply, int kinds) {
        ReplyOk(std::move(reply), base::DictValue()
                                      .Set("ok", true)
                                      .Set("cleared_items", kinds));
      },
      std::move(reply), kinds);
  if (mask == 0) {
    std::move(done).Run();
    return;
  }
  DataRemovalObserver::Start(ps->chrome_profile->GetBrowsingDataRemover(),
                             begin, mask, std::move(done));
}

void OpenSettingsUI::SetDefaultBrowser(const base::DictValue& payload,
                                       Reply reply) {
  // Shell integration may spawn processes (xdg-settings) or show OS UI.
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
      base::BindOnce([]() -> std::pair<std::string, bool> {
        OpenPlatform* platform = OpenPlatform::Get();
        if (!platform) {
          return {"failed", false};
        }
        if (platform->IsDefaultBrowser()) {
          return {"already", true};
        }
        const bool requested = platform->SetDefaultBrowser();
        const bool is_default = platform->IsDefaultBrowser();
        return {is_default ? "success" : (requested ? "declined" : "failed"),
                is_default};
      }),
      base::BindOnce(
          [](Reply reply, std::pair<std::string, bool> result) {
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("status", result.first)
                        .Set("is_default", result.second));
          },
          std::move(reply)));
}

// --- Extensions --------------------------------------------------------------

void OpenSettingsUI::GetExtensions(const base::DictValue& payload,
                                   Reply reply) {
  ProfileServices* ps =
      service()->ProfileServicesFor(ProfileFromPayload(payload));
  base::ListValue extensions;
  if (ps && ps->extensions) {
    for (const ExtensionActionInfo& info : ps->extensions->ListInstalled()) {
      extensions.Append(OpenExtensionBridge::ToValue(info));
    }
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("extensions", std::move(extensions)));
}

void OpenSettingsUI::ToggleExtension(const base::DictValue& payload,
                                     Reply reply) {
  ProfileServices* ps = service()->ProfileServicesFor(profile_id());
  const std::string id = json::GetString(payload, "id");
  if (!ps || !ps->extensions || id.empty()) {
    ReplyError(std::move(reply), "no such extension");
    return;
  }
  if (std::optional<bool> enabled = payload.FindBool("enabled")) {
    ps->extensions->SetEnabled(id, *enabled);
  }
  if (std::optional<bool> pinned = payload.FindBool("pinned")) {
    ps->extensions->SetPinned(id, *pinned);
  }
  GetExtensions(payload, std::move(reply));
}

// --- Account & Sync ----------------------------------------------------------

void OpenSettingsUI::SyncGetStatus(const base::DictValue& payload,
                                   Reply reply) {
  SyncEngine* sync = SyncFor(profile_id());
  if (!sync) {
    ReplyError(std::move(reply), "sync is not available");
    return;
  }
  const SyncStatusInfo status = sync->Status();
  if (!status.signed_in) {
    ReplyOk(std::move(reply), SyncStatusToValue(status, {}));
    return;
  }
  sync->ListDevices(base::BindOnce(
      [](SyncStatusInfo status, Reply reply,
         std::vector<SyncDeviceInfo> devices) {
        ReplyOk(std::move(reply), SyncStatusToValue(status, devices));
      },
      status, std::move(reply)));
}

void OpenSettingsUI::SyncConfigureServer(const base::DictValue& payload,
                                         Reply reply) {
  SyncEngine* sync = SyncFor(profile_id());
  const GURL server(json::GetString(payload, "server_url"));
  if (!sync || !server.is_valid() || !server.SchemeIsHTTPOrHTTPS()) {
    ReplyError(std::move(reply), "an http(s) server URL is needed");
    return;
  }
  std::map<std::string, bool> categories;
  if (const base::DictValue* c = payload.FindDict("categories")) {
    for (auto [name, value] : *c) {
      if (value.is_bool()) {
        categories[name] = value.GetBool();
      }
    }
  }
  sync->ConfigureServer(
      server.spec(), std::move(categories),
      base::BindOnce(
          [](Reply reply, SyncStatusInfo status) {
            ReplyOk(std::move(reply), SyncStatusToValue(status, {}));
          },
          std::move(reply)));
}

void OpenSettingsUI::SyncRegister(const base::DictValue& payload,
                                  Reply reply) {
  const ProfileID profile = profile_id();
  SyncEngine* sync = SyncFor(profile);
  const std::string email = json::GetString(payload, "email");
  const std::string password = json::GetString(payload, "password");
  const std::string server = json::GetString(payload, "server_url");
  if (!sync || email.empty() || password.size() < 8 ||
      !GURL(server).SchemeIsHTTPOrHTTPS()) {
    ReplyError(std::move(reply),
               "an email, a password of 8+ characters and a server are needed");
    return;
  }
  sync->Register(
      email, password, server,
      base::BindOnce(
          [](ProfileID profile, Reply reply,
             base::expected<std::string, std::string> recovery_key) {
            SyncEngine* sync = SyncFor(profile);
            if (!recovery_key.has_value() || !sync) {
              ReplyError(std::move(reply),
                         recovery_key.has_value() ? "sync is not available"
                                                  : recovery_key.error());
              return;
            }
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("status", SyncStatusToValue(sync->Status(), {}))
                        .Set("recovery_key", recovery_key.value()));
          },
          profile, std::move(reply)));
}

void OpenSettingsUI::SyncLogin(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = profile_id();
  SyncEngine* sync = SyncFor(profile);
  const std::string server = json::GetString(payload, "server_url");
  if (!sync || !GURL(server).SchemeIsHTTPOrHTTPS()) {
    ReplyError(std::move(reply), "a server URL is needed");
    return;
  }
  sync->Login(
      json::GetString(payload, "email"), json::GetString(payload, "password"),
      server,
      base::BindOnce(
          [](ProfileID profile, Reply reply,
             base::expected<bool, std::string> has_cloud_data) {
            SyncEngine* sync = SyncFor(profile);
            if (!has_cloud_data.has_value() || !sync) {
              ReplyError(std::move(reply),
                         has_cloud_data.has_value() ? "sync is not available"
                                                    : has_cloud_data.error());
              return;
            }
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("status", SyncStatusToValue(sync->Status(), {}))
                        .Set("has_cloud_data", has_cloud_data.value()));
          },
          profile, std::move(reply)));
}

void OpenSettingsUI::SyncLogout(const base::DictValue& payload, Reply reply) {
  SyncEngine* sync = SyncFor(profile_id());
  if (!sync) {
    ReplyError(std::move(reply), "sync is not available");
    return;
  }
  sync->Logout(base::BindOnce(
      [](Reply reply, SyncStatusInfo status) {
        ReplyOk(std::move(reply), SyncStatusToValue(status, {}));
      },
      std::move(reply)));
}

void OpenSettingsUI::SyncTriggerNow(const base::DictValue& payload,
                                    Reply reply) {
  SyncEngine* sync = SyncFor(profile_id());
  if (!sync) {
    ReplyError(std::move(reply), "sync is not available");
    return;
  }
  const ProfileID profile = profile_id();
  sync->SyncNow(base::BindOnce(
      [](ProfileID profile, Reply reply, SyncResult result) {
        SyncEngine* sync = SyncFor(profile);
        if (!sync) {
          ReplyError(std::move(reply), "sync is not available");
          return;
        }
        SyncStatusInfo status = sync->Status();
        if (!result.ok && !result.error_message.empty()) {
          status.error_message = result.error_message;
        }
        ReplyOk(std::move(reply), SyncStatusToValue(status, {}));
      },
      profile, std::move(reply)));
}

void OpenSettingsUI::SyncRecover(const base::DictValue& payload,
                                 Reply reply) {
  const ProfileID profile = profile_id();
  SyncEngine* sync = SyncFor(profile);
  const std::string new_password = json::GetString(payload, "new_password");
  if (!sync || new_password.size() < 8) {
    ReplyError(std::move(reply), "a new password of 8+ characters is needed");
    return;
  }
  sync->Recover(
      json::GetString(payload, "email"),
      json::GetString(payload, "recovery_key"), new_password,
      json::GetString(payload, "server_url"),
      base::BindOnce(
          [](ProfileID profile, Reply reply,
             base::expected<void, std::string> result) {
            SyncEngine* sync = SyncFor(profile);
            if (!result.has_value() || !sync) {
              ReplyError(std::move(reply), result.has_value()
                                               ? "sync is not available"
                                               : result.error());
              return;
            }
            ReplyOk(std::move(reply), SyncStatusToValue(sync->Status(), {}));
          },
          profile, std::move(reply)));
}

void OpenSettingsUI::SyncListDevices(const base::DictValue& payload,
                                     Reply reply) {
  SyncEngine* sync = SyncFor(profile_id());
  if (!sync) {
    ReplyError(std::move(reply), "sync is not available");
    return;
  }
  sync->ListDevices(base::BindOnce(
      [](Reply reply, std::vector<SyncDeviceInfo> devices) {
        ReplyOk(std::move(reply),
                base::DictValue().Set("devices", DevicesToValue(devices)));
      },
      std::move(reply)));
}

void OpenSettingsUI::SyncRevokeDevice(const base::DictValue& payload,
                                      Reply reply) {
  SyncEngine* sync = SyncFor(profile_id());
  const std::string device = json::GetString(payload, "device_id");
  if (!sync || device.empty()) {
    ReplyError(std::move(reply), "no such device");
    return;
  }
  const ProfileID profile = profile_id();
  sync->RevokeDevice(
      device,
      base::BindOnce(
          [](ProfileID profile, Reply reply, SyncResult result) {
            SyncEngine* sync = SyncFor(profile);
            if (!result.ok || !sync) {
              ReplyError(std::move(reply), result.error_message.empty()
                                               ? "the device was not revoked"
                                               : result.error_message);
              return;
            }
            sync->ListDevices(base::BindOnce(
                [](Reply reply, std::vector<SyncDeviceInfo> devices) {
                  ReplyOk(std::move(reply),
                          base::DictValue().Set("devices",
                                                  DevicesToValue(devices)));
                },
                std::move(reply)));
          },
          profile, std::move(reply)));
}

}  // namespace open_unified::webui
