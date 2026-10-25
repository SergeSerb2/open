import Foundation
import OpenModel
import SQLite3

public struct ArchivedTabRecord: Sendable, Identifiable {
    public var id: ItemID
    public var url: URL
    public var title: String
    public var spaceID: SpaceID?
    public var profileID: ProfileID?
    public var archivedAt: Date
    public var reason: ArchiveReason
    public var originalLocation: String
    public var payloadJSON: String
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

    public func archive(tab: Tab, reason: ArchiveReason, originalLocation: String) {
        let id = tab.id
        let url = tab.url
        let title = tab.displayTitle
        let dto = SnapshotMapper.tabDTO(tab)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(dto)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let archivedAt = Date()
        queue.async { [weak self] in
            guard let self else { return }
            self.openOnQueue()
            self.insertOnQueue(id: id, url: url, title: title, archivedAt: archivedAt, reason: reason, originalLocation: originalLocation, payloadJSON: payload)
        }
    }

    /// Test/CLI helper: wait until queued writes finish.
    public func flushQueue() {
        queue.sync {}
    }

    nonisolated private func insertOnQueue(id: ItemID, url: URL, title: String, spaceID: SpaceID? = nil, profileID: ProfileID? = nil, archivedAt: Date, reason: ArchiveReason, originalLocation: String, payloadJSON: String) {
        guard let db else { return }
        let stmt = db.prepare("INSERT OR REPLACE INTO archived_tabs(id,url,title,space_id,profile_id,archived_at,reason,original_location,payload) VALUES(?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        db.bindText(stmt, 1, id.rawValue.uuidString)
        db.bindText(stmt, 2, url.absoluteString)
        db.bindText(stmt, 3, title)
        db.bindText(stmt, 4, spaceID?.rawValue.uuidString)
        db.bindText(stmt, 5, profileID?.rawValue.uuidString)
        db.bindDouble(stmt, 6, archivedAt.timeIntervalSince1970)
        db.bindText(stmt, 7, reason.rawValue)
        db.bindText(stmt, 8, originalLocation)
        db.bindText(stmt, 9, payloadJSON)
        sqlite3_step(stmt)
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
                guard let self, let db = self.db else { continuation.resume(returning: 0); return }
                self.openOnQueue()
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
                guard let self, let db = self.db else { continuation.resume(returning: 0); return }
                self.openOnQueue()
                let stmt = db.prepare("SELECT COUNT(*) FROM archived_tabs")
                var value = 0
                if sqlite3_step(stmt) == SQLITE_ROW { value = Int(db.columnInt(stmt, 0)) }
                sqlite3_finalize(stmt)
                continuation.resume(returning: value)
            }
        }
    }
}
