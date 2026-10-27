#if OPEN_AUTOMATION
import AppKit

/// Starts before the first window/engine turn so launch intervals have the
/// same native foreground-loss evidence as later socket-driven intervals.
@MainActor
final class ActivationTrace {
  private(set) var events: [[String: Any]] = []
  private var applicationObservers: [any NSObjectProtocol] = []
  private var hardwareMonitor: Any?
  private var syntheticKey: NSEvent?
  private var syntheticPointerTags: Set<Int> = []
  private var workspaceObserver: (any NSObjectProtocol)?

  init() {
    // Only explicit short-lived e2e profiles use virtual input. Local monitors
    // see native queued input; socket key events use sendEvent directly. Drop
    // untrusted key events before a field can retain text from the shared Mac.
    if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_VIRTUAL_INPUT"] == "1" {
      hardwareMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self] event in
        let dropKey = MainActor.assumeIsolated {
          if self?.syntheticKey === event { return false }
          if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let sourcePID = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
            if self?.syntheticPointerTags.remove(event.eventNumber) == nil {
              self?.append(["event": "hardwareInteraction", "kind": "pointer", "sourcePID": sourcePID ?? -1, "duringSyntheticKey": self?.syntheticKey != nil, "uptime": ProcessInfo.processInfo.systemUptime])
            }
            return false
          }
          if event.type == .keyDown { self?.append(["event": "hardwareInteraction", "kind": "key", "uptime": ProcessInfo.processInfo.systemUptime]) }
          return true // no characters or key codes are retained in the trace
        }
        return dropKey ? nil : event
      }
    }
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
      let bundle = target?.bundleIdentifier ?? ""
      MainActor.assumeIsolated {
        self?.append(["event": "frontmostChanged", "uptime": ProcessInfo.processInfo.systemUptime,
          "frontmostApp": name, "frontmostPID": pid, "frontmostBundle": bundle])
      }
    }
  }
  func deliverSyntheticKey(_ event: NSEvent, to window: NSWindow? = nil) {
    syntheticKey = event
    defer { syntheticKey = nil }
    if let window { window.sendEvent(event) } else { NSApp.sendEvent(event) }
  }
  func tagSyntheticPointer(_ tag: Int) { if hardwareMonitor != nil { syntheticPointerTags.insert(tag) } }
  private func append(_ event: [String: Any]) {
    events.append(event)
    if events.count > 512 { events.removeFirst(events.count - 512) }
  }
  isolated deinit {
    if let hardwareMonitor { NSEvent.removeMonitor(hardwareMonitor) }
    applicationObservers.forEach(NotificationCenter.default.removeObserver)
    if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
  }
}
#endif
