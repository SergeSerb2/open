// Copyright 2026 The Open Authors. All rights reserved.
// Cross-platform browser discovery and data importer:
// Arc (Sidebar, Archive, Boosts, Easels, Notes, History), Open (Legacy macOS,
// read-only migration), Safari (Bookmarks.plist + History.db with TCC check),
// Chrome/Edge/Brave/Vivaldi/Chromium, Firefox/Gecko, Netscape HTML Bookmarks,
// nested folder tree preservation, and ImportReceipt / UndoImport.

#ifndef OPEN_UNIFIED_CORE_IMPORT_BROWSER_IMPORTER_H_
#define OPEN_UNIFIED_CORE_IMPORT_BROWSER_IMPORTER_H_

#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/values.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified {

class ArchiveStore;
class BoostStore;
class BrowserModel;
class DocumentStore;
class HistoryStore;

enum class BrowserFamily {
  kArc,
  kChromium,
  kFirefox,
  kSafari,
  kOpenLegacy,
  kHtmlBookmarks,
};

using ImportSourceBrowser = BrowserFamily;

struct DetectedBrowserProfile {
  DetectedBrowserProfile();
  DetectedBrowserProfile(const DetectedBrowserProfile&);
  DetectedBrowserProfile(DetectedBrowserProfile&&) noexcept;
  DetectedBrowserProfile& operator=(const DetectedBrowserProfile&);
  DetectedBrowserProfile& operator=(DetectedBrowserProfile&&) noexcept;
  ~DetectedBrowserProfile();

  std::string id;        // Directory basename (e.g. "Default", "Profile 1")
  std::string name;      // Display name from Local State or profiles.ini
  base::FilePath directory;
  bool is_default = false;
  int bookmark_count = 0;
  int history_count = 0;
  bool access_denied = false;
  std::string access_error;
};

struct DetectedBrowser {
  DetectedBrowser();
  DetectedBrowser(const DetectedBrowser&);
  DetectedBrowser(DetectedBrowser&&) noexcept;
  DetectedBrowser& operator=(const DetectedBrowser&);
  DetectedBrowser& operator=(DetectedBrowser&&) noexcept;
  ~DetectedBrowser();

  std::string id;        // "chrome", "edge", "brave", "vivaldi", "chromium",
                         // "firefox", "arc", "safari", "open-legacy"
  std::string name;      // Human-readable name
  BrowserFamily family = BrowserFamily::kChromium;
  base::FilePath data_root;
  std::vector<DetectedBrowserProfile> profiles;
};

struct ImportedBookmarkNode {
  ImportedBookmarkNode();
  ImportedBookmarkNode(const ImportedBookmarkNode&);
  ImportedBookmarkNode(ImportedBookmarkNode&&) noexcept;
  ImportedBookmarkNode& operator=(const ImportedBookmarkNode&);
  ImportedBookmarkNode& operator=(ImportedBookmarkNode&&) noexcept;
  ~ImportedBookmarkNode();

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

enum class SafariAccessStatus {
  kGranted,
  kPermissionDenied,
  kNotFound,
};

struct SafariImportErrorInfo {
  bool permission_denied = false;
  std::string error_code;
  std::string error_message;
};

struct ArcImportOptions {
  bool include_archive = true;
  bool include_boosts = true;
  bool include_notes = true;
  bool include_easels = true;
  bool include_history = true;
  size_t max_history_entries = 50000;
};

struct ArcSidebarImportResult {
  ArcSidebarImportResult();
  ArcSidebarImportResult(const ArcSidebarImportResult&);
  ArcSidebarImportResult(ArcSidebarImportResult&&) noexcept;
  ArcSidebarImportResult& operator=(const ArcSidebarImportResult&);
  ArcSidebarImportResult& operator=(ArcSidebarImportResult&&) noexcept;
  ~ArcSidebarImportResult();

  bool ok = false;
  std::string error_message;
  std::vector<Profile> profiles;
  std::vector<Space> spaces;
  std::vector<ArchivedTabRecord> archive_records;
  std::vector<Boost> boosts;
  std::vector<EaselDocument> easels;
  std::vector<NoteDocument> notes;
  std::vector<HistoryEntry> history;
  size_t imported_tabs = 0;
  size_t imported_folders = 0;
  size_t imported_splits = 0;
  size_t imported_archive_items = 0;
  size_t deduped_archive_items = 0;
  size_t imported_boosts = 0;
  size_t imported_easels = 0;
  size_t imported_notes = 0;
  size_t imported_history = 0;
};

struct OpenLegacyImportOptions {
  bool include_workspace = true;
  bool include_preferences = true;
  bool include_shortcuts = true;
  bool include_boosts = true;
  bool include_documents = true;
  bool include_history = true;
  bool include_archive = true;
  bool include_adblock = true;
  size_t max_history_per_profile = 50000;
};

struct OpenLegacyAdBlockConfig {
  OpenLegacyAdBlockConfig();
  OpenLegacyAdBlockConfig(const OpenLegacyAdBlockConfig&);
  OpenLegacyAdBlockConfig(OpenLegacyAdBlockConfig&&) noexcept;
  OpenLegacyAdBlockConfig& operator=(const OpenLegacyAdBlockConfig&);
  OpenLegacyAdBlockConfig& operator=(OpenLegacyAdBlockConfig&&) noexcept;
  ~OpenLegacyAdBlockConfig();

  bool global_enabled = true;
  std::map<ProfileID, std::vector<std::string>> enabled_lists_by_profile;
  std::map<ProfileID, std::vector<std::string>> excluded_domains_by_profile;
  std::map<ProfileID, std::string> custom_rules_by_profile;
};

struct OpenLegacyImportResult {
  OpenLegacyImportResult();
  OpenLegacyImportResult(OpenLegacyImportResult&&) noexcept;
  OpenLegacyImportResult& operator=(OpenLegacyImportResult&&) noexcept;
  ~OpenLegacyImportResult();

  bool ok = false;
  std::string error_message;

  std::vector<Profile> profiles;
  std::vector<Space> spaces;
  std::vector<BrowserWindowState> windows;
  std::vector<RoutingRule> routing_rules;
  RoutingDestination default_destination;

  std::map<std::string, base::Value> preferences;
  std::optional<base::DictValue> keybindings;
  std::map<ProfileID, std::vector<Boost>> boosts_by_profile;
  std::vector<EaselDocument> easels;
  std::vector<NoteDocument> notes;
  std::map<ProfileID, std::vector<HistoryEntry>> history_by_profile;
  std::map<ProfileID, std::vector<ArchivedTabRecord>> archive_by_profile;
  std::optional<OpenLegacyAdBlockConfig> adblock;

  size_t imported_profiles = 0;
  size_t imported_spaces = 0;
  size_t imported_tabs = 0;
  size_t imported_folders = 0;
  size_t imported_splits = 0;
  size_t imported_boosts = 0;
  size_t imported_easels = 0;
  size_t imported_notes = 0;
  size_t imported_history = 0;
  size_t imported_archive = 0;
  size_t imported_preferences = 0;
  size_t imported_shortcuts = 0;
};

// Receipt returned by every model import so the entire import (created
// profiles, spaces, nested sidebar nodes, favorites, boosts, documents,
// archive items, and history range) can be cleanly undone via UndoImport().
struct ImportReceipt {
  ImportReceipt();
  ImportReceipt(const ImportReceipt&);
  ImportReceipt(ImportReceipt&&) noexcept;
  ImportReceipt& operator=(const ImportReceipt&);
  ImportReceipt& operator=(ImportReceipt&&) noexcept;
  ~ImportReceipt();

  std::string import_id;
  std::string source_browser;
  BrowserFamily source_family = BrowserFamily::kChromium;
  TimestampSec imported_at = 0.0;

  std::vector<ProfileID> created_profile_ids;
  std::vector<SpaceID> created_space_ids;
  std::vector<ItemID> created_node_ids;
  std::vector<ItemID> created_favorite_ids;
  std::map<ProfileID, std::vector<std::string>> created_boost_ids;
  std::vector<std::string> created_easel_ids;
  std::vector<std::string> created_note_ids;
  std::map<ProfileID, std::vector<ItemID>> created_archive_ids;
  std::optional<TimestampSec> history_range_start;
  std::optional<TimestampSec> history_range_end;
  std::vector<ProfileID> history_profile_ids;

  bool preferences_modified = false;
  bool keybindings_modified = false;
  bool routing_rules_modified = false;

  bool empty() const {
    return created_profile_ids.empty() && created_space_ids.empty() &&
           created_node_ids.empty() && created_favorite_ids.empty() &&
           created_boost_ids.empty() && created_easel_ids.empty() &&
           created_note_ids.empty() && created_archive_ids.empty() &&
           !history_range_start.has_value();
  }
};

// Optional extra store handles used by Apply* and UndoImport when reverting
// non-model stores alongside BrowserModel.
struct UndoImportTargets {
  UndoImportTargets();
  UndoImportTargets(UndoImportTargets&&) noexcept;
  UndoImportTargets& operator=(UndoImportTargets&&) noexcept;
  ~UndoImportTargets();

  base::RepeatingCallback<BoostStore*(const ProfileID&)> get_boost_store;
  raw_ptr<DocumentStore> document_store = nullptr;
  base::RepeatingCallback<ArchiveStore*(const ProfileID&)> get_archive_store;
  base::RepeatingCallback<HistoryStore*(const ProfileID&)> get_history_store;
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
  // (including Safari and Legacy macOS Open on macOS) without locking live
  // browser databases.
  static std::vector<DetectedBrowser> ProbeInstalledBrowsers();

  // Deterministic RFC 4122 v4-shaped UUID from FNV-1a hashes so repeated
  // imports map to identical IDs without duplicating items.
  static std::string DeterministicUuid(std::string_view namespace_tag,
                                       std::string_view source_id);

  // Converts an ImportedBookmarkNode tree into an "Imported from <Browser>"
  // Folder preserving full nested folder hierarchies.
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

  // --- Safari readers (macOS, pure C++ binary bplist00 + XML plist parser) ---
  static base::FilePath DefaultSafariDirectory();
  static SafariAccessStatus CheckSafariAccess(
      const base::FilePath& safari_dir = DefaultSafariDirectory());

  // Parses either Apple binary plist (`bplist00`) or XML plist (`<plist>`)
  // into a base::Value without Objective-C dependencies.
  static std::optional<base::Value> ParsePlist(std::string_view bytes);

  static bool ReadSafariBookmarks(
      const base::FilePath& safari_dir,
      std::vector<ImportedBookmarkNode>* out_roots,
      ImportBookmarksReport* out_report = nullptr,
      SafariImportErrorInfo* out_error = nullptr);

  static bool ReadSafariHistory(
      const base::FilePath& safari_dir,
      HistoryBatchCallback on_batch,
      ImportHistoryBatchReport* out_report = nullptr,
      SafariImportErrorInfo* out_error = nullptr,
      size_t batch_size = kDefaultHistoryBatchSize);

  // --- Netscape HTML Bookmarks reader ---
  static bool ParseBookmarksHtml(std::string_view html_bytes,
                                 std::vector<ImportedBookmarkNode>* out_roots,
                                 ImportBookmarksReport* out_report = nullptr);
  static bool ReadBookmarksHtmlFile(const base::FilePath& html_path,
                                    std::vector<ImportedBookmarkNode>* out_roots,
                                    ImportBookmarksReport* out_report = nullptr);

  // --- Arc importer (Sidebar, Archive, Boosts, Easels, Notes, History) ---
  static ArcSidebarImportResult ImportArcDirectory(
      const base::FilePath& arc_data_dir,
      bool include_archive = true);
  static ArcSidebarImportResult ImportArcDirectory(
      const base::FilePath& arc_data_dir,
      const ArcImportOptions& options);

  // --- Open (Legacy macOS Open) READ-ONLY migration importer ---
  // Never modifies or deletes any files in |legacy_open_dir|.
  static base::FilePath DefaultOpenLegacyDirectory();
  static OpenLegacyImportResult ImportOpenLegacyDirectory(
      const base::FilePath& legacy_open_dir,
      const OpenLegacyImportOptions& options = {});

  // --- Nested Tree Model Application & Import Undo ---

  // Inserts a nested ImportedBookmarkNode tree into |target_space_id|'s pinned
  // section preserving all nested subfolders (never flattens) and returns an
  // ImportReceipt suitable for UndoImport().
  static ImportReceipt ApplyImportedBookmarksToModel(
      BrowserModel* model,
      const SpaceID& target_space_id,
      std::string_view browser_name,
      BrowserFamily source_family,
      std::string_view source_key,
      const std::vector<ImportedBookmarkNode>& roots,
      size_t max_bookmarks = kMaxBookmarkNodes);

  // Merges an ArcSidebarImportResult into |model| (and optional extra stores)
  // preserving nested folders, splits, favorites, boosts, easels, notes,
  // archive, and history, returning an ImportReceipt.
  static ImportReceipt ApplyArcImportToModel(
      BrowserModel* model,
      const ArcSidebarImportResult& arc_result,
      const UndoImportTargets* extra_targets = nullptr);

  // Merges an OpenLegacyImportResult into |model| (and optional extra stores)
  // returning an ImportReceipt.
  static ImportReceipt ApplyOpenLegacyImportToModel(
      BrowserModel* model,
      const OpenLegacyImportResult& legacy_result,
      const UndoImportTargets* extra_targets = nullptr);

  // Cleanly reverts all items recorded in |receipt| from |model| (and optional
  // |extra_targets| stores) without polluting Archive.
  static bool UndoImport(const ImportReceipt& receipt,
                         BrowserModel* model,
                         const UndoImportTargets* extra_targets = nullptr);
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_IMPORT_BROWSER_IMPORTER_H_
