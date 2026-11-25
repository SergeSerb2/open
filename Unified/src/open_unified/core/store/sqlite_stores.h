// Copyright 2026 The Open Authors. All rights reserved.
// Cross-platform SQLite stores built on Chromium //sql:
// HistoryStore (FTS5), ArchiveStore, SleepStore, DownloadHistoryStore,
// and FaviconStore.

#ifndef OPEN_UNIFIED_CORE_STORE_SQLITE_STORES_H_
#define OPEN_UNIFIED_CORE_STORE_SQLITE_STORES_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "open_unified/core/model/open_types.h"
#include "sql/database.h"

namespace open_unified {

// --- HistoryStore (history.sqlite3, FTS5 + frecency ranking) ---

class HistoryStore {
 public:
  explicit HistoryStore(base::FilePath db_path);
  ~HistoryStore();

  HistoryStore(const HistoryStore&) = delete;
  HistoryStore& operator=(const HistoryStore&) = delete;

  bool Open();
  void Close();
  bool is_open() const { return db_.is_open(); }
  uint64_t deletion_generation() const { return deletion_generation_; }

  std::optional<int64_t> RecordVisit(const std::string& url,
                                     const std::string& title,
                                     TimestampSec time = 0.0,
                                     const std::string& transition = "link",
                                     bool typed = false);

  bool UpdateTitle(const std::string& title,
                   int64_t visit_id,
                   TimestampSec time);

  // FTS5 prefix match ranked by frecency, with escaped LIKE substring fallback.
  std::vector<HistoryEntry> Search(const std::string& query, int limit = 20);

  // Chronological recent URLs (newest first).
  std::vector<HistoryEntry> Recent(int limit = 100, int offset = 0);

  bool DeleteUrl(const std::string& url);
  bool DeleteIds(const std::vector<int64_t>& ids);
  bool ClearRange(std::optional<TimestampSec> since, TimestampSec through);
  int64_t UrlCount();

 private:
  std::vector<HistoryEntry> TopEntries(int limit);
  std::vector<HistoryEntry> SubstringSearch(const std::string& text, int limit);

  base::FilePath db_path_;
  sql::Database db_;
  bool closed_ = false;
  uint64_t deletion_generation_ = 0;
};

// --- ArchiveStore (archive.sqlite3) ---

class ArchiveStore {
 public:
  explicit ArchiveStore(base::FilePath db_path);
  ~ArchiveStore();

  ArchiveStore(const ArchiveStore&) = delete;
  ArchiveStore& operator=(const ArchiveStore&) = delete;

  bool Open();
  void Close();
  bool is_open() const { return db_.is_open(); }

  bool Archive(const ArchivedTabRecord& record);
  bool Archive(const std::vector<ArchivedTabRecord>& records);

  std::vector<ArchivedTabRecord> List(
      int limit = 100,
      int offset = 0,
      const std::string& query = "",
      const std::optional<SpaceID>& space_id = std::nullopt,
      const std::optional<std::string>& reason = std::nullopt);

  std::optional<ArchivedTabRecord> Get(const ItemID& id);
  // Returns the archived record and removes it atomically.
  std::optional<ArchivedTabRecord> Restore(const ItemID& id);

  bool Delete(const ItemID& id);
  bool DeleteIds(const std::vector<ItemID>& ids);
  bool DeleteAll();
  int PurgeOlderThanDays(int days, TimestampSec now = 0.0);
  int64_t Count();

 private:
  base::FilePath db_path_;
  sql::Database db_;
  bool closed_ = false;
};

// --- SleepStore (sleep.sqlite3) ---

struct SleepHistoryRecord {
  ItemID tab_id;
  std::vector<uint8_t> container;
  int current_index = 0;
  int entry_count = 0;
  std::string current_url;
  std::string current_title;
  std::optional<std::string> favicon_url;
  bool has_page_state = false;
  int container_version = 1;
  std::string chromium_tag;
  TimestampSec captured_at = 0.0;
};

class SleepStore {
 public:
  static constexpr size_t kMaxContainerBytes = 2 * 1024 * 1024;

  explicit SleepStore(base::FilePath db_path);
  ~SleepStore();

  SleepStore(const SleepStore&) = delete;
  SleepStore& operator=(const SleepStore&) = delete;

  bool Open();
  void Close();
  bool is_open() const { return db_.is_open(); }

  bool Save(const SleepHistoryRecord& record);
  std::optional<SleepHistoryRecord> Load(const ItemID& tab_id);
  bool Delete(const ItemID& tab_id);
  bool DeleteIds(const std::vector<ItemID>& tab_ids);
  std::vector<ItemID> AllTabIds();
  int64_t TotalBytes();

  std::optional<std::string> GetMeta(const std::string& key);
  bool SetMeta(const std::string& key, const std::string& value);

 private:
  base::FilePath db_path_;
  sql::Database db_;
  bool closed_ = false;
};

// --- DownloadHistoryStore (downloads.sqlite3, max 1,000 rows) ---

class DownloadHistoryStore {
 public:
  static constexpr int kMaxRows = 1000;
  static constexpr size_t kMaxPayloadBytes = 96 * 1024;

  explicit DownloadHistoryStore(base::FilePath db_path);
  ~DownloadHistoryStore();

  DownloadHistoryStore(const DownloadHistoryStore&) = delete;
  DownloadHistoryStore& operator=(const DownloadHistoryStore&) = delete;

  bool Open();
  void Close();
  bool is_open() const { return db_.is_open(); }

  bool Record(const DownloadRecord& record);
  std::vector<DownloadRecord> List(int limit = kMaxRows);
  bool Remove(const std::string& id);
  bool Clear(std::optional<TimestampSec> since, TimestampSec through);

 private:
  base::FilePath db_path_;
  sql::Database db_;
  bool closed_ = false;
};

// --- FaviconStore (favicons.sqlite3, 16 MiB DB cap) ---

struct FaviconRecord {
  std::vector<uint8_t> png32;
  std::vector<uint8_t> png64;
  std::optional<std::string> icon_url;
  TimestampSec fetched_at = 0.0;
  TimestampSec expires_at = 0.0;
  int status = 0;  // 0 = ok, 1 = missing, 2 = error
};

class FaviconStore {
 public:
  static constexpr int kMaxEntries = 4096;
  static constexpr int64_t kMaxStoredBytes = 8 * 1024 * 1024;
  static constexpr int64_t kMaxDatabaseBytes = 16 * 1024 * 1024;
  static constexpr int kPageSize = 4096;
  static constexpr int kMaxPageCount = kMaxDatabaseBytes / kPageSize;

  explicit FaviconStore(base::FilePath db_path);
  ~FaviconStore();

  FaviconStore(const FaviconStore&) = delete;
  FaviconStore& operator=(const FaviconStore&) = delete;

  bool Open();
  void Close();
  bool is_open() const { return db_.is_open(); }

  std::optional<FaviconRecord> Get(const std::string& page_url);
  bool Put(const std::string& page_url,
           const std::vector<uint8_t>& png32,
           const std::vector<uint8_t>& png64 = {},
           const std::optional<std::string>& icon_url = std::nullopt,
           bool page_specific = false,
           double lifetime_sec = 7.0 * 86400.0);
  bool MarkMissing(const std::string& page_url);
  int PurgeOlderThan(TimestampSec cutoff);
  int64_t Count();
  int64_t TotalStoredBytes();

 private:
  bool EnforceLimits(int64_t reserved_bytes, int reserved_count);

  base::FilePath db_path_;
  sql::Database db_;
  bool closed_ = false;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_STORE_SQLITE_STORES_H_
