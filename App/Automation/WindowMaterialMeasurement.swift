#if OPEN_AUTOMATION
import AppKit
import QuartzCore
import OpenDesign
import OpenFeatures
import Darwin

/// Opt-in, bounded observation of the real window. Identical source is used in
/// both comparison builds. No sampler runs during idle measurements.
@MainActor
final class WindowMaterialMeasurement: NSObject {
  static let shared = WindowMaterialMeasurement()
  private weak var controller: BrowserWindowController?
  private var link: CADisplayLink?
  private var fields: [ThemeBackgroundView] = []
  private var frames: [[String: Any]] = []
  private var changes: [[String: Any]] = []
  private var started = 0.0
  private var armedBefore: [Int]?

  private func themeViews(_ view: NSView) -> [ThemeBackgroundView] {
    (view as? ThemeBackgroundView).map { [$0] } ?? view.subviews.flatMap(themeViews)
  }
  private func fieldState() -> [[String: Any]] {
    fields.map { ["rebuilds": $0.fieldRebuildCount, "active": $0.isWindowActive,
                  "hidden": $0.isHiddenOrHasHiddenAncestor] }
  }
  @objc private func keyChanged(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          window === controller?.window else { return }
    changes.append(["time": CACurrentMediaTime(), "event": notification.name.rawValue,
                    "before": armedBefore ?? fields.map(\.fieldRebuildCount)])
    armedBefore = nil
  }
  @objc private func tick(_ display: CADisplayLink) {
    guard let controller else { stop(); return }
    let now = CACurrentMediaTime()
    if now - started > 60 || frames.count >= 20000 { stop(); return }
    let reveal = controller.revealState
    frames.append(["time": now, "timestamp": display.timestamp,
      "targetTimestamp": display.targetTimestamp, "duration": display.duration,
      "offset": reveal.offset.isFinite ? Double(reveal.offset) : NSNull(),
      "phase": reveal.phase, "shows": reveal.shows, "hides": reveal.hides,
      "animated": controller.sidebar.layer?.animation(forKey: "reveal") != nil,
      "fields": fields.map(\.fieldRebuildCount)])
    for i in changes.indices where changes[i]["observed"] == nil {
      if let before = changes[i]["before"] as? [Int], before != fields.map(\.fieldRebuildCount) {
        changes[i]["observed"] = now
        changes[i]["after"] = fields.map(\.fieldRebuildCount)
      }
    }
  }
  private func stop() {
    link?.invalidate(); link = nil
    NotificationCenter.default.removeObserver(self)
  }
  func perform(_ args: [String: Any], controller: BrowserWindowController) async throws -> Any {
    let op = args["op"] as? String ?? "read"
    if op == "start" {
      stop(); self.controller = controller
      fields = themeViews(controller.contentView)
      frames = []; changes = []; armedBefore = nil; started = CACurrentMediaTime()
      for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: name, object: controller.window)
      }
      let display = controller.contentView.displayLink(target: self, selector: #selector(tick(_:)))
      let hz = Float(controller.window?.screen?.maximumFramesPerSecond ?? 120)
      display.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
      link = display; display.add(to: .main, forMode: .common)
    }
    if op == "stop" { stop() }
    if op == "arm" { armedBefore = fields.map(\.fieldRebuildCount); return true }
    if op == "observe" || op == "idle" {
      stop(); self.controller = controller; fields = themeViews(controller.contentView)
      typealias Action = @convention(c) () -> Void
      typealias Watch = @convention(c) (UnsafeMutableRawPointer) -> Void
      typealias Count = @convention(c) (Int32) -> UInt64
      func symbol<T>(_ name: String, _: T.Type) throws -> T {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
          throw NSError(domain: "WindowMaterialMeasurement missing observer", code: 1)
        }
        return unsafeBitCast(address, to: T.self)
      }
      let begin = try symbol("open_idle_begin", Action.self)
      let reset = try symbol("open_idle_reset_events", Action.self)
      let watch = try symbol("open_idle_watch_view", Watch.self)
      let count = try symbol("open_idle_count", Count.self)
      if op == "observe" { begin(); return true }
      watch(Unmanaged.passUnretained(controller.contentView).toOpaque())
      let before = (0..<11).map { count(Int32($0)) }, fieldsBefore = fieldState()
      reset(); let start = CACurrentMediaTime()
      try await Task.sleep(for: .seconds(5))
      return ["before": before, "after": (0..<11).map { count(Int32($0)) },
              "fieldsBefore": fieldsBefore, "fieldsAfter": fieldState(),
              "seconds": CACurrentMediaTime() - start] as [String: Any]
    }
    return ["running": link != nil, "started": started, "frames": frames,
            "changes": changes, "fields": fieldState()] as [String: Any]
  }
}
#endif
