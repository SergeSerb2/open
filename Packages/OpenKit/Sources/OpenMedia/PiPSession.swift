import Foundation
import Observation
import OpenModel

/// One video PiP app-wide. Runtime session and snoozes only (PP-9, §4.4.6).
@MainActor @Observable public final class PiPSession {
    public enum Reason: Sendable { case userClosed, minimized, backToTab, sourceShown, sourceGone, replaced, failed }
    public enum State: Sendable, Equatable {
        case idle
        case requesting(tabID: ItemID, automatic: Bool)
        case active(tabID: ItemID, automatic: Bool)
        case minimized(tabID: ItemID)
        case closed(tabID: ItemID, reason: Reason)
    }
    public struct Effect: Sendable, Equatable {
        public let tabID: ItemID
        public let reason: Reason
        public let pause: Bool
    }
    public private(set) var state: State = .idle
    public private(set) var snoozed: Set<ItemID> = []
    public init() {}
    public var activeSource: (tabID: ItemID, automatic: Bool)? {
        switch state {
        case let .active(id, auto), let .requesting(id, auto): return (id, auto)
        default: return nil
        }
    }
    @discardableResult public func request(tabID: ItemID, automatic: Bool) -> Effect? {
        let replaced = activeSource.map { Effect(tabID: $0.tabID, reason: .replaced, pause: false) }
        state = .requesting(tabID: tabID, automatic: automatic)
        return replaced
    }
    public func didEnter(tabID: ItemID) {
        guard case let .requesting(id, automatic) = state, id == tabID else { return }
        state = .active(tabID: id, automatic: automatic)
    }
    @discardableResult public func close(_ reason: Reason) -> Effect? {
        guard let source = activeSource else { return nil }
        let pause = reason == .userClosed
        if source.automatic && (reason == .userClosed || reason == .minimized) { snoozed.insert(source.tabID) }
        if reason == .minimized { state = .minimized(tabID: source.tabID) }
        else { state = .closed(tabID: source.tabID, reason: reason) }
        return Effect(tabID: source.tabID, reason: reason, pause: pause)
    }
    @discardableResult public func displayed(tabID: ItemID) -> Effect? {
        snoozed.remove(tabID)
        guard let source = activeSource, source.tabID == tabID, source.automatic else { return nil }
        return close(.sourceShown)
    }
}
