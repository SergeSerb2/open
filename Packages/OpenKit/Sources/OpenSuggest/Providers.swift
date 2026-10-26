import Foundation
import OpenModel
import OpenStore

// MARK: - Protocol and input

/// Facts about the selected tab, read from the model on the main actor. Drives action availability.
public struct CurrentTabState: Sendable {
    public var tabID: ItemID
    public var url: URL
    /// True when the tab sits in a Space's pinned section (directly, in a folder, or in a split).
    public var isPinned: Bool
    public var isFavorite: Bool
    public var isInSplit: Bool
}

/// Everything a provider needs for one keystroke. Built once on the main actor by the engine.
public struct SuggestInput: Sendable {
    public let rawText: String
    /// `rawText` without surrounding whitespace.
    public let text: String
    public let query: FoldedQuery
    public let typed: TypedInput
    public let context: SuggestContext
    public let searchEngine: SearchEngine
    /// Active Site Search scope, if any.
    public let siteSearch: SiteSearch?
    public let currentTab: CurrentTabState?
    public let profileID: ProfileID?
    public let now: Date
    let tabs: TabIndex
    let profileOrdinal: Int?
}

/// One source of command bar rows.
///
/// `localSuggestions` runs synchronously on the main actor on every keystroke and must stay well
/// under a millisecond. `asyncOperation` returns work that runs off the main actor; the engine
/// cancels it when the next keystroke arrives. Its rows replace the provider's local rows; returning
/// nil keeps them.
@MainActor
public protocol SuggestProvider {
    var id: String { get }
    func localSuggestions(for input: SuggestInput) -> [Suggestion]
    func asyncOperation(for input: SuggestInput) -> (@Sendable () async -> [Suggestion]?)?
}

public extension SuggestProvider {
    func localSuggestions(for input: SuggestInput) -> [Suggestion] { [] }
    func asyncOperation(for input: SuggestInput) -> (@Sendable () async -> [Suggestion]?)? { nil }
}

// MARK: - 1. What you typed

public struct WhatYouTypedProvider: SuggestProvider {
    public let id = "typed"
    public init() {}

    public nonisolated static let urlRowID = "typed:url"
    public nonisolated static let searchRowID = "typed:search"

    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        guard input.context.mode != .searchTabs, input.siteSearch == nil else { return [] }
        switch input.typed {
        case .empty:
            return []
        case .url(let url, let reason):
            var rows = [Suggestion(
                id: Self.urlRowID, kind: .navigate, title: url.absoluteString, url: url,
                icon: TextMatching.faviconURL(for: url).map(IconHint.favicon) ?? .symbol("globe"),
                provider: id, scoreDetail: ScoreDetail(quality: MatchQuality.exact, weight: Ranking.weight(.navigate)),
                isWhatYouTyped: true)]
            // A bare host may still be meant as words; offer the search as a second row.
            if reason != .explicitScheme, reason != .filePath, let search = searchRow(input, primary: false) {
                rows.append(search)
            }
            return rows
        case .text:
            return searchRow(input, primary: true).map { [$0] } ?? []
        }
    }

    private func searchRow(_ input: SuggestInput, primary: Bool) -> Suggestion? {
        guard let url = input.searchEngine.searchURL(for: input.text) else { return nil }
        return Suggestion(
            id: Self.searchRowID, kind: .search, title: input.text, subtitle: "Search \(input.searchEngine.name)",
            url: url, icon: .symbol("magnifyingglass"), provider: id,
            scoreDetail: ScoreDetail(quality: MatchQuality.exact, weight: Ranking.weight(.search)),
            isWhatYouTyped: primary)
    }
}

// MARK: - 2. Open tabs, pinned tabs, favorites

public struct TabsProvider: SuggestProvider {
    public let id = "tabs"
    /// Rows returned before ranking caps apply.
    public var maxRows = 12
    /// Most recent tabs shown for an empty query (search-tabs mode shows up to `maxRows`).
    public var emptyQueryRows = 6
    public init() {}

    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        let index = input.tabs
        let excluded = input.currentTab?.tabID
        let currentSpace = index.spaceOrdinal(of: input.context.spaceID)
        var top = TopRows(capacity: input.query.isEmpty && input.context.mode != .searchTabs ? emptyQueryRows : maxRows)
        // Scores are computed for every match from flat arrays; Suggestion values only for the winners.
        func consider(_ i: Int, quality: Double) {
            let tab = index.tabs[i]
            if tab.id == excluded { return }
            var boost = Ranking.locationBoost(index.locations[i])
            if index.spaceOrdinals[i] == currentSpace { boost += Ranking.currentSpaceBoost }
            let detail = ScoreDetail(quality: quality, weight: Ranking.weight(.switchToTab),
                                     frecency: TextMatching.tabRecency(lastActiveAt: tab.lastActiveAt, now: input.now), boost: boost)
            top.insert(i, detail)
        }
        if input.query.isEmpty {
            // Empty query: most recently active tabs (score is recency + location), no Site Search scope.
            guard input.siteSearch == nil else { return [] }
            for i in 0..<index.tabs.count where input.profileOrdinal == nil || index.profileOrdinals[i] == Int32(input.profileOrdinal!) {
                consider(i, quality: 0)
            }
        } else {
            for m in Self.scan(input.query, index, profile: input.profileOrdinal) {
                if let site = input.siteSearch {
                    let e = index.entries[m.entry]
                    if !site.contains(host: e.host, matchableURL: TextMatching.matchableURL(e.url)) { continue }
                }
                consider(m.entry, quality: m.quality)
            }
        }
        return top.rows.map { (i, detail) in
            let e = index.entries[i]
            var row = Suggestion(
                id: "tab:\(e.tab.id.rawValue.uuidString)", kind: .switchToTab,
                title: e.title.isEmpty ? TextMatching.matchableURL(e.url) : e.title, subtitle: e.host,
                url: e.url, icon: Self.icon(e), tabID: e.tab.id, tabLocation: e.location,
                spaceID: e.spaceID, spaceTitle: e.spaceTitle, provider: id, scoreDetail: detail)
            row.canBeTopHit = detail.quality >= MatchQuality.prefix && input.query.bytes.count >= 2
            row.isExactTabMatch = detail.quality == MatchQuality.exact
            return row
        }
    }

    /// Keeps the best `capacity` rows by score (ties: lower entry index first). O(n) for typical input.
    struct TopRows {
        let capacity: Int
        private(set) var rows: [(Int, ScoreDetail)] = []

        init(capacity: Int) {
            self.capacity = capacity
            rows.reserveCapacity(capacity + 1)
        }

        mutating func insert(_ entry: Int, _ detail: ScoreDetail) {
            let score = detail.total
            if rows.count == capacity, let last = rows.last, last.1.total >= score { return }
            var i = rows.count
            while i > 0 && rows[i - 1].1.total < score { i -= 1 }
            rows.insert((entry, detail), at: i)
            if rows.count > capacity { rows.removeLast() }
        }
    }

    private static func icon(_ e: TabIndex.Entry) -> IconHint? {
        if let custom = e.tab.customIcon, !custom.isEmpty {
            let isEmoji = custom.count == 1 && (custom.unicodeScalars.first?.properties.isEmojiPresentation ?? false)
            return isEmoji ? .emoji(custom) : .symbol(custom)
        }
        return TextMatching.faviconURL(for: e.url).map(IconHint.favicon)
    }

    /// The per-keystroke scan. Quality is the best of title (×1), host (×1), and URL (×0.9), with
    /// the multi-word fallback. Title and host quality decide top-hit eligibility, so they are kept apart:
    /// a URL-only match is capped at 90 and never reaches the exact-match level.
    static func scan(_ q: FoldedQuery, _ index: TabIndex, profile: Int?) -> [(entry: Int, quality: Double)] {
        var out: [(entry: Int, quality: Double)] = []
        let qmask = q.mask
        let multi = q.tokens.count > 1
        // All query words in one buffer with (start, length) pairs.
        let tokenBytes = q.tokens.flatMap { $0 }
        var tokenRanges: [(Int, Int)] = []
        var cursor = 0
        for t in q.tokens { tokenRanges.append((cursor, t.count)); cursor += t.count }

        q.bytes.withUnsafeBufferPointer { whole in
        tokenBytes.withUnsafeBufferPointer { tokens in
        index.bytes.withUnsafeBufferPointer { bytes in
        index.offsets.withUnsafeBufferPointer { off in
        index.masks.withUnsafeBufferPointer { masks in
        index.profileOrdinals.withUnsafeBufferPointer { ords in
            @inline(__always) func field(_ o: Int) -> UnsafeBufferPointer<UInt8> {
                UnsafeBufferPointer(rebasing: bytes[Int(off[o])..<Int(off[o] + off[o + 1])])
            }
            let profileOrdinal = profile.map(Int32.init)
            for i in 0..<masks.count {
                if let p = profileOrdinal, ords[i] != p { continue }
                if masks[i] & qmask != qmask { continue }
                let o = i * 6
                let title = field(o), host = field(o + 2), url = field(o + 4)
                var best = TextMatching.quality(whole, in: title)
                if best < MatchQuality.exact { best = max(best, TextMatching.quality(whole, in: host)) }
                if best < MatchQuality.prefix { best = max(best, TextMatching.quality(whole, in: url) * 0.9) }
                if multi && best < MatchQuality.allWordsPrefix {
                    var allWordPrefix = true
                    var allFound = true
                    for (start, length) in tokenRanges {
                        let t = UnsafeBufferPointer(rebasing: tokens[start..<(start + length)])
                        let tq = max(TextMatching.quality(t, in: title), TextMatching.quality(t, in: host), TextMatching.quality(t, in: url))
                        if tq == 0 { allFound = false; break }
                        if tq < MatchQuality.wordPrefix { allWordPrefix = false }
                    }
                    if allFound { best = max(best, allWordPrefix ? MatchQuality.allWordsPrefix : MatchQuality.allWordsSubstring) }
                }
                if best > 0 { out.append((i, best)) }
            }
        }}}}}}
        return out
    }
}

// MARK: - 5. Calculator

public struct CalculatorProvider: SuggestProvider {
    public let id = "calculator"
    public init() {}

    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        guard input.context.mode != .searchTabs, input.siteSearch == nil, case .text(let text) = input.typed,
              let value = Calculator.evaluate(text) else { return [] }
        let answer = Calculator.format(value)
        // No URL: the typed search row below already searches the expression, and a shared URL
        // would merge the two rows. Return on this row copies the answer (the app's handler).
        var row = Suggestion(
            id: "calculator", kind: .calculator, title: answer, subtitle: "\(text) =",
            icon: .symbol("equal.circle"),
            provider: id, scoreDetail: ScoreDetail(quality: MatchQuality.exact, weight: Ranking.weight(.calculator)))
        row.canBeTopHit = true
        return [row]
    }
}

// MARK: - 6. Actions

public struct ActionsProvider: SuggestProvider {
    public let id = "actions"
    public var maxRows = 3
    let matcher: ActionMatcher

    public init(registry: ActionRegistry = .arcDefaults) {
        matcher = ActionMatcher(registry)
    }

    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        guard input.context.mode != .searchTabs, input.siteSearch == nil, case .text = input.typed,
              input.query.bytes.count >= 2 else { return [] }
        var rows: [Suggestion] = []
        for entry in matcher.entries where Self.isAvailable(entry.action.requirement, input) {
            let q = ActionMatcher.quality(input.query, entry)
            guard q > 0 else { continue }
            rows.append(row(entry.action, quality: q, input: input, space: nil))
        }
        // "Focus on <Space>" for the other Spaces of this Profile.
        let focus = BrowserAction(id: ActionRegistry.focusSpaceActionID, title: "", symbol: "rectangle.on.rectangle")
        for space in input.tabs.spaces
        where (input.profileOrdinal == nil || space.profileOrdinal == input.profileOrdinal) && space.id != input.context.spaceID {
            let q = TextMatching.rowQuality(input.query, fields: [(space.foldedTitle, 1), (space.foldedFocusTitle, 1)])
            guard q > 0 else { continue }
            var action = focus
            action.title = "Focus on \(space.title)"
            rows.append(row(action, quality: q, input: input, space: space))
        }
        rows.sort(by: Ranking.order)
        return Array(rows.prefix(maxRows))
    }

    private func row(_ action: BrowserAction, quality: Double, input: SuggestInput, space: TabIndex.SpaceSummary?) -> Suggestion {
        var row = Suggestion(
            id: "action:\(action.id)" + (space.map { ":\($0.id.rawValue.uuidString)" } ?? ""),
            kind: .action, title: action.title, subtitle: action.shortcut ?? "", actionID: action.id,
            icon: .symbol(action.symbol), spaceID: space?.id, spaceTitle: space?.title, provider: id,
            scoreDetail: ScoreDetail(quality: quality, weight: Ranking.weight(.action)))
        row.canBeTopHit = quality >= MatchQuality.prefix && input.query.bytes.count >= 3
        return row
    }

    static func isAvailable(_ requirement: ActionRequirement, _ input: SuggestInput) -> Bool {
        let tab = input.currentTab
        switch requirement {
        case .none: return true
        case .currentTab: return tab != nil
        case .currentTabInToday: return tab.map { !$0.isPinned && !$0.isFavorite } ?? false
        case .currentTabPinned: return tab?.isPinned ?? false
        case .currentTabHasPinnedURL: return tab.map { $0.isPinned || $0.isFavorite } ?? false
        case .currentTabIsFavorite: return tab?.isFavorite ?? false
        case .currentTabNotFavorite: return tab.map { !$0.isFavorite } ?? false
        case .currentTabInSplit: return tab?.isInSplit ?? false
        case .multipleSpaces:
            return input.tabs.spaces.filter { input.profileOrdinal == nil || $0.profileOrdinal == input.profileOrdinal }.count > 1
        }
    }
}

// MARK: - 7. Site Search

public struct SiteSearchProvider: SuggestProvider {
    public let id = "site-search"
    let index: SiteSearchIndex

    public init(sites: [SiteSearch] = SiteSearches.defaults()) {
        index = SiteSearchIndex(sites)
    }

    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        guard input.context.mode != .searchTabs else { return [] }
        if let site = input.siteSearch {
            guard !input.text.isEmpty, let url = site.searchURL(for: input.text) else { return [] }
            var row = searchRow(site, query: input.text, url: url, quality: MatchQuality.exact)
            row.isWhatYouTyped = true
            row.canBeTopHit = true
            return [row]
        }
        var rows: [Suggestion] = []
        if let (site, rest) = index.spaceTrigger(for: input.text), let url = site.searchURL(for: rest) {
            rows.append(searchRow(site, query: rest, url: url, quality: MatchQuality.exact))
        }
        if let site = index.tabTrigger(for: input.query.bytes) {
            let exact = index.entries.contains { $0.site.id == site.id && ($0.names.contains(input.query.bytes) || $0.keywords.contains(input.query.bytes)) }
            rows.append(Suggestion(
                id: "site-hint:\(site.id)", kind: .siteSearchHint, title: "Search \(site.name)",
                subtitle: "Press Tab to search \(site.name)", icon: .symbol("magnifyingglass"), siteSearchID: site.id,
                provider: id, scoreDetail: ScoreDetail(quality: exact ? MatchQuality.exact : MatchQuality.prefix,
                                                       weight: Ranking.weight(.siteSearchHint))))
        }
        return rows
    }

    private func searchRow(_ site: SiteSearch, query: String, url: URL, quality: Double) -> Suggestion {
        Suggestion(
            id: "site:\(site.id):\(query)", kind: .siteSearch, title: query, subtitle: "Search \(site.name)",
            url: url, icon: .symbol("magnifyingglass"), siteSearchID: site.id, provider: id,
            scoreDetail: ScoreDetail(quality: quality, weight: Ranking.weight(.siteSearch)))
    }
}

// MARK: - 3. History

public struct HistoryProvider: SuggestProvider {
    public let id = "history"
    public var limit = 24
    public var emptyQueryRows = 6
    let store: @MainActor (ProfileID?) -> HistoryStore?

    /// `store` returns the history database of a Profile (one per Profile, as in Chromium).
    public init(store: @escaping @MainActor (ProfileID?) -> HistoryStore?) {
        self.store = store
    }

    public func asyncOperation(for input: SuggestInput) -> (@Sendable () async -> [Suggestion]?)? {
        guard input.context.mode != .searchTabs, let store = store(input.profileID) else { return nil }
        if input.query.isEmpty && input.siteSearch != nil { return nil }
        let text = input.text, query = input.query, now = input.now, site = input.siteSearch
        let limit = input.query.isEmpty ? emptyQueryRows : limit
        let provider = id
        return {
            let matches = await store.search(text, limit: limit)
            if Task.isCancelled { return nil }
            return matches.compactMap { Self.row($0, query: query, now: now, site: site, provider: provider) }
        }
    }

    nonisolated static func row(_ m: HistoryMatch, query: FoldedQuery, now: Date, site: SiteSearch?, provider: String) -> Suggestion? {
        guard let scheme = m.url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "file" else { return nil }
        let host = TextMatching.displayHost(m.url)
        let urlText = TextMatching.matchableURL(m.url)
        if let site, !site.contains(host: host, matchableURL: urlText) { return nil }
        var quality = 0.0
        var hostOrURL = 0.0
        if !query.isEmpty {
            let hostBytes = TextMatching.fold(host), urlBytes = TextMatching.fold(urlText)
            quality = TextMatching.rowQuality(query, fields: [(TextMatching.fold(m.title), 1), (hostBytes, 1), (urlBytes, 0.9)])
            hostOrURL = max(TextMatching.quality(query.bytes, in: hostBytes), TextMatching.quality(query.bytes, in: urlBytes))
            // FTS matched it (for example on a token our matcher reads differently); keep a floor.
            if quality == 0 { quality = 20 }
        }
        var row = Suggestion(
            id: "history:\(TextMatching.urlKey(m.url))", kind: .history,
            title: m.title.isEmpty ? urlText : m.title, subtitle: host, url: m.url,
            icon: TextMatching.faviconURL(for: m.url).map(IconHint.favicon), provider: provider,
            scoreDetail: ScoreDetail(quality: quality, weight: Ranking.weight(.history),
                                     frecency: TextMatching.historyFrecency(visits: m.visitCount, typed: m.typedCount, lastVisit: m.lastVisit, now: now)))
        // Strong history: the host or URL starts with the query, and the page was typed or visited 3+ times.
        row.canBeTopHit = hostOrURL >= MatchQuality.prefix && (m.typedCount >= 1 || m.visitCount >= 3)
        return row
    }
}
