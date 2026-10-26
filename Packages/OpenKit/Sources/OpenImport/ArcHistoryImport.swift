import Foundation
import SQLite3

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

/// Recovery is allowed only on our private copy, never on the source connection.
/// Shared by the history and secret readers. Errors deliberately contain no SQL or row data.
final class ArcSQLiteCopy {
    private var connection: OpaquePointer?
    private let directory: URL

    init(fileURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { throw ArcHistoryImportError.missingHistoryFile }
        directory = fm.temporaryDirectory.appendingPathComponent("open-history-import-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for attempt in 0..<2 {
                do {
                    for suffix in ["", "-wal", "-shm", "-journal"] {
                        let source = URL(fileURLWithPath: fileURL.path + suffix)
                        let destination = directory.appendingPathComponent(fileURL.lastPathComponent + suffix)
                        if fm.fileExists(atPath: source.path) {
                            try fm.copyItem(at: source, to: destination)
                            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                        }
                    }
                    let path = directory.appendingPathComponent(fileURL.lastPathComponent).path
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
        while let batch = try cursor.next() { await consume(batch) }
        return cursor.report
    }
}

/// Confined to the one task that owns a read; never shared between batch consumers.
private final class ArcHistoryCursor {
    private let copy: ArcSQLiteCopy
    private var statement: OpaquePointer?
    private var urls: [Int64: (String, String)] = [:]
    private let limit: Int
    private let latest = Date().addingTimeInterval(24 * 60 * 60).timeIntervalSince1970
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
            guard seconds <= latest else { report.skippedInvalidTime += 1; continue }
            batch.append(ArcHistoryVisitRecord(chromiumVisitID: sqlite3_column_int64(row, 0), urlString: url, title: title,
                                               time: Date(timeIntervalSince1970: seconds), transition: core < transitions.count ? transitions[core] : "link", isTyped: core == 1))
            report.keptVisits += 1
        }
        return batch
    }
}
