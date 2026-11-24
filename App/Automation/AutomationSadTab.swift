#if OPEN_AUTOMATION
import AppKit
import OpenFeatures
import OpenModel

extension AutomationController {
  /// Inspect the actual replacement view, focus it, or invoke its AppKit buttons.
  /// Never synthesizes a crash state.
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
      case "focus":
        guard view.window?.makeFirstResponder(view) == true else { throw Failure(message: "Sad Tab could not take focus") }
      default: throw Failure(message: "action must be reload, close, or focus")
      }
      return true
    }
    guard let view else { return ["shown": false] }
    controller.contentView.layoutSubtreeIfNeeded()
    let responder = view.window?.firstResponder as? NSView
    return ["shown": view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor,
      "focused": responder.map { $0 === view || $0.isDescendant(of: view) } ?? false,
      "label": view.accessibilityLabel() ?? "",
      "id": view.accessibilityIdentifier(), "default": view.reloadButton.keyEquivalent == "\r",
      "buttons": [view.reloadButton, view.closeButton].map {
        // Frame in window points from the top-left, for pixel checks of the button's label.
        let r = controller.contentView.convert($0.bounds, from: $0)
        return ["id": $0.accessibilityIdentifier(), "label": $0.accessibilityLabel() ?? "", "enabled": $0.isEnabled,
                "frame": [r.minX, controller.contentView.isFlipped ? r.minY : controller.contentView.bounds.height - r.maxY, r.width, r.height],
                "appearance": $0.effectiveAppearance.name.rawValue] as [String: Any]
      }] as [String: Any]
  }
}
#endif
