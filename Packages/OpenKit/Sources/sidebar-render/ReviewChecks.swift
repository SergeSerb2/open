import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// Event fixtures feed the real offscreen AppKit destinations. No desktop input,
/// substitute views, model commands, or production data are used.
@MainActor
final class SidebarDragEvent: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy] }
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(ids: [ItemID], window: NSWindow) {
        draggingDestinationWindow = window
        super.init()
        let items = ids.map { id in
            let item = NSPasteboardItem()
            item.setString(id.description, forType: .init("com.open.sidebar.node"))
            return item
        }
        draggingPasteboard.writeObjects(items)
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
            var stop = ObjCBool(false)
            block(NSDraggingItem(pasteboardWriter: item), index, &stop)
            if stop.boolValue { break }
        }
    }
}

@MainActor
enum ReviewChecks {
    static func run() {
        let model = Synthetic.model()
        let state = model.windows[0]
        let context = SidebarContext(model: model, windowID: state.id)
        let delegate = RecordingDelegate()
        var options = RenderScene.Options()
        options.size = CGSize(width: 1000, height: 1100)
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        let sidebar = scene.sidebar
        let space = model.spaces[0], target = model.spaces[1], profile = model.profiles[0]
        func pump() { OffscreenRenderer.settle(scene, runLoop: 0.01) }
        let check = Checks.check
        let folder = model.createFolder(in: .spacePinned(space.id), title: "Parent")!
        let child = model.createFolder(in: .folder(folder.id), title: "Child")!
        let grandchild = model.createFolder(in: .folder(child.id), title: "Grandchild")!
        let a = model.newTab(in: space.id, url: Synthetic.url("a"), title: "Pane A")
        let b = model.newTab(in: space.id, url: Synthetic.url("b"), title: "Pane B")
        let split = model.makeSplit(tabIDs: [a.id, b.id])!
        pump()
        let outline = sidebar.focusedOutline!
        let data = outline.dataSource!
        func validate(_ id: ItemID, folder: Folder? = nil, index: Int = 1) -> NSDragOperation {
            let event = SidebarDragEvent(ids: [id], window: host)
            return data.outlineView?(outline, validateDrop: event, proposedItem: folder, proposedChildIndex: folder == nil ? index : NSOutlineViewDropOnItemIndex) ?? []
        }
        func accept(_ id: ItemID, folder: Folder? = nil, index: Int = 1) -> Bool {
            let event = SidebarDragEvent(ids: [id], window: host)
            return data.outlineView?(outline, acceptDrop: event, item: folder, childIndex: folder == nil ? index : NSOutlineViewDropOnItemIndex) ?? false
        }
        print("review: drop feedback and actual command results")
        check(validate(folder.id, folder: folder).isEmpty, "outline rejects a folder into itself")
        check(validate(folder.id, folder: grandchild).isEmpty, "outline rejects a folder into its descendant")
        check(!accept(folder.id, folder: grandchild), "illegal acceptDrop returns false from the model")
        check(validate(a.id).isEmpty && !accept(a.id), "outline rejects split-pane sources")
        check(validate(split.id, folder: child) == .move, "outline permits a split inside a folder")
        let cv = sidebar.favoritesCollection
        func validateFavorite(_ id: ItemID) -> NSDragOperation {
            let event = SidebarDragEvent(ids: [id], window: host)
            var proposed = NSIndexPath(index: 0)
            var operation = NSCollectionView.DropOperation.before
            return cv.delegate?.collectionView?(cv, validateDrop: event, proposedIndexPath: &proposed, dropOperation: &operation) ?? []
        }
        func acceptFavorite(_ id: ItemID) -> Bool {
            cv.delegate?.collectionView?(cv, acceptDrop: SidebarDragEvent(ids: [id], window: host), indexPath: IndexPath(item: 0, section: 0), dropOperation: .before) ?? false
        }
        check([folder.id, split.id, a.id].allSatisfy { validateFavorite($0).isEmpty && !acceptFavorite($0) }, "Favorites rejects folders, splits, and split panes in validation and acceptance")
        let pinned = space.pinned.compactMap(\.tab)[0]
        delegate.refuses = true
        check(!accept(pinned.id) && !acceptFavorite(pinned.id), "drop handlers propagate a delegate refusal")
        delegate.refuses = false
        check(accept(pinned.id, folder: child), "legal drop reaches the model")
        pump()
        check(model.parent(of: pinned.id) == .folder(child.id) && model.isPinned(tabID: pinned.id), "pinned ancestry stays pinned after a folder drop")

        print("review: accessibility dump (NSAccessibility APIs, synthetic titles)")
        func axRows() -> [NSView] { (outline.accessibilityRows() ?? []).compactMap { $0 as? NSView } }
        let rows = axRows()
        for row in rows {
            print("  AX \(row.accessibilityRole()?.rawValue ?? "nil") | \(row.accessibilityLabel() ?? "nil") | expanded=\(row.isAccessibilityExpanded())")
        }
        check(rows.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button && !($0.accessibilityLabel() ?? "").isEmpty }, "all exposed outline rows are named AX buttons")
        check(rows.contains { $0.accessibilityLabel() == "Split View: Pane A, Pane B" }, "split AX label names both panes")
        check(rows.contains { $0.accessibilityLabel() == "Parent" && $0.isAccessibilityExpanded() }, "folder AX exposes its title and expanded state")
        let tiles = profile.favorites.indices.compactMap { cv.item(at: IndexPath(item: $0, section: 0))?.view }
        for tile in tiles { print("  AX \(tile.accessibilityRole()?.rawValue ?? "nil") | \(tile.accessibilityLabel() ?? "nil")") }
        check(tiles.count == profile.favorites.count && tiles.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button && !($0.accessibilityLabel() ?? "").isEmpty }, "every favorite tile is a named AX button")
        func buttons(_ view: NSView) -> [NSView] {
            var result = view.subviews.flatMap(buttons)
            if view.isAccessibilityElement() && view.accessibilityRole() == .button && !view.isHidden { result.append(view) }
            return result
        }
        let allButtons = buttons(sidebar)
        check(allButtons.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty }, "all visible PlateButtons have AX labels")
        check(tiles.first?.accessibilityPerformPress() == true && state.selectedNodeBySpace[space.id] == profile.favorites[0].id, "favorite AX press selects the actual model tab")

        print("review: keyboard events → real outline → delegate → model")
        host.makeFirstResponder(outline)
        func key(_ code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            host.firstResponder?.keyDown(with: event)
            pump()
        }
        let firstTab = space.pinned.compactMap(\.tab)[0]
        let selectedBefore = state.selectedNodeBySpace[space.id]
        key(125)
        check(axRows().filter { $0.isAccessibilityFocused() }.count == 1, "Down exposes one keyboard focus ring through AX")
        check(state.selectedNodeBySpace[space.id] == selectedBefore, "Down moves keyboard focus without selecting")
        key(36)
        check(state.selectedNodeBySpace[space.id] == firstTab.id, "Return selects the focused tab")
        key(125); key(49)
        let secondTab = space.pinned.compactMap(\.tab)[1]
        check(state.selectedNodeBySpace[space.id] == secondTab.id, "Space selects the next focused tab")
        key(126); key(36)
        check(state.selectedNodeBySpace[space.id] == firstTab.id, "Up moves focus back")
        key(51)
        check(model.tab(id: firstTab.id) == nil, "Delete archives the focused tab through the model")
        // Move focus to the parent folder, then test collapse and expand.
        let firstFolderIndex = sidebar.displayedRows.firstIndex(of: folder.id.description)!
        for _ in 0..<max(0, firstFolderIndex - 1) { key(125) }
        key(123)
        check(!folder.isExpanded && !outline.isItemExpanded(folder), "Left collapses the focused folder")
        check(axRows().contains { $0.accessibilityLabel() == "Parent" && !$0.isAccessibilityExpanded() }, "folder AX expanded state updates after keyboard collapse")
        key(124)
        check(folder.isExpanded && outline.isItemExpanded(folder), "Right expands the focused folder")
        key(36)
        check(!folder.isExpanded, "Return activates a focused folder")

        print("review: tooltip delay stays armed across pointer movement")
        // Today rows keep title tooltips while pinned rows now own Hover Previews.
        let tooltipTab = space.today.compactMap(\.tab).first!
        sidebar.reveal(nodeID: tooltipTab.id)
        pump()
        let page = outline.enclosingScrollView!.superview!
        let rect = outline.rect(ofRow: outline.row(forItem: tooltipTab))
        let point = outline.convert(NSPoint(x: 60, y: rect.midY), to: nil)
        let tooltip = TooltipController.shared
        let schedules = tooltip.scheduleCount, shows = tooltip.showCount
        for i in 0..<16 {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: point.offsetBy(dx: CGFloat(i % 3), dy: 0), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 0, pressure: 0)!
            page.mouseMoved(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(tooltip.scheduleCount - schedules == 1 && tooltip.showCount - shows == 1, "same Today row and tooltip schedule and show once during continuous movement")

        print("review: mixed Favorites reload batches")
        var seed: UInt64 = 0x332026
        func random(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        SidebarDiagnostics.forceAnimations = true
        var batchesOK = true
        for iteration in 0..<32 {
            var next = profile.favorites
            next.remove(at: random(next.count))
            next.remove(at: random(next.count))
            for i in stride(from: next.count - 1, through: 1, by: -1) { next.swapAt(i, random(i + 1)) }
            for j in 0..<2 {
                let tab = Tab(url: Synthetic.url("batch\(iteration)-\(j)"), title: "Batch \(iteration) item \(j)")
                next.insert(tab, at: random(next.count + 1))
            }
            profile.favorites = next
            model.rebuildIndex()
            sidebar.reloadFavorites() // The actual .reload handler receives the full mixed plan.
            pump()
            let labels = next.indices.map { cv.item(at: IndexPath(item: $0, section: 0))?.view.accessibilityLabel() }
            let countsOK = cv.numberOfItems(inSection: 0) == next.count
            let idsOK = sidebar.displayedFavorites == next.map(\.id)
            let labelsOK = labels == next.map { Optional($0.displayTitle) }
            if !countsOK || !idsOK || !labelsOK {
                print("  batch \(iteration): count=\(countsOK) ids=\(idsOK) labels=\(labelsOK) shown=\(labels) wanted=\(next.map(\.displayTitle))")
            }
            batchesOK = batchesOK && countsOK && idsOK && labelsOK
        }
        SidebarDiagnostics.forceAnimations = false
        check(batchesOK, "32 seeded multi-permutation + insert + delete reloads match collection counts, tile order, and model IDs")

        print("review: spring-loaded cross-Space drag")
        let switcher = sidebar.spaceSwitcher(spaceID: target.id)!
        let today1 = model.newTab(in: space.id, url: Synthetic.url("drag1"), title: "Drag Today 1")
        let today2 = model.newTab(in: space.id, url: Synthetic.url("drag2"), title: "Drag Today 2")
        let sourcePinned = space.pinned.compactMap(\.tab)[0]
        pump()
        let drag = SidebarDragEvent(ids: [today1.id, sourcePinned.id, today2.id], window: host)
        check(switcher.registeredDraggedTypes.contains(.init("com.open.sidebar.node")), "Space icon registers the sidebar drag type")
        check(switcher.draggingEntered(drag) == .move, "Space icon accepts a legal multi-tab drag")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        check(context.focusedSpace === space, "spring loading waits before switching")
        _ = switcher.draggingUpdated(drag)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        pump()
        check(context.focusedSpace === target, "hover switches Space after 0.5 seconds despite drag updates")
        check(switcher.performDragOperation(drag), "dropping on the Space icon succeeds")
        pump()
        check(Array(target.today.prefix(2).map(\.id)) == [today1.id, today2.id] && target.pinned.first?.id == sourcePinned.id, "multi-tab drop keeps order at Today top and preserves the pinned section")
        check(today1.pinnedURL == nil && sourcePinned.pinnedURL != nil, "cross-Space drop preserves Today and Pinned URL rules")
        let illegal = SidebarDragEvent(ids: [a.id], window: host)
        check(switcher.draggingEntered(illegal).isEmpty && !switcher.performDragOperation(illegal), "Space icon rejects a split pane")
        let missing = SidebarDragEvent(ids: [ItemID()], window: host)
        check(switcher.draggingEntered(missing).isEmpty && !switcher.performDragOperation(missing), "Space icon rejects a stale source")
        let back = sidebar.spaceSwitcher(spaceID: space.id)!
        let returnDrag = SidebarDragEvent(ids: [today1.id], window: host)
        _ = back.draggingEntered(returnDrag)
        back.draggingExited(returnDrag)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        check(context.focusedSpace === target, "leaving a Space icon cancels spring loading")
        delegate.refuses = true
        check(!back.performDragOperation(returnDrag), "Space drop propagates delegate refusal")
        delegate.refuses = false

        print("review: theme rebuild count across 120 resize steps")
        let before = scene.background.fieldRebuildCount
        scene.background.viewWillStartLiveResize()
        for step in 0..<120 {
            scene.background.frame.size = CGSize(width: 1000 + step * 3, height: 1100 - step * 2)
            scene.background.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        check(scene.background.fieldRebuildCount == before, "live resize performs no theme field rebuilds")
        scene.background.viewDidEndLiveResize()
        pump()
        let rebuilds = scene.background.fieldRebuildCount - before
        check(rebuilds >= 1 && rebuilds <= 2, "120 resize steps cause \(rebuilds) theme rebuild(s), limit 2")
        host.contentView = nil
        host.close()

        print("review: teardown with queued observations")
        weak var released: SidebarView?
        autoreleasepool {
            var transient: RenderScene? = RenderScene(context: SidebarContext(model: model, windowID: state.id), options: options, delegate: delegate)
            released = transient?.sidebar
            let transientHost = OffscreenRenderer.host(transient!, scale: 1)
            model.focusSpace(windowID: state.id, spaceID: space.id)
            profile.favorites.append(Tab(url: Synthetic.url("teardown"), title: "Teardown"))
            transientHost.contentView = nil
            transient = nil
            transientHost.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(released == nil, "sidebar, favorites, and pager release safely with queued observation work")
    }
}

private extension NSPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> NSPoint { NSPoint(x: x + dx, y: y + dy) }
}
