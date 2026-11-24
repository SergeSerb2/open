#if OPEN_AUTOMATION
import AppKit

/// UX round 1 wave 2 (keyboard and accessibility audit). In-process reads only: the key window's
/// first responder and any owned window's accessibility tree. Input still travels through the
/// existing `key` command (NSApp.sendEvent); nothing here sends events or changes focus.
extension AutomationController {
  /// `OPEN_AUTOMATION_FULL_KEYBOARD_ACCESS=1` (automation builds only): Open behaves as if Keyboard
  /// navigation (Full Keyboard Access) were on, without touching the user's system setting.
  static func installFullKeyboardAccessOverrideIfRequested() {
    guard ProcessInfo.processInfo.environment["OPEN_AUTOMATION_FULL_KEYBOARD_ACCESS"] == "1",
      let method = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isFullKeyboardAccessEnabled)) else { return }
    let on: @convention(block) (AnyObject) -> Bool = { _ in true }
    method_setImplementation(method, imp_implementationWithBlock(on))
  }

  /// Window-relative frame, top-left origin, of an accessibility element or view.
  private func auditFrame(_ object: NSObject, in window: NSWindow) -> [Double] {
    var frame = CGRect.zero
    let selector = NSSelectorFromString("accessibilityFrame")
    if object.responds(to: selector) {
      typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
      frame = unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
      frame = window.convertFromScreen(frame)
      frame.origin.y = window.frame.height - frame.maxY
    } else if let view = object as? NSView {
      frame = view.convert(view.bounds, to: nil)
      frame.origin.y = window.frame.height - frame.maxY
    }
    return [frame.minX, frame.minY, frame.width, frame.height].map { (value: CGFloat) -> Double in (Double(value) * 10).rounded() / 10 }
  }

  private func auditString(_ object: NSObject, _ name: String) -> String {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return "" }
    let value = object.perform(selector)?.takeUnretainedValue()
    if let string = value as? String { return string }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return ""
  }

  /// `ax-debug`: for every NSTableView/NSOutlineView in the key window, what the attribute-based
  /// API answers for AXChildren and AXRows, the unignored count, and each row's parent and ignored state.
  func auditAXDebug(_ a: [String: Any]) throws -> [String: Any] {
    guard let window = (a["window"] as? Int).flatMap({ n in NSApp.windows.first { $0.windowNumber == n } }) ?? NSApp.keyWindow,
      let content = window.contentView else { throw Failure(message: "no window") }
    var tables: [[String: Any]] = []
    // `mode: count`: only the cheap paths a screen reader uses to size and page through a long list.
    // Reports how many row views existed before and after, so a full build of every row shows.
    if a["mode"] as? String == "count" {
      func existing(_ table: NSTableView) -> Int { (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: false) != nil }.count }
      func walkCount(_ view: NSView) {
        if let table = view as? NSTableView {
          let before = existing(table)
          let children = table.accessibilityArrayAttributeCount(.children), rows = table.accessibilityArrayAttributeCount(.rows)
          let visible = table.accessibilityArrayAttributeCount(.visibleRows)
          let page = table.accessibilityArrayAttributeValues(.rows, index: 0, maxCount: 5)
          let index = page.first.map { table.accessibilityIndex(ofChild: $0) } ?? -1
          tables.append(["class": String(describing: type(of: table)), "numberOfRows": table.numberOfRows, "countChildren": children,
            "countRows": rows, "countVisible": visible, "firstPage": page.count, "indexOfFirst": index,
            "rowViewsBefore": before, "rowViewsAfter": existing(table)])
        }
        view.subviews.forEach(walkCount)
      }
      walkCount(content)
      return ["tables": tables]
    }
    func walk(_ view: NSView) {
      if let table = view as? NSTableView {
        let modern = table.accessibilityChildren() ?? []
        let attr = table.accessibilityAttributeValue(.children) as? [Any] ?? []
        let rows = table.accessibilityAttributeValue(.rows) as? [Any] ?? []
        let unignored = NSAccessibility.unignoredChildren(from: modern)
        let detail = modern.prefix(4).map { child -> [String: Any] in
          let object = child as AnyObject
          let parent = (object as? NSView)?.accessibilityParent() as AnyObject?
          return ["class": String(describing: type(of: object)), "parentIsTable": parent === table,
            "parentClass": parent.map { String(describing: type(of: $0)) } ?? "nil",
            "ignored": (object as? NSObject)?.accessibilityIsIgnored() ?? true,
            "element": (object as? NSView)?.isAccessibilityElement() ?? false]
        }
        tables.append(["class": String(describing: type(of: table)), "modern": modern.count, "attributeChildren": attr.count,
          "arrayCountChildren": table.accessibilityArrayAttributeCount(.children), "arrayCountRows": table.accessibilityArrayAttributeCount(.rows),
          "attributeRows": rows.count, "unignored": unignored.count, "detail": detail])
      }
      view.subviews.forEach(walk)
    }
    walk(content)
    return ["tables": tables]
  }

  /// `responder`: the key (or given) window's first responder: class, accessibility role and
  /// label, frame, and focus ring type. A field editor reports its text field.
  func auditResponder(_ a: [String: Any]) throws -> [String: Any] {
    guard let window = (a["window"] as? Int).flatMap({ n in NSApp.windows.first { $0.windowNumber == n } }) ?? NSApp.keyWindow
    else { return ["window": 0, "class": "none"] }
    var responder: NSResponder? = window.firstResponder
    if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder { responder = field }
    var row: [String: Any] = ["window": window.windowNumber, "windowClass": String(describing: type(of: window)),
      "windowTitle": window.title, "class": responder.map { String(describing: type(of: $0)) } ?? "none",
      "isWindow": responder === window, "fullKeyboardAccess": NSApp.isFullKeyboardAccessEnabled]
    if let object = responder as NSObject? {
      row["role"] = auditString(object, "accessibilityRole")
      row["label"] = auditString(object, "accessibilityLabel")
      row["title"] = auditString(object, "accessibilityTitle")
      row["identifier"] = auditString(object, "accessibilityIdentifier")
      row["frame"] = auditFrame(object, in: window)
    }
    if let view = responder as? NSView { row["focusRingType"] = view.focusRingType.rawValue }
    return row
  }

  /// `ax-tree`: every accessibility element under an owned window (NSView and SwiftUI
  /// elements alike), depth first, with role, subrole, label, title, value, identifier,
  /// enabled, frame and whether the frame lies inside the window.
  func auditAXTree(_ a: [String: Any]) throws -> [String: Any] {
    guard let window = (a["window"] as? Int).flatMap({ n in NSApp.windows.first { $0.windowNumber == n } }) ?? NSApp.keyWindow
    else { throw Failure(message: "no window") }
    let write = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    if NSApp.responds(to: write) { NSApp.perform(write, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }
    window.contentView?.layoutSubtreeIfNeeded()
    var nodes: [[String: Any]] = [], seen: Set<ObjectIdentifier> = []
    let bounds = CGRect(origin: .zero, size: window.frame.size)
    func walk(_ object: NSObject, depth: Int, path: String) {
      guard depth < 40, nodes.count < 4000, seen.insert(ObjectIdentifier(object)).inserted else { return }
      if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
      let role = auditString(object, "accessibilityRole")
      let ignored: Bool = {
        let selector = NSSelectorFromString("isAccessibilityElement")
        guard object.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return !unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
      }()
      if !role.isEmpty && !ignored {
        let frame = auditFrame(object, in: window)
        let rect = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
        var enabled = true
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        if object.responds(to: selector) {
          typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
          enabled = unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        nodes.append(["role": role, "subrole": auditString(object, "accessibilitySubrole"),
          "label": auditString(object, "accessibilityLabel"), "title": auditString(object, "accessibilityTitle"),
          "value": auditString(object, "accessibilityValue"), "help": auditString(object, "accessibilityHelp"),
          "identifier": auditString(object, "accessibilityIdentifier"), "enabled": enabled,
          "class": String(describing: type(of: object)), "frame": frame, "path": path,
          "inside": rect.width <= 0 || rect.height <= 0 || bounds.insetBy(dx: -1, dy: -1).contains(rect)])
      }
      let children = NSSelectorFromString("accessibilityChildren")
      if object.responds(to: children), let list = object.perform(children)?.takeUnretainedValue() as? [Any] {
        for (index, child) in list.enumerated() { if let child = child as? NSObject { walk(child, depth: depth + 1, path: path + "/" + String(index)) } }
      } else if let view = object as? NSView {
        for (index, child) in view.subviews.enumerated() { walk(child, depth: depth + 1, path: path + "/v" + String(index)) }
      }
    }
    if let content = window.contentView { walk(content, depth: 0, path: "") }
    return ["window": window.windowNumber, "windowClass": String(describing: type(of: window)), "size": [window.frame.width, window.frame.height], "nodes": nodes]
  }
}
#endif
