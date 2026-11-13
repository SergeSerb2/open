import AppKit
import Observation
import OpenEngine
import OpenFeatures
import OpenModel
import OpenStore
import OpenWeb

/// The sole delegate of a tab page. Closed generations never update the model.
@MainActor
final class EngineWebContentHost: NSObject, WebContentHost, WebContentProviding, OEWebContentDelegate {
  private(set) var tabID: ItemID
  private(set) var spaceID: SpaceID?
  let profileID: ProfileID
  let content: OEWebContent
  weak var owner: EngineWebContentHostFactory?
  private(set) var closed = false
  private(set) var generation = 0
  let historyRecorder: AppHistoryRecorder
  var onURLChange: ((URL) -> Void)?
  var onTitleChange: ((String) -> Void)?
  var onLoadingChange: ((Bool) -> Void)?
  var onFaviconChange: ((Data?) -> Void)?
  var additionalKeyHandler: ((NSEvent) -> Bool)?
  var onCloseRequest: (() -> Void)?
  var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)?
  private(set) var pageBackgroundColor: NSColor?
  var onPageBackgroundChange: ((NSColor?) -> Void)?
  var onLiveStateChange: ((WebContentLiveState) -> Void)?
  private var cachedFaviconImage: NSImage?
  private var cachedFaviconPNG: Data?
  private var lastReportedFavicon: (key: String, data: Data, iconURL: URL)?
  private var faviconImagePageURL: URL?
  private var cachedFaviconURL: URL?
  private var faviconDocumentRevision = 0
  private var faviconEventForDocument = false
  private var faviconProbe: Task<Void, Never>?
  private var copiedFavicon: (url: URL, token: UUID)?
  private var backgroundGeneration = 0
  private var backgroundTask: Task<Void, Never>?
  var hasBackgroundTask: Bool { backgroundTask != nil }
  var liveState: WebContentLiveState {
    WebContentLiveState(isLoading: content.isLoading, progress: content.estimatedProgress,
      canGoBack: content.canGoBack, canGoForward: content.canGoForward,
      // Unresponsive (4) still has a renderer. Preserve the raw engine state;
      // only terminated renderers need a replacement page.
      isAudible: content.isAudible, isCrashed: content.crashState == .crashed
        || content.crashState == .killed || content.crashState == .outOfMemory)
  }
  var view: NSView { content.view }
  var currentURL: URL? { content.url }
  var title: String { content.title }
  var canGoBack: Bool { content.canGoBack }
  var canGoForward: Bool { content.canGoForward }
  var isLoading: Bool { content.isLoading }
  /// Capture, selection, and translation reach the page through this (page-platform §3.2).
  var webContent: (any WebContent)? { closed ? nil : content }
  var isPrivateBrowsing: Bool { content.context.isEphemeral }

  init(tabID: ItemID, profileID: ProfileID, content: OEWebContent, owner: EngineWebContentHostFactory) {
    self.tabID = tabID; self.profileID = profileID; self.content = content; self.owner = owner
    historyRecorder = AppHistoryRecorder(stores: owner.app.stores, profileID: profileID)
    spaceID = owner.space(for: tabID)?.id ?? owner.focusedSpace?.id
    super.init(); content.delegate = self
    // Tab pages draw Open's own swipe indicator (page-platform §4.4.3), not Chromium's arrow.
    content.drawsEngineHistorySwipeOverlay = false
    content.historySwipeEnabled = owner.historySwipeAllowed
    observeMute()
  }
  /// The engine follows the tab's mute, including Undo/Redo and Mute All (media-pip §7.2).
  private var muteObservation = 0
  private func observeMute() {
    muteObservation += 1
    let token = muteObservation
    guard !closed, let tab = owner?.model.tab(id: tabID) else { return }
    if content.isMuted != tab.isMuted { content.isMuted = tab.isMuted }
    withObservationTracking { _ = tab.isMuted } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.muteObservation == token else { return }
        self.observeMute()
        self.owner?.app.media.contentChanged(self, changes: .audio)
      }
    }
  }
  func load(_ url: URL) { if !closed, !WelcomeTab.isInternal(url) { content.load(url) } }
  func reload() { if !closed { content.reload() } }
  func stop() { if !closed { content.stopLoading() } }
  func goBack() { if !closed { content.goBack() } }
  func goForward() { if !closed { content.goForward() } }
  func focus() { if !closed { content.focusPage(); owner?.savePromptFocusChanged() } }
  func setPageCoveredBySnapshot(_ covered: Bool) {
    guard !closed else { return }
    // The explicit WasHidden path also covers Chrome's child-window host.
    // Releasing a snapshot must not wake a page parked or hidden elsewhere.
    content.setPageHidden(covered || view.window == nil || view.isHiddenOrHasHiddenAncestor)
  }
  func rebind(tabID: ItemID, spaceID: SpaceID?) {
    if tabID != self.tabID { owner?.app.stores.boosts.existingEditorHost?.exitZap(tabID: self.tabID) }
    generation += 1; self.tabID = tabID; self.spaceID = spaceID
    refreshPageBackground(); observeMute()
  }
  func close() {
    guard !closed else { return }; closed = true; generation += 1; muteObservation += 1
    historyRecorder.close()
    cancelBackgroundRead(); faviconProbe?.cancel(); faviconProbe = nil
    onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil; shouldNavigate = nil
    onPageBackgroundChange = nil; onLiveStateChange = nil
    additionalKeyHandler = nil; onCloseRequest = nil
    cachedFaviconImage = nil; cachedFaviconPNG = nil; cachedFaviconURL = nil; faviconImagePageURL = nil; lastReportedFavicon = nil
    owner?.pageChrome.cancel(content)
    content.delegate = nil; content.close(); content.view.removeFromSuperview()
    owner?.hostDidClose(self)
  }

  func webContent(_ page: OEWebContent, didChange changes: OEWebContentChange) {
    guard !closed, let owner else { return }
    let token = generation
    if (changes.contains(.loading) && page.isLoading) ||
      (changes.contains(.live) && !page.isLive) || changes.contains(.crash) {
      owner.app.stores.boosts.existingEditorHost?.exitZap(tabID: tabID)
    }
    if changes.contains(.loading) || changes.contains(.live) || changes.contains(.crash) {
      owner.app.stores.boosts.existingEditorHost?.pickerAvailabilityChanged(tabID: tabID)
    }
    if changes.contains(.loading), page.isLoading { historyRecorder.loadingChanged(true) }
    if changes.contains(.URL), let url = page.url, url.absoluteString != "about:blank" {
      // OEWebContent still exposes the previous document's favicon here.
      // A committed URL alone never proves ownership of those pixels.
      faviconDocumentRevision += 1; faviconEventForDocument = false
      faviconProbe?.cancel(); faviconProbe = nil; copiedFavicon = nil
      onURLChange?(url); cancelBackgroundRead(); pageBackgroundColor = nil; onPageBackgroundChange?(nil)
    }
    guard !closed, generation == token else { return }
    if changes.contains(.URL) || changes.contains(.security), owner.controller?.siteControl != nil {
      owner.siteControlSource.refresh(tabID: tabID)
    }
    // CEF's OnLoadStart excludes same-document commits. Address changes outside
    // a document load cover pushState/fragments without duplicating that hook.
    if changes.contains(.URL), let url = page.url {
      if !page.isLoading { owner.app.stores.boosts.pageCommitted(self, url: url) }
      historyRecorder.addressChanged(url, isLoading: page.isLoading, ephemeral: page.context.isEphemeral, title: page.title)
      // Live Folder triggers (PR created / reviewed): a static origin test first, so ordinary
      // navigations never create the Live Folder service.
      if !owner.isIncognito, LiveFolderService.isOnOrigin(url) {
        owner.app.liveFolders.addressChanged(tabID: tabID, url: url, space: owner.space(for: tabID))
      }
    }
    if changes.contains(.loading), !page.isLoading { historyRecorder.loadingChanged(false); historyRecorder.titleChanged(page.title) }
    if (changes.contains(.URL) || (changes.contains(.loading) && !page.isLoading)) { ThemeData.pageChanged(self, factory: owner) }
    if changes.contains(.title), !page.title.isEmpty { onTitleChange?(page.title); historyRecorder.titleChanged(page.title) }
    if changes.contains(.loading) || changes.contains(.live) { onLoadingChange?(page.isLoading) }
    guard !closed, generation == token else { return }
    if changes.contains(.favicon) {
      faviconDocumentRevision += 1; faviconEventForDocument = true
      lastReportedFavicon = nil
      faviconProbe?.cancel(); faviconProbe = nil
      revokeCopiedFavicon(owner: owner)
      let data = currentFaviconData(page)
      onFaviconChange?(data)
      confirmFaviconForDocument(page, owner: owner)
    }
    guard !closed, generation == token else { return }
    onLiveStateChange?(liveState)
    owner.app.media.contentChanged(self, changes: changes)
    owner.app.handoff.pageChanged(content, changes: changes)
    if changes.contains(.loading), !page.isLoading { refreshPageBackground() }
    // Same-document History API path changes do not emit another load finish.
    if !page.isLoading, !changes.isDisjoint(with: [.URL, .loading]) { confirmFaviconForDocument(page, owner: owner) }
    if !changes.isDisjoint(with: [.URL, .title]) { owner.scheduleSave() }
    // Share Quote follows the focused page's selection (page-platform §4.2.5, EP-3).
    if changes.contains(.selection) { owner.translate.syncStatus() }
    // Tab sleep's hard event contract: every change of every page, background tabs included.
    if !closed, generation == token { owner.app.tabSleep.pageChanged(self, changes: changes) }
    owner.record("change", page, ["changes": changes.rawValue])
  }
  /// Cache conversion by image identity, independent of the page key.
  private func currentFaviconData(_ page: OEWebContent) -> Data? {
    guard let image = page.favicon else {
      cachedFaviconImage = nil; cachedFaviconPNG = nil; cachedFaviconURL = nil; faviconImagePageURL = nil
      return nil
    }
    if cachedFaviconImage !== image {
      cachedFaviconImage = image
      cachedFaviconURL = page.faviconURL; faviconImagePageURL = page.url
      cachedFaviconPNG = EngineWebContentHostFactory.pngData(image)
    }
    return cachedFaviconPNG
  }

  private func revokeCopiedFavicon(owner: EngineWebContentHostFactory) {
    guard let copied = copiedFavicon, let cache = owner.app.stores.sidebarFavicons else { return }
    copiedFavicon = nil
    if cache.removeCopy(for: copied.url, token: copied.token) { return }
    // Backpressure keeps the report queue bounded even during a burst of nil
    // notifications. Capture no host or image while waiting for the worker.
    Task { @MainActor in
      while !cache.removeCopy(for: copied.url, token: copied.token) { await cache.flush() }
    }
  }

  /// The engine's faviconURL can also lag the URL callback. After loading, ask
  /// the committed document which icon it declares, then compare that URL with
  /// the engine image's URL. A changed/empty event invalidates this whole probe.
  private func confirmFaviconForDocument(_ page: OEWebContent, owner: EngineWebContentHostFactory) {
    guard !owner.isIncognito, !page.context.isEphemeral, !closed, !page.isLoading, owner.app.engineReady, !owner.app.terminationRequested,
          let url = page.url, let key = FaviconStore.cacheKey(url), let iconURL = page.faviconURL,
          let image = page.favicon, let data = currentFaviconData(page), cachedFaviconURL == iconURL else { return }
    let isReport = faviconEventForDocument
    if !isReport {
      // Suppressed same-icon events may cover another path, but never infer
      // ownership across origins. The DOM check below also rejects no-icon pages.
      guard let source = faviconImagePageURL, Self.sameOrigin(source, url) else { return }
    }
    if lastReportedFavicon?.key == key, lastReportedFavicon?.data == data,
       lastReportedFavicon?.iconURL == iconURL { return }
    faviconProbe?.cancel()
    let revision = faviconDocumentRevision, token = generation
    faviconProbe = Task { @MainActor [weak self, weak owner] in
      guard let self, let owner else { return }
      defer { if self.faviconDocumentRevision == revision { self.faviconProbe = nil } }
      let script = """
      (() => { const link=document.querySelector('link[rel~="icon" i]');
        const icon=link ? link.href : new URL('/favicon.ico', location.href).href;
        return [location.href.slice(0,8193), icon.length <= 8192 ? icon : '']; })()
      """
      await owner.app.deferAsyncEngineWorkForAutomation()
      guard !Task.isCancelled, !self.closed, !owner.app.terminationRequested else { return }
      owner.app.noteAsyncEngineCall("faviconOwnership")
      let document = try? await page.evaluateJavaScript(script) as? [String]
      guard !Task.isCancelled, !self.closed, self.generation == token,
            self.faviconDocumentRevision == revision, page.url == url,
            page.favicon === image, page.faviconURL == iconURL,
            let document, document.count == 2, URL(string: document[0]) == url,
            URL(string: document[1]) == iconURL, let cache = owner.app.stores.sidebarFavicons else { return }
      let copyToken = isReport ? nil : UUID()
      if cache.report(data, for: url, iconURL: iconURL, copyToken: copyToken) {
        self.lastReportedFavicon = (key, data, iconURL)
        if let copyToken { self.copiedFavicon = (url, copyToken) }
      }
    }
  }

  private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    guard let first = FaviconStore.cacheKey(a), let second = FaviconStore.cacheKey(b) else { return false }
    return first.split(separator: "\n", maxSplits: 1).first == second.split(separator: "\n", maxSplits: 1).first
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
  func webContent(_ page: OEWebContent, shouldNavigateTo url: URL, userGesture: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
    guard !closed, !WelcomeTab.isInternal(url) else { return false }
    owner?.record("navigationPolicy", page, ["url": url.absoluteString, "modifiers": modifiers.rawValue, "userGesture": userGesture])
    return !userGesture || shouldNavigate?(url, modifiers) != false
  }
  func webContentDidRequestClose(_ page: OEWebContent) {
    guard !closed else { return }
    if owner?.pageChrome.pageRequestedClose(page) == true { return }
    if let onCloseRequest {
      // Match the main-window close path: retire the standalone host only
      // after Chromium's delegate callback returns.
      DispatchQueue.main.async { [weak self] in
        guard self?.closed == false else { return }
        onCloseRequest()
      }
    } else { owner?.webContentDidRequestClose(page) }
  }
  func webContent(_ page: OEWebContent, handleKeyEventBeforePage event: NSEvent) -> Bool {
    guard !closed else { return false }
    if owner?.pageChrome.handleKey(event) == true { return true }
    if additionalKeyHandler?(event) == true { return true }
    if owner?.controller?.handleKeyDown(event) == true { return true }
    // A key the page receives: tab sleep's form proxy (discard waits 5 min after typing).
    if event.type == .keyDown { owner?.app.tabSleep.pageKeyDown(tabID: tabID) }
    return false
  }
  func webContent(_ page: OEWebContent, handleUnconsumedKeyEvent event: NSEvent) -> Bool {
    !closed && (additionalKeyHandler?(event) == true || owner?.controller?.handleKeyDown(event, unconsumed: true) == true)
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
  func webContent(_ page: OEWebContent, didReceiveOpenWorldMessage type: String, payloadJSON: String, documentID: String) {
    if !closed { owner?.webContent(page, didReceiveOpenWorldMessage: type, payloadJSON: payloadJSON, documentID: documentID) }
  }
  func webContent(_ page: OEWebContent, didRequestFullscreen fullscreen: Bool) { if !closed { owner?.webContent(page, didRequestFullscreen: fullscreen) } }
  /// Chromium's history swiper (page-platform EP-1): the factory records it; Step 12 draws Open's
  /// indicator from it.
  func webContent(_ page: OEWebContent, historySwipe phase: OEHistorySwipePhase, direction: OEHistorySwipeDirection, progress: Double) {
    if !closed { owner?.webContent(page, historySwipe: phase, direction: direction, progress: progress) }
  }
  func webContent(_ page: OEWebContent, didCommitNavigationTo url: URL, isReload: Bool) {
    guard !closed else { return }
    owner?.app.stores.boosts.pageCommitted(self, url: url, newDocument: true)
    owner?.findController?.didNavigate(page)
    historyRecorder.committed(url: url, isReload: isReload, ephemeral: page.context.isEphemeral)
    owner?.record("historyCommit", page, ["url": url.absoluteString, "reload": isReload])
  }
  func webContent(_ page: OEWebContent, didFinishLoadWithStatus status: Int) { if !closed { historyRecorder.titleChanged(page.title); refreshPageBackground(); if let owner { confirmFaviconForDocument(page, owner: owner) }; owner?.webContent(page, didFinishLoadWithStatus: status) } }
  func webContent(_ page: OEWebContent, didFailLoadWithError error: any Error) { if !closed { historyRecorder.navigationFailed(); owner?.webContent(page, didFailLoadWithError: error) } }
  func webContent(_ page: OEWebContent, didReceiveDevToolsEvent method: String, parameters: [String: Any]) { if !closed { owner?.webContent(page, didReceiveDevToolsEvent: method, parameters: parameters) } }
  func webContent(_ page: OEWebContent, didLogConsoleMessage message: String, level: Int, source: String, line: Int) { if !closed { owner?.webContent(page, didLogConsoleMessage: message, level: level, source: source, line: line) } }
}
