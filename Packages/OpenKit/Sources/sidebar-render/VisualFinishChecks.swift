import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// M4 sidebar visuals through the real view stack: the selected split card, the
/// split-row menu (Arc's builder order), the Peek badge, the Peek source fill and
/// dim, and narrow split titles. Menu items run through the delegate and the model.
@MainActor
enum VisualFinishChecks {
    static func run() {
        let check = Checks.check
        let model = Synthetic.model()
        let state = model.windows[0]
        let context = SidebarContext(model: model, windowID: state.id)
        let delegate = RecordingDelegate()
        var options = RenderScene.Options()
        options.size = CGSize(width: 1000, height: 900)
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        defer { host.contentView = nil; host.close() }
        let sidebar = scene.sidebar
        func pump() { OffscreenRenderer.settle(scene, runLoop: 0.02) }
        let space = model.spaces[0]
        let a = model.newTab(in: space.id, url: Synthetic.url("split-a"), title: "Pane A")
        let b = model.newTab(in: space.id, url: Synthetic.url("split-b"), title: "A pane title that runs well past thirty characters")
        let split = model.makeSplit(tabIDs: [a.id, b.id])!
        pump()

        print("split row (F0081)")
        let unselected = sidebar.splitRowCells(splitID: split.id)
        check(unselected.map { $0.cells.isEmpty && $0.dividersVisible } ?? false, "unselected split row: divider, no pane cells")
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: split.id); pump()
        let row = sidebar.rowFrame(nodeID: split.id)!
        let selected = sidebar.splitRowCells(splitID: split.id)
        let pitch = (row.width - 16 - 4) / 2
        let expected = (0..<2).map { i in
            CGRect(x: (12 + CGFloat(i) * pitch).rounded(), y: row.minY + 6,
                   width: (12 + CGFloat(i) * pitch + pitch - 4).rounded() - (12 + CGFloat(i) * pitch).rounded(), height: 28)
        }
        check(selected.map { $0.cells == expected && !$0.dividersVisible } ?? false,
              "selected split row: one 28 pt cell per pane, 4 pt inside the card, no divider (\(selected?.cells.map { "\($0)" }.joined(separator: " ") ?? "none"))")

        check(!sidebar.toolbarNavigationVisible, "selected split: the sidebar toolbar keeps only the toggle (F0081)")
        print("split row menu (Arc builder order)")
        let titles = sidebar.menuTitles(nodeID: split.id)
        let longTitle = String(b.displayTitle.prefix(30)) + "…"
        check(titles == ["Separate All Tabs", "Add Tab…", "Convert to Vertical Split View", "—", "Tab Options", "Pane A", longTitle, "—", "Duplicate", "Move to", "—", "Archive Item"],
              "split menu: \(titles.joined(separator: " · "))")
        let menu = sidebar.contextMenu(nodeID: split.id)!
        check(menu.item(withTitle: "Tab Options")?.isEnabled == false, "\"Tab Options\" is a header")
        let paneMenu = menu.item(withTitle: "Pane A")?.submenu
        check(paneMenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } == ["Separate from Split View", "—", "Mute", "Copy Link", "Copy Link as Markdown", "—", "Archive Item"],
              "pane submenu items")
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Convert to Vertical Split View")); pump()
        check(split.orientation == .vertical && sidebar.menuTitles(nodeID: split.id).contains("Convert to Horizontal Split View"), "Convert runs setSplitOrientation and flips the title")
        let c = model.newTab(in: space.id, url: Synthetic.url("split-c"), title: "Pane C")
        let d = model.newTab(in: space.id, url: Synthetic.url("split-d"), title: "Pane D")
        _ = model.addPane(splitID: split.id, tabID: c.id); _ = model.addPane(splitID: split.id, tabID: d.id); pump()
        check(sidebar.contextMenu(nodeID: split.id)?.item(withTitle: "Add Tab…")?.isEnabled == false, "Add Tab… is disabled at four panes")
        check(sidebar.splitRowCells(splitID: split.id)?.cells.count == 4, "four-pane selected row has four cells")
        // Narrow four-pane titles draw nothing rather than spill over the next cell.
        let image = OffscreenRenderer().render(scene, scale: 1)
        let rowFrame = sidebar.rowFrame(nodeID: split.id)!
        let rowInScene = scene.convert(rowFrame, from: sidebar)
        let p4 = (rowFrame.width - 16 - 4) / 4
        var spill = 0
        if let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            let bpr = image.bytesPerRow, bpp = image.bitsPerPixel / 8
            for i in 0..<4 {
                // Title area of cell i: from icon end + 6 to the next cell start.
                let x0 = Int((rowInScene.minX + 17 + CGFloat(i) * p4 + 24).rounded()), x1 = Int((rowInScene.minX + 12 + CGFloat(i + 1) * p4 - 6).rounded())
                let y0 = Int(rowInScene.minY + 14), y1 = Int(rowInScene.minY + 28)
                var lo = 255, hi = 0
                for y in y0..<y1 { for x in x0..<max(x0 + 1, x1) { let v = Int(bytes[y * bpr + x * bpp + 1]); lo = min(lo, v); hi = max(hi, v) } }
                if hi - lo > 12 { spill += 1 }
            }
        }
        check(spill == 0, "four-pane split titles do not overflow their cells (\(spill) cells with ink)")
        let paneB = sidebar.contextMenu(nodeID: split.id)!.item(withTitle: longTitle)!.submenu!
        paneB.performActionForItem(at: paneB.indexOfItem(withTitle: "Separate from Split View")); pump()
        check(!split.panes.contains { $0.id == b.id } && model.parent(of: b.id) != .splitPane(split.id), "Separate from Split View takes that pane out")

        print("Peek badge and dim (F0090, F0101)")
        let source = space.pinned.compactMap(\.tab).first!
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: source.id); pump()
        check(sidebar.toolbarNavigationVisible, "a selected tab brings back, forward, and reload back")
        let sourceRow = sidebar.rowFrame(nodeID: source.id)!
        check(sidebar.peekBadgeFrame(tabID: source.id) == nil, "no badge without a Peek")
        let visibleTabRows = sidebar.displayedRows.filter { id in model.node(id: ItemID(rawValue: UUID(uuidString: id) ?? UUID()))?.tab != nil }.count
        var layouts = SidebarDiagnostics.tabRowLayouts
        context.peekBadges = [source.id: SidebarPeekBadge(url: URL(string: "https://example.org/preview")!)]
        pump(); _ = OffscreenRenderer().render(scene, scale: 1)
        let onLayouts = SidebarDiagnostics.tabRowLayouts - layouts
        check(onLayouts >= 1 && onLayouts <= 2, "a badge on lays out only its own row (\(onLayouts) row layouts; \(visibleTabRows) tab rows shown)")
        layouts = SidebarDiagnostics.tabRowLayouts
        let draws = SidebarDiagnostics.peekBadgeDraws
        let png = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.systemBlue.setFill(); r.fill(); return true }.tiffRepresentation
        context.peekBadges = [source.id: SidebarPeekBadge(url: URL(string: "https://example.org/next")!, faviconPNG: png)]
        pump(); _ = OffscreenRenderer().render(scene, scale: 1)
        check(SidebarDiagnostics.tabRowLayouts == layouts && SidebarDiagnostics.peekBadgeDraws > draws,
              "a Peek URL or favicon change redraws the badge only (\(SidebarDiagnostics.tabRowLayouts - layouts) row layouts, \(SidebarDiagnostics.peekBadgeDraws - draws) badge draws)")
        let w = sidebar.bounds.width
        check(sidebar.peekBadgeFrame(tabID: source.id) == CGRect(x: w - 38, y: sourceRow.minY + 8, width: 24, height: 24),
              "badge plate [W − 38, y + 8, 24, 24] (\(sidebar.peekBadgeFrame(tabID: source.id).map { "\($0)" } ?? "none"))")
        func fillPixel() -> Int {
            let image = OffscreenRenderer().render(scene, scale: 1)
            let p = scene.convert(NSPoint(x: 150, y: sourceRow.minY + 5), from: sidebar)
            guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
            return Int(bytes[Int(p.y) * image.bytesPerRow + Int(p.x) * (image.bitsPerPixel / 8) + 1])
        }
        let selectedFill = fillPixel()
        context.shownPeek = SidebarShownPeek(sourceNodeID: source.id, url: URL(string: "https://example.org/preview")!)
        pump()
        let peekFill = fillPixel()
        check(peekFill != selectedFill, "the source row trades the selected fill for the lighter Peek fill (\(selectedFill) → \(peekFill))")
        check(sidebar.chromeOpacity == (SidebarRole.peekToolbarOpacity, SidebarRole.peekBottomBarOpacity), "toolbar row and bottom bar sit under the Peek dim")
        check(sidebar.displayedURLText == "example.org", "URL field shows the Peek host (\(sidebar.displayedURLText))")
        context.forcedHover = .row(source.id); pump()
        check(sidebar.peekBadgeFrame(tabID: source.id) == nil && sidebar.tabAction(tabID: source.id) != nil,
              "hovered source row shows its close button in the badge slot (badge \(sidebar.peekBadgeFrame(tabID: source.id).map { "\($0)" } ?? "hidden"), button \(sidebar.tabAction(tabID: source.id) != nil))")
        context.forcedHover = nil
        context.shownPeek = nil; pump()
        check(sidebar.chromeOpacity == (1, 1) && sidebar.peekBadgeFrame(tabID: source.id) != nil, "hidden Peek keeps the badge and lifts the dim (F0101)")
        context.peekBadges = [:]; pump()
        check(sidebar.peekBadgeFrame(tabID: source.id) == nil, "closing the Peek removes the badge")
    }
}
