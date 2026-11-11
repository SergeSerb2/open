import AppKit
import Darwin
import Observation
import OpenEngine
import OpenFeatures
import OpenModel
import OpenSettings
import OpenSidebar
import OpenStore

/// All disk work stays off the main actor. Serialized name claims separate
/// simultaneous requests without leaving empty files. Chromium also uniquifies
/// the final path if another process creates it before the transfer opens it.
actor DownloadFiles {
  private var claims: Set<URL> = []
  private let defaultDirectory: URL?
  init(defaultDirectory: URL? = nil) { self.defaultDirectory = defaultDirectory }
  struct Destination: Sendable { let url: URL; let fellBack: Bool }
  func directory(_ path: String) throws -> Destination {
    let standard = defaultDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    let requested = path.isEmpty || path == "~/Downloads" ? standard : URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory)
    if exists && isDirectory.boolValue { return Destination(url: requested, fellBack: false) }
    try FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
    return Destination(url: standard, fellBack: requested != standard)
  }
  func unique(in directory: URL, name: String) throws -> URL {
    let file = URL(fileURLWithPath: name)
    let ext = file.pathExtension
    let stem = ext.isEmpty ? name : file.deletingPathExtension().lastPathComponent
    // Bounded 10,000 filesystem operations, each name <= Int(NAME_MAX) bytes.
    for index in 0..<10_000 {
      let candidate = index == 0 ? name : stem + " (\(index))" + (ext.isEmpty ? "" : "." + ext)
      guard candidate.utf8.count <= Int(NAME_MAX) else { throw CocoaError(.fileWriteInvalidFileName) }
      let url = directory.appendingPathComponent(candidate)
      if !claims.contains(url), !FileManager.default.fileExists(atPath: url.path) {
        claims.insert(url); return url
      }
    }
    throw CocoaError(.fileWriteFileExists)
  }
  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
  struct FileCheck: Sendable { let id: String; let path: String? }
  struct Availability: Sendable { let check: FileCheck; let exists: Bool }
  func availability(for checks: [FileCheck]) throws -> [Availability] {
    var results: [Availability] = []
    for check in checks {
      try Task.checkCancellation()
      let exists = check.path.map { FileManager.default.fileExists(atPath: $0) } ?? false
      results.append(Availability(check: check, exists: exists))
    }
    return results
  }
  func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
  func release(_ url: URL) { claims.remove(url) }
}

/// Live state plus lazy per-Profile terminal history. Engine callbacks are the sole progress source.
/// One queued main-actor turn publishes a burst, following ObservationLoop.
@MainActor @Observable
final class DownloadsCenter: DownloadsProvider, ProfileDataOwner {
  unowned let app: AppDelegate
  @ObservationIgnored let files: DownloadFiles
  @ObservationIgnored private var entries: [String: Entry] = [:]
  @ObservationIgnored private var detachedPages: [ObjectIdentifier: (page: OEWebContent, close: () -> Void)] = [:]
  @ObservationIgnored private var order: [String] = []
  @ObservationIgnored private(set) var littleOpenTrays: [WindowID: LittleOpenDownloadsTray] = [:]
  @ObservationIgnored private var publishQueued = false
  @ObservationIgnored private(set) var choices: [String: DownloadDestinationChoice] = [:]
  @ObservationIgnored private var reserved: [String: URL] = [:]
  @ObservationIgnored private var suggestedNames: [String: String] = [:]
  @ObservationIgnored private var completedAt: [ProfileID: Date] = [:]
  @ObservationIgnored private let sessionID = UUID().uuidString
  @ObservationIgnored private var historyStores: [ProfileID: DownloadHistoryStore] = [:]
  @ObservationIgnored private var history: [String: DownloadItemSnapshot] = [:]
  @ObservationIgnored private var loadedHistory: Set<ProfileID> = []
  @ObservationIgnored private var historyRevisions: [ProfileID: Int] = [:]
  @ObservationIgnored private var retiredProfiles: Set<ProfileID> = []
  @ObservationIgnored private var historyLoadTask: Task<Void, Never>?
  @ObservationIgnored private var historyWriteRevision = 0
  @ObservationIgnored private var flushedHistoryRevision = 0
  @ObservationIgnored private var historyMutations: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var removedHistory: Set<String> = []
  @ObservationIgnored private var inFlightHistoryClears: [UUID: HistoryClearRange] = [:]
  // Only needed until the current lazy load settles. These ranges reject rows
  // from an older read even after its two allowed retries have been used.
  @ObservationIgnored private var clearedHistoryDuringLoad: [HistoryClearRange] = []
  @ObservationIgnored private var fileRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var fileRefreshQueued = false
  @ObservationIgnored private var fileRefreshGeneration = 0
  private(set) var downloadHistoryError = ""
  private(set) var downloads: [DownloadItemSnapshot] = []
  @ObservationIgnored private var completionFiles: [DownloadBadgeFile] = []
  @ObservationIgnored private var badgeExpiry: DispatchWorkItem?
  private var badgeLifetime: TimeInterval {
    #if OPEN_AUTOMATION
    return badgeLifetimeForAutomation
    #else
    return 60
    #endif
  }
  private(set) var publishCount = 0
  private(set) var updateCount = 0
  private(set) var fallbackCount = 0
  private(set) var lastFileError = ""
  @ObservationIgnored private var quitApproved = false
  @ObservationIgnored private(set) var presentingQuitAlert = false
  #if OPEN_AUTOMATION
  var badgeLifetimeForAutomation: TimeInterval = 60
  var badgeExpiryScheduledForAutomation: Bool { badgeExpiry != nil }
  var recordFileActions = false
  var detachedPageCountForAutomation: Int { detachedPages.count }
  var fileOpenerForAutomation: URL?
  private(set) var fileOpenerPID: Int32 = 0
  private(set) var fileActions: [[String: String]] = []
  var quitAlertPolicy: String?
  private(set) var quitAlerts: [[String: Any]] = []
  // One real download callback stream can be held across the destination
  // boundary, to prove attribution before its source host is detached.
  var holdProgressForAutomation = false
  private var heldProgressForAutomation: (OEDownload, OEBrowserContext)?
  var afterDestinationForAutomation: ((String) -> Void)?
  func releaseProgressForAutomation() {
    holdProgressForAutomation = false
    let held = heldProgressForAutomation; heldProgressForAutomation = nil
    if let held { updated(held.0, context: held.1) }
  }
  func sourceSessionForAutomation(_ key: String) -> String? { entries[key]?.littleOpenSessionID?.description }
  /// Ages a real engine transfer for range-boundary e2e fixtures, never creates rows.
  func setStartForAutomation(_ key: String, age: TimeInterval) -> Bool {
    guard entries[key] != nil, age.isFinite, (0...31_536_000).contains(age) else { return false }
    let start = Date().addingTimeInterval(-age)
    let end = entries[key]?.snapshot.endedAt ?? start
    entries[key]?.snapshot.startedAt = min(start, end)
    if let entry = entries[key], let profile = app.model.profile(id: entry.snapshot.profileID) { persist(entry.snapshot, profile: profile) }
    schedulePublish()
    return true
  }
  #endif
  private struct Entry {
    let download: OEDownload
    let littleOpenSessionID: WindowID?
    var snapshot: DownloadItemSnapshot
    var hidden = false
  }
  private struct HistoryClearRange {
    let profileID: ProfileID
    let start: Date?
    let end: Date
    func contains(profileID: ProfileID, startedAt: Date) -> Bool {
      self.profileID == profileID && startedAt <= end && (start.map { startedAt >= $0 } ?? true)
    }
    func contains(_ item: DownloadItemSnapshot) -> Bool { contains(profileID: item.profileID, startedAt: item.startedAt) }
  }
  init(app: AppDelegate) {
    self.app = app
    #if OPEN_AUTOMATION
    // The e2e default folder is a real directory in its disposable root, so
    // fallback/creation does not ask for access to a user's protected folder.
    let path = ProcessInfo.processInfo.environment["OPEN_DOWNLOADS_DEFAULT_DIRECTORY"]
    files = DownloadFiles(defaultDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) })
    #else
    files = DownloadFiles()
    #endif
    app.profileTeardown.register(self)
  }
  func profile(for context: OEBrowserContext) -> Profile? {
    // Do not infer a regular Profile from a private context's parent/directory.
    guard !context.isEphemeral, context.originalContext == nil else { return nil }
    return app.model.profiles.first { $0.id.description == context.identifier || app.directories.engineDirectory(for: $0).standardizedFileURL == context.directory?.standardizedFileURL }
      ?? (context === OEEngine.shared.defaultContext ? app.model.defaultProfile : nil)
  }
  /// Chromium's download callbacks belong to the source browser. Detach its UI
  /// now, but keep that browser until its last transfer reaches a terminal state.
  func retainDetachedPage(_ page: OEWebContent, close: @escaping () -> Void) -> Bool {
    guard !app.shutdownPrepared, !app.terminationRequested, page.context.downloads.contains(where: {
      $0.webContent === page && ($0.state == .pending || $0.state == .inProgress)
    }) else { return false }
    detachedPages[ObjectIdentifier(page)] = (page, close)
    return true
  }
  func closeDetachedPages(profileID: ProfileID? = nil, force: Bool = true) {
    for (id, detached) in Array(detachedPages) {
      if let profileID, profile(for: detached.page.context)?.id != profileID { continue }
      if !force, detached.page.context.downloads.contains(where: {
        $0.webContent === detached.page && ($0.state == .pending || $0.state == .inProgress)
      }) { continue }
      detachedPages[id] = nil
      detached.close()
    }
  }
  func id(_ download: OEDownload, _ context: OEBrowserContext) -> String { "\(sessionID):\(context.identifier):\(download.identifier)" }
  var hasRunning: Bool { entries.values.contains { $0.snapshot.state == .inProgress || $0.snapshot.state == .paused } || !choices.isEmpty }
  func decide(_ download: OEDownload, context: OEBrowserContext, filename: String, window: NSWindow?, directoryOverride: URL? = nil, completion: @escaping @MainActor (URL?) -> Void) {
    guard let profile = profile(for: context) else { completion(nil); return }
    let key = id(download, context)
    let name = filename.isEmpty ? "download" : (filename as NSString).lastPathComponent
    guard ![".", "..", "/"].contains(name), name.utf8.count <= Int(NAME_MAX) else { completion(nil); return }
    suggestedNames[key] = name
    // Capture while the source host still belongs to its Little Open session,
    // before choosing a destination yields or the user moves/closes the page.
    updated(download, context: context, atDestination: true)
    let path = directoryOverride?.path ?? profile.settings.downloadDirectory
    let ask = directoryOverride == nil && profile.settings.askWhereToSaveEachFile
    Task { [weak self, weak window] in
      guard let self else { completion(nil); return }
      do {
        let directory = try await files.directory(path)
        guard !app.terminationRequested, !retiredProfiles.contains(profile.id), app.model.profile(id: profile.id) != nil else { completion(nil); return }
        if directory.fellBack {
          fallbackCount += 1
          AppDelegate.commandLog("download-directory-fallback")
        }
        if ask {
          guard let parent = window ?? app.frontWindowController?.window else { completion(nil); return }
          let choice = DownloadDestinationChoice { [weak self] url in
            self?.choices[key] = nil
            completion(url)
          }
          choices[key] = choice
          choice.present(in: parent, filename: name, directory: directory.url)
        } else {
          let url = try await files.unique(in: directory.url, name: name)
          guard !app.terminationRequested, !retiredProfiles.contains(profile.id), app.model.profile(id: profile.id) != nil else { await files.release(url); completion(nil); return }
          reserved[key] = url
          completion(url)
          #if OPEN_AUTOMATION
          let after = afterDestinationForAutomation; afterDestinationForAutomation = nil
          after?(key)
          #endif
        }
      } catch { lastFileError = error.localizedDescription; completion(nil) }
    }
  }
  func updated(_ download: OEDownload, context: OEBrowserContext, atDestination: Bool = false) {
    guard let profile = profile(for: context) else { return }
    #if OPEN_AUTOMATION
    if holdProgressForAutomation && !atDestination {
      heldProgressForAutomation = (download, context); return
    }
    #endif
    updateCount += 1
    let key = id(download, context), previous = entries[key]
    let state: DownloadState
    switch download.state {
    case .complete: state = .completed
    case .cancelled: state = .cancelled
    case .interrupted: state = .failed
    default:
      // A queued progress callback cannot undo the user's approved quit cancellation.
      state = quitApproved && previous?.snapshot.state == .cancelled ? .cancelled
        : (previous?.snapshot.state == .paused ? .paused : .inProgress)
    }
    let name = [download.destinationURL?.lastPathComponent, download.suggestedFilename,
      suggestedNames[key], previous?.snapshot.fileName].compactMap { $0 }.first { !$0.isEmpty } ?? "download"
    var snapshot = DownloadItemSnapshot(id: key, fileName: name,
      sourceHost: download.sourceURL.host() ?? "", receivedBytes: download.receivedBytes,
      totalBytes: download.totalBytes > 0 ? download.totalBytes : nil, state: state,
      filePath: download.destinationURL?.path, startedAt: previous?.snapshot.startedAt ?? Date(), profileID: profile.id)
    snapshot.bytesPerSecond = download.bytesPerSecond
    snapshot.sourceURL = download.sourceURL
    let terminal = state == .completed || state == .failed || state == .cancelled
    snapshot.endedAt = terminal ? (state == previous?.snapshot.state ? previous?.snapshot.endedAt ?? Date() : Date()) : nil
    snapshot.fileExists = state == .completed && previous?.snapshot.state != .completed
      ? download.destinationURL != nil : previous?.snapshot.fileExists ?? false
    // Retry a missing link on each callback. Once known it never follows focus,
    // a view's window, or a later Profile/session hosting the same URL.
    let source = previous?.littleOpenSessionID ?? download.webContent.flatMap { page in
      app.littleOpenHosts.values.first { $0.content === page }?.owner?.littleOpenController?.session.id
    }
    entries[key] = Entry(download: download, littleOpenSessionID: source, snapshot: snapshot, hidden: previous?.hidden ?? removedHistory.contains(key))
    if let source, littleOpenTrays[source] == nil, let controller = app.littleOpenCoordinator?.controllers[source] {
      littleOpenTrays[source] = LittleOpenDownloadsTray(controller: controller, center: self)
    }
    if previous == nil { order.insert(key, at: 0) }
    if state == .completed && previous?.snapshot.state != .completed { completedAt[profile.id] = Date()
      if let path = snapshot.filePath {
        completionFiles.insert(DownloadBadgeFile(id:key,name:snapshot.fileName,path:path,completedAt:Date()),at:0)
        completionFiles = Array(completionFiles.prefix(3)); scheduleBadgeExpiry()
      }
      refreshFiles() }
    if state == .completed || state == .failed || state == .cancelled {
      if state != previous?.snapshot.state, !(previous?.hidden ?? false) { persist(snapshot, profile: profile) }
      suggestedNames[key] = nil
      if let url = reserved.removeValue(forKey: key) { Task { await files.release(url) } }
    }
    // Session history is bounded; active downloads are never evicted.
    if order.count > 1_000, let old = order.last(where: { entries[$0]?.snapshot.state != .inProgress && entries[$0]?.snapshot.state != .paused }) {
      entries[old] = nil; order.removeAll { $0 == old }
    }
    schedulePublish()
  }
  private func schedulePublish() {
    guard !publishQueued else { return }
    publishQueued = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      publishQueued = false; publishCount += 1
      let live = order.compactMap { key in entries[key].flatMap { $0.hidden || removedHistory.contains(key) ? nil : $0.snapshot } }
      let historical = history.values.filter { entries[$0.id] == nil && !removedHistory.contains($0.id) && app.model.profile(id: $0.profileID) != nil }
        .sorted { $0.endedAt == $1.endedAt ? $0.id < $1.id : ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
      downloads = live + historical
      updateBadges()
      refreshLittleOpenTrays()
      // Outside the engine callback stack, close only browsers whose final
      // transfer has ended. No timer or work exists when there are no transfers.
      closeDetachedPages(force: false)
    }
  }
  func refreshLittleOpenTrays() {
    guard !littleOpenTrays.isEmpty else { return }
    for (id, tray) in Array(littleOpenTrays) {
      guard app.littleOpenCoordinator?.controllers[id] != nil else {
        tray.close(); littleOpenTrays[id] = nil; continue
      }
      tray.update(downloads.filter { entries[$0.id]?.littleOpenSessionID == id })
    }
  }
  func updateBadges() {
    for controller in app.windowControllers {
      let profileIDs = Set(app.model.spaces.map(\.profileID))
      let active = entries.values.filter { profileIDs.contains($0.snapshot.profileID) && $0.snapshot.state == .inProgress }
      let known = active.filter { $0.snapshot.totalBytes != nil }
      let total = known.reduce(0.0) { $0 + Double($1.snapshot.totalBytes ?? 0) }
      let received = known.reduce(0.0) { $0 + Double($1.snapshot.receivedBytes) }
      let completion = completedAt.filter { profileIDs.contains($0.key) }.map(\.value).max()
      let next = DownloadBadgeState(running: active.count, progress: total > 0 ? min(1, received / total) : 0,
        indeterminate: active.contains { $0.snapshot.totalBytes == nil }, completedAt: completion, files:completionFiles.filter {
          Date().timeIntervalSince($0.completedAt)<badgeLifetime && !removedHistory.contains($0.id)
            && entries[$0.id].map { profileIDs.contains($0.snapshot.profileID) && !$0.hidden && $0.snapshot.fileExists != false } == true
        })
      if controller.context.downloadBadge != next { controller.context.downloadBadge = next }
    }
  }
  func acknowledgeLibrary() {
    completionFiles = []; badgeExpiry?.cancel(); badgeExpiry = nil; updateBadges()
  }
  private func scheduleBadgeExpiry() {
    badgeExpiry?.cancel(); badgeExpiry = nil
    guard let oldest=completionFiles.last else { return }
    let work=DispatchWorkItem { [weak self] in
      guard let self else { return }; self.completionFiles.removeAll { Date().timeIntervalSince($0.completedAt)>=self.badgeLifetime }
      self.updateBadges(); self.scheduleBadgeExpiry()
    }
    badgeExpiry = work; DispatchQueue.main.asyncAfter(deadline:.now()+max(0,badgeLifetime-Date().timeIntervalSince(oldest.completedAt)),execute:work)
  }
  func opensDownloads(in context: SidebarContext) -> Bool {
    // A new window may have no callback yet. Reuse session snapshots on click.
    updateBadges()
    guard let badge = context.downloadBadge else { return false }
    return badge.running > 0 || badge.completedAt.map { Date().timeIntervalSince($0) < 60 } == true
  }
  func refreshFiles() {
    fileRefreshTask?.cancel()
    fileRefreshGeneration += 1
    guard !fileRefreshQueued else { return }
    fileRefreshQueued = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      fileRefreshQueued = false
      let generation = fileRefreshGeneration
      let live = order.compactMap { visibleItem($0) }
      let stored = history.values.filter { entries[$0.id] == nil && !removedHistory.contains($0.id) }
      let checks = (live + stored).compactMap { item -> DownloadFiles.FileCheck? in
        guard item.state == .completed else { return nil }
        return DownloadFiles.FileCheck(id: item.id, path: item.filePath)
      }
      guard !checks.isEmpty else { fileRefreshTask = nil; return }
      let files = self.files
      fileRefreshTask = Task { [weak self] in
        let results = try? await files.availability(for: checks)
        guard let self, generation == fileRefreshGeneration else { return }
        defer { fileRefreshTask = nil }
        guard !Task.isCancelled, let results else { return }
        var changed = false
        for result in results {
          let key = result.check.id
          guard let item = visibleItem(key), item.state == .completed, item.filePath == result.check.path,
            item.fileExists != result.exists else { continue }
          if entries[key] != nil { entries[key]?.snapshot.fileExists = result.exists }
          if history[key] != nil { history[key]?.fileExists = result.exists }
          changed = true
        }
        if changed { schedulePublish() }
      }
    }
  }
  func cancel(_ key: String) {
    choices[key]?.cancel()
    entries[key]?.download.cancel()
  }
  func pause(_ key: String) {
    guard entries[key]?.snapshot.state == .inProgress else { return }
    entries[key]?.download.pause(); entries[key]?.snapshot.state = .paused; schedulePublish()
  }
  func resume(_ key: String) {
    guard entries[key]?.snapshot.state == .paused else { return }
    entries[key]?.download.resume(); entries[key]?.snapshot.state = .inProgress; schedulePublish()
  }
  func remove(_ key: String) {
    guard let item = visibleItem(key) else { return }
    // Hiding must work even when the store cannot open or delete. Keep the ID
    // as a tombstone so an in-flight read or delayed callback cannot undo it.
    removedHistory.insert(key)
    entries[key]?.hidden = true; history[key] = nil
    historyRevisions[item.profileID, default: 0] += 1
    schedulePublish()
    guard let store = historyStore(for: item.profileID) else { return }
    let mutation = UUID()
    historyMutations[mutation] = Task { [weak self] in
      defer { self?.historyMutations[mutation] = nil }
      do { try await store.remove(id: key) }
      catch { self?.downloadHistoryError = error.localizedDescription }
    }
  }
  /// Match Settings' start-time range. Keep files and live engine transfers intact.
  func clearHistory(profileID: ProfileID, since start: Date?, through end: Date) async throws {
    guard let store = historyStore(for: profileID) else { return }
    let range = HistoryClearRange(profileID: profileID, start: start, end: end), token = UUID()
    // Register before yielding: terminal callbacks during the SQL clear must
    // not enqueue a write behind that clear and resurrect the removed history.
    inFlightHistoryClears[token] = range
    historyRevisions[profileID, default: 0] += 1
    do { try await store.clear(since: start, through: end) }
    catch {
      inFlightHistoryClears[token] = nil
      // The clear failed. Replay terminal callbacks suppressed while it waited;
      // another overlapping clear still has its own persistence guard.
      if let profile = app.model.profile(id: profileID) {
        for entry in Array(entries.values) where range.contains(entry.snapshot) && !entry.hidden {
          persist(entry.snapshot, profile: profile)
        }
      }
      throw error
    }
    inFlightHistoryClears[token] = nil
    if historyLoadTask != nil { clearedHistoryDuringLoad.append(range) }
    historyRevisions[profileID, default: 0] += 1
    let removed = Set(entries.compactMap { key, entry -> String? in
      let item = entry.snapshot
      guard range.contains(item), item.state != .inProgress, item.state != .paused else { return nil }
      return key
    })
    // Keep hidden engine entries as tombstones: a delayed terminal callback
    // must not reinsert history that the user just cleared.
    for key in removed { removedHistory.insert(key); entries[key]?.hidden = true }
    history = history.filter { _, item in
      if range.contains(item) { removedHistory.insert(item.id); return false }
      return true
    }
    schedulePublish()
  }
  func retry(_ key: String) {
    guard let item = visibleItem(key), item.state == .failed || item.isHistorical, let source = item.sourceURL else { return }
    app.settingsPresenter.openURL(source, profileID: item.profileID)
  }
  private func visibleItem(_ key: String) -> DownloadItemSnapshot? {
    guard !removedHistory.contains(key) else { return nil }
    if let entry = entries[key] { return entry.hidden ? nil : entry.snapshot }
    return history[key]
  }
  func fileAction(_ action: String, key: String) {
    guard let item = visibleItem(key), item.state == .completed, let path = item.filePath else { return }
    let url = URL(fileURLWithPath: path)
    Task { [weak self] in
      guard let self else { return }
      guard await files.exists(url) else { refreshFiles(); return }
      #if OPEN_AUTOMATION
      if recordFileActions {
        if fileActions.count >= 256 { fileActions.removeFirst() }
        fileActions.append(["action": action, "url": url.absoluteString])
      }
      #endif
      switch action {
      case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL])
      case "trash":
        do { try await files.trash(url); remove(key) }
        catch { lastFileError = error.localizedDescription }
      case "reveal":
        #if OPEN_AUTOMATION
        if recordFileActions { return }
        #endif
        NSWorkspace.shared.activateFileViewerSelecting([url])
      case "open":
        #if OPEN_AUTOMATION
        if let opener = fileOpenerForAutomation {
          let configuration = NSWorkspace.OpenConfiguration()
          configuration.activates = false; configuration.addsToRecentItems = false
          configuration.createsNewApplicationInstance = true
          let root = opener.deletingLastPathComponent()
          configuration.environment = ["OPEN_DOWNLOADS_OPEN_FILE_ROOT": root.path,
            "OPEN_DOWNLOADS_OPEN_FILE_RECEIPT": root.appendingPathComponent("opened-file.json").path,
            "DYLD_INSERT_LIBRARIES": ""]
          do {
            let application = try await NSWorkspace.shared.open([url], withApplicationAt: opener, configuration: configuration)
            fileOpenerPID = application.processIdentifier
          } catch { lastFileError = error.localizedDescription }
          return
        }
        if recordFileActions { return }
        #endif
        NSWorkspace.shared.open(url)
      default: break
      }
    }
  }
  private func historyStore(for profileID: ProfileID) -> DownloadHistoryStore? {
    guard !retiredProfiles.contains(profileID), let profile = app.model.profile(id: profileID) else { return nil }
    if let store = historyStores[profileID] { return store }
    let store = DownloadHistoryStore(fileURL: app.directories.downloadsFileURL(dataDirectoryName: profile.dataDirectoryName), profileID: profileID)
    historyStores[profileID] = store
    return store
  }
  private func persist(_ item: DownloadItemSnapshot, profile: Profile) {
    guard let state = DownloadHistoryRecord.State(rawValue: item.state.rawValue), let source = item.sourceURL,
      let endedAt = item.endedAt, !removedHistory.contains(item.id), entries[item.id]?.hidden != true,
      !inFlightHistoryClears.values.contains(where: { $0.contains(item) }),
      let store = historyStore(for: profile.id) else { return }
    historyRevisions[profile.id, default: 0] += 1
    historyWriteRevision += 1
    // Cache synchronously with the callback. A delayed disk completion must
    // never re-add a row after a remove/clear or Profile deletion.
    var historical = item; historical.isHistorical = true
    history[item.id] = historical
    let profileRows = history.values.filter { $0.profileID == item.profileID }.sorted {
      $0.endedAt == $1.endedAt ? $0.id < $1.id : ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt)
    }
    for old in profileRows.dropFirst(DownloadHistoryStore.maximumCount) { history[old.id] = nil }
    store.record(DownloadHistoryRecord(id: item.id, fileName: item.fileName, sourceURL: source, sourceHost: item.sourceHost,
      filePath: item.filePath, receivedBytes: item.receivedBytes, totalBytes: item.totalBytes,
      startedAt: item.startedAt, endedAt: endedAt, state: state, profileID: profile.id)) { [weak self] error in
        if let error { self?.downloadHistoryError = error }
      }
  }
  func refreshDownloads() async {
    if let historyLoadTask { await historyLoadTask.value; refreshFiles(); await finishPublication(); return }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      downloadHistoryError = ""
      for profile in app.model.profiles {
        guard let store = historyStore(for: profile.id) else { continue }
        var retries = 0
        while !loadedHistory.contains(profile.id), !retiredProfiles.contains(profile.id) {
          let revision = historyRevisions[profile.id, default: 0]
          do {
            let records = try await store.load()
            guard app.model.profile(id: profile.id) != nil, !retiredProfiles.contains(profile.id) else { break }
            // Bound retries under continuous callbacks. Tombstones and clear
            // ranges make the final read safe even if its revision is stale.
            if revision != historyRevisions[profile.id, default: 0], retries < 2 { retries += 1; continue }
            for record in records {
              guard !removedHistory.contains(record.id), entries[record.id] == nil, history[record.id] == nil,
                !clearedHistoryDuringLoad.contains(where: { $0.contains(profileID: record.profileID, startedAt: record.startedAt) }) else { continue }
              var item = DownloadItemSnapshot(id: record.id, fileName: record.fileName, sourceHost: record.sourceHost,
                receivedBytes: record.receivedBytes, totalBytes: record.totalBytes,
                state: DownloadState(rawValue: record.state.rawValue) ?? .failed, filePath: record.filePath,
                startedAt: record.startedAt, profileID: record.profileID)
              item.sourceURL = record.sourceURL; item.endedAt = record.endedAt; item.isHistorical = true
              // Existence checks also stay on the file actor; no main-thread stat.
              item.fileExists = nil
              history[item.id] = item
            }
            loadedHistory.insert(profile.id)
          } catch { downloadHistoryError = error.localizedDescription; break }
        }
      }
      refreshFiles(); schedulePublish()
    }
    historyLoadTask = task
    await task.value
    historyLoadTask = nil
    clearedHistoryDuringLoad.removeAll()
    await finishPublication()
  }
  private func finishPublication() async {
    guard publishQueued else { return }
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
  }
  var historyLoaded: Bool { app.model.profiles.allSatisfy { loadedHistory.contains($0.id) } }
  func flushHistory() async {
    for task in Array(historyMutations.values) { await task.value }
    let revision = historyWriteRevision
    for store in historyStores.values { await store.flush() }
    flushedHistoryRevision = revision
  }
  var needsHistoryFlush: Bool { historyWriteRevision != flushedHistoryRevision || !historyMutations.isEmpty }
  func retireProfile(_ profileID: ProfileID, directory: String) async {
    closeDetachedPages(profileID: profileID)
    retiredProfiles.insert(profileID); historyRevisions[profileID, default: 0] += 1
    let prefixes = ["\(sessionID):\(directory):", "\(sessionID):\(profileID.description):"]
    let keys = Set(order.filter { entries[$0]?.snapshot.profileID == profileID })
      .union(choices.keys.filter { key in prefixes.contains { key.hasPrefix($0) } })
    for key in keys {
      choices.removeValue(forKey: key)?.cancel()
      if let url = reserved.removeValue(forKey: key) { Task { await files.release(url) } }
      suggestedNames[key] = nil; entries[key] = nil
    }
    order.removeAll { entries[$0] == nil }
    history = history.filter { $0.value.profileID != profileID }
    loadedHistory.remove(profileID); completedAt[profileID] = nil
    completionFiles.removeAll { keys.contains($0.id) }; scheduleBadgeExpiry()
    if let store = historyStores.removeValue(forKey: profileID) { await store.retire() }
    schedulePublish()
  }
  /// This runs before sleep capture or any page-beforeunload handling.
  /// The traced Arc path does not prove a Warn-before-quitting preference gate;
  /// keep this download-specific warning for both values (downloads-s11.md).
  func shouldKeepBrowsing(withoutPrompts: Bool = false) -> Bool {
    if withoutPrompts { approveQuit(); return false }
    #if OPEN_AUTOMATION
    if AutomationOwnerWatch.quittingWithoutPrompts {
      approveQuit()
      return false
    }
    #endif
    guard !quitApproved, hasRunning else { return false }
    presentingQuitAlert = true
    defer { presentingQuitAlert = false }
    // Quit from the Dock or a script can arrive while Open is in the background.
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Downloads in progress"
    alert.informativeText = "There are downloads in progress. Closing the application will cancel them."
    alert.addButton(withTitle: "Close Open"); alert.addButton(withTitle: "Keep browsing")
    #if OPEN_AUTOMATION
    AppDelegate.commandLog("downloads-quit-alert-presented")
    if quitAlerts.count >= 64 { quitAlerts.removeFirst() }
    quitAlerts.append(["title": alert.messageText, "body": alert.informativeText, "buttons": alert.buttons.map(\.title)])
    if let policy = quitAlertPolicy {
      // Observe the actual app-modal window; press its own native button inside
      // the modal run loop (GCD callbacks can be held by CEF's nested loop).
      var observer: (any NSObjectProtocol)?
      observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: alert.window, queue: .main) { _ in
        MainActor.assumeIsolated {
          RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated { alert.buttons[policy == "close" ? 0 : 1].performClick(nil) }
          }
        }
      }
      let response = alert.runModal()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      if response != .alertFirstButtonReturn { return true }
    } else if alert.runModal() != .alertFirstButtonReturn { return true }
    #else
    if alert.runModal() != .alertFirstButtonReturn { return true }
    #endif
    approveQuit()
    return false
  }
  /// A new quit attempt asks again (AppDelegate calls this at each fresh attempt).
  func resetQuitApproval() { quitApproved = false }
  private func approveQuit() {
    quitApproved = true
    // Model the user's cancellation before asking the engine, as Pause/Resume
    // already do. The quit flush then covers cancellations even if Chromium's
    // terminal callback arrives during shutdown. A final Complete callback wins.
    for (key, entry) in Array(entries) where entry.snapshot.state == .inProgress || entry.snapshot.state == .paused {
      var item = entry.snapshot; item.state = .cancelled; item.endedAt = Date()
      entries[key]?.snapshot = item
      if !entry.hidden, let profile = app.model.profile(id: item.profileID) { persist(item, profile: profile) }
      entry.download.cancel()
    }
    for choice in choices.values { choice.cancel() }
    schedulePublish()
  }
  var queued: Bool { publishQueued }
}
