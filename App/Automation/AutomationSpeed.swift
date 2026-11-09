#if OPEN_AUTOMATION
import AppKit
import OpenEngine
import Darwin

extension AutomationController {
  /// Whole native tree for settled main/branch parity, including AppKit additions.
  func speedMenuTree(_ menu: NSMenu?) -> [[String: Any]] {
    menu?.update()
    return (menu?.items ?? []).map { item in
      ["id": item.identifier?.rawValue ?? "", "title": item.title,
        "separator": item.isSeparatorItem, "key": item.keyEquivalent,
        "modifierMask": item.keyEquivalentModifierMask.rawValue,
        "checked": item.state.rawValue, "hidden": item.isHidden, "enabled": item.isEnabled,
        "targetNil": item.target == nil, "tag": item.tag,
        "action": item.action.map(NSStringFromSelector) ?? "",
        "payload": (item.representedObject as? [String: String])?["payload"] ?? "",
        "children": speedMenuTree(item.submenu)]
    }
  }

  /// Measurement only. The bare engine trace avoids the recording toast's
  /// once-per-second UI updates. The optional observer is harness-injected.
  func speedTrace(_ args: [String: Any]) async throws -> Any {
    switch args["action"] as? String ?? "state" {
    case "start":
      return OEEngine.shared.beginTracing(categories: args["categories"] as? String)
    case "stop":
      guard let path = args["path"] as? String else { throw Failure(message: "missing trace path") }
      return try await withCheckedThrowingContinuation { continuation in
        OEEngine.shared.endTracing(to: URL(fileURLWithPath: path)) { file, error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume(returning: file?.path ?? "") }
        }
      } as String
    case "observe":
      typealias Action = @convention(c) () -> Void
      typealias Watch = @convention(c) (UnsafeMutableRawPointer) -> Void
      guard let begin = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "open_idle_begin"),
        let watch = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "open_idle_watch_view") else {
        throw Failure(message: "speed observer is not injected")
      }
      unsafeBitCast(begin, to: Action.self)()
      for window in NSApp.windows {
        if let view = window.contentView { unsafeBitCast(watch, to: Watch.self)(Unmanaged.passUnretained(view).toOpaque()) }
      }
      return true
    case "reset", "read", "end":
      guard let window = app.frontWindowController, let factory = app.hostFactories[window.windowID] else {
        throw Failure(message: "speed observer needs a browser window")
      }
      var result = try FindIdleProbe.perform(args["action"] as? String ?? "read", factory: factory)
      if let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "open_speed_main_wakes") {
        result["mainRunLoopWakeups"] = unsafeBitCast(address, to: (@convention(c) () -> UInt64).self)()
      }
      return result
    default:
      let environment = ProcessInfo.processInfo.environment
      return ["tracing": OEEngine.shared.isTracing,
        "dyldStatisticsRequested": environment["DYLD_PRINT_STATISTICS"] == "1",
        "dyldDetailsRequested": environment["DYLD_PRINT_STATISTICS_DETAILS"] == "1"]
    }
  }
}
#endif
