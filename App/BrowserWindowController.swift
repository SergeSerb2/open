import AppKit
import OpenEngine
import OpenModel
import OpenStore

/// A page that is not a sidebar tab: a sized window.open() popup (Arc opens
/// these in a small window).
@MainActor
final class AuxiliaryPage {
  let content: OEWebContent
  let panel: NSPanel
  init(content: OEWebContent, panel: NSPanel) {
    self.content = content
    self.panel = panel
  }
}

/// The minimal M1 shell window: a plain list of the focused Space's tabs on
/// the left (favorites, pinned, today), bound to OpenModel, and the selected
/// tab's page on the right. No visual design on purpose; OpenSidebar replaces
/// the left side.
///
/// Engine wiring: one OEWebContent per loaded tab, created on first
/// selection (or when a page opens it), and one OEBrowser per profile that
/// mirrors the sidebar order for Chromium (docs/engine-api.md).
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
  @MainActor
  enum Row {
    case header(String)
    case tab(Tab, depth: Int)
    case folder(Folder, depth: Int)
    case split(Split, depth: Int)

    var nodeID: ItemID? {
      switch self {
      case .header: return nil
      case .tab(let t, _): return t.id
      case .folder(let f, _): return f.id
      case .split(let s, _): return s.id
      }
    }
  }

  unowned let app: AppDelegate
  let windowState: BrowserWindowState
  var model: BrowserModel { app.model }

  private(set) var rows: [Row] = []
  private(set) var contents: [ItemID: OEWebContent] = [:]
  private var tabIDByContent: [ObjectIdentifier: ItemID] = [:]
  private var browsers: [ProfileID: OEBrowser] = [:]
  private(set) var auxiliaryPages: [AuxiliaryPage] = []
  private var popupPanel: NSPanel?
  private var observerID: UUID?
  private var newTabMode = false
  private var sidebarVisible = true
  private var isPageFullscreen = false

  // Automation hooks (docs/automation.md).
  var dialogPolicy: String?  // "accept" | "dismiss" | "hold" | nil (show UI)
  var permissionPolicy: String?  // "grant" | "deny" | nil (show UI)
  var promptText: String?
  var contextMenuPolicy: String?  // "record": record items and cancel
  var fullscreenPolicy: String?  // "record": do not resize the window
  var downloadDirectory: URL?
  private(set) var events: [[String: Any]] = []
  private(set) var lastFindResult: OEFindResult?
  private(set) var pendingDialogs: [OEJavaScriptDialog] = []

  // Views
  private let sidebar: NSVisualEffectView = {
    let v = NSVisualEffectView()
    v.material = .sidebar
    v.blendingMode = .behindWindow
    v.state = .followsWindowActiveState
    return v
  }()
  private let spacePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let addressField = NSTextField()
  private let extensionBar = NSStackView()
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  let contentContainer = NSView()
  private let findField = NSSearchField()
  private let statusLabel = NSTextField(labelWithString: "")

  static let sidebarWidth: CGFloat = 260

  init(app: AppDelegate, windowState: BrowserWindowState) {
    self.app = app
    self.windowState = windowState
    let frame = NSRect(
      x: windowState.frameX, y: windowState.frameY,
      width: max(windowState.frameWidth, 640), height: max(windowState.frameHeight, 480))
    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Open"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    super.init(window: window)
    window.delegate = self
    buildUI()
    observerID = model.addObserver { [weak self] change in self?.treeChanged(change) }
    rebuildSpaceMenu()
    rebuildRows()
    reloadExtensionBar()
    showSelection(focus: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // MARK: Model helpers

  var focusedSpace: Space? { model.space(id: windowState.focusedSpaceID) ?? model.spaces.first }
  var focusedProfile: Profile? { focusedSpace.flatMap { model.profile(id: $0.profileID) } }

  var selectedNodeID: ItemID? {
    guard let space = focusedSpace else { return nil }
    return windowState.selectedNodeBySpace[space.id]
  }

  /// The tabs the content area shows: one tab, or every pane of a split.
  var visibleTabs: [Tab] {
    guard let id = selectedNodeID, let node = model.node(id: id) else { return [] }
    switch node {
    case .tab(let tab):
      if case .splitPane(let splitID)? = model.parent(of: id), let split = model.node(id: splitID)?.split {
        return split.panes
      }
      return [tab]
    case .split(let split): return split.panes
    case .folder: return []
    }
  }

  /// The tab that has focus: the selected tab, or the focused split pane.
  var selectedTab: Tab? {
    guard let id = selectedNodeID, let node = model.node(id: id) else { return nil }
    if let tab = node.tab { return tab }
    if let split = node.split {
      return split.panes.first { $0.id == split.focusedPaneID } ?? split.panes.first
    }
    return nil
  }

  var selectedContent: OEWebContent? { selectedTab.flatMap { contents[$0.id] } }

  /// Every tab of the focused Space in sidebar order (favorites, pinned,
  /// today), splits and folders flattened.
  var orderedTabs: [Tab] {
    var out: [Tab] = []
    func walk(_ nodes: [SidebarNode]) {
      for node in nodes {
        switch node {
        case .tab(let t): out.append(t)
        case .folder(let f): walk(f.children)
        case .split(let s): out.append(contentsOf: s.panes)
        }
      }
    }
    if let profile = focusedProfile { out.append(contentsOf: profile.favorites) }
    if let space = focusedSpace {
      walk(space.pinned)
      walk(space.today)
    }
    return out
  }

  /// The engine context of an Open profile: the global context for the
  /// default profile, else Profiles/<dir>/Engine (docs/plans/profiles.md §6.2).
  /// Created on first use, so profiles nobody shows cost nothing.
  func context(for profileID: ProfileID) -> OEBrowserContext {
    guard let profile = model.profile(id: profileID) ?? model.defaultProfile,
      profile.id != model.defaultProfile?.id
    else { return OEEngine.shared.defaultContext }
    let name = profile.dataDirectoryName
    return OEEngine.shared.context(
      identifier: name, directory: app.directories.engineDirectory(dataDirectoryName: name))
  }

  func engineBrowser(for profileID: ProfileID) -> OEBrowser {
    if let b = browsers[profileID] { return b }
    let browser = OEBrowser(context: context(for: profileID))
    browser.delegate = self
    browser.window = window
    browser.context.delegate = self
    browsers[profileID] = browser
    return browser
  }

  var focusedBrowser: OEBrowser? { focusedSpace.map { engineBrowser(for: $0.profileID) } }

  func tabID(for content: OEWebContent) -> ItemID? { tabIDByContent[ObjectIdentifier(content)] }

  private func withoutUndo(_ body: () -> Void) {
    app.undoManager.disableUndoRegistration()
    body()
    app.undoManager.enableUndoRegistration()
  }

  // MARK: UI

  private func buildUI() {
    guard let root = window?.contentView else { return }
    root.wantsLayer = true

    root.addSubview(sidebar)
    contentContainer.wantsLayer = true
    contentContainer.layer?.cornerRadius = 6
    contentContainer.layer?.masksToBounds = true
    root.addSubview(contentContainer)

    spacePopup.target = self
    spacePopup.action = #selector(spaceChosen(_:))
    spacePopup.controlSize = .small
    sidebar.addSubview(spacePopup)

    addressField.placeholderString = "Search or enter URL"
    addressField.delegate = self
    addressField.target = self
    addressField.action = #selector(addressEntered(_:))
    addressField.lineBreakMode = .byTruncatingTail
    addressField.cell?.usesSingleLineMode = true
    sidebar.addSubview(addressField)

    extensionBar.orientation = .horizontal
    extensionBar.spacing = 4
    extensionBar.alignment = .centerY
    sidebar.addSubview(extensionBar)

    let column = NSTableColumn(identifier: .init("tab"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.rowHeight = 30
    tableView.style = .sourceList
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(tableClicked(_:))
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    sidebar.addSubview(scrollView)

    statusLabel.font = .systemFont(ofSize: 10)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingMiddle
    sidebar.addSubview(statusLabel)

    findField.placeholderString = "Find in page"
    findField.target = self
    findField.action = #selector(findFieldChanged(_:))
    findField.isHidden = true
    root.addSubview(findField)

    layoutViews()
  }

  func windowDidResize(_ notification: Notification) { layoutViews() }

  private func layoutViews() {
    guard let root = window?.contentView else { return }
    let b = root.bounds
    let sw = sidebarVisible && !isPageFullscreen ? Self.sidebarWidth : 0
    sidebar.isHidden = sw == 0
    sidebar.frame = NSRect(x: 0, y: 0, width: sw, height: b.height)
    let inset: CGFloat = isPageFullscreen ? 0 : 8
    contentContainer.frame = NSRect(
      x: sw + inset, y: inset, width: b.width - sw - inset * 2, height: b.height - inset * 2
    ).integral
    let top = b.height - 34
    spacePopup.frame = NSRect(x: 76, y: top, width: sw - 84, height: 24)
    addressField.frame = NSRect(x: 8, y: top - 30, width: sw - 16, height: 24)
    extensionBar.frame = NSRect(x: 8, y: top - 60, width: sw - 16, height: 26)
    scrollView.frame = NSRect(x: 0, y: 24, width: sw, height: top - 66 - 24)
    statusLabel.frame = NSRect(x: 8, y: 4, width: sw - 16, height: 16)
    findField.frame = NSRect(x: b.width - 268, y: b.height - 32, width: 260, height: 24)
    layoutContent()
  }

  /// Places the visible pages; hides the rest (hidden pages are throttled).
  private func layoutContent() {
    let visible = visibleTabs
    let visibleIDs = Set(visible.map(\.id))
    for (id, content) in contents where !visibleIDs.contains(id) {
      content.view.isHidden = true
    }
    let b = contentContainer.bounds
    let gap: CGFloat = 6
    var fractions: [Double] = visible.map { _ in 1.0 / Double(max(visible.count, 1)) }
    if visible.count > 1, let id = selectedNodeID,
      let split = model.node(id: id)?.split ?? model.parent(of: id).flatMap({ p -> Split? in
        if case .splitPane(let sid) = p { return model.node(id: sid)?.split }
        return nil
      }), split.fractions.count == visible.count
    {
      fractions = split.fractions
    }
    var x: CGFloat = 0
    let usable = b.width - gap * CGFloat(max(visible.count - 1, 0))
    for (i, tab) in visible.enumerated() {
      let content = ensureContent(for: tab)
      let w = i == visible.count - 1 ? b.width - x : (usable * fractions[i]).rounded()
      content.view.frame = NSRect(x: x, y: 0, width: w, height: b.height)
      content.view.isHidden = false
      x += w + gap
    }
  }

  // MARK: Rows

  private func rebuildRows() {
    var out: [Row] = []
    func walk(_ nodes: [SidebarNode], depth: Int) {
      for node in nodes {
        switch node {
        case .tab(let t): out.append(.tab(t, depth: depth))
        case .folder(let f):
          out.append(.folder(f, depth: depth))
          if f.isExpanded { walk(f.children, depth: depth + 1) }
        case .split(let s):
          out.append(.split(s, depth: depth))
          for pane in s.panes { out.append(.tab(pane, depth: depth + 1)) }
        }
      }
    }
    if let profile = focusedProfile, !profile.favorites.isEmpty {
      out.append(.header("Favorites"))
      for t in profile.favorites { out.append(.tab(t, depth: 0)) }
    }
    if let space = focusedSpace {
      out.append(.header("Pinned"))
      walk(space.pinned, depth: 0)
      out.append(.header("Today"))
      walk(space.today, depth: 0)
    }
    rows = out
    tableView.reloadData()
    syncRowSelection()
  }

  private func syncRowSelection() {
    if let id = selectedNodeID, let row = rows.firstIndex(where: { $0.nodeID == id }) {
      tableView.selectRowIndexes([row], byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }
  }

  private func reloadRow(for tabID: ItemID) {
    let indexes = IndexSet(rows.indices.filter { rows[$0].nodeID == tabID })
    if !indexes.isEmpty { tableView.reloadData(forRowIndexes: indexes, columnIndexes: [0]) }
  }

  private func rebuildSpaceMenu() {
    spacePopup.removeAllItems()
    for space in model.spaces {
      let title = space.title ?? ""
      spacePopup.addItem(withTitle: title.isEmpty ? "Space" : title)
      spacePopup.lastItem?.representedObject = space.id
    }
    if let i = model.spaces.firstIndex(where: { $0.id == focusedSpace?.id }) {
      spacePopup.selectItem(at: i)
    }
  }

  private func treeChanged(_ change: TreeChange) {
    // Close pages of tabs that left the model (archived, auto-archived).
    for (id, content) in contents where model.tab(id: id) == nil {
      dropContent(id: id, content: content)
    }
    rebuildRows()
    syncTabStrips()
    if let id = selectedNodeID, model.node(id: id) == nil, let space = focusedSpace {
      withoutUndo { model.selectNode(windowID: windowState.id, spaceID: space.id, nodeID: nil) }
    }
    showSelection(focus: false)
  }

  // MARK: Pages

  /// The page of `tab`, created (and loading) on first use.
  @discardableResult
  func ensureContent(for tab: Tab) -> OEWebContent {
    if let c = contents[tab.id] { return c }
    let content = makeContent(for: tab, url: tab.url)
    return content
  }

  private func makeContent(for tab: Tab, url: URL?) -> OEWebContent {
    let profileID = focusedSpace?.profileID ?? model.profiles.first?.id ?? ProfileID()
    let config = OEWebContentConfiguration(context: context(for: profileID))
    config.runtimeStyle = app.options.defaultStyle
    config.showsChromeToolbar = app.options.chromeToolbar
    let content = OEWebContent(configuration: config, url: url)
    content.delegate = self
    content.isMuted = tab.isMuted
    content.view.isHidden = true
    content.view.frame = contentContainer.bounds
    contentContainer.addSubview(content.view)
    contents[tab.id] = content
    tabIDByContent[ObjectIdentifier(content)] = tab.id
    syncTabStrips()
    return content
  }

  private func dropContent(id: ItemID, content: OEWebContent) {
    content.close()
    content.view.removeFromSuperview()
    contents[id] = nil
    tabIDByContent[ObjectIdentifier(content)] = nil
    if let tab = model.tab(id: id) { resetLiveState(tab) }
  }

  private func resetLiveState(_ tab: Tab) {
    tab.live.isLoading = false
    tab.live.progress = 0
    tab.live.isAudible = false
    tab.live.isCrashed = false
  }

  /// Keeps every OEBrowser's tab strip in sidebar order (the input of fork
  /// patch P1).
  private func syncTabStrips() {
    guard let space = focusedSpace else { return }
    let browser = engineBrowser(for: space.profileID)
    let favorites = Set(focusedProfile?.favorites.map(\.id) ?? [])
    var index = 0
    for tab in orderedTabs {
      guard let content = contents[tab.id] else { continue }
      browser.insert(content, at: UInt(index))
      browser.setPinned(favorites.contains(tab.id) || model.isPinned(tabID: tab.id), for: content)
      index += 1
    }
    browser.activeWebContent = selectedContent
  }

  /// Shows the selected node's page(s) and updates the chrome.
  func showSelection(focus: Bool = true) {
    layoutContent()
    syncRowSelection()
    focusedBrowser?.activeWebContent = selectedContent
    updateChrome()
    if focus { selectedContent?.focusPage() }
  }

  func select(nodeID: ItemID?, focus: Bool = true) {
    guard let space = focusedSpace else { return }
    withoutUndo { model.selectNode(windowID: windowState.id, spaceID: space.id, nodeID: nodeID) }
    newTabMode = false
    showSelection(focus: focus)
    app.scheduleSave()
  }

  private func updateChrome() {
    let tab = selectedTab
    if addressField.currentEditor() == nil {
      addressField.stringValue = newTabMode ? "" : (selectedContent?.url?.absoluteString ?? tab?.url.absoluteString ?? "")
    }
    window?.title = tab?.displayTitle ?? "Open"
    statusLabel.stringValue = selectedContent?.statusText ?? ""
  }

  /// Opens `url` as a new Today tab at the top (Arc's placement).
  @discardableResult
  func openNewTab(url: URL, background: Bool, opener: ItemID? = nil) -> Tab? {
    guard let space = focusedSpace else { return nil }
    let tab = model.newTab(in: space.id, url: url, at: 0)
    tab.openerID = opener
    if background {
      ensureContent(for: tab)
      syncTabStrips()
    } else {
      select(nodeID: tab.id)
    }
    return tab
  }

  func adoptUnownedRequest(_ request: OEOpenRequest) -> OEWebContent? {
    guard let space = focusedSpace else { return nil }
    let tab = model.newTab(in: space.id, url: request.url ?? URL(string: "about:blank")!, at: 0)
    let content = makeContent(for: tab, url: nil)
    select(nodeID: tab.id)
    return content
  }

  // MARK: Extensions

  private func reloadExtensionBar() {
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

  // MARK: Window

  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { app.undoManager }

  func saveWindowState() {
    guard let frame = window?.frame else { return }
    windowState.frameX = frame.origin.x
    windowState.frameY = frame.origin.y
    windowState.frameWidth = frame.width
    windowState.frameHeight = frame.height
    windowState.sidebarMode = sidebarVisible ? .anchored : .hidden
  }

  func windowDidMove(_ notification: Notification) { saveWindowState() }
  func windowDidEndLiveResize(_ notification: Notification) { saveWindowState() }

  // MARK: Automation event log

  func record(_ type: String, _ content: OEWebContent?, _ info: [String: Any]) {
    var event = info
    event["type"] = type
    event["tab"] = content.flatMap { tabID(for: $0)?.rawValue.uuidString } ?? ""
    event["content"] = content?.identifier ?? 0
    event["time"] = Date().timeIntervalSince1970
    events.append(event)
    if events.count > 2000 { events.removeFirst(events.count - 2000) }
  }

  func drainEvents() -> [[String: Any]] {
    defer { events.removeAll() }
    return events
  }

  func completePendingDialog(accept: Bool, text: String?) -> Bool {
    guard !pendingDialogs.isEmpty else { return false }
    pendingDialogs.removeFirst().complete(accepted: accept, text: text)
    return true
  }

  func content(forAutomationHandle handle: Any?) -> OEWebContent? {
    switch handle {
    case nil: return selectedContent
    case let s as String where s == "popup": return focusedBrowser?.extensionPopup
    case let s as String:
      if let id = UUID(uuidString: s).map({ ItemID(rawValue: $0) }), let tab = model.tab(id: id) {
        return ensureContent(for: tab)
      }
      return nil
    case let n as Int: return OEEngine.shared.webContent(identifier: n)
    default: return nil
    }
  }
}

// MARK: - Menu actions

extension BrowserWindowController {
  @objc func newTab(_ sender: Any?) {
    // Arc opens the command bar; the minimal shell uses the address field.
    newTabMode = true
    focusAddressBar(nil)
    addressField.stringValue = ""
  }

  @objc func focusAddressBar(_ sender: Any?) {
    if !sidebarVisible { toggleSidebar(nil) }
    window?.makeFirstResponder(addressField)
    addressField.currentEditor()?.selectAll(nil)
  }

  @objc func closeTab(_ sender: Any?) {
    if let panel = NSApp.keyWindow as? NSPanel, let page = auxiliaryPages.first(where: { $0.panel === panel }) {
      closeAuxiliary(page)
      return
    }
    guard let tab = selectedTab else { return }
    let order = rows.compactMap(\.nodeID)
    let position = order.firstIndex(of: selectedNodeID ?? tab.id) ?? 0
    let isFavorite = focusedProfile?.favorites.contains { $0.id == tab.id } ?? false
    if isFavorite || model.isPinned(tabID: tab.id) {
      // Pinned tabs and favorites stay in the sidebar; closing unloads them.
      if let content = contents[tab.id] { dropContent(id: tab.id, content: content) }
    } else {
      model.closeTab(id: tab.id)  // archives; treeChanged closes the page
    }
    let remaining = rows.compactMap(\.nodeID).filter { model.tab(id: $0) != nil && $0 != tab.id }
    let next = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)]
    select(nodeID: next)
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
    guard let tab = selectedTab else { return }
    if case .splitPane(let splitID)? = model.parent(of: tab.id) {
      model.unsplit(splitID: splitID)
      select(nodeID: tab.id)
      return
    }
    let others = orderedTabs.filter { $0.id != tab.id && !model.isPinned(tabID: $0.id) }
    guard let other = others.first, let split = model.makeSplit(tabIDs: [tab.id, other.id]) else { return }
    select(nodeID: split.id)
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

  @objc func openExtensionsPage(_ sender: Any?) {
    // chrome://extensions needs a Chrome-style page in stock CEF.
    guard let space = focusedSpace else { return }
    let tab = model.newTab(in: space.id, url: OEExtensionManager.managementPageURL, at: 0)
    let config = OEWebContentConfiguration(context: context(for: space.profileID))
    config.runtimeStyle = .chrome
    let content = OEWebContent(configuration: config, url: tab.url)
    content.delegate = self
    content.view.isHidden = true
    contentContainer.addSubview(content.view)
    contents[tab.id] = content
    tabIDByContent[ObjectIdentifier(content)] = tab.id
    select(nodeID: tab.id)
  }

  @objc func toggleSidebar(_ sender: Any?) {
    sidebarVisible.toggle()
    layoutViews()
  }

  @objc func nextTab(_ sender: Any?) { cycleTab(by: 1) }
  @objc func previousTab(_ sender: Any?) { cycleTab(by: -1) }

  private func cycleTab(by delta: Int) {
    let ids = rows.compactMap { row -> ItemID? in
      if case .tab(let t, _) = row { return t.id }
      return nil
    }
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

  func focus(space: Space) {
    withoutUndo { model.focusSpace(windowID: windowState.id, spaceID: space.id) }
    rebuildSpaceMenu()
    rebuildRows()
    reloadExtensionBar()
    syncTabStrips()
    showSelection()
    app.scheduleSave()
  }

  @objc private func spaceChosen(_ sender: NSPopUpButton) {
    guard let id = sender.selectedItem?.representedObject as? SpaceID, let space = model.space(id: id) else { return }
    focus(space: space)
  }

  @objc func showFind(_ sender: Any?) {
    findField.isHidden = false
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
    if newTabMode || selectedTab == nil {
      newTabMode = false
      openNewTab(url: url, background: false)
    } else if let tab = selectedTab {
      ensureContent(for: tab).load(url)
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

  @objc private func tableClicked(_ sender: NSTableView) {
    let row = sender.clickedRow
    guard row >= 0, row < rows.count, let id = rows[row].nodeID else { return }
    if case .folder(let folder, _) = rows[row] {
      withoutUndo { model.setExpanded(folderID: folder.id, expanded: !folder.isExpanded) }
      rebuildRows()
      return
    }
    select(nodeID: id)
  }

  /// Closes one page wherever it lives.
  func close(page: OEWebContent) {
    if let aux = auxiliaryPages.first(where: { $0.content === page }) {
      closeAuxiliary(aux)
    } else if page.extensionPopupIdentifier != nil {
      page.browser?.closeExtensionPopup()
      focusedBrowser?.closeExtensionPopup()
    } else if let id = tabID(for: page) {
      select(nodeID: id)
      closeTab(nil)
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

// MARK: - NSTextFieldDelegate

extension BrowserWindowController: NSTextFieldDelegate {
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if control === addressField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      newTabMode = false
      updateChrome()
      selectedContent?.focusPage()
      return true
    }
    return false
  }
}

// MARK: - NSTableView

extension BrowserWindowController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].nodeID != nil }

  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    if case .header = rows[row] { return true }
    return false
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = NSTableCellView()
    let width = Self.sidebarWidth - 24
    switch rows[row] {
    case .header(let title):
      let label = NSTextField(labelWithString: title)
      label.font = .systemFont(ofSize: 11, weight: .semibold)
      label.textColor = .secondaryLabelColor
      label.frame = NSRect(x: 4, y: 6, width: width, height: 16)
      cell.addSubview(label)
    case .folder(let folder, let depth):
      let x = 4 + CGFloat(depth) * 14
      let label = NSTextField(labelWithString: "\(folder.isExpanded ? "▾" : "▸") \(folder.title)")
      label.frame = NSRect(x: x, y: 6, width: width - x, height: 17)
      cell.addSubview(label)
    case .split(let split, let depth):
      let x = 4 + CGFloat(depth) * 14
      let label = NSTextField(labelWithString: "Split View (\(split.panes.count))")
      label.textColor = .secondaryLabelColor
      label.frame = NSRect(x: x, y: 6, width: width - x, height: 17)
      cell.addSubview(label)
    case .tab(let tab, let depth):
      let x = 4 + CGFloat(depth) * 14
      let content = contents[tab.id]
      let icon =
        content?.favicon ?? tab.live.faviconPNG.flatMap(NSImage.init(data:))
        ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
      let image = NSImageView(image: icon)
      image.imageScaling = .scaleProportionallyUpOrDown
      image.frame = NSRect(x: x, y: 7, width: 16, height: 16)
      cell.addSubview(image)
      var flags = ""
      if content == nil { flags += "◌ " }  // not loaded
      if tab.live.isLoading { flags += "… " }
      if tab.live.isAudible { flags += tab.isMuted ? "🔇 " : "🔊 " }
      if tab.live.isCrashed { flags += "💥 " }
      let title = tab.displayTitle.isEmpty ? (tab.url.host() ?? tab.url.absoluteString) : tab.displayTitle
      let label = NSTextField(labelWithString: flags + title)
      label.lineBreakMode = .byTruncatingTail
      label.frame = NSRect(x: x + 22, y: 6, width: width - x - 22, height: 17)
      cell.addSubview(label)
    }
    return cell
  }
}

// MARK: - OEWebContentDelegate

extension BrowserWindowController: OEWebContentDelegate {
  func webContent(_ webContent: OEWebContent, didChange changes: OEWebContentChange) {
    if let page = auxiliaryPages.first(where: { $0.content === webContent }) {
      if changes.contains(.title) { page.panel.title = webContent.title }
      return
    }
    guard let id = tabID(for: webContent), let tab = model.tab(id: id) else { return }
    var persist = false
    if changes.contains(.URL), let url = webContent.url, url.absoluteString != "about:blank" {
      if tab.url != url {
        tab.url = url
        persist = true
      }
    }
    if changes.contains(.title), !webContent.title.isEmpty, tab.title != webContent.title {
      tab.title = webContent.title
      persist = true
    }
    if changes.contains(.favicon) {
      tab.live.faviconPNG = webContent.favicon.flatMap(Self.pngData)
    }
    tab.live.isLoading = webContent.isLoading
    tab.live.progress = webContent.estimatedProgress
    tab.live.canGoBack = webContent.canGoBack
    tab.live.canGoForward = webContent.canGoForward
    tab.live.isAudible = webContent.isAudible
    tab.live.isCrashed = webContent.crashState != .none
    if !changes.isDisjoint(with: [.URL, .title, .favicon, .loading, .audio, .crash, .live]) {
      reloadRow(for: id)
    }
    if visibleTabs.contains(where: { $0.id == id }) { updateChrome() }
    if persist { app.scheduleSave() }
    if !changes.isDisjoint(with: [.URL, .title, .loading, .live, .crash, .audio]) {
      record("change", webContent, ["changes": changes.rawValue])
    }
  }

  static func pngData(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }

  func webContent(_ webContent: OEWebContent, createWebContentFor request: OEOpenRequest) -> OEWebContent? {
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
    case .currentTab, .saveToDisk:
      return nil
    default:
      guard let space = focusedSpace else { return nil }
      let opener = tabID(for: webContent)
      let tab = model.newTab(in: space.id, url: request.url ?? URL(string: "about:blank")!, at: 0)
      tab.openerID = opener
      let content = makeContent(for: tab, url: nil)
      if request.disposition != .newBackgroundTab { select(nodeID: tab.id) }
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
      findField.placeholderString = "\(result.activeMatchIndex)/\(result.matchCount)"
    }
  }

  func webContent(_ webContent: OEWebContent, didRequestFullscreen fullscreen: Bool) {
    record("fullscreen", webContent, ["on": fullscreen])
    if fullscreenPolicy == "record" { return }
    // Arc hides the sidebar and lets the page fill the screen.
    isPageFullscreen = fullscreen
    if let window, window.styleMask.contains(.fullScreen) != fullscreen {
      window.toggleFullScreen(nil)
    }
    layoutViews()
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

extension BrowserWindowController: OEBrowserDelegate {
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

extension BrowserWindowController: OEBrowserContextDelegate {
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
