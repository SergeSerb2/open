import AppKit
import OpenExtensionsUI
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
    /// "Translation Available" under the URL field (page-platform §4.7.3). Made the first time the
    /// App sets `context.urlStatus` and kept afterwards: most windows never show it, so it costs
    /// nothing until then.
    private(set) var urlStatusButtonIfMade: URLStatusButton?
    var urlStatusButton: URLStatusButton {
        if let urlStatusButtonIfMade { return urlStatusButtonIfMade }
        let button = URLStatusButton(context: context)
        button.isHidden = true
        addSubview(button, positioned: .above, relativeTo: urlField)
        urlStatusButtonIfMade = button
        return button
    }
    private var urlStatusShown = false
    /// The last push-down animations (position of Favorites and the pager), for checks.
    public private(set) var urlStatusAnimations: [String: CAAnimation] = [:]
    let favorites: FavoritesView
    let pager: SpacePagerView
    /// Last Space slide, read back from the real pager layer when scheduled.
    public var spaceSlideAnimation: CAAnimation? { pager.lastSlideAnimation }
    let bottomBar: BottomBarView
    public let mediaControls: MediaControlsView
    private var creationDraft: SpaceThemeStyle?
    public private(set) var isCreatingSpace = false
    private var cardBackground: ThemeBackgroundView?
    private var pointerTracking: NSTrackingArea?
    private var themePreviewObserver: UUID?
    private var observerID: UUID?
    private var loops: [ObservationLoop] = []
    private var modifierMonitor: Any?
    private var modelUpdateDepth = 0
    private var pendingChanges: [TreeChange] = []
    private var pendingRename: ItemID?
    public var updateBannerState: UpdateBannerState? { didSet { syncBanner() } }
    public var onUpdateBannerAction: (() -> Void)?
    public var onUpdateBannerDismiss: (() -> Void)?
    public private(set) var updateBanner: UpdateBannerView?
    private var activeBanner: NSView? { updateBanner ?? banner }
    private func slotHeight(_ width: CGFloat) -> CGFloat { updateBanner?.height(for: width) ?? banner?.height(for: width) ?? 0 }
    private var banner: SidebarBannerView?
    private var bannerShown = false
    private var bannerGeneration = 0
    private var retiringUpdateBanner: UpdateBannerView?
    private var preferencesObserver: NSObjectProtocol?

    public init(context: SidebarContext) {
        self.context = context
        let menus = SidebarMenus(context: context)
        toolbar = ToolbarView(context: context)
        urlField = URLFieldView(context: context)
        favorites = FavoritesView(context: context)
        pager = SpacePagerView(context: context, menus: menus)
        bottomBar = BottomBarView(context: context, menus: menus)
        mediaControls = MediaControlsView(context: context)
        super.init(frame: .zero)
        wantsLayer = true
        context.sidebar = self
        mediaControls.onUpdateHeight = { [weak self] in self?.needsLayout = true }
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
        for v in [pager, favorites, urlField, toolbar, bottomBar, mediaControls] as [NSView] { addSubview(v) }
        observerID = context.model.addObserver { [weak self] change in self?.apply(change) }
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.context.focusedSpace?.theme
            _ = self.context.systemAppearance; _ = self.context.increaseContrast
            _ = self.context.isWindowActive
        }) { [weak self] in self?.syncTheme() })
        loops.append(ObservationLoop(read: { [weak self] in
            _ = self?.context.favoritesProfile?.favorites.count
            _ = self?.context.sidebarWidth
        }) { [weak self] in self?.needsLayout = true })
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.context.peekSourceNodeID }) { [weak self] in self?.syncPeekDim() })
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.context.autoArchiveBannerRequested
            _ = self.context.focusedSpace?.profileID
            _ = self.context.focusedSpace.flatMap { self.context.model.profile(id: $0.profileID) }?.settings.autoArchiveAfter
        }) { [weak self] in self?.syncBanner() })
        preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncBanner() }
        }
        themePreviewObserver = ThemePreviewRegistry.shared.addObserver { [weak self] id in
            guard let self, self.context.focusedSpace?.id == id else { return }
            self.syncTheme()
            if self.context.isLiveThemePreview(id) {
                (self.presentation == .floatingCard ? self.cardBackground : self.themeBackground)?.prepareForSnapshot()
            }
        }
        syncTheme()
        syncPeekDim()
        syncBanner()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        context.existingHoverPreviews?.dismiss()
        if let observerID { context.model.removeObserver(observerID) }
        if let themePreviewObserver { ThemePreviewRegistry.shared.removeObserver(themePreviewObserver) }
        loops.forEach { $0.cancel() }
    }

    public override var isFlipped: Bool { true }

    @objc private func windowResignedKey(_ notification: Notification) {
        if let resigned = notification.object as? NSWindow, resigned === window { context.isOptionHeld = false }
    }

    /// Window-level geometry for this sidebar's width.
    public var favoritesHeight: CGFloat {
        context.isIncognito ? 0 : FavoritesMetrics.sectionHeight(count: context.favoritesProfile?.favorites.count ?? 0, sidebarWidth: bounds.width)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        if presentation == .floatingCard { cardBackground?.frame = bounds; cardBackground?.fieldFrame = cardFieldFrame }
        toolbar.frame = CGRect(x: 0, y: 0, width: w, height: URLFieldMetrics.y)
        urlField.frame = CGRect(x: URLFieldMetrics.insetX, y: URLFieldMetrics.y, width: w - 2 * URLFieldMetrics.insetX, height: URLFieldMetrics.height)
        // With the content toolbar, the URL field hides and Favorites move up to its place (§4.6.3; layout guess, §9 item 1).
        let toolbarShown = tracked({ context.isToolbarShown }) { [weak self] in self?.needsLayout = true }
        urlField.isHidden = toolbarShown
        // The status button pushes everything under the URL field down 34 pt (§4.7.3).
        let statusShown = tracked({ context.urlStatusVisible }) { [weak self] in self?.needsLayout = true }
        let oldFavorites = favorites.frame, oldPagerFrame = pager.frame
        if statusShown || urlStatusButtonIfMade != nil { urlStatusButton.frame = URLStatusMetrics.frame(sidebarWidth: w) }
        let favTop = toolbarShown ? URLFieldMetrics.y : FavoritesMetrics.sectionTop + (statusShown ? URLStatusMetrics.pushDown : 0)
        favorites.isHidden = isCreatingSpace || context.isIncognito
        let favH = isCreatingSpace ? 0 : favoritesHeight
        favorites.frame = CGRect(x: 0, y: favTop, width: w, height: favH)
        let bottom = h - BottomBarMetrics.height
        let mediaHeight = mediaControls.requiredHeight
        let bannerHeight = bannerShown ? slotHeight(max(0, w - 2 * BannerMetrics.inset)) : 0
        let listBottom = bottom - mediaHeight - (bannerShown ? bannerHeight + 2 * BannerMetrics.inset : 0)
        let oldPager = pager.frame, oldMedia = mediaControls.frame
        let mediaWidthChanged = oldMedia.width > 0 && oldMedia.width != w
        if mediaWidthChanged { removeMediaAnimations(pager.layer); removeMediaAnimations(mediaControls.layer) }
        let pagerStart = MediaAnimationStart(layer: pager.layer, frame: oldPager)
        let mediaStart = MediaAnimationStart(layer: mediaControls.layer, frame: oldMedia)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pager.frame = CGRect(x: 0, y: favTop + favH, width: w, height: max(0, listBottom - favTop - favH))
        mediaControls.frame = CGRect(x: 0, y: bottom - mediaHeight, width: w, height: mediaHeight)
        CATransaction.commit()
        if oldMedia.height != mediaHeight && oldPager != .zero && animatesMediaChanges && mediaControls.hasPendingTransition && !mediaWidthChanged {
            for (view, start) in [(pager as NSView, pagerStart), (mediaControls as NSView, mediaStart)] {
                if SidebarDiagnostics.mediaReducesMotion {
                    if view === mediaControls { mediaControls.crossFadeReducedTransition() }
                } else {
                    let spring = mediaControls.heightTransition == .stack
                    let move = spring ? Motion.miniPlayerStack.animation(keyPath: "position") : CABasicAnimation(keyPath: "position")
                    let resize = spring ? Motion.miniPlayerStack.animation(keyPath: "bounds.size") : CABasicAnimation(keyPath: "bounds.size")
                    move.fromValue = start.position; move.toValue = view.layer?.position
                    resize.fromValue = start.size; resize.toValue = view.bounds.size
                    if !spring {
                        let duration = mediaControls.heightTransition == .drawer ? Motion.miniPlayerResize : Motion.rowStructure
                        for animation in [move, resize] { animation.duration = duration; animation.timingFunction = Motion.easeInOut }
                    }
                    view.layer?.add(move, forKey: "media.containerMove"); view.layer?.add(resize, forKey: "media.containerResize")
                }
            }
        }
        if statusShown != urlStatusShown {
            urlStatusShown = statusShown
            animateURLStatus(shown: statusShown, oldFavorites: oldFavorites, oldPager: oldPagerFrame)
        }
        bottomBar.frame = CGRect(x: 0, y: bottom, width: w, height: BottomBarMetrics.height)
        if bannerShown, let banner = activeBanner {
            let height = slotHeight(max(0, w - 2 * BannerMetrics.inset))
            banner.frame = CGRect(x: BannerMetrics.inset, y: bottom - mediaControls.requiredHeight - BannerMetrics.inset - height,
                                  width: max(0, w - 2 * BannerMetrics.inset), height: height)

        }
    }

    /// Shows or hides the status button. Favorites and the Space list slide with
    /// `Motion.rowStructure` from where they are on screen (an interrupted slide continues from its
    /// presentation layer); the button fades. Reduce Motion: no slide, the button still fades.
    private func animateURLStatus(shown: Bool, oldFavorites: CGRect, oldPager: CGRect) {
        let button = urlStatusButton
        guard animatesSidebarChanges, oldPager != .zero else {
            button.isHidden = !shown; button.alphaValue = 1; return
        }
        if shown { button.isHidden = false; button.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.rowStructure; ctx.timingFunction = Motion.easeInOut
            button.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.urlStatusShown == shown else { return }
                self.urlStatusButton.isHidden = !shown; self.urlStatusButton.alphaValue = 1
            }
        })
        urlStatusAnimations = [:]
        guard !Motion.reducesMotion else { return }
        for (view, old, key) in [(favorites as NSView, oldFavorites, "favorites"), (pager as NSView, oldPager, "pager")] {
            guard let layer = view.layer, old != view.frame else { continue }
            let presentation = layer.presentation()
            let move = CABasicAnimation(keyPath: "position")
            // No presentation layer yet (never drawn): the model position, shifted back by the move.
            move.fromValue = presentation?.position ?? CGPoint(x: layer.position.x, y: layer.position.y - (view.frame.minY - old.minY))
            move.toValue = layer.position
            let resize = CABasicAnimation(keyPath: "bounds.size")
            resize.fromValue = presentation?.bounds.size ?? old.size
            resize.toValue = layer.bounds.size
            for a in [move, resize] { a.duration = Motion.rowStructure; a.timingFunction = Motion.easeInOut }
            layer.add(move, forKey: "urlStatus.move"); layer.add(resize, forKey: "urlStatus.resize")
            urlStatusAnimations[key] = move
        }
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
        mediaControls.alphaValue = dimmed ? SidebarRole.peekBottomBarOpacity : 1
    }

    /// Theme, appearance, and the window background.
    private func syncTheme() {
        if let draft = creationDraft {
            appearance = draft.resolvedAppearance(system: context.systemAppearance).nsAppearance
            let bg = presentation == .floatingCard ? cardBackground : themeBackground
            if bg?.targetStyle != draft { bg?.crossfade(to: draft, animated: false) }
            return
        }
        guard let space = context.focusedSpace else { return }
        appearance = context.appearance(for: space).nsAppearance
        let bg = presentation == .floatingCard ? cardBackground : themeBackground
        bg?.isWindowActive = context.isWindowActive
        // A theme edit on the focused Space shows at once; Space switches cross-fade in the pager.
        if let bg, bg.targetStyle != context.style(for: space), pager.currentPage?.space === space {
            bg.crossfade(to: context.style(for: space), animated: animatesSidebarChanges && !context.isLiveThemePreview(space.id), duration: Motion.themeCrossfade)
        }
        for v in [toolbar, urlField, favorites, bottomBar] as [NSView] { v.needsDisplay = true; v.needsLayout = true }
    }

    /// Builds the card's own theme background before the card shows, so its first frame
    /// is never empty: a new `ThemeBackgroundView` only fills its field on the next display
    /// tick. The view is kept (hidden) between reveals; only a theme or size change rebuilds it.
    /// The window's bounds in the card's coordinates: the card shows the window's own
    /// theme field at its place (`ThemeBackgroundView.fieldFrame`). Nil: the card's size.
    /// True while the card shows and its background draws over the page blur.
    public var cardDrawsPageBlur: Bool { presentation == .floatingCard && cardBackground?.drawsPageBlur == true }
    public var cardFieldFrame: CGRect? {
        didSet { if cardFieldFrame != oldValue, presentation == .floatingCard { cardBackground?.fieldFrame = cardFieldFrame } }
    }

    public func prepareFloatingCard(size: CGSize) {
        let bg: ThemeBackgroundView
        if let cardBackground { bg = cardBackground } else {
            bg = ThemeBackgroundView(frame: CGRect(origin: .zero, size: size))
            // Arc's card is translucent: its tint over the blurred page (WindowMaterial).
            bg.material = .overPage
            bg.isHidden = presentation != .floatingCard
            addSubview(bg, positioned: .below, relativeTo: nil)
            cardBackground = bg
        }
        if let space = context.focusedSpace, bg.targetStyle != context.style(for: space) { bg.style = context.style(for: space) }
        bg.isWindowActive = context.isWindowActive
        bg.frame = CGRect(origin: .zero, size: size)
        bg.fieldFrame = cardFieldFrame
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

    public func beginSpaceCreation(page: NSView) {
        isCreatingSpace = true; context.existingHoverPreviews?.dismiss()
        needsLayout = true; layoutSubtreeIfNeeded(); pager.beginCreation(page: page)
    }
    public func previewSpaceCreation(_ style: SpaceThemeStyle) {
        creationDraft = style; syncTheme()
    }
    public func endSpaceCreation(focus: SpaceID?) {
        isCreatingSpace = false; creationDraft = nil
        pager.endCreation(); needsLayout = true; layoutSubtreeIfNeeded(); syncTheme()
    }
    /// Starts inline rename of a row (or of the Space title when `nodeID` is nil).
    public func beginRename(nodeID: ItemID?) {
        pager.currentPage?.beginRename(nodeID: nodeID)
    }

    /// The same Profile choices as the Space context menu's Set Profile submenu.
    public func profileMenu() -> NSMenu? {
        guard let space = context.focusedSpace else { return nil }
        return SidebarMenus(context: context).profile(space)
    }

    /// The focused page shows its Space header (false for a single unnamed Space unless "Show Space Header").
    public var spaceHeaderVisible: Bool { pager.currentPage?.headerVisible ?? false }

    public var spaceHeaderFrame: NSRect? {
        pager.currentPage.map { convert($0.header.bounds, from: $0.header) }
    }

    /// Icon anchors use AppKit window coordinates, including a floating sidebar.
    public func headerIconFrame(for space: SpaceID) -> CGRect? {
        guard let page = pager.currentPage, page.space.id == space else { return nil }
        return page.header.iconFrameInWindow
    }

    public func rowIconFrame(for node: ItemID) -> CGRect? {
        guard let page = pager.currentPage, let obj = context.model.node(id: node)?.object else { return nil }
        let row = page.outline.row(forItem: obj)
        guard row >= 0, page.outline.rows(in: page.outline.visibleRect).contains(row),
              let cell = page.outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
        if let tab = cell as? TabCellView { return tab.favicon.convert(tab.favicon.bounds, to: nil) }
        if let folder = cell as? FolderCellView { return folder.icon.convert(folder.icon.bounds, to: nil) }
        return nil
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

    /// Actual current-row highlight state, without creating an offscreen row.
    public func isCurrentRow(nodeID: ItemID) -> Bool {
        guard let page = pager.currentPage, let obj = context.model.node(id: nodeID)?.object else { return false }
        let row = page.outline.row(forItem: obj)
        guard row >= 0 else { return false }
        return (page.outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.isCurrent == true
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
    /// Full ↔ compact toolbar swaps (one per crossing of 219 pt).
    public internal(set) static var compactToolbarSwaps = 0
    /// Native incremental outline update calls. One plain main-actor increment per call.
    public internal(set) static var outlineItemUpdates = 0
    public internal(set) static var outlineItemsInserted = 0
    public internal(set) static var outlineItemsRemoved = 0
    public internal(set) static var folderTransitionDuration: TimeInterval = 0
    public internal(set) static var folderTransitionExpanding = false
    /// Enabled only by the CLI bench. No clocks, delays or allocations at rest.
    public static var measuresFolderTransitions = false
    public internal(set) static var folderReconcileSeconds: Double = 0
    public internal(set) static var folderReconcileCPUSeconds: Double = 0
    /// CLI-only 3 ms transition negative control, scoped to its own window.
    public static var folderBenchBusyWindowID: WindowID?
    public internal(set) static var folderReconcileCount = 0
    /// CLI-only phase timing; untouched when transition measurement is disabled.
    public internal(set) static var folderReconcilePhases: [String: Double] = [:]
    public internal(set) static var folderSyncItemsVisited = 0
    public internal(set) static var folderStateRowsConfigured = 0
    public internal(set) static var folderFaviconDraws = 0
    public internal(set) static var folderTitleDraws = 0
    /// Opt-in bounded redraw trace. Never installed by the App.
    public static var folderTrace: (@MainActor (String) -> Void)?
    public internal(set) static var folderBenchCounters: [String: Int] = [:]
    static func countFolderWork(_ key: String) {
        if measuresFolderTransitions { folderBenchCounters[key, default: 0] += 1 }
    }
    static func traceFolderView(_ view: NSView, _ event: String, rect: CGRect? = nil) {
        guard let folderTrace else { return }
        var ancestor: NSView? = view
        while let v = ancestor, !(v is SidebarRowView) { ancestor = v.superview }
        let row = ancestor as? SidebarRowView
        let ordinal = row.flatMap { row in row.page.map { $0.outline.row(for: row) } } ?? -1
        folderTrace("\(type(of: view)) \(event) row=\(ordinal) rect=\(rect.map { NSStringFromRect($0) } ?? "-")")
    }
    /// CLI-only negative control. Nil in the App; no extra work in normal scrolling.
    public static var folderBenchFullRowWindowID: WindowID?
    public internal(set) static var folderRowLayouts = 0
    /// One plain main-actor integer increment per page build or layout callback.
    /// No lock, allocation, or logging occurs at these diagnostic hook sites.
    public internal(set) static var spacePageBuilds = 0
    public internal(set) static var spaceManagerLayouts = 0
    public internal(set) static var spacePageLayouts = 0
    /// Tab row layout passes and Peek badge draws (a badge change must not lay out every row).
    public internal(set) static var tabRowLayouts = 0
    public internal(set) static var peekBadgeDraws = 0
    /// Animate even in windows that are not on screen (frame captures of transitions).
    public static var forceAnimations = false
    public static var mediaIncreaseContrastOverride: Bool?
    public static var mediaIncreasesContrast: Bool { mediaIncreaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
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

    /// A composed product preview animates the actual tile, with the same
    /// collection layout and icon provider as a normal browser window.
    public func favoriteTileView(tabID: ItemID) -> NSView? {
        guard let index = favorites.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        return favorites.collection.item(at: IndexPath(item: index, section: 0))?.view
    }

    /// A finite product demonstration lifts the same native row and cell used
    /// by the outline, without starting a system drag session or taking focus.
    public func liftedRow(tabID: ItemID) -> NSView? {
        guard let page = pager.currentPage, let tab = context.model.tab(id: tabID) else { return nil }
        let row = SidebarRowView(frame: CGRect(x: 0,y: 0,width: bounds.width,height: SpaceListMetrics.rowHeight))
        row.page = page; row.representedItem = tab; row.isCurrent = true
        let cell = TabCellView(frame: row.bounds); cell.page = page; cell.tab = tab
        cell.autoresizingMask = [.width,.height]; row.addSubview(cell)
        row.layer?.shadowColor = NSColor.black.cgColor; row.layer?.shadowOpacity = 0.35
        row.layer?.shadowRadius = 12; row.layer?.shadowOffset = CGSize(width: 0,height: 6)
        row.layoutSubtreeIfNeeded(); return row
    }

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
    /// Native Home control and its real badge layers, for App automation.
    public var homeButton: NSView { bottomBar.home }
    public var downloadBadgeEvidence: [String: Any] { bottomBar.home.evidence }

    public func spaceSwitcher(spaceID: SpaceID) -> NSView? { bottomBar.items[spaceID] }
    /// Delay a switcher's pending spring-load Space switch was scheduled with.
    public func springLoadDelay(spaceID: SpaceID) -> TimeInterval? { bottomBar.items[spaceID]?.pendingSpringLoadDelay }

    /// Resync a profile after a bulk import/reload.
    public func reloadFavorites() {
        guard let profile = context.favoritesProfile else { return }
        apply(.reload(parent: .favorites(profile.id)))
    }

    /// The focused page's tab list (checks and benches).
    public var focusedOutline: NSOutlineView? { pager.currentPage?.outline }

    public func favoriteFrame(tabID: ItemID) -> CGRect? {
        guard let index = favorites.tabs.firstIndex(where: { $0.id == tabID }),
              let attributes = favorites.collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { return nil }
        return convert(attributes.frame, from: favorites.collection)
    }

    /// Actual divider hit region; visibility follows the real hover state.
    public func clearTodayFrame() -> CGRect? {
        guard let control = clearControl, let cell = control.view as? DividerCellView else { return nil }
        return convert(cell.clearHitRect, from: cell)
    }
    public var isClearTodayVisible: Bool { (clearControl?.view as? DividerCellView)?.showsClear == true }

    /// Actual Clear control and its displayed strings, for host diagnostics.
    public var clearControl: (view: NSView, title: String, tooltip: String)? {
        guard let page = pager.currentPage else { return nil }
        let row = page.outline.row(forItem: page.divider)
        guard row >= 0, let cell = page.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? DividerCellView else { return nil }
        return (cell, cell.clearTitle, cell.clearTooltipTitle)
    }

    /// A Live Folder row's state glyph: its tooltip and frame (sidebar coordinates) when shown.
    public func liveFolderStateGlyph(nodeID: ItemID) -> (tooltip: String, frame: CGRect)? {
        guard let cell = cell(nodeID: nodeID) as? FolderCellView else { return nil }
        cell.layoutSubtreeIfNeeded()
        guard let button = cell.liveState, !button.isHidden, let tip = button.toolTip else { return nil }
        return (tip, convert(button.frame, from: cell))
    }
    /// Presses the Live Folder state glyph through its own action.
    @discardableResult
    public func pressLiveFolderStateGlyph(nodeID: ItemID) -> Bool {
        guard let button = (cell(nodeID: nodeID) as? FolderCellView)?.liveState, !button.isHidden else { return false }
        return button.accessibilityPerformPress()
    }

    public func unreadDotFrame(nodeID: ItemID) -> CGRect? {
        guard let cell = cell(nodeID: nodeID), let dot = cell.layer?.sublayers?.first(where: { $0.name == "sidebar-unread-dot" }), dot.opacity > 0 else { return nil }
        return convert(dot.frame, from: cell)
    }

    private func faviconView(tabID: ItemID) -> FaviconView? {
        func find(_ view: NSView) -> FaviconView? {
            if let icon = view as? FaviconView, icon.tab?.id == tabID { return icon }
            for child in view.subviews { if let icon = find(child) { return icon } }
            return nil
        }
        return find(self)
    }
    /// Refresh a caller-owned preview icon after its provider receives an image.
    public func refreshFavicon(tabID: ItemID) { faviconView(tabID: tabID)?.needsDisplay = true }

    /// Actual last row/tile draw receipts; read-only and never used on scroll.
    public func drawnFavicon(tabID: ItemID) -> NSImage? { faviconView(tabID: tabID)?.lastDrawnImage }
    public func drawnFaviconSource(tabID: ItemID) -> String? { faviconView(tabID: tabID)?.lastDrawnSource }

    public func drawnFolderGlyph(nodeID: ItemID) -> String? { (cell(nodeID: nodeID) as? FolderCellView)?.icon.lastDrawnGlyph }

    public func folderIconView(nodeID: ItemID) -> NSView? { (cell(nodeID: nodeID) as? FolderCellView)?.icon }

    public func drawnTitleFrame(tabID: ItemID) -> CGRect? {
        guard let row = cell(nodeID: tabID) as? TabCellView else { return nil }
        return convert(row.title.bounds, from: row.title)
    }

    /// Developer Mode row state (PB3 row 5): the host subtitle, the title baseline, and the dashed outline.
    public func developerRowState(tabID: ItemID) -> [String: Any]? {
        guard let cell = cell(nodeID: tabID) as? TabCellView else { return nil }
        let row = cell.superview as? SidebarRowView
        let subtitle = cell.hostSubtitle.flatMap { $0.isHidden ? nil : $0.text() } ?? ""
        return ["subtitle": subtitle, "titleBaseline": cell.title.baseline, "outline": row?.showsDeveloperOutline ?? false]
    }

    public func drawnTitle(tabID: ItemID) -> String? { (cell(nodeID: tabID) as? TabCellView)?.title.lastDrawnText }

    public func resetAction(tabID: ItemID) -> NSView? {
        guard let cell = cell(nodeID: tabID) as? TabCellView, let button = cell.resetButton, !button.isHidden else { return nil }
        return button
    }

    /// The context menu a row (or empty space, for nil) opens, for checks that run its items.
    /// The Library button's right-click menu ("Show media from:"), as a right click builds it.
    public func libraryButtonContextMenu() -> NSMenu? { bottomBar.home.contextMenuProvider?() }

    public func contextMenu(nodeID: ItemID?) -> NSMenu? {
        // A Favorite tile's menu, as the grid builds it on right-click (Favorites are not outline rows).
        if let nodeID, case .favorites? = context.model.parent(of: nodeID), let tab = context.model.tab(id: nodeID),
           let menus = favorites.menus {
            return menus.favorite(tab)
        }
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
    public var toolbarGeometry: [String: CGRect] {
        ["toggle": toolbar.toggle.frame, "back": toolbar.back.frame, "forward": toolbar.forward.frame, "reload": toolbar.reload.frame,
         "more": toolbar.more.frame]
    }
    /// Visible toolbar buttons by name, in display order.
    public var toolbarVisibleButtons: [String] {
        [("toggle", toolbar.toggle), ("back", toolbar.back), ("forward", toolbar.forward), ("reload", toolbar.reload), ("more", toolbar.more)]
            .filter { !$0.1.isHidden }.map(\.0)
    }
    /// The compact toolbar's "More options" menu, built as a click would build it.
    public func toolbarMoreMenu() -> NSMenu { toolbar.makeMoreMenu() }
    /// The same provider used when the bottom-bar plus button opens its menu.
    public func plusMenu() -> NSMenu? { bottomBar.plus.menuProvider?() }
    /// The URL field's right-click menu, built as a click would build it.
    public func urlFieldMenu() -> NSMenu { SidebarMenus(context: context).urlField() }
    /// The URL field shows (it hides while the window shows the content toolbar).
    public var extensionsStrip: ExtensionStripView? { urlField.extensionStrip }
    public var siteControlsAnchor: NSView { urlField.siteControls }
    public var siteControlsAvailable: Bool {
        get { urlField.siteControlsAvailable }
        set { urlField.siteControlsAvailable = newValue }
    }
    public var siteControlState: SiteControlButtonState {
        get { urlField.siteControlState }
        set { urlField.siteControlState = newValue }
    }
    @discardableResult public func pressSiteControls() -> Bool { urlField.siteControls.accessibilityPerformPress() }
    public func refreshExtensionsLayout() { urlField.needsLayout = true; urlField.layoutSubtreeIfNeeded() }
    public var urlFieldVisible: Bool { !urlField.isHidden }
    /// Diagnostics: the URL field's host label (field points), long-host fade, alignment, first shown control x.
    public var urlFieldHost: (frame: CGRect, faded: Bool, rightAligned: Bool, firstControlX: CGFloat?) {
        urlField.needsLayout = true; urlField.layoutSubtreeIfNeeded(); return urlField.hostState
    }
    /// Diagnostics: the shown URL-field controls (frame in sidebar points) and the accessibility labels the field exposes.
    public var urlFieldControls: (copy: CGRect?, site: CGRect?, accessibilityLabels: [String]) {
        urlField.needsLayout = true; urlField.layoutSubtreeIfNeeded()
        let shown = { (b: NSView) in b.isHiddenOrHasHiddenAncestor ? nil : self.convert(b.bounds, from: b) }
        let children = NSAccessibility.unignoredChildren(from: urlField.accessibilityChildren() ?? [])
        let labels = children.compactMap { ($0 as? NSView)?.accessibilityLabel() }
        return (shown(urlField.copyLink), shown(urlField.siteControls), labels)
    }
    /// The URL field's frame in `view`'s coordinates while it shows (the inline address editor anchors here, plan D3 §2.2).
    /// True when a window point is on a tab or Split View row (the command bar's click-through, LEAD 01:25).
    public func isTabRow(atWindowPoint point: NSPoint) -> Bool {
        guard let superview, !isHiddenOrHasHiddenAncestor else { return false }
        var view = hitTest(superview.convert(point, from: nil))
        while let current = view, current !== self {
            if current is TabCellView || current is SplitCellView { return true }
            view = current.superview
        }
        return false
    }
    public func urlFieldFrame(in view: NSView) -> CGRect? {
        guard !urlField.isHiddenOrHasHiddenAncestor, window != nil, urlField.window === view.window else { return nil }
        return view.convert(urlField.bounds, from: urlField)
    }
    /// The URL field's text right now (the host, or the full URL for a Developer Mode site).
    public var urlFieldText: String { context.pageHost ?? "" }
    /// The status button under the URL field: frame in sidebar coordinates, shown, drawn title.
    public var urlStatusState: (frame: CGRect, shown: Bool, title: String) {
        guard let button = urlStatusButtonIfMade else { return (URLStatusMetrics.frame(sidebarWidth: bounds.width), false, "") }
        return (button.frame, urlStatusShown && !button.isHidden, button.currentTitle)
    }
    /// A click on the status button, as the real button sends it.
    @discardableResult public func pressURLStatus() -> Bool { urlStatusShown ? urlStatusButtonIfMade?.press() ?? false : false }
    /// The status button exists (made on the first offer, page-platform §4.7.3).
    public var urlStatusButtonMade: Bool { urlStatusButtonIfMade != nil }

    /// Toolbar row and bottom bar opacity (a Peek's dim lowers both).
    public var chromeOpacity: (toolbar: CGFloat, bottomBar: CGFloat) { (toolbar.alphaValue, bottomBar.alphaValue) }

    /// The text the URL field shows: the current page's host or the placeholder.
    public var displayedURLText: String { urlField.displayedText }
    /// Read actual private-window view visibility for real-App acceptance.
    public var incognitoChrome: [String: Bool] {
        ["favoritesHidden": favorites.isHidden, "libraryHidden": bottomBar.home.isHidden,
         "switcherEmpty": bottomBar.items.isEmpty, "headerMoreHidden": pager.currentPage?.header.more.isHidden == true,
         "headerCollapseHidden": pager.currentPage?.header.chevron.isHidden == true,
         "eyeglasses": pager.currentPage?.space.icon == .symbol("eyeglasses")]
    }

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


extension SidebarView {
    /// The App sets the request after an actual sweep. Preference checks remain
    /// live so every window hides after the App persists the dismissal.
    private func syncBanner() {
        let preferences = context.previewPreferences
        let eligible = preferences.object(forKey: "open.sidebar.autoArchiveBannerEligible") == nil || preferences.bool(forKey: "open.sidebar.autoArchiveBannerEligible")
        let interval = context.focusedSpace.flatMap { context.model.profile(id: $0.profileID) }?.settings.autoArchiveAfter
        let educationWanted = context.autoArchiveBannerRequested && eligible && !preferences.bool(forKey: "open.sidebar.autoArchiveBannerDismissed") && interval != nil && interval != .never
        if let state = updateBannerState {
            banner?.isHidden = true
            if let updateBanner { updateBanner.state = state; needsLayout = true; return }
            let view = UpdateBannerView(state: state, context: context)
            view.onAction = { [weak self] in self?.onUpdateBannerAction?() }
            view.onDismiss = { [weak self] in self?.onUpdateBannerDismiss?() }
            updateBanner = view; addSubview(view)
        } else if let updateBanner {
            self.updateBanner = nil; retiringUpdateBanner?.removeFromSuperview()
            updateBanner.onAction = nil; updateBanner.onDismiss = nil
            retiringUpdateBanner = updateBanner
            let layer = updateBanner.layer
            let opacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 1
            let translation = layer?.presentation()?.value(forKeyPath: "transform.translation.y") ?? 0
            layer?.removeAllAnimations()
            if animatesSidebarChanges, let layer {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = opacity; fade.toValue = 0; fade.duration = Motion.bannerOut
                let group = CAAnimationGroup(); group.animations = [fade]; group.duration = Motion.bannerOut
                if !Motion.reducesMotion {
                    let slide = CABasicAnimation(keyPath: "transform.translation.y")
                    slide.fromValue = translation; slide.toValue = 12; slide.duration = Motion.bannerOut
                    group.animations?.append(slide)
                }
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self, weak updateBanner] in MainActor.assumeIsolated {
                    updateBanner?.removeFromSuperview()
                    if self?.retiringUpdateBanner === updateBanner { self?.retiringUpdateBanner = nil }
                } }
                layer.opacity = 0; layer.add(group, forKey: "banner")
                CATransaction.commit()
            } else { updateBanner.removeFromSuperview(); retiringUpdateBanner = nil }
            bannerShown = false
            needsLayout = true
        }
        let wanted = updateBannerState != nil || educationWanted
        guard wanted != bannerShown || (updateBanner != nil && updateBanner?.layer?.animation(forKey: "banner") == nil) else { return }
        bannerShown = wanted; bannerGeneration += 1
        let generation = bannerGeneration
        if wanted, updateBanner == nil, banner == nil {
            let view = SidebarBannerView(context: context)
            view.onHeightChange = { [weak self] in self?.needsLayout = true }
            banner = view; addSubview(view)
        }
        guard let banner = activeBanner else { return }
        banner.layer?.removeAllAnimations()
        if wanted {
            banner.isHidden = false
            needsLayout = true; layoutSubtreeIfNeeded()
        } else { needsLayout = true }
        guard animatesSidebarChanges else { banner.isHidden = !wanted; return }
        let duration = wanted ? Motion.bannerIn : Motion.bannerOut
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = wanted ? 0 : 1; opacity.toValue = wanted ? 1 : 0; opacity.duration = duration
        let group = CAAnimationGroup(); group.animations = [opacity]; group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if !Motion.reducesMotion {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = wanted ? 12 : 0; slide.toValue = wanted ? 0 : 12; slide.duration = duration
            group.animations?.append(slide)
        }
        CATransaction.begin()
        if !wanted { CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated {
            guard let self, self.bannerGeneration == generation else { return }; self.banner?.isHidden = true
        } } }
        banner.layer?.add(group, forKey: "banner")
        CATransaction.commit()
    }
    public var autoArchiveBanner: SidebarBannerView? { bannerShown && updateBannerState == nil ? banner : nil }
    public var bannerContentInset: CGFloat { 0 }
    public func refreshAutoArchiveBanner() { syncBanner() }
}
