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
                       sleptAt: Date? = nil, hiddenAt: Date? = nil) -> Action {
        let action = timedAction(phase: tab.live.sleepPhase, hiddenAt: hiddenAt ?? tab.lastActiveAt,
                                 sleptAt: sleptAt, now: now)
        guard action != .none,
              blockingReason(tab: tab, visible: visible, now: now, lastAudibleAt: lastAudibleAt,
                             lastCommitAt: lastCommitAt, downloading: downloading,
                             hasUnloadHandlers: hasUnloadHandlers, forDiscard: action == .discard) == nil else { return .none }
        return action
    }

    /// Check phase deadlines before reading the more expensive runtime gates.
    /// A sleeping tab needs no hide clock; a frozen tab in off mode needs no work.
    public func timedAction(phase: SleepPhase, hiddenAt: Date, sleptAt: Date?, now: Date) -> Action {
        switch phase {
        case .placeholder: return .none
        case .live: return now.timeIntervalSince(hiddenAt) >= freezeDelay ? .freeze : .none
        case .frozen:
            guard let delay = mode.discardDelay else { return .none }
            return now.timeIntervalSince(hiddenAt) >= max(freezeDelay, delay) ? .discard : .none
        case .sleeping:
            return sleptAt.map { now.timeIntervalSince($0) >= destroyDelay } == true ? .destroy : .none
        }
    }
}
