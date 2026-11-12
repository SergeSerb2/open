import Foundation
import Observation
import OpenSettings
import OpenModel
import OpenStore

@MainActor @Observable final class PreviewDownloads: DownloadsProvider {
    var downloads: [DownloadItemSnapshot]
    init(_ downloads: [DownloadItemSnapshot]) { self.downloads = downloads }
}
@MainActor final class PreviewLibraryActions: LibraryActions, BoostsProvider {
    var boostRows: [ProfileID: [BoostItemSnapshot]] = [:]
    func boosts(profileID: ProfileID) -> [BoostItemSnapshot] { boostRows[profileID] ?? [] }
    func setBoostEnabled(id: String, enabled: Bool, profileID: ProfileID) { record("setBoostEnabled \(id) \(enabled) \(profileID)") }
    func renameBoost(id: String, to name: String, profileID: ProfileID) { record("renameBoost \(id) \(profileID)") }
    func deleteBoost(id: String, profileID: ProfileID) { record("deleteBoost \(id) \(profileID)") }
    func editBoost(id: String, profileID: ProfileID) { record("editBoost \(id) \(profileID)") }
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

import AppKit
import SwiftUI
import OpenLibrary
import OpenSidebar
import OpenSettings

/// Preview the same native Library used by the app. The removed separate
/// window/source-list implementation has no rendering path in this executable.
struct LibraryPreview: NSViewRepresentable {
    let viewModel: LibraryViewModel
    func makeNSView(context: Context) -> LibraryPanelView {
        let sidebar = SidebarContext(model:viewModel.model,windowID:viewModel.model.windows[0].id)
        sidebar.systemAppearance = .dark
        let panel = LibraryPanelView(viewModel:viewModel,context:sidebar)
        panel.isPresented = true
        return panel
    }
    func updateNSView(_ view: LibraryPanelView, context: Context) {
        let section = LibraryPanelSection(viewModel.section)
        // A representable update must not write the same observed section back.
        // Doing so schedules another SwiftUI update while rendering the preview.
        if view.section != section { view.select(section,animated:false) }
    }
    static func dismantleNSView(_ view: LibraryPanelView, coordinator: ()) {
        view.isPresented = false
    }
}
