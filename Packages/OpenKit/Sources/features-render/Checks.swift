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
        let store = SnapshotStore(root: temp), archive = ArchiveStore(fileURL: temp.appendingPathComponent("State/archive.sqlite3"))
        model.archiveSink = archive
        let c = BrowserWindowController(model: model, windowID: window.id, factory: factory, defaults: defaults, snapshotStore: store)
        defer { c.peekController.dismissAll(); c.container.closeAll(); c.window?.close() }
        func settle() { OffscreenRenderer.settle(c.contentView, runLoop: 0.01) }
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
        let assignmentMatches = c.container.slots.allSatisfy { slot in
            guard let host = c.container.host(for: slot.tabID) as? FakeWebContentHost else { return false }
            return host.tabID == slot.tabID && slot.contentHostView === host.surface
        }
        check(split.focusedPaneID == newID && assignmentMatches && c.container.slots.map(\.tabID) == split.panes.map(\.id), "S2 focus and colored host assignment in pane order")
        let divider = c.container.divider(at: 0)!
        let initialFractions = split.fractions
        model.undoManager = undo
        let pageLayouts = c.container.slots.compactMap { ($0.contentHostView as? FakePageView)?.layoutCount }
        divider.drag(by: 60, commit: false)
        check(c.container.slots.compactMap { ($0.contentHostView as? FakePageView)?.layoutCount } == pageLayouts,
              "R8 divider updates frames without laying out the web subtree per event")
        divider.drag(by: 120); settle()
        check(split.fractions.count == 2 && abs(split.fractions.reduce(0, +) - 1) < 0.000001 && split.fractions[0] > 0.5, "S3 divider persists normalized widths")
        try store.saveNow(model: model); let loaded = try store.load()!
        check(loaded.node(id: split.id)?.split?.fractions == split.fractions, "S3 snapshot reload preserves fractions")
        let draggedFractions = split.fractions
        undo.undo(); check(split.fractions == initialFractions, "S3 one divider release undoes in one step")
        undo.redo(); check(split.fractions == draggedFractions, "S3 divider redo restores drag result")
        model.undoManager = nil
        let slot = c.container.slots[1], point = slot.convert(CGPoint(x: slot.bounds.midX, y: slot.bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: c.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        c.container.mouseDown(with: event); slot.hitTest(slot.convert(point, from: nil))?.mouseDown(with: event); settle()
        check(split.focusedPaneID == newID && c.container.slots[0].focusRing.isHidden && !c.container.slots[1].focusRing.isHidden && c.context.currentTab?.id == newID, "S4 synthesized pane click focuses ring and sidebar URL source")
        c.performCommand("focus-split-pane-1"); c.performCommand("previous-split-pane")
        check(split.focusedPaneID == newID, "S4 previous wraps to last")
        c.performCommand("next-split-pane"); check(split.focusedPaneID == first.id, "S4 next wraps to first")
        func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: c.window!.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        let focusSecond = key("2", code: 19, flags: [.control, .shift])
        c.container.host(for: first.id)?.focus()
        check(c.handleKeyDown(focusSecond) && split.focusedPaneID == newID, "R9 web responder permits split-focus shortcut")
        c.performCommand("focus-split-pane-1")
        let sidebarField = NSTextField(); c.sidebar.addSubview(sidebarField); c.window?.makeFirstResponder(sidebarField)
        check(!c.handleKeyDown(focusSecond) && split.focusedPaneID == first.id, "R9 sidebar responder keeps split-focus shortcut")
        sidebarField.removeFromSuperview()
        let textField = NSTextField(); c.contentView.addSubview(textField); c.window?.makeFirstResponder(textField)
        check(!c.handleKeyDown(focusSecond) && split.focusedPaneID == first.id, "R9 text field retains split-focus shortcut")
        textField.removeFromSuperview(); c.container.host(for: first.id)?.focus()
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
        model.setSplitFractions(splitID: split.id, fractions: [0.4, 0.3, 0.2, 0.1])
        model.undoManager = undo
        let removedFourth = split.panes[3].id
        c.splitController.close(removedFourth, separate: false); settle()
        check(split.fractions.count == 3 && abs(split.fractions.reduce(0, +) - 1) < 0.000001
            && abs(split.fractions[0] / split.fractions[1] - 4.0 / 3) < 0.000001,
            "R1 four-to-three close drops removed share and preserves proportions")
        undo.undo(); c.refresh(); settle()
        check(split.panes.count == 4 && split.fractions == [0.4, 0.3, 0.2, 0.1], "R1 four-pane undo restores exact fractions")
        model.undoManager = nil
        let focusedBeforeSeparate = c.splitController.focusedTab!.id
        c.performCommand("separate-from-split-view"); settle()
        check(c.context.currentTab?.id == focusedBeforeSeparate && model.parent(of: focusedBeforeSeparate) == model.parent(of: split.id), "S5 separated pane becomes selected sibling")
        model.setSplitOrientation(splitID: split.id, orientation: .horizontal)
        let threeFractions = [0.5, 0.3, 0.2]
        model.setSplitFractions(splitID: split.id, fractions: threeFractions)
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: split.id); c.refresh(); settle()
        let middle = split.panes[1].id
        model.undoManager = undo
        c.splitController.close(middle, separate: false); settle()
        check(split.fractions.count == 2 && abs(split.fractions.reduce(0, +) - 1) < 0.000001
            && abs(split.fractions[0] / split.fractions[1] - 2.5) < 0.000001,
            "R1 [0.5,0.3,0.2] close middle normalizes survivors in 5:2 proportions")
        c.window?.setContentSize(CGSize(width: 700, height: 900)); settle()
        check(c.container.slots.allSatisfy { $0.frame.width >= 200 }, "R1 surviving pane layout clamps to 200 pt")
        c.window?.setContentSize(CGSize(width: 500, height: 900)); settle()
        check(abs(c.container.slots[0].frame.width - c.container.slots[1].frame.width) <= 1,
              "R1 narrow surviving panes scale equally below 200 pt")
        c.window?.setContentSize(CGSize(width: 2216, height: 1394))
        undo.undo(); c.refresh(); settle()
        check(split.panes.count == 3 && split.panes[1].id == middle && split.fractions == threeFractions,
              "R1 undo restores original three panes and exact previous fractions")
        undo.redo(); c.refresh(); settle()
        check(split.panes.count == 2 && split.fractions.count == 2 && abs(split.fractions[0] / split.fractions[1] - 2.5) < 0.000001,
              "R1 redo preserves normalized survivors")
        undo.undo(); c.refresh(); settle(); model.undoManager = nil
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
        let favorite = model.newTab(in: space.id, url: URL(string: "https://favorite.example.com")!, title: "Favorite")
        _ = model.addFavorite(tabID: favorite.id, to: space.profileID); favorite.live.sleepPhase = .live
        // A favorite's Peek is visible even when the Space selection is another node.
        check(!c.peekController.intercept(tabID: favorite.id, url: URL(string: "https://favorite-preview.org")!, flags: [])
            && c.peekController.isShown, "R2 favorite opens visible Peek without Space selection")
        let favoriteHost = c.peekController.stack.last!.host as! FakeWebContentHost
        let beforeRefusal = model.index.count
        check(!c.peekController.openInSplitTop() && c.peekController.isShown && !favoriteHost.isClosed
            && model.index.count == beforeRefusal, "R4 favorite Split takes beep refusal path and keeps Peek with no new tab")
        let otherSpace = model.createSpace(title: "Other", profileID: space.profileID)
        model.focusSpace(windowID: window.id, spaceID: otherSpace.id); c.refresh(); settle()
        check(c.peekController.isShown, "R2 favorite Peek stays visible in another Space of its profile")
        check(c.handleKeyDown(key("", code: 53)) && !c.peekController.isOpen && favoriteHost.isClosed,
              "R2 Escape dismisses favorite Peek and closes its host")
        model.focusSpace(windowID: window.id, spaceID: space.id); c.refresh(); settle()
        weak var dismissedHost: FakeWebContentHost?
        var savedURL: ((URL) -> Void)?, savedLoading: ((Bool) -> Void)?, savedNavigation: ((URL, NSEvent.ModifierFlags) -> Bool)?
        autoreleasepool {
            c.peekController.open(url: URL(string: "https://leak-preview.org")!, sourceTabID: favorite.id)
            let host = c.peekController.stack.last!.host as! FakeWebContentHost; dismissedHost = host
            savedURL = host.onURLChange; savedLoading = host.onLoadingChange; savedNavigation = host.shouldNavigate
            c.handleKeyDown(key("", code: 53)); factory.releaseClosedHosts()
        }
        settle()
        check(dismissedHost == nil && c.peekController.overlay.pageClip.subviews.isEmpty,
              "R3 dismissed host releases even while all old callbacks remain retained")
        savedURL?(URL(string: "https://stale.org")!); savedLoading?(false)
        check(savedNavigation?(URL(string: "https://stale.org")!, []) == false && !c.peekController.isOpen,
              "R3 retained stale callbacks cannot navigate or reopen a dismissed Peek")
        withExtendedLifetime((savedURL, savedLoading, savedNavigation)) {}
        for suffix in ["internal", "lan", "未知后缀"] {
            sourceHost.load(URL(string: "https://one.example.\(suffix)/start")!)
            check(sourceHost.simulateLinkClick(URL(string: "https://two.example.\(suffix)/same-site")!) && !c.peekController.isOpen,
                  "R7 unknown suffix \(suffix) uses last-two-label site heuristic")
            check(!sourceHost.simulateLinkClick(URL(string: "https://one.other.\(suffix)/other-site")!) && c.peekController.isShown,
                  "R7 unknown suffix \(suffix) distinguishes another site")
            c.peekController.dismissAll()
        }
        for (source, target) in [("127.0.0.1", "192.0.0.1"), ("[::1]", "[::2]"), ("localhost", "other.localhost")] {
            sourceHost.load(URL(string: "https://\(source)/")!)
            check(sourceHost.simulateLinkClick(URL(string: "https://\(source)/same")!) && !c.peekController.isOpen
                && !sourceHost.simulateLinkClick(URL(string: "https://\(target)/different")!) && c.peekController.isShown,
                "R7 \(source) compares exactly")
            c.peekController.dismissAll()
        }
        sourceHost.load(URL(string: "https://github.com/start")!)
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
        let notification = Notification(name: NSWindow.didBecomeKeyNotification, object: lc.window)
        lc.windowDidBecomeKey(notification); lc.windowDidDeminiaturize(notification); lc.windowDidChangeOcclusionState(notification)
        check(!session.windowIsVisible, "R6 unordered Little Open stays hidden after key deminiaturize and occlusion callbacks")
        little.resurface(session.id)
        check(!session.windowIsVisible, "R6 resurfacing an offscreen Little Open derives actual window visibility")
        check(littleModel.windows.isEmpty && lc.contentView.bounds.size == CGSize(width: 720, height: 540), "L1 720x540 session without main window")
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
        // V1's explicit synthetic visible-window override; R6 above checks actual AppKit flags.
        little.sessions[0].windowIsVisible = true
        let visible = provider.sleepVisibility().visibleTabIDs(in: model), panes = c.splitController.split!.panes.map(\.id)
        check(panes.allSatisfy { visible.contains($0) } && visible.contains(c.peekController.stack.last!.hostTabID) && visible.contains(little.sessions[0].tab.id), "V1 all split panes Peek host and Little Open visible")
        c.visibilityOverride = .minimized
        let minimized = provider.sleepVisibility().visibleTabIDs(in: model)
        check(panes.allSatisfy { !minimized.contains($0) } && !minimized.contains(c.peekController.stack.last!.hostTabID), "V1 minimized main drops split and Peek")
        provider.pipTabIDs = [panes[0]]; check(provider.sleepVisibility().visibleTabIDs(in: model).contains(panes[0]), "V1 PiP remains protected")
        // Exercise provider transitions through the real SleepController and
        // SQLite store. Only the engine-facing web host boundary is synthetic.
        c.visibilityOverride = .minimized; provider.pipTabIDs = []
        little.sessions[0].windowIsVisible = false
        var visibilityClock = Date(timeIntervalSince1970: 1_800_000_000)
        let sleepDisk = FeatureSleepStore(fileURL: temp.appendingPathComponent("State/visibility-sleep.sqlite3"))
        let sleep = SleepController(model: model, engine: FeatureSleepHostBridge(container: c.container),
            store: sleepDisk, visibility: provider, chromiumTag: "m4-fake-host", now: { visibilityClock })
        provider.sleepController = sleep
        c.visibilityOverride = .visible
        provider.visibilityChanged(); provider.visibilityChanged()
        for _ in 0..<5 { await Task.yield() }
        let firstVisibleAt = visibilityClock
        check(panes.allSatisfy { model.tab(id: $0)?.lastActiveAt == firstVisibleAt },
              "R5 rapid duplicate notifications preserve queued newly visible wakes")
        visibilityClock = visibilityClock.addingTimeInterval(60)
        provider.visibilityChanged()
        for _ in 0..<5 { await Task.yield() }
        check(panes.allSatisfy { model.tab(id: $0)?.lastActiveAt == firstVisibleAt },
              "R5 unchanged visible tabs are not stamped active again")
        c.visibilityOverride = .minimized; provider.visibilityChanged()
        let firstHiddenAt = visibilityClock
        visibilityClock = visibilityClock.addingTimeInterval(60); provider.visibilityChanged()
        check(panes.allSatisfy { sleep.hiddenAt[$0] == firstHiddenAt },
              "R5 newly hidden panes reach SleepController once and keep hidden time")
        try await sleepDisk.flush()
        provider.sleepController = nil
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
        let image = OffscreenRenderer().render(c.contentView, scale: 1)
        check(image.width == 2216 && image.height == 1394, "C1 real CARenderer scene snapshot")
        print("features-render check: \(passed) passed, \(failed) failed")
        if failed > 0 { throw CLIError(description: "\(failed) feature scenarios failed") }
    }
}
