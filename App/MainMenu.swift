import AppKit
import OpenCommands

/// The registry owns titles, ordering, shortcuts and menu actions.
@MainActor
enum MainMenu {
  static func build(factoryOverride: EngineWebContentHostFactory? = nil) -> NSMenu {
    guard let app = NSApp.delegate as? AppDelegate, app.model != nil else { return NSMenu() }
    let owner = NSApp.keyWindow.flatMap { app.factory(forKeyWindow: $0) }
    let factory = factoryOverride ?? owner ?? (NSApp.keyWindow == nil ? app.frontWindowController.flatMap { app.hostFactories[$0.windowID] } : nil)
    let dispatcher: any CommandDispatcher
    if let controller = factory?.controller { dispatcher = controller } else { dispatcher = app }
    return MenuBuilder.buildMainMenu(dispatcher: dispatcher,
      spaces: app.model.spaces.map { SpaceMenuEntry(id: $0.id.description, title: app.model.displayTitle(for: $0)) },
      tabs: (factory?.orderedTabs ?? []).map { TabMenuEntry(id: $0.id.description, title: $0.displayTitle.isEmpty ? $0.url.absoluteString : $0.displayTitle) },
      overrides: app.keyBindings)
  }
  static func targetWindowCommands(_ target: EngineWebContentHostFactory?) { NSApp.mainMenu = build(factoryOverride: target) }
  static func performReservedShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, let app = NSApp.delegate as? AppDelegate else { return false }
    app.prepareCommandServices()
    if let window = event.window, let factory = app.factory(forKeyWindow: window) {
      return factory.controller?.handleKeyDown(event) == true
    }
    let context = RoutingContext(isAppActive: NSApp.isActive,
      isTextFocused: NSApp.keyWindow?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextField)
    guard case .browserCommand(let id)? = app.fallbackKeyboard.route(event: event, context: context, overrides: app.keyBindings),
          app.isCommandEnabled(id, enabledKey: CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always) else { return false }
    app.performCommand(id); return true
  }
}

@MainActor
enum AppCommand {
  static let helpURL = URL(string: "https://github.com/SergeSerb2/open/blob/main/docs/commands.md")!
  static let featureIDs: Set<String> = ["add-split-view", "close-split-pane", "expand-current-split", "separate-from-split-view", "next-split-pane", "previous-split-pane", "open-in-current-space"]
  static func canonicalID(_ id: String) -> String {
    ["reveal-tab-in-sidebar": "reveal-current-tab", "keyboard-shortcuts": "keyboard-shortcuts-edu"][id] ?? id
  }
  static let implemented: Set<String> = ["new-tab", "open-command-bar", "search-tabs", "new-window", "blank-window", "archive-tab", "restore-last-closed-tab", "pin-unpin-tab", "pin-tab", "unpin-tab", "duplicate-tab", "rename-tab", "reset-tab", "replace-pinned-url", "clear-unpinned-tabs", "next-tab", "previous-tab", "cycle-tab-forward", "cycle-tab-backward", "tab-switcher-forward", "tab-switcher-backward", "next-space", "previous-space", "new-space", "new-folder", "focus-space", "reload", "force-reload", "stop-loading", "go-back", "go-forward", "zoom-in", "zoom-out", "zoom-actual-size", "print", "save-page-as", "share-page", "copy-url", "copy-url-markdown", "copy-url-quote", "developer-tools", "javascript-console", "view-source", "inspect-elements", "toggle-sidebar", "reveal-current-tab", "expand-pinned-section", "collapse-pinned-section", "settings", "search-settings", "air-traffic-control", "import-from-browser", "set-default-browser", "check-for-updates", "view-archive", "view-history", "view-downloads", "view-library", "view-boosts", "manage-extensions", "add-extension", "new-little-open-window", "little-open-global", "help-center", "keyboard-shortcuts-edu", "show-shortcuts-overlay", "getting-started", "release-notes", "contact-team", "expand-all-folders", "collapse-all-folders", "add-to-favorites", "remove-from-favorites", "mute-all-tabs", "unmute-all-tabs", "reset-all-tabs-in-space"]
}

import OpenEngine
import OpenModel

extension EngineWebContentHostFactory {
  func isAppCommandEnabled(_ original: String, enabledKey: String? = nil, payload: String? = nil) -> Bool {
    let id = AppCommand.canonicalID(original)
    if id == "manage-spaces" { return true }
    if SystemCommandActions.selectors[id] != nil { return SystemCommandActions.isEnabled(id) }
    if AppCommand.featureIDs.contains(id) || id.hasPrefix("focus-split-pane-") {
      return controller?.isCommandEnabled(id, enabledKey: enabledKey ?? EnabledKey.currentTabInSplit) == true
    }
    guard AppCommand.implemented.contains(id) || id.hasPrefix("go-to-tab-") || id.hasPrefix("go-to-space-") else { return false }
    if id == "focus-space" { return payload.flatMap(UUID.init(uuidString:)).map { model.space(id: SpaceID(rawValue: $0)) != nil } ?? false }
    if id.hasPrefix("go-to-tab-"), let n = Int(id.split(separator: "-").last ?? "") { return n <= orderedTabs.count }
    if id.hasPrefix("go-to-space-"), let n = Int(id.split(separator: "-").last ?? "") { return n <= model.spaces.count }
    if id == "pin-tab" { return selectedTab.map { !model.isPinned(tabID: $0.id) } ?? false }
    if id == "unpin-tab" { return selectedTab.map { model.isPinned(tabID: $0.id) } ?? false }
    let key = enabledKey ?? CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always
    switch key {
    case EnabledKey.currentTab: return selectedContent != nil || selectedTab != nil
    case EnabledKey.currentTabPinned: return selectedTab.map { model.isPinned(tabID: $0.id) } ?? false
    case EnabledKey.currentTabInToday: return selectedTab.map { !model.isPinned(tabID: $0.id) && focusedProfile?.favorites.contains(where: { $0.id == selectedTab?.id }) != true } ?? false
    case EnabledKey.currentTabHasPinnedURL: return selectedTab?.pinnedURL != nil
    case EnabledKey.currentTabIsFavorite: return focusedProfile?.favorites.contains(where: { $0.id == selectedTab?.id }) == true
    case EnabledKey.currentTabNotFavorite: return selectedTab != nil && focusedProfile?.favorites.contains(where: { $0.id == selectedTab?.id }) != true
    case EnabledKey.currentTabInSplit: return controller?.splitController.split != nil
    case EnabledKey.multipleSpaces: return model.spaces.count > 1
    case EnabledKey.canGoBack: return selectedContent?.canGoBack == true
    case EnabledKey.canGoForward: return selectedContent?.canGoForward == true
    case EnabledKey.textField: return window?.firstResponder is NSTextView || window?.firstResponder is NSTextField || selectedContent != nil
    case EnabledKey.hasHistory: return focusedProfile != nil
    default: return true
    }
  }
  @discardableResult
  func performAppCommand(_ original: String, payload: String? = nil) -> Bool {
    let id = AppCommand.canonicalID(original)
    if id == "manage-spaces" { app.performCommand(id); return true }
    if SystemCommandActions.selectors[id] != nil { return SystemCommandActions.perform(id) }
    if AppCommand.featureIDs.contains(id) || id.hasPrefix("focus-split-pane-") { return false }
    guard isAppCommandEnabled(id, payload: payload) else { return false }
    if id.hasPrefix("go-to-space-"), let n = Int(id.split(separator: "-").last ?? ""), n <= model.spaces.count {
      if let uuid = payload.flatMap(UUID.init(uuidString:)), let space = model.space(id: SpaceID(rawValue: uuid)) { focus(space: space) }
      else { focus(space: model.spaces[n - 1]) }; return true
    }
    if id.hasPrefix("go-to-tab-"), let n = Int(id.split(separator: "-").last ?? ""), n <= orderedTabs.count {
      let tabID = payload.flatMap(UUID.init(uuidString:)).map { ItemID(rawValue: $0) } ?? orderedTabs[n - 1].id
      selectTabForCommand(tabID); return true
    }
    switch id {
    case "new-tab": newTab(nil)
    case "open-command-bar": focusAddressBar(nil)
    case "search-tabs": showCommandBar(.searchTabs)
    case "archive-tab":
      if controller?.hasPeekController == true, controller?.peekController.isShown == true { controller?.peekController.dismissTop() }
      else { closeTab(nil) }
    case "restore-last-closed-tab": restoreLastClosedTab(nil)
    case "pin-unpin-tab": togglePin(nil)
    case "pin-tab": if let tab = selectedTab { model.pinTab(id: tab.id) }
    case "unpin-tab": if let tab = selectedTab { model.unpinTab(id: tab.id) }
    case "duplicate-tab": if let id = selectedNodeID { _ = model.duplicateNode(id: id) }
    case "rename-tab":
      guard let tab = selectedTab, let controller, let window else { return false }
      if windowState.sidebarMode == .hidden { controller.toggleSidebar() }
      controller.sidebar.reveal(nodeID: tab.id)
      if controller.sidebar.rowFrame(nodeID: tab.id) != nil {
        controller.sidebar.beginRename(nodeID: tab.id)
      } else {
        // Split panes have no standalone outline row. Keep their rename async.
        guard pendingRenameAlert == nil else { return false }
        let alert = NSAlert(); alert.messageText = "Rename Tab"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: tab.displayTitle); field.frame.size = NSSize(width: 300, height: 24); alert.accessoryView = field
        pendingRenameAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
          guard let self else { return }; self.pendingRenameAlert = nil
          guard !self.isClosing, !self.app.terminationRequested, response == .alertFirstButtonReturn else { return }
          self.model.renameNode(id: tab.id, title: field.stringValue)
        }
      }
    case "reset-tab": if let tab = selectedTab, let url = tab.pinnedURL { model.resetPinnedTab(id: tab.id); hosts[tab.id]?.load(url) }
    case "replace-pinned-url": if let tab = selectedTab { model.replacePinnedURL(id: tab.id) }
    case "clear-unpinned-tabs": if let space = focusedSpace { model.clearToday(space: space.id) }
    case "next-tab", "cycle-tab-forward", "tab-switcher-forward": cycleTab(by: 1)
    case "previous-tab", "cycle-tab-backward", "tab-switcher-backward": cycleTab(by: -1)
    case "next-space": cycleSpace(by: 1)
    case "previous-space": cycleSpace(by: -1)
    case "focus-space": if let uuid = payload.flatMap(UUID.init(uuidString:)), let space = model.space(id: SpaceID(rawValue: uuid)) { focus(space: space) }
    case "new-space": if let profile = focusedProfile { focus(space: model.createSpace(title: "Space", profileID: profile.id)) }
    case "new-folder": if let space = focusedSpace { _ = model.createFolder(in: .spacePinned(space.id)) }
    case "reload": selectedContent?.reload()
    case "force-reload": selectedContent?.reloadIgnoringCache()
    case "stop-loading": selectedContent?.stopLoading()
    case "go-back": selectedContent?.goBack()
    case "go-forward": selectedContent?.goForward()
    case "zoom-in": selectedContent?.zoomIn()
    case "zoom-out": selectedContent?.zoomOut()
    case "zoom-actual-size": selectedContent?.resetZoom()
    case "print": selectedContent?.showPrintPanel()
    case "save-page-as": savePage()
    case "share-page": if let url = selectedContent?.url { NSSharingServicePicker(items: [url]).show(relativeTo: controller?.container.bounds ?? .zero, of: controller!.container, preferredEdge: .maxY) }
    case "copy-url", "copy-url-markdown", "copy-url-quote":
      guard let url = selectedContent?.url ?? selectedTab?.url else { return false }
      let title = selectedContent?.title ?? selectedTab?.displayTitle ?? ""
      NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id == "copy-url" ? url.absoluteString : "[\(title)](\(url.absoluteString))", forType: .string)
    case "developer-tools", "javascript-console", "inspect-elements": selectedContent?.showDevTools()
    case "view-source": if let url = selectedContent?.url { _ = openNewTab(url: URL(string: "view-source:\(url.absoluteString)")!, background: false) }
    case "toggle-sidebar": controller?.toggleSidebar()
    case "reveal-current-tab": if let id = selectedTab?.id { if windowState.sidebarMode == .hidden { controller?.toggleSidebar() }; controller?.sidebar.reveal(nodeID: id); window?.makeFirstResponder(controller?.sidebar.focusedOutline) }
    case "expand-pinned-section", "collapse-pinned-section": if let space = focusedSpace { model.setPinnedSectionCollapsed(spaceID: space.id, collapsed: id == "collapse-pinned-section") }
    case "manage-extensions", "add-extension": openExtensionsPage(nil)
    case "expand-all-folders", "collapse-all-folders":
      let ids = model.index.values.compactMap(\.folder).map(\.id)
      for folder in ids { model.setExpanded(folderID: folder, expanded: id == "expand-all-folders") }
    case "add-to-favorites": if let tab = selectedTab, let profile = focusedProfile { _ = model.addFavorite(tabID: tab.id, to: profile.id) }
    case "remove-from-favorites": if let tab = selectedTab { _ = model.removeFavorite(tabID: tab.id, into: focusedSpace?.id) }
    case "mute-all-tabs", "unmute-all-tabs": for tab in orderedTabs { model.setMuted(tabID: tab.id, muted: id == "mute-all-tabs"); hosts[tab.id]?.content.isMuted = tab.isMuted }
    case "reset-all-tabs-in-space": for tab in orderedTabs { if let url = tab.pinnedURL { model.resetPinnedTab(id: tab.id); hosts[tab.id]?.load(url) } }
    default: app.performCommand(id)
    }
    app.scheduleSave(); app.scheduleMenuRebuild(); return true
  }
  private func savePage() {
    guard !isClosing, app.engineReady, !app.terminationRequested,
          let page = selectedContent, let window, pendingSavePanel == nil else { return }
    let wasActive = NSApp.isActive, wasKey = window.isKeyWindow
    savePageRequestCount += 1
    let panel = NSSavePanel(); pendingSavePanel = panel; panel.nameFieldStringValue = "Page.mhtml"
    pendingSaveChoice = { [weak self, weak page] url in
      self?.pendingSavePanel = nil; self?.pendingSaveChoice = nil
      if wasActive && wasKey {
        DispatchQueue.main.async { [weak self, weak page] in
          if let page { self?.restorePageFocusIfUnclaimed(page) }
        }
      }
      self?.app.scheduleMenuRebuild()
      guard let self, !self.isClosing, !self.app.terminationRequested,
            self.app.engineReady, let url, let page else { return }
      let id = UUID()
      self.saveCaptureTasks[id] = Task { @MainActor [weak self, weak page] in
        guard let self else { return }
        defer { self.saveCaptureTasks[id] = nil }
        guard !Task.isCancelled, !self.isClosing, self.app.engineReady,
              !self.app.terminationRequested, let page else { return }
        await self.app.deferAsyncEngineWorkForAutomation()
        guard !Task.isCancelled, !self.isClosing, self.app.engineReady, !self.app.terminationRequested else { return }
        do {
          self.app.noteAsyncEngineCall("saveCapture")
          let result = try await page.sendDevToolsMethod("Page.captureSnapshot", parameters: ["format": "mhtml"])
          guard !Task.isCancelled, !self.isClosing, self.app.engineReady, !self.app.terminationRequested else { return }
          guard let body = result["data"] as? String else { return }
          try Data(body.utf8).write(to: url, options: .atomic)
        } catch { AppDelegate.commandLog("Could not save page: \(error)") }
      }
    }
    panel.beginSheetModal(for: window) { [weak self, weak panel] response in
      guard let self, let panel, self.pendingSavePanel === panel else { return }
      self.pendingSaveChoice?(response == .OK ? panel.url : nil)
    }
  }
}
