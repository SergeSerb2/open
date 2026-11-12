#if OPEN_AUTOMATION
import AppKit

/// Opt-in (OPEN_AUTOMATION_RUNLOOP_TURNS=1) split of long main run-loop turns.
/// Observers only: no timer, display link or product scheduling. A turn runs from
/// after-waiting to the last before-waiting observer; its time is attributed to the
/// segment that was open when each observer fired. Core Animation's implicit commit
/// runs in its before-waiting observer at order 2,000,000, so the observers at
/// 1,999,999 and 2,000,001 bracket it. Only turns at or above 4 ms are kept (≤ 4,096).
@MainActor
final class RunLoopTurnTrace {
  static var current: RunLoopTurnTrace?
  private struct Turn { let start: Double; let end: Double; let segments: [String: Double] }
  private var turns: [Turn] = []
  private var observers: [CFRunLoopObserver] = []
  private var turnStart: Double?
  private var segment = "wake"
  private var segmentStart = 0.0
  private var segments: [String: Double] = [:]
  private var turnCount = 0
  private var overflow = false
  private let launchUptime: Double

  static func startIfRequested() {
    guard current == nil, ProcessInfo.processInfo.environment["OPEN_AUTOMATION_RUNLOOP_TURNS"] == "1" else { return }
    current = RunLoopTurnTrace()
  }

  private init() {
    launchUptime = ProcessInfo.processInfo.systemUptime - LaunchTiming.shared.elapsedMilliseconds / 1000
    turns.reserveCapacity(4096)
    add(.afterWaiting, CFIndex.min) { $0.begin() }
    add(.beforeTimers, CFIndex.min) { $0.enter("timers") }
    add(.beforeSources, CFIndex.min) { $0.enter("sources") }
    add(.beforeWaiting, CFIndex.min) { $0.enter("beforeWaitingObservers") }
    add(.beforeWaiting, 1_999_999) { $0.enter("caCommit") }
    add(.beforeWaiting, 2_000_001) { $0.enter("afterCommitObservers") }
    add(.beforeWaiting, CFIndex.max) { $0.finish() }
  }

  private func add(_ activity: CFRunLoopActivity, _ order: CFIndex, _ body: @escaping @MainActor (RunLoopTurnTrace) -> Void) {
    guard let observer = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, true, order, { _, _ in
      MainActor.assumeIsolated { if let trace = RunLoopTurnTrace.current { body(trace) } }
    }) else { return }
    observers.append(observer)
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }

  private func begin() {
    let now = ProcessInfo.processInfo.systemUptime
    turnStart = now; segment = "wake"; segmentStart = now; segments = [:]
  }
  private func enter(_ name: String) {
    let now = ProcessInfo.processInfo.systemUptime
    if turnStart == nil { turnStart = now; segments = [:]; segmentStart = now }
    segments[segment, default: 0] += (now - segmentStart) * 1000
    segment = name; segmentStart = now
  }
  private func finish() {
    enter("end")
    guard let start = turnStart else { return }
    turnCount += 1
    let end = ProcessInfo.processInfo.systemUptime
    if (end - start) * 1000 >= 4 {
      if turns.count < 4096 { turns.append(Turn(start: start, end: end, segments: segments)) } else { overflow = true }
    }
    turnStart = nil
  }

  func json(minimumMilliseconds: Double, fromLaunchMilliseconds: Double) -> [String: Any] {
    func ms(_ t: Double) -> Double { (t - launchUptime) * 1000 }
    let rows: [[String: Any]] = turns.filter { ($0.end - $0.start) * 1000 >= minimumMilliseconds && ms($0.start) >= fromLaunchMilliseconds }.map {
      ["startMs": ms($0.start), "endMs": ms($0.end), "ms": ($0.end - $0.start) * 1000,
       "segmentsMs": $0.segments.mapValues { ($0 * 1000).rounded() / 1000 }]
    }
    return ["turnCount": turnCount, "keptLongTurns": turns.count, "overflow": overflow, "turns": rows]
  }
}
#endif
