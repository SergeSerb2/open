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

  static var hosts: Set<String> { Set(stored) }
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

  /// Turns the site's state over; returns the new state.
  @discardableResult
  static func toggle(host: String) -> Bool {
    var list = stored
    let on: Bool
    if let i = list.firstIndex(of: host) { list.remove(at: i); on = false } else { list.append(host); on = true }
    if list.count > maxHosts { list.removeFirst(list.count - maxHosts) }
    UserDefaults.standard.set(list, forKey: hostsKey)
    NotificationCenter.default.post(name: didChange, object: nil)
    return on
  }

  /// Hidden for pages that are not http(s) or file; else the title of the next action.
  static func menuState(for url: URL?) -> CommandMenuState {
    guard let host = host(for: url) else { return CommandMenuState(isHidden: true) }
    return CommandMenuState(title: isOn(host: host) ? "Turn off Developer Mode for this site" : "Turn on Developer Mode for this site")
  }
}
