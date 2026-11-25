// Copyright 2026 The Open Authors. All rights reserved.
// Cross-platform browser importer implementation.

#include "open_unified/core/import/browser_importer.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <map>
#include <set>
#include <sstream>
#include <utility>

#include "base/environment.h"
#include "base/files/file.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/values.h"
#include "build/build_config.h"
#include "sql/database.h"
#include "sql/statement.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

// Microseconds between 1601-01-01 (WebKit/Windows epoch) and 1970-01-01.
constexpr int64_t kWebkitEpochOffsetMicros = 11644473600000000LL;
// Seconds between 1970-01-01 and 2001-01-01 (Apple Core Data epoch).
constexpr double kApple2001EpochOffsetSec = 978307200.0;

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

// Safely copies a SQLite database (+ matching -wal or -journal, never -shm)
// into a private temporary directory so a live running browser is never locked
// or mutated.
class SafeSqliteTempCopy {
 public:
  SafeSqliteTempCopy() = default;
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
      // Run PRAGMA quick_check and switch connection to read-only query mode.
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

constexpr size_t kMaxProbeJsonBytes = 16 * 1024 * 1024;
constexpr int64_t kMaxProbeSqliteBytes = 8 * 1024 * 1024;
constexpr int kMaxReportedProbeCount = 500000;

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

// Probes Chromium-family profiles using Local State + directory scan.
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

std::string DecodeHtmlEntities(std::string_view raw) {
  std::string out;
  out.reserve(raw.size());
  for (size_t i = 0; i < raw.size(); ++i) {
    if (raw[i] != '&') {
      out.push_back(raw[i]);
      continue;
    }
    size_t semi = raw.find(';', i + 1);
    if (semi == std::string_view::npos || semi - i > 10) {
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
      if (parsed && code > 0 && code < 0x80) {
        out.push_back(static_cast<char>(code));
      } else {
        out.append(raw.substr(i, semi - i + 1));
      }
    } else {
      out.append(raw.substr(i, semi - i + 1));
    }
    i = semi;
  }
  return std::string(base::TrimWhitespaceASCII(out, base::TRIM_ALL));
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

}  // namespace

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

  char buf[37]{};
  std::snprintf(
      buf, sizeof(buf),
      "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
      bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13],
      bytes[14], bytes[15]);
  return std::string(buf);
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
  std::string local_app_data;
  std::string roaming_app_data;
  env->GetVar("LOCALAPPDATA", &local_app_data);
  env->GetVar("APPDATA", &roaming_app_data);
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
  std::string home;
  env->GetVar("HOME", &home);
  if (!home.empty()) {
    base::FilePath app_sup = base::FilePath(home)
                                 .AppendASCII("Library")
                                 .AppendASCII("Application Support");
    candidates.push_back(
        {"arc", "Arc", BrowserFamily::kArc, app_sup.AppendASCII("Arc")});
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
  std::string home;
  env->GetVar("HOME", &home);
  std::string xdg_config;
  env->GetVar("XDG_CONFIG_HOME", &xdg_config);
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

// --- Chromium Bookmarks & History ---

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

  // Load urls table into map.
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

    // Dedupe on (url, second-granularity timestamp).
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

// --- Firefox / Gecko ---

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
    if (cnt.Step()) report.source_url_rows = static_cast<size_t>(cnt.ColumnInt64(0));
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

// --- Netscape HTML Bookmarks ---

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

  size_t pos = 0;
  while (pos < html_bytes.size()) {
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
      const Frame& parent = stack.back();
      std::string title = pending_folder.value_or("");
      std::string fid = parent.id + "/" +
                        base::NumberToString(parent.children.size()) + ":" +
                        title;
      stack.push_back(Frame{std::move(fid), std::move(title), {}});
      pending_folder.reset();
    } else if (tag_name == "/DL") {
      if (stack.size() <= 1) continue;
      Frame done = std::move(stack.back());
      stack.pop_back();
      if (done.children.empty()) {
        ++report.skipped;
      } else {
        ++report.folders;
        ImportedBookmarkNode f;
        f.is_folder = true;
        f.source_id = std::move(done.id);
        f.title = std::move(done.title);
        f.children = std::move(done.children);
        stack.back().children.push_back(std::move(f));
      }
    } else if (tag_name == "A") {
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

// --- Arc StorableSidebar.json & StorableArchiveItems.json ---

// static
ArcSidebarImportResult BrowserImporter::ImportArcDirectory(
    const base::FilePath& arc_data_dir,
    bool include_archive) {
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

  // Locate global sidebar holder keyed by {"global":{}}.
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
  ensure_profile("default");

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
          prof.favorites.push_back(std::move(*n->as_tab()));
        }
      }
    }
  }

  // Spaces and their pinned/unpinned containers.
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

        auto& target = (role == "pinned") ? space.pinned : space.today;
        for (const auto& k : *kids) {
          if (!k.is_string()) continue;
          const std::string& item_id = k.GetString();
          if (placed.contains(item_id)) continue;
          if (auto node = build_node(build_node, item_id)) {
            placed.insert(item_id);
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
  if (include_archive) {
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

  result.ok = true;
  return result;
}

}  // namespace open_unified
