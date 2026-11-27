// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_settings_ui.h"

#include <algorithm>
#include <cmath>
#include <set>
#include <utility>

#include "base/base_paths.h"
#include "base/command_line.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/scoped_observation.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/utf_string_conversions.h"
#include "base/system/sys_info.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/version_info/version_info.h"
#include "build/build_config.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/platform_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/themes/theme_service.h"          // nogncheck
#include "chrome/browser/themes/theme_service_factory.h"  // nogncheck
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/options_page_info.h"
#include "open/adblock/open_adblock_service.h"
#include "open_unified/browser/open_download_bridge.h"
#include "open_unified/browser/open_extension_bridge.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_media_bridge.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/browser/open_switches.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/open_updater_service.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/documents/document_store.h"
#include "open_unified/core/import/browser_importer.h"
#include "open_unified/core/routing/routing_evaluator.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "open_unified/core/sync/sync_engine.h"
#include "open_unified/ui/webui/open_library_ui.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"  // nogncheck
#include "third_party/blink/public/common/page/page_zoom.h"
#include "ui/base/base_window.h"
#include "ui/base/clipboard/clipboard_buffer.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/native_theme/native_theme.h"
#include "ui/shell_dialogs/select_file_dialog.h"   // nogncheck
#include "ui/shell_dialogs/select_file_policy.h"   // nogncheck
#include "ui/shell_dialogs/selected_file_info.h"   // nogncheck
#include "url/gurl.h"

namespace open_unified::webui {

namespace {

// --- Methods of the Settings redesign (settings.<area>.<verb>) --------------
// They live here, not in open_ipc_contract.h, because only open://settings
// (OpenSettingsUI) serves them; bridge.ts RPC_METHODS mirrors every name.
constexpr char kSettingsGetTheme[] = "settings.getTheme";
constexpr char kSettingsOpenChromeUrl[] = "settings.openChromeUrl";
constexpr char kSettingsPickFolder[] = "settings.pickFolder";
constexpr char kSettingsPickDownloadFolder[] = "settings.pickDownloadFolder";
constexpr char kSettingsExportSnapshot[] = "settings.exportSnapshot";

constexpr char kProfilesList[] = "settings.profiles.list";
constexpr char kProfilesSwitch[] = "settings.profiles.switch";
constexpr char kProfilesCreate[] = "settings.profiles.create";
constexpr char kProfilesRename[] = "settings.profiles.rename";
constexpr char kProfilesSetIcon[] = "settings.profiles.setIcon";
constexpr char kProfilesSetSearchEngine[] = "settings.profiles.setSearchEngine";
constexpr char kProfilesSetCustomSearchEngines[] =
    "settings.profiles.setCustomSearchEngines";
constexpr char kProfilesDelete[] = "settings.profiles.delete";
constexpr char kProfilesCleanupUnused[] = "settings.profiles.cleanupUnused";

constexpr char kSpacesList[] = "settings.spaces.list";
constexpr char kSpacesCreate[] = "settings.spaces.create";
constexpr char kSpacesRename[] = "settings.spaces.rename";
constexpr char kSpacesSetProfile[] = "settings.spaces.setProfile";

constexpr char kAtcGet[] = "settings.atc.get";
constexpr char kAtcSetDefaultDestination[] =
    "settings.atc.setDefaultDestination";
constexpr char kAtcAddRule[] = "settings.atc.addRule";
constexpr char kAtcUpdateRule[] = "settings.atc.updateRule";
constexpr char kAtcDeleteRule[] = "settings.atc.deleteRule";
constexpr char kAtcReorderRules[] = "settings.atc.reorderRules";
constexpr char kAtcListRunningApps[] = "settings.atc.listRunningApps";
constexpr char kAtcTestUrl[] = "settings.atc.testUrl";
constexpr char kAtcRecentDecisions[] = "settings.atc.recentDecisions";

constexpr char kShortcutsList[] = "settings.shortcuts.list";
constexpr char kShortcutsSet[] = "settings.shortcuts.set";
constexpr char kShortcutsClear[] = "settings.shortcuts.clear";
constexpr char kShortcutsReset[] = "settings.shortcuts.reset";
constexpr char kShortcutsResetAll[] = "settings.shortcuts.resetAll";
constexpr char kShortcutsSetPriority[] = "settings.shortcuts.setPriority";
constexpr char kShortcutsExportJson[] = "settings.shortcuts.exportJson";
constexpr char kShortcutsImportJson[] = "settings.shortcuts.importJson";

constexpr char kAdBlockGet[] = "settings.adblock.get";
constexpr char kAdBlockUpdateNow[] = "settings.adblock.updateNow";
constexpr char kAdBlockResetLists[] = "settings.adblock.resetLists";
constexpr char kAdBlockSetCustomRules[] = "settings.adblock.setCustomRules";
constexpr char kAdBlockCopyDebugInfo[] = "settings.adblock.copyDebugInfo";
constexpr char kAdBlockDetectConflicts[] =
    "settings.adblock.detectConflictingExtensions";

constexpr char kExtensionsRemove[] = "settings.extensions.remove";
constexpr char kExtensionsOpenOptions[] = "settings.extensions.openOptions";

constexpr char kSyncDetailed[] = "settings.sync.getStatus";
constexpr char kSyncSignIn[] = "settings.sync.signIn";
constexpr char kSyncSignUp[] = "settings.sync.signUp";
constexpr char kSyncSignOut[] = "settings.sync.signOut";
constexpr char kSyncCompleteInitial[] = "settings.sync.completeInitialSync";
constexpr char kSyncNowDetailed[] = "settings.sync.syncNow";
constexpr char kSyncChangePassword[] = "settings.sync.changePassword";
constexpr char kSyncUpdateDisplayName[] = "settings.sync.updateDisplayName";
constexpr char kSyncDeleteAccount[] = "settings.sync.deleteAccount";
constexpr char kSyncRevokeDeviceDetailed[] = "settings.sync.revokeDevice";
constexpr char kSyncSetServerUrl[] = "settings.sync.setServerUrl";
constexpr char kSyncSetCategory[] = "settings.sync.setCategory";
constexpr char kSyncRecoverDetailed[] = "settings.sync.recover";

constexpr char kSettingsImportDetect[] = "settings.import.detect";
constexpr char kSettingsImportPickHtml[] = "settings.import.pickHtml";
constexpr char kSettingsImportRun[] = "settings.import.run";
constexpr char kSettingsImportUndo[] = "settings.import.undo";
constexpr char kSettingsImportReceipts[] = "settings.import.receipts";

constexpr char kAboutGet[] = "settings.about.get";
constexpr char kAboutShowDataFolder[] = "settings.about.showDataFolder";
constexpr char kAboutCopySystemInfo[] = "settings.about.copySystemInfo";
constexpr char kAboutCheckForUpdates[] = "settings.about.checkForUpdates";
constexpr char kAboutReplayOnboarding[] = "settings.about.replayOnboarding";

constexpr char kPreferencesFile[] = "Preferences.json";
constexpr char kOpenUnifiedVersion[] = "0.2.0";
constexpr size_t kMaxCustomSearchEngines = 64;
constexpr size_t kMaxImportReceipts = 20;
constexpr size_t kMaxImportedBookmarks = 20000;
constexpr size_t kMaxImportedHistory = 50000;

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
    {"profiles.newDocuments", "default_document_app"},
};

const ProfileKey* FindProfileKey(std::string_view key) {
  for (const ProfileKey& entry : kProfileKeys) {
    if (key == entry.preference) {
      return &entry;
    }
  }
  return nullptr;
}

// The built-in search engines (catalog.ts BUILTIN_SEARCH_ENGINES).
constexpr const char* kBuiltinEngineIds[] = {"google", "duckduckgo", "kagi",
                                            "bing",   "perplexity", "ecosia"};

bool IsBuiltinEngine(std::string_view id) {
  for (const char* builtin : kBuiltinEngineIds) {
    if (id == builtin) {
      return true;
    }
  }
  return false;
}

base::FilePath PreferencesPath() {
  OpenBrowserService* service = OpenBrowserService::Get();
  return service ? service->user_data_dir()
                       .AppendASCII("State")
                       .AppendASCII(kPreferencesFile)
                 : base::FilePath();
}

// The one OpenMediaBridge of the app (SetMediaBridge()).
OpenMediaBridge* g_media_bridge = nullptr;

// Open Unified's version, read once from the bundle (macOS) off the UI
// thread; kOpenUnifiedVersion until then and on other platforms.
std::string& CachedOpenVersion() {
  static base::NoDestructor<std::string> version(kOpenUnifiedVersion);
  return *version;
}

std::string ReadBundleVersionBlocking() {
#if BUILDFLAG(IS_MAC)
  base::FilePath exe;
  if (base::PathService::Get(base::FILE_EXE, &exe)) {
    // <App>.app/Contents/MacOS/<exe> -> <App>.app/Contents/Info.plist. A
    // helper's own bundle never reaches the browser process.
    const base::FilePath plist =
        exe.DirName().DirName().AppendASCII("Info.plist");
    std::string bytes;
    if (base::ReadFileToStringWithMaxSize(plist, &bytes, 1024 * 1024)) {
      if (std::optional<base::Value> parsed =
              BrowserImporter::ParsePlist(bytes);
          parsed && parsed->is_dict()) {
        if (const std::string* v =
                parsed->GetDict().FindString("CFBundleShortVersionString");
            v && !v->empty() && v->size() < 64) {
          return *v;
        }
      }
    }
  }
#endif
  return kOpenUnifiedVersion;
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

base::ListValue DeviceList(const std::vector<SyncDeviceInfo>& devices) {
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
  return device_list;
}

base::DictValue SyncStatusToValue(
    const SyncStatusInfo& info,
    const std::vector<SyncDeviceInfo>& devices) {
  base::DictValue categories;
  for (const auto& [name, enabled] : info.categories) {
    categories.Set(name, enabled);
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
  d.Set("devices", DeviceList(devices));
  return d;
}

base::ListValue DevicesToValue(const std::vector<SyncDeviceInfo>& devices) {
  return DeviceList(devices);
}

// The full Account & Sync state for the redesigned pane
// (bridge.ts SyncDetailedStatus).
base::DictValue SyncDetailedToValue(const SyncDetailedStatus& s) {
  base::DictValue categories;
  for (const auto& [name, enabled] : s.categories) {
    categories.Set(name, enabled);
  }
  base::ListValue pending_extensions;
  for (const SyncPendingExtension& ext : s.pending_extension_installs) {
    pending_extensions.Append(base::DictValue()
                                  .Set("profile_id", ext.profile_id)
                                  .Set("extension_id", ext.extension_id)
                                  .Set("name", ext.name));
  }
  base::ListValue warnings;
  for (const std::string& warning : s.warnings) {
    warnings.Append(warning);
  }
  base::DictValue d;
  d.Set("signed_in", s.signed_in);
  d.Set("state", s.state);
  d.Set("status_message", s.status_message);
  d.Set("email", s.email);
  d.Set("display_name", s.display_name);
  d.Set("server_url", s.server_url);
  d.Set("device_id", s.device_id);
  d.Set("device_name", s.device_name);
  if (s.last_sync_at_ms) {
    d.Set("last_sync_at_ms", static_cast<double>(*s.last_sync_at_ms));
  }
  d.Set("last_pulled_revision", s.last_pulled_revision);
  d.Set("pending_push_count", static_cast<int>(s.pending_push_count));
  d.Set("ws_connected", s.websocket_connected);
  d.Set("initial_sync_required", s.initial_sync_required);
  if (s.pending_initial_choice) {
    base::DictValue counts;
    for (const auto& [name, count] : s.pending_initial_choice->collection_counts) {
      counts.Set(name, count);
    }
    d.Set("cloud_summary",
          base::DictValue()
              .Set("server_revision", s.pending_initial_choice->server_revision)
              .Set("has_cloud_data", s.pending_initial_choice->has_cloud_data)
              .Set("collection_counts", std::move(counts)));
  }
  d.Set("devices", DeviceList(s.devices));
  d.Set("categories", std::move(categories));
  d.Set("pending_extensions", std::move(pending_extensions));
  d.Set("warnings", std::move(warnings));
  d.Set("is_busy", s.is_busy);
  if (s.error_message) {
    d.Set("error_message", *s.error_message);
  }
  return d;
}

// Account & Sync is app-wide: one Open Account for every Profile
// (OpenBrowserService::sync()). |profile_id| is the page's Profile, kept for
// call sites that reply with Profile data.
SyncEngine* SyncFor(const ProfileID& /*profile_id*/) {
  OpenBrowserService* service = OpenBrowserService::Get();
  return service ? service->sync() : nullptr;
}

SyncEngine* AppSync() {
  OpenBrowserService* service = OpenBrowserService::Get();
  return service ? service->sync() : nullptr;
}

std::optional<FirstSyncStrategy> ParseStrategy(std::string_view s) {
  if (s == "merge") return FirstSyncStrategy::kMergeLocalAndCloud;
  if (s == "use_server" || s == "cloud") {
    return FirstSyncStrategy::kReplaceLocalWithCloud;
  }
  if (s == "use_local" || s == "local") {
    return FirstSyncStrategy::kReplaceCloudWithLocal;
  }
  return std::nullopt;
}

// The reply of a SyncEngine call: the detailed status, or the error.
base::expected<base::Value, std::string> SyncResultValue(
    const SyncResult& result) {
  SyncEngine* sync = AppSync();
  if (!sync) {
    return base::unexpected("sync is not available");
  }
  if (!result.ok) {
    return base::unexpected(
        result.error_message.empty()
            ? std::string("the sync server did not accept the request")
            : result.error_message);
  }
  base::DictValue d;
  d.Set("status", SyncDetailedToValue(sync->GetDetailedStatus()));
  if (!result.recovery_key.empty()) {
    d.Set("recovery_key", result.recovery_key);
  }
  d.Set("needs_initial_choice", result.needs_initial_choice.has_value());
  return base::Value(std::move(d));
}

// Preferences.json writes run one at a time, in order, on this sequence
// (BLOCK_SHUTDOWN): an older snapshot can never land after a newer one.
scoped_refptr<base::SequencedTaskRunner> PreferencesFileRunner() {
  static base::NoDestructor<scoped_refptr<base::SequencedTaskRunner>> runner(
      base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::BLOCK_SHUTDOWN}));
  return *runner;
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

std::string_view PriorityName(ShortcutPriority priority) {
  switch (priority) {
    case ShortcutPriority::kBrowser:
      return "browser";
    case ShortcutPriority::kSite:
      return "site";
    case ShortcutPriority::kSiteThenBrowser:
      return "site-then-browser";
  }
  return "browser";
}

std::optional<ShortcutPriority> ParsePriority(std::string_view s) {
  if (s == "browser") return ShortcutPriority::kBrowser;
  if (s == "site") return ShortcutPriority::kSite;
  if (s == "site-then-browser") return ShortcutPriority::kSiteThenBrowser;
  return std::nullopt;
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
  if (base::StartsWith(command.id, "go-to-tab-") ||
      base::StartsWith(command.id, "focus-split-pane-")) {
    return "Tabs";
  }
  if (base::StartsWith(command.id, "go-to-space-")) return "Spaces";
  return "Tools";
}

std::string_view RuleOutcomeName(RoutingRuleOutcome outcome) {
  switch (outcome) {
    case RoutingRuleOutcome::kMatched:
      return "matched";
    case RoutingRuleOutcome::kDisabled:
      return "disabled";
    case RoutingRuleOutcome::kSourceUnknown:
      return "source_unknown";
    case RoutingRuleOutcome::kSourceMismatch:
      return "source_mismatch";
    case RoutingRuleOutcome::kHostMismatch:
      return "host_mismatch";
    case RoutingRuleOutcome::kPathMismatch:
      return "path_mismatch";
    case RoutingRuleOutcome::kTargetSpaceMissing:
      return "space_missing";
    case RoutingRuleOutcome::kTargetProfileMissing:
      return "profile_missing";
  }
  return "host_mismatch";
}

std::string_view RoutingViaName(RoutingVia via) {
  switch (via) {
    case RoutingVia::kRule:
      return "rule";
    case RoutingVia::kDefaultDestination:
      return "default";
    case RoutingVia::kFallbackMissingSpace:
      return "fallback_missing_space";
    case RoutingVia::kFallbackMissingProfile:
      return "fallback_missing_profile";
    case RoutingVia::kDefaultSuppressedByToggle:
      return "default_suppressed";
    case RoutingVia::kRejectedNonHttp:
      return "rejected_non_http";
    case RoutingVia::kNoSpaces:
      return "no_spaces";
  }
  return "default";
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

// "Little Open", "Most recent Space" or the Space's title.
std::string DestinationLabel(const BrowserModel& model,
                             RoutingDestinationKind kind,
                             const std::optional<SpaceID>& space_id) {
  switch (kind) {
    case RoutingDestinationKind::kLittleOpen:
      return "Little Open";
    case RoutingDestinationKind::kMostRecentSpace:
      return "Most recent Space";
    case RoutingDestinationKind::kSpace:
      if (space_id && model.FindSpace(*space_id)) {
        return model.DisplayTitleForSpace(*space_id);
      }
      return "A deleted Space";
  }
  return std::string();
}

std::string RuleName(const BrowserModel& model, const RuleID& id) {
  for (const RoutingRule& rule : model.routing_rules()) {
    if (rule.id == id) {
      return rule.name.empty() ? rule.host_pattern : rule.name;
    }
  }
  return std::string();
}

base::DictValue DecisionToValue(const BrowserModel& model,
                                const RoutingDecision& decision) {
  base::DictValue d;
  d.Set("url", decision.request.url);
  if (decision.normalized_host) {
    d.Set("host", *decision.normalized_host);
  }
  if (decision.request.source_app_id) {
    d.Set("source_app_id", *decision.request.source_app_id);
  }
  d.Set("at", decision.request.received_at);
  d.Set("via", RoutingViaName(decision.via));
  d.Set("explanation", RoutingExplanation(decision));
  if (decision.matched_rule_id) {
    d.Set("matched_rule_id", *decision.matched_rule_id);
    d.Set("matched_rule_name", RuleName(model, *decision.matched_rule_id));
  }
  RoutingDestination destination;
  if (decision.resolved) {
    destination.kind = decision.resolved->kind;
    destination.space_id = decision.resolved->space_id;
    destination.profile_id = decision.resolved->profile_id;
  }
  d.Set("destination", json::RoutingDestinationToValue(destination));
  d.Set("destination_label",
        decision.resolved
            ? DestinationLabel(model, decision.resolved->kind,
                               decision.resolved->space_id)
            : std::string("Not opened"));
  base::ListValue traces;
  for (const RoutingRuleTrace& trace : decision.traces) {
    traces.Append(base::DictValue()
                      .Set("index", static_cast<int>(trace.rule_index))
                      .Set("rule_id", trace.rule_id)
                      .Set("rule_name", RuleName(model, trace.rule_id))
                      .Set("outcome", RuleOutcomeName(trace.outcome)));
  }
  d.Set("traces", std::move(traces));
  return d;
}

// WCAG 2.x relative luminance and contrast ratio.
double Channel(double c) {
  return c <= 0.03928 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
}
double RelLuminance(const RGBAColor& c) {
  return 0.2126 * Channel(c.r) + 0.7152 * Channel(c.g) + 0.0722 * Channel(c.b);
}
double Contrast(const RGBAColor& a, const RGBAColor& b) {
  const double la = RelLuminance(a);
  const double lb = RelLuminance(b);
  return (std::max(la, lb) + 0.05) / (std::min(la, lb) + 0.05);
}
RGBAColor MixColor(const RGBAColor& a, const RGBAColor& b, double t) {
  return RGBAColor{a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, 1.0};
}
std::string CssColor(const RGBAColor& c) {
  auto byte = [](double v) {
    return static_cast<int>(std::lround(std::clamp(v, 0.0, 1.0) * 255.0));
  };
  return base::StringPrintf("#%02x%02x%02x", byte(c.r), byte(c.g), byte(c.b));
}
std::string CssRgba(const RGBAColor& c, double alpha) {
  auto byte = [](double v) {
    return static_cast<int>(std::lround(std::clamp(v, 0.0, 1.0) * 255.0));
  };
  return base::StringPrintf("rgba(%d, %d, %d, %.2f)", byte(c.r), byte(c.g),
                            byte(c.b), alpha);
}

// An accent with at least WCAG AA (4.5:1) contrast as text on |surface|:
// mixed toward black (light) or white (dark) in small steps.
RGBAColor AccessibleAccent(const RGBAColor& key,
                           const RGBAColor& surface,
                           bool dark) {
  const RGBAColor target = dark ? RGBAColor{1, 1, 1, 1} : RGBAColor{0, 0, 0, 1};
  RGBAColor out = key;
  for (int step = 0; step < 20 && Contrast(out, surface) < 4.5; ++step) {
    out = MixColor(key, target, (step + 1) * 0.05);
  }
  return out;
}

bool SystemIsDark() {
  ui::NativeTheme* theme = ui::NativeTheme::GetInstanceForNativeUi();
  return theme && theme->preferred_color_scheme() ==
                      ui::NativeTheme::PreferredColorScheme::kDark;
}

// The Chromium Profiles of every Open Profile (or |ids|).
std::vector<::Profile*> ChromeProfiles(const std::vector<ProfileID>& ids) {
  std::vector<::Profile*> out;
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    return out;
  }
  std::vector<ProfileID> targets = ids;
  if (targets.empty()) {
    for (const Profile& profile : service->model().profiles()) {
      targets.push_back(profile.id);
    }
  }
  for (const ProfileID& id : targets) {
    if (ProfileServices* ps = service->ProfileServicesFor(id);
        ps && ps->chrome_profile) {
      out.push_back(ps->chrome_profile);
    }
  }
  return out;
}

bool BoolPref(const std::string& key) {
  const base::Value v = OpenPreferences::Get()->GetValue(key);
  return v.is_bool() && v.GetBool();
}

std::string StringPref(const std::string& key) {
  const base::Value v = OpenPreferences::Get()->GetValue(key);
  return v.is_string() ? v.GetString() : std::string();
}

void CopyToClipboard(const std::string& text) {
  ui::ScopedClipboardWriter writer(ui::ClipboardBuffer::kCopyPaste);
  writer.WriteText(base::UTF8ToUTF16(text));
}

// Removes browsing data of one Chromium Profile, then deletes itself.
//
// Chromium 156's BrowsingDataRemoverImpl::RemoveAndReply() DCHECKs that the
// observer is registered (AddObserver) before the task starts, and calls
// only that task's observer when it is done; the single registration below
// is that requirement, not a duplicate. Shutdown: when the Profile (and its
// remover) goes away with the task pending, ~BrowsingDataRemoverImpl reports
// the task done (failed) to registered observers, so this object still
// deletes itself; the reply then reaches a closed page as a no-op.
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
    if (!done_) {
      return;  // Already finished (never runs twice).
    }
    observation_.Reset();
    base::OnceClosure done = std::move(done_);
    delete this;
    std::move(done).Run();
  }

 private:
  DataRemovalObserver(content::BrowsingDataRemover* remover,
                      base::OnceClosure done)
      : done_(std::move(done)) {
    observation_.Observe(remover);
  }
  ~DataRemovalObserver() override = default;

  base::OnceClosure done_;
  base::ScopedObservation<content::BrowsingDataRemover,
                          content::BrowsingDataRemover::Observer>
      observation_{this};
};

// --- Import receipts ---------------------------------------------------------

// One import of this browser session: the model receipt (BrowserImporter
// UndoImport) plus what went into the per-Profile stores, which live on
// their own sequences (UndoImportTargets needs synchronous store pointers,
// so those parts are recorded and undone here through RunOnStore).
struct ImportEntry {
  std::string id;
  std::string source_name;
  std::string source_kind;
  double imported_at = 0;
  ImportReceipt receipt;
  base::DictValue counts;
  std::map<ProfileID, std::vector<std::string>> boost_ids;
  std::map<ProfileID, std::vector<std::string>> easel_ids;
  std::map<ProfileID, std::vector<std::string>> note_ids;
  std::map<ProfileID, std::vector<ItemID>> archive_ids;
  std::map<ProfileID, std::vector<std::string>> history_urls;
  bool undone = false;
};

std::vector<ImportEntry>& ImportEntries() {
  static base::NoDestructor<std::vector<ImportEntry>> entries;
  return *entries;
}

ImportEntry* FindImportEntry(const std::string& id) {
  for (ImportEntry& entry : ImportEntries()) {
    if (entry.id == id) {
      return &entry;
    }
  }
  return nullptr;
}

base::DictValue ImportEntryToValue(const ImportEntry& entry) {
  return base::DictValue()
      .Set("receipt_id", entry.id)
      .Set("source_name", entry.source_name)
      .Set("source_kind", entry.source_kind)
      .Set("imported_at", entry.imported_at)
      .Set("counts", entry.counts.Clone())
      .Set("undone", entry.undone);
}

std::string_view FamilyKind(BrowserFamily family) {
  switch (family) {
    case BrowserFamily::kArc:
      return "arc";
    case BrowserFamily::kChromium:
      return "chromium";
    case BrowserFamily::kFirefox:
      return "firefox";
    case BrowserFamily::kSafari:
      return "safari";
    case BrowserFamily::kOpenLegacy:
      return "open_legacy";
    case BrowserFamily::kHtmlBookmarks:
      return "html";
  }
  return "chromium";
}

void CountNodes(const std::vector<ImportedBookmarkNode>& nodes,
                size_t* urls) {
  for (const ImportedBookmarkNode& node : nodes) {
    if (node.is_folder) {
      CountNodes(node.children, urls);
    } else {
      ++*urls;
    }
  }
}

// Macintosh apps for the Air Traffic Control source picker: bundle id and
// name of every .app in the standard folders (Info.plist, binary or XML).
base::ListValue ListApplicationsBlocking() {
  base::ListValue apps;
#if BUILDFLAG(IS_MAC)
  std::vector<base::FilePath> roots = {
      base::FilePath("/Applications"),
      base::FilePath("/Applications/Utilities"),
      base::FilePath("/System/Applications"),
      base::FilePath("/System/Applications/Utilities"),
  };
  base::FilePath home;
  if (base::PathService::Get(base::DIR_HOME, &home)) {
    roots.push_back(home.AppendASCII("Applications"));
  }
  std::map<std::string, std::string> by_id;  // bundle id -> name
  for (const base::FilePath& root : roots) {
    base::FileEnumerator it(root, /*recursive=*/false,
                            base::FileEnumerator::DIRECTORIES);
    for (base::FilePath app = it.Next(); !app.empty() && by_id.size() < 600;
         app = it.Next()) {
      if (app.Extension() != ".app") {
        continue;
      }
      std::string bytes;
      if (!base::ReadFileToStringWithMaxSize(
              app.AppendASCII("Contents").AppendASCII("Info.plist"), &bytes,
              512 * 1024)) {
        continue;
      }
      std::optional<base::Value> plist = BrowserImporter::ParsePlist(bytes);
      if (!plist || !plist->is_dict()) {
        continue;
      }
      const std::string* id = plist->GetDict().FindString("CFBundleIdentifier");
      if (!id || id->empty() || id->size() > 255) {
        continue;
      }
      const std::string* name =
          plist->GetDict().FindString("CFBundleDisplayName");
      if (!name || name->empty()) {
        name = plist->GetDict().FindString("CFBundleName");
      }
      by_id.emplace(*id, name && !name->empty()
                             ? *name
                             : app.BaseName().RemoveExtension().AsUTF8Unsafe());
    }
  }
  std::vector<std::pair<std::string, std::string>> sorted(by_id.begin(),
                                                          by_id.end());
  std::sort(sorted.begin(), sorted.end(), [](const auto& a, const auto& b) {
    return base::CompareCaseInsensitiveASCII(a.second, b.second) < 0;
  });
  for (const auto& [id, name] : sorted) {
    apps.Append(base::DictValue().Set("id", id).Set("name", name));
  }
#endif
  return apps;
}

// Ad-block extensions that duplicate Open's blocker.
bool IsAdBlockExtension(const std::string& name) {
  const std::string lower = base::ToLowerASCII(name);
  for (const char* needle : {"ublock", "adblock", "adguard", "ghostery",
                             "privacy badger", "ad block", "adblocker"}) {
    if (lower.find(needle) != std::string::npos) {
      return true;
    }
  }
  return false;
}

std::string SystemInfoText(const std::string& open_version) {
  OpenBrowserService* service = OpenBrowserService::Get();
  std::string text;
  text += "Open Unified " + open_version + "\n";
  text += "Chromium " + std::string(version_info::GetVersionNumber()) + "\n";
  text += "OS: " + base::SysInfo::OperatingSystemName() + " " +
          base::SysInfo::OperatingSystemVersion() + " (" +
          base::SysInfo::OperatingSystemArchitecture() + ")\n";
  text += "Widevine: " +
          std::string(base::CommandLine::ForCurrentProcess()->HasSwitch(
                          switches::kEnableWidevine)
                          ? "enabled this session"
                          : "off") +
          "\n";
  if (service) {
    text += base::StringPrintf(
        "Profiles: %zu, Spaces: %zu, Windows: %zu\n",
        service->model().profiles().size(), service->model().spaces().size(),
        service->model().windows().size());
    if (SyncEngine* sync = service->sync()) {
      const SyncDetailedStatus s = sync->GetDetailedStatus();
      text += "Sync: " + s.state + (s.websocket_connected ? " (live)" : "") +
              "\n";
    }
  }
  return text;
}

// Normalizes legacy macOS-specific "Option" modifier tokens to the canonical
// cross-platform "Alt" token (e.g. "Mod+Option+N" -> "Mod+Alt+N").
std::string NormalizeHotkeyPref(std::string_view raw) {
  std::string trimmed(base::TrimWhitespaceASCII(raw, base::TRIM_ALL));
  if (trimmed.empty() || trimmed.find('+') == std::string::npos) {
    return trimmed;
  }
  const bool ends_with_plus =
      trimmed.size() >= 2 && trimmed.ends_with("++");
  const std::string_view body =
      ends_with_plus ? std::string_view(trimmed).substr(0, trimmed.size() - 1)
                     : std::string_view(trimmed);
  std::vector<std::string> parts;
  size_t start = 0;
  while (start <= body.size()) {
    const size_t sep = body.find('+', start);
    const std::string_view part =
        sep == std::string_view::npos ? body.substr(start)
                                      : body.substr(start, sep - start);
    std::string token(base::TrimWhitespaceASCII(part, base::TRIM_ALL));
    if (!token.empty()) {
      const std::string lower = base::ToLowerASCII(token);
      if (lower == "option" || lower == "opt") {
        token = "Alt";
      }
      parts.push_back(std::move(token));
    }
    if (sep == std::string_view::npos) {
      break;
    }
    start = sep + 1;
  }
  if (ends_with_plus) {
    parts.push_back("+");
  }
  return base::JoinString(parts, "+");
}

// Formats a profile's download directory for the Settings UI. On Windows,
// resolves the default Unix-style "~/Downloads" placeholder to the user's real
// Windows Downloads path (matching OpenDownloadBridge::ExpandDownloadDirectory);
// on macOS and Linux, keeps "~/Downloads" as-is.
std::string DisplayDownloadDirectory(std::string_view raw) {
#if BUILDFLAG(IS_WIN)
  const std::string_view trimmed =
      base::TrimWhitespaceASCII(raw, base::TRIM_ALL);
  if (trimmed.empty() || trimmed == "~/Downloads" ||
      trimmed == "~\\Downloads") {
    base::FilePath home;
    if (base::PathService::Get(base::DIR_HOME, &home) && !home.empty()) {
      return home.AppendASCII("Downloads").AsUTF8Unsafe();
    }
    const base::FilePath fallback =
        DownloadPrefs::GetDefaultDownloadDirectory();
    if (!fallback.empty()) {
      return fallback.AsUTF8Unsafe();
    }
  }
  if (trimmed == "~" || base::StartsWith(trimmed, "~/") ||
      base::StartsWith(trimmed, "~\\")) {
    base::FilePath home;
    if (base::PathService::Get(base::DIR_HOME, &home) && !home.empty()) {
      if (trimmed.size() <= 2) {
        return home.AsUTF8Unsafe();
      }
      const base::FilePath rel =
          base::FilePath::FromUTF8Unsafe(trimmed.substr(2));
      if (!rel.empty() && !rel.IsAbsolute()) {
        return home.Append(rel).AsUTF8Unsafe();
      }
    }
  }
  return std::string(trimmed.empty() ? "~/Downloads" : trimmed);
#else
  return raw.empty() ? std::string("~/Downloads") : std::string(raw);
#endif
}

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
          .Set("general.offerTranslate", true)
          .Set("appearance.appIcon", "open-indigo")
          .Set("appearance.websiteAppearance", "automatic")
          .Set("appearance.toolbar", false)
          .Set("appearance.fullUrl", false)
          .Set("appearance.sidebarPosition", "left")
          .Set("appearance.sidebarAutoHide", false)
          .Set("appearance.translucency", true)
          .Set("appearance.increaseContrast", false)
          .Set("appearance.fontSize", "medium")
          .Set("appearance.defaultZoom", 100)
          .Set("tabs.archiveAfter", "12h")
          .Set("tabs.littleOpenArchiveAfter", "6h")
          .Set("tabs.sleepMode", "balanced")
          .Set("tabs.includeFavoritesInSwitcher", true)
          .Set("tabs.ninthTabGoesToLast", true)
          .Set("tabs.splitOrientation", "horizontal")
          .Set("search.engine", "google")
          .Set("search.suggestions", true)
          .Set("downloads.location", DisplayDownloadDirectory("~/Downloads"))
          .Set("downloads.askEachTime", false)
          .Set("profiles.newDocuments", "note")
          .Set("previews.enabled", true)
          .Set("previews.folders", true)
          .Set("previews.pages", true)
          .Set("previews.recents", true)
          .Set("previews.calendar", true)
          .Set("previews.gmail", true)
          .Set("links.littleOpenHotkey", "Mod+Alt+N")
          .Set("links.optionCommandClick", true)
          .Set("links.externalLinksLittleOpen", true)
          .Set("links.peekShiftClick", true)
          .Set("links.peekOtherSites", true)
          .Set("shortcuts.priority", "open")
          .Set("privacy.httpsOnly", false)
          .Set("privacy.doNotTrack", false)
          .Set("advanced.soundEffects", true)
          .Set("advanced.haptics", true)
          .Set("advanced.windowDragging", true)
          .Set("advanced.sharedQuotes", true)
          .Set("advanced.pictureInPicture", true)
          .Set("advanced.pipExcludedHosts", base::ListValue())
          .Set("advanced.themeData", true)
          .Set("advanced.enableBoosts", true)
          .Set("advanced.translateOffer", true)
          .Set("advanced.developerMode", false)
          .Set("advanced.hardwareAcceleration", true)
          .Set("advanced.widevine", false));
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
              // Keep only known keys with the default's type, preserving any
              // keys written via Set()/Reset() before the disk load completed.
              for (auto [key, value] : *stored) {
                if (self->dirty_keys_.contains(key)) {
                  continue;
                }
                const base::Value* def = Defaults().Find(key);
                if (def && def->type() == value.type() &&
                    !FindProfileKey(key)) {
                  if (key == "links.littleOpenHotkey" && value.is_string()) {
                    self->stored_.Set(key,
                                      NormalizeHotkeyPref(value.GetString()));
                  } else {
                    self->stored_.Set(key, value.Clone());
                  }
                }
              }
            }
            const bool had_dirty = !self->dirty_keys_.empty();
            self->dirty_keys_.clear();
            self->loaded_ = true;
            self->loading_ = false;
            if (had_dirty) {
              self->Save();
            }
            // Changed preferences take effect from the first launch on.
            ApplyAllEffects();
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
        if (std::string_view(entry.preference) == "downloads.location" &&
            v->is_string()) {
          values.Set(entry.preference,
                     DisplayDownloadDirectory(v->GetString()));
        } else {
          values.Set(entry.preference, v->Clone());
        }
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
  if (value.is_string() && value.GetString().size() > 4096) {
    *error = "value too long for " + key;
    return false;
  }
  if (value.is_list()) {
    if (value.GetList().size() > 500) {
      *error = "too many values for " + key;
      return false;
    }
    for (const base::Value& item : value.GetList()) {
      if (!item.is_string() || item.GetString().empty() ||
          item.GetString().size() > 253) {
        *error = "invalid list item for " + key;
        return false;
      }
    }
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
    ApplyEffects(key, targets);
    return true;
  }
  if (key == "links.littleOpenHotkey" && value.is_string()) {
    stored_.Set(key, NormalizeHotkeyPref(value.GetString()));
  } else {
    stored_.Set(key, value.Clone());
  }
  if (!loaded_) {
    dirty_keys_.insert(key);
    WhenLoaded(base::DoNothing());
  } else {
    Save();
  }
  ApplyEffects(key, {});
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
  if (!loaded_) {
    dirty_keys_.insert(key);
    WhenLoaded(base::DoNothing());
  } else {
    Save();
  }
  ApplyEffects(key, {});
}

void OpenPreferences::Save() {
  std::optional<std::string> json = base::WriteJsonWithOptions(
      stored_, base::JSONWriter::OPTIONS_PRETTY_PRINT);
  const base::FilePath path = PreferencesPath();
  if (!json || path.empty()) {
    return;
  }
  PreferencesFileRunner()->PostTask(
      FROM_HERE,
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

// static
void OpenPreferences::ApplyEffects(const std::string& key,
                                   const std::vector<ProfileID>& profile_ids) {
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    return;
  }
  OpenPreferences* open_prefs = Get();
  if (key == "downloads.location" || key == "downloads.askEachTime") {
    std::vector<ProfileID> targets = profile_ids;
    if (targets.empty()) {
      for (const Profile& profile : service->model().profiles()) {
        targets.push_back(profile.id);
      }
    }
    for (const ProfileID& id : targets) {
      const Profile* profile = service->model().FindProfile(id);
      ProfileServices* ps = service->ProfileServicesFor(id);
      if (!profile || !ps || !ps->chrome_profile) {
        continue;
      }
      OpenDownloadBridge::ApplyDownloadPreferences(
          ps->chrome_profile, profile->settings.download_directory,
          profile->settings.ask_where_to_save_each_file);
    }
  } else if (key == "search.suggestions") {
    for (const ProfileID& id : profile_ids) {
      const Profile* profile = service->model().FindProfile(id);
      ProfileServices* ps = service->ProfileServicesFor(id);
      if (profile && ps && ps->chrome_profile) {
        ps->chrome_profile->GetPrefs()->SetBoolean(
            prefs::kSearchSuggestEnabled,
            profile->settings.search_suggest_enabled);
      }
    }
  } else if (key == "advanced.pictureInPicture") {
    if (g_media_bridge) {
      g_media_bridge->SetAutoPiPEnabled(BoolPref(key));
    }
  } else if (key == "advanced.pipExcludedHosts") {
    if (g_media_bridge) {
      std::vector<std::string> hosts;
      const base::Value v = open_prefs->GetValue(key);
      if (v.is_list()) {
        for (const base::Value& host : v.GetList()) {
          if (host.is_string()) {
            hosts.push_back(host.GetString());
          }
        }
      }
      g_media_bridge->SetAutoPiPDisabledHosts(std::move(hosts));
    }
  } else if (key == "appearance.appIcon") {
    if (OpenPlatform* platform = OpenPlatform::Get()) {
      const std::string id = StringPref(key);
      // The default artwork is the bundle's own icon.
      platform->SetAppIcon(id == "open-indigo" ? std::string() : id);
    }
  } else if (key == "links.littleOpenHotkey") {
    service->ReloadGlobalHotkeys();
  } else if (key == "appearance.websiteAppearance") {
    const std::string mode = StringPref(key);
    const ThemeService::BrowserColorScheme scheme =
        mode == "light"  ? ThemeService::BrowserColorScheme::kLight
        : mode == "dark" ? ThemeService::BrowserColorScheme::kDark
                         : ThemeService::BrowserColorScheme::kSystem;
    for (::Profile* profile : ChromeProfiles({})) {
      if (ThemeService* theme = ThemeServiceFactory::GetForProfile(profile)) {
        theme->SetBrowserColorScheme(scheme);
      }
    }
  } else if (key == "appearance.fontSize") {
    const std::string size = StringPref(key);
    const int px = size == "small"        ? 12
                   : size == "large"      ? 20
                   : size == "very-large" ? 24
                                          : 16;
    for (::Profile* profile : ChromeProfiles({})) {
      profile->GetPrefs()->SetInteger(prefs::kWebKitDefaultFontSize, px);
    }
  } else if (key == "appearance.defaultZoom") {
    const base::Value v = open_prefs->GetValue(key);
    int pct = 100;
    if (v.is_int()) {
      pct = v.GetInt();
    } else if (v.is_double()) {
      pct = static_cast<int>(std::lround(v.GetDouble()));
    }
    pct = std::clamp(pct, 50, 300);
    const double level = blink::ZoomFactorToZoomLevel(pct / 100.0);
    for (::Profile* profile : ChromeProfiles({})) {
      if (content::HostZoomMap* map =
              content::HostZoomMap::GetDefaultForBrowserContext(profile)) {
        map->SetDefaultZoomLevel(level);
      }
    }
  } else if (key == "privacy.doNotTrack") {
    for (::Profile* profile : ChromeProfiles({})) {
      profile->GetPrefs()->SetBoolean(prefs::kEnableDoNotTrack,
                                      BoolPref(key));
    }
  } else if (key == "privacy.httpsOnly") {
    for (::Profile* profile : ChromeProfiles({})) {
      profile->GetPrefs()->SetBoolean(prefs::kHttpsOnlyModeEnabled,
                                      BoolPref(key));
    }
  } else if (key == "advanced.developerMode") {
    for (::Profile* profile : ChromeProfiles({})) {
      profile->GetPrefs()->SetBoolean(prefs::kExtensionsUIDeveloperMode,
                                      BoolPref(key));
    }
  } else if (key == "advanced.hardwareAcceleration") {
    // Read by Chromium at the next launch.
    if (PrefService* local_state = g_browser_process->local_state()) {
      local_state->SetBoolean(prefs::kHardwareAccelerationModeEnabled,
                              BoolPref(key));
    }
  }
  service->BroadcastEvent("open.preferencesChanged",
                          base::Value(base::DictValue().Set("key", key)));
}

// static
void OpenPreferences::ApplyAllEffects() {
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    return;
  }
  // Profile settings are the source of truth for downloads.
  ApplyEffects("downloads.location", {});
  // App preferences: only the ones the user changed, so Chromium's own
  // settings (chrome://settings) keep their values otherwise.
  for (const char* key :
       {"advanced.pictureInPicture", "advanced.pipExcludedHosts",
        "appearance.appIcon", "appearance.websiteAppearance",
        "appearance.fontSize", "appearance.defaultZoom",
        "privacy.doNotTrack", "privacy.httpsOnly", "advanced.developerMode"}) {
    if (Get()->stored_.Find(key)) {
      ApplyEffects(key, {});
    }
  }
  service->BroadcastEvent("open.preferencesChanged",
                          base::Value(base::DictValue().Set("key", "")));
}

// ===========================================================================
// OpenSettingsUI::FileDialog
// ===========================================================================

// A native open/save/folder dialog (ui::SelectFileDialog) for this page.
class OpenSettingsUI::FileDialog : public ui::SelectFileDialog::Listener {
 public:
  using Done = base::OnceCallback<void(std::optional<base::FilePath>)>;

  explicit FileDialog(Done done) : done_(std::move(done)) {}
  ~FileDialog() override {
    if (dialog_) {
      dialog_->ListenerDestroyed();
    }
  }

  void Show(ui::SelectFileDialog::Type type,
            const std::u16string& title,
            const base::FilePath& default_path,
            const std::vector<std::string>& extensions,
            gfx::NativeWindow owner) {
    dialog_ = ui::SelectFileDialog::Create(this, /*policy=*/nullptr);
    ui::SelectFileDialog::FileTypeInfo types;
    for (const std::string& ext : extensions) {
#if BUILDFLAG(IS_WIN)
      types.extensions.push_back({base::UTF8ToWide(ext)});
#else
      types.extensions.push_back({ext});
#endif
    }
    types.include_all_files = extensions.empty();
    base::FilePath::StringType default_extension;
    if (!extensions.empty()) {
      default_extension = types.extensions.front().front();
    }
    dialog_->SelectFile(type, title, default_path,
                        extensions.empty() ? nullptr : &types,
                        extensions.empty() ? 0 : 1, default_extension, owner);
  }

  // ui::SelectFileDialog::Listener:
  void FileSelected(const ui::SelectedFileInfo& file, int index) override {
    Finish(file.path());
  }
  void FileSelectionCanceled() override { Finish(std::nullopt); }

 private:
  void Finish(std::optional<base::FilePath> path) {
    if (done_) {
      std::move(done_).Run(std::move(path));
    }
  }

  Done done_;
  scoped_refptr<ui::SelectFileDialog> dialog_;
};

struct OpenSettingsUI::ImportRecord {
  std::string error;
  bool access_denied = false;
  std::string browser_name;
  std::string source_kind;
  BrowserFamily family = BrowserFamily::kChromium;
  std::vector<std::string> kinds;
  bool has_bookmarks = false;
  std::vector<ImportedBookmarkNode> bookmark_roots;
  std::vector<HistoryEntry> history;
  std::optional<ArcSidebarImportResult> arc;
  std::optional<OpenLegacyImportResult> legacy;

  bool Wants(std::string_view kind) const {
    return std::find(kinds.begin(), kinds.end(), kind) != kinds.end();
  }
};

// ===========================================================================
// OpenSettingsUI
// ===========================================================================

OpenSettingsUI::OpenSettingsUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenSettingsUI::~OpenSettingsUI() = default;

// static
void OpenSettingsUI::SetMediaBridge(OpenMediaBridge* bridge) {
  g_media_bridge = bridge;
  if (bridge && OpenPreferences::Get()->loaded()) {
    OpenPreferences::ApplyEffects("advanced.pictureInPicture", {});
    OpenPreferences::ApplyEffects("advanced.pipExcludedHosts", {});
  }
}

// static
OpenMediaBridge* OpenSettingsUI::media_bridge() {
  return g_media_bridge;
}

// static
std::string OpenSettingsUI::OpenVersion() {
  return CachedOpenVersion();
}

void OpenSettingsUI::RegisterMethods() {
  auto bind = [this](void (OpenSettingsUI::*method)(const base::DictValue&,
                                                    Reply)) {
    return base::BindRepeating(method, weak_factory_.GetWeakPtr());
  };
  // open_ipc_contract.h
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

  // The Settings redesign.
  Register(kSettingsGetTheme, bind(&OpenSettingsUI::GetTheme));
  Register(kSettingsOpenChromeUrl, bind(&OpenSettingsUI::OpenChromeUrl));
  Register(kSettingsPickFolder, bind(&OpenSettingsUI::PickFolder));
  Register(kSettingsPickDownloadFolder,
           bind(&OpenSettingsUI::PickDownloadFolder));
  Register(kSettingsExportSnapshot, bind(&OpenSettingsUI::ExportSnapshot));

  Register(kProfilesList, bind(&OpenSettingsUI::ProfilesList));
  Register(kProfilesSwitch, bind(&OpenSettingsUI::ProfilesSwitch));
  Register(kProfilesCreate, bind(&OpenSettingsUI::ProfilesCreate));
  Register(kProfilesRename, bind(&OpenSettingsUI::ProfilesRename));
  Register(kProfilesSetIcon, bind(&OpenSettingsUI::ProfilesSetIcon));
  Register(kProfilesSetSearchEngine,
           bind(&OpenSettingsUI::ProfilesSetSearchEngine));
  Register(kProfilesSetCustomSearchEngines,
           bind(&OpenSettingsUI::ProfilesSetCustomSearchEngines));
  Register(kProfilesDelete, bind(&OpenSettingsUI::ProfilesDelete));
  Register(kProfilesCleanupUnused,
           bind(&OpenSettingsUI::ProfilesCleanupUnused));

  Register(kSpacesList, bind(&OpenSettingsUI::SpacesList));
  Register(kSpacesCreate, bind(&OpenSettingsUI::SpacesCreate));
  Register(kSpacesRename, bind(&OpenSettingsUI::SpacesRename));
  Register(kSpacesSetProfile, bind(&OpenSettingsUI::SpacesSetProfile));

  Register(kAtcGet, bind(&OpenSettingsUI::AtcGet));
  Register(kAtcSetDefaultDestination,
           bind(&OpenSettingsUI::AtcSetDefaultDestination));
  Register(kAtcAddRule, bind(&OpenSettingsUI::AtcAddRule));
  Register(kAtcUpdateRule, bind(&OpenSettingsUI::AtcUpdateRule));
  Register(kAtcDeleteRule, bind(&OpenSettingsUI::AtcDeleteRule));
  Register(kAtcReorderRules, bind(&OpenSettingsUI::AtcReorderRules));
  Register(kAtcListRunningApps, bind(&OpenSettingsUI::AtcListRunningApps));
  Register(kAtcTestUrl, bind(&OpenSettingsUI::AtcTestUrl));
  Register(kAtcRecentDecisions, bind(&OpenSettingsUI::AtcRecentDecisions));

  Register(kShortcutsList, bind(&OpenSettingsUI::ShortcutsList));
  Register(kShortcutsSet, bind(&OpenSettingsUI::ShortcutsSet));
  Register(kShortcutsClear, bind(&OpenSettingsUI::ShortcutsClear));
  Register(kShortcutsReset, bind(&OpenSettingsUI::ShortcutsReset));
  Register(kShortcutsResetAll, bind(&OpenSettingsUI::ShortcutsResetAll));
  Register(kShortcutsSetPriority, bind(&OpenSettingsUI::ShortcutsSetPriority));
  Register(kShortcutsExportJson, bind(&OpenSettingsUI::ShortcutsExportJson));
  Register(kShortcutsImportJson, bind(&OpenSettingsUI::ShortcutsImportJson));

  Register(kAdBlockGet, bind(&OpenSettingsUI::AdBlockGet));
  Register(kAdBlockUpdateNow, bind(&OpenSettingsUI::AdBlockUpdateNow));
  Register(kAdBlockResetLists, bind(&OpenSettingsUI::AdBlockResetLists));
  Register(kAdBlockSetCustomRules,
           bind(&OpenSettingsUI::AdBlockSetCustomRules));
  Register(kAdBlockCopyDebugInfo, bind(&OpenSettingsUI::AdBlockCopyDebugInfo));
  Register(kAdBlockDetectConflicts,
           bind(&OpenSettingsUI::AdBlockDetectConflicts));

  Register(kExtensionsRemove, bind(&OpenSettingsUI::ExtensionsRemove));
  Register(kExtensionsOpenOptions,
           bind(&OpenSettingsUI::ExtensionsOpenOptions));

  Register(kSyncDetailed, bind(&OpenSettingsUI::SyncDetailed));
  Register(kSyncSignIn, bind(&OpenSettingsUI::SyncSignIn));
  Register(kSyncSignUp, bind(&OpenSettingsUI::SyncSignUp));
  Register(kSyncSignOut, bind(&OpenSettingsUI::SyncSignOut));
  Register(kSyncCompleteInitial, bind(&OpenSettingsUI::SyncCompleteInitial));
  Register(kSyncNowDetailed, bind(&OpenSettingsUI::SyncNowDetailed));
  Register(kSyncChangePassword, bind(&OpenSettingsUI::SyncChangePassword));
  Register(kSyncUpdateDisplayName,
           bind(&OpenSettingsUI::SyncUpdateDisplayName));
  Register(kSyncDeleteAccount, bind(&OpenSettingsUI::SyncDeleteAccount));
  Register(kSyncRevokeDeviceDetailed,
           bind(&OpenSettingsUI::SyncRevokeDeviceDetailed));
  Register(kSyncSetServerUrl, bind(&OpenSettingsUI::SyncSetServerUrl));
  Register(kSyncSetCategory, bind(&OpenSettingsUI::SyncSetCategory));
  Register(kSyncRecoverDetailed, bind(&OpenSettingsUI::SyncRecoverDetailed));

  Register(kSettingsImportDetect, bind(&OpenSettingsUI::ImportDetect));
  Register(kSettingsImportPickHtml, bind(&OpenSettingsUI::ImportPickHtml));
  Register(kSettingsImportRun, bind(&OpenSettingsUI::ImportRun));
  Register(kSettingsImportUndo, bind(&OpenSettingsUI::ImportUndo));
  Register(kSettingsImportReceipts, bind(&OpenSettingsUI::ImportReceipts));

  Register(kAboutGet, bind(&OpenSettingsUI::AboutGet));
  Register(kAboutShowDataFolder, bind(&OpenSettingsUI::AboutShowDataFolder));
  Register(kAboutCopySystemInfo, bind(&OpenSettingsUI::AboutCopySystemInfo));
  Register(kAboutCheckForUpdates,
           bind(&OpenSettingsUI::AboutCheckForUpdates));
  Register(kAboutReplayOnboarding,
           bind(&OpenSettingsUI::AboutReplayOnboarding));
}

namespace {

// Installed extensions of one Profile (bridge.ts ExtensionItem plus
// has_options and is_adblocker).
base::DictValue ExtensionsListValue(const ProfileID& profile_id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  ProfileServices* ps =
      service ? service->ProfileServicesFor(profile_id) : nullptr;
  base::ListValue extensions;
  if (ps && ps->extensions) {
    extensions::ExtensionRegistry* registry =
        ps->chrome_profile ? extensions::ExtensionRegistry::Get(
                                 ps->chrome_profile.get())
                           : nullptr;
    for (const ExtensionActionInfo& info : ps->extensions->ListInstalled()) {
      base::DictValue item = OpenExtensionBridge::ToValue(info);
      const extensions::Extension* extension =
          registry ? registry->GetInstalledExtension(info.id) : nullptr;
      item.Set("has_options",
               extension &&
                   extensions::OptionsPageInfo::HasOptionsPage(extension));
      item.Set("is_adblocker", IsAdBlockExtension(info.name));
      extensions.Append(std::move(item));
    }
  }
  return base::DictValue()
      .Set("profile_id", profile_id)
      .Set("extensions", std::move(extensions));
}

// Applies a keybindings.json document (CommandRegistry::SaveOverrides
// format: {"version": 1, "bindings": {id: {shortcuts, priority}}}). Replaces
// every override; unknown and reserved commands are skipped.
bool ApplyShortcutsDict(const base::DictValue& root,
                        std::string* error,
                        int* applied,
                        int* skipped) {
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    *error = "shutting down";
    return false;
  }
  if (root.FindInt("version").value_or(0) !=
      CommandRegistry::kKeybindingsSchemaVersion) {
    *error = "This is not an Open shortcuts file (unsupported version).";
    return false;
  }
  const base::DictValue* bindings = root.FindDict("bindings");
  if (!bindings) {
    *error = "This is not an Open shortcuts file (no bindings).";
    return false;
  }
  CommandRegistry& registry = service->commands();
  std::vector<std::pair<std::string, KeyBindingOverride>> loaded;
  for (const auto [id, value] : *bindings) {
    const CommandDefinition* def = registry.FindByStringId(id);
    const base::DictValue* binding = value.GetIfDict();
    if (!def || def->is_reserved || !binding) {
      ++*skipped;
      continue;
    }
    KeyBindingOverride override_value;
    if (const base::ListValue* list = binding->FindList("shortcuts")) {
      for (const base::Value& item : *list) {
        const base::DictValue* sd = item.GetIfDict();
        const std::string* key = sd ? sd->FindString("key") : nullptr;
        if (!key || key->empty() || key->size() > 16) {
          continue;
        }
        std::vector<std::string> names;
        if (const base::ListValue* mods = sd->FindList("modifiers")) {
          for (const base::Value& mod : *mods) {
            if (mod.is_string()) {
              names.push_back(mod.GetString());
            }
          }
        }
        KeyboardShortcut shortcut{
            base::ToLowerASCII(*key),
            KeyboardShortcut::ModifiersFromNames(names)};
        override_value.shortcuts.push_back(shortcut.Normalized());
      }
    }
    if (const std::string* priority = binding->FindString("priority")) {
      override_value.priority = ParsePriority(*priority);
    }
    loaded.emplace_back(def->id, std::move(override_value));
  }
  registry.ResetAllOverrides();
  for (auto& [id, override_value] : loaded) {
    if (registry.SetOverride(id, std::move(override_value))) {
      ++*applied;
    } else {
      ++*skipped;
    }
  }
  return true;
}

// The keybindings.json document of the current overrides.
base::DictValue ShortcutsDocument(const CommandRegistry& registry) {
  base::DictValue bindings;
  for (const auto& [id, override_value] : registry.overrides()) {
    base::ListValue shortcuts;
    for (const KeyboardShortcut& shortcut : override_value.shortcuts) {
      base::ListValue mods;
      for (const std::string& name : shortcut.ModifierNames()) {
        mods.Append(name);
      }
      shortcuts.Append(base::DictValue()
                           .Set("key", shortcut.key)
                           .Set("modifiers", std::move(mods)));
    }
    base::DictValue binding;
    binding.Set("shortcuts", std::move(shortcuts));
    if (override_value.priority) {
      binding.Set("priority", PriorityName(*override_value.priority));
    }
    bindings.Set(id, std::move(binding));
  }
  return base::DictValue()
      .Set("version", CommandRegistry::kKeybindingsSchemaVersion)
      .Set("bindings", std::move(bindings));
}

template <typename T>
void AppendAll(std::vector<T>* into, const std::vector<T>& from) {
  into->insert(into->end(), from.begin(), from.end());
}

void MergeReceipt(ImportReceipt* into, const ImportReceipt& from) {
  AppendAll(&into->created_profile_ids, from.created_profile_ids);
  AppendAll(&into->created_space_ids, from.created_space_ids);
  AppendAll(&into->created_node_ids, from.created_node_ids);
  AppendAll(&into->created_favorite_ids, from.created_favorite_ids);
  AppendAll(&into->created_easel_ids, from.created_easel_ids);
  AppendAll(&into->created_note_ids, from.created_note_ids);
  AppendAll(&into->history_profile_ids, from.history_profile_ids);
  for (const auto& [pid, ids] : from.created_boost_ids) {
    AppendAll(&into->created_boost_ids[pid], ids);
  }
  for (const auto& [pid, ids] : from.created_archive_ids) {
    AppendAll(&into->created_archive_ids[pid], ids);
  }
  into->preferences_modified |= from.preferences_modified;
  into->keybindings_modified |= from.keybindings_modified;
  into->routing_rules_modified |= from.routing_rules_modified;
}

// Swift Open (legacy) UserDefaults keys -> open://settings keys.
constexpr std::pair<const char*, const char*> kLegacyPreferenceKeys[] = {
    {"open.general.warnBeforeQuitting", "general.warnBeforeQuitting"},
    {"open.advanced.restoreWindowsOnLaunch", "general.restoreWindows"},
    {"open.general.automaticallyUpdate", "general.automaticUpdates"},
    {"open.advanced.showFullURLWithToolbar", "appearance.fullUrl"},
    {"open.general.previewsEnabled", "previews.enabled"},
    {"open.general.previewsFolders", "previews.folders"},
    {"open.general.previewsPages", "previews.pages"},
    {"open.general.previewsRecents", "previews.recents"},
    {"open.general.previewsCalendar", "previews.calendar"},
    {"open.general.previewsGmail", "previews.gmail"},
    {"open.links.optionCommandClickLittleOpen", "links.optionCommandClick"},
    {"open.links.externalInLittleOpen", "links.externalLinksLittleOpen"},
    {"open.links.openPeekShiftClick", "links.peekShiftClick"},
    {"open.links.openPeekOtherSites", "links.peekOtherSites"},
    {"open.shortcuts.includeFavoritesInTabNumbering",
     "tabs.includeFavoritesInSwitcher"},
    {"open.shortcuts.switchToNinthEnabled", "tabs.ninthTabGoesToLast"},
    {"open.advanced.playSoundEffects", "advanced.soundEffects"},
    {"open.advanced.hapticOnTabReorder", "advanced.haptics"},
    {"open.advanced.allowWindowDraggingFromWebTop", "advanced.windowDragging"},
    {"open.advanced.enableSharedQuotes", "advanced.sharedQuotes"},
    {"open.advanced.enablePictureInPictureOnLeave",
     "advanced.pictureInPicture"},
    {"open.advanced.allowSitesThemeData", "advanced.themeData"},
    {"open.advanced.enableBoosts", "advanced.enableBoosts"},
    {"open.advanced.enableWidevine", "advanced.widevine"},
};

// Writes |json| to |path| atomically (blocking).
bool WriteJsonFileBlocking(const base::FilePath& path,
                           const std::string& json) {
  if (!base::CreateDirectory(path.DirName())) {
    return false;
  }
  const base::FilePath temp = path.AddExtensionASCII("tmp");
  return base::WriteFile(temp, json) && base::ReplaceFile(temp, path, nullptr);
}

base::FilePath ExpandHome(const std::string& raw) {
  if (raw.empty()) {
    return base::FilePath();
  }
  if (raw == "~" || base::StartsWith(raw, "~/") ||
      base::StartsWith(raw, "~\\")) {
    base::FilePath home;
    if (base::PathService::Get(base::DIR_HOME, &home) && !home.empty()) {
      return raw.size() > 2
                 ? home.Append(base::FilePath::FromUTF8Unsafe(raw.substr(2)))
                 : home;
    }
    return base::GetHomeDir().AppendASCII(raw.size() > 2 ? raw.substr(2)
                                                         : std::string());
  }
  return base::FilePath::FromUTF8Unsafe(raw);
}

std::string TodayStamp() {
  base::Time::Exploded now;
  base::Time::Now().LocalExplode(&now);
  return base::StringPrintf("%04d-%02d-%02d", now.year, now.month,
                            now.day_of_month);
}

}  // namespace

// static
std::string OpenPreferences::TranslateLegacyKey(std::string_view key) {
  for (const auto& [legacy_key, mapped_key] : kLegacyPreferenceKeys) {
    if (key == legacy_key) {
      return mapped_key;
    }
  }
  return std::string(key);
}

// --- Preferences -------------------------------------------------------------

void OpenSettingsUI::GetAll(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  OpenPreferences::Get()->WhenLoaded(base::BindOnce(
      [](base::WeakPtr<OpenSettingsUI> self, ProfileID profile, Reply reply) {
        if (!self) {
          return;
        }
        OpenPreferences* prefs = OpenPreferences::Get();
        OpenPlatform* platform = OpenPlatform::Get();
        ReplyOk(std::move(reply),
                base::DictValue()
                    .Set("preferences", prefs->Values(profile))
                    .Set("defaults", OpenPreferences::Defaults().Clone())
                    .Set("is_default_browser",
                         platform && platform->IsDefaultBrowser())
                    .Set("app_version", OpenVersion())
                    .Set("chromium_version", version_info::GetVersionNumber())
                    .Set("active_profile_id", profile)
                    .Set("theme", self->ThemeValue()));
      },
      weak_factory_.GetWeakPtr(), profile, std::move(reply)));
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

// --- Window, theme, navigation, files ----------------------------------------

WindowID OpenSettingsUI::HostWindowId() const {
  OpenBrowserService* s = service();
  if (!s) {
    return WindowID();
  }
  // The page is in front while the user works in it.
  const WindowID active = s->ActiveWindowId();
  return active.empty() ? s->MainWindowId() : active;
}

base::DictValue OpenSettingsUI::ThemeValue() const {
  const std::string preference = StringPref("appearance.websiteAppearance");
  const bool dark =
      preference == "dark" || (preference != "light" && SystemIsDark());
  // Card surfaces of the Settings page (docs/settings reference frames).
  const RGBAColor surface = dark ? RGBAColor{0.114, 0.114, 0.149, 1.0}
                                 : RGBAColor{1.0, 1.0, 1.0, 1.0};
  // Open's own accent when no Space is focused (#5b5bcf / #8a8aee).
  RGBAColor key = dark ? RGBAColor{0.541, 0.541, 0.933, 1.0}
                       : RGBAColor{0.357, 0.357, 0.812, 1.0};
  base::DictValue d;
  OpenBrowserService* s = service();
  if (s) {
    const WindowID window_id = HostWindowId();
    for (const BrowserWindowState& window : s->model().windows()) {
      if (window.id != window_id) {
        continue;
      }
      if (const Space* space = s->model().FindSpace(window.focused_space_id)) {
        const SpaceStyle style = space->theme.style.value_or(SpaceStyle());
        key = space->theme.accent.value_or(style.key_color);
        d.Set("space_id", space->id);
        d.Set("space_title", s->model().DisplayTitleForSpace(space->id));
      }
    }
  }
  const RGBAColor accent = AccessibleAccent(key, surface, dark);
  const RGBAColor white{1, 1, 1, 1};
  const RGBAColor ink{0.08, 0.08, 0.11, 1};
  const RGBAColor on_accent =
      Contrast(white, accent) >= Contrast(ink, accent) ? white : ink;
  d.Set("mode", dark ? "dark" : "light");
  d.Set("preference", preference);
  d.Set("accent", CssColor(accent));
  d.Set("accent_hover",
        CssColor(MixColor(accent, dark ? white : RGBAColor{0, 0, 0, 1}, 0.12)));
  d.Set("accent_soft", CssRgba(accent, dark ? 0.24 : 0.14));
  d.Set("on_accent", CssColor(on_accent));
  d.Set("space_bg", CssRgba(key, dark ? 0.16 : 0.10));
  d.Set("contrast", std::round(Contrast(accent, surface) * 100) / 100);
  return d;
}

void OpenSettingsUI::GetTheme(const base::DictValue& payload, Reply reply) {
  ReplyOk(std::move(reply), ThemeValue());
}

bool OpenSettingsUI::OpenInBrowser(const GURL& url) {
  OpenBrowserService* s = service();
  OpenTabBridge* bridge = s ? s->tab_bridge() : nullptr;
  if (!bridge || !url.is_valid()) {
    return false;
  }
  // A standalone Settings window is not a standard browser window of the
  // model: pages it opens go to the main window, which comes to the front.
  WindowID window = s->ActiveWindowId();
  bool standard = false;
  for (const BrowserWindowState& state : s->model().windows()) {
    if (state.id == window && state.style == WindowStyle::kStandard &&
        !state.is_incognito) {
      standard = true;
    }
  }
  if (!standard) {
    window = s->MainWindowId();
  }
  const ItemID tab = window.empty()
                         ? bridge->OpenTab(url, /*background=*/false)
                         : bridge->OpenTab(url, /*background=*/false, window);
  if (!window.empty()) {
    if (BrowserWindowInterface* browser = bridge->BrowserForWindow(window)) {
      if (ui::BaseWindow* base_window = browser->GetWindow()) {
        base_window->Activate();
      }
    }
  }
  return !tab.empty();
}

void OpenSettingsUI::OpenChromeUrl(const base::DictValue& payload,
                                   Reply reply) {
  const GURL url(json::GetString(payload, "url"));
  bool allowed = false;
  if (url.is_valid() && url.SchemeIs("chrome")) {
    for (const char* host : {"settings", "password-manager", "extensions",
                             "history", "downloads", "credits"}) {
      allowed |= url.host() == host;
    }
  } else if (url.is_valid() && url.SchemeIs("https")) {
    allowed = url.host() == "chromewebstore.google.com";
  }
  if (!allowed) {
    ReplyError(std::move(reply), "that page cannot be opened from Settings");
    return;
  }
  ReplyOk(std::move(reply), base::DictValue().Set("ok", OpenInBrowser(url)));
}

void OpenSettingsUI::RunFileDialog(
    int type,
    const std::u16string& title,
    const base::FilePath& default_path,
    const std::vector<std::string>& extensions,
    base::OnceCallback<void(std::optional<base::FilePath>)> done) {
  content::WebContents* contents =
      web_ui() ? web_ui()->GetWebContents() : nullptr;
  if (file_dialog_ || !contents) {
    std::move(done).Run(std::nullopt);
    return;
  }
  file_dialog_ = std::make_unique<FileDialog>(
      base::BindOnce(&OpenSettingsUI::OnFileDialogDone,
                     weak_factory_.GetWeakPtr(), std::move(done)));
  file_dialog_->Show(static_cast<ui::SelectFileDialog::Type>(type), title,
                     default_path, extensions,
                     contents->GetTopLevelNativeWindow());
}

void OpenSettingsUI::OnFileDialogDone(
    base::OnceCallback<void(std::optional<base::FilePath>)> done,
    std::optional<base::FilePath> path) {
  // The listener is still on the stack: delete it after this task.
  if (file_dialog_) {
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(file_dialog_));
  }
  std::move(done).Run(std::move(path));
}

void OpenSettingsUI::PickFolder(const base::DictValue& payload, Reply reply) {
  const std::string title = json::GetString(payload, "title", "Choose Folder");
  RunFileDialog(
      ui::SelectFileDialog::SELECT_FOLDER, base::UTF8ToUTF16(title),
      ExpandHome(json::GetString(payload, "default_path")), {},
      base::BindOnce(
          [](Reply reply, std::optional<base::FilePath> path) {
            base::DictValue d;
            d.Set("canceled", !path.has_value());
            if (path) {
              d.Set("path", path->AsUTF8Unsafe());
            }
            ReplyOk(std::move(reply), std::move(d));
          },
          std::move(reply)));
}

void OpenSettingsUI::PickDownloadFolder(const base::DictValue& payload,
                                        Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  const Profile* p = service()->model().FindProfile(profile);
  const std::string current = DisplayDownloadDirectory(
      p ? p->settings.download_directory : std::string("~/Downloads"));
  RunFileDialog(
      ui::SelectFileDialog::SELECT_FOLDER, u"Choose Download Folder",
      ExpandHome(current), {},
      base::BindOnce(
          [](ProfileID profile, Reply reply,
             std::optional<base::FilePath> path) {
            OpenPreferences* prefs = OpenPreferences::Get();
            if (!path) {
              ReplyOk(std::move(reply),
                      base::DictValue()
                          .Set("canceled", true)
                          .Set("preferences", prefs->Values(profile)));
              return;
            }
            std::string error;
            if (!prefs->Set("downloads.location",
                            base::Value(path->AsUTF8Unsafe()), profile,
                            /*all_profiles=*/false, &error)) {
              ReplyError(std::move(reply), error);
              return;
            }
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("canceled", false)
                        .Set("path", path->AsUTF8Unsafe())
                        .Set("preferences", prefs->Values(profile)));
          },
          profile, std::move(reply)));
}

void OpenSettingsUI::ExportSnapshot(const base::DictValue& payload,
                                    Reply reply) {
  OpenBrowserService* s = service();
  const BrowserModel& model = s->model();
  base::ListValue profiles;
  for (const Profile& profile : model.profiles()) {
    base::DictValue summary = ProfileSummary(profile.id);
    base::ListValue favorites;
    for (const Tab& tab : profile.favorites) {
      favorites.Append(json::TabToValue(tab));
    }
    summary.Set("favorites", std::move(favorites));
    profiles.Append(std::move(summary));
  }
  base::ListValue spaces;
  for (const Space& space : model.spaces()) {
    base::DictValue item = OpenLibraryUI::SpaceSummary(space);
    item.Set("theme", json::SpaceThemeToValue(space.theme));
    base::ListValue pinned;
    for (const SidebarNode& node : space.pinned) {
      pinned.Append(json::SidebarNodeToValue(node));
    }
    base::ListValue today;
    for (const SidebarNode& node : space.today) {
      today.Append(json::SidebarNodeToValue(node));
    }
    item.Set("pinned", std::move(pinned));
    item.Set("today", std::move(today));
    spaces.Append(std::move(item));
  }
  base::DictValue snapshot;
  snapshot.Set("format", "open-unified-snapshot");
  snapshot.Set("format_version", 1);
  snapshot.Set("exported_at", base::Time::Now().InSecondsFSinceUnixEpoch());
  snapshot.Set("app_version", OpenVersion());
  snapshot.Set("chromium_version", version_info::GetVersionNumber());
  snapshot.Set("profiles", std::move(profiles));
  snapshot.Set("spaces", std::move(spaces));
  snapshot.Set("preferences", OpenPreferences::Get()->stored().Clone());
  snapshot.Set("shortcuts", ShortcutsDocument(s->commands()));
  snapshot.Set("routing", RoutingValue());
  std::optional<std::string> json = base::WriteJsonWithOptions(
      snapshot, base::JSONWriter::OPTIONS_PRETTY_PRINT);
  if (!json) {
    ReplyError(std::move(reply), "the snapshot could not be written");
    return;
  }
  const base::FilePath default_path =
      DownloadPrefs::GetDefaultDownloadDirectory().AppendASCII(
          "Open-Snapshot-" + TodayStamp() + ".json");
  auto write = base::BindOnce(
      [](std::string json, Reply reply, base::FilePath path) {
        base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
            base::BindOnce(&WriteJsonFileBlocking, path, json),
            base::BindOnce(
                [](Reply reply, base::FilePath path, bool ok) {
                  if (!ok) {
                    ReplyError(std::move(reply),
                               "Open could not write " + path.AsUTF8Unsafe());
                    return;
                  }
                  ReplyOk(std::move(reply),
                          base::DictValue()
                              .Set("ok", true)
                              .Set("path", path.AsUTF8Unsafe()));
                },
                std::move(reply), path));
      },
      std::move(*json));
  if (json::GetBool(payload, "to_downloads", false)) {
    std::move(write).Run(std::move(reply), default_path);
    return;
  }
  RunFileDialog(
      ui::SelectFileDialog::SELECT_SAVEAS_FILE, u"Export Open Data",
      default_path, {"json"},
      base::BindOnce(
          [](base::OnceCallback<void(Reply, base::FilePath)> write,
             Reply reply, std::optional<base::FilePath> path) {
            if (!path) {
              ReplyOk(std::move(reply), base::DictValue()
                                            .Set("ok", false)
                                            .Set("canceled", true));
              return;
            }
            std::move(write).Run(std::move(reply), *path);
          },
          std::move(write), std::move(reply)));
}

// --- Profiles ----------------------------------------------------------------

// static
base::DictValue OpenSettingsUI::ProfileSummary(const ProfileID& profile_id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    return base::DictValue();  // During shutdown.
  }
  const BrowserModel& model = service->model();
  const Profile* profile = model.FindProfile(profile_id);
  if (!profile) {
    return base::DictValue();
  }
  const int space_count = static_cast<int>(std::count_if(
      model.spaces().begin(), model.spaces().end(),
      [&](const Space& space) { return space.profile_id == profile_id; }));
  const SpaceIcon icon =
      profile->icon.value_or(SpaceIcon{SpaceIconKind::kNamed, "person"});
  base::DictValue settings = json::ProfileSettingsToValue(profile->settings);
  if (const std::string* dir = settings.FindString("download_directory")) {
    settings.Set("download_directory", DisplayDownloadDirectory(*dir));
  }
  return base::DictValue()
      .Set("id", profile->id)
      .Set("name", profile->name)
      .Set("icon", json::SpaceIconToValue(icon))
      .Set("data_directory_name", profile->data_directory_name)
      .Set("is_default", !model.profiles().empty() &&
                             model.profiles().front().id == profile->id)
      .Set("space_count", space_count)
      .Set("favorites_count", static_cast<int>(profile->favorites.size()))
      .Set("settings", std::move(settings));
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

void OpenSettingsUI::ProfilesList(const base::DictValue& payload,
                                  Reply reply) {
  base::ListValue profiles;
  for (const Profile& profile : service()->model().profiles()) {
    profiles.Append(ProfileSummary(profile.id));
  }
  ReplyOk(std::move(reply),
          base::DictValue()
              .Set("profiles", std::move(profiles))
              .Set("active_profile_id", service()->ActiveProfileId())
              .Set("page_profile_id", profile_id()));
}

void OpenSettingsUI::ProfilesSwitch(const base::DictValue& payload,
                                    Reply reply) {
  const ProfileID id = json::GetString(payload, "profile_id");
  if (!service()->model().FindProfile(id)) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  OpenPreferences::Get()->WhenLoaded(base::BindOnce(
      [](ProfileID id, Reply reply) {
        ReplyOk(std::move(reply),
                base::DictValue()
                    .Set("profile_id", id)
                    .Set("profile", ProfileSummary(id))
                    .Set("preferences", OpenPreferences::Get()->Values(id))
                    .Set("adblock", AdBlockState(id))
                    .Set("extensions", ExtensionsListValue(id)
                                           .Extract("extensions")
                                           .value_or(base::Value(
                                               base::ListValue()))));
      },
      id, std::move(reply)));
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

void OpenSettingsUI::ProfilesCreate(const base::DictValue& payload,
                                    Reply reply) {
  CreateProfile(payload, std::move(reply));
}

void OpenSettingsUI::RenameProfile(const base::DictValue& payload,
                                   Reply reply) {
  const std::string id = json::GetString(payload, "profile_id");
  const std::string name = std::string(base::TrimWhitespaceASCII(
      json::GetString(payload, "name"), base::TRIM_ALL));
  const Profile* existing = service()->model().FindProfile(id);
  const bool same_name = existing && existing->name == name;
  if (name.empty() || name.size() > 64 ||
      (!same_name &&
       (service()->model().ValidateProfileName(name, id) !=
            ProfileNameIssue::kNone ||
        !service()->model().RenameProfile(id, name)))) {
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

void OpenSettingsUI::ProfilesRename(const base::DictValue& payload,
                                    Reply reply) {
  RenameProfile(payload, std::move(reply));
}

void OpenSettingsUI::ProfilesSetIcon(const base::DictValue& payload,
                                     Reply reply) {
  const std::string id = json::GetString(payload, "profile_id");
  std::optional<SpaceIcon> icon =
      json::SpaceIconFromValue(payload.Find("icon"));
  if (!icon || !service()->model().SetProfileIcon(id, std::move(icon))) {
    ReplyError(std::move(reply), "cannot change the profile icon");
    return;
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("profile", ProfileSummary(id)));
}

void OpenSettingsUI::ProfilesSetSearchEngine(const base::DictValue& payload,
                                             Reply reply) {
  const ProfileID id = json::GetString(payload, "profile_id");
  const std::string engine = json::GetString(payload, "engine_id");
  const Profile* profile = service()->model().FindProfile(id);
  if (!profile) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  bool known = IsBuiltinEngine(engine);
  for (const CustomSearchEngine& custom :
       profile->settings.custom_search_engines) {
    known |= custom.id == engine;
  }
  if (!known) {
    ReplyError(std::move(reply), "unknown search engine");
    return;
  }
  ProfileSettings settings = profile->settings;
  settings.search_engine_id = engine;
  service()->model().UpdateProfileSettings(id, settings);
  ReplyOk(std::move(reply),
          base::DictValue().Set("profile", ProfileSummary(id)));
}

void OpenSettingsUI::ProfilesSetCustomSearchEngines(
    const base::DictValue& payload,
    Reply reply) {
  const ProfileID id = json::GetString(payload, "profile_id");
  const Profile* profile = service()->model().FindProfile(id);
  const base::ListValue* list = payload.FindList("engines");
  if (!profile || !list || list->size() > kMaxCustomSearchEngines) {
    ReplyError(std::move(reply), "invalid search engines");
    return;
  }
  std::vector<CustomSearchEngine> engines;
  std::set<std::string> keywords;
  for (const base::Value& item : *list) {
    const base::DictValue* d = item.GetIfDict();
    if (!d) {
      ReplyError(std::move(reply), "invalid search engine");
      return;
    }
    CustomSearchEngine engine;
    engine.id = json::GetString(*d, "id");
    engine.name = std::string(
        base::TrimWhitespaceASCII(json::GetString(*d, "name"), base::TRIM_ALL));
    engine.keyword = base::ToLowerASCII(base::TrimWhitespaceASCII(
        json::GetString(*d, "keyword"), base::TRIM_ALL));
    engine.url_template = std::string(base::TrimWhitespaceASCII(
        json::GetString(*d, "url_template"), base::TRIM_ALL));
    const GURL url(engine.url_template);
    if (engine.name.empty() || engine.name.size() > 64 ||
        engine.keyword.empty() || engine.keyword.size() > 32 ||
        engine.keyword.find(' ') != std::string::npos ||
        engine.url_template.find("%s") == std::string::npos ||
        !url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
      ReplyError(std::move(reply),
                 "Each engine needs a name, a one-word keyword, and an "
                 "http(s) URL with %s where the search goes.");
      return;
    }
    if (!keywords.insert(engine.keyword).second) {
      ReplyError(std::move(reply),
                 "The keyword \"" + engine.keyword + "\" is used twice.");
      return;
    }
    if (engine.id.empty() || engine.id.size() > 64 ||
        IsBuiltinEngine(engine.id)) {
      engine.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
    }
    engines.push_back(std::move(engine));
  }
  ProfileSettings settings = profile->settings;
  settings.custom_search_engines = std::move(engines);
  if (!IsBuiltinEngine(settings.search_engine_id) &&
      std::none_of(settings.custom_search_engines.begin(),
                   settings.custom_search_engines.end(),
                   [&](const CustomSearchEngine& e) {
                     return e.id == settings.search_engine_id;
                   })) {
    settings.search_engine_id = "google";
  }
  service()->model().UpdateProfileSettings(id, settings);
  ReplyOk(std::move(reply),
          base::DictValue().Set("profile", ProfileSummary(id)));
}

void OpenSettingsUI::DeleteProfile(const base::DictValue& payload,
                                   Reply reply) {
  ProfilesDelete(payload, std::move(reply));
}

void OpenSettingsUI::ProfilesDelete(const base::DictValue& payload,
                                    Reply reply) {
  const std::string id = json::GetString(payload, "profile_id");
  BrowserModel& model = service()->model();
  const Profile* profile = model.FindProfile(id);
  if (!profile) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  // Typed confirmation (the page asks for the Profile's name).
  if (json::GetString(payload, "confirm_name") != profile->name) {
    ReplyError(std::move(reply), "the confirmation does not match the name");
    return;
  }
  if (!model.profiles().empty() && model.profiles().front().id == id) {
    ReplyError(std::move(reply), "the default profile cannot be deleted");
    return;
  }
  // Optionally keep the Profile's Spaces by moving them first.
  const ProfileID move_to = json::GetString(payload, "move_spaces_to");
  if (!move_to.empty() && move_to != id && model.FindProfile(move_to)) {
    std::vector<SpaceID> spaces;
    for (const Space& space : model.spaces()) {
      if (space.profile_id == id) {
        spaces.push_back(space.id);
      }
    }
    for (const SpaceID& space : spaces) {
      model.MoveSpaceToProfile(space, move_to);
    }
  }
  switch (model.GetProfileDeleteBlock(id)) {
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
  // Closes the Profile's tabs, deletes its Chromium Profile and every Open
  // folder of it on disk (crash-safe), then removes it from the model.
  service()->DeleteProfileData(
      id, base::BindOnce(
              [](Reply reply, bool ok) {
                if (!ok) {
                  ReplyError(std::move(reply),
                             "the profile could not be deleted");
                  return;
                }
                ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
              },
              std::move(reply)));
}

void OpenSettingsUI::ProfilesCleanupUnused(const base::DictValue& payload,
                                           Reply reply) {
  const bool dry_run = json::GetBool(payload, "dry_run", true);
  BrowserModel& model = service()->model();
  base::ListValue unused;
  std::vector<ProfileID> unused_ids;
  std::set<std::string> known_dirs;
  for (const Profile& profile : model.profiles()) {
    known_dirs.insert(profile.data_directory_name);
    const bool is_default = model.profiles().front().id == profile.id;
    const bool has_spaces =
        std::any_of(model.spaces().begin(), model.spaces().end(),
                    [&](const Space& s) { return s.profile_id == profile.id; });
    if (!is_default && !has_spaces) {
      unused_ids.push_back(profile.id);
      unused.Append(
          base::DictValue().Set("id", profile.id).Set("name", profile.name));
    }
  }
  const base::FilePath profiles_dir =
      service()->user_data_dir().AppendASCII("Profiles");
  if (!dry_run) {
    for (const ProfileID& id : unused_ids) {
      service()->DeleteProfileData(id);
    }
  }
  // Open folders under <user data>/Profiles that no Profile owns (a Profile
  // whose creation never finished). Listed on a dry run, deleted otherwise.
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(
          [](base::FilePath root, std::set<std::string> known, bool remove) {
            base::ListValue orphans;
            base::FileEnumerator it(root, /*recursive=*/false,
                                    base::FileEnumerator::DIRECTORIES);
            for (base::FilePath dir = it.Next(); !dir.empty();
                 dir = it.Next()) {
              const std::string name = dir.BaseName().AsUTF8Unsafe();
              if (known.contains(name) || name.empty() || name[0] == '.') {
                continue;
              }
              if (remove) {
                base::DeletePathRecursively(dir);
              }
              orphans.Append(name);
            }
            return orphans;
          },
          profiles_dir, std::move(known_dirs), !dry_run),
      base::BindOnce(
          [](Reply reply, base::ListValue unused, bool dry_run,
             base::ListValue orphans) {
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("profiles", std::move(unused))
                        .Set("orphan_directories", std::move(orphans))
                        .Set("deleted", !dry_run));
          },
          std::move(reply), std::move(unused), dry_run));
}

// --- Spaces ------------------------------------------------------------------

void OpenSettingsUI::SpacesList(const base::DictValue& payload, Reply reply) {
  const BrowserModel& model = service()->model();
  const bool dark = ThemeValue().FindString("mode") &&
                    *ThemeValue().FindString("mode") == "dark";
  base::ListValue spaces;
  for (const Space& space : model.spaces()) {
    base::DictValue item = OpenLibraryUI::SpaceSummary(space);
    base::DictValue palette = OpenLibraryUI::SpaceThemePayload(space, dark);
    item.Set("accent", json::GetString(palette, "accent"));
    item.Set("bg", json::GetString(palette, "bg"));
    item.Set("display_title", model.DisplayTitleForSpace(space.id));
    spaces.Append(std::move(item));
  }
  ReplyOk(std::move(reply), base::DictValue().Set("spaces", std::move(spaces)));
}

void OpenSettingsUI::SpacesCreate(const base::DictValue& payload,
                                  Reply reply) {
  const ProfileID profile = json::GetString(payload, "profile_id");
  const std::string title = std::string(base::TrimWhitespaceASCII(
      json::GetString(payload, "title"), base::TRIM_ALL));
  if (!service()->model().FindProfile(profile) || title.size() > 64) {
    ReplyError(std::move(reply), "cannot create that space");
    return;
  }
  const SpaceID id = service()->model().CreateSpace(
      profile, title.empty() ? std::nullopt : std::optional<std::string>(title));
  if (id.empty()) {
    ReplyError(std::move(reply), "the space could not be created");
    return;
  }
  SpacesList(payload, std::move(reply));
}

void OpenSettingsUI::SpacesRename(const base::DictValue& payload,
                                  Reply reply) {
  const SpaceID id = json::GetString(payload, "space_id");
  const std::string title = std::string(base::TrimWhitespaceASCII(
      json::GetString(payload, "title"), base::TRIM_ALL));
  if (title.empty() || title.size() > 64 ||
      !service()->model().UpdateSpace(id, title)) {
    ReplyError(std::move(reply), "cannot rename that space");
    return;
  }
  SpacesList(payload, std::move(reply));
}

void OpenSettingsUI::SpacesSetProfile(const base::DictValue& payload,
                                      Reply reply) {
  const SpaceID id = json::GetString(payload, "space_id");
  const ProfileID profile = json::GetString(payload, "profile_id");
  if (!service()->model().FindProfile(profile) ||
      !service()->model().MoveSpaceToProfile(id, profile)) {
    ReplyError(std::move(reply), "cannot move that space");
    return;
  }
  SpacesList(payload, std::move(reply));
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
    if (command.is_reserved) {
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

base::DictValue OpenSettingsUI::ShortcutsDetailedValue() const {
  CommandRegistry& registry = service()->commands();
  std::map<std::string, std::string> conflicts;
  for (const ShortcutConflict& conflict : registry.DetectConflicts()) {
    if (conflict.command_ids.size() < 2 || conflict.is_known_arc_duplicate) {
      continue;
    }
    for (const std::string& id : conflict.command_ids) {
      for (const std::string& other : conflict.command_ids) {
        if (other != id) {
          conflicts[id] = other;
        }
      }
    }
  }
  int modified = 0;
  int unassigned = 0;
  int conflict_count = 0;
  base::ListValue shortcuts;
  for (const CommandDefinition& command : registry.all_commands()) {
    if (command.is_reserved) {
      continue;
    }
    const std::vector<KeyboardShortcut> keys =
        registry.EffectiveShortcuts(command.id);
    base::ListValue all_keys;
    for (const KeyboardShortcut& key : keys) {
      all_keys.Append(FormatShortcut(key));
    }
    base::ListValue aliases;
    for (const std::string& alias : command.aliases) {
      aliases.Append(alias);
    }
    const bool is_modified = registry.overrides().contains(command.id);
    modified += is_modified;
    unassigned += keys.empty();
    base::DictValue d;
    d.Set("id", command.id);
    d.Set("title", command.title);
    d.Set("menu_title", command.menu_title);
    d.Set("category", ShortcutCategory(command));
    d.Set("menu", base::JoinString(command.menu_path, " > "));
    d.Set("keys", keys.empty() ? std::string() : FormatShortcut(keys.front()));
    d.Set("all_keys", std::move(all_keys));
    d.Set("default_keys", command.default_shortcuts.empty()
                              ? std::string()
                              : FormatShortcut(command.default_shortcuts[0]));
    d.Set("modified", is_modified);
    d.Set("customizable", command.is_customizable);
    d.Set("global", command.scope == CommandScope::kGlobal);
    d.Set("priority", PriorityName(registry.EffectivePriority(command.id)));
    d.Set("default_priority", PriorityName(command.default_priority));
    d.Set("aliases", std::move(aliases));
    if (auto it = conflicts.find(command.id); it != conflicts.end()) {
      d.Set("conflict_with", it->second);
      ++conflict_count;
    }
    shortcuts.Append(std::move(d));
  }
  const std::string priority = StringPref("shortcuts.priority");
  return base::DictValue()
      .Set("shortcuts", std::move(shortcuts))
      .Set("priority", priority.empty() ? std::string("open") : priority)
      .Set("counts", base::DictValue()
                         .Set("modified", modified)
                         .Set("unassigned", unassigned)
                         .Set("conflicts", conflict_count));
}

void OpenSettingsUI::AfterShortcutChange(const std::string& id) {
  service()->PersistShortcuts();
  // The Little Open hotkey is registered with the OS, not the window.
  if (id.empty() || id == "little-open-global") {
    service()->ReloadGlobalHotkeys();
  }
}

void OpenSettingsUI::GetShortcuts(const base::DictValue& payload,
                                  Reply reply) {
  ReplyOk(std::move(reply), ShortcutsValue());
}

void OpenSettingsUI::SetShortcutAndReply(const std::string& id,
                                         const std::string& keys,
                                         Reply reply) {
  CommandRegistry& registry = service()->commands();
  const CommandDefinition* def = registry.FindByStringId(id);
  if (!def || def->is_reserved || keys.size() > 64) {
    ReplyError(std::move(reply), "unknown command or shortcut");
    return;
  }
  if (keys.empty()) {
    // Unassign: an override with no shortcuts (not the default's).
    if (!registry.ClearBinding(def->id)) {
      ReplyError(std::move(reply), "that shortcut cannot be cleared");
      return;
    }
  } else {
    std::optional<KeyboardShortcut> shortcut = ParseShortcut(keys);
    if (!shortcut) {
      ReplyError(std::move(reply), "unknown command or shortcut");
      return;
    }
    KeyBindingOverride binding;
    if (auto it = registry.overrides().find(def->id);
        it != registry.overrides().end()) {
      binding.priority = it->second.priority;
    }
    binding.shortcuts.push_back(*shortcut);
    if (!registry.SetOverride(def->id, std::move(binding))) {
      ReplyError(std::move(reply), "that shortcut is reserved by the system");
      return;
    }
  }
  AfterShortcutChange(def->id);
  base::DictValue result = ShortcutsDetailedValue();
  for (const ShortcutConflict& conflict : registry.DetectConflicts()) {
    if (!conflict.is_known_arc_duplicate &&
        std::find(conflict.command_ids.begin(), conflict.command_ids.end(),
                  def->id) != conflict.command_ids.end()) {
      for (const std::string& other : conflict.command_ids) {
        if (other != def->id) {
          result.Set("conflict", other);
        }
      }
    }
  }
  ReplyOk(std::move(reply), std::move(result));
}

void OpenSettingsUI::SetShortcut(const base::DictValue& payload,
                                 Reply reply) {
  SetShortcutAndReply(json::GetString(payload, "id"),
                      json::GetString(payload, "keys"), std::move(reply));
}

void OpenSettingsUI::ResetShortcut(const base::DictValue& payload,
                                   Reply reply) {
  if (json::GetBool(payload, "reset_all", false)) {
    service()->commands().ResetAllOverrides();
    AfterShortcutChange(std::string());
  } else {
    const std::string id = json::GetString(payload, "id");
    service()->commands().ResetOverride(id);
    AfterShortcutChange(id);
  }
  base::DictValue result = ShortcutsValue();
  result.Remove("priority");
  ReplyOk(std::move(reply), std::move(result));
}

void OpenSettingsUI::ShortcutsList(const base::DictValue& payload,
                                   Reply reply) {
  ReplyOk(std::move(reply), ShortcutsDetailedValue());
}

void OpenSettingsUI::ShortcutsSet(const base::DictValue& payload,
                                  Reply reply) {
  SetShortcutAndReply(json::GetString(payload, "id"),
                      json::GetString(payload, "keys"), std::move(reply));
}

void OpenSettingsUI::ShortcutsClear(const base::DictValue& payload,
                                    Reply reply) {
  SetShortcutAndReply(json::GetString(payload, "id"), std::string(),
                      std::move(reply));
}

void OpenSettingsUI::ShortcutsReset(const base::DictValue& payload,
                                    Reply reply) {
  const std::string id = json::GetString(payload, "id");
  if (!service()->commands().FindByStringId(id)) {
    ReplyError(std::move(reply), "unknown command");
    return;
  }
  service()->commands().ResetOverride(id);
  AfterShortcutChange(id);
  ReplyOk(std::move(reply), ShortcutsDetailedValue());
}

void OpenSettingsUI::ShortcutsResetAll(const base::DictValue& payload,
                                       Reply reply) {
  service()->commands().ResetAllOverrides();
  AfterShortcutChange(std::string());
  ReplyOk(std::move(reply), ShortcutsDetailedValue());
}

void OpenSettingsUI::ShortcutsSetPriority(const base::DictValue& payload,
                                          Reply reply) {
  const std::string id = json::GetString(payload, "id");
  const std::string priority = json::GetString(payload, "priority");
  if (id.empty()) {
    // The app-wide choice (When shortcuts overlap): "open" or "website".
    if (priority != "open" && priority != "website") {
      ReplyError(std::move(reply), "unknown priority");
      return;
    }
    OpenPreferences::Get()->WhenLoaded(base::BindOnce(
        [](base::WeakPtr<OpenSettingsUI> self, std::string priority,
           Reply reply) {
          std::string error;
          OpenPreferences::Get()->Set("shortcuts.priority",
                                      base::Value(priority), ProfileID(),
                                      false, &error);
          if (self) {
            ReplyOk(std::move(reply), self->ShortcutsDetailedValue());
          }
        },
        weak_factory_.GetWeakPtr(), priority, std::move(reply)));
    return;
  }
  CommandRegistry& registry = service()->commands();
  const CommandDefinition* def = registry.FindByStringId(id);
  std::optional<ShortcutPriority> parsed = ParsePriority(priority);
  if (!def || def->is_reserved || !parsed) {
    ReplyError(std::move(reply), "unknown command or priority");
    return;
  }
  KeyBindingOverride binding;
  binding.shortcuts = registry.EffectiveShortcuts(def->id);
  binding.priority = parsed;
  if (!registry.SetOverride(def->id, std::move(binding))) {
    ReplyError(std::move(reply), "that priority cannot be set");
    return;
  }
  AfterShortcutChange(def->id);
  ReplyOk(std::move(reply), ShortcutsDetailedValue());
}

void OpenSettingsUI::ShortcutsExportJson(const base::DictValue& payload,
                                         Reply reply) {
  std::optional<std::string> json = base::WriteJsonWithOptions(
      ShortcutsDocument(service()->commands()),
      base::JSONWriter::OPTIONS_PRETTY_PRINT);
  if (!json) {
    ReplyError(std::move(reply), "the shortcuts could not be exported");
    return;
  }
  RunFileDialog(
      ui::SelectFileDialog::SELECT_SAVEAS_FILE, u"Export Shortcuts",
      DownloadPrefs::GetDefaultDownloadDirectory().AppendASCII(
          "Open-Shortcuts.json"),
      {"json"},
      base::BindOnce(
          [](std::string json, Reply reply,
             std::optional<base::FilePath> path) {
            if (!path) {
              ReplyOk(std::move(reply),
                      base::DictValue().Set("ok", false).Set("canceled", true));
              return;
            }
            base::ThreadPool::PostTaskAndReplyWithResult(
                FROM_HERE,
                {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
                base::BindOnce(&WriteJsonFileBlocking, *path, json),
                base::BindOnce(
                    [](Reply reply, base::FilePath path, bool ok) {
                      if (!ok) {
                        ReplyError(std::move(reply),
                                   "Open could not write the file");
                        return;
                      }
                      ReplyOk(std::move(reply),
                              base::DictValue()
                                  .Set("ok", true)
                                  .Set("path", path.AsUTF8Unsafe()));
                    },
                    std::move(reply), *path));
          },
          std::move(*json), std::move(reply)));
}

void OpenSettingsUI::ShortcutsImportJson(const base::DictValue& payload,
                                         Reply reply) {
  auto apply = base::BindOnce(
      [](base::WeakPtr<OpenSettingsUI> self, Reply reply,
         std::optional<std::string> text) {
        if (!self) {
          return;
        }
        if (!text) {
          ReplyOk(std::move(reply),
                  base::DictValue().Set("ok", false).Set("canceled", true));
          return;
        }
        std::optional<base::DictValue> root =
            base::JSONReader::ReadDict(*text, base::JSON_PARSE_RFC);
        std::string error;
        int applied = 0;
        int skipped = 0;
        if (!root) {
          ReplyError(std::move(reply), "That file is not valid JSON.");
          return;
        }
        if (!ApplyShortcutsDict(*root, &error, &applied, &skipped)) {
          ReplyError(std::move(reply), error);
          return;
        }
        self->AfterShortcutChange(std::string());
        base::DictValue result = self->ShortcutsDetailedValue();
        result.Set("ok", true);
        result.Set("applied", applied);
        result.Set("skipped", skipped);
        ReplyOk(std::move(reply), std::move(result));
      },
      weak_factory_.GetWeakPtr(), std::move(reply));
  if (const std::string* text = payload.FindString("json")) {
    if (text->size() > 1024 * 1024) {
      std::move(apply).Run(std::nullopt);
      return;
    }
    std::move(apply).Run(*text);
    return;
  }
  RunFileDialog(
      ui::SelectFileDialog::SELECT_OPEN_FILE, u"Import Shortcuts",
      DownloadPrefs::GetDefaultDownloadDirectory(), {"json"},
      base::BindOnce(
          [](base::OnceCallback<void(std::optional<std::string>)> apply,
             std::optional<base::FilePath> path) {
            if (!path) {
              std::move(apply).Run(std::nullopt);
              return;
            }
            base::ThreadPool::PostTaskAndReplyWithResult(
                FROM_HERE,
                {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
                base::BindOnce(
                    [](base::FilePath path) -> std::optional<std::string> {
                      std::string text;
                      if (!base::ReadFileToStringWithMaxSize(path, &text,
                                                             1024 * 1024)) {
                        return std::string();
                      }
                      return text;
                    },
                    *path),
                std::move(apply));
          },
          std::move(apply)));
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

base::DictValue OpenSettingsUI::AtcValue() const {
  base::DictValue d = RoutingValue();
  const BrowserModel& model = service()->model();
  d.Set("default_destination_label",
        DestinationLabel(model, model.default_destination().kind,
                         model.default_destination().space_id));
  d.Set("external_links_little_open",
        BoolPref("links.externalLinksLittleOpen"));
#if BUILDFLAG(IS_MAC)
  d.Set("source_apps_supported", true);
#else
  d.Set("source_apps_supported", false);
#endif
  return d;
}

void OpenSettingsUI::GetRoutingRules(const base::DictValue& payload,
                                     Reply reply) {
  ReplyOk(std::move(reply), RoutingValue());
}

void OpenSettingsUI::SaveRoutingRule(const base::DictValue& payload,
                                     Reply reply) {
  // A default-destination-only change has no rule.
  std::optional<RoutingDestination> dest =
      json::RoutingDestinationFromValue(payload.Find("default_destination"));
  const base::Value* rule_value = payload.Find("rule");
  const bool has_rule = rule_value && rule_value->is_dict() &&
                        !json::GetString(rule_value->GetDict(), "host_pattern")
                             .empty();
  if (!has_rule) {
    if (!dest) {
      ReplyError(std::move(reply), "invalid routing rule");
      return;
    }
    service()->model().SetDefaultDestination(*dest);
    ReplyOk(std::move(reply), RoutingValue());
    return;
  }
  std::optional<RoutingRule> rule = json::RoutingRuleFromValue(rule_value);
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
  if (dest) {
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
  const RoutingDecision decision = service()->routing().Evaluate(
      request, service()->model(),
      BoolPref("links.externalLinksLittleOpen"));
  base::DictValue d;
  if (decision.matched_rule_id) {
    d.Set("matched_rule_id", *decision.matched_rule_id);
    d.Set("matched_rule_name",
          RuleName(service()->model(), *decision.matched_rule_id));
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

void OpenSettingsUI::AtcGet(const base::DictValue& payload, Reply reply) {
  OpenPreferences::Get()->WhenLoaded(base::BindOnce(
      [](base::WeakPtr<OpenSettingsUI> self, Reply reply) {
        if (self) {
          ReplyOk(std::move(reply), self->AtcValue());
        }
      },
      weak_factory_.GetWeakPtr(), std::move(reply)));
}

void OpenSettingsUI::AtcSetDefaultDestination(const base::DictValue& payload,
                                              Reply reply) {
  std::optional<RoutingDestination> dest =
      json::RoutingDestinationFromValue(payload.Find("destination"));
  if (!dest || (dest->kind == RoutingDestinationKind::kSpace &&
                (!dest->space_id ||
                 !service()->model().FindSpace(*dest->space_id)))) {
    ReplyError(std::move(reply), "choose an existing Space or Little Open");
    return;
  }
  if (dest->profile_id && !service()->model().FindProfile(*dest->profile_id)) {
    dest->profile_id.reset();
  }
  service()->model().SetDefaultDestination(*dest);
  ReplyOk(std::move(reply), AtcValue());
}

namespace {

// Validates a rule from the page: pattern, destination Space and Profile.
std::optional<RoutingRule> ValidatedRule(const BrowserModel& model,
                                         const base::Value* value,
                                         std::string* error) {
  std::optional<RoutingRule> rule = json::RoutingRuleFromValue(value);
  if (!rule) {
    *error = "Enter a site such as github.com, *.google.com or *docs*.";
    return std::nullopt;
  }
  if (rule->path_prefix && !rule->path_prefix->empty() &&
      (*rule->path_prefix)[0] != '/') {
    rule->path_prefix = "/" + *rule->path_prefix;
  }
  if (rule->path_prefix && rule->path_prefix->empty()) {
    rule->path_prefix.reset();
  }
  if (rule->source_app_id && rule->source_app_id->empty()) {
    rule->source_app_id.reset();
  }
  if (rule->destination.kind == RoutingDestinationKind::kSpace &&
      (!rule->destination.space_id ||
       !model.FindSpace(*rule->destination.space_id))) {
    *error = "The destination Space does not exist.";
    return std::nullopt;
  }
  if (rule->destination.profile_id &&
      !model.FindProfile(*rule->destination.profile_id)) {
    *error = "The destination Profile does not exist.";
    return std::nullopt;
  }
  if (rule->name.empty()) {
    rule->name = rule->host_pattern;
  }
  return rule;
}

}  // namespace

void OpenSettingsUI::AtcAddRule(const base::DictValue& payload, Reply reply) {
  std::string error;
  std::optional<RoutingRule> rule =
      ValidatedRule(service()->model(), payload.Find("rule"), &error);
  if (!rule) {
    ReplyError(std::move(reply), error);
    return;
  }
  rule->id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  std::vector<RoutingRule> rules = service()->model().routing_rules();
  if (rules.size() >= 500) {
    ReplyError(std::move(reply), "too many rules");
    return;
  }
  rules.push_back(*rule);
  service()->model().SetRoutingRules(std::move(rules));
  base::DictValue result = AtcValue();
  result.Set("rule_id", rule->id);
  ReplyOk(std::move(reply), std::move(result));
}

void OpenSettingsUI::AtcUpdateRule(const base::DictValue& payload,
                                   Reply reply) {
  std::string error;
  std::optional<RoutingRule> rule =
      ValidatedRule(service()->model(), payload.Find("rule"), &error);
  if (!rule) {
    ReplyError(std::move(reply), error);
    return;
  }
  std::vector<RoutingRule> rules = service()->model().routing_rules();
  auto it = std::find_if(rules.begin(), rules.end(), [&](const RoutingRule& r) {
    return r.id == rule->id;
  });
  if (rule->id.empty() || it == rules.end()) {
    ReplyError(std::move(reply), "no such rule");
    return;
  }
  *it = *rule;
  service()->model().SetRoutingRules(std::move(rules));
  ReplyOk(std::move(reply), AtcValue());
}

void OpenSettingsUI::AtcDeleteRule(const base::DictValue& payload,
                                   Reply reply) {
  const std::string id = json::GetString(payload, "id");
  std::vector<RoutingRule> rules = service()->model().routing_rules();
  const size_t removed =
      std::erase_if(rules, [&](const RoutingRule& r) { return r.id == id; });
  if (!removed) {
    ReplyError(std::move(reply), "no such rule");
    return;
  }
  service()->model().SetRoutingRules(std::move(rules));
  ReplyOk(std::move(reply), AtcValue());
}

void OpenSettingsUI::AtcReorderRules(const base::DictValue& payload,
                                     Reply reply) {
  const base::ListValue* ids = payload.FindList("ids");
  std::vector<RoutingRule> rules = service()->model().routing_rules();
  if (!ids || ids->size() != rules.size()) {
    ReplyError(std::move(reply), "the rule order does not match the rules");
    return;
  }
  std::vector<RoutingRule> ordered;
  for (const base::Value& id : *ids) {
    auto it = std::find_if(rules.begin(), rules.end(), [&](const RoutingRule& r) {
      return id.is_string() && r.id == id.GetString();
    });
    if (it == rules.end() ||
        std::any_of(ordered.begin(), ordered.end(),
                    [&](const RoutingRule& r) { return r.id == it->id; })) {
      ReplyError(std::move(reply), "the rule order does not match the rules");
      return;
    }
    ordered.push_back(*it);
  }
  service()->model().SetRoutingRules(std::move(ordered));
  ReplyOk(std::move(reply), AtcValue());
}

void OpenSettingsUI::AtcListRunningApps(const base::DictValue& payload,
                                        Reply reply) {
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&ListApplicationsBlocking),
      base::BindOnce(
          [](Reply reply, base::ListValue apps) {
#if BUILDFLAG(IS_MAC)
            const bool supported = true;
#else
            const bool supported = false;
#endif
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("apps", std::move(apps))
                                          .Set("supported", supported));
          },
          std::move(reply)));
}

void OpenSettingsUI::AtcTestUrl(const base::DictValue& payload, Reply reply) {
  std::string url = std::string(
      base::TrimWhitespaceASCII(json::GetString(payload, "url"), base::TRIM_ALL));
  if (!url.empty() && url.find("://") == std::string::npos) {
    url = "https://" + url;
  }
  if (!GURL(url).is_valid() || url.size() > 4096) {
    ReplyError(std::move(reply), "Enter a full link, such as https://example.com.");
    return;
  }
  RoutingRequest request;
  request.url = url;
  request.source_app_id = json::FindString(payload, "source_app_id");
  if (request.source_app_id && request.source_app_id->empty()) {
    request.source_app_id.reset();
  }
  request.received_at = base::Time::Now().InSecondsFSinceUnixEpoch();
  const RoutingDecision decision = service()->routing().Evaluate(
      request, service()->model(), BoolPref("links.externalLinksLittleOpen"));
  ReplyOk(std::move(reply), DecisionToValue(service()->model(), decision));
}

void OpenSettingsUI::AtcRecentDecisions(const base::DictValue& payload,
                                        Reply reply) {
  base::ListValue decisions;
  const auto& entries = service()->routing_log().entries();
  for (auto it = entries.rbegin(); it != entries.rend() && decisions.size() < 50;
       ++it) {
    decisions.Append(DecisionToValue(service()->model(), *it));
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("decisions", std::move(decisions)));
}

// --- Ad blocking -------------------------------------------------------------

// static
base::DictValue OpenSettingsUI::AdBlockState(const ProfileID& profile_id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  ProfileServices* ps =
      service ? service->ProfileServicesFor(profile_id) : nullptr;
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
  // The full catalog (Track 3's 46 lists) with this Profile's switches and
  // each list's receipt (bundled or downloaded, rules, time, error).
  base::ListValue lists;
  int64_t newest_ms = 0;
  int active_rules = 0;
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
    const bool enabled =
        std::find(snapshot.enabled_list_ids.begin(),
                  snapshot.enabled_list_ids.end(),
                  info.id) != snapshot.enabled_list_ids.end();
    item.Set("enabled", enabled);
    if (auto it = snapshot.list_receipts.find(info.id);
        it != snapshot.list_receipts.end()) {
      const AdBlockListReceipt& receipt = it->second;
      item.Set("source", receipt.source);
      item.Set("rule_count", receipt.rule_count);
      item.Set("bytes", static_cast<double>(receipt.bytes));
      if (receipt.last_updated_ms > 0) {
        item.Set("last_updated_at",
                 static_cast<double>(receipt.last_updated_ms) / 1000.0);
      }
      if (!receipt.last_error.empty()) {
        item.Set("error", receipt.last_error);
      }
      if (enabled) {
        active_rules += receipt.rule_count;
        newest_ms = std::max(newest_ms, receipt.last_updated_ms);
      }
    }
    lists.Append(std::move(item));
  }
  base::ListValue exclusions;
  for (const std::string& domain : snapshot.excluded_domains) {
    exclusions.Append(domain);
  }
  int blocked = 0;
  if (OpenTabBridge* bridge = service->tab_bridge()) {
    for (const auto& [tab_id, contents] : bridge->LoadedTabs()) {
      if (model_util::ProfileOfNode(service->model(), tab_id) == profile_id) {
        blocked += OpenAdBlockProfileService::GetTotalStoppedCount(contents);
      }
    }
  }
  d.Set("global_enabled", snapshot.enabled);
  d.Set("generation", static_cast<double>(status.generation));
  d.Set("lists", std::move(lists));
  d.Set("exclusions", std::move(exclusions));
  d.Set("blocked_count_session", blocked);
  d.Set("is_updating", snapshot.is_updating);
  d.Set("engine_loaded", status.engine_loaded);
  d.Set("engine_list_count", static_cast<int>(status.list_count));
  d.Set("active_rules", active_rules);
  if (newest_ms > 0) {
    d.Set("last_updated_at", static_cast<double>(newest_ms) / 1000.0);
  }
  d.Set("custom_rules", adblock->GetCustomRules());
  if (!status.last_error.empty()) {
    d.Set("last_error", status.last_error);
  } else if (!snapshot.last_error.empty()) {
    d.Set("last_error", snapshot.last_error);
  }
  return d;
}

void OpenSettingsUI::GetAdBlockState(const base::DictValue& payload,
                                     Reply reply) {
  ReplyOk(std::move(reply), AdBlockState(ProfileFromPayload(payload)));
}

void OpenSettingsUI::AdBlockGet(const base::DictValue& payload, Reply reply) {
  GetAdBlockState(payload, std::move(reply));
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
  base::DictValue state = AdBlockState(ProfileFromPayload(payload));
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
  const std::string raw = json::GetString(payload, "host");
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  // Public Suffix List validation: a registrable domain or an IP address.
  std::optional<std::string> host =
      OpenAdBlockProfileService::NormalizeExclusionDomain(raw);
  if (!host && !excluded && !raw.empty() && raw.size() <= 253) {
    host = raw;  // Removing a stored entry needs no validation.
  }
  if (!adblock || !host) {
    ReplyError(std::move(reply),
               "Enter a site such as example.com (not a public suffix).");
    return;
  }
  if (excluded) {
    adblock->AddExcludedDomain(*host);
  } else {
    adblock->RemoveExcludedDomain(*host);
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

void OpenSettingsUI::AdBlockUpdateNow(const base::DictValue& payload,
                                      Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  if (!adblock) {
    ReplyError(std::move(reply), "Ad blocking is not available here.");
    return;
  }
  // The Profile's default loader factory downloads the lists.
  adblock->UpdateListsNow(
      nullptr,
      base::BindOnce(
          [](base::WeakPtr<OpenSettingsUI> self, ProfileID profile,
             Reply reply, bool ok) {
            base::DictValue state = AdBlockState(profile);
            state.Set("update_ok", ok);
            if (self) {
              self->Emit(kEventAdBlockUpdated, base::Value(state.Clone()));
            }
            ReplyOk(std::move(reply), std::move(state));
          },
          weak_factory_.GetWeakPtr(), profile, std::move(reply)));
}

void OpenSettingsUI::AdBlockResetLists(const base::DictValue& payload,
                                       Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  if (!adblock) {
    ReplyError(std::move(reply), "Ad blocking is not available here.");
    return;
  }
  adblock->ResetLists(base::BindOnce(
      [](base::WeakPtr<OpenSettingsUI> self, ProfileID profile, Reply reply,
         bool ok) {
        base::DictValue state = AdBlockState(profile);
        state.Set("update_ok", ok);
        if (self) {
          self->Emit(kEventAdBlockUpdated, base::Value(state.Clone()));
        }
        ReplyOk(std::move(reply), std::move(state));
      },
      weak_factory_.GetWeakPtr(), profile, std::move(reply)));
}

void OpenSettingsUI::AdBlockSetCustomRules(const base::DictValue& payload,
                                           Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  const std::string rules = json::GetString(payload, "rules");
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  if (!adblock || rules.size() > 256 * 1024) {
    ReplyError(std::move(reply), "custom rules must be under 256 KB");
    return;
  }
  adblock->SetCustomRules(
      rules, base::BindOnce(
                 [](ProfileID profile, Reply reply, bool ok) {
                   base::DictValue state = AdBlockState(profile);
                   state.Set("update_ok", ok);
                   ReplyOk(std::move(reply), std::move(state));
                 },
                 profile, std::move(reply)));
}

void OpenSettingsUI::AdBlockCopyDebugInfo(const base::DictValue& payload,
                                          Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  std::string text = "Open Ad Blocking debug info\n";
  text += "Open " + OpenVersion() + ", Chromium " +
          std::string(version_info::GetVersionNumber()) + "\n";
  if (!adblock) {
    text += "Ad blocking is not available for this Profile.\n";
  } else {
    const AdBlockProfileSnapshot s = adblock->GetSnapshot();
    const open_engine::AdBlockStatus& e = s.engine_status;
    text += base::StringPrintf(
        "Enabled: %s\nUpdating: %s\nEngine loaded: %s (from DAT: %s, "
        "shared: %s)\nGeneration: %lld\nLists in engine: %u\nEngine size: "
        "%llu bytes\nLast build: %lld ms\nDAT policy: %s\nResources: %u (%s)\n",
        s.enabled ? "yes" : "no", s.is_updating ? "yes" : "no",
        e.engine_loaded ? "yes" : "no", e.engine_from_dat ? "yes" : "no",
        e.engine_shared ? "yes" : "no", static_cast<long long>(e.generation),
        e.list_count, static_cast<unsigned long long>(e.dat_size_bytes),
        static_cast<long long>(e.last_build_ms), e.dat_policy.c_str(),
        e.resources_loaded, e.resources_version.c_str());
    text += "Enabled lists:\n";
    for (const std::string& id : s.enabled_list_ids) {
      text += "  " + id;
      if (auto it = s.list_receipts.find(id); it != s.list_receipts.end()) {
        text += base::StringPrintf(
            " [%s, %d rules, %lld bytes, updated %lld%s%s]",
            it->second.source.c_str(), it->second.rule_count,
            static_cast<long long>(it->second.bytes),
            static_cast<long long>(it->second.last_updated_ms),
            it->second.last_error.empty() ? "" : ", error: ",
            it->second.last_error.c_str());
      }
      text += "\n";
    }
    text += base::StringPrintf("Allowed sites: %zu\nCustom rules: %zu bytes\n",
                               s.excluded_domains.size(),
                               adblock->GetCustomRules().size());
    if (!e.last_error.empty()) {
      text += "Engine error: " + e.last_error + "\n";
    }
    if (!s.last_error.empty()) {
      text += "Last error: " + s.last_error + "\n";
    }
  }
  CopyToClipboard(text);
  ReplyOk(std::move(reply),
          base::DictValue().Set("ok", true).Set("text", text));
}

void OpenSettingsUI::AdBlockDetectConflicts(const base::DictValue& payload,
                                            Reply reply) {
  base::DictValue list = ExtensionsListValue(ProfileFromPayload(payload));
  base::ListValue conflicts;
  if (const base::ListValue* extensions = list.FindList("extensions")) {
    for (const base::Value& item : *extensions) {
      const base::DictValue& d = item.GetDict();
      if (d.FindBool("is_adblocker").value_or(false)) {
        conflicts.Append(base::DictValue()
                             .Set("id", json::GetString(d, "id"))
                             .Set("name", json::GetString(d, "name"))
                             .Set("enabled",
                                  d.FindBool("enabled").value_or(false)));
      }
    }
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("conflicts", std::move(conflicts)));
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
  const std::optional<TimestampSec> since =
      range == "all" ? std::nullopt
                     : std::optional<TimestampSec>(
                           begin.InSecondsFSinceUnixEpoch());
  const TimestampSec through = base::Time::Now().InSecondsFSinceUnixEpoch() + 1;

  uint64_t mask = 0;
  int kinds = 0;
  bool history = false;
  bool downloads = false;
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
        downloads = true;
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
    // Open's own history store (not Chromium's HistoryService); the command
    // bar's recent rows refresh after it.
    RunOnStore(ps->history,
               base::BindOnce(
                   [](std::optional<TimestampSec> since, TimestampSec through,
                      HistoryStore* store) {
                     return store->ClearRange(since, through);
                   },
                   since, through),
               base::BindOnce([](bool) {
                 if (OpenBrowserService* service = OpenBrowserService::Get()) {
                   service->RefreshRecentHistory();
                 }
               }));
  }
  if (downloads) {
    // The Library's download list.
    RunOnStore(ps->downloads,
               base::BindOnce(
                   [](std::optional<TimestampSec> since, TimestampSec through,
                      DownloadHistoryStore* store) {
                     store->Clear(since, through);
                   },
                   since, through));
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
#if BUILDFLAG(IS_MAC)
  // AppKit's NSWorkspace must run on the main/UI thread, and macOS prompts
  // asynchronously for default-browser confirmation.
  OpenPlatform* platform = OpenPlatform::Get();
  if (!platform) {
    ReplyOk(std::move(reply),
            base::DictValue().Set("status", "failed").Set("is_default", false));
    return;
  }
  if (platform->IsDefaultBrowser()) {
    ReplyOk(std::move(reply),
            base::DictValue().Set("status", "already").Set("is_default", true));
    return;
  }
  const bool requested = platform->SetDefaultBrowser();
  const bool is_default = platform->IsDefaultBrowser();
  const char* status =
      is_default ? "success" : (requested ? "prompted" : "failed");
  ReplyOk(std::move(reply), base::DictValue()
                                .Set("status", status)
                                .Set("is_default", is_default));
#else
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
#if BUILDFLAG(IS_WIN)
        // Windows launches ms-settings:defaultapps asynchronously.
        const char* status =
            is_default ? "success" : (requested ? "prompted" : "failed");
#else
        const char* status =
            is_default ? "success" : (requested ? "declined" : "failed");
#endif
        return {status, is_default};
      }),
      base::BindOnce(
          [](Reply reply, std::pair<std::string, bool> result) {
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("status", result.first)
                        .Set("is_default", result.second));
          },
          std::move(reply)));
#endif
}

// --- Extensions --------------------------------------------------------------

void OpenSettingsUI::GetExtensions(const base::DictValue& payload,
                                   Reply reply) {
  ReplyOk(std::move(reply), ExtensionsListValue(ProfileFromPayload(payload)));
}

void OpenSettingsUI::ToggleExtension(const base::DictValue& payload,
                                     Reply reply) {
  // payload.profile_id picks the Profile (Settings lists every Profile's
  // extensions); the page's Profile otherwise.
  ProfileServices* ps =
      service()->ProfileServicesFor(ProfileFromPayload(payload));
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

void OpenSettingsUI::ExtensionsRemove(const base::DictValue& payload,
                                      Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  const std::string id = json::GetString(payload, "id");
  extensions::ExtensionRegistrar* registrar =
      ps && ps->chrome_profile
          ? extensions::ExtensionRegistrar::Get(ps->chrome_profile.get())
          : nullptr;
  if (!registrar || id.empty() || id.size() > 64) {
    ReplyError(std::move(reply), "no such extension");
    return;
  }
  std::u16string error;
  if (!registrar->UninstallExtension(
          id, extensions::UNINSTALL_REASON_USER_INITIATED, &error)) {
    ReplyError(std::move(reply),
               error.empty() ? std::string("the extension was not removed")
                             : base::UTF16ToUTF8(error));
    return;
  }
  ReplyOk(std::move(reply), ExtensionsListValue(profile));
}

void OpenSettingsUI::ExtensionsOpenOptions(const base::DictValue& payload,
                                           Reply reply) {
  ProfileServices* ps =
      service()->ProfileServicesFor(ProfileFromPayload(payload));
  const std::string id = json::GetString(payload, "id");
  const extensions::Extension* extension =
      ps && ps->chrome_profile
          ? extensions::ExtensionRegistry::Get(ps->chrome_profile.get())
                ->GetInstalledExtension(id)
          : nullptr;
  if (!extension) {
    ReplyError(std::move(reply), "no such extension");
    return;
  }
  const GURL url =
      extensions::OptionsPageInfo::HasOptionsPage(extension)
          ? extensions::OptionsPageInfo::GetOptionsPage(extension)
          : GURL("chrome://extensions/?id=" + id);
  ReplyOk(std::move(reply), base::DictValue().Set("ok", OpenInBrowser(url)));
}

// --- Account & Sync (legacy sync.* shape) --------------------------------------

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

// --- Account & Sync (settings.sync.*, detailed) ------------------------------

namespace {

// Runs |reply| with the SyncEngine result (detailed status or error).
SyncEngine::ResultCallback ReplyWithSync(OpenRpcDomain::Reply reply) {
  return base::BindOnce(
      [](OpenRpcDomain::Reply reply, SyncResult result) {
        std::move(reply).Run(SyncResultValue(result));
      },
      std::move(reply));
}

}  // namespace

void OpenSettingsUI::SyncDetailed(const base::DictValue& payload,
                                  Reply reply) {
  SyncEngine* sync = AppSync();
  if (!sync) {
    ReplyError(std::move(reply), "sync is not available");
    return;
  }
  if (!sync->is_signed_in() || !json::GetBool(payload, "refresh_devices",
                                              true)) {
    ReplyOk(std::move(reply), SyncDetailedToValue(sync->GetDetailedStatus()));
    return;
  }
  sync->RefreshDevices(base::BindOnce(
      [](Reply reply, bool ok, std::vector<SyncDeviceInfo> devices,
         std::string error) {
        SyncEngine* sync = AppSync();
        if (!sync) {
          ReplyError(std::move(reply), "sync is not available");
          return;
        }
        base::DictValue d = SyncDetailedToValue(sync->GetDetailedStatus());
        if (ok) {
          d.Set("devices", DeviceList(devices));
        } else if (!error.empty()) {
          d.Set("devices_error", error);
        }
        ReplyOk(std::move(reply), std::move(d));
      },
      std::move(reply)));
}

void OpenSettingsUI::SyncSignIn(const base::DictValue& payload, Reply reply) {
  SyncEngine* sync = AppSync();
  std::optional<std::string> server =
      SyncEngine::ValidateServerUrl(json::GetString(payload, "server_url"));
  const std::string email = json::GetString(payload, "email");
  const std::string password = json::GetString(payload, "password");
  if (!sync || !server || email.empty() || password.empty()) {
    ReplyError(std::move(reply),
               "Enter your server address, email, and password.");
    return;
  }
  sync->SignIn(*server, email, password,
               ParseStrategy(json::GetString(payload, "strategy")),
               ReplyWithSync(std::move(reply)));
}

void OpenSettingsUI::SyncSignUp(const base::DictValue& payload, Reply reply) {
  SyncEngine* sync = AppSync();
  std::optional<std::string> server =
      SyncEngine::ValidateServerUrl(json::GetString(payload, "server_url"));
  const std::string email = json::GetString(payload, "email");
  const std::string password = json::GetString(payload, "password");
  const std::string name = json::GetString(payload, "display_name");
  if (!sync || !server || email.empty() || email.size() > 254 ||
      password.size() < kSyncMinPasswordLength || name.size() > 64) {
    ReplyError(std::move(reply),
               "Enter a server address, an email, and a password of at least "
               "8 characters.");
    return;
  }
  sync->SignUp(*server, email, password, name, ReplyWithSync(std::move(reply)));
}

void OpenSettingsUI::SyncSignOut(const base::DictValue& payload, Reply reply) {
  SyncEngine* sync = AppSync();
  if (!sync) {
    ReplyError(std::move(reply), "sync is not available");
    return;
  }
  sync->SignOut(base::BindOnce(
      [](Reply reply) {
        SyncResult result;
        result.ok = true;
        std::move(reply).Run(SyncResultValue(result));
      },
      std::move(reply)));
}

void OpenSettingsUI::SyncCompleteInitial(const base::DictValue& payload,
                                         Reply reply) {
  SyncEngine* sync = AppSync();
  std::optional<FirstSyncStrategy> strategy =
      ParseStrategy(json::GetString(payload, "strategy"));
  if (!sync || !strategy) {
    ReplyError(std::move(reply), "choose Merge, Use Server, or Use This Device");
    return;
  }
  sync->CompleteInitialSync(*strategy, ReplyWithSync(std::move(reply)));
}

void OpenSettingsUI::SyncNowDetailed(const base::DictValue& payload,
                                     Reply reply) {
  SyncEngine* sync = AppSync();
  if (!sync || !sync->is_signed_in()) {
    ReplyError(std::move(reply), "Sign in to sync.");
    return;
  }
  sync->SyncNow(ReplyWithSync(std::move(reply)));
}

void OpenSettingsUI::SyncChangePassword(const base::DictValue& payload,
                                        Reply reply) {
  SyncEngine* sync = AppSync();
  const std::string current = json::GetString(payload, "current_password");
  const std::string next = json::GetString(payload, "new_password");
  if (!sync || current.empty() || next.size() < kSyncMinPasswordLength) {
    ReplyError(std::move(reply),
               "Enter your current password and a new one of at least 8 "
               "characters.");
    return;
  }
  sync->ChangePassword(current, next,
                       json::GetBool(payload, "revoke_other_sessions", false),
                       ReplyWithSync(std::move(reply)));
}

void OpenSettingsUI::SyncUpdateDisplayName(const base::DictValue& payload,
                                           Reply reply) {
  SyncEngine* sync = AppSync();
  const std::string name = std::string(base::TrimWhitespaceASCII(
      json::GetString(payload, "display_name"), base::TRIM_ALL));
  if (!sync || name.size() > 64) {
    ReplyError(std::move(reply), "a name of up to 64 characters is needed");
    return;
  }
  sync->UpdateDisplayName(name, ReplyWithSync(std::move(reply)));
}

void OpenSettingsUI::SyncDeleteAccount(const base::DictValue& payload,
                                       Reply reply) {
  SyncEngine* sync = AppSync();
  const std::string password = json::GetString(payload, "password");
  if (!sync || password.empty()) {
    ReplyError(std::move(reply), "Enter your password to delete the account.");
    return;
  }
  sync->DeleteAccount(password, ReplyWithSync(std::move(reply)));
}

void OpenSettingsUI::SyncRevokeDeviceDetailed(const base::DictValue& payload,
                                              Reply reply) {
  SyncEngine* sync = AppSync();
  const std::string device = json::GetString(payload, "device_id");
  if (!sync || device.empty() || device.size() > 128) {
    ReplyError(std::move(reply), "no such device");
    return;
  }
  sync->RevokeDevice(device, ReplyWithSync(std::move(reply)));
}

void OpenSettingsUI::SyncSetServerUrl(const base::DictValue& payload,
                                      Reply reply) {
  SyncEngine* sync = AppSync();
  std::optional<std::string> server =
      SyncEngine::ValidateServerUrl(json::GetString(payload, "server_url"));
  if (!sync || !server) {
    ReplyError(std::move(reply),
               "Enter a server address such as https://sync.example.com.");
    return;
  }
  if (sync->is_signed_in()) {
    ReplyError(std::move(reply), "Sign out before you change the server.");
    return;
  }
  if (!sync->ConfigureServerUrl(*server)) {
    ReplyError(std::move(reply), "That server address is not valid.");
    return;
  }
  ReplyOk(std::move(reply), SyncDetailedToValue(sync->GetDetailedStatus()));
}

void OpenSettingsUI::SyncSetCategory(const base::DictValue& payload,
                                     Reply reply) {
  SyncEngine* sync = AppSync();
  std::optional<SyncCategory> category =
      SyncCategoryFromString(json::GetString(payload, "category"));
  std::optional<bool> enabled = payload.FindBool("enabled");
  if (!sync || !category || !enabled) {
    ReplyError(std::move(reply), "unknown sync category");
    return;
  }
  sync->SetCategoryEnabled(*category, *enabled);
  ReplyOk(std::move(reply), SyncDetailedToValue(sync->GetDetailedStatus()));
}

void OpenSettingsUI::SyncRecoverDetailed(const base::DictValue& payload,
                                         Reply reply) {
  SyncEngine* sync = AppSync();
  std::optional<std::string> server =
      SyncEngine::ValidateServerUrl(json::GetString(payload, "server_url"));
  const std::string email = json::GetString(payload, "email");
  const std::string key = json::GetString(payload, "recovery_key");
  const std::string next = json::GetString(payload, "new_password");
  if (!sync || !server || email.empty() || key.empty() ||
      next.size() < kSyncMinPasswordLength) {
    ReplyError(std::move(reply),
               "Enter your server, email, recovery key, and a new password of "
               "at least 8 characters.");
    return;
  }
  sync->RecoverAccount(*server, email, key, next,
                       ParseStrategy(json::GetString(payload, "strategy")),
                       ReplyWithSync(std::move(reply)));
}

// --- Import ------------------------------------------------------------------

void OpenSettingsUI::ImportDetect(const base::DictValue& payload,
                                  Reply reply) {
  // Reads other browsers' profile folders: blocking file I/O.
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce([]() {
        base::ListValue sources;
        for (const DetectedBrowser& browser :
             BrowserImporter::ProbeInstalledBrowsers()) {
          for (const DetectedBrowserProfile& profile : browser.profiles) {
            base::DictValue item;
            item.Set("id", browser.id + "/" + profile.id);
            item.Set("kind", FamilyKind(browser.family));
            item.Set("browser_id", browser.id);
            item.Set("browser_name", browser.name);
            item.Set("profile_name", profile.name);
            item.Set("is_default", profile.is_default);
            item.Set("bookmarks_count", profile.bookmark_count);
            item.Set("history_count", profile.history_count);
            item.Set("access_denied", profile.access_denied);
            if (!profile.access_error.empty()) {
              item.Set("access_error", profile.access_error);
            }
            // The legacy macOS Open folder is only ever read.
            item.Set("read_only",
                     browser.family == BrowserFamily::kOpenLegacy);
            sources.Append(std::move(item));
          }
        }
        return sources;
      }),
      base::BindOnce(
          [](Reply reply, base::ListValue sources) {
            ReplyOk(std::move(reply),
                    base::DictValue().Set("sources", std::move(sources)));
          },
          std::move(reply)));
}

void OpenSettingsUI::ImportPickHtml(const base::DictValue& payload,
                                    Reply reply) {
  RunFileDialog(
      ui::SelectFileDialog::SELECT_OPEN_FILE, u"Import Bookmarks File",
      DownloadPrefs::GetDefaultDownloadDirectory(), {"html", "htm"},
      base::BindOnce(
          [](base::WeakPtr<OpenSettingsUI> self, Reply reply,
             std::optional<base::FilePath> path) {
            if (!self) {
              return;
            }
            if (!path) {
              ReplyOk(std::move(reply),
                      base::DictValue().Set("canceled", true));
              return;
            }
            self->picked_html_path_ = *path;
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("canceled", false)
                        .Set("path", path->AsUTF8Unsafe())
                        .Set("name", path->BaseName().AsUTF8Unsafe()));
          },
          weak_factory_.GetWeakPtr(), std::move(reply)));
}

// static
std::unique_ptr<OpenSettingsUI::ImportRecord>
OpenSettingsUI::ReadImportBlocking(std::string source_id,
                                   std::vector<std::string> kinds,
                                   base::FilePath html_path) {
  auto record = std::make_unique<ImportRecord>();
  record->kinds = std::move(kinds);
  auto on_batch = base::BindRepeating(
      [](std::vector<HistoryEntry>* out,
         const std::vector<HistoryEntry>& batch) {
        for (const HistoryEntry& entry : batch) {
          if (out->size() >= kMaxImportedHistory) {
            return;
          }
          out->push_back(entry);
        }
      },
      base::Unretained(&record->history));

  if (source_id == "html") {
    record->family = BrowserFamily::kHtmlBookmarks;
    record->source_kind = "html";
    record->browser_name = "Bookmarks File";
    if (html_path.empty()) {
      record->error = "Choose a bookmarks file first.";
    } else if (!BrowserImporter::ReadBookmarksHtmlFile(
                   html_path, &record->bookmark_roots)) {
      record->error = "That file is not a bookmarks HTML file.";
    } else {
      record->has_bookmarks = true;
    }
    return record;
  }

  const size_t slash = source_id.find('/');
  const std::string browser_id =
      slash == std::string::npos ? source_id : source_id.substr(0, slash);
  const std::string profile_id =
      slash == std::string::npos ? std::string() : source_id.substr(slash + 1);
  for (const DetectedBrowser& browser :
       BrowserImporter::ProbeInstalledBrowsers()) {
    if (browser.id != browser_id) {
      continue;
    }
    for (const DetectedBrowserProfile& profile : browser.profiles) {
      if (profile.id != profile_id) {
        continue;
      }
      record->browser_name = browser.name;
      record->family = browser.family;
      record->source_kind = std::string(FamilyKind(browser.family));
      if (profile.access_denied) {
        record->access_denied = true;
        record->error = profile.access_error.empty()
                            ? "Open needs Full Disk Access to read this data."
                            : profile.access_error;
        return record;
      }
      switch (browser.family) {
        case BrowserFamily::kArc: {
          ArcImportOptions options;
          options.include_archive = record->Wants("archive");
          options.include_boosts = record->Wants("boosts");
          options.include_notes = record->Wants("documents");
          options.include_easels = record->Wants("documents");
          options.include_history = record->Wants("history");
          options.max_history_entries = kMaxImportedHistory;
          ArcSidebarImportResult result =
              BrowserImporter::ImportArcDirectory(profile.directory, options);
          if (!result.ok) {
            record->error = result.error_message.empty()
                                ? "Open could not read Arc's sidebar."
                                : result.error_message;
            return record;
          }
          if (!record->Wants("spaces")) {
            result.spaces.clear();
            result.profiles.clear();
          }
          record->arc = std::move(result);
          return record;
        }
        case BrowserFamily::kOpenLegacy: {
          // Read-only: never writes to the legacy folder.
          OpenLegacyImportOptions options;
          options.include_workspace = record->Wants("spaces");
          options.include_preferences = record->Wants("settings");
          options.include_shortcuts = record->Wants("settings");
          options.include_adblock = record->Wants("settings");
          options.include_boosts = record->Wants("boosts");
          options.include_documents = record->Wants("documents");
          options.include_history = record->Wants("history");
          options.include_archive = record->Wants("archive");
          options.max_history_per_profile = kMaxImportedHistory;
          OpenLegacyImportResult result =
              BrowserImporter::ImportOpenLegacyDirectory(profile.directory,
                                                         options);
          if (!result.ok) {
            record->error = result.error_message.empty()
                                ? "Open could not read the legacy Open data."
                                : result.error_message;
            return record;
          }
          record->legacy = std::move(result);
          return record;
        }
        case BrowserFamily::kSafari: {
          SafariImportErrorInfo error;
          if (record->Wants("bookmarks")) {
            record->has_bookmarks = BrowserImporter::ReadSafariBookmarks(
                profile.directory, &record->bookmark_roots, nullptr, &error);
          }
          if (!error.permission_denied && record->Wants("history")) {
            BrowserImporter::ReadSafariHistory(profile.directory, on_batch,
                                               nullptr, &error);
          }
          if (error.permission_denied) {
            record->access_denied = true;
            record->error = "Open needs Full Disk Access to read Safari.";
          }
          return record;
        }
        case BrowserFamily::kFirefox:
          if (record->Wants("bookmarks")) {
            record->has_bookmarks = BrowserImporter::ReadFirefoxBookmarks(
                profile.directory, &record->bookmark_roots);
          }
          if (record->Wants("history")) {
            BrowserImporter::ReadFirefoxHistory(profile.directory, on_batch);
          }
          return record;
        case BrowserFamily::kChromium:
        case BrowserFamily::kHtmlBookmarks:
          if (record->Wants("bookmarks")) {
            record->has_bookmarks = BrowserImporter::ReadChromiumBookmarks(
                profile.directory, &record->bookmark_roots);
          }
          if (record->Wants("history")) {
            BrowserImporter::ReadChromiumHistory(profile.directory, on_batch);
          }
          return record;
      }
    }
  }
  record->error = "That browser profile was not found.";
  return record;
}

void OpenSettingsUI::ImportRun(const base::DictValue& payload, Reply reply) {
  const std::string source_id = json::GetString(payload, "source_id");
  std::vector<std::string> kinds;
  if (const base::ListValue* list = payload.FindList("kinds")) {
    for (const base::Value& kind : *list) {
      static constexpr const char* kKnown[] = {
          "bookmarks", "history", "spaces",   "favorites",
          "archive",   "boosts",  "documents", "settings"};
      if (kind.is_string() &&
          std::find(std::begin(kKnown), std::end(kKnown), kind.GetString()) !=
              std::end(kKnown)) {
        kinds.push_back(kind.GetString());
      }
    }
  }
  if (source_id == "html") {
    kinds.push_back("bookmarks");
  }
  if (source_id.empty() || source_id.size() > 256 || kinds.empty()) {
    ReplyError(std::move(reply), "Choose a source and what to import.");
    return;
  }
  const ProfileID target = service()->model().FindProfile(
                               json::GetString(payload, "target_profile_id"))
                               ? json::GetString(payload, "target_profile_id")
                               : profile_id();
  Emit(kEventImportProgress, base::Value(base::DictValue()
                                             .Set("source_id", source_id)
                                             .Set("phase", "reading")));
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&OpenSettingsUI::ReadImportBlocking, source_id,
                     std::move(kinds), picked_html_path_),
      base::BindOnce(&OpenSettingsUI::FinishImport,
                     weak_factory_.GetWeakPtr(), source_id, target,
                     std::move(reply)));
}

void OpenSettingsUI::FinishImport(std::string source_id,
                                  ProfileID profile,
                                  Reply reply,
                                  std::unique_ptr<ImportRecord> record) {
  OpenBrowserService* s = service();
  if (!s) {
    ReplyError(std::move(reply), "shutting down");
    return;
  }
  if (!record->error.empty()) {
    Emit(kEventImportProgress, base::Value(base::DictValue()
                                               .Set("source_id", source_id)
                                               .Set("phase", "failed")));
    if (record->access_denied) {
      // The page shows the Full Disk Access steps.
      ReplyOk(std::move(reply), base::DictValue()
                                    .Set("ok", false)
                                    .Set("access_denied", true)
                                    .Set("error", record->error));
      return;
    }
    ReplyError(std::move(reply), record->error);
    return;
  }
  BrowserModel& model = s->model();
  if (!model.FindProfile(profile) && !model.profiles().empty()) {
    profile = model.profiles().front().id;
  }
  auto pid_or_target = [&](const std::optional<ProfileID>& id) {
    return id && model.FindProfile(*id) ? *id : profile;
  };

  ImportEntries().emplace_back();
  ImportEntry& entry = ImportEntries().back();
  entry.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  entry.source_name = record->browser_name;
  entry.source_kind = record->source_kind;
  entry.imported_at = base::Time::Now().InSecondsFSinceUnixEpoch();
  entry.receipt.import_id = entry.id;
  entry.receipt.source_browser = record->browser_name;
  entry.receipt.source_family = record->family;
  entry.receipt.imported_at = entry.imported_at;
  const std::string entry_id = entry.id;

  int bookmarks = 0;
  int spaces = 0;
  int tabs = 0;
  int boosts = 0;
  int documents = 0;
  int archive = 0;
  int history = 0;
  int preferences = 0;
  int shortcuts = 0;

  // Bookmarks: an "Imported from <browser>" pinned folder tree in the
  // Profile's current Space (nested folders kept).
  if (record->has_bookmarks && !record->bookmark_roots.empty()) {
    std::optional<SpaceID> space = model.MostRecentlyFocusedSpace(profile);
    if (!space) {
      for (const Space& candidate : model.spaces()) {
        if (candidate.profile_id == profile) {
          space = candidate.id;
          break;
        }
      }
    }
    if (space) {
      size_t urls = 0;
      CountNodes(record->bookmark_roots, &urls);
      MergeReceipt(&entry.receipt,
                   BrowserImporter::ApplyImportedBookmarksToModel(
                       &model, *space, record->browser_name, record->family,
                       source_id, record->bookmark_roots,
                       kMaxImportedBookmarks));
      bookmarks = static_cast<int>(std::min(urls, kMaxImportedBookmarks));
    }
  }

  // Records what a store task created, once it is done.
  auto record_created =
      [](std::string entry_id,
         std::map<ProfileID, std::vector<std::string>> ImportEntry::*member,
         ProfileID pid, std::vector<std::string> ids) {
        if (ImportEntry* e = FindImportEntry(entry_id)) {
          AppendAll(&((e->*member)[pid]), ids);
        }
      };
  auto add_boosts = [&](const ProfileID& pid, std::vector<Boost> items) {
    ProfileServices* ps = s->ProfileServicesFor(pid);
    if (!ps || items.empty()) {
      return;
    }
    boosts += static_cast<int>(items.size());
    RunOnStore(ps->boosts,
               base::BindOnce(
                   [](ProfileID pid, std::vector<Boost> items,
                      BoostStore* store) {
                     std::vector<std::string> created;
                     for (Boost& boost : items) {
                       if (store->GetBoost(boost.id)) {
                         continue;
                       }
                       boost.profile_id = pid;
                       created.push_back(boost.id);
                       store->Upsert(std::move(boost));
                     }
                     store->SaveNow();
                     return created;
                   },
                   pid, std::move(items)),
               base::BindOnce(record_created, entry_id,
                              &ImportEntry::boost_ids, pid));
  };
  auto add_documents = [&](const ProfileID& pid,
                           std::vector<EaselDocument> easels,
                           std::vector<NoteDocument> notes) {
    ProfileServices* ps = s->ProfileServicesFor(pid);
    if (!ps || (easels.empty() && notes.empty())) {
      return;
    }
    documents += static_cast<int>(easels.size() + notes.size());
    RunOnStore(ps->documents,
               base::BindOnce(
                   [](std::vector<EaselDocument> easels,
                      DocumentStore* store) {
                     std::vector<std::string> created;
                     for (const EaselDocument& easel : easels) {
                       if (!store->LoadEasel(easel.id) &&
                           store->SaveEasel(easel)) {
                         created.push_back(easel.id);
                       }
                     }
                     return created;
                   },
                   std::move(easels)),
               base::BindOnce(record_created, entry_id,
                              &ImportEntry::easel_ids, pid));
    RunOnStore(ps->documents,
               base::BindOnce(
                   [](std::vector<NoteDocument> notes, DocumentStore* store) {
                     std::vector<std::string> created;
                     for (const NoteDocument& note : notes) {
                       if (!store->LoadNote(note.id) &&
                           store->SaveNote(note)) {
                         created.push_back(note.id);
                       }
                     }
                     return created;
                   },
                   std::move(notes)),
               base::BindOnce(record_created, entry_id,
                              &ImportEntry::note_ids, pid));
  };
  auto add_archive = [&](const ProfileID& pid,
                         std::vector<ArchivedTabRecord> items) {
    ProfileServices* ps = s->ProfileServicesFor(pid);
    if (!ps || items.empty()) {
      return;
    }
    archive += static_cast<int>(items.size());
    RunOnStore(ps->archive,
               base::BindOnce(
                   [](ProfileID pid, std::vector<ArchivedTabRecord> items,
                      ArchiveStore* store) {
                     std::vector<ArchivedTabRecord> fresh;
                     std::vector<std::string> created;
                     for (ArchivedTabRecord& item : items) {
                       if (!store->Get(item.id)) {
                         item.profile_id = pid;
                         created.push_back(item.id);
                         fresh.push_back(std::move(item));
                       }
                     }
                     if (!fresh.empty()) {
                       store->Archive(fresh);
                     }
                     return created;
                   },
                   pid, std::move(items)),
               base::BindOnce(record_created, entry_id,
                              &ImportEntry::archive_ids, pid));
  };
  auto add_history = [&](const ProfileID& pid,
                         std::vector<HistoryEntry> items) {
    ProfileServices* ps = s->ProfileServicesFor(pid);
    if (!ps || items.empty()) {
      return;
    }
    history += static_cast<int>(items.size());
    std::vector<std::string> urls;
    for (const HistoryEntry& item : items) {
      urls.push_back(item.url);
    }
    if (ImportEntry* e = FindImportEntry(entry_id)) {
      AppendAll(&e->history_urls[pid], urls);
    }
    RunOnStore(ps->history,
               base::BindOnce(
                   [](std::vector<HistoryEntry> items, HistoryStore* store) {
                     for (const HistoryEntry& item : items) {
                       store->RecordVisit(item.url, item.title,
                                          item.last_visit, "imported",
                                          item.typed_count > 0);
                     }
                     return true;
                   },
                   std::move(items)),
               // Imported pages show up in the command bar at once.
               base::BindOnce([](bool) {
                 if (OpenBrowserService* service = OpenBrowserService::Get()) {
                   service->RefreshRecentHistory();
                 }
               }));
  };

  if (record->arc) {
    ArcSidebarImportResult& arc = *record->arc;
    MergeReceipt(&entry.receipt,
                 BrowserImporter::ApplyArcImportToModel(&model, arc, nullptr));
    spaces += static_cast<int>(arc.spaces.size());
    tabs += static_cast<int>(arc.imported_tabs);
    std::map<ProfileID, std::vector<Boost>> boosts_by_profile;
    for (Boost& boost : arc.boosts) {
      boosts_by_profile[pid_or_target(boost.profile_id)].push_back(
          std::move(boost));
    }
    for (auto& [pid, items] : boosts_by_profile) {
      add_boosts(pid, std::move(items));
    }
    add_documents(profile, std::move(arc.easels), std::move(arc.notes));
    add_archive(profile, std::move(arc.archive_records));
    add_history(profile, std::move(arc.history));
  }

  if (record->legacy) {
    OpenLegacyImportResult& legacy = *record->legacy;
    MergeReceipt(&entry.receipt, BrowserImporter::ApplyOpenLegacyImportToModel(
                                     &model, legacy, nullptr));
    spaces += static_cast<int>(legacy.imported_spaces);
    tabs += static_cast<int>(legacy.imported_tabs);
    for (auto& [pid, items] : legacy.boosts_by_profile) {
      add_boosts(pid_or_target(pid), std::move(items));
    }
    add_documents(profile, std::move(legacy.easels), std::move(legacy.notes));
    for (auto& [pid, items] : legacy.archive_by_profile) {
      add_archive(pid_or_target(pid), std::move(items));
    }
    for (auto& [pid, items] : legacy.history_by_profile) {
      add_history(pid_or_target(pid), std::move(items));
    }
    if (record->Wants("settings")) {
      if (legacy.keybindings) {
        std::string error;
        int applied = 0;
        int skipped = 0;
        if (ApplyShortcutsDict(*legacy.keybindings, &error, &applied,
                               &skipped)) {
          shortcuts = applied;
          AfterShortcutChange(std::string());
        }
      }
      OpenPreferences* prefs = OpenPreferences::Get();
      for (const auto& [legacy_key, key] : kLegacyPreferenceKeys) {
        auto it = legacy.preferences.find(legacy_key);
        std::string error;
        if (it != legacy.preferences.end() &&
            prefs->Set(key, it->second, profile, false, &error)) {
          ++preferences;
        }
      }
      if (legacy.adblock) {
        for (const auto& [pid, lists] : legacy.adblock->enabled_lists_by_profile) {
          ProfileServices* ps = s->ProfileServicesFor(pid_or_target(pid));
          if (OpenAdBlockProfileService* adblock =
                  ps ? ps->adblock() : nullptr) {
            adblock->SetEnabledListIds(lists);
          }
        }
        for (const auto& [pid, domains] :
             legacy.adblock->excluded_domains_by_profile) {
          ProfileServices* ps = s->ProfileServicesFor(pid_or_target(pid));
          if (OpenAdBlockProfileService* adblock =
                  ps ? ps->adblock() : nullptr) {
            adblock->SetExcludedDomains(domains);
          }
        }
      }
    }
  }

  if (!record->history.empty()) {
    add_history(profile, std::move(record->history));
  }

  if (ImportEntry* e = FindImportEntry(entry_id)) {
    e->counts = base::DictValue()
                    .Set("bookmarks", bookmarks)
                    .Set("spaces", spaces)
                    .Set("tabs", tabs)
                    .Set("boosts", boosts)
                    .Set("documents", documents)
                    .Set("archive", archive)
                    .Set("history", history)
                    .Set("preferences", preferences)
                    .Set("shortcuts", shortcuts);
  }
  // Keep the newest receipts only.
  while (ImportEntries().size() > kMaxImportReceipts) {
    ImportEntries().erase(ImportEntries().begin());
  }
  s->ScheduleSave();
  Emit(kEventImportProgress, base::Value(base::DictValue()
                                             .Set("source_id", source_id)
                                             .Set("phase", "done")));
  const ImportEntry* done = FindImportEntry(entry_id);
  ReplyOk(std::move(reply),
          base::DictValue()
              .Set("ok", true)
              .Set("receipt", done ? ImportEntryToValue(*done)
                                   : base::DictValue()));
}

void OpenSettingsUI::ImportUndo(const base::DictValue& payload, Reply reply) {
  ImportEntry* entry = FindImportEntry(json::GetString(payload, "receipt_id"));
  OpenBrowserService* s = service();
  if (!entry || entry->undone || !s) {
    ReplyError(std::move(reply), "That import cannot be undone.");
    return;
  }
  // Spaces, tabs, folders, Favorites and Profiles the import created.
  BrowserImporter::UndoImport(entry->receipt, &s->model(), nullptr);
  for (const auto& [pid, ids] : entry->boost_ids) {
    if (ProfileServices* ps = s->ProfileServicesFor(pid)) {
      RunOnStore(ps->boosts, base::BindOnce(
                                 [](std::vector<std::string> ids,
                                    BoostStore* store) {
                                   for (const std::string& id : ids) {
                                     store->Delete(id);
                                   }
                                   store->SaveNow();
                                 },
                                 ids));
    }
  }
  for (const auto& [pid, ids] : entry->easel_ids) {
    if (ProfileServices* ps = s->ProfileServicesFor(pid)) {
      RunOnStore(ps->documents, base::BindOnce(
                                    [](std::vector<std::string> ids,
                                       DocumentStore* store) {
                                      for (const std::string& id : ids) {
                                        store->DeleteEasel(id);
                                      }
                                    },
                                    ids));
    }
  }
  for (const auto& [pid, ids] : entry->note_ids) {
    if (ProfileServices* ps = s->ProfileServicesFor(pid)) {
      RunOnStore(ps->documents, base::BindOnce(
                                    [](std::vector<std::string> ids,
                                       DocumentStore* store) {
                                      for (const std::string& id : ids) {
                                        store->DeleteNote(id);
                                      }
                                    },
                                    ids));
    }
  }
  for (const auto& [pid, ids] : entry->archive_ids) {
    if (ProfileServices* ps = s->ProfileServicesFor(pid)) {
      RunOnStore(ps->archive,
                 base::BindOnce(
                     [](std::vector<ItemID> ids, ArchiveStore* store) {
                       store->DeleteIds(ids);
                     },
                     ids));
    }
  }
  for (const auto& [pid, urls] : entry->history_urls) {
    if (ProfileServices* ps = s->ProfileServicesFor(pid)) {
      RunOnStore(ps->history,
                 base::BindOnce(
                     [](std::vector<std::string> urls, HistoryStore* store) {
                       for (const std::string& url : urls) {
                         store->DeleteUrl(url);
                       }
                       return true;
                     },
                     urls),
                 base::BindOnce([](bool) {
                   if (OpenBrowserService* service =
                           OpenBrowserService::Get()) {
                     service->RefreshRecentHistory();
                   }
                 }));
    }
  }
  entry->undone = true;
  s->ScheduleSave();
  ReplyOk(std::move(reply), base::DictValue()
                                .Set("ok", true)
                                .Set("receipt", ImportEntryToValue(*entry)));
}

void OpenSettingsUI::ImportReceipts(const base::DictValue& payload,
                                    Reply reply) {
  base::ListValue receipts;
  for (auto it = ImportEntries().rbegin(); it != ImportEntries().rend(); ++it) {
    receipts.Append(ImportEntryToValue(*it));
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("receipts", std::move(receipts)));
}

// --- About & diagnostics -----------------------------------------------------

void OpenSettingsUI::AboutGet(const base::DictValue& payload, Reply reply) {
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&ReadBundleVersionBlocking),
      base::BindOnce(
          [](Reply reply, std::string version) {
            CachedOpenVersion() = version;
            OpenBrowserService* s = OpenBrowserService::Get();
            const bool widevine_session =
                base::CommandLine::ForCurrentProcess()->HasSwitch(
                    switches::kEnableWidevine);
            const bool widevine_pref = BoolPref("advanced.widevine");
#if BUILDFLAG(IS_MAC)
            const char* platform = "macOS";
#elif BUILDFLAG(IS_WIN)
            const char* platform = "Windows";
#else
            const char* platform = "Linux";
#endif
            ReplyOk(
                std::move(reply),
                base::DictValue()
                    .Set("app_version", version)
                    .Set("chromium_version", version_info::GetVersionNumber())
                    .Set("platform", platform)
                    .Set("os_version",
                         base::SysInfo::OperatingSystemName() + " " +
                             base::SysInfo::OperatingSystemVersion())
                    .Set("architecture",
                         base::SysInfo::OperatingSystemArchitecture())
                    .Set("data_folder", s ? s->user_data_dir().AsUTF8Unsafe()
                                          : std::string())
                    .Set("widevine",
                         base::DictValue()
                             .Set("session_enabled", widevine_session)
                             .Set("preference", widevine_pref)
                             .Set("restart_required",
                                  widevine_session != widevine_pref)));
          },
          std::move(reply)));
}

void OpenSettingsUI::AboutShowDataFolder(const base::DictValue& payload,
                                         Reply reply) {
  ::Profile* chrome_profile = profile();
  if (!chrome_profile) {
    ReplyError(std::move(reply), "no profile");
    return;
  }
  // Selects the folder in Finder, Explorer or the file manager.
  platform_util::ShowItemInFolder(chrome_profile, service()->user_data_dir());
  ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
}

void OpenSettingsUI::AboutCopySystemInfo(const base::DictValue& payload,
                                         Reply reply) {
  const std::string text = SystemInfoText(OpenVersion());
  CopyToClipboard(text);
  ReplyOk(std::move(reply),
          base::DictValue().Set("ok", true).Set("text", text));
}

void OpenSettingsUI::AboutCheckForUpdates(const base::DictValue& payload,
                                          Reply reply) {
  OpenBrowserService* svc = service();
  OpenUpdaterService* updater = svc ? svc->updater() : nullptr;
  if (!updater) {
    ReplyOk(std::move(reply),
            base::DictValue()
                .Set("status", "unavailable")
                .Set("current_version", OpenVersion())
                .Set("message",
                     "Update checker is not initialized yet. Try again in a "
                     "moment."));
    return;
  }
  updater->CheckForUpdates(
      /*user_initiated=*/true,
      base::BindOnce(
          [](Reply reply, const UpdateCheckStatus& status) {
            base::DictValue out;
            out.Set("current_version", status.current_version.empty()
                                           ? OpenVersion()
                                           : status.current_version);
            switch (status.state) {
              case UpdateState::kUpToDate:
                out.Set("status", "up_to_date");
                out.Set("message", "Open is up to date.");
                break;
              case UpdateState::kUpdateAvailable:
                out.Set("status", "update_available");
                if (status.available_release.has_value()) {
                  out.Set("latest_version", status.available_release->version);
                  out.Set("release_url",
                          status.available_release->html_url.spec());
                  out.Set("download_url",
                          status.available_release->download_url.spec());
                  out.Set("release_notes",
                          status.available_release->release_notes);
                  out.Set("message", "Open " +
                                         status.available_release->version +
                                         " is available.");
                } else {
                  out.Set("message", "A new version of Open is available.");
                }
                break;
              case UpdateState::kChecking:
                out.Set("status", "checking");
                out.Set("message", "Checking for updates…");
                break;
              case UpdateState::kError:
                out.Set("status", "error");
                out.Set("message", status.error_message.empty()
                                       ? "Could not check for updates."
                                       : status.error_message);
                break;
              case UpdateState::kIdle:
                out.Set("status", "unavailable");
                out.Set("message", "No update check result yet.");
                break;
            }
            ReplyOk(std::move(reply), std::move(out));
          },
          std::move(reply)));
}

void OpenSettingsUI::AboutReplayOnboarding(const base::DictValue& payload,
                                           Reply reply) {
  ReplyOk(std::move(reply),
          base::DictValue().Set(
              "ok", OpenInBrowser(GURL(OpenWebUIURL(kHostOnboarding)))));
}

}  // namespace open_unified::webui
