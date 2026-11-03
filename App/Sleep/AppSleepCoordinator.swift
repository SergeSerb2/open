import AppKit
import OpenEngine
import OpenFeatures
import OpenModel
import OpenSettings
import OpenSleep
import OpenStore

/// The App's tab sleep (app-shell §4.7 Step G, memory-fork S6). One `SleepController` for
/// the whole app, built and started after the first web paint (startup T5), never before the
/// first window (T2) or the first page (T4). Before that every hook is a no-op: the
/// controller's init reads the phases the window factories already set.
///
/// Engine events reach the controller here, on every event and for background tabs too
/// (`docs/sleep.md`, hard adapter contract). Nothing here ticks: the controller's own pass is
/// the only timer, and it parks while no hidden tab can change without an event.
@MainActor
final class AppSleepCoordinator {
  unowned let app: AppDelegate
  private(set) var controller: SleepController?
  private(set) var adapter: EngineSleepAdapter?
  private(set) var store: RoutingSleepStore?
  private var powerObserver: (any NSObjectProtocol)?
  /// macOS Low Power Mode as the controller sees it (Battery Saver).
  private(set) var lowPowerMode = false
  /// The last controller log lines (wake latency, capture failures, fallbacks), newest last.
  private(set) var log: [String] = []
  /// Battery Saver toasts shown since launch (automation evidence).
  private(set) var batteryToasts: [String] = []
  private(set) var quitCapture: [String: Any] = [:]
  /// True after T5 started the controller's pass loop.
  private(set) var isStarted = false
  /// Set by the quit capture; nothing starts the controller again.
  private var quitting = false
  /// Automation builds move the controller's clock to test timed transitions.
  final class Clock { var offset: TimeInterval = 0 }
  let clock = Clock()
  #if OPEN_AUTOMATION
  /// Automation override of the low-power flag; nil follows macOS.
  var lowPowerOverride: Bool? { didSet { updateLowPower(announce: true) } }
  #endif

  init(app: AppDelegate) { self.app = app }

  // MARK: Lifecycle

  /// Builds the controller once (no timer yet). Needs the model, the data root and a ready engine.
  @discardableResult
  func prepare() -> SleepController? {
    if let controller { return controller }
    guard !quitting, app.engineReady, !app.shutdownPrepared, !app.terminationRequested, let model = app.model,
          let directories = app.directories else { return nil }
    let adapter = EngineSleepAdapter(app: app)
    let store = RoutingSleepStore(model: model, directories: directories)
    store.onError = { [weak self] in self?.record("store-error \($0)") }
    let visibility = app.media.visibility
    visibility.browserWindowControllers = app.windowControllers
    let clock = clock
    let controller = SleepController(model: model, engine: adapter, store: store, visibility: visibility,
                                     chromiumTag: OEEngine.shared.chromiumVersion,
                                     now: { Date().addingTimeInterval(clock.offset) })
    controller.onLog = { [weak self] in self?.record($0) }
    adapter.controller = controller
    self.adapter = adapter; self.store = store; self.controller = controller
    // Pages made before the controller existed (selected tabs at T4, automation pages).
    for factory in app.hostFactories.values {
      for (id, host) in factory.hosts where !host.closed && model.tab(id: id) != nil {
        controller.contentCreated(tabID: id)
        refreshPermissions(tabID: id, host: host)
      }
    }
    updateLowPower(announce: false)
    visibility.sleepController = controller
    visibility.visibilityChanged()
    return controller
  }

  /// T5: start the controller's pass loop and the Low Power Mode observer.
  func start() {
    guard !quitting, let controller = prepare() else { return }
    if powerObserver == nil {
      powerObserver = NotificationCenter.default.addObserver(
        forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.updateLowPower(announce: true) } }
    }
    controller.start()
    if !isStarted { LaunchTiming.shared.mark("sleepStarted") }
    isStarted = true
  }

  func stop() {
    isStarted = false
    controller?.stop()
    if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    powerObserver = nil
  }

  private func record(_ line: String) {
    log.append(line); if log.count > 500 { log.removeFirst(log.count - 500) }
    #if DEBUG
    FileHandle.standardError.write(Data("Open: \(line)\n".utf8))
    #endif
  }

  // MARK: Battery Saver

  private var currentLowPower: Bool {
    #if OPEN_AUTOMATION
    if let lowPowerOverride { return lowPowerOverride }
    #endif
    return ProcessInfo.processInfo.isLowPowerModeEnabled
  }

  /// Low Power Mode makes Automatic act as Aggressive (settings-library, Tab Sleeping group).
  /// A change while Open runs shows a toast in the front window (features-core §3.4 r17).
  private func updateLowPower(announce: Bool) {
    let on = currentLowPower
    controller?.lowPowerMode = on
    guard on != lowPowerMode else { return }
    lowPowerMode = on
    guard announce, controller != nil else { return }
    let title = on ? "Battery Saver Mode Activated" : "Battery Saver Mode Deactivated"
    batteryToasts.append(title)
    showToast(title)
  }

  /// The front window's ToastCenter (page-platform §4.1) with a Settings button that opens
  /// Settings ▸ Advanced, where the Tab Sleeping mode is (Arc shows a Settings accessory; its
  /// exact target is a guess).
  private func showToast(_ title: String) {
    guard let toasts = app.frontWindowController?.toasts else { return }
    let content = ToastContent(title: title, accessory: .button(symbol: "gearshape", accessibilityLabel: "Settings"))
    toasts.show(content) { [weak app] handle in
      handle.dismiss()
      app?.settingsPresenter.show(pane: .advanced)
    }
  }

  // MARK: Engine and App events

  /// A sidebar tab got a page (selection, background open, adoption, automation).
  func contentCreated(tabID: ItemID, host: EngineWebContentHost) {
    guard let controller, let adapter, app.model.tab(id: tabID) != nil, !adapter.creating.contains(tabID) else { return }
    let kind = adapter.contentReturned(tabID)
    controller.contentCreated(tabID: tabID)
    if let kind { controller.wakeStarted(tabID: tabID, kind: kind) }
    refreshPermissions(tabID: tabID, host: host)
  }

  /// A page closed outside sleep (tab close, archive, unload, cache trim, window close).
  /// The controller drops its content only when no window holds a page for the tab anymore.
  func hostClosed(tabID: ItemID) {
    guard let controller, let adapter, !adapter.closingForSleep, controller.liveContent.contains(tabID),
          adapter.hosts(tabID).isEmpty else { return }
    controller.tabClosed(tabID)
  }

  /// Every engine change of a sidebar tab's page, after the container updated the model.
  func pageChanged(_ host: EngineWebContentHost, changes: OEWebContentChange) {
    guard let controller, let tab = app.model.tab(id: host.tabID) else { return }
    let page = host.content
    if changes.contains(.URL), let url = page.url, url.absoluteString != "about:blank" {
      if tab.url != url { tab.url = url }
      refreshPermissions(tabID: tab.id, host: host)
      controller.tabDidCommit(tab.id)
    } else if changes.contains(.loading) || changes.contains(.live), !page.isLoading {
      // Load end: the 10 s loading grace starts now, also for background pages.
      controller.tabDidCommit(tab.id)
    }
    if changes.contains(.audio) { controller.tabAudioChanged(tab.id) }
    let capturing = page.isCapturingCamera || page.isCapturingMicrophone
    if tab.live.isCapturing != capturing { tab.live.isCapturing = capturing; controller.setNeedsPass() }
    if tab.live.devToolsOpen != page.hasDevTools { tab.live.devToolsOpen = page.hasDevTools; controller.setNeedsPass() }
  }

  /// Keys typed into a page: the form proxy until P-MEM-06 reports real edit state.
  func pageKeyDown(tabID: ItemID) {
    guard controller != nil, let tab = app.model.tab(id: tabID) else { return }
    tab.live.lastFormInteractionAt = Date().addingTimeInterval(clock.offset)
  }

  func downloadUpdated(_ download: OEDownload, factory: EngineWebContentHostFactory) {
    guard let controller, let page = download.webContent, let id = factory.tabID(for: page), app.model.tab(id: id) != nil else { return }
    let running = download.state == .pending || download.state == .inProgress
    let others = page.context.downloads.contains { $0 !== download && $0.webContent === page && ($0.state == .pending || $0.state == .inProgress) }
    if running || others { controller.downloading.insert(id) } else { controller.downloading.remove(id) }
  }

  /// Window, selection, split, Peek, Little Open, PiP or mini-player change.
  func visibilityChanged() {
    guard controller != nil else { return }
    app.media.visibility.browserWindowControllers = app.windowControllers
    app.media.visibility.visibilityChanged()
  }

  /// A Profile's notification permission may have changed (prompt answer, Site Control,
  /// automation). Refresh every page of that Profile.
  func permissionsChanged(context: OEBrowserContext?) {
    guard let controller else { return }
    for factory in app.hostFactories.values {
      for (id, host) in factory.hosts where !host.closed && (context == nil || host.content.context === context) {
        refreshPermissions(tabID: id, host: host)
      }
    }
    controller.setNeedsPass()
  }

  private func refreshPermissions(tabID: ItemID, host: EngineWebContentHost) {
    guard let tab = app.model.tab(id: tabID) else { return }
    var allowed = false
    let page = host.content
    if let url = page.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
       let name = url.host(), var origin = URLComponents(string: "\(scheme)://") {
      origin.host = name; origin.port = url.port
      if let originURL = origin.url {
        allowed = page.context.permissionState(for: .notifications, origin: originURL) == .allow
      }
    }
    if tab.live.notificationsAllowed != allowed { tab.live.notificationsAllowed = allowed; controller?.setNeedsPass() }
  }

  /// Settings or another input changed a Profile's sleep mode.
  func modeChanged() { controller?.setNeedsPass() }

  /// The hidden-host cache keeps pages the sleep gates protect.
  func protects(_ id: ItemID) -> Bool {
    guard let controller else { return false }
    switch controller.blockingGate(tabID: id, forDiscard: false) {
    case nil, .visible?, .loading?: return false
    default: return true
    }
  }

  /// chrome.tabs.discard of a hosted tab (engine-patches P1 "Discards"): the debug sleep
  /// path, which honors every never-sleep gate and refuses the visible tab. Answers at once;
  /// the discard runs on the next turn, outside the engine's call.
  func requestDiscard(tabID: ItemID) -> Bool {
    guard let controller = prepare(), controller.liveContent.contains(tabID),
          controller.blockingGate(tabID: tabID, forDiscard: true) == nil else { return false }
    Task { @MainActor [weak controller] in await controller?.debugSleepNow(tabID: tabID) }
    return true
  }

  // MARK: Quit

  /// Quit order step 1 (app-shell §5.3): capture every live page's history into the sleep
  /// stores and flush them. Bounded: quit continues after `limit` seconds, a save error is
  /// logged, and quit never waits on a renderer.
  func captureForQuit(limit: TimeInterval = 3) async {
    quitting = true
    guard let controller else { quitCapture = ["ran": false]; return }
    let started = ContinuousClock.now
    let capture = Task { @MainActor () -> String in
      do { try await controller.captureAllForQuit(); return "ok" } catch { return "error: \(error)" }
    }
    // The first of capture and deadline answers; a capture still running after the deadline
    // keeps going until the process exits, but quit does not wait for it.
    let race = QuitRace()
    let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
      race.continuation = continuation
      race.deadline = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(Int(limit * 1000)))
        race.finish("timeout")
      }
      Task { @MainActor in race.finish(await capture.value) }
    }
    race.deadline?.cancel()
    let elapsed = started.duration(to: .now).components
    let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    quitCapture = ["ran": true, "outcome": outcome, "ms": ms, "tabs": controller.liveContent.count]
    if outcome != "ok" { FileHandle.standardError.write(Data("Open: sleep quit capture \(outcome) after \(Int(ms)) ms\n".utf8)) }
    stop()
  }

  /// Wires one window: its hidden-host cache asks the sleep gates, and its visibility
  /// changes (selection, split focus, Peek, minimize, occlusion, full screen) reach the
  /// controller at once. Runs before the controller exists; the hooks check it on use.
  func attach(_ factory: EngineWebContentHostFactory) {
    guard let window = factory.controller else { return }
    window.container.retainsHiddenHost = { [weak self] id in self?.protects(id) == true }
    let previous = window.onVisibilityChange
    window.onVisibilityChange = { [weak self] in previous?(); self?.visibilityChanged() }
  }
}

/// One answer for the quit capture: capture result or deadline, whichever comes first.
@MainActor
private final class QuitRace {
  var continuation: CheckedContinuation<String, Never>?
  var deadline: Task<Void, Never>?
  func finish(_ outcome: String) {
    continuation?.resume(returning: outcome); continuation = nil
  }
}
