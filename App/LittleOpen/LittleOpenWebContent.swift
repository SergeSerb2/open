import AppKit
import OpenEngine
import OpenFeatures
import OpenModel

/// One standalone Alloy page per session. This factory owns no sidebar window,
/// and its transient id never enters BrowserModel or a Chromium tab strip.
@MainActor
final class LittleOpenWebContent: LittleOpenWebContentProviding, WebContentHost {
  private unowned let app: AppDelegate
  private let factory: EngineWebContentHostFactory
  let host: EngineWebContentHost
  var tabID: ItemID { host.tabID }
  var view: NSView { host.view }
  var currentURL: URL? { host.currentURL }
  var title: String { host.title }
  var canGoBack: Bool { host.canGoBack }
  var canGoForward: Bool { host.canGoForward }
  var isLoading: Bool { host.isLoading }
  var pageBackgroundColor: NSColor? { host.pageBackgroundColor }
  var liveState: WebContentLiveState { host.liveState }
  var onURLChange: ((URL) -> Void)? { get { host.onURLChange } set { host.onURLChange = newValue } }
  var onTitleChange: ((String) -> Void)? { get { host.onTitleChange } set { host.onTitleChange = newValue } }
  var onLoadingChange: ((Bool) -> Void)? { get { host.onLoadingChange } set { host.onLoadingChange = newValue } }
  var onFaviconChange: ((Data?) -> Void)? { get { host.onFaviconChange } set { host.onFaviconChange = newValue } }
  var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)? { get { host.shouldNavigate } set { host.shouldNavigate = newValue } }
  var onPageBackgroundChange: ((NSColor?) -> Void)? { get { host.onPageBackgroundChange } set { host.onPageBackgroundChange = newValue } }
  var onLiveStateChange: ((WebContentLiveState) -> Void)? { get { host.onLiveStateChange } set { host.onLiveStateChange = newValue } }

  init(app: AppDelegate, profileID: ProfileID) {
    self.app = app
    let spaceID = app.model.mostRecentlyFocusedSpace(profileID: profileID)?.id ?? app.model.spaces.first?.id ?? SpaceID()
    factory = EngineWebContentHostFactory(app: app, state: BrowserWindowState(focusedSpaceID: spaceID))
    host = factory.makeHost(tabID: ItemID(), profileID: profileID, url: nil) as! EngineWebContentHost
    host.rebind(tabID: host.tabID, spaceID: nil)
    app.littleOpenHosts[host.tabID] = host
    host.content.drawsEngineHistorySwipeOverlay = true
    host.additionalKeyHandler = { [weak app] in app?.handleLittleOpenKey($0) ?? false }
    host.onCloseRequest = { [weak app, weak host] in
      guard let app, let window = host?.view.window,
        let session = app.littleOpenCoordinator.stateForAutomation.first(where: { $0.window === window }) else { return }
      app.littleOpenCoordinator.close(sessionID: session.id, archiveReason: nil)
    }
    // EngineWebContentHost forwards commit, URL/loading and title to the
    // per-Profile AppHistoryRecorder, exactly as it does for Peek.
  }
  func load(_ url: URL) { host.load(url) }
  func reload() { host.reload() }
  func stop() { host.stop() }
  func goBack() { host.goBack() }
  func goForward() { host.goForward() }
  func focus() { host.focus() }
  func close() {
    host.historyRecorder.flushBeforeClose()
    factory.closeAll()
    app.littleOpenHosts[host.tabID] = nil
  }
}
