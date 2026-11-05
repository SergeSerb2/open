#if OPEN_AUTOMATION
import Foundation
import OpenRouting

extension AutomationController {
  func routingLog() -> [String: Any] {
    let intake = app.linkIntake
    let titles = Dictionary(uniqueKeysWithValues: app.model.spaces.map { ($0.id, app.model.displayTitle(for: $0)) })
    let entries: [[String: Any]] = intake.decisionLog.snapshot().map { decision in
      let data = try? JSONEncoder().encode(decision)
      let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
      return ["decision": value,
        "summary": RoutingDecisionFormatter.oneLine(decision, spaceTitles: titles),
        "sourceBundleID": decision.request.source.bundleID as Any? ?? NSNull(),
        "sourcePID": decision.request.source.pid as Any? ?? NSNull()]
    }
    let little: Any = app.lastLittleOpenRequest.map { ["url": $0.url.absoluteString,
      "profileHint": $0.profileHint?.description as Any? ?? NSNull()] as [String: Any] } ?? NSNull()
    return ["entries": entries, "duplicatesDropped": intake.duplicatesDropped,
      "pendingCount": intake.pendingCount, "ready": intake.ready,
      "queuedCount": intake.queuedCount, "drainedCount": intake.drainedCount,
      "lastLittleOpenRequest": little]
  }

  func defaultBrowserState() -> [String: Any] {
    // Deliberately read-only. There is no automation command for makeDefault.
    let service = app.defaultBrowserService
    return ["http": ["isDefault": service.isDefault(forScheme: "http")],
      "https": ["isDefault": service.isDefault(forScheme: "https")], "isDefaultBrowser": service.isDefaultBrowser]
  }
}
#endif
