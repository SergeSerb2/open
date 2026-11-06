import Foundation
import Observation

/// Transient, process-wide preview ownership. Space IDs are globally unique;
/// leases keep one editor from clearing another editor's live gesture.
@MainActor @Observable
public final class ThemePreviewRegistry {
    public static let shared = ThemePreviewRegistry()
    public private(set) var livePreviewSpaces: Set<SpaceID> = []
    @ObservationIgnored private var leases: [UUID: SpaceID] = [:]
    @ObservationIgnored private var observers: [UUID: @MainActor (SpaceID) -> Void] = [:]

    public init() {}
    public func begin(_ owner: UUID, spaceID: SpaceID) {
        leases[owner] = spaceID; livePreviewSpaces.insert(spaceID)
    }
    public func end(_ owner: UUID) {
        guard let id = leases.removeValue(forKey: owner) else { return }
        if !leases.values.contains(id) { livePreviewSpaces.remove(id) }
    }
    /// Called after the model write, on the panel's display tick. All sidebars
    /// update in this transaction, before the next frame is presented.
    public func publish(_ spaceID: SpaceID) {
        for callback in Array(observers.values) { callback(spaceID) }
    }
    public func addObserver(_ callback: @escaping @MainActor (SpaceID) -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }
}
