import AppKit
import OpenEngine
import OpenModel
import OpenStore
import OpenFeatures
import QuartzCore
import OpenCommands
import OpenSettings

/// Owns the model, its stores, and the windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, OEEngineDelegate, OEBrowserContextDelegate {
  let archiveClock = AppArchiveClock()
  var todayAutoArchive: TodayAutoArchiveController?
  var expirySweeper: ExpirySweeper?
  var options = LaunchOptions(arguments: [])
  private(set) var model: BrowserModel!
  private(set) var isFirstRun = false
  var firstRunSaved = false
  var firstRunWindowController: FirstRunWindowController?
  var lastFirstRunStep = "none"
  var importInProgress = false
  private var modelSaveObserver: UUID?
  private weak var firstRunDefaultModel: BrowserModel?
  lazy var importRunner = AppImportRunner(app: self)
  var firstContentView: NSView? { firstRunWindowController?.window?.contentView ?? windowControllers.first?.window?.contentView }
  private(set) var snapshotStore: SnapshotStore!
  private(set) var archiveSink: ProfileArchiveSink!
  private(set) var directories: ProfileDirectories!
  /// The engine layout step's outcome (and the data root lock).
  private(set) var engine: OpenDataRoot.EnginePreparation!
  private(set) var hostFactories: [WindowID: EngineWebContentHostFactory] = [:]
  private(set) var windowControllers: [BrowserWindowController] = []
  let incognitoSessions = IncognitoSessions()
  // CEF pumps AppKit without a normal per-event undo group boundary. The
  // model opens one group per command; multi-operation UI actions may nest.
  let undoManager: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; return manager }()
  private(set) var engineReady = false
  private(set) var terminationRequested = false
  private var faviconShutdownTask: Task<Void, Never>?
  private var historyQuitTask: Task<Void, Never>?
  /// Uptime of the last quit-time history flush. A quit cancelled later (downloads alert,
  /// beforeunload) must flush again on the next attempt, so the flush is valid only briefly.
  private var historyQuitFlushedAt: TimeInterval?
  private(set) var shutdownPrepared = false
  private var lateAsyncEngineCalls = 0
  private var asyncEngineCalls: [String: Int] = [:]
  private var shutdownTrace: [[String: Any]] = []
  lazy var stores = AppStores(app: self)
  lazy var profileTeardown = ProfileTeardown(app: self)
  var pendingMissingProfileTitles: [String] = []
  var missingProfileNotice: NSAlert?
  var missingProfileNoticeTitles: [String] = []
  var missingProfileNoticeCount = 0
  lazy var extensionPrompts = ExtensionPromptPresenter(app: self)
  lazy var extensionsMainMenu = ExtensionsMainMenuProvider(app: self)
  /// Mini players, auto-PiP and the media sleep feed (media-pip §7.2).
  lazy var media = MediaCoordinator(app: self, rulesURL: options.pipSiteRules)
  /// Tab sleep (app-shell §4.7, Step G): one SleepController, started after first paint.
  lazy var tabSleep = AppSleepCoordinator(app: self)
  /// Quit order step 1 (app-shell §5.3) runs once, before the snapshot save.
  private var sleepQuitTask: Task<Void, Never>?
  private var sleepQuitCaptured = false
  lazy var settingsPresenter = AppSettingsActions(app: self)
  private(set) var updater: UpdaterController?
  var checkForUpdatesAfterPaint = false
  lazy var applicationIcon = ApplicationIconController(app: self)
  lazy var downloadsCenter = DownloadsCenter(app: self)
  let defaultBrowserService = DefaultBrowserService()
  lazy var linkExecutor = AppLinkExecutor(app: self)
  lazy var linkIntake = ExternalLinkIntake(executor: linkExecutor, snapshot: { [unowned self] in self.linkExecutor.snapshot() })
  var lastLittleOpenRequest: LittleOpenRequest?
  var executedExternalLink = false
  /// Only a fresh launch fallback is eligible for removal by its first Little Open link.
  /// Saved standard windows are never tagged. Input or navigation clears this tag.
  var autoCreatedLaunchWindowID: WindowID?
  var initialWindowInputMonitor: Any?
  /// Library ▸ Captures writer (page-platform §4.6.6); one per app, shared by every window.
  lazy var captureLibrary = CaptureLibraryWriter(app: self, root: directories.root)
  var keyBindings = KeyBindingStore.empty
  let fallbackKeyboard = KeyboardRouter()
  var commandServicesPrepared = false
  var hotkeyService: GlobalHotkeyService?
  var hotkeyError: String?
  var hotkeyAttempts = 0
  var menuRebuildTask: Task<Void, Never>?
  var afterPaintTask: Task<Void, Never>?
  var littleOpenCoordinator: LittleOpenCoordinator!
  var pendingLittleOpenBlankStamps: [TimeInterval?] = []
  var littleOpenProfileAlert: NSAlert?
  var littleOpenHosts: [ItemID: EngineWebContentHost] = [:]
  var commandWindowObserver: (any NSObjectProtocol)?
  var commandDefaultsObserver: (any NSObjectProtocol)?
  private var numberedShortcutOptions = ""
  private var currentNumberedShortcutOptions: String {
    "\(UserDefaults.standard.bool(forKey: "open.shortcuts.includeFavoritesInTabNumbering")):\(UserDefaults.standard.bool(forKey: "open.shortcuts.switchToNinthEnabled"))"
  }
  private var activeWindowID: WindowID?
  private(set) var startupEvidence: [String: Any] = [:]
  #if OPEN_AUTOMATION
    let activationTrace = ActivationTrace()
    private var automation: AutomationServer?
  #endif

  var frontWindowController: BrowserWindowController? {
    windowControllers.first { $0.windowID == activeWindowID }
      ?? windowControllers.first { $0.window?.isKeyWindow == true } ?? windowControllers.first
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchTiming.shared.mark("didFinishLaunching")
    SettingsDefaults.register(in: .standard)
    NSApp.mainMenu = MainMenu.build()
    MainMenu.targetWindowCommands(frontWindowController.flatMap { hostFactories[$0.windowID] })
    NSApp.setActivationPolicy(.regular)
    // The window and sidebar come from the snapshot and do not wait for the
    // engine (docs/architecture.md, launch tactics). Pages created before
    // the engine is ready wait inside OpenEngine.
    showWindowsIfNeeded()
    tabSleep.installSettingsPolicy()
    installScripting()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let frontWindowController { frontWindowController.showWindow(nil) }
    else { showWindowsIfNeeded(ignoringLittleOpen: true) }
    return false
  }

  private lazy var pageQuit = PageQuitCoordinator(app: self)

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if historyQuitTask != nil || faviconShutdownTask != nil || sleepQuitTask != nil { return .terminateCancel }
    if downloadsCenter.shouldKeepBrowsing() { return .terminateCancel }
    let now = ProcessInfo.processInfo.systemUptime
    if !shutdownPrepared, importRunner.hasPendingUndo || (historyQuitFlushedAt.map({ now - $0 > 5 }) ?? true) {
      historyQuitTask = Task { @MainActor in
        await self.stores.flushHistory()
        await self.importRunner.flushUndoForQuit()
        self.historyQuitFlushedAt = ProcessInfo.processInfo.systemUptime; self.historyQuitTask = nil
        NSApp.terminate(nil)
      }
      return .terminateCancel
    }
    if engineReady, !shutdownPrepared, !pageQuit.shouldTerminate() { return .terminateCancel }
    if !sleepQuitCaptured, engineReady, !shutdownPrepared, tabSleep.controller != nil {
      // OEApplication has no terminateLater: capture sleep history first (bounded at 3 s),
      // then ask again. The snapshot save and engine shutdown follow below.
      sleepQuitTask = Task { @MainActor [weak self] in
        guard let self else { return }
        await self.tabSleep.captureForQuit()
        self.sleepQuitCaptured = true; self.sleepQuitTask = nil
        NSApp.terminate(nil)
      }
      return .terminateCancel
    }
    let wasEngineReady = engineReady
    let icons = wasEngineReady && !windowControllers.isEmpty ? stores.sidebarFavicons : nil
    terminationRequested = true
    for controller in windowControllers { controller.closeThemeEditor() }
    extensionPrompts.cancelAll()
    if let commandWindowObserver { NotificationCenter.default.removeObserver(commandWindowObserver) }; commandWindowObserver = nil
    if let commandDefaultsObserver { NotificationCenter.default.removeObserver(commandDefaultsObserver) }; commandDefaultsObserver = nil
    if let initialWindowInputMonitor { NSEvent.removeMonitor(initialWindowInputMonitor) }; initialWindowInputMonitor = nil
    hotkeyService?.unregister(); afterPaintTask?.cancel(); menuRebuildTask?.cancel()
    stopAutoArchive()
    saveState()
    prepareForEngineShutdown()
    if let icons, !icons.isIdle {
      // OEApplication supports terminateCancel, not terminateLater. Close hosts
      // above, drain accepted cache work, then request shutdown via OpenEngine.
      faviconShutdownTask = Task { @MainActor in
        await icons.flush()
        OEEngine.shared.terminate()
      }
      return .terminateCancel
    }
    if !wasEngineReady { CFRunLoopStop(CFRunLoopGetMain()) }
    return .terminateNow
  }

  // MARK: Model

  /// Prepares the data root (lock, Chromium's layout, Open's stores, profile
  /// folders) and loads the model. Runs before the engine starts.
  @discardableResult
  func prepareData() -> ProfileDirectories {
    if let directories { return directories }
    let root = options.userDataDirectory
    isFirstRun = !options.skipFirstRun && !FileManager.default.fileExists(atPath: root.appendingPathComponent("State/browser.json").path)
    // Chromium's data layout is its own step, before the snapshot loads. A
    // migration problem selects the old layout for this launch (retried on
    // the next one); it never touches the model.
    do {
      engine = try OpenDataRoot.prepareEngineLayout(root: root)
      try ProfileTeardown.finishPendingWipes(directories: ProfileDirectories(root: engine.root))
    } catch {
      FileHandle.standardError.write(Data("Open: data root \(root.path) unavailable: \(error)\n".utf8))
      exit(1)
    }
    let layout = engine.result
    if !layout.report.moved.isEmpty || !layout.report.skipped.isEmpty || layout.problem != nil {
      FileHandle.standardError.write(Data(
        "Open: engine layout \(layout.layout) in \(String(format: "%.1f", layout.milliseconds)) ms\n".utf8))
    }
    snapshotStore = SnapshotStore(root: root)
    // Only an unreadable snapshot starts a fresh model, and the unreadable
    // file is kept beside the new one, never overwritten.
    var loaded: BrowserModel?
    do {
      loaded = try snapshotStore.loadData().map(SnapshotMapper.model(from:))
    } catch {
      let kept = snapshotStore.fileURL.deletingLastPathComponent()
        .appendingPathComponent("browser.unreadable-\(Int(Date().timeIntervalSince1970)).json")
      try? FileManager.default.moveItem(at: snapshotStore.fileURL, to: kept)
      FileHandle.standardError.write(Data(
        "Open: snapshot unreadable (kept as \(kept.lastPathComponent)), starting fresh: \(error)\n".utf8))
    }
    let model: BrowserModel
    if let loaded { model = loaded }
    else {
      model = Self.makeDefaultModel()
      autoCreatedLaunchWindowID = model.windows.first?.id
    }
    applyLaunchWindowPreference(to: model)
    let repaired = repairMissingProfiles(in: model)
    if model.windows.isEmpty, let space = model.spaces.first {
      let state = BrowserWindowState(focusedSpaceID: space.id)
      model.windows.append(state)
      autoCreatedLaunchWindowID = state.id
    }
    do {
      try OpenDataRoot.prepare(root: root, model: model)
      if repaired { try snapshotStore.saveNow(model: model) }
    } catch {
      FileHandle.standardError.write(Data("Open: data root \(root.path) unavailable: \(error)\n".utf8))
      exit(1)
    }
    let directories = ProfileDirectories(root: root.standardizedFileURL.resolvingSymlinksInPath())
    self.directories = directories
    if isFirstRun { firstRunDefaultModel = model }
    installModel(model)
    // Launch URLs enter the snapshot-backed model before window composition.
    // Only the final selection gets a page after engine readiness.
    if let state = model.windows.first(where: { $0.style == .standard }),
      let space = model.space(id: state.focusedSpaceID)
    {
      for url in isFirstRun ? [] : options.initialURLs {
        autoCreatedLaunchWindowID = nil
        let tab = model.newTab(in: space.id, url: url, at: 0)
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: tab.id)
      }
    }
    if !isFirstRun { prepareLittleOpen() }
    if !isFirstRun { startAutoArchiveIfNeeded() }
    LaunchTiming.shared.mark("modelLoaded")
    return directories
  }

  /// One observer/service seam for initial load and the first-run model swap.
  func installModel(_ model: BrowserModel) {
    if repairMissingProfiles(in: model) {
      do { try snapshotStore.saveNow(model: model) }
      catch { FileHandle.standardError.write(Data("Open: repaired Profiles could not be saved: \(error)\n".utf8)); exit(1) }
    }
    if let modelSaveObserver { self.model?.removeObserver(modelSaveObserver) }
    self.model = model
    if isFirstRun { autoCreatedLaunchWindowID = nil }
    archiveSink = ProfileArchiveSink(directories: directories) { [weak model] id in
      let profile = id.flatMap { model?.profile(id: $0) } ?? model?.defaultProfile
      return profile?.dataDirectoryName ?? "Default"
    }
    model.archiveSink = archiveSink; model.undoManager = undoManager
    modelSaveObserver = model.addObserver { [weak self] _ in self?.scheduleSave(); self?.scheduleMenuRebuild(); self?.purgeScriptingWrappers() }
    // Profile creation belongs to the currently installed model, including an import swap.
    tabSleep.installSettingsPolicy()
    purgeScriptingWrappers()
  }

  /// Runs at the first of applicationDidFinishLaunching and
  /// engineDidInitialize (their order is not fixed).
  private func showWindowsIfNeeded(ignoringLittleOpen: Bool = false) {
    #if OPEN_AUTOMATION
    // Validate the packaged engine before its first on-screen launch.
    if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_OFFSCREEN_SMOKE"] == "1" { return }
    #endif
    prepareData()
    if isFirstRun && !firstRunSaved && windowControllers.isEmpty {
      if firstRunWindowController == nil {
        let actions = AppFirstRunActions(app: self)
        let viewModel = FirstRunViewModel(settings: settingsPresenter.settings, actions: actions, directory: options.arcDirectory)
        firstRunWindowController = FirstRunWindowController(model: viewModel)
        lastFirstRunStep = "welcome"
      }
      firstRunWindowController?.showWindow(nil)
      return
    }
    guard windowControllers.isEmpty else { return }
    guard ignoringLittleOpen || littleOpenCoordinator?.sessions.isEmpty != false else { return }
    let states = model.windows.filter { $0.style == .standard }
    for state in states.isEmpty ? Array(model.windows.prefix(1)) : states {
      createWindowController(state: state)
    }
    todayAutoArchive?.finishStartupComposition()
    LaunchTiming.shared.mark("windowShown")
  }

  func drawWindowsBeforeEngine() {
    showWindowsIfNeeded()
    firstRunWindowController?.window?.contentView?.layoutSubtreeIfNeeded()
    firstRunWindowController?.window?.displayIfNeeded()
    for controller in windowControllers {
      controller.prepareForInitialDisplay()
      controller.window?.contentView?.layoutSubtreeIfNeeded()
      controller.window?.displayIfNeeded()
    }
    CATransaction.flush()
    startupEvidence = [
      "sidebarClass": windowControllers.first.map { String(reflecting: type(of: $0.sidebar)) } ?? "",
      "pagesBeforeEngine": OEEngine.shared.allWebContents.count,
      "contextsBeforeEngine": OEEngine.shared.contexts.count,
      "visibleWindows": windowControllers.filter { $0.window?.isVisible == true }.count,
    ]
    #if OPEN_AUTOMATION
    startupEvidence["adBlockOwnerOpenBeforeEngine"] = stores.existingAdBlock != nil
    #endif
  }

  @discardableResult
  private func createWindowController(state: BrowserWindowState, privateModel: BrowserModel? = nil, session: IncognitoSession? = nil) -> BrowserWindowController {
    let windowModel = privateModel ?? model!
    windowModel.setWindowContentVisible(windowID: state.id, visible: true)
    let factory = EngineWebContentHostFactory(app: self, state: state, model: windowModel, incognitoSession: session)
    hostFactories[state.id] = factory
    let title = session.map { model.profiles.count > 1 ? "Incognito · " + $0.parent.name : "Incognito" }
    let controller = BrowserWindowController(model: windowModel, windowID: state.id, factory: factory,
      snapshotStore: session == nil ? snapshotStore : nil, incognitoTitle: title,
      siteControlSource: factory.siteControlSource, siteControlActions: factory.siteControlSource)
    if session == nil { controller.context.storedFavicons = stores.sidebarFavicons }
    factory.attach(controller)
    windowControllers.append(controller)
    if session == nil { media.attach(factory); tabSleep.attach(factory) }
    activeWindowID = state.id
    MainMenu.targetWindowCommands(factory)
    if session == nil { todayAutoArchive?.attach(context: controller.context) }
    controller.showWindow(nil)
    if session == nil { showMissingProfileNoticeIfNeeded(on: controller.window) }
    if engineReady { factory.engineDidBecomeReady() }
    return controller
  }

  @discardableResult
  func makeWindow(focusedSpaceID: SpaceID? = nil) -> BrowserWindowController? {
    guard firstRunWindowController == nil || firstRunSaved else { return nil }
    // Closing the final window keeps its state for reopen and relaunch.
    if frontStandardWindowController == nil, let state = model.windows.first(where: { $0.style == .standard }) {
      return createWindowController(state: state)
    }
    guard let spaceID = focusedSpaceID ?? frontStandardWindowController?.context.focusedSpace?.id ?? model.spaces.first?.id,
      let state = withoutWindowUndo({ model.createWindow(focusedSpaceID: spaceID) }) else { return nil }
    let offset = Double(windowControllers.count * 24)
    state.frameX += offset; state.frameY -= offset
    // A new window copies the key window's toolbar (commandbar-completion §4.6.1; guess).
    state.showsToolbar = frontWindowController?.context.window?.showsToolbar ?? false
    let controller = createWindowController(state: state)
    scheduleSave(); return controller
  }

  var frontStandardWindowController: BrowserWindowController? {
    let normal = windowControllers.filter { hostFactories[$0.windowID]?.isIncognito == false }
    return NSApp.orderedWindows.compactMap { window in normal.first { $0.window === window } }.first ?? normal.first
  }

  @discardableResult
  func makeIncognitoWindow(parent: Profile? = nil, url: URL? = nil) -> BrowserWindowController? {
    guard engineReady, let parent = parent ?? frontStandardWindowController?.context.focusedSpace.flatMap({ model.profile(id: $0.profileID) }) ?? model.defaultProfile else { return nil }
    let session = incognitoSessions.acquire(parent: parent, app: self)
    let profile = Profile(name: parent.name, settings: parent.settings, dataDirectoryName: "Incognito")
    let space = Space(title: "Incognito", icon: .symbol("eyeglasses"), profileID: profile.id)
    let state = BrowserWindowState(focusedSpaceID: space.id)
    let memory = BrowserModel(profiles: [profile], spaces: [space], windows: [state])
    let undo = UndoManager(); undo.groupsByEvent = false; memory.undoManager = undo
    let controller = createWindowController(state: state, privateModel: memory, session: session)
    if let factory = hostFactories[state.id] {
      if let url { factory.openNewTab(url: url, background: false) }
      else { factory.showCommandBar(.newTab) }
    }
    return controller
  }

  @objc func newWindow(_ sender: Any?) { makeUserWindow() }

  /// File ▸ New Window and Blank Window: Arc opens every window the user creates with the command bar
  /// open in New Tab mode (`showCommandBarOnNewlyCreatedWindows`, one Bool in Arc's app state beside its
  /// session-restoration fields; F0098, F0157, A0359, S2 19/0029). Windows restored at launch and windows
  /// made for a moved tab do not (guess for restoration; no launch capture), so cold launch pays nothing.
  @discardableResult
  func makeUserWindow() -> BrowserWindowController? {
    guard let controller = makeWindow() else { return nil }
    hostFactories[controller.windowID]?.showCommandBar(.newTab)
    return controller
  }

  /// Settings ▸ Advanced "Show full URL when Toolbar is enabled" for every browser window.
  func applyToolbarSettings() {
    let full = UserDefaults.standard.bool(forKey: AppCommand.showFullURLKey)
    for controller in windowControllers where controller.showsFullURLWithToolbar != full { controller.showsFullURLWithToolbar = full }
  }

  func focusWindow(_ id: WindowID, activate: Bool = false) {
    didFocusWindow(id)
    windowControllers.first { $0.windowID == id }?.window?.makeKeyAndOrderFront(nil)
    if activate { NSApp.activate() }
  }

  func didFocusWindow(_ id: WindowID) {
    activeWindowID = id
    if let state = model.windows.first(where: { $0.id == id && $0.style == .standard }) {
      state.lastFocusedAt = Date()
      scheduleSave()
    }
    for (otherID, factory) in hostFactories where otherID != id { factory.commandBarSession?.dismiss() }
    MainMenu.targetWindowCommands(hostFactories[id])
    settingsPresenter.refreshSpaceManagerContext()
  }

  func windowDidClose(_ id: WindowID) {
    guard let factory = hostFactories[id] else { return }
    if let session = factory.incognitoSession {
      windowControllers.removeAll { $0.windowID == id }; hostFactories[id] = nil
      if session.windows == 1, let context = session.context { extensionPrompts.unregister(context.extensions) }
      incognitoSessions.release(session)
      if activeWindowID == id { activeWindowID = windowControllers.last?.windowID }
      MainMenu.targetWindowCommands(frontWindowController.flatMap { hostFactories[$0.windowID] })
      return
    }
    noteLaunchWindowNavigation(id)
    todayAutoArchive?.detach(windowID: id)
    if model.windows.filter({ $0.style == .standard }).count > 1 {
      withoutWindowUndo { model.closeWindow(windowID: id) }
    } else {
      model.setWindowContentVisible(windowID: id, visible: false)
    }
    windowControllers.removeAll { $0.windowID == id }; hostFactories[id] = nil
    purgeScriptingWrappers()
    media.windowClosed(id)
    tabSleep.visibilityChanged()
    if activeWindowID == id { activeWindowID = windowControllers.last?.windowID }
    MainMenu.targetWindowCommands(frontWindowController.flatMap { hostFactories[$0.windowID] })
    scheduleSave()
    settingsPresenter.refreshSpaceManagerContext()
  }

  func discardUnusedLaunchWindow(_ id: WindowID) {
    guard let controller = windowControllers.first(where: { $0.windowID == id }) else { return }
    controller.window?.close()
    // The usual last-window close retains user state. This tagged fallback
    // was absent from the saved session, so do not persist a phantom window.
    withoutWindowUndo { model.closeWindow(windowID: id) }
    scheduleSave()
  }

  static func makeDefaultModel() -> BrowserModel {
    let profile = Profile(name: "Default", dataDirectoryName: "Default")
    let space = Space(title: "Space", profileID: profile.id)
    let window = BrowserWindowState(focusedSpaceID: space.id)
    return BrowserModel(profiles: [profile], spaces: [space], windows: [window])
  }

  /// Shell window lifetime cannot be undone as a sidebar edit. Preserve an
  /// enclosing caller's disabled registration state, including on early return.
  private func withoutWindowUndo<T>(_ body: () -> T) -> T {
    let wasEnabled = undoManager.isUndoRegistrationEnabled
    if wasEnabled { undoManager.disableUndoRegistration() }
    defer { if wasEnabled { undoManager.enableUndoRegistration() } }
    return body()
  }

  func scheduleSave() {
    guard let model, (!isFirstRun || firstRunSaved) else { return }
    snapshotStore.scheduleSave(model: model)
  }

  /// Called after the message loop returns, before the engine shuts down.
  func saveState() {
    guard let model, (!isFirstRun || firstRunSaved) else { return }
    for controller in windowControllers { controller.saveWindowState() }
    do {
      try snapshotStore.saveNow(model: model)
    } catch {
      FileHandle.standardError.write(Data("Open: saving the snapshot failed: \(error)\n".utf8))
    }
    archiveSink.flushAll()
  }

  /// Used after import (including an E-5 save error) so the imported items are
  /// available behind the panel. Saving remains guarded until saveNow succeeds.
  func showFirstRunBrowser() {
    guard windowControllers.isEmpty else { return }
    LaunchTiming.shared.mark("firstRunLandingStarted")
    let states = model.windows.filter { $0.style == .standard }
    for state in states { createWindowController(state: state) }
    firstRunWindowController?.window?.makeKeyAndOrderFront(nil)
  }

  func finishFirstRun(imported: Bool) {
    guard firstRunWindowController != nil else { return }
    assert(imported || model === firstRunDefaultModel, "A fresh finish must keep the original default model")
    do {
      try snapshotStore.saveNow(model: model)
      firstRunSaved = true
      UserDefaults.standard.set(true, forKey: "open.firstRun.completed")
    } catch {
      firstRunWindowController?.model.reportSaveFailure(imported: imported)
      return
    }
    lastFirstRunStep = firstRunWindowController?.model.step.rawValue ?? lastFirstRunStep
    firstRunWindowController?.close(); firstRunWindowController = nil
    prepareLittleOpen()
    showWindowsIfNeeded()
    frontWindowController?.window?.makeKeyAndOrderFront(nil)
    settingsPresenter.attachBrowserStores()
    startAutoArchiveIfNeeded(); todayAutoArchive?.finishStartupComposition()
    for url in options.initialURLs {
      _ = frontWindowController.flatMap { hostFactories[$0.windowID] }?.openNewTab(url: url, background: false)
    }
    completeLinkRestoration()
    reloadKeyBindings()
    let pendingLittleOpen = pendingLittleOpenBlankStamps
    pendingLittleOpenBlankStamps.removeAll()
    for timestamp in pendingLittleOpen { openBlankLittleOpen(timestamp: timestamp) }
  }

  // MARK: OEEngineDelegate

  func engineDidInitialize() {
    LaunchTiming.shared.mark("engineInitialized")
    engineReady = true
    showWindowsIfNeeded()
    refreshScriptingEngine()
    for factory in hostFactories.values { factory.engineDidBecomeReady() }
    // A fresh empty Space has no web paint to start T5. Register its shortcut
    // after the native first frame without creating Settings or SuggestEngine.
    if !isFirstRun || firstRunSaved { reloadKeyBindings() }
    if firstRunWindowController == nil {
      let pendingLittleOpen = pendingLittleOpenBlankStamps
      pendingLittleOpenBlankStamps.removeAll()
      for timestamp in pendingLittleOpen { openBlankLittleOpen(timestamp: timestamp) }
    }
    if !isFirstRun || firstRunWindowController == nil { completeLinkRestoration() }
    EngineWebProfile.onPermissionChange = { [weak self] context in self?.tabSleep.permissionsChanged(context: context) }
    scheduleMenuRebuild()
    #if OPEN_AUTOMATION
      let socket =
        options.automationSocket
        ?? options.userDataDirectory.appendingPathComponent("automation.sock")
      let server = AutomationServer(socketURL: socket, controller: AutomationController(app: self))
      do {
        try server.start()
        automation = server
        FileHandle.standardError.write(Data("Open: automation socket at \(socket.path)\n".utf8))
      } catch {
        FileHandle.standardError.write(Data("Open: automation socket failed: \(error)\n".utf8))
      }
    #endif
  }

  func engineWebContent(forUnownedOpenRequest request: OEOpenRequest) -> OEWebContent? {
    let owner = hostFactories.values.first { $0.isIncognito && $0.incognitoSession?.context === request.context }
      ?? frontStandardWindowController.flatMap { hostFactories[$0.windowID] }
    return owner?.adoptUnownedRequest(request)
  }

  func engineWillShutDown() {
    prepareForEngineShutdown()
    #if OPEN_AUTOMATION
      automation?.stop()
    #endif
  }

  /// Runs before OEApplication starts its engine close sequence, and again
  /// defensively before CefShutdown if the message loop ends by another path.
  func prepareForEngineShutdown() {
    guard !shutdownPrepared else { return }
    ExtensionWindowController.closeAll()
    stopAutoArchive()
    tabSleep.stop()
    shutdownPrepared = true
    recordShutdownPhase("prepare")
    afterPaintTask?.cancel(); afterPaintTask = nil
    menuRebuildTask?.cancel(); menuRebuildTask = nil
    littleOpenCoordinator?.closeAll()
    engineReady = false
    refreshScriptingEngine()
    for factory in Array(hostFactories.values) { factory.closeAll() }
    incognitoSessions.closeAll()
    recordShutdownPhase("hostsClosed")
  }

  func noteAsyncEngineCall(_ operation: String) {
    asyncEngineCalls[operation, default: 0] += 1
    if shutdownPrepared || !engineReady || terminationRequested { lateAsyncEngineCalls += 1 }
  }

  /// A real queued task can be held at its scheduling boundary in e2e builds.
  /// Cancellation interrupts this wait; engine responses are never replaced.
  func deferAsyncEngineWorkForAutomation() async {
    #if OPEN_AUTOMATION
    if let raw = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_ASYNC_TASK_DELAY_MS"],
       let milliseconds = Int(raw), milliseconds > 0 {
      try? await Task.sleep(for: .milliseconds(milliseconds))
    }
    #endif
  }

  func recordShutdownPhase(_ phase: String) {
    #if OPEN_AUTOMATION
    guard ProcessInfo.processInfo.environment["OPEN_AUTOMATION_SHUTDOWN_TRACE"] == "1", directories != nil else { return }
    let factories = Array(hostFactories.values)
    shutdownTrace.append(["phase": phase, "uptime": ProcessInfo.processInfo.systemUptime,
      "captureTasks": factories.reduce(0) { $0 + $1.saveCaptureTasks.count },
      "backgroundTasks": factories.reduce(0) { $0 + $1.hosts.values.filter(\.hasBackgroundTask).count },
      "selectionTasks": factories.filter(\.hasFindSelectionTask).count,
      "hosts": factories.reduce(0) { $0 + $1.hosts.count },
      "closedFactories": factories.filter(\.isClosing).count, "factories": factories.count,
      "asyncEngineCalls": asyncEngineCalls,
      "lateAsyncEngineCalls": lateAsyncEngineCalls])
    let file = directories.root.appendingPathComponent("State/shutdown-order.json")
    if let data = try? JSONSerialization.data(withJSONObject: shutdownTrace, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: file, options: .atomic)
    }
    #endif
  }

  private func downloadOwner(_ download: OEDownload) -> EngineWebContentHostFactory? {
    if let page = download.webContent {
      return hostFactories.values.first { $0.tabID(for: page) != nil || $0.auxiliaryPages.contains { $0.content === page } }
    }
    return frontWindowController.flatMap { hostFactories[$0.windowID] }
  }

  func browserContext(_ context: OEBrowserContext, decideDestinationFor download: OEDownload, suggestedFilename: String, completion: @escaping @MainActor (URL?) -> Void) {
    #if OPEN_AUTOMATION
    if AutomationOwnerWatch.quittingWithoutPrompts { completion(nil); return }
    #endif
    guard let owner = downloadOwner(download) else { completion(nil); return }
    owner.browserContext(context, decideDestinationFor: download, suggestedFilename: suggestedFilename, completion: completion)
  }

  func browserContext(_ context: OEBrowserContext, downloadDidUpdate download: OEDownload) {
    downloadsCenter.updated(download, context: context)
    downloadOwner(download)?.browserContext(context, downloadDidUpdate: download)
  }

  /// A web notification was clicked (EP-6); §4.5.4's 500 ms fallback selects its tab.
  func browserContext(_ context: OEBrowserContext, didClickNotification identifier: String, origin: URL, persistent: Bool) {
    NotificationClickRouter.shared.clicked(app: self, context: context, identifier: identifier, origin: origin, persistent: persistent)
  }
}

extension AppDelegate: CommandDispatcher {
  func factory(forKeyWindow window: NSWindow) -> EngineWebContentHostFactory? {
    hostFactories.values.first { $0.ownsKeyWindow(window) }
  }
  func scheduleMenuRebuild() {
    guard !shutdownPrepared, menuRebuildTask == nil else { return }
    menuRebuildTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(30))
      guard let self, !Task.isCancelled else { return }
      self.menuRebuildTask = nil; NSApp.mainMenu = MainMenu.build()
    }
  }
  /// No suggestion index, history, hotkey or settings work before first paint.
  func prepareCommandsAfterPaint(_ page: OEWebContent) {
    guard engineReady, !shutdownPrepared, !terminationRequested,
          !commandServicesPrepared || !tabSleep.isStarted || !FindBarPrewarm.isScheduled, afterPaintTask == nil else { return }
    afterPaintTask = Task { @MainActor [weak self, weak page] in
      defer { self?.afterPaintTask = nil }
      for _ in 0..<40 {
        guard let self, let page, self.engineReady, !self.shutdownPrepared,
              !self.terminationRequested, !Task.isCancelled else { return }
        let painted = (try? await page.evaluateJavaScript("performance.getEntriesByType('paint').length > 0")) as? Bool
        if painted == true {
          if !self.commandServicesPrepared {
            self.prepareCommandServices()
            if let id = self.frontStandardWindowController?.windowID, let profile = self.hostFactories[id]?.focusedProfile { self.stores.prewarm(profileID: profile.id) }
          }
          // Startup T5: the sleep controller starts after first paint, never before.
          self.tabSleep.start()
          FindBarPrewarm.schedule(afterPaintIn: self)
          self.applicationIcon.restoreAfterContent()
          self.prepareUpdaterAfterPaint()
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      // A page that never reports a paint (about:blank): start sleep after the same 2 s budget.
      guard let self, self.engineReady, !self.shutdownPrepared, !self.terminationRequested, !Task.isCancelled else { return }
      self.tabSleep.start()
      self.applicationIcon.restoreAfterContent()
      self.prepareUpdaterAfterPaint()
    }
  }
  private func prepareUpdaterAfterPaint() {
    guard updater == nil else { return }
    updater = UpdaterController(app: self)
    if checkForUpdatesAfterPaint { checkForUpdatesAfterPaint = false; updater?.checkForUpdates() }
  }
  func prepareCommandServices() {
    guard !commandServicesPrepared else { return }
    commandServicesPrepared = true
    _ = settingsPresenter.settings
    numberedShortcutOptions = currentNumberedShortcutOptions
    commandDefaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.applyToolbarSettings()
        let options = self.currentNumberedShortcutOptions
        guard options != self.numberedShortcutOptions else { return }
        self.numberedShortcutOptions = options; self.scheduleMenuRebuild()
      }
    }
    commandWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        // A window no browser owns (Library, Settings) must stop routing menu keys to the
        // browser at once: a key pressed before a deferred rebuild (or while another one is
        // pending) would otherwise run in the browser behind it (Cmd+L, Cmd+W).
        if let window = NSApp.keyWindow, window.sheetParent == nil, self.factory(forKeyWindow: window) == nil, !self.shutdownPrepared {
          self.menuRebuildTask?.cancel(); self.menuRebuildTask = nil
          NSApp.mainMenu = MainMenu.build()
        } else { self.scheduleMenuRebuild() }
      }
    }
    reloadKeyBindings()
  }
  func reloadKeyBindings() {
    let file = options.userDataDirectory.appendingPathComponent("State/keybindings.json")
    do {
      let loaded = FileManager.default.fileExists(atPath: file.path) ? try KeyBindingStore.load(from: file) : .empty
      guard loaded.version == 1, loaded.unknownCommandIDs.isEmpty,
        loaded.bindings.keys.allSatisfy({ CommandRegistry.byID[$0]?.isCustomizable == true }),
        ConflictChecker.unexpected(ConflictChecker.check(overrides: loaded)).isEmpty else {
        throw CocoaError(.fileReadCorruptFile)
      }
      keyBindings = loaded
      EssentialShortcutsWindowController.shared.update(store: loaded)
    } catch {
      keyBindings = .empty; Self.commandLog("Key bindings could not be loaded: \(error)")
    }
    for controller in windowControllers { controller.keyBindingOverrides = keyBindings }
    extensionPrompts.rebuildShortcuts()
    updateLittleOpenHotkey(); scheduleMenuRebuild()
  }
  func updateLittleOpenHotkey() {
    hotkeyService?.unregister(); hotkeyError = nil
    guard UserDefaults.standard.object(forKey: "open.links.littleOpenHotkeyEnabled") as? Bool ?? true,
      let command = CommandRegistry.byID["little-open-global"],
      let shortcut = keyBindings.effectiveShortcuts(for: command).first else { return }
    if hotkeyService == nil { hotkeyService = GlobalHotkeyService() }
    hotkeyAttempts += 1
    do { try hotkeyService?.register(shortcut: shortcut, actionWithTimestamp: { [weak self] timestamp in
      Task { @MainActor in self?.openBlankLittleOpen(timestamp: timestamp) }
    }) }
    catch { hotkeyError = String(describing: error); Self.commandLog("Little Open hotkey registration failed: \(error)") }
  }
  static func commandLog(_ message: String) { FileHandle.standardError.write(Data("Open: \(message)\n".utf8)) }
  func menuState(for id: String) -> CommandMenuState? {
    if id == "set-default-browser" { return CommandMenuState(isChecked: defaultBrowserService.isDefaultBrowser) }
    if id == "toggle-developer-mode" { return DeveloperMode.menuState(for: frontWindowController.flatMap { hostFactories[$0.windowID] }?.selectedContent?.url) }
    return PageTools.menuState(for: id)
  }
  private static let firstRunCommands: Set<String> = [
    "quit-open", "hide-open", "hide-others", "show-all", "about-open", "archive-tab", "close-window"
  ]
  private func allowsFirstRunCommand(_ id: String) -> Bool {
    firstRunWindowController == nil || firstRunSaved || Self.firstRunCommands.contains(id)
  }
  var settingsShortcutCaptured: Bool {
    hostFactories.values.contains { factory in
      factory.commandBarSession?.isPresented == true &&
        factory.commandBarSession?.controller?.editingUndoManager(for: NSApp.keyWindow?.firstResponder) != nil
    }
  }
  func isCommandEnabled(_ id: String, enabledKey: String) -> Bool {
    guard allowsFirstRunCommand(id) else { return false }
    if id == "settings", settingsShortcutCaptured { return false }
    if id == "check-for-updates" { return updater?.canCheckForUpdates ?? true }
    if let enabled = littleOpenCommandEnabled(id) { return enabled }
    if SystemCommandActions.selectors[id] != nil { return SystemCommandActions.isEnabled(id) }
    if let enabled = PageTools.isAppCommandEnabled(id) { return enabled }  // App/Page/PageToolsCommands.swift
    if ["archive-tab", "close-window"].contains(id) { return NSApp.keyWindow != nil }
    return ["new-incognito-window", "new-window", "blank-window", "new-tab", "new-profile", "settings", "search-settings", "air-traffic-control", "import-from-browser", "set-default-browser", "check-for-updates", "view-archive", "view-history", "view-library", "view-downloads", "view-media", "view-boosts", "quit-open", "new-little-open-window", "little-open-global", "about-open", "hide-open", "hide-others", "show-all", "help-center", "keyboard-shortcuts-edu", "getting-started", "release-notes", "contact-team", "manage-spaces"].contains(id)
  }
  func performCommand(_ id: String, payload: String?) {
    guard allowsFirstRunCommand(id) else { return }
    // Search engines live in Settings ▸ Profiles: open the named Profile, else the front window's.
    // An action row's payload is a Space ID, which names no Profile, so it falls back too.
    if id == "search-settings" {
      let named = payload.flatMap(UUID.init(uuidString:)).map { ProfileID(rawValue: $0) }.flatMap { model.profile(id: $0) == nil ? nil : $0 }
      let profile = named ?? frontWindowController.flatMap { hostFactories[$0.windowID]?.focusedProfile?.id }
      if let profile, model.profile(id: profile) != nil { settingsPresenter.showProfileSettings(profileID: profile) }
      else { settingsPresenter.show(pane: .profiles) }
      return
    }
    performCommand(id)
  }
  func performCommand(_ id: String) {
    performCommand(id, keyDownTimestamp: nil)
  }
  func performCommand(_ id: String, keyDownTimestamp: TimeInterval?) {
    guard allowsFirstRunCommand(id) else { return }
    noteLaunchWindowInput(NSApp.keyWindow)
    if performLittleOpenCommand(id) { return }
    if SystemCommandActions.selectors[id] != nil { _ = SystemCommandActions.perform(id); return }
    if PageTools.isAppCommandEnabled(id) == true, PageTools.performAppCommand(id) { return }
    switch id {
    case "new-incognito-window": makeIncognitoWindow()
    case "new-window", "blank-window": makeUserWindow()
    case "new-tab":
      let controller = frontWindowController ?? makeWindow()
      controller.flatMap { hostFactories[$0.windowID] }?.newTab(nil)
    case "settings": if !settingsShortcutCaptured { settingsPresenter.show() }
    case "new-profile": settingsPresenter.showNewProfile()
    case "search-settings": performCommand(id, payload: nil)
    case "air-traffic-control":
      settingsPresenter.settings.scrollTarget = nil
      settingsPresenter.show(pane: .links)
      // A repeated invocation must scroll again even if Settings was left on Links.
      Task { @MainActor [weak self] in
        await Task.yield()
        self?.settingsPresenter.settings.scrollTarget = "links-rules"
      }
    case "import-from-browser": settingsPresenter.show(pane: .general); settingsPresenter.settings.showsImport = true
    case "set-default-browser": settingsPresenter.settings.general.setDefault()
    case "check-for-updates": settingsPresenter.checkForUpdates()
    case "view-library": settingsPresenter.showLibrary()
    case "view-downloads": settingsPresenter.showLibrary(section: .downloads)
    // Arc's View Media runs viewScreenshotsAndCaptures: (docs/re/menus-and-hotkeys.md): the Library's
    // Media grid (Captures + Screenshots), not playback.
    case "view-media": settingsPresenter.showLibrary(section: .media)
    case "view-archive": settingsPresenter.showLibrary(section: .archive)
    case "view-history": settingsPresenter.showLibrary(section: .history)
    case "view-boosts": settingsPresenter.show(pane: .advanced); settingsPresenter.settings.advanced.statusText = "Boost editing is not available in this build."
    case "keyboard-shortcuts-edu":
      // Help ▸ Essential Keyboard Shortcuts: Arc's floating EDU window (commandbar-completion §4.5, CC-27).
      EssentialShortcutsWindowController.shared.show(near: frontWindowController?.window ?? NSApp.keyWindow, store: keyBindings)
    case "archive-tab": NSApp.keyWindow?.performClose(nil)
    case "manage-spaces": settingsPresenter.showLibrary(section: .spaces)
    case "new-little-open-window", "little-open-global": openBlankLittleOpen(timestamp: keyDownTimestamp)
    case "help-center", "getting-started", "release-notes", "contact-team":
      let controller = frontWindowController ?? makeWindow()
      _ = controller.flatMap { hostFactories[$0.windowID] }?.openNewTab(url: AppCommand.helpURL(for: id), background: false)
    default:
      #if DEBUG
      if CommandRegistry.byID[id]?.isReserved != true { Self.commandLog("Unhandled app command: \(id)") }
      #endif
    }
  }
}
