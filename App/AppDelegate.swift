import AppKit
import OpenEngine
import OpenModel
import OpenStore
import QuartzCore

/// Owns the model, its stores, and the windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, OEEngineDelegate {
  var options = LaunchOptions(arguments: [])
  private(set) var model: BrowserModel!
  private(set) var snapshotStore: SnapshotStore!
  private(set) var archiveSink: ProfileArchiveSink!
  private(set) var directories: ProfileDirectories!
  private(set) var windowControllers: [BrowserWindowController] = []
  let undoManager = UndoManager()
  private(set) var engineReady = false
  private(set) var startupEvidence: [String: Any] = [:]
  #if OPEN_AUTOMATION
    private var automation: AutomationServer?
  #endif

  var frontWindowController: BrowserWindowController? {
    windowControllers.first { $0.window?.isKeyWindow == true } ?? windowControllers.first
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchTiming.shared.mark("didFinishLaunching")
    NSApp.mainMenu = MainMenu.build()
    NSApp.setActivationPolicy(.regular)
    // The window and sidebar come from the snapshot and do not wait for the
    // engine (docs/architecture.md, launch tactics). Pages created before
    // the engine is ready wait inside OpenEngine.
    showWindowsIfNeeded()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    frontWindowController?.showWindow(nil)
    return false
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
      let controller = BrowserWindowController(app: self, windowState: state)
      windowControllers.append(controller)
      controller.showWindow(nil)
    }
    LaunchTiming.shared.mark("windowShown")
  }

  func drawWindowsBeforeEngine() {
    showWindowsIfNeeded()
    for controller in windowControllers {
      controller.window?.contentView?.layoutSubtreeIfNeeded()
      controller.window?.displayIfNeeded()
    }
    CATransaction.flush()
    LaunchTiming.shared.mark("sidebarDrawn")
    startupEvidence = [
      "sidebarClass": windowControllers.first?.sidebarClassName ?? "",
      "pagesBeforeEngine": OEEngine.shared.allWebContents.count,
      "contextsBeforeEngine": OEEngine.shared.contexts.count,
      "visibleWindows": windowControllers.filter { $0.window?.isVisible == true }.count,
    ]
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
    for controller in windowControllers { controller.engineDidBecomeReady() }
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
    frontWindowController?.adoptUnownedRequest(request)
  }

  func engineWillShutDown() {
    #if OPEN_AUTOMATION
      automation?.stop()
    #endif
  }
}
