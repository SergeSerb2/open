import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// CT1–CT3 (completion §3.16): the compact toolbar below 219 pt, its "More options" menu,
/// and the swap on resize. Real `SidebarView` in an offscreen window.
@MainActor
enum CompactToolbarChecks {
    static func run() {
        let check = Checks.check
        let model = Synthetic.model(), state = model.windows[0]
        let context = SidebarContext(model: model, windowID: state.id)
        let delegate = RecordingDelegate()
        var options = RenderScene.Options()
        options.size = CGSize(width: 900, height: 700)
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 1)
        defer { host.contentView = nil; host.close() }
        let sidebar = scene.sidebar
        func width(_ w: CGFloat) {
            context.sidebarWidthOverride = w
            scene.needsLayout = true
            OffscreenRenderer.settle(scene, runLoop: 0.01)
        }
        var rows: [String] = [], ok = true
        for w: CGFloat in [228, 219, 218, 207, 164] {
            width(w)
            let g = sidebar.toolbarGeometry, visible = sidebar.toolbarVisibleButtons
            let full = w >= CompactToolbarMetrics.switchWidth
            let expected: Bool
            if full {
                expected = visible == ["toggle", "back", "forward", "reload"] && g["toggle"]?.minX == 77
                    && g["back"] == CGRect(x: w - 106, y: 7, width: 32, height: 32) && g["reload"] == CGRect(x: w - 38, y: 7, width: 32, height: 32)
            } else {
                expected = visible == ["back", "forward", "more"]
                    && g["back"] == CGRect(x: w - 90, y: 9, width: 28, height: 28) && g["forward"] == CGRect(x: w - 62, y: 9, width: 28, height: 28)
                    && g["more"] == CGRect(x: w - 34, y: 9, width: 28, height: 28)
            }
            ok = ok && expected
            rows.append("\(Int(w)): \(visible.joined(separator: "/"))")
        }
        check(ok, "CT1 full toolbar at 228 and 219; compact Back, Forward, More options at [W − 90 / W − 62 / W − 34, 9, 28, 28] at 218, 207, 164 (\(rows.joined(separator: "; ")))")
        width(200)
        let moreRows = sidebar.toolbarMoreRows()
        delegate.log = []
        let opened = sidebar.toggleToolbarMorePopover()
        let open = sidebar.toolbarMoreState
        sidebar.chooseToolbarMoreRow(1)
        let closed = sidebar.toolbarMoreState
        let hide = delegate.log.last.map { if case .toggleSidebar = $0 { true } else { false } } ?? false
        let space = model.spaces[0], tab = space.today.first?.tab ?? space.pinned.first!.tab!
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: tab.id)
        tab.live.isLoading = true
        let stop = sidebar.toolbarMoreRows().first
        tab.live.isLoading = false
        check(moreRows.map { $0.title } == ["Reload", "Toggle Sidebar"] && moreRows.map { $0.shortcut } == ["⌘R", "⌘S"] && hide && stop?.title == "Stop Loading",
              "CT2 More options rows, as Arc (capture s9): Reload ⌘R (Stop Loading while loading), Toggle Sidebar ⌘S sends .toggleSidebar")
        check(opened && open.open && open.closeGlyph && open.frame.width == 200 && open.frame.height == 101
              && abs(open.frame.midX - (200 - 34 + 14)) <= 0.5 && abs(open.frame.minY - (9 + 28 + 12)) <= 0.5
              && !closed.open && !closed.closeGlyph,
              "CT2c More options popover: 200 × 101 (95 card + 6 arrow) centred under the button, tip 12 pt below it, × while open; a row press closes it (\(open.frame))")
        let compactPlaceholder = sidebar.urlFieldPlaceholder
        width(228)
        let fullPlaceholder = sidebar.urlFieldPlaceholder
        width(200)
        check(compactPlaceholder == "Search…" && fullPlaceholder == "Search or Enter URL…",
              "CT2b URL field placeholder: \"Search…\" in the compact sidebar, \"Search or Enter URL…\" at 228 (\(compactPlaceholder) / \(fullPlaceholder))")
        width(228)
        let swaps = SidebarDiagnostics.compactToolbarSwaps
        var layouts = SidebarDiagnostics.tabRowLayouts
        width(221); let plainStep = SidebarDiagnostics.tabRowLayouts - layouts
        layouts = SidebarDiagnostics.tabRowLayouts
        width(218); let crossingStep = SidebarDiagnostics.tabRowLayouts - layouts
        width(210); width(200)
        let afterDown = SidebarDiagnostics.compactToolbarSwaps
        width(225); width(230)
        check(afterDown == swaps + 1 && SidebarDiagnostics.compactToolbarSwaps == swaps + 2 && crossingStep == plainStep,
              "CT3 resizing across 219 swaps the toolbar once per crossing (down \(afterDown - swaps), up 1) and adds no row layout (\(crossingStep) vs \(plainStep) for a plain 3 pt step)")
    }
}
