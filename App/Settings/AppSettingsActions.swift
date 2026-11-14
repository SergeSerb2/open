import AppKit
import Observation
import OpenSettings
import OpenCommands
import OpenModel
import OpenStore
import OpenEngine
import OpenAdBlock
import OpenSidebar
import OpenFeatures
import OpenTranslate
import OpenSpaceEditor
import OpenLibrary

/// App-owned adapters for the two shared OpenSettings presenters. Neither
/// presenter owns a second snapshot writer or an engine context.
@MainActor
@Observable
final class AppSettingsActions: SettingsActions, LibraryActions, DownloadsProvider {
  unowned let app: AppDelegate
  init(app: AppDelegate) { self.app = app }
  @ObservationIgnored private var settingsStorage: SettingsViewModel?
  #if OPEN_AUTOMATION
  var hasSettingsModel: Bool { settingsStorage != nil }
  private(set) var lastSettingsShowMs = 0.0
  #endif
  var settings: SettingsViewModel {
    if let settingsStorage { return settingsStorage }
    let vm = SettingsViewModel(model: app.model, actions: self, defaults: .standard,
      root: app.directories.root, snapshot: app.snapshotStore,
      focusedProfileID: app.frontStandardWindowController.flatMap { app.hostFactories[$0.windowID]?.focusedProfile?.id })
    vm.routingSnapshotProvider = { [unowned app] in app.linkExecutor.snapshot() }
    // Command services can create Settings before its window is shown. An
    // unsupported engine must not open a Profile or schedule list updates then.
    if (!app.isFirstRun || app.firstRunSaved) && app.adBlockEngineAdapter.isSupported {
      if let store = app.stores.existingAdBlock { vm.attach(adBlockStore: store, directoryForProfile: { [unowned app] in app.directories.adBlockDirectory(dataDirectoryName: $0.dataDirectoryName) }) }
      // A worker prepares the store; adBlockStoreDidOpen attaches it to this model.
      else if !app.stores.prepareAdBlockInBackground() { vm.advanced.statusText = "Ad blocking settings could not be opened." }
    }
    app.defaultBrowserService.onChange = { [weak vm, weak app] state in
      vm?.general.refresh()
      vm?.links.isDefaultBrowser = state.values.allSatisfy { $0 }
      app?.firstRunWindowController?.model.refreshDefaultBrowserStatus()
    }
    vm.updateState = app.updater?.settingsStatus
    settingsStorage = vm
    return vm
  }
  func modelWasInstalled() { settingsStorage = nil }
  func refreshPreferencesIfLoaded() { settingsStorage?.preferenceRevision &+= 1 }
  // Registry callbacks never instantiate Settings or open another Profile.
  func refreshAdBlockWarning() { settingsStorage?.adBlock?.refreshOtherBlocker() }
  // Async fresh-context store preparation may finish after Settings already
  // exists. Attach only that model; never instantiate Settings in this callback.
  func adBlockStoreDidOpen(_ store: AdBlockStore) {
    guard let settingsStorage, settingsStorage.adBlock == nil else { return }
    settingsStorage.attach(adBlockStore: store, directoryForProfile: { [unowned app] in app.directories.adBlockDirectory(dataDirectoryName: $0.dataDirectoryName) })
    if settingsStorage.advanced.statusText == "Ad blocking settings could not be opened." {
      settingsStorage.advanced.statusText = ""
    }
  }
  func adBlockStoreFailedToOpen() {
    guard let settingsStorage, settingsStorage.adBlock == nil else { return }
    settingsStorage.advanced.statusText = "Ad blocking settings could not be opened."
  }
  func hasEnabledBlockerExtension(profileID: ProfileID) -> Bool {
    guard app.engineReady, let profile = app.model.profile(id: profileID),
      let context = OEEngine.shared.contexts.first(where: { $0.identifier == profile.dataDirectoryName }) else { return false }
    return context.extensions.installedExtensions.contains {
      $0.isEnabled && AdBlockKnownBlockers.extensionIDs.contains($0.identifier)
    }
  }
  func attachBrowserStores(openingSettings: Bool = false) {
    guard openingSettings || app.adBlockEngineAdapter.isSupported else { return }
    if settings.adBlock == nil, let store = app.stores.adBlock { settings.attach(adBlockStore: store, directoryForProfile: { [unowned app] in app.directories.adBlockDirectory(dataDirectoryName: $0.dataDirectoryName) }) }
  }
  @ObservationIgnored lazy var settingsPresenter = SettingsPresenter(viewModel: settings)
  @ObservationIgnored lazy var captures = FileCapturesProvider(root: app.directories.root, loadImmediately: false)
  /// Library folder sources (PB1). Nothing reads the folders before "Choose Folders…".
  @ObservationIgnored lazy var mediaFolders: LibraryMediaFoldersProvider = {
    var folders = LibraryMediaFolders.user()
    #if OPEN_AUTOMATION
    // Fixture folders only: automation never reads the user's folders or meets a consent prompt.
    if let root = ProcessInfo.processInfo.environment["OPEN_LIBRARY_MEDIA_FIXTURE"], root.hasPrefix("/") {
      folders = .fixture(root: URL(fileURLWithPath: root, isDirectory: true))
    }
    #endif
    let provider = LibraryMediaFoldersProvider(stateURL: app.directories.root.appendingPathComponent("State/library-media.json"), folders: folders)
    provider.onChange = { [weak self] in self?.syncLibraryMediaSources(refresh: true) }
    return provider
  }()
  /// The Library button's "Show media from:" menu state, for every window; refreshes open Media lists.
  func syncLibraryMediaSources(refresh: Bool = false) {
    let items = LibraryMediaSource.menuOrder.map { SidebarMediaSourceItem(id: $0.rawValue, title: $0.title, enabled: mediaFolders.isEnabled($0)) }
    for controller in app.windowControllers where controller.context.libraryMediaSources != items { controller.context.libraryMediaSources = items }
    guard refresh else { return }
    for session in librarySessions.values { Task { @MainActor in await session.model.refreshExternalState(for: .media) } }
  }
  func toggleLibraryMediaSource(_ id: String) -> Bool {
    guard let source = LibraryMediaSource(rawValue: id) else { return false }
    mediaFolders.setEnabled(source, !mediaFolders.isEnabled(source)); return true
  }
  @ObservationIgnored var librarySessions: [WindowID: AppLibrarySession] = [:]
  #if OPEN_AUTOMATION
  @ObservationIgnored weak var lastClosedLibraryPanel: LibraryPanelView?
  #endif
  func libraryWindowClosed(_ id: WindowID) {
    guard let session = librarySessions.removeValue(forKey: id) else { return }
    #if OPEN_AUTOMATION
    lastClosedLibraryPanel = session.panel
    #endif
    // Keep the session alive through windowDidClose. It owns native delegates
    // and observation callbacks which must stop outside that callback stack.
    DispatchQueue.main.async { session.dispose() }
  }
  var activeLibrarySession: AppLibrarySession? {
    app.frontStandardWindowController.flatMap { librarySessions[$0.windowID] }
  }
  var library: LibraryViewModel? { activeLibrarySession?.model }
  var libraryWindow: NSWindow? {
    guard let session=activeLibrarySession, session.controller?.isLibraryOpen == true else { return nil }
    return session.controller?.window
  }
  func show(pane: PaneID? = nil) {
    #if OPEN_AUTOMATION
    let started = ProcessInfo.processInfo.systemUptime
    #endif
    attachBrowserStores(openingSettings: true)
    settings.appearanceWindowID = app.frontStandardWindowController?.windowID
    settingsPresenter.show(pane: pane); NSApp.activate(); app.scheduleMenuRebuild()
    #if OPEN_AUTOMATION
    lastSettingsShowMs = (ProcessInfo.processInfo.systemUptime-started)*1000
    #endif
  }
  func show(section: SettingsSection, row: String? = nil, profileID: ProfileID? = nil) {
    if let profileID, app.model.profile(id: profileID) != nil { settings.profiles.select(profileID) }
    settings.navigate(to: section, row: row); show()
  }
  @discardableResult func showSettingsURL(_ url: URL) -> Bool {
    guard let target = SettingsSearchIndex.destination(for: url) else { return false }
    settings.navigate(to: target.section, row: target.row)
    show(); return true
  }
  func updateStatusDidChange(_ status: String?) { settingsStorage?.updateState = status }
  func showProfileSettings(profileID: ProfileID) {
    guard app.model.profile(id: profileID) != nil else { return }
    show(section: .tabsArchive, row: "archive-after", profileID: profileID)
  }
  func showNewProfile(sourceSpace: SpaceID? = nil) {
    settings.profiles.beginCreate(sourceSpace: sourceSpace)
    show(pane: .profiles)
  }
  func showLibrary(section: LibrarySection? = nil, boostsPresentation: BoostsPresentation? = nil, boostsProfileID: ProfileID? = nil) {
    guard let controller = app.frontStandardWindowController ?? app.makeWindow(), let window = controller.window else { return }
    librarySessions = librarySessions.filter { $0.value.controller != nil }
    app.downloadsCenter.refreshFiles()
    let archives = Dictionary(uniqueKeysWithValues: app.model.profiles.map { ($0.id, app.archiveSink.store(for: $0.id)) })
    let histories = Dictionary(uniqueKeysWithValues: app.model.profiles.compactMap { profile in app.stores.history(for: profile.id).map { (profile.id, $0) } })
    let session = makeLibrarySession(controller)
    session.model.registerStores(archives: archives, histories: histories)
    let target = section ?? session.model.section
    if target == .boosts, let boostsPresentation, session.model.boostsPresentation != boostsPresentation {
      if let panel = session.panel { panel.setBoostLayout(boostsPresentation == .gallery ? "Gallery" : "List") }
      else { session.model.boostsPresentation = boostsPresentation }
    }
    // Outside entry points use the browser owner. Internal panel navigation
    // never calls this method and keeps the user's filter selection.
    if let profileID = (target == .boosts ? boostsProfileID : nil) ?? controller.context.focusedSpace?.profileID {
      if target == .downloads, session.model.downloadProfileFilter != profileID { session.model.downloadProfileFilter = profileID }
      if (target == .history || target == .boosts), session.model.historyProfileID != profileID { session.model.historyProfileID = profileID }
    }
    session.show(section: section)
    window.makeKeyAndOrderFront(nil); NSApp.activate(); app.scheduleMenuRebuild()
  }
  func makeLibrarySession(_ controller:BrowserWindowController) -> AppLibrarySession {
    if let session = librarySessions[controller.windowID] { return session }
    let archives = Dictionary(uniqueKeysWithValues:app.model.profiles.map { ($0.id,app.archiveSink.store(for:$0.id)) })
    let histories = Dictionary(uniqueKeysWithValues:app.model.profiles.compactMap { profile in app.stores.history(for:profile.id).map { (profile.id,$0) } })
    let model = LibraryViewModel(model:app.model,defaults:.standard,actions:self,downloads:self,captures:captures,
      archives:archives,histories:histories,snapshot:app.snapshotStore,faviconStore:app.stores.favicons,settingsActions:self,
      historyResolver:{ [weak app] in app?.stores.history(for:$0) })
    model.boostsProvider = app.stores.boosts
    model.mediaFolders = mediaFolders
    controller.onLibraryIdleRefresh = { [weak app] in app?.scheduleLibraryPrebuild() }
    let session = AppLibrarySession(model:model,controller:controller); librarySessions[controller.windowID] = session
    return session
  }
  func cancelLibraryIdleWork() { for session in librarySessions.values { session.cancelIdleWork() } }
  /// Window ▸ View Easels & Notes: the in-window Library at its Easels page (Easels and Notes).
  func showLibraryEasels() {
    showLibrary()
    activeLibrarySession?.panel?.select(.easels, animated: false)
  }
  func toggleLibrary(section: LibrarySection? = nil) {
    if let session = activeLibrarySession, session.controller?.isLibraryOpen == true { session.close() }
    else { showLibrary(section: section) }
  }
  func closeLibrary() {
    activeLibrarySession?.close()
    app.scheduleMenuRebuild()
  }
  /// Present the native Library confirmation; the old SwiftUI flag has no observer.
  func requestClearArchive() {
    showLibrary(section: .archive)
    activeLibrarySession?.panel?.requestClearArchive()
  }
  func prepareForRemoteSuggestions(profileID: ProfileID) -> Bool { settingsPresenter.prepareForRemoteSuggestions(profileID: profileID) }
  @ObservationIgnored private weak var spaceManager: SpaceManagerView?
  @ObservationIgnored private var pendingManagerProfileAlert: NSAlert?
  /// No persistent preference writes: this context never arms hover previews.
  @ObservationIgnored private let managerPreferences: UserDefaults = SpaceManagerPreferences()
  func makeSpaceManagerView() -> NSView? {
    // Closing the last browser retains its model window for normal reopen.
    // Prefer a live browser, then that existing state; never create a window here.
    let id = app.frontStandardWindowController?.windowID ?? app.model.windows.first(where: { $0.style == .standard })?.id
    guard let id, app.model.windows.contains(where: { $0.id == id }) else { spaceManager = nil; return nil }
    if let spaceManager, spaceManager.context.windowID == id { spaceManager.prepareForPresentation(); return spaceManager }
    let context = SidebarContext(model: app.model, windowID: id, previewPreferences: managerPreferences)
    context.storedFavicons = app.stores.sidebarFavicons
    context.faviconProvider = { tab in NoteTab.matches(tab.url) ? NoteTab.faviconImage : nil }
    context.systemAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    let manager = SpaceManagerView(context: context)
    manager.onIntent = { [weak self, weak context] intent in
      guard let self, let context, self.app.model.windows.contains(where: { $0.id == context.windowID }) else { return false }
      switch intent {
      case .hoverPreview: return true
      case .toggleSidebar, .openCommandBar, .newTab, .goBack, .goForward, .reload, .stopLoading,
           .copyCurrentURL, .showLibrary, .manageSpaces: return false
      default: break
      }
      let factory = self.app.hostFactories[context.windowID]
      switch intent {
      case .setSpaceProfile(let space, let profile):
        if let factory { return factory.performSidebar(intent) ?? false }
        return self.confirmManagerProfileChange(spaceID: space, profileID: profile)
      case .openURL(let url, let parent, let index):
        // The Manager shows every Space: create the tab in the column it was
        // dropped on, not in the browser's focused Space, then select it there.
        return self.openDroppedURL(url, parent: parent, index: index, factory: factory, windowID: context.windowID)
      case .openInSplitView(let id), .addSplitView(let id), .addTabToSplit(let id):
        // Split View lives in the browser window: show the node's Space there,
        // then use the browser controller's own split path.
        guard let factory, let controller = factory.controller, let space = self.spaceID(containing: id) else { return false }
        if controller.context.focusedSpace?.id != space, factory.performSidebar(.switchSpace(space)) != true { return false }
        return controller.sidebar(controller.sidebar, didRequest: intent)
      case .deleteSpace, .deleteFolder, .deleteFolders:
        // The Manager's "…" ▸ Delete, folder Delete, and selection Delete confirm first,
        // with a sheet on the Library window (completion §3.3).
        return self.confirmManagerDelete(intent, context: context, factory: factory)
      default: break
      }
      if let factory, let handled = factory.performSidebar(intent) {
        if handled, case .select = intent { self.closeLibrary() }
        return handled
      }
      // No live browser (or a model-only intent): closing a pin must never archive it.
      switch intent {
      case .unloadTab: return false
      case .close(let id) where self.app.model.isPinned(tabID: id): return false
      case .copyLink(let id, let markdown), .copyAllLinks(let id, let markdown):
        return Self.copyCleanLinks(self.app.model, ids: [id], markdown: markdown)
      case .copyLinks(let ids, let markdown):
        return Self.copyCleanLinks(self.app.model, ids: ids, markdown: markdown)
      default: break
      }
      let accepted = ModelSidebarActions(context: context).perform(intent)
      if accepted { self.app.scheduleSave(); self.app.scheduleMenuRebuild() }
      return accepted
    }
    if let previous = spaceManager {
      manager.frame.size = previous.frame.size
      manager.layoutSubtreeIfNeeded()
      let clip = manager.scrollView.contentView
      var bounds = clip.bounds
      bounds.origin = previous.scrollView.contentView.bounds.origin
      clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
      manager.scrollView.reflectScrolledClipView(clip)
    }
    spaceManager = manager
    return manager
  }
  private func confirmManagerProfileChange(spaceID: SpaceID, profileID: ProfileID) -> Bool {
    guard let model = app.model,
      let request = ChangeProfileRequest(spaceID: spaceID, toProfile: profileID, in: model),
      pendingManagerProfileAlert == nil, let window = libraryWindow,
      window.attachedSheet == nil else { return false }
    let apply: @MainActor () -> Void = { [weak self] in
      guard let self, !self.app.terminationRequested, self.app.model === model,
        model.space(id: spaceID)?.profileID == request.fromProfileID,
        model.profile(id: profileID) != nil else { return }
      self.app.undoManager.beginUndoGrouping()
      model.moveSpace(id: spaceID, toProfile: profileID)
      self.app.undoManager.setActionName("Change Profile")
      self.app.undoManager.endUndoGrouping()
      self.app.scheduleSave(); self.app.scheduleMenuRebuild()
    }
    let preferences = UserDefaults.standard
    if preferences.object(forKey: request.dontShowAgainKey) != nil && !preferences.bool(forKey: request.dontShowAgainKey) {
      apply(); return true
    }
    let alert = makeSpaceProfileChangeAlert(request)
    pendingManagerProfileAlert = alert
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }; self.pendingManagerProfileAlert = nil
      guard response == .alertFirstButtonReturn else { return }
      if alert.suppressionButton?.state == .on { preferences.set(false, forKey: request.dontShowAgainKey) }
      apply()
    }
    return true
  }
  private func confirmManagerDelete(_ intent: SidebarIntent, context: SidebarContext, factory: EngineWebContentHostFactory?) -> Bool {
    guard let model = app.model, let window = libraryWindow else { return false }
    let alert: NSAlert?, ids: [ItemID]
    switch intent {
    case .deleteSpace(let id): alert = SidebarConfirmations.deleteSpaceAlert(model: model, spaceID: id); ids = []
    case .deleteFolder(let id): ids = [id]; alert = SidebarConfirmations.deleteFoldersAlert(model: model, ids: ids)
    case .deleteFolders(let selection, _): ids = selection; alert = SidebarConfirmations.deleteFoldersAlert(model: model, ids: ids)
    default: return false
    }
    guard let alert else { return false }
    let folders = ids.filter { model.node(id: $0)?.folder != nil }.count
    let restoreKeyboardFocus = context.keyboardFocusAfterDeletion()
    return SidebarConfirmations.present(alert, on: window) { [weak self, weak context] confirmed in
      guard let self, let context, confirmed else { return }
      let accepted: Bool
      if case .deleteSpace(let id) = intent { accepted = ModelSidebarActions(context: context).perform(.deleteSpace(id)) }
      else {
        var archived = 0
        let removal = { archived = model.archiveNodes(ids: ids) }
        if let controller = self.app.hostFactories[context.windowID]?.controller { controller.keepingSelection(removal) } else { removal() }
        accepted = archived > 0
      }
      guard accepted else { return }
      restoreKeyboardFocus()
      if case .deleteSpace = intent, let panel = self.activeLibrarySession?.panel, panel.isPresented { panel.focusRail() }
      self.app.scheduleSave(); self.app.scheduleMenuRebuild()
      if folders > 0 {
        self.app.hostFactories[context.windowID]?.controller?.showModelUndoToast(SidebarConfirmations.folderToast(count: folders))
      }
    }
  }
  /// The Space whose Pinned or Today list holds `id`, through folders and splits.
  private func spaceID(containing id: ItemID) -> SpaceID? {
    var current = id
    for _ in 0..<64 {
      switch app.model.parent(of: current) {
      case .spacePinned(let space)?, .spaceToday(let space)?: return space
      case .folder(let folder)?: current = folder
      case .splitPane(let split)?: current = split
      case .favorites?, nil: return nil
      }
    }
    return nil
  }
  private func openDroppedURL(_ url: URL, parent: NodeParent, index: Int?, factory: EngineWebContentHostFactory?, windowID: WindowID) -> Bool {
    guard let model = app.model else { return false }
    let title = url.host() ?? url.absoluteString
    let space: SpaceID?
    switch parent {
    case .spacePinned(let id), .spaceToday(let id): space = id
    case .folder(let folder): space = spaceID(containing: folder)
    case .favorites, .splitPane: space = nil
    }
    guard let space, model.space(id: space) != nil else { return false }
    let tab = model.newTab(in: space, url: url, title: title, at: parent == .spaceToday(space) ? index : 0)
    // A refused move (a folder removed meanwhile) keeps the new tab at the top of Today.
    if parent != .spaceToday(space) { _ = model.moveNode(id: tab.id, to: parent, at: index) }
    if let factory { _ = factory.performSidebar(.select(nodeID: tab.id, space: space)) }
    else { model.selectNode(windowID: windowID, spaceID: space, nodeID: tab.id) }
    app.scheduleSave(); app.scheduleMenuRebuild()
    return true
  }
  func refreshSpaceManagerContext() {
    guard libraryWindow?.isVisible == true else { return }
    library?.refreshSpaceManagerView()
  }
  var downloads: [DownloadItemSnapshot] { app.downloadsCenter.downloads }
  var downloadHistoryError: String { app.downloadsCenter.downloadHistoryError }
  func refreshDownloads() async { await app.downloadsCenter.refreshDownloads() }
  private func status(_ message: String, pane: PaneID? = nil) {
    switch pane ?? settings.selectedPane {
    case .general: settings.general.errorText = message
    case .profiles: settings.profiles.errorText = message
    case .advanced: settings.advanced.statusText = message
    case .appIcon: settings.appIcon.errorText = message
    case .links: settings.linksError = message
    case .shortcuts: settings.shortcuts.statusText = message
    }
    AppDelegate.commandLog(message)
  }
  var canImportPasswordsAndCookies: Bool { app.importRunner.canImportPasswordsAndCookies }
  var canImportBrowserPasswords: Bool { app.importRunner.canImportBrowserPasswords }
  var hasUnfinishedSecretsImport: Bool { app.importRunner.hasUnfinishedSecretsImport }
  func isDefaultBrowser() -> Bool { app.defaultBrowserService.isDefaultBrowser }
  @ObservationIgnored private(set) var defaultBrowserRequest: Task<Void, Never>?
  func setAsDefaultBrowser() -> String? {
    defaultBrowserRequest = Task { @MainActor in
      let state = await app.defaultBrowserService.makeDefault()
      settings.general.refresh()
      settings.links.isDefaultBrowser = state.values.allSatisfy { $0 }
      settings.general.errorText = settings.links.isDefaultBrowser ? "" : "The default browser was not changed."
    }
    return nil
  }
  func checkForUpdates() {
    if let updater = app.updater { updater.checkForUpdates() }
    else { app.checkForUpdatesAfterPaint = true }
  }
  func showUpdatesUnavailable() { status(UpdaterController.unavailableStatus, pane: .general); show(pane: .general) }
  func openMoreSettings() { openURL(URL(string: "chrome://settings")!, profileID: settings.selectedProfileID) }
  // One source with Help ▸ Troubleshooting (page-platform §4.11.3–4).
  func revealOpenDataFolder() { TroubleshootingActions.shared.revealOpenData() }
  func copyOpenInfoToPasteboard() { copyText(TroubleshootingActions.openInfoText) }
  func deleteProfileData(profileID: ProfileID, dataDirectoryName: String) async -> String? {
    do { try await app.profileTeardown.wipe(profileID:profileID,directory:dataDirectoryName); return nil }
    catch { return "The Profile was removed, but its data could not be fully deleted. \(error.localizedDescription)" }
  }
  @ObservationIgnored var profileIconPicker: IconPickerController?
  func chooseProfileIcon(profileID: ProfileID, anchor: NSView) {
    guard let profile = app.model.profile(id:profileID), let window = anchor.window else { return }
    profileIconPicker?.close()
    let picker = IconPickerController(target:.profile,current:profile.icon,window:window,anchor:anchor.convert(anchor.bounds,to:nil)) { [weak self] icon in
      self?.settings.profiles.setIcon(icon,profileID:profileID)
    }
    profileIconPicker=picker
    picker.onClose = { [weak self, weak picker] in if self?.profileIconPicker === picker { self?.profileIconPicker=nil } }
    picker.show()
  }
  func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds) async -> String? { await clearBrowsingData(profileID: profileID, kinds: kinds, range: .all) }
  func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds, range: ClearDataRange) async -> String? {
    guard kinds.rawValue > 0, (kinds.rawValue & ~15) == 0 else { return "Choose valid browsing data to clear." }
    guard let profile = app.model.profile(id: profileID) else { return "This profile is no longer available." }
    let engineKinds = kinds.intersection([.cookies, .cache, .downloads])
    // A History-only clear must not load a native context just to clear Open's
    // HistoryStore. If already loaded, clear Chromium's own history as well.
    let identifier = profile.id == app.model.defaultProfile?.id ? "Default" : profile.dataDirectoryName
    let loaded = OEEngine.shared.contexts.first { $0.identifier == identifier && $0.state == .live }
    let context = engineKinds.isEmpty ? loaded :
      (loaded ?? app.hostFactories.values.compactMap { $0.context(for: profileID, create: true) }.first)
    if !engineKinds.isEmpty, context == nil { return "This profile is not open." }
    let now = Date()
    let end = range == .all ? Date.distantFuture : now
    let seconds: TimeInterval? = switch range {
    case .lastHour: 3_600; case .lastDay: 86_400; case .lastWeek: 604_800
    case .lastFourWeeks: 2_419_200; case .all: nil
    }
    let begin = seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast
    if kinds.contains(.history) {
      guard let history = app.stores.history(for: profileID) else { return "This profile is no longer available." }
      await app.stores.flushHistory()
      do { try await history.deleteVisits(since: seconds.map { now.addingTimeInterval(-$0) }, through: end) }
      catch { return error.localizedDescription }
    }
    if let context {
      let nativeKinds = OEBrowsingDataKinds(rawValue: UInt32(kinds.rawValue))
      let error: String? = await withCheckedContinuation { continuation in
        context.clearBrowsingData(nativeKinds, from: begin, to: end) { error in
          continuation.resume(returning: error?.localizedDescription)
        }
      }
      if let error { return error }
    }
    if kinds.contains(.downloads) {
      do { try await app.downloadsCenter.clearHistory(profileID: profileID, since: seconds.map { now.addingTimeInterval(-$0) }, through: end) }
      catch { return error.localizedDescription }
    }
    return nil
  }
  func openProfileSubpage(profileID: ProfileID, page: ProfilePage) {
    let address: String
    switch page {
    case .privacy: address = "chrome://settings/privacy"
    case .passwords: address = "chrome://password-manager/passwords"
    case .paymentMethods: address = "chrome://settings/payments"
    case .notifications: address = "chrome://settings/content/notifications"
    }
    openURL(URL(string:address)!, profileID:profileID)
  }
  func openPreviewsSettings() {} // General owns its one sheet.
  func extensionShortcutConflicts(profileID: ProfileID) -> [ExtensionShortcutConflict] {
    guard app.engineReady, let profile = app.model.profile(id: profileID),
          let context = OEEngine.shared.contexts.first(where: { $0.identifier == profile.dataDirectoryName }) else { return [] }
    return app.extensionPrompts.table(context.extensions).conflicts
  }
  func keyBindingsDidChange(store: KeyBindingStore) { app.reloadKeyBindings() }
  func openEssentialShortcuts() { app.performCommand("keyboard-shortcuts-edu", payload: nil) }
  func runImport(plan: ImportPlan) async -> ImportOutcome { await app.importRunner.run(plan: plan, firstRun: false) }
  func installImportedExtension(_ candidate: ImportExtensionCandidate) async -> ImportExtensionInstallResult {
    await app.importRunner.installExtension(candidate, window: settingsPresenter.window)
  }
  // The store has already persisted and emitted the engine event.
  func setAdBlockEnabled(_ on: Bool, profileID: ProfileID) {
    if !app.adBlockEngineAdapter.isSupported {
      status("Ad blocking is not active in this build. Your preferences were saved.", pane: .advanced)
    }
  }
  func setEnabledBlockLists(_ ids: [String], profileID: ProfileID) { setAdBlockEnabled(true, profileID: profileID) }
  func setAdBlockExcludedDomains(_ domains: [String], profileID: ProfileID) { setAdBlockEnabled(true, profileID: profileID) }
  func adBlockDebugInfo(profileID: ProfileID) -> String {
    guard let profile = app.model.profile(id: profileID),
      let context = OEEngine.shared.contexts.first(where: { $0.identifier == profile.dataDirectoryName }) else { return "" }
    let status = context.adBlockStatus
    return status.keys.sorted().map { "\($0): \(status[$0]!)" }.joined(separator: "\n")
  }
  func setTabSleepMode(_ mode: TabSleepMode) {
    app.tabSleep.reconcileSettingsPolicy()
  }
  func setApplicationIcon(id: String) { settings.appIcon.errorText = app.applicationIcon.apply(id: id) ?? "" }
  func setWebsiteAppearance(_ value: String) {
    _ = WebsiteAppearance.select(commandID: "appearance-" + value)
    app.scheduleMenuRebuild()
  }
  /// Settings ▸ Advanced "Reset Translated-site Prompts" (page-platform §4.7.7): app scope, every profile.
  func resetTranslatePrompts(profileID: ProfileID) -> String? { TranslatePreferences().reset(); return nil }
  func openURL(_ url: URL, profileID: ProfileID) {
    guard app.model.profile(id:profileID) != nil else { return }
    guard let space = app.model.spaces.first(where: { $0.profileID == profileID }) else {
      // guess S10: Arc's destination for a Profile with no Space is unverified.
      app.openProfilePage(url,profileID:profileID); return
    }
    guard
      // A window of the main model: a Blank Window front window does not hold this Space.
      let controller = app.frontMainModelWindowController ?? app.makeWindow(focusedSpaceID: space.id),
      let factory = app.hostFactories[controller.windowID] else { return }
    app.focusWindow(controller.windowID, activate: true); factory.focus(space: space)
    if url.scheme == "chrome", url.host() == "extensions", url.query == nil, url.fragment == nil {
      let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      // Settings uses the same focused-Space singleton rule as the Extensions menu.
      if path.isEmpty || path == "shortcuts" {
        _ = factory.performAppCommand(path.isEmpty ? "manage-extensions" : "extension-shortcuts"); return
      }
    }
    if let page = AutofillPage.allCases.first(where: { $0.matches(url) }) {
      factory.openAutofillPage(page, in: space); return
    }
    _ = factory.openNewTab(url: url, background: false)
  }
  func openHelp(topic: String) { if let profile = app.model.defaultProfile { openURL(AppCommand.helpURL, profileID: profile.id) } }
  func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
  func openLibrary() { settingsPresenter.window?.orderOut(nil); showLibrary(section: .archive) }
  // Library owns the durable archive/capture mutations. These are notifications.
  func previewArchived(url: URL, profileID: ProfileID) {
    guard app.model.profile(id:profileID) != nil,
          let controller = activeLibrarySession?.controller, controller.isLibraryOpen else { return }
    controller.peekController.openLibraryPreview(url:url,profileID:profileID)
  }
  func restoreArchived(id: ItemID) { app.scheduleSave(); app.scheduleMenuRebuild() }
  func deleteArchived(id: ItemID) { app.scheduleMenuRebuild() }
  func clearArchive() { app.scheduleMenuRebuild() }
  func revealDownload(id: String) { app.downloadsCenter.fileAction("reveal", key: id) }
  func retryDownload(id: String) { app.downloadsCenter.retry(id) }
  func cancelDownload(id: String) { app.downloadsCenter.cancel(id) }
  func pauseDownload(id: String) { app.downloadsCenter.pause(id) }
  func resumeDownload(id: String) { app.downloadsCenter.resume(id) }
  func openDownload(id: String) { app.downloadsCenter.fileAction("open", key: id) }
  func copyDownload(id: String) { app.downloadsCenter.fileAction("copy", key: id) }
  func trashDownload(id: String) { app.downloadsCenter.fileAction("trash", key: id) }
  func removeDownload(id: String) { app.downloadsCenter.remove(id) }
  func deleteCapture(id: UUID) {} // Library already removed the file and index.
  private func captureURL(_ id: UUID) -> URL? { captures.captures.first { $0.id == id }.flatMap { library?.captureURL($0) } }
  func revealCapture(id: UUID) { if let url = captureURL(id) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
  #if OPEN_AUTOMATION
  var recordCaptureFileActions = false
  var captureFileActions: [String] = []
  #endif
  func openCapture(id: UUID) {
    guard let url = captureURL(id) else { return }
    #if OPEN_AUTOMATION
    // Same OS-handoff receipt as Downloads: never launch the user's Preview in a suite.
    if recordCaptureFileActions {
      if captureFileActions.count >= 32 { captureFileActions.removeFirst() }
      captureFileActions.append(url.lastPathComponent); return
    }
    #endif
    NSWorkspace.shared.open(url)
  }
  func copyCapture(id: UUID) { if let url = captureURL(id), let image = NSImage(contentsOf: url) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) } }
  func saveCapture(id: UUID, to: URL) -> String? { guard let url = captureURL(id) else { return "This capture is no longer available." }; do { try FileManager.default.copyItem(at: url, to: to); return nil } catch { return "The capture could not be saved. \(error.localizedDescription)" } }
  func openHistoryItem(url: URL) { if let profileID = library?.historyProfileID { openURL(url, profileID: profileID) } }
  func flushHistoryWrites() async { await app.stores.flushHistory() }
  func viewSpace(id: SpaceID) {
    guard let controller = app.frontMainModelWindowController ?? app.makeWindow(focusedSpaceID: id), let space = app.model.space(id: id), let factory = app.hostFactories[controller.windowID] else { return }
    app.focusWindow(controller.windowID, activate: true); factory.focus(space: space)
  }
}

/// A read-only in-memory override. NSArgumentDomain is process-shared, so
/// mutating it on a suite would also disable previews in browser sidebars.
private final class SpaceManagerPreferences: UserDefaults, @unchecked Sendable {
  override func set(_ value: Any?, forKey defaultName: String) {}
  override func object(forKey defaultName: String) -> Any? {
    if defaultName == "open.general.previewsEnabled" { return false }
    return super.object(forKey: defaultName)
  }
  override func bool(forKey defaultName: String) -> Bool {
    if defaultName == "open.general.previewsEnabled" { return false }
    return super.bool(forKey: defaultName)
  }
}

extension AppSettingsActions {
  /// Space Manager copies with no browser window: the same clean payload as the sidebar, without
  /// a toast (no window to show it in).
  @MainActor static func copyCleanLinks(_ model: BrowserModel, ids: [ItemID], markdown: Bool) -> Bool {
    guard let payload = model.cleanLinkPayload(ids: ids, markdown: markdown) else { return false }
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.setString(payload.text, forType: .string)
  }
}
