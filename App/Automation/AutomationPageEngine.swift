#if OPEN_AUTOMATION
import AppKit
import OpenEngine
import OpenFeatures

/// Engine page API automation (page-platform §6 EP-1, EP-2, EP-3; docs/automation.md "Page engine").
/// `page-selection` reads the page's selection through `OEWebContent.requestSelection` (EP-2) and
/// `hasSelection` (EP-3). `swipe` replays one history swipe through Chromium's overlay controller
/// with the engine's `--open-automation` hook (EP-1); its phases arrive as `historySwipe` events.
extension AutomationController {
  func runPageEngineCommand(_ cmd: String, _ page: OEWebContent, _ a: [String: Any]) async throws -> Any {
    switch cmd {
    case "page-selection":
      let (text, link) = await withCheckedContinuation { (done: CheckedContinuation<(String, URL?), Never>) in
        page.requestSelection { text, link in done.resume(returning: (text, link)) }
      }
      return ["text": text, "link": link?.absoluteString ?? NSNull(), "hasSelection": page.hasSelection] as [String: Any]
    case "swipe":
      if let enabled = a["enabled"] as? Bool { page.historySwipeEnabled = enabled }
      if let overlay = a["engineOverlay"] as? Bool { page.drawsEngineHistorySwipeOverlay = overlay }
      guard let raw = a["direction"] as? String else {
        return ["enabled": page.historySwipeEnabled, "engineOverlay": page.drawsEngineHistorySwipeOverlay]
      }
      guard raw == "back" || raw == "forward" else { throw Failure(message: "direction must be back or forward") }
      let progress = a["progress"] as? Double ?? 1.2
      guard progress.isFinite, (0...2).contains(progress) else { throw Failure(message: "progress must be 0...2") }
      let ran = page.simulateHistorySwipe(direction: raw == "back" ? .back : .forward, progress: progress)
      return ["ran": ran, "enabled": page.historySwipeEnabled, "engineOverlay": page.drawsEngineHistorySwipeOverlay,
              "indicator": swipeIndicatorState(page)]
    case "swipe-indicator":
      return swipeIndicatorState(page)
    default:
      throw Failure(message: "unknown command \(cmd)")
    }
  }

  /// Open's indicator over the pane that shows `page` (page-platform §4.4.2).
  private func swipeIndicatorState(_ page: OEWebContent) -> [String: Any] {
    guard let w = try? window else { return ["pane": false] }
    let indicator: SwipeIndicatorView?
    if let c = w.controller, c.hasPeekController, c.peekController.isShown,
       (c.peekController.stack.last?.host as? EngineWebContentHost)?.content === page {
      indicator = c.peekController.overlay.swipeIndicator
    } else if let id = w.tabID(for: page), let slot = w.controller?.container.slots.first(where: { $0.tabID == id }) {
      indicator = slot.swipeIndicator
    } else { return ["pane": false] }
    guard let indicator else { return ["pane": true, "made": false] }
    let f = indicator.circleFrame, pf = indicator.frame
    var out: [String: Any] = ["pane": true, "made": true, "active": indicator.isActive, "hidden": indicator.isHidden,
      "circle": [f.minX, f.minY, f.width, f.height], "page": [pf.minX, pf.minY, pf.width, pf.height],
      "opacity": indicator.circleOpacity, "scale": indicator.circleScale]
    if let last = indicator.last { out["last"] = ["phase": last.phase.rawValue, "direction": last.direction.rawValue, "progress": last.progress] }
    return out
  }
}
#endif
