import Foundation

extension Duration {
    var milliseconds: Double {
        let c = components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}

public enum SuggestError: Error, Sendable {
    case timeout
}

/// Runs `operation` and throws `SuggestError.timeout` if it takes longer than `limit`.
/// The loser is cancelled.
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw SuggestError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
