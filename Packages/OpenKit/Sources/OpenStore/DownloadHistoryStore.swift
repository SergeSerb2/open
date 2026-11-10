import Foundation
import OpenModel
import SQLite3

public struct DownloadHistoryRecord: Codable, Sendable {
    public enum State: String, Codable, Sendable { case completed, cancelled, failed }
    public var id: String
    public var fileName: String
    public var sourceURL: URL
    public var sourceHost: String
    public var filePath: String?
    public var receivedBytes: Int64
    public var totalBytes: Int64?
    public var startedAt: Date
    public var endedAt: Date
    public var state: State
    public var profileID: ProfileID

    public init(id: String, fileName: String, sourceURL: URL, sourceHost: String, filePath: String?, receivedBytes: Int64,
                totalBytes: Int64?, startedAt: Date, endedAt: Date, state: State, profileID: ProfileID) {
        self.id = id; self.fileName = fileName; self.sourceURL = sourceURL; self.sourceHost = sourceHost; self.filePath = filePath
        self.receivedBytes = receivedBytes; self.totalBytes = totalBytes; self.startedAt = startedAt; self.endedAt = endedAt
        self.state = state; self.profileID = profileID
    }
    fileprivate var valid: Bool {
        !id.isEmpty && id.utf8.count <= 512 && !fileName.isEmpty && fileName.utf8.count <= 1024
            && sourceURL.absoluteString.utf8.count <= 8192 && sourceURL.scheme != nil && sourceHost.utf8.count <= 1024
            && (filePath.map { $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") } ?? true)
            && receivedBytes >= 0 && (totalBytes.map { $0 >= 0 } ?? true)
            && startedAt.timeIntervalSince1970.isFinite && endedAt.timeIntervalSince1970.isFinite
            && endedAt >= startedAt
    }
}

/// Like ArchiveStore: lazy per-Profile State SQLite file, a private serial queue,
/// FULL-synchronous atomic transactions, and no disk work on the main actor.
/// Keep 1,000 terminal rows. Refuse databases/sidecars above 32 MiB before open;
/// SQLite's page ceiling also bounds growth. A row payload is at most 96 KiB
/// (JSON escaping included); SQLite's value/row allocation limit is 100 KiB.
/// Thus even a corrupt declared payload size cannot reach the allocator ceiling.
@MainActor
public final class DownloadHistoryStore {
    nonisolated public static let maximumCount = 1_000
    nonisolated public static let maximumFileBytes = 32 * 1024 * 1024
    nonisolated private static let maximumPayloadBytes = 96 * 1024
    private let fileURL: URL
    private let profileID: ProfileID
    private let queue = DispatchQueue(label: "open.download-history", qos: .utility)
    nonisolated(unsafe) private var db: SQLiteDB?
    private var retired = false

    public init(fileURL: URL, profileID: ProfileID) { self.fileURL = fileURL; self.profileID = profileID }

    deinit {
        let connection = db; db = nil
        queue.async { withExtendedLifetime(connection) {} }
    }

    nonisolated private func failure() -> NSError {
        NSError(domain: "OpenStore.DownloadHistory", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Download history is unavailable, damaged, or exceeds its size limit."])
    }
    nonisolated private func openOnQueue() throws -> SQLiteDB {
        if let db { return db }
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: fileURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      let size = info.fileSize, size <= Self.maximumFileBytes else { throw failure() }
            }
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let opened = try SQLiteDB(path: fileURL.path, maximumValueBytes: Int32(Self.maximumPayloadBytes + 4096), newFilePermissions: 0o600)
        guard opened.exec("PRAGMA synchronous=FULL"), let pageSize = opened.prepare("PRAGMA page_size") else { throw failure() }
        let pageBytes = sqlite3_step(pageSize) == SQLITE_ROW ? opened.columnInt(pageSize, 0) : 0
        sqlite3_finalize(pageSize)
        guard pageBytes > 0, pageBytes <= 65_536,
              opened.exec("PRAGMA max_page_count=\(Int64(Self.maximumFileBytes) / pageBytes)"),
              let check = opened.prepare("PRAGMA quick_check(1)") else { throw failure() }
        let healthy = sqlite3_step(check) == SQLITE_ROW && opened.columnText(check, 0) == "ok"
        sqlite3_finalize(check)
        guard healthy else { throw failure() }
        guard let version = opened.prepare("PRAGMA user_version") else { throw failure() }
        let supported = sqlite3_step(version) == SQLITE_ROW && (0...1).contains(opened.columnInt(version, 0))
        sqlite3_finalize(version)
        guard supported, opened.exec("BEGIN IMMEDIATE") else { throw failure() }
        var committed = false
        defer { if !committed { opened.exec("ROLLBACK") } }
        guard opened.exec("""
            CREATE TABLE IF NOT EXISTS downloads(id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL NOT NULL, payload TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS downloads_end ON downloads(ended_at DESC,id);
            PRAGMA user_version=1;
            """), opened.exec("COMMIT") else { throw failure() }
        committed = true; db = opened
        return opened
    }
    nonisolated private func recordsOnQueue(_ db: SQLiteDB) throws -> [DownloadHistoryRecord] {
        guard let statement = db.prepare("SELECT id,payload FROM downloads ORDER BY ended_at DESC,id LIMIT \(Self.maximumCount)") else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        var rows: [DownloadHistoryRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                  Int(sqlite3_column_bytes(statement, 1)) <= Self.maximumPayloadBytes,
                  let payload = db.columnText(statement, 1), let key = db.columnText(statement, 0) else { throw failure() }
            let row = try decoder.decode(DownloadHistoryRecord.self, from: Data(payload.utf8))
            guard row.valid, row.profileID == profileID, row.id == key else { throw failure() }
            rows.append(row)
        }
        return rows
    }
    public func load() async throws -> [DownloadHistoryRecord] {
        guard !retired else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try recordsOnQueue(openOnQueue())) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// Enqueue immediately on the main actor, so loads, removes and clears cannot
    /// overtake a terminal callback. The completion surfaces failures to the App.
    public func record(_ row: DownloadHistoryRecord, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        guard !retired else { return }
        queue.async { [self] in
            var errorText: String?
            do {
                guard row.valid, row.profileID == profileID else { throw failure() }
                let db = try openOnQueue()
                guard db.exec("BEGIN IMMEDIATE") else { throw failure() }
                var committed = false
                defer { if !committed { db.exec("ROLLBACK") } }
                // Recover over-count files before the insert needs free pages.
                // No existing payload is read or decoded on the write path.
                let prune = "DELETE FROM downloads WHERE id NOT IN (SELECT id FROM downloads ORDER BY ended_at DESC,id LIMIT \(Self.maximumCount))"
                guard db.exec(prune) else { throw failure() }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]
                let payload = try encoder.encode(row)
                guard payload.count <= Self.maximumPayloadBytes else { throw failure() }
                guard let statement = db.prepare("INSERT OR REPLACE INTO downloads VALUES(?,?,?,?)") else { throw failure() }
                defer { sqlite3_finalize(statement) }
                db.bindText(statement, 1, row.id); db.bindDouble(statement, 2, row.startedAt.timeIntervalSince1970)
                db.bindDouble(statement, 3, row.endedAt.timeIntervalSince1970); db.bindText(statement, 4, String(decoding: payload, as: UTF8.self))
                guard sqlite3_step(statement) == SQLITE_DONE,
                      db.exec(prune),
                      db.exec("COMMIT") else { throw failure() }
                committed = true
                db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            } catch { errorText = error.localizedDescription }
            let result = errorText
            Task { @MainActor in completion(result) }
        }
    }
    public func remove(id: String) async throws { try await delete(id: id, since: nil, through: .distantFuture) }
    public func clear(since: Date?, through: Date) async throws { try await delete(id: nil, since: since, through: through) }
    private func delete(id: String?, since: Date?, through: Date) async throws {
        guard !retired else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    let db = try openOnQueue()
                    guard db.exec("BEGIN IMMEDIATE") else { throw failure() }
                    var committed = false
                    defer { if !committed { db.exec("ROLLBACK") } }
                    guard let statement = db.prepare(id == nil ? "DELETE FROM downloads WHERE started_at>=? AND started_at<=?" : "DELETE FROM downloads WHERE id=?") else { throw failure() }
                    defer { sqlite3_finalize(statement) }
                    if let id { db.bindText(statement, 1, id) }
                    else { db.bindDouble(statement, 1, (since ?? .distantPast).timeIntervalSince1970); db.bindDouble(statement, 2, through.timeIntervalSince1970) }
                    guard sqlite3_step(statement) == SQLITE_DONE, db.exec("COMMIT") else { throw failure() }
                    committed = true; db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    public func retire() async {
        retired = true
        await withCheckedContinuation { continuation in
            queue.async { [self] in db = nil; continuation.resume() }
        }
    }
}
