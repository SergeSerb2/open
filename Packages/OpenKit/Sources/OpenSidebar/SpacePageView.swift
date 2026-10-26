import AppKit
import OpenDesign
import OpenModel

/// One Space: the header and the tab list (`NSOutlineView`). Root rows are
/// `[spacer] + pinned + [divider if Today is not empty] + [New Tab] + Today`.
///
/// The outline never reloads in full after the first load. `TreeChange` events
/// become diffed insert, remove, and move calls on cached child lists, so rows
/// animate and only touched rows get views. Property changes (titles, icons,
/// audio) redraw the affected cells through Observation tracking.
@MainActor
final class SpacePageView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    unowned let context: SidebarContext
    let space: Space
    let header: SpaceHeaderView
    let scroll = PageScrollView()
    let outline = SidebarOutlineView()
    let spacer = SpacerItem(), divider = DividerItem(), newTab = NewTabItem()
    var menus: SidebarMenus

    /// Child lists as the outline currently knows them.
    private var rootItems: [AnyObject] = []
    private var folderChildren: [ObjectIdentifier: [AnyObject]] = [:]
    private var loops: [ObservationLoop] = []
    private var hoveredItem: AnyObject? { didSet { if hoveredItem !== oldValue { updateRowStates(animated: true) } } }
    private var tracking: NSTrackingArea?

    init(context: SidebarContext, space: Space, menus: SidebarMenus) {
        self.context = context
        self.space = space
        self.menus = menus
        header = SpaceHeaderView(context: context, space: space)
        super.init(frame: .zero)
        wantsLayer = true
        header.page = self
        addSubview(header)
        configureOutline()
        scroll.documentView = outline
        addSubview(scroll)
        applyAppearance()
        rootItems = computeRoot()
        outline.reloadData()
        syncExpansion(animated: false)
        observe()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var style: SpaceThemeStyle { context.style(for: space) }
    var contentAppearanceForSpace: ContentAppearance { context.appearance(for: space) }

    private func configureOutline() {
        let column = NSTableColumn(identifier: .init("Tabs"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0
        outline.indentationMarkerFollowsCell = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.usesAutomaticRowHeights = false
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.allowsEmptySelection = true
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.page = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.registerForDraggedTypes([.sidebarNode, .URL, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .gap
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.verticalScrollElasticity = .allowed
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    /// Each page draws in its own Space's content appearance.
    func applyAppearance() {
        appearance = contentAppearanceForSpace.nsAppearance
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        header.frame = CGRect(x: 0, y: 0, width: w, height: SpaceListMetrics.headerHeight)
        scroll.frame = CGRect(x: 0, y: SpaceListMetrics.headerHeight, width: w, height: max(0, bounds.height - SpaceListMetrics.headerHeight))
        if let column = outline.tableColumns.first, column.width != w { column.width = w }
    }

    // MARK: Observation

    private func observe() {
        // Selection, command bar state, forced hover: update row fills.
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.context.selectedID(in: self.space.id)
            _ = self.context.isNewTabCommandBarOpen
            _ = self.context.forcedHover
        }) { [weak self] in self?.updateRowStates(animated: true) })
        // Folder expansion and the pinned-collapsed flag. Reading the child lists
        // too re-arms the loop after structural changes, so new folders are tracked.
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.space.isPinnedCollapsed
            _ = self.space.pinned.count
            _ = self.space.today.count
            self.forEachLoadedFolder { _ = $0.isExpanded; _ = $0.children.count }
        }) { [weak self] in
            guard let self else { return }
            self.syncRoot()
            self.syncExpansion(animated: self.animatesSidebarChanges)
        })
        // Theme and appearance.
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.space.theme
            _ = self.context.systemAppearance
        }) { [weak self] in
            guard let self else { return }
            self.applyAppearance()
            self.outline.enumerateAvailableRowViews { row, _ in
                (row as? SidebarRowView)?.updateFill(animated: false)
                row.subviews.forEach { $0.needsDisplay = true; $0.subviews.forEach { $0.needsDisplay = true } }
            }
            self.header.needsDisplay = true
        })
    }

    isolated deinit {
        loops.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    private func forEachLoadedFolder(_ body: (Folder) -> Void) {
        func walk(_ items: [AnyObject]) {
            for case let f as Folder in items {
                body(f)
                if let kids = folderChildren[ObjectIdentifier(f)] { walk(kids) }
            }
        }
        walk(rootItems)
    }

    // MARK: Model changes

    func computeRoot() -> [AnyObject] {
        var r: [AnyObject] = [spacer]
        if !space.isPinnedCollapsed { r += space.pinned.map(\.object) }
        if !space.today.isEmpty { r.append(divider) }
        r.append(newTab)
        r += space.today.map(\.object)
        return r
    }

    /// True when the change touched this page.
    @discardableResult
    func apply(_ change: TreeChange) -> Bool {
        switch change {
        case .insert(let p, _, _), .remove(let p, _, _), .reload(let p):
            return sync(parent: p)
        case .move(let from, _, let to, _, let nodeID):
            if from != to, let src = displayedItem(for: from), let dst = displayedItem(for: to),
               src.isFolder || dst.isFolder, moveDirect(nodeID: nodeID, from: src, to: dst) {
                return true
            }
            let a = sync(parent: from)
            let b = sync(parent: to)
            return a || b
        case .spaceProfileChanged:
            // Profile changes do not change this page's rows.
            return false
        }
    }

    private enum Displayed {
        case root
        case folder(Folder)
        var isFolder: Bool { if case .folder = self { return true }; return false }
    }

    private func displayedItem(for parent: NodeParent) -> Displayed? {
        switch parent {
        case .spacePinned(let s), .spaceToday(let s): return s == space.id ? .root : nil
        case .folder(let id):
            guard let f = context.model.node(id: id)?.folder, folderChildren[ObjectIdentifier(f)] != nil else { return nil }
            return .folder(f)
        case .favorites, .splitPane: return nil
        }
    }

    @discardableResult
    private func sync(parent: NodeParent) -> Bool {
        switch displayedItem(for: parent) {
        case .root: syncRoot(); return true
        case .folder(let f): syncFolder(f); return true
        case nil:
            if case .splitPane = parent { return false }
            return false
        }
    }

    /// Cross-parent move between two displayed lists (one of them a folder):
    /// one animated `moveItem` keeps the row's view and expansion state.
    private func moveDirect(nodeID: ItemID, from: Displayed, to: Displayed) -> Bool {
        guard let node = context.model.node(id: nodeID) else { return false }
        let obj = node.object
        let srcList = list(for: from), dstNew = target(for: to)
        guard let fromIndex = srcList.firstIndex(where: { $0 === obj }), let toIndex = dstNew.firstIndex(where: { $0 === obj }) else { return false }
        // Only valid when the destination list differs from its cache by exactly this node.
        var expected = list(for: to)
        expected.insert(obj, at: min(toIndex, expected.count))
        guard expected.map(ObjectIdentifier.init) == dstNew.map(ObjectIdentifier.init) else { return false }
        var src = srcList
        src.remove(at: fromIndex)
        setList(src, for: from)
        setList(dstNew, for: to)
        outline.beginUpdates()
        outline.moveItem(at: fromIndex, inParent: parentItem(from), to: toIndex, inParent: parentItem(to))
        outline.endUpdates()
        updateRowStates(animated: false)
        return true
    }

    private func list(for d: Displayed) -> [AnyObject] {
        switch d { case .root: rootItems; case .folder(let f): folderChildren[ObjectIdentifier(f)] ?? [] }
    }

    private func target(for d: Displayed) -> [AnyObject] {
        switch d { case .root: computeRoot(); case .folder(let f): f.children.map(\.object) }
    }

    private func setList(_ l: [AnyObject], for d: Displayed) {
        switch d { case .root: rootItems = l; case .folder(let f): folderChildren[ObjectIdentifier(f)] = l }
    }

    private func parentItem(_ d: Displayed) -> Any? {
        switch d { case .root: nil; case .folder(let f): f }
    }

    func syncRoot() { apply(target: computeRoot(), in: .root) }

    private func syncFolder(_ folder: Folder) {
        guard folderChildren[ObjectIdentifier(folder)] != nil else { return }
        apply(target: folder.children.map(\.object), in: .folder(folder))
    }

    /// Edits a cached child list in place (no copy of a 1,000-item list per step).
    private func mutate(_ d: Displayed, _ body: (inout [AnyObject]) -> Void) {
        switch d {
        case .root: body(&rootItems)
        case .folder(let f): body(&folderChildren[ObjectIdentifier(f), default: []])
        }
    }

    /// Applies the sequential diff between the cached list and `new` to the
    /// outline. The cache changes step by step with the outline, so data source
    /// calls during an update always see the outline's current state.
    private func apply(target new: [AnyObject], in d: Displayed) {
        let steps = ListDiff.steps(old: list(for: d).map(ObjectIdentifier.init), new: new.map(ObjectIdentifier.init))
        guard !steps.isEmpty else { return }
        let animate = animatesSidebarChanges
        let parent = parentItem(d)
        outline.beginUpdates()
        for step in steps {
            switch step {
            case .remove(let i):
                var removed: AnyObject?
                mutate(d) { removed = $0.remove(at: i) }
                if let f = removed as? Folder { dropCache(f) }
                outline.removeItems(at: IndexSet(integer: i), inParent: parent, withAnimation: animate ? [.effectFade, .slideUp] : [])
            case .insert(let j):
                mutate(d) { $0.insert(new[j], at: j) }
                outline.insertItems(at: IndexSet(integer: j), inParent: parent, withAnimation: animate ? [.effectFade, .slideDown] : [])
            case .move(let k, let j):
                mutate(d) { let item = $0.remove(at: k); $0.insert(item, at: j) }
                outline.moveItem(at: k, inParent: parent, to: j, inParent: parent)
            }
        }
        outline.endUpdates()
        syncExpansion(animated: animate)
        updateRowStates(animated: false)
    }

    private func dropCache(_ folder: Folder) {
        guard let kids = folderChildren.removeValue(forKey: ObjectIdentifier(folder)) else { return }
        for case let f as Folder in kids { dropCache(f) }
    }

    /// Makes the outline's expanded state match `Folder.isExpanded`.
    func syncExpansion(animated: Bool) {
        func walk(_ items: [AnyObject]) {
            for case let f as Folder in items {
                let expanded = outline.isItemExpanded(f)
                if f.isExpanded, !expanded {
                    if animated { outline.animator().expandItem(f) } else { outline.expandItem(f) }
                } else if !f.isExpanded, expanded {
                    if animated { outline.animator().collapseItem(f) } else { outline.collapseItem(f) }
                }
                if f.isExpanded, let kids = folderChildren[ObjectIdentifier(f)] { walk(kids) }
            }
        }
        walk(rootItems)
    }

    // MARK: Row states

    private var currentItem: AnyObject? {
        if context.isNewTabCommandBarOpen, context.focusedSpace?.id == space.id { return newTab }
        guard let id = context.selectedID(in: space.id), let node = context.model.node(id: id) else { return nil }
        return node.object
    }

    private func hoverItem() -> AnyObject? {
        guard let forced = context.forcedHover else { return hoveredItem }
        switch forced {
        case .row(let id): return context.model.node(id: id)?.object
        case .newTab: return newTab
        case .divider: return divider
        default: return nil
        }
    }

    func updateRowStates(animated: Bool) {
        let current = currentItem
        let hover = hoverItem()
        outline.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? SidebarRowView else { return }
            let item = outline.item(atRow: row) as AnyObject?
            self.configure(rowView, item: item, current: current, hover: hover, animated: animated)
        }
        header.needsDisplay = true
    }

    private func configure(_ rowView: SidebarRowView, item: AnyObject?, current: AnyObject?, hover: AnyObject?, animated: Bool) {
        rowView.page = self
        rowView.representedItem = item
        rowView.isKeyboardFocused = outline.keyboardItem === item && outline.window?.firstResponder === outline
        let highlight = !(item is SpacerItem || item is DividerItem)
        rowView.allowsHighlight = highlight
        rowView.fillIndent = item.map { CGFloat(outline.level(forItem: $0)) * SpaceListMetrics.indentPerLevel } ?? 0
        rowView.isCurrent = item != nil && item === current
        rowView.isHovered = item != nil && item === hover
        if let cell = rowView.view(atColumn: 0) as? DividerCellView { cell.showsClear = item === hover && hover === divider }
    }

    @objc private func scrolled() {
        guard let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoveredItem = nil; header.pointerInside = false }

    private func updateHover(at point: NSPoint) {
        header.pointerInside = header.frame.contains(point)
        let p = outline.convert(point, from: self)
        guard scroll.frame.contains(point) else { hoveredItem = nil; return }
        let row = outline.row(at: p)
        let item = row >= 0 ? outline.item(atRow: row) as AnyObject? : nil
        hoveredItem = item
        if let tab = item as? Tab, let rowView = outline.rowView(atRow: row, makeIfNecessary: false) {
            TooltipController.shared.schedule(Tooltip(title: tab.displayTitle, subtitle: "Double-click to rename", placement: .beside, style: style),
                                              for: rowView, at: rowView.convert(point, from: self))
        } else {
            TooltipController.shared.cancel(for: nil)
        }
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        activate(item: item)
    }

    @discardableResult
    func activate(item: Any) -> Bool {
        TooltipController.shared.cancel(for: nil)
        switch item {
        case let t as Tab: return context.send(.select(nodeID: t.id, space: space.id))
        case let s as Split: return context.send(.select(nodeID: s.id, space: space.id))
        case let f as Folder: return context.send(.setExpanded(folderID: f.id, expanded: !f.isExpanded))
        case is NewTabItem: return context.send(.openCommandBar(.newTabRow))
        default: return false
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        beginRename(item: item as AnyObject)
    }

    func beginRename(nodeID: ItemID?) {
        guard let nodeID else { header.beginRename(); return }
        guard let obj = context.model.node(id: nodeID)?.object else { return }
        let row = outline.row(forItem: obj)
        if row >= 0 { outline.scrollRowToVisible(row) }
        beginRename(item: obj)
    }

    private func beginRename(item: AnyObject) {
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        (cell as? TabCellView)?.beginRename()
        (cell as? FolderCellView)?.beginRename()
    }

    func menu(at point: NSPoint) -> NSMenu {
        let row = outline.row(at: point)
        let item = row >= 0 ? outline.item(atRow: row) : nil
        switch item {
        case let t as Tab: return context.model.isPinned(tabID: t.id) ? menus.pinnedTab(t) : menus.todayTab(t)
        case let f as Folder: return menus.folder(f)
        case let s as Split: return menus.split(s)
        default: return menus.space(space)
        }
    }

    // MARK: Data source

    private func children(of item: Any?) -> [AnyObject] {
        guard let folder = item as? Folder else { return rootItems }
        let key = ObjectIdentifier(folder)
        if let c = folderChildren[key] { return c }
        let c = folder.children.map(\.object)
        folderChildren[key] = c
        return c
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Folder }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch item {
        case is SpacerItem: SpaceListMetrics.spacerRowHeight
        case is DividerItem: SpaceListMetrics.dividerRowHeight
        default: SpaceListMetrics.rowHeight
        }
    }

    // Do not return false from `shouldShowOutlineCellForItem`: NSOutlineView then
    // refuses to collapse the item. The triangle is hidden by `frameOfOutlineCell`.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = outlineView.makeView(withIdentifier: SidebarRowView.identifier, owner: nil) as? SidebarRowView ?? SidebarRowView()
        row.page = self
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let depth = outlineView.level(forItem: item)
        func make<T: SidebarCellView>(_ type: T.Type, _ id: NSUserInterfaceItemIdentifier) -> T {
            let v = outlineView.makeView(withIdentifier: id, owner: nil) as? T ?? T(frame: .zero)
            v.page = self
            v.depth = depth
            return v
        }
        switch item {
        case let t as Tab: let v = make(TabCellView.self, TabCellView.identifier); v.tab = t; return v
        case let f as Folder: let v = make(FolderCellView.self, FolderCellView.identifier); v.folder = f; return v
        case let s as Split: let v = make(SplitCellView.self, SplitCellView.identifier); v.split = s; return v
        case is NewTabItem: return make(NewTabCellView.self, NewTabCellView.identifier)
        case is DividerItem: return make(DividerCellView.self, DividerCellView.identifier)
        default: return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? SidebarRowView else { return }
        configure(rowView, item: outlineView.item(atRow: row) as AnyObject?, current: currentItem, hover: hoverItem(), animated: false)
    }

    func outlineViewItemDidExpand(_ notification: Notification) { updateRowStates(animated: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { updateRowStates(animated: false) }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let id = itemID(of: item), let node = context.model.node(id: id) else { return nil }
        return SidebarPasteboard.writer(for: node)
    }

    /// Model destination for a proposed outline drop, or nil when not allowed.
    func dropDestination(item: Any?, childIndex: Int) -> (parent: NodeParent, index: Int, retarget: (Any?, Int)?)? {
        switch item {
        case let f as Folder:
            let i = childIndex == NSOutlineViewDropOnItemIndex ? f.children.count : childIndex
            return (.folder(f.id), i, nil)
        case nil:
            let pinnedCount = space.isPinnedCollapsed ? 0 : space.pinned.count
            let pinnedEnd = 1 + pinnedCount
            let newTabIndex = pinnedEnd + (space.today.isEmpty ? 0 : 1)
            let todayStart = newTabIndex + 1
            if childIndex <= pinnedEnd { return (.spacePinned(space.id), max(0, childIndex - 1), childIndex < 1 ? (nil, 1) : nil) }
            if childIndex <= todayStart { return (.spaceToday(space.id), 0, childIndex == todayStart ? nil : (nil, todayStart)) }
            return (.spaceToday(space.id), childIndex - todayStart, nil)
        case let t as AnyObject where t is Tab || t is Split:
            // Dropping onto a row: insert above it in its parent.
            let parent = outlineView(outline, parentOf: t)
            let siblings = children(of: parent)
            guard let i = siblings.firstIndex(where: { $0 === t }) else { return nil }
            return dropDestination(item: parent, childIndex: i).map { ($0.parent, $0.index, (parent, i)) }
        default:
            return nil
        }
    }

    private func outlineView(_ outlineView: NSOutlineView, parentOf item: AnyObject) -> Any? { outlineView.parent(forItem: item) }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let dest = dropDestination(item: item, childIndex: index) else { return [] }
        if let r = dest.retarget { outlineView.setDropItem(r.0, dropChildIndex: r.1) }
        if let id = SidebarPasteboard.nodeID(from: info.draggingPasteboard) {
            guard context.model.canMoveNode(id: id, to: dest.parent) else { return [] }
            return .move
        }
        return SidebarPasteboard.urls(from: info.draggingPasteboard).isEmpty ? [] : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let dest = dropDestination(item: item, childIndex: index) else { return false }
        if let id = SidebarPasteboard.nodeID(from: info.draggingPasteboard) {
            var target = dest.index
            // Same-parent reorder: the model counts the position after removal.
            if context.model.parent(of: id) == dest.parent, let from = siblingIndex(of: id, in: dest.parent), from < target { target -= 1 }
            return context.send(.move(nodeID: id, to: dest.parent, index: target))
        }
        guard let url = SidebarPasteboard.urls(from: info.draggingPasteboard).first else { return false }
        return context.send(.openURL(url, in: dest.parent, index: dest.index))
    }

    private func siblingIndex(of id: ItemID, in parent: NodeParent) -> Int? {
        let list: [SidebarNode]
        switch parent {
        case .spacePinned: list = space.pinned
        case .spaceToday: list = space.today
        case .folder(let fid): list = context.model.node(id: fid)?.folder?.children ?? []
        default: return nil
        }
        return list.firstIndex { $0.id == id }
    }
}

/// Outline view that lets row buttons take clicks and builds context menus.
@MainActor
final class SidebarOutlineView: NSOutlineView {
    weak var page: SpacePageView?
    private(set) var keyboardItem: AnyObject?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        page?.updateRowStates(animated: false)
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        // AppKit has not changed firstResponder yet.
        enumerateAvailableRowViews { view, _ in (view as? SidebarRowView)?.isKeyboardFocused = false }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        keyboardItem = nil
        page?.updateRowStates(animated: false)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let page, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        let rows = (0..<numberOfRows).filter { itemID(of: item(atRow: $0)) != nil || item(atRow: $0) is NewTabItem }
        let current = keyboardItem.map { row(forItem: $0) } ?? -1
        switch event.keyCode {
        case 125, 126: // Down, Up: focus only, leaving selection in the model.
            let next = event.keyCode == 125 ? rows.first(where: { $0 > current }) : rows.last(where: { $0 < (current < 0 ? numberOfRows : current) })
            if let next { keyboardItem = item(atRow: next) as AnyObject?; scrollRowToVisible(next) }
        case 36, 49, 76: // Return, Space, keypad Enter
            if let keyboardItem { page.activate(item: keyboardItem) }
        case 123, 124: // Left, Right
            if let folder = keyboardItem as? Folder {
                page.context.send(.setExpanded(folderID: folder.id, expanded: event.keyCode == 124))
            }
        case 51, 117: // Delete, forward Delete: archive a focused tab.
            if let tab = keyboardItem as? Tab {
                let next = rows.first(where: { $0 > current }).flatMap { item(atRow: $0) as AnyObject? }
                    ?? rows.last(where: { $0 < current }).flatMap { item(atRow: $0) as AnyObject? }
                page.context.send(.close(nodeID: tab.id))
                keyboardItem = next
            }
        default: super.keyDown(with: event); return
        }
        page.updateRowStates(animated: false)
    }

    override func accessibilityRows() -> [any NSAccessibilityRow]? {
        (0..<numberOfRows).compactMap { row -> NSTableRowView? in
            guard itemID(of: item(atRow: row)) != nil || item(atRow: row) is NewTabItem else { return nil }
            return rowView(atRow: row, makeIfNecessary: true)
        }
    }

    override func accessibilityChildren() -> [Any]? { accessibilityRows()?.map { $0 as Any } }

    override func reloadData() {
        SidebarDiagnostics.fullReloads += 1
        super.reloadData()
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is PlateButton || responder is RenameField || responder is DividerCellView { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        page?.menu(at: convert(event.locationInWindow, from: nil))
    }

    /// No disclosure triangle: folder rows toggle on click, as in Arc.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override var isOpaque: Bool { false }
}

/// Space header: icon and title; on hover a fill, a collapse chevron in place of
/// the icon, and a "…" button (A0413).
@MainActor
final class SpaceHeaderView: NSView {
    unowned let context: SidebarContext
    let space: Space
    weak var page: SpacePageView?
    private let fill = CALayer()
    private let title = TextLabel()
    private let icon = SpaceIconView()
    let chevron = PlateButton(glyph: .disclosureDown)
    let more = PlateButton(glyph: .spaceMore)
    var pointerInside = false { didSet { if pointerInside != oldValue { needsDisplay = true; needsLayout = true } } }

    init(context: SidebarContext, space: Space) {
        self.context = context
        self.space = space
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        fill.cornerCurve = .continuous
        fill.opacity = 0
        layer?.addSublayer(fill)
        icon.space = space
        icon.context = context
        title.font = Typography.spaceTitle.font
        title.baseline = SpaceListMetrics.headerTitleBaselineOffset
        title.inset = SpaceListMetrics.headerTextInset
        title.text = { [unowned context, space] in context.title(of: space) }
        title.color = { SidebarRole.spaceTitle.nsColor }
        chevron.accessibleTitle = { [weak space] in space?.isPinnedCollapsed == true ? "Expand Pinned" : "Collapse Pinned" }
        more.setAccessibilityLabel("Space options")
        chevron.showsHoverPlate = false
        chevron.glyphTint = { _ in SidebarRole.spaceTitle.nsColor }
        chevron.action = { [unowned context, space] in context.send(.setPinnedCollapsed(space: space.id, collapsed: !space.isPinnedCollapsed)) }
        more.glyphTint = { _ in SidebarRole.spaceTitle.nsColor }
        more.menuProvider = { [weak self] in self?.page.map { $0.menus.space($0.space) } }
        chevron.context = context
        more.context = context
        addSubview(icon); addSubview(title); addSubview(chevron); addSubview(more)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    private var isHovered: Bool {
        if let forced = context.forcedHover { return forced == .header }
        return pointerInside
    }

    override func updateLayer() {
        let hovered = tracked({ isHovered }) { [weak self] in self?.needsDisplay = true; self?.needsLayout = true }
        fill.backgroundColor = SidebarRole.rowHover.cgColor(contentAppearance)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.hoverFade)
        fill.opacity = hovered ? 1 : 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let m = SpaceListMetrics.self
        let w = bounds.width
        let hovered = tracked({ isHovered }) { [weak self] in self?.needsLayout = true }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: m.headerFillInsetX, y: 0, width: w - 2 * m.headerFillInsetX, height: m.headerHeight)
        fill.cornerRadius = m.rowFillCornerRadius
        CATransaction.commit()
        icon.frame = m.headerIconFrame
        chevron.frame = m.headerIconFrame
        icon.isHidden = hovered
        chevron.isHidden = !hovered
        chevron.glyphView.glyph = space.isPinnedCollapsed ? .disclosureRight : .disclosureDown
        let s = m.headerMoreSize
        more.frame = CGRect(x: w - m.headerMoreTrailing - s, y: (m.headerHeight - s) / 2, width: s, height: s)
        more.isHidden = !hovered
        let right = hovered ? more.frame.minX - 2 : w - 17
        title.frame = CGRect(x: m.headerTitleX, y: m.headerTitleY, width: max(0, right - m.headerTitleX), height: 18)
    }

    override func menu(for event: NSEvent) -> NSMenu? { page.map { $0.menus.space($0.space) } }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginRename() }
    }

    func beginRename() {
        let field = RenameField(frame: title.frame.insetBy(dx: -2, dy: -1))
        field.stringValue = context.title(of: space)
        field.font = title.font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = SidebarRole.spaceTitle.nsColor
        let id = space.id
        field.onEnd = { [weak self, weak field] value in
            field?.removeFromSuperview()
            self?.title.isHidden = false
            if let value { self?.context.send(.renameSpace(id, title: value)) }
        }
        title.isHidden = true
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
}

/// Space icon: emoji, SF Symbol, or a neutral dot.
@MainActor
final class SpaceIconView: NSView {
    weak var space: Space?
    weak var context: SidebarContext?
    var emojiSize: CGFloat = Typography.headerEmoji.size
    /// Emoji sit 1 pt above the frame's center (NCC fit on F0001).
    var emojiNudgeY: CGFloat = -1
    var desaturated = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let space else { return }
        let icon = tracked({ space.icon }) { [weak self] in self?.needsDisplay = true }
        switch icon {
        case .emoji(let e)?:
            if desaturated, let gray = EmojiRenderer.grayscale(e, size: emojiSize) {
                let s = gray.size
                gray.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2 + emojiNudgeY, width: s.width, height: s.height),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                EmojiRenderer.draw(e, fontSize: emojiSize, in: bounds.offsetBy(dx: 0, dy: emojiNudgeY))
            }
        case .symbol(let name)? where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil:
            // Arc's own named icons (for example "planet" on the default Space) have no SF Symbol.
            CustomIcon.planet(in: NSRect(x: bounds.midX - emojiSize / 2, y: bounds.midY - emojiSize / 2, width: emojiSize, height: emojiSize),
                              color: desaturated ? SidebarRole.spaceTitle.nsColor : SidebarRole.spaceTitle.nsColor)
        case .symbol(let name)?:
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: emojiSize * 0.8, weight: .medium)) {
                let s = img.size
                img.drawTinted(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height),
                               color: SidebarRole.spaceTitle.nsColor)
            }
        case nil:
            // Arc draws a planet-like mark for Spaces without an icon (F0079); ours is drawn in code.
            CustomIcon.planet(in: NSRect(x: bounds.midX - emojiSize / 2, y: bounds.midY - emojiSize / 2, width: emojiSize, height: emojiSize),
                              color: SidebarRole.spaceTitle.nsColor)
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

extension SidebarNode {
    var object: AnyObject {
        switch self {
        case .tab(let t): t
        case .folder(let f): f
        case .split(let s): s
        }
    }
}
