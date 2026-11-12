import Foundation
import SQLite3
import OpenModel

/// One node of a Chromium `Bookmarks` tree (PUB: `components/bookmarks/browser/bookmark_codec.cc`).
public indirect enum ChromiumBookmark: Sendable, Hashable {
    case folder(guid: String, title: String, children: [ChromiumBookmark])
    case url(guid: String, title: String, url: URL, added: Date?)

    public var urlCount: Int {
        switch self {
        case .url: 1
        case .folder(_, _, let children): children.reduce(0) { $0 + $1.urlCount }
        }
    }
}

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
}

/// Reads one Chromium-family profile directory. Files are copied before SQLite opens them
/// (`ArcSQLiteCopy`), so a running browser is fine. Errors never contain source values.
public struct ChromiumProfileReader: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public enum ReadError: Error { case missing, unreadable }

    /// The three roots in Chromium order. Empty roots are dropped.
    /// GUESS — capture pending (F3 §3 item 3): Arc's subfolder titles for the roots.
    public func bookmarks() throws -> (roots: [ChromiumBookmark], skipped: Int) {
        let file = directory.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: file.path) else { throw ReadError.missing }
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw ReadError.unreadable }
        var skipped = 0
        func node(_ value: Any, depth: Int) -> ChromiumBookmark? {
            guard depth < 64, let object = value as? [String: Any] else { return nil }
            let guid = (object["guid"] as? String) ?? (object["id"] as? String) ?? ""
            let title = (object["name"] as? String) ?? ""
            switch object["type"] as? String {
            case "folder":
                let children = ((object["children"] as? [Any]) ?? []).compactMap { node($0, depth: depth + 1) }
                return .folder(guid: guid, title: title, children: children)
            case "url":
                guard let raw = object["url"] as? String, let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
                    skipped += 1; return nil
                }
                return .url(guid: guid, title: title, url: url, added: Self.chromiumDate(object["date_added"]))
            default: skipped += 1; return nil
            }
        }
        let titles = ["bookmark_bar": "Bookmarks bar", "other": "Other bookmarks", "synced": "Mobile bookmarks"]
        var result: [ChromiumBookmark] = []
        for key in ["bookmark_bar", "other", "synced"] {
            guard let root = roots[key], case .folder(let guid, _, let children)? = node(root, depth: 0), !children.isEmpty else { continue }
            result.append(.folder(guid: guid.isEmpty ? key : guid, title: titles[key]!, children: children))
        }
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

    /// `Preferences` → `default_search_provider_data.template_url_data`; else the
    /// `default_search_provider.guid` row in `Web Data` `keywords`. Nil: the browser default.
    public func defaultSearchEngine() -> ChromiumSearchEngine? {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("Preferences")),
           let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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
        if let tree = try? bookmarks() { counts.bookmarks = tree.roots.reduce(0) { $0 + $1.urlCount }; counts.skippedBookmarks = tree.skipped }
        counts.historyVisits = try? historyVisitCount()
        counts.searchEngine = defaultSearchEngine().map { ChromiumSearchMapping.map($0).name }
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

/// Builds a source model that `BrowserModel.mergeImportedSidebar` merges into one live Space.
/// Bookmarks become pinned tabs in a pinned folder "Imported from <Browser>".
/// Evidence: PUB secondary sources (docs/re/browser-import.md §2). GUESS — capture pending: exact title and nesting.
@MainActor
public enum BrowserBookmarksImport {
    public static func folderTitle(browserName: String) -> String { "Imported from " + browserName }

    public static func itemID(_ sourceKey: String, _ guid: String) -> ItemID {
        ItemID(rawValue: ArcImporter.deterministicUUID(for: sourceKey + "/" + guid, namespace: "browser-bookmark"))
    }

    public static func rootFolderID(sourceKey: String) -> ItemID { itemID(sourceKey, "root-folder") }

    /// Profile and Space IDs are the live destination IDs, so the merge lands in place.
    public static func sourceModel(roots: [ChromiumBookmark], browserName: String, sourceKey: String,
                                   profileID: ProfileID, settings: ProfileSettings, spaceID: SpaceID) -> BrowserModel {
        func convert(_ node: ChromiumBookmark) -> SidebarNode {
            switch node {
            case .folder(let guid, let title, let children):
                return .folder(Folder(id: itemID(sourceKey, "folder:" + guid), title: title.isEmpty ? "Folder" : title,
                                      isExpanded: false, children: children.map(convert)))
            case .url(let guid, let title, let url, let added):
                let date = added ?? Date()
                return .tab(Tab(id: itemID(sourceKey, "url:" + guid), url: url, title: title, pinnedURL: url,
                                createdAt: date, lastActiveAt: date))
            }
        }
        let root = Folder(id: rootFolderID(sourceKey: sourceKey), title: folderTitle(browserName: browserName),
                          isExpanded: true, children: roots.map(convert))
        let profile = Profile(id: profileID, settings: settings)
        let space = Space(id: spaceID, profileID: profileID, pinned: roots.isEmpty ? [] : [.folder(root)])
        return BrowserModel(profiles: [profile], spaces: [space])
    }
}
