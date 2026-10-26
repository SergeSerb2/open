import Foundation
import SQLite3
import Darwin

public struct ArcHistoryVisitRecord: Sendable {
    public var chromiumVisitID: Int64
    public var urlString: String
    public var title: String
    public var time: Date
    public var transition: String
    public var isTyped: Bool
}

public struct ArcHistoryImportBatch: Sendable {
    public var visits: [ArcHistoryVisitRecord]
}

public struct ArcHistoryReadReport: Sendable {
    public var sourceURLRows: Int = 0
    public var sourceVisitRows: Int = 0
    public var keptVisits: Int = 0
    public var skippedInternal: Int = 0
    public var skippedSubframe: Int = 0
    public var skippedInvalidTime: Int = 0
    public var keywordSearchTermRows: Int = 0
}

public enum ArcHistoryImportError: Error {
    case missingHistoryFile
    case copyFailed
    case openFailed
    case schemaMismatch
    case schemaVersionMismatch(Int)
}

/// Internal copy audit used by the synthetic CLI cancellation flow. Never logs source data.
enum ArcCopyAudit {
    @TaskLocal static var observer:(@Sendable (URL,Int)->Void)?
}

/// Recovery is allowed only on our private copy, never on the source connection.
/// Shared by the history and secret readers. Errors deliberately contain no SQL or row data.
final class ArcSQLiteCopy {
    private var connection: OpaquePointer?
    private let directory: URL

    init(fileURL: URL) throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { throw ArcHistoryImportError.missingHistoryFile }
        directory = fm.temporaryDirectory.appendingPathComponent("open-history-import-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for attempt in 0..<2 {
                do {
                    let path = directory.appendingPathComponent(fileURL.lastPathComponent).path
                    // SHM is process-local coordination state. Never copy it.
                    try? fm.removeItem(atPath: path + "-shm")
                    try copyPrivateSQLiteFile(from: fileURL.path, to: path)
                    let header = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    let bytes: Data
                    do { bytes = try header.read(upToCount: 20) ?? Data(); try header.close() }
                    catch { try? header.close(); throw error }
                    guard bytes.count == 20 else { throw ArcHistoryImportError.copyFailed }
                    let walMode = bytes[18] == 2 && bytes[19] == 2
                    for suffix in walMode ? ["-wal"] : ["-journal"] {
                        if fm.fileExists(atPath: fileURL.path + suffix) {
                            try copyPrivateSQLiteFile(from: fileURL.path + suffix, to: path + suffix)
                        }
                    }
                    guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                        throw ArcHistoryImportError.openFailed
                    }
                    var checks: [String] = []
                    try rows("PRAGMA quick_check") { checks.append(text($0, 0)) }
                    guard checks == ["ok"] else { throw ArcHistoryImportError.copyFailed }
                    guard sqlite3_exec(connection, "PRAGMA temp_store = MEMORY; PRAGMA query_only = ON;", nil, nil, nil) == SQLITE_OK else {
                        throw ArcHistoryImportError.openFailed
                    }
                    return
                } catch {
                    if error is CancellationError || Task.isCancelled {throw CancellationError()}
                    if let connection { sqlite3_close(connection) }
                    connection = nil
                    for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                        try fm.removeItem(at: item)
                    }
                    if attempt == 0 { Thread.sleep(forTimeInterval: 0.2) }
                }
            }
            throw ArcHistoryImportError.copyFailed
        } catch {
            if let connection { sqlite3_close(connection) }
            connection = nil
            try? fm.removeItem(at: directory)
            throw ArcHistoryImportError.copyFailed
        }
    }

    deinit {
        if let connection { sqlite3_close(connection) }
        try? FileManager.default.removeItem(at: directory)
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArcHistoryImportError.schemaMismatch
        }
        return statement
    }

    func rows(_ sql: String, _ consume: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try consume(statement)
            case SQLITE_DONE: return
            default: throw ArcHistoryImportError.schemaMismatch
            }
        }
    }

    func integer(_ sql: String) throws -> Int64 {
        var value: Int64?
        try rows(sql) { value = sqlite3_column_int64($0, 0) }
        guard let value else { throw ArcHistoryImportError.schemaMismatch }
        return value
    }

    func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    func bytes(_ statement: OpaquePointer, _ column: Int32) -> [UInt8] {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return [] }
        return Array(UnsafeRawBufferPointer(start: pointer, count: count))
    }
}

public struct ArcHistoryReader: Sendable {
    public let historyFileURL: URL
    public init(historyFileURL: URL) { self.historyFileURL = historyFileURL }

    public func readBatches(batchSize: Int = 5000) throws -> (report: ArcHistoryReadReport, batches: [[ArcHistoryVisitRecord]]) {
        let cursor = try ArcHistoryCursor(historyFileURL: historyFileURL, batchSize: batchSize)
        var batches: [[ArcHistoryVisitRecord]] = []
        while let batch = try cursor.next() { batches.append(batch) }
        return (cursor.report, batches)
    }

    /// Back pressure keeps only the current visit batch alive in the CLI.
    /// The array-returning overload above remains available to existing callers.
    public func readBatches(batchSize: Int = 5000, consume: ([ArcHistoryVisitRecord]) async -> Void) async throws -> ArcHistoryReadReport {
        let cursor = try ArcHistoryCursor(historyFileURL: historyFileURL, batchSize: batchSize)
        while let batch = try cursor.next() { try Task.checkCancellation(); await consume(batch) }
        return cursor.report
    }
}

/// Confined to the one task that owns a read; never shared between batch consumers.
private final class ArcHistoryCursor {
    private let copy: ArcSQLiteCopy
    private var statement: OpaquePointer?
    private var urls: [Int64: (String, String)] = [:]
    private let limit: Int
    private let offsetMicros: Int64 = 11_644_473_600_000_000
    private let transitions = ["link", "typed", "bookmark", "subframe", "subframe", "generated", "toplevel", "form", "reload", "keyword", "keyword"]
    private(set) var report = ArcHistoryReadReport()

    init(historyFileURL: URL, batchSize: Int) throws {
        copy = try ArcSQLiteCopy(fileURL: historyFileURL)
        limit = min(5000, max(1, batchSize))
        let version = try copy.integer("SELECT value FROM meta WHERE key = 'version'")
        guard (65...75).contains(version) else { throw ArcHistoryImportError.schemaVersionMismatch(Int(version)) }
        report.keywordSearchTermRows = Int(try copy.integer("SELECT COUNT(*) FROM keyword_search_terms"))
        try copy.rows("SELECT id, url, title, hidden FROM urls") { row in
            report.sourceURLRows += 1
            _ = sqlite3_column_int(row, 3) // Hidden URLs remain eligible.
            urls[sqlite3_column_int64(row, 0)] = (copy.text(row, 1), copy.text(row, 2))
        }
        statement = try copy.prepare("SELECT id, url, visit_time, transition, incremented_omnibox_typed_score FROM visits ORDER BY visit_time ASC, id ASC")
    }

    deinit { sqlite3_finalize(statement) }

    func next() throws -> [ArcHistoryVisitRecord]? {
        guard let row = statement else { return nil }
        var batch: [ArcHistoryVisitRecord] = []
        batch.reserveCapacity(limit)
        while batch.count < limit {
            let status = sqlite3_step(row)
            if status == SQLITE_DONE {
                sqlite3_finalize(statement)
                statement = nil
                return batch.isEmpty ? nil : batch
            }
            guard status == SQLITE_ROW else { throw ArcHistoryImportError.schemaMismatch }
            report.sourceVisitRows += 1
            guard let (url, title) = urls[sqlite3_column_int64(row, 1)],
                  let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
                report.skippedInternal += 1
                continue
            }
            let core = Int(sqlite3_column_int64(row, 3) & 0xFF)
            if core == 3 || core == 4 { report.skippedSubframe += 1; continue }
            let micros = sqlite3_column_int64(row, 2)
            guard micros > offsetMicros else { report.skippedInvalidTime += 1; continue }
            let seconds = Double(micros - offsetMicros) / 1_000_000.0
            guard let time = validatedImportDate(unixSeconds: seconds) else { report.skippedInvalidTime += 1; continue }
            batch.append(ArcHistoryVisitRecord(chromiumVisitID: sqlite3_column_int64(row, 0), urlString: url, title: title,
                                               time: time, transition: core < transitions.count ? transitions[core] : "link", isTyped: core == 1))
            report.keptVisits += 1
        }
        return batch
    }
}

/// Shared bound for history and secret timestamps. Zero is not a real date.
func validatedImportDate(unixSeconds: Double) -> Date? {
    guard unixSeconds.isFinite, unixSeconds > 0,
          unixSeconds <= Date().timeIntervalSince1970 + 24 * 60 * 60 else { return nil }
    return Date(timeIntervalSince1970: unixSeconds)
}

/// Creates the destination at its final private mode before the first byte is written.
func copyPrivateSQLiteFile(from source: String, to destination: String) throws {
    let input = Darwin.open(source, O_RDONLY | O_NOFOLLOW)
    guard input >= 0 else { throw ArcHistoryImportError.copyFailed }
    defer { Darwin.close(input) }
    var info = stat()
    guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ArcHistoryImportError.copyFailed }
    let output = Darwin.open(destination, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard output >= 0 else { throw ArcHistoryImportError.copyFailed }
    defer { Darwin.close(output) }
    var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    defer { zeroSecretBytes(&buffer) }
    try buffer.withUnsafeMutableBytes { bytes in
        var copied=0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(input, bytes.baseAddress!, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ArcHistoryImportError.copyFailed }
            if count == 0 { return }
            var offset = 0
            while offset < count {
                let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ArcHistoryImportError.copyFailed }
                offset += written
            }
            copied += count
            ArcCopyAudit.observer?(URL(fileURLWithPath:destination).deletingLastPathComponent(),copied)
        }
    }
}

/// CLI startup cleanup. Only old, user-owned directories with our prefix qualify.
/// lstat excludes symlinks. Active copies younger than one hour are left alone.
@discardableResult
public func sweepStaleImportCopies() -> Int {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
    guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return 0 }
    let cutoff = Date().timeIntervalSince1970 - 3600
    var removed = 0
    for entry in entries where entry.lastPathComponent.hasPrefix("open-history-import-") {
        var info = stat()
        guard lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), Double(info.st_mtimespec.tv_sec) < cutoff else { continue }
        do { try fm.removeItem(at: entry); removed += 1 } catch { continue }
    }
    return removed
}
