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
    case "peek-motion-trace":
      switch a["action"] as? String ?? "read" {
      case "arm":
        PeekMotionTrace.arm()
        PeekMotionTrace.watch(controller.contentView)
      case "stop": PeekMotionTrace.stop()
      case "mark":
        guard let name = a["name"] as? String, name.utf8.count <= 64 else { throw Failure(message: "trace name limit") }
        PeekMotionTrace.mark(name)
      case "read": break
      default: throw Failure(message: "unknown trace action")
      }
      return PeekMotionTrace.json()
    case "peek-motion":
      guard controller.hasPeekController else { return ["shown": false] }
      let peek = controller.peekController, overlay = peek.overlay
      func rect(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
      func motion(_ layer: CALayer?) -> [String: Any] {
        guard let layer else { return [:] }
        let displayed = layer.presentation() ?? layer
        return ["frame": rect(layer.frame), "presentation": rect(displayed.frame),
          "opacity": displayed.opacity, "scale": [displayed.transform.m11, displayed.transform.m22],
          "rasterized": layer.shouldRasterize, "rasterScale": layer.rasterizationScale,
          "animations": (layer.animationKeys() ?? []).map { key in
            let animation = layer.animation(forKey: key)
            let paths = (animation as? CAAnimationGroup)?.animations?.compactMap { ($0 as? CAPropertyAnimation)?.keyPath }
              ?? (animation as? CAPropertyAnimation).map { [$0.keyPath ?? ""] } ?? []
            return ["key": key, "duration": animation?.duration ?? 0,
              "requestedHz": animation?.preferredFrameRateRange.preferred ?? 0, "paths": paths] as [String: Any]
          }]
      }
      return ["shown": peek.isShown, "expanding": peek.isExpanding, "kind": overlay.motionKind,
        "overlayHidden": overlay.isHidden, "backdropHidden": overlay.backdrop.isHidden,
        "snapshot": overlay.hasMotionSnapshot,
        "snapshotPixels": overlay.hasSnapshotPixels, "preparingOpening": peek.isPreparingOpening,
        "openingHandoff": overlay.isOpeningHandoff, "contentFading": overlay.isOpeningContentFading, "promotionHandoff": peek.isPromotionHandoff,
        "expandedImage": overlay.hasExpansionImage,
        "expandedImageFrame": overlay.expandedImageFrame.map(rect) ?? [],
        "expandedImageScale": overlay.expandedImageScale ?? 0,
        "expandedImagePixels": overlay.expandedImagePixels.map { [$0.width, $0.height] } ?? [],
        "hostHidden": peek.stack.last?.host?.view.isHiddenOrHasHiddenAncestor ?? true,
        "hostAttached": peek.stack.last?.host?.view.window != nil,
        "backingScale": overlay.window?.backingScaleFactor ?? 1,
        "displayHz": overlay.window?.screen?.maximumFramesPerSecond ?? 60,
        "duration": overlay.motionDuration, "startedAt": overlay.motionStartedAt,
        "layouts": overlay.layoutCount, "hostFrameChanges": overlay.hostFrameChangeCount,
        "panelFrame": rect(overlay.panel.frame), "clipFrame": rect(overlay.pageClip.frame),
        "hostFrame": peek.stack.last?.host.map { rect($0.view.frame) } ?? [],
        "panel": motion(overlay.motionPanelLayer), "overlay": motion(overlay.layer), "backdrop": motion(overlay.backdrop.layer)] as [String: Any]
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
