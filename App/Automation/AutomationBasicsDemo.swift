#if OPEN_AUTOMATION
import AppKit
import OpenModel
import OpenDesign

/// Recorder support for the basics clips (tools/basics). A sidebar drag cannot
/// start a WindowServer drag loop from the socket, so the recorder drives the
/// same drag-source state and NSDraggingDestination callbacks that AppKit
/// calls during a real drag, one pointer step at a time. Everything the clip
/// shows (drop line, folder target, split overlay, the drop itself) is the
/// app's own response. The recorder draws only the pointer and the drag image.
@MainActor
final class BasicsDemoDrag {
  let node: String
  weak var destination: NSView?
  init(node: String) { self.node = node }
}

extension AutomationController {
  func basicsDemo(_ a: [String: Any]) throws -> Any {
    let factory = try window
    guard let controller = factory.controller, let target = controller.window, let root = target.contentView?.superview else {
      throw Failure(message: "no browser window")
    }
    func windowPoint(_ value: Any?) throws -> NSPoint {
      guard let p = value as? [Double], p.count == 2, p.allSatisfy(\.isFinite) else { throw Failure(message: "point must be [x, y]") }
      return NSPoint(x: p[0], y: target.frame.height - p[1])
    }
    func info(_ point: NSPoint, _ node: String) -> SplitDraggingInfo {
      SplitDraggingInfo(window: target, source: controller.sidebar, point: point, node: node)
    }
    func destination(at point: NSPoint) -> NSView? {
      var view = root.hitTest(point)
      while let candidate = view {
        if candidate.registeredDraggedTypes.contains(.init("com.open.sidebar.node")) { return candidate }
        view = candidate.superview
      }
      return nil
    }
    switch a["op"] as? String ?? "window" {
    case "window":
      return ["number": target.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier,
        "frame": [target.frame.minX, target.frame.minY, target.frame.width, target.frame.height],
        "scale": target.backingScaleFactor,
        "sidebarWidth": controller.sidebar.frame.width,
        "tooltip": TooltipController.shared.visibleTooltip?.title ?? NSNull(),
        "pendingTooltip": TooltipController.shared.visibleOrPendingTooltip?.title ?? NSNull()] as [String: Any]
    case "targets":
      // Frames in window points, top-left origin (the `mouse` command's space).
      controller.contentView.layoutSubtreeIfNeeded()
      func box(_ rect: CGRect, in view: NSView) -> [Double] {
        let r = view.convert(rect, to: nil)
        return [r.minX, target.frame.height - r.maxY, r.width, r.height].map(Double.init)
      }
      let sidebar = controller.sidebar
      var rows: [[String: Any]] = []
      if let space = factory.focusedSpace {
        func visit(_ nodes: [SidebarNode]) {
          for node in nodes {
            if let frame = sidebar.rowFrame(nodeID: node.id) {
              rows.append(["id": node.id.description, "title": factory.model.tab(id: node.id)?.title ?? node.folder?.title ?? "",
                "frame": box(frame, in: sidebar)])
            }
            if case .folder(let folder) = node { visit(folder.children) }
          }
        }
        visit(space.pinned); visit(space.today)
      }
      let switchers: [[String: Any]] = factory.model.spaces.compactMap { space in
        guard let view = sidebar.spaceSwitcher(spaceID: space.id), view.window != nil, !view.isHidden else { return nil }
        return ["space": space.id.description, "title": space.title, "frame": box(view.bounds, in: view)]
      }
      let favorites: [[String: Any]] = (factory.focusedSpace.flatMap { factory.model.profile(id: $0.profileID) }?.favorites ?? [])
        .compactMap { tab in sidebar.favoriteFrame(tabID: tab.id).map { ["id": tab.id.description, "frame": box($0, in: sidebar)] } }
      let page = controller.container
      return ["rows": rows, "spaces": switchers, "favorites": favorites,
        "favoritesEmptyCard": sidebar.favoritesEmptyCard.map { box($0.bounds, in: $0) } ?? [],
        "dropFolder": sidebar.dropTargetFolderState ?? NSNull(),
        "newTab": sidebar.newTabRowFrame.map { box($0, in: sidebar) } ?? [],
        "sidebar": box(sidebar.bounds, in: sidebar), "page": box(page.bounds, in: page),
        "window": [target.frame.width, target.frame.height]] as [String: Any]
    case "space-icon":
      guard let raw = a["space"] as? String, let space = factory.model.spaces.first(where: { $0.id.description == raw }),
        let emoji = a["emoji"] as? String, !emoji.isEmpty else { throw Failure(message: "space-icon needs a space and an emoji") }
      factory.model.setSpaceIcon(id: space.id, icon: .emoji(emoji))
      if let title = a["title"] as? String, !title.isEmpty { factory.model.renameSpace(id: space.id, title: title) }
      app.scheduleSave()
      return true
    case "drag-begin":
      guard let raw = a["node"] as? String, let uuid = UUID(uuidString: raw), factory.model.tab(id: ItemID(rawValue: uuid)) != nil,
        let path = a["image"] as? String else { throw Failure(message: "drag-begin needs a tab node and an image path") }
      let start = try windowPoint(a["point"])
      guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
        let drag = controller.sidebar.demoDragImage(tabID: ItemID(rawValue: uuid), mouseDown: down),
        let tiff = drag.image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "no drag image for that row") }
      try png.write(to: URL(fileURLWithPath: path))
      let row = controller.sidebar.convert(drag.rowFrame, to: nil)
      basicsDrag = BasicsDemoDrag(node: raw)
      controller.sidebar.demoDragChanged([ItemID(rawValue: uuid)])
      return ["image": path, "imageSize": [drag.image.size.width, drag.image.size.height],
        "pixels": [bitmap.pixelsWide, bitmap.pixelsHigh],
        "row": [row.minX, target.frame.height - row.maxY, row.width, row.height]] as [String: Any]
    case "drag-over":
      guard let drag = basicsDrag else { throw Failure(message: "no demo drag") }
      let point = try windowPoint(a["point"])
      let request = info(point, drag.node)
      defer { request.draggingPasteboard.releaseGlobally() }
      let next = destination(at: point)
      var operation: NSDragOperation = []
      if next !== drag.destination {
        drag.destination?.draggingExited(request)
        drag.destination = next
        operation = next?.draggingEntered(request) ?? []
      } else {
        operation = next?.draggingUpdated(request) ?? []
      }
      controller.sidebar.displayIfNeeded()
      return ["destination": next.map { String(describing: type(of: $0)) } ?? "", "operation": operation.rawValue,
        "indicator": controller.sidebar.dropIndicatorFrame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
        "dropFolder": controller.sidebar.dropTargetFolderState ?? NSNull(),
        "favoritesGap": controller.sidebar.favoritesGapIndicatorFrame.map { r -> [Any] in
          [r.minX, r.minY, r.width, r.height] } ?? []] as [String: Any]
    case "drag-end":
      guard let drag = basicsDrag else { throw Failure(message: "no demo drag") }
      basicsDrag = nil
      let point = try windowPoint(a["point"])
      let request = info(point, drag.node)
      defer { request.draggingPasteboard.releaseGlobally() }
      var accepted = false
      if a["perform"] as? Bool == true, let destination = drag.destination {
        accepted = destination.prepareForDragOperation(request) && destination.performDragOperation(request)
        destination.concludeDragOperation(request)
      } else { drag.destination?.draggingExited(request) }
      controller.sidebar.demoDragChanged(nil)
      return ["accepted": accepted] as [String: Any]
    default:
      throw Failure(message: "unknown basics-demo op")
    }
  }
}
#endif
