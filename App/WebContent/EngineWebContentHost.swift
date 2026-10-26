import AppKit
import OpenEngine
import OpenFeatures
import OpenModel

/// The sole delegate of a tab page. Closed generations never update the model.
@MainActor
final class EngineWebContentHost: NSObject, WebContentHost, OEWebContentDelegate {
  private(set) var tabID: ItemID
  private(set) var spaceID: SpaceID?
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
  private(set) var pageBackgroundColor: NSColor?
  var onPageBackgroundChange: ((NSColor?) -> Void)?
  var onLiveStateChange: ((WebContentLiveState) -> Void)?
  private var backgroundGeneration = 0
  private var backgroundTask: Task<Void, Never>?
  var hasBackgroundTask: Bool { backgroundTask != nil }
  var liveState: WebContentLiveState {
    WebContentLiveState(isLoading: content.isLoading, progress: content.estimatedProgress,
      canGoBack: content.canGoBack, canGoForward: content.canGoForward,
      isAudible: content.isAudible, isCrashed: content.crashState != .none)
  }
  var view: NSView { content.view }
  var currentURL: URL? { content.url }
  var title: String { content.title }
  var canGoBack: Bool { content.canGoBack }
  var canGoForward: Bool { content.canGoForward }
  var isLoading: Bool { content.isLoading }

  init(tabID: ItemID, profileID: ProfileID, content: OEWebContent, owner: EngineWebContentHostFactory) {
    self.tabID = tabID; self.profileID = profileID; self.content = content; self.owner = owner
    spaceID = owner.space(for: tabID)?.id ?? owner.focusedSpace?.id
    super.init(); content.delegate = self
  }
  func load(_ url: URL) { if !closed { content.load(url) } }
  func reload() { if !closed { content.reload() } }
  func stop() { if !closed { content.stopLoading() } }
  func goBack() { if !closed { content.goBack() } }
  func goForward() { if !closed { content.goForward() } }
  func focus() { if !closed { content.focusPage() } }
  func rebind(tabID: ItemID, spaceID: SpaceID?) {
    generation += 1; self.tabID = tabID; self.spaceID = spaceID
    refreshPageBackground()
  }
  func close() {
    guard !closed else { return }; closed = true; generation += 1
    cancelBackgroundRead()
    onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil; shouldNavigate = nil
    onPageBackgroundChange = nil; onLiveStateChange = nil
    content.delegate = nil; content.close(); content.view.removeFromSuperview()
    owner?.hostDidClose(self)
  }

  func webContent(_ page: OEWebContent, didChange changes: OEWebContentChange) {
    guard !closed, let owner else { return }
    let token = generation
    if changes.contains(.URL), let url = page.url, url.absoluteString != "about:blank" {
      onURLChange?(url); cancelBackgroundRead(); pageBackgroundColor = nil; onPageBackgroundChange?(nil)
    }
    guard !closed, generation == token else { return }
    if changes.contains(.title), !page.title.isEmpty { onTitleChange?(page.title) }
    if changes.contains(.loading) || changes.contains(.live) { onLoadingChange?(page.isLoading) }
    if changes.contains(.favicon) { onFaviconChange?(page.favicon.flatMap(EngineWebContentHostFactory.pngData)) }
    guard !closed, generation == token else { return }
    onLiveStateChange?(liveState)
    if changes.contains(.loading), !page.isLoading { refreshPageBackground() }
    if !changes.isDisjoint(with: [.URL, .title]) { owner.app.scheduleSave() }
    owner.record("change", page, ["changes": changes.rawValue])
  }
  /// OpenEngine has no page-color event yet. Read the committed page after
  /// loading ends; a late answer cannot cross a close, rebind, or navigation.
  private func cancelBackgroundRead() {
    backgroundGeneration += 1
    backgroundTask?.cancel(); backgroundTask = nil
  }
  func refreshPageBackground() {
    guard !closed, owner?.app.engineReady == true, owner?.app.terminationRequested == false,
          !content.isLoading else { return }
    cancelBackgroundRead()
    backgroundGeneration += 1
    let revision = backgroundGeneration, token = generation
    backgroundTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { if self.backgroundGeneration == revision { self.backgroundTask = nil } }
      guard !Task.isCancelled, !self.closed, self.owner?.app.engineReady == true,
            self.owner?.app.terminationRequested == false else { return }
      await self.owner?.app.deferAsyncEngineWorkForAutomation()
      guard !Task.isCancelled, !self.closed, self.owner?.app.engineReady == true,
            self.owner?.app.terminationRequested == false else { return }
      let script = """
      (() => { const c=document.createElement('canvas'); c.width=c.height=1; const x=c.getContext('2d');
        const colors=[document.querySelector('meta[name="theme-color"]')?.content,
          document.body && getComputedStyle(document.body).backgroundColor, getComputedStyle(document.documentElement).backgroundColor];
        for (const v of colors) { if (!v || !CSS.supports('color',v)) continue;
          x.clearRect(0,0,1,1); x.fillStyle=v; x.fillRect(0,0,1,1); const p=Array.from(x.getImageData(0,0,1,1).data); if(p[3]) return p; }
        return [255,255,255,255]; })()
      """
      self.owner?.app.noteAsyncEngineCall("pageBackground")
      let values = try? await self.content.evaluateJavaScript(script) as? [Double]
      guard !Task.isCancelled, !self.closed, self.owner?.app.engineReady == true,
            self.owner?.app.terminationRequested == false,
            self.generation == token, self.backgroundGeneration == revision,
            let values, values.count == 4 else { return }
      let color = NSColor(srgbRed: values[0]/255, green: values[1]/255, blue: values[2]/255, alpha: values[3]/255)
      self.pageBackgroundColor = color; self.onPageBackgroundChange?(color)
    }
  }
  func webContent(_ page: OEWebContent, createWebContentFor request: OEOpenRequest) -> OEWebContent? {
    guard !closed else { return nil }; return owner?.webContent(page, createWebContentFor: request)
  }
  func webContentDidRequestClose(_ page: OEWebContent) { if !closed { owner?.close(page: page) } }
  func webContent(_ page: OEWebContent, handleKeyEventBeforePage event: NSEvent) -> Bool {
    !closed && owner?.controller?.handleKeyDown(event) == true
  }
  func webContent(_ page: OEWebContent, handleUnconsumedKeyEvent event: NSEvent) -> Bool {
    !closed && owner?.controller?.handleKeyDown(event, unconsumed: true) == true
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
  func webContent(_ page: OEWebContent, didFinishLoadWithStatus status: Int) { if !closed { refreshPageBackground(); owner?.webContent(page, didFinishLoadWithStatus: status) } }
  func webContent(_ page: OEWebContent, didFailLoadWithError error: any Error) { if !closed { owner?.webContent(page, didFailLoadWithError: error) } }
  func webContent(_ page: OEWebContent, didReceiveDevToolsEvent method: String, parameters: [String: Any]) { if !closed { owner?.webContent(page, didReceiveDevToolsEvent: method, parameters: parameters) } }
  func webContent(_ page: OEWebContent, didLogConsoleMessage message: String, level: Int, source: String, line: Int) { if !closed { owner?.webContent(page, didLogConsoleMessage: message, level: level, source: source, line: line) } }
}
