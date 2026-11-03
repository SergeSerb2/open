import Foundation
import Observation
import OpenModel
import OpenWeb

@MainActor public protocol MediaDismissTask: AnyObject {
    var isPending: Bool { get }
    func cancel()
}
@MainActor public protocol MediaDismissScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any MediaDismissTask
}

/// Actual dispatch scheduler, also used by the CLI with accelerated delays. No polling.
@MainActor public final class DispatchMediaDismissScheduler: MediaDismissScheduling {
    private final class Scheduled: MediaDismissTask {
        var isPending = true
        var work: DispatchWorkItem?
        func cancel() { isPending = false; work?.cancel(); work = nil }
    }
    private let delay: (TimeInterval) -> TimeInterval
    public init(delay: @escaping (TimeInterval) -> TimeInterval = { $0 }) { self.delay = delay }
    public func schedule(after interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any MediaDismissTask {
        let scheduled = Scheduled()
        let work = DispatchWorkItem { [weak scheduled] in
            MainActor.assumeIsolated {
                guard let scheduled, scheduled.isPending else { return }
                scheduled.isPending = false; scheduled.work = nil
                action()
            }
        }
        scheduled.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay(interval)), execute: work)
        return scheduled
    }
}

/// Stable observable identity per window: views of B do not observe A's registry writes.
@MainActor @Observable public final class WindowMediaSources {
    public fileprivate(set) var allSources: [MediaSource] = []
    public fileprivate(set) var nonControllableTabIDs: Set<ItemID> = []
    fileprivate init() {}
}

/// One app-wide registry, per-window publications (PP-14, PP-18). One scheduled dismissal.
@MainActor @Observable public final class MediaSourceStore {
    public static let maxVisible = 3
    public static let pausedTimeout: TimeInterval = 3600
    public private(set) var sources: [ItemID: MediaSource] = [:]
    public private(set) var auxiliarySources: [UUID: MediaSource] = [:]
    public private(set) var pendingDismissDeadline: Date?
    public var pendingWorkItemCount: Int { dismissWork?.isPending == true ? 1 : 0 }
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let scheduler: any MediaDismissScheduling
    @ObservationIgnored private var dismissWork: (any MediaDismissTask)?
    @ObservationIgnored private var windows: [WindowID: WindowMediaSources] = [:]
    @ObservationIgnored private var sequence: UInt64 = 0
    public init(clock: @escaping () -> Date = Date.init, scheduler: any MediaDismissScheduling = DispatchMediaDismissScheduler()) {
        self.clock = clock; self.scheduler = scheduler
    }
    isolated deinit { dismissWork?.cancel() }

    public var registeredWindowCount: Int { windows.count }

    public func sourceList(windowID: WindowID) -> WindowMediaSources {
        if let list = windows[windowID] { return list }
        let list = WindowMediaSources(); windows[windowID] = list; return list
    }
    public func update(tabID: ItemID, windowID: WindowID, state: WebMediaState, isMuted: Bool, isCapturing: Bool) {
        guard state.playback != .none || isCapturing else { remove(tabID: tabID); return }
        let existing = sources[tabID]
        let source = existing ?? MediaSource(tabID: tabID, windowID: windowID)
        guard existing == nil || source.lastState != state || source.isMuted != isMuted || source.isCapturing != isCapturing || source.windowID != windowID else { return }
        let previousWindow = source.windowID
        apply(source, state: state, isMuted: isMuted, isCapturing: isCapturing)
        source.windowID = windowID
        // A source is a stable observable object. Replacing the dictionary entry on every event
        // would invalidate unrelated windows, even for an identical state.
        if existing == nil { sources[tabID] = source }
        publish(windowID); if previousWindow != windowID { publish(previousWindow) }
        reschedule()
    }
    public func updateAuxiliaryPage(pageID: UUID, windowID: WindowID, state: WebMediaState, isMuted: Bool, isCapturing: Bool) {
        guard state.playback != .none || isCapturing else { auxiliarySources.removeValue(forKey: pageID); reschedule(); return }
        let existing = auxiliarySources[pageID]
        let source = existing ?? MediaSource(pageID: pageID, windowID: windowID)
        guard existing == nil || source.lastState != state || source.isMuted != isMuted || source.isCapturing != isCapturing || source.windowID != windowID else { return }
        apply(source, state: state, isMuted: isMuted, isCapturing: isCapturing); source.windowID = windowID
        if existing == nil { auxiliarySources[pageID] = source }
        reschedule()
    }
    public func removeAuxiliaryPage(pageID: UUID) { auxiliarySources.removeValue(forKey: pageID); reschedule() }
    /// Close/archive/crash must call this even if the renderer sends no final event.
    public func remove(tabID: ItemID) {
        guard let source = sources.removeValue(forKey: tabID) else { return }
        publish(source.windowID); reschedule()
    }
    /// Step 6 owns window teardown: stop its sidebar observations, then call this on close.
    public func removeWindow(windowID: WindowID) {
        for id in sources.filter({ $0.value.windowID == windowID }).map(\.key) { sources.removeValue(forKey: id) }
        for id in auxiliarySources.filter({ $0.value.windowID == windowID }).map(\.key) { auxiliarySources.removeValue(forKey: id) }
        if let list = windows.removeValue(forKey: windowID) { list.allSources = []; list.nonControllableTabIDs = [] }
        reschedule()
    }
    public func move(tabID: ItemID, toWindow windowID: WindowID) {
        guard let source = sources[tabID], source.windowID != windowID else { return }
        let previous = source.windowID; source.windowID = windowID
        publish(previous); publish(windowID)
    }
    public func dismiss(tabID: ItemID) {
        guard let source = sources[tabID], !source.userDismissed else { return }
        source.userDismissed = true; publish(source.windowID); reschedule()
    }
    public func noteInteraction(tabID: ItemID) {
        guard let source = sources[tabID] else { return }
        source.lastInteractionAt = clock(); sequence &+= 1; source.order = sequence
        publish(source.windowID); reschedule()
    }
    public func setPiP(tabID: ItemID, _ pip: MediaSource.PiP) {
        guard let source = sources[tabID], source.pip != pip else { return }
        source.pip = pip; publish(source.windowID)
    }
    public func visibleSources(windowID: WindowID, displayed: Set<ItemID>) -> [MediaSource] {
        Array(sourceList(windowID: windowID).allSources.filter { s in
            guard let tabID = s.tabID else { return false }
            return !displayed.contains(tabID)
        }.prefix(Self.maxVisible))
    }
    /// Exactly the shown cards plus eligible non-controllable sessions. Audible/PiP gates live in OpenSleep.
    public func sleepProtectedTabIDs(windowID: WindowID, displayed: Set<ItemID>) -> Set<ItemID> {
        Set(visibleSources(windowID: windowID, displayed: displayed).compactMap(\.tabID))
            .union(sourceList(windowID: windowID).nonControllableTabIDs)
    }

    private func apply(_ source: MediaSource, state: WebMediaState, isMuted: Bool, isCapturing: Bool) {
        let old = source.playback, now = clock()
        // A meeting page has only MediaStream ("one shot") players, which Chromium never makes
        // controllable, so its playing remote audio does not make it an audio/video source.
        let kind: MediaSource.Kind = isCapturing && !(state.isControllable && state.playback == .playing) ? .recording : .audioVideo
        if source.kind != kind { source.kind = kind }
        if source.playback != state.playback { source.playback = state.playback }
        if source.isControllable != state.isControllable { source.isControllable = state.isControllable }
        if source.hasVideo != state.hasVideo { source.hasVideo = state.hasVideo }
        if source.largestVideoArea != state.largestVideoArea { source.largestVideoArea = state.largestVideoArea }
        if source.actions != state.actions { source.actions = state.actions }
        if source.isMuted != isMuted { source.isMuted = isMuted }
        if source.volume != state.volume { source.volume = state.volume }
        let microphoneOn = state.microphoneMuted.map { !$0 }
        if source.microphoneOn != microphoneOn { source.microphoneOn = microphoneOn }
        if source.cameraOn != state.cameraOn { source.cameraOn = state.cameraOn }
        source.enginePictureInPicture = state.isPictureInPicture
        if state.playback == .playing && old != .playing {
            source.lastStartedAt = now; source.userDismissed = false; sequence &+= 1; source.order = sequence
        }
        if state.playback == .paused && old != .paused { source.pausedAt = now }
        if state.playback != .paused && source.pausedAt != nil { source.pausedAt = nil }
        if source.order == 0 { sequence &+= 1; source.order = sequence }
        source.lastState = state; source.isCapturing = isCapturing
    }
    private func deadline(_ s: MediaSource) -> Date? {
        guard let paused = s.pausedAt else { return nil }
        return max(paused, s.lastInteractionAt ?? paused).addingTimeInterval(Self.pausedTimeout)
    }
    private func isExpired(_ s: MediaSource, at now: Date) -> Bool { deadline(s).map { $0 <= now } ?? false }
    private func publish(_ windowID: WindowID) {
        let list = sourceList(windowID: windowID), now = clock()
        let eligible = sources.values.filter { $0.windowID == windowID && $0.origin == .tab && !$0.userDismissed && !isExpired($0, at: now) }
        let cards = eligible.filter { s in
            // PP-19: a capturing tab gets a recording card with its microphone and camera toggles,
            // controllable or not. Without a toggle the card would have no control (guess: no card).
            let recordingCard = s.kind == .recording && !s.actions.isDisjoint(with: [.toggleMicrophone, .toggleCamera])
            guard s.isControllable || recordingCard else { return false }
            if s.enginePictureInPicture { return false }
            if case .active = s.pip { return false }
            return true
        }.sorted { $0.order > $1.order }
        if list.allSources.map(\.tabID) != cards.map(\.tabID) { list.allSources = cards }
        let protected = Set(eligible.filter { !$0.isControllable && ($0.playback == .playing || $0.playback == .paused) }.compactMap(\.tabID))
        if list.nonControllableTabIDs != protected { list.nonControllableTabIDs = protected }
    }
    private func reschedule() {
        dismissWork?.cancel(); dismissWork = nil
        let now = clock()
        pendingDismissDeadline = (Array(sources.values) + Array(auxiliarySources.values)).compactMap(deadline).filter { $0 > now }.min()
        guard let due = pendingDismissDeadline else { return }
        dismissWork = scheduler.schedule(after: max(0, due.timeIntervalSince(now))) { [weak self] in self?.expirePausedSources() }
    }
    private func expirePausedSources() {
        // Ordinary expiry retains an interactive source. A user-dismissed paused entry is
        // cleaned up at the same deadline; its next playing event creates a fresh source.
        let now = clock()
        for id in sources.filter({ $0.value.userDismissed && isExpired($0.value, at: now) }).map(\.key) { sources.removeValue(forKey: id) }
        for id in auxiliarySources.filter({ $0.value.userDismissed && isExpired($0.value, at: now) }).map(\.key) { auxiliarySources.removeValue(forKey: id) }
        for windowID in Array(windows.keys) { publish(windowID) }
        reschedule()
    }
}
