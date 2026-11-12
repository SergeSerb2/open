import Foundation
import SQLite3

/// I-5: sites the user visits most in another browser, for the onboarding Favorites step.
/// Arc ranks imported history and site engagement and pre-selects Favorites above a threshold
/// (`suggestedTopApps`, `autoSelectFavoritesEngagementThreshold`, browser-import.md §1). The threshold
/// value is not in strings: Open's value is a GUESS — capture pending.
public struct ImportedTopSite: Sendable, Equatable {
    /// The site's root, for example `https://mail.example.com/`.
    public var url: URL
    public var host: String
    public var title: String
    /// Summed visit counts of the site's pages (Firefox pages are first ranked by frecency).
    public var score: Int64
}

/// The onboarding Favorites hook (IMC I-5, `IMC-questions.md` IMC 05:15): ranked hosts, lower-case, no `www.`.
public enum BrowserSiteSuggestions {
    /// GUESS — capture pending: the same rule as IMC's Chromium reader (hosts with at least 3 visits).
    public static let minimumVisits: Int64 = 3

    /// Most visited hosts in the source profile, best first; at most `limit`. Empty when unreadable.
    public static func topHosts(source: BrowserSource, profile: BrowserSourceProfile, safari: SafariImportFiles = .init(), limit: Int) -> [String] {
        switch source.family {
        case .arc: return []
        case .chromium: return (try? ChromiumProfileReader(directory: profile.directory).topHosts(limit: limit)) ?? []
        case .firefox, .safari:
            return BrowserTopSites.read(family: source.family, profile: profile, safari: safari, limit: 200)
                .filter { $0.score >= minimumVisits }.prefix(max(0, limit)).map(\.host)
        }
    }
}

enum BrowserTopSites {

    /// Groups pages by host (a leading `www.` is dropped) and sums the score. Web pages only.
    static func group(_ rows: [(url: String, title: String, score: Int64)], limit: Int) -> [ImportedTopSite] {
        var sites: [String: ImportedTopSite] = [:]
        var order: [String] = []
        for row in rows {
            guard let url = URL(string: row.url), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  var host = url.host()?.lowercased(), !host.isEmpty, row.score > 0 else { continue }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if var site = sites[host] {
                site.score += row.score
                if site.title.isEmpty { site.title = row.title }
                sites[host] = site
            } else {
                guard let root = URL(string: "\(scheme)://\(url.host() ?? host)/") else { continue }
                sites[host] = ImportedTopSite(url: root, host: host, title: row.title, score: row.score)
                order.append(host)
            }
        }
        let ranked = order.compactMap { sites[$0] }.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }
        return ranked.prefix(max(0, limit)).map(\.element)
    }

    /// Reads at most 2,000 of the most visited pages, then groups them by host.
    static func read(family: BrowserFamily, profile: BrowserSourceProfile, safari: SafariImportFiles = .init(), limit: Int = 12) -> [ImportedTopSite] {
        let pages = 2000
        switch family {
        case .arc:
            return [] // Arc brings its own Favorites.
        case .chromium:
            guard let copy = try? ArcSQLiteCopy(fileURL: profile.directory.appendingPathComponent("History")) else { return [] }
            var rows: [(String, String, Int64)] = []
            try? copy.rows("SELECT url, title, visit_count FROM urls WHERE hidden = 0 ORDER BY visit_count DESC LIMIT \(pages)") { s in
                rows.append((copy.text(s, 0), copy.text(s, 1), sqlite3_column_int64(s, 2)))
            }
            return group(rows.map { (url: $0.0, title: $0.1, score: $0.2) }, limit: limit)
        case .firefox:
            let sites = (try? FirefoxPlacesReader(profileDirectory: profile.directory).topSites(limit: 200)) ?? []
            return group(sites.map { (url: $0.url.absoluteString, title: $0.title, score: $0.visits) }, limit: limit)
        case .safari:
            if let archive = safari.exportArchive {
                guard let reader = try? SafariExportReader(url: archive), let member = reader.historyMember,
                      let data = try? reader.archive.extract(member),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = root["history"] as? [[String: Any]] else { return [] }
                let rows = items.compactMap { item -> (url: String, title: String, score: Int64)? in
                    guard let url = item["url"] as? String else { return nil }
                    return (url, item["title"] as? String ?? "", (item["visit_count"] as? NSNumber)?.int64Value ?? 1)
                }
                return group(rows, limit: limit)
            }
            guard SafariAccess.check(safariDirectory: profile.directory) == .granted,
                  let copy = try? ArcSQLiteCopy(fileURL: profile.directory.appendingPathComponent("History.db")) else { return [] }
            var rows: [(String, Int64)] = []
            try? copy.rows("SELECT url, visit_count FROM history_items ORDER BY visit_count DESC LIMIT \(pages)") { s in
                rows.append((copy.text(s, 0), sqlite3_column_int64(s, 1)))
            }
            return group(rows.map { (url: $0.0, title: "", score: $0.1) }, limit: limit)
        }
    }
}
