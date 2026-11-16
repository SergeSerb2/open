import Foundation
import SQLite3

public struct HistoryMatch: Sendable {
    public var url: URL
    public var title: String
    public var visitCount: Int
    public var typedCount: Int
    public var lastVisit: Date
    public var score: Double
}

/// SQLite + FTS5 history. All access runs inside this actor (off the main thread).
/// Budget: < 5 ms search on a 100k-URL database (FTS5 prefix index + frecency sort).
public actor HistoryStore {
    var db: SQLiteDB?
    public let fileURL: URL
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Set by `close()`: the store never opens (or recreates) its file again.
    private var closed = false

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// Event driven, with one pending invalidation per subscriber. No idle work.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    func didChange() { for observer in observers.values { observer.yield(()) } }

    /// Closes the database for good (its Profile was deleted). Later calls
    /// read nothing and write nothing, and never recreate the file.
    public func close() {
        closed = true
        db = nil
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    public func open() {
        guard db == nil, !closed else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try? SQLiteDB(path: fileURL.path)
        db?.exec("""
        CREATE TABLE IF NOT EXISTS urls(
          id INTEGER PRIMARY KEY, url TEXT UNIQUE NOT NULL, title TEXT NOT NULL DEFAULT '',
          visit_count INTEGER NOT NULL DEFAULT 0, typed_count INTEGER NOT NULL DEFAULT 0,
          last_visit REAL NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS visits(
          id INTEGER PRIMARY KEY, url_id INTEGER NOT NULL REFERENCES urls(id),
          time REAL NOT NULL, transition TEXT NOT NULL DEFAULT 'link');
        CREATE INDEX IF NOT EXISTS idx_visits_time ON visits(time DESC);
        CREATE TABLE IF NOT EXISTS history_import_keys(
          visit_key TEXT PRIMARY KEY NOT NULL,
          url_id INTEGER NOT NULL REFERENCES urls(id));
        CREATE INDEX IF NOT EXISTS idx_visits_url_time ON visits(url_id, time);
        CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(title, url, content='urls', content_rowid='id');
        CREATE TRIGGER IF NOT EXISTS urls_ai AFTER INSERT ON urls BEGIN
          INSERT INTO history_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
        END;
        CREATE TRIGGER IF NOT EXISTS urls_au AFTER UPDATE OF title, url ON urls BEGIN
          INSERT INTO history_fts(history_fts, rowid, title, url) VALUES('delete', old.id, old.title, old.url);
          INSERT INTO history_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
        END;
        CREATE TRIGGER IF NOT EXISTS urls_ad AFTER DELETE ON urls BEGIN
          INSERT INTO history_fts(history_fts, rowid, title, url) VALUES('delete', old.id, old.title, old.url);
        END;
        """)
    }

    @discardableResult
    public func recordVisit(url: URL, title: String, time: Date = Date(), transition: String = "link", typed: Bool = false) -> Int64? {
        open()
        guard let db else { return nil }
        db.exec("BEGIN")
        let upsert = db.prepare("INSERT INTO urls(url,title,visit_count,typed_count,last_visit) VALUES(?,?,1,?,?) ON CONFLICT(url) DO UPDATE SET title=CASE WHEN excluded.title<>'' THEN excluded.title ELSE urls.title END, visit_count=urls.visit_count+1, typed_count=urls.typed_count+excluded.typed_count, last_visit=excluded.last_visit")
        db.bindText(upsert, 1, url.absoluteString)
        db.bindText(upsert, 2, title)
        db.bindInt(upsert, 3, typed ? 1 : 0)
        db.bindDouble(upsert, 4, time.timeIntervalSince1970)
        sqlite3_step(upsert)
        sqlite3_finalize(upsert)
        let sel = db.prepare("SELECT id FROM urls WHERE url = ?")
        db.bindText(sel, 1, url.absoluteString)
        var urlID: Int64 = 0
        if sqlite3_step(sel) == SQLITE_ROW { urlID = db.columnInt(sel, 0) }
        sqlite3_finalize(sel)
        let visit = db.prepare("INSERT INTO visits(url_id,time,transition) VALUES(?,?,?)")
        db.bindInt(visit, 1, urlID)
        db.bindDouble(visit, 2, time.timeIntervalSince1970)
        db.bindText(visit, 3, transition)
        let recorded = sqlite3_step(visit) == SQLITE_DONE
        let visitID = db.lastInsertRowID
        sqlite3_finalize(visit)
        guard recorded, db.exec("COMMIT") else { db.exec("ROLLBACK"); return nil }
        didChange()
        return visitID
    }

    /// Bulk insert for bench/import. One transaction, FTS kept in sync by triggers.
    public func recordVisitsBulk(_ items: [(url: URL, title: String, time: Date)]) {
        open()
        guard let db else { return }
        db.exec("BEGIN")
        let stmt = db.prepare("INSERT INTO urls(url,title,visit_count,typed_count,last_visit) VALUES(?,?,1,0,?) ON CONFLICT(url) DO UPDATE SET visit_count=urls.visit_count+1, last_visit=excluded.last_visit")
        for item in items {
            db.bindText(stmt, 1, item.url.absoluteString)
            db.bindText(stmt, 2, item.title)
            db.bindDouble(stmt, 3, item.time.timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_finalize(stmt)
        db.exec("COMMIT")
    }

    public func urlCount() -> Int {
        open()
        guard let db else { return 0 }
        let stmt = db.prepare("SELECT COUNT(*) FROM urls")
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(db.columnInt(stmt, 0)) }
        return 0
    }

    /// Frecency search: FTS5 prefix match on title/url, ranked by frecency
    /// (visit_count + 3*typed_count, decayed by age). Falls back to LIKE for
    /// inputs FTS cannot parse.
    public func search(_ text: String, limit: Int = 20) async -> [HistoryMatch] {
        open()
        guard let db else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return top(limit: limit, db: db)
        }
        // Build a safe FTS query: split on non-alphanumerics so "site-123"
        // matches the FTS tokens `site` and `123`; each piece is a prefix term.
        let tokens = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return top(limit: limit, db: db) }
        let ftsQuery = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        let now = Date().timeIntervalSince1970
        let stmt = db.prepare("SELECT u.url, u.title, u.visit_count, u.typed_count, u.last_visit FROM history_fts f JOIN urls u ON u.id = f.rowid WHERE history_fts MATCH ? ORDER BY (u.visit_count + 3*u.typed_count) * (1.0 / (1.0 + (CAST(? AS REAL) - u.last_visit) / 86400.0)) DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, ftsQuery)
        db.bindDouble(stmt, 2, now)
        db.bindInt(stmt, 3, Int64(limit))
        var rows: [HistoryMatch] = []
        var ok = true
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                guard let urlS = db.columnText(stmt, 0), let url = URL(string: urlS) else { continue }
                let visits = Int(db.columnInt(stmt, 2))
                let typed = Int(db.columnInt(stmt, 3))
                let last = db.columnDouble(stmt, 4)
                let ageDays = max(0, (now - last) / 86400)
                let score = Double(visits + 3 * typed) / (1 + ageDays)
                rows.append(HistoryMatch(url: url, title: db.columnText(stmt, 1) ?? "", visitCount: visits, typedCount: typed, lastVisit: Date(timeIntervalSince1970: last), score: score))
            } else {
                if rc != SQLITE_DONE { ok = false }
                break
            }
        }
        if ok && !rows.isEmpty { return rows }
        if !ok || rows.isEmpty {
            // Fallback: substring search (covers mid-word matches FTS prefixes miss).
            return substringSearch(trimmed, limit: limit, db: db, now: now)
        }
        return rows
    }

    private func top(limit: Int, db: SQLiteDB) -> [HistoryMatch] {
        let now = Date().timeIntervalSince1970
        let stmt = db.prepare("SELECT url,title,visit_count,typed_count,last_visit FROM urls ORDER BY visit_count + 3*typed_count DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        db.bindInt(stmt, 1, Int64(limit))
        var rows: [HistoryMatch] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlS = db.columnText(stmt, 0), let url = URL(string: urlS) else { continue }
            let visits = Int(db.columnInt(stmt, 2)); let typed = Int(db.columnInt(stmt, 3)); let last = db.columnDouble(stmt, 4)
            let score = Double(visits + 3 * typed) / (1 + max(0, (now - last) / 86400))
            rows.append(HistoryMatch(url: url, title: db.columnText(stmt, 1) ?? "", visitCount: visits, typedCount: typed, lastVisit: Date(timeIntervalSince1970: last), score: score))
        }
        return rows
    }

    private func substringSearch(_ text: String, limit: Int, db: SQLiteDB, now: Double) -> [HistoryMatch] {
        let like = "%\(text)%"
        let stmt = db.prepare("SELECT url,title,visit_count,typed_count,last_visit FROM urls WHERE title LIKE ? OR url LIKE ? ORDER BY visit_count + 3*typed_count DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, like); db.bindText(stmt, 2, like); db.bindInt(stmt, 3, Int64(limit))
        var rows: [HistoryMatch] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlS = db.columnText(stmt, 0), let url = URL(string: urlS) else { continue }
            let visits = Int(db.columnInt(stmt, 2)); let typed = Int(db.columnInt(stmt, 3)); let last = db.columnDouble(stmt, 4)
            let score = Double(visits + 3 * typed) / (1 + max(0, (now - last) / 86400))
            rows.append(HistoryMatch(url: url, title: db.columnText(stmt, 1) ?? "", visitCount: visits, typedCount: typed, lastVisit: Date(timeIntervalSince1970: last), score: score))
        }
        return rows
    }
}
