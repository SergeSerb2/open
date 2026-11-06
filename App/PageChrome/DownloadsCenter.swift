import AppKit
import Darwin
import Observation
import OpenEngine
import OpenModel
import OpenSettings
import OpenSidebar

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
  func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
  func release(_ url: URL) { claims.remove(url) }
}

/// Session-only download state. Engine callbacks are the sole progress source.
/// One queued main-actor turn publishes a burst, following ObservationLoop.
@MainActor @Observable
final class DownloadsCenter: DownloadsProvider {
  unowned let app: AppDelegate
  @ObservationIgnored let files: DownloadFiles
  @ObservationIgnored private var entries: [String: Entry] = [:]
  @ObservationIgnored private var order: [String] = []
  @ObservationIgnored private var publishQueued = false
  @ObservationIgnored private(set) var choices: [String: DownloadDestinationChoice] = [:]
  @ObservationIgnored private var reserved: [String: URL] = [:]
  @ObservationIgnored private var suggestedNames: [String: String] = [:]
  @ObservationIgnored private var completedAt: [ProfileID: Date] = [:]
  private(set) var downloads: [DownloadItemSnapshot] = []
  private(set) var publishCount = 0
  private(set) var updateCount = 0
  private(set) var fallbackCount = 0
  private(set) var lastFileError = ""
  @ObservationIgnored private var quitApproved = false
  #if OPEN_AUTOMATION
  var recordFileActions = false
  var fileOpenerForAutomation: URL?
  private(set) var fileOpenerPID: Int32 = 0
  private(set) var fileActions: [[String: String]] = []
  var quitAlertPolicy: String?
  private(set) var quitAlerts: [[String: Any]] = []
  #endif
  private struct Entry {
    let download: OEDownload
    var snapshot: DownloadItemSnapshot
    var hidden = false
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
  }
  func profile(for context: OEBrowserContext) -> Profile? {
    app.model.profiles.first { $0.id.description == context.identifier || app.directories.engineDirectory(for: $0).standardizedFileURL == context.directory?.standardizedFileURL }
      ?? (context === OEEngine.shared.defaultContext ? app.model.defaultProfile : nil)
  }
  func id(_ download: OEDownload, _ context: OEBrowserContext) -> String { "\(context.identifier):\(download.identifier)" }
  var hasRunning: Bool { entries.values.contains { $0.snapshot.state == .inProgress || $0.snapshot.state == .paused } || !choices.isEmpty }
  func decide(_ download: OEDownload, context: OEBrowserContext, filename: String, window: NSWindow?, directoryOverride: URL? = nil, completion: @escaping @MainActor (URL?) -> Void) {
    guard let profile = profile(for: context) else { completion(nil); return }
    let key = id(download, context)
    let name = filename.isEmpty ? "download" : (filename as NSString).lastPathComponent
    guard ![".", "..", "/"].contains(name), name.utf8.count <= Int(NAME_MAX) else { completion(nil); return }
    suggestedNames[key] = name
    let path = directoryOverride?.path ?? profile.settings.downloadDirectory
    let ask = directoryOverride == nil && profile.settings.askWhereToSaveEachFile
    Task { [weak self, weak window] in
      guard let self else { completion(nil); return }
      do {
        let directory = try await files.directory(path)
        guard !app.terminationRequested else { completion(nil); return }
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
          guard !app.terminationRequested else { await files.release(url); completion(nil); return }
          reserved[key] = url
          completion(url)
        }
      } catch { lastFileError = error.localizedDescription; completion(nil) }
    }
  }
  func updated(_ download: OEDownload, context: OEBrowserContext) {
    guard let profile = profile(for: context) else { return }
    updateCount += 1
    let key = id(download, context), previous = entries[key]
    let state: DownloadState
    switch download.state {
    case .complete: state = .completed
    case .cancelled: state = .cancelled
    case .interrupted: state = .failed
    default: state = previous?.snapshot.state == .paused ? .paused : .inProgress
    }
    let name = [download.destinationURL?.lastPathComponent, download.suggestedFilename,
      suggestedNames[key], previous?.snapshot.fileName].compactMap { $0 }.first { !$0.isEmpty } ?? "download"
    var snapshot = DownloadItemSnapshot(id: key, fileName: name,
      sourceHost: download.sourceURL.host() ?? "", receivedBytes: download.receivedBytes,
      totalBytes: download.totalBytes > 0 ? download.totalBytes : nil, state: state,
      filePath: download.destinationURL?.path, startedAt: previous?.snapshot.startedAt ?? Date(), profileID: profile.id)
    snapshot.bytesPerSecond = download.bytesPerSecond
    snapshot.fileExists = state == .completed && previous?.snapshot.state != .completed
      ? download.destinationURL != nil : previous?.snapshot.fileExists ?? false
    entries[key] = Entry(download: download, snapshot: snapshot, hidden: previous?.hidden ?? false)
    if previous == nil { order.insert(key, at: 0) }
    if state == .completed && previous?.snapshot.state != .completed { completedAt[profile.id] = Date(); refreshFile(key) }
    if state == .completed || state == .failed || state == .cancelled {
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
      downloads = order.compactMap { entries[$0].flatMap { $0.hidden ? nil : $0.snapshot } }
      updateBadges()
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
        indeterminate: active.contains { $0.snapshot.totalBytes == nil }, completedAt: completion)
      if controller.context.downloadBadge != next { controller.context.downloadBadge = next }
    }
  }
  func opensDownloads(in context: SidebarContext) -> Bool {
    // A new window may have no callback yet. Reuse session snapshots on click.
    updateBadges()
    guard let badge = context.downloadBadge else { return false }
    return badge.running > 0 || badge.completedAt.map { Date().timeIntervalSince($0) < 60 } == true
  }
  func refreshFiles() { for key in order where entries[key]?.snapshot.state == .completed { refreshFile(key) } }
  private func refreshFile(_ key: String) {
    guard let path = entries[key]?.snapshot.filePath else { return }
    Task { [weak self] in
      guard let self else { return }
      let exists = await files.exists(URL(fileURLWithPath: path))
      guard entries[key]?.snapshot.fileExists != exists else { return }
      entries[key]?.snapshot.fileExists = exists; schedulePublish()
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
  func remove(_ key: String) { entries[key]?.hidden = true; schedulePublish() }
  func retry(_ key: String) {
    guard let entry = entries[key], !entry.hidden, entry.snapshot.state == .failed else { return }
    app.settingsPresenter.openURL(entry.download.sourceURL, profileID: entry.snapshot.profileID)
  }
  func fileAction(_ action: String, key: String) {
    guard let entry = entries[key], !entry.hidden, entry.snapshot.state == .completed, let path = entry.snapshot.filePath else { return }
    let url = URL(fileURLWithPath: path)
    Task { [weak self] in
      guard let self, await files.exists(url) else { return }
      #if OPEN_AUTOMATION
      if recordFileActions {
        if fileActions.count >= 256 { fileActions.removeFirst() }
        fileActions.append(["action": action, "url": url.absoluteString])
      }
      #endif
      switch action {
      case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL])
      case "trash":
        do { try await files.trash(url); entries[key]?.hidden = true; schedulePublish() }
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
  /// This runs before sleep capture or any page-beforeunload handling.
  func shouldKeepBrowsing() -> Bool {
    guard !quitApproved, hasRunning else { return false }
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
    quitApproved = true
    for entry in entries.values where entry.snapshot.state == .inProgress || entry.snapshot.state == .paused { entry.download.cancel() }
    for choice in choices.values { choice.cancel() }
    return false
  }
  var queued: Bool { publishQueued }
}
