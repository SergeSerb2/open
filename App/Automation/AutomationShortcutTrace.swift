#if OPEN_AUTOMATION
import AppKit

/// Scoped to one in-process key send. Records real dispatch without replacing
/// any target, selector, validation, or key-equivalent route.
@MainActor
enum AutomationShortcutTrace {
  static var recording = false
  static var commands: [String] = []
  static var menuActions: [String] = []
  static func record(_ id: String) {
    if recording, commands.count < 64 { commands.append(id) }
  }
}

extension AutomationController {
  /// Copies the real items into a native menu and captures only our popup.
  /// AppKit draws the key glyphs; the observer cancels without an action.
  func renderMenuKeys(to path: String) throws -> Any {
    func items(_ menu: NSMenu?) -> [NSMenuItem] {
      (menu?.items ?? []).flatMap { item in
        if let submenu = item.submenu { return items(submenu) }
        return item.keyEquivalentModifierMask.contains(.shift)
          && item.keyEquivalent.count == 1 && item.keyEquivalent.first?.isLetter == true ? [item] : []
      }
    }
    let rows = items(NSApp.mainMenu)
    let capture = NativeMenuKeyCapture()
    let menu = NSMenu(title: "Native Shift Keys"); menu.autoenablesItems = false
    for row in rows {
      let item = row.copy() as! NSMenuItem
      item.action = nil; item.target = nil; item.isEnabled = true
      menu.addItem(item)
    }
    guard let parent = app.frontWindowController?.window, let view = parent.contentView else {
      throw Failure(message: "no browser window for native menu")
    }
    capture.start(menu: menu, excluding: parent)
    defer { capture.stop() }
    menu.popUp(positioning: nil, at: NSPoint(x: 100, y: 300), in: view)
    guard let data = capture.png else { throw Failure(message: "native menu did not draw") }
    try data.write(to: URL(fileURLWithPath: path))
    return ["path": path, "count": rows.count]
  }
}

@MainActor
private final class NativeMenuKeyCapture {
  var png: Data?
  private var timer: Timer?
  private weak var menu: NSMenu?
  private weak var parent: NSWindow?
  func stop() { timer?.invalidate(); timer = nil }
  func start(menu: NSMenu, excluding parent: NSWindow) {
    self.menu = menu; self.parent = parent
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    let notBefore = ProcessInfo.processInfo.systemUptime + 0.1
    timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let menu = self.menu else { return }
        if ProcessInfo.processInfo.systemUptime >= notBefore,
          let popup = NSApp.windows.first(where: { $0 !== self.parent && $0.isVisible && $0.className.contains("PopupMenu") }),
          let image = WindowSnapshot.windowServerImage(popup) {
          self.png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        if self.png != nil || ProcessInfo.processInfo.systemUptime >= deadline {
          self.stop(); menu.cancelTrackingWithoutAnimation()
        }
      }
    }
    if let timer { RunLoop.main.add(timer, forMode: .eventTracking) }
  }
}
#endif
