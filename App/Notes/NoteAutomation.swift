#if OPEN_AUTOMATION
import AppKit
import OpenDocuments
import OpenModel

extension AutomationController {
  static func formatRows(_ formats: [NoteFormat]) -> [[String: Any]] {
    formats.map { f in
      var row: [String: Any] = ["type": f.type, "location": f.location, "length": f.length]
      if let url = f.url { row["url"] = url }
      if let level = f.level { row["level"] = level }
      return row
    }
  }
  static func barState(_ editor: NoteEditorView) -> [String: Any] {
    let bar = editor.formatBar
    var selectionTop: Double = 0
    if let manager = editor.bodyView.layoutManager, let container = editor.bodyView.textContainer {
      let glyphs = manager.glyphRange(forCharacterRange: editor.bodyView.selectedRange(), actualCharacterRange: nil)
      selectionTop = Double(editor.convert(manager.boundingRect(forGlyphRange: glyphs, in: container), from: editor.bodyView).maxY)
    }
    return ["visible": !bar.isHidden, "frame": [bar.frame.minX, bar.frame.minY, bar.frame.width, bar.frame.height].map { Double($0) },
            "selectionTop": selectionTop, "editingLink": bar.isEditingLink,
            "on": bar.buttons.filter(\.isOn).map(\.name), "items": bar.buttons.map(\.name)]
  }
  static func imageCount(_ editor: NoteEditorView) -> Int {
    var count = 0
    let storage = editor.bodyView.attributedString()
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
      if (value as? NSTextAttachment)?.image != nil { count += 1 }
    }
    return count
  }

  static func hex(_ color: CGColor?) -> String {
    guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "" }
    let parts: [CGFloat] = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
    return "#" + parts.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
  }

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
    case "flush", "export-state": allowed = ["action"]
    case "export": allowed = ["action", "path"]
    case "import-zip": allowed = ["action", "path"]
    case "row-menu": allowed = ["action", "tab"]
    case "rename": allowed = ["action", "tab", "text"]
    case "export-one": allowed = ["action", "tab", "path"]
    case "sheet": allowed = ["action", "press", "cancel"]
    case "select": allowed = ["action", "start", "length"]
    case "press": allowed = ["action", "item"]
    case "gutter": allowed = ["action", "item"]
    case "paste-file": allowed = ["action", "path"]
    case "click-link": allowed = ["action", "at"]
    default: throw Failure(message: "unknown note action")
    }
    guard Set(args.keys).isSubset(of: allowed) else { throw Failure(message: "unknown note argument") }
    if action == "export" || action == "export-state" {
      // The same export as Help ▸ Export Notes… after its save panel.
      if action == "export" {
        guard let path = args["path"] as? String, path.hasSuffix(".zip") else { throw Failure(message: "path must end in .zip") }
        NoteExporter.export(app: app, to: URL(fileURLWithPath: path))
      }
      var result: [String: Any] = ["running": NoteExporter.running]
      switch NoteExporter.last {
      case nil: result["last"] = ""
      case .none?: result["last"] = "none"
      case .exported(let count, let url)?: result["last"] = "exported"; result["count"] = count; result["path"] = url.path
      case .failed(let reason)?: result["last"] = "failed"; result["reason"] = reason
      }
      return result
    }
    let factory = try window
    if action == "sheet" {
      // The window's sheet (Delete Note alert, Export Note… panel): its texts and buttons; press one.
      guard let sheet = factory.window?.attachedSheet else { return ["shown": false] }
      func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
      let views = sheet.contentView.map(walk) ?? []
      let buttons = views.compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty && !$0.isHidden }
      if let title = args["press"] as? String {
        guard let button = buttons.first(where: { $0.title == title }) else { throw Failure(message: "no sheet button \(title)") }
        button.performClick(nil); return ["shown": true, "pressed": title]
      }
      if args["cancel"] as? Bool == true { factory.window?.endSheet(sheet, returnCode: .cancel); return ["shown": false] }
      return ["shown": true, "isSavePanel": sheet is NSSavePanel, "message": (sheet as? NSSavePanel)?.message ?? "",
              "name": (sheet as? NSSavePanel)?.nameFieldStringValue ?? "",
              "texts": views.compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty },
              "buttons": buttons.map(\.title)]
    }
    if ["row-menu", "rename", "export-one"].contains(action) {
      guard let raw = args["tab"] as? String, let uuid = UUID(uuidString: raw), let tab = factory.model.tab(id: ItemID(rawValue: uuid)),
        NoteTab.matches(tab.url) else { throw Failure(message: "not a Note row") }
      switch action {
      case "row-menu":
        guard let menu = factory.controller?.sidebar.contextMenu(nodeID: tab.id) else { throw Failure(message: "no row menu") }
        return ["items": menu.items.map { $0.isSeparatorItem ? "—" : ($0.submenu != nil ? $0.title + " ▸" : $0.title) },
                "enabled": menu.items.filter { !$0.isSeparatorItem }.map { [$0.title, $0.isEnabled] as [Any] }]
      case "rename":
        // The intent the row's inline rename sends when it commits.
        guard let text = args["text"] as? String, factory.performSidebar(.rename(nodeID: tab.id, title: text)) == true else { throw Failure(message: "rename refused") }
      default:
        guard let path = args["path"] as? String, factory.exportNote(tabID: tab.id, to: URL(fileURLWithPath: path)) else { throw Failure(message: "export refused") }
        return ["path": factory.lastNoteExport as Any? ?? NSNull()]
      }
    }
    if action == "import-zip" {
      // The same import as the command-bar action after its open panel.
      guard let path = args["path"] as? String else { throw Failure(message: "missing path") }
      let o = NoteImporter.importZip(URL(fileURLWithPath: path), factory: factory)
      return ["filled": o.filled, "added": o.added, "alreadyPresent": o.alreadyPresent, "unreadable": o.unreadable,
              "droppedImages": o.droppedImages, "error": o.error ?? ""]
    }
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
    case "select", "press", "gutter", "paste-file", "click-link":
      guard let tab = factory.selectedTab, let host = factory.noteHosts[tab.id], let window = host.editor.window else {
        throw Failure(message: "the selected tab is not a shown Note")
      }
      let editor = host.editor
      switch action {
      case "select":
        guard let start = args["start"] as? Int, let length = args["length"] as? Int, start >= 0, length >= 0,
          start + length <= (editor.bodyView.string as NSString).length else { throw Failure(message: "range outside the body") }
        window.makeFirstResponder(editor.bodyView)
        editor.bodyView.setSelectedRange(NSRange(location: start, length: length))
        editor.layoutSubtreeIfNeeded(); editor.updateChrome()
      case "press":
        // The real button: target/action of the visible format bar.
        guard let item = args["item"] as? String, !editor.formatBar.isHidden,
          let button = editor.formatBar.buttons.first(where: { $0.name == item }) else { throw Failure(message: "format bar hidden or unknown item") }
        button.performClick(nil)
      case "gutter":
        // The menu the visible "+" pops, item by title.
        guard let item = args["item"] as? String, !editor.gutterButton.isHidden else { throw Failure(message: "gutter hidden") }
        let menu = editor.gutterMenu()
        guard let index = menu.items.firstIndex(where: { $0.title == item }) else { throw Failure(message: "unknown gutter item") }
        menu.performActionForItem(at: index)
      case "paste-file":
        // AppKit's paste path with a file URL on a private pasteboard (also the drop path).
        guard let path = args["path"] as? String else { throw Failure(message: "missing path") }
        window.makeFirstResponder(editor.bodyView)
        let board = NSPasteboard(name: NSPasteboard.Name("open.automation.note-paste"))
        board.clearContents(); board.writeObjects([URL(fileURLWithPath: path) as NSURL])
        _ = editor.bodyView.readSelection(from: board, type: .fileURL)
        board.releaseGlobally()
      default:
        guard let at = args["at"] as? Int, let storage = editor.bodyView.textStorage, at >= 0, at < storage.length,
          let link = storage.attribute(.link, at: at, effectiveRange: nil) else { throw Failure(message: "no link there") }
        editor.bodyView.clicked(onLink: link, at: at)
      }
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
      "background": Self.hex(host?.editor.layer?.backgroundColor),
      "editable": host.map { $0.editor.titleView.isEditable && $0.editor.bodyView.isEditable } ?? false,
      "unreadable": host?.unreadable ?? false,
      "formats": host.map { Self.formatRows(NoteRichText.formats(of: $0.editor.bodyView.attributedString())) } ?? [],
      "storedFormats": noteID.flatMap { id in (try? Data(contentsOf: app.notes.fileURL(for: id))).flatMap {
        (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["formats"] } } ?? [],
      "selection": host.map { [$0.editor.bodyView.selectedRange().location, $0.editor.bodyView.selectedRange().length] } ?? [],
      "typingBlock": host.flatMap { $0.editor.bodyView.typingAttributes[.noteBlock] as? String } ?? "",
      "formatBar": host.map { Self.barState($0.editor) } ?? [:],
      "gutterVisible": host.map { !$0.editor.gutterButton.isHidden } ?? false,
      "images": host.map { Self.imageCount($0.editor) } ?? 0,
      "imageError": host?.editor.lastImageError ?? "",
      "importPlaceholder": noteID.flatMap { app.notes.load($0)?.importPlaceholder } ?? false,
      "assets": noteID.map { (try? FileManager.default.contentsOfDirectory(atPath: app.notes.assetDirectory(for: $0).path))?.count ?? 0 } ?? 0,
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
