import Foundation
import OpenModel

/// Live-data hover cards ("glances") for Pinned and Favorite tabs (docs/re/live-data.md §3).
/// Pure decisions only: no AppKit, no I/O, nothing runs at launch. The App supplies data
/// (history, later the fetch host and EventKit) on first hover.
public enum GlanceKind: Hashable, Sendable {
    /// Recent pages of one site from the Profile's own history (LD §3.4). No network.
    case recents(RecentsSite)
    /// Today's events from the system calendar (LD §3.2; EventKit per LEAD 11:05 Q1).
    case calendar(CalendarProvider)
    /// Unread mail of one Gmail inbox from the Profile's own session (LD §3.3, LF L6).
    case gmail(account: Int)
    /// A Live Folder row's pull request card (C-LF-1, Open's design, live-data §8). Decided from
    /// the row's stored facts, never from the URL; no fetch.
    case pullRequest

    /// The settings key that turns this kind of card on or off (default on).
    public var preferenceKey: String {
        switch self {
        case .recents: RecentsSite.preferenceKey
        case .calendar: CalendarProvider.preferenceKey
        case .gmail: GmailGlance.preferenceKey
        case .pullRequest: "open.general.previewsEnabled"  // only the master switch
        }
    }

    /// The glance a tab gets from its URL, or nil for a plain page preview.
    /// `aliases` maps extra hosts to a site (automation fixtures only; empty in normal use).
    /// `mailHosts`: extra hosts that count as Gmail (automation fixtures only).
    public static func match(url: URL, aliases: [String: RecentsSite] = [:], mailHosts: Set<String> = []) -> GlanceKind? {
        if let provider = CalendarProvider.match(url: url) { return .calendar(provider) }
        if let account = GmailGlance.account(of: url, extraHosts: mailHosts) { return .gmail(account: account) }
        return RecentsSite.match(url: url, aliases: aliases).map { .recents($0) }
    }
}

/// The four sites of Arc's Recents card (LD §3.4: `G:FUN_100098fac`, `S:110664–110680`).
public enum RecentsSite: String, CaseIterable, Hashable, Sendable {
    case linear, notion, figma, confluence

    /// Open's switch for the whole Recents card (Arc: `recentPagesPreviewEnabled`, one switch).
    public static let preferenceKey = "open.general.previewsRecents"

    /// Card header (LD §3.4).
    public static let header = "Recents"

    /// The "+" action's label and tooltip.
    public var newLabel: String {
        switch self {
        case .linear: "New Issue"
        case .notion, .confluence: "New Page"
        case .figma: "New File"
        }
    }

    /// The "+" action's target (LD §3.4).
    public var newURL: URL {
        switch self {
        case .linear: URL(string: "https://linear.app/new")!
        case .notion: URL(string: "https://notion.so/new")!
        case .figma: URL(string: "https://figma.com/new")!
        case .confluence: URL(string: "https://confluence.new")!
        }
    }

    /// The empty card's text (LD §3.4, exact strings).
    public var emptyText: String {
        switch self {
        case .linear: "Recent Linear projects and issues appear here."
        case .notion: "Recent Notion docs appear here."
        case .figma: "Recent Figma files appear here."
        case .confluence: "Recent Confluence pages appear here."
        }
    }

    /// Registrable domains whose pages belong to the site. Confluence Cloud lives under
    /// `<team>.atlassian.net/wiki` (guess on Arc's exact rule; capture item 10).
    var domains: [String] {
        switch self {
        case .linear: ["linear.app"]
        case .notion: ["notion.so", "notion.com", "notion.site"]
        case .figma: ["figma.com"]
        case .confluence: ["atlassian.net"]
        }
    }

    /// The history token that finds candidate rows quickly (FTS phrase on the URL column).
    public var historyPhrase: String {
        switch self {
        case .linear: "linear app"
        case .notion: "notion"
        case .figma: "figma com"
        case .confluence: "atlassian net"
        }
    }

    /// Every history phrase to search: the site's own plus its fixture alias hosts.
    public func historyPhrases(aliases: [String: RecentsSite] = [:]) -> [String] {
        [historyPhrase] + aliases.filter { $0.value == self }.keys.sorted()
            .map { $0.split(separator: ":").first.map(String.init) ?? $0 }
            .map { $0.replacingOccurrences(of: ".", with: " ") }
    }

    /// Calendar hosts on the same domains get the calendar card later, never Recents.
    private static let excludedHosts: Set<String> = ["calendar.notion.so", "calendar.notion.com"]

    public static func match(url: URL, aliases: [String: RecentsSite] = [:]) -> RecentsSite? {
        guard let host = url.host?.lowercased() else { return nil }
        if let alias = aliases[host] ?? url.port.flatMap({ aliases["\(host):\($0)"] }) { return alias }
        guard url.scheme == "https" || url.scheme == "http", !excludedHosts.contains(host) else { return nil }
        return allCases.first { site in
            site.domains.contains { host == $0 || host.hasSuffix("." + $0) }
                && (site != .confluence || url.path.hasPrefix("/wiki"))
        }
    }

    /// True when `url` is a page of this site worth listing: not the site's home,
    /// login, or "new" pages (guess on Arc's filter; capture item 10).
    public func isRecentPage(_ url: URL, aliases: [String: RecentsSite] = [:]) -> Bool {
        guard Self.match(url: url, aliases: aliases) == self else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !path.isEmpty else { return false }
        let segments = path.split(separator: "/").map(String.init)
        if let first = segments.first, ["login", "logout", "signup", "oauth", "auth"].contains(first) { return false }
        if segments.count == 1, ["new", "settings", "onboarding", "files", "wiki"].contains(segments[0]) { return false }
        return true
    }
}

/// One row of the Recents card.
public struct RecentPage: Equatable, Sendable {
    public var url: URL
    public var title: String
    public var lastVisit: Date
    public init(url: URL, title: String, lastVisit: Date) { self.url = url; self.title = title; self.lastVisit = lastVisit }
}

public enum RecentPages {
    /// Most rows a card shows (guess — capture pending, item 10).
    public static let limit = 6

    /// Turns history rows (newest first) into card rows: only the site's pages, tidy titles
    /// (`TidyTitles`, the sidebar's own rule set), one row per page (query and fragment
    /// ignored), and no untitled rows.
    @MainActor
    public static func select(_ rows: [(url: URL, title: String, lastVisit: Date)], site: RecentsSite,
                              aliases: [String: RecentsSite] = [:], limit: Int = RecentPages.limit) -> [RecentPage] {
        var seen = Set<String>()
        var pages: [RecentPage] = []
        for row in rows.sorted(by: { $0.lastVisit > $1.lastVisit }) where pages.count < limit {
            guard site.isRecentPage(row.url, aliases: aliases) else { continue }
            var components = URLComponents(url: row.url, resolvingAgainstBaseURL: false)
            components?.query = nil; components?.fragment = nil
            let key = (components?.url ?? row.url).absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(key).inserted else { continue }
            let title = TidyTitles.tidy(title: row.title, url: row.url).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != row.url.absoluteString else { continue }
            pages.append(RecentPage(url: row.url, title: title, lastVisit: row.lastVisit))
        }
        return pages
    }
}
