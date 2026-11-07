import AppKit
import OpenEngine
import OpenModel

/// One engine strip per (standard window, profile). Contexts remain lazy.
@MainActor
final class TabStripMirror {
  unowned let owner: EngineWebContentHostFactory
  private var browsers: [ProfileID: OEBrowser] = [:]
  private var moveObserver: UUID?
  init(owner: EngineWebContentHostFactory) {
    self.owner = owner
    moveObserver = owner.model.addObserver { [weak self] change in
      guard let self, case .move(_, _, _, _, let id) = change,
        let profile = self.owner.profile(for: id), let browser = self.browsers[profile.id],
        let content = self.owner.contents[id],
        let index = self.owner.tabs(in: profile.id).filter({ self.owner.contents[$0.id] != nil }).firstIndex(where: { $0.id == id })
      else { return }
      browser.move(content, to: UInt(index))
      self.sync()
    }
  }

  func browser(for profileID: ProfileID, create: Bool = true, loadContext: Bool = true) -> OEBrowser? {
    if let browser = browsers[profileID] { return browser }
    guard create else { return nil }
    guard let context = owner.context(for: profileID, create: loadContext) else { return nil }
    let browser = OEBrowser(context: context)
    browser.delegate = owner; browser.window = owner.window
    browser.context.delegate = owner.app
    browsers[profileID] = browser
    return browser
  }

  func sync() {
    guard owner.app.engineReady else { return }
    owner.didSyncMirror()
    let contents = owner.contents
    for profile in owner.model.profiles {
      let tabs = owner.tabs(in: profile.id)
      let loaded = tabs.filter { contents[$0.id] != nil }
      guard !loaded.isEmpty || browsers[profile.id] != nil else { continue }
      guard let browser = browser(for: profile.id) else { continue }
      let retained = Set(loaded.compactMap { contents[$0.id].map(ObjectIdentifier.init) })
      for content in browser.webContents where !retained.contains(ObjectIdentifier(content)) { browser.remove(content) }
      for (index, tab) in loaded.enumerated() {
        guard let content = contents[tab.id] else { continue }
        browser.insert(content, at: UInt(index))
        browser.setPinned(owner.model.isPinned(tabID: tab.id) || profile.favorites.contains { $0.id == tab.id }, for: content)
      }
      let selected = owner.selectedTab.flatMap { contents[$0.id] }
      browser.activeWebContent = owner.focusedProfile?.id == profile.id
        && selected.map({ chosen in browser.webContents.contains { $0 === chosen } }) == true ? selected : nil
    }
  }

  func close() {
    if let moveObserver { owner.model.removeObserver(moveObserver); self.moveObserver = nil }
    for browser in browsers.values { browser.close() }; browsers.removeAll()
  }
  func retireProfile(_ id: ProfileID) { browsers.removeValue(forKey:id)?.close() }
  #if OPEN_AUTOMATION
  /// Exercise OEBrowser.dealloc, not its explicit -close path. Web contents
  /// and the engine registry hold only weak browser references.
  func releaseWithoutClosingForAutomation() -> [String: Any] {
    let weakBrowsers = NSHashTable<OEBrowser>.weakObjects()
    for browser in browsers.values { weakBrowsers.add(browser) }
    let count = browsers.count
    let hadPopup = browsers.values.contains { $0.extensionPopup != nil }
    browsers.removeAll()
    return ["released": count, "remaining": weakBrowsers.allObjects.count, "hadPopup": hadPopup]
  }
  #endif
  func snapshot() -> [[String: Any]] {
    browsers.map { profile, browser in
      ["profile": profile.description, "context": browser.context.identifier,
       "tabs": browser.webContents.map { owner.tabID(for: $0)?.description ?? "" },
       "pinStates": browser.webContents.map { ["id": owner.tabID(for: $0)?.description ?? "", "pinned": browser.isPinned($0)] as [String: Any] },
       "contents": browser.webContents.map(\.identifier),
       "active": browser.activeWebContent.flatMap { owner.tabID(for: $0)?.description } ?? "",
       "activeIsMember": browser.activeWebContent.map { active in browser.webContents.contains { $0 === active } } ?? true] as [String: Any]
    }.sorted { ($0["profile"] as? String ?? "") < ($1["profile"] as? String ?? "") }
  }
}
