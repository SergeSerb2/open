#if OPEN_AUTOMATION
import AppKit
import OpenFeatures
import OpenEngine
import OpenModel

/// Reads the real Peek views and operates their buttons/menu through AppKit.
/// No desktop input and no alternate implementation of Peek policy.
extension AutomationController {
  private static var peekMoveObserver: NSObjectProtocol?
  private static weak var peekMoveController: BrowserWindowController?
  private static var peekMoveMenu: NSMenu?
  private static var peekMoveIndex = 0
  private static var peekMoveReceipt: [String: Any] = [:]

  func runPeekAppCommand(_ cmd: String, _ a: [String: Any]) throws -> Any {
    let factory = try window
    guard let controller = factory.controller else { throw Failure(message: "no browser window") }
    switch cmd {
    case "peek-ui":
      controller.contentView.layoutSubtreeIfNeeded()
      let visible = app.media.visibility.sleepVisibility().visibleTabIDs(in: app.model).map(\.description).sorted()
      guard controller.hasPeekController else { return ["shown": false, "visible": visible] as [String: Any] }
      let peek = controller.peekController, overlay = peek.overlay, root = controller.contentView
      func rect(_ view: NSView) -> [Double] {
        let f = root.convert(view.bounds, from: view)
        return [f.minX, f.minY, f.width, f.height]
      }
      return ["shown": peek.isShown, "panel": rect(overlay.panel), "content": [overlay.contentRect.minX, overlay.contentRect.minY, overlay.contentRect.width, overlay.contentRect.height],
        "baseWidth": overlay.baseWidth, "dimHidden": overlay.backdrop.isHidden, "dimAlpha": overlay.backdrop.alphaValue,
        "buttons": overlay.buttons.map { ["id": $0.identifier?.rawValue ?? "", "frame": rect($0)] as [String: Any] },
        "badges": controller.context.peekBadges.keys.map(\.description).sorted(),
        "sourceRow": controller.context.peekSourceNodeID?.description ?? "",
        "hostHidden": peek.stack.last?.host?.view.isHiddenOrHasHiddenAncestor ?? true,
        "visible": visible, "maximized": controller.container.maximizedTabID?.description ?? ""] as [String: Any]
    case "peek-button":
      guard controller.hasPeekController, controller.peekController.isShown,
        let id = a["id"] as? String,
        let button = controller.peekController.overlay.buttons.first(where: { $0.identifier?.rawValue == id })
      else { throw Failure(message: "no shown Peek button") }
      button.performClick(nil); return true
    case "peek-move-arm":
      if let token = Self.peekMoveObserver { NotificationCenter.default.removeObserver(token) }
      guard let id = a["space"] as? String, let chosenIndex = app.model.spaces.firstIndex(where: { $0.id.description == id }) else { throw Failure(message: "unknown Space") }
      Self.peekMoveController = controller; Self.peekMoveIndex = chosenIndex
      Self.peekMoveReceipt = ["tracked": false, "chosen": false]
      Self.peekMoveObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
        let menuID = (note.object as? NSMenu).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
          guard let controller = Self.peekMoveController, let menu = controller.pendingMoveMenu, menuID == ObjectIdentifier(menu) else { return }
          Self.peekMoveReceipt["tracked"] = true
          Self.peekMoveMenu = menu
          RunLoop.main.perform(inModes: [.eventTracking, .modalPanel, .default]) {
            MainActor.assumeIsolated {
              Self.peekMoveMenu?.cancelTrackingWithoutAnimation()
              DispatchQueue.main.async {
                Self.peekMoveMenu?.performActionForItem(at: Self.peekMoveIndex)
                Self.peekMoveMenu = nil
                Self.peekMoveReceipt["chosen"] = true
              }
            }
          }
          if let token = Self.peekMoveObserver { NotificationCenter.default.removeObserver(token) }
          Self.peekMoveObserver = nil
        }
      }
      return true
    case "peek-move-state": return Self.peekMoveReceipt
    default: throw Failure(message: "unknown Peek command")
    }
  }
}
#endif
