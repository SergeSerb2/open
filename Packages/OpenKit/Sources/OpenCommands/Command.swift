import Foundation

/// Where a command can fire. Wider scopes contain narrower ones for conflict checks:
/// global contains every scope; window contains sidebar, command bar, and web scopes.
public enum CommandScope: String, Sendable, Codable, CaseIterable {
    case global
    case window
    case sidebarFocused = "sidebar-focused"
    case commandBar = "command-bar"
    case webContent = "web-content"

    /// True when a shortcut bound in `self` can collide with one bound in `other`.
    public func overlaps(_ other: CommandScope) -> Bool {
        if self == other { return true }
        if self == .global || other == .global { return true }
        if self == .window || other == .window { return true }
        return false
    }
}

/// Who wins when a browser shortcut and a web page shortcut use the same keys.
/// Mirrors Arc strings: "When shortcuts conflict, Arc wins.",
/// "When shortcuts conflict, the website wins.", and the double-press rule.
public enum ShortcutPriority: String, Sendable, Codable, CaseIterable {
    /// Browser command runs at once; the page never sees the keys.
    case browserFirst = "browser"
    /// Page runs at once; the browser command does not run.
    case siteFirst = "site"
    /// First press goes to the page. A second press of the same keys within
    /// `KeyboardRouter.doublePressInterval` runs the browser command.
    case siteThenBrowserOnDoublePress = "site-then-browser"
}

/// One browser command. The registry in `CommandRegistry` is the single source
/// of truth for menus, key bindings, routing, and the command bar adapter.
public struct CommandDefinition: Sendable, Hashable, Identifiable {
    /// Stable id, kebab-case. Never rename a shipped id; overrides key on it.
    public var id: String
    public var title: String
    /// Primary menu, for example `["Edit", "Find"]`. Nil for code-only commands.
    public var menuPath: [String]?
    /// Every default key equivalent. The first one is the visible menu shortcut;
    /// the rest are alternate carriers (Go Back is Cmd+[ and Cmd+Left).
    public var defaultShortcuts: [KeyboardShortcut]
    public var scope: CommandScope
    /// True when Settings > Shortcuts may remap this command (Arc `arcKeyBindingID` set).
    public var isCustomizable: Bool
    /// Key the dispatcher checks to enable or disable the item. See `EnabledKey`.
    public var enabledKey: String
    /// Extra search phrases for the command bar (Arc TypeTravel triggers).
    public var aliases: [String]
    /// Out-of-scope Arc command kept only so its keys stay reserved.
    /// Reserved commands never appear in menus and no other command may take their keys.
    public var isReserved: Bool
    /// Default winner when this shortcut also exists on a web page.
    public var priority: ShortcutPriority

    public init(
        id: String,
        title: String,
        menuPath: [String]? = nil,
        defaultShortcuts: [KeyboardShortcut] = [],
        scope: CommandScope = .window,
        isCustomizable: Bool = false,
        enabledKey: String = EnabledKey.always,
        aliases: [String] = [],
        isReserved: Bool = false,
        priority: ShortcutPriority = .browserFirst
    ) {
        self.id = id
        self.title = title
        self.menuPath = menuPath
        self.defaultShortcuts = defaultShortcuts
        self.scope = scope
        self.isCustomizable = isCustomizable
        self.enabledKey = enabledKey
        self.aliases = aliases
        self.isReserved = isReserved
        self.priority = priority
    }

    public var menuPathDisplay: String {
        guard let menuPath, !menuPath.isEmpty else { return "—" }
        return menuPath.joined(separator: " > ")
    }

    public var shortcutDisplay: String {
        defaultShortcuts.map(\.display).joined(separator: ", ")
    }
}

/// Enabled-state keys. The app's `CommandDispatcher` answers these.
public enum EnabledKey {
    public static let always = "always"
    public static let currentTab = "hasCurrentTab"
    public static let currentTabPinned = "currentTabPinned"
    public static let currentTabInToday = "currentTabInToday"
    public static let currentTabHasPinnedURL = "currentTabHasPinnedURL"
    public static let currentTabIsFavorite = "currentTabIsFavorite"
    public static let currentTabNotFavorite = "currentTabNotFavorite"
    public static let currentTabInSplit = "currentTabInSplit"
    public static let multipleSpaces = "hasMultipleSpaces"
    public static let canGoBack = "canGoBack"
    public static let canGoForward = "canGoForward"
    public static let textField = "textFieldFocused"
    public static let hasHistory = "hasHistory"
    /// A live http(s), file, or data page in the focused host (page-platform §7.1: capture, Clear Cookies).
    public static let webPage = "hasWebPage"
    /// Per-site data clearing exists (Site Control E2) and the page is http(s) (Clear Cache and Refresh).
    public static let siteDataClearAvailable = "siteDataClearAvailable"
    /// A trace recording runs (Help ▸ Troubleshooting ▸ Cancel Trace), or none does (Record Trace).
    public static let isTracing = "isTracing"
    public static let notTracing = "notTracing"
}
