import Foundation

/// Deterministic ranking. Every constant and rule here is listed in docs/suggest.md.
///
/// score = quality × weight(kind) + frecency + boost
public enum Ranking {
    // MARK: Constants

    public static func weight(_ kind: SuggestionKind) -> Double {
        switch kind {
        case .switchToTab: return 1.0
        case .navigate: return 1.0
        case .calculator: return 1.0
        case .history: return 0.9
        case .action: return 0.85
        case .siteSearch: return 0.8
        case .siteSearchHint: return 0.6
        case .search: return 0.5
        case .searchSuggestion: return 0.45
        }
    }

    /// Same URL, different places: today tab > pinned tab = favorite > history (history gets no boost).
    public static func locationBoost(_ location: TabLocation) -> Double {
        switch location {
        case .today, .splitPane: return 12
        case .pinned, .favorite: return 10
        }
    }

    public static let currentSpaceBoost: Double = 3
    /// Share of a history row's frecency that an open tab with the same URL absorbs.
    public static let absorbedFrecencyShare: Double = 0.5

    /// Per-kind row limits after the top hit.
    public static func cap(_ kind: SuggestionKind, mode: SuggestMode) -> Int {
        switch kind {
        case .switchToTab: return mode == .searchTabs ? .max : 6
        case .history: return 6
        case .searchSuggestion: return 5
        case .navigate: return 3
        case .action: return 3
        case .siteSearch: return 2
        case .siteSearchHint, .calculator, .search: return 1
        }
    }

    /// Tie-break order for equal scores.
    static func kindPriority(_ kind: SuggestionKind) -> Int {
        switch kind {
        case .switchToTab: return 8
        case .navigate: return 7
        case .calculator: return 6
        case .history: return 5
        case .action: return 4
        case .siteSearch: return 3
        case .siteSearchHint: return 2
        case .search: return 1
        case .searchSuggestion: return 0
        }
    }

    /// Score descending, then kind priority, then title, then id. Total and deterministic.
    public static func order(_ a: Suggestion, _ b: Suggestion) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let ka = kindPriority(a.kind), kb = kindPriority(b.kind)
        if ka != kb { return ka > kb }
        if a.title != b.title { return a.title < b.title }
        return a.id < b.id
    }

    // MARK: Dedupe and merge

    /// Which row survives when two rows share a URL. Typed rows sit just below open tabs.
    static func mergePrecedence(_ s: Suggestion) -> Int {
        if s.kind == .switchToTab { return 5 }
        if s.isWhatYouTyped || s.providers.first == "typed" { return 4 }
        switch s.kind {
        case .history: return 3
        case .navigate, .siteSearch: return 2
        default: return 1
        }
    }

    static func dedupeKey(_ s: Suggestion) -> String {
        if let url = s.url { return "u|" + TextMatching.urlKey(url) }
        return "i|" + s.id
    }

    /// Folds `loser` into `winner`. Returns the merged row.
    static func absorb(_ winner: Suggestion, _ loser: Suggestion) -> Suggestion {
        var w = winner
        for p in loser.providers where !w.providers.contains(p) { w.providers.append(p) }
        if loser.isWhatYouTyped { w.isWhatYouTyped = true }
        w.canBeTopHit = w.canBeTopHit || loser.canBeTopHit
        if w.kind == .switchToTab, loser.kind == .history {
            w.scoreDetail.boost += absorbedFrecencyShare * loser.scoreDetail.frecency
            w.score = w.scoreDetail.total
        }
        if w.kind == .navigate, w.isWhatYouTyped, loser.kind == .history, w.subtitle.isEmpty {
            w.subtitle = loser.title // typed "github.com" shows the page title from history
        }
        return w
    }

    /// One row per normalized URL (scheme, "www.", trailing slash, and fragment ignored). Then, for the
    /// hosts in `TextMatching.dedupeByTitleAndHost`, one tab/history row per (title, host).
    /// In edit mode the typed URL never absorbs a tab: both rows stay.
    static func dedupe(_ rows: [Suggestion], mode: SuggestMode) -> [Suggestion] {
        var groups: [String: [Suggestion]] = [:]
        var keys: [String] = []
        for row in rows {
            let k = dedupeKey(row)
            if groups[k] == nil { keys.append(k) }
            groups[k, default: []].append(row)
        }
        var out: [Suggestion] = []
        for k in keys {
            var group = groups[k]!
            group.sort { a, b in
                let pa = mergePrecedence(a), pb = mergePrecedence(b)
                return pa != pb ? pa > pb : order(a, b)
            }
            if mode == .editCurrentURL, let typed = group.firstIndex(where: { $0.isWhatYouTyped && $0.kind == .navigate }) {
                let typedRow = group.remove(at: typed)
                let tabs = group.filter { $0.kind == .switchToTab }
                out.append(group.filter { $0.kind != .switchToTab }.reduce(typedRow, absorb))
                if let bestTab = tabs.first { out.append(tabs.dropFirst().reduce(bestTab, absorb)) }
            } else {
                out.append(group.dropFirst().reduce(group[0], absorb))
            }
        }
        // Second pass: (title, host) for multi-page apps.
        var seen: [String: Int] = [:]
        var result: [Suggestion] = []
        for row in out {
            guard row.kind == .switchToTab || row.kind == .history, let url = row.url else { result.append(row); continue }
            let host = TextMatching.displayHost(url)
            guard dedupeHosts.contains(host) else { result.append(row); continue }
            let k = host + "|" + row.title.lowercased()
            if let i = seen[k] {
                let (a, b) = mergePrecedence(result[i]) >= mergePrecedence(row) ? (result[i], row) : (row, result[i])
                result[i] = absorb(a, b)
            } else {
                seen[k] = result.count
                result.append(row)
            }
        }
        return result
    }

    static let dedupeHosts = TextMatching.dedupeByTitleAndHost

    // MARK: Top hit and final order

    struct Ranked {
        var rows: [Suggestion]
        var hasTopHit: Bool
        var rule: TopHitRule
        var completion: InlineCompletion?
    }

    /// Top-hit rules, first match wins (docs/suggest.md "Top hit"):
    /// T0 empty → none · T1 Site Search scope → scoped row · T2 search-tabs → best tab ·
    /// T3a inline completion allowed → the best strong tab/history row the text completes ·
    /// T3 URL-like input → typed URL (or the open tab that has that URL, new-tab mode) ·
    /// T4 arithmetic → calculator · T5 exact tab title/host → that tab ·
    /// T6 exact action title/alias (3+ characters) → that action ·
    /// T7 best eligible row (strong tab, strong history, strong action) · T8 typed search.
    static func rank(_ candidates: [Suggestion], input: SuggestInput, maxResults: Int) -> Ranked {
        let mode = input.context.mode
        var rows = dedupe(candidates, mode: mode)
        rows.sort(by: order)

        var topIndex: Int?
        var rule = TopHitRule.none
        var topCompletion: InlineCompletion?
        if input.siteSearch != nil {
            topIndex = rows.firstIndex { $0.kind == .siteSearch && $0.isWhatYouTyped }
            rule = .siteSearchScope
        } else if mode == .searchTabs {
            topIndex = input.query.isEmpty ? nil : rows.firstIndex { $0.kind == .switchToTab }
            rule = topIndex == nil ? .none : .bestTab
        } else if input.query.isEmpty {
            rule = .none
        } else if let (i, completion) = inlineCompletionTopHit(rows, input: input) {
            topIndex = i; rule = .inlineCompletion; topCompletion = completion
        } else if input.typed.isURL, let i = rows.firstIndex(where: { $0.isWhatYouTyped }) {
            topIndex = i; rule = .typedURL
        } else if let i = rows.firstIndex(where: { $0.kind == .calculator }) {
            topIndex = i; rule = .calculator
        } else if let i = rows.firstIndex(where: { $0.kind == .switchToTab && $0.isExactTabMatch }) {
            topIndex = i; rule = .exactTab
        } else if input.query.bytes.count >= 3,
                  let i = rows.firstIndex(where: { $0.kind == .action && $0.scoreDetail.quality == MatchQuality.exact }) {
            topIndex = i; rule = .exactAction
        } else if let i = rows.firstIndex(where: { $0.canBeTopHit && $0.kind != .searchSuggestion }) {
            topIndex = i; rule = .bestEligible
        } else if let i = rows.firstIndex(where: { $0.isWhatYouTyped }) {
            // The typed search row, or the open tab it merged into (a tab already showing that search).
            topIndex = i; rule = .typedSearch
        }
        if topIndex == nil, rule != .none { rule = .none }
        // T5 and T7 may complete too (F0062: "Google" = a tab title completes to the lower-case host).
        if let topIndex, topCompletion == nil, rule == .exactTab || rule == .bestEligible {
            topCompletion = InlineCompletion.make(for: rows[topIndex], input: input)
        }

        var final: [Suggestion] = []
        var counts: [SuggestionKind: Int] = [:]
        if let topIndex {
            let top = rows.remove(at: topIndex)
            final.append(top)
            counts[top.kind] = 1
        }
        for row in rows where final.count < maxResults {
            let n = counts[row.kind, default: 0]
            if n >= cap(row.kind, mode: mode) { continue }
            counts[row.kind] = n + 1
            final.append(row)
        }
        return Ranked(rows: final, hasTopHit: topIndex != nil, rule: rule, completion: topCompletion)
    }

    /// Rule T3a (commandbar-completion §4.1.3): with inline completion allowed, no arithmetic (T4) and no
    /// exact tab title or host (T5), the highest-ranked row that may be a top hit and that the typed text
    /// completes. Looks at most at the ranked rows' first `maxResults` entries; prefix compares only.
    static func inlineCompletionTopHit(_ rows: [Suggestion], input: SuggestInput) -> (Int, InlineCompletion)? {
        guard InlineCompletion.allowed(input),
              !rows.contains(where: { $0.kind == .calculator || ($0.kind == .switchToTab && $0.isExactTabMatch) }) else { return nil }
        // A tab whose host (or URL) the text starts is strong for T3a even when only its URL field matched
        // ("localhost:30" → a tab on localhost:3000: the host field has no port), as long as 2+ bytes were typed.
        let strongTabBytes = input.matchQuery.bytes.count >= 2
        for (i, row) in rows.enumerated() where (row.canBeTopHit || (row.kind == .switchToTab && strongTabBytes)) && InlineCompletion.canComplete(row) {
            if let completion = InlineCompletion.make(for: row, input: input) { return (i, completion) }
        }
        return nil
    }
}
