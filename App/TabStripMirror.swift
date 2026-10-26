import AppKit
import OpenEngine
import OpenModel

/// One engine strip per (standard window, profile). Contexts remain lazy.
@MainActor
final class TabStripMirror {
  unowned let owner: EngineWebContentHostFactory
  private var browsers: [ProfileID: OEBrowser] = [:]
  init(owner: EngineWebContentHostFactory) { self.owner = owner }

  func browser(for profileID: ProfileID) -> OEBrowser {
    if let browser = browsers[profileID] { return browser }
    let browser = OEBrowser(context: owner.context(for: profileID))
    browser.delegate = owner; browser.window = owner.window
    browser.context.delegate = owner.app
    browsers[profileID] = browser
    return browser
  }

  func sync() {
    guard owner.app.engineReady else { return }
    let contents = owner.contents
    for profile in owner.model.profiles {
      let tabs = owner.tabs(in: profile.id)
      let loaded = tabs.filter { contents[$0.id] != nil }
      guard !loaded.isEmpty || browsers[profile.id] != nil else { continue }
      let browser = browser(for: profile.id)
      let retained = Set(loaded.compactMap { contents[$0.id].map(ObjectIdentifier.init) })
      for content in browser.webContents where !retained.contains(ObjectIdentifier(content)) { browser.remove(content) }
      for (index, tab) in loaded.enumerated() {
        guard let content = contents[tab.id] else { continue }
        browser.insert(content, at: UInt(index))
        browser.setPinned(owner.model.isPinned(tabID: tab.id) || profile.favorites.contains { $0.id == tab.id }, for: content)
      }
      browser.activeWebContent = owner.focusedProfile?.id == profile.id ? owner.selectedContent : nil
    }
  }

  func close() { for browser in browsers.values { browser.close() }; browsers.removeAll() }
}
