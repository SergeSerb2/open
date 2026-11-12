import AppKit
import OpenEngine
import OpenFeatures
import OpenModel
import OpenSuggest

/// Bounds copied from the page-chrome checkpoint. The App copies at most 128 nodes,
/// eight levels, 1 KiB per title, 16 KiB selection and 64 KiB per URL. No buffer here
/// approaches PartitionAlloc's single-allocation ceiling; the largest accepted external text is 64 KiB.
@MainActor
enum PageContextMenuLimits {
  static func failure(_ request: OEContextMenu) -> String? {
    guard request.selectionText.utf8.count <= 16 * 1024 else { return "Menu selection exceeds 16384 UTF-8 bytes." }
    guard [request.linkURL, request.sourceURL, request.pageURL, request.frameURL].compactMap({ $0 })
      .allSatisfy({ $0.absoluteString.utf8.count <= 64 * 1024 }) else { return "Menu URL exceeds 65536 UTF-8 bytes." }
    var count = 0
    func visit(_ items: [OEContextMenuItem], depth: Int) -> Bool {
      guard depth <= 8, items.count <= 128 else { return false }
      for item in items {
        count += 1
        guard count <= 128, item.title.utf8.count <= 1024 else { return false }
        if !item.submenu.isEmpty, !visit(item.submenu, depth: depth + 1) { return false }
      }
      return true
    }
    return visit(request.items, depth: 1) ? nil : "Menu exceeds 128 nodes, 8 levels or a 1024-byte title."
  }
}

/// The lead's S11 menu design is an Open decision. Arc's exact page-menu order is
/// unverified (docs/re/page-chrome.md §5). Keep Chromium's grouping and relative order.
@MainActor
final class PageContextMenuBuilder {
  let menu = NSMenu()
  private let request: OEContextMenu
  private weak var owner: EngineWebContentHostFactory?
  private weak var page: OEWebContent?
  private var openKeys: Set<String> = []
  private var engineAliases: [String: String] = [:]
  // Opaque identifiers delivered by OpenEngine's pinned Chromium 156 model (the symbols
  // in Vendor/cef/include/cef_command_ids.h). No CEF API is called by the shell. Identity
  // matters: extensions can use exactly the same English titles as a browser command.
  private enum ChromeCommand {
    static let linkOpen: Set<Int> = [50100, 50101, 50102, 50111, 57316]
    static let linkAliases = [50100: "link-new-tab", 50101: "link-window", 50111: "link-split"]
    static let copy = 50150, goToURL = 50190, source = 35002
    static let inspect: Set<Int> = [50162, 50171]
    static let media: Set<Int> = [50120, 50121, 50122, 50123, 50125, 50126, 50129, 50130,
      50131, 50132, 50133, 50136, 50137, 50140, 50141, 50142, 50143, 50170]
  }
  private var chromeModel: Bool { page?.runtimeStyle == .chrome }
  private func engineItem(_ item: NSMenuItem, in identifiers: Set<Int>) -> Bool {
    guard let key = item.identifier?.rawValue, key.hasPrefix("engine:"), let id = Int(key.dropFirst(7)) else { return false }
    return identifiers.contains(id)
  }
  private func isInspect(_ item: NSMenuItem) -> Bool {
    chromeModel ? engineItem(item, in: ChromeCommand.inspect) : item.title.hasPrefix("Inspect")
  }
  private func isSource(_ item: NSMenuItem) -> Bool {
    chromeModel ? engineItem(item, in: [ChromeCommand.source]) : item.title.hasPrefix("View Page Source")
  }
  private(set) var completed = false

  init(request: OEContextMenu, page: OEWebContent, owner: EngineWebContentHostFactory) {
    self.request = request; self.page = page; self.owner = owner
    menu.autoenablesItems = false
  }

  func buildAndShow() {
    guard let owner, let page, !owner.isClosing, page.isLive else { cancel(); return }
    if let failure = PageContextMenuLimits.failure(request) {
      owner.record("contextMenuRefused", page, ["reason": failure]); cancel(); return
    }
    append(request.items, to: menu)
    if let link = request.linkURL { insertLinkItems(link, owner: owner, page: page) }
    if !request.targets.contains(.editable), !request.selectionText.isEmpty { insertSelection(owner: owner) }
    // Translate and Capture retain their existing Inspect anchor. On a page, source precedes
    // Inspect, so insert before source to keep Translate → Capture → Source → Inspect.
    if request.linkURL == nil, request.mediaType == .none, request.selectionText.isEmpty,
      !request.targets.contains(.editable) {
      var index = menu.items.firstIndex { isSource($0) || isInspect($0) } ?? menu.items.count
      var additions: [NSMenuItem] = []
      if let translation = owner.translate.contextMenuItem(for: page) {
        additions.append(openItem("translate", translation.title) { [weak owner] in owner?.translate.perform(translation.action) })
      }
      if owner.hasWebPage, owner.selectedContent === page {
        for (title, id) in [("Capture", "capture-page"), ("Capture Full Page", "capture-full-page")] {
          additions.append(openItem(id, title) { [weak owner] in _ = owner?.performAppCommand(id) })
        }
      }
      if !additions.isEmpty {
        if index > 0, !menu.items[index - 1].isSeparatorItem { menu.insertItem(.separator(), at: index); index += 1 }
        for item in additions { menu.insertItem(item, at: index); index += 1 }
        if index < menu.items.count, !menu.items[index].isSeparatorItem { menu.insertItem(.separator(), at: index) }
      }
    }
    guard insertHooks(owner.pageContextMenuHooks) else {
      owner.record("contextMenuRefused", page, ["reason": "Menu hooks exceed 32 items."]); cancel(); return
    }
    trim(menu)
    guard validNativeMenu() else {
      owner.record("contextMenuRefused", page, ["reason": "Final menu exceeds 168 nodes, 8 levels or a 1024-byte title."]); cancel(); return
    }
    func commands(_ items: [OEContextMenuItem], parent: String = "") -> [[String: Any]] {
      items.flatMap { item -> [[String: Any]] in
        if item.isSeparator { return [] }
        if !item.submenu.isEmpty { return commands(item.submenu, parent: item.title) }
        return [["id": item.commandIdentifier, "title": item.title, "enabled": item.isEnabled, "checked": item.isChecked, "submenu": parent]]
      }
    }
    func nodeCount(_ items: [OEContextMenuItem]) -> Int { items.reduce(0) { $0 + 1 + nodeCount($1.submenu) } }
    owner.record("contextMenu", page, ["incomingNodes": nodeCount(request.items), "selectionBytes": request.selectionText.utf8.count,
      "items": request.items.map(\.title), "commands": commands(request.items),
      "link": request.linkURL?.absoluteString ?? "", "targets": request.targets.rawValue,
      "openItems": menu.items.filter { !$0.isSeparatorItem }.map(\.title),
      "open": menu.items.filter { ["capture-page", "capture-full-page"].contains($0.identifier?.rawValue ?? "") }.map(\.title),
      "shown": menu.items.map { $0.isSeparatorItem ? "-" : $0.title }, "rows": rows(menu)])
    let policy = owner.contextMenuPolicy
    if policy == "record" { cancel(); return }
    // Actions may destroy the caller (new window, close, Peek). Leave the engine callback first.
    DispatchQueue.main.async { [self] in
      if let policy, policy.hasPrefix("run-open:") {
        if !perform(title: String(policy.dropFirst(9))) { cancel() }
      } else if let policy, policy.hasPrefix("run:"), let id = Int(policy.dropFirst(4)) {
        // Preserve the engine-refusal probe: absent/disabled ids still reach OpenEngine's
        // delivered-command allowlist, which refuses them and completes this request.
        if !perform(key: "engine:\(id)") { finish("engine:\(id)", engine: id) }
      } else { present() }
    }
  }

  private static func title(_ item: NSMenuItem) -> String { normalized(item.title) }
  private static func normalized(_ value: String) -> String { value }
  private func isLinkOpen(_ item: OEContextMenuItem) -> Bool {
    if chromeModel { return ChromeCommand.linkOpen.contains(item.commandIdentifier) }
    // Alloy has CEF's short menu model and no Chrome extension menu entries.
    let title = item.title
    return ["Open Link in New Tab", "Open Link in New Window", "Open Link in Incognito Window",
      "Open Link in Split View", "Open Link in Left View", "Open Link in Right View",
      "Open Link in Top View", "Open Link in Bottom View", "Open Link With…", "Open Link With"].contains(title)
  }

  private func append(_ sources: [OEContextMenuItem], to destination: NSMenu) {
    for source in sources {
      if source.isSeparator { destination.addItem(.separator()); continue }
      if request.linkURL != nil, isLinkOpen(source) {
        let aliases = ["Open Link in New Tab": "link-new-tab", "Open Link in New Window": "link-window", "Open Link in Split View": "link-split"]
        engineAliases["engine:\(source.commandIdentifier)"] = chromeModel ? ChromeCommand.linkAliases[source.commandIdentifier] : aliases[source.title]
        continue
      }
      let title = Self.normalized(source.title)
      let item: NSMenuItem
      if !request.targets.contains(.editable), !request.selectionText.isEmpty, (chromeModel ? source.commandIdentifier == ChromeCommand.goToURL : title.hasPrefix("Go to ")) {
        // Reinsert the Open URL-selection action after Copy, never duplicate Chromium's Go to.
        continue
      } else {
        let key = "engine:\(source.commandIdentifier)"
        item = ClosureMenuItem(title: source.title) { [weak self] in self?.finish(key, engine: source.commandIdentifier) }
        item.identifier = .init(key); item.isEnabled = source.isEnabled
      }
      item.state = source.isChecked ? .on : .off
      if !source.submenu.isEmpty {
        let child = NSMenu(title: source.title); child.autoenablesItems = false
        append(source.submenu, to: child); item.submenu = child
      }
      destination.addItem(item)
    }
  }

  private func insertLinkItems(_ link: URL, owner: EngineWebContentHostFactory, page: OEWebContent) {
    let opener = owner.tabID(for: page)
    let split = owner.controller?.splitController
    let peekItem = owner.controller?.hasPeekController == true
      ? owner.controller?.peekController.stack.first(where: { $0.hostTabID == opener }) : nil
    let peekSource = peekItem?.sourceTabID ?? opener
    let canSplit = owner.windowState.style == .standard && peekItem == nil
      && opener.flatMap { owner.model.tab(id: $0) } != nil && split?.canAddPane == true
    // Count only surviving rows before the first replaced Chromium link-open row.
    let anchor = request.items.firstIndex { isLinkOpen($0) } ?? 0
    let survivingBefore = request.items.prefix(anchor).filter { $0.isSeparator || !isLinkOpen($0) }.count
    let items = [
      openItem("link-incognito", "Open Link in Incognito Window") { [weak owner] in
        guard let owner else { return }
        owner.app.makeIncognitoWindow(parent: owner.incognitoSession?.parent ?? opener.flatMap { owner.profile(for: $0) } ?? owner.focusedProfile, url: link)
      },
      openItem("link-new-tab", "Open Link in New Tab") { [weak owner] in _ = owner?.openNewTab(url: link, background: true, opener: opener) },
      openItem("link-split", "Open Link in Split View", enabled: canSplit) { [weak owner] in
        guard let owner, let opener, let controller = owner.controller else { return }
        owner.selectNumberedItem(opener)
        let split = controller.splitController
        guard split.canAddPane, let tab = owner.openNewTab(url: link, background: true, opener: opener) else { return }
        let index = split.split?.panes.firstIndex { $0.id == opener }.map { $0 + 1 }
        if split.drop(tab.id, zone: .right, paneIndex: index) {
          // An insertion index preserves the old axis in the public drop API. This menu
          // explicitly opens to the right, including when the source split was vertical.
          if let current = split.split, current.orientation != .horizontal {
            owner.model.setSplitOrientation(splitID: current.id, orientation: .horizontal)
            split.refresh()
          }
        } else { owner.model.closeTab(id: tab.id) }
      },
      openItem("link-peek", "Open Link in Peek", enabled: peekSource != nil && owner.controller != nil) { [weak owner] in
        if let peekSource { owner?.controller?.peekController.open(url: link, sourceTabID: peekSource) }
      },
      // Section 9's URL seam currently records the request and opens the File-menu stub.
      // Step 6 replaces that seam with the real page without changing this caller.
      openItem("link-little-open", "Open Link in Little Open") { [weak owner] in
        guard let owner else { return }
        if owner.isIncognito { owner.openNewTab(url: link, background: false, opener: opener) }
        else { owner.app.openLittleOpen(url: link, profileHint: owner.focusedProfile?.id) }
      },
      openItem("link-window", "Open Link in New Window") { [weak owner] in
        guard let owner, let window = owner.isIncognito ? owner.app.makeIncognitoWindow(parent: owner.incognitoSession?.parent) : owner.app.makeUserWindow(), let target = owner.app.hostFactories[window.windowID] else { return }
        target.commandBarSession?.dismiss()
        _ = target.openNewTab(url: link, background: false)
      },
      NSMenuItem.separator(),
    ]
    var index = min(survivingBefore, menu.items.count)
    for item in items { menu.insertItem(item, at: index); index += 1 }
  }

  private func insertSelection(owner: EngineWebContentHostFactory) {
    let text = request.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let engine = SearchEngines.resolve(profile: owner.focusedProfile)
    let url = Self.selectionURL(text)
    let display = String(text.prefix(32)) + (text.count > 32 ? "…" : "")
    let title = url.map { _ in "Go to \(text)" } ?? "Search \(engine.name) for “\(display)”"
    guard let target = url ?? engine.searchURL(for: text) else { return }
    let index = menu.items.firstIndex { chromeModel ? engineItem($0, in: [ChromeCommand.copy]) : $0.title == "Copy" }.map { $0 + 1 } ?? menu.items.count
    menu.insertItem(openItem("selection-search", title) { [weak owner] in _ = owner?.openNewTab(url: target, background: false) }, at: index)
    // PB4 row 5: Open's on-device Translate Selection, right after the search item.
    if owner.translate.preferences.isEnabled {
      let location = request.location
      menu.insertItem(openItem("translate-selection", TranslateSelectionController.menuTitle) { [weak owner, weak page] in
        owner?.translate.selection.translate(text, at: location, in: page)
      }, at: index + 1)
    }
  }

  private static func selectionURL(_ text: String) -> URL? {
    guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
    if let url = URL(string: text), ["http", "https", "ftp", "file", "about"].contains(url.scheme?.lowercased() ?? "") { return url }
    if !text.contains(":"), !text.contains("@"), text.contains("."), let url = URL(string: "https://" + text), url.host != nil { return url }
    return nil
  }

  private func insertHooks(_ hooks: PageContextMenuHooks) -> Bool {
    let media = hooks.mediaItems(request), extensions = hooks.extensionItems(request)
    guard media.count + extensions.count <= 32 else { return false }
    let mediaIndex = menu.items.lastIndex { item in
      if chromeModel { return engineItem(item, in: ChromeCommand.media) }
      let title = Self.title(item)
      return title.contains("Image") || title.contains("Video") || title.contains("Audio") || title == "Loop" || title == "Show Controls"
    }.map { $0 + 1 } ?? menu.items.count
    insert(media, prefix: "media", at: mediaIndex)
    if !extensions.isEmpty {
      // GUESS: S-9's user capture will settle placement. Keep Manage Extensions
      // after Chromium's extension group, or in its own group before Inspect.
      func hasExtension(_ item: NSMenuItem) -> Bool {
        if let key = item.identifier?.rawValue, key.hasPrefix("engine:"),
           let id = Int(key.dropFirst(7)), (49000...50000).contains(id) { return true }
        return item.submenu?.items.contains(where: hasExtension) == true
      }
      if chromeModel, let last = menu.items.lastIndex(where: hasExtension) {
        insert(extensions, prefix: "extension", at: last + 1)
      } else {
        var index = menu.items.firstIndex { isInspect($0) } ?? menu.items.count
        // Preserve the separator belonging to Inspect's group below our new group.
        if index > 0, menu.items[index - 1].isSeparatorItem { index -= 1 }
        if index > 0, !menu.items[index - 1].isSeparatorItem {
          menu.insertItem(.separator(), at: index); index += 1
        }
        insert(extensions, prefix: "extension", at: index)
        let end = index + extensions.count
        if end < menu.items.count, !menu.items[end].isSeparatorItem { menu.insertItem(.separator(), at: end) }
      }
    }
    return true
  }
  private func insert(_ items: [PageContextMenuHooks.Item], prefix: String, at anchor: Int) {
    for (offset, item) in items.enumerated() {
      menu.insertItem(openItem("\(prefix):\(offset)", item.title, enabled: item.isEnabled, action: item.action), at: anchor + offset)
    }
  }
  private func openItem(_ key: String, _ title: String, enabled: Bool = true, action: @escaping @MainActor () -> Void) -> NSMenuItem {
    openKeys.insert(key)
    let item = ClosureMenuItem(title: title) { [weak self] in
      guard let self, self.isLive, !self.completed else { self?.cancel(); return }
      self.finish(key, engine: nil); action()
    }
    item.identifier = .init(key); item.isEnabled = enabled; return item
  }
  private var isLive: Bool { owner?.isClosing == false && page?.isLive == true }
  private func finish(_ key: String, engine: Int?) {
    guard !completed else { return }
    completed = true
    if let engine, isLive { request.select(command: engine) } else { request.cancel() }
    owner?.record("contextMenuDecision", page, ["key": key])
  }
  func cancel() { finish("cancel", engine: nil); menu.cancelTracking() }
  func belongs(to content: OEWebContent) -> Bool { page === content }
  private func present() {
    guard isLive, let page, page.view.window != nil, !page.view.isHiddenOrHasHiddenAncestor, !completed else { cancel(); return }
    _ = menu.popUp(positioning: nil, at: request.location, in: page.view)
    cancel()
  }
  @discardableResult private func perform(key: String? = nil, title: String? = nil) -> Bool {
    guard !completed, isLive else { cancel(); return false }
    func find(_ candidate: NSMenu) -> (NSMenu, Int)? {
      for (index, item) in candidate.items.enumerated() where item.isEnabled {
        let id = item.identifier?.rawValue ?? ""
        if item.submenu == nil, key == id || (title == item.title && openKeys.contains(id)) { return (candidate, index) }
        if let submenu = item.submenu, let result = find(submenu) { return result }
      }
      return nil
    }
    if let key, let alias = engineAliases[key] { return perform(key: alias) }
    guard let (native, index) = find(menu) else { return false }
    native.performActionForItem(at: index); return completed
  }
  private func trim(_ candidate: NSMenu) {
    for item in candidate.items { if let submenu = item.submenu { trim(submenu) } }
    var previousSeparator = true
    for item in candidate.items {
      if item.isSeparatorItem && previousSeparator { candidate.removeItem(item) } else { previousSeparator = item.isSeparatorItem }
    }
    if candidate.items.last?.isSeparatorItem == true { candidate.removeItem(at: candidate.items.count - 1) }
  }
  private func validNativeMenu() -> Bool {
    var count = 0
    func visit(_ candidate: NSMenu, depth: Int) -> Bool {
      guard depth <= 8 else { return false }
      for item in candidate.items {
        count += 1
        // Keep the final node cap, including Open rows, hook groups and separators.
        guard count <= 168, item.title.utf8.count <= 1024 else { return false }
        if let submenu = item.submenu, !visit(submenu, depth: depth + 1) { return false }
      }
      return true
    }
    return visit(menu, depth: 1)
  }
  private func rows(_ candidate: NSMenu, parent: String = "") -> [[String: Any]] {
    candidate.items.flatMap { item -> [[String: Any]] in
      if item.isSeparatorItem { return [] }
      if let submenu = item.submenu { return rows(submenu, parent: item.title) }
      return [["key": item.identifier?.rawValue ?? "", "title": item.title, "enabled": item.isEnabled, "checked": item.state == .on, "submenu": parent]]
    }
  }
}
