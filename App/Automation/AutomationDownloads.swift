#if OPEN_AUTOMATION
import AppKit
import Darwin
import OpenModel
import OpenSettings

extension AutomationController {
  static let downloadCommands: Set<String> = ["downloads-state", "download-settings", "download-row", "download-menu", "download-save", "download-policy", "download-home", "download-idle", "download-library-close"]
  private func downloadRows() -> [DownloadRowView] {
    func rows(_ view: NSView) -> [DownloadRowView] {
      (view as? DownloadRowView).map { [$0] } ?? view.subviews.flatMap(rows)
    }
    return app.settingsPresenter.libraryPresenter?.window?.contentView.map(rows) ?? []
  }
  func runDownloadCommand(_ cmd: String, _ args: [String: Any]) async throws -> Any {
    let center = app.downloadsCenter
    switch cmd {
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
      return true
    case "downloads-state":
      return ["items": center.downloads.map { item in
        ["id": item.id, "name": item.fileName, "state": item.state.rawValue, "received": item.receivedBytes,
         "total": item.totalBytes as Any? ?? NSNull(), "speed": item.bytesPerSecond, "path": item.filePath ?? "",
         "profile": item.profileID.description, "fileExists": item.fileExists ?? false] as [String: Any]
      }, "rows": downloadRows().map { ["id": $0.item.id, "subtitle": $0.subtitle.stringValue, "buttons": $0.buttons.map { $0.identifier?.rawValue ?? "" }] },
       "badge": app.frontWindowController?.sidebar.downloadBadgeEvidence ?? [:], "running": center.hasRunning,
       "queued": center.queued, "updates": center.updateCount, "publishes": center.publishCount,
       "fallbacks": center.fallbackCount, "error": center.lastFileError, "fileActions": center.fileActions, "quitAlerts": center.quitAlerts,
       "sheets": center.choices.map { ["id": $0.key, "name": $0.value.panel.nameFieldStringValue,
         "directory": $0.value.panel.directoryURL?.path ?? "", "visible": $0.value.panel.isVisible,
         "sheet": $0.value.panel.sheetParent != nil] as [String: Any] }] as [String: Any]
    case "download-row", "download-menu":
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
      app.settingsPresenter.libraryPresenter?.window?.performClose(nil); return true
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
      guard pressDownloadPanelButton(choice.panel, title: title) else { throw Failure(message: "save sheet button unavailable: " + title) }
      return true
    case "download-home":
      guard let home = app.frontWindowController?.sidebar.homeButton, home.accessibilityPerformPress() else { throw Failure(message: "Home unavailable") }
      return true
    case "download-idle":
      return try downloadIdleProof(args)
    default: throw Failure(message: "unknown download command")
    }
  }
  /// Save panels use a remote view on current macOS. Walk only this owned
  /// sheet's bounded accessibility tree and invoke its real AXPress action.
  private func pressDownloadPanelButton(_ panel: NSSavePanel, title: String) -> Bool {
    var seen: Set<ObjectIdentifier> = []
    func string(_ object: NSObject, _ name: String) -> String {
      let selector = NSSelectorFromString(name)
      return object.responds(to: selector) ? (object.perform(selector)?.takeUnretainedValue() as? String ?? "") : ""
    }
    func attribute(_ object: NSObject, _ name: String) -> Any? {
      let selector = NSSelectorFromString("accessibilityAttributeValue:")
      return object.responds(to: selector) ? object.perform(selector, with: name)?.takeUnretainedValue() : nil
    }
    func press(_ object: NSObject, depth: Int) -> Bool {
      guard depth < 20, seen.count < 512, seen.insert(ObjectIdentifier(object)).inserted else { return false }
      let labels = ["accessibilityTitle", "accessibilityLabel", "accessibilityDescription"].map { string(object, $0) } + ["AXTitle", "AXDescription", "AXHelp"].map { attribute(object, $0) as? String ?? "" }
      if labels.contains(title) {
        if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
        let modern = NSSelectorFromString("accessibilityPerformPress")
        if object.responds(to: modern) {
          typealias Press = @convention(c) (AnyObject, Selector) -> Bool
          let call = unsafeBitCast(object.method(for: modern), to: Press.self)
          if call(object, modern) { return true }
        }
        let legacy = NSSelectorFromString("accessibilityPerformAction:")
        if object.responds(to: legacy) { object.perform(legacy, with: "AXPress"); return true }
      }
      let children = NSSelectorFromString("accessibilityChildren")
      if object.responds(to: children), let nodes = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
        for child in nodes.prefix(512) where press(child, depth: depth + 1) { return true }
      }
      if let nodes = attribute(object, "AXChildren") as? [NSObject] {
        for child in nodes.prefix(512) where press(child, depth: depth + 1) { return true }
      }
      if let view = object as? NSView { for child in view.subviews.prefix(512) where press(child, depth: depth + 1) { return true } }
      return false
    }
    return press(panel, depth: 0) || panel.contentView.map { press($0, depth: 0) } == true
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
