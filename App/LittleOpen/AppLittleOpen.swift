import AppKit
import OpenCommands
import OpenFeatures
import OpenModel
import Observation

struct LittleOpenRequest {
  let url: URL
  let profileHint: ProfileID?
}

extension AppDelegate {
  func openLittleOpen(url: URL, profileHint: ProfileID?) {
    lastLittleOpenRequest = LittleOpenRequest(url: url, profileHint: profileHint)
    littleOpenCoordinator.open(url: url, profileHint: profileHint)
    NSApp.activate()
  }

  func prepareLittleOpen() {
    guard littleOpenCoordinator == nil else { return }
    #if OPEN_AUTOMATION
    startLittleOpenTimerProbeForAutomation()
    #endif
    let coordinator = LittleOpenCoordinator(model: model, archiveSink: archiveSink) { [unowned self] profile in
      LittleOpenWebContent(app: self, profileID: profile)
    }
    littleOpenCoordinator = coordinator
    coordinator.onSwitchToTab = { [weak self] id, space in self?.selectLittleOpenDestination(tabID: id, spaceID: space) }
    coordinator.onOpenInMain = { [weak self] windowID, tabID, host in
      // Recreate through the sidebar's factory: host ownership stays local.
      // A live cross-factory transfer needs a separate ownership handoff.
      host?.close()
      self?.selectLittleOpenDestination(tabID: tabID, windowID: windowID)
    }
    coordinator.performCommand = { [weak self] id, space in self?.performCommand(id, payload: space?.description) }
    coordinator.isActionEnabled = { [weak self] id, _ in
      self?.isCommandEnabled(id, enabledKey: CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always) ?? false
    }
    coordinator.confirmProfileSwitch = { [weak self] profile, completion in self?.confirmLittleOpenProfileSwitch(profile, completion: completion) }
    // Fan out to the shared visibility feed, deadline and menus.
    coordinator.onChange = { [weak self, weak coordinator] in
      guard let self, let coordinator else { return }
      for controller in coordinator.controllers.values {
        let view = controller.container.host(for: controller.session.tab.id)?.view as? LittleOpenSurfaceView
        view?.owner?.windowOrderedFront()
        if let host = self.littleOpenHosts.values.first(where: { $0.view.window === controller.window }) {
          host.owner?.attachLittleOpen(controller, content: host.content)
        }
      }
      self.media.visibility.visibilityChanged()
      for host in self.littleOpenHosts.values {
        host.owner?.standaloneSurfaceVisibilityChanged()
      }
      self.expirySweeper?.rearm()
      self.scheduleMenuRebuild()
    }
    media.visibility.littleOpenCoordinator = coordinator
    observeLittleOpenArchivePolicies()
    initialWindowInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
      MainActor.assumeIsolated { self?.noteLaunchWindowInput(event.window ?? NSApp.keyWindow) }
      return event
    }
  }

  private func observeLittleOpenArchivePolicies() {
    guard !shutdownPrepared else { return }
    withObservationTracking {
      for profile in model.profiles { _ = profile.settings.littleOpenAutoArchiveAfter }
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.expirySweeper?.rearm()
        self?.observeLittleOpenArchivePolicies()
      }
    }
  }

  func openBlankLittleOpen(timestamp: TimeInterval? = nil) {
    // The File menu can run during the shell's first frame, before CEF is ready.
    // Keep the press stamp and create the real host at engine initialization.
    guard engineReady else { pendingLittleOpenBlankStamps.append(timestamp); return }
    littleOpenCoordinator.openBlank(focusURLField: true, keyDownTimestamp: timestamp)
    NSApp.activate()
  }

  var keyLittleOpen: LittleOpenWindowController? {
    littleOpenCoordinator?.controllers.values.first { $0.window === NSApp.keyWindow }
  }

  func noteLaunchWindowInput(_ window: NSWindow?) {
    guard let id = autoCreatedLaunchWindowID,
      windowControllers.contains(where: { $0.windowID == id && $0.window === window }) else { return }
    autoCreatedLaunchWindowID = nil
  }

  func noteLaunchWindowNavigation(_ id: WindowID) {
    if autoCreatedLaunchWindowID == id { autoCreatedLaunchWindowID = nil }
  }

  func selectLittleOpenDestination(tabID: ItemID, spaceID: SpaceID? = nil, windowID: WindowID? = nil) {
    guard model.tab(id: tabID) != nil else { return }
    let space = spaceID.flatMap { model.space(id: $0) } ?? model.spaces.first { space in
      @MainActor func contains(_ nodes: [SidebarNode]) -> Bool {
        nodes.contains { node in
          switch node {
          case .tab(let tab): tab.id == tabID
          case .folder(let folder): contains(folder.children)
          case .split(let split): split.panes.contains { $0.id == tabID }
          }
        }
      }
      return contains(space.pinned + space.today)
    } ?? model.profiles.first(where: { $0.favorites.contains { $0.id == tabID } }).flatMap { model.mostRecentlyFocusedSpace(profileID: $0.id) }
    guard let space else { return }
    let controller = windowID.flatMap { id in windowControllers.first { $0.windowID == id } }
      ?? linkExecutor.orderedControllers.first ?? makeWindow(focusedSpaceID: space.id)
    guard let controller, let factory = hostFactories[controller.windowID] else { return }
    model.focusSpace(windowID: controller.windowID, spaceID: space.id)
    factory.selectTabForCommand(tabID)
    focusWindow(controller.windowID, activate: true)
    scheduleSave()
  }

  func confirmLittleOpenProfileSwitch(_ profile: ProfileID, completion: @escaping (Bool) -> Void) {
    guard let coordinator = littleOpenCoordinator,
      let controller = keyLittleOpen ?? coordinator.controllers.values.first(where: { $0.window?.isVisible == true }),
      let window = controller.window else { completion(false); return }
    let alert = NSAlert()
    alert.messageText = "Open this page in another Profile?"
    alert.informativeText = "Each Profile has different browser data, so this webpage might look a little different."
    alert.addButton(withTitle: "Switch Profile"); alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't ask again"
    littleOpenProfileAlert = alert
    alert.beginSheetModal(for: window) { [weak self, weak alert] response in
      MainActor.assumeIsolated {
        let confirmed = response == .alertFirstButtonReturn
        if confirmed, alert?.suppressionButton?.state == .on {
          UserDefaults.standard.set(true, forKey: "open.links.littleOpenProfileSwitchConfirmed")
        }
        self?.littleOpenProfileAlert = nil
        completion(confirmed)
      }
    }
  }

  func handleLittleOpenKey(_ event: NSEvent) -> Bool {
    guard let controller = keyLittleOpen, event.type == .keyDown else { return false }
    let context = RoutingContext(isAppActive: NSApp.isActive,
      isTextFocused: controller.window?.firstResponder is NSTextView || controller.window?.firstResponder is NSTextField)
    guard case .browserCommand(let id)? = fallbackKeyboard.route(event: event, context: context, overrides: keyBindings),
      isCommandEnabled(id, enabledKey: CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always) else { return false }
    performCommand(id, keyDownTimestamp: event.timestamp); return true
  }

  func littleOpenCommandEnabled(_ id: String) -> Bool? {
    if ["show-little-open-windows", "close-little-open-windows"].contains(id) { return !(littleOpenCoordinator?.sessions.isEmpty ?? true) }
    guard let controller = keyLittleOpen else { return nil }
    switch id {
    case "open-in-current-space": return controller.state == .page && controller.pillSpaceID != nil
    case "open-command-bar", "archive-tab", "close-window": return true
    case "reload", "go-back", "go-forward", "copy-url": return controller.state == .page
    default: return nil
    }
  }

  @discardableResult
  func performLittleOpenCommand(_ id: String) -> Bool {
    switch id {
    case "show-little-open-windows": littleOpenCoordinator.showAll(); NSApp.activate(); return true
    case "close-little-open-windows": littleOpenCoordinator.closeAll(); return true
    default: break
    }
    guard let controller = keyLittleOpen else { return false }
    let host = controller.container.host(for: controller.session.tab.id)
    switch id {
    case "manage-extensions", "add-extension", "extension-shortcuts":
      littleOpenExtensionFactory()?.performLittleOpenExtensionManagement(id)
    case "open-in-current-space": controller.openInCurrentSpace()
    case "open-command-bar": controller.focusURL()
    case "archive-tab", "close-window": littleOpenCoordinator.close(sessionID: controller.session.id, archiveReason: nil)
    case "reload": host?.reload()
    case "go-back": host?.goBack()
    case "go-forward": host?.goForward()
    case "copy-url": controller.copyURL()
    default: return false
    }
    return true
  }

  func appendLittleOpenMenuItems(to menu: NSMenu, sessions: Bool) {
    menu.addItem(.separator())
    if sessions {
      for session in littleOpenCoordinator?.sessions ?? [] {
        let title = session.tab.title.isEmpty ? "Little Open" : session.tab.title
        let item = ClosureMenuItem(title: title) { [weak self] in self?.littleOpenCoordinator.resurface(session.id); NSApp.activate() }
        item.identifier = NSUserInterfaceItemIdentifier("little-open-session:\(session.id)")
        menu.addItem(item)
      }
    }
    for id in ["show-little-open-windows", "close-little-open-windows"] {
      guard let command = CommandRegistry.byID[id] else { continue }
      let item = ClosureMenuItem(title: command.title) { [weak self] in self?.performCommand(id) }
      item.identifier = NSUserInterfaceItemIdentifier(id)
      menu.addItem(item)
    }
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu(title: "Open")
    appendLittleOpenMenuItems(to: menu, sessions: false)
    return menu
  }
}
