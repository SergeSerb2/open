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

  /// The last page activation (P1), so a click can tell whether its page answered.
  private var lastActivation: (tab: ItemID, at: Date)?
  /// Recent clicks and what Open did (automation evidence).
  private(set) var log: [[String: Any]] = []

  func pageRequestedActivation(tab: ItemID) { lastActivation = (tab, Date()) }

  func clicked(app: AppDelegate, context: OEBrowserContext, identifier: String, origin: URL, persistent: Bool) {
    let clickedAt = Date()
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay) { [weak self, weak app, weak context] in
      MainActor.assumeIsolated {
        guard let self, let app, let context else { return }
        var entry: [String: Any] = ["id": identifier, "origin": origin.absoluteString, "persistent": persistent]
        defer { self.log.append(entry); if self.log.count > 20 { self.log.removeFirst() } }
        if let activation = self.lastActivation, activation.at >= clickedAt,
           app.model.tab(id: activation.tab).map({ Self.sameOrigin($0.url, origin) }) == true {
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
  private static func fallbackTab(app: AppDelegate, context: OEBrowserContext, origin: URL) -> (EngineWebContentHostFactory, Tab)? {
    var best: (EngineWebContentHostFactory, Tab)?
    // Only windows of the main model hold its Spaces (a Blank Window has a model of its own).
    for factory in app.hostFactories.values where factory.model === app.model {
      guard let profile = factory.profile(for: context) else { continue }
      for space in app.model.spaces where space.profileID == profile.id {
        for tab in factory.flattened(space.pinned) + factory.flattened(space.today) where sameOrigin(tab.url, origin) {
          if best == nil || tab.lastActiveAt > best!.1.lastActiveAt { best = (factory, tab) }
        }
      }
    }
    return best
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
