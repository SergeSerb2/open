import AppKit
import OpenEngine

/// One web view the shell knows about.
@MainActor
final class Tab {
  enum Kind: String {
    case tab  // in the sidebar
    case popup  // window.open with features (Little Arc style panel)
    case peek  // Peek panel
    case extensionPopup  // extension action popup
  }

  private static var nextID = 1
  let id: Int
  let webView: WebView
  var kind: Kind
  var extensionID: String?

  init(webView: WebView, kind: Kind) {
    id = Tab.nextID
    Tab.nextID += 1
    self.webView = webView
    self.kind = kind
  }
}

/// The spike's only window: a plain tab list on the left and the page on the
/// right. Intentionally ugly; it exists to exercise the engine API.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
  NSTableViewDelegate, NSTextFieldDelegate, WebViewDelegate, ExtensionManagerDelegate, ProfileDelegate
{
  let profile: Profile
  let options: LaunchOptions

  private(set) var tabs: [Tab] = []
  private(set) var auxiliaryTabs: [Tab] = []
  private(set) var activeTab: Tab?
  private(set) var splitTab: Tab?

  // Automation hooks (docs/automation.md).
  var dialogPolicy: String?  // "accept" | "dismiss" | nil (show UI)
  var permissionPolicy: String?  // "grant" | "deny" | nil (show UI)
  var promptText: String?
  private(set) var events: [[String: Any]] = []
  private(set) var lastFindResult: FindResult?
  var downloadDirectory: URL?
  var contextMenuPolicy: String?  // "record": record items and cancel
  var fullscreenPolicy: String?  // "record": do not resize the window
  private(set) var pendingDialogs: [JavaScriptDialog] = []

  private let sidebar = NSView()
  private let addressField = NSTextField()
  private let extensionBar = NSStackView()
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private let contentContainer = NSView()
  private let findField = NSSearchField()
  private let statusLabel = NSTextField(labelWithString: "")
  private var sidebarVisible = true
  private var popupPanel: NSPanel?
  private var peekPanel: NSPanel?
  private var littlePanels: [NSPanel] = []
  private var isPageFullscreen = false

  static let sidebarWidth: CGFloat = 260

  init(profile: Profile, options: LaunchOptions) {
    self.profile = profile
    self.options = options
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Open (engine spike)"
    window.titlebarAppearsTransparent = true
    window.center()
    window.setFrameAutosaveName("OpenSpikeWindow")
    window.tabbingMode = .disallowed
    super.init(window: window)
    window.delegate = self
    profile.delegate = self
    profile.extensions.delegate = self
    buildUI()
    reloadExtensionBar()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // MARK: UI

  private func buildUI() {
    guard let root = window?.contentView else { return }
    root.wantsLayer = true

    sidebar.wantsLayer = true
    sidebar.layer?.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
    root.addSubview(sidebar)
    contentContainer.wantsLayer = true
    contentContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.85, alpha: 1).cgColor
    root.addSubview(contentContainer)

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
    tableView.rowHeight = 38
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

  func windowDidResize(_ notification: Notification) {
    layoutViews()
  }

  private func layoutViews() {
    guard let root = window?.contentView else { return }
    let b = root.bounds
    let sw = sidebarVisible && !isPageFullscreen ? Self.sidebarWidth : 0
    sidebar.isHidden = sw == 0
    sidebar.frame = NSRect(x: 0, y: 0, width: sw, height: b.height)
    let inset: CGFloat = isPageFullscreen ? 0 : 8
    contentContainer.frame = NSRect(
      x: sw + (sw > 0 ? 0 : inset), y: inset,
      width: b.width - sw - inset - (sw > 0 ? 0 : inset), height: b.height - inset * 2 - (isPageFullscreen ? 0 : 28)
    ).integral
    let top = b.height - 36
    addressField.frame = NSRect(x: 76, y: top, width: sw - 84, height: 24)
    extensionBar.frame = NSRect(x: 8, y: top - 34, width: sw - 16, height: 28)
    scrollView.frame = NSRect(x: 0, y: 24, width: sw, height: top - 34 - 30)
    statusLabel.frame = NSRect(x: 8, y: 4, width: sw - 16, height: 16)
    findField.frame = NSRect(x: b.width - 268, y: b.height - 30, width: 260, height: 24)
    layoutContent()
  }

  private func layoutContent() {
    let b = contentContainer.bounds
    for tab in tabs {
      let visible = tab === activeTab || tab === splitTab
      if !visible {
        tab.webView.isHidden = true
        continue
      }
      if tab.webView.superview !== contentContainer {
        contentContainer.addSubview(tab.webView)
      }
      tab.webView.isHidden = false
      if let split = splitTab, let active = activeTab, split !== active {
        let half = (b.width - 6) / 2
        tab.webView.frame =
          tab === active
          ? NSRect(x: 0, y: 0, width: half, height: b.height)
          : NSRect(x: half + 6, y: 0, width: b.width - half - 6, height: b.height)
      } else {
        tab.webView.frame = b
      }
    }
  }

  private func reloadTabRow(_ tab: Tab) {
    if let row = tabs.firstIndex(where: { $0 === tab }) {
      tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
    }
  }

  // MARK: Tabs

  func makeWebView(url: URL?, style: RuntimeStyle, profile: Profile? = nil) -> WebView {
    let config = WebViewConfiguration(profile: profile ?? self.profile)
    config.runtimeStyle = style
    config.showsChromeToolbar = options.chromeToolbar && style == .chrome
    let webView = WebView(configuration: config, url: url)
    webView.delegate = self
    return webView
  }

  @discardableResult
  func openTab(url: URL?, style: RuntimeStyle? = nil, background: Bool = false) -> Tab {
    let webView = makeWebView(url: url, style: style ?? options.defaultStyle)
    return addTab(webView: webView, background: background)
  }

  @discardableResult
  func addTab(webView: WebView, background: Bool) -> Tab {
    let tab = Tab(webView: webView, kind: .tab)
    tabs.append(tab)
    webView.isHidden = true
    contentContainer.addSubview(webView)
    webView.frame = contentContainer.bounds
    tableView.reloadData()
    if !background || activeTab == nil {
      activate(tab)
    }
    return tab
  }

  func tab(id: Int) -> Tab? {
    (tabs + auxiliaryTabs).first { $0.id == id }
  }

  func tab(for webView: WebView) -> Tab? {
    (tabs + auxiliaryTabs).first { $0.webView === webView }
  }

  var allTabs: [Tab] { tabs + auxiliaryTabs }

  func activate(_ tab: Tab) {
    guard tabs.contains(where: { $0 === tab }) else { return }
    activeTab = tab
    if splitTab === tab { splitTab = nil }
    layoutContent()
    if let row = tabs.firstIndex(where: { $0 === tab }) {
      tableView.selectRowIndexes([row], byExtendingSelection: false)
    }
    updateChrome()
    tab.webView.focusPage()
  }

  func close(_ tab: Tab) {
    tab.webView.close()
    tab.webView.removeFromSuperview()
    if let i = tabs.firstIndex(where: { $0 === tab }) {
      tabs.remove(at: i)
      if splitTab === tab { splitTab = nil }
      if activeTab === tab {
        activeTab = nil
        if !tabs.isEmpty { activate(tabs[min(i, tabs.count - 1)]) }
      }
      tableView.reloadData()
      layoutContent()
    } else if let i = auxiliaryTabs.firstIndex(where: { $0 === tab }) {
      auxiliaryTabs.remove(at: i)
      for panel in [popupPanel, peekPanel] + littlePanels where panel?.contentView?.subviews.contains(tab.webView) == true {
        panel?.orderOut(nil)
      }
    }
    updateChrome()
  }

  func showSplit(left: Tab, right: Tab) {
    activeTab = left
    splitTab = right
    layoutContent()
  }

  func adoptUnownedRequest(_ request: OpenRequest) -> WebView? {
    let webView = makeWebView(url: nil, style: options.defaultStyle, profile: request.profile)
    addTab(webView: webView, background: false)
    return webView
  }

  private func updateChrome() {
    let wv = activeTab?.webView
    if addressField.currentEditor() == nil {
      addressField.stringValue = wv?.url?.absoluteString ?? ""
    }
    window?.title = wv?.title ?? "Open"
  }

  // MARK: Panels (Peek, Little Arc popups, extension popups)

  private func makePanel(size: NSSize, title: String) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: false)
    panel.title = title
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.becomesKeyOnlyIfNeeded = false
    return panel
  }

  /// Shows a panel even while another app is active (automation runs from
  /// the terminal, so Open is usually not the active app).
  private func present(_ panel: NSPanel) {
    panel.orderFrontRegardless()
    panel.makeKey()
  }

  private func host(_ webView: WebView, in panel: NSPanel) {
    let container = NSView(frame: panel.contentLayoutRect)
    panel.contentView = container
    webView.frame = container.bounds
    webView.autoresizingMask = [.width, .height]
    container.addSubview(webView)
  }

  @discardableResult
  func openPeek(url: URL) -> Tab {
    let webView = makeWebView(url: url, style: options.defaultStyle)
    let tab = Tab(webView: webView, kind: .peek)
    auxiliaryTabs.append(tab)
    let panel = peekPanel ?? makePanel(size: NSSize(width: 900, height: 700), title: "Peek")
    peekPanel = panel
    host(webView, in: panel)
    if let frame = window?.frame {
      panel.setFrame(frame.insetBy(dx: 120, dy: 60), display: true)
    }
    present(panel)
    return tab
  }

  /// Opens an extension action popup below its toolbar button.
  @discardableResult
  func openExtensionPopup(_ ext: Extension) -> Tab? {
    popupPanel?.orderOut(nil)
    if let old = auxiliaryTabs.first(where: { $0.kind == .extensionPopup }) {
      close(old)
    }
    guard let webView = profile.extensions.makeActionPopupWebView(for: ext, activeWebView: activeTab?.webView)
    else { return nil }
    webView.delegate = self
    webView.enableAutoResize(minimumSize: NSSize(width: 25, height: 25), maximumSize: NSSize(width: 800, height: 600))
    let tab = Tab(webView: webView, kind: .extensionPopup)
    tab.extensionID = ext.identifier
    auxiliaryTabs.append(tab)
    let panel = makePanel(size: NSSize(width: 380, height: 520), title: ext.name)
    popupPanel = panel
    host(webView, in: panel)
    if let button = extensionBar.arrangedSubviews.first(where: { $0.identifier?.rawValue == ext.identifier }),
      let win = window
    {
      let r = win.convertToScreen(button.convert(button.bounds, to: nil))
      panel.setFrameTopLeftPoint(NSPoint(x: r.minX, y: r.minY - 4))
    }
    present(panel)
    return tab
  }

  // MARK: Extensions bar

  func extensionManagerDidChange() {
    reloadExtensionBar()
  }

  private func reloadExtensionBar() {
    extensionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for ext in profile.extensions.installedExtensions where ext.isEnabled {
      let image = ext.icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
      image.size = NSSize(width: 18, height: 18)
      let button = NSButton(image: image, target: self, action: #selector(extensionButtonClicked(_:)))
      button.bezelStyle = .accessoryBarAction
      button.isBordered = false
      button.toolTip = ext.actionTitle ?? ext.name
      button.identifier = .init(ext.identifier)
      extensionBar.addArrangedSubview(button)
    }
    let manage = NSButton(title: "⋯", target: self, action: #selector(openExtensionsPage(_:)))
    manage.bezelStyle = .accessoryBarAction
    manage.toolTip = "chrome://extensions"
    extensionBar.addArrangedSubview(manage)
  }

  @objc private func extensionButtonClicked(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue, let ext = profile.extensions.extension(identifier: id) else { return }
    openExtensionPopup(ext)
  }

  // MARK: Actions (menu)

  @objc func newTab(_ sender: Any?) {
    openTab(url: URL(string: "https://www.google.com"), style: options.defaultStyle)
    focusAddressBar(nil)
  }

  @objc func newChromeTab(_ sender: Any?) {
    openTab(url: URL(string: "https://www.google.com"), style: .chrome)
  }

  @objc func focusAddressBar(_ sender: Any?) {
    if !sidebarVisible { toggleSidebar(nil) }
    window?.makeFirstResponder(addressField)
    addressField.currentEditor()?.selectAll(nil)
  }

  @objc func closeTab(_ sender: Any?) {
    if let panel = NSApp.keyWindow as? NSPanel, let tab = auxiliaryTabs.first(where: { panel.contentView?.subviews.contains($0.webView) == true }) {
      close(tab)
      return
    }
    if let tab = activeTab { close(tab) }
  }

  @objc func printPage(_ sender: Any?) { activeTab?.webView.print() }
  @objc func reloadPage(_ sender: Any?) { activeTab?.webView.reload() }
  @objc func goBack(_ sender: Any?) { activeTab?.webView.goBack() }
  @objc func goForward(_ sender: Any?) { activeTab?.webView.goForward() }
  @objc func zoomIn(_ sender: Any?) { activeTab?.webView.zoomIn() }
  @objc func zoomOut(_ sender: Any?) { activeTab?.webView.zoomOut() }
  @objc func resetZoom(_ sender: Any?) { activeTab?.webView.resetZoom() }
  @objc func showDevTools(_ sender: Any?) { activeTab?.webView.showDevTools() }

  @objc func openExtensionsPage(_ sender: Any?) {
    openTab(url: ExtensionManager.managementPageURL, style: .chrome)
  }

  @objc func toggleSidebar(_ sender: Any?) {
    sidebarVisible.toggle()
    layoutViews()
  }

  @objc func toggleSplit(_ sender: Any?) {
    if splitTab != nil {
      splitTab = nil
    } else if let active = activeTab, let other = tabs.first(where: { $0 !== active }) {
      splitTab = other
    }
    layoutContent()
  }

  @objc func nextTab(_ sender: Any?) { cycleTab(by: 1) }
  @objc func previousTab(_ sender: Any?) { cycleTab(by: -1) }

  private func cycleTab(by delta: Int) {
    guard let active = activeTab, let i = tabs.firstIndex(where: { $0 === active }), !tabs.isEmpty else { return }
    activate(tabs[(i + delta + tabs.count) % tabs.count])
  }

  @objc func selectTabByNumber(_ sender: NSMenuItem) {
    guard let n = sender.representedObject as? Int, !tabs.isEmpty else { return }
    activate(n == 9 ? tabs[tabs.count - 1] : tabs[min(n - 1, tabs.count - 1)])
  }

  @objc func showFind(_ sender: Any?) {
    findField.isHidden = false
    window?.makeFirstResponder(findField)
  }

  @objc func findNext(_ sender: Any?) {
    guard !findField.stringValue.isEmpty else { return }
    activeTab?.webView.find(findField.stringValue, forward: true, caseSensitive: false)
  }

  @objc private func findFieldChanged(_ sender: NSSearchField) {
    if sender.stringValue.isEmpty {
      activeTab?.webView.stopFinding(clearSelection: true)
      findField.isHidden = true
      activeTab?.webView.focusPage()
    } else {
      activeTab?.webView.find(sender.stringValue, forward: true, caseSensitive: false)
    }
  }

  @objc private func addressEntered(_ sender: NSTextField) {
    let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    let url: URL?
    if text.contains("://") || text.hasPrefix("about:") {
      url = URL(string: text)
    } else if text.contains(".") && !text.contains(" ") {
      url = URL(string: "https://\(text)")
    } else {
      var c = URLComponents(string: "https://www.google.com/search")!
      c.queryItems = [URLQueryItem(name: "q", value: text)]
      url = c.url
    }
    guard let url else { return }
    if let tab = activeTab {
      tab.webView.load(url)
      tab.webView.focusPage()
    } else {
      openTab(url: url)
    }
  }

  @objc private func tableClicked(_ sender: NSTableView) {
    let row = sender.clickedRow
    guard row >= 0, row < tabs.count else { return }
    activate(tabs[row])
  }

  // MARK: NSTableView

  func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let tab = tabs[row]
    let wv = tab.webView
    let cell = NSTableCellView()
    let image = NSImageView(image: wv.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
    image.frame = NSRect(x: 4, y: 11, width: 16, height: 16)
    cell.addSubview(image)
    var flags: [String] = [wv.runtimeStyle == .chrome ? "C" : "A"]
    if wv.isLoading { flags.append("…") }
    if wv.isAudible { flags.append(wv.isMuted ? "🔇" : "🔊") }
    if wv.crashState != .none { flags.append("💥") }
    let title = NSTextField(labelWithString: wv.title.isEmpty ? (wv.url?.host ?? "New Tab") : wv.title)
    title.lineBreakMode = .byTruncatingTail
    title.frame = NSRect(x: 26, y: 18, width: Self.sidebarWidth - 60, height: 17)
    cell.addSubview(title)
    let sub = NSTextField(labelWithString: "[\(flags.joined(separator: " "))] #\(tab.id) \(wv.url?.absoluteString ?? "")")
    sub.font = .systemFont(ofSize: 9)
    sub.textColor = .secondaryLabelColor
    sub.lineBreakMode = .byTruncatingTail
    sub.frame = NSRect(x: 26, y: 3, width: Self.sidebarWidth - 60, height: 13)
    cell.addSubview(sub)
    return cell
  }

  // MARK: WebViewDelegate

  func webView(_ webView: WebView, didChange changes: WebViewChange) {
    guard let tab = tab(for: webView) else { return }
    if changes.contains(.statusText) && tab === activeTab {
      statusLabel.stringValue = webView.statusText
    }
    if changes.isDisjoint(with: [.progress, .statusText]) {
      reloadTabRow(tab)
    }
    if tab === activeTab { updateChrome() }
    if tab.kind == .popup || tab.kind == .peek, changes.contains(.title) {
      webView.window?.title = webView.title
    }
    record("change", tab, ["changes": changes.rawValue])
  }

  func webView(_ webView: WebView, createWebViewFor request: OpenRequest) -> WebView? {
    let style = webView.runtimeStyle
    switch request.disposition {
    case .newPopup:
      // Arc opens sized window.open() popups in a small floating window.
      let popup = makeWebView(url: nil, style: style, profile: request.profile)
      let tab = Tab(webView: popup, kind: .popup)
      auxiliaryTabs.append(tab)
      var size = request.requestedFrame.size
      if size.width < 100 || size.height < 100 { size = NSSize(width: 600, height: 500) }
      let panel = makePanel(size: size, title: request.url?.host ?? "Popup")
      littlePanels.append(panel)
      host(popup, in: panel)
      panel.center()
      present(panel)
      record("open", tab, ["disposition": "popup", "url": request.url?.absoluteString ?? ""])
      return popup
    case .currentTab, .saveToDisk:
      return nil
    default:
      let newView = makeWebView(url: nil, style: style, profile: request.profile)
      let tab = addTab(webView: newView, background: request.disposition == .newBackgroundTab)
      record("open", tab, ["disposition": "\(request.disposition.rawValue)", "url": request.url?.absoluteString ?? ""])
      return newView
    }
  }

  func webViewDidRequestClose(_ webView: WebView) {
    if let tab = tab(for: webView) { close(tab) }
  }

  func webView(_ webView: WebView, handleKeyEventBeforePage event: NSEvent) -> Bool {
    MainMenu.performReservedShortcut(event, fallback: self)
  }

  func webView(_ webView: WebView, runJavaScriptDialog dialog: JavaScriptDialog) -> Bool {
    record(
      "dialog", tab(for: webView),
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
      guard let window = webView.window else { return false }
      let alert = NSAlert()
      alert.messageText = webView.url?.host ?? "This page says"
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

  func completePendingDialog(accept: Bool, text: String?) -> Bool {
    guard !pendingDialogs.isEmpty else { return false }
    pendingDialogs.removeFirst().complete(accepted: accept, text: text)
    return true
  }

  func webView(_ webView: WebView, decidePermissionRequest request: PermissionRequest) -> Bool {
    record(
      "permission", tab(for: webView), ["origin": request.origin.absoluteString, "kinds": request.kinds.rawValue])
    switch permissionPolicy {
    case "grant":
      request.grant()
      return true
    case "deny":
      request.deny()
      return true
    default:
      guard let window = webView.window else { return false }
      let alert = NSAlert()
      alert.messageText = "\(request.origin.host ?? "This site") wants permission"
      alert.informativeText = "Permission bits: \(request.kinds.rawValue)"
      alert.addButton(withTitle: "Allow")
      alert.addButton(withTitle: "Block")
      alert.beginSheetModal(for: window) { response in
        response == .alertFirstButtonReturn ? request.grant() : request.deny()
      }
      return true
    }
  }

  func webView(_ webView: WebView, showContextMenu menu: ContextMenu) -> Bool {
    let ns = NSMenu()
    var keep: [AnyObject] = [menu]
    if let link = menu.linkURL {
      ns.addItem(
        ClosureMenuItem(title: "Open Link in New Tab") { [weak self] in
          self?.openTab(url: link, style: webView.runtimeStyle, background: true)
        })
      ns.addItem(
        ClosureMenuItem(title: "Open Link in Peek") { [weak self] in
          self?.openPeek(url: link)
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
    keep.append(ns)
    record(
      "contextMenu", tab(for: webView),
      ["items": menu.items.map(\.title), "link": menu.linkURL?.absoluteString ?? "", "targets": menu.targets.rawValue])
    if contextMenuPolicy == "record" {
      menu.cancel()
      return true
    }
    let point = NSPoint(x: menu.location.x, y: menu.location.y)
    DispatchQueue.main.async {
      let picked = ns.popUp(positioning: nil, at: point, in: webView)
      if !picked { menu.cancel() }
      _ = keep
    }
    return true
  }

  func webView(_ webView: WebView, didUpdateFindResult result: FindResult) {
    lastFindResult = result
    if result.isFinal {
      findField.placeholderString = "\(result.activeMatchIndex)/\(result.matchCount)"
    }
  }

  func webView(_ webView: WebView, didRequestFullscreen fullscreen: Bool) {
    // Arc hides its sidebar and lets the page fill the window, entering
    // macOS full screen if the window is not there yet.
    record("fullscreen", tab(for: webView), ["on": fullscreen])
    if fullscreenPolicy == "record" { return }
    isPageFullscreen = fullscreen
    if let window, window.styleMask.contains(.fullScreen) != fullscreen {
      window.toggleFullScreen(nil)
    }
    layoutViews()
  }

  func webView(_ webView: WebView, didRequestContentSize size: NSSize) {
    guard let tab = tab(for: webView), tab.kind == .extensionPopup, let panel = webView.window as? NSPanel else {
      return
    }
    let frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    var f = panel.frame
    f.origin.y += f.height - frame.height
    f.size = frame.size
    panel.setFrame(f, display: true)
  }

  func webView(_ webView: WebView, didFinishLoadWithStatus status: Int) {
    if tabs.first === tab(for: webView) {
      LaunchTiming.shared.mark("firstLoadEnd")
    }
    record("load", tab(for: webView), ["status": status, "url": webView.url?.absoluteString ?? ""])
  }

  func webView(_ webView: WebView, didFailLoadWithError error: Error) {
    record("loadError", tab(for: webView), ["error": error.localizedDescription])
  }

  func webView(_ webView: WebView, didReceiveDevToolsEvent method: String, parameters: [String: Any]) {
    record("devtools", tab(for: webView), ["method": method, "params": parameters])
  }

  func webView(
    _ webView: WebView, didLogConsoleMessage message: String, level: Int, source: String, line: Int
  ) {
    record("console", tab(for: webView), ["message": message, "level": level, "source": source, "line": line])
  }

  private func record(_ type: String, _ tab: Tab?, _ info: [String: Any]) {
    var event = info
    event["type"] = type
    event["tab"] = tab?.id ?? 0
    event["time"] = Date().timeIntervalSince1970
    events.append(event)
    if events.count > 2000 { events.removeFirst(events.count - 2000) }
  }

  func drainEvents() -> [[String: Any]] {
    defer { events.removeAll() }
    return events
  }

  // MARK: ProfileDelegate (downloads)

  func profile(
    _ profile: Profile, decideDestinationFor download: Download, suggestedFilename: String,
    completion: @escaping @MainActor (URL?) -> Void
  ) {
    let dir =
      downloadDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    completion(dir.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename))
  }

  func profile(_ profile: Profile, downloadDidUpdate download: Download) {
    record(
      "download", nil,
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
