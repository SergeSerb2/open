import AppKit

/// The only App API that reads or changes the system's HTTP(S) handlers.
/// Construction and activation only read state; only an explicit user action
/// calls makeDefault(), which lets macOS ask for consent.
@MainActor
final class DefaultBrowserService {
  static let schemes = ["http", "https"]
  var onChange: (([String: Bool]) -> Void)?
  private var lastState: [String: Bool] = [:]
  private var activationObserver: (any NSObjectProtocol)?

  init() {
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
  }

  func isDefault(forScheme scheme: String) -> Bool {
    guard Self.schemes.contains(scheme), let id = Bundle.main.bundleIdentifier,
      let probe = URL(string: "\(scheme)://example.com/"),
      let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
    else { return false }
    return Bundle(url: handler)?.bundleIdentifier == id
  }

  var isDefaultBrowser: Bool { Self.schemes.allSatisfy { isDefault(forScheme: $0) } }

  @discardableResult
  func refresh() -> [String: Bool] {
    let state = Dictionary(uniqueKeysWithValues: Self.schemes.map { ($0, isDefault(forScheme: $0)) })
    if state != lastState { lastState = state; onChange?(state) }
    return state
  }

  func makeDefault() async -> [String: Bool] {
    for scheme in Self.schemes {
      do {
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
      } catch {
        AppDelegate.commandLog("Default browser request for \(scheme) was not accepted: \(error.localizedDescription)")
      }
    }
    return refresh()
  }
}
