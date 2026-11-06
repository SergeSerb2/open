import AppKit
import QuartzCore
import OpenEngine
import OpenFeatures
import OpenModel

/// One Chrome tab in its own hidden Browser per session. Its transient id
/// never enters BrowserModel; extension APIs see the standalone window.
@MainActor
final class LittleOpenWebContent: NSObject, LittleOpenWebContentProviding, WebContentHost, StandalonePageSurface {
  private unowned let app: AppDelegate
  private let factory: EngineWebContentHostFactory
  private(set) var host: EngineWebContentHost?
  private var browser: OEBrowser?
  private let profileID: ProfileID
  let tabID = ItemID()
  private let root = LittleOpenSurfaceView(frame: .zero)
  private var creationScheduled = false
  private var pendingURL: URL?
  private var closed = false
  #if OPEN_AUTOMATION
  static var beforeNextCreationForAutomation: ((LittleOpenWebContent) -> Bool)?
  private var beforeCreationForAutomation: ((LittleOpenWebContent) -> Bool)?
  var onSubmissionForAutomation: (() -> Void)?
  private(set) var submittedBeforeBrowser = false
  #endif
  private(set) var firstFrameRead: [String: Any]?
  private(set) var browserCreationStartedAt: TimeInterval?
  var registeredSurface: (any StandalonePageSurface)? { factory.standaloneSurface }
  var surfaceWindow: NSWindow? { root.window }
  var surfacePage: OEWebContent? {
    guard !closed, let host, !host.closed else { return nil }
    return host.content
  }
  var isSurfaceVisible: Bool {
    guard surfacePage != nil, let window = surfaceWindow else { return false }
    return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
  }
  func surfaceAnchor() -> (view: NSView, rect: CGRect)? {
    guard surfacePage != nil, let window = surfaceWindow else { return nil }
    if let controller = app.littleOpenCoordinator?.controllers.values.first(where: { $0.window === window }),
      controller.state == .page, !controller.titleBar.isHidden,
      let capsule = controller.titleBar.urlCapsuleView {
      return (capsule, capsule.bounds)
    }
    return (root, CGRect(x: root.bounds.minX + 24,
      y: root.isFlipped ? root.bounds.minY : root.bounds.maxY - 1, width: 1, height: 1))
  }
  var view: NSView { root }
  var currentURL: URL? { host?.currentURL ?? pendingURL }
  var title: String { host?.title ?? "" }
  var canGoBack: Bool { host?.canGoBack ?? false }
  var canGoForward: Bool { host?.canGoForward ?? false }
  var isLoading: Bool { host?.isLoading ?? false }
  var pageBackgroundColor: NSColor? { host?.pageBackgroundColor }
  var liveState: WebContentLiveState { host?.liveState ?? WebContentLiveState() }
  var onURLChange: ((URL) -> Void)? { didSet { host?.onURLChange = onURLChange } }
  var onTitleChange: ((String) -> Void)? { didSet { host?.onTitleChange = onTitleChange } }
  var onLoadingChange: ((Bool) -> Void)? { didSet { host?.onLoadingChange = onLoadingChange } }
  var onFaviconChange: ((Data?) -> Void)? { didSet { host?.onFaviconChange = onFaviconChange } }
  var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)? { didSet { host?.shouldNavigate = shouldNavigate } }
  var onPageBackgroundChange: ((NSColor?) -> Void)? { didSet { host?.onPageBackgroundChange = onPageBackgroundChange } }
  var onLiveStateChange: ((WebContentLiveState) -> Void)? { didSet { host?.onLiveStateChange = onLiveStateChange } }

  init(app: AppDelegate, profileID: ProfileID) {
    self.app = app
    let spaceID = app.model.mostRecentlyFocusedSpace(profileID: profileID)?.id ?? app.model.spaces.first?.id ?? SpaceID()
    factory = EngineWebContentHostFactory(app: app, state: BrowserWindowState(focusedSpaceID: spaceID))
    self.profileID = profileID
    super.init()
    root.owner = self
    factory.standaloneSurface = self
    #if OPEN_AUTOMATION
    beforeCreationForAutomation = Self.beforeNextCreationForAutomation
    Self.beforeNextCreationForAutomation = nil
    #endif
  }

  /// The existing onChange feed runs after orderFront and Profile replacement.
  /// Commit the first window frame, then create on the next main run-loop turn.
  /// The weak completion and closed guard cancel creation if the window closes.
  func windowOrderedFront() {
    guard !closed, host == nil, !creationScheduled,
      let window = surfaceWindow, window.isVisible else { return }
    creationScheduled = true
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      // A main-queue async block can drain within the current turn.
      RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
        MainActor.assumeIsolated {
          guard let self, !self.closed else { return }
          self.firstFrameRead = ["browserID": self.browser.map { $0.identifier } as Any? ?? NSNull(),
            "content": self.host?.content.identifier ?? 0, "visible": self.surfaceWindow?.isVisible ?? false,
            "uptime": ProcessInfo.processInfo.systemUptime]
          #if OPEN_AUTOMATION
          let before = self.beforeCreationForAutomation; self.beforeCreationForAutomation = nil
          if before?(self) == true { return }
          #endif
          self.createBrowser()
        }
      }
    }
    window.displayIfNeeded()
    CATransaction.commit()
    CATransaction.flush()
  }
  private func createBrowser() {
    guard !closed, host == nil, let context = factory.context(for: profileID) else { return }
    browserCreationStartedAt = ProcessInfo.processInfo.systemUptime
    // Same P1 path as the main window: context, Browser, Chrome host, strip insertion.
    let browser = OEBrowser(context: context)
    self.browser = browser
    browser.context.delegate = app
    factory.standaloneBrowser = browser
    let initialURL = pendingURL; pendingURL = nil
    guard let host = factory.makeHost(tabID: tabID, profileID: profileID, url: initialURL, history: nil, browser: browser) as? EngineWebContentHost else {
      pendingURL = initialURL
      browser.close(); self.browser = nil; factory.standaloneBrowser = nil; return
    }
    guard !closed else { host.close(); browser.close(); return }
    self.host = host
    host.onURLChange = onURLChange; host.onTitleChange = onTitleChange
    host.onLoadingChange = onLoadingChange; host.onFaviconChange = onFaviconChange
    host.shouldNavigate = shouldNavigate; host.onPageBackgroundChange = onPageBackgroundChange
    host.onLiveStateChange = onLiveStateChange
    host.view.frame = root.bounds; host.view.autoresizingMask = [.width, .height]
    root.addSubview(host.view)
    host.view.isHidden = false
    host.rebind(tabID: host.tabID, spaceID: nil)
    app.littleOpenHosts[host.tabID] = host
    host.content.drawsEngineHistorySwipeOverlay = true
    host.additionalKeyHandler = { [weak app] in app?.handleLittleOpenKey($0) ?? false }
    host.onCloseRequest = { [weak app, weak host] in
      guard let app, let window = host?.view.window,
        let session = app.littleOpenCoordinator.stateForAutomation.first(where: { $0.window === window }) else { return }
      app.littleOpenCoordinator.close(sessionID: session.id, archiveReason: nil)
    }
    // Section 6 discovers the new Browser as soon as its tab exists.
    factory.standaloneSurfaceVisibilityChanged()
    app.littleOpenCoordinator?.onChange?()
    guard !closed else { return }
    if let url = pendingURL { pendingURL = nil; host.load(url) }
    // The host records history only after a real navigation commits.
  }
  func load(_ url: URL) {
    guard !closed else { return }
    #if OPEN_AUTOMATION
    submittedBeforeBrowser = host == nil && url.absoluteString != "about:blank"
    #endif
    if let host { host.load(url) } else { pendingURL = url }
    #if OPEN_AUTOMATION
    if submittedBeforeBrowser {
      let submitted = onSubmissionForAutomation; onSubmissionForAutomation = nil
      submitted?()
    }
    #endif
  }
  #if OPEN_AUTOMATION
  func resumeCreationForAutomation() {
    DispatchQueue.main.async { [weak self] in self?.createBrowser() }
  }
  #endif
  func reload() { host?.reload() }
  func stop() { pendingURL = nil; host?.stop() }
  func goBack() { host?.goBack() }
  func goForward() { host?.goForward() }
  func focus() { host?.focus() }
  func close() {
    guard !closed else { return }; closed = true
    creationScheduled = false
    #if OPEN_AUTOMATION
    beforeCreationForAutomation = nil; onSubmissionForAutomation = nil
    #endif
    pendingURL = nil
    host?.historyRecorder.flushBeforeClose()
    factory.standaloneSurface = nil
    factory.standaloneSurfaceVisibilityChanged()
    factory.closeAll()
    browser?.close(); browser = nil
    factory.standaloneBrowser = nil
    app.littleOpenHosts[tabID] = nil
    host = nil
  }
}

/// Stable slot content across deferred page creation and container slot reuse.
@MainActor
final class LittleOpenSurfaceView: NSView {
  weak var owner: LittleOpenWebContent?
}
