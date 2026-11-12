import Foundation
import SQLite3
import Security

/// Writes a synthetic Gecko data root (profiles.ini + two profiles) for the e2e import check.
/// Every value is generated here; no real browser data is read or copied. Login hosts are under
/// example.com: the mock-key engine accepts only those (open_profile_data_impl.cc FixtureHost).
/// Profile "Synthetic Default": PBES2/AES-256 key store, no Primary Password, 3DES and AES logins.
/// Profile "Synthetic Work": legacy SHA1+3DES key store protected by `primaryPassword`.
public struct SyntheticFirefoxFixture: Sendable {
    public struct Expected: Codable, Sendable, Equatable {
        public var profile: String
        public var bookmarkRows: Int
        public var bookmarkURLs: Int
        public var bookmarkFolders: Int
        public var bookmarkSeparators: Int
        public var bookmarkUnsupported: Int
        public var bookmarkEmptyFolders: Int
        public var bookmarkOther: Int
        public var visitRows: Int
        public var visitsKept: Int
        public var visitsInternal: Int
        public var visitsSubframe: Int
        public var visitsInvalidTime: Int
        public var formRows: Int
        public var formKept: Int
        public var loginRows: Int
        public var loginsKept: Int
        public var loginsUnsupported: Int
        public var primaryPassword: Bool
        /// Top-level folders of "Imported from Firefox", in order.
        public var rootTitles: [String]
        /// I-6: the last session (default profile only).
        public var openTabWindows = 0, openTabRows = 0, openTabsKept = 0, openTabsUnsupported = 0, openTabsEmpty = 0
        public var openTabURLs: [String] = []
    }

    public static let primaryPassword = "synthetic-primary"
    public let root: URL
    public let expected: [Expected]

    /// `visits` sets the visit count of the default profile (to cross the 5,000-row batch boundary).
    public static func write(to root: URL, visits: Int = 7_000) throws -> SyntheticFirefoxFixture {
        let fm = FileManager.default
        guard try !fm.fileExists(atPath: root.path) || fm.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.createDirectory(at: root.appendingPathComponent("Profiles"), withIntermediateDirectories: true)
        let first = "Profiles/syn0001.default-release", second = "Profiles/syn0002.work"
        try """
        [Install4F96D1932A9F858E]
        Default=\(first)
        Locked=1

        [Profile1]
        Name=Synthetic Work
        IsRelative=1
        Path=\(second)

        [Profile0]
        Name=Synthetic Default
        IsRelative=1
        Path=\(first)
        Default=1

        [General]
        StartWithLastProfile=1
        Version=2

        """.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        try "[4F96D1932A9F858E]\nDefault=\(first)\nLocked=1\n".write(to: root.appendingPathComponent("installs.ini"), atomically: true, encoding: .utf8)
        var expected: [Expected] = []
        expected.append(try writeProfile(root.appendingPathComponent(first), name: "Synthetic Default", visits: max(0, visits), seed: 1, primary: nil))
        expected.append(try writeProfile(root.appendingPathComponent(second), name: "Synthetic Work", visits: 40, seed: 2, primary: primaryPassword))
        let data = try JSONEncoder().encode(expected)
        try data.write(to: root.appendingPathComponent("expected.json"))
        return SyntheticFirefoxFixture(root: root, expected: expected)
    }

    public static func readExpected(root: URL) -> [Expected]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("expected.json")) else { return nil }
        return try? JSONDecoder().decode([Expected].self, from: data)
    }

    // MARK: Profile

    private static func writeProfile(_ dir: URL, name: String, visits: Int, seed: Int, primary: String?) throws -> Expected {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "".write(to: dir.appendingPathComponent(".parentlock"), atomically: true, encoding: .utf8)
        var e = Expected(profile: name, bookmarkRows: 0, bookmarkURLs: 0, bookmarkFolders: 0, bookmarkSeparators: 0,
                         bookmarkUnsupported: 0, bookmarkEmptyFolders: 0, bookmarkOther: 0, visitRows: 0, visitsKept: 0,
                         visitsInternal: 0, visitsSubframe: 0, visitsInvalidTime: 0, formRows: 0, formKept: 0,
                         loginRows: 0, loginsKept: 0, loginsUnsupported: 0, primaryPassword: primary != nil, rootTitles: [])
        try writePlaces(dir.appendingPathComponent("places.sqlite"), visits: visits, seed: seed, expected: &e)
        try writeFormHistory(dir.appendingPathComponent("formhistory.sqlite"), seed: seed, expected: &e)
        try writeLogins(dir, seed: seed, primary: primary, expected: &e)
        if primary == nil { try writeSession(dir, seed: seed, expected: &e) }
        return e
    }

    private static func writePlaces(_ file: URL, visits: Int, seed: Int, expected e: inout Expected) throws {
        let db = try FixtureDB(file)
        try db.exec("""
            PRAGMA journal_mode = WAL; PRAGMA user_version = 75;
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR,
              visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL,
              frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT, foreign_count INTEGER DEFAULT 0 NOT NULL,
              url_hash INTEGER DEFAULT 0 NOT NULL, description TEXT, preview_image_url TEXT, origin_id INTEGER);
            CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER, visit_date INTEGER,
              visit_type INTEGER, session INTEGER, source INTEGER DEFAULT 0 NOT NULL, triggeringPlaceId INTEGER);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER,
              position INTEGER, title LONGVARCHAR, keyword_id INTEGER, folder_type TEXT, dateAdded INTEGER, lastModified INTEGER,
              guid TEXT, syncStatus INTEGER NOT NULL DEFAULT 0, syncChangeCounter INTEGER NOT NULL DEFAULT 1);
            BEGIN;
            """)
        let base: Int64 = 1_735_689_600_000_000 // 2025-01-01, microseconds since 1970
        var placeID: Int64 = 0
        @discardableResult func place(_ url: String, _ title: String, visits: Int = 0, frecency: Int = 0) throws -> Int64 {
            placeID += 1
            try db.run("INSERT INTO moz_places(id, url, title, visit_count, frecency, guid) VALUES(?, ?, ?, ?, ?, ?)",
                       [.int(placeID), .text(url), .text(title), .int(Int64(visits)), .int(Int64(frecency)), .text("p\(seed)-\(placeID)")])
            return placeID
        }
        // Bookmarks. Every row except the root is counted once in `expected`.
        var bookmarkID: Int64 = 0
        @discardableResult func bookmark(_ type: Int, parent: Int64, position: Int, title: String, guid: String? = nil, fk: Int64? = nil) throws -> Int64 {
            bookmarkID += 1
            try db.run("INSERT INTO moz_bookmarks(id, type, fk, parent, position, title, dateAdded, lastModified, guid) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       [.int(bookmarkID), .int(Int64(type)), fk.map { .int($0) } ?? .null, .int(parent), .int(Int64(position)), .text(title),
                        .int(base + bookmarkID * 1_000_000), .int(base + bookmarkID * 1_000_000), .text(guid ?? "bm\(seed)-\(bookmarkID)xxxxx")])
            if parent != 0 { e.bookmarkRows += 1 }
            return bookmarkID
        }
        let root = try bookmark(2, parent: 0, position: 0, title: "", guid: "root________")
        let menu = try bookmark(2, parent: root, position: 0, title: "menu", guid: "menu________")
        let toolbar = try bookmark(2, parent: root, position: 1, title: "toolbar", guid: "toolbar_____")
        let tags = try bookmark(2, parent: root, position: 2, title: "tags", guid: "tags________")
        _ = try bookmark(2, parent: root, position: 3, title: "unfiled", guid: "unfiled_____")
        _ = try bookmark(2, parent: root, position: 4, title: "mobile", guid: "mobile______")
        e.bookmarkFolders += 2; e.bookmarkEmptyFolders += 2
        e.rootTitles = ["Bookmarks Toolbar", "Bookmarks Menu"]
        for index in 0..<3 {
            try bookmark(1, parent: toolbar, position: index, title: "Toolbar site \(seed)-\(index)",
                         fk: try place("https://toolbar\(index).example.test/s\(seed)", "Toolbar \(index)"))
            e.bookmarkURLs += 1
        }
        let nested = try bookmark(2, parent: toolbar, position: 3, title: "Synthetic Nested \(seed)")
        e.bookmarkFolders += 1
        try bookmark(1, parent: nested, position: 0, title: "Nested site", fk: try place("https://nested.example.test/\(seed)", "Nested"))
        try bookmark(3, parent: nested, position: 1, title: "")
        try bookmark(1, parent: nested, position: 2, title: "Most visited", fk: try place("place:sort=8&maxResults=10", "Most visited"))
        let deeper = try bookmark(2, parent: nested, position: 3, title: "Deeper")
        try bookmark(1, parent: deeper, position: 0, title: "Deep site", fk: try place("http://deep.example.test/\(seed)", "Deep"))
        let emptyChild = try bookmark(2, parent: nested, position: 4, title: "Empty")
        _ = emptyChild
        e.bookmarkURLs += 2; e.bookmarkSeparators += 1; e.bookmarkUnsupported += 1; e.bookmarkFolders += 1; e.bookmarkEmptyFolders += 1
        try bookmark(1, parent: menu, position: 0, title: "Menu site", fk: try place("https://menu.example.test/\(seed)", "Menu"))
        try bookmark(1, parent: menu, position: 1, title: "Bookmarklet", fk: try place("javascript:void(0)", "Bookmarklet"))
        e.bookmarkURLs += 1; e.bookmarkUnsupported += 1
        let tag = try bookmark(2, parent: tags, position: 0, title: "synthetic-tag")
        try bookmark(1, parent: tag, position: 0, title: "", fk: 1)
        e.bookmarkOther += 3
        // History: one place per 10 visits; types cycle through every Gecko visit type.
        let invalid = try place("https://invalid-time.example.test/", "Invalid")
        let download = try place("https://downloads.example.test/file.zip", "Download")
        let internalPage = try place("about:preferences", "Settings")
        var visitID: Int64 = 0
        var current: Int64 = 0
        for index in 0..<visits {
            if index % 10 == 0 { current = try place("https://site\(index / 10).history.example.test/s\(seed)", "History \(seed) \(index / 10)", visits: 10, frecency: 10_000 - index / 10) }
            let type = [1, 2, 1, 3, 1, 4, 5, 6, 8, 9][index % 10]
            visitID += 1
            try db.run("INSERT INTO moz_historyvisits(id, from_visit, place_id, visit_date, visit_type, session) VALUES(?, 0, ?, ?, ?, 0)",
                       [.int(visitID), .int(current), .int(base + Int64(index) * 60_000_000), .int(Int64(type))])
            if type == 4 || type == 8 { e.visitsSubframe += 1 } else { e.visitsKept += 1 }
        }
        for (place, type, date, bucket) in [(invalid, 1, Int64(0), 0), (download, 7, base, 1), (internalPage, 1, base, 1)] {
            visitID += 1
            try db.run("INSERT INTO moz_historyvisits(id, from_visit, place_id, visit_date, visit_type, session) VALUES(?, 0, ?, ?, ?, 0)",
                       [.int(visitID), .int(place), .int(date), .int(Int64(type))])
            if bucket == 0 { e.visitsInvalidTime += 1 } else { e.visitsInternal += 1 }
        }
        // I-5: sites that match the onboarding Favorites catalog. GitHub and Wikipedia rank above the history
        // hosts; YouTube has 3 visits (the threshold) but ranks below them. Pages only, so the visit counts above stay.
        try place("https://github.com/synthetic/repo", "Synthetic repo", visits: 40, frecency: 20_000)
        try place("https://en.wikipedia.org/wiki/Main_Page", "Wikipedia", visits: 12, frecency: 15_000)
        try place("https://www.youtube.com/watch?v=synthetic", "YouTube", visits: 3, frecency: 14_000)
        e.visitRows = Int(visitID)
        try db.exec("COMMIT;")
    }

    /// `sessionstore-backups/recovery.jsonlz4`: two windows; a pinned tab, a tab with back history, an
    /// `about:` tab and a tab with no entries. A real LZ4 block (Apple's encoder) with repeated text.
    private static func writeSession(_ dir: URL, seed: Int, expected e: inout Expected) throws {
        func entry(_ url: String, _ title: String) -> [String: Any] { ["url": url, "title": title, "triggeringPrincipal_base64": String(repeating: "eyJ", count: 20)] }
        let windows: [[String: Any]] = [
            ["tabs": [
                ["entries": [entry("https://pinned.session.example.test/s\(seed)", "Pinned")], "index": 1, "pinned": true, "lastAccessed": 1_735_689_600_000],
                ["entries": [entry("https://back.session.example.test/1", "Back"), entry("https://current.session.example.test/2", "Current")], "index": 2, "lastAccessed": 1_735_776_000_000],
                ["entries": [entry("about:newtab", "New Tab")], "index": 1],
            ], "selected": 2],
            ["tabs": [
                ["entries": [entry("https://second.session.example.test/w2", "Second window")], "index": 1],
                ["entries": [], "index": 0],
                ["entries": [entry("https://third.session.example.test/w2", "Third")], "index": 1, "hidden": false],
            ]],
        ]
        let json = try JSONSerialization.data(withJSONObject: ["version": ["sessionrestore", 1], "windows": windows, "selectedWindow": 1], options: [.sortedKeys])
        guard let packed = FirefoxSessionReader.encodeMozLz4(json) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessionstore-backups"), withIntermediateDirectories: true)
        try packed.write(to: dir.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"))
        e.openTabWindows = 2; e.openTabRows = 6; e.openTabsKept = 4; e.openTabsUnsupported = 1; e.openTabsEmpty = 1
        e.openTabURLs = ["https://pinned.session.example.test/s\(seed)", "https://current.session.example.test/2",
                         "https://second.session.example.test/w2", "https://third.session.example.test/w2"]
    }

    private static func writeFormHistory(_ file: URL, seed: Int, expected e: inout Expected) throws {
        let db = try FixtureDB(file)
        try db.exec("""
            PRAGMA user_version = 5;
            CREATE TABLE moz_formhistory (id INTEGER PRIMARY KEY, fieldname TEXT NOT NULL, value TEXT NOT NULL, timesUsed INTEGER,
              firstUsed INTEGER, lastUsed INTEGER, guid TEXT);
            """)
        let rows: [(String, String)] = [("email", "person\(seed)@example.test"), ("search", "synthetic query \(seed)"),
                                         ("city", "Testville"), ("name", "   "), ("comment", String(repeating: "x", count: 1100))]
        for (index, row) in rows.enumerated() {
            try db.run("INSERT INTO moz_formhistory(fieldname, value, timesUsed, firstUsed, lastUsed, guid) VALUES(?, ?, ?, ?, ?, ?)",
                       [.text(row.0), .text(row.1), .int(Int64(index + 1)), .int(1_735_689_600_000_000), .int(1_735_776_000_000_000), .text("fh\(seed)\(index)")])
        }
        e.formRows = rows.count; e.formKept = 3
    }

    private static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }

    private static func writeLogins(_ dir: URL, seed: Int, primary: String?, expected e: inout Expected) throws {
        let globalSalt = random(20), password = Array((primary ?? "").utf8)
        var key = random(32)
        defer { zeroSecretBytes(&key) }
        let check: DER, wrapped: DER
        if primary == nil {
            check = try FirefoxCrypto.encryptPBES2(FirefoxCrypto.passwordCheck + [2, 2], globalSalt: globalSalt, primaryPassword: password,
                                                   salt: random(32), ivTail: random(14), iterations: 10_000)
            wrapped = try FirefoxCrypto.encryptPBES2(key, globalSalt: globalSalt, primaryPassword: password, salt: random(32), ivTail: random(14), iterations: 10_000)
        } else {
            check = try FirefoxCrypto.encryptLegacyPBE(FirefoxCrypto.passwordCheck + [2, 2], globalSalt: globalSalt, primaryPassword: password, entrySalt: random(20))
            wrapped = try FirefoxCrypto.encryptLegacyPBE(key, globalSalt: globalSalt, primaryPassword: password, entrySalt: random(20))
        }
        let db = try FixtureDB(dir.appendingPathComponent("key4.db"))
        try db.exec("""
            CREATE TABLE metaData (id PRIMARY KEY UNIQUE ON CONFLICT REPLACE, item1, item2);
            CREATE TABLE nssPrivate (id PRIMARY KEY UNIQUE ON CONFLICT ABORT, a0, a1, a2, a3, a10, a11, a12, a81, a82, a83, a90, a100, a101, a102, a103);
            """)
        try db.run("INSERT INTO metaData(id, item1, item2) VALUES('password', ?, ?)", [.blob(globalSalt), .blob(check.encoded)])
        try db.run("INSERT INTO metaData(id, item1) VALUES('Version', 1)", [])
        // A decoy key row with another CKA_ID proves the reader selects by ID.
        try db.run("INSERT INTO nssPrivate(id, a11, a102) VALUES(1, ?, ?)", [.blob(random(48)), .blob([0xF8] + [UInt8](repeating: 0, count: 14) + [2])])
        try db.run("INSERT INTO nssPrivate(id, a11, a102) VALUES(2, ?, ?)", [.blob(wrapped.encoded), .blob(FirefoxCrypto.sdrKeyID)])
        var logins: [[String: Any]] = []
        func login(_ host: String, user: String, pass: String, aes: Bool, realm: String? = nil) throws {
            let iv = random(aes ? 16 : 8)
            var entry: [String: Any] = [
                "id": logins.count + 1, "hostname": host, "httpRealm": realm ?? NSNull(),
                "formSubmitURL": realm == nil ? host : NSNull(), "usernameField": realm == nil ? "email" : "", "passwordField": realm == nil ? "password" : "",
                "encryptedUsername": try FirefoxCrypto.encryptSDR(Array(user.utf8), key: key, iv: iv, aes: aes),
                "encryptedPassword": try FirefoxCrypto.encryptSDR(Array(pass.utf8), key: key, iv: random(aes ? 16 : 8), aes: aes),
                "guid": "{00000000-0000-4000-8000-0000000\(seed)\(String(format: "%04d", logins.count))}", "encType": 1,
                "timeCreated": 1_735_689_600_000, "timeLastUsed": 1_735_776_000_000, "timePasswordChanged": 1_735_689_600_000, "timesUsed": 2,
            ]
            if realm == nil { entry["httpRealm"] = NSNull() }
            logins.append(entry)
        }
        try login("https://login1.example.com", user: "synthetic-user-\(seed)-1", pass: "synthetic-pass-\(seed)-1", aes: false)
        try login("https://login2.example.com:8443", user: "synthetic-user-\(seed)-2", pass: "synthetic-pass-\(seed)-2", aes: true)
        try login("https://auth.example.com", user: "synthetic-user-\(seed)-3", pass: "synthetic-pass-\(seed)-3", aes: false, realm: "Synthetic Realm")
        try login("chrome://FirefoxAccounts", user: "synthetic-sync-\(seed)", pass: "synthetic-sync", aes: false)
        e.loginRows = 4; e.loginsKept = 3; e.loginsUnsupported = 1
        let json: [String: Any] = ["nextId": logins.count + 1, "logins": logins, "potentiallyVulnerablePasswords": [],
                                   "dismissedBreachAlertsByLoginGUID": [:], "version": 3]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: dir.appendingPathComponent("logins.json"))
    }
}

/// Small write helper for fixtures only.
private final class FixtureDB {
    enum Value { case int(Int64), text(String), blob([UInt8]), null }
    private var db: OpaquePointer?
    init(_ file: URL) throws {
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
    deinit { sqlite3_close(db) }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
    func run(_ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, i, v)
            case .text(let v): sqlite3_bind_text(statement, i, v, -1, transient)
            case .blob(let v): sqlite3_bind_blob(statement, i, v, Int32(v.count), transient)
            case .null: sqlite3_bind_null(statement, i)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
}
