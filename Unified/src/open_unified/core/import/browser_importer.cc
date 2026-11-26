// Copyright 2026 The Open Authors. All rights reserved.
// Cross-platform browser importer implementation (Arc, Open Legacy macOS,
// Safari with pure-C++ bplist/XML plist parser, Chrome/Chromium/Edge/Brave/
// Vivaldi, Firefox, Netscape HTML Bookmarks, nested folder trees, and Undo).

#include "open_unified/core/import/browser_importer.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <utility>

#include "base/base64.h"
#include "base/containers/span.h"
#include "base/environment.h"
#include "base/files/file.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/raw_span.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/string_view_util.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/values.h"
#include "build/build_config.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/core/documents/document_store.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/uuid_util.h"
#include "open_unified/core/store/snapshot_store.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "sql/database.h"
#include "sql/statement.h"
#include "url/gurl.h"

#if BUILDFLAG(IS_POSIX)
#include <fcntl.h>
#include <unistd.h>
#endif

namespace open_unified {

// --- Struct boilerplate ---

DetectedBrowserProfile::DetectedBrowserProfile() = default;
DetectedBrowserProfile::DetectedBrowserProfile(const DetectedBrowserProfile&) =
    default;
DetectedBrowserProfile::DetectedBrowserProfile(
    DetectedBrowserProfile&&) noexcept = default;
DetectedBrowserProfile& DetectedBrowserProfile::operator=(
    const DetectedBrowserProfile&) = default;
DetectedBrowserProfile& DetectedBrowserProfile::operator=(
    DetectedBrowserProfile&&) noexcept = default;
DetectedBrowserProfile::~DetectedBrowserProfile() = default;

DetectedBrowser::DetectedBrowser() = default;
DetectedBrowser::DetectedBrowser(const DetectedBrowser&) = default;
DetectedBrowser::DetectedBrowser(DetectedBrowser&&) noexcept = default;
DetectedBrowser& DetectedBrowser::operator=(const DetectedBrowser&) = default;
DetectedBrowser& DetectedBrowser::operator=(DetectedBrowser&&) noexcept =
    default;
DetectedBrowser::~DetectedBrowser() = default;

ImportedBookmarkNode::ImportedBookmarkNode() = default;
ImportedBookmarkNode::ImportedBookmarkNode(const ImportedBookmarkNode&) =
    default;
ImportedBookmarkNode::ImportedBookmarkNode(ImportedBookmarkNode&&) noexcept =
    default;
ImportedBookmarkNode& ImportedBookmarkNode::operator=(
    const ImportedBookmarkNode&) = default;
ImportedBookmarkNode& ImportedBookmarkNode::operator=(
    ImportedBookmarkNode&&) noexcept = default;
ImportedBookmarkNode::~ImportedBookmarkNode() = default;

ArcSidebarImportResult::ArcSidebarImportResult() = default;
ArcSidebarImportResult::ArcSidebarImportResult(const ArcSidebarImportResult&) =
    default;
ArcSidebarImportResult::ArcSidebarImportResult(
    ArcSidebarImportResult&&) noexcept = default;
ArcSidebarImportResult& ArcSidebarImportResult::operator=(
    const ArcSidebarImportResult&) = default;
ArcSidebarImportResult& ArcSidebarImportResult::operator=(
    ArcSidebarImportResult&&) noexcept = default;
ArcSidebarImportResult::~ArcSidebarImportResult() = default;

OpenLegacyAdBlockConfig::OpenLegacyAdBlockConfig() = default;
OpenLegacyAdBlockConfig::OpenLegacyAdBlockConfig(
    const OpenLegacyAdBlockConfig&) = default;
OpenLegacyAdBlockConfig::OpenLegacyAdBlockConfig(
    OpenLegacyAdBlockConfig&&) noexcept = default;
OpenLegacyAdBlockConfig& OpenLegacyAdBlockConfig::operator=(
    const OpenLegacyAdBlockConfig&) = default;
OpenLegacyAdBlockConfig& OpenLegacyAdBlockConfig::operator=(
    OpenLegacyAdBlockConfig&&) noexcept = default;
OpenLegacyAdBlockConfig::~OpenLegacyAdBlockConfig() = default;

OpenLegacyImportResult::OpenLegacyImportResult() = default;
OpenLegacyImportResult::OpenLegacyImportResult(
    OpenLegacyImportResult&&) noexcept = default;
OpenLegacyImportResult& OpenLegacyImportResult::operator=(
    OpenLegacyImportResult&&) noexcept = default;
OpenLegacyImportResult::~OpenLegacyImportResult() = default;

ImportReceipt::ImportReceipt() = default;
ImportReceipt::ImportReceipt(const ImportReceipt&) = default;
ImportReceipt::ImportReceipt(ImportReceipt&&) noexcept = default;
ImportReceipt& ImportReceipt::operator=(const ImportReceipt&) = default;
ImportReceipt& ImportReceipt::operator=(ImportReceipt&&) noexcept = default;
ImportReceipt::~ImportReceipt() = default;

UndoImportTargets::UndoImportTargets() = default;
UndoImportTargets::UndoImportTargets(UndoImportTargets&&) noexcept = default;
UndoImportTargets& UndoImportTargets::operator=(UndoImportTargets&&) noexcept =
    default;
UndoImportTargets::~UndoImportTargets() = default;

namespace {

// Microseconds between 1601-01-01 (WebKit/Windows epoch) and 1970-01-01.
constexpr int64_t kWebkitEpochOffsetMicros = 11644473600000000LL;
// Seconds between 1970-01-01 and 2001-01-01 (Apple Core Data epoch).
constexpr double kApple2001EpochOffsetSec = 978307200.0;

constexpr size_t kMaxProbeJsonBytes = 16 * 1024 * 1024;
constexpr int64_t kMaxProbeSqliteBytes = 8 * 1024 * 1024;
constexpr int kMaxReportedProbeCount = 500000;
constexpr size_t kMaxPlistBytes = 64 * 1024 * 1024;
constexpr size_t kMaxPlistObjects = 200000;
constexpr int kMaxPlistDepth = 64;

bool IsSupportedImportScheme(std::string_view url_str) {
  GURL url(url_str);
  if (!url.is_valid()) return false;
  return url.SchemeIsHTTPOrHTTPS() || url.SchemeIsFile();
}

std::optional<TimestampSec> ValidateImportUnixSeconds(double seconds) {
  double max_future =
      base::Time::Now().InSecondsFSinceUnixEpoch() + 24.0 * 3600.0;
  if (!std::isfinite(seconds) || seconds <= 0.0 || seconds > max_future) {
    return std::nullopt;
  }
  return seconds;
}

std::optional<TimestampSec> ChromiumTimeMicrosToUnix(int64_t micros) {
  if (micros <= kWebkitEpochOffsetMicros) return std::nullopt;
  return ValidateImportUnixSeconds(
      static_cast<double>(micros - kWebkitEpochOffsetMicros) / 1000000.0);
}

uint64_t Fnv1a64(std::string_view text, uint64_t offset) {
  uint64_t hash = offset;
  for (unsigned char b : text) {
    hash ^= static_cast<uint64_t>(b);
    hash *= 1099511628211ULL;
  }
  return hash;
}

bool IsSafeDirBasename(std::string_view name) {
  if (name.empty() || name.size() > 255 || name == "." || name == "..") {
    return false;
  }
  for (unsigned char c : name) {
    if (c < 0x20 || c == '/' || c == '\\') return false;
  }
  return true;
}

void AppendUtf8CodePoint(uint32_t cp, std::string* out) {
  if (cp == 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
    return;
  }
  if (cp < 0x80) {
    out->push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out->push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out->push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out->push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

// Safely copies a SQLite database (+ matching -wal or -journal, never -shm)
// into a private temporary directory so a live running browser is never locked
// or mutated.
class SafeSqliteTempCopy {
 public:
  SafeSqliteTempCopy()
      : db_(sql::DatabaseOptions{}, sql::Database::Tag("History")) {}
  ~SafeSqliteTempCopy() = default;

  bool Open(const base::FilePath& source_db, bool run_quick_check = true) {
    if (!base::PathExists(source_db) || base::IsLink(source_db)) {
      return false;
    }
    if (!temp_dir_.CreateUniqueTempDir()) {
      return false;
    }
    base::FilePath dest_db = temp_dir_.GetPath().Append(source_db.BaseName());
    if (!base::CopyFile(source_db, dest_db)) {
      return false;
    }

    // Inspect SQLite header bytes 18 & 19 to determine WAL vs rollback journal.
    bool wal_mode = false;
    {
      base::File f(dest_db, base::File::FLAG_OPEN | base::File::FLAG_READ);
      if (!f.IsValid()) return false;
      std::array<uint8_t, 20> hdr{};
      if (f.ReadAtCurrentPos(hdr) != 20) return false;
      wal_mode = (hdr[18] == 2 && hdr[19] == 2);
    }

    base::FilePath sidecar_src(
        source_db.value() +
        (wal_mode ? FILE_PATH_LITERAL("-wal") : FILE_PATH_LITERAL("-journal")));
    if (base::PathExists(sidecar_src) && !base::IsLink(sidecar_src)) {
      base::FilePath sidecar_dst(
          dest_db.value() + (wal_mode ? FILE_PATH_LITERAL("-wal")
                                      : FILE_PATH_LITERAL("-journal")));
      base::CopyFile(sidecar_src, sidecar_dst);
    }

    if (!db_.Open(dest_db)) {
      return false;
    }
    if (run_quick_check) {
      sql::Statement check(db_.GetUniqueStatement("PRAGMA quick_check"));
      if (!check.Step() || check.ColumnString(0) != "ok") {
        db_.Close();
        return false;
      }
    }
    if (!db_.Execute("PRAGMA temp_store = MEMORY; PRAGMA query_only = ON;")) {
      db_.Close();
      return false;
    }
    return true;
  }

  sql::Database& db() { return db_; }

 private:
  base::ScopedTempDir temp_dir_;
  sql::Database db_;
};

int CountJsonStringKeyValue(std::string_view text,
                            std::string_view quoted_key,
                            std::string_view quoted_value) {
  int count = 0;
  size_t pos = 0;
  while ((pos = text.find(quoted_key, pos)) != std::string_view::npos) {
    pos += quoted_key.size();
    while (pos < text.size() && base::IsAsciiWhitespace(text[pos])) {
      ++pos;
    }
    if (pos >= text.size() || text[pos] != ':') {
      continue;
    }
    ++pos;
    while (pos < text.size() && base::IsAsciiWhitespace(text[pos])) {
      ++pos;
    }
    if (text.substr(pos).starts_with(quoted_value)) {
      ++count;
      pos += quoted_value.size();
    }
  }
  return count;
}

int CountJsonKey(std::string_view text, std::string_view quoted_key) {
  int count = 0;
  size_t pos = 0;
  while ((pos = text.find(quoted_key, pos)) != std::string_view::npos) {
    pos += quoted_key.size();
    while (pos < text.size() && base::IsAsciiWhitespace(text[pos])) {
      ++pos;
    }
    if (pos < text.size() && text[pos] == ':') {
      ++count;
      ++pos;
    }
  }
  return count;
}

bool IsSmallEnoughForSqliteProbe(const base::FilePath& db_path,
                                 int64_t db_size) {
  if (db_size <= 0 || db_size > kMaxProbeSqliteBytes) {
    return false;
  }
  base::FilePath wal_path(db_path.value() + FILE_PATH_LITERAL("-wal"));
  if (auto wal_size = base::GetFileSize(wal_path);
      wal_size.has_value() && *wal_size > kMaxProbeSqliteBytes) {
    return false;
  }
  return true;
}

int EstimateChromiumBookmarkCount(const base::FilePath& profile_dir) {
  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(profile_dir.AppendASCII("Bookmarks"),
                                         &raw, kMaxProbeJsonBytes)) {
    return 0;
  }
  return CountJsonStringKeyValue(raw, "\"type\"", "\"url\"");
}

int EstimateChromiumHistoryCount(const base::FilePath& profile_dir) {
  base::FilePath history_path = profile_dir.AppendASCII("History");
  auto file_size = base::GetFileSize(history_path);
  if (!file_size.has_value() || *file_size <= 0) {
    return 0;
  }
  if (IsSmallEnoughForSqliteProbe(history_path, *file_size)) {
    SafeSqliteTempCopy copy;
    if (copy.Open(history_path, /*run_quick_check=*/false)) {
      sql::Statement st(
          copy.db().GetUniqueStatement("SELECT COUNT(*) FROM urls"));
      if (st.Step()) {
        int64_t rows = st.ColumnInt64(0);
        return static_cast<int>(
            std::clamp<int64_t>(rows, 0, kMaxReportedProbeCount));
      }
    }
  }
  return static_cast<int>(
      std::clamp<int64_t>(*file_size / 512, 1, kMaxReportedProbeCount));
}

void EstimateFirefoxCounts(const base::FilePath& profile_dir,
                           int* bookmark_count,
                           int* history_count) {
  *bookmark_count = 0;
  *history_count = 0;
  base::FilePath places_path = profile_dir.AppendASCII("places.sqlite");
  auto file_size = base::GetFileSize(places_path);
  if (!file_size.has_value() || *file_size <= 0) {
    return;
  }
  if (IsSmallEnoughForSqliteProbe(places_path, *file_size)) {
    SafeSqliteTempCopy copy;
    if (copy.Open(places_path, /*run_quick_check=*/false)) {
      {
        sql::Statement st(copy.db().GetUniqueStatement(
            "SELECT COUNT(*) FROM moz_bookmarks WHERE type = 1"));
        if (st.Step()) {
          *bookmark_count = static_cast<int>(std::clamp<int64_t>(
              st.ColumnInt64(0), 0, kMaxReportedProbeCount));
        }
      }
      {
        sql::Statement st(copy.db().GetUniqueStatement(
            "SELECT COUNT(*) FROM moz_places WHERE visit_count > 0"));
        if (st.Step()) {
          *history_count = static_cast<int>(std::clamp<int64_t>(
              st.ColumnInt64(0), 0, kMaxReportedProbeCount));
        }
      }
      return;
    }
  }
  *history_count = static_cast<int>(
      std::clamp<int64_t>(*file_size / 1024, 1, kMaxReportedProbeCount));
  if (*file_size > 1024 * 1024) {
    *bookmark_count = static_cast<int>(
        std::clamp<int64_t>(*file_size / (64 * 1024), 1, 50000));
  }
}

int EstimateArcSidebarTabCount(const base::FilePath& arc_root) {
  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(
          arc_root.AppendASCII("StorableSidebar.json"), &raw,
          kMaxProbeJsonBytes)) {
    return 0;
  }
  return CountJsonKey(raw, "\"savedURL\"");
}

int EstimateOpenLegacyTabCount(const base::FilePath& legacy_root) {
  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(
          legacy_root.AppendASCII("State").AppendASCII("browser.json"), &raw,
          kMaxProbeJsonBytes)) {
    return 0;
  }
  return CountJsonKey(raw, "\"url\"");
}

int EstimateOpenLegacyHistoryCount(const base::FilePath& legacy_root) {
  base::FilePath hist = legacy_root.AppendASCII("Profiles")
                            .AppendASCII("Default")
                            .AppendASCII("State")
                            .AppendASCII("history.sqlite3");
  if (!base::PathExists(hist)) {
    hist = legacy_root.AppendASCII("State").AppendASCII("history.sqlite3");
  }
  auto fsize = base::GetFileSize(hist);
  if (!fsize || *fsize <= 0) return 0;
  if (IsSmallEnoughForSqliteProbe(hist, *fsize)) {
    SafeSqliteTempCopy copy;
    if (copy.Open(hist, /*run_quick_check=*/false)) {
      sql::Statement st(
          copy.db().GetUniqueStatement("SELECT COUNT(*) FROM urls"));
      if (st.Step()) {
        return static_cast<int>(
            std::clamp<int64_t>(st.ColumnInt64(0), 0, kMaxReportedProbeCount));
      }
    }
  }
  return static_cast<int>(
      std::clamp<int64_t>(*fsize / 512, 1, kMaxReportedProbeCount));
}

int EstimateSafariHistoryCount(const base::FilePath& safari_dir) {
  base::FilePath hist = safari_dir.AppendASCII("History.db");
  auto fsize = base::GetFileSize(hist);
  if (!fsize || *fsize <= 0) return 0;
  if (IsSmallEnoughForSqliteProbe(hist, *fsize)) {
    SafeSqliteTempCopy copy;
    if (copy.Open(hist, /*run_quick_check=*/false)) {
      sql::Statement st(
          copy.db().GetUniqueStatement("SELECT COUNT(*) FROM history_items"));
      if (st.Step()) {
        return static_cast<int>(
            std::clamp<int64_t>(st.ColumnInt64(0), 0, kMaxReportedProbeCount));
      }
    }
  }
  return static_cast<int>(
      std::clamp<int64_t>(*fsize / 512, 1, kMaxReportedProbeCount));
}

std::vector<DetectedBrowserProfile> ProbeChromiumProfiles(
    const base::FilePath& user_data_dir) {
  auto is_usable = [](const base::FilePath& dir) {
    return base::PathExists(dir.AppendASCII("Bookmarks")) ||
           base::PathExists(dir.AppendASCII("History")) ||
           base::PathExists(dir.AppendASCII("Preferences"));
  };

  std::map<std::string, std::string> names_by_dir;
  std::vector<std::string> ordered_dirs;

  std::string local_state_raw;
  if (base::ReadFileToStringWithMaxSize(
          user_data_dir.AppendASCII("Local State"), &local_state_raw,
          4 * 1024 * 1024)) {
    if (auto dict =
            base::JSONReader::ReadDict(local_state_raw, base::JSON_PARSE_RFC)) {
      if (const auto* prof = dict->FindDict("profile")) {
        if (const auto* info_cache = prof->FindDict("info_cache")) {
          for (const auto [dir_name, val] : *info_cache) {
            const auto* entry = val.GetIfDict();
            const auto* display = entry ? entry->FindString("name") : nullptr;
            names_by_dir[dir_name] =
                (display && !display->empty()) ? *display : dir_name;
          }
        }
        if (const auto* order = prof->FindList("profiles_order")) {
          for (const auto& v : *order) {
            if (v.is_string() && names_by_dir.contains(v.GetString())) {
              ordered_dirs.push_back(v.GetString());
            }
          }
        }
      }
    }
  }

  std::set<std::string> seen(ordered_dirs.begin(), ordered_dirs.end());
  for (const auto& [dir_name, _] : names_by_dir) {
    if (seen.insert(dir_name).second) ordered_dirs.push_back(dir_name);
  }

  base::FileEnumerator enumerator(user_data_dir, false,
                                  base::FileEnumerator::DIRECTORIES);
  std::vector<std::string> scanned;
  for (base::FilePath d = enumerator.Next(); !d.empty(); d = enumerator.Next()) {
    std::string base_name = d.BaseName().AsUTF8Unsafe();
    if ((base_name == "Default" || base::StartsWith(base_name, "Profile ")) &&
        !seen.contains(base_name)) {
      scanned.push_back(base_name);
    }
  }
  std::sort(scanned.begin(), scanned.end());
  for (const auto& s : scanned) {
    if (seen.insert(s).second) ordered_dirs.push_back(s);
  }

  std::vector<DetectedBrowserProfile> out;
  for (const auto& dir_name : ordered_dirs) {
    if (out.size() >= 100 || !IsSafeDirBasename(dir_name)) continue;
    base::FilePath full = user_data_dir.AppendASCII(dir_name);
    if (!base::DirectoryExists(full) || !is_usable(full)) continue;
    DetectedBrowserProfile p;
    p.id = dir_name;
    auto it = names_by_dir.find(dir_name);
    p.name = (it != names_by_dir.end() && !it->second.empty()) ? it->second
                                                               : dir_name;
    p.directory = full;
    p.is_default = (dir_name == "Default");
    p.bookmark_count = EstimateChromiumBookmarkCount(full);
    p.history_count = EstimateChromiumHistoryCount(full);
    out.push_back(std::move(p));
  }
  return out;
}

std::vector<std::pair<std::string, std::map<std::string, std::string>>>
ParseIniSections(std::string_view text) {
  std::vector<std::pair<std::string, std::map<std::string, std::string>>> out;
  size_t pos = 0;
  while (pos < text.size()) {
    size_t eol = text.find('\n', pos);
    if (eol == std::string_view::npos) eol = text.size();
    std::string_view line =
        base::TrimWhitespaceASCII(text.substr(pos, eol - pos), base::TRIM_ALL);
    pos = eol + 1;
    if (line.empty() || line[0] == ';' || line[0] == '#') continue;
    if (line.front() == '[' && line.back() == ']') {
      out.emplace_back(std::string(line.substr(1, line.size() - 2)),
                       std::map<std::string, std::string>{});
      continue;
    }
    size_t eq = line.find('=');
    if (eq != std::string_view::npos && !out.empty()) {
      out.back().second[std::string(line.substr(0, eq))] =
          std::string(line.substr(eq + 1));
    }
  }
  return out;
}

std::string DecodeHtmlEntities(std::string_view raw, bool trim = true) {
  std::string out;
  out.reserve(raw.size());
  for (size_t i = 0; i < raw.size(); ++i) {
    if (raw[i] != '&') {
      out.push_back(raw[i]);
      continue;
    }
    size_t semi = raw.find(';', i + 1);
    if (semi == std::string_view::npos || semi - i > 12) {
      out.push_back('&');
      continue;
    }
    std::string_view entity = raw.substr(i + 1, semi - i - 1);
    if (entity == "amp") out.push_back('&');
    else if (entity == "lt") out.push_back('<');
    else if (entity == "gt") out.push_back('>');
    else if (entity == "quot") out.push_back('"');
    else if (entity == "apos" || entity == "#39") out.push_back('\'');
    else if (entity == "nbsp") out.push_back(' ');
    else if (!entity.empty() && entity[0] == '#') {
      uint32_t code = 0;
      bool parsed = false;
      if (entity.size() > 2 && (entity[1] == 'x' || entity[1] == 'X')) {
        parsed = base::HexStringToUInt(entity.substr(2), &code);
      } else {
        parsed = base::StringToUint(entity.substr(1), &code);
      }
      if (parsed && code > 0 && code <= 0x10FFFF) {
        AppendUtf8CodePoint(code, &out);
      } else {
        out.append(raw.substr(i, semi - i + 1));
      }
    } else {
      out.append(raw.substr(i, semi - i + 1));
    }
    i = semi;
  }
  return trim ? std::string(base::TrimWhitespaceASCII(out, base::TRIM_ALL))
              : out;
}

std::optional<std::string> ExtractHtmlAttribute(std::string_view tag,
                                                std::string_view attr_name) {
  std::string lower_tag = base::ToLowerASCII(tag);
  std::string needle = base::ToLowerASCII(attr_name) + "=";
  size_t pos = lower_tag.find(needle);
  if (pos == std::string::npos) return std::nullopt;
  size_t val_start = pos + needle.size();
  if (val_start >= tag.size()) return std::nullopt;
  if (tag[val_start] == '"' || tag[val_start] == '\'') {
    char q = tag[val_start++];
    size_t end = tag.find(q, val_start);
    if (end == std::string_view::npos) end = tag.size();
    return DecodeHtmlEntities(tag.substr(val_start, end - val_start));
  }
  size_t end = val_start;
  while (end < tag.size() && !base::IsAsciiWhitespace(tag[end])) ++end;
  return DecodeHtmlEntities(tag.substr(val_start, end - val_start));
}

size_t FindCaseInsensitive(std::string_view haystack,
                           std::string_view needle,
                           size_t start = 0) {
  if (needle.empty() || start >= haystack.size()) return std::string_view::npos;
  std::string h_low = base::ToLowerASCII(haystack.substr(start));
  std::string n_low = base::ToLowerASCII(needle);
  size_t rel = h_low.find(n_low);
  return rel == std::string::npos ? std::string_view::npos : start + rel;
}

// ============================================================================
// Pure C++ Binary Plist (bplist00) + XML Plist Parser (zero ObjC dependency)
// ============================================================================

class BinaryPlistParser {
 public:
  explicit BinaryPlistParser(std::string_view raw)
      : bytes_(base::as_byte_span(raw)) {}

  std::optional<base::Value> Parse() {
    if (bytes_.size() < 40 || bytes_.size() > kMaxPlistBytes) {
      return std::nullopt;
    }
    if (base::as_string_view(bytes_.first<8>()) != "bplist00") {
      return std::nullopt;
    }

    const size_t trailer = bytes_.size() - 32;
    offset_int_size_ = bytes_[trailer + 6];
    object_ref_size_ = bytes_[trailer + 7];
    num_objects_ = ReadBE64(trailer + 8);
    top_object_ = ReadBE64(trailer + 16);
    offset_table_offset_ = ReadBE64(trailer + 24);

    if ((offset_int_size_ != 1 && offset_int_size_ != 2 &&
         offset_int_size_ != 4 && offset_int_size_ != 8) ||
        (object_ref_size_ != 1 && object_ref_size_ != 2 &&
         object_ref_size_ != 4 && object_ref_size_ != 8)) {
      return std::nullopt;
    }
    if (num_objects_ == 0 || num_objects_ > kMaxPlistObjects ||
        top_object_ >= num_objects_) {
      return std::nullopt;
    }
    if (offset_table_offset_ < 8 || offset_table_offset_ >= trailer) {
      return std::nullopt;
    }
    const uint64_t table_bytes = num_objects_ * offset_int_size_;
    if (table_bytes > trailer - offset_table_offset_) {
      return std::nullopt;
    }
    return ReadObject(top_object_, 0);
  }

 private:
  uint64_t ReadBE64(size_t pos) const {
    uint64_t v = 0;
    for (size_t i = 0; i < 8; ++i) {
      v = (v << 8) | bytes_[pos + i];
    }
    return v;
  }

  std::optional<uint64_t> ReadBEUint(size_t pos, size_t width) const {
    if (width == 0 || width > 8 || pos > bytes_.size() ||
        width > bytes_.size() - pos) {
      return std::nullopt;
    }
    uint64_t v = 0;
    for (size_t i = 0; i < width; ++i) {
      v = (v << 8) | bytes_[pos + i];
    }
    return v;
  }

  std::optional<uint64_t> ReadLength(uint8_t low_nibble,
                                     size_t* cursor) const {
    if (low_nibble != 0x0F) {
      return static_cast<uint64_t>(low_nibble);
    }
    if (*cursor >= bytes_.size()) return std::nullopt;
    uint8_t marker = bytes_[(*cursor)++];
    if ((marker & 0xF0) != 0x10) return std::nullopt;
    uint8_t exp = marker & 0x0F;
    if (exp > 3) return std::nullopt;  // length <= 8 bytes
    size_t width = static_cast<size_t>(1u) << exp;
    auto len = ReadBEUint(*cursor, width);
    if (!len) return std::nullopt;
    *cursor += width;
    return len;
  }

  std::optional<base::Value> ReadObject(uint64_t obj_idx, int depth) {
    if (depth > kMaxPlistDepth || obj_idx >= num_objects_ ||
        ++visited_count_ > kMaxPlistObjects) {
      return std::nullopt;
    }
    if (!visiting_.insert(obj_idx).second) {
      return std::nullopt;
    }
    struct Guard {
      raw_ptr<std::set<uint64_t>> set;
      uint64_t idx;
      ~Guard() { set->erase(idx); }
    } guard{&visiting_, obj_idx};

    const size_t off_pos = static_cast<size_t>(
        offset_table_offset_ + obj_idx * offset_int_size_);
    auto obj_offset_opt = ReadBEUint(off_pos, offset_int_size_);
    if (!obj_offset_opt || *obj_offset_opt < 8 ||
        *obj_offset_opt >= offset_table_offset_) {
      return std::nullopt;
    }
    size_t pos = static_cast<size_t>(*obj_offset_opt);
    uint8_t marker = bytes_[pos++];
    uint8_t hi = marker & 0xF0;
    uint8_t lo = marker & 0x0F;

    switch (hi) {
      case 0x00:
        if (lo == 0x00) return base::Value();
        if (lo == 0x08) return base::Value(false);
        if (lo == 0x09) return base::Value(true);
        return base::Value();

      case 0x10: {
        if (lo > 4) return std::nullopt;
        size_t width = static_cast<size_t>(1u) << lo;
        if (width == 16) {
          if (pos > bytes_.size() || 16 > bytes_.size() - pos) {
            return std::nullopt;
          }
          auto low64 = ReadBEUint(pos + 8, 8);
          if (!low64) return std::nullopt;
          int64_t signed_val = static_cast<int64_t>(*low64);
          return base::Value(static_cast<double>(signed_val));
        }
        auto raw = ReadBEUint(pos, width);
        if (!raw) return std::nullopt;
        if (width == 8) {
          int64_t s = static_cast<int64_t>(*raw);
          if (s >= std::numeric_limits<int>::min() &&
              s <= std::numeric_limits<int>::max()) {
            return base::Value(static_cast<int>(s));
          }
          return base::Value(static_cast<double>(s));
        }
        return base::Value(static_cast<int>(*raw));
      }

      case 0x20: {
        if (lo == 2) {
          auto raw = ReadBEUint(pos, 4);
          if (!raw) return std::nullopt;
          const float f = std::bit_cast<float>(static_cast<uint32_t>(*raw));
          return std::isfinite(f) ? base::Value(static_cast<double>(f))
                                  : base::Value(0.0);
        }
        if (lo == 3) {
          auto raw = ReadBEUint(pos, 8);
          if (!raw) return std::nullopt;
          const double d = std::bit_cast<double>(*raw);
          return std::isfinite(d) ? base::Value(d) : base::Value(0.0);
        }
        return std::nullopt;
      }

      case 0x30: {
        if (lo != 3) return std::nullopt;
        auto raw = ReadBEUint(pos, 8);
        if (!raw) return std::nullopt;
        const double d = std::bit_cast<double>(*raw);
        return std::isfinite(d) ? base::Value(d) : base::Value(0.0);
      }

      case 0x40: {
        auto len = ReadLength(lo, &pos);
        if (!len || *len > bytes_.size() - pos) return std::nullopt;
        auto sub = bytes_.subspan(pos, static_cast<size_t>(*len));
        return base::Value(std::vector<uint8_t>(sub.begin(), sub.end()));
      }

      case 0x50: {
        auto len = ReadLength(lo, &pos);
        if (!len || *len > bytes_.size() - pos) return std::nullopt;
        return base::Value(std::string(base::as_string_view(
            bytes_.subspan(pos, static_cast<size_t>(*len)))));
      }

      case 0x60: {
        auto count = ReadLength(lo, &pos);
        if (!count || *count > (bytes_.size() - pos) / 2) return std::nullopt;
        std::string utf8;
        utf8.reserve(static_cast<size_t>(*count) * 2);
        for (uint64_t i = 0; i < *count; ++i) {
          uint16_t u1 = static_cast<uint16_t>(
              (bytes_[pos + i * 2] << 8) | bytes_[pos + i * 2 + 1]);
          if (u1 >= 0xD800 && u1 <= 0xDBFF && i + 1 < *count) {
            uint16_t u2 = static_cast<uint16_t>(
                (bytes_[pos + (i + 1) * 2] << 8) |
                bytes_[pos + (i + 1) * 2 + 1]);
            if (u2 >= 0xDC00 && u2 <= 0xDFFF) {
              uint32_t cp = 0x10000u + (((u1 - 0xD800u) << 10) | (u2 - 0xDC00u));
              AppendUtf8CodePoint(cp, &utf8);
              ++i;
              continue;
            }
          }
          AppendUtf8CodePoint(u1, &utf8);
        }
        return base::Value(std::move(utf8));
      }

      case 0xA0: {
        auto count = ReadLength(lo, &pos);
        if (!count || *count > kMaxPlistObjects ||
            *count > (bytes_.size() - pos) / object_ref_size_) {
          return std::nullopt;
        }
        base::ListValue list;
        for (uint64_t i = 0; i < *count; ++i) {
          auto ref = ReadBEUint(pos + i * object_ref_size_, object_ref_size_);
          if (!ref) return std::nullopt;
          auto item = ReadObject(*ref, depth + 1);
          if (!item) return std::nullopt;
          list.Append(std::move(*item));
        }
        return base::Value(std::move(list));
      }

      case 0xD0: {
        auto count = ReadLength(lo, &pos);
        if (!count || *count > kMaxPlistObjects ||
            *count > (bytes_.size() - pos) / (2 * object_ref_size_)) {
          return std::nullopt;
        }
        const size_t val_base = pos + static_cast<size_t>(*count) * object_ref_size_;
        base::DictValue dict;
        for (uint64_t i = 0; i < *count; ++i) {
          auto kref = ReadBEUint(pos + i * object_ref_size_, object_ref_size_);
          auto vref =
              ReadBEUint(val_base + i * object_ref_size_, object_ref_size_);
          if (!kref || !vref) return std::nullopt;
          auto key = ReadObject(*kref, depth + 1);
          auto val = ReadObject(*vref, depth + 1);
          if (!key || !key->is_string() || !val) continue;
          dict.Set(key->GetString(), std::move(*val));
        }
        return base::Value(std::move(dict));
      }

      default:
        return base::Value();
    }
  }

  base::raw_span<const uint8_t> bytes_;
  uint8_t offset_int_size_ = 0;
  uint8_t object_ref_size_ = 0;
  uint64_t num_objects_ = 0;
  uint64_t top_object_ = 0;
  uint64_t offset_table_offset_ = 0;
  size_t visited_count_ = 0;
  std::set<uint64_t> visiting_;
};

class XmlPlistParser {
 public:
  explicit XmlPlistParser(std::string_view xml) : xml_(xml) {}

  std::optional<base::Value> Parse() {
    if (xml_.size() > kMaxPlistBytes) return std::nullopt;
    size_t plist_pos = FindCaseInsensitive(xml_, "<plist");
    if (plist_pos == std::string_view::npos) return std::nullopt;
    size_t gt = xml_.find('>', plist_pos);
    if (gt == std::string_view::npos) return std::nullopt;
    pos_ = gt + 1;
    return ParseValue(0);
  }

 private:
  void SkipWhitespaceAndComments() {
    while (pos_ < xml_.size()) {
      while (pos_ < xml_.size() && base::IsAsciiWhitespace(xml_[pos_])) {
        ++pos_;
      }
      if (xml_.substr(pos_).starts_with("<!--")) {
        size_t end = xml_.find("-->", pos_ + 4);
        pos_ = (end == std::string_view::npos) ? xml_.size() : end + 3;
      } else {
        break;
      }
    }
  }

  struct Tag {
    std::string name;
    bool closing = false;
    bool self_closing = false;
  };

  std::optional<Tag> NextTag() {
    SkipWhitespaceAndComments();
    if (pos_ >= xml_.size() || xml_[pos_] != '<') return std::nullopt;
    size_t close = xml_.find('>', pos_ + 1);
    if (close == std::string_view::npos) return std::nullopt;
    std::string_view raw = xml_.substr(pos_ + 1, close - pos_ - 1);
    pos_ = close + 1;

    Tag t;
    if (!raw.empty() && raw.front() == '/') {
      t.closing = true;
      raw.remove_prefix(1);
    }
    if (!raw.empty() && raw.back() == '/') {
      t.self_closing = true;
      raw.remove_suffix(1);
    }
    size_t name_end = 0;
    while (name_end < raw.size() && !base::IsAsciiWhitespace(raw[name_end])) {
      ++name_end;
    }
    t.name = base::ToLowerASCII(raw.substr(0, name_end));
    return t;
  }

  std::optional<std::string> ReadTextUntilClose(std::string_view tag_name) {
    std::string closing = "</" + std::string(tag_name) + ">";
    size_t end = FindCaseInsensitive(xml_, closing, pos_);
    if (end == std::string_view::npos) return std::nullopt;
    std::string text =
        DecodeHtmlEntities(xml_.substr(pos_, end - pos_), /*trim=*/false);
    pos_ = end + closing.size();
    return text;
  }

  std::optional<base::Value> ParseValue(int depth) {
    if (depth > kMaxPlistDepth || ++node_count_ > kMaxPlistObjects) {
      return std::nullopt;
    }
    auto tag = NextTag();
    if (!tag || tag->closing) return std::nullopt;

    if (tag->name == "true") return base::Value(true);
    if (tag->name == "false") return base::Value(false);
    if (tag->name == "string" || tag->name == "date") {
      if (tag->self_closing) return base::Value("");
      auto txt = ReadTextUntilClose(tag->name);
      if (!txt) return std::nullopt;
      return base::Value(std::move(*txt));
    }
    if (tag->name == "integer") {
      if (tag->self_closing) return base::Value(0);
      auto txt = ReadTextUntilClose("integer");
      if (!txt) return std::nullopt;
      int64_t n = 0;
      if (!base::StringToInt64(base::TrimWhitespaceASCII(*txt, base::TRIM_ALL),
                               &n)) {
        return base::Value(0);
      }
      if (n >= std::numeric_limits<int>::min() &&
          n <= std::numeric_limits<int>::max()) {
        return base::Value(static_cast<int>(n));
      }
      return base::Value(static_cast<double>(n));
    }
    if (tag->name == "real") {
      if (tag->self_closing) return base::Value(0.0);
      auto txt = ReadTextUntilClose("real");
      if (!txt) return std::nullopt;
      double d = 0.0;
      base::StringToDouble(base::TrimWhitespaceASCII(*txt, base::TRIM_ALL), &d);
      return std::isfinite(d) ? base::Value(d) : base::Value(0.0);
    }
    if (tag->name == "data") {
      if (tag->self_closing) return base::Value(std::vector<uint8_t>{});
      auto txt = ReadTextUntilClose("data");
      if (!txt) return std::nullopt;
      std::string stripped;
      for (char c : *txt) {
        if (!base::IsAsciiWhitespace(c)) stripped.push_back(c);
      }
      if (auto decoded = base::Base64Decode(stripped)) {
        return base::Value(std::move(*decoded));
      }
      return base::Value(std::vector<uint8_t>{});
    }
    if (tag->name == "array") {
      base::ListValue list;
      if (tag->self_closing) return base::Value(std::move(list));
      while (pos_ < xml_.size()) {
        SkipWhitespaceAndComments();
        if (FindCaseInsensitive(xml_.substr(pos_, 9), "</array>") == 0) {
          pos_ += 8;
          return base::Value(std::move(list));
        }
        auto item = ParseValue(depth + 1);
        if (!item) return std::nullopt;
        list.Append(std::move(*item));
      }
      return std::nullopt;
    }
    if (tag->name == "dict") {
      base::DictValue dict;
      if (tag->self_closing) return base::Value(std::move(dict));
      while (pos_ < xml_.size()) {
        SkipWhitespaceAndComments();
        if (FindCaseInsensitive(xml_.substr(pos_, 8), "</dict>") == 0) {
          pos_ += 7;
          return base::Value(std::move(dict));
        }
        auto key_tag = NextTag();
        if (!key_tag || key_tag->closing || key_tag->name != "key") {
          return std::nullopt;
        }
        std::string key_str;
        if (!key_tag->self_closing) {
          auto kt = ReadTextUntilClose("key");
          if (!kt) return std::nullopt;
          key_str = std::move(*kt);
        }
        auto val = ParseValue(depth + 1);
        if (!val) return std::nullopt;
        dict.Set(key_str, std::move(*val));
      }
      return std::nullopt;
    }
    return std::nullopt;
  }

  std::string_view xml_;
  size_t pos_ = 0;
  size_t node_count_ = 0;
};

// ============================================================================
// Pure C++ Read-Only LevelDB + Firestore Protobuf Reader (Arc Boosts)
// ============================================================================

struct ByteCursor {
  base::raw_span<const uint8_t> data;
  size_t offset = 0;

  explicit ByteCursor(base::span<const uint8_t> bytes) : data(bytes) {}

  size_t remaining() const {
    return offset <= data.size() ? data.size() - offset : 0;
  }

  bool ReadByte(uint8_t* out) {
    if (remaining() < 1) return false;
    *out = data[offset++];
    return true;
  }

  bool ReadFixedLE(size_t count, uint64_t* out) {
    if (count == 0 || count > 8 || remaining() < count) return false;
    uint64_t v = 0;
    for (size_t i = 0; i < count; ++i) {
      v |= static_cast<uint64_t>(data[offset + i]) << (8 * i);
    }
    offset += count;
    *out = v;
    return true;
  }

  bool ReadVarint(uint64_t* out) {
    uint64_t v = 0;
    for (int i = 0; i < 10; ++i) {
      uint8_t b = 0;
      if (!ReadByte(&b)) return false;
      if (i == 9 && b > 1) return false;
      v |= static_cast<uint64_t>(b & 0x7Fu) << (7 * i);
      if (b < 0x80u) {
        *out = v;
        return true;
      }
    }
    return false;
  }

  bool ReadCount(size_t limit, size_t* out) {
    uint64_t n = 0;
    if (!ReadVarint(&n) || n > limit) return false;
    *out = static_cast<size_t>(n);
    return true;
  }

  bool ReadSlice(size_t count, std::vector<uint8_t>* out) {
    if (count > remaining()) return false;
    auto sub = data.subspan(offset, count);
    out->assign(sub.begin(), sub.end());
    offset += count;
    return true;
  }

  bool ReadBlob(size_t limit, std::vector<uint8_t>* out) {
    size_t n = 0;
    if (!ReadCount(limit, &n)) return false;
    return ReadSlice(n, out);
  }
};

constexpr size_t kLevelDbMaxFile = 32 * 1024 * 1024;
constexpr size_t kLevelDbMaxTotal = 64 * 1024 * 1024;
constexpr size_t kLevelDbMaxBlock = 8 * 1024 * 1024;
constexpr size_t kLevelDbMaxRecords = 100000;
constexpr size_t kLevelDbMaxKey = 4096;

uint32_t Crc32c(base::span<const uint8_t> data,
                uint8_t extra_prefix,
                bool use_prefix,
                uint8_t extra_suffix,
                bool use_suffix) {
  uint32_t crc = 0xFFFFFFFFu;
  auto step = [&](uint8_t b) {
    crc ^= b;
    for (int i = 0; i < 8; ++i) {
      crc = (crc >> 1) ^ ((crc & 1u) ? 0x82F63B78u : 0u);
    }
  };
  if (use_prefix) step(extra_prefix);
  for (uint8_t b : data) step(b);
  if (use_suffix) step(extra_suffix);
  return ~crc;
}

bool ValidLevelDbCrc(uint32_t raw_crc, uint64_t masked) {
  uint32_t expected = ((raw_crc >> 15) | (raw_crc << 17)) + 0xA282EAD8u;
  return static_cast<uint64_t>(expected) == masked;
}

bool SnappyDecompress(const std::vector<uint8_t>& input,
                      std::vector<uint8_t>* output) {
  ByteCursor c(input);
  size_t uncompressed_size = 0;
  if (!c.ReadCount(kLevelDbMaxBlock, &uncompressed_size)) return false;
  output->clear();
  output->reserve(uncompressed_size);

  while (c.remaining() > 0) {
    uint8_t tag = 0;
    if (!c.ReadByte(&tag)) return false;
    uint8_t kind = tag & 0x03u;
    size_t length = tag >> 2;
    size_t distance = 0;
    if (kind == 0) {
      if (length < 60) {
        length += 1;
      } else {
        uint64_t extra = 0;
        if (!c.ReadFixedLE(length - 59, &extra)) return false;
        length = static_cast<size_t>(extra) + 1;
      }
      if (length > uncompressed_size - output->size() || length > c.remaining()) {
        return false;
      }
      auto sub = c.data.subspan(c.offset, length);
      output->insert(output->end(), sub.begin(), sub.end());
      c.offset += length;
    } else {
      if (kind == 1) {
        uint8_t next = 0;
        if (!c.ReadByte(&next)) return false;
        length = 4 + ((tag >> 2) & 0x07u);
        distance = (static_cast<size_t>(tag & 0xE0u) << 3) | next;
      } else if (kind == 2) {
        uint64_t d = 0;
        if (!c.ReadFixedLE(2, &d)) return false;
        length += 1;
        distance = static_cast<size_t>(d);
      } else {
        uint64_t d = 0;
        if (!c.ReadFixedLE(4, &d)) return false;
        length += 1;
        distance = static_cast<size_t>(d);
      }
      if (distance == 0 || distance > output->size() ||
          length > uncompressed_size - output->size()) {
        return false;
      }
      for (size_t i = 0; i < length; ++i) {
        output->push_back((*output)[output->size() - distance]);
      }
    }
  }
  return output->size() == uncompressed_size;
}

bool ReadLevelDbLogRecords(const std::vector<uint8_t>& bytes,
                           bool allow_truncated_tail,
                           std::vector<std::vector<uint8_t>>* out) {
  out->clear();
  ByteCursor c(bytes);
  std::optional<std::vector<uint8_t>> fragments;

  while (c.remaining() > 0) {
    const size_t block_rem = 32768u - (c.offset % 32768u);
    if (block_rem < 7) {
      size_t pad = std::min(block_rem, c.remaining());
      for (size_t i = 0; i < pad; ++i) {
        if (c.data[c.offset + i] != 0) return false;
      }
      c.offset += pad;
      continue;
    }
    if (c.remaining() < 7) {
      return allow_truncated_tail;
    }
    uint64_t checksum = 0;
    uint64_t length_u64 = 0;
    uint8_t kind = 0;
    if (!c.ReadFixedLE(4, &checksum) || !c.ReadFixedLE(2, &length_u64) ||
        !c.ReadByte(&kind)) {
      return false;
    }
    size_t length = static_cast<size_t>(length_u64);
    if (length == 0 && kind == 0) {
      if (checksum != 0) return false;
      size_t pad = std::min(block_rem - 7, c.remaining());
      for (size_t i = 0; i < pad; ++i) {
        if (c.data[c.offset + i] != 0) return false;
      }
      c.offset += pad;
      continue;
    }
    if (length > block_rem - 7) return false;
    if (length > c.remaining()) {
      return allow_truncated_tail;
    }
    std::vector<uint8_t> payload;
    if (!c.ReadSlice(length, &payload)) return false;
    uint32_t raw_crc = Crc32c(payload, kind, true, 0, false);
    if (!ValidLevelDbCrc(raw_crc, checksum)) return false;

    if (kind == 1) {
      if (fragments.has_value()) return false;
      out->push_back(std::move(payload));
    } else if (kind == 2) {
      if (fragments.has_value()) return false;
      fragments = std::move(payload);
    } else if (kind == 3 || kind == 4) {
      if (!fragments.has_value() ||
          fragments->size() + payload.size() > kLevelDbMaxBlock) {
        return false;
      }
      fragments->insert(fragments->end(), payload.begin(), payload.end());
      if (kind == 4) {
        out->push_back(std::move(*fragments));
        fragments.reset();
      }
    } else {
      return false;
    }
    if (out->size() > kLevelDbMaxRecords) return false;
  }
  return !fragments.has_value() || allow_truncated_tail;
}

template <typename Visitor>
bool VisitLevelDbBlockEntries(const std::vector<uint8_t>& block,
                              Visitor&& visit) {
  if (block.size() < 4) return false;
  ByteCursor trailer(base::span<const uint8_t>(block).last<4>());
  uint64_t restarts = 0;
  if (!trailer.ReadFixedLE(4, &restarts) || restarts == 0 ||
      restarts > (block.size() - 4) / 4) {
    return false;
  }
  const size_t end = block.size() - 4 - static_cast<size_t>(restarts) * 4;
  ByteCursor c(base::span<const uint8_t>(block).first(end));
  std::vector<uint8_t> key;
  size_t count = 0;
  while (c.remaining() > 0) {
    size_t shared = 0;
    size_t suffix = 0;
    size_t val_size = 0;
    if (!c.ReadCount(kLevelDbMaxKey + 8, &shared) ||
        !c.ReadCount(kLevelDbMaxKey + 8, &suffix) ||
        !c.ReadCount(kLevelDbMaxBlock, &val_size)) {
      return false;
    }
    if (shared > key.size() || shared + suffix > kLevelDbMaxKey + 8) {
      return false;
    }
    std::vector<uint8_t> suffix_bytes;
    std::vector<uint8_t> value_bytes;
    if (!c.ReadSlice(suffix, &suffix_bytes) ||
        !c.ReadSlice(val_size, &value_bytes)) {
      return false;
    }
    key.resize(shared);
    key.insert(key.end(), suffix_bytes.begin(), suffix_bytes.end());
    if (!visit(key, value_bytes)) return false;
    if (++count > kLevelDbMaxRecords) return false;
  }
  return true;
}

template <typename Visitor>
bool VisitLevelDbTable(const std::vector<uint8_t>& bytes, Visitor&& visit) {
  if (bytes.size() < 48) return false;
  const auto all = base::span<const uint8_t>(bytes);
  ByteCursor footer(all.last<48>());
  uint64_t dummy = 0;
  size_t index_offset = 0;
  size_t index_size = 0;
  if (!footer.ReadVarint(&dummy) || !footer.ReadVarint(&dummy) ||
      !footer.ReadCount(bytes.size(), &index_offset) ||
      !footer.ReadCount(kLevelDbMaxBlock, &index_size)) {
    return false;
  }
  footer.offset = 40;
  uint64_t magic = 0;
  if (!footer.ReadFixedLE(8, &magic) || magic != 0xDB4775248B80FB57ULL) {
    return false;
  }

  auto read_block = [&](size_t off, size_t sz,
                        std::vector<uint8_t>* out) -> bool {
    if (sz > kLevelDbMaxBlock || off > bytes.size() - 48 ||
        sz + 5 > bytes.size() - 48 - off) {
      return false;
    }
    auto block_slice = all.subspan(off, sz);
    uint8_t kind = all[off + sz];
    ByteCursor cc(all.subspan(off + sz + 1, size_t{4}));
    uint64_t checksum = 0;
    if (!cc.ReadFixedLE(4, &checksum)) return false;
    uint32_t raw_crc = Crc32c(block_slice, 0, false, kind, true);
    if (!ValidLevelDbCrc(raw_crc, checksum)) return false;
    std::vector<uint8_t> payload(block_slice.begin(), block_slice.end());
    if (kind == 0) {
      *out = std::move(payload);
      return true;
    }
    if (kind == 1) {
      return SnappyDecompress(payload, out);
    }
    return false;
  };

  std::vector<uint8_t> index_block;
  if (!read_block(index_offset, index_size, &index_block)) return false;

  return VisitLevelDbBlockEntries(
      index_block,
      [&](const std::vector<uint8_t>& /*k*/,
          const std::vector<uint8_t>& handle_bytes) -> bool {
        ByteCursor hc(handle_bytes);
        size_t off = 0;
        size_t sz = 0;
        if (!hc.ReadCount(bytes.size(), &off) ||
            !hc.ReadCount(kLevelDbMaxBlock, &sz) || hc.remaining() != 0) {
          return false;
        }
        std::vector<uint8_t> data_block;
        if (!read_block(off, sz, &data_block)) return false;
        return VisitLevelDbBlockEntries(data_block, visit);
      });
}

struct LevelDbEntry {
  uint64_t sequence = 0;
  std::optional<std::vector<uint8_t>> value;
};

bool ReadLevelDbDirectoryCopy(
    const base::FilePath& copy_dir,
    std::map<std::string, LevelDbEntry>* out_records) {
  out_records->clear();
  std::string current_raw;
  if (!base::ReadFileToStringWithMaxSize(copy_dir.AppendASCII("CURRENT"),
                                         &current_raw, 256)) {
    return false;
  }
  while (!current_raw.empty() &&
         (current_raw.back() == '\n' || current_raw.back() == '\r')) {
    current_raw.pop_back();
  }
  if (!base::StartsWith(current_raw, "MANIFEST-")) return false;

  std::string manifest_raw;
  if (!base::ReadFileToStringWithMaxSize(copy_dir.AppendASCII(current_raw),
                                         &manifest_raw, kLevelDbMaxFile)) {
    return false;
  }
  std::vector<uint8_t> manifest_bytes(manifest_raw.begin(), manifest_raw.end());
  std::vector<std::vector<uint8_t>> manifest_records;
  if (!ReadLevelDbLogRecords(manifest_bytes, /*allow_truncated_tail=*/false,
                             &manifest_records)) {
    return false;
  }

  std::set<uint64_t> tables;
  uint64_t log_number = 0;
  uint64_t prev_log_number = 0;
  for (const auto& rec : manifest_records) {
    ByteCursor c(rec);
    while (c.remaining() > 0) {
      uint64_t tag = 0;
      if (!c.ReadVarint(&tag)) return false;
      std::vector<uint8_t> tmp;
      uint64_t v = 0;
      switch (tag) {
        case 1:
          if (!c.ReadBlob(128, &tmp)) return false;
          break;
        case 2:
          if (!c.ReadVarint(&log_number)) return false;
          break;
        case 3:
        case 4:
          if (!c.ReadVarint(&v)) return false;
          break;
        case 5:
          if (!c.ReadVarint(&v) || !c.ReadBlob(kLevelDbMaxKey + 8, &tmp)) {
            return false;
          }
          break;
        case 6: {
          uint64_t num = 0;
          if (!c.ReadVarint(&v) || !c.ReadVarint(&num)) return false;
          tables.erase(num);
          break;
        }
        case 7: {
          uint64_t num = 0;
          if (!c.ReadVarint(&v) || !c.ReadVarint(&num) || !c.ReadVarint(&v) ||
              !c.ReadBlob(kLevelDbMaxKey + 8, &tmp) ||
              !c.ReadBlob(kLevelDbMaxKey + 8, &tmp)) {
            return false;
          }
          tables.insert(num);
          if (tables.size() > 1024) return false;
          break;
        }
        case 9:
          if (!c.ReadVarint(&prev_log_number)) return false;
          break;
        default:
          return false;
      }
    }
  }

  size_t retained = 0;
  size_t visited = 0;
  auto apply = [&](const std::vector<uint8_t>& key,
                   std::optional<std::vector<uint8_t>> value,
                   uint64_t seq) -> bool {
    if (++visited > 500000 || key.size() > kLevelDbMaxKey) return false;
    std::string kstr(base::as_string_view(base::span<const uint8_t>(key)));
    auto it = out_records->find(kstr);
    if (it != out_records->end() && it->second.sequence >= seq) {
      return true;
    }
    if (it != out_records->end() && it->second.value) {
      retained -= it->second.value->size();
    }
    if (value) retained += value->size();
    if (retained > kLevelDbMaxTotal ||
        (out_records->size() >= kLevelDbMaxRecords &&
         it == out_records->end())) {
      return false;
    }
    (*out_records)[std::move(kstr)] = LevelDbEntry{seq, std::move(value)};
    return true;
  };

  size_t total_read = 0;
  for (uint64_t num : tables) {
    std::string base_name = base::NumberToString(num);
    if (base_name.size() < 6) {
      base_name.insert(0, 6 - base_name.size(), '0');
    }
    base::FilePath ldb = copy_dir.AppendASCII(base_name + ".ldb");
    base::FilePath path =
        base::PathExists(ldb) ? ldb : copy_dir.AppendASCII(base_name + ".sst");
    std::string raw;
    if (!base::ReadFileToStringWithMaxSize(path, &raw, kLevelDbMaxFile)) {
      return false;
    }
    total_read += raw.size();
    if (total_read > kLevelDbMaxTotal) return false;
    std::vector<uint8_t> tbytes(raw.begin(), raw.end());
    if (!VisitLevelDbTable(
            tbytes,
            [&](const std::vector<uint8_t>& k,
                const std::vector<uint8_t>& v) -> bool {
              if (k.size() < 8) return false;
              ByteCursor tc(base::span<const uint8_t>(k).last<8>());
              uint64_t seq = 0;
              if (!tc.ReadFixedLE(8, &seq)) return false;
              uint64_t kind = seq & 0xFFu;
              if (kind > 1) return false;
              std::vector<uint8_t> user_key(k.begin(), k.end() - 8);
              return apply(user_key,
                           kind == 0 ? std::nullopt
                                     : std::optional<std::vector<uint8_t>>(v),
                           seq);
            })) {
      return false;
    }
  }

  // Apply WAL .log files >= log_number or == prev_log_number.
  std::vector<base::FilePath> log_files;
  base::FileEnumerator enumerator(copy_dir, false, base::FileEnumerator::FILES);
  for (base::FilePath f = enumerator.Next(); !f.empty();
       f = enumerator.Next()) {
    if (f.Extension() == FILE_PATH_LITERAL(".log")) {
      log_files.push_back(std::move(f));
    }
  }
  std::sort(log_files.begin(), log_files.end());
  for (const base::FilePath& lf : log_files) {
    std::string stem = lf.RemoveExtension().BaseName().AsUTF8Unsafe();
    uint64_t num = 0;
    if (!base::StringToUint64(stem, &num)) continue;
    if (num < log_number && num != prev_log_number) continue;
    std::string raw;
    if (!base::ReadFileToStringWithMaxSize(lf, &raw, kLevelDbMaxFile)) {
      return false;
    }
    total_read += raw.size();
    if (total_read > kLevelDbMaxTotal) return false;
    std::vector<uint8_t> lbytes(raw.begin(), raw.end());
    std::vector<std::vector<uint8_t>> batches;
    if (!ReadLevelDbLogRecords(lbytes, /*allow_truncated_tail=*/true,
                               &batches)) {
      return false;
    }
    for (const auto& batch : batches) {
      ByteCursor c(batch);
      uint64_t seq = 0;
      uint64_t count = 0;
      if (!c.ReadFixedLE(8, &seq) || !c.ReadFixedLE(4, &count) ||
          count > kLevelDbMaxRecords) {
        return false;
      }
      for (uint64_t i = 0; i < count; ++i) {
        uint8_t kind = 0;
        std::vector<uint8_t> key;
        if (!c.ReadByte(&kind) || !c.ReadBlob(kLevelDbMaxKey, &key) ||
            kind > 1) {
          return false;
        }
        std::optional<std::vector<uint8_t>> val;
        if (kind == 1) {
          std::vector<uint8_t> v;
          if (!c.ReadBlob(kLevelDbMaxBlock, &v)) return false;
          val = std::move(v);
        }
        if (!apply(key, std::move(val), ((seq + i) << 8) | kind)) return false;
      }
    }
  }
  return true;
}

struct ProtoField {
  uint64_t number = 0;
  uint64_t wire = 0;
  std::vector<uint8_t> bytes;
  uint64_t number_value = 0;
};

bool DecodeProtoFields(const std::vector<uint8_t>& raw,
                       std::vector<ProtoField>* out) {
  out->clear();
  ByteCursor c(raw);
  while (c.remaining() > 0) {
    uint64_t tag = 0;
    if (!c.ReadVarint(&tag)) return false;
    ProtoField f;
    f.wire = tag & 7u;
    f.number = tag >> 3;
    if (f.number == 0 || f.number >= (1ULL << 29)) return false;
    switch (f.wire) {
      case 0:
        if (!c.ReadVarint(&f.number_value)) return false;
        break;
      case 1:
        if (!c.ReadFixedLE(8, &f.number_value)) return false;
        break;
      case 2:
        if (!c.ReadBlob(2 * 1024 * 1024, &f.bytes)) return false;
        break;
      case 5:
        if (!c.ReadFixedLE(4, &f.number_value)) return false;
        break;
      default:
        return false;
    }
    out->push_back(std::move(f));
    if (out->size() > 4096) return false;
  }
  return true;
}

std::optional<std::string> ProtoFieldString(const ProtoField& f,
                                            size_t max_len = 1024 * 1024) {
  if (f.wire != 2 || f.bytes.size() > max_len) return std::nullopt;
  return std::string(base::as_string_view(base::span<const uint8_t>(f.bytes)));
}

std::optional<double> DecodeProtoTimestamp(const std::vector<uint8_t>& raw) {
  std::vector<ProtoField> parts;
  if (!DecodeProtoFields(raw, &parts)) return std::nullopt;
  int64_t secs = 0;
  uint64_t nanos = 0;
  for (const auto& p : parts) {
    if (p.number == 1 && p.wire == 0) secs = static_cast<int64_t>(p.number_value);
    if (p.number == 2 && p.wire == 0) nanos = p.number_value;
  }
  if (nanos >= 1000000000ULL) return std::nullopt;
  return static_cast<double>(secs) + static_cast<double>(nanos) / 1e9;
}

std::optional<base::Value> DecodeFirestoreValue(const std::vector<uint8_t>& raw,
                                                int depth);

std::optional<base::DictValue> DecodeFirestoreMap(
    const std::vector<uint8_t>& raw,
    uint64_t field_number,
    int depth) {
  if (depth > 16) return std::nullopt;
  std::vector<ProtoField> fields;
  if (!DecodeProtoFields(raw, &fields)) return std::nullopt;
  base::DictValue out;
  for (const auto& f : fields) {
    if (f.number != field_number || f.wire != 2) continue;
    std::vector<ProtoField> parts;
    if (!DecodeProtoFields(f.bytes, &parts)) return std::nullopt;
    std::optional<std::string> key;
    const ProtoField* val_field = nullptr;
    for (const auto& p : parts) {
      if (p.number == 1) key = ProtoFieldString(p, 256);
      if (p.number == 2 && p.wire == 2) val_field = &p;
    }
    if (!key || !val_field) continue;
    if (auto val = DecodeFirestoreValue(val_field->bytes, depth + 1)) {
      out.Set(*key, std::move(*val));
    }
  }
  return out;
}

std::optional<base::Value> DecodeFirestoreValue(const std::vector<uint8_t>& raw,
                                                int depth) {
  if (depth > 16) return std::nullopt;
  std::vector<ProtoField> items;
  if (!DecodeProtoFields(raw, &items) || items.size() != 1) return std::nullopt;
  const ProtoField& f = items.front();
  if (f.number == 17 && f.wire == 2) {
    auto s = ProtoFieldString(f);
    return s ? std::optional<base::Value>(base::Value(std::move(*s)))
             : std::nullopt;
  }
  if (f.number == 1 && f.wire == 0) {
    return base::Value(f.number_value == 1);
  }
  if (f.number == 2 && f.wire == 0) {
    return base::Value(static_cast<double>(static_cast<int64_t>(f.number_value)));
  }
  if (f.number == 3 && f.wire == 1) {
    const double d = std::bit_cast<double>(f.number_value);
    return std::isfinite(d) ? base::Value(d) : base::Value();
  }
  if (f.number == 6 && f.wire == 2) {
    auto m = DecodeFirestoreMap(f.bytes, 1, depth + 1);
    return m ? std::optional<base::Value>(base::Value(std::move(*m)))
             : std::nullopt;
  }
  if (f.number == 9 && f.wire == 2) {
    std::vector<ProtoField> entries;
    if (!DecodeProtoFields(f.bytes, &entries)) return std::nullopt;
    base::ListValue list;
    for (const auto& e : entries) {
      if (e.number == 1 && e.wire == 2) {
        if (auto v = DecodeFirestoreValue(e.bytes, depth + 1)) {
          list.Append(std::move(*v));
        }
      }
    }
    return base::Value(std::move(list));
  }
  if (f.number == 10 && f.wire == 2) {
    auto ts = DecodeProtoTimestamp(f.bytes);
    return ts ? base::Value(*ts) : base::Value();
  }
  return base::Value();
}

std::optional<std::set<std::string>> ReadArcEnabledBoostIds(
    const base::FilePath& arc_data_dir) {
  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(
          arc_data_dir.AppendASCII("StorableBoostsData.json"), &raw,
          2 * 1024 * 1024)) {
    return std::nullopt;
  }
  auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
  const auto* ids = dict ? dict->FindList("locallyEnabledBoostIDs") : nullptr;
  if (!ids) return std::nullopt;
  std::set<std::string> out;
  for (const auto& entry : *ids) {
    if (const auto* obj = entry.GetIfDict()) {
      if (const auto* val = obj->FindString("value"); val && !val->empty()) {
        out.insert(base::ToLowerASCII(*val));
      }
    } else if (entry.is_string() && !entry.GetString().empty()) {
      out.insert(base::ToLowerASCII(entry.GetString()));
    }
  }
  return out;
}

std::optional<Boost> MapArcBoostDocument(
    const std::string& doc_id,
    const base::DictValue& fields,
    const std::optional<std::set<std::string>>& locally_enabled,
    const ProfileID& default_profile_id,
    TimestampSec created_at,
    TimestampSec updated_at) {
  const std::string* host = fields.FindString("hostPattern");
  const std::string* serialized = fields.FindString("data");
  if (!host || host->empty() || host->size() > 253 || !serialized) {
    return std::nullopt;
  }
  std::string bare = base::StartsWith(*host, "*.") ? host->substr(2) : *host;
  if (bare.empty() || bare.front() == '.' || bare.back() == '.' ||
      bare.find("..") != std::string::npos) {
    return std::nullopt;
  }
  auto components = base::JSONReader::ReadDict(*serialized, base::JSON_PARSE_RFC);
  if (!components) return std::nullopt;

  Boost b;
  b.id = BrowserImporter::DeterministicUuid("boost", doc_id);
  b.profile_id = default_profile_id;
  if (const auto* title = fields.FindString("title")) b.name = *title;
  b.host_pattern = base::ToLowerASCII(bare);

  bool active = true;
  if (const auto* active_val = fields.Find("isActive")) {
    if (active_val->is_bool()) active = active_val->GetBool();
    else if (active_val->is_string()) active = (active_val->GetString() == "true");
  }
  b.enabled = active && locally_enabled.has_value() &&
              locally_enabled->contains(base::ToLowerASCII(doc_id));

  if (const auto* css = components->FindString("css")) b.custom_css = *css;
  if (const auto* js = components->FindString("js")) b.custom_js = *js;
  if (const auto* font = components->FindDict("font")) {
    if (const auto* fam = font->FindString("family"); fam && !fam->empty()) {
      b.font_family = *fam;
    }
  }
  if (const auto* tt = components->FindString("textTransform");
      tt && (*tt == "capitalize" || *tt == "uppercase" || *tt == "lowercase")) {
    b.text_transform = *tt;
  }
  if (const auto* tz = components->FindDict("textZoom")) {
    if (auto lvl = tz->FindDouble("level");
        lvl && std::isfinite(*lvl) && *lvl >= 50.0 && *lvl <= 200.0) {
      b.text_zoom = *lvl / 100.0;
    }
  }
  if (const auto* zaps = components->FindList("zaps")) {
    size_t idx = 0;
    for (const auto& z : *zaps) {
      if (z.is_string() && !z.GetString().empty() &&
          z.GetString().size() <= kZapMaxSelectorBytes) {
        b.zapped_elements.emplace_back(
            BrowserImporter::DeterministicUuid(
                "zap", doc_id + ":" + base::NumberToString(idx++)),
            z.GetString(), z.GetString());
      }
      if (b.zapped_elements.size() >= kZapMaxEntriesPerBoost) break;
    }
  }
  if (const auto* cs = components->FindDict("colorScheme")) {
    if (const auto* driven = cs->FindDict("colorWheelDriven")) {
      if (const auto* scheme = driven->FindDict("_0")) {
        auto hue = scheme->FindDouble("primaryHueDegrees");
        auto sat = scheme->FindDouble("primarySaturation");
        if (hue && sat && std::isfinite(*hue) && std::isfinite(*sat)) {
          b.color.enabled = true;
          b.color.hue_degrees = *hue;
          b.color.saturation = std::clamp(*sat, 0.0, 2.0);
          b.color.invert = scheme->FindBool("invertLightness").value_or(false);
          if (const auto* adv = scheme->FindDict("advancedSettings")) {
            if (auto shift = adv->FindDouble("lightnessShift");
                shift && std::isfinite(*shift)) {
              b.color.lightness = std::clamp(*shift / 2.0, -0.5, 0.5);
            }
            if (auto cont = adv->FindDouble("preservedLightness");
                cont && std::isfinite(*cont)) {
              b.color.contrast = std::clamp(0.5 + *cont, 0.5, 1.5);
            }
          }
        }
      }
    }
  }

  b.created_at = created_at;
  b.modified_at = updated_at > 0.0 ? updated_at : created_at;
  return b;
}

void ReadArcBoosts(const base::FilePath& arc_data_dir,
                   const ProfileID& default_profile_id,
                   std::vector<Boost>* out_boosts) {
  auto enabled_ids = ReadArcEnabledBoostIds(arc_data_dir);

  // Locate Firestore cache directory.
  base::FilePath cache_dir =
      arc_data_dir.AppendASCII("Firestore").AppendASCII("main");
#if BUILDFLAG(IS_MAC)
  if (!base::DirectoryExists(cache_dir)) {
    auto env = base::Environment::Create();
    std::string home = env->GetVar("HOME").value_or("");
    if (!home.empty()) {
      base::FilePath app_sup = base::FilePath(home)
                                   .AppendASCII("Library")
                                   .AppendASCII("Application Support");
      base::FilePath real_arc_dir = app_sup.AppendASCII("Arc");
      if (arc_data_dir == real_arc_dir) {
        cache_dir = app_sup.AppendASCII("firestore")
                        .AppendASCII("Arc")
                        .AppendASCII("bcny-arc-server")
                        .AppendASCII("main");
      }
    }
  }
#endif

  if (base::DirectoryExists(cache_dir) && !base::IsLink(cache_dir)) {
    base::ScopedTempDir temp_dir;
    if (temp_dir.CreateUniqueTempDir()) {
      base::FileEnumerator e(cache_dir, false, base::FileEnumerator::FILES);
      size_t count = 0;
      for (base::FilePath f = e.Next(); !f.empty() && count < 256;
           f = e.Next()) {
        if (!base::IsLink(f)) {
          base::CopyFile(f, temp_dir.GetPath().Append(f.BaseName()));
          ++count;
        }
      }
      std::map<std::string, LevelDbEntry> records;
      if (ReadLevelDbDirectoryCopy(temp_dir.GetPath(), &records)) {
        std::string prefix;
        prefix.push_back(static_cast<char>(0x85));
        prefix += "remote_document";
        prefix.push_back('\0');
        prefix.push_back('\x01');

        for (const auto& [k, rec] : records) {
          if (!base::StartsWith(k, prefix) || !rec.value.has_value()) continue;
          std::vector<ProtoField> wrapper;
          if (!DecodeProtoFields(*rec.value, &wrapper)) continue;
          const ProtoField* variant = nullptr;
          for (const auto& f : wrapper) {
            if (f.number >= 1 && f.number <= 3 && f.wire == 2) {
              variant = &f;
              break;
            }
          }
          if (!variant || variant->number != 2) continue;
          std::vector<ProtoField> contents;
          if (!DecodeProtoFields(variant->bytes, &contents)) continue;
          std::optional<std::string> doc_name;
          TimestampSec created_at = 0.0;
          TimestampSec updated_at = 0.0;
          for (const auto& f : contents) {
            if (f.number == 1) doc_name = ProtoFieldString(f, 4096);
            if (f.number == 3 && f.wire == 2) {
              created_at = DecodeProtoTimestamp(f.bytes).value_or(0.0);
            }
            if (f.number == 4 && f.wire == 2) {
              updated_at = DecodeProtoTimestamp(f.bytes).value_or(0.0);
            }
          }
          if (!doc_name) continue;
          // projects/bcny-arc-server/databases/(default)/documents/boosts/<id>
          const std::string boosts_prefix =
              "projects/bcny-arc-server/databases/(default)/documents/boosts/";
          if (!base::StartsWith(*doc_name, boosts_prefix)) continue;
          std::string doc_id = doc_name->substr(boosts_prefix.size());
          if (doc_id.empty() || doc_id.find('/') != std::string::npos) continue;
          auto fields = DecodeFirestoreMap(variant->bytes, 2, 0);
          if (!fields) continue;
          if (auto boost = MapArcBoostDocument(doc_id, *fields, enabled_ids,
                                               default_profile_id, created_at,
                                               updated_at)) {
            out_boosts->push_back(std::move(*boost));
          }
        }
      }
    }
  }
}

// Reads Arc Notes and Easels from <arc_data_dir>/StorableARCDocuments and
// <arc_data_dir>/StorableEasels (if present).
void ReadArcNotesAndEasels(const base::FilePath& arc_data_dir,
                            std::vector<NoteDocument>* out_notes,
                            std::vector<EaselDocument>* out_easels) {
  auto parse_arc_doc_file = [&](const base::FilePath& file) {
    std::string raw;
    if (!base::ReadFileToStringWithMaxSize(file, &raw, kNoteMaxDocumentBytes)) {
      return;
    }
    auto parsed = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
    if (!parsed) return;
    const base::DictValue* root = parsed->FindDict("arcDocument");
    if (!root) root = &*parsed;

    const std::string* arc_id = root->FindString("id");
    if (!arc_id || arc_id->empty()) return;

    std::string title;
    if (const auto* tdict = root->FindDict("title")) {
      if (const auto* v = tdict->FindString("value")) title = *v;
    } else if (const auto* tstr = root->FindString("title")) {
      title = *tstr;
    }

    TimestampSec created =
        root->FindDouble("createdAt").value_or(0.0) + kApple2001EpochOffsetSec;
    TimestampSec modified =
        root->FindDouble("lastUpdatedAt")
            .value_or(root->FindDouble("createdAt").value_or(0.0)) +
        kApple2001EpochOffsetSec;

    const base::DictValue* data = root->FindDict("data");
    // Check if Easel canvas payload.
    const base::DictValue* easel_data =
        data ? data->FindDict("easel") : root->FindDict("easel");
    if (easel_data || root->FindList("elements") || root->FindList("objects")) {
      EaselDocument easel;
      easel.id = BrowserImporter::DeterministicUuid("easel", *arc_id);
      easel.title = title.empty() ? "Untitled Easel" : title;
      easel.created_at = created;
      easel.modified_at = modified;
      const base::DictValue* src = easel_data ? easel_data : root;
      easel.canvas_width = src->FindDouble("canvasWidth").value_or(1000.0);
      easel.canvas_height = src->FindDouble("canvasHeight").value_or(1400.0);
      const base::ListValue* elems = src->FindList("elements");
      if (!elems) elems = src->FindList("objects");
      if (elems) {
        int z = 0;
        for (const auto& ev : *elems) {
          const auto* ed = ev.GetIfDict();
          if (!ed) continue;
          EaselElement el;
          el.id = ed->FindString("id")
                      ? *ed->FindString("id")
                      : BrowserImporter::DeterministicUuid(
                            "easel-el",
                            *arc_id + ":" + base::NumberToString(z));
          el.type = ed->FindString("type") ? *ed->FindString("type") : "text";
          el.x = ed->FindDouble("x").value_or(0.0);
          el.y = ed->FindDouble("y").value_or(0.0);
          el.width = ed->FindDouble("width").value_or(200.0);
          el.height = ed->FindDouble("height").value_or(100.0);
          if (const auto* c = ed->FindString("content")) el.content = *c;
          else if (const auto* t = ed->FindString("text")) el.content = *t;
          if (const auto* fc = ed->FindString("fillColor")) el.fill_color = *fc;
          if (const auto* sc = ed->FindString("strokeColor"))
            el.stroke_color = *sc;
          el.stroke_width = ed->FindDouble("strokeWidth").value_or(2.0);
          el.font_size = ed->FindDouble("fontSize").value_or(16.0);
          el.z_index = ed->FindInt("zIndex").value_or(z);
          easel.elements.push_back(std::move(el));
          ++z;
        }
      }
      out_easels->push_back(std::move(easel));
      return;
    }

    // Otherwise parse Arc Note (scratchpad blocks).
    const base::DictValue* scratchpad = data ? data->FindDict("scratchpad") : nullptr;
    if (!scratchpad) return;

    std::map<std::string, const base::DictValue*> blocks;
    if (const base::Value* raw_blocks = scratchpad->Find("blocks")) {
      if (const auto* bd = raw_blocks->GetIfDict()) {
        for (const auto [k, v] : *bd) {
          if (const auto* item = v.GetIfDict()) blocks[k] = item;
        }
      } else if (const auto* bl = raw_blocks->GetIfList()) {
        for (size_t i = 0; i + 1 < bl->size(); i += 2) {
          if ((*bl)[i].is_string() && (*bl)[i + 1].is_dict()) {
            blocks[(*bl)[i].GetString()] = &(*bl)[i + 1].GetDict();
          }
        }
      }
    }

    std::vector<std::string> order;
    if (const auto* roots = scratchpad->FindList("rootBlocks")) {
      for (const auto& rv : *roots) {
        if (rv.is_string()) order.push_back(rv.GetString());
      }
    } else {
      for (const auto& [k, _] : blocks) order.push_back(k);
    }

    NoteDocument note;
    note.id = BrowserImporter::DeterministicUuid("note", *arc_id);
    note.title = title.empty() ? "Untitled Note" : title;
    note.created_at = created;
    note.modified_at = modified;

    for (const std::string& block_id : order) {
      auto it = blocks.find(block_id);
      if (it == blocks.end()) continue;
      const std::string* btext = it->second->FindString("text");
      if (!btext) continue;
      if (!note.text.empty()) note.text.push_back('\n');
      const int offset = static_cast<int>(note.text.size());
      note.text.append(*btext);
      const int blen = static_cast<int>(btext->size());

      if (const auto* props = it->second->FindList("properties")) {
        for (const auto& pv : *props) {
          const auto* pd = pv.GetIfDict();
          if (!pd) continue;
          const base::DictValue* rich = pd->FindDict("richText");
          if (!rich) rich = pd;

          int loc = -1;
          int len = -1;
          if (const auto* rlist = rich->FindList("range");
              rlist && rlist->size() == 2) {
            loc = (*rlist)[0].GetIfInt().value_or(-1);
            len = (*rlist)[1].GetIfInt().value_or(-1);
          } else if (const auto* rdict = rich->FindDict("range")) {
            loc = rdict->FindInt("location").value_or(-1);
            len = rdict->FindInt("length").value_or(-1);
          }
          if (loc < 0 || len < 0 || loc + len > blen) continue;

          std::string fmt_name;
          const base::DictValue* payload = nullptr;
          if (const auto* v = rich->Find("value")) {
            if (v->is_string()) {
              fmt_name = v->GetString();
            } else if (const auto* vd = v->GetIfDict(); vd && vd->size() == 1) {
              auto first = vd->begin();
              fmt_name = first->first;
              payload = first->second.GetIfDict();
              if (payload && payload->FindDict("_0")) {
                payload = payload->FindDict("_0");
              }
            }
          }
          NoteFormatRange fmt;
          fmt.location = offset + loc;
          fmt.length = len;
          if (fmt_name == "bold" || fmt_name == "italic" ||
              fmt_name == "underline" || fmt_name == "strikethrough" ||
              fmt_name == "h1" || fmt_name == "h2" || fmt_name == "h3") {
            fmt.type = fmt_name;
          } else if (fmt_name == "unorderedList") {
            fmt.type = "bulletList";
            fmt.level = payload ? payload->FindInt("level").value_or(0) : 0;
          } else if (fmt_name == "orderedList") {
            fmt.type = "numberedList";
            fmt.level = payload ? payload->FindInt("level").value_or(0) : 0;
          } else if ((fmt_name == "formattedHyperlink" ||
                      fmt_name == "hyperlink") &&
                     payload) {
            if (const auto* href = payload->FindString("url");
                href && IsSupportedImportScheme(*href)) {
              fmt.type = "link";
              fmt.url = *href;
            } else {
              continue;
            }
          } else {
            continue;
          }
          note.formats.push_back(std::move(fmt));
        }
      }
    }
    out_notes->push_back(std::move(note));
  };

  for (const char* sub : {"StorableARCDocuments", "StorableEasels", "Easels"}) {
    base::FilePath dir = arc_data_dir.AppendASCII(sub);
    if (!base::DirectoryExists(dir)) continue;
    base::FileEnumerator e(dir, /*recursive=*/true, base::FileEnumerator::FILES);
    size_t count = 0;
    for (base::FilePath f = e.Next(); !f.empty() && count < 5000;
         f = e.Next()) {
      std::string name = f.BaseName().AsUTF8Unsafe();
      if (!name.empty() && name[0] == '.') continue;
      parse_arc_doc_file(f);
      ++count;
    }
  }
}

// Read-only parser for legacy Open Boosts JSON (`BoostFileDTO`).
void ReadLegacyBoostsJsonFile(const base::FilePath& path,
                              const ProfileID& profile_id,
                              std::vector<Boost>* out) {
  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(path, &raw, 32 * 1024 * 1024)) {
    return;
  }
  auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
  const auto* list = dict ? dict->FindList("boosts") : nullptr;
  if (!list) return;
  for (const auto& v : *list) {
    const auto* bd = v.GetIfDict();
    if (!bd) continue;
    const auto* id = bd->FindString("id");
    if (!id || id->empty()) continue;
    Boost b;
    b.id = NormalizeUuid(*id).value_or(*id);
    b.profile_id = profile_id;
    if (const auto* s = bd->FindString("name")) b.name = *s;
    if (const auto* sm = bd->FindDict("siteMatch")) {
      if (const auto* dom = sm->FindString("domain")) b.host_pattern = *dom;
    } else if (const auto* hp = bd->FindString("hostPattern")) {
      b.host_pattern = *hp;
    }
    b.enabled = bd->FindBool("isEnabled")
                    .value_or(bd->FindBool("enabled").value_or(true));
    if (const auto* s = bd->FindString("css")) b.custom_css = *s;
    else if (const auto* s2 = bd->FindString("customCSS")) b.custom_css = *s2;
    if (const auto* s = bd->FindString("js")) b.custom_js = *s;
    else if (const auto* s2 = bd->FindString("customJS")) b.custom_js = *s2;
    if (const auto* c = bd->FindDict("colorAdjustment")) {
      b.color.enabled = c->FindBool("enabled").value_or(true);
      b.color.hue_degrees =
          c->FindDouble("hueRotateDegrees")
              .value_or(c->FindDouble("hueDegrees").value_or(0.0));
      b.color.saturation = c->FindDouble("saturation").value_or(1.0);
      if (auto br = c->FindDouble("brightness")) b.color.lightness = *br - 1.0;
      else b.color.lightness = c->FindDouble("lightness").value_or(0.0);
      b.color.contrast = c->FindDouble("contrast").value_or(1.0);
      if (auto inv_b = c->FindBool("invert")) b.color.invert = *inv_b;
      else b.color.invert = c->FindDouble("invert").value_or(0.0) >= 0.5;
    } else if (const auto* cw = bd->FindDict("colorWheel")) {
      b.color.enabled = true;
      b.color.hue_degrees = cw->FindDouble("hue").value_or(0.0);
      b.color.saturation = cw->FindDouble("intensity").value_or(1.0);
      b.color.lightness = cw->FindDouble("brightness").value_or(1.0) - 1.0;
      b.color.contrast = cw->FindDouble("contrast").value_or(1.0);
      b.color.invert = cw->FindBool("invertLightness").value_or(false);
    }
    if (const auto* s = bd->FindString("fontFamily")) b.font_family = *s;
    b.text_zoom = bd->FindDouble("textZoom").value_or(1.0);
    if (const auto* s = bd->FindString("textTransform")) b.text_transform = *s;
    const auto* zaps = bd->FindList("zaps");
    if (!zaps) zaps = bd->FindList("zappedElements");
    if (zaps) {
      for (const auto& zv : *zaps) {
        const auto* zd = zv.GetIfDict();
        if (!zd) continue;
        const auto* sel = zd->FindString("selector");
        if (!sel || sel->empty()) continue;
        std::string zid = zd->FindString("id") ? *zd->FindString("id")
                                               : GenerateUuidV4();
        std::string zlbl = zd->FindString("label") ? *zd->FindString("label")
                                                   : *sel;
        b.zapped_elements.emplace_back(std::move(zid), *sel, std::move(zlbl));
      }
    }
    b.created_at = bd->FindDouble("createdAt").value_or(0.0);
    b.modified_at =
        bd->FindDouble("updatedAt")
            .value_or(bd->FindDouble("modifiedAt").value_or(b.created_at));
    out->push_back(std::move(b));
  }
}

void CountSidebarNodes(const std::vector<SidebarNode>& nodes,
                       size_t* tabs,
                       size_t* folders,
                       size_t* splits) {
  for (const SidebarNode& n : nodes) {
    if (n.as_tab()) {
      ++(*tabs);
    } else if (const Folder* f = n.as_folder()) {
      ++(*folders);
      CountSidebarNodes(f->children, tabs, folders, splits);
    } else if (const Split* s = n.as_split()) {
      ++(*splits);
      *tabs += s->panes.size();
    }
  }
}

void CollectAllNodeIds(const SidebarNode& node, std::vector<ItemID>* out) {
  out->push_back(node.id());
  if (const Folder* f = node.as_folder()) {
    for (const SidebarNode& c : f->children) {
      CollectAllNodeIds(c, out);
    }
  } else if (const Split* s = node.as_split()) {
    for (const Tab& p : s->panes) {
      out->push_back(p.id);
    }
  }
}

void RemoveNodesByIdRecursive(std::vector<SidebarNode>* list,
                              const std::set<ItemID>& remove_ids) {
  if (!list) return;
  for (SidebarNode& node : *list) {
    if (Folder* f = node.as_folder()) {
      RemoveNodesByIdRecursive(&f->children, remove_ids);
    }
  }
  std::erase_if(*list, [&](const SidebarNode& n) {
    return remove_ids.contains(n.id());
  });
}

void SetPinnedUrlRecursive(SidebarNode* node) {
  if (Tab* t = node->as_tab()) {
    if (!t->pinned_url.has_value() && !t->url.empty()) {
      t->pinned_url = t->url;
    }
  } else if (Folder* f = node->as_folder()) {
    for (SidebarNode& c : f->children) {
      SetPinnedUrlRecursive(&c);
    }
  } else if (Split* s = node->as_split()) {
    for (Tab& p : s->panes) {
      if (!p.pinned_url.has_value() && !p.url.empty()) {
        p.pinned_url = p.url;
      }
    }
  }
}

}  // namespace

// ============================================================================
// Deterministic UUID & Browser Probing
// ============================================================================

// static
std::string BrowserImporter::DeterministicUuid(std::string_view namespace_tag,
                                               std::string_view source_id) {
  base::Uuid parsed = base::Uuid::ParseCaseInsensitive(source_id);
  if (parsed.is_valid()) {
    return parsed.AsLowercaseString();
  }
  std::string seed = std::string(namespace_tag) + ":" + std::string(source_id);
  std::string rev(seed.rbegin(), seed.rend());
  uint64_t h1 = Fnv1a64(seed, 14695981039346656037ULL);
  uint64_t h2 = Fnv1a64(rev, 1469598103934665603ULL);

  std::array<uint8_t, 16> bytes{};
  for (int i = 0; i < 8; ++i) {
    bytes[i] = static_cast<uint8_t>((h1 >> (8 * i)) & 0xFFu);
    bytes[8 + i] = static_cast<uint8_t>((h2 >> (8 * i)) & 0xFFu);
  }
  bytes[6] = static_cast<uint8_t>((bytes[6] & 0x0Fu) | 0x40u);
  bytes[8] = static_cast<uint8_t>((bytes[8] & 0x3Fu) | 0x80u);

  const std::string hex = base::HexEncodeLower(bytes);
  return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-" + hex.substr(12, 4) +
         "-" + hex.substr(16, 4) + "-" + hex.substr(20, 12);
}

// static
base::FilePath BrowserImporter::DefaultSafariDirectory() {
#if BUILDFLAG(IS_MAC)
  auto env = base::Environment::Create();
  std::string home = env->GetVar("HOME").value_or("");
  if (!home.empty()) {
    return base::FilePath(home).AppendASCII("Library").AppendASCII("Safari");
  }
#endif
  return base::FilePath();
}

// static
base::FilePath BrowserImporter::DefaultOpenLegacyDirectory() {
#if BUILDFLAG(IS_MAC)
  auto env = base::Environment::Create();
  std::string home = env->GetVar("HOME").value_or("");
  if (!home.empty()) {
    return base::FilePath(home)
        .AppendASCII("Library")
        .AppendASCII("Application Support")
        .AppendASCII("Open");
  }
#endif
  return base::FilePath();
}

// static
SafariAccessStatus BrowserImporter::CheckSafariAccess(
    const base::FilePath& safari_dir) {
  if (safari_dir.empty()) {
    return SafariAccessStatus::kNotFound;
  }
  base::FilePath plist = safari_dir.AppendASCII("Bookmarks.plist");
#if BUILDFLAG(IS_POSIX)
  int fd = ::open(plist.value().c_str(), O_RDONLY | O_NOFOLLOW);
  if (fd >= 0) {
    ::close(fd);
    return SafariAccessStatus::kGranted;
  }
  if (errno == EPERM || errno == EACCES) {
    return SafariAccessStatus::kPermissionDenied;
  }
  if (errno == ENOENT) {
    // Also check History.db in case Bookmarks.plist was not yet created.
    base::FilePath hist = safari_dir.AppendASCII("History.db");
    int hfd = ::open(hist.value().c_str(), O_RDONLY | O_NOFOLLOW);
    if (hfd >= 0) {
      ::close(hfd);
      return SafariAccessStatus::kGranted;
    }
    if (errno == EPERM || errno == EACCES) {
      return SafariAccessStatus::kPermissionDenied;
    }
    return SafariAccessStatus::kNotFound;
  }
  return SafariAccessStatus::kPermissionDenied;
#else
  return base::PathExists(plist) ? SafariAccessStatus::kGranted
                                 : SafariAccessStatus::kNotFound;
#endif
}

// static
std::optional<base::Value> BrowserImporter::ParsePlist(std::string_view bytes) {
  if (bytes.size() >= 8 && bytes.substr(0, 8) == "bplist00") {
    BinaryPlistParser parser(bytes);
    return parser.Parse();
  }
  XmlPlistParser xml_parser(bytes);
  return xml_parser.Parse();
}

// static
std::vector<DetectedBrowser> BrowserImporter::ProbeInstalledBrowsers() {
  struct Candidate {
    std::string id;
    std::string name;
    BrowserFamily family;
    base::FilePath root;
  };
  std::vector<Candidate> candidates;
  auto env = base::Environment::Create();

#if BUILDFLAG(IS_WIN)
  std::string local_app_data = env->GetVar("LOCALAPPDATA").value_or("");
  std::string roaming_app_data = env->GetVar("APPDATA").value_or("");
  if (!local_app_data.empty()) {
    base::FilePath lad = base::FilePath::FromUTF8Unsafe(local_app_data);
    candidates.push_back(
        {"arc", "Arc", BrowserFamily::kArc,
         lad.AppendASCII("Packages")
             .AppendASCII("TheBrowserCompany.Arc_ttt1ap7aakyb4")
             .AppendASCII("LocalCache")
             .AppendASCII("Local")
             .AppendASCII("Arc")});
    candidates.push_back(
        {"chrome", "Google Chrome", BrowserFamily::kChromium,
         lad.AppendASCII("Google").AppendASCII("Chrome").AppendASCII(
             "User Data")});
    candidates.push_back(
        {"edge", "Microsoft Edge", BrowserFamily::kChromium,
         lad.AppendASCII("Microsoft").AppendASCII("Edge").AppendASCII(
             "User Data")});
    candidates.push_back(
        {"brave", "Brave", BrowserFamily::kChromium,
         lad.AppendASCII("BraveSoftware")
             .AppendASCII("Brave-Browser")
             .AppendASCII("User Data")});
    candidates.push_back(
        {"vivaldi", "Vivaldi", BrowserFamily::kChromium,
         lad.AppendASCII("Vivaldi").AppendASCII("User Data")});
    candidates.push_back(
        {"chromium", "Chromium", BrowserFamily::kChromium,
         lad.AppendASCII("Chromium").AppendASCII("User Data")});
  }
  if (!roaming_app_data.empty()) {
    base::FilePath rad = base::FilePath::FromUTF8Unsafe(roaming_app_data);
    candidates.push_back({"firefox", "Firefox", BrowserFamily::kFirefox,
                          rad.AppendASCII("Mozilla").AppendASCII("Firefox")});
  }
#elif BUILDFLAG(IS_MAC)
  std::string home = env->GetVar("HOME").value_or("");
  if (!home.empty()) {
    base::FilePath lib = base::FilePath(home).AppendASCII("Library");
    base::FilePath app_sup = lib.AppendASCII("Application Support");
    candidates.push_back({"open-legacy", "Open (Legacy)",
                          BrowserFamily::kOpenLegacy,
                          app_sup.AppendASCII("Open")});
    candidates.push_back(
        {"arc", "Arc", BrowserFamily::kArc, app_sup.AppendASCII("Arc")});
    candidates.push_back({"safari", "Safari", BrowserFamily::kSafari,
                          lib.AppendASCII("Safari")});
    candidates.push_back(
        {"chrome", "Google Chrome", BrowserFamily::kChromium,
         app_sup.AppendASCII("Google").AppendASCII("Chrome")});
    candidates.push_back({"edge", "Microsoft Edge", BrowserFamily::kChromium,
                          app_sup.AppendASCII("Microsoft Edge")});
    candidates.push_back(
        {"brave", "Brave", BrowserFamily::kChromium,
         app_sup.AppendASCII("BraveSoftware").AppendASCII("Brave-Browser")});
    candidates.push_back({"vivaldi", "Vivaldi", BrowserFamily::kChromium,
                          app_sup.AppendASCII("Vivaldi")});
    candidates.push_back({"chromium", "Chromium", BrowserFamily::kChromium,
                          app_sup.AppendASCII("Chromium")});
    candidates.push_back({"firefox", "Firefox", BrowserFamily::kFirefox,
                          app_sup.AppendASCII("Firefox")});
  }
#else  // Linux / POSIX
  std::string home = env->GetVar("HOME").value_or("");
  std::string xdg_config = env->GetVar("XDG_CONFIG_HOME").value_or("");
  base::FilePath config_root =
      !xdg_config.empty()
          ? base::FilePath(xdg_config)
          : (!home.empty() ? base::FilePath(home).AppendASCII(".config")
                           : base::FilePath());
  if (!config_root.empty()) {
    candidates.push_back({"chrome", "Google Chrome", BrowserFamily::kChromium,
                          config_root.AppendASCII("google-chrome")});
    candidates.push_back({"chromium", "Chromium", BrowserFamily::kChromium,
                          config_root.AppendASCII("chromium")});
    candidates.push_back(
        {"brave", "Brave", BrowserFamily::kChromium,
         config_root.AppendASCII("BraveSoftware").AppendASCII("Brave-Browser")});
    candidates.push_back({"edge", "Microsoft Edge", BrowserFamily::kChromium,
                          config_root.AppendASCII("microsoft-edge")});
    candidates.push_back({"vivaldi", "Vivaldi", BrowserFamily::kChromium,
                          config_root.AppendASCII("vivaldi")});
  }
  if (!home.empty()) {
    candidates.push_back({"firefox", "Firefox", BrowserFamily::kFirefox,
                          base::FilePath(home)
                              .AppendASCII(".mozilla")
                              .AppendASCII("firefox")});
  }
#endif

  std::vector<DetectedBrowser> result;
  for (const auto& c : candidates) {
    if (!base::DirectoryExists(c.root)) continue;
    DetectedBrowser browser;
    browser.id = c.id;
    browser.name = c.name;
    browser.family = c.family;
    browser.data_root = c.root;
    if (c.family == BrowserFamily::kChromium) {
      browser.profiles = ProbeChromiumProfiles(c.root);
    } else if (c.family == BrowserFamily::kFirefox) {
      browser.profiles = ProbeFirefoxProfiles(c.root);
    } else if (c.family == BrowserFamily::kArc) {
      if (base::PathExists(c.root.AppendASCII("StorableSidebar.json"))) {
        DetectedBrowserProfile p;
        p.id = "Arc";
        p.name = "Arc";
        p.directory = c.root;
        p.is_default = true;
        p.bookmark_count = EstimateArcSidebarTabCount(c.root);
        p.history_count = EstimateChromiumHistoryCount(
            c.root.AppendASCII("User Data").AppendASCII("Default"));
        browser.profiles.push_back(std::move(p));
      }
    } else if (c.family == BrowserFamily::kOpenLegacy) {
      if (base::PathExists(
              c.root.AppendASCII("State").AppendASCII("browser.json"))) {
        DetectedBrowserProfile p;
        p.id = "OpenLegacy";
        p.name = "Open (Legacy)";
        p.directory = c.root;
        p.is_default = true;
        p.bookmark_count = EstimateOpenLegacyTabCount(c.root);
        p.history_count = EstimateOpenLegacyHistoryCount(c.root);
        browser.profiles.push_back(std::move(p));
      }
    } else if (c.family == BrowserFamily::kSafari) {
      SafariAccessStatus access = CheckSafariAccess(c.root);
      if (access != SafariAccessStatus::kNotFound) {
        DetectedBrowserProfile p;
        p.id = "Safari";
        p.name = "Safari";
        p.directory = c.root;
        p.is_default = true;
        if (access == SafariAccessStatus::kPermissionDenied) {
          p.access_denied = true;
          p.access_error = "Full Disk Access required to read Safari data";
        } else {
          std::vector<ImportedBookmarkNode> roots;
          ImportBookmarksReport report;
          if (ReadSafariBookmarks(c.root, &roots, &report)) {
            p.bookmark_count = static_cast<int>(
                std::min<size_t>(report.urls, kMaxReportedProbeCount));
          }
          p.history_count = EstimateSafariHistoryCount(c.root);
        }
        browser.profiles.push_back(std::move(p));
      }
    }
    if (!browser.profiles.empty()) {
      result.push_back(std::move(browser));
    }
  }
  return result;
}

// static
Folder BrowserImporter::BuildImportedBookmarksFolder(
    std::string_view browser_name,
    std::string_view source_key,
    const std::vector<ImportedBookmarkNode>& roots) {
  TimestampSec now = base::Time::Now().InSecondsFSinceUnixEpoch();

  auto convert = [&](auto& self,
                     const ImportedBookmarkNode& bn) -> std::optional<SidebarNode> {
    std::string item_id = DeterministicUuid(
        "browser-bookmark",
        std::string(source_key) + ":" + bn.source_id);
    if (!bn.is_folder) {
      Tab t;
      t.id = item_id;
      t.url = bn.url;
      t.pinned_url = bn.url;
      t.title = bn.title.empty() ? bn.url : bn.title;
      t.created_at = bn.date_added.value_or(now);
      t.last_active_at = t.created_at;
      return SidebarNode(std::move(t));
    }
    Folder f;
    f.id = item_id;
    f.title = bn.title;
    f.is_expanded = false;
    for (const auto& child : bn.children) {
      if (auto node = self(self, child)) {
        f.children.push_back(std::move(*node));
      }
    }
    if (f.children.empty()) return std::nullopt;
    return SidebarNode(std::move(f));
  };

  Folder root;
  root.id = DeterministicUuid("browser-bookmark",
                              std::string(source_key) + ":<root>");
  root.title = "Imported from " + std::string(browser_name);
  root.is_expanded = false;
  for (const auto& r : roots) {
    if (auto node = convert(convert, r)) {
      root.children.push_back(std::move(*node));
    }
  }
  return root;
}

// ============================================================================
// Chromium Bookmarks & History
// ============================================================================

// static
bool BrowserImporter::ReadChromiumBookmarks(
    const base::FilePath& profile_dir,
    std::vector<ImportedBookmarkNode>* out_roots,
    ImportBookmarksReport* out_report) {
  if (!out_roots) return false;
  out_roots->clear();
  ImportBookmarksReport report;

  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(profile_dir.AppendASCII("Bookmarks"),
                                         &raw, kMaxJsonBytes)) {
    return false;
  }
  auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
  const auto* roots = dict ? dict->FindDict("roots") : nullptr;
  if (!roots) return false;

  size_t total_nodes = 0;
  auto parse_node = [&](auto& self, const base::DictValue* obj,
                        int depth) -> std::optional<ImportedBookmarkNode> {
    if (!obj || depth >= kMaxBookmarkDepth || ++total_nodes > kMaxBookmarkNodes) {
      ++report.skipped;
      return std::nullopt;
    }
    const auto* type = obj->FindString("type");
    if (!type) {
      ++report.skipped;
      return std::nullopt;
    }
    std::string guid = obj->FindString("guid")
                           ? *obj->FindString("guid")
                           : (obj->FindString("id") ? *obj->FindString("id")
                                                    : "");
    std::string title = obj->FindString("name") ? *obj->FindString("name") : "";

    if (*type == "folder") {
      ImportedBookmarkNode f;
      f.is_folder = true;
      f.source_id = guid;
      f.title = title;
      if (const auto* kids = obj->FindList("children")) {
        for (const auto& k : *kids) {
          if (auto child = self(self, k.GetIfDict(), depth + 1)) {
            f.children.push_back(std::move(*child));
          }
        }
      }
      if (!f.children.empty()) {
        ++report.folders;
        return f;
      }
      ++report.skipped;
      return std::nullopt;
    }

    if (*type == "url") {
      const auto* url_str = obj->FindString("url");
      if (!url_str || !IsSupportedImportScheme(*url_str)) {
        ++report.skipped;
        return std::nullopt;
      }
      ImportedBookmarkNode u;
      u.is_folder = false;
      u.source_id = guid;
      u.title = title;
      u.url = *url_str;
      if (const auto* added_str = obj->FindString("date_added")) {
        int64_t micros = 0;
        if (base::StringToInt64(*added_str, &micros)) {
          u.date_added = ChromiumTimeMicrosToUnix(micros);
        }
      }
      ++report.urls;
      return u;
    }
    ++report.skipped;
    return std::nullopt;
  };

  static constexpr std::pair<const char*, const char*> kRootKeys[] = {
      {"bookmark_bar", "Bookmarks bar"},
      {"other", "Other bookmarks"},
      {"synced", "Mobile bookmarks"},
  };
  for (const auto& [key, label] : kRootKeys) {
    const auto* r = roots->FindDict(key);
    if (!r) continue;
    if (auto node = parse_node(parse_node, r, 0)) {
      if (node->source_id.empty()) node->source_id = key;
      node->title = label;
      out_roots->push_back(std::move(*node));
    }
  }
  if (out_report) *out_report = report;
  return true;
}

// static
bool BrowserImporter::ReadChromiumHistory(
    const base::FilePath& profile_dir,
    HistoryBatchCallback on_batch,
    ImportHistoryBatchReport* out_report,
    size_t batch_size) {
  SafeSqliteTempCopy copy;
  if (!copy.Open(profile_dir.AppendASCII("History"))) {
    return false;
  }

  ImportHistoryBatchReport report;
  size_t limit = std::clamp<size_t>(batch_size, 1, 5000);

  struct UrlMeta {
    std::string url;
    std::string title;
    int visit_count = 1;
    int typed_count = 0;
  };
  std::map<int64_t, UrlMeta> urls;
  {
    sql::Statement st(copy.db().GetUniqueStatement(
        "SELECT id, url, title, visit_count, typed_count FROM urls"));
    while (st.Step()) {
      ++report.source_url_rows;
      urls[st.ColumnInt64(0)] =
          UrlMeta{st.ColumnString(1), st.ColumnString(2), st.ColumnInt(3),
                  st.ColumnInt(4)};
    }
  }

  std::set<std::string> dedupe_keys;
  std::vector<HistoryEntry> batch;
  batch.reserve(limit);

  sql::Statement visits(copy.db().GetUniqueStatement(
      "SELECT id, url, visit_time, transition FROM visits "
      "ORDER BY visit_time ASC, id ASC"));
  while (visits.Step()) {
    ++report.source_visit_rows;
    int64_t visit_id = visits.ColumnInt64(0);
    int64_t url_id = visits.ColumnInt64(1);
    int64_t visit_time = visits.ColumnInt64(2);
    int core_transition = static_cast<int>(visits.ColumnInt64(3) & 0xFF);

    auto uit = urls.find(url_id);
    if (uit == urls.end() || !IsSupportedImportScheme(uit->second.url)) {
      ++report.skipped_internal;
      continue;
    }
    if (core_transition == 3 || core_transition == 4) {
      ++report.skipped_subframe;
      continue;
    }
    auto unix_sec = ChromiumTimeMicrosToUnix(visit_time);
    if (!unix_sec) {
      ++report.skipped_invalid_time;
      continue;
    }

    std::string dkey = uit->second.url + "|" +
                       base::NumberToString(static_cast<int64_t>(*unix_sec));
    if (!dedupe_keys.insert(dkey).second) {
      ++report.deduped_visits;
      continue;
    }

    HistoryEntry entry;
    entry.id = visit_id;
    entry.url = uit->second.url;
    entry.title = uit->second.title;
    entry.visit_count = std::max(1, uit->second.visit_count);
    entry.typed_count =
        std::max(uit->second.typed_count, core_transition == 1 ? 1 : 0);
    entry.last_visit = *unix_sec;
    batch.push_back(std::move(entry));
    ++report.kept_visits;

    if (batch.size() >= limit) {
      if (on_batch) on_batch.Run(batch);
      batch.clear();
    }
  }
  if (!batch.empty() && on_batch) {
    on_batch.Run(batch);
  }
  if (out_report) *out_report = report;
  return true;
}

// ============================================================================
// Firefox / Gecko
// ============================================================================

// static
std::vector<DetectedBrowserProfile> BrowserImporter::ProbeFirefoxProfiles(
    const base::FilePath& firefox_root) {
  std::vector<DetectedBrowserProfile> out;
  std::string ini_raw;
  if (!base::ReadFileToStringWithMaxSize(
          firefox_root.AppendASCII("profiles.ini"), &ini_raw, 1024 * 1024)) {
    return out;
  }

  std::set<std::string> install_defaults;
  std::string installs_raw;
  if (base::ReadFileToStringWithMaxSize(
          firefox_root.AppendASCII("installs.ini"), &installs_raw,
          1024 * 1024)) {
    for (const auto& [section, kv] : ParseIniSections(installs_raw)) {
      if (base::StartsWith(section, "Install",
                           base::CompareCase::INSENSITIVE_ASCII)) {
        auto it = kv.find("Default");
        if (it != kv.end()) install_defaults.insert(it->second);
      }
    }
  }

  auto sections = ParseIniSections(ini_raw);
  for (const auto& [section, kv] : sections) {
    if (base::StartsWith(section, "Install")) {
      auto it = kv.find("Default");
      if (it != kv.end()) install_defaults.insert(it->second);
    }
  }

  for (const auto& [section, kv] : sections) {
    if (!base::StartsWith(section, "Profile")) continue;
    auto path_it = kv.find("Path");
    if (path_it == kv.end() || path_it->second.empty()) continue;
    bool is_relative = true;
    if (auto rel_it = kv.find("IsRelative"); rel_it != kv.end()) {
      is_relative = (rel_it->second != "0");
    }
    base::FilePath dir =
        is_relative
            ? firefox_root.Append(base::FilePath::FromUTF8Unsafe(path_it->second))
            : base::FilePath::FromUTF8Unsafe(path_it->second);
    if (!base::DirectoryExists(dir) ||
        !base::PathExists(dir.AppendASCII("places.sqlite"))) {
      continue;
    }
    DetectedBrowserProfile p;
    p.id = dir.BaseName().AsUTF8Unsafe();
    auto name_it = kv.find("Name");
    p.name = (name_it != kv.end() && !name_it->second.empty()) ? name_it->second
                                                               : p.id;
    p.directory = dir;
    p.is_default = install_defaults.empty()
                       ? (kv.find("Default") != kv.end() &&
                          kv.at("Default") == "1")
                       : install_defaults.contains(path_it->second);
    EstimateFirefoxCounts(dir, &p.bookmark_count, &p.history_count);
    out.push_back(std::move(p));
    if (out.size() >= 100) break;
  }

  std::stable_sort(out.begin(), out.end(),
                   [](const DetectedBrowserProfile& a,
                      const DetectedBrowserProfile& b) {
                     return a.is_default && !b.is_default;
                   });
  return out;
}

// static
bool BrowserImporter::ReadFirefoxBookmarks(
    const base::FilePath& profile_dir,
    std::vector<ImportedBookmarkNode>* out_roots,
    ImportBookmarksReport* out_report) {
  if (!out_roots) return false;
  out_roots->clear();
  ImportBookmarksReport report;

  SafeSqliteTempCopy copy;
  if (!copy.Open(profile_dir.AppendASCII("places.sqlite"))) {
    return false;
  }

  {
    sql::Statement ver(copy.db().GetUniqueStatement("PRAGMA user_version"));
    if (!ver.Step()) return false;
    int v = ver.ColumnInt(0);
    if (v < 43 || v > 120) return false;
  }

  struct Row {
    int64_t id = 0;
    int type = 0;
    int64_t parent = 0;
    std::string title;
    std::string guid;
    int64_t added = 0;
    std::optional<std::string> url;
  };
  std::map<int64_t, Row> rows;
  std::map<int64_t, std::vector<int64_t>> children;
  std::optional<int64_t> root_id;

  {
    sql::Statement st(copy.db().GetUniqueStatement(
        "SELECT b.id, b.type, b.parent, b.title, b.guid, b.dateAdded, p.url "
        "FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk "
        "ORDER BY b.parent, b.position, b.id"));
    while (st.Step()) {
      Row r;
      r.id = st.ColumnInt64(0);
      r.type = st.ColumnInt(1);
      r.parent = st.ColumnInt64(2);
      r.title = st.ColumnString(3);
      r.guid = st.ColumnString(4);
      r.added = st.ColumnInt64(5);
      if (st.GetColumnType(6) != sql::ColumnType::kNull) {
        r.url = st.ColumnString(6);
      }
      if (r.guid == "root________") {
        root_id = r.id;
      } else {
        children[r.parent].push_back(r.id);
      }
      rows[r.id] = std::move(r);
    }
  }

  if (!root_id) return false;

  auto build = [&](auto& self, int64_t id,
                   std::optional<std::string> title_override,
                   int depth) -> std::optional<ImportedBookmarkNode> {
    if (depth >= kMaxBookmarkDepth) return std::nullopt;
    auto it = rows.find(id);
    if (it == rows.end()) return std::nullopt;
    const Row& r = it->second;
    std::string sid = r.guid.empty() ? base::NumberToString(r.id) : r.guid;

    if (r.type == 1) {
      if (!r.url || !IsSupportedImportScheme(*r.url)) {
        ++report.skipped;
        return std::nullopt;
      }
      ImportedBookmarkNode u;
      u.is_folder = false;
      u.source_id = sid;
      u.title = r.title;
      u.url = *r.url;
      if (r.added > 0) {
        u.date_added =
            ValidateImportUnixSeconds(static_cast<double>(r.added) / 1000000.0);
      }
      ++report.urls;
      return u;
    }
    if (r.type == 2) {
      ImportedBookmarkNode f;
      f.is_folder = true;
      f.source_id = sid;
      f.title = title_override.value_or(r.title);
      for (int64_t cid : children[id]) {
        if (auto child = self(self, cid, std::nullopt, depth + 1)) {
          f.children.push_back(std::move(*child));
        }
      }
      if (f.children.empty()) {
        ++report.skipped;
        return std::nullopt;
      }
      ++report.folders;
      return f;
    }
    ++report.skipped;
    return std::nullopt;
  };

  static constexpr std::pair<const char*, const char*> kGeckoRoots[] = {
      {"toolbar_____", "Bookmarks Toolbar"},
      {"menu________", "Bookmarks Menu"},
      {"unfiled_____", "Other Bookmarks"},
      {"mobile______", "Mobile Bookmarks"},
  };
  for (const auto& [guid, label] : kGeckoRoots) {
    for (int64_t top_id : children[*root_id]) {
      auto it = rows.find(top_id);
      if (it != rows.end() && it->second.guid == guid) {
        if (auto root = build(build, top_id, std::string(label), 0)) {
          out_roots->push_back(std::move(*root));
        }
        break;
      }
    }
  }
  if (out_report) *out_report = report;
  return true;
}

// static
bool BrowserImporter::ReadFirefoxHistory(
    const base::FilePath& profile_dir,
    HistoryBatchCallback on_batch,
    ImportHistoryBatchReport* out_report,
    size_t batch_size) {
  SafeSqliteTempCopy copy;
  if (!copy.Open(profile_dir.AppendASCII("places.sqlite"))) {
    return false;
  }

  ImportHistoryBatchReport report;
  size_t limit = std::clamp<size_t>(batch_size, 1, 5000);
  {
    sql::Statement cnt(
        copy.db().GetUniqueStatement("SELECT COUNT(*) FROM moz_places"));
    if (cnt.Step()) {
      report.source_url_rows = static_cast<size_t>(cnt.ColumnInt64(0));
    }
  }

  std::set<std::string> dedupe_keys;
  std::vector<HistoryEntry> batch;
  batch.reserve(limit);

  sql::Statement st(copy.db().GetUniqueStatement(
      "SELECT v.id, p.url, p.title, v.visit_date, v.visit_type, p.visit_count "
      "FROM moz_historyvisits v LEFT JOIN moz_places p ON p.id = v.place_id "
      "ORDER BY v.visit_date ASC, v.id ASC"));
  while (st.Step()) {
    ++report.source_visit_rows;
    int visit_type = st.ColumnInt(4);
    if (st.GetColumnType(1) == sql::ColumnType::kNull || visit_type == 7) {
      ++report.skipped_internal;
      continue;
    }
    std::string url = st.ColumnString(1);
    if (!IsSupportedImportScheme(url)) {
      ++report.skipped_internal;
      continue;
    }
    if (visit_type == 4 || visit_type == 8) {
      ++report.skipped_subframe;
      continue;
    }
    auto unix_sec = ValidateImportUnixSeconds(
        static_cast<double>(st.ColumnInt64(3)) / 1000000.0);
    if (!unix_sec) {
      ++report.skipped_invalid_time;
      continue;
    }

    std::string dkey =
        url + "|" + base::NumberToString(static_cast<int64_t>(*unix_sec));
    if (!dedupe_keys.insert(dkey).second) {
      ++report.deduped_visits;
      continue;
    }

    HistoryEntry entry;
    entry.id = st.ColumnInt64(0);
    entry.url = std::move(url);
    entry.title = st.ColumnString(2);
    entry.visit_count = std::max(1, st.ColumnInt(5));
    entry.typed_count = (visit_type == 2) ? 1 : 0;
    entry.last_visit = *unix_sec;
    batch.push_back(std::move(entry));
    ++report.kept_visits;

    if (batch.size() >= limit) {
      if (on_batch) on_batch.Run(batch);
      batch.clear();
    }
  }
  if (!batch.empty() && on_batch) {
    on_batch.Run(batch);
  }
  if (out_report) *out_report = report;
  return true;
}

// ============================================================================
// Safari Bookmarks.plist & History.db (macOS TCC aware, pure C++)
// ============================================================================

// static
bool BrowserImporter::ReadSafariBookmarks(
    const base::FilePath& safari_dir,
    std::vector<ImportedBookmarkNode>* out_roots,
    ImportBookmarksReport* out_report,
    SafariImportErrorInfo* out_error) {
  if (!out_roots) return false;
  out_roots->clear();
  if (out_error) *out_error = SafariImportErrorInfo{};

  const SafariAccessStatus access = CheckSafariAccess(safari_dir);
  if (access == SafariAccessStatus::kPermissionDenied) {
    if (out_error) {
      out_error->permission_denied = true;
      out_error->error_code = "permission_denied";
      out_error->error_message =
          "Full Disk Access required to read Safari data";
    }
    return false;
  }
  if (access == SafariAccessStatus::kNotFound) {
    if (out_error) {
      out_error->error_code = "not_found";
      out_error->error_message = "Safari Bookmarks.plist not found";
    }
    return false;
  }

  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(
          safari_dir.AppendASCII("Bookmarks.plist"), &raw, kMaxPlistBytes)) {
    if (out_error) {
      out_error->error_code = "unreadable";
      out_error->error_message = "Could not read Safari Bookmarks.plist";
    }
    return false;
  }

  auto parsed = ParsePlist(raw);
  const base::DictValue* root = parsed ? parsed->GetIfDict() : nullptr;
  if (!root) {
    if (out_error) {
      out_error->error_code = "malformed";
      out_error->error_message = "Safari Bookmarks.plist is malformed";
    }
    return false;
  }

  ImportBookmarksReport report;
  size_t total_nodes = 0;

  auto map_special_title = [](const std::string& raw_title) -> std::string {
    if (raw_title == "BookmarksBar") return "Favorites";
    if (raw_title == "BookmarksMenu") return "Bookmarks Menu";
    if (raw_title == "com.apple.ReadingList") return "Reading List";
    return raw_title.empty() ? "Folder" : raw_title;
  };

  auto parse_node = [&](auto& self, const base::DictValue* dict,
                        const std::string& path,
                        int depth) -> std::optional<ImportedBookmarkNode> {
    if (!dict || depth >= kMaxBookmarkDepth ||
        ++total_nodes > kMaxBookmarkNodes) {
      ++report.skipped;
      return std::nullopt;
    }
    const std::string* btype = dict->FindString("WebBookmarkType");
    if (!btype) {
      ++report.skipped;
      return std::nullopt;
    }
    const std::string sid = dict->FindString("WebBookmarkUUID")
                                ? *dict->FindString("WebBookmarkUUID")
                                : path;

    if (*btype == "WebBookmarkTypeLeaf") {
      const std::string* url_str = dict->FindString("URLString");
      if (!url_str || !IsSupportedImportScheme(*url_str)) {
        ++report.skipped;
        return std::nullopt;
      }
      std::string title;
      if (const auto* uri_dict = dict->FindDict("URIDictionary")) {
        if (const auto* t = uri_dict->FindString("title")) title = *t;
      }
      if (title.empty()) title = *url_str;
      ImportedBookmarkNode u;
      u.is_folder = false;
      u.source_id = sid;
      u.title = std::move(title);
      u.url = *url_str;
      ++report.urls;
      return u;
    }

    if (*btype == "WebBookmarkTypeList") {
      ImportedBookmarkNode f;
      f.is_folder = true;
      f.source_id = sid;
      const std::string* raw_title = dict->FindString("Title");
      f.title = map_special_title(raw_title ? *raw_title : "");
      if (const auto* kids = dict->FindList("Children")) {
        size_t idx = 0;
        for (const auto& k : *kids) {
          if (auto child = self(self, k.GetIfDict(),
                                path + "/" + base::NumberToString(idx++),
                                depth + 1)) {
            f.children.push_back(std::move(*child));
          }
        }
      }
      if (f.children.empty()) {
        ++report.skipped;
        return std::nullopt;
      }
      ++report.folders;
      return f;
    }

    // WebBookmarkTypeProxy (History proxy) and unknown entries.
    ++report.skipped;
    return std::nullopt;
  };

  if (const auto* top = root->FindList("Children")) {
    size_t idx = 0;
    for (const auto& child : *top) {
      if (auto n = parse_node(parse_node, child.GetIfDict(),
                              base::NumberToString(idx++), 0)) {
        out_roots->push_back(std::move(*n));
      }
    }
  }

  // Place Favorites first, matching Safari's order.
  std::stable_sort(
      out_roots->begin(), out_roots->end(),
      [](const ImportedBookmarkNode& a, const ImportedBookmarkNode& b) {
        const bool a_fav = a.is_folder && a.title == "Favorites";
        const bool b_fav = b.is_folder && b.title == "Favorites";
        return a_fav && !b_fav;
      });

  if (out_report) *out_report = report;
  return true;
}

// static
bool BrowserImporter::ReadSafariHistory(
    const base::FilePath& safari_dir,
    HistoryBatchCallback on_batch,
    ImportHistoryBatchReport* out_report,
    SafariImportErrorInfo* out_error,
    size_t batch_size) {
  if (out_error) *out_error = SafariImportErrorInfo{};

  const SafariAccessStatus access = CheckSafariAccess(safari_dir);
  if (access == SafariAccessStatus::kPermissionDenied) {
    if (out_error) {
      out_error->permission_denied = true;
      out_error->error_code = "permission_denied";
      out_error->error_message =
          "Full Disk Access required to read Safari data";
    }
    return false;
  }

  base::FilePath history_db = safari_dir.AppendASCII("History.db");
  if (!base::PathExists(history_db)) {
    if (out_error) {
      out_error->error_code = "not_found";
      out_error->error_message = "Safari History.db not found";
    }
    return false;
  }

  SafeSqliteTempCopy copy;
  if (!copy.Open(history_db)) {
    if (out_error) {
      out_error->error_code = "unreadable";
      out_error->error_message = "Could not open Safari History.db";
    }
    return false;
  }

  ImportHistoryBatchReport report;
  size_t limit = std::clamp<size_t>(batch_size, 1, 5000);
  {
    sql::Statement cnt(
        copy.db().GetUniqueStatement("SELECT COUNT(*) FROM history_items"));
    if (cnt.Step()) {
      report.source_url_rows = static_cast<size_t>(cnt.ColumnInt64(0));
    }
  }

  std::set<std::string> dedupe_keys;
  std::vector<HistoryEntry> batch;
  batch.reserve(limit);

  sql::Statement st(copy.db().GetUniqueStatement(
      "SELECT v.id, i.url, v.title, v.visit_time, i.visit_count "
      "FROM history_visits v "
      "LEFT JOIN history_items i ON i.id = v.history_item "
      "ORDER BY v.visit_time ASC, v.id ASC"));
  while (st.Step()) {
    ++report.source_visit_rows;
    if (st.GetColumnType(1) == sql::ColumnType::kNull) {
      ++report.skipped_internal;
      continue;
    }
    std::string url = st.ColumnString(1);
    if (!IsSupportedImportScheme(url)) {
      ++report.skipped_internal;
      continue;
    }
    auto unix_sec = ValidateImportUnixSeconds(st.ColumnDouble(3) +
                                              kApple2001EpochOffsetSec);
    if (!unix_sec) {
      ++report.skipped_invalid_time;
      continue;
    }

    std::string dkey =
        url + "|" + base::NumberToString(static_cast<int64_t>(*unix_sec));
    if (!dedupe_keys.insert(dkey).second) {
      ++report.deduped_visits;
      continue;
    }

    HistoryEntry entry;
    entry.id = st.ColumnInt64(0);
    entry.url = std::move(url);
    entry.title = st.ColumnString(2);
    entry.visit_count = std::max(1, st.ColumnInt(4));
    entry.typed_count = 0;
    entry.last_visit = *unix_sec;
    batch.push_back(std::move(entry));
    ++report.kept_visits;

    if (batch.size() >= limit) {
      if (on_batch) on_batch.Run(batch);
      batch.clear();
    }
  }
  if (!batch.empty() && on_batch) {
    on_batch.Run(batch);
  }
  if (out_report) *out_report = report;
  return true;
}

// ============================================================================
// Netscape HTML Bookmarks
// ============================================================================

// static
bool BrowserImporter::ParseBookmarksHtml(
    std::string_view html_bytes,
    std::vector<ImportedBookmarkNode>* out_roots,
    ImportBookmarksReport* out_report) {
  if (!out_roots || html_bytes.size() > kMaxJsonBytes) return false;
  out_roots->clear();
  if (FindCaseInsensitive(html_bytes, "<dl") == std::string_view::npos) {
    return false;
  }

  struct Frame {
    std::string id;
    std::string title;
    std::vector<ImportedBookmarkNode> children;
  };
  std::vector<Frame> stack;
  stack.push_back(Frame{"html", "", {}});
  ImportBookmarksReport report;
  std::optional<std::string> pending_folder;
  bool saw_first_dl = false;
  size_t total_nodes = 0;

  size_t pos = 0;
  while (pos < html_bytes.size() && total_nodes < kMaxBookmarkNodes) {
    size_t open = html_bytes.find('<', pos);
    if (open == std::string_view::npos) break;
    size_t close = html_bytes.find('>', open + 1);
    if (close == std::string_view::npos) break;

    std::string_view tag = html_bytes.substr(open + 1, close - open - 1);
    size_t name_end = 0;
    while (name_end < tag.size() && !base::IsAsciiWhitespace(tag[name_end])) {
      ++name_end;
    }
    std::string tag_name = base::ToUpperASCII(tag.substr(0, name_end));
    pos = close + 1;

    if (tag_name == "H3") {
      size_t end = FindCaseInsensitive(html_bytes, "</h3", pos);
      if (end == std::string_view::npos) end = html_bytes.size();
      pending_folder = DecodeHtmlEntities(html_bytes.substr(pos, end - pos));
      pos = end;
    } else if (tag_name == "DL") {
      if (!saw_first_dl && !pending_folder.has_value()) {
        saw_first_dl = true;
        continue;
      }
      saw_first_dl = true;
      if (static_cast<int>(stack.size()) >= kMaxBookmarkDepth) {
        pending_folder.reset();
        continue;
      }
      const Frame& parent = stack.back();
      std::string title = pending_folder.value_or("");
      std::string fid = parent.id + "/" +
                        base::NumberToString(parent.children.size()) + ":" +
                        title;
      stack.push_back(Frame{std::move(fid), std::move(title), {}});
      pending_folder.reset();
    } else if (tag_name == "/DL") {
      pending_folder.reset();
      if (stack.size() <= 1) continue;
      Frame done = std::move(stack.back());
      stack.pop_back();
      if (done.children.empty()) {
        ++report.skipped;
      } else {
        ++report.folders;
        ++total_nodes;
        ImportedBookmarkNode f;
        f.is_folder = true;
        f.source_id = std::move(done.id);
        f.title = std::move(done.title);
        f.children = std::move(done.children);
        stack.back().children.push_back(std::move(f));
      }
    } else if (tag_name == "A") {
      pending_folder.reset();
      size_t end = FindCaseInsensitive(html_bytes, "</a", pos);
      if (end == std::string_view::npos) end = html_bytes.size();
      std::string title = DecodeHtmlEntities(html_bytes.substr(pos, end - pos));
      pos = end;

      auto href = ExtractHtmlAttribute(tag, "HREF");
      if (!href || !IsSupportedImportScheme(*href)) {
        ++report.skipped;
        continue;
      }
      ImportedBookmarkNode u;
      u.is_folder = false;
      u.source_id = stack.back().id + "/" +
                    base::NumberToString(stack.back().children.size());
      u.title = title.empty() ? *href : title;
      u.url = *href;
      if (auto added_str = ExtractHtmlAttribute(tag, "ADD_DATE")) {
        double secs = 0.0;
        if (base::StringToDouble(*added_str, &secs)) {
          u.date_added = ValidateImportUnixSeconds(secs);
        }
      }
      stack.back().children.push_back(std::move(u));
      ++report.urls;
      ++total_nodes;
    } else if (tag_name == "HR") {
      ++report.skipped;
    }
  }

  while (stack.size() > 1) {
    Frame done = std::move(stack.back());
    stack.pop_back();
    if (!done.children.empty()) {
      ++report.folders;
      ImportedBookmarkNode f;
      f.is_folder = true;
      f.source_id = std::move(done.id);
      f.title = std::move(done.title);
      f.children = std::move(done.children);
      stack.back().children.push_back(std::move(f));
    }
  }

  *out_roots = std::move(stack.front().children);
  if (out_report) *out_report = report;
  return true;
}

// static
bool BrowserImporter::ReadBookmarksHtmlFile(
    const base::FilePath& html_path,
    std::vector<ImportedBookmarkNode>* out_roots,
    ImportBookmarksReport* out_report) {
  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(html_path, &raw, kMaxJsonBytes)) {
    return false;
  }
  return ParseBookmarksHtml(raw, out_roots, out_report);
}

// ============================================================================
// Arc Full Importer (Sidebar, Archive, Boosts, Easels, Notes, History)
// ============================================================================

// static
ArcSidebarImportResult BrowserImporter::ImportArcDirectory(
    const base::FilePath& arc_data_dir,
    bool include_archive) {
  ArcImportOptions opts;
  opts.include_archive = include_archive;
  return ImportArcDirectory(arc_data_dir, opts);
}

// static
ArcSidebarImportResult BrowserImporter::ImportArcDirectory(
    const base::FilePath& arc_data_dir,
    const ArcImportOptions& options) {
  ArcSidebarImportResult result;

  std::string sidebar_raw;
  if (!base::ReadFileToStringWithMaxSize(
          arc_data_dir.AppendASCII("StorableSidebar.json"), &sidebar_raw,
          kMaxJsonBytes)) {
    result.error_message = "Missing or unreadable StorableSidebar.json";
    return result;
  }
  auto root = base::JSONReader::ReadDict(sidebar_raw, base::JSON_PARSE_RFC);
  const auto* sidebar = root ? root->FindDict("sidebar") : nullptr;
  const auto* containers = sidebar ? sidebar->FindList("containers") : nullptr;
  if (!containers || containers->empty() || (containers->size() % 2) != 0) {
    result.error_message = "Malformed StorableSidebar.json containers";
    return result;
  }

  const base::DictValue* holder = nullptr;
  for (size_t i = 0; i + 1 < containers->size(); i += 2) {
    const auto* key = (*containers)[i].GetIfDict();
    if (!key || key->size() != 1) continue;
    const auto* global_marker = key->FindDict("global");
    if (global_marker && global_marker->empty()) {
      holder = (*containers)[i + 1].GetIfDict();
      break;
    }
  }
  if (!holder) {
    result.error_message = "Missing global sidebar container";
    return result;
  }

  const auto* items_arr = holder->FindList("items");
  const auto* spaces_arr = holder->FindList("spaces");
  if (!items_arr || !spaces_arr) {
    result.error_message = "Missing items or spaces in StorableSidebar.json";
    return result;
  }

  std::map<std::string, const base::DictValue*> items_by_id;
  for (size_t i = 0; i + 1 < items_arr->size(); i += 2) {
    if ((*items_arr)[i].is_string() && (*items_arr)[i + 1].is_dict()) {
      items_by_id[(*items_arr)[i].GetString()] = &(*items_arr)[i + 1].GetDict();
    }
  }

  auto extract_profile_key = [](const base::Value* raw) -> std::string {
    if (!raw) return "default";
    if (raw->is_string()) return raw->GetString();
    const auto* obj = raw->GetIfDict();
    if (!obj) return "default";
    if (obj->FindBool("default").value_or(false)) return "default";
    if (const auto* custom = obj->FindDict("custom")) {
      if (const auto* inner = custom->FindDict("_0")) {
        if (const auto* dir = inner->FindString("directoryBasename");
            dir && IsSafeDirBasename(*dir)) {
          return *dir;
        }
      }
    }
    return "default";
  };

  std::map<std::string, Profile> profiles_by_key;
  auto ensure_profile = [&](const std::string& key) -> ProfileID {
    std::string canon = (key == "Default" || key.empty()) ? "default" : key;
    auto it = profiles_by_key.find(canon);
    if (it != profiles_by_key.end()) return it->second.id;
    Profile p;
    p.id = DeterministicUuid("profile", canon);
    p.name = (canon == "default") ? "Default" : canon;
    p.data_directory_name = (canon == "default") ? "Default" : canon;
    ProfileID id = p.id;
    profiles_by_key[canon] = std::move(p);
    return id;
  };
  const ProfileID default_profile_id = ensure_profile("default");

  std::set<std::string> placed;
  std::set<std::string> building;
  std::set<std::string> live_arc_ids;

  auto decode_icon = [](const base::DictValue* info) -> std::optional<SpaceIcon> {
    if (!info) return std::nullopt;
    const auto* icon_type = info->FindDict("iconType");
    if (!icon_type) return std::nullopt;
    if (const auto* emoji = icon_type->FindString("emoji_v2");
        emoji && !emoji->empty()) {
      return SpaceIcon{SpaceIconKind::kEmoji, *emoji};
    }
    if (const auto* named = icon_type->FindString("icon");
        named && !named->empty()) {
      return SpaceIcon{SpaceIconKind::kNamed, *named};
    }
    return std::nullopt;
  };

  auto decode_theme = [](const base::DictValue* info) -> SpaceTheme {
    SpaceTheme theme;
    if (!info) return theme;
    const auto* wt = info->FindDict("windowTheme");
    if (!wt) return theme;
    std::string raw_wt;
    if (base::JSONWriter::Write(*wt, &raw_wt)) {
      theme.imported_arc_theme_json = std::move(raw_wt);
    }
    const auto* sem = wt->FindDict("semanticColorPalette");
    const auto* app = sem ? sem->FindDict("appearanceBased") : nullptr;
    auto read_color = [](const base::DictValue* set,
                         const char* key) -> std::optional<RGBAColor> {
      const auto* c = set ? set->FindDict(key) : nullptr;
      if (!c) return std::nullopt;
      return RGBAColor{c->FindDouble("red").value_or(0.0),
                       c->FindDouble("green").value_or(0.0),
                       c->FindDouble("blue").value_or(0.0),
                       c->FindDouble("alpha").value_or(1.0)};
    };
    if (app) {
      const auto* light = app->FindDict("light");
      const auto* dark = app->FindDict("dark");
      theme.light_background = read_color(light, "backgroundExtra");
      if (!theme.light_background) {
        theme.light_background = read_color(light, "cutoutColor");
      }
      theme.dark_background = read_color(dark, "backgroundExtra");
      if (!theme.dark_background) {
        theme.dark_background = read_color(dark, "cutoutColor");
      }
      theme.light_foreground = read_color(light, "foregroundPrimary");
      theme.dark_foreground = read_color(dark, "foregroundPrimary");
    }
    return theme;
  };

  auto build_node = [&](auto& self,
                        const std::string& arc_id) -> std::optional<SidebarNode> {
    auto it = items_by_id.find(arc_id);
    if (it == items_by_id.end() || !building.insert(arc_id).second) {
      return std::nullopt;
    }
    const base::DictValue& item = *it->second;
    const auto* data = item.FindDict("data");
    if (!data) {
      building.erase(arc_id);
      return std::nullopt;
    }

    std::optional<SidebarNode> built;
    if (const auto* td = data->FindDict("tab")) {
      Tab t;
      t.id = DeterministicUuid("item", arc_id);
      t.url = td->FindString("savedURL") ? *td->FindString("savedURL")
                                         : "about:blank";
      t.title = td->FindString("savedTitle") ? *td->FindString("savedTitle") : "";
      if (const auto* item_title = item.FindString("title");
          item_title && *item_title != t.title) {
        t.custom_title = *item_title;
      }
      t.icon_override = decode_icon(td->FindDict("customInfo"));
      t.created_at =
          item.FindDouble("createdAt").value_or(0.0) + kApple2001EpochOffsetSec;
      t.last_active_at =
          td->FindDouble("timeLastActiveAt")
              .value_or(item.FindDouble("createdAt").value_or(0.0)) +
          kApple2001EpochOffsetSec;
      if (const auto* mute = td->FindString("savedMuteStatus");
          mute && *mute == "mute") {
        t.is_muted = true;
      }
      t.is_unread = item.FindBool("isUnread").value_or(false);
      live_arc_ids.insert(arc_id);
      ++result.imported_tabs;
      built = SidebarNode(std::move(t));
    } else if (const auto* adoc = data->FindDict("arcDocument")) {
      const std::string* doc_id = adoc->FindString("arcDocumentID");
      if (doc_id && !doc_id->empty()) {
        Tab t;
        t.id = DeterministicUuid("item", arc_id);
        t.url = "open://note/" + DeterministicUuid("note", *doc_id);
        t.title = item.FindString("title") ? *item.FindString("title") : "Note";
        t.created_at =
            item.FindDouble("createdAt").value_or(0.0) + kApple2001EpochOffsetSec;
        t.last_active_at = t.created_at;
        live_arc_ids.insert(arc_id);
        ++result.imported_tabs;
        built = SidebarNode(std::move(t));
      }
    } else if (const auto* edoc = data->FindDict("easel")) {
      const std::string* eid = edoc->FindString("easelID");
      if (!eid) eid = edoc->FindString("id");
      std::string target_id =
          (eid && !eid->empty()) ? DeterministicUuid("easel", *eid)
                                 : DeterministicUuid("easel", arc_id);
      Tab t;
      t.id = DeterministicUuid("item", arc_id);
      t.url = "open://easel/" + target_id;
      t.title = item.FindString("title") ? *item.FindString("title") : "Easel";
      t.created_at =
          item.FindDouble("createdAt").value_or(0.0) + kApple2001EpochOffsetSec;
      t.last_active_at = t.created_at;
      live_arc_ids.insert(arc_id);
      ++result.imported_tabs;
      built = SidebarNode(std::move(t));
    } else if (data->FindDict("list")) {
      Folder f;
      f.id = DeterministicUuid("item", arc_id);
      f.title = item.FindString("title") ? *item.FindString("title") : "Folder";
      if (const auto* kids = item.FindList("childrenIds")) {
        for (const auto& k : *kids) {
          if (!k.is_string()) continue;
          const std::string& cid = k.GetString();
          if (placed.contains(cid)) continue;
          if (auto child = self(self, cid)) {
            placed.insert(cid);
            f.children.push_back(std::move(*child));
          }
        }
      }
      live_arc_ids.insert(arc_id);
      ++result.imported_folders;
      built = SidebarNode(std::move(f));
    } else if (const auto* sd = data->FindDict("splitView")) {
      Split s;
      s.id = DeterministicUuid("item", arc_id);
      if (const auto* orient = sd->FindString("layoutOrientation");
          orient && *orient == "vertical") {
        s.orientation = SplitOrientation::kVertical;
      }
      if (const auto* kids = item.FindList("childrenIds")) {
        for (const auto& k : *kids) {
          if (!k.is_string() || s.panes.size() >= 4) continue;
          const std::string& cid = k.GetString();
          if (placed.contains(cid)) continue;
          if (auto child = self(self, cid); child && child->as_tab()) {
            placed.insert(cid);
            s.panes.push_back(std::move(*child->as_tab()));
          }
        }
      }
      if (s.panes.size() >= 2) {
        if (const auto* factors = sd->FindList("itemWidthFactors");
            factors && factors->size() == s.panes.size()) {
          double sum = 0.0;
          std::vector<double> vals;
          for (const auto& fv : *factors) {
            double d = fv.GetIfDouble().value_or(0.0);
            if (std::isfinite(d) && d > 0.0) {
              vals.push_back(d);
              sum += d;
            }
          }
          if (vals.size() == s.panes.size() && sum > 0.0) {
            for (double v : vals) s.fractions.push_back(v / sum);
          }
        }
        s.focused_pane_id = s.panes.front().id;
        live_arc_ids.insert(arc_id);
        ++result.imported_splits;
        built = SidebarNode(std::move(s));
      } else if (s.panes.size() == 1) {
        built = SidebarNode(std::move(s.panes.front()));
      }
    }
    building.erase(arc_id);
    return built;
  };

  // Top Apps (Favorites) per profile.
  if (const auto* top_apps = holder->FindList("topAppsContainerIDs")) {
    for (size_t i = 0; i + 1 < top_apps->size(); i += 2) {
      std::string pkey = extract_profile_key(&(*top_apps)[i]);
      ensure_profile(pkey);
      if (!(*top_apps)[i + 1].is_string()) continue;
      auto container_it = items_by_id.find((*top_apps)[i + 1].GetString());
      if (container_it == items_by_id.end()) continue;
      const auto* kids = container_it->second->FindList("childrenIds");
      if (!kids) continue;
      Profile& prof =
          profiles_by_key[(pkey == "Default" || pkey.empty()) ? "default"
                                                              : pkey];
      for (const auto& k : *kids) {
        if (!k.is_string()) continue;
        const std::string& cid = k.GetString();
        if (placed.contains(cid)) continue;
        if (auto n = build_node(build_node, cid); n && n->as_tab()) {
          placed.insert(cid);
          Tab fav = std::move(*n->as_tab());
          if (!fav.pinned_url && !fav.url.empty()) fav.pinned_url = fav.url;
          prof.favorites.push_back(std::move(fav));
        }
      }
    }
  }

  // Spaces and their pinned/unpinned containers (preserving nested folders).
  std::set<SpaceID> seen_spaces;
  for (size_t i = 0; i + 1 < spaces_arr->size(); i += 2) {
    if (!(*spaces_arr)[i].is_string() || !(*spaces_arr)[i + 1].is_dict()) {
      continue;
    }
    const std::string& arc_space_id = (*spaces_arr)[i].GetString();
    const base::DictValue& sobj = (*spaces_arr)[i + 1].GetDict();
    SpaceID sid = DeterministicUuid("space", arc_space_id);
    if (!seen_spaces.insert(sid).second) continue;

    Space space;
    space.id = sid;
    if (const auto* title = sobj.FindString("title");
        title && !title->empty()) {
      space.title = *title;
    }
    const auto* custom_info = sobj.FindDict("customInfo");
    space.icon = decode_icon(custom_info);
    space.theme = decode_theme(custom_info);
    space.profile_id = ensure_profile(extract_profile_key(sobj.Find("profile")));

    if (const auto* container_ids = sobj.FindList("containerIDs")) {
      for (size_t j = 0; j + 1 < container_ids->size(); j += 2) {
        if (!(*container_ids)[j].is_string() ||
            !(*container_ids)[j + 1].is_string()) {
          continue;
        }
        const std::string& role = (*container_ids)[j].GetString();
        const std::string& cid = (*container_ids)[j + 1].GetString();
        auto cit = items_by_id.find(cid);
        if (cit == items_by_id.end()) continue;
        const auto* kids = cit->second->FindList("childrenIds");
        if (!kids) continue;

        const bool is_pinned = (role == "pinned");
        auto& target = is_pinned ? space.pinned : space.today;
        for (const auto& k : *kids) {
          if (!k.is_string()) continue;
          const std::string& item_id = k.GetString();
          if (placed.contains(item_id)) continue;
          if (auto node = build_node(build_node, item_id)) {
            placed.insert(item_id);
            if (is_pinned) {
              SetPinnedUrlRecursive(&*node);
            }
            target.push_back(std::move(*node));
          }
        }
      }
    }
    result.spaces.push_back(std::move(space));
  }

  for (auto& [_, prof] : profiles_by_key) {
    result.profiles.push_back(std::move(prof));
  }

  // Optional StorableArchiveItems.json with dedupe.
  if (options.include_archive) {
    std::string archive_raw;
    if (base::ReadFileToStringWithMaxSize(
            arc_data_dir.AppendASCII("StorableArchiveItems.json"), &archive_raw,
            kMaxJsonBytes)) {
      if (auto arch_dict =
              base::JSONReader::ReadDict(archive_raw, base::JSON_PARSE_RFC)) {
        const auto* flat = arch_dict->FindList("items");
        if (flat) {
          std::set<std::string> seen_archive_ids;
          for (size_t i = 0; i + 1 < flat->size(); i += 2) {
            if (!(*flat)[i].is_string() || !(*flat)[i + 1].is_dict()) continue;
            const std::string& key = (*flat)[i].GetString();
            const base::DictValue& entry = (*flat)[i + 1].GetDict();
            const auto* sitem = entry.FindDict("sidebarItem");
            if (!sitem) continue;
            std::string arc_id =
                sitem->FindString("id") ? *sitem->FindString("id") : key;
            if (live_arc_ids.contains(arc_id) ||
                !seen_archive_ids.insert(arc_id).second) {
              ++result.deduped_archive_items;
              continue;
            }
            const auto* data = sitem->FindDict("data");
            const auto* td = data ? data->FindDict("tab") : nullptr;
            const auto* url = td ? td->FindString("savedURL") : nullptr;
            if (!url || !IsSupportedImportScheme(*url)) continue;

            ArchivedTabRecord rec;
            rec.id = DeterministicUuid("item", arc_id);
            rec.url = *url;
            rec.title =
                td->FindString("savedTitle") ? *td->FindString("savedTitle")
                                             : *url;
            rec.archived_at = entry.FindDouble("archivedAt").value_or(0.0) +
                              kApple2001EpochOffsetSec;
            std::string reason = entry.FindString("reason")
                                     ? *entry.FindString("reason")
                                     : "manual";
            if (reason == "auto") rec.reason = "auto-archive";
            else if (reason == "clearButton" || reason == "clearTabGroup")
              rec.reason = "clear-today";
            else rec.reason = "closed";
            rec.original_location = "today";
            rec.kind = "tab";
            if (const auto* src = entry.FindDict("source")) {
              if (const auto* sp = src->FindDict("space")) {
                if (const auto* sid = sp->FindString("_0")) {
                  rec.space_id = DeterministicUuid("space", *sid);
                }
              }
            }
            result.archive_records.push_back(std::move(rec));
            ++result.imported_archive_items;
          }
        }
      }
    }
  }

  // Optional Arc Boosts (Firestore LevelDB cache + StorableBoostsData.json).
  if (options.include_boosts) {
    ReadArcBoosts(arc_data_dir, default_profile_id, &result.boosts);
    result.imported_boosts = result.boosts.size();
  }

  // Optional Arc Notes & Easels.
  if (options.include_notes || options.include_easels) {
    std::vector<NoteDocument> notes;
    std::vector<EaselDocument> easels;
    ReadArcNotesAndEasels(arc_data_dir, &notes, &easels);
    if (options.include_notes) {
      result.notes = std::move(notes);
      result.imported_notes = result.notes.size();
    }
    if (options.include_easels) {
      result.easels = std::move(easels);
      result.imported_easels = result.easels.size();
    }
  }

  // Optional Arc History (User Data/<profile_dir>/History).
  if (options.include_history && options.max_history_entries > 0) {
    const base::FilePath user_data = arc_data_dir.AppendASCII("User Data");
    std::set<std::string> visited_dirs;
    auto read_profile_hist = [&](const std::string& dir_name) {
      if (!visited_dirs.insert(dir_name).second) return;
      base::FilePath prof_dir = user_data.AppendASCII(dir_name);
      if (!base::PathExists(prof_dir.AppendASCII("History"))) return;
      auto on_batch = base::BindRepeating(
          [](std::vector<HistoryEntry>* out, size_t max_entries,
             const std::vector<HistoryEntry>& batch) {
            for (const auto& e : batch) {
              if (out->size() >= max_entries) break;
              out->push_back(e);
            }
          },
          base::Unretained(&result.history), options.max_history_entries);
      ReadChromiumHistory(prof_dir, on_batch);
    };
    read_profile_hist("Default");
    for (const Profile& p : result.profiles) {
      if (!p.data_directory_name.empty()) {
        read_profile_hist(p.data_directory_name);
      }
    }
    result.imported_history = result.history.size();
  }

  result.ok = true;
  return result;
}

// ============================================================================
// Open (Legacy macOS Open) READ-ONLY Migration Importer
// ============================================================================

// static
OpenLegacyImportResult BrowserImporter::ImportOpenLegacyDirectory(
    const base::FilePath& legacy_open_dir,
    const OpenLegacyImportOptions& options) {
  OpenLegacyImportResult result;

  if (legacy_open_dir.empty() || !base::DirectoryExists(legacy_open_dir)) {
    result.error_message = "Legacy Open directory does not exist";
    return result;
  }

  const base::FilePath state_dir = legacy_open_dir.AppendASCII("State");
  const base::FilePath browser_json = state_dir.AppendASCII("browser.json");

  // 1. State/browser.json (READ-ONLY parse via SnapshotStore::DeserializeModel).
  if (options.include_workspace) {
    std::string raw;
    if (!base::ReadFileToStringWithMaxSize(browser_json, &raw, kMaxJsonBytes)) {
      result.error_message = "Missing or unreadable State/browser.json";
      return result;
    }
    auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
    if (!dict) {
      result.error_message = "Malformed JSON in State/browser.json";
      return result;
    }
    std::string err;
    auto model = SnapshotStore::DeserializeModel(*dict, nullptr, &err);
    if (!model) {
      result.error_message =
          err.empty() ? "Could not decode legacy browser.json" : err;
      return result;
    }
    result.profiles = model->profiles();
    result.spaces = model->spaces();
    result.windows = model->windows();
    result.routing_rules = model->routing_rules();
    result.default_destination = model->default_destination();

    result.imported_profiles = result.profiles.size();
    result.imported_spaces = result.spaces.size();
    for (const Profile& p : result.profiles) {
      result.imported_tabs += p.favorites.size();
    }
    for (const Space& s : result.spaces) {
      CountSidebarNodes(s.pinned, &result.imported_tabs,
                        &result.imported_folders, &result.imported_splits);
      CountSidebarNodes(s.today, &result.imported_tabs,
                        &result.imported_folders, &result.imported_splits);
    }
  }

  // 2. Preferences (State/Preferences.json or macOS UserDefaults plist).
  if (options.include_preferences) {
    std::string prefs_raw;
    if (base::ReadFileToStringWithMaxSize(
            state_dir.AppendASCII("Preferences.json"), &prefs_raw,
            4 * 1024 * 1024)) {
      if (auto dict =
              base::JSONReader::ReadDict(prefs_raw, base::JSON_PARSE_RFC)) {
        for (const auto [k, v] : *dict) {
          result.preferences.emplace(k, v.Clone());
        }
      }
    }
#if BUILDFLAG(IS_MAC)
    if (result.preferences.empty()) {
      auto env = base::Environment::Create();
      std::string home = env->GetVar("HOME").value_or("");
      if (!home.empty()) {
        base::FilePath plist_path = base::FilePath(home)
                                        .AppendASCII("Library")
                                        .AppendASCII("Preferences")
                                        .AppendASCII("com.open.browser.plist");
        std::string plist_raw;
        if (base::ReadFileToStringWithMaxSize(plist_path, &plist_raw,
                                              4 * 1024 * 1024)) {
          if (auto val = ParsePlist(plist_raw); val && val->is_dict()) {
            for (const auto [k, v] : val->GetDict()) {
              if (base::StartsWith(k, "open.")) {
                result.preferences.emplace(k, v.Clone());
              }
            }
          }
        }
      }
    }
#endif
    result.imported_preferences = result.preferences.size();
  }

  // 3. Shortcuts (State/keybindings.json or State/Shortcuts.json).
  if (options.include_shortcuts) {
    for (const char* fname : {"keybindings.json", "Shortcuts.json"}) {
      std::string kb_raw;
      if (base::ReadFileToStringWithMaxSize(state_dir.AppendASCII(fname),
                                            &kb_raw, 4 * 1024 * 1024)) {
        if (auto dict =
                base::JSONReader::ReadDict(kb_raw, base::JSON_PARSE_RFC)) {
          if (const auto* bindings = dict->FindDict("bindings")) {
            result.imported_shortcuts = bindings->size();
          }
          result.keybindings = std::move(*dict);
          break;
        }
      }
    }
  }

  // Ensure we have at least a Default profile reference for per-profile stores.
  std::vector<Profile> scan_profiles = result.profiles;
  if (scan_profiles.empty()) {
    Profile def;
    def.id = DeterministicUuid("profile", "default");
    def.name = "Default";
    def.data_directory_name = "Default";
    scan_profiles.push_back(std::move(def));
  }

  // 4. Boosts (read-only from Profiles/<dir>/Boosts/boosts.json & Boosts/<id>.json).
  if (options.include_boosts) {
    for (const Profile& profile : scan_profiles) {
      std::vector<Boost> profile_boosts;
      base::FilePath per_prof = legacy_open_dir.AppendASCII("Profiles")
                                    .AppendASCII(profile.data_directory_name)
                                    .AppendASCII("Boosts")
                                    .AppendASCII("boosts.json");
      if (base::PathExists(per_prof)) {
        ReadLegacyBoostsJsonFile(per_prof, profile.id, &profile_boosts);
      } else {
        base::FilePath flat = legacy_open_dir.AppendASCII("Boosts")
                                  .AppendASCII(profile.id + ".json");
        if (base::PathExists(flat)) {
          ReadLegacyBoostsJsonFile(flat, profile.id, &profile_boosts);
        }
      }
      if (!profile_boosts.empty()) {
        result.imported_boosts += profile_boosts.size();
        result.boosts_by_profile[profile.id] = std::move(profile_boosts);
      }
    }
  }

  // 5. Easels & Notes (read-only via DocumentStore on root and per-profile dirs).
  if (options.include_documents) {
    std::set<std::string> seen_easels;
    std::set<std::string> seen_notes;
    auto scan_docs_root = [&](const base::FilePath& root_dir) {
      DocumentStore ds(root_dir, /*read_only=*/true);
      for (const EaselIndexEntry& entry : ds.ListEasels()) {
        if (!seen_easels.insert(entry.id).second) continue;
        if (auto doc = ds.LoadEasel(entry.id)) {
          result.easels.push_back(std::move(*doc));
        }
      }
      for (const NoteIndexEntry& entry : ds.ListNotes()) {
        if (!seen_notes.insert(entry.id).second) continue;
        if (auto doc = ds.LoadNote(entry.id)) {
          result.notes.push_back(std::move(*doc));
        }
      }
    };
    scan_docs_root(legacy_open_dir);
    for (const Profile& profile : scan_profiles) {
      base::FilePath pdir = legacy_open_dir.AppendASCII("Profiles")
                                .AppendASCII(profile.data_directory_name);
      if (base::DirectoryExists(pdir)) {
        scan_docs_root(pdir);
      }
    }
    result.imported_easels = result.easels.size();
    result.imported_notes = result.notes.size();
  }

  // 6. History (read-only via SafeSqliteTempCopy).
  if (options.include_history && options.max_history_per_profile > 0) {
    for (const Profile& profile : scan_profiles) {
      base::FilePath pstate = legacy_open_dir.AppendASCII("Profiles")
                                  .AppendASCII(profile.data_directory_name)
                                  .AppendASCII("State");
      base::FilePath db_path;
      for (const char* name :
           {"history.sqlite3", "History.sqlite", "history.sqlite"}) {
        base::FilePath cand = pstate.AppendASCII(name);
        if (base::PathExists(cand)) {
          db_path = cand;
          break;
        }
      }
      if (db_path.empty() && profile.data_directory_name == "Default") {
        for (const char* name :
             {"history.sqlite3", "History.sqlite", "history.sqlite"}) {
          base::FilePath cand = state_dir.AppendASCII(name);
          if (base::PathExists(cand)) {
            db_path = cand;
            break;
          }
        }
      }
      if (db_path.empty()) continue;

      SafeSqliteTempCopy copy;
      if (!copy.Open(db_path)) continue;
      sql::Statement st(copy.db().GetUniqueStatement(
          "SELECT id, url, title, visit_count, typed_count, last_visit "
          "FROM urls ORDER BY last_visit DESC LIMIT ?"));
      st.BindInt64(0, static_cast<int64_t>(options.max_history_per_profile));
      std::vector<HistoryEntry> entries;
      while (st.Step()) {
        std::string url = st.ColumnString(1);
        if (!IsSupportedImportScheme(url)) continue;
        HistoryEntry e;
        e.id = st.ColumnInt64(0);
        e.url = std::move(url);
        e.title = st.ColumnString(2);
        e.visit_count = std::max(1, st.ColumnInt(3));
        e.typed_count = std::max(0, st.ColumnInt(4));
        e.last_visit = st.ColumnDouble(5);
        entries.push_back(std::move(e));
      }
      if (!entries.empty()) {
        result.imported_history += entries.size();
        result.history_by_profile[profile.id] = std::move(entries);
      }
    }
  }

  // 7. Archive (read-only via SafeSqliteTempCopy).
  if (options.include_archive) {
    for (const Profile& profile : scan_profiles) {
      base::FilePath pstate = legacy_open_dir.AppendASCII("Profiles")
                                  .AppendASCII(profile.data_directory_name)
                                  .AppendASCII("State");
      base::FilePath db_path;
      for (const char* name :
           {"archive.sqlite3", "Archive.sqlite", "archive.sqlite"}) {
        base::FilePath cand = pstate.AppendASCII(name);
        if (base::PathExists(cand)) {
          db_path = cand;
          break;
        }
      }
      if (db_path.empty()) continue;
      SafeSqliteTempCopy copy;
      if (!copy.Open(db_path)) continue;
      sql::Statement st(copy.db().GetUniqueStatement(
          "SELECT id, url, title, space_id, profile_id, archived_at, reason, "
          "original_location, payload_json, kind FROM archived_tabs "
          "ORDER BY archived_at DESC LIMIT 5000"));
      std::vector<ArchivedTabRecord> records;
      while (st.Step()) {
        ArchivedTabRecord r;
        r.id = st.ColumnString(0);
        r.url = st.ColumnString(1);
        r.title = st.ColumnString(2);
        if (st.GetColumnType(3) != sql::ColumnType::kNull) {
          r.space_id = st.ColumnString(3);
        }
        if (st.GetColumnType(4) != sql::ColumnType::kNull) {
          r.profile_id = st.ColumnString(4);
        } else {
          r.profile_id = profile.id;
        }
        r.archived_at = st.ColumnDouble(5);
        r.reason = st.ColumnString(6);
        r.original_location = st.ColumnString(7);
        r.payload_json = st.ColumnString(8);
        r.kind = st.ColumnString(9);
        if (r.kind.empty()) r.kind = "tab";
        if (!r.id.empty()) records.push_back(std::move(r));
      }
      if (!records.empty()) {
        result.imported_archive += records.size();
        result.archive_by_profile[profile.id] = std::move(records);
      }
    }
  }

  // 8. AdBlock config, site exclusions, and custom rules (read-only).
  if (options.include_adblock) {
    OpenLegacyAdBlockConfig ab;
    bool found_any = false;
    std::string global_raw;
    if (base::ReadFileToStringWithMaxSize(
            legacy_open_dir.AppendASCII("adblock-settings.json"), &global_raw,
            1024 * 1024)) {
      if (auto dict =
              base::JSONReader::ReadDict(global_raw, base::JSON_PARSE_RFC)) {
        found_any = true;
        ab.global_enabled = dict->FindBool("nativeAdBlockEnabled")
                                .value_or(dict->FindBool("enabled").value_or(true));
      }
    }

    for (const Profile& profile : scan_profiles) {
      base::FilePath ab_dir = legacy_open_dir.AppendASCII("Profiles")
                                  .AppendASCII(profile.data_directory_name)
                                  .AppendASCII("AdBlock");
      if (!base::DirectoryExists(ab_dir)) continue;

      for (const char* cfg_name : {"adblock-config.json", "state.json"}) {
        std::string raw;
        if (base::ReadFileToStringWithMaxSize(ab_dir.AppendASCII(cfg_name),
                                              &raw, 4 * 1024 * 1024)) {
          if (auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC)) {
            found_any = true;
            if (auto en = dict->FindBool("enabled")) ab.global_enabled = *en;
            const auto* lists = dict->FindList("enabled_list_ids");
            if (!lists) lists = dict->FindList("enabledListIDs");
            if (lists) {
              std::vector<std::string> ids;
              for (const auto& lv : *lists) {
                if (lv.is_string()) ids.push_back(lv.GetString());
              }
              ab.enabled_lists_by_profile[profile.id] = std::move(ids);
            }
            break;
          }
        }
      }

      std::string excl_raw;
      if (base::ReadFileToStringWithMaxSize(
              ab_dir.AppendASCII("exclusions.json"), &excl_raw,
              4 * 1024 * 1024)) {
        if (auto val = base::JSONReader::Read(excl_raw, base::JSON_PARSE_RFC)) {
          const base::ListValue* list = val->GetIfList();
          if (!list && val->is_dict()) {
            list = val->GetDict().FindList("excluded_domains");
            if (!list) list = val->GetDict().FindList("domains");
          }
          if (list) {
            found_any = true;
            std::vector<std::string> doms;
            for (const auto& dv : *list) {
              if (dv.is_string()) doms.push_back(dv.GetString());
            }
            ab.excluded_domains_by_profile[profile.id] = std::move(doms);
          }
        }
      }

      std::string custom_raw;
      if (base::ReadFileToStringWithMaxSize(
              ab_dir.AppendASCII("custom-rules.txt"), &custom_raw,
              2 * 1024 * 1024)) {
        found_any = true;
        ab.custom_rules_by_profile[profile.id] = std::move(custom_raw);
      }
    }

    if (found_any) {
      result.adblock = std::move(ab);
    }
  }

  result.ok = true;
  return result;
}

// ============================================================================
// Nested Tree Application & Import Undo
// ============================================================================

// static
ImportReceipt BrowserImporter::ApplyImportedBookmarksToModel(
    BrowserModel* model,
    const SpaceID& target_space_id,
    std::string_view browser_name,
    BrowserFamily source_family,
    std::string_view source_key,
    const std::vector<ImportedBookmarkNode>& roots,
    size_t max_bookmarks) {
  ImportReceipt receipt;
  receipt.import_id = GenerateUuidV4();
  receipt.source_browser = std::string(browser_name);
  receipt.source_family = source_family;
  receipt.imported_at = base::Time::Now().InSecondsFSinceUnixEpoch();

  if (!model || roots.empty()) {
    return receipt;
  }
  Space* space = model->FindSpace(target_space_id);
  if (!space) {
    return receipt;
  }

  Folder root_folder =
      BuildImportedBookmarksFolder(browser_name, source_key, roots);
  if (root_folder.children.empty()) {
    return receipt;
  }

  // Filter out any IDs that already exist in |model| and enforce |max_bookmarks|
  // while preserving the full nested Folder hierarchy!
  size_t remaining_urls = max_bookmarks;
  auto prune_and_record = [&](auto& self,
                              SidebarNode node) -> std::optional<SidebarNode> {
    if (model->HasNode(node.id())) {
      return std::nullopt;
    }
    if (node.as_tab()) {
      if (remaining_urls == 0) return std::nullopt;
      --remaining_urls;
      receipt.created_node_ids.push_back(node.id());
      return node;
    }
    if (Folder* f = node.as_folder()) {
      std::vector<SidebarNode> kept;
      for (SidebarNode& child : f->children) {
        if (auto c = self(self, std::move(child))) {
          kept.push_back(std::move(*c));
        }
      }
      if (kept.empty()) return std::nullopt;
      f->children = std::move(kept);
      receipt.created_node_ids.push_back(f->id);
      return node;
    }
    return std::nullopt;
  };

  if (auto pruned = prune_and_record(prune_and_record,
                                     SidebarNode(std::move(root_folder)))) {
    space->pinned.push_back(std::move(*pruned));
    model->RebuildIndex();
  }
  return receipt;
}

// static
ImportReceipt BrowserImporter::ApplyArcImportToModel(
    BrowserModel* model,
    const ArcSidebarImportResult& arc_result,
    const UndoImportTargets* extra_targets) {
  ImportReceipt receipt;
  receipt.import_id = GenerateUuidV4();
  receipt.source_browser = "Arc";
  receipt.source_family = BrowserFamily::kArc;
  receipt.imported_at = base::Time::Now().InSecondsFSinceUnixEpoch();

  if (!model || !arc_result.ok) {
    return receipt;
  }

  // Map Arc's "Default" profile to the model's existing Default profile when present.
  std::map<ProfileID, ProfileID> profile_map;
  const Profile* existing_default = model->DefaultProfile();

  for (const Profile& arc_prof : arc_result.profiles) {
    if (base::EqualsCaseInsensitiveASCII(arc_prof.data_directory_name,
                                         "default") &&
        existing_default) {
      profile_map[arc_prof.id] = existing_default->id;
      Profile* target = model->FindProfile(existing_default->id);
      if (target) {
        for (const Tab& fav : arc_prof.favorites) {
          if (!model->HasNode(fav.id)) {
            target->favorites.push_back(fav);
            receipt.created_favorite_ids.push_back(fav.id);
          }
        }
      }
    } else if (Profile* existing = model->FindProfile(arc_prof.id)) {
      profile_map[arc_prof.id] = existing->id;
      for (const Tab& fav : arc_prof.favorites) {
        if (!model->HasNode(fav.id)) {
          existing->favorites.push_back(fav);
          receipt.created_favorite_ids.push_back(fav.id);
        }
      }
    } else {
      std::string tmp_name = "ArcImport-" + GenerateUuidV4().substr(0, 8);
      ProfileID tmp_id =
          model->CreateProfile(tmp_name, arc_prof.icon, arc_prof.settings);
      if (Profile* created = model->FindProfile(tmp_id)) {
        std::string safe_dir = created->data_directory_name;
        *created = arc_prof;
        created->data_directory_name = safe_dir;
        profile_map[arc_prof.id] = created->id;
        receipt.created_profile_ids.push_back(created->id);
        model->RebuildIndex();
      }
    }
  }

  ProfileID fallback_pid =
      existing_default ? existing_default->id : model->profiles().front().id;

  // Insert Arc Spaces with nested folders, splits, pinned, and today tabs.
  for (const Space& arc_space : arc_result.spaces) {
    ProfileID target_pid = profile_map.contains(arc_space.profile_id)
                               ? profile_map[arc_space.profile_id]
                               : fallback_pid;
    if (Space* existing = model->FindSpace(arc_space.id)) {
      for (const SidebarNode& n : arc_space.pinned) {
        if (!model->HasNode(n.id())) {
          CollectAllNodeIds(n, &receipt.created_node_ids);
          existing->pinned.push_back(n);
        }
      }
      for (const SidebarNode& n : arc_space.today) {
        if (!model->HasNode(n.id())) {
          CollectAllNodeIds(n, &receipt.created_node_ids);
          existing->today.push_back(n);
        }
      }
    } else {
      SpaceID tmp_sid = model->CreateSpace(target_pid, arc_space.title,
                                           arc_space.icon, arc_space.theme);
      if (Space* created = model->FindSpace(tmp_sid)) {
        *created = arc_space;
        created->profile_id = target_pid;
        receipt.created_space_ids.push_back(created->id);
        for (const SidebarNode& n : created->pinned) {
          CollectAllNodeIds(n, &receipt.created_node_ids);
        }
        for (const SidebarNode& n : created->today) {
          CollectAllNodeIds(n, &receipt.created_node_ids);
        }
        model->RebuildIndex();
      }
    }
  }
  model->RebuildIndex();

  if (extra_targets) {
    // Boosts.
    if (extra_targets->get_boost_store && !arc_result.boosts.empty()) {
      for (const Boost& b : arc_result.boosts) {
        ProfileID pid = profile_map.contains(b.profile_id)
                            ? profile_map[b.profile_id]
                            : fallback_pid;
        if (BoostStore* bs = extra_targets->get_boost_store.Run(pid)) {
          if (!bs->GetBoost(b.id)) {
            Boost copy = b;
            copy.profile_id = pid;
            bs->Upsert(std::move(copy));
            receipt.created_boost_ids[pid].push_back(b.id);
          }
        }
      }
      for (const auto& [pid, _] : receipt.created_boost_ids) {
        if (BoostStore* bs = extra_targets->get_boost_store.Run(pid)) {
          bs->SaveNow();
        }
      }
    }

    // Easels & Notes.
    if (extra_targets->document_store) {
      for (const EaselDocument& e : arc_result.easels) {
        if (!extra_targets->document_store->LoadEasel(e.id)) {
          if (extra_targets->document_store->SaveEasel(e)) {
            receipt.created_easel_ids.push_back(e.id);
          }
        }
      }
      for (const NoteDocument& n : arc_result.notes) {
        if (!extra_targets->document_store->LoadNote(n.id)) {
          if (extra_targets->document_store->SaveNote(n)) {
            receipt.created_note_ids.push_back(n.id);
          }
        }
      }
    }

    // Archive.
    if (extra_targets->get_archive_store &&
        !arc_result.archive_records.empty()) {
      if (ArchiveStore* as = extra_targets->get_archive_store.Run(fallback_pid)) {
        std::vector<ArchivedTabRecord> to_add;
        for (const ArchivedTabRecord& r : arc_result.archive_records) {
          if (!as->Get(r.id)) {
            to_add.push_back(r);
            receipt.created_archive_ids[fallback_pid].push_back(r.id);
          }
        }
        if (!to_add.empty()) {
          as->Archive(to_add);
        }
      }
    }

    // History.
    if (extra_targets->get_history_store && !arc_result.history.empty()) {
      if (HistoryStore* hs = extra_targets->get_history_store.Run(fallback_pid)) {
        TimestampSec min_ts = arc_result.history.front().last_visit;
        TimestampSec max_ts = min_ts;
        for (const HistoryEntry& e : arc_result.history) {
          hs->RecordVisit(e.url, e.title, e.last_visit, "imported",
                          e.typed_count > 0);
          min_ts = std::min(min_ts, e.last_visit);
          max_ts = std::max(max_ts, e.last_visit);
        }
        receipt.history_range_start = min_ts;
        receipt.history_range_end = max_ts;
        receipt.history_profile_ids.push_back(fallback_pid);
      }
    }
  }

  return receipt;
}

// static
ImportReceipt BrowserImporter::ApplyOpenLegacyImportToModel(
    BrowserModel* model,
    const OpenLegacyImportResult& legacy_result,
    const UndoImportTargets* extra_targets) {
  ImportReceipt receipt;
  receipt.import_id = GenerateUuidV4();
  receipt.source_browser = "Open (Legacy)";
  receipt.source_family = BrowserFamily::kOpenLegacy;
  receipt.imported_at = base::Time::Now().InSecondsFSinceUnixEpoch();

  if (!model || !legacy_result.ok) {
    return receipt;
  }

  std::map<ProfileID, ProfileID> profile_map;
  const Profile* existing_default = model->DefaultProfile();

  for (const Profile& lp : legacy_result.profiles) {
    if (base::EqualsCaseInsensitiveASCII(lp.data_directory_name, "default") &&
        existing_default) {
      profile_map[lp.id] = existing_default->id;
      if (Profile* target = model->FindProfile(existing_default->id)) {
        for (const Tab& fav : lp.favorites) {
          if (!model->HasNode(fav.id)) {
            target->favorites.push_back(fav);
            receipt.created_favorite_ids.push_back(fav.id);
          }
        }
      }
    } else if (Profile* existing = model->FindProfile(lp.id)) {
      profile_map[lp.id] = existing->id;
      for (const Tab& fav : lp.favorites) {
        if (!model->HasNode(fav.id)) {
          existing->favorites.push_back(fav);
          receipt.created_favorite_ids.push_back(fav.id);
        }
      }
    } else {
      std::string tmp_name = "OpenLegacy-" + GenerateUuidV4().substr(0, 8);
      ProfileID tmp_id = model->CreateProfile(tmp_name, lp.icon, lp.settings);
      if (Profile* created = model->FindProfile(tmp_id)) {
        std::string safe_dir = created->data_directory_name;
        *created = lp;
        created->data_directory_name = safe_dir;
        profile_map[lp.id] = created->id;
        receipt.created_profile_ids.push_back(created->id);
        model->RebuildIndex();
      }
    }
  }

  ProfileID fallback_pid =
      existing_default ? existing_default->id : model->profiles().front().id;

  for (const Space& ls : legacy_result.spaces) {
    ProfileID target_pid = profile_map.contains(ls.profile_id)
                               ? profile_map[ls.profile_id]
                               : fallback_pid;
    if (Space* existing = model->FindSpace(ls.id)) {
      for (const SidebarNode& n : ls.pinned) {
        if (!model->HasNode(n.id())) {
          CollectAllNodeIds(n, &receipt.created_node_ids);
          existing->pinned.push_back(n);
        }
      }
      for (const SidebarNode& n : ls.today) {
        if (!model->HasNode(n.id())) {
          CollectAllNodeIds(n, &receipt.created_node_ids);
          existing->today.push_back(n);
        }
      }
    } else {
      SpaceID tmp_sid =
          model->CreateSpace(target_pid, ls.title, ls.icon, ls.theme);
      if (Space* created = model->FindSpace(tmp_sid)) {
        *created = ls;
        created->profile_id = target_pid;
        receipt.created_space_ids.push_back(created->id);
        for (const SidebarNode& n : created->pinned) {
          CollectAllNodeIds(n, &receipt.created_node_ids);
        }
        for (const SidebarNode& n : created->today) {
          CollectAllNodeIds(n, &receipt.created_node_ids);
        }
        model->RebuildIndex();
      }
    }
  }

  if (!legacy_result.routing_rules.empty()) {
    std::vector<RoutingRule> merged = model->routing_rules();
    std::set<RuleID> existing_ids;
    for (const RoutingRule& r : merged) existing_ids.insert(r.id);
    for (const RoutingRule& r : legacy_result.routing_rules) {
      if (existing_ids.insert(r.id).second) {
        merged.push_back(r);
        receipt.routing_rules_modified = true;
      }
    }
    if (receipt.routing_rules_modified) {
      model->SetRoutingRules(std::move(merged));
    }
  }

  model->RebuildIndex();

  if (extra_targets) {
    if (extra_targets->get_boost_store) {
      for (const auto& [src_pid, boosts] : legacy_result.boosts_by_profile) {
        ProfileID pid =
            profile_map.contains(src_pid) ? profile_map[src_pid] : fallback_pid;
        if (BoostStore* bs = extra_targets->get_boost_store.Run(pid)) {
          bool touched = false;
          for (const Boost& b : boosts) {
            if (!bs->GetBoost(b.id)) {
              Boost copy = b;
              copy.profile_id = pid;
              bs->Upsert(std::move(copy));
              receipt.created_boost_ids[pid].push_back(b.id);
              touched = true;
            }
          }
          if (touched) bs->SaveNow();
        }
      }
    }

    if (extra_targets->document_store) {
      for (const EaselDocument& e : legacy_result.easels) {
        if (!extra_targets->document_store->LoadEasel(e.id) &&
            extra_targets->document_store->SaveEasel(e)) {
          receipt.created_easel_ids.push_back(e.id);
        }
      }
      for (const NoteDocument& n : legacy_result.notes) {
        if (!extra_targets->document_store->LoadNote(n.id) &&
            extra_targets->document_store->SaveNote(n)) {
          receipt.created_note_ids.push_back(n.id);
        }
      }
    }

    if (extra_targets->get_archive_store) {
      for (const auto& [src_pid, records] : legacy_result.archive_by_profile) {
        ProfileID pid =
            profile_map.contains(src_pid) ? profile_map[src_pid] : fallback_pid;
        if (ArchiveStore* as = extra_targets->get_archive_store.Run(pid)) {
          std::vector<ArchivedTabRecord> to_add;
          for (const ArchivedTabRecord& r : records) {
            if (!as->Get(r.id)) {
              to_add.push_back(r);
              receipt.created_archive_ids[pid].push_back(r.id);
            }
          }
          if (!to_add.empty()) as->Archive(to_add);
        }
      }
    }

    if (extra_targets->get_history_store) {
      for (const auto& [src_pid, entries] : legacy_result.history_by_profile) {
        if (entries.empty()) continue;
        ProfileID pid =
            profile_map.contains(src_pid) ? profile_map[src_pid] : fallback_pid;
        if (HistoryStore* hs = extra_targets->get_history_store.Run(pid)) {
          for (const HistoryEntry& e : entries) {
            hs->RecordVisit(e.url, e.title, e.last_visit, "imported",
                            e.typed_count > 0);
            if (!receipt.history_range_start ||
                e.last_visit < *receipt.history_range_start) {
              receipt.history_range_start = e.last_visit;
            }
            if (!receipt.history_range_end ||
                e.last_visit > *receipt.history_range_end) {
              receipt.history_range_end = e.last_visit;
            }
          }
          receipt.history_profile_ids.push_back(pid);
        }
      }
    }
  }

  return receipt;
}

// static
bool BrowserImporter::UndoImport(const ImportReceipt& receipt,
                                 BrowserModel* model,
                                 const UndoImportTargets* extra_targets) {
  if (!model) {
    return false;
  }

  // 1. Revert Boosts, Documents, Archive, and History in extra stores first
  //    (before Profiles may be deleted from BrowserModel).
  if (extra_targets) {
    if (extra_targets->get_boost_store) {
      for (const auto& [pid, boost_ids] : receipt.created_boost_ids) {
        if (BoostStore* bs = extra_targets->get_boost_store.Run(pid)) {
          bool touched = false;
          for (const std::string& bid : boost_ids) {
            if (bs->Delete(bid)) touched = true;
          }
          if (touched) bs->SaveNow();
        }
      }
    }
    if (extra_targets->document_store) {
      for (const std::string& eid : receipt.created_easel_ids) {
        extra_targets->document_store->DeleteEasel(eid);
      }
      for (const std::string& nid : receipt.created_note_ids) {
        extra_targets->document_store->DeleteNote(nid);
      }
    }
    if (extra_targets->get_archive_store) {
      for (const auto& [pid, archive_ids] : receipt.created_archive_ids) {
        if (ArchiveStore* as = extra_targets->get_archive_store.Run(pid)) {
          as->DeleteIds(archive_ids);
        }
      }
    }
    if (extra_targets->get_history_store &&
        receipt.history_range_start.has_value() &&
        receipt.history_range_end.has_value()) {
      for (const ProfileID& pid : receipt.history_profile_ids) {
        if (HistoryStore* hs = extra_targets->get_history_store.Run(pid)) {
          hs->ClearRange(*receipt.history_range_start,
                         *receipt.history_range_end);
        }
      }
    }
  }

  // 2. Remove created Favorites from existing Profiles without archiving.
  if (!receipt.created_favorite_ids.empty()) {
    std::set<ItemID> fav_set(receipt.created_favorite_ids.begin(),
                             receipt.created_favorite_ids.end());
    std::vector<ProfileID> all_pids;
    for (const Profile& p : model->profiles()) all_pids.push_back(p.id);
    for (const ProfileID& pid : all_pids) {
      if (Profile* p = model->FindProfile(pid)) {
        std::erase_if(p->favorites, [&](const Tab& t) {
          return fav_set.contains(t.id);
        });
      }
    }
  }

  // 3. Remove created SidebarNodes from existing Spaces without archiving.
  if (!receipt.created_node_ids.empty()) {
    std::set<ItemID> node_set(receipt.created_node_ids.begin(),
                              receipt.created_node_ids.end());
    std::vector<SpaceID> all_sids;
    for (const Space& s : model->spaces()) all_sids.push_back(s.id);
    for (const SpaceID& sid : all_sids) {
      if (Space* s = model->FindSpace(sid)) {
        RemoveNodesByIdRecursive(&s->pinned, node_set);
        RemoveNodesByIdRecursive(&s->today, node_set);
      }
    }
  }

  // 4. Delete created Spaces (without archiving) while keeping at least one.
  for (auto it = receipt.created_space_ids.rbegin();
       it != receipt.created_space_ids.rend(); ++it) {
    if (model->spaces().size() <= 1) break;
    model->DeleteSpace(*it, /*archive_tabs=*/false);
  }

  // 5. Delete created Profiles (only when no Spaces remain assigned).
  for (auto it = receipt.created_profile_ids.rbegin();
       it != receipt.created_profile_ids.rend(); ++it) {
    model->DeleteProfile(*it);
  }

  model->RebuildIndex();
  return true;
}

}  // namespace open_unified
