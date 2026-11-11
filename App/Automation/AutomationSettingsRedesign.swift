#if OPEN_AUTOMATION
import AppKit
import OpenSettings
import OpenCommands
import OpenDesign
import CryptoKit
import CoreGraphics

extension AutomationController {
  func settingsDisplayInfo(_ screen: NSScreen?) -> [String: Any] {
    guard let screen else { return [:] }
    let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    let mode = CGDisplayCopyDisplayMode(display)
    let profile = screen.colorSpace?.iccProfileData ?? Data()
    return ["name": screen.localizedName, "scale": screen.backingScaleFactor,
      "pixels": [mode?.pixelWidth ?? 0, mode?.pixelHeight ?? 0], "modeHz": mode?.refreshRate ?? 0,
      "maximumFPS": screen.maximumFramesPerSecond,
      "iccSHA256": SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined()]
  }
  func settingsPerformance(_ args: [String: Any]) throws -> [String: Any] {
    let action = args["action"] as? String ?? "state"
    if action == "stop" { settingsPerformanceProbe?.stop() }
    if ["sections", "scroll"].contains(action) {
      guard settingsPerformanceProbe?.running != true, let window = app.settingsPresenter.settingsPresenter.window else { throw Failure(message: "Settings probe busy or window missing") }
      settingsPerformanceProbe = SettingsPerformanceProbe(window: window, root: app.settingsPresenter.settings, mode: action)
    }
    var state = settingsPerformanceProbe?.state ?? ["running": false]
    state["display"] = settingsDisplayInfo(app.settingsPresenter.settingsPresenter.window?.screen)
    return state
  }
  /// Own-window controls and layout only. Input still travels through the
  /// existing key/mouse socket commands; this never uses desktop input.
  func settingsUI(_ args: [String: Any]) throws -> [String: Any] {
    let adapter = app.settingsPresenter
    let root = adapter.settings
    let action = args["action"] as? String ?? "state"
    switch action {
    case "open":
      guard let raw = args["section"] as? String, let section = SettingsSection(rawValue: raw) else { throw Failure(message: "unknown section") }
      adapter.show(); root.navigate(to: section)
    case "link":
      guard let raw = args["url"] as? String, let url = URL(string: raw), root.openSettingsURL(url) else { throw Failure(message: "invalid Settings link") }
      adapter.show()
    case "reduce-motion":
      Motion.reduceMotionOverride = args["enabled"] as? Bool
    case "external-link":
      guard let raw = args["url"] as? String, let url = URL(string: raw) else { throw Failure(message: "invalid URL") }
      app.application(NSApp, open: [url])
    case "kit": root.showsControlsKit = args["visible"] as? Bool ?? true
    case "default-browser-presentation":
      // Visual fixture only: never calls the system default-browser service.
      guard let isDefault = args["isDefault"] as? Bool else { throw Failure(message: "missing presentation state") }
      root.general.isDefault = isDefault
    case "blur":
      guard let window = adapter.settingsPresenter.window else { throw Failure(message: "missing Settings window") }
      let target = window.attachedSheet ?? window
      target.makeFirstResponder(target.contentView)
    case "resize":
      guard let width = args["width"] as? Double, let height = args["height"] as? Double,
        (800...1400).contains(width), (540...1000).contains(height),
        let window = adapter.settingsPresenter.window else { throw Failure(message: "invalid Settings size") }
      var frame = window.frame; frame.size = .init(width: width, height: height); window.setFrame(frame, display: true)
    case "select-command":
      guard let id = args["id"] as? String, CommandRegistry.byID[id] != nil else { throw Failure(message: "unknown command") }
      root.shortcuts.selectedCommandID = id
    case "choice":
      guard let label = args["label"] as? String, let title = args["title"] as? String,
        let content = adapter.settingsPresenter.window?.contentView else { throw Failure(message: "missing choice") }
      func find(_ view: NSView) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton, button.accessibilityLabel() == label, !button.isHiddenOrHasHiddenAncestor { return button }
        return view.subviews.lazy.compactMap(find).first
      }
      guard let button = find(content), button.isEnabled, button.itemTitles.contains(title) else { throw Failure(message: "unknown enabled Settings choice") }
      if button.pullsDown {
        guard let item = button.item(withTitle: title), item.isEnabled, let action = item.action else { throw Failure(message: "disabled Settings menu item") }
        NSApp.sendAction(action, to: item.target, from: item)
      } else { button.selectItem(withTitle: title); button.sendAction(button.action, to: button.target) }
    case "filter":
      guard let filter = args["filter"] as? String, ["all", "changed", "unassigned", "conflicts"].contains(filter) else { throw Failure(message: "unknown shortcut filter") }
      root.shortcuts.filter = filter
    case "keep":
      guard let id = args["id"] as? String, CommandRegistry.byID[id] != nil else { throw Failure(message: "unknown command") }
      root.shortcuts.keepShortcut(for: id)
    case "revert": root.shortcuts.revert()
    case "state": break
    default: throw Failure(message: "unknown Settings UI action")
    }
    let window = adapter.settingsPresenter.window
    let write = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    if NSApp.responds(to: write) { NSApp.perform(write, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }
    window?.contentView?.layoutSubtreeIfNeeded()
    window?.displayIfNeeded()
    var nodes: [[String: Any]] = [], seen: Set<ObjectIdentifier> = []
    var inspectedWindow = window
    func string(_ object: NSObject, _ name: String) -> String {
      let selector = NSSelectorFromString(name)
      return object.responds(to: selector) ? (object.perform(selector)?.takeUnretainedValue() as? String ?? "") : ""
    }
    func walk(_ object: NSObject, depth: Int) {
      guard depth < 30, seen.count < 3000, seen.insert(ObjectIdentifier(object)).inserted else { return }
      if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
      let label = string(object, "accessibilityLabel"), role = string(object, "accessibilityRole")
      let identifier = string(object, "accessibilityIdentifier")
      let value = string(object, "accessibilityValue")
      if !label.isEmpty || !identifier.isEmpty || !value.isEmpty {
        var frame = CGRect.zero
        let selector = NSSelectorFromString("accessibilityFrame")
        if object.responds(to: selector) {
          typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
          frame = unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        if let target = inspectedWindow {
          frame = target.convertFromScreen(frame)
          frame.origin.y = target.frame.height - frame.maxY
        }
        nodes.append(["label": label, "id": identifier, "role": role,
          "value": value, "window": inspectedWindow?.windowNumber ?? 0,
          "frame": [frame.minX, frame.minY, frame.width, frame.height]])
      }
      let selector = NSSelectorFromString("accessibilityChildren")
      if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
        for child in children { walk(child, depth: depth + 1) }
      }
      if let view = object as? NSView { for child in view.subviews { walk(child, depth: depth + 1) } }
    }
    if let content = window?.contentView { walk(content, depth: 0) }
    if let sheet = window?.attachedSheet, let content = sheet.contentView { inspectedWindow = sheet; walk(content, depth: 0) }
    let shortcuts = root.shortcuts
    let file = shortcuts.fileURL
    return ["window": window?.windowNumber ?? 0, "visible": window?.isVisible ?? false, "sheet": window?.attachedSheet?.windowNumber ?? 0,
      "section": root.selectedSection.rawValue, "query": root.searchQuery,
      "results": root.searchResults.map { ["id": $0.id, "label": $0.label] },
      "selection": root.searchSelection, "arrival": root.arrivalID ?? "", "arrivalRevision": root.arrivalRevision,
      "focusedSetting": root.focusedSettingID ?? "",
      "searchCPUms": root.searchCPUMilliseconds, "indexCount": SettingsSearchIndex.entries.count,
      "openLayoutDisplayMs": adapter.settingsPresenter.lastOpenMilliseconds,
      "openPhasesMs": adapter.settingsPresenter.lastOpenPhases,
      "openActionLayoutDisplayMs": adapter.lastSettingsShowMs,
      "size": window.map { [$0.frame.width, $0.frame.height] } ?? [],
      "scale": window?.backingScaleFactor ?? 0,
      "display": settingsDisplayInfo(window?.screen),
      "screen": window?.screen?.localizedName ?? "", "profile": root.selectedProfileID.description,
      "clearStatus": root.profiles.clearStatus, "clearing": root.profiles.clearing, "suggestNotice": root.profiles.showsSuggestNotice,
      "allowsRemoteSuggestions": root.profiles.allowsRemoteSuggestions,
      "updateState": root.updateState ?? "", "reduceMotion": Motion.reducesMotion,
      "profileSettings": ["engine": root.profiles.searchEngineID, "suggestions": root.profiles.suggestions,
        "directory": root.profiles.downloadDirectory, "ask": root.profiles.askWhereToSave,
        "archive": root.profiles.profile?.settings.autoArchiveAfter.rawValue ?? "",
        "littleArchive": root.profiles.profile?.settings.littleOpenAutoArchiveAfter.rawValue ?? ""],
      "controls": nodes, "recording": shortcuts.recordingCommandID ?? "", "shortcutStatus": shortcuts.statusText,
      "shortcutSelection": shortcuts.selectedCommandID ?? "", "findingKeys": shortcuts.findByKeys,
      "bindings": shortcuts.store.bindings.keys.sorted(), "conflicts": shortcuts.unexpected.count,
      "keybindingsFile": file.path, "shortcutCount": shortcuts.commands.count,
      "firstResponder": window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
      "sheetFirstResponder": window?.attachedSheet?.firstResponder.map { String(describing: type(of: $0)) } ?? ""] as [String: Any]
  }
}
#endif
