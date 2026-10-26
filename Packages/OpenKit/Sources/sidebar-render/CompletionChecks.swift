import AppKit
import OpenDesign
import OpenModel
import OpenSidebar
import OpenStore

/// Completion flows through real AppKit views, window events, and the model.
@MainActor
enum CompletionChecks {
    static func run() {
        let check = Checks.check
        let model = Synthetic.model()
        let state = model.windows[0], space = model.spaces[0]
        let context = SidebarContext(model: model, windowID: state.id)
        let delegate = RecordingDelegate()
        var options = RenderScene.Options()
        options.size = CGSize(width: 1000, height: 1100)
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        defer { host.contentView = nil; host.close() }
        let sidebar = scene.sidebar, outline = sidebar.focusedOutline!
        func pump() { OffscreenRenderer.settle(scene, runLoop: 0.01) }
        func click(_ id: ItemID, _ flags: NSEvent.ModifierFlags = []) {
            guard let frame = sidebar.rowFrame(nodeID: id) else { return }
            let point = sidebar.convert(NSPoint(x: 100, y: frame.midY), to: nil)
            let now = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: now,
                                          windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags, timestamp: now + 0.01,
                                        windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            guard let target = scene.hitTest(point) else { return }
            NSApp.postEvent(up, atStart: true)
            target.mouseDown(with: down)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { target.mouseUp(with: pending) }
            pump()
        }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            host.makeFirstResponder(outline)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            host.firstResponder?.keyDown(with: event)
            pump()
        }
        func order() -> [ItemID] {
            (0..<outline.numberOfRows).compactMap { row in
                switch outline.item(atRow: row) {
                case let t as Tab: t.id
                case let f as Folder: f.id
                case let s as Split: s.id
                default: nil
                }
            }
        }
        let pinned = space.pinned[0].id, today = space.today[2].id
        click(pinned)
        let reloads = SidebarDiagnostics.fullReloads, layouts = SidebarDiagnostics.tabRowLayouts
        click(today, .command)
        check(context.selection.ids == [pinned, today] && state.selectedNodeBySpace[space.id] == pinned,
              "MS1 first Cmd-click includes current and clicked rows, keeps model selection")
        check(SidebarDiagnostics.tabRowLayouts - layouts <= 2,
              "MS1 only affected rows lay out (\(SidebarDiagnostics.tabRowLayouts - layouts) passes)")
        click(pinned, .command) // toggles it out and sets the range anchor
        click(today, .shift)
        check(context.selection.ids == order(), "MS2 Shift-click spans Pinned and Today, skips all sentinels")
        click(space.pinned[2].id)
        check(context.selection.isEmpty && state.selectedNodeBySpace[space.id] == space.pinned[2].id,
              "MS4 plain click clears selection and selects through the delegate")
        click(pinned)
        for _ in 0..<3 { key(125, .shift) }
        check(context.selection.ids == Array(space.pinned.prefix(4).map(\.id)), "MS5 Shift+Down three times selects four rows")
        let selectedRow = outline.rowView(atRow: sidebar.displayedRows.firstIndex(of: space.pinned[1].id.description)!, makeIfNecessary: true)!
        let unselectedRow = outline.rowView(atRow: sidebar.displayedRows.firstIndex(of: space.today[0].id.description)!, makeIfNecessary: true)!
        // Ask AppKit's AX attribute dispatcher, rather than calling the row override.
        func axSelected(_ row: NSView) -> Bool? {
            row.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: NSAccessibility.Attribute.selected.rawValue)?.takeUnretainedValue() as? Bool
        }
        check(axSelected(selectedRow) == true && axSelected(unselectedRow) == false, "MS5 AXSelected attribute API exposes selected and unselected real rows")
        key(53)
        check(context.selection.isEmpty, "MS5 Escape clears selection")
        key(125, .shift); key(126)
        check(context.selection.isEmpty, "MS5 plain Up clears selection")
        // Cmd-selected rows outside the Shift range survive; reversing the range removes its old tail.
        click(pinned); click(today, .command); click(space.pinned[1].id, .command)
        click(space.pinned[3].id, .shift); click(space.pinned[2].id, .shift)
        check(context.selection.ids == [pinned, space.pinned[1].id, space.pinned[2].id, today],
              "MS2 Shift range shrinks and preserves Cmd-selected rows outside it")
        let folder = model.createFolder(in: .spacePinned(space.id), title: "Selection folder")!
        let child = model.newTab(in: space.id, url: Synthetic.url("selection-child"), title: "Nested row")
        model.moveNode(id: child.id, to: .folder(folder.id), at: nil)
        pump()
        click(child.id, .command)
        model.setExpanded(folderID: folder.id, expanded: false); pump()
        check(!context.selection.contains(child.id), "MS3 collapse prunes selected descendants")
        model.setExpanded(folderID: folder.id, expanded: true); pump()
        click(pinned); click(folder.id, .command); click(child.id, .command)
        model.setExpanded(folderID: folder.id, expanded: false); pump()
        check(context.selection.anchor == folder.id, "MS3 lost anchor moves to the nearest kept row")
        key(125, .shift)
        let next = order()[order().firstIndex(of: folder.id)! + 1]
        check(context.selection.ids == [pinned, folder.id, next], "MS3 Shift+Down after anchor collapse extends from the nearest kept row")
        click(pinned); click(today, .shift)
        check(!context.selection.contains(child.id) && context.selection.contains(folder.id), "MS3 range skips collapsed children and includes the folder")
        model.setPinnedSectionCollapsed(spaceID: space.id, collapsed: true); pump()
        check(context.selection.ids.allSatisfy { space.today.map(\.id).contains($0) }, "MS3 collapsing Pinned prunes hidden rows")
        model.setPinnedSectionCollapsed(spaceID: space.id, collapsed: false); pump()
        click(pinned); click(today, .command)
        model.closeTab(id: today); pump()
        check(context.selection.ids == [pinned], "MS3 removal prunes the deleted row")
        check(SidebarDiagnostics.fullReloads == reloads, "MS1–MS5 no full reloads during selection or pruning")

        // The layer is the actual row's fill; the pixel sample also crosses the real renderer.
        func rowFill(_ id: ItemID) -> CALayer? {
            let index = sidebar.displayedRows.firstIndex(of: id.description)!
            return outline.rowView(atRow: index, makeIfNecessary: true)?.layer?.sublayers?.first { $0.name == "sidebar-row-fill" }
        }
        func pixel(_ image: CGImage, at p: CGPoint) -> [Double] {
            let data = image.dataProvider!.data!, bytes = CFDataGetBytePtr(data)!
            let start = Int(p.y) * image.bytesPerRow + Int(p.x) * image.bitsPerPixel / 8
            return (0..<3).map { Double(bytes[start + $0]) }
        }
        for appearance in [ContentAppearance.light, .dark] {
            // A default Space follows the forced appearance, unlike a themed Space.
            space.theme = SpaceTheme()
            context.systemAppearance = appearance
            context.selection.clear(); pump()
            let other = space.pinned[1].id
            let frame = sidebar.rowFrame(nodeID: other)!
            let sample = scene.convert(CGPoint(x: 150, y: frame.minY + 5), from: sidebar)
            let before = pixel(OffscreenRenderer().snapshot(scene, scale: 1), at: sample)
            click(other, .command)
            let fill = rowFill(other)!
            let color = NSColor(cgColor: SidebarRole.rowMultiselected.cgColor(appearance))!.usingColorSpace(.sRGB)!
            let expected = zip(before, [color.redComponent, color.greenComponent, color.blueComponent]).map { old, ink in
                old * (1 - color.alphaComponent) + ink * 255 * color.alphaComponent
            }
            let after = pixel(OffscreenRenderer().snapshot(scene, scale: 1), at: sample)
            let delta = ColorMath.deltaE2000(after, expected)
            check(delta <= 0.5, "MS6 \(appearance) multi-fill pixel ΔE00 \(String(format: "%.3f", delta)) ≤ 0.5")
            check(fill.frame == CGRect(x: 8, y: 2, width: 212, height: 36) && fill.cornerRadius == 12 && fill.shadowOpacity == 0,
                  "MS6 \(appearance) multi-fill uses row geometry, radius 12, no shadow")
            let currentFill = rowFill(pinned)!
            check(currentFill.backgroundColor == (context.style(for: space).selectedFill(appearance)).cgColor &&
                  currentFill.shadowOpacity == Float(SidebarRole.rowSelectedShadow.resolved(appearance).alpha),
                  "MS6 \(appearance) current row keeps selected fill and shadow")
            context.forcedHover = .row(other); pump()
            check(fill.backgroundColor == SidebarRole.rowMultiselected.cgColor(appearance), "MS6 hover keeps the multi-fill")
            context.forcedHover = nil
        }
        model.focusSpace(windowID: state.id, spaceID: model.spaces[1].id); pump()
        check(context.selection.isEmpty, "MS13 Space switch clears the selection")
        let night = model.spaces[2]
        model.focusSpace(windowID: state.id, spaceID: night.id); pump()
        let group = night.pinned[0].folder!, split = group.children.compactMap(\.split)[0]
        click(group.id, .command); click(split.id, .command)
        check(context.selection.ids == [group.id, split.id] && state.selectedNodeBySpace[night.id] == nil,
              "MS1 Cmd-click with no current row selects folders and splits without activating them")
        let nightOutline = sidebar.focusedOutline!
        let splitIndex = sidebar.displayedRows.firstIndex(of: split.id.description)!
        let splitFill = nightOutline.rowView(atRow: splitIndex, makeIfNecessary: true)?.layer?.sublayers?.first { $0.name == "sidebar-row-fill" }
        check(splitFill?.frame == CGRect(x: 24, y: 2, width: 196, height: 36) &&
              splitFill?.backgroundColor == SidebarRole.rowMultiselected.cgColor(.dark) &&
              sidebar.splitRowCells(splitID: split.id)?.cells.isEmpty == true,
              "MS6 indented multi-selected split uses one fill and keeps its pane cells hidden")
        model.moveNode(id: split.id, to: .spacePinned(night.id), at: 0); pump()
        check(context.selection.ids == [split.id, group.id], "MS3 a structural move keeps selected IDs in display order")
        let favorite = sidebar.favoritesCollection.item(at: IndexPath(item: 0, section: 0))!.view
        _ = favorite.accessibilityPerformPress(); pump()
        check(context.selection.isEmpty && state.selectedNodeBySpace[night.id] == model.profiles[0].favorites[0].id,
              "MS4 plain Favorite activation clears the row selection and selects the actual tab")
        runActions()
        runRows()
    }
}

/// Records batch boundaries while forwarding every write to the real SQLite
/// store. It replaces no model, view, validation, undo, or persistence behavior.
@MainActor
private final class CompletionArchiveRecorder: ArchiveSink {
    let store: ArchiveStore
    var batches = 0
    init(store: ArchiveStore) { self.store = store }
    func archive(_ entries: [ArchiveEntry]) { batches += 1; store.archive(entries) }
    func archive(_ entries: [ArchiveEntry], folders: [ArchiveFolderEntry]) { batches += 1; store.archive(entries, folders: folders) }
    func archiveFolder(_ entry: ArchiveFolderEntry) { batches += 1; store.archiveFolder(entry) }
    func discardArchived(ids: [ItemID]) { store.discardArchived(ids: ids) }
}

extension CompletionChecks {
    static func runRows() {
        let check = Checks.check, model = Synthetic.model(), undo = UndoManager()
        undo.groupsByEvent = false; model.undoManager = undo
        let state = model.windows[0], space = model.spaces[0]
        let context = SidebarContext(model: model, windowID: state.id), delegate = RecordingDelegate()
        var options = RenderScene.Options(); options.size = CGSize(width: 1000, height: 1100)
        let scene = RenderScene(context: context, options: options, delegate: delegate), host = OffscreenRenderer.host(scene, scale: 1)
        defer { host.contentView = nil; host.close() }
        let sidebar = scene.sidebar, outline = sidebar.focusedOutline!
        func pump() { OffscreenRenderer.settle(scene, runLoop: 0.001) }
        let unread = model.newTab(in: space.id, url: Synthetic.url("unread"), title: "Background", unread: true)
        pump()
        let frame = sidebar.rowFrame(nodeID: unread.id)!
        check(sidebar.unreadDotFrame(nodeID: unread.id) == CGRect(x: 199, y: frame.minY + 17, width: 6, height: 6), "UB1 unread dot is 6 pt at (W − 26, y + 20)")
        let originalTheme = space.theme, originalAppearance = context.systemAppearance
        for (name, appearance, themed) in [("themed light", ContentAppearance.light, true), ("unthemed light", .light, false), ("unthemed dark", .dark, false)] {
            space.theme = themed ? originalTheme : SpaceTheme()
            context.systemAppearance = appearance; pump()
            let dot = sidebar.unreadDotFrame(nodeID: unread.id)!
            let image = OffscreenRenderer().snapshot(scene, scale: 1)
            let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
            func luminance(_ p: CGPoint) -> Double {
                let i = Int(p.y) * image.bytesPerRow + Int(p.x) * 4
                let rgb = (0..<3).map { c -> Double in let x = Double(bytes[i+c])/255; return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
                return rgb[0]*0.2126 + rgb[1]*0.7152 + rgb[2]*0.0722
            }
            let center = scene.convert(CGPoint(x: dot.midX, y: dot.midY), from: sidebar)
            let ink = luminance(center), base = luminance(CGPoint(x: center.x-8,y: center.y))
            let ratio = (max(ink,base)+0.05)/(min(ink,base)+0.05)
            if !themed && appearance == .light {
                let i = Int(center.y) * image.bytesPerRow + Int(center.x) * 4
                check(bytes[i + 2] > bytes[i] + 40 && bytes[i + 2] > bytes[i + 1] + 40, "UB1 unthemed light dot keeps the passing blue Space accent in rendered ink")
            }
            check(ratio >= 3, "UB1 \(name) actual unread dot contrast \(String(format: "%.2f",ratio)):1 ≥ 3:1 (guess pending C5)")
        }
        space.theme = originalTheme; context.systemAppearance = originalAppearance; pump()
        let snapshotRoot = FileManager.default.temporaryDirectory.appendingPathComponent("unread-relaunch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        do {
            let store = SnapshotStore(root: snapshotRoot)
            try store.saveNow(model: model)
            let restored = try store.load()!
            let restoredContext = SidebarContext(model: restored, windowID: state.id)
            let restoredDelegate = RecordingDelegate()
            let restoredScene = RenderScene(context: restoredContext, options: options, delegate: restoredDelegate)
            let restoredHost = OffscreenRenderer.host(restoredScene, scale: 1)
            check(restored.tab(id: unread.id)?.isUnread == true && restoredScene.sidebar.unreadDotFrame(nodeID: unread.id) == sidebar.unreadDotFrame(nodeID: unread.id), "UB1 unread dot survives real SnapshotStore save/load and rebuilt sidebar")
            restoredHost.contentView = nil; restoredHost.close()
        } catch { check(false, "UB1 unread relaunch through SnapshotStore: \(error)") }
        context.forcedHover = .row(unread.id); pump()
        check(sidebar.unreadDotFrame(nodeID: unread.id) == nil && sidebar.tabAction(tabID: unread.id) != nil, "UB2 hover gives the dot slot to the close button")
        context.forcedHover = nil
        context.peekBadges = [unread.id: SidebarPeekBadge(url: Synthetic.url("preview"))]; pump()
        check(sidebar.unreadDotFrame(nodeID: unread.id) == nil && sidebar.peekBadgeFrame(tabID: unread.id) != nil, "UB5 Peek badge wins over unread")
        context.peekBadges = [:]; pump()
        let layouts = SidebarDiagnostics.tabRowLayouts
        let row = sidebar.displayedRows.firstIndex(of: unread.id.description)!
        check(outline.rowView(atRow: row, makeIfNecessary: true)?.accessibilityPerformPress() == true, "UB3 real row activation selects the unread tab")
        pump()
        check(!unread.isUnread && sidebar.unreadDotFrame(nodeID: unread.id) == nil && SidebarDiagnostics.tabRowLayouts - layouts <= 1,
              "UB3 selecting clears unread with at most its own row layout (\(SidebarDiagnostics.tabRowLayouts - layouts))")
        let folder = model.createFolder(in: .spacePinned(space.id), title: "Unread folder")!
        let child = model.newTab(in: space.id, url: Synthetic.url("nested-unread"), title: "Nested unread", unread: true)
        model.moveNode(id: child.id, to: .folder(folder.id), at: nil); pump()
        model.setExpanded(folderID: folder.id, expanded: false); pump()
        check(sidebar.unreadDotFrame(nodeID: folder.id) != nil && sidebar.unreadDotFrame(nodeID: child.id) == nil, "UB4 collapsed folder summarizes an unread descendant")
        model.setExpanded(folderID: folder.id, expanded: true); pump()
        check(sidebar.unreadDotFrame(nodeID: folder.id) == nil && sidebar.unreadDotFrame(nodeID: child.id) != nil, "UB4 expanding moves unread back to its child")

        let pinned = space.pinned[0].tab!
        pinned.url = pinned.url.appendingPathComponent("later"); pump()
        let pinnedFrame = sidebar.rowFrame(nodeID: pinned.id)!
        let point = sidebar.convert(CGPoint(x: 26, y: pinnedFrame.minY + 20), to: nil)
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        outline.enclosingScrollView!.superview!.mouseMoved(with: hover); pump()
        let reset = sidebar.resetAction(tabID: pinned.id)
        check(reset.map { sidebar.convert($0.bounds, from: $0) == CGRect(x: 16, y: pinnedFrame.minY + 10, width: 20, height: 20) } == true &&
              TooltipController.shared.visibleOrPendingTooltip?.title == "Back to Pinned URL", "SP1 favicon hover shows reset plate and tooltip")
        func glyphPixels() -> [UInt8] {
            guard let reset = sidebar.resetAction(tabID: pinned.id) else { return [] }
            let region = scene.convert(reset.bounds, from: reset).integral
            let image = OffscreenRenderer().snapshot(scene, scale: 1), data = image.dataProvider!.data!, bytes = CFDataGetBytePtr(data)!
            return (Int(region.minY)..<Int(region.maxY)).flatMap { y in
                Array(UnsafeBufferPointer(start: bytes + y * image.bytesPerRow + Int(region.minX) * 4, count: Int(region.width) * 4))
            }
        }
        let resetPixels = glyphPixels()
        let option = NSEvent.keyEvent(with: .flagsChanged, location: point, modifierFlags: .option, timestamp: 0,
                                      windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
        outline.flagsChanged(with: option); pump()
        check(reset?.accessibilityLabel() == "Separate From Pinned Tab" && TooltipController.shared.visibleOrPendingTooltip?.title == "Separate From Pinned Tab" &&
              glyphPixels() != resetPixels, "SP2 Option swaps the actual rendered glyph, label, and tooltip")
        delegate.log = []; _ = reset?.accessibilityPerformPress()
        check(delegate.log == [.separateFromPinned(tabID: pinned.id)] && pinned.url != pinned.pinnedURL,
              "SP3 Option reset routes separate to the App without resetting the model early")
        context.isOptionHeld = false; delegate.log = []; _ = reset?.accessibilityPerformPress(); pump()
        check(delegate.log == [.resetToPinnedURL(tabID: pinned.id)] && pinned.url == pinned.pinnedURL, "SP3 normal reset routes through the real model")
        check(sidebar.resetAction(tabID: pinned.id) == nil, "SP4 no reset plate when the pinned URL is current")

        let tidy = model.newTab(in: space.id, url: URL(string: "https://mail.google.com/mail/u/0/#search")!, title: "Inbox (3) - reader@example.invalid - Gmail")
        pump()
        check(sidebar.drawnTitle(tabID: tidy.id) == "Inbox (3)", "TT1 the real Gmail row uses its tidy display title")
        let titleLayouts = SidebarDiagnostics.tabRowLayouts
        tidy.title = "Sent (4) - reader@example.invalid - Gmail"; pump()
        check(sidebar.drawnTitle(tabID: tidy.id) == "Sent (4)" && SidebarDiagnostics.tabRowLayouts == titleLayouts,
              "TT2 title change updates its row title without laying out any tab row")

        let deep = model.createFolder(in: .folder(folder.id), title: "Never opened")!
        let deepest = model.createFolder(in: .folder(deep.id), title: "Deepest")!
        model.setExpanded(folderID: folder.id, expanded: false); model.setExpanded(folderID: deep.id, expanded: false); model.setExpanded(folderID: deepest.id, expanded: false); pump()
        undo.removeAllActions()
        let reloads = SidebarDiagnostics.fullReloads
        let expanded = model.setAllFoldersExpanded(spaceID: space.id, expanded: true); pump()
        check(expanded == 3 && [folder, deep, deepest].allSatisfy { outline.isItemExpanded($0) } && sidebar.displayedRows == Checks.expectedRows(context: context),
              "EA1 Expand All loads and expands every depth, including previously hidden children")
        undo.removeAllActions()
        _ = model.setAllFoldersExpanded(spaceID: space.id, expanded: false); pump()
        check([folder, deep, deepest].allSatisfy { !$0.isExpanded } && sidebar.displayedRows == Checks.expectedRows(context: context), "EA2 Collapse All matches the model")
        undo.undo(); pump()
        check([folder, deep, deepest].allSatisfy { outline.isItemExpanded($0) } && !undo.canUndo, "EA2 one undo reopens all folders")
        undo.removeAllActions()
        check(model.setAllFoldersExpanded(spaceID: space.id, expanded: true) == 0 && !undo.canUndo && SidebarDiagnostics.fullReloads == reloads,
              "EA3 same-value Expand All creates no undo or full reload")
    }

    static func runActions() {
        let check = Checks.check
        let model = Synthetic.model(), undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-actions-\(UUID())")
        let store = ArchiveStore(fileURL: root.appendingPathComponent("archive.sqlite3"))
        let archive = CompletionArchiveRecorder(store: store)
        model.archiveSink = archive
        defer { store.flushQueue(); try? FileManager.default.removeItem(at: root) }
        let state = model.windows[0], space = model.spaces[0]
        let context = SidebarContext(model: model, windowID: state.id), delegate = RecordingDelegate()
        var options = RenderScene.Options()
        options.size = CGSize(width: 1000, height: 1100)
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        defer { host.contentView = nil; host.close() }
        let sidebar = scene.sidebar, outline = sidebar.focusedOutline!
        var changes: [TreeChange] = []
        let observer = model.addObserver { changes.append($0) }
        defer { model.removeObserver(observer) }
        func pump() { OffscreenRenderer.settle(scene, runLoop: 0.005) }
        func select(_ ids: [ItemID]) { context.selection.select(ids, anchor: ids.first); pump() }
        func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isAlternate }.map { $0.isSeparatorItem ? "—" : $0.title } }
        func perform(_ menu: NSMenu, _ title: String) {
            let index = menu.indexOfItem(withTitle: title)
            check(index >= 0, "menu exposes \(title)")
            if index >= 0 { menu.performActionForItem(at: index); pump() }
        }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], focusOutline: Bool = true) {
            if focusOutline { host.makeFirstResponder(outline) }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            host.firstResponder?.keyDown(with: event); pump()
        }
        func records() -> [ArchivedTabRecord] {
            store.flushQueue()
            var rows: [ArchivedTabRecord]?
            Task { @MainActor in rows = await store.recent(limit: 100) }
            let deadline = Date().addingTimeInterval(2)
            while rows == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            check(rows != nil, "real SQLite archive read completes")
            return rows ?? []
        }
        let ids = [space.pinned[1].id, space.pinned[3].id, space.today[1].id]
        select(ids)
        model.tab(id: ids[0])?.live.hasWebContent = true
        context.forcedHover = .row(ids[0]); pump()
        let row = outline.rowView(atRow: sidebar.displayedRows.firstIndex(of: ids[0].description)!, makeIfNecessary: true)!
        func controls(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(controls) }
        if let button = controls(row).first(where: { $0.accessibilityLabel()?.lowercased() == "unload tab" || $0.accessibilityLabel()?.lowercased() == "close tab" }) {
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 0)!
            delegate.log = []; NSApp.postEvent(up, atStart: true); outline.mouseDown(with: down)
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
            pump()
            check(!delegate.log.contains(where: { if case .select = $0 { true } else { false } }) && !(host.firstResponder is NSTextView), "MS7 selected accessory press neither activates nor renames")
        } else { check(false, "MS7 selected row exposes its accessory control") }
        context.forcedHover = nil; select(ids)
        let menu = sidebar.contextMenu(nodeID: ids[1])!
        check(titles(menu) == ["Copy Links", "Copy links as Markdown", "—", "New Folder with 3 Items", "Move to", "—", "Pin Tabs", "Duplicate", "—", "Archive Items"],
              "MS7 tabs selection menu order and titles")
        delegate.log = []
        perform(menu, "Copy links as Markdown")
        check(delegate.log == [.copyLinks(ids: ids, markdown: true)] && context.selection.ids == ids,
              "MS7 Copy Links passes ordered IDs to the App and preserves selection")
        let newSpace = menu.item(withTitle: "Move to")!.submenu!
        delegate.log = []
        perform(newSpace, "New Space…")
        check(delegate.log == [.moveNodesToNewSpace(ids: ids)] && context.selection.ids == ids,
              "MS7 New Space passes the full selection; an unhandled App form preserves it")
        changes = []
        let pinnedBefore = space.pinned.map(\.id), todayBefore = space.today.map(\.id)
        let reloads = SidebarDiagnostics.fullReloads
        perform(menu, "New Folder with 3 Items")
        let folder = space.pinned[1].folder!
        check(folder.children.map(\.id) == ids && changes.filter { if case .insert = $0 { true } else { false } }.count == 1 &&
              changes.filter { if case .move = $0 { true } else { false } }.count == 3,
              "MS8 one folder insert and three moves, at the first selected slot")
        check(((host.firstResponder as? NSTextView)?.string == "Folder" || (host.firstResponder as? NSTextField)?.stringValue == "Folder") && context.selection.isEmpty,
              "MS8 inline rename starts and consumes selection (responder \(String(describing: host.firstResponder)))")
        key(53, focusOutline: false)
        undo.undo(); pump()
        check(space.pinned.map(\.id) == pinnedBefore && space.today.map(\.id) == todayBefore,
              "MS8 one undo restores the complete pre-folder order")

        let group = model.createFolder(in: .spacePinned(space.id), title: "Action folder")!
        let nested = model.newTab(in: space.id, url: Synthetic.url("folder-child"), title: "Folder child")
        model.moveNode(id: nested.id, to: .folder(group.id), at: nil); pump()
        select([ids[0], group.id])
        let mixed = sidebar.contextMenu(nodeID: group.id)!
        check(titles(mixed) == ["Copy Links", "Copy links as Markdown", "—", "New Folder with 2 Items", "Move to", "—", "Duplicate", "—", "Archive Items", "Delete"] &&
              !titles(mixed).contains(where: { $0.contains("Archive Folder") }), "MS7 mixed menu has Delete only and no pin action")
        delegate.log = []
        perform(mixed, "Delete")
        check(delegate.log == [.deleteFolders(ids: [group.id])] && model.node(id: group.id) != nil && context.selection.ids == [ids[0], group.id],
              "MS7 Delete requests the App confirmation; no premature model or selection change")
        delegate.log = []; key(51)
        check(delegate.log == [.deleteFolders(ids: [ids[0], group.id])], "Delete on a mixed selection requests one confirmation for one eventual bulk archive")
        select([ids[0], group.id])
        perform(sidebar.contextMenu(nodeID: group.id)!, "Archive Items")
        check(model.node(id: ids[0]) == nil && context.selection.ids == [group.id], "MS9 mixed Archive Items preserves its untouched selected folder")
        undo.undo(); pump()
        let secondFolder = model.createFolder(in: .spacePinned(space.id), title: "Other folder")!
        select([group.id, secondFolder.id])
        check(!titles(sidebar.contextMenu(nodeID: group.id)!).contains(where: { $0.hasPrefix("Archive Item") }), "MS7 folders-only selection hides Archive Item")
        undo.undo(); pump()
        context.selection.clear()
        let folderMenu = sidebar.contextMenu(nodeID: group.id)!
        check(titles(folderMenu).contains("Turn “Action folder” into Space") && !titles(folderMenu).contains("Archive Folder"), "curly folder title and Q1 Delete-only menu")
        let batches = archive.batches
        perform(folderMenu, "Delete")
        check(archive.batches == batches + 1 && records().contains { $0.id == group.id && $0.kind == .folder },
              "Q1 folder Delete writes one real folder archive record")
        undo.undo(); pump()
        check(model.node(id: group.id)?.folder?.children.first?.id == nested.id, "folder Delete undo restores the subtree")

        let tabs = (0..<3).map { model.newTab(in: space.id, url: Synthetic.url("archive\($0)"), title: "Archive \($0)") }
        let ordered = space.today.filter { n in tabs.contains { $0.id == n.id } }.map(\.id)
        select(ordered); changes = []
        let archiveBatches = archive.batches
        perform(sidebar.contextMenu(nodeID: ordered[0])!, "Archive Items")
        check(changes.filter { if case .remove = $0 { true } else { false } }.count == 3 && archive.batches == archiveBatches + 1 &&
              Set(records().map(\.id)) == Set(ordered), "MS9 three removes, one sink batch, three persisted SQLite rows")
        check(sidebar.displayedRows == Checks.expectedRows(context: context) && context.selection.isEmpty, "MS9 outline follows archive and selection clears")
        undo.undo(); pump()
        check(ordered.allSatisfy { model.tab(id: $0) != nil } && records().isEmpty, "MS9 one undo restores all tabs and removes their archive rows")

        select(ids); changes = []
        key(2, .command)
        check(ids.allSatisfy { model.isPinned(tabID: $0) } && context.selection.ids.count == 3, "MS11 Cmd+D pins a mixed pinned/Today selection")
        key(2, .command)
        check(ids.allSatisfy { !model.isPinned(tabID: $0) } && context.selection.ids.count == 3, "MS11 Cmd+D again unpins all")
        undo.undo(); undo.undo(); pump()
        select(ids)
        let originalIDs = Set(model.index.keys)
        perform(sidebar.contextMenu(nodeID: ids[0])!, "Duplicate")
        check(Set(model.index.keys).subtracting(originalIDs).count == 3, "selection Duplicate creates three real tabs")
        undo.undo(); pump()
        check(Set(model.index.keys) == originalIDs, "one undo removes all selection duplicates")
        select(ids); changes = []
        let target = model.spaces[1]
        let move = sidebar.contextMenu(nodeID: ids[0])!.item(withTitle: "Move to")!.submenu!
        perform(move, context.title(of: target))
        check(changes.filter { if case .move = $0 { true } else { false } }.count == 3 &&
              Array(target.pinned.prefix(2).map(\.id)) == Array(ids.prefix(2)) && target.today.first?.id == ids[2],
              "MS10 Move to sends three moves, retaining order at each section top")
        check(ids.allSatisfy { model.tab(id: $0)?.isUnread == true } && context.selection.isEmpty, "MS10 move into an unfocused Space marks unread and consumes selection")
        undo.undo(); pump()

        select(ordered)
        let writerIDs = outline.selectedRowIndexes.compactMap { row -> ItemID? in (outline.item(atRow: row) as? Tab)?.id }
        let writers: [any NSPasteboardWriting] = outline.selectedRowIndexes.compactMap { row in
            guard let item = outline.item(atRow: row) else { return nil }
            return outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: item)
        }
        let drag = SidebarDragEvent(ids: [], window: host)
        drag.draggingPasteboard.clearContents(); drag.draggingPasteboard.writeObjects(writers)
        let payload = drag.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: .init("com.open.sidebar.node")) } ?? []
        check(writerIDs == ordered && payload == ordered.map(\.description), "MS12 native selectedRowIndexes and production writers yield three ordered pasteboard items")
        context.selection.clear(); pump()
        let singleWriter = outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: model.tab(id: ordered[0])!)
        let singleDrag = SidebarDragEvent(ids: [], window: host)
        if let singleWriter { singleDrag.draggingPasteboard.writeObjects([singleWriter]) }
        check(outline.dataSource?.outlineView?(outline, acceptDrop: singleDrag, item: group, childIndex: -1) == true && model.parent(of: ordered[0]) == .folder(group.id), "MS12 unselected-row writer/drop works with an empty selection")
        undo.undo(); pump(); select(ordered)
        let beforeDrag = space.today.map(\.id)
        changes = []
        let data = outline.dataSource!
        check(data.outlineView?(outline, validateDrop: drag, proposedItem: group, proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move &&
              data.outlineView?(outline, acceptDrop: drag, item: group, childIndex: NSOutlineViewDropOnItemIndex) == true,
              "MS12 whole-selection drop reaches the real outline destination")
        pump()
        check(Array(group.children.suffix(3).map(\.id)) == ordered && changes.filter { if case .move = $0 { true } else { false } }.count == 3,
              "MS12 one bulk drop moves all three in pasteboard order")
        undo.undo(); pump()
        check(space.today.map(\.id) == beforeDrag && group.children.map(\.id) == [nested.id], "MS12 one undo restores every drag source")
        let paneA = model.newTab(in: space.id, url: Synthetic.url("refused-pane-a")), paneB = model.newTab(in: space.id, url: Synthetic.url("refused-pane-b"))
        let split = model.makeSplit(tabIDs: [paneA.id, paneB.id])!; pump()
        let partial = SidebarDragEvent(ids: [ordered[0], paneA.id, ordered[1]], window: host)
        check(data.outlineView?(outline, acceptDrop: partial, item: group, childIndex: -1) == true &&
              model.parent(of: paneA.id) == .splitPane(split.id) && Array(group.children.suffix(2).map(\.id)) == Array(ordered.prefix(2)),
              "MS12 an incoming split-pane source is skipped while both legal nodes move")
        undo.undo(); pump()
        select(ordered)
        let refused = SidebarDragEvent(ids: [paneA.id], window: host)
        check(data.outlineView?(outline, validateDrop: refused, proposedItem: group, proposedChildIndex: -1) == [] &&
              data.outlineView?(outline, acceptDrop: refused, item: group, childIndex: -1) == false && context.selection.ids == ordered,
              "MS12 an entirely refused drop preserves selection")
        let favorites = sidebar.favoritesCollection
        let beforeFavoriteDrop = space.today.map(\.id)
        let favoriteDrag = SidebarDragEvent(ids: ordered + [group.id], window: host)
        check(favorites.delegate?.collectionView?(favorites, acceptDrop: favoriteDrag, indexPath: IndexPath(item: 2, section: 0), dropOperation: .before) == true &&
              Array(model.profiles[0].favorites.dropFirst(2).prefix(3).map(\.id)) == ordered && model.parent(of: group.id) == .spacePinned(space.id),
              "MS12 Favorites bulk drop preserves tab order and skips the folder")
        undo.undo(); pump()
        check(space.today.map(\.id) == beforeFavoriteDrop, "MS12 one Favorites undo restores source order")
        select(ordered); changes = []
        let switcher = sidebar.spaceSwitcher(spaceID: target.id)!
        let spaceDrag = SidebarDragEvent(ids: ordered, window: host)
        check(switcher.performDragOperation(spaceDrag) && Array(target.today.prefix(3).map(\.id)) == ordered &&
              changes.filter { if case .move = $0 { true } else { false } }.count == 3,
              "MS12 Space icon drop uses one bulk command and preserves order")
        undo.undo(); pump()
        select(ordered); delegate.refuses = true
        check(!switcher.performDragOperation(spaceDrag) && context.selection.ids == ordered && ordered.allSatisfy { model.parent(of: $0) == .spaceToday(space.id) },
              "MS12 a refused Space drop preserves the source and selection")
        delegate.refuses = false
        check(SidebarDiagnostics.fullReloads == reloads, "MS8–MS12 edits perform no full outline reload")

        context.selection.clear()
        context.forcedHover = .divider; pump()
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: ordered[0]); select([ordered[1]])
        let clear = sidebar.clearControl!.view
        let clearPoint = clear.convert(NSPoint(x: 190, y: 8), to: nil)
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: clearPoint, modifierFlags: [], timestamp: 0,
                                       windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        clear.mouseMoved(with: hover); pump()
        check(sidebar.clearControl?.title == "Clear" && TooltipController.shared.visibleOrPendingTooltip?.title == "Clear Today tabs", "CU1 Clear label and real scheduled tooltip at rest")
        let option = NSEvent.keyEvent(with: .flagsChanged, location: clearPoint, modifierFlags: .option, timestamp: 0,
                                      windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
        NSApp.sendEvent(option); pump()
        check(sidebar.clearControl?.title == "Clear" && TooltipController.shared.visibleOrPendingTooltip?.title == "Clear unselected Today tabs",
              "CU1 Q14 Option changes only the tooltip without pointer movement")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: host); pump()
        check(!context.isOptionHeld && sidebar.clearControl?.title == "Clear", "CU1 window resignation clears monitored Option state")
        let beforeClear = space.today.map(\.id)
        changes = []
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: clearPoint, modifierFlags: .option, timestamp: 0,
                                      windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        clear.mouseDown(with: down); pump()
        check(space.today.map(\.id) == beforeClear.filter { [ordered[0], ordered[1]].contains($0) } &&
              changes.count == 1 && { if case .reload(.spaceToday(space.id)) = changes.first { true } else { false } }(),
              "CU2 Option Clear keeps current and selection with one reload")
        undo.undo(); pump()
        check(space.today.map(\.id) == beforeClear, "CU4 one undo restores every cleared row")
        context.selection.clear(); context.forcedHover = nil; context.isOptionHeld = false; pump()
        let todayMenu = sidebar.contextMenu(nodeID: ordered[0])!
        let below = todayMenu.item(withTitle: "Archive Tabs Below")!
        let beforeBelow = space.today.map(\.id)
        let belowIndex = beforeBelow.firstIndex(of: ordered[0])!
        let belowIDs = Array(beforeBelow.dropFirst(belowIndex + 1))
        check(todayMenu.item(withTitle: "Archive Tab") != nil && !below.isAlternate && below.isEnabled &&
              todayMenu.indexOfItem(withTitle: "Archive Tabs Below") == todayMenu.indexOfItem(withTitle: "Archive Other Tabs") + 1,
              "Q16 single Today menu has Archive Tab then normal Archive Tabs Below")
        let beforeBelowBatches = archive.batches
        perform(todayMenu, "Archive Tabs Below")
        check(space.today.map(\.id) == Array(beforeBelow.prefix(belowIndex + 1)) && archive.batches == beforeBelowBatches + 1 &&
              belowIDs.allSatisfy { model.node(id: $0) == nil }, "Q16 Archive Tabs Below archives only later Today rows in one batch")
        undo.undo(); pump()
        check(space.today.map(\.id) == beforeBelow, "Q16 one undo restores every tab below")
        check(sidebar.contextMenu(nodeID: space.today.last!.id)!.item(withTitle: "Archive Tabs Below")?.isEnabled == false,
              "Q16 last Today row keeps Archive Tabs Below visible and disabled")
        let alternate = todayMenu.item(withTitle: "Archive Other Tabs")!
        check(alternate.isAlternate && alternate.keyEquivalentModifierMask == .option &&
              todayMenu.indexOfItem(withTitle: "Archive Other Tabs") == todayMenu.indexOfItem(withTitle: "Archive Tab") + 1,
              "CU3 Archive Other Tabs is the native Option alternate immediately after Archive Tab")
        perform(todayMenu, "Archive Other Tabs")
        check(space.today.map(\.id) == [ordered[0]], "CU3 Archive Other Tabs keeps its tab")
        undo.undo(); pump()

        model.focusSpace(windowID: state.id, spaceID: target.id); pump()
        let sourcePinned = target.pinned.map(\.id), sourceToday = target.today.map(\.id)
        let export = sidebar.contextMenu(nodeID: nil)!.item(withTitle: "Export “Reading” into Folder")!
        check(export.submenu?.items.count == model.spaces.count, "TF1 Space export menu uses curly quotes and lists all Spaces")
        perform(export.submenu!, context.title(of: space))
        let exported = space.pinned.first?.folder
        check(model.space(id: target.id) == nil && context.focusedSpace === space && exported?.children.map(\.id) == sourcePinned + sourceToday &&
              sidebar.displayedRows.dropFirst().first == exported?.id.description, "TF2 export inserts one folder at Pinned top and removes the source Space")
        undo.undo(); pump()
        check(model.space(id: target.id) === target && context.focusedSpace === target && target.pinned.map(\.id) == sourcePinned && target.today.map(\.id) == sourceToday,
              "TF3 one undo restores the source Space, its rows, and window focus")
    }
}
