import Foundation
import Observation
import OpenModel
import OpenWeb

/// One app-wide registry, per-window views (PP-14, PP-18). No polling timer.
@MainActor @Observable public final class MediaSourceStore {
    public static let maxVisible = 3
    public static let pausedTimeout: TimeInterval = 3600
    public private(set) var sources: [ItemID: MediaSource] = [:]
    public private(set) var pendingDismissDeadline: Date?
    public var pendingWorkItemCount: Int { pendingDismissDeadline == nil ? 0 : 1 }
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var dismissWork: DispatchWorkItem?
    @ObservationIgnored private var sequence: UInt64 = 0
    public init(clock: @escaping () -> Date = Date.init) { self.clock = clock }
    isolated deinit { dismissWork?.cancel() }

    public func update(tabID: ItemID, windowID: WindowID, state: WebMediaState, isMuted: Bool, isCapturing: Bool) {
        guard (state.isControllable && state.playback != .none) || isCapturing else { remove(tabID: tabID); return }
        let source = sources[tabID] ?? MediaSource(tabID: tabID, windowID: windowID)
        let old = source.playback, now = clock()
        source.windowID = windowID; source.kind = isCapturing && state.playback != .playing ? .recording : .audioVideo
        source.playback = state.playback; source.hasVideo = state.hasVideo; source.largestVideoArea = state.largestVideoArea
        source.actions = state.actions; source.isMuted = isMuted; source.volume = state.volume
        source.microphoneOn = state.microphoneMuted.map { !$0 }; source.cameraOn = state.cameraOn
        if state.playback == .playing && old != .playing {
            source.lastStartedAt = now; source.dismissed = false; sequence &+= 1; source.order = sequence
        }
        if state.playback == .paused && old != .paused { source.pausedAt = now }
        if state.playback != .paused { source.pausedAt = nil }
        if sources[tabID] == nil && source.order == 0 { sequence &+= 1; source.order = sequence }
        sources[tabID] = source
        reschedule()
    }
    public func remove(tabID: ItemID) { sources.removeValue(forKey: tabID); reschedule() }
    public func dismiss(tabID: ItemID) { sources[tabID]?.dismissed = true; reschedule() }
    public func noteInteraction(tabID: ItemID) {
        guard let source = sources[tabID] else { return }
        source.lastInteractionAt = clock(); sequence &+= 1; source.order = sequence; reschedule()
    }
    public func setPiP(tabID: ItemID, _ pip: MediaSource.PiP) { sources[tabID]?.pip = pip }
    public func visibleSources(windowID: WindowID, displayed: Set<ItemID>) -> [MediaSource] {
        let now = clock()
        return Array(sources.values.filter { s in
            s.windowID == windowID && !displayed.contains(s.tabID) && !s.dismissed && !isExpired(s, at: now)
                && { if case .active = s.pip { return false }; return true }()
        }.sorted { $0.order > $1.order }.prefix(Self.maxVisible))
    }
    private func deadline(_ s: MediaSource) -> Date? {
        guard s.kind != .recording, let paused = s.pausedAt, !s.dismissed else { return nil }
        return max(paused, s.lastInteractionAt ?? paused).addingTimeInterval(Self.pausedTimeout)
    }
    private func isExpired(_ s: MediaSource, at now: Date) -> Bool { deadline(s).map { $0 <= now } ?? false }
    private func reschedule() {
        dismissWork?.cancel(); dismissWork = nil
        let now = clock()
        pendingDismissDeadline = sources.values.compactMap(deadline).filter { $0 > now }.min()
        guard let due = pendingDismissDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.expirePausedSources() }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSince(now)), execute: work)
    }
    private func expirePausedSources() {
        let now = clock()
        for source in sources.values where isExpired(source, at: now) { source.dismissed = true }
        reschedule()
    }
}
