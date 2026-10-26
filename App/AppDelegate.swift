import AppKit
import OpenEngine
import OpenModel
import OpenStore

/// Owns the model, its stores, and the windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, OEEngineDelegate {
  var options = LaunchOptions(arguments: [])
  private(set) var model: BrowserModel!
  private(set) var snapshotStore: SnapshotStore!
  private(set) var archiveStore: ArchiveStore!
  private(set) var windowControllers: [BrowserWindowController] = []
  let undoManager = UndoManager()
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

  private func loadModelIfNeeded() {
    guard model == nil else { return }
    snapshotStore = SnapshotStore(root: options.stateDirectory)
    archiveStore = ArchiveStore(root: options.stateDirectory)
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
    model.archiveSink = archiveStore
    model.undoManager = undoManager
    model.addObserver { [weak self] _ in self?.scheduleSave() }
    self.model = model
    LaunchTiming.shared.mark("modelLoaded")
  }

  /// Runs at the first of applicationDidFinishLaunching and
  /// engineDidInitialize (their order is not fixed).
  private func showWindowsIfNeeded() {
    loadModelIfNeeded()
    guard windowControllers.isEmpty else { return }
    let states = model.windows.filter { $0.style == .standard }
    for state in states.isEmpty ? Array(model.windows.prefix(1)) : states {
      let controller = BrowserWindowController(app: self, windowState: state)
      windowControllers.append(controller)
      controller.showWindow(nil)
    }
    LaunchTiming.shared.mark("windowShown")
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
    snapshotStore.saveNow(model: model)
    archiveStore.flushQueue()
  }

  // MARK: OEEngineDelegate

  func engineDidInitialize() {
    LaunchTiming.shared.mark("engineInitialized")
    showWindowsIfNeeded()
    if let front = windowControllers.first {
      for url in options.initialURLs {
        front.openNewTab(url: url, background: false)
      }
    }
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
