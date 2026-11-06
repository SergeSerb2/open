import AppKit
import OpenBoosts
import OpenSiteControl
import OpenModel

extension EditorFlows {
    @MainActor static func zapFlows() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        func check(_ name: String, _ pass: Bool) { checks.append(.init(name: name, pass: pass)) }
        let stage = EditorStage(), host = stage.host, session = stage.session
        host.zapEnabled = true
        stage.tap("editor.tool.zap")
        check("F13 Zap on calls enter then list and selects button", host.pickerCalls == ["enter", "list"] && session.isZapActive && stage.view.control(id: "editor.tool.zap")?.isEnabled == true)
        host.deliver("zap:committed")
        check("F13 commit reloads store count and AX", session.boost.zaps.count == 1 && stage.view.control(id: "editor.tool.zap")?.accessibilityLabel() == "Zap, 1" && session.undoManager.canUndo)
        host.deliver("zap:revealRequested")
        check("F13 reveal removes stored Zap and updates count", session.boost.zaps.isEmpty && host.boostStore.boost(id: session.boost.id)?.zaps.isEmpty == true && stage.view.control(id: "editor.tool.zap")?.accessibilityLabel() == "Zap")
        stage.key(6, "z", modifiers: .command)
        check("F13 reveal undo restores one Zap", session.boost.zaps.count == 1)
        stage.key(6, "z", modifiers: .command)
        check("F13 commit undo restores empty Zaps", session.boost.zaps.isEmpty && !session.undoManager.canUndo)
        let refreshes = host.refreshes
        host.deliver("zap:committed", selector: "article.post", matches: 3)
        host.boostStore.saveNow()
        let persisted = BoostStore(root: host.root, profileID: host.profileID).load()
        let relatedStored = persisted.first(where: { $0.id == session.boost.id })?.zaps.map(\.selector) == ["article.post"]
        let oneRefresh = host.refreshes == refreshes + 1
        stage.key(6, "z", modifiers: .command)
        check("F13 direct related commit persists one selector and one undo step", relatedStored && oneRefresh && session.boost.zaps.isEmpty && !session.undoManager.canUndo)
        stage.tap("editor.tool.zap")
        check("F13 Zap off sends exit", !session.isZapActive && host.pickerCalls.last == "exit")
        stage.tap("editor.tool.zap"); host.deliver("picker:exited")
        check("F13 picker exit clears button state", !session.isZapActive)
        stage.tap("editor.tool.zap"); session.endPickerSession()
        check("F13 App tab-switch hook exits picker", !session.isZapActive && host.pickerCalls.last == "exit")
        stage.tap("editor.tool.zap"); session.updatePageURL(URL(string: "https://news.example.com/next")!)
        check("F13 navigation exits picker", !session.isZapActive && host.pickerCalls.last == "exit")
        // The code-mode child binds this insertion callback to its CSS NSTextView.
        // Exercise the real text system and its selected range, without an isolated mock.
        let css = NSTextView(frame: .zero); css.string = "body { color: red; }"; css.setSelectedRange(NSRange(location: 5, length: 0))
        session.insertSelectorAtCaret = { css.insertText($0, replacementRange: css.selectedRange()) }
        let before = host.boostStore.boost(id: session.boost.id)
        session.pickSelector()
        host.deliver("zap:committed")
        check("Pick Selector refuses commit in native select capability", host.boostStore.boost(id: session.boost.id) == before && session.isSelecting)
        host.deliver("picker:selected", selector: ".post")
        check("Pick Selector inserts selector at CSS caret and exits", css.string == "body .post{ color: red; }" && !session.isSelecting && host.pickerCalls.last == "exit" && host.boostStore.boost(id: session.boost.id) == before)
        session.pickSelector(); session.finish(); session.finish()
        check("F13 close exits once and removes picker observer", !session.isSelecting && host.observers.isEmpty && session.isClosed)
        let blocked = EditorStage(); blocked.tap("editor.tool.zap")
        check("F13 unavailable host disables Zap with exact tooltip", !blocked.session.zapAvailable && blocked.view.control(id: "editor.tool.zap")?.isEnabled == false && blocked.view.control(id: "editor.tool.zap")?.tooltipTitle == "Zap isn't available yet.")
        return checks
    }
}
