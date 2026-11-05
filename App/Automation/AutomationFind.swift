#if OPEN_AUTOMATION
import AppKit
import Darwin

/// Reads the harness-only feature-idle observer. No library is loaded here:
/// the e2e launcher injects it into its own disposable App instance.
@MainActor
enum FindIdleProbe {
  static func perform(_ action: String, factory: EngineWebContentHostFactory) throws -> [String: Any] {
    func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
      guard let value = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
        throw AutomationController.Failure(message: "Find idle observer is not loaded")
      }
      return value
    }
    switch action {
    case "begin", "reset", "end":
      let name = ["begin": "open_idle_begin", "reset": "open_idle_reset_events", "end": "open_idle_end"][action]!
      unsafeBitCast(try symbol(name), to: (@convention(c) () -> Void).self)()
    case "watch":
      let watch = unsafeBitCast(try symbol("open_idle_watch_view"), to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
      factory.findController?.observeIdleViews { watch(Unmanaged.passUnretained($0).toOpaque()) }
    case "invalidate":
      // Observer canary: invalidate the actual Find view, then use the same
      // zero-work predicate as the idle interval. This is never a fake count.
      factory.findController?.observeIdleViews { $0.needsLayout = true }
    case "read": break
    default: throw AutomationController.Failure(message: "Unknown Find idle observer action")
    }
    let count = unsafeBitCast(try symbol("open_idle_count"), to: (@convention(c) (Int32) -> UInt64).self)
    let names = ["draw", "layout", "layerDisplay", "invalidations", "scheduling", "overflow", "timers", "dispatchTimers", "cvLinks", "displayLinks"]
    return Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, count(Int32($0.offset)) as Any) })
  }
}
#endif
