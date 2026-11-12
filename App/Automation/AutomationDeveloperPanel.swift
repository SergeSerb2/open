#if OPEN_AUTOMATION
import AppKit
import OpenFeatures
import OpenDesign

extension AutomationController {
  /// `developer-panel` {action?: "state" | "press", button?: DeveloperPanelAction raw value}: the front window's
  /// developer bar (PB3 row 5). Presses go through the bar's own button (`performClick`), as a click would.
  func developerPanelCommand(_ a: [String: Any]) throws -> Any {
    guard let controller = app.frontWindowController, let factory = app.hostFactories[controller.windowID] else {
      throw Failure(message: "no browser window")
    }
    let current = controller.context.currentTab?.id
    let slot = controller.container.slots.first { $0.tabID == current } ?? controller.container.slots.first
    if (a["action"] as? String) == "press" {
      guard let raw = a["button"] as? String, let action = DeveloperPanelAction(rawValue: raw),
            let button = slot?.developerPanel?.button(action) as? NSButton else { throw Failure(message: "no developer bar or unknown button") }
      button.performClick(nil)
    }
    if (a["action"] as? String) == "hover" {
      // The pointer entering the button (its tracking area's callback), without moving the system pointer.
      guard let raw = a["button"] as? String, let action = DeveloperPanelAction(rawValue: raw), let panel = slot?.developerPanel
      else { throw Failure(message: "no developer bar or unknown button") }
      panel.pointer((a["inside"] as? Bool) ?? true, action)
    }
    // The Extensions card: run one row by title, through its press path.
    if let title = a["cardItem"] as? String {
      guard let card = factory.developerPanel.extensionsCard, let index = card.rowTitles.firstIndex(of: title) else { throw Failure(message: "no card row") }
      card.choose(index)
    }
    // The Split View menu: titles without opening it (a menu blocks), or run one row by title.
    var menuTitles: [String]?
    if let raw = a["menu"] as? String, let action = DeveloperPanelAction(rawValue: raw) {
      guard let menu = factory.developerPanel.menu(for: action) else { throw Failure(message: "no menu") }
      menuTitles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
      if let title = a["item"] as? String {
        guard let index = menu.items.firstIndex(where: { $0.title == title }), menu.items[index].isEnabled else { throw Failure(message: "no enabled item") }
        menu.performActionForItem(at: index)
      }
    }
    if (a["action"] as? String) == "reload-menu" {
      guard let title = a["item"] as? String, controller.sidebar.runDeveloperReloadItem(title) else { throw Failure(message: "no reload item") }
    }
    var state: [String: Any] = ["shown": slot?.developerPanel != nil, "toolbar": slot?.paneChrome != nil, "devtools": factory.developerPanel.state(slot?.tabID)]
    if let panel = slot?.developerPanel {
      state["frame"] = [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height]
      state["url"] = panel.urlString
      state["activePanel"] = panel.activePanel?.rawValue ?? ""
      state["palette"] = panel.paletteDescription
      state["hovered"] = panel.hovered?.rawValue ?? ""
      state["hoverPlate"] = panel.hoverPlateDescription ?? ""
      state["buttons"] = DeveloperPanelAction.allCases.compactMap { action -> [String: Any]? in
        guard let view = panel.button(action) else { return nil }
        return ["id": action.rawValue, "frame": [view.frame.minX, view.frame.minY, view.frame.width, view.frame.height], "label": view.accessibilityLabel() ?? "",
                "tooltip": action.tooltip.map { [$0.title] + $0.keys } ?? []]
      }
    }
    // Sidebar rows of the focused Space: host subtitle, title baseline and the dashed outline (pane 2).
    if let space = controller.context.focusedSpace {
      state["rows"] = space.today.compactMap { node -> [String: Any]? in
        guard case .tab(let tab) = node, var row = controller.sidebar.developerRowState(tabID: tab.id) else { return nil }
        row["url"] = tab.url.absoluteString; return row
      }
    }
    state["sidebarToolbar"] = controller.sidebar.developerToolbarState()
    if let tip = TooltipController.shared.visibleOrPendingTooltip { state["tooltip"] = [tip.title] + tip.keys }
    if let menuTitles { state["menu"] = menuTitles }
    if let card = factory.developerPanel.extensionsCard, let host = card.superview, let anchor = slot?.developerPanel?.button(.extensionsMenu) {
      let a = host.convert(anchor.bounds, from: anchor), f = card.frame
      // Gap from the button's bottom edge to the arrow tip, and the tip's x offset from the button's center.
      let gap = host.isFlipped ? f.minY - a.maxY : a.minY - f.maxY
      state["extensionsCard"] = ["rows": card.rowTitles, "size": [f.width, f.height], "arrowGap": gap,
                                 "arrowOffset": f.minX + card.arrowTipX - a.midX, "label": card.accessibilityLabel() ?? ""]
    }
    state["splitPanes"] = controller.splitController.split?.panes.count ?? 1
    state["splitOrientation"] = controller.splitController.split.map { $0.orientation == .horizontal ? "horizontal" : "vertical" } ?? ""
    if let page = slot?.contentHostView { state["pageFrame"] = [page.frame.minX, page.frame.minY, page.frame.width, page.frame.height] }
    return state
  }
}
#endif
