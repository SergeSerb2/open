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
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
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

  // Sets the sequenced blocking task runner used for disk I/O. If unset, a
  // lazy ThreadPool MayBlock + BLOCK_SHUTDOWN runner is created on first use.
  void SetIoTaskRunner(scoped_refptr<base::SequencedTaskRunner> runner);

  // Schedules an atomic write after 1s debounce, capped at 10s max wait from
  // the first unsaved change. Serializes on the calling thread and writes on
  // the I/O task runner.
  void ScheduleSave(const BrowserModel* model);

  // Schedules a lower-priority metadata-only save (10s delay) if no save is
  // already scheduled.
  void ScheduleMetadataSave(const BrowserModel* model);

  // Cancels any pending timer and writes via atomic temp+rename. On
  // BrowserThread::UI, serializes synchronously and dispatches file I/O to the
  // BLOCK_SHUTDOWN I/O task runner; on blocking sequences, writes inline.
  bool SaveNow(const BrowserModel& model, std::string* error_out = nullptr);

  // Flushes any pending dirty model asynchronously onto the I/O task runner.
  void FlushAsync(
      base::OnceCallback<void(bool ok, std::string error)> done = {});

  // Flushes any pending dirty model (inline on blocking sequences, or
  // dispatched to the BLOCK_SHUTDOWN I/O task runner on BrowserThread::UI).
  bool Flush(std::string* error_out = nullptr);

  // Loads <data_root>/State/browser.json. Returns nullptr if the file does not
  // exist or cannot be parsed/validated; corrupt or unsupported files are
  // moved aside to browser.corrupt-<epoch>.json before returning nullptr.
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
  scoped_refptr<base::SequencedTaskRunner> GetOrCreateIoTaskRunner();
  void OnTimerFired();
  void OnAsyncWriteComplete(
      base::OnceCallback<void(bool ok, std::string error)> done,
      std::string error);

  base::FilePath data_root_;
  base::FilePath file_path_;
  scoped_refptr<base::SequencedTaskRunner> io_runner_;

  base::OneShotTimer save_timer_;
  raw_ptr<const BrowserModel> dirty_model_ = nullptr;
  std::optional<base::TimeTicks> dirty_since_;
  base::RepeatingCallback<void(const std::string&)> on_save_failure_;
  base::WeakPtrFactory<SnapshotStore> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_STORE_SNAPSHOT_STORE_H_
