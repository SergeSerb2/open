import AppKit
import OpenEngine
import OpenModel
import OpenStore
import OpenFeatures
import QuartzCore

/// Owns the model, its stores, and the windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, OEEngineDelegate, OEBrowserContextDelegate {
  var options = LaunchOptions(arguments: [])
  private(set) var model: BrowserModel!
  private(set) var snapshotStore: SnapshotStore!
  private(set) var archiveSink: ProfileArchiveSink!
  private(set) var directories: ProfileDirectories!
  private(set) var hostFactories: [WindowID: EngineWebContentHostFactory] = [:]
  private(set) var windowControllers: [BrowserWindowController] = []
  let undoManager = UndoManager()
  private(set) var engineReady = false
  private(set) var terminationRequested = false
  private var activeWindowID: WindowID?
  private(set) var startupEvidence: [String: Any] = [:]
  #if OPEN_AUTOMATION
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
    terminationRequested = true
    saveState()
    if !engineReady { CFRunLoopStop(CFRunLoopGetMain()) }
    return .terminateNow
  }

  // MARK: Model

  /// Loads the model and prepares the data root (lock, layout migration,
  /// profile folders). Runs before the engine starts.
  @discardableResult
  func prepareData() -> ProfileDirectories {
    if let directories { return directories }
    let root = options.userDataDirectory
    snapshotStore = SnapshotStore(root: root)
    let loaded: BrowserModel?
    do {
      loaded = try snapshotStore.load()
    } catch {
      FileHandle.standardError.write(Data("Open: snapshot failed to load, starting fresh: \(error)\n".utf8))
      loaded = nil
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
    model.addObserver { [weak self] _ in self?.scheduleSave() }
    self.model = model
    self.directories = directories
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
    let factory = EngineWebContentHostFactory(app: self, state: state)
    hostFactories[state.id] = factory
    let controller = BrowserWindowController(model: model, windowID: state.id, factory: factory, snapshotStore: snapshotStore)
    factory.attach(controller)
    windowControllers.append(controller)
    activeWindowID = state.id
    MainMenu.targetWindowCommands(factory)
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
      let state = model.createWindow(focusedSpaceID: spaceID) else { return nil }
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
    MainMenu.targetWindowCommands(hostFactories[id])
  }

  func windowDidClose(_ id: WindowID) {
    if model.windows.filter({ $0.style == .standard }).count > 1 {
      model.closeWindow(windowID: id)
    }
    windowControllers.removeAll { $0.windowID == id }; hostFactories[id] = nil
    if activeWindowID == id { activeWindowID = windowControllers.last?.windowID }
    MainMenu.targetWindowCommands(frontWindowController.flatMap { hostFactories[$0.windowID] })
    scheduleSave()
  }

  static func makeDefaultModel() -> BrowserModel {
    let profile = Profile(name: "Default", dataDirectoryName: "Default")
    let space = Space(title: "Space", profileID: profile.id)
    let window = BrowserWindowState(focusedSpaceID: space.id)
    return BrowserModel(profiles: [profile], spaces: [space], windows: [window])
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
    #if OPEN_AUTOMATION
      automation?.stop()
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
