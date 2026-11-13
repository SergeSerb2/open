import AppKit
import OpenEngine
import OpenFeatures
import OpenDesign
import OpenModel
import OpenSidebar

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
    container.onDeveloperHover = { [weak self] _, action, view in
      if action == .captureWindow { self?.showPortraitCapture(anchor: view, hover: true) }
    }
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
    case .captureWindow: showPortraitCapture(anchor: view, hover: false)
    case .extensionsMenu: toggleExtensionsCard(anchor: view)
    case .splitMenu:
      menu(for: action)?.popUp(positioning: nil, at: CGPoint(x: 0, y: view.bounds.height + 4), in: view)
    case .siteSettings: controller.container.onSiteControls?(id)
    }
  }

  /// The Extensions Menu card (C-report-s10 PB3-a2, `m-ext.png`): "Add Extension…" and "Manage Extensions…" in the
  /// More options card layout (`ToolbarMorePopover.Layout.extensions`) with the "+" popover colours (C3 session 11).
  /// A second press on the button closes it.
  private(set) weak var extensionsCard: ToolbarMorePopover?
  func toggleExtensionsCard(anchor: NSView) {
    if let open = extensionsCard { open.dismiss(); return }
    guard let controller = factory.controller, let host = anchor.window?.contentView else { return }
    let card = ToolbarMorePopover(rows: [
      .init(title: "Add Extension…") { [weak controller] in controller?.performCommand("add-extension") },
      .init(title: "Manage Extensions…") { [weak controller] in controller?.performCommand("manage-extensions") },
    ], layout: .extensions)
    card.dark = anchor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    // The "+" popover's style (C3 session 11), from the bar's Space style and the window's appearance.
    if let bar = anchor.superview as? DeveloperContentPanelView {
      card.colors = PlusPopoverColors(style: bar.tooltipStyle, system: card.dark ? .dark : .light)
    }
    card.swallowsClick = { [weak anchor] location in
      guard let anchor else { return false }
      return anchor.bounds.contains(anchor.convert(location, from: nil))
    }
    card.present(in: host, under: anchor)
    extensionsCard = card
  }

  /// The Split View Menu (C-report-s10 PB3-a2): Arc's native menu with the four split directions.
  func menu(for action: DeveloperPanelAction) -> NSMenu? {
    guard let controller = factory.controller else { return nil }
    let menu = NSMenu(); menu.autoenablesItems = false
    func item(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
      let item = DeveloperMenuItem(title: title, action: #selector(DeveloperMenuItem.run), keyEquivalent: "")
      item.handler = run; item.target = item; return item
    }
    switch action {
    case .splitMenu:
      let split = controller.splitController
      for (title, edge) in [("Add Right Split", SplitDropOverlayView.Zone.right), ("Add Left Split", .left), ("", .center),
                            ("Add Top Split", .top), ("Add Bottom Split", .bottom)] {
        if title.isEmpty { menu.addItem(.separator()); continue }
        let row = item(title) { [weak split] in split?.addEmptyPane(edge: edge) }
        row.isEnabled = split.canAddPane; menu.addItem(row)
      }
    default: return nil
    }
    return menu
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

  /// Shows "Capture in Portrait Mode" for the Capture Window button. Hover and click both come here.
  /// Arc opens the Portrait Mode popover when the pointer rests on the button, anchored under it (C-report-s10).
  /// EZ's popover (PB2) sets `portraitCapturePresenter`; until then a click runs the existing portrait capture
  /// and a hover does nothing.
  func showPortraitCapture(anchor: NSView, hover: Bool) {
    portraitCaptureRequests += 1
    if let present = Self.portraitCapturePresenter { present(anchor); return }
    if !hover { factory.controller?.performCommand("capture-portrait") }
  }
  /// The Portrait Mode popover entry (EZ, PB2). It receives the button to anchor under.
  static var portraitCapturePresenter: (@MainActor (NSView) -> Void)?
  /// Requests that reached `showPortraitCapture` (verification).
  private(set) var portraitCaptureRequests = 0

  /// A tab's host closed (below: the menu item type).
  func forget(_ id: ItemID) { opened[id] = nil }

  #if OPEN_AUTOMATION
  func state(_ id: ItemID?) -> [String: Any] {
    guard let id else { return [:] }
    return ["activePanel": activePanel(id)?.rawValue ?? "", "hasDevTools": factory.hosts[id]?.content.hasDevTools ?? false,
            "portraitCaptureRequests": portraitCaptureRequests]
  }
  #endif
}

/// A menu row that runs a closure.
@MainActor
final class DeveloperMenuItem: NSMenuItem {
  var handler: (@MainActor () -> Void)?
  @objc func run() { handler?() }
}
