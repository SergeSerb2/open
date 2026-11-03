#if OPEN_AUTOMATION
import AppKit
import UserNotifications

/// Web notification automation commands (page-platform §8.3, docs/automation.md "Notifications").
extension AutomationController {
  static let notificationCommands: Set<String> = [
    "notifications", "notification-click", "notification-authorization", "window-miniaturize",
  ]

  /// EP-7 (`OEBrowserContext (NotificationTesting)`, fork patch 0504) is not in the engine yet.
  static let engineNotificationsBlocked: [String: Any] = [
    "status": "BLOCKED", "reason": "EP-7: engine notification list and simulated click (fork patch 0504)",
  ]

  func runNotificationCommand(_ cmd: String, _ a: [String: Any]) async throws -> Any {
    let authorization = NotificationAuthorization.shared
    switch cmd {
    case "notifications":
      // macOS's list for Open.app (banners shown by the browser process). Alerts
      // come from the Alerts helper's own bundle and are not in this list.
      let status = await authorization.readStatus()
      let delivered = await Self.deliveredNotifications()
      return ["authorization": status.rawValue, "delivered": delivered, "engine": Self.engineNotificationsBlocked] as [String: Any]
    case "notification-click":
      return Self.engineNotificationsBlocked
    case "notification-authorization":
      let status = await authorization.readStatus()
      return ["status": status.rawValue, "denied": authorization.isDenied, "requests": authorization.requestLog,
              "suppressed": authorization.suppressesRequests,
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
