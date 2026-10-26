import AppKit
import OpenModel
import OpenSidebar

/// Drives the production row editor and intent-to-model path in a never-shown window.
@MainActor
private final class TidyRenameActions: SidebarDelegate {
    func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent) -> Bool {
        ModelSidebarActions(context: sidebar.context).perform(intent)
    }
}

@MainActor
func runTidyRenameDemo(check: (Bool, String) -> Void) {
    _ = NSApplication.shared
    let profile = Profile(name: "Rename")
    let space = Space(title: "Rename", profileID: profile.id)
    let state = BrowserWindowState(focusedSpaceID: space.id)
    let model = BrowserModel(profiles: [profile], spaces: [space], windows: [state])
    let raw = "Inbox (3) - rename@example.invalid - Gmail"
    let tab = model.newTab(in: space.id, url: URL(string: "https://mail.google.com/mail/#inbox")!, title: raw)
    let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
    let sidebar = SidebarView(context: SidebarContext(model: model, windowID: state.id))
    let actions = TidyRenameActions(); sidebar.delegate = actions
    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 250, height: 700),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = sidebar
    defer { window.contentView = nil; window.close() }
    sidebar.frame = NSRect(x: 0, y: 0, width: 250, height: 700)
    for _ in 0..<3 { sidebar.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    sidebar.beginRename(nodeID: tab.id)
    func editor(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    guard let outline = sidebar.focusedOutline, let field = editor(in: outline) else {
        check(false, "T2 production Gmail rename editor opens"); return
    }
    check(tab.displayTitle == "Inbox" && field.stringValue == raw, "T2 production rename starts from the raw Gmail title")
    let committed = field.delegate?.control?(field, textView: field.currentEditor() as? NSTextView ?? NSTextView(),
                                            doCommandBy: #selector(NSResponder.insertNewline(_:))) == true
    check(committed && tab.customTitle == nil && tab.title == raw && !undo.canUndo,
          "T2 unchanged Return preserves raw title, creates no customTitle or undo step")
}
