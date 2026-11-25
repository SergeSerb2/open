// Copyright 2026 The Open Authors. All rights reserved.
// Cross-platform browser discovery and data importer (Chrome, Edge, Brave,
// Vivaldi, Chromium, Firefox, HTML bookmarks, and Arc Storable files).

#ifndef OPEN_UNIFIED_CORE_IMPORT_BROWSER_IMPORTER_H_
#define OPEN_UNIFIED_CORE_IMPORT_BROWSER_IMPORTER_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

enum class BrowserFamily {
  kArc,
  kChromium,
  kFirefox,
};

struct DetectedBrowserProfile {
  std::string id;        // Directory basename (e.g. "Default", "Profile 1")
  std::string name;      // Display name from Local State or profiles.ini
  base::FilePath directory;
  bool is_default = false;
  int bookmark_count = 0;
  int history_count = 0;
};

struct DetectedBrowser {
  std::string id;        // "chrome", "edge", "brave", "vivaldi", "chromium", "firefox", "arc"
  std::string name;      // Human-readable name
  BrowserFamily family = BrowserFamily::kChromium;
  base::FilePath data_root;
  std::vector<DetectedBrowserProfile> profiles;
};

struct ImportedBookmarkNode {
  bool is_folder = false;
  std::string source_id;
  std::string title;
  std::string url;
  std::optional<TimestampSec> date_added;
  std::vector<ImportedBookmarkNode> children;
};

struct ImportHistoryBatchReport {
  size_t source_url_rows = 0;
  size_t source_visit_rows = 0;
  size_t kept_visits = 0;
  size_t deduped_visits = 0;
  size_t skipped_internal = 0;
  size_t skipped_subframe = 0;
  size_t skipped_invalid_time = 0;
};

struct ImportBookmarksReport {
  size_t urls = 0;
  size_t folders = 0;
  size_t skipped = 0;
};

struct ArcSidebarImportResult {
  bool ok = false;
  std::string error_message;
  std::vector<Profile> profiles;
  std::vector<Space> spaces;
  std::vector<ArchivedTabRecord> archive_records;
  size_t imported_tabs = 0;
  size_t imported_folders = 0;
  size_t imported_splits = 0;
  size_t imported_archive_items = 0;
  size_t deduped_archive_items = 0;
};

class BrowserImporter {
 public:
  using HistoryBatchCallback =
      base::RepeatingCallback<void(const std::vector<HistoryEntry>& batch)>;

  static constexpr size_t kDefaultHistoryBatchSize = 5000;
  static constexpr size_t kMaxJsonBytes = 64 * 1024 * 1024;
  static constexpr size_t kMaxBookmarkNodes = 200000;
  static constexpr int kMaxBookmarkDepth = 64;

  // Discovers installed browsers and their profiles on Windows, Linux, or macOS
  // and computes fast approximate bookmark and history counts per profile
  // without locking live browser databases.
  static std::vector<DetectedBrowser> ProbeInstalledBrowsers();

  // Deterministic RFC 4122 v4-shaped UUID from FNV-1a hashes so repeated
  // imports map to identical IDs without duplicating items.
  static std::string DeterministicUuid(std::string_view namespace_tag,
                                       std::string_view source_id);

  // Converts an ImportedBookmarkNode tree into an "Imported from <Browser>"
  // Folder ready to append to a Space's pinned nodes.
  static Folder BuildImportedBookmarksFolder(
      std::string_view browser_name,
      std::string_view source_key,
      const std::vector<ImportedBookmarkNode>& roots);

  // --- Chromium-family readers (Chrome, Edge, Brave, Vivaldi, Chromium) ---
  static bool ReadChromiumBookmarks(const base::FilePath& profile_dir,
                                    std::vector<ImportedBookmarkNode>* out_roots,
                                    ImportBookmarksReport* out_report = nullptr);

  // Safely copies Chromium `History` (+ `-wal` or `-journal`, never `-shm`)
  // into a private temporary directory, verifies with PRAGMA quick_check, and
  // streams deduplicated HistoryEntry batches via |on_batch|.
  static bool ReadChromiumHistory(const base::FilePath& profile_dir,
                                  HistoryBatchCallback on_batch,
                                  ImportHistoryBatchReport* out_report = nullptr,
                                  size_t batch_size = kDefaultHistoryBatchSize);

  // --- Firefox / Gecko readers ---
  static std::vector<DetectedBrowserProfile> ProbeFirefoxProfiles(
      const base::FilePath& firefox_root);

  static bool ReadFirefoxBookmarks(const base::FilePath& profile_dir,
                                   std::vector<ImportedBookmarkNode>* out_roots,
                                   ImportBookmarksReport* out_report = nullptr);

  static bool ReadFirefoxHistory(const base::FilePath& profile_dir,
                                 HistoryBatchCallback on_batch,
                                 ImportHistoryBatchReport* out_report = nullptr,
                                 size_t batch_size = kDefaultHistoryBatchSize);

  // --- Netscape HTML Bookmarks reader ---
  static bool ParseBookmarksHtml(std::string_view html_bytes,
                                 std::vector<ImportedBookmarkNode>* out_roots,
                                 ImportBookmarksReport* out_report = nullptr);
  static bool ReadBookmarksHtmlFile(const base::FilePath& html_path,
                                    std::vector<ImportedBookmarkNode>* out_roots,
                                    ImportBookmarksReport* out_report = nullptr);

  // --- Arc StorableSidebar.json & StorableArchiveItems.json reader ---
  static ArcSidebarImportResult ImportArcDirectory(
      const base::FilePath& arc_data_dir,
      bool include_archive = true);
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_IMPORT_BROWSER_IMPORTER_H_
