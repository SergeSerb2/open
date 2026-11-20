import AppKit
import OpenCommands

/// Developer Mode v1 (page-platform §4.10.3, lead answer Q6): a per-site on/off state with
/// Ctrl+D, the menu title "Turn on/off Developer Mode for this site", a toast, and the full URL
/// in the sidebar URL field for those sites. Anything more waits for capture C-D1. The Site
/// Control tile (Section 12) reads and toggles the same state through `isOn(host:)`/`toggle(host:)`.
@MainActor
enum DeveloperMode {
  static let hostsKey = "open.developer.modeHosts"
  /// At most this many hosts are kept (the oldest drop first); a host is at most 253 characters.
  static let maxHosts = 1_000
  static let didChange = Notification.Name("OpenDeveloperModeDidChange")

  /// An Incognito session's own changes on top of the regular list. Memory only: they end with the
  /// session and never reach the preferences.
  @MainActor final class SessionHosts {
    fileprivate var added: Set<String> = []
    fileprivate var removed: Set<String> = []
  }

  static var hosts: Set<String> { Set(stored) }
  /// The sites of a window: the regular list, with its Incognito session's changes when it has one.
  static func hosts(session: SessionHosts?) -> Set<String> {
    guard let session else { return hosts }
    return hosts.union(session.added).subtracting(session.removed)
  }
  private static var stored: [String] {
    (UserDefaults.standard.array(forKey: hostsKey) as? [String] ?? []).filter { !$0.isEmpty && $0.count <= 253 }
  }

  /// The site key of a page: its lowercased host, for http(s) and file pages ("" for file).
  static func host(for url: URL?) -> String? {
    guard let url, let scheme = url.scheme?.lowercased() else { return nil }
    if scheme == "file" { return "file" }
    guard scheme == "http" || scheme == "https", let host = url.host()?.lowercased(), !host.isEmpty, host.count <= 253 else { return nil }
    return host
  }

  static func isOn(host: String) -> Bool { stored.contains(host) }

  /// Turns the site's state over; returns the new state. An Incognito session changes only itself.
  @discardableResult
  static func toggle(host: String, session: SessionHosts? = nil) -> Bool {
    if let session {
      let on = !hosts(session: session).contains(host)
      // The same cap as the stored list: past it, a new site stays off.
      if on, session.added.count >= maxHosts { return false }
      if on { session.removed.remove(host); session.added.insert(host) } else { session.added.remove(host); session.removed.insert(host) }
      NotificationCenter.default.post(name: didChange, object: nil)
      return on
    }
    var list = stored
    let on: Bool
    if let i = list.firstIndex(of: host) { list.remove(at: i); on = false } else { list.append(host); on = true }
    if list.count > maxHosts { list.removeFirst(list.count - maxHosts) }
    UserDefaults.standard.set(list, forKey: hostsKey)
    NotificationCenter.default.post(name: didChange, object: nil)
    return on
  }

  /// Hidden for pages that are not http(s) or file; else the title of the next action.
  static func menuState(for url: URL?, session: SessionHosts? = nil) -> CommandMenuState {
    guard let host = host(for: url) else { return CommandMenuState(isHidden: true) }
    let on = hosts(session: session).contains(host)
    return CommandMenuState(title: on ? "Turn off Developer Mode for this site" : "Turn on Developer Mode for this site")
  }
}
