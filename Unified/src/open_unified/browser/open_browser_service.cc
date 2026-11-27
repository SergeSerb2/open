// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_browser_service.h"

#include <algorithm>
#include <filesystem>
#include <set>
#include <string_view>
#include <utility>

#include "base/auto_reset.h"
#include "base/check.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/power_monitor/power_monitor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "build/build_config.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/custom_handlers/protocol_handler_registry_factory.h"  // nogncheck
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_metrics.h"
#include "components/custom_handlers/protocol_handler_registry.h"  // nogncheck
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/browser/open_boost_controller.h"
#include "open_unified/browser/open_capture_controller.h"
#include "open_unified/browser/open_download_bridge.h"
#include "open_unified/browser/open_extension_bridge.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_media_bridge.h"
#include "open_unified/browser/open_sleep_controller.h"
#include "open_unified/browser/open_switches.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/open_translate_controller.h"
#include "open_unified/browser/open_updater_service.h"
#include "open_unified/browser/open_window_controller.h"
#include "open_unified/browser/platform/open_handoff.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/documents/document_store.h"
#include "open_unified/core/livedata/open_livedata_service.h"
#include "open_unified/core/model/uuid_util.h"
#include "open_unified/core/routing/routing_evaluator.h"
#include "open_unified/core/store/snapshot_store.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "open_unified/core/suggest/suggest_engine.h"
#include "open_unified/core/sync/sync_adapter_impl.h"
#include "open_unified/core/sync/sync_engine.h"
#include "open_unified/core/sync/sync_ws_client.h"
#include "open_unified/ui/webui/open_ipc_contract.h"
#include "open_unified/ui/webui/open_library_ui.h"
#include "open_unified/ui/webui/open_settings_ui.h"
#include "open_unified/ui/webui/open_webui_config.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "ui/events/keycodes/keyboard_codes.h"

#if BUILDFLAG(OPEN_ENABLE_AUTOMATION)
#include "open_unified/browser/open_automation_server.h"
#endif

namespace open_unified {

namespace {

OpenBrowserService* g_service = nullptr;

constexpr char kStateDirName[] = "State";
constexpr char kProfilesDirName[] = "Profiles";
constexpr char kOnboardingMarker[] = "onboarding-complete";
constexpr char kMeetRouteMarker[] = "meet-route-set";
constexpr char kPreferencesFile[] = "Preferences.json";
constexpr char kKeybindingsFile[] = "keybindings.json";
constexpr char kPendingWipeFile[] = ".pending-wipe.json";
constexpr char kLittleOpenGlobalHotkeyId[] = "little-open-global";
constexpr base::TimeDelta kAutoArchiveSweepInterval = base::Seconds(60);

bool IsSafeProfileDirectoryName(std::string_view name) {
  if (name.empty() || name.size() > 255) {
    return false;
  }
  const std::string lower = base::ToLowerASCII(name);
  if (lower == "." || lower == ".." || lower == "default") {
    return false;
  }
  for (unsigned char c : name) {
    if (c < 32 || c == '/' || c == '\\' || c == ':') {
      return false;
    }
  }
  return true;
}

std::vector<std::string> ReadPendingWipeList(const base::FilePath& path) {
  std::vector<std::string> names;
  std::string raw;
  if (!base::PathExists(path) ||
      !base::ReadFileToStringWithMaxSize(path, &raw, 65536)) {
    return names;
  }
  std::optional<base::ListValue> list =
      base::JSONReader::ReadList(raw, base::JSON_PARSE_RFC);
  if (!list || list->size() > 1024) {
    return names;
  }
  for (const base::Value& v : *list) {
    if (v.is_string() && IsSafeProfileDirectoryName(v.GetString())) {
      names.push_back(v.GetString());
    }
  }
  return names;
}

bool WritePendingWipeList(const base::FilePath& path,
                          const std::vector<std::string>& names) {
  if (names.empty()) {
    return !base::PathExists(path) || base::DeleteFile(path);
  }
  base::ListValue list;
  for (const std::string& name : names) {
    if (IsSafeProfileDirectoryName(name)) {
      list.Append(name);
    }
  }
  std::string encoded;
  if (!base::JSONWriter::Write(list, &encoded)) {
    return false;
  }
  base::CreateDirectory(path.DirName());
  return base::ImportantFileWriter::WriteFileAtomically(path, encoded);
}

std::optional<uint32_t> PlatformHotkeyCodeForToken(std::string_view raw_key) {
  const std::string key = base::ToLowerASCII(raw_key);
#if BUILDFLAG(IS_MAC)
  // macOS Carbon RegisterEventHotKey uses hardware virtual keycodes (kVK_*).
  if (key.size() == 1) {
    switch (key[0]) {
      case 'a': return 0x00;
      case 's': return 0x01;
      case 'd': return 0x02;
      case 'f': return 0x03;
      case 'h': return 0x04;
      case 'g': return 0x05;
      case 'z': return 0x06;
      case 'x': return 0x07;
      case 'c': return 0x08;
      case 'v': return 0x09;
      case 'b': return 0x0B;
      case 'q': return 0x0C;
      case 'w': return 0x0D;
      case 'e': return 0x0E;
      case 'r': return 0x0F;
      case 'y': return 0x10;
      case 't': return 0x11;
      case '1': return 0x12;
      case '2': return 0x13;
      case '3': return 0x14;
      case '4': return 0x15;
      case '6': return 0x16;
      case '5': return 0x17;
      case '=': return 0x18;
      case '9': return 0x19;
      case '7': return 0x1A;
      case '-': return 0x1B;
      case '8': return 0x1C;
      case '0': return 0x1D;
      case ']': return 0x1E;
      case 'o': return 0x1F;
      case 'u': return 0x20;
      case '[': return 0x21;
      case 'i': return 0x22;
      case 'p': return 0x23;
      case 'l': return 0x25;
      case 'j': return 0x26;
      case '\'': return 0x27;
      case 'k': return 0x28;
      case ';': return 0x29;
      case '\\': return 0x2A;
      case ',': return 0x2B;
      case '/': return 0x2C;
      case 'n': return 0x2D;
      case 'm': return 0x2E;
      case '.': return 0x2F;
      case '`': return 0x32;
      default: break;
    }
  }
  if (key == "return" || key == "enter") return 0x24;
  if (key == "tab") return 0x30;
  if (key == "space") return 0x31;
  if (key == "escape" || key == "esc") return 0x35;
  return std::nullopt;
#else
  if (key.size() == 1) {
    const char c = key[0];
    if (c >= 'a' && c <= 'z') {
      return static_cast<uint32_t>(ui::VKEY_A + (c - 'a'));
    }
    if (c >= '0' && c <= '9') {
      return static_cast<uint32_t>(ui::VKEY_0 + (c - '0'));
    }
  }
  if (key == "space") return static_cast<uint32_t>(ui::VKEY_SPACE);
  if (key == "return" || key == "enter") {
    return static_cast<uint32_t>(ui::VKEY_RETURN);
  }
  if (key == "tab") return static_cast<uint32_t>(ui::VKEY_TAB);
  if (key == "escape" || key == "esc") {
    return static_cast<uint32_t>(ui::VKEY_ESCAPE);
  }
  return std::nullopt;
#endif
}

std::optional<GlobalHotkeySpec> BuildGlobalHotkeySpec(
    const std::string& id,
    const KeyboardShortcut& shortcut) {
  auto code = PlatformHotkeyCodeForToken(shortcut.key);
  if (!code.has_value()) {
    return std::nullopt;
  }
  GlobalHotkeySpec spec;
  spec.id = id;
  spec.key_code = *code;
  spec.modifiers = kHotkeyModNone;
  if (shortcut.modifiers & kModAlt) spec.modifiers |= kHotkeyModAlt;
  if (shortcut.modifiers & kModCtrl) spec.modifiers |= kHotkeyModControl;
  if (shortcut.modifiers & kModShift) spec.modifiers |= kHotkeyModShift;
  if (shortcut.modifiers & kModMeta) spec.modifiers |= kHotkeyModMeta;
  return spec;
}

std::optional<KeyboardShortcut> ParseHotkeyPrefString(std::string_view text) {
  std::vector<std::string> parts = base::SplitString(
      text, "+", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  if (parts.empty() || parts.size() > 5) {
    return std::nullopt;
  }
  KeyboardShortcut sc;
  sc.key = base::ToLowerASCII(parts.back());
  parts.pop_back();
  for (const std::string& raw : parts) {
    const std::string m = base::ToLowerASCII(raw);
    if (m == "mod") {
      sc.modifiers |= kModPrimary;
    } else if (m == "ctrl" || m == "control") {
      sc.modifiers |= kModCtrl;
    } else if (m == "alt" || m == "option") {
      sc.modifiers |= kModAlt;
    } else if (m == "shift") {
      sc.modifiers |= kModShift;
    } else if (m == "cmd" || m == "meta" || m == "super") {
      sc.modifiers |= kModMeta;
    } else {
      return std::nullopt;
    }
  }
  return sc.key.empty() ? std::nullopt
                        : std::optional<KeyboardShortcut>(sc.Normalized());
}

std::filesystem::path ToStdPath(const base::FilePath& path) {
  return std::filesystem::path(path.value());
}

TimestampSec NowSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

template <typename Store>
void OpenStore(const base::SequenceBound<Store>& store) {
  RunOnStore(store, base::BindOnce([](Store* s) {
               if (!s->Open()) {
                 LOG(ERROR) << "Open: a profile store failed to open";
               }
             }));
}

}  // namespace

// ---------------------------------------------------------------------------
// ProfileServices

namespace {

// Mapping between webui::OpenPreferences keys (Preferences.json) and canonical
// Open Sync v1 portable preference keys (docs/sync-protocol.md §2).
struct PortablePrefMapping {
  const char* open_pref_key;
  const char* sync_key;
};

constexpr PortablePrefMapping kPortablePrefMappings[] = {
    {"previews.enabled", "open.general.previewsEnabled"},
    {"previews.folders", "open.general.previewsFolders"},
    {"previews.pages", "open.general.previewsPages"},
    {"previews.calendar", "open.general.previewsCalendar"},
    {"previews.recents", "open.general.previewsRecents"},
    {"previews.gmail", "open.general.previewsGmail"},
    {"general.warnBeforeQuitting", "open.general.warnBeforeQuitting"},
    {"links.peekShiftClick", "open.links.openPeekShiftClick"},
    {"links.peekOtherSites", "open.links.openPeekOtherSites"},
    {"links.externalLinksLittleOpen", "open.links.externalInLittleOpen"},
    {"links.optionCommandClick", "open.links.optionCommandClickLittleOpen"},
    {"shortcuts.priority", "open.shortcuts.defaultPriority"},
    {"tabs.ninthTabGoesToLast", "open.shortcuts.switchToNinthEnabled"},
    {"tabs.includeFavoritesInSwitcher",
     "open.shortcuts.includeFavoritesInTabNumbering"},
    {"advanced.soundEffects", "open.advanced.playSoundEffects"},
    {"advanced.haptics", "open.advanced.hapticOnTabReorder"},
    {"general.restoreWindows", "open.advanced.restoreWindowsOnLaunch"},
    {"appearance.fullUrl", "open.advanced.showFullURLWithToolbar"},
    {"advanced.enableBoosts", "open.advanced.enableBoosts"},
    {"advanced.windowDragging", "open.advanced.allowWindowDraggingFromWebTop"},
    {"advanced.sharedQuotes", "open.advanced.enableSharedQuotes"},
    {"advanced.pictureInPicture",
     "open.advanced.enablePictureInPictureOnLeave"},
    {"advanced.themeData", "open.advanced.allowSitesThemeData"},
    {"appearance.websiteAppearance", "open.web.colorScheme"},
    {"general.offerTranslate", "open.translate.enabled"},
    {"advanced.pipExcludedHosts", "open.pip.autoDisabledHosts"},
};

void CollectLiveFoldersFromNodes(
    const std::vector<SidebarNode>& nodes,
    std::map<ItemID, LiveFolderConfig>* out) {
  for (const SidebarNode& node : nodes) {
    if (const Folder* folder = node.as_folder()) {
      if (folder->live.has_value()) {
        out->emplace(folder->id, *folder->live);
      }
      CollectLiveFoldersFromNodes(folder->children, out);
    }
  }
}

}  // namespace

// Bridges OpenDownloadBridge updates to OpenSleepController download
// protection and open:// WebUI push events.
class OpenBrowserService::DownloadObserverBridge final
    : public OpenDownloadBridge::Observer {
 public:
  explicit DownloadObserverBridge(OpenBrowserService* service)
      : service_(service) {}
  ~DownloadObserverBridge() override = default;

  void OnDownloadUpdatedForProfile(const ProfileID& profile_id,
                                   const DownloadRecord& record) override {
    if (!service_ || !service_->started()) {
      return;
    }
    // OpenLibraryUI::SetDownloadBridge installs its own DownloadEventForwarder
    // broadcasting kEventDownloadUpdated; avoid duplicating every progress tick
    // while still broadcasting if OpenLibraryUI is detached.
    if (webui::OpenLibraryUI::download_bridge() !=
        service_->download_bridge()) {
      service_->BroadcastEvent(
          webui::kEventDownloadUpdated,
          base::Value(json::DownloadToValue(record, profile_id)));
    }
  }

  void OnDownloadRemoved(const std::string& id) override {
    if (!service_ || !service_->started()) {
      return;
    }
    if (webui::OpenLibraryUI::download_bridge() !=
        service_->download_bridge()) {
      service_->BroadcastEvent(
          webui::kEventDownloadUpdated,
          base::Value(base::DictValue().Set("id", id).Set("removed", true)));
    }
  }

  void OnTabDownloadStateChanged(const ItemID& tab_id,
                                 bool is_downloading) override {
    if (service_ && service_->sleep_controller()) {
      service_->sleep_controller()->OnTabDownloadStateChanged(tab_id,
                                                              is_downloading);
    }
  }

 private:
  raw_ptr<OpenBrowserService> service_;
};

// Bridges OpenTabBridge lifecycle and activation events to OpenMediaBridge,
// OpenTranslateController, OpenHandoffController, and OpenLiveDataService.
class OpenBrowserService::TabObserverBridge final
    : public OpenTabBridge::Observer {
 public:
  explicit TabObserverBridge(OpenBrowserService* service) : service_(service) {}
  ~TabObserverBridge() override = default;

  void OnTabContentsAttached(const ItemID& tab_id,
                             content::WebContents* contents) override {
    if (service_) {
      service_->OnTabContentsAttachedBridge(tab_id, contents);
    }
  }

  void OnTabContentsDetaching(const ItemID& tab_id,
                              content::WebContents* contents) override {
    if (service_) {
      service_->OnTabContentsDetachingBridge(tab_id, contents);
    }
  }

  void OnTabPrimaryPageCommitted(const ItemID& tab_id,
                                 content::WebContents* contents) override {
    if (service_) {
      service_->OnTabPrimaryPageCommittedBridge(tab_id, contents);
    }
  }

  void OnTabActivated(const ItemID& tab_id) override {
    if (service_) {
      service_->OnTabActivatedBridge(tab_id);
    }
  }

 private:
  raw_ptr<OpenBrowserService> service_;
};

// Bridges per-Profile OpenAdBlockProfileService updates to open:// WebUI push
// events and debounced Sync pushes.
class OpenBrowserService::AdBlockObserverBridge final
    : public OpenAdBlockProfileService::Observer {
 public:
  explicit AdBlockObserverBridge(OpenBrowserService* service)
      : service_(service) {}
  ~AdBlockObserverBridge() override = default;

  void Observe(OpenAdBlockProfileService* adblock) {
    if (adblock && !observations_.IsObservingSource(adblock)) {
      observations_.AddObservation(adblock);
    }
  }

  void Unobserve(OpenAdBlockProfileService* adblock) {
    if (adblock && observations_.IsObservingSource(adblock)) {
      observations_.RemoveObservation(adblock);
    }
  }

  void OnAdBlockStateChanged(const std::string& profile_id) override {
    if (!service_ || !service_->started() || profile_id.empty()) {
      return;
    }
    service_->BroadcastEvent(
        webui::kEventAdBlockUpdated,
        base::Value(webui::OpenSettingsUI::AdBlockState(profile_id)));
    if (SyncEngine* sync = service_->sync();
        sync && sync->is_signed_in() && !sync->is_applying_remote()) {
      sync->ScheduleCollectionPush(
          SyncCollectionToString(SyncCollection::kAdblockConfig));
    }
  }

 private:
  raw_ptr<OpenBrowserService> service_;
  base::ScopedMultiSourceObservation<OpenAdBlockProfileService,
                                     OpenAdBlockProfileService::Observer>
      observations_{this};
};

ProfileServices::ProfileServices() = default;

ProfileServices::~ProfileServices() = default;

OpenAdBlockProfileService* ProfileServices::adblock() const {
  return chrome_profile
             ? OpenAdBlockProfileService::GetForBrowserContext(chrome_profile)
             : nullptr;
}

// ---------------------------------------------------------------------------
// OpenBrowserService

OpenBrowserService::OpenBrowserService(base::FilePath user_data_dir)
    : user_data_dir_(std::move(user_data_dir)) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  CHECK(!g_service);
  g_service = this;
  file_runner_ = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  // Blocking reads are still allowed here (PreBrowserStart, before content
  // disallows unresponsive tasks at the end of PreMainMessageLoopRun).
  LoadOrCreateState();
  commands_ = std::make_unique<CommandRegistry>();
  std::string error;
  const base::FilePath keybindings =
      user_data_dir_.AppendASCII(kStateDirName).AppendASCII(kKeybindingsFile);
  if (base::PathExists(keybindings) &&
      !commands_->LoadOverrides(keybindings, &error)) {
    LOG(WARNING) << "Open: keybindings.json ignored: " << error;
  }
  routing_ = std::make_unique<RoutingEvaluator>();
  // History lives on a store sequence, so SuggestEngine gets no store: its
  // history rows come from SetRecentHistory() (RefreshRecentHistory()).
  suggest_ = std::make_unique<SuggestEngine>(model_.get(), nullptr,
                                             commands_.get());
  window_controller_ = std::make_unique<OpenWindowController>(this);
}

OpenBrowserService::~OpenBrowserService() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  Shutdown();
  window_controller_.reset();
  model_->SetArchiveSink(nullptr);
  model_->RemoveObserver(this);
  if (g_service == this) {
    g_service = nullptr;
  }
}

// static
OpenBrowserService* OpenBrowserService::Get() {
  return g_service;
}

void OpenBrowserService::LoadOrCreateState() {
  const base::FilePath state_dir = user_data_dir_.AppendASCII(kStateDirName);
  base::CreateDirectory(state_dir);
  snapshot_store_ = std::make_unique<SnapshotStore>(user_data_dir_);
  // browser.json is serialized on the UI thread and written on Open's file
  // sequence (BLOCK_SHUTDOWN): debounced saves and the shutdown save never
  // block BrowserThread::UI.
  snapshot_store_->SetIoTaskRunner(file_runner_);
  std::vector<std::string> repairs;
  std::string error;
  model_ = snapshot_store_->Load(&repairs, &error);
  if (!model_) {
    // First run, or an unreadable snapshot (SnapshotStore keeps it aside):
    // one Profile, one Space, one window, then onboarding.
    first_run_ = !base::PathExists(snapshot_store_->file_path());
    if (!first_run_) {
      LOG(ERROR) << "Open: browser.json unusable (" << error
                 << "); starting with a default workspace";
    }
    model_ = std::make_unique<BrowserModel>();
  }
  model_->EnsureDefaultWorkspace();
  for (const std::string& repair : repairs) {
    VLOG(1) << "Open: browser.json repair: " << repair;
  }
  if (first_run_) {
    snapshot_store_->SaveNow(*model_);
  }
  onboarding_completed_ =
      base::PathExists(state_dir.AppendASCII(kOnboardingMarker));
  did_set_default_meet_route_ =
      base::PathExists(state_dir.AppendASCII(kMeetRouteMarker));

  // Complete any interrupted Profile disk deletions before Chromium opens any
  // Profile directories.
  FinishPendingProfileWipes();
  // Apply general.restoreWindows before any OS windows are created.
  ApplySessionRestorePreference();

  model_->AddObserver(this);
  model_->SetArchiveSink(this);
}

void OpenBrowserService::ApplySessionRestorePreference() {
  const base::FilePath prefs_path =
      user_data_dir_.AppendASCII(kStateDirName).AppendASCII(kPreferencesFile);
  bool restore_windows = true;
  std::string raw;
  if (base::PathExists(prefs_path) &&
      base::ReadFileToStringWithMaxSize(prefs_path, &raw, 1024 * 1024)) {
    if (auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC)) {
      if (std::optional<bool> pref = dict->FindBool("general.restoreWindows")) {
        restore_windows = *pref;
      }
    }
  }
  if (restore_windows) {
    return;
  }
  // Start clean: collapse saved multi-window/tab selections to one standard
  // window on the most recently focused Space with no restored active tab.
  SpaceID target_space;
  TimestampSec best_focus = -1.0;
  for (const BrowserWindowState& window : model_->windows()) {
    if (window.style != WindowStyle::kStandard || window.is_incognito) {
      continue;
    }
    const TimestampSec focused_at = window.last_focused_at.value_or(0.0);
    if (target_space.empty() || focused_at > best_focus) {
      if (model_->FindSpace(window.focused_space_id)) {
        target_space = window.focused_space_id;
        best_focus = focused_at;
      }
    }
  }
  if (target_space.empty() && !model_->spaces().empty()) {
    target_space = model_->spaces().front().id;
  }
  if (!target_space.empty()) {
    model_->ResetWindowsForCleanLaunch(target_space, {});
  }
}

void OpenBrowserService::FinishPendingProfileWipes() {
  const base::FilePath journal_path = user_data_dir_
                                          .AppendASCII(kProfilesDirName)
                                          .AppendASCII(kPendingWipeFile);
  std::vector<std::string> pending = ReadPendingWipeList(journal_path);
  if (pending.empty()) {
    return;
  }
  std::set<std::string> in_use;
  for (const Profile& profile : model_->profiles()) {
    in_use.insert(base::ToLowerASCII(profile.data_directory_name));
  }
  std::vector<std::string> remaining;
  for (const std::string& dir : pending) {
    if (in_use.contains(base::ToLowerASCII(dir))) {
      continue;  // Snapshot still references this Profile; never delete it.
    }
    const base::FilePath open_dir =
        user_data_dir_.AppendASCII(kProfilesDirName).AppendASCII(dir);
    const base::FilePath chrome_dir = user_data_dir_.AppendASCII(dir);
    bool ok = true;
    if (base::PathExists(open_dir) && !base::DeletePathRecursively(open_dir)) {
      ok = false;
    }
    if (base::PathExists(chrome_dir) &&
        !base::DeletePathRecursively(chrome_dir)) {
      ok = false;
    }
    if (!ok) {
      remaining.push_back(dir);
    }
  }
  WritePendingWipeList(journal_path, remaining);
}

void OpenBrowserService::Start() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (started_) {
    return;
  }
  started_ = true;

  // Ensure OTR AdBlock contexts resolve cleanly to their parent Profile.
  OpenAdBlockProfileServiceFactory::SetOriginalContextResolver(
      base::BindRepeating(
          [](content::BrowserContext* ctx) -> content::BrowserContext* {
            if (!ctx) {
              return nullptr;
            }
            return ::Profile::FromBrowserContext(ctx)->GetOriginalProfile();
          }));

  // App-wide Download bridge & AdBlock observer must exist before
  // StartProfiles() so CreateProfileServices() attaches every Profile.
  download_bridge_ = std::make_unique<OpenDownloadBridge>();
  download_observer_ = std::make_unique<DownloadObserverBridge>(this);
  download_bridge_->AddObserver(download_observer_.get());
  webui::OpenLibraryUI::SetDownloadBridge(download_bridge_.get());

  adblock_observer_ = std::make_unique<AdBlockObserverBridge>(this);

  StartProfiles();

  // Wave A-E services (Profiles and their StoragePartitions now exist).
  media_bridge_ = std::make_unique<OpenMediaBridge>();
  webui::OpenSettingsUI::SetMediaBridge(media_bridge_.get());

  livedata_ = std::make_unique<OpenLiveDataService>();
  RefreshNetworkFactories();
  SyncLiveDataFromModel();
  livedata_->Start();

  capture_controller_ = std::make_unique<OpenCaptureController>(user_data_dir_);
  translate_controller_ = std::make_unique<OpenTranslateController>(
      user_data_dir_.AppendASCII(kStateDirName));
  translate_controller_->SetOpenLanguageSettingsCallback(base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self) {
        if (self && self->window_controller_) {
          self->window_controller_->OpenSettingsWindow("general");
        }
      },
      weak_factory_.GetWeakPtr()));

  updater_ = std::make_unique<OpenUpdaterService>(
      ResolveActiveURLLoaderFactory(), webui::OpenSettingsUI::OpenVersion());
  handoff_ = std::make_unique<OpenHandoffController>();

  StartSync();
  ConfigureSyncFromCommandLine();

  tab_bridge_ = std::make_unique<OpenTabBridge>(this);
  tab_observer_ = std::make_unique<TabObserverBridge>(this);
  tab_bridge_->AddObserver(tab_observer_.get());
  sleep_controller_ = std::make_unique<OpenSleepController>(this);
  boost_controller_ = std::make_unique<OpenBoostController>(this);

  // Adopts Chromium's startup Browser (or opens one), mirrors loaded tabs
  // into the real TabStripModel and selects the saved node.
  tab_bridge_->Start();
  sleep_controller_->Start();
  window_controller_->Start();
  // The command bar's history rows (SuggestEngine never touches SQLite).
  RefreshRecentHistory();

  // Periodic Auto-Archive sweeper (60s + startup + system wakeup).
  StartAutoArchiveSweeper();

  // Apply live runtime preferences (downloads, Auto-PiP, Offer Translate,
  // App Icon, Boosts, Global Little Open hotkey) once loaded.
  webui::OpenPreferences::Get()->WhenLoaded(base::BindOnce(
      &OpenBrowserService::ApplyPreferencesInternal,
      weak_factory_.GetWeakPtr(), /*schedule_sync_push=*/false));

  const base::CommandLine& command_line =
      *base::CommandLine::ForCurrentProcess();
  if (first_run_ && !onboarding_completed_ &&
      !command_line.HasSwitch(switches::kSkipOnboarding)) {
    window_controller_->OpenFirstRunWindow();
  }

  MaybeStartAutomationServer();
  FlushPendingExternalUrls();
}

void OpenBrowserService::Shutdown() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!started_) {
    return;
  }
  started_ = false;
  auto_archive_timer_.Stop();
  little_open_last_active_.clear();
  if (power_observer_registered_) {
    if (base::PowerMonitor* pm = base::PowerMonitor::GetInstance()) {
      pm->RemovePowerSuspendObserver(this);
    }
    power_observer_registered_ = false;
  }
  if (global_hotkey_registered_) {
    if (OpenPlatform* platform = OpenPlatform::Get()) {
      platform->UnregisterGlobalHotkey(kLittleOpenGlobalHotkeyId);
    }
    global_hotkey_registered_ = false;
  }
#if BUILDFLAG(OPEN_ENABLE_AUTOMATION)
  automation_server_.reset();
#endif
  if (sleep_controller_) {
    sleep_controller_->Shutdown();
  }
  // Serialized here, written on |file_runner_| (BLOCK_SHUTDOWN: the write
  // completes before the process exits; the UI thread does not wait).
  std::string error;
  if (!snapshot_store_->SaveNow(*model_, &error)) {
    LOG(ERROR) << "Open: browser.json not saved at shutdown: " << error;
  }

  // Shut down windows and detach UI observers BEFORE tearing down the
  // services they observe (DownloadBridge, MediaBridge, LiveData, Capture,
  // Translate, Handoff, Updater).
  window_controller_->Shutdown();

  // Tear down Sync (and its WebSocket client) before Profiles/stores vanish.
  if (sync_) {
    sync_->SetNetworkContextProvider({});
    sync_->Shutdown();
  }
  sync_.reset();
  sync_adapter_.reset();

  // Tear down Handoff, Updater, LiveData, Capture, and Translate before
  // tab_bridge_ and profiles_ disappear.
  if (handoff_) {
    handoff_->Invalidate();
    handoff_.reset();
  }
  last_handoff_tab_id_.clear();
  active_tab_by_window_.clear();
  last_active_tab_id_.clear();

  if (updater_) {
    updater_->CancelPendingCheck();
    updater_->SetURLLoaderFactory(nullptr);
    updater_.reset();
  }
  if (livedata_) {
    livedata_->Stop();
    livedata_->SetURLLoaderFactory(nullptr);
    livedata_.reset();
  }
  livedata_url_loader_factory_.reset();
  registered_live_folders_.clear();
  registered_calendar_favorites_.clear();

  if (capture_controller_) {
    capture_controller_->Cancel();
    capture_controller_.reset();
  }
  if (translate_controller_) {
    translate_controller_->ClosePopover();
    translate_controller_.reset();
  }

  // Detach MediaBridge & tab observer before tab_bridge_ tears down tabs.
  webui::OpenSettingsUI::SetMediaBridge(nullptr);
  if (tab_bridge_ && tab_observer_) {
    tab_bridge_->RemoveObserver(tab_observer_.get());
  }
  tab_observer_.reset();
  if (media_bridge_) {
    media_bridge_->UntrackAll();
    media_bridge_.reset();
  }

  boost_controller_.reset();
  sleep_controller_.reset();
  if (tab_bridge_) {
    tab_bridge_->Shutdown();
  }
  tab_bridge_.reset();

  // Clear Library hook, download observer, and Profile bindings BEFORE
  // destroying profiles_ (ProfileServices::downloads and chrome_profile).
  webui::OpenLibraryUI::SetDownloadBridge(nullptr);
  if (download_bridge_ && download_observer_) {
    download_bridge_->RemoveObserver(download_observer_.get());
  }
  download_observer_.reset();
  if (download_bridge_) {
    download_bridge_->DetachAll();
    download_bridge_.reset();
  }

  // Clear AdBlock observations before destroying profiles_.
  adblock_observer_.reset();
  OpenAdBlockProfileServiceFactory::SetOriginalContextResolver({});

  // SequenceBound posts each store's destruction to its runner
  // (BLOCK_SHUTDOWN), so pending writes finish.
  profile_observations_.RemoveAllObservations();
  profiles_.clear();
  pending_external_urls_.clear();
  if (OpenPlatform* platform = OpenPlatform::Get()) {
    platform->Shutdown();
  }
}

void OpenBrowserService::StartProfiles() {
  for (const Profile& profile : model_->profiles()) {
    ProfileServices* s = ProfileServicesFor(profile.id);
    if (!s || !s->chrome_profile) {
      continue;
    }
    // A startup window (hook 0002 between PreBrowserStart and PostBrowserStart)
    // may have materialized ProfileServices before Start() constructed
    // download_bridge_ and adblock_observer_. Ensure every Profile is attached
    // and observed now.
    if (download_bridge_ && !download_bridge_->HasProfile(s->chrome_profile)) {
      download_bridge_->AttachProfile(s->chrome_profile, profile.id,
                                      &s->downloads);
      OpenDownloadBridge::ApplyDownloadPreferences(
          s->chrome_profile, profile.settings.download_directory,
          profile.settings.ask_where_to_save_each_file);
    }
    if (adblock_observer_) {
      if (OpenAdBlockProfileService* adblock = s->adblock()) {
        adblock->SetProfileId(profile.id);
        adblock_observer_->Observe(adblock);
      }
    }
  }
}

base::FilePath OpenBrowserService::ChromeProfileDir(
    const Profile& profile) const {
  return user_data_dir_.AppendASCII(profile.data_directory_name);
}

base::FilePath OpenBrowserService::OpenProfileDir(
    const Profile& profile) const {
  return user_data_dir_.AppendASCII(kProfilesDirName)
      .AppendASCII(profile.data_directory_name);
}

ProfileServices* OpenBrowserService::ProfileServicesFor(const ProfileID& id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (auto it = profiles_.find(id); it != profiles_.end()) {
    return it->second.get();
  }
  const Profile* profile = model_->FindProfile(id);
  if (!profile) {
    return nullptr;
  }
  if (destroying_profile_) {
    return nullptr;  // Never reload a Profile from its destruction.
  }
  // Synchronous for Profiles present at startup (the first window needs
  // them); Profiles created later go through CreateProfile() (async).
  ::Profile* chrome_profile =
      g_browser_process->profile_manager()->GetProfile(
          ChromeProfileDir(*profile));
  if (!chrome_profile) {
    LOG(ERROR) << "Open: cannot open the Chromium Profile of " << id;
    return nullptr;
  }
  auto services = CreateProfileServices(*profile, chrome_profile);
  ProfileServices* raw = services.get();
  profiles_.emplace(id, std::move(services));
  return raw;
}

std::unique_ptr<ProfileServices> OpenBrowserService::CreateProfileServices(
    const Profile& profile,
    ::Profile* chrome_profile) {
  auto s = std::make_unique<ProfileServices>();
  s->id = profile.id;
  s->chrome_profile = chrome_profile;
  const base::FilePath profile_dir = OpenProfileDir(profile);
  s->state_dir = profile_dir.AppendASCII(kStateDirName);

  s->store_runner = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  // Directories first, on the store sequence (ordered before every Open()).
  s->store_runner->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::FilePath state_dir) {
                       base::CreateDirectory(state_dir);
                     },
                     s->state_dir));
  s->history.emplace(s->store_runner,
                     s->state_dir.AppendASCII("History.sqlite"));
  s->archive.emplace(s->store_runner,
                     s->state_dir.AppendASCII("Archive.sqlite"));
  s->sleep.emplace(s->store_runner, s->state_dir.AppendASCII("Sleep.sqlite"));
  s->downloads.emplace(s->store_runner,
                       s->state_dir.AppendASCII("Downloads.sqlite"));
  s->favicons.emplace(s->store_runner,
                      s->state_dir.AppendASCII("Favicons.sqlite"));
  OpenStore(s->history);
  OpenStore(s->archive);
  OpenStore(s->sleep);
  OpenStore(s->downloads);
  OpenStore(s->favicons);
  s->boosts.emplace(s->store_runner, profile.id, profile_dir);
  RunOnStore(s->boosts, base::BindOnce([](BoostStore* store) {
               store->Load();
             }));
  s->documents.emplace(s->store_runner, profile_dir);

  s->extensions = std::make_unique<OpenExtensionBridge>(this, chrome_profile);
  if (!profile_observations_.IsObservingSource(chrome_profile)) {
    profile_observations_.AddObservation(chrome_profile);
  }
  if (window_controller_) {
    window_controller_->ObserveExtensionBridge(s->extensions.get());
  }
  // Attach DownloadManager to OpenDownloadBridge and sync download prefs.
  if (download_bridge_) {
    download_bridge_->AttachProfile(chrome_profile, profile.id, &s->downloads);
    OpenDownloadBridge::ApplyDownloadPreferences(
        chrome_profile, profile.settings.download_directory,
        profile.settings.ask_where_to_save_each_file);
  }
  // Eagerly initialize OpenAdBlockProfileService so bundled EasyList,
  // EasyPrivacy, and resources.json seed immediately before first navigation.
  if (OpenAdBlockProfileService* adblock =
          OpenAdBlockProfileService::GetForBrowserContext(chrome_profile)) {
    adblock->SetProfileId(profile.id);
    if (adblock_observer_) {
      adblock_observer_->Observe(adblock);
    }
  }
  return s;
}

ProfileServices* OpenBrowserService::ProfileServicesForBrowserContext(
    content::BrowserContext* context) {
  std::optional<ProfileID> id = OpenProfileIdFor(context);
  return id ? ProfileServicesFor(*id) : nullptr;
}

std::optional<ProfileID> OpenBrowserService::OpenProfileIdFor(
    content::BrowserContext* context) {
  if (!context) {
    return std::nullopt;
  }
  // Incognito windows belong to their original Profile's Open Profile; the
  // stores never record OTR data (callers check IsOffTheRecord()).
  ::Profile* original =
      ::Profile::FromBrowserContext(context)->GetOriginalProfile();
  for (const auto& [id, services] : profiles_) {
    if (services->chrome_profile == original) {
      return id;
    }
  }
  return std::nullopt;
}

::Profile* OpenBrowserService::ChromeProfileFor(const ProfileID& id) {
  ProfileServices* services = ProfileServicesFor(id);
  return services ? services->chrome_profile.get() : nullptr;
}

ProfileID OpenBrowserService::ActiveProfileId() const {
  const WindowID active_win = ActiveWindowId();
  if (!active_win.empty()) {
    if (const BrowserWindowState* window = model_->FindWindow(active_win)) {
      if (window->incognito_profile_id.has_value() &&
          !window->incognito_profile_id->empty()) {
        return *window->incognito_profile_id;
      }
      if (const Space* space = model_->FindSpace(window->focused_space_id)) {
        return space->profile_id;
      }
    }
  }
  const auto& windows = model_->windows();
  if (!windows.empty()) {
    if (const Space* space =
            model_->FindSpace(windows.front().focused_space_id)) {
      return space->profile_id;
    }
  }
  const Profile* fallback = model_->DefaultProfile();
  return fallback ? fallback->id : ProfileID();
}

WindowID OpenBrowserService::MainWindowId() const {
  const auto& windows = model_->windows();
  for (const BrowserWindowState& window : windows) {
    if (window.style == WindowStyle::kStandard && !window.is_incognito) {
      return window.id;
    }
  }
  return windows.empty() ? WindowID() : windows.front().id;
}

WindowID OpenBrowserService::ActiveWindowId() const {
  if (tab_bridge_) {
    const WindowID focused = tab_bridge_->FocusedWindowId();
    if (!focused.empty()) {
      return focused;
    }
  }
  return MainWindowId();
}

WindowID OpenBrowserService::ReopenLastClosedWindow() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  WindowID restored = model_->RestoreLastClosedWindow();
  if (restored.empty()) {
    return tab_bridge_ ? tab_bridge_->OpenNewWindow() : WindowID();
  }
  if (tab_bridge_) {
    if (const BrowserWindowState* window = model_->FindWindow(restored)) {
      tab_bridge_->FocusSpace(window->focused_space_id, restored);
    }
  }
  ScheduleSave();
  return restored;
}

bool OpenBrowserService::IsIncognitoWindow(const WindowID& window_id) const {
  if (tab_bridge_) {
    return tab_bridge_->IsIncognitoWindow(window_id);
  }
  return model_->IsIncognitoWindow(window_id);
}

void OpenBrowserService::StartAutoArchiveSweeper() {
  if (!power_observer_registered_) {
    if (base::PowerMonitor* pm = base::PowerMonitor::GetInstance()) {
      pm->AddPowerSuspendObserver(this);
      power_observer_registered_ = true;
    }
  }
  auto_archive_timer_.Start(
      FROM_HERE, kAutoArchiveSweepInterval,
      base::BindRepeating(&OpenBrowserService::RunAutoArchiveSweep,
                          weak_factory_.GetWeakPtr()));
  // Run an immediate startup sweep on the next task after startup finishes.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&OpenBrowserService::RunAutoArchiveSweep,
                                weak_factory_.GetWeakPtr()));
}

void OpenBrowserService::OnSuspend() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (livedata_) {
    livedata_->SetPowerSuspended(true);
  }
}

void OpenBrowserService::OnResume() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (livedata_) {
    livedata_->SetPowerSuspended(false);
  }
  if (started_) {
    RunAutoArchiveSweep();
  }
}

void OpenBrowserService::RunAutoArchiveSweep() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!started_) {
    return;
  }
  const TimestampSec now = NowSec();
  std::vector<ItemID> archived_ids;
  const size_t archived_count = model_->ArchiveExpiredTabs(now, &archived_ids);
  if (archived_count > 0) {
    // Cleanly close/unload any Chromium WebContents still attached to expired
    // tabs (ArchiveSink already synced records to each Profile's ArchiveStore).
    if (tab_bridge_) {
      for (const ItemID& id : archived_ids) {
        tab_bridge_->UnloadTab(id);
      }
    }
    ScheduleSave();
  }
  SweepExpiredLittleOpens(now);
}

void OpenBrowserService::SweepExpiredLittleOpens(TimestampSec now) {
  if (!window_controller_) {
    return;
  }
  std::set<OpenLittleOpenController*> alive;
  for (const auto& controller : window_controller_->little_opens()) {
    OpenLittleOpenController* raw = controller.get();
    alive.insert(raw);
    little_open_last_active_.try_emplace(raw, now);
  }
  std::erase_if(little_open_last_active_, [&](const auto& entry) {
    return !alive.contains(entry.first.get());
  });

  std::vector<OpenLittleOpenController*> expired;
  for (const auto& [controller, last_active] : little_open_last_active_) {
    const Profile* profile = model_->FindProfile(controller->profile_id());
    if (!profile) {
      continue;
    }
    auto threshold =
        AutoArchiveSeconds(profile->settings.little_open_auto_archive_after);
    if (!threshold.has_value()) {
      continue;
    }
    if ((now - last_active) >= *threshold) {
      expired.push_back(controller.get());
    }
  }

  std::vector<ArchivedTabRecord> records;
  for (OpenLittleOpenController* controller : expired) {
    if (content::WebContents* wc = controller->page()) {
      const GURL url = wc->GetLastCommittedURL().is_valid()
                           ? wc->GetLastCommittedURL()
                           : wc->GetVisibleURL();
      if (url.is_valid() && url.SchemeIsHTTPOrHTTPS()) {
        ArchivedTabRecord rec;
        rec.id = GenerateUuidV4();
        rec.url = url.spec();
        rec.title = base::UTF16ToUTF8(wc->GetTitle());
        if (rec.title.empty()) {
          rec.title = rec.url;
        }
        rec.profile_id = controller->profile_id();
        rec.archived_at = now;
        rec.reason = "auto-archive";
        rec.original_location = "little-open";
        rec.payload_json = "{}";
        rec.kind = "tab";
        records.push_back(std::move(rec));
      }
    }
    little_open_last_active_.erase(controller);
    controller->Close();
  }
  if (!records.empty()) {
    OnArchiveTabs(records);
  }
}

void OpenBrowserService::ReloadGlobalHotkeys() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!started_) {
    return;
  }
  OpenPlatform* platform = OpenPlatform::Get();
  if (!platform) {
    return;
  }
  if (global_hotkey_registered_) {
    platform->UnregisterGlobalHotkey(kLittleOpenGlobalHotkeyId);
    global_hotkey_registered_ = false;
  }
  const base::Value pref =
      webui::OpenPreferences::Get()->GetValue("links.littleOpenHotkey");
  if (pref.is_bool() && !pref.GetBool()) {
    return;
  }
  std::optional<KeyboardShortcut> shortcut;
  if (pref.is_string()) {
    const std::string lower = base::ToLowerASCII(
        base::TrimWhitespaceASCII(pref.GetString(), base::TRIM_ALL));
    if (lower.empty() || lower == "off" || lower == "none" ||
        lower == "disabled") {
      return;
    }
    shortcut = ParseHotkeyPrefString(pref.GetString());
  }
  const auto registered =
      commands_->EffectiveShortcuts(CommandId::kLittleOpenGlobal);
  if (!registered.empty() &&
      (!shortcut.has_value() ||
       commands_->overrides().contains(kLittleOpenGlobalHotkeyId))) {
    shortcut = registered.front();
  }
  if (!shortcut.has_value()) {
    return;
  }
  auto spec = BuildGlobalHotkeySpec(kLittleOpenGlobalHotkeyId, *shortcut);
  if (!spec.has_value()) {
    return;
  }
  // Global hotkey callbacks can fire from a platform thread/event loop; hop
  // cleanly onto BrowserThread::UI.
  scoped_refptr<base::SequencedTaskRunner> ui_runner =
      base::SequencedTaskRunner::GetCurrentDefault();
  auto weak_self = weak_factory_.GetWeakPtr();
  global_hotkey_registered_ = platform->RegisterGlobalHotkey(
      *spec,
      base::BindRepeating(
          [](scoped_refptr<base::SequencedTaskRunner> runner,
             base::WeakPtr<OpenBrowserService> self, const std::string& id) {
            runner->PostTask(
                FROM_HERE,
                base::BindOnce(&OpenBrowserService::OnLittleOpenGlobalHotkey,
                               self, id));
          },
          std::move(ui_runner), weak_self));
}

void OpenBrowserService::OnLittleOpenGlobalHotkey(const std::string& /*id*/) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!started_ || !window_controller_) {
    return;
  }
  window_controller_->OpenLittleOpen(std::nullopt);
}

OpenViewController* OpenBrowserService::view_controller() {
  return window_controller_.get();
}

OpenExtensionBridge* OpenBrowserService::extension_bridge() {
  ProfileServices* services = ProfileServicesFor(ActiveProfileId());
  return services ? services->extensions.get() : nullptr;
}

std::vector<OpenExtensionBridge*> OpenBrowserService::AllExtensionBridges() {
  std::vector<OpenExtensionBridge*> bridges;
  for (const auto& [id, services] : profiles_) {
    if (services->extensions) {
      bridges.push_back(services->extensions.get());
    }
  }
  return bridges;
}

void OpenBrowserService::OnProfileWillBeDestroyed(::Profile* profile) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (profile_observations_.IsObservingSource(profile)) {
    profile_observations_.RemoveObservation(profile);
  }
  auto it = std::find_if(profiles_.begin(), profiles_.end(),
                         [profile](const auto& entry) {
                           return entry.second->chrome_profile == profile;
                         });
  if (it == profiles_.end()) {
    return;
  }
  base::AutoReset<raw_ptr<::Profile>> destroying(&destroying_profile_,
                                                 profile);
  const ProfileID id = it->first;
  std::unique_ptr<ProfileServices> services = std::move(it->second);
  profiles_.erase(it);
  if (download_bridge_ && services->chrome_profile) {
    download_bridge_->DetachProfile(services->chrome_profile);
  }
  if (adblock_observer_ && services->chrome_profile) {
    adblock_observer_->Unobserve(services->adblock());
  }
  if (window_controller_ && services->extensions) {
    window_controller_->UnobserveExtensionBridge(services->extensions.get());
  }
  // Rebind LiveData/Updater network factories off the dying Profile before
  // destroying ProfileServices.
  RefreshNetworkFactories();
  // Stores go to their sequence for destruction; the extension bridge drops
  // its ToolbarActionsModel / ExtensionRegistry observations while those
  // KeyedServices still exist.
  services.reset();
  if (started_ && id == recent_history_profile_) {
    // The command bar must not keep rows of a Profile that is gone.
    suggest_->SetRecentHistory({});
  }
}

void OpenBrowserService::CreateProfile(
    const std::string& name,
    std::optional<SpaceIcon> icon,
    base::OnceCallback<void(ProfileID)> done) {
  const ProfileID id = model_->CreateProfile(name, std::move(icon));
  const Profile* profile = model_->FindProfile(id);
  if (!profile) {
    std::move(done).Run(ProfileID());
    return;
  }
  g_browser_process->profile_manager()->CreateProfileAsync(
      ChromeProfileDir(*profile),
      base::BindOnce(&OpenBrowserService::OnNewChromeProfileReady,
                     weak_factory_.GetWeakPtr(), id, std::move(done)));
}

void OpenBrowserService::OnNewChromeProfileReady(
    ProfileID id,
    base::OnceCallback<void(ProfileID)> done,
    ::Profile* chrome_profile) {
  const Profile* profile = model_->FindProfile(id);
  if (chrome_profile && profile && !profiles_.contains(id)) {
    profiles_.emplace(id, CreateProfileServices(*profile, chrome_profile));
  }
  std::move(done).Run(chrome_profile ? id : ProfileID());
}

bool OpenBrowserService::DeleteProfileData(
    const ProfileID& profile_id,
    base::OnceCallback<void(bool)> done) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  const Profile* profile = model_->FindProfile(profile_id);
  if (!profile ||
      model_->GetProfileDeleteBlock(profile_id) != ProfileDeleteBlock::kNone) {
    if (done) {
      std::move(done).Run(false);
    }
    return false;
  }
  const std::string dir_name = profile->data_directory_name;
  if (!IsSafeProfileDirectoryName(dir_name)) {
    if (done) {
      std::move(done).Run(false);
    }
    return false;
  }
  const base::FilePath chrome_dir = ChromeProfileDir(*profile);
  const base::FilePath open_dir = OpenProfileDir(*profile);
  const base::FilePath journal_path = user_data_dir_
                                          .AppendASCII(kProfilesDirName)
                                          .AppendASCII(kPendingWipeFile);

  // 1. Close any Little Open windows and OS browsers belonging to this Profile.
  if (window_controller_) {
    std::vector<OpenLittleOpenController*> doomed_lo;
    for (const auto& lo : window_controller_->little_opens()) {
      if (lo->profile_id() == profile_id) {
        doomed_lo.push_back(lo.get());
      }
    }
    for (OpenLittleOpenController* lo : doomed_lo) {
      little_open_last_active_.erase(lo);
      lo->Close();
    }
  }
  if (tab_bridge_) {
    tab_bridge_->CloseBrowsersForProfile(profile_id);
  }

  // 2. Remove from BrowserModel and persist browser.json immediately so a
  // crash during disk cleanup never resurrects an empty Profile.
  if (!model_->DeleteProfile(profile_id)) {
    if (done) {
      std::move(done).Run(false);
    }
    return false;
  }
  snapshot_store_->SaveNow(*model_);

  // 3. Tear down ProfileServices cleanly (closing all SQLite stores on their
  // store_runner before removing directories).
  scoped_refptr<base::SequencedTaskRunner> cleanup_runner = file_runner_;
  if (auto it = profiles_.find(profile_id); it != profiles_.end()) {
    std::unique_ptr<ProfileServices> services = std::move(it->second);
    profiles_.erase(it);
    if (download_bridge_ && services->chrome_profile) {
      download_bridge_->DetachProfile(services->chrome_profile);
    }
    if (adblock_observer_ && services->chrome_profile) {
      adblock_observer_->Unobserve(services->adblock());
    }
    if (services->chrome_profile &&
        profile_observations_.IsObservingSource(services->chrome_profile)) {
      profile_observations_.RemoveObservation(services->chrome_profile);
    }
    if (window_controller_ && services->extensions) {
      window_controller_->UnobserveExtensionBridge(services->extensions.get());
    }
    RefreshNetworkFactories();
    if (services->store_runner) {
      cleanup_runner = services->store_runner;
    }
    // SequenceBound posts each SQLite store's destructor onto store_runner;
    // any task posted to cleanup_runner right after this runs strictly AFTER
    // all SQLite file handles are closed!
    services.reset();
  }
  if (started_ && profile_id == recent_history_profile_) {
    suggest_->SetRecentHistory({});
  }

  // 4. Schedule Chromium ProfileManager deletion for the Chromium profile dir.
  if (g_browser_process && g_browser_process->profile_manager()) {
    g_browser_process->profile_manager()
        ->GetDeleteProfileHelper()
        .MaybeScheduleProfileForDeletion(
            chrome_dir, base::DoNothing(),
            ProfileMetrics::DELETE_PROFILE_SETTINGS);
  }

  // 5. Journal the wipe and remove Open's Boosts/AdBlock/Documents/State
  // folder on disk after all SQLite stores have closed.
  cleanup_runner->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(
          [](base::FilePath journal_path, std::string dir_name,
             base::FilePath open_dir) -> bool {
            std::vector<std::string> pending =
                ReadPendingWipeList(journal_path);
            if (std::find(pending.begin(), pending.end(), dir_name) ==
                pending.end()) {
              pending.push_back(dir_name);
              WritePendingWipeList(journal_path, pending);
            }
            bool ok = true;
            if (base::PathExists(open_dir)) {
              ok = base::DeletePathRecursively(open_dir);
            }
            if (ok) {
              std::erase(pending, dir_name);
              WritePendingWipeList(journal_path, pending);
            }
            return ok;
          },
          journal_path, dir_name, open_dir),
      base::BindOnce(
          [](base::OnceCallback<void(bool)> done, bool ok) {
            if (done) {
              std::move(done).Run(ok);
            }
          },
          std::move(done)));
  return true;
}

void OpenBrowserService::ScheduleSave() {
  snapshot_store_->ScheduleSave(model_.get());
}

void OpenBrowserService::PersistShortcuts() {
  // CommandRegistry is UI-thread state; a copy of the overrides is written
  // by a registry that exists only for the write.
  const auto overrides = commands_->overrides();
  const base::FilePath path =
      user_data_dir_.AppendASCII(kStateDirName).AppendASCII(kKeybindingsFile);
  file_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::unordered_map<std::string, KeyBindingOverride> overrides,
             base::FilePath path) {
            CommandRegistry writer;
            for (auto& [id, value] : overrides) {
              writer.SetOverride(id, std::move(value));
            }
            std::string error;
            if (!writer.SaveOverrides(path, &error)) {
              LOG(ERROR) << "Open: keybindings.json not saved: " << error;
            }
          },
          overrides, path));
  // Open's window accelerators (Find, Ctrl+Tab, Little Open) and global
  // Little Open hotkey follow.
  window_controller_->ReloadShortcuts();
  ReloadGlobalHotkeys();
  if (sync_ && sync_->is_signed_in() && !sync_->is_applying_remote()) {
    sync_->ScheduleCollectionPush(
        SyncCollectionToString(SyncCollection::kSettingsKeybindings));
  }
}

void OpenBrowserService::RecordVisit(const ProfileID& profile_id,
                                     const std::string& url,
                                     const std::string& title,
                                     bool typed) {
  ProfileServices* services = ProfileServicesFor(profile_id);
  if (!services) {
    return;
  }
  if (profile_id != ActiveProfileId()) {
    RunOnStore(services->history,
               base::BindOnce(
                   [](std::string url, std::string title, TimestampSec now,
                      bool typed, HistoryStore* store) {
                     store->RecordVisit(url, title, now,
                                        typed ? "typed" : "link", typed);
                   },
                   url, title, NowSec(), typed));
    return;
  }
  // Active Profile: the same store task reads the newest entries back, so
  // the visit is in the command bar's rows without a second round trip.
  recent_history_profile_ = profile_id;
  const uint64_t generation = ++recent_history_generation_;
  RunOnStore(services->history,
             base::BindOnce(
                 [](std::string url, std::string title, TimestampSec now,
                    bool typed, HistoryStore* store) {
                   store->RecordVisit(url, title, now,
                                      typed ? "typed" : "link", typed);
                   return store->Recent(kRecentHistoryLimit);
                 },
                 url, title, NowSec(), typed),
             base::BindOnce(&OpenBrowserService::OnRecentHistoryLoaded,
                            weak_factory_.GetWeakPtr(), profile_id,
                            generation));
}

void OpenBrowserService::RefreshRecentHistory() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  const ProfileID profile_id = ActiveProfileId();
  recent_history_profile_ = profile_id;
  const uint64_t generation = ++recent_history_generation_;
  ProfileServices* services =
      profile_id.empty() ? nullptr : ProfileServicesFor(profile_id);
  if (!services) {
    suggest_->SetRecentHistory({});
    return;
  }
  RunOnStore(services->history,
             base::BindOnce([](HistoryStore* store) {
               return store->Recent(kRecentHistoryLimit);
             }),
             base::BindOnce(&OpenBrowserService::OnRecentHistoryLoaded,
                            weak_factory_.GetWeakPtr(), profile_id,
                            generation));
}

void OpenBrowserService::OnRecentHistoryLoaded(
    ProfileID profile_id,
    uint64_t generation,
    std::vector<HistoryEntry> entries) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (generation != recent_history_generation_ ||
      profile_id != recent_history_profile_) {
    return;  // A newer request (or another Profile) wins.
  }
  suggest_->SetRecentHistory(std::move(entries));
}

void OpenBrowserService::OnArchiveTabs(
    const std::vector<ArchivedTabRecord>& records) {
  // Records carry their Profile; each Profile has its own Archive.sqlite.
  std::map<ProfileID, std::vector<ArchivedTabRecord>> by_profile;
  for (const ArchivedTabRecord& record : records) {
    by_profile[record.profile_id.value_or(ActiveProfileId())].push_back(
        record);
  }
  std::vector<ArchivedTabRecord> closed_by_user;
  for (const ArchivedTabRecord& record : records) {
    if (record.reason == "closed") {
      closed_by_user.push_back(record);
    }
  }
  for (auto& [profile_id, list] : by_profile) {
    ProfileServices* services = ProfileServicesFor(profile_id);
    if (!services) {
      continue;
    }
    RunOnStore(services->archive,
               base::BindOnce(
                   [](std::vector<ArchivedTabRecord> list, ArchiveStore* s) {
                     s->Archive(list);
                   },
                   std::move(list)));
  }
  // A user close (not auto-archive, Clear Today or a deleted Space): the
  // "Tab Archived" toast with Undo. Its Restore() runs on the same store
  // sequence, after the Archive() above.
  if (!closed_by_user.empty() && window_controller_) {
    window_controller_->OnTabsArchivedByUser(std::move(closed_by_user));
  }
}

void OpenBrowserService::OnDiscardArchived(const std::vector<ItemID>& ids) {
  for (auto& [profile_id, services] : profiles_) {
    RunOnStore(services->archive,
               base::BindOnce(
                   [](std::vector<ItemID> ids, ArchiveStore* s) {
                     s->DeleteIds(ids);
                   },
                   ids));
  }
}

void OpenBrowserService::MarkOnboardingCompleted() {
  onboarding_completed_ = true;
  file_runner_->PostTask(
      FROM_HERE,
      base::BindOnce([](base::FilePath path) { base::WriteFile(path, "1"); },
                     user_data_dir_.AppendASCII(kStateDirName)
                         .AppendASCII(kOnboardingMarker)));
}

void OpenBrowserService::AddObserver(Observer* observer) {
  observers_.AddObserver(observer);
}

void OpenBrowserService::RemoveObserver(Observer* observer) {
  observers_.RemoveObserver(observer);
}

void OpenBrowserService::BroadcastEvent(const std::string& event_name,
                                        base::Value payload) {
  for (Observer& observer : observers_) {
    observer.OnOpenEvent(event_name, payload);
  }
}

void OpenBrowserService::OnTreeChanged(const TreeChange& change) {
  const bool is_incognito_change =
      (!change.space_id.empty() && model_->IsIncognitoSpace(change.space_id)) ||
      (!change.node_id.empty() && model_->IsIncognitoNode(change.node_id)) ||
      ((change.parent.kind == NodeParentKind::kSpacePinned ||
        change.parent.kind == NodeParentKind::kSpaceToday) &&
       model_->IsIncognitoSpace(change.parent.owner_id));
  // Ephemeral Incognito state NEVER dirties browser.json.
  if (!is_incognito_change) {
    // Title/URL updates take the snapshot store's slower metadata path.
    if (change.kind == TreeChange::Kind::kUpdate) {
      snapshot_store_->ScheduleMetadataSave(model_.get());
    } else {
      ScheduleSave();
    }
    if (sync_ && sync_->is_signed_in() && !sync_->is_applying_remote()) {
      if (change.parent.kind == NodeParentKind::kSpaceToday) {
        sync_->ScheduleCollectionPush(
            SyncCollectionToString(SyncCollection::kWorkspaceToday),
            change.parent.owner_id);
      } else if (change.parent.kind == NodeParentKind::kFavorites) {
        sync_->ScheduleCollectionPush(
            SyncCollectionToString(SyncCollection::kWorkspaceProfile),
            change.parent.owner_id);
      } else if (!change.space_id.empty()) {
        sync_->ScheduleCollectionPush(
            SyncCollectionToString(SyncCollection::kWorkspaceSpace),
            change.space_id);
      } else {
        sync_->ScheduleCollectionPush(
            SyncCollectionToString(SyncCollection::kWorkspaceMeta));
      }
    }
  }
  if (change.kind == TreeChange::Kind::kSpaceProfileChanged) {
    ProfileServicesFor(change.to_profile_id);
  }
  if (started_) {
    if (change.kind == TreeChange::Kind::kUpdate && !change.node_id.empty()) {
      if (handoff_ && tab_bridge_ &&
          tab_bridge_->ActiveTabId() == change.node_id) {
        UpdateHandoffForTab(change.node_id,
                            tab_bridge_->WebContentsForTab(change.node_id));
      }
      if (livedata_ && model_->IsFavorite(change.node_id) &&
          !model_->IsIncognitoNode(change.node_id)) {
        if (const Tab* tab = model_->FindTab(change.node_id)) {
          livedata_->UpdateTabTitleForBadge(tab->id, tab->url, tab->title);
          if (OpenLiveDataService::IsCalendarFavoriteUrl(tab->url)) {
            livedata_->IngestCalendarTabMetadata(tab->id, tab->url, tab->title);
          }
        }
      }
    } else if (livedata_ && !is_incognito_change) {
      SyncLiveDataFromModel();
    }
  }
  // Switching to a Space of another Profile swaps the history feed.
  if (started_ && ActiveProfileId() != recent_history_profile_) {
    RefreshRecentHistory();
  }
  // One coalesced open.stateChanged per task, not one per change.
  if (!state_event_pending_ && !observers_.empty()) {
    state_event_pending_ = true;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&OpenBrowserService::BroadcastStateChanged,
                                  weak_factory_.GetWeakPtr()));
  }
}

void OpenBrowserService::BroadcastStateChanged() {
  state_event_pending_ = false;
  BroadcastEvent(webui::kEventStateChanged, base::Value(base::DictValue()));
}

void OpenBrowserService::MaybeStartAutomationServer() {
#if BUILDFLAG(OPEN_ENABLE_AUTOMATION)
  automation_server_ = OpenAutomationServer::CreateFromCommandLine(
      this, *base::CommandLine::ForCurrentProcess(), user_data_dir_);
#endif
}

void OpenBrowserService::ApplyPreferencesNow() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  ApplyPreferencesInternal(/*schedule_sync_push=*/true);
}

void OpenBrowserService::ApplyPreferencesInternal(bool schedule_sync_push) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!started_) {
    return;
  }
  webui::OpenPreferences* prefs = webui::OpenPreferences::Get();

  // 1. Download location + prompt toggle per attached Profile.
  for (const auto& [id, services] : profiles_) {
    const Profile* profile = model_->FindProfile(id);
    if (profile && services && services->chrome_profile) {
      OpenDownloadBridge::ApplyDownloadPreferences(
          services->chrome_profile, profile->settings.download_directory,
          profile->settings.ask_where_to_save_each_file);
    }
  }

  // 2. Auto Picture-in-Picture enabled & disabled hosts.
  if (media_bridge_) {
    const base::Value pip_enabled = prefs->GetValue("advanced.pictureInPicture");
    if (pip_enabled.is_bool()) {
      media_bridge_->SetAutoPiPEnabled(pip_enabled.GetBool());
    }
    const base::Value pip_hosts = prefs->GetValue("advanced.pipExcludedHosts");
    if (pip_hosts.is_list()) {
      std::vector<std::string> hosts;
      for (const base::Value& entry : pip_hosts.GetList()) {
        if (entry.is_string()) {
          hosts.push_back(entry.GetString());
        }
      }
      media_bridge_->SetAutoPiPDisabledHosts(std::move(hosts));
    }
  }

  // 3. Offer Translate toggle (general.offerTranslate && advanced.translateOffer).
  if (translate_controller_) {
    const base::Value gen = prefs->GetValue("general.offerTranslate");
    const base::Value adv = prefs->GetValue("advanced.translateOffer");
    const bool offer_translate =
        (!gen.is_bool() || gen.GetBool()) && (!adv.is_bool() || adv.GetBool());
    content::WebContents* active_wc =
        tab_bridge_ ? tab_bridge_->ActiveWebContents() : nullptr;
    translate_controller_->SetOfferTranslateEnabled(offer_translate, active_wc);
  }

  // 4. App Icon.
  if (OpenPlatform* platform = OpenPlatform::Get()) {
    if (schedule_sync_push || prefs->stored().Find("appearance.appIcon")) {
      const base::Value icon_val = prefs->GetValue("appearance.appIcon");
      if (icon_val.is_string()) {
        const std::string& id = icon_val.GetString();
        platform->SetAppIcon(id == "open-indigo" ? std::string() : id);
      }
    }
  }

  // 5. Boosts enabled toggle.
  if (boost_controller_) {
    boost_controller_->OnBoostsPreferenceChanged();
  }

  // 6. Global Little Open hotkey.
  ReloadGlobalHotkeys();

  // 7. Debounced Sync push for portable preferences.
  if (schedule_sync_push && sync_ && sync_->is_signed_in() &&
      !sync_->is_applying_remote()) {
    sync_->ScheduleCollectionPush(
        SyncCollectionToString(SyncCollection::kSettingsPreferences));
  }
}

scoped_refptr<network::SharedURLLoaderFactory>
OpenBrowserService::ResolveActiveURLLoaderFactory() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  ::Profile* chrome_profile = ChromeProfileFor(ActiveProfileId());
  if (!chrome_profile || chrome_profile == destroying_profile_) {
    chrome_profile = nullptr;
    for (const auto& [id, services] : profiles_) {
      if (services && services->chrome_profile &&
          services->chrome_profile != destroying_profile_) {
        chrome_profile = services->chrome_profile.get();
        break;
      }
    }
  }
  if (chrome_profile) {
    if (content::StoragePartition* partition =
            chrome_profile->GetDefaultStoragePartition()) {
      if (auto factory = partition->GetURLLoaderFactoryForBrowserProcess()) {
        return factory;
      }
    }
  }
  return g_browser_process ? g_browser_process->shared_url_loader_factory()
                           : nullptr;
}

network::mojom::NetworkContext*
OpenBrowserService::ResolveActiveNetworkContext() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!started_) {
    return nullptr;
  }
  ::Profile* chrome_profile = ChromeProfileFor(ActiveProfileId());
  if (!chrome_profile || chrome_profile == destroying_profile_) {
    chrome_profile = nullptr;
    for (const auto& [id, services] : profiles_) {
      if (services && services->chrome_profile &&
          services->chrome_profile != destroying_profile_) {
        chrome_profile = services->chrome_profile.get();
        break;
      }
    }
  }
  if (!chrome_profile) {
    return nullptr;
  }
  content::StoragePartition* partition =
      chrome_profile->GetDefaultStoragePartition();
  return partition ? partition->GetNetworkContext() : nullptr;
}

void OpenBrowserService::RefreshNetworkFactories() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (livedata_) {
    livedata_->SetURLLoaderFactory(nullptr);
  }
  livedata_url_loader_factory_.reset();
  if (!started_) {
    if (updater_) {
      updater_->SetURLLoaderFactory(nullptr);
    }
    return;
  }
  scoped_refptr<network::SharedURLLoaderFactory> factory =
      ResolveActiveURLLoaderFactory();
  if (livedata_) {
    livedata_url_loader_factory_ = factory;
    livedata_->SetURLLoaderFactory(livedata_url_loader_factory_.get());
  }
  if (updater_) {
    updater_->SetURLLoaderFactory(std::move(factory));
  }
}

void OpenBrowserService::SyncLiveDataFromModel() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!livedata_ || !model_) {
    return;
  }

  std::map<ItemID, LiveFolderConfig> current_folders;
  for (const Space& space : model_->spaces()) {
    CollectLiveFoldersFromNodes(space.pinned, &current_folders);
    CollectLiveFoldersFromNodes(space.today, &current_folders);
  }

  for (auto it = registered_live_folders_.begin();
       it != registered_live_folders_.end();) {
    if (!current_folders.contains(it->first)) {
      livedata_->UnregisterLiveFolder(it->first);
      it = registered_live_folders_.erase(it);
    } else {
      ++it;
    }
  }
  for (const auto& [folder_id, config] : current_folders) {
    auto it = registered_live_folders_.find(folder_id);
    if (it == registered_live_folders_.end() || !(it->second == config)) {
      livedata_->RegisterLiveFolder(folder_id, config);
      registered_live_folders_[folder_id] = config;
    }
  }

  std::map<ItemID, std::string> current_calendars;
  for (const Profile& profile : model_->profiles()) {
    for (const Tab& fav : profile.favorites) {
      if (OpenLiveDataService::IsCalendarFavoriteUrl(fav.url)) {
        current_calendars.emplace(fav.id, fav.url);
      }
    }
  }
  for (auto it = registered_calendar_favorites_.begin();
       it != registered_calendar_favorites_.end();) {
    if (!current_calendars.contains(it->first)) {
      livedata_->UnregisterFavoriteTab(it->first);
      it = registered_calendar_favorites_.erase(it);
    } else {
      ++it;
    }
  }
  for (const auto& [tab_id, url] : current_calendars) {
    auto it = registered_calendar_favorites_.find(tab_id);
    if (it == registered_calendar_favorites_.end() || it->second != url) {
      livedata_->RegisterCalendarFavoriteTab(tab_id, url);
      registered_calendar_favorites_[tab_id] = url;
    }
  }
}

void OpenBrowserService::UpdateHandoffForTab(const ItemID& tab_id,
                                             content::WebContents* contents) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!handoff_) {
    return;
  }
  if (tab_id.empty()) {
    last_handoff_tab_id_.clear();
    handoff_->Invalidate();
    return;
  }
  const bool is_incognito =
      model_->IsIncognitoNode(tab_id) ||
      (contents && contents->GetBrowserContext() &&
       contents->GetBrowserContext()->IsOffTheRecord());
  if (is_incognito) {
    last_handoff_tab_id_ = tab_id;
    handoff_->UpdateActiveTab(GURL(), std::string_view(),
                              /*is_incognito=*/true);
    return;
  }
  GURL url;
  std::string title;
  if (contents) {
    url = contents->GetLastCommittedURL();
    if (!url.is_valid()) {
      url = contents->GetVisibleURL();
    }
    title = base::UTF16ToUTF8(contents->GetTitle());
  }
  if (!url.is_valid()) {
    if (const Tab* tab = model_->FindTab(tab_id)) {
      url = GURL(tab->url);
      if (title.empty()) {
        title = tab->display_title();
      }
    }
  }
  last_handoff_tab_id_ = tab_id;
  handoff_->UpdateActiveTab(url, title, /*is_incognito=*/false);
}

void OpenBrowserService::OnTabContentsAttachedBridge(
    const ItemID& tab_id,
    content::WebContents* contents) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!started_ || !contents) {
    return;
  }
  if (media_bridge_) {
    media_bridge_->TrackTab(tab_id, contents);
  }
  if (translate_controller_) {
    translate_controller_->ObserveWebContents(contents);
  }
  if (livedata_ && contents->GetBrowserContext() &&
      !contents->GetBrowserContext()->IsOffTheRecord() &&
      model_->IsFavorite(tab_id)) {
    const GURL& gurl = contents->GetLastCommittedURL();
    const std::string url = gurl.is_valid()
                                ? gurl.spec()
                                : (model_->FindTab(tab_id)
                                       ? model_->FindTab(tab_id)->url
                                       : std::string());
    const std::string title = base::UTF16ToUTF8(contents->GetTitle());
    if (!url.empty()) {
      if (OpenLiveDataService::IsCalendarFavoriteUrl(url)) {
        livedata_->RegisterCalendarFavoriteTab(tab_id, url);
        registered_calendar_favorites_[tab_id] = url;
        livedata_->IngestCalendarTabMetadata(tab_id, url, title);
      }
      livedata_->UpdateTabTitleForBadge(tab_id, url, title);
    }
  }
}

void OpenBrowserService::OnTabContentsDetachingBridge(
    const ItemID& tab_id,
    content::WebContents* /*contents*/) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (media_bridge_) {
    media_bridge_->UntrackTab(tab_id);
  }
  for (auto it = active_tab_by_window_.begin();
       it != active_tab_by_window_.end();) {
    if (it->second == tab_id) {
      it = active_tab_by_window_.erase(it);
    } else {
      ++it;
    }
  }
  if (last_active_tab_id_ == tab_id) {
    last_active_tab_id_.clear();
  }
  if (handoff_ && last_handoff_tab_id_ == tab_id) {
    last_handoff_tab_id_.clear();
    handoff_->Invalidate();
  }
}

void OpenBrowserService::OnTabActivatedBridge(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!started_) {
    return;
  }
  std::optional<WindowID> win_id;
  if (tab_bridge_) {
    if (BrowserWindowInterface* browser = tab_bridge_->BrowserForTab(tab_id)) {
      win_id = tab_bridge_->WindowIdForBrowser(browser);
    }
  }
  ItemID previous_tab;
  if (win_id && !win_id->empty()) {
    auto it = active_tab_by_window_.find(*win_id);
    if (it != active_tab_by_window_.end()) {
      previous_tab = it->second;
    }
    active_tab_by_window_[*win_id] = tab_id;
  } else {
    previous_tab = last_active_tab_id_;
  }
  last_active_tab_id_ = tab_id;

  if (media_bridge_) {
    media_bridge_->OnTabSelected(tab_id);
    if (!previous_tab.empty() && previous_tab != tab_id) {
      media_bridge_->MaybeEnterAutoPiP(previous_tab);
    }
  }

  content::WebContents* contents =
      tab_bridge_ ? tab_bridge_->WebContentsForTab(tab_id) : nullptr;
  if (translate_controller_ && contents) {
    translate_controller_->ObserveWebContents(contents);
  }
  UpdateHandoffForTab(tab_id, contents);
}

void OpenBrowserService::OnTabPrimaryPageCommittedBridge(
    const ItemID& tab_id,
    content::WebContents* contents) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!started_ || !contents) {
    return;
  }
  if (handoff_ && tab_bridge_ && tab_bridge_->ActiveTabId() == tab_id) {
    UpdateHandoffForTab(tab_id, contents);
  }
  if (livedata_ && contents->GetBrowserContext() &&
      !contents->GetBrowserContext()->IsOffTheRecord() &&
      model_->IsFavorite(tab_id)) {
    const std::string url = contents->GetLastCommittedURL().spec();
    const std::string title = base::UTF16ToUTF8(contents->GetTitle());
    if (!url.empty()) {
      if (OpenLiveDataService::IsCalendarFavoriteUrl(url)) {
        livedata_->RegisterCalendarFavoriteTab(tab_id, url);
        registered_calendar_favorites_[tab_id] = url;
        livedata_->IngestCalendarTabMetadata(tab_id, url, title);
      }
      livedata_->UpdateTabTitleForBadge(tab_id, url, title);
    }
  }
}

void OpenBrowserService::StartSync() {
  if (sync_) {
    return;
  }
  // One engine for the whole app, rooted in <user data>/State/Sync. Its
  // credentials use a secret-store account key derived from that directory,
  // so two user-data directories (or test profiles) never share a login.
  // Network: the browser process's own loader factory (no Profile's cookies)
  // plus Chromium's NetworkContext for real-time WebSocket push wakeups.
  const base::FilePath state_dir = user_data_dir_.AppendASCII(kStateDirName);
  const base::FilePath pending_wipe_path =
      user_data_dir_.AppendASCII(kProfilesDirName)
          .AppendASCII(kPendingWipeFile);

  SyncAdapterDeps deps;
  deps.user_data_dir = user_data_dir_;
  deps.model = model_.get();
  deps.command_registry = commands_.get();
  deps.get_layout_window_id = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self) -> WindowID {
        return self ? self->ActiveWindowId() : WindowID();
      },
      weak_factory_.GetWeakPtr());
  deps.on_workspace_applied = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self,
         const std::set<ProfileID>& new_profile_ids) {
        if (!self) {
          return;
        }
        for (const ProfileID& pid : new_profile_ids) {
          self->ProfileServicesFor(pid);
        }
        self->ScheduleSave();
        self->RefreshRecentHistory();
        self->SyncLiveDataFromModel();
        self->BroadcastEvent(webui::kEventStateChanged,
                             base::Value(base::DictValue()));
      },
      weak_factory_.GetWeakPtr());
  deps.read_preferences = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self)
          -> std::map<std::string, base::Value> {
        std::map<std::string, base::Value> out;
        if (!self) {
          return out;
        }
        webui::OpenPreferences* prefs = webui::OpenPreferences::Get();
        std::optional<base::DictValue> disk_dict;
        const base::DictValue* source = nullptr;
        if (prefs->loaded()) {
          source = &prefs->stored();
        } else {
          const base::FilePath prefs_path =
              self->user_data_dir_.AppendASCII(kStateDirName)
                  .AppendASCII(kPreferencesFile);
          std::string raw;
          if (base::ReadFileToStringWithMaxSize(prefs_path, &raw,
                                                1024 * 1024)) {
            disk_dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
            if (disk_dict) {
              source = &*disk_dict;
            }
          }
        }
        if (source) {
          for (const PortablePrefMapping& m : kPortablePrefMappings) {
            if (const base::Value* val = source->Find(m.open_pref_key)) {
              out.emplace(m.sync_key, val->Clone());
            }
          }
        }
        if (self->translate_controller_) {
          const std::vector<std::string> hosts =
              self->translate_controller_->GetNeverTranslateHosts();
          if (!hosts.empty()) {
            base::ListValue list;
            for (const std::string& h : hosts) {
              list.Append(h);
            }
            out.emplace("open.translate.neverTranslateHosts",
                        base::Value(std::move(list)));
          }
        }
        return out;
      },
      weak_factory_.GetWeakPtr());
  deps.write_preferences = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self,
         const std::map<std::string, base::Value>& values,
         bool remove_missing) {
        if (!self) {
          return;
        }
        webui::OpenPreferences* prefs = webui::OpenPreferences::Get();
        const ProfileID active_profile = self->ActiveProfileId();
        for (const PortablePrefMapping& m : kPortablePrefMappings) {
          auto it = values.find(m.sync_key);
          if (it != values.end()) {
            std::string error;
            prefs->Set(m.open_pref_key, it->second, active_profile,
                       /*all_profiles=*/false, &error);
          } else if (remove_missing) {
            prefs->Reset(m.open_pref_key, active_profile);
          }
        }
        if (self->translate_controller_) {
          auto it = values.find("open.translate.neverTranslateHosts");
          if (it != values.end() && it->second.is_list()) {
            if (remove_missing) {
              self->translate_controller_->ResetNeverTranslateHosts();
            }
            for (const base::Value& entry : it->second.GetList()) {
              if (entry.is_string()) {
                self->translate_controller_->SetNeverTranslateHost(
                    nullptr, entry.GetString(), /*never=*/true);
              }
            }
          } else if (remove_missing) {
            self->translate_controller_->ResetNeverTranslateHosts();
          }
        }
        self->ApplyPreferencesInternal(/*schedule_sync_push=*/false);
      },
      weak_factory_.GetWeakPtr());
  deps.on_keybindings_applied = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self) {
        if (!self) {
          return;
        }
        if (self->window_controller_) {
          self->window_controller_->ReloadShortcuts();
        }
        self->ReloadGlobalHotkeys();
      },
      weak_factory_.GetWeakPtr());
  deps.apply_archive = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self, const ProfileID& profile_id,
         const std::vector<ArchivedTabRecord>& records,
         bool replace_all) -> bool {
        if (!self) {
          return false;
        }
        ProfileServices* ps = self->ProfileServicesFor(profile_id);
        if (!ps) {
          return false;
        }
        RunOnStore(
            ps->archive,
            base::BindOnce(
                [](std::vector<ArchivedTabRecord> records, bool replace_all,
                   ArchiveStore* store) {
                  if (!store) {
                    return;
                  }
                  if (replace_all) {
                    store->DeleteAll();
                  }
                  if (!records.empty()) {
                    store->Archive(records);
                  }
                },
                records, replace_all));
        return true;
      },
      weak_factory_.GetWeakPtr());
  deps.apply_history = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self, const ProfileID& profile_id,
         const std::vector<HistoryEntry>& entries, bool replace_all) -> bool {
        if (!self) {
          return false;
        }
        ProfileServices* ps = self->ProfileServicesFor(profile_id);
        if (!ps) {
          return false;
        }
        RunOnStore(
            ps->history,
            base::BindOnce(
                [](std::vector<HistoryEntry> entries, bool replace_all,
                   TimestampSec clear_through, HistoryStore* store) -> bool {
                  if (!store) {
                    return false;
                  }
                  if (replace_all) {
                    store->ClearRange(std::nullopt, clear_through);
                  }
                  for (const HistoryEntry& e : entries) {
                    store->RecordVisit(e.url, e.title, e.last_visit, "sync",
                                       e.typed_count > 0);
                  }
                  return true;
                },
                entries, replace_all, NowSec() + 86400.0),
            base::BindOnce(
                [](base::WeakPtr<OpenBrowserService> self, ProfileID pid,
                   bool /*ok*/) {
                  if (self && pid == self->ActiveProfileId()) {
                    self->RefreshRecentHistory();
                  }
                },
                self, profile_id));
        return true;
      },
      weak_factory_.GetWeakPtr());
  deps.apply_boosts = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self, const ProfileID& profile_id,
         const std::vector<Boost>& upserts,
         const std::vector<std::string>& deletes, bool replace_all) -> bool {
        if (!self) {
          return false;
        }
        ProfileServices* ps = self->ProfileServicesFor(profile_id);
        if (!ps) {
          return false;
        }
        std::set<std::string> keep_ids;
        if (replace_all) {
          for (const Boost& b : upserts) {
            keep_ids.insert(b.id);
          }
        }
        RunOnStore(
            ps->boosts,
            base::BindOnce(
                [](std::vector<Boost> upserts, std::vector<std::string> deletes,
                   bool replace_all, std::set<std::string> keep_ids,
                   BoostStore* store) -> bool {
                  if (!store) {
                    return false;
                  }
                  store->Load();
                  for (const std::string& bid : deletes) {
                    store->Delete(bid);
                  }
                  for (const Boost& b : upserts) {
                    store->Upsert(b);
                  }
                  if (replace_all) {
                    for (const Boost& existing : store->AllBoosts()) {
                      if (!keep_ids.contains(existing.id)) {
                        store->Delete(existing.id);
                      }
                    }
                  }
                  return store->SaveNow();
                },
                upserts, deletes, replace_all, std::move(keep_ids)),
            base::BindOnce(
                [](base::WeakPtr<OpenBrowserService> self, ProfileID pid,
                   bool /*ok*/) {
                  if (self && self->boost_controller_) {
                    self->boost_controller_->ReloadBoosts(pid);
                  }
                },
                self, profile_id));
        return true;
      },
      weak_factory_.GetWeakPtr());
  deps.on_boosts_changed = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self, const ProfileID& profile_id) {
        if (self && self->boost_controller_) {
          self->boost_controller_->ReloadBoosts(profile_id);
        }
      },
      weak_factory_.GetWeakPtr());
  deps.get_adblock_service = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self,
         const ProfileID& profile_id) -> OpenAdBlockProfileService* {
        if (!self) {
          return nullptr;
        }
        ProfileServices* ps = self->ProfileServicesFor(profile_id);
        return ps ? ps->adblock() : nullptr;
      },
      weak_factory_.GetWeakPtr());
  deps.on_documents_changed = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self) {
        if (self) {
          self->BroadcastEvent(webui::kEventStateChanged,
                               base::Value(base::DictValue()));
        }
      },
      weak_factory_.GetWeakPtr());
  deps.read_extensions = base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self, const ProfileID& profile_id)
          -> std::optional<std::vector<SyncedExtensionRecord>> {
        if (!self) {
          return std::nullopt;
        }
        ProfileServices* ps = self->ProfileServicesFor(profile_id);
        if (!ps || !ps->extensions) {
          return std::nullopt;
        }
        std::vector<SyncedExtensionRecord> out;
        int pinned_idx = 0;
        for (const ExtensionActionInfo& info :
             ps->extensions->ListInstalled()) {
          if (!SyncStorageAdapterImpl::IsValidWebStoreExtensionId(info.id)) {
            continue;
          }
          SyncedExtensionRecord rec;
          rec.extension_id = info.id;
          rec.name = info.name;
          rec.from_web_store = true;
          rec.is_enabled = info.enabled;
          rec.is_pinned = info.pinned;
          rec.pinned_index = info.pinned ? pinned_idx++ : 0;
          out.push_back(std::move(rec));
        }
        return out;
      },
      weak_factory_.GetWeakPtr());
  deps.get_reserved_profile_dirs = base::BindRepeating(
      [](base::FilePath journal_path) -> std::set<std::string> {
        std::set<std::string> reserved;
        for (const std::string& dir : ReadPendingWipeList(journal_path)) {
          reserved.insert(base::ToLowerASCII(dir));
        }
        return reserved;
      },
      pending_wipe_path);

  sync_adapter_ = std::make_unique<SyncStorageAdapterImpl>(std::move(deps));
  sync_ = std::make_unique<SyncEngine>(
      ToStdPath(state_dir.AppendASCII("Sync")), model_.get(),
      OpenPlatform::Get()->CreateSecretStore(state_dir),
      g_browser_process->shared_url_loader_factory());
  sync_->SetDataAdapter(sync_adapter_.get());
  sync_->SetNetworkContextProvider(base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self)
          -> network::mojom::NetworkContext* {
        return self ? self->ResolveActiveNetworkContext() : nullptr;
      },
      weak_factory_.GetWeakPtr()));
  sync_->SetStatusObserver(base::BindRepeating(
      [](base::WeakPtr<OpenBrowserService> self, const SyncStatusInfo& info) {
        if (!self) {
          return;
        }
        self->BroadcastEvent(
            webui::kEventSyncStatusChanged,
            base::Value(base::DictValue()
                            .Set("signed_in", info.signed_in)
                            .Set("state", info.state)
                            .Set("server_url", info.server_url)
                            .Set("revision",
                                 static_cast<double>(info.revision))));
      },
      weak_factory_.GetWeakPtr()));
  sync_->StartIfSignedIn();
}

void OpenBrowserService::ConfigureSyncFromCommandLine() {
  const base::CommandLine& command_line =
      *base::CommandLine::ForCurrentProcess();
  if (!command_line.HasSwitch(switches::kSyncServer)) {
    return;
  }
  const std::string url =
      command_line.GetSwitchValueASCII(switches::kSyncServer);
  if (sync_ && !sync_->Status().signed_in) {
    sync_->ConfigureServer(url, {}, base::DoNothing());
  }
}

void OpenBrowserService::RouteExternalUrls(const std::vector<GURL>& urls) {
  std::optional<std::string> source_app_id;
  if (OpenPlatform* platform = OpenPlatform::Get()) {
    std::string resolved = platform->ResolveExternalUrlSourceApp();
    if (!resolved.empty()) {
      source_app_id = std::move(resolved);
    }
  }
  RouteExternalUrls(urls, std::move(source_app_id));
}

void OpenBrowserService::RouteExternalUrls(
    const std::vector<GURL>& urls,
    std::optional<std::string> source_app_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!source_app_id.has_value()) {
    if (OpenPlatform* platform = OpenPlatform::Get()) {
      std::string resolved = platform->ResolveExternalUrlSourceApp();
      if (!resolved.empty()) {
        source_app_id = std::move(resolved);
      }
    }
  }
  for (const GURL& url : urls) {
    if (url.is_valid()) {
      pending_external_urls_.push_back(PendingExternalUrl{url, source_app_id});
    }
  }
  if (started_) {
    FlushPendingExternalUrls();
  }
}

void OpenBrowserService::RouteExternalUrl(
    const GURL& url,
    std::optional<std::string> source_app_id,
    std::optional<ProfileID> profile_override) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!url.is_valid()) {
    return;
  }
  if (!source_app_id.has_value()) {
    if (OpenPlatform* platform = OpenPlatform::Get()) {
      std::string resolved = platform->ResolveExternalUrlSourceApp();
      if (!resolved.empty()) {
        source_app_id = std::move(resolved);
      }
    }
  }
  if (!started_) {
    pending_external_urls_.push_back(
        PendingExternalUrl{url, std::move(source_app_id)});
    return;
  }
  RouteSingleExternalUrl(url, std::move(source_app_id),
                         std::move(profile_override),
                         /*after_bootstrap=*/false);
}

void OpenBrowserService::FlushPendingExternalUrls() {
  if (!started_ || !window_controller_) {
    return;
  }
  std::vector<PendingExternalUrl> pending = std::move(pending_external_urls_);
  pending_external_urls_.clear();
  for (PendingExternalUrl& entry : pending) {
    RouteSingleExternalUrl(entry.url, std::move(entry.source_app_id),
                           std::nullopt, /*after_bootstrap=*/false);
  }
}

bool OpenBrowserService::HandleDeepLink(const DeepLinkAction& action) {
  if (action.kind == DeepLinkKind::kNone) {
    return false;
  }
  switch (action.kind) {
    case DeepLinkKind::kQuit:
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&chrome::AttemptUserExit));
      return true;
    case DeepLinkKind::kRestart:
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&chrome::AttemptRestart));
      return true;
    case DeepLinkKind::kWelcome:
      if (tab_bridge_) {
        tab_bridge_->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostWelcome)),
                             /*background=*/false, MainWindowId());
      }
      if (OpenWindowUi* ui = window_controller_->MainWindowUi()) {
        ui->ActivateWindow();
      }
      return true;
    case DeepLinkKind::kSpace: {
      const auto& spaces = model_->spaces();
      SpaceID target_space;
      int one_based = 0;
      if (base::StringToInt(action.argument, &one_based)) {
        if (one_based >= 1 &&
            static_cast<size_t>(one_based) <= spaces.size()) {
          target_space = spaces[static_cast<size_t>(one_based - 1)].id;
        }
      } else if (!action.argument.empty()) {
        for (const Space& space : spaces) {
          if (space.title.has_value() &&
              base::EqualsCaseInsensitiveASCII(*space.title, action.argument)) {
            target_space = space.id;
            break;
          }
        }
      }
      if (!target_space.empty() && tab_bridge_) {
        tab_bridge_->FocusSpace(target_space, MainWindowId());
        if (OpenWindowUi* ui = window_controller_->MainWindowUi()) {
          ui->ActivateWindow();
        }
      }
      return true;
    }
    case DeepLinkKind::kLittleOpen: {
      std::optional<GURL> arg_url;
      if (!action.argument.empty()) {
        GURL parsed(action.argument);
        if (parsed.is_valid() && parsed.SchemeIsHTTPOrHTTPS()) {
          arg_url = parsed;
        }
      }
      if (window_controller_) {
        window_controller_->OpenLittleOpen(arg_url);
      }
      return true;
    }
    case DeepLinkKind::kWebUI:
      if (tab_bridge_) {
        GURL target(action.raw_url);
        if (target.is_valid()) {
          tab_bridge_->OpenTab(target, /*background=*/false, MainWindowId());
          if (OpenWindowUi* ui = window_controller_->MainWindowUi()) {
            ui->ActivateWindow();
          }
        }
      }
      return true;
    case DeepLinkKind::kUnknown:
      LOG(INFO) << "Open: ignored unknown deep link route ("
                << action.route.size() << " chars)";
      return true;
    case DeepLinkKind::kNone:
      return false;
  }
  return false;
}

bool OpenBrowserService::HandleMailtoUrl(
    const GURL& url,
    const std::optional<std::string>& source_app_id) {
  if (!IsMailtoUrl(url.spec())) {
    return false;
  }
  const ProfileID profile_id = ActiveProfileId();
  ::Profile* chrome_profile = ChromeProfileFor(profile_id);
  if (chrome_profile) {
    if (custom_handlers::ProtocolHandlerRegistry* registry =
            ProtocolHandlerRegistryFactory::GetForBrowserContext(
                chrome_profile)) {
      const GURL translated = registry->Translate(url);
      if (translated.is_valid() && translated.SchemeIsHTTPOrHTTPS()) {
        RouteSingleExternalUrl(translated, source_app_id, profile_id,
                               /*after_bootstrap=*/false);
        return true;
      }
    }
  }
  LOG(INFO) << "Open: mailto link arrived with no registered webmail handler";
  return true;
}

void OpenBrowserService::MaybeInstallDefaultGoogleMeetRule(const GURL& url) {
  if (did_set_default_meet_route_ || !IsGoogleMeetUrl(url.spec())) {
    return;
  }
  did_set_default_meet_route_ = true;
  file_runner_->PostTask(
      FROM_HERE,
      base::BindOnce([](base::FilePath path) { base::WriteFile(path, "1"); },
                     user_data_dir_.AppendASCII(kStateDirName)
                         .AppendASCII(kMeetRouteMarker)));
  if (HasGoogleMeetRule(*model_)) {
    return;
  }
  RoutingRule rule;
  rule.id = GenerateUuidV4();
  rule.name = "Google Meet";
  rule.host_pattern = "meet.google.com";
  rule.destination =
      RoutingDestination(RoutingDestinationKind::kMostRecentSpace);
  rule.enabled = true;
  std::vector<RoutingRule> rules = model_->routing_rules();
  rules.push_back(std::move(rule));
  model_->SetRoutingRules(std::move(rules));
  ScheduleSave();
}

void OpenBrowserService::RouteSingleExternalUrl(
    const GURL& url,
    std::optional<std::string> source_app_id,
    std::optional<ProfileID> profile_override,
    bool after_bootstrap) {
  if (!started_ || !window_controller_ || !tab_bridge_ || !url.is_valid()) {
    return;
  }

  // 1. open:// and open-browser:// deep links.
  DeepLinkAction deep_link = ParseDeepLink(url.spec());
  if (deep_link.kind != DeepLinkKind::kNone) {
    HandleDeepLink(deep_link);
    return;
  }

  // 2. mailto: protocol handler translation -> ATC routing in that Profile.
  if (IsMailtoUrl(url.spec())) {
    HandleMailtoUrl(url, source_app_id);
    return;
  }

  const TimestampSec now = NowSec();
  // 3. Non-HTTP(S) links are logged as rejected and never enter the deduper.
  if (!url.SchemeIsHTTPOrHTTPS()) {
    RoutingRequest req{url.spec(), source_app_id, now};
    routing_log_.Record(routing_->Evaluate(req, *model_, true));
    return;
  }

  // 4. 2-second duplicate URL dedupe.
  if (link_deduper_.IsDuplicateAndRecord(url.spec(), source_app_id, now)) {
    return;
  }

  // 5. Google Meet default Air Traffic Control route on first Meet link.
  MaybeInstallDefaultGoogleMeetRule(url);

  // 6. Air Traffic Control evaluation.
  RoutingRequest request;
  request.url = url.spec();
  request.source_app_id = source_app_id;
  request.received_at = now;
  const base::Value little_open_pref =
      webui::OpenPreferences::Get()->GetValue("links.externalLinksLittleOpen");
  const bool external_in_little_open =
      little_open_pref.is_bool() ? little_open_pref.GetBool() : true;
  RoutingDecision decision =
      routing_->Evaluate(request, *model_, external_in_little_open);

  // Keep mailto-generated compose URLs inside their originating Profile when
  // no explicit rule matched.
  if (profile_override.has_value() && decision.via != RoutingVia::kRule &&
      decision.resolved.has_value()) {
    if (decision.resolved->kind == RoutingDestinationKind::kLittleOpen) {
      decision.resolved->profile_id = *profile_override;
    } else if (decision.resolved->profile_id != *profile_override) {
      if (auto sid = model_->MostRecentlyFocusedSpace(*profile_override)) {
        decision.resolved = ResolvedRoutingTarget{
            RoutingDestinationKind::kSpace, *sid, *profile_override};
      } else {
        decision.resolved = ResolvedRoutingTarget{
            RoutingDestinationKind::kLittleOpen, std::nullopt,
            *profile_override};
      }
    }
  }

  routing_log_.Record(decision);

  if (!decision.resolved.has_value()) {
    if (decision.via == RoutingVia::kNoSpaces && !after_bootstrap) {
      model_->EnsureDefaultWorkspace();
      RouteSingleExternalUrl(url, std::move(source_app_id),
                             std::move(profile_override),
                             /*after_bootstrap=*/true);
      return;
    }
    if (decision.via == RoutingVia::kNoSpaces) {
      window_controller_->OpenLittleOpen(url);
    }
    return;
  }

  if (decision.resolved->kind == RoutingDestinationKind::kLittleOpen) {
    window_controller_->OpenLittleOpen(
        url, decision.resolved->profile_id.value_or(ProfileID()),
        decision.resolved->space_id);
    return;
  }

  const WindowID target_window = MainWindowId();
  if (decision.resolved->space_id) {
    tab_bridge_->OpenTabInSpace(url, *decision.resolved->space_id,
                                /*background=*/false, target_window);
  } else {
    tab_bridge_->OpenTab(url, /*background=*/false, target_window);
  }
  if (OpenWindowUi* ui = window_controller_->MainWindowUi()) {
    ui->ActivateWindow();
  }
}

}  // namespace open_unified
