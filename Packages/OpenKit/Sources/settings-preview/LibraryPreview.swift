import Foundation
import Observation
import OpenSettings
import OpenModel
import OpenStore

@MainActor @Observable final class PreviewDownloads: DownloadsProvider {
    var downloads: [DownloadItemSnapshot]
    init(_ downloads: [DownloadItemSnapshot]) { self.downloads = downloads }
}
@MainActor final class PreviewLibraryActions: LibraryActions {
    var log: [String] = []
    let model: BrowserModel
    let downloads: PreviewDownloads
    let captures: FileCapturesProvider
    let snapshot: SnapshotStore
    var selectedHistoryProfile: (() -> ProfileID?)?
    init(model: BrowserModel, downloads: PreviewDownloads, captures: FileCapturesProvider, snapshot: SnapshotStore) { self.model = model; self.downloads = downloads; self.captures = captures; self.snapshot = snapshot }
    func record(_ text: String) { log.append(text); print("ACTION \(text)") }
    func restoreArchived(id: ItemID) { record("restoreArchived \(id)") }
    func deleteArchived(id: ItemID) { record("deleteArchived \(id)") }
    func clearArchive() { record("clearArchive") }
    func revealDownload(id: String) { record("revealDownload \(id)") }
    func retryDownload(id: String) { record("retryDownload \(id)"); if let i = downloads.downloads.firstIndex(where: { $0.id == id }) { downloads.downloads[i].state = .inProgress } }
    func cancelDownload(id: String) { record("cancelDownload \(id)"); if let i = downloads.downloads.firstIndex(where: { $0.id == id }) { downloads.downloads[i].state = .cancelled } }
    func pauseDownload(id: String) { record("pauseDownload \(id)"); if let i = downloads.downloads.firstIndex(where: { $0.id == id }) { downloads.downloads[i].state = .paused } }
    func resumeDownload(id: String) { record("resumeDownload \(id)"); if let i = downloads.downloads.firstIndex(where: { $0.id == id }) { downloads.downloads[i].state = .inProgress } }
    func openDownload(id: String) { record("openDownload \(id)") }
    func removeDownload(id: String) { record("removeDownload \(id)"); downloads.downloads.removeAll { $0.id == id } }
    func deleteCapture(id: UUID) { record("deleteCapture \(id)") }
    func revealCapture(id: UUID) { record("revealCapture \(id)") }
    func openCapture(id: UUID) { record("openCapture \(id)") }
    func copyCapture(id: UUID) { record("copyCapture \(id)") }
    func saveCapture(id: UUID, to url: URL) -> String? {
        record("saveCapture \(id)")
        guard let item = captures.captures.first(where: { $0.id == id }) else { return "Capture missing." }
        do { try Data(contentsOf: captures.directory.appendingPathComponent(item.fileName)).write(to: url, options: .atomic); return nil } catch { return "Could not save capture." }
    }
    func openHistoryItem(url: URL) { record("openHistoryItem"); if let space = model.spaces.first(where: { $0.profileID == selectedHistoryProfile?() }) ?? model.spaces.first { _ = model.newTab(in: space.id, url: url); try? snapshot.saveNow(model: model) } }
    func viewSpace(id: SpaceID) { record("viewSpace \(id)") }
}
