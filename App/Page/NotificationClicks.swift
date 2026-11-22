import AppKit
import OpenEngine
import OpenModel

/// Web notification click → tab (page-platform §4.5.4). The engine reports every click before
/// Chromium dispatches it to the page (EP-6, fork patch 0504). A page whose click handler calls
/// `focus()` selects its tab through P1 (`browser(_:requestsActivationOf:)`). If no such request
/// arrives within 500 ms, Open selects the most recently active tab of the clicked context's
/// profile whose URL has the notification's origin; with none, it does nothing beyond the app
/// activation macOS already did. One-shot work per click; nothing runs while idle.
@MainActor
final class NotificationClickRouter {
  static let shared = NotificationClickRouter()
  static let fallbackDelay: TimeInterval = 0.5

  /// The last page activation (P1), so a click can tell whether its page answered: its tab in
  /// the model of the window that showed it, and the page's URL then.
  private var lastActivation: (tab: ItemID, url: URL?, at: Date)?
  /// Recent clicks and what Open did (automation evidence).
  private(set) var log: [[String: Any]] = []

  /// A tab of any window counts, also a Blank Window's (its own model, not `app.model`): the
  /// fallback then raised another window over the page that had just answered (bug sweep r7 AB-02).
  func pageRequestedActivation(tab: ItemID, url: URL?) { lastActivation = (tab, url, Date()) }

  func clicked(app: AppDelegate, context: OEBrowserContext, identifier: String, origin: URL, persistent: Bool) {
    let clickedAt = Date()
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay) { [weak self, weak app, weak context] in
      MainActor.assumeIsolated {
        guard let self, let app, let context else { return }
        var entry: [String: Any] = ["id": identifier, "origin": origin.absoluteString, "persistent": persistent]
        defer { self.log.append(entry); if self.log.count > 20 { self.log.removeFirst() } }
        if let activation = self.lastActivation, activation.at >= clickedAt,
           activation.url.map({ Self.sameOrigin($0, origin) }) == true {
          entry["action"] = "page"; entry["tab"] = activation.tab.description
          return
        }
        guard let (factory, tab) = Self.fallbackTab(app: app, context: context, origin: origin) else {
          entry["action"] = "none"; return
        }
        factory.activateFromNotification(tabID: tab.id)
        entry["action"] = "fallback"; entry["tab"] = tab.id.description
      }
    }
  }

  static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased()
      && (a.port ?? defaultPort(a)) == (b.port ?? defaultPort(b))
  }
  private static func defaultPort(_ url: URL) -> Int? { url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil }

  /// The most recently active tab with the origin, in a window that shows its profile's Spaces.
  /// A Profile with no Space (its Favorites can outlive its last Space) has no destination. When
  /// several windows can show the tab, prefer the one that hosts its page, then one that already
  /// shows its Profile; never dictionary order.
  private static func fallbackTab(app: AppDelegate, context: OEBrowserContext, origin: URL) -> (EngineWebContentHostFactory, Tab)? {
    var best: (factory: EngineWebContentHostFactory, tab: Tab, rank: Int)?
    // Only windows of the main model hold its Spaces (a Blank Window has a model of its own).
    for factory in app.hostFactories.values where factory.model === app.model {
      guard let profile = factory.profile(for: context) else { continue }
      let spaces = app.model.spaces.filter { $0.profileID == profile.id }
      guard !spaces.isEmpty else { continue }
      // Favorites belong to the Profile, not to a Space: a webmail or chat Favorite is the usual
      // source of these notifications.
      let tabs = profile.favorites + spaces.flatMap { factory.flattened($0.pinned) + factory.flattened($0.today) }
      for tab in tabs where sameOrigin(tab.url, origin) {
        let rank = factory.hosts[tab.id] != nil ? 2 : factory.focusedSpace?.profileID == profile.id ? 1 : 0
        if let current = best, tab.lastActiveAt < current.tab.lastActiveAt
          || (tab.lastActiveAt == current.tab.lastActiveAt && rank <= current.rank) { continue }
        best = (factory, tab, rank)
      }
    }
    return best.map { ($0.factory, $0.tab) }
  }
}

extension EngineWebContentHostFactory {
  /// What a page's own `focus()` does (§4.5.4): the tab's Space in this window, the tab
  /// selected (which wakes it), the window in front (also from the Dock), Open active.
  func activateFromNotification(tabID: ItemID) {
    if let space = space(containing: tabID), space.id != focusedSpace?.id { focus(space: space) }
    select(nodeID: tabID)
    if let window = controller?.window {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    }
    NSApp.activate()
  }
}
