import Foundation
import SQLite3
import Darwin

/// Safari import. Evidence: docs/re/browser-import.md §1, §2 (Safari passwords), §4.2.
/// Two routes: the user-picked "Export Browsing Data" ZIP (no permission needed) and the live
/// files in `~/Library/Safari` behind Full Disk Access. Safari passwords come only from a user export.
public enum SafariImportError: Error, Equatable {
    case fullDiskAccessRequired
    case missingFile(String)
    case unreadable(String)
    case notPasswordsFile
    case notExportArchive
}

// MARK: Access

public enum SafariAccess: Equatable, Sendable {
    case granted, denied, notFound

    /// Opens and closes `Bookmarks.plist` without reading a byte. EPERM/EACCES is the TCC
    /// Full Disk Access gate (DISK in F3: "Operation not permitted").
    public static func check(safariDirectory: URL = SafariLiveReader.defaultDirectory) -> SafariAccess {
        let fd = Darwin.open(safariDirectory.appendingPathComponent("Bookmarks.plist").path, O_RDONLY | O_NOFOLLOW)
        if fd >= 0 { Darwin.close(fd); return .granted }
        return errno == ENOENT ? .notFound : .denied
    }

    /// System Settings ▸ Privacy & Security ▸ Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

// MARK: Passwords CSV

public struct PasswordsCSVReport: Sendable, Equatable {
    public var sourceRows = 0
    public var kept = 0
    public var skippedUnsupportedOrigin = 0
    public var skippedEmptyPassword = 0
    public var skippedOversize = 0
    public init() {}
    public var accounted: Int { kept + skippedUnsupportedOrigin + skippedEmptyPassword + skippedOversize }
}

/// Safari/Passwords-app CSV (Title, URL, Username, Password, Notes, OTPAuth) and the Chrome-style
/// CSV (name, url, username, password, note). Columns are found by header name.
public enum PasswordsCSVReader {
    public static func read(_ data: Data) throws -> (logins: [ImportedLoginRecord], report: PasswordsCSVReport) {
        guard data.count <= 32 << 20 else { throw SafariImportError.notPasswordsFile }
        var rows = parseCSV(data)
        defer { for i in rows.indices { for j in rows[i].indices { rows[i][j] = "" } } }
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
              let urlColumn = header.firstIndex(where: { $0 == "url" || $0 == "website" || $0 == "login_uri" }),
              let userColumn = header.firstIndex(where: { $0 == "username" || $0 == "login_username" }),
              let passColumn = header.firstIndex(where: { $0 == "password" || $0 == "login_password" }) else {
            throw SafariImportError.notPasswordsFile
        }
        let noteColumn = header.firstIndex { $0 == "notes" || $0 == "note" }
        var report = PasswordsCSVReport(), logins: [ImportedLoginRecord] = []
        for row in rows.dropFirst() where !(row.count == 1 && row[0].isEmpty) {
            report.sourceRows += 1
            func field(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            let raw = field(urlColumn).trimmingCharacters(in: .whitespaces)
            let withScheme = raw.contains("://") ? raw : "https://" + raw
            guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else { report.skippedUnsupportedOrigin += 1; continue }
            let password = field(passColumn)
            guard !password.isEmpty else { report.skippedEmptyPassword += 1; continue }
            let user = field(userColumn), note = field(noteColumn)
            guard user.utf8.count <= 16 * 1024, password.utf8.count <= 16 * 1024, note.utf8.count <= 16 * 1024 else { report.skippedOversize += 1; continue }
            let origin = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/"
            var record = ImportedLoginRecord(originURLString: origin, actionURLString: nil, username: user, passwordBytes: Array(password.utf8),
                                             signonRealm: origin, dateCreated: Date(), isBlacklisted: false, timesUsed: 0)
            record.noteBytes = Array(note.utf8)
            logins.append(record)
            report.kept += 1
        }
        return (logins, report)
    }

    /// RFC 4180: quoted fields, doubled quotes, CRLF or LF.
    static func parseCSV(_ data: Data) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var iterator = String(decoding: data, as: UTF8.self).unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        if pending == "\u{FEFF}" { pending = iterator.next() }
        while let c = pending {
            pending = iterator.next()
            if quoted {
                if c == "\"" { if pending == "\"" { field.unicodeScalars.append("\""); pending = iterator.next() } else { quoted = false } }
                else { field.unicodeScalars.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r" {
                if c == "\r", pending == "\n" { pending = iterator.next() }
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.unicodeScalars.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

// MARK: Export archive

public struct SafariHistoryReport: Sendable, Equatable {
    public var sourceRows = 0
    public var kept = 0
    public var skippedInternal = 0
    public var skippedInvalidTime = 0
    public init() {}
}

/// Safari 18+ File ▸ Export Browsing Data. Members are found by name pattern, because the exact
/// member names are a guess until a user-made export is seen (browser-import.md §4.2).
public struct SafariExportReader: Sendable {
    public let archive: ImportZipArchive
    public init(url: URL) throws {
        do { archive = try ImportZipArchive(url: url) } catch { throw SafariImportError.notExportArchive }
        guard bookmarksMember != nil || historyMember != nil || passwordsMember != nil else { throw SafariImportError.notExportArchive }
    }

    var bookmarksMember: ImportZipArchive.Member? { archive.member { $0.hasSuffix(".html") || $0.hasSuffix(".htm") } }
    var historyMember: ImportZipArchive.Member? { archive.member { $0.hasPrefix("history") && $0.hasSuffix(".json") } }
    var passwordsMember: ImportZipArchive.Member? { archive.member { $0.hasPrefix("passwords") && $0.hasSuffix(".csv") } }
    public var contents: (bookmarks: Bool, history: Bool, passwords: Bool) { (bookmarksMember != nil, historyMember != nil, passwordsMember != nil) }

    public func readBookmarks() throws -> (roots: [ImportedBookmark], report: ImportedBookmarksReport) {
        guard let member = bookmarksMember else { return ([], ImportedBookmarksReport()) }
        guard let data = try? archive.extract(member), let parsed = try? BookmarksHTMLParser.parse(data) else { throw SafariImportError.unreadable("bookmarks") }
        return parsed
    }

    /// `History.json`: `{"history": [{url, title, time_usec, …}]}` (Arc's engine string:
    /// "Safari history JSON file missing 'history' array"). Each entry becomes one visit.
    /// The visit key is a stable hash of (url, time) because the export has no row IDs.
    public func readHistory(batchSize: Int = 5000, consume: ([ArcHistoryVisitRecord]) async -> Void) async throws -> SafariHistoryReport {
        guard let member = historyMember else { return SafariHistoryReport() }
        guard let data = try? archive.extract(member),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["history"] as? [[String: Any]] else { throw SafariImportError.unreadable("history") }
        var report = SafariHistoryReport(), batch: [ArcHistoryVisitRecord] = []
        let limit = min(5000, max(1, batchSize))
        let sorted = items.sorted { (($0["time_usec"] as? NSNumber)?.int64Value ?? 0) < (($1["time_usec"] as? NSNumber)?.int64Value ?? 0) }
        for item in sorted {
            report.sourceRows += 1
            guard let raw = item["url"] as? String, let url = URL(string: raw), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
                report.skippedInternal += 1; continue
            }
            let micros = (item["time_usec"] as? NSNumber)?.int64Value ?? 0
            guard micros > 0, let time = validatedImportDate(unixSeconds: Double(micros) / 1_000_000) else { report.skippedInvalidTime += 1; continue }
            batch.append(ArcHistoryVisitRecord(chromiumVisitID: stableVisitKey(raw, micros), urlString: raw, title: item["title"] as? String ?? "",
                                               time: time, transition: "link", isTyped: false))
            report.kept += 1
            if batch.count == limit { try Task.checkCancellation(); await consume(batch); batch.removeAll(keepingCapacity: true) }
        }
        if !batch.isEmpty { try Task.checkCancellation(); await consume(batch) }
        return report
    }

    public func readPasswords() throws -> (logins: [ImportedLoginRecord], report: PasswordsCSVReport) {
        guard let member = passwordsMember else { return ([], PasswordsCSVReport()) }
        guard var data = try? archive.extract(member) else { throw SafariImportError.unreadable("passwords") }
        defer { data.resetBytes(in: 0..<data.count) }
        return try PasswordsCSVReader.read(data)
    }
}

/// FNV-1a 63-bit: positive and stable across runs.
func stableVisitKey(_ url: String, _ time: Int64) -> Int64 {
    var hash: UInt64 = 14695981039346656037
    for byte in url.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    for i in 0..<8 { hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: time >> (8 * i)))) &* 1099511628211 }
    return Int64(bitPattern: hash & 0x7FFF_FFFF_FFFF_FFFF)
}

// MARK: Live files (Full Disk Access)

public struct SafariLiveReader: Sendable {
    public static var defaultDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true) }
    public let directory: URL
    public init(directory: URL = SafariLiveReader.defaultDirectory) { self.directory = directory }

    static let specialLists = ["BookmarksBar": "Favorites", "BookmarksMenu": "Bookmarks Menu", "com.apple.ReadingList": "Reading List"]

    public func readBookmarks() throws -> (roots: [ImportedBookmark], report: ImportedBookmarksReport) {
        switch SafariAccess.check(safariDirectory: directory) {
        case .denied: throw SafariImportError.fullDiskAccessRequired
        case .notFound: throw SafariImportError.missingFile("Bookmarks.plist")
        case .granted: break
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("Bookmarks.plist")), data.count <= 64 << 20,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SafariImportError.unreadable("Bookmarks.plist")
        }
        var report = ImportedBookmarksReport()
        func node(_ dict: [String: Any], path: String, titleOverride: String? = nil) -> ImportedBookmark? {
            report.sourceRows += 1
            let id = dict["WebBookmarkUUID"] as? String ?? path
            switch dict["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let raw = dict["URLString"] as? String, let url = URL(string: raw),
                      ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { report.skippedUnsupportedURL += 1; return nil }
                report.urls += 1
                let title = (dict["URIDictionary"] as? [String: Any])?["title"] as? String ?? raw
                return .url(sourceID: id, title: title, url: url, dateAdded: nil)
            case "WebBookmarkTypeList":
                let children = (dict["Children"] as? [[String: Any]] ?? []).enumerated().compactMap { node($1, path: path + "/" + String($0)) }
                guard !children.isEmpty else { report.skippedEmptyFolders += 1; return nil }
                report.folders += 1
                let title = titleOverride ?? (dict["Title"] as? String).map { Self.specialLists[$0] ?? $0 } ?? "Folder"
                return .folder(sourceID: id, title: title, children: children)
            default:
                // WebBookmarkTypeProxy (the History entry) and unknown types.
                report.skippedOther += 1; return nil
            }
        }
        // The root list itself is not a folder in the result: its children are the roots.
        let top = root["Children"] as? [[String: Any]] ?? []
        var roots: [ImportedBookmark] = []
        for (index, child) in top.enumerated() { if let n = node(child, path: String(index)) { roots.append(n) } }
        // Favorites first, as Safari shows them.
        roots.sort { a, b in
            func rank(_ n: ImportedBookmark) -> Int { if case .folder(_, "Favorites", _) = n { return 0 }; return 1 }
            return rank(a) < rank(b)
        }
        return (roots, report)
    }

    /// `History.db`: `history_visits.visit_time` is seconds since 2001-01-01 (Core Data reference date).
    public func readHistory(batchSize: Int = 5000, consume: ([ArcHistoryVisitRecord]) async -> Void) async throws -> SafariHistoryReport {
        if SafariAccess.check(safariDirectory: directory) == .denied { throw SafariImportError.fullDiskAccessRequired }
        let copy: ArcSQLiteCopy
        do { copy = try ArcSQLiteCopy(fileURL: directory.appendingPathComponent("History.db")) }
        catch ArcHistoryImportError.missingHistoryFile { throw SafariImportError.missingFile("History.db") }
        catch { throw SafariImportError.unreadable("History.db") }
        var report = SafariHistoryReport(), batch: [ArcHistoryVisitRecord] = []
        let limit = min(5000, max(1, batchSize))
        do {
            let statement = try copy.prepare("""
                SELECT v.id, i.url, v.title, v.visit_time FROM history_visits v LEFT JOIN history_items i ON i.id = v.history_item
                ORDER BY v.visit_time ASC, v.id ASC
                """)
            defer { sqlite3_finalize(statement) }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw SafariImportError.unreadable("History.db") }
                report.sourceRows += 1
                let raw = copy.text(statement, 1)
                guard let url = URL(string: raw), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { report.skippedInternal += 1; continue }
                guard let time = validatedImportDate(unixSeconds: sqlite3_column_double(statement, 3) + 978_307_200) else { report.skippedInvalidTime += 1; continue }
                batch.append(ArcHistoryVisitRecord(chromiumVisitID: sqlite3_column_int64(statement, 0), urlString: raw, title: copy.text(statement, 2),
                                                   time: time, transition: "link", isTyped: false))
                report.kept += 1
                if batch.count == limit { try Task.checkCancellation(); await consume(batch); batch.removeAll(keepingCapacity: true) }
            }
            if !batch.isEmpty { try Task.checkCancellation(); await consume(batch) }
        } catch let error as SafariImportError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw SafariImportError.unreadable("History.db") }
        return report
    }
}
