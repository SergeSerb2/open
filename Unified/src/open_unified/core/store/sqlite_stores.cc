// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/store/sqlite_stores.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <utility>

#include "base/containers/span.h"
#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/values.h"
#include "sql/statement.h"
#include "sql/transaction.h"

namespace open_unified {

namespace {

TimestampSec NowSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

std::string EscapeLikePattern(std::string_view text) {
  std::string out;
  out.reserve(text.size() + 2);
  out.push_back('%');
  for (char c : text) {
    if (c == '%' || c == '_' || c == '\\') {
      out.push_back('\\');
    }
    out.push_back(c);
  }
  out.push_back('%');
  return out;
}

// Extracts canonical origin ("https://example.com" or "http://host:8080") and
// path ("/" or "/foo/bar") for http(s) URLs.
std::optional<std::pair<std::string, std::string>> ExtractOriginAndPageKey(
    std::string_view url) {
  if (url.size() > 8192) {
    return std::nullopt;
  }
  size_t scheme_sep = url.find("://");
  if (scheme_sep == std::string_view::npos) {
    return std::nullopt;
  }
  std::string scheme = base::ToLowerASCII(url.substr(0, scheme_sep));
  if (scheme != "http" && scheme != "https") {
    return std::nullopt;
  }
  std::string_view rest = url.substr(scheme_sep + 3);
  size_t path_start = rest.find_first_of("/?#");
  std::string_view authority =
      path_start == std::string_view::npos ? rest : rest.substr(0, path_start);
  // Strip credentials if present.
  size_t at = authority.rfind('@');
  if (at != std::string_view::npos) {
    authority = authority.substr(at + 1);
  }
  if (authority.empty()) {
    return std::nullopt;
  }

  std::string host;
  std::string port_str;
  if (authority.front() == '[') {
    size_t close = authority.find(']');
    if (close == std::string_view::npos) {
      return std::nullopt;
    }
    host = base::ToLowerASCII(authority.substr(0, close + 1));
    if (close + 1 < authority.size() && authority[close + 1] == ':') {
      port_str = std::string(authority.substr(close + 2));
    }
  } else {
    size_t colon = authority.rfind(':');
    if (colon != std::string_view::npos) {
      host = base::ToLowerASCII(authority.substr(0, colon));
      port_str = std::string(authority.substr(colon + 1));
    } else {
      host = base::ToLowerASCII(authority);
    }
  }
  if (host.empty()) {
    return std::nullopt;
  }
  if ((scheme == "https" && port_str == "443") ||
      (scheme == "http" && port_str == "80")) {
    port_str.clear();
  }
  std::string origin = scheme + "://" + host;
  if (!port_str.empty()) {
    origin += ":" + port_str;
  }

  std::string page_key = "/";
  if (path_start != std::string_view::npos && rest[path_start] == '/') {
    std::string_view path_part = rest.substr(path_start);
    size_t q = path_part.find_first_of("?#");
    if (q != std::string_view::npos) {
      path_part = path_part.substr(0, q);
    }
    if (!path_part.empty()) {
      page_key = std::string(path_part);
    }
  }
  return std::make_pair(std::move(origin), std::move(page_key));
}

std::vector<uint8_t> ReadBlobColumn(sql::Statement& stmt, int col) {
  if (stmt.GetColumnType(col) == sql::ColumnType::kNull) {
    return {};
  }
  base::span<const uint8_t> span = stmt.ColumnBlob(col);
  return std::vector<uint8_t>(span.begin(), span.end());
}

}  // namespace

// ============================================================================
// HistoryStore
// ============================================================================

HistoryStore::HistoryStore(base::FilePath db_path)
    : db_path_(std::move(db_path)),
      db_(sql::DatabaseOptions().set_exclusive_locking(false),
          sql::Database::Tag("History")) {}

HistoryStore::~HistoryStore() {
  Close();
}

bool HistoryStore::Open() {
  if (closed_) {
    return false;
  }
  if (db_.is_open()) {
    return true;
  }
  if (!base::CreateDirectory(db_path_.DirName())) {
    return false;
  }
  if (!db_.Open(db_path_)) {
    LOG(ERROR) << "HistoryStore::Open db_.Open failed: " << db_.GetErrorMessage();
    return false;
  }
  static constexpr char kSchema[] = R"SQL(
    CREATE TABLE IF NOT EXISTS urls(
      id INTEGER PRIMARY KEY,
      url TEXT UNIQUE NOT NULL,
      title TEXT NOT NULL DEFAULT '',
      visit_count INTEGER NOT NULL DEFAULT 0,
      typed_count INTEGER NOT NULL DEFAULT 0,
      last_visit REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS visits(
      id INTEGER PRIMARY KEY,
      url_id INTEGER NOT NULL REFERENCES urls(id),
      time REAL NOT NULL,
      transition TEXT NOT NULL DEFAULT 'link'
    );
    CREATE INDEX IF NOT EXISTS idx_visits_time ON visits(time DESC);
    CREATE TABLE IF NOT EXISTS history_import_keys(
      visit_key TEXT PRIMARY KEY NOT NULL,
      url_id INTEGER NOT NULL REFERENCES urls(id)
    );
    CREATE INDEX IF NOT EXISTS idx_visits_url_time ON visits(url_id, time);
    CREATE INDEX IF NOT EXISTS idx_urls_last_visit ON urls(last_visit DESC, id DESC);
  )SQL";
  if (!db_.Execute(kSchema)) {
    LOG(ERROR) << "HistoryStore::Open schema failed: " << db_.GetErrorMessage();
    db_.Close();
    return false;
  }
  return true;
}

void HistoryStore::Close() {
  closed_ = true;
  ++deletion_generation_;
  db_.Close();
}

std::optional<int64_t> HistoryStore::RecordVisit(const std::string& url,
                                                 const std::string& title,
                                                 TimestampSec time,
                                                 const std::string& transition,
                                                 bool typed) {
  if (!Open() || url.empty()) {
    return std::nullopt;
  }
  if (time <= 0.0) {
    time = NowSec();
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return std::nullopt;
  }
  int64_t url_id = 0;
  {
    sql::Statement sel(
        db_.GetUniqueStatement("SELECT id FROM urls WHERE url = ?"));
    sel.BindString(0, url);
    if (sel.Step()) {
      url_id = sel.ColumnInt64(0);
    }
  }
  if (url_id > 0) {
    sql::Statement upd(db_.GetUniqueStatement(
        "UPDATE urls SET "
        "title = CASE WHEN ? <> '' THEN ? ELSE title END, "
        "visit_count = visit_count + 1, "
        "typed_count = typed_count + ?, "
        "last_visit = ? "
        "WHERE id = ?"));
    upd.BindString(0, title);
    upd.BindString(1, title);
    upd.BindInt(2, typed ? 1 : 0);
    upd.BindDouble(3, time);
    upd.BindInt64(4, url_id);
    if (!upd.Run()) {
      LOG(ERROR) << "HistoryStore::RecordVisit update failed: "
                 << db_.GetErrorMessage();
      return std::nullopt;
    }
  } else {
    sql::Statement ins_url(db_.GetUniqueStatement(
        "INSERT INTO urls(url, title, visit_count, typed_count, last_visit) "
        "VALUES(?, ?, 1, ?, ?)"));
    ins_url.BindString(0, url);
    ins_url.BindString(1, title);
    ins_url.BindInt(2, typed ? 1 : 0);
    ins_url.BindDouble(3, time);
    if (!ins_url.Run()) {
      LOG(ERROR) << "HistoryStore::RecordVisit insert url failed: "
                 << db_.GetErrorMessage();
      return std::nullopt;
    }
    url_id = db_.GetLastInsertRowId();
  }
  int64_t visit_id = 0;
  {
    sql::Statement ins(db_.GetUniqueStatement(
        "INSERT INTO visits(url_id, time, transition) VALUES(?, ?, ?)"));
    ins.BindInt64(0, url_id);
    ins.BindDouble(1, time);
    ins.BindString(2, transition);
    if (!ins.Run()) {
      LOG(ERROR) << "HistoryStore::RecordVisit insert visit failed: "
                 << db_.GetErrorMessage();
      return std::nullopt;
    }
    visit_id = db_.GetLastInsertRowId();
  }
  if (!txn.Commit()) {
    LOG(ERROR) << "HistoryStore::RecordVisit commit failed: "
               << db_.GetErrorMessage();
    return std::nullopt;
  }
  return visit_id;
}

bool HistoryStore::UpdateTitle(const std::string& title,
                               int64_t visit_id,
                               TimestampSec time) {
  if (title.empty() || !db_.is_open()) {
    return false;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "UPDATE urls SET title = ? WHERE title <> ? AND id = "
      "(SELECT url_id FROM visits WHERE id = ? AND time = ?) AND "
      "? = (SELECT MAX(v.id) FROM visits v WHERE v.url_id = urls.id)"));
  stmt.BindString(0, title);
  stmt.BindString(1, title);
  stmt.BindInt64(2, visit_id);
  stmt.BindDouble(3, time);
  stmt.BindInt64(4, visit_id);
  return stmt.Run() && db_.GetLastChangeCount() > 0;
}

std::vector<HistoryEntry> HistoryStore::Search(const std::string& query,
                                               int limit) {
  if (!Open() || limit <= 0) {
    return {};
  }
  std::string trimmed;
  base::TrimWhitespaceASCII(query, base::TRIM_ALL, &trimmed);
  if (trimmed.empty()) {
    return TopEntries(limit);
  }

  // Extract alphanumeric / non-ASCII tokens for safe FTS5 prefix queries.
  std::vector<std::string> tokens;
  std::string cur;
  for (unsigned char c : trimmed) {
    if (std::isalnum(c) || c >= 128) {
      cur.push_back(static_cast<char>(c));
    } else if (!cur.empty()) {
      tokens.push_back(std::move(cur));
      cur.clear();
    }
  }
  if (!cur.empty()) {
    tokens.push_back(std::move(cur));
  }
  if (tokens.empty()) {
    return SubstringSearch(trimmed, limit);
  }

  TimestampSec now = NowSec();
  std::string sql_str =
      "SELECT u.id, u.url, u.title, u.visit_count, u.typed_count, u.last_visit "
      "FROM urls u WHERE 1=1";
  for (size_t i = 0; i < tokens.size(); ++i) {
    sql_str += " AND (u.title LIKE ? ESCAPE '\\' OR u.url LIKE ? ESCAPE '\\')";
  }
  sql_str +=
      " ORDER BY (u.visit_count + 3 * u.typed_count) * "
      "(1.0 / (1.0 + MAX(0.0, (CAST(? AS REAL) - u.last_visit) / 86400.0))) DESC "
      "LIMIT ?";

  sql::Statement stmt(db_.GetUniqueStatement(sql_str));
  int bind_idx = 0;
  for (const auto& token : tokens) {
    std::string like = EscapeLikePattern(token);
    stmt.BindString(bind_idx++, like);
    stmt.BindString(bind_idx++, like);
  }
  stmt.BindDouble(bind_idx++, now);
  stmt.BindInt(bind_idx++, limit);

  std::vector<HistoryEntry> rows;
  while (stmt.Step()) {
    HistoryEntry e;
    e.id = stmt.ColumnInt64(0);
    e.url = stmt.ColumnString(1);
    e.title = stmt.ColumnString(2);
    e.visit_count = stmt.ColumnInt(3);
    e.typed_count = stmt.ColumnInt(4);
    e.last_visit = stmt.ColumnDouble(5);
    rows.push_back(std::move(e));
  }
  if (!stmt.Succeeded() || rows.empty()) {
    return SubstringSearch(trimmed, limit);
  }
  return rows;
}

std::vector<HistoryEntry> HistoryStore::TopEntries(int limit) {
  sql::Statement stmt(db_.GetUniqueStatement(
      "SELECT id, url, title, visit_count, typed_count, last_visit FROM urls "
      "ORDER BY visit_count + 3 * typed_count DESC LIMIT ?"));
  stmt.BindInt(0, limit);
  std::vector<HistoryEntry> rows;
  while (stmt.Step()) {
    HistoryEntry e;
    e.id = stmt.ColumnInt64(0);
    e.url = stmt.ColumnString(1);
    e.title = stmt.ColumnString(2);
    e.visit_count = stmt.ColumnInt(3);
    e.typed_count = stmt.ColumnInt(4);
    e.last_visit = stmt.ColumnDouble(5);
    rows.push_back(std::move(e));
  }
  return rows;
}

std::vector<HistoryEntry> HistoryStore::SubstringSearch(const std::string& text,
                                                        int limit) {
  std::string like = EscapeLikePattern(text);
  sql::Statement stmt(db_.GetUniqueStatement(
      "SELECT id, url, title, visit_count, typed_count, last_visit FROM urls "
      "WHERE title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\' "
      "ORDER BY visit_count + 3 * typed_count DESC LIMIT ?"));
  stmt.BindString(0, like);
  stmt.BindString(1, like);
  stmt.BindInt(2, limit);
  std::vector<HistoryEntry> rows;
  while (stmt.Step()) {
    HistoryEntry e;
    e.id = stmt.ColumnInt64(0);
    e.url = stmt.ColumnString(1);
    e.title = stmt.ColumnString(2);
    e.visit_count = stmt.ColumnInt(3);
    e.typed_count = stmt.ColumnInt(4);
    e.last_visit = stmt.ColumnDouble(5);
    rows.push_back(std::move(e));
  }
  return rows;
}

std::vector<HistoryEntry> HistoryStore::Recent(int limit, int offset) {
  if (!Open() || limit <= 0) {
    return {};
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "SELECT id, url, title, visit_count, typed_count, last_visit FROM urls "
      "ORDER BY last_visit DESC, id DESC LIMIT ? OFFSET ?"));
  stmt.BindInt(0, std::clamp(limit, 0, 1000));
  stmt.BindInt(1, std::max(0, offset));
  std::vector<HistoryEntry> rows;
  while (stmt.Step()) {
    HistoryEntry e;
    e.id = stmt.ColumnInt64(0);
    e.url = stmt.ColumnString(1);
    e.title = stmt.ColumnString(2);
    e.visit_count = stmt.ColumnInt(3);
    e.typed_count = stmt.ColumnInt(4);
    e.last_visit = stmt.ColumnDouble(5);
    rows.push_back(std::move(e));
  }
  return rows;
}

bool HistoryStore::DeleteUrl(const std::string& url) {
  if (!Open() || url.empty()) {
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  int64_t url_id = 0;
  {
    sql::Statement sel(db_.GetUniqueStatement("SELECT id FROM urls WHERE url = ?"));
    sel.BindString(0, url);
    if (!sel.Step()) {
      return txn.Commit();
    }
    url_id = sel.ColumnInt64(0);
  }
  {
    sql::Statement del_v(db_.GetUniqueStatement("DELETE FROM visits WHERE url_id = ?"));
    del_v.BindInt64(0, url_id);
    if (!del_v.Run()) return false;
  }
  {
    sql::Statement del_k(
        db_.GetUniqueStatement("DELETE FROM history_import_keys WHERE url_id = ?"));
    del_k.BindInt64(0, url_id);
    if (!del_k.Run()) return false;
  }
  {
    sql::Statement del_u(db_.GetUniqueStatement("DELETE FROM urls WHERE id = ?"));
    del_u.BindInt64(0, url_id);
    if (!del_u.Run()) return false;
  }
  if (!txn.Commit()) {
    return false;
  }
  ++deletion_generation_;
  return true;
}

bool HistoryStore::DeleteIds(const std::vector<int64_t>& ids) {
  if (ids.empty()) {
    return true;
  }
  if (!Open()) {
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  sql::Statement del_v(
      db_.GetUniqueStatement("DELETE FROM visits WHERE url_id = ?"));
  sql::Statement del_k(db_.GetUniqueStatement(
      "DELETE FROM history_import_keys WHERE url_id = ?"));
  sql::Statement del_u(
      db_.GetUniqueStatement("DELETE FROM urls WHERE id = ?"));
  for (int64_t url_id : ids) {
    del_v.BindInt64(0, url_id);
    if (!del_v.Run()) {
      return false;
    }
    del_v.Reset(/*clear_bound_vars=*/true);

    del_k.BindInt64(0, url_id);
    if (!del_k.Run()) {
      return false;
    }
    del_k.Reset(/*clear_bound_vars=*/true);

    del_u.BindInt64(0, url_id);
    if (!del_u.Run()) {
      return false;
    }
    del_u.Reset(/*clear_bound_vars=*/true);
  }
  if (!txn.Commit()) {
    return false;
  }
  ++deletion_generation_;
  return true;
}

bool HistoryStore::ClearRange(std::optional<TimestampSec> since,
                              TimestampSec through) {
  if (!Open()) {
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  if (!db_.Execute(
          "CREATE TEMP TABLE IF NOT EXISTS history_delete_urls(id INTEGER PRIMARY KEY);"
          "DELETE FROM history_delete_urls;")) {
    return false;
  }
  if (since.has_value()) {
    sql::Statement sel(db_.GetUniqueStatement(
        "INSERT OR IGNORE INTO history_delete_urls "
        "SELECT DISTINCT url_id FROM visits WHERE time >= ? AND time <= ?"));
    sel.BindDouble(0, *since);
    sel.BindDouble(1, through);
    if (!sel.Run()) return false;

    sql::Statement del(db_.GetUniqueStatement(
        "DELETE FROM visits WHERE time >= ? AND time <= ?"));
    del.BindDouble(0, *since);
    del.BindDouble(1, through);
    if (!del.Run()) return false;
  } else {
    sql::Statement sel(db_.GetUniqueStatement(
        "INSERT OR IGNORE INTO history_delete_urls "
        "SELECT url_id FROM visits WHERE time <= ? "
        "UNION SELECT id FROM urls WHERE NOT EXISTS "
        "(SELECT 1 FROM visits WHERE visits.url_id = urls.id)"));
    sel.BindDouble(0, through);
    if (!sel.Run()) return false;

    sql::Statement del(db_.GetUniqueStatement("DELETE FROM visits WHERE time <= ?"));
    del.BindDouble(0, through);
    if (!del.Run()) return false;
  }

  static constexpr char kRebuildSql[] = R"SQL(
    DELETE FROM history_import_keys WHERE url_id IN history_delete_urls
      AND NOT EXISTS (SELECT 1 FROM visits WHERE visits.url_id = history_import_keys.url_id);
    UPDATE urls SET
      visit_count = (SELECT COUNT(*) FROM visits WHERE url_id = urls.id),
      typed_count = (SELECT COUNT(*) FROM visits WHERE url_id = urls.id AND transition = 'typed'),
      last_visit = COALESCE((SELECT MAX(time) FROM visits WHERE url_id = urls.id), 0)
      WHERE id IN history_delete_urls;
    DELETE FROM urls WHERE id IN history_delete_urls AND visit_count = 0;
    DELETE FROM history_delete_urls;
  )SQL";
  if (!db_.Execute(kRebuildSql)) {
    return false;
  }
  if (!txn.Commit()) {
    return false;
  }
  ++deletion_generation_;
  return true;
}

int64_t HistoryStore::UrlCount() {
  if (!Open()) {
    return 0;
  }
  sql::Statement stmt(db_.GetUniqueStatement("SELECT COUNT(*) FROM urls"));
  return stmt.Step() ? stmt.ColumnInt64(0) : 0;
}

// ============================================================================
// ArchiveStore
// ============================================================================

ArchiveStore::ArchiveStore(base::FilePath db_path)
    : db_path_(std::move(db_path)),
      db_(sql::DatabaseOptions().set_exclusive_locking(false),
          sql::Database::Tag("TabStateStorage")) {}

ArchiveStore::~ArchiveStore() {
  Close();
}

bool ArchiveStore::Open() {
  if (closed_) {
    return false;
  }
  if (db_.is_open()) {
    return true;
  }
  if (!base::CreateDirectory(db_path_.DirName())) {
    return false;
  }
  if (!db_.Open(db_path_)) {
    LOG(ERROR) << "ArchiveStore::Open db_.Open failed: " << db_.GetErrorMessage();
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    db_.Close();
    return false;
  }
  static constexpr char kSchema[] = R"SQL(
    CREATE TABLE IF NOT EXISTS archived_tabs(
      id TEXT PRIMARY KEY,
      url TEXT NOT NULL,
      title TEXT NOT NULL,
      space_id TEXT,
      profile_id TEXT,
      archived_at REAL NOT NULL,
      reason TEXT NOT NULL,
      original_location TEXT NOT NULL,
      payload TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'tab'
    );
    CREATE INDEX IF NOT EXISTS idx_archived_at ON archived_tabs(archived_at DESC);
  )SQL";
  if (!db_.Execute(kSchema)) {
    LOG(ERROR) << "ArchiveStore::Open schema failed: " << db_.GetErrorMessage();
    db_.Close();
    return false;
  }
  // Ensure legacy databases missing the `kind` column are migrated.
  bool has_kind = false;
  {
    sql::Statement info(db_.GetUniqueStatement("PRAGMA table_info(archived_tabs)"));
    while (info.Step()) {
      if (info.ColumnString(1) == "kind") {
        has_kind = true;
      }
    }
  }
  if (!has_kind) {
    if (!db_.Execute(
            "ALTER TABLE archived_tabs ADD COLUMN kind TEXT NOT NULL DEFAULT 'tab'")) {
      db_.Close();
      return false;
    }
  }
  if (!txn.Commit()) {
    db_.Close();
    return false;
  }
  // WAL/locking/timeouts are managed by sql::DatabaseOptions.
  return true;
}

void ArchiveStore::Close() {
  closed_ = true;
  db_.Close();
}

bool ArchiveStore::Archive(const ArchivedTabRecord& record) {
  return Archive(std::vector<ArchivedTabRecord>{record});
}

bool ArchiveStore::Archive(const std::vector<ArchivedTabRecord>& records) {
  if (records.empty()) {
    return true;
  }
  if (!Open()) {
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "INSERT OR REPLACE INTO archived_tabs"
      "(id, url, title, space_id, profile_id, archived_at, reason, original_location, payload, kind) "
      "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"));
  for (const ArchivedTabRecord& r : records) {
    stmt.BindString(0, r.id);
    stmt.BindString(1, r.url);
    stmt.BindString(2, r.title);
    if (r.space_id.has_value()) {
      stmt.BindString(3, *r.space_id);
    } else {
      stmt.BindNull(3);
    }
    if (r.profile_id.has_value()) {
      stmt.BindString(4, *r.profile_id);
    } else {
      stmt.BindNull(4);
    }
    stmt.BindDouble(5, r.archived_at);
    stmt.BindString(6, r.reason);
    stmt.BindString(7, r.original_location);
    stmt.BindString(8, r.payload_json.empty() ? "{}" : r.payload_json);
    stmt.BindString(9, r.kind.empty() ? "tab" : r.kind);
    if (!stmt.Run()) {
      return false;
    }
    stmt.Reset(/*clear_bound_vars=*/true);
  }
  return txn.Commit();
}

std::vector<ArchivedTabRecord> ArchiveStore::List(
    int limit,
    int offset,
    const std::string& query,
    const std::optional<SpaceID>& space_id,
    const std::optional<std::string>& reason) {
  if (!Open() || limit <= 0) {
    return {};
  }
  std::string sql_str =
      "SELECT id, url, title, space_id, profile_id, archived_at, reason, "
      "original_location, payload, kind FROM archived_tabs WHERE 1=1";
  if (!query.empty()) {
    sql_str += " AND (title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')";
  }
  if (space_id.has_value()) {
    sql_str += " AND space_id = ?";
  }
  if (reason.has_value()) {
    sql_str += " AND reason = ?";
  }
  sql_str += " ORDER BY archived_at DESC, id LIMIT ? OFFSET ?";

  sql::Statement stmt(db_.GetUniqueStatement(sql_str));
  int bind_idx = 0;
  if (!query.empty()) {
    std::string like = EscapeLikePattern(query);
    stmt.BindString(bind_idx++, like);
    stmt.BindString(bind_idx++, like);
  }
  if (space_id.has_value()) {
    stmt.BindString(bind_idx++, *space_id);
  }
  if (reason.has_value()) {
    stmt.BindString(bind_idx++, *reason);
  }
  stmt.BindInt(bind_idx++, std::clamp(limit, 1, 500));
  stmt.BindInt(bind_idx++, std::max(0, offset));

  std::vector<ArchivedTabRecord> out;
  while (stmt.Step()) {
    ArchivedTabRecord r;
    r.id = stmt.ColumnString(0);
    r.url = stmt.ColumnString(1);
    r.title = stmt.ColumnString(2);
    if (stmt.GetColumnType(3) != sql::ColumnType::kNull) {
      r.space_id = stmt.ColumnString(3);
    }
    if (stmt.GetColumnType(4) != sql::ColumnType::kNull) {
      r.profile_id = stmt.ColumnString(4);
    }
    r.archived_at = stmt.ColumnDouble(5);
    r.reason = stmt.ColumnString(6);
    r.original_location = stmt.ColumnString(7);
    r.payload_json = stmt.ColumnString(8);
    r.kind = stmt.ColumnString(9);
    out.push_back(std::move(r));
  }
  return out;
}

std::optional<ArchivedTabRecord> ArchiveStore::Get(const ItemID& id) {
  if (!Open() || id.empty()) {
    return std::nullopt;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "SELECT id, url, title, space_id, profile_id, archived_at, reason, "
      "original_location, payload, kind FROM archived_tabs WHERE id = ? LIMIT 1"));
  stmt.BindString(0, id);
  if (!stmt.Step()) {
    return std::nullopt;
  }
  ArchivedTabRecord r;
  r.id = stmt.ColumnString(0);
  r.url = stmt.ColumnString(1);
  r.title = stmt.ColumnString(2);
  if (stmt.GetColumnType(3) != sql::ColumnType::kNull) {
    r.space_id = stmt.ColumnString(3);
  }
  if (stmt.GetColumnType(4) != sql::ColumnType::kNull) {
    r.profile_id = stmt.ColumnString(4);
  }
  r.archived_at = stmt.ColumnDouble(5);
  r.reason = stmt.ColumnString(6);
  r.original_location = stmt.ColumnString(7);
  r.payload_json = stmt.ColumnString(8);
  r.kind = stmt.ColumnString(9);
  return r;
}

std::optional<ArchivedTabRecord> ArchiveStore::Restore(const ItemID& id) {
  if (!Open() || id.empty()) {
    return std::nullopt;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return std::nullopt;
  }
  auto rec = Get(id);
  if (!rec.has_value()) {
    return std::nullopt;
  }
  sql::Statement del(db_.GetUniqueStatement("DELETE FROM archived_tabs WHERE id = ?"));
  del.BindString(0, id);
  if (!del.Run() || !txn.Commit()) {
    return std::nullopt;
  }
  return rec;
}

bool ArchiveStore::Delete(const ItemID& id) {
  return DeleteIds({id});
}

bool ArchiveStore::DeleteIds(const std::vector<ItemID>& ids) {
  if (ids.empty()) {
    return true;
  }
  if (!Open()) {
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  sql::Statement stmt(db_.GetUniqueStatement("DELETE FROM archived_tabs WHERE id = ?"));
  for (const ItemID& id : ids) {
    stmt.BindString(0, id);
    if (!stmt.Run()) return false;
    stmt.Reset(/*clear_bound_vars=*/true);
  }
  return txn.Commit();
}

bool ArchiveStore::DeleteAll() {
  if (!Open()) {
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  if (!db_.Execute("DELETE FROM archived_tabs")) {
    return false;
  }
  return txn.Commit();
}

int ArchiveStore::PurgeOlderThanDays(int days, TimestampSec now) {
  if (!Open()) {
    return 0;
  }
  if (now <= 0.0) {
    now = NowSec();
  }
  TimestampSec cutoff = now - static_cast<double>(days) * 86400.0;
  sql::Statement stmt(
      db_.GetUniqueStatement("DELETE FROM archived_tabs WHERE archived_at < ?"));
  stmt.BindDouble(0, cutoff);
  if (!stmt.Run()) {
    return 0;
  }
  return static_cast<int>(db_.GetLastChangeCount());
}

int64_t ArchiveStore::Count() {
  if (!Open()) {
    return 0;
  }
  sql::Statement stmt(db_.GetUniqueStatement("SELECT COUNT(*) FROM archived_tabs"));
  return stmt.Step() ? stmt.ColumnInt64(0) : 0;
}

// ============================================================================
// SleepStore
// ============================================================================

SleepStore::SleepStore(base::FilePath db_path)
    : db_path_(std::move(db_path)),
      db_(sql::DatabaseOptions().set_exclusive_locking(false),
          sql::Database::Tag("TabStateStorage")) {}

SleepStore::~SleepStore() {
  Close();
}

bool SleepStore::Open() {
  if (closed_) {
    return false;
  }
  if (db_.is_open()) {
    return true;
  }
  if (!base::CreateDirectory(db_path_.DirName())) {
    return false;
  }
  if (!db_.Open(db_path_)) {
    LOG(ERROR) << "SleepStore::Open db_.Open failed: " << db_.GetErrorMessage();
    return false;
  }
  static constexpr char kSchema[] = R"SQL(
    CREATE TABLE IF NOT EXISTS sleep_history(
      tab_id TEXT PRIMARY KEY,
      container BLOB NOT NULL,
      current_index INTEGER NOT NULL,
      entry_count INTEGER NOT NULL,
      current_url TEXT NOT NULL,
      current_title TEXT NOT NULL,
      favicon_url TEXT,
      has_page_state INTEGER NOT NULL,
      container_version INTEGER NOT NULL,
      chromium_tag TEXT NOT NULL,
      captured_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sleep_meta(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
  )SQL";
  if (!db_.Execute(kSchema)) {
    LOG(ERROR) << "SleepStore::Open schema failed: " << db_.GetErrorMessage();
    db_.Close();
    return false;
  }
  return true;
}

void SleepStore::Close() {
  closed_ = true;
  db_.Close();
}

bool SleepStore::Save(const SleepHistoryRecord& record) {
  if (record.container.size() > kMaxContainerBytes || record.tab_id.empty()) {
    return false;
  }
  if (!Open()) {
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "INSERT OR REPLACE INTO sleep_history VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"));
  stmt.BindString(0, record.tab_id);
  stmt.BindBlob(1, base::span<const uint8_t>(record.container));
  stmt.BindInt(2, record.current_index);
  stmt.BindInt(3, record.entry_count);
  stmt.BindString(4, record.current_url);
  stmt.BindString(5, record.current_title);
  if (record.favicon_url.has_value()) {
    stmt.BindString(6, *record.favicon_url);
  } else {
    stmt.BindNull(6);
  }
  stmt.BindInt(7, record.has_page_state ? 1 : 0);
  stmt.BindInt(8, record.container_version);
  stmt.BindString(9, record.chromium_tag);
  stmt.BindDouble(10, record.captured_at);
  return stmt.Run() && txn.Commit();
}

std::optional<SleepHistoryRecord> SleepStore::Load(const ItemID& tab_id) {
  if (!Open() || tab_id.empty()) {
    return std::nullopt;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "SELECT container, current_index, entry_count, current_url, current_title, "
      "favicon_url, has_page_state, container_version, chromium_tag, captured_at "
      "FROM sleep_history WHERE tab_id = ?"));
  stmt.BindString(0, tab_id);
  if (!stmt.Step()) {
    return std::nullopt;
  }
  std::vector<uint8_t> blob = ReadBlobColumn(stmt, 0);
  if (blob.size() > kMaxContainerBytes) {
    return std::nullopt;
  }
  SleepHistoryRecord rec;
  rec.tab_id = tab_id;
  rec.container = std::move(blob);
  rec.current_index = stmt.ColumnInt(1);
  rec.entry_count = stmt.ColumnInt(2);
  rec.current_url = stmt.ColumnString(3);
  rec.current_title = stmt.ColumnString(4);
  if (stmt.GetColumnType(5) != sql::ColumnType::kNull) {
    rec.favicon_url = stmt.ColumnString(5);
  }
  rec.has_page_state = stmt.ColumnInt(6) != 0;
  rec.container_version = stmt.ColumnInt(7);
  rec.chromium_tag = stmt.ColumnString(8);
  rec.captured_at = stmt.ColumnDouble(9);
  return rec;
}

bool SleepStore::Delete(const ItemID& tab_id) {
  return DeleteIds({tab_id});
}

bool SleepStore::DeleteIds(const std::vector<ItemID>& tab_ids) {
  if (tab_ids.empty()) {
    return true;
  }
  if (!Open()) {
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  sql::Statement stmt(
      db_.GetUniqueStatement("DELETE FROM sleep_history WHERE tab_id = ?"));
  for (const ItemID& id : tab_ids) {
    stmt.BindString(0, id);
    if (!stmt.Run()) return false;
    stmt.Reset(/*clear_bound_vars=*/true);
  }
  return txn.Commit();
}

std::vector<ItemID> SleepStore::AllTabIds() {
  if (!Open()) {
    return {};
  }
  sql::Statement stmt(
      db_.GetUniqueStatement("SELECT tab_id FROM sleep_history ORDER BY tab_id"));
  std::vector<ItemID> ids;
  while (stmt.Step()) {
    ids.push_back(stmt.ColumnString(0));
  }
  return ids;
}

int64_t SleepStore::TotalBytes() {
  if (!Open()) {
    return 0;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "SELECT COALESCE(SUM(length(container)), 0) FROM sleep_history"));
  return stmt.Step() ? stmt.ColumnInt64(0) : 0;
}

std::optional<std::string> SleepStore::GetMeta(const std::string& key) {
  if (!Open()) {
    return std::nullopt;
  }
  sql::Statement stmt(
      db_.GetUniqueStatement("SELECT value FROM sleep_meta WHERE key = ?"));
  stmt.BindString(0, key);
  if (!stmt.Step()) {
    return std::nullopt;
  }
  return stmt.ColumnString(0);
}

bool SleepStore::SetMeta(const std::string& key, const std::string& value) {
  if (!Open()) {
    return false;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "INSERT OR REPLACE INTO sleep_meta(key, value) VALUES(?, ?)"));
  stmt.BindString(0, key);
  stmt.BindString(1, value);
  return stmt.Run();
}

// ============================================================================
// DownloadHistoryStore
// ============================================================================

DownloadHistoryStore::DownloadHistoryStore(base::FilePath db_path)
    : db_path_(std::move(db_path)),
      db_(sql::DatabaseOptions().set_exclusive_locking(false),
          sql::Database::Tag("DownloadRecord")) {}

DownloadHistoryStore::~DownloadHistoryStore() {
  Close();
}

bool DownloadHistoryStore::Open() {
  if (closed_) {
    return false;
  }
  if (db_.is_open()) {
    return true;
  }
  if (!base::CreateDirectory(db_path_.DirName())) {
    return false;
  }
  if (!db_.Open(db_path_)) {
    LOG(ERROR) << "DownloadHistoryStore::Open db_.Open failed: " << db_.GetErrorMessage();
    return false;
  }
  static constexpr char kSchema[] = R"SQL(
    CREATE TABLE IF NOT EXISTS downloads(
      id TEXT PRIMARY KEY,
      started_at REAL NOT NULL,
      ended_at REAL NOT NULL,
      payload TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS downloads_end ON downloads(ended_at DESC, id);
  )SQL";
  if (!db_.Execute(kSchema)) {
    LOG(ERROR) << "DownloadHistoryStore::Open schema failed: " << db_.GetErrorMessage();
    db_.Close();
    return false;
  }
  return true;
}

void DownloadHistoryStore::Close() {
  closed_ = true;
  db_.Close();
}

bool DownloadHistoryStore::Record(const DownloadRecord& record) {
  if (record.id.empty() || record.filename.empty() || !Open()) {
    return false;
  }
  base::DictValue d;
  d.Set("id", record.id);
  d.Set("url", record.url);
  d.Set("filename", record.filename);
  d.Set("targetPath", record.target_path);
  d.Set("mimeType", record.mime_type);
  d.Set("state", record.state);
  d.Set("receivedBytes", static_cast<double>(record.received_bytes));
  d.Set("totalBytes", static_cast<double>(record.total_bytes));
  d.Set("startedAt", record.started_at);
  d.Set("endedAt", record.ended_at);

  std::string payload;
  if (!base::JSONWriter::Write(d, &payload) ||
      payload.size() > kMaxPayloadBytes) {
    return false;
  }

  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  {
    sql::Statement ins(db_.GetUniqueStatement(
        "INSERT OR REPLACE INTO downloads(id, started_at, ended_at, payload) "
        "VALUES(?, ?, ?, ?)"));
    ins.BindString(0, record.id);
    ins.BindDouble(1, record.started_at);
    ins.BindDouble(2, record.ended_at);
    ins.BindString(3, payload);
    if (!ins.Run()) {
      return false;
    }
  }
  // Enforce hard 1,000-row cap.
  if (!db_.Execute(
          "DELETE FROM downloads WHERE id NOT IN "
          "(SELECT id FROM downloads ORDER BY ended_at DESC, id LIMIT 1000)")) {
    return false;
  }
  return txn.Commit();
}

std::vector<DownloadRecord> DownloadHistoryStore::List(int limit) {
  if (!Open() || limit <= 0) {
    return {};
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "SELECT id, started_at, ended_at, payload FROM downloads "
      "ORDER BY ended_at DESC, id LIMIT ?"));
  stmt.BindInt(0, std::clamp(limit, 1, kMaxRows));
  std::vector<DownloadRecord> rows;
  while (stmt.Step()) {
    std::string payload = stmt.ColumnString(3);
    if (payload.size() > kMaxPayloadBytes) {
      continue;
    }
    auto parsed = base::JSONReader::ReadDict(payload, base::JSON_PARSE_RFC);
    if (!parsed.has_value()) {
      continue;
    }
    DownloadRecord rec;
    rec.id = stmt.ColumnString(0);
    rec.started_at = stmt.ColumnDouble(1);
    rec.ended_at = stmt.ColumnDouble(2);
    if (const std::string* s = parsed->FindString("url")) rec.url = *s;
    if (const std::string* s = parsed->FindString("filename")) rec.filename = *s;
    if (const std::string* s = parsed->FindString("targetPath")) {
      rec.target_path = *s;
    }
    if (const std::string* s = parsed->FindString("mimeType")) {
      rec.mime_type = *s;
    }
    if (const std::string* s = parsed->FindString("state")) rec.state = *s;
    if (auto rb = parsed->FindDouble("receivedBytes")) {
      rec.received_bytes = static_cast<int64_t>(*rb);
    }
    if (auto tb = parsed->FindDouble("totalBytes")) {
      rec.total_bytes = static_cast<int64_t>(*tb);
    }
    rows.push_back(std::move(rec));
  }
  return rows;
}

bool DownloadHistoryStore::Remove(const std::string& id) {
  if (!Open() || id.empty()) {
    return false;
  }
  sql::Statement stmt(
      db_.GetUniqueStatement("DELETE FROM downloads WHERE id = ?"));
  stmt.BindString(0, id);
  return stmt.Run();
}

bool DownloadHistoryStore::Clear(std::optional<TimestampSec> since,
                                 TimestampSec through) {
  if (!Open()) {
    return false;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "DELETE FROM downloads WHERE started_at >= ? AND started_at <= ?"));
  stmt.BindDouble(0, since.value_or(-1e18));
  stmt.BindDouble(1, through);
  return stmt.Run();
}

// ============================================================================
// FaviconStore
// ============================================================================

FaviconStore::FaviconStore(base::FilePath db_path)
    : db_path_(std::move(db_path)),
      db_(sql::DatabaseOptions().set_exclusive_locking(false),
          sql::Database::Tag("Thumbnail")) {}

FaviconStore::~FaviconStore() {
  Close();
}

bool FaviconStore::Open() {
  if (closed_) {
    return false;
  }
  if (db_.is_open()) {
    return true;
  }
  if (!base::CreateDirectory(db_path_.DirName())) {
    return false;
  }
  if (auto file_size = base::GetFileSize(db_path_);
      file_size.has_value() && *file_size > kMaxDatabaseBytes) {
    return false;
  }
  if (!db_.Open(db_path_)) {
    LOG(ERROR) << "FaviconStore::Open db_.Open failed: " << db_.GetErrorMessage();
    return false;
  }
  static constexpr char kSchema[] = R"SQL(
    CREATE TABLE IF NOT EXISTS favicons(
      origin TEXT NOT NULL,
      page_key TEXT NOT NULL,
      icon_url TEXT,
      png32 BLOB,
      png64 BLOB,
      fetched_at REAL NOT NULL,
      expires_at REAL NOT NULL,
      status INTEGER NOT NULL,
      copy_token TEXT,
      image_info TEXT,
      PRIMARY KEY(origin, page_key)
    );
    CREATE INDEX IF NOT EXISTS favicon_age ON favicons(fetched_at);
  )SQL";
  if (!db_.Execute(kSchema)) {
    LOG(ERROR) << "FaviconStore::Open schema failed: " << db_.GetErrorMessage();
    db_.Close();
    return false;
  }
  return EnforceLimits(0, 0);
}

void FaviconStore::Close() {
  closed_ = true;
  db_.Close();
}

std::optional<FaviconRecord> FaviconStore::Get(const std::string& page_url) {
  auto key = ExtractOriginAndPageKey(page_url);
  if (!key.has_value() || !Open()) {
    return std::nullopt;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "SELECT png32, png64, icon_url, fetched_at, expires_at, status "
      "FROM favicons "
      "WHERE origin = ? AND page_key IN (?, '') AND status = 0 "
      "AND png32 IS NOT NULL AND length(png32) <= 32768 "
      "AND COALESCE(length(png64), 0) <= 32768 "
      "ORDER BY length(page_key) DESC LIMIT 1"));
  stmt.BindString(0, key->first);
  stmt.BindString(1, key->second);
  if (!stmt.Step()) {
    return std::nullopt;
  }
  FaviconRecord rec;
  rec.png32 = ReadBlobColumn(stmt, 0);
  rec.png64 = ReadBlobColumn(stmt, 1);
  if (stmt.GetColumnType(2) != sql::ColumnType::kNull) {
    rec.icon_url = stmt.ColumnString(2);
  }
  rec.fetched_at = stmt.ColumnDouble(3);
  rec.expires_at = stmt.ColumnDouble(4);
  rec.status = stmt.ColumnInt(5);
  return rec;
}

bool FaviconStore::Put(const std::string& page_url,
                       const std::vector<uint8_t>& png32,
                       const std::vector<uint8_t>& png64,
                       const std::optional<std::string>& icon_url,
                       bool page_specific,
                       double lifetime_sec) {
  auto key = ExtractOriginAndPageKey(page_url);
  if (!key.has_value() || png32.empty() || png32.size() > 32768 ||
      png64.size() > 32768 || !Open()) {
    return false;
  }
  const std::string& origin = key->first;
  const std::string page_key = page_specific ? key->second : std::string();
  int64_t reserved_bytes =
      static_cast<int64_t>(2 * (origin.size() + page_key.size()) +
                           (icon_url ? icon_url->size() : 0) + png32.size() +
                           png64.size() + 512);

  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  if (!EnforceLimits(reserved_bytes, 1)) {
    return false;
  }
  TimestampSec now = NowSec();
  sql::Statement stmt(db_.GetUniqueStatement(
      "INSERT OR REPLACE INTO favicons(origin, page_key, icon_url, png32, png64, "
      "fetched_at, expires_at, status, copy_token, image_info) "
      "VALUES(?, ?, ?, ?, ?, ?, ?, 0, NULL, NULL)"));
  stmt.BindString(0, origin);
  stmt.BindString(1, page_key);
  if (icon_url.has_value()) {
    stmt.BindString(2, *icon_url);
  } else {
    stmt.BindNull(2);
  }
  stmt.BindBlob(3, base::span<const uint8_t>(png32));
  if (!png64.empty()) {
    stmt.BindBlob(4, base::span<const uint8_t>(png64));
  } else {
    stmt.BindNull(4);
  }
  stmt.BindDouble(5, now);
  stmt.BindDouble(6, now + lifetime_sec);
  return stmt.Run() && txn.Commit();
}

bool FaviconStore::MarkMissing(const std::string& page_url) {
  auto key = ExtractOriginAndPageKey(page_url);
  if (!key.has_value() || !Open()) {
    return false;
  }
  sql::Transaction txn(&db_);
  if (!txn.Begin()) {
    return false;
  }
  if (!EnforceLimits(512, 1)) {
    return false;
  }
  TimestampSec now = NowSec();
  sql::Statement stmt(db_.GetUniqueStatement(
      "INSERT OR REPLACE INTO favicons(origin, page_key, icon_url, png32, png64, "
      "fetched_at, expires_at, status, copy_token, image_info) "
      "VALUES(?, '', NULL, NULL, NULL, ?, ?, 1, NULL, NULL)"));
  stmt.BindString(0, key->first);
  stmt.BindDouble(1, now);
  stmt.BindDouble(2, now + 86400.0);
  return stmt.Run() && txn.Commit();
}

int FaviconStore::PurgeOlderThan(TimestampSec cutoff) {
  if (!Open()) {
    return 0;
  }
  sql::Statement stmt(
      db_.GetUniqueStatement("DELETE FROM favicons WHERE fetched_at < ?"));
  stmt.BindDouble(0, cutoff);
  if (!stmt.Run()) {
    return 0;
  }
  return static_cast<int>(db_.GetLastChangeCount());
}

int64_t FaviconStore::Count() {
  if (!Open()) {
    return 0;
  }
  sql::Statement stmt(db_.GetUniqueStatement("SELECT COUNT(*) FROM favicons"));
  return stmt.Step() ? stmt.ColumnInt64(0) : 0;
}

int64_t FaviconStore::TotalStoredBytes() {
  if (!Open()) {
    return 0;
  }
  sql::Statement stmt(db_.GetUniqueStatement(
      "SELECT COALESCE(SUM(COALESCE(length(png32), 0) + COALESCE(length(png64), 0)), 0) "
      "FROM favicons"));
  return stmt.Step() ? stmt.ColumnInt64(0) : 0;
}

bool FaviconStore::EnforceLimits(int64_t reserved_bytes, int reserved_count) {
  sql::Statement usage(db_.GetUniqueStatement(
      "SELECT COUNT(*), COALESCE(SUM("
      "2 * (length(CAST(origin AS BLOB)) + length(CAST(page_key AS BLOB))) + "
      "COALESCE(length(CAST(icon_url AS BLOB)), 0) + "
      "COALESCE(length(png32), 0) + COALESCE(length(png64), 0) + 512), 0) "
      "FROM favicons"));
  for (int i = 0; i <= kMaxEntries; ++i) {
    if (!usage.Step()) {
      return false;
    }
    int64_t cnt = usage.ColumnInt64(0);
    int64_t bytes = usage.ColumnInt64(1);
    usage.Reset(/*clear_bound_vars=*/true);
    if (cnt + reserved_count <= kMaxEntries &&
        bytes + reserved_bytes <= kMaxStoredBytes) {
      return true;
    }
    if (!db_.Execute(
            "DELETE FROM favicons WHERE rowid = "
            "(SELECT rowid FROM favicons ORDER BY fetched_at, rowid LIMIT 1)")) {
      return false;
    }
  }
  return false;
}

}  // namespace open_unified
