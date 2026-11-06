#if OPEN_AUTOMATION
import AppKit
import OpenBoosts
import OpenModel
import OpenSiteControl

extension AutomationController {
  func runBoostCommand(_ command: String, _ args: [String: Any]) async throws -> Any {
    let factory = try window
    let boosts = app.stores.boosts
    if command == "boosts" {
      if let raw = args["profile"] as? String, UUID(uuidString: raw) == nil { throw Failure(message: "invalid Profile ID") }
      let profile = (args["profile"] as? String).flatMap(UUID.init(uuidString:)).map { ProfileID(rawValue: $0) } ?? factory.focusedProfile?.id
      guard let profile, app.model.profile(id: profile) != nil else { throw Failure(message: "unknown Boost Profile") }
      let store = boosts.store(for: profile)
      if args["action"] as? String == "get" {
        guard let raw = args["boost"] as? String, let uuid = UUID(uuidString: raw), let boost = store.boost(id: BoostID(rawValue: uuid)) else { throw Failure(message: "unknown Boost") }
        return try boostJSON(boost)
      }
      guard args["action"] == nil || args["action"] as? String == "list" else { throw Failure(message: "unknown boosts action") }
      return try store.allBoosts().map(boostJSON)
    }
    guard let controller = factory.controller else { throw Failure(message: "no browser window") }
    let action = args["action"] as? String ?? "state"
    switch action {
    case "open":
      guard args["mode"] == nil || args["mode"] as? String == "simple" else { throw Failure(message: "blocked: code mode") }
      if let raw = args["tab"] as? String, UUID(uuidString: raw) == nil { throw Failure(message: "invalid tab ID") }
      let tab = (args["tab"] as? String).flatMap(UUID.init(uuidString:)).map { ItemID(rawValue: $0) } ?? factory.selectedTab?.id
      guard let tab, boosts.canEdit(tabID: tab) else { throw Failure(message: "Boost editing requires a non-private http(s) tab") }
      var id: BoostID?
      if let raw = args["boost"] as? String {
        guard let uuid = UUID(uuidString: raw) else { throw Failure(message: "invalid Boost ID") }; id = BoostID(rawValue: uuid)
      }
      guard let owner = boosts.factory(for: tab), let host = owner.hosts[tab], let target = owner.controller else { throw Failure(message: "no Boost editor window") }
      if let id, boosts.store(for: host.profileID).boost(id: id) == nil { throw Failure(message: "unknown Boost") }
      boosts.openEditor(boostID: id, tabID: tab, mode: .simple)
      guard target.boostEditor?.session != nil else { throw Failure(message: "could not open Boost editor") }
      return try boostEditorState(target.boostEditor)
    case "close": controller.boostEditor?.close()
    case "state": break
    case "drag":
      guard let editor = controller.boostEditor, let panel = editor.panel, let view = editor.view, let points = args["points"] as? [[Double]],
            (2...512).contains(points.count), points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { throw Failure(message: "drag needs 2...512 finite editor points") }
      guard editor.session?.colorsReady == true, editor.session?.showsInterstitial == false else { throw Failure(message: "editor colors are not ready") }
      guard points.allSatisfy({ view.pad.frame.contains(CGPoint(x: $0[0], y: $0[1])) }) else { throw Failure(message: "point outside color pad") }
      for (index, point) in points.enumerated() {
        let type: NSEvent.EventType = index == 0 ? .leftMouseDown : .leftMouseDragged
        let location = view.convert(CGPoint(x: point[0], y: point[1]), to: nil)
        if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: index, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
      }
      if let last = points.last {
        let location = view.convert(CGPoint(x: last[0], y: last[1]), to: nil)
        if let event = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: points.count, clickCount: 1, pressure: 0) { NSApp.sendEvent(event) }
      }
    case "key":
      guard let panel = controller.boostEditor?.panel else { throw Failure(message: "Boost editor is closed") }
      var input = args; input["window"] = panel.windowNumber; input["route"] = "app"
      _ = try await sendKey(input, factory)
    case "type":
      guard let editor = controller.boostEditor, let alert = editor.activeAlert, let field = alert.accessoryView as? NSTextField, let text = args["text"] as? String, text.utf8.count <= 16_384 else {
        throw Failure(message: "blocked: code mode; type supports the active rename field only (16 KiB)")
      }
      alert.window.makeKeyAndOrderFront(nil); alert.window.makeFirstResponder(field); field.selectText(nil)
      try await activateForInput(alert.window)
      // One native text event also represents composed input. Sending 16K
      // separate key pairs makes AppKit re-layout the growing field each time.
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: alert.window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0) { NSApp.sendEvent(event) }
      }
      try? await Task.sleep(for: .milliseconds(20))
    case "tap":
      guard let editor = controller.boostEditor, let view = editor.view, let id = args["id"] as? String else { throw Failure(message: "Boost editor is closed") }
      if id.hasPrefix("menu.") {
        let title = String(id.dropFirst(5)), menu = editor.makeMenu()
        guard let index = menu.items.firstIndex(where: { $0.title == title && $0.isEnabled }) else { throw Failure(message: "no enabled editor menu item") }
        menu.performActionForItem(at: index)
      } else if id.hasPrefix("alert.") {
        guard let alert = editor.activeAlert, let button = alert.buttons.first(where: { $0.title == String(id.dropFirst(6)) }) else { throw Failure(message: "no editor alert button") }
        button.performClick(nil)
      } else {
        let native: String
        if id == "firstRun.makeABoost" { native = "editor.make" }
        else if id.hasPrefix("font."), let index = BoostEditorFonts.available.firstIndex(where: { $0.name == String(id.dropFirst(5)) }) { native = "editor.font.\(index)" }
        else { native = id.hasPrefix("editor.") ? id : "editor.tool." + id }
        guard let button = view.control(id: native), button.isEnabled, !button.isHiddenOrHasHiddenAncestor, let panel = button.window else { throw Failure(message: "no enabled editor control") }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
          if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
        }
      }
    default: throw Failure(message: "unknown boost-editor action")
    }
    return try boostEditorState(controller.boostEditor)
  }
  private func boostJSON(_ boost: Boost) throws -> Any {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
    return try JSONSerialization.jsonObject(with: encoder.encode(boost))
  }
  private func boostEditorState(_ editor: BoostEditorController?) throws -> [String: Any] {
    let runtime = app.stores.boosts.adapter
    guard let editor, let session = editor.session, let panel = editor.panel, let view = editor.view else { return ["open": false, "refreshMs": runtime.lastRefreshMilliseconds, "refreshPages": runtime.lastRefreshPageCount] }
    let rect = view.pad.frame
    return ["open": true, "boost": try boostJSON(session.boost), "profile": session.context.profileID.description,
      "tab": session.context.tabID.description, "mode": "simple", "zap": false, "zapCount": session.boost.zaps.count,
      "canUndo": session.undoManager.canUndo, "undoCount": session.undoManager.groupingLevel + (session.undoManager.canUndo ? 1 : 0),
      "interstitial": session.showsInterstitial, "colorsReady": session.colorsReady, "globallyEnabled": session.globallyEnabled,
      "active": session.isActiveOnPage, "window": panel.windowNumber, "key": panel.isKeyWindow,
      "frame": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
      "pad": [rect.minX, rect.minY, rect.width, rect.height],
      "alert": editor.activeAlert.map { ["title": $0.messageText, "message": $0.informativeText, "buttons": $0.buttons.map(\.title)] as [String: Any] } ?? [:],
      "controls": view.controls.map { ["id": $0.controlID, "enabled": $0.isEnabled, "visible": !$0.isHiddenOrHasHiddenAncestor] },
      "refreshMs": runtime.lastRefreshMilliseconds, "refreshPages": runtime.lastRefreshPageCount,
      "refreshCount": runtime.refreshCount, "completedRefreshCount": runtime.completedRefreshCount]
  }
}
#endif
