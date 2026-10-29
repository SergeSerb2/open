import AppKit
import OpenCommandBar
import OpenDesign
import OpenModel
import OpenSuggest

/// End-to-end flows: real key events through the window and the field editor, real mouse
/// events, the real engine over the synthetic world. Each flow asserts the intents the
/// delegate receives. Exit code is non-zero on any failure.
@MainActor
enum Flows {
    struct Check { let name: String; let pass: Bool; let detail: String }

    static func run() -> [Check] {
        let env = Scenes.env()
        var checks: [Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: @autoclosure () -> String) {
            let d = detail()
            checks.append(Check(name: name, pass: pass, detail: d))
            print("\(pass ? "PASS" : "FAIL")  \(name)  —  \(d)")
        }
        func fresh(_ mode: CommandBarMode) -> Stage {
            let stage = Stage(size: CGSize(width: 1440, height: 900), scale: 1, engine: env.engine, backdrop: .darkPage)
            stage.controller.favicons = env.favicons
            stage.controller.theme = Scenes.theme(env)
            stage.controller.present(Scenes.request(env, mode: mode))
            stage.settle()
            return stage
        }
        let w = env.world

        // 1. Cmd+T, type, Return → the top hit opens in a new tab.
        do {
            let s = fresh(.newTab)
            check("Cmd+T reports presentation (sidebar New Tab highlight)", s.recorder.presentations.first.map { $0.0 && $0.1 == .newTab } ?? false,
                  "\(s.recorder.presentations.map { "\($0.0) \($0.1)" })")
            s.type("git"); s.settle()
            let top = s.controller.suggestions.first
            s.key(.returnKey); s.settle()
            check("\"git\" + Return → the top hit's intent", s.recorder.intents.count == 1 && intentMatches(s.recorder.intents.first, top),
                  "top \(top?.kind.rawValue ?? "-") \(top?.title ?? "-"); intents \(s.recorder.intents)")
            check("Return closes the bar", !s.controller.isPresented && s.recorder.presentations.last.map { !$0.0 } == true, "presented \(s.controller.isPresented)")
        }

        // 2. Down moves the selection; Return acts on the selected row.
        do {
            let s = fresh(.newTab)
            s.type("git"); s.settle()
            let rows = s.controller.suggestions
            s.key(.down); s.key(.down)
            let sel = s.controller.selectedIndex
            s.key(.returnKey); s.settle()
            let target = rows.count > 2 ? rows[2] : nil
            check("Down ×2 selects row 3", sel == 2, "selected \(sel.map(String.init) ?? "nil") of \(rows.count)")
            check("Return on row 3 → its intent", s.recorder.intents.count == 1 && intentMatches(s.recorder.intents.first, target),
                  "row 3 \(target?.kind.rawValue ?? "-") \(target?.title ?? "-"); intents \(s.recorder.intents)")
        }

        // 3. Up at the top and Down at the bottom stay in range.
        do {
            let s = fresh(.newTab)
            s.type("git"); s.settle()
            s.key(.up)
            let top = s.controller.selectedIndex
            for _ in 0..<20 { s.key(.down) }
            let bottom = s.controller.selectedIndex
            check("Up at row 1 stays; Down stops at the last row", top == 0 && bottom == s.controller.rows.count - 1,
                  "after Up \(top.map(String.init) ?? "nil"), after 20× Down \(bottom.map(String.init) ?? "nil") of \(s.controller.rows.count)")
        }

        // 4. Cmd+L: URL prefilled and fully selected; typing replaces it; Esc closes; a second Esc is not the bar's.
        do {
            let s = fresh(.editCurrentURL)
            let editor = s.window.firstResponder as? NSTextView
            let full = NSRange(location: 0, length: (w.current.url.absoluteString as NSString).length)
            check("Cmd+L prefills the current URL, fully selected", s.controller.text == w.current.url.absoluteString && editor?.selectedRange() == full,
                  "text \(s.controller.text == w.current.url.absoluteString ? "= current URL" : "≠"), selection \(editor.map { NSStringFromRange($0.selectedRange()) } ?? "-")")
            check("Cmd+L first row is the current page (title, no subtitle)",
                  s.controller.rows.first.map { $0.title == w.current.displayTitle && $0.subtitle.isEmpty } ?? false,
                  "row 1 \(s.controller.rows.first?.title ?? "-") / \(s.controller.rows.first?.subtitle ?? "-")")
            check("Cmd+L does not report a New Tab presentation", s.recorder.presentations.first.map { $0.1 == .editCurrentURL } ?? false, "\(s.recorder.presentations.map { "\($0.1)" })")
            s.type("x"); s.settle()
            check("Typing replaces the selected URL", s.controller.text == "x", "text \(s.controller.text)")
            s.key(.escape); s.settle()
            check("Esc closes with .dismissed(.escape)", s.recorder.intents == [.dismissed(.escape)] && !s.controller.isPresented, "intents \(s.recorder.intents)")
            s.key(.escape); s.settle()
            check("Second Esc reaches nothing in the bar", s.recorder.intents.count == 1, "intents \(s.recorder.intents)")
        }

        // 5. Cmd+L, Return → navigate the current tab.
        do {
            let s = fresh(.editCurrentURL)
            s.key(.returnKey); s.settle()
            check("Cmd+L + Return → open the URL in the current tab", s.recorder.intents == [.open(w.current.url, .currentTab, [])], "intents \(s.recorder.intents)")
        }

        // 6. Site Search: Tab on the hint, then Return searches the site.
        do {
            let s = fresh(.newTab)
            s.type("youtu"); s.settle()
            let prefixHint = s.controller.view.debugTrailing
            s.type("be"); s.settle()
            let hint = s.controller.view.debugTrailing
            s.key(.tab); s.settle()
            check("\"youtu\" shows \"Search YouTube [Tab]\"", prefixHint == "hint YouTube", "trailing \(prefixHint)")
            check("\"youtube\" (the name) also offers Space", hint == "hint+space YouTube", "trailing \(hint)")
            check("Tab enters Site Search (chip, empty query)", s.controller.siteScope?.id == "youtube" && s.controller.text.isEmpty,
                  "scope \(s.controller.siteScope?.id ?? "nil"), text \"\(s.controller.text)\"")
            s.type("lofi beats"); s.settle()
            s.key(.returnKey); s.settle()
            let url = URL(string: "https://www.youtube.com/results?search_query=lofi%20beats")!
            check("Site Search + Return → search YouTube", s.recorder.intents == [.search(query: "lofi beats", url: url, siteSearchID: "youtube", .newTab, [])],
                  "intents \(s.recorder.intents)")
        }

        // 7. Backspace on an empty scoped query leaves Site Search.
        do {
            let s = fresh(.newTab)
            s.type("youtube"); s.settle()
            s.key(.tab); s.settle()
            s.key(.backspace); s.settle()
            check("Backspace on empty Site Search exits the scope", s.controller.siteScope == nil, "scope \(s.controller.siteScope?.id ?? "nil")")
        }

        // 8. Space after an exact keyword enters Site Search; a prefix does not.
        do {
            let s = fresh(.newTab)
            s.type("yt"); s.settle()
            let hint = s.controller.view.debugTrailing
            s.type(" "); s.settle()
            check("\"yt\" shows Tab or Space", hint == "hint+space YouTube", "trailing \(hint)")
            check("\"yt\" + Space enters Site Search", s.controller.siteScope?.id == "youtube", "scope \(s.controller.siteScope?.id ?? "nil")")
            let t = fresh(.newTab)
            t.type("you"); t.settle()
            t.type(" "); t.settle()
            check("\"you\" + Space stays plain text", t.controller.siteScope == nil && t.controller.text == "you ", "scope \(t.controller.siteScope?.id ?? "nil"), text \"\(t.controller.text)\"")
        }

        // 9. Calculator → copy.
        do {
            let s = fresh(.newTab)
            s.type("12*(3+4)"); s.settle()
            s.key(.returnKey); s.settle()
            check("Calculator + Return → copy 84", s.recorder.intents == [.copy("84")], "intents \(s.recorder.intents)")
        }

        // 10. Action with keycaps → run action.
        do {
            let s = fresh(.newTab)
            s.type("toggle sid"); s.settle()
            let row = s.controller.rows.first
            s.key(.returnKey); s.settle()
            check("\"toggle sid\" shows the sidebar action with keycaps", (row?.title.contains("Sidebar") ?? false) && row?.accessory == .keys(["⌘", "S"]),
                  "row 1 \(row?.title ?? "-") \(String(describing: row?.accessory))")
            check("Action + Return → run toggle-sidebar", s.recorder.intents == [.runAction(id: "toggle-sidebar", spaceID: nil)], "intents \(s.recorder.intents)")
        }

        // 11. Switch to Tab, in this Space and in another Space.
        do {
            let s = fresh(.newTab)
            s.type("sprint"); s.settle()
            let row = s.controller.rows.first
            s.key(.returnKey); s.settle()
            let sprint = w.studio.pinned[2].tab!
            check("\"sprint\" → Switch to Tab row", row?.accessory == .switchTo("Switch to Tab"), "row 1 \(row?.title ?? "-") \(String(describing: row?.accessory))")
            check("Return → switch to that tab", s.recorder.intents == [.switchToTab(sprint.id, spaceID: w.studio.id)], "intents \(s.recorder.intents)")
            let o = fresh(.newTab)
            o.type("git - b"); o.settle()
            let other = o.controller.rows.first { $0.kind == .switchToTab }
            check("Tab in another Space shows the Space name", other?.accessory == .switchTo("Reading"), "row \(other?.title ?? "-") \(String(describing: other?.accessory))")
        }

        // 12. Selection stability across snapshots. A local stub stands in for the search
        // engine (no network) and answers after 200 ms, so a later snapshot always follows the move.
        do {
            let slowEngine = SuggestEngine(model: w.model, history: env.history, fetcher: SlowFetcher())
            func freshSlow() -> Stage {
                let stage = Stage(size: CGSize(width: 1440, height: 900), scale: 1, engine: slowEngine, backdrop: .darkPage)
                stage.controller.theme = Scenes.theme(env)
                var r = Scenes.request(env, mode: .newTab)
                r.allowsRemoteSuggestions = true
                stage.controller.present(r)
                stage.settle()
                return stage
            }
            let s = freshSlow()
            var firstTop: String?, pendingAtFirst = false
            s.controller.onSnapshotApplied = { [weak s] snap in
                guard let s, snap.query == "git", snap.sequence == 0 else { return }
                firstTop = s.controller.selectedSuggestion?.id
                pendingAtFirst = !snap.isFinal
            }
            s.type("git")
            s.settle()
            check("Without a move, the selection follows the top hit", s.controller.selectedIndex == 0,
                  "first snapshot top \(firstTop ?? "-") (later snapshot pending: \(pendingAtFirst)), final top \(s.controller.selectedSuggestion?.id ?? "-")")
            let t = freshSlow()
            // Move exactly when the first snapshot of "git" lands, before any later one.
            var chosen: String?, wasPending = false
            t.controller.onSnapshotApplied = { [weak t] snap in
                guard let t, snap.query == "git", snap.sequence == 0, chosen == nil else { return }
                t.key(.down)
                chosen = t.controller.selectedSuggestion?.id
                wasPending = !snap.isFinal
            }
            t.type("git")
            t.settle()
            check("After a move, a later snapshot keeps the chosen row", wasPending && t.controller.selectedSuggestion?.id == chosen,
                  "later snapshot pending at move: \(wasPending); chosen \(chosen ?? "-") → \(t.controller.selectedSuggestion?.id ?? "-") at row \(t.controller.selectedIndex.map { String($0 + 1) } ?? "-")")
        }

        // 13. Return typed before the snapshot lands acts on the new query.
        do {
            let s = fresh(.newTab)
            s.type("12*(3+4)")
            s.key(.returnKey) // no settle in between
            s.settle()
            check("Return right after typing waits for that query", s.recorder.intents == [.copy("84")], "intents \(s.recorder.intents)")
        }

        // 14. Mouse: hover selects, click chooses, click outside closes.
        do {
            let s = fresh(.newTab)
            s.type("git"); s.settle()
            let panel = s.controller.view.panelFrame
            let row3 = CGPoint(x: panel.midX, y: panel.minY + CommandBarMetrics.listTop + 2.5 * CommandBarMetrics.rowHeight)
            s.mouse(.mouseMoved, at: row3)
            let hovered = s.controller.selectedIndex
            let target = s.controller.suggestions.count > 2 ? s.controller.suggestions[2] : nil
            s.mouse(.leftMouseDown, at: row3); s.mouse(.leftMouseUp, at: row3); s.settle()
            check("Hover selects row 3", hovered == 2, "selected \(hovered.map(String.init) ?? "nil")")
            check("Click on row 3 → its intent", s.recorder.intents.count == 1 && intentMatches(s.recorder.intents.first, target), "intents \(s.recorder.intents)")
            let o = fresh(.newTab)
            o.mouse(.leftMouseDown, at: CGPoint(x: 30, y: 30)); o.settle()
            check("Click outside → .dismissed(.clickOutside)", o.recorder.intents == [.dismissed(.clickOutside)] && !o.controller.isPresented, "intents \(o.recorder.intents)")
            let i = fresh(.newTab)
            let info = CGPoint(x: panel.maxX - CommandBarMetrics.infoButtonTrailing - 13, y: panel.minY + CommandBarMetrics.infoButtonY + 13)
            i.mouse(.leftMouseDown, at: info); i.mouse(.leftMouseUp, at: info); i.settle()
            check("Click on (i) shows the privacy footer, no intent and no window (CC-42)",
                  i.recorder.intents.isEmpty && i.controller.showsPrivacyFooter && i.controller.isPresented && NSApp.windows.filter(\.isVisible).isEmpty,
                  "intents \(i.recorder.intents), footer \(i.controller.showsPrivacyFooter)")
        }

        // 15. Empty Cmd+T selects row 1 with no top hit (F0063); Return switches to it.
        do {
            let s = fresh(.newTab)
            let row = s.controller.suggestions.first
            s.key(.returnKey); s.settle()
            check("Empty Cmd+T: row 1 selected, Return acts on it", s.controller.rows.count > 0 && intentMatches(s.recorder.intents.first, row),
                  "row 1 \(row?.kind.rawValue ?? "-") \(row?.title ?? "-"); intents \(s.recorder.intents)")
        }
        checks += ReviewFlows.run(env)
        checks += FooterFlows.run(env)
        return checks
    }

    static func intentMatches(_ intent: CommandBarIntent?, _ s: Suggestion?) -> Bool {
        guard let intent, let s else { return false }
        switch (intent, s.kind) {
        case (.open(let u, _, _), .navigate), (.open(let u, _, _), .history): return u == s.url
        case (.search(_, let u, _, _, _), .search), (.search(_, let u, _, _, _), .searchSuggestion), (.search(_, let u, _, _, _), .siteSearch): return u == s.url
        case (.switchToTab(let id, _), .switchToTab): return id == s.tabID
        case (.runAction(let id, _), .action): return id == s.actionID
        case (.copy(let t), .calculator): return t == s.title
        default: return false
        }
    }
}

/// Search-engine stand-in: three suggestions after 200 ms (inside OpenSuggest's 300 ms timeout).
struct SlowFetcher: SuggestionFetcher {
    func fetch(_ query: String, engine: SearchEngine) async throws -> [RemoteItem] {
        try await Task.sleep(for: .milliseconds(200))
        return [.query(query + " one"), .query(query + " two"), .query(query + " three")]
    }
}
