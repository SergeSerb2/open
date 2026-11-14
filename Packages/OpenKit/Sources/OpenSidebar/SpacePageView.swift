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
    /// False for pages that never show a header (the Space Manager's mini pages).
    var displaysHeader = true { didSet { updateHeaderVisibility() } }
    /// Shows a hidden header while its title is being renamed.
    var revealsHeaderForRename = false { didSet { updateHeaderVisibility() } }
    /// The header is shown: not hidden for a single unnamed Space (`SidebarContext.hidesHeader`), or being renamed.
    private(set) var headerVisible = true
    func updateHeaderVisibility() {
        let visible = displaysHeader && (revealsHeaderForRename || !context.hidesHeader(for: space))
        guard visible != headerVisible || header.isHidden == visible else { return }
        headerVisible = visible; header.isHidden = !visible; needsLayout = true
    }
    let header: SpaceHeaderView
    let scroll = PageScrollView()
    let outline = SidebarOutlineView()
    let dropIndicator = SidebarDropIndicator()
    let spacer = SpacerItem(), divider = DividerItem(), newTab = NewTabItem()
    var menus: SidebarMenus

    /// Child lists as the outline currently knows them.
    private var rootItems: [AnyObject] = []
    private var folderChildren: [ObjectIdentifier: [AnyObject]] = [:]
    private var displayedExpansion: [ObjectIdentifier: FolderExpansion] = [:]
    private var displayedChildCounts: [ObjectIdentifier: Int] = [:]
    /// C-LF-2 (Open's design): reveal the first 10 PRs, then Show More. Never saved.
    private var revealedLiveFolders: Set<ItemID> = []
    private var liveFolderMoreItems: [ItemID: LiveFolderMoreItem] = [:]
    private var rootPinnedCount = 0
    private var rootTodayCount = 0
    private var rootPinnedCollapsed = false
    private var loops: [ObservationLoop] = []
    private var folderLoops: [ObjectIdentifier: ObservationLoop] = [:]
    private var mirroringSelection = false
    private var draggingIDs: Set<ItemID> = []
    private var applyingBulk = false
    private var syncingExpansion = false
    private let rowMotion = SidebarRowLayerMotion()
    private var hoveredItem: AnyObject? { didSet { if hoveredItem !== oldValue { updateRowStates(animated: true) } } }
    private var tracking: NSTrackingArea?

    init(context: SidebarContext, space: Space, menus: SidebarMenus) {
        self.context = context
        self.space = space
        self.menus = menus
        header = SpaceHeaderView(context: context, space: space)
        super.init(frame: .zero)
        SidebarDiagnostics.spacePageBuilds += 1
        wantsLayer = true
        header.page = self
        addSubview(header)
        rootItems = computeRoot()
        rememberRootShape()
        configureOutline()
        scroll.documentView = outline
        addSubview(scroll)
        applyAppearance()
        syncExpansion(animated: false, initial: true)
        observe()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var style: SpaceThemeStyle { context.style(for: space) }
    var contentAppearanceForSpace: ContentAppearance { context.appearance(for: space) }
    /// This Space's sidebar colours (`SidebarRoles`, cached per theme change).
    var roles: SidebarRoles { context.roles(for: space) }
    private var animatesChanges: Bool { context.animatesChanges && animatesSidebarChanges }

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
        outline.allowsMultipleSelection = true
        outline.focusRingType = .none
        outline.delegate = self
        outline.page = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.registerForDraggedTypes([.sidebarNode, .URL, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .none
        dropIndicator.isHidden = true
        outline.addSubview(dropIndicator)
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
        // Setting the native data source performs the initial load. Cache roots
        // and install the delegate first, so there is no empty preliminary load.
        outline.dataSource = self
    }

    /// Each page draws in its own Space's content appearance.
    func applyAppearance() {
        appearance = contentAppearanceForSpace.nsAppearance
    }

    override func layout() {
        super.layout()
        SidebarDiagnostics.spacePageLayouts += 1
        let w = bounds.width
        header.frame = CGRect(x: 0, y: 0, width: w, height: SpaceListMetrics.headerHeight)
        let headerHeight = headerVisible ? SpaceListMetrics.headerHeight : 0
        scroll.frame = CGRect(x: 0, y: headerHeight, width: w, height: max(0, bounds.height - headerHeight))
        if let column = outline.tableColumns.first, column.width != w { column.width = w }
    }

    // MARK: Observation

    private func observe() {
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.context.selection.ids }) { [weak self] in
            self?.syncSelectionIndexes()
        })
        // Selection, command bar state, forced hover: update row fills.
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.context.selectedID(in: self.space.id)
            _ = self.context.isNewTabCommandBarOpen
            _ = self.context.forcedHover
            _ = self.context.peekSourceNodeID
        }) { [weak self] in self?.updateRowStates(animated: true) })
        // Root shape only. Each exposed folder observes its own expansion, so
        // toggling one folder never reads a 1,000-row root or unrelated folders.
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.space.isPinnedCollapsed
            _ = self.space.pinned.count
            _ = self.space.today.count
        }) { [weak self] in
            guard let self else { return }
            guard self.context.manager?.deferHiddenUpdates() != true else { return }
            if self.rootPinnedCount != self.space.pinned.count || self.rootTodayCount != self.space.today.count || self.rootPinnedCollapsed != self.space.isPinnedCollapsed {
                self.syncRoot()
            }
            self.syncExpansion(animated: self.animatesChanges)
        })
        // Space header visibility (single unnamed Space, "Show/Hide Space Header").
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.context.model.spaces.count
            _ = self.space.title
            _ = SpaceHeaderPreference.shared.showOnSingleUnnamedSpace
        }) { [weak self] in self?.updateHeaderVisibility() })
        // Theme and appearance.
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.space.theme
            _ = self.context.systemAppearance
            _ = self.context.increaseContrast
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
        folderLoops.values.forEach { $0.cancel() }
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
        if !context.hidesSpaceChrome, !space.isPinnedCollapsed { r += space.pinned.map(\.object) }
        if !context.hidesSpaceChrome, !space.today.isEmpty { r.append(divider) }
        if context.manager?.libraryLayout != true { r.append(newTab) }
        r += space.today.map(\.object)
        return r
    }

    /// True when the change touched this page.
    @discardableResult
    func apply(_ change: TreeChange) -> Bool {
        switch change {
        case .insert(let p, _, _), .remove(let p, _, _), .reload(let p):
            let touched = sync(parent: p)
            if touched { pruneSelection() }
            return touched
        case .move(let from, _, let to, _, let nodeID):
            defer { if displayedItem(for: from) != nil || displayedItem(for: to) != nil { pruneSelection() } }
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

    /// Reconcile final parent lists once for a synchronous bulk command. Remove
    /// departing children first, so cross-parent inserts never duplicate an item
    /// in AppKit. Cached lists and native edits still advance together.
    func applyBulk(_ changes: [TreeChange]) {
        var root = false
        var folders: [Folder] = []
        var seen: Set<ItemID> = []
        func include(_ parent: NodeParent) {
            switch displayedItem(for: parent) {
            case .root: root = true
            case .folder(let folder): if seen.insert(folder.id).inserted { folders.append(folder) }
            case nil: break
            }
        }
        for change in changes {
            switch change {
            case .insert(let parent, _, _), .remove(let parent, _, _), .reload(let parent): include(parent)
            case .move(let from, _, let to, _, _): include(from); include(to)
            case .spaceProfileChanged: break
            }
        }
        guard root || !folders.isEmpty else { return }
        rowMotion.begin(outline, animated: animatesChanges, duration: Motion.rowStructure, timing: Motion.easeInOut)
        defer { rowMotion.end(outline) }
        applyingBulk = true
        outline.beginUpdates()
        let parents: [Displayed] = folders.map { .folder($0) } + (root ? [.root] : [])
        for parent in parents {
            if case .folder(let folder) = parent, folderChildren[ObjectIdentifier(folder)] == nil { continue }
            let retained = Set(target(for: parent).map(ObjectIdentifier.init))
            apply(target: list(for: parent).filter { retained.contains(ObjectIdentifier($0)) }, in: parent)
        }
        for parent in (root ? [.root] : []) + folders.map({ Displayed.folder($0) }) {
            if case .folder(let folder) = parent, folderChildren[ObjectIdentifier(folder)] == nil { continue }
            apply(target: target(for: parent), in: parent)
        }
        outline.endUpdates()
        applyingBulk = false
        syncExpansion(animated: animatesChanges)
        updateRowStates(animated: false)
        pruneSelection()
        syncSelectionIndexes()
    }

    /// Reconcile a hidden Manager once on visibility, without reloadData or an event backlog.
    func resyncAfterVisibility() {
        var changes: [TreeChange] = [.reload(parent: .spacePinned(space.id)), .reload(parent: .spaceToday(space.id))]
        forEachLoadedFolder { changes.append(.reload(parent: .folder($0.id))) }
        applyBulk(changes)
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
        guard src.map(ObjectIdentifier.init) == target(for: from).map(ObjectIdentifier.init) else { return false }
        rowMotion.begin(outline, animated: animatesChanges, duration: Motion.rowStructure, timing: Motion.easeInOut)
        defer { rowMotion.end(outline) }
        setList(src, for: from)
        setList(dstNew, for: to)
        outline.beginUpdates()
        outline.moveItem(at: fromIndex, inParent: parentItem(from), to: toIndex, inParent: parentItem(to))
        outline.endUpdates()
        syncExpansion(animated: animatesChanges)
        updateRowStates(animated: false)
        return true
    }

    private func list(for d: Displayed) -> [AnyObject] {
        switch d { case .root: rootItems; case .folder(let f): folderChildren[ObjectIdentifier(f)] ?? [] }
    }

    private func displayedChildren(of folder: Folder) -> [AnyObject] {
        if folder.expansion != .expanded { revealedLiveFolders.remove(folder.id) }
        switch folder.expansion {
        case .expanded:
            guard folder.live != nil, !revealedLiveFolders.contains(folder.id) else { return folder.children.map(\.object) }
            var count = 0, hidden = false
            let rows: [AnyObject] = folder.children.compactMap { node in
                // A user's own rows remain visible; only fetched PRs use the limit.
                if case .tab(let tab) = node, tab.liveItemURL != nil {
                    count += 1
                    if count > 10 { hidden = true; return nil }
                }
                return node.object
            }
            guard hidden else { return rows }
            let more = liveFolderMoreItems[folder.id] ?? LiveFolderMoreItem(folderID: folder.id)
            liveFolderMoreItems[folder.id] = more
            return rows + [more]
        case .collapsed: return []
        case .peeked(let id):
            guard context.model.parent(of: id) == .folder(folder.id), let node = context.model.node(id: id), node.folder == nil else { return [] }
            return [node.object]
        }
    }

    func liveFolderMoreItem(folderID: ItemID) -> LiveFolderMoreItem? {
        guard let item = liveFolderMoreItems[folderID], outline.row(forItem: item) >= 0 else { return nil }
        return item
    }

    private func target(for d: Displayed) -> [AnyObject] {
        switch d { case .root: computeRoot(); case .folder(let f): displayedChildren(of: f) }
    }

    private func setList(_ l: [AnyObject], for d: Displayed) {
        switch d { case .root: rootItems = l; case .folder(let f): folderChildren[ObjectIdentifier(f)] = l }
    }

    private func parentItem(_ d: Displayed) -> Any? {
        switch d { case .root: nil; case .folder(let f): f }
    }

    private func rememberRootShape() {
        rootPinnedCount = space.pinned.count; rootTodayCount = space.today.count; rootPinnedCollapsed = space.isPinnedCollapsed
    }

    func syncRoot() { apply(target: computeRoot(), in: .root); rememberRootShape() }

    private func syncFolder(_ folder: Folder) {
        guard folderChildren[ObjectIdentifier(folder)] != nil else { return }
        syncExpansion(animated: animatesChanges, changedFolder: folder.id)
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
    private func apply(target new: [AnyObject], in d: Displayed, animated: Bool? = nil) {
        let steps = ListDiff.steps(old: list(for: d).map(ObjectIdentifier.init), new: new.map(ObjectIdentifier.init))
        guard !steps.isEmpty else { return }
        let animate = animated ?? animatesChanges
        rowMotion.begin(outline, animated: animate, duration: Motion.rowStructure, timing: Motion.easeInOut)
        defer { rowMotion.end(outline) }
        let parent = parentItem(d)
        if syncingExpansion, case .folder = d {
            // A folder transition only inserts or removes a subset, preserving
            // retained row order. One native edit avoids reprocessing the same
            // trailing row positions for each child in the sequential diff.
            let old = list(for: d), oldIDs = old.map(ObjectIdentifier.init), newIDs = new.map(ObjectIdentifier.init)
            let kept = Set(newIDs), prior = Set(oldIDs)
            if oldIDs.filter({ kept.contains($0) }) == newIDs {
                let indexes = IndexSet(oldIDs.indices.filter { !kept.contains(oldIDs[$0]) })
                for i in indexes {
                    rowMotion.captureDeparture(old[i], in: outline)
                    if let folder = old[i] as? Folder { rowMotion.captureDescendants(of: folder, in: outline); dropCache(folder) }
                }
                setList(new, for: d)
                outline.removeItems(at: indexes, inParent: parent, withAnimation: [])
                return
            }
            if newIDs.filter({ prior.contains($0) }) == oldIDs {
                let indexes = IndexSet(newIDs.indices.filter { !prior.contains(newIDs[$0]) })
                setList(new, for: d)
                outline.insertItems(at: indexes, inParent: parent, withAnimation: [])
                return
            }
        }
        if !syncingExpansion && !applyingBulk { outline.beginUpdates() }
        for step in steps {
            switch step {
            case .remove(let i):
                let departing = list(for: d)[i]
                rowMotion.captureDeparture(departing, in: outline)
                rowMotion.captureDescendants(of: departing, in: outline)
                var removed: AnyObject?
                mutate(d) { removed = $0.remove(at: i) }
                if let f = removed as? Folder { dropCache(f) }
                outline.removeItems(at: IndexSet(integer: i), inParent: parent, withAnimation: [])
            case .insert(let j):
                mutate(d) { $0.insert(new[j], at: j) }
                outline.insertItems(at: IndexSet(integer: j), inParent: parent, withAnimation: [])
            case .move(let k, let j):
                mutate(d) { let item = $0.remove(at: k); $0.insert(item, at: j) }
                outline.moveItem(at: k, inParent: parent, to: j, inParent: parent)
            }
        }
        if !syncingExpansion && !applyingBulk { outline.endUpdates() }
        if !applyingBulk && !syncingExpansion {
            syncExpansion(animated: animate)
            updateRowStates(animated: false)
        }
    }

    private func observeFolder(_ folder: Folder) {
        let key = ObjectIdentifier(folder)
        guard folderLoops[key] == nil else { return }
        // AppKit need not request children for a collapsed row. Register its
        // empty list before observing, so the first expand/peek can reconcile.
        if folderChildren[key] == nil { folderChildren[key] = [] }
        folderLoops[key] = ObservationLoop(read: { [weak folder] in
            _ = folder?.isExpanded; _ = folder?.peekedChildID; _ = folder?.children.count
        }) { [weak self, weak folder] in
            guard let self, let folder, self.folderChildren[key] != nil,
                  self.context.manager?.deferHiddenUpdates() != true else { return }
            self.syncExpansion(animated: self.animatesChanges, changedFolder: folder.id)
        }
    }

    private func dropCache(_ folder: Folder) {
        revealedLiveFolders.remove(folder.id)
        liveFolderMoreItems[folder.id] = nil
        folderLoops.removeValue(forKey: ObjectIdentifier(folder))?.cancel()
        displayedExpansion[ObjectIdentifier(folder)] = nil
        displayedChildCounts[ObjectIdentifier(folder)] = nil
        guard let kids = folderChildren.removeValue(forKey: ObjectIdentifier(folder)) else { return }
        for case let f as Folder in kids { dropCache(f) }
    }

    /// Logical peek is collapsed for AX, but expanded natively with exactly one real child.
    func syncExpansion(animated: Bool, initial: Bool = false, changedFolder: ItemID? = nil) {
        guard !syncingExpansion else { return }
        syncingExpansion = true
        let measuring = SidebarDiagnostics.measuresFolderTransitions
        let started = measuring ? CACurrentMediaTime() : 0
        let cpuStarted = measuring ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0
        var phaseStart = started
        let expanding = changedFolder.flatMap { context.model.node(id: $0)?.folder }?.isExpanded ?? true
        // Root-count observation can reconcile expansion again after a row
        // edit. A no-op refresh must not replace the row's in-flight layer
        // animation before its first presentation tree has been committed.
        var beganMotion = false
        func beginMotion() {
            guard !beganMotion else { return }
            beganMotion = true
            rowMotion.begin(outline, animated: animated && !initial,
                            duration: expanding ? Motion.folderExpand : Motion.folderCollapse,
                            timing: expanding ? Motion.folderExpandTiming : Motion.folderCollapseTiming)
        }
        func phase(_ name: String) {
            guard measuring else { return }
            let now = CACurrentMediaTime()
            SidebarDiagnostics.folderReconcilePhases[name, default: 0] += now - phaseStart
            phaseStart = now
        }
        defer {
            if beganMotion { rowMotion.end(outline) }
            phase("layer-motion")
            syncingExpansion = false
            if measuring {
                SidebarDiagnostics.folderReconcileSeconds += CACurrentMediaTime() - started
                SidebarDiagnostics.folderReconcileCPUSeconds += Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStarted) / 1e9
                SidebarDiagnostics.folderReconcileCount += 1
            }
        }
        if measuring, SidebarDiagnostics.folderBenchBusyWindowID == context.windowID {
            // Deliberate real main-thread CPU work, only for the CLI negative proof.
            let deadline = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) + 3_000_000
            while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) < deadline {}
            phase("negative-busy-wait")
        }
        let animate = animated && !Motion.reducesMotion
        let firstRow = outline.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
        let firstItem = firstRow >= 0 ? outline.item(atRow: firstRow) : nil
        let offset = firstRow >= 0 ? scroll.contentView.bounds.minY - outline.rect(ofRow: firstRow).minY : 0
        var changed = false
        func walk(_ items: [AnyObject]) {
            if measuring { SidebarDiagnostics.folderSyncItemsVisited += items.count }
            for case let folder as Folder in items {
                observeFolder(folder)
                let key = ObjectIdentifier(folder), state = folder.expansion
                let old = displayedExpansion[key] ?? .collapsed
                let native = outline.isItemExpanded(folder)
                // Unchanged folders keep their cached list. Do not rebuild unrelated arrays
                // for one folder toggle; structural events explicitly name their affected parent.
                if !initial, old == state, native == (state != .collapsed),
                   displayedChildCounts[key] == folder.children.count, changedFolder != folder.id {
                    if state != .collapsed, let kids = folderChildren[key] { walk(kids) }
                    continue
                }
                let target = displayedChildren(of: folder)
                let previous = folderChildren[key] ?? []
                if old != state || native != (state != .collapsed) || previous.map(ObjectIdentifier.init) != target.map(ObjectIdentifier.init) {
                    beginMotion()
                    let expanding = state == .expanded
                    let transition = old != state
                    let duration = transition ? (expanding ? Motion.folderExpand : Motion.folderCollapse) : Motion.rowStructure
                    NSAnimationContext.runAnimationGroup { group in
                        group.duration = 0
                        group.timingFunction = transition ? (expanding ? Motion.folderExpandTiming : Motion.folderCollapseTiming) : nil
                        if transition {
                            SidebarDiagnostics.folderTransitionDuration = animate ? duration : 0
                            SidebarDiagnostics.folderTransitionExpanding = expanding
                        }
                        outline.beginUpdates()
                        if initial || !native {
                            // A collapsed item has no displayed child list to edit.
                            // The native expand below inserts it once from this cache.
                            folderChildren[key] = target
                        } else {
                            if folderChildren[key] == nil { folderChildren[key] = [] }
                            apply(target: target, in: .folder(folder), animated: animate)
                        }
                        if state != .collapsed, !native {
                            outline.expandItem(folder)
                        } else if state == .collapsed, native {
                            rowMotion.captureDescendants(of: folder, in: outline)
                            outline.collapseItem(folder)
                        }
                        outline.endUpdates()
                    }
                    displayedExpansion[key] = state
                    changed = true
                }
                displayedChildCounts[key] = folder.children.count
                if state != .collapsed, let kids = folderChildren[key] { walk(kids) }
            }
        }
        if let changedFolder, let folder = context.model.node(id: changedFolder)?.folder {
            walk([folder])
        } else { walk(rootItems) }
        phase("walk-and-native-edits")
        if let firstItem {
            let row = outline.row(forItem: firstItem)
            if row >= 0 {
                let y = min(max(0, outline.rect(ofRow: row).minY + offset), max(0, outline.frame.height - scroll.contentView.bounds.height))
                if y != scroll.contentView.bounds.minY { scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }
            }
        }
        phase("scroll-anchor")
        if changed {
            if let changedFolder, let folder = context.model.node(id: changedFolder)?.folder {
                // New child rows are configured by didAdd. The retained child has
                // the same identity/depth/state. Unrelated available rows need
                // no state assignment or header redraw for a folder transition.
                let row = outline.row(forItem: folder)
                if row >= 0, let view = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView {
                    configure(view, item: folder, current: currentItem, hover: hoverItem(), animated: false)
                }
            } else { updateRowStates(animated: false) }
        }
        phase("row-states")
        pruneSelection()
        phase("selection")
        if measuring {
            // Keep the bench's forced layout/display inside the measured completed callback.
            layoutSubtreeIfNeeded()
            phase("forced-layout")
            window?.displayIfNeeded()
            phase("forced-display")
            CATransaction.flush()
        }
        phase("forced-ca-flush")
    }

    // MARK: Row states

    /// Built only for an input event or a structure change, never during drawing.
    var selectableOrder: [ItemID] {
        (0..<outline.numberOfRows).compactMap { itemID(of: outline.item(atRow: $0)) }
    }

    private func pruneSelection() {
        guard !applyingBulk, context.focusedSpace?.id == space.id, !context.selection.isEmpty else { return }
        let order = selectableOrder
        context.selection.prune(keeping: Set(order), order: order)
        let ordered = order.filter { context.selection.contains($0) }
        if context.selection.ids != ordered { context.selection.select(ordered, anchor: context.selection.anchor) }
        syncSelectionIndexes()
    }

    func syncSelectionIndexes() {
        guard !applyingBulk, !mirroringSelection, draggingIDs.isEmpty, !outline.dragWasStarted, !outline.trackingMouseDown else { return }
        let wanted = IndexSet(context.selection.ids.compactMap { id in
            guard let object = context.model.node(id: id)?.object else { return nil }
            let row = outline.row(forItem: object)
            return row >= 0 ? row : nil
        })
        guard outline.selectedRowIndexes != wanted else { return }
        mirroringSelection = true
        outline.selectRowIndexes(wanted, byExtendingSelection: false)
        mirroringSelection = false
    }

    func modifySelection(item: Any, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let id = itemID(of: item), !modifiers.intersection([.command, .shift]).isEmpty else { return false }
        context.manager?.activate(space)
        let order = selectableOrder
        let selection = context.selection
        if selection.isEmpty, let current = context.selectedID(in: space.id), order.contains(current) {
            selection.select([current], anchor: current)
        }
        if modifiers.contains(.command) { selection.toggle(id, order: order) }
        else { selection.extend(to: id, order: order) }
        syncSelectionIndexes()
        TooltipController.shared.cancel(for: nil)
        return true
    }

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
        if SidebarDiagnostics.measuresFolderTransitions { SidebarDiagnostics.folderStateRowsConfigured += 1 }
        rowView.page = self
        rowView.representedItem = item
        rowView.isKeyboardFocused = outline.keyboardItem === item && outline.window?.firstResponder === outline
        let highlight = !(item is SpacerItem || item is DividerItem)
        rowView.allowsHighlight = highlight
        rowView.fillIndent = item.map { CGFloat(outline.level(forItem: $0)) * SpaceListMetrics.indentPerLevel } ?? 0
        rowView.isCurrent = item != nil && item === current
        rowView.isPeekSource = context.peekSourceNodeID.map { itemID(of: item) == $0 } ?? false
        rowView.isHovered = item != nil && item === hover
        rowView.alphaValue = itemID(of: item).map { draggingIDs.contains($0) } == true ? 0.4 : 1
        if let cell = rowView.view(atColumn: 0) as? DividerCellView { cell.showsClear = item === hover && hover === divider }
    }

    @objc private func scrolled() {
        if SidebarDiagnostics.folderBenchFullRowWindowID == context.windowID {
            // Deliberately bad O(n) scroll work for the CLI negative proof. Exercise real
            // AppKit cells, not synthetic busy work; the matched baseline has no pass.
            for row in 0..<outline.numberOfRows {
                if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) {
                    cell.needsLayout = true
                    cell.layoutSubtreeIfNeeded()
                }
            }
        }
        guard let window else { return }
        context.existingHoverPreviews?.dismiss()
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), allowPreview: false)
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
    override func mouseExited(with event: NSEvent) { hoveredItem = nil; header.pointerInside = false; context.existingHoverPreviews?.leaveTarget() }

    private func updateHover(at point: NSPoint, allowPreview: Bool = true) {
        header.pointerInside = header.frame.contains(point)
        let p = outline.convert(point, from: self)
        guard scroll.frame.contains(point) else { hoveredItem = nil; context.existingHoverPreviews?.leaveTarget(); return }
        let row = outline.row(at: p)
        let item = row >= 0 ? outline.item(atRow: row) as AnyObject? : nil
        hoveredItem = item
        if let rowView = row >= 0 ? outline.rowView(atRow: row, makeIfNecessary: false) : nil, let id = itemID(of: item) {
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView
            let reset = cell.map { $0.trackFavicon(at: $0.convert(point, from: self)) } ?? false
            if reset { context.existingHoverPreviews?.dismiss(); return }
            if allowPreview, context.canStartHoverPreview,
               context.hoverPreviews.hover(nodeID: id, anchorInWindow: rowView.convert(rowView.bounds, to: nil), owner: rowView) { return }
            if !context.canStartHoverPreview { context.existingHoverPreviews?.dismiss() }
            if let tab = item as? Tab {
                TooltipController.shared.schedule(Tooltip(title: tab.displayTitle, subtitle: "Double-click to rename", placement: .beside, style: style),
                                                  for: rowView, at: rowView.convert(point, from: self))
            } else { TooltipController.shared.cancel(for: nil) }
        } else if item is DividerItem, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? DividerCellView {
            context.existingHoverPreviews?.leaveTarget()
            cell.trackPointer(at: cell.convert(point, from: self))
        } else {
            context.existingHoverPreviews?.leaveTarget()
            TooltipController.shared.cancel(for: nil)
        }
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        outline.didActivateMouseDown = true
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        activate(item: item)
    }

    @discardableResult
    func activate(item: Any) -> Bool {
        context.manager?.activate(space)
        context.selection.clear()
        TooltipController.shared.cancel(for: nil)
        switch item {
        case let t as Tab: return context.send(.select(nodeID: t.id, space: space.id))
        case let s as Split: return context.send(.select(nodeID: s.id, space: space.id))
        case let f as Folder:
            let expansion = f.expansion == .collapsed ? FolderExpansion.expanded : context.folderExpansion(folderID: f.id, expanded: false)
            return context.send(.setFolderExpansion(folderID: f.id, expansion: expansion))
        case let more as LiveFolderMoreItem:
            guard let folder = context.model.node(id: more.folderID)?.folder,
                  folder.live != nil, folder.isExpanded, liveFolderMoreItem(folderID: folder.id) === more else { return false }
            let hidden = folder.children.first { node in !children(of: folder).contains { $0 === node.object } }
            revealedLiveFolders.insert(folder.id)
            syncExpansion(animated: animatesChanges, changedFolder: folder.id)
            if outline.keyboardItem === more { outline.keyboardItem = hidden?.object }
            updateRowStates(animated: false)
            return true
        case is NewTabItem: return context.send(.openCommandBar(.newTabRow))
        default: return false
        }
    }

    @objc private func rowDoubleClicked() {
        outline.didActivateMouseDown = true
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

    fileprivate func beginRename(item: AnyObject) {
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { return }
        (cell as? TabCellView)?.beginRename()
        (cell as? FolderCellView)?.beginRename()
        (cell as? SplitCellView)?.beginRename()
    }

    func menu(at point: NSPoint) -> NSMenu {
        context.existingHoverPreviews?.dismiss()
        context.manager?.activate(space)
        let row = outline.row(at: point)
        let item = row >= 0 ? outline.item(atRow: row) : nil
        if let id = itemID(of: item), context.selection.contains(id) {
            if context.selection.ids.count >= 2 { return menus.selection(context.selection.ids) }
        } else { context.selection.clear() }
        TooltipController.shared.cancel(for: nil)
        switch item {
        case let t as Tab: return context.model.isPinned(tabID: t.id) ? menus.pinnedTab(t) : menus.todayTab(t)
        case let f as Folder: return menus.folder(f)
        case let s as Split: return menus.split(s)
        default: return context.hidesSpaceChrome ? menus.emptyIncognito() : menus.space(space)
        }
    }

    // MARK: Data source

    private func children(of item: Any?) -> [AnyObject] {
        guard let folder = item as? Folder else { return rootItems }
        let key = ObjectIdentifier(folder)
        if let c = folderChildren[key] { return c }
        let c = displayedChildren(of: folder)
        folderChildren[key] = c
        return c
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Folder }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        SidebarDiagnostics.countFolderWork("height-queries")
        return switch item {
        // NSOutlineView requires a strictly positive height. Keep the sentinel
        // for existing child/drop indexes, with no visible card-top spacing.
        case is SpacerItem: context.manager?.libraryLayout == true ? 0.01 : SpaceListMetrics.spacerRowHeight
        case is DividerItem: SpaceListMetrics.dividerRowHeight
        default: SpaceListMetrics.rowHeight
        }
    }

    // Do not return false from `shouldShowOutlineCellForItem`: NSOutlineView then
    // refuses to collapse the item. The triangle is hidden by `frameOfOutlineCell`.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }
    func outlineViewSelectionDidChange(_ notification: Notification) { syncSelectionIndexes() }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = outlineView.makeView(withIdentifier: SidebarRowView.identifier, owner: nil) as? SidebarRowView ?? SidebarRowView()
        row.page = self
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let depth = outlineView.level(forItem: item)
        func make<T: SidebarCellView>(_ type: T.Type, _ id: NSUserInterfaceItemIdentifier) -> T {
            let cached = outlineView.makeView(withIdentifier: id, owner: nil) as? T
            SidebarDiagnostics.countFolderWork(cached == nil ? "cell-allocations" : "cell-reuses")
            let v = cached ?? T(frame: .zero)
            v.page = self
            v.depth = depth
            return v
        }
        switch item {
        case let t as Tab: let v = make(TabCellView.self, TabCellView.identifier); v.tab = t; return v
        case let f as Folder: let v = make(FolderCellView.self, FolderCellView.identifier); v.folder = f; return v
        case let s as Split: let v = make(SplitCellView.self, SplitCellView.identifier); v.split = s; return v
        case is NewTabItem: return make(NewTabCellView.self, NewTabCellView.identifier)
        case is LiveFolderMoreItem: return make(LiveFolderMoreCellView.self, LiveFolderMoreCellView.identifier)
        case is DividerItem: return make(DividerCellView.self, DividerCellView.identifier)
        default: return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? SidebarRowView else { return }
        configure(rowView, item: outlineView.item(atRow: row) as AnyObject?, current: currentItem, hover: hoverItem(), animated: false)
    }

    func outlineViewItemDidExpand(_ notification: Notification) { if !syncingExpansion { pruneSelection(); updateRowStates(animated: false) } }
    func outlineViewItemDidCollapse(_ notification: Notification) { if !syncingExpansion { pruneSelection(); updateRowStates(animated: false) } }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let id = itemID(of: item), let node = context.model.node(id: id) else { return nil }
        return SidebarPasteboard.writer(for: node)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        outline.dragWasStarted = true
        context.suppressPreviews(.drag, true)
        TooltipController.shared.cancel(for: nil)
        draggingIDs = Set(draggedItems.compactMap { itemID(of: $0) })
        context.tabDragChanged?(Array(draggingIDs))
        updateRowStates(animated: false)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingIDs = []
        context.tabDragChanged?(nil)
        clearDropIndicator()
        context.suppressPreviews(.drag, false)
        context.haptics.endDrag()
        outline.dragWasStarted = false
        syncSelectionIndexes()
        updateRowStates(animated: false)
    }

    /// Model destination for a proposed outline drop, or nil when not allowed.
    func dropDestination(item: Any?, childIndex: Int) -> (parent: NodeParent, index: Int, retarget: (Any?, Int)?)? {
        switch item {
        case let f as Folder:
            // Drop ON the folder appends to its full model list. Boundaries
            // around the one exposed peek row belong to the filtered outline.
            if childIndex == NSOutlineViewDropOnItemIndex { return (.folder(f.id), f.children.count, nil) }
            if case .peeked(let id) = f.expansion {
                guard (0...1).contains(childIndex), let index = f.children.firstIndex(where: { $0.id == id }) else { return nil }
                return (.folder(f.id), index + childIndex, nil)
            }
            if f.live != nil, !revealedLiveFolders.contains(f.id) {
                let visible = children(of: f)
                guard (0...visible.count).contains(childIndex) else { return nil }
                let index = childIndex < visible.count ? itemID(of: visible[childIndex]).flatMap { id in f.children.firstIndex { $0.id == id } } : nil
                return (.folder(f.id), index ?? f.children.count, nil)
            }
            return (.folder(f.id), childIndex, nil)
        case nil:
            let pinnedCount = context.hidesSpaceChrome || space.isPinnedCollapsed ? 0 : space.pinned.count
            let pinnedEnd = 1 + pinnedCount
            let newTabIndex = pinnedEnd + (context.hidesSpaceChrome || space.today.isEmpty ? 0 : 1)
            let todayStart = newTabIndex + (context.manager?.libraryLayout == true ? 0 : 1)
            if !context.hidesSpaceChrome, childIndex <= pinnedEnd { return (.spacePinned(space.id), max(0, childIndex - 1), childIndex < 1 ? (nil, 1) : nil) }
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

    func clearDropIndicator() { dropIndicator.isHidden = true }
    private func showDropIndicator(item: Any?, index: Int) {
        let items = children(of: item)
        let row: Int
        if index == NSOutlineViewDropOnItemIndex, let item { row = outline.row(forItem: item) + 1 }
        else if items.indices.contains(index) { row = outline.row(forItem: items[index]) }
        else if let last = items.last { row = outline.row(forItem: last) + 1 }
        else { row = 0 }
        let y = row < outline.numberOfRows ? outline.rect(ofRow: max(0, row)).minY
            : (outline.numberOfRows > 0 ? outline.rect(ofRow: outline.numberOfRows - 1).maxY : 0)
        dropIndicator.frame = CGRect(x: 8, y: y - 4, width: max(0, outline.bounds.width - 16), height: 8)
        dropIndicator.isHidden = false
        outline.addSubview(dropIndicator, positioned: .above, relativeTo: nil)
        dropIndicator.needsDisplay = true
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        context.suppressPreviews(.drag, true)
        guard let dest = dropDestination(item: item, childIndex: index) else { clearDropIndicator(); return [] }
        if let r = dest.retarget { outlineView.setDropItem(r.0, dropChildIndex: r.1) }
        if let ids = SidebarPasteboard.nodeIDs(from: info.draggingPasteboard) {
            let allowed = context.acceptsNodeDrop(ids: ids, to: dest.parent, index: dest.index)
            if allowed {
                context.haptics.insertionChanged(parent: dest.parent, index: dest.index)
                let target = dest.retarget ?? (item, index)
                showDropIndicator(item: target.0, index: target.1)
            } else { clearDropIndicator() }
            return allowed ? .move : []
        }
        guard !SidebarPasteboard.urls(from: info.draggingPasteboard).isEmpty else { clearDropIndicator(); return [] }
        let target = dest.retarget ?? (item, index)
        showDropIndicator(item: target.0, index: target.1)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        defer { context.suppressPreviews(.drag, false); clearDropIndicator() }
        guard let dest = dropDestination(item: item, childIndex: index) else { return false }
        if let ids = SidebarPasteboard.nodeIDs(from: info.draggingPasteboard) {
            let accepted = context.performNodeDrop(ids: ids, to: dest.parent, index: dest.index)
            context.haptics.dropped(accepted)
            return accepted
        }
        guard let url = SidebarPasteboard.urls(from: info.draggingPasteboard).first else { return false }
        return context.send(.openURL(url, in: dest.parent, index: dest.index))
    }

}

/// Outline view that lets row buttons take clicks and builds context menus.
@MainActor
final class SidebarOutlineView: NSOutlineView {
    weak var page: SpacePageView?
    fileprivate(set) var keyboardItem: AnyObject?
    var didActivateMouseDown = false
    var dragWasStarted = false
    var trackingMouseDown = false

    override func noteHeightOfRows(withIndexesChanged indexes: IndexSet) {
        SidebarDiagnostics.countFolderWork("note-height-calls")
        if SidebarDiagnostics.measuresFolderTransitions { SidebarDiagnostics.folderBenchCounters["noted-heights", default: 0] += indexes.count }
        super.noteHeightOfRows(withIndexesChanged: indexes)
    }
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
        trackingMouseDown = true
        defer {
            trackingMouseDown = false
            if !dragWasStarted { page?.syncSelectionIndexes() }
        }
        keyboardItem = nil
        didActivateMouseDown = false
        dragWasStarted = false
        let pressedRow = row(at: convert(event.locationInWindow, from: nil))
        let pressedItem = pressedRow >= 0 ? item(atRow: pressedRow) : nil
        let pressedControl: NSView? = {
            guard pressedRow >= 0, let row = rowView(atRow: pressedRow, makeIfNecessary: false), let parent = row.superview else { return nil }
            var hit = row.hitTest(parent.convert(event.locationInWindow, from: nil))
            while let view = hit, view !== row {
                if view is PlateButton || view is NSControl { return view }
                hit = view.superview
            }
            return nil
        }()
        if let pressedControl { pressedControl.mouseDown(with: event); return }
        if let page {
            page.context.manager?.activate(page.space)
            let row = row(at: convert(event.locationInWindow, from: nil))
            if row >= 0, let item = item(atRow: row), page.modifySelection(item: item, modifiers: event.modifierFlags) {
                window?.makeFirstResponder(self)
                return
            }
            if row < 0 || itemID(of: item(atRow: row)).map({ page.context.selection.contains($0) }) != true {
                page.context.selection.clear()
            }
            page.syncSelectionIndexes()
        }
        page?.updateRowStates(animated: false)
        super.mouseDown(with: event)
        // AppKit can omit its action for a row that was already in the mirrored
        // native selection. Preserve drag tracking, then handle a plain release.
        if !didActivateMouseDown, !dragWasStarted, pressedControl == nil, let pressedItem {
            if event.clickCount >= 2 { page?.beginRename(item: pressedItem as AnyObject) }
            else { page?.activate(item: pressedItem) }
        }
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        page?.clearDropIndicator()
        page?.context.suppressPreviews(.drag, false)
        super.draggingEnded(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        page?.clearDropIndicator()
        page?.context.haptics.endDrag()
        page?.context.suppressPreviews(.drag, false)
        super.draggingExited(sender)
    }

    /// Capture rows before removal, including all neighbors so expanded children and
    /// other members of a batch delete can be skipped once the delete completes.
    func keyboardFocusAfterDeletion() -> @MainActor () -> Void {
        guard let focused = keyboardItem, keyboardItemIsAvailable(focused) else { return {} }
        let current = row(forItem: focused)
        let rows = Array((current + 1)..<numberOfRows) + Array((0..<current).reversed())
        let candidates = rows.compactMap { item(atRow: $0) as AnyObject? }
        return { [weak self, weak focused] in
            guard let self, let focused, self.keyboardItem === focused,
                  !self.keyboardItemIsAvailable(focused) else { return }
            self.keyboardItem = candidates.first(where: self.keyboardItemIsAvailable)
            if let next = self.keyboardItem { self.scrollRowToVisible(self.row(forItem: next)) }
            self.page?.updateRowStates(animated: false)
        }
    }

    private func keyboardItemIsAvailable(_ item: AnyObject) -> Bool {
        guard let page, page.context.model.space(id: page.space.id) === page.space,
              row(forItem: item) >= 0 else { return false }
        if let id = itemID(of: item) { return page.context.model.node(id: id)?.object === item }
        return item is NewTabItem || item is LiveFolderMoreItem
    }

    override func keyDown(with event: NSEvent) {
        guard let page, page.context.model.space(id: page.space.id) === page.space else { keyboardItem = nil; return }
        if let item = keyboardItem, !keyboardItemIsAvailable(item) {
            keyboardItem = nil
            if [36, 49, 76, 51, 117, 123, 124].contains(event.keyCode) {
                page.updateRowStates(animated: false)
                return
            }
        }
        if event.keyCode == 53 { page.context.existingHoverPreviews?.dismiss() }
        page.context.manager?.activate(page.space)
        if !page.context.selection.isEmpty, event.modifierFlags.intersection([.control, .option]).isEmpty {
            if event.modifierFlags.contains(.command) {
                if event.keyCode == 2, !event.modifierFlags.contains(.shift) { _ = page.context.performSelectionCommand("pin-unpin-tab"); return }
                if event.keyCode == 45, event.modifierFlags.contains(.shift) { _ = page.context.performSelectionCommand("new-folder"); return }
            } else if event.keyCode == 51 || event.keyCode == 117 {
                let restoreKeyboardFocus = keyboardFocusAfterDeletion()
                _ = page.context.deleteSelection()
                restoreKeyboardFocus()
                return
            }
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        let rows = (0..<numberOfRows).filter { itemID(of: item(atRow: $0)) != nil || item(atRow: $0) is NewTabItem || item(atRow: $0) is LiveFolderMoreItem }
        let current = keyboardItem.map { row(forItem: $0) } ?? -1
        switch event.keyCode {
        case 125, 126: // Down, Up: focus only, leaving selection in the model.
            let extending = event.modifierFlags.contains(.shift)
            let selection = page.context.selection
            var from = current
            let candidates = extending ? rows.filter { itemID(of: item(atRow: $0)) != nil } : rows
            if extending {
                if from < 0, let id = selection.anchor, let object = page.context.model.node(id: id)?.object { from = row(forItem: object) }
                if from < 0, let id = page.context.selectedID(in: page.space.id), let object = page.context.model.node(id: id)?.object { from = row(forItem: object) }
                if from < 0 { from = candidates.first ?? -1 }
                if selection.isEmpty, let id = itemID(of: item(atRow: from)) { selection.select([id], anchor: id) }
            } else { selection.clear() }
            let next = event.keyCode == 125 ? candidates.first(where: { $0 > from }) : candidates.last(where: { $0 < (from < 0 ? numberOfRows : from) })
            if let next { keyboardItem = item(atRow: next) as AnyObject?; scrollRowToVisible(next) }
            if extending, let id = itemID(of: keyboardItem) { selection.extend(to: id, order: page.selectableOrder) }
        case 53: // Escape
            page.context.selection.clear()
        case 36, 49, 76: // Return, Space, keypad Enter
            if let keyboardItem { page.activate(item: keyboardItem) }
        case 123, 124: // Left, Right
            if let folder = keyboardItem as? Folder {
                page.context.send(.setExpanded(folderID: folder.id, expanded: event.keyCode == 124))
            }
        case 51, 117: // Delete, forward Delete: archive a focused tab.
            if let id = itemID(of: keyboardItem) {
                let restoreKeyboardFocus = keyboardFocusAfterDeletion()
                page.context.send(keyboardItem is Folder ? .deleteFolder(folderID: id) : .close(nodeID: id))
                restoreKeyboardFocus()
            }
        default: super.keyDown(with: event); return
        }
        page.updateRowStates(animated: false)
    }

    override func accessibilityRows() -> [any NSAccessibilityRow]? {
        (0..<numberOfRows).compactMap { row -> NSTableRowView? in
            guard itemID(of: item(atRow: row)) != nil || item(atRow: row) is NewTabItem || item(atRow: row) is LiveFolderMoreItem else { return nil }
            return rowView(atRow: row, makeIfNecessary: true)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        page?.context.isOptionHeld = event.modifierFlags.contains(.option)
        super.flagsChanged(with: event)
    }

    override func accessibilityChildren() -> [Any]? { accessibilityRows()?.map { $0 as Any } }

    override func reloadData() {
        SidebarDiagnostics.fullReloads += 1
        super.reloadData()
    }

    override func insertItems(at indexes: IndexSet, inParent parent: Any?, withAnimation animationOptions: NSTableView.AnimationOptions) {
        SidebarDiagnostics.outlineItemUpdates += 1
        SidebarDiagnostics.outlineItemsInserted += indexes.count
        super.insertItems(at: indexes, inParent: parent, withAnimation: animationOptions)
    }

    override func removeItems(at indexes: IndexSet, inParent parent: Any?, withAnimation animationOptions: NSTableView.AnimationOptions) {
        SidebarDiagnostics.outlineItemUpdates += 1
        SidebarDiagnostics.outlineItemsRemoved += indexes.count
        super.removeItems(at: indexes, inParent: parent, withAnimation: animationOptions)
    }

    override func moveItem(at fromIndex: Int, inParent oldParent: Any?, to toIndex: Int, inParent newParent: Any?) {
        SidebarDiagnostics.outlineItemUpdates += 1
        super.moveItem(at: fromIndex, inParent: oldParent, to: toIndex, inParent: newParent)
    }

    override func reloadItem(_ item: Any?, reloadChildren: Bool) {
        SidebarDiagnostics.outlineItemUpdates += 1
        super.reloadItem(item, reloadChildren: reloadChildren)
    }

    override func noteNumberOfRowsChanged() {
        SidebarDiagnostics.outlineItemUpdates += 1
        super.noteNumberOfRowsChanged()
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is PlateButton || responder is RenameField || responder is DividerCellView { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        page?.context.isOptionHeld = event.modifierFlags.contains(.option)
        return page?.menu(at: convert(event.locationInWindow, from: nil))
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
    /// Space title role (`SidebarRoles.spaceTitle`; raised with Increase Contrast).
    var spaceTitleColor: NSColor { context.roles(for: space).spaceTitle.nsColor }
    weak var page: SpacePageView?
    private let fill = CALayer()
    private let title = TextLabel()
    var displayedTitle: String { title.text() }
    private let icon = SpaceIconView()
    var iconFrameInWindow: CGRect { icon.convert(icon.bounds, to: nil) }
    let chevron = PlateButton(glyph: .disclosureDown)
    let more = PlateButton(glyph: .spaceMore)
    /// Blank Window header "Move to…" (C-report-s11 1(a): AX button "Move to...", small grey text at
    /// the header's right). GUESS: its menu lists the browser's Spaces and moves all of this
    /// window's tabs there (capture item C-NT6); the look (11 pt semibold, 55 % title colour) is
    /// read from the frame `v7/e1b-drag-back/e2-hold.png`.
    private(set) lazy var moveTo: NSButton = {
        let button = NSButton(title: "Move to…", target: self, action: #selector(showMoveToMenu(_:)))
        button.isBordered = false
        button.setAccessibilityLabel("Move to...")
        return button
    }()
    let profileIndicator: ProfileIndicatorButton
    var pointerInside = false { didSet { if pointerInside != oldValue { needsDisplay = true; needsLayout = true } } }

    init(context: SidebarContext, space: Space) {
        self.context = context
        self.space = space
        profileIndicator = ProfileIndicatorButton(context:context,space:space)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        fill.cornerCurve = .continuous
        fill.opacity = 0
        layer?.addSublayer(fill)
        icon.space = space
        icon.context = context
        if context.isIncognito { icon.setAccessibilityElement(true); icon.setAccessibilityRole(.image); icon.setAccessibilityLabel("eyeglasses") }
        title.font = Typography.spaceTitle.font
        title.baseline = SpaceListMetrics.headerTitleBaselineOffset
        title.inset = SpaceListMetrics.headerTextInset
        title.text = { [unowned context, space] in context.title(of: space) }
        title.color = { [weak self] in self?.spaceTitleColor ?? SidebarRole.spaceTitle.nsColor }
        chevron.accessibleTitle = { [weak space] in space?.isPinnedCollapsed == true ? "Expand Pinned" : "Collapse Pinned" }
        more.setAccessibilityLabel("Space options")
        chevron.showsHoverPlate = false
        chevron.glyphTint = { [weak self] _ in self?.spaceTitleColor ?? SidebarRole.spaceTitle.nsColor }
        chevron.action = { [unowned context, space] in context.send(.setPinnedCollapsed(space: space.id, collapsed: !space.isPinnedCollapsed)) }
        more.glyphTint = { [weak self] _ in self?.spaceTitleColor ?? SidebarRole.spaceTitle.nsColor }
        more.menuProvider = { [weak self] in self?.page.map { $0.menus.space($0.space) } }
        profileIndicator.menuProvider = { [weak self] in self?.page.map { $0.menus.profile($0.space) } }
        chevron.context = context
        more.context = context
        addSubview(icon); addSubview(title); addSubview(chevron); addSubview(more); addSubview(profileIndicator)
        if context.isWindowOnly { addSubview(moveTo) }
    }

    /// The Spaces of the browser; choosing one moves every tab of this window there (top first).
    func moveToMenu() -> NSMenu {
        let menu = NSMenu(title: "Move to")
        let ids = space.today.flatMap { node -> [ItemID] in
            switch node { case .tab(let tab): [tab.id]; case .split(let split): split.panes.map(\.id); case .folder: [] }
        }
        for target in context.windowOnlyMoveSpaces?() ?? [] {
            menu.addItem(ClosureMenuItem(target.title) { [weak self] in
                // Bottom first: each tab lands on top of the Space's Today list, so the order stays.
                for id in ids.reversed() { _ = self?.context.send(.moveToSpace(nodeID: id, space: target.id)) }
            })
        }
        return menu
    }

    @objc private func showMoveToMenu(_ sender: NSButton) {
        moveToMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    private var isHovered: Bool {
        if let forced = context.forcedHover { return forced == .header }
        return pointerInside
    }
    var isHeaderHovered: Bool { isHovered }
    var titleLabel: TextLabel { title }

    override func updateLayer() {
        let hovered = tracked({ isHovered }) { [weak self] in self?.needsDisplay = true; self?.needsLayout = true }
        CATransaction.begin()
        CATransaction.setDisableActions(!context.animatesChanges)
        fill.backgroundColor = context.roles(for: space).rowHover.cgColor
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
        // GUESS (C10 has no close-up): a Blank Window's header shows the title only, no Space icon.
        icon.isHidden = context.isWindowOnly || (hovered && !context.isIncognito)
        chevron.isHidden = !hovered || context.hidesSpaceChrome
        chevron.glyphView.glyph = space.isPinnedCollapsed ? .disclosureRight : .disclosureDown
        let s = m.headerMoreSize
        more.frame = CGRect(x: w - m.headerMoreTrailing - s, y: (m.headerHeight - s) / 2, width: s, height: s)
        more.isHidden = !hovered || context.hidesSpaceChrome
        var right = hovered ? more.frame.minX - 2 : w - 17
        if context.isWindowOnly {
            let color = spaceTitleColor.withAlphaComponent(0.55)
            moveTo.attributedTitle = NSAttributedString(string: "Move to…", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color])
            let size = moveTo.attributedTitle.size()
            moveTo.frame = CGRect(x: w - m.headerMoreTrailing - ceil(size.width), y: (m.headerHeight - ceil(size.height)) / 2,
                                  width: ceil(size.width), height: ceil(size.height))
            right = moveTo.frame.minX - 6
        }
        let hasProfiles = tracked({ !context.hidesSpaceChrome && context.model.profiles.count > 1 }) { [weak self] in self?.needsLayout=true }
        profileIndicator.isHidden = !hasProfiles
        if hasProfiles {
            let size = ProfileIndicatorMetrics.hitSize
            profileIndicator.frame = CGRect(x:right-size,y:(m.headerHeight-size)/2,width:size,height:size)
            right -= size + ProfileIndicatorMetrics.gap
        }
        title.frame = CGRect(x: m.headerTitleX, y: m.headerTitleY, width: max(0, right - m.headerTitleX), height: 18)
    }

    override func menu(for event: NSEvent) -> NSMenu? { context.hidesSpaceChrome ? nil : page.map { $0.menus.space($0.space) } }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginRename() }
    }

    func beginRename() {
        guard !context.hidesSpaceChrome else { return }
        page?.revealsHeaderForRename = true
        superview?.layoutSubtreeIfNeeded()
        context.suppressPreviews(.rename, true)
        let field = RenameField(frame: title.frame.insetBy(dx: -2, dy: -1))
        field.stringValue = context.title(of: space)
        field.font = title.font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = self.spaceTitleColor
        let id = space.id
        field.onEnd = { [weak self, weak field] value in
            field?.removeFromSuperview()
            self?.title.isHidden = false
            self?.page?.revealsHeaderForRename = false
            self?.context.suppressPreviews(.rename, false)
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
    private var spaceTitleColor: NSColor {
        guard let context, let space else { return SidebarRole.spaceTitle.nsColor }
        return context.roles(for: space).spaceTitle.nsColor
    }
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
        case .named(let name)?:
            drawSymbol(NamedSpaceIcons.symbolName(for: name))
        case .symbol(let name)? where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil:
            // Arc's own named icons (for example "planet" on the default Space) have no SF Symbol.
            CustomIcon.planet(in: NSRect(x: bounds.midX - emojiSize / 2, y: bounds.midY - emojiSize / 2, width: emojiSize, height: emojiSize),
                              color: self.spaceTitleColor)
        case .symbol(let name)?:
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: emojiSize * 0.8, weight: .medium)) {
                let s = img.size
                img.drawTinted(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height),
                               color: self.spaceTitleColor)
            }
        case nil:
            // Arc draws a planet-like mark for Spaces without an icon (F0079); ours is drawn in code.
            CustomIcon.planet(in: NSRect(x: bounds.midX - emojiSize / 2, y: bounds.midY - emojiSize / 2, width: emojiSize, height: emojiSize),
                              color: self.spaceTitleColor)
        }
    }

    private func drawSymbol(_ name: String) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: emojiSize * 0.8, weight: .medium)) else { return }
        let size = image.size
        image.drawTinted(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                   width: size.width, height: size.height), color: self.spaceTitleColor)
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
