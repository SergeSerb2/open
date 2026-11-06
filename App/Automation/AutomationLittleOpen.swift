#if OPEN_AUTOMATION
import AppKit
import OpenEngine
import OpenFeatures
import OpenModel
import OpenSleep
import Darwin

extension AppDelegate {
  func startLittleOpenTimerProbeForAutomation() {
    guard ProcessInfo.processInfo.environment["OPEN_LITTLEOPEN_TIMER_PROBE"] == "1",
      let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "open_idle_begin") else { return }
    unsafeBitCast(address, to: (@convention(c) () -> Void).self)()
  }
}

extension AutomationController {
  static let littleOpenCommands: Set<String> = ["little-open-state", "little-open-action", "little-open-eval", "little-open-profile-alert", "little-open-dock-menu", "little-open-link-click"]

  private func littleOpenState() -> [String: Any] {
    func frame(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
    let visibility = app.media.visibility.sleepVisibility()
    let sessions = app.littleOpenCoordinator.stateForAutomation.map { state -> [String: Any] in
      let window = state.window
      let controller = app.littleOpenCoordinator.controllers[state.id]!
      let page = OEEngine.shared.allWebContents.first { $0.view.window === window }
      window.layoutIfNeeded()
      let contentRect = window.convertToScreen(controller.container.convert(controller.container.bounds, to: nil))
      controller.contentView.layoutSubtreeIfNeeded()
      let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind -> [Double]? in
        guard let button = window.standardWindowButton(kind), let parent = button.superview else { return nil }
        let rect = controller.contentView.convert(button.frame, from: parent)
        return frame(CGRect(x: rect.minX, y: controller.contentView.bounds.height - rect.maxY, width: rect.width, height: rect.height))
      }
      return ["id": state.id.description, "window": window.windowNumber, "frame": frame(window.frame),
        "state": state.state.rawValue, "url": state.currentURL.absoluteString, "title": window.title,
        "profile": state.profileID.description, "pillSpace": state.pillSpaceID?.description ?? "",
        "lastActiveAt": state.lastActiveAt.timeIntervalSince1970,
        "screenFrame": frame(window.screen?.frame ?? .zero), "visibleFrame": frame(window.screen?.visibleFrame ?? .zero),
        "visible": window.isVisible, "miniaturized": window.isMiniaturized, "key": window.isKeyWindow,
        "visibilityProtected": visibility.littleOpen.contains(controller.session.tab.id),
        "tabID": controller.session.tab.id.description, "sidebarTab": app.model.tab(id: controller.session.tab.id) != nil,
        "content": page?.identifier ?? 0, "runtimeStyle": page?.runtimeStyle == .alloy ? "alloy" : "chrome",
        "loading": page?.isLoading ?? false, "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "",
        "barPresented": controller.commandBar.isPresented, "barInput": controller.urlField.stringValue,
        "trafficLights": lights,
        "fieldFocused": (window.firstResponder as? NSTextView)?.delegate as AnyObject? === controller.urlField,
        "contentFrame": frame(CGRect(x: contentRect.minX - window.frame.minX,
          y: window.frame.maxY - contentRect.maxY, width: contentRect.width, height: contentRect.height)),
        "titleElements": controller.titleBar.elementFrames.mapValues(frame),
        "pickerWindow": controller.spacePicker?.view.window?.windowNumber ?? 0,
        "pickerSpaces": controller.spacePicker?.filteredSpaces.map(\.id.description) ?? [],
        "intro": controller.showsIntro]
    }
    let count = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "open_idle_count").map {
      unsafeBitCast($0, to: (@convention(c) (Int32) -> UInt64).self)
    }
    return ["sessions": sessions, "hotkeyRegistered": app.hotkeyService?.isRegistered ?? false,
      "expiry": archiveState(), "mainWindows": app.windowControllers.count,
      "featureTimers": count.map { $0(6) } ?? NSNull()]
  }

  func runLittleOpenCommand(_ cmd: String, _ args: [String: Any]) async throws -> Any {
    if cmd == "little-open-state" { return littleOpenState() }
    if cmd == "little-open-link-click" {
      let factory = try window
      guard let page = factory.content(forAutomationHandle: args["tab"]), let target = page.view.window,
        let x = args["x"] as? Double, let y = args["y"] as? Double else { throw Failure(message: "missing link page or point") }
      try await activateForInput(target)
      page.focusPage()
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await page.sendDevToolsMethod("Input.dispatchMouseEvent", parameters: [
          "type": type, "x": x, "y": y, "button": "left", "clickCount": 1, "modifiers": 5])
      }
      return ["point": [x, y], "path": "OpenEngine Input.dispatchMouseEvent", "modifiers": 5] as [String: Any]
    }
    if cmd == "little-open-dock-menu" {
      return app.applicationDockMenu(NSApp)?.items.map { ["id": $0.identifier?.rawValue ?? "", "title": $0.title] } ?? []
    }
    if cmd == "little-open-profile-alert" {
      guard let alert = app.littleOpenProfileAlert else { return ["visible": false] }
      if let action = args["action"] as? String {
        guard ["confirm", "cancel"].contains(action) else { throw Failure(message: "invalid alert action") }
        alert.suppressionButton?.state = args["suppress"] as? Bool == true ? .on : .off
        alert.buttons[action == "confirm" ? 0 : 1].performClick(nil)
        await Task.yield()
      }
      return ["visible": app.littleOpenProfileAlert != nil, "message": alert.messageText,
        "informative": alert.informativeText, "buttons": alert.buttons.map(\.title),
        "suppression": alert.suppressionButton?.title ?? ""] as [String: Any]
    }
    if cmd == "little-open-action", args["action"] as? String == "blank" {
      app.openBlankLittleOpen(timestamp: args["timestamp"] as? Double)
      return littleOpenState()
    }
    guard let id = args["id"] as? String,
      let controller = app.littleOpenCoordinator.controllers.values.first(where: { $0.session.id.description == id })
    else { throw Failure(message: "unknown Little Open session") }
    if cmd == "little-open-eval" {
      guard let js = args["js"] as? String,
        let page = OEEngine.shared.allWebContents.first(where: { $0.view.window === controller.window })
      else { throw Failure(message: "missing Little Open page or js") }
      return try await page.evaluateJavaScript(js)
    }
    guard let action = args["action"] as? String else { throw Failure(message: "missing Little Open action") }
    switch action {
    case "close": app.littleOpenCoordinator.close(sessionID: controller.session.id, archiveReason: nil)
    case "miniaturize": controller.window?.miniaturize(nil)
    case "deminiaturize": controller.window?.deminiaturize(nil)
    case "focus": app.littleOpenCoordinator.resurface(controller.session.id); NSApp.activate()
    case "dismiss-intro": controller.dismissIntro()
    case "picker": controller.showSpacePicker()
    case "picker-search":
      controller.spacePicker?.searchField.stringValue = args["text"] as? String ?? ""
      if let picker = controller.spacePicker { picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.searchField)) }
    case "switch-profile":
      guard let raw = args["profile"] as? String, let uuid = UUID(uuidString: raw) else { throw Failure(message: "invalid Profile") }
      app.littleOpenCoordinator.switchProfile(sessionID: controller.session.id, profileID: ProfileID(rawValue: uuid))
    case "archive-policy":
      guard let value = args["interval"] as? String, let interval = AutoArchiveInterval(rawValue: value),
        let profile = app.model.profile(id: controller.session.profileID) else { throw Failure(message: "invalid Little Open archive interval") }
      profile.settings.littleOpenAutoArchiveAfter = interval
      app.expirySweeper?.rearm(); app.scheduleSave()
    default: throw Failure(message: "unknown Little Open action")
    }
    await Task.yield()
    return littleOpenState()
  }
}
#endif
