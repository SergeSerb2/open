// Copyright 2026 The Open Authors. All rights reserved.
// Atomic JSON snapshot persistence for <data_root>/State/browser.json
// (schemaVersion = 1, parity with Packages/OpenKit OpenStore/SnapshotDTOs.swift).

#ifndef OPEN_UNIFIED_CORE_STORE_SNAPSHOT_STORE_H_
#define OPEN_UNIFIED_CORE_STORE_SNAPSHOT_STORE_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

class SnapshotStore {
 public:
  static constexpr int kSchemaVersion = 1;
  static constexpr base::TimeDelta kDebounceDelay = base::Seconds(1);
  static constexpr base::TimeDelta kMaxSaveWait = base::Seconds(10);
  static constexpr base::TimeDelta kMetadataSaveDelay = base::Seconds(10);

  explicit SnapshotStore(base::FilePath data_root);
  ~SnapshotStore();

  SnapshotStore(const SnapshotStore&) = delete;
  SnapshotStore& operator=(const SnapshotStore&) = delete;

  const base::FilePath& data_root() const { return data_root_; }
  const base::FilePath& file_path() const { return file_path_; }
  bool is_dirty() const { return dirty_model_ != nullptr; }

  // Optional callback invoked when a debounced or synchronous write fails.
  void SetSaveFailureCallback(
      base::RepeatingCallback<void(const std::string&)> callback);

  // Schedules an atomic write after 1s debounce, capped at 10s max wait from
  // the first unsaved change.
  void ScheduleSave(const BrowserModel* model);

  // Schedules a lower-priority metadata-only save (10s delay) if no save is
  // already scheduled.
  void ScheduleMetadataSave(const BrowserModel* model);

  // Cancels any pending timer and writes immediately via atomic temp+rename.
  bool SaveNow(const BrowserModel& model, std::string* error_out = nullptr);

  // Flushes any pending dirty model synchronously.
  bool Flush(std::string* error_out = nullptr);

  // Loads <data_root>/State/browser.json. Returns nullptr if the file does not
  // exist or cannot be parsed. Populates |repairs_out| if duplicate IDs were
  // repaired during decode.
  std::unique_ptr<BrowserModel> Load(
      std::vector<std::string>* repairs_out = nullptr,
      std::string* error_out = nullptr) const;

  // Pure JSON serialization/deserialization helpers (reusable by Sync/Archive).
  static base::DictValue SerializeModel(const BrowserModel& model);
  static std::unique_ptr<BrowserModel> DeserializeModel(
      const base::DictValue& root,
      std::vector<std::string>* repairs_out = nullptr,
      std::string* error_out = nullptr);

  static base::DictValue SerializeTab(const Tab& tab);
  static Tab DeserializeTab(const base::DictValue& dict);
  static base::DictValue SerializeNode(const SidebarNode& node);
  static std::optional<SidebarNode> DeserializeNode(const base::DictValue& dict);

 private:
  void OnTimerFired();

  base::FilePath data_root_;
  base::FilePath file_path_;

  base::OneShotTimer save_timer_;
  const BrowserModel* dirty_model_ = nullptr;
  std::optional<base::TimeTicks> dirty_since_;
  base::RepeatingCallback<void(const std::string&)> on_save_failure_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_STORE_SNAPSHOT_STORE_H_
