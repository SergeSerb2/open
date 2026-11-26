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
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "open_unified/browser/open_boost_controller.h"
#include "open_unified/browser/open_extension_bridge.h"
#include "open_unified/browser/open_sleep_controller.h"
#include "open_unified/browser/open_switches.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/open_window_controller.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/documents/document_store.h"
#include "open_unified/core/routing/routing_evaluator.h"
#include "open_unified/core/store/snapshot_store.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "open_unified/core/suggest/suggest_engine.h"
#include "open_unified/core/sync/sync_engine.h"
#include "open_unified/ui/webui/open_ipc_contract.h"
#include "open_unified/ui/webui/open_webui_config.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"

#if BUILDFLAG(OPEN_ENABLE_AUTOMATION)
#include "open_unified/browser/open_automation_server.h"
#endif

namespace open_unified {

namespace {

OpenBrowserService* g_service = nullptr;

constexpr char kStateDirName[] = "State";
constexpr char kProfilesDirName[] = "Profiles";
constexpr char kOnboardingMarker[] = "onboarding-complete";
constexpr char kKeybindingsFile[] = "keybindings.json";

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

// Local directory names of Profiles that arrive through Sync. A remote
// payload's dataDirectoryName is never trusted (path traversal, collisions
// with another Profile's Chromium directory): it is reduced to
// [A-Za-z0-9 _-]{1,64}, "Default" (any case) stays reserved for the first
// local Profile, and a name already taken gets " 2", " 3", ...
constexpr size_t kMaxProfileDirectoryLength = 64;

std::string SanitizeProfileDirectoryName(std::string_view raw,
                                         const std::set<std::string>& taken) {
  std::string name;
  for (char c : raw) {
    if (base::IsAsciiAlphaNumeric(c) || c == ' ' || c == '_' || c == '-') {
      name.push_back(c);
    }
  }
  name = std::string(base::TrimString(name, " ", base::TRIM_ALL));
  if (name.size() > kMaxProfileDirectoryLength) {
    name.resize(kMaxProfileDirectoryLength);
    name = std::string(base::TrimString(name, " ", base::TRIM_TRAILING));
  }
  if (name.empty() || base::ToLowerASCII(name) == "default") {
    name = "Profile";
  }
  std::string candidate = name;
  for (int n = 2; taken.contains(base::ToLowerASCII(candidate)); ++n) {
    const std::string suffix = " " + base::NumberToString(n);
    std::string stem = name.substr(
        0, std::min(name.size(), kMaxProfileDirectoryLength - suffix.size()));
    candidate = std::string(base::TrimString(stem, " ", base::TRIM_TRAILING)) +
                suffix;
  }
  return candidate;
}

// The app-wide SyncDataAdapter: one Open Account carries every Profile's
// workspace (Spaces of all Profiles), as on macOS Open.
class OpenSyncDataAdapter final : public SyncDataAdapter {
 public:
  explicit OpenSyncDataAdapter(BrowserModel* model) : model_(model) {}
  ~OpenSyncDataAdapter() override = default;

  SyncLocalBundle CollectLocalData(
      const SyncCategorySettings& categories,
      const SyncVaultKeys& /*vault_keys*/) override {
    SyncLocalBundle bundle;
    if (model_ && categories.IsEnabled(SyncCollection::kWorkspaceSpace)) {
      base::DictValue meta;
      base::ListValue space_order;
      for (const Space& space : model_->spaces()) {
        space_order.Append(space.id);
        base::DictValue space_dict;
        space_dict.Set("id", space.id);
        space_dict.Set("title", space.title.value_or(""));
        space_dict.Set("profileId", space.profile_id);
        std::string space_json;
        base::JSONWriter::Write(space_dict, &space_json);
        bundle.records.push_back(
            {SyncCollection::kWorkspaceSpace, space.id, std::move(space_json)});
      }
      meta.Set("spaceOrder", std::move(space_order));
      std::string meta_json;
      base::JSONWriter::Write(meta, &meta_json);
      const std::string meta_id =
          SyncCollectionSingletonId(SyncCollection::kWorkspaceMeta)
              .value_or("workspace");
      bundle.records.push_back(
          {SyncCollection::kWorkspaceMeta, meta_id, std::move(meta_json)});
      bundle.complete_collections.insert(SyncCollection::kWorkspaceMeta);
      bundle.complete_collections.insert(SyncCollection::kWorkspaceSpace);
    }
    return bundle;
  }

  SyncApplyOutcome ApplyRemoteData(
      const SyncRemoteBundle& bundle,
      SyncApplyMode /*mode*/,
      const SyncCategorySettings& /*categories*/) override {
    SyncApplyOutcome outcome;
    if (!model_) {
      return outcome;
    }
    for (const SyncRemoteRecord& record : bundle.records) {
      if (record.collection != SyncCollection::kWorkspaceProfile ||
          record.deleted || !record.payload_json) {
        continue;
      }
      std::optional<base::DictValue> dict =
          SyncCollectionCodecs::DecodeJsonDict(*record.payload_json);
      std::optional<Profile> remote =
          dict ? SyncCollectionCodecs::DecodeProfile(*dict) : std::nullopt;
      if (!remote) {
        outcome.warnings.push_back("workspace.profile " + record.record_id +
                                   ": unreadable payload");
        continue;
      }
      const base::DictValue* fields = dict->FindDict("profile");
      const std::string* raw_dir =
          (fields ? fields : &*dict)->FindString("dataDirectoryName");
      const std::string local_dir = LocalDirectoryFor(
          remote->id, raw_dir ? std::string_view(*raw_dir)
                              : std::string_view(remote->name));
      VLOG(1) << "Open sync: remote Profile " << remote->id
              << " maps to local directory \"" << local_dir << "\"";
    }
    return outcome;
  }

  bool PrepareLocalBackup(const base::FilePath& backup_dir) override {
    return base::CreateDirectory(backup_dir);
  }

  // The local Chromium directory name for a Profile id: the local Profile's
  // own when it exists, else a sanitized unique name kept for this session
  // (the model gains synced Profiles through these names).
  std::string LocalDirectoryFor(const ProfileID& id, std::string_view raw) {
    if (const Profile* local = model_->FindProfile(id)) {
      return local->data_directory_name;
    }
    if (auto it = remote_dirs_.find(id); it != remote_dirs_.end()) {
      return it->second;
    }
    std::set<std::string> taken = {"default"};
    for (const Profile& profile : model_->profiles()) {
      taken.insert(base::ToLowerASCII(profile.data_directory_name));
    }
    for (const auto& [remote_id, dir] : remote_dirs_) {
      taken.insert(base::ToLowerASCII(dir));
    }
    std::string dir = SanitizeProfileDirectoryName(raw, taken);
    remote_dirs_.emplace(id, dir);
    return dir;
  }

 private:
  raw_ptr<BrowserModel> model_;
  std::map<ProfileID, std::string> remote_dirs_;
};

}  // namespace

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
  model_->AddObserver(this);
  model_->SetArchiveSink(this);
}

void OpenBrowserService::Start() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (started_) {
    return;
  }
  started_ = true;

  StartProfiles();
  StartSync();
  ConfigureSyncFromCommandLine();

  tab_bridge_ = std::make_unique<OpenTabBridge>(this);
  sleep_controller_ = std::make_unique<OpenSleepController>(this);
  boost_controller_ = std::make_unique<OpenBoostController>(this);

  // Adopts Chromium's startup Browser (or opens one), mirrors loaded tabs
  // into the real TabStripModel and selects the saved node.
  tab_bridge_->Start();
  sleep_controller_->Start();
  window_controller_->Start();
  // The command bar's history rows (SuggestEngine never touches SQLite).
  RefreshRecentHistory();

  const base::CommandLine& command_line =
      *base::CommandLine::ForCurrentProcess();
  if (first_run_ && !onboarding_completed_ &&
      !command_line.HasSwitch(switches::kSkipOnboarding)) {
    tab_bridge_->OpenTab(GURL(webui::OpenWebUIURL(webui::kHostOnboarding)),
                         /*background=*/false);
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
  if (sync_) {
    sync_->Shutdown();
  }
  sync_.reset();
  sync_adapter_.reset();
  window_controller_->Shutdown();
  boost_controller_.reset();
  sleep_controller_.reset();
  if (tab_bridge_) {
    tab_bridge_->Shutdown();
  }
  tab_bridge_.reset();
  // SequenceBound posts each store's destruction to its runner
  // (BLOCK_SHUTDOWN), so pending writes finish.
  profile_observations_.RemoveAllObservations();
  profiles_.clear();
  pending_external_urls_.clear();
}

void OpenBrowserService::StartProfiles() {
  for (const Profile& profile : model_->profiles()) {
    ProfileServicesFor(profile.id);
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
  return windows.empty() ? WindowID() : windows.front().id;
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
  if (window_controller_ && services->extensions) {
    window_controller_->UnobserveExtensionBridge(services->extensions.get());
  }
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
  // Open's window accelerators (Find, Ctrl+Tab, Little Open) follow.
  window_controller_->ReloadShortcuts();
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
  // Title/URL updates take the snapshot store's slower metadata path.
  if (change.kind == TreeChange::Kind::kUpdate) {
    snapshot_store_->ScheduleMetadataSave(model_.get());
  } else {
    ScheduleSave();
  }
  if (change.kind == TreeChange::Kind::kSpaceProfileChanged) {
    ProfileServicesFor(change.to_profile_id);
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

void OpenBrowserService::StartSync() {
  if (sync_) {
    return;
  }
  // One engine for the whole app, rooted in <user data>/State/Sync. Its
  // credentials use a secret-store account key derived from that directory,
  // so two user-data directories (or test profiles) never share a login.
  // Network: the browser process's own loader factory (no Profile's cookies).
  const base::FilePath state_dir = user_data_dir_.AppendASCII(kStateDirName);
  sync_adapter_ = std::make_unique<OpenSyncDataAdapter>(model_.get());
  sync_ = std::make_unique<SyncEngine>(
      ToStdPath(state_dir.AppendASCII("Sync")), model_.get(),
      OpenPlatform::Get()->CreateSecretStore(state_dir),
      g_browser_process->shared_url_loader_factory());
  sync_->SetDataAdapter(sync_adapter_.get());
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
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  for (const GURL& url : urls) {
    if (url.is_valid()) {
      pending_external_urls_.push_back(url);
    }
  }
  if (started_) {
    FlushPendingExternalUrls();
  }
}

void OpenBrowserService::FlushPendingExternalUrls() {
  if (!started_ || !window_controller_) {
    return;
  }
  std::vector<GURL> urls = std::move(pending_external_urls_);
  pending_external_urls_.clear();
  for (const GURL& url : urls) {
    window_controller_->RouteExternalUrl(url, std::nullopt);
  }
}

}  // namespace open_unified
