import Foundation
import OpenModel

extension EngineWebContentHostFactory {
  /// Lead decision: use only this Profile's saved Favorites and pinned tabs. No live
  /// mail/calendar discovery, network lookup, timer, or idle work.
  var peekEmailTab: Tab? {
    guard !isClosing, let profile = focusedProfile, let focusedSpace else { return nil }
    let spaces = [focusedSpace] + model.spaces.filter { $0.profileID == profile.id && $0.id != focusedSpace.id }
    return profile.favorites.first { Self.isWebmail($0.url) }
      ?? spaces.lazy.flatMap { self.flattened($0.pinned) }.first { Self.isWebmail($0.url) }
  }

  private static func isWebmail(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return false }
    if host == "www.icloud.com" { return url.path == "/mail" || url.path.hasPrefix("/mail/") }
    return ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
      "app.fastmail.com", "mail.proton.me", "mail.yahoo.com", "app.hey.com"].contains(host)
  }

  func peekEmail() -> Bool {
    guard let mail = peekEmailTab, let controller else { return false }
    // Peek needs a visible source tab. Resolve the saved tab's containing split and
    // focused pane when the command starts from an empty Space.
    if selectedTab == nil {
      selectTabForCommand(mail.id)
    }
    guard let source = selectedTab else { return false }
    controller.peekController.open(url: mail.url, sourceTabID: source.id)
    return controller.peekController.isShown
  }
}
