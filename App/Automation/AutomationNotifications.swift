#if OPEN_AUTOMATION
import AppKit
import OpenEngine
import UserNotifications

/// Web notification automation commands (page-platform §8.3, docs/automation.md "Notifications").
extension AutomationController {
  static let notificationCommands: Set<String> = [
    "notifications", "notification-click", "notification-authorization", "window-miniaturize",
  ]

  /// The context of the window's focused Space (its profile's notifications).
  private func notificationContext() throws -> OEBrowserContext {
    let w = try window
    guard let space = w.focusedSpace, let context = w.context(for: space.profileID) else { throw Failure(message: "no profile context") }
    return context
  }

  func runNotificationCommand(_ cmd: String, _ a: [String: Any]) async throws -> Any {
    if AutomationNotificationSetup.suppressesSystemSetup, ["notifications", "notification-click"].contains(cmd) {
      throw Failure(message: "macOS notification setup is disabled for this automation launch")
    }
    let authorization = NotificationAuthorization.shared
    switch cmd {
    case "notifications":
      // macOS's list for Open.app (banners shown by the browser process). Alerts
      // come from the Alerts helper's own bundle and are not in this list.
      let status = await authorization.readStatus()
      let delivered = await Self.deliveredNotifications()
      // EP-7: Chromium's own displayed list (engine switch --open-automation).
      let context = try notificationContext()
      let engine = await withCheckedContinuation { (done: CheckedContinuation<[[String: String]], Never>) in
        context.displayedNotifications { done.resume(returning: $0) }
      }
      return ["authorization": status.rawValue, "delivered": delivered, "engine": engine,
              "clicks": NotificationClickRouter.shared.log] as [String: Any]
    case "notification-click":
      // EP-7: the same click path as macOS's response; `id` from `notifications`.engine.
      guard let id = a["id"] as? String else { throw Failure(message: "missing id") }
      return ["clicked": try notificationContext().simulateClickOnNotification(identifier: id)]
    case "notification-authorization":
      let status = await authorization.readStatus()
      return ["status": status.rawValue, "denied": authorization.isDenied, "requests": authorization.requestLog,
              "suppressed": authorization.suppressesRequests,
              "setupSuppressed": AutomationNotificationSetup.suppressesSystemSetup,
              "settingsURL": NotificationAuthorization.systemSettingsURL.absoluteString] as [String: Any]
    case "window-miniaturize":
      // What a click on the yellow button does.
      guard let window = try window.window else { throw Failure(message: "no window") }
      window.miniaturize(nil)
      return true
    default:
      throw Failure(message: "unknown notification command \(cmd)")
    }
  }

  nonisolated private static func deliveredNotifications() async -> [[String: String]] {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getDeliveredNotifications { items in
        continuation.resume(returning: items.map { item in
          let content = item.request.content
          return ["id": item.request.identifier, "title": content.title, "subtitle": content.subtitle,
                  "body": content.body, "thread": content.threadIdentifier]
        })
      }
    }
  }
}
#endif
