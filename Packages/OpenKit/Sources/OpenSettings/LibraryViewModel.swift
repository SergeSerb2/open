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
        if oldValue != section { statusText = ""; restoredSpaceID = nil; selections[oldValue] = selectedIDs; queries[oldValue] = query; selectedIDs = selections[section] ?? []; query = queries[section] ?? "" }
        if usesLegacySpaceManager, section == .spaces, cachedSpaceManagerView == nil { refreshSpaceManagerView() }
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
    public var historyProfileID: ProfileID { didSet {
        if oldValue != historyProfileID { pendingHistoryDeletes = []; confirmsClearHistory = false; selectedIDs = [] }
    } }
    private var historyLoadRevision = 0
    private var historyLoadedIdentity = ""
    public var confirmsClearHistory = false
    public var pendingHistoryDeletes: [URL] = []
    public private(set) var historyHasMore = true
    public private(set) var historyLoading = false
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
    @ObservationIgnored private let settingsActions: (any SettingsActions)?
    @ObservationIgnored private let historyResolver: (@MainActor (ProfileID) -> HistoryStore?)?
    private var cachedSpaceManagerView: NSView?
    /// The AppKit overlay owns its cards; do not build the legacy hosted grid.
    @ObservationIgnored public var usesLegacySpaceManager = true
    /// Rendering reads the cache; section and presenter changes refresh it.
    public var spaceManagerView: NSView? { cachedSpaceManagerView }
    /// The presenter refreshes this when its browser context changes. The
    /// supplier retains a stable view until it needs a different window ID.
    public func refreshSpaceManagerView() {
        guard section == .spaces || cachedSpaceManagerView != nil else { return }
        let view = settingsActions?.makeSpaceManagerView()
        if cachedSpaceManagerView !== view { cachedSpaceManagerView = view }
    }
    public func releaseContentViews() {
        cachedSpaceManagerView = nil; rowIcons.removeAll(); iconRequests.removeAll()
        thumbnails = [:]; thumbnailImages = [:]; faviconImages = [:]; historyFaviconImages = [:]
    }
    public var boostsProvider: (any BoostsProvider)?
    public var boostsPresentation: BoostsPresentation = .list
    public private(set) var libraryBoostRows: [BoostItemSnapshot] = []
    public let downloads: any DownloadsProvider
    public let captures: any CapturesProvider
    /// Folder sources for Media (PB1). Nil in render fixtures that have no folders.
    public var mediaFolders: LibraryMediaFoldersProvider?
    public private(set) var archives: [ProfileID: ArchiveStore]
    public private(set) var histories: [ProfileID: HistoryStore]
    public let faviconStore: FaviconStore?
    private let snapshot: SnapshotStore
    private var archiveOwners: [ItemID: ProfileID] = [:]
    @ObservationIgnored private var archivedDisplayTitles: [ItemID: String] = [:]
    @ObservationIgnored private var archivedChildCounts: [ItemID: Int] = [:]
    @ObservationIgnored private var rowIcons: [URL:NSImage] = [:]
    @ObservationIgnored private var captureLocations: [UUID:URL] = [:]
    @ObservationIgnored private var iconRequests: [URL:[@MainActor (NSImage?) -> Void]] = [:]
    public func loadRowIcon(_ url:URL, completion:@escaping @MainActor (NSImage?) -> Void) {
        if let cached = rowIcons[url] { completion(cached); return }
        if iconRequests[url] != nil { if iconRequests[url]!.count < 32 { iconRequests[url]!.append(completion) }; return }
        guard iconRequests.count < 16, let faviconStore else { return }
        iconRequests[url] = [completion]
        Task { @MainActor [weak self] in
            let data = await faviconStore.icon(for:url)?.png32
            guard let self else { return }
            let image = data.flatMap { NSImage(data:$0) }
            if rowIcons.count >= 512 { rowIcons.removeAll(keepingCapacity:true) }
            if let image { rowIcons[url] = image }
            let callbacks = iconRequests.removeValue(forKey:url) ?? []
            for callback in callbacks { callback(image) }
        }
    }
    private var activeArchiveLoad = UUID()
    private var cursors: [ProfileID: Int] = [:]
    private var generation = UUID()
    public init(model: BrowserModel, defaults: UserDefaults, actions: any LibraryActions, downloads: any DownloadsProvider, captures: any CapturesProvider,
                archives: [ProfileID: ArchiveStore], histories: [ProfileID: HistoryStore], snapshot: SnapshotStore, faviconStore: FaviconStore? = nil, settingsActions: (any SettingsActions)? = nil, historyResolver: (@MainActor (ProfileID) -> HistoryStore?)? = nil) {
        SettingsDefaults.register(in: defaults)
        self.settingsActions = settingsActions
        self.historyResolver = historyResolver
        self.model = model; self.defaults = defaults; self.actions = actions; self.downloads = downloads; self.captures = captures
        self.archives = archives; self.histories = histories; self.snapshot = snapshot; self.faviconStore = faviconStore
        section = LibrarySection(rawValue: defaults.string(forKey: "open.library.lastSection") ?? "") ?? .archive
        historyProfileID = model.windows.first.flatMap { model.space(id: $0.focusedSpaceID)?.profileID } ?? model.profiles.first?.id ?? ProfileID()
    }
    /// The app supplies its shared stores when new profiles enter the model.
    public func registerStores(archives: [ProfileID: ArchiveStore], histories: [ProfileID: HistoryStore]) {
        for (id,store) in archives where self.archives[id] !== store { self.archives[id] = store }
        for (id,store) in histories where self.histories[id] !== store { self.histories[id] = store }
    }
    public func refreshProfiles() {
        let ids = Set(model.profiles.map(\.id)); histories = histories.filter { ids.contains($0.key) } // Keep injected retired-profile archives searchable.
        let directories = ProfileDirectories(root: snapshot.root)
        for profile in model.profiles {
            if archives[profile.id] == nil { archives[profile.id] = ArchiveStore(fileURL: directories.archiveFileURL(for: profile)) }
            if histories[profile.id] == nil { histories[profile.id] = historyResolver?(profile.id) ?? HistoryStore(fileURL: directories.historyFileURL(for: profile)) }
        }
        if !ids.contains(historyProfileID), let first = model.profiles.first { historyProfileID = first.id }
        if let downloadProfileFilter, !ids.contains(downloadProfileFilter) { self.downloadProfileFilter = nil }
    }
    public var filterIdentity: String { "\(section.rawValue)|\(query)|\(archiveSpaceFilter?.description ?? "")|\(archiveReasonFilter?.rawValue ?? "")|\(archiveOriginFilter.rawValue)|\(historyProfileID)" }
    public func query(for target:LibrarySection) -> String { target == section ? query : queries[target] ?? "" }
    public func refreshExternalState(for target:LibrarySection? = nil) async {
        let target = target ?? section
        refreshProfiles()
        switch target {
        case .archive: await reloadArchive(text:query(for:.archive))
        case .history: await reloadHistory(text:query(for:.history))
        case .downloads: await downloads.refreshDownloads()
        case .media,.captures:
            await (captures as? FileCapturesProvider)?.refresh()
            await mediaFolders?.refresh()
            let rows = captures.captures,directory = captures.directory
            let locations = await Task.detached(priority:.utility) {
                Dictionary(uniqueKeysWithValues:rows.compactMap { item -> (UUID,URL)? in
                    guard FileCapturesProvider.safeName(item.fileName) else { return nil }
                    let url = directory.appendingPathComponent(item.fileName)
                    guard (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == false else { return nil }
                    return (item.id,url)
                })
            }.value
            if !Task.isCancelled { captureLocations = locations }
        case .boosts:
            let profile = historyProfileID
            let rows = await boostsProvider?.libraryBoosts(profileID:profile) ?? []
            if !Task.isCancelled,profile == historyProfileID { libraryBoostRows = rows }
        default: break
        }
    }
    public func reload() async { refreshProfiles(); if section == .archive { await reloadArchive() }; if section == .history { await reloadHistory() }; if section == .downloads { await downloads.refreshDownloads() } }
    private var archiveQuery = ""
    private var archiveLoadedIdentity = ""
    public func reloadArchive(text:String? = nil) async {
        generation = UUID(); let request = generation
        archiveQuery = text ?? query
        // A reload of the same list (a delete, a restore, a newly archived tab) loads as many rows
        // as were shown, so the Library does not jump back to its first page.
        let identity = "\(archiveQuery)|\(archiveSpaceFilter?.description ?? "")|\(archiveReasonFilter?.rawValue ?? "")|\(archiveOriginFilter.rawValue)"
        let depth = identity == archiveLoadedIdentity ? archiveRows.count : 0
        var total = 0
        for store in archives.values { total += await store.count() }
        guard !Task.isCancelled,request == generation else { return }
        archiveTotalCount = total; cursors = [:]; archiveOwners = [:]; archivedChildCounts = [:]; archivedDisplayTitles = [:]; archiveRows = []; favicons = [:]; archiveHasMore = true; archiveLoading = false
        archiveLoadedIdentity = identity
        await loadNextArchivePage()
        while archiveRows.count < depth, archiveHasMore, request == generation, !Task.isCancelled {
            let loaded = archiveRows.count
            await loadNextArchivePage()
            if archiveRows.count == loaded { break }
        }
    }
    public func loadNextArchivePage() async {
        guard archiveHasMore, !archiveLoading else { return }; archiveLoading = true; let request = generation, load = UUID();activeArchiveLoad=load
        defer { if request == generation && load == activeArchiveLoad { archiveLoading = false } }
        var candidates: [(ProfileID, ArchivedTabRecord)] = []
        for (profile, store) in archives {
            let page = await store.page(offset: cursors[profile, default: 0], query: archiveQuery, spaceID: archiveSpaceFilter, reason: archiveReasonFilter, origin: archiveOriginFilter.rawValue)
            guard request == generation, !Task.isCancelled else { return }
            candidates += page.map { (profile, $0) }
        }
        let input = candidates
        let prepared = await Task.detached(priority:.userInitiated) {
            let page = Array(input.sorted { a,b in a.1.archivedAt == b.1.archivedAt ? a.1.id.description < b.1.id.description : a.1.archivedAt > b.1.archivedAt }.prefix(100))
            return page.map { profile,row in
                let custom = (try? JSONDecoder().decode(ArchivedTitle.self,from:Data(row.payloadJSON.utf8)))?.customTitle
                let title = row.kind == .folder ? row.title : custom ?? TidyTitles.tidyUncached(title:row.title,url:row.url)
                return (profile,row,title,Self.countArchivedChildren(row))
            }
        }.value
        guard !Task.isCancelled, request == generation else { return }
        for (profile, row, title, children) in prepared {
            cursors[profile, default: 0] += 1; archiveOwners[row.id] = profile
            archivedDisplayTitles[row.id] = title; archivedChildCounts[row.id] = children
        }
        archiveRows += prepared.map(\.1); archiveHasMore = prepared.count == 100; archiveLoading=false
    }
    private struct ArchivedTitle: Decodable { let customTitle: String? }
    public func archivedDisplayTitle(_ row: ArchivedTabRecord) -> String { archivedDisplayTitles[row.id] ?? row.title }

    /// Preview keeps both the archived record and the sidebar unchanged.
    public func previewArchived(id: ItemID) {
        guard let row = archiveRows.first(where: { $0.id == id && $0.kind == .tab }),
              let profile = archiveOwners[id] ?? row.profileID else { return }
        actions.previewArchived(url: row.url, profileID: profile)
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

    nonisolated private static func countArchivedChildren(_ row: ArchivedTabRecord) -> Int {
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
    public var downloadItems: [DownloadItemSnapshot] {
        let profile = downloadProfileFilter.flatMap { model.profile(id: $0)?.id }
        return downloads.downloads.filter { item in
        (downloadStateFilter == nil || item.state == downloadStateFilter || (downloadStateFilter == .inProgress && item.state == .paused)) && (profile == nil || item.profileID == profile) && (query.isEmpty || item.fileName.localizedCaseInsensitiveContains(query) || item.sourceHost.localizedCaseInsensitiveContains(query))
    } }
    public func downloadLocation(_ item: DownloadItemSnapshot) -> String {
        guard let path = item.filePath else { return "" }
        if path.hasPrefix(snapshot.root.path + "/") { return "Open Data/" + String(path.dropFirst(snapshot.root.path.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
    public func fileAvailable(_ item: DownloadItemSnapshot) -> Bool {
        if let exists = item.fileExists { return exists }
        // Historical nil means the asynchronous file check has not completed.
        // Keep the legacy-provider fallback out of that path.
        if item.isHistorical { return false }
        return item.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }
    public func revealDownload(_ item: DownloadItemSnapshot) { guard fileAvailable(item) else { statusText = "File moved or deleted."; return }; actions.revealDownload(id: item.id) }
    public func retryDownload(_ item: DownloadItemSnapshot) { guard item.state == .failed || item.isHistorical else { return }; actions.retryDownload(id: item.id) }
    public var captureItems: [CaptureItemSnapshot] {
        let filtered = captures.captures.filter { item in
            (section != .captures || item.kind != .screenshot) && (section != .media || mediaKind == "All" || (mediaKind == "Screenshots" ? item.kind == .screenshot : item.kind != .screenshot)) && (query.isEmpty || item.fileName.localizedCaseInsensitiveContains(query) || item.sourceHost.localizedCaseInsensitiveContains(query))
        }
        return filtered.sorted { a, b in if captureSort == "Name" { return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending }; return captureSort == "Oldest" ? a.createdAt < b.createdAt : a.createdAt > b.createdAt }
    }
    public func captureURL(_ item: CaptureItemSnapshot) -> URL? {
        if !usesLegacySpaceManager, let url = captureLocations[item.id] { return url }
        // A capture saved after the last Media refresh (the capture writer reloads the index while
        // the Library is open or prebuilt) is not in the off-main location map yet: check it here.
        guard FileCapturesProvider.safeName(item.fileName) else { return nil }
        let url = captures.directory.appendingPathComponent(item.fileName)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return nil }
        if !usesLegacySpaceManager { captureLocations[item.id] = url }
        return url
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
        do { try captures.remove(id: id); selectedIDs.remove(id.uuidString); thumbnails.removeValue(forKey: id); thumbnailImages.removeValue(forKey:id); actions.deleteCapture(id: id); statusText = "Capture deleted." }
        catch { statusText = "Could not delete the capture. \(error.localizedDescription)" }
    }
    public func saveCapture(_ item: CaptureItemSnapshot, to url: URL) { statusText = actions.saveCapture(id: item.id, to: url) ?? "Saved." }
    public func reloadHistory(text:String? = nil) async {
        historyLoadRevision += 1; historyLoading = false; historyHasMore = true
        historyQuery = text ?? query
        let identity = historyProfileID.description+"|"+historyQuery
        // A reload of the same list (a new visit, a delete) keeps the pages already shown, so the
        // Library does not jump back to its first page. `recent` returns at most 1,000 rows.
        let depth = identity == historyLoadedIdentity ? historyRows.count : 0
        if identity != historyLoadedIdentity { historyRows = [] }
        historyLoadedIdentity = identity
        await loadNextHistoryPage(reset:true, depth:depth)
    }
    private var historyQuery = ""
    public func loadNextHistoryPage(reset:Bool = false, depth:Int = 0) async {
        guard historyHasMore, !historyLoading else { return }
        historyLoading = true
        let revision = historyLoadRevision, profile = historyProfileID, text = historyQuery, offset = reset ? 0 : historyRows.count
        let limit = reset ? min(1_000, max(100, (depth+99)/100*100)) : 100
        defer { if revision == historyLoadRevision { historyLoading = false } }
        let rows: [HistoryMatch]
        if text.isEmpty { rows = await histories[profile]?.recent(limit:limit,offset:offset) ?? [] }
        else { rows = Array((await histories[profile]?.search(text,limit:offset+limit) ?? []).dropFirst(offset)) }
        guard revision == historyLoadRevision, profile == historyProfileID, text == historyQuery, !Task.isCancelled else { return }
        if reset { historyRows = rows } else { historyRows += rows }
        historyHasMore = rows.count == limit
        if historyFaviconImages.count > 512 { historyFavicons = [:]; historyFaviconImages = [:] }
    }
}
