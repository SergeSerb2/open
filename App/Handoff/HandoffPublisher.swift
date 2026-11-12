import AppKit
import OpenEngine
import OpenFeatures

/// Handoff (Arc parity, feature-gap §3: Arc's Info.plist declares
/// `NSUserActivityTypes = [NSUserActivityTypeBrowsingWeb]`).
/// Publishes the key browser window's current page as a web-browsing activity,
/// so another Apple device can continue it. Incognito pages, non-web URLs and
/// windows without a page publish nothing. Updates are coalesced: a burst of
/// URL/title changes or tab switches makes one AppKit call.
@MainActor
final class HandoffPublisher {
  private unowned let app: AppDelegate
  private var activity: NSUserActivity?
  private var updateTask: Task<Void, Never>?
  private(set) var updateCount = 0

  init(app: AppDelegate) { self.app = app }

  var publishedURL: URL? { activity?.webpageURL }
  var publishedTitle: String? { activity?.title }

  func setNeedsUpdate() {
    guard updateTask == nil else { return }
    updateTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard let self, !Task.isCancelled else { return }
      self.updateTask = nil; self.update()
    }
  }

  /// Called from a page change. Only the visible page of the key window matters.
  func pageChanged(_ page: OEWebContent, changes: OEWebContentChange) {
    guard !changes.isDisjoint(with: [.URL, .title]) else { return }
    if page === currentPage() || activity != nil { setNeedsUpdate() }
  }

  func currentPage() -> OEWebContent? {
    guard let controller = app.frontWindowController else { return nil }
    return app.hostFactories[controller.windowID]?.selectedContent
  }

  private func update() {
    updateCount += 1
    guard !app.shutdownPrepared, let page = currentPage(), !page.context.isEphemeral,
      let url = page.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      invalidate(); return
    }
    if let activity, activity.webpageURL == url, activity.title == page.title { return }
    let next = activity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    next.isEligibleForHandoff = true
    next.isEligibleForSearch = false
    next.isEligibleForPublicIndexing = false
    next.webpageURL = url
    next.title = page.title.isEmpty ? nil : page.title
    if activity == nil { activity = next; next.becomeCurrent() } else { next.needsSave = true }
  }

  func invalidate() {
    activity?.invalidate(); activity = nil
  }
}

extension AppDelegate {
  func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
    userActivityType == NSUserActivityTypeBrowsingWeb
  }

  /// Resume: a page handed off from another device opens like an external link,
  /// through the same routing intake (Air Traffic Control rules, Little Open or Space).
  /// Guess — capture pending: Arc's exact destination for a resumed activity.
  func application(_ application: NSApplication, continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL,
      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
    linkIntake.handle(urls: [url], source: .unknown)
    return true
  }
}
