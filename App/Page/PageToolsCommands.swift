import AppKit
import OpenCommands
import OpenEngine

/// View ▸ Appearance, View ▸ Developer panels, Allow JavaScript from Apple Events,
/// Clear Cookies/Cache and Refresh, and Help ▸ Troubleshooting
/// (plans/page-platform.md §4.8–§4.12, §7.1; Section 8 page-platform Steps 5–6).
@MainActor
enum PageTools {
  /// Commands that need the focused page of a window.
  static let pageIDs: Set<String> = [
    "javascript-console", "inspect-elements", "network-inspector",
    "clear-cookies-and-refresh", "clear-cache-and-refresh",
  ]
  /// Commands that also run with no browser window (AppDelegate dispatch).
  static let appIDs: Set<String> = [
    "appearance-automatic", "appearance-light", "appearance-dark", "allow-js-apple-events",
    "task-manager", "record-trace", "cancel-trace", "copy-open-info", "reveal-open-data",
  ]
  static func handles(_ id: String) -> Bool { pageIDs.contains(id) || appIDs.contains(id) }

  /// Same defaults key as OpenScripting's `ScriptHost.allowJavaScriptFromAppleEventsKey`
  /// (the App does not link OpenScripting). Default false, Chromium's default (T-13, Q3).
  static let allowJavaScriptFromAppleEventsKey = "open.developer.allowJavaScriptFromAppleEvents"

  /// Per-site HTTP cache clearing is Site Control E2, which needs a fork patch
  /// (DevTools `Storage.clearDataForOrigin` has no HTTP cache type, and CEF can
  /// only clear every site's cache). Clear Cache and Refresh stays disabled
  /// until the engine reports per-site clearing (page-platform §4.9, D-12).
  static let siteDataClearAvailable = false

  /// Runtime menu state (page-platform §7.1, `CommandMenuState`): the Appearance radio
  /// checkmark on the stored value, the Allow JavaScript from Apple Events checkmark, and
  /// View ▸ Cast… hidden (Cast is out of v1, §4.12, Q2). Window and app dispatchers both ask.
  static func menuState(for id: String) -> CommandMenuState? {
    if WebsiteAppearance.commandIDs[id] != nil {
      return CommandMenuState(isChecked: WebsiteAppearance.commandID(for: WebsiteAppearance.current) == id)
    }
    switch id {
    case "allow-js-apple-events": return CommandMenuState(isChecked: UserDefaults.standard.bool(forKey: allowJavaScriptFromAppleEventsKey))
    case "cast": return CommandMenuState(isHidden: true)
    default: return nil
    }
  }

  /// http(s) page whose cookies or cache a site command may clear.
  static func isSitePage(_ url: URL?) -> Bool {
    guard let scheme = url?.scheme?.lowercased(), url?.host?.isEmpty == false else { return false }
    return scheme == "http" || scheme == "https"
  }

  /// App-level enabled state; nil when `id` is not one of these commands.
  static func isAppCommandEnabled(_ id: String) -> Bool? {
    switch id {
    case "record-trace": return OEEngine.shared.isRunning && !OEEngine.shared.isTracing
    case "cancel-trace": return TroubleshootingActions.shared.isRecording
    case "task-manager": return OEEngine.shared.isRunning
    default: return appIDs.contains(id) ? true : nil
    }
  }

  /// Runs an app-level command; false when `id` is not one of these.
  static func performAppCommand(_ id: String) -> Bool {
    if WebsiteAppearance.select(commandID: id) { MenuRefresh.request(); return true }
    let troubleshooting = TroubleshootingActions.shared
    switch id {
    case "allow-js-apple-events":
      let defaults = UserDefaults.standard
      defaults.set(!defaults.bool(forKey: allowJavaScriptFromAppleEventsKey), forKey: allowJavaScriptFromAppleEventsKey)
    case "task-manager": troubleshooting.showTaskManager()
    case "record-trace": troubleshooting.recordTrace()
    case "cancel-trace": troubleshooting.cancelTrace()
    case "copy-open-info": troubleshooting.copyOpenInfo()
    case "reveal-open-data": troubleshooting.revealOpenData()
    default: return false
    }
    MenuRefresh.request()
    return true
  }
}

/// Asks the app delegate for a menu rebuild (titles and checkmarks follow state).
@MainActor
enum MenuRefresh {
  static func request() { (NSApp.delegate as? AppDelegate)?.scheduleMenuRebuild() }
}

extension EngineWebContentHostFactory {
  /// nil when `id` is not a page-tools command.
  func isPageToolEnabled(_ id: String) -> Bool? {
    if let enabled = PageTools.isAppCommandEnabled(id) { return enabled }
    guard PageTools.pageIDs.contains(id) else { return nil }
    guard let page = selectedContent, page.isLive else { return false }
    switch id {
    case "clear-cookies-and-refresh": return PageTools.isSitePage(page.url)
    case "clear-cache-and-refresh": return PageTools.siteDataClearAvailable && PageTools.isSitePage(page.url)
    default: return true
    }
  }

  /// Runs a page-tools command; nil when `id` is not one of them.
  func performPageTool(_ id: String) -> Bool? {
    guard PageTools.handles(id) else { return nil }
    guard isPageToolEnabled(id) == true else { return false }
    if PageTools.appIDs.contains(id) { return PageTools.performAppCommand(id) }
    guard let page = selectedContent else { return false }
    switch id {
    // §4.10.1. Network (EP-4b) selects its panel through the DevTools front end.
    case "javascript-console": page.showDevTools(panel: .console)
    case "inspect-elements": page.showDevTools(panel: .inspectMode)
    case "network-inspector": page.showDevTools(panel: .network)
    case "clear-cookies-and-refresh": clearCookiesAndRefresh(page)
    case "clear-cache-and-refresh": return false  // disabled until E2 (siteDataClearAvailable)
    default: return false
    }
    return true
  }

  /// §4.9 interim (before Site Control E2): the host cookies of the focused page's
  /// host (`clearBrowsingData(origin:)`), then a reload. The reload is the feedback
  /// (no toast, guess). Peek: the top Peek page (`selectedContent`).
  private func clearCookiesAndRefresh(_ page: OEWebContent) {
    guard let url = page.url, PageTools.isSitePage(url),
      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    parts.path = "/"; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
    guard let origin = parts.url else { return }
    page.context.clearBrowsingData(origin: origin) { [weak page] in
      guard let page, page.isLive else { return }
      page.reload()
    }
  }
}
