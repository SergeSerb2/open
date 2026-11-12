#if OPEN_AUTOMATION
import AppKit

extension AutomationController {
  /// `handoff-state`: the activity Open publishes now (after the coalescing delay).
  /// `handoff-continue {url}`: hands a web-browsing activity to the real
  /// NSApplicationDelegate continue path, as macOS does for an incoming Handoff.
  func runHandoffCommand(_ cmd: String, _ args: [String: Any]) async throws -> Any {
    if cmd == "handoff-continue" {
      let activity = NSUserActivity(activityType: args["type"] as? String ?? NSUserActivityTypeBrowsingWeb)
      // NSUserActivity raises for a non-web webpageURL, so macOS never delivers one.
      if let raw = args["url"] as? String {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
          throw Failure(message: "url must be http or https")
        }
        activity.webpageURL = url
      }
      let willContinue = app.application(NSApp, willContinueUserActivityWithType: activity.activityType)
      let accepted = app.application(NSApp, continue: activity, restorationHandler: { _ in })
      return ["willContinue": willContinue, "accepted": accepted]
    }
    // Let a pending coalesced update run first.
    try? await Task.sleep(for: .milliseconds(250))
    return ["url": app.handoff.publishedURL?.absoluteString ?? "", "title": app.handoff.publishedTitle ?? "",
      "published": app.handoff.publishedURL != nil, "updates": app.handoff.updateCount] as [String: Any]
  }
}
#endif
