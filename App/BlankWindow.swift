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
/// Capture C-report-s11 (Arc 1.172.2): a tab drags both ways between a Blank Window and a normal
/// window (the destination's blue drop line; the tab leaves the source); the header has a
/// "Move to…" button; ⌘W on a tab (not the last) puts it in the Archive, the last tab that closes
/// the window does not; with "restore windows" on, the Blank Window comes back at relaunch.
@MainActor
enum BlankWindow {
  static let sidebarTitle = "This Window"
  static let offset: CGFloat = 29
}

/// The Blank Windows open at quit, written beside the session snapshot (`State/blank-windows.json`).
/// With "restore windows" on they come back at the next launch (C-report-s11 1(c)), at the default
/// size and position (Arc restored 1080 pt wide at its own cascade, not the saved frame; GUESS:
/// Open's default window frame). The snapshot itself never holds them.
struct SavedBlankWindow: Codable {
  struct SavedTab: Codable { var url: URL; var title: String; var customTitle: String? }
  var profileID: ProfileID
  var tabs: [SavedTab]          // sidebar order (newest first)
  var selected: Int?
}

extension AppDelegate {
  var blankWindowsFile: URL { snapshotStore.fileURL.deletingLastPathComponent().appendingPathComponent("blank-windows.json") }

  /// Taken when quit starts, before any window closes.
  func currentBlankWindows() -> [SavedBlankWindow] {
    windowControllers.compactMap { controller in
      guard let factory = hostFactories[controller.windowID], factory.isBlankWindow,
        let profile = factory.focusedProfile else { return nil }
      let tabs = factory.orderedTabs
      guard !tabs.isEmpty else { return nil }
      return SavedBlankWindow(profileID: profile.id,
        tabs: tabs.map { SavedBlankWindow.SavedTab(url: $0.url, title: $0.title, customTitle: $0.customTitle) },
        selected: factory.selectedTab.flatMap { selected in tabs.firstIndex { $0.id == selected.id } })
    }
  }

  func writeBlankWindows(_ windows: [SavedBlankWindow]) {
    let file = blankWindowsFile
    if windows.isEmpty { try? FileManager.default.removeItem(at: file); return }
    guard let data = try? JSONEncoder().encode(windows) else { return }
    try? data.write(to: file, options: .atomic)
  }

  /// At launch, after the snapshot's windows: once, then the file is gone.
  func restoreBlankWindows() {
    let file = blankWindowsFile
    guard let data = try? Data(contentsOf: file), data.count <= 4 << 20 else { return }
    try? FileManager.default.removeItem(at: file)
    guard UserDefaults.standard.object(forKey: "open.advanced.restoreWindowsOnLaunch") as? Bool != false,
      let saved = try? JSONDecoder().decode([SavedBlankWindow].self, from: data) else { return }
    for window in saved.prefix(16) {
      guard let profile = model.profile(id: window.profileID) else { continue }
      makeBlankWindow(profile: profile, restoring: window)
    }
  }

  @discardableResult
  func makeBlankWindow(profile chosen: Profile? = nil, restoring saved: SavedBlankWindow? = nil) -> BrowserWindowController? {
    guard model != nil else { return nil }
    let source = saved == nil ? frontStandardWindowController : nil
    let sourceFactory = source.flatMap { hostFactories[$0.windowID] }
    guard let real = chosen ?? sourceFactory?.focusedProfile.flatMap({ model.profile(id: $0.id) }) ?? model.defaultProfile else { return nil }
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
    if let saved {
      // Oldest first, so each new tab lands on top and the list keeps its saved order.
      for tab in saved.tabs.prefix(500).reversed() {
        let made = memory.newTab(in: space.id, url: tab.url, title: tab.title, at: 0)
        made.customTitle = tab.customTitle
      }
    }
    let controller = createWindowController(state: state, privateModel: memory, blankWindow: true)
    controller.context.windowOnlyMoveSpaces = { [weak self] in
      guard let model = self?.model else { return [] }
      return model.spaces.map { (id: $0.id, title: model.displayTitle(for: $0)) }
    }
    if let saved, let factory = hostFactories[state.id] {
      let tabs = factory.orderedTabs
      factory.select(nodeID: tabs.indices.contains(saved.selected ?? 0) ? tabs[saved.selected ?? 0].id : tabs.first?.id)
    } else { hostFactories[state.id]?.showCommandBar(.newTab) }
    return controller
  }
}

extension AppDelegate {
  /// Tabs dragged from another window whose model does not hold them: a Blank Window's own model
  /// and the browser's model (C-report-s11 1(a): both ways; afterwards the tab is in the
  /// destination's list and gone from the source). Only plain tabs move; the page loads again in
  /// the destination (its live page does not cross models: Open's limit). GUESS: the moved tab is
  /// selected in the destination.
  func dropTabs(_ ids: [ItemID], fromAnotherWindowInto factory: EngineWebContentHostFactory,
                parent: NodeParent, index: Int, perform: Bool) -> Bool {
    switch parent {
    case .spaceToday, .folder: break
    case .spacePinned: guard !factory.isBlankWindow else { return false }
    case .favorites, .splitPane: return false
    }
    guard let space = factory.focusedSpace, Set(ids).count == ids.count,
      let source = hostFactories.values.first(where: { other in
        other !== factory && other.model !== factory.model && ids.allSatisfy { other.model.tab(id: $0) != nil }
      }), source.isBlankWindow || factory.isBlankWindow, source.incognitoSession == nil, factory.incognitoSession == nil
    else { return false }
    guard perform else { return true }
    var position = index, last: ItemID?
    for id in ids {
      guard let tab = source.model.tab(id: id) else { continue }
      let moved = factory.model.newTab(in: space.id, url: tab.url, title: tab.title, at: 0)
      moved.customTitle = tab.customTitle; moved.customIcon = tab.customIcon; moved.iconOverride = tab.iconOverride
      if parent != .spaceToday(space.id) || position != 0 { _ = factory.model.moveNode(id: moved.id, to: parent, at: position) }
      position += 1; last = moved.id
      source.releaseTabToAnotherWindow(id)
    }
    if let last { factory.select(nodeID: last) }
    scheduleSave()
    return last != nil
  }
}

extension EngineWebContentHostFactory {
  /// The tab left for another window: no Archive entry and no Undo (the tab still exists there).
  /// A Blank Window left with no tab closes, as when its last tab moves to a Space.
  func releaseTabToAnotherWindow(_ id: ItemID) {
    controller?.container.closeHost(for: id); hosts[id]?.close()
    let undo = model.undoManager; undo?.disableUndoRegistration()
    model.closeTab(id: id)
    undo?.enableUndoRegistration()
    model.archiveSink?.discardArchived(ids: [id])
    if isBlankWindow, orderedTabs.isEmpty { DispatchQueue.main.async { [weak self] in self?.window?.performClose(nil) } }
    else if isBlankWindow { select(nodeID: orderedTabs.first?.id) }
  }

  /// Row menu ▸ Move to ▸ ‹Space›: the tab leaves this window and opens at the top of that
  /// Space's Today list in the browser's model. The page loads again there (its live page does
  /// not move between the two models: Open's limit, not an Arc fact).
  func moveBlankWindowTab(_ id: ItemID, toSpace spaceID: SpaceID) -> Bool {
    guard isBlankWindow, let tab = model.tab(id: id), app.model.space(id: spaceID) != nil else { return false }
    let moved = app.model.newTab(in: spaceID, url: tab.url, title: tab.title, at: 0)
    moved.customTitle = tab.customTitle; moved.customIcon = tab.customIcon; moved.iconOverride = tab.iconOverride
    releaseTabToAnotherWindow(id)
    app.scheduleSave()
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
    return ["isBlankWindow": factory.isBlankWindow, "window": factory.windowState.id.description, "space": space.id.description,
      "headerTitle": controller.context.title(of: space), "headerHidden": controller.context.hidesHeader(for: space),
      "favoritesShown": sidebar.favoritesShown, "spaceDots": sidebar.spaceSwitcherCount,
      "libraryButtonShown": !sidebar.homeButton.isHidden, "plusShown": !sidebar.plusButton.isHidden,
      "plusMenu": sidebar.plusMenu()?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [],
      "windowTitle": controller.window?.title ?? "", "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
      "inSnapshotModel": app.model.windows.contains { $0.id == factory.windowState.id },
      "moveTo": sidebar.blankHeaderMoveTo.map { ["shown": $0.shown, "title": $0.title, "menu": $0.menu] as [String: Any] } ?? [:],
      "tabs": factory.orderedTabs.map { ["id": $0.id.description, "url": $0.url.absoluteString] },
      "browserWindows": app.windowControllers.count,
      "profileDirectory": factory.focusedProfile?.dataDirectoryName ?? ""]
  }
}
#endif
