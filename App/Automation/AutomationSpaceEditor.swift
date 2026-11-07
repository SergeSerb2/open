#if OPEN_AUTOMATION
import AppKit
import OpenDesign
import OpenModel
import OpenSpaceEditor

extension AutomationController {
  /// The kind switch is shared by the theme, icon and creation flows.
  func runEditorCommand(_ cmd: String, _ args: [String: Any]) async throws -> Any {
    let factory = try window
    guard let owner = factory.controller else { throw Failure(message: "no browser window") }
    func targetSpace() throws -> Space {
      if let raw = args["space"] as? String {
        guard let space = app.model.spaces.first(where: { $0.id.description == raw }) else { throw Failure(message: "unknown Space") }
        return space
      }
      guard let space = factory.focusedSpace else { throw Failure(message: "no focused Space") }
      return space
    }
    func hex(_ color: RGBA) -> String {
      let c = color.nsColor.usingColorSpace(.sRGB)!
      return String(format: "#%02X%02X%02X", Int((min(1, max(0, c.redComponent)) * 255).rounded()),
        Int((min(1, max(0, c.greenComponent)) * 255).rounded()), Int((min(1, max(0, c.blueComponent)) * 255).rounded()))
    }
    func palette(_ p: SemanticPalette?) -> [String: String] {
      guard let p else { return [:] }
      return ["background": hex(p.background), "backgroundExtra": hex(p.backgroundExtra), "title": hex(p.title),
        "subtitle": hex(p.subtitle), "hover": hex(p.hover), "focus": hex(p.focus),
        "foregroundPrimary": hex(p.foregroundPrimary), "foregroundSecondary": hex(p.foregroundSecondary),
        "foregroundTertiary": hex(p.foregroundTertiary), "minContrast": hex(p.minContrast),
        "maxContrast": hex(p.maxContrast), "cutout": hex(p.cutout)]
    }
    switch cmd {
    case "creation-state": return try await runSpaceEditorCommand(cmd, args)
    case "theme-get":
      let space = try targetSpace()
      let style = SpaceThemeStyle(theme: space.theme, system: owner.context.systemAppearance)
      let encoded = try JSONEncoder().encode(space.theme.style)
      return ["style": try JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed),
        "contentAppearance": style.resolvedAppearance(system: owner.context.systemAppearance).rawValue,
        "palette": ["light": palette(style.lightPalette), "dark": palette(style.darkPalette)]] as [String: Any]
    case "theme-set":
      let space = try targetSpace()
      let value = args["style"] ?? NSNull()
      let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
      let style = try JSONDecoder().decode(SpaceStyle?.self, from: data)
      owner.closeThemeEditor()
      let session = ThemeEditSession(model: app.model, spaceID: space.id)
      let manager = app.model.undoManager
      manager?.beginUndoGrouping()
      session.preview(style, live: false)
      let changed = session.commit()
      manager?.setActionName("Update Theme"); manager?.endUndoGrouping(); session.close()
      if changed { app.scheduleSave() }
      return true
    case "editor-open":
      switch args["kind"] as? String ?? "theme" {
      case "create":
        owner.closeThemeEditor(); factory.iconPicker?.close()
        return try await runSpaceEditorCommand("creation-open", args)
      case "theme":
        factory.iconPicker?.close()
        if let creation = owner.spaceCreationController {
          creation.openThemeEditor(); return creation.themeEditor != nil
        }
        return owner.editSpaceTheme(try targetSpace().id)
      case "icon":
        owner.closeThemeEditor()
        if let value = args["node"] as? String, let uuid = UUID(uuidString: value) {
          return factory.openNodeIconPicker(ItemID(rawValue: uuid))
        }
        return factory.openSpaceIconPicker(try targetSpace().id)
      default: return false
      }
    case "editor-close":
      if let picker = factory.iconPicker { picker.close(); return true }
      if owner.themeEditor != nil { owner.closeThemeEditor(); return true }
      if owner.spaceCreationController != nil { return try await runSpaceEditorCommand("creation-close", args) }
      return true
    case "editor-state":
      if factory.iconPicker != nil { return try await runIconEditorCommand(cmd, args) }
      guard let editor = owner.spaceCreationController?.themeEditor ?? owner.themeEditor else {
        return ["open": false, "displayLinks": ThemeEditorController.activeDisplayLinkCount] as [String: Any]
      }
      let frame = editor.panel.frame
      return ["open": !editor.isClosed, "kind": "theme", "window": editor.panel.windowNumber,
        "frame": [frame.minX, frame.minY, frame.width, frame.height],
        "scale": editor.panel.backingScaleFactor, "ownerScale": owner.window?.backingScaleFactor ?? 0,
        "screens": NSScreen.screens.map { screen in
          ["frame": [screen.visibleFrame.minX, screen.visibleFrame.minY, screen.visibleFrame.width, screen.visibleFrame.height],
           "scale": screen.backingScaleFactor] as [String: Any]
        },
        "pendingFrame": editor.hasPendingFrame,
        "displayLinks": ThemeEditorController.activeDisplayLinkCount, "frames": editor.frameCount,
        "previews": editor.previewCount, "commits": editor.commitCount,
        "commitSequence": editor.session?.commitSequence ?? 0,
        "sessionPreviews": editor.session?.previewCount ?? 0,
        "commitPreviews": editor.session?.committedPreviewCount ?? 0,
        "committedStyle": try JSONSerialization.jsonObject(with: JSONEncoder().encode(editor.session?.lastCommittedTheme?.style), options: .fragmentsAllowed),
        "undoActionName": editor.panel.undoManager?.undoActionName ?? "",
        "controls": editor.panel.editorView.controlFrames.mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
        "style": try JSONSerialization.jsonObject(with: JSONEncoder().encode(editor.state.style), options: .fragmentsAllowed),
        "knob": editor.state.knob.map { [$0.x, $0.y] } ?? [],
        "space": editor.session?.spaceID.description ?? ""] as [String: Any]
    case "editor-act":
      if factory.iconPicker != nil { return try await runIconEditorCommand(cmd, args) }
      if owner.spaceCreationController != nil { return try await runSpaceEditorCommand("creation-act", args) }
      guard let editor = owner.themeEditor, !editor.isClosed else { return false }
      var eventArgs = args
      eventArgs["window"] = editor.panel.windowNumber
      switch args["action"] as? String {
      case "key": eventArgs["route"] = "app"; return try await sendKey(eventArgs, factory)
      case "click", "hover":
        if let control = args["control"] as? String {
          guard let rect = editor.panel.editorView.controlFrames[control] else { throw Failure(message: "unknown editor control") }
          // Control frames are in the body's coordinates, inside the 13pt band.
          eventArgs["x"] = rect.midX + 13; eventArgs["y"] = rect.midY + 13
        }
        return try await mouse(eventArgs, factory)
      case "drag" where args["from"] != nil:
        guard let start = args["from"] as? [Double], let end = args["to"] as? [Double],
          start.count == 2, end.count == 2, (start + end).allSatisfy(\.isFinite)
        else { throw Failure(message: "drag requires finite from/to points") }
        let steps = args["steps"] as? Int ?? 8
        guard (1...240).contains(steps) else { throw Failure(message: "steps must be 1...240") }
        _ = try await mouse(["window": editor.panel.windowNumber, "action": "down", "x": start[0], "y": start[1]], factory)
        for index in 1...steps {
          let t = Double(index) / Double(steps)
          _ = try await mouse(["window": editor.panel.windowNumber, "action": "drag",
            "x": start[0] + (end[0] - start[0]) * t, "y": start[1] + (end[1] - start[1]) * t], factory)
          try await Task.sleep(for: .milliseconds(9))
        }
        _ = try await mouse(["window": editor.panel.windowNumber, "action": "up", "x": end[0], "y": end[1]], factory)
        return true
      case "down", "drag", "up": return try await mouse(eventArgs, factory)
      default: throw Failure(message: "unknown editor action")
      }
    default: throw Failure(message: "unknown editor command")
    }
  }
  private func runIconEditorCommand(_ cmd: String, _ a: [String: Any]) async throws -> Any {
    let w = try window
    switch cmd {
    case "editor-state":
      guard let picker = w.iconPicker else { return ["open": false] }
      return ["open": !picker.isClosed, "kind": "icon", "page": picker.view.page == .emoji ? "emoji" : "icons",
              "count": picker.view.page == .emoji ? picker.view.visibleEntries.count : NamedSpaceIcons.order.count,
              "tones": picker.toneCount, "category": picker.view.highlightedCategory,
              "search": picker.view.search.stringValue, "remove": !picker.view.remove.isHidden,
              "frame": [picker.panel.frame.minX, picker.panel.frame.minY, picker.panel.frame.width, picker.panel.frame.height]] as [String: Any]
    case "editor-act":
      guard let picker = w.iconPicker, !picker.isClosed else { throw Failure(message: "no icon picker") }
      let panel = picker.panel
      if a["action"] as? String == "key" {
        let key = a["key"] as? String ?? ""
        let codes: [String: UInt16] = ["escape": 53, "return": 36, "left": 123, "right": 124, "down": 125, "up": 126]
        let chars = key == "escape" ? "\u{1B}" : key == "return" ? "\r" : key
        let flags: NSEvent.ModifierFlags = (a["modifiers"] as? [String] ?? []).contains("cmd") ? .command : []
        guard chars.count <= 128, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
          characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: codes[key] ?? 0) else { throw Failure(message: "invalid picker key") }
        NSApp.sendEvent(event); return true
      }
      if a["action"] as? String == "click", a["control"] as? String == "tone",
         let button = picker.toneButton(at: a["index"] as? Int ?? 0), let toneWindow = picker.toneWindow {
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        _ = try await mouse(["action": "click", "window": toneWindow.windowNumber, "x": Double(point.x),
                             "y": Double(toneWindow.frame.height - point.y), "queued": true], w)
        return true
      }
      guard a["action"] as? String == "click", let control = a["control"] as? String,
            let frame = picker.view.controlFrame(control, index: a["index"] as? Int ?? 0) else { throw Failure(message: "invalid picker control") }
      let point = picker.view.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
      // Reuse the native queue path and wait for mouse-up delivery. Native
      // controls can track synchronously; custom cells finish on mouse-up.
      _ = try await mouse(["action": "click", "window": panel.windowNumber, "x": Double(point.x),
                           "y": Double(panel.frame.height - point.y), "queued": true,
                           "modifiers": a["modifiers"] as? [String] ?? []], w)
      return true
    default: throw Failure(message: "unknown editor command")
    }
  }
}
#endif
