// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_download_bridge.h"

#include <algorithm>
#include <utility>

#include "base/base_paths.h"
#include "base/environment.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/task/bind_post_task.h"
#include "base/task/thread_pool.h"
#include "build/build_config.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/platform_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/pref_names.h"
#include "components/download/public/common/download_source.h"
#include "components/download/public/common/download_url_parameters.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/web_contents.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_WIN)
#include <windows.h>
#include <shellapi.h>
#endif

namespace open_unified {

namespace {

constexpr base::TimeDelta kProgressPersistInterval = base::Milliseconds(500);

constexpr net::NetworkTrafficAnnotationTag kOpenDownloadRetryTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("open_download_retry", R"(
        semantics {
          sender: "Open Download Manager"
          description:
            "Retries a previously failed or historical download requested "
            "explicitly by the user."
          trigger:
            "User clicks Retry on a download in the Downloads popover or "
            "Library."
          data:
            "Standard HTTP/HTTPS download request with profile cookies."
          destination: OTHER
          destination_other: "User-requested download URL"
        }
        policy {
          cookies_allowed: YES
          cookies_store: "user"
          setting: "User-initiated download retry."
          policy_exception_justification: "Explicit user action."
        })");

TimestampSec NowSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

bool IsActiveState(std::string_view state) {
  return state == "in_progress" || state == "paused";
}

bool IsTerminalState(std::string_view state) {
  return state == "completed" || state == "cancelled" || state == "interrupted";
}

#if BUILDFLAG(IS_MAC) || BUILDFLAG(IS_LINUX)
base::FilePath UniquePathInDirectory(const base::FilePath& dir,
                                     const base::FilePath& base_name) {
  base::FilePath candidate = dir.Append(base_name);
  if (!base::PathExists(candidate)) {
    return candidate;
  }
  const base::FilePath stem = base_name.RemoveExtension();
  const base::FilePath::StringType ext = base_name.Extension();
  for (int i = 1; i < 10000; ++i) {
    base::FilePath numbered = dir.Append(
        stem.value() +
        base::FilePath::FromASCII(" (" + base::NumberToString(i) + ")")
            .value() +
        ext);
    if (!base::PathExists(numbered)) {
      return numbered;
    }
  }
  return candidate;
}
#endif  // BUILDFLAG(IS_MAC) || BUILDFLAG(IS_LINUX)

bool MoveFileToTrashOnBlockingSequence(base::FilePath path) {
  if (path.empty() || !base::PathExists(path) || base::DirectoryExists(path)) {
    return false;
  }

#if BUILDFLAG(IS_WIN)
  std::wstring from = path.value();
  from.push_back(L'\0');
  from.push_back(L'\0');
  SHFILEOPSTRUCTW op = {};
  op.wFunc = FO_DELETE;
  op.pFrom = from.c_str();
  op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI;
  if (SHFileOperationW(&op) == 0 && !op.fAnyOperationsAborted) {
    return true;
  }
  return base::DeleteFile(path);
#elif BUILDFLAG(IS_MAC)
  base::FilePath home;
  if (base::PathService::Get(base::DIR_HOME, &home) && !home.empty()) {
    base::FilePath trash_dir = home.AppendASCII(".Trash");
    if (base::DirectoryExists(trash_dir) || base::CreateDirectory(trash_dir)) {
      base::FilePath dest = UniquePathInDirectory(trash_dir, path.BaseName());
      if (base::Move(path, dest)) {
        return true;
      }
    }
  }
  return base::DeleteFile(path);
#elif BUILDFLAG(IS_LINUX)
  base::FilePath trash_root;
  if (auto env = base::Environment::Create()) {
    if (auto xdg = env->GetVar("XDG_DATA_HOME"); xdg && !xdg->empty()) {
      trash_root = base::FilePath::FromUTF8Unsafe(*xdg).AppendASCII("Trash");
    }
  }
  if (trash_root.empty()) {
    base::FilePath home;
    if (base::PathService::Get(base::DIR_HOME, &home) && !home.empty()) {
      trash_root = home.AppendASCII(".local")
                       .AppendASCII("share")
                       .AppendASCII("Trash");
    }
  }
  if (!trash_root.empty()) {
    base::FilePath files_dir = trash_root.AppendASCII("files");
    base::FilePath info_dir = trash_root.AppendASCII("info");
    if (base::CreateDirectory(files_dir) && base::CreateDirectory(info_dir)) {
      base::FilePath dest = UniquePathInDirectory(files_dir, path.BaseName());
      base::Time::Exploded now_exploded;
      base::Time::Now().LocalExplode(&now_exploded);
      std::string deletion_date = base::StringPrintf(
          "%04d-%02d-%02dT%02d:%02d:%02d", now_exploded.year,
          now_exploded.month, now_exploded.day_of_month, now_exploded.hour,
          now_exploded.minute, now_exploded.second);
      std::string trashinfo = "[Trash Info]\nPath=" + path.AsUTF8Unsafe() +
                              "\nDeletionDate=" + deletion_date + "\n";
      base::FilePath info_file = info_dir.Append(
          dest.BaseName().AddExtensionASCII("trashinfo"));
      base::WriteFile(info_file, trashinfo);
      if (base::Move(path, dest)) {
        return true;
      }
      base::DeleteFile(info_file);
    }
  }
  return base::DeleteFile(path);
#else
  return base::DeleteFile(path);
#endif
}

std::vector<std::pair<std::string, bool>> CheckPathsExistOnBlockingSequence(
    std::vector<std::pair<std::string, base::FilePath>> checks) {
  std::vector<std::pair<std::string, bool>> results;
  results.reserve(checks.size());
  for (const auto& [id, path] : checks) {
    bool exists = !path.empty() && base::PathExists(path) &&
                  !base::DirectoryExists(path);
    results.emplace_back(id, exists);
  }
  return results;
}

std::vector<RecentDownloadEntry> PopulateFileExistsOnBlockingSequence(
    std::vector<RecentDownloadEntry> entries) {
  for (RecentDownloadEntry& entry : entries) {
    if (entry.record.state == "completed" && !entry.record.target_path.empty()) {
      base::FilePath path =
          base::FilePath::FromUTF8Unsafe(entry.record.target_path);
      entry.file_exists =
          base::PathExists(path) && !base::DirectoryExists(path);
    } else {
      entry.file_exists = false;
    }
  }
  return entries;
}

}  // namespace

RecentDownloadEntry::RecentDownloadEntry() = default;
RecentDownloadEntry::RecentDownloadEntry(const RecentDownloadEntry&) = default;
RecentDownloadEntry::RecentDownloadEntry(RecentDownloadEntry&&) noexcept =
    default;
RecentDownloadEntry& RecentDownloadEntry::operator=(
    const RecentDownloadEntry&) = default;
RecentDownloadEntry& RecentDownloadEntry::operator=(
    RecentDownloadEntry&&) noexcept = default;
RecentDownloadEntry::~RecentDownloadEntry() = default;

OpenDownloadBridge::ProfileBinding::ProfileBinding() = default;
OpenDownloadBridge::ProfileBinding::~ProfileBinding() = default;

OpenDownloadBridge::TrackedDownload::TrackedDownload() = default;
OpenDownloadBridge::TrackedDownload::~TrackedDownload() = default;

OpenDownloadBridge::OpenDownloadBridge()
    : io_task_runner_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN})) {}

OpenDownloadBridge::~OpenDownloadBridge() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  DetachAll();
}

void OpenDownloadBridge::AddObserver(Observer* observer) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (observer) {
    observers_.AddObserver(observer);
  }
}

void OpenDownloadBridge::RemoveObserver(Observer* observer) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (observer) {
    observers_.RemoveObserver(observer);
  }
}

void OpenDownloadBridge::AttachProfile(::Profile* chrome_profile,
                                       const ProfileID& profile_id,
                                       DownloadHistoryStore* history_store) {
  AttachProfileInternal(chrome_profile, profile_id, history_store, nullptr);
}

void OpenDownloadBridge::AttachProfile(
    ::Profile* chrome_profile,
    const ProfileID& profile_id,
    base::SequenceBound<DownloadHistoryStore>* history_store) {
  AttachProfileInternal(chrome_profile, profile_id, nullptr, history_store);
}

bool OpenDownloadBridge::HasProfile(::Profile* chrome_profile) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return chrome_profile && bindings_.contains(chrome_profile);
}

void OpenDownloadBridge::AttachProfileInternal(
    ::Profile* chrome_profile,
    const ProfileID& profile_id,
    DownloadHistoryStore* direct_store,
    base::SequenceBound<DownloadHistoryStore>* bound_store) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!chrome_profile || profile_id.empty()) {
    return;
  }
  if (bindings_.contains(chrome_profile)) {
    DetachProfile(chrome_profile);
  }

  if (PrefService* prefs = chrome_profile->GetPrefs()) {
    // Open renders its own Downloads popover, sidebar ring, and Library drawer.
    // Disable Chromium's automatic partial download bubble so it never pops
    // over Open's sidebar or traffic lights.
    prefs->SetBoolean(prefs::kDownloadBubblePartialViewEnabled, false);
  }

  content::DownloadManager* manager = chrome_profile->GetDownloadManager();
  if (!manager) {
    return;
  }

  auto binding = std::make_unique<ProfileBinding>();
  binding->profile_id = profile_id;
  binding->chrome_profile = chrome_profile;
  binding->manager = manager;
  binding->direct_store = direct_store;
  binding->bound_store = bound_store;
  ProfileBinding* raw_binding = binding.get();
  bindings_[chrome_profile] = std::move(binding);

  manager->AddObserver(this);

  // Observe any already-existing downloads on this manager.
  download::SimpleDownloadManager::DownloadVector existing;
  manager->GetAllDownloads(&existing);
  manager->GetUninitializedActiveDownloadsIfAny(&existing);
  for (download::DownloadItem* item : existing) {
    if (item && !item->IsTransient()) {
      ObserveItem(raw_binding, item);
      SyncItem(raw_binding, item, /*force_persist=*/false);
    }
  }

  // Load persisted history rows into our in-memory cache so GetRecentDownloads
  // merges live and historical records immediately.
  if (raw_binding->bound_store) {
    raw_binding->bound_store->PostTaskWithThisObject(base::BindOnce(
        [](base::OnceCallback<void(std::vector<DownloadRecord>)> reply,
           DownloadHistoryStore* store) {
          std::move(reply).Run(store ? store->List()
                                     : std::vector<DownloadRecord>{});
        },
        base::BindPostTaskToCurrentDefault(
            base::BindOnce(&OpenDownloadBridge::OnHistoryLoaded,
                           weak_factory_.GetWeakPtr(), profile_id))));
  } else if (raw_binding->direct_store) {
    OnHistoryLoaded(profile_id, raw_binding->direct_store->List());
  }
}

void OpenDownloadBridge::DetachProfile(::Profile* chrome_profile) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = bindings_.find(chrome_profile);
  if (it == bindings_.end()) {
    return;
  }

  std::unique_ptr<ProfileBinding> binding = std::move(it->second);
  bindings_.erase(it);

  if (binding->manager) {
    binding->manager->RemoveObserver(this);
  }

  std::set<ItemID> affected_tabs;
  for (auto dit = downloads_.begin(); dit != downloads_.end();) {
    TrackedDownload* tracked = dit->second.get();
    if (tracked->chrome_profile == chrome_profile) {
      if (tracked->item) {
        tracked->item->RemoveObserver(this);
        item_to_id_.erase(tracked->item);
      }
      if (tracked->source_tab_id) {
        affected_tabs.insert(*tracked->source_tab_id);
      }
      dit = downloads_.erase(dit);
    } else {
      ++dit;
    }
  }

  for (const ItemID& tab_id : affected_tabs) {
    UpdateTabDownloadState(tab_id);
  }
}

void OpenDownloadBridge::DetachAll() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::vector<::Profile*> profiles;
  profiles.reserve(bindings_.size());
  for (const auto& [profile, _] : bindings_) {
    profiles.push_back(profile);
  }
  for (::Profile* profile : profiles) {
    DetachProfile(profile);
  }
}

void OpenDownloadBridge::OnHistoryLoaded(ProfileID profile_id,
                                         std::vector<DownloadRecord> records) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  ProfileBinding* binding = FindBindingForProfileId(profile_id);
  if (!binding) {
    return;
  }
  bool added = false;
  for (DownloadRecord& rec : records) {
    if (rec.id.empty() || downloads_.contains(rec.id)) {
      continue;
    }
    auto tracked = std::make_unique<TrackedDownload>();
    tracked->profile_id = profile_id;
    tracked->chrome_profile = binding->chrome_profile;
    tracked->record = std::move(rec);
    tracked->file_exists = tracked->record.state == "completed";
    tracked->file_checked = false;
    downloads_[tracked->record.id] = std::move(tracked);
    added = true;
  }
  if (added) {
    RefreshFileAvailability();
  }
}

void OpenDownloadBridge::ObserveItem(ProfileBinding* binding,
                                     download::DownloadItem* item) {
  if (!binding || !item || item_to_id_.contains(item)) {
    return;
  }
  const std::string id = DownloadIdForItem(item);
  item_to_id_[item] = id;
  item->AddObserver(this);

  auto& slot = downloads_[id];
  if (!slot) {
    slot = std::make_unique<TrackedDownload>();
  }
  slot->profile_id = binding->profile_id;
  slot->chrome_profile = binding->chrome_profile;
  slot->item = item;
  slot->removed = false;

  content::WebContents* wc =
      content::DownloadItemUtils::GetOriginalWebContents(item);
  if (!wc) {
    wc = content::DownloadItemUtils::GetWebContents(item);
  }
  if (wc) {
    slot->source_tab_id = OpenTabBridge::TabIdForWebContents(wc);
  }
}

void OpenDownloadBridge::SyncItem(ProfileBinding* binding,
                                  download::DownloadItem* item,
                                  bool force_persist) {
  if (!binding || !item || item->IsTransient()) {
    return;
  }
  const std::string id = DownloadIdForItem(item);
  auto it = downloads_.find(id);
  if (it == downloads_.end()) {
    ObserveItem(binding, item);
    it = downloads_.find(id);
    if (it == downloads_.end()) {
      return;
    }
  }

  TrackedDownload* tracked = it->second.get();
  if (tracked->removed) {
    return;
  }

  if (!tracked->source_tab_id) {
    content::WebContents* wc =
        content::DownloadItemUtils::GetOriginalWebContents(item);
    if (!wc) {
      wc = content::DownloadItemUtils::GetWebContents(item);
    }
    if (wc) {
      tracked->source_tab_id = OpenTabBridge::TabIdForWebContents(wc);
    }
  }

  const std::string previous_state = tracked->record.state;
  tracked->record = RecordFromItem(item);
  tracked->bytes_per_second = item->CurrentSpeed();
  tracked->can_resume = item->CanResume();

  if (tracked->record.state == "completed") {
    if (previous_state != "completed") {
      tracked->file_exists = !item->GetFileExternallyRemoved();
      tracked->file_checked = true;
    } else if (item->GetFileExternallyRemoved()) {
      tracked->file_exists = false;
      tracked->file_checked = true;
    }
  } else {
    tracked->file_exists = false;
  }

  const base::TimeTicks now = base::TimeTicks::Now();
  const bool state_changed =
      tracked->record.state != tracked->last_persisted_state;
  const bool interval_elapsed =
      tracked->last_persisted_at.is_null() ||
      (now - tracked->last_persisted_at) >= kProgressPersistInterval;
  if (force_persist || state_changed || IsTerminalState(tracked->record.state) ||
      interval_elapsed) {
    tracked->last_persisted_at = now;
    tracked->last_persisted_state = tracked->record.state;
    PersistRecord(*binding, tracked->record);
  }

  UpdateTabDownloadState(tracked->source_tab_id);

  for (Observer& observer : observers_) {
    observer.OnDownloadUpdatedForProfile(binding->profile_id, tracked->record);
  }
}

void OpenDownloadBridge::PersistRecord(const ProfileBinding& binding,
                                       const DownloadRecord& record) {
  if (record.id.empty() || record.filename.empty()) {
    return;
  }
  if (binding.bound_store) {
    binding.bound_store->PostTaskWithThisObject(base::BindOnce(
        [](DownloadRecord rec, DownloadHistoryStore* store) {
          if (store) {
            store->Record(rec);
          }
        },
        record));
  } else if (binding.direct_store) {
    binding.direct_store->Record(record);
  }
}

void OpenDownloadBridge::UpdateTabDownloadState(
    const std::optional<ItemID>& tab_id) {
  if (!tab_id || tab_id->empty()) {
    return;
  }
  bool active = false;
  for (const auto& [_, tracked] : downloads_) {
    if (!tracked->removed && tracked->source_tab_id == tab_id &&
        IsActiveState(tracked->record.state)) {
      active = true;
      break;
    }
  }
  const bool was_active = downloading_tabs_.contains(*tab_id);
  if (active == was_active) {
    return;
  }
  if (active) {
    downloading_tabs_.insert(*tab_id);
  } else {
    downloading_tabs_.erase(*tab_id);
  }
  for (Observer& observer : observers_) {
    observer.OnTabDownloadStateChanged(*tab_id, active);
  }
}

// --- Control actions ---

bool OpenDownloadBridge::Pause(const std::string& id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = downloads_.find(id);
  if (it == downloads_.end() || !it->second->item) {
    return false;
  }
  download::DownloadItem* item = it->second->item;
  if (item->GetState() != download::DownloadItem::IN_PROGRESS ||
      item->IsPaused()) {
    return false;
  }
  item->Pause();
  return true;
}

bool OpenDownloadBridge::Resume(const std::string& id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = downloads_.find(id);
  if (it == downloads_.end() || !it->second->item) {
    return false;
  }
  download::DownloadItem* item = it->second->item;
  if (!item->CanResume()) {
    return false;
  }
  item->Resume(/*user_resume=*/true);
  return true;
}

bool OpenDownloadBridge::Cancel(const std::string& id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = downloads_.find(id);
  if (it == downloads_.end() || !it->second->item) {
    return false;
  }
  download::DownloadItem* item = it->second->item;
  if (item->GetState() != download::DownloadItem::IN_PROGRESS) {
    return false;
  }
  item->Cancel(/*user_cancel=*/true);
  return true;
}

bool OpenDownloadBridge::Retry(const std::string& id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = downloads_.find(id);
  if (it == downloads_.end() || it->second->removed) {
    return false;
  }
  TrackedDownload* tracked = it->second.get();
  if (tracked->item && tracked->item->CanResume()) {
    tracked->item->Resume(/*user_resume=*/true);
    return true;
  }

  const GURL url(tracked->record.url);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  ProfileBinding* binding = FindBindingForProfileId(tracked->profile_id);
  if (!binding || !binding->manager) {
    return false;
  }
  auto params = std::make_unique<download::DownloadUrlParameters>(
      url, kOpenDownloadRetryTrafficAnnotation);
  params->set_download_source(download::DownloadSource::INTERNAL_API);
  binding->manager->DownloadUrl(std::move(params));
  return true;
}

bool OpenDownloadBridge::OpenFile(const std::string& id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = downloads_.find(id);
  if (it == downloads_.end() || it->second->removed) {
    return false;
  }
  TrackedDownload* tracked = it->second.get();
  if (tracked->item &&
      tracked->item->GetState() == download::DownloadItem::COMPLETE &&
      tracked->item->CanOpenDownload()) {
    tracked->item->OpenDownload();
    return true;
  }
  if (tracked->record.state != "completed" ||
      tracked->record.target_path.empty() || !tracked->chrome_profile) {
    return false;
  }
  const base::FilePath path =
      base::FilePath::FromUTF8Unsafe(tracked->record.target_path);
  platform_util::OpenItem(tracked->chrome_profile, path,
                          platform_util::OPEN_FILE,
                          platform_util::OpenOperationCallback());
  return true;
}

bool OpenDownloadBridge::RevealInFolder(const std::string& id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = downloads_.find(id);
  if (it == downloads_.end() || it->second->removed) {
    return false;
  }
  TrackedDownload* tracked = it->second.get();
  if (tracked->item && tracked->item->CanShowInFolder()) {
    tracked->item->ShowDownloadInShell();
    return true;
  }
  if (tracked->record.target_path.empty() || !tracked->chrome_profile) {
    return false;
  }
  const base::FilePath path =
      base::FilePath::FromUTF8Unsafe(tracked->record.target_path);
  platform_util::ShowItemInFolder(tracked->chrome_profile, path);
  return true;
}

bool OpenDownloadBridge::MoveToTrash(const std::string& id,
                                     base::OnceCallback<void(bool)> done) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = downloads_.find(id);
  if (it == downloads_.end() || it->second->removed ||
      it->second->record.state != "completed" ||
      it->second->record.target_path.empty()) {
    if (done) {
      std::move(done).Run(false);
    }
    return false;
  }
  const base::FilePath path =
      base::FilePath::FromUTF8Unsafe(it->second->record.target_path);
  io_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&MoveFileToTrashOnBlockingSequence, path),
      base::BindOnce(&OpenDownloadBridge::OnTrashCompleted,
                     weak_factory_.GetWeakPtr(), id, std::move(done)));
  return true;
}

void OpenDownloadBridge::OnTrashCompleted(std::string id,
                                          base::OnceCallback<void(bool)> done,
                                          bool trashed) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (trashed) {
    if (auto it = downloads_.find(id); it != downloads_.end()) {
      it->second->file_exists = false;
      it->second->file_checked = true;
    }
    RemoveFromHistory(id);
  }
  if (done) {
    std::move(done).Run(trashed);
  }
}

bool OpenDownloadBridge::RemoveFromHistory(const std::string& id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = downloads_.find(id);
  if (it == downloads_.end()) {
    return false;
  }
  TrackedDownload* tracked = it->second.get();
  if (IsActiveState(tracked->record.state)) {
    return false;
  }
  const ProfileID profile_id = tracked->profile_id;
  tracked->removed = true;

  if (tracked->item) {
    download::DownloadItem* item = tracked->item;
    item->RemoveObserver(this);
    item_to_id_.erase(item);
    tracked->item = nullptr;
    item->Remove();
  }
  downloads_.erase(it);

  if (ProfileBinding* binding = FindBindingForProfileId(profile_id)) {
    if (binding->bound_store) {
      binding->bound_store->PostTaskWithThisObject(base::BindOnce(
          [](std::string remove_id, DownloadHistoryStore* store) {
            if (store) {
              store->Remove(remove_id);
            }
          },
          id));
    } else if (binding->direct_store) {
      binding->direct_store->Remove(id);
    }
  }

  for (Observer& observer : observers_) {
    observer.OnDownloadRemoved(id);
  }
  return true;
}

bool OpenDownloadBridge::ClearHistory(const ProfileID& profile_id,
                                      std::optional<TimestampSec> since,
                                      TimestampSec through) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  ProfileBinding* binding = FindBindingForProfileId(profile_id);
  if (!binding) {
    return false;
  }
  const TimestampSec effective_through =
      through > 0.0 ? through : NowSec() + 1.0;

  std::vector<std::string> removed_ids;
  for (auto it = downloads_.begin(); it != downloads_.end();) {
    TrackedDownload* tracked = it->second.get();
    if (tracked->profile_id == profile_id &&
        !IsActiveState(tracked->record.state) &&
        tracked->record.started_at <= effective_through &&
        (!since || tracked->record.started_at >= *since)) {
      removed_ids.push_back(it->first);
      if (tracked->item) {
        tracked->item->RemoveObserver(this);
        item_to_id_.erase(tracked->item);
      }
      it = downloads_.erase(it);
    } else {
      ++it;
    }
  }

  if (binding->bound_store) {
    binding->bound_store->PostTaskWithThisObject(base::BindOnce(
        [](std::optional<TimestampSec> s, TimestampSec t,
           DownloadHistoryStore* store) {
          if (store) {
            store->Clear(s, t);
          }
        },
        since, effective_through));
  } else if (binding->direct_store) {
    binding->direct_store->Clear(since, effective_through);
  }

  for (const std::string& id : removed_ids) {
    for (Observer& observer : observers_) {
      observer.OnDownloadRemoved(id);
    }
  }
  return true;
}

// --- Queries ---

bool OpenDownloadBridge::HasActiveDownloads(
    const std::optional<ProfileID>& profile_id) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  for (const auto& [_, tracked] : downloads_) {
    if (tracked->removed) {
      continue;
    }
    if (profile_id && tracked->profile_id != *profile_id) {
      continue;
    }
    if (IsActiveState(tracked->record.state)) {
      return true;
    }
  }
  return false;
}

DownloadProgressSummary OpenDownloadBridge::GetAggregateProgress(
    const std::optional<ProfileID>& profile_id) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  DownloadProgressSummary summary;
  int64_t known_received = 0;
  int64_t known_total = 0;

  for (const auto& [_, tracked] : downloads_) {
    if (tracked->removed) {
      continue;
    }
    if (profile_id && tracked->profile_id != *profile_id) {
      continue;
    }
    if (!IsActiveState(tracked->record.state)) {
      continue;
    }
    ++summary.active_count;
    summary.received_bytes += std::max<int64_t>(0, tracked->record.received_bytes);
    summary.bytes_per_second += std::max<int64_t>(0, tracked->bytes_per_second);
    if (tracked->record.total_bytes > 0) {
      known_received += std::max<int64_t>(0, tracked->record.received_bytes);
      known_total += tracked->record.total_bytes;
      summary.total_bytes += tracked->record.total_bytes;
    } else {
      summary.indeterminate = true;
    }
  }

  if (known_total > 0) {
    summary.progress = std::clamp(
        static_cast<double>(known_received) / static_cast<double>(known_total),
        0.0, 1.0);
  }
  return summary;
}

std::vector<RecentDownloadEntry> OpenDownloadBridge::GetRecentDownloads(
    const ProfileID& profile_id,
    int limit) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::vector<RecentDownloadEntry> entries;
  if (limit <= 0) {
    return entries;
  }

  for (const auto& [_, tracked] : downloads_) {
    if (tracked->removed) {
      continue;
    }
    if (!profile_id.empty() && tracked->profile_id != profile_id) {
      continue;
    }
    RecentDownloadEntry entry;
    entry.record = tracked->record;
    entry.profile_id = tracked->profile_id;
    entry.file_exists = tracked->file_exists;
    entry.bytes_per_second = tracked->bytes_per_second;
    entry.can_resume = tracked->can_resume;
    entry.is_live = tracked->item != nullptr;
    entries.push_back(std::move(entry));
  }

  std::sort(entries.begin(), entries.end(),
            [](const RecentDownloadEntry& a, const RecentDownloadEntry& b) {
              const bool a_active = IsActiveState(a.record.state);
              const bool b_active = IsActiveState(b.record.state);
              if (a_active != b_active) {
                return a_active;
              }
              const TimestampSec a_ts =
                  a.record.ended_at > 0.0 ? a.record.ended_at
                                          : a.record.started_at;
              const TimestampSec b_ts =
                  b.record.ended_at > 0.0 ? b.record.ended_at
                                          : b.record.started_at;
              if (a_ts != b_ts) {
                return a_ts > b_ts;
              }
              return a.record.id < b.record.id;
            });

  if (static_cast<int>(entries.size()) > limit) {
    entries.resize(static_cast<size_t>(limit));
  }
  return entries;
}

void OpenDownloadBridge::SyncLiveDownloadsFromManagers() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  for (auto& [_, binding] : bindings_) {
    if (!binding || !binding->chrome_profile) {
      continue;
    }
    content::DownloadManager* manager =
        binding->chrome_profile->GetDownloadManager();
    if (!manager) {
      continue;
    }
    if (binding->manager != manager) {
      if (binding->manager) {
        binding->manager->RemoveObserver(this);
      }
      binding->manager = manager;
      manager->AddObserver(this);
    }
    download::SimpleDownloadManager::DownloadVector items;
    manager->GetAllDownloads(&items);
    manager->GetUninitializedActiveDownloadsIfAny(&items);
    for (download::DownloadItem* item : items) {
      if (!item || item->IsTransient()) {
        continue;
      }
      if (!item_to_id_.contains(item)) {
        ObserveItem(binding.get(), item);
        SyncItem(binding.get(), item, /*force_persist=*/true);
      } else {
        auto id_it = item_to_id_.find(item);
        if (id_it != item_to_id_.end()) {
          auto d_it = downloads_.find(id_it->second);
          if (d_it != downloads_.end() && !d_it->second->removed) {
            const DownloadRecord latest = RecordFromItem(item);
            if (latest.state != d_it->second->record.state ||
                latest.received_bytes != d_it->second->record.received_bytes ||
                latest.target_path != d_it->second->record.target_path) {
              SyncItem(binding.get(), item, /*force_persist=*/false);
            }
          }
        }
      }
    }
  }
}

void OpenDownloadBridge::GetRecentDownloadsAsync(
    const ProfileID& profile_id,
    int limit,
    base::OnceCallback<void(std::vector<RecentDownloadEntry>)> callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  SyncLiveDownloadsFromManagers();
  std::vector<RecentDownloadEntry> snapshot =
      GetRecentDownloads(profile_id, limit);
  io_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&PopulateFileExistsOnBlockingSequence,
                     std::move(snapshot)),
      base::BindOnce(
          [](base::WeakPtr<OpenDownloadBridge> self,
             base::OnceCallback<void(std::vector<RecentDownloadEntry>)> cb,
             std::vector<RecentDownloadEntry> checked) {
            if (self) {
              for (const RecentDownloadEntry& e : checked) {
                if (auto it = self->downloads_.find(e.record.id);
                    it != self->downloads_.end()) {
                  it->second->file_exists = e.file_exists;
                  it->second->file_checked = true;
                }
              }
            }
            if (cb) {
              std::move(cb).Run(std::move(checked));
            }
          },
          weak_factory_.GetWeakPtr(), std::move(callback)));
}

void OpenDownloadBridge::RefreshFileAvailability() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  SyncLiveDownloadsFromManagers();
  std::vector<std::pair<std::string, base::FilePath>> checks;
  for (const auto& [id, tracked] : downloads_) {
    if (!tracked->removed && tracked->record.state == "completed" &&
        !tracked->record.target_path.empty()) {
      checks.emplace_back(
          id, base::FilePath::FromUTF8Unsafe(tracked->record.target_path));
    }
  }
  if (checks.empty()) {
    return;
  }
  io_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&CheckPathsExistOnBlockingSequence, std::move(checks)),
      base::BindOnce(&OpenDownloadBridge::OnFileAvailabilityChecked,
                     weak_factory_.GetWeakPtr()));
}

void OpenDownloadBridge::OnFileAvailabilityChecked(
    std::vector<std::pair<std::string, bool>> results) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  for (const auto& [id, exists] : results) {
    auto it = downloads_.find(id);
    if (it == downloads_.end() || it->second->removed) {
      continue;
    }
    const bool changed =
        !it->second->file_checked || it->second->file_exists != exists;
    it->second->file_exists = exists;
    it->second->file_checked = true;
    if (changed) {
      for (Observer& observer : observers_) {
        observer.OnDownloadUpdatedForProfile(it->second->profile_id,
                                             it->second->record);
      }
    }
  }
}

// --- Preferences sync ---

// static
base::FilePath OpenDownloadBridge::ExpandDownloadDirectory(
    std::string_view raw) {
  std::string trimmed =
      std::string(base::TrimWhitespaceASCII(raw, base::TRIM_ALL));
  if (trimmed.empty() || trimmed == "~/Downloads" || trimmed == "~\\Downloads") {
    base::FilePath home;
    if (base::PathService::Get(base::DIR_HOME, &home) && !home.empty()) {
      return home.AppendASCII("Downloads");
    }
    return DownloadPrefs::GetDefaultDownloadDirectory();
  }
  if (trimmed == "~" || base::StartsWith(trimmed, "~/") ||
      base::StartsWith(trimmed, "~\\")) {
    base::FilePath home;
    if (base::PathService::Get(base::DIR_HOME, &home) && !home.empty()) {
      if (trimmed.size() <= 2) {
        return home;
      }
      return home.Append(base::FilePath::FromUTF8Unsafe(trimmed.substr(2)));
    }
  }
  return base::FilePath::FromUTF8Unsafe(trimmed);
}

// static
void OpenDownloadBridge::ApplyDownloadPreferences(
    ::Profile* chrome_profile,
    const base::FilePath& download_dir,
    bool ask_each_time) {
  if (!chrome_profile) {
    return;
  }
  PrefService* prefs = chrome_profile->GetPrefs();
  if (!prefs) {
    return;
  }
  base::FilePath resolved = download_dir.empty()
                                ? DownloadPrefs::GetDefaultDownloadDirectory()
                                : download_dir;
  prefs->SetFilePath(prefs::kDownloadDefaultDirectory, resolved);
  prefs->SetBoolean(prefs::kPromptForDownload, ask_each_time);
  prefs->SetBoolean(prefs::kDownloadBubblePartialViewEnabled, false);
  if (DownloadPrefs* download_prefs =
          DownloadPrefs::FromBrowserContext(chrome_profile)) {
    download_prefs->SetDownloadPath(resolved);
  }
}

// static
void OpenDownloadBridge::ApplyDownloadPreferences(
    ::Profile* chrome_profile,
    std::string_view download_dir_utf8,
    bool ask_each_time) {
  ApplyDownloadPreferences(chrome_profile,
                           ExpandDownloadDirectory(download_dir_utf8),
                           ask_each_time);
}

// --- content::DownloadManager::Observer ---

void OpenDownloadBridge::OnDownloadCreated(content::DownloadManager* manager,
                                           download::DownloadItem* item) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  ProfileBinding* binding = FindBindingForManager(manager);
  if (!binding || !item || item->IsTransient()) {
    return;
  }
  ObserveItem(binding, item);
  SyncItem(binding, item, /*force_persist=*/true);
}

void OpenDownloadBridge::OnManagerInitialized() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  SyncLiveDownloadsFromManagers();
}

void OpenDownloadBridge::ManagerGoingDown(content::DownloadManager* manager) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  ProfileBinding* binding = FindBindingForManager(manager);
  if (binding) {
    DetachProfile(binding->chrome_profile);
  }
}

// --- download::DownloadItem::Observer ---

void OpenDownloadBridge::OnDownloadUpdated(download::DownloadItem* download) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!download || download->IsTransient()) {
    return;
  }
  auto id_it = item_to_id_.find(download);
  if (id_it == item_to_id_.end()) {
    return;
  }
  auto d_it = downloads_.find(id_it->second);
  if (d_it == downloads_.end()) {
    return;
  }
  ProfileBinding* binding = FindBindingForProfileId(d_it->second->profile_id);
  if (!binding) {
    return;
  }
  SyncItem(binding, download, /*force_persist=*/false);
}

void OpenDownloadBridge::OnDownloadOpened(download::DownloadItem* download) {
  OnDownloadUpdated(download);
}

void OpenDownloadBridge::OnDownloadRemoved(download::DownloadItem* download) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto id_it = item_to_id_.find(download);
  if (id_it == item_to_id_.end()) {
    return;
  }
  const std::string id = id_it->second;
  download->RemoveObserver(this);
  item_to_id_.erase(id_it);

  std::optional<ItemID> tab_id;
  if (auto d_it = downloads_.find(id); d_it != downloads_.end()) {
    tab_id = d_it->second->source_tab_id;
    d_it->second->item = nullptr;
  }
  UpdateTabDownloadState(tab_id);
}

void OpenDownloadBridge::OnDownloadDestroyed(download::DownloadItem* download) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto id_it = item_to_id_.find(download);
  if (id_it == item_to_id_.end()) {
    return;
  }
  const std::string id = id_it->second;
  download->RemoveObserver(this);
  item_to_id_.erase(id_it);

  std::optional<ItemID> tab_id;
  if (auto d_it = downloads_.find(id); d_it != downloads_.end()) {
    tab_id = d_it->second->source_tab_id;
    d_it->second->item = nullptr;
  }
  UpdateTabDownloadState(tab_id);
}

// --- Helpers ---

OpenDownloadBridge::ProfileBinding* OpenDownloadBridge::FindBindingForManager(
    content::DownloadManager* manager) {
  for (auto& [_, binding] : bindings_) {
    if (binding->manager == manager) {
      return binding.get();
    }
  }
  return nullptr;
}

OpenDownloadBridge::ProfileBinding* OpenDownloadBridge::FindBindingForProfileId(
    const ProfileID& profile_id) {
  for (auto& [_, binding] : bindings_) {
    if (binding->profile_id == profile_id) {
      return binding.get();
    }
  }
  return nullptr;
}

// static
std::string OpenDownloadBridge::DownloadIdForItem(
    download::DownloadItem* item) {
  if (!item) {
    return std::string();
  }
  if (!item->GetGuid().empty()) {
    return item->GetGuid();
  }
  return base::NumberToString(item->GetId());
}

// static
DownloadRecord OpenDownloadBridge::RecordFromItem(
    download::DownloadItem* item) {
  DownloadRecord rec;
  rec.id = DownloadIdForItem(item);

  const GURL& url =
      item->GetURL().is_valid() ? item->GetURL() : item->GetOriginalUrl();
  rec.url = url.spec();

  base::FilePath report_name = item->GetFileNameToReportUser();
  if (!report_name.empty()) {
    rec.filename = report_name.BaseName().AsUTF8Unsafe();
  } else if (!item->GetTargetFilePath().empty()) {
    rec.filename = item->GetTargetFilePath().BaseName().AsUTF8Unsafe();
  } else if (!item->GetSuggestedFilename().empty()) {
    rec.filename = item->GetSuggestedFilename();
  } else {
    rec.filename = "download";
  }

  const base::FilePath& path = !item->GetTargetFilePath().empty()
                                   ? item->GetTargetFilePath()
                                   : item->GetFullPath();
  rec.target_path = path.AsUTF8Unsafe();

  rec.mime_type = !item->GetMimeType().empty() ? item->GetMimeType()
                                               : item->GetOriginalMimeType();

  switch (item->GetState()) {
    case download::DownloadItem::IN_PROGRESS:
      rec.state = item->IsPaused() ? "paused" : "in_progress";
      break;
    case download::DownloadItem::COMPLETE:
      rec.state = "completed";
      break;
    case download::DownloadItem::CANCELLED:
      rec.state = "cancelled";
      break;
    case download::DownloadItem::INTERRUPTED:
      rec.state = "interrupted";
      break;
    case download::DownloadItem::MAX_DOWNLOAD_STATE:
      rec.state = "interrupted";
      break;
  }

  rec.received_bytes = item->GetReceivedBytes();
  rec.total_bytes = item->GetTotalBytes() > 0 ? item->GetTotalBytes() : -1;

  const base::Time start = item->GetStartTime();
  rec.started_at =
      start.is_null() ? NowSec() : start.InSecondsFSinceUnixEpoch();

  const base::Time end = item->GetEndTime();
  if (!end.is_null()) {
    rec.ended_at = end.InSecondsFSinceUnixEpoch();
  } else if (IsTerminalState(rec.state)) {
    rec.ended_at = NowSec();
  } else {
    rec.ended_at = 0.0;
  }
  return rec;
}

}  // namespace open_unified
