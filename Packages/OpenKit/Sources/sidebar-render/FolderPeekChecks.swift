import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

@MainActor
enum FolderPeekChecks {
    static func run() {
        let check = Checks.check
        let profile = Profile(name: "Peek checks")
        let tabs = (0..<4).map { Tab(url: URL(string: "https://example.invalid/peek/\($0)")!, title: "Peek \($0)") }
        let folder = Folder(title: "Peek", children: tabs.prefix(3).map { .tab($0) })
        let space = Space(title: "Peek", profileID: profile.id, pinned: [.folder(folder)], today: [.tab(tabs[3])])
        let window = BrowserWindowState(focusedSpaceID: space.id, selectedNodeBySpace: [space.id: tabs[1].id])
        let model = BrowserModel(profiles: [profile], spaces: [space], windows: [window])
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let context = SidebarContext(model: model, windowID: window.id), delegate = RecordingDelegate()
        var options = RenderScene.Options(); options.size = CGSize(width: 1000, height: 1100)
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        defer { host.contentView = nil; host.close() }
        let sidebar = scene.sidebar, outline = sidebar.focusedOutline!
        func pump() { OffscreenRenderer.settle(scene, runLoop: 0.015) }
        func click(_ id: ItemID, _ flags: NSEvent.ModifierFlags = []) {
            guard let frame = sidebar.rowFrame(nodeID: id) else { check(false, "FP visible click target"); return }
            let point = sidebar.convert(NSPoint(x: 95, y: frame.midY), to: nil)
            let now = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: now,
                windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags, timestamp: now + 0.01,
                windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            guard let target = host.contentView?.hitTest(point) else { check(false, "FP native hit target"); return }
            NSApp.postEvent(up, atStart: true); target.mouseDown(with: down)
            if let event = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { target.mouseUp(with: event) }
            pump()
        }
        func rows(_ ids: [ItemID]) -> Bool {
            sidebar.displayedRows == ["spacer"] + ids.map(\.description) + ["divider", "newTab", tabs[3].id.description]
        }
        pump()
        let originalChild = outline.view(atColumn: 0, row: outline.row(forItem: tabs[1]), makeIfNecessary: true)
        let reloads = SidebarDiagnostics.fullReloads, removed = SidebarDiagnostics.outlineItemsRemoved
        click(folder.id)
        check(folder.expansion == .peeked(tabs[1].id) && rows([folder.id, tabs[1].id]) && window.selectedNodeBySpace[space.id] == tabs[1].id,
              "FP5 real click keeps only selected second direct child and content selection")
        check(SidebarDiagnostics.fullReloads == reloads && SidebarDiagnostics.outlineItemsRemoved - removed == 2,
              "FP5 removes exactly two items without full reload")
        let retained = outline.view(atColumn: 0, row: outline.row(forItem: tabs[1]), makeIfNecessary: true)
        check(retained === originalChild, "FP5 retained peek child keeps its ordinary row view identity")
        context.forcedHover = .row(folder.id); pump()
        // Actual drawing diagnostic is public through SidebarView, avoiding private view casts.
        check(sidebar.drawnFolderGlyph(nodeID: folder.id) == "folder.peek", "FP6 peek selects Open's vector glyph (capture gate is separate)")
        let folderRow = outline.rowView(atRow: outline.row(forItem: folder), makeIfNecessary: true)!
        let axValue = folderRow.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: NSAccessibility.Attribute.value.rawValue)?.takeUnretainedValue() as? String
        let axExpanded = folderRow.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: NSAccessibility.Attribute.expanded.rawValue)?.takeUnretainedValue() as? Bool
        check(axExpanded == false && axValue == "1 tab shown", "FP9 real AX dispatcher reports expanded false and value 1 tab shown")
        context.forcedHover = .row(tabs[1].id); pump()
        check(sidebar.tabAction(tabID: tabs[1].id) != nil && sidebar.contextMenu(nodeID: tabs[1].id)?.items.isEmpty == false,
              "FP9 ordinary peek child keeps hover action and production context menu")
        click(tabs[1].id, .command); click(tabs[3].id, .command)
        check(context.selection.ids == [tabs[1].id, tabs[3].id] && !context.selection.contains(tabs[0].id), "FP9 Cmd selection includes exposed child and excludes hidden siblings")
        context.selection.clear()
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: tabs[3].id); pump()
        check(folder.expansion == .peeked(tabs[1].id) && rows([folder.id, tabs[1].id]), "FP8 selecting Today leaves stored peek")
        let beforeCollapse = SidebarDiagnostics.outlineItemsRemoved
        click(folder.id)
        check(folder.expansion == .collapsed && rows([folder.id]) && SidebarDiagnostics.outlineItemsRemoved - beforeCollapse == 1,
              "FP7 click peek fully collapses and removes exactly one child")
        click(folder.id)
        check(folder.expansion == .expanded && rows([folder.id] + tabs.prefix(3).map(\.id)), "FP7 click collapsed expands all three real children")
        click(folder.id)
        check(folder.expansion == .collapsed && rows([folder.id]), "FP7 collapse with Today selected creates no peek")
        click(folder.id)
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: tabs[1].id); pump(); click(folder.id)
        let drag = SidebarDragEvent(ids: [tabs[1].id], window: host)
        check(outline.dataSource?.outlineView?(outline, acceptDrop: drag, item: nil, childIndex: outline.numberOfRows) == true,
              "FP8 production drop accepts exposed child moving out")
        pump()
        check(folder.expansion == .collapsed && model.parent(of: tabs[1].id) != .folder(folder.id), "FP8 drag out clears peek")
        undo.undo(); pump()
        check(folder.expansion == .peeked(tabs[1].id), "FP8 drag undo restores peek")
        model.closeTab(id: tabs[1].id); pump()
        check(folder.expansion == .collapsed && !sidebar.displayedRows.contains(tabs[1].id.description), "FP8 real remove clears peek and native child")
        undo.undo(); pump()
        let left = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
        // Focus the first real row through Down, then exercise Left/Right.
        host.makeFirstResponder(outline)
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        outline.keyDown(with: down); pump()
        outline.keyDown(with: left); pump()
        check(folder.expansion == .collapsed, "FP7 Left on peek fully collapses")
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        outline.keyDown(with: right); pump()
        check(folder.expansion == .expanded, "FP7 Right expands the focused folder")
        model.selectNode(windowID: window.id, spaceID: space.id, nodeID: tabs[1].id); pump()
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        outline.keyDown(with: enter); pump()
        check(folder.expansion == .peeked(tabs[1].id), "FP7 Return collapses the focused folder through selected-child policy")
        let spaceKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        outline.keyDown(with: spaceKey); pump()
        check(folder.expansion == .collapsed, "FP7 Space on peek fully collapses")
        outline.keyDown(with: enter); pump()
        check(folder.expansion == .expanded, "FP7 Return on collapsed expands")
        check(Motion.folderExpand == 0.20 && Motion.folderCollapse == 0.25 && Motion.rowStructure == 0.22, "FP7 distinct measured folder durations preserve general row duration")
        let split = model.makeSplit(tabIDs: [tabs[0].id, tabs[1].id])!
        model.setFolderExpansion(folderID: folder.id, .peeked(split.id)); pump()
        let splitCell = outline.view(atColumn: 0, row: outline.row(forItem: split), makeIfNecessary: true)
        check(splitCell?.identifier?.rawValue == "split" && rows([folder.id, split.id]) && sidebar.contextMenu(nodeID: split.id)?.items.isEmpty == false,
              "FP9 peek split is the ordinary interactive SplitCellView")
        folder.iconOverride = .symbol("star.fill"); pump()
        check(sidebar.drawnFolderGlyph(nodeID: folder.id) == "star.fill", "FP6 typed custom folder icon retains precedence over peek art")
        folder.iconOverride = nil; pump()
        model.setExpanded(folderID: folder.id, expanded: true); pump()
        check(sidebar.drawnFolderGlyph(nodeID: folder.id) == "folder.open", "FP6 expanded folder keeps existing glyph")
        SidebarDiagnostics.forceAnimations = true; Motion.reduceMotionOverride = true
        model.setExpanded(folderID: folder.id, expanded: false); pump()
        check(folder.expansion == .collapsed && rows([folder.id]) && SidebarDiagnostics.folderTransitionDuration == 0,
              "FP7 Reduce Motion reaches final collapsed rows with zero duration")
        Motion.reduceMotionOverride = nil; SidebarDiagnostics.forceAnimations = false
        check(sidebar.drawnFolderGlyph(nodeID: folder.id) == "folder.closed", "FP6 collapsed folder keeps existing glyph")
        _ = model.moveNode(id: folder.id, to: .spaceToday(space.id), at: 0)
        model.setFolderExpansion(folderID: folder.id, .peeked(tabs[2].id))
        context.forcedHover = .row(tabs[2].id); pump()
        let close = sidebar.tabAction(tabID: tabs[2].id)?.view
        let accepted = close?.accessibilityPerformPress() == true; pump()
        check(accepted && model.tab(id: tabs[2].id) == nil && folder.expansion == .collapsed,
              "FP8 Today peek child's ordinary close button removes row and clears peek")
        undo.undo(); pump()
        check(model.tab(id: tabs[2].id) === tabs[2] && folder.expansion == .peeked(tabs[2].id),
              "FP8 one ordinary close undo restores Today child and peek")
        check(SidebarDiagnostics.fullReloads == reloads, "FP5–FP9 all transitions remain incremental")
    }

    /// Exercise the real outline validation/acceptance and model mutation together.
    static func drops() {
        for urlDrop in [false, true] {
            for target in ["above C", "below C", "on C", "on folder"] {
                let profile = Profile(name: "FP drop")
                let tabs = (0..<4).map { Tab(url: URL(string: "https://example.invalid/drop/\($0)")!, title: "Drop \($0)") }
                let folder = Folder(title: "Drop ABC", children: tabs.prefix(3).map { .tab($0) })
                let space = Space(title: "Drop", profileID: profile.id, pinned: [.folder(folder)], today: [.tab(tabs[3])])
                let window = BrowserWindowState(focusedSpaceID: space.id, selectedNodeBySpace: [space.id: tabs[2].id])
                let model = BrowserModel(profiles: [profile], spaces: [space], windows: [window])
                model.setFolderExpansion(folderID: folder.id, .peeked(tabs[2].id))
                let context = SidebarContext(model: model, windowID: window.id), delegate = RecordingDelegate()
                let scene = RenderScene(context: context, options: RenderScene.Options(), delegate: delegate)
                let host = OffscreenRenderer.host(scene, scale: 1)
                defer { host.contentView = nil; host.close() }
                OffscreenRenderer.settle(scene)
                let outline = scene.sidebar.focusedOutline!, data = outline.dataSource!
                let event = SidebarDragEvent(ids: urlDrop ? [] : [tabs[3].id], window: host)
                let url = URL(string: "https://example.invalid/dropped-url")!
                if urlDrop { event.draggingPasteboard.clearContents(); event.draggingPasteboard.writeObjects([url as NSURL]) }
                let item: Any = target == "on C" ? tabs[2] : folder
                let index = target == "above C" ? 0 : target == "below C" ? 1 : NSOutlineViewDropOnItemIndex
                let validated = data.outlineView?(outline, validateDrop: event, proposedItem: item, proposedChildIndex: index)
                // AppKit uses the displayed parent/index retargeted by validateDrop
                // when the proposal is ON the exposed child. Never feed model index 2
                // back into an outline which has only one displayed child.
                let accepted = data.outlineView?(outline, acceptDrop: event,
                    item: target == "on C" ? folder : item, childIndex: target == "on C" ? 0 : index) == true
                OffscreenRenderer.settle(scene)
                var expected = tabs.prefix(3).map { $0.url }
                expected.insert(urlDrop ? url : tabs[3].url, at: target == "above C" || target == "on C" ? 2 : 3)
                Checks.check(validated == (urlDrop ? .copy : .move) && accepted && folder.children.compactMap(\.tab).map(\.url) == expected,
                    "FP-drop \(urlDrop ? "URL" : "node") \(target) maps peeked C in [A,B,C] to model order")
            }
        }
    }

}
