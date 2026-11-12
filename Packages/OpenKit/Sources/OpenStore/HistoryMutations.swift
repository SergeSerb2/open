import Foundation
import SQLite3

extension HistoryStore {
    /// Library's empty query is chronological; command-bar frecency is unchanged.
    public func recent(limit: Int = 100, offset: Int = 0) -> [HistoryMatch] {
        open()
        guard let db else { return [] }
        let statement = db.prepare("SELECT url,title,visit_count,typed_count,last_visit FROM urls ORDER BY last_visit DESC, id DESC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(statement) }
        db.bindInt(statement, 1, Int64(max(0, min(limit, 1_000))))
        db.bindInt(statement, 2, Int64(max(0, offset)))
        var rows: [HistoryMatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = db.columnText(statement, 0), let url = URL(string: text) else { continue }
            rows.append(HistoryMatch(url: url, title: db.columnText(statement, 1) ?? "",
                visitCount: Int(db.columnInt(statement, 2)), typedCount: Int(db.columnInt(statement, 3)),
                lastVisit: Date(timeIntervalSince1970: db.columnDouble(statement, 4)), score: 0))
        }
        return rows
    }

    /// A cleared visit must never recreate a URL through a late title callback.
    /// An older document also must not replace a newer visit's title.
    public func updateTitle(_ title: String, visitID: Int64, time: Date) {
        guard !title.isEmpty, let db else { return }
        let statement = db.prepare("""
        UPDATE urls SET title = ? WHERE title <> ? AND id =
          (SELECT url_id FROM visits WHERE id = ? AND time = ?) AND
          ? = (SELECT MAX(v.id) FROM visits v WHERE v.url_id = urls.id)
        """)
        defer { sqlite3_finalize(statement) }
        db.bindText(statement, 1, title); db.bindText(statement, 2, title)
        db.bindInt(statement, 3, visitID); db.bindDouble(statement, 4, time.timeIntervalSince1970); db.bindInt(statement, 5, visitID)
        if sqlite3_step(statement) == SQLITE_DONE, db.changes > 0 { didChange() }
    }

    /// Both bounds are captured by the caller when the user confirms clearing.
    /// Only affected URL aggregates are rebuilt; import/bench rows are left alone.
    public func deleteVisits(since start: Date? = nil, through end: Date = Date(), urls: [URL]? = nil) throws {
        open()
        guard let db, db.exec("BEGIN IMMEDIATE") else { throw HistoryMutationError.unavailable }
        do {
            guard db.exec("CREATE TEMP TABLE IF NOT EXISTS history_delete_urls(id INTEGER PRIMARY KEY); DELETE FROM history_delete_urls") else { throw HistoryMutationError.unavailable }
            if let urls {
                let insert = db.prepare("INSERT OR IGNORE INTO history_delete_urls SELECT id FROM urls WHERE url = ?")
                defer { sqlite3_finalize(insert) }
                for url in urls {
                    db.bindText(insert, 1, url.absoluteString)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw HistoryMutationError.unavailable }
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                }
                guard db.exec("DELETE FROM visits WHERE url_id IN history_delete_urls") else { throw HistoryMutationError.unavailable }
            } else if let start {
                let select = db.prepare("INSERT INTO history_delete_urls SELECT DISTINCT url_id FROM visits WHERE time >= ? AND time <= ?")
                db.bindDouble(select, 1, start.timeIntervalSince1970); db.bindDouble(select, 2, end.timeIntervalSince1970)
                let selected = sqlite3_step(select) == SQLITE_DONE; sqlite3_finalize(select)
                guard selected else { throw HistoryMutationError.unavailable }
                let remove = db.prepare("DELETE FROM visits WHERE time >= ? AND time <= ?")
                db.bindDouble(remove, 1, start.timeIntervalSince1970); db.bindDouble(remove, 2, end.timeIntervalSince1970)
                let removed = sqlite3_step(remove) == SQLITE_DONE; sqlite3_finalize(remove)
                guard removed else { throw HistoryMutationError.unavailable }
            } else {
                guard db.exec("INSERT INTO history_delete_urls SELECT id FROM urls; DELETE FROM visits") else { throw HistoryMutationError.unavailable }
            }
            guard db.exec("""
            DELETE FROM history_import_keys WHERE url_id IN history_delete_urls
              AND NOT EXISTS (SELECT 1 FROM visits WHERE visits.url_id = history_import_keys.url_id);
            UPDATE urls SET
              visit_count = (SELECT COUNT(*) FROM visits WHERE url_id = urls.id),
              typed_count = (SELECT COUNT(*) FROM visits WHERE url_id = urls.id AND transition = 'typed'),
              last_visit = COALESCE((SELECT MAX(time) FROM visits WHERE url_id = urls.id), 0)
              WHERE id IN history_delete_urls;
            DELETE FROM urls WHERE id IN history_delete_urls AND visit_count = 0;
            DELETE FROM history_delete_urls;
            COMMIT;
            """) else { throw HistoryMutationError.unavailable }
            didChange()
        } catch { db.exec("ROLLBACK"); throw error }
    }
}

private enum HistoryMutationError: LocalizedError {
    case unavailable
    var errorDescription: String? { "History could not be changed." }
}
