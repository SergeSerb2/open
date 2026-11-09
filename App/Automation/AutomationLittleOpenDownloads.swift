#if OPEN_AUTOMATION
import AppKit

extension AutomationController {
  func littleOpenDownloads(_ args: [String: Any]) throws -> Any {
    guard let id = args["id"] as? String,
      let controller = app.littleOpenCoordinator.controllers.values.first(where: { $0.session.id.description == id })
    else { throw Failure(message: "unknown Little Open session") }
    let tray = app.downloadsCenter.littleOpenTrays[controller.session.id]
    switch args["action"] as? String {
    case "toggle":
      guard !controller.titleBar.downloadsButton.isHidden else { throw Failure(message: "Downloads button is hidden") }
      controller.titleBar.downloadsButton.performClick(nil)
    case "close": tray?.close()
    case "escape":
      guard tray?.popover?.isShown == true, let window = tray?.viewIfLoaded?.window else {
        throw Failure(message: "Downloads popover is not visible")
      }
      // A transient NSPopover can report isKeyWindow while NSApp.keyWindow
      // still names its parent. Send the event to this process's actual
      // popover through OEApplication, without changing window activation.
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
          isARepeat: false, keyCode: 53) else { continue }
        NSApp.sendEvent(event)
      }
    case "row":
      guard let key = args["download"] as? String, let title = args["button"] as? String,
        tray?.popover?.isShown == true,
        let button = tray?.rows.first(where: { $0.item.id == key })?.buttons.first(where: { $0.identifier?.rawValue == title }),
        button.isEnabled else { throw Failure(message: "tray download button is unavailable") }
      button.performClick(nil)
    default: break
    }
    return ["buttonVisible": !controller.titleBar.downloadsButton.isHidden,
      "label": controller.titleBar.downloadsButton.accessibilityLabel() ?? "",
      "progress": controller.titleBar.downloadsButton.progress as Any? ?? NSNull(),
      "running": controller.titleBar.downloadsButton.running,
      "shown": tray?.popover?.isShown == true, "window": tray?.viewIfLoaded?.window?.windowNumber ?? 0,
      "items": tray?.items.map { ["id": $0.id, "name": $0.fileName, "host": $0.sourceHost,
        "state": $0.state.rawValue, "received": $0.receivedBytes, "historical": $0.isHistorical] as [String: Any] } ?? [],
      "rows": tray?.rows.map { ["id": $0.item.id, "status": $0.status.stringValue,
        "label": $0.accessibilityLabel() ?? "", "buttons": $0.buttons.map { ["name": $0.identifier?.rawValue ?? "", "label": $0.accessibilityLabel() ?? "", "enabled": $0.isEnabled] as [String: Any] }] as [String: Any] } ?? []] as [String: Any]
  }
}
#endif
