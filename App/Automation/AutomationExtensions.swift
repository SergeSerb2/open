#if OPEN_AUTOMATION
import AppKit
import OpenEngine
import OpenExtensionsUI
import OpenDesign
import OpenCommands

extension AutomationController {
  func runExtensionCommand(_ cmd: String, _ args: [String: Any]) async throws -> Any {
    if cmd == "ext-shortcuts" { return try await extensionShortcuts(args) }
    if cmd == "ext-windows" {
      let key = "NSWindow Frame ExtensionPopupWindow"
      if args["preference"] as? Bool == true {
        if let value = args["value"] { UserDefaults.standard.set(value is NSNull ? nil : value, forKey: key) }
        return UserDefaults.standard.object(forKey: key) ?? NSNull()
      }
      return ExtensionWindowController.windows.values.map { controller in
        let window = controller.window!
        let frame = window.frame
        return ["browser": controller.browser.identifier, "chromeWindowId": controller.browser.chromeWindowIdentifier,
          "page": controller.content.identifier, "extension": controller.extensionID,
          "number": window.windowNumber, "title": window.title, "visible": window.isVisible,
          "controller": String(describing: type(of: controller)),
          "frame": [frame.minX, frame.minY, frame.width, frame.height],
          "autosave": window.frameAutosaveName, "style": window.styleMask.rawValue,
          "pageIsContentView": window.contentView === controller.content.view,
          "hasToolbar": window.toolbar != nil] as [String: Any]
      }
    }
    if cmd == "ext-prompt" {
      if let enabled = args["handler"] as? Bool {
        extensionAutomation.cancelAll()
        extensionAutomation.handlesPrompts = enabled
        extensionAutomation.registerContexts()
      }
      if args["clear"] as? Bool == true { extensionAutomation.cancelAll() }
      var result: [String: Any] = ["pending": false]
      if let prompt = extensionAutomation.pending.first {
        result = extensionAutomation.describe(prompt)
        if let answer = args["answer"] as? String {
          guard ["accept", "cancel"].contains(answer) else { throw Failure(message: "answer must be accept or cancel") }
          let injectCancel = answer == "accept" && prompt.type == .install
            && ProcessInfo.processInfo.environment["OPEN_E2E_P3_CANCEL_INSTALL"] == "1"
          extensionAutomation.answer(prompt, accepted: answer == "accept" && !injectCancel)
          result["injectedCancel"] = injectCancel
          // The API guarantees exactly once even for accidental duplicate answers.
          if args["twice"] as? Bool == true { prompt.accept(); prompt.cancel() }
          result["answered"] = answer
        } else if args["hold"] as? Bool == false {
          // Dropping the last reference tests release-to-cancel.
          extensionAutomation.answer(prompt, accepted: false)
          result["released"] = true
        }
      }
      result["queued"] = extensionAutomation.pending.count
      result["handler"] = extensionAutomation.handlesPrompts
      result["events"] = extensionAutomation.events
      return result
    }
    let factory: EngineWebContentHostFactory
    if args["surface"] as? String == "little" {
      // A welcome tab may focus the main window between automation calls.
      // Select the requested Little Open window; clicks still use native events.
      let target: NSWindow? = if let number = args["window"] as? Int {
        NSApp.window(withWindowNumber: number)
      } else { NSApp.keyWindow }
      guard let little = app.littleOpenExtensionFactory(window: target) else { throw Failure(message: "no Little Open extension host for window") }
      factory = little
    } else { factory = try window }
    if cmd == "ext-redraw-measure" {
      if args["start"] as? Bool == true {
        extensionRedrawMeasurement?.stop()
        extensionRedrawMeasurement = ExtensionRedrawMeasurement(strips: factory.extensions.strips)
        try await Task.sleep(for: .milliseconds(50))
      } else { extensionRedrawMeasurement?.stop() }
      return extensionRedrawMeasurement?.state ?? [:]
    }
    if ["ext-strip", "ext-click", "ext-popup-state", "ext-picker", "ext-hover", "ext-ui-menu"].contains(cmd) {
      return try await runExtensionUICommand(cmd, args, factory)
    }
    let browser = try focusedBrowser(factory)
    let manager = browser.context.extensions
    if cmd == "ext-omnibox" {
      guard let id = args["extension"] as? String else { throw Failure(message: "missing extension") }
      switch args["op"] as? String {
      case "start": browser.omniboxStartSession(forExtension: id); return true
      case "cancel": browser.omniboxInputCancelled(forExtension: id); return true
      case "default":
        guard let row = browser.omniboxDefaultSuggestion(forExtension: id) else { return ["present": false] }
        return ["present": true, "titleUTF16": row.descriptionText.utf16.count, "contentUTF16": row.content.utf16.count,
          "matchRanges": row.matchRanges.count] as [String: Any]
      case "input":
        extensionAutomation.omniboxReply = nil
        return browser.omniboxInputChanged(args["text"] as? String ?? "", forExtension: id) { [weak extensionAutomation] rows in
          extensionAutomation?.omniboxReply = ["count": rows.count]
        }
      case "reply": return extensionAutomation.omniboxReply ?? [:]
      default: throw Failure(message: "unknown omnibox operation")
      }
    }
    if cmd == "ext-commands" {
      return ["ready": manager.isReady, "context": browser.context.identifier,
        "commands": extensionAutomation.table(manager).state]

    }
    guard let id = args["extension"] as? String else { throw Failure(message: "missing extension") }
    if cmd == "ext-run-command" {
      guard let name = args["name"] as? String else { throw Failure(message: "missing command name") }
      return browser.executeExtensionCommand(name, forExtension: id)
    }
    guard let action = args["action"] as? String else { throw Failure(message: "missing management action") }
    switch action {
    case "enable", "disable": manager.setEnabled(action == "enable", forExtension: id)
    case "uninstall": manager.uninstallExtension(id, window: factory.window)
    case "reload": manager.reloadExtension(id)
    case "install-webstore":
      // Completion is recorded so the socket remains available to answer consent.
      manager.install(fromWebStore: id, window: factory.window) { [weak extensionAutomation] installed, error in
        extensionAutomation?.record(["event": "installComplete", "id": id, "installed": installed, "error": error ?? ""])
      }
    case "install-crx":
      guard let path = args["path"] as? String, let content = browser.activeWebContent else { throw Failure(message: "missing CRX path or active page") }
      return manager.installLocalCRX(URL(fileURLWithPath: path), webContent: content)
    default: throw Failure(message: "unknown management action")
    }
    return true
  }
  /// X-27 uses the actual Settings model/save callback, menu target and rendered
  /// notice labels. It never constructs a second conflict list for the check.
  private func extensionShortcuts(_ args: [String: Any]) async throws -> Any {
    let adapter = app.settingsPresenter
    let model = adapter.settings.shortcuts
    let action = args["action"] as? String ?? "state"
    if action == "close" { adapter.settingsPresenter.window?.close(); return true }
    guard adapter.settings.selectedPane == .shortcuts,
      let window = adapter.settingsPresenter.window, window.isVisible,
      let content = window.contentView else { throw Failure(message: "show Settings Shortcuts first") }
    switch action {
    case "reset-all": model.resetAll(confirmed: true)
    case "record", "reset":
      guard let id = args["id"] as? String, let command = CommandRegistry.byID[id],
        command.isCustomizable, !command.isReserved else { throw Failure(message: "unknown customizable command") }
      if action == "reset" { model.reset(id) }
      else {
        guard let key = args["key"] as? String, key.utf8.count == 1,
          let modifiers = args["modifiers"] as? [String], modifiers.count <= 4,
          modifiers.allSatisfy({ ["command", "shift", "option", "control"].contains($0) }) else { throw Failure(message: "invalid shortcut") }
        var flags: ShortcutModifiers = []
        for modifier in modifiers {
          switch modifier { case "command": flags.insert(.command); case "shift": flags.insert(.shift)
          case "option": flags.insert(.option); default: flags.insert(.control) }
        }
        model.record(KeyboardShortcut(key: key, modifiers: flags), for: id)
      }
    case "state", "menu": break
    default: throw Failure(message: "unknown shortcuts action")
    }
    // Allow SwiftUI to update its native representable after a saved binding.
    try await Task.sleep(for: .milliseconds(50))
    content.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView, depth: Int = 0) -> [NSView] {
      guard depth < 64 else { return [] }
      return [view] + view.subviews.flatMap { descendants($0, depth: depth + 1) }
    }
    let views = descendants(content)
    guard let button = views.compactMap({ $0 as? NSPopUpButton }).first(where: {
      $0.accessibilityLabel() == "More shortcut actions" && !$0.isHiddenOrHasHiddenAncestor
    }), let menu = button.menu else { throw Failure(message: "no Shortcuts more menu") }
    let titles = describeExtensionMenu(menu)
    if action == "menu", let title = args["select"] as? String { try selectExtensionMenu(menu, title: title) }
    let notices = views.compactMap { $0 as? NSTextField }.filter {
      !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.hasSuffix(", so it is off.")
    }.map(\.stringValue)
    let id = args["id"] as? String ?? ""
    return ["menu": titles, "notices": notices, "status": model.statusText,
      "bindingCount": model.store.bindings.count,
      "openCommandTitle": CommandRegistry.byID[id]?.title ?? "",
      "window": window.windowNumber] as [String: Any]
  }
}
#endif

#if OPEN_AUTOMATION
extension AutomationController {
  func runExtensionUICommand(_ cmd: String, _ args: [String: Any], _ factory: EngineWebContentHostFactory) async throws -> Any {
    let ui = factory.extensions
    factory.controller?.contentView.layoutSubtreeIfNeeded()
    if cmd == "ext-popup-state" { return ui.popup.state }
    if args["surface"] as? String == "little", let little = factory.littleOpenController {
      little.contentView.layoutSubtreeIfNeeded()
      let button = little.extensionsButton, rect = button.convert(button.bounds, to: nil)
      if cmd == "ext-strip" {
        if let retain = args["retainBrowser"] as? Bool {
          WindowExtensions.retainedLittleOpenBrowser = retain ? ui.host?.browser : nil
          WindowExtensions.retainedLittleOpenContext = retain ? ui.context : nil
        }
        let old = WindowExtensions.retainedLittleOpenBrowser
        return ["ids": ui.context.actions.map(\.id), "more": false,
          "frames": [[rect.minX, rect.minY, rect.width, rect.height]],
          "buttonFrame": [rect.minX, rect.minY, rect.width, rect.height],
          "visible": !button.isHiddenOrHasHiddenAncestor, "ready": ui.host?.actionsReady == true,
          "browser": ui.host?.browser.identifier ?? 0, "context": ui.host?.browser.context.identifier ?? "",
          "activeTab": ui.host?.browser.activeWebContent?.chromeTabIdentifier ?? -1,
          "delegateMatches": ui.host?.browser.delegate === factory,
          "retainedBrowser": old?.identifier ?? 0,
          "retainedDelegateCleared": old != nil && old?.delegate == nil,
          "retainedActionIDs": WindowExtensions.retainedLittleOpenContext?.actions.map(\.id) ?? [],
          "contextIDs": ui.context.actions.map(\.id)] as [String: Any]
      }
      if cmd == "ext-click" {
        guard !button.isHiddenOrHasHiddenAncestor, let target = little.window else { throw Failure(message: "Little Open Extensions button is hidden") }
        ui.capturesMenus = true; ui.capturedMenu = nil
        defer { ui.capturesMenus = false; ui.capturedMenu = nil }
        _ = try await mouse(["action": "click", "window": target.windowNumber,
          "x": Double(rect.midX), "y": Double(target.frame.height - rect.midY)], factory)
        try await Task.sleep(for: .milliseconds(20))
        guard let native = ui.capturedMenu else { throw Failure(message: "Little Open Extensions button did not open its menu") }
        let items = describeExtensionMenu(native)
        if let title = args["select"] as? String { try selectExtensionMenu(native, title: title) }
        return ["menu": items]
      }
    }
    if cmd == "ext-hover" {
      guard let window = factory.window, let controller = factory.controller else { throw Failure(message: "no window") }
      let inside = args["inside"] as? Bool ?? true
      let view: NSView = inside ? controller.sidebar : controller.container
      let local = inside ? CGPoint(x: min(100, view.bounds.width / 2), y: 62) : CGPoint(x: view.bounds.midX, y: view.bounds.midY)
      let p = view.convert(local, to: nil)
      return try await mouse(["action": "hover", "window": window.windowNumber, "x": Double(p.x), "y": Double(window.frame.height - p.y)], factory)
    }
    if cmd == "ext-picker" {
      guard let scc = ui.siteControl else { return ["blocked": "App has no SiteControlController presenter or data source; showSiteControls is a stub", "focusedID": NSNull()] as [String: Any] }
      if let keys = args["keys"] as? [String] {
        guard keys.count <= 128 else { throw Failure(message: "too many keys") }
        for key in keys { _ = try await sendKey(["key": key, "route": "app"], factory) }
      }
      return ["presented": scc.isPresented, "focusedID": scc.view.panel.extensionsBody.focusedID ?? ""] as [String: Any]
    }
    if cmd == "ext-ui-menu" {
      if args["kind"] as? String == "bar" {
        guard let native = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Extensions" })?.submenu else { throw Failure(message: "no Extensions menu") }
        native.delegate?.menuNeedsUpdate?(native)
        if let title = args["select"] as? String { try selectExtensionMenu(native, title: title) }
        return describeExtensionMenu(native)
      }
      guard let id = args["extension"] as? String else { throw Failure(message: "missing extension") }
      guard let source = ui.host?.contextMenu(extensionID: id, fromMenuItem: false),
            let native = ExtensionsMenuBuilder.contextMenu(source) else { throw Failure(message: "no menu") }
      let result = describeExtensionMenu(native)
      if let title = args["select"] as? String {
        try selectExtensionMenu(native, title: title)
        return ["items": result, "ran": (source as? EngineExtensionMenu)?.didRun == true] as [String: Any]
      }
      else { source.cancel() }
      return result
    }
    let surface = args["surface"] as? String ?? "url"
    guard ["url", "pane", "toolbar", "little"].contains(surface) else { throw Failure(message: "invalid surface") }
    let strips = ui.strips.filter { strip in
      switch surface { case "url": strip.style == .urlField; case "pane": strip.style == .paneBar; case "toolbar": strip.style == .toolbar; default: false }
    }
    if cmd == "ext-strip" {
      let values: [[String: Any]] = strips.map { strip in
        let buttons = strip.buttons.filter { !$0.isHiddenOrHasHiddenAncestor }
        func frame(_ view: NSView) -> [CGFloat] { let r = view.convert(view.bounds, to: nil); return [r.minX, r.minY, r.width, r.height] }
        return ["ids": buttons.map { $0.action.id }, "more": !strip.moreButton.isHiddenOrHasHiddenAncestor,
          "frames": buttons.map(frame), "moreFrame": strip.moreButton.isHiddenOrHasHiddenAncestor ? [] : frame(strip.moreButton),
          "visible": strip.showsActions && !strip.isHiddenOrHasHiddenAncestor, "focused": strip.isFocused,
          "hovered": strip.hovered, "hasPage": strip.hasPage, "hidden": strip.isHiddenOrHasHiddenAncestor,
          "layoutCount": strip.layoutCount, "redraws": strip.buttons.reduce(0) { $0 + $1.redrawCount },
          "width": strip.bounds.width, "stripWidth": strip.geometry.stripWidth]
      }
      var result = values.first(where: { $0["focused"] as? Bool == true }) ?? values.first
        ?? ["ids": [String](), "more": false, "frames": [[CGFloat]](), "visible": false]
      result["strips"] = values
      result["imageConversions"] = EngineExtensionImages.shared.conversionCount
      result["contextIDs"] = ui.context.actions.map(\.id)
      result["pinnedIDs"] = ui.context.actions.filter(\.isPinned).map(\.id)
      result["listUpdates"] = ui.host?.listUpdateCount ?? 0
      result["actionUpdates"] = ui.host?.actionUpdateCount ?? 0
      return result
    }
    guard let id = args["extension"] as? String else { throw Failure(message: "missing extension") }
    let button: NSView? = id == "more"
      ? strips.first(where: { !$0.moreButton.isHiddenOrHasHiddenAncestor })?.moreButton
      : strips.flatMap(\.buttons).first(where: { $0.action.id == id && !$0.isHiddenOrHasHiddenAncestor })
    guard let button, let window = button.window else { throw Failure(message: "action has no visible slot on this surface") }
    let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    ui.capturesMenus = true; ui.capturedMenu = nil
    defer { ui.capturesMenus = false; ui.capturedMenu = nil }
    if args["button"] as? String == "right" {
      guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: Self.syntheticPointerTag, clickCount: 1, pressure: 1) else { throw Failure(message: "cannot create event") }
      NSApp.sendEvent(event)
    } else {
      _ = try await mouse(["action": "click", "window": window.windowNumber, "x": Double(point.x), "y": Double(window.frame.height - point.y)], factory)
      // The native mouse-up is queued by the shared real-event helper.
      try await Task.sleep(for: .milliseconds(20))
    }
    if let native = ui.capturedMenu {
      let items = describeExtensionMenu(native)
      if let title = args["select"] as? String { try selectExtensionMenu(native, title: title) }
      return ["menu": items]
    }
    return ["clicked": id, "popup": ui.popup.state] as [String: Any]
  }
  private func describeExtensionMenu(_ menu: NSMenu) -> [[String: Any]] {
    menu.items.filter { !$0.isHidden }.map { item in
      ["title": item.title, "enabled": item.isEnabled, "checked": item.state == .on, "separator": item.isSeparatorItem,
        "submenu": item.submenu.map(describeExtensionMenu) ?? []] as [String: Any]
    }
  }
  private func selectExtensionMenu(_ menu: NSMenu, title: String) throws {
    for item in menu.items where item.isEnabled && !item.isHidden {
      if item.title == title, item.submenu == nil {
        menu.performActionForItem(at: menu.index(of: item)); return
      }
      if let child = item.submenu, (try? selectExtensionMenu(child, title: title)) != nil { return }
    }
    throw Failure(message: "no enabled menu item \(title)")
  }
}
#endif
