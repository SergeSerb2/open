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
    public var undo: HistoryImportUndo?
}

/// Only rows committed by this batch, never duplicate keys or later live visits.
/// A reader batch contains at most 5,000 visits. Values share their String storage.
public struct HistoryImportUndo: Sendable {
    public struct TitleChange: Sendable {
        public let urlID: Int64
        public let previous: String
        public let imported: String
    }
    public let sourceProfileKey: String
    public let visits: [ImportedHistoryVisit]
    public let redoVisits: [ImportedHistoryVisit]
    public let visitIDs: [Int64]
    public let createdURLIDs: [Int64]
    public let titleChanges: [TitleChange]
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
            ON CONFLICT(url) DO NOTHING;
            """,
            "SELECT id, title FROM urls WHERE url = ?",
            "INSERT OR IGNORE INTO history_import_keys(visit_key, url_id) VALUES(?, ?)",
            "INSERT INTO visits(url_id, time, transition) VALUES(?, ?, ?)",
            """
            UPDATE urls SET
              visit_count = (SELECT COUNT(*) FROM visits WHERE visits.url_id = urls.id),
              typed_count = (SELECT COUNT(*) FROM visits WHERE visits.url_id = urls.id AND visits.transition = 'typed'),
              last_visit = COALESCE((SELECT MAX(time) FROM visits WHERE visits.url_id = urls.id), 0)
            WHERE urls.id = ?;
            """,
            "UPDATE urls SET title = ? WHERE url = ? AND ? <> '' AND title <> ?",
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
        var createdURLIDs: [Int64] = []
        var titleChanges: [HistoryImportUndo.TitleChange] = []
        for url in orderedURLs {
            let upsert = statements[0], select = statements[1]
            guard text(upsert, 1, url), text(upsert, 2, titles[url] ?? ""),
                  sqlite3_step(upsert) == SQLITE_DONE else { return .init() }
            let created = db.changes == 1
            guard reset(upsert),
                  text(select, 1, url), sqlite3_step(select) == SQLITE_ROW else { return .init() }
            let id = sqlite3_column_int64(select, 0)
            let previousTitle = db.columnText(select, 1) ?? ""
            urlIDs[url] = id
            if created { createdURLIDs.append(id) }
            guard reset(select) else { return .init() }
            if !created, let title = titles[url], !title.isEmpty, title != previousTitle {
                let update = statements[5]
                guard text(update, 1, title), text(update, 2, url), text(update, 3, title), text(update, 4, title),
                      sqlite3_step(update) == SQLITE_DONE, reset(update) else { return .init() }
                titleChanges.append(.init(urlID: id, previous: previousTitle, imported: title))
            }
        }

        var result = HistoryImportBatchResult()
        var affected: Set<Int64> = []
        var insertedVisits: [ImportedHistoryVisit] = []
        var visitIDs: [Int64] = []
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
            insertedVisits.append(visit); visitIDs.append(db.lastInsertRowID)
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
        if !insertedVisits.isEmpty || !createdURLIDs.isEmpty || !titleChanges.isEmpty {
            result.undo = HistoryImportUndo(sourceProfileKey: sourceProfileKey, visits: insertedVisits,
                                           redoVisits: visits, visitIDs: visitIDs, createdURLIDs: createdURLIDs,
                                           titleChanges: titleChanges)
            didChange()
        }
        return result
    }

    /// One actor-confined transaction. Exact destination row IDs and import
    /// keys protect unrelated visits even when URL, time and transition match.
    public func removeImportedHistory(_ receipt: HistoryImportUndo) -> Bool {
        open()
        guard let db, receipt.visits.count == receipt.visitIDs.count, db.exec("BEGIN IMMEDIATE") else { return false }
        var committed = false
        defer { if !committed { db.exec("ROLLBACK") } }
        let queries = [
            "SELECT k.url_id FROM history_import_keys k JOIN visits v ON v.url_id=k.url_id WHERE k.visit_key=? AND v.id=? AND v.time=? AND v.transition=?",
            "DELETE FROM visits WHERE id=?",
            "DELETE FROM history_import_keys WHERE visit_key=?",
            """
            UPDATE urls SET visit_count=(SELECT count(*) FROM visits WHERE url_id=urls.id),
              typed_count=(SELECT count(*) FROM visits WHERE url_id=urls.id AND transition='typed'),
              last_visit=COALESCE((SELECT max(time) FROM visits WHERE url_id=urls.id),0) WHERE id=?
            """,
            "DELETE FROM urls WHERE id=? AND NOT EXISTS(SELECT 1 FROM visits WHERE url_id=urls.id) AND NOT EXISTS(SELECT 1 FROM history_import_keys WHERE url_id=urls.id)",
            "UPDATE urls SET title=? WHERE id=? AND title=?"
        ]
        var statements: [OpaquePointer] = []
        defer { for statement in statements { sqlite3_finalize(statement) } }
        for query in queries {
            guard let statement = db.prepare(query) else { return false }
            statements.append(statement)
        }
        func reset(_ statement: OpaquePointer) { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        var affected = Set<Int64>()
        for (visit, id) in zip(receipt.visits, receipt.visitIDs) {
            let key = "\(receipt.sourceProfileKey):\(visit.chromiumVisitID)", check = statements[0]
            db.bindText(check, 1, key); db.bindInt(check, 2, id)
            db.bindDouble(check, 3, visit.time.timeIntervalSince1970); db.bindText(check, 4, visit.transition)
            let status = sqlite3_step(check)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { return false }
            if status == SQLITE_ROW {
                affected.insert(db.columnInt(check, 0))
                db.bindInt(statements[1], 1, id)
                guard sqlite3_step(statements[1]) == SQLITE_DONE else { return false }; reset(statements[1])
                db.bindText(statements[2], 1, key)
                guard sqlite3_step(statements[2]) == SQLITE_DONE else { return false }; reset(statements[2])
            }
            reset(check)
        }
        for id in affected {
            db.bindInt(statements[3], 1, id)
            guard sqlite3_step(statements[3]) == SQLITE_DONE else { return false }; reset(statements[3])
        }
        for id in receipt.createdURLIDs {
            db.bindInt(statements[4], 1, id)
            guard sqlite3_step(statements[4]) == SQLITE_DONE else { return false }; reset(statements[4])
        }
        // A normal navigation may have supplied a newer title after import.
        // Restore only the value still owned by this batch.
        for change in receipt.titleChanges {
            db.bindText(statements[5], 1, change.previous); db.bindInt(statements[5], 2, change.urlID)
            db.bindText(statements[5], 3, change.imported)
            guard sqlite3_step(statements[5]) == SQLITE_DONE else { return false }; reset(statements[5])
        }
        guard db.exec("COMMIT") else { return false }
        committed = true
        if !affected.isEmpty || !receipt.titleChanges.isEmpty { didChange() }
        return true
    }
}
