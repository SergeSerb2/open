import AppKit
import Observation
import OpenDesign
import OpenModel

/// Shared state for every sidebar view: the model, the window it shows, and
/// view-only state that is not part of the model (window active, command bar
/// open, forced states for the renderer).
@MainActor
@Observable
public final class SidebarContext {
    public let model: BrowserModel
    public let windowID: WindowID
    /// Key/main state of the host window. Drives the theme underlay.
    public var isWindowActive: Bool = true
    /// macOS appearance. Only Spaces without a stored theme follow it.
    public var systemAppearance: ContentAppearance = .light
    /// True while the command bar is open for a new tab (Cmd+T). The "New Tab"
    /// row then shows the selected fill (F0040, F0063; not with Cmd+L).
    public var isNewTabCommandBarOpen: Bool = false
    /// Forced hover for offscreen rendering and checks. Nil follows the pointer.
    public var forcedHover: SidebarHoverTarget?
    /// The pointer is over the sidebar (or a hover is forced).
    var pointerInSidebar = false
    /// Open Peeks by source tab. The source row shows the Peek page's favicon in a
    /// plate at its right end, also while another tab is selected (F0090, F0101).
    /// Transient: the window controller sets it; the model never stores it.
    /// Each tab has its own observable state, so a change reaches only that row:
    /// a badge on or off lays the row out again, a new URL or favicon only redraws it.
    public var peekBadges: [ItemID: SidebarPeekBadge] {
        get { peekBadgeStates.compactMapValues(\.badge) }
        set {
            for id in Set(peekBadgeStates.keys).union(newValue.keys) {
                let state = peekBadgeState(for: id), badge = newValue[id]
                if state.badge != badge { state.badge = badge }
                if state.isShown != (badge != nil) { state.isShown = badge != nil }
            }
        }
    }
    @ObservationIgnored private var peekBadgeStates: [ItemID: SidebarPeekBadgeState] = [:]
    /// The badge state a row observes (made on first use and kept, so a row that
    /// observes it before a Peek opens still hears about it).
    func peekBadgeState(for id: ItemID) -> SidebarPeekBadgeState {
        if let state = peekBadgeStates[id] { return state }
        let state = SidebarPeekBadgeState(); peekBadgeStates[id] = state; return state
    }
    /// The Peek on screen. Its source row draws a lighter fill, and the URL field
    /// and toolbar follow the Peek page (F0090: Peek host, Peek history).
    public var shownPeek: SidebarShownPeek? {
        didSet { if shownPeek?.sourceNodeID != peekSourceNodeID { peekSourceNodeID = shownPeek?.sourceNodeID } }
    }
    /// The shown Peek's source row alone: row fills and the chrome dim observe this,
    /// so the Peek's URL or loading changes do not reach every row.
    public private(set) var peekSourceNodeID: ItemID?

    /// Optional favicon override (for example an engine-side cache).
    @ObservationIgnored public var faviconProvider: (@MainActor (Tab) -> NSImage?)?
    @ObservationIgnored weak var sidebar: SidebarView?

    public init(model: BrowserModel, windowID: WindowID) {
        self.model = model
        self.windowID = windowID
    }

    public var window: BrowserWindowState? { model.windows.first { $0.id == windowID } }

    public var focusedSpace: Space? {
        guard let w = window else { return model.spaces.first }
        return model.space(id: w.focusedSpaceID) ?? model.spaces.first
    }

    /// Live resize presentation. The host commits to the model on drag end.
    public var sidebarWidthOverride: CGFloat?
    public var sidebarWidth: CGFloat { sidebarWidthOverride ?? CGFloat(window?.sidebarWidth ?? Double(WindowMetrics.defaultSidebarWidth)) }

    public func selectedID(in space: SpaceID) -> ItemID? { window?.selectedNodeBySpace[space] }

    /// The selected tab of the focused Space (a favorite, a tab, or a split's focused pane).
    public var currentTab: Tab? {
        guard let space = focusedSpace, let id = selectedID(in: space.id), let node = model.node(id: id) else { return nil }
        switch node {
        case .tab(let t): return t
        case .split(let s): return s.panes.first { $0.id == s.focusedPaneID } ?? s.panes.first
        case .folder: return nil
        }
    }

    /// The focused Space's selection is a split.
    var isSplitSelected: Bool {
        guard let space = focusedSpace, let id = selectedID(in: space.id) else { return false }
        return model.node(id: id)?.split != nil
    }

    /// The page the toolbar and URL field describe: the Peek on screen, else the current tab.
    var hasPage: Bool { shownPeek != nil || currentTab != nil }
    var pageHost: String? { shownPeek?.displayHost ?? currentTab?.displayHost }
    var pageCanGoBack: Bool { shownPeek?.canGoBack ?? currentTab?.live.canGoBack ?? false }
    var pageCanGoForward: Bool { shownPeek?.canGoForward ?? currentTab?.live.canGoForward ?? false }
    var pageIsLoading: Bool { shownPeek?.isLoading ?? currentTab?.live.isLoading ?? false }

    /// Favorites shown in this window: the focused Space's profile.
    public var favoritesProfile: Profile? {
        guard let space = focusedSpace else { return model.profiles.first }
        return model.profile(id: space.profileID) ?? model.profiles.first
    }

    public func style(for space: Space) -> SpaceThemeStyle {
        StyleCache.style(for: space.theme, system: systemAppearance)
    }

    public func appearance(for space: Space) -> ContentAppearance {
        style(for: space).resolvedAppearance(system: systemAppearance)
    }

    /// Display title of a Space: untitled Spaces read "Space N" (1-based position).
    public func title(of space: Space) -> String {
        model.displayTitle(for: space)
    }

    @discardableResult
    func send(_ intent: SidebarIntent) -> Bool {
        guard let sidebar, let delegate = sidebar.delegate else { return false }
        return delegate.sidebar(sidebar, didRequest: intent)
    }
}

/// The page a source row's Peek badge shows.
public struct SidebarPeekBadge: Equatable, Sendable {
    public var url: URL
    public var faviconPNG: Data?
    public init(url: URL, faviconPNG: Data? = nil) { self.url = url; self.faviconPNG = faviconPNG }
}

/// One tab's Peek badge, observed by that tab's row only.
@MainActor
@Observable
final class SidebarPeekBadgeState {
    /// Read during row layout: the badge takes the close button's slot.
    var isShown = false
    /// Read while the badge draws: the Peek page's favicon and host.
    var badge: SidebarPeekBadge?
}

/// The Peek on screen, as the sidebar shows it.
public struct SidebarShownPeek: Equatable, Sendable {
    /// The source row: the source tab, or the split that holds it.
    public var sourceNodeID: ItemID
    public var url: URL
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isLoading: Bool
    public init(sourceNodeID: ItemID, url: URL, canGoBack: Bool = false, canGoForward: Bool = false, isLoading: Bool = false) {
        self.sourceNodeID = sourceNodeID; self.url = url
        self.canGoBack = canGoBack; self.canGoForward = canGoForward; self.isLoading = isLoading
    }
    var displayHost: String { URL.displayHost(url) }
}

extension URL {
    /// Host shown in the URL field and used for fallback icons.
    static func displayHost(_ url: URL) -> String {
        var host = url.host() ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// What a forced hover points at.
public enum SidebarHoverTarget: Hashable, Sendable {
    case row(ItemID)
    case newTab
    case divider
    case header
    case favorite(ItemID)
    case urlField
    case toolbar(ToolbarButtonKind)
    case home
    case plus
    case switcher(SpaceID)
}

public enum ToolbarButtonKind: Hashable, Sendable { case sidebarToggle, back, forward, reload }

/// Parsing a theme costs a JSON decode; cache by value.
@MainActor
enum StyleCache {
    private static var cache: [Key: SpaceThemeStyle] = [:]
    private static var order: [Key] = []
    private struct Key: Hashable { var theme: SpaceTheme; var system: ContentAppearance }

    static func style(for theme: SpaceTheme, system: ContentAppearance) -> SpaceThemeStyle {
        let key = Key(theme: theme, system: system)
        if let s = cache[key] { return s }
        let s = SpaceThemeStyle(theme: theme, system: system)
        if cache.count >= 256 {
            for old in order.prefix(128) { cache[old] = nil }
            order.removeFirst(128)
        }
        cache[key] = s
        order.append(key)
        return s
    }
}

extension Tab {
    /// Host shown in the URL field and used for fallback icons.
    var displayHost: String { URL.displayHost(url) }

    /// A pinned tab that navigated away from its pinned URL shows a "/" mark.
    var hasLeftPinnedURL: Bool {
        guard let pinned = pinnedURL else { return false }
        return pinned.host() != url.host() || pinned.path() != url.path()
    }
}
