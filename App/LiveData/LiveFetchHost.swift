import AppKit
import OpenEngine
import OpenModel
import OpenWeb

/// One short-lived hidden page in a Profile (live-data §2.4, F2-report §6): loads an origin
/// page with the Profile's own cookies, runs one Open-owned script in Open's isolated world,
/// returns its JSON value, and closes the page. Alloy style, never in a window, never a
/// sidebar tab, so extensions' `chrome.tabs` does not see it. At most one runs at a time;
/// nothing exists before the first fetch.
@MainActor
final class LiveFetchHost {
  enum Failure: Error, Equatable { case noProfile, noWindow, timedOut(loading: Bool, url: String), loadFailed(String), busy }
  static let timeout: TimeInterval = 20
  private unowned let app: AppDelegate
  private var running = false
  /// Pages created and closed (automation read-back: the host must not leak pages).
  private(set) var created = 0
  private(set) var closed = 0

  init(app: AppDelegate) { self.app = app }

  /// Loads `url` in `profileID`, waits until it stops loading, then evaluates `script`
  /// (an async function body allowed: promises are awaited) in the Open world.
  func fetch(profileID: ProfileID, url: URL, script: String) async throws -> Any {
    // One page at a time: later fetches wait their turn (bounded by the same timeout).
    let queued = Date().addingTimeInterval(Self.timeout)
    while running { guard Date() < queued else { throw Failure.busy }; try await Task.sleep(for: .milliseconds(50)) }
    // A main-model window: a Blank Window's model holds only its own stand-in Profile.
    guard let factory = app.hostFactories.values.first(where: { !$0.isIncognito && $0.model === app.model }),
          let context = factory.context(for: profileID) else { throw Failure.noProfile }
    // Engine pages are created once their view is in a window (as the container's hidden cached
    // pages are). The fetch page sits hidden under the window's content view: never drawn, never a tab.
    // Checked before the page exists, so a missing window cannot leave an unclosed page.
    guard let root = app.frontWindowController?.contentView ?? app.windowControllers.first?.contentView else { throw Failure.noWindow }
    running = true
    defer { running = false }
    let config = OEWebContentConfiguration(context: context)
    config.runtimeStyle = .alloy
    let content = OEWebContent(configuration: config, url: nil)
    created += 1
    content.isMuted = true
    content.view.isHidden = true
    content.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
    root.addSubview(content.view, positioned: .below, relativeTo: nil)
    content.prepareForDisplay()
    defer { content.view.removeFromSuperview(); content.close(); closed += 1 }
    content.load(url)
    let deadline = Date().addingTimeInterval(Self.timeout)
    // Poll the engine's own loading state (no timer while idle: this loop lives only during a fetch).
    try await Task.sleep(for: .milliseconds(100))
    while content.isLoading || content.url == nil {
      guard Date() < deadline else { throw Failure.timedOut(loading: content.isLoading, url: content.url?.absoluteString ?? "") }
      try await Task.sleep(for: .milliseconds(100))
    }
    if content.crashState != .none { throw Failure.loadFailed("crashed") }
    return try await content.evaluateJavaScript(script, in: .open)
  }
}
