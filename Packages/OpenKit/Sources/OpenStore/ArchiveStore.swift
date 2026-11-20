import Foundation
import Observation
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
    let kind: ArchiveRecordKind
    let payload: ArchivePayload
}

private enum ArchivePayload: Encodable, Sendable {
    case tab(TabDTO), folder(FolderArchiveDTO)
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .tab(let tab): try tab.encode(to: encoder)
        case .folder(let folder): try folder.encode(to: encoder)
        }
    }
}

private struct FolderArchiveDTO: Encodable, Sendable {
    let kind = ArchiveRecordKind.folder
    let id: String
    let title: String
    let isExpanded: Bool
    let customIcon: String?
    let iconOverride: SpaceIconDTO?
    let children: [NodeDTO]
    let originalSection: String?
}

/// SQLite archive. The sink entry point runs on the main actor and snapshots
/// values there; every SQLite statement runs on a private serial queue.
@MainActor @Observable
public final class ArchiveStore: ArchiveSink {
    public private(set) var contentVersion: UInt64 = 0
    public let fileURL: URL
    private let queue = DispatchQueue(label: "open.archive", qos: .utility)
    @ObservationIgnored nonisolated(unsafe) private var db: SQLiteDB?
    @ObservationIgnored nonisolated(unsafe) private var retired = false

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// Runs `body` with synchronous=FULL, then restores the connection's previous mode, so only
    /// the archive commit itself (and its schema setup) pays for the full sync.
    nonisolated private func withFullSync<T>(_ db: SQLiteDB, _ body: () throws -> T) throws -> T {
        guard let read = db.prepare("PRAGMA synchronous") else { throw archiveFailure() }
        let previous = sqlite3_step(read) == SQLITE_ROW ? db.columnInt(read, 0) : 1
        sqlite3_finalize(read)
        guard db.exec("PRAGMA synchronous=FULL") else { throw archiveFailure() }
        defer { db.exec("PRAGMA synchronous=\(previous)") }
        return try body()
    }

    nonisolated private func openOnQueue() throws {
        guard !retired else { throw archiveFailure() }
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = try SQLiteDB(path: fileURL.path)
        try withFullSync(opened) { try migrateOnQueue(opened) }
        db = opened
    }

    nonisolated private func migrateOnQueue(_ opened: SQLiteDB) throws {
        guard opened.exec("BEGIN IMMEDIATE") else { throw archiveFailure() }
        var committed = false
        defer { if !committed { opened.exec("ROLLBACK") } }
        guard opened.exec("""
        CREATE TABLE IF NOT EXISTS archived_tabs(
          id TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL,
          space_id TEXT, profile_id TEXT, archived_at REAL NOT NULL,
          reason TEXT NOT NULL, original_location TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_archived_at ON archived_tabs(archived_at DESC);
        """) else { throw archiveFailure() }
        guard let columns = opened.prepare("PRAGMA table_info(archived_tabs)") else { throw archiveFailure() }
        var hasKind = false
        while sqlite3_step(columns) == SQLITE_ROW { if opened.columnText(columns, 1) == "kind" { hasKind = true } }
        sqlite3_finalize(columns)
        if !hasKind {
            guard opened.exec("ALTER TABLE archived_tabs ADD COLUMN kind TEXT NOT NULL DEFAULT 'tab'") else { throw archiveFailure() }
            if ProcessInfo.processInfo.environment["OPENKIT_DEBUG_ARCHIVE_MIGRATION_CRASH"] == "alter" { _exit(86) }
        }
        guard let version = opened.prepare("PRAGMA user_version"), sqlite3_step(version) == SQLITE_ROW else { throw archiveFailure() }
        let oldVersion = opened.columnInt(version, 0); sqlite3_finalize(version)
        if oldVersion == 0 {
            guard opened.exec("PRAGMA user_version=1") else { throw archiveFailure() }
            if ProcessInfo.processInfo.environment["OPENKIT_DEBUG_ARCHIVE_MIGRATION_CRASH"] == "version" { _exit(86) }
        }
        guard opened.exec("COMMIT") else { throw archiveFailure() }
        committed = true
    }

    /// Snapshots the tabs on the main actor. JSON encoding and one SQLite transaction run on the queue.
    public func archive(_ entries: [ArchiveEntry]) { archive(entries, folders: []) }

    public func archiveFolder(_ entry: ArchiveFolderEntry) { archive([], folders: [entry]) }

    public func archive(_ entries: [ArchiveEntry], folders: [ArchiveFolderEntry]) {
        contentVersion &+= 1
        let rows = rows(entries) + folders.map { entry in
            ArchiveRow(id: entry.folder.id.description, url: "about:blank", title: entry.folder.title,
                       spaceID: entry.spaceID?.description, profileID: entry.profileID?.description,
                       archivedAt: entry.archivedAt.timeIntervalSince1970, reason: entry.reason.rawValue,
                       originalLocation: entry.originalLocation, kind: .folder,
                       payload: .folder(FolderArchiveDTO(id: entry.folder.id.description, title: entry.folder.title,
                           isExpanded: entry.folder.isExpanded, customIcon: entry.folder.customIcon,
                           iconOverride: SnapshotMapper.iconDTO(entry.folder.iconOverride),
                           children: entry.folder.children.map { SnapshotMapper.archivedNodeDTO($0) }, originalSection: entry.originalSection)))
        }
        guard !rows.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            try? self.openOnQueue()
            try? self.insertOnQueue(rows)
        }
    }

    private func rows(_ entries: [ArchiveEntry]) -> [ArchiveRow] {
        entries.map { entry in
            ArchiveRow(id: entry.tab.id.rawValue.uuidString, url: entry.tab.url.absoluteString, title: entry.tab.customTitle ?? entry.tab.title,
                       spaceID: entry.spaceID?.rawValue.uuidString, profileID: entry.profileID?.rawValue.uuidString,
                       archivedAt: entry.archivedAt.timeIntervalSince1970, reason: entry.reason.rawValue,
                       originalLocation: entry.originalLocation, kind: .tab, payload: .tab(SnapshotMapper.tabDTO(entry.tab)))
        }
    }

    /// Profile deletion waits for FULL-synchronous commit and surfaces all failures.
    public func archiveForProfileDeletion(_ entries: [ArchiveEntry], directoryName: String) throws {
        contentVersion &+= 1
        let rows = rows(entries)
        guard !rows.isEmpty else { return }
        try queue.sync {
            try openOnQueue()
            try insertOnQueue(rows)
        }
    }

    nonisolated private func archiveFailure() -> NSError {
        NSError(domain: "OpenStore.Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: "archive write did not commit"])
    }

    public func discardArchived(ids: [ItemID]) {
        contentVersion &+= 1
        guard !ids.isEmpty else { return }
        let keys = ids.map { $0.rawValue.uuidString }
        queue.async { [weak self] in
            guard let self else { return }
            try? self.openOnQueue()
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

    /// Profile deletion: finish queued writes, close the database and never
    /// reopen it, so its folder can be removed without a file coming back.
    public func retire() {
        queue.sync { retired = true; db = nil }
    }

    /// Test/CLI helper: wait until queued writes finish.
    public func flushQueue() {
        queue.sync {}
    }

    /// One queued batch lookup, ordered after manual archive writes. Scan only
    /// UUID keys, retaining at most the candidate set, with no payload decoding
    /// or SQL bind-count ceiling. Each input row is bounded to 36 bytes.
    public func existingIDs(in candidates: Set<ItemID>) async throws -> Set<ItemID> {
        guard !candidates.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try openOnQueue()
                    guard let db, let statement = db.prepare("SELECT id FROM archived_tabs WHERE length(CAST(id AS BLOB)) = 36") else {
                        throw archiveFailure()
                    }
                    defer { sqlite3_finalize(statement) }
                    var found = Set<ItemID>()
                    while true {
                        let status = sqlite3_step(statement)
                        if status == SQLITE_DONE { break }
                        guard status == SQLITE_ROW else { throw archiveFailure() }
                        if let key = db.columnText(statement, 0), let uuid = UUID(uuidString: key) {
                            let id = ItemID(rawValue: uuid)
                            if candidates.contains(id) { found.insert(id) }
                        }
                    }
                    continuation.resume(returning: found)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Stores imported archive records. A record whose ID is already stored
    /// counts as a duplicate and keeps the stored row. This makes re-import
    /// idempotent by Arc item ID (the importer maps Arc IDs to stable Open IDs).
    public func importRecords(_ records: [ArchivedTabRecord]) async -> (inserted: Int, duplicates: Int) {
        (try? await importRecords(records, checking: true)) ?? (0, 0)
    }

    /// App import needs a checked result: an unavailable store is a failure,
    /// never a duplicate. The entire Profile batch commits or rolls back.
    public func importRecords(_ records: [ArchivedTabRecord], checking: Bool) async throws -> (inserted: Int, duplicates: Int) {
        let result = try await importRecordsWithUndo(records)
        return (result.inserted, result.duplicates)
    }

    /// The receipt includes only inserted stable IDs. Existing Archive rows
    /// remain outside this import's Undo, including during a partial failure.
    public func importRecordsWithUndo(_ records: [ArchivedTabRecord]) async throws -> (inserted: Int, duplicates: Int, undo: [ArchivedTabRecord]) {
        contentVersion &+= 1
        guard !records.isEmpty else { return (0, 0, []) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try openOnQueue()
                    guard let db else { throw archiveFailure() }
                    guard db.exec("BEGIN IMMEDIATE") else { throw archiveFailure() }
                    var committed = false
                    defer { if !committed { db.exec("ROLLBACK") } }
                    guard let check = db.prepare("SELECT 1 FROM archived_tabs WHERE id = ? LIMIT 1") else { throw archiveFailure() }
                    defer { sqlite3_finalize(check) }
                    guard let insert = db.prepare("INSERT INTO archived_tabs(id,url,title,space_id,profile_id,archived_at,reason,original_location,payload,kind) VALUES(?,?,?,?,?,?,?,?,?,?)") else { throw archiveFailure() }
                    defer { sqlite3_finalize(insert) }
                    var inserted = 0, duplicates = 0
                    var undo: [ArchivedTabRecord] = []
                    for record in records {
                        let key = record.id.rawValue.uuidString
                        db.bindText(check, 1, key)
                        let status = sqlite3_step(check)
                        sqlite3_reset(check)
                        if status == SQLITE_ROW { duplicates += 1; continue }
                        guard status == SQLITE_DONE else { throw archiveFailure() }
                        db.bindText(insert, 1, key)
                        db.bindText(insert, 2, record.url.absoluteString)
                        db.bindText(insert, 3, record.title)
                        db.bindText(insert, 4, record.spaceID?.rawValue.uuidString)
                        db.bindText(insert, 5, record.profileID?.rawValue.uuidString)
                        db.bindDouble(insert, 6, record.archivedAt.timeIntervalSince1970)
                        db.bindText(insert, 7, record.reason.rawValue)
                        db.bindText(insert, 8, record.originalLocation)
                        db.bindText(insert, 9, record.payloadJSON)
                        db.bindText(insert, 10, record.kind.rawValue)
                        guard sqlite3_step(insert) == SQLITE_DONE else { throw archiveFailure() }
                        inserted += 1; undo.append(record); sqlite3_reset(insert)
                    }
                    guard db.exec("COMMIT") else { throw archiveFailure() }
                    committed = true
                    continuation.resume(returning: (inserted, duplicates, undo))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private func insertOnQueue(_ rows: [ArchiveRow]) throws {
        guard let db else { throw archiveFailure() }
        try withFullSync(db) { try insertOnQueue(rows, db: db) }
    }

    nonisolated private func insertOnQueue(_ rows: [ArchiveRow], db: SQLiteDB) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard db.exec("BEGIN IMMEDIATE") else { throw archiveFailure() }
        var committed = false
        defer { if !committed { db.exec("ROLLBACK") } }
        guard let stmt = db.prepare("INSERT OR REPLACE INTO archived_tabs(id,url,title,space_id,profile_id,archived_at,reason,original_location,payload,kind) VALUES(?,?,?,?,?,?,?,?,?,?)") else { throw archiveFailure() }
        defer { sqlite3_finalize(stmt) }
        for row in rows {
            let payload = String(decoding: try encoder.encode(row.payload), as: UTF8.self)
            db.bindText(stmt, 1, row.id)
            db.bindText(stmt, 2, row.url)
            db.bindText(stmt, 3, row.title)
            db.bindText(stmt, 4, row.spaceID)
            db.bindText(stmt, 5, row.profileID)
            db.bindDouble(stmt, 6, row.archivedAt)
            db.bindText(stmt, 7, row.reason)
            db.bindText(stmt, 8, row.originalLocation)
            db.bindText(stmt, 9, payload)
            db.bindText(stmt, 10, row.kind.rawValue)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw archiveFailure() }
            sqlite3_reset(stmt)
        }
        guard db.exec("COMMIT") else { throw archiveFailure() }
        committed = true
    }

    nonisolated private func queryOnQueue(sql: String, limit: Int, likeText: String?, exactID: String?) -> [ArchivedTabRecord] {
        try? openOnQueue()
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
                payloadJSON: db.columnText(stmt, 8) ?? "{}",
                kind: ArchiveRecordKind(rawValue: db.columnText(stmt, 9) ?? "") ?? .tab
            ))
        }
        return rows
    }

    /// Bounded Library page. Only typed enum/UUID values enter the fixed SQL fragments.
    public func page(limit: Int = 100, offset: Int = 0, query: String = "", spaceID: SpaceID? = nil,
                     reason: ArchiveReason? = nil, origin: String = "all") async -> [ArchivedTabRecord] {
        let authority = "substr(url,instr(url,'://')+3)"
        let host = "substr(\(authority),1,instr(\(authority)||'/','/')-1)"
        var filter = "(title LIKE ? ESCAPE '\\' OR \(host) LIKE ? ESCAPE '\\')"
        if let spaceID { filter += " AND space_id='\(spaceID.description)'" }
        if let reason { filter += " AND reason='\(reason.rawValue)'" }
        if origin == "littleOpen" { filter += " AND lower(original_location) LIKE 'little%'" }
        if origin == "spaces" { filter += " AND lower(original_location) NOT LIKE 'little%'" }
        let sql = "SELECT id,url,title,space_id,profile_id,archived_at,reason,original_location,payload,kind FROM archived_tabs WHERE \(filter) ORDER BY archived_at DESC,id LIMIT ? OFFSET \(max(0, offset))"
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.queryOnQueue(sql: sql, limit: max(1, min(100, limit)), likeText: Self.likePattern(query), exactID: nil) ?? [])
            }
        }
    }

    /// A substring LIKE pattern: `%`, `_` and `\` in the user's text match themselves.
    nonisolated static func likePattern(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%" + escaped + "%"
    }

    public func delete(id: ItemID) async throws { try await delete(ids: [id]) }
    public func delete(ids: [ItemID]) async throws {
        contentVersion &+= 1
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                do {
                    try self.openOnQueue(); guard let db = self.db else { throw self.archiveFailure() }
                    guard db.exec("BEGIN IMMEDIATE") else { throw self.archiveFailure() }
                    var committed = false; defer { if !committed { db.exec("ROLLBACK") } }
                    let statement = db.prepare("DELETE FROM archived_tabs WHERE id=?")
                    defer { sqlite3_finalize(statement) }
                    for id in ids { db.bindText(statement, 1, id.description); guard sqlite3_step(statement) == SQLITE_DONE else { throw self.archiveFailure() }; sqlite3_reset(statement) }
                    guard db.exec("COMMIT") else { throw self.archiveFailure() }; committed = true
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func deleteAll() async throws {
        contentVersion &+= 1
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                do {
                    try self.openOnQueue(); guard let db = self.db else { throw self.archiveFailure() }
                    guard db.exec("BEGIN IMMEDIATE") else { throw self.archiveFailure() }
                    guard db.exec("DELETE FROM archived_tabs"), db.exec("COMMIT") else { db.exec("ROLLBACK"); throw self.archiveFailure() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func recent(limit: Int = 100) async -> [ArchivedTabRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: []); return }
                let rows = self.queryOnQueue(sql: "SELECT id,url,title,space_id,profile_id,archived_at,reason,original_location,payload,kind FROM archived_tabs ORDER BY archived_at DESC LIMIT ?", limit: limit, likeText: nil, exactID: nil)
                continuation.resume(returning: rows)
            }
        }
    }

    public func search(_ text: String, limit: Int = 100) async -> [ArchivedTabRecord] {
        let like = Self.likePattern(text)
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: []); return }
                let rows = self.queryOnQueue(sql: "SELECT id,url,title,space_id,profile_id,archived_at,reason,original_location,payload,kind FROM archived_tabs WHERE title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\' ORDER BY archived_at DESC LIMIT ?", limit: limit, likeText: like, exactID: nil)
                continuation.resume(returning: rows)
            }
        }
    }

    /// Reads a row without removing it. The caller commits its sidebar snapshot before delete.
    public func record(id: ItemID) async -> ArchivedTabRecord? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.queryOnQueue(sql: "SELECT id,url,title,space_id,profile_id,archived_at,reason,original_location,payload,kind FROM archived_tabs WHERE id = ?", limit: 1, likeText: nil, exactID: id.rawValue.uuidString).first)
            }
        }
    }

    /// Returns the stored record for restore and deletes the row.
    public func restore(id: ItemID) async -> ArchivedTabRecord? {
        contentVersion &+= 1
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                let rows = self.queryOnQueue(sql: "SELECT id,url,title,space_id,profile_id,archived_at,reason,original_location,payload,kind FROM archived_tabs WHERE id = ?", limit: 1, likeText: nil, exactID: id.rawValue.uuidString)
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
        contentVersion &+= 1
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: 0); return }
                try? self.openOnQueue()
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
                try? self.openOnQueue()
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
