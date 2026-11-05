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
        guard let store = histories[historyProfileID] else { return }
        await actions.flushHistoryWrites()
        do { try await store.deleteVisits(); selectedIDs = []; statusText = "History cleared." }
        catch { statusText = error.localizedDescription }
        await reloadHistory()
    }
}
