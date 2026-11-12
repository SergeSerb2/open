#if OPEN_AUTOMATION
import AppKit
import OpenEasel
import OpenModel

/// `easel` socket command. Every edit goes through the real views: mouse and key events are
/// built as NSEvents and dispatched by the window (`sendEvent`), toolbar buttons are pressed,
/// and typing uses the text view's own insertion path. Coordinates are document points.
extension AutomationController {
  func easel(_ args: [String: Any]) throws -> Any {
    let action = args["action"] as? String ?? "state"
    let factory = try window
    if action == "create" {
      guard let id = EaselTab.create(in: factory) else { throw Failure(message: "New Easel refused") }
      return ["tab": id.description]
    }
    if action == "pasteboard" {
      // Puts test data on the general pasteboard, as another app's copy would.
      let pb = NSPasteboard.general
      pb.clearContents()
      if let path = args["file"] as? String { pb.writeObjects([URL(fileURLWithPath: path) as NSURL]) }
      else if let path = args["imageData"] as? String, let data = FileManager.default.contents(atPath: path) { pb.setData(data, forType: .png) }
      else if let raw = args["url"] as? String, let url = URL(string: raw) { pb.writeObjects([url as NSURL]); pb.setString(raw, forType: .string) }
      else if let text = args["text"] as? String { pb.setString(text, forType: .string) }
      else { throw Failure(message: "pasteboard needs file, imageData, url or text") }
      return true
    }
    if action == "capture-menu" {
      // The Capture card's Add to Easel menu: its rows, or a row run as a click would.
      guard let result = factory.controller?.capture.lastResult, factory.controller?.capture.card != nil else {
        throw Failure(message: "no capture card")
      }
      let menu = factory.addToEaselMenu(result)
      guard let title = args["item"] as? String else { return menu.items.map { $0.isSeparatorItem ? "—" : $0.title } }
      guard let index = menu.items.firstIndex(where: { $0.title == title }) else { throw Failure(message: "no such row") }
      menu.performActionForItem(at: index)
      return ["selected": factory.selectedTab?.id.description ?? ""]
    }
    if action == "store" {
      // Disk state of one document (after an explicit flush), without a canvas.
      guard let raw = args["document"] as? String, let id = UUID(uuidString: raw) else { throw Failure(message: "document id needed") }
      app.easels.flush()
      let url = app.easels.fileURL(for: id)
      guard let data = try? Data(contentsOf: url) else { return ["exists": false, "path": url.path] }
      return ["exists": true, "path": url.path, "json": (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()]
    }
    let tab: Tab
    if args["tab"] != nil { tab = try easelModelTab(args, factory) }
    else {
      guard let selected = factory.selectedTab, EaselTab.matches(selected.url) else { throw Failure(message: "selected tab is not an Easel") }
      tab = selected
    }
    guard let documentID = EaselTab.documentID(tab.url) else { throw Failure(message: "not an Easel tab") }
    if action == "state" { return easelState(tab: tab, documentID: documentID, factory: factory) }
    guard let host = factory.easelHosts[tab.id], !host.closed, host.canvas.window != nil else {
      throw Failure(message: "Easel is not shown")
    }
    let canvas = host.canvas
    func point(_ key: String) throws -> CGPoint {
      guard let v = args[key] as? [Double], v.count == 2 else { throw Failure(message: "\(key) must be [x, y]") }
      return CGPoint(x: v[0], y: v[1])
    }
    func flags() -> NSEvent.ModifierFlags {
      var f: NSEvent.ModifierFlags = []
      for m in args["modifiers"] as? [String] ?? [] {
        switch m { case "shift": f.insert(.shift); case "cmd": f.insert(.command); case "option": f.insert(.option); case "ctrl": f.insert(.control); default: break }
      }
      return f
    }
    switch action {
    case "tool":
      guard let raw = args["tool"] as? String, let tool = EaselTool(rawValue: raw),
            let button = canvas.toolbarButton(tool) else { throw Failure(message: "unknown tool") }
      _ = button.accessibilityPerformPress()
    case "add-button": _ = canvas.addButton.accessibilityPerformPress()
    case "image-panel":
      // The Image tool's open panel: report it, then cancel it (never chooses a file).
      guard let panel = host.openPanel else { return ["shown": false] }
      let message = panel.message ?? ""
      if args["cancel"] as? Bool ?? true { canvas.window?.endSheet(panel, returnCode: .cancel) }
      return ["shown": true, "message": message, "sheet": canvas.window?.attachedSheet === panel || !(args["cancel"] as? Bool ?? true)]
    case "drag":
      let from = try point("from"), to = try point("to")
      let steps = max(1, args["steps"] as? Int ?? 8)
      try easelMouse(.leftMouseDown, at: canvas.windowPoint(forDocument: from), canvas: canvas, flags: flags())
      for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        var p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        if args["wave"] as? Bool == true { p.y += sin(t * .pi * 4) * 30 }
        try easelMouse(.leftMouseDragged, at: canvas.windowPoint(forDocument: p), canvas: canvas, flags: flags())
      }
      try easelMouse(.leftMouseUp, at: canvas.windowPoint(forDocument: to), canvas: canvas, flags: flags())
    case "click":
      let at = try point("at")
      let count = args["count"] as? Int ?? 1
      for n in 1...max(1, count) {
        try easelMouse(.leftMouseDown, at: canvas.windowPoint(forDocument: at), canvas: canvas, flags: flags(), clickCount: n)
        try easelMouse(.leftMouseUp, at: canvas.windowPoint(forDocument: at), canvas: canvas, flags: flags(), clickCount: n)
      }
    case "swatch":
      guard let raw = args["color"] as? String, let color = EaselColor(rawValue: raw) else { throw Failure(message: "unknown color") }
      guard let p = canvas.swatchCenter(color) else { throw Failure(message: "colour popover is not shown") }
      try easelMouse(.leftMouseDown, at: p, canvas: canvas, flags: [])
      try easelMouse(.leftMouseUp, at: p, canvas: canvas, flags: [])
    case "menu":
      let at = try point("at")
      guard let title = args["item"] as? String else { return canvas.contextMenuTitles(atDocument: at) }
      guard canvas.performContextMenu(atDocument: at, title: title, submenu: args["submenu"] as? String) else {
        throw Failure(message: "menu item missing or disabled")
      }
    case "key":
      guard let window = canvas.window, let key = args["key"] as? String else { throw Failure(message: "key needed") }
      let codes: [String: (UInt16, String)] = ["delete": (51, "\u{7F}"), "escape": (53, "\u{1B}"), "return": (36, "\r"),
        "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}")]
      let (code, chars) = codes[key] ?? (0, key)
      if !canvas.isEditingText, window.firstResponder !== canvas.documentView { window.makeFirstResponder(canvas.documentView) }
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags(), timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
        window.sendEvent(event)
      }
    case "type":
      guard let text = args["text"] as? String, let editor = canvas.editorTextView else { throw Failure(message: "no text editor") }
      for character in text { editor.insertText(String(character), replacementRange: editor.selectedRange()) }
    case "size":
      guard let which = args["button"] as? String, let button = canvas.editorSizeButton(which) as? NSButton else {
        throw Failure(message: "no size control")
      }
      button.performClick(nil)
    case "title":
      guard let text = args["text"] as? String, let window = canvas.window else { throw Failure(message: "text needed") }
      window.makeFirstResponder(canvas.titleView)
      guard let editor = canvas.titleView.currentEditor() as? NSTextView else { throw Failure(message: "title not editable") }
      editor.selectAll(nil)
      editor.insertText(text, replacementRange: editor.selectedRange())
      if args["commit"] as? Bool ?? true { window.makeFirstResponder(canvas.documentView) }
    case "undo", "redo":
      guard let window = canvas.window else { throw Failure(message: "no window") }
      if !canvas.isEditingText { window.makeFirstResponder(canvas.documentView) }
      // The Edit menu's action, sent down the responder chain like the menu item.
      NSApp.sendAction(Selector((action + ":")), to: nil, from: nil)
    case "edit":
      // Edit-menu actions through the responder chain: copy, cut, paste, delete, selectAll, duplicate.
      guard let name = args["op"] as? String, ["copy", "cut", "paste", "delete", "selectAll", "duplicate"].contains(name),
            let window = canvas.window else { throw Failure(message: "unknown edit op") }
      window.makeFirstResponder(canvas.documentView)
      guard NSApp.sendAction(Selector((name + ":")), to: nil, from: nil) else { throw Failure(message: "edit op not handled") }
    case "sheet":
      // The canvas's alert sheet (live-card question): its text, or a button pressed as a click would.
      guard let sheet = canvas.window?.attachedSheet, let alert = NSApp.windows.compactMap({ $0 }).first(where: { $0 === sheet }),
            let content = alert.contentView else { return ["shown": false] }
      func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
      func labels(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels) }
      let all = buttons(content).filter { !$0.title.isEmpty }
      if let press = args["press"] as? String {
        guard let button = all.first(where: { $0.title == press }) else { throw Failure(message: "no such button") }
        button.performClick(nil)
        return ["pressed": press]
      }
      return ["shown": true, "buttons": all.map(\.title), "texts": labels(content).filter { !$0.isEmpty }]
    case "flush": app.easels.flush()
    default: throw Failure(message: "unknown easel action")
    }
    canvas.layoutSubtreeIfNeeded()
    return easelState(tab: tab, documentID: documentID, factory: factory)
  }

  private func easelModelTab(_ a: [String: Any], _ w: EngineWebContentHostFactory) throws -> Tab {
    guard let s = a["tab"] as? String, let uuid = UUID(uuidString: s), let tab = w.model.tab(id: ItemID(rawValue: uuid)) else {
      throw Failure(message: "no tab")
    }
    return tab
  }

  private func easelMouse(_ type: NSEvent.EventType, at windowPoint: CGPoint, canvas: EaselCanvasView,
                          flags: NSEvent.ModifierFlags, clickCount: Int = 1) throws {
    guard let window = canvas.window, let event = NSEvent.mouseEvent(
      with: type, location: windowPoint, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)
    else { throw Failure(message: "could not build mouse event") }
    window.sendEvent(event)
  }

  private func easelState(tab: Tab, documentID: UUID, factory: EngineWebContentHostFactory) -> [String: Any] {
    var state: [String: Any] = ["tab": tab.id.description, "document": documentID.uuidString.lowercased(),
      "url": tab.url.absoluteString, "tabTitle": tab.title, "selected": factory.selectedTab?.id == tab.id,
      "favicon": tab.live.faviconPNG != nil, "hostCount": factory.easelHosts.count,
      "engineContentCreationCount": factory.contentCreationCount,
      "fileExists": FileManager.default.fileExists(atPath: app.easels.fileURL(for: documentID).path),
      "storeWrites": app.easels.writeCount, "livePages": factory.easelHosts[tab.id]?.livePages.count ?? 0,
      "livePagesMade": factory.easelHosts[tab.id]?.livePagesMade ?? 0, "pendingLinks": factory.easelHosts[tab.id]?.pendingLinks ?? 0,
      "imageFiles": (try? FileManager.default.contentsOfDirectory(atPath: app.easels.imagesDirectory(for: documentID).path))?.sorted() ?? []]
    if let host = factory.easelHosts[tab.id], !host.closed {
      state["shown"] = host.canvas.window != nil && !host.canvas.isHiddenOrHasHiddenAncestor
      state["canvas"] = host.canvas.state()
      state["recreated"] = host.recreated
      if let window = host.canvas.window {
        state["firstResponder"] = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        state["canvasFrame"] = { let f = host.canvas.convert(host.canvas.bounds, to: nil); return [f.minX, f.minY, f.width, f.height] }()
      }
    } else { state["shown"] = false }
    return state
  }
}
#endif
