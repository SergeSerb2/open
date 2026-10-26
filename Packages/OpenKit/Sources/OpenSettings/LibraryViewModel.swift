import Foundation
import AppKit
import Observation
import ImageIO
import UniformTypeIdentifiers
import OpenModel
import OpenStore

@MainActor @Observable public final class LibraryViewModel {
    public typealias Section = LibrarySection
    public var section: LibrarySection { didSet {
        defaults.set(section.rawValue, forKey: "open.library.lastSection")
        if oldValue != section { selections[oldValue] = selectedIDs; queries[oldValue] = query; selectedIDs = selections[section] ?? []; query = queries[section] ?? "" }
    } }
    private var selections: [LibrarySection: Set<String>] = [:]
    private var queries: [LibrarySection: String] = [:]
    public var query = ""
    public var archiveSpaceFilter: SpaceID?
    public var archiveReasonFilter: ArchiveReason?
    public var archiveOriginFilter: OriginFilter = .all
    public var selectedIDs: Set<String> = []
    public var statusText = ""
    public private(set) var archiveTotalCount = 0
    public private(set) var archiveRows: [ArchivedTabRecord] = []
    public private(set) var archiveHasMore = true
    public private(set) var archiveLoading = false
    public var confirmsClear = false
    public var pendingArchiveDeletes: [ItemID] = []
    public var pendingCaptureDelete: UUID?
    public var restoredSpaceID: SpaceID?
    public var downloadStateFilter: DownloadState?
    public var downloadProfileFilter: ProfileID?
    public var captureSort = "Newest"
    public var mediaKind = "All"
    public var historyProfileID: ProfileID
    public private(set) var historyRows: [HistoryMatch] = []
    public private(set) var historyFavicons: [URL: Data] = [:]
    public private(set) var thumbnailImages: [UUID: NSImage] = [:]
    public private(set) var faviconImages: [ItemID: NSImage] = [:]
    public private(set) var historyFaviconImages: [URL: NSImage] = [:]
    public private(set) var thumbnails: [UUID: Data] = [:]
    public private(set) var favicons: [ItemID: Data] = [:]
    public let defaults: UserDefaults
    public let model: BrowserModel
    public let actions: any LibraryActions
    public let downloads: any DownloadsProvider
    public let captures: any CapturesProvider
    public private(set) var archives: [ProfileID: ArchiveStore]
    public private(set) var histories: [ProfileID: HistoryStore]
    public let faviconStore: FaviconStore?
    private let snapshot: SnapshotStore
    private var archiveOwners: [ItemID: ProfileID] = [:]
    @ObservationIgnored private var archivedChildCounts: [ItemID: Int] = [:]
    private var activeArchiveLoad = UUID()
    private var cursors: [ProfileID: Int] = [:]
    private var generation = UUID()
    public init(model: BrowserModel, defaults: UserDefaults, actions: any LibraryActions, downloads: any DownloadsProvider, captures: any CapturesProvider,
                archives: [ProfileID: ArchiveStore], histories: [ProfileID: HistoryStore], snapshot: SnapshotStore, faviconStore: FaviconStore? = nil) {
        self.model = model; self.defaults = defaults; self.actions = actions; self.downloads = downloads; self.captures = captures
        self.archives = archives; self.histories = histories; self.snapshot = snapshot; self.faviconStore = faviconStore
        section = LibrarySection(rawValue: defaults.string(forKey: "open.library.lastSection") ?? "") ?? .archive
        historyProfileID = model.windows.first.flatMap { model.space(id: $0.focusedSpaceID)?.profileID } ?? model.profiles.first?.id ?? ProfileID()
    }
    public func refreshProfiles() {
        let ids = Set(model.profiles.map(\.id)); histories = histories.filter { ids.contains($0.key) } // Keep injected retired-profile archives searchable.
        let directories = ProfileDirectories(root: snapshot.root)
        for profile in model.profiles {
            if archives[profile.id] == nil { archives[profile.id] = ArchiveStore(fileURL: directories.archiveFileURL(for: profile)) }
            if histories[profile.id] == nil { histories[profile.id] = HistoryStore(fileURL: directories.historyFileURL(for: profile)) }
        }
        if !ids.contains(historyProfileID), let first = model.profiles.first { historyProfileID = first.id }
    }
    public var filterIdentity: String { "\(section.rawValue)|\(query)|\(archiveSpaceFilter?.description ?? "")|\(archiveReasonFilter?.rawValue ?? "")|\(archiveOriginFilter.rawValue)|\(historyProfileID)" }
    public func refreshExternalState() async {
        do { try (captures as? FileCapturesProvider)?.reload() }
        catch { statusText = "Could not read captures. \(error.localizedDescription)" }
        await reload()
    }
    public func reload() async { refreshProfiles(); if section == .archive { await reloadArchive() }; if section == .history { await reloadHistory() } }
    public func reloadArchive() async { var total=0; for store in archives.values {total += await store.count()};archiveTotalCount=total; generation = UUID(); cursors = [:]; archiveOwners = [:]; archivedChildCounts = [:]; archiveRows = []; favicons = [:]; archiveHasMore = true; archiveLoading = false; await loadNextArchivePage() }
    public func loadNextArchivePage() async {
        guard archiveHasMore, !archiveLoading else { return }; archiveLoading = true; let request = generation, load = UUID();activeArchiveLoad=load
        defer { if request == generation && load == activeArchiveLoad { archiveLoading = false } }
        var candidates: [(ProfileID, ArchivedTabRecord)] = []
        for (profile, store) in archives {
            let page = await store.page(offset: cursors[profile, default: 0], query: query, spaceID: archiveSpaceFilter, reason: archiveReasonFilter, origin: archiveOriginFilter.rawValue)
            guard request == generation, !Task.isCancelled else { return }
            candidates += page.map { (profile, $0) }
        }
        let page = Array(candidates.sorted { a, b in a.1.archivedAt == b.1.archivedAt ? a.1.id.description < b.1.id.description : a.1.archivedAt > b.1.archivedAt }.prefix(100))
        for (profile, row) in page {
            cursors[profile, default: 0] += 1; archiveOwners[row.id] = profile
            if row.kind == .folder { archivedChildCounts[row.id] = Self.countArchivedChildren(row) }
        }
        archiveRows += page.map(\.1); archiveHasMore = page.count == 100; archiveLoading=false
        if let faviconStore { for (_, row) in page { let icon = await faviconStore.icon(for: row.url)?.png32; guard generation == request, !Task.isCancelled else { return }
            if favicons[row.id] != icon { faviconImages[row.id]=icon.flatMap{NSImage(data:$0)} }
            favicons[row.id] = icon } }
    }
    public func restore(id: ItemID, to spaceID: SpaceID? = nil) async {
        guard !model.spaces.isEmpty else { statusText = "Create a Space before restoring this tab."; return }
        guard let row = archiveRows.first(where: { $0.id == id }), let profile = archiveOwners[id] ?? row.profileID, let store = archives[profile], var record = await store.record(id: id) else { statusText = "This archived tab is no longer available."; return }
        if let spaceID { record.spaceID = spaceID; record.originalLocation = "today:\(spaceID)" }
        let restoredID: ItemID
        do {
            if record.kind == .folder {
                guard let folder = try model.restoreArchivedFolder(record, saving: { try snapshot.saveNow(model: model) }) else {
                    statusText = "This archived folder cannot be restored."; return
                }
                restoredID = folder.id
            } else {
                restoredID = try model.restoreArchivedTab(record, saving: { try snapshot.saveNow(model: model) }).id
            }
        } catch {
            statusText = "Saving failed. The Archive entry was kept. Try Restore again."
            await reloadArchive(); return
        }
        guard model.node(id: id) != nil else { statusText = "Choose a Space before restoring this tab."; return }
        do { try await store.delete(id: id) }
        catch { statusText = "\(record.kind == .folder ? "Folder" : "Tab") restored, but its Archive entry could not be removed. \(error.localizedDescription)"; await reloadArchive(); return }
        actions.restoreArchived(id: id)
        restoredSpaceID = owningSpace(of: restoredID) ?? spaceID ?? record.spaceID
        let title = restoredSpaceID.flatMap { model.space(id: $0) }.map { model.displayTitle(for: $0) } ?? "Today"
        statusText = record.kind == .folder ? "Folder restored to \(title). Click to view." : "Restored to \(title)."; await reloadArchive()
    }
    private func owningSpace(of id: ItemID) -> SpaceID? {
        var cursor = id, seen: Set<ItemID> = []
        while seen.insert(cursor).inserted, let parent = model.parent(of: cursor) {
            switch parent {
            case .spacePinned(let id), .spaceToday(let id): return id
            case .folder(let id), .splitPane(let id): cursor = id
            case .favorites(let profile): return model.windows.compactMap { model.space(id: $0.focusedSpaceID) }.first { $0.profileID == profile }?.id ?? model.spaces.first { $0.profileID == profile }?.id
            }
        }
        return nil
    }
    public func archivedChildCount(_ row: ArchivedTabRecord) -> Int { archivedChildCounts[row.id] ?? 0 }

    private static func countArchivedChildren(_ row: ArchivedTabRecord) -> Int {
        guard row.kind == .folder, let data = row.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        func count(_ node: [String: Any]) -> Int {
            if let tab = node["tab"] as? [String: Any], tab["_0"] != nil { return 1 }
            if let split = node["split"] as? [String: Any], let value = split["_0"] as? [String: Any] { return (value["panes"] as? [Any])?.count ?? 0 }
            if let folder = node["folder"] as? [String: Any], let value = folder["_0"] as? [String: Any] { return children(value) }
            return 0
        }
        func children(_ folder: [String: Any]) -> Int { (folder["children"] as? [[String: Any]] ?? []).reduce(0) { $0 + count($1) } }
        return children(payload)
    }
    public func requestDeleteArchive(_ ids: [ItemID]) { pendingArchiveDeletes = ids }
    public private(set) var archiveResults: [ProfileID: String] = [:]
    public func deleteArchiveConfirmed() async {
        let ids = pendingArchiveDeletes; pendingArchiveDeletes = []; archiveResults = [:]
        let grouped = Dictionary(grouping: ids, by: { archiveOwners[$0] })
        for (owner, ownedIDs) in grouped {
            guard let owner, let store = archives[owner] else { continue }
            do {
                try await store.delete(ids: ownedIDs)
                for id in ownedIDs { actions.deleteArchived(id: id) }
                archiveResults[owner] = "Deleted \(ownedIDs.count.formatted())."
            } catch { archiveResults[owner] = "Failed: \(error.localizedDescription)" }
        }
        let missing=ids.contains{archiveOwners[$0] == nil}
        statusText = [archiveResultText(),missing ? "This archived tab is no longer available." : ""].filter{!$0.isEmpty}.joined(separator:" · ")
        await reloadArchive()
    }
    public func requestClearArchive() { confirmsClear = true }
    public func clearArchiveConfirmed() async {
        confirmsClear = false; archiveResults = [:]
        for (owner, store) in archives {
            do { try await store.deleteAll(); archiveResults[owner] = "Archive cleared." }
            catch { archiveResults[owner] = "Failed: \(error.localizedDescription)" }
        }
        if !archiveResults.values.contains(where: { $0.hasPrefix("Failed:") }) { actions.clearArchive() }
        statusText = archiveResultText(); await reloadArchive()
    }
    private func archiveResultText() -> String {
        archiveResults.sorted { $0.key.description < $1.key.description }.map { owner, result in
            "\(model.profile(id: owner)?.name ?? "Retired Profile"): \(result)"
        }.joined(separator: " · ")
    }
    public var downloadItems: [DownloadItemSnapshot] { downloads.downloads.filter { item in
        (downloadStateFilter == nil || item.state == downloadStateFilter || (downloadStateFilter == .inProgress && item.state == .paused)) && (downloadProfileFilter == nil || item.profileID == downloadProfileFilter) && (query.isEmpty || item.fileName.localizedCaseInsensitiveContains(query) || item.sourceHost.localizedCaseInsensitiveContains(query))
    } }
    public func downloadLocation(_ item: DownloadItemSnapshot) -> String {
        guard let path = item.filePath else { return "" }
        if path.hasPrefix(snapshot.root.path + "/") { return "Open Data/" + String(path.dropFirst(snapshot.root.path.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
    public func fileAvailable(_ item: DownloadItemSnapshot) -> Bool { item.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    public func revealDownload(_ item: DownloadItemSnapshot) { guard fileAvailable(item) else { statusText = "File moved or deleted."; return }; actions.revealDownload(id: item.id) }
    public func retryDownload(_ item: DownloadItemSnapshot) { guard item.state == .failed else { return }; actions.retryDownload(id: item.id) }
    public var captureItems: [CaptureItemSnapshot] {
        let filtered = captures.captures.filter { item in
            (section != .captures || item.kind != .screenshot) && (section != .media || mediaKind == "All" || (mediaKind == "Screenshots" ? item.kind == .screenshot : item.kind != .screenshot)) && (query.isEmpty || item.fileName.localizedCaseInsensitiveContains(query) || item.sourceHost.localizedCaseInsensitiveContains(query))
        }
        return filtered.sorted { a, b in if captureSort == "Name" { return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending }; return captureSort == "Oldest" ? a.createdAt < b.createdAt : a.createdAt > b.createdAt }
    }
    public func captureURL(_ item: CaptureItemSnapshot) -> URL? {
        guard FileCapturesProvider.safeName(item.fileName) else { return nil }
        let url = captures.directory.appendingPathComponent(item.fileName)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return nil }; return url
    }
    public func captureBytes(_ item: CaptureItemSnapshot) -> Int64 { guard let url = captureURL(item) else { return 0 }; return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    public func loadThumbnail(_ item: CaptureItemSnapshot) async {
        guard thumbnails[item.id] == nil, let url = captureURL(item) else { return }
        let data = await Task.detached(priority: .utility) { () -> Data? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            let output = NSMutableData(); guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil); guard CGImageDestinationFinalize(destination) else { return nil }; return output as Data
        }.value
        if thumbnails.count >= 128 { thumbnails.removeAll(keepingCapacity: true);thumbnailImages.removeAll(keepingCapacity:true) }; thumbnails[item.id] = data;thumbnailImages[item.id]=data.flatMap{NSImage(data:$0)}
    }
    public func deleteCaptureConfirmed() {
        guard let id = pendingCaptureDelete else { return }; pendingCaptureDelete = nil
        do { try captures.remove(id: id); thumbnails.removeValue(forKey: id); thumbnailImages.removeValue(forKey:id); actions.deleteCapture(id: id); statusText = "Capture deleted." }
        catch { statusText = "Could not delete the capture. \(error.localizedDescription)" }
    }
    public func saveCapture(_ item: CaptureItemSnapshot, to url: URL) { statusText = actions.saveCapture(id: item.id, to: url) ?? "Saved." }
    public func reloadHistory() async { let profile = historyProfileID, text = query; let rows = await histories[profile]?.search(text, limit: 100) ?? []; guard profile == historyProfileID, text == query, !Task.isCancelled else { return }; historyRows = rows; if historyFaviconImages.count > 512 {historyFavicons=[:];historyFaviconImages=[:]}; if let faviconStore { for row in rows { let data = await faviconStore.icon(for: row.url)?.png32; guard profile == historyProfileID, text == query, !Task.isCancelled else {return}; if historyFavicons[row.url] != data {historyFaviconImages[row.url]=data.flatMap{NSImage(data:$0)}};historyFavicons[row.url] = data } } }
}
