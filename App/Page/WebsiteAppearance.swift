import Foundation
import OpenEngine

/// View ▸ Appearance ("Websites will use:" Automatic, Light, Dark): one app-wide
/// value for every profile (plans/page-platform.md §4.8, D-7, Q9; Arc's menu is
/// app-level, PG-8.1). Every engine context gets it when it is created and when it
/// changes (EP-9a); open pages update without a reload.
@MainActor
enum WebsiteAppearance {
  static let defaultsKey = "open.web.colorScheme"
  static let commandIDs: [String: OEColorSchemePreference] = [
    "appearance-automatic": .automatic, "appearance-light": .light, "appearance-dark": .dark,
  ]

  /// The stored value; unknown or missing strings read as Automatic (§5).
  static var current: OEColorSchemePreference {
    switch UserDefaults.standard.string(forKey: defaultsKey) {
    case "light": .light
    case "dark": .dark
    default: .automatic
    }
  }

  static func commandID(for scheme: OEColorSchemePreference) -> String {
    switch scheme {
    case .light: "appearance-light"
    case .dark: "appearance-dark"
    default: "appearance-automatic"
    }
  }

  /// Sets the context's scheme. OEBrowserContext forwards only the first call
  /// and real changes to Chromium, so callers may run this on every lookup.
  @discardableResult
  static func prepare(_ context: OEBrowserContext) -> OEBrowserContext {
    context.websiteColorScheme = current
    return context
  }

  /// The `appearance-*` commands: store, then apply to every live context.
  static func select(commandID id: String) -> Bool {
    guard let scheme = commandIDs[id] else { return false }
    let value: String
    switch scheme {
    case .light: value = "light"
    case .dark: value = "dark"
    default: value = "automatic"
    }
    UserDefaults.standard.set(value, forKey: defaultsKey)
    applyToLiveContexts()
    return true
  }

  static func applyToLiveContexts() {
    guard OEEngine.shared.isRunning else { return }
    prepare(OEEngine.shared.defaultContext)
    for context in OEEngine.shared.contexts { prepare(context) }
  }
}
