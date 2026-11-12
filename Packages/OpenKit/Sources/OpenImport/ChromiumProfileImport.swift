import Foundation
import SQLite3
import OpenModel

/// The default search engine of a Chromium profile, in Chromium's template format.
public struct ChromiumSearchEngine: Sendable, Hashable {
    public var name: String
    public var keyword: String
    public var urlTemplate: String
    public var suggestTemplate: String?
}

public struct ChromiumProfileCounts: Sendable {
    public var bookmarks: Int?
    public var historyVisits: Int?
    public var searchEngine: String?
    public var skippedBookmarks = 0
    public var openTabs: Int?
    /// Row counts only (no decryption, no Keychain): saved passwords, cookies, cards, addresses.
    public var secrets: ArcSecretsReadReport?
    /// Categories whose file exists but was refused or could not be parsed.
    public var unreadable: Set<String> = []
}

/// Reads one Chromium-family profile directory. Files are copied before SQLite opens them
/// (`ArcSQLiteCopy`), so a running browser is fine. Errors never contain source values.
public struct ChromiumProfileReader: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public enum ReadError: Error { case missing, unreadable, tooLarge }

    /// Hard limits on source input. Chrome's bookmark files are a few MiB for 10,000 bookmarks
    /// (about 400 bytes per node), so 64 MiB and 200,000 nodes leave wide room. The worst single
    /// allocation is the 64 MiB file buffer; the decoded tree is many small objects.
    public static let maxJSONBytes = 64 << 20
    public static let maxBookmarkNodes = 200_000
    public static let maxDepth = 64

    /// Reads a JSON object file of at most `maxJSONBytes`.
    static func readJSON(_ file: URL) throws -> [String: Any] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else { throw ReadError.missing }
        guard size <= maxJSONBytes else { throw ReadError.tooLarge }
        guard let data = try? Data(contentsOf: file), data.count <= maxJSONBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadError.unreadable }
        return json
    }

    /// The three roots in Chromium order. Empty roots are dropped.
    /// GUESS — capture pending (F3 §3 item 3): Arc's subfolder titles for the roots.
    public func bookmarks() throws -> (roots: [ImportedBookmark], skipped: Int) {
        let file = directory.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: file.path) else { throw ReadError.missing }
        guard let roots = try Self.readJSON(file)["roots"] as? [String: Any] else { throw ReadError.unreadable }
        var skipped = 0, nodes = 0
        func node(_ value: Any, depth: Int) -> ImportedBookmark? {
            nodes += 1
            guard depth < Self.maxDepth, nodes <= Self.maxBookmarkNodes, let object = value as? [String: Any] else { skipped += 1; return nil }
            let guid = (object["guid"] as? String) ?? (object["id"] as? String) ?? ""
            let title = (object["name"] as? String) ?? ""
            switch object["type"] as? String {
            case "folder":
                let children = ((object["children"] as? [Any]) ?? []).compactMap { node($0, depth: depth + 1) }
                return .folder(sourceID: guid, title: title, children: children)
            case "url":
                guard let raw = object["url"] as? String, let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
                    skipped += 1; return nil
                }
                return .url(sourceID: guid, title: title, url: url, dateAdded: Self.chromiumDate(object["date_added"]))
            default: skipped += 1; return nil
            }
        }
        let titles = ["bookmark_bar": "Bookmarks bar", "other": "Other bookmarks", "synced": "Mobile bookmarks"]
        var result: [ImportedBookmark] = []
        for key in ["bookmark_bar", "other", "synced"] {
            guard let root = roots[key], case .folder(let guid, _, let children)? = node(root, depth: 0), !children.isEmpty else { continue }
            result.append(.folder(sourceID: guid.isEmpty ? key : guid, title: titles[key]!, children: children))
        }
        guard nodes <= Self.maxBookmarkNodes else { throw ReadError.tooLarge }
        return (result, skipped)
    }

    /// Microseconds since 1601-01-01, as a decimal string.
    static func chromiumDate(_ value: Any?) -> Date? {
        guard let text = value as? String, let micros = Int64(text), micros > 11_644_473_600_000_000 else { return nil }
        return validatedImportDate(unixSeconds: Double(micros - 11_644_473_600_000_000) / 1_000_000)
    }

    public func historyVisitCount() throws -> Int {
        let file = directory.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: file.path) else { throw ReadError.missing }
        do {
            let copy = try ArcSQLiteCopy(fileURL: file)
            return Int(try copy.integer("SELECT COUNT(*) FROM visits"))
        } catch { throw ReadError.unreadable }
    }

    /// The most visited hosts in `History` (rows in `visits`), without "www.". For the onboarding Favorites
    /// step (I-5). Arc ranks by visits and site engagement above a threshold that strings do not show (F3 §1);
    /// GUESS — capture pending: Open takes the top `limit` hosts with at least 3 visits.
    public func topHosts(limit: Int) throws -> [String] {
        let file = directory.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: file.path) else { throw ReadError.missing }
        var totals: [String: Int] = [:]
        do {
            let copy = try ArcSQLiteCopy(fileURL: file)
            // Count rows in `visits`; `urls.visit_count` can lag behind.
            try copy.rows("SELECT u.url, COUNT(v.id) AS n FROM urls u JOIN visits v ON v.url = u.id GROUP BY u.id ORDER BY n DESC LIMIT 2000") { row in
                guard let url = URL(string: copy.text(row, 0)), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      var host = url.host?.lowercased() else { return }
                if host.hasPrefix("www.") { host.removeFirst(4) }
                totals[host, default: 0] += Int(sqlite3_column_int64(row, 1))
            }
        } catch { throw ReadError.unreadable }
        return totals.filter { $0.value >= 3 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(max(0, limit)).map(\.key)
    }

    /// `Preferences` → `default_search_provider_data.template_url_data`; else the
    /// `default_search_provider.guid` row in `Web Data` `keywords`. Nil: the browser default.
    public func defaultSearchEngine() -> ChromiumSearchEngine? {
        if let prefs = try? Self.readJSON(directory.appendingPathComponent("Preferences")) {
            if let template = (prefs["default_search_provider_data"] as? [String: Any])?["template_url_data"] as? [String: Any],
               let url = template["url"] as? String, !url.isEmpty {
                return ChromiumSearchEngine(name: (template["short_name"] as? String) ?? "", keyword: (template["keyword"] as? String) ?? "",
                                            urlTemplate: url, suggestTemplate: (template["suggestions_url"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            if let guid = (prefs["default_search_provider"] as? [String: Any])?["guid"] as? String, !guid.isEmpty {
                let file = directory.appendingPathComponent("Web Data")
                if let copy = try? ArcSQLiteCopy(fileURL: file) {
                    var found: ChromiumSearchEngine?
                    let escaped = guid.replacingOccurrences(of: "'", with: "''")
                    try? copy.rows("SELECT short_name, keyword, url, suggest_url FROM keywords WHERE sync_guid = '\(escaped)' LIMIT 1") { row in
                        let suggest = copy.text(row, 3)
                        found = ChromiumSearchEngine(name: copy.text(row, 0), keyword: copy.text(row, 1), urlTemplate: copy.text(row, 2),
                                                     suggestTemplate: suggest.isEmpty ? nil : suggest)
                    }
                    if let found, !found.urlTemplate.isEmpty { return found }
                }
            }
        }
        return nil
    }

    /// Counts for the wizard. Each part fails on its own.
    public func counts() -> ChromiumProfileCounts {
        var counts = ChromiumProfileCounts()
        do { let tree = try bookmarks(); counts.bookmarks = tree.roots.reduce(0) { $0 + $1.urlCount }; counts.skippedBookmarks = tree.skipped }
        catch ReadError.missing {} catch { counts.unreadable.insert("Bookmarks") }
        do { counts.historyVisits = try historyVisitCount() } catch ReadError.missing {} catch { counts.unreadable.insert("History") }
        counts.searchEngine = defaultSearchEngine().map { ChromiumSearchMapping.map($0).name }
        do { counts.openTabs = try ChromiumSessionReader(profileDirectory: directory).openTabs().count }
        catch ChromiumSessionReader.ReadError.missing {} catch { counts.unreadable.insert("Open tabs") }
        do { counts.secrets = try ArcSecretsReader(profileDirectory: directory).countOnly() }
        catch ArcSecretsImportError.missingFiles {} catch { counts.unreadable.insert("Passwords and cookies") }
        return counts
    }
}

/// Maps a Chromium search template to Open's built-in engine IDs, or a custom engine.
public enum ChromiumSearchMapping {
    static let builtIns: [(host: String, id: String, name: String)] = [
        ("google.", "google", "Google"), ("duckduckgo.com", "duckduckgo", "DuckDuckGo"), ("bing.com", "bing", "Bing"),
        ("search.brave.com", "brave", "Brave Search"), ("ecosia.org", "ecosia", "Ecosia"), ("kagi.com", "kagi", "Kagi"),
        ("perplexity.ai", "perplexity", "Perplexity"), ("search.yahoo.com", "yahoo", "Yahoo"),
    ]

    public static func map(_ engine: ChromiumSearchEngine) -> (id: String, name: String, custom: SearchEngine?) {
        if engine.urlTemplate.hasPrefix("{google:baseURL}") { return ("google", "Google", nil) }
        let search = fill(engine.urlTemplate)
        let host = URL(string: search)?.host?.lowercased() ?? ""
        for builtIn in builtIns where host.hasPrefix(builtIn.host) || host.contains("." + builtIn.host) || host == builtIn.host {
            return (builtIn.id, builtIn.name, nil)
        }
        let keyword = engine.keyword.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let id = "imported-" + (keyword.isEmpty ? host : keyword)
        let name = engine.name.isEmpty ? host : engine.name
        let custom = SearchEngine(id: id, name: name, keywords: keyword.isEmpty ? [] : [keyword], searchURLTemplate: search,
                                  suggestURLTemplate: engine.suggestTemplate.map(fill))
        return (id, name, custom)
    }

    /// `{searchTerms}` → `%s`; `{inputEncoding}`/`{outputEncoding}` → UTF-8; other parameters are dropped.
    static func fill(_ template: String) -> String {
        var text = template.replacingOccurrences(of: "{searchTerms}", with: "%s")
            .replacingOccurrences(of: "{inputEncoding}", with: "UTF-8").replacingOccurrences(of: "{outputEncoding}", with: "UTF-8")
        while let open = text.range(of: "{"), let close = text.range(of: "}", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text
    }
}

/// Wraps the shared "Imported from <Browser>" folder (`ImportedBookmarksFolder`, BrowserBookmarks.swift)
/// in a source model that `BrowserModel.mergeImportedSidebar` merges into one live Space.
@MainActor
public enum BrowserBookmarksImport {
    public static func folderTitle(browserName: String) -> String { ImportedBookmarksFolder.title(browserName: browserName) }

    /// Profile and Space IDs are the live destination IDs, so the merge lands in place.
    /// Open tabs (I-6): pinned source tabs become pinned tabs after the folder; the rest become Today tabs.
    /// GUESS — capture pending (F3 §3 item 3): Arc's placement of imported open tabs. One tab per URL; the ID
    /// comes from the URL, so a re-import adds nothing.
    public static func openTabID(sourceKey: String, url: URL) -> ItemID {
        ImportedBookmarksFolder.itemID(sourceKey: sourceKey, sourceID: "open-tab:" + url.absoluteString)
    }
    public static func sourceModel(roots: [ImportedBookmark], browserName: String, sourceKey: String,
                                   profileID: ProfileID, settings: ProfileSettings, spaceID: SpaceID,
                                   openTabs: [ChromiumOpenTab] = []) -> BrowserModel {
        let root = ImportedBookmarksFolder.make(browserName: browserName, sourceKey: sourceKey, roots: roots)
        let profile = Profile(id: profileID, settings: settings)
        var seen = Set<URL>(), pinned: [SidebarNode] = root.children.isEmpty ? [] : [.folder(root)], today: [SidebarNode] = []
        for tab in openTabs where seen.insert(tab.url).inserted {
            let node = Tab(id: openTabID(sourceKey: sourceKey, url: tab.url), url: tab.url, title: tab.title, pinnedURL: tab.pinned ? tab.url : nil)
            if tab.pinned { pinned.append(.tab(node)) } else { today.append(.tab(node)) }
        }
        let space = Space(id: spaceID, profileID: profileID, pinned: pinned, today: today)
        return BrowserModel(profiles: [profile], spaces: [space])
    }
}
