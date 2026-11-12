import AppKit
import OpenDesign
import OpenLiveData
import OpenModel

/// Favorites grid: an `NSCollectionView` with a fixed-metric layout
/// (`FavoritesMetrics`), tile states (rest, hover, selected), drag and drop,
/// and animated updates from `TreeChange.favorites` events.
@MainActor
final class FavoritesView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    unowned let context: SidebarContext
    let collection = FavoritesCollectionView()
    private let gridLayout = FavoritesLayout()
    /// Displayed tabs, kept in step with the collection view's items.
    private(set) var tabs: [Tab] = []
    private var profileID: ProfileID?
    private var loop: ObservationLoop?
    var menus: SidebarMenus?

    init(context: SidebarContext) {
        self.context = context
        super.init(frame: .zero)
        wantsLayer = true
        collection.collectionViewLayout = gridLayout
        collection.backgroundColors = [.clear]
        // Selectable so the collection view tracks clicks and drags; the delegate
        // turns a selection into an intent and keeps no selection state.
        collection.isSelectable = true
        collection.owner = self
        collection.dataSource = self
        collection.delegate = self
        collection.register(FavoriteTileItem.self, forItemWithIdentifier: FavoriteTileItem.identifier)
        collection.registerForDraggedTypes([.sidebarNode, .URL, .fileURL])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        addSubview(collection)
        reloadProfile()
        loop = ObservationLoop(read: { [weak self] in _ = self?.context.favoritesProfile?.id }) { [weak self] in
            self?.reloadProfile()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loop?.cancel() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        collection.frame = bounds
        gridLayout.invalidateLayout()
    }

    /// Full reload only when the window shows another profile's favorites.
    func reloadProfile() {
        let profile = context.favoritesProfile
        guard profile?.id != profileID || tabs.count != (profile?.favorites.count ?? 0) else { return }
        profileID = profile?.id
        tabs = profile?.favorites ?? []
        collection.reloadData()
        superview?.needsLayout = true
    }

    /// Applies a model change to the grid with animation.
    func apply(_ change: TreeChange) {
        guard let profile = context.favoritesProfile, profile.id == profileID else { return }
        let new = profile.favorites
        let old = tabs
        guard new.map(\.id) != old.map(\.id) else { return }
        let plan = ListDiff.plan(old: old.map(\.id), new: new.map(\.id))
        let animate = animatesSidebarChanges
        let updates = {
            self.tabs = new
            if !plan.removals.isEmpty { self.collection.deleteItems(at: Set(plan.removals.map { IndexPath(item: $0, section: 0) })) }
            if !plan.insertions.isEmpty { self.collection.insertItems(at: Set(plan.insertions.map { IndexPath(item: $0, section: 0) })) }
            for m in plan.moves { self.collection.moveItem(at: IndexPath(item: m.from, section: 0), to: IndexPath(item: m.to, section: 0)) }
        }
        let isReload: Bool
        if case .reload = change { isReload = true } else { isReload = false }
        let mixesMovesWithCountChanges = !plan.moves.isEmpty && (!plan.removals.isEmpty || !plan.insertions.isEmpty)
        // Bulk reloads have no precise edit sequence. Offscreen collection batches
        // can also retain stale items while AppKit waits for an animation commit.
        if animate && !isReload && plan.isSimple && !mixesMovesWithCountChanges {
            collection.animator().performBatchUpdates(updates)
        } else {
            tabs = new
            collection.reloadData()
        }
        superview?.needsLayout = true
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { tabs.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FavoriteTileItem.identifier, for: indexPath)
        if let tile = item as? FavoriteTileItem { tile.bind(tabs[indexPath.item], context: context, owner: self) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        if let i = indexPaths.first?.item, tabs.indices.contains(i) {
            TooltipController.shared.cancel(for: nil)
            context.send(.selectFavorite(tabID: tabs[i].id))
        }
        return []
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        context.suppressPreviews(.drag, true)
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        context.suppressPreviews(.drag, false); context.haptics.endDrag()
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        SidebarPasteboard.writer(for: tabs[indexPath.item])
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        context.suppressPreviews(.drag, true)
        dropOperation.pointee = .before
        if let ids = SidebarPasteboard.nodeIDs(from: draggingInfo.draggingPasteboard) {
            // Favorites hold tabs only.
            guard let profileID else { return [] }
            let allowed = ids.contains { context.model.canMoveNode(id: $0, to: .favorites(profileID)) }
            if allowed { context.haptics.insertionChanged(parent: .favorites(profileID), index: proposedIndexPath.pointee.item) }
            return allowed ? .move : []
        }
        return SidebarPasteboard.urls(from: draggingInfo.draggingPasteboard).isEmpty ? [] : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        defer { context.suppressPreviews(.drag, false) }
        let index = indexPath.item
        if let ids = SidebarPasteboard.nodeIDs(from: draggingInfo.draggingPasteboard) {
            guard !ids.isEmpty, let profileID else { return false }
            let accepted = context.send(.moveNodes(ids: ids, to: .favorites(profileID), index: index))
            context.haptics.dropped(accepted)
            return accepted
        }
        guard let profileID, let url = SidebarPasteboard.urls(from: draggingInfo.draggingPasteboard).first else { return false }
        return context.send(.openURL(url, in: .favorites(profileID), index: index))
    }
}

/// Transparent collection view with a per-tile context menu.
@MainActor
final class FavoritesCollectionView: NSCollectionView {
    weak var owner: FavoritesView?
    override var isOpaque: Bool { false }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        owner?.context.haptics.endDrag()
        owner?.context.suppressPreviews(.drag, false)
        super.draggingExited(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let owner, let menus = owner.menus, let i = indexPathForItem(at: p)?.item, owner.tabs.indices.contains(i) else { return nil }
        owner.context.selection.clear()
        owner.context.existingHoverPreviews?.dismiss()
        return menus.favorite(owner.tabs[i])
    }
}

/// Grid layout from the measured metrics: inset 8, gaps 8, tile height 47,
/// columns from `FavoritesMetrics.columns`.
@MainActor
final class FavoritesLayout: NSCollectionViewLayout {
    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    private var columns = 3

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        let count = cv.numberOfItems(inSection: 0)
        let width = cv.bounds.width
        columns = FavoritesMetrics.columns(count: count, sidebarWidth: width)
        let m = FavoritesMetrics.self
        let tileW = m.tileWidth(sidebarWidth: width, columns: columns)
        frames = (0..<count).map { i in
            let r = i / columns, c = i % columns
            return CGRect(x: m.inset + CGFloat(c) * (tileW + m.columnGap), y: m.inset + CGFloat(r) * (m.tileHeight + m.rowGap),
                          width: tileW, height: m.tileHeight)
        }
        contentHeight = m.sectionHeight(count: count, sidebarWidth: width)
    }

    override var collectionViewContentSize: NSSize { NSSize(width: collectionView?.bounds.width ?? 0, height: contentHeight) }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        frames.indices.compactMap { i in frames[i].intersects(rect) ? attributes(i) : nil }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    private func attributes(_ i: Int) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
        a.frame = frames[i]
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    override func layoutAttributesForDropTarget(at pointInCollectionView: NSPoint) -> NSCollectionViewLayoutAttributes? {
        guard !frames.isEmpty else {
            let a = NSCollectionViewLayoutAttributes(forInterItemGapBefore: IndexPath(item: 0, section: 0))
            a.frame = CGRect(x: FavoritesMetrics.inset, y: FavoritesMetrics.inset, width: 2, height: FavoritesMetrics.tileHeight)
            return a
        }
        // Nearest gap: before the tile whose center is right of the point in its row.
        var best = frames.count
        for (i, f) in frames.enumerated() where pointInCollectionView.y >= f.minY - FavoritesMetrics.rowGap && pointInCollectionView.y <= f.maxY + FavoritesMetrics.rowGap {
            if pointInCollectionView.x < f.midX { best = i; break }
            best = i + 1
        }
        return layoutAttributesForInterItemGap(before: IndexPath(item: best, section: 0))
    }

    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let a = NSCollectionViewLayoutAttributes(forInterItemGapBefore: indexPath)
        let i = indexPath.item
        let ref = i < frames.count ? frames[i] : (frames.last.map { $0.offsetBy(dx: $0.width + FavoritesMetrics.columnGap, dy: 0) } ?? .zero)
        a.frame = CGRect(x: ref.minX - FavoritesMetrics.columnGap / 2 - 1, y: ref.minY, width: 2, height: ref.height)
        return a
    }
}

/// One favorite tile.
@MainActor
final class FavoriteTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("favoriteTile")
    override func loadView() { view = FavoriteTileView() }
    var tile: FavoriteTileView { view as! FavoriteTileView }

    func bind(_ tab: Tab, context: SidebarContext, owner: FavoritesView) {
        tile.context = context
        tile.tab = tab
        tile.owner = owner
    }
}

@MainActor
final class FavoriteTileView: NSView {
    weak var context: SidebarContext? { didSet { favicon.context = context } }
    weak var tab: Tab? {
        didSet {
            favicon.tab = tab; needsDisplay = true
            // A calendar Favorite starts Live Calendar (LD §4); the App checks access and never prompts.
            if let tab, CalendarProvider.match(url: tab.url) != nil { context?.liveCalendar?.tileAppeared(tab.url) }
        }
    }
    /// Live Calendar countdown ("in 5m", "Now", "3m ago"), shown under the icon.
    private let liveSubtitle = LiveCalendarSubtitleView()
    weak var owner: FavoritesView?
    private let fill = CALayer()
    private let favicon = FaviconView()
    private(set) var accessory: PlateButton?
    private var pointerInside = false { didSet { if pointerInside != oldValue { needsDisplay = true; hoverChanged() } } }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
        addSubview(favicon)
        liveSubtitle.isHidden = true
        addSubview(liveSubtitle)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    private var isHovered: Bool {
        if let forced = context?.forcedHover, let tab { return forced == .favorite(tab.id) }
        return pointerInside
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.cornerRadius = FavoritesMetrics.cornerRadius
        fill.shadowPath = CGPath(roundedRect: bounds, cornerWidth: FavoritesMetrics.cornerRadius, cornerHeight: FavoritesMetrics.cornerRadius, transform: nil)
        CATransaction.commit()
        let s = context?.favoriteIconFraction.map { min(bounds.width,bounds.height)*$0 } ?? FavoritesMetrics.iconFrameSize
        favicon.inkSize = context?.favoriteIconFraction == nil ? SpaceListMetrics.faviconInk:s
        // With a countdown the icon moves up and the plate sits under it. GUESS — capture pending (F2 item 7).
        let iconY = liveSubtitle.isHidden ? (bounds.height - s) / 2 : bounds.height * 0.40 - s / 2
        favicon.frame = backingAlignedRect(CGRect(x: (bounds.width - s) / 2, y: iconY, width: s, height: s), options: .alignAllEdgesNearest)
        let plate = liveSubtitle.fittingSize
        liveSubtitle.frame = backingAlignedRect(CGRect(x: (bounds.width - plate.width) / 2, y: bounds.height - plate.height - 4,
                                                       width: plate.width, height: plate.height), options: .alignAllEdgesNearest)
    }

    override func updateLayer() {
        guard let context, let tab else { return }
        let (selected, hovered, style) = tracked({ () -> (Bool, Bool, SpaceThemeStyle?) in
            let space = context.focusedSpace
            return (space.map { context.selectedID(in: $0.id) == tab.id } ?? false, isHovered, space.map(context.style(for:)))
        }) { [weak self] in self?.needsDisplay = true }
        let appearance = context.focusedSpace.map(context.appearance(for:)) ?? context.systemAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(!context.animatesChanges)
        CATransaction.setAnimationDuration(selected ? Motion.selectionFade : Motion.hoverFade)
        if selected {
            fill.backgroundColor = (style?.selectedFill(appearance) ?? SidebarRole.rowSelected.resolved(appearance)).cgColor
            SelectionShadow.apply(to: fill, appearance: appearance)
        } else {
            fill.backgroundColor = (hovered ? SidebarRole.tileHover : SidebarRole.tileFill).cgColor(appearance)
            fill.shadowOpacity = 0
        }
        CATransaction.commit()
        let live = tracked({ context.liveCalendarTiles[tab.id] }) { [weak self] in self?.needsDisplay = true }
        if liveSubtitle.text != live?.subtitle || liveSubtitle.isHidden != (live == nil) || liveSubtitle.selected != selected {
            liveSubtitle.text = live?.subtitle ?? ""; liveSubtitle.isHidden = live == nil
            liveSubtitle.selected = selected; liveSubtitle.dark = appearance == .dark
            needsLayout = true
        }
        updateAccessory(hovered: hovered)
    }

    private func updateAccessory(hovered: Bool) {
        let unload = tracked({ tab?.live.hasWebContent ?? false }) { [weak self] in self?.needsDisplay = true }
        guard hovered || accessory != nil else { return }
        let button: PlateButton
        if let accessory { button = accessory }
        else {
            button = PlateButton(glyph: .rowClose)
            button.plateRadius = 6
            button.accessibleTitle = { [weak self] in self?.tab?.live.hasWebContent == true ? "Unload tab" : "Archive tab" }
            button.glyphTint = { _ in SidebarRole.rowAccessory.nsColor }
            button.plateColor = { _ in SidebarRole.rowPressed }
            button.action = { [weak self] in
                guard let self, let tab = self.tab else { return }
                self.context?.send(tab.live.hasWebContent ? .unloadTab(tab.id) : .close(nodeID: tab.id))
            }
            addSubview(button)
            accessory = button
        }
        button.glyphView.glyph = unload ? .rowUnload : .rowClose
        button.frame = CGRect(x: bounds.width - 22, y: 1, width: 22, height: 22)
        button.isHidden = !hovered
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }

    private func hoverChanged() {
        guard let tab, let context, let space = context.focusedSpace else { return }
        if pointerInside {
            if context.canStartHoverPreview,
               context.hoverPreviews.hover(nodeID: tab.id, anchorInWindow: convert(bounds, to: nil), owner: self) { return }
            if !context.canStartHoverPreview { context.existingHoverPreviews?.dismiss() }
            TooltipController.shared.schedule(Tooltip(title: tab.displayTitle, placement: .below, style: context.style(for: space)), for: self)
        } else {
            context.existingHoverPreviews?.leaveTarget()
            TooltipController.shared.cancel(for: self)
        }
    }

    /// The action owns its hit target; the rest of the tile hits the tile itself. NSCollectionView
    /// (macOS 27) finds the clicked item by hit-testing item views, so a tile that returns nil
    /// is never selected or dragged. The tile does not handle mouse events: they travel up the
    /// responder chain (tile → item → collection view), which does selection and drags.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let accessory, !accessory.isHidden, accessory.frame.contains(local) { return accessory.hitTest(local) }
        return bounds.contains(local) ? self : nil
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { tab?.displayTitle }
    override func accessibilityPerformPress() -> Bool {
        guard let tab else { return false }
        return context?.send(.selectFavorite(tabID: tab.id)) ?? false
    }
}

/// The Live Calendar countdown plate on a calendar Favorite tile. Colors are Arc's asset values
/// (LD §4, `A:ARC_AppTray`): GCalSubtitleBackgroundSecondary / Selected and GCalSubtitleTextColor*.
/// Size and font: GUESS — capture pending (F2 item 7).
@MainActor
final class LiveCalendarSubtitleView: NSView {
    var text = "" { didSet { needsDisplay = true; setAccessibilityLabel(text) } }
    var selected = false { didSet { needsDisplay = true } }
    var dark = false { didSet { needsDisplay = true } }
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    override var isFlipped: Bool { true }
    override var fittingSize: NSSize {
        let w = (text as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(w) + 10, height: 13)
    }
    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor, ink: NSColor
        if selected {
            fill = NSColor(srgbRed: 0.963, green: 0.976, blue: 0.996, alpha: 0.90)
            ink = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)
        } else if dark {
            fill = NSColor(white: 1, alpha: 0.07); ink = NSColor(srgbRed: 0.87, green: 0.89, blue: 0.92, alpha: 0.70)
        } else {
            fill = NSColor(white: 0, alpha: 0.07); ink = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)
        }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ink]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
