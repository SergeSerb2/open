#if OPEN_AUTOMATION
import AppKit
import QuartzCore
import OpenEngine
import Darwin

/// Opt-in H1 counters. No timer, process attach, or recurring socket query.
/// Boundary reads stop collection before they enumerate native state.
@MainActor
enum PerfAttribution {
  static var idleEnabled = false
  static var socketWork = false
  static var phasesEnabled = false
  static var eventInFlight = false
  static var counts: [String: Int] = [:]
  static var phases: [[String: Any]] = []
  static var events: [[String: Any]] = []
  private static var runLoopObserver: CFRunLoopObserver?
  private static var notificationObserver: NSObjectProtocol?
  private static var eventStart: Double?
  private static var idleStart = 0.0
  static var now: Double { ProcessInfo.processInfo.systemUptime }

  static func count(_ name: String) {
    guard idleEnabled, !socketWork else { return }
    counts[name, default: 0] += 1
  }
  static func mark(_ name: String) {
    guard phasesEnabled, let eventStart, phases.count < 256 else { return }
    phases.append(["name": name, "milliseconds": (now - eventStart) * 1000])
  }
  /// A socket-driven operation (no NSEvent) that wants the same phase clock.
  static func beginManual(_ name: String) {
    guard phasesEnabled else { return }
    eventStart = now; phases = [["name": name, "milliseconds": 0.0]]
  }
  static func beginEvent(_ event: NSEvent) {
    guard phasesEnabled else { return }
    eventInFlight = true; eventStart = now; phases = []
    phases.append(["name": "native.dispatch", "milliseconds": 0.0,
      "type": event.type.rawValue, "keyCode": event.keyCode,
      "modifierMask": event.modifierFlags.rawValue])
  }
  static func endEvent(window: NSWindow?) {
    guard phasesEnabled, eventStart != nil else { return }
    defer { eventInFlight = false }
    mark("native.return")
    submit("native", window: window)
    if events.count < 128 { events.append(["startUptime": eventStart!, "phases": phases]) }
    // Navigation callbacks can extend this final event until the next event/read.
  }
  static func submit(_ prefix: String, window: NSWindow?) {
    guard phasesEnabled, eventStart != nil else { return }
    window?.contentView?.layoutSubtreeIfNeeded(); mark("\(prefix).layout")
    window?.displayIfNeeded(); mark("\(prefix).display")
    CATransaction.flush(); mark("\(prefix).flush")
  }
  static func startIdle() {
    stopIdle(); counts = [:]; idleStart = now
    runLoopObserver = CFRunLoopObserverCreateWithHandler(nil,
      CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeTimers.rawValue |
        CFRunLoopActivity.beforeSources.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
      true, 0) { _, activity in
        MainActor.assumeIsolated { count("runloop.\(activity.rawValue)") }
      }
    if let runLoopObserver { CFRunLoopAddObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes) }
    notificationObserver = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { note in
      guard Thread.isMainThread else { return }
      let name = note.name.rawValue
      MainActor.assumeIsolated { count("notification.\(name)") }
    }
    idleEnabled = true
  }
  static func stopIdle() {
    idleEnabled = false
    if let runLoopObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes) }
    runLoopObserver = nil
    if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
    notificationObserver = nil
  }
  static func state(app: AppDelegate) -> [String: Any] {
    var classes: [String: Int] = [:], animations: [String: Int] = [:]
    var layerCount = 0
    func layers(_ layer: CALayer) {
      layerCount += 1
      for key in layer.animationKeys() ?? [] { animations[key, default: 0] += 1 }
      for child in layer.sublayers ?? [] { layers(child) }
    }
    func views(_ view: NSView) {
      classes[NSStringFromClass(type(of: view)), default: 0] += 1
      for child in view.subviews { views(child) }
    }
    for window in NSApp.windows {
      if let view = window.contentView { views(view); if let layer = view.layer { layers(layer) } }
    }
    var allocation = malloc_statistics_t()
    malloc_zone_statistics(nil, &allocation)
    var timers: Any = NSNull()
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "open_h1_timer_details"),
      let json = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafePointer<CChar>?).self)() {
      timers = (try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8))) ?? NSNull()
    }
    return ["seconds": idleStart > 0 ? now - idleStart : 0, "counts": counts,
      "timers": timers,
      "events": events, "latestPhases": phases, "latestEventStartUptime": eventStart ?? 0, "viewClasses": classes,
      "layerCount": layerCount, "animations": animations,
      "mallocBytesInUse": allocation.size_in_use, "mallocBytesAllocated": allocation.size_allocated,
      "windows": NSApp.windows.map { ["number": $0.windowNumber, "visible": $0.isVisible,
        "key": $0.isKeyWindow, "main": $0.isMainWindow] },
      "active": NSApp.isActive, "hidden": NSApp.isHidden,
      "engineHosts": app.hostFactories.values.reduce(0) { $0 + $1.hosts.count },
      "welcomeHosts": app.hostFactories.values.reduce(0) { $0 + $1.welcomeHosts.count },
      "sleepPasses": app.tabSleep.controller?.passCount ?? 0,
      "enginePages": OEEngine.shared.allWebContents.count]
  }
}

extension AutomationController {
  func perfAttribution(_ args: [String: Any]) throws -> Any {
    switch args["action"] as? String ?? "read" {
    case "idle-start": PerfAttribution.startIdle()
    case "phase-start":
      PerfAttribution.events = []; PerfAttribution.phases = []; PerfAttribution.phasesEnabled = true
    case "phase-read": break
    case "read": PerfAttribution.stopIdle(); PerfAttribution.phasesEnabled = false
    case "resign-key": app.frontWindowController?.window?.resignKey()
    default: throw Failure(message: "unknown perf attribution action")
    }
    return PerfAttribution.state(app: app)
  }
}
#endif
