#if OPEN_AUTOMATION
import AppKit
import OpenFeatures
import OpenModel

extension AutomationController {
  /// Inspect the actual replacement view and invoke its AppKit buttons; no synthetic crash state.
  func runSadTabCommand(_ cmd: String, _ args: [String: Any]) throws -> Any {
    guard let controller = try window.controller else { throw Failure(message: "no browser window") }
    let view: SadTabView?
    if args["peek"] as? Bool == true {
      view = controller.hasPeekController && controller.peekController.isShown ? controller.peekController.overlay.sadTabView : nil
    } else {
      guard let raw = args["tab"] as? String, let uuid = UUID(uuidString: raw) else { throw Failure(message: "missing tab ID") }
      view = controller.container.slots.first { $0.tabID == ItemID(rawValue: uuid) }?.sadTabView
    }
    if cmd == "sad-tab-action" {
      guard let view, !view.isHiddenOrHasHiddenAncestor, view.window?.isVisible == true else { throw Failure(message: "no shown Sad Tab") }
      switch args["action"] as? String {
      case "reload": view.reloadButton.performClick(nil)
      case "close": view.closeButton.performClick(nil)
      default: throw Failure(message: "action must be reload or close")
      }
      return true
    }
    guard let view else { return ["shown": false] }
    controller.contentView.layoutSubtreeIfNeeded()
    return ["shown": view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor,
      "id": view.accessibilityIdentifier(), "default": view.reloadButton.keyEquivalent == "\r",
      "buttons": [view.reloadButton, view.closeButton].map {
        ["id": $0.accessibilityIdentifier(), "label": $0.accessibilityLabel() ?? "", "enabled": $0.isEnabled] as [String: Any]
      }] as [String: Any]
  }
}
#endif
