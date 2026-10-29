import AppKit
import OpenEngine
import OpenFeatures
import OpenModel
import OpenStore
import OpenSidebar
import OpenCommands
import OpenCommandBar
import OpenSuggest

// App has no window controller of its own.
typealias BrowserWindowController = OpenFeatures.BrowserWindowController

@MainActor
final class AuxiliaryPage {
  let content: OEWebContent
  let panel: NSPanel
  /// The panel's close button closes the page too.
  var closeObserver: NSObjectProtocol?
  init(content: OEWebContent, panel: NSPanel) { self.content = content; self.panel = panel }
}

/// App-owned engine wiring for one OpenFeatures window. The package sees only
/// WebContentHost; it never imports OpenEngine.
@MainActor
final class EngineWebContentHostFactory: NSResponder, WebContentHostFactory {
  unowned let app: AppDelegate
  let windowState: BrowserWindowState
  weak var controller: BrowserWindowController?
  var window: NSWindow? { controller?.window }
  var model: BrowserModel { app.model }
  var contentContainer: NSView { controller!.container }
  private(set) var hosts: [ItemID: EngineWebContentHost] = [:]
  private var modelHostIDs: Set<ItemID> = []
  private(set) var contentCreationCount = 0
  private var queuedNavigations: [ItemID: URL] = [:]
  private(set) var earlyHostRequestsRefused: Bool?
  private(set) var treeChangeCount = 0
  private(set) var mirrorSyncCount = 0
  var contents: [ItemID: OEWebContent] { hosts.filter { !$0.value.closed }.mapValues(\.content) }
  private lazy var mirror = TabStripMirror(owner: self)
  private var observerID: UUID?
  private(set) var commandBarSession: AppCommandBarSession?
  private var commandBarNavigationFocus: Set<ItemID> = []
  private(set) var isClosing = false
  var saveCaptureTasks: [UUID: Task<Void, Never>] = [:]
  var pendingSaveChoice: ((URL?) -> Void)?
  private var findSelectionTask: Task<Void, Never>?
  var hasFindSelectionTask: Bool { findSelectionTask != nil }
  var pendingRenameAlert: NSAlert?
  var sidebarSharePicker: NSSharingServicePicker?
  var spaceProfileMenu: NSMenu?
  #if OPEN_AUTOMATION
  var dismissSidebarShareForAutomation = false
  var sidebarShareRequest: [String: Any] = [:]
  var sidebarShareDismissTimerForAutomation: Timer?
  var sidebarShareDismissAttemptsForAutomation = 0
  var profileMenuResponseForAutomation: String?
  var profileMenuRequest: [String: Any] = [:]
  var sidebarMenuTrackingObserverForAutomation: NSObjectProtocol?
  #endif
  private(set) var navigationFocusDecisions = 0
  private(set) var lastNavigationFocusRestored = false
  func showCommandBar(_ mode: CommandBarMode) {
    guard !isClosing, !app.terminationRequested else { return }
    let requestedAt = LaunchTiming.shared.elapsedMilliseconds
    app.prepareCommandServices()
    if commandBarSession == nil { commandBarSession = AppCommandBarSession(factory: self) }
    commandBarSession?.show(mode, requestedAt: requestedAt)
  }
  private var enteredWindowFullscreenForPage = false
  private(set) var auxiliaryPages: [AuxiliaryPage] = []
  private(set) var popupPanel: NSPanel?
  #if OPEN_AUTOMATION
  var popupCallbackClose: (phase: String, toggle: Bool)?
  func releaseBrowsersForAutomation() -> [String: Any] { mirror.releaseWithoutClosingForAutomation() }
  #endif
  private lazy var extensionBar = makeExtensionBar()
  private lazy var findField = makeFindField()
  private var extensionBarCreated = false
  private var findFieldCreated = false

  var dialogPolicy: String?
  var permissionPolicy: String?
  var promptText: String?
  var contextMenuPolicy: String?
  var fullscreenPolicy: String?
  var pendingSavePanel: NSSavePanel?
  var savePageRequestCount = 0
  var downloadDirectory: URL?
  private(set) var events: [[String: Any]] = []
  private(set) var lastFindResult: OEFindResult?
  private(set) var pendingDialogs: [OEJavaScriptDialog] = []

  init(app: AppDelegate, state: BrowserWindowState) {
    self.app = app; windowState = state
    super.init()
    observerID = model.addObserver { [weak self] change in self?.treeChanged(change) }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { if let observerID { model.removeObserver(observerID) } }

  func attach(_ controller: BrowserWindowController) {
    self.controller = controller
    controller.onTextUndoManager = { [weak self] window in
      self?.commandBarSession?.controller?.editingUndoManager(for: window.firstResponder)
    }
    controller.keyBindingOverrides = app.keyBindings
    controller.isApplicationActive = { [weak self] in NSApp.isActive || self?.window?.isKeyWindow == true }
    controller.ownsAdditionalKeyWindow = { [weak self] in self?.ownsKeyWindow($0) == true }
    controller.onCommand = { [weak self] in self?.performAppCommand($0) == true }
    controller.onCommandWithPayload = { [weak self] in self?.performAppCommand($0, payload: $1) == true }
    controller.onCommandValidation = { [weak self] id, key in
      guard !AppCommand.featureIDs.contains(id), !id.hasPrefix("focus-split-pane-") else { return nil }
      return self?.isAppCommandEnabled(id, enabledKey: key) ?? false
    }
    controller.onLayout = { [weak self] in self?.layoutViews() }
    controller.onFocus = { [weak self] in guard let self else { return }; self.app.didFocusWindow(self.windowState.id) }
    controller.nextResponder = self; nextResponder = NSApp
    controller.onSidebarIntent = { [weak self] intent in guard let self else { return false }; return self.performSidebar(intent) }
    controller.onStateChange = { [weak self] in
      guard let self else { return }
      if self.app.engineReady { for tab in self.visibleTabs { tab.live.sleepPhase = .live }; self.controller?.container.refreshPlaceholders() }
      // BrowserWindowController schedules its SnapshotStore once per committed change.
      self.mirror.sync(); self.commandBarSession?.contextDidChange(); self.app.scheduleMenuRebuild()
    }
    controller.onOpenCommandBar = { [weak self] source, _ in
      if source == .urlField { self?.focusAddressBar(nil) } else { self?.newTab(nil) }
    }
    controller.onClose = { [weak self] in
      guard let self else { return }; self.closeAll(); self.app.windowDidClose(self.windowState.id)
    }
  }
  func engineDidBecomeReady() {
    for (id, url) in queuedNavigations { model.tab(id: id)?.url = url }
    queuedNavigations.removeAll()
    showSelection(focus: false)
  }
  #if OPEN_AUTOMATION
  func navigateBeforeEngineForAutomation(_ input: String) {
    if !app.engineReady, let tab = selectedTab, let profile = focusedProfile {
      let before = contentCreationCount
      earlyHostRequestsRefused = context(for: profile.id) == nil && ensureContent(for: tab) == nil
        && makeHost(tabID: tab.id, profileID: profile.id, url: nil) == nil && contentCreationCount == before
    }
    if let url = Self.url(forInput: input, profile: focusedProfile) { navigateFromCommandBar(url, current: true) }
  }
  #endif

  var focusedSpace: Space? { model.space(id: windowState.focusedSpaceID) ?? model.spaces.first }
  var focusedProfile: Profile? { focusedSpace.flatMap { model.profile(id: $0.profileID) } }
  var selectedNodeID: ItemID? { focusedSpace.flatMap { windowState.selectedNodeBySpace[$0.id] } }
  var selectedTab: Tab? { controller?.splitController.focusedTab }
  var visibleTabs: [Tab] { controller?.splitController.split?.panes ?? selectedTab.map { [$0] } ?? [] }
  var selectedContent: OEWebContent? {
    if let controller, controller.hasPeekController, controller.peekController.isShown {
      return (controller.peekController.stack.last?.host as? EngineWebContentHost)?.content
    }
    return selectedTab.flatMap { hosts[$0.id]?.content }
  }
  var orderedTabs: [Tab] {
    (focusedProfile?.favorites ?? []) + (focusedSpace.map { flattened($0.pinned) + flattened($0.today) } ?? [])
  }
  func flattened(_ nodes: [SidebarNode]) -> [Tab] {
    nodes.flatMap { node in
      switch node { case .tab(let tab): [tab]; case .folder(let folder): flattened(folder.children); case .split(let split): split.panes }
    }
  }
  /// A profile's tabs in tab-strip order: favorites, then every Space's
  /// pinned tabs, then every Space's Today tabs, in Space order (Chromium
  /// keeps one pinned prefix, so chrome.tabs indexes match this order).
  func tabs(in profileID: ProfileID) -> [Tab] {
    let spaces = model.spaces.filter { $0.profileID == profileID }
    return (model.profile(id: profileID)?.favorites ?? []) + spaces.flatMap { flattened($0.pinned) }
      + spaces.flatMap { flattened($0.today) }
  }
  func space(for tabID: ItemID) -> Space? {
    model.spaces.first { (flattened($0.pinned) + flattened($0.today)).contains { $0.id == tabID } }
  }
  func profile(for tabID: ItemID) -> Profile? {
    if let space = space(for: tabID) { return model.profile(id: space.profileID) }
    return model.profiles.first { $0.favorites.contains { $0.id == tabID } }
  }
  private func profile(for context: OEBrowserContext) -> Profile? {
    context === OEEngine.shared.defaultContext ? model.defaultProfile : model.profiles.first { $0.dataDirectoryName == context.identifier }
  }
  func context(for profileID: ProfileID) -> OEBrowserContext? {
    guard app.engineReady, let profile = model.profile(id: profileID) else { return nil }
    if profile.id == model.defaultProfile?.id { return OEEngine.shared.defaultContext }
    guard app.engine.result.layout == .engine else {
      // The old layout has no disk folder for other profiles (CEF refused
      // Profiles/<dir>/Engine). Their pages wait for the next launch, whose
      // migration retries; they never run in a memory-only profile.
      if Self.legacyRefusals.insert(profile.dataDirectoryName).inserted {
        FileHandle.standardError.write(Data(
          "Open: profile \(profile.dataDirectoryName) unavailable this launch (engine data still in the old layout)\n".utf8))
      }
      return nil
    }
    return OEEngine.shared.context(identifier: profile.dataDirectoryName, directory: app.directories.engineDirectory(dataDirectoryName: profile.dataDirectoryName))
  }
  private static var legacyRefusals: Set<String> = []
  var focusedBrowser: OEBrowser? {
    guard app.engineReady, let profile = focusedProfile else { return nil }; return mirror.browser(for: profile.id)
  }
  func tabID(for content: OEWebContent) -> ItemID? { hosts.first { $0.value.content === content }?.key }
  private func withoutUndo(_ body: () -> Void) {
    app.undoManager.disableUndoRegistration(); defer { app.undoManager.enableUndoRegistration() }; body()
  }

  func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?) -> (any WebContentHost)? {
    guard let context = context(for: profileID) else {
      if let url, model.tab(id: tabID) != nil { queuedNavigations[tabID] = url }
      return nil
    }
    if let host = hosts[tabID], !host.closed { return host }
    let config = OEWebContentConfiguration(context: context)
    // Sidebar tabs are tabs of the window's hidden Chrome window (fork patch
    // P1). Hosts that are not model tabs (Peek) stay Alloy: a Chrome style
    // page outside a strip would get its own Chrome window.
    let isModelTab = model.tab(id: tabID) != nil
    config.runtimeStyle = isModelTab ? app.options.defaultStyle : .alloy
    config.showsChromeToolbar = app.options.chromeToolbar
    if isModelTab, model.tab(id: tabID)?.url.scheme == "chrome" { config.runtimeStyle = .chrome }
    contentCreationCount += 1
    let content = OEWebContent(configuration: config, url: nil)
    content.isMuted = model.tab(id: tabID)?.isMuted ?? false
    content.view.isHidden = true
    let host = EngineWebContentHost(tabID: tabID, profileID: profileID, content: content, owner: self)
    hosts[tabID] = host
    if model.tab(id: tabID) != nil { modelHostIDs.insert(tabID) }
    mirror.sync()
    if let url { host.load(url) }
    return host
  }
  func hostDidClose(_ host: EngineWebContentHost) {
    commandBarNavigationFocus.remove(host.tabID)
    if hosts[host.tabID] === host { hosts[host.tabID] = nil }
    modelHostIDs.remove(host.tabID)
    mirror.sync()
  }
  func adoptHost(_ host: any WebContentHost, as tabID: ItemID) -> Bool {
    guard let host = host as? EngineWebContentHost, host.owner === self, !host.closed,
          profile(for: tabID)?.id == host.profileID else { return false }
    // Sidebar tabs are tabs of the window's hidden Chrome window (fork patch
    // P1); a Peek page is Alloy. Refusing closes it, and the container makes a
    // Chrome host for the tab at its URL: one reload, accepted for v1
    // (docs/m4.md, Peek expand).
    if model.tab(id: tabID) != nil, host.content.runtimeStyle != app.options.defaultStyle { return false }
    if host.tabID != tabID {
      let oldID = host.tabID
      if let previous = hosts[tabID], previous !== host { controller?.container.closeHost(for: tabID); previous.close() }
      if hosts[oldID] === host { hosts[oldID] = nil }
      modelHostIDs.remove(oldID)
      host.rebind(tabID: tabID, spaceID: space(for: tabID)?.id)
      hosts[tabID] = host; modelHostIDs.insert(tabID)
    }
    mirror.sync(); return true
  }
  func didSyncMirror() { mirrorSyncCount += 1 }
  func remainingLiveState(for tabID: ItemID) -> WebContentLiveState? {
    app.hostFactories.values.compactMap { $0.hosts[tabID] }.first { !$0.closed }?.liveState
  }
  func tabStripState() -> [[String: Any]] { mirror.snapshot() }
  @discardableResult
  func ensureContent(for tab: Tab) -> OEWebContent? {
    guard app.engineReady else { queuedNavigations[tab.id] = tab.url; return nil }
    if let host = hosts[tab.id] { return host.content }
    guard let profileID = profile(for: tab.id)?.id else { return nil }
    tab.live.sleepPhase = .live
    guard let host = makeHost(tabID: tab.id, profileID: profileID, url: nil) as? EngineWebContentHost else { return nil }
    controller?.container.adopt(host, for: tab.id)
    if host.view.superview == nil { host.view.frame = contentContainer.bounds; contentContainer.addSubview(host.view) }
    host.load(tab.url)
    return host.content
  }
  private func makeContent(for tab: Tab, url: URL?, requestContext: OEBrowserContext? = nil) -> OEWebContent? {
    guard app.engineReady else { queuedNavigations[tab.id] = url ?? tab.url; return nil }
    guard let profile = profile(for: tab.id) ?? requestContext.flatMap({ self.profile(for: $0) }) else { return nil }
    tab.live.sleepPhase = .live
    guard let host = makeHost(tabID: tab.id, profileID: profile.id, url: nil) as? EngineWebContentHost else { return nil }
    controller?.container.adopt(host, for: tab.id)
    if host.view.superview == nil { host.view.frame = contentContainer.bounds; contentContainer.addSubview(host.view) }
    if let url { host.load(url) }; mirror.sync(); return host.content
  }
  private func dropContent(id: ItemID, content: OEWebContent) { controller?.container.closeHost(for: id); hosts[id]?.close() }
  private func treeChanged(_ change: TreeChange) {
    guard !isClosing, !app.shutdownPrepared else { return }
    treeChangeCount += 1
    if case .spaceProfileChanged(let spaceID, _, _) = change, let space = model.space(id: spaceID) {
      let ids = Set((flattened(space.pinned) + flattened(space.today)).map(\.id))
      if let controller, controller.hasPeekController,
         controller.peekController.stack.contains(where: { ids.contains($0.sourceTabID) || ($0.host as? EngineWebContentHost)?.spaceID == spaceID }) { controller.peekController.dismissAll() }
      for (id, host) in hosts where ids.contains(id) || (model.tab(id: id) == nil && host.spaceID == spaceID) {
        controller?.container.closeHost(for: id); host.close()
      }
      for id in ids { controller?.container.resetLiveState(for: id, includingFavicon: true) }
    }
    // Peek hosts are transient until expanded into the model. A sidebar
    // mutation must not close them merely because they have no model row.
    modelHostIDs.formUnion(hosts.keys.filter { model.tab(id: $0) != nil })
    for (id, host) in hosts where modelHostIDs.contains(id) && (model.tab(id: id) == nil || !tabs(in: host.profileID).contains(where: { $0.id == id })) {
      controller?.container.closeHost(for: id); host.close()
    }
    if let id = selectedNodeID, model.node(id: id) == nil, let space = focusedSpace {
      withoutUndo { model.selectNode(windowID: windowState.id, spaceID: space.id, nodeID: nil) }
    }
    if case .spaceProfileChanged(let id, _, _) = change, focusedSpace?.id == id { showSelection(focus: false) }
    else { controller?.refresh(); mirror.sync() }
  }
  func showSelection(focus: Bool = true) {
    guard let controller else { return }
    if app.engineReady { for tab in visibleTabs { tab.live.sleepPhase = .live } }
    controller.refresh(); mirror.sync()
    window?.title = selectedTab?.displayTitle.isEmpty == false ? selectedTab!.displayTitle : "Open"
    if focus { selectedContent?.focusPage() }
    commandBarSession?.contextDidChange(); app.scheduleMenuRebuild()
    layoutViews()
  }
  func select(nodeID: ItemID?, focus: Bool = true) {
    guard let space = focusedSpace else { return }
    withoutUndo { model.selectNode(windowID: windowState.id, spaceID: space.id, nodeID: nodeID) }
    controller?.dismissSidebarReveal()
    showSelection(focus: focus); app.scheduleSave()
  }
  @discardableResult
  func openNewTab(url: URL, background: Bool, opener: ItemID? = nil) -> Tab? {
    guard let space = focusedSpace else { return nil }
    // Lead Q11: a tab opened in the background is unread until it is selected.
    let tab = model.newTab(in: space.id, url: url, at: 0, unread: background); tab.openerID = opener
    if !background { select(nodeID: tab.id) }
    app.scheduleSave(); return tab
  }
  func adoptUnownedRequest(_ request: OEOpenRequest) -> OEWebContent? {
    guard app.engineReady else { return nil }
    guard let profile = profile(for: request.context),
      let space = focusedSpace.flatMap({ $0.profileID == profile.id ? $0 : nil }) ?? model.spaces.first(where: { $0.profileID == profile.id }) else { return nil }
    let tab = model.newTab(in: space.id, url: request.url ?? URL(string: "about:blank")!, at: 0)
    let content = makeContent(for: tab, url: nil, requestContext: request.context); focus(space: space); select(nodeID: tab.id); return content
  }
  func focus(space: Space) {
    withoutUndo { model.focusSpace(windowID: windowState.id, spaceID: space.id) }
    controller?.dismissSidebarReveal(); showSelection(); app.scheduleSave()
  }

  /// Only model-only cases fall back to the package. Unsupported later-step
  /// editors return false, so no successful no-op reaches the sidebar.
  func performSidebar(_ intent: SidebarIntent) -> Bool? {
    switch intent {
    case .dismissAutoArchiveBanner: app.dismissAutoArchiveEducation(); return true
    case .openProfileSettings(let id):
      guard model.profile(id: id) != nil else { return false }
      app.dismissAutoArchiveEducation(); app.settingsPresenter.showProfileSettings(profileID: id); return true
    case .toggleSidebar: controller?.toggleSidebar(); return true
    case .select(let id, let spaceID):
      guard model.space(id: spaceID) != nil, model.node(id: id) != nil else { return false }
      withoutUndo { model.focusSpace(windowID: windowState.id, spaceID: spaceID) }
      select(nodeID: id); return true
    case .selectFavorite(let id): guard model.tab(id: id) != nil else { return false }; select(nodeID: id); return true
    case .switchSpace(let id): guard let space = model.space(id: id) else { return false }; focus(space: space); return true
    case .openCommandBar(let source): if source == .urlField { focusAddressBar(nil) } else { newTab(nil) }; return true
    case .newTab: newTab(nil); return true
    case .close(let id), .unloadTab(let id):
      guard model.tab(id: id) != nil else { return nil }; closeTab(id: id); return true
    case .goBack: guard let page = selectedContent, page.canGoBack else { return false }; page.goBack(); return true
    case .goForward: guard let page = selectedContent, page.canGoForward else { return false }; page.goForward(); return true
    case .reload: guard let page = selectedContent else { return false }; page.reload(); return true
    case .stopLoading: guard let page = selectedContent else { return false }; page.stopLoading(); return true
    case .copyCurrentURL:
      guard let tab = selectedTab else { return false }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tab.url.absoluteString, forType: .string); return true
    case .toggleMute(let id):
      guard let tab = model.tab(id: id) else { return false }; model.setMuted(tabID: id, muted: !tab.isMuted); hosts[id]?.content.isMuted = tab.isMuted; app.scheduleSave(); return true
    case .resetToPinnedURL(let id):
      guard let tab = model.tab(id: id), let url = tab.pinnedURL else { return false }; model.resetPinnedTab(id: id); hosts[id]?.load(url); app.scheduleSave(); return true
    case .newSpace:
      guard let profile = focusedProfile else { return false }; focus(space: model.createSpace(title: "Space", profileID: profile.id)); return true
    case .openURL(let url, let parent, let index):
      let before = Set(model.index.keys)
      guard let context = controller?.context, ModelSidebarActions(context: context).perform(.openURL(url, in: parent, index: index)),
        let tab = model.index.values.compactMap(\.tab).first(where: { !before.contains($0.id) }) else { return false }
      select(nodeID: tab.id); return true
    case .copyLink(let id, let markdown):
      return copyLinks(ids: [id], markdown: markdown)
    case .copyLinks(let ids, let markdown): return copyLinks(ids: ids, markdown: markdown)
    case .copyAllLinks(let id, let markdown): return copyLinks(ids: [id], markdown: markdown)
    case .moveNodesToNewSpace(let ids): return moveSelectionToNewSpace(ids: ids)
    case .moveToNewSpace(let id): return moveSelectionToNewSpace(ids: [id])
    case .turnFolderIntoSpace(let id):
      // The App disables event grouping. Name the action while this explicit
      // group is open, before the model's one-step registration is closed.
      app.undoManager.beginUndoGrouping()
      defer { app.undoManager.endUndoGrouping() }
      guard let space = model.turnFolderIntoSpace(id: id) else { return false }
      let actionName: String = "New Space"
      app.undoManager.setActionName(actionName)
      focus(space: space); app.scheduleSave(); app.scheduleMenuRebuild(); return true
    case .share(let id): return shareSidebarTab(id)
    case .duplicate(let id): return model.duplicateNode(id: id) != nil
    case .showLibrary: app.settingsPresenter.showLibrary(); return true
    case .manageSpaces:
      app.settingsPresenter.showLibrary(section: .spaces); return true
    case .showSiteControls, .changeSpaceIcon, .editSpaceTheme, .newProfile, .shareSpace,
         .editPinnedURL, .changeIcon, .customizePage:
      return false // Explicitly deferred UI entries; see docs/app-shell.md Step B.
    default: return nil
    }
  }

  private func copyLinks(ids: [ItemID], markdown: Bool) -> Bool {
    var seen = Set<ItemID>(), lines: [String] = []
    func append(_ node: SidebarNode) {
      guard seen.insert(node.id).inserted else { return }
      switch node {
      case .tab(let tab): lines.append(markdown ? "[\(tab.displayTitle)](\(tab.url.absoluteString))" : tab.url.absoluteString)
      case .folder(let folder): folder.children.forEach(append)
      case .split(let split): split.panes.forEach { append(.tab($0)) }
      }
    }
    // Selected containers cover their descendants, even if a child also appears
    // earlier in the payload. Preserve the displayed order of top-level nodes.
    let selected = Set(ids)
    for id in ids {
      var parent = model.parent(of: id), covered = false
      while let current = parent {
        switch current {
        case .folder(let ancestor), .splitPane(let ancestor):
          if selected.contains(ancestor) { covered = true }
          parent = model.parent(of: ancestor)
        default: parent = nil
        }
      }
      if !covered, let node = model.node(id: id) { append(node) }
    }
    guard !lines.isEmpty else { return false }
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
  }

  private func moveSelectionToNewSpace(ids: [ItemID]) -> Bool {
    guard let profile = focusedProfile, controller?.context.canMoveNodesToNewSpace(ids) == true,
      let space = model.createSpace(title: "Space", profileID: profile.id, icon: nil, theme: SpaceTheme(), at: nil, moving: ids)
    else { return false }
    focus(space: space); app.scheduleSave(); app.scheduleMenuRebuild(); return true
  }

  /// One close rule for Cmd-W, the sidebar, window.close() and
  /// chrome.tabs.remove: pinned tabs and favorites stay in the sidebar and
  /// unload; Today tabs close (archived).
  func closeTab(id: ItemID) {
    guard model.tab(id: id) != nil else { return }
    let order = orderedTabs.map(\.id), index = order.firstIndex(of: id) ?? 0
    let wasSelected = selectedTab?.id == id
    var isFavorite = false
    if case .favorites? = model.parent(of: id) { isFavorite = true }
    if model.isPinned(tabID: id) || isFavorite {
      controller?.container.closeHost(for: id); hosts[id]?.close()
    } else { model.closeTab(id: id) }
    if wasSelected {
      let remaining = orderedTabs.map(\.id).filter { $0 != id }
      select(nodeID: remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)])
    } else { controller?.refresh(); mirror.sync(); app.scheduleSave() }
  }
  func closeAll() {
    guard !isClosing else { return }
    isClosing = true
    for task in saveCaptureTasks.values { task.cancel() }
    saveCaptureTasks.removeAll()
    findSelectionTask?.cancel(); findSelectionTask = nil
    pendingSaveChoice = nil
    if let panel = pendingSavePanel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }
    pendingSavePanel = nil
    if let sheet = pendingRenameAlert?.window { window?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
    pendingRenameAlert = nil
    sidebarSharePicker?.close(); sidebarSharePicker = nil
    spaceProfileMenu?.cancelTrackingWithoutAnimation(); spaceProfileMenu = nil
    #if OPEN_AUTOMATION
    stopShareDismissalForAutomation()
    stopObservingSidebarMenusForAutomation()
    #endif
    commandBarNavigationFocus.removeAll()
    commandBarSession?.dismiss()
    controller?.container.closeAll(); for host in Array(hosts.values) { host.close() }
    for page in auxiliaryPages { closeAuxiliary(page); page.panel.close() }
    popupPanel?.close(); mirror.close()
  }
  func content(forAutomationHandle handle: Any?) -> OEWebContent? {
    switch handle {
    case nil: return selectedContent
    case let text as String where text == "popup": return focusedBrowser?.extensionPopup
    case let text as String: return UUID(uuidString: text).map { ItemID(rawValue: $0) }.flatMap { model.tab(id: $0) }.flatMap { ensureContent(for: $0) }
    case let number as Int: return OEEngine.shared.webContent(identifier: number)
    default: return nil
    }
  }
  func record(_ type: String, _ content: OEWebContent?, _ info: [String: Any]) {
    var event = info; event["type"] = type; event["tab"] = content.flatMap { tabID(for: $0)?.description } ?? ""
    event["content"] = content?.identifier ?? 0; event["time"] = Date().timeIntervalSince1970
    events.append(event); if events.count > 2000 { events.removeFirst(events.count - 2000) }
  }
  func drainEvents() -> [[String: Any]] { defer { events.removeAll() }; return events }
  func completePendingDialog(accept: Bool, text: String?) -> Bool {
    guard !pendingDialogs.isEmpty else { return false }; pendingDialogs.removeFirst().complete(accepted: accept, text: text); return true
  }
  private func makeFindField() -> NSSearchField {
    let field = NSSearchField(); field.placeholderString = "Find in page"; field.target = self; field.delegate = self
    field.action = #selector(findFieldChanged(_:)); field.isHidden = true
    controller?.contentView.addSubview(field); findFieldCreated = true; return field
  }
  private func makeExtensionBar() -> NSStackView {
    let bar = NSStackView(); bar.orientation = .horizontal; bar.spacing = 4
    controller?.contentView.addSubview(bar); extensionBarCreated = true; return bar
  }
  private func layoutViews() {
    guard let controller else { return }; let panel = controller.container.frame
    if findFieldCreated { findField.frame = CGRect(x: panel.maxX - 268, y: panel.minY + 8, width: 260, height: 24) }
    if extensionBarCreated { extensionBar.frame = CGRect(x: panel.maxX - 210, y: panel.minY + 8, width: 200, height: 26) }
  }
  private func updateChrome() { window?.title = selectedTab?.displayTitle ?? "Open" }
}

extension EngineWebContentHostFactory {
  private func reloadExtensionBar() {
    guard app.engineReady else { return }
    extensionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for action in focusedBrowser?.extensionActions ?? [] {
      // Fork patch P2: Chrome's toolbar image (badge, disabled state).
      // A copy: the snapshot's image keeps its own size.
      let image =
        (action.toolbarImage ?? action.icon)?.copy() as? NSImage
        ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
      image.size = NSSize(width: 18, height: 18)
      let button = NSButton(image: image, target: self, action: #selector(extensionButtonClicked(_:)))
      button.bezelStyle = .accessoryBarAction
      button.isBordered = false
      button.toolTip = action.title
      button.identifier = .init(action.extensionIdentifier)
      button.isEnabled = action.isEnabled
      extensionBar.addArrangedSubview(button)
    }
    let manage = NSButton(title: "⋯", target: self, action: #selector(openExtensionsPage(_:)))
    manage.bezelStyle = .accessoryBarAction
    manage.toolTip = "Manage extensions"
    extensionBar.addArrangedSubview(manage)
    layoutViews()
  }

  @objc private func extensionButtonClicked(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    focusedBrowser?.executeExtensionAction(id)
  }

  // MARK: Panels

  private func makePanel(size: NSSize, title: String, titled: Bool = true) -> NSPanel {
    let style: NSWindow.StyleMask = titled ? [.titled, .closable, .resizable] : [.borderless]
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    panel.title = title
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.becomesKeyOnlyIfNeeded = false
    return panel
  }

  /// Shows a panel even while another app is active (automation drives Open
  /// from a terminal).
  private func present(_ panel: NSPanel) {
    panel.orderFrontRegardless()
    panel.makeKey()
  }

  private func host(_ content: OEWebContent, in panel: NSPanel) {
    let container = NSView(frame: NSRect(origin: .zero, size: panel.contentLayoutRect.size))
    panel.contentView = container
    content.view.frame = container.bounds
    content.view.autoresizingMask = [.width, .height]
    container.addSubview(content.view)
  }

}

extension EngineWebContentHostFactory {
  @objc func newTab(_ sender: Any?) { showCommandBar(.newTab) }
  @objc func focusAddressBar(_ sender: Any?) { showCommandBar(.editCurrentURL) }

  func ownsKeyWindow(_ candidate: NSWindow) -> Bool {
    candidate === window || candidate === popupPanel || auxiliaryPages.contains { $0.panel === candidate }
  }
  func navigateFromCommandBar(_ url: URL, current: Bool, background: Bool = false) {
    if current, selectedContent != nil || selectedTab != nil {
      if let id = selectedTab?.id { commandBarNavigationFocus.insert(id) }
      if !app.engineReady, let tab = selectedTab {
        queuedNavigations[tab.id] = url; tab.url = url; app.scheduleSave()
      } else { selectedContent?.load(url); selectedContent?.focusPage() }
    } else if let tab = openNewTab(url: url, background: background) {
      if background { _ = ensureContent(for: tab) }
      else { commandBarNavigationFocus.insert(tab.id) }
    }
    if let profile = focusedProfile { app.stores.recordTyped(url: url, title: url.host() ?? url.absoluteString, profileID: profile.id) }
  }
  private func finishCommandBarNavigation(_ page: OEWebContent) {
    guard let id = tabID(for: page), commandBarNavigationFocus.remove(id) != nil else { return }
    DispatchQueue.main.async { [weak self, weak page] in
      guard let self, let page else { return }
      // The bar had focused the old document before navigating. A hosted
      // Chrome tab can reuse its native responder while replacing its renderer;
      // give the committed page a real blur/focus transition after strip sync.
      self.lastNavigationFocusRestored = self.restorePageFocusIfUnclaimed(page, resetResponder: true)
      self.navigationFocusDecisions += 1
    }
  }

  /// Async completions may restore the page only while its native focus is
  /// unclaimed. Sidebar controls, field editors, sheets and other windows win.
  @discardableResult
  func restorePageFocusIfUnclaimed(_ page: OEWebContent? = nil, resetResponder: Bool = false) -> Bool {
    guard !isClosing, !app.terminationRequested, app.engineReady, NSApp.isActive,
          let window, window.isKeyWindow, window.attachedSheet == nil,
          commandBarSession?.isPresented != true,
          let page = page ?? selectedContent, selectedContent === page else { return false }
    let responder = window.firstResponder
    let view = responder as? NSView
    guard responder === window
      || view.map({ $0 === page.view || $0.isDescendant(of: page.view) }) == true else { return false }
    if resetResponder { window.makeFirstResponder(nil) }
    page.focusPage()
    return true
  }

  func focusStateForAutomation() -> [String: Any] {
    let responder = window?.firstResponder
    let view = responder as? NSView
    var owner = "other"
    if responder == nil || responder === window { owner = "window" }
    else if findFieldCreated, responder === findField || responder === findField.currentEditor() { owner = "find" }
    else if commandBarSession?.controller?.editingUndoManager(for: responder) != nil { owner = "commandbar" }
    else if let view, let sidebar = controller?.sidebar,
            view === sidebar || view.isDescendant(of: sidebar)
              || ((responder as? NSTextView)?.delegate as? NSView).map({ $0.isDescendant(of: sidebar) }) == true { owner = "sidebar" }
    else if let page = selectedContent, let view, view === page.view || view.isDescendant(of: page.view) { owner = "page" }
    return ["owner": owner, "responder": responder.map { String(describing: type(of: $0)) } ?? "none",
      "navigationDecisions": navigationFocusDecisions, "lastNavigationRestored": lastNavigationFocusRestored,
      "findVisible": findFieldCreated && !findField.isHidden,
      "findText": findFieldCreated ? findField.stringValue : "", "sheet": window?.attachedSheet != nil]
  }
  func selectTabForCommand(_ id: ItemID, spaceID: SpaceID? = nil) {
    guard let tab = model.tab(id: id) else { return }
    if let space = spaceID.flatMap({ model.space(id: $0) }) ?? space(for: id) { focus(space: space) }
    var nodeID = tab.id
    var parent = model.parent(of: nodeID)
    while let container = parent {
      switch container {
      case .folder(let folder): model.setExpanded(folderID: folder, expanded: true); parent = model.parent(of: folder)
      case .splitPane(let split): model.focusSplitPane(splitID: split, tabID: tab.id); nodeID = split; parent = model.parent(of: split)
      default: parent = nil
      }
    }
    select(nodeID: nodeID); controller?.sidebar.reveal(nodeID: tab.id)
  }

  @objc func closeTab(_ sender: Any?) {
    if let popupPanel, NSApp.keyWindow === popupPanel {
      focusedBrowser?.closeExtensionPopup()
      return
    }
    if let panel = NSApp.keyWindow as? NSPanel, let page = auxiliaryPages.first(where: { $0.panel === panel }) { closeAuxiliary(page); return }
    if let tab = selectedTab { closeTab(id: tab.id) }
  }

  @objc func restoreLastClosedTab(_ sender: Any?) {
    let store = app.archiveSink.store(for: focusedProfile?.id)
    Task { @MainActor in
      guard let recent = await store.recent(limit: 1).first,
        let record = await store.restore(id: recent.id)
      else { return }
      guard !self.isClosing, !self.app.terminationRequested else { return }
      let tab = self.model.restoreArchivedTab(record)
      self.select(nodeID: tab.id)
    }
  }

  @objc func togglePin(_ sender: Any?) {
    guard let tab = selectedTab else { return }
    if model.isPinned(tabID: tab.id) { model.unpinTab(id: tab.id) } else { model.pinTab(id: tab.id) }
  }

  @objc func addSplitView(_ sender: Any?) {
    guard let selected = selectedTab else { return }
    if let split = controller?.splitController.split { model.unsplit(splitID: split.id); showSelection() }
    else if let other = orderedTabs.first(where: { $0.id != selected.id && !model.isPinned(tabID: $0.id) }),
      let split = model.makeSplit(tabIDs: [selected.id, other.id]) { select(nodeID: split.id) }
    else { controller?.splitController.addEmptyPane(); showSelection() }
  }

  @objc func printPage(_ sender: Any?) { selectedContent?.showPrintPanel() }
  @objc func reloadPage(_ sender: Any?) { selectedContent?.reload() }
  @objc func stopLoading(_ sender: Any?) { selectedContent?.stopLoading() }
  @objc func goBack(_ sender: Any?) { selectedContent?.goBack() }
  @objc func goForward(_ sender: Any?) { selectedContent?.goForward() }
  @objc func zoomIn(_ sender: Any?) { selectedContent?.zoomIn() }
  @objc func zoomOut(_ sender: Any?) { selectedContent?.zoomOut() }
  @objc func resetZoom(_ sender: Any?) { selectedContent?.resetZoom() }
  @objc func showDevTools(_ sender: Any?) { selectedContent?.showDevTools() }

  @objc func openExtensionsPage(_ sender: Any?) { _ = openNewTab(url: OEExtensionManager.managementPageURL, background: false) }
  @objc func toggleSidebar(_ sender: Any?) { controller?.toggleSidebar() }
  @objc func newWindow(_ sender: Any?) { app.newWindow(nil) }

  @objc func nextTab(_ sender: Any?) { cycleTab(by: 1) }
  @objc func previousTab(_ sender: Any?) { cycleTab(by: -1) }

  func cycleTab(by delta: Int) {
    let ids = orderedTabs.map(\.id)
    guard !ids.isEmpty else { return }
    let current = selectedTab.flatMap { ids.firstIndex(of: $0.id) } ?? -delta
    select(nodeID: ids[(current + delta + ids.count) % ids.count])
  }

  @objc func nextSpace(_ sender: Any?) { cycleSpace(by: 1) }
  @objc func previousSpace(_ sender: Any?) { cycleSpace(by: -1) }

  func cycleSpace(by delta: Int) {
    guard let i = model.spaces.firstIndex(where: { $0.id == focusedSpace?.id }), model.spaces.count > 1 else {
      return
    }
    focus(space: model.spaces[(i + delta + model.spaces.count) % model.spaces.count])
  }

  @objc func showFind(_ sender: Any?) {
    _ = findField; layoutViews(); findField.isHidden = false
    window?.makeFirstResponder(findField)
  }

  func findPrevious() {
    guard findFieldCreated, !findField.stringValue.isEmpty else { return }
    selectedContent?.find(findField.stringValue, forward: false, caseSensitive: false)
  }

  @objc func findNext(_ sender: Any?) {
    guard !findField.stringValue.isEmpty else { return }
    selectedContent?.find(findField.stringValue, forward: true, caseSensitive: false)
  }

  @objc private func findFieldChanged(_ sender: NSSearchField) {
    if sender.stringValue.isEmpty {
      selectedContent?.stopFinding(clearSelection: true)
      findField.isHidden = true
      selectedContent?.focusPage()
    } else {
      selectedContent?.find(sender.stringValue, forward: true, caseSensitive: false)
    }
  }

  /// URL for address-field input: a URL, a host, or a search.
  static func url(forInput text: String, profile: Profile?) -> URL? {
    if text.contains("://") || text.hasPrefix("about:") || text.hasPrefix("chrome:") {
      return URL(string: text)
    }
    if text.contains(".") && !text.contains(" ") {
      return URL(string: "https://\(text)")
    }
    return SearchEngines.resolve(profile: profile).searchURL(for: text)
  }

  /// Closes one page wherever it lives.
  func close(page: OEWebContent) {
    if let aux = auxiliaryPages.first(where: { $0.content === page }) {
      closeAuxiliary(aux)
    } else if page.extensionPopupIdentifier != nil {
      page.browser?.closeExtensionPopup()
      focusedBrowser?.closeExtensionPopup()
    } else if let id = tabID(for: page) {
      closeTab(id: id)
    } else {
      page.close()
    }
  }

  func closeAuxiliary(_ page: AuxiliaryPage) {
    guard auxiliaryPages.contains(where: { $0 === page }) else { return }
    auxiliaryPages.removeAll { $0 === page }
    if let observer = page.closeObserver { NotificationCenter.default.removeObserver(observer) }
    page.closeObserver = nil
    page.content.close()
    page.panel.orderOut(nil)
  }
}

extension EngineWebContentHostFactory: NSSearchFieldDelegate {
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if control === findField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      findField.isHidden = true; selectedContent?.stopFinding(clearSelection: true); selectedContent?.focusPage(); return true
    }
    return false
  }
}

// MARK: - OEWebContentDelegate

extension EngineWebContentHostFactory: OEWebContentDelegate {
  func webContent(_ webContent: OEWebContent, didChange changes: OEWebContentChange) {
    if changes.contains(.title), let popup = auxiliaryPages.first(where: { $0.content === webContent }) { popup.panel.title = webContent.title }
    record("change", webContent, ["changes": changes.rawValue])
  }

  static func pngData(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }

  func webContent(_ webContent: OEWebContent, createWebContentFor request: OEOpenRequest) -> OEWebContent? {
    guard app.engineReady else { return nil }
    let config = OEWebContentConfiguration(context: request.context)
    config.runtimeStyle = webContent.runtimeStyle
    switch request.disposition {
    case .newPopup:
      let popup = OEWebContent(configuration: config, url: nil)
      popup.delegate = self
      var size = request.requestedFrame.size
      if size.width < 100 || size.height < 100 { size = NSSize(width: 600, height: 500) }
      let panel = makePanel(size: size, title: request.url?.host() ?? "Popup")
      host(popup, in: panel)
      panel.center()
      present(panel)
      let page = AuxiliaryPage(content: popup, panel: panel)
      page.closeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: panel, queue: .main
      ) { [weak self, weak page] _ in
        MainActor.assumeIsolated { if let self, let page { self.closeAuxiliary(page) } }
      }
      auxiliaryPages.append(page)
      record("open", popup, ["disposition": "popup", "url": request.url?.absoluteString ?? ""])
      return popup
    case .newWindow:
      let sourceSpace = tabID(for: webContent).flatMap { space(for: $0) } ?? hosts.values.first { $0.content === webContent }?.spaceID.flatMap { model.space(id: $0) }
      guard let controller = app.makeWindow(focusedSpaceID: sourceSpace?.id), let target = app.hostFactories[controller.windowID] else { return nil }
      if webContent.runtimeStyle == .chrome, let url = request.url {
        // The engine would make the page a tab of the opener window's hidden
        // Chrome window (P1), which closes with that window. A new window
        // needs no opener: open the URL as a new tab there instead.
        target.openNewTab(url: url, background: false)
        record("open", webContent, ["disposition": "newWindow", "url": url.absoluteString, "newTab": true])
        return nil
      }
      return target.adoptUnownedRequest(request)
    case .currentTab, .saveToDisk:
      return nil
    default:
      let opener = tabID(for: webContent)
      if let opener, model.tab(id: opener) == nil, app.options.defaultStyle == .chrome, let url = request.url {
        // A Peek page (a host that is not a model tab) is Alloy, and so would
        // be the page it opens: not a chrome.tabs tab. Open the URL as a tab.
        openNewTab(url: url, background: request.disposition == .newBackgroundTab)
        record("open", webContent, ["disposition": request.disposition.rawValue, "url": url.absoluteString, "fromPeek": true])
        return nil
      }
      let source = opener.flatMap { space(for: $0) } ?? hosts.values.first { $0.content === webContent }?.spaceID.flatMap { model.space(id: $0) }
      guard let space = source ?? focusedSpace, space.profileID == profile(for: request.context)?.id else { return nil }
      let tab = model.newTab(in: space.id, url: request.url ?? URL(string: "about:blank")!, at: 0,
                             unread: request.disposition == .newBackgroundTab)
      tab.openerID = opener
      let content = makeContent(for: tab, url: nil, requestContext: request.context)
      if request.disposition != .newBackgroundTab { focus(space: space); select(nodeID: tab.id) }
      record(
        "open", content,
        ["disposition": request.disposition.rawValue, "url": request.url?.absoluteString ?? ""])
      return content
    }
  }

  /// Key events that reach the page view directly (not through
  /// NSApplication.sendEvent) still get the reserved app shortcuts.
  func webContent(_ webContent: OEWebContent, handleKeyEventBeforePage event: NSEvent) -> Bool {
    // An action popup's keys arrive here too (Chrome's ExtensionViewHost
    // pre-handles them through the hidden window, whose delegate is CEF's).
    // Cmd+W closes the popup, not the tab (extensions plan §3.7 F2).
    if let browser = focusedBrowser, webContent === browser.extensionPopup {
      record("popupKey", webContent, ["key": event.charactersIgnoringModifiers ?? "", "phase": "beforePage"])
      if Self.isCommandW(event) {
        browser.closeExtensionPopup()
        return true
      }
    }
    return controller?.handleKeyDown(event) == true
  }

  private static func isCommandW(_ event: NSEvent) -> Bool {
    event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "w"
  }

  func webContentDidRequestClose(_ webContent: OEWebContent) {
    if let page = auxiliaryPages.first(where: { $0.content === webContent }) {
      closeAuxiliary(page)
    } else if let id = tabID(for: webContent) {
      closeTab(id: id)
    }
  }

  func webContent(_ webContent: OEWebContent, runJavaScriptDialog dialog: OEJavaScriptDialog) -> Bool {
    record(
      "dialog", webContent,
      ["kind": dialog.kind.rawValue, "message": dialog.message, "default": dialog.defaultPromptText])
    switch dialogPolicy {
    case "accept":
      dialog.complete(accepted: true, text: promptText ?? dialog.defaultPromptText)
      return true
    case "dismiss":
      dialog.complete(accepted: false, text: nil)
      return true
    case "hold":
      pendingDialogs.append(dialog)
      return true
    default:
      guard let window = webContent.view.window else { return false }
      let alert = NSAlert()
      alert.messageText = webContent.url?.host() ?? "This page says"
      alert.informativeText = dialog.message
      alert.addButton(withTitle: "OK")
      if dialog.kind != .alert { alert.addButton(withTitle: "Cancel") }
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      if dialog.kind == .prompt {
        field.stringValue = dialog.defaultPromptText
        alert.accessoryView = field
      }
      alert.beginSheetModal(for: window) { response in
        dialog.complete(accepted: response == .alertFirstButtonReturn, text: field.stringValue)
      }
      return true
    }
  }

  func webContent(_ webContent: OEWebContent, decidePermissionRequest request: OEPermissionRequest) -> Bool {
    record("permission", webContent, ["origin": request.origin.absoluteString, "kinds": request.kinds.rawValue])
    switch permissionPolicy {
    case "grant":
      request.grant()
      return true
    case "deny":
      request.deny()
      return true
    default:
      guard let window = webContent.view.window else { return false }
      let alert = NSAlert()
      alert.messageText = "\(request.origin.host() ?? "This site") wants permission"
      alert.informativeText = "Requested: \(request.kinds.rawValue)"
      alert.addButton(withTitle: "Allow")
      alert.addButton(withTitle: "Block")
      alert.beginSheetModal(for: window) { response in
        response == .alertFirstButtonReturn ? request.grant() : request.deny()
      }
      return true
    }
  }

  func webContent(_ webContent: OEWebContent, showContextMenu menu: OEContextMenu) -> Bool {
    let ns = NSMenu()
    if let link = menu.linkURL {
      let opener = tabID(for: webContent)
      ns.addItem(
        ClosureMenuItem(title: "Open Link in New Tab") { [weak self] in
          self?.openNewTab(url: link, background: true, opener: opener)
        })
      ns.addItem(.separator())
    }
    for item in menu.items {
      if item.isSeparator {
        ns.addItem(.separator())
        continue
      }
      let command = item.commandIdentifier
      let mi = ClosureMenuItem(title: item.title) { menu.select(command: command) }
      mi.isEnabled = item.isEnabled
      ns.addItem(mi)
    }
    func commands(_ items: [OEContextMenuItem], in submenu: String = "") -> [[String: Any]] {
      items.flatMap { item -> [[String: Any]] in
        if item.isSeparator { return [] }
        if !item.submenu.isEmpty { return commands(item.submenu, in: item.title) }
        return [["id": item.commandIdentifier, "title": item.title, "enabled": item.isEnabled, "submenu": submenu]]
      }
    }
    record(
      "contextMenu", webContent,
      [
        "items": menu.items.map(\.title), "commands": commands(menu.items),
        "link": menu.linkURL?.absoluteString ?? "", "targets": menu.targets.rawValue,
      ])
    if contextMenuPolicy == "record" {
      menu.cancel()
      return true
    }
    if let policy = contextMenuPolicy, policy.hasPrefix("run:"), let command = Int(policy.dropFirst(4)) {
      // After the right click returns, as a picked menu item would.
      DispatchQueue.main.async { menu.select(command: command) }
      return true
    }
    let point = menu.location
    let view = webContent.view
    DispatchQueue.main.async {
      let picked = ns.popUp(positioning: nil, at: point, in: view)
      if !picked { menu.cancel() }
    }
    return true
  }

  func webContent(_ webContent: OEWebContent, didUpdateFindResult result: OEFindResult) {
    lastFindResult = result
    if result.isFinal {
      if findFieldCreated { findField.placeholderString = "\(result.activeMatchIndex)/\(result.matchCount)" }
    }
  }

  func webContent(_ webContent: OEWebContent, didRequestFullscreen fullscreen: Bool) {
    record("fullscreen", webContent, ["on": fullscreen])
    if fullscreenPolicy == "record" { return }
    controller?.isPageFullscreen = fullscreen
    if let window {
      if fullscreen, !window.styleMask.contains(.fullScreen) {
        enteredWindowFullscreenForPage = true; window.toggleFullScreen(nil)
      } else if !fullscreen, enteredWindowFullscreenForPage {
        enteredWindowFullscreenForPage = false
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
      }
    }
  }

  func webContent(_ webContent: OEWebContent, handleUnconsumedKeyEvent event: NSEvent) -> Bool {
    if webContent === focusedBrowser?.extensionPopup {
      record("popupKey", webContent, ["key": event.charactersIgnoringModifiers ?? "", "phase": "unconsumed"])
    }
    return controller?.handleKeyDown(event, unconsumed: true) == true
  }

  func webContent(_ webContent: OEWebContent, didFinishLoadWithStatus status: Int) {
    finishCommandBarNavigation(webContent)
    app.prepareCommandsAfterPaint(webContent)
    if tabID(for: webContent) != nil { LaunchTiming.shared.mark("firstLoadEnd") }
    record("load", webContent, ["status": status, "url": webContent.url?.absoluteString ?? ""])
  }

  func webContent(_ webContent: OEWebContent, didFailLoadWithError error: any Error) {
    finishCommandBarNavigation(webContent)
    record("loadError", webContent, ["error": error.localizedDescription])
  }

  func webContent(_ webContent: OEWebContent, didReceiveDevToolsEvent method: String, parameters: [String: Any]) {
    record("devtools", webContent, ["method": method, "params": parameters])
  }

  func webContent(_ webContent: OEWebContent, didLogConsoleMessage message: String, level: Int, source: String, line: Int) {
    record("console", webContent, ["message": message, "level": level, "source": source, "line": line])
  }
}

// MARK: - OEBrowserDelegate (extension actions and popups)

extension EngineWebContentHostFactory: OEBrowserDelegate {
  private func closePopupInCallbackForAutomation(_ browser: OEBrowser, popup: OEWebContent, phase: String) {
    #if OPEN_AUTOMATION
    guard let policy = popupCallbackClose, policy.phase == phase else { return }
    popupCallbackClose = nil
    if policy.toggle, let identifier = browser.extensionPopupExtensionIdentifier {
      _ = browser.executeExtensionAction(identifier)
    } else {
      browser.closeExtensionPopup()
      browser.closeExtensionPopup() // repeated requests must remain safe
    }
    record("popupCallbackClose", popup, ["phase": phase, "toggle": policy.toggle,
      "stillOpenInsideCallback": browser.extensionPopup === popup])
    #endif
  }

  func browserDidUpdateExtensionActions(_ browser: OEBrowser) {
    record("extensionActions", nil, ["browser": browser.identifier, "ready": browser.extensionActionsReady])
    if browser === focusedBrowser { reloadExtensionBar() }
  }

  func browser(_ browser: OEBrowser, didOpenExtensionPopup popup: OEWebContent, for action: OEExtensionAction) {
    popupPanel?.orderOut(nil)
    popup.delegate = self  // dialogs, console, context menu like any page
    let panel = makePanel(size: NSSize(width: 360, height: 480), title: action.title)
    popupPanel = panel
    host(popup, in: panel)
    if let button = extensionBar.arrangedSubviews.first(where: {
      $0.identifier?.rawValue == action.extensionIdentifier
    }), let win = window {
      let r = win.convertToScreen(button.convert(button.bounds, to: nil))
      panel.setFrameTopLeftPoint(NSPoint(x: r.minX, y: r.minY - 4))
    }
    present(panel)
    record("extensionPopup", popup, ["extension": action.extensionIdentifier, "open": true])
    closePopupInCallbackForAutomation(browser, popup: popup, phase: "open")
  }

  func browser(_ browser: OEBrowser, didResizeExtensionPopup popup: OEWebContent, to size: NSSize) {
    record("extensionPopup", popup, ["resize": [size.width, size.height]])
    closePopupInCallbackForAutomation(browser, popup: popup, phase: "resize")
    guard let panel = popupPanel else { return }
    let frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    var f = panel.frame
    f.origin.y += f.height - frame.height
    f.size = frame.size
    panel.setFrame(f, display: true)
  }

  /// Fork patch P2: the popup's first load stopped.
  func browser(_ browser: OEBrowser, extensionPopupIsReady popup: OEWebContent) {
    record("extensionPopup", popup, ["ready": true])
    closePopupInCallbackForAutomation(browser, popup: popup, phase: "ready")
  }

  func browser(_ browser: OEBrowser, didCloseExtensionPopup popup: OEWebContent) {
    popup.view.removeFromSuperview()
    popupPanel?.orderOut(nil)
    popupPanel = nil
    record("extensionPopup", popup, ["open": false])
  }

  /// A disabled action ran: Chrome shows its context menu (this shell only
  /// records it).
  func browser(_ browser: OEBrowser, requestsContextMenuForExtensionAction extensionIdentifier: String) {
    record("extensionMenuRequest", nil, ["extension": extensionIdentifier])
  }
}

// MARK: - OEBrowserDelegate (tab requests from Chromium, fork patch P1)

/// Tab changes that Chromium asks for on its own: chrome.tabs calls from
/// extensions, and pages extensions open (docs/engine-patches.md, P1). Each
/// arrives as a request; the handler changes OpenModel and then calls
/// mirror.sync(), the only owner of strip order. Handlers never insert, move,
/// pin, or activate in an OEBrowser themselves. Closes arrive as
/// webContentDidRequestClose(_:) and follow closeTab(id:).
extension EngineWebContentHostFactory {
  /// chrome.tabs.create, an extension's welcome or options page: a new Today
  /// tab at the top of the Space (Arc's placement for new tabs). pinned,
  /// index and openerTabId are not applied (documented P1 gap).
  @objc(browser:didOpenWebContent:active:)
  func browser(_ browser: OEBrowser, didOpen webContent: OEWebContent, active: Bool) {
    guard let space = space(forNewTabIn: browser), let profileID = profile(for: browser.context)?.id else {
      webContent.close()
      return
    }
    let url = webContent.url ?? URL(string: "about:blank")!
    let tab = model.newTab(in: space.id, url: url, at: 0, unread: !active)
    adopt(webContent, for: tab, profileID: profileID)
    record("open", webContent, ["disposition": "chromium", "active": active, "url": url.absoluteString])
    if active {
      if space.id != focusedSpace?.id { focus(space: space) }
      select(nodeID: tab.id)
    }
  }

  /// chrome.tabs.update({active: true}): select the tab, in its own Space.
  @objc(browser:requestsActivationOfWebContent:)
  func browser(_ browser: OEBrowser, requestsActivationOf webContent: OEWebContent) {
    defer { mirror.sync() }
    guard let id = requestTabID(for: webContent) else { return }
    if let space = space(containing: id), space.id != focusedSpace?.id { focus(space: space) }
    select(nodeID: id)
    record("tab-request", webContent, ["request": "activate"])
  }

  /// chrome.tabs.move: applied only when one position in the tab's own
  /// parent (section, folder, or Favorites) puts the tab between exactly the
  /// two strip tabs Chromium put it between. Otherwise nothing changes and
  /// the resync puts Chromium's strip back (folders, splits, other sections
  /// and Spaces cannot be reached by a strip index).
  @objc(browser:requestsMoveOfWebContent:toIndex:)
  func browser(_ browser: OEBrowser, requestsMoveOf webContent: OEWebContent, to index: UInt) {
    defer { mirror.sync() }
    guard let id = requestTabID(for: webContent), let profileID = profile(for: browser.context)?.id,
      let parent = model.parent(of: id), let node = model.node(id: id),
      let current = children(of: parent), let from = current.firstIndex(where: { $0.id == id })
    else {
      record("tab-request", webContent, ["request": "move", "refused": true])
      return
    }
    let siblings = current.filter { $0.id != id }
    let others = browser.webContents.filter { $0 !== webContent }
    let target = Int(index)
    let previous = target > 0 && target - 1 < others.count ? tabID(for: others[target - 1]) : nil
    let next = target < others.count ? tabID(for: others[target]) : nil
    let position = (0...siblings.count).first { candidate in
      var moved = siblings
      moved.insert(node, at: candidate)
      let order = stripOrder(profile: profileID, replacing: parent, with: moved)
      guard let i = order.firstIndex(of: id) else { return false }
      return (i > 0 ? order[i - 1] : nil) == previous && (i + 1 < order.count ? order[i + 1] : nil) == next
    }
    guard let position else {
      record("tab-request", webContent, ["request": "move", "refused": true])
      return
    }
    if position != from { model.moveNode(id: id, to: parent, at: position) }
    record("tab-request", webContent, ["request": "move", "position": position])
  }

  /// chrome.tabs.update({pinned}): pin or unpin the tab. Favorites are
  /// pinned tabs to Chromium and stay Favorites: both are no-ops for them.
  @objc(browser:requestsPinned:forWebContent:)
  func browser(_ browser: OEBrowser, requestsPinned pinned: Bool, for webContent: OEWebContent) {
    defer { mirror.sync() }
    guard let id = requestTabID(for: webContent), let parent = model.parent(of: id) else { return }
    if case .favorites = parent {
      record("tab-request", webContent, ["request": pinned ? "pin" : "unpin", "refused": true])
      return
    }
    guard model.isPinned(tabID: id) != pinned else { return }
    if pinned { model.pinTab(id: id) } else { model.unpinTab(id: id) }
    record("tab-request", webContent, ["request": pinned ? "pin" : "unpin"])
  }

  /// chrome.tabs.discard: a tab that is not on screen unloads in place, the
  /// way sleep unloads it (OpenSleep is not wired to this shell yet). It
  /// stays in the sidebar and loads again when shown.
  @objc(browser:requestsDiscardOfWebContent:)
  func browser(_ browser: OEBrowser, requestsDiscardOf webContent: OEWebContent) -> Bool {
    guard let id = requestTabID(for: webContent), !visibleTabs.contains(where: { $0.id == id }) else {
      record("tab-request", webContent, ["request": "discard", "refused": true])
      return false
    }
    record("tab-request", webContent, ["request": "discard"])
    // Not inside the engine's call.
    DispatchQueue.main.async { [weak self] in
      guard let self, let host = self.hosts[id], host.content === webContent, !host.closed else { return }
      self.controller?.container.closeHost(for: id)
      host.close()
      self.model.tab(id: id)?.live.sleepPhase = .sleeping
      self.mirror.sync()
    }
    return true
  }

  /// chrome.windows.remove on this window: refused in v1. The window and its
  /// tabs stay; the user closes windows.
  @objc(browserRequestsClose:)
  func browserRequestsClose(_ browser: OEBrowser) {
    NSLog("Open: refused chrome.windows.remove for window %ld", browser.chromeWindowIdentifier)
    record("window-request", nil, ["request": "close", "refused": true, "window": browser.chromeWindowIdentifier])
  }

  /// Makes `content`, a page the engine opened on its own, the page of `tab`.
  private func adopt(_ content: OEWebContent, for tab: Tab, profileID: ProfileID) {
    let host = EngineWebContentHost(tabID: tab.id, profileID: profileID, content: content, owner: self)
    hosts[tab.id] = host
    modelHostIDs.insert(tab.id)
    tab.live.sleepPhase = .live
    content.isMuted = tab.isMuted
    controller?.container.adopt(host, for: tab.id)
    if host.view.superview == nil { host.view.frame = contentContainer.bounds; contentContainer.addSubview(host.view) }
    mirror.sync()
  }

  /// The model tab of a request's page: sidebar tabs only (Peek hosts have
  /// transient ids).
  private func requestTabID(for content: OEWebContent) -> ItemID? {
    guard let id = tabID(for: content), model.tab(id: id) != nil, modelHostIDs.contains(id) else { return nil }
    return id
  }

  /// The focused Space if it belongs to the strip's profile, else that
  /// profile's first Space.
  private func space(forNewTabIn browser: OEBrowser) -> Space? {
    guard let profile = profile(for: browser.context)?.id else { return nil }
    if let space = focusedSpace, space.profileID == profile { return space }
    return model.spaces.first { $0.profileID == profile }
  }

  /// The Space whose sidebar shows `id` (favorites: the focused Space of
  /// that profile, else its first Space).
  private func space(containing id: ItemID) -> Space? {
    var current = id
    while let parent = model.parent(of: current) {
      switch parent {
      case .spacePinned(let space), .spaceToday(let space): return model.space(id: space)
      case .folder(let folder), .splitPane(let folder): current = folder
      case .favorites(let profile):
        if let space = focusedSpace, space.profileID == profile { return space }
        return model.spaces.first { $0.profileID == profile }
      }
    }
    return nil
  }

  private func children(of parent: NodeParent) -> [SidebarNode]? {
    switch parent {
    case .spacePinned(let space): return model.space(id: space)?.pinned
    case .spaceToday(let space): return model.space(id: space)?.today
    case .folder(let folder): return model.node(id: folder)?.folder?.children
    case .favorites(let profile): return model.profile(id: profile)?.favorites.map { .tab($0) }
    case .splitPane: return nil
    }
  }

  /// The tab ids of `profile`'s strip in mirror order (tabs(in:), tabs with
  /// a page only), with `parent`'s children replaced by `children`.
  private func stripOrder(profile: ProfileID, replacing parent: NodeParent, with children: [SidebarNode]) -> [ItemID] {
    let loaded = contents
    func ids(_ nodes: [SidebarNode], in container: NodeParent) -> [ItemID] {
      (container == parent ? children : nodes).flatMap { node -> [ItemID] in
        switch node {
        case .tab(let t): return loaded[t.id] == nil ? [] : [t.id]
        case .folder(let f): return ids(f.children, in: .folder(f.id))
        case .split(let s): return ids(s.panes.map { .tab($0) }, in: .splitPane(s.id))
        }
      }
    }
    let spaces = model.spaces.filter { $0.profileID == profile }
    var order = ids((model.profile(id: profile)?.favorites ?? []).map { .tab($0) }, in: .favorites(profile))
    for space in spaces { order += ids(space.pinned, in: .spacePinned(space.id)) }
    for space in spaces { order += ids(space.today, in: .spaceToday(space.id)) }
    return order
  }
}

// MARK: - OEBrowserContextDelegate (downloads)

extension EngineWebContentHostFactory: OEBrowserContextDelegate {
  func browserContext(
    _ context: OEBrowserContext, decideDestinationFor download: OEDownload, suggestedFilename: String,
    completion: @escaping @MainActor (URL?) -> Void
  ) {
    let dir = downloadDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    completion(dir.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename))
  }

  func browserContext(_ context: OEBrowserContext, downloadDidUpdate download: OEDownload) {
    app.settingsPresenter.noteDownload(download, context: context)
    record(
      "download", download.webContent,
      [
        "id": download.identifier, "state": download.state.rawValue, "received": download.receivedBytes,
        "path": download.destinationURL?.path ?? "",
      ])
  }
}

/// NSMenuItem that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError() }

  @objc private func run() { handler() }
}

// AppKit reaches browser Find only after the text/page responder declines it.
// Undo/Redo use AppKit itself and the window delegate's selected UndoManager.
extension EngineWebContentHostFactory: NSMenuItemValidation {
  @objc func performFindPanelAction(_ sender: Any?) {
    switch (sender as? NSMenuItem)?.tag ?? 1 {
    case 1: showFind(nil)
    case 2: findNext(nil)
    case 3: findPrevious()
    case 7:
      guard !isClosing, app.engineReady, !app.terminationRequested, let page = selectedContent else { return }
      findSelectionTask?.cancel()
      findSelectionTask = Task { @MainActor [weak self, weak page] in
        guard let self, let page, !Task.isCancelled, !self.isClosing,
              self.app.engineReady, !self.app.terminationRequested else { return }
        self.app.noteAsyncEngineCall("findSelection")
        let value = try? await page.evaluateJavaScript("window.getSelection().toString()") as? String
        guard !Task.isCancelled, !self.isClosing, self.app.engineReady, !self.app.terminationRequested else { return }
        self.findSelectionTask = nil
        if let value, !value.isEmpty { self.findField.stringValue = value; self.findNext(nil) }
      }
    default: break
    }
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(performFindPanelAction(_:)): return selectedContent != nil
    default: return true
    }
  }
}
