import Foundation
import SQLite3

/// Minimal SQLite wrapper. One connection, used only inside its actor/queue.
final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let dataRootLock: DataRootLock

    init(path: String, maximumValueBytes: Int32? = nil, newFilePermissions: Int? = nil) throws {
        dataRootLock = try DataRootLock.acquire(root: OpenDataRoot.root(forStoreFileURL: URL(fileURLWithPath: path)))
        let isNew = newFilePermissions != nil && !FileManager.default.fileExists(atPath: path)
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            db = nil
            throw NSError(domain: "OpenStore.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        // Set permissions immediately after open, before journal/schema writes.
        if isNew, let newFilePermissions {
            do { try FileManager.default.setAttributes([.posixPermissions: newFilePermissions], ofItemAtPath: path) }
            catch {
                if let db { sqlite3_close(db) }
                db = nil
                throw error
            }
        }
        // Apply before any PRAGMA/schema read. A corrupt record's declared size
        // must not cause SQLite to allocate its default (up to 1 GiB) value limit.
        if let maximumValueBytes { sqlite3_limit(db, Int32(SQLITE_LIMIT_LENGTH), maximumValueBytes) }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA foreign_keys=ON;")
    }

    deinit { if let db { sqlite3_close(db) } }

    /// True when the file is not a database or its schema cannot be read (SQLITE_NOTADB or
    /// SQLITE_CORRUPT). SQLite opens such a file without an error and fails every later statement.
    /// Reads only the schema page; a busy or locked file is not damaged.
    var isDamaged: Bool {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        let code = (prepared == SQLITE_OK ? sqlite3_step(statement) : prepared) & 0xff
        return code == SQLITE_NOTADB || code == SQLITE_CORRUPT
    }

    /// Opens the store. A damaged file and its -wal/-shm are moved aside as
    /// `<name>.damaged-<time>-<id>[-wal|-shm]` (kept, never deleted) and a fresh store is opened in its
    /// place, as the session snapshot keeps `browser.unreadable-*.json` (bug sweep r7 Z-02).
    static func openSettingAsideDamage(path: String, open: (String) throws -> SQLiteDB) throws -> SQLiteDB {
        do {
            let first = try open(path)
            if !first.isDamaged { return first }
        }
        // Unique per set-aside; the sidecars go first, so a failed move never leaves the old WAL beside a
        // new database (review r1 of #670).
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        for suffix in ["-shm", "-wal", ""] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.moveItem(atPath: path + suffix, toPath: path + ".damaged-\(stamp)" + suffix)
        }
        FileHandle.standardError.write(Data("Open: damaged store kept as \((path as NSString).lastPathComponent).damaged-\(stamp); starting a new one\n".utf8))
        return try open(path)
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bindInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }

    func bindDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    func columnInt(_ stmt: OpaquePointer?, _ index: Int32) -> Int64 {
        sqlite3_column_int64(stmt, index)
    }

    func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
    var changes: Int32 { sqlite3_changes(db) }
}
