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

  /// chrome.tabs.move: move the tab within its own section, next to the tab
  /// that Chromium put it beside. A move across sections is not applied.
  @objc(browser:requestsMoveOfWebContent:toIndex:)
  func browser(_ browser: OEBrowser, requestsMoveOf webContent: OEWebContent, to index: UInt) {
    defer { syncTabStrips() }
    guard let id = tabID(for: webContent), let parent = model.parent(of: id),
      let siblings = children(of: parent)?.filter({ $0.id != id })
    else { return }
    let others = browser.webContents.filter { $0 !== webContent }
    let target = Int(index)
    var position: Int?
    if target < others.count, let next = tabID(for: others[target]) {
      position = siblings.firstIndex { $0.id == next }
    }
    if position == nil, target > 0, target - 1 < others.count, let previous = tabID(for: others[target - 1]) {
      position = siblings.firstIndex { $0.id == previous }.map { $0 + 1 }
    }
    guard let position else { return }
    model.moveNode(id: id, to: parent, at: position)
    record("tab-request", webContent, ["request": "move", "position": position])
  }

  /// chrome.tabs.update({pinned}): pin or unpin the tab.
  @objc(browser:requestsPinned:forWebContent:)
  func browser(_ browser: OEBrowser, requestsPinned pinned: Bool, for webContent: OEWebContent) {
    defer { syncTabStrips() }
    guard let id = tabID(for: webContent), model.tab(id: id) != nil, model.isPinned(tabID: id) != pinned else {
      return
    }
    if pinned { model.pinTab(id: id) } else { model.unpinTab(id: id) }
    record("tab-request", webContent, ["request": pinned ? "pin" : "unpin"])
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
