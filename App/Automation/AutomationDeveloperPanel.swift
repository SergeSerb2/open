#if OPEN_AUTOMATION
import AppKit
import OpenFeatures

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
    var state: [String: Any] = ["shown": slot?.developerPanel != nil, "toolbar": slot?.paneChrome != nil, "devtools": factory.developerPanel.state(slot?.tabID)]
    if let panel = slot?.developerPanel {
      state["frame"] = [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height]
      state["url"] = panel.urlString
      state["activePanel"] = panel.activePanel?.rawValue ?? ""
      state["palette"] = panel.paletteDescription
      state["buttons"] = DeveloperPanelAction.allCases.compactMap { action -> [String: Any]? in
        guard let view = panel.button(action) else { return nil }
        return ["id": action.rawValue, "frame": [view.frame.minX, view.frame.minY, view.frame.width, view.frame.height], "label": view.accessibilityLabel() ?? ""]
      }
    }
    // Sidebar rows of the focused Space: host subtitle, title baseline and the dashed outline (pane 2).
    if let space = controller.context.focusedSpace {
      state["rows"] = space.today.compactMap { node -> [String: Any]? in
        guard case .tab(let tab) = node, var row = controller.sidebar.developerRowState(tabID: tab.id) else { return nil }
        row["url"] = tab.url.absoluteString; return row
      }
    }
    if let page = slot?.contentHostView { state["pageFrame"] = [page.frame.minX, page.frame.minY, page.frame.width, page.frame.height] }
    return state
  }
}
#endif
