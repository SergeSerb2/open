import AppKit
import OpenEngine
import OpenFeatures
import OpenModel

/// Developer Mode's content panel for one browser window (PB3 row 5): the developer bar's buttons and the
/// per-tab network list, fed by DevTools protocol `Network.*` events of that tab's page.
/// Button targets reuse existing commands; the network list is Open's own (GUESS — capture PB3-a).
@MainActor
final class DeveloperModePanel {
  unowned let factory: EngineWebContentHostFactory
  private var logs: [ItemID: NetworkLog] = [:]
  private var shown: Set<ItemID> = []

  init(factory: EngineWebContentHostFactory) { self.factory = factory }

  func attach(_ container: WebContentContainer) {
    container.developerModeHosts = DeveloperMode.hosts
    container.networkLogProvider = { [weak self] in self?.logs[$0] }
    container.onDeveloperAction = { [weak self] id, action, view in self?.perform(id, action, view) }
    container.onCloseNetwork = { [weak self] in self?.closeNetwork($0) }
  }

  /// Developer Mode sites changed: lists of tabs that left Developer Mode close.
  func hostsChanged() {
    guard let container = factory.controller?.container else { return }
    container.developerModeHosts = DeveloperMode.hosts
    for id in shown {
      let host = factory.hosts[id]?.content.url.flatMap { DeveloperMode.host(for: $0) }
      if host.map({ !DeveloperMode.isOn(host: $0) }) ?? true { closeNetwork(id) }
    }
  }

  func perform(_ id: ItemID, _ action: DeveloperPanelAction, _ view: NSView) {
    guard let controller = factory.controller else { return }
    let page = factory.hosts[id]?.content
    switch action {
    case .console: page?.showDevTools(panel: .console)
    case .inspect: page?.showDevTools(panel: .inspectMode)
    case .network: if shown.contains(id) { closeNetwork(id) } else { openNetwork(id) }
    case .copyURL: controller.performCommand("copy-url")
    case .capture: controller.performCommand("capture-page")
    case .windowScreenshot: controller.performCommand("capture-portrait")
    case .extensions: controller.performCommand("manage-extensions")
    case .siteSettings: controller.container.onSiteControls?(id)
    case .splitMenu: controller.container.onPaneMenu?(id, view)
    }
  }

  func openNetwork(_ id: ItemID) {
    guard let page = factory.hosts[id]?.content else { return }
    if logs[id] == nil { logs[id] = NetworkLog() }
    shown.insert(id)
    page.sendDevToolsMethod("Page.enable", parameters: nil, completion: nil)
    page.sendDevToolsMethod("Network.enable", parameters: nil, completion: nil)
    factory.controller?.container.networkShownTabs = shown
  }

  func closeNetwork(_ id: ItemID) {
    guard shown.remove(id) != nil else { return }
    factory.hosts[id]?.content.sendDevToolsMethod("Network.disable", parameters: nil, completion: nil)
    logs[id] = nil
    factory.controller?.container.networkShownTabs = shown
  }

  /// Every DevTools event of this window's pages passes here; only tabs with an open list record.
  func event(_ method: String, parameters: [String: Any], page: OEWebContent) {
    guard !shown.isEmpty, method.hasPrefix("Network.") || method == "Page.frameNavigated",
          let id = shown.first(where: { factory.hosts[$0]?.content === page }) else { return }
    logs[id]?.handle(method, parameters)
  }

  /// A tab's host closed.
  func forget(_ id: ItemID) {
    guard shown.remove(id) != nil || logs[id] != nil else { return }
    logs[id] = nil
    factory.controller?.container.networkShownTabs = shown
  }

  #if OPEN_AUTOMATION
  var state: [String: Any] {
    ["shown": shown.map(\.description), "logs": Dictionary(uniqueKeysWithValues: logs.map { ($0.key.description, $0.value.entries.map {
      ["url": $0.url, "method": $0.method, "status": $0.status ?? NSNull(), "type": $0.type, "size": $0.size ?? NSNull(), "failed": $0.failed ?? NSNull()] as [String: Any]
    }) })]
  }
  #endif
}
