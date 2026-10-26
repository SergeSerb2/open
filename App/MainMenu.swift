import AppKit

/// The menu bar with Arc's keys (docs/re/menus-and-hotkeys.md). Items marked
/// `reserved` win over the page: OEApplication.keyEquivalentHandler runs them
/// before Chromium sees the key. Everything else goes to the page first and
/// reaches the menu only if the page does not consume it.
@MainActor
enum MainMenu {
  static let reservedTag = 1

  static func build() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      item.submenu = menu
      main.addItem(item)
    }
    func item(
      _ title: String, _ action: Selector?, _ key: String,
      _ mods: NSEvent.ModifierFlags = .command, reserved: Bool = false
    ) -> NSMenuItem {
      let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
      i.keyEquivalentModifierMask = mods
      if reserved { i.tag = reservedTag }
      return i
    }
    func arrow(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }
    typealias W = BrowserWindowController

    submenu(
      "Open",
      [
        item("About Open", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
        .separator(),
        item("Hide Open", #selector(NSApplication.hide(_:)), "h"),
        item("Quit Open", #selector(NSApplication.terminate(_:)), "q", reserved: true),
      ])
    submenu(
      "File",
      [
        item("New Tab", #selector(W.newTab(_:)), "t", reserved: true),
        item("Open Location", #selector(W.focusAddressBar(_:)), "l", reserved: true),
        item("Archive Tab", #selector(W.closeTab(_:)), "w", reserved: true),
        item("Restore Last Closed Tab", #selector(W.restoreLastClosedTab(_:)), "T", [.command, .shift], reserved: true),
        .separator(),
        item("Print…", #selector(W.printPage(_:)), "p"),
      ])
    submenu(
      "Edit",
      [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "Z", [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
        .separator(),
        item("Find…", #selector(W.showFind(_:)), "f"),
        item("Find Next", #selector(W.findNext(_:)), "g"),
      ])
    submenu(
      "View",
      [
        item("Show/Hide Sidebar", #selector(W.toggleSidebar(_:)), "s", reserved: true),
        item("Reload", #selector(W.reloadPage(_:)), "r"),
        item("Stop", #selector(W.stopLoading(_:)), "."),
        item("Zoom In", #selector(W.zoomIn(_:)), "="),
        item("Zoom Out", #selector(W.zoomOut(_:)), "-"),
        item("Actual Size", #selector(W.resetZoom(_:)), "0"),
        .separator(),
        item("Add Split View", #selector(W.addSplitView(_:)), "=", [.control, .shift], reserved: true),
        item("Developer Tools", #selector(W.showDevTools(_:)), "i", [.command, .option]),
        item("Extensions", #selector(W.openExtensionsPage(_:)), ""),
      ])
    submenu(
      "Tabs",
      [
        item("Next Tab", #selector(W.nextTab(_:)), arrow(NSDownArrowFunctionKey), [.command, .option], reserved: true),
        item("Previous Tab", #selector(W.previousTab(_:)), arrow(NSUpArrowFunctionKey), [.command, .option], reserved: true),
        item("Tab Switcher Forward", #selector(W.nextTab(_:)), "\t", .control, reserved: true),
        item("Tab Switcher Backward", #selector(W.previousTab(_:)), "\t", [.control, .shift], reserved: true),
        item("Pin/Unpin Tab", #selector(W.togglePin(_:)), "d", reserved: true),
      ])
    submenu(
      "Spaces",
      [
        item("Next Space", #selector(W.nextSpace(_:)), arrow(NSRightArrowFunctionKey), [.command, .option], reserved: true),
        item("Previous Space", #selector(W.previousSpace(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option], reserved: true),
      ])
    submenu(
      "Archive",
      [
        item("Back", #selector(W.goBack(_:)), "["),
        item("Forward", #selector(W.goForward(_:)), "]"),
      ])
    submenu(
      "Window",
      [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
      ])
    return main
  }

  /// Runs a reserved shortcut if `event` matches one. Actions go to the key
  /// window's responder chain, else to the front browser window, so they also
  /// work while Open is not the active app (automation runs from a terminal).
  static func performReservedShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, let menu = NSApp.mainMenu,
      let item = reservedItem(in: menu, for: event), let action = item.action
    else { return false }
    let fallback = (NSApp.delegate as? AppDelegate)?.frontWindowController
    let target =
      item.target ?? NSApp.target(forAction: action, to: nil, from: item) as AnyObject? ?? fallback
    guard let target, target.responds(to: action) else { return false }
    return NSApp.sendAction(action, to: target, from: item)
  }

  private static func reservedItem(in menu: NSMenu, for event: NSEvent) -> NSMenuItem? {
    let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    let mods = event.modifierFlags.intersection(relevant)
    let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
    for item in menu.items {
      if let sub = item.submenu, let found = reservedItem(in: sub, for: event) {
        return found
      }
      guard item.tag == reservedTag, !item.keyEquivalent.isEmpty else { continue }
      var itemMods = item.keyEquivalentModifierMask.intersection(relevant)
      if item.keyEquivalent != item.keyEquivalent.lowercased() {
        itemMods.insert(.shift)
      }
      // Arrow keys carry the function-key flag; ignore it like AppKit does.
      if item.keyEquivalent.lowercased() == chars && itemMods == mods {
        return item
      }
      // Ctrl-Tab arrives as "\t"; Ctrl-Shift-Tab as backtab (U+0019).
      if item.keyEquivalent == "\t" && event.keyCode == 48 && itemMods == mods {
        return item
      }
    }
    return nil
  }
}
