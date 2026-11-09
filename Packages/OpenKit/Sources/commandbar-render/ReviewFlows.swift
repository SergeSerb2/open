import AppKit
import OpenCommandBar
import OpenModel
import OpenStore
import OpenSuggest

/// Review regressions through the rendered overlay, real field editor, engine, and SQLite store.
@MainActor
enum ReviewFlows {
    static func run(_ env: Scenes.Env) -> [Flows.Check] {
        var checks: [Flows.Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: @autoclosure () -> String) {
            let detail = detail()
            checks.append(.init(name: name, pass: pass, detail: detail))
            print("\(pass ? "PASS" : "FAIL")  \(name)  —  \(detail)")
        }
        func fresh(_ mode: CommandBarMode = .newTab, remote: Bool = false) -> Stage {
            let engine = SuggestEngine(model: env.world.model, history: env.history, fetcher: remote ? SlowFetcher() : nil)
            let s = Stage(size: CGSize(width: 1440, height: 900), scale: 1, engine: engine, backdrop: .darkPage)
            var request = Scenes.request(env, mode: mode)
            request.allowsRemoteSuggestions = remote
            s.controller.present(request)
            s.settle()
            return s
        }

        // 1. Real NSTextInputClient composition and commit, including Return's command route.
        do {
            let s = fresh()
            let editor = s.fieldEditor!
            var queries: [String] = []
            s.controller.onQueryStarted = { queries.append($0) }
            editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            check("IME: Japanese marked text submits zero queries", editor.hasMarkedText() && queries.isEmpty, "marked \(editor.hasMarkedText()), queries \(queries)")
            editor.unmarkText()
            s.settle()
            check("IME: unmark submits exactly one visible-text query", queries == ["にほん"] && s.controller.appliedQuery == s.controller.text,
                  "text \(s.controller.text), queries \(queries)")
            let c = fresh()
            var committed: [String] = []
            c.controller.onQueryStarted = { committed.append($0) }
            let ce = c.fieldEditor!
            ce.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            ce.insertText("日本", replacementRange: ce.markedRange())
            c.settle()
            check("IME: insertText commit submits exactly one query", committed == ["日本"] && !ce.hasMarkedText(), "queries \(committed)")
            let r = fresh()
            var returnQueries: [String] = []
            r.controller.onQueryStarted = { returnQueries.append($0) }
            r.fieldEditor!.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            r.key(.returnKey)
            check("IME: Return commits composition without choosing a row", r.controller.isPresented && r.recorder.intents.isEmpty && !r.fieldEditor!.hasMarkedText() && returnQueries == [r.controller.text],
                  "presented \(r.controller.isPresented), marked \(r.fieldEditor?.hasMarkedText() ?? false), queries \(returnQueries), intents \(r.recorder.intents)")
            for key in [Stage.Key.tab, .escape, .space, .up, .down] {
                let k = fresh()
                k.type("yt"); k.settle()
                k.fieldEditor!.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                let selected = k.controller.selectedIndex
                k.key(key)
                check("IME: \(key) stays with the input method", k.controller.isPresented && k.controller.siteScope == nil && k.recorder.intents.isEmpty && !k.controller.userMovedSelection && k.controller.selectedIndex == selected,
                      "scope \(k.controller.siteScope?.id ?? "nil"), intents \(k.recorder.intents)")
            }
        }

        // 2. Dump the rendered overlay's actual AppKit AX tree and invoke its press actions.
        do {
            let s = fresh()
            s.type("git"); s.settle()
            _ = s.render(scale: 1)
            let nodes = accessibilityNodes(s.controller.view)
            print("AX TREE (rendered git overlay)\n" + accessibilityDump(s.controller.view))
            let buttons = nodes.filter { $0.accessibilityRole() == .button }
            let row = s.controller.rows.first!
            let button = buttons.first { $0.accessibilityLabel() == row.title }
            check("AX: rendered rows are labeled buttons with accessory values", s.controller.rows.allSatisfy { row in
                buttons.contains { button in
                    guard button.accessibilityLabel() == row.title else { return false }
                    let value = button.accessibilityValue() as? String ?? ""
                    switch row.accessory {
                    case .switchTo(let text): return value.contains(text) && (row.subtitle.isEmpty || value.contains(row.subtitle))
                    case .keys(let keys): return value.contains(keys.joined(separator: " ")) && (row.subtitle.isEmpty || value.contains(row.subtitle))
                    case .none: return value == row.subtitle
                    }
                }
            }, "\(buttons.count) AX buttons, \(s.controller.rows.count) rows")
            let field = nodes.compactMap { $0 as? NSTextField }.first
            check("AX: native placeholder equals visible placeholder", field?.placeholderString == s.controller.view.debugInput.placeholder,
                  "placeholder \(field?.placeholderString ?? "nil")")
            s.key(.down)
            let list = nodes.first { $0.accessibilityRole() == .list }
            let selected = (list?.accessibilitySelectedChildren()?.first as? NSView)?.accessibilityLabel()
            check("AX: selection exposes the highlighted row", selected == s.controller.rows[s.controller.selectedIndex!].title, "selected AX label \(selected ?? "nil")")
            let target = s.controller.suggestions.first
            let pressed = button?.accessibilityPerformPress() == true
            check("AX: row press performs its real intent", pressed && Flows.intentMatches(s.recorder.intents.first, target), "intents \(s.recorder.intents)")
            let h = fresh()
            let info = accessibilityNodes(h.controller.view).first { $0.accessibilityLabel() == "Command Bar Help" }
            let infoPressed = info?.accessibilityRole() == .button && info?.accessibilityPerformPress() == true
            let shownByPress = h.controller.showsPrivacyFooter
            h.key(.info, flags: .command)
            check("AX: (i) is a labeled button; its press and Command-I toggle the privacy footer", infoPressed && shownByPress && !h.controller.showsPrivacyFooter
                  && h.recorder.intents.isEmpty && h.controller.view.debugUsesOwnFieldEditor,
                  "press → footer \(shownByPress), Cmd+I → footer \(h.controller.showsPrivacyFooter), intents \(h.recorder.intents)")
            let focusTarget = NSTextField(string: "Next control")
            focusTarget.frame = CGRect(x: 10, y: 10, width: 120, height: 30)
            h.root.addSubview(focusTarget)
            let helpField = accessibilityNodes(h.controller.view).compactMap { $0 as? NSTextField }.first
            helpField?.nextKeyView = focusTarget
            h.key(.tab)
            check("Tab without a Site Search hint uses normal focus traversal", focusTarget.currentEditor() === h.window.firstResponder, "first responder \(String(describing: h.window.firstResponder.map { type(of: $0) }))")
            let a = fresh()
            a.type("toggle sid"); a.settle()
            check("AX: action button includes its shortcut", accessibilityNodes(a.controller.view).contains { $0.accessibilityRole() == .button && ($0.accessibilityValue() as? String)?.contains("⌘ S") == true }, "shortcut ⌘ S")
        }

        // 3. A pending Return belongs only to the query and presentation that received it.
        do {
            let s = fresh()
            s.type("12*(3+4)"); s.key(.returnKey)
            s.type("x"); s.settle()
            check("Pending Return is cleared by the next text change", s.controller.isPresented && s.recorder.intents.isEmpty && s.controller.appliedQuery == "12*(3+4)x", "intents \(s.recorder.intents)")
            let p = fresh()
            p.type("12*(3+4)"); p.key(.returnKey)
            p.controller.present(Scenes.request(env, mode: .newTab))
            p.settle()
            check("Pending Return is cleared by present", p.controller.isPresented && p.recorder.intents.isEmpty, "intents \(p.recorder.intents)")
            let d = fresh()
            d.type("12*(3+4)"); d.key(.returnKey)
            d.controller.dismiss(reason: .programmatic)
            d.controller.present(Scenes.request(env, mode: .newTab))
            d.settle()
            check("Pending Return is cleared by dismiss and reopen", d.controller.isPresented && d.recorder.intents == [.dismissed(.programmatic)], "intents \(d.recorder.intents)")
            let empty = fresh(.searchTabs)
            empty.type("unmatched-query-782649"); empty.key(.returnKey); empty.settle()
            empty.fieldEditor!.selectAll(nil)
            empty.type("git"); empty.settle()
            check("Return on an empty snapshot never applies to a later query", empty.controller.isPresented && empty.recorder.intents.isEmpty && !empty.controller.rows.isEmpty, "rows \(empty.controller.rows.count), intents \(empty.recorder.intents)")
        }

        // 4. Return uses the current highlight without waiting for either async provider.
        do {
            let s = fresh(remote: true)
            s.type("git")
            spin(until: { s.controller.appliedQuery == "git" && s.controller.appliedSequence >= 0 })
            s.key(.down)
            let row = s.controller.selectedSuggestion
            let wasPending = !s.controller.isSnapshotFinal
            s.key(.returnKey)
            check("Return uses the visible selected row while history/remote are pending", wasPending && !s.controller.isPresented && Flows.intentMatches(s.recorder.intents.first, row), "pending \(wasPending), intents \(s.recorder.intents)")
            let t = fresh(remote: true)
            t.type("12*(3+4)"); t.key(.returnKey)
            spin(until: { !t.controller.isPresented })
            check("Return before a first snapshot opens its top row without provider wait", t.recorder.intents == [.copy("84")] && !t.controller.isSnapshotFinal,
                  "final \(t.controller.isSnapshotFinal), intents \(t.recorder.intents)")
        }

        // 5. A boundary arrow does not pin a selection against a later snapshot.
        do {
            let s = fresh(remote: true)
            s.type("git")
            spin(until: { s.controller.appliedQuery == "git" && s.controller.appliedSequence >= 0 })
            s.key(.up)
            let unchanged = !s.controller.userMovedSelection
            s.settle()
            check("Up at row zero does not count as a user move", unchanged && !s.controller.userMovedSelection && s.controller.selectedIndex == 0, "moved \(s.controller.userMovedSelection)")
            for _ in 0..<20 { s.key(.down) }
            let bottom = s.controller.selectedIndex
            s.key(.down)
            check("Down at the last row preserves the selected row", bottom == s.controller.selectedIndex, "row \(bottom ?? -1)")
        }

        // 6. The real favicon store fills every view sharing an origin, and bounded misses expire.
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("commandbar-favicon-flow-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = try FaviconStore(databaseURL: dir.appendingPathComponent("icons.sqlite3"))
            let source = FaviconStoreSource(store: store)
            let icon = Synthetic.icon("", color: 0x49A85A)
            let png = NSBitmapImageRep(data: icon.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            let first = URL(string: "https://icons.example/a")!, second = URL(string: "https://icons.example/b")!
            _ = try blockingThrowing { try await store.ingest(imageData: png, iconURL: nil, for: first, pageSpecific: false) }
            let s = fresh()
            s.controller.favicons = source
            s.controller.presentPreview(.init(input: .init(placeholder: "Search or Enter URL…", leadingIcon: .favicon(first, fallback: "globe")), rows: [
                .init(id: "a", kind: .history, title: "Icon A", icon: .favicon(first, fallback: "globe")),
                .init(id: "b", kind: .history, title: "Icon B", icon: .favicon(second, fallback: "globe")),
            ]))
            _ = s.render(scale: 1)
            let before = s.controller.view.debugRowDrawCount
            var loaded: [URL] = []
            _ = source.favicon(for: first) { loaded.append($0) }
            _ = source.favicon(for: second) { loaded.append($0) }
            spin(until: { loaded.count == 2 })
            OffscreenRenderer.settle(s.root)
            check("Favicons: all same-origin waiters and rows receive the icon", Set(loaded) == Set([first, second]) && s.controller.view.debugRowDrawCount >= before + 2,
                  "callbacks \(loaded.count), redrawn rows \(s.controller.view.debugRowDrawCount - before)")
            let cache = FaviconStoreSource(store: store)
            cache.capacity = 2
            let miss = URL(string: "https://missing.example/")!
            _ = cache.favicon(for: miss) { _ in }
            // An actor round trip followed by the main loop drains that lookup before eviction.
            _ = blocking { await store.count() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            _ = try blockingThrowing { try await store.ingest(imageData: png, iconURL: nil, for: miss, pageSpecific: false) }
            var premature = false
            let cachedMiss = cache.favicon(for: miss) { _ in premature = true }
            let b = URL(string: "https://missing-b.example/")!, c = URL(string: "https://missing-c.example/")!
            _ = cache.favicon(for: b) { _ in }; _ = cache.favicon(for: c) { _ in }
            _ = blocking { await store.count() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            var retried = false
            _ = cache.favicon(for: miss) { _ in retried = true }
            spin(until: { retried })
            check("Favicons: misses use bounded FIFO and an evicted origin retries", cachedMiss == nil && !premature && retried, "retry delivered \(retried)")
        } catch {
            check("Favicons: real store flow", false, "\(error)")
        }

        // 7. Preview rows intentionally have no backing suggestions.
        do {
            let s = fresh()
            s.controller.presentPreview(.init(input: .init(placeholder: "Search", leadingIcon: .symbol("magnifyingglass", plate: false)), rows: [
                .init(id: "preview", kind: .search, title: "Preview", icon: .symbol("magnifyingglass", plate: false)),
            ]))
            _ = s.render(scale: 1)
            check("selectedSuggestion bounds-checks preview rows", s.controller.selectedIndex == 0 && s.controller.selectedSuggestion == nil, "selected \(s.controller.selectedIndex ?? -1), suggestions \(s.controller.suggestions.count)")
            s.controller.moveSelection(by: 1)
            s.key(.returnKey)
            check("Return on a preview row is safe", s.controller.isPresented && s.recorder.intents.isEmpty, "intents \(s.recorder.intents)")
        }

        // 8. Paste uses NSTextView's real paste/should-change path, preserving Unicode characters.
        do {
            let s = fresh()
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let pasted = "line1\r\nline2\rline3\n" + String(repeating: "🙂", count: 2_100)
            pasteboard.setString(pasted, forType: .string)
            var queries: [String] = []
            s.controller.onQueryStarted = { queries.append($0) }
            s.fieldEditor!.readSelection(from: pasteboard, type: .string)
            s.settle()
            check("Paste strips line breaks, caps at 2048 characters, and queries visible text", s.controller.text.count == 2_048 && !s.controller.text.contains(where: { $0 == "\r" || $0 == "\n" }) && queries == [s.controller.text] && s.controller.appliedQuery == s.controller.text && s.fieldEditor!.string == s.controller.text,
                  "characters \(s.controller.text.count), queries \(queries.count), visible/query match \(s.controller.appliedQuery == s.controller.text)")
            s.type("x")
            check("Typing past the length limit keeps visible and queried text equal", s.controller.text.count == 2_048 && queries.count == 1 && s.fieldEditor!.string == s.controller.text, "characters \(s.controller.text.count), queries \(queries.count)")
        }

        // 9. Each presentation starts with clean composition and its own empty undo stack.
        do {
            let s = fresh()
            s.type("private text"); s.settle()
            let editor = s.fieldEditor!
            let hadUndo = editor.undoManager?.canUndo == true
            editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            s.controller.dismiss(reason: .programmatic)
            let cleanDismiss = !editor.hasMarkedText() && editor.undoManager?.canUndo == false
            s.controller.present(Scenes.request(env, mode: .editCurrentURL))
            s.settle()
            let current = s.controller.text
            editor.undoManager?.undo()
            check("Dismiss and reopen clear marked text and the field editor undo stack", hadUndo && cleanDismiss && !editor.hasMarkedText() && editor.undoManager?.canUndo == false && s.controller.text == current,
                  "had undo \(hadUndo), clean dismiss \(cleanDismiss), can undo \(editor.undoManager?.canUndo ?? false)")
            s.type("draft")
            editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            s.controller.present(Scenes.request(env, mode: .newTab))
            s.settle()
            check("Present while open also clears marked text and undo", !editor.hasMarkedText() && editor.undoManager?.canUndo == false && s.controller.text.isEmpty,
                  "marked \(editor.hasMarkedText()), can undo \(editor.undoManager?.canUndo ?? false)")
        }

        // 10. Present before the overlay gets a window, then attach and immediately type.
        do {
            let s = Stage(size: CGSize(width: 1440, height: 900), scale: 1, engine: env.engine, backdrop: .darkPage) { c in
                c.present(Scenes.request(env, mode: .editCurrentURL))
            }
            let focused = s.controller.view.debugUsesOwnFieldEditor
            let selected = s.fieldEditor?.selectedRange() == NSRange(location: 0, length: (env.world.current.url.absoluteString as NSString).length)
            s.type("attached"); s.settle()
            check("Present before window attachment focuses and selects the URL", focused && selected && s.controller.text == "attached", "focused \(focused), selected URL \(selected), text \(s.controller.text)")
        }
        return checks
    }

    static func accessibilityNodes(_ root: NSView) -> [NSView] {
        [root] + (root.accessibilityChildren() ?? []).compactMap { $0 as? NSView }.flatMap(accessibilityNodes)
    }

    static func accessibilityDump(_ root: NSView, indent: String = "") -> String {
        let line = "\(indent)\(root.accessibilityRole()?.rawValue ?? "ignored") label=\(root.accessibilityLabel() ?? "") value=\(root.accessibilityValue().map(String.init(describing:)) ?? "")"
        return ([line] + (root.accessibilityChildren() ?? []).compactMap { $0 as? NSView }.map { accessibilityDump($0, indent: indent + "  ") }).joined(separator: "\n")
    }
}
