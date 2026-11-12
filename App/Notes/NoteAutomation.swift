#if OPEN_AUTOMATION
import AppKit
import OpenDocuments
import OpenModel

extension AutomationController {
  /// Notes through the real App paths: the registry command (menu action),
  /// the editor's own text views, and the store on disk.
  func note(_ args: [String: Any]) throws -> [String: Any] {
    let action = args["action"] as? String ?? "state"
    let allowed: Set<String>
    switch action {
    case "state": allowed = ["action", "tab"]
    case "create": allowed = ["action", "split"]
    case "focus": allowed = ["action", "field"]
    case "type", "paste": allowed = ["action", "text", "field"]
    case "flush": allowed = ["action"]
    default: throw Failure(message: "unknown note action")
    }
    guard Set(args.keys).isSubset(of: allowed) else { throw Failure(message: "unknown note argument") }
    let factory = try window
    switch action {
    case "create":
      let split = args["split"] as? Bool ?? false
      // The same entry as File ▸ New Note / New Note (in Split) and ⌃⇧N / ⌃⌥N.
      guard factory.performAppCommand(split ? "new-note-in-split" : "new-note") else { throw Failure(message: "New Note is disabled") }
    case "focus", "type", "paste":
      guard let tab = factory.selectedTab, let host = factory.noteHosts[tab.id], let window = host.editor.window else {
        throw Failure(message: "the selected tab is not a shown Note")
      }
      if let field = args["field"] as? String {
        guard ["title", "body"].contains(field) else { throw Failure(message: "field must be title or body") }
        window.makeFirstResponder(field == "title" ? host.editor.titleView : host.editor.bodyView)
      }
      if action == "paste" {
        // AppKit's own paste path, from a private pasteboard (never the user's clipboard).
        guard let text = args["text"] as? String,
          let view = window.firstResponder as? NoteTextView else { throw Failure(message: "no text or no Note field is focused") }
        let board = NSPasteboard(name: NSPasteboard.Name("open.automation.note-paste"))
        board.clearContents(); board.setString(text, forType: .string)
        guard view.readSelection(from: board, type: .string) else { throw Failure(message: "paste refused") }
        board.releaseGlobally()
      }
      if action == "type" {
        guard let text = args["text"] as? String,
          let view = window.firstResponder as? NoteTextView else { throw Failure(message: "no text or no Note field is focused") }
        // The real typing path: undo, delegate and the title's line-break rule all run.
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
          if piece.offset > 0 { view.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
          if !piece.element.isEmpty { view.insertText(String(piece.element), replacementRange: view.selectedRange()) }
        }
      }
    case "flush": app.notes.flush()
    default: break
    }
    var tab = factory.selectedTab
    if let id = args["tab"] as? String {
      guard let uuid = UUID(uuidString: id), let found = factory.model.tab(id: ItemID(rawValue: uuid)) else { throw Failure(message: "no tab \(id)") }
      tab = found
    }
    let noteID = NoteLink.id(from: tab?.url)
    let host = tab.flatMap { factory.noteHosts[$0.id] }
    let responder = host?.editor.window?.firstResponder
    let file = noteID.map { app.notes.fileURL(for: $0) }
    var stored: Any = NSNull()
    if let file, let data = try? Data(contentsOf: file),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      stored = ["title": object["title"] ?? "", "text": object["text"] ?? "", "formatVersion": object["formatVersion"] ?? 0]
    }
    var frame: [Double] = []
    if let view = host?.editor, let window = view.window {
      let rect = view.convert(view.bounds, to: nil)
      frame = [rect.minX, window.contentLayoutRect.height - rect.maxY, rect.width, rect.height].map { Double($0) }
    }
    return [
      "tab": tab?.id.description as Any? ?? NSNull(), "url": tab?.url.absoluteString ?? "",
      "tabTitle": tab?.title ?? "", "isNote": noteID != nil, "noteID": noteID?.uuidString.lowercased() as Any? ?? NSNull(),
      "hasHost": host != nil, "noteHostCount": factory.noteHosts.count,
      "shown": host.map { !$0.editor.isHiddenOrHasHiddenAncestor && $0.editor.window != nil } ?? false,
      "frame": frame,
      "title": host?.editor.titleView.string ?? "", "body": host?.editor.bodyView.string ?? "",
      "focused": responder === host?.editor.titleView ? "title" : responder === host?.editor.bodyView ? "body" : "other",
      "placeholders": [NoteLook.titlePlaceholder, NoteLook.bodyPlaceholder],
      "dark": host?.editor.isDark ?? false,
      "editable": host.map { $0.editor.titleView.isEditable && $0.editor.bodyView.isEditable } ?? false,
      "unreadable": host?.unreadable ?? false,
      "favicon": tab?.live.faviconPNG == NoteTab.faviconPNG && tab?.live.faviconPNG != nil,
      "file": file?.path ?? "", "stored": stored,
      "pendingWrites": app.notes.hasPendingWrites, "writeCount": app.notes.writeCount,
      "storeError": app.notes.lastError ?? "",
      "engineContentCreationCount": factory.contentCreationCount,
      "engineHostForTab": tab.map { factory.contents[$0.id] != nil } ?? false,
    ]
  }
}
#endif
