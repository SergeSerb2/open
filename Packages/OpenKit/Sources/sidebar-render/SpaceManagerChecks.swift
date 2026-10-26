import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// Drives the real Library content view, native event tracking, menus, outline
/// drop callbacks, model observation, and undo. No substitute model or views.
@MainActor
enum SpaceManagerChecks {
    static func run() {
        let check = Checks.check
        let key = "open.advanced.hapticOnTabReorder", defaults = UserDefaults.standard
        let oldPreference = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { if let oldPreference { defaults.set(oldPreference, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let model = Synthetic.model()
        let window = model.windows[0], original = model.spaces.map(\.id)
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let context = SidebarContext(model: model, windowID: window.id)
        let manager = SpaceManagerView(context: context)
        var intents: [SidebarIntent] = []
        manager.onIntent = { intent in intents.append(intent); return ModelSidebarActions(context: context).perform(intent) }
        manager.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let host = OffscreenRenderer.host(manager, scale: 1)
        host.orderFront(nil)
        defer { host.contentView = nil; host.close() }
        func pump() { OffscreenRenderer.settle(manager, runLoop: 0.002) }
        check(manager.columnOrder == original && original.enumerated().allSatisfy { i, id in
            manager.columnFrame(spaceID: id) == CGRect(x: 16 + CGFloat(i) * 256, y: 16, width: 244, height: 668)
        }, "SM1 real Library columns follow model order and 244/16/12 geometry")
        let controls = manager.controls(spaceID: original[0])!
        check(controls.displayedTitle == "Studio" && !controls.showsProfileChip && controls.grabber.frame == CGRect(x: 186, y: 10, width: 24, height: 24),
              "SM2 real header title, grabber, and one-Profile chip suppression")
        let gripPoint = controls.grabber.convert(CGPoint(x: 12, y: 12), to: nil)
        controls.grabber.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: gripPoint, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        check(controls.grabber.toolTip == nil && TooltipController.shared.visibleOrPendingTooltip?.title == "Drag to Reorder Space", "SM2 grabber uses the shared capsule tooltip")
        host.orderOut(nil)
        let outlineBeforeHidden = manager.outline(spaceID: original[0])!, rowsBeforeHidden = outlineBeforeHidden.numberOfRows
        let hiddenTab = model.newTab(in: original[0], url: Synthetic.url("hidden-manager"), title: "Hidden edit")
        pump()
        check(outlineBeforeHidden.numberOfRows == rowsBeforeHidden, "SM1 hidden Manager defers structural outline work")
        let hiddenReloads = SidebarDiagnostics.fullReloads
        host.orderFront(nil); manager.needsLayout = true; pump()
        check(outlineBeforeHidden.row(forItem: hiddenTab) >= 0 && SidebarDiagnostics.fullReloads == hiddenReloads, "SM1 showing Manager reconciles final lists without reloadData")
        let second = model.createProfile(name: "Work")!
        model.updateSpace(id: original[0], profileID: second.id); pump()
        check(controls.showsProfileChip && controls.displayedProfile == "Work", "SM2 two Profiles show the Space's real Profile chip")
        let menu = controls.makeMenu()
        check(menu.items.map(\.title) == ["Turn into Folder", "", "Delete"] && menu.items[0].submenu?.items.count == 2 && menu.items[2].isEnabled,
              "SM5 header menu has other-Space destinations and enabled Delete")

        func drag(_ controls: SpaceControlsView, deltas: [CGFloat], cancel: Bool = false) {
            let grip = controls.grabber
            let start = grip.convert(CGPoint(x: 12, y: 12), to: nil)
            func mouse(_ type: NSEvent.EventType, dx: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: start.applying(.init(translationX: dx, y: 0)), modifierFlags: [], timestamp: 0,
                                   windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            for dx in deltas { NSApp.postEvent(mouse(.leftMouseDragged, dx: dx), atStart: false) }
            if cancel {
                NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: start, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
                                                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!, atStart: false)
            } else { NSApp.postEvent(mouse(.leftMouseUp, dx: deltas.last ?? 0), atStart: false) }
            grip.mouseDown(with: mouse(.leftMouseDown, dx: 0)); pump()
        }
        let reloads = SidebarDiagnostics.fullReloads
        let alignment = SidebarDiagnostics.haptics["alignment", default: 0]
        drag(controls, deltas: [360])
        check(model.spaces.map(\.id) == [original[1], original[0], original[2]] && intents.filter { if case .moveSpace = $0 { true } else { false } }.count == 1,
              "SM3 native grabber tracking commits one moveSpace at release")
        undo.undo(); pump()
        let beforeTwo = SidebarDiagnostics.haptics["alignment", default: 0]
        drag(controls, deltas: [360, 620])
        check(SidebarDiagnostics.haptics["alignment", default: 0] - beforeTwo == 2 && SidebarDiagnostics.haptics["alignment", default: 0] > alignment, "HG4 Manager reorder crosses two slots: alignment ×2 (bottom reorder omitted by Q5)")
        undo.undo(); pump()
        intents = []
        drag(controls, deltas: [360], cancel: true)
        check(model.spaces.map(\.id) == original && intents.isEmpty, "SM3 Escape cancels native reorder without a model command")
        check(SidebarDiagnostics.fullReloads == reloads, "SM3 reorder and undo keep built column pages")

        let source = manager.outline(spaceID: original[0])!, destination = manager.outline(spaceID: original[1])!
        let tab = model.spaces[0].pinned[0].tab!
        let dropEvent = SidebarDragEvent(ids: [], window: host)
        dropEvent.draggingPasteboard.clearContents()
        let writer = source.dataSource!.outlineView!(source, pasteboardWriterForItem: tab)!
        dropEvent.draggingPasteboard.writeObjects([writer])
        let data = destination.dataSource!
        let alignBefore = SidebarDiagnostics.haptics["alignment", default: 0], dropBefore = SidebarDiagnostics.haptics["generic", default: 0]
        for slot in [0, 1, 1, 2] { _ = data.outlineView?(destination, validateDrop: dropEvent, proposedItem: nil, proposedChildIndex: slot + 1) }
        check(data.outlineView?(destination, acceptDrop: dropEvent, item: nil, childIndex: 1) == true, "SM4 real source writer and destination outline accept cross-column drop")
        pump()
        check(model.parent(of: tab.id) == .spacePinned(original[1]) && source.row(forItem: tab) == -1 && destination.row(forItem: tab) >= 0,
              "SM4 cross-column move updates both cached outlines")
        check(SidebarDiagnostics.haptics["alignment", default: 0] - alignBefore == 3 && SidebarDiagnostics.haptics["generic", default: 0] - dropBefore == 1,
              "HG1 three distinct outline insertion points and successful drop: alignment ×3, generic ×1")
        undo.undo(); pump()
        // The Manager uses the same real row selection and inline rename flow.
        let selectedTabs = Array(model.spaces[0].pinned.prefix(2).compactMap(\.tab))
        for tab in selectedTabs {
            let row = source.row(forItem: tab), rect = source.rect(ofRow: source.row(forItem: tab))
            check(row >= 0, "SM4 source row remains available after drop undo")
            let point = source.convert(CGPoint(x: 100, y: rect.midY), to: nil)
            source.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .command, timestamp: 0,
                                                     windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        pump()
        check(context.selection.ids == selectedTabs.map(\.id), "SM4 native Cmd-click multi-select works in a Manager column")
        let rowPoint = source.convert(CGPoint(x: 100, y: source.rect(ofRow: source.row(forItem: selectedTabs[0])).midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: rowPoint, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let selectionMenu = source.menu(for: event)!
        selectionMenu.performActionForItem(at: selectionMenu.indexOfItem(withTitle: "New Folder with 2 Items")); pump()
        let created = model.spaces[0].pinned.first?.folder
        check(created?.children.map(\.id) == selectedTabs.map(\.id) && host.firstResponder is NSTextView,
              "SM4 selection menu creates one folder and starts the real inline editor")
        host.makeFirstResponder(source)
        undo.undo(); pump()
        defaults.set(false, forKey: key)
        let haptics = SidebarDiagnostics.haptics
        _ = data.outlineView?(destination, validateDrop: dropEvent, proposedItem: nil, proposedChildIndex: 1)
        _ = data.outlineView?(destination, acceptDrop: dropEvent, item: nil, childIndex: 1); pump()
        drag(controls, deltas: [360])
        check(SidebarDiagnostics.haptics == haptics, "HG3 changing the setting off suppresses real drop and reorder haptics")
        defaults.set(true, forKey: key)

        let only = Synthetic.model()
        only.spaces = [only.spaces[0]]; only.rebuildIndex()
        let single = SpaceManagerView(context: SidebarContext(model: only, windowID: only.windows[0].id))
        check(single.controls(spaceID: only.spaces[0].id)?.makeMenu().item(withTitle: "Delete")?.isEnabled == false,
              "SM5 Delete is disabled with one Space")

        checkLargeManager()
        checkPagerAndSwipe()
        print("  SKIP SW1–SW4: lead Q5 prohibits bottom-switcher reorder; existing Space-icon drops remain covered by MS12")
    }

    private static func checkLargeManager() {
        let model = Synthetic.model(), profile = model.profiles[0]
        model.spaces = (0..<10).map { i in
            let space = Space(title: "Space \(i + 1)", icon: .emoji("📚"), profileID: profile.id)
            Synthetic.fillBulk(space, rows: 100); return space
        }
        model.windows[0].focusedSpaceID = model.spaces[0].id; model.rebuildIndex()
        let started = CACurrentMediaTime()
        let manager = SpaceManagerView(context: SidebarContext(model: model, windowID: model.windows[0].id))
        manager.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let host = OffscreenRenderer.host(manager, scale: 1)
        let elapsed = CACurrentMediaTime() - started
        defer { host.contentView = nil; host.close() }
        Checks.check(elapsed <= 0.120 && manager.builtColumnIDs.count <= 4, "SM6 10×100 Library to first layout \(Bench.ms(elapsed)) ≤ 120 ms; only \(manager.builtColumnIDs.count) visible columns built")
        let loaded = manager.builtColumnIDs, reloads = SidebarDiagnostics.fullReloads
        manager.scrollView.contentView.scroll(to: CGPoint(x: 1700, y: 0))
        manager.scrollView.reflectScrolledClipView(manager.scrollView.contentView)
        OffscreenRenderer.settle(manager, runLoop: 0.002)
        let added = manager.builtColumnIDs.subtracting(loaded).count
        Checks.check(added > 0 && SidebarDiagnostics.fullReloads - reloads == added, "SM6 horizontal scroll builds newly visible pages once (added \(added), reloads \(SidebarDiagnostics.fullReloads - reloads), visible \(manager.scrollView.documentVisibleRect))")
        let current = SidebarDiagnostics.fullReloads
        model.renameNode(id: model.spaces[7].pinned[0].id, title: "Updated in Library")
        OffscreenRenderer.settle(manager, runLoop: 0.002)
        Checks.check(SidebarDiagnostics.fullReloads == current, "SM6 model property changes cause no full reload")
    }

    private static func checkPagerAndSwipe() {
        let model = Synthetic.model(), state = model.windows[0], ids = model.spaces.map(\.id)
        let context = SidebarContext(model: model, windowID: state.id), delegate = RecordingDelegate()
        let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        defer { host.contentView = nil; host.close() }
        model.focusSpace(windowID: state.id, spaceID: ids[1]); OffscreenRenderer.settle(scene, runLoop: 0.01)
        let outline = scene.sidebar.focusedOutline, reloads = SidebarDiagnostics.fullReloads
        model.moveSpace(id: ids[1], to: 0); OffscreenRenderer.settle(scene, runLoop: 0.01)
        Checks.check(scene.sidebar.focusedOutline === outline && scene.sidebar.pagerOffset == 0 && SidebarDiagnostics.fullReloads == reloads,
                     "SM3 focused pager re-offsets after Space order changes without rebuilding its page")
        func scroll(_ phase: Int64, _ dx: Int32) -> NSEvent {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
            return NSEvent(cgEvent: event)!
        }
        let before = SidebarDiagnostics.haptics["levelChange", default: 0]
        scene.sidebar.simulateSwipe([scroll(1, -1), scroll(2, -125), scroll(2, -20), scroll(2, -20), scroll(4, 0)])
        OffscreenRenderer.settle(scene, runLoop: 0.01)
        Checks.check(SidebarDiagnostics.haptics["levelChange", default: 0] - before == 1, "HG2 Space swipe crosses threshold once: levelChange ×1")
        let short = SidebarDiagnostics.haptics["levelChange", default: 0]
        scene.sidebar.simulateSwipe([scroll(1, 1), scroll(2, 5), scroll(2, 5), scroll(4, 0)])
        Checks.check(SidebarDiagnostics.haptics["levelChange", default: 0] == short, "HG2 short Space swipe has no haptic")
        let haptics = SidebarDiagnostics.haptics
        UserDefaults.standard.set(false, forKey: "open.advanced.hapticOnTabReorder")
        scene.sidebar.simulateSwipe([scroll(1, -1), scroll(2, -125), scroll(4, 0)])
        Checks.check(SidebarDiagnostics.haptics == haptics, "HG3 setting off also suppresses a threshold-crossing swipe")
        UserDefaults.standard.set(true, forKey: "open.advanced.hapticOnTabReorder")
    }
}
