#if OPEN_AUTOMATION
import AppKit
import OpenModel
import OpenSpaceEditor

extension AutomationController {
  func runEditorCommand(_ cmd: String, _ a: [String: Any]) throws -> Any {
    let w = try window
    switch cmd {
    case "editor-open":
      guard a["kind"] as? String == "icon" else { throw Failure(message: "editor kind not available") }
      if let value = a["node"] as? String, let uuid = UUID(uuidString: value) {
        return w.openNodeIconPicker(ItemID(rawValue: uuid))
      }
      let space = (a["space"] as? String).flatMap(UUID.init(uuidString:)).map { SpaceID(rawValue: $0) } ?? w.focusedSpace?.id
      return space.map { w.openSpaceIconPicker($0) } ?? false
    case "editor-close": w.iconPicker?.close(); return true
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
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: toneWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
          NSApp.sendEvent(event)
        }
        return true
      }
      guard a["action"] as? String == "click", let control = a["control"] as? String,
            let frame = picker.view.controlFrame(control, index: a["index"] as? Int ?? 0) else { throw Failure(message: "invalid picker control") }
      let point = picker.view.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: (a["modifiers"] as? [String] ?? []).contains("ctrl") ? .control : [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return false }
        NSApp.sendEvent(event)
      }
      return true
    default: throw Failure(message: "unknown editor command")
    }
  }
}
#endif
