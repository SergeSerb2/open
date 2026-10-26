import AppKit
import OpenModel
import OpenStore
import OpenFeatures
import OpenDesign
import OpenSleep

/// End-to-end executable scenarios through the real controllers, views, model,
/// snapshot store, and SQLite archive. The only fake is the specified web host.
@MainActor
enum FeatureChecks {
    static func run() async throws {
        var passed = 0, failed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            let ok = condition(); if ok { passed += 1 } else { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label)")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("open-m4-\(UUID())")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let model = FeatureCLI.synthetic(), factory = FakeWebContentHostFactory(), defaults = FeatureCLI.defaults()
        let window = model.windows[0], space = model.spaces[0], first = space.pinned[0].tab!
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: first.id)
        let store = SnapshotStore(root: temp), archive = ArchiveStore(root: temp)
        model.archiveSink = archive
        let c = BrowserWindowController(model: model, windowID: window.id, factory: factory, defaults: defaults, snapshotStore: store)
        defer { c.peekController.dismissAll(); c.container.closeAll(); c.window?.close() }
        func settle() { OffscreenRenderer.settle(c.root, runLoop: 0.01) }
        settle()
        check(c.container.slots.count == 1 && c.container.slots[0].paneChrome == nil, "C1 single pane has no bar")
        check(c.container.frame == CGRect(x: 228, y: 10, width: 1978, height: 1374), "C1 measured panel insets")
        for orientation in [SplitOrientation.horizontal, .vertical] {
            for n in 2...4 {
                for narrow in [false, true] {
                    for custom in [false, true] {
                        let content = CGRect(x: 7, y: 11, width: narrow ? 480 : 1600, height: narrow ? 420 : 1300)
                        let fractions = custom ? (0..<n).map { Double($0 + 1) / Double(n * (n + 1) / 2) } : Array(repeating: 1 / Double(n), count: n)
                        let frames = SplitLayout.frames(content: content, orientation: orientation, fractions: fractions, gap: 10, minPane: 200)
                        let sizes = frames.map { orientation == .horizontal ? $0.width : $0.height }
                        let axis = orientation == .horizontal ? content.width : content.height
                        let gaps = (0..<(n - 1)).allSatisfy { i in abs((orientation == .horizontal ? frames[i + 1].minX - frames[i].maxX : frames[i].minY - frames[i + 1].maxY) - 10) < 0.001 }
                        check(frames.count == n && gaps && sizes.allSatisfy { $0 >= 0 } && abs(sizes.reduce(0, +) + Double(n - 1) * 10 - axis) < 0.001,
                              "S1 \(orientation) \(n) panes \(narrow ? "narrow" : "wide") \(custom ? "custom" : "equal") tiles")
                    }
                }
            }
        }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = nil
        c.performCommand("add-split-view"); settle()
        check(c.splitController.split?.panes.count == 2 && c.container.slots.count == 2, "S2 C1 creates two real slots")
        let split = c.splitController.split!, newID = split.panes[1].id
        check(split.focusedPaneID == newID && c.container.host(for: first.id) != nil && c.container.host(for: newID) != nil, "S2 focus and lazy hosts")
        let divider = c.container.divider(at: 0)!
        divider.drag(by: 120); settle()
        check(split.fractions.count == 2 && abs(split.fractions.reduce(0, +) - 1) < 0.000001 && split.fractions[0] > 0.5, "S3 divider persists normalized widths")
        store.saveNow(model: model); let loaded = try store.load()!
        check(loaded.node(id: split.id)?.split?.fractions == split.fractions, "S3 snapshot reload preserves fractions")
        let slot = c.container.slots[1], point = slot.convert(CGPoint(x: slot.bounds.midX, y: slot.bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: c.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        c.container.observeClick(event); slot.hitTest(slot.convert(point, from: nil))?.mouseDown(with: event); settle()
        check(split.focusedPaneID == newID && c.container.slots[0].focusRing.isHidden && !c.container.slots[1].focusRing.isHidden && c.context.currentTab?.id == newID, "S4 synthesized pane click focuses ring and sidebar URL source")
        c.performCommand("focus-split-pane-1"); c.performCommand("previous-split-pane")
        check(split.focusedPaneID == newID, "S4 previous wraps to last")
        c.performCommand("next-split-pane"); check(split.focusedPaneID == first.id, "S4 next wraps to first")
        c.performCommand("expand-current-split"); settle(); check(c.container.slots[0].frame == c.container.bounds && c.container.slots[1].isHidden, "S5 maximize hides other slots")
        c.splitController.performCommand("escape"); settle(); check(c.container.slots.allSatisfy { !$0.isHidden }, "S5 Escape restores layout")
        c.performCommand("add-split-view"); c.performCommand("add-split-view"); settle()
        check(split.panes.count == 4 && c.container.slots.count == 4 && !c.splitController.canAddPane, "S6 four-pane cap and disabled command")
        let extra = space.today.compactMap(\.tab).first { model.parent(of: $0.id) != .splitPane(split.id) }!
        let revision = model.treeRevision, undoBefore = undo.canUndo
        check(!model.addPane(splitID: split.id, tabID: extra.id) && model.treeRevision == revision && undo.canUndo == undoBefore && split.panes.count == 4, "S6 fifth model add refuses without event")
        let order = split.panes.map(\.id), focused = split.focusedPaneID, fractions = split.fractions
        model.setSplitOrientation(splitID: split.id, orientation: .vertical); c.refresh(); settle()
        check(split.panes.map(\.id) == order && split.focusedPaneID == focused && split.fractions == fractions, "S6 orientation keeps order focus fractions")
        let prior = split.fractions
        for invalid in [[Double.nan, 0, 0, 1], [-1, 1, 0, 1], [0.5, 0.5], [1, 1, 1, 1]] { model.setSplitFractions(splitID: split.id, fractions: invalid) }
        check(split.fractions == prior, "S3 invalid fractions change nothing")
        let focusedBeforeSeparate = c.splitController.focusedTab!.id
        c.performCommand("separate-from-split-view"); settle()
        check(c.context.currentTab?.id == focusedBeforeSeparate && model.parent(of: focusedBeforeSeparate) == model.parent(of: split.id), "S5 separated pane becomes selected sibling")
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: split.id); c.refresh()
        c.performCommand("close-split-pane"); c.performCommand("close-split-pane"); settle()
        check(c.splitController.split == nil && c.container.slots.count == 1 && c.container.slots[0].paneChrome == nil, "S5 close collapses to single no bar")
        check(c.container.handleDrop(extra.id, point: CGPoint(x: 1, y: 200)), "S2 C2 edge drop handler accepts tab")
        settle(); check(c.splitController.split?.panes.first?.id == extra.id, "S2 left drop preserves pane order")
        let another = model.newTab(in: space.id, url: URL(string: "https://combine.example.com")!); another.live.sleepPhase = .live
        check(c.container.handleDrop(another.id, point: CGPoint(x: 300, y: 300), paneIndex: 1), "S2 C3 combine drop handler inserts at pane index")
        settle(); check(c.splitController.split?.panes[1].id == another.id, "S2 combined pane order")
        let added = c.splitController.split!, originalFractions = added.fractions, originalFocus = added.focusedPaneID
        let undoTab = model.newTab(in: space.id, url: URL(string: "https://undo.example.com")!)
        model.undoManager = undo; undo.beginUndoGrouping(); _ = model.addPane(splitID: added.id, tabID: undoTab.id, at: 1); undo.endUndoGrouping()
        undo.undo(); check(added.panes.count == 3 && added.fractions == originalFractions && added.focusedPaneID == originalFocus && model.parent(of: undoTab.id) == .spaceToday(space.id), "S6 addPane undo restores ownership fractions focus")
        undo.redo(); check(added.panes.count == 4 && model.parent(of: undoTab.id) == .splitPane(added.id), "S6 addPane redo")
        model.undoManager = nil
        let pinned = model.newTab(in: space.id, url: URL(string: "https://github.com/start")!, title: "Source")
        model.pinTab(id: pinned.id); pinned.live.sleepPhase = .live
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: pinned.id); c.refresh(); settle()
        let sourceHost = c.container.host(for: pinned.id) as! FakeWebContentHost
        check(sourceHost.simulateLinkClick(URL(string: "https://docs.github.com/guide")!), "P1 lead Q1 same registrable domain stays in tab")
        check(!sourceHost.simulateLinkClick(URL(string: "https://example.org/preview")!) && c.peekController.isShown, "P1 pinned different registrable domain opens Peek")
        settle(); let overlay = c.peekController.overlay
        check(overlay.panel.frame == CGRect(x: 427, y: 12, width: 1590, height: 1370), "P2 F0090 panel geometry")
        check(overlay.buttons.enumerated().allSatisfy { i, b in abs(b.frame.minX - 2030) < 0.01 && abs((1394 - b.frame.maxY) - (21 + Double(i) * 43)) < 0.01 }, "P2 three control offsets")
        let oldURL = pinned.url, peekHost = c.peekController.stack.last!.host as! FakeWebContentHost
        c.peekController.escape(); check(peekHost.isClosed && !c.peekController.isShown && pinned.url == oldURL, "P2 Escape closes host without source navigation")
        c.peekController.undoDismiss(); check(c.peekController.isShown, "P4 Undo reopens dismissed URL")
        c.peekController.dismissAll()
        check(FeatureSite.shouldPeek(source: pinned.url, target: pinned.url, pinned: false, flags: .shift, defaults: defaults), "P1 Today Shift opens Peek")
        check(!FeatureSite.shouldPeek(source: pinned.url, target: URL(string: "https://other.org")!, pinned: true, flags: [.option, .command], defaults: defaults), "P1 Opt+Cmd excluded before Peek (Step 8 intake deferred)")
        check(!FeatureSite.shouldPeek(source: pinned.url, target: URL(string: pinned.url.absoluteString + "#section")!, pinned: true, flags: .shift, defaults: defaults), "P1 fragment never Peeks")
        defaults.set(false, forKey: "open.peek.otherSites"); defaults.set(false, forKey: "open.peek.shiftClick")
        check(!FeatureSite.shouldPeek(source: pinned.url, target: URL(string: "https://other.org")!, pinned: true, flags: .shift, defaults: defaults), "P1 toggles off navigate")
        defaults.set(true, forKey: "open.peek.otherSites"); defaults.set(true, forKey: "open.peek.shiftClick")
        c.peekController.open(url: URL(string: "https://preview.org/one")!, sourceTabID: pinned.id); settle()
        let firstPeek = c.peekController.stack.last!.host as! FakeWebContentHost
        firstPeek.simulateLinkClick(URL(string: "https://preview.org/two")!); firstPeek.surface.mouseDown(with: event)
        let loadCount = firstPeek.loadCount
        c.peekController.expandTop(); settle()
        let promoted = c.context.currentTab!
        check(space.today.first?.id == promoted.id && promoted.url.absoluteString == "https://preview.org/two" && !c.peekController.isOpen, "P3 expand creates selected Today-top tab")
        check(c.container.host(for: promoted.id) === firstPeek && firstPeek.surface.clickCount == 1 && firstPeek.loadCount == loadCount && firstPeek.canGoBack, "P3 same host click count history and no reload")
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: pinned.id); c.refresh()
        c.peekController.open(url: URL(string: "https://one.org")!, sourceTabID: pinned.id)
        let parent = c.peekController.stack.last!.host as! FakeWebContentHost
        parent.simulateLinkClick(URL(string: "https://two.net")!)
        check(c.peekController.stack.count == 2, "P4 cross-site nesting pushes")
        c.peekController.escape(); check(c.peekController.stack.count == 1 && c.peekController.stack.last?.host === parent, "P4 Escape restores parent host")
        for i in 0..<6 { (c.peekController.stack.last!.host as! FakeWebContentHost).simulateLinkClick(URL(string: "https://nested\(i).org")!) }
        check(c.peekController.stack.count == 5, "P4 depth cap five navigates top")
        let retained = c.peekController.stack.last!.host
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: promoted.id); c.refresh(); check(!c.peekController.isShown, "P5 another selection hides Peek")
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: pinned.id); c.refresh()
        check(c.peekController.isShown && c.peekController.stack.last?.host === retained, "P5 source selection restores same Peek")
        c.peekController.dismissAll(); c.peekController.open(url: URL(string: "https://split-preview.org")!, sourceTabID: pinned.id)
        let splitPeek = c.peekController.stack.last!.host
        c.peekController.openInSplitTop(); settle()
        check(c.splitController.split?.panes.count == 2 && !c.peekController.isOpen && c.container.host(for: c.context.currentTab!.id) === splitPeek, "P3 lead Q4 Split promotes same host beside source")
        let littleModel = FeatureCLI.synthetic(); littleModel.windows = []
        let little = LittleOpenCoordinator(model: littleModel, archiveSink: archive) { profile in factory.makeHost(tabID: ItemID(), profileID: profile, url: nil) as! FakeWebContentHost }
        little.presentWindows = false; little.defaults = defaults
        defer { little.closeAll() }
        little.open(url: URL(string: "https://example.com/path#one")!, profileHint: nil)
        let session = little.sessions[0], lc = little.controllers[session.id]!
        check(littleModel.windows.isEmpty && lc.root.bounds.size == CGSize(width: 720, height: 540), "L1 720x540 session without main window")
        little.open(url: URL(string: "https://EXAMPLE.com:443/path#two")!, profileHint: nil)
        check(little.sessions.count == 1, "L1 canonical URL resurface dedupe")
        little.openBlank(focusURLField: true); little.openBlank(focusURLField: true)
        check(little.sessions.count == 2, "L1 blank key session reused")
        little.moveToSpace(sessionID: session.id, spaceID: littleModel.spaces[0].id)
        check(littleModel.windows.count == 1 && littleModel.spaces[0].today.first?.tab?.url.absoluteString.contains("example.com/path") == true && little.sessions.count == 1, "L2 move creates main window and selected Today-top tab")
        let count = littleModel.index.count
        little.open(url: URL(string: "https://example.com/path#again")!, profileHint: nil)
        let duplicate = little.sessions[0]
        little.moveToSpace(sessionID: duplicate.id, spaceID: littleModel.spaces[0].id)
        check(littleModel.index.count == count, "L2 move dedupes existing Space tab")
        let stale = little.sessions[0]; stale.lastActiveAt = Date(timeIntervalSince1970: 1)
        let expected = stale.tab.id; check(little.archiveExpired(now: Date()) == 1 && little.sessions.isEmpty, "L3 stale profile threshold expires one session")
        archive.flushQueue(); let records = await archive.recent()
        check(records.contains { $0.id == expected && $0.originalLocation.hasPrefix("littleOpen:") && $0.reason == .autoArchived }, "L3 actual SQLite archive stores Little Open prefix")
        little.open(url: URL(string: "https://fresh.org")!, profileHint: nil)
        check(little.archiveExpired(now: Date()) == 0, "L3 fresh session stays")
        let provider = AppVisibilityProvider(model: model); provider.browserWindowControllers = [c]; provider.littleOpenCoordinator = little
        c.visibilityOverride = .visible
        c.peekController.open(url: URL(string: "https://visible.org")!, sourceTabID: c.context.currentTab!.id); settle()
        let visible = provider.sleepVisibility().visibleTabIDs(in: model), panes = c.splitController.split!.panes.map(\.id)
        check(panes.allSatisfy { visible.contains($0) } && visible.contains(c.peekController.stack.last!.hostTabID) && visible.contains(little.sessions[0].tab.id), "V1 all split panes Peek host and Little Open visible")
        c.visibilityOverride = .minimized
        let minimized = provider.sleepVisibility().visibleTabIDs(in: model)
        check(panes.allSatisfy { !minimized.contains($0) } && !minimized.contains(c.peekController.stack.last!.hostTabID), "V1 minimized main drops split and Peek")
        provider.pipTabIDs = [panes[0]]; check(provider.sleepVisibility().visibleTabIDs(in: model).contains(panes[0]), "V1 PiP remains protected")
        c.peekController.dismissAll()
        let sleeping = model.newTab(in: space.id, url: URL(string: "https://sleeping.org")!); sleeping.live.sleepPhase = .sleeping
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: sleeping.id); c.refresh(); settle()
        check(c.container.host(for: sleeping.id) == nil && c.container.slots[0].placeholderView != nil, "C1 sleeping placeholder creates no host")
        sleeping.live.sleepPhase = .live; c.container.refreshPlaceholders(); settle()
        check(c.container.host(for: sleeping.id) != nil && c.container.slots[0].placeholderView == nil, "C1 wake swaps placeholder to host")
        let oldHost = c.container.host(for: sleeping.id) as! FakeWebContentHost, staleCallback = oldHost.onTitleChange
        for i in 0..<11 {
            let tab = model.newTab(in: space.id, url: URL(string: "https://cache\(i).org")!); tab.live.sleepPhase = .live
            model.selectNode(windowID: window.id, spaceID: space.id, nodeID: tab.id); c.refresh(); settle()
        }
        check(oldHost.isClosed, "C1 ninth hidden host evicted by LRU")
        let oldTitle = sleeping.title; staleCallback?("Stale title")
        check(sleeping.title == oldTitle, "C1 generation guard drops stale callback after eviction")
        let image = OffscreenRenderer().snapshot(c.root, scale: 1)
        check(image.width == 2216 && image.height == 1394, "C1 real CARenderer scene snapshot")
        print("features-render check: \(passed) passed, \(failed) failed")
        if failed > 0 { throw CLIError(description: "\(failed) feature scenarios failed") }
    }
}
