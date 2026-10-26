import AppKit
import OpenEngine
import OpenModel

/// Tab changes that Chromium asks for on its own: chrome.tabs calls from
/// extensions, and pages extensions open (fork patch P1,
/// docs/engine-patches.md). The engine reports each one as a request; the
/// shell applies it to OpenModel, and syncTabStrips() then puts Chromium's
/// tab strip back in sidebar order. Closes arrive as
/// webContentDidRequestClose(_:).
extension BrowserWindowController {
  /// chrome.tabs.create, an extension's welcome or options page: a new Today
  /// tab at the top of the Space (Arc's placement for new tabs).
  @objc(browser:didOpenWebContent:active:)
  func browser(_ browser: OEBrowser, didOpen webContent: OEWebContent, active: Bool) {
    guard let space = space(forNewTabIn: browser) else {
      webContent.close()
      return
    }
    let url = webContent.url ?? URL(string: "about:blank")!
    let tab = model.newTab(in: space.id, url: url, at: 0)
    adopt(webContent, for: tab)
    record("open", webContent, ["disposition": "chromium", "active": active, "url": url.absoluteString])
    if active {
      if space.id != focusedSpace?.id { focus(space: space) }
      select(nodeID: tab.id)
    }
  }

  /// chrome.tabs.update({active: true}): select the tab, in its own Space.
  @objc(browser:requestsActivationOfWebContent:)
  func browser(_ browser: OEBrowser, requestsActivationOf webContent: OEWebContent) {
    guard let id = tabID(for: webContent), model.tab(id: id) != nil else { return }
    if let space = space(containing: id), space.id != focusedSpace?.id { focus(space: space) }
    select(nodeID: id)
    record("tab-request", webContent, ["request": "activate"])
  }

  /// chrome.tabs.move: applied only when one position in the tab's own
  /// parent (section, folder, or Favorites) puts the tab between exactly the
  /// two strip tabs Chromium put it between. Otherwise nothing changes, and
  /// the resync puts Chromium's strip back (folders, splits, other sections
  /// and Spaces cannot be reached by a strip index).
  @objc(browser:requestsMoveOfWebContent:toIndex:)
  func browser(_ browser: OEBrowser, requestsMoveOf webContent: OEWebContent, to index: UInt) {
    defer { syncTabStrips() }
    guard let id = tabID(for: webContent), let profile = profileID(for: browser),
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
      let order = stripOrder(profile: profile, replacing: parent, with: moved)
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
    defer { syncTabStrips() }
    guard let id = tabID(for: webContent), let parent = model.parent(of: id), model.tab(id: id) != nil else {
      return
    }
    if case .favorites = parent {
      record("tab-request", webContent, ["request": pinned ? "pin" : "unpin", "refused": true])
      return
    }
    guard model.isPinned(tabID: id) != pinned else { return }
    if pinned { model.pinTab(id: id) } else { model.unpinTab(id: id) }
    record("tab-request", webContent, ["request": pinned ? "pin" : "unpin"])
  }

  /// chrome.tabs.discard: this shell unloads a tab that is not on screen,
  /// the way it unloads pinned tabs (the new shell sleeps it with
  /// OpenSleep). The tab stays in the sidebar and loads again when shown.
  @objc(browser:requestsDiscardOfWebContent:)
  func browser(_ browser: OEBrowser, requestsDiscardOf webContent: OEWebContent) -> Bool {
    guard let id = tabID(for: webContent), model.tab(id: id) != nil,
      !visibleTabs.contains(where: { $0.id == id })
    else {
      record("tab-request", webContent, ["request": "discard", "refused": true])
      return false
    }
    record("tab-request", webContent, ["request": "discard"])
    // Not inside the engine's call.
    DispatchQueue.main.async { [weak self] in
      guard let self, let content = self.contents[id], content === webContent else { return }
      self.dropContent(id: id, content: content)
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

  /// The focused Space if it belongs to the strip's profile, else that
  /// profile's first Space.
  private func space(forNewTabIn browser: OEBrowser) -> Space? {
    guard let profile = profileID(for: browser) else { return nil }
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

  /// The tab ids of `profile`'s strip in syncTabStrips() order (tabs with a
  /// page only), with `parent`'s children replaced by `children`.
  private func stripOrder(profile: ProfileID, replacing parent: NodeParent, with children: [SidebarNode]) -> [ItemID] {
    func tabs(_ nodes: [SidebarNode], in container: NodeParent) -> [ItemID] {
      (container == parent ? children : nodes).flatMap { node -> [ItemID] in
        switch node {
        case .tab(let t): return contents[t.id] == nil ? [] : [t.id]
        case .folder(let f): return tabs(f.children, in: .folder(f.id))
        case .split(let s): return tabs(s.panes.map { .tab($0) }, in: .splitPane(s.id))
        }
      }
    }
    var order: [ItemID] = []
    if let favorites = model.profile(id: profile)?.favorites {
      order += tabs(favorites.map { .tab($0) }, in: .favorites(profile))
    }
    for space in model.spaces where space.profileID == profile {
      order += tabs(space.pinned, in: .spacePinned(space.id))
    }
    for space in model.spaces where space.profileID == profile {
      order += tabs(space.today, in: .spaceToday(space.id))
    }
    return order
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
}
