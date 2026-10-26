import Foundation
import OpenModel
import SQLite3

/// Values copied off the main actor for one archive row.
private struct ArchiveRow: Sendable {
    let id: String
    let url: String
    let title: String
    let spaceID: String?
    let profileID: String?
    let archivedAt: Double
    let reason: String
    let originalLocation: String
    let payload: TabDTO
}

/// SQLite archive. The sink entry point runs on the main actor and snapshots
/// values there; every SQLite statement runs on a private serial queue.
@MainActor
public final class ArchiveStore: ArchiveSink {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "open.archive", qos: .utility)
    nonisolated(unsafe) private var db: SQLiteDB?

    public init(root: URL) {
        self.fileURL = root.appendingPathComponent("State/archive.sqlite3")
    }

    nonisolated private func openOnQueue() {
        guard db == nil else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try? SQLiteDB(path: fileURL.path)
        db?.exec("""
        CREATE TABLE IF NOT EXISTS archived_tabs(
          id TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL,
          space_id TEXT, profile_id TEXT, archived_at REAL NOT NULL,
          reason TEXT NOT NULL, original_location TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_archived_at ON archived_tabs(archived_at DESC);
        """)
    }

    /// Snapshots the tabs on the main actor. JSON encoding and one SQLite transaction run on the queue.
    public func archive(_ entries: [ArchiveEntry]) {
        guard !entries.isEmpty else { return }
        let rows = entries.map { entry in
            ArchiveRow(id: entry.tab.id.rawValue.uuidString, url: entry.tab.url.absoluteString, title: entry.tab.displayTitle,
                       spaceID: entry.spaceID?.rawValue.uuidString, profileID: entry.profileID?.rawValue.uuidString,
                       archivedAt: entry.archivedAt.timeIntervalSince1970, reason: entry.reason.rawValue,
                       originalLocation: entry.originalLocation, payload: SnapshotMapper.tabDTO(entry.tab))
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.openOnQueue()
            self.insertOnQueue(rows)
        }
    }

    public func discardArchived(ids: [ItemID]) {
        guard !ids.isEmpty else { return }
        let keys = ids.map { $0.rawValue.uuidString }
        queue.async { [weak self] in
            guard let self else { return }
            self.openOnQueue()
            guard let db = self.db else { return }
            db.exec("BEGIN IMMEDIATE")
            let stmt = db.prepare("DELETE FROM archived_tabs WHERE id = ?")
            for key in keys {
                db.bindText(stmt, 1, key)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
            db.exec("COMMIT")
        }
    }

    /// Test/CLI helper: wait until queued writes finish.
    public func flushQueue() {
        queue.sync {}
    }

    /// Stores imported archive records. A record whose ID is already stored
    /// counts as a duplicate and keeps the stored row. This makes re-import
    /// idempotent by Arc item ID (the importer maps Arc IDs to stable Open IDs).
    public func importRecords(_ records: [ArchivedTabRecord]) async -> (inserted: Int, duplicates: Int) {
        guard !records.isEmpty else { return (0, 0) }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: (0, records.count)); return }
                self.openOnQueue()
                guard let db = self.db else { continuation.resume(returning: (0, records.count)); return }
                var inserted = 0
                var duplicates = 0
                db.exec("BEGIN IMMEDIATE")
                let check = db.prepare("SELECT 1 FROM archived_tabs WHERE id = ? LIMIT 1")
                let insert = db.prepare("INSERT INTO archived_tabs(id,url,title,space_id,profile_id,archived_at,reason,original_location,payload) VALUES(?,?,?,?,?,?,?,?,?)")
                for record in records {
                    let key = record.id.rawValue.uuidString
                    db.bindText(check, 1, key)
                    let exists = sqlite3_step(check) == SQLITE_ROW
                    sqlite3_reset(check)
                    if exists { duplicates += 1; continue }
                    db.bindText(insert, 1, key)
                    db.bindText(insert, 2, record.url.absoluteString)
                    db.bindText(insert, 3, record.title)
                    db.bindText(insert, 4, record.spaceID?.rawValue.uuidString)
                    db.bindText(insert, 5, record.profileID?.rawValue.uuidString)
                    db.bindDouble(insert, 6, record.archivedAt.timeIntervalSince1970)
                    db.bindText(insert, 7, record.reason.rawValue)
                    db.bindText(insert, 8, record.originalLocation)
                    db.bindText(insert, 9, record.payloadJSON)
                    if sqlite3_step(insert) == SQLITE_DONE { inserted += 1 } else { duplicates += 1 }
                    sqlite3_reset(insert)
                }
                sqlite3_finalize(check)
                sqlite3_finalize(insert)
                db.exec("COMMIT")
                continuation.resume(returning: (inserted, duplicates))
            }
        }
    }

    nonisolated private func insertOnQueue(_ rows: [ArchiveRow]) {
        guard let db else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        db.exec("BEGIN IMMEDIATE")
        let stmt = db.prepare("INSERT OR REPLACE INTO archived_tabs(id,url,title,space_id,profile_id,archived_at,reason,original_location,payload) VALUES(?,?,?,?,?,?,?,?,?)")
        for row in rows {
            let payload = (try? encoder.encode(row.payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            db.bindText(stmt, 1, row.id)
            db.bindText(stmt, 2, row.url)
            db.bindText(stmt, 3, row.title)
            db.bindText(stmt, 4, row.spaceID)
            db.bindText(stmt, 5, row.profileID)
            db.bindDouble(stmt, 6, row.archivedAt)
            db.bindText(stmt, 7, row.reason)
            db.bindText(stmt, 8, row.originalLocation)
            db.bindText(stmt, 9, payload)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        db.exec("COMMIT")
    }

    nonisolated private func queryOnQueue(sql: String, limit: Int, likeText: String?, exactID: String?) -> [ArchivedTabRecord] {
        openOnQueue()
        guard let db else { return [] }
        let stmt = db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let exactID {
            db.bindText(stmt, 1, exactID)
        } else if let likeText {
            db.bindText(stmt, 1, likeText); db.bindText(stmt, 2, likeText); db.bindInt(stmt, 3, Int64(limit))
        } else {
            db.bindInt(stmt, 1, Int64(limit))
        }
        var rows: [ArchivedTabRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idS = db.columnText(stmt, 0), let urlS = db.columnText(stmt, 1) else { continue }
            rows.append(ArchivedTabRecord(
                id: ItemID(uuidString: idS),
                url: URL(string: urlS) ?? URL(string: "about:blank")!,
                title: db.columnText(stmt, 2) ?? "",
                spaceID: db.columnText(stmt, 3).map { SpaceID(uuidString: $0) },
                profileID: db.columnText(stmt, 4).map { ProfileID(uuidString: $0) },
                archivedAt: Date(timeIntervalSince1970: db.columnDouble(stmt, 5)),
                reason: ArchiveReason(rawValue: db.columnText(stmt, 6) ?? "") ?? .closed,
                originalLocation: db.columnText(stmt, 7) ?? "",
                payloadJSON: db.columnText(stmt, 8) ?? "{}"
            ))
        }
        return rows
    }

    public func recent(limit: Int = 100) async -> [ArchivedTabRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: []); return }
                let rows = self.queryOnQueue(sql: "SELECT id,url,title,space_id,profile_id,archived_at,reason,original_location,payload FROM archived_tabs ORDER BY archived_at DESC LIMIT ?", limit: limit, likeText: nil, exactID: nil)
                continuation.resume(returning: rows)
            }
        }
    }

    public func search(_ text: String, limit: Int = 100) async -> [ArchivedTabRecord] {
        let like = "%\(text)%"
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: []); return }
                let rows = self.queryOnQueue(sql: "SELECT id,url,title,space_id,profile_id,archived_at,reason,original_location,payload FROM archived_tabs WHERE title LIKE ? OR url LIKE ? ORDER BY archived_at DESC LIMIT ?", limit: limit, likeText: like, exactID: nil)
                continuation.resume(returning: rows)
            }
        }
    }

    /// Returns the stored record for restore and deletes the row.
    public func restore(id: ItemID) async -> ArchivedTabRecord? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                let rows = self.queryOnQueue(sql: "SELECT id,url,title,space_id,profile_id,archived_at,reason,original_location,payload FROM archived_tabs WHERE id = ?", limit: 1, likeText: nil, exactID: id.rawValue.uuidString)
                let record = rows.first
                if record != nil, let db = self.db {
                    let del = db.prepare("DELETE FROM archived_tabs WHERE id = ?")
                    db.bindText(del, 1, id.rawValue.uuidString)
                    sqlite3_step(del)
                    sqlite3_finalize(del)
                }
                continuation.resume(returning: record)
            }
        }
    }

    @discardableResult
    public func purge(olderThanDays days: Int) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: 0); return }
                self.openOnQueue()
                guard let db = self.db else { continuation.resume(returning: 0); return }
                let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
                let stmt = db.prepare("DELETE FROM archived_tabs WHERE archived_at < ?")
                db.bindDouble(stmt, 1, cutoff)
                sqlite3_step(stmt)
                let changed = Int(db.changes)
                sqlite3_finalize(stmt)
                continuation.resume(returning: changed)
            }
        }
    }

    public func count() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: 0); return }
                self.openOnQueue()
                guard let db = self.db else { continuation.resume(returning: 0); return }
                let stmt = db.prepare("SELECT COUNT(*) FROM archived_tabs")
                var value = 0
                if sqlite3_step(stmt) == SQLITE_ROW { value = Int(db.columnInt(stmt, 0)) }
                sqlite3_finalize(stmt)
                continuation.resume(returning: value)
            }
        }
    }
}
