import Foundation

/// One Site Search target: a site whose own search the command bar can scope to (Arc §4.6 rule 15).
public struct SiteSearch: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Host (or host/path) that scopes tab and history rows while Site Search is active
    /// ("youtube.com", "google.com/maps").
    public var host: String
    /// Extra trigger words ("yt"). The folded name and the host always trigger too.
    public var keywords: [String]
    /// `%s` is replaced by the percent-encoded query.
    public var searchURLTemplate: String
    /// Set when the site is a search engine; Site Search then uses that engine's suggestions.
    public var engineID: String?

    public init(id: String, name: String, host: String, keywords: [String] = [], searchURLTemplate: String, engineID: String? = nil) {
        self.id = id; self.name = name; self.host = host; self.keywords = keywords
        self.searchURLTemplate = searchURLTemplate; self.engineID = engineID
    }

    public func searchURL(for query: String) -> URL? { SearchEngine.fill(searchURLTemplate, query) }

    /// True when a page belongs to this site: same host or a subdomain of it; for a host/path scope
    /// ("google.com/maps"), the URL (no scheme, no www) starts with it.
    func contains(host pageHost: String, matchableURL: String) -> Bool {
        if let slash = host.firstIndex(of: "/") {
            return host[..<slash] == pageHost && matchableURL.lowercased().hasPrefix(host)
        }
        return pageHost == host || pageHost.hasSuffix("." + host)
    }
}

/// Seed table. Templates are the sites' public search URLs, written for Open (not copied from Arc's
/// seeded list). Every search engine is added as a site too.
public enum SiteSearches {
    public static let popular: [SiteSearch] = [
        SiteSearch(id: "youtube", name: "YouTube", host: "youtube.com", keywords: ["yt"], searchURLTemplate: "https://www.youtube.com/results?search_query=%s"),
        SiteSearch(id: "github", name: "GitHub", host: "github.com", keywords: ["gh"], searchURLTemplate: "https://github.com/search?q=%s&type=repositories"),
        SiteSearch(id: "wikipedia", name: "Wikipedia", host: "wikipedia.org", keywords: ["wiki"], searchURLTemplate: "https://en.wikipedia.org/w/index.php?search=%s"),
        SiteSearch(id: "amazon", name: "Amazon", host: "amazon.com", keywords: ["amz"], searchURLTemplate: "https://www.amazon.com/s?k=%s"),
        SiteSearch(id: "reddit", name: "Reddit", host: "reddit.com", searchURLTemplate: "https://www.reddit.com/search/?q=%s"),
        SiteSearch(id: "x", name: "X", host: "x.com", keywords: ["twitter"], searchURLTemplate: "https://x.com/search?q=%s"),
        SiteSearch(id: "google-maps", name: "Google Maps", host: "google.com/maps", keywords: ["maps", "gmaps"], searchURLTemplate: "https://www.google.com/maps/search/%s"),
        SiteSearch(id: "google-images", name: "Google Images", host: "google.com", keywords: ["images"], searchURLTemplate: "https://www.google.com/search?tbm=isch&q=%s"),
        SiteSearch(id: "google-news", name: "Google News", host: "news.google.com", searchURLTemplate: "https://news.google.com/search?q=%s"),
        SiteSearch(id: "google-drive", name: "Google Drive", host: "drive.google.com", keywords: ["drive", "gdrive"], searchURLTemplate: "https://drive.google.com/drive/search?q=%s"),
        SiteSearch(id: "gmail", name: "Gmail", host: "mail.google.com", searchURLTemplate: "https://mail.google.com/mail/u/0/#search/%s"),
        SiteSearch(id: "google-translate", name: "Google Translate", host: "translate.google.com", keywords: ["translate"], searchURLTemplate: "https://translate.google.com/?sl=auto&text=%s"),
        SiteSearch(id: "stackoverflow", name: "Stack Overflow", host: "stackoverflow.com", searchURLTemplate: "https://stackoverflow.com/search?q=%s"),
        SiteSearch(id: "mdn", name: "MDN", host: "developer.mozilla.org", searchURLTemplate: "https://developer.mozilla.org/en-US/search?q=%s"),
        SiteSearch(id: "apple-developer", name: "Apple Developer", host: "developer.apple.com", searchURLTemplate: "https://developer.apple.com/search/?q=%s"),
        SiteSearch(id: "npm", name: "npm", host: "npmjs.com", searchURLTemplate: "https://www.npmjs.com/search?q=%s"),
        SiteSearch(id: "hacker-news", name: "Hacker News", host: "news.ycombinator.com", keywords: ["hn"], searchURLTemplate: "https://hn.algolia.com/?q=%s"),
        SiteSearch(id: "imdb", name: "IMDb", host: "imdb.com", searchURLTemplate: "https://www.imdb.com/find/?q=%s"),
        SiteSearch(id: "spotify", name: "Spotify", host: "open.spotify.com", searchURLTemplate: "https://open.spotify.com/search/%s"),
        SiteSearch(id: "linkedin", name: "LinkedIn", host: "linkedin.com", searchURLTemplate: "https://www.linkedin.com/search/results/all/?keywords=%s"),
        SiteSearch(id: "pinterest", name: "Pinterest", host: "pinterest.com", searchURLTemplate: "https://www.pinterest.com/search/pins/?q=%s"),
        SiteSearch(id: "twitch", name: "Twitch", host: "twitch.tv", searchURLTemplate: "https://www.twitch.tv/search?term=%s"),
        SiteSearch(id: "ebay", name: "eBay", host: "ebay.com", searchURLTemplate: "https://www.ebay.com/sch/i.html?_nkw=%s"),
    ]

    /// Popular sites plus one entry per engine (`engine-<id>`).
    public static func defaults(engines: [SearchEngine] = SearchEngines.all) -> [SiteSearch] {
        popular + engines.map { engine in
            SiteSearch(id: "engine-\(engine.id)", name: engine.name,
                       host: URL(string: engine.searchURLTemplate.replacingOccurrences(of: "%s", with: "")).map(TextMatching.displayHost) ?? "",
                       keywords: engine.keywords, searchURLTemplate: engine.searchURLTemplate, engineID: engine.id)
        }
    }
}

extension SiteSearch {
    /// The Actions and Tabs scopes as trigger entries with no URL template (commandbar-completion §4.3.2).
    /// Exact keywords only: "actions", "action", "commands" and "tabs", "tab". The bar maps their ids to
    /// its scopes; the engine never searches them.
    public static let actionsScopeID = "scope-actions"
    public static let tabsScopeID = "scope-tabs"
    public static let scopes = [
        SiteSearch(id: actionsScopeID, name: "Actions", host: "", keywords: ["actions", "action", "commands"], searchURLTemplate: ""),
        SiteSearch(id: tabsScopeID, name: "Tabs", host: "", keywords: ["tabs", "tab"], searchURLTemplate: ""),
    ]

    /// True for the Actions and Tabs scope entries.
    public var isScope: Bool { id == Self.actionsScopeID || id == Self.tabsScopeID }
}

/// Folded trigger words for fast per-keystroke matching.
struct SiteSearchIndex: Sendable {
    struct Entry: Sendable {
        let site: SiteSearch
        /// Name without spaces ("stackoverflow"), host ("stackoverflow.com"), and keywords. Folded.
        let names: [[UInt8]]
        let keywords: [[UInt8]]
    }

    let entries: [Entry]
    /// The Actions and Tabs scopes (`SiteSearch.scopes`): exact keywords only, never a Space trigger.
    let scopes: [Entry]
    let byID: [String: SiteSearch]

    init(_ sites: [SiteSearch]) {
        scopes = SiteSearch.scopes.map { Entry(site: $0, names: [], keywords: $0.keywords.map { TextMatching.fold($0) }) }
        entries = sites.filter { !$0.isScope }.map { site in
            let name = TextMatching.fold(site.name.filter { !$0.isWhitespace })
            let host = TextMatching.fold(site.host)
            return Entry(site: site, names: [name, host], keywords: site.keywords.map { TextMatching.fold($0) })
        }
        var map: [String: SiteSearch] = [:]
        for site in sites + SiteSearch.scopes where map[site.id] == nil { map[site.id] = site }
        byID = map
    }

    /// Site for a one-word query, for the "Press Tab to search <Site>" hint and the Tab key.
    /// A scope keyword wins, exact only ("actions", never "act"); then an exact site name/host/keyword;
    /// then the shortest site name the query is a prefix of (2+ bytes).
    func tabTrigger(for query: [UInt8]) -> SiteSearch? {
        guard query.count >= 2, !query.contains(32) else { return nil }
        for e in scopes where e.keywords.contains(query) { return e.site }
        for e in entries where e.names.contains(query) || e.keywords.contains(query) { return e.site }
        var best: (site: SiteSearch, length: Int)?
        for e in entries {
            for name in e.names where name.count > query.count && name.starts(with: query) {
                if best == nil || name.count < best!.length { best = (e.site, name.count) }
            }
        }
        return best?.site
    }

    /// "yt cats" → (YouTube, "cats"). The first word must equal a name, host, or keyword.
    func spaceTrigger(for text: String) -> (site: SiteSearch, rest: String)? {
        guard let space = text.firstIndex(of: " ") else { return nil }
        let head = TextMatching.fold(text[..<space])
        let rest = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard head.count >= 2, !rest.isEmpty else { return nil }
        for e in entries where e.names.contains(head) || e.keywords.contains(head) { return (e.site, rest) }
        return nil
    }
}
