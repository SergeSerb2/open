import Foundation
import Observation

/// Runs `body` with Observation tracking. The first change to any observed
/// property calls `invalidate` once, on the main actor. Views call this inside
/// `draw`, `layout`, or `updateLayer`, so each pass re-arms tracking for exactly
/// the properties it read. `invalidate` runs during the property's `willSet`, so
/// it must only mark the view dirty (`needsDisplay`, `needsLayout`), never read
/// the new value.
@MainActor
func tracked<T>(_ body: () -> T, invalidate: @escaping @MainActor @Sendable () -> Void) -> T {
    withObservationTracking(body) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { invalidate() }
        } else {
            Task { @MainActor in invalidate() }
        }
    }
}

/// Re-arming observation for logic that needs the new values (for example
/// "the focused Space changed → slide the pager"). `changed` runs on the next
/// main-actor turn after a change, once per burst of changes.
@MainActor
final class ObservationLoop {
    private let read: @MainActor () -> Void
    private let changed: @MainActor () -> Void
    private var cancelled = false
    private var scheduled = false

    init(read: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        self.read = read
        self.changed = changed
        arm()
    }

    private func arm() {
        guard !cancelled else { return }
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.fire() }
        }
    }

    private func fire() {
        guard !cancelled else { return }
        changed()
        arm()
    }

    func cancel() { cancelled = true }
}
