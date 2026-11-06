import AppKit
import OpenCommands
import OpenSettings

/// The registry owns titles, ordering, shortcuts and menu actions.
@MainActor
enum MainMenu {
  static func build(factoryOverride: EngineWebContentHostFactory? = nil) -> NSMenu {
    guard let app = NSApp.delegate as? AppDelegate, app.model != nil else { return NSMenu() }
    let owner = NSApp.keyWindow.flatMap { app.factory(forKeyWindow: $0) }
    let factory = factoryOverride ?? owner ?? (NSApp.keyWindow == nil ? app.frontWindowController.flatMap { app.hostFactories[$0.windowID] } : nil)
    let dispatcher: any CommandDispatcher
    if let controller = factory?.controller { dispatcher = controller } else { dispatcher = app }
    let menu = MenuBuilder.buildMainMenu(dispatcher: dispatcher,
      spaces: app.model.spaces.map { SpaceMenuEntry(id: $0.id.description, title: app.model.displayTitle(for: $0)) },
      tabs: (factory.map { f in f.numberedItems.map { TabMenuEntry(id: $0.description, title: f.numberedTitle($0)) } } ?? []),
      overrides: app.keyBindings, switchToNinth: UserDefaults.standard.bool(forKey: "open.shortcuts.switchToNinthEnabled"))
    menu.items.first { $0.submenu?.title == "Extensions" }?.submenu?.delegate = app.extensionsMainMenu
    if let windowMenu = menu.items.first(where: { $0.title == "Window" })?.submenu { app.appendLittleOpenMenuItems(to: windowMenu, sessions: true) }
    #if DEBUG || OPEN_AUTOMATION
    if let help = menu.items.first(where: { $0.title == "Help" })?.submenu,
      let troubleshooting = help.items.first(where: { $0.title == "Troubleshooting" })?.submenu {
      let archive = ClosureMenuItem(title: "Archive Expired Little Open Windows Now") { [weak app] in
        _ = app?.littleOpenCoordinator.archiveExpired(now: Date().addingTimeInterval(31 * 24 * 3600))
        app?.archiveSink.flushAll()
      }
      archive.identifier = NSUserInterfaceItemIdentifier("archive-expired-little-open-now")
      troubleshooting.addItem(archive)
    }
    #endif
    return menu
  }
  static func targetWindowCommands(_ target: EngineWebContentHostFactory?) { NSApp.mainMenu = build(factoryOverride: target) }
  static func performReservedShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, let app = NSApp.delegate as? AppDelegate else { return false }
    if (Array(app.hostFactories.values) + app.littleOpenHosts.values.compactMap(\.owner))
      .contains(where: { $0.pageChrome.dialogs.blocksBrowserShortcut(event) }) { return true }
    app.prepareCommandServices()
    // Preserve the initiating timestamp even if Carbon/menu delivery was delayed.
    // Pointer and programmatic menu actions call performCommand without a key stamp.
    let littleContext = RoutingContext(isAppActive: NSApp.isActive, isTextFocused: false)
    if case .browserCommand(let id)? = app.fallbackKeyboard.route(event: event, context: littleContext, overrides: app.keyBindings),
      ["new-little-open-window", "little-open-global"].contains(id),
      app.isCommandEnabled(id, enabledKey: CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always) {
      app.noteLaunchWindowInput(event.window ?? NSApp.keyWindow)
      app.performCommand(id, keyDownTimestamp: event.timestamp)
      return true
    }
    if app.handleLittleOpenKey(event) { return true }
    if let factory = app.littleOpenExtensionFactory(window: event.window ?? NSApp.keyWindow),
      let browser = factory.focusedBrowser,
      app.extensionPrompts.table(browser.context.extensions).handle(event, factory: factory) { return true }
    if let window = event.window, let factory = app.factory(forKeyWindow: window) {
      factory.findKeyRequestedAt = event.timestamp
      defer { factory.findKeyRequestedAt = nil }
      return factory.controller?.handleKeyDown(event) == true
    }
    let context = RoutingContext(isAppActive: NSApp.isActive,
      isTextFocused: NSApp.keyWindow?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextField)
    guard case .browserCommand(let id)? = app.fallbackKeyboard.route(event: event, context: context, overrides: app.keyBindings),
          app.isCommandEnabled(id, enabledKey: CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always) else { return false }
    app.performCommand(id, keyDownTimestamp: event.timestamp); return true
  }
}

@MainActor
enum AppCommand {
  static let helpURL = URL(string: "https://github.com/SergeSerb2/open/blob/main/docs/commands.md")!
  static func helpURL(for id: String) -> URL {
    switch id {
    case "getting-started": URL(string: "https://github.com/SergeSerb2/open#readme")!
    case "release-notes": URL(string: "https://github.com/SergeSerb2/open/releases")!
    case "contact-team": URL(string: "https://github.com/SergeSerb2/open/issues/new")!
    default: helpURL
    }
  }
  /// Settings ▸ Advanced "Show full URL when Toolbar is enabled" (CC-37).
  static let showFullURLKey = "open.advanced.showFullURLWithToolbar"
  static let featureIDs: Set<String> = ["add-split-view", "close-split-pane", "expand-current-split", "separate-from-split-view", "next-split-pane", "previous-split-pane", "open-in-current-space"]
  static func canonicalID(_ id: String) -> String {
    ["reveal-tab-in-sidebar": "reveal-current-tab", "keyboard-shortcuts": "keyboard-shortcuts-edu"][id] ?? id
  }
  static let implemented: Set<String> = ["peek-email", "exit-modal", "new-tab", "open-command-bar", "search-tabs", "search-actions", "new-window", "blank-window", "archive-tab", "restore-last-closed-tab", "pin-unpin-tab", "pin-tab", "unpin-tab", "duplicate-tab", "rename-tab", "reset-tab", "replace-pinned-url", "clear-unpinned-tabs", "next-tab", "previous-tab", "cycle-tab-forward", "cycle-tab-backward", "tab-switcher-forward", "tab-switcher-backward", "next-space", "previous-space", "new-space", "new-folder", "focus-space", "reload", "force-reload", "stop-loading", "go-back", "go-forward", "zoom-in", "zoom-out", "zoom-actual-size", "print", "save-page-as", "share-page", "copy-url", "copy-url-markdown", "copy-url-quote", "developer-tools", "javascript-console", "view-source", "inspect-elements", "toggle-sidebar", "toggle-toolbar", "reveal-current-tab", "expand-pinned-section", "collapse-pinned-section", "settings", "search-settings", "air-traffic-control", "import-from-browser", "set-default-browser", "check-for-updates", "view-archive", "view-history", "view-downloads", "view-library", "view-media", "view-boosts", "manage-extensions", "add-extension", "extension-shortcuts", "open-extensions-picker", "new-little-open-window", "little-open-global", "help-center", "keyboard-shortcuts-edu", "getting-started", "release-notes", "contact-team", "expand-all-folders", "collapse-all-folders", "add-to-favorites", "remove-from-favorites", "mute-all-tabs", "unmute-all-tabs", "reset-all-tabs-in-space", "manage-spaces", "rename-space", "change-profile", "clear-archive", "capture-page", "capture-full-page", "capture-portrait"]
}

import OpenEngine
import OpenModel
import OpenSidebar
import OpenFeatures

extension EngineWebContentHostFactory {
  private func selectionCommandContext(for id: String) -> SidebarContext? {
    guard ["pin-unpin-tab", "duplicate-tab", "new-folder"].contains(id),
      let controller, !controller.context.selection.isEmpty else { return nil }
    if id == "new-folder" {
      guard let outline = controller.sidebar.focusedOutline, let responder = window?.firstResponder as? NSView,
        !(responder is NSTextView), !(responder is NSTextField),
        responder === outline || responder.isDescendant(of: outline) else { return nil }
    }
    return controller.context
  }

  private func performSelectionAppCommand(_ id: String) -> Bool? {
    guard let context = selectionCommandContext(for: id) else { return nil }
    guard context.isSelectionCommandEnabled(id) else { return false }
    let result = context.performSelectionCommand(id)
    if result { app.scheduleSave(); app.scheduleMenuRebuild() }
    return result
  }

  func isAppCommandEnabled(_ original: String, enabledKey: String? = nil, payload: String? = nil) -> Bool {
    let id = AppCommand.canonicalID(original)
    if ["find", "find-next", "find-previous", "find-and-replace", "use-selection-to-find", "jump-to-selection"].contains(id) { return selectedContent != nil }
    if id == "peek-email" { return controller != nil && peekEmailTab != nil }
    // Post-v1: Join Meeting needs calendar live data (lead decision S2 on live-data sources).
    if id == "join-meeting" { return false }
    if id == "exit-modal" {
      return window === NSApp.keyWindow && windowState.style == .standard && controller?.canExitModal == true
    }
    if let context = selectionCommandContext(for: id) { return context.isSelectionCommandEnabled(id) }
    if let enabled = isPageToolEnabled(id) { return enabled }  // App/Page/PageToolsCommands.swift
    if SystemCommandActions.selectors[id] != nil { return SystemCommandActions.isEnabled(id) }
    if AppCommand.featureIDs.contains(id) || id.hasPrefix("focus-split-pane-") {
      return controller?.isCommandEnabled(id, enabledKey: enabledKey ?? EnabledKey.currentTabInSplit) == true
    }
    guard AppCommand.implemented.contains(id) || id == "go-to-last-tab" || id.hasPrefix("go-to-tab-") || id.hasPrefix("go-to-space-") else { return false }
    if id == "go-to-last-tab" { return !numberedItems.isEmpty }
    if ["rename-space", "change-profile", "clear-archive"].contains(id) {
      return !isClosing && controller != nil && window?.isVisible == true && window?.attachedSheet == nil
        && focusedSpace != nil && spaceProfileMenu == nil
    }
    if id == "focus-space" { return payload.flatMap(UUID.init(uuidString:)).map { model.space(id: SpaceID(rawValue: $0)) != nil } ?? false }
    if id.hasPrefix("go-to-tab-"), let n = Int(id.split(separator: "-").last ?? "") { return numberedItem(n) != nil }
    if id.hasPrefix("go-to-space-"), let n = Int(id.split(separator: "-").last ?? "") { return n <= model.spaces.count }
    if id == "pin-tab" { return selectedTab.map { !model.isPinned(tabID: $0.id) } ?? false }
    if id == "expand-all-folders" || id == "collapse-all-folders" {
      // Enabled when the focused Space has a folder in the other state (completion §2.5).
      let wantsExpanded = id == "collapse-all-folders"
      func any(_ nodes: [SidebarNode]) -> Bool {
        nodes.contains { node in node.folder.map { $0.isExpanded == wantsExpanded || (wantsExpanded && $0.peekedChildID != nil) || any($0.children) } ?? false }
      }
      return focusedSpace.map { any($0.pinned) || any($0.today) } ?? false
    }
    if id == "reset-all-tabs-in-space" {
      return focusedSpace.map { space in flattened(space.pinned).contains { tab in
        tab.pinnedURL.map { tab.url.host != $0.host || tab.url.path != $0.path } ?? false } } ?? false
    }
    if id == "unpin-tab" { return selectedTab.map { model.isPinned(tabID: $0.id) } ?? false }
    if Self.captureKinds[id] != nil { return hasWebPage }
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
    case EnabledKey.webPage:
      // A live http(s), file, or data page in the focused host (page-platform §7.1).
      return ["http", "https", "file", "data"].contains(selectedContent?.url?.scheme?.lowercased() ?? "")
    // Per-site cache clearing waits for Site Control E2 (App/Page/PageToolsCommands.swift).
    case EnabledKey.siteDataClearAvailable: return PageTools.siteDataClearAvailable && PageTools.isSitePage(selectedContent?.url)
    case EnabledKey.isTracing: return TroubleshootingActions.shared.isRecording
    case EnabledKey.notTracing: return !OEEngine.shared.isTracing
    default: return true
    }
  }
  @discardableResult
  func performAppCommand(_ original: String, payload: String? = nil) -> Bool {
    let id = AppCommand.canonicalID(original)
    #if OPEN_AUTOMATION
    AutomationShortcutTrace.record(id)
    #endif
    // Find owns its pane even when AppKit's field editor implements the native selector.
    if let tag = ["find": 1, "find-next": 2, "find-previous": 3, "find-and-replace": 12, "use-selection-to-find": 7][id] {
      guard selectedContent != nil else { return false }
      ensureFindController().perform(tag: tag); return true
    }
    if id == "jump-to-selection", selectedContent != nil { ensureFindController().jumpToSelection(); return true }
    // A Find bar keeps Esc even when the Exit menu is disabled (no Peek/split).
    if id == "exit-modal", window === NSApp.keyWindow, windowState.style == .standard,
       dismissFindForExit() { return true }
    if SystemCommandActions.selectors[id] != nil { return SystemCommandActions.perform(id) }
    if AppCommand.featureIDs.contains(id) || id.hasPrefix("focus-split-pane-") { return false }
    if let result = performSelectionAppCommand(id) { return result }
    if let result = performPageTool(id) { app.scheduleMenuRebuild(); return result }  // App/Page/PageToolsCommands.swift
    guard isAppCommandEnabled(id, payload: payload) else { return false }
    if id.hasPrefix("go-to-space-"), let n = Int(id.split(separator: "-").last ?? ""), n <= model.spaces.count {
      if let uuid = payload.flatMap(UUID.init(uuidString:)), let space = model.space(id: SpaceID(rawValue: uuid)) { focus(space: space) }
      else { focus(space: model.spaces[n - 1]) }; return true
    }
    if id == "go-to-last-tab", let item = numberedItems.last { selectNumberedItem(item); return true }
    if Self.captureKinds[id] != nil { return performCapture(id) }
    if id.hasPrefix("go-to-tab-"), let n = Int(id.split(separator: "-").last ?? ""), let item = numberedItem(n) {
      selectNumberedItem(payload.flatMap(UUID.init(uuidString:)).map { ItemID(rawValue: $0) } ?? item); return true
    }
    switch id {
    case "peek-email": return peekEmail()
    case "exit-modal": return controller?.exitModal() == true
    case "new-tab": newTab(nil)
    case "open-command-bar": focusAddressBar(nil)
    case "search-tabs": showCommandBar(.searchTabs)
    case "search-actions": showCommandBar(.searchActions)
    case "archive-tab":
      if let edu = EssentialShortcutsWindowController.shared.window, NSApp.keyWindow === edu { edu.close() }
      else if popupPanel?.isKeyWindow == true { closeTab(nil) }
      else if controller?.hasPeekController == true, controller?.peekController.isShown == true { controller?.peekController.dismissTop() }
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
    case "clear-unpinned-tabs":
      if let space = focusedSpace, !space.today.isEmpty { model.clearToday(space: space.id); controller?.showClearedToast() }
    case "next-tab", "cycle-tab-forward": cycleTab(by: 1)
    case "previous-tab", "cycle-tab-backward": cycleTab(by: -1)
    case "tab-switcher-forward": showTabSwitcher(by: 1)
    case "tab-switcher-backward": showTabSwitcher(by: -1)
    case "next-space": cycleSpace(by: 1)
    case "previous-space": cycleSpace(by: -1)
    case "focus-space": if let uuid = payload.flatMap(UUID.init(uuidString:)), let space = model.space(id: SpaceID(rawValue: uuid)) { focus(space: space) }
    // No key equivalents: docs/re/menus-and-hotkeys.md, Spaces / Archive;
    // docs/commands.md lists all four entries with “—”.
    case "rename-space":
      guard let controller else { return false }
      if windowState.sidebarMode == .hidden { return showRenameSpaceDialog() }
      controller.sidebar.layoutSubtreeIfNeeded()
      controller.sidebar.beginRename(nodeID: nil)
    case "change-profile":
      guard let controller else { return false }
      if windowState.sidebarMode == .hidden { controller.toggleSidebar() }
      controller.sidebar.layoutSubtreeIfNeeded()
      return showSpaceProfileMenu()
    case "clear-archive":
      app.settingsPresenter.requestClearArchive()
    case "new-space": return controller?.beginSpaceCreation() == true
    case "new-folder": if let space = focusedSpace { _ = model.createFolder(in: .spacePinned(space.id)) }
    case "reload": selectedContent?.reload()
    case "force-reload": selectedContent?.reloadIgnoringCache()
    case "stop-loading": selectedContent?.stopLoading()
    case "go-back": selectedContent?.goBack()
    case "go-forward": selectedContent?.goForward()
    case "zoom-in", "zoom-out", "zoom-actual-size": guard zoomPage(id) else { return false }
    case "print": selectedContent?.showPrintPanel()
    case "save-page-as": savePage()
    case "share-page": if let url = selectedContent?.url { NSSharingServicePicker(items: [url]).show(relativeTo: controller?.container.bounds ?? .zero, of: controller!.container, preferredEdge: .maxY) }
    // The Copy URL family and its toasts (page-platform §4.2, `App/Page/PageCommands.swift`).
    case "copy-url": guard copyURL() else { return false }
    case "copy-url-markdown": guard copyURLMarkdown() else { return false }
    case "copy-url-quote": guard copyURLQuote() else { return false }
    case "developer-tools": selectedContent?.showDevTools()
    case "view-source": if let url = selectedContent?.url { _ = openNewTab(url: URL(string: "view-source:\(url.absoluteString)")!, background: false) }
    case "toggle-sidebar": controller?.toggleSidebar()
    case "toggle-toolbar": return controller?.toggleToolbar() != nil
    case "reveal-current-tab": if let id = selectedTab?.id { if windowState.sidebarMode == .hidden { controller?.toggleSidebar() }; controller?.sidebar.reveal(nodeID: id); window?.makeFirstResponder(controller?.sidebar.focusedOutline) }
    case "expand-pinned-section", "collapse-pinned-section": if let space = focusedSpace { model.setPinnedSectionCollapsed(spaceID: space.id, collapsed: id == "collapse-pinned-section") }
    case "manage-extensions", "extension-shortcuts":
      let url = URL(string: id == "manage-extensions" ? "chrome://extensions" : "chrome://extensions/shortcuts")!
      if let space = focusedSpace, let tab = flattened(space.pinned + space.today).first(where: {
        // WebUI commits add a trailing slash to the root URL. Compare the same page.
        $0.url.scheme == url.scheme && $0.url.host() == url.host()
          && $0.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          && $0.url.query == url.query
      }) {
        selectTabForCommand(tab.id, spaceID: space.id)
      } else { _ = openNewTab(url: url, background: false) }
    case "add-extension": _ = openNewTab(url: URL(string: "https://chromewebstore.google.com/category/extensions")!, background: false)
    case "open-extensions-picker":
      // S6 App step: this factory has no reachable SiteControlController entry point yet.
      // The SCC integration supplies the §3.10 anchor and .extensionPicker presentation.
      NSSound.beep()
    case "expand-all-folders", "collapse-all-folders":
      // The key window's focused Space only; one undo step (completion §3.4).
      if let space = focusedSpace { _ = model.setAllFoldersExpanded(spaceID: space.id, expanded: id == "expand-all-folders") }
    case "add-to-favorites": if let tab = selectedTab, let profile = focusedProfile { _ = model.addFavorite(tabID: tab.id, to: profile.id) }
    case "remove-from-favorites": if let tab = selectedTab { _ = model.removeFavorite(tabID: tab.id, into: focusedSpace?.id) }
    case "mute-all-tabs", "unmute-all-tabs": app.media.muteAll(id == "mute-all-tabs")
    case "reset-all-tabs-in-space":
      // Pinned tabs of the focused Space that left their pinned URL (folders and splits
      // included, Favorites excluded); one undo step. Live pages navigate back.
      if let space = focusedSpace {
        for tabID in model.resetPinnedTabs(spaceID: space.id) { if let url = model.tab(id: tabID)?.pinnedURL { hosts[tabID]?.load(url) } }
      }
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
