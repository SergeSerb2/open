import AppKit
import Darwin
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

    /// The 1-minute load average, for timing-check diagnostics.
    static func loadAverage1() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads[0] : -1
    }

    /// Pump the main run loop in 5 ms slices until `condition` holds or the
    /// generous upper bound passes. Use this instead of a fixed sleep followed
    /// by an assertion: machine load stretches fixed sleeps, not conditions.
    static func waitFor(timeout: TimeInterval = 5, settle view: NSView? = nil, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let view { OffscreenRenderer.settle(view) }
            if condition() { return true }
            if Date() >= deadline { return condition() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Display rows the outline should show for the focused Space.
    static func expectedRows(context: SidebarContext) -> [String] {
        guard let space = context.focusedSpace else { return [] }
        return expectedRows(space: space)
    }

    static func expectedRows(space: Space) -> [String] {
        var r = ["spacer"]
        func walk(_ nodes: [SidebarNode]) {
            for n in nodes {
                r.append(n.id.description)
                if case .folder(let f) = n {
                    if f.isExpanded { walk(f.children) }
                    else if let id = f.peekedChildID, let child = f.children.first(where: { $0.id == id }) { walk([child]) }
                }
            }
        }
        if !space.isPinnedCollapsed { walk(space.pinned) }
        if !space.today.isEmpty { r.append("divider") }
        r.append("newTab")
        walk(space.today)
        return r
    }

    static func run(_ args: [String]) throws {
        if args == ["--media-lifecycle-only"] {
            MediaLifecycleChecks.run()
            print("\nchecks: \(passes) passed, \(failures) failed")
            if failures > 0 { exit(1) }
            return
        }
        if args == ["--row-media-only"] {
            MediaChecks.runRowIndicators()
            print("\nchecks: \(passes) passed, \(failures) failed")
            if failures > 0 { exit(1) }
            return
        }
        if args == ["--media-motion-only"] {
            MediaMotionChecks.run()
            print("\nchecks: \(passes) passed, \(failures) failed")
            if failures > 0 { exit(1) }
            return
        }
        // Checks that write preferences use one disposable suite per run.
        let suite = "com.open.sidebar-render-check.\(UUID().uuidString)"
        SidebarHaptics.defaults = UserDefaults(suiteName: suite)!
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
        let t = model.newTab(in: space.id, url: URL(string: "https://new.example.com")!, title: "Fresh")
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

        // Holding Command shows nothing (CC-39, D13; commandbar-completion §4.4.2): a Command press, posted
        // and dequeued as the app's run loop does (so event monitors see it), changes no sidebar pixel while
        // it is held, lays out no row, and reloads nothing.
        print("hold Command (no hints)")
        pump()
        func pixels() -> Data { let img = OffscreenRenderer().snapshot(scene, scale: 1); return (img.dataProvider?.data as Data?) ?? Data() }
        func flags(_ f: NSEvent.ModifierFlags) {
            guard let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: host.windowNumber,
                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55) else { return }
            NSApp.postEvent(e, atStart: false)
            let deadline = Date().addingTimeInterval(1)
            var delivered = false
            while !delivered, Date() < deadline {
                while let next = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                    if next.type == .flagsChanged { delivered = true }
                    NSApp.sendEvent(next)
                }
            }
            pump()
        }
        let beforePress = pixels()
        let layoutsC = SidebarDiagnostics.tabRowLayouts, reloadsC = SidebarDiagnostics.fullReloads
        flags(.command)
        let held = pixels()
        flags([])
        check(held == beforePress && SidebarDiagnostics.tabRowLayouts == layoutsC && SidebarDiagnostics.fullReloads == reloadsC,
              "a Command press alone changes no sidebar view (pixels same \(held == beforePress), layouts \(SidebarDiagnostics.tabRowLayouts - layoutsC), reloads \(SidebarDiagnostics.fullReloads - reloadsC))")

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
        check(delegate.log.contains(.setFolderExpansion(folderID: folder.id, expansion: .collapsed)), "click on a folder row toggles it")
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
        // Arc 1.172.2 orders (capture session 3 Part D; docs/re/sidebar-menus-parity.md §1).
        check(sidebar.menuTitles(nodeID: pinnedTab.id) == ["Copy Link", "Share", "—", "Change Icon…", "Rename…", "Mute", "Edit Pinned Page", "—", "Open in Split View", "Duplicate", "Move to", "—", "Remove Pin"],
              "pinned tab menu (S3D order): \(sidebar.menuTitles(nodeID: pinnedTab.id).joined(separator: " · "))")
        if let todayTab = space.today.first {
            // ⌥ alternates (Archive Other Tabs, Archive Tabs Above) are not drawn (capture session 8).
            let split = context.currentTab?.id == todayTab.id ? "Add Split View" : "Open in Split View"
            check(sidebar.menuTitles(nodeID: todayTab.id) == ["Copy Link", "Share", "—", "Change Icon…", "Rename…", "Mute", "—", split, "Duplicate", "Move to", "—",
                                                              "Archive Tab", "Archive Tabs Below"],
                  "Today tab menu (S3D order): \(sidebar.menuTitles(nodeID: todayTab.id).joined(separator: " · "))")
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

        print("model followups: live web content, undo, titles, and named icons")
        model.focusSpace(windowID: window.id, spaceID: space.id)
        OffscreenRenderer.settle(scene, runLoop: 0.8)
        let pinned = space.pinned.compactMap(\.tab).first!
        let plain = space.today.compactMap(\.tab).first!
        let favorite = profile.favorites.first!
        func hover(_ tab: Tab, favorite: Bool = false) {
            context.forcedHover = favorite ? .favorite(tab.id) : .row(tab.id)
            pump()
        }
        func clickAction(_ tab: Tab) {
            delegate.log.removeAll()
            if let button = sidebar.tabAction(tabID: tab.id)?.view {
                click(scene.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button))
            }
        }
        hover(pinned)
        check(sidebar.tabAction(tabID: pinned.id)?.glyph == .rowClose, "unloaded pinned tab shows × on hover")
        pinned.live.hasWebContent = true
        pump()
        check(sidebar.tabAction(tabID: pinned.id)?.glyph == .rowUnload, "loaded pinned tab changes to − while hovered")
        clickAction(pinned)
        check(delegate.log == [.unloadTab(pinned.id)] && model.tab(id: pinned.id) === pinned,
              "pinned − click sends unloadTab and keeps the entry")
        pinned.live.hasWebContent = false
        pump()
        check(sidebar.tabAction(tabID: pinned.id)?.glyph == .rowClose, "pinned tab returns to × when web content goes away")
        clickAction(pinned)
        check(delegate.log == [.close(nodeID: pinned.id)] && model.tab(id: pinned.id) == nil, "pinned × click closes the entry")
        undo.undo(); pump()
        plain.live.hasWebContent = true
        hover(plain)
        check(sidebar.tabAction(tabID: plain.id)?.glyph == .rowClose, "Today tab shows × even with live web content")
        hover(favorite, favorite: true)
        check(sidebar.tabAction(tabID: favorite.id)?.glyph == .rowClose, "unloaded Favorite shows × on hover")
        favorite.live.hasWebContent = true
        pump()
        check(sidebar.tabAction(tabID: favorite.id)?.glyph == .rowUnload, "loaded Favorite changes to − while hovered")
        clickAction(favorite)
        check(delegate.log == [.unloadTab(favorite.id)] && model.tab(id: favorite.id) === favorite,
              "Favorite − click sends unloadTab and keeps the entry")
        favorite.live.hasWebContent = false
        pump()
        check(sidebar.tabAction(tabID: favorite.id)?.glyph == .rowClose, "Favorite returns to × when web content goes away")
        clickAction(favorite)
        check(delegate.log == [.close(nodeID: favorite.id)] && model.tab(id: favorite.id) == nil, "Favorite × click closes the entry")
        undo.undo(); pump()
        context.forcedHover = .header
        pump()
        func button(_ label: String, in view: NSView) -> NSView? {
            if view.accessibilityLabel() == label { return view }
            for child in view.subviews { if let found = button(label, in: child) { return found } }
            return nil
        }
        if let collapse = button("Collapse Pinned", in: sidebar) {
            click(scene.convert(NSPoint(x: collapse.bounds.midX, y: collapse.bounds.midY), from: collapse))
        }
        check(space.isPinnedCollapsed, "header click uses the collapse command")
        undo.undo(); pump(); rowsMatch("undo of header collapse")
        undo.redo(); pump(); check(space.isPinnedCollapsed, "redo of header collapse")
        undo.undo(); pump()
        check(ModelSidebarActions(context: context).perform(.toggleMute(tabID: pinned.id)) && pinned.isMuted,
              "sidebar mute intent uses the model command")
        undo.undo(); check(!pinned.isMuted, "sidebar mute undo")
        undo.redo(); check(pinned.isMuted, "sidebar mute redo")
        space.title = nil
        pump()
        check(sidebar.displayedSpaceTitle == "Space 1" && sidebar.spaceSwitcher(spaceID: space.id)?.accessibilityLabel() == "Space 1",
              "nil title displays Space 1 in the header and switcher")
        model.moveSpace(id: space.id, to: 1)
        pump()
        check(sidebar.displayedSpaceTitle == "Space 2" && sidebar.spaceSwitcher(spaceID: space.id)?.accessibilityLabel() == "Space 2" && space.title == nil,
              "untitled Space follows its 1-based position after reorder")
        model.updateSpace(id: space.id, title: "Renamed")
        pump()
        check(sidebar.displayedSpaceTitle == "Renamed" && sidebar.spaceSwitcher(spaceID: space.id)?.accessibilityLabel() == "Renamed",
              "an explicit Space title appears unchanged")
        let missing = Set(NamedSpaceIcons.symbols.values).union([NamedSpaceIcons.fallbackSymbol]).filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }
        check(missing.isEmpty, "all \(NamedSpaceIcons.symbols.count) named-icon mappings and the neutral fallback exist on macOS: missing=\(missing.sorted())")
        check(NamedSpaceIcons.symbolName(for: "unknown-future-icon") == NamedSpaceIcons.fallbackSymbol,
              "unknown named icons use the neutral symbol")

        MediaChecks.runRowIndicators()
        MediaChecks.runMiniPlayers()
        MediaMotionChecks.run()
        MediaLifecycleChecks.run()
        ReviewChecks.run()
        VisualFinishChecks.run()
        FolderPeekChecks.run()
        FolderPeekChecks.drops()
        FolderPeekChecks.collapsedLoads()
        CompletionChecks.run()
        CompactToolbarChecks.run()
        URLStatusChecks.run()
        SpaceManagerChecks.run()
        PreviewChecks.run()
        SidebarHaptics.defaults.removePersistentDomain(forName: suite)

        print("\nchecks: \(passes) passed, \(failures) failed")
        host.contentView = nil
        host.close()
        if failures > 0 { exit(1) }
    }
}
