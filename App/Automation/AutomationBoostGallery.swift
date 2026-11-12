#if OPEN_AUTOMATION
import AppKit
import OpenModel
import OpenSettings
import OpenLibrary

extension AutomationController {
  /// Exercise hosted controls in Open's own Library/Settings window. This
  /// never constructs Boost data or invokes LibraryActions in place of UI.
  func boostGalleryUI(_ args: [String: Any]) async throws -> Any {
    let action = args["action"] as? String ?? "state"
    guard ["state", "press", "profile", "section", "layout", "search"].contains(action),
      args.values.compactMap({ $0 as? String }).allSatisfy({ $0.utf8.count <= 1024 })
    else { throw Failure(message: "invalid Gallery UI request") }
    let settings = args["window"] as? String == "settings"
    guard let owner = settings ? app.settingsPresenter.settingsPresenter.window : app.settingsPresenter.libraryWindow,
      owner.isVisible else { throw Failure(message: "requested window is not visible") }
    if action != "state" { try await activateForInput(owner) }
    // SwiftUI lazily materializes its AX tree for enhanced clients. Use the
    // same in-process opt-in as the existing Profile automation checks.
    let enhanced = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }

    func string(_ object: NSObject, _ name: String) -> String {
      let selector = NSSelectorFromString(name)
      guard object.responds(to: selector) else { return "" }
      let value = object.perform(selector)?.takeUnretainedValue()
      if let value = value as? String { return String(value.prefix(1024)) }
      return (value as? NSNumber)?.stringValue ?? ""
    }
    func identifier(_ object: NSObject) -> String {
      let accessible = string(object, "accessibilityIdentifier")
      if !accessible.isEmpty { return accessible }
      // Native Library controls keep their identifiers on NSView. Read the
      // actual rendered view, just as the legacy path reads hosted AX nodes.
      return (object as? NSView)?.identifier?.rawValue ?? ""
    }
    var seen: Set<ObjectIdentifier> = [], nodes: [NSObject] = []
    func walk(_ object: NSObject, _ depth: Int) {
      guard depth <= 32, seen.count < 2048, seen.insert(ObjectIdentifier(object)).inserted else { return }
      if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
      nodes.append(object)
      let selector = NSSelectorFromString("accessibilityChildren")
      if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
        for child in children.prefix(2048) { walk(child, depth + 1) }
      }
      if let view = object as? NSView { for child in view.subviews.prefix(2048) { walk(child, depth + 1) } }
    }
    walk(owner.attachedSheet ?? owner, 0)
    if let view = (owner.attachedSheet ?? owner).contentView { walk(view, 0) }
    func press(_ target: NSObject) throws {
      // AX actions return BOOL, not an Objective-C object.
      typealias BooleanAction = @convention(c) (AnyObject, Selector) -> Bool
      let enabled = NSSelectorFromString("isAccessibilityEnabled")
      if target.responds(to: enabled), !unsafeBitCast(target.method(for: enabled), to: BooleanAction.self)(target, enabled) {
        throw Failure(message: "Gallery control is disabled")
      }
      if let button = target as? NSButton, button.target != nil, button.action != nil {
        // Native Library controls use NSButton's target/action path. Their
        // layer-backed cells do not implement the hosted AX press method.
        guard button.isEnabled else { throw Failure(message: "Gallery control is disabled") }
        button.performClick(nil); return
      }
      let selector = NSSelectorFromString("accessibilityPerformPress")
      guard target.responds(to: selector), unsafeBitCast(target.method(for: selector), to: BooleanAction.self)(target, selector)
      else { throw Failure(message: "Gallery control refused press") }
    }
    switch action {
    case "profile":
      if !settings, let panel=app.settingsPresenter.activeLibrarySession?.panel, let name=args["name"] as? String {
        guard panel.setBoostProfile(name) else { throw Failure(message:"unknown Profile") }; break
      }
      guard !settings, let name = args["name"] as? String,
        let profile = app.model.profiles.first(where: { $0.name == name }) else { throw Failure(message: "Profile picker item not found") }
      if let popup = nodes.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains(name) }),
        let item = popup.item(withTitle: name), item.isEnabled {
        popup.selectItem(withTitle: name)
        if let selector = popup.action { NSApp.sendAction(selector, to: popup.target, from: popup) }
      } else {
        let current = app.model.profile(id: app.settingsPresenter.library!.historyProfileID)?.name ?? ""
        let matches = nodes.filter {
          [NSAccessibility.Role.popUpButton.rawValue, NSAccessibility.Role.button.rawValue].contains(string($0, "accessibilityRole"))
            && [string($0, "accessibilityLabel"), string($0, "accessibilityTitle"), string($0, "accessibilityValue")].contains(current)
        }
        guard matches.count == 1, let target = matches.first else { throw Failure(message: "Profile picker control not found") }
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
          nonisolated(unsafe) let menu = note.object as? NSMenu
          MainActor.assumeIsolated {
            guard let menu else { return }
            nonisolated(unsafe) let trackingMenu = menu
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
              MainActor.assumeIsolated {
                if let index = trackingMenu.items.firstIndex(where: { $0.title == name && $0.isEnabled }) { trackingMenu.performActionForItem(at: index) }
                trackingMenu.cancelTrackingWithoutAnimation()
              }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
          }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try press(target)
        for _ in 0..<100 {
          if app.settingsPresenter.library?.historyProfileID == profile.id { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        guard app.settingsPresenter.library?.historyProfileID == profile.id else { throw Failure(message: "Profile menu selection did not apply") }
      }
    case "section":
      if !settings, let panel = app.settingsPresenter.activeLibrarySession?.panel, let raw = args["section"] as? String,
        let section = LibraryPanelSection(rawValue:raw == "captures" ? "media" : raw) {
        panel.select(section); break
      }
      guard !settings, let raw = args["section"] as? String, let section = LibrarySection(rawValue: raw),
        let index = LibrarySection.allCases.firstIndex(of: section),
        let table = nodes.compactMap({ $0 as? NSTableView }).first(where: { $0.numberOfRows == LibrarySection.allCases.count })
      else { throw Failure(message: "Library sidebar not found") }
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    case "layout":
      if !settings, let panel=app.settingsPresenter.activeLibrarySession?.panel, let name=args["name"] as? String { panel.setBoostLayout(name); break }
      guard let name = args["name"] as? String, ["List", "Gallery"].contains(name) else { throw Failure(message: "unknown layout") }
      if let control = nodes.compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount == 2 && $0.label(forSegment: 0) == "List" }) {
        control.selectedSegment = name == "List" ? 0 : 1
        if let selector = control.action { NSApp.sendAction(selector, to: control.target, from: control) }
      } else {
        guard let target = nodes.first(where: { string($0, "accessibilityLabel") == name && string($0, "accessibilityRole") == NSAccessibility.Role.radioButton.rawValue })
        else { throw Failure(message: "layout control not found") }
        try press(target)
      }
    case "search":
      guard let text = args["text"] as? String,
        let field = nodes.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString?.hasPrefix("Search Boosts") == true })
      else { throw Failure(message: "Boost search field not found") }
      owner.makeFirstResponder(field); field.selectText(nil)
      _ = try await sendKey(["window": owner.windowNumber, "text": text.isEmpty ? "\u{7f}" : text, "route": "app"], try? window)
    case "press":
      let matches = nodes.filter {
        if let id = args["id"] as? String { return identifier($0) == id }
        guard let label = args["label"] as? String else { return false }
        return [string($0, "accessibilityLabel"), string($0, "accessibilityTitle")].contains(label)
          && [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.checkBox.rawValue].contains(string($0, "accessibilityRole"))
      }
      guard matches.count == 1, let target = matches.first else { throw Failure(message: "expected one Gallery control; found \(matches.count)") }
      if let raw = args["profileBeforePress"] as? String {
        guard !settings, let uuid = UUID(uuidString: raw), app.model.profile(id: ProfileID(rawValue: uuid)) != nil else { throw Failure(message: "unknown queued Profile") }
        // Retain the actual rendered control, change the picker binding, then
        // press in the same turn before SwiftUI can replace its callback.
        app.settingsPresenter.library?.historyProfileID = ProfileID(rawValue: uuid)
      }
      try press(target)
    default: break
    }
    if action != "state" { await Task.yield() }
    return ["window": owner.windowNumber, "key": owner.isKeyWindow,
      "controls": nodes.map { ["class": String(describing: type(of: $0)), "id": identifier($0), "label": string($0, "accessibilityLabel"),
        "title": string($0, "accessibilityTitle"), "role": string($0, "accessibilityRole"), "value": string($0, "accessibilityValue")] },
      "popupItems": nodes.compactMap { ($0 as? NSPopUpButton)?.itemTitles }] as [String: Any]
  }
}
#endif
