import AppKit
import OpenCommandBar
import OpenDesign
import OpenSuggest

/// Flows 69–80 and 86 (docs/plans/commandbar-completion.md §5.1): inline completion through real key
/// events, the real field editor and text system, and the real engine over the synthetic world
/// (history: GitHub typed 6 times, YouTube typed 5 times).
@MainActor
enum CompletionFlows {
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
        func state(_ s: Stage) -> String {
            let sel = s.fieldEditor.map { NSStringFromRange($0.selectedRange()) } ?? "-"
            return "field \"\(s.controller.fieldText)\" typed \"\(s.controller.text)\" selection \(sel) completion \(s.controller.inlineCompletion.map { "\($0.fieldText)/\($0.typedLength)" } ?? "none")"
        }
        func tail(_ s: Stage) -> NSRange? {
            s.controller.inlineCompletion.map { NSRange(location: $0.typedLength, length: ($0.fieldText as NSString).length - $0.typedLength) }
        }

        // 69. "gi" → "git" → "gith": the completion follows each snapshot in the same apply; field = host,
        // selection = tail, one query per keystroke, and none of it in the undo stack.
        do {
            let s = fresh()
            var queries: [String] = []
            var appliedWithout = 0
            s.controller.onQueryStarted = { queries.append($0) }
            s.controller.onSnapshotApplied = { [weak s] snap in
                guard let s, let c = snap.inlineCompletion else { return }
                // The field shows the snapshot's completion when the apply returns (row 1 selected).
                if s.controller.selectedIndex == 0, s.controller.fieldText != c.fieldText { appliedWithout += 1 }
            }
            var steps: [String] = []
            for ch in "gith" {
                s.type(String(ch)); s.settle()
                let ok = s.controller.inlineCompletion.map { c in
                    c.rowID == s.controller.suggestions.first?.id && s.fieldEditor?.selectedRange() == tail(s)
                        && TextMatching.fold(c.fieldText).starts(with: TextMatching.fold(s.controller.text))
                } ?? false
                if !ok { steps.append(state(s)) }
            }
            let atGith = s.controller.fieldText
            let typingQueries = queries
            let editor = s.fieldEditor!
            let canUndo = editor.undoManager?.canUndo == true
            editor.undoManager?.undo(); s.settle()
            check("69: typing \"gi\", \"git\", \"gith\": completion of row 1 each time, tail selected, \"gith\" → github.com",
                  steps.isEmpty && atGith == "github.com" && typingQueries == ["g", "gi", "git", "gith"] && appliedWithout == 0,
                  "wrong steps \(steps); queries \(typingQueries); applied without the completion \(appliedWithout)")
            check("69: the completion is never in the undo stack (one Undo removes the typing, nothing of the host stays)",
                  canUndo && s.controller.fieldText.isEmpty && s.controller.inlineCompletion == nil, state(s))
        }

        // 70. A matching character keeps the completion with no gap before its snapshot.
        do {
            let s = fresh()
            s.type("gith"); s.settle()
            var gaps = 0
            s.controller.onSnapshotApplied = { [weak s] _ in if s?.controller.inlineCompletion == nil { gaps += 1 } }
            s.type("u")
            let immediate = state(s)
            let kept = s.controller.fieldText == "github.com" && s.fieldEditor?.selectedRange() == NSRange(location: 5, length: 5)
            s.settle()
            check("70: a matching character keeps the completion at once (before its snapshot) and in every applied snapshot",
                  kept && gaps == 0 && s.controller.text == "githu" && s.controller.fieldText == "github.com", "after the key: \(immediate); gaps \(gaps)")

            // The same with another letter case: the field keeps the candidate's case (CC-6); one Undo clears the typing.
            let u = fresh()
            u.type("gith"); u.settle()
            u.type("U")
            let upperImmediate = state(u)
            let upper = u.controller.fieldText == "github.com" && u.controller.text == "githU" && u.fieldEditor?.selectedRange() == NSRange(location: 5, length: 5)
            u.settle()
            let upperState = state(u)
            let settledUpper = u.controller.inlineCompletion?.fieldText == "github.com" && u.controller.text == "githU"
            u.fieldEditor?.undoManager?.undo(); u.settle()
            check("70: a matching character in another case keeps the completion in the candidate's case; Undo clears the typing",
                  upper && settledUpper && u.controller.fieldText.isEmpty && u.controller.inlineCompletion == nil,
                  "at the key: \(upperImmediate); settled: \(upperState); after Undo: \(state(u))")
        }

        // 71. A non-matching character replaces the completion.
        do {
            let s = fresh()
            s.type("gith"); s.settle()
            s.type("x")
            let immediate = s.controller.fieldText
            s.settle()
            check("71: a non-matching character replaces the completion", immediate == "githx" && s.controller.inlineCompletion == nil && s.controller.text == "githx", state(s))
        }

        // 72–73. Backspace removes only the completion and re-queries with completion off; for URL-like
        // text the typed URL becomes row 1. A second Backspace deletes a character; completion stays off.
        do {
            let s = fresh()
            var queries: [String] = []
            s.controller.onQueryStarted = { queries.append($0) }
            s.type("github.co"); s.settle()
            let before = s.controller.inlineCompletion?.fieldText
            s.key(.backspace); s.settle()
            let row1 = s.controller.suggestions.first
            check("72: Backspace removes only the completion; the text stays; re-query; row 1 is the typed URL (CC-40)",
                  before == "github.com" && s.controller.fieldText == "github.co" && s.controller.text == "github.co" && s.controller.inlineCompletion == nil
                    && queries.suffix(2) == ["github.co", "github.co"] && row1?.kind == .navigate && row1?.isWhatYouTyped == true,
                  "before \(before ?? "none"); \(state(s)); queries \(queries.suffix(3)); row 1 \(row1?.kind.rawValue ?? "-")")
            s.key(.backspace); s.settle()
            let afterSecond = state(s)
            let second = s.controller.fieldText == "github.c" && s.controller.inlineCompletion == nil
            s.type("o"); s.settle()
            check("73: a second Backspace deletes a typed character with no completion; the next insertion completes again",
                  second && s.controller.inlineCompletion?.fieldText == "github.com", "after 2nd: \(afterSecond); after \"o\": \(state(s))")
            let f = fresh()
            f.type("gith"); f.settle()
            f.key(.forwardDelete); f.settle()
            check("72: Forward Delete also removes only the completion (guess)", f.controller.fieldText == "gith" && f.controller.inlineCompletion == nil, state(f))
        }

        // 74. Right, End, Cmd+Right accept; Left and Home make the text typed with the caret where the key says.
        do {
            var wrong: [String] = []
            for (key, flags, caret, name) in [(Stage.Key.right, NSEvent.ModifierFlags(), 10, "Right"), (.end, [], 10, "End"), (.right, .command, 10, "Cmd+Right"),
                                               (.left, [], 4, "Left"), (.home, [], 0, "Home"), (.left, .command, 0, "Cmd+Left")] {
                let s = fresh()
                s.type("gith"); s.settle()
                s.key(key, flags: flags); s.settle()
                let ok = s.controller.fieldText == "github.com" && s.controller.text == "github.com" && s.controller.inlineCompletion == nil
                    && s.fieldEditor?.selectedRange() == NSRange(location: caret, length: 0) && s.controller.appliedQuery == "github.com"
                if !ok { wrong.append("\(name): \(state(s))") }
            }
            check("74: Right/End/Cmd+Right accept (caret at the end); Left/Home/Cmd+Left keep the text, caret at the start of the completion or the line",
                  wrong.isEmpty, wrong.isEmpty ? "6 keys" : wrong.joined(separator: "; "))
        }

        // 75. Down hides the completion, Up restores it; a pointer on another row too; no query.
        do {
            let s = fresh()
            s.type("gith"); s.settle()
            var queries = 0
            s.controller.onQueryStarted = { _ in queries += 1 }
            s.key(.down)
            let down = s.controller.fieldText == "gith" && s.controller.inlineCompletion == nil && s.fieldEditor?.selectedRange() == NSRange(location: 4, length: 0)
            s.key(.up)
            let up = s.controller.fieldText == "github.com" && s.fieldEditor?.selectedRange() == NSRange(location: 4, length: 6)
            let panel = s.controller.view.panelFrame
            s.mouse(.mouseMoved, at: CGPoint(x: panel.midX, y: panel.minY + CommandBarMetrics.listTop + 1.5 * CommandBarMetrics.rowHeight))
            let hover = s.controller.fieldText == "gith"
            s.mouse(.mouseMoved, at: CGPoint(x: panel.midX, y: panel.minY + CommandBarMetrics.listTop + 0.5 * CommandBarMetrics.rowHeight))
            let back = s.controller.fieldText == "github.com"
            check("75: Down/hover on row 2 hide the completion, Up/hover on row 1 show it again; no query (D2)",
                  down && up && hover && back && queries == 0, "down \(down) up \(up) hover \(hover) back \(back) queries \(queries)")
        }

        // 76. Return opens row 1, the completion row; a pending Return uses the first snapshot's row 1.
        do {
            let s = fresh()
            s.type("gith"); s.settle()
            let row1 = s.controller.suggestions.first
            s.key(.returnKey); s.settle()
            let p = fresh()
            p.type("gith")
            p.key(.returnKey) // before any snapshot of "gith"
            p.settle()
            check("76: Return opens row 1 (the completion's row); a Return before the snapshot waits and opens its row 1",
                  Flows.intentMatches(s.recorder.intents.first, row1) && row1?.id == s.recorder.intents.first.flatMap { _ in row1?.id }
                    && p.recorder.intents.count == 1 && Flows.intentMatches(p.recorder.intents.first, row1),
                  "intents \(s.recorder.intents) / pending \(p.recorder.intents); row 1 \(row1?.title ?? "-")")
        }

        // 77. Paste never completes; Cmd+A and a caret placement make the completion typed text.
        do {
            let s = fresh()
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("gith", forType: .string)
            _ = s.fieldEditor!.readSelection(from: pasteboard, type: .string)
            s.settle()
            let paste = s.controller.fieldText == "gith" && s.controller.inlineCompletion == nil && s.controller.appliedQuery == "gith"
            let a = fresh()
            a.type("gith"); a.settle()
            a.fieldEditor!.selectAll(nil); a.settle()
            let selectAll = a.controller.text == "github.com" && a.controller.inlineCompletion == nil && a.controller.appliedQuery == "github.com"
                && a.fieldEditor?.selectedRange() == NSRange(location: 0, length: 10)
            let c = fresh()
            c.type("gith"); c.settle()
            c.fieldEditor!.setSelectedRange(NSRange(location: 2, length: 0)) // what a click in the text does
            c.settle()
            let click = c.controller.text == "github.com" && c.controller.inlineCompletion == nil && c.fieldEditor?.selectedRange() == NSRange(location: 2, length: 0)
            check("77: paste never completes; Cmd+A and a caret placement make the completion typed text and re-query",
                  paste && selectAll && click, "paste \(paste) (\(state(s))); select all \(selectAll); caret \(click)")
        }

        // 78. Tab with a hint enters Site Search from the typed text; Space with a completion types a space.
        do {
            let s = fresh()
            s.type("youtu"); s.settle()
            let completed = s.controller.inlineCompletion?.fieldText == "youtube.com"
            s.key(.tab); s.settle()
            let tab = s.controller.siteScope?.id == "youtube" && s.controller.fieldText.isEmpty && s.controller.inlineCompletion == nil
            let t = fresh()
            t.type("youtube"); t.settle()
            let hint = t.controller.view.debugTrailing
            t.type(" "); t.settle()
            check("78: Tab enters Site Search from the typed text (completion dropped); Space with a completion types a space (CC-5)",
                  completed && tab && hint == "hint YouTube" && t.controller.siteScope == nil && t.controller.fieldText == "youtube " && t.controller.inlineCompletion == nil,
                  "tab \(tab); hint \(hint); after Space \(state(t)) scope \(t.controller.siteScope?.id ?? "nil")")
        }

        // 79. IME: marked text removes the completion first (no query); no completion while marked;
        // a commit at the end allows one.
        do {
            let s = fresh()
            s.type("gith"); s.settle()
            var queries: [String] = []
            s.controller.onQueryStarted = { queries.append($0) }
            let editor = s.fieldEditor!
            editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let marked = s.controller.inlineCompletion == nil && editor.string == "githに" && queries.isEmpty
            editor.unmarkText(); s.settle()
            let c = fresh()
            var committed: [String] = []
            c.controller.onQueryStarted = { committed.append($0) }
            let ce = c.fieldEditor!
            ce.setMarkedText("gith", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let none = c.controller.inlineCompletion == nil && committed.isEmpty
            ce.insertText("gith", replacementRange: ce.markedRange()); c.settle()
            check("79: IME: marking removes the completion first with no query; none while marked; a commit at the end completes",
                  marked && none && committed == ["gith"] && c.controller.inlineCompletion?.fieldText == "github.com",
                  "marked \(marked) (\(editor.string)); none \(none); commit queries \(committed); \(state(c))")
        }

        // 80. Cmd+L: typing replaces the selected URL, then completes.
        do {
            let s = fresh(.editCurrentURL)
            s.type("gith"); s.settle()
            check("80: Cmd+L: typing replaces the URL, then completes", s.controller.text == "gith" && s.controller.fieldText == "github.com", state(s))
        }

        // 86. AX: the field's value is the whole text; its selected range is the completion (CC-3).
        do {
            let s = fresh()
            s.type("gith"); s.settle()
            let editor = s.fieldEditor!
            let value = editor.accessibilityValue()
            let range = editor.accessibilitySelectedTextRange()
            check("86: AX value = whole field text, AX selected range = the completion (CC-3)",
                  value == "github.com" && range == NSRange(location: 4, length: 6), "value \(value ?? "nil"), range \(NSStringFromRange(range))")
        }
        return checks
    }
}
