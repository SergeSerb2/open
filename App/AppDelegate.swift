import AppKit
import OpenEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, EngineDelegate {
  var options = LaunchOptions(arguments: [])
  private(set) var windowController: BrowserWindowController?
  #if OPEN_AUTOMATION
    private var automation: AutomationServer?
  #endif

  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchTiming.shared.mark("didFinishLaunching")
    NSApp.mainMenu = MainMenu.build()
    NSApp.setActivationPolicy(.regular)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    windowController?.showWindow(nil)
    return false
  }

  // MARK: EngineDelegate

  func engineDidInitialize() {
    LaunchTiming.shared.mark("engineInitialized")
    let controller = BrowserWindowController(profile: Engine.shared.defaultProfile, options: options)
    windowController = controller
    controller.showWindow(nil)
    LaunchTiming.shared.mark("windowShown")
    let urls = options.initialURLs.isEmpty ? [URL(string: "https://example.com")!] : options.initialURLs
    for url in urls {
      controller.openTab(url: url, style: options.defaultStyle, background: false)
    }
    #if OPEN_AUTOMATION
      let socket =
        options.automationSocket
        ?? options.userDataDirectory.appendingPathComponent("automation.sock")
      let server = AutomationServer(socketURL: socket, controller: AutomationController(window: controller))
      do {
        try server.start()
        automation = server
        FileHandle.standardError.write(Data("Open: automation socket at \(socket.path)\n".utf8))
      } catch {
        FileHandle.standardError.write(Data("Open: automation socket failed: \(error)\n".utf8))
      }
    #endif
  }

  func engineWebView(forUnownedOpenRequest request: OpenRequest) -> WebView? {
    windowController?.adoptUnownedRequest(request)
  }

  func engineWillShutDown() {
    #if OPEN_AUTOMATION
      automation?.stop()
    #endif
  }
}

/// The spike's menu bar. Items with `reservedTag` are app shortcuts that win
/// over the page (Arc reserves these too); everything else goes to the page
/// first and reaches the menu only if the page does not consume it.
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
        item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t", reserved: true),
        item("New Chrome-Style Tab", #selector(BrowserWindowController.newChromeTab(_:)), "t", [.command, .option]),
        item("Open Location…", #selector(BrowserWindowController.focusAddressBar(_:)), "l", reserved: true),
        item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w", reserved: true),
        .separator(),
        item("Print…", #selector(BrowserWindowController.printPage(_:)), "p"),
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
        item("Find…", #selector(BrowserWindowController.showFind(_:)), "f", reserved: true),
        item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"),
      ])
    submenu(
      "View",
      [
        item("Toggle Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s", reserved: true),
        item("Reload", #selector(BrowserWindowController.reloadPage(_:)), "r", reserved: true),
        item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "="),
        item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
        item("Actual Size", #selector(BrowserWindowController.resetZoom(_:)), "0"),
        .separator(),
        item("Split View", #selector(BrowserWindowController.toggleSplit(_:)), "=", [.control, .shift], reserved: true),
        item("Developer Tools", #selector(BrowserWindowController.showDevTools(_:)), "i", [.command, .option], reserved: true),
        item("Extensions", #selector(BrowserWindowController.openExtensionsPage(_:)), ""),
      ])
    submenu(
      "History",
      [
        item("Back", #selector(BrowserWindowController.goBack(_:)), "[", reserved: true),
        item("Forward", #selector(BrowserWindowController.goForward(_:)), "]", reserved: true),
      ])
    var tabItems = [
      item("Next Tab", #selector(BrowserWindowController.nextTab(_:)), "\t", .control, reserved: true),
      item("Previous Tab", #selector(BrowserWindowController.previousTab(_:)), "\t", [.control, .shift], reserved: true),
    ]
    for n in 1...9 {
      let i = item("Tab \(n)", #selector(BrowserWindowController.selectTabByNumber(_:)), "\(n)", reserved: true)
      i.representedObject = n
      tabItems.append(i)
    }
    submenu("Tabs", tabItems)
    submenu(
      "Window",
      [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
      ])
    return main
  }

  /// Performs a reserved app shortcut if `event` matches one. `fallback`
  /// receives actions that have no explicit target, so shortcuts work even
  /// when no window is key (for example while driven by automation).
  static func performReservedShortcut(_ event: NSEvent, fallback: AnyObject? = nil) -> Bool {
    guard let menu = NSApp.mainMenu, let item = reservedItem(in: menu, for: event),
      let action = item.action
    else { return false }
    let target = item.target ?? NSApp.target(forAction: action, to: nil, from: item) as AnyObject? ?? fallback
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
      if item.keyEquivalent.lowercased() == chars && itemMods == mods {
        return item
      }
      // Ctrl-Tab arrives with "\t" as characters; Ctrl-Shift-Tab as backtab.
      if item.keyEquivalent == "\t" && event.keyCode == 48 && itemMods == mods {
        return item
      }
    }
    return nil
  }
}
