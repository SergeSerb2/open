#if OPEN_AUTOMATION
import AppKit

/// Opt-in run-loop trace for the scoped ready-open receipt. No display link,
/// polling timer or product scheduler is installed. Sleep is observed after
/// Core Animation's implicit commit, so pending work cannot disappear.
@MainActor
final class LibraryPreparationHeartbeat {
  private struct Busy { let start: Double; let end: Double }
  private var intervals: [Busy] = []
  private var observers: [CFRunLoopObserver] = []
  private var busyStart: Double?
  private var started = 0.0
  private var launchUptime = 0.0
  private var overflow = false
  func start() {
    started = ProcessInfo.processInfo.systemUptime
    launchUptime = started-LaunchTiming.shared.elapsedMilliseconds/1000
    busyStart = started
    // At most 16,384 pairs of Doubles: 262,144 bytes of element storage.
    intervals.reserveCapacity(16_384)
    for (activity,order) in [(CFRunLoopActivity.afterWaiting,CFIndex.min),(.beforeWaiting,CFIndex.max)] {
      if let observer = CFRunLoopObserverCreateWithHandler(nil,activity.rawValue,true,order,{ [weak self] _,activity in
        MainActor.assumeIsolated { self?.beat(busy:activity == .afterWaiting) }
      }) {
        observers.append(observer)
        CFRunLoopAddObserver(CFRunLoopGetMain(),observer,.commonModes)
      }
    }
  }
  private func beat(busy:Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    if busy {
      if busyStart == nil { busyStart = now }
    } else if let start = busyStart {
      if intervals.count < 16_384 { intervals.append(Busy(start:start,end:now)) }
      else { overflow = true }
      busyStart = nil
    }
  }
  func stop() {
    beat(busy:false)
    for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(),observer,.commonModes) }
    observers = []
  }
  func json(slices:[[String:Double]]) -> [String:Any] {
    ["startedLaunchMilliseconds":(started-launchUptime)*1000,"overflow":overflow,
      "observerCount":observers.count,
      "busyIntervals":intervals.map { row in
        ["startLaunchMilliseconds":(row.start-launchUptime)*1000,
          "endLaunchMilliseconds":(row.end-launchUptime)*1000,"milliseconds":(row.end-row.start)*1000]
      },
      "idleWorkIntervals":slices.map { row in
        ["startLaunchMilliseconds":(row["startUptime"]!-launchUptime)*1000,
          "endLaunchMilliseconds":(row["endUptime"]!-launchUptime)*1000,"milliseconds":row["milliseconds"]!,
          "rowKind":row["rowKind"] ?? 0,"phase":row["phase"] ?? 0,"firstUse":row["firstUse"] ?? 0]
      }]
  }
}
#endif
