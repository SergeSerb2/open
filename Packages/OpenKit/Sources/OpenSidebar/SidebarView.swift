import AppKit
import OpenDesign
import OpenModel

/// The sidebar column: toolbar row, URL field, favorites, the Space pager, and
/// the bottom bar. Bound to `OpenModel` through Observation (property changes)
/// and `TreeChange` events (structure). It never changes the model or talks to
/// the engine; every user action goes to `delegate` as a `SidebarIntent`.
///
/// The host window owns the `ThemeBackgroundView` behind the sidebar and the web
/// panel and hands it to `themeBackground`; the sidebar drives its cross-fade on
/// Space switches.
@MainActor
public final class SidebarView: NSView {
    public enum Presentation: Sendable { case anchored, floatingCard }

    public let context: SidebarContext
    public weak var delegate: (any SidebarDelegate)?
    public weak var themeBackground: ThemeBackgroundView? {
        didSet { pager.themeBackground = presentation == .floatingCard ? cardBackground : themeBackground; syncTheme() }
    }
    /// `.floatingCard` is the hover-reveal card shown while the sidebar is hidden:
    /// rounded 10, a light 1 px stroke, its own background (interaction-states §13).
    /// The host draws the card's shadow and moves the card; see `prepareFloatingCard(size:)`.
    public var presentation: Presentation = .anchored { didSet { if presentation != oldValue { applyPresentation() } } }

    let toolbar: ToolbarView
    let urlField: URLFieldView
    let favorites: FavoritesView
    let pager: SpacePagerView
    let bottomBar: BottomBarView
    private var cardBackground: ThemeBackgroundView?
    private var pointerTracking: NSTrackingArea?
    private var observerID: UUID?
    private var loops: [ObservationLoop] = []
    private var modifierMonitor: Any?
    private var modelUpdateDepth = 0
    private var pendingChanges: [TreeChange] = []
    private var pendingRename: ItemID?

    public init(context: SidebarContext) {
        self.context = context
        let menus = SidebarMenus(context: context)
        toolbar = ToolbarView(context: context)
        urlField = URLFieldView(context: context)
        favorites = FavoritesView(context: context)
        pager = SpacePagerView(context: context, menus: menus)
        bottomBar = BottomBarView(context: context, menus: menus)
        super.init(frame: .zero)
        wantsLayer = true
        context.sidebar = self
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window {
                    self.context.isOptionHeld = event.modifierFlags.contains(.option)
                }
            }
            return event
        }
        let renaming = SidebarMenus(context: context, beginRename: { [weak self] id in self?.beginRename(nodeID: id) })
        favorites.menus = renaming
        pager.menus = renaming
        bottomBar.menus = renaming
        for v in [pager, favorites, urlField, toolbar, bottomBar] as [NSView] { addSubview(v) }
        observerID = context.model.addObserver { [weak self] change in self?.apply(change) }
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.context.focusedSpace?.theme
            _ = self.context.systemAppearance
            _ = self.context.isWindowActive
        }) { [weak self] in self?.syncTheme() })
        loops.append(ObservationLoop(read: { [weak self] in
            _ = self?.context.favoritesProfile?.favorites.count
            _ = self?.context.sidebarWidth
        }) { [weak self] in self?.needsLayout = true })
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.context.peekSourceNodeID }) { [weak self] in self?.syncPeekDim() })
        syncTheme()
        syncPeekDim()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        if let observerID { context.model.removeObserver(observerID) }
        loops.forEach { $0.cancel() }
    }

    public override var isFlipped: Bool { true }

    @objc private func windowResignedKey(_ notification: Notification) {
        if let resigned = notification.object as? NSWindow, resigned === window { context.isOptionHeld = false }
    }

    /// Window-level geometry for this sidebar's width.
    public var favoritesHeight: CGFloat {
        FavoritesMetrics.sectionHeight(count: context.favoritesProfile?.favorites.count ?? 0, sidebarWidth: bounds.width)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        if presentation == .floatingCard { cardBackground?.frame = bounds }
        toolbar.frame = CGRect(x: 0, y: 0, width: w, height: URLFieldMetrics.y)
        urlField.frame = CGRect(x: URLFieldMetrics.insetX, y: URLFieldMetrics.y, width: w - 2 * URLFieldMetrics.insetX, height: URLFieldMetrics.height)
        let favTop = FavoritesMetrics.sectionTop
        let favH = favoritesHeight
        favorites.frame = CGRect(x: 0, y: favTop, width: w, height: favH)
        let bottom = h - BottomBarMetrics.height
        pager.frame = CGRect(x: 0, y: favTop + favH, width: w, height: max(0, bottom - favTop - favH))
        bottomBar.frame = CGRect(x: 0, y: bottom, width: w, height: BottomBarMetrics.height)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        pointerTracking = t
    }

    public override func mouseEntered(with event: NSEvent) { context.pointerInSidebar = true }
    public override func mouseExited(with event: NSEvent) { context.pointerInSidebar = false }

    /// A Peek's dim covers the toolbar row and the bottom bar, but not the URL field,
    /// Favorites, or the Space list (F0090 vs F0101: toggle `#A2A3AB` → `#464654`,
    /// row titles unchanged). The window controller dims the background under the sidebar.
    private func syncPeekDim() {
        let dimmed = context.peekSourceNodeID != nil
        toolbar.alphaValue = dimmed ? SidebarRole.peekToolbarOpacity : 1
        bottomBar.alphaValue = dimmed ? SidebarRole.peekBottomBarOpacity : 1
    }

    /// Theme, appearance, and the window background.
    private func syncTheme() {
        guard let space = context.focusedSpace else { return }
        appearance = context.appearance(for: space).nsAppearance
        let bg = presentation == .floatingCard ? cardBackground : themeBackground
        bg?.isWindowActive = context.isWindowActive
        // A theme edit on the focused Space shows at once; Space switches cross-fade in the pager.
        if let bg, bg.targetStyle != context.style(for: space), pager.currentPage?.space === space {
            bg.crossfade(to: context.style(for: space), animated: animatesSidebarChanges)
        }
        for v in [toolbar, urlField, favorites, bottomBar] as [NSView] { v.needsDisplay = true; v.needsLayout = true }
    }

    /// Builds the card's own theme background before the card shows, so its first frame
    /// is never empty: a new `ThemeBackgroundView` only fills its field on the next display
    /// tick. The view is kept (hidden) between reveals; only a theme or size change rebuilds it.
    public func prepareFloatingCard(size: CGSize) {
        let bg: ThemeBackgroundView
        if let cardBackground { bg = cardBackground } else {
            bg = ThemeBackgroundView(frame: CGRect(origin: .zero, size: size))
            bg.isHidden = presentation != .floatingCard
            addSubview(bg, positioned: .below, relativeTo: nil)
            cardBackground = bg
        }
        if let space = context.focusedSpace, bg.targetStyle != context.style(for: space) { bg.style = context.style(for: space) }
        bg.isWindowActive = context.isWindowActive
        bg.frame = CGRect(origin: .zero, size: size)
        bg.layoutSubtreeIfNeeded()
        bg.prepareForSnapshot()
    }

    private func applyPresentation() {
        switch presentation {
        case .anchored:
            cardBackground?.isHidden = true
            layer?.cornerRadius = 0
            layer?.borderWidth = 0
            layer?.masksToBounds = false
            pager.themeBackground = themeBackground
        case .floatingCard:
            if cardBackground == nil { prepareFloatingCard(size: bounds.size) }
            cardBackground?.isHidden = false
            // One rounded clip for everything in the card (theme, rows, the scroll view), with
            // the 1 px stroke drawn by the same layer inside its bounds, above the content.
            layer?.cornerRadius = WindowMetrics.revealCardRadius
            layer?.cornerCurve = .circular  // F0129 corner fit (WindowMetrics.revealCardRadius)
            layer?.masksToBounds = true
            layer?.borderWidth = WindowMetrics.revealCardStrokeWidth
            layer?.borderColor = SidebarColors.border.cgColor(.light)
            pager.themeBackground = cardBackground
        }
        needsLayout = true
    }

    private func apply(_ change: TreeChange) {
        if modelUpdateDepth > 0 { pendingChanges.append(change); return }
        switch change {
        case .insert(let p, _, _), .remove(let p, _, _), .reload(let p):
            if case .favorites = p { favorites.apply(change) }
        case .move(let from, _, let to, _, _):
            if case .favorites = from { favorites.apply(change) } else if case .favorites = to { favorites.apply(change) }
        case .spaceProfileChanged:
            // The focused Space may now show another profile's favorites.
            favorites.reloadProfile()
        }
        pager.apply(change)
        needsLayout = true
    }

    /// Model events remain per-node; only this view's synchronous transaction is
    /// coalesced. This avoids ending and relaying out an outline 50 times.
    func beginModelUpdates() { modelUpdateDepth += 1 }

    func endModelUpdates() {
        modelUpdateDepth -= 1
        guard modelUpdateDepth == 0 else { return }
        let changes = pendingChanges
        pendingChanges = []
        if !changes.isEmpty {
            pager.applyBulk(changes)
            if let profile = context.favoritesProfile {
                favorites.apply(.reload(parent: .favorites(profile.id)))
            }
        }
        if let id = pendingRename {
            pendingRename = nil
            reveal(nodeID: id)
            layoutSubtreeIfNeeded()
            beginRename(nodeID: id)
        }
    }

    func renameInsertedNode(_ id: ItemID) {
        if modelUpdateDepth > 0 { pendingRename = id }
        else { reveal(nodeID: id); layoutSubtreeIfNeeded(); beginRename(nodeID: id) }
    }

    /// App command handlers and confirmed alerts use the same transactional path
    /// as menus and drops, including selection consumption and view batching.
    @discardableResult
    public func perform(_ intent: SidebarIntent) -> Bool { context.send(intent) }

    /// Starts inline rename of a row (or of the Space title when `nodeID` is nil).
    public func beginRename(nodeID: ItemID?) {
        pager.currentPage?.beginRename(nodeID: nodeID)
    }

    /// Scrolls the focused page so the node's row is visible.
    public func reveal(nodeID: ItemID) {
        guard let page = pager.currentPage, let obj = context.model.node(id: nodeID)?.object else { return }
        let row = page.outline.row(forItem: obj)
        if row >= 0 { page.outline.scrollRowToVisible(row) }
    }

    /// Rows of the focused page's outline (for checks and benches).
    public var visibleRowCount: Int { pager.currentPage?.outline.numberOfRows ?? 0 }

    /// Outline row frame of a node in sidebar coordinates (for renders and comparisons).
    public func rowFrame(nodeID: ItemID) -> CGRect? {
        guard let page = pager.currentPage, let obj = context.model.node(id: nodeID)?.object else { return nil }
        let row = page.outline.row(forItem: obj)
        guard row >= 0 else { return nil }
        return convert(page.outline.rect(ofRow: row), from: page.outline)
    }
}

@MainActor
public protocol SidebarDelegate: AnyObject {
    @discardableResult
    func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent) -> Bool
}

/// Counters for checks and benches.
@MainActor
public enum SidebarDiagnostics {
    /// `reloadData` calls on any tab list. One per page build; model changes add none.
    public internal(set) static var fullReloads = 0
    /// Tab row layout passes and Peek badge draws (a badge change must not lay out every row).
    public internal(set) static var tabRowLayouts = 0
    public internal(set) static var peekBadgeDraws = 0
    /// Animate even in windows that are not on screen (frame captures of transitions).
    public static var forceAnimations = false
}

extension NSView {
    /// Structural and Space-switch animations run only in visible windows: an
    /// offscreen window never completes them, and nobody would see them.
    var animatesSidebarChanges: Bool { (window?.isVisible ?? false) || SidebarDiagnostics.forceAnimations }
}

extension SidebarView {
    /// Rows of the focused page in display order, as outline items (model IDs or
    /// sentinel names). Lets checks compare the view with the model.
    public var displayedRows: [String] {
        guard let page = pager.currentPage else { return [] }
        return (0..<page.outline.numberOfRows).map { row in
            let item = page.outline.item(atRow: row)
            if let id = itemID(of: item) { return id.description }
            switch item {
            case is SpacerItem: return "spacer"
            case is DividerItem: return "divider"
            case is NewTabItem: return "newTab"
            default: return "?"
            }
        }
    }

    /// The rendered action button and its actual glyph, for host diagnostics.
    public func tabAction(tabID: ItemID) -> (view: NSView, glyph: Glyph?)? {
        if let index = favorites.tabs.firstIndex(where: { $0.id == tabID }),
           let tile = favorites.collection.item(at: IndexPath(item: index, section: 0))?.view as? FavoriteTileView,
           let button = tile.accessory, !button.isHidden {
            return (button, button.glyphView.glyph)
        }
        guard let page = pager.currentPage, let object = context.model.node(id: tabID)?.object else { return nil }
        let row = page.outline.row(forItem: object)
        guard row >= 0, let cell = page.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView,
              let button = cell.accessory, !button.isHidden else { return nil }
        return (button, button.glyphView.glyph)
    }

    public var displayedSpaceTitle: String? { pager.currentPage?.header.displayedTitle }

    /// Favorite tiles in display order.
    public var displayedFavorites: [ItemID] { favorites.tabs.map(\.id) }

    /// Horizontal offset of the pager strip (model value) and the focused page index.
    public var pagerOffset: CGFloat { -pager.strip.frame.minX }

    /// Context menu titles for a row (or the Space menu for nil).
    public func menuTitles(nodeID: ItemID?) -> [String] {
        guard let page = pager.currentPage else { return [] }
        var point = NSPoint(x: 100, y: page.outline.bounds.maxY + 50)
        if let nodeID, let obj = context.model.node(id: nodeID)?.object {
            let row = page.outline.row(forItem: obj)
            guard row >= 0 else { return [] }
            let r = page.outline.rect(ofRow: row)
            point = NSPoint(x: r.midX, y: r.midY)
        }
        return page.menu(at: point).items.filter { !$0.isAlternate }.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    /// Model destination for a drop at a row boundary of the focused page
    /// (`childIndex` in the root list, or in a folder).
    public func dropDestination(intoFolder folder: ItemID?, childIndex: Int) -> (NodeParent, Int)? {
        guard let page = pager.currentPage else { return nil }
        let item: Any? = folder.flatMap { context.model.node(id: $0)?.object }
        return page.dropDestination(item: item, childIndex: childIndex).map { ($0.parent, $0.index) }
    }

    /// Simulates a two-finger horizontal swipe through the pager's real handler.
    public func simulateSwipe(_ events: [NSEvent]) {
        for e in events { _ = pager.handleScroll(e) }
    }

    public var favoritesCollection: NSCollectionView { favorites.collection }
    public func spaceSwitcher(spaceID: SpaceID) -> NSView? { bottomBar.items[spaceID] }

    /// Resync a profile after a bulk import/reload.
    public func reloadFavorites() {
        guard let profile = context.favoritesProfile else { return }
        apply(.reload(parent: .favorites(profile.id)))
    }

    /// The focused page's tab list (checks and benches).
    public var focusedOutline: NSOutlineView? { pager.currentPage?.outline }

    /// Actual Clear control and its displayed strings, for host diagnostics.
    public var clearControl: (view: NSView, title: String, tooltip: String)? {
        guard let page = pager.currentPage else { return nil }
        let row = page.outline.row(forItem: page.divider)
        guard row >= 0, let cell = page.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? DividerCellView else { return nil }
        return (cell, cell.clearTitle, cell.clearTooltipTitle)
    }

    public func unreadDotFrame(nodeID: ItemID) -> CGRect? {
        guard let cell = cell(nodeID: nodeID), let dot = cell.layer?.sublayers?.first(where: { $0.name == "sidebar-unread-dot" }), dot.opacity > 0 else { return nil }
        return convert(dot.frame, from: cell)
    }

    public func resetAction(tabID: ItemID) -> NSView? {
        guard let cell = cell(nodeID: tabID) as? TabCellView, let button = cell.resetButton, !button.isHidden else { return nil }
        return button
    }

    /// The context menu a row (or empty space, for nil) opens, for checks that run its items.
    public func contextMenu(nodeID: ItemID?) -> NSMenu? {
        guard let page = pager.currentPage else { return nil }
        var point = NSPoint(x: 100, y: page.outline.bounds.maxY + 50)
        if let nodeID, let obj = context.model.node(id: nodeID)?.object {
            let row = page.outline.row(forItem: obj)
            guard row >= 0 else { return nil }
            let r = page.outline.rect(ofRow: row)
            point = NSPoint(x: r.midX, y: r.midY)
        }
        return page.menu(at: point)
    }

    private func cell(nodeID: ItemID) -> SidebarCellView? {
        guard let page = pager.currentPage, let object = context.model.node(id: nodeID)?.object else { return nil }
        let row = page.outline.row(forItem: object)
        guard row >= 0 else { return nil }
        return page.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView
    }

    /// The Peek badge plate on a tab row, in sidebar coordinates, when it shows.
    public func peekBadgeFrame(tabID: ItemID) -> CGRect? {
        guard let cell = cell(nodeID: tabID) as? TabCellView, let badge = cell.peekBadge, !badge.isHidden else { return nil }
        return convert(badge.frame, from: cell)
    }

    /// Visible pane cells of a split row in sidebar coordinates (empty unless selected),
    /// and whether its dividers show.
    public func splitRowCells(splitID: ItemID) -> (cells: [CGRect], dividersVisible: Bool)? {
        guard let cell = cell(nodeID: splitID) as? SplitCellView else { return nil }
        return (cell.visibleCellFrames.map { convert($0, from: cell) }, cell.dividersVisible)
    }

    /// Back, forward, and reload show in the sidebar toolbar.
    public var toolbarNavigationVisible: Bool { !toolbar.back.isHidden && !toolbar.forward.isHidden && !toolbar.reload.isHidden }

    /// Toolbar row and bottom bar opacity (a Peek's dim lowers both).
    public var chromeOpacity: (toolbar: CGFloat, bottomBar: CGFloat) { (toolbar.alphaValue, bottomBar.alphaValue) }

    /// The text the URL field shows: the current page's host or the placeholder.
    public var displayedURLText: String { urlField.displayedText }

    /// Chrome geometry in sidebar coordinates, for host checks: the URL field and its hover
    /// state, and the focused Space header band, its title frame and baseline, and its hover state.
    public var chromeGeometry: SidebarChromeGeometry {
        let header = pager.currentPage?.header
        let title = header?.titleLabel
        return SidebarChromeGeometry(
            urlField: urlField.frame, urlFieldHovered: urlField.isHovered,
            favorites: favorites.frame,
            header: header.map { convert($0.bounds, from: $0) },
            headerTitle: title.map { convert($0.frame, from: header) },
            headerTitleBaseline: title.flatMap { t in header.map { convert(CGPoint(x: 0, y: t.frame.minY + t.baseline), from: $0).y } },
            headerHovered: header?.isHeaderHovered ?? false)
    }
}

/// See `SidebarView.chromeGeometry`.
public struct SidebarChromeGeometry: Sendable, Equatable {
    public var urlField: CGRect
    public var urlFieldHovered: Bool
    public var favorites: CGRect
    public var header: CGRect?
    public var headerTitle: CGRect?
    public var headerTitleBaseline: CGFloat?
    public var headerHovered: Bool
}
