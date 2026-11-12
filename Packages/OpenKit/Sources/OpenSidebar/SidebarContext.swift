import AppKit
import Observation
import OpenDesign
import OpenModel
import OpenMedia
import OpenStore
import OpenExtensionsUI
import OpenLiveData

/// Shared state for every sidebar view: the model, the window it shows, and
/// view-only state that is not part of the model (window active, command bar
/// open, forced states for the renderer).
@MainActor
@Observable
public final class SidebarContext {
    public let model: BrowserModel
    public let windowID: WindowID
    public let incognitoTitle: String?
    public var isIncognito: Bool { incognitoTitle != nil }
    public var extensionsUI: ExtensionsUIContext?
    /// App-wide store injected by the host; each sidebar observes its own stable window list.
    public var media: MediaSourceStore?
    /// Session download progress supplied by the App; no sidebar polling.
    public var downloadBadge: DownloadBadgeState?
    public var displayedTabIDs: Set<ItemID> = []
    /// Render-only forced states, analogous to forcedHover.
    public var forcedMediaHover: SidebarMediaHover?
    public var mediaDrawers: Set<ItemID> = []
    public let selection = SidebarSelection()
    /// Shared across every window; transient and never saved.
    public var livePreviewSpaces: Set<SpaceID> { ThemePreviewRegistry.shared.livePreviewSpaces }
    public func isLiveThemePreview(_ spaceID: SpaceID) -> Bool { livePreviewSpaces.contains(spaceID) }
    /// Preview/banner preferences; the App uses .standard, harnesses use a suite.
    @ObservationIgnored public let previewPreferences: UserDefaults
    @ObservationIgnored private var hoverPreviewStorage: HoverPreviewTracker?
    var existingHoverPreviews: HoverPreviewTracker? { hoverPreviewStorage }
    @ObservationIgnored var previewSuppressions: Set<HoverPreviewTracker.Suppression> = []
    var previewsEnabled: Bool { previewPreferences.object(forKey: "open.general.previewsEnabled") == nil || previewPreferences.bool(forKey: "open.general.previewsEnabled") }
    var canStartHoverPreview: Bool { previewsEnabled && previewSuppressions.isEmpty }
    func suppressPreviews(_ reason: HoverPreviewTracker.Suppression, _ value: Bool) {
        if value { previewSuppressions.insert(reason) } else { previewSuppressions.remove(reason) }
        existingHoverPreviews?.setSuppressed(reason, value)
    }
    public var hoverPreviews: HoverPreviewTracker {
        if let hoverPreviewStorage { return hoverPreviewStorage }
        let tracker = HoverPreviewTracker(context: self); hoverPreviewStorage = tracker; return tracker
    }
    /// Set only after a real auto-archive sweep. Never persisted in the snapshot.
    public var autoArchiveBannerRequested = false
    public let haptics = SidebarHaptics()
    @ObservationIgnored weak var manager: SpaceManagerView?
    var managerSpaceID: SpaceID?
    /// Live Option state, also forced by the offscreen renderer. One window
    /// monitor updates this even while web content is first responder.
    public var isOptionHeld = false
    /// Render-only hover of a navigated pinned row's favicon slot.
    public var forcedFaviconHoverID: ItemID?
    /// Key/main state of the host window. Drives the theme underlay.
    public var isWindowActive: Bool = true
    /// A static embedded preview uses the real rows without structural or fill motion.
    public var animatesChanges = true
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

    /// Theme integration supplies iconOverride here until the model exposes that field.
    /// Shared folder rendering resolves this before Folder.customIcon.
    public var folderIconOverrideProvider: (@MainActor (Folder) -> String?)?

    public var storedFavicons: StoredFaviconCache?

    /// Recents hover card data (live-data §3.4): history rows of a Profile whose URLs contain one
    /// of the given phrases (`RecentsSite.historyPhrases`), newest first. The App sets it for normal windows; nil (incognito, render scenes) keeps the page card.
    @ObservationIgnored public var recentPagesSource: (@MainActor (ProfileID, [String]) async -> [(url: URL, title: String, lastVisit: Date)])?
    /// Automation fixtures only: extra hosts that count as a Recents site. Empty in normal use.
    @ObservationIgnored public var glanceHostAliases: [String: RecentsSite] = [:]
    /// The live-data card a sidebar tab gets on hover, or nil for the page card.
    /// Calendar card data (live-data §3.2, plan NS §2 CAL). The App sets it for normal windows;
    /// nil (incognito, render scenes) keeps the page card on calendar tabs.
    @ObservationIgnored public var calendarGlance: CalendarGlanceSource?
    public func glanceKind(for tab: Tab) -> GlanceKind? {
        guard let kind = GlanceKind.match(url: tab.url, aliases: glanceHostAliases) else { return nil }
        switch kind {
        case .recents: guard recentPagesSource != nil else { return nil }
        case .calendar: guard calendarGlance != nil else { return nil }
        }
        let key = kind.preferenceKey
        return previewPreferences.object(forKey: key) == nil || previewPreferences.bool(forKey: key) ? kind : nil
    }

    /// Optional favicon override (for example an engine-side cache).
    @ObservationIgnored public var faviconProvider: (@MainActor (Tab) -> NSImage?)?
    /// Embedded product artwork can preserve readable ink at reduced scale.
    /// Normal browser sidebars use their exact Space palette.
    @ObservationIgnored public var titleColorTransform: (@MainActor (NSColor) -> NSColor)?
    /// Small embedded scenes can use stronger native glyphs after scaling.
    @ObservationIgnored public var titleFontOverride: NSFont?
    /// Product artwork keeps fetched Favorite icons legible after scaling.
    @ObservationIgnored public var favoriteIconFraction: CGFloat?
    @ObservationIgnored weak var sidebar: SidebarView?

    public init(model: BrowserModel, windowID: WindowID, previewPreferences: UserDefaults = .standard, incognitoTitle: String? = nil) {
        self.model = model
        self.windowID = windowID
        self.incognitoTitle = incognitoTitle
        self.previewPreferences = previewPreferences
        selection.onChange = { [weak self] in
            guard let outline = self?.sidebar?.focusedOutline else { return }
            NSAccessibility.post(element: outline, notification: .selectedRowsChanged)
        }
    }

    public var window: BrowserWindowState? { model.windows.first { $0.id == windowID } }

    public var focusedSpace: Space? {
        if let managerSpaceID { return model.space(id: managerSpaceID) ?? model.spaces.first }
        guard let w = window else { return model.spaces.first }
        return model.space(id: w.focusedSpaceID) ?? model.spaces.first
    }

    /// Live resize presentation. The host commits to the model on drag end.
    public var sidebarWidthOverride: CGFloat?
    public var sidebarWidth: CGFloat { sidebarWidthOverride ?? CGFloat(window?.sidebarWidth ?? Double(WindowMetrics.defaultSidebarWidth)) }

    public func selectedID(in space: SpaceID) -> ItemID? { window?.selectedNodeBySpace[space] }

    public func isPinnedFolder(_ id: ItemID) -> Bool {
        var parent = model.parent(of: id)
        while let current = parent {
            switch current {
            case .folder(let folder): parent = model.parent(of: folder)
            case .spacePinned: return true
            default: return false
            }
        }
        return false
    }

    /// Only the acting window chooses the retained direct row. The model API remains exact.
    public func folderExpansion(folderID: ItemID, expanded: Bool) -> FolderExpansion {
        guard !expanded else { return .expanded }
        guard let folder = model.node(id: folderID)?.folder, folder.isExpanded else { return .collapsed }
        var parent = model.parent(of: folderID)
        while let current = parent {
            switch current {
            case .folder(let id): parent = model.parent(of: id)
            case .spacePinned(let id), .spaceToday(let id):
                guard let selected = selectedID(in: id), model.parent(of: selected) == .folder(folderID),
                      let node = model.node(id: selected), node.folder == nil else { return .collapsed }
                return .peeked(selected)
            case .favorites, .splitPane: return .collapsed
            }
        }
        return .collapsed
    }

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

    /// The window shows the content toolbar: the sidebar drops its URL field and its Back,
    /// Forward and Reload buttons (§4.6.3).
    var isToolbarShown: Bool { window?.showsToolbar == true }

    /// The status button under the URL field ("Translation Available", page-platform §4.7.3).
    /// The App sets it for the focused page; nil hides the button.
    public var urlStatus: URLStatusItem?
    /// The button shows with an item, unless the content toolbar replaces the URL field or a Peek
    /// shows (§4.7.3 "Hidden"). The hover-reveal card is this sidebar, so it shows the button too.
    var urlStatusVisible: Bool { urlStatus != nil && !isToolbarShown && shownPeek == nil }

    /// The page the toolbar and URL field describe: the Peek on screen, else the current tab.
    var hasPage: Bool { shownPeek != nil || currentTab != nil }
    var pageHost: String? {
        if let peek = shownPeek { return Self.fieldText(peek.url, developerModeHosts) }
        return currentTab.map { Self.fieldText($0.url, developerModeHosts) }
    }
    /// Sites in Developer Mode (page-platform §4.10.3): their URL field shows the full URL.
    public var developerModeHosts: Set<String> = []
    /// The URL field text: the host, or for a Developer Mode site the full URL without the scheme
    /// (host, port, path, query).
    static func fieldText(_ url: URL, _ developerHosts: Set<String>) -> String {
        if url.absoluteString == "open://welcome" { return "Welcome to Open" }
        // Arc shows a lock and "Share" for an Easel; Open has no sharing, so it names the page kind.
        if url.scheme?.lowercased() == "open", url.host()?.lowercased() == "easel" { return "Easel" }
        // GUESS — capture pending (Arc 1.172 cannot create Notes): a Note's URL field names the kind.
        if url.scheme?.lowercased() == "open", url.host()?.lowercased() == "note" { return "Note" }
        let scheme = url.scheme?.lowercased()
        let key = scheme == "file" ? "file" : url.host()?.lowercased()
        guard let key, developerHosts.contains(key) else { return URL.displayHost(url) }
        var text = url.absoluteString
        if let r = text.range(of: "://") { text = String(text[r.upperBound...]) }
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        return text
    }
    var pageCanGoBack: Bool { shownPeek?.canGoBack ?? currentTab?.live.canGoBack ?? false }
    var pageCanGoForward: Bool { shownPeek?.canGoForward ?? currentTab?.live.canGoForward ?? false }
    var pageIsLoading: Bool { shownPeek?.isLoading ?? currentTab?.live.isLoading ?? false }

    /// Favorites shown in this window: the focused Space's profile.
    public var favoritesProfile: Profile? {
        guard let space = focusedSpace else { return model.profiles.first }
        return model.profile(id: space.profileID) ?? model.profiles.first
    }

    public func style(for space: Space) -> SpaceThemeStyle {
        isIncognito ? .incognito : StyleCache.style(for: space.theme, system: systemAppearance)
    }

    public func appearance(for space: Space) -> ContentAppearance {
        style(for: space).resolvedAppearance(system: systemAppearance)
    }

    /// Display title of a Space: untitled Spaces read "Space N" (1-based position).
    public func title(of space: Space) -> String {
        incognitoTitle ?? model.displayTitle(for: space)
    }

    @discardableResult
    func send(_ intent: SidebarIntent) -> Bool {
        switch intent {
        case .hoverPreview: break
        default: existingHoverPreviews?.dismiss(immediate: true)
        }
        switch intent {
        case .select, .selectFavorite: selection.clear()
        default: break
        }
        guard manager != nil || sidebar?.delegate != nil else { return false }
        let consumes: Bool
        switch intent {
        case .moveNodes, .moveNodesToSpace, .moveNodesToNewSpace, .archiveNodes, .newFolderFromSelection: consumes = true
        default: consumes = false
        }
        let previousIDs = consumes ? selection.ids : []
        let previousAnchor = consumes ? selection.anchor : nil
        // Consumed selections need not be pruned after every node in a bulk
        // command. A refused delegate restores the unchanged view state.
        if consumes {
            selection.clear()
            sidebar?.pager.currentPage?.syncSelectionIndexes()
            manager?.syncSelectionIndexes()
        }
        let batches: Bool
        switch intent {
        case .moveNodes, .moveNodesToSpace, .moveNodesToNewSpace, .archiveNodes, .newFolderFromSelection,
             .setPinned, .duplicateNodes, .duplicate, .exportSpaceIntoFolder: batches = true
        default: batches = false
        }
        if batches { sidebar?.beginModelUpdates(); manager?.beginModelUpdates() }
        let accepted: Bool
        if let manager { accepted = manager.send(intent) }
        else if let sidebar, let delegate = sidebar.delegate { accepted = delegate.sidebar(sidebar, didRequest: intent) }
        else { accepted = false }
        if batches { sidebar?.endModelUpdates(); manager?.endModelUpdates() }
        if consumes, !accepted {
            selection.select(previousIDs, anchor: previousAnchor)
            sidebar?.pager.currentPage?.syncSelectionIndexes()
            manager?.syncSelectionIndexes()
        } else if accepted, case .archiveNodes = intent {
            let outline = sidebar?.pager.currentPage?.outline ?? focusedSpace.flatMap { manager?.outline(spaceID: $0.id) }
            let visible = Set((0..<(outline?.numberOfRows ?? 0)).compactMap { itemID(of: outline?.item(atRow: $0)) })
            let kept = previousIDs.filter { visible.contains($0) && model.node(id: $0) != nil }
            selection.select(kept, anchor: previousAnchor.flatMap { kept.contains($0) ? $0 : nil } ?? kept.first)
            sidebar?.pager.currentPage?.syncSelectionIndexes()
            manager?.syncSelectionIndexes()
        }
        return accepted
    }

    /// Save outline focus before an asynchronous delete. Call only after a successful
    /// removal; Cancel must leave the original focus and selection unchanged.
    public func keyboardFocusAfterDeletion() -> @MainActor () -> Void {
        let outline = focusedSpace.flatMap { manager?.outline(spaceID: $0.id) } ?? sidebar?.focusedOutline
        guard let outline = outline as? SidebarOutlineView else { return {} }
        return outline.keyboardFocusAfterDeletion()
    }

    /// Existing command IDs only. The App command registry can use this same
    /// path as the focused outline; an empty selection falls through to the App.
    public func isSelectionCommandEnabled(_ commandID: String) -> Bool {
        let ids = selection.ids
        guard !ids.isEmpty else { return false }
        func topLevel(_ id: ItemID) -> Bool {
            guard model.node(id: id) != nil, let parent = model.parent(of: id) else { return false }
            if case .splitPane = parent { return false }
            var ancestor = parent
            while case .folder(let folder) = ancestor {
                guard !ids.contains(folder), let next = model.parent(of: folder) else { return false }
                ancestor = next
            }
            return true
        }
        switch commandID {
        case "pin-unpin-tab":
            return ids.contains { id in
                guard topLevel(id), model.node(id: id)?.folder == nil, let parent = model.parent(of: id) else { return false }
                if case .favorites = parent { return false }
                return true
            }
        case "duplicate-tab": return ids.contains(where: topLevel)
        case "new-folder":
            guard let first = ids.first, topLevel(first), let parent = model.parent(of: first) else { return false }
            if case .favorites = parent { return false }
            return true
        default: return false
        }
    }

    /// Shared by native acceptDrop and automation of the production drop intent.
    @discardableResult
    public func performNodeDrop(ids: [ItemID], to parent: NodeParent, index: Int) -> Bool {
        guard index >= 0, !ids.isEmpty, Set(ids).count == ids.count,
              ids.allSatisfy({ model.node(id: $0) != nil }),
              ids.contains(where: { model.canMoveNode(id: $0, to: parent) }) else { return false }
        return send(.moveNodes(ids: ids, to: parent, index: index))
    }

    public func canMoveNodesToNewSpace(_ ids: [ItemID]) -> Bool {
        guard let profile = focusedSpace?.profileID, !ids.isEmpty, Set(ids).count == ids.count else { return false }
        let selected = Set(ids)
        return ids.allSatisfy { id in
            guard model.node(id: id) != nil, var parent = model.parent(of: id) else { return false }
            if case .splitPane = parent { return false }
            while case .folder(let ancestor) = parent {
                guard !selected.contains(ancestor), let next = model.parent(of: ancestor) else { return false }
                parent = next
            }
            switch parent {
            case .spacePinned(let space), .spaceToday(let space): return model.space(id: space)?.profileID == profile
            case .favorites(let owner): return owner == profile
            case .folder, .splitPane: return false
            }
        }
    }

    @discardableResult
    public func performSelectionCommand(_ commandID: String) -> Bool {
        let ids = selection.ids
        guard isSelectionCommandEnabled(commandID) else { return false }
        switch commandID {
        case "pin-unpin-tab":
            let pinnable = ids.filter { id in
                guard model.node(id: id)?.folder == nil, let parent = model.parent(of: id) else { return false }
                switch parent { case .favorites, .splitPane: return false; default: return true }
            }
            guard !pinnable.isEmpty else { return false }
            return send(.setPinned(ids: ids, pinned: !pinnable.allSatisfy { model.isPinned(tabID: $0) }))
        case "duplicate-tab": return send(.duplicateNodes(ids: ids))
        case "new-folder": return send(.newFolderFromSelection(ids: ids))
        default: return false
        }
    }

    @discardableResult
    func deleteSelection() -> Bool {
        let ids = selection.ids
        guard !ids.isEmpty else { return false }
        if ids.contains(where: { model.node(id: $0)?.folder != nil }) {
            // The App confirms once, archives all IDs in one command, and clears
            // the selection only on confirmation. Cancel preserves the selection.
            return send(.deleteFolders(ids: ids))
        }
        return send(.archiveNodes(ids: ids))
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
    /// The status button under the URL field (page-platform §4.7.3).
    case urlStatus
}

public enum ToolbarButtonKind: Hashable, Sendable { case sidebarToggle, back, forward, reload, more }

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


public enum SidebarMediaHover: Equatable, Sendable {
    case expanded, title(ItemID)
}
