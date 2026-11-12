import Foundation
import OpenModel

/// Which command bar entry point is asking. See docs/suggest.md "Modes".
public enum SuggestMode: String, Sendable, Codable, CaseIterable {
    /// Cmd+T: submit opens a new Today tab.
    case newTab
    /// Cmd+L: the query starts as the current tab URL; submit navigates the current tab.
    case editCurrentURL
    /// Tabs scope: only open, pinned, and favorite tabs.
    case searchTabs
    /// Actions scope: only browser actions (commandbar-completion §4.3.3; Arc's TypeTravel, CC-16).
    case searchActions

    /// A scope mode: one provider, no typed, history, remote, calculator, or Site Search rows.
    public var isScoped: Bool { self == .searchTabs || self == .searchActions }
}

public struct SuggestContext: Sendable {
    public var mode: SuggestMode
    /// Results come only from this Profile. Nil means the Profile of `spaceID`, else every Profile.
    public var profileID: ProfileID?
    /// The Space of the window that opened the command bar. Its tabs get a small boost.
    public var spaceID: SpaceID?
    /// The selected tab. Edit mode never offers "Switch to Tab" for it.
    public var currentTabID: ItemID?
    public var currentTabURL: URL?
    /// False turns off the network provider (setting "Include search engine suggestions", or offline).
    public var allowsRemoteSuggestions: Bool
    /// `SearchEngine.id`. Nil means Google.
    public var searchEngineID: String?
    /// Set while Site Search is active (`SiteSearch.id`). The query then searches that site.
    public var siteSearchID: String?
    public var extensionScopeID: String?
    /// The bar's last edit was an insertion at the end of the text with no selection (typing, or an IME
    /// commit at the end). Only then may the snapshot carry an inline completion (commandbar-completion §4.1.1).
    public var allowsInlineCompletion: Bool
    /// Names of the App's next Undo and Redo ("Close Tab"), for "Undo <name>" / "Redo <name>" actions.
    public var undoActionName: String? = nil
    public var redoActionName: String? = nil

    public init(
        mode: SuggestMode = .newTab,
        profileID: ProfileID? = nil,
        spaceID: SpaceID? = nil,
        currentTabID: ItemID? = nil,
        currentTabURL: URL? = nil,
        allowsRemoteSuggestions: Bool = true,
        searchEngineID: String? = nil,
        siteSearchID: String? = nil,
        extensionScopeID: String? = nil,
        allowsInlineCompletion: Bool = false
    ) {
        self.mode = mode
        self.profileID = profileID
        self.spaceID = spaceID
        self.currentTabID = currentTabID
        self.currentTabURL = currentTabURL
        self.allowsRemoteSuggestions = allowsRemoteSuggestions
        self.searchEngineID = searchEngineID
        self.siteSearchID = siteSearchID
        self.extensionScopeID = extensionScopeID
        self.allowsInlineCompletion = allowsInlineCompletion
    }
}

public enum SuggestionKind: String, Sendable, Codable, CaseIterable {
    /// Open a URL: what the user typed, or a URL the search engine suggested.
    case navigate
    /// Search the default engine for what the user typed.
    case search
    /// Select an existing sidebar tab (open, pinned, or favorite), maybe in another Space.
    case switchToTab
    /// Open a page from history.
    case history
    /// A query the search engine suggested.
    case searchSuggestion
    case calculator
    /// A browser command. `actionID` names it; the app runs the handler.
    case action
    /// Search one site (Site Search) for the query.
    case siteSearch
    /// "Press Tab to search <Site>". Tab (or Return) enters Site Search; the row has no URL.
    case siteSearchHint
    case extensionAction, extensionKeywordHint, extensionSuggestion
}

public enum IconHint: Sendable, Hashable {
    /// Favicon of the page's origin (`<scheme>://<host>/favicon.ico`). The app looks up its favicon cache first.
    case favicon(URL)
    case symbol(String)
    /// A tab's custom emoji icon.
    case emoji(String)
    case `extension`(String)
}

/// Where a `switchToTab` row lives.
public enum TabLocation: String, Sendable, Codable {
    case today, pinned, favorite, splitPane
}

/// How a row's score was built: `quality × weight + frecency + boost`.
public struct ScoreDetail: Sendable, Hashable {
    /// Text match quality, 0...100 (see `MatchQuality`).
    public var quality: Double
    /// Provider weight for the row kind.
    public var weight: Double
    /// Visit/typed counts and recency, 0...30 for history, 0...6 for tab recency.
    public var frecency: Double
    /// Location boosts (today tab, pinned, favorite, current Space, merged history).
    public var boost: Double

    public init(quality: Double, weight: Double, frecency: Double = 0, boost: Double = 0) {
        self.quality = quality; self.weight = weight; self.frecency = frecency; self.boost = boost
    }

    public var total: Double { quality * weight + frecency + boost }
}

/// One Split View as one row (commandbar-completion §4.2; Arc CC-12…CC-14): the panes in order.
public struct SplitRowInfo: Sendable, Hashable {
    public var splitID: ItemID
    /// Pane tabs, titles, icons, and URLs in pane order.
    public var paneTabIDs: [ItemID]
    public var paneTitles: [String]
    public var paneIcons: [IconHint?]
    public var paneURLs: [URL]
    /// `SplitOrientation.vertical`: panes stacked top to bottom.
    public var isVertical: Bool

    public init(splitID: ItemID, paneTabIDs: [ItemID], paneTitles: [String], paneIcons: [IconHint?], paneURLs: [URL], isVertical: Bool) {
        self.splitID = splitID; self.paneTabIDs = paneTabIDs; self.paneTitles = paneTitles
        self.paneIcons = paneIcons; self.paneURLs = paneURLs; self.isVertical = isVertical
    }
}

public struct Suggestion: Sendable, Identifiable, Hashable {
    /// Stable across snapshots of one query, so the UI can diff rows and keep the selection.
    public var id: String
    public var kind: SuggestionKind
    public var title: String
    public var subtitle: String
    public var url: URL?
    public var extensionID: String?
    public var extensionContent: String?
    /// UTF-16 offsets, as in the engine and AppKit text system.
    public var boldRanges: [Range<Int>] = []
    public var isDeletable = false
    public var shortcutKeys: [String] = []
    public var actionID: String?
    public var icon: IconHint?
    /// Target tab for `switchToTab`.
    public var tabID: ItemID?
    public var tabLocation: TabLocation?
    /// Space that holds the target tab, or the target Space of a "Focus on <Space>" action.
    /// Nil for favorites, which belong to the Profile.
    public var spaceID: SpaceID?
    public var spaceTitle: String?
    /// Site for `siteSearch` and `siteSearchHint` rows.
    public var siteSearchID: String?
    /// Providers that produced this row. More than one after a merge (for example `tabs` + `history`).
    public var providers: [String]
    public var score: Double
    public var scoreDetail: ScoreDetail
    /// True for the row that carries the user's literal input (typed URL or typed search).
    public var isWhatYouTyped: Bool
    /// Rule T7: the row passed its kind's top-hit test (see docs/suggest.md "Top hit").
    public var canBeTopHit: Bool = false
    /// Rule T5: a tab whose title or host equals the query.
    public var isExactTabMatch: Bool = false
    /// A Split View row: one row for all its panes. `tabID` and `url` are the best-matching pane
    /// (for an empty query the focused pane), `title` the pane titles joined with " | ". Nil otherwise.
    public var split: SplitRowInfo?

    public init(
        id: String, kind: SuggestionKind, title: String, subtitle: String = "",
        url: URL? = nil, actionID: String? = nil, extensionID: String? = nil, icon: IconHint? = nil,
        tabID: ItemID? = nil, tabLocation: TabLocation? = nil,
        spaceID: SpaceID? = nil, spaceTitle: String? = nil, siteSearchID: String? = nil,
        provider: String, scoreDetail: ScoreDetail, isWhatYouTyped: Bool = false
    ) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle
        self.url = url; self.actionID = actionID; self.extensionID = extensionID; self.icon = icon
        self.tabID = tabID; self.tabLocation = tabLocation
        self.spaceID = spaceID; self.spaceTitle = spaceTitle; self.siteSearchID = siteSearchID
        self.providers = [provider]
        self.scoreDetail = scoreDetail
        self.score = scoreDetail.total
        self.isWhatYouTyped = isWhatYouTyped
    }
}

/// Time spent per provider for one snapshot.
public struct ProviderTiming: Sendable, Hashable {
    public var provider: String
    public var milliseconds: Double
    public var isAsync: Bool
}

public struct SuggestionSnapshot: Sendable {
    public var query: String
    /// 0 for the local snapshot. Each async provider that finishes adds one.
    public var sequence: Int
    /// True on the last snapshot of the stream.
    public var isFinal: Bool
    /// How the input was read (URL, search text, or empty).
    public var input: TypedInput
    /// Ranked rows. When `hasTopHit` is true, `suggestions[0]` is the top hit (what Return does).
    public var suggestions: [Suggestion]
    public var hasTopHit: Bool
    /// The rule that chose the top hit (see docs/suggest.md "Top hit").
    public var topHitRule: TopHitRule
    /// Milliseconds from `query(_:context:)` to this snapshot.
    public var elapsedMilliseconds: Double
    /// Providers that contributed so far, with their own run time.
    public var timings: [ProviderTiming]
    /// Async providers still running.
    public var pendingProviders: [String]
    /// The top hit's inline completion, when the context allowed one (§4.1). Rules T3a, T5, and T7 can
    /// produce it; it always belongs to `suggestions[0]`.
    public var inlineCompletion: InlineCompletion?

    public var topHit: Suggestion? { hasTopHit ? suggestions.first : nil }
}

/// Top-hit rules in priority order. The first rule that applies picks the top hit.
public enum TopHitRule: String, Sendable {
    case extensionScope = "T1-extension-scope"
    case none = "T0-empty"
    case siteSearchScope = "T1-site-search-scope"
    case bestTab = "T2-search-tabs"
    case typedURL = "T3-typed-url"
    case calculator = "T4-calculator"
    case exactTab = "T5-exact-tab"
    case exactAction = "T6-exact-action"
    case bestEligible = "T7-best-eligible"
    case typedSearch = "T8-typed-search"
    /// T3a: a strong tab or history row whose host (or URL) the typed text starts, while inline completion
    /// is allowed (commandbar-completion §4.1.3). Checked after T2 and before T3.
    case inlineCompletion = "T3a-inline-completion"
    /// T2a: the Actions scope with a query → the best action (commandbar-completion §4.3.3).
    case bestAction = "T2a-search-actions"
}
