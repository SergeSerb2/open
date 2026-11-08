import AppKit
import OpenFeatures
import OpenModel

@MainActor
final class WelcomeContentHost: WebContentHost {
  let tabID: ItemID
  weak var owner: EngineWebContentHostFactory?
  let page = WelcomePageView()
  private(set) var closed = false
  var view: NSView { page }
  var currentURL: URL? { WelcomeTab.url }
  var title: String { WelcomeTab.title }
  var canGoBack: Bool { false }
  var canGoForward: Bool { false }
  var isLoading: Bool { false }
  var pageBackgroundColor: NSColor? { page.backgroundColor }
  var onURLChange: ((URL) -> Void)?
  var onTitleChange: ((String) -> Void)?
  var onLoadingChange: ((Bool) -> Void)?
  var onFaviconChange: ((Data?) -> Void)?
  var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)?
  var onPageBackgroundChange: ((NSColor?) -> Void)?
  var onLiveStateChange: ((WebContentLiveState) -> Void)?

  init(tabID: ItemID, owner: EngineWebContentHostFactory) {
    self.tabID = tabID; self.owner = owner
    page.styleProvider = { [weak owner] in
      guard let owner, let space = owner.space(for: tabID) else { return nil }
      return owner.controller?.context.style(for: space)
    }
    page.openShortcuts = { [weak owner] in owner?.app.performCommand("keyboard-shortcuts-edu") }
    page.openSettings = { [weak owner] in owner?.app.settingsPresenter.show(pane: .general) }
  }
  func load(_ url: URL) {
    guard !closed else { return }
    if WelcomeTab.matches(url) {
      onURLChange?(WelcomeTab.url); onTitleChange?(title); onFaviconChange?(WelcomeTab.faviconPNG)
      page.updateColors(); onPageBackgroundChange?(pageBackgroundColor)
    } else if !WelcomeTab.isInternal(url) {
      // load is a caller action, not an engine delegate. Replacement is safe here.
      owner?.leaveWelcome(tabID: tabID, for: url)
    }
  }
  func reload() { page.replay(card: 0) }
  func stop() { page.stop() }
  func goBack() {}
  func goForward() {}
  func focus() { if !closed { page.window?.makeFirstResponder(page.cards[0]) } }
  func close() {
    guard !closed else { return }; closed = true
    page.close(); page.removeFromSuperview()
    onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil
    onPageBackgroundChange = nil; onLiveStateChange = nil; shouldNavigate = nil
    if owner?.welcomeHosts[tabID] === self { owner?.welcomeHosts[tabID] = nil }
  }
}
