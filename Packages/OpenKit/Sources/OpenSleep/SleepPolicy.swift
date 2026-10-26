import Foundation
import OpenModel

/// Pure decisions. Pin/favorite status deliberately is not an input.
public struct SleepPolicy: Sendable {
    public var mode: SleepMode
    public let freezeDelay: TimeInterval = 30
    public let destroyDelay: TimeInterval = 24 * 3600
    public let audioProtection: TimeInterval = 60
    public let loadProtection: TimeInterval = 10
    public let formProtection: TimeInterval = 300

    public init(mode: SleepMode = .balanced) { self.mode = mode }

    public enum Gate: String, Sendable {
        case visible, audible, loading, capturing, devTools, downloading, unload, form
    }
    public enum Action: Sendable { case none, freeze, discard, destroy }

    @MainActor
    public func blockingReason(tab: Tab, visible: Set<ItemID>, now: Date,
                               lastAudibleAt: Date?, lastCommitAt: Date?, downloading: Bool,
                               hasUnloadHandlers: Bool, forDiscard: Bool) -> Gate? {
        if visible.contains(tab.id) { return .visible }
        if tab.live.isAudible || recent(lastAudibleAt, now, audioProtection) { return .audible }
        if tab.live.isLoading || recent(lastCommitAt, now, loadProtection) { return .loading }
        if tab.live.isCapturing { return .capturing }
        if tab.live.devToolsOpen { return .devTools }
        if downloading { return .downloading }
        if forDiscard && hasUnloadHandlers { return .unload }
        if forDiscard && recent(tab.live.lastFormInteractionAt, now, formProtection) { return .form }
        return nil
    }

    private func recent(_ date: Date?, _ now: Date, _ interval: TimeInterval) -> Bool {
        date.map { now.timeIntervalSince($0) < interval } ?? false
    }

    @MainActor
    public func action(tab: Tab, visible: Set<ItemID>, now: Date,
                       lastAudibleAt: Date? = nil, lastCommitAt: Date? = nil,
                       downloading: Bool = false, hasUnloadHandlers: Bool = false,
                       sleptAt: Date? = nil) -> Action {
        guard blockingReason(tab: tab, visible: visible, now: now, lastAudibleAt: lastAudibleAt,
                             lastCommitAt: lastCommitAt, downloading: downloading,
                             hasUnloadHandlers: hasUnloadHandlers, forDiscard: false) == nil else { return .none }
        let age = now.timeIntervalSince(tab.lastActiveAt)
        switch tab.live.sleepPhase {
        case .placeholder: return .none
        case .live: return age >= freezeDelay ? .freeze : .none
        case .frozen:
            guard let delay = mode.discardDelay, age >= max(freezeDelay, delay),
                  blockingReason(tab: tab, visible: visible, now: now, lastAudibleAt: lastAudibleAt,
                                 lastCommitAt: lastCommitAt, downloading: downloading,
                                 hasUnloadHandlers: hasUnloadHandlers, forDiscard: true) == nil else { return .none }
            return .discard
        case .sleeping:
            return sleptAt.map { now.timeIntervalSince($0) >= destroyDelay } == true ? .destroy : .none
        }
    }
}
