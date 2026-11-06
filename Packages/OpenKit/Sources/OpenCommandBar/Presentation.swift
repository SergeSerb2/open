import Foundation
import OpenModel
import OpenSuggest

/// Leading icon of a row or of the input.
public enum CommandBarIcon: Sendable, Hashable {
    /// The page's favicon from the favicon source; `fallback` (an SF Symbol) until it loads.
    case favicon(URL, fallback: String)
    /// An SF Symbol. `plate` draws the 24 pt rounded plate behind it (action rows, F0063 row 4).
    case symbol(String, plate: Bool)
    case emoji(String)
    case `extension`(String)
    /// A Split View: one cell per pane on a 30 pt plate, side by side or stacked (A0120, CC-13, CC-15).
    case split([CommandBarIcon], vertical: Bool)
}

/// Right side of a row.
public enum CommandBarAccessory: Sendable, Hashable {
    case none
    /// A label and the arrow plate: "Switch to Tab", "Switch to Split View" (A0121), or the
    /// name of the tab's Space when it is not the current one ("Work", F0098 AX).
    case switchTo(String)
    /// Keycaps of an action's shortcut ("⌘", "T"). guess: drawn like the input's keycaps.
    case keys([String])
}

/// One result row as drawn.
public struct CommandBarRow: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: SuggestionKind
    public var title: String
    /// Drawn after " — " in the secondary color. Empty hides it.
    public var subtitle: String
    public var icon: CommandBarIcon
    public var accessory: CommandBarAccessory
    /// A Split View row's pane titles, drawn with a thin rule between them (CC-14). Empty for other rows.
    public var boldRanges: [Range<Int>]
    public var titleParts: [String]

    public init(id: String, kind: SuggestionKind, title: String, subtitle: String = "", icon: CommandBarIcon,
                accessory: CommandBarAccessory = .none, titleParts: [String] = [], boldRanges: [Range<Int>] = []) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.icon = icon; self.accessory = accessory
        self.titleParts = titleParts; self.boldRanges = boldRanges
    }
}

/// Right side of the input row.
public enum CommandBarTrailing: Sendable, Hashable {
    /// The (i) button (F0063).
    case info
    /// "Search <Site> [Tab]" or "Search <Site> [Tab] or [Space]" (F0061, F0040).
    case siteSearchHint(name: String, space: Bool)
    case none
}

/// The input row as drawn.
public struct CommandBarInput: Sendable, Hashable {
    public var placeholder: String
    public var leadingIcon: CommandBarIcon
    /// Site Search scope: the chip before the text.
    public var chip: SiteChip?
    public var trailing: CommandBarTrailing

    /// Site Search has no icon (CC-41); an extension scope includes its 16 pt icon (§3.14).
    public struct SiteChip: Sendable, Hashable {
        public var name: String
        public var extensionID: String?
        public init(name: String, extensionID: String? = nil) { self.name = name; self.extensionID = extensionID }
    }

    public init(placeholder: String, leadingIcon: CommandBarIcon, chip: SiteChip? = nil, trailing: CommandBarTrailing = .info) {
        self.placeholder = placeholder; self.leadingIcon = leadingIcon; self.chip = chip; self.trailing = trailing
    }
}

/// Copy, written for Open. "Search or Enter URL…" is measured (F0063, one ellipsis character).
public enum CommandBarText {
    public static let placeholder = "Search or Enter URL…"
    /// The placeholder inside every scope (CC-18, CC-41: S2 18/0016 shows "Search…" with a Site Search chip).
    public static let scopePlaceholder = "Search…"
    // guess (child): the named extension placeholder follows §3.14’s helper signature.
    public static func siteSearchPlaceholder(_ name: String) -> String { "Search \(name)…" }
    /// Scope chip titles: "Actions" is Arc's (CC-17); "Tabs" is a guess.
    public static let actionsScope = "Actions"
    public static let tabsScope = "Tabs"
    public static let switchToTab = "Switch to Tab"
    public static let switchToSplit = "Switch to Split View"
    public static func searchSite(_ name: String) -> String { "Search \(name)" }
    public static let or = "or"
    public static let tabKey = "Tab"
    public static let spaceKey = "Space"
    /// (i) footer (CC-42, S2 18/0044 AX). "Arc" becomes "Open" (naming rule). Line 1 is the same
    /// text as the Settings notice (features-core §4.5 rule 13).
    public static let privacyTitle = "We talk to your search engine to help us suggest results."
    public static let privacyLearnMorePrefix = "Learn more about your data on Open "
    public static let privacyLinkWord = "here"
    public static let searchSettings = "Search Settings…"
    public static let dismissNotice = "Dismiss"
}

/// Maps `OpenSuggest` rows to drawn rows. Each rule names its evidence.
enum RowPresentation {
    /// - navigate: "<url> — <url>", or "<page title> — <url>" after a history merge (F0040 "google.com — google.com").
    /// - history: "<title> — <url>" (F0048 "The Browser Company — youtube.com/c/…").
    /// - switchToTab: title only, accessory "Switch to Tab", "Switch to Split View", or the Space name (F0063, A0121, F0098).
    /// - search, searchSuggestion: the query only, magnifier (F0052).
    /// - action: title, symbol on a plate, shortcut keycaps (F0063 row 4; keycaps guess).
    /// - Cmd+L: the row for the current URL shows the page title, no subtitle (F0048 row 1).
    static func row(_ s: Suggestion, mode: CommandBarMode, currentSpaceID: SpaceID?, currentURL: URL?, currentTitle: String?) -> CommandBarRow {
        let icon = icon(for: s)
        switch s.kind {
        case .navigate:
            if mode == .editCurrentURL, let currentURL, let u = s.url, TextMatching.urlKey(u) == TextMatching.urlKey(currentURL) {
                return CommandBarRow(id: s.id, kind: s.kind, title: currentTitle ?? URLDisplay.short(u), icon: icon)
            }
            let display = s.url.map(URLDisplay.short) ?? s.title
            let title = s.subtitle.isEmpty ? display : s.subtitle
            return CommandBarRow(id: s.id, kind: s.kind, title: title, subtitle: display, icon: icon)
        case .history:
            return CommandBarRow(id: s.id, kind: s.kind, title: s.title, subtitle: s.url.map(URLDisplay.short) ?? "", icon: icon)
        case .switchToTab:
            if let split = s.split {
                // One row per Split View: pane icons on one plate, pane titles with a rule, no subtitle (CC-12…CC-14).
                let icons = split.paneIcons.enumerated().map { i, hint in paneIcon(hint, url: split.paneURLs[i]) }
                return CommandBarRow(id: s.id, kind: s.kind, title: s.title, icon: .split(icons, vertical: split.isVertical),
                                     accessory: .switchTo(CommandBarText.switchToSplit), titleParts: split.paneTitles)
            }
            let label: String
            if s.tabLocation == .splitPane {
                label = CommandBarText.switchToSplit
            } else if let space = s.spaceID, let current = currentSpaceID, space != current, let name = s.spaceTitle, !name.isEmpty {
                label = name
            } else {
                label = CommandBarText.switchToTab
            }
            return CommandBarRow(id: s.id, kind: s.kind, title: s.title, icon: icon, accessory: .switchTo(label))
        case .search, .searchSuggestion:
            return CommandBarRow(id: s.id, kind: s.kind, title: s.title, icon: icon)
        case .siteSearch:
            // Inside the scope the row is the query alone (S2 18/0018 "bird"); a "yt cats" row outside
            // keeps "— Search <Site>" (guess).
            return CommandBarRow(id: s.id, kind: s.kind, title: s.title, subtitle: s.isWhatYouTyped ? "" : s.subtitle, icon: icon)
        case .calculator:
            // Title is the answer; OpenSuggest's subtitle is "<expression> =". guess layout.
            return CommandBarRow(id: s.id, kind: s.kind, title: s.title, subtitle: s.subtitle, icon: icon)
        case .action:
            let keys = KeycapText.split(s.subtitle)
            return CommandBarRow(id: s.id, kind: s.kind, title: s.title, icon: icon, accessory: keys.isEmpty ? .none : .keys(keys))
        case .extensionAction:
            return CommandBarRow(id: s.id, kind: s.kind, title: s.title, subtitle: s.subtitle, icon: icon,
                                 accessory: s.shortcutKeys.isEmpty ? .none : .keys(s.shortcutKeys))
        case .extensionSuggestion:
            return CommandBarRow(id: s.id, kind: s.kind, title: s.title, subtitle: s.subtitle, icon: icon, boldRanges: s.boldRanges)
        case .siteSearchHint, .extensionKeywordHint:
            return CommandBarRow(id: s.id, kind: s.kind, title: s.title, subtitle: s.subtitle, icon: icon)
        }
    }

    static func paneIcon(_ hint: IconHint?, url: URL) -> CommandBarIcon {
        switch hint {
        case .extension(let id): return .extension(id)
        case .emoji(let e): return .emoji(e)
        case .symbol(let name): return .symbol(name, plate: false)
        case .favicon(let u): return .favicon(u, fallback: "globe")
        case nil: return .favicon(url, fallback: "globe")
        }
    }

    static func icon(for s: Suggestion) -> CommandBarIcon {
        switch s.kind {
        case .extensionAction, .extensionKeywordHint, .extensionSuggestion:
            return s.extensionID.map { .extension($0) } ?? .symbol("puzzlepiece.extension", plate: false)
        case .search, .searchSuggestion, .siteSearchHint: return .symbol("magnifyingglass", plate: false)
        case .calculator: return .symbol("equal", plate: true)
        case .action:
            if case .symbol(let name) = s.icon { return .symbol(name, plate: true) }
            return .symbol("command", plate: true)
        case .siteSearch:
            if case .favicon(let u) = s.icon { return .favicon(u, fallback: "magnifyingglass") }
            return .symbol("magnifyingglass", plate: false)
        case .navigate, .history, .switchToTab:
            switch s.icon {
            case .extension(let id): return .extension(id)
            case .emoji(let e): return .emoji(e)
            case .symbol(let name): return .symbol(name, plate: false)
            case .favicon(let u): return .favicon(u, fallback: "globe")
            case nil: return s.url.map { .favicon($0, fallback: "globe") } ?? .symbol("globe", plate: false)
            }
        }
    }
}

/// URL text for rows: no scheme, no "www.", no trailing slash (F0040 "google.com", F0048 "youtube.com/c/…").
public enum URLDisplay {
    public static func short(_ url: URL) -> String {
        var s = url.absoluteString
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        if s.lowercased().hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// Splits a shortcut display string ("⇧⌘C") into keycaps (["⇧", "⌘", "C"]).
enum KeycapText {
    static let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    static func split(_ shortcut: String) -> [String] {
        let trimmed = shortcut.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var keys: [String] = []
        var rest = Substring(trimmed)
        while let c = rest.first, modifiers.contains(c) {
            keys.append(String(c))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { keys.append(String(rest)) }
        return keys
    }
}
