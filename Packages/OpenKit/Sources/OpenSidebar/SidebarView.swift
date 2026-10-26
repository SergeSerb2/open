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
    public var presentation: Presentation = .anchored { didSet { applyPresentation() } }

    let toolbar: ToolbarView
    let urlField: URLFieldView
    let favorites: FavoritesView
    let pager: SpacePagerView
    let bottomBar: BottomBarView
    private var cardBackground: ThemeBackgroundView?
    private var observerID: UUID?
    private var loops: [ObservationLoop] = []

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
        syncTheme()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            if let observerID { context.model.removeObserver(observerID) }
            loops.forEach { $0.cancel() }
        }
    }

    public override var isFlipped: Bool { true }

    /// Window-level geometry for this sidebar's width.
    public var favoritesHeight: CGFloat {
        FavoritesMetrics.sectionHeight(count: context.favoritesProfile?.favorites.count ?? 0, sidebarWidth: bounds.width)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        cardBackground?.frame = bounds
        toolbar.frame = CGRect(x: 0, y: 0, width: w, height: URLFieldMetrics.y)
        urlField.frame = CGRect(x: URLFieldMetrics.insetX, y: URLFieldMetrics.y, width: w - 2 * URLFieldMetrics.insetX, height: URLFieldMetrics.height)
        let favTop = FavoritesMetrics.sectionTop
        let favH = favoritesHeight
        favorites.frame = CGRect(x: 0, y: favTop, width: w, height: favH)
        let bottom = h - BottomBarMetrics.height
        pager.frame = CGRect(x: 0, y: favTop + favH, width: w, height: max(0, bottom - favTop - favH))
        bottomBar.frame = CGRect(x: 0, y: bottom, width: w, height: BottomBarMetrics.height)
    }

    /// Theme, appearance, and the window background.
    private func syncTheme() {
        guard let space = context.focusedSpace else { return }
        appearance = context.appearance(for: space).nsAppearance
        let bg = presentation == .floatingCard ? cardBackground : themeBackground
        bg?.isWindowActive = context.isWindowActive
        // A theme edit on the focused Space shows at once; Space switches cross-fade in the pager.
        if bg?.style != context.style(for: space), pager.currentPage?.space === space {
            bg?.crossfade(to: context.style(for: space), animated: window != nil)
        }
        for v in [toolbar, urlField, favorites, bottomBar] as [NSView] { v.needsDisplay = true; v.needsLayout = true }
    }

    private func applyPresentation() {
        switch presentation {
        case .anchored:
            cardBackground?.removeFromSuperview()
            cardBackground = nil
            layer?.cornerRadius = 0
            layer?.borderWidth = 0
            layer?.masksToBounds = false
            pager.themeBackground = themeBackground
        case .floatingCard:
            let bg = cardBackground ?? ThemeBackgroundView(frame: bounds)
            if let space = context.focusedSpace { bg.style = context.style(for: space) }
            bg.isWindowActive = context.isWindowActive
            addSubview(bg, positioned: .below, relativeTo: nil)
            cardBackground = bg
            layer?.cornerRadius = WindowMetrics.revealCardRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            layer?.borderColor = SidebarColors.border.cgColor(.light)
            pager.themeBackground = bg
        }
        needsLayout = true
    }

    private func apply(_ change: TreeChange) {
        switch change {
        case .insert(let p, _, _), .remove(let p, _, _), .reload(let p):
            if case .favorites = p { favorites.apply(change) }
        case .move(let from, _, let to, _, _):
            if case .favorites = from { favorites.apply(change) } else if case .favorites = to { favorites.apply(change) }
        }
        pager.apply(change)
        needsLayout = true
    }

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
    func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent)
}
