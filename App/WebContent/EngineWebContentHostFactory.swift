import AppKit
import OpenEngine
import OpenFeatures
import OpenModel
import OpenStore
import OpenSidebar

// App has no window controller of its own.
typealias BrowserWindowController = OpenFeatures.BrowserWindowController

@MainActor
final class AuxiliaryPage {
  let content: OEWebContent
  let panel: NSPanel
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
  private var newTabMode = false
  private var enteredWindowFullscreenForPage = false
  private(set) var auxiliaryPages: [AuxiliaryPage] = []
  private var popupPanel: NSPanel?
  private lazy var addressField = makeAddressField()
  private lazy var extensionBar = makeExtensionBar()
  private lazy var findField = makeFindField()
  private var extensionBarCreated = false
  private var findFieldCreated = false
  private var addressFieldCreated = false

  var dialogPolicy: String?
  var permissionPolicy: String?
  var promptText: String?
  var contextMenuPolicy: String?
  var fullscreenPolicy: String?
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
    controller.onLayout = { [weak self] in self?.layoutViews() }
    controller.onFocus = { [weak self] in guard let self else { return }; self.app.didFocusWindow(self.windowState.id) }
    controller.nextResponder = self; nextResponder = NSApp
    controller.onSidebarIntent = { [weak self] intent in guard let self else { return false }; return self.performSidebar(intent) }
    controller.onStateChange = { [weak self] in
      guard let self else { return }
      if self.app.engineReady { for tab in self.visibleTabs { tab.live.sleepPhase = .live }; self.controller?.container.refreshPlaceholders() }
      self.mirror.sync(); self.app.scheduleSave()
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
    addressField.stringValue = input; addressEntered(addressField)
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
  func tabs(in profileID: ProfileID) -> [Tab] {
    (model.profile(id: profileID)?.favorites ?? []) + model.spaces.filter { $0.profileID == profileID }.flatMap { flattened($0.pinned) + flattened($0.today) }
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
    return OEEngine.shared.context(identifier: profile.dataDirectoryName, directory: app.directories.engineDirectory(dataDirectoryName: profile.dataDirectoryName))
  }
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
    config.runtimeStyle = app.options.defaultStyle; config.showsChromeToolbar = app.options.chromeToolbar
    if model.tab(id: tabID)?.url.scheme == "chrome" { config.runtimeStyle = .chrome }
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
    if hosts[host.tabID] === host { hosts[host.tabID] = nil }
    modelHostIDs.remove(host.tabID)
    mirror.sync()
  }
  func adoptHost(_ host: any WebContentHost, as tabID: ItemID) -> Bool {
    guard let host = host as? EngineWebContentHost, host.owner === self, !host.closed,
          profile(for: tabID)?.id == host.profileID else { return false }
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
    layoutViews()
  }
  func select(nodeID: ItemID?, focus: Bool = true) {
    guard let space = focusedSpace else { return }
    withoutUndo { model.selectNode(windowID: windowState.id, spaceID: space.id, nodeID: nodeID) }
    controller?.dismissSidebarReveal(); newTabMode = false
    showSelection(focus: focus); app.scheduleSave()
  }
  @discardableResult
  func openNewTab(url: URL, background: Bool, opener: ItemID? = nil) -> Tab? {
    guard let space = focusedSpace else { return nil }
    let tab = model.newTab(in: space.id, url: url, at: 0); tab.openerID = opener
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
      guard let tab = model.tab(id: id) else { return false }; NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(markdown ? "[\(tab.displayTitle)](\(tab.url.absoluteString))" : tab.url.absoluteString, forType: .string); return true
    case .showSiteControls, .showLibrary, .manageSpaces, .changeSpaceIcon, .editSpaceTheme, .newProfile, .shareSpace,
         .exportSpaceIntoFolder, .editPinnedURL, .share, .changeIcon, .customizePage, .duplicate,
         .copyAllLinks, .turnFolderIntoSpace, .moveToNewSpace:
      return false // Explicitly deferred UI entries; see docs/app-shell.md Step B.
    default: return nil
    }
  }

  private func closeTab(id: ItemID) {
    guard model.tab(id: id) != nil else { return }
    let order = orderedTabs.map(\.id), index = order.firstIndex(of: id) ?? 0
    let wasSelected = selectedTab?.id == id
    if model.isPinned(tabID: id) || focusedProfile?.favorites.contains(where: { $0.id == id }) == true {
      controller?.container.closeHost(for: id); hosts[id]?.close()
    } else { model.closeTab(id: id) }
    if wasSelected {
      let remaining = orderedTabs.map(\.id).filter { $0 != id }
      select(nodeID: remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)])
    } else { controller?.refresh(); mirror.sync(); app.scheduleSave() }
  }
  func closeAll() {
    controller?.container.closeAll(); for host in Array(hosts.values) { host.close() }
    for page in auxiliaryPages { page.content.close(); page.panel.close() }; auxiliaryPages.removeAll()
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
  private func makeAddressField() -> NSTextField {
    let field = NSTextField(); field.placeholderString = "Search or enter URL"; field.delegate = self
    field.target = self; field.action = #selector(addressEntered(_:)); field.isHidden = true
    controller?.contentView.addSubview(field); addressFieldCreated = true; return field
  }
  private func makeFindField() -> NSSearchField {
    let field = NSSearchField(); field.placeholderString = "Find in page"; field.target = self
    field.action = #selector(findFieldChanged(_:)); field.isHidden = true
    controller?.contentView.addSubview(field); findFieldCreated = true; return field
  }
  private func makeExtensionBar() -> NSStackView {
    let bar = NSStackView(); bar.orientation = .horizontal; bar.spacing = 4
    controller?.contentView.addSubview(bar); extensionBarCreated = true; return bar
  }
  private func layoutViews() {
    guard let controller else { return }; let panel = controller.container.frame
    if addressFieldCreated, !addressField.isHidden { addressField.frame = CGRect(x: 8, y: 46, width: max(212, controller.context.sidebarWidth - 16), height: 36) }
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
      let image =
        action.icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
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
  @objc func newTab(_ sender: Any?) {
    // Arc opens the command bar; the minimal shell uses the address field.
    newTabMode = true
    focusAddressBar(nil)
    addressField.stringValue = ""
  }

  @objc func focusAddressBar(_ sender: Any?) {
    if windowState.sidebarMode == .hidden { controller?.toggleSidebar() }; controller?.dismissSidebarReveal()
    addressField.frame = CGRect(x: 8, y: 46, width: max(212, windowState.sidebarWidth - 16), height: 36)
    addressField.isHidden = false
    controller?.context.isNewTabCommandBarOpen = newTabMode
    window?.makeFirstResponder(addressField)
    addressField.currentEditor()?.selectAll(nil)
  }

  @objc func closeTab(_ sender: Any?) {
    if let panel = NSApp.keyWindow as? NSPanel, let page = auxiliaryPages.first(where: { $0.panel === panel }) { closeAuxiliary(page); return }
    if let tab = selectedTab { closeTab(id: tab.id) }
  }

  @objc func restoreLastClosedTab(_ sender: Any?) {
    let store = app.archiveSink.store(for: focusedProfile?.id)
    Task { @MainActor in
      guard let recent = await store.recent(limit: 1).first,
        let record = await store.restore(id: recent.id)
      else { return }
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

  private func cycleTab(by delta: Int) {
    let ids = orderedTabs.map(\.id)
    guard !ids.isEmpty else { return }
    let current = selectedTab.flatMap { ids.firstIndex(of: $0.id) } ?? -delta
    select(nodeID: ids[(current + delta + ids.count) % ids.count])
  }

  @objc func nextSpace(_ sender: Any?) { cycleSpace(by: 1) }
  @objc func previousSpace(_ sender: Any?) { cycleSpace(by: -1) }

  private func cycleSpace(by delta: Int) {
    guard let i = model.spaces.firstIndex(where: { $0.id == focusedSpace?.id }), model.spaces.count > 1 else {
      return
    }
    focus(space: model.spaces[(i + delta + model.spaces.count) % model.spaces.count])
  }

  @objc func showFind(_ sender: Any?) {
    _ = findField; layoutViews(); findField.isHidden = false
    window?.makeFirstResponder(findField)
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

  @objc private func addressEntered(_ sender: NSTextField) {
    let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, let url = Self.url(forInput: text, engine: focusedProfile?.settings.searchEngineID) else {
      return
    }
    addressField.isHidden = true
    controller?.context.isNewTabCommandBarOpen = false
    if newTabMode || selectedTab == nil {
      newTabMode = false
      openNewTab(url: url, background: false)
    } else if let tab = selectedTab {
      guard app.engineReady else {
        tab.url = url; queuedNavigations[tab.id] = url; app.scheduleSave(); return
      }
      ensureContent(for: tab)?.load(url)
      tab.url = url
      selectedContent?.focusPage()
    }
  }

  /// URL for address-field input: a URL, a host, or a search.
  static func url(forInput text: String, engine: String?) -> URL? {
    if text.contains("://") || text.hasPrefix("about:") || text.hasPrefix("chrome:") {
      return URL(string: text)
    }
    if text.contains(".") && !text.contains(" ") {
      return URL(string: "https://\(text)")
    }
    var c =
      engine == "google"
      ? URLComponents(string: "https://www.google.com/search")! : URLComponents(string: "https://duckduckgo.com/")!
    c.queryItems = [URLQueryItem(name: "q", value: text)]
    return c.url
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
    page.content.close()
    page.panel.orderOut(nil)
    auxiliaryPages.removeAll { $0 === page }
  }
}

extension EngineWebContentHostFactory: NSTextFieldDelegate {
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if control === addressField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      addressField.isHidden = true
      controller?.context.isNewTabCommandBarOpen = false
      newTabMode = false
      updateChrome()
      selectedContent?.focusPage()
      return true
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
      auxiliaryPages.append(AuxiliaryPage(content: popup, panel: panel))
      record("open", popup, ["disposition": "popup", "url": request.url?.absoluteString ?? ""])
      return popup
    case .newWindow:
      let sourceSpace = tabID(for: webContent).flatMap { space(for: $0) } ?? hosts.values.first { $0.content === webContent }?.spaceID.flatMap { model.space(id: $0) }
      guard let controller = app.makeWindow(focusedSpaceID: sourceSpace?.id), let target = app.hostFactories[controller.windowID] else { return nil }
      return target.adoptUnownedRequest(request)
    case .currentTab, .saveToDisk:
      return nil
    default:
      let opener = tabID(for: webContent)
      let source = opener.flatMap { space(for: $0) } ?? hosts.values.first { $0.content === webContent }?.spaceID.flatMap { model.space(id: $0) }
      guard let space = source ?? focusedSpace, space.profileID == profile(for: request.context)?.id else { return nil }
      let tab = model.newTab(in: space.id, url: request.url ?? URL(string: "about:blank")!, at: 0)
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
    MainMenu.performReservedShortcut(event)
  }

  func webContentDidRequestClose(_ webContent: OEWebContent) {
    if let page = auxiliaryPages.first(where: { $0.content === webContent }) {
      closeAuxiliary(page)
    } else if let id = tabID(for: webContent) {
      model.closeTab(id: id)
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
    record(
      "contextMenu", webContent,
      ["items": menu.items.map(\.title), "link": menu.linkURL?.absoluteString ?? "", "targets": menu.targets.rawValue])
    if contextMenuPolicy == "record" {
      menu.cancel()
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

  func webContent(_ webContent: OEWebContent, didFinishLoadWithStatus status: Int) {
    if tabID(for: webContent) != nil { LaunchTiming.shared.mark("firstLoadEnd") }
    record("load", webContent, ["status": status, "url": webContent.url?.absoluteString ?? ""])
  }

  func webContent(_ webContent: OEWebContent, didFailLoadWithError error: any Error) {
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
  func browserDidUpdateExtensionActions(_ browser: OEBrowser) {
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
  }

  func browser(_ browser: OEBrowser, didResizeExtensionPopup popup: OEWebContent, to size: NSSize) {
    guard let panel = popupPanel else { return }
    let frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    var f = panel.frame
    f.origin.y += f.height - frame.height
    f.size = frame.size
    panel.setFrame(f, display: true)
  }

  func browser(_ browser: OEBrowser, didCloseExtensionPopup popup: OEWebContent) {
    popup.view.removeFromSuperview()
    popupPanel?.orderOut(nil)
    popupPanel = nil
    record("extensionPopup", popup, ["open": false])
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
