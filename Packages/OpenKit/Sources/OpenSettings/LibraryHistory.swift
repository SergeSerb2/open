import Foundation

extension LibraryViewModel {
    /// The view's task owns this subscription and cancels it on section/profile/query changes.
    public func watchHistory() async {
        refreshProfiles()
        guard section == .history, let store = histories[historyProfileID] else { return }
        let changes = await store.changes()
        for await _ in changes {
            guard !Task.isCancelled, section == .history else { return }
            await reloadHistory()
        }
    }

    public func requestDeleteHistory(_ urls: [URL]) { pendingHistoryDeletes = urls }
    public func deleteHistoryConfirmed() async {
        let urls = pendingHistoryDeletes, profile = historyProfileID
        pendingHistoryDeletes = []
        guard !urls.isEmpty, let store = histories[profile] else { return }
        await actions.flushHistoryWrites()
        do { try await store.deleteVisits(urls: urls); selectedIDs.subtract(urls.map(\.absoluteString)); statusText = "History deleted." }
        catch { statusText = error.localizedDescription }
        await reloadHistory()
    }

    public func clearHistoryConfirmed() async {
        confirmsClearHistory = false
        // The Profile at confirm time: the filter can change during the awaits (review r1 #3).
        let profileID = historyProfileID
        guard let store = histories[profileID] else { return }
        await actions.flushHistoryWrites()
        do {
            // All of it, also visits with a future time (a clock that was ahead); pending writes were
            // flushed just above, and the engine clear below has no end either (review r2 #4).
            try await store.deleteVisits(through: .distantFuture); selectedIDs = []; statusText = "History cleared."
            // Not only Open's list: the engine keeps its own copy (bug sweep r6 DHR-01).
            await actions.clearEngineHistory(profileID: profileID)
        }
        catch { statusText = error.localizedDescription }
        await reloadHistory()
    }
}
