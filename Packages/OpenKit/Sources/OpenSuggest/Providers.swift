import Foundation
import OpenModel
import OpenStore
import Synchronization

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
    /// `query` without a typed `https://`, `http://`, then `www.`: what tab and history rows match, so
    /// "https://goo" still finds google.com and can complete (commandbar-completion §4.1.2 rule 3).
    public let matchQuery: FoldedQuery
    public let typed: TypedInput
    public let context: SuggestContext
    public let searchEngine: SearchEngine
    public var customSearchEngines: [SearchEngine] = []
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
        guard !input.context.mode.isScoped, input.siteSearch == nil else { return [] }
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
        guard input.context.mode != .searchActions else { return [] }
        let index = input.tabs
        // Edit mode never offers the current tab; Cmd+T does (F0063, F0043: the page behind the bar is a
        // Switch to Tab row, and F0043's completion comes from it; commandbar-completion §4.1.3).
        let excluded = input.context.mode == .editCurrentURL ? input.currentTab?.tabID : nil
        let currentSpace = index.spaceOrdinal(of: input.context.spaceID)
        var top = TopRows(capacity: input.query.isEmpty && input.context.mode != .searchTabs ? emptyQueryRows : maxRows)
        // Split panes become one candidate per split (§4.2.1): the best pane's quality and entry,
        // the most recent pane's recency. A split holding the excluded tab is left out.
        var splitBest: [Int32: (entry: Int, quality: Double, frecency: Double)] = [:]
        var excludedSplits: Set<Int32> = []
        // Scores are computed for every match from flat arrays; Suggestion values only for the winners.
        func detail(_ i: Int, quality: Double, frecency: Double) -> ScoreDetail {
            var boost = Ranking.locationBoost(index.locations[i])
            if index.spaceOrdinals[i] == currentSpace { boost += Ranking.currentSpaceBoost }
            return ScoreDetail(quality: quality, weight: Ranking.weight(.switchToTab), frecency: frecency, boost: boost)
        }
        func consider(_ i: Int, quality: Double) {
            let tab = index.tabs[i]
            let split = index.splitOrdinals[i]
            if tab.id == excluded {
                if split >= 0 { excludedSplits.insert(split) }
                return
            }
            let frecency = TextMatching.tabRecency(lastActiveAt: tab.lastActiveAt, now: input.now)
            guard split >= 0 else { top.insert(i, detail(i, quality: quality, frecency: frecency)); return }
            if let b = splitBest[split] {
                splitBest[split] = (quality > b.quality ? i : b.entry, max(quality, b.quality), max(frecency, b.frecency))
            } else {
                splitBest[split] = (i, quality, frecency)
            }
        }
        if input.query.isEmpty {
            // Empty query: most recently active tabs (score is recency + location), no Site Search scope.
            guard input.siteSearch == nil else { return [] }
            for i in 0..<index.tabs.count where input.profileOrdinal == nil || index.profileOrdinals[i] == Int32(input.profileOrdinal!) {
                consider(i, quality: 0)
            }
        } else {
            for m in Self.scan(input.matchQuery, index, profile: input.profileOrdinal) {
                if let site = input.siteSearch {
                    let e = index.entries[m.entry]
                    if !site.contains(host: e.host, matchableURL: TextMatching.matchableURL(e.url)) { continue }
                }
                consider(m.entry, quality: m.quality)
            }
        }
        // Edit mode: a split that holds the current tab is left out even when only another pane matched.
        if let excluded, !splitBest.isEmpty,
           let k = index.splits.firstIndex(where: { $0.paneSlots.contains { index.tabs[$0].id == excluded } }) {
            excludedSplits.insert(Int32(k))
        }
        for (split, b) in splitBest where !excludedSplits.contains(split) {
            var entry = b.entry
            // Empty query: the row targets the focused pane (else the first).
            if input.query.isEmpty {
                let s = index.splits[Int(split)]
                let focused = s.split.focusedPaneID
                entry = s.paneSlots.first { index.tabs[$0].id == focused } ?? s.paneSlots.first ?? b.entry
            }
            top.insert(entry, detail(entry, quality: b.quality, frecency: b.frecency))
        }
        return top.rows.map { (i, detail) in
            let e = index.entries[i]
            if index.splitOrdinals[i] >= 0 { return splitRow(i, detail, index: index, input: input) }
            let displayTitle = e.tab.displayTitle
            var row = Suggestion(
                id: "tab:\(e.tab.id.rawValue.uuidString)", kind: .switchToTab,
                title: displayTitle.isEmpty ? TextMatching.matchableURL(e.url) : displayTitle, subtitle: e.host,
                url: e.url, icon: Self.icon(e), tabID: e.tab.id, tabLocation: e.location,
                spaceID: e.spaceID, spaceTitle: e.spaceTitle, provider: id, scoreDetail: detail)
            row.canBeTopHit = detail.quality >= MatchQuality.prefix && input.matchQuery.bytes.count >= 2
            row.isExactTabMatch = detail.quality == MatchQuality.exact
            return row
        }
    }

    /// One row for the split that holds entry `i` (its best-matching or focused pane).
    private func splitRow(_ i: Int, _ detail: ScoreDetail, index: TabIndex, input: SuggestInput) -> Suggestion {
        let e = index.entries[i]
        let s = index.splits[Int(index.splitOrdinals[i])]
        let panes = s.paneSlots.map { index.entries[$0] }
        let titles = panes.map { p in p.tab.displayTitle.isEmpty ? TextMatching.matchableURL(p.url) : p.tab.displayTitle }
        var row = Suggestion(
            id: "split:\(s.split.id.rawValue.uuidString)", kind: .switchToTab, title: titles.joined(separator: " | "),
            url: e.url, icon: Self.icon(e), tabID: e.tab.id, tabLocation: .splitPane,
            spaceID: e.spaceID, spaceTitle: e.spaceTitle, provider: id, scoreDetail: detail)
        row.split = SplitRowInfo(splitID: s.split.id, paneTabIDs: panes.map(\.tab.id), paneTitles: titles,
                                 paneIcons: panes.map(Self.icon), paneURLs: panes.map(\.url), isVertical: s.isVertical)
        // Any pane may make the split exact (T5) or eligible (T7): the quality is the best pane's.
        row.canBeTopHit = detail.quality >= MatchQuality.prefix && input.matchQuery.bytes.count >= 2
        row.isExactTabMatch = detail.quality == MatchQuality.exact
        return row
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
        guard !input.context.mode.isScoped, input.siteSearch == nil, case .text(let text) = input.typed,
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
    /// Rows in the Actions scope (the panel shows 5 and scrolls).
    public var scopeRows = 12
    let matcher: ActionMatcher

    public init(registry: ActionRegistry = .arcDefaults) {
        matcher = ActionMatcher(registry)
    }

    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        if input.context.mode == .searchActions { return scoped(input) }
        guard !input.context.mode.isScoped, input.siteSearch == nil, case .text = input.typed,
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

    /// The Actions scope (§4.3.3): any text, no length minimum; the empty query lists the available
    /// actions in registry seed order (guess: Arc ranks by recent use). Requirements still hide actions.
    private func scoped(_ input: SuggestInput) -> [Suggestion] {
        var rows: [Suggestion] = []
        if input.query.isEmpty {
            for entry in matcher.entries where Self.isAvailable(entry.action.requirement, input) {
                rows.append(row(entry.action, quality: 0, input: input, space: nil))
                if rows.count == scopeRows { break }
            }
            // Seed order: a falling score keeps it through ranking's sort.
            for i in rows.indices { rows[i].scoreDetail.boost = Double(rows.count - i); rows[i].score = rows[i].scoreDetail.total }
            return rows
        }
        for entry in matcher.entries where Self.isAvailable(entry.action.requirement, input) {
            let q = ActionMatcher.quality(input.query, entry, minimumBytes: 1)
            guard q > 0 else { continue }
            rows.append(row(entry.action, quality: q, input: input, space: nil))
        }
        let focus = BrowserAction(id: ActionRegistry.focusSpaceActionID, title: "", symbol: "rectangle.on.rectangle")
        for space in input.tabs.spaces
        where (input.profileOrdinal == nil || space.profileOrdinal == input.profileOrdinal) && space.id != input.context.spaceID {
            let q = TextMatching.rowQuality(input.query, fields: [(space.foldedTitle, 1), (space.foldedFocusTitle, 1)])
            guard q > 0 else { continue }
            var action = focus
            action.title = "Focus on \(space.title)"
            rows.append(row(action, quality: q, input: input, space: space))
        }
        // Equal matches: the title the query covers more of goes first ("side" → Show/Hide Sidebar before
        // Reveal Tab in Sidebar). Open rule; Arc ranks this scope by recent use (CC-16), which Open does not keep.
        let n = Double(input.query.bytes.count)
        for i in rows.indices {
            rows[i].scoreDetail.boost += min(1, n / Double(max(1, rows[i].title.utf8.count)))
            rows[i].score = rows[i].scoreDetail.total
            rows[i].canBeTopHit = rows[i].scoreDetail.quality > 0
        }
        rows.sort(by: Ranking.order)
        return Array(rows.prefix(scopeRows))
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
        guard !input.context.mode.isScoped else { return [] }
        if let site = input.siteSearch {
            guard !input.text.isEmpty, let url = site.searchURL(for: input.text) else { return [] }
            var row = searchRow(site, query: input.text, url: url, quality: MatchQuality.exact)
            row.isWhatYouTyped = true
            row.canBeTopHit = true
            return [row]
        }
        var rows: [Suggestion] = []
        if let (site, rest) = index.spaceTrigger(for: input.text), !site.isScope, let url = site.searchURL(for: rest) {
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
    let carry = HistoryCarryOver()

    /// `store` returns the history database of a Profile (one per Profile, as in Chromium).
    public init(store: @escaping @MainActor (ProfileID?) -> HistoryStore?) {
        self.store = store
    }

    /// Carry-over (commandbar-completion §4.1.3): when the text extends the previous query, snapshot 0
    /// keeps that query's history pages whose host or URL still matches, re-scored for the new text.
    /// The history snapshot replaces them. Without it a history completion would vanish for a frame
    /// on every keystroke. Same rule as the remote carry-over (docs/suggest.md §4).
    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        guard !input.context.mode.isScoped, !input.query.isEmpty else { return [] }
        let q = input.matchQuery
        let matches = carry.matches(profile: input.profileID, extending: q.bytes)
        guard !matches.isEmpty else { return [] }
        return matches.compactMap { m -> Suggestion? in
            let host = TextMatching.fold(TextMatching.displayHost(m.url)), url = TextMatching.fold(TextMatching.matchableURL(m.url))
            guard TextMatching.quality(q.bytes, in: host) > 0 || TextMatching.quality(q.bytes, in: url) > 0 else { return nil }
            return Self.row(m, query: q, now: input.now, site: input.siteSearch, provider: id)
        }
    }

    public func asyncOperation(for input: SuggestInput) -> (@Sendable () async -> [Suggestion]?)? {
        guard !input.context.mode.isScoped, let store = store(input.profileID) else { return nil }
        if input.query.isEmpty && input.siteSearch != nil { return nil }
        let text = input.matchQuery.text, query = input.matchQuery, now = input.now, site = input.siteSearch
        let limit = input.query.isEmpty ? emptyQueryRows : limit
        let provider = id, carry = carry, profile = input.profileID
        return {
            let matches = await store.search(text, limit: limit)
            if Task.isCancelled { return nil }
            carry.store(profile: profile, query: query.bytes, matches: matches)
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

/// The last finished history answer, per engine instance: the source of history carry-over rows.
final class HistoryCarryOver: Sendable {
    private struct Last { var profile: ProfileID?; var query: [UInt8]; var matches: [HistoryMatch] }
    private let last = Mutex<Last?>(nil)

    func store(profile: ProfileID?, query: [UInt8], matches: [HistoryMatch]) {
        last.withLock { $0 = query.isEmpty ? nil : Last(profile: profile, query: query, matches: matches) }
    }

    /// Matches of the previous query when `query` extends it in the same Profile, else none.
    func matches(profile: ProfileID?, extending query: [UInt8]) -> [HistoryMatch] {
        last.withLock { l in
            guard let l, l.profile == profile, query.count > l.query.count, query.starts(with: l.query) else { return [] }
            return l.matches
        }
    }
}
