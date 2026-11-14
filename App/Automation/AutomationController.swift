#if OPEN_AUTOMATION
  import AppKit
  import CryptoKit
  import OpenEngine
  import OpenModel
  import OpenWeb
  import OpenFeatures
  import OpenSidebar
  import OpenLiveData
  import OpenCommands
  import OpenSettings
  import OpenLibrary
  import OpenDesign
  import OpenExtensionsUI
  import OpenSpaceEditor
  import Synchronization
  import MachO
  import QuartzCore

  /// Opt-in, bounded observations of the actual clip view during a wheel run.
  /// Display-link callbacks sample bounds; they do not prove scanout or drawing.
  @MainActor
  private final class AutomationScrollCadence: NSObject {
    private weak var clip: NSClipView?
    private var link: CADisplayLink?
    private var observer: (any NSObjectProtocol)?
    private var oldPosts: Bool
    private var ticks: [Double] = []
    private var changes: [Double] = []
    private var origins: [[Double]] = []
    private var lastOrigin: NSPoint
    private let started = ProcessInfo.processInfo.systemUptime
    private var truncated = false
    init(clip: NSClipView) {
      self.clip = clip; oldPosts = clip.postsBoundsChangedNotifications; lastOrigin = clip.bounds.origin
      super.init()
      clip.postsBoundsChangedNotifications = true
      observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
        object: clip, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.changed() }
      }
      let display = clip.displayLink(target: self, selector: #selector(frame(_:)))
      link = display; display.add(to: .main, forMode: .common)
    }
    private func changed() {
      guard let clip, clip.bounds.origin != lastOrigin else { return }
      lastOrigin = clip.bounds.origin
      guard changes.count < 4096 else { truncated = true; stop(); return }
      changes.append(ProcessInfo.processInfo.systemUptime)
      origins.append([lastOrigin.x, lastOrigin.y])
    }
    @objc private func frame(_ display: CADisplayLink) {
      guard ticks.count < 4096, ProcessInfo.processInfo.systemUptime - started < 10 else {
        truncated = true; stop(); return
      }
      ticks.append(display.timestamp)
    }
    func stop() {
      link?.invalidate(); link = nil
      if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
      clip?.postsBoundsChangedNotifications = oldPosts
    }
    var state: [String: Any] {
      ["displayTimestamps": ticks, "boundsChangeTimestamps": changes, "origins": origins,
       "truncated": truncated, "running": link != nil,
       "scope": "App display-link callbacks and actual clip bounds changes; excludes drawing and scanout"]
    }
  }

  /// A CG scroll event with an explicit local destination. AppKit's CG bridge
  /// does not populate a synthetic scroll's window-relative location.
  private final class AutomationScrollEvent: NSEvent {
    private let native: NSEvent
    private weak var destination: NSWindow?
    private let number: Int
    private let point: NSPoint
    @MainActor init(native: NSEvent, window: NSWindow, point: NSPoint) {
      self.native = native; destination = window; number = window.windowNumber; self.point = point
      super.init()
    }
    required init?(coder: NSCoder) { return nil }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { destination }
    override var windowNumber: Int { number }
    override var locationInWindow: NSPoint { point }
    override var timestamp: TimeInterval { native.timestamp }
    override var modifierFlags: NSEvent.ModifierFlags { native.modifierFlags }
    override var cgEvent: CGEvent? { native.cgEvent }
    override var deltaX: CGFloat { native.deltaX }
    override var deltaY: CGFloat { native.deltaY }
    override var deltaZ: CGFloat { native.deltaZ }
    override var scrollingDeltaX: CGFloat { native.scrollingDeltaX }
    override var scrollingDeltaY: CGFloat { native.scrollingDeltaY }
    override var hasPreciseScrollingDeltas: Bool { native.hasPreciseScrollingDeltas }
    override var phase: NSEvent.Phase {
      switch native.cgEvent?.getIntegerValueField(.scrollWheelEventScrollPhase) ?? 0 {
      case 1: .began
      case 2: .changed
      case 4: .ended
      case 8: .cancelled
      default: []
      }
    }
    override var momentumPhase: NSEvent.Phase {
      switch native.cgEvent?.getIntegerValueField(.scrollWheelEventMomentumPhase) ?? 0 {
      case 1: .began
      case 2: .changed
      case 3: .ended
      default: []
      }
    }
    override var isDirectionInvertedFromDevice: Bool { native.isDirectionInvertedFromDevice }
  }

  /// Executes automation commands (docs/automation.md) on the main actor.
  /// Every command answers `{"id":…, "ok":true, "result":…}` or
  /// `{"id":…, "ok":false, "error":"…"}`. Commands touch only Open's own
  /// windows and pages; nothing here sends input to other apps.
  @MainActor
  final class AutomationController {
    var settingsPerformanceProbe: SettingsPerformanceProbe?
    var libraryPreparationHeartbeat: LibraryPreparationHeartbeat?
    struct Failure: Error { let message: String }

    var extensionRedrawMeasurement: ExtensionRedrawMeasurement?
    var extensionAutomation: ExtensionPromptPresenter { app.extensionPrompts }
    unowned let app: AppDelegate
    private let blockCounter = BlockCounter()
    /// An action menu kept by `ext-menu keep`, for a later `stale` select.
    private var staleMenu: OEExtensionActionMenu?
    private var pointerRequestID = 0
    private var scrollCadence: AutomationScrollCadence?
    private var nativeInputStart: Double = 0
    private var managerUndoObserver: (any NSObjectProtocol)?
    private var managerUndoCount = 0
    private var updaterModalObserver: (any NSObjectProtocol)?
    private var updaterModalEvents: [[String: Any]] = []
    var firstRunActionTask: Task<Void, Never>?
    var secretsFixtureTask: Task<Void, Never>?
    var secretsFixtureReport: [String: Any] = [:]
    var secretsFixtureStage = "idle"
    var secretsFixtureError = ""
    var importExtensionTask: Task<Void, Never>?
    var profileIndicatorMenuTitles: [String] = []
    var savePromptEvents: [[String: Any]] = []
    static weak var savePromptOwner: AutomationController?
    var savePromptPolicy = "hold"
    var realSavePromptAnswers = NSMapTable<OESavePrompt, NSString>.weakToStrongObjects()
    var realSavePromptFactories = NSMapTable<OESavePrompt, EngineWebContentHostFactory>.weakToWeakObjects()
    var realSavePromptPages = NSMapTable<OESavePrompt, OEWebContent>.weakToWeakObjects()
    // troubleshooting-setup recorder (page-platform Troubleshooting checks).
    private var revealedURLs: [URL] = []
    var profileProofWindows: [String: ProfileEngineProofWindow] = [:]
    var engineAPIProof: EngineAPIProof?
    var profileProofContexts: [String: OEBrowserContext] = [:]
    var recordedOpenWorldCallbacks: [[String: Any]] = []

    init(app: AppDelegate) {
      self.app = app; extensionAutomation.registerContexts(); Self.savePromptOwner = self
      if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_LIBRARY_PREPARATION_TRACE"] == "1" {
        libraryPreparationHeartbeat = LibraryPreparationHeartbeat()
        libraryPreparationHeartbeat?.start()
      }
    }

    var window: EngineWebContentHostFactory {
      get throws {
        guard let controller = app.frontWindowController, let w = app.hostFactories[controller.windowID] else { throw Failure(message: "no window") }
        return w
      }
    }

    func handle(_ data: Data) async -> Data {
      let observationStart = ProcessInfo.processInfo.systemUptime
      var id: Any = NSNull()
      var response: [String: Any]
      var inputCommand = false
      do {
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cmd = request["cmd"] as? String
        else { throw Failure(message: "expected {\"cmd\": …}") }
        id = request["id"] ?? NSNull()
        let traceName = String(cmd.prefix(48))
        PeekMotionTrace.mark("socket.begin." + traceName)
        defer { PeekMotionTrace.mark("socket.end." + traceName) }
        let args = request["args"] as? [String: Any] ?? [:]
        inputCommand = cmd == "editor-act" || cmd == "key" || cmd == "focus" || cmd == "little-open-link-click" || (cmd == "window-focus" && args["activate"] as? Bool == true)
        if cmd == "profiles-shell", ["press", "type-delete", "icon-symbol", "indicator-menu"].contains(args["action"] as? String ?? "") { inputCommand = true }
        if ["space-manager-drag", "sidebar-click", "sidebar-key", "hover"].contains(cmd) { inputCommand = true }
        if cmd == "boost-editor", ["key", "type", "tap", "drag"].contains(args["action"] as? String ?? "") { inputCommand = true }
        if cmd == "boost-gallery-ui", args["action"] as? String != "state" { inputCommand = true }
        if cmd == "first-run", args["action"] as? String == "focus" { inputCommand = true }
        if inputCommand { nativeInputStart = 0 }
        let result = try await run(cmd, args)
        response = ["id": id, "ok": true, "result": result]
      } catch let failure as Failure {
        response = ["id": id, "ok": false, "error": failure.message]
      } catch {
        response = ["id": id, "ok": false, "error": "\(error.localizedDescription)"]
      }
      response["observationStart"] = observationStart
      if inputCommand { response["nativeInputStart"] = nativeInputStart }
      let safe =
        JSONSerialization.isValidJSONObject(response)
        ? response : ["id": id, "ok": false, "error": "unserializable result"]
      return (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func mallocZoneNames() -> [String] {
      var zones: UnsafeMutablePointer<vm_address_t>?
      var count: UInt32 = 0
      guard malloc_get_all_zones(mach_task_self_, nil, &zones, &count) == KERN_SUCCESS, let zones else { return [] }
      return (0..<Int(count)).map { i in
        UnsafePointer<malloc_zone_t>(bitPattern: UInt(zones[i]))?.pointee.zone_name.map { String(cString: $0) } ?? ""
      }
    }

    // MARK: Dispatch

    private func run(_ cmd: String, _ a: [String: Any]) async throws -> Any {
      extensionAutomation.registerContexts()
      // App lifecycle commands remain available after the final window closes.
      switch cmd {
      case "updater-view-tree":
        var seen: Set<ObjectIdentifier> = []
        var webViews: [String] = []
        let webClasses = ["WKWebView", "WebView"].compactMap(NSClassFromString)
        func visit(_ view: NSView) {
          guard seen.insert(ObjectIdentifier(view)).inserted else { return }
          if webClasses.contains(where: { view.isKind(of: $0) }) { webViews.append(NSStringFromClass(type(of: view))) }
          for child in view.subviews { visit(child) }
        }
        for window in NSApp.windows { if let content = window.contentView { visit(content.superview ?? content) } }
        let notes = app.updater?.userDriver.updateWindow?.notes?.text
        let banners = app.windowControllers.compactMap { controller -> [String: Any]? in
          guard let banner = controller.sidebar.updateBanner else { return nil }
          return ["title": banner.titleLabel.stringValue, "subtitle": banner.subtitleLabel.stringValue,
            "frame": rect(banner.frame), "titleFrame": rect(banner.titleLabel.frame),
            "subtitleFrame": rect(banner.subtitleLabel.frame),
            "subtitleColor": colorComponents(banner.subtitleLabel.textColor)]
        }
        return ["webViewCount": webViews.count, "webViewClasses": webViews,
          "viewCount": seen.count, "notesViewClass": notes.map { NSStringFromClass(type(of: $0)) } ?? "",
          "notesIsTextView": notes is NSTextView, "bannerStyles": banners]
      case "updater-banner-width":
        guard let width = a["width"] as? Double, (164...400).contains(width), let controller = app.frontWindowController else { throw Failure(message: "expected banner width 164...400") }
        controller.model.setSidebarWidth(windowID: controller.windowID, width: width)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return width
      case "updater-menu":
        guard let (menu, index) = findMenuItem("check-for-updates", in: NSApp.mainMenu), let item = menu.item(at: index) else { throw Failure(message: "missing update menu item") }
        let enabled = menuEnabled(item)
        return ["title": item.title, "enabled": enabled, "badgeCount": item.badge?.itemCount ?? 0,
          "canCheck": app.updater?.canCheckForUpdates ?? true]
      case "updater-act": return app.updater?.userDriver.performAutomationAction(a["action"] as? String ?? "") ?? false
      case "updater-modal-alert":
        let action = a["action"] as? String ?? "state"
        if action == "state" { return updaterModalEvents }
        if let observer = updaterModalObserver { NotificationCenter.default.removeObserver(observer) }
        updaterModalObserver = nil
        if action == "disarm" { return true }
        guard action == "arm", let button = a["button"] as? Int, (0...1).contains(button) else {
          throw Failure(message: "expected arm with button 0 or 1, state, or disarm")
        }
        updaterModalEvents.removeAll()
        updaterModalObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
          object: nil, queue: .main) { [weak self] notification in
          guard let presented = notification.object as? NSWindow else { return }
          MainActor.assumeIsolated {
            guard let self, let alert = self.app.updater?.userDriver.alert,
              presented === alert.window else { return }
            // CEF may hold main-queue tasks inside a native modal loop. Observe
            // the real alert and press its button from that loop, as Downloads does.
            RunLoop.main.perform(inModes: [.modalPanel]) { [weak self, weak alert] in
              MainActor.assumeIsolated {
                guard let self, let alert, alert.buttons.indices.contains(button), self.updaterModalEvents.isEmpty else { return }
                var row = self.describe(alert.window)
                row["text"] = self.windowText(alert.window)
                row["informativeText"] = alert.informativeText
                row["buttons"] = alert.buttons.map { ["title": $0.title, "enabled": $0.isEnabled] }
                row["appModal"] = NSApp.modalWindow === alert.window
                row["active"] = NSApp.isActive
                row["browserWindows"] = self.app.windowControllers.count
                row["updaterBeforeAnswer"] = self.app.updater?.automationState
                row["pressedButton"] = button
                self.updaterModalEvents.append(row)
                if let observer = self.updaterModalObserver { NotificationCenter.default.removeObserver(observer) }
                self.updaterModalObserver = nil
                alert.buttons[button].performClick(nil)
              }
            }
          }
        }
        return true
      case "updater-background-check": app.updater?.checkInBackgroundForAutomation(); return true
      case "updater-images": return (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
      case "child-dialog-button": return try await childDialogButton(a)
      case "updater-state": return app.updater?.automationState ?? ["created": false, "started": false]
      case "profile-engine": return try await runProfileEngineCommand(a)
      case "save-prompt": return try await savePrompt(a)
      case "events":
        // Keep Section 11's Little Open routing. Every event, including password
        // offers and Manage links, is recorded by the factory that owns its page.
        let owner: EngineWebContentHostFactory?
        if let number = a["window"] as? Int {
          owner = app.hostFactories.values.first { $0.window?.windowNumber == number }
            ?? app.littleOpenHosts.values.first { $0.view.window?.windowNumber == number }?.owner
        } else {
          owner = app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
        }
        let number = a["window"] as? Int ?? owner?.window?.windowNumber
        let completions = savePromptEvents.filter { number == nil || $0["window"] as? Int == number }
        savePromptEvents.removeAll { number == nil || $0["window"] as? Int == number }
        return (owner?.drainEvents() ?? []) + completions
      case "credentials": return try await credentialCounts(a)
      case "import-secrets-fixture": return try await importSecretsFixture(a)
      case "import-secrets-state": return secretsImportState()
      case "credentials-prefs": return try credentialPreferences(a)
      case "engine-contexts":
        guard app.engineReady else { return [] as [String] }
        return Set((OEEngine.shared.contexts + [OEEngine.shared.defaultContext]).map(\.identifier)).sorted()
      case "engine-api": return try await runEngineAPICommand(a)
      case "speed-trace": return try await speedTrace(a)
      case "profiles-shell": return try await profilesShell(a)
      case "incognito-state": return try incognitoState(a)
      case "incognito-screen": return try incognitoScreen(a)
      case "first-run": return try await runFirstRun(a)
      case "onboarding": return try await runOnboarding(a)
      case "mouse" where app.onboardingWindowController?.window?.isVisible == true:
        return try await mouse(a, nil)
      case "welcome": return try welcome(a)
      case "easel": return try easel(a)
      case "note": return try note(a)
      case "blank-window":
        // action=move-to space=‹title›: the header's "Move to…" menu item (front window).
        if a["action"] as? String == "move-to" {
          guard let title = a["space"] as? String, let controller = try window.controller else { throw Failure(message: "no window") }
          return controller.sidebar.chooseBlankHeaderMoveTo(title)
        }
        if a["action"] as? String == "saved-file" { return app.blankWindowsFile.path }
        return try blankWindowState()
      case "import-extensions": return try await runImportExtensions(a)
      case "engine-close-activation": return try probeEngineCloseActivation()
      case "engine-activation-state": return try engineActivationState(a)
      case "timing" where app.frontWindowController == nil:
        var marks = LaunchTiming.shared.report
        marks["kernelProcessStart"] = LaunchTiming.shared.hasKernelProcessStart
        return marks
      case "startup" where app.frontWindowController == nil: return app.startupEvidence
      case "spaces" where app.frontWindowController == nil:
        return app.model.spaces.map { ["id": $0.id.description, "title": $0.title ?? "", "profile": $0.profileID.description, "pinned": $0.pinned.count, "today": $0.today.count, "focused": false] as [String: Any] }
      case "tabs" where app.frontWindowController == nil: return [] as [String]
      case "windows" where app.frontWindowController == nil:
        return NSApp.windows.filter { $0.identifier?.rawValue != "onboarding-dim" }.map { nativeWindow in
          var row = describe(nativeWindow)
          if a["accessibility"] as? Bool == true { row["text"] = windowText(nativeWindow) }
          if a["accessibilityRoles"] as? Bool == true { row["roles"] = windowAccessibilityRoles(nativeWindow) }
          return row
        }
      case _ where Self.littleOpenCommands.contains(cmd): return try await runLittleOpenCommand(cmd, a)
      case "developer-panel": return try developerPanelCommand(a)
      case "site-controls": return try await runSiteControl(a)
      case "site-controls-idle": return try siteControlIdle(a)
      case "theme-get", "theme-set", "editor-open", "editor-act", "editor-close", "editor-state", "creation-state":
        if cmd == "editor-act" { nativeInputStart = ProcessInfo.processInfo.systemUptime }
        return try await runEditorCommand(cmd, a)
      case "key": return try await sendKey(a, app.frontWindowController.flatMap { app.hostFactories[$0.windowID] })
      case "snapshot": return try await snapshot(a, app.frontWindowController.flatMap { app.hostFactories[$0.windowID] })
      case "library-captures-state": return try libraryCapturesState(a)
      case "ext-prompt", "ext-manage", "ext-commands", "ext-run-command", "ext-windows", "ext-omnibox", "ext-strip", "ext-click", "ext-popup-state", "ext-picker", "ext-hover", "ext-ui-menu", "ext-redraw-measure", "ext-shortcuts":
        return try await runExtensionCommand(cmd, a)
      case "hotkey-probe":
        // Tries a system-wide registration of one shortcut and releases it at once: `exists` means another
        // registration (Chromium's extension global-shortcut listener, or another app) holds the key.
        guard let key = a["key"] as? String, !key.isEmpty, key.utf8.count <= 16 else { throw Failure(message: "bad key") }
        var modifiers: ShortcutModifiers = []
        for name in a["modifiers"] as? [String] ?? [] {
          switch name {
          case "command", "cmd": modifiers.insert(.command)
          case "shift": modifiers.insert(.shift)
          case "option": modifiers.insert(.option)
          case "control": modifiers.insert(.control)
          default: throw Failure(message: "bad modifier \(name)")
          }
        }
        let shortcut = KeyboardShortcut(key: key, modifiers: modifiers)
        let probe = GlobalHotkeyService(identifier: 9_999)
        defer { probe.unregister() }
        do { try probe.register(shortcut: shortcut) {}; return ["registered": true, "error": ""] }
        catch { return ["registered": false, "error": String(describing: error)] }
      case "applescript": return try await runAppleScript(a)
      case "routing-log": return routingLog()
      case "default-browser-state": return defaultBrowserState()
      case _ where Self.liveDataCommands.contains(cmd): return try await runLiveDataCommand(cmd, a)
      case "favorites-empty-state": return try runFavoritesEmptyCommand(a)
      case "history-state", "history-clear", "library-history-state", "library-history-delete":
        return try await runHistoryCommand(cmd, a)
      case "archive-sweep", "archive-clock", "archive-state", "archive-wake", "profile-archive-setting", "archive-list", "archive-banner-state", "archive-banner-action":
        return try await runArchiveCommand(cmd, a)
      case _ where Self.downloadCommands.contains(cmd): return try await runDownloadCommand(cmd, a)
      case "metrics": return await metrics(interval: a["interval"] as? Double ?? 1)
      #if DEBUG
      case "adblock-memory": return try await adBlockMemory(a)
      #endif
      case _ where Self.mediaCommands.contains(cmd): return try await runMediaCommand(cmd, a)
      case _ where Self.notificationCommands.contains(cmd): return try await runNotificationCommand(cmd, a)
      case _ where Self.sleepCommands.contains(cmd): return try await runSleepCommand(cmd, a)
      case "ping":
        return [
          "pid": Int(getpid()), "chromium": OEEngine.shared.chromiumVersion, "cef": OEEngine.shared.cefVersion,
          "userData": OEEngine.shared.configuration.userDataDirectory.path,
          "preferencesDomain": AutomationPreferences.domain,
          "root": app.directories.root.path,
          // Malloc zone names in registration order: with OpenEngine's early
          // delegating zone, PartitionAlloc replaced it in place, so the
          // system zone stays second (docs/engine-fork.md).
          "mallocZones": Self.mallocZoneNames(),
        ]
      case "menu-context":
        return ["services": NSApp.servicesMenu?.title == "Services", "window": NSApp.windowsMenu?.title == "Window",
          "font": NSFontManager.shared.fontMenu(false)?.title == "Font"]
      case "activation-events": return app.activationTrace.events
      case "yield-activation":
        // Read the mapped executable from the kernel, not LaunchServices'
        // cached executableURL. CEF may use a persistent hard link; the peer
        // must map this exact file, never a separate copy with equal bytes.
        guard let pid = a["pid"] as? Int32, pid != getpid(),
          let target = NSRunningApplication(processIdentifier: pid),
          let targetFile = Self.mappedExecutableURL(pid),
          let ownFile = Self.mappedExecutableURL(getpid()),
          let targetAttributes = try? FileManager.default.attributesOfItem(atPath: targetFile.path),
          let ownAttributes = try? FileManager.default.attributesOfItem(atPath: ownFile.path),
          let targetDevice = targetAttributes[.systemNumber] as? NSNumber,
          let targetInode = targetAttributes[.systemFileNumber] as? NSNumber,
          let ownDevice = ownAttributes[.systemNumber] as? NSNumber,
          let ownInode = ownAttributes[.systemFileNumber] as? NSNumber,
          targetDevice == ownDevice, targetInode == ownInode
        else { throw Failure(message: "activation peer must be another instance of this exact Open executable") }
        NSApp.yieldActivation(to: target); return true
      case "native-focus-state":
        return ["active": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? 0,
          "uptime": ProcessInfo.processInfo.systemUptime,
          "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown",
          "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0] as [String: Any]
      case "menu-tree":
        NSApp.mainMenu?.update()
        return speedMenuTree(NSApp.mainMenu)
      case "menu-state":
        NSApp.mainMenu?.update()
        return menuRows(NSApp.mainMenu)
      case "menu-key-render":
        guard let path = a["path"] as? String else { throw Failure(message: "missing render path") }
        return try renderMenuKeys(to: path)
      case "command" where (a["id"] as? String).flatMap({ CommandRegistry.byID[$0] }).map({ $0.menuPath == nil }) == true:
        guard let id = a["id"] as? String, CommandRegistry.byID[id] != nil,
          let controller = try window.controller,
          controller.isCommandEnabled(id, enabledKey: CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always)
        else { throw Failure(message: "unknown or disabled command") }
        controller.performCommand(id); return true
      case "menu-perform", "command":
        guard let id = a["id"] as? String, let (menu, index) = findMenuItem(id, in: NSApp.mainMenu) else { throw Failure(message: "unknown menu item") }
        let item = menu.item(at: index)!
        guard menuEnabled(item) else { throw Failure(message: "disabled menu item") }
        menu.performActionForItem(at: index); return true
      case "reload-keybindings": app.prepareCommandServices(); app.reloadKeyBindings(); return true
      case "hotkey-state":
        return ["prepared": app.commandServicesPrepared, "attempts": app.hotkeyAttempts, "registered": app.hotkeyService?.isRegistered ?? false,
          "error": app.hotkeyError ?? "", "enabled": UserDefaults.standard.object(forKey: "open.links.littleOpenHotkeyEnabled") as? Bool ?? true] as [String: Any]
      case "settings-pane":
        // Shows Settings on one pane through the real presenter (a fixture step for pane-switch checks).
        guard let raw = a["pane"] as? String, let pane = PaneID(rawValue: raw) else { throw Failure(message: "unknown pane") }
        app.settingsPresenter.show(pane: pane)
        return pane.rawValue
      case "settings-state":
        let adapter = app.settingsPresenter
        return ["pane": adapter.settings.selectedPane.rawValue, "selectedProfile": adapter.settings.selectedProfileID.description,
          "settings": adapter.settingsPresenter.window?.windowNumber ?? 0,
          "settingsVisible": adapter.settingsPresenter.window?.isVisible ?? false,
          "scrollTarget": adapter.settings.scrollTarget ?? "",
          "generalError": adapter.settings.general.errorText, "advancedStatus": adapter.settings.advanced.statusText,
          "library": adapter.libraryWindow?.windowNumber ?? 0,
          "librarySection": adapter.library?.section.rawValue ?? "", "archiveRows": adapter.library?.archiveRows.count ?? 0,
          "boostsPresentation": adapter.library?.boostsPresentation.rawValue ?? "",
          "boostsProfile": adapter.library?.historyProfileID.description ?? "",
          "historyRows": adapter.library?.historyRows.count ?? 0,
          "archive": (adapter.library?.archiveRows ?? []).map { ["id": $0.id.description, "url": $0.url.absoluteString] },
          "sharedArchives": adapter.library?.archives.allSatisfy { $0.value === app.archiveSink.store(for: $0.key) } ?? false,
          "sameSnapshot": adapter.settings.snapshot === app.snapshotStore,
          "hotkey": adapter.settings.bool("open.links.littleOpenHotkeyEnabled"),
          "external": adapter.settings.bool("open.links.externalInLittleOpen")] as [String: Any]
      case "settings-profile": return try settingsProfile(a)
      case "settings-ui": return try settingsUI(a)
      case "settings-lifetime": return ["modelCreated": app.settingsPresenter.hasSettingsModel]
      case "settings-link":
        guard let raw = a["url"] as? String, let url = URL(string: raw) else { throw Failure(message: "invalid Settings URL") }
        return ["accepted": app.settingsPresenter.showSettingsURL(url)]
      case "settings-perf": return try settingsPerformance(a)
      case "settings-profile-page": return try settingsProfilePage(a)
      case "settings-icon": return try settingsIcon(a)
      case "settings-adblock": return try await settingsAdBlock(a)
      case "settings-adblock-site": return try settingsAdBlockSite(a)
      #if DEBUG
      case "settings-adblock-profile": return try await settingsAdBlockProfile(a)
      case "settings-adblock-lifecycle": return try await settingsAdBlockLifecycle(a)
      #endif
      case "settings-adblock-engine": return settingsAdBlockEngine()
      case "runloop-turns":
        guard let trace = RunLoopTurnTrace.current else { throw Failure(message: "start with OPEN_AUTOMATION_RUNLOOP_TURNS=1") }
        return trace.json(minimumMilliseconds: a["minimumMs"] as? Double ?? 8, fromLaunchMilliseconds: a["fromLaunchMs"] as? Double ?? 0)
      case "startup-trace":
        guard let trace = StartupMainThreadTrace.current else { throw Failure(message: "start with OPEN_AUTOMATION_STARTUP_TRACE=1") }
        return trace.json(minimumMilliseconds: a["minimumMs"] as? Double ?? 8)
      case "settings-toggle":
        let settings = app.settingsPresenter.settings
        if a["name"] as? String == "updates" { settings.general.updates.toggle(); return settings.general.updates }
        if a["name"] as? String == "hotkey" { settings.links.littleOpenHotkeyEnabled.toggle() }
        else { settings.links.externalLinksInLittleOpen.toggle() }
        return settings.commitLinks()
      case "pasteboard-preserve": return AutomationPasteboard.preserve()
      case "pasteboard-restore": return AutomationPasteboard.restore()
      case "pasteboard":
        // `text`: replace the contents first (checks that must see a fresh copy).
        if let text = a["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        return NSPasteboard.general.string(forType: .string) ?? ""
      case "pasteboard-write":
        guard let value = a["text"] as? String else { throw Failure(message: "missing clipboard text") }
        NSPasteboard.general.clearContents(); return NSPasteboard.general.setString(value, forType: .string)
      case "shell-windows":
        return app.windowControllers.map { ["id": $0.windowID.description, "number": $0.window?.windowNumber ?? 0,
          "title": $0.window?.title ?? "", "level": $0.window?.level.rawValue ?? 0] as [String: Any] }
      case "window-reopen":
        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        return true
      case "save":
        app.saveState()
        return app.snapshotStore.fileURL.path
      case "quit":
        app.quitWarning.harnessQuit = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
        return true
      case "quit-warning":
        if let button = a["button"] as? String {
          guard ["quit", "cancel"].contains(button) else { throw Failure(message: "expected quit or cancel") }
          app.quitWarning.buttonForAutomation = button
        }
        if a["request"] as? Bool == true {
          app.quitWarning.harnessQuit = false
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.app.performCommand("quit-open") }
        }
        return app.quitWarning.alerts
      case "library-open":
        let section: LibrarySection?
        if let value = a["section"] {
          guard let raw = value as? String, let parsed = LibrarySection(rawValue: raw == "easels" ? "media" : raw) else { throw Failure(message: "unknown Library section") }
          section = parsed
        } else { section = nil }
        switch a["entry"] as? String ?? "command" {
        case "command":
          if let section { app.settingsPresenter.showLibrary(section: section) }
          else { app.performCommand("manage-spaces") }
        case "space-menu":
          guard section == nil || section == .spaces else { throw Failure(message: "Space menu opens Spaces only") }
          let factory = try window
          guard let menu = factory.controller?.sidebar.contextMenu(nodeID: nil),
            let index = menu.items.firstIndex(where: { $0.title == "Manage Spaces…" && $0.isEnabled })
          else { throw Failure(message: "Space menu has no Manage Spaces entry") }
          menu.performActionForItem(at: index)
        default: throw Failure(message: "unknown Library entry")
        }
        if a["section"] as? String == "easels", let panel = app.settingsPresenter.activeLibrarySession?.panel {
          guard panel.sections.contains(.easels) else { throw Failure(message: "Easels is hidden") }
          panel.select(.easels)
        }
        await Task.yield()
        return spaceManagerState()
      case "library", "library-state", "library-ui": return try libraryPanelAction(a)
      case "library-performance": return try await libraryPerformance(a)
      case "space-manager-state": return spaceManagerState()
      case "defaults":
        // Reads (and with `value`, writes) one Open preference in this app's own domain.
        guard let key = a["key"] as? String, key.hasPrefix("open.") || ["libraryShowsEasels", "libraryMediaFolderSources"].contains(key) else { throw Failure(message: "unknown defaults domain key") }
        if a["persistent"] as? Bool == true { return UserDefaults.standard.persistentDomain(forName: AutomationPreferences.domain)?[key] ?? NSNull() }
        if let value = a["value"] {
          UserDefaults.standard.set(value is NSNull ? nil : value, forKey: key)
          app.settingsPresenter.refreshPreferencesIfLoaded()
          if key == "open.advanced.tabSleepMode" { app.tabSleep.reconcileSettingsPolicy() }
          if key.hasPrefix("open.favorites.") { NotificationCenter.default.post(name: FavoriteTileSettings.didChange, object: UserDefaults.standard) }
          app.scheduleMenuRebuild()
        }
        if a["persistent"] as? Bool == true {
          return UserDefaults.standard.persistentDomain(forName: AutomationPreferences.domain)?[key] ?? NSNull()
        }
        return UserDefaults.standard.object(forKey: key) ?? NSNull()
      case "tab-switcher-state":
        guard let switcher = try window.controller!.existingTabSwitcher else {
          return ["created": false, "presented": false, "active": false, "selected": "", "items": [], "visible": [], "viewCount": 0, "monitoringModifiers": false] as [String: Any]
        }
        return ["created": true, "monitoringModifiers": switcher.isMonitoringModifiers, "presented": switcher.isPresented, "active": switcher.isActive, "selected": switcher.selectedID?.description ?? "",
          "items": switcher.items.map { $0.id.description }, "visible": switcher.visibleIDs.map(\.description),
          "viewCount": switcher.view == nil ? 0 : 1] as [String: Any]
      case "sound-effect":
        // The App's SoundEffects path: plays only with open.advanced.playSoundEffects on.
        guard let raw = a["effect"] as? String, let effect = SoundEffects.Effect(rawValue: raw) else { throw Failure(message: "unknown sound effect") }
        let played = SoundEffects.shared.play(effect)
        return ["played": played, "resource": SoundEffects.resourceURL(for: effect)?.lastPathComponent ?? "",
          "loaded": SoundEffects.shared.loadedSoundCount, "plays": SoundEffects.shared.playCount] as [String: Any]
      case "alert":
        // Presses a button of the alert sheet attached to a browser or the Library window.
        let library = app.settingsPresenter.libraryWindow
        let candidates = (a["window"] as? String == "library" ? [library].compactMap { $0 } : app.windowControllers.compactMap(\.window) + [library].compactMap { $0 })
        guard let sheet = candidates.compactMap(\.attachedSheet).first else { throw Failure(message: "no attached alert sheet") }
        var buttons: [NSButton] = [], texts: [String] = []
        func walk(_ view: NSView, _ depth: Int) {
          guard depth < 16 else { return }
          if let button = view as? NSButton, !button.title.isEmpty { buttons.append(button) }
          else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
          for child in view.subviews { walk(child, depth + 1) }
        }
        if let content = sheet.contentView { walk(content, 0) }
        let result: [String: Any] = ["texts": texts, "buttons": buttons.map(\.title), "window": sheet.sheetParent?.windowNumber ?? 0]
        guard let title = a["button"] as? String else { return result }
        guard let button = buttons.first(where: { $0.title == title }) else { throw Failure(message: "alert has no button \(title)") }
        button.performClick(nil)
        await Task.yield()
        return result
      case "sidebar-click": return try await sidebarClick(a)
      case "favorite-click": return try await favoriteClick(a)
      case "favorite-badge": return try favoriteBadge(a)
      case "sidebar-key": return try await sidebarKey(a)
      case "hover": return try await sidebarHover(a)
      case "selection": return try sidebarController(a).context.selection.ids.map(\.description)
      case "sidebar-drop":
        let controller = try sidebarController(a)
        guard let raw = a["nodes"] as? [String], let parent = a["parent"] as? [String: Any],
          let text = parent["id"] as? String, let uuid = UUID(uuidString: text), let index = a["index"] as? Int, index >= 0 else { throw Failure(message: "invalid sidebar drop") }
        let ids = try raw.map { text -> ItemID in
          guard let uuid = UUID(uuidString: text) else { throw Failure(message: "invalid drop node") }
          return ItemID(rawValue: uuid)
        }
        let destination: NodeParent
        switch parent["kind"] as? String {
        case "today": destination = .spaceToday(SpaceID(rawValue: uuid))
        case "pinned": destination = .spacePinned(SpaceID(rawValue: uuid))
        case "folder": destination = .folder(ItemID(rawValue: uuid))
        case "favorites": destination = .favorites(ProfileID(rawValue: uuid))
        default: throw Failure(message: "invalid drop parent")
        }
        return controller.context.performNodeDrop(ids: ids, to: destination, index: index)
      case "sidebar-drag": return try sidebarDrag(a)
      case "sidebar-clear-state":
        let controller = try sidebarController(a)
        controller.contentView.layoutSubtreeIfNeeded()
        let frame = controller.sidebar.clearTodayFrame().map { controller.contentView.convert($0, from: controller.sidebar) }
        return ["visible": controller.sidebar.isClearTodayVisible, "frame": frame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []] as [String: Any]
      case "sidebar-row":
        // A sidebar row's frame and center in the front browser window (top-left origin).
        guard let controller = app.frontWindowController, let raw = a["node"] as? String, let uuid = UUID(uuidString: raw),
          let frame = controller.sidebar.rowFrame(nodeID: ItemID(rawValue: uuid)) else { throw Failure(message: "no such sidebar row") }
        controller.contentView.layoutSubtreeIfNeeded()
        let inRoot = controller.contentView.convert(frame, from: controller.sidebar)
        let style = controller.context.focusedSpace.map { controller.context.style(for:$0) }
        let contentAppearance = style?.resolvedAppearance(system:controller.context.systemAppearance) ?? controller.context.systemAppearance
        let ink = style?.titleColor(contentAppearance).nsColor.usingColorSpace(.sRGB)
        return ["foreground":ink.map { [$0.redComponent,$0.greenComponent,$0.blueComponent,$0.alphaComponent] } ?? [], "frame": [inRoot.minX, inRoot.minY, inRoot.width, inRoot.height], "point": [inRoot.midX, inRoot.midY], "unreadBadge": controller.sidebar.unreadDotFrame(nodeID: ItemID(rawValue: uuid)) != nil, "current": controller.sidebar.isCurrentRow(nodeID: ItemID(rawValue: uuid))] as [String: Any]
      case "preview-state":
        return try previewState(a)
      case "page-selection", "swipe", "swipe-indicator":
        // Engine page API (EP-1, EP-2, EP-3); App/Automation/AutomationPageEngine.swift.
        return try await runPageEngineCommand(cmd, try content(a, try window), a)
      case "capture", "capture-state", "capture-action", "captures", "capture-portrait":
        // Capture tool (page-platform §8.3); App/Automation/AutomationCapture.swift.
        return try await runCaptureCommand(cmd, a)
      case "toast-undo":
        guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
        return controller.pressToastUndo()
      case "toasts":
        // The toasts of the front browser window, newest first (page-platform §8.3). Frames are in
        // the window content (top-left origin); `panel` is the anchor they sit in.
        guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
        let center = controller.toasts, overlay = controller.toastOverlay, root = controller.contentView
        return ["panel": rect(root.convert(overlay.bounds, from: overlay)), "shown": center.shownCount,
          "toasts": center.snapshots.map { s -> [String: Any] in
            ["title": s.content.title, "subtitle": s.content.subtitle ?? NSNull(), "symbol": s.content.symbol ?? NSNull(),
             "accessory": s.content.accessoryName, "coalescingKey": s.content.coalescingKey ?? NSNull(),
             "frame": rect(root.convert(s.frame, from: overlay)),
             "accessoryFrame": s.accessoryFrame.map { rect(root.convert($0, from: overlay)) } ?? NSNull(),
             "age": s.age, "lifetime": s.lifetime ?? NSNull(), "sticky": s.content.isSticky,
             "exiting": s.isExiting, "hovered": s.isHovered]
          }] as [String: Any]
      case "quote-offer":
        // The last Shared Quotes offer of the key window: page answer time (s) and whether it showed.
        guard let controller = app.frontWindowController, let factory = app.hostFactories[controller.windowID] else { throw Failure(message: "no browser window") }
        return factory.lastQuoteOffer
      case "toast-hover":
        // The pointer enters (`inside` true) or leaves the visible toast at `index` (newest first).
        guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
        let index = (a["index"] as? Int) ?? 0
        return controller.toasts.setHovered(at: index, a["inside"] as? Bool ?? true)
      case "toast-action":
        // Clicks the button of the visible toast at `index` (newest first, default 0) through the real button.
        guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
        let index = (a["index"] as? Int) ?? Int(a["index"] as? String ?? "") ?? 0
        return controller.toasts.performAccessory(at: index)
      case "library-button-menu":
        // The Library button's real right-click menu: list it, or choose one item by title.
        guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
        guard let menu = controller.sidebar.libraryButtonContextMenu() else { return ["items": []] }
        if let title = a["item"] as? String {
          guard let index = menu.items.firstIndex(where: { $0.title == title && $0.isEnabled }) else { throw Failure(message: "no enabled item \(title)") }
          menu.performActionForItem(at: index); await Task.yield()
        }
        let fresh = controller.sidebar.libraryButtonContextMenu() ?? menu
        return ["items": fresh.items.map { ["title": $0.title, "enabled": $0.isEnabled, "on": $0.state == .on] as [String: Any] }]
      case "plus-popover":
        // The bottom-bar "+" popover: op=toggle (as a click on "+"), op=key code=<125|126|36|53>, or state only.
        guard let controller = app.frontWindowController else { throw Failure(message: "no window") }
        switch a["op"] as? String {
        case "toggle"?: controller.sidebar.togglePlusPopover()
        case "key"?:
          guard let code = a["code"] as? Int, [125, 126, 36, 76, 53].contains(code) else { throw Failure(message: "unsupported key code") }
          controller.sidebar.plusPopoverKey(UInt16(code))
        case nil: break
        default: throw Failure(message: "unknown plus-popover op")
        }
        return controller.sidebar.plusPopoverState
      case "sidebar-menu-items":
        // The right-click menu of a row (or the Space with no node) in Arc's notation:
        // "—" for a separator, "Title ▸" for a submenu; `disabled` lists disabled titles.
        // `path` ("Move to") lists a submenu instead.
        guard let controller = app.frontWindowController else { throw Failure(message: "no window") }
        var nodeID: ItemID?
        if let raw = a["node"] {
          guard let text = raw as? String, let uuid = UUID(uuidString: text), app.model.node(id: ItemID(rawValue: uuid)) != nil else { throw Failure(message: "invalid sidebar node") }
          nodeID = ItemID(rawValue: uuid)
        }
        // `surface=url-field`: the URL field's right-click menu instead of a row's.
        guard var level = a["surface"] as? String == "url-field" ? controller.sidebar.urlFieldMenu() : controller.sidebar.contextMenu(nodeID: nodeID) else { throw Failure(message: "no sidebar menu") }
        if let path = a["path"] as? String {
          for part in path.split(separator: "/") {
            guard let sub = level.items.first(where: { $0.title == part && !$0.isAlternate })?.submenu else { throw Failure(message: "\(part) has no submenu") }
            level = sub
          }
        }
        let visible = level.items.filter { !$0.isHidden && !$0.isAlternate }
        return ["items": visible.map { $0.isSeparatorItem ? "—" : ($0.submenu != nil ? $0.title + " ▸" : $0.title) },
                "disabled": visible.filter { !$0.isSeparatorItem && !$0.isEnabled }.map(\.title)]
      case "sidebar-menu", "sidebar-menu-state":
        // Builds the same NSMenu a right-click shows (a row, or the Space with no node)
        // and performs the item at a "/" path; `alternate` picks the ⌥ alternate title.
        // `items` (an array) addresses titles that contain "/" (Live Folder repositories).
        guard let controller = app.frontWindowController, let path = (a["items"] as? [String])?.joined(separator: "\u{1F}") ?? a["item"] as? String else { throw Failure(message: "missing sidebar menu item") }
        let node: ItemID?
        if let raw = a["node"] {
          guard let text = raw as? String, let uuid = UUID(uuidString: text), (app.hostFactories[controller.windowID]?.model ?? app.model).node(id: ItemID(rawValue: uuid)) != nil else { throw Failure(message: "invalid sidebar node") }
          node = ItemID(rawValue: uuid)
        } else { node = nil }
        let separator: Character = a["items"] != nil ? "\u{1F}" : "/"
        guard !path.isEmpty, !path.split(separator: separator, omittingEmptySubsequences: false).contains(where: { $0.isEmpty }) else { throw Failure(message: "empty sidebar menu path") }
        guard var level = a["surface"] as? String == "url-field" ? controller.sidebar.urlFieldMenu() : controller.sidebar.contextMenu(nodeID: node) else { throw Failure(message: "no sidebar menu") }
        let parts = path.split(separator: separator).map(String.init)
        for (depth, part) in parts.enumerated() {
          let matches = level.items.indices.filter { index in
            let item = level.items[index]
            return item.title == part && (item.isEnabled || cmd == "sidebar-menu-state") && (item.isAlternate == (a["alternate"] as? Bool ?? false) || depth < parts.count - 1)
          }
          guard matches.count == 1, let index = matches.first
          else { throw Failure(message: "sidebar menu has no enabled item \(part)") }
          if depth == parts.count - 1 {
            if cmd == "sidebar-menu-state" {
              let item = level.items[index]
              return ["title": item.title, "enabled": item.isEnabled, "key": item.keyEquivalent, "checked": item.state == .on]
            }
            level.performActionForItem(at: index)
          }
          else if let sub = level.items[index].submenu { level = sub } else { throw Failure(message: "\(part) has no submenu") }
        }
        await Task.yield()
        return true
      case "space-manager-drag": return try await dragSpaceManager(a)
      case "space-manager-menu": return try performSpaceManagerMenu(a)
      case "space-manager-intent":
        // The production intent a native URL drop on a Manager column sends (the drop
        // mapping itself is checked offscreen in sidebar-render).
        let (manager, _) = try realSpaceManager()
        guard a["kind"] as? String == "openURL", let raw = a["space"] as? String,
          let space = app.model.spaces.first(where: { $0.id.description == raw }),
          let text = a["url"] as? String, let url = URL(string: text) else { throw Failure(message: "invalid Manager intent") }
        let parent: NodeParent = a["section"] as? String == "pinned" ? .spacePinned(space.id) : .spaceToday(space.id)
        return manager.onIntent?(.openURL(url, in: parent, index: 0)) == true
      case "library-close":
        let target = app.settingsPresenter.libraryWindow
        var dialogs: [Int] = []
        if let sheet = target?.attachedSheet { dialogs.append(sheet.windowNumber); target?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        app.settingsPresenter.closeLibrary()
        return ["closed": app.settingsPresenter.libraryWindow == nil, "dialogs": dialogs] as [String: Any]
      case "space-manager-lifecycle": return try spaceManagerLifecycle(a)
      case "space-manager-row-controls": return try spaceManagerRowControls(a)
      case "space-manager-scroll":
        let (manager, _) = try realSpaceManager()
        guard let x = a["x"] as? Double, x.isFinite, x >= 0, x <= 100_000 else { throw Failure(message: "invalid manager scroll origin") }
        let clip = manager.scrollView.contentView
        var bounds = clip.bounds; bounds.origin.x = x
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin); manager.scrollView.reflectScrolledClipView(clip)
        return try spaceManagerLifecycle([:])
      default: break
      }
      let w: EngineWebContentHostFactory
      if let number = a["window"] as? Int,
         let owner = app.littleOpenHosts.values.first(where: { $0.view.window?.windowNumber == number })?.owner {
        w = owner
      } else { w = try window }
      switch cmd {

      case "sidebar-share":
        if let dismiss = a["dismiss"] as? Bool { w.dismissSidebarShareForAutomation = dismiss }
        if a["close"] as? Bool == true { w.sidebarSharePicker?.close() }
        if a["waitClosed"] as? Bool == true {
          // show() has now returned. A close from the service-query delegate
          // alone can run before AppKit finishes presenting its menu.
          if w.dismissSidebarShareForAutomation { w.sidebarSharePicker?.close() }
          for _ in 0..<100 where w.sidebarSharePicker != nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        var result = w.sidebarShareRequest
        result["pending"] = w.sidebarSharePicker != nil
        return result
      case "profile-menu":
        if let response = a["response"] as? String {
          guard response == "cancel" || app.model.profiles.contains(where: { $0.name == response }) else { throw Failure(message: "unknown Profile response") }
          w.profileMenuResponseForAutomation = response
        }
        if a["close"] as? Bool == true {
          w.spaceProfileMenu?.cancelTrackingWithoutAnimation()
          w.profileMenuResponseForAutomation = nil
        }
        if a["waitClosed"] as? Bool == true {
          for _ in 0..<100 where w.spaceProfileMenu != nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        var result = w.profileMenuRequest
        result["pending"] = w.spaceProfileMenu != nil
        return result

      // Model-level tabs (the sidebar).
      case "settings-custom-engine":
        let settings = app.settingsPresenter.settings
        guard let template = a["template"] as? String, let profile = w.focusedProfile else { throw Failure(message: "missing search template") }
        settings.profiles.select(profile.id)
        guard settings.profiles.saveEngine(id: "custom-e2e", name: "Local Search", keyword: "local-search", template: template) else { throw Failure(message: settings.profiles.errorText) }
        settings.profiles.searchEngineID = "custom-e2e"; return true
      case "library-restore":
        guard let library = app.settingsPresenter.library, let raw = a["id"] as? String, let uuid = UUID(uuidString: raw) else { throw Failure(message: "missing Archive row") }
        await library.restore(id: ItemID(rawValue: uuid)); return library.statusText
      case "library-history-open":
        guard let library = app.settingsPresenter.library, let url = (a["url"] as? String).flatMap(URL.init(string:)) else { throw Failure(message: "Library not open") }
        library.actions.openHistoryItem(url: url); return true
      case "save-page-state": return ["requests": w.savePageRequestCount, "visible": w.pendingSavePanel?.isVisible == true, "pending": w.pendingSavePanel != nil, "number": w.pendingSavePanel?.windowNumber ?? 0] as [String: Any]
      case "focus-state":
        let owner = (a["id"] as? String).flatMap { id in app.hostFactories.first { $0.key.description == id }?.value } ?? w
        return owner.focusStateForAutomation()
      case "background-read":
        guard let tab = w.selectedTab, let host = w.hosts[tab.id] else { throw Failure(message: "no live tab") }
        host.refreshPageBackground(); return true
      case "async-engine-state":
        return ["captures": w.saveCaptureTasks.count, "background": w.hosts.values.filter(\.hasBackgroundTask).count]
      case "save-page-choose":
        guard let panel = w.pendingSavePanel, let choice = w.pendingSaveChoice,
              let path = a["path"] as? String else { throw Failure(message: "no Save sheet") }
        // Complete the owned presenter's choice through the socket, like our
        // dialog/permission replies. The actual engine capture is unchanged.
        w.pendingSaveChoice = nil
        panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil)
        choice(URL(fileURLWithPath: path)); return true
      case "toolbar-menu", "url-field-menu":
        // The content toolbar's or the sidebar URL field's right-click menu, built as a click builds
        // it; with `item`, performs that item (the menu item's own action).
        guard let controller = w.controller else { throw Failure(message: "no window") }
        guard let menu = cmd == "toolbar-menu" ? controller.toolbarMenu() : controller.sidebar.urlFieldMenu() else { throw Failure(message: "no content toolbar") }
        guard let title = a["item"] as? String else { return menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else { throw Failure(message: "no menu item \(title)") }
        menu.performActionForItem(at: index); return true
      case "commandbar-state": return w.commandBarSession?.stateForAutomation() ?? ["created": false, "presented": false]
      case "commandbar-press":
        // AX press of one bar control (info, searchSettings, dismiss, privacyLink): the real control action.
        guard let session = w.commandBarSession, let bar = session.controller, bar.isPresented else { throw Failure(message: "command bar is not open") }
        guard let control = a["control"] as? String else { throw Failure(message: "missing control") }
        let pressed = bar.view.debugPress(control)
        return ["pressed": pressed, "state": session.stateForAutomation()]
      case "suggest-remote":
        guard let profile = w.focusedProfile else { throw Failure(message: "no profile") }
        var settings = profile.settings; settings.searchSuggestEnabled = a["enabled"] as? Bool ?? false
        return app.model.updateProfileSettings(id: profile.id, settings: settings)
      case "sidebar-duplicate":
        guard let id = (a["id"] as? String).flatMap(UUID.init(uuidString:)).map({ ItemID(rawValue: $0) }) else { throw Failure(message: "missing id") }
        return w.controller?.sidebar(w.controller!.sidebar, didRequest: .duplicate(nodeID: id)) == true
      case "space-header":
        // The focused Space's header: shown or hidden (single unnamed Space, "Show/Hide Space Header").
        guard let space = w.focusedSpace else { throw Failure(message: "no space") }
        if a["reload"] as? Bool == true { SpaceHeaderPreference.shared.reload() }
        w.controller?.contentView.layoutSubtreeIfNeeded()
        return ["visible": w.controller?.sidebar.spaceHeaderVisible ?? false, "hidesHeader": w.controller?.context.hidesHeader(for: space) ?? false,
          "showPreference": SpaceHeaderPreference.shared.showOnSingleUnnamedSpace, "spaces": app.model.spaces.count,
          "title": space.title ?? NSNull()] as [String: Any]
      case "sidebar-tree":
        guard let space = w.focusedSpace else { throw Failure(message: "no space") }
        return ["pinned": space.pinned.map(describeNode), "today": space.today.map(describeNode)]
      case "tabs":
        let tabs = w.orderedTabs.map { describe($0, in: w) }
        guard a["sidebar"] as? Bool == true, let sidebar = w.controller?.sidebar, let outline = sidebar.focusedOutline,
              let space = w.focusedSpace else { return tabs }
        w.controller?.contentView.layoutSubtreeIfNeeded()
        let rows = sidebar.displayedRows
        var folders: [[String: Any]] = []
        func collect(_ nodes: [SidebarNode]) {
          for node in nodes {
            guard let folder = node.folder else { continue }
            let visible = (0..<outline.numberOfRows).compactMap { row -> String? in
              guard let item = outline.item(atRow: row), outline.parent(forItem: item) as? Folder === folder else { return nil }
              if let tab = item as? Tab { return tab.id.description }
              if let split = item as? Split { return split.id.description }
              if let nested = item as? Folder { return nested.id.description }
              return nil
            }
            folders.append(["id": folder.id.description, "expanded": folder.isExpanded,
              "peekedChildID": folder.peekedChildID?.description ?? "", "visibleChildren": visible])
            collect(folder.children)
          }
        }
        collect(space.pinned); collect(space.today)
        return ["tabs": tabs, "rows": rows, "folders": folders, "selectedNode": w.selectedNodeID?.description ?? ""] as [String: Any]
      case "tab-state":
        return describe(try modelTab(a, w), in: w)
      case "tab-strip":
        return w.tabStripState()
      case "frame-save-counters":
        return ["captures": app.snapshotStore.captureCount, "scheduled": app.snapshotStore.scheduleCount,
          "dirty": app.snapshotStore.isDirty, "treeChanges": w.treeChangeCount, "mirrorSyncs": w.mirrorSyncCount] as [String: Any]
      case "space-profile":
        guard let raw = a["space"] as? String, let space = app.model.spaces.first(where: { $0.id.description == raw }) else { throw Failure(message: "unknown Space") }
        let name = a["profile"] as? String ?? "Default"
        guard let profile = app.model.profiles.first(where: { $0.name == name }) ?? app.model.createProfile(name: name) else { throw Failure(message: "unknown Profile") }
        try app.directories.ensureProfileDirectories(for: profile)
        return w.controller?.sidebar(w.controller!.sidebar, didRequest: .setSpaceProfile(space: space.id, profile: profile.id)) == true
      case "boost-editor", "boosts", "boost-library":
        return try await runBoostCommand(cmd, a)
      case "boost-gallery-ui": return try await boostGalleryUI(a)
      case "peek-ui", "peek-motion", "peek-motion-trace", "peek-button", "peek-move-arm", "peek-move-state":
        return try runPeekAppCommand(cmd, a)
      case "theme-data-state":
        // The theme variables the App sets for a tab (setting on), or none.
        let tab = try modelTab(a, w)
        let values = ThemeData.variables(tabID: tab.id, factory: w) ?? []
        return ["enabled": ThemeData.enabled, "variables": Dictionary(values, uniquingKeysWith: { x, _ in x })] as [String: Any]
      case "sad-tab-state", "sad-tab-action":
        return try runSadTabCommand(cmd, a)
      case "handoff-state", "handoff-continue", "deep-link-state", "mailto-state":
        return try await runHandoffCommand(cmd, a)
      case "peek-open":
        let source = try modelTab(a, w)
        guard let raw = a["url"] as? String, let url = URL(string: raw), let controller = w.controller else { throw Failure(message: "missing Peek URL") }
        controller.peekController.open(url: url, sourceTabID: source.id); return true
      case "peek-expand":
        w.controller?.peekController.expandTop(); return true
      case "peek-close":
        w.controller?.peekController.dismissAll(); return true
      case "peek-state":
        guard let controller = w.controller, controller.hasPeekController else { return ["shown": false, "stack": []] as [String: Any] }
        let peek = controller.peekController
        return ["shown": peek.isShown, "expanding": peek.isExpanding, "stack": peek.stack.map { item in
          ["source": item.sourceTabID.description, "url": item.url.absoluteString,
           "profile": item.profileID.description, "librarySpace": item.librarySpaceID?.description ?? "",
           "originalHostTab": item.hostTabID.description,
           "boundTab": item.host?.tabID.description ?? "", "content": (item.host as? EngineWebContentHost)?.content.identifier ?? 0,
           "style": (item.host as? EngineWebContentHost).map { $0.content.runtimeStyle == .chrome ? "chrome" : "alloy" } ?? ""] as [String: Any]
        }] as [String: Any]
      case "spaces":
        return app.model.spaces.map { space in
          [
            "id": space.id.description, "title": space.title ?? "", "profile": space.profileID.description, "focused": space.id == w.focusedSpace?.id,
            "pinned": space.pinned.count, "today": space.today.count, "icon": describeIcon(space.icon),
          ] as [String: Any]
        }
      case "space-create":
        // A Space with its own profile (own engine context) when `profile`
        // names a new one.
        let model = app.model!
        let name = a["profile"] as? String ?? "Default"
        guard
          let profile = model.profiles.first(where: { $0.name == name })
            ?? model.createProfile(name: name)
        else { throw Failure(message: "cannot create profile \(name)") }
        try app.directories.ensureProfileDirectories(for: profile)
        guard let space = model.createSpace(title: a["title"] as? String ?? name, profileID: profile.id,
                                           icon: nil, theme: SpaceTheme(), at: nil, moving: [])
        else { throw Failure(message: "cannot create Space for profile \(profile.id)") }
        w.focus(space: space)
        return space.id.description
      case "favorite":
        // Moves a tab to its profile's Favorites.
        let tab = try modelTab(a, w)
        guard let profile = w.focusedSpace?.profileID,
          app.model.moveNode(id: tab.id, to: .favorites(profile), at: nil)
        else { throw Failure(message: "cannot make a favorite") }
        return describe(tab, in: w)
      case "folder":
        // A folder in the focused Space's Today (or pinned) section with
        // the given tabs, in order.
        guard let space = w.focusedSpace else { throw Failure(message: "no space") }
        let ids = try (a["tabs"] as? [String] ?? []).map { try modelTab(["tab": $0], w).id }
        let section: NodeParent = a["section"] as? String == "pinned" ? .spacePinned(space.id) : .spaceToday(space.id)
        guard let folder = app.model.createFolder(in: section, title: a["title"] as? String ?? "Folder", withNodes: ids)
        else { throw Failure(message: "folder not created") }
        if let at = a["at"] as? Int { app.model.moveNode(id: folder.id, to: section, at: at) }
        return folder.id.description
      case "space":
        guard let s = a["space"] as? String, let space = app.model.spaces.first(where: { $0.id.description == s })
        else { throw Failure(message: "unknown space") }
        guard w.controller?.sidebar(w.controller!.sidebar, didRequest: .switchSpace(space.id)) == true else { throw Failure(message: "Space switch refused") }
        return true
      case "open":
        let url = try url(a, "url")
        guard let tab = w.openNewTab(url: url, background: a["background"] as? Bool ?? false) else {
          throw Failure(message: "no space")
        }
        return describe(tab, in: w)
      case "select":
        let tab = try modelTab(a, w)
        guard let space = w.focusedSpace, w.controller?.sidebar(w.controller!.sidebar, didRequest: .select(nodeID: tab.id, space: space.id)) == true else { throw Failure(message: "selection refused") }
        return describe(tab, in: w)
      case "close":
        // A page identifier closes that page (popup panel, extension popup,
        // or the tab that shows it); a tab id or nothing closes like Cmd-W.
        if let n = a["tab"] as? Int {
          guard let page = OEEngine.shared.webContent(identifier: n) else { throw Failure(message: "no page \(n)") }
          w.close(page: page)
          return true
        }
        if a["tab"] != nil || a["index"] != nil {
          let tab = try modelTab(a, w)
          guard w.controller?.sidebar(w.controller!.sidebar, didRequest: .close(nodeID: tab.id)) == true else { throw Failure(message: "close refused") }
        } else { w.closeTab(nil) }
        return true
      case "pin":
        let tab = try modelTab(a, w)
        let intent: SidebarIntent = app.model.isPinned(tabID: tab.id) ? .unpin(tabID: tab.id) : .pin(tabID: tab.id)
        guard w.controller?.sidebar(w.controller!.sidebar, didRequest: intent) == true else { throw Failure(message: "pin refused") }
        return describe(tab, in: w)
      case "split":
        if a["op"] != nil { return try await splitCommand(a, w) }
        w.addSplitView(nil)
        return w.visibleTabs.map { describe($0, in: w) }
      case "navigate":
        let destination = try url(a, "url")
        guard !WelcomeTab.isInternal(destination) else { throw Failure(message: "internal URL navigation refused") }
        if let tab = try? modelTab(a, w), let host = w.welcomeHosts[tab.id] { host.load(destination) }
        else { try content(a, w).load(destination) }
        return true
      case "back":
        try content(a, w).goBack()
        return true
      case "wait":
        return try await waitForLoad(try content(a, w), timeout: a["timeout"] as? Double ?? 20)

      // Engine tab-sleep primitives (memory-fork, OEWebContent "Sleep"): test
      // hooks for the e2e tabstrip suite. The shell's sleep policy (Step G)
      // calls the same API; nothing here changes sleep phases in the model.
      case "engine-sleep":
        let page = try content(a, w)
        var r: [String: Any] = [:]
        switch a["op"] as? String ?? "state" {
        case "state": break
        case "hide": page.setPageHidden(true)
        case "show": page.setPageHidden(false)
        case "freeze": r["ok"] = page.setPageFrozen(true)
        case "unfreeze": r["ok"] = page.setPageFrozen(false)
        case "discard": r["ok"] = await page.discard()
        case "capture":
          guard let h = page.captureNavigationHistory() else { r["history"] = NSNull(); break }
          r["history"] = ["entryCount": h.entryCount, "currentIndex": h.currentIndex, "hasPageState": h.hasPageState,
            "bytes": h.container.count, "title": h.title, "currentURL": h.currentURL?.absoluteString ?? "",
            "faviconURL": h.faviconURL?.absoluteString ?? "",
            "roundTrip": OENavigationHistory(container: h.container)?.container == h.container] as [String: Any]
        default: throw Failure(message: "unknown engine-sleep op")
        }
        r["frozen"] = page.isPageFrozen; r["discarded"] = page.isDiscarded
        r["unloadHandlers"] = page.hasUnloadHandlers; r["chromeTabId"] = page.chromeTabIdentifier
        r["identifier"] = page.identifier; r["live"] = page.isLive
        return r

      // Pages (any live web content).
      case "pages":
        return OEEngine.shared.allWebContents.filter { content in
          a["private"] as? Bool == true || !app.hostFactories.values.contains {
            $0.isIncognito && $0.incognitoSession?.context === content.context
          }
        }.map { describe($0, in: w) }
      case "site-settings", "site-setting", "site-data-clear", "security-state":
        return try await runSiteDataCommand(cmd, a, page: try content(a, w))
      case "page-site-data-probe":
        return try runPageSiteDataProbe(a) { try content(a, w) }
      case "eval":
        guard let js = a["js"] as? String else { throw Failure(message: "missing js") }
        // Through the OpenWeb protocol, as OpenKit features will call it.
        let page: any WebContent = try content(a, w)
        return try await page.evaluateJavaScript(js, in: try scriptWorld(a))
      case "devtools":
        guard let method = a["method"] as? String else { throw Failure(message: "missing method") }
        return try await content(a, w).sendDevToolsMethod(method, parameters: a["params"] as? [String: Any])
      case "click":
        return try await click(try content(a, w), selector: a["selector"] as? String, text: a["text"] as? String)
      case "rightclick":
        let page = try content(a, w)
        let x = a["x"] as? Double ?? 100, y = a["y"] as? Double ?? 100
        for type in ["mousePressed", "mouseReleased"] {
          _ = try await page.sendDevToolsMethod(
            "Input.dispatchMouseEvent", parameters: ["type": type, "x": x, "y": y, "button": "right", "clickCount": 1])
        }
        return true
      case "type":
        if w.controller?.spaceCreationController != nil { return try await sendKey(["text": a["text"] as? String ?? ""], w) }
        _ = try await content(a, w).sendDevToolsMethod(
          "Input.insertText", parameters: ["text": a["text"] as? String ?? ""])
        return true
      case "focus":
        let page = try content(a, w)
        if let target = page.view.window { try await activateForInput(target) }
        page.focusPage()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
          let responder = page.view.window?.firstResponder as? NSView
          let nativeFocus = responder.map { $0 === page.view || $0.isDescendant(of: page.view) } == true
          if nativeFocus, try await page.evaluateJavaScript("document.hasFocus()") as? Bool == true { return true }
          try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "page focus not ready")
      case "mouse":
        return try await mouse(a, w)
      case "key":
        return try await sendKey(a, w)
      case "find-state":
        var state = w.findController?.automationState() ?? ["panes": [], "created": false, "pending": false]
        state["display"] = FindIdleProbe.displayInfo(window: w.window)
        state["warmup"] = FindBarPrewarm.snapshot
        return state
      case "find-idle":
        return try FindIdleProbe.perform(a["action"] as? String ?? "read", factory: w)
      case "find":
        let page = try content(a, w)
        page.find(a["text"] as? String ?? "", forward: true, caseSensitive: false)
        try await Task.sleep(for: .milliseconds(500))
        let r = w.lastFindResult
        return ["matches": r?.matchCount ?? 0, "active": r?.activeMatchIndex ?? 0, "final": r?.isFinal ?? false]
      case "zoom":
        let page = try content(a, w)
        if let level = a["level"] as? Double { page.zoomLevel = level }
        return page.zoomLevel
      case "mute":
        let page = try content(a, w)
        page.isMuted = a["muted"] as? Bool ?? true
        return ["muted": page.isMuted, "audible": page.isAudible]
      case "devtools-open":
        try content(a, w).showDevTools()
        return true
      // Page tools (page-platform Steps 4-6, Section 8 helper B).
      case "devtools-frontend":
        // Evaluates `js` in the open DevTools window of a page (its front end).
        guard let js = a["js"] as? String else { throw Failure(message: "missing js") }
        let page = try content(a, w)
        let value: Any? = try await page.evaluateInDevToolsFrontend(js)
        return value ?? NSNull()
      case "devtools-close":
        try content(a, w).closeDevTools()
        return true
      case "user-style-sheet":
        // OEWebContent.setUserStyleSheet(_:forKey:) on one page (PB1 theme data).
        guard let key = a["key"] as? String else { throw Failure(message: "missing key") }
        try content(a, w).setUserStyleSheet(a["css"] as? String, forKey: key)
        return true
      case "devtools-dock":
        // Test host for docked DevTools (IMC owns the real placement): puts the
        // page's DevTools view over the right part of the page and reports frames.
        let page = try content(a, w)
        let panels: [String: OEDevToolsPanel] = ["default": .default, "elements": .elements,
          "console": .console, "network": .network, "inspect": .inspectMode]
        if let name = a["panel"] as? String {
          guard let panel = panels[name], let dock = page.devToolsView(panel: panel) else {
            throw Failure(message: "no docked DevTools for this page")
          }
          let host = page.view
          if let parent = host.superview, dock.superview !== parent { parent.addSubview(dock, positioned: .above, relativeTo: host) }
          let width = (a["width"] as? Double).map { CGFloat($0) } ?? 360
          dock.frame = NSRect(x: host.frame.maxX - width, y: host.frame.minY, width: width, height: host.frame.height)
        }
        if a["remove"] as? Bool == true {
          // Removing a test host must not open a fresh DevTools frontend.
          for dock in page.view.superview?.subviews.filter({ $0.className.contains("DevToolsDock") }) ?? [] {
            dock.removeFromSuperview()
          }
        }
        let window = page.view.window
        let dock = page.hasDevTools ? page.view.superview?.subviews.first { $0.className.contains("DevToolsDock") } : nil
        let dockScreen = dock.flatMap { d in d.window.map { $0.convertToScreen(d.convert(d.bounds, to: nil)) } }
        let children = (window?.childWindows ?? []).filter { $0.isVisible }.map { NSStringFromRect($0.frame) }
        return ["hasDevTools": page.hasDevTools, "dockScreenFrame": dockScreen.map { NSStringFromRect($0) } ?? "",
          "childWindows": children,
          "appWindows": NSApp.windows.filter { $0.isVisible && $0.parent == nil }.count,
          "topLevel": NSApp.windows.filter { $0.isVisible && $0.parent == nil }.map {
            ["class": $0.className, "title": $0.title, "frame": NSStringFromRect($0.frame),
             "borderless": $0.styleMask.rawValue == 0] as [String: Any] }] as [String: Any]
      case "troubleshooting-state":
        let t = TroubleshootingActions.shared
        return ["tracing": OEEngine.shared.isTracing, "recording": t.isRecording,
          "lastTraceFile": t.lastTraceFile?.path ?? "", "lastTraceError": t.lastTraceError ?? "",
          "taskManagerShown": t.taskManagerShown.map { $0 ? "yes" : "no" } ?? "",
          "reveals": revealedURLs.map(\.path),
          "colorScheme": UserDefaults.standard.string(forKey: WebsiteAppearance.defaultsKey) ?? "",
          "contextSchemes": OEEngine.shared.contexts.map { $0.websiteColorScheme.rawValue },
          "allowJavaScriptFromAppleEvents": UserDefaults.standard.bool(forKey: PageTools.allowJavaScriptFromAppleEventsKey)] as [String: Any]
      case "troubleshooting-setup":
        // A run folder for traces, and Finder reveals recorded instead of shown.
        let t = TroubleshootingActions.shared
        if let path = a["traceDir"] as? String { t.traceDirectory = URL(fileURLWithPath: path, isDirectory: true) }
        if a["recordReveals"] as? Bool == true { t.reveal = { [weak self] in self?.revealedURLs.append($0) } }
        return true
      case "print-pdf":
        let path = (a["path"] as? String) ?? NSTemporaryDirectory() + "open-print.pdf"
        let page = try content(a, w)
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
          page.printToPDF(at: URL(fileURLWithPath: path)) { c.resume(returning: $0) }
        }
        return ["ok": ok, "path": path]
      case "fullscreen-exit":
        try content(a, w).exitFullscreen()
        return true

      // Extensions.
      case "extensions":
        guard let browser = w.focusedBrowser(create: a["create"] as? Bool ?? false) else {
          return ["loaded": false, "ready": false, "duplicatesDropped": 0, "installed": [], "actions": []] as [String: Any]
        }
        if a["refresh"] as? Bool == true { browser.context.extensions.reload() }
        return [
          "loaded": true, "ready": browser.context.extensions.isReady,
          "duplicatesDropped": w.extensions.host?.duplicatesDropped ?? 0,
          "installed": browser.context.extensions.installedExtensions.map(describe),
          "actions": browser.extensionActions.map { action in
            var value = describe(action)
            value["icon"] = (value["icon"] as? [String: Any])?["bytes"] ?? 0
            value["popup"] = action.hasPopup
            return value
          },
        ]
      case "popup":
        guard let id = a["extension"] as? String else { throw Failure(message: "missing extension") }
        let browser = try focusedBrowser(w, create: a["create"] as? Bool ?? false)
        guard EngineExtensionHost(browser).executeAction(extensionID: id), let popup = browser.extensionPopup else {
          throw Failure(message: "action did not open a popup")
        }
        // The popup's browser is created once its view is in the panel.
        for _ in 0..<50 where !popup.isLive {
          try await Task.sleep(for: .milliseconds(100))
        }
        return describe(popup, in: w)
      case "popup-close":
        try focusedBrowser(w, create: a["create"] as? Bool ?? false).closeExtensionPopup()
        return true

      // Toolbar actions from Chrome's model (fork patch P2).
      case "actions":
        guard let browser = w.focusedBrowser(create: a["create"] as? Bool ?? false) else {
          return ["loaded": false, "ready": false, "actions": []] as [String: Any]
        }
        return ["ready": browser.extensionActionsReady, "actions": browser.extensionActions.map(describe)] as [String: Any]
      case "ext-pin":
        guard let id = a["extension"] as? String else { throw Failure(message: "missing extension") }
        let browser = try focusedBrowser(w, create: a["create"] as? Bool ?? false)
        browser.setExtensionAction(id, pinned: a["pinned"] as? Bool ?? true)
        if let index = a["index"] as? Int {
          guard index >= 0, index < 512 else { throw Failure(message: "invalid pinned index") }
          // Read the post-pin list before using the same guarded move as a drag.
          w.extensions.host?.reload()
          w.extensions.host?.movePinned(extensionID: id, to: index)
        }
        return true
      case "ext-move":
        guard let id = a["extension"] as? String, let index = a["index"] as? Int else { throw Failure(message: "missing extension or index") }
        guard index >= 0 else { throw Failure(message: "index must be nonnegative") }
        if a["engine"] as? Bool == true {
          // C5's boundary checks deliberately exercise engine refusal before
          // the App clamps a native drag's destination.
          try focusedBrowser(w, create: a["create"] as? Bool ?? false).moveExtensionAction(id, toPinnedIndex: UInt(index))
        } else { w.extensions.host?.movePinned(extensionID: id, to: index) }
        return true
      case "ext-run":
        guard let id = a["extension"] as? String else { throw Failure(message: "missing extension") }
        try focusActionPane(a, w)
        let source: OEBrowser.ExtensionActionSource =
          switch a["source"] as? String { case "menu": .menuEntry; case "command": .command; default: .toolbarButton }
        return try focusedBrowser(w, create: a["create"] as? Bool ?? false).executeExtensionAction(id, source: source)
      case "ext-menu":
        // The action's context menu: its items, or select one by title.
        guard let id = a["extension"] as? String else { throw Failure(message: "missing extension") }
        try focusActionPane(a, w)
        if a["keep"] as? Bool != true, a["stale"] as? Bool != true, a["snapshot"] as? Bool != true {
          return try await runExtensionUICommand("ext-ui-menu", a, w)
        }
        let browser = try focusedBrowser(w, create: a["create"] as? Bool ?? false)
        guard let menu = browser.contextMenu(forExtensionAction: id, source: a["source"] as? String == "menu" ? .menuItem : .toolbarAction)
        else { throw Failure(message: "no menu") }
        func items(_ list: [OEContextMenuItem]) -> [[String: Any]] {
          list.map { ["title": ExtensionsMenuBuilder.relabel($0.title), "command": $0.commandIdentifier, "enabled": $0.isEnabled, "checked": $0.isChecked,
                      "separator": $0.isSeparator, "submenu": items($0.submenu)] as [String: Any] }
        }
        let listed = items(menu.items)
        if let title = a["select"] as? String {
          func find(_ list: [OEContextMenuItem]) -> OEContextMenuItem? {
            for item in list { if item.title == title || ExtensionsMenuBuilder.relabel(item.title) == title { return item }; if let hit = find(item.submenu) { return hit } }
            return nil
          }
          guard let item = find(menu.items) else { menu.cancel(); throw Failure(message: "no menu item \(title)") }
          // `stale`: run the item on the menu kept earlier (`keep`), built
          // before this one; this one is cancelled.
          if a["stale"] as? Bool == true, let older = staleMenu {
            staleMenu = nil
            // Keep the newer model alive while selecting the older one. This
            // also exposes any id collision across hidden-Browser generations.
            let ran = older.select(command: item.commandIdentifier)
            menu.cancel()
            return ["items": listed, "ran": ran] as [String: Any]
          }
          return ["items": listed, "ran": menu.select(command: item.commandIdentifier)] as [String: Any]
        } else if a["keep"] as? Bool == true {
          // Kept open (not cancelled) for a later `stale` select.
          staleMenu = menu
        } else {
          menu.cancel()
        }
        if a["snapshot"] as? Bool == true {
          return ["items": listed, "action": browser.extensionActions.first(where: { $0.extensionIdentifier == id }).map(describe) ?? [:]] as [String: Any]
        }
        return listed
      case "ext-popup":
        guard let browser = w.focusedBrowser(create: a["create"] as? Bool ?? false), let popup = browser.extensionPopup else { return ["open": false] as [String: Any] }
        return ["open": true, "page": describe(popup, in: w), "extension": browser.extensionPopupExtensionIdentifier ?? "",
                "source": ["user", "command", "api"][browser.extensionPopupSource.rawValue],
                "staysOpenOnBlur": browser.extensionPopupStaysOpenOnBlur] as [String: Any]
      case "popup-callback-close":
        if a["phase"] as? String == "clear" { w.popupCallbackClose = nil; return true }
        guard let phase = a["phase"] as? String, ["open", "resize", "ready"].contains(phase) else {
          throw Failure(message: "expected popup callback phase: open, resize, ready")
        }
        w.popupCallbackClose = (phase, a["toggle"] as? Bool ?? false)
        return true
      case "activate":
        // Makes Open's window key (Chrome's "active window"), even with an
        // action popup's panel in front.
        NSApp.activate()
        w.window?.makeKeyAndOrderFront(nil)
        return ["key": w.window?.isKeyWindow ?? false]

      // Windows and pixels (Open's own windows only).
      case "windows":
        let enhanced = a["accessibility"] as? Bool == true
        let axRead = NSSelectorFromString("accessibilityAttributeValue:"), axWrite = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previousAX = enhanced && NSApp.responds(to: axRead) ? NSApp.perform(axRead, with: "AXEnhancedUserInterface")?.takeUnretainedValue() : nil
        if enhanced, NSApp.responds(to: axWrite) { NSApp.perform(axWrite, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }
        defer { if enhanced, NSApp.responds(to: axWrite) { NSApp.perform(axWrite, with: previousAX ?? NSNumber(value: false), with: "AXEnhancedUserInterface") } }
        if enhanced {
          for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded() }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return NSApp.windows.filter { $0.identifier?.rawValue != "onboarding-dim" }.map { nativeWindow in
          var row = describe(nativeWindow)
          if a["accessibility"] as? Bool == true { row["text"] = windowText(nativeWindow) }
          if a["accessibilityRoles"] as? Bool == true { row["roles"] = windowAccessibilityRoles(nativeWindow) }
          return row
        }
      case "panel-close":
        // The close button of the panel that shows page `page` (performClose).
        guard let n = a["page"] as? Int, let aux = w.auxiliaryPages.first(where: { $0.content.identifier == n })
        else { throw Failure(message: "no panel for page") }
        aux.panel.performClose(nil)
        return true
      case "dismiss":
        // Ends what a Chromium command opened: modal panels (Print), sheets
        // (Save As), and windows that are not Open's (DevTools, Chrome
        // windows). Open's browser windows and panels stay.
        var dismissed: [String] = []
        staleMenu?.cancel(); staleMenu = nil
        for owner in app.hostFactories.values {
          while owner.completePendingDialog(accept: false, text: nil) { dismissed.append("javascript") }
        }
        if let modal = NSApp.modalWindow {
          dismissed.append("modal:" + String(describing: type(of: modal)))
          NSApp.abortModal()
        }
        let ours = Set(app.windowControllers.compactMap { $0.window.map(ObjectIdentifier.init) })
        for win in NSApp.windows {
          if let sheet = win.attachedSheet {
            dismissed.append("sheet:" + String(describing: type(of: sheet)))
            win.endSheet(sheet, returnCode: .cancel)
          }
          // Chromium's own windows (DevTools, Chrome windows, Picture in
          // Picture) are Views windows.
          // A Chrome-style page is a NativeWidget child of our browser
          // window. Closing it closes the hosted tab and can close the last
          // shell window. Only standalone Chromium windows are disposable.
          var ancestor: NSWindow? = win
          var belongsToBrowser = false
          while let current = ancestor {
            if ours.contains(ObjectIdentifier(current)) { belongsToBrowser = true; break }
            ancestor = current.parent
          }
          let foreign = !belongsToBrowser && !(win is NSPanel) && win.isVisible
            && win.className.contains("NativeWidget")
          if foreign {
            dismissed.append("window:" + win.className)
            win.performClose(nil)
            if win.isVisible { win.close() }
          }
        }
        return dismissed
      case "window-motion":
        guard let controller = w.controller else { throw Failure(message: "no window") }
        if let reduced = a["reduced"] as? Bool { Motion.reduceMotionOverride = reduced }
        if let delay = a["sidebarDelay"] as? Double { Motion.sidebarDelayOverride = min(0.5, max(0, delay)) }
        if let sample = a["sampleCard"] as? Bool { controller.samplesCardMotion = sample }
        func token(_ s: SpringToken) -> [String: Any] { ["response": s.response, "damping": s.dampingFraction] }
        let travel = controller.context.sidebarWidth + WindowMetrics.revealCardInset - PanelMetrics.inset
        return ["reduced": Motion.reducesMotion,
          "tokens": ["sidebarToggle": token(Motion.sidebarToggle), "revealCardIn": token(Motion.revealCardIn),
            "sidebarShowDuration": Motion.sidebarShowDuration,
            "revealCardOut": Motion.revealCardOut, "spaceSwitch": token(Motion.spaceSwitch)] as [String: Any],
          "cardCurve": [0.112, 0.140, 0.210].map { ["time": $0, "pastRest": (Motion.springProgress(Motion.revealCardIn, at: $0) - 1) * travel] },
          "toggleRemainderAt130ms": (1 - Motion.springProgress(Motion.sidebarToggle, at: 0.130)) * (WindowMetrics.defaultSidebarWidth - PanelMetrics.inset),
          "spaceRemainderAt300ms": (1 - Motion.springProgress(Motion.spaceSwitch, at: 0.300)) * controller.context.sidebarWidth,
          "sidebar": controller.sidebarAnimations.mapValues(describeAnimation),
          "card": controller.cardAnimations.mapValues(describeAnimation),
          "cardSamples": controller.cardMotionSamples.map { ["time": $0.time, "offset": $0.offset] },
          "space": controller.sidebar.spaceSlideAnimation.map(describeAnimation) ?? [:],
          "spacePage": ["phase": controller.container.spacePageMotionPhase,
            "cachedDestination": controller.container.spacePageUsesSnapshot,
            "cacheBytes": controller.container.spacePageSnapshotBytes,
            "captures": controller.container.spacePageCaptureCount,
            "presentationUnavailable": controller.container.spacePagePresentationUnavailable,
            "animation": controller.container.spacePageAnimation.map(describeAnimation) ?? [:]] as [String: Any],
          "active": ["sidebar": controller.sidebar.layer?.animationKeys() ?? [],
            "panel": controller.container.layer?.animationKeys() ?? []]] as [String: Any]
      case "window-state":
        // `id` reads another standard window without making it key.
        let w = (a["id"] as? String).flatMap { id in app.windowControllers.first { $0.windowID.description == id } }
          .flatMap { app.hostFactories[$0.windowID] } ?? w
        guard let controller = w.controller, let win = w.window else { throw Failure(message: "no window") }
        // Read what the next frame shows: the window's own layout pass, the one its display
        // runs (the traffic lights are placed at its end).
        let passes = controller.layoutPasses
        win.layoutIfNeeded()
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind -> [Double]? in
          guard let button = win.standardWindowButton(kind) else { return nil }
          let center = controller.contentView.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
          return [center.x, center.y]
        }
        let panel = controller.container.frame
        let reveal = controller.revealState
        let chrome = controller.sidebar.chromeGeometry
        let root = controller.contentView, sidebar = controller.sidebar
        func inRoot(_ r: CGRect?) -> Any { r.map { rect(root.convert($0, from: sidebar)) } ?? NSNull() }
        let titlebar = win.standardWindowButton(.closeButton)?.superview.map { rect(root.convert($0.bounds, from: $0)) } ?? []
        return ["id": w.windowState.id.description, "number": win.windowNumber,
          "appActive": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? 0,
          "isKeyWindow": win.isKeyWindow, "visible": win.isVisible,
          "windowAppearance": win.effectiveAppearance.name.rawValue,
          "windowMaterial": ["behindWindow": controller.background.drawsWindowBackdrop,
            "active": controller.background.isWindowBackdropActive,
            "material": controller.background.windowBackdropMaterial.map { $0 as Any } ?? NSNull(),
            "fieldRebuilds": controller.background.fieldRebuildCount,
            "pendingDisplayUpdate": controller.background.hasPendingDisplayUpdate] as [String: Any],
          "contentAppearance": root.effectiveAppearance.name.rawValue,
          "systemAppearance": controller.context.systemAppearance.rawValue,
          "keySameObject": NSApp.keyWindow === win, "onActiveSpace": win.isOnActiveSpace,
          "canBecomeKey": win.canBecomeKey, "windowClass": String(reflecting: type(of: win)),
          "attachedSheet": win.attachedSheet?.windowNumber ?? 0,
          "childWindows": win.childWindows?.map(\.windowNumber) ?? [],
          "firstResponder": win.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
          "activationPolicy": NSApp.activationPolicy().rawValue,
          "screenFrame": win.screen.map { rect($0.frame) } ?? [],
          "mainScreenVisibleFrame": NSScreen.main.map { rect($0.visibleFrame) } ?? [],
          "mainScreenName": NSScreen.main?.localizedName ?? "", "mainScreenScale": NSScreen.main?.backingScaleFactor ?? 0,
          "frame": [win.frame.minX, win.frame.minY, win.frame.width, win.frame.height],
          "sidebarWidth": w.windowState.sidebarWidth, "sidebarMode": w.windowState.sidebarMode.rawValue,
          // The optional content toolbar (commandbar-completion §4.6).
          "toolbar": contentToolbarState(controller), "urlFieldVisible": controller.sidebar.urlFieldVisible,
          "menuTitles": ["toggle-toolbar": controller.menuTitle(for: "toggle-toolbar") ?? "", "toggle-sidebar": controller.menuTitle(for: "toggle-sidebar") ?? ""],
          "sidebarFrame": rect(controller.sidebar.frame), "sidebarLiveWidth": controller.context.sidebarWidth,
          "toolbarFrames": controller.sidebar.toolbarGeometry.mapValues(rect),
          "toolbarButtons": controller.sidebar.toolbarVisibleButtons,
          "spaceSwitcherFrames": app.model.spaces.reduce(into: [String: [Double]]()) { frames, space in
            if let view = controller.sidebar.spaceSwitcher(spaceID: space.id) {
              frames[space.id.description] = rect(root.convert(view.bounds, from: view))
            }
          },
          "hint": ["shows": controller.hintShows, "visible": controller.hintToast != nil,
            "frame": controller.hintToast.map { rect($0.frame) } ?? [], "keys": controller.hintToast?.keys ?? "",
            "plate": controller.hintToast.map { rect($0.plateFrame) } ?? []] as [String: Any],
          "toast": controller.lastToastTitle,
          "confirmation": controller.pendingConfirmation.map { ["title": $0.messageText, "text": $0.informativeText,
            "buttons": $0.buttons.map(\.title)] as [String: Any] } ?? NSNull(),
          "sidebarResizeActive": controller.sidebarResizeActive,
          "sidebarResizeHandleDragging": controller.sidebarResizeHandleDragging,
          "sidebarResizeHandleVisible": controller.sidebarResizeHandleVisible,
          "sidebarResizeHasStart": controller.sidebarResizeHasStart,
          "sidebarWidthOverride": controller.context.sidebarWidthOverride.map { $0 as Any } ?? NSNull(),
          "sidebarWidthCommits": controller.sidebarWidthCommits, "sidebarGestureHides": controller.sidebarGestureHides,
          "sidebarGeometryChanges": controller.sidebarGeometryChanges,
          "sidebarVisible": !controller.sidebar.isHidden, "revealed": controller.isSidebarRevealed,
          "sidebarClass": String(reflecting: type(of: controller.sidebar)),
          "panel": [panel.minX, panel.minY, panel.width, panel.height],
          "trafficLights": lights, "layoutPasses": passes,
          // The hardware pointer in window coordinates (top-left origin), read only, so a
          // check can keep its window away from where someone's pointer rests.
          "cursor": { let p = win.mouseLocationOutsideOfEventStream; return [Double(p.x), Double(win.frame.height - p.y)] }(),
          "trafficLightFrames": controller.trafficLightFrames.map { rect($0.frame) },
          "trafficLightsDimmed": controller.trafficLightsDimmed, "trafficLightsHovered": controller.trafficLightsHoveredState,
          "trafficLightButtons": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind -> [String: Any]? in
            guard let button = win.standardWindowButton(kind) else { return nil }
            // In process, the buttons' own AX role reads AXUnknown; outside clients see the
            // window's attributes below, so only those carry roles here.
            return ["alpha": Double(button.alphaValue), "hidden": button.isHiddenOrHasHiddenAncestor,
              "action": button.action.map { NSStringFromSelector($0) } ?? ""] as [String: Any]
          },
          // The window's AX button attributes, as an outside AX client reads them (F0001's dump).
          // Role and subrole only: their AXFrame does not resolve in process.
          "axWindowButtons": ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].compactMap { name -> [String: Any]? in
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            guard win.responds(to: selector), let element = win.perform(selector, with: name)?.takeUnretainedValue() as? NSObject else { return nil }
            return ["attribute": name, "role": legacyAX(element, "AXRole"), "subrole": legacyAX(element, "AXSubrole")]
          },
          "automationPointer": BrowserWindowController.automationPointer.map { p -> Any in
            p.window == win.windowNumber ? [Double(p.location.x), Double(win.frame.height - p.location.y)] : NSNull() } ?? NSNull(),
          "key": win.isKeyWindow, "miniaturized": win.isMiniaturized, "zoomed": win.isZoomed,
          "urlFieldText": controller.sidebar.urlFieldText,
          "trafficLightsHidden": controller.trafficLightFrames.map(\.hidden), "titlebar": titlebar,
          "reveal": ["phase": reveal.phase, "shows": reveal.shows, "hides": reveal.hides, "pointerEvents": reveal.pointerEvents,
            "dwell": reveal.dwell, "zone": reveal.zone, "offset": reveal.offset.isFinite ? Double(reveal.offset) : NSNull(),
            "card": rect(reveal.card), "pageBlur": controller.cardDrawsPageBlur] as [String: Any],
          "chrome": ["urlField": inRoot(chrome.urlField), "urlFieldHovered": chrome.urlFieldHovered, "favorites": inRoot(chrome.favorites),
            "header": inRoot(chrome.header), "headerTitle": inRoot(chrome.headerTitle),
            "headerTitleBaseline": chrome.headerTitleBaseline.map { Double(root.convert(CGPoint(x: 0, y: $0), from: sidebar).y) } ?? NSNull(),
            "headerHovered": chrome.headerHovered] as [String: Any],
          "titled": win.styleMask.contains(.titled), "hiddenTitle": win.titleVisibility == .hidden,
          "fullscreen": win.styleMask.contains(.fullScreen), "peekCreated": controller.hasPeekController,
          "fullscreenTransition": controller.isChangingFullScreen, "fullscreenChanges": controller.fullScreenTransitionCount,
          "pageFullscreen": controller.isPageFullscreen,
          "selected": w.selectedTab?.id.description ?? "", "space": w.windowState.focusedSpaceID.description,
          "engineURL": w.selectedContent?.url?.absoluteString ?? "",
          "engineSelected": w.selectedContent?.browser?.activeWebContent?.identifier ?? 0,
          "paneBackgrounds": controller.container.slots.map { ["tab": $0.tabID.description,
            "color": colorComponents($0.paneChrome?.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })] as [String: Any] },
          "shownPages": w.contents.filter { $0.value.view.window === win && !$0.value.view.isHiddenOrHasHiddenAncestor }.keys.map(\.description)] as [String: Any]
      case "appearance":
        // Open's own appearance only (light, dark, or nil for the system's); the
        // system setting is untouched.
        switch a["name"] as? String {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        return NSApp.effectiveAppearance.name.rawValue
      case "undo-state":
        if a["clear"] as? Bool == true { app.undoManager.removeAllActions() }
        return ["generation": app.model.undoGeneration, "canUndo": app.undoManager.canUndo,
          "canRedo": app.undoManager.canRedo] as [String: Any]
      case "window-interrupt":
        guard let win = w.window else { throw Failure(message: "no window") }
        switch a["kind"] as? String {
        case "key": win.orderOut(nil)
        case "sheet":
          // Native sheet lifecycle, with no tracking loop or external input.
          let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
          sheet.isReleasedWhenClosed = false
          if let name = a["appearance"] as? String, ["light", "dark"].contains(name) {
            sheet.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
          }
          if a["critical"] as? Bool == true { win.beginCriticalSheet(sheet, completionHandler: { _ in }) }
          else { win.beginSheet(sheet, completionHandler: { _ in }) }
        case "end-sheet":
          if let sheet = win.attachedSheet { win.endSheet(sheet); sheet.orderOut(nil) }
        default: throw Failure(message: "expected key, sheet, or end-sheet")
        }
        return true
      case "window-focus":
        guard let id = a["id"] as? String, let controller = app.windowControllers.first(where: { $0.windowID.description == id }) else { throw Failure(message: "unknown window") }
        let readinessTimeout = a["readinessTimeout"] as? Double ?? 5
        guard readinessTimeout.isFinite, (0...5).contains(readinessTimeout) else {
          throw Failure(message: "readinessTimeout must be between 0 and 5 seconds")
        }
        app.focusWindow(controller.windowID, activate: a["activate"] as? Bool == true)
        if a["activate"] as? Bool == true, let target = controller.window { try await activateForInput(target, timeout: readinessTimeout) }
        return true
      case "window-close":
        let released = a["releaseBrowsers"] as? Bool == true ? w.releaseBrowsersForAutomation() : [:]
        w.window?.performClose(nil)
        return released.isEmpty ? true : released as Any
      case "window-fullscreen":
        guard a["observeReadiness"] as? Bool == true else {
          w.window?.toggleFullScreen(nil); return true
        }
        guard let target = w.window else { throw Failure(message: "no window") }
        target.toggleFullScreen(nil)
        // No suspension or second RPC between the native toggle, transition
        // flag and zero-wait readiness predicate. The caller may resume after
        // the transition ends; this immutable sample still describes this turn.
        let readiness = inputReadiness(target)
        if !readiness.fullscreenTransition {
          return ["status": "SKIP", "reason": "AppKit did not report an in-progress full-screen transition after the toggle",
            "ready": readiness.ready, "state": readiness.state] as [String: Any]
        }
        return ["status": "observed", "ready": readiness.ready, "state": readiness.state] as [String: Any]
      case "window-deminiaturize":
        // What a click on the window's Dock tile does.
        w.window?.deminiaturize(nil); return true
      case "sidebar-move":
        let tab = try modelTab(a, w)
        let parent: NodeParent
        if let folder = a["folder"] as? String, let uuid = UUID(uuidString: folder) { parent = .folder(ItemID(rawValue: uuid)) }
        else if a["section"] as? String == "pinned", let space = w.focusedSpace { parent = .spacePinned(space.id) }
        else if let space = w.focusedSpace { parent = .spaceToday(space.id) }
        else { throw Failure(message: "no Space") }
        return w.controller?.sidebar(w.controller!.sidebar, didRequest: .move(nodeID: tab.id, to: parent, index: a["index"] as? Int)) == true
      case "folder-create":
        guard let space = w.focusedSpace, let folder = app.model.createFolder(in: .spacePinned(space.id), title: a["title"] as? String ?? "Folder") else { throw Failure(message: "cannot create folder") }
        return folder.id.description
      case "folder-toggle":
        guard let raw = a["folder"] as? String, let uuid = UUID(uuidString: raw), let folder = app.model.node(id: ItemID(rawValue: uuid))?.folder else { throw Failure(message: "unknown folder") }
        let accepted = w.controller?.sidebar(w.controller!.sidebar, didRequest: .setExpanded(folderID: folder.id, expanded: !folder.isExpanded)) == true
        return ["accepted": accepted, "expanded": folder.isExpanded]
      case "sidebar-clear":
        guard let space = w.focusedSpace else { throw Failure(message: "no Space") }
        return w.controller?.sidebar(w.controller!.sidebar, didRequest: .clearToday(space: space.id)) == true
      case "archive":
        let records = await app.archiveSink.store(for: w.focusedProfile?.id).recent(limit: 100)
        return records.map { ["id": $0.id.description, "title": $0.title] }
      case "window-frame":
        guard let win = w.window else { throw Failure(message: "no window") }
        if let f = a["frame"] as? [Double], f.count == 4 {
          // `unconstrained`: keep the exact frame even past the screen (capture-size
          // comparisons on a smaller display); AppKit otherwise fits it to the screen.
          BrowserWindowController.constrainsFramesToScreen = a["unconstrained"] as? Bool != true
          win.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: true)
        }
        return NSStringFromRect(win.frame)
      case "snapshot":
        return try await snapshot(a, w)

      // Dialogs, permissions, scripts, filters, downloads.
      case "policy":
        if let value = a["savePrompt"] {
          guard let policy = value as? String, ["record", "save", "never", "dismiss", "hold"].contains(policy) else {
            throw Failure(message: "invalid savePrompt policy")
          }
          savePromptPolicy = policy
          if let sheet = w.savePrompts?.active { savePromptDidPresent(sheet) }
        }
        if let v = a["contextMenu"] { w.contextMenuPolicy = v as? String }
        if let v = a["fullscreen"] { w.fullscreenPolicy = v as? String }
        if let v = a["dialogs"] { w.dialogPolicy = v as? String }
        if let v = a["permissions"] { w.permissionPolicy = v as? String }
        if let v = a["prompt"] { w.promptText = v as? String }
        return true
      case "dialog":
        return w.completePendingDialog(accept: a["accept"] as? Bool ?? true, text: a["text"] as? String)
      case "dialog-state": return w.pageChrome.dialogs.state
      case "dialog-button":
        return w.pageChrome.dialogs.press(accepted: a["accept"] as? Bool ?? true, text: a["text"] as? String, suppress: a["suppress"] as? Bool ?? false)
      case "permission-prompt":
        if let answer = a["answer"] as? String { return w.pageChrome.permissions.press(answer) }
        return w.pageChrome.permissions.state
      case "permission-decisions":
        guard let browser = w.focusedBrowser(create: a["create"] as? Bool ?? false) else {
          return ["ready": false, "decisions": []] as [String: Any]
        }
        let store = SitePermissionStore.forContext(browser.context)
        return ["ready": store.indexReady, "decisions": store.allDecisions().map { ["origin": $0.origin.absoluteString, "kind": $0.kind.rawValue, "state": $0.state.rawValue] }]
      case "open-world-messages": return try await openWorldMessages(try content(a, w), factory: w, clear: a["clear"] as? Bool == true, subscribe: a["subscribe"] as? Bool)
      case "script-add":
        let profile = EngineWebProfile(try focusedBrowser(w, create: a["create"] as? Bool ?? false).context)
        profile.addUserScript(
          UserScript(
            id: a["id"] as? String ?? UUID().uuidString, source: a["source"] as? String ?? "",
            kind: a["css"] as? Bool == true ? .styleSheet : .javaScript,
            injectionTime: a["end"] as? Bool == true ? .documentEnd : .documentStart,
            matchPatterns: a["matches"] as? [String] ?? ["<all_urls>"],
            mainFrameOnly: !(a["allFrames"] as? Bool ?? false), world: try scriptWorld(a)))
        return profile.userScripts.map(\.id)
      case "script-remove":
        let profile = EngineWebProfile(try focusedBrowser(w, create: a["create"] as? Bool ?? false).context)
        profile.removeUserScript(id: a["id"] as? String ?? "")
        return profile.userScripts.map(\.id)
      case "filter":
        let patterns = a["block"] as? [String] ?? []
        let profile = EngineWebProfile(try focusedBrowser(w, create: a["create"] as? Bool ?? false).context)
        blockCounter.reset()
        if patterns.isEmpty {
          profile.setRequestFilter(nil)
        } else {
          let counter = blockCounter
          profile.setRequestFilter { request in
            for p in patterns where request.url.contains(p) {
              counter.add(request.url)
              return true
            }
            return false
          }
        }
        return true
      case "filter-stats":
        return blockCounter.snapshot()
      case "permission":
        let origin = try url(a, "origin")
        let context = try focusedBrowser(w, create: a["create"] as? Bool ?? false).context
        let rawKind = a["kind"] as? Int ?? 0
        guard let bits = UInt32(exactly: rawKind) else { throw Failure(message: "invalid permission kind") }
        let kind = OEPermissionKind(rawValue: bits)
        guard SitePermissionStore.canPersist(kind) else { throw Failure(message: "no persistent setting for permission kind") }
        if let state = a["state"] as? Int, let s = OEPermissionState(rawValue: state) {
          SitePermissionStore.forContext(context).set(origin: origin, kind: kind, state: s, requestSystemAuthorization: false)
        }
        return SitePermissionStore.forContext(context).state(origin: origin, kind: kind).rawValue
      case "protocol-handlers":
        // Chromium's web protocol handler registry of the focused Profile.
        let context = try focusedBrowser(w, create: false).context
        var result: [String: Any] = [:]
        // Remove first, so `translated` describes the state after the removal.
        if let scheme = a["removeScheme"] as? String, let template = a["removeURLTemplate"] as? String {
          result["removed"] = context.protocolHandlers.first { $0.scheme == scheme && $0.urlTemplate == template }
            .map { context.removeProtocolHandler($0) } ?? false
        }
        if let raw = a["translate"] as? String, raw.utf8.count <= 4096, let target = URL(string: raw) {
          result["translated"] = context.protocolHandlerURL(for: target)?.absoluteString ?? NSNull()
        }
        result["handlers"] = context.protocolHandlers.map {
          ["scheme": $0.scheme, "urlTemplate": $0.urlTemplate, "default": $0.isDefault] as [String: Any]
        }
        return result
      case "download-dir":
        w.downloadDirectory = URL(fileURLWithPath: a["path"] as? String ?? NSTemporaryDirectory())
        return true
      case "downloads":
        return (w.focusedBrowser(create: a["create"] as? Bool ?? false)?.context.downloads ?? []).map {
          [
            "id": $0.identifier, "state": $0.state.rawValue, "received": $0.receivedBytes, "total": $0.totalBytes,
            "path": $0.destinationURL?.path ?? "", "url": $0.sourceURL.absoluteString,
          ] as [String: Any]
        }

      // Measurements.
      case "timing":
        return await timing(w)
      case "startup":
        var evidence = app.startupEvidence
        if let probe = w.earlyHostRequestsRefused { evidence["earlyHostRequestsRefused"] = probe }
        return evidence
      case "host-counts":
        return ["created": app.hostFactories.values.reduce(0) { $0 + $1.contentCreationCount },
                "retained": app.hostFactories.values.reduce(0) { $0 + $1.contents.count },
                "engineContents": OEEngine.shared.allWebContents.count]
      case "translate": return try await translateCommand(a)
      case "calendar": return try await calendarCommand(a)
      case "sidebar-unload":
        return w.controller?.sidebar(w.controller!.sidebar, didRequest: .unloadTab(try modelTab(a, w).id)) == true
      default:
        throw Failure(message: "unknown command \(cmd)")
      }
    }

    // MARK: Arguments

    private func modelTab(_ a: [String: Any], _ w: EngineWebContentHostFactory) throws -> Tab {
      if let s = a["tab"] as? String {
        guard let uuid = UUID(uuidString: s), let tab = w.model.tab(id: ItemID(rawValue: uuid)) else {
          throw Failure(message: "no tab \(s)")
        }
        return tab
      }
      if let n = a["index"] as? Int {
        let tabs = w.orderedTabs
        guard n >= 0, n < tabs.count else { throw Failure(message: "no tab at \(n)") }
        return tabs[n]
      }
      guard let tab = w.selectedTab else { throw Failure(message: "no selected tab") }
      return tab
    }

    /// `tab`: a tab UUID, a page identifier (number), "popup", or omitted
    /// for the selected tab.
    private func content(_ a: [String: Any], _ w: EngineWebContentHostFactory) throws -> OEWebContent {
      if let id = a["tab"] as? Int,
         let popup = ExtensionWindowController.windows.values.first(where: { $0.content.identifier == id }) {
        return popup.content
      }
      if let n = a["index"] as? Int {
        guard let page = w.ensureContent(for: try modelTab(["index": n], w)) else { throw Failure(message: "engine or profile is not ready") }
        return page
      }
      guard let page = w.content(forAutomationHandle: a["tab"]) else {
        throw Failure(message: "no page for \(a["tab"] ?? "selected tab")")
      }
      return page
    }

    func focusedBrowser(_ w: EngineWebContentHostFactory, create: Bool = false) throws -> OEBrowser {
      guard let b = w.focusedBrowser(create: create) else { throw Failure(message: "profile browser is not loaded (use create: true for an explicit interaction)") }
      return b
    }

    private func url(_ a: [String: Any], _ key: String) throws -> URL {
      guard let s = a[key] as? String, let url = URL(string: s) else { throw Failure(message: "missing \(key)") }
      return url
    }

    // MARK: Descriptions

    private func describe(_ tab: Tab, in w: EngineWebContentHostFactory) -> [String: Any] {
      let section: String
      if w.focusedProfile?.favorites.contains(where: { $0.id == tab.id }) == true {
        section = "favorites"
      } else if w.model.isPinned(tabID: tab.id) {
        section = "pinned"
      } else {
        section = "today"
      }
      var d: [String: Any] = [
        "createdAt": tab.createdAt.timeIntervalSince1970, "lastActiveAt": tab.lastActiveAt.timeIntervalSince1970,
        "id": tab.id.description, "title": tab.displayTitle, "url": tab.url.absoluteString, "section": section, "unread": tab.isUnread,
        "pinnedURL": tab.pinnedURL?.absoluteString ?? "",
        "selected": w.selectedTab?.id == tab.id, "visible": w.visibleTabs.contains { $0.id == tab.id },
        "loading": tab.live.isLoading, "audible": tab.live.isAudible, "crashed": tab.live.isCrashed,
        "favicon": tab.live.faviconPNG != nil, "sleepPhase": String(describing: tab.live.sleepPhase),
        "progress": tab.live.progress, "canGoBack": tab.live.canGoBack, "canGoForward": tab.live.canGoForward,
        "profile": w.profile(for: tab.id)?.id.description ?? "", "space": w.space(for: tab.id)?.id.description ?? "",
        "hasWebContent": tab.live.hasWebContent, "loaded": w.contents[tab.id] != nil,
      ]
      d["iconOverride"] = describeIcon(tab.iconOverride)
      d["rowFaviconSource"] = w.controller?.sidebar.drawnFaviconSource(tabID: tab.id) ?? ""
      d["rowFaviconHash"] = faviconHash(w.controller?.sidebar.drawnFavicon(tabID: tab.id))
      d["faviconReportsCompleted"] = app.stores.sidebarFavicons?.completedReports ?? 0
      d["faviconReportsRejected"] = app.stores.sidebarFavicons?.rejectedReports ?? 0
      if let c = w.contents[tab.id] {
        d["page"] = describe(c, in: w)
      }
      return d
    }

    private func faviconHash(_ image: NSImage?) -> String {
      guard let source = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let space = CGColorSpace(name: CGColorSpace.sRGB) else { return "" }
      var pixels = Data(count: 64 * 64 * 4)
      let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
          bytesPerRow: 256, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(source, in: CGRect(x: 0, y: 0, width: 64, height: 64)); return true
      }
      return ok ? SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined() : ""
    }

    private func describe(_ c: OEWebContent, in w: EngineWebContentHostFactory) -> [String: Any] {
      var kind = "unowned"
      if w.tabID(for: c) != nil {
        kind = "tab"
      } else if c.extensionPopupIdentifier != nil {
        kind = "extensionPopup"
      } else if w.auxiliaryPages.contains(where: { $0.content === c }) {
        kind = "popup"
      }
      let pageColor = w.hosts.values.first { $0.content === c }?.pageBackgroundColor
      return [
        "identifier": c.identifier, "nativeViewIdentity": String(describing: ObjectIdentifier(c.view)),
        "kind": kind, "live": c.isLive, "ephemeral": c.context.isEphemeral, "url": c.url?.absoluteString ?? "",
        "title": c.title, "loading": c.isLoading, "style": c.runtimeStyle == .chrome ? "chrome" : "alloy",
        "audible": c.isAudible, "muted": c.isMuted, "crash": c.crashState.rawValue, "fullscreen": c.isFullscreen,
        "favicon": c.favicon != nil, "context": c.context.identifier, "canGoBack": c.canGoBack,
        "zoom": c.zoomLevel, "popup": c.isPopup, "hidden": c.view.isHiddenOrHasHiddenAncestor,
        "browser": c.browser?.identifier ?? 0,
        "browserIndex": c.browser?.webContents.firstIndex(of: c) ?? -1,
        "browserPinned": c.browser?.isPinned(c) ?? false,
        // chrome.tabs / chrome.windows ids (fork patch P1); -1 if none.
        "chromeTabId": c.chromeTabIdentifier,
        "chromeWindowId": c.browser?.chromeWindowIdentifier ?? -1,
        "extension": c.extensionPopupIdentifier ?? "",
        "hostTab": w.tabID(for: c)?.description ?? "",
        "pageBackground": colorComponents(pageColor),
      ]
    }

    private func describe(_ action: OEExtensionAction) -> [String: Any] {
      func pixels(_ image: NSImage?) -> [String: Any] {
        guard let image else { return ["bytes": 0] }
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
          .sorted { $0.pixelsWide < $1.pixelsWide }
        guard !reps.isEmpty, reps.count <= 4 else { return ["bytes": 0] }
        var hash = SHA256(), byteCount = 0
        for rep in reps {
          let width = rep.pixelsWide, height = rep.pixelsHigh
          // Automation only. Largest permitted single allocation: 256 * 256 * 4 = 262144 bytes.
          guard width > 0, height > 0, width <= 256, height <= 256, let source = rep.cgImage,
                let space = CGColorSpace(name: CGColorSpace.sRGB) else { return ["bytes": 0] }
          var rgba = Data(count: width * height * 4)
          let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
          }
          guard drawn else { return ["bytes": 0] }
          hash.update(data: Data("\(width)x\(height):".utf8))
          hash.update(data: rgba)
          byteCount += rgba.count
        }
        return ["bytes": byteCount, "hash": hash.finalize().map { String(format: "%02x", $0) }.joined(),
          "width": image.size.width, "pixels": reps.map { [$0.pixelsWide, $0.pixelsHigh] },
          "object": ObjectIdentifier(image).hashValue]
      }
      func hex(_ color: NSColor?) -> Any {
        guard let c = color?.usingColorSpace(.sRGB) else { return NSNull() }
        return String(format: "#%02x%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
      }
      return [
        "id": action.extensionIdentifier, "name": action.extensionName, "title": action.title,
        "tooltip": action.tooltip, "accessibleName": action.accessibleName, "badge": action.badgeText ?? "",
        "badgeColor": hex(action.badgeBackgroundColor), "badgeTextColor": hex(action.badgeTextColor),
        "enabled": action.isEnabled, "hasPopup": action.hasPopup, "pinned": action.isPinned,
        "pinnedIndex": action.pinnedIndex, "wantsToRun": action.wantsToRun, "siteAccess": action.siteAccess.rawValue,
        "showingPopup": action.isShowingPopup, "toolbarImage": pixels(action.toolbarImage), "icon": pixels(action.icon),
        "live": action.isLive, "shortcutKeyEquivalent": action.shortcutKeyEquivalent ?? "",
        "shortcutModifierFlags": action.shortcutModifierFlags.rawValue,
      ]
    }

    private func describe(_ e: OEExtension) -> [String: Any] {
      [
        "id": e.identifier, "name": e.name, "version": e.version, "enabled": e.isEnabled, "unpacked": e.isUnpacked,
        "manifestVersion": e.manifestVersion, "options": e.optionsURL?.absoluteString ?? "",
        "directory": e.installDirectory.path,
        "icon": e.icon.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "",
        "permissions": e.permissions, "hostPermissions": e.hostPermissions,
        "hasAction": e.hasAction, "fromWebStore": e.fromWebStore,
        "homepage": e.homepageURL?.absoluteString ?? "", "disableReasons": e.disableReasons,
        "omniboxKeyword": e.omniboxKeyword ?? "",
      ]
    }
    static let syntheticPointerTag = 0x4F50
    private var hoveredOwners: [ObjectIdentifier: NSResponder] = [:]

    /// Delivers what AppKit's tracking-area machinery would for a pointer at `location`
    /// (window base coordinates): exit to owners it left, enter to owners it reached,
    /// and move to owners whose areas track movement.
    @discardableResult
    private func hover(_ window: NSWindow, at location: NSPoint, exitingOnly: Bool = false) -> [String: [String]] {
      // The whole frame view, so the title bar (window buttons) is included.
      guard let content = window.contentView?.superview ?? window.contentView else { return [:] }
      // AppKit builds tracking areas lazily, once the hardware pointer has reached the
      // window; ask every view for its areas first.
      func prepare(_ view: NSView) { view.updateTrackingAreas(); view.subviews.forEach(prepare) }
      prepare(content)
      var inside: [ObjectIdentifier: NSResponder] = [:]
      var moving: [ObjectIdentifier: NSResponder] = [:]
      // The point is visible in `view` when it lies inside the view and every ancestor
      // (scroll views and pages clip their content). Not `visibleRect`: views that do not
      // clip to their bounds (the macOS 14+ default) report the whole window there.
      func visible(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let current = v, current !== content.superview {
          if !current.bounds.contains(current.convert(location, from: nil)) { return false }
          v = current.superview
        }
        return true
      }
      func visit(_ view: NSView) {
        guard !view.isHidden else { return }
        let local = view.convert(location, from: nil)
        for area in view.trackingAreas {
          guard let owner = area.owner as? NSResponder else { continue }
          let hit = area.options.contains(.inVisibleRect) ? visible(view) : area.rect.contains(local) && visible(view)
          guard hit else { continue }
          if area.options.contains(.mouseEnteredAndExited) { inside[ObjectIdentifier(owner)] = owner }
          if area.options.contains(.mouseMoved) { moving[ObjectIdentifier(owner)] = owner }
        }
        view.subviews.forEach(visit)
      }
      visit(content)
      let time = ProcessInfo.processInfo.systemUptime
      func enterExit(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
      }
      let move = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
        context: nil, eventNumber: Self.syntheticPointerTag, clickCount: 0, pressure: 0)
      // Exit before the queued native motion can enter the new target. A late
      // synthetic SpacePageView exit would otherwise cancel the Favorite preview
      // that native motion just armed; its duplicate enter cannot re-arm it.
      if exitingOnly {
        let leaving = hoveredOwners.filter { inside[$0.key] == nil }
        if let exit = enterExit(.mouseExited) { for owner in leaving.values { owner.mouseExited(with: exit) } }
        return ["exited": leaving.values.map { String(describing: type(of: $0)) }.sorted()]
      }
      if let enter = enterExit(.mouseEntered) { for (id, owner) in inside where hoveredOwners[id] == nil { owner.mouseEntered(with: enter) } }
      if let move { for owner in moving.values { owner.mouseMoved(with: move) } }
      let entered = inside.filter { hoveredOwners[$0.key] == nil }.values
      hoveredOwners = inside
      let name = { (o: NSResponder) in String(describing: type(of: o)) }
      return ["inside": inside.values.map(name).sorted(), "entered": entered.map(name).sorted(), "moved": moving.values.map(name).sorted()]
    }

    private func describeAnimation(_ animation: CAAnimation) -> [String: Any] {
      var value: [String: Any] = ["duration": animation.duration, "beginTime": animation.beginTime,
        "type": String(describing: type(of: animation))]
      if let requestedAt = animation.value(forKey: "openRequestedAt") as? Double {
        value["requestedAt"] = requestedAt
        value["scheduledDelay"] = animation.beginTime - requestedAt
      }
      if let basic = animation as? CABasicAnimation {
        value["keyPath"] = basic.keyPath ?? ""
        value["from"] = (basic.fromValue as? NSNumber) ?? NSNull()
        value["to"] = (basic.toValue as? NSNumber) ?? NSNull()
      }
      if let spring = animation as? CASpringAnimation {
        value["mass"] = spring.mass
        value["stiffness"] = spring.stiffness
        value["physicalDamping"] = spring.damping
        value["settlingDuration"] = spring.settlingDuration
        value["response"] = 2 * Double.pi / sqrt(spring.stiffness / spring.mass)
        value["damping"] = spring.damping / (2 * sqrt(spring.stiffness * spring.mass))
        value["initialVelocity"] = spring.initialVelocity
      }
      if let timing = animation.timingFunction {
        value["timing"] = (0..<4).map { index -> [Float] in
          var p: [Float] = [0, 0]; timing.getControlPoint(at: index, values: &p); return p
        }
      }
      if let group = animation as? CAAnimationGroup { value["children"] = (group.animations ?? []).map(describeAnimation) }
      return value
    }
    private static func mappedExecutableURL(_ pid: Int32) -> URL? {
      var path = [CChar](repeating: 0, count: 4096)
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
      return URL(fileURLWithPath: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    private func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }

    private func legacyAX(_ object: NSObject, _ attribute: String) -> String {
      let selector = NSSelectorFromString("accessibilityAttributeValue:")
      guard object.responds(to: selector), let value = object.perform(selector, with: attribute)?.takeUnretainedValue() else { return "" }
      return value as? String ?? String(describing: value)
    }

    private func colorComponents(_ color: NSColor?) -> [Int] {
      guard let color = color?.usingColorSpace(.sRGB) else { return [] }
      return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    private func contentToolbarState(_ controller: BrowserWindowController) -> [String: Any] {
      let slot = controller.container.slots.count == 1 ? controller.container.slots[0] : nil
      let bar = slot?.paneChrome.flatMap { $0.role == .toolbar ? $0 : nil }
      return ["shown": controller.context.window?.showsToolbar == true, "drawn": bar != nil,
        "frame": bar.map { rect($0.frame) } ?? [], "controls": bar?.visibleControls ?? [], "text": bar?.displayedText ?? "",
        "page": slot?.contentHostView.map { rect($0.frame) } ?? [],
        "menu": controller.toolbarMenu()?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []]
    }

    private func describe(_ w: NSWindow) -> [String: Any] {
      [
        "number": w.windowNumber, "title": w.title, "class": String(describing: type(of: w)),
        "appearance": w.effectiveAppearance.name.rawValue,
        "explicitAppearance": w.appearance?.name.rawValue ?? "",
        "contentAppearance": w.contentView?.effectiveAppearance.name.rawValue ?? "",
        "viewAppearances": chromeViewAppearances(in: w.contentView),
        "visible": w.isVisible, "key": w.isKeyWindow, "main": w.isMainWindow,
        "alpha": w.alphaValue, "frame": NSStringFromRect(w.frame),
        "parent": w.parent?.windowNumber ?? 0, "level": w.level.rawValue,
        "sheet": w.isSheet, "attachedSheet": w.attachedSheet?.windowNumber ?? 0,
        "firstResponder": w.firstResponder.map { String(describing: type(of: $0)) } ?? "",
      ]
    }

    /// Bounded accessibility text from this process's own windows. Used to
    /// identify Chromium's uninstall confirmation, not merely any new window.
    func windowText(_ window: NSWindow) -> [String] {
      var seen: Set<ObjectIdentifier> = [], text: Set<String> = []
      func walk(_ object: NSObject, depth: Int) {
        if window.title.hasPrefix("Open Update"), let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
        guard depth <= 16, seen.count < 512, seen.insert(ObjectIdentifier(object)).inserted else { return }
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
          let selector = NSSelectorFromString(name)
          if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() as? String,
             !value.isEmpty { text.insert(String(value.prefix(400))) }
        }
        let children = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: children), let nodes = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
          for child in nodes.prefix(512) { walk(child, depth: depth + 1) }
        }
        if let view = object as? NSView { for child in view.subviews.prefix(512) { walk(child, depth: depth + 1) } }
      }
      walk(window, depth: 0)
      if let content = window.contentView { walk(content, depth: 0) }
      return text.sorted()
    }

    /// Roles only: inspect native Chromium popup accessibility without values.
    private func windowAccessibilityRoles(_ window: NSWindow) -> [String] {
      var seen: Set<ObjectIdentifier> = [], roles: Set<String> = []
      func walk(_ object: NSObject, depth: Int) {
        guard depth <= 16, seen.count < 512, seen.insert(ObjectIdentifier(object)).inserted else { return }
        let role = NSSelectorFromString("accessibilityRole")
        if object.responds(to: role), let value = object.perform(role)?.takeUnretainedValue() as? String {
          roles.insert(value)
        }
        let children = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: children), let nodes = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
          for child in nodes.prefix(512) { walk(child, depth: depth + 1) }
        }
        if let view = object as? NSView { for child in view.subviews.prefix(512) { walk(child, depth: depth + 1) } }
      }
      walk(window, depth: 0)
      if let content = window.contentView { walk(content, depth: 0) }
      return roles.sorted()
    }

    // MARK: Helpers

    /// Focus the actual Split View pane and execute in this same socket turn.
    /// This is the pane-toolbar click path: no yield can flush the engine for it.
    private func focusActionPane(_ a: [String: Any], _ w: EngineWebContentHostFactory) throws {
      guard let handle = a["focusTab"] else { return }
      let tab = try modelTab(["tab": handle], w)
      guard let controller = w.controller, let split = controller.splitController.split,
            split.panes.contains(where: { $0.id == tab.id }) else { throw Failure(message: "tab is not a split pane") }
      controller.splitController.focus(tab.id)
    }


    private func waitForLoad(_ page: OEWebContent, timeout: Double) async throws -> [String: Any] {
      let deadline = Date().addingTimeInterval(timeout)
      // Let a just-issued navigation start before polling.
      try await Task.sleep(for: .milliseconds(150))
      while Date() < deadline {
        if page.isLive && !page.isLoading && page.url != nil { return describe(page, in: try window) }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw Failure(message: "timeout waiting for load")
    }

    /// Clicks the element's center with DevTools Input events (real input
    /// inside the page, so the page sees a user gesture).
    private func click(_ page: OEWebContent, selector: String?, text: String?) async throws -> Any {
      // Find by CSS selector, or by visible text (case-insensitive regex)
      // among buttons and links, searching open shadow roots too.
      let js = """
        (() => {
          const sel = \(jsString(selector ?? "")), re = \(jsString(text ?? ""));
          const all = [];
          const walk = (root) => { for (const el of root.querySelectorAll('*')) { all.push(el); if (el.shadowRoot) walk(el.shadowRoot); } };
          walk(document);
          let e = sel ? document.querySelector(sel) : null;
          if (!e && re) { const rx = new RegExp(re, 'i');
            e = all.find(x => /^(BUTTON|A)$/.test(x.tagName) || x.getAttribute('role') === 'button'
                              ? rx.test((x.innerText || x.getAttribute('aria-label') || '').trim()) : false); }
          if (!e) return null; e.scrollIntoView({block:'center'});
          const r = e.getBoundingClientRect(); return [r.x + r.width/2, r.y + r.height/2]; })()
        """
      guard let point = try await page.evaluateJavaScript(js) as? [Double], point.count == 2 else {
        throw Failure(message: "no element for \(selector ?? text ?? "")")
      }
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await page.sendDevToolsMethod(
          "Input.dispatchMouseEvent",
          parameters: ["type": type, "x": point[0], "y": point[1], "button": "left", "clickCount": 1])
      }
      return point
    }

    private func jsString(_ s: String) -> String {
      let data = try? JSONSerialization.data(withJSONObject: [s])
      let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
      return String(arr.dropFirst().dropLast())
    }

    func describeIcon(_ icon: SpaceIcon?) -> Any {
      guard let icon else { return NSNull() }
      switch icon {
      case .emoji(let value): return ["type": "emoji", "value": value]
      case .named(let value): return ["type": "named", "value": value]
      case .symbol(let value): return ["type": "symbol", "value": value]
      }
    }
    private func describeNode(_ node: SidebarNode) -> [String: Any] {
      switch node {
      case .tab(let tab): return ["id": tab.id.description, "kind": "tab", "url": tab.url.absoluteString, "title": tab.displayTitle, "loaded": tab.live.hasWebContent]
      case .folder(let folder): return ["id": folder.id.description, "kind": "folder", "title": folder.title, "expanded": folder.isExpanded, "iconOverride": describeIcon(folder.iconOverride), "peekedChildID": folder.peekedChildID?.description ?? "", "children": folder.children.map(describeNode)]
      case .split(let split): return ["id": split.id.description, "kind": "split", "title":split.displayTitle, "customTitle":split.customTitle as Any? ?? NSNull(), "iconOverride":describeIcon(split.iconOverride), "children": split.panes.map { describeNode(.tab($0)) }]
      }
    }
    func menuEnabled(_ item: NSMenuItem) -> Bool {
      guard let action = item.action else { return item.isEnabled }
      let target = item.target ?? NSApp.target(forAction: action, to: nil, from: item)
      if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
      if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
      return target != nil
    }
    private func menuRows(_ menu: NSMenu?) -> [[String: Any]] {
      (menu?.items ?? []).flatMap { item -> [[String: Any]] in
        if let submenu = item.submenu { return menuRows(submenu) }
        guard !item.isSeparatorItem else { return [] }
        // Validate first, as AppKit does before it shows a menu: validation can set the title (CC-32).
        let enabled = menuEnabled(item)
        return [["id": item.identifier?.rawValue ?? "", "title": item.title, "key": item.keyEquivalent,
          "modifierMask": item.keyEquivalentModifierMask.rawValue,
          "badgeCount": item.badge?.itemCount ?? 0, "enabled": enabled, "checked": item.state == .on, "hidden": item.isHidden, "targetNil": item.target == nil, "tag": item.tag, "action": item.action.map(NSStringFromSelector) ?? "", "payload": (item.representedObject as? [String: String])?["payload"] ?? ""]]
      }
    }
    func findMenuItem(_ id: String, in menu: NSMenu?) -> (NSMenu, Int)? {
      guard let menu else { return nil }
      for (index, item) in menu.items.enumerated() {
        if item.identifier?.rawValue == id { return (menu, index) }
        if let found = findMenuItem(id, in: item.submenu) { return found }
      }
      return nil
    }

    private func normalizedModifier(_ name: String) -> String {
      switch name { case "cmd": return "command"; case "opt", "alt": return "option"; case "ctrl": return "control"; default: return name }
    }

    func sidebarController(_ args: [String: Any]) throws -> BrowserWindowController {
      if let raw = args["window"] {
        guard let id = raw as? String, let controller = app.windowControllers.first(where: { $0.windowID.description == id }) else { throw Failure(message: "unknown browser window") }
        return controller
      }
      guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
      return controller
    }

    private func sidebarPoint(_ args: [String: Any], controller: BrowserWindowController, favorite: Bool = false) throws -> NSPoint {
      guard let text = args[favorite ? "favorite" : "node"] as? String, let uuid = UUID(uuidString: text),
        app.model.node(id: ItemID(rawValue: uuid)) != nil else { throw Failure(message: "invalid sidebar node") }
      let id = ItemID(rawValue: uuid)
      controller.contentView.layoutSubtreeIfNeeded()
      if !favorite { controller.sidebar.reveal(nodeID: id) }
      controller.contentView.layoutSubtreeIfNeeded()
      guard let frame = favorite ? controller.sidebar.favoriteFrame(tabID: id) : controller.sidebar.rowFrame(nodeID: id),
        !controller.sidebar.isHidden, frame.intersects(controller.sidebar.bounds),
        let outline = controller.sidebar.focusedOutline, favorite || !outline.visibleRect.isEmpty else { throw Failure(message: "no visible sidebar target") }
      let root = controller.contentView.convert(frame, from: controller.sidebar)
      return NSPoint(x: root.midX, y: root.midY)
    }

    /// The unread badge drawn on one Favorite tile (audit A2): its text, whether it shows, and its
    /// frame in the tile. Read from the real view tree (AX identifier `favoriteUnreadBadge`).
    private func favoriteBadge(_ args: [String: Any]) throws -> Any {
      let controller = try sidebarController(args)
      let point = try sidebarPoint(args, controller: controller, favorite: true)
      controller.contentView.layoutSubtreeIfNeeded()
      controller.contentView.displayIfNeeded()
      func badges(in view: NSView) -> [NSView] {
        (view.accessibilityIdentifier() == "favoriteUnreadBadge" ? [view] : []) + view.subviews.flatMap(badges)
      }
      guard let badge = badges(in: controller.contentView).first(where: { view in
        guard let tile = view.superview else { return false }
        return controller.contentView.convert(tile.bounds, from: tile).contains(point)
      }), let tile = badge.superview else { throw Failure(message: "no Favorite tile at that node") }
      let subtitle = tile.subviews.first { $0.accessibilityIdentifier() == "favoriteMeetingSubtitle" }
      return ["shown": !badge.isHidden && !(badge.accessibilityValue() as? String ?? "").isEmpty,
        "subtitleShown": subtitle.map { !$0.isHidden } ?? false,
        "text": badge.accessibilityValue() as? String ?? "",
        "frame": [badge.frame.minX, badge.frame.minY, badge.frame.width, badge.frame.height],
        "tile": [tile.bounds.width, tile.bounds.height]] as [String: Any]
    }

    /// A real NSEvent click on a Favorites tile (through NSApp.sendEvent and hit testing),
    /// with the view chain that hit testing returns at that point.
    private func favoriteClick(_ args: [String: Any]) async throws -> Any {
      let controller = try sidebarController(args)
      let point = try sidebarPoint(args, controller: controller, favorite: true)
      guard let target = controller.window, let factory = app.hostFactories[controller.windowID] else { throw Failure(message: "no browser window") }
      try await activateForInput(target)
      let windowPoint = controller.contentView.convert(point, to: nil)
      var chain: [String] = []
      var view = target.contentView?.superview?.hitTest(windowPoint) ?? target.contentView?.hitTest(windowPoint)
      while let current = view, chain.count < 16 { chain.append(String(describing: type(of: current))); view = current.superview }
      _ = try await mouse(["action": "click", "window": target.windowNumber, "x": Double(point.x), "y": Double(point.y),
        "queued": args["queued"] as? Bool ?? true], factory)
      try await Task.sleep(nanoseconds: 300_000_000)
      return ["point": [point.x, point.y], "hitChain": chain, "selected": factory.selectedNodeID?.description ?? "",
        "selectedTab": factory.selectedTab?.id.description ?? ""] as [String: Any]
    }

    private func sidebarClick(_ args: [String: Any]) async throws -> Any {
      let controller = try sidebarController(args)
      let point = try sidebarPoint(args, controller: controller)
      guard let target = controller.window, let factory = app.hostFactories[controller.windowID],
        let outline = controller.sidebar.focusedOutline,
        let id = (args["node"] as? String).flatMap(UUID.init(uuidString:)).map({ ItemID(rawValue: $0) }),
        let node = app.model.node(id: id) else { throw Failure(message: "no browser sidebar node") }
      try await activateForInput(target)
      let capturesMotion = args["motion"] as? Bool == true
      let previousReduceMotion = Motion.reduceMotionOverride
      if capturesMotion { Motion.reduceMotionOverride = false }
      defer { if capturesMotion { Motion.reduceMotionOverride = previousReduceMotion } }
      let eventStarted = CACurrentMediaTime()
      _ = try await mouse(["action": "click", "window": target.windowNumber, "x": Double(point.x), "y": Double(point.y), "modifiers": args["modifiers"] as? [String] ?? []], factory)
      await Task.yield()
      var result: [String: Any] = ["selection": controller.context.selection.ids.map(\.description),
        "selected": factory.selectedNodeID?.description ?? "", "accepted": true,
        "expanded": node.folder?.isExpanded ?? false, "peekedChildID": node.folder?.peekedChildID?.description ?? ""]
      if args["motion"] as? Bool == true {
        let started = eventStarted
        var samples: [[String: Any]] = [], animations: [[String: Any]] = []
        func inspect(_ layer: CALayer) {
          for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) else { continue }
            let path = (animation as? CAPropertyAnimation)?.keyPath ?? key
            var points: [Float] = []
            if let curve = animation.timingFunction {
              for index in 0..<4 { var p: [Float] = [0,0]; curve.getControlPoint(at: index, values: &p); points += p }
            }
            animations.append(["path": path, "duration": animation.duration, "curve": points])
          }
          for child in layer.sublayers ?? [] { inspect(child) }
        }
        for _ in 0..<8 {
          var positions: [String: Double] = [:]
          for index in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: index), let view = outline.rowView(atRow: index, makeIfNecessary: false) else { continue }
            let id: String
            if let tab = item as? Tab { id = tab.id.description }
            else if let folder = item as? Folder { id = folder.id.description }
            else { continue }
            positions[id] = Double(view.layer?.presentation()?.frame.minY ?? view.frame.minY)
            if samples.isEmpty, let layer = view.layer { inspect(layer) }
          }
          samples.append(["time": CACurrentMediaTime() - started, "rows": positions])
          try await Task.sleep(for: .milliseconds(45))
        }
        result["motion"] = ["appliedDuration": SidebarDiagnostics.folderTransitionDuration,
          "expanding": SidebarDiagnostics.folderTransitionExpanding, "animations": animations, "samples": samples]
      }
      return result
    }

    private func sidebarKey(_ args: [String: Any]) async throws -> Any {
      let controller = try sidebarController(args)
      guard let target = controller.window, let outline = controller.sidebar.focusedOutline,
        let factory = app.hostFactories[controller.windowID] else { throw Failure(message: "no sidebar outline") }
      try await activateForInput(target)
      guard target.makeFirstResponder(outline) else { throw Failure(message: "sidebar focus refused") }
      var input = args; input["window"] = target.windowNumber; input["route"] = "app"
      return try await sendKey(input, factory)
    }

    private func sidebarHover(_ args: [String: Any]) async throws -> Any {
      let controller = try sidebarController(args)
      guard let target = controller.window, let factory = app.hostFactories[controller.windowID],
        let ms = (args["ms"] ?? 0) as? Int, (0...5000).contains(ms) else { throw Failure(message: "invalid hover duration") }
      let leave = args["leave"] as? Bool == true
      let targets = [args["node"], args["favorite"]].compactMap { $0 }.count
      guard leave ? targets == 0 : targets == 1 else { throw Failure(message: "hover needs one node or favorite, or leave") }
      let point = try leave ? NSPoint(x: controller.contentView.bounds.maxX - 80, y: controller.contentView.bounds.midY) : sidebarPoint(args, controller: controller, favorite: args["favorite"] != nil)
      try await activateForInput(target)
      let tracking = try await mouse(["action": "hover", "window": target.windowNumber, "x": Double(point.x), "y": Double(point.y)], factory)
      if ms > 0 { try await Task.sleep(for: .milliseconds(ms)) }
      var result = try previewState(args)
      result["tracking"] = tracking
      result["point"] = [point.x, point.y]
      let tracker = controller.context.hoverPreviews
      result["armed"] = tracker.isArmed
      result["scheduledShows"] = tracker.scheduledShowCount
      result["showDeadline"] = tracker.scheduledShowDeadline.map { $0 as Any } ?? NSNull()
      return result
    }

    private func previewState(_ a: [String: Any]) throws -> [String: Any] {
      let controller = try sidebarController(a)
      let preview = controller.hoverPreview
      var kind = "none", target = ""
      switch preview.request?.kind {
      case .page(let id)?: kind = "page"; target = id.description
      case .folder(let id)?: kind = "folder"; target = id.description
      case .glance(let id)?: kind = "glance"; target = id.description
      case nil: break
      }
      return ["kind": kind, "target": target, "card": preview.card.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
        "host": preview.host.map { String(describing: ObjectIdentifier($0)) } ?? "",
        "cachedHost": preview.hostTabID.flatMap { controller.container.host(for: $0) }.map { String(describing: ObjectIdentifier($0)) } ?? "",
        "makeHostCount": preview.makeHostCount, "reusedCachedHost": preview.reusedCachedHost, "shows": preview.shows] as [String: Any]
    }

    func mouse(_ a: [String: Any], _ w: EngineWebContentHostFactory?) async throws -> Any {
      let number = a["window"] as? Int ?? app.onboardingWindowController?.window?.windowNumber ?? w?.window?.windowNumber ?? 0
      guard let target = NSApp.windows.first(where: { $0.windowNumber == number }) else { throw Failure(message: "no window \(number)") }
      pointerRequestID += 1
      let motionTag = Self.syntheticPointerTag + pointerRequestID
      func event(_ type: NSEvent.EventType, _ point: [Double]) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: point[0], y: target.frame.height - point[1]),
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number,
          context: nil, eventNumber: motionTag, clickCount: a["clickCount"] as? Int ?? 1,
          pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0)
      }
      let action = a["action"] as? String
      if action == "scroll-cadence-stop" {
        guard let scrollCadence else { throw Failure(message: "no scroll cadence probe") }
        scrollCadence.stop(); self.scrollCadence = nil
        return scrollCadence.state
      }
      if action == "scroll" || action == "scroll-cadence-start" {
        // Performance harness: normal own-window AppKit dispatch only. Never
        // posts a CGEvent to the system or changes the hardware pointer.
        let dx = a["dx"] as? Double ?? 0, dy = a["dy"] as? Double ?? 0
        let x = a["x"] as? Double ?? 0, y = a["y"] as? Double ?? 0
        guard dx.isFinite, dy.isFinite, abs(dx) <= 4096, abs(dy) <= 4096,
          x.isFinite, y.isFinite, x >= 0, y >= 0, x < target.frame.width, y < target.frame.height,
          let root = target.contentView else { throw Failure(message: "invalid scroll") }
        let point = NSPoint(x: x, y: target.frame.height - y)
        let local = root.convert(point, from: nil)
        guard let hit = root.hitTest(local) else { throw Failure(message: "no scroll target") }
        if action == "scroll-cadence-start" {
          var view: NSView? = hit
          while let candidate = view, !(candidate is NSClipView) { view = candidate.superview }
          guard let clip = view as? NSClipView else { throw Failure(message: "no native scroll clip") }
          scrollCadence?.stop(); scrollCadence = AutomationScrollCadence(clip: clip)
          return ["started": true, "limit": 4096] as [String: Any]
        }
        guard
          let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        else { throw Failure(message: "no scroll target") }
        let phase: Int64
        switch a["phase"] as? String ?? "changed" {
        case "none": phase = 0
        case "began": phase = 1
        case "changed": phase = 2
        case "ended": phase = 4
        case "cancelled": phase = 8
        default: throw Failure(message: "invalid scroll phase")
        }
        cg.location = target.convertPoint(toScreen: point)
        cg.location.y = (NSScreen.screens.first?.frame.maxY ?? 0) - cg.location.y
        cg.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        let momentum = a["momentum"] as? Int64 ?? 0
        guard (0...3).contains(momentum) else { throw Failure(message: "invalid momentum phase") }
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(number))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(number))
        guard let native = NSEvent(cgEvent: cg) else { throw Failure(message: "scroll event refused") }
        let event = AutomationScrollEvent(native: native, window: target, point: point)
        guard event.window === target else { throw Failure(message: "scroll event did not address own window") }
        NSApp.sendEvent(event)
        return ["eventTimestamp": event.timestamp, "dx": dx, "dy": dy,
          "window": event.windowNumber, "phase": phase, "momentum": momentum,
          "routedPhase": event.phase.rawValue, "routedMomentum": event.momentumPhase.rawValue,
          "scrollingDelta": [event.scrollingDeltaX, event.scrollingDeltaY],
          "location": [event.locationInWindow.x, event.locationInWindow.y],
          "targetPoint": [point.x, point.y]] as [String: Any]
      }
      if action == "down" || action == "drag" || action == "up" {
        let point = [a["x"] as? Double ?? 0, a["y"] as? Double ?? 0]
        BrowserWindowController.pointerEventFilter = { $0.eventNumber == motionTag }
        BrowserWindowController.automationPointer = (number, NSPoint(x: point[0], y: target.frame.height - point[1]))
        target.layoutIfNeeded()
        let type: NSEvent.EventType = action == "down" ? .leftMouseDown : action == "drag" ? .leftMouseDragged : .leftMouseUp
        if let e = event(type, point) { NSApp.sendEvent(e) }
      } else if action == "move" || action == "hover" {
        // Local event monitors run on AppKit's native dequeue path. Queue
        // motion just like real input, including after a Space transition.
        // From the first synthetic move on, pointer-driven window logic (the
        // sidebar hover reveal) follows only these tagged events, so the
        // hardware pointer of whoever uses the Mac cannot disturb a check.
        BrowserWindowController.pointerEventFilter = { $0.eventNumber == motionTag }
        let point = [a["x"] as? Double ?? 0, a["y"] as? Double ?? 0]
        let owner = app.windowControllers.first { $0.window === target }
        let count = owner?.revealState.pointerEvents
        let delivered = Mutex(false)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { e in
          if e.windowNumber == number && e.eventNumber == motionTag { delivered.withLock { $0 = true } }
          return e
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let location = NSPoint(x: point[0], y: target.frame.height - point[1])
        let leaving = action == "hover" ? hover(target, at: location, exitingOnly: true) : [:]
        if let e = event(.mouseMoved, point) { NSApp.postEvent(e, atStart: false) }
        // The local monitor consumes motion on native dequeue. A second
        // queued move must not overtake/coalesce the leave-edge event that
        // clears reveal suppression. Acknowledge actual delivery, not a delay.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !delivered.withLock({ $0 }) || (owner != nil && owner!.revealState.pointerEvents <= count!) {
            guard ContinuousClock.now < deadline else { throw Failure(message: "pointer motion was not dequeued") }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Native motion has now arrived. Publish its point before rebuilding
        // tracking areas: owners that sync from the pointer during that rebuild
        // must see the new location, or they undo the preflight exit above.
        BrowserWindowController.automationPointer = (number, location)
        if action == "hover" {
          var result = hover(target, at: location)
          result["exited"] = leaving["exited"] ?? []
          return result
        }
        // A move delivers no enter or exit, so the owners `hover` entered before may no longer
        // hold the pointer; the next `hover` enters the owners under its point again.
        hoveredOwners = [:]
      } else if action == "click" {
        // A click with modifiers (for example Option on the zoom button). Controls that
        // track the mouse wait for the mouse-up on the event queue, so it goes there first.
        var flags: NSEvent.ModifierFlags = []
        for name in a["modifiers"] as? [String] ?? [] {
          switch normalizedModifier(name) { case "option": flags.insert(.option); case "command": flags.insert(.command)
          case "shift": flags.insert(.shift); case "control": flags.insert(.control); default: break }
        }
        let point = NSPoint(x: a["x"] as? Double ?? 0, y: target.frame.height - (a["y"] as? Double ?? 0))
        // A click happens where the pointer is.
        BrowserWindowController.automationPointer = (number, point)
        func click(_ type: NSEvent.EventType) -> NSEvent? {
          NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: number, context: nil, eventNumber: 0, clickCount: a["clickCount"] as? Int ?? 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        // Real input arrives after the display cycle has laid the window out (the window
        // buttons are placed at its end); run that pass before hit-testing.
        target.layoutIfNeeded()
        // A click also moves the simulated pointer. Reconcile tracking before
        // mouseDown, so an old Favorite enter cannot outlive a row click.
        _ = hover(target, at: point, exitingOnly: true)
        _ = hover(target, at: point)
        if a["queued"] as? Bool == true {
          // Controls that read NSApp.currentEvent (Option-click pane Close) need
          // native dequeue, not a direct sendEvent with an unrelated current event.
          let delivered = Mutex(false)
          let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            if event.windowNumber == number && event.locationInWindow == point { delivered.withLock { $0 = true } }
            return event
          }
          defer { if let monitor { NSEvent.removeMonitor(monitor) } }
          if let down = click(.leftMouseDown) { NSApp.postEvent(down, atStart: false) }
          if let up = click(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
          let deadline = ContinuousClock.now.advanced(by: .seconds(3))
          while !delivered.withLock({ $0 }) {
            guard ContinuousClock.now < deadline else { throw Failure(message: "pointer click was not dequeued") }
            try await Task.sleep(for: .milliseconds(5))
          }
        } else {
          if let up = click(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
          if let down = click(.leftMouseDown) { NSApp.sendEvent(down) }
        }
      } else if let start = a["from"] as? [Double], let end = a["to"] as? [Double], start.count == 2, end.count == 2 {
        // The real resize handle consumes these own-window events through
        // NSWindow.nextEvent. No system cursor or keyboard is touched.
        BrowserWindowController.pointerEventFilter = { $0.eventNumber == motionTag }
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
          BrowserWindowController.automationPointer = (number, NSPoint(x: point[0], y: target.frame.height - point[1]))
          if let e = event(type, point) { NSApp.sendEvent(e) }
        }
      } else {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          if let e = event(type, [a["x"] as? Double ?? 0, a["y"] as? Double ?? 0]) { NSApp.sendEvent(e) }
        }
      }
      return true
    }

    private struct InputReadiness {
      let active: Bool
      let targetIsKey: Bool
      let keyWindowNumber: Int
      let keySameObject: Bool
      let fullscreenTransition: Bool

      // AppKit can retain the key flag while moving the window between
      // full-screen Spaces. Only the native completion callback makes that
      // key flag an input-readiness grant again.
      var ready: Bool { active && targetIsKey && keySameObject && !fullscreenTransition }
      var state: [String: Any] {
        ["appActive": active, "key": targetIsKey, "keyWindow": keyWindowNumber,
          "keySameObject": keySameObject, "fullscreenTransition": fullscreenTransition]
      }
    }

    /// Synchronous so the full-screen negative sample and native input use
    /// exactly the same predicate without yielding between its observations.
    private func inputReadiness(_ target: NSWindow) -> InputReadiness {
      let active = NSApp.isActive, targetIsKey = target.isKeyWindow
      let keyWindow = NSApp.keyWindow
      return InputReadiness(active: active, targetIsKey: targetIsKey,
        keyWindowNumber: keyWindow?.windowNumber ?? 0, keySameObject: keyWindow === target,
        fullscreenTransition: app.windowControllers.first { $0.window === target }?.isChangingFullScreen ?? false)
    }

    func activateForInput(_ target: NSWindow, timeout: Double = 5) async throws {
      // Activation is asynchronous. Never inject into an inactive app after a
      // fixed grace period: its production router correctly declines the key.
      // Make the requested window key again once activation has completed.
      target.makeKeyAndOrderFront(nil); NSApp.activate()
      let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
      while true {
        // Retain the same predicate values for the grant and any refusal.
        let readiness = inputReadiness(target)
        // AppKit keeps the Little Open parent as NSApp.keyWindow while its
        // native NSPopoverWindow reports isKeyWindow and owns the field editor.
        // Accept only that exact, visible picker and its key parent.
        let littlePicker = app.littleOpenCoordinator?.controllers.values.first {
          $0.spacePicker?.view.window === target && $0.window === NSApp.keyWindow
        }
        if readiness.active, readiness.targetIsKey, target.isVisible,
          littlePicker?.window?.isKeyWindow == true, !readiness.fullscreenTransition {
          nativeInputStart = ProcessInfo.processInfo.systemUptime
          return
        }
        if readiness.ready {
          nativeInputStart = ProcessInfo.processInfo.systemUptime
          return
        }
        guard ContinuousClock.now < deadline else {
          let foreground = NSWorkspace.shared.frontmostApplication
          throw Failure(message: "key focus not ready: active=\(readiness.active) target=\(target.windowNumber) targetIsKey=\(readiness.targetIsKey) key=\(readiness.keyWindowNumber) keySameObject=\(readiness.keySameObject) fullscreenTransition=\(readiness.fullscreenTransition) onActiveSpace=\(target.isOnActiveSpace) canBecomeKey=\(target.canBecomeKey) class=\(String(reflecting: type(of: target))) attachedSheet=\(target.attachedSheet?.windowNumber ?? 0) childWindows=\(target.childWindows?.map(\.windowNumber) ?? []) frontmost=\(foreground?.localizedName ?? "unknown") frontmostPID=\(foreground?.processIdentifier ?? 0)")
        }
        if readiness.active && !readiness.fullscreenTransition { target.makeKeyAndOrderFront(nil) }
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    /// Posts a key event inside Open. `route: "app"` (default) goes through
    /// NSApplication.sendEvent, like a real key press; `route: "window"`
    /// sends it straight to the window's first responder (the page view when
    /// it has focus), which exercises the engine's pre-key hook. In-process
    /// only: the system keyboard is never touched.
    func sendKey(_ a: [String: Any], _ w: EngineWebContentHostFactory?) async throws -> Any {
      guard let target = a["window"] as? String == "popup" ? w?.popupPanel :
        (a["window"] as? Int).flatMap({ n in NSApp.windows.first { $0.windowNumber == n } }) ?? app.onboardingWindowController.flatMap { $0.window?.isVisible == true ? $0.window : nil } ?? app.firstRunWindowController?.window ?? w?.window
      else { throw Failure(message: "no window") }
      try await activateForInput(target)
      if let text = a["text"] as? String {
        // Plain characters to the first responder (the address field, a
        // text field in a page, ...).
        for ch in text {
          for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
              with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: target.windowNumber, context: nil, characters: String(ch),
              charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: ch == "\r" ? 36 : 0)
            {
              if a["route"] as? String == "window" { target.sendEvent(event) } else { NSApp.sendEvent(event) }
            }
          }
        }
        try? await Task.sleep(for: .milliseconds(20))
        return ["firstResponder": target.firstResponder.map { String(describing: type(of: $0)) } ?? "none"]
      }
      let keys: [String: (String, UInt16)] = [
        ".": (".", 47),
        "[": ("[", 33), "]": ("]", 30),
        "enter": ("\u{3}", 76),
        "return": ("\r", 36), "escape": ("\u{1b}", 53), "tab": ("\t", 48), "space": (" ", 49),
        "delete": ("\u{7f}", 51), "forward-delete": (String(Character(UnicodeScalar(NSDeleteFunctionKey)!)), 117),
        "o": ("o", 31), ",": (",", 43), "z": ("z", 6), "n": ("n", 45), "t": ("t", 17), "w": ("w", 13), "l": ("l", 37), "f": ("f", 3), "g": ("g", 5), "s": ("s", 1), "a": ("a", 0),
        "e": ("e", 14), "r": ("r", 15), "k": ("k", 40), "v": ("v", 9), "x": ("x", 7), "c": ("c", 8), "d": ("d", 2), "i": ("i", 34), "j": ("j", 38), "y": ("y", 16), "u": ("u", 32),
        "b": ("b", 11), "h": ("h", 4), "m": ("m", 46), "p": ("p", 35), "q": ("q", 12),
        // Every digit, so Ctrl+1…9 (Go to Space) and Cmd+1…9 (Go to Tab) reach the router.
        "0": ("0", 29), "1": ("1", 18), "2": ("2", 19), "3": ("3", 20), "4": ("4", 21), "5": ("5", 23),
        "6": ("6", 22), "7": ("7", 26), "8": ("8", 28), "9": ("9", 25), "=": ("=", 24), "-": ("-", 27), "}": ("}", 30), "{": ("{", 33),
        "control": ("", 59), "command": ("", 55),
        "down": (String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125),
        "up": (String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), 126),
        "left": (String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), 123),
        "right": (String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), 124),
      ]
      guard let (chars, code) = keys[a["key"] as? String ?? "return"] else { throw Failure(message: "unknown key") }
      var mods: NSEvent.ModifierFlags = []
      for m in a["modifiers"] as? [String] ?? [] {
        switch normalizedModifier(m) {
        case "command": mods.insert(.command)
        case "shift": mods.insert(.shift)
        case "option": mods.insert(.option)
        case "control": mods.insert(.control)
        default: break
        }
      }
      if code >= 123 { mods.insert([.function, .numericPad]) }
      // AppKit preserves Shift in charactersIgnoringModifiers. Native menu
      // equivalents such as Redo need "Z", even though the key router folds case.
      let eventCharacters = mods.contains(.shift) ? chars.uppercased() : chars
      let route = a["route"] as? String ?? "app"
      let observeCommands = a["observeCommands"] as? Bool == true
      var menuObserver: (any NSObjectProtocol)?
      if observeCommands {
        AutomationShortcutTrace.commands = []; AutomationShortcutTrace.recording = true
        AutomationShortcutTrace.menuActions = []
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { note in
          let identifier = (note.userInfo?["MenuItem"] as? NSMenuItem)?.identifier?.rawValue
          MainActor.assumeIsolated {
            if let identifier, AutomationShortcutTrace.menuActions.count < 64 {
              AutomationShortcutTrace.menuActions.append(identifier)
            }
          }
        }
      }
      defer {
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        if observeCommands { AutomationShortcutTrace.recording = false }
      }
      let dispatchStarted = ProcessInfo.processInfo.systemUptime
      // Modifier keys alone post one flagsChanged event (down: pass the modifier; up: none).
      let types: [NSEvent.EventType] = code == 59 || code == 55 ? [.flagsChanged] : [.keyDown, .keyUp]
      let eventTimestamp = a["eventTimestamp"] as? Double ?? ProcessInfo.processInfo.systemUptime
      guard eventTimestamp.isFinite else { throw Failure(message: "eventTimestamp must be finite") }
      for type in types {
        guard
          let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: mods, timestamp: eventTimestamp,
            windowNumber: target.windowNumber, context: nil, characters: eventCharacters, charactersIgnoringModifiers: eventCharacters,
            isARepeat: false, keyCode: code)
        else { continue }
        if route == "window" { target.sendEvent(event) } else { NSApp.sendEvent(event) }
      }
      let dispatchMilliseconds = (ProcessInfo.processInfo.systemUptime - dispatchStarted) * 1000
      // CEF's window key callback is asynchronous. Report after its next pump
      // turn, as a user-facing automation caller expects.
      try? await Task.sleep(for: .milliseconds(20))
      return ["dispatchMilliseconds": dispatchMilliseconds, "firstResponder": target.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
        "charactersIgnoringModifiers": eventCharacters,
        "commands": observeCommands ? AutomationShortcutTrace.commands : [], "menuActions": observeCommands ? AutomationShortcutTrace.menuActions : [],
        "sidebarMode": w?.windowState.sidebarMode.rawValue ?? "", "barPresented": w?.commandBarSession?.isPresented == true,
        "keyWindow": NSApp.keyWindow?.windowNumber ?? 0] as [String: Any]
    }

    private func snapshot(_ a: [String: Any], _ w: EngineWebContentHostFactory?) async throws -> Any {
      let path = a["path"] as? String ?? NSTemporaryDirectory() + "open-snapshot.png"
      let url = URL(fileURLWithPath: path)
      if a["tab"] != nil || a["page"] as? Bool == true {
        guard let w else { throw Failure(message: "no browser window") }
        let page: any WebContent = try content(a, w)
        try await page.snapshotPNG().write(to: url)
        return ["path": path, "method": "devtools"]
      }
      if a["window"] as? String == "library", app.settingsPresenter.libraryWindow == nil { throw Failure(message: "no Library window") }
      if a["window"] as? String == "editor" {
        guard let panel: NSWindow = w?.iconPicker?.panel ?? w?.controller?.spaceCreationController?.themeEditor?.panel ?? w?.controller?.themeEditor?.panel,
              panel.isVisible else { throw Failure(message: "no editor") }
        return ["path": path, "method": try await WindowSnapshot.capture(panel, to: url)]
      }
      let number = a["window"] as? String == "library" ? app.settingsPresenter.libraryWindow?.windowNumber : a["window"] as? Int
      guard let target = number.flatMap({ n in NSApp.windows.first { $0.windowNumber == n } }) ?? app.onboardingWindowController.flatMap { $0.window?.isVisible == true ? $0.window : nil } ?? app.firstRunWindowController?.window ?? w?.window
      else { throw Failure(message: "no window") }
      guard target.identifier?.rawValue != "onboarding-dim" else { throw Failure(message: "dim window snapshots are excluded") }
      var keyTime: Double?
      var capturedAfterKey: Double?
      let toggle = a["toggleSidebar"] as? Bool == true
      let overlays = try (a["overlayWindows"] as? [Int] ?? []).map { number in
        guard let window = NSApp.windows.first(where: { $0.windowNumber == number && $0.isVisible })
        else { throw Failure(message: "overlay window is not owned and visible") }
        return window
      }
      let method = try await WindowSnapshot.capture(target, to: url, afterPreparation: toggle ? {
        let time = ProcessInfo.processInfo.systemUptime
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: time,
          windowNumber: target.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) {
          keyTime = CACurrentMediaTime()
          NSApp.sendEvent(event)
        }
      } : nil, atCapture: { capturedAfterKey = keyTime.map { CACurrentMediaTime() - $0 } }, overlayWindows: overlays)
      return ["path": path, "method": method, "capturedAfterKey": capturedAfterKey ?? NSNull()] as [String: Any]
    }

    private func metrics(interval: Double) async -> [String: Any] {
      let tasks = await OEEngine.shared.sampleProcessMetrics(after: interval)
      let footprints = ProcessFootprint.tree(root: getpid())
      return [
        "tasks": tasks.map {
          [
            "kind": $0.kind.rawValue, "title": $0.title, "memory": $0.memoryFootprint, "gpu": $0.gpuMemory,
            "cpu": $0.cpuUsage,
          ] as [String: Any]
        },
        "processes": footprints.map {
          ["pid": Int($0.pid), "name": $0.name, "footprint": $0.footprint, "rss": $0.rss] as [String: Any]
        },
        "totalFootprint": footprints.reduce(UInt64(0)) { $0 + $1.footprint },
        "totalRSS": footprints.reduce(UInt64(0)) { $0 + $1.rss },
        "livePages": OEEngine.shared.allWebContents.filter(\.isLive).count,
      ]
    }

    // MARK: Real Library Space Manager

    private func hostedSpaceManagers(in view: NSView?) -> [SpaceManagerView] {
      guard let view else { return [] }
      return (view as? SpaceManagerView).map { [$0] } ?? view.subviews.flatMap { hostedSpaceManagers(in: $0) }
    }
    private func spaceManagerState() -> [String: Any] {
      if managerUndoObserver == nil {
        managerUndoObserver = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidUndoChange, object: app.undoManager, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.managerUndoCount += 1 }
        }
      }
      let adapter = app.settingsPresenter
      let target = adapter.libraryWindow
      target?.layoutIfNeeded(); target?.contentView?.layoutSubtreeIfNeeded()
      let managers = hostedSpaceManagers(in: target?.contentView)
      let manager = managers.first
      let columns: [[String: Any]] = manager.map { manager in
        manager.columnOrder.map { id in
          let grabber = manager.controls(spaceID: id)?.grabber
          let rect = grabber.map { $0.convert($0.bounds, to: nil) } ?? .zero
          let outline = manager.outline(spaceID: id)
          let rows: [[String: Any]] = (0..<min(outline?.numberOfRows ?? 0, 200)).compactMap { row in
            guard let outline else { return nil }
            let item = outline.item(atRow: row)
            guard let nodeID = (item as? Tab)?.id ?? (item as? Folder)?.id ?? (item as? Split)?.id else { return nil }
            let frame = outline.convert(outline.rect(ofRow: row), to: nil)
            return ["id": nodeID.description, "point": [frame.midX, (target?.frame.height ?? 0) - frame.midY]]
          }
          // Spec geometry (plan §3.2, S4 R1): column frame in the manager's flipped
          // coordinates (scroll origin removed) and header parts in column coordinates.
          let origin = manager.scrollView.contentView.bounds.origin
          let column = manager.columnFrame(spaceID: id).map { $0.offsetBy(dx: -origin.x, dy: -origin.y) } ?? .zero
          let parts = (manager.controls(spaceID: id)?.partFrames ?? [:]).mapValues { [$0.minX, $0.minY, $0.width, $0.height] }
          return ["id": id.description, "grabber": [rect.midX, (target?.frame.height ?? 0) - rect.midY], "rows": rows,
            "column": [column.minX, column.minY, column.width, column.height], "header": parts,
            "managerSize": [manager.bounds.width, manager.bounds.height]]
        }
      } ?? []
      let switchers = app.windowControllers.map { controller -> [String: Any] in
        controller.window?.layoutIfNeeded(); controller.sidebar.layoutSubtreeIfNeeded()
        let items = app.model.spaces.compactMap { space -> (String, CGFloat)? in
          guard let view = controller.sidebar.spaceSwitcher(spaceID: space.id) else { return nil }
          return (space.id.description, view.convert(view.bounds, to: nil).minX)
        }.sorted { $0.1 < $1.1 }
        return ["window": controller.windowID.description, "order": items.map(\.0)]
      }
      return ["window": target?.windowNumber ?? 0, "visible": target?.isVisible == true,
        "section": adapter.library?.section.rawValue ?? "", "hostedManagers": managers.count,
        "managerClass": manager.map { String(reflecting: type(of: $0)) } ?? "",
        "identity": manager.map { String(describing: ObjectIdentifier($0)) } ?? "",
        "contextWindow": manager?.context.windowID.description ?? "",
        "contextValid": manager?.context.window != nil,
        "sameModel": manager?.context.model === app.model && adapter.library?.model === app.model,
        "sameUndoManager": target?.undoManager === app.model.undoManager,
        "undoEnabled": SystemCommandActions.isEnabled("undo"),
        "undoTarget": SystemCommandActions.sender(for: "undo").flatMap { item in
          item.action.flatMap { NSApp.target(forAction: $0, to: nil, from: item) }.map { String(reflecting: type(of: $0)) }
        } ?? "",
        "modelUndoCount": managerUndoCount,
        "previewsEnabled": manager?.context.previewPreferences.bool(forKey: "open.general.previewsEnabled") ?? true,
        "globalPreviewsEnabled": UserDefaults.standard.object(forKey: "open.general.previewsEnabled") as? Bool ?? true,
        "columns": columns, "switchers": switchers, "windows": NSApp.windows.map(describe)] as [String: Any]
    }
    private func realSpaceManager() throws -> (SpaceManagerView, NSWindow) {
      guard let target = app.settingsPresenter.libraryWindow, target.isVisible,
        let manager = hostedSpaceManagers(in: target.contentView).first
      else { throw Failure(message: "real SpaceManagerView is unavailable") }
      target.layoutIfNeeded(); manager.layoutSubtreeIfNeeded()
      return (manager, target)
    }
    private func dragSpaceManager(_ args: [String: Any]) async throws -> Any {
      let (manager, target) = try realSpaceManager()
      guard let id = args["space"] as? String,
        let source = manager.columnOrder.first(where: { $0.description == id }),
        let sourceIndex = manager.columnOrder.firstIndex(of: source),
        let index = args["to"] as? Int, manager.columnOrder.indices.contains(index),
        let grabber = manager.controls(spaceID: source)?.grabber,
        let destinationControls = manager.controls(spaceID: manager.columnOrder[index])
      else { throw Failure(message: "invalid Space reorder") }
      try await activateForInput(target)
      let destination = destinationControls.grabber
      let startRect = grabber.convert(grabber.bounds, to: nil)
      let endRect = destination.convert(destination.bounds, to: nil)
      let start = NSPoint(x: startRect.midX, y: startRect.midY)
      // PR #350 moved the grabber to the card's left edge. Reordering crosses
      // card midpoints, so finish just beyond the destination midpoint.
      let destinationRect = destinationControls.convert(destinationControls.bounds, to: nil)
      let end = sourceIndex == index ? start : NSPoint(x: destinationRect.midX + (sourceIndex < index ? 1 : -1), y: endRect.midY)
      guard grabber.visibleRect.contains(NSPoint(x: grabber.bounds.midX, y: grabber.bounds.midY)),
        destination.visibleRect.contains(NSPoint(x: destination.bounds.midX, y: destination.bounds.midY))
      else { throw Failure(message: "Space grabber is outside the visible Library") }
      func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
      }
      // The native grabber's tracking loop dequeues drag/up. Only the initial
      // down is dispatched here, through OEApplication's production event path.
      guard let down = event(.leftMouseDown, start), let drag = event(.leftMouseDragged, end), let up = event(.leftMouseUp, end)
      else { throw Failure(message: "could not create Space drag events") }
      NSApp.postEvent(drag, atStart: false); NSApp.postEvent(up, atStart: false)
      NSApp.sendEvent(down)
      await Task.yield()
      return spaceManagerState()
    }
    private func performSpaceManagerMenu(_ args: [String: Any]) throws -> Any {
      let (manager, target) = try realSpaceManager()
      guard let raw = args["space"] as? String, let id = manager.columnOrder.first(where: { $0.description == raw }),
        let title = args["item"] as? String else { throw Failure(message: "missing Space menu target") }
      let menu: NSMenu?
      if let nodeID = args["node"] as? String, let outline = manager.outline(spaceID: id) {
        guard let row = (0..<outline.numberOfRows).first(where: { row in
          let item = outline.item(atRow: row)
          return (item as? Tab)?.id.description == nodeID || (item as? Folder)?.id.description == nodeID || (item as? Split)?.id.description == nodeID
        }) else { throw Failure(message: "manager row is unavailable") }
        let rect = outline.convert(outline.rect(ofRow: row), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { throw Failure(message: "could not create row menu event") }
        menu = outline.menu(for: event)
      } else if args["header"] as? Bool == true, let controls = manager.controls(spaceID: id) {
        // A right-click on the card header (Library › Spaces), through the view's own menu(for:).
        let point = controls.convert(NSPoint(x: controls.bounds.midX, y: 12), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { throw Failure(message: "could not create header menu event") }
        menu = controls.menu(for: event)
      } else { menu = manager.controls(spaceID: id)?.makeMenu() }
      if title == "?" { return menu?.items.map { $0.isSeparatorItem ? "separator" : $0.title } ?? [] }
      // "Turn into Folder/<Space>" walks one submenu level per path component.
      var level = menu
      let path = title.split(separator: "/").map(String.init)
      for (depth, component) in path.enumerated() {
        guard let current = level, let index = current.items.firstIndex(where: { $0.title == component && $0.isEnabled })
        else { throw Failure(message: "manager menu item is unavailable") }
        if depth == path.count - 1 { current.performActionForItem(at: index) } else { level = current.items[index].submenu }
      }
      return true
    }
    /// Passive cache read: do not layout/build the hidden manager while checking focus work.
    private func spaceManagerLifecycle(_ args: [String: Any]) throws -> [String: Any] {
      let adapter = app.settingsPresenter
      let session: AppLibrarySession?
      if let id = args["id"] as? String {
        guard let controller = app.windowControllers.first(where: { $0.windowID.description == id }) else { throw Failure(message: "unknown browser window") }
        session = adapter.librarySessions[controller.windowID]
      } else { session = adapter.activeLibrarySession }
      let manager = session?.model.spaceManagerView as? SpaceManagerView
      let target = session?.controller?.isLibraryOpen == true ? session?.controller?.window : nil
      var sectionRows: [[String: Any]] = []
      // PR #350 replaced the table rail with native tiles. Use the same real
      // controls as Library automation; the harness still clicks via sendEvent.
      if let panel = session?.panel, let target {
        for tile in panel.automationRailState {
          guard let section = tile["id"] as? String, let frame = tile["frame"] as? [CGFloat], frame.count == 4 else { continue }
          let point = panel.convert(CGPoint(x: frame[0] + frame[2] / 2, y: frame[1] + frame[3] / 2), to: nil)
          sectionRows.append(["section": section, "point": [point.x, target.frame.height - point.y]])
        }
      }
      return ["identity": manager.map { String(describing: ObjectIdentifier($0)) } ?? "",
        "contextWindow": manager?.context.windowID.description ?? "", "builtColumns": manager?.builtColumnIDs.count ?? 0,
        "origin": [manager?.scrollView.contentView.bounds.origin.x ?? 0, manager?.scrollView.contentView.bounds.origin.y ?? 0],
        "systemAppearance": manager.map { String(describing: $0.context.systemAppearance) } ?? "",
        "appAppearance": NSApp.appearance?.name.rawValue ?? "", "visible": target?.isVisible == true,
        "key": target?.isKeyWindow == true, "section": session?.model.section.rawValue ?? "",
        "undoRegistrationEnabled": app.undoManager.isUndoRegistrationEnabled, "sectionRows": sectionRows] as [String: Any]
    }
    /// Coordinates of actual visible row controls; input still uses OEApplication.sendEvent.
    private func spaceManagerRowControls(_ args: [String: Any]) throws -> Any {
      let (manager, target) = try realSpaceManager()
      guard let space = args["space"] as? String, let node = args["node"] as? String,
        let id = manager.columnOrder.first(where: { $0.description == space }), let outline = manager.outline(spaceID: id),
        let row = (0..<min(outline.numberOfRows, 200)).first(where: { (outline.item(atRow: $0) as? Tab)?.id.description == node }),
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
      else { throw Failure(message: "visible manager row is unavailable") }
      var controls: [[String: Any]] = [], visited = 0
      func walk(_ view: NSView, depth: Int) {
        guard depth <= 12, visited < 256 else { return }; visited += 1
        if let label = view.accessibilityLabel(), !label.isEmpty, !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty {
          let rect = view.convert(view.bounds, to: nil)
          controls.append(["label": String(label.prefix(160)), "point": [rect.midX, target.frame.height - rect.midY]])
        }
        for child in view.subviews.prefix(256) { walk(child, depth: depth + 1) }
      }
      walk(cell, depth: 0)
      let rect = outline.convert(outline.rect(ofRow: row), to: nil)
      return ["frame": [rect.minX, target.frame.height - rect.maxY, rect.width, rect.height], "controls": controls] as [String: Any]
    }
    isolated deinit {
      if let managerUndoObserver { NotificationCenter.default.removeObserver(managerUndoObserver) }
      if let updaterModalObserver { NotificationCenter.default.removeObserver(updaterModalObserver) }
    }

    private func timing(_ w: EngineWebContentHostFactory) async -> [String: Any] {
      var out: [String: Any] = LaunchTiming.shared.report
      if let counts = app.cloneCleanupCounts { out["cloneCleanup"] = counts }
      out["clock"] = "mach_continuous_time; kernel ri_proc_start_abstime"
      out["kernelProcessStart"] = LaunchTiming.shared.hasKernelProcessStart
      if let page = w.selectedContent {
        // Both page values use the renderer's monotonic Performance clock.
        // Map that clock to process uptime at the CDP round-trip midpoint.
        let before = LaunchTiming.shared.elapsedMilliseconds
        let js = "(() => { const p = performance.getEntriesByName('first-contentful-paint')[0]; return p ? {now:performance.now(), paint:p.startTime} : null; })()"
        if let values = try? await page.evaluateJavaScript(js) as? [String: Double],
          let now = values["now"], let paint = values["paint"]
        {
          let after = LaunchTiming.shared.elapsedMilliseconds
          out["firstContentfulPaint"] = ((before + after) / 2 + paint - now).rounded()
          out["firstPaintClockUncertaintyMs"] = ((after - before) / 2 * 100).rounded() / 100
        }
      }
      return out
    }

  }

  /// Counts blocked requests. Touched from Chromium's network thread.
  final class BlockCounter: Sendable {
    private let state = Mutex<(count: Int, recent: [String])>((0, []))

    func add(_ url: String) {
      state.withLock {
        $0.count += 1
        $0.recent.append(url)
        if $0.recent.count > 50 { $0.recent.removeFirst() }
      }
    }

    func reset() { state.withLock { $0 = (0, []) } }

    func snapshot() -> [String: Any] {
      state.withLock { ["blocked": $0.count, "recent": $0.recent] }
    }
  }

  /// Physical footprint (what Activity Monitor shows) of a process and its
  /// direct children (Chromium launches every helper from the browser process).
  enum ProcessFootprint {
    struct Sample {
      let pid: pid_t
      let name: String
      let footprint: UInt64
      let rss: UInt64
    }

    static func tree(root: pid_t) -> [Sample] {
      var pids = [root]
      let count = proc_listchildpids(root, nil, 0)
      if count > 0 {
        var children = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listchildpids(root, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        pids += children.prefix(Int(n))
      }
      return pids.compactMap(sample)
    }

    static func sample(_ pid: pid_t) -> Sample? {
      var info = rusage_info_v4()
      let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
          proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
      }
      guard ok == 0 else { return nil }
      var name = [CChar](repeating: 0, count: 1024)
      proc_name(pid, &name, UInt32(name.count))
      var task = proc_taskinfo()
      proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
      return Sample(
        pid: pid, name: String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
        footprint: info.ri_phys_footprint, rss: task.pti_resident_size)
    }
  }
#endif
