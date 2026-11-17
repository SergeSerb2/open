import Foundation
import SQLite3

/// Where Safari data comes from: the live files (Full Disk Access) or a user-picked export ZIP.
/// A user-picked `Passwords.csv` can come with either.
public struct SafariImportFiles: Sendable, Hashable {
    public var exportArchive: URL?
    public var passwordsCSV: URL?
    public init(exportArchive: URL? = nil, passwordsCSV: URL? = nil) { self.exportArchive = exportArchive; self.passwordsCSV = passwordsCSV }
}

/// Counts and reads for the Firefox and Safari families, behind one interface for the wizard and the App runner.
/// The Chromium family keeps `ChromiumProfileReader`.
public struct BrowserImportReader: Sendable {
    public let family: BrowserFamily
    public let profile: BrowserSourceProfile
    public let safari: SafariImportFiles

    public init(family: BrowserFamily, profile: BrowserSourceProfile, safari: SafariImportFiles = .init()) {
        self.family = family; self.profile = profile; self.safari = safari
    }

    public struct Counts: Sendable, Equatable {
        public var bookmarks: Int?
        public var historyVisits: Int?
        public var passwords: Int?
        public var openTabs: Int?
        /// Firefox: logins exist but a Primary Password protects them.
        public var needsPrimaryPassword = false
        public var unreadable: Set<String> = []
        public init() {}
    }

    /// Cheap enough for the Choose step: counts only, values never leave the reader.
    public func counts() -> Counts {
        var c = Counts()
        switch family {
        case .firefox:
            let places = FirefoxPlacesReader(profileDirectory: profile.directory)
            do { c.bookmarks = try places.readBookmarks().report.urls } catch { mark(&c, "Bookmarks", error) }
            do { c.historyVisits = try places.visitCount() } catch { mark(&c, "History", error) }
            let logins = FirefoxLoginsReader(profileDirectory: profile.directory)
            if let count = try? logins.countOnly(), count > 0 {
                c.passwords = count
                c.needsPrimaryPassword = (try? logins.needsPrimaryPassword()) ?? false
            }
            if let session = try? FirefoxSessionReader(profileDirectory: profile.directory).read(), session.report.kept > 0 {
                c.openTabs = session.report.kept
            }
        case .safari:
            if let archive = safari.exportArchive {
                guard let reader = try? SafariExportReader(url: archive) else {
                    c.unreadable = ["Bookmarks", "History", "Passwords"]; return c
                }
                if reader.contents.bookmarks { c.bookmarks = (try? reader.readBookmarks().report.urls); if c.bookmarks == nil { c.unreadable.insert("Bookmarks") } }
                if reader.contents.history { c.historyVisits = reader.historyCount(); if c.historyVisits == nil { c.unreadable.insert("History") } }
                if reader.contents.passwords { c.passwords = reader.passwordsCount(); if c.passwords == nil { c.unreadable.insert("Passwords") } }
            } else {
                let live = SafariLiveReader(directory: profile.directory)
                do { c.bookmarks = try live.readBookmarks().report.urls } catch { mark(&c, "Bookmarks", error) }
                do { c.historyVisits = try live.visitCount() } catch { mark(&c, "History", error) }
            }
            // `passwords()` imports the archive's member and the CSV together, so the count is their sum.
            // A readable CSV must not clear the archive's unreadable mark: the import would still fail on it.
            if let csv = safari.passwordsCSV {
                var data = (try? Data(contentsOf: csv)) ?? Data()
                defer { data.resetBytes(in: 0..<data.count) }
                if !data.isEmpty, let read = try? PasswordsCSVReader.read(data) {
                    var logins = read.logins
                    for i in logins.indices { logins[i].zeroSecrets() }
                    c.passwords = (c.passwords ?? 0) + read.report.kept
                } else { c.passwords = nil; c.unreadable.insert("Passwords") }
            }
        case .arc, .chromium: break
        }
        return c
    }

    private func mark(_ c: inout Counts, _ category: String, _ error: any Error) {
        switch error {
        case FirefoxImportError.missingFile, SafariImportError.missingFile: break
        default: c.unreadable.insert(category)
        }
    }

    public func bookmarks() throws -> (roots: [ImportedBookmark], report: ImportedBookmarksReport) {
        switch family {
        case .firefox: return try FirefoxPlacesReader(profileDirectory: profile.directory).readBookmarks()
        case .safari:
            if let archive = safari.exportArchive { return try SafariExportReader(url: archive).readBookmarks() }
            return try SafariLiveReader(directory: profile.directory).readBookmarks()
        case .arc, .chromium: return ([], ImportedBookmarksReport())
        }
    }

    /// Streams visits in batches of at most 5,000. Returns the number of kept visits.
    public func history(consume: ([ArcHistoryVisitRecord]) async -> Void) async throws -> Int {
        switch family {
        case .firefox: return try await FirefoxPlacesReader(profileDirectory: profile.directory).readHistory(consume: consume).keptVisits
        case .safari:
            if let archive = safari.exportArchive { return try await SafariExportReader(url: archive).readHistory(consume: consume).kept }
            return try await SafariLiveReader(directory: profile.directory).readHistory(consume: consume).kept
        case .arc, .chromium: return 0
        }
    }

    /// I-6: the current entry of each tab in the last session. Firefox family only.
    public func openTabs() throws -> (tabs: [ImportedOpenTab], report: ImportedOpenTabsReport) {
        guard family == .firefox else { return ([], ImportedOpenTabsReport()) }
        return try FirefoxSessionReader(profileDirectory: profile.directory).read()
    }

    /// Callers zero every record after the write. Firefox needs the Primary Password when one is set.
    public func passwords(primaryPassword: String = "") throws -> (logins: [ImportedLoginRecord], skipped: Int) {
        switch family {
        case .firefox:
            let read = try FirefoxLoginsReader(profileDirectory: profile.directory).read(primaryPassword: primaryPassword)
            return (read.logins, read.report.sourceRows - read.report.kept)
        case .safari:
            var logins: [ImportedLoginRecord] = [], skipped = 0
            if let archive = safari.exportArchive {
                let read = try SafariExportReader(url: archive).readPasswords()
                logins += read.logins; skipped += read.report.sourceRows - read.report.kept
            }
            if let csv = safari.passwordsCSV {
                guard var data = try? Data(contentsOf: csv) else { throw SafariImportError.unreadable("passwords") }
                defer { data.resetBytes(in: 0..<data.count) }
                let read = try PasswordsCSVReader.read(data)
                logins += read.logins; skipped += read.report.sourceRows - read.report.kept
            }
            return (logins, skipped)
        case .arc, .chromium: return ([], 0)
        }
    }
}

extension FirefoxPlacesReader {
    public func visitCount() throws -> Int {
        let copy = try openPlaces()
        do { return Int(try copy.integer("SELECT COUNT(*) FROM moz_historyvisits")) }
        catch { throw FirefoxImportError.schemaMismatch("places.sqlite") }
    }
}

extension SafariLiveReader {
    public func visitCount() throws -> Int {
        if SafariAccess.check(safariDirectory: directory) == .denied { throw SafariImportError.fullDiskAccessRequired }
        let copy: ArcSQLiteCopy
        do { copy = try ArcSQLiteCopy(fileURL: directory.appendingPathComponent("History.db")) }
        catch ArcHistoryImportError.missingHistoryFile { throw SafariImportError.missingFile("History.db") }
        catch { throw SafariImportError.unreadable("History.db") }
        do { return Int(try copy.integer("SELECT COUNT(*) FROM history_visits")) }
        catch { throw SafariImportError.unreadable("History.db") }
    }
}

extension SafariExportReader {
    func historyCount() -> Int? {
        guard let member = historyMember, let data = try? archive.extract(member),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["history"] as? [Any] else { return nil }
        return items.count
    }
    func passwordsCount() -> Int? {
        guard var read = try? readPasswords() else { return nil }
        for i in read.logins.indices { read.logins[i].zeroSecrets() }
        return read.report.kept
    }
}
