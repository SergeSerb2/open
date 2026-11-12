#if OPEN_AUTOMATION
import AppKit
import ImageIO
import OpenDesign
import OpenFeatures
import OpenSettings

/// Capture tool automation (page-platform §8.3, docs/automation.md "Capture"). Every step goes
/// through the real paths: the File menu item, own-window mouse events through
/// `NSApplication.sendEvent` (so the window's local monitors see them), and the card's buttons.
extension AutomationController {
  func runCaptureCommand(_ cmd: String, _ a: [String: Any]) async throws -> Any {
    let w = try window
    guard let controller = w.controller else { throw Failure(message: "no browser window") }
    switch cmd {
    case "capture-state": return captureState(controller)
    case "capture-action":
      let capture = controller.capture
      if let hovered = a["hover"] as? Bool {
        guard let card = capture.card else { throw Failure(message: "no capture card") }
        card.setHovered(hovered); return captureState(controller)
      }
      if a["action"] as? String == "cancel" { capture.cancel(); return captureState(controller) }
      guard let raw = a["action"] as? String, let action = CaptureResultView.Action(rawValue: raw) else { throw Failure(message: "unknown capture action") }
      guard let button = capture.card?.buttons[action] else { throw Failure(message: "the capture card has no \(raw) button") }
      button.performClick(nil)
      await Task.yield()
      return captureState(controller)
    case "captures": return try capturesIndex(a)
    default: return try await capture(a, w, controller)
    }
  }

  private func capture(_ a: [String: Any], _ w: EngineWebContentHostFactory, _ controller: BrowserWindowController) async throws -> Any {
    let mode = a["mode"] as? String ?? "area"
    let ids = ["area": "capture-page", "fullPage": "capture-full-page", "portrait": "capture-portrait"]
    let rect = a["rect"] as? [Double]
    if let rect, rect.count != 4 || rect[2] <= 0 || rect[3] <= 0 { throw Failure(message: "rect must be [x, y, w, h] with a positive size") }
    let capture = controller.capture
    var steps: [[String: Any]] = []
    if a["entry"] as? String == "drag" {
      // Cmd+Shift drag on the page itself (§4.6.2): down, a move under the threshold, then the drag.
      guard mode == "area", let rect, let target = controller.captureHost()?.view, let window = target.window else { throw Failure(message: "drag needs mode=area, a rect, and a page") }
      func send(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
        let point = target.convert(NSPoint(x: x, y: y), to: nil)
        if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) { NSApp.sendEvent(e) }
      }
      send(.leftMouseDown, rect[0], rect[1])
      steps.append(["after": "down", "held": capture.isHoldingPress, "overlay": capture.isOverlayActive])
      send(.leftMouseDragged, rect[0] + 2, rect[1] + 1)
      steps.append(["after": "move 2.2 pt", "held": capture.isHoldingPress, "overlay": capture.isOverlayActive])
      send(.leftMouseDragged, rect[0] + rect[2] / 2, rect[1] + rect[3] / 2)
      steps.append(["after": "drag", "overlay": capture.isOverlayActive,
        "anchor": capture.overlay?.anchor.map { [$0.x, $0.y] } ?? [], "selection": capture.overlay?.selection.map(Self.box) ?? []])
      send(.leftMouseDragged, rect[0] + rect[2], rect[1] + rect[3])
      send(.leftMouseUp, rect[0] + rect[2], rect[1] + rect[3])
    } else {
      guard let id = ids[mode] else { throw Failure(message: "mode must be area, fullPage, or portrait") }
      guard let (menu, index) = findMenuItem(id, in: NSApp.mainMenu) else { throw Failure(message: "no menu item \(id)") }
      let item = menu.item(at: index)!
      guard menuEnabled(item) else { throw Failure(message: "disabled menu item \(id)") }
      menu.performActionForItem(at: index)
      if mode == "area" {
        guard let overlay = capture.overlay, let window = overlay.window else { throw Failure(message: "the capture overlay did not show") }
        steps.append(["after": "command", "state": captureState(controller)])
        if let rect {
          // A drag inside the overlay, in page-view points (the overlay covers the page view).
          func send(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
            let point = overlay.convert(NSPoint(x: x, y: y), to: nil)
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) { NSApp.sendEvent(e) }
          }
          send(.leftMouseDown, rect[0], rect[1])
          send(.leftMouseDragged, rect[0] + rect[2] / 2, rect[1] + rect[3] / 2)
          steps.append(["after": "drag", "selection": overlay.selection.map(Self.box) ?? [],
            "sizeLabel": overlay.sizeLabelFrame.map(Self.box) ?? [], "hintHidden": overlay.hint.isHidden || overlay.hint.alphaValue == 0])
          send(.leftMouseDragged, rect[0] + rect[2], rect[1] + rect[3])
          send(.leftMouseUp, rect[0] + rect[2], rect[1] + rect[3])
        } else { return ["steps": steps, "state": captureState(controller)] as [String: Any] }
      }
    }
    // Wait for the pipeline (snapshot, compose, Library write) to finish.
    let deadline = ContinuousClock.now.advanced(by: .seconds(a["timeout"] as? Double ?? 60))
    while capture.phase == .capturing || capture.phase == .selecting {
      guard ContinuousClock.now < deadline else { throw Failure(message: "capture did not finish: \(capture.phase.rawValue)") }
      try await Task.sleep(for: .milliseconds(20))
    }
    return ["steps": steps, "state": captureState(controller)] as [String: Any]
  }

  static func box(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }

  func captureState(_ controller: BrowserWindowController) -> [String: Any] {
    let capture = controller.capture
    var state: [String: Any] = ["phase": capture.phase.rawValue, "overlayActive": controller.captureOverlayActive,
      "held": capture.isHoldingPress, "completed": capture.completedCount, "cancelled": capture.cancelledCount,
      "replays": capture.replayCount, "hintShows": capture.hintShows, "entry": capture.lastEntry?.rawValue ?? "",
      "error": capture.lastError ?? ""]
    if let overlay = capture.overlay {
      let page = controller.captureHost()?.view
      state["overlay"] = ["frame": Self.box(overlay.frame), "pageFrame": page.map { Self.box(controller.contentView.convert($0.bounds, from: $0)) } ?? [],
        "selection": overlay.selection.map(Self.box) ?? [], "anchor": overlay.anchor.map { [Double($0.x), Double($0.y)] } ?? [],
        "sizeLabel": overlay.sizeLabelFrame.map(Self.box) ?? [], "sizeText": overlay.selection.map(CaptureOverlayView.sizeText) ?? "",
        "hint": overlay.hint.text, "hintHidden": overlay.hint.isHidden || overlay.hint.alphaValue == 0,
        "firstResponder": overlay.window?.firstResponder === overlay] as [String: Any]
    }
    if let card = capture.card {
      state["card"] = ["frame": Self.box(card.frame), "actions": card.actions.map(\.rawValue), "savedLine": card.showsSavedLine,
        "note": card.note ?? "", "hovered": card.isHovered, "lifetime": CaptureMetrics.cardLifetime,
        "remaining": capture.cardDeadline.map { $0 - CACurrentMediaTime() } ?? capture.cardRemaining,
        "paused": capture.cardDeadline == nil, "panel": Self.box(controller.container.frame)] as [String: Any]
    }
    if let r = capture.lastResult {
      state["result"] = ["kind": r.kind.rawValue, "width": r.pixelWidth, "height": r.pixelHeight, "truncated": r.truncated,
        "saved": r.savedID?.uuidString ?? "", "host": r.sourceHost, "bytes": r.png.count,
        "fileName": CaptureComposer.fileName(title: r.title, date: r.createdAt)] as [String: Any]
    }
    return state
  }

  /// Rows of `State/captures.json` with each file's size and PNG pixel size; `probe` reads
  /// pixels ([[x, y], …] in image pixels) of row `index` (default: the last row).
  private func capturesIndex(_ a: [String: Any]) throws -> Any {
    let writer = app.captureLibrary
    let rows = try writer.readIndex()
    var out: [[String: Any]] = []
    for row in rows {
      let url = writer.directory.appendingPathComponent(row.fileName)
      let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
      var item: [String: Any] = ["id": row.id.uuidString, "fileName": row.fileName, "createdAt": row.createdAt.timeIntervalSince1970,
        "kind": row.kind.rawValue, "sourceHost": row.sourceHost, "bytes": bytes]
      if let data = try? Data(contentsOf: url), let size = CaptureComposer.pixelSize(data) { item["width"] = size.width; item["height"] = size.height }
      out.append(item)
    }
    var result: [String: Any] = ["rows": out, "directory": writer.directory.path, "index": writer.indexURL.path]
    if let probe = a["probe"] as? [[Double]], !rows.isEmpty {
      guard probe.count <= 64 else { throw Failure(message: "at most 64 probe points") }
      let row = rows[min(max(a["index"] as? Int ?? rows.count - 1, 0), rows.count - 1)]
      guard let data = try? Data(contentsOf: writer.directory.appendingPathComponent(row.fileName)), let image = CaptureComposer.decode(data),
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message: "capture image unreadable") }
      var samples: [[Int]] = []
      for point in probe {
        let x = Int(point[0]), y = Int(point[1])
        guard x >= 0, y >= 0, x < image.width, y < image.height, let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { samples.append([]); continue }
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = context.data!.assumingMemoryBound(to: UInt8.self)
        samples.append([Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3])])
      }
      result["probe"] = samples; result["probeRow"] = row.id.uuidString
    }
    return result
  }
}
#endif
