import AppKit
import OpenDesign
import OpenModel

/// Library content supplied through SettingsActions.makeSpaceManagerView().
/// Use a dedicated SidebarContext for this view. The App injects its intent
/// handler for confirmations and navigation; the default handles model intents.
@MainActor
public final class SpaceManagerView: NSView {
    public let context: SidebarContext
    public var onIntent: (@MainActor (SidebarIntent) -> Bool)?
    public let scrollView = NSScrollView()
    private let strip = SpaceManagerStrip()
    private var columns: [SpaceID: SpaceManagerColumn] = [:]
    private var loop: ObservationLoop?
    private var observer: UUID?
    private var updateDepth = 0
    private var changes: [TreeChange] = []
    private var pendingRename: ItemID?
    private var reorder: Reorder?
    private struct Reorder {
        let id: SpaceID
        let start: CGFloat
        let origin: CGFloat
        var slot: Int
    }

    public init(context: SidebarContext) {
        precondition(context.sidebar == nil && context.manager == nil, "Space Manager needs its own SidebarContext")
        self.context = context
        super.init(frame: .zero)
        wantsLayer = true
        context.manager = self
        context.managerSpaceID = context.focusedSpace?.id
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = strip
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        observer = context.model.addObserver { [weak self] change in self?.apply(change) }
        loop = ObservationLoop(read: { [weak self] in _ = self?.context.model.spaces.map(\.id) }) { [weak self] in self?.syncColumns() }
        syncColumns(force: true)
        for name in [NSWindow.didUpdateNotification, NSWindow.didExposeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit {
        loop?.cancel()
        if let observer { context.model.removeObserver(observer) }
        NotificationCenter.default.removeObserver(self)
    }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        context.systemAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private var visibilityDirty = false
    func deferHiddenUpdates() -> Bool {
        guard !visibleForUpdates else { return false }
        visibilityDirty = true
        return true
    }
    private var visibleForUpdates: Bool { window?.isVisible == true && !isHiddenOrHasHiddenAncestor }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshVisibleColumns() }
    public override func viewDidUnhide() { super.viewDidUnhide(); refreshVisibleColumns() }
    @objc private func windowUpdated(_ note: Notification) {
        if let host = note.object as? NSWindow, host === window { refreshVisibleColumns() }
    }
    private func refreshVisibleColumns() {
        guard visibilityDirty, visibleForUpdates else { return }
        visibilityDirty = false
        syncColumns(force: true)
        for column in columns.values { column.page?.resyncAfterVisibility() }
        if let id = pendingRename { pendingRename = nil; renameInsertedNode(id) }
    }
    private func syncColumns(force: Bool = false) {
        if !force, !visibleForUpdates { visibilityDirty = true; return }
        let live = Set(context.model.spaces.map(\.id))
        let stale = columns.keys.filter { !live.contains($0) }
        for id in stale { columns.removeValue(forKey: id)?.removeFromSuperview() }
        if context.managerSpaceID.map({ !live.contains($0) }) == true { context.managerSpaceID = context.model.spaces.first?.id; context.selection.clear() }
        for space in context.model.spaces where columns[space.id] == nil {
            let column = SpaceManagerColumn(manager: self, space: space)
            columns[space.id] = column
            strip.addSubview(column)
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        SidebarDiagnostics.spaceManagerLayouts += 1
        refreshVisibleColumns()
        scrollView.frame = bounds
        let m = SpaceManagerMetrics.self
        strip.frame.size = CGSize(width: max(bounds.width, m.inset * 2 + CGFloat(columns.count) * m.columnWidth + CGFloat(max(0, columns.count - 1)) * m.gap), height: max(0, scrollView.contentSize.height))
        placeColumns(animated: false)
        buildVisibleColumns()
    }

    private var displayedOrder: [SpaceID] {
        var order = context.model.spaces.map(\.id)
        if let reorder, let index = order.firstIndex(of: reorder.id) {
            order.remove(at: index); order.insert(reorder.id, at: min(reorder.slot, order.count))
        }
        return order
    }

    private func placeColumns(animated: Bool) {
        let m = SpaceManagerMetrics.self
        for (i, id) in displayedOrder.enumerated() {
            guard let column = columns[id], reorder?.id != id else { continue }
            let oldX = column.layer?.presentation()?.frame.minX ?? column.frame.minX
            let frame = CGRect(x: m.inset + CGFloat(i) * m.pitch, y: m.inset, width: m.columnWidth, height: max(0, strip.bounds.height - 2 * m.inset))
            column.frame = frame
            if animated, animatesSidebarChanges {
                let animation = Motion.spaceSwitch.animation(keyPath: "position.x")
                animation.fromValue = oldX; animation.toValue = frame.minX
                column.layer?.add(animation, forKey: "reorder-slot")
            }
        }
    }

    @objc private func scrolled() { buildVisibleColumns() }
    private func buildVisibleColumns() {
        let visible = scrollView.documentVisibleRect
        for column in columns.values where column.frame.intersects(visible) { column.buildContent() }
    }

    func activate(_ space: Space) {
        if context.managerSpaceID != space.id { context.selection.clear(); context.existingHoverPreviews?.dismiss(); context.managerSpaceID = space.id }
    }

    func send(_ intent: SidebarIntent) -> Bool { onIntent?(intent) ?? ModelSidebarActions(context: context).perform(intent) }
    func beginModelUpdates() { updateDepth += 1 }
    func endModelUpdates() {
        updateDepth -= 1
        guard updateDepth == 0 else { return }
        let batch = changes; changes = []
        if visibleForUpdates { for column in columns.values { column.page?.applyBulk(batch) } }
        else { visibilityDirty = true }
        if visibleForUpdates, let id = pendingRename { pendingRename = nil; renameInsertedNode(id) }
    }
    private func apply(_ change: TreeChange) {
        guard visibleForUpdates else { visibilityDirty = true; return }
        if updateDepth > 0 { changes.append(change); return }
        for column in columns.values { column.page?.apply(change) }
    }
    func syncSelectionIndexes() { for column in columns.values { column.page?.syncSelectionIndexes() } }
    func renameInsertedNode(_ id: ItemID) {
        guard visibleForUpdates else { visibilityDirty = true; pendingRename = id; return }
        if updateDepth > 0 { pendingRename = id; return }
        for column in columns.values where (column.page?.outline.row(forItem: context.model.node(id: id)?.object) ?? -1) >= 0 {
            column.page?.layoutSubtreeIfNeeded(); column.page?.beginRename(nodeID: id)
        }
    }

    func trackReorder(space: Space, event: NSEvent) {
        guard let host = window, let column = columns[space.id],
              let startSlot = context.model.spaces.firstIndex(where: { $0.id == space.id }) else { return }
        activate(space)
        host.makeFirstResponder(self)
        let start = strip.convert(event.locationInWindow, from: nil).x
        var began = false
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let next = host.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .keyDown {
                if next.keyCode == 53 { finishReorder(commit: false); return }
                continue
            }
            if next.type == .leftMouseUp { if began { finishReorder(commit: true) }; return }
            let x = strip.convert(next.locationInWindow, from: nil).x
            if !began {
                guard abs(x - start) >= 4 else { continue }
                began = true
                context.suppressPreviews(.drag, true)
                reorder = Reorder(id: space.id, start: start, origin: column.frame.minX, slot: startSlot)
                column.layer?.zPosition = 1
                column.setLifted(true)
                context.haptics.endDrag()
            }
            guard var state = reorder else { continue }
            let m = SpaceManagerMetrics.self
            let origin = state.origin + x - state.start
            column.frame.origin.x = origin
            column.setLifted(true)
            let others = context.model.spaces.map(\.id).filter { $0 != state.id }
            let slot = others.filter { id in
                guard let i = context.model.spaces.firstIndex(where: { $0.id == id }) else { return false }
                return x > m.inset + CGFloat(i) * m.pitch + m.columnWidth / 2
            }.count
            if slot != state.slot {
                let crossed = abs(slot - state.slot)
                state.slot = slot; reorder = state
                for _ in 0..<crossed { context.haptics.perform(.alignment) }
                placeColumns(animated: true)
            }
            SidebarDiagnostics.spaceReorderFrame?()
        }
        finishReorder(commit: false)
    }

    private func finishReorder(commit: Bool) {
        guard let state = reorder else { return }
        reorder = nil
        context.suppressPreviews(.drag, false)
        if let column = columns[state.id] {
            column.layer?.zPosition = 0
            column.setLifted(false)
        }
        if commit, context.model.spaces.firstIndex(where: { $0.id == state.id }) != state.slot {
            _ = context.send(.moveSpace(state.id, toIndex: state.slot))
        }
        context.haptics.endDrag()
        placeColumns(animated: true)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finishReorder(commit: false) } else { super.keyDown(with: event) }
    }

    /// Read-back and input surfaces used by the real Library host/harness.
    public var columnOrder: [SpaceID] { displayedOrder }
    public var builtColumnIDs: Set<SpaceID> { Set(columns.values.filter { $0.page != nil }.map { $0.space.id }) }
    public func columnFrame(spaceID: SpaceID) -> CGRect? { columns[spaceID]?.frame }
    public func controls(spaceID: SpaceID) -> SpaceControlsView? { columns[spaceID]?.controls }
    public func outline(spaceID: SpaceID) -> NSOutlineView? { columns[spaceID]?.buildContent(); return columns[spaceID]?.page?.outline }
}

@MainActor
private final class SpaceManagerStrip: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SpaceManagerColumn: NSView {
    unowned let manager: SpaceManagerView
    let space: Space
    let controls: SpaceControlsView
    private(set) var page: SpacePageView?
    private let content = SpaceManagerStrip()
    private var background: ThemeBackgroundView?
    private var loop: ObservationLoop?
    private var lifted = false
    private let liftShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        return shadow
    }()
    init(manager: SpaceManagerView, space: Space) {
        self.manager = manager; self.space = space
        controls = SpaceControlsView(context: manager.context, space: space)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        layer?.cornerRadius = 10; layer?.cornerCurve = .continuous
        content.wantsLayer = true; content.layer?.cornerRadius = 10; content.layer?.cornerCurve = .continuous; content.layer?.masksToBounds = true
        addSubview(content); content.addSubview(controls)
        controls.onGrab = { [weak manager, space] event in manager?.trackReorder(space: space, event: event) }
        loop = ObservationLoop(read: { [weak self] in _ = self?.space.theme; _ = self?.manager.context.systemAppearance }) { [weak self] in self?.updateTheme() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    func buildContent() {
        guard page == nil, bounds.height > 0 else { return }
        let context = manager.context
        let background = ThemeBackgroundView(frame: bounds)
        background.wantsLayer = true; background.layer?.cornerRadius = 10; background.layer?.masksToBounds = true
        self.background = background
        content.addSubview(background, positioned: .below, relativeTo: controls)
        let menus = SidebarMenus(context: context, beginRename: { [weak self] id in self?.page?.beginRename(nodeID: id) })
        let page = SpacePageView(context: context, space: space, menus: menus)
        page.displaysHeader = false
        self.page = page; content.addSubview(page)
        updateTheme(); needsLayout = true
    }
    func setLifted(_ lifted: Bool) {
        if self.lifted != lifted {
            self.lifted = lifted
            shadow = lifted ? liftShadow : nil
        }
        let scale: CGFloat = lifted ? 1.02 : 1
        guard let layer else { return }
        // Transform the complete column layer, including any AppKit-flattened
        // fill, its rim and all content. Compensate for AppKit's layer anchor.
        let center = CGPoint(x: (0.5 - layer.anchorPoint.x) * bounds.width,
                             y: (0.5 - layer.anchorPoint.y) * bounds.height)
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        layer.transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = lifted ? 0.25 : 0
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        if layer.shadowPath?.boundingBoxOfPath != bounds {
            layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        }
    }
    private func updateTheme() {
        let context = manager.context
        background?.style = context.style(for: space)
        let appearance = context.appearance(for: space)
        self.appearance = appearance.nsAppearance
        content.layer?.borderWidth = appearance == .dark ? 1 : 0
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
    }
    override func layout() {
        super.layout()
        content.frame = bounds
        background?.frame = bounds
        controls.frame = CGRect(x: 0, y: 0, width: bounds.width, height: SpaceManagerMetrics.headerHeight)
        page?.frame = CGRect(x: 0, y: SpaceManagerMetrics.headerHeight, width: bounds.width, height: max(0, bounds.height - SpaceManagerMetrics.headerHeight))
    }
}

@MainActor extension SidebarDiagnostics {
    /// Optional capture of the real native reorder presentation, used by the harness.
    public static var spaceReorderFrame: (@MainActor () -> Void)?
}
