#if OPEN_AUTOMATION
import Foundation

/// E2E launches opt out of macOS notification registration and authorization.
/// Notification fixtures explicitly opt in; normal user launches are unchanged.
enum AutomationNotificationSetup {
  static let suppressesSystemSetup = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS"] == "1"
  static let skipSwitch = "--open-automation-skip-macos-notifications"
}
#endif
