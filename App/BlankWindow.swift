import AppKit
import OpenModel

/// File ▸ Blank Window (⌃⌘N) as its own window kind (capture C10, Arc 1.172.2; C-report-s6.md):
/// - the same size as the source window, offset +29 / +29 pt;
/// - the sidebar header "This Window" over this window's tabs only (newest first), with no
///   Favorites, no pinned section and no Space dots; the bottom bar keeps Library and "+";
/// - default theme colours, the command bar open, the window title "Space 1" until a page shows;
/// - ⌘W on the last tab closes the window with no prompt; it is not restored at relaunch;
/// - ⇧⌘T reopens a closed tab in this window, and does not bring a closed Blank Window back.
///
/// Open builds it as a window with its own in-memory model: one untitled Space on a stand-in
/// for the source Profile (same id and data directory, so pages, history and the Archive are
/// that Profile's). Nothing of it is written to the session snapshot.
/// GUESS (not captured): tab drag between windows, the Archive entry of a
/// closed tab, and restore with "restore windows" on.
@MainActor
enum BlankWindow {
  static let sidebarTitle = "This Window"
  static let offset: CGFloat = 29
}

extension AppDelegate {
  @discardableResult
  func makeBlankWindow() -> BrowserWindowController? {
    guard model != nil else { return nil }
    let source = frontStandardWindowController
    let sourceFactory = source.flatMap { hostFactories[$0.windowID] }
    guard let real = sourceFactory?.focusedProfile.flatMap({ model.profile(id: $0.id) }) ?? model.defaultProfile else { return nil }
    // A stand-in Profile: the same identity and data, no Favorites of its own.
    let profile = Profile(id: real.id, name: real.name, icon: real.icon, settings: real.settings, dataDirectoryName: real.dataDirectoryName)
    let space = Space(title: nil, profileID: profile.id)
    let state = BrowserWindowState(focusedSpaceID: space.id)
    if let frame = source?.window?.frame {
      // +29 pt right and +29 pt down from the source window (screen y grows upward).
      state.frameX = frame.minX + BlankWindow.offset; state.frameY = frame.minY - BlankWindow.offset
      state.frameWidth = frame.width; state.frameHeight = frame.height
    }
    if let width = sourceFactory?.windowState.sidebarWidth { state.sidebarWidth = width }
    let memory = BrowserModel(profiles: [profile], spaces: [space], windows: [state])
    let undo = UndoManager(); undo.groupsByEvent = false; memory.undoManager = undo
    // GUESS: a tab closed here goes to the Profile's Archive like any Today tab.
    memory.archiveSink = archiveSink
    let controller = createWindowController(state: state, privateModel: memory, blankWindow: true)
    controller.context.windowOnlyMoveSpaces = { [weak self] in
      guard let model = self?.model else { return [] }
      return model.spaces.map { (id: $0.id, title: model.displayTitle(for: $0)) }
    }
    hostFactories[state.id]?.showCommandBar(.newTab)
    return controller
  }
}

extension EngineWebContentHostFactory {
  /// Row menu ▸ Move to ▸ ‹Space›: the tab leaves this window and opens at the top of that
  /// Space's Today list in the browser's model. The page loads again there (its live page does
  /// not move between the two models: Open's limit, not an Arc fact).
  func moveBlankWindowTab(_ id: ItemID, toSpace spaceID: SpaceID) -> Bool {
    guard isBlankWindow, let tab = model.tab(id: id), app.model.space(id: spaceID) != nil else { return false }
    let moved = app.model.newTab(in: spaceID, url: tab.url, title: tab.title, at: 0)
    moved.customTitle = tab.customTitle; moved.customIcon = tab.customIcon; moved.iconOverride = tab.iconOverride
    // Leave this window without an Archive entry: the tab still exists, in the Space.
    controller?.container.closeHost(for: id); hosts[id]?.close()
    let undo = model.undoManager; undo?.disableUndoRegistration()
    model.closeTab(id: id)
    undo?.enableUndoRegistration()
    model.archiveSink?.discardArchived(ids: [id])
    app.scheduleSave()
    if orderedTabs.isEmpty { DispatchQueue.main.async { [weak self] in self?.window?.performClose(nil) } }
    else { select(nodeID: orderedTabs.first?.id) }
    return true
  }
}

#if OPEN_AUTOMATION
extension AutomationController {
  /// The front window's Blank Window facts (capture C10 rows).
  func blankWindowState() throws -> [String: Any] {
    let factory = try window
    guard let controller = factory.controller, let space = factory.focusedSpace else { throw Failure(message: "no window") }
    controller.contentView.layoutSubtreeIfNeeded()
    let sidebar = controller.sidebar
    let frame = controller.window?.frame ?? .zero
    return ["isBlankWindow": factory.isBlankWindow, "window": factory.windowState.id.description,
      "headerTitle": controller.context.title(of: space), "headerHidden": controller.context.hidesHeader(for: space),
      "favoritesShown": sidebar.favoritesShown, "spaceDots": sidebar.spaceSwitcherCount,
      "libraryButtonShown": !sidebar.homeButton.isHidden, "plusShown": !sidebar.plusButton.isHidden,
      "plusMenu": sidebar.plusMenu()?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [],
      "windowTitle": controller.window?.title ?? "", "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
      "inSnapshotModel": app.model.windows.contains { $0.id == factory.windowState.id },
      "browserWindows": app.windowControllers.count,
      "profileDirectory": factory.focusedProfile?.dataDirectoryName ?? ""]
  }
}
#endif
