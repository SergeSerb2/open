import AppKit
import Observation
import OpenSettings
import OpenCommands
import OpenModel
import OpenStore
import OpenEngine
import OpenAdBlock

/// App-owned adapters for the two shared OpenSettings presenters. Neither
/// presenter owns a second snapshot writer or an engine context.
@MainActor
@Observable
final class AppSettingsActions: SettingsActions, LibraryActions, DownloadsProvider {
  unowned let app: AppDelegate
  init(app: AppDelegate) { self.app = app }
  @ObservationIgnored lazy var settings: SettingsViewModel = {
    let vm = SettingsViewModel(model: app.model, actions: self, defaults: .standard,
      root: app.directories.root, snapshot: app.snapshotStore,
      focusedProfileID: app.frontWindowController.flatMap { app.hostFactories[$0.windowID]?.focusedProfile?.id })
    if let store = app.stores.adBlock { vm.attach(adBlockStore: store) }
    else { vm.statusText = "Ad blocking settings could not be opened." }
    return vm
  }()
  @ObservationIgnored lazy var settingsPresenter = SettingsPresenter(viewModel: settings)
  @ObservationIgnored lazy var captures = try? FileCapturesProvider(root: app.directories.root)
  @ObservationIgnored private(set) var library: LibraryViewModel?
  @ObservationIgnored private(set) var libraryPresenter: LibraryPresenter?
  private(set) var downloadRevision = 0
  private var removedDownloads: Set<String> = []
  private var pausedDownloads: Set<String> = []
  private(set) var lastDownloadReveal: [String: String] = [:]
  func show(pane: PaneID? = nil) { settingsPresenter.show(pane: pane); NSApp.activate(); app.scheduleMenuRebuild() }
  func showLibrary(section: LibrarySection? = nil) {
    guard let captures else { settings.statusText = "Captures could not be opened."; show(); return }
    let archives = Dictionary(uniqueKeysWithValues: app.model.profiles.map { ($0.id, app.archiveSink.store(for: $0.id)) })
    let histories = Dictionary(uniqueKeysWithValues: app.model.profiles.compactMap { profile in app.stores.history(for: profile.id).map { (profile.id, $0) } })
    if library == nil {
      let vm = LibraryViewModel(model: app.model, defaults: .standard, actions: self,
        downloads: self, captures: captures, archives: archives, histories: histories,
        snapshot: app.snapshotStore, faviconStore: app.stores.favicons)
      library = vm; libraryPresenter = LibraryPresenter(viewModel: vm)
    }
    library?.registerStores(archives: archives, histories: histories)
    libraryPresenter?.show(section: section); NSApp.activate(); app.scheduleMenuRebuild()
  }
  func prepareForRemoteSuggestions(profileID: ProfileID) -> Bool { settingsPresenter.prepareForRemoteSuggestions(profileID: profileID) }
  func refreshDownloads() { downloadRevision += 1 }
  var downloads: [DownloadItemSnapshot] {
    _ = downloadRevision
    guard app.engineReady, !app.shutdownPrepared else { return [] }
    return OEEngine.shared.contexts.flatMap { context in
      guard let profile = profile(for: context) else { return [DownloadItemSnapshot]() }
      return context.downloads.compactMap { download in
        let id = "\(context.identifier):\(download.identifier)"
        guard !removedDownloads.contains(id) else { return nil }
        let state: DownloadState
        switch download.state { case .complete: state = .completed; case .cancelled: state = .cancelled; case .interrupted: state = .failed; default: state = pausedDownloads.contains(id) ? .paused : .inProgress }
        var snapshot = DownloadItemSnapshot(id: id, fileName: download.destinationURL?.lastPathComponent ?? (download.suggestedFilename.isEmpty ? "Download" : download.suggestedFilename),
          sourceHost: download.sourceURL.host() ?? "", receivedBytes: download.receivedBytes,
          totalBytes: download.totalBytes >= 0 ? download.totalBytes : nil, state: state,
          filePath: download.destinationURL?.path, startedAt: downloadStarted[id] ?? Date(), profileID: profile.id)
        snapshot.bytesPerSecond = download.bytesPerSecond; return snapshot
      }
    }
  }
  @ObservationIgnored private var downloadStarted: [String: Date] = [:]
  func noteDownload(_ download: OEDownload, context: OEBrowserContext) {
    let id = "\(context.identifier):\(download.identifier)"
    if download.state == .complete || download.state == .cancelled || download.state == .interrupted { pausedDownloads.remove(id) }
    if downloadStarted[id] == nil { downloadStarted[id] = Date() }; refreshDownloads()
  }
  func profile(for context: OEBrowserContext) -> Profile? {
    app.model.profiles.first { $0.dataDirectoryName == context.identifier || app.directories.engineDirectory(for: $0).standardizedFileURL == context.directory?.standardizedFileURL }
      ?? (context === OEEngine.shared.defaultContext ? app.model.defaultProfile : nil)
  }
  private func download(_ id: String) -> OEDownload? {
    for context in OEEngine.shared.contexts { if let item = context.downloads.first(where: { "\(context.identifier):\($0.identifier)" == id }) { return item } }; return nil
  }
  private func status(_ message: String) { settings.statusText = message; AppDelegate.commandLog(message) }
  var canImportPasswordsAndCookies: Bool { false }
  func isDefaultBrowser() -> Bool { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
  func setAsDefaultBrowser() -> String? {
    Task { @MainActor in
      do {
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https")
        settings.general.refresh()
      } catch { settings.general.errorText = "The default browser could not be changed. \(error.localizedDescription)" }
    }
    return nil
  }
  func checkForUpdates() { status("An update feed is not available yet."); show(pane: .general) }
  func openMoreSettings() { openURL(URL(string: "chrome://settings")!, profileID: settings.selectedProfileID) }
  func revealOpenDataFolder() { NSWorkspace.shared.activateFileViewerSelecting([app.directories.root]) }
  func copyOpenInfoToPasteboard() { copyText("Open \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")\nChromium \(OEEngine.shared.chromiumVersion)") }
  func deleteProfileData(profileID: ProfileID) -> String? {
    guard let profile = app.model.profile(id: profileID) else { return "This profile is no longer available." }
    guard !OEEngine.shared.contexts.contains(where: { self.profile(for: $0)?.id == profileID }) else { return "Close this profile's pages and restart Open before deleting its data." }
    do { try app.directories.deleteProfileData(for: profile); return nil } catch { return "The profile data could not be deleted. \(error.localizedDescription)" }
  }
  func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds) async -> String? { await clearBrowsingData(profileID: profileID, kinds: kinds, range: .all) }
  func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds, range: ClearDataRange) async -> String? {
    // Today's engine can only clear cookies + cache together, for all time.
    guard range == .all, !kinds.contains(.history), !kinds.contains(.downloads), kinds.contains([.cookies, .cache]) else { return "This engine can clear cookies and cache together for All time. Other ranges and history clearing are not available yet." }
    guard let context = app.hostFactories.values.compactMap({ $0.context(for: profileID) }).first else { return "This profile is not open." }
    await withCheckedContinuation { continuation in context.clearBrowsingData(origin: nil) { continuation.resume() } }; return nil
  }
  func openProfileSubpage(profileID: ProfileID, page: ProfilePage) {
    let path = [ProfilePage.privacy: "privacy", .passwords: "passwords", .paymentMethods: "payments", .notifications: "content/notifications"][page] ?? "privacy"
    openURL(URL(string: "chrome://settings/\(path)")!, profileID: profileID)
  }
  func openPreviewsSettings() {} // General owns its one sheet.
  func keyBindingsDidChange(store: KeyBindingStore) { app.reloadKeyBindings() }
  func runImport(plan: ImportPlan) async -> ImportOutcome { ImportOutcome(errorText: "Import is not available in this build. No data was imported.") }
  func setAdBlockEnabled(_ on: Bool, profileID: ProfileID) { status("Ad blocking is not active in this build. Your preferences were saved.") }
  func setEnabledBlockLists(_ ids: [String], profileID: ProfileID) { setAdBlockEnabled(true, profileID: profileID) }
  func setAdBlockExcludedDomains(_ domains: [String], profileID: ProfileID) { setAdBlockEnabled(true, profileID: profileID) }
  func adBlockDebugInfo(profileID: ProfileID) -> String { "App engine filter adapter: pending Step D" }
  func setTabSleepMode(_ mode: TabSleepMode) {
    for profile in app.model.profiles { var settings = profile.settings; settings.sleepMode = mode.modelMode; app.model.updateProfileSettings(id: profile.id, settings: settings) }; app.scheduleSave()
  }
  func setApplicationIcon(id: String) { status("Application icon switching is not connected yet.") }
  func resetTranslatePrompts(profileID: ProfileID) -> String? { "Translation prompt reset is not available in this engine yet." }
  func openURL(_ url: URL, profileID: ProfileID) {
    guard let space = app.model.spaces.first(where: { $0.profileID == profileID }),
      let controller = app.frontWindowController ?? app.makeWindow(focusedSpaceID: space.id),
      let factory = app.hostFactories[controller.windowID] else { return }
    app.focusWindow(controller.windowID, activate: true); factory.focus(space: space); _ = factory.openNewTab(url: url, background: false)
  }
  func openHelp(topic: String) { if let profile = app.model.defaultProfile { openURL(AppCommand.helpURL, profileID: profile.id) } }
  func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
  func openLibrary() { showLibrary() }
  // Library owns the durable archive/capture mutations. These are notifications.
  func restoreArchived(id: ItemID) { app.scheduleSave(); app.scheduleMenuRebuild() }
  func deleteArchived(id: ItemID) { app.scheduleMenuRebuild() }
  func clearArchive() { app.scheduleMenuRebuild() }
  func revealDownload(id: String) {
    guard let item = download(id), item.state == .complete, let url = item.destinationURL,
          FileManager.default.fileExists(atPath: url.path) else { return }
    lastDownloadReveal = ["id": id, "path": url.path]
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
  func retryDownload(id: String) { if let item = download(id), let profile = OEEngine.shared.contexts.first(where: { id.hasPrefix($0.identifier + ":") }).flatMap({ self.profile(for: $0) }) ?? app.model.defaultProfile { openURL(item.sourceURL, profileID: profile.id) } }
  func cancelDownload(id: String) { download(id)?.cancel(); pausedDownloads.remove(id); refreshDownloads() }
  func pauseDownload(id: String) { download(id)?.pause(); pausedDownloads.insert(id); refreshDownloads() }
  func resumeDownload(id: String) { download(id)?.resume(); pausedDownloads.remove(id); refreshDownloads() }
  func openDownload(id: String) { if let url = download(id)?.destinationURL { NSWorkspace.shared.open(url) } }
  func removeDownload(id: String) { removedDownloads.insert(id); refreshDownloads() }
  func deleteCapture(id: UUID) {} // Library already removed the file and index.
  private func captureURL(_ id: UUID) -> URL? { captures?.captures.first { $0.id == id }.flatMap { captures?.directory.appendingPathComponent($0.fileName) } }
  func revealCapture(id: UUID) { if let url = captureURL(id) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
  func openCapture(id: UUID) { if let url = captureURL(id) { NSWorkspace.shared.open(url) } }
  func copyCapture(id: UUID) { if let url = captureURL(id), let image = NSImage(contentsOf: url) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) } }
  func saveCapture(id: UUID, to: URL) -> String? { guard let url = captureURL(id) else { return "This capture is no longer available." }; do { try FileManager.default.copyItem(at: url, to: to); return nil } catch { return "The capture could not be saved. \(error.localizedDescription)" } }
  func openHistoryItem(url: URL) { if let profileID = library?.historyProfileID { openURL(url, profileID: profileID) } }
  func viewSpace(id: SpaceID) {
    guard let controller = app.frontWindowController ?? app.makeWindow(focusedSpaceID: id), let space = app.model.space(id: id), let factory = app.hostFactories[controller.windowID] else { return }
    app.focusWindow(controller.windowID, activate: true); factory.focus(space: space)
  }
}
