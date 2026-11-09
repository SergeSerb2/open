#if OPEN_AUTOMATION
import AppKit

extension AutomationController {
  /// Invoke a real button in Open's frontmost native child dialog. Chromium
  /// Views buttons are AX elements, so they need not be NSButton instances.
  func childDialogButton(_ args: [String: Any]) async throws -> Any {
    guard Set(args.keys).isSubset(of: ["window", "label"]),
      args["window"] == nil || args["window"] is Int,
      args["label"] == nil || args["label"] is String
    else { throw Failure(message: "expected optional child window number and button label") }
    guard let dialog = NSApp.orderedWindows.first(where: { $0.isVisible && $0.parent != nil && !$0.isSheet }),
      args["window"] == nil || args["window"] as? Int == dialog.windowNumber
    else { throw Failure(message: "frontmost child dialog does not match") }

    func string(_ object: NSObject, _ name: String) -> String {
      let selector = NSSelectorFromString(name)
      guard object.responds(to: selector) else { return "" }
      return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    var seen: Set<ObjectIdentifier> = [], buttons: [(NSObject, String)] = []
    func walk(_ object: NSObject, _ depth: Int) {
      guard depth <= 16, seen.count < 512, seen.insert(ObjectIdentifier(object)).inserted else { return }
      if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
      if string(object, "accessibilityRole") == NSAccessibility.Role.button.rawValue {
        let label = [string(object, "accessibilityLabel"), string(object, "accessibilityTitle")]
          .first { !$0.isEmpty } ?? (object as? NSButton)?.title ?? ""
        if !label.isEmpty { buttons.append((object, label)) }
      }
      let children = NSSelectorFromString("accessibilityChildren")
      if object.responds(to: children), let nodes = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
        for node in nodes.prefix(512) { walk(node, depth + 1) }
      }
      if let view = object as? NSView {
        for child in view.subviews.prefix(512) { walk(child, depth + 1) }
      }
    }
    walk(dialog, 0)
    if let content = dialog.contentView { walk(content, 0) }
    let state: [String: Any] = ["window": dialog.windowNumber, "buttons": buttons.map { $0.1 }]
    guard let label = args["label"] as? String else { return state }
    guard !label.isEmpty, label.utf8.count <= 256 else { throw Failure(message: "invalid child dialog button label") }
    let matches = buttons.filter { $0.1 == label }
    guard matches.count == 1, let target = matches.first?.0 else {
      throw Failure(message: "expected one matching child dialog button")
    }
    // BOOL-returning Objective-C methods must use their real signature, not
    // NSObject.perform's object-returning signature.
    typealias BooleanAction = @convention(c) (AnyObject, Selector) -> Bool
    let enabled = NSSelectorFromString("isAccessibilityEnabled")
    if target.responds(to: enabled),
      !unsafeBitCast(target.method(for: enabled), to: BooleanAction.self)(target, enabled) {
      throw Failure(message: "child dialog button is disabled")
    }
    let press = NSSelectorFromString("accessibilityPerformPress")
    guard target.responds(to: press),
      unsafeBitCast(target.method(for: press), to: BooleanAction.self)(target, press)
    else { throw Failure(message: "child dialog button did not accept its press action") }
    await Task.yield()
    return state.merging(["pressed": true, "label": label]) { _, new in new }
  }
}
#endif
