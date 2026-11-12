#if OPEN_AUTOMATION
import AppKit

/// Opt-in (OPEN_AUTOMATION_STARTUP_TRACE=1) main-thread record for the first
/// seconds after launch: run-loop busy intervals (after-waiting → before-waiting,
/// observed after Core Animation's implicit commit) and named regions around
/// start-up service bodies. No timer, display link or product scheduling.
/// Product builds contain none of this. Times are milliseconds of launch age.
@MainActor
final class StartupMainThreadTrace {
  static var current: StartupMainThreadTrace?
  struct Region { fileprivate let index: Int }
  private struct Span { let name: String; let start: Double; var end: Double? }
  private var busy: [(Double, Double)] = []
  private var spans: [Span] = []
  private var busyStart: Double?
  private var observers: [CFRunLoopObserver] = []
  private var overflow = false
  private let launchUptime: Double

  static func startIfRequested() {
    guard current == nil, ProcessInfo.processInfo.environment["OPEN_AUTOMATION_STARTUP_TRACE"] == "1" else { return }
    current = StartupMainThreadTrace()
  }

  private init() {
    let now = ProcessInfo.processInfo.systemUptime
    launchUptime = now - LaunchTiming.shared.elapsedMilliseconds / 1000
    busyStart = now
    // At most 16,384 intervals and 4,096 spans: under 1 MiB.
    busy.reserveCapacity(16_384); spans.reserveCapacity(4_096)
    for (activity, order) in [(CFRunLoopActivity.afterWaiting, CFIndex.min), (.beforeWaiting, CFIndex.max)] {
      if let observer = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, true, order, { _, activity in
        MainActor.assumeIsolated { StartupMainThreadTrace.current?.beat(busy: activity == .afterWaiting) }
      }) {
        observers.append(observer)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      }
    }
  }

  private func beat(busy isBusy: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    if isBusy { if busyStart == nil { busyStart = now }; return }
    guard let start = busyStart else { return }
    busyStart = nil
    if busy.count < 16_384 { busy.append((start, now)) } else { overflow = true }
  }

  static func begin(_ name: String) -> Region? { current?.open(name) }
  static func end(_ region: Region?) { if let region { current?.close(region.index) } }

  private func open(_ name: String) -> Region? {
    guard spans.count < 4_096 else { overflow = true; return nil }
    spans.append(Span(name: name, start: ProcessInfo.processInfo.systemUptime))
    return Region(index: spans.count - 1)
  }
  private func close(_ index: Int) { spans[index].end = ProcessInfo.processInfo.systemUptime }

  /// Busy intervals at or above `minimumMilliseconds`, each with the regions it overlaps.
  func json(minimumMilliseconds: Double) -> [String: Any] {
    func ms(_ t: Double) -> Double { (t - launchUptime) * 1000 }
    let rows: [[String: Any]] = busy.filter { ($0.1 - $0.0) * 1000 >= minimumMilliseconds }.map { interval in
      var overlap: [String: Double] = [:]
      for span in spans {
        let low = max(span.start, interval.0), high = min(span.end ?? interval.1, interval.1)
        if high > low { overlap[span.name, default: 0] += (high - low) * 1000 }
      }
      return ["startMs": ms(interval.0), "endMs": ms(interval.1), "ms": (interval.1 - interval.0) * 1000,
              "regionOverlapMs": overlap]
    }
    return ["overflow": overflow, "intervalCount": busy.count, "openBusyStartMs": busyStart.map(ms) ?? -1,
            "intervals": rows,
            "maxIntervalMs": busy.map { ($0.1 - $0.0) * 1000 }.max() ?? 0,
            "regions": spans.map { ["name": $0.name, "startMs": ms($0.start), "endMs": $0.end.map(ms) ?? -1,
                                    "ms": (($0.end ?? $0.start) - $0.start) * 1000] }]
  }
}
#endif
