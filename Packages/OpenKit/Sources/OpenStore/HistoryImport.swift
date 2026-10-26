import Foundation
import SQLite3

public struct ImportedHistoryVisit: Sendable {
    public var chromiumVisitID: Int64
    public var urlString: String
    public var title: String
    public var time: Date
    public var transition: String
    public var isTyped: Bool

    public init(chromiumVisitID: Int64, urlString: String, title: String, time: Date, transition: String, isTyped: Bool) {
        self.chromiumVisitID = chromiumVisitID
        self.urlString = urlString
        self.title = title
        self.time = time
        self.transition = transition
        self.isTyped = isTyped
    }
}

public struct HistoryImportBatchResult: Sendable {
    public var succeeded: Bool = false
    public var insertedVisits: Int = 0
    public var duplicateVisits: Int = 0
    public var affectedURLs: Int = 0
}

extension HistoryStore {
    /// One atomic batch. Zero counts on failure let the caller fail its accounting check.
    public func importHistoryBatch(_ visits: [ImportedHistoryVisit], sourceProfileKey: String) -> HistoryImportBatchResult {
        open()
        guard let db, db.exec("BEGIN IMMEDIATE") else { return .init() }
        var committed = false
        defer { if !committed { db.exec("ROLLBACK") } }

        let sql = [
            """
            INSERT INTO urls(url, title, visit_count, typed_count, last_visit) VALUES(?, ?, 0, 0, 0)
            ON CONFLICT(url) DO UPDATE SET
              title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE urls.title END
            WHERE excluded.title <> '' AND excluded.title <> urls.title;
            """,
            "SELECT id FROM urls WHERE url = ?",
            "INSERT OR IGNORE INTO history_import_keys(visit_key, url_id) VALUES(?, ?)",
            "INSERT INTO visits(url_id, time, transition) VALUES(?, ?, ?)",
            """
            UPDATE urls SET
              visit_count = (SELECT COUNT(*) FROM visits WHERE visits.url_id = urls.id),
              typed_count = (SELECT COUNT(*) FROM visits WHERE visits.url_id = urls.id AND visits.transition = 'typed'),
              last_visit = COALESCE((SELECT MAX(time) FROM visits WHERE visits.url_id = urls.id), 0)
            WHERE urls.id = ?;
            """,
        ]
        var statements: [OpaquePointer] = []
        defer { for statement in statements { sqlite3_finalize(statement) } }
        for query in sql {
            guard let statement = db.prepare(query) else { return .init() }
            statements.append(statement)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func text(_ statement: OpaquePointer, _ index: Int32, _ value: String) -> Bool {
            sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK
        }
        func reset(_ statement: OpaquePointer) -> Bool {
            let result = sqlite3_reset(statement)
            return sqlite3_clear_bindings(statement) == SQLITE_OK && result == SQLITE_OK
        }

        var orderedURLs: [String] = []
        var titles: [String: String] = [:]
        for visit in visits {
            if titles[visit.urlString] == nil {
                orderedURLs.append(visit.urlString)
                titles[visit.urlString] = visit.title
            } else if !visit.title.isEmpty {
                titles[visit.urlString] = visit.title
            }
        }
        var urlIDs: [String: Int64] = [:]
        for url in orderedURLs {
            let upsert = statements[0], select = statements[1]
            guard text(upsert, 1, url), text(upsert, 2, titles[url] ?? ""),
                  sqlite3_step(upsert) == SQLITE_DONE, reset(upsert),
                  text(select, 1, url), sqlite3_step(select) == SQLITE_ROW else { return .init() }
            urlIDs[url] = sqlite3_column_int64(select, 0)
            guard reset(select) else { return .init() }
        }

        var result = HistoryImportBatchResult()
        var affected: Set<Int64> = []
        for visit in visits {
            guard let urlID = urlIDs[visit.urlString] else { return .init() }
            let key = statements[2]
            guard text(key, 1, "\(sourceProfileKey):\(visit.chromiumVisitID)"),
                  sqlite3_bind_int64(key, 2, urlID) == SQLITE_OK,
                  sqlite3_step(key) == SQLITE_DONE else { return .init() }
            let inserted = db.changes == 1
            guard reset(key) else { return .init() }
            if !inserted { result.duplicateVisits += 1; continue }
            let insert = statements[3]
            guard sqlite3_bind_int64(insert, 1, urlID) == SQLITE_OK,
                  sqlite3_bind_double(insert, 2, visit.time.timeIntervalSince1970) == SQLITE_OK,
                  text(insert, 3, visit.transition), sqlite3_step(insert) == SQLITE_DONE,
                  reset(insert) else { return .init() }
            result.insertedVisits += 1
            affected.insert(urlID)
        }
        for urlID in affected {
            let update = statements[4]
            guard sqlite3_bind_int64(update, 1, urlID) == SQLITE_OK,
                  sqlite3_step(update) == SQLITE_DONE, reset(update) else { return .init() }
        }
        guard db.exec("COMMIT") else { return .init() }
        committed = true
        result.succeeded = true
        result.affectedURLs = affected.count
        return result
    }
}
