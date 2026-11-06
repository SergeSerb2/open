import Foundation

/// Profile/window data is supplied by the App. Providers hold no adapter between queries.
@MainActor public protocol ExtensionCommandBarSource: AnyObject {
    var actions: [ExtensionCommandBarAction] { get } // enabled actions only
    var keywords: [ExtensionKeyword] { get }
    func startSession(extensionID: String)
    /// Resolve nil on task cancellation, including an engine completion superseded by newer text.
    func inputChanged(_ text: String, extensionID: String) async -> [ExtensionOmniboxRow]?
    func defaultRow(extensionID: String, text: String) -> ExtensionOmniboxRow
    func cancelSession(extensionID: String)
    func deleteSuggestion(_ content: String, extensionID: String)
}

public struct ExtensionCommandBarAction: Sendable, Hashable {
    public let id: String
    public let name: String
    public let shortcutKeys: [String]
    fileprivate let match: ActionMatcher.Entry
    public init(id: String, name: String, shortcutKeys: [String] = []) {
        self.id = id; self.name = name; self.shortcutKeys = shortcutKeys
        match = ActionMatcher.entry(for: BrowserAction(id: id, title: name))
    }
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.name == b.name && a.shortcutKeys == b.shortcutKeys }
    public func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(name); hasher.combine(shortcutKeys) }
}
public struct ExtensionKeyword: Sendable, Hashable {
    public var id: String
    public var name: String
    public var keyword: String
    public init(id: String, name: String, keyword: String) { self.id = id; self.name = name; self.keyword = keyword }
}
public struct ExtensionOmniboxRow: Sendable, Hashable {
    public var content: String
    public var title: String
    /// UTF-16 offsets, matching NSRange from the engine. Invalid ranges are refused.
    public var boldRanges: [Range<Int>]
    public var deletable: Bool
    public init(content: String, title: String, boldRanges: [Range<Int>] = [], deletable: Bool = false) {
        self.content = content; self.title = title; self.boldRanges = boldRanges; self.deletable = deletable
    }
}

/// Bounds at the engine-free boundary; over-limit rows are refused, never truncated into executable content.
/// At most 5 accepted rows, each with 16K UTF-16 units in title/content and 256 ranges
/// (under 160 KiB payload per row; no single allocation approaches the allocator ceiling).
public enum ExtensionProviderLimits {
    public static let entries = 4096
    public static let textUTF16 = 16_384
    public static let ranges = 256
    public static func accepts(_ row: ExtensionOmniboxRow) -> Bool {
        let n = row.title.utf16.count
        return n <= textUTF16 && row.content.utf16.count <= textUTF16 && row.boldRanges.count <= ranges
            && row.boldRanges.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= n }
    }
}

public struct ExtensionActionsProvider: SuggestProvider {
    public let id = "extensions"
    private weak var source: (any ExtensionCommandBarSource)?
    private let siteSearches: @MainActor () -> [SiteSearch]
    public init(source: any ExtensionCommandBarSource, siteSearches: @escaping @MainActor () -> [SiteSearch] = { SiteSearches.defaults() }) {
        self.source = source; self.siteSearches = siteSearches
    }
    public static func conflicts(_ keyword: String, sites: [SiteSearch]) -> Bool {
        let folded = TextMatching.fold(keyword)
        return sites.contains { TextMatching.fold($0.name) == folded || TextMatching.fold($0.host) == folded || $0.keywords.contains { TextMatching.fold($0) == folded } }
    }
    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        guard !input.context.mode.isScoped, input.siteSearch == nil, input.context.extensionScopeID == nil,
              !input.query.isEmpty, let source else { return [] }
        var rows: [Suggestion] = []
        for action in source.actions.prefix(ExtensionProviderLimits.entries) where action.name.utf16.count <= ExtensionProviderLimits.textUTF16 {
            let quality = ActionMatcher.quality(input.query, action.match)
            guard quality > 0 else { continue }
            var row = Suggestion(id: "extension-action:\(action.id)", kind: .extensionAction, title: action.name,
                                 subtitle: "Extension", extensionID: action.id, icon: .extension(action.id), provider: id,
                                 scoreDetail: .init(quality: quality, weight: Ranking.weight(.extensionAction)))
            row.shortcutKeys = action.shortcutKeys
            row.canBeTopHit = input.query.bytes.count >= 3 && quality >= MatchQuality.prefix
            rows.append(row)
        }
        rows.sort(by: Ranking.order)
        rows = Array(rows.prefix(3))
        if let keyword = source.keywords.prefix(ExtensionProviderLimits.entries).first(where: { TextMatching.fold($0.keyword) == input.query.bytes }),
           !Self.conflicts(keyword.keyword, sites: siteSearches()) {
            rows.append(Suggestion(id: "extension-keyword:\(keyword.id)", kind: .extensionKeywordHint, title: keyword.name,
                                   extensionID: keyword.id, icon: .extension(keyword.id), provider: id,
                                   scoreDetail: .init(quality: MatchQuality.exact, weight: Ranking.weight(.extensionKeywordHint))))
        }
        return rows
    }
}

public struct ExtensionOmniboxProvider: SuggestProvider {
    public let id = "extension-omnibox"
    private weak var source: (any ExtensionCommandBarSource)?
    @MainActor private final class State { var generation = 0 }
    private let state = State()
    public init(source: any ExtensionCommandBarSource) { self.source = source }
    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        guard let extensionID = input.context.extensionScopeID, let source else { return [] }
        return Self.rows([], source: source, extensionID: extensionID, text: input.rawText)
    }
    public func asyncOperation(for input: SuggestInput) -> (@Sendable () async -> [Suggestion]?)? {
        // Increment for every query, including scope exit. A late source may ignore task cancellation.
        state.generation += 1
        guard let extensionID = input.context.extensionScopeID, let source,
              input.rawText.utf16.count <= ExtensionProviderLimits.textUTF16 else { return nil }
        let generation = state.generation, state = state, text = input.rawText
        return { @MainActor [weak source] in
            guard let source, state.generation == generation, !Task.isCancelled else { return nil }
            guard let answer = await source.inputChanged(text, extensionID: extensionID),
                  state.generation == generation, !Task.isCancelled else { return nil }
            return Self.rows(answer, source: source, extensionID: extensionID, text: text)
        }
    }
    private static func rows(_ answer: [ExtensionOmniboxRow], source: any ExtensionCommandBarSource, extensionID: String, text: String) -> [Suggestion] {
        guard text.utf16.count <= ExtensionProviderLimits.textUTF16 else { return [] }
        var first = source.defaultRow(extensionID: extensionID, text: text)
        guard ExtensionProviderLimits.accepts(first) else { return [] }
        first.content = text
        let substitutions = first.title.components(separatedBy: "%s").count - 1
        let replacedLength = first.title.utf16.count + substitutions * (text.utf16.count - 2)
        guard replacedLength <= ExtensionProviderLimits.textUTF16 else { return [] }
        first.title = first.title.isEmpty ? text : first.title.replacingOccurrences(of: "%s", with: text)
        // Default template ranges do not describe the substituted title. The bridge may supply a final title.
        if substitutions > 0 { first.boldRanges = [] }
        let name = source.keywords.prefix(ExtensionProviderLimits.entries).first { $0.id == extensionID }?.name ?? ""
        return ([first] + answer.prefix(4)).enumerated().compactMap { index, value in
            guard ExtensionProviderLimits.accepts(value) else { return nil }
            var row = Suggestion(id: "extension-suggestion:\(extensionID):\(index):\(value.content)", kind: .extensionSuggestion,
                                 title: value.title, subtitle: index == 0 ? name : value.content == value.title ? "" : value.content,
                                 extensionID: extensionID, icon: .extension(extensionID), provider: "extension-omnibox",
                                 scoreDetail: .init(quality: MatchQuality.exact, weight: 1), isWhatYouTyped: index == 0)
            row.extensionContent = value.content; row.boldRanges = value.boldRanges
            row.isDeletable = index != 0 && value.deletable
            return row
        }
    }
}
