import Foundation
import OpenModel
import SQLite3

public struct SleepHistoryRecord: Sendable, Equatable {
    public var tabID: ItemID
    public var container: Data
    public var currentIndex: Int
    public var entryCount: Int
    public var currentURL: URL
    public var currentTitle: String
    public var faviconURL: URL?
    public var hasPageState: Bool
    public var containerVersion: Int
    public var chromiumTag: String
    public var capturedAt: Date

    public init(tabID: ItemID, container: Data, currentIndex: Int, entryCount: Int,
                currentURL: URL, currentTitle: String, faviconURL: URL? = nil,
                hasPageState: Bool, containerVersion: Int = 1, chromiumTag: String, capturedAt: Date) {
        self.tabID = tabID; self.container = container; self.currentIndex = currentIndex
        self.entryCount = entryCount; self.currentURL = currentURL; self.currentTitle = currentTitle
        self.faviconURL = faviconURL; self.hasPageState = hasPageState
        self.containerVersion = containerVersion; self.chromiumTag = chromiumTag; self.capturedAt = capturedAt
    }
}

/// Separate from the frequently rewritten JSON snapshot. All SQLite work stays on open.sleep.
@MainActor
public final class SleepStore {
    nonisolated public static let maximumContainerBytes = 2 * 1024 * 1024
    public let fileURL: URL
    public var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "open.sleep", qos: .utility)
    nonisolated(unsafe) private var db: SQLiteDB?

    public init(fileURL: URL) { self.fileURL = fileURL }

    deinit {
        let connection = db
        db = nil
        queue.async { withExtendedLifetime(connection) {} }
    }

    private enum Failure: Error { case sqlite, tooLarge }

    nonisolated private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    nonisolated private func openOnQueue() throws -> SQLiteDB {
        if let db { return db }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = try SQLiteDB(path: fileURL.path)
        // Sleep history must survive quit and renderer release, including WAL writes.
        guard opened.exec("PRAGMA synchronous=FULL"), opened.exec("PRAGMA busy_timeout=5000"), opened.exec("""
        CREATE TABLE IF NOT EXISTS sleep_history(
          tab_id TEXT PRIMARY KEY, container BLOB NOT NULL,
          current_index INTEGER NOT NULL, entry_count INTEGER NOT NULL,
          current_url TEXT NOT NULL, current_title TEXT NOT NULL, favicon_url TEXT,
          has_page_state INTEGER NOT NULL, container_version INTEGER NOT NULL,
          chromium_tag TEXT NOT NULL, captured_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS sleep_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """) else { throw Failure.sqlite }
        db = opened
        return opened
    }

    /// Returns only after a real SQLite transaction commits with synchronous=FULL.
    public func save(_ record: SleepHistoryRecord) async throws {
        guard record.container.count <= Self.maximumContainerBytes else {
            onError?("SleepStore: container exceeds 2 MiB; write dropped")
            throw Failure.tooLarge
        }
        do {
            try await write { db in
                guard let stmt = db.prepare("INSERT OR REPLACE INTO sleep_history VALUES(?,?,?,?,?,?,?,?,?,?,?)") else { throw Failure.sqlite }
                defer { sqlite3_finalize(stmt) }
                db.bindText(stmt, 1, record.tabID.rawValue.uuidString)
                let code = record.container.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(stmt, 2, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard code == SQLITE_OK else { throw Failure.sqlite }
                db.bindInt(stmt, 3, Int64(record.currentIndex)); db.bindInt(stmt, 4, Int64(record.entryCount))
                db.bindText(stmt, 5, record.currentURL.absoluteString); db.bindText(stmt, 6, record.currentTitle)
                db.bindText(stmt, 7, record.faviconURL?.absoluteString)
                db.bindInt(stmt, 8, record.hasPageState ? 1 : 0); db.bindInt(stmt, 9, Int64(record.containerVersion))
                db.bindText(stmt, 10, record.chromiumTag); db.bindDouble(stmt, 11, record.capturedAt.timeIntervalSince1970)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sqlite }
            }
        } catch { onError?("SleepStore: save failed"); throw error }
    }

    private func write(_ body: @escaping @Sendable (SQLiteDB) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    let db = try openOnQueue()
                    guard db.exec("BEGIN IMMEDIATE") else { throw Failure.sqlite }
                    do {
                        try body(db)
                        guard db.exec("COMMIT") else { throw Failure.sqlite }
                    } catch { db.exec("ROLLBACK"); throw error }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Serial queue barrier plus a transaction commit. WAL is durable before return;
    /// checkpointing is not needed for recovery and would contend with readers.
    public func flush() async throws {
        do { try await write { _ in } }
        catch { onError?("SleepStore: flush failed"); throw error }
    }

    private func query<T: Sendable>(_ fallback: T, _ body: @escaping @Sendable (SQLiteDB) throws -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try body(openOnQueue())) }
                catch { report("SleepStore: read failed"); continuation.resume(returning: fallback) }
            }
        }
    }

    public func load(tabID: ItemID) async -> SleepHistoryRecord? {
        await query(nil) { db in
            guard let stmt = db.prepare("SELECT container,current_index,entry_count,current_url,current_title,favicon_url,has_page_state,container_version,chromium_tag,captured_at FROM sleep_history WHERE tab_id=?") else { throw Failure.sqlite }
            defer { sqlite3_finalize(stmt) }
            db.bindText(stmt, 1, tabID.rawValue.uuidString)
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw Failure.sqlite }
            let length = Int(sqlite3_column_bytes(stmt, 0))
            guard length <= SleepStore.maximumContainerBytes, let bytes = sqlite3_column_blob(stmt, 0),
                  let url = db.columnText(stmt, 3).flatMap(URL.init(string:)) else { throw Failure.sqlite }
            return SleepHistoryRecord(tabID: tabID, container: Data(bytes: bytes, count: length),
                currentIndex: Int(db.columnInt(stmt, 1)), entryCount: Int(db.columnInt(stmt, 2)),
                currentURL: url, currentTitle: db.columnText(stmt, 4) ?? "",
                faviconURL: db.columnText(stmt, 5).flatMap(URL.init(string:)),
                hasPageState: db.columnInt(stmt, 6) != 0, containerVersion: Int(db.columnInt(stmt, 7)),
                chromiumTag: db.columnText(stmt, 8) ?? "", capturedAt: Date(timeIntervalSince1970: db.columnDouble(stmt, 9)))
        }
    }

    public func delete(tabID: ItemID) { delete(tabIDs: [tabID]) }

    public func delete(tabIDs: [ItemID]) {
        guard !tabIDs.isEmpty else { return }
        queue.async { [self] in
            do {
                let db = try openOnQueue()
                guard db.exec("BEGIN IMMEDIATE") else { throw Failure.sqlite }
                do {
                    guard let stmt = db.prepare("DELETE FROM sleep_history WHERE tab_id=?") else { throw Failure.sqlite }
                    defer { sqlite3_finalize(stmt) }
                    for id in tabIDs {
                        db.bindText(stmt, 1, id.rawValue.uuidString)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sqlite }
                        sqlite3_reset(stmt)
                    }
                    guard db.exec("COMMIT") else { throw Failure.sqlite }
                } catch { db.exec("ROLLBACK"); throw error }
            } catch { report("SleepStore: delete failed") }
        }
    }

    public func allTabIDs() async -> [ItemID] {
        await query([]) { db in
            guard let stmt = db.prepare("SELECT tab_id FROM sleep_history ORDER BY tab_id") else { throw Failure.sqlite }
            defer { sqlite3_finalize(stmt) }
            var ids: [ItemID] = []
            while true {
                let code = sqlite3_step(stmt)
                if code == SQLITE_DONE { return ids }
                guard code == SQLITE_ROW, let text = db.columnText(stmt, 0), let uuid = UUID(uuidString: text) else { throw Failure.sqlite }
                ids.append(ItemID(rawValue: uuid))
            }
        }
    }

    public func totalBytes() async -> Int {
        await query(0) { db in
            guard let stmt = db.prepare("SELECT COALESCE(SUM(length(container)),0) FROM sleep_history") else { throw Failure.sqlite }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw Failure.sqlite }
            return Int(db.columnInt(stmt, 0))
        }
    }

    /// Drains queued disk work. Error callbacks run on the main actor afterward.
    public func flushQueue() { queue.sync {} }
}
