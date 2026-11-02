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
  private(set) var snapshotStore: SnapshotStore!
  private(set) var archiveSink: ProfileArchiveSink!
  private(set) var directories: ProfileDirectories!
  /// The engine layout step's outcome (and the data root lock).
  private(set) var engine: OpenDataRoot.EnginePreparation!
  private(set) var hostFactories: [WindowID: EngineWebContentHostFactory] = [:]
  private(set) var windowControllers: [BrowserWindowController] = []
  // CEF pumps AppKit without a normal per-event undo group boundary. The
  // model opens one group per command; multi-operation UI actions may nest.
  let undoManager: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; return manager }()
  private(set) var engineReady = false
  private(set) var terminationRequested = false
  private var faviconShutdownTask: Task<Void, Never>?
  private(set) var shutdownPrepared = false
  private var lateAsyncEngineCalls = 0
  private var asyncEngineCalls: [String: Int] = [:]
  private var shutdownTrace: [[String: Any]] = []
  lazy var stores = AppStores(app: self)
  lazy var settingsPresenter = AppSettingsActions(app: self)
  var keyBindings = KeyBindingStore.empty
  let fallbackKeyboard = KeyboardRouter()
  var commandServicesPrepared = false
  var hotkeyService: GlobalHotkeyService?
  var hotkeyError: String?
  var hotkeyAttempts = 0
  var menuRebuildTask: Task<Void, Never>?
  var afterPaintTask: Task<Void, Never>?
  var littleOpenStub: NSWindowController?
  var commandWindowObserver: NSObjectProtocol?
  var commandDefaultsObserver: NSObjectProtocol?
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
    NSApp.mainMenu = MainMenu.build()
    MainMenu.targetWindowCommands(frontWindowController.flatMap { hostFactories[$0.windowID] })
    NSApp.setActivationPolicy(.regular)
    // The window and sidebar come from the snapshot and do not wait for the
    // engine (docs/architecture.md, launch tactics). Pages created before
    // the engine is ready wait inside OpenEngine.
    showWindowsIfNeeded()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let frontWindowController { frontWindowController.showWindow(nil) }
    else { showWindowsIfNeeded() }
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if faviconShutdownTask != nil { return .terminateCancel }
    let wasEngineReady = engineReady
    let icons = wasEngineReady ? stores.sidebarFavicons : nil
    terminationRequested = true
    if let commandWindowObserver { NotificationCenter.default.removeObserver(commandWindowObserver) }; commandWindowObserver = nil
    if let commandDefaultsObserver { NotificationCenter.default.removeObserver(commandDefaultsObserver) }; commandDefaultsObserver = nil
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
    // Chromium's data layout is its own step, before the snapshot loads. A
    // migration problem selects the old layout for this launch (retried on
    // the next one); it never touches the model.
    do {
      engine = try OpenDataRoot.prepareEngineLayout(root: root)
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
    let model = loaded ?? Self.makeDefaultModel()
    if model.windows.isEmpty, let space = model.spaces.first {
      model.windows.append(BrowserWindowState(focusedSpaceID: space.id))
    }
    do {
      try OpenDataRoot.prepare(root: root, model: model)
    } catch {
      FileHandle.standardError.write(Data("Open: data root \(root.path) unavailable: \(error)\n".utf8))
      exit(1)
    }
    let directories = ProfileDirectories(root: root.standardizedFileURL.resolvingSymlinksInPath())
    archiveSink = ProfileArchiveSink(directories: directories) { [weak model] id in
      let profile = id.flatMap { model?.profile(id: $0) } ?? model?.defaultProfile
      return profile?.dataDirectoryName ?? "Default"
    }
    model.archiveSink = archiveSink
    model.undoManager = undoManager
    // Launch URLs enter the snapshot-backed model before window composition.
    // Only the final selection gets a page after engine readiness.
    if let state = model.windows.first(where: { $0.style == .standard }),
      let space = model.space(id: state.focusedSpaceID)
    {
      for url in options.initialURLs {
        let tab = model.newTab(in: space.id, url: url, at: 0)
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: tab.id)
      }
    }
    model.addObserver { [weak self] _ in self?.scheduleSave(); self?.scheduleMenuRebuild() }
    self.model = model
    self.directories = directories
    startAutoArchiveIfNeeded()
    LaunchTiming.shared.mark("modelLoaded")
    return directories
  }

  /// Runs at the first of applicationDidFinishLaunching and
  /// engineDidInitialize (their order is not fixed).
  private func showWindowsIfNeeded() {
    prepareData()
    guard windowControllers.isEmpty else { return }
    let states = model.windows.filter { $0.style == .standard }
    for state in states.isEmpty ? Array(model.windows.prefix(1)) : states {
      createWindowController(state: state)
    }
    todayAutoArchive?.finishStartupComposition()
    LaunchTiming.shared.mark("windowShown")
  }

  func drawWindowsBeforeEngine() {
    showWindowsIfNeeded()
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
  }

  @discardableResult
  private func createWindowController(state: BrowserWindowState) -> BrowserWindowController {
    model.setWindowContentVisible(windowID: state.id, visible: true)
    let factory = EngineWebContentHostFactory(app: self, state: state)
    hostFactories[state.id] = factory
    let controller = BrowserWindowController(model: model, windowID: state.id, factory: factory, snapshotStore: snapshotStore)
    controller.context.storedFavicons = stores.sidebarFavicons
    factory.attach(controller)
    windowControllers.append(controller)
    activeWindowID = state.id
    MainMenu.targetWindowCommands(factory)
    todayAutoArchive?.attach(context: controller.context)
    controller.showWindow(nil)
    if engineReady { factory.engineDidBecomeReady() }
    return controller
  }

  @discardableResult
  func makeWindow(focusedSpaceID: SpaceID? = nil) -> BrowserWindowController? {
    // Closing the final window keeps its state for reopen and relaunch.
    if windowControllers.isEmpty, let state = model.windows.first(where: { $0.style == .standard }) {
      return createWindowController(state: state)
    }
    guard let spaceID = focusedSpaceID ?? frontWindowController?.context.focusedSpace?.id ?? model.spaces.first?.id,
      let state = withoutWindowUndo({ model.createWindow(focusedSpaceID: spaceID) }) else { return nil }
    let offset = Double(windowControllers.count * 24)
    state.frameX += offset; state.frameY -= offset
    let controller = createWindowController(state: state)
    scheduleSave(); return controller
  }

  @objc func newWindow(_ sender: Any?) { makeWindow() }

  func focusWindow(_ id: WindowID, activate: Bool = false) {
    didFocusWindow(id)
    windowControllers.first { $0.windowID == id }?.window?.makeKeyAndOrderFront(nil)
    if activate { NSApp.activate() }
  }

  func didFocusWindow(_ id: WindowID) {
    activeWindowID = id
    for (otherID, factory) in hostFactories where otherID != id { factory.commandBarSession?.dismiss() }
    MainMenu.targetWindowCommands(hostFactories[id])
    settingsPresenter.refreshSpaceManagerContext()
  }

  func windowDidClose(_ id: WindowID) {
    todayAutoArchive?.detach(windowID: id)
    if model.windows.filter({ $0.style == .standard }).count > 1 {
      withoutWindowUndo { model.closeWindow(windowID: id) }
    } else {
      model.setWindowContentVisible(windowID: id, visible: false)
    }
    windowControllers.removeAll { $0.windowID == id }; hostFactories[id] = nil
    if activeWindowID == id { activeWindowID = windowControllers.last?.windowID }
    MainMenu.targetWindowCommands(frontWindowController.flatMap { hostFactories[$0.windowID] })
    scheduleSave()
    settingsPresenter.refreshSpaceManagerContext()
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
    guard let model else { return }
    snapshotStore.scheduleSave(model: model)
  }

  /// Called after the message loop returns, before the engine shuts down.
  func saveState() {
    guard let model else { return }
    for controller in windowControllers { controller.saveWindowState() }
    do {
      try snapshotStore.saveNow(model: model)
    } catch {
      FileHandle.standardError.write(Data("Open: saving the snapshot failed: \(error)\n".utf8))
    }
    archiveSink.flushAll()
  }

  // MARK: OEEngineDelegate

  func engineDidInitialize() {
    LaunchTiming.shared.mark("engineInitialized")
    engineReady = true
    showWindowsIfNeeded()
    for factory in hostFactories.values { factory.engineDidBecomeReady() }
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
    frontWindowController.flatMap { hostFactories[$0.windowID]?.adoptUnownedRequest(request) }
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
    stopAutoArchive()
    shutdownPrepared = true
    recordShutdownPhase("prepare")
    afterPaintTask?.cancel(); afterPaintTask = nil
    menuRebuildTask?.cancel(); menuRebuildTask = nil
    engineReady = false
    for factory in Array(hostFactories.values) { factory.closeAll() }
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
    guard let owner = downloadOwner(download) else { completion(nil); return }
    owner.browserContext(context, decideDestinationFor: download, suggestedFilename: suggestedFilename, completion: completion)
  }

  func browserContext(_ context: OEBrowserContext, downloadDidUpdate download: OEDownload) {
    downloadOwner(download)?.browserContext(context, downloadDidUpdate: download)
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
          !commandServicesPrepared, afterPaintTask == nil else { return }
    afterPaintTask = Task { @MainActor [weak self, weak page] in
      defer { self?.afterPaintTask = nil }
      for _ in 0..<40 {
        guard let self, let page, self.engineReady, !self.shutdownPrepared,
              !self.terminationRequested, !Task.isCancelled else { return }
        let painted = (try? await page.evaluateJavaScript("performance.getEntriesByType('paint').length > 0")) as? Bool
        if painted == true {
          self.prepareCommandServices()
          if let id = self.frontWindowController?.windowID, let profile = self.hostFactories[id]?.focusedProfile { self.stores.prewarm(profileID: profile.id) }
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }
  func prepareCommandServices() {
    guard !commandServicesPrepared else { return }
    commandServicesPrepared = true
    _ = settingsPresenter.settings
    numberedShortcutOptions = currentNumberedShortcutOptions
    commandDefaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
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
    updateLittleOpenHotkey(); scheduleMenuRebuild()
  }
  func updateLittleOpenHotkey() {
    hotkeyService?.unregister(); hotkeyError = nil
    guard UserDefaults.standard.object(forKey: "open.links.littleOpenHotkeyEnabled") as? Bool ?? true,
      let command = CommandRegistry.byID["little-open-global"],
      let shortcut = keyBindings.effectiveShortcuts(for: command).first else { return }
    if hotkeyService == nil { hotkeyService = GlobalHotkeyService() }
    hotkeyAttempts += 1
    do { try hotkeyService?.register(shortcut: shortcut) { [weak self] in Task { @MainActor in self?.showLittleOpenStub() } } }
    catch { hotkeyError = String(describing: error); Self.commandLog("Little Open hotkey registration failed: \(error)") }
  }
  static func commandLog(_ message: String) { FileHandle.standardError.write(Data("Open: \(message)\n".utf8)) }
  func showLittleOpenStub() {
    if littleOpenStub == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.title = "Little Open"; window.isReleasedWhenClosed = false
      let label = NSTextField(labelWithString: "Little Open is not available in this build.")
      label.frame = NSRect(x: 28, y: 260, width: 650, height: 24); window.contentView?.addSubview(label)
      window.center(); littleOpenStub = NSWindowController(window: window)
    }
    littleOpenStub?.showWindow(nil); littleOpenStub?.window?.makeKeyAndOrderFront(nil); NSApp.activate()
    scheduleMenuRebuild()
  }
  func isCommandEnabled(_ id: String, enabledKey: String) -> Bool {
    if SystemCommandActions.selectors[id] != nil { return SystemCommandActions.isEnabled(id) }
    if ["archive-tab", "close-window"].contains(id) { return NSApp.keyWindow != nil }
    return ["new-window", "blank-window", "new-tab", "settings", "search-settings", "air-traffic-control", "import-from-browser", "set-default-browser", "check-for-updates", "view-archive", "view-history", "view-library", "view-downloads", "view-boosts", "quit-open", "new-little-open-window", "little-open-global", "about-open", "hide-open", "hide-others", "show-all", "help-center", "keyboard-shortcuts-edu", "show-shortcuts-overlay", "getting-started", "release-notes", "contact-team", "manage-spaces"].contains(id)
  }
  func performCommand(_ id: String, payload: String?) {
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
    if SystemCommandActions.selectors[id] != nil { _ = SystemCommandActions.perform(id); return }
    switch id {
    case "new-window", "blank-window": makeWindow()
    case "new-tab":
      let controller = frontWindowController ?? makeWindow()
      controller.flatMap { hostFactories[$0.windowID] }?.newTab(nil)
    case "settings": settingsPresenter.show()
    case "search-settings": performCommand(id, payload: nil)
    case "air-traffic-control": settingsPresenter.show(pane: .links)
    case "import-from-browser": settingsPresenter.show(pane: .general); settingsPresenter.settings.showsImport = true
    case "set-default-browser": settingsPresenter.settings.general.setDefault()
    case "check-for-updates": settingsPresenter.checkForUpdates()
    case "view-library": settingsPresenter.showLibrary()
    case "view-downloads": settingsPresenter.showLibrary(section: .downloads)
    case "view-archive": settingsPresenter.showLibrary(section: .archive)
    case "view-history": settingsPresenter.showLibrary(section: .history)
    case "view-boosts": settingsPresenter.show(); settingsPresenter.settings.statusText = "Boost editing is not available in this build."
    case "keyboard-shortcuts-edu":
      // Help ▸ Essential Keyboard Shortcuts: Arc's floating EDU window (commandbar-completion §4.5, CC-27).
      EssentialShortcutsWindowController.shared.show(near: frontWindowController?.window ?? NSApp.keyWindow, store: keyBindings)
    case "archive-tab": NSApp.keyWindow?.performClose(nil)
    case "manage-spaces": settingsPresenter.showLibrary(section: .spaces)
    case "new-little-open-window", "little-open-global": showLittleOpenStub()
    case "help-center", "show-shortcuts-overlay", "getting-started", "release-notes", "contact-team":
      let controller = frontWindowController ?? makeWindow()
      _ = controller.flatMap { hostFactories[$0.windowID] }?.openNewTab(url: AppCommand.helpURL, background: false)
    default:
      #if DEBUG
      if CommandRegistry.byID[id]?.isReserved != true { Self.commandLog("Unhandled app command: \(id)") }
      #endif
    }
  }
}
