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

    /// Whether a tab has live web content. A loaded pinned tab shows "−" (close
    /// and keep pinned) instead of "×". Supplied by the App (engine state).
    @ObservationIgnored public var isTabLoaded: @MainActor (Tab) -> Bool = { _ in false }
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

    public var sidebarWidth: CGFloat { CGFloat(window?.sidebarWidth ?? Double(WindowMetrics.defaultSidebarWidth)) }

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
        if !space.title.isEmpty { return space.title }
        let index = (model.spaces.firstIndex { $0.id == space.id } ?? 0) + 1
        return "Space \(index)"
    }

    func send(_ intent: SidebarIntent) {
        guard let sidebar else { return }
        sidebar.delegate?.sidebar(sidebar, didRequest: intent)
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
    private struct Key: Hashable { var theme: SpaceTheme; var system: ContentAppearance }

    static func style(for theme: SpaceTheme, system: ContentAppearance) -> SpaceThemeStyle {
        let key = Key(theme: theme, system: system)
        if let s = cache[key] { return s }
        let s = SpaceThemeStyle(theme: theme, system: system)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = s
        return s
    }
}

extension Tab {
    /// Host shown in the URL field and used for fallback icons.
    var displayHost: String {
        var host = url.host() ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// A pinned tab that navigated away from its pinned URL shows a "/" mark.
    var hasLeftPinnedURL: Bool {
        guard let pinned = pinnedURL else { return false }
        return pinned.host() != url.host() || pinned.path() != url.path()
    }
}
