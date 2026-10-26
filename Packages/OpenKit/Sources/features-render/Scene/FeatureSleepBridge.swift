import Foundation
import OpenModel
import OpenFeatures
import OpenSleep
import OpenStore

/// Harness adapter to the actual SQLite history store, as in the openkit CLI.
@MainActor
final class FeatureSleepStore: SleepHistoryStoring {
    let disk: SleepStore
    init(fileURL: URL) { disk = SleepStore(fileURL: fileURL) }
    func save(tabID: ItemID, envelope e: SleepHistoryEnvelope) async throws {
        try await disk.save(SleepHistoryRecord(tabID: tabID, container: e.container, currentIndex: e.currentIndex,
            entryCount: e.entryCount, currentURL: e.currentURL, currentTitle: e.currentTitle, faviconURL: e.faviconURL,
            hasPageState: e.hasPageState, containerVersion: e.containerVersion, chromiumTag: e.chromiumTag, capturedAt: e.capturedAt))
    }
    func flush() async throws { try await disk.flush() }
    func sleepHistory(tabID: ItemID) async -> SleepHistoryEnvelope? {
        guard let r = await disk.load(tabID: tabID) else { return nil }
        return SleepHistoryEnvelope(container: r.container, currentIndex: r.currentIndex, entryCount: r.entryCount,
            currentURL: r.currentURL, currentTitle: r.currentTitle, faviconURL: r.faviconURL,
            hasPageState: r.hasPageState, containerVersion: r.containerVersion, chromiumTag: r.chromiumTag, capturedAt: r.capturedAt)
    }
    func deleteSleepHistory(tabID: ItemID) { disk.delete(tabID: tabID) }
}

/// Keeps the single fake boundary at WebContentHost for the visibility flow.
/// No discard/history support is claimed for these colored pages.
@MainActor
final class FeatureSleepHostBridge: SleepEngine {
    let container: WebContentContainer
    init(container: WebContentContainer) { self.container = container }
    func createContent(tabID: ItemID, url: URL, history: SleepHistoryEnvelope?) async -> Bool {
        container.refreshPlaceholders()
        return container.host(for: tabID) != nil
    }
    func destroyContent(tabID: ItemID) { container.closeHost(for: tabID) }
    func setVisible(tabID: ItemID, visible: Bool) { container.host(for: tabID)?.view.isHidden = !visible }
    func freeze(tabID: ItemID) -> Bool { false }
    func discard(tabID: ItemID) async -> Bool { false }
    func wasDiscarded(tabID: ItemID) -> Bool { false }
    func captureHistory(tabID: ItemID) -> SleepHistoryEnvelope? { nil }
    func hasUnloadHandlers(tabID: ItemID) -> Bool { false }
    func handleCriticalPressure() {}
}
