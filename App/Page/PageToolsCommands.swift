import AppKit
import OpenCommands
import OpenFeatures
import OpenEngine

/// View ▸ Appearance, View ▸ Developer panels, Allow JavaScript from Apple Events,
/// Clear Cookies/Cache and Refresh, and Help ▸ Troubleshooting
/// (plans/page-platform.md §4.8–§4.12, §7.1; Section 8 page-platform Steps 5–6).
@MainActor
enum PageTools {
  /// Commands that need the focused page of a window.
  static let pageIDs: Set<String> = [
    "javascript-console", "inspect-elements", "network-inspector",
    "clear-cookies-and-refresh", "clear-cache-and-refresh", "toggle-developer-mode",
  ]
  /// Commands that also run with no browser window (AppDelegate dispatch).
  static let appIDs: Set<String> = [
    "appearance-automatic", "appearance-light", "appearance-dark", "allow-js-apple-events",
    "task-manager", "record-trace", "cancel-trace", "copy-open-info", "reveal-open-data",
  ]
  static func handles(_ id: String) -> Bool { pageIDs.contains(id) || appIDs.contains(id) }

  /// Same defaults key as OpenScripting's `ScriptHost.allowJavaScriptFromAppleEventsKey`
  /// (the shared value crosses the App scripting adapter). Default false (T-13, Q3).
  static let allowJavaScriptFromAppleEventsKey = "open.developer.allowJavaScriptFromAppleEvents"

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
    // Arc 1.172.2 shows Cancel Trace only while a trace records (absent from every runtime capture).
    case "cancel-trace": return CommandMenuState(isHidden: !TroubleshootingActions.shared.isRecording)
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
    case "clear-cookies-and-refresh", "clear-cache-and-refresh": return PageTools.isSitePage(page.url)
    case "toggle-developer-mode": return DeveloperMode.host(for: page.url) != nil
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
    case "clear-cookies-and-refresh": PageSiteDataCommands.clearAndRefresh(page, kinds: .cookies)
    case "clear-cache-and-refresh": PageSiteDataCommands.clearAndRefresh(page, kinds: .cache)
    case "toggle-developer-mode":
      // §4.10.3: the focused page's site; toast "Developer Mode On" / "Developer Mode Off".
      guard let host = DeveloperMode.host(for: page.url) else { return false }
      let on = DeveloperMode.toggle(host: host)
      controller?.toasts.show(ToastContent(title: on ? "Developer Mode On" : "Developer Mode Off"))
    default: return false
    }
    return true
  }

  /// Window menu state: page tools plus the focused page's Developer Mode title (§4.10.3).
  func pageMenuState(for id: String) -> CommandMenuState? {
    if id == "toggle-developer-mode" { return DeveloperMode.menuState(for: selectedContent?.url) }
    if id == "view-easels-notes" { return app.menuState(for: id) }
    // Arc 1.172.2 runtime titles (capture AX union): "Pin Tab" / "Unpin Tab" for the current tab and
    // "Pin Tabs" for a sidebar selection; "New Folder from Selection…" for a selection. Both commands
    // already act on the selection (`performSelectionAppCommand`). GUESS: "Unpin Tabs" when every
    // selected tab is pinned (not seen in a capture; Arc's sidebar menu has that title).
    if id == "pin-unpin-tab" || id == "new-folder", let context = controller?.context {
      let ids = context.selection.ids
      if id == "new-folder" { return ids.count >= 2 ? CommandMenuState(title: "New Folder from Selection…") : nil }
      if ids.count >= 2 { return CommandMenuState(title: ids.allSatisfy { model.isPinned(tabID: $0) } ? "Unpin Tabs" : "Pin Tabs") }
      guard let tab = selectedTab else { return nil }
      return CommandMenuState(title: model.isPinned(tabID: tab.id) ? "Unpin Tab" : "Pin Tab")
    }
    return PageTools.menuState(for: id)
  }
}
