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

  func start() {
    lock.withLock { maximum = 0; samples = 0; pending = nil; active = true }
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

  private func receive(_ sent: Double) {
    lock.withLock {
      guard let pending, pending == sent else { return }
      maximum = max(maximum, (CACurrentMediaTime() - pending) * 1_000)
      samples += 1; self.pending = nil
    }
  }

  func stop() {
    timer?.cancel(); timer = nil
    lock.withLock {
      if let pending { maximum = max(maximum, (CACurrentMediaTime() - pending) * 1_000) }
      pending = nil; active = false
    }
  }

  var state: [String: Double] {
    lock.withLock { ["maxMainLagMilliseconds": maximum, "watchdogSamples": Double(samples), "watchdogActive": active ? 1 : 0] }
  }
}
#endif
