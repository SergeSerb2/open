import AppKit
import Observation
import OpenDesign
import OpenModel

/// Shared state for every sidebar view: the model, the window it shows, and
/// view-only state (hover, window active) that is not part of the model.
@MainActor
@Observable
public final class SidebarContext {
    public let model: BrowserModel
    public let windowID: WindowID
    /// Key/main state of the host window. Drives the theme underlay and glyph tone.
    public var isWindowActive: Bool = true
    /// macOS appearance, used only by Spaces without a stored theme.
    public var systemAppearance: ContentAppearance = .light
    /// Whether a tab has live web content. Pinned tabs with content show "−"
    /// (close and keep pinned) instead of "×". Supplied by the App (engine state).
    @ObservationIgnored public var isTabLoaded: (Tab) -> Bool = { _ in false }
    /// Optional favicon override (for example an engine-side cache).
    @ObservationIgnored public var faviconProvider: ((Tab) -> NSImage?)?
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

    public func style(for space: Space) -> SpaceThemeStyle {
        SpaceThemeStyle(theme: space.theme, system: systemAppearance)
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

/// Re-arming `withObservationTracking` loop. Calls `changed` on the main actor
/// after any property read in `read` changes, coalescing bursts into one call.
@MainActor
final class ObservationLoop {
    private let read: @MainActor () -> Void
    private let changed: @MainActor () -> Void
    private var cancelled = false

    init(read: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        self.read = read
        self.changed = changed
        arm()
    }

    private func arm() {
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.changed()
                self.arm()
            }
        }
    }

    func cancel() { cancelled = true }
}

extension SidebarNode {
    var object: AnyObject {
        switch self {
        case .tab(let t): t
        case .folder(let f): f
        case .split(let s): s
        }
    }
}

/// Model ID of an outline item, if it is a model object.
@MainActor
func itemID(of item: Any?) -> ItemID? {
    switch item {
    case let t as Tab: t.id
    case let f as Folder: f.id
    case let s as Split: s.id
    default: nil
    }
}

extension Tab {
    /// Host shown in the URL field and used for fallback icons.
    var displayHost: String {
        var host = url.host() ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
