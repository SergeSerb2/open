import Foundation

/// Every Easel by title (LEAD 15:25, EZ GAPS G6; Arc searches Easels with `EaselCandidateProvider`,
/// docs/re/easels-notes.md §3.1). Easels that are sidebar tabs already come as Switch to Tab rows;
/// this provider adds the others (only in the Library, or in another Space's archive) as a normal
/// navigate row to the Easel's own address, which opens it and gives it a sidebar row.
@MainActor
public final class EaselCatalog {
    public struct Entry: Sendable, Hashable {
        public var url: URL
        public var title: String
        public var modifiedAt: Date
        public init(url: URL, title: String, modifiedAt: Date) { self.url = url; self.title = title; self.modifiedAt = modifiedAt }
    }
    /// At most this many Easels are searched (newest first).
    public static let maxEntries = 2_000
    public private(set) var entries: [Entry] = []
    private var folded: [[UInt8]] = []
    public init() {}
    public func replace(_ next: [Entry]) {
        entries = Array(next.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(Self.maxEntries))
        folded = entries.map { TextMatching.fold($0.title.prefix(512)) }
    }
    fileprivate func matches(_ query: FoldedQuery) -> [(Entry, Double)] {
        var out: [(Entry, Double)] = []
        for (i, title) in folded.enumerated() {
            let q = TextMatching.quality(query.bytes, in: title)
            if q > 0 { out.append((entries[i], q)) }
        }
        return out
    }
}

public struct EaselsProvider: SuggestProvider {
    public let id = "easels"
    public var maxRows = 3
    let catalog: EaselCatalog
    public init(catalog: EaselCatalog) { self.catalog = catalog }

    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        // ⌘T only: the Tabs and Actions scopes have their own rows, and ⌘L edits the current tab.
        guard input.context.mode == .newTab, input.siteSearch == nil, input.query.bytes.count >= 2 else { return [] }
        let inSidebar = Set(input.tabs.tabs.map(\.url))
        let hits = catalog.matches(input.query).filter { !inSidebar.contains($0.0.url) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.modifiedAt > $1.0.modifiedAt }.prefix(maxRows)
        return hits.map { entry, quality in
            Suggestion(id: "easel:" + entry.url.absoluteString, kind: .navigate, title: entry.title, subtitle: "Easel",
                       url: entry.url, icon: .favicon(entry.url), provider: id,
                       scoreDetail: ScoreDetail(quality: quality, weight: Ranking.weight(.navigate)))
        }
    }
}
