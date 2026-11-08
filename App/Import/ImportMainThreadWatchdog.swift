#if OPEN_AUTOMATION
import Foundation
import QuartzCore

/// Exists only for an active automation import. One outstanding main-queue
/// ping bounds memory even when the main thread is blocked.
final class ImportMainThreadWatchdog: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "open.import.watchdog", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var pending: Double?
  private var maximum: Double = 0
  private var samples = 0
  private var active = false
  private var phase = "progress"
  private var phaseStarted: Double = 0
  private var phaseLags: [String: Double] = [:]
  private var phaseTimes: [String: Double] = [:]

  func start() {
    lock.withLock {
      maximum = 0; samples = 0; pending = nil; active = true
      phase = "progress"; phaseStarted = CACurrentMediaTime()
      phaseLags = [phase: 0]; phaseTimes = [:]
    }
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let send: Double? = self.lock.withLock {
        guard self.active, self.pending == nil else { return nil }
        let sent = CACurrentMediaTime(); self.pending = sent; return sent
      }
      guard let send else { return }
      DispatchQueue.main.async { [weak self] in self?.receive(send) }
    }
    timer = source; source.resume()
  }

  /// Account for a ping spanning a phase boundary before changing its label.
  /// The overall maximum still includes the full, uninterrupted lag.
  func beginPhase(_ name: String) {
    lock.withLock {
      guard active else { return }
      let now = CACurrentMediaTime()
      recordPending(at: now)
      phaseTimes[phase, default: 0] += (now - phaseStarted) * 1_000
      phase = name; phaseStarted = now
      phaseLags[name, default: 0] += 0
    }
  }

  private func recordPending(at now: Double) {
    guard let pending else { return }
    maximum = max(maximum, (now - pending) * 1_000)
    phaseLags[phase] = max(phaseLags[phase, default: 0], (now - max(pending, phaseStarted)) * 1_000)
  }

  private func receive(_ sent: Double) {
    lock.withLock {
      guard let pending, pending == sent else { return }
      recordPending(at: CACurrentMediaTime())
      samples += 1; self.pending = nil
    }
  }

  func stop() {
    timer?.cancel(); timer = nil
    lock.withLock {
      let now = CACurrentMediaTime()
      recordPending(at: now)
      phaseTimes[phase, default: 0] += (now - phaseStarted) * 1_000
      pending = nil; active = false
    }
  }

  var state: [String: Double] {
    lock.withLock {
      var value = ["maxMainLagMilliseconds": maximum, "watchdogSamples": Double(samples), "watchdogActive": active ? 1.0 : 0.0]
      for (name, lag) in phaseLags { value["phase." + name + ".maxMainLagMilliseconds"] = lag }
      for (name, elapsed) in phaseTimes { value["phase." + name + ".milliseconds"] = elapsed }
      return value
    }
  }
}
#endif
