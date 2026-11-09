#if OPEN_AUTOMATION
import AppKit
import OpenModel

extension AutomationController {
  func littleOpenDownloads(_ args: [String: Any]) throws -> Any {
    guard let id = args["id"] as? String, let uuid = UUID(uuidString: id) else { throw Failure(message: "invalid Little Open session") }
    let sessionID = WindowID(rawValue: uuid)
    let controller = app.littleOpenCoordinator.controllers[sessionID]
    let center = app.downloadsCenter
    let tray = center.littleOpenTrays[sessionID]
    let action = args["action"] as? String
    if let action, controller == nil { throw Failure(message: "unknown Little Open session for " + action) }
    switch action {
    case "arm-early-move":
      guard let controller, controller.pillSpaceID != nil, !center.holdProgressForAutomation else {
        throw Failure(message: "early-move boundary unavailable")
      }
      center.holdProgressForAutomation = true
      center.afterDestinationForAutomation = { [weak center, weak controller, weak app] _ in
        guard let center else { return }
        defer { center.releaseProgressForAutomation() }
        if let controller, let space = controller.pillSpaceID {
          app?.littleOpenCoordinator.moveToSpace(sessionID: controller.session.id, spaceID: space)
        }
      }
    case "toggle":
      guard let controller, !controller.titleBar.downloadsButton.isHidden else { throw Failure(message: "Downloads button is hidden") }
      controller.titleBar.downloadsButton.performClick(nil)
    case "close": tray?.close()
    case "escape", "key":
      guard tray?.popover?.isShown == true, let controller else { throw Failure(message: "Downloads popover is not visible") }
      let name = action == "escape" ? "Escape" : args["key"] as? String ?? ""
      let key: (String, UInt16, NSEvent.ModifierFlags)
      switch name {
      case "Escape": key = ("\u{1b}", 53, [])
      case "Return": key = ("\r", 36, [])
      case "Cmd+W": key = ("w", 13, .command)
      default: throw Failure(message: "expected Escape, Return or Cmd+W")
      }
      let target = args["target"] as? String == "parent" ? controller.window : tray?.viewIfLoaded?.window
      guard let target else { throw Failure(message: "download key target is unavailable") }
      // Keep the popover key. Parent-targeted events take OEApplication ->
      // LittleOpenNativeWindow -> handleLittleOpenKey -> the tray key handler.
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.2,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
          context: nil, characters: key.0, charactersIgnoringModifiers: key.0,
          isARepeat: false, keyCode: key.1) else { continue }
        NSApp.sendEvent(event)
      }
    case "move": controller?.titleBar.pillButton.performClick(nil)
    case "row":
      guard let key = args["download"] as? String, let title = args["button"] as? String,
        tray?.popover?.isShown == true,
        let button = tray?.rows.first(where: { $0.item.id == key })?.buttons.first(where: { $0.identifier?.rawValue == title }),
        button.isEnabled else { throw Failure(message: "tray download button is unavailable") }
      button.performClick(nil)
    case nil: break
    default: throw Failure(message: "unknown downloads tray action")
    }
    // Close preparation can remove this tray during a key or move.
    let current = center.littleOpenTrays[sessionID]
    let live = app.littleOpenCoordinator.controllers[sessionID]
    let responder = live?.window?.firstResponder as? NSView
    return ["exists": live != nil, "trayExists": current != nil,
      "buttonVisible": live.map { !$0.titleBar.downloadsButton.isHidden } ?? false,
      "label": live?.titleBar.downloadsButton.accessibilityLabel() ?? "",
      "value": live?.titleBar.downloadsButton.accessibilityValue() as Any? ?? NSNull(),
      "progress": live?.titleBar.downloadsButton.progress as Any? ?? NSNull(),
      "running": live?.titleBar.downloadsButton.running ?? false,
      "shown": current?.popover?.isShown == true, "window": current?.viewIfLoaded?.window?.windowNumber ?? 0,
      "popoverKey": current?.viewIfLoaded?.window?.isKeyWindow == true,
      "firstAction": (current?.viewIfLoaded?.window?.firstResponder as? NSButton)?.identifier?.rawValue ?? "",
      "parentKey": live?.window?.isKeyWindow == true,
      "parentFocusRestored": live.map { responder === $0.container || responder === $0.titleBar.downloadsButton || responder?.isDescendant(of: $0.container) == true } ?? false,
      "appearance": current?.viewIfLoaded?.effectiveAppearance.name.rawValue ?? "",
      "updates": current?.updateCount ?? 0, "handledKeys": current?.handledKeys ?? tray?.handledKeys ?? [],
      "axRowOrder": current?.accessibilityRowOrder ?? [],
      "items": current?.items.map { ["id": $0.id, "name": $0.fileName, "host": $0.sourceHost,
        "state": $0.state.rawValue, "received": $0.receivedBytes, "historical": $0.isHistorical] as [String: Any] } ?? [],
      "rows": current?.rows.map { row in
        ["id": row.item.id, "status": row.status.stringValue, "icon": row.icon.image != nil,
         "label": row.accessibilityLabel() ?? "",
         "axChildren": (row.accessibilityChildren() ?? []).compactMap { child -> [String: Any]? in
           guard let view = child as? NSView else { return nil }
           return ["role": view.accessibilityRole()?.rawValue ?? "", "label": view.accessibilityLabel() ?? "",
             "name": view.identifier?.rawValue ?? ""]
         },
         "buttons": row.buttons.map { ["name": $0.identifier?.rawValue ?? "", "label": $0.accessibilityLabel() ?? "", "enabled": $0.isEnabled] as [String: Any] }] as [String: Any]
      } ?? []] as [String: Any]
  }
}
#endif
