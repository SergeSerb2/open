#if OPEN_AUTOMATION
import AppKit
import OpenEngine

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
      return ["ran": ran, "enabled": page.historySwipeEnabled, "engineOverlay": page.drawsEngineHistorySwipeOverlay]
    default:
      throw Failure(message: "unknown command \(cmd)")
    }
  }
}
#endif
