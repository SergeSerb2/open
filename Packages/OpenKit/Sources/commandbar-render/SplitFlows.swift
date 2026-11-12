import AppKit
import OpenCommandBar
import OpenDesign
import OpenSuggest

/// Flow 81 (docs/plans/commandbar-completion.md §5.1): one row per Split View, through real key
/// events and the real engine over the synthetic world (Studio's split "Spec draft" | "Review notes").
@MainActor
enum SplitFlows {
    static func run(_ env: Scenes.Env) -> [Flows.Check] {
        var checks: [Flows.Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: @autoclosure () -> String) {
            let d = detail()
            checks.append(.init(name: name, pass: pass, detail: d))
            print("\(pass ? "PASS" : "FAIL")  \(name)  —  \(d)")
        }
        func fresh(scale: CGFloat = 1) -> Stage {
            let s = Stage(size: CGSize(width: 1440, height: 900), scale: scale, engine: env.engine, backdrop: .darkPage)
            s.controller.favicons = env.favicons
            s.controller.theme = Scenes.theme(env)
            s.controller.present(Scenes.request(env, mode: .newTab))
            s.settle()
            return s
        }
        let w = env.world
        guard case .split(let split)? = w.studio.today.first(where: { if case .split = $0 { return true }; return false }),
              split.panes.count == 2 else {
            check("81: the synthetic world has a two-pane split", false, "no split in Studio")
            return checks
        }
        let spec = split.panes[0], review = split.panes[1]

        // 81. One row for the split; AX label lists both titles; Return switches to the matched pane.
        do {
            let s = fresh()
            s.type("review"); s.settle()
            let splitRows = s.controller.rows.filter { !$0.titleParts.isEmpty }
            let row = splitRows.first
            let index = s.controller.rows.firstIndex { !$0.titleParts.isEmpty }
            let ax = ReviewFlows.accessibilityDump(s.controller.view)
            check("81: \"review\" → one row for the split: both titles in pane order, \"Switch to Split View\", no subtitle, no pane rows",
                  splitRows.count == 1 && row?.titleParts == ["Spec draft", "Review notes"] && row?.accessory == .switchTo("Switch to Split View")
                    && row?.subtitle == "" && !s.controller.rows.contains { $0.titleParts.isEmpty && ($0.title == "Review notes" || $0.title == "Spec draft") },
                  "rows \(s.controller.rows.map { $0.titleParts.isEmpty ? $0.title : $0.titleParts.joined(separator: "|") })")
            check("81: AX: the split row's label is \"Spec draft, Review notes\", its value \"Switch to Split View\"",
                  ax.contains("AXButton label=Spec draft, Review notes value=Switch to Split View"), ax.split(separator: "\n").filter { $0.contains("Split") }.joined(separator: " / "))
            if let index, index != s.controller.selectedIndex { for _ in 0..<(index - (s.controller.selectedIndex ?? 0)) { s.key(.down) } }
            s.key(.returnKey); s.settle()
            check("81: Return on the split row → switchToTab of the matched pane (Review notes) in its Space",
                  s.recorder.intents == [.switchToTab(review.id, spaceID: w.studio.id)], "intents \(s.recorder.intents)")
            let t = fresh()
            t.type("spec draft"); t.settle()
            t.key(.returnKey); t.settle()
            check("81: the other pane's title targets that pane; an exact pane title is the top hit (T5)",
                  t.recorder.intents == [.switchToTab(spec.id, spaceID: w.studio.id)], "intents \(t.recorder.intents)")
        }

        // 81. Pixels at 2x: the plate cells and the 1 pt gap between them (A0120, CC-13).
        do {
            let s = fresh(scale: 2)
            s.type("review"); s.settle()
            guard let index = s.controller.rows.firstIndex(where: { !$0.titleParts.isEmpty }) else {
                check("81: plate pixels", false, "no split row"); return checks
            }
            let selected = s.controller.selectedIndex == index
            let image = s.render(scale: 2)
            let p = s.controller.view.panelFrame
            let rowTop = p.minY + CommandBarMetrics.listTop + CGFloat(index) * CommandBarMetrics.rowHeight - s.controller.view.debugListScrollOffset
            let rowX = p.minX + CommandCardLayout.newTab.listPaddingX // row views sit 9 pt inside the list (ResultsView)
            func px(_ x: CGFloat, _ y: CGFloat) -> [Int] { CLI.pixel(image, CGPoint(x: (rowX + x) * 2, y: (rowTop + y) * 2)) }
            let cell = px(19, 14), gap = px(27.25, 14), rightCell = px(34.5, 14), outside = px(45, 25)
            // Selected: white cells, the gap shows the selection fill; unselected: plate cells over the panel, panel in the gap.
            let ok = selected ? (cell.allSatisfy { $0 >= 250 } && rightCell.allSatisfy { $0 >= 250 } && gap.max()! < 250 && gap == outside)
                              : (cell != gap && gap == outside)
            check("81: plate pixels at 2x: two cells and a 1 pt gap that shows the row background",
                  ok, "selected \(selected); cell \(cell), gap \(gap), right cell \(rightCell), beside the plate \(outside)")
        }
        return checks
    }
}
