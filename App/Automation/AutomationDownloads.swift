#if OPEN_AUTOMATION
import AppKit
import Darwin
import ObjectiveC
import OpenModel
import OpenSettings

extension AutomationController {
  static let downloadCommands: Set<String> = ["downloads-state", "download-settings", "download-row", "download-menu", "download-save", "download-policy", "download-home", "download-idle", "download-library-close", "download-start-age", "settings-clear-data", "download-profile-filter", "download-history-flush"]
  private func downloadProfileControl() -> NSPopUpButton? {
    func find(_ view: NSView) -> NSPopUpButton? {
      if let button = view as? NSPopUpButton, button.identifier?.rawValue == "download-profile-filter" { return button }
      for child in view.subviews { if let found = find(child) { return found } }
      return nil
    }
    return app.settingsPresenter.libraryPresenter?.window?.contentView.flatMap(find)
  }
  private func overlayDownloadRows() -> [[String:Any]]? {
    guard let panel = app.settingsPresenter.activeLibrarySession?.panel, panel.isPresented, panel.section == .downloads else { return nil }
    return (panel.automationState()["rows"] as? [[String:Any]] ?? []).map { row in
      let id = row["id"] as? String ?? ""
      return ["id":id,"subtitle":row["subtitle"] ?? "","buttons":panel.rowMenu(id)?.filter { $0["enabled"] as? Bool == true }.compactMap { $0["title"] as? String } ?? []]
    }
  }
  private func downloadRows() -> [DownloadRowView] {
    func rows(_ view: NSView) -> [DownloadRowView] {
      (view as? DownloadRowView).map { [$0] } ?? view.subviews.flatMap(rows)
    }
    return app.settingsPresenter.libraryPresenter?.window?.contentView.map(rows) ?? []
  }
  func runDownloadCommand(_ cmd: String, _ args: [String: Any]) async throws -> Any {
    let center = app.downloadsCenter
    switch cmd {
    case "download-history-flush":
      await center.flushHistory(); return true
    case "download-profile-filter":
      if let panel = app.settingsPresenter.activeLibrarySession?.panel, let selection = args["profile"] as? String {
        guard panel.filterDownloadProfile(selection) else { throw Failure(message:"unknown Profile") }; return true
      }
      guard let button = downloadProfileControl(), let selection = args["profile"] as? String else { throw Failure(message: "Downloads Profile filter is not visible") }
      let index = selection == "all" ? 0 : button.itemArray.firstIndex { ($0.representedObject as? String) == selection }
      guard let index else { throw Failure(message: "unknown Downloads Profile filter") }
      button.selectItem(at: index)
      guard button.sendAction(button.action, to: button.target) else { throw Failure(message: "Downloads Profile filter action unavailable") }
      return true
    case "download-start-age":
      guard let key = args["id"] as? String, let age = args["seconds"] as? Double,
        center.setStartForAutomation(key, age: age) else { throw Failure(message: "expected an existing download and age in 0...31536000 seconds") }
      return true
    case "settings-clear-data":
      guard let raw = args["profile"] as? String, let profile = app.model.profiles.first(where: { $0.id.description == raw }),
        let value = args["kinds"] as? Int, (0...15).contains(value),
        let label = args["range"] as? String, let range = ClearDataRange(rawValue: label) else { throw Failure(message: "expected Profile, kinds in 0...15, and time range") }
      let profiles = app.settingsPresenter.settings.profiles
      profiles.select(profile.id); profiles.showClear()
      profiles.clearKinds = ClearDataKinds(rawValue: value); profiles.clearRange = range
      await profiles.clear()
      profiles.showsClear = false
      return ["status": profiles.clearStatus]
    case "download-settings":
      guard let raw = args["profile"] as? String, let id = UUID(uuidString: raw), app.model.profile(id: ProfileID(rawValue: id)) != nil else { throw Failure(message: "unknown Profile") }
      let settings = app.settingsPresenter.settings.profiles
      settings.select(ProfileID(rawValue: id))
      if let path = args["directory"] as? String { guard path.utf8.count <= 4096 else { throw Failure(message: "path too long") }; settings.downloadDirectory = path }
      if let ask = args["ask"] as? Bool { settings.askWhereToSave = ask }
      return ["directory": settings.downloadDirectory, "ask": settings.askWhereToSave] as [String: Any]
    case "download-policy":
      if let value = args["quit"] as? String {
        guard ["close", "keep", "record"].contains(value) else { throw Failure(message: "invalid quit policy") }
        center.quitAlertPolicy = value
      }
      if let value = args["recordFiles"] as? Bool { center.recordFileActions = value }
      if let path = args["openApp"] as? String {
        guard path.utf8.count <= 4096 else { throw Failure(message: "opener path too long") }
        center.fileOpenerForAutomation = URL(fileURLWithPath: path)
      }
      return true
    case "downloads-state":
      return ["items": center.downloads.map { item in
        ["id": item.id, "name": item.fileName, "state": item.state.rawValue, "received": item.receivedBytes,
         "total": item.totalBytes as Any? ?? NSNull(), "speed": item.bytesPerSecond, "path": item.filePath ?? "",
         "profile": item.profileID.description, "startedAt": item.startedAt.timeIntervalSince1970,
         "endedAt": item.endedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
         "source": item.sourceURL?.absoluteString ?? "", "historical": item.isHistorical,
         "littleOpenSession": center.sourceSessionForAutomation(item.id) ?? "",
         "fileExists": item.fileExists as Any? ?? NSNull()] as [String: Any]
      }, "rows": overlayDownloadRows() ?? downloadRows().map { ["id": $0.item.id, "subtitle": $0.subtitle.stringValue, "buttons": $0.buttons.map { $0.identifier?.rawValue ?? "" }] },
       "badge": app.frontWindowController?.sidebar.downloadBadgeEvidence ?? [:], "running": center.hasRunning,
       "queued": center.queued, "updates": center.updateCount, "publishes": center.publishCount,
       "detachedPages": center.detachedPageCountForAutomation,
       "openerPID": center.fileOpenerPID, "historyError": center.downloadHistoryError, "historyLoaded": center.historyLoaded,
       "profileFilter": downloadProfileControl().map { ["visible": !$0.isHidden, "titles": $0.itemTitles,
         "selected": ($0.selectedItem?.representedObject as? String) ?? "all"] as [String: Any] } ?? [:],
       "visibleItems": app.settingsPresenter.library?.downloadItems.map(\.id) ?? [],
       "copiedFileURL": NSPasteboard.general.string(forType: .fileURL) ?? "",
       "fallbacks": center.fallbackCount, "error": center.lastFileError, "fileActions": center.fileActions, "quitAlerts": center.quitAlerts,
       "sheets": center.choices.map { ["id": $0.key, "name": $0.value.panel.nameFieldStringValue,
         "directory": $0.value.panel.directoryURL?.path ?? "", "visible": $0.value.panel.isVisible,
         "sheet": $0.value.panel.sheetParent != nil,
         "parent": $0.value.panel.sheetParent?.windowNumber ?? 0] as [String: Any] }] as [String: Any]
    case "download-row", "download-menu":
      if let panel = app.settingsPresenter.activeLibrarySession?.panel, panel.section == .downloads, let id = args["id"] as? String {
        if cmd == "download-row" {
          guard let action = args["action"] as? String, panel.performRow(id,action:action) else { throw Failure(message:"download action unavailable") }; return true
        }
        guard let menu = panel.rowMenu(id,select:args["select"] as? String) else { throw Failure(message:"download menu unavailable") }; return menu
      }
      guard let id = args["id"] as? String, let row = downloadRows().first(where: { $0.item.id == id }) else { throw Failure(message: "download row is not visible") }
      if cmd == "download-row" {
        guard let action = args["action"] as? String, let button = row.buttons.first(where: { $0.identifier?.rawValue == action }), button.isEnabled else { throw Failure(message: "download button unavailable") }
        button.performClick(nil); return true
      }
      let menu = row.downloadMenu()
      if let title = args["select"] as? String {
        guard let index = menu.items.firstIndex(where: { $0.title == title && $0.isEnabled && !$0.isSeparatorItem }) else { throw Failure(message: "download menu item unavailable") }
        menu.performActionForItem(at: index)
      }
      return menu.items.map { ["title": $0.isSeparatorItem ? "separator" : $0.title, "enabled": $0.isEnabled] }
    case "download-library-close":
      app.settingsPresenter.closeLibrary(); return true
    case "download-save":
      guard let id = args["id"] as? String, let choice = center.choices[id], choice.panel.isVisible, choice.panel.sheetParent != nil else { throw Failure(message: "no download save sheet") }
      let cancel = args["action"] as? String == "cancel"
      if !cancel {
        guard let path = args["path"] as? String, path.utf8.count <= 4096 else { throw Failure(message: "expected cancel or a save path") }
        let url = URL(fileURLWithPath: path)
        choice.panel.directoryURL = url.deletingLastPathComponent()
        choice.panel.nameFieldStringValue = url.lastPathComponent
        try? await Task.sleep(for: .milliseconds(150))
      }
      let title = cancel ? "Cancel" : choice.panel.prompt ?? "Save"
      if !pressDownloadPanelButton(choice.panel, title: title) {
        // The remote panel hides its buttons. The spec also permits URL
        // input: supply the selected URL to NSSavePanel's native service
        // response path. Its existing beginSheetModal completion (not this
        // automation command) reads panel.url and answers OpenEngine.
        let selector = NSSelectorFromString("completeWithReturnCode:url:urls:")
        guard let method = class_getInstanceMethod(type(of: choice.panel), selector),
          let types = method_getTypeEncoding(method), String(cString: types) == "v40@0:8q16@24@32"
        else { throw Failure(message: "save panel URL input is unavailable") }
        typealias Complete = @convention(c) (AnyObject, Selector, Int, NSURL?, NSArray?) -> Void
        let complete = unsafeBitCast(method_getImplementation(method), to: Complete.self)
        let selected = cancel ? nil : (args["path"] as? String).map { URL(fileURLWithPath: $0) }
        // AppKit requires a one-file array for OK and nil for Cancel.
        let urls: NSArray? = selected.map { [$0 as NSURL] as NSArray }
        complete(choice.panel, selector, cancel ? NSApplication.ModalResponse.cancel.rawValue : NSApplication.ModalResponse.OK.rawValue, selected as NSURL?, urls)
      }
      return true
    case "download-home":
      guard let home = app.frontWindowController?.sidebar.homeButton, home.accessibilityPerformPress() else { throw Failure(message: "Home unavailable") }
      return true
    case "download-idle":
      return try downloadIdleProof(args)
    default: throw Failure(message: "unknown download command")
    }
  }
  /// Prefer an actual native button where AppKit exposes one. Remote panels
  /// use the spec's native URL-input path in runDownloadCommand above.
  private func pressDownloadPanelButton(_ panel: NSSavePanel, title: String) -> Bool {
    var visited = 0
    func button(_ view: NSView) -> NSButton? {
      guard visited < 512 else { return nil }; visited += 1
      if let button = view as? NSButton, button.title == title, button.isEnabled { return button }
      for child in view.subviews.prefix(512) { if let found = button(child) { return found } }
      return nil
    }
    guard let content = panel.contentView, let target = button(content) else { return false }
    target.performClick(nil); return true
  }
  /// The same native observer as S8, injected only by the e2e runner. No idle
  /// hooks or observer library are included in a shipping build.
  private func downloadIdleProof(_ args: [String: Any]) throws -> Any {
    typealias VoidFunction = @convention(c) () -> Void
    typealias WatchFunction = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias CountFunction = @convention(c) (Int32) -> UInt64
    func symbol<T>(_ name: String, _: T.Type) throws -> T {
      guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { throw Failure(message: "idle observer not loaded: " + name) }
      return unsafeBitCast(address, to: T.self)
    }
    let count = try symbol("open_idle_count", CountFunction.self)
    switch args["action"] as? String {
    case "begin":
      try symbol("open_idle_begin", VoidFunction.self)()
      if let home = app.frontWindowController?.sidebar.homeButton { try symbol("open_idle_watch_view", WatchFunction.self)(Unmanaged.passUnretained(home).toOpaque()) }
    case "reset": try symbol("open_idle_reset_events", VoidFunction.self)()
    case "end": try symbol("open_idle_end", VoidFunction.self)()
    case "canary":
      // A real repeating timer proves native scheduler observation is live.
      let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in }
      let live = count(6); timer.invalidate()
      return ["live": live, "after": count(6)]
    default: break
    }
    return (0..<10).map { count(Int32($0)) }
  }
}
#endif
