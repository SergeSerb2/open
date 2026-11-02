import AppKit
import OpenCommandBar
import OpenDesign
import OpenSuggest

/// Flows 82–85 and 91 (docs/plans/commandbar-completion.md §5.1): the Actions and Tabs scopes and the
/// captured Site Search chip (CC-41), through real key and mouse events and the real engine.
@MainActor
enum ScopeFlows {
    static func run(_ env: Scenes.Env) -> [Flows.Check] {
        var checks: [Flows.Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: @autoclosure () -> String) {
            let d = detail()
            checks.append(.init(name: name, pass: pass, detail: d))
            print("\(pass ? "PASS" : "FAIL")  \(name)  —  \(d)")
        }
        func fresh(_ mode: CommandBarMode = .newTab) -> Stage {
            let s = Stage(size: CGSize(width: 1440, height: 900), scale: 1, engine: env.engine, backdrop: .darkPage)
            s.controller.favicons = env.favicons
            s.controller.theme = Scenes.theme(env)
            s.controller.present(Scenes.request(env, mode: mode))
            s.settle()
            return s
        }
        func caret(_ s: Stage) -> NSRange? { s.fieldEditor?.selectedRange() }
        func rgb(_ s: Stage, _ p: CGPoint) -> [Int] { CLI.pixel(s.render(scale: 1), p) }
        let chipRGB = [255, 160, 0] // P3 #FFA500 in the sRGB harness (clipped)
        func near(_ a: [Int], _ b: [Int], _ tol: Int = 4) -> Bool { a.count == 3 && zip(a, b).allSatisfy { abs($0 - $1) <= tol } }

        // 82. "actions" + Tab → Actions chip, "Search…", only action rows; Backspace on empty → "actions", no scope.
        do {
            let s = fresh()
            s.type("actions"); s.settle()
            let hint = s.controller.view.debugTrailing
            s.key(.tab); s.settle()
            let inScope = s.controller.scope == .actions && s.controller.view.debugInput.chip?.name == "Actions"
                && s.controller.view.debugInput.placeholder == "Search…" && s.controller.text.isEmpty
            let kinds = Set(s.controller.suggestions.map(\.kind))
            let trailing = s.controller.view.debugTrailing
            s.type("side"); s.settle()
            let top = s.controller.suggestions.first?.actionID
            for _ in 0..<4 { s.key(.backspace) }; s.settle()
            s.key(.backspace); s.settle()
            check("82: \"actions\" offers Tab only; Tab → Actions chip, \"Search…\", action rows only, no (i); \"side\" → Show/Hide Sidebar",
                  hint.contains("Actions") && !hint.contains("Space") && inScope && kinds == [.action] && trailing == "none" && top == "toggle-sidebar",
                  "hint \(hint); in scope \(inScope); kinds \(kinds.map(\.rawValue)); trailing \(trailing); top \(top ?? "-")")
            check("82: Backspace on the empty field leaves the scope and restores \"actions\", caret at the end",
                  s.controller.scope == nil && s.controller.text == "actions" && caret(s) == NSRange(location: 7, length: 0),
                  "scope \(String(describing: s.controller.scope)) text \"\(s.controller.text)\" caret \(String(describing: caret(s)))")
            // Space after a scope keyword types a space ("tabs vs spaces").
            let t = fresh()
            t.type("tabs"); t.settle()
            t.key(.space); t.settle()
            check("82: Space after \"tabs\" types a space, never enters a scope", t.controller.scope == nil && t.controller.text == "tabs ",
                  "scope \(String(describing: t.controller.scope)) text \"\(t.controller.text)\"")
        }

        // 83. "tabs" + Tab → Tabs chip; split rows show; Esc closes.
        do {
            let s = fresh()
            s.type("tabs"); s.settle()
            s.key(.tab); s.settle()
            let empty = s.controller.suggestions
            s.type("review"); s.settle()
            let rows = s.controller.rows
            s.key(.escape); s.settle()
            check("83: \"tabs\" + Tab → Tabs chip; tab rows only, the split as one row; Esc closes",
                  !empty.isEmpty && empty.allSatisfy { $0.kind == .switchToTab } && rows.contains { !$0.titleParts.isEmpty }
                    && rows.allSatisfy { $0.kind == .switchToTab } && !s.controller.isPresented,
                  "empty \(empty.count) rows; \"review\" rows \(rows.map(\.title)); presented \(s.controller.isPresented)")
        }

        // 84. Hover shows the close glyph (the chip grows by 15); a click leaves the scope like Backspace on empty.
        do {
            let s = fresh()
            s.type("wikipedia"); s.settle()
            s.key(.tab); s.settle()
            s.type("bird"); s.settle()
            let chip = s.controller.view.debugChipFrame
            let p = s.controller.view.panelFrame
            let center = CGPoint(x: p.minX + chip.midX, y: p.minY + chip.midY)
            s.mouse(.mouseMoved, at: center); s.settle()
            let grown = s.controller.view.debugChipFrame
            let glyph = rgb(s, CGPoint(x: p.minX + grown.minX + CommandBarMetrics.chipPaddingX + 5.5, y: p.minY + grown.midY - 4)) // the ring above the X cut-out
            let at = CGPoint(x: p.minX + grown.midX, y: p.minY + grown.midY)
            s.mouse(.leftMouseDown, at: at); s.mouse(.leftMouseUp, at: at); s.settle()
            check("84: hover shows the close glyph and widens the chip by 15; a click leaves the scope and restores \"wikipedia\"",
                  s.controller.view.debugChipHovered == false && grown.width - chip.width == CommandBarMetrics.chipCloseGrowth && glyph.allSatisfy { $0 > 230 }
                    && s.controller.scope == nil && s.controller.text == "wikipedia",
                  "chip \(chip.width) → \(grown.width); glyph pixel \(glyph); scope \(String(describing: s.controller.scope)) text \"\(s.controller.text)\"")
        }

        // 85. Present in a scope (the search-actions / search-tabs commands); Backspace on empty → .newTab, empty field.
        do {
            var ok: [String] = []
            for (mode, scope) in [(CommandBarMode.searchActions, CommandBarScope.actions), (.searchTabs, .tabs)] {
                let s = fresh(mode)
                let opened = s.controller.scope == scope && s.controller.view.debugInput.placeholder == "Search…"
                let rows = s.controller.suggestions.map(\.kind)
                s.key(.backspace); s.settle()
                let left = s.controller.scope == nil && s.controller.request?.mode == .newTab && s.controller.text.isEmpty
                    && s.controller.view.debugInput.placeholder == CommandBarText.placeholder && s.controller.suggestions.contains { $0.kind != (scope == .actions ? .action : .switchToTab) }
                if !(opened && !rows.isEmpty && left) { ok.append("\(mode.rawValue): opened \(opened) rows \(rows.count) left \(left)") }
            }
            check("85: present in the Actions or Tabs scope; Backspace on the empty field gives an empty Cmd+T bar", ok.isEmpty, ok.isEmpty ? "both modes" : ok.joined(separator: "; "))
        }

        // 91. "wikipedia" + Tab: the captured chip (CC-41, S2 18/0016) and an orange selected row (0018).
        do {
            let s = fresh()
            s.type("wikipedia"); s.settle()
            s.key(.tab); s.settle()
            let chip = s.controller.view.debugChipFrame
            let field = s.controller.view.debugFieldFrame
            let p = s.controller.view.panelFrame
            let fill = rgb(s, CGPoint(x: p.minX + chip.minX + 5, y: p.minY + chip.minY + 3))
            let placeholder = s.controller.view.debugInput.placeholder
            s.type("bird"); s.settle()
            let selected = s.controller.selectedIndex
            let rowFill = rgb(s, CGPoint(x: p.minX + 400, y: p.minY + CommandBarMetrics.listTop + 5))
            let rowSubtitle = s.controller.rows.first?.subtitle
            for _ in 0..<4 { s.key(.backspace) }; s.settle()
            s.key(.backspace); s.settle()
            check("91: chip [54, 20, 81, 24] ± 0.5, chip-colored, no icon; field x 146; \"Search…\"",
                  abs(chip.minX - 54) <= 0.5 && abs(chip.minY - 20) <= 0.5 && abs(chip.width - 81) <= 0.5 && chip.height == 24
                    && near(fill, chipRGB) && abs(field.minX - 146) <= 0.5 && placeholder == "Search…",
                  "chip \(chip); fill \(fill); field x \(field.minX); placeholder \(placeholder)")
            check("91: \"bird\" selects the scoped row with the chip fill and no subtitle; Backspace on empty restores \"wikipedia\"",
                  selected == 0 && near(rowFill, chipRGB) && rowSubtitle == "" && s.controller.scope == nil && s.controller.text == "wikipedia",
                  "selected \(String(describing: selected)); row fill \(rowFill); subtitle \"\(rowSubtitle ?? "-")\"; text \"\(s.controller.text)\"")
        }
        return checks
    }
}
