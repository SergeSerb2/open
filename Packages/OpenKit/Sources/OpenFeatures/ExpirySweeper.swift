import AppKit

/// One App-wide, non-repeating deadline. Domain controllers supply all policy.
@MainActor
public final class ExpirySweeper {
    public enum Reason: String, Sendable { case launch, timer, wake, automation }
    public struct State: Sendable {
        public fileprivate(set) var running = false
        public fileprivate(set) var nextExpiry: Date?
        public fileprivate(set) var timerArmed = false
        public var armedTimerCount: Int { timerArmed ? 1 : 0 }
        public fileprivate(set) var timerGeneration = 0
        public fileprivate(set) var sweepCount = 0
        public fileprivate(set) var countsByReason: [String: Int] = [:]
        public fileprivate(set) var lastReason: Reason?
        public fileprivate(set) var lastNow: Date?
        public fileprivate(set) var lastCount = 0
    }
    public private(set) var state = State()
    private let now: @MainActor () -> Date
    private let nextExpiry: @MainActor (Date) -> Date?
    private let sweep: @MainActor (Date) -> Int
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lifecycle = 0
    private var sweeping = false

    public init(now: @escaping @MainActor () -> Date, nextExpiry: @escaping @MainActor (Date) -> Date?,
                sweep: @escaping @MainActor (Date) -> Int) {
        self.now = now; self.nextExpiry = nextExpiry; self.sweep = sweep
    }
    public func start() {
        guard !state.running else { return }
        state.running = true; lifecycle += 1
        let generation = lifecycle
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state.running, self.lifecycle == generation else { return }
                self.fire(reason: .wake)
            }
        }
        fire(reason: .launch)
    }
    private func cancelTimer() {
        timer?.invalidate(); timer = nil
        state.timerGeneration += 1; state.timerArmed = false; state.nextExpiry = nil
    }
    public func rearm() {
        guard !sweeping else { return } // fire always recomputes after the mutation batch.
        cancelTimer()
        guard state.running else { return }
        let time = now()
        guard let deadline = nextExpiry(time) else { return }
        state.nextExpiry = deadline
        let generation = state.timerGeneration
        let timer = Timer(timeInterval: max(0.001, deadline.timeIntervalSince(time) + 0.001), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.running, self.state.timerGeneration == generation else { return }
                self.timer = nil; self.state.timerArmed = false
                self.fire(reason: .timer)
            }
        }
        self.timer = timer; state.timerArmed = true
        RunLoop.main.add(timer, forMode: .common)
    }
    @discardableResult public func fire(reason: Reason) -> Int {
        guard state.running, !sweeping else { return 0 }
        cancelTimer(); sweeping = true
        let time = now(), count = sweep(time)
        state.sweepCount += 1; state.countsByReason[reason.rawValue, default: 0] += 1
        state.lastReason = reason; state.lastNow = time; state.lastCount = count
        sweeping = false; rearm()
        return count
    }
    public func stop() {
        state.running = false; lifecycle += 1; cancelTimer()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
    isolated deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
