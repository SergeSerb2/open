import AppKit
import OpenEngine
import OpenFeatures
import OpenModel

/// Developer Mode's toolbar actions for one browser window (PB3 row 5).
/// Capture PB3-a (C-report-s6.md:273): Toggle Console, Toggle Network Panel and Inspect Element open the standard
/// Chromium DevTools on that panel, and the same button closes it. Arc docks DevTools at the page's right;
/// OpenEngine opens it in its own window until the engine can dock it (need written in E-questions.md, IMC 10:55).
@MainActor
final class DeveloperModePanel {
  unowned let factory: EngineWebContentHostFactory
  /// The toggle that last opened each tab's DevTools. Valid only while that page still has DevTools open.
  private var opened: [ItemID: DeveloperPanelAction] = [:]

  init(factory: EngineWebContentHostFactory) { self.factory = factory }

  func attach(_ container: WebContentContainer) {
    container.developerModeHosts = DeveloperMode.hosts
    container.developerActivePanel = { [weak self] in self?.activePanel($0) }
    container.onDeveloperAction = { [weak self] id, action, view in self?.perform(id, action, view) }
  }

  func hostsChanged() { factory.controller?.container.developerModeHosts = DeveloperMode.hosts }

  /// The pressed toggle of a tab: the panel this bar opened, while the page's DevTools is still open.
  func activePanel(_ id: ItemID) -> DeveloperPanelAction? {
    guard let panel = opened[id], factory.hosts[id]?.content.hasDevTools == true else { return nil }
    return panel
  }

  func perform(_ id: ItemID, _ action: DeveloperPanelAction, _ view: NSView) {
    guard let controller = factory.controller else { return }
    switch action {
    case .console, .network, .inspect: toggleDevTools(id, action)
    case .copyLink: controller.performCommand("copy-url")
    case .capture: controller.performCommand("capture-page")
    case .captureWindow: controller.performCommand("capture-portrait")
    case .extensionsMenu: controller.performCommand("manage-extensions")
    case .siteSettings: controller.container.onSiteControls?(id)
    case .splitMenu: controller.container.onPaneMenu?(id, view)
    }
  }

  /// The same button closes the DevTools it opened; another toggle moves the open DevTools to its panel.
  private func toggleDevTools(_ id: ItemID, _ action: DeveloperPanelAction) {
    guard let page = factory.hosts[id]?.content else { return }
    if activePanel(id) == action {
      page.closeDevTools(); opened[id] = nil
    } else {
      let panel: OEDevToolsPanel = action == .console ? .console : action == .network ? .network : .inspectMode
      _ = page.showDevTools(panel: panel); opened[id] = action
    }
    factory.controller?.container.developerPanelStateChanged()
  }

  /// A tab's host closed.
  func forget(_ id: ItemID) { opened[id] = nil }

  #if OPEN_AUTOMATION
  func state(_ id: ItemID?) -> [String: Any] {
    guard let id else { return [:] }
    return ["activePanel": activePanel(id)?.rawValue ?? "", "hasDevTools": factory.hosts[id]?.content.hasDevTools ?? false]
  }
  #endif
}
