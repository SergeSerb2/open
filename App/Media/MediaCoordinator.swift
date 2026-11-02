import AppKit
import OpenEngine
import OpenFeatures
import OpenMedia
import OpenModel
import OpenSidebar
import OpenWeb

/// The App's media wiring (media-pip §7.2): one media store, one PiP session and
/// the auto-PiP rules for all windows. Everything runs on the main actor, from
/// engine change callbacks and window state changes; nothing here ticks.
@MainActor
final class MediaCoordinator {
  unowned let app: AppDelegate
  let store = MediaSourceStore()
  let session = PiPSession()
  let settings = MediaSettings()
  let rules: PiPSiteRules
  /// The tabs each window shows (selected tab or split panes of its focused Space).
  private(set) var displayed: [WindowID: Set<ItemID>] = [:]
  /// Automation evidence: the last auto-PiP decision per tab and when it ran.
  private(set) var decisions: [ItemID: (decision: AutoPiPPolicy.Decision, at: TimeInterval)] = [:]
  /// Automation evidence: when each tab's PiP request started and entered (system uptime).
  private(set) var pipTimes: [ItemID: (requested: TimeInterval, entered: TimeInterval?)] = [:]
  private(set) var pipRequests = 0
  /// Sleep feed (media-pip §4.10): read by AppVisibilityProvider; section 8's sleep adapter consumes it.
  let visibility: AppVisibilityProvider

  init(app: AppDelegate, rulesURL: URL?) {
    self.app = app
    visibility = AppVisibilityProvider(model: app.model)
    if let url = rulesURL, let data = try? Data(contentsOf: url), let custom = try? PiPSiteRules(data: data) {
      rules = custom
    } else if let bundled = try? PiPSiteRules.bundled() {
      rules = bundled
    } else {
      // The bundled file is part of OpenMedia; this branch only keeps a broken bundle from crashing.
      rules = try! PiPSiteRules(data: Data(#"{"version":1,"disallow":[],"sites":[]}"#.utf8))
    }
  }

  // MARK: Windows

  func attach(_ factory: EngineWebContentHostFactory) {
    guard let controller = factory.controller else { return }
    controller.context.media = store
    // The window controller refreshes after every selection, Space, split and visibility change.
    // Keep any hook another owner installed (the sleep adapter's AppVisibilityProvider).
    let previous = controller.onVisibilityChange
    controller.onVisibilityChange = { [weak self, weak factory] in
      previous?()
      if let self, let factory { self.windowChanged(factory) }
    }
    windowChanged(factory)
  }

  /// Window state changed (selection, Space, split, model edits, Undo). Computes leave
  /// events (§4.5.1) from the displayed set, so minimize, occlusion and app hide never
  /// produce one (D-4): they do not change it.
  func windowChanged(_ factory: EngineWebContentHostFactory) {
    let windowID = factory.windowState.id
    let now = Set(factory.visibleTabs.map(\.id))
    let old = displayed[windowID] ?? []
    guard now != old || displayed[windowID] == nil else { return }
    displayed[windowID] = now
    if factory.controller?.context.displayedTabIDs != now { factory.controller?.context.displayedTabIDs = now }
    for id in now.subtracting(old) {
      if let effect = session.displayed(tabID: id) { apply(effect) }
    }
    for id in old.subtracting(now) where app.model.tab(id: id) != nil {
      if let host = factory.hosts[id], !host.closed { leave(host, factory: factory) }
    }
    feedSleep()
  }

  func windowClosed(_ windowID: WindowID) {
    displayed[windowID] = nil
    store.removeWindow(windowID: windowID)
    feedSleep()
  }

  // MARK: Engine events

  func contentChanged(_ host: EngineWebContentHost, changes: OEWebContentChange) {
    guard !changes.isDisjoint(with: [.media, .audio, .mediaCapture, .pictureInPicture, .live, .crash]) else { return }
    sync(host)
  }

  /// A tab's page closed: tab close, archive, unload (sleep), crash teardown, window close.
  func hostClosed(tabID: ItemID) {
    store.remove(tabID: tabID)
    var minimized = false
    if case .minimized(let other) = session.state { minimized = other == tabID }
    if session.activeSource?.tabID == tabID || minimized {
      // The engine closes Chromium's PiP window with the page (§4.5.5).
      session.close(.sourceGone)
    }
    feedSleep()
  }

  private func sync(_ host: EngineWebContentHost) {
    guard !host.closed, let factory = host.owner, app.model.tab(id: host.tabID) != nil else { return }
    let content = host.content, id = host.tabID
    let state = Self.state(content.mediaSession)
    store.update(tabID: id, windowID: factory.windowState.id, state: state, isMuted: content.isMuted,
                 isCapturing: content.isCapturingCamera || content.isCapturingMicrophone)
    followPictureInPicture(tabID: id, inPiP: state.isPictureInPicture, playing: state.playback == .playing)
    feedSleep()
  }

  /// Phase 1 (§4.4.1): Chromium's own PiP window. The App learns of its Back to Tab and Close only
  /// as a PiP exit: a paused video means Close (snooze), a playing one means the user went back.
  private func followPictureInPicture(tabID: ItemID, inPiP: Bool, playing: Bool) {
    switch session.state {
    case let .requesting(id, _) where id == tabID:
      if inPiP { enter(tabID) }
    case let .active(id, _) where id == tabID:
      if !inPiP { session.close(playing ? .sourceShown : .userClosed); store.setPiP(tabID: tabID, .none) }
    default:
      if inPiP {
        // A PiP the page or Chromium's own menu started (manual, §4.8).
        if let replaced = session.request(tabID: tabID, automatic: false) { apply(replaced) }
        enter(tabID)
      }
    }
  }

  private func enter(_ tabID: ItemID) {
    session.didEnter(tabID: tabID)
    if case let .active(_, automatic) = session.state { store.setPiP(tabID: tabID, .active(auto: automatic)) }
    if let start = pipTimes[tabID], start.entered == nil { pipTimes[tabID] = (start.requested, ProcessInfo.processInfo.systemUptime) }
  }

  // MARK: Auto-PiP

  private func leave(_ host: EngineWebContentHost, factory: EngineWebContentHostFactory) {
    let content = host.content, id = host.tabID
    guard let url = content.url else { return }
    let media = content.mediaSession
    let decision = AutoPiPPolicy.decide(
      tabID: id, url: url, state: Self.state(media), audible: content.isAudible, event: .selection,
      settings: settings, rules: rules, session: session,
      disablePictureInPicture: media?.isPictureInPictureDisabled ?? false)
    decisions[id] = (decision, ProcessInfo.processInfo.systemUptime)
    guard decision == .open else { return }
    request(content, tabID: id, automatic: true)
  }

  private func request(_ content: OEWebContent, tabID: ItemID, automatic: Bool) {
    if let replaced = session.request(tabID: tabID, automatic: automatic) { apply(replaced) }
    pipRequests += 1
    pipTimes[tabID] = (ProcessInfo.processInfo.systemUptime, nil)
    content.requestPictureInPicture { [weak self] entered in
      guard let self else { return }
      guard case let .requesting(id, _) = self.session.state, id == tabID else { return }
      if entered { self.enter(tabID) } else { self.session.close(.failed) }
      self.feedSleep()
    }
  }

  /// Exits the PiP of the effect's tab (§4.5.5). The page keeps playing unless the effect pauses.
  private func apply(_ effect: PiPSession.Effect) {
    store.setPiP(tabID: effect.tabID, .none)
    guard effect.reason != .sourceGone, let content = page(effect.tabID) else { return }
    content.exitPictureInPicture(pausing: effect.pause)
  }

  // MARK: Sidebar intents

  func perform(_ intent: MediaIntent) -> Bool {
    switch intent {
    case .play(let id): page(id)?.mediaSession?.play(); store.noteInteraction(tabID: id)
    case .pause(let id): page(id)?.mediaSession?.pause(); store.noteInteraction(tabID: id)
    case .previousTrack(let id): page(id)?.mediaSession?.previousTrack(); store.noteInteraction(tabID: id)
    case .nextTrack(let id): page(id)?.mediaSession?.nextTrack(); store.noteInteraction(tabID: id)
    case .toggleMicrophone(let id): page(id)?.mediaSession?.toggleMicrophone(); store.noteInteraction(tabID: id)
    case .toggleCamera(let id): page(id)?.mediaSession?.toggleCamera(); store.noteInteraction(tabID: id)
    case .toggleMute(let id):
      guard let tab = app.model.tab(id: id) else { return false }
      app.model.setMuted(tabID: id, muted: !tab.isMuted)
      if let host = host(id) { host.content.isMuted = tab.isMuted; sync(host) }
      store.noteInteraction(tabID: id); app.scheduleSave()
    case .setVolume:
      // Tab volume needs the fork's EM-2; until then the volume button toggles mute (Q8).
      return false
    case .toggleVolumeDrawer: return true
    case .openPictureInPicture(let id):
      guard let content = page(id) else { return false }
      store.noteInteraction(tabID: id)
      request(content, tabID: id, automatic: false)
    case .close(let id):
      // Q5: Close pauses the source; the card stays away until it plays again.
      page(id)?.mediaSession?.pause(); store.dismiss(tabID: id)
    case .backToTab(let id):
      return backToTab(id)
    }
    feedSleep()
    return true
  }

  /// Selects the tab in its own window and Space and brings that window front (§4.2.3).
  @discardableResult
  func backToTab(_ id: ItemID) -> Bool {
    guard let factory = app.hostFactories.values.first(where: { $0.hosts[id] != nil }) ?? app.hostFactories.values.first(where: { $0.space(for: id) != nil }),
          app.model.tab(id: id) != nil else { return false }
    store.noteInteraction(tabID: id)
    factory.selectTabForCommand(id, spaceID: factory.space(for: id)?.id)
    factory.window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
    if session.activeSource?.tabID == id, let effect = session.close(.backToTab) { apply(effect) }
    feedSleep()
    return true
  }

  /// "Mute All Tabs": every tab with a live page, app-wide; "Unmute All Tabs": every muted tab.
  /// One undo step (media-pip §4.8, Q10).
  func muteAll(_ muted: Bool) {
    var ids: [ItemID]
    if muted {
      ids = app.hostFactories.values.flatMap { factory in
        factory.hosts.compactMap { id, host in !host.closed && self.app.model.tab(id: id) != nil ? id : nil }
      }
    } else {
      ids = app.model.index.values.compactMap { node in node.tab.flatMap { $0.isMuted ? $0.id : nil } }
    }
    ids = ids.filter { app.model.tab(id: $0)?.isMuted != muted }
    guard !ids.isEmpty else { return }
    let undo = app.undoManager
    undo.beginUndoGrouping()
    for id in ids { app.model.setMuted(tabID: id, muted: muted) }
    undo.endUndoGrouping()
    for id in ids { if let host = host(id) { host.content.isMuted = muted; sync(host) } }
    app.scheduleSave()
  }

  // MARK: Helpers

  private func host(_ id: ItemID) -> EngineWebContentHost? {
    for factory in app.hostFactories.values { if let host = factory.hosts[id], !host.closed { return host } }
    return nil
  }
  func page(_ id: ItemID) -> OEWebContent? { host(id)?.content }

  /// OEMediaSession → OpenWeb's engine-free value (§7.1). The action bits are the same.
  static func state(_ media: OEMediaSession?) -> WebMediaState {
    guard let media else { return WebMediaState() }
    let playback: WebMediaState.Playback
    switch media.playbackState {
    case .playing: playback = .playing
    case .paused: playback = .paused
    default: playback = .none
    }
    let actions = WebMediaActions(rawValue: UInt(media.actions.rawValue))
    let size = media.largestVideoSize
    return WebMediaState(
      playback: playback, isControllable: media.isControllable, hasVideo: media.hasVideo,
      largestVideoArea: Double(size.width * size.height), actions: actions, isPictureInPicture: media.isPictureInPicture,
      microphoneMuted: actions.contains(.toggleMicrophone) ? media.microphoneMuted : nil,
      cameraOn: actions.contains(.toggleCamera) ? media.cameraOn : nil,
      volume: nil, duration: media.position?.duration)
  }

  /// Media-pip §4.10. PiP sources and the tabs of shown mini players (plus controllable-less
  /// sessions) never freeze or discard. Section 8's sleep adapter reads `visibility`.
  func feedSleep() {
    var pip: Set<ItemID> = []
    if let source = session.activeSource { pip.insert(source.tabID) }
    var controls: Set<ItemID> = []
    for controller in app.windowControllers {
      guard let window = controller.window, window.isVisible, !window.isMiniaturized else {
        controls.formUnion(store.sourceList(windowID: controller.windowID).nonControllableTabIDs); continue
      }
      controls.formUnion(store.sleepProtectedTabIDs(windowID: controller.windowID, displayed: displayed[controller.windowID] ?? []))
    }
    visibility.browserWindowControllers = app.windowControllers
    guard visibility.pipTabIDs != pip || visibility.mediaControlTabIDs != controls else { return }
    visibility.pipTabIDs = pip; visibility.mediaControlTabIDs = controls
    visibility.visibilityChanged()
  }
}
