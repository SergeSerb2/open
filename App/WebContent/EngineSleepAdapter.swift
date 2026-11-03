import AppKit
import OpenEngine
import OpenModel
import OpenSleep

/// `SleepEngine` over the App's existing page hosts (app-shell §4.7 table, memory-fork §8.1).
/// It owns no page: every call goes to the `EngineWebContentHost` the window factories
/// already hold for the tab, so a tab never gets a second page object from sleep.
/// Stock-engine fallbacks are marked `// Until P-MEM-0x`; PR G2 replaces them with the
/// fork's freeze, in-place discard and history capture/restore.
@MainActor
final class EngineSleepAdapter: SleepEngine {
  unowned let app: AppDelegate
  weak var controller: SleepController?
  /// Tabs whose page this adapter closed for a discard; `wasDiscarded` reads it.
  private(set) var discarded: Set<ItemID> = []
  /// Discarded tabs whose retained shell the controller then destroyed (24 h or critical).
  private(set) var destroyed: Set<ItemID> = []
  /// Tabs this adapter is creating content for (the factory's host hook skips them).
  private(set) var creating: Set<ItemID> = []
  /// True while this adapter closes hosts, so the App's close hook does not report a tab close.
  private(set) var closingForSleep = false
  private(set) var criticalCloses = 0

  init(app: AppDelegate) { self.app = app }

  /// Live hosts of a tab in every window (one per window that shows its Space).
  func hosts(_ id: ItemID) -> [(EngineWebContentHostFactory, EngineWebContentHost)] {
    app.hostFactories.values.compactMap { factory in
      factory.hosts[id].flatMap { $0.closed ? nil : (factory, $0) }
    }
  }

  /// The tab got content again (selection recreated it, or the controller woke it).
  /// Returns the wake kind the shell had, for the latency log.
  func contentReturned(_ id: ItemID) -> String? {
    if destroyed.remove(id) != nil { discarded.remove(id); return "destroyed" }
    if discarded.remove(id) != nil { return "discard" }
    return nil
  }

  /// The factory that should hold a new host: a window that shows the tab, else one whose
  /// focused Space holds it, else the front window.
  private func owningFactory(for id: ItemID) -> EngineWebContentHostFactory? {
    let factories = app.windowControllers.compactMap { app.hostFactories[$0.windowID] }
    return factories.first { $0.visibleTabs.contains { $0.id == id } }
      ?? factories.first { factory in factory.focusedSpace.map { factory.space(for: id)?.id == $0.id } == true }
      ?? app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
  }

  /// The controller believes a tab has content, but no host exists (a host failed or closed
  /// without the close hook). Report a close on the next turn, never inside the caller.
  private func contentVanished(_ id: ItemID) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.hosts(id).isEmpty, self.controller?.liveContent.contains(id) == true else { return }
      self.controller?.tabClosed(id)
    }
  }

  /// DevTools has no open/close event in OpenEngine; read it whenever sleep asks.
  private func refuseForDevTools(_ id: ItemID) -> Bool {
    let open = hosts(id).contains { $0.1.content.hasDevTools }
    if let tab = app.model.tab(id: id), tab.live.devToolsOpen != open { tab.live.devToolsOpen = open }
    return open
  }

  func createContent(tabID: ItemID, url: URL, history: SleepHistoryEnvelope?) async -> Bool {
    // Until P-MEM-04: validate the stored container like the fork bridge will (a bad one makes
    // the controller retry without history), then load its URL. Back/Forward are not restored.
    if let history, (try? SleepHistoryContainer(data: history.container)) == nil { return false }
    if !hosts(tabID).isEmpty { return true }
    guard let tab = app.model.tab(id: tabID), let factory = owningFactory(for: tabID) else { return false }
    creating.insert(tabID); defer { creating.remove(tabID) }
    if tab.url != url { tab.url = url }
    tab.live.sleepPhase = .live
    guard factory.ensureContent(for: tab) != nil else { return false }
    _ = contentReturned(tabID)
    return true
  }

  func destroyContent(tabID: ItemID) {
    if discarded.remove(tabID) != nil { destroyed.insert(tabID) }
    let open = hosts(tabID)
    guard !open.isEmpty else { return }
    let phase = app.model.tab(id: tabID)?.live.sleepPhase
    close(open)
    // The container resets a closed tab to a placeholder; a destroyed shell stays sleeping.
    if phase == .sleeping { app.model.tab(id: tabID)?.live.sleepPhase = .sleeping }
  }

  func setVisible(tabID: ItemID, visible: Bool) {
    // Until P-MEM-01: no call. The container hides the view of every tab that leaves a pane
    // slot (Chromium throttles hidden views), and the window server hides minimized and
    // occluded windows. Toggling `isHidden` here would fight the container's slots.
  }

  func freeze(tabID: ItemID) -> Bool {
    // Until P-MEM-02: no renderer freeze. A hidden page is already throttled by its hidden
    // view; "frozen" records the phase only. True only if the page exists.
    let open = hosts(tabID)
    guard !open.isEmpty else { contentVanished(tabID); return false }
    if refuseForDevTools(tabID) { return false }
    for (_, host) in open where host.view.superview == nil { host.view.isHidden = true }
    return true
  }

  func discard(tabID: ItemID) async -> Bool {
    // Until P-MEM-03: close the page (renderer released), keep the sidebar row. The tab
    // wakes by a new host that loads `tab.url` when it is shown again.
    let open = hosts(tabID)
    guard !open.isEmpty else { contentVanished(tabID); return false }
    if refuseForDevTools(tabID) { return false }
    close(open)
    discarded.insert(tabID)
    return true
  }

  func wasDiscarded(tabID: ItemID) -> Bool {
    // Until P-MEM-03: the adapter's own record, not an engine flag.
    discarded.contains(tabID)
  }

  func captureHistory(tabID: ItemID) -> SleepHistoryEnvelope? {
    // Until P-MEM-04: OpenEngine has no navigation-history capture. A nil capture would keep
    // every tab frozen (the controller backs off and retries), so this returns a minimal
    // envelope: one opaque entry with the current URL, no page state. Wake loads that URL.
    guard let (_, host) = hosts(tabID).first, let tab = app.model.tab(id: tabID) else { contentVanished(tabID); return nil }
    let url = host.content.url ?? tab.url
    guard let container = try? SleepHistoryContainer(entries: [Data(url.absoluteString.utf8)], currentIndex: 0, hasPageState: false)
    else { return nil }
    return SleepHistoryEnvelope(
      container: container.encoded(), currentIndex: 0, entryCount: 1, currentURL: url,
      currentTitle: host.content.title.isEmpty ? tab.title : host.content.title, faviconURL: host.content.faviconURL,
      hasPageState: false, chromiumTag: "", capturedAt: Date())
  }

  func hasUnloadHandlers(tabID: ItemID) -> Bool {
    // Until P-MEM-06: unknown on stock CEF. Never guess true (app-shell §4.7).
    false
  }

  func handleCriticalPressure() {
    // Until the engine pressure hook: close hidden pages the sleep gates do not protect.
    // Deferred to the next turn: the controller calls this from inside its pass.
    DispatchQueue.main.async { [weak self] in
      guard let self, let controller = self.controller, !self.app.shutdownPrepared else { return }
      let visible = controller.visibleTabIDs()
      for factory in Array(self.app.hostFactories.values) {
        for (id, host) in factory.hosts where !host.closed && !visible.contains(id) && self.app.model.tab(id: id) != nil {
          guard controller.blockingGate(tabID: id, forDiscard: true) == nil else { continue }
          // An ordinary close: the App's close hook tells the controller (placeholder, no shell).
          factory.controller?.container.closeHost(for: id); host.close()
          self.criticalCloses += 1
        }
      }
    }
  }

  private func close(_ open: [(EngineWebContentHostFactory, EngineWebContentHost)]) {
    closingForSleep = true
    defer { closingForSleep = false }
    for (factory, host) in open {
      factory.controller?.container.closeHost(for: host.tabID)
      if !host.closed { host.close() }
    }
  }
}
