import Foundation
import Observation
import OpenModel
import OpenSidebar

public struct AutoArchiveSweepReport: Sendable {
    public let now: Date
    public let archivedCount: Int
    public let affectedSpaceIDs: Set<SpaceID>
}

@MainActor
public final class TodayAutoArchiveController {
    private let model: BrowserModel
    private let preferences: UserDefaults
    private var contexts: [WindowID: SidebarContext] = [:]
    private var observing = false
    private var generation = 0
    /// Restored window states are considered shown only until initial composition finishes.
    private var composingStartup = true
    public var onScheduleInvalidated: (@MainActor () -> Void)?
    public var onDidSweep: (@MainActor (AutoArchiveSweepReport) -> Void)?
    public private(set) var educationRequested = false
    public private(set) var lastReport: AutoArchiveSweepReport?

    public init(model: BrowserModel, preferences: UserDefaults = .standard) {
        self.model = model; self.preferences = preferences
    }
    public func startObserving() {
        guard !observing else { return }
        observing = true; generation += 1; track()
    }
    public func stopObserving() {
        observing = false; generation += 1
    }
    private func track() {
        guard observing else { return }
        let current = generation
        withObservationTracking {
            // This query reads every structural/activity input, even after finding a minimum.
            _ = model.nextAutoArchiveExpiry()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.generation == current else { return }
                self.track()
                self.onScheduleInvalidated?()
            }
        }
    }
    public func nextExpiry(now: Date) -> Date? { model.nextAutoArchiveExpiry() }
    private func tabCount(_ nodes: [SidebarNode]) -> Int {
        nodes.reduce(0) { count, node in
            switch node {
            case .tab: count + 1
            case .folder(let folder): count + tabCount(folder.children)
            case .split(let split): count + split.panes.count
            }
        }
    }
    @discardableResult public func sweep(now: Date) -> Int {
        let before = Dictionary(uniqueKeysWithValues: model.spaces.map { ($0.id, tabCount($0.today)) })
        let count = model.archiveExpiredTabs(now: now)
        let affected = Set(model.spaces.filter { tabCount($0.today) < before[$0.id, default: 0] }.map(\.id))
        let report = AutoArchiveSweepReport(now: now, archivedCount: count, affectedSpaceIDs: affected)
        lastReport = report
        var shown = Set(contexts.values.compactMap { $0.focusedSpace?.id })
        if composingStartup { shown.formUnion(model.windows.filter { $0.style == .standard }.map(\.focusedSpaceID)) }
        let eligible = preferences.object(forKey: "open.sidebar.autoArchiveBannerEligible") == nil || preferences.bool(forKey: "open.sidebar.autoArchiveBannerEligible")
        if count > 0, !affected.isDisjoint(with: shown), eligible,
           !preferences.bool(forKey: "open.sidebar.autoArchiveBannerDismissed") {
            educationRequested = true
            for context in contexts.values { context.autoArchiveBannerRequested = true }
        }
        onDidSweep?(report)
        return count
    }
    public func finishStartupComposition() { composingStartup = false }
    public func attach(context: SidebarContext) {
        guard model.windows.first(where: { $0.id == context.windowID })?.style == .standard else { return }
        contexts[context.windowID] = context
        context.autoArchiveBannerRequested = educationRequested && !preferences.bool(forKey: "open.sidebar.autoArchiveBannerDismissed")
    }
    public func detach(windowID: WindowID) { contexts[windowID] = nil }
    public func dismissEducation() {
        preferences.set(true, forKey: "open.sidebar.autoArchiveBannerDismissed")
        educationRequested = false
        for context in contexts.values { context.autoArchiveBannerRequested = false }
    }
}
