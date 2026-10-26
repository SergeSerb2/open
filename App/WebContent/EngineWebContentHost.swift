import AppKit
import OpenEngine
import OpenFeatures
import OpenModel

/// The sole delegate of a tab page. Closed generations never update the model.
@MainActor
final class EngineWebContentHost: NSObject, WebContentHost, OEWebContentDelegate {
  let tabID: ItemID
  let profileID: ProfileID
  let content: OEWebContent
  weak var owner: EngineWebContentHostFactory?
  private(set) var closed = false
  private(set) var generation = 0
  var onURLChange: ((URL) -> Void)?
  var onTitleChange: ((String) -> Void)?
  var onLoadingChange: ((Bool) -> Void)?
  var onFaviconChange: ((Data?) -> Void)?
  var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)?
  var view: NSView { content.view }
  var currentURL: URL? { content.url }
  var title: String { content.title }
  var canGoBack: Bool { content.canGoBack }
  var canGoForward: Bool { content.canGoForward }
  var isLoading: Bool { content.isLoading }

  init(tabID: ItemID, profileID: ProfileID, content: OEWebContent, owner: EngineWebContentHostFactory) {
    self.tabID = tabID; self.profileID = profileID; self.content = content; self.owner = owner
    super.init(); content.delegate = self
  }
  func load(_ url: URL) { if !closed { content.load(url) } }
  func reload() { if !closed { content.reload() } }
  func stop() { if !closed { content.stopLoading() } }
  func goBack() { if !closed { content.goBack() } }
  func goForward() { if !closed { content.goForward() } }
  func focus() { if !closed { content.focusPage() } }
  func close() {
    guard !closed else { return }; closed = true; generation += 1
    onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil; shouldNavigate = nil
    content.delegate = nil; content.close(); content.view.removeFromSuperview()
    owner?.hostDidClose(self)
  }

  func webContent(_ page: OEWebContent, didChange changes: OEWebContentChange) {
    guard !closed, let owner else { return }
    let token = generation
    if changes.contains(.URL), let url = page.url, url.absoluteString != "about:blank" { onURLChange?(url) }
    guard !closed, generation == token else { return }
    if changes.contains(.title), !page.title.isEmpty { onTitleChange?(page.title) }
    if changes.contains(.loading) || changes.contains(.live) { onLoadingChange?(page.isLoading) }
    if changes.contains(.favicon) { onFaviconChange?(page.favicon.flatMap(EngineWebContentHostFactory.pngData)) }
    guard !closed, generation == token else { return }
    if let tab = owner.model.tab(id: tabID) {
      tab.live.hasWebContent = true; tab.live.isLoading = page.isLoading
      tab.live.progress = page.estimatedProgress; tab.live.canGoBack = page.canGoBack; tab.live.canGoForward = page.canGoForward
      tab.live.isAudible = page.isAudible; tab.live.isCrashed = page.crashState != .none
    }
    if !changes.isDisjoint(with: [.URL, .title]) { owner.app.scheduleSave() }
    owner.record("change", page, ["changes": changes.rawValue])
  }
  func webContent(_ page: OEWebContent, createWebContentFor request: OEOpenRequest) -> OEWebContent? {
    guard !closed else { return nil }; return owner?.webContent(page, createWebContentFor: request)
  }
  func webContentDidRequestClose(_ page: OEWebContent) { if !closed { owner?.close(page: page) } }
  func webContent(_ page: OEWebContent, handleKeyEventBeforePage event: NSEvent) -> Bool {
    !closed && (MainMenu.performReservedShortcut(event) || owner?.controller?.handleKeyDown(event) == true)
  }
  func webContent(_ page: OEWebContent, runJavaScriptDialog dialog: OEJavaScriptDialog) -> Bool {
    !closed && owner?.webContent(page, runJavaScriptDialog: dialog) == true
  }
  func webContent(_ page: OEWebContent, decidePermissionRequest request: OEPermissionRequest) -> Bool {
    !closed && owner?.webContent(page, decidePermissionRequest: request) == true
  }
  func webContent(_ page: OEWebContent, showContextMenu menu: OEContextMenu) -> Bool {
    !closed && owner?.webContent(page, showContextMenu: menu) == true
  }
  func webContent(_ page: OEWebContent, didUpdateFindResult result: OEFindResult) { if !closed { owner?.webContent(page, didUpdateFindResult: result) } }
  func webContent(_ page: OEWebContent, didRequestFullscreen fullscreen: Bool) { if !closed { owner?.webContent(page, didRequestFullscreen: fullscreen) } }
  func webContent(_ page: OEWebContent, didFinishLoadWithStatus status: Int) { if !closed { owner?.webContent(page, didFinishLoadWithStatus: status) } }
  func webContent(_ page: OEWebContent, didFailLoadWithError error: any Error) { if !closed { owner?.webContent(page, didFailLoadWithError: error) } }
  func webContent(_ page: OEWebContent, didReceiveDevToolsEvent method: String, parameters: [String: Any]) { if !closed { owner?.webContent(page, didReceiveDevToolsEvent: method, parameters: parameters) } }
  func webContent(_ page: OEWebContent, didLogConsoleMessage message: String, level: Int, source: String, line: Int) { if !closed { owner?.webContent(page, didLogConsoleMessage: message, level: level, source: source, line: line) } }
}
