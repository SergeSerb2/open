import Foundation
import SQLite3

/// Writes a synthetic Safari export ZIP, a standalone Passwords.csv, a non-passwords file, and a
/// synthetic live `Library/Safari` (Bookmarks.plist + History.db). Every value is generated here.
public struct SyntheticSafariFixture: Sendable {
    public struct Expected: Codable, Sendable, Equatable {
        public var exportBookmarkRows = 0, exportBookmarkURLs = 0, exportBookmarkFolders = 0, exportSeparators = 0, exportUnsupported = 0, exportEmptyFolders = 0
        public var exportRootTitles: [String] = []
        public var exportHistoryRows = 0, exportHistoryKept = 0, exportHistoryInternal = 0, exportHistoryInvalid = 0
        public var passwordRows = 0, passwordsKept = 0, passwordsUnsupported = 0, passwordsEmpty = 0
        public var liveBookmarkRows = 0, liveBookmarkURLs = 0, liveBookmarkFolders = 0, liveUnsupported = 0, liveEmptyFolders = 0, liveOther = 0
        public var liveRootTitles: [String] = []
        public var liveHistoryRows = 0, liveHistoryKept = 0, liveHistoryInternal = 0
    }

    public let root: URL
    public var exportZip: URL { root.appendingPathComponent("Safari Export.zip") }
    public var passwordsCSV: URL { root.appendingPathComponent("Passwords.csv") }
    public var notPasswords: URL { root.appendingPathComponent("Notes.csv") }
    public var liveDirectory: URL { root.appendingPathComponent("Library/Safari", isDirectory: true) }
    public let expected: Expected

    public static func readExpected(root: URL) -> Expected? {
        (try? Data(contentsOf: root.appendingPathComponent("expected.json"))).flatMap { try? JSONDecoder().decode(Expected.self, from: $0) }
    }

    public static func write(to root: URL, historyItems: Int = 6_000) throws -> SyntheticSafariFixture {
        let fm = FileManager.default
        guard try !fm.fileExists(atPath: root.path) || fm.contentsOfDirectory(atPath: root.path).isEmpty else { throw CocoaError(.fileWriteFileExists) }
        try fm.createDirectory(at: root.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
        var e = Expected()

        // Bookmarks HTML, in the Netscape format Safari exports.
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
          <DT><H3 FOLDED>Favorites</H3>
          <DL><p>
            <DT><A HREF="https://fav1.example.test/" ADD_DATE="1735689600">Fav &amp; One</A>
            <DT><A HREF="https://fav2.example.test/?a=1&amp;b=2">Fav Two</A>
            <DT><H3>Synthetic Work</H3>
            <DL><p>
              <DT><A HREF="https://work.example.test/">Work &#8211; Board</A>
              <HR>
              <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
              <DT><H3>Empty</H3>
              <DL><p>
              </DL><p>
            </DL><p>
          </DL><p>
          <DT><H3 id="com.apple.ReadingList">Reading List</H3>
          <DL><p>
            <DT><A HREF="https://read.example.test/article">Article</A>
          </DL><p>
          <DT><A HREF="https://loose.example.test/">Loose</A>
        </DL><p>
        """
        e.exportBookmarkRows = 11; e.exportBookmarkURLs = 5; e.exportBookmarkFolders = 3; e.exportSeparators = 1; e.exportUnsupported = 1; e.exportEmptyFolders = 1
        e.exportRootTitles = ["Favorites", "Reading List"]

        // History.json.
        var items: [[String: Any]] = []
        let base: Int64 = 1_735_689_600_000_000
        for i in 0..<historyItems {
            items.append(["url": "https://h\(i % 500).safari.example.test/p\(i)", "title": "Safari \(i)", "time_usec": base + Int64(i) * 30_000_000, "visit_count": 1])
        }
        items.append(["url": "about:blank", "title": "", "time_usec": base])
        items.append(["url": "https://no-time.example.test/", "title": "No time"])
        e.exportHistoryRows = historyItems + 2; e.exportHistoryKept = historyItems; e.exportHistoryInternal = 1; e.exportHistoryInvalid = 1
        let history = try JSONSerialization.data(withJSONObject: ["metadata": ["browser_name": "Safari", "data_type": "history", "schema_version": 1], "history": items])

        // Passwords.csv (Title, URL, Username, Password, Notes, OTPAuth).
        let q = "\""
        let csv = [
            "Title,URL,Username,Password,Notes,OTPAuth",
            "login1.example.com,https://login1.example.com/,synthetic-user-1,synthetic-pass-1,,",
            "\(q)Quoted, title\(q),https://login2.example.com:8443/path,synthetic-user-2,\(q)synthetic-pass-\(q)\(q)2\(q)\(q)\(q),\(q)multi\r\nline note\(q),",
            "app,login3.example.com,synthetic-user-3,synthetic-pass-3,,otpauth://totp/x",
            "bad,ftp://files.example.com,synthetic-user-4,synthetic-pass-4,,",
            "empty,https://empty.example.com,synthetic-user-5,,,",
            "",
        ].joined(separator: "\r\n")
        e.passwordRows = 5; e.passwordsKept = 3; e.passwordsUnsupported = 1; e.passwordsEmpty = 1
        try Data(csv.utf8).write(to: root.appendingPathComponent("Passwords.csv"))
        try Data("Name,Phone\nSynthetic,555-0100\n".utf8).write(to: root.appendingPathComponent("Notes.csv"))
        try ImportZipArchive.write([
            ("Safari Export/Bookmarks.html", Data(html.utf8), true),
            ("Safari Export/History.json", history, true),
            ("Safari Export/Passwords.csv", Data(csv.utf8), false),
        ], to: root.appendingPathComponent("Safari Export.zip"))

        // Live Bookmarks.plist (binary), with the History proxy and an empty BookmarksMenu.
        func leaf(_ url: String, _ title: String, _ uuid: String) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "URIDictionary": ["title": title], "WebBookmarkUUID": uuid]
        }
        func list(_ title: String, _ uuid: String, _ children: [[String: Any]]) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "WebBookmarkUUID": uuid, "Children": children]
        }
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Title": "", "WebBookmarkFileVersion": 1, "Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History", "WebBookmarkIdentifier": "History", "WebBookmarkUUID": "S-0001"],
            list("BookmarksMenu", "S-0002", []),
            list("com.apple.ReadingList", "S-0003", [leaf("https://live-read.example.test/", "Live read", "S-0004")]),
            list("BookmarksBar", "S-0005", [
                leaf("https://live1.example.test/", "Live One", "S-0006"),
                list("Synthetic Live Folder", "S-0007", [leaf("https://live2.example.test/", "Live Two", "S-0008"), leaf("feed://x.example.test/", "Feed", "S-0009")]),
            ]),
        ]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: root.appendingPathComponent("Library/Safari/Bookmarks.plist"))
        e.liveBookmarkRows = 9; e.liveBookmarkURLs = 3; e.liveBookmarkFolders = 3; e.liveUnsupported = 1; e.liveEmptyFolders = 1; e.liveOther = 1
        e.liveRootTitles = ["Favorites", "Reading List"]

        // Live History.db.
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("Library/Safari/History.db").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        var sql = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, domain_expansion TEXT NULL, visit_count INTEGER NOT NULL);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT NULL,
              load_successful BOOLEAN NOT NULL DEFAULT 1, http_non_get BOOLEAN NOT NULL DEFAULT 0, synthesized BOOLEAN NOT NULL DEFAULT 0);
            BEGIN;
            INSERT INTO history_items(id, url, visit_count) VALUES (1, 'https://live-history.example.test/a', 3), (2, 'https://live-history.example.test/b', 1), (3, 'about:blank', 1);
            """
        for i in 0..<4 { sql += "INSERT INTO history_visits(history_item, visit_time, title) VALUES (\(i < 3 ? 1 : 2), \(757_382_400 + i * 60), 'Live \(i)');" }
        sql += "INSERT INTO history_visits(history_item, visit_time, title) VALUES (3, 757382400, '');COMMIT;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        e.liveHistoryRows = 5; e.liveHistoryKept = 4; e.liveHistoryInternal = 1

        try JSONEncoder().encode(e).write(to: root.appendingPathComponent("expected.json"))
        return SyntheticSafariFixture(root: root, expected: e)
    }
}
