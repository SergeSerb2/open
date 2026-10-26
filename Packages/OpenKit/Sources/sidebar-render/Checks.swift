import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// End-to-end checks of the real sidebar view stack in an offscreen window:
/// model commands reach the views as animated diffs, clicks and swipes reach
/// the delegate as intents, menus and drop targets map to model commands.
/// Prints OK or FAIL per check; exits non-zero on any failure.
@MainActor
enum Checks {
    static var failures = 0
    static var passes = 0

    static func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1 } else { failures += 1 }
        print("  \(ok ? "OK  " : "FAIL") \(what)")
    }

    /// Display rows the outline should show for the focused Space.
    static func expectedRows(context: SidebarContext) -> [String] {
        guard let space = context.focusedSpace else { return [] }
        var r = ["spacer"]
        func walk(_ nodes: [SidebarNode]) {
            for n in nodes {
                r.append(n.id.description)
                if case .folder(let f) = n, f.isExpanded { walk(f.children) }
            }
        }
        if !space.isPinnedCollapsed { walk(space.pinned) }
        if !space.today.isEmpty { r.append("divider") }
        r.append("newTab")
        walk(space.today)
        return r
    }

    static func run(_ args: [String]) throws {
        let model = Synthetic.model()
        model.rebuildIndex()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        guard let window = model.windows.first else { return }
        let context = SidebarContext(model: model, windowID: window.id)
        let delegate = RecordingDelegate()
        var options = RenderScene.Options()
        options.size = CGSize(width: 1000, height: 900)
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        let sidebar = scene.sidebar
        func pump() { OffscreenRenderer.settle(scene, runLoop: 0.02) }
        func rowsMatch(_ what: String) {
            let shown = sidebar.displayedRows, want = expectedRows(context: context)
            var detail = ""
            if shown != want {
                let i = zip(shown, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(shown.count, want.count)
                detail = " — shown \(shown.count) rows, model \(want.count), first difference at row \(i): \(shown.indices.contains(i) ? String(shown[i].prefix(8)) : "-") vs \(want.indices.contains(i) ? String(want[i].prefix(8)) : "-")"
            }
            check(shown == want, "rows match the model: \(what)\(detail)")
        }
        let space = model.spaces[0]
        let reloads0 = SidebarDiagnostics.fullReloads

        print("structure (model → TreeChange → outline diff)")
        rowsMatch("first build")
        // Arc puts a new Today tab at the top, right under "New Tab" (F0041).
        let t = model.newTab(in: space.id, url: URL(string: "https://new.example.com")!, title: "Fresh", at: 0)
        pump(); rowsMatch("newTab at the top of Today")
        check(sidebar.displayedRows.firstIndex(of: "newTab").map { sidebar.displayedRows[$0 + 1] } == t.id.description, "new tab sits right under New Tab")
        model.pinTab(id: t.id)
        pump(); rowsMatch("pinTab moves it to Pinned")
        model.moveNode(id: t.id, to: .spacePinned(space.id), at: 0)
        pump(); rowsMatch("moveNode to the top of Pinned")
        let folder = model.createFolder(in: .spacePinned(space.id), title: "Group", withNodes: [t.id])!
        pump(); rowsMatch("createFolder with one tab")
        model.setExpanded(folderID: folder.id, expanded: false)
        OffscreenRenderer.settle(scene, runLoop: 0.15); rowsMatch("folder collapsed (animated)")
        model.setExpanded(folderID: folder.id, expanded: true)
        OffscreenRenderer.settle(scene, runLoop: 0.15); rowsMatch("folder expanded (animated)")
        let today = space.today.compactMap(\.tab)
        if today.count >= 2, let split = model.makeSplit(tabIDs: [today[0].id, today[1].id]) {
            pump(); rowsMatch("makeSplit of two Today tabs")
            model.unsplit(splitID: split.id)
            pump(); rowsMatch("unsplit")
        }
        model.closeTab(id: t.id)
        pump(); rowsMatch("closeTab inside the folder")
        undo.undo()
        pump(); rowsMatch("undo of the close")
        model.clearToday(space: space.id)
        pump(); rowsMatch("clearToday removes Today and the divider")
        check(!sidebar.displayedRows.contains("divider"), "no divider without Today tabs")
        undo.undo()
        pump(); rowsMatch("undo of clearToday brings the divider back")
        check(SidebarDiagnostics.fullReloads == reloads0, "no full reloads during edits (reloadData calls: \(SidebarDiagnostics.fullReloads - reloads0))")

        print("favorites")
        let profile = model.profiles[0]
        let fav = space.today.first!.tab!
        model.addFavorite(tabID: fav.id, to: profile.id, at: 1)
        pump(); check(sidebar.displayedFavorites == profile.favorites.map(\.id), "addFavorite shows a 7th tile at index 1")
        rowsMatch("the tab left Today")
        model.removeFavorite(tabID: fav.id, into: space.id)
        pump(); check(sidebar.displayedFavorites == profile.favorites.map(\.id), "removeFavorite removes the tile")

        print("clicks (window events → outline action → delegate intent → model)")
        // The window is never shown, so it never becomes key; deliver the press to
        // the hit-tested view as AppKit would after first-mouse handling. The mouse-up
        // waits in the event queue for the view's own tracking loop.
        func click(_ p: NSPoint, count: Int = 1) {
            let wp = scene.convert(p, to: nil)
            let now = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: wp, modifierFlags: [], timestamp: now, windowNumber: host.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: wp, modifierFlags: [], timestamp: now + 0.01, windowNumber: host.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: count, pressure: 0)!
            // hitTest takes a point in the superview's space: window coordinates for the content view.
            guard let target = host.contentView?.hitTest(wp) else { return }
            NSApp.postEvent(up, atStart: true)
            target.mouseDown(with: down)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { target.mouseUp(with: pending) }
            pump()
        }
        func center(of id: ItemID) -> NSPoint? {
            guard let f = sidebar.rowFrame(nodeID: id) else { return nil }
            return scene.convert(NSPoint(x: f.midX - 40, y: f.midY), from: sidebar)
        }
        let second = space.pinned[1]
        delegate.log.removeAll()
        if let p = center(of: second.id) { click(p) }
        check(delegate.log.contains(.select(nodeID: second.id, space: space.id)), "click on a pinned row sends select")
        check(window.selectedNodeBySpace[space.id] == second.id, "the model selected it")
        delegate.log.removeAll()
        if let p = center(of: folder.id) { click(p) }
        check(delegate.log.contains(.setExpanded(folderID: folder.id, expanded: false)), "click on a folder row toggles it")
        OffscreenRenderer.settle(scene, runLoop: 0.15); rowsMatch("folder collapsed by click")
        delegate.log.removeAll()
        if let r = sidebar.displayedRows.firstIndex(of: "newTab"), let outline = sidebar.focusedOutline {
            let f = outline.rect(ofRow: r)
            click(scene.convert(NSPoint(x: f.midX, y: f.midY), from: outline))
        }
        check(delegate.log.contains(.openCommandBar(.newTabRow)), "click on New Tab asks for the command bar")
        delegate.log.removeAll()
        click(scene.convert(NSPoint(x: 100, y: 64), from: sidebar))
        check(delegate.log.contains(.openCommandBar(.urlField)), "click on the URL field asks for the command bar")

        print("menus")
        let pinnedTab = space.pinned.compactMap(\.tab).last!
        check(sidebar.menuTitles(nodeID: pinnedTab.id) == ["Copy Link", "Share…", "—", "Change Icon…", "Rename…", "Mute", "Customize Page…", "Edit Pinned Page", "—", "Add Split View", "Duplicate", "Move to", "—", "Remove Pin"],
              "pinned tab menu (F0116 order): \(sidebar.menuTitles(nodeID: pinnedTab.id).joined(separator: " · "))")
        if let todayTab = space.today.first {
            check(sidebar.menuTitles(nodeID: todayTab.id) == ["Copy Link", "—", "Open in Split View", "Move to", "—", "Archive Item"], "Today tab menu (F0115 order)")
        }
        check(sidebar.menuTitles(nodeID: folder.id).first == "Share Folder…" && sidebar.menuTitles(nodeID: folder.id).last == "Delete", "folder menu (F0119 order)")
        check(sidebar.menuTitles(nodeID: nil).first == "Change Space Icon…" && sidebar.menuTitles(nodeID: nil).last == "Delete Space", "Space menu on empty space (F0117 order)")

        print("drag and drop targets")
        let pinnedCount = space.pinned.count
        check(sidebar.dropDestination(intoFolder: nil, childIndex: 0).map { $0.0 == .spacePinned(space.id) && $0.1 == 0 } ?? false, "above the first row → Pinned 0")
        check(sidebar.dropDestination(intoFolder: nil, childIndex: 1 + pinnedCount).map { $0.0 == .spacePinned(space.id) && $0.1 == pinnedCount } ?? false, "after the last pinned row → end of Pinned")
        check(sidebar.dropDestination(intoFolder: nil, childIndex: 1 + pinnedCount + 2).map { $0.0 == .spaceToday(space.id) && $0.1 == 0 } ?? false, "between New Tab and Today → Today 0")
        check(sidebar.dropDestination(intoFolder: folder.id, childIndex: -1).map { $0.0 == .folder(folder.id) } ?? false, "onto a folder → into the folder")
        let before = space.pinned.map(\.id)
        delegate.sidebar(sidebar, didRequest: .move(nodeID: before[0], to: .spacePinned(space.id), index: 2))
        pump(); rowsMatch("drop intent moves a pinned row (animated move)")

        print("Space switch and swipe")
        let w = sidebar.bounds.width
        model.focusSpace(windowID: window.id, spaceID: model.spaces[1].id)
        pump()
        OffscreenRenderer.settle(scene, runLoop: 0.8) // let the spring finish before swiping
        check(abs(sidebar.pagerOffset - w) < 0.5, "focusSpace slides the pager to page 2 (offset \(sidebar.pagerOffset))")
        check(scene.background.style == context.style(for: model.spaces[1]), "background cross-fades to Space 2's theme")
        rowsMatch("page 2 rows")
        func scroll(_ phase: Int64, dx: Int32) -> NSEvent {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
            return NSEvent(cgEvent: e)!
        }
        delegate.log.removeAll()
        sidebar.simulateSwipe([scroll(1, dx: -10)] + (0..<12).map { _ in scroll(2, dx: -14) } + [scroll(4, dx: 0)])
        pump()
        check(delegate.log.contains(.switchSpace(model.spaces[2].id)), "swipe left sends switchSpace to the next Space")
        check(context.focusedSpace === model.spaces[2], "focus moved to Space 3")
        OffscreenRenderer.settle(scene, runLoop: 0.8)
        sidebar.simulateSwipe([scroll(1, dx: 3), scroll(2, dx: 5), scroll(2, dx: 4), scroll(4, dx: 0)])
        pump()
        check(context.focusedSpace === model.spaces[2], "a short swipe snaps back")

        ReviewChecks.run()

        print("\nchecks: \(passes) passed, \(failures) failed")
        host.contentView = nil
        host.close()
        if failures > 0 { exit(1) }
    }
}
