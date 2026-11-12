import AppKit
import OpenFeatures
import OpenModel

/// Arc's default Air Traffic Control route for Google Meet (docs/re/live-data.md §5: pref
/// `didSetDefaultGoogleMeetRoute`, toast "Meet links now open in your current Space!" with "Choose where they open",
/// `S:125771`, `S:125836`). The first external Meet link adds one rule — meet.google.com → the most recent Space —
/// unless a rule for Meet already exists, and the toast says so once. The user can change or delete the rule in
/// Settings ▸ Links. GUESS — capture pending (F2 item 8): the rule's exact form and the toast's placement.
@MainActor
final class MeetRoute {
  static let doneKey = "open.links.didSetDefaultMeetRoute"
  static let host = "meet.google.com"
  unowned let app: AppDelegate
  private var announcePending = false
  #if OPEN_AUTOMATION
  static var announcedForAutomation = 0
  #endif

  init(app: AppDelegate) { self.app = app }

  private static func isMeet(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased(), url.scheme == "https" || url.scheme == "http" else { return false }
    return host == Self.host
  }

  func prepare(_ url: URL) {
    guard Self.isMeet(url), !UserDefaults.standard.bool(forKey: Self.doneKey), let model = app.model else { return }
    UserDefaults.standard.set(true, forKey: Self.doneKey)
    let covered = model.routingRules.contains { rule in
      switch rule.match {
      case .hostEquals(let h), .hostContains(let h): return Self.host.contains(h.lowercased()) && !h.isEmpty
      case .urlPrefix(let p): return p.lowercased().contains(Self.host)
      }
    }
    guard !covered else { return }
    model.routingRules.append(RoutingRule(match: .hostEquals(Self.host), destination: .mostRecentSpace(profile: nil)))
    app.scheduleSave()
    announcePending = true
  }

  func announce(_ url: URL) {
    guard announcePending, Self.isMeet(url) else { return }
    announcePending = false
    #if OPEN_AUTOMATION
    Self.announcedForAutomation += 1
    #endif
    // The window the link just opened in.
    DispatchQueue.main.async { [weak app] in
      guard let app, let controller = app.frontStandardWindowController else { return }
      let content = ToastContent(title: "Meet links now open in your current Space!", subtitle: "Choose where they open",
        symbol: "video", accessory: .button(symbol: "gearshape", accessibilityLabel: "Choose where they open"), coalescingKey: "meet-route")
      controller.toasts.show(content) { [weak app] handle in
        handle.dismiss()
        _ = app.map { $0.hostFactories[controller.windowID]?.performAppCommand("air-traffic-control") }
      }
    }
  }
}
