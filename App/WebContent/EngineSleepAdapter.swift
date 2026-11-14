import AppKit
import OpenEngine
import OpenModel
import OpenSleep

/// `SleepEngine` over the App's existing page hosts (app-shell §4.7 table, memory-fork §8.1).
/// It owns no page: every call goes to the `EngineWebContentHost` the window factories
/// already hold for the tab, so a tab never gets a second page object from sleep.
/// The fork's sleep API (memory-fork §5, OpenEngine "Tab sleeping"): renderer freeze, discard in
/// place (the page object and its tab identity stay), and back/forward history capture and
/// restore (OPNH v1, the same bytes as `SleepHistoryContainer`).
@MainActor
final class EngineSleepAdapter: SleepEngine {
  unowned let app: AppDelegate
  weak var controller: SleepController?
  /// Tabs this adapter discarded in place (the engine's own flag clears when the page loads
  /// again; this set tells the wake kind apart).
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
    let factories = app.windowControllers.compactMap { app.hostFactories[$0.windowID] }.filter { !$0.isIncognito }
    return factories.first { $0.visibleTabs.contains { $0.id == id } }
      ?? factories.first { factory in factory.focusedSpace.map { factory.space(for: id)?.id == $0.id } == true }
      ?? app.frontMainModelWindowController.flatMap { app.hostFactories[$0.windowID] }
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
    // A page discarded in place still exists: it reloads its current entry when shown.
    if !hosts(tabID).isEmpty { _ = contentReturned(tabID); return true }
    // A bad container makes the controller retry without history (memory-fork §7.3).
    var restore: OENavigationHistory?
    if let history {
      guard (try? SleepHistoryContainer(data: history.container)) != nil,
            let decoded = OENavigationHistory(container: history.container) else { return false }
      restore = decoded
    }
    guard let tab = app.model.tab(id: tabID), let factory = owningFactory(for: tabID) else { return false }
    creating.insert(tabID); defer { creating.remove(tabID) }
    if tab.url != url { tab.url = url }
    tab.live.sleepPhase = .live
    // No renderer until the page shows; the history goes in first (memory-fork §5.2).
    guard let content = factory.ensureContent(for: tab, history: restore) else { return false }
    if restore != nil {
      // The engine installs the history when it creates the page (the view enters the window).
      // Wait for its verdict, at most 3 s, in 20 ms steps (one wake, never while idle).
      for _ in 0..<150 where content.navigationHistoryRestore == .pending {
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      if content.navigationHistoryRestore == .failed {
        // The page loads the fallback URL with no back list. False makes the controller log
        // `sleep-restore-fallback` and retry without history; the retry finds this page.
        restoreFallbacks += 1
        return false
      }
    }
    _ = contentReturned(tabID)
    return true
  }
  /// Restores that fell back to the URL (corrupt or unreadable history; F4).
  private(set) var restoreFallbacks = 0

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
    // No call: the container shows and hides each page's view, and the engine follows the
    // view (P-MEM-01 makes Chromium see HIDDEN for a hidden hosted or Alloy view). Toggling
    // `isHidden` here would fight the container's pane slots.
  }

  func freeze(tabID: ItemID) -> Bool {
    // The renderer stops its timers, tasks and loads and keeps its memory (P-MEM-02). The
    // engine refuses a visible page; showing the page unfreezes it.
    let open = hosts(tabID)
    guard !open.isEmpty else { contentVanished(tabID); return false }
    if refuseForDevTools(tabID) { return false }
    return open.allSatisfy { $0.1.content.setPageFrozen(true) }
  }

  func discard(tabID: ItemID) async -> Bool {
    // In place (P-MEM-03): the renderer and frame tree go; the page object, its back/forward
    // list and its chrome.tabs identity stay. It reloads its entry when shown, with
    // `document.wasDiscarded`. The answer is the engine's re-check after it settled.
    let open = hosts(tabID)
    guard !open.isEmpty else { contentVanished(tabID); return false }
    if refuseForDevTools(tabID) { return false }
    var all = true
    for (_, host) in open {
      // Discard preserves isLive and has no WebContentChange bit. Invalidate
      // picker authority before the renderer disappears, including its UI flag.
      app.stores.boosts.existingEditorHost?.exitZap(tabID: tabID)
      let done = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        host.content.discard { c.resume(returning: $0) }
      }
      all = all && done
    }
    if all { discarded.insert(tabID) }
    return all
  }

  func wasDiscarded(tabID: ItemID) -> Bool {
    hosts(tabID).contains { $0.1.content.isDiscarded } || destroyed.contains(tabID)
  }

  func captureHistory(tabID: ItemID) -> SleepHistoryEnvelope? {
    // The page's whole back/forward list with scroll and form state (P-MEM-04), packed as
    // OPNH v1. Nil (a page with only its initial entry, or over a container limit) makes the
    // controller back off and retry.
    guard let (_, host) = hosts(tabID).first, let tab = app.model.tab(id: tabID) else { contentVanished(tabID); return nil }
    guard let history = host.content.captureNavigationHistory() else { return nil }
    return SleepHistoryEnvelope(
      container: history.container, currentIndex: history.currentIndex, entryCount: history.entryCount,
      currentURL: history.currentURL ?? host.content.url ?? tab.url,
      currentTitle: history.title.isEmpty ? tab.title : history.title, faviconURL: history.faviconURL,
      hasPageState: history.hasPageState, chromiumTag: OEEngine.shared.chromiumVersion, capturedAt: Date())
  }

  func hasUnloadHandlers(tabID: ItemID) -> Bool {
    // beforeunload or unload handlers in any frame (P-MEM-06).
    hosts(tabID).contains { $0.1.content.hasUnloadHandlers }
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
