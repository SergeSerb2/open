#if OPEN_AUTOMATION
import AppKit

/// Starts before the first window/engine turn so launch intervals have the
/// same native foreground-loss evidence as later socket-driven intervals.
@MainActor
final class ActivationTrace {
  private(set) var events: [[String: Any]] = []
  private var applicationObservers: [NSObjectProtocol] = []
  private var workspaceObserver: NSObjectProtocol?

  init() {
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      applicationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        let eventName = notification.name.rawValue
        MainActor.assumeIsolated {
          self?.append(["event": eventName, "uptime": ProcessInfo.processInfo.systemUptime,
            "active": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? 0,
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown",
            "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0])
        }
      })
    }
    workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
      let target = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let name = target?.localizedName ?? "unknown", pid = target?.processIdentifier ?? 0
      MainActor.assumeIsolated {
        self?.append(["event": "frontmostChanged", "uptime": ProcessInfo.processInfo.systemUptime,
          "frontmostApp": name, "frontmostPID": pid])
      }
    }
  }
  private func append(_ event: [String: Any]) {
    events.append(event)
    if events.count > 512 { events.removeFirst(events.count - 512) }
  }
  isolated deinit {
    applicationObservers.forEach(NotificationCenter.default.removeObserver)
    if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
  }
}
#endif
