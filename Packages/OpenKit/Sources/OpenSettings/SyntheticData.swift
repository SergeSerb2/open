import Foundation
import OpenModel
import OpenSuggest
import OpenCommands
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OpenDesign
import OpenStore
import SQLite3

@MainActor public enum SyntheticData {
    public static func model() -> BrowserModel {
        let personal = Profile(id: ProfileID(uuidString: "10000000-0000-0000-0000-000000000001"), name: "Personal")
        let work = Profile(id: ProfileID(uuidString: "10000000-0000-0000-0000-000000000002"), name: "Work", dataDirectoryName: "Profile 1")
        personal.settings.searchEngineID = "google"
        work.settings.searchEngineID = "duckduckgo"; work.settings.searchSuggestEnabled = false
        work.settings.autoArchiveAfter = .twentyFourHours
        work.settings.customSearchEngines = [SearchEngine(id: "custom-docs", name: "Docs Search", keywords: ["docs"], searchURLTemplate: "https://example.com/search?q=%s", suggestURLTemplate: nil)]
        let spaces = ["Home", "Reading", "Office"].enumerated().map { i, name in Space(id: SpaceID(uuidString: "20000000-0000-0000-0000-00000000000\(i+1)"), title: name, profileID: i == 2 ? work.id : personal.id) }
        for (i, space) in spaces.enumerated() {
            for j in 0..<2 { space.pinned.append(.tab(Tab(id: ItemID(uuidString: "70000000-0000-0000-0000-0000000000\(i)\(j)"), url: URL(string: "https://example.com/pinned/\(i)/\(j)")!, title: "Example Pinned \(i+1).\(j+1)", pinnedURL: URL(string: "https://example.com/pinned/\(i)/\(j)")!, createdAt: fixtureDate))) }
            space.pinned.append(.folder(Folder(id: ItemID(uuidString: "71000000-0000-0000-0000-00000000000\(i+1)"), title: "Example Folder \(i+1)")))
        }
        let rules = [RoutingRule(id: RuleID(uuidString: "30000000-0000-0000-0000-000000000001"), match: .hostEquals("example.com"), destination: .space(spaces[0].id)), RoutingRule(id: RuleID(uuidString: "30000000-0000-0000-0000-000000000002"), match: .hostContains("docs"), destination: .space(spaces[2].id)), RoutingRule(id: RuleID(uuidString: "30000000-0000-0000-0000-000000000003"), match: .urlPrefix("https://example.net/a"), destination: .littleOpen(profile: nil))]
        let model = BrowserModel(profiles: [personal, work], spaces: spaces, windows: [BrowserWindowState(id: WindowID(uuidString: "40000000-0000-0000-0000-000000000001"), focusedSpaceID: spaces[0].id)], routingRules: rules)
        model.undoManager = UndoManager(); model.undoManager?.groupsByEvent = false
        return model
    }
}

extension SyntheticData {
    /// Tiny synthetic filter generations use the real store's receipt format, never bundled art/data.
    public static func seedSettings(root: URL, model: BrowserModel) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("State"), withIntermediateDirectories: true)
        try KeyBindingStore(bindings: ["new-tab": .init(shortcuts: [.ctrl("t")]), "zoom-in": .init(shortcuts: [])]).save(to: root.appendingPathComponent("State/keybindings.json"))
        let lists = ["EasyList", "EasyPrivacy"]
        for profile in model.profiles {
            let directory = ProfileDirectories(root: root).adBlockDirectory(dataDirectoryName: profile.dataDirectoryName)
            let generation = directory.appendingPathComponent("lists/generations/1")
            try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
            var receipts: [String: Any] = [:], files: [[String: Any]] = []
            for id in lists {
                let data = Data("[Adblock Plus 2.0]\n! Example synthetic \(id)\n||example.net/advert^\n".utf8)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try data.write(to: generation.appendingPathComponent("\(id).txt"))
                receipts[id] = ["sha256": hash, "bytes": data.count, "sources": [], "lastCheck": 0]
                files.append(["file": "\(id).txt", "bytes": data.count, "sha256": hash, "listID": id, "sourceRevision": [hash], "generation": 1])
            }
            let state: [String: Any] = ["catalogVersion": 1, "enabledBlockLists": lists, "lists": receipts]
            let manifest = try JSONSerialization.data(withJSONObject: ["generation": 1, "files": files, "state": state], options: .sortedKeys)
            try manifest.write(to: generation.appendingPathComponent("manifest.json"))
            let hash = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
            try JSONSerialization.data(withJSONObject: ["live": ["generation": 1, "manifestSHA256": hash]], options: .sortedKeys).write(to: directory.appendingPathComponent("lists/current.json"))
            try JSONSerialization.data(withJSONObject: state, options: .sortedKeys).write(to: directory.appendingPathComponent("catalog-state.json"))
            try JSONEncoder().encode(profile.id == model.profiles.first?.id ? ["example.com"] : []).write(to: directory.appendingPathComponent("exclusions.json"))
        }
    }
}

extension SyntheticData {
    public static let fixtureDate = Date(timeIntervalSince1970: 1_790_000_000)
    public static func downloads(root: URL, profiles: [Profile]) throws -> [DownloadItemSnapshot] {
        let completed = root.appendingPathComponent("Example Guide.pdf")
        try Data("%PDF-1.4\n% Example synthetic download\n".utf8).write(to: completed)
        var items: [DownloadItemSnapshot] = [
            .init(id: "download-active", fileName: "Example Video.zip", sourceHost: "example.com", receivedBytes: 4_000_000, totalBytes: 10_000_000, state: .inProgress, filePath: nil, startedAt: fixtureDate, profileID: profiles[0].id),
            .init(id: "download-paused", fileName: "Example Images.zip", sourceHost: "example.org", receivedBytes: 1_000_000, totalBytes: 5_000_000, state: .paused, filePath: nil, startedAt: fixtureDate, profileID: profiles[1].id),
            .init(id: "download-done", fileName: "Example Guide.pdf", sourceHost: "example.net", receivedBytes: 20_000, totalBytes: 20_000, state: .completed, filePath: completed.path, startedAt: fixtureDate, profileID: profiles[0].id),
            .init(id: "download-failed", fileName: "Example Document.pdf", sourceHost: "example.com", receivedBytes: 0, totalBytes: nil, state: .failed, filePath: nil, startedAt: fixtureDate, profileID: profiles[1].id)
        ]
        items[0].bytesPerSecond=33_333;items[3].errorDescription="Network error"
        return items
    }
    public static func seedLibrary(root: URL, model: BrowserModel, archives: [ProfileID: ArchiveStore], histories: [ProfileID: HistoryStore]) async throws {
        for i in 0..<6 {
            let profile = model.profiles[i % 2], space = i % 2 == 0 ? model.spaces[(i / 2) % 2] : model.spaces[2]
            let tab = Tab(id: ItemID(uuidString: "50000000-0000-0000-0000-00000000000\(i+1)"), url: URL(string: "https://example.com/archive/\(i)")!, title: "Example Archived \(i+1)", createdAt: fixtureDate)
            let reason: ArchiveReason = [.closed, .closed, .autoArchived, .autoArchived, .clearedToday, .folderDeleted][i]
            archives[profile.id]?.archive([ArchiveEntry(tab: tab, reason: reason, originalLocation: "today:\(space.id)", spaceID: space.id, profileID: profile.id, archivedAt: fixtureDate.addingTimeInterval(-Double(i) * 3600))])
        }
        for store in archives.values { store.flushQueue() }
        for i in 0..<5 { await histories[model.profiles[i % 2].id]?.recordVisit(url: URL(string: "https://example.org/history/\(i)")!, title: "Example History \(i+1)", time: fixtureDate.addingTimeInterval(-Double(i) * 60)) }
        let directory = root.appendingPathComponent("Captures"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var items: [CaptureItemSnapshot] = []
        for i in 0..<3 {
            let fileName = "Example Capture \(i+1).png"
            guard let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            context.setFillColor(Core.popoverBackground.light.cgColor); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(Core.focusRing.light.cgColor); context.fill(CGRect(x: 14, y: 125, width: 292, height: 38))
            context.setFillColor(Core.baseQuaternary.light.cgColor)
            for row in 0..<4 { context.fill(CGRect(x: 18, y: 25 + row * 22, width: 240 - row * 25 + i * 10, height: 8)) }
            let data = NSMutableData(); guard let image = context.makeImage(), let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(output, image, nil); guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
            try (data as Data).write(to: directory.appendingPathComponent(fileName))
            items.append(CaptureItemSnapshot(id: UUID(uuidString: "60000000-0000-0000-0000-00000000000\(i+1)")!, fileName: fileName, createdAt: fixtureDate.addingTimeInterval(-Double(i) * 7200), kind: [.area, .fullPage, .portrait][i], sourceHost: ["example.com", "example.org", "example.net"][i]))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(items).write(to: root.appendingPathComponent("State/captures.json"))
    }
    public static func writeImportFixture(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var items: [Any] = [], spaces: [Any] = []
        for i in 0..<2 {
            let container = "example-container-\(i)", children = i == 0 ? ["example-tab-0", "example-tab-1", "example-easel"] : ["example-tab-2"]
            items += [container, ["id": container, "data": ["itemContainer": [:]], "childrenIds": children]]
            spaces += ["example-space-\(i)", ["id": "example-space-\(i)", "title": "Example Space \(i+1)", "containerIDs": ["pinned", container], "profile": i == 0 ? ["default":true]:[:]]]
        }
        for i in 0..<3 { items += ["example-tab-\(i)", ["id": "example-tab-\(i)", "data": ["tab": ["savedURL": "https://example.com/\(i)", "savedTitle": "Example Tab \(i+1)"]]]] }
        items += ["example-easel", ["id": "example-easel", "data": ["easel": [:]]]]
        let profileDirectory = directory.appendingPathComponent("User Data/Default")
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(profileDirectory.appendingPathComponent("Login Data").path, &database) == SQLITE_OK else { sqlite3_close(database); throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS logins(blacklisted_by_user INTEGER); DELETE FROM logins; INSERT INTO logins VALUES(0),(0);", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": ["example", ["items": items, "spaces": spaces]]]], options: .sortedKeys).write(to: directory.appendingPathComponent("StorableSidebar.json"))
    }
    /// A real on-disk probe fixture; no profile or reader is mocked.
    public static func writeProbeFixture(to directory:URL) throws {
        try writeImportFixture(to:directory)
        let profile=directory.appendingPathComponent("User Data/Default")
        func sql(_ file:String,_ source:String) throws {
            var database:OpaquePointer?
            guard sqlite3_open(profile.appendingPathComponent(file).path,&database) == SQLITE_OK else {sqlite3_close(database);throw CocoaError(.fileWriteUnknown)}
            defer {sqlite3_close(database)}
            guard sqlite3_exec(database,source,nil,nil,nil) == SQLITE_OK else {throw CocoaError(.fileWriteUnknown)}
        }
        try sql("History", """
        CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','70');
        CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT,hidden INTEGER);
        CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER,transition INTEGER,incremented_omnibox_typed_score INTEGER);
        CREATE TABLE keyword_search_terms(keyword_id INTEGER,url_id INTEGER,term TEXT,normalized_term TEXT);
        INSERT INTO urls VALUES(1,'https://example.com/a','Example History A',0),(2,'https://example.org/b','Example History B',0),(3,'chrome://settings','Example Internal',0);
        INSERT INTO visits VALUES(1,1,13437000000000000,0,0),(2,1,13437000005000000,1,1),(3,2,13437000010000000,8,0),(4,3,13437000020000000,0,0),(5,1,13437000030000000,3,0),(6,1,0,0,0);
        """)
        try sql("Cookies","CREATE TABLE cookies(host_key TEXT); INSERT INTO cookies VALUES('example.com'),('example.org');")
        let items:[Any]=["example-archive-a",["sidebarItem":["id":"example-archive-a","data":["tab":["savedURL":"https://example.com/archive"]]],"reason":"manual","archivedAt":800000000,"source":["space":["_0":"example-space-0"]]],"example-archive-b",["sidebarItem":["id":"example-archive-b","data":["tab":["savedURL":"https://example.org/archive"]]],"reason":"auto","archivedAt":800000001,"source":["space":["_0":"example-space-1"]]],"example-archive-skipped",["sidebarItem":["id":"example-archive-skipped","data":["easel":[:]]],"reason":"manual"]]
        try JSONSerialization.data(withJSONObject:["items":items]).write(to:directory.appendingPathComponent("StorableArchiveItems.json"))
    }

}
