import Foundation
import SQLite3

public enum FirefoxImportError: Error, Equatable {
    case missingFile(String)
    case unreadable(String)
    case schemaMismatch(String)
    case profileInUse
    case primaryPasswordRequired
}

/// Reads `places.sqlite` from a private copy (`ArcSQLiteCopy`), so the source is never opened for writing.
/// Schema facts: docs/re/browser-import.md §4.3 (moz_bookmarks, moz_places, moz_historyvisits).
public struct FirefoxPlacesReader: Sendable {
    public let profileDirectory: URL
    /// Gecko schema versions this reader accepts (Firefox 60 = 52; Zen 1.24 = 87, DISK in F3).
    public static let schemaVersions = 43...120
    public init(profileDirectory: URL) { self.profileDirectory = profileDirectory }

    static func open(_ file: URL, name: String) throws -> ArcSQLiteCopy {
        do { return try ArcSQLiteCopy(fileURL: file) }
        catch ArcHistoryImportError.missingHistoryFile { throw FirefoxImportError.missingFile(name) }
        catch { throw FirefoxImportError.unreadable(name) }
    }

    func openPlaces() throws -> ArcSQLiteCopy {
        let copy = try Self.open(profileDirectory.appendingPathComponent("places.sqlite"), name: "places.sqlite")
        guard let version = try? copy.integer("PRAGMA user_version"), Self.schemaVersions.contains(Int(version)) else {
            throw FirefoxImportError.schemaMismatch("places.sqlite")
        }
        return copy
    }

    // MARK: Bookmarks

    static let rootNames: [(guid: String, title: String)] = [
        ("toolbar_____", "Bookmarks Toolbar"), ("menu________", "Bookmarks Menu"),
        ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks"),
    ]

    public func readBookmarks() throws -> (roots: [ImportedBookmark], report: ImportedBookmarksReport) {
        let copy = try openPlaces()
        struct Row { var id: Int64; var type: Int; var parent: Int64; var title: String; var guid: String; var added: Int64; var url: String? }
        var rows: [Int64: Row] = [:]
        var children: [Int64: [Int64]] = [:]
        var rootID: Int64?
        do {
            try copy.rows("""
                SELECT b.id, b.type, b.parent, b.title, b.guid, b.dateAdded, p.url
                FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position, b.id
                """) { s in
                let row = Row(id: sqlite3_column_int64(s, 0), type: Int(sqlite3_column_int(s, 1)), parent: sqlite3_column_int64(s, 2),
                              title: copy.text(s, 3), guid: copy.text(s, 4), added: sqlite3_column_int64(s, 5),
                              url: sqlite3_column_type(s, 6) == SQLITE_NULL ? nil : copy.text(s, 6))
                rows[row.id] = row
                if row.guid == "root________" { rootID = row.id } else { children[row.parent, default: []].append(row.id) }
            }
        } catch { throw FirefoxImportError.schemaMismatch("places.sqlite") }
        var report = ImportedBookmarksReport()
        report.sourceRows = rows.count - (rootID == nil ? 0 : 1)
        var reached = Set<Int64>()
        func skipSubtree(_ id: Int64) {
            reached.insert(id); report.skippedOther += 1
            for child in children[id] ?? [] { skipSubtree(child) }
        }
        func build(_ id: Int64, titleOverride: String? = nil) -> ImportedBookmark? {
            guard let row = rows[id] else { return nil }
            reached.insert(id)
            switch row.type {
            case 1:
                guard let raw = row.url, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                      ["http", "https", "file"].contains(scheme) else { report.skippedUnsupportedURL += 1; return nil }
                report.urls += 1
                let added = row.added > 0 ? validatedImportDate(unixSeconds: Double(row.added) / 1_000_000) : nil
                return .url(sourceID: row.guid.isEmpty ? String(row.id) : row.guid, title: row.title, url: url, dateAdded: added)
            case 2:
                let kids = (children[id] ?? []).compactMap { build($0) }
                guard !kids.isEmpty else { report.skippedEmptyFolders += 1; return nil }
                report.folders += 1
                return .folder(sourceID: row.guid.isEmpty ? String(row.id) : row.guid, title: titleOverride ?? row.title, children: kids)
            case 3: report.skippedSeparators += 1; return nil
            default: report.skippedOther += 1; return nil
            }
        }
        var roots: [ImportedBookmark] = []
        if let rootID {
            let topLevel = children[rootID] ?? []
            for (guid, title) in Self.rootNames {
                guard let id = topLevel.first(where: { rows[$0]?.guid == guid }) else { continue }
                if let root = build(id, titleOverride: title) { roots.append(root) }
            }
            // The tags root and unknown roots are not bookmarks.
            for id in topLevel where !reached.contains(id) { skipSubtree(id) }
        }
        // Rows whose parent chain does not reach the root (orphans) are not imported.
        for id in rows.keys where id != rootID && !reached.contains(id) { reached.insert(id); report.skippedOther += 1 }
        guard report.accounted == report.sourceRows else { throw FirefoxImportError.schemaMismatch("places.sqlite") }
        return (roots, report)
    }

    // MARK: History

    /// Streams visits oldest first in batches of at most 5,000, as `ArcHistoryReader` does.
    /// `chromiumVisitID` carries the Gecko `moz_historyvisits.id`; the caller's source key keeps them apart.
    public func readHistory(batchSize: Int = 5000, consume: ([ArcHistoryVisitRecord]) async -> Void) async throws -> ArcHistoryReadReport {
        let copy = try openPlaces()
        var report = ArcHistoryReadReport()
        let limit = min(5000, max(1, batchSize))
        do {
            report.sourceURLRows = Int(try copy.integer("SELECT COUNT(*) FROM moz_places"))
            let statement = try copy.prepare("""
                SELECT v.id, p.url, p.title, v.visit_date, v.visit_type
                FROM moz_historyvisits v LEFT JOIN moz_places p ON p.id = v.place_id ORDER BY v.visit_date ASC, v.id ASC
                """)
            defer { sqlite3_finalize(statement) }
            var batch: [ArcHistoryVisitRecord] = []
            batch.reserveCapacity(limit)
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw FirefoxImportError.schemaMismatch("places.sqlite") }
                report.sourceVisitRows += 1
                let type = Int(sqlite3_column_int(statement, 4))
                guard sqlite3_column_type(statement, 1) != SQLITE_NULL, let url = URL(string: copy.text(statement, 1)),
                      let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme), type != 7 else {
                    report.skippedInternal += 1; continue
                }
                // 4 = embed, 8 = framed link: Gecko's equivalents of Chromium subframes.
                if type == 4 || type == 8 { report.skippedSubframe += 1; continue }
                guard let time = validatedImportDate(unixSeconds: Double(sqlite3_column_int64(statement, 3)) / 1_000_000) else {
                    report.skippedInvalidTime += 1; continue
                }
                let transition = switch type { case 2: "typed"; case 3: "bookmark"; case 9: "reload"; default: "link" }
                batch.append(ArcHistoryVisitRecord(chromiumVisitID: sqlite3_column_int64(statement, 0), urlString: copy.text(statement, 1),
                    title: copy.text(statement, 2), time: time, transition: transition, isTyped: type == 2))
                report.keptVisits += 1
                if batch.count == limit {
                    try Task.checkCancellation()
                    await consume(batch); batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { try Task.checkCancellation(); await consume(batch) }
        } catch let error as FirefoxImportError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw FirefoxImportError.schemaMismatch("places.sqlite") }
        return report
    }

    /// Sites ranked by Gecko frecency, for the Favorites suggestions step (I-5).
    public func topSites(limit: Int = 20) throws -> [(url: URL, title: String, frecency: Int64, visits: Int64)] {
        let copy = try openPlaces()
        var result: [(URL, String, Int64, Int64)] = []
        do {
            try copy.rows("SELECT url, title, frecency, visit_count FROM moz_places WHERE hidden = 0 AND visit_count > 0 ORDER BY frecency DESC, id ASC LIMIT \(max(1, min(limit, 200)))") { s in
                if let url = URL(string: copy.text(s, 0)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    result.append((url, copy.text(s, 1), sqlite3_column_int64(s, 2), sqlite3_column_int64(s, 3)))
                }
            }
        } catch { throw FirefoxImportError.schemaMismatch("places.sqlite") }
        return result.map { (url: $0.0, title: $0.1, frecency: $0.2, visits: $0.3) }
    }
}

// MARK: Form history

/// One saved form-field value (Firefox "autocomplete data"; Chromium's `autofill` table).
public struct ImportedFormEntry: Sendable, Equatable {
    public var fieldName: String
    public var value: String
    public var timesUsed: Int
    public var firstUsed: Date?
    public var lastUsed: Date?
}

public struct FirefoxFormHistoryReport: Sendable, Equatable {
    public var sourceRows = 0
    public var kept = 0
    public var skippedEmpty = 0
    public var skippedOversize = 0
    public init() {}
}

public struct FirefoxFormHistoryReader: Sendable {
    public let profileDirectory: URL
    public init(profileDirectory: URL) { self.profileDirectory = profileDirectory }

    public func read(batchSize: Int = 5000, consume: ([ImportedFormEntry]) async -> Void) async throws -> FirefoxFormHistoryReport {
        let copy = try FirefoxPlacesReader.open(profileDirectory.appendingPathComponent("formhistory.sqlite"), name: "formhistory.sqlite")
        var report = FirefoxFormHistoryReport()
        let limit = min(5000, max(1, batchSize))
        do {
            let statement = try copy.prepare("SELECT fieldname, value, timesUsed, firstUsed, lastUsed FROM moz_formhistory ORDER BY id")
            defer { sqlite3_finalize(statement) }
            var batch: [ImportedFormEntry] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw FirefoxImportError.schemaMismatch("formhistory.sqlite") }
                report.sourceRows += 1
                let name = copy.text(statement, 0), value = copy.text(statement, 1)
                if name.isEmpty || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { report.skippedEmpty += 1; continue }
                // Chromium's autocomplete table limits a value to 1,024 characters.
                if name.utf8.count > 1024 || value.utf8.count > 1024 { report.skippedOversize += 1; continue }
                func date(_ column: Int32) -> Date? {
                    let micros = sqlite3_column_int64(statement, column)
                    return micros > 0 ? validatedImportDate(unixSeconds: Double(micros) / 1_000_000) : nil
                }
                batch.append(ImportedFormEntry(fieldName: name, value: value, timesUsed: Int(max(0, sqlite3_column_int64(statement, 2))),
                                               firstUsed: date(3), lastUsed: date(4)))
                report.kept += 1
                if batch.count == limit { try Task.checkCancellation(); await consume(batch); batch.removeAll(keepingCapacity: true) }
            }
            if !batch.isEmpty { try Task.checkCancellation(); await consume(batch) }
        } catch let error as FirefoxImportError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw FirefoxImportError.schemaMismatch("formhistory.sqlite") }
        return report
    }
}
