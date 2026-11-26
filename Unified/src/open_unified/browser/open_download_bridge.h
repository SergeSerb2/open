// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_DOWNLOAD_BRIDGE_H_
#define OPEN_UNIFIED_BROWSER_OPEN_DOWNLOAD_BRIDGE_H_

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "base/sequence_checker.h"
#include "base/task/sequenced_task_runner.h"
#include "base/threading/sequence_bound.h"
#include "base/time/time.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/download_manager.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/core/store/sqlite_stores.h"

class Profile;

namespace open_unified {

// Aggregate download progress across active transfers (feeds sidebar ring).
struct DownloadProgressSummary {
  int active_count = 0;
  double progress = 0.0;  // 0.0 - 1.0 across transfers with known total_bytes
  bool indeterminate = false;
  int64_t received_bytes = 0;
  int64_t total_bytes = 0;
  int64_t bytes_per_second = 0;
};

// Enriched download record returned by GetRecentDownloads() / async queries.
struct RecentDownloadEntry {
  RecentDownloadEntry();
  RecentDownloadEntry(const RecentDownloadEntry&);
  RecentDownloadEntry(RecentDownloadEntry&&) noexcept;
  RecentDownloadEntry& operator=(const RecentDownloadEntry&);
  RecentDownloadEntry& operator=(RecentDownloadEntry&&) noexcept;
  ~RecentDownloadEntry();

  DownloadRecord record;
  ProfileID profile_id;
  bool file_exists = false;
  int64_t bytes_per_second = 0;
  bool can_resume = false;
  bool is_live = false;
};

// Bridges Chromium's per-Profile content::DownloadManager and live
// download::DownloadItem instances to Open's DownloadHistoryStore, Sidebar
// download ring, Recent Downloads popover, Library push events, and
// OpenSleepController download protection.
//
// Threading: UI thread only. Disk I/O (PathExists, MoveToTrash, SQLite when
// bound via SequenceBound) runs on background blocking sequences.
class OpenDownloadBridge : public content::DownloadManager::Observer,
                           public download::DownloadItem::Observer {
 public:
  class Observer : public base::CheckedObserver {
   public:
    // Called whenever a download is created, progresses, pauses, completes,
    // cancels, fails, or has its file availability updated.
    virtual void OnDownloadUpdated(const DownloadRecord& record) {}
    virtual void OnDownloadUpdatedForProfile(const ProfileID& profile_id,
                                             const DownloadRecord& record) {
      OnDownloadUpdated(record);
    }
    virtual void OnDownloadRemoved(const std::string& id) {}
    // Feeds OpenSleepController / SleepScheduler so tabs with active downloads
    // are never frozen or discarded.
    virtual void OnTabDownloadStateChanged(const ItemID& tab_id,
                                           bool is_downloading) {}

   protected:
    ~Observer() override = default;
  };

  OpenDownloadBridge();
  ~OpenDownloadBridge() override;

  OpenDownloadBridge(const OpenDownloadBridge&) = delete;
  OpenDownloadBridge& operator=(const OpenDownloadBridge&) = delete;

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);

  // Observes |chrome_profile|'s DownloadManager and all of its active
  // DownloadItems, persisting updates to |history_store|.
  void AttachProfile(::Profile* chrome_profile,
                     const ProfileID& profile_id,
                     DownloadHistoryStore* history_store);
  void AttachProfile(::Profile* chrome_profile,
                     const ProfileID& profile_id,
                     base::SequenceBound<DownloadHistoryStore>* history_store);
  void DetachProfile(::Profile* chrome_profile);
  void DetachAll();

  // Control actions on live or historical downloads by ID (DownloadItem GUID).
  bool Pause(const std::string& id);
  bool Resume(const std::string& id);
  bool Cancel(const std::string& id);
  bool Retry(const std::string& id);
  bool OpenFile(const std::string& id);
  bool RevealInFolder(const std::string& id);
  bool MoveToTrash(const std::string& id,
                   base::OnceCallback<void(bool)> done = {});
  bool RemoveFromHistory(const std::string& id);
  bool ClearHistory(const ProfileID& profile_id,
                    std::optional<TimestampSec> since = std::nullopt,
                    TimestampSec through = 0.0);

  // Aggregate status for Sidebar download progress ring and quit guard.
  bool HasActiveDownloads(
      const std::optional<ProfileID>& profile_id = std::nullopt) const;
  DownloadProgressSummary GetAggregateProgress(
      const std::optional<ProfileID>& profile_id = std::nullopt) const;

  // Returns recent downloads for |profile_id| (newest first), merging live
  // Chromium DownloadItems and persisted DownloadHistoryStore rows.
  // Also schedules an async base::PathExists refresh when file status is stale.
  std::vector<RecentDownloadEntry> GetRecentDownloads(
      const ProfileID& profile_id,
      int limit = 50) const;

  // Same as GetRecentDownloads(), but performs a fresh live base::PathExists()
  // check for every completed item on a blocking ThreadPool sequence before
  // invoking |callback| on the UI thread.
  void GetRecentDownloadsAsync(
      const ProfileID& profile_id,
      int limit,
      base::OnceCallback<void(std::vector<RecentDownloadEntry>)> callback);

  // Triggers an asynchronous base::PathExists() pass for completed downloads
  // and notifies observers when availability changes.
  void RefreshFileAvailability();

  // Syncs Open's ProfileSettings download location & prompt toggle directly
  // into Chromium's DownloadPrefs (prefs::kDownloadDefaultDirectory and
  // prefs::kPromptForDownload).
  static void ApplyDownloadPreferences(::Profile* chrome_profile,
                                       const base::FilePath& download_dir,
                                       bool ask_each_time);
  static void ApplyDownloadPreferences(::Profile* chrome_profile,
                                       std::string_view download_dir_utf8,
                                       bool ask_each_time);

  // content::DownloadManager::Observer:
  void OnDownloadCreated(content::DownloadManager* manager,
                         download::DownloadItem* item) override;
  void OnManagerInitialized() override;
  void ManagerGoingDown(content::DownloadManager* manager) override;

  // download::DownloadItem::Observer:
  void OnDownloadUpdated(download::DownloadItem* download) override;
  void OnDownloadOpened(download::DownloadItem* download) override;
  void OnDownloadRemoved(download::DownloadItem* download) override;
  void OnDownloadDestroyed(download::DownloadItem* download) override;

 private:
  struct ProfileBinding {
    ProfileBinding();
    ~ProfileBinding();

    ProfileID profile_id;
    raw_ptr<::Profile> chrome_profile = nullptr;
    raw_ptr<content::DownloadManager> manager = nullptr;
    raw_ptr<DownloadHistoryStore> direct_store = nullptr;
    raw_ptr<base::SequenceBound<DownloadHistoryStore>> bound_store = nullptr;
  };

  struct TrackedDownload {
    TrackedDownload();
    ~TrackedDownload();

    ProfileID profile_id;
    raw_ptr<::Profile> chrome_profile = nullptr;
    raw_ptr<download::DownloadItem> item = nullptr;  // Null for history-only.
    DownloadRecord record;
    std::optional<ItemID> source_tab_id;
    int64_t bytes_per_second = 0;
    bool can_resume = false;
    bool file_exists = false;
    bool file_checked = false;
    bool removed = false;
    base::TimeTicks last_persisted_at;
    std::string last_persisted_state;
  };

  void AttachProfileInternal(
      ::Profile* chrome_profile,
      const ProfileID& profile_id,
      DownloadHistoryStore* direct_store,
      base::SequenceBound<DownloadHistoryStore>* bound_store);
  void ObserveItem(ProfileBinding* binding, download::DownloadItem* item);
  void SyncItem(ProfileBinding* binding,
                download::DownloadItem* item,
                bool force_persist);
  void PersistRecord(const ProfileBinding& binding,
                     const DownloadRecord& record);
  void OnHistoryLoaded(ProfileID profile_id,
                       std::vector<DownloadRecord> records);
  void UpdateTabDownloadState(const std::optional<ItemID>& tab_id);
  void OnFileAvailabilityChecked(
      std::vector<std::pair<std::string, bool>> results);
  void OnTrashCompleted(std::string id,
                        base::OnceCallback<void(bool)> done,
                        bool trashed);
  ProfileBinding* FindBindingForManager(content::DownloadManager* manager);
  ProfileBinding* FindBindingForProfileId(const ProfileID& profile_id);
  static DownloadRecord RecordFromItem(download::DownloadItem* item);
  static std::string DownloadIdForItem(download::DownloadItem* item);
  static base::FilePath ExpandDownloadDirectory(std::string_view raw);

  SEQUENCE_CHECKER(sequence_checker_);

  scoped_refptr<base::SequencedTaskRunner> io_task_runner_;
  std::map<raw_ptr<::Profile>, std::unique_ptr<ProfileBinding>> bindings_;
  std::map<std::string, std::unique_ptr<TrackedDownload>> downloads_;
  std::map<raw_ptr<download::DownloadItem>, std::string> item_to_id_;
  std::set<ItemID> downloading_tabs_;
  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenDownloadBridge> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_DOWNLOAD_BRIDGE_H_
