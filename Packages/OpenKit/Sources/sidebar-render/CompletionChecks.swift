import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

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
            check(fill.frame == CGRect(x: 8, y: 2, width: 212, height: 36) && fill.cornerRadius == 10 && fill.shadowOpacity == 0,
                  "MS6 \(appearance) multi-fill uses row geometry, radius 10, no shadow")
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
    }
}
