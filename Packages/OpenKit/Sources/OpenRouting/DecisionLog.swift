import Foundation

public protocol RoutingLogging: Sendable {
    func record(_ decision: RoutingDecision)
}

/// Thread-safe, bounded history, oldest first. Contains clicked URLs and source
/// identities, with history-entry sensitivity. Never persisted or sent elsewhere.
/// No page titles, cookies, or fetched content are recorded.
public final class RoutingDecisionLog: RoutingLogging, @unchecked Sendable {
    public static let capacity = 200
    private let lock = NSLock()
    private var decisions: [RoutingDecision] = []

    public init() {}

    public func record(_ decision: RoutingDecision) {
        lock.withLock {
            decisions.append(decision)
            if decisions.count > Self.capacity { decisions.removeFirst() }
        }
    }

    public func snapshot() -> [RoutingDecision] { lock.withLock { decisions } }
    public func clear() { lock.withLock { decisions.removeAll(keepingCapacity: true) } }
}
